// Milestone 26, package WP1: the KTX 2.0 container (Khronos, "KTX File
// Format Specification" 2.0) for a CompressedImage: the processed form
// the importer caches (build/cache/import/*.ktx2) and the bundle stores
// (bundle/format.as TextureFormat.Ktx2). Readable by Khronos' `ktx info`.
//
// What this writer puts in it (docs/formats/IMPORT.md, "The KTX2 files"):
// the identifier; vkFormat (vkFormatOf: the *_UNORM_BLOCK or, for an sRGB
// texture, *_SRGB_BLOCK Vulkan format; R8G8B8A8 for Rgba8); typeSize 1;
// pixelWidth, pixelHeight; pixelDepth 0; layerCount 0; faceCount 1;
// levelCount; supercompressionScheme 0, or 3 (ZLIB, deflate through
// render/png.as zlibCompress) when `supercompress` and it saves bytes; the
// level index (level 0 first in the index, the smallest level first in
// the file, as the spec orders the data); a basic Data Format Descriptor
// for the format; key-value data "KTXwriter" = "hedra" (no version:
// the bytes must not change with it) and "hedra.normal_map" = "1" for a
// normal map; each level aligned as the specification asks: to lcm(4,
// block bytes) without supercompression (4 for rgba8, 8 for bc1 and
// etc2-rgb, 16 for the rest), to 1 with it.
//
// readKtx2 reads what this writer writes, and any KTX2 file of these
// vkFormats with supercompression 0 or 3, one layer, one face, 2D; it
// fails, never traps, on anything else.
//
// Milestone 67b (docs/engine/RESOURCES.md, "Loading"): a level stored
// without supercompression is a view of the file's bytes (the bundle's
// entry, which the run time keeps), not a copy of them; a deflated one is
// inflated straight into its own buffer by a pooled inflater
// (render/png.as zlibDecompress), so that reading a texture allocates its
// levels' bytes once, or not at all. Nothing writes into a level's bytes
// (they are uploaded, or decoded on the CPU into new ones).
//
// Layout of a file this writer makes (all little-endian):
//   0    identifier (12), vkFormat, typeSize, pixelWidth, pixelHeight,
//        pixelDepth, layerCount, faceCount, levelCount,
//        supercompressionScheme (u32 each)
//   48   dfdByteOffset, dfdByteLength, kvdByteOffset, kvdByteLength (u32),
//        sgdByteOffset, sgdByteLength (u64, both 0)
//   80   level index: per level, level 0 first, byteOffset, byteLength,
//        uncompressedByteLength (u64 each)
//   then the DFD (dfdTotalSize, one basic block), the key-value data, and
//   the levels, smallest first.

import { Result } from "../base/util";
import { zlibDecompress } from "../render/png";
import { BlockFormat, CompressedImage, CompressedLevel, blockBytes, blockFormatName, levelBytes } from "./format";

// The 12-byte file identifier: «KTX 20»\r\n\x1A\n.
export const KTX2_IDENTIFIER: StaticArray<u8> = [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A];

export const KTX2_EXTENSION = "ktx2";

// supercompressionScheme values this code knows.
export const KTX2_SUPERCOMPRESSION_NONE: u32 = 0;
export const KTX2_SUPERCOMPRESSION_ZLIB: u32 = 3;
// The key-value entry that marks a normal map (written by the compiler).
export const KV_NORMAL_MAP = "hedra.normal_map";

// The Vulkan format of a block format (VkFormat numbers from the Vulkan
// specification): R8G8B8A8_UNORM 37 / _SRGB 43, BC1_RGBA_UNORM_BLOCK 133 /
// SRGB 134, BC3 137 / 138, BC7 145 / 146, ETC2_R8G8B8 147 / 148,
// ETC2_R8G8B8A8 151 / 152, ASTC_4x4 157 / 158, ASTC_6x6 165 / 166,
// ASTC_8x8 171 / 172.
export function vkFormatOf(f: BlockFormat, srgb: bool): u32 {
    switch (f) {
        case BlockFormat.Rgba8: return srgb ? 43 : 37;
        case BlockFormat.Bc1: return srgb ? 134 : 133;
        case BlockFormat.Bc3: return srgb ? 138 : 137;
        case BlockFormat.Bc7: return srgb ? 146 : 145;
        case BlockFormat.Etc2Rgb: return srgb ? 148 : 147;
        case BlockFormat.Etc2Rgba: return srgb ? 152 : 151;
        case BlockFormat.Astc4x4: return srgb ? 158 : 157;
        case BlockFormat.Astc6x6: return srgb ? 166 : 165;
        case BlockFormat.Astc8x8: return srgb ? 172 : 171;
        default: return 0;
    }
}

// The block format of a Vulkan format this code reads, or -1; `srgb` (a
// one-element array, as the caller's out-parameter) says whether it was an
// _SRGB one.
export function blockFormatOfVk(vk: u32, srgb: Array<bool>): i32 {
    for (let f = 0; f < 9; f++) {
        if (vkFormatOf(<BlockFormat>f, false) == vk) { if (srgb.length > 0) srgb[0] = false; return f; }
        if (vkFormatOf(<BlockFormat>f, true) == vk) { if (srgb.length > 0) srgb[0] = true; return f; }
    }
    return -1;
}

// Whether `bytes` start with the KTX2 identifier.
export function looksLikeKtx2(bytes: Uint8Array): bool {
    if (bytes.length < KTX2_IDENTIFIER.length) return false;
    for (let i = 0; i < KTX2_IDENTIFIER.length; i++) if (bytes[i] != KTX2_IDENTIFIER[i]) return false;
    return true;
}

// ---------------------------------------------------------------------------
// The Data Format Descriptor (Khronos Data Format Specification 1.3, the
// basic block): colour model, primaries BT.709, transfer sRGB or linear,
// the block's size and bytes, and one sample per channel as KTX-Software's
// vk2dfd gives them for these formats.

function getU32(b: Uint8Array, o: i32): u32 {
    return <u32>b[o] | (<u32>b[o + 1] << 8) | (<u32>b[o + 2] << 16) | (<u32>b[o + 3] << 24);
}

function getU64(b: Uint8Array, o: i32): u64 {
    return <u64>getU32(b, o) | (<u64>getU32(b, o + 4) << 32);
}

export function alignUp(v: i32, a: i32): i32 {
    return ((v + a - 1) / a) * a;
}

// The level alignment the specification asks for: lcm(4, block bytes)
// without supercompression, 1 with it.
export function levelAlignment(f: BlockFormat, scheme: u32): i32 {
    if (scheme != KTX2_SUPERCOMPRESSION_NONE) return 1;
    const b = <i32>blockBytes(f);
    return b % 4 == 0 ? b : b * 4;
}

export const HEADER_BYTES = 80;
export const LEVEL_ENTRY_BYTES = 24;

// The largest side readKtx2 accepts (a bigger header is corrupt or not a
// texture this project makes: levelBytes stays within 32 bits).
export const KTX2_MAX_SIDE: u32 = 16384;

function fail(what: string, why: string): Result<CompressedImage> {
    return Result.fail<CompressedImage>(what + ": " + why);
}

// Reads a KTX2 file of one of this project's block formats (vkFormatOf),
// 2D, one layer, one face, supercompression 0 or 3. `what` names the file
// in a failure ("res://stone.png's bc form"). Never traps: every offset
// and length is checked against the bytes before it is used.
export function readKtx2(bytes: Uint8Array, what: string): Result<CompressedImage> {
    if (!looksLikeKtx2(bytes)) return fail(what, "not a KTX2 file (no KTX 20 identifier)");
    const len = bytes.length;
    if (len < HEADER_BYTES) return fail(what, "truncated KTX2 header (" + len.toString() + " bytes of 80)");
    const vk = getU32(bytes, 12);
    const srgb: Array<bool> = [false];
    const fi = blockFormatOfVk(vk, srgb);
    if (fi < 0) return fail(what, "unsupported vkFormat " + vk.toString());
    const format = <BlockFormat>fi;
    const typeSize = getU32(bytes, 16);
    if (typeSize != 1) return fail(what, "typeSize " + typeSize.toString() + " (a block format's is 1)");
    const w = getU32(bytes, 20);
    const h = getU32(bytes, 24);
    if (w == 0 || h == 0) return fail(what, "a 1D or empty texture (" + w.toString() + " x " + h.toString() + ")");
    if (w > KTX2_MAX_SIDE || h > KTX2_MAX_SIDE) {
        return fail(what, w.toString() + " x " + h.toString() + " exceeds " + KTX2_MAX_SIDE.toString() + " texels a side");
    }
    if (getU32(bytes, 28) != 0) return fail(what, "a 3D texture (pixelDepth " + getU32(bytes, 28).toString() + ")");
    const layers = getU32(bytes, 32);
    if (layers > 1) return fail(what, "an array texture (" + layers.toString() + " layers)");
    const faces = getU32(bytes, 36);
    if (faces != 1) return fail(what, faces.toString() + " faces (a cube map is not a 2D texture)");
    const levelCount = getU32(bytes, 40);
    let maxLevels = 1;
    {
        let s = w > h ? w : h;
        while (s > 1) { s >>= 1; maxLevels++; }
    }
    // Checked unsigned before the cast: 0x80000000 or more would turn
    // negative as an i32, slip past this check and the index-size check
    // (which then wraps) and come back as an image with no levels.
    if (levelCount > <u32>maxLevels) return fail(what, levelCount.toString() + " levels for " + w.toString() + " x " + h.toString() + " (at most " + maxLevels.toString() + ")");
    // levelCount 0 asks a loader to make the mips; the file holds level 0.
    const n = levelCount == 0 ? 1 : <i32>levelCount;
    const scheme = getU32(bytes, 44);
    if (scheme != KTX2_SUPERCOMPRESSION_NONE && scheme != KTX2_SUPERCOMPRESSION_ZLIB) {
        return fail(what, "unsupported supercompressionScheme " + scheme.toString() + " (0 none and 3 zlib are read)");
    }
    if (HEADER_BYTES + LEVEL_ENTRY_BYTES * n > len) return fail(what, "truncated level index");
    // The key-value data: only hedra.normal_map is read.
    const kvdOffset = getU32(bytes, 56);
    const kvdLength = getU32(bytes, 60);
    let normalMap = false;
    if (kvdLength > 0) {
        if (<u64>kvdOffset + <u64>kvdLength > <u64>len) return fail(what, "key-value data past the end of the file");
        let p = <i32>kvdOffset;
        const end = <i32>(kvdOffset + kvdLength);
        while (p + 4 <= end) {
            const n2 = getU32(bytes, p);
            if (<u64>p + 4 + <u64>n2 > <u64>end) return fail(what, "a key-value entry past the end of the key-value data");
            const start = p + 4;
            const stop = start + <i32>n2;
            // The key runs to its NUL; the value follows.
            let k = start;
            while (k < stop && bytes[k] != 0) k++;
            if (k < stop && matches(bytes, start, k, KV_NORMAL_MAP)) {
                normalMap = k + 1 < stop && bytes[k + 1] == 0x31;
            }
            p = start + ((<i32>n2 + 3) & ~3);
        }
    }
    const ci = new CompressedImage(format, w, h);
    ci.srgb = srgb[0];
    ci.normalMap = normalMap;
    let lw = w, lh = h;
    for (let i = 0; i < n; i++) {
        const o = HEADER_BYTES + i * LEVEL_ENTRY_BYTES;
        const off = getU64(bytes, o);
        const size = getU64(bytes, o + 8);
        const full = getU64(bytes, o + 16);
        const need = levelBytes(format, lw, lh);
        if (full != <u64>need) {
            return fail(what, "level " + i.toString() + " holds " + full.toString() + " bytes uncompressed; a "
                + lw.toString() + " x " + lh.toString() + " " + blockFormatName(format) + " level takes " + need.toString());
        }
        if (off > <u64>len || size > <u64>len - off) return fail(what, "level " + i.toString() + " lies past the end of the file");
        const stored = bytes.subarray(<i32>off, <i32>(off + size));
        let data: Uint8Array;
        if (scheme == KTX2_SUPERCOMPRESSION_NONE) {
            if (size != full) return fail(what, "level " + i.toString() + " stores " + size.toString() + " bytes, not " + full.toString());
            // (milestone 67b: the file's bytes themselves, see the header)
            data = stored;
        } else {
            // Deflate expands at most 1032 to 1: a level claiming more is
            // corrupt, and refusing it here spares the allocation.
            if (<u64>need > size * 1032 + 64) {
                return fail(what, "level " + i.toString() + " cannot inflate from " + size.toString() + " to " + need.toString() + " bytes");
            }
            const r = zlibDecompress(stored, <i32>need);
            if (!r.ok) return fail(what, "level " + i.toString() + " does not inflate: " + r.err);
            data = r.value;
        }
        ci.levels.push(new CompressedLevel(lw, lh, data));
        lw = lw > 1 ? lw >> 1 : 1;
        lh = lh > 1 ? lh >> 1 : 1;
    }
    return Result.okv<CompressedImage>(ci);
}

function matches(b: Uint8Array, start: i32, end: i32, s: string): bool {
    if (end - start != s.length) return false;
    for (let i = 0; i < s.length; i++) if (<i32>b[start + i] != s.charCodeAt(i)) return false;
    return true;
}
