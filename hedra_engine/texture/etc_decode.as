// Milestone 26, package WP1: ETC2 RGB8 and ETC2 RGBA8 decoders (every
// mode: individual, differential, T, H, planar; EAC alpha), to RGBA8 as
// the Khronos Data Format specification decodes them. Part of the
// run time; any bytes decode without a trap.
//
// A block is 64 bits big-endian (byte 0 holds bits 63..56). HI below is
// bits 63..32, LO bits 31..0. Texel (x, y) of the 4 x 4 block is texel
// number x * 4 + y in the index bits (column by column), and its 2-bit
// index is bit 16 + n of LO (the high bit) with bit n (the low bit).
//
// Bits 63..32 by mode (the Khronos specification's tables, as read here):
//   individual (bit 33 = 0)  R1 63..60  R2 59..56  G1 55..52  G2 51..48
//                            B1 47..44  B2 43..40
//   differential (bit 33 = 1, no overflow)
//                            R 63..59  dR 58..56  G 55..51  dG 50..48
//                            B 47..43  dB 42..40 (3-bit two's complement)
//   both                     table 1 39..37, table 2 36..34, flip 32
//   T (R + dR overflows)     R1 60..59 57..56  G1 55..52  B1 51..48
//                            R2 47..44  G2 43..40  B2 39..36
//                            distance 35..34 32
//   H (G + dG overflows)     R1 62..59  G1 58..56 52  B1 51 49..47
//                            R2 46..43  G2 42..39  B2 38..35
//                            distance 34 32 (and R1G1B1 >= R2G2B2)
//   planar (B + dB overflows)
//                            RO 62..57  GO 56 54..49  BO 48 44..43 41..39
//                            RH 38..34 32  GH 31..25  BH 24..19
//                            RV 18..13  GV 12..6  BV 5..0
// The EAC alpha block (ETC2 RGBA8's first 8 bytes): base 63..56,
// multiplier 55..52, table 51..48, then a 3-bit index per texel from bit
// 47 down, texel 0 first.

import { Image } from "../render/image";

// ETC1's modifier tables: [table][0..1] = the small and the large step.
export const ETC1_MODIFIERS: StaticArray<i32> = [
    2, 8, 5, 17, 9, 29, 13, 42, 18, 60, 24, 80, 33, 106, 47, 183,
];

// The T and H modes' distances.
export const ETC2_DISTANCES: StaticArray<i32> = [3, 6, 11, 16, 23, 32, 41, 64];

// EAC's modifier tables: [table][index 0..7].
export const EAC_MODIFIERS: StaticArray<i32> = [
    -3, -6, -9, -15, 2, 5, 8, 14,
    -3, -7, -10, -13, 2, 6, 9, 12,
    -2, -5, -8, -13, 1, 4, 7, 12,
    -2, -4, -6, -13, 1, 3, 5, 12,
    -3, -6, -8, -12, 2, 5, 7, 11,
    -3, -7, -9, -11, 2, 6, 8, 10,
    -4, -7, -8, -11, 3, 6, 7, 10,
    -3, -5, -8, -11, 2, 4, 7, 10,
    -2, -6, -8, -10, 1, 5, 7, 9,
    -2, -5, -8, -10, 1, 4, 7, 9,
    -2, -4, -8, -10, 1, 3, 7, 9,
    -2, -5, -7, -10, 1, 4, 6, 9,
    -3, -4, -7, -10, 2, 3, 6, 9,
    -1, -2, -3, -10, 0, 1, 2, 9,
    -4, -6, -8, -9, 3, 5, 7, 8,
    -3, -5, -7, -9, 2, 4, 6, 8,
];

// The value an ETC1 index (0..3: +small, +large, -small, -large) adds with
// table t.
export function etc1Modifier(t: i32, k: i32): i32 {
    const v = unchecked(ETC1_MODIFIERS[((t & 7) << 1) + (k & 1)]);
    return (k & 2) != 0 ? -v : v;
}

// One decoded block: 16 texels RGBA, raster order (y * 4 + x).
const TEX = new StaticArray<u8>(64);
// The four colours of the T, H and individual/differential palettes.
const PAINT = new StaticArray<i32>(12);

@inline function clamp255(v: i32): i32 {
    return v < 0 ? 0 : (v > 255 ? 255 : v);
}

function be32(data: Uint8Array, o: i32): u32 {
    return (<u32>data[o] << 24) | (<u32>data[o + 1] << 16) | (<u32>data[o + 2] << 8) | <u32>data[o + 3];
}

// The 3-bit field's two's complement value.
@inline function signed3(v: u32): i32 {
    const x = <i32>(v & 7);
    return x >= 4 ? x - 8 : x;
}

@inline function ext4(v: i32): i32 { return (v << 4) | v; }
@inline function ext5(v: i32): i32 { return (v << 3) | (v >> 2); }

// Writes texel (x, y) of a T or H block from PAINT[k].
function paintTexels(lo: u32): void {
    for (let x = 0; x < 4; x++) {
        for (let y = 0; y < 4; y++) {
            const n = x * 4 + y;
            const k = <i32>(((lo >> <u32>(16 + n)) & 1) << 1 | ((lo >> <u32>n) & 1));
            const t = (y * 4 + x) * 4;
            unchecked(TEX[t] = <u8>unchecked(PAINT[k * 3]));
            unchecked(TEX[t + 1] = <u8>unchecked(PAINT[k * 3 + 1]));
            unchecked(TEX[t + 2] = <u8>unchecked(PAINT[k * 3 + 2]));
            unchecked(TEX[t + 3] = 255);
        }
    }
}

function setPaint(k: i32, r: i32, g: i32, b: i32): void {
    unchecked(PAINT[k * 3] = clamp255(r));
    unchecked(PAINT[k * 3 + 1] = clamp255(g));
    unchecked(PAINT[k * 3 + 2] = clamp255(b));
}

// The colour block at data[off..off+8] into TEX (alpha 255).
function etc2Block(data: Uint8Array, off: i32): void {
    const hi = be32(data, off);
    const lo = be32(data, off + 4);
    const diff = (hi >> 1) & 1;
    if (diff != 0) {
        const r = <i32>((hi >> 27) & 31), dr = signed3(hi >> 24);
        const g = <i32>((hi >> 19) & 31), dg = signed3(hi >> 16);
        const b = <i32>((hi >> 11) & 31), db = signed3(hi >> 8);
        if (r + dr < 0 || r + dr > 31) {
            // T mode.
            const r1 = ext4(<i32>(((hi >> 27) & 3) << 2 | ((hi >> 24) & 3)));
            const g1 = ext4(<i32>((hi >> 20) & 15));
            const b1 = ext4(<i32>((hi >> 16) & 15));
            const r2 = ext4(<i32>((hi >> 12) & 15));
            const g2 = ext4(<i32>((hi >> 8) & 15));
            const b2 = ext4(<i32>((hi >> 4) & 15));
            const d = unchecked(ETC2_DISTANCES[<i32>(((hi >> 2) & 3) << 1 | (hi & 1))]);
            setPaint(0, r1, g1, b1);
            setPaint(1, r2 + d, g2 + d, b2 + d);
            setPaint(2, r2, g2, b2);
            setPaint(3, r2 - d, g2 - d, b2 - d);
            paintTexels(lo);
            return;
        }
        if (g + dg < 0 || g + dg > 31) {
            // H mode.
            const r1 = <i32>((hi >> 27) & 15);
            const g1 = <i32>(((hi >> 24) & 7) << 1 | ((hi >> 20) & 1));
            const b1 = <i32>(((hi >> 19) & 1) << 3 | ((hi >> 15) & 7));
            const r2 = <i32>((hi >> 11) & 15);
            const g2 = <i32>((hi >> 7) & 15);
            const b2 = <i32>((hi >> 3) & 15);
            const v1 = (r1 << 8) | (g1 << 4) | b1;
            const v2 = (r2 << 8) | (g2 << 4) | b2;
            const di = <i32>(((hi >> 2) & 1) << 2 | (hi & 1) << 1) | (v1 >= v2 ? 1 : 0);
            const d = unchecked(ETC2_DISTANCES[di]);
            setPaint(0, ext4(r1) + d, ext4(g1) + d, ext4(b1) + d);
            setPaint(1, ext4(r1) - d, ext4(g1) - d, ext4(b1) - d);
            setPaint(2, ext4(r2) + d, ext4(g2) + d, ext4(b2) + d);
            setPaint(3, ext4(r2) - d, ext4(g2) - d, ext4(b2) - d);
            paintTexels(lo);
            return;
        }
        if (b + db < 0 || b + db > 31) {
            planarBlock(hi, lo);
            return;
        }
        // Differential.
        setPaint(0, ext5(r), ext5(g), ext5(b));
        setPaint(1, ext5(r + dr), ext5(g + dg), ext5(b + db));
    } else {
        // Individual.
        setPaint(0, ext4(<i32>((hi >> 28) & 15)), ext4(<i32>((hi >> 20) & 15)), ext4(<i32>((hi >> 12) & 15)));
        setPaint(1, ext4(<i32>((hi >> 24) & 15)), ext4(<i32>((hi >> 16) & 15)), ext4(<i32>((hi >> 8) & 15)));
    }
    const t1 = <i32>((hi >> 5) & 7);
    const t2 = <i32>((hi >> 2) & 7);
    const flip = (hi & 1) != 0;
    for (let x = 0; x < 4; x++) {
        for (let y = 0; y < 4; y++) {
            const n = x * 4 + y;
            const k = <i32>(((lo >> <u32>(16 + n)) & 1) << 1 | ((lo >> <u32>n) & 1));
            const second = flip ? y >= 2 : x >= 2;
            const m = etc1Modifier(second ? t2 : t1, k);
            const p = second ? 3 : 0;
            const t = (y * 4 + x) * 4;
            unchecked(TEX[t] = <u8>clamp255(unchecked(PAINT[p]) + m));
            unchecked(TEX[t + 1] = <u8>clamp255(unchecked(PAINT[p + 1]) + m));
            unchecked(TEX[t + 2] = <u8>clamp255(unchecked(PAINT[p + 2]) + m));
            unchecked(TEX[t + 3] = 255);
        }
    }
}

function planarBlock(hi: u32, lo: u32): void {
    const ro = <i32>((hi >> 25) & 63);
    const go = <i32>(((hi >> 24) & 1) << 6 | ((hi >> 17) & 63));
    const bo = <i32>(((hi >> 16) & 1) << 5 | ((hi >> 11) & 3) << 3 | ((hi >> 7) & 7));
    const rh = <i32>(((hi >> 2) & 31) << 1 | (hi & 1));
    const gh = <i32>((lo >> 25) & 127);
    const bh = <i32>((lo >> 19) & 63);
    const rv = <i32>((lo >> 13) & 63);
    const gv = <i32>((lo >> 6) & 127);
    const bv = <i32>(lo & 63);
    planarTexels(ext6(ro), ext7(go), ext6(bo), ext6(rh), ext7(gh), ext6(bh), ext6(rv), ext7(gv), ext6(bv));
}

@inline function ext6(v: i32): i32 { return (v << 2) | (v >> 4); }
@inline function ext7(v: i32): i32 { return (v << 1) | (v >> 6); }

// The planar mode's texels from its three colours (8-bit, widened).
function planarTexels(ro: i32, go: i32, bo: i32, rh: i32, gh: i32, bh: i32, rv: i32, gv: i32, bv: i32): void {
    for (let y = 0; y < 4; y++) {
        for (let x = 0; x < 4; x++) {
            const t = (y * 4 + x) * 4;
            unchecked(TEX[t] = <u8>clamp255((x * (rh - ro) + y * (rv - ro) + 4 * ro + 2) >> 2));
            unchecked(TEX[t + 1] = <u8>clamp255((x * (gh - go) + y * (gv - go) + 4 * go + 2) >> 2));
            unchecked(TEX[t + 2] = <u8>clamp255((x * (bh - bo) + y * (bv - bo) + 4 * bo + 2) >> 2));
            unchecked(TEX[t + 3] = 255);
        }
    }
}

// The EAC alpha block at data[off..off+8] into TEX's alpha.
function eacBlock(data: Uint8Array, off: i32): void {
    const base = <i32>data[off];
    const mul = <i32>(data[off + 1] >> 4);
    const table = <i32>(data[off + 1] & 15);
    let bits: u64 = 0;
    for (let i = 2; i < 8; i++) bits = (bits << 8) | <u64>data[off + i];
    for (let x = 0; x < 4; x++) {
        for (let y = 0; y < 4; y++) {
            const n = x * 4 + y;
            const k = <i32>((bits >> <u64>(45 - n * 3)) & 7);
            const v = base + unchecked(EAC_MODIFIERS[table * 8 + k]) * mul;
            unchecked(TEX[(y * 4 + x) * 4 + 3] = <u8>clamp255(v));
        }
    }
}

// The value EAC index k gives with base, multiplier and table.
export function eacValue(base: i32, mul: i32, table: i32, k: i32): i32 {
    return clamp255(base + unchecked(EAC_MODIFIERS[(table & 15) * 8 + (k & 7)]) * mul);
}

function decodeBlocks(data: Uint8Array, w: u32, h: u32, rgba: bool): Image {
    const out = new Uint8Array(<i32>(w * h * 4));
    const bw = (w + 3) / 4;
    const bh = (h + 3) / 4;
    const bytes = rgba ? 16 : 8;
    let off = 0;
    for (let by: u32 = 0; by < bh; by++) {
        for (let bx: u32 = 0; bx < bw; bx++) {
            if (off + bytes <= data.length) {
                if (rgba) {
                    etc2Block(data, off + 8);
                    eacBlock(data, off);
                } else {
                    etc2Block(data, off);
                }
            } else {
                for (let i = 0; i < 64; i++) unchecked(TEX[i] = 0);
            }
            for (let y: u32 = 0; y < 4; y++) {
                const py = by * 4 + y;
                if (py >= h) break;
                for (let x: u32 = 0; x < 4; x++) {
                    const px = bx * 4 + x;
                    if (px >= w) break;
                    const o = <i32>((py * w + px) * 4);
                    const t = <i32>((y * 4 + x) * 4);
                    out[o] = unchecked(TEX[t]);
                    out[o + 1] = unchecked(TEX[t + 1]);
                    out[o + 2] = unchecked(TEX[t + 2]);
                    out[o + 3] = unchecked(TEX[t + 3]);
                }
            }
            off += bytes;
        }
    }
    return new Image(w, h, out);
}

export function decodeEtc2Rgb(data: Uint8Array, w: u32, h: u32): Image {
    return decodeBlocks(data, w, h, false);
}

export function decodeEtc2Rgba(data: Uint8Array, w: u32, h: u32): Image {
    return decodeBlocks(data, w, h, true);
}
