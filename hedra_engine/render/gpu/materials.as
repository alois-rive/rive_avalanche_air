// The device side of materials: texture upload (with the CPU mip chain), the
// material sampler and the group-2 bind groups. The rest (cache, fallbacks,
// warnings, the uniform) is engine/src/render/material.as, which calls this
// backend.
//
// rive has no sRGB texture formats. Color textures (base color, emission,
// and the white / magenta fallbacks) must be decoded to linear before
// filtering, as an sRGB format would do, so they are uploaded as
// `rgba16float` holding exactly those decoded values (each
// mip level decoded from the bytes `half` produced, as the GPU would), so
// filtering still happens in linear space and the shader samples linear
// values unchanged. Data textures (normal, metallic-roughness, occlusion)
// stay `rgba8unorm` bytes.
//
// Milestone 14, part 2: binding 7 is the extension array (the textures of
// glTF's extension slots, one layer each, all one size: material.as
// `extArray` composes them). It is `rgba8unorm` holding the files' bytes,
// sRGB slots included, which surface.wgsl decodes after filtering (an
// array cannot mix formats). Every group binds one: a material without
// MAT_EXT the backend's one white layer.
//
// Milestone 26: a texture's processed form (a CompressedImage: BC, ETC2,
// ASTC or rgba8, hedra_engine/texture/format.as) is uploaded as it is, every
// level the import made, in the rive/gpu_enums format of its block format,
// when the device takes it (`supports`: rive/gpu gpuFeatures, read once).
// None of those formats has an sRGB variant, so a colour texture is
// sampled as stored and surface.wgsl decodes the sRGB curve after
// sampling (the material's MAT_SRGB_* bits, set by the binder).
//
// Milestone 67b (docs/engine/RESOURCES.md, "Loading" and "Lifetimes"): a
// mip chain is built level by level in pooled buffers (../../base/
// scratch.as: each level halved from the one before, converted for the
// device, uploaded, and its buffer given back), never as a whole chain of
// images and their converted copies at once; the bytes uploaded are those
// of before. The GPU backend releases the texture of a freed resource
// through the GpuRelease it makes for each upload (`releaser`), at once
// when the ledger asks (a frame after the free: ledger.as).

import {
    GPUBindGroup, GPUBindGroupSampler, GPUBindGroupTexture, GPUBindGroupUBO, GPUBindGroupLayout, GPUBuffer, GPUFeatures,
    GPUSampler, GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc, gpuFeatures,
} from "rive/gpu";
import { BufferUsage, Filter, TextureFormat, TextureType, TextureViewDimension, WrapMode } from "rive/gpu_enums";
import { Image, Rgba, srgbToLinear } from "../image";
import { MaterialBackend, MaterialUniformBox, TextureFamilies, halfInto, halfSide, mipChain, mipLevelCount } from "../material";
import { BlockFormat, CompressedImage, blockBytes, blockHeight, blockRows, blockWidth, rowBytes } from "../../texture/format";
import { MATERIAL_TEXTURES, MATERIAL_UNIFORM_SIZE } from "./layouts";
import { uploadRegion } from "./upload";
import { GpuRelease, LEDGER_TEXTURE } from "./ledger";
import { ScratchPool, SCRATCH_MIN_SHIFT, scratch } from "../../base/scratch";

// IEEE 754 binary16 bits of `x`, rounded to nearest, ties to even (the
// conversion a GPU applies when it stores an f32 into a half-float texel).
export function f32ToF16Bits(x: f32): u16 {
    const b = reinterpret<u32>(x);
    const sign = (b >> 16) & 0x8000;
    const exp = <i32>((b >> 23) & 0xff);
    let mant = b & 0x7fffff;
    if (exp == 255) {
        return <u16>(sign | 0x7c00 | (mant != 0 ? 0x200 : 0));
    }
    const e = exp - 127 + 15;
    if (e >= 31) {
        return <u16>(sign | 0x7c00);
    }
    if (e <= 0) {
        // Subnormal half (or zero).
        if (e < -10) return <u16>sign;
        mant |= 0x800000;
        const shift = <u32>(14 - e);
        let h = mant >> shift;
        const rem = mant & ((<u32>1 << shift) - 1);
        const halfway = <u32>1 << (shift - 1);
        if (rem > halfway || (rem == halfway && (h & 1) != 0)) h++;
        return <u16>(sign | h);
    }
    let h = (<u32>e << 10) | (mant >> 13);
    const rem = mant & 0x1fff;
    // A carry out of the mantissa rolls into the exponent, which is right
    // (and gives infinity past the largest half).
    if (rem > 0x1000 || (rem == 0x1000 && (h & 1) != 0)) h++;
    return <u16>(sign | h);
}

// Half-float bits of each sRGB byte decoded to linear (the sRGB texture
// read) and of each byte as plain unorm (the alpha channel).
let srgbLut: StaticArray<u16>? = null;
let unormLut: StaticArray<u16>? = null;

function luts(): void {
    if (srgbLut != null) return;
    const s = new StaticArray<u16>(256);
    const u = new StaticArray<u16>(256);
    for (let i = 0; i < 256; i++) {
        const v = <f32>i / <f32>255.0;
        s[i] = f32ToF16Bits(srgbToLinear(v));
        u[i] = f32ToF16Bits(v);
    }
    srgbLut = s;
    unormLut = u;
}

// The texel bytes of one level: RGBA8 as is, or (sRGB) rgba16float of the
// decoded color and the unorm alpha.
export function levelBytes(img: Image, srgb: bool): ArrayBuffer {
    const n = <i32>(img.width * img.height);
    const d = img.data;
    if (!srgb) {
        const out = new ArrayBuffer(n * 4);
        const o = Uint8Array.wrap(out);
        for (let i = 0; i < n * 4; i++) o[i] = d[i];
        return out;
    }
    luts();
    const s = srgbLut!;
    const u = unormLut!;
    const out = new ArrayBuffer(n * 8);
    const dv = new DataView(out, 0, out.byteLength);
    for (let i = 0; i < n; i++) {
        dv.setUint16(i * 8, s[d[i * 4]], true);
        dv.setUint16(i * 8 + 2, s[d[i * 4 + 1]], true);
        dv.setUint16(i * 8 + 4, s[d[i * 4 + 2]], true);
        dv.setUint16(i * 8 + 6, u[d[i * 4 + 3]], true);
    }
    return out;
}

// Milestone 67b: `levelBytes` written into `out` (exactly the level's
// bytes: 4 or 8 a texel), from the `w` x `h` RGBA8 texels `d`.
export function levelBytesInto(d: Uint8Array, w: u32, h: u32, srgb: bool, out: Uint8Array): void {
    const n = <i32>(w * h);
    if (!srgb) {
        for (let i = 0; i < n * 4; i++) unchecked(out[i] = unchecked(d[i]));
        return;
    }
    luts();
    const s = srgbLut!;
    const u = unormLut!;
    const dv = new DataView(out.buffer, out.byteOffset, n * 8);
    for (let i = 0; i < n; i++) {
        dv.setUint16(i * 8, s[d[i * 4]], true);
        dv.setUint16(i * 8 + 2, s[d[i * 4 + 1]], true);
        dv.setUint16(i * 8 + 4, s[d[i * 4 + 2]], true);
        dv.setUint16(i * 8 + 6, u[d[i * 4 + 3]], true);
    }
}

// Milestone 67b: where `uploadLevels` hands each level (the texture's
// upload; a test's capture).
export abstract class TextureLevelSink {
    // Level `mip`, `w` x `h` texels, `bytesPerRow` bytes a row: the first
    // bytesPerRow * h bytes of `data`, which is exactly that long.
    abstract level(mip: u32, w: u32, h: u32, bytesPerRow: u32, data: ArrayBuffer): void;
}

// Whether a pooled buffer for `bytes` bytes is exactly that long (a
// buffer the device is handed must be: scratch.as hands out power-of-two
// buffers from 4 KiB).
function poolsExactly(bytes: i32): bool {
    return bytes >= (1 << SCRATCH_MIN_SHIFT) && (bytes & (bytes - 1)) == 0;
}

// Milestone 67b: `img`'s whole mip chain (`mipChain`'s levels: level 0
// the image, each next one `half` of the one before), each converted as
// `levelBytes` converts it, handed to `sink` level by level, level 0
// first: the bytes uploadTexture always uploaded, made in `pool`'s buffers
// (taken and given back as each level is done, so a chain holds two
// levels at once, never the whole chain twice). A converted level whose
// size is a pooled buffer's exactly (a power of two from 4 KiB: every
// level of a power-of-two texture of 1024 texels or more, 512 for
// rgba16float) is converted into one; a smaller level, or one of a texture
// whose sides are not powers of two, into a buffer of its own, which the
// device wants exactly as long as the level. An rgba8 level whose texels
// fill their buffer exactly (the image's own, or a pooled level's) is
// handed over as it is.
export function uploadLevels(img: Image, srgb: bool, sink: TextureLevelSink, pool: ScratchPool = scratch()): void {
    const levels = <i32>mipLevelCount(img.width, img.height);
    const bpp: u32 = srgb ? 8 : 4;
    let cur = img.data;
    let w = img.width;
    let h = img.height;
    // The pooled buffer `cur` is (null: level 0, the image's own).
    let held: Uint8Array? = null;
    for (let mip = 0; mip < levels; mip++) {
        const bytes = <i32>(w * h * bpp);
        if (!srgb && cur.byteOffset == 0 && cur.buffer.byteLength == bytes) {
            // (the image's texels as they are: no copy)
            sink.level(<u32>mip, w, h, w * bpp, cur.buffer);
        } else if (poolsExactly(bytes)) {
            const out = pool.take(bytes);
            levelBytesInto(cur, w, h, srgb, out);
            sink.level(<u32>mip, w, h, w * bpp, out.buffer);
            pool.give(out);
        } else {
            const out = new Uint8Array(bytes);
            levelBytesInto(cur, w, h, srgb, out);
            sink.level(<u32>mip, w, h, w * bpp, out.buffer);
        }
        if (mip + 1 < levels) {
            const nw = halfSide(w);
            const nh = halfSide(h);
            const next = pool.take(<i32>(nw * nh * 4));
            halfInto(cur, w, h, next);
            if (held != null) pool.give(held);
            held = next;
            cur = next;
            w = nw;
            h = nh;
        }
    }
    if (held != null) pool.give(held);
}

// The sink of uploadTexture: each level into the texture.
class TextureUpload extends TextureLevelSink {
    texture: GPUTexture;

    constructor(texture: GPUTexture) {
        super();
        this.texture = texture;
    }

    level(mip: u32, w: u32, h: u32, bytesPerRow: u32, data: ArrayBuffer): void {
        this.texture.upload(uploadRegion(w, h, mip, 0, 0, 0, bytesPerRow), data);
    }
}

// A texture with the full
// mip chain (`mipChain`), sampled as linear values (its levels made in
// pooled buffers: uploadLevels).
export function uploadTexture(img: Image, srgb: bool): GPUTexture {
    const desc = new GPUTextureDesc();
    desc.width = img.width;
    desc.height = img.height;
    desc.format = srgb ? TextureFormat.rgba16float : TextureFormat.rgba8unorm;
    desc.numMipmaps = mipLevelCount(img.width, img.height);
    desc.sampleCount = 1;
    desc.renderTarget = false;
    const texture = new GPUTexture(desc);
    uploadLevels(img, srgb, new TextureUpload(texture));
    return texture;
}

// The device's block-compression families (rive/gpu gpuFeatures), asked
// once: the answer does not change while the program runs, and asking
// makes an object each time. A device whose backend's upload layout is not
// known (uploadLayoutOf: UPLOAD_NONE) answers no family, so that every
// form is decoded on the CPU (or a bundle's rgba8 or source read) rather
// than uploaded in a layout its backend refuses.
let families: TextureFamilies? = null;

export function deviceFamilies(): TextureFamilies {
    let f = families;
    if (f == null) {
        const g: GPUFeatures = gpuFeatures();
        const p = new DeviceProfile();
        p.known = g.known;
        p.bc = g.bc;
        p.etc2 = g.etc2;
        p.astc = g.astc;
        p.drawBaseInstance = g.drawBaseInstance;
        p.perTargetBlend = g.perTargetBlend;
        p.maxColorAttachments = g.maxColorAttachments;
        p.maxTextureSize2D = g.maxTextureSize2D;
        p.maxTextureSize3D = g.maxTextureSize3D;
        p.maxSamplers = g.maxSamplers;
        p.maxUniformBufferSize = g.maxUniformBufferSize;
        // (the shell says its backend: useHostBackend; anywhere else, a
        // Rive player, the features tell)
        const layout = hostBackendSaid ? (glBlockUploads ? UPLOAD_GL : UPLOAD_ROWS) : uploadLayoutOf(p);
        uploadLayout = layout;
        wholeBlocksOnly = hostBackendSaid ? hostD3d : isD3dProfile(p);
        glBlockUploads = layout == UPLOAD_GL;
        f = layout == UPLOAD_NONE ? TextureFamilies.of(g.known, false, false, false) : TextureFamilies.of(g.known, g.bc, g.etc2, g.astc);
        families = f;
    }
    return f;
}

// The rive/gpu_enums format of a block format (rgba8: rgba8unorm).
export function gpuFormatOf(f: BlockFormat): TextureFormat {
    switch (f) {
        case BlockFormat.Bc1: return TextureFormat.bc1unorm;
        case BlockFormat.Bc3: return TextureFormat.bc3unorm;
        case BlockFormat.Bc7: return TextureFormat.bc7unorm;
        case BlockFormat.Etc2Rgb: return TextureFormat.etc2rgb8;
        case BlockFormat.Etc2Rgba: return TextureFormat.etc2rgba8;
        case BlockFormat.Astc4x4: return TextureFormat.astc4x4;
        case BlockFormat.Astc6x6: return TextureFormat.astc6x6;
        case BlockFormat.Astc8x8: return TextureFormat.astc8x8;
        default: return TextureFormat.rgba8unorm;
    }
}

// How a block-compressed level is described to ore's upload, which differs
// by backend in the pinned runtime. ore checks rowsPerImage against the
// level's height in texels (ore_texture.hpp: "rowsPerImage %u is less than
// height %u") and the data against bytesPerRow x rowsPerImage. Metal's
// replaceRegion and D3D's row pitch read bytesPerRow as the bytes of one row
// of blocks, so there rowsPerImage is the height in texels and the level's
// blocks are handed over in a buffer of that size, zeros after them. ore's GL
// backend passes bytesPerRow x rowsPerImage as glCompressedTexSubImage2D's
// imageSize, which GL requires to be the level's size exactly, so there
// bytesPerRow is the blocks across (a row of blocks divided by the bytes of
// a block) and rowsPerImage the rows of blocks times the bytes of a block:
// their product is the level's size, and rowsPerImage (at least 8 x the rows
// of blocks, with blocks at most 8 texels high) still covers the height.
// (Vulkan refuses block formats and WebGPU wants 256-byte strides: on
// those devices, and any other not recognised, deviceFamilies answers no
// family, so nothing is uploaded as it is: uploadLayoutOf.)
let glBlockUploads = false;
// Whether useHostBackend was called (the shell's programs), and the layout
// deviceFamilies settled on.
let hostBackendSaid = false;
let uploadLayout: i32 = -1;
// Direct3D wants level 0 of a block-compressed texture to be whole blocks
// (a multiple of 4 each way for BC) unless D3D12 reports
// UnalignedBlockTexturesSupported, which the script API cannot ask; ore's
// D3D backends check nothing. On D3D (the shell's "; d3d11" or "; d3d12",
// else isD3dProfile) such a texture is decoded on the CPU instead
// (takesBlockSize). Metal and GL take any size. Textures are almost
// always whole blocks (powers of two), so this costs nothing in practice.
let hostD3d = false;
let wholeBlocksOnly = false;

// The upload layouts (deviceFamilies, uploadLayoutOf): Metal's and D3D's
// rows of blocks; GL's level size exactly; none known (Vulkan, whose ore
// backend refuses block formats, WebGPU, whose strides must be multiples of
// 256 bytes, and anything not recognised), where no form is uploaded as it
// is.
export const UPLOAD_ROWS: i32 = 0;
export const UPLOAD_GL: i32 = 1;
export const UPLOAD_NONE: i32 = 2;
export const UPLOAD_LAYOUT_NAMES: StaticArray<string> = ["rows", "gl", "none"];

// What a device's rive/gpu GPUFeatures says that tells its backend apart
// (a class of plain fields, so the choice is tested without a device).
export class DeviceProfile {
    known: bool = false;
    bc: bool = false;
    etc2: bool = false;
    astc: bool = false;
    drawBaseInstance: bool = false;
    perTargetBlend: bool = false;
    maxColorAttachments: u32 = 0;
    maxTextureSize2D: u32 = 0;
    maxTextureSize3D: u32 = 0;
    maxSamplers: u32 = 0;
    maxUniformBufferSize: u32 = 0;
}

// The upload layout of the device `p` describes. The script API names no
// backend, so the run time tells it from the features ore's
// backends report in the pinned runtime (renderer/src/ore/*/ore_context_*):
//   - GL alone reports neither drawBaseInstance nor perTargetBlend (GLES3,
//     and desktop GL the same): UPLOAD_GL;
//   - Metal reports constants: 8 colour attachments, 16384 x 16384 2D and
//     2048 3D textures, 16 samplers and 256 KiB uniform buffers (macOS bc
//     alone, iOS etc2 and astc): UPLOAD_ROWS;
//   - D3D11 and D3D12 the same limits with 64 KiB uniform buffers and bc
//     alone: UPLOAD_ROWS;
//   - anything else (Vulkan, whose limits are the device's own; WebGPU's 4
//     colour attachments and etc2 alone): UPLOAD_NONE.
// A Vulkan device whose limits happened to be exactly D3D's or Metal's
// would be taken for one; none of the limits above is a common Vulkan
// figure for all five together.
// Whether `p` is a Direct3D device's profile (see uploadLayoutOf).
export function isD3dProfile(p: DeviceProfile): bool {
    return p.known && (p.drawBaseInstance || p.perTargetBlend) && p.maxColorAttachments == 8
        && p.maxTextureSize2D == 16384 && p.maxTextureSize3D == 2048 && p.maxSamplers == 16
        && p.maxUniformBufferSize == 64 * 1024 && p.bc && !p.etc2 && !p.astc;
}

// Whether a device that wants whole blocks (`wholeOnly`: Direct3D, see
// wholeBlocksOnly) uploads a `w` x `h` level 0 of `f` as it is.
export function takesBlockSize(f: BlockFormat, w: u32, h: u32, wholeOnly: bool): bool {
    if (!wholeOnly || f == BlockFormat.Rgba8) return true;
    return w % blockWidth(f) == 0 && h % blockHeight(f) == 0;
}

// Whether a device of families `f` uploads `img` as it is: its format,
// and on Direct3D its size (takesBlockSize). The binder's choice and
// render's answer (`textures`) both ask this.
export function familiesTakeImage(f: TextureFamilies, img: CompressedImage): bool {
    if (!f.takes(img.format)) return false;
    deviceFamilies();
    return takesBlockSize(img.format, img.width, img.height, wholeBlocksOnly);
}

export function uploadLayoutOf(p: DeviceProfile): i32 {
    if (!p.known) return UPLOAD_NONE;
    if (!p.drawBaseInstance && !p.perTargetBlend) return UPLOAD_GL;
    const limits = p.maxColorAttachments == 8 && p.maxTextureSize2D == 16384 && p.maxTextureSize3D == 2048
        && p.maxSamplers == 16;
    if (limits && p.maxUniformBufferSize == 256 * 1024) return UPLOAD_ROWS;
    if (limits && p.maxUniformBufferSize == 64 * 1024 && p.bc && !p.etc2 && !p.astc) return UPLOAD_ROWS;
    return UPLOAD_NONE;
}

// The layout deviceFamilies settled on (UPLOAD_*), asking it first.
export function deviceUploadLayout(): i32 {
    deviceFamilies();
    return uploadLayout;
}

// Tells the uploads which backend the host draws with, from the start
// message's `host.runtime` ("rive-runtime v0.1.452; gl"): only "gl" changes
// anything. A program calls it once, as it starts, before deviceFamilies;
// the run time does not, and deviceFamilies tells the backend
// from the device's features instead (uploadLayoutOf).
export function useHostBackend(runtime: string): void {
    glBlockUploads = runtime.endsWith("; gl");
    hostD3d = runtime.includes("; d3d");
    hostBackendSaid = true;
}

// The bytesPerRow of an upload of a `w` x `h` level of `f` (see above).
// An rgba8 form (vram_uncompressed) is no block format: GL uploads it with
// glTexSubImage2D, which reads bytesPerRow as the row's bytes (ore sets
// GL_UNPACK_ROW_LENGTH from it), so it keeps the plain layout everywhere.
export function blockUploadBytesPerRow(f: BlockFormat, w: u32, gl: bool): u32 {
    const row = rowBytes(f, w);
    return gl && f != BlockFormat.Rgba8 ? row / blockBytes(f) : row;
}

// The rowsPerImage of that upload (see above).
export function blockUploadRows(f: BlockFormat, h: u32, gl: bool): u32 {
    const rows = blockRows(f, h);
    return gl && f != BlockFormat.Rgba8 ? rows * blockBytes(f) : max<u32>(h, rows);
}

// A texture of `img`'s block format with every level it holds, each
// uploaded as it is, described as the host's backend reads it
// (blockUploadBytesPerRow, blockUploadRows).
export function uploadCompressedTexture(img: CompressedImage): GPUTexture {
    const desc = new GPUTextureDesc();
    desc.width = img.width;
    desc.height = img.height;
    desc.format = gpuFormatOf(img.format);
    desc.numMipmaps = <u32>max<i32>(img.levels.length, 1);
    desc.sampleCount = 1;
    desc.renderTarget = false;
    const texture = new GPUTexture(desc);
    if (texture.handle == 0) return texture;
    // (the layout is settled with the families, which the binder asks
    // before it uploads anything)
    deviceFamilies();
    const gl = glBlockUploads;
    for (let mip = 0; mip < img.levels.length; mip++) {
        const level = img.levels[mip];
        const row = blockUploadBytesPerRow(img.format, level.width, gl);
        const rows = blockUploadRows(img.format, level.height, gl);
        const d = level.data;
        const buf = new ArrayBuffer(<i32>(row * rows));
        Uint8Array.wrap(buf).set(d.subarray(0, min<i32>(d.length, buf.byteLength)), 0);
        texture.upload(uploadRegion(level.width, level.height, <u32>mip, 0, 0, 0, row, rows), buf);
    }
    return texture;
}

// The binding of the extension array (surface.wgsl's t_ext).
export const EXT_ARRAY_BINDING: u32 = 7;

// A 2D array texture of `layers` (all one size), each layer with its full
// mip chain, rgba8unorm bytes as they are.
export function uploadArrayTexture(layers: Array<Image>): GPUTexture {
    const chains: Array<Array<Image>> = [];
    for (let i = 0; i < layers.length; i++) chains.push(mipChain(layers[i]));
    const desc = new GPUTextureDesc();
    desc.width = layers[0].width;
    desc.height = layers[0].height;
    desc.depthOrArrayLayers = <u32>layers.length;
    desc.textureType = TextureType.array2D;
    desc.format = TextureFormat.rgba8unorm;
    desc.numMipmaps = <u32>chains[0].length;
    desc.sampleCount = 1;
    desc.renderTarget = false;
    const texture = new GPUTexture(desc);
    if (texture.handle == 0) return texture;
    for (let layer = 0; layer < chains.length; layer++) {
        const levels = chains[layer];
        for (let mip = 0; mip < levels.length; mip++) {
            const level = levels[mip];
            texture.upload(uploadRegion(level.width, level.height, <u32>mip, <u32>layer), levelBytes(level, false));
        }
    }
    return texture;
}

// The view a `texture_2d_array` binding samples: every layer, every level.
function arrayView(t: GPUTexture, layers: u32): GPUTextureView {
    const d = new GPUTextureViewDesc();
    d.dimension = TextureViewDimension.array2D;
    d.layerCount = layers;
    return t.view(d);
}

// `MaterialBackend` on the host GPU: views are `GPUTextureView`s, groups
// `GPUBindGroup`s of the surface module's material layout.
export class GpuMaterialBackend extends MaterialBackend<GPUTextureView, GPUBindGroup> {
    layout: GPUBindGroupLayout;
    // Repeat, linear, mip linear.
    sampler: GPUSampler;
    // Every texture uploaded and still held, kept alive with its view
    // (`views[i]` is `textures[i]`'s).
    textures: Array<GPUTexture> = [];
    views: Array<GPUTextureView> = [];
    // Released textures, freed at the next `releaseCreated` (the renderer's
    // next `beginFrame`), once the frame that may bind them is recorded.
    private released: Array<GPUTexture> = [];
    private releasedViews: Array<GPUTextureView> = [];
    // Groups (and their uniform buffers) made since the last `keepCreated` /
    // `releaseCreated`. A material's group lives for one view; the renderer
    // releases them at its next
    // `beginFrame`, once the frame that used them is recorded.
    private createdGroups: Array<GPUBindGroup> = [];
    private createdBuffers: Array<GPUBuffer> = [];
    // The uniform buffer of the group `group` made last (milestone 25: the
    // renderer keeps it beside the group, to write a material's numbers
    // again in place).
    lastBuffer: GPUBuffer? = null;
    // Binding 7 of every group without an extension array of its own: one
    // white texel (kept for the backend's life).
    private emptyArray: GPUTexture;
    private emptyArrayView: GPUTextureView;

    constructor(layout: GPUBindGroupLayout) {
        super();
        this.layout = layout;
        this.sampler = new GPUSampler(Filter.linear, Filter.linear, Filter.linear, WrapMode.repeat, WrapMode.repeat);
        this.emptyArray = uploadArrayTexture([Image.new(1, 1, Rgba(255, 255, 255, 255))]);
        this.emptyArrayView = arrayView(this.emptyArray, 1);
    }

    uploadArray(label: string, layers: Array<Image>): GPUTextureView {
        const t = uploadArrayTexture(layers);
        const v = arrayView(t, <u32>layers.length);
        this.textures.push(t);
        this.views.push(v);
        return v;
    }

    upload(label: string, img: Image, srgb: bool): GPUTextureView {
        const t = uploadTexture(img, srgb);
        const v = t.view();
        this.textures.push(t);
        this.views.push(v);
        return v;
    }

    // Milestone 26: the device's families (deviceFamilies), or the ones a
    // test gives.
    families: TextureFamilies = deviceFamilies();

    supports(format: BlockFormat): bool {
        return this.families.takes(format);
    }

    // (and on Direct3D, whole blocks only: takesBlockSize)
    supportsImage(img: CompressedImage): bool {
        return familiesTakeImage(this.families, img);
    }

    uploadCompressed(label: string, img: CompressedImage, srgb: bool): GPUTextureView {
        const t = uploadCompressedTexture(img);
        const v = t.view();
        this.textures.push(t);
        this.views.push(v);
        return v;
    }

    release(view: GPUTextureView): void {
        for (let i = 0; i < this.views.length; i++) {
            if (this.views[i] !== view) continue;
            this.released.push(this.textures[i]);
            this.releasedViews.push(view);
            this.textures.splice(i, 1);
            this.views.splice(i, 1);
            return;
        }
    }

    // Milestone 67b: what releases `view`'s texture at once (see the
    // header): the run time's ledger calls it a frame after the resource
    // was freed. Released through these lists, so that a binder's own
    // `release` of the same view afterwards (or before: it is then in
    // `released`, freed at the next releaseCreated) releases nothing twice.
    releaser(view: GPUTextureView): GpuRelease? {
        return new BackendTextureRelease(this, view);
    }

    // Releases `view` and its texture now, when this backend still holds
    // them; false when it does not (released already).
    releaseNow(view: GPUTextureView): bool {
        for (let i = 0; i < this.views.length; i++) {
            if (this.views[i] !== view) continue;
            const t = this.textures[i];
            this.textures.splice(i, 1);
            this.views.splice(i, 1);
            view.release();
            t.release();
            return true;
        }
        return false;
    }

    // The material's bind group: its uniform, five views, the sampler and
    // the extension array (a sixth view, else the white one).
    group(u: MaterialUniformBox, views: Array<GPUTextureView>): GPUBindGroup {
        const buffer = new GPUBuffer(BufferUsage.uniform, MATERIAL_UNIFORM_SIZE, u.toBytes());
        const textures = new Array<GPUBindGroupTexture>();
        const n = views.length < <i32>MATERIAL_TEXTURES ? views.length : <i32>MATERIAL_TEXTURES;
        for (let i = 0; i < n; i++) {
            textures.push(new GPUBindGroupTexture(<u32>i + 1, views[i]));
        }
        const ext = views.length > <i32>MATERIAL_TEXTURES ? views[MATERIAL_TEXTURES] : this.emptyArrayView;
        textures.push(new GPUBindGroupTexture(EXT_ARRAY_BINDING, ext));
        const g = new GPUBindGroup(
            this.layout,
            [new GPUBindGroupUBO(0, buffer)],
            textures,
            [new GPUBindGroupSampler(MATERIAL_TEXTURES + 1, this.sampler)],
        );
        this.createdGroups.push(g);
        this.createdBuffers.push(buffer);
        this.lastBuffer = buffer;
        return g;
    }

    // Keep everything made so far (the default material's group). The
    // lists keep their storage (here and below): the renderer calls these
    // every frame, and the stub runtime never frees.
    keepCreated(): void {
        this.createdGroups.length = 0;
        this.createdBuffers.length = 0;
    }

    // Hands the groups (and their uniform buffers) made since the last call
    // over to the caller, appended to `groups` and `buffers`, which then
    // releases them itself: the renderer keeps a frame's material groups
    // for the frames that draw the same materials (milestone 13).
    takeCreated(groups: Array<GPUBindGroup>, buffers: Array<GPUBuffer>): void {
        for (let i = 0; i < this.createdGroups.length; i++) groups.push(this.createdGroups[i]);
        for (let i = 0; i < this.createdBuffers.length; i++) buffers.push(this.createdBuffers[i]);
        this.keepCreated();
    }

    // Release the groups made since the last call (a finished frame's).
    releaseCreated(): void {
        for (let i = 0; i < this.createdGroups.length; i++) this.createdGroups[i].release();
        for (let i = 0; i < this.createdBuffers.length; i++) this.createdBuffers[i].release();
        for (let i = 0; i < this.releasedViews.length; i++) this.releasedViews[i].release();
        for (let i = 0; i < this.released.length; i++) this.released[i].release();
        this.released.length = 0;
        this.releasedViews.length = 0;
        this.keepCreated();
    }
}

// Milestone 67b: a texture of a GpuMaterialBackend, released through it
// (GpuMaterialBackend.releaser). Its bytes are the upload's, which the
// share charged (TextureShare: the ledger's figure is the share's, this
// object only releases).
class BackendTextureRelease extends GpuRelease {
    backend: GpuMaterialBackend;
    view: GPUTextureView;

    constructor(backend: GpuMaterialBackend, view: GPUTextureView) {
        super();
        this.backend = backend;
        this.view = view;
    }

    release(): void {
        this.backend.releaseNow(this.view);
    }

    bytes(): i64 {
        return 0;
    }

    kind(): i32 {
        return LEDGER_TEXTURE;
    }
}
