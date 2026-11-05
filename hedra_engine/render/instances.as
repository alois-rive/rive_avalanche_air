// The instances of an instanced draw (milestone 13: a MultiMeshInstance3D):
// what a program packs once per MultiMesh, and what the renderer uploads as
// a per-instance vertex buffer (gpu/renderer.as) and the CPU reads for
// culling bounds and picking.
//
// The layout is the frozen contract between this module and surface.wgsl's
// instanced vertex stage: per instance INSTANCE_STRIDE (64) bytes, four
// vec4<f32> in this order,
//
//   row0  (m00, m01, m02, t0)   the 3x4 transform's rows: the basis's row r
//   row1  (m10, m11, m12, t1)   (its columns are the X, Y and Z axes), then
//   row2  (m20, m21, m22, t2)   the origin's component r
//   color (r, g, b, a)          as written (1, 1, 1, 1 without colours)
//
// so a point p of the mesh lands at (dot(row0, p1), dot(row1, p1),
// dot(row2, p1)) with p1 = (p, 1), in the item's space, which DrawItem.world
// then takes to the frame's world. That is Godot 4's MultiMesh buffer
// exactly (basis.rows[r].x, .y, .z, origin[r], r = 0, 1, 2; then the
// colour), so a scene's `buffer` is copied, not reinterpreted; only the
// custom data Godot keeps after the colour is dropped, and a colour is
// added when the MultiMesh has none.
//
// Milestone 61 (custom shaders, gpu/custom.as): a second stream of
// INSTANCE_EXTRA_STRIDE (32) bytes an instance, `extra`, read by the custom
// shaders' instanced pipelines alone (every other pipeline, and the 64-byte
// layout above, are as they were):
//
//   custom (c0, c1, c2, c3)     Godot's INSTANCE_CUSTOM: the MultiMesh's
//                               custom data with use_custom_data, else 0
//   id     (i, 0, 0, 0)         Godot's INSTANCE_ID: the instance's index,
//                               a float (exact up to 2^24 instances)
//
// packed with the transforms; a dynamic data's (a CPUParticles3D's) is
// made by the GPU side, its index alone (gpu/instances.as
// instanceExtraBuffer).
//
// `post`, when `hasPost`, is applied to the right of every instance's transform
// (instance x post): a mesh built in another space than the instances'
// (Hedra's .modeler meshes, built Z up, placed in a Y-up scene) is taken
// to the instance's space first, as Hedra's adapter does for one copy.

import { MAT4_IDENTITY, Mat4, Vec3, Vec4 } from "../base/vecmath";
import { Bounds } from "./camera";

// Floats and bytes of one instance.
export const INSTANCE_FLOATS: i32 = 16;
export const INSTANCE_STRIDE: u32 = 64;
// Milestone 61: the extra stream's floats and bytes an instance.
export const INSTANCE_EXTRA_FLOATS: i32 = 8;
export const INSTANCE_EXTRA_STRIDE: u32 = 32;

// The device side of an InstanceData (the vertex buffer), set by the
// renderer; the GPU side subclasses it.
export abstract class InstanceGpuBuffer {}

export class InstanceData {
    // Instances drawn (Godot's visible_instance_count, or all).
    count: u32 = 0;
    // count x INSTANCE_STRIDE bytes (the layout above).
    bytes: ArrayBuffer = new ArrayBuffer(0);
    // The MultiMesh had colours (otherwise every colour is white).
    hasColors: bool = false;
    // The box around every instance's copy of the mesh's box, in the item's
    // space (before DrawItem.world); `hasLocal` false when there is no
    // instance.
    local: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    hasLocal: bool = false;
    // Some instance's transform mirrors (a negative determinant).
    anyMirrored: bool = false;
    // The uploaded vertex buffer (null until the renderer uploads it).
    gpu: InstanceGpuBuffer? = null;
    // Milestone 35: the instances change from frame to frame (a
    // CPUParticles3D's, ../scene/particles/state.as): `bytes` is the
    // capacity (count may be less, 0 included), uploaded into a buffer the
    // renderer may update, and every change of them moves `version`; the
    // renderer updates the first count x INSTANCE_STRIDE bytes when the
    // version it uploaded differs, and makes the buffer again when `bytes`
    // is of another length (gpu/instances.as); with `count` 0 the item is
    // drawn in no pass (cull.as). A MultiMesh's are packed once: `dynamic`
    // false, uploaded once into an immutable buffer.
    dynamic: bool = false;
    version: u32 = 0;
    // Milestone 61: the extra stream (the header), count x
    // INSTANCE_EXTRA_STRIDE bytes, packed by packInstances; null for a
    // dynamic data, whose index stream the GPU side makes. And its
    // uploaded buffer (null until a custom instanced draw uploads it).
    extra: ArrayBuffer? = null;
    extraGpu: InstanceGpuBuffer? = null;

    // Instance i's transform as a Mat4 (item space; `post` applied).
    transform(i: i32): Mat4 {
        return instanceTransform(new DataView(this.bytes, 0, this.bytes.byteLength), i);
    }

    // Instance i's colour, as written (white without colours).
    color(i: i32): Vec4 {
        const dv = new DataView(this.bytes, 0, this.bytes.byteLength);
        const o = i * <i32>INSTANCE_STRIDE + 48;
        return Vec4(dv.getFloat32(o, true), dv.getFloat32(o + 4, true), dv.getFloat32(o + 8, true),
            dv.getFloat32(o + 12, true));
    }
}

// Instance i's transform from a view of InstanceData.bytes (one view read
// for every instance: picking walks thousands).
export function instanceTransform(dv: DataView, i: i32): Mat4 {
    const o = i * <i32>INSTANCE_STRIDE;
    return Mat4(
        Vec4(dv.getFloat32(o, true), dv.getFloat32(o + 16, true), dv.getFloat32(o + 32, true), 0),
        Vec4(dv.getFloat32(o + 4, true), dv.getFloat32(o + 20, true), dv.getFloat32(o + 36, true), 0),
        Vec4(dv.getFloat32(o + 8, true), dv.getFloat32(o + 24, true), dv.getFloat32(o + 40, true), 0),
        Vec4(dv.getFloat32(o + 12, true), dv.getFloat32(o + 28, true), dv.getFloat32(o + 44, true), 1),
    );
}

// The rows of Godot's 3D transform numbers (12, from `at`) as a Mat4.
export function godotTransform(buffer: Array<f64>, at: i32): Mat4 {
    return Mat4(
        Vec4(<f32>buffer[at], <f32>buffer[at + 4], <f32>buffer[at + 8], 0),
        Vec4(<f32>buffer[at + 1], <f32>buffer[at + 5], <f32>buffer[at + 9], 0),
        Vec4(<f32>buffer[at + 2], <f32>buffer[at + 6], <f32>buffer[at + 10], 0),
        Vec4(<f32>buffer[at + 3], <f32>buffer[at + 7], <f32>buffer[at + 11], 1),
    );
}

// Packs a Godot MultiMesh buffer with 3D transforms: `instanceCount`
// instances of `stride` numbers each (12, plus 4 with `useColors`, plus 4
// with custom data), of which the first `visible` are drawn (-1: all;
// clamped to what the buffer holds). `meshLocal` is the mesh's box in the
// mesh's own space (`post` takes it to the instance's), for `local`. A
// buffer shorter than it should be packs the instances it holds whole.
export function packInstances(
    buffer: Array<f64>, instanceCount: i32, stride: i32, useColors: bool, visible: i32, meshLocal: Bounds,
    hasPost: bool = false, post: Mat4 = MAT4_IDENTITY,
): InstanceData {
    const out = new InstanceData();
    out.hasColors = useColors;
    if (stride < 12 || instanceCount <= 0) return out;
    let n = min<i32>(instanceCount, buffer.length / stride);
    if (visible >= 0) n = min<i32>(n, visible);
    if (n <= 0) return out;
    out.count = <u32>n;
    out.bytes = new ArrayBuffer(n * <i32>INSTANCE_STRIDE);
    const dv = new DataView(out.bytes, 0, out.bytes.byteLength);
    // (milestone 61: the custom data after the colour, when the buffer
    // holds it: Godot's stride 12, plus 4 with colours, plus 4)
    const custom = stride >= 16 + (useColors ? 4 : 0);
    const customAt = 12 + (useColors ? 4 : 0);
    out.extra = new ArrayBuffer(n * <i32>INSTANCE_EXTRA_STRIDE);
    const ev = new DataView(out.extra!, 0, n * <i32>INSTANCE_EXTRA_STRIDE);
    let first = true;
    for (let i = 0; i < n; i++) {
        const at = i * stride;
        let m = godotTransform(buffer, at);
        if (hasPost) m = m * post;
        const o = i * <i32>INSTANCE_STRIDE;
        // rows: (x, y, z) of each axis's component r, then the origin's r
        dv.setFloat32(o + 0, m.xAxis.x, true);
        dv.setFloat32(o + 4, m.yAxis.x, true);
        dv.setFloat32(o + 8, m.zAxis.x, true);
        dv.setFloat32(o + 12, m.wAxis.x, true);
        dv.setFloat32(o + 16, m.xAxis.y, true);
        dv.setFloat32(o + 20, m.yAxis.y, true);
        dv.setFloat32(o + 24, m.zAxis.y, true);
        dv.setFloat32(o + 28, m.wAxis.y, true);
        dv.setFloat32(o + 32, m.xAxis.z, true);
        dv.setFloat32(o + 36, m.yAxis.z, true);
        dv.setFloat32(o + 40, m.zAxis.z, true);
        dv.setFloat32(o + 44, m.wAxis.z, true);
        for (let k = 0; k < 4; k++) {
            const c: f32 = useColors ? <f32>buffer[at + 12 + k] : 1;
            dv.setFloat32(o + 48 + k * 4, c, true);
        }
        writeInstanceExtra(ev, i, custom ? <f32>buffer[at + customAt] : 0, custom ? <f32>buffer[at + customAt + 1] : 0,
            custom ? <f32>buffer[at + customAt + 2] : 0, custom ? <f32>buffer[at + customAt + 3] : 0);
        const x = m.xAxis;
        const y = m.yAxis;
        const z = m.zAxis;
        const det = x.x * (y.y * z.z - y.z * z.y) - y.x * (x.y * z.z - x.z * z.y) + z.x * (x.y * y.z - x.z * y.y);
        if (det < 0) out.anyMirrored = true;
        const b = meshLocal.transformed(m);
        out.local = first ? b : out.local.union(b);
        first = false;
    }
    out.hasLocal = true;
    return out;
}

// Instance i's extra record (the header) at its place in `dv`: its custom
// data and its index.
export function writeInstanceExtra(dv: DataView, i: i32, c0: f32, c1: f32, c2: f32, c3: f32): void {
    const o = i * <i32>INSTANCE_EXTRA_STRIDE;
    dv.setFloat32(o, c0, true);
    dv.setFloat32(o + 4, c1, true);
    dv.setFloat32(o + 8, c2, true);
    dv.setFloat32(o + 12, c3, true);
    dv.setFloat32(o + 16, <f32>i, true);
    dv.setFloat32(o + 20, 0, true);
    dv.setFloat32(o + 24, 0, true);
    dv.setFloat32(o + 28, 0, true);
}

// The extra stream of `count` instances that have no custom data (a
// dynamic data's: its particles' indices).
export function instanceIndexStream(count: i32): ArrayBuffer {
    const bytes = new ArrayBuffer(max<i32>(count, 0) * <i32>INSTANCE_EXTRA_STRIDE);
    const dv = new DataView(bytes, 0, bytes.byteLength);
    for (let i = 0; i < count; i++) writeInstanceExtra(dv, i, 0, 0, 0, 0);
    return bytes;
}
