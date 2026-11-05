// Materials on the GPU. A `MaterialDesc` is a material as the renderer
// draws it (glTF metallic-roughness, textures by file path); a program maps
// its own materials onto it (Hedra's render/material.as). Decoded textures
// cached by path and file stamp, the 1x1 fallbacks, and the per-material bind
// group (group 2) every surface pipeline binds. Only PNG is decoded; anything else,
// or a missing file, becomes a magenta texture plus a warning so a render
// never fails because of an asset.
//
// The decisions (which view goes in which binding, fallbacks, cache
// freshness, warnings, the uniform, the CPU mip chain) are here and pure.
// The device work is a `MaterialBackend<V, G>` the GPU side supplies:
// `upload` makes a texture view `V` from an image (use `mipChain` for the
// levels) and `group` makes a bind group `G` from a uniform and five views.
// File access goes through `TextureFiles` (`VfsTextureFiles` reads the
// app's VFS).
//
// Milestone 14, part 2 (glTF's whole material; docs/engine/SHADING.md):
// MaterialDesc carries every glTF property, and a material that uses one
// today's shading does not draw has MAT_EXT (`materialIsExt`). Only such a
// material reads the uniform's extended part (`materialExtUniform`: each
// texture slot's KHR_texture_transform and UV set, the extensions'
// factors) and a sixth view, the extension array (`extArray`: the textures
// of the extension slots composed on the CPU, `uploadArray`), and the
// renderer draws it with the extended pipelines. Every other material is
// bound exactly as before: five views, the first 80 bytes of the uniform.

import { Result, maxF32, clampF32, toAsciiLowercase } from "../base/util";
import { Vec4 } from "../base/vecmath";
import { Image, Rgba, srgbToLinear } from "./image";
import { RenderError } from "./errors";
import {
    MAT_EXT, MAT_ROUGHNESS_LAYER, MAT_SRGB_BASE, MAT_SRGB_EMISSION, MAT_UNLIT, MAT_VERTEX_COLOR, MAT_VERTEX_COLOR_SRGB,
    MATERIAL_BASE_SIZE,
    MATERIAL_UNIFORM_SIZE, MaterialExtUniform, MaterialUniform, U32x4, T_BASE, T_EMISSION, T_METALLIC_ROUGHNESS,
    T_NORMAL, T_OCCLUSION,
} from "./gpu/layouts";
import { PBR_SLOT_COUNT, PbrSlot, pbrSlotIsSrgb } from "../material/pbr";
import { vfs, ioErrorOf, IoErrorKind } from "../fs/vfs";
import { isAbsolute, join, extension, components } from "../fs/path";
import { BlockFormat, CompressedImage, TextureForm, blockFormatName, formOfBlockFormat } from "../texture/format";
import { decodeLevel } from "../texture/decode";
import { CustomMaterialDesc } from "./custom_material";
import { emitTextureForgotten, emitTextureUploaded, uploadListenerCount } from "./upload_events";
import { GpuRelease, imageUploadBytes } from "./gpu/ledger";
// (milestone 67b: a released CPU copy read again is a miss the run time
// counts; the extension arrays read their images' pixels, so pin them)
import { noteCpuMiss, pinForm, pinImage } from "../scene/resource/cpu_copy";

// How a material's alpha is used (the `flags.y` of its uniform).
export const ALPHA_OPAQUE: u32 = 0;
// Fragments below `alphaCutoff` are discarded.
export const ALPHA_MASK: u32 = 1;
export const ALPHA_BLEND: u32 = 2;

// The texture slots, in binding order (bindings 1 to 5 of the material
// group); the same numbers as Hedra's `TextureSlot`.
export const TEX_BASE: i32 = 0;
export const TEX_NORMAL: i32 = 1;
export const TEX_METALLIC_ROUGHNESS: i32 = 2;
export const TEX_EMISSION: i32 = 3;
export const TEX_OCCLUSION: i32 = 4;
// How many texture slots a material has.
export const TEX_COUNT: i32 = 5;

// Which texture slot needs sRGB decoding.
export function slotIsSrgb(slot: i32): bool {
    return slot == TEX_BASE || slot == TEX_EMISSION;
}

export function slotBit(slot: i32): u32 {
    switch (slot) {
        case TEX_BASE: return T_BASE;
        case TEX_NORMAL: return T_NORMAL;
        case TEX_METALLIC_ROUGHNESS: return T_METALLIC_ROUGHNESS;
        case TEX_EMISSION: return T_EMISSION;
        default: return T_OCCLUSION;
    }
}

// One texture's UV set and KHR_texture_transform (glTF's texCoord, offset,
// rotation in radians, scale), the identity by default.
export class TextureTransform {
    texCoord: i32 = 0;
    offset: Array<f32> = [0, 0];
    rotation: f32 = 0;
    scale: Array<f32> = [1, 1];

    // UV set 0 and the identity: what every texture was before milestone
    // 14's second part.
    isIdentity(): bool {
        return this.texCoord == 0 && this.offset[0] == 0 && this.offset[1] == 0 && this.rotation == 0
            && this.scale[0] == 1 && this.scale[1] == 1;
    }

    static identities(): Array<TextureTransform> {
        const a: Array<TextureTransform> = [];
        for (let i = 0; i < PBR_SLOT_COUNT; i++) a.push(new TextureTransform());
        return a;
    }
}

// The texture of slot `slot` (a PbrSlot) the binder reads for each of the
// five bindings' slots: TEX_* by PbrSlot 0 to 5 (metallic and roughness
// share the metallic-roughness binding).
function texOfSlot(slot: i32): i32 {
    switch (slot) {
        case PbrSlot.BaseColor: return TEX_BASE;
        case PbrSlot.Normal: return TEX_NORMAL;
        case PbrSlot.Occlusion: return TEX_OCCLUSION;
        case PbrSlot.Emissive: return TEX_EMISSION;
        default: return TEX_METALLIC_ROUGHNESS;
    }
}

// A material as the renderer draws it: glTF metallic-roughness. The
// defaults are those of Hedra's `Material` (0.8 grey, roughness 0.5).
export class MaterialDesc {
    // sRGB
    baseColor: Array<f32> = [0.8, 0.8, 0.8];
    alpha: f32 = 1.0;
    // sRGB
    emission: Array<f32> = [0.0, 0.0, 0.0];
    emissionStrength: f32 = 1.0;
    metallic: f32 = 0.0;
    roughness: f32 = 0.5;
    alphaMode: u32 = ALPHA_OPAQUE;
    alphaCutoff: f32 = 0.5;
    doubleSided: bool = false;
    // By TEX_*: the file path as written in the material (relative paths
    // resolve against the frame's `baseDir`), or null for none.
    textures: Array<string?> = [null, null, null, null, null];
    // Milestone 13 (Godot's vertex_color_use_as_albedo, vertex_color_is_srgb):
    // the albedo is multiplied by the vertex colour, which an instanced
    // item takes from its instance (instances.as) and every other draws as
    // white; the colour is sRGB and made linear first. Both off for every
    // material before, whose pictures do not change.
    vertexColorAsAlbedo: bool = false;
    vertexColorIsSrgb: bool = false;
    // Milestone 14 (Godot's uv1_scale and uv1_offset, x and y): every
    // texture is sampled at `uv * uvScale + uvOffset`, the coordinate taken
    // after its flip to image rows. The defaults leave it as it is, exactly
    // (Hedra's materials keep them).
    uvScale: Array<f32> = [1, 1];
    uvOffset: Array<f32> = [0, 0];

    // Milestone 14, part 2: the rest of glTF 2.0's material (glTF's
    // meanings and defaults, colours sRGB as above; docs/engine/SHADING.md
    // says how each is drawn). A material that uses none of it
    // (`materialIsExt` false: every Hedra material, every material
    // before) is drawn exactly as before.
    // normalTexture.scale and occlusionTexture.strength.
    normalScale: f32 = 1;
    occlusionStrength: f32 = 1;
    // KHR_materials_unlit.
    unlit: bool = false;
    // KHR_materials_ior, KHR_materials_specular.
    ior: f32 = 1.5;
    specular: f32 = 1;
    specularColor: Array<f32> = [1, 1, 1];
    // KHR_materials_transmission, KHR_materials_volume (attenuation
    // distance 0: never attenuated, glTF's +infinity),
    // KHR_materials_dispersion.
    transmission: f32 = 0;
    thickness: f32 = 0;
    // Milestone 62: Godot's refraction_scale, how far a thin wall (thickness
    // 0) moves the picture behind it along its normal, as a share of the
    // picture, when the frame refracts the screen (screen.as
    // thinRefractionOffset); read by nothing else, so every other frame
    // draws as before.
    refractionScale: f32 = 0.05;
    attenuationDistance: f32 = 0;
    attenuationColor: Array<f32> = [1, 1, 1];
    dispersion: f32 = 0;
    // KHR_materials_clearcoat.
    clearcoat: f32 = 0;
    clearcoatRoughness: f32 = 0;
    clearcoatNormalScale: f32 = 1;
    // KHR_materials_sheen.
    sheenColor: Array<f32> = [0, 0, 0];
    sheenRoughness: f32 = 0;
    // KHR_materials_iridescence (thicknesses in nanometres).
    iridescence: f32 = 0;
    iridescenceIor: f32 = 1.3;
    iridescenceThicknessMinimum: f32 = 100;
    iridescenceThicknessMaximum: f32 = 400;
    // KHR_materials_anisotropy (rotation in radians).
    anisotropyStrength: f32 = 0;
    anisotropyRotation: f32 = 0;
    // KHR_materials_diffuse_transmission.
    diffuseTransmission: f32 = 0;
    diffuseTransmissionColor: Array<f32> = [1, 1, 1];
    // By PbrSlot: each texture's UV set and KHR_texture_transform, before
    // uvScale and uvOffset (which move UV set 0 on top of it).
    slotUv: Array<TextureTransform> = TextureTransform.identities();
    // By PbrSlot, the textures of the slots the five bindings do not hold:
    // slots 6 to 19 (the extensions'), and Roughness when roughness is an
    // image of its own (metallic, or nothing, in TEX_METALLIC_ROUGHNESS).
    // They are drawn from one array texture (binding 7 of the material
    // group), each a layer.
    extTextures: Array<string?> = MaterialDesc.noTextures();
    // Which channels textures[TEX_METALLIC_ROUGHNESS] gives: metallic
    // (blue), roughness (green), both by default (glTF's packed image).
    metallicFromMr: bool = true;
    roughnessFromMr: bool = true;
    // Milestone 26: MAT_SRGB_BASE and MAT_SRGB_EMISSION (layouts.as), set by
    // MaterialBinder.bind when that slot's texture was uploaded as a block
    // format (which has no sRGB variant on the pinned runtime: the shader
    // decodes it after sampling). 0 for every material whose textures are
    // drawn from their sources, whose uniform is then what it was. Kept on
    // the description so that a renderer writing a bound material's uniform
    // again in place (FrameRenderer.rewriteMaterials) keeps the bits.
    srgbDecode: u32 = 0;
    // Godot's Material.render_priority (-128 to 127): a pass draws its
    // blended ranges in a stable order of it, lower first (so higher in
    // front), its opaque ones as before; 0 for every material, which draws
    // as it did.
    renderPriority: i32 = 0;
    // A ShaderMaterial's shader, its parameters and textures
    // (./custom_material.as): drawn with the custom pipelines
    // (gpu/custom.as) once its module is ready, and with the fields above
    // (its fallback) until then or when it cannot be. null for every other
    // material, which draws exactly as before.
    custom: CustomMaterialDesc? = null;

    // PBR_SLOT_COUNT empty slots. (A static method: the linter does not see
    // a function called from a field's initialiser.)
    static noTextures(): Array<string?> {
        const a = new Array<string?>(PBR_SLOT_COUNT);
        for (let i = 0; i < PBR_SLOT_COUNT; i++) a[i] = null;
        return a;
    }
}


function rgbIs(c: Array<f32>, v: f32): bool {
    return c[0] == v && c[1] == v && c[2] == v;
}

// The texture of PbrSlot `slot` is drawn (bound at its binding, or in a
// layer of the extension array).
export function slotDrawn(d: MaterialDesc, slot: i32): bool {
    if (slot == PbrSlot.Metallic) return d.textures[TEX_METALLIC_ROUGHNESS] != null && d.metallicFromMr;
    if (slot == PbrSlot.Roughness) {
        return d.extTextures[PbrSlot.Roughness] != null || (d.textures[TEX_METALLIC_ROUGHNESS] != null && d.roughnessFromMr);
    }
    if (slot < 6) return d.textures[texOfSlot(slot)] != null;
    return d.extTextures[slot] != null;
}

// Whether `d` needs the extended pipelines (MAT_EXT): it uses something
// today's shading does not draw. A value that changes nothing drawn (an
// extension's colour while its strength is 0, an attenuation without
// transmission) does not count, so switching a feature off draws the
// picture it drew before, byte for byte.
export function materialIsExt(d: MaterialDesc): bool {
    if (d.unlit || d.ior != 1.5 || d.specular != 1 || !rgbIs(d.specularColor, 1)) return true;
    if (d.extTextures[PbrSlot.Specular] != null || d.extTextures[PbrSlot.SpecularColor] != null) return true;
    if (d.transmission > 0 || d.clearcoat > 0 || d.iridescence > 0 || d.anisotropyStrength > 0) return true;
    if (d.diffuseTransmission > 0) return true;
    if (d.sheenColor[0] > 0 || d.sheenColor[1] > 0 || d.sheenColor[2] > 0) return true;
    if (d.textures[TEX_NORMAL] != null && d.normalScale != 1) return true;
    if (d.textures[TEX_OCCLUSION] != null && d.occlusionStrength != 1) return true;
    if (d.extTextures[PbrSlot.Roughness] != null) return true;
    if (d.textures[TEX_METALLIC_ROUGHNESS] != null && (!d.metallicFromMr || !d.roughnessFromMr)) return true;
    for (let slot = 0; slot < 6; slot++) {
        if (slotDrawn(d, slot) && !d.slotUv[slot].isIdentity()) return true;
    }
    return false;
}

// Milestone 62: whether `d` refracts the screen when the frame turns the
// screen-space refraction on (the Environment's screen_refraction_enabled):
// a material with transmission (glTF's; StandardMaterial3D's
// refraction_enabled), drawn after the opaque surfaces from a copy of
// them. A ShaderMaterial does not (its own code draws it, with no screen
// texture).
export function materialRefracts(d: MaterialDesc): bool {
    return d.transmission > 0 && d.custom == null;
}

// The PbrSlots whose texture samples UV set 1 (glTF's TEXCOORD_1), and
// those above it, which the renderer draws with set 0: what the scene
// adapter warns about.
export function slotsOnSet(d: MaterialDesc, set: i32, above: bool): Array<i32> {
    const out: Array<i32> = [];
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        if (!slotDrawn(d, slot)) continue;
        const c = d.slotUv[slot].texCoord;
        if (above ? c > set : c == set) out.push(slot);
    }
    return out;
}

// Next mip level: a 2x2 box filter, clamped at the borders so odd sizes and
// 1-pixel-wide levels work. (On the bytes, rows at a time: a 2048-texel
// map's level 1 is a million texels, and a texel at a time through
// Image.get and put took half a second; the same bytes.)
export function half(img: Image): Image {
    const w = halfSide(img.width);
    const h = halfSide(img.height);
    const out = new Uint8Array(<i32>(w * h * 4));
    halfInto(img.data, img.width, img.height, out);
    return new Image(w, h, out);
}

// The side of the level after one of `side` texels (half, at least 1).
export function halfSide(side: u32): u32 {
    return side / 2 > 1 ? side / 2 : 1;
}

// Milestone 67b: `half`'s level written into `out` (halfSide(sw) x
// halfSide(sh) texels, RGBA8; at least that long, as a pooled buffer is:
// ../base/scratch.as), from the `sw` x `sh` RGBA8 texels `src` (only their
// first sw * sh * 4 bytes are read). The same bytes as `half`, which it
// makes: render/gpu/materials.as builds a mip chain level by level in
// pooled buffers with it.
export function halfInto(src: Uint8Array, sw: u32, sh: u32, out: Uint8Array): void {
    const w = halfSide(sw);
    const h = halfSide(sh);
    for (let y: u32 = 0; y < h; y++) {
        const y0 = y * 2 < sh - 1 ? y * 2 : sh - 1;
        const y1 = y * 2 + 1 < sh - 1 ? y * 2 + 1 : sh - 1;
        const r0 = <i32>(y0 * sw * 4);
        const r1 = <i32>(y1 * sw * 4);
        const ro = <i32>(y * w * 4);
        for (let x: u32 = 0; x < w; x++) {
            const x0 = <i32>((x * 2 < sw - 1 ? x * 2 : sw - 1) * 4);
            const x1 = <i32>((x * 2 + 1 < sw - 1 ? x * 2 + 1 : sw - 1) * 4);
            const o = ro + <i32>(x * 4);
            for (let c = 0; c < 4; c++) {
                const sum = <u32>unchecked(src[r0 + x0 + c]) + <u32>unchecked(src[r0 + x1 + c])
                    + <u32>unchecked(src[r1 + x0 + c]) + <u32>unchecked(src[r1 + x1 + c]);
                unchecked(out[o + c] = <u8>((sum + 2) / 4));
            }
        }
    }
}

// `32 - max(w, h, 1).leading_zeros()`: the mip level count `upload` creates.
export function mipLevelCount(width: u32, height: u32): u32 {
    let m = width > height ? width : height;
    if (m < 1) m = 1;
    return 32 - <u32>clz<u32>(m);
}

// The levels `upload` writes, level 0 first (`img.clone()`, then `half` of
// the previous level while more levels remain).
export function mipChain(img: Image): Array<Image> {
    const levels = mipLevelCount(img.width, img.height);
    const out: Array<Image> = [];
    let level = img.clone();
    for (let mip: u32 = 0; mip < levels; mip++) {
        out.push(level);
        if (mip + 1 < levels) level = half(level);
    }
    return out;
}

// A file's modification time (when known) and size, to tell whether a
// cached texture is stale. Two stamps are equal when both parts are.
export class TextureStamp {
    hasModified: bool;
    modified: f64;
    len: u64;

    constructor(hasModified: bool, modified: f64, len: u64) {
        this.hasModified = hasModified;
        this.modified = modified;
        this.len = len;
    }

    equals(o: TextureStamp): bool {
        if (this.hasModified != o.hasModified || this.len != o.len) return false;
        return !this.hasModified || this.modified == o.modified;
    }

    // Stamp equality, where null (unknown) equals only null. (A static
    // method rather than a function: the linter does not see calls from the
    // generic MaterialBinder, and reported the function as never used.)
    static same(a: TextureStamp?, b: TextureStamp?): bool {
        if (a == null) return b == null;
        if (b == null) return false;
        return a.equals(b);
    }
}


// The file access textures need: canonical paths, stamps and contents.
export abstract class TextureFiles {
    // The canonical path, or null when it cannot be resolved.
    abstract canonicalize(path: string): string?;
    // `stamp(path)`: null when the metadata cannot be read.
    abstract stamp(path: string): TextureStamp?;
    // The file's bytes; `r.err` is the I/O error text.
    abstract read(path: string): Result<Uint8Array>;
    // An image already decoded for `path` (Hedra holds a model's embedded
    // images in memory, under keys that are no file), used instead of
    // reading and decoding the file; null, the default, reads the file.
    decoded(path: string): Image? {
        return null;
    }
    // Milestone 26: the texture's processed forms (import/texture_files.as,
    // and a bundle's KTX2 entries in the run time), in form order,
    // which the binder uploads as they are (the first the backend
    // `supports`) or decodes on the CPU; null, the default, draws the
    // source (`read`, decoded) as before.
    compressed(path: string): Array<CompressedImage>? {
        return null;
    }
    // Milestone 26: how many times what `compressed` answers for `path`
    // changed while the file did not (the tools' imported files finishing
    // an import in slices: import/texture_files.as), for a stamp that
    // depends on the forms; 0, the default, never.
    formsSerial(path: string): u32 {
        return 0;
    }
}

// TextureFiles over the app's VFS (engine/src/fs/vfs.as). The VFS has no
// modification times, so the stamp is the size alone.
export class VfsTextureFiles extends TextureFiles {
    canonicalize(path: string): string? {
        const r = vfs.canonicalize(path);
        return r.ok ? r.value : null;
    }

    stamp(path: string): TextureStamp? {
        const r = vfs.metadata(path);
        return r.ok ? new TextureStamp(false, 0, r.value.len) : null;
    }

    read(path: string): Result<Uint8Array> {
        return vfs.read(path);
    }
}

// `path.extension().is_some_and(|e| e.eq_ignore_ascii_case("png"))`.
export function isPngPath(path: string): bool {
    const e = extension(path);
    return e != null && toAsciiLowercase(e) == "png";
}

// Decode a texture file; the error is the text that goes into the warning.
export function decode(path: string, files: TextureFiles): Result<Image> {
    const held = files.decoded(path);
    if (held != null) return Result.okv<Image>(held);
    if (!isPngPath(path)) return Result.fail<Image>("only PNG textures are supported");
    const bytes = files.read(path);
    if (!bytes.ok) {
        // A directory opens but cannot be read, and that failure surfaces
        // from the PNG decoder: it is reported as a PNG error, not an I/O
        // one ("PNG error: Is a directory (os error 21)").
        const io = ioErrorOf<Uint8Array>(bytes);
        if (io != null && io.kind == IoErrorKind.IsADirectory) return Result.fail<Image>(RenderError.encode(bytes.err).toString());
        return Result.fail<Image>(RenderError.io(path, bytes.err).toString());
    }
    const img = Image.decodePng(bytes.value);
    if (!img.ok) return Result.fail<Image>(img.err);
    return img;
}

export function materialUniform(m: MaterialDesc, textureBits: u32): MaterialUniform {
    const b0 = srgbToLinear(m.baseColor[0]);
    const b1 = srgbToLinear(m.baseColor[1]);
    const b2 = srgbToLinear(m.baseColor[2]);
    const e0 = srgbToLinear(m.emission[0]);
    const e1 = srgbToLinear(m.emission[1]);
    const e2 = srgbToLinear(m.emission[2]);
    const s = maxF32(m.emissionStrength, 0.0);
    let alphaMode: u32;
    switch (m.alphaMode) {
        case ALPHA_OPAQUE: alphaMode = ALPHA_OPAQUE; break;
        case ALPHA_MASK: alphaMode = ALPHA_MASK; break;
        default: alphaMode = ALPHA_BLEND; break;
    }
    return MaterialUniform(
        Vec4(b0, b1, b2, clampF32(m.alpha, 0.0, 1.0)),
        Vec4(e0 * s, e1 * s, e2 * s, m.alphaCutoff),
        // (milestone 62: an extended material's refraction_scale in z, which
        // the extended entries read behind the lit block's
        // ENV_SCREEN_REFRACTION; a core material's 0, as before)
        Vec4(clampF32(m.metallic, 0.0, 1.0), clampF32(m.roughness, 0.0, 1.0),
            materialIsExt(m) ? m.refractionScale : 0.0, 0.0),
        U32x4(textureBits, alphaMode, m.doubleSided ? 1 : 0,
            vertexColorBits(m) | extBits(m) | (m.srgbDecode & (MAT_SRGB_BASE | MAT_SRGB_EMISSION))),
        Vec4(m.uvScale[0], m.uvScale[1], m.uvOffset[0], m.uvOffset[1]),
    );
}

// The texture presence bits `MaterialBinder.bind` gives `m`'s uniform: the
// T_* bit of every one of the five slots with a path (whether or not the
// file loads: a failed one binds its fallback, still marked present).
export function textureBitsOf(m: MaterialDesc): u32 {
    let bits: u32 = 0;
    for (let slot = 0; slot < TEX_COUNT; slot++) {
        if (slot < m.textures.length && m.textures[slot] != null) bits |= slotBit(slot);
    }
    return bits;
}

// `MaterialUniform.flags.w`'s milestone-14 bits: MAT_EXT for a material the
// extended pipelines draw (materialIsExt), with MAT_UNLIT and
// MAT_ROUGHNESS_LAYER as it says; 0 for every other.
export function extBits(m: MaterialDesc): u32 {
    if (!materialIsExt(m)) return 0;
    let bits = MAT_EXT;
    if (m.unlit) bits |= MAT_UNLIT;
    if (m.extTextures[PbrSlot.Roughness] != null) bits |= MAT_ROUGHNESS_LAYER;
    return bits;
}

// The two rows of slot `slot`'s coordinate transform (MaterialExtUniform.xf):
// glTF's KHR_texture_transform, uv' = offset + R(rotation) S(scale) uv
// with R = [cos, sin; -sin, cos] (KHR_texture_transform's matrix), and for
// UV set 0 Godot's uv1 before it, uv * uvScale + uvOffset, so the slot reads
// exactly the coordinate today's path reads for an identity transform.
// `where` goes in row1.w (0: no texture).
function slotRows(m: MaterialDesc, slot: i32, where: f32, out: StaticArray<Vec4>): void {
    const t = m.slotUv[slot];
    // A set above 1 is drawn with set 0 (the adapter says so).
    const set1 = t.texCoord == 1;
    const c = Mathf.cos(t.rotation), s = Mathf.sin(t.rotation);
    const sx = t.scale[0], sy = t.scale[1];
    let a = c * sx, b = s * sy, tx = t.offset[0];
    let d = -s * sx, e = c * sy, ty = t.offset[1];
    if (!set1) {
        const s1x = m.uvScale[0], s1y = m.uvScale[1], o1x = m.uvOffset[0], o1y = m.uvOffset[1];
        tx = a * o1x + b * o1y + tx;
        ty = d * o1x + e * o1y + ty;
        a = a * s1x;
        b = b * s1y;
        d = d * s1x;
        e = e * s1y;
    }
    out[slot * 2] = Vec4(a, b, tx, set1 ? 1 : 0);
    out[slot * 2 + 1] = Vec4(d, e, ty, where);
}

// The extended part of `m`'s uniform (MaterialExtUniform): each slot's
// transform, where its texture is (`textureBits` for the five bindings,
// `layers[slot]` the extension array's layer or -1), and the factors,
// colours made linear.
export function materialExtUniform(m: MaterialDesc, textureBits: u32, layers: StaticArray<i32>): MaterialExtUniform {
    return materialExtUniformInto(m, textureBits, layers, new MaterialExtUniform());
}

// materialExtUniform written into `u` (every row and factor of it), which it
// returns: a renderer rewriting a kept group's uniform while a value is
// dragged (gpu/renderer.as rewriteMaterials) reuses one, allocating nothing.
export function materialExtUniformInto(m: MaterialDesc, textureBits: u32, layers: StaticArray<i32>,
    u: MaterialExtUniform): MaterialExtUniform {
    const xf = u.xf;
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        let where: f32 = 0;
        if (slot < 6 && slotDrawn(m, slot) && (textureBits & slotBit(texOfSlot(slot))) != 0) where = 1;
        if (slot == PbrSlot.Metallic && !m.metallicFromMr) where = 0;
        if (slot == PbrSlot.Roughness && (!m.roughnessFromMr || m.extTextures[PbrSlot.Roughness] != null)) where = 0;
        if ((slot >= 6 || slot == PbrSlot.Roughness) && layers[slot] >= 0) where = <f32>(layers[slot] + 1);
        slotRows(m, slot, where, xf);
    }
    const e = u.ext;
    e[0] = Vec4(srgbToLinear(m.specularColor[0]), srgbToLinear(m.specularColor[1]), srgbToLinear(m.specularColor[2]),
        maxF32(m.specular, 0));
    e[1] = Vec4(maxF32(m.ior, 1), clampF32(m.transmission, 0, 1), maxF32(m.thickness, 0), maxF32(m.attenuationDistance, 0));
    e[2] = Vec4(srgbToLinear(m.attenuationColor[0]), srgbToLinear(m.attenuationColor[1]),
        srgbToLinear(m.attenuationColor[2]), maxF32(m.dispersion, 0));
    e[3] = Vec4(clampF32(m.clearcoat, 0, 1), clampF32(m.clearcoatRoughness, 0, 1), m.clearcoatNormalScale, m.normalScale);
    e[4] = Vec4(srgbToLinear(m.sheenColor[0]), srgbToLinear(m.sheenColor[1]), srgbToLinear(m.sheenColor[2]),
        clampF32(m.sheenRoughness, 0, 1));
    e[5] = Vec4(clampF32(m.iridescence, 0, 1), maxF32(m.iridescenceIor, 1), maxF32(m.iridescenceThicknessMinimum, 0),
        maxF32(m.iridescenceThicknessMaximum, 0));
    e[6] = Vec4(clampF32(m.anisotropyStrength, 0, 1), Mathf.cos(m.anisotropyRotation), Mathf.sin(m.anisotropyRotation),
        clampF32(m.occlusionStrength, 0, 1));
    e[7] = Vec4(srgbToLinear(m.diffuseTransmissionColor[0]), srgbToLinear(m.diffuseTransmissionColor[1]),
        srgbToLinear(m.diffuseTransmissionColor[2]), clampF32(m.diffuseTransmission, 0, 1));
    return u;
}

// The largest side of a layer of the extension array (binding 7): each
// layer is resampled to the largest extension texture's size, at most this
// on either side.
export const EXT_LAYER_MAX: u32 = 2048;

// `img` resampled bilinearly to `w` x `h` (texel centres mapped onto texel
// centres, clamped at the borders); `img` itself when it is that size.
export function resampleBilinear(img: Image, w: u32, h: u32): Image {
    if (img.width == w && img.height == h) return img;
    const out = Image.new(w, h, Rgba(0, 0, 0, 0));
    const sw = <f32>img.width, sh = <f32>img.height;
    const maxX = <i32>img.width - 1, maxY = <i32>img.height - 1;
    for (let y: u32 = 0; y < h; y++) {
        const fy = maxF32((<f32>y + 0.5) * sh / <f32>h - 0.5, 0);
        let y0 = <i32>Mathf.floor(fy);
        if (y0 > maxY) y0 = maxY;
        const y1 = y0 + 1 <= maxY ? y0 + 1 : maxY;
        const ty = fy - <f32>y0;
        for (let x: u32 = 0; x < w; x++) {
            const fx = maxF32((<f32>x + 0.5) * sw / <f32>w - 0.5, 0);
            let x0 = <i32>Mathf.floor(fx);
            if (x0 > maxX) x0 = maxX;
            const x1 = x0 + 1 <= maxX ? x0 + 1 : maxX;
            const tx = fx - <f32>x0;
            const p00 = img.get(<u32>x0, <u32>y0), p10 = img.get(<u32>x1, <u32>y0);
            const p01 = img.get(<u32>x0, <u32>y1), p11 = img.get(<u32>x1, <u32>y1);
            out.put(<i32>x, <i32>y, Rgba(
                lerpByte(p00.r, p10.r, p01.r, p11.r, tx, ty), lerpByte(p00.g, p10.g, p01.g, p11.g, tx, ty),
                lerpByte(p00.b, p10.b, p01.b, p11.b, tx, ty), lerpByte(p00.a, p10.a, p01.a, p11.a, tx, ty)));
        }
    }
    return out;
}

function lerpByte(a: u8, b: u8, c: u8, d: u8, tx: f32, ty: f32): u8 {
    const top = <f32>a + (<f32>b - <f32>a) * tx;
    const bottom = <f32>c + (<f32>d - <f32>c) * tx;
    const v = top + (bottom - top) * ty;
    return <u8>clampF32(Mathf.round(v), 0, 255);
}

// The size every layer of an extension array of `images` takes: the
// largest width and height among them, each at most EXT_LAYER_MAX.
export function extLayerSize(images: Array<Image>): StaticArray<u32> {
    let w: u32 = 1, h: u32 = 1;
    for (let i = 0; i < images.length; i++) {
        if (images[i].width > w) w = images[i].width;
        if (images[i].height > h) h = images[i].height;
    }
    return [w < EXT_LAYER_MAX ? w : EXT_LAYER_MAX, h < EXT_LAYER_MAX ? h : EXT_LAYER_MAX];
}

// The layer order of the extension array: slots 6 to 19 in PbrSlot order,
// then Roughness (when it is an image of its own), each that has a texture
// taking the next layer. By slot, -1 for none.
export function extLayers(d: MaterialDesc): StaticArray<i32> {
    return extLayersInto(d, new StaticArray<i32>(PBR_SLOT_COUNT));
}

// extLayers written into `out` (PBR_SLOT_COUNT long), which it returns.
export function extLayersInto(d: MaterialDesc, out: StaticArray<i32>): StaticArray<i32> {
    for (let i = 0; i < PBR_SLOT_COUNT; i++) out[i] = -1;
    let next = 0;
    for (let slot = 6; slot < PBR_SLOT_COUNT; slot++) {
        if (d.extTextures[slot] != null) out[slot] = next++;
    }
    if (d.extTextures[PbrSlot.Roughness] != null) out[PbrSlot.Roughness] = next++;
    return out;
}

// `MaterialUniform.flags.w` (milestone 13): MAT_VERTEX_COLOR when the
// vertex colour multiplies the albedo, with MAT_VERTEX_COLOR_SRGB when that
// colour is sRGB; 0 otherwise (every material before, and Hedra's).
export function vertexColorBits(m: MaterialDesc): u32 {
    if (!m.vertexColorAsAlbedo) return 0;
    return MAT_VERTEX_COLOR | (m.vertexColorIsSrgb ? MAT_VERTEX_COLOR_SRGB : 0);
}

// Whether the id pass (surface.wgsl `fs_id`, material mode) discards every
// fragment drawn with `d`: `M.flags.y == ALPHA_MASK && base.a < M.emission.w`,
// where `base.a` is the clamped alpha times the base texture's alpha (at most
// 1, and a failed load samples the opaque magenta fallback), so it is below
// the cutoff everywhere exactly when the clamped alpha is. Label occlusion
// (GpuMesh.bvhSkipping) leaves such materials out, since they never occlude
// anything. A textured mask material with alpha >= cutoff can still cut
// out per texel, which the CPU does not see.
export function cutsOut(d: MaterialDesc): bool {
    const u = materialUniform(d, 0);
    return u.flags.y == ALPHA_MASK && u.baseColor.w < u.emission.w;
}

// A MaterialUniform in a class. rasc 1.1.0 cannot load a module in which an
// overridden (virtual) method takes a struct parameter ("no protocol scripts"
// at load time), so `MaterialBackend.group` takes the uniform boxed.
export class MaterialUniformBox {
    u: MaterialUniform;
    // The extended part (milestone 14, part 2) of a material with MAT_EXT;
    // null writes its identity (MaterialUniform.toBytes).
    ext: MaterialExtUniform?;

    constructor(u: MaterialUniform, ext: MaterialExtUniform? = null) {
        this.u = u;
        this.ext = ext;
    }

    // The uniform buffer contents (MATERIAL_UNIFORM_SIZE bytes).
    toBytes(): ArrayBuffer {
        const ext = this.ext;
        if (ext == null) return this.u.toBytes();
        const buf = new ArrayBuffer(<i32>MATERIAL_UNIFORM_SIZE);
        const dv = new DataView(buf, 0, buf.byteLength);
        this.u.writeAt(dv, 0);
        ext.writeAt(dv, MATERIAL_BASE_SIZE);
        return buf;
    }
}

// The device side of `MaterialBinder` (see the header).
export abstract class MaterialBackend<V, G> {
    // A texture with the
    // full mip chain (`mipChain(img)`), sRGB-decoded on sampling when `srgb`.
    abstract upload(label: string, img: Image, srgb: bool): V;
    // A bind group: a uniform buffer holding `u`, the five views
    // (bindings 1 to 5, in texture-slot order) and the sampler (binding 6).
    // A material with MAT_EXT passes a sixth view, its extension array
    // (`uploadArray`), for binding 7; without one the backend binds an
    // array of one white layer there.
    abstract group(u: MaterialUniformBox, views: Array<V>): G;
    // A texture array of `layers` (milestone 14, part 2: binding 7, the
    // extension slots' textures), every layer the same size, each with its
    // mip chain, its bytes as they are (the shader decodes the sRGB
    // slots). The default, for backends that draw nothing, uploads the
    // first layer as a texture.
    uploadArray(label: string, layers: Array<Image>): V {
        return this.upload(label, layers[0], false);
    }
    // A texture `upload` made that the binder no longer holds (its file
    // changed and was uploaded again). Groups the current frame made may
    // still bind it, so a backend frees it once that frame is done; the
    // default keeps it.
    release(view: V): void {}
    // Milestone 67b (docs/engine/RESOURCES.md, "Lifetimes"): what releases
    // the texture behind `view` (one this backend uploaded) at once, for the
    // run time's GPU ledger, which calls it a frame after the resource it
    // belongs to was freed (gpu/ledger.as); null for a backend that holds
    // nothing on a device (the default). A TextureShare asks the backend
    // that uploaded, since each renderer's backend keeps its own textures.
    releaser(view: V): GpuRelease? {
        return null;
    }
    // Milestone 26: whether the device takes `format` as it is (the GPU
    // backend asks rive/gpu gpuFeatures: bc, etc2, astc). The default, for
    // backends that draw nothing, takes none.
    supports(format: BlockFormat): bool {
        return false;
    }
    // Whether the device takes `img` as it is: its format (`supports`) at
    // its size. The GPU backend also refuses a BC texture whose level 0 is
    // not whole blocks on Direct3D (render/gpu/materials.as
    // takesBlockSize), which is then decoded on the CPU.
    supportsImage(img: CompressedImage): bool {
        return this.supports(img.format);
    }
    // A compressed texture uploaded as it is, every level (only called for a
    // format `supports` takes); the view samples the stored texels, so an
    // sRGB colour slot is decoded in the shader (the binder sets the
    // material's MAT_SRGB_* bits). The default decodes level 0 on the CPU
    // and uploads it as `upload` would (srgb: decoded on sampling).
    uploadCompressed(label: string, img: CompressedImage, srgb: bool): V {
        const d = decodeFirstLevel(img);
        return this.upload(label, d.ok ? d.value : Image.new(1, 1, Rgba(255, 0, 255, 255)), srgb);
    }
}

// Milestone 26: which block-compression families a device takes (rive/gpu
// gpuFeatures: `bc`, `etc2`, `astc`), as the GPU backend reads them once
// (render/gpu/materials.as deviceFamilies) and the run time
// chooses its textures' form by. `known` is false where no device is
// attached (`rive --test`): nothing compressed is taken then.
export class TextureFamilies {
    known: bool = false;
    bc: bool = false;
    etc2: bool = false;
    astc: bool = false;

    static of(known: bool, bc: bool, etc2: bool, astc: bool): TextureFamilies {
        const f = new TextureFamilies();
        f.known = known;
        f.bc = bc;
        f.etc2 = etc2;
        f.astc = astc;
        return f;
    }

    // Whether the device takes `form` (Source: always, it is decoded).
    takesForm(form: TextureForm): bool {
        if (form == TextureForm.Bc) return this.known && this.bc;
        if (form == TextureForm.Etc2) return this.known && this.etc2;
        if (form == TextureForm.Astc) return this.known && this.astc;
        return true;
    }

    // Whether the device uploads `format` as it is: Rgba8 on any device
    // (rgba8unorm), a block format when its family is taken.
    takes(format: BlockFormat): bool {
        if (format == BlockFormat.Rgba8) return this.known;
        return this.takesForm(formOfBlockFormat(format));
    }

    // The families taken, "bc,etc2" ("none" when none), as answers say.
    toString(): string {
        const parts = new Array<string>();
        if (this.known && this.bc) parts.push("bc");
        if (this.known && this.etc2) parts.push("etc2");
        if (this.known && this.astc) parts.push("astc");
        return parts.length > 0 ? parts.join(",") : "none";
    }
}

// Level 0 of `img` decoded on the CPU (hedra_engine/texture/decode.as): what a
// device that takes none of a texture's forms draws.
export function decodeFirstLevel(img: CompressedImage): Result<Image> {
    if (img.levels.length == 0) return Result.fail<Image>("a " + blockFormatName(img.format) + " texture without levels");
    const l = img.levels[0];
    return decodeLevel(img.format, l.data, l.width, l.height);
}

// The form of `forms` a device that takes what `backend.supports` says
// uploads as it is: the first it supports, else -1 (the first is then
// decoded on the CPU). The binder's choice, and the answers' (render's
// `textures`).
export function chosenForm<V, G>(backend: MaterialBackend<V, G>, forms: Array<CompressedImage>): i32 {
    for (let i = 0; i < forms.length; i++) if (backend.supportsImage(forms[i])) return i;
    return -1;
}

// The texture cache key: path and sRGB flag. Paths compare by components
// (`a//b`, `a/./b` and `a/b/` all equal `a/b`), so
// two spellings of one path share an entry, and its warning.
export function texKey(path: string, srgb: bool): string {
    const c = components(path);
    const parts: Array<string> = [];
    for (let i = 0; i < c.length; i++) parts.push(c[i].text);
    return parts.join("\u0000") + (srgb ? "\u0001srgb" : "\u0001linear");
}

export class CachedTexture<V> {
    // The path spelling first inserted (an equal key inserted later keeps
    // the original spelling).
    path: string;
    srgb: bool;
    // Stamp when decoded; null when the file was unreadable, so it is
    // retried once it appears.
    stamp: TextureStamp?;
    view: V;
    // Why the file is drawn as a fallback; repeated on every use so a
    // long-lived session keeps reporting it.
    warning: string?;
    // Milestone 26: what was uploaded: "source" (the file, decoded), a
    // block format's name ("bc1", ...: a processed form uploaded as it
    // is), or "<name> decoded" (a form the device does not take, decoded
    // on the CPU); and whether the shader decodes its sRGB (a form
    // uploaded as it is in an sRGB slot: MAT_SRGB_*).
    drawn: string = "source";
    srgbInShader: bool = false;
    // Milestone 67b: the share's generation when `view` was last known to
    // be the share's (MaterialBinder.texture, TextureShare.forget).
    shareGen: i32 = 0;

    constructor(path: string, srgb: bool, stamp: TextureStamp?, view: V, warning: string?) {
        this.path = path;
        this.srgb = srgb;
        this.stamp = stamp;
        this.view = view;
        this.warning = warning;
    }
}

// A decoded image of an extension slot, kept by path (as CachedTexture,
// but on the CPU: the binder composes the extension array from it).
export class CachedImage {
    stamp: TextureStamp?;
    // null when the file could not be decoded (`warning` says why).
    image: Image?;
    warning: string?;

    constructor(stamp: TextureStamp?, image: Image?, warning: string?) {
        this.stamp = stamp;
        this.image = image;
        this.warning = warning;
    }

    // What a failed extension texture draws as: a colour slot magenta (a
    // broken path shows), the clearcoat normal flat, any other white (no
    // effect). (A static method, for the linter, as TextureStamp.same.)
    static fallback(slot: i32): Image {
        if (slot == PbrSlot.ClearcoatNormal) return Image.new(1, 1, Rgba(128, 128, 255, 255));
        if (pbrSlotIsSrgb(slot)) return Image.new(1, 1, Rgba(255, 0, 255, 255));
        return Image.new(1, 1, Rgba(255, 255, 255, 255));
    }
}

// An extension array the binder uploaded, and the layer images it was made
// from (compared by identity: an image decoded again is a new object).
export class CachedArray<V> {
    images: Array<Image>;
    view: V;

    constructor(images: Array<Image>, view: V) {
        this.images = images;
        this.view = view;
    }

    madeFrom(images: Array<Image>): bool {
        if (images.length != this.images.length) return false;
        for (let i = 0; i < images.length; i++) if (images[i] !== this.images[i]) return false;
        return true;
    }
}

// Milestone 39: GPU textures shared by the binders of several renderers on
// one device (the run time's instances: the first renderer and
// its siblings), keyed by the decoded Image and how it is sampled, so that
// an image every instance draws is uploaded once. Images compare by
// identity: the run time's are the bundle's decoded Texture2Ds, which its
// one SceneTextureFiles hands every binder (`decode` returns the image
// held). A shared texture lives as long as the share: a binder never
// releases one (`holds`), as another may bind it. Without a share (every
// other program) each binder uploads its own, as before.
//
// Milestone 67b (docs/engine/RESOURCES.md, "The cache"): the run time's
// share is the module's one (every Scene3D's runtime binds through it:
// ../scene/runtime/runtime_resources.as), and it lets go of a texture
// whose resource the cache freed (`forget`): the views go from its lists
// (a binder asking for the image again would upload it again), and their
// GPU objects are released through the GpuRelease the uploading backend
// made (`releaseFor`, MaterialBackend.releaser), which the resource's
// cache entry holds. `generation` counts the forgets, so that a binder
// whose cached view may be one of them checks it (MaterialBinder.texture)
// without searching the share on every bind.
export abstract class SharedTextures {
    // Forgets every upload of `img` (null: none) and of `form` (null:
    // none; with the image decoded from it on the CPU); how many views it
    // dropped. Tells the upload listeners (textureForgotten).
    abstract forget(img: Image?, form: CompressedImage?): i32;
    // The release the uploading backend made for the upload of `img` or
    // `form` sampled as `srgb` says; null when there is none.
    abstract releaseFor(img: Image?, form: CompressedImage?, srgb: bool): GpuRelease?;
}

export class TextureShare<V> extends SharedTextures {
    private images: Array<Image> = [];
    private srgb: Array<bool> = [];
    private views: Array<V> = [];
    // Milestone 67b: by upload, what releases it (MaterialBackend.releaser)
    // and the bytes it charged (upload_events.as).
    private releases: Array<GpuRelease?> = [];
    private sizes: Array<i64> = [];
    private formReleases: Array<GpuRelease?> = [];
    private formSizes: Array<i64> = [];
    // How many times `forget` dropped a view (MaterialBinder.texture).
    generation: i32 = 0;
    // Milestone 26: compressed uploads, keyed by the CompressedImage (the
    // bundle's decoded KTX2 form, held by its Texture2D) and the sampling;
    // and the forms decoded on the CPU, so that every binder draws the one
    // decoded Image (and so one upload of it).
    private forms: Array<CompressedImage> = [];
    private formSrgb: Array<bool> = [];
    private formViews: Array<V> = [];
    private decodedForms: Array<CompressedImage> = [];
    private decodedImages: Array<Image> = [];
    // How many textures were uploaded through the share (tests).
    uploads: i32 = 0;

    // The view of `img` sampled as `srgb` says, uploaded through `backend`
    // the first time.
    upload<G>(backend: MaterialBackend<V, G>, label: string, img: Image, srgb: bool): V {
        for (let i = 0; i < this.images.length; i++) {
            if (this.images[i] === img && this.srgb[i] == srgb) return this.views[i];
        }
        // (milestone 67b: an image whose pixels a run time released after
        // its first upload is never handed to a backend, which would read
        // past its empty data: a miss, drawn as its other sampling's view
        // when it has one, else as a placeholder; MaterialBinder.texture
        // samples an sRGB slot from the linear view correctly, and
        // Texture2D.noteSampled keeps the pixels of a texture its materials
        // sample both ways, so a run time meets this only for a material
        // described after the release)
        if (img.released) {
            noteCpuMiss("texture: a released copy uploaded anew");
            for (let i = 0; i < this.images.length; i++) if (this.images[i] === img) return this.views[i];
            return this.placeholder<G>(backend, srgb);
        }
        const v = backend.upload(label, img, srgb);
        const bytes = imageUploadBytes(img.width, img.height, srgb);
        this.images.push(img);
        this.srgb.push(srgb);
        this.views.push(v);
        this.releases.push(backend.releaser(v));
        this.sizes.push(bytes);
        this.uploads++;
        // (milestone 67b: the run time's listeners, upload_events.as)
        if (uploadListenerCount() > 0) emitTextureUploaded(img, this.formDecodedAs(img), srgb, bytes);
        return v;
    }

    // The view of `img` uploaded as it is (MaterialBackend.uploadCompressed)
    // the first time, sampled as stored whatever `srgb` says (the key keeps
    // the two slots' uses apart all the same, as the views' labels differ).
    uploadCompressed<G>(backend: MaterialBackend<V, G>, label: string, img: CompressedImage, srgb: bool): V {
        for (let i = 0; i < this.forms.length; i++) {
            if (this.forms[i] === img && this.formSrgb[i] == srgb) return this.formViews[i];
        }
        if (img.released) {
            // (milestone 67b: a form is uploaded as it is stored whatever
            // the slot, so the other sampling's view holds the same texels:
            // it is that one; a released form never reaches the backend)
            for (let i = 0; i < this.forms.length; i++) if (this.forms[i] === img) return this.formViews[i];
            noteCpuMiss("texture: a released form uploaded anew");
            return this.placeholder<G>(backend, srgb);
        }
        const v = backend.uploadCompressed(label, img, srgb);
        const bytes = formBytes(img);
        this.forms.push(img);
        this.formSrgb.push(srgb);
        this.formViews.push(v);
        this.formReleases.push(backend.releaser(v));
        this.formSizes.push(bytes);
        this.uploads++;
        // (milestone 67b: the run time's listeners, upload_events.as)
        if (uploadListenerCount() > 0) emitTextureUploaded(null, img, srgb, bytes);
        return v;
    }

    // Milestone 67b (see SharedTextures).
    releaseFor(img: Image?, form: CompressedImage?, srgb: bool): GpuRelease? {
        if (img != null) {
            for (let i = 0; i < this.images.length; i++) {
                if (this.images[i] === img && this.srgb[i] == srgb) return this.releases[i];
            }
            return null;
        }
        if (form != null) {
            for (let i = 0; i < this.forms.length; i++) {
                if (this.forms[i] === form && this.formSrgb[i] == srgb) return this.formReleases[i];
            }
        }
        return null;
    }

    forget(img: Image?, form: CompressedImage?): i32 {
        let dropped = 0;
        // (the image decoded from `form` on the CPU goes with it)
        let decodedImg: Image? = null;
        if (form != null) {
            for (let i = this.decodedForms.length - 1; i >= 0; i--) {
                if (this.decodedForms[i] !== form) continue;
                decodedImg = this.decodedImages[i];
                this.decodedForms.splice(i, 1);
                this.decodedImages.splice(i, 1);
            }
            for (let i = this.forms.length - 1; i >= 0; i--) {
                if (this.forms[i] !== form) continue;
                const srgb = this.formSrgb[i];
                const bytes = this.formSizes[i];
                this.forms.splice(i, 1);
                this.formSrgb.splice(i, 1);
                this.formViews.splice(i, 1);
                this.formReleases.splice(i, 1);
                this.formSizes.splice(i, 1);
                dropped++;
                if (uploadListenerCount() > 0) emitTextureForgotten(null, form, srgb, bytes);
            }
        }
        for (let pass = 0; pass < 2; pass++) {
            const which = pass == 0 ? img : decodedImg;
            if (which == null) continue;
            for (let i = this.images.length - 1; i >= 0; i--) {
                if (this.images[i] !== which) continue;
                const srgb = this.srgb[i];
                const bytes = this.sizes[i];
                this.images.splice(i, 1);
                this.srgb.splice(i, 1);
                this.views.splice(i, 1);
                this.releases.splice(i, 1);
                this.sizes.splice(i, 1);
                dropped++;
                if (uploadListenerCount() > 0) emitTextureForgotten(which, pass == 1 ? form : null, srgb, bytes);
            }
        }
        if (dropped > 0) this.generation++;
        return dropped;
    }

    // Milestone 67b: the form `img` was decoded from on the CPU (`decoded`),
    // or null (the upload events name both: upload_events.as).
    private formDecodedAs(img: Image): CompressedImage? {
        for (let i = 0; i < this.decodedImages.length; i++) if (this.decodedImages[i] === img) return this.decodedForms[i];
        return null;
    }

    // `img`'s level 0 decoded on the CPU, once (decodeFirstLevel).
    decoded(img: CompressedImage): Result<Image> {
        for (let i = 0; i < this.decodedForms.length; i++) {
            if (this.decodedForms[i] === img) return Result.okv<Image>(this.decodedImages[i]);
        }
        if (img.released) {
            // (milestone 67b: its levels are gone; the binder draws its
            // slot's fallback with this as the warning)
            noteCpuMiss("texture: a released form decoded anew");
            return Result.fail<Image>("its CPU copy was released after its upload");
        }
        const d = decodeFirstLevel(img);
        if (!d.ok) return d;
        this.decodedForms.push(img);
        this.decodedImages.push(d.value);
        return d;
    }

    // Milestone 67b: whether `img` was uploaded through the share sampled as
    // `srgb` says (MaterialBinder.texture, for an image whose pixels were
    // released).
    has(img: Image, srgb: bool): bool {
        for (let i = 0; i < this.images.length; i++) if (this.images[i] === img && this.srgb[i] == srgb) return true;
        return false;
    }

    // Milestone 67b: what a released copy asked for anew draws (`upload`):
    // one 1 x 1 texel for each sampling, uploaded once, mid grey (an
    // obvious but quiet placeholder, as a missing texture's magenta would
    // not be for a data slot).
    private placeholderViews: Array<V> = [];
    private placeholderSrgb: Array<bool> = [];

    private placeholder<G>(backend: MaterialBackend<V, G>, srgb: bool): V {
        for (let i = 0; i < this.placeholderSrgb.length; i++) if (this.placeholderSrgb[i] == srgb) return this.placeholderViews[i];
        const v = backend.upload("released", Image.new(1, 1, Rgba(128, 128, 128, 255)), srgb);
        this.placeholderViews.push(v);
        this.placeholderSrgb.push(srgb);
        return v;
    }

    // Whether `view` is one of the share's.
    holds(view: V): bool {
        for (let i = 0; i < this.views.length; i++) if (this.views[i] == view) return true;
        for (let i = 0; i < this.formViews.length; i++) if (this.formViews[i] == view) return true;
        for (let i = 0; i < this.placeholderViews.length; i++) if (this.placeholderViews[i] == view) return true;
        return false;
    }

    // How many textures the share holds.
    get size(): i32 {
        return this.views.length + this.formViews.length;
    }
}

// Texture cache, fallbacks and bind groups over a `MaterialBackend`.
export class MaterialBinder<V, G> {
    backend: MaterialBackend<V, G>;
    files: TextureFiles;
    // Milestone 39: where texture files are uploaded when several binders
    // share them (TextureShare); null uploads through `backend` alone.
    share: TextureShare<V>? = null;
    white: V;
    flatNormal: V;
    magenta: V;
    // TexKey (`texKey(path, srgb)`) -> entry.
    textures: Map<string, CachedTexture<V>> = new Map<string, CachedTexture<V>>();
    // The default material (0.8 grey, roughness 0.5); bound by every mode
    // that does not shade materials.
    defaultGroup: G;
    // Milestone 14, part 2: the extension slots' images by texKey (on the
    // CPU), and the arrays composed from them.
    images: Map<string, CachedImage> = new Map<string, CachedImage>();
    arrays: Array<CachedArray<V>> = [];
    // Milestone 15: views drawn every frame by their owner (the Hedra
    // player's artboard textures), by texKey(path as given, srgb). A slot
    // whose texture path is here binds the view as it is: nothing is
    // decoded, cached or warned about. Only the five bindings read it; an
    // extension slot's texture is composed on the CPU (extArray) and draws
    // what `files` gives for its path. Empty unless an owner sets one, so
    // every other program binds exactly as before.
    live: Map<string, V> = new Map<string, V>();
    // Bumped by every setLive and clearLive: a renderer that keeps bind
    // groups from frame to frame (FrameRenderer.bindMaterials) remakes them
    // when it changes, so a texture that goes live after its materials were
    // first bound does not keep its placeholder.
    liveGeneration: i32 = 0;
    // Milestone 25: bumped when the numbers and colours of materials already
    // bound changed in place (SceneRenderer.refreshMaterial, a value dragged
    // in the material editor) while their textures and switches did not: a
    // renderer that keeps bind groups writes their uniforms again
    // (FrameRenderer.bindMaterials) instead of making new groups, so a drag
    // allocates nothing.
    valuesGeneration: i32 = 0;

    // The sampler belongs to the backend's `group`.
    constructor(backend: MaterialBackend<V, G>, files: TextureFiles) {
        this.backend = backend;
        this.files = files;
        const white = backend.upload("white", Image.new(1, 1, Rgba(255, 255, 255, 255)), true);
        const flatNormal = backend.upload("flat-normal", Image.new(1, 1, Rgba(128, 128, 255, 255)), false);
        const magenta = backend.upload("magenta", Image.new(1, 1, Rgba(255, 0, 255, 255)), true);
        this.white = white;
        this.flatNormal = flatNormal;
        this.magenta = magenta;
        const defaultUniform = materialUniform(new MaterialDesc(), 0);
        const views: Array<V> = [white, flatNormal, white, white, white];
        this.defaultGroup = backend.group(new MaterialUniformBox(defaultUniform), views);
    }

    // The view for a texture file (`given` as written in the material),
    // decoding the file on first use or when it changed on disk. Failures are
    // reported through `warnings` and yield `fallback`.
    texture(given: string, srgb: bool, fallback: V, baseDir: string, warnings: Array<string>): V {
        // (a live view, an artboard's target, is decoded by the sampler or
        // linear already: never decoded in the shader, whatever the slot
        // or material bound before it said)
        this.lastSrgbInShader = false;
        if (this.live.size > 0) {
            const lk = texKey(given, srgb);
            if (this.live.has(lk)) return this.live.get(lk);
        }
        const abs = isAbsolute(given) ? given : join(baseDir, given);
        // Canonical keys let two spellings of one file share a decode; a
        // missing file keeps its joined path.
        const canon = this.files.canonicalize(abs);
        const path = canon != null ? canon : abs;
        const key = texKey(path, srgb);
        const current = this.files.stamp(path);
        const had = this.textures.has(key);
        const fresh = had && TextureStamp.same(this.textures.get(key).stamp, current) && this.stillShared(this.textures.get(key));
        if (!fresh) {
            const keyPath = had ? this.textures.get(key).path : path;
            // The texture this one replaces (a fallback is shared: kept).
            if (had && this.textures.get(key).warning == null) {
                const old = this.textures.get(key).view;
                const share = this.share;
                if (share == null || !share.holds(old)) this.backend.release(old);
            }
            const forms = this.files.compressed(path);
            let entry: CachedTexture<V>;
            if (forms != null && forms.length > 0) {
                entry = this.compressedEntry(given, keyPath, srgb, current, forms, fallback, path);
            } else {
                const img = decode(path, this.files);
                const share = this.share;
                if (img.ok && img.value.released && (share == null || !share.has(img.value, srgb))) {
                    // (milestone 67b: its pixels were released after its
                    // upload for the other sampling: an sRGB slot samples
                    // that linear view and decodes in the shader, as a
                    // processed form is drawn; a data slot cannot undo the
                    // sRGB view's conversion and draws its fallback)
                    entry = this.releasedEntry(given, keyPath, srgb, current, img.value, fallback, path);
                } else if (img.ok) {
                    const view = share != null
                        ? share.upload<G>(this.backend, given, img.value, srgb)
                        : this.backend.upload(given, img.value, srgb);
                    entry = new CachedTexture<V>(keyPath, srgb, current, view, null);
                } else {
                    entry = new CachedTexture<V>(
                        keyPath,
                        srgb,
                        current,
                        fallback,
                        "texture '" + path + "' could not be loaded (" + img.err + "); drawn as a placeholder",
                    );
                }
            }
            const sh = this.share;
            if (sh != null) entry.shareGen = sh.generation;
            this.textures.set(key, entry);
        }
        // Inserted just above when missing.
        const cached = this.textures.get(key);
        const w = cached.warning;
        if (w != null) warnings.push(w);
        this.lastSrgbInShader = cached.srgbInShader;
        return cached.view;
    }

    // Milestone 67b: the entry of an image whose pixels were released (see
    // `texture`); counts a miss.
    private releasedEntry(given: string, keyPath: string, srgb: bool, stamp: TextureStamp?, img: Image, fallback: V,
        path: string): CachedTexture<V> {
        noteCpuMiss("texture: a released copy bound with the other sampling");
        const share = this.share;
        if (srgb && share != null && share.has(img, false)) {
            const e = new CachedTexture<V>(keyPath, srgb, stamp, share.upload<G>(this.backend, given, img, false), null);
            e.srgbInShader = true;
            return e;
        }
        return new CachedTexture<V>(keyPath, srgb, stamp, fallback,
            "texture '" + path + "' was released from the CPU after its upload and is sampled another way now (keep it with "
                + "memory/keep_cpu_copies); drawn as a placeholder");
    }

    // Milestone 67b: whether `e`'s view is still the share's (the run time's
    // share forgets the textures of freed resources: TextureShare.forget),
    // checked only when the share forgot something since `e` was last
    // found in it; a fallback's view, and a view without a share, always.
    private stillShared(e: CachedTexture<V>): bool {
        const share = this.share;
        if (share == null || e.warning != null || e.shareGen == share.generation) return true;
        if (!share.holds(e.view)) return false;
        e.shareGen = share.generation;
        return true;
    }

    // Whether the texture `texture` returned last is sampled as stored and
    // decoded from sRGB in the shader (bind sets the material's MAT_SRGB_*
    // bit from it). A field, not a second result: binding allocates
    // nothing more.
    lastSrgbInShader: bool = false;

    // Milestone 26: the entry of a texture with processed forms (`files
    // .compressed`): the first form the backend supports, uploaded as it
    // is (an sRGB slot then decodes in the shader), else the first decoded
    // on the CPU and uploaded as a source would be (an sRGB slot then
    // rgba16float linear, as today: the CPU road draws what the source road
    // draws for the same texels). A form that does not decode draws
    // `fallback` with a warning, as a file that does not.
    private compressedEntry(given: string, keyPath: string, srgb: bool, stamp: TextureStamp?,
        forms: Array<CompressedImage>, fallback: V, path: string): CachedTexture<V> {
        const share = this.share;
        const pick = chosenForm<V, G>(this.backend, forms);
        if (pick >= 0) {
            const ci = forms[pick];
            const view = share != null
                ? share.uploadCompressed<G>(this.backend, given, ci, srgb)
                : this.backend.uploadCompressed(given, ci, srgb);
            const e = new CachedTexture<V>(keyPath, srgb, stamp, view, null);
            e.drawn = blockFormatName(ci.format);
            e.srgbInShader = srgb;
            return e;
        }
        const first = forms[0];
        const d = share != null ? share.decoded(first) : decodeFirstLevel(first);
        if (!d.ok) {
            return new CachedTexture<V>(keyPath, srgb, stamp, fallback,
                "texture '" + path + "' could not be loaded (its " + blockFormatName(first.format) + " form: " + d.err
                    + "); drawn as a placeholder");
        }
        const view = share != null
            ? share.upload<G>(this.backend, given, d.value, srgb)
            : this.backend.upload(given, d.value, srgb);
        const e = new CachedTexture<V>(keyPath, srgb, stamp, view, null);
        e.drawn = blockFormatName(first.format) + " decoded";
        return e;
    }

    // What each texture the binder holds was drawn from (CachedTexture
    // .drawn), by its path, in the order first bound: the answer of
    // `render --textures`. Fallbacks are left out (their warning says it).
    drawnForms(paths: Array<string>, drawn: Array<string>): void {
        const keys = this.textures.keys();
        for (let i = 0; i < keys.length; i++) {
            const t = this.textures.get(keys[i]);
            if (t.warning != null || paths.includes(t.path)) continue;
            paths.push(t.path);
            drawn.push(t.drawn);
        }
    }

    // Binds `view` wherever a material's texture path is `path` (as the
    // material gives it) and sampled as `srgb` says (see `live`); the
    // owner keeps the view alive and drawn.
    setLive(path: string, srgb: bool, view: V): void {
        this.live.set(texKey(path, srgb), view);
        this.liveGeneration++;
    }

    // Forgets every live view (their owner is gone).
    clearLive(): void {
        this.live.clear();
        this.liveGeneration++;
    }

    // Milestone 34: forgets the live view of `key` (texKey(path, srgb)) alone,
    // when there is one (a viewport left the plan; the artboards' stay).
    dropLive(key: string): void {
        if (!this.live.has(key)) return;
        this.live.delete(key);
        this.liveGeneration++;
    }

    // Milestone 34: setLive by a key made already (texKey(path, srgb)),
    // so an owner that sets its views again whenever they were dropped (a
    // viewport after the player's clearLive) builds no key.
    setLiveKey(key: string, view: V): void {
        this.live.set(key, view);
        this.liveGeneration++;
    }

    // Bind group for a material; null is the default material.
    bind(d: MaterialDesc?, baseDir: string, warnings: Array<string>): G {
        if (d == null) return this.defaultGroup;
        const m = d;
        let bits: u32 = 0;
        let decodeBits: u32 = 0;
        const views: Array<V> = [];
        for (let slot = 0; slot < TEX_COUNT; slot++) {
            const srgb = slotIsSrgb(slot);
            // Color inputs fall back to magenta so a broken path is obvious;
            // data inputs fall back to neutral values so the material still
            // reads (a magenta normal map would not).
            let empty: V;
            let failed: V;
            if (slot == TEX_NORMAL) {
                empty = this.flatNormal;
                failed = this.flatNormal;
            } else if (slot == TEX_BASE || slot == TEX_EMISSION) {
                empty = this.white;
                failed = this.magenta;
            } else {
                empty = this.white;
                failed = this.white;
            }
            const t = slot < m.textures.length ? m.textures[slot] : null;
            if (t != null) {
                bits |= slotBit(slot);
                views.push(this.texture(t, srgb, failed, baseDir, warnings));
                if (this.lastSrgbInShader) decodeBits |= slot == TEX_BASE ? MAT_SRGB_BASE : MAT_SRGB_EMISSION;
            } else {
                views.push(empty);
            }
        }
        m.srgbDecode = decodeBits;
        const u = materialUniform(m, bits);
        if ((u.flags.w & MAT_EXT) == 0) return this.backend.group(new MaterialUniformBox(u), views);
        const layers = extLayers(m);
        views.push(this.extArray(m, layers, baseDir, warnings));
        return this.backend.group(new MaterialUniformBox(u, materialExtUniform(m, bits, layers)), views);
    }

    // The decoded image of an extension texture (`given` as written in the
    // material), decoded again when its file changed; null when it cannot
    // be (the warning goes to `warnings`, every use, as `texture`'s does).
    image(given: string, baseDir: string, warnings: Array<string>): Image? {
        const abs = isAbsolute(given) ? given : join(baseDir, given);
        const canon = this.files.canonicalize(abs);
        const path = canon != null ? canon : abs;
        const key = texKey(path, false);
        const current = this.files.stamp(path);
        const had = this.images.has(key);
        if (!had || !TextureStamp.same(this.images.get(key).stamp, current)) {
            if (had) this.dropArraysOf(this.images.get(key).image);
            // (milestone 26: a texture with processed forms is composed from
            // the form the five bindings would draw, decoded: the array is
            // rgba8 on the CPU whatever the form)
            let img = this.decodeForExtension(path);
            if (img.ok) {
                pinImage(img.value);
                // (milestone 67b: released before an extension slot named
                // it, its pixels are gone: composing them would read past
                // them, so it is a failure, and a miss)
                if (img.value.released) {
                    noteCpuMiss("extension texture");
                    img = Result.fail<Image>("its CPU copy was released after its upload");
                }
            }
            this.images.set(key, img.ok
                ? new CachedImage(current, img.value, null)
                : new CachedImage(current, null,
                    "texture '" + path + "' could not be loaded (" + img.err + "); drawn as a placeholder"));
        }
        const cached = this.images.get(key);
        const w = cached.warning;
        if (w != null) warnings.push(w);
        return cached.image;
    }

    // An extension slot's image: its processed forms' chosen one (or the
    // first) decoded on the CPU when `files` gives forms, else the file.
    private decodeForExtension(path: string): Result<Image> {
        const forms = this.files.compressed(path);
        if (forms == null || forms.length == 0) return decode(path, this.files);
        const pick = chosenForm<V, G>(this.backend, forms);
        const ci = forms[pick >= 0 ? pick : 0];
        // (a released form: TextureShare.decoded fails, and counts the miss)
        pinForm(ci);
        const share = this.share;
        return share != null ? share.decoded(ci) : decodeFirstLevel(ci);
    }

    // Releases the arrays made from `img` (its file changed): groups made
    // since may still bind them, so the backend frees them after the frame.
    private dropArraysOf(img: Image?): void {
        if (img == null) return;
        for (let i = this.arrays.length - 1; i >= 0; i--) {
            const a = this.arrays[i];
            if (!a.images.includes(img)) continue;
            this.backend.release(a.view);
            this.arrays.splice(i, 1);
        }
    }

    // The extension array of `m` (binding 7): its layers in `layers`'
    // order, each resampled to the largest one's size (extLayerSize); one
    // white layer when it has none. Arrays are kept and shared by every
    // material whose layers are the same images.
    extArray(m: MaterialDesc, layers: StaticArray<i32>, baseDir: string, warnings: Array<string>): V {
        const images: Array<Image> = [];
        const order: Array<i32> = [];
        for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
            if (layers[slot] >= 0) order.push(slot);
        }
        // In layer order (extLayers numbers them by slot, Roughness last).
        for (let k = 0; k < order.length; k++) {
            for (let j = k + 1; j < order.length; j++) {
                if (layers[order[j]] < layers[order[k]]) {
                    const t = order[k];
                    order[k] = order[j];
                    order[j] = t;
                }
            }
        }
        for (let k = 0; k < order.length; k++) {
            const slot = order[k];
            const path = m.extTextures[slot];
            const img = path != null ? this.image(path, baseDir, warnings) : null;
            images.push(img != null ? img : this.fallbackImage(slot));
        }
        if (images.length == 0) images.push(this.fallbackImage(PbrSlot.Clearcoat));
        for (let i = 0; i < this.arrays.length; i++) {
            if (this.arrays[i].madeFrom(images)) return this.arrays[i].view;
        }
        const size = extLayerSize(images);
        const resampled: Array<Image> = [];
        for (let i = 0; i < images.length; i++) resampled.push(resampleBilinear(images[i], size[0], size[1]));
        const view = this.backend.uploadArray("ext-array", resampled);
        this.arrays.push(new CachedArray<V>(images, view));
        return view;
    }

    // One image per fallback kind, so arrays of the same fallbacks are
    // shared.
    private fallbacks: Map<i32, Image> = new Map<i32, Image>();

    private fallbackImage(slot: i32): Image {
        const kind = slot == PbrSlot.ClearcoatNormal ? 1 : pbrSlotIsSrgb(slot) ? 2 : 0;
        if (!this.fallbacks.has(kind)) this.fallbacks.set(kind, CachedImage.fallback(slot));
        return this.fallbacks.get(kind);
    }
}

// Milestone 67b: the bytes a compressed form's upload hands the device
// (every level as stored).
export function formBytes(img: CompressedImage): i64 {
    let total: i64 = 0;
    for (let i = 0; i < img.levels.length; i++) total += <i64>img.levels[i].data.length;
    return total;
}
