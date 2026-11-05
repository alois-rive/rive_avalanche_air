// Dissolve (Ctrl+X): remove verts / edges /
// faces while keeping the surface, plus limited dissolve by angle. Kernel
// errors on non-manifold input become warnings so one bad element does not
// abort the rest.
//
// Two Blender behaviours the kernel primitives do not provide directly
// live here: a 2-valence vertex is dissolved by merging its two edges
// (`BM_vert_collapse_edge`, faces keep their count), and a group of faces
// is joined even when neighbours share several edges (the interior vertex
// between the shared edges is dissolved, which merges the pair).

import { toRadians } from "../../../base/vecmath";
import { Result, panic, dedup, swapRemove, clampF32 } from "../../../base/util";
import { CoreError } from "../../../base/error";
import { OpReport, plural } from "../../../base/report";
import { Mesh, ElemKind, EdgeId, FaceId, VertId, NO_ID } from "../mesh/mod";
import { Scene } from "../scene";
import { appleAcosf } from "../../../base/libm";
import { editMesh, requireSelected, meshReport } from "./mod";

export enum DissolveKind {
    Vert,
    Edge,
    Face,
    Limited,
}

export namespace DissolveKind {
    // The variant named by `s`, or -1 when none matches.
    export function parse(s: string): i32 {
        if (s == "vert" || s == "verts" || s == "vertex" || s == "vertices") return DissolveKind.Vert;
        if (s == "edge" || s == "edges") return DissolveKind.Edge;
        if (s == "face" || s == "faces") return DissolveKind.Face;
        if (s == "limited") return DissolveKind.Limited;
        return -1;
    }
}

export class DissolveOpts {
    kind: DissolveKind = DissolveKind.Edge;
    // Limited dissolve: maximum angle (degrees) between faces / edges.
    angleDeg: f32 = 5.0;
    // Edge dissolve: also dissolve the end verts left with two edges
    // (Blender's "Dissolve Vertices" option, on by default).
    useVerts: bool = true;

    static of(kind: DissolveKind): DissolveOpts {
        const o = new DissolveOpts();
        o.kind = kind;
        return o;
    }

    clone(): DissolveOpts {
        const o = new DissolveOpts();
        o.kind = this.kind;
        o.angleDeg = this.angleDeg;
        o.useVerts = this.useVerts;
        return o;
    }
}

// What was dissolved plus collected kernel warnings. `verts`/`edges`/
// `faces` count input elements dissolved; `regions` counts the ngons a
// face dissolve produced.
export class Dissolved {
    verts: i32 = 0;
    edges: i32 = 0;
    faces: i32 = 0;
    regions: i32 = 0;
    warnings: Array<string> = [];

    warn(msg: string): void {
        this.warnings.push(msg);
    }

    finish(): Dissolved {
        if (this.warnings.length > MAX_WARNINGS) {
            const extra = this.warnings.length - MAX_WARNINGS;
            this.warnings.length = MAX_WARNINGS;
            this.warnings.push("... and " + extra.toString() + " more");
        }
        return this;
    }
}

const MAX_WARNINGS: i32 = 5;

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

export function dissolve(scene: Scene, opts: DissolveOpts): Result<OpReport> {
    const rm = editMesh(scene, "dissolve");
    if (!rm.ok) return rm.forward<OpReport>();
    const mesh = rm.value;
    let d: Dissolved;
    switch (opts.kind) {
        case DissolveKind.Vert: {
            const r = requireSelected(mesh, ElemKind.Vert);
            if (!r.ok) return r.forward<OpReport>();
            d = dissolveVerts(mesh, r.value);
            break;
        }
        case DissolveKind.Edge: {
            const r = requireSelected(mesh, ElemKind.Edge);
            if (!r.ok) return r.forward<OpReport>();
            d = dissolveEdges(mesh, r.value, opts.useVerts);
            break;
        }
        case DissolveKind.Face: {
            const r = requireSelected(mesh, ElemKind.Face);
            if (!r.ok) return r.forward<OpReport>();
            d = dissolveFaces(mesh, r.value);
            break;
        }
        default: {
            const r = requireSelected(mesh, ElemKind.Vert);
            if (!r.ok) return r.forward<OpReport>();
            d = dissolveLimited(mesh, r.value, toRadians(opts.angleDeg));
            break;
        }
    }
    mesh.debugValidate();
    let msg: string;
    switch (opts.kind) {
        case DissolveKind.Vert:
            msg = "Dissolved " + plural(d.verts, "vert");
            break;
        case DissolveKind.Edge:
            msg = "Dissolved " + plural(d.edges, "edge");
            break;
        case DissolveKind.Face:
            msg = "Dissolved " + plural(d.faces, "face") + " into " + plural(d.regions, "ngon");
            break;
        default:
            msg = "Dissolved " + plural(d.edges, "edge") + " and " + plural(d.verts, "vert");
            break;
    }
    const report = meshReport(msg, mesh);
    for (let i = 0; i < d.warnings.length; i++) report.warn(d.warnings[i]);
    return Result.okv<OpReport>(report);
}

// Dissolve one vertex the way Blender does: a 2-valence vertex merges its
// two edges, anything else joins the fan of faces around it.
export function dissolveOneVert(mesh: Mesh, v: VertId): Result<bool> {
    if (mesh.vertEdges(v).length == 2) return joinEdgesAt(mesh, v);
    return mesh.dissolveVert(v);
}

// Remove a 2-valence vertex by merging its two edges into one
// (`BM_vert_collapse_edge`). Faces on it lose the corner; a triangle
// would degenerate and is removed instead.
export function joinEdgesAt(mesh: Mesh, v: VertId): Result<bool> {
    const edges = mesh.vertEdges(v).slice(0);
    if (edges.length != 2) {
        return Result.failWith<bool>(
            bad("vert " + v.toString() + " has " + edges.length.toString() + " edges; joining edges needs exactly two"),
        );
    }
    const a = otherEnd(mesh, edges[0], v);
    const b = otherEnd(mesh, edges[1], v);
    if (a == b) {
        return Result.failWith<bool>(bad("vert " + v.toString() + " sits on a loop edge; cannot dissolve"));
    }
    const faces = mesh.vertFaces(v);
    if (faces.length == 0) return mesh.dissolveVert(v);
    const marks = mesh.edges.at(edges[0]).clone();
    marks.select = marks.select || mesh.edges.at(edges[1]).select;
    const kill: Array<FaceId> = [];
    const rebuildFaces: Array<FaceId> = [];
    const rebuildRings: Array<Array<VertId>> = [];
    for (let i = 0; i < faces.length; i++) {
        const f = faces[i];
        const all = mesh.faceVerts(f);
        const ring: Array<VertId> = [];
        for (let k = 0; k < all.length; k++) {
            if (all[k] != v) ring.push(all[k]);
        }
        if (ring.length < 3) {
            kill.push(f);
        } else {
            rebuildFaces.push(f);
            rebuildRings.push(ring);
        }
    }
    mesh.deleteFaces(kill);
    for (let i = 0; i < rebuildFaces.length; i++) mesh.setFaceVerts(rebuildFaces[i], rebuildRings[i]);
    mesh.removeVert(v);
    const e = mesh.addEdge(a, b);
    const dst = mesh.edges.at(e);
    dst.copyMarks(marks);
    dst.select = dst.select || marks.select;
    return Result.okv<bool>(true);
}

export function dissolveVerts(mesh: Mesh, verts: Array<VertId>): Dissolved {
    const d = new Dissolved();
    for (let i = 0; i < verts.length; i++) {
        const v = verts[i];
        if (!mesh.verts.contains(v)) continue;
        const r = dissolveOneVert(mesh, v);
        if (r.ok) d.verts += 1;
        else d.warn(r.err);
    }
    mesh.flushSelection(ElemKind.Vert);
    return d.finish();
}

export function dissolveEdges(mesh: Mesh, edges: Array<EdgeId>, useVerts: bool): Dissolved {
    const d = new Dissolved();
    const ends: Array<VertId> = [];
    for (let i = 0; i < edges.length; i++) {
        const e = edges[i];
        if (!mesh.edges.contains(e)) continue;
        const ed = mesh.edges.at(e);
        const va = ed.v[0];
        const vb = ed.v[1];
        const r = mesh.dissolveEdge(e);
        if (r.ok) {
            d.edges += 1;
            ends.push(va);
            ends.push(vb);
        } else {
            d.warn(r.err);
        }
    }
    if (useVerts) {
        sortIds(ends);
        dedup<u32>(ends);
        for (let i = 0; i < ends.length; i++) {
            const v = ends[i];
            if (mesh.verts.contains(v) && mesh.vertEdges(v).length == 2) {
                const r = joinEdgesAt(mesh, v);
                if (r.ok) d.verts += 1;
                else d.warn(r.err);
            }
        }
    }
    mesh.flushSelection(ElemKind.Face);
    return d.finish();
}

// The surviving face and the merged count of `joinRegion`.
class JoinedRegion {
    survivor: FaceId = 0;
    merged: i32 = 0;
}

// Join a group of faces into one ngon. Pairs sharing exactly one edge are
// joined directly; pairs sharing several edges are merged by dissolving
// the vertex between those edges. Returns the surviving face and how many
// faces were merged into it.
function joinRegion(mesh: Mesh, group: Array<FaceId>, d: Dissolved): JoinedRegion {
    let survivor = group[0];
    const pending = group.slice(1);
    let merged = 1;
    const stuck: Array<FaceId> = [];
    while (true) {
        let pos = -1;
        for (let i = 0; i < pending.length; i++) {
            const g = pending[i];
            if (mesh.faces.contains(g) && mesh.sharedEdge(survivor, g) != NO_ID) {
                pos = i;
                break;
            }
        }
        if (pos < 0) break;
        const f = swapRemove<u32>(pending, pos);
        const shared: Array<EdgeId> = [];
        const fe = mesh.faceEdges(survivor);
        for (let i = 0; i < fe.length; i++) {
            if (mesh.edgeFaces(fe[i]).includes(f)) shared.push(fe[i]);
        }
        let result: Result<bool>;
        if (shared.length == 1) {
            const r = mesh.joinFaces(survivor, f);
            result = r.ok ? Result.okv<bool>(true) : r.forward<bool>();
        } else {
            // The vertex where two shared edges meet lies inside the union
            // of the two faces: dissolving it merges them.
            const verts: Array<VertId> = [];
            for (let i = 0; i < shared.length; i++) {
                const ed = mesh.edges.at(shared[i]);
                verts.push(ed.v[0]);
                verts.push(ed.v[1]);
            }
            sortIds(verts);
            let inner: VertId = NO_ID;
            for (let i = 0; i + 1 < verts.length; i++) {
                if (verts[i] == verts[i + 1]) {
                    const cand = verts[i];
                    const vf = mesh.vertFaces(cand);
                    let all = true;
                    for (let k = 0; k < vf.length; k++) {
                        if (vf[k] != survivor && vf[k] != f) {
                            all = false;
                            break;
                        }
                    }
                    if (all) inner = cand;
                    break;
                }
            }
            if (inner != NO_ID) {
                result = mesh.dissolveVert(inner);
            } else {
                result = Result.failWith<bool>(
                    bad(
                        "faces " +
                            survivor.toString() +
                            " and " +
                            f.toString() +
                            " share " +
                            shared.length.toString() +
                            " edges with no vertex between them",
                    ),
                );
            }
        }
        if (result.ok) {
            merged += 1;
            if (!mesh.faces.contains(survivor)) survivor = f;
        } else {
            d.warn(result.err);
            stuck.push(f);
        }
    }
    for (let i = 0; i < pending.length; i++) {
        d.warn("face " + pending[i].toString() + " shares no edge with face " + survivor.toString() + "; not dissolved");
    }
    const out = new JoinedRegion();
    out.survivor = survivor;
    out.merged = merged;
    return out;
}

// Join every group of edge-connected selected faces into one ngon.
export function dissolveFaces(mesh: Mesh, faces: Array<FaceId>): Dissolved {
    const d = new Dissolved();
    const sel = new Set<FaceId>();
    const sorted: Array<FaceId> = [];
    for (let i = 0; i < faces.length; i++) {
        const f = faces[i];
        if (mesh.faces.contains(f) && !sel.has(f)) {
            sel.add(f);
            sorted.push(f);
        }
    }
    sortIds(sorted);
    const done = new Set<FaceId>();
    for (let s = 0; s < sorted.length; s++) {
        const start = sorted[s];
        if (done.has(start) || !mesh.faces.contains(start)) continue;
        const linked = mesh.linkedFaces(start, (e: EdgeId): bool => {
            const fs = mesh.edgeFaces(e);
            for (let k = 0; k < fs.length; k++) {
                if (!sel.has(fs[k])) return false;
            }
            return true;
        });
        const group: Array<FaceId> = [];
        for (let i = 0; i < linked.length; i++) {
            if (sel.has(linked[i])) group.push(linked[i]);
        }
        for (let i = 0; i < group.length; i++) done.add(group[i]);
        if (group.length < 2) continue;
        const jr = joinRegion(mesh, group, d);
        if (jr.merged > 1) {
            d.faces += jr.merged;
            d.regions += 1;
        }
    }
    mesh.flushSelection(ElemKind.Face);
    return d.finish();
}

// Limited dissolve over the selected verts: faces meeting at less than
// `maxAngle` across an edge are joined region by region, then verts left
// on two nearly collinear edges are dissolved. Counts are elements removed.
export function dissolveLimited(mesh: Mesh, verts: Array<VertId>, maxAngle: f32): Dissolved {
    const d = new Dissolved();
    const beforeVerts = mesh.verts.len();
    const beforeEdges = mesh.edges.len();
    const vset = new Set<VertId>();
    const cands: Array<VertId> = [];
    for (let i = 0; i < verts.length; i++) {
        if (!vset.has(verts[i])) {
            vset.add(verts[i]);
            cands.push(verts[i]);
        }
    }
    const faces: Array<FaceId> = [];
    const ids = mesh.faces.ids();
    for (let i = 0; i < ids.length; i++) {
        const fv = mesh.faceVerts(ids[i]);
        let all = true;
        for (let k = 0; k < fv.length; k++) {
            if (!vset.has(fv[k])) {
                all = false;
                break;
            }
        }
        if (all) faces.push(ids[i]);
    }
    sortIds(faces);
    const done = new Set<FaceId>();
    for (let s = 0; s < faces.length; s++) {
        const start = faces[s];
        if (done.has(start) || !mesh.faces.contains(start)) continue;
        const group = mesh.linkedFaces(start, (e: EdgeId): bool => {
            const ed = mesh.edges.at(e);
            const a = ed.v[0];
            const b = ed.v[1];
            if (!vset.has(a) || !vset.has(b)) return false;
            // NaN means no angle; `angle <= maxAngle` is false for it.
            const angle = mesh.edgeFaceAngle(e);
            return mesh.edgeFaces(e).length == 2 && angle <= maxAngle;
        });
        for (let i = 0; i < group.length; i++) done.add(group[i]);
        if (group.length >= 2) joinRegion(mesh, group, d);
    }
    sortIds(cands);
    for (let i = 0; i < cands.length; i++) {
        const v = cands[i];
        if (!mesh.verts.contains(v)) continue;
        const es = mesh.vertEdges(v);
        if (es.length != 2) continue;
        const a = otherEnd(mesh, es[0], v);
        const b = otherEnd(mesh, es[1], v);
        const co = mesh.verts.at(v).co;
        const da = (mesh.verts.at(a).co - co).normalizeOrZero();
        const db = (mesh.verts.at(b).co - co).normalizeOrZero();
        // Straight when the two edges point in opposite directions.
        // `appleAcosf` reproduces Apple's acosf: acosf(-1) is one ulp below PI,
        // so exactly collinear edges deviate by 2.4e-7.
        const deviation = Mathf.PI - appleAcosf(clampF32(da.dot(db), -1.0, 1.0));
        if (deviation <= maxAngle) {
            const r = joinEdgesAt(mesh, v);
            if (!r.ok) d.warn(r.err);
        }
    }
    d.verts = beforeVerts - mesh.verts.len();
    d.edges = beforeEdges - mesh.edges.len();
    mesh.flushSelection(ElemKind.Face);
    return d.finish();
}
