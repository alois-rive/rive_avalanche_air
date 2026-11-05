// Decimate (Blender: Generate > Decimate), all three modes.
//
// - `collapse` is quadric edge collapse (see engine/src/source/model/modifiers/ext/geom/quadric),
//   the mode that takes a ratio and works on anything.
// - `un-subdivide` is the inverse of a subdivision: it dissolves every
//   other edge loop, which only means anything on a grid-like quad mesh.
// - `planar` dissolves edges between faces whose normals agree within an
//   angle, which flattens panels without touching the silhouette.

import { Vec3, VEC3_ZERO } from "../../../../base/vecmath";
import { Result, roundF32, f32ToU32 } from "../../../../base/util";
import { Mesh, VertId, EdgeId, FaceId, NO_ID } from "../../mesh/mod";
import { ModifierEnv } from "../mod";
import { triangulate } from "../triangulate";
import { dissolveLimited, dissolveVerts } from "../../ops/dissolve";
import { Quadric, triPlane } from "./geom/quadric";
import { PropDef, PropKind, Props, prop } from "./props";
import { VERTEX_GROUP, INVERT_GROUP, weightField, weightAt } from "./common";

export const PROPS: Array<PropDef> = [
    prop(
        "mode",
        PropKind.Choice(["collapse", "un-subdivide", "planar"]),
        "collapse",
        "collapse takes a ratio, un-subdivide halves the loops, planar merges flat neighbours",
    ),
    prop("ratio", PropKind.Range(0.0, 1.0), "1", "in collapse mode, the fraction of the faces to keep"),
    prop(
        "iterations",
        PropKind.IntRange(0, 16),
        "0",
        "in un-subdivide mode, how many times to halve the loops",
    ),
    prop(
        "angle-limit",
        PropKind.Degrees(),
        "5",
        "in planar mode, neighbours whose normals agree within this are merged",
    ),
    prop(
        "symmetry-axis",
        PropKind.Axis(),
        "x",
        "in collapse mode, the mirror axis used when --use-symmetry is on",
    ),
    prop(
        "use-symmetry",
        PropKind.Bool(),
        "false",
        "in collapse mode, keep the result symmetric about --symmetry-axis",
    ),
    VERTEX_GROUP,
    INVERT_GROUP,
];

// A per-vertex weight.
export type VertWeight = (v: VertId) => f32;

// No symmetry axis.
export const NO_AXIS: i32 = -1;

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const wf = weightField(mesh, p, env);
    const warnings = wf.field.warnings.slice(0);
    const mode = p.str("mode");
    if (mode == "un-subdivide") {
        const n = p.u32("iterations");
        for (let i: u32 = 0; i < n; i++) {
            unsubdivide(mesh);
        }
    } else if (mode == "planar") {
        const merged = dissolvePlanar(mesh, p.radians("angle-limit"));
        if (merged == 0) {
            warnings.push("no neighbouring faces were flat enough to merge; raise --angle-limit");
        }
    } else {
        const ratio = p.f32("ratio");
        const target = <i32>f32ToU32(roundF32(<f32>mesh.faces.len() * ratio));
        // A weighted group *protects* what it covers: weight 1 means
        // "do not touch", which is how Blender's decimate vertex group
        // reads at the default factor.
        // With no group set the field is 1 everywhere, which would
        // read as "protect every vertex" and collapse nothing.
        const protect: VertWeight = wf.field.isUniform()
            ? (v: VertId): f32 => <f32>0.0
            : (v: VertId): f32 => weightAt(wf.field, wf.invert, v);
        const removed = collapseTo(
            mesh,
            target,
            p.bool("use-symmetry") ? p.axis("symmetry-axis") : NO_AXIS,
            protect,
        );
        if (removed == 0 && ratio < <f32>1.0) {
            warnings.push(
                "nothing could be collapsed without tearing the mesh; it may be all " +
                    "boundary or non-manifold (`inspect check`)",
            );
        }
    }
    mesh.recalcNormals();
    mesh.touch();
    return Result.okv<Array<string>>(warnings);
}

// The best candidate so far (`has` is false until there is one).
class Best {
    has: bool = false;
    cost: f64 = 0;
    edge: EdgeId = 0;
    point: Vec3 = Vec3(0, 0, 0);
}

// One edge's score as a pass of `collapse_to` computes it: whether it may
// collapse (both weights below 1 and `collapsible`), and if so the cost and
// point of `best_position`. `a`/`b` are the edge's ends when it was scored
// and `at` the cache clock then.
class EdgeScore {
    a: VertId = 0;
    b: VertId = 0;
    at: i32 = 0;
    ok: bool = false;
    cost: f64 = 0;
    point: Vec3 = Vec3(0, 0, 0);
}

// Re-scoring every edge on every pass would cost O(E) evaluations per
// collapse, each allocating, which the never-freeing runtime keeps. A score
// depends only on the edge's two ends: their weights (a fixed function of
// the vertex id), their positions and quadrics, their edges, the faces of
// those edges and their other ends. A collapse (successful or not) changes
// those only for the vertices `touch` marks: both ends, every corner of a
// face of the removed vertex, and the removed vertex's neighbours (the
// edges it rewrites, adds or removes all run between these). So each pass
// still scans every edge in ascending id order with the same comparison,
// but re-scores only an edge that is new, has other ends, or touches a
// vertex marked since it was scored. Same scores, same choices.
class ScoreCache {
    scores: Array<EdgeScore?> = [];
    // Per vertex id: the clock value of the last `touch` that marked it.
    marked: Int32Array;
    clock: i32 = 1;

    constructor(vertBound: u32) {
        this.marked = new Int32Array(<i32>vertBound);
    }

    // The score slot of edge `e` (created on first use).
    slot(e: EdgeId): EdgeScore {
        const i = <i32>e;
        while (this.scores.length <= i) this.scores.push(null);
        let s = this.scores[i];
        if (s == null) {
            s = new EdgeScore();
            this.scores[i] = s;
        }
        return s;
    }

    // Whether `s` still holds the score of an edge from `a` to `b`.
    fresh(s: EdgeScore, a: VertId, b: VertId): bool {
        if (s.at == 0 || s.a != a || s.b != b) return false;
        const n = <u32>this.marked.length;
        if (a >= n || b >= n) return false;
        return s.at >= this.marked[<i32>a] && s.at >= this.marked[<i32>b];
    }

    private mark(v: VertId): void {
        if (v < <u32>this.marked.length) this.marked[<i32>v] = this.clock;
    }

    // Called before collapsing `keep`/`gone`, while the neighbourhood the
    // collapse will rewrite is still there to be read.
    touch(mesh: Mesh, keep: VertId, gone: VertId): void {
        this.clock++;
        this.mark(keep);
        this.mark(gone);
        const es = mesh.vertEdges(gone);
        for (let i = 0; i < es.length; i++) {
            const e = mesh.edges.at(es[i]);
            this.mark(e.v[0]);
            this.mark(e.v[1]);
            const fs = mesh.edgeFaces(es[i]);
            for (let k = 0; k < fs.length; k++) {
                const f = mesh.faces.at(fs[k]);
                const end = f.loopStart + f.loopLen;
                for (let l = f.loopStart; l < end; l++) this.mark(mesh.loops.at(l).vert);
            }
        }
    }
}

function quadricOf(quadrics: Map<VertId, Quadric>, v: VertId): Quadric {
    return quadrics.has(v) ? quadrics.get(v) : Quadric.default();
}

function addQuadric(quadrics: Map<VertId, Quadric>, v: VertId, q: Quadric): void {
    if (!quadrics.has(v)) quadrics.set(v, Quadric.default());
    quadrics.get(v).add(q);
}

// Collapse edges cheapest-first until the face count reaches `target`.
// Returns how many faces went away.
//
// `weight` protects geometry: a vertex whose weight is 1 is never moved,
// which is Blender's vertex-group behaviour, and an edge with any
// protected end is skipped. `symmetry` is an axis, or NO_AXIS.
export function collapseTo(mesh: Mesh, target: i32, symmetry: i32, weight: VertWeight): i32 {
    const start = mesh.faces.len();
    if (target >= start || mesh.faces.isEmpty()) {
        return 0;
    }
    // Blender's Collapse mode triangulates before it runs, and the link
    // condition below needs it: on a quad the two ends of an edge share no
    // neighbour, so nothing would ever pass.
    const faceVals = mesh.faces.values();
    let anyNonTri = false;
    for (let i = 0; i < faceVals.length; i++) {
        if (faceVals[i].loopLen != 3) {
            anyNonTri = true;
            break;
        }
    }
    if (anyNonTri) {
        triangulate(mesh);
    }
    // A quadric per vertex, summed over the planes of its faces.
    const quadrics = new Map<VertId, Quadric>();
    const fids = mesh.faces.ids();
    for (let i = 0; i < fids.length; i++) {
        const ts = mesh.triangulateFace(fids[i]);
        for (let k = 0; k < ts.length; k++) {
            const t = ts[k];
            const v0 = mesh.loops.at(t[0]).vert;
            const v1 = mesh.loops.at(t[1]).vert;
            const v2 = mesh.loops.at(t[2]).vert;
            const tp = triPlane(mesh.verts.at(v0).co, mesh.verts.at(v1).co, mesh.verts.at(v2).co);
            if (tp != null) {
                const q = Quadric.face(tp.p, tp.n, tp.area);
                addQuadric(quadrics, v0, q);
                addQuadric(quadrics, v1, q);
                addQuadric(quadrics, v2, q);
            }
        }
    }
    // Boundary edges get a plane standing on them, so decimating an open
    // surface does not eat its rim — the same guard Blender applies.
    const eids = mesh.edges.ids();
    for (let i = 0; i < eids.length; i++) {
        const e = eids[i];
        const ef = mesh.edgeFaces(e);
        if (ef.length != 1) {
            continue;
        }
        const edge = mesh.edges.at(e);
        const a = edge.v[0];
        const b = edge.v[1];
        const f = ef[0];
        const along = mesh.verts.at(b).co - mesh.verts.at(a).co;
        const normal = along.cross(mesh.faces.at(f).normal).normalizeOrZero();
        if (normal == VEC3_ZERO) {
            continue;
        }
        const q = Quadric.face(mesh.verts.at(a).co, normal, along.length());
        addQuadric(quadrics, a, q);
        addQuadric(quadrics, b, q);
    }

    let removed = 0;
    // Edges the link condition accepted but the collapse could not carry
    // out; skipped from then on so the search cannot pick one for ever.
    const blocked = new Set<EdgeId>();
    // Re-scoring every pass rather than keeping a heap: the heap needs
    // lazy deletion and a version per vertex, and the pass cost is what
    // dominates only on meshes far past this tool's budget anyway.
    // (Each edge keeps its score until a collapse touches it; see
    // ScoreCache. `weight` must be a fixed function of the vertex id, as
    // every caller's is.)
    const cache = new ScoreCache(mesh.verts.idBound());
    while (true) {
        if (mesh.faces.len() <= target) {
            break;
        }
        const best = new Best();
        const ids = mesh.edges.ids();
        for (let i = 0; i < ids.length; i++) {
            const e = ids[i];
            if (blocked.has(e)) {
                continue;
            }
            const edge = mesh.edges.at(e);
            const a = edge.v[0];
            const b = edge.v[1];
            const s = cache.slot(e);
            if (!cache.fresh(s, a, b)) {
                s.a = a;
                s.b = b;
                s.at = cache.clock;
                s.ok = !(weight(a) >= <f32>1.0 || weight(b) >= <f32>1.0) && collapsible(mesh, e);
                if (s.ok) {
                    const q = Quadric.sum(quadricOf(quadrics, a), quadricOf(quadrics, b));
                    const bp = q.bestPosition(mesh.verts.at(a).co, mesh.verts.at(b).co);
                    s.cost = bp.cost;
                    s.point = bp.p;
                }
            }
            if (!s.ok) {
                continue;
            }
            const cost = s.cost;
            // Ties break on the edge id, so the same mesh decimates the
            // same way on every run and every platform.
            if (!best.has || cost < best.cost || (cost == best.cost && e < best.edge)) {
                best.has = true;
                best.cost = cost;
                best.edge = e;
                best.point = s.point;
            }
        }
        if (!best.has) break;
        const edge = mesh.edges.at(best.edge);
        const a = edge.v[0];
        const b = edge.v[1];
        const q = Quadric.sum(quadricOf(quadrics, a), quadricOf(quadrics, b));
        const before = mesh.faces.len();
        const kept = collapseEdge(mesh, best.edge, best.point, cache);
        if (kept == NO_ID) {
            // The edge passed the link condition but the collapse would
            // have torn the mesh. Take it out of the running so the next
            // pass picks something else instead of choosing it again.
            blocked.add(best.edge);
            continue;
        }
        removed += before - mesh.faces.len();
        quadrics.delete(a);
        quadrics.delete(b);
        quadrics.set(kept, q);
        if (symmetry >= 0) {
            mirrorCollapse(mesh, kept, symmetry, quadrics, cache);
        }
        if (before == mesh.faces.len()) {
            // Nothing went away: stop rather than spin.
            break;
        }
    }
    mesh.deleteLooseVerts();
    return removed;
}

// An edge can be collapsed when the two vertices share exactly the faces
// that use the edge — otherwise the collapse would fold a face onto
// itself and leave non-manifold geometry behind (the "link condition").
//
// The neighbourhood has to be manifold as well, not just the edge: a
// vertex where three surfaces meet has a fan the collapse cannot rewrite,
// and a mesh with such vertices is exactly what a boolean produces along
// its seam. Those edges are skipped rather than collapsed badly.
export function collapsible(mesh: Mesh, e: EdgeId): bool {
    const edge = mesh.edges.at(e);
    const a = edge.v[0];
    const b = edge.v[1];
    if (a == b) {
        return false;
    }
    const faces = mesh.edgeFaces(e);
    if (faces.length == 0 || faces.length > 2) {
        return false;
    }
    for (let k = 0; k < 2; k++) {
        const v = k == 0 ? a : b;
        const ve = mesh.vertEdges(v);
        for (let i = 0; i < ve.length; i++) {
            if (mesh.edgeFaces(ve[i]).length > 2) return false;
        }
    }
    // Counts the entries of `vertNeighbors(a)` (repeats included) that
    // `vertNeighbors(b)` contains, read straight from the edge lists
    // instead of collecting both.
    const ea = mesh.vertEdges(a);
    const eb = mesh.vertEdges(b);
    let shared = 0;
    for (let i = 0; i < ea.length; i++) {
        const x = mesh.edges.at(ea[i]).other(a);
        if (x == NO_ID) continue;
        for (let j = 0; j < eb.length; j++) {
            if (mesh.edges.at(eb[j]).other(b) == x) {
                shared++;
                break;
            }
        }
    }
    // One shared neighbour per face on the edge, and no more.
    return shared == faces.length;
}

// Merge `e`'s two vertices at `point`, keeping the lower id. NO_ID when the collapse would have left a face referring to a vertex
// that is no longer there, in which case the position is put back (the
// rewritten faces are not). `cache` is told which scores the
// collapse can change.
function collapseEdge(mesh: Mesh, e: EdgeId, point: Vec3, cache: ScoreCache): VertId {
    const edge = mesh.edges.at(e);
    const a = edge.v[0];
    const b = edge.v[1];
    const keep = a < b ? a : b;
    const gone = a < b ? b : a;
    cache.touch(mesh, keep, gone);
    const faces = mesh.vertFaces(gone);
    const keepVert = mesh.verts.at(keep);
    const before = keepVert.co;
    keepVert.co = point;
    const emptied: Array<FaceId> = [];
    for (let fi = 0; fi < faces.length; fi++) {
        const f = faces[fi];
        const ring = mesh.faceVerts(f);
        // `gone` may appear more than once, and not consecutively, on a
        // face the seam of a boolean left folded; `dedup` alone would keep
        // one of those and make a face that repeats a vertex.
        const verts: Array<VertId> = [];
        for (let i = 0; i < ring.length; i++) {
            const v = ring[i] == gone ? keep : ring[i];
            if (verts.length == 0 || verts[verts.length - 1] != v) {
                verts.push(v);
            }
        }
        while (verts.length > 1 && verts[0] == verts[verts.length - 1]) {
            verts.pop();
        }
        if (verts.length < 3) {
            emptied.push(f);
        } else {
            mesh.setFaceVerts(f, verts);
        }
    }
    // `delete_faces`, not `delete_faces_cleanup`: the cleanup would take
    // every vertex no *remaining* face uses, and half way through a
    // collapse that can include one the next face still refers to.
    mesh.deleteFaces(emptied);
    // If anything still names the vertex about to go, put the geometry back
    // rather than leave a dangling reference behind. This cannot happen on
    // a manifold neighbourhood, and `collapsible` refuses the rest — but a
    // decimator that can corrupt a mesh on a shape it mis-classified is
    // worse than one that declines a collapse.
    // (The loop walk below reads each face's corners without building
    // the vertex lists.)
    const fids = mesh.faces.ids();
    for (let i = 0; i < fids.length; i++) {
        const face = mesh.faces.at(fids[i]);
        const end = face.loopStart + face.loopLen;
        for (let l = face.loopStart; l < end; l++) {
            if (mesh.loops.at(l).vert == gone) {
                mesh.verts.at(keep).co = before;
                return NO_ID;
            }
        }
    }
    mesh.removeVert(gone);
    return keep;
}

// Do the same collapse on the other side of a mirror plane, so a symmetric
// mesh decimates symmetrically.
function mirrorCollapse(
    mesh: Mesh,
    kept: VertId,
    axis: i32,
    quadrics: Map<VertId, Quadric>,
    cache: ScoreCache,
): void {
    let co = mesh.verts.at(kept).co;
    if (Mathf.abs(co.get(axis)) < <f32>1e-5) {
        return;
    }
    co.set(axis, -co.get(axis));
    // The nearest vertex across the plane, if it is close enough to be the
    // mirror of this one. Scanned in ascending id order: a later vertex wins
    // only when strictly nearer (an unordered distance counts as equal).
    let has = false;
    let twin: VertId = 0;
    let dist: f32 = 0;
    const ids = mesh.verts.ids();
    for (let i = 0; i < ids.length; i++) {
        const id = ids[i];
        if (id == kept) continue;
        const d = (mesh.verts.at(id).co - co).length();
        if (!has || d < dist) {
            has = true;
            twin = id;
            dist = d;
        }
    }
    if (!has) {
        return;
    }
    if (dist > <f32>1e-4) {
        return;
    }
    const ve = mesh.vertEdges(twin);
    let edge: EdgeId = NO_ID;
    for (let i = 0; i < ve.length; i++) {
        if (collapsible(mesh, ve[i])) {
            edge = ve[i];
            break;
        }
    }
    if (edge == NO_ID) {
        return;
    }
    const ev = mesh.edges.at(edge);
    const x = ev.v[0];
    const y = ev.v[1];
    const mid = (mesh.verts.at(x).co + mesh.verts.at(y).co) * <f32>0.5;
    const q = Quadric.sum(quadricOf(quadrics, x), quadricOf(quadrics, y));
    const survivor = collapseEdge(mesh, edge, mid, cache);
    if (survivor == NO_ID) {
        return;
    }
    quadrics.delete(x);
    quadrics.delete(y);
    quadrics.set(survivor, q);
}

// Merge neighbouring faces whose normals agree within `angleLimit`.
//
// This is Blender's Limited Dissolve under another name, which is exactly
// what planar decimation is — so it runs the kernel's, rather than a
// second implementation of the same walk. Returns how many faces went.
export function dissolvePlanar(mesh: Mesh, angleLimit: f32): i32 {
    const verts = mesh.verts.ids();
    const before = mesh.faces.len();
    dissolveLimited(mesh, verts, angleLimit);
    const after = mesh.faces.len();
    return before > after ? before - after : 0;
}

// Halve the resolution of a quad grid by dissolving every other loop.
export function unsubdivide(mesh: Mesh): i32 {
    // Colour the vertices two ways by walking the quad grid: a vertex whose
    // graph distance from an arbitrary start is odd is dissolved away.
    const ids = mesh.verts.ids();
    if (ids.length == 0) {
        return 0;
    }
    const start = ids[0];
    const parity = new Map<VertId, bool>();
    parity.set(start, false);
    const queue: Array<VertId> = [start];
    let head = 0;
    while (head < queue.length) {
        const v = queue[head++];
        const p = parity.get(v);
        const ns = mesh.vertNeighbors(v);
        for (let i = 0; i < ns.length; i++) {
            const n = ns[i];
            if (!parity.has(n)) {
                parity.set(n, !p);
                queue.push(n);
            }
        }
    }
    // Ascending vertex id.
    const keys = parity.keys();
    keys.sort((x: VertId, y: VertId): i32 => (x < y ? -1 : x > y ? 1 : 0));
    const drop: Array<VertId> = [];
    for (let i = 0; i < keys.length; i++) {
        const v = keys[i];
        if (!parity.get(v)) continue;
        // A vertex on the boundary holds the rim in place.
        const ve = mesh.vertEdges(v);
        let all = true;
        for (let k = 0; k < ve.length; k++) {
            if (mesh.edgeFaces(ve[k]).length != 2) {
                all = false;
                break;
            }
        }
        if (all) drop.push(v);
    }
    return dissolveVerts(mesh, drop).verts;
}
