// Occluders as a frame carries them (milestone 37; Godot's
// OccluderInstance3D): triangles that hide, from the camera, what is wholly
// behind them, so that the renderer does not draw it (occlusion culling, on
// the CPU, before drawing; occlusion.as rasterises them and tests the
// items, cull.as calls it after the frustum test). A program fills
// RenderFrame.occluders with what does not depend on the camera (the scene
// adapter's ../scene/render/occluders.as: each visible OccluderInstance3D
// of the frame's world, its occluder's triangles in its node's space and
// the node's transform); the culling does the rest for the camera it
// draws from. A frame without occluders (every frame of a scene without an
// OccluderInstance3D) culls as before.
//
// Godot's semantics: an occluder occludes from both sides (Embree's rays
// hit a triangle either way), a hidden OccluderInstance3D occludes nothing,
// the occluders are geometry of their own (not drawn, not the meshes they
// stand for: a bake makes them from those). Imports nothing of the
// renderer's but the camera's box.

import { MAT4_IDENTITY, Mat4, Vec3 } from "../base/vecmath";
import { Bounds } from "./camera";

// One OccluderInstance3D of a frame: its triangles and where they are. A
// class filled in place (the scene adapter refreshes a frame's occluders
// every frame a scene moves), so it allocates nothing once made: the
// arrays are the occluder's own (../scene/render/occluder_shapes.as keeps
// them per occluder resource and version), never copied.
export class OccluderDesc {
    // x, y, z a point, in the node's space.
    vertices: Float32Array = new Float32Array(0);
    // Three a triangle, into vertices.
    indices: Uint32Array = new Uint32Array(0);
    // The node's space to the frame's world (SCENE_TO_MODEL times its
    // global transform).
    world: Mat4 = MAT4_IDENTITY;
    // The triangles' box in the frame's world, and whether there is one
    // (an occluder with no triangle has none, and occludes nothing).
    bounds: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    hasBounds: bool = false;
    // Its place among the frame's occluders, in the scene's order.
    order: i32 = 0;
    // The occluder resource's version when its arrays were taken (they
    // are taken again when it moves).
    version: u32 = 0;
    // The node's path, for the statistics and `inspect --occluders` (not
    // drawn).
    label: string = "";
    // Milestone 34 (viewport.as): the world it occludes in (its node's, as
    // DrawItem.scenario). 0 in every scene without a SubViewport.
    scenario: i32 = 0;
    // Whether its triangles close a volume, each turned counter-clockwise
    // seen from outside (a BoxOccluder3D's, a SphereOccluder3D's): then
    // the faces turned away from the eye lie behind those turned towards
    // it, and the buffer leaves them out (the same buffer at half the
    // cost). False for every other occluder, whose both sides occlude.
    closed: bool = false;
}
