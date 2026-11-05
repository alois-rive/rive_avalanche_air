// Bevel edges and vertices (Ctrl+B /
// Ctrl+Shift+B).
//
// The construction follows Blender's bevel in outline. Every vertex on a
// beveled edge gets a *boundary* of new vertices walking its fan of edges
// and faces counter-clockwise:
//
// - where two consecutive beveled edges share a face, one vertex where
//   their two offset lines (parallel to the edge, `width` into the face)
//   meet;
// - on every unbeveled edge, one vertex slid along it: to where the offset
//   line of the neighbouring beveled edge crosses it, or by `width` when no
//   beveled edge is adjacent.
//
// Each beveled edge becomes a strip of `segments` quads whose ends follow a
// circular (`profile` 0.5) arc between its two boundary vertices at each
// end; faces around a vertex re-point their corner to the boundary vertices
// they see, and the boundary itself is closed with a corner patch (one
// ngon, or for two segments quads around a centre vertex, otherwise a
// triangle fan). Blender's special case is kept: a vertex with three
// edges of which one is beveled gets no corner patch; the profile joins the
// opposite face instead.
//
// Limitations: beveled edges must be manifold interior edges with
// consistently wound faces; every vertex they touch must have a manifold
// fan (open fans, i.e. boundary vertices, are accepted but get no corner
// patch); profiles other than 0.5 fall back to 0.5 with a warning; corner
// patches with three or more segments are triangle fans rather than
// Blender's subdivided grids; `clamp` limits the width to half the shortest
// edge around the bevel rather than Blender's exact overlap test.

import { Vec3, VEC3_ZERO } from "../../../base/vecmath";
import { Result, panic, dedup, minF32 } from "../../../base/util";
import { displayF32 } from "../../../base/fmt";
import { CoreError } from "../../../base/error";
import { OpReport, plural } from "../../../base/report";
import { Mesh, Edge, ElemKind, EdgeId, FaceId, VertId, NO_ID } from "../mesh/mod";
import { Scene } from "../scene";
import { appleSincosf } from "../../../base/libm";
import { editMesh, requireSelected, meshReport, nothingSelected } from "./mod";
import { vertices } from "./merge";

// Options shared by the operator and the bevel modifier.
export class BevelOpts {
    width: f32 = 0.1;
    segments: u32 = 1;
    // 0..1, 0.5 = circular. Only 0.5 is honored until profiles land.
    profile: f32 = 0.5;
    clamp: bool = true;

    // Default options with the given width and segments.
    static of(width: f32, segments: u32): BevelOpts {
        const o = new BevelOpts();
        o.width = width;
        o.segments = segments;
        return o;
    }

    clone(): BevelOpts {
        const o = new BevelOpts();
        o.width = this.width;
        o.segments = this.segments;
        o.profile = this.profile;
        o.clamp = this.clamp;
        return o;
    }
}

// What a bevel produced (new faces are selected by the caller).
export class BevelResult {
    newFaces: Array<u32> = [];
    warnings: Array<string> = [];
    newVerts: Array<VertId> = [];
}

function bad(msg: string): CoreError {
    return CoreError.invalidArgument(msg);
}

function sortIds(a: Array<u32>): void {
    a.sort((x: u32, y: u32): i32 => (x < y ? -1 : x > y ? 1 : 0));
}

function otherEnd(mesh: Mesh, e: EdgeId, v: VertId): VertId {
    const o = mesh.edges.at(e).other(v);
    if (o == NO_ID) panic("edge on vert");
    return o;
}

// The edges and faces around a vertex, counter-clockwise seen from
// outside: `faces[i]` lies between `edges[i]` (the face's outgoing edge at
// the vertex) and `edges[i + 1]` (its incoming edge). Open fans start and
// end on boundary edges and have one face fewer than edges.
class Fan {
    edges: Array<EdgeId> = [];
    faces: Array<FaceId> = [];
    closed: bool = false;
}

function nonManifold(v: VertId): CoreError {
    return bad("vert " + v.toString() + " is non-manifold; bevel needs a single fan of faces around it");
}

function faceLoopAt(mesh: Mesh, f: FaceId, v: VertId): u32 {
    const l = mesh.faceLoopOf(f, v);
    if (l == NO_ID) panic("face lists the vert");
    return l;
}

function fanAround(mesh: Mesh, v: VertId): Result<Fan> {
    const edges = mesh.vertEdges(v);
    if (edges.length == 0) return Result.failWith<Fan>(bad("vert " + v.toString() + " has no edges"));
    const outFace = new Map<EdgeId, FaceId>();
    const inFace = new Map<EdgeId, FaceId>();
    const vf = mesh.vertFaces(v);
    for (let i = 0; i < vf.length; i++) {
        const f = vf[i];
        const l = faceLoopAt(mesh, f, v);
        const out = mesh.loops.at(l).edge;
        const inn = mesh.loops.at(mesh.loopPrev(l)).edge;
        if (outFace.has(out)) return Result.failWith<Fan>(nonManifold(v));
        outFace.set(out, f);
        if (inFace.has(inn)) return Result.failWith<Fan>(nonManifold(v));
        inFace.set(inn, f);
    }
    for (let i = 0; i < edges.length; i++) {
        const e = edges[i];
        if (!outFace.has(e) && !inFace.has(e)) {
            return Result.failWith<Fan>(
                bad("vert " + v.toString() + " has wire edge " + e.toString() + "; delete or fill it before beveling"),
            );
        }
    }
    const sorted = edges.slice(0);
    sortIds(sorted);
    let start = sorted[0];
    for (let i = 0; i < sorted.length; i++) {
        if (!inFace.has(sorted[i])) {
            start = sorted[i];
            break;
        }
    }
    const closed = inFace.has(start);
    const fan = new Fan();
    fan.edges.push(start);
    fan.closed = closed;
    let cur = start;
    while (outFace.has(cur)) {
        const f = outFace.get(cur);
        fan.faces.push(f);
        const l = faceLoopAt(mesh, f, v);
        const next = mesh.loops.at(mesh.loopPrev(l)).edge;
        if (next == start) break;
        if (fan.edges.includes(next)) return Result.failWith<Fan>(nonManifold(v));
        fan.edges.push(next);
        cur = next;
    }
    if (fan.edges.length != edges.length || (closed && fan.faces.length != fan.edges.length)) {
        return Result.failWith<Fan>(nonManifold(v));
    }
    return Result.okv<Fan>(fan);
}

function unitFrom(mesh: Mesh, v: VertId, e: EdgeId): Vec3 {
    const other = otherEnd(mesh, e, v);
    return (mesh.verts.at(other).co - mesh.verts.at(v).co).normalizeOrZero();
}

// Direction perpendicular to `e` within face `f`, pointing into the face.
function offsetDir(mesh: Mesh, f: FaceId, e: EdgeId, v: VertId): Vec3 {
    const along = unitFrom(mesh, v, e);
    const toward = mesh.faceCenter(f) - mesh.verts.at(v).co;
    return (toward - along * toward.dot(along)).normalizeOrZero();
}

// Distance along unbeveled edge `u` from `v` to where the offset line of
// beveled edge `bev` (in their shared face `f`) crosses it.
function onEdgeT(mesh: Mesh, v: VertId, f: FaceId, bev: EdgeId, u: EdgeId, w: f32): f32 {
    const d = offsetDir(mesh, f, bev, v);
    const s = unitFrom(mesh, v, u).dot(d);
    return s < <f32>1e-4 ? w : w / s;
}

// Where the offset lines of two beveled edges meet inside face `f`.
function meet(mesh: Mesh, v: VertId, f: FaceId, ea: EdgeId, eb: EdgeId, w: f32): Vec3 {
    const p = mesh.verts.at(v).co;
    const ua = unitFrom(mesh, v, ea);
    const ub = unitFrom(mesh, v, eb);
    const da = offsetDir(mesh, f, ea, v);
    const c = ua.dot(ub);
    const s = ub.dot(da);
    if (s < <f32>1e-4) return p + da * w;
    return p + da * w + ua * ((w * (<f32>1.0 + c)) / s);
}

// What `profilePoints` returns: the points and a center.
class ProfilePoints {
    pts: Array<Vec3> = [];
    center: Vec3 = VEC3_ZERO;
}

// Points of the circular profile between `a` and `b` at the end `v` of
// edge `e` (interior points only) and the arc's centre.
function profilePoints(mesh: Mesh, v: VertId, e: EdgeId, a: Vec3, b: Vec3, segments: u32): ProfilePoints {
    const p = mesh.verts.at(v).co;
    const along = unitFrom(mesh, v, e);
    const mid = (a + b) * <f32>0.5;
    const corner = p + along * (mid - p).dot(along);
    const center = a + b - corner;
    const ra = a - center;
    const rb = b - center;
    const curved = ra.cross(rb).length() > <f32>1e-5 * ra.length() * rb.length();
    const out = new ProfilePoints();
    for (let j: u32 = 1; j < segments; j++) {
        const t = <f32>j / <f32>segments;
        if (curved) {
            const ang = t * <f32>(Mathf.PI / 2);
            // cos and sin of one angle, as Apple's __sincosf_stret computes
            // them.
            const sc = appleSincosf(ang);
            out.pts.push(center + ra * sc.c + rb * sc.s);
        } else {
            out.pts.push(a.lerp(b, t));
        }
    }
    out.center = center;
    return out;
}

// An optional Vec3 (`Plan.profCenter`).
class CenterSlot {
    v: Vec3 = VEC3_ZERO;
}

// The rebuild plan for one vertex: which boundary vertex sits on each fan
// edge / inside each fan face, plus the profile interiors of beveled edges.
// `edgePt` / `facePt` hold NO_ID for none.
class Plan {
    v: VertId = 0;
    fan: Fan = new Fan();
    bev: Array<bool> = [];
    edgePt: Array<VertId> = [];
    facePt: Array<VertId> = [];
    interior: Array<Array<VertId>> = [];
    profCenter: Array<CenterSlot?> = [];
    // Blender's three-edge special case: no corner patch, the profile is
    // inserted into the face opposite the beveled edge.
    mNone: bool = false;

    slotCount(): i32 {
        return this.fan.edges.length + this.fan.faces.length;
    }

    slot(s: i32): VertId {
        return s % 2 == 0 ? this.edgePt[s / 2] : this.facePt[s / 2];
    }

    // Boundary vertex just before fan edge `i` (counter-clockwise).
    before(i: i32): VertId {
        const n = this.slotCount();
        let s = 2 * i;
        for (let it = 0; it < n; it++) {
            if (s == 0) {
                if (!this.fan.closed) return NO_ID;
                s = n;
            }
            s -= 1;
            const v = this.slot(s);
            if (v != NO_ID) return v;
        }
        return NO_ID;
    }

    // Boundary vertex just after fan edge `i`.
    after(i: i32): VertId {
        const n = this.slotCount();
        let s = 2 * i;
        for (let it = 0; it < n; it++) {
            s += 1;
            if (s >= n) {
                if (!this.fan.closed) return NO_ID;
                s = 0;
            }
            const v = this.slot(s);
            if (v != NO_ID) return v;
        }
        return NO_ID;
    }

    // Verts replacing `v` in fan face `i`, in that face's ring order
    // (incoming edge side first).
    replacement(i: i32): Array<VertId> {
        const k = this.fan.edges.length;
        const j = (i + 1) % k;
        const out: Array<VertId> = [];
        if (this.edgePt[j] != NO_ID) out.push(this.edgePt[j]);
        if (this.mNone && !this.bev[i] && !this.bev[j]) {
            const b = this.bev.indexOf(true);
            if (b < 0) panic("one beveled edge");
            const inner = this.interior[b];
            for (let q = 0; q < inner.length; q++) out.push(inner[q]);
        }
        if (this.facePt[i] != NO_ID) out.push(this.facePt[i]);
        if (this.edgePt[i] != NO_ID) out.push(this.edgePt[i]);
        return out;
    }

    // The closed boundary around `v` including profile interiors, counter-
    // clockwise; `flags` marks profile-interior verts.
    cornerRing(verts: Array<VertId>, flags: Array<bool>): void {
        for (let i = 0; i < this.fan.edges.length; i++) {
            const inner = this.interior[i];
            for (let q = 0; q < inner.length; q++) {
                verts.push(inner[q]);
                flags.push(true);
            }
            if (this.edgePt[i] != NO_ID) {
                verts.push(this.edgePt[i]);
                flags.push(false);
            }
            if (i < this.fan.faces.length && this.facePt[i] != NO_ID) {
                verts.push(this.facePt[i]);
                flags.push(false);
            }
        }
    }
}

// Farthest a point may slide along `e` from `v` without reaching the
// other end (or its own point when that end is beveled too).
function tMax(mesh: Mesh, v: VertId, e: EdgeId, bevelVerts: Set<VertId>): f32 {
    const other = otherEnd(mesh, e, v);
    const len = mesh.edgeLength(e);
    return bevelVerts.has(other) ? len * <f32>0.5 : len * <f32>0.999;
}

// Clamped width: never more than half the shortest edge around the bevel
// (a full edge when its far end does not move). The min does not depend on
// the iteration order.
function clampedWidth(mesh: Mesh, verts: Array<VertId>, vertSet: Set<VertId>, edges: Set<EdgeId>, width: f32): f32 {
    let w = width;
    for (let i = 0; i < verts.length; i++) {
        const v = verts[i];
        const es = mesh.vertEdges(v);
        for (let k = 0; k < es.length; k++) {
            const e = es[k];
            const other = otherEnd(mesh, e, v);
            const len = mesh.edgeLength(e);
            const limit = edges.has(e) || vertSet.has(other) ? len * <f32>0.5 : len;
            w = minF32(w, limit);
        }
    }
    return w;
}

// Corner patch faces for a closed boundary ring.
function cornerFaces(mesh: Mesh, plan: Plan, segments: u32, newVerts: Array<VertId>): Array<Array<VertId>> {
    const verts: Array<VertId> = [];
    const flags: Array<bool> = [];
    plan.cornerRing(verts, flags);
    const out: Array<Array<VertId>> = [];
    if (verts.length <= 2) return out;
    if (verts.length <= 4 || segments == 1) {
        out.push(verts);
        return out;
    }
    // Centre: on the sphere-ish surface the profile arcs suggest.
    const pts: Array<Vec3> = [];
    for (let i = 0; i < verts.length; i++) pts.push(mesh.verts.at(verts[i]).co);
    const mean = Vec3.sum(pts) / <f32>pts.length;
    const centers: Array<Vec3> = [];
    for (let i = 0; i < plan.profCenter.length; i++) {
        const c = plan.profCenter[i];
        if (c != null) centers.push(c.v);
    }
    let center: Vec3;
    if (centers.length == 0) {
        center = mean;
    } else {
        const s = Vec3.sum(centers) / <f32>centers.length;
        // The sum starts from -0.0, which adds exactly.
        let rsum: f32 = -0.0;
        for (let i = 0; i < pts.length; i++) rsum += pts[i].distance(s);
        const r = rsum / <f32>pts.length;
        const dir = mean - s;
        center = dir.length() < <f32>1e-6 ? mean : s + dir.normalize() * r;
    }
    const c = mesh.addVert(center);
    newVerts.push(c);
    const n = verts.length;
    let firstAnchor = flags.indexOf(false);
    if (firstAnchor < 0) firstAnchor = 0;
    let alternating = segments == 2 && n % 2 == 0;
    if (alternating) {
        for (let i = 0; i < n; i++) {
            if (flags[i] != (i % 2 != firstAnchor % 2)) {
                alternating = false;
                break;
            }
        }
    }
    if (alternating) {
        for (let q = 0; q < n / 2; q++) {
            const a = (firstAnchor + 2 * q) % n;
            out.push([verts[(a + n - 1) % n], verts[a], verts[(a + 1) % n], c]);
        }
    } else {
        for (let i = 0; i < n; i++) out.push([verts[i], verts[(i + 1) % n], c]);
    }
    return out;
}

// A new face ring and the face it copies.
class NewFace {
    ring: Array<VertId>;
    like: FaceId;
    constructor(ring: Array<VertId>, like: FaceId) {
        this.ring = ring;
        this.like = like;
    }
}

// The replacement edge's ends and the marks.
class MarkCarry {
    a: VertId;
    b: VertId;
    src: Edge;
    constructor(a: VertId, b: VertId, src: Edge) {
        this.a = a;
        this.b = b;
        this.src = src;
    }
}

function faceVertKey(f: FaceId, v: VertId): u64 {
    return ((<u64>f) << 32) | <u64>v;
}

// Apply the plans: re-point the faces around every planned vertex, add
// the strip and corner faces, remove the old vertices. Returns the new
// faces.
function commit(mesh: Mesh, plans: Array<Plan>, strips: Array<NewFace>, segments: u32, newVerts: Array<VertId>): Result<Array<FaceId>> {
    const byVert = new Map<VertId, i32>();
    for (let i = 0; i < plans.length; i++) byVert.set(plans[i].v, i);
    const repl = new Map<u64, Array<VertId>>();
    const affected: Array<FaceId> = [];
    for (let p = 0; p < plans.length; p++) {
        const plan = plans[p];
        for (let i = 0; i < plan.fan.faces.length; i++) {
            const f = plan.fan.faces[i];
            repl.set(faceVertKey(f, plan.v), plan.replacement(i));
            affected.push(f);
        }
    }
    sortIds(affected);
    dedup<u32>(affected);
    const ringFaces: Array<FaceId> = [];
    const rings: Array<Array<VertId>> = [];
    for (let a = 0; a < affected.length; a++) {
        const f = affected[a];
        const fv = mesh.faceVerts(f);
        const ring: Array<VertId> = [];
        for (let i = 0; i < fv.length; i++) {
            const key = faceVertKey(f, fv[i]);
            if (repl.has(key)) {
                const r = repl.get(key);
                for (let q = 0; q < r.length; q++) ring.push(r[q]);
            } else {
                ring.push(fv[i]);
            }
        }
        const distinct = ring.slice(0);
        sortIds(distinct);
        dedup<u32>(distinct);
        if (ring.length < 3 || distinct.length != ring.length) {
            for (let i = 0; i < newVerts.length; i++) mesh.removeVert(newVerts[i]);
            return Result.failWith<Array<FaceId>>(
                bad("beveling would make face " + f.toString() + " degenerate; use a smaller width"),
            );
        }
        ringFaces.push(f);
        rings.push(ring);
    }
    // Marks of unbeveled edges carry over to the edges that replace them.
    const marks: Array<MarkCarry> = [];
    for (let pi = 0; pi < plans.length; pi++) {
        const plan = plans[pi];
        for (let i = 0; i < plan.fan.edges.length; i++) {
            const e = plan.fan.edges[i];
            const p = plan.edgePt[i];
            if (p == NO_ID || plan.bev[i]) continue;
            const other = otherEnd(mesh, e, plan.v);
            let far = other;
            if (byVert.has(other)) {
                const op = plans[byVert.get(other)];
                const k = op.fan.edges.indexOf(e);
                if (k >= 0 && op.edgePt[k] != NO_ID) far = op.edgePt[k];
            }
            marks.push(new MarkCarry(p, far, mesh.edges.at(e).clone()));
        }
    }
    const corners: Array<NewFace> = [];
    for (let pi = 0; pi < plans.length; pi++) {
        const plan = plans[pi];
        if (!plan.fan.closed || plan.mNone) continue;
        const like = plan.fan.faces[0];
        const cf = cornerFaces(mesh, plan, segments, newVerts);
        for (let i = 0; i < cf.length; i++) corners.push(new NewFace(cf[i], like));
    }
    for (let i = 0; i < ringFaces.length; i++) mesh.setFaceVerts(ringFaces[i], rings[i]);
    const newFaces: Array<FaceId> = [];
    for (let i = 0; i < strips.length; i++) newFaces.push(mesh.addFaceLike(strips[i].ring, strips[i].like));
    for (let i = 0; i < corners.length; i++) newFaces.push(mesh.addFaceLike(corners[i].ring, corners[i].like));
    for (let pi = 0; pi < plans.length; pi++) mesh.removeVert(plans[pi].v);
    for (let i = 0; i < marks.length; i++) {
        const m = marks[i];
        const e = mesh.findEdge(m.a, m.b);
        if (e != NO_ID) mesh.edges.at(e).copyMarks(m.src);
    }
    const touched = affected;
    for (let i = 0; i < newFaces.length; i++) touched.push(newFaces[i]);
    mesh.recalcFaceNormals(touched);
    return Result.okv<Array<FaceId>>(newFaces);
}

function checkOpts(opts: BevelOpts): Result<Array<string>> {
    if (opts.width <= 0.0 || !isFinite<f32>(opts.width)) {
        return Result.failWith<Array<string>>(bad("bevel width must be positive"));
    }
    if (opts.segments == 0) return Result.failWith<Array<string>>(bad("--segments must be at least 1"));
    const warnings: Array<string> = [];
    if (Mathf.abs(opts.profile - <f32>0.5) > <f32>1e-6) {
        warnings.push("profile " + displayF32(opts.profile) + " is not supported yet; using the circular profile 0.5");
    }
    return Result.okv<Array<string>>(warnings);
}

// Removes every new vertex (roll back) and returns the error.
function rollBack(mesh: Mesh, newVerts: Array<VertId>): void {
    for (let i = 0; i < newVerts.length; i++) mesh.removeVert(newVerts[i]);
}

// The anchors and interior of edge `e` at the
// plan's vertex.
function profileAt(plan: Plan, e: EdgeId): Array<VertId> {
    const i = plan.fan.edges.indexOf(e);
    if (i < 0) panic("edge in fan");
    const l = plan.before(i);
    if (l == NO_ID) panic("anchor");
    const out: Array<VertId> = [l];
    const inner = plan.interior[i];
    for (let q = 0; q < inner.length; q++) out.push(inner[q]);
    const r = plan.after(i);
    if (r == NO_ID) panic("anchor");
    out.push(r);
    return out;
}

function emptyPlan(v: VertId, fan: Fan): Plan {
    const k = fan.edges.length;
    const plan = new Plan();
    plan.v = v;
    plan.fan = fan;
    for (let i = 0; i < k; i++) {
        plan.bev.push(false);
        plan.edgePt.push(NO_ID);
        plan.interior.push([]);
        plan.profCenter.push(null);
    }
    for (let i = 0; i < fan.faces.length; i++) plan.facePt.push(NO_ID);
    return plan;
}

// Bevel the given edges of `mesh` (the modifier and the operator both call
// this). See the module docs for the construction and its limits.
export function bevelEdges(mesh: Mesh, edges: Array<EdgeId>, opts: BevelOpts): Result<BevelResult> {
    const rw = checkOpts(opts);
    if (!rw.ok) return rw.forward<BevelResult>();
    const warnings = rw.value;
    const edgeSet = new Set<EdgeId>();
    const sortedEdges: Array<EdgeId> = [];
    for (let i = 0; i < edges.length; i++) {
        const e = edges[i];
        if (mesh.edges.contains(e) && !edgeSet.has(e)) {
            edgeSet.add(e);
            sortedEdges.push(e);
        }
    }
    if (sortedEdges.length == 0) return Result.failWith<BevelResult>(nothingSelected(ElemKind.Edge));
    sortIds(sortedEdges);
    for (let i = 0; i < sortedEdges.length; i++) {
        const e = sortedEdges[i];
        const faces = mesh.edgeFaces(e);
        if (faces.length != 2 || mesh.faceWalksEdgeForward(faces[0], e) == mesh.faceWalksEdgeForward(faces[1], e)) {
            return Result.failWith<BevelResult>(
                bad(
                    "edge " +
                        e.toString() +
                        " is a boundary or non-manifold edge; bevel needs manifold interior edges with consistent normals",
                ),
            );
        }
    }
    const vertSet = new Set<VertId>();
    const verts: Array<VertId> = [];
    for (let i = 0; i < sortedEdges.length; i++) {
        const ed = mesh.edges.at(sortedEdges[i]);
        const a = ed.v[0];
        const b = ed.v[1];
        if (!vertSet.has(a)) {
            vertSet.add(a);
            verts.push(a);
        }
        if (!vertSet.has(b)) {
            vertSet.add(b);
            verts.push(b);
        }
    }
    sortIds(verts);
    const fans: Array<Fan> = [];
    for (let i = 0; i < verts.length; i++) {
        const v = verts[i];
        const rf = fanAround(mesh, v);
        if (!rf.ok) return rf.forward<BevelResult>();
        const fan = rf.value;
        if (fan.closed && fan.edges.length < 3) {
            return Result.failWith<BevelResult>(
                bad(
                    "vert " +
                        v.toString() +
                        " has only " +
                        fan.edges.length.toString() +
                        " edges; bevel needs at least three around a closed fan",
                ),
            );
        }
        fans.push(fan);
    }
    const w = opts.clamp ? clampedWidth(mesh, verts, vertSet, edgeSet, opts.width) : opts.width;
    if (w <= <f32>1e-6) {
        return Result.failWith<BevelResult>(bad("the clamped bevel width is zero (a zero-length edge touches the bevel)"));
    }
    const newVerts: Array<VertId> = [];
    const plans: Array<Plan> = [];
    for (let vi = 0; vi < verts.length; vi++) {
        const v = verts[vi];
        const fan = fans[vi];
        const k = fan.edges.length;
        const p = mesh.verts.at(v).co;
        const plan = emptyPlan(v, fan);
        let bevCount = 0;
        for (let i = 0; i < k; i++) {
            plan.bev[i] = edgeSet.has(fan.edges[i]);
            if (plan.bev[i]) bevCount++;
        }
        const bev = plan.bev;
        plan.mNone = fan.closed && k == 3 && bevCount == 1;
        for (let i = 0; i < k; i++) {
            if (bev[i]) continue;
            const e = fan.edges[i];
            const ts: Array<f32> = [];
            if (i > 0 || fan.closed) {
                const j = (i + k - 1) % k;
                if (bev[j]) ts.push(onEdgeT(mesh, v, fan.faces[j], fan.edges[j], e, w));
            }
            if (i + 1 < k || fan.closed) {
                const j = (i + 1) % k;
                if (bev[j]) ts.push(onEdgeT(mesh, v, fan.faces[i], fan.edges[j], e, w));
            }
            const boundaryEnd = !fan.closed && (i == 0 || i + 1 == k);
            let t: f32;
            if (ts.length == 0) {
                if (boundaryEnd) continue;
                t = w;
            } else {
                // The sum starts from -0.0, which adds exactly.
                let sum: f32 = -0.0;
                for (let q = 0; q < ts.length; q++) sum += ts[q];
                t = sum / <f32>ts.length;
            }
            t = minF32(t, tMax(mesh, v, e, vertSet));
            const nv = mesh.addVert(p + unitFrom(mesh, v, e) * t);
            newVerts.push(nv);
            plan.edgePt[i] = nv;
        }
        for (let i = 0; i < fan.faces.length; i++) {
            const j = (i + 1) % k;
            if (bev[i] && bev[j]) {
                const nv = mesh.addVert(meet(mesh, v, fan.faces[i], fan.edges[i], fan.edges[j], w));
                newVerts.push(nv);
                plan.facePt[i] = nv;
            }
        }
        for (let i = 0; i < k; i++) {
            if (!plan.bev[i]) continue;
            const l = plan.before(i);
            const r = plan.after(i);
            if (l == NO_ID || r == NO_ID) {
                rollBack(mesh, newVerts);
                return Result.failWith<BevelResult>(
                    bad(
                        "edge " +
                            plan.fan.edges[i].toString() +
                            " ends on boundary vert " +
                            v.toString() +
                            "; bevel needs interior vertices",
                    ),
                );
            }
            const pp = profilePoints(mesh, v, plan.fan.edges[i], mesh.verts.at(l).co, mesh.verts.at(r).co, opts.segments);
            const ids: Array<VertId> = [];
            for (let q = 0; q < pp.pts.length; q++) ids.push(mesh.addVert(pp.pts[q]));
            for (let q = 0; q < ids.length; q++) newVerts.push(ids[q]);
            plan.interior[i] = ids;
            const cs = new CenterSlot();
            cs.v = pp.center;
            plan.profCenter[i] = cs;
        }
        plans.push(plan);
    }
    // Strips: profile at one end paired with the reversed profile at the
    // other, so quad j joins the same two faces on both sides.
    const byVert = new Map<VertId, i32>();
    for (let i = 0; i < plans.length; i++) byVert.set(plans[i].v, i);
    const strips: Array<NewFace> = [];
    for (let s = 0; s < sortedEdges.length; s++) {
        const e = sortedEdges[s];
        const ed = mesh.edges.at(e);
        const a = ed.v[0];
        const b = ed.v[1];
        const pa = profileAt(plans[byVert.get(a)], e);
        const pb = profileAt(plans[byVert.get(b)], e);
        pb.reverse();
        const like = mesh.edgeFaces(e)[0];
        for (let j = 0; j < <i32>opts.segments; j++) {
            strips.push(new NewFace([pa[j], pb[j], pb[j + 1], pa[j + 1]], like));
        }
    }
    const rc = commit(mesh, plans, strips, opts.segments, newVerts);
    if (!rc.ok) return rc.forward<BevelResult>();
    mesh.debugValidate();
    const out = new BevelResult();
    out.newFaces = rc.value;
    out.warnings = warnings;
    out.newVerts = newVerts;
    return Result.okv<BevelResult>(out);
}

// Vertex-only bevel: every selected vertex is cut back by `width` along
// each of its edges and the cut is closed with one face.
export function bevelVerts(mesh: Mesh, verts: Array<VertId>, opts: BevelOpts): Result<BevelResult> {
    const rw = checkOpts(opts);
    if (!rw.ok) return rw.forward<BevelResult>();
    const warnings = rw.value;
    const vertSet = new Set<VertId>();
    const sorted: Array<VertId> = [];
    for (let i = 0; i < verts.length; i++) {
        const v = verts[i];
        if (mesh.verts.contains(v) && !vertSet.has(v)) {
            vertSet.add(v);
            sorted.push(v);
        }
    }
    if (sorted.length == 0) return Result.failWith<BevelResult>(nothingSelected(ElemKind.Vert));
    sortIds(sorted);
    const fans: Array<Fan> = [];
    for (let i = 0; i < sorted.length; i++) {
        const v = sorted[i];
        const rf = fanAround(mesh, v);
        if (!rf.ok) return rf.forward<BevelResult>();
        const fan = rf.value;
        if (fan.edges.length < (fan.closed ? 3 : 2)) {
            return Result.failWith<BevelResult>(
                bad("vert " + v.toString() + " has too few edges to bevel (" + fan.edges.length.toString() + ")"),
            );
        }
        fans.push(fan);
    }
    const w = opts.clamp ? clampedWidth(mesh, sorted, vertSet, new Set<EdgeId>(), opts.width) : opts.width;
    if (w <= <f32>1e-6) {
        return Result.failWith<BevelResult>(bad("the clamped bevel width is zero (a zero-length edge touches the bevel)"));
    }
    const newVerts: Array<VertId> = [];
    const plans: Array<Plan> = [];
    for (let vi = 0; vi < sorted.length; vi++) {
        const v = sorted[vi];
        const fan = fans[vi];
        const p = mesh.verts.at(v).co;
        const plan = emptyPlan(v, fan);
        for (let i = 0; i < fan.edges.length; i++) {
            const e = fan.edges[i];
            const t = minF32(w, tMax(mesh, v, e, vertSet));
            const nv = mesh.addVert(p + unitFrom(mesh, v, e) * t);
            newVerts.push(nv);
            plan.edgePt[i] = nv;
        }
        plans.push(plan);
    }
    const rc = commit(mesh, plans, [], 1, newVerts);
    if (!rc.ok) return rc.forward<BevelResult>();
    mesh.debugValidate();
    const out = new BevelResult();
    out.newFaces = rc.value;
    out.warnings = warnings;
    out.newVerts = newVerts;
    return Result.okv<BevelResult>(out);
}

// Operator entry point: bevels the selected edges (or vertices with
// `vertexOnly`) of the edited mesh and selects what it made.
export function bevel(scene: Scene, opts: BevelOpts, vertexOnly: bool): Result<OpReport> {
    const rm = editMesh(scene, "bevel");
    if (!rm.ok) return rm.forward<OpReport>();
    const mesh = rm.value;
    let result: BevelResult;
    let what: string;
    if (vertexOnly) {
        const rs = requireSelected(mesh, ElemKind.Vert);
        if (!rs.ok) return rs.forward<OpReport>();
        const r = bevelVerts(mesh, rs.value, opts);
        if (!r.ok) return r.forward<OpReport>();
        result = r.value;
        what = vertices(rs.value.length);
    } else {
        const rs = requireSelected(mesh, ElemKind.Edge);
        if (!rs.ok) return rs.forward<OpReport>();
        const r = bevelEdges(mesh, rs.value, opts);
        if (!r.ok) return r.forward<OpReport>();
        result = r.value;
        what = plural(rs.value.length, "edge");
    }
    if (result.newFaces.length == 0) {
        mesh.setSelection(ElemKind.Vert, result.newVerts);
    } else {
        mesh.setSelection(ElemKind.Face, result.newFaces);
    }
    mesh.debugValidate();
    const report = meshReport("Beveled " + what, mesh);
    for (let i = 0; i < result.warnings.length; i++) report.warn(result.warnings[i]);
    return Result.okv<OpReport>(report);
}
