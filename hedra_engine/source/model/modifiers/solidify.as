// The Solidify modifier, give a surface
// thickness by adding an offset inner shell with flipped faces and rim quads
// along every boundary edge.

import { clampF32, maxF32, minF32 } from "../../../base/util";
import { Vec2, Vec3 } from "../../../base/vecmath";
import { Mesh, VertId, FaceId, EdgeId, NO_ID } from "../mesh/mod";
import { flipFaces } from "./mirror";

// One rim: the boundary edge walked (a, b) the way its face does, and that
// face.
class Rim {
    a: VertId;
    b: VertId;
    f: FaceId;
    constructor(a: VertId, b: VertId, f: FaceId) {
        this.a = a;
        this.b = b;
        this.f = f;
    }
}

// Rim UVs come from the boundary face's corners.
function cornerUv(mesh: Mesh, hasUv: bool, layer: i32, f: FaceId, v: VertId): Vec2 {
    if (!hasUv) return Vec2(0, 0);
    const l = mesh.faceLoopOf(f, v);
    if (l == NO_ID) return Vec2(0, 0);
    return mesh.loops.at(l).uv[layer];
}

// `offset` in -1..1 places the original surface: -1 (Blender's default)
// extrudes inward, 1 outward, 0 half each way. `even` scales each vertex
// offset by 1/cos of the angle to its faces so the shell keeps its thickness
// at corners (clamped, like Blender).
export function solidify(mesh: Mesh, thickness: f32, offset: f32, even: bool): void {
    if (mesh.faces.isEmpty() || thickness == 0) return;
    const o = clampF32(offset, -1, 1);
    const dOuter: f32 = thickness * (o + 1) * 0.5;
    const dInner: f32 = thickness * (o - 1) * 0.5;
    const boundary: Array<EdgeId> = mesh.boundaryEdges();

    // Per-vertex displacement direction (and even-thickness scale) from the
    // original surface, before anything moves. (The writes are per vertex
    // and independent, so id order is as good as any.)

    const dirIds: Array<VertId> = [];
    const dirs: Array<Vec3> = [];
    const vb = mesh.verts.idBound();
    for (let v: u32 = 0; v < vb; v++) {
        if (!mesh.verts.contains(v)) continue;
        const n = mesh.vertNormal(v);
        let scale: f32 = 1;
        if (even) {
            const faces = mesh.vertFaces(v);
            if (faces.length > 0) {
                let sum: f32 = 0;
                for (let i = 0; i < faces.length; i++) sum += maxF32(mesh.faces.at(faces[i]).normal.dot(n), 0);
                const meanCos: f32 = sum / <f32>faces.length;
                scale = minF32(<f32>1 / maxF32(meanCos, <f32>1e-3), 4);
            }
        }
        dirIds.push(v);
        dirs.push(n * scale);
    }
    const layer = mesh.activeUv;
    const hasUv = layer < <u32>mesh.uvLayers.length;
    const rims: Array<Rim> = [];
    for (let i = 0; i < boundary.length; i++) {
        const e = boundary[i];
        const f = mesh.edgeFaces(e)[0];
        const edge = mesh.edges.at(e);
        const a = edge.v[0];
        const b = edge.v[1];
        // Orient the rim so it faces away from the surface: walk the edge the
        // way the face does, then go down the inner shell.
        if (mesh.faceWalksEdgeForward(f, e)) rims.push(new Rim(a, b, f));
        else rims.push(new Rim(b, a, f));
    }

    const inner = mesh.clone();
    for (let i = 0; i < dirIds.length; i++) {
        const v = inner.verts.at(dirIds[i]);
        v.co = v.co + dirs[i] * dInner;
    }
    flipFaces(inner);
    if (dOuter != 0) {
        mesh.touch();
        for (let i = 0; i < dirIds.length; i++) {
            const v = mesh.verts.at(dirIds[i]);
            v.co = v.co + dirs[i] * dOuter;
        }
    }
    const vmap = mesh.append(inner, 0);
    for (let i = 0; i < rims.length; i++) {
        const a = rims[i].a;
        const b = rims[i].b;
        const f = rims[i].f;
        const ai = vmap.get(a);
        const bi = vmap.get(b);
        const ring: Array<VertId> = [b, a, ai, bi];
        const ua = cornerUv(mesh, hasUv, <i32>layer, f, a);
        const ub = cornerUv(mesh, hasUv, <i32>layer, f, b);
        const uvs: Array<Vec2> = [];
        uvs.push(ub);
        uvs.push(ua);
        uvs.push(ua);
        uvs.push(ub);
        const nf = mesh.addFaceUv(ring, uvs);
        const src = mesh.faces.at(f);
        const smooth = src.smooth;
        const material = src.materialIndex;
        const rim = mesh.faces.at(nf);
        rim.smooth = smooth;
        rim.materialIndex = material;
    }
    mesh.recalcNormals();
}
