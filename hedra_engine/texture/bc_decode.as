// Milestone 26, package WP1: BC1, BC3 and BC7 decoders, to RGBA8 texels as
// the D3D11 functional specification decodes them (BC1's thirds rounded
// as (2a + b + 1) / 3; BC7 every mode). Part of the run time (a
// device without the bc family draws a bc texture decoded here), so it
// imports nothing the run time leaves out. Any bytes decode without a trap:
// a reserved BC7 mode decodes to transparent black, as the spec says.
//
// The tables BC7 needs (the modes, the partitions, the anchors, the
// weights) are exported for the encoder (bc_encode.as), which must agree
// with this file to the bit.

import { Image } from "../render/image";

// ---------------------------------------------------------------------------
// Shared scratch: one decoded block of 16 texels, RGBA, raster order. The
// decoders allocate nothing but the image they return.

const TEX = new StaticArray<u8>(64);

// Copies the decoded block at block (bx, by) into the image, dropping the
// texels past its right and bottom edges.
function storeBlock(out: Uint8Array, w: u32, h: u32, bx: u32, by: u32): void {
    const x0 = bx * 4;
    const y0 = by * 4;
    for (let y: u32 = 0; y < 4; y++) {
        const py = y0 + y;
        if (py >= h) break;
        for (let x: u32 = 0; x < 4; x++) {
            const px = x0 + x;
            if (px >= w) break;
            const o = <i32>((py * w + px) * 4);
            const t = <i32>((y * 4 + x) * 4);
            out[o] = unchecked(TEX[t]);
            out[o + 1] = unchecked(TEX[t + 1]);
            out[o + 2] = unchecked(TEX[t + 2]);
            out[o + 3] = unchecked(TEX[t + 3]);
        }
    }
}

// Blocks of `bytes` bytes, w x h texels, through `decode(data, offset)`
// (which fills TEX); a block past the end of `data` decodes as zeros.
function decodeBlocks(data: Uint8Array, w: u32, h: u32, bytes: i32, which: i32): Image {
    const out = new Uint8Array(<i32>(w * h * 4));
    const bw = (w + 3) / 4;
    const bh = (h + 3) / 4;
    let off = 0;
    for (let by: u32 = 0; by < bh; by++) {
        for (let bx: u32 = 0; bx < bw; bx++) {
            if (off + bytes <= data.length) {
                if (which == 1) bc1Block(data, off, false, true);
                else if (which == 3) bc3Block(data, off);
                else bc7Block(data, off);
            } else {
                for (let i = 0; i < 64; i++) TEX[i] = 0;
            }
            storeBlock(out, w, h, bx, by);
            off += bytes;
        }
    }
    return new Image(w, h, out);
}

// ---------------------------------------------------------------------------
// BC1 (and BC3's colour half)

// A 5-bit, 6-bit value widened to 8 bits by repeating its top bits.
export function expand5(v: i32): i32 { return (v << 3) | (v >> 2); }
export function expand6(v: i32): i32 { return (v << 2) | (v >> 4); }

// The colour block at data[off..off+8] into TEX. `fourAlways`: BC3's colour
// half, always four colours whatever the endpoints' order; else BC1, three
// colours and transparent black when c0 <= c1. `setAlpha`: write alpha
// (BC3 writes its own afterwards).
function bc1Block(data: Uint8Array, off: i32, fourAlways: bool, setAlpha: bool): void {
    const c0 = <i32>data[off] | (<i32>data[off + 1] << 8);
    const c1 = <i32>data[off + 2] | (<i32>data[off + 3] << 8);
    const r0 = expand5(c0 >> 11), g0 = expand6((c0 >> 5) & 63), b0 = expand5(c0 & 31);
    const r1 = expand5(c1 >> 11), g1 = expand6((c1 >> 5) & 63), b1 = expand5(c1 & 31);
    let r2: i32, g2: i32, b2: i32, r3: i32, g3: i32, b3: i32, a3: i32;
    if (fourAlways || c0 > c1) {
        r2 = (2 * r0 + r1 + 1) / 3; g2 = (2 * g0 + g1 + 1) / 3; b2 = (2 * b0 + b1 + 1) / 3;
        r3 = (r0 + 2 * r1 + 1) / 3; g3 = (g0 + 2 * g1 + 1) / 3; b3 = (b0 + 2 * b1 + 1) / 3;
        a3 = 255;
    } else {
        r2 = (r0 + r1 + 1) >> 1; g2 = (g0 + g1 + 1) >> 1; b2 = (b0 + b1 + 1) >> 1;
        r3 = 0; g3 = 0; b3 = 0; a3 = 0;
    }
    const bits = <u32>data[off + 4] | (<u32>data[off + 5] << 8) | (<u32>data[off + 6] << 16) | (<u32>data[off + 7] << 24);
    for (let i = 0; i < 16; i++) {
        const k = (bits >> <u32>(i * 2)) & 3;
        const t = i * 4;
        let r = r0, g = g0, b = b0, a = 255;
        if (k == 1) { r = r1; g = g1; b = b1; }
        else if (k == 2) { r = r2; g = g2; b = b2; }
        else if (k == 3) { r = r3; g = g3; b = b3; a = a3; }
        TEX[t] = <u8>r;
        TEX[t + 1] = <u8>g;
        TEX[t + 2] = <u8>b;
        if (setAlpha) TEX[t + 3] = <u8>a;
    }
}

// The value of index k (0..7) of a BC4 block with endpoints a0, a1, as the
// spec's float formula rounds it: eight values when a0 > a1, else six and
// then 0 and 255.
export function bc4Value(a0: i32, a1: i32, k: i32): i32 {
    if (k == 0) return a0;
    if (k == 1) return a1;
    if (a0 > a1) return ((8 - k) * a0 + (k - 1) * a1 + 3) / 7;
    if (k == 6) return 0;
    if (k == 7) return 255;
    return ((6 - k) * a0 + (k - 1) * a1 + 2) / 5;
}

function bc3Block(data: Uint8Array, off: i32): void {
    bc1Block(data, off + 8, true, false);
    const a0 = <i32>data[off];
    const a1 = <i32>data[off + 1];
    let lo: u32 = <u32>data[off + 2] | (<u32>data[off + 3] << 8) | (<u32>data[off + 4] << 16);
    let hi: u32 = <u32>data[off + 5] | (<u32>data[off + 6] << 8) | (<u32>data[off + 7] << 16);
    for (let i = 0; i < 16; i++) {
        const k = i < 8 ? <i32>((lo >> <u32>(i * 3)) & 7) : <i32>((hi >> <u32>((i - 8) * 3)) & 7);
        TEX[i * 4 + 3] = <u8>bc4Value(a0, a1, k);
    }
}

export function decodeBc1(data: Uint8Array, w: u32, h: u32): Image {
    return decodeBlocks(data, w, h, 8, 1);
}

export function decodeBc3(data: Uint8Array, w: u32, h: u32): Image {
    return decodeBlocks(data, w, h, 16, 3);
}

// ---------------------------------------------------------------------------
// BC7

// Per mode 0..7: subsets, partition bits, rotation bits, index-selection
// bits, colour bits, alpha bits, endpoint p-bits (one per endpoint), shared
// p-bits (one per subset), index bits, second index bits.
export const BC7_NS: StaticArray<i32> = [3, 2, 3, 2, 1, 1, 1, 2];
export const BC7_PB: StaticArray<i32> = [4, 6, 6, 6, 0, 0, 0, 6];
export const BC7_RB: StaticArray<i32> = [0, 0, 0, 0, 2, 2, 0, 0];
export const BC7_ISB: StaticArray<i32> = [0, 0, 0, 0, 1, 0, 0, 0];
export const BC7_CB: StaticArray<i32> = [4, 6, 5, 7, 5, 7, 7, 5];
export const BC7_AB: StaticArray<i32> = [0, 0, 0, 0, 6, 8, 7, 5];
export const BC7_EPB: StaticArray<i32> = [1, 0, 0, 1, 0, 0, 1, 1];
export const BC7_SPB: StaticArray<i32> = [0, 1, 0, 0, 0, 0, 0, 0];
export const BC7_IB: StaticArray<i32> = [3, 3, 2, 2, 2, 2, 4, 2];
export const BC7_IB2: StaticArray<i32> = [0, 0, 0, 0, 3, 2, 0, 0];

// The interpolation weights (of 64) for 2-, 3- and 4-bit indices.
export const BC7_W2: StaticArray<i32> = [0, 21, 43, 64];
export const BC7_W3: StaticArray<i32> = [0, 9, 18, 27, 37, 46, 55, 64];
export const BC7_W4: StaticArray<i32> = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64];

export function bc7Weight(bits: i32, k: i32): i32 {
    if (bits == 2) return unchecked(BC7_W2[k & 3]);
    if (bits == 3) return unchecked(BC7_W3[k & 7]);
    return unchecked(BC7_W4[k & 15]);
}

// The two-subset partitions: bit i of entry p is texel i's subset (texel i
// = y * 4 + x).
const P2_MASKS: StaticArray<u16> = [
    0xCCCC, 0x8888, 0xEEEE, 0xECC8, 0xC880, 0xFEEC, 0xFEC8, 0xEC80,
    0xC800, 0xFFEC, 0xFE80, 0xE800, 0xFFE8, 0xFF00, 0xFFF0, 0xF000,
    0xF710, 0x008E, 0x7100, 0x08CE, 0x008C, 0x7310, 0x3100, 0x8CCE,
    0x088C, 0x3110, 0x6666, 0x366C, 0x17E8, 0x0FF0, 0x718E, 0x399C,
    0xAAAA, 0xF0F0, 0x5A5A, 0x33CC, 0x3C3C, 0x55AA, 0x9696, 0xA55A,
    0x73CE, 0x13C8, 0x324C, 0x3BDC, 0x6996, 0xC33C, 0x9966, 0x0660,
    0x0272, 0x04E4, 0x4E40, 0x2720, 0xC936, 0x936C, 0x39C6, 0x639C,
    0x9336, 0x9CC6, 0x817E, 0xE718, 0xCCF0, 0x0FCC, 0x7744, 0xEE22,
];

// The three-subset partitions: entry p * 16 + i is texel i's subset.
const P3: StaticArray<u8> = [
    0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 1, 2, 2, 2, 2,
    0, 0, 0, 1, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 2, 1,
    0, 0, 0, 0, 2, 0, 0, 1, 2, 2, 1, 1, 2, 2, 1, 1,
    0, 2, 2, 2, 0, 0, 2, 2, 0, 0, 1, 1, 0, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2,
    0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 2, 2, 0, 0, 2, 2,
    0, 0, 2, 2, 0, 0, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2,
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2,
    0, 1, 1, 2, 0, 1, 1, 2, 0, 1, 1, 2, 0, 1, 1, 2,
    0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 2,
    0, 0, 1, 1, 0, 1, 1, 2, 1, 1, 2, 2, 1, 2, 2, 2,
    0, 0, 1, 1, 2, 0, 0, 1, 2, 2, 0, 0, 2, 2, 2, 0,
    0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 2, 1, 1, 2, 2,
    0, 1, 1, 1, 0, 0, 1, 1, 2, 0, 0, 1, 2, 2, 0, 0,
    0, 0, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2,
    0, 0, 2, 2, 0, 0, 2, 2, 0, 0, 2, 2, 1, 1, 1, 1,
    0, 1, 1, 1, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2,
    0, 0, 0, 1, 0, 0, 0, 1, 2, 2, 2, 1, 2, 2, 2, 1,
    0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 2, 2, 0, 1, 2, 2,
    0, 0, 0, 0, 1, 1, 0, 0, 2, 2, 1, 0, 2, 2, 1, 0,
    0, 1, 2, 2, 0, 1, 2, 2, 0, 0, 1, 1, 0, 0, 0, 0,
    0, 0, 1, 2, 0, 0, 1, 2, 1, 1, 2, 2, 2, 2, 2, 2,
    0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1, 0, 1, 1, 0,
    0, 0, 0, 0, 0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1,
    0, 0, 2, 2, 1, 1, 0, 2, 1, 1, 0, 2, 0, 0, 2, 2,
    0, 1, 1, 0, 0, 1, 1, 0, 2, 0, 0, 2, 2, 2, 2, 2,
    0, 0, 1, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 0, 1, 1,
    0, 0, 0, 0, 2, 0, 0, 0, 2, 2, 1, 1, 2, 2, 2, 1,
    0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 2, 2, 2,
    0, 2, 2, 2, 0, 0, 2, 2, 0, 0, 1, 2, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 2, 0, 0, 2, 2, 0, 2, 2, 2,
    0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0,
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0,
    0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0,
    0, 1, 2, 0, 2, 0, 1, 2, 1, 2, 0, 1, 0, 1, 2, 0,
    0, 0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0, 0, 1, 1,
    0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0, 1, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 2, 1,
    0, 0, 2, 2, 1, 1, 2, 2, 0, 0, 2, 2, 1, 1, 2, 2,
    0, 0, 2, 2, 0, 0, 1, 1, 0, 0, 2, 2, 0, 0, 1, 1,
    0, 2, 2, 0, 1, 2, 2, 1, 0, 2, 2, 0, 1, 2, 2, 1,
    0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 0, 1, 0, 1,
    0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2,
    0, 2, 2, 2, 0, 1, 1, 1, 0, 2, 2, 2, 0, 1, 1, 1,
    0, 0, 0, 2, 1, 1, 1, 2, 0, 0, 0, 2, 1, 1, 1, 2,
    0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2,
    0, 2, 2, 2, 0, 1, 1, 1, 0, 1, 1, 1, 0, 2, 2, 2,
    0, 0, 0, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2,
    0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 1, 2,
    0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 2, 2, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 2, 2,
    0, 0, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2, 0, 0, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2,
    0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1,
    0, 2, 2, 2, 1, 2, 2, 2, 0, 2, 2, 2, 1, 2, 2, 2,
    0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 1, 1, 1, 2, 0, 1, 1, 2, 2, 0, 1, 2, 2, 2, 0,
];

// The second subset's anchor texel of each two-subset partition.
export const BC7_ANCHOR2: StaticArray<u8> = [
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
    15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6,
    6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15,
];

// The second and third subsets' anchor texels of each three-subset
// partition.
export const BC7_ANCHOR3A: StaticArray<u8> = [
    3, 3, 15, 15, 8, 3, 15, 15, 8, 8, 6, 6, 6, 5, 3, 3,
    3, 3, 8, 15, 3, 3, 6, 10, 5, 8, 8, 6, 8, 5, 15, 15,
    8, 15, 3, 5, 6, 10, 8, 15, 15, 3, 15, 5, 15, 15, 15, 15,
    3, 15, 5, 5, 5, 8, 5, 10, 5, 10, 8, 13, 15, 12, 3, 3,
];
export const BC7_ANCHOR3B: StaticArray<u8> = [
    15, 8, 8, 3, 15, 15, 3, 8, 15, 15, 15, 15, 15, 15, 15, 8,
    15, 8, 15, 3, 15, 8, 15, 8, 3, 15, 6, 10, 15, 15, 10, 8,
    15, 3, 15, 10, 10, 8, 9, 10, 6, 15, 8, 15, 3, 6, 6, 8,
    15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3, 15, 15, 8,
];

// The texels of subset 1 of two-subset partition p, as a 16-bit mask.
export function bc7Mask2(p: i32): i32 {
    return <i32>unchecked(P2_MASKS[p & 63]);
}

// Texel i's subset in partition p of a mode with `ns` subsets.
export function bc7Subset(ns: i32, p: i32, i: i32): i32 {
    if (ns == 2) return (<i32>unchecked(P2_MASKS[p & 63]) >> i) & 1;
    if (ns == 3) return <i32>unchecked(P3[((p & 63) << 4) + i]);
    return 0;
}

// Whether texel i is an anchor (its index has one bit less) in partition p.
export function bc7IsAnchor(ns: i32, p: i32, i: i32): bool {
    if (i == 0) return true;
    if (ns == 2) return i == <i32>unchecked(BC7_ANCHOR2[p & 63]);
    if (ns == 3) return i == <i32>unchecked(BC7_ANCHOR3A[p & 63]) || i == <i32>unchecked(BC7_ANCHOR3B[p & 63]);
    return false;
}

// The block's 128 bits as two little-endian halves, read from bit POS on.
let LO: u64 = 0;
let HI: u64 = 0;
let POS: i32 = 0;

function bits(n: i32): i32 {
    if (n == 0) return 0;
    const p = POS;
    POS += n;
    const mask: u64 = (<u64>1 << <u64>n) - 1;
    if (p >= 64) return <i32>((HI >> <u64>(p - 64)) & mask);
    if (p + n <= 64) return <i32>((LO >> <u64>p) & mask);
    // Spans the halves.
    const low = 64 - p;
    return <i32>(((LO >> <u64>p) | (HI << <u64>low)) & mask);
}

// Endpoints of the block being decoded: [endpoint 0..5][channel 0..3].
const EP = new StaticArray<i32>(24);
const IDX = new StaticArray<i32>(16);
const IDX2 = new StaticArray<i32>(16);

function load64(data: Uint8Array, off: i32): u64 {
    let v: u64 = 0;
    for (let i = 7; i >= 0; i--) v = (v << 8) | <u64>data[off + i];
    return v;
}

// A value of n bits (n >= 5 here) widened to 8 by repeating its top bits.
function widen(v: i32, n: i32): i32 {
    if (n >= 8) return v & 255;
    v = v << (8 - n);
    return v | (v >> n);
}

function bc7Block(data: Uint8Array, off: i32): void {
    const m0 = <i32>data[off];
    if (m0 == 0) {
        // Reserved mode 8: transparent black.
        for (let i = 0; i < 64; i++) TEX[i] = 0;
        return;
    }
    LO = load64(data, off);
    HI = load64(data, off + 8);
    let mode = 0;
    while (((m0 >> mode) & 1) == 0) mode++;
    POS = mode + 1;
    const ns = unchecked(BC7_NS[mode]);
    const part = bits(unchecked(BC7_PB[mode]));
    const rot = bits(unchecked(BC7_RB[mode]));
    const isb = bits(unchecked(BC7_ISB[mode]));
    const cb = unchecked(BC7_CB[mode]);
    const ab = unchecked(BC7_AB[mode]);
    const ne = ns * 2;
    for (let c = 0; c < 3; c++) for (let e = 0; e < ne; e++) EP[e * 4 + c] = bits(cb);
    for (let e = 0; e < ne; e++) EP[e * 4 + 3] = ab > 0 ? bits(ab) : 255;
    let cbits = cb;
    let abits = ab;
    if (unchecked(BC7_EPB[mode]) != 0) {
        for (let e = 0; e < ne; e++) {
            const p = bits(1);
            for (let c = 0; c < 3; c++) EP[e * 4 + c] = (unchecked(EP[e * 4 + c]) << 1) | p;
            if (ab > 0) EP[e * 4 + 3] = (unchecked(EP[e * 4 + 3]) << 1) | p;
        }
        cbits++;
        if (ab > 0) abits++;
    } else if (unchecked(BC7_SPB[mode]) != 0) {
        for (let s = 0; s < ns; s++) {
            const p = bits(1);
            for (let e = s * 2; e < s * 2 + 2; e++) {
                for (let c = 0; c < 3; c++) EP[e * 4 + c] = (unchecked(EP[e * 4 + c]) << 1) | p;
            }
        }
        cbits++;
    }
    for (let e = 0; e < ne; e++) {
        for (let c = 0; c < 3; c++) EP[e * 4 + c] = widen(unchecked(EP[e * 4 + c]), cbits);
        if (ab > 0) EP[e * 4 + 3] = widen(unchecked(EP[e * 4 + 3]), abits);
    }
    const ib = unchecked(BC7_IB[mode]);
    const ib2 = unchecked(BC7_IB2[mode]);
    for (let i = 0; i < 16; i++) IDX[i] = bits(bc7IsAnchor(ns, part, i) ? ib - 1 : ib);
    if (ib2 > 0) for (let i = 0; i < 16; i++) IDX2[i] = bits(i == 0 ? ib2 - 1 : ib2);
    for (let i = 0; i < 16; i++) {
        const s = bc7Subset(ns, part, i);
        let wc: i32, wa: i32;
        if (ib2 == 0) {
            wc = bc7Weight(ib, unchecked(IDX[i]));
            wa = wc;
        } else if (isb == 0) {
            wc = bc7Weight(ib, unchecked(IDX[i]));
            wa = bc7Weight(ib2, unchecked(IDX2[i]));
        } else {
            wc = bc7Weight(ib2, unchecked(IDX2[i]));
            wa = bc7Weight(ib, unchecked(IDX[i]));
        }
        const e0 = s * 8;
        const e1 = e0 + 4;
        const t = i * 4;
        let r = ((64 - wc) * unchecked(EP[e0]) + wc * unchecked(EP[e1]) + 32) >> 6;
        let g = ((64 - wc) * unchecked(EP[e0 + 1]) + wc * unchecked(EP[e1 + 1]) + 32) >> 6;
        let b = ((64 - wc) * unchecked(EP[e0 + 2]) + wc * unchecked(EP[e1 + 2]) + 32) >> 6;
        let a = ((64 - wa) * unchecked(EP[e0 + 3]) + wa * unchecked(EP[e1 + 3]) + 32) >> 6;
        if (rot == 1) { const x = a; a = r; r = x; }
        else if (rot == 2) { const x = a; a = g; g = x; }
        else if (rot == 3) { const x = a; a = b; b = x; }
        TEX[t] = <u8>r;
        TEX[t + 1] = <u8>g;
        TEX[t + 2] = <u8>b;
        TEX[t + 3] = <u8>a;
    }
}

export function decodeBc7(data: Uint8Array, w: u32, h: u32): Image {
    return decodeBlocks(data, w, h, 16, 7);
}
