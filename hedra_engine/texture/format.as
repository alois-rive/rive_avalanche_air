// Milestone 26: the block-compressed texture forms a script can upload on
// the pinned runtime, and the CPU-side shape of a compressed texture. The
// codecs (bc_*.as, etc_*.as, astc_*.as), the dispatch (encode.as for the
// tools, decode.as for every program and the run time) and the
// container (ktx2.as) all agree on what is here; docs/formats/IMPORT.md
// ("Texture forms") is the description.
//
// What the runtime takes (established on rive 1.2.0-uat.24, recorded in
// docs/milestones/M26.md): rive/gpu_enums TextureFormat names bc1unorm,
// bc3unorm, bc7unorm, etc2rgb8, etc2rgba8, astc4x4, astc6x6 and astc8x8,
// with no sRGB variants, so a colour texture is sampled as stored and the
// shader decodes sRGB (surface.wgsl, MAT_SRGB_* bits); gpuFeatures() says
// which families a device takes (bc, etc2, astc). There is no Basis
// Universal transcoder in the runtime, so a texture ships pre-encoded in
// each family Build targets (Godot's "VRAM Compressed" per platform)
// and is uploaded as it is, or decoded on the CPU when the device takes
// none of them.
//
// A compressed level of w x h texels holds ceil(w / bw) * ceil(h / bh)
// blocks of `blockBytes(format)` bytes, row of blocks after row of blocks,
// top row first; the texels past the image's edge in the last blocks are
// copies of the edge (encoders clamp) and never drawn.

// One block format. The numbers are this format's own (the KTX2 container
// stores the Vulkan format, ktx2.as vkFormatOf), fixed: appended only.
export enum BlockFormat {
    // Uncompressed RGBA8 (Godot's "VRAM Uncompressed"): a 1 x 1 "block" of
    // 4 bytes.
    Rgba8 = 0,
    // BC1 (DXT1): RGB, 4 bits a texel, for opaque colour.
    Bc1 = 1,
    // BC3 (DXT5): BC1's colour and a BC4 alpha, 8 bits a texel.
    Bc3 = 2,
    // BC7, mode 6 and others as the encoder finds best: RGBA, 8 bits a
    // texel, the high-quality desktop form.
    Bc7 = 3,
    // ETC2 RGB8 (ETC1 compatible): RGB, 4 bits a texel.
    Etc2Rgb = 4,
    // ETC2 RGBA8: ETC2 colour and an EAC alpha, 8 bits a texel.
    Etc2Rgba = 5,
    // ASTC LDR 4 x 4: 8 bits a texel.
    Astc4x4 = 6,
    // ASTC LDR 6 x 6: 3.56 bits a texel.
    Astc6x6 = 7,
    // ASTC LDR 8 x 8: 2 bits a texel.
    Astc8x8 = 8,
}

export const BLOCK_FORMAT_COUNT: i32 = 9;

// The formats' names as answers, KTX2 key-values and docs spell them.
export const BLOCK_FORMAT_NAMES: StaticArray<string> = [
    "rgba8", "bc1", "bc3", "bc7", "etc2-rgb", "etc2-rgba", "astc-4x4", "astc-6x6", "astc-8x8",
];

export function blockFormatName(f: BlockFormat): string {
    const i = <i32>f;
    return i >= 0 && i < BLOCK_FORMAT_COUNT ? BLOCK_FORMAT_NAMES[i] : "format " + i.toString();
}

// The format a name names, or -1.
export function blockFormatOf(name: string): i32 {
    for (let i = 0; i < BLOCK_FORMAT_COUNT; i++) if (BLOCK_FORMAT_NAMES[i] == name) return i;
    return -1;
}

// A block's width and height in texels.
export function blockWidth(f: BlockFormat): u32 {
    if (f == BlockFormat.Rgba8) return 1;
    if (f == BlockFormat.Astc6x6) return 6;
    if (f == BlockFormat.Astc8x8) return 8;
    return 4;
}

export function blockHeight(f: BlockFormat): u32 {
    return blockWidth(f);
}

// A block's bytes.
export function blockBytes(f: BlockFormat): u32 {
    if (f == BlockFormat.Rgba8) return 4;
    if (f == BlockFormat.Bc1 || f == BlockFormat.Etc2Rgb) return 8;
    return 16;
}

// Whether the format stores alpha (BC1 and ETC2 RGB do not: they decode
// alpha 255).
export function hasAlpha(f: BlockFormat): bool {
    return f != BlockFormat.Bc1 && f != BlockFormat.Etc2Rgb;
}

// The bytes of one level of w x h texels.
export function levelBytes(f: BlockFormat, w: u32, h: u32): u32 {
    const bw = blockWidth(f);
    const bh = blockHeight(f);
    return ((w + bw - 1) / bw) * ((h + bh - 1) / bh) * blockBytes(f);
}

// The bytes of one row of blocks of a level w texels wide (what an upload's
// bytesPerRow is), and the rows of blocks of a level h texels high (its
// rowsPerImage).
export function rowBytes(f: BlockFormat, w: u32): u32 {
    const bw = blockWidth(f);
    return ((w + bw - 1) / bw) * blockBytes(f);
}

export function blockRows(f: BlockFormat, h: u32): u32 {
    const bh = blockHeight(f);
    return (h + bh - 1) / bh;
}

// A texture form: what the CLI's `build --target` and `render --textures`
// name, one family of the runtime's (gpuFeatures' bc, etc2, astc), or the
// source file as it is. Fixed numbers; `source` first.
export enum TextureForm {
    Source = 0,
    Bc = 1,
    Etc2 = 2,
    Astc = 3,
}

export const TEXTURE_FORM_COUNT: i32 = 4;
export const TEXTURE_FORM_NAMES: StaticArray<string> = ["source", "bc", "etc2", "astc"];

export function textureFormName(f: TextureForm): string {
    const i = <i32>f;
    return i >= 0 && i < TEXTURE_FORM_COUNT ? TEXTURE_FORM_NAMES[i] : "form " + i.toString();
}

// The form a name names, or -1.
export function textureFormOf(name: string): i32 {
    for (let i = 0; i < TEXTURE_FORM_COUNT; i++) if (TEXTURE_FORM_NAMES[i] == name) return i;
    return -1;
}

// The block format a texture takes in `form` (not Source): alpha says
// whether any texel's alpha is below 255, highQuality is the import's
// compress/high_quality, normalMap whether it is a normal map (which
// always takes the high-quality format: BC1's and ASTC 6x6's error bends
// normals visibly).
//
//   form  opaque           alpha            high quality / normal map
//   bc    bc1              bc3              bc7
//   etc2  etc2-rgb         etc2-rgba        etc2-rgb / etc2-rgba (one quality)
//   astc  astc-6x6         astc-6x6         astc-4x4
export function blockFormatFor(form: TextureForm, alpha: bool, highQuality: bool, normalMap: bool): BlockFormat {
    const hq = highQuality || normalMap;
    if (form == TextureForm.Bc) return hq ? BlockFormat.Bc7 : (alpha ? BlockFormat.Bc3 : BlockFormat.Bc1);
    if (form == TextureForm.Etc2) return alpha ? BlockFormat.Etc2Rgba : BlockFormat.Etc2Rgb;
    if (form == TextureForm.Astc) return hq ? BlockFormat.Astc4x4 : BlockFormat.Astc6x6;
    return BlockFormat.Rgba8;
}

// The form a block format belongs to (Rgba8: Source, as it needs no GPU
// family).
export function formOfBlockFormat(f: BlockFormat): TextureForm {
    if (f == BlockFormat.Bc1 || f == BlockFormat.Bc3 || f == BlockFormat.Bc7) return TextureForm.Bc;
    if (f == BlockFormat.Etc2Rgb || f == BlockFormat.Etc2Rgba) return TextureForm.Etc2;
    if (f == BlockFormat.Astc4x4 || f == BlockFormat.Astc6x6 || f == BlockFormat.Astc8x8) return TextureForm.Astc;
    return TextureForm.Source;
}

// Milestone 67b: the one empty array a released level's `data` becomes
// (CompressedImage.releaseLevels), shared, so a release allocates nothing.
const NO_BLOCKS: Uint8Array = new Uint8Array(0);

// One mip level: its size in texels and its blocks.
export class CompressedLevel {
    width: u32;
    height: u32;
    data: Uint8Array;

    constructor(width: u32, height: u32, data: Uint8Array) {
        this.width = width;
        this.height = height;
        this.data = data;
    }
}

// A texture in one block format with its mip chain (level 0 the largest,
// each next level half the size, rounded down, at least 1): what a KTX2
// file holds and what the renderer uploads as it is.
export class CompressedImage {
    format: BlockFormat;
    width: u32;
    height: u32;
    // The texels are sRGB-encoded colour (KTX2's *_SRGB_BLOCK formats): the
    // label the importer chose (process/srgb). The renderer samples them as
    // stored and decodes sRGB in the shader for a colour slot, as the
    // material slot says, whatever the label.
    srgb: bool = false;
    // Whether the texture is a normal map (the importer's choice; recorded
    // in the KTX2 key-value data, "hedra.normal_map").
    normalMap: bool = false;
    levels: Array<CompressedLevel> = [];
    // Milestone 67b (docs/engine/RESOURCES.md, "CPU copies"): the levels'
    // blocks were let go of once the texture was on the GPU
    // (releaseLevels): each level keeps its size and an empty `data`, and
    // the object is still the key the renderers' texture shares find its
    // upload by.
    released: bool = false;
    // Milestone 67b: released, then its texture freed, its upload with it
    // (as ../render/image.as Image.freed): never drawn again.
    freed: bool = false;
    // Kept on the CPU after its upload (../scene/resource/cpu_copy.as
    // pinForm): a flag, so a pin keeps nothing alive.
    pinned: bool = false;

    constructor(format: BlockFormat, width: u32, height: u32) {
        this.format = format;
        this.width = width;
        this.height = height;
    }

    // The blocks' bytes over every level (on the CPU: 0 once released).
    byteSize(): i64 {
        let n: i64 = 0;
        for (let i = 0; i < this.levels.length; i++) n += <i64>this.levels[i].data.length;
        return n;
    }

    // Milestone 67b: the blocks' bytes every level holds by its size
    // (levelBytes), released or not: what the texture takes on the device.
    deviceBytes(): i64 {
        let n: i64 = 0;
        for (let i = 0; i < this.levels.length; i++) {
            const l = this.levels[i];
            n += <i64>levelBytes(this.format, l.width, l.height);
        }
        return n;
    }

    // Milestone 67b: lets go of every level's blocks (see `released`),
    // their sizes kept; the bytes they held. Allocates nothing.
    releaseLevels(): i64 {
        if (this.released) return 0;
        const n = this.byteSize();
        for (let i = 0; i < this.levels.length; i++) this.levels[i].data = NO_BLOCKS;
        this.released = true;
        return n;
    }
}

// What an encoder is asked for.
export class EncodeOptions {
    // Effort, 0 (fastest) to 2 (best): how many candidates an encoder tries
    // (endpoints refined, BC7 modes, ETC2 modes, ASTC block modes). The
    // importer passes 1 unless compress/high_quality asks for 2.
    effort: i32 = 1;
    // Error weighting: perceptual (the colour channels weighted 0.299,
    // 0.587, 0.114 in sRGB, Rec. 601's luma) for an sRGB colour texture,
    // uniform for linear data and normal maps.
    perceptual: bool = true;
    // Whether alpha is kept (else the encoder may use alpha-less modes and
    // the decoder gives 255).
    alpha: bool = false;
}
