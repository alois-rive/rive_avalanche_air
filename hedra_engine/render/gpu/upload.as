// The one upload region every texture upload of the renderer fills.
//
// A `rive_gpu_texture_upload_v1` is unmanaged: the collector never frees
// it, so an instance made per upload lives as long as the program (rive
// 1.6's lint says so, W3006, where a function makes one and drops it).
// The renderer's uploads all happen on the one thread that draws, each
// filling the region and handing it to `GPUTexture.upload` before the
// next, so one instance, made the first time it is asked for, serves them
// all. A caller must not keep the returned region across another call.

import { rive_gpu_texture_upload_v1 } from "rive/bindings";

let shared: rive_gpu_texture_upload_v1? = null;

// The region of a `w` x `h` block at (x, y) of mip `mip` of layer `layer`.
// `bytesPerRow` 0 is `w` four-byte texels (rgba8unorm); a caller uploading
// other texels (rgba16float: 8 bytes) or blocks says how many. `rowsPerImage`
// 0 is `h` rows; a block-compressed upload says how many rows of blocks.
export function uploadRegion(
    w: u32, h: u32, mip: u32, layer: u32,
    x: u32 = 0, y: u32 = 0, bytesPerRow: u32 = 0, rowsPerImage: u32 = 0,
): rive_gpu_texture_upload_v1 {
    let r = shared;
    if (r == null) {
        r = new rive_gpu_texture_upload_v1();
        shared = r;
    }
    r.bytesPerRow = bytesPerRow != 0 ? bytesPerRow : w * 4;
    r.rowsPerImage = rowsPerImage != 0 ? rowsPerImage : h;
    r.mipLevel = mip;
    r.layer = layer;
    r.x = x;
    r.y = y;
    r.z = 0;
    r.width = w;
    r.height = h;
    r.depth = 1;
    return r;
}
