// A scene's meshes as the renderer draws them (hedra_engine/render/mesh.as,
// GpuMesh). There are two roads, and the choice is what makes a model look
// the same in Hedra as in Hedra:
//
// - a model's mesh (ArrayMesh.source set) is built from the model's own
//   object by its ModelSource's mesh cache (the tools': shared/render/
//   meshbuild.as, in model space, Z up), exactly as Hedra builds it: the
//   same vertices, the same order, the same tangents. The adapter places
//   it with SCENE_TO_MODEL * global * MODEL_TO_SCENE (adapter.as). A model
//   from a built scene has no source; its meshes arrive prebuilt;
// - any other ArrayMesh (a built-in mesh, or one built in code) becomes a
//   GpuMesh from its triangle lists: one index range per surface, the UVs
//   turned back to the renderer's bottom-left origin, per-vertex tangents
//   from the UVs, and every triangle edge once for the wire shadings. It
//   stays in scene space; the adapter places it with SCENE_TO_MODEL *
//   global.

import { VEC4_ZERO, Vec2, Vec3, Vec4 } from "../../base/vecmath";
import { finishTangent } from "../../render/mesh_build";
import { GpuMesh, MaterialRange, MeshLod, MeshUploader } from "../../render/mesh";
import { F_MESH, LineInstance, SurfaceVertex, WEIGHT_NONE } from "../../render/gpu/layouts";
import { ArrayMesh, ModelMeshCache, ModelMeshSource } from "../resource/types";
import { noteCpuMiss } from "../resource/cpu_copy";

// `a[i*3 .. i*3+3]` as a Vec3 (zero past the end, so a surface with fewer
// normals than positions still builds).
function vec3At(a: Array<f32>, i: i32): Vec3 {
    const k = i * 3;
    if (k + 2 >= a.length) return Vec3(0, 0, 0);
    return Vec3(a[k], a[k + 1], a[k + 2]);
}

// The UV of vertex `i` in the renderer's convention: the format's UVs have a
// top-left origin (as Godot's and glTF's), Hedra's and the shaders' a
// bottom-left one (surface.wgsl samples at (u, 1 - v)), so v is flipped
// back. No UVs: (0, 0).
function uvAt(a: Array<f32>, i: i32): Vec2 {
    const k = i * 2;
    if (k + 1 >= a.length) return Vec2(0, 0);
    return Vec2(a[k], <f32>1 - a[k + 1]);
}

// `mesh` as a GpuMesh (decision 2 of milestone 4): every surface's vertices
// in turn, its indices offset to them, one MaterialRange per surface with
// the surface's index as its slot (the adapter maps slot k to surface k's
// material). Tangents are summed per vertex over its triangles, as
// meshbuild does per face, and finished the same way (finishTangent), so a
// normal map bends the light the same way on both roads. Flags are 0 and
// the weight WEIGHT_NONE: a scene has no selection and no vertex groups.
// Its edges are `triangleEdges`'. Nothing is uploaded.
export function arrayMeshToGpu(mesh: ArrayMesh): GpuMesh {
    const verts = new Array<SurfaceVertex>();
    const indices = new Array<u32>();
    const ranges = new Array<MaterialRange>();
    for (let s = 0; s < mesh.surfaces.length; s++) {
        const surf = mesh.surfaces[s];
        const n = surf.vertexCount();
        const base = <u32>verts.length;
        const first = <u32>indices.length;
        // Tangent and bitangent sums per vertex of this surface.
        const tSum = new Array<Vec3>(n);
        const bSum = new Array<Vec3>(n);
        for (let i = 0; i < n; i++) {
            tSum[i] = Vec3(0, 0, 0);
            bSum[i] = Vec3(0, 0, 0);
        }
        const hasUv = surf.uvs.length >= n * 2 && n > 0;
        const idx = surf.indices;
        const tris = idx.length / 3;
        for (let t = 0; t < tris; t++) {
            const i0 = <i32>idx[t * 3];
            const i1 = <i32>idx[t * 3 + 1];
            const i2 = <i32>idx[t * 3 + 2];
            if (i0 >= n || i1 >= n || i2 >= n) continue;
            indices.push(base + <u32>i0);
            indices.push(base + <u32>i1);
            indices.push(base + <u32>i2);
            if (!hasUv) continue;
            // The triangle's tangent and bitangent from its UVs (the same
            // formula as meshbuild's addTriTangent), skipped when the UVs
            // are degenerate.
            const p0 = vec3At(surf.positions, i0);
            const e1 = vec3At(surf.positions, i1) - p0;
            const e2 = vec3At(surf.positions, i2) - p0;
            const uv0 = uvAt(surf.uvs, i0);
            const d1 = uvAt(surf.uvs, i1) - uv0;
            const d2 = uvAt(surf.uvs, i2) - uv0;
            const det = d1.x * d2.y - d2.x * d1.y;
            if (Mathf.abs(det) < <f32>1e-12) continue;
            const r = <f32>1.0 / det;
            const tt = (e1 * d2.y - e2 * d1.y) * r;
            const bb = (e2 * d1.x - e1 * d2.x) * r;
            tSum[i0] = tSum[i0] + tt;
            tSum[i1] = tSum[i1] + tt;
            tSum[i2] = tSum[i2] + tt;
            bSum[i0] = bSum[i0] + bb;
            bSum[i1] = bSum[i1] + bb;
            bSum[i2] = bSum[i2] + bb;
        }
        for (let i = 0; i < n; i++) {
            const normal = vec3At(surf.normals, i);
            const tangent: Vec4 = finishTangent(normal, tSum[i], bSum[i]);
            verts.push(SurfaceVertex(vec3At(surf.positions, i), normal, uvAt(surf.uvs, i), 0, tangent, WEIGHT_NONE));
        }
        ranges.push(MaterialRange(<u16>s, first, <u32>indices.length - first));
    }
    const g = GpuMesh.fromArrays(verts, indices, ranges);
    g.edges = triangleEdges(verts, indices);
    g.edgeCount = <u32>g.edges.length;
    return g;
}

// The key of a position: its three coordinates' bits (-0 made 0, so the two
// zeros are one place).
function positionKey(p: Vec3): string {
    const x = p.x == 0 ? <f32>0 : p.x;
    const y = p.y == 0 ? <f32>0 : p.y;
    const z = p.z == 0 ? <f32>0 : p.z;
    return reinterpret<u32>(x).toString() + "," + reinterpret<u32>(y).toString() + "," + reinterpret<u32>(z).toString();
}

// Every edge of the triangles `indices` makes of `verts`, once, in the
// order the triangles first name them, as the wire lines of meshbuild's
// edges (F_MESH: the shader colours them with the frame's wire colour).
// Vertices are compared by position, not by index: a built-in mesh splits
// its vertices wherever the normal or the UV changes (a BoxMesh has 24 for
// 8 corners), and an edge shared by two faces must be drawn once. So a
// BoxMesh has 18 edges: its 12 and one diagonal per face.
export function triangleEdges(verts: Array<SurfaceVertex>, indices: Array<u32>): Array<LineInstance> {
    // Each distinct position's number, by vertex.
    const ids = new Map<string, u32>();
    const idOf = new Array<u32>(verts.length);
    for (let i = 0; i < verts.length; i++) {
        const k = positionKey(verts[i].pos);
        if (!ids.has(k)) ids.set(k, <u32>ids.size);
        idOf[i] = ids.get(k);
    }
    const seen = new Set<u64>();
    const out = new Array<LineInstance>();
    const tris = indices.length / 3;
    for (let t = 0; t < tris; t++) {
        for (let e = 0; e < 3; e++) {
            const a = <i32>indices[t * 3 + e];
            const b = <i32>indices[t * 3 + (e + 1) % 3];
            const ia = idOf[a];
            const ib = idOf[b];
            // A triangle folded onto an edge has no edge there.
            if (ia == ib) continue;
            const key = ia < ib ? (<u64>ia << 32) | <u64>ib : (<u64>ib << 32) | <u64>ia;
            if (seen.has(key)) continue;
            seen.add(key);
            out.push(LineInstance(verts[a].pos, verts[b].pos, VEC4_ZERO, 1.0, F_MESH));
        }
    }
    return out;
}

// The GpuMesh of a model's object, from the model itself through `cache`
// (one per ModelResource, from its source's meshCache: object ids are per
// model), as Hedra's material mode builds it (no cage, the object's
// texture UV layer, no weights; and UV set 1, milestone 14's second part:
// the model's second UV layer, glTF's TEXCOORD_1, which changes nothing of
// a mesh that has none), so the buffers are Hedra's byte for byte.
// Uploaded through `uploader` when it is not null. null when the model has
// no source (a built scene's), or the object is gone or is no mesh.
export function modelObjectMesh(src: ModelMeshSource, cache: ModelMeshCache, uploader: MeshUploader?): GpuMesh? {
    if (src.model.source == null) return null;
    return cache.mesh(src.objectId, uploader);
}

// --- levels of detail (milestone 26) -------------------------------------------

// Where a mesh's levels of detail come from when a frame asks for them
// (SceneRenderOptions.lodThreshold above 0) and the mesh has none: the
// tools install one at start (compiler/src/import/lod_source.as:
// the model's imported levels when its import is current, else levels
// generated with Godot's defaults); the run time gives each
// runtime's SceneRenderCache its bundle's (bundle/provider.as
// BundleLodSource: a primitive's levels from its Lods entry; a model
// mesh's come with its Mesh entry), so it carries no simplifier and never
// stalls a frame making them. That one is the cache's, not this module's:
// every scene built into one Rive project shares this module, and a
// global source would let the scene loaded last decide every scene's
// levels.
export abstract class LodSource {
    // The levels of `g`, built from `mesh`; empty for none (a mesh too
    // small, or a model whose import says meshes/generate_lods false).
    abstract levels(mesh: ArrayMesh, g: GpuMesh): Array<MeshLod>;
}

let lodSource: LodSource? = null;

export function setLodSource(s: LodSource?): void {
    lodSource = s;
}

export function currentLodSource(): LodSource? {
    return lodSource;
}

// Gives `g` its levels from `own` (a SceneRenderCache's: a built
// scene's assets, so two scenes in one Rive project, which share this
// module, each keep their own) or else the installed source, once (an
// empty array marks a mesh asked and given none), and says whether it was
// given any.
// It uploads nothing: SceneRenderCache.entry asks before a mesh's first
// upload, so its index buffer holds them from the start, and uploads a
// mesh already on the device again only after handing its old buffers to
// the renderer's retire list (a second upload replaces GpuMesh.gpu, and
// buffers dropped that way are never released).
//
// Milestone 67b: a mesh whose CPU arrays a run time released (GpuMesh
// .releaseCpu, a frame after its upload) has none to make levels from: it
// keeps level 0 alone and counts a miss. Under the release policy the
// render cache asks for levels before every first upload, whatever the
// threshold (cache.as SceneRenderCache.ready), so a mesh has them, or has
// been given none, before its arrays can go.
export function provideLods(mesh: ArrayMesh, g: GpuMesh, own: LodSource? = null): bool {
    if (g.lods != null) return false;
    const src = own != null ? own : lodSource;
    if (src == null) return false;
    if (g.cpuReleased) {
        noteCpuMiss("lods: a released mesh");
        g.lods = [];
        return false;
    }
    const lods = src.levels(mesh, g);
    g.lods = lods;
    return lods.length > 0;
}
