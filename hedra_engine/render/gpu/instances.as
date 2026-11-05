// The device side of instanced draws (milestone 13): the per-instance
// vertex buffer of an `InstanceData` (engine/src/render/instances.as, the
// frozen 64-byte layout surface.wgsl's InstIn reads).
//
// A program packs an InstanceData once per MultiMesh and keeps it while the
// MultiMesh is the same (Hedra's cache.as); the renderer uploads its bytes
// the first time a frame draws it (`instanceBuffer`) and keeps the buffer on
// it (`InstanceData.gpu`), so a preview moving its camera over the same plan
// uploads nothing. When the program drops the data (SceneRenderer.sweep),
// it hands it to `FrameRenderer.retireInstances`, which releases the buffer
// at the next `beginFrame`, once the views that may still draw it are
// recorded.
//
// Milestone 35: a dynamic InstanceData (InstanceData.dynamic: a
// CPUParticles3D's, packed again whenever its particles move) gets a
// mutable buffer of its whole `bytes` (the state's capacity), made on its
// first draw with something in it, written again with its first `count` x
// INSTANCE_STRIDE bytes (GPUBuffer.update) when the version it was last
// written at differs from the data's, so once per host frame however many
// views draw it, and made again when `bytes` is of another length (a new
// amount), the old one handed to the caller's retired list (released at
// the next beginFrame, as `retire`'s are). A dynamic data with no instance
// (count 0) is not drawn (cull.as) and writes nothing. A MultiMesh's path is
// as before: immutable, uploaded once.

import { GPUBuffer } from "rive/gpu";
import { BufferUsage } from "rive/gpu_enums";
import { INSTANCE_STRIDE, InstanceData, InstanceGpuBuffer, instanceIndexStream } from "../instances";

export class GpuInstanceBuffer extends InstanceGpuBuffer {
    buffer: GPUBuffer;
    // A dynamic data's: the version its bytes were last written at, and
    // the byte length the buffer was made for.
    version: u32 = 0;
    length: i32 = 0;

    constructor(buffer: GPUBuffer) {
        super();
        this.buffer = buffer;
    }
}

// What `instanceBuffer` does for a data (instanceAction).
// Nothing to draw yet: no buffer is made.
export const INSTANCE_NONE: i32 = 0;
// The kept buffer as it is.
export const INSTANCE_KEEP: i32 = 1;
// A buffer made (the data's first draw).
export const INSTANCE_MAKE: i32 = 2;
// The kept buffer written with the data's instances (a dynamic data whose
// version moved).
export const INSTANCE_UPDATE: i32 = 3;
// The kept buffer retired and another made (a dynamic data whose bytes are
// of another length); with no instance the old is retired and none made.
export const INSTANCE_REMAKE: i32 = 4;

// What `instanceBuffer` does for `data` now (the rule of the header).
export function instanceAction(data: InstanceData): i32 {
    const g = data.gpu;
    if (!data.dynamic) {
        if (g != null) return INSTANCE_KEEP;
        return data.count == 0 || data.bytes.byteLength == 0 ? INSTANCE_NONE : INSTANCE_MAKE;
    }
    const empty = data.count == 0 || data.bytes.byteLength == 0;
    if (g == null) return empty ? INSTANCE_NONE : INSTANCE_MAKE;
    const kept = g as GpuInstanceBuffer;
    if (kept.length != data.bytes.byteLength) return INSTANCE_REMAKE;
    if (kept.version != data.version && !empty) return INSTANCE_UPDATE;
    return INSTANCE_KEEP;
}

// How many dynamic buffers were made and written (tests and the
// statistics see a frame write each once).
export let instanceMakes: u32 = 0;
export let instanceUpdates: u32 = 0;

// The vertex buffer holding `data`'s instances (see the header), made or
// written as instanceAction says and kept on `data`; null when there is no
// instance, or the host refused the buffer (the caller then does not draw
// the item). A dynamic data's replaced buffer goes onto `retired` (null:
// released at once, for a caller that records no view).
export function instanceBuffer(data: InstanceData, retired: Array<GPUBuffer>? = null): GPUBuffer? {
    const a = instanceAction(data);
    const g = data.gpu;
    if (a == INSTANCE_KEEP) return g != null ? (g as GpuInstanceBuffer).buffer : null;
    if (a == INSTANCE_NONE) return null;
    if (a == INSTANCE_UPDATE) {
        const kept = g as GpuInstanceBuffer;
        kept.buffer.update(0, data.bytes, data.count * INSTANCE_STRIDE);
        kept.version = data.version;
        instanceUpdates++;
        return kept.buffer;
    }
    if (a == INSTANCE_REMAKE) {
        const old = takeInstanceBuffer(data);
        if (old != null) {
            if (retired != null) retired.push(old);
            else old.release();
        }
        if (data.count == 0) return null;
    }
    const n = <u32>data.bytes.byteLength;
    if (!data.dynamic) {
        const b = new GPUBuffer(BufferUsage.vertex, n, data.bytes, true);
        if (b.handle == 0) return null;
        data.gpu = new GpuInstanceBuffer(b);
        return b;
    }
    const b = new GPUBuffer(BufferUsage.vertex, n, data.bytes, false);
    if (b.handle == 0) return null;
    const made = new GpuInstanceBuffer(b);
    made.version = data.version;
    made.length = data.bytes.byteLength;
    data.gpu = made;
    instanceMakes++;
    return b;
}

// Takes `data`'s uploaded buffer off it (null when none was uploaded): the
// caller releases it once no recorded view draws it. A later draw of the
// same data uploads it again.
export function takeInstanceBuffer(data: InstanceData): GPUBuffer? {
    const g = data.gpu;
    if (g == null) return null;
    data.gpu = null;
    return (g as GpuInstanceBuffer).buffer;
}

// Milestone 61: the vertex buffer of `data`'s extra stream (instances.as's
// header), which the custom shaders' instanced pipelines read: `extra` as
// packed, uploaded once into an immutable buffer; for a data without one
// (a dynamic data's) its indices, for its whole capacity (bytes'
// instances: the indices stay those of the slots, whatever the count),
// made again when the capacity changes, the old buffer onto `retired`.
// Kept on data.extraGpu; null when the host refused the buffer (the item is
// then drawn with its fallback).
export function instanceExtraBuffer(data: InstanceData, retired: Array<GPUBuffer>? = null): GPUBuffer? {
    const g = data.extraGpu;
    const packed = data.extra;
    const capacity = packed != null ? 0 : data.bytes.byteLength / <i32>INSTANCE_STRIDE;
    if (g != null) {
        const kept = g as GpuInstanceBuffer;
        if (packed != null || kept.length == capacity) return kept.buffer;
        data.extraGpu = null;
        if (retired != null) retired.push(kept.buffer);
        else kept.buffer.release();
    }
    const bytes = packed != null ? packed : instanceIndexStream(capacity);
    if (bytes.byteLength == 0) return null;
    const b = new GPUBuffer(BufferUsage.vertex, <u32>bytes.byteLength, bytes, true);
    if (b.handle == 0) return null;
    const made = new GpuInstanceBuffer(b);
    made.length = capacity;
    data.extraGpu = made;
    return b;
}

// Takes `data`'s extra stream buffer off it (takeInstanceBuffer's rule).
export function takeInstanceExtraBuffer(data: InstanceData): GPUBuffer? {
    const g = data.extraGpu;
    if (g == null) return null;
    data.extraGpu = null;
    return (g as GpuInstanceBuffer).buffer;
}
