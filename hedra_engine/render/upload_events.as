// What the uploaders tell the program (milestone 67b,
// docs/engine/RESOURCES.md): a texture or a mesh went up to the GPU, or was
// let go of. The run time listens to release the CPU copy an upload made
// redundant (../scene/resource/cpu_copy.as, Godot's textures keeping the
// RID and not the Image) and to charge the GPU ledger
// (gpu/ledger.as) to the resource the upload belongs to
// (../scene/resource/cache.as). The tools install no listener: everything
// stays as it was, and every picture with it.
//
// The emitters are called by TextureShare (material.as: upload,
// uploadCompressed) and by GpuMeshUploader (gpu/mesh_cache.as: upload)
// right after the device has the data; a listener must not change what
// was drawn or bound (it may drop CPU arrays the GPU no longer needs). With
// no listener an emit costs one length test, and a listener allocates
// nothing per frame (uploads happen at load, not every frame).
//
// Its listeners: the run time's resource cache (charging each upload to
// the resource that owns it: ../scene/runtime/runtime_resources.as) and
// the CPU-copy releaser (../scene/resource/cpu_copy.as).

import { Image } from "./image";
import { GpuMesh } from "./mesh";
import { CompressedImage } from "../texture/format";

export abstract class UploadListener {
    // `img` went up as one texture sampled as `srgb` says, `bytes` on the
    // device (`form` null), or the compressed form `form` did (`img`
    // null), or `img`, decoded on the CPU from `form`, did (both set: a
    // device that takes none of the texture's families).
    textureUploaded(img: Image?, form: CompressedImage?, srgb: bool, bytes: i64): void {}
    // The texture uploaded from `img` or `form` with `srgb` was let go of
    // (TextureShare.forget).
    textureForgotten(img: Image?, form: CompressedImage?, srgb: bool, bytes: i64): void {}
    // `mesh`'s buffers went up (`bytes` on the device, every buffer the
    // uploader made: GpuMeshBuffers).
    meshUploaded(mesh: GpuMesh, bytes: i64): void {}
    // `mesh`'s buffers were let go of.
    meshForgotten(mesh: GpuMesh, bytes: i64): void {}
}

// Null until the first listener (a constant initial value on purpose, as
// resource/loader.as's readers: a module that adds one by a top-level
// statement may run before this module's initialiser).
let listeners: Array<UploadListener>? = null;

function all(): Array<UploadListener> {
    let l = listeners;
    if (l == null) {
        l = new Array<UploadListener>();
        listeners = l;
    }
    return l;
}

// Adds a listener (once: the same object again is ignored).
export function addUploadListener(l: UploadListener): void {
    const a = all();
    for (let i = 0; i < a.length; i++) if (a[i] === l) return;
    a.push(l);
}

export function removeUploadListener(l: UploadListener): void {
    const a = all();
    for (let i = 0; i < a.length; i++) {
        if (a[i] === l) {
            a.splice(i, 1);
            return;
        }
    }
}

// How many listeners there are (tests).
export function uploadListenerCount(): i32 {
    const a = listeners;
    return a != null ? a.length : 0;
}

export function emitTextureUploaded(img: Image?, form: CompressedImage?, srgb: bool, bytes: i64): void {
    const a = listeners;
    if (a == null) return;
    for (let i = 0; i < a.length; i++) unchecked(a[i]).textureUploaded(img, form, srgb, bytes);
}

export function emitTextureForgotten(img: Image?, form: CompressedImage?, srgb: bool, bytes: i64): void {
    const a = listeners;
    if (a == null) return;
    for (let i = 0; i < a.length; i++) unchecked(a[i]).textureForgotten(img, form, srgb, bytes);
}

export function emitMeshUploaded(mesh: GpuMesh, bytes: i64): void {
    const a = listeners;
    if (a == null) return;
    for (let i = 0; i < a.length; i++) unchecked(a[i]).meshUploaded(mesh, bytes);
}

export function emitMeshForgotten(mesh: GpuMesh, bytes: i64): void {
    const a = listeners;
    if (a == null) return;
    for (let i = 0; i < a.length; i++) unchecked(a[i]).meshForgotten(mesh, bytes);
}
