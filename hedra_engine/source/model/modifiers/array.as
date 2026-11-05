// The Array modifier, `count` copies (the
// original included) laid out along a relative offset (in bounding-box
// units) plus a constant offset.

import { Vec3 } from "../../../base/vecmath";
import { Mesh } from "../mesh/mod";

export function array(mesh: Mesh, count: u32, relativeOffset: Vec3, constantOffset: Vec3, merge: bool, mergeThreshold: f32): void {
    if (count < 2 || mesh.verts.isEmpty()) return;
    const b = mesh.bounds();
    const size = b == null ? Vec3(0, 0, 0) : b.hi - b.lo;
    const step = relativeOffset.mul(size) + constantOffset;
    const base = mesh.clone();
    for (let i: u32 = 1; i < count; i++) {
        const copy = base.clone();
        copy.translate(step * <f32>i);
        mesh.append(copy, 0);
    }
    if (merge && mergeThreshold > 0) {
        const verts = mesh.verts.ids();
        mesh.mergeByDistance(verts, mergeThreshold);
    }
    mesh.recalcNormals();
}
