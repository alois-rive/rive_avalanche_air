// Triangulate, tris to quads
// (Ctrl+T / Alt+J).

import { Result, clampF32, minF32, maxF32, panic, stableSort, totalCmpF32 } from "../../../base/util";
import { Vec2, Vec3, toRadians } from "../../../base/vecmath";
import { appleAcosf } from "../../../base/libm";
import { CoreError } from "../../../base/error";
import { OpReport, plural } from "../../../base/report";
import { Mesh, ElemKind, VertId, EdgeId, FaceId, LoopId, NO_ID } from "../mesh/mod";
import { Scene } from "../scene";
import { editMesh, meshReport, requireSelected } from "./mod";

// Triangulation method (default: Beauty).
export enum TriangulateMethod {
    Beauty = 0,
    Fixed = 1,
}

export namespace TriangulateMethod {
    // The variant named by `s`, or -1 when none matches.
    export function parse(s: string): i32 {
        if (s == "beauty") return TriangulateMethod.Beauty;
        if (s == "fixed" || s == "clip") return TriangulateMethod.Fixed;
        return -1;
    }
}

// Uses `appleAcosf` (what vecmath's `acosf` is), which reproduces Apple's
// acosf bit for bit and is not correctly rounded. A one-ulp difference flips
// `angle > faceThr` and the candidate order in tris-to-quads (golden cases
// `xt2q.hinge.*`).
function cornerAngle(prev: Vec3, at: Vec3, next: Vec3): f32 {
    const a = (prev - at).normalizeOrZero();
    const b = (next - at).normalizeOrZero();
    return appleAcosf(clampF32(a.dot(b), -1, 1));
}

// Smallest corner angle over a set of triangles (each 3 vertex ids).
function minAngle(mesh: Mesh, tris: Array<StaticArray<VertId>>): f32 {
    let acc: f32 = f32.MAX_VALUE;
    for (let t = 0; t < tris.length; t++) {
        const tri = tris[t];
        const p0 = mesh.verts.at(tri[0]).co;
        const p1 = mesh.verts.at(tri[1]).co;
        const p2 = mesh.verts.at(tri[2]).co;
        acc = minF32(acc, cornerAngle(p2, p0, p1));
        acc = minF32(acc, cornerAngle(p0, p1, p2));
        acc = minF32(acc, cornerAngle(p1, p2, p0));
    }
    return acc;
}

function tri3(a: VertId, b: VertId, c: VertId): StaticArray<VertId> {
    const t = new StaticArray<VertId>(3);
    t[0] = a;
    t[1] = b;
    t[2] = c;
    return t;
}

// Triangles for one face as vertex ids. Beauty picks, on quads, the diagonal
// whose two triangles have the larger minimum angle (both diagonals must be
// valid, which ear clipping decides for concave quads); ngons always use ear
// clipping.
function faceTriangles(mesh: Mesh, f: FaceId, method: TriangulateMethod): Array<StaticArray<VertId>> {
    const byLoops = mesh.triangulateFace(f);
    let tris: Array<StaticArray<VertId>> = [];
    for (let i = 0; i < byLoops.length; i++) {
        const t = byLoops[i];
        tris.push(tri3(mesh.loops.at(t[0]).vert, mesh.loops.at(t[1]).vert, mesh.loops.at(t[2]).vert));
    }
    const ring = mesh.faceVerts(f);
    if (method == TriangulateMethod.Beauty && ring.length == 4) {
        const p: Array<Vec3> = [];
        for (let i = 0; i < 4; i++) p.push(mesh.verts.at(ring[i]).co);
        const n = mesh.faces.at(f).normal;
        // Both diagonals are usable only when the quad is convex in its plane.
        let convex = true;
        for (let i = 0; i < 4; i++) {
            const a = p[(i + 3) % 4];
            const b = p[i];
            const c = p[(i + 1) % 4];
            if (!((b - a).cross(c - b).dot(n) >= 0)) {
                convex = false;
                break;
            }
        }
        if (convex) {
            const d02: Array<StaticArray<VertId>> = [tri3(ring[0], ring[1], ring[2]), tri3(ring[0], ring[2], ring[3])];
            const d13: Array<StaticArray<VertId>> = [tri3(ring[1], ring[2], ring[3]), tri3(ring[1], ring[3], ring[0])];
            tris = minAngle(mesh, d02) >= minAngle(mesh, d13) ? d02 : d13;
        }
    }
    return tris;
}

// Triangulate the given faces in place (the modifier and the operator both
// call this). Faces keep their id for the first triangle; the rest are new
// faces with the same flags, material and (per-vertex) UVs. Returns the ids
// of the resulting triangles, including faces that were already triangles.
export function triangulateFaces(mesh: Mesh, faces: Array<FaceId>, method: TriangulateMethod): Array<FaceId> {
    const out: Array<FaceId> = [];
    for (let fi = 0; fi < faces.length; fi++) {
        const f = faces[fi];
        if (!mesh.faces.contains(f)) continue;
        if (mesh.faces.at(f).loopLen <= 3) {
            out.push(f);
            continue;
        }
        const tris = faceTriangles(mesh, f, method);
        const select = mesh.faces.at(f).select;
        if (tris.length == 0) continue;
        // Copy the corner UVs before the ring is rebuilt so every triangle
        // corner keeps the UV of the original corner at that vertex.
        const uvVerts: Array<VertId> = [];
        const uvLists: Array<Array<Vec2>> = [];
        const face = mesh.faces.at(f);
        for (let l = face.loopStart; l < face.loopStart + face.loopLen; l++) {
            const lp = mesh.loops.at(l);
            uvVerts.push(lp.vert);
            uvLists.push(lp.uv.slice(0));
        }
        const first = tris[0];
        mesh.setFaceVerts(f, [first[0], first[1], first[2]]);
        out.push(f);
        for (let ti = 1; ti < tris.length; ti++) {
            const t = tris[ti];
            const nf = mesh.addFaceLike([t[0], t[1], t[2]], f);
            mesh.faces.at(nf).select = select;
            const layer = mesh.activeUv;
            if (layer < <u32>mesh.uvLayers.length) {
                const nface = mesh.faces.at(nf);
                const ring: Array<LoopId> = [];
                for (let l = nface.loopStart; l < nface.loopStart + nface.loopLen; l++) ring.push(l);
                const cornerUvs: Array<Vec2> = [];
                for (let k = 0; k < ring.length; k++) {
                    const v = mesh.loops.at(ring[k]).vert;
                    let uv = Vec2(0, 0);
                    for (let j = 0; j < uvVerts.length; j++) {
                        if (uvVerts[j] == v) {
                            uv = uvLists[j][<i32>layer];
                            break;
                        }
                    }
                    cornerUvs.push(uv);
                }
                for (let k = 0; k < ring.length && k < cornerUvs.length; k++) {
                    const arr = mesh.loops.at(ring[k]).uv;
                    arr[<i32>layer].x = cornerUvs[k].x;
                    arr[<i32>layer].y = cornerUvs[k].y;
                }
            }
            out.push(nf);
        }
    }
    mesh.recalcFaceNormals(out);
    mesh.touch();
    return out;
}

// What `triangulateMesh` did: the face count before and the new triangles.
export class Triangulated {
    before: i32 = 0;
    tris: Array<FaceId> = [];

    static new(before: i32, tris: Array<FaceId>): Triangulated {
        const r = new Triangulated();
        r.before = before;
        r.tris = tris;
        return r;
    }
}

// Operator: triangulate the selected faces and select the triangles.
export function triangulateMesh(mesh: Mesh, method: TriangulateMethod): Result<Triangulated> {
    const fr = requireSelected(mesh, ElemKind.Face);
    if (!fr.ok) return fr.forward<Triangulated>();
    const faces = fr.value;
    const before = faces.length;
    const tris = triangulateFaces(mesh, faces, method);
    mesh.setSelection(ElemKind.Face, tris);
    mesh.debugValidate();
    return Result.okv<Triangulated>(Triangulated.new(before, tris));
}

export function triangulate(scene: Scene, method: TriangulateMethod): Result<OpReport> {
    const mr = editMesh(scene, "triangulate");
    if (!mr.ok) return mr.forward<OpReport>();
    const mesh = mr.value;
    const r = triangulateMesh(mesh, method);
    if (!r.ok) return r.forward<OpReport>();
    const t = r.value;
    return Result.okv<OpReport>(
        meshReport("Triangulated " + plural(t.before, "face") + " into " + plural(t.tris.length, "triangle"), mesh),
    );
}

// Options for tris to quads (degrees, like Blender's panel).
export class TrisToQuadsOpts {
    faceThresholdDeg: f32 = 40.0;
    shapeThresholdDeg: f32 = 40.0;

    static new(faceThresholdDeg: f32, shapeThresholdDeg: f32): TrisToQuadsOpts {
        const o = new TrisToQuadsOpts();
        o.faceThresholdDeg = faceThresholdDeg;
        o.shapeThresholdDeg = shapeThresholdDeg;
        return o;
    }

    clone(): TrisToQuadsOpts {
        return TrisToQuadsOpts.new(this.faceThresholdDeg, this.shapeThresholdDeg);
    }
}

const FRAC_PI_2_F32: f32 = <f32>1.5707963267948966;

// Largest deviation of the quad's corner angles from a right angle.
function quadShapeError(mesh: Mesh, ring: Array<VertId>): f32 {
    let acc: f32 = 0;
    for (let i = 0; i < 4; i++) {
        const a = mesh.verts.at(ring[(i + 3) % 4]).co;
        const b = mesh.verts.at(ring[i]).co;
        const c = mesh.verts.at(ring[(i + 1) % 4]).co;
        acc = maxF32(acc, Mathf.abs(cornerAngle(a, b, c) - FRAC_PI_2_F32));
    }
    return acc;
}

// The triangle's vertex that is neither `a` nor `b`.
function farVert(mesh: Mesh, f: FaceId, a: VertId, b: VertId): VertId {
    const fv = mesh.faceVerts(f);
    for (let i = 0; i < fv.length; i++) {
        if (fv[i] != a && fv[i] != b) return fv[i];
    }
    panic("triangle has a third vert");
    return NO_ID;
}

// The ring the two triangles would form when joined across `e`.
function joinedRing(mesh: Mesh, f1: FaceId, f2: FaceId, e: EdgeId): Array<VertId> {
    const edge = mesh.edges.at(e);
    const ev = edge.v;
    const a = ev[0];
    const b = ev[1];
    // Without the shared edge, f2 contributes the path a -> far2 -> b and
    // f1 the path b -> far1 -> a (or the mirror when f1 walks b -> a).
    if (mesh.faceWalksEdgeForward(f1, e)) {
        return [a, farVert(mesh, f2, a, b), b, farVert(mesh, f1, a, b)];
    }
    return [b, farVert(mesh, f2, a, b), a, farVert(mesh, f1, a, b)];
}

// A tris-to-quads candidate: its cost and the two triangles.
class Candidate {
    cost: f32 = 0;
    f1: FaceId = 0;
    f2: FaceId = 0;

    static new(cost: f32, f1: FaceId, f2: FaceId): Candidate {
        const c = new Candidate();
        c.cost = cost;
        c.f1 = f1;
        c.f2 = f2;
        return c;
    }
}

function cmpCandidate(a: Candidate, b: Candidate): i32 {
    const c = totalCmpF32(a.cost, b.cost);
    if (c != 0) return c;
    if (a.f1 != b.f1) return a.f1 < b.f1 ? -1 : 1;
    if (a.f2 != b.f2) return a.f2 < b.f2 ? -1 : 1;
    return 0;
}

// Join pairs of adjacent selected triangles into quads, best pairs first.
// Returns the quads made (the surviving face ids).
export function trisToQuadsMesh(mesh: Mesh, opts: TrisToQuadsOpts): Result<Array<FaceId>> {
    const fr = requireSelected(mesh, ElemKind.Face);
    if (!fr.ok) return fr.forward<Array<FaceId>>();
    const faces = fr.value;
    const tris: Array<FaceId> = [];
    for (let i = 0; i < faces.length; i++) {
        if (mesh.faces.at(faces[i]).loopLen == 3) tris.push(faces[i]);
    }
    if (tris.length == 0) {
        return Result.failWith<Array<FaceId>>(
            CoreError.invalidArgument("no selected triangles to join; select pairs of adjacent triangles"),
        );
    }
    const faceThr = toRadians(opts.faceThresholdDeg);
    const shapeThr = toRadians(opts.shapeThresholdDeg);
    const candidates: Array<Candidate> = [];
    for (let ti = 0; ti < tris.length; ti++) {
        const f1 = tris[ti];
        const fe = mesh.faceEdges(f1);
        for (let k = 0; k < fe.length; k++) {
            const e = fe[k];
            const f2 = mesh.otherFace(e, f1);
            if (f2 == NO_ID) continue;
            if (f2 <= f1 || !tris.includes(f2)) continue;
            if (mesh.faceWalksEdgeForward(f1, e) == mesh.faceWalksEdgeForward(f2, e)) continue;
            const angle = appleAcosf(clampF32(mesh.faces.at(f1).normal.dot(mesh.faces.at(f2).normal), -1, 1));
            if (angle > faceThr) continue;
            const ring = joinedRing(mesh, f1, f2, e);
            const shape = quadShapeError(mesh, ring);
            if (shape > shapeThr) continue;
            candidates.push(Candidate.new(angle + shape, f1, f2));
        }
    }
    stableSort<Candidate>(candidates, cmpCandidate);
    const used: Array<FaceId> = [];
    const quads: Array<FaceId> = [];
    for (let i = 0; i < candidates.length; i++) {
        const f1 = candidates[i].f1;
        const f2 = candidates[i].f2;
        if (used.includes(f1) || used.includes(f2)) continue;
        if (mesh.joinFaces(f1, f2).ok) {
            used.push(f1);
            used.push(f2);
            quads.push(f1);
        }
    }
    mesh.recalcFaceNormals(quads);
    mesh.flushSelection(ElemKind.Face);
    mesh.debugValidate();
    return Result.okv<Array<FaceId>>(quads);
}

export function trisToQuads(scene: Scene, opts: TrisToQuadsOpts): Result<OpReport> {
    const mr = editMesh(scene, "tris to quads");
    if (!mr.ok) return mr.forward<OpReport>();
    const mesh = mr.value;
    const r = trisToQuadsMesh(mesh, opts);
    if (!r.ok) return r.forward<OpReport>();
    const quads = r.value;
    return Result.okv<OpReport>(
        meshReport(
            "Converted " + plural(quads.length * 2, "triangle") + " to " + plural(quads.length, "quad"),
            mesh,
        ),
    );
}
