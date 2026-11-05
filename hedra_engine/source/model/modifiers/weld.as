// The Weld modifier, merge every vertex
// closer than `distance` to another.

import { maxF32 } from "../../../base/util";
import { Mesh } from "../mesh/mod";

// Returns the number of removed vertices.
export function weld(mesh: Mesh, distance: f32): i32 {
    const verts = mesh.verts.ids();
    return mesh.mergeByDistance(verts, maxF32(distance, 0));
}
