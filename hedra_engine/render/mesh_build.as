// The parts of mesh building that know no model (milestone 40): what a
// mesh request asks for, which UV layer set 1 reads, and how a tangent is
// finished. They lived in engine/src/source/render/meshbuild.as, the builder of a
// Hedra object's buffers, which stays with the tools (it reads the
// Hedra's mesh kernel) and re-exports these, so Hedra's imports and
// buffers are unchanged. The engine builds the meshes of primitives and
// code (engine/src/scene/render/meshes.as) with the same tangent rule, so a model
// and a primitive are shaded alike.

import { Vec3, Vec4, VEC3_X, VEC3_Y } from "../base/vecmath";

// What an object's buffers must carry this frame.
export class MeshRequest {
    // The edit-mode look: base mesh wire over the evaluated surface.
    cage: bool = false;
    // UV layer textures sample through (null = the active layer).
    uvLayer: string? = null;
    // Vertex group baked into the `weight` attribute (`--shading weights`); -1 = none.
    weightGroup: i64 = -1;
    // Milestone 14, part 2 (Hedra only): build UV set 1 as well
    // (GpuMesh.uv1, `uv1LayerOf`). Off, the mesh is built as before.
    uv1: bool = false;

    constructor(cage: bool = false, uvLayer: string? = null, weightGroup: i64 = -1, uv1: bool = false) {
        this.cage = cage;
        this.uvLayer = uvLayer;
        this.weightGroup = weightGroup;
        this.uv1 = uv1;
    }
}

// The UV layer UV set 1 is read from, of a mesh with `count` layers whose
// set 0 is layer `layer`: layer 1, glTF's TEXCOORD_1 by the importer's
// layer order, whatever set 0 is (a material's texCoord names a layer, not
// a place relative to set 0; set 0 is the layer Hedra samples, the
// object's `textureLayer`, for a .modeler model, so it draws as it always
// drew, and layer 0 for a glTF model: the tools' model source,
// engine/src/source/scene/resource/model_source.as); -1 when the mesh has one
// layer.
export function uv1LayerOf(layer: i32, count: i32): i32 {
    return count >= 2 ? 1 : -1;
}

// Any unit vector perpendicular to `n`, for corners without usable UVs.
export function anyPerpendicular(n: Vec3): Vec3 {
    const axis = Mathf.abs(n.x) < <f32>0.9 ? VEC3_X : VEC3_Y;
    const p = n.cross(axis);
    if (p.lengthSquared() < <f32>1e-12) return VEC3_X;
    return p.normalize();
}

// Gram-Schmidt the accumulated tangent against the shading normal and pack
// the bitangent sign into `w` (glTF convention).
export function finishTangent(n: Vec3, t0: Vec3, b: Vec3): Vec4 {
    const t1 = t0 - n * n.dot(t0);
    if (t1.lengthSquared() < <f32>1e-12) return anyPerpendicular(n).extend(1.0);
    const t = t1.normalize();
    const w: f32 = n.cross(t).dot(b) < 0 ? -1.0 : 1.0;
    return t.extend(w);
}
