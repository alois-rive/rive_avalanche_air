// Milestone 26, package WP2: an ASTC LDR decoder for any block of the
// 4 x 4, 6 x 6 and 8 x 8 footprints (every block mode, 1 to 4 partitions,
// dual plane, every LDR endpoint mode, void-extent blocks), to RGBA8 as the
// Khronos Data Format specification decodes them (sRGB-agnostic: the
// UNORM8 decode). Part of the run time; any bytes decode without
// a trap (an illegal encoding decodes to the error colour, magenta).
//
// The decode follows the specification's chapter "ASTC" (Khronos Data
// Format Specification 1.3, section 23) step by step: the block mode, the
// partition count and the colour endpoint modes; the weights, an integer
// sequence (ISE) read bit-reversed from the top of the block, unquantised
// to 0..64 and infilled from their grid onto the texels; the endpoints, an
// ISE from bit 17 (one partition) or 29, unquantised to 0..255 and decoded
// per endpoint mode; then per texel its partition (the specification's
// hash), and each channel interpolated between the endpoints expanded to
// 16 bits (v * 257: the linear LDR profile) and kept as its top 8 bits
// (decode_unorm8). A block with an HDR endpoint mode, or a void extent
// marked HDR, is an error in the LDR profile; so are reserved block modes,
// weight grids larger than the block, more than 64 weights, weights in
// fewer than 24 or more than 96 bits, four partitions with two planes,
// more than 18 colour values, and too few bits for them. An error block is
// magenta (255, 0, 255, 255) whole; a partition with an HDR endpoint mode
// is magenta alone, as the reference decoder (Arm's astcenc 4.7) draws
// both. editor/program/tests/texture/astc_decode_test.as proves the
// decoder byte for byte against astcenc's on its fixtures and on random
// blocks.
//
// The work needs no heap past the output image: the block's words, the
// decoded values and the infilled weights live in arrays made once.

import { Image } from "../render/image";

// The 21 quantisation ranges of the integer sequence encoding, by index:
// how many levels, and whether a value carries a trit or a quint above its
// `bits` low bits.
export const ISE_LEVELS: StaticArray<i32> = [2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64, 80, 96, 128, 160, 192, 256];
export const ISE_BITS: StaticArray<i32> = [1, 0, 2, 0, 1, 3, 1, 2, 4, 2, 3, 5, 3, 4, 6, 4, 5, 7, 5, 6, 8];
export const ISE_TRITS: StaticArray<i32> = [0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0];
export const ISE_QUINTS: StaticArray<i32> = [0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0];
// The colour values' smallest range (6 levels): a block whose colour bits
// do not hold its values at 6 levels is an error.
export const COLOR_MIN_QUANT: i32 = 4;
export const COLOR_MAX_QUANT: i32 = 20;
export const WEIGHT_MAX_QUANT: i32 = 11;

// The bits `count` values take at range `quant`.
export function iseBitCount(count: i32, quant: i32): i32 {
    let n = count * ISE_BITS[quant];
    if (ISE_TRITS[quant] != 0) n += (8 * count + 4) / 5;
    if (ISE_QUINTS[quant] != 0) n += (7 * count + 2) / 3;
    return n;
}

// The block mode of a 2D block, decoded (decodeBlockMode).
export class BlockMode {
    gridW: i32 = 0;
    gridH: i32 = 0;
    dualPlane: bool = false;
    // The weights' range (0..WEIGHT_MAX_QUANT).
    weightQuant: i32 = 0;
    // Weights (both planes) and their bits.
    weightCount: i32 = 0;
    weightBits: i32 = 0;
}

// Decodes the 11-bit block mode `m` for a bw x bh block into `out`; false
// for a reserved mode or one this footprint cannot hold (a grid larger
// than the block, more than 64 weights, weights outside 24..96 bits). A
// void-extent mode is not a block mode here (the caller tests it first).
export function decodeBlockMode(m: i32, bw: i32, bh: i32, out: BlockMode): bool {
    let r = (m >> 4) & 1;
    let h = (m >> 9) & 1;
    let d = (m >> 10) & 1;
    const a = (m >> 5) & 3;
    let gw = 0;
    let gh = 0;
    if ((m & 3) != 0) {
        r |= (m & 3) << 1;
        let b = (m >> 7) & 3;
        switch ((m >> 2) & 3) {
            case 0: gw = b + 4; gh = a + 2; break;
            case 1: gw = b + 8; gh = a + 2; break;
            case 2: gw = a + 2; gh = b + 8; break;
            default: {
                b &= 1;
                if ((m & 0x100) != 0) {
                    gw = b + 2;
                    gh = a + 2;
                } else {
                    gw = a + 2;
                    gh = b + 6;
                }
            }
        }
    } else {
        r |= ((m >> 2) & 3) << 1;
        if (((m >> 2) & 3) == 0) return false;
        const b = (m >> 9) & 3;
        switch ((m >> 7) & 3) {
            case 0: gw = 12; gh = a + 2; break;
            case 1: gw = a + 2; gh = 12; break;
            case 2: {
                gw = a + 6;
                gh = b + 6;
                d = 0;
                h = 0;
                break;
            }
            default: {
                const s = (m >> 5) & 3;
                if (s == 0) {
                    gw = 6;
                    gh = 10;
                } else if (s == 1) {
                    gw = 10;
                    gh = 6;
                } else {
                    return false;
                }
            }
        }
    }
    if (gw > bw || gh > bh) return false;
    const quant = (r - 2) + 6 * h;
    if (quant < 0 || quant > WEIGHT_MAX_QUANT) return false;
    const count = gw * gh * (d + 1);
    if (count > 64) return false;
    const wbits = iseBitCount(count, quant);
    if (wbits < 24 || wbits > 96) return false;
    out.gridW = gw;
    out.gridH = gh;
    out.dualPlane = d != 0;
    out.weightQuant = quant;
    out.weightCount = count;
    out.weightBits = wbits;
    return true;
}

// --- bits --------------------------------------------------------------------

// `count` (0..32) bits of the 128-bit block `w` (four little-endian words)
// from bit `start`; bits past bit 127 read as zero.
function bitsOf(w: StaticArray<u32>, start: i32, count: i32): u32 {
    if (count <= 0 || start >= 128 || start < 0) return 0;
    const word = start >> 5;
    const off = <u64>(start & 31);
    let v: u64 = <u64>unchecked(w[word]);
    if (word + 1 < 4) v |= <u64>unchecked(w[word + 1]) << 32;
    const mask: u64 = count >= 32 ? 0xFFFFFFFF : ((<u64>1 << <u64>count) - 1);
    return <u32>((v >> off) & mask);
}

function bitrev32(x: u32): u32 {
    x = ((x >> 1) & 0x55555555) | ((x & 0x55555555) << 1);
    x = ((x >> 2) & 0x33333333) | ((x & 0x33333333) << 2);
    x = ((x >> 4) & 0x0F0F0F0F) | ((x & 0x0F0F0F0F) << 4);
    x = ((x >> 8) & 0x00FF00FF) | ((x & 0x00FF00FF) << 8);
    return (x >> 16) | (x << 16);
}

// --- integer sequence --------------------------------------------------------

// The five trits a packed byte holds (the specification's decoding,
// written out), into t[0..5].
export function unpackTrits(tv: u32, t: StaticArray<i32>): void {
    let c: u32;
    let t4: u32;
    let t3: u32;
    if (((tv >> 2) & 7) == 7) {
        c = (((tv >> 5) & 7) << 2) | (tv & 3);
        t4 = 2;
        t3 = 2;
    } else {
        c = tv & 0x1F;
        if (((tv >> 5) & 3) == 3) {
            t4 = 2;
            t3 = (tv >> 7) & 1;
        } else {
            t4 = (tv >> 7) & 1;
            t3 = (tv >> 5) & 3;
        }
    }
    let t2: u32;
    let t1: u32;
    let t0: u32;
    if ((c & 3) == 3) {
        t2 = 2;
        t1 = (c >> 4) & 1;
        const c3 = (c >> 3) & 1;
        const c2 = (c >> 2) & 1;
        t0 = (c3 << 1) | (c2 & (c3 ^ 1));
    } else if (((c >> 2) & 3) == 3) {
        t2 = 2;
        t1 = 2;
        t0 = c & 3;
    } else {
        t2 = (c >> 4) & 1;
        t1 = (c >> 2) & 3;
        const c1 = (c >> 1) & 1;
        const c0 = c & 1;
        t0 = (c1 << 1) | (c0 & (c1 ^ 1));
    }
    unchecked(t[0] = <i32>t0);
    unchecked(t[1] = <i32>t1);
    unchecked(t[2] = <i32>t2);
    unchecked(t[3] = <i32>t3);
    unchecked(t[4] = <i32>t4);
}

// The three quints a packed 7 bits hold, into q[0..3].
export function unpackQuints(qv: u32, q: StaticArray<i32>): void {
    let q0: u32;
    let q1: u32;
    let q2: u32;
    if (((qv >> 1) & 3) == 3 && ((qv >> 5) & 3) == 0) {
        const b0 = qv & 1;
        const nb0 = b0 ^ 1;
        q2 = (b0 << 2) | ((((qv >> 4) & 1) & nb0) << 1) | (((qv >> 3) & 1) & nb0);
        q1 = 4;
        q0 = 4;
    } else {
        let c: u32;
        if (((qv >> 1) & 3) == 3) {
            q2 = 4;
            c = (((qv >> 3) & 3) << 3) | ((~(qv >> 5) & 3) << 1) | (qv & 1);
        } else {
            q2 = (qv >> 5) & 3;
            c = qv & 0x1F;
        }
        if ((c & 7) == 5) {
            q1 = 4;
            q0 = (c >> 3) & 3;
        } else {
            q1 = (c >> 3) & 3;
            q0 = c & 7;
        }
    }
    unchecked(q[0] = <i32>q0);
    unchecked(q[1] = <i32>q1);
    unchecked(q[2] = <i32>q2);
}

const TRIT_CHUNK_BITS: StaticArray<i32> = [2, 2, 1, 2, 1];
const TRIT_CHUNK_SHIFT: StaticArray<i32> = [0, 2, 4, 5, 7];
const QUINT_CHUNK_BITS: StaticArray<i32> = [3, 2, 2];
const QUINT_CHUNK_SHIFT: StaticArray<i32> = [0, 3, 5];

const packs = new StaticArray<u32>(22);
const unpacked = new StaticArray<i32>(5);

// Decodes `count` values of range `quant` from bit `start` of `w` into
// out[0..count): each value's low bits, then its share of its group's
// packed trits or quints, in the order the specification interleaves them
// (a short last group's missing shares are zero).
export function iseDecode(w: StaticArray<u32>, start: i32, count: i32, quant: i32, out: StaticArray<i32>): void {
    const nb = ISE_BITS[quant];
    const trits = ISE_TRITS[quant] != 0;
    const quints = ISE_QUINTS[quant] != 0;
    for (let i = 0; i < 22; i++) unchecked(packs[i] = 0);
    let pos = start;
    for (let i = 0; i < count; i++) {
        unchecked(out[i] = <i32>bitsOf(w, pos, nb));
        pos += nb;
        if (trits) {
            const k = i % 5;
            const n = TRIT_CHUNK_BITS[k];
            unchecked(packs[i / 5] |= bitsOf(w, pos, n) << <u32>TRIT_CHUNK_SHIFT[k]);
            pos += n;
        } else if (quints) {
            const k = i % 3;
            const n = QUINT_CHUNK_BITS[k];
            unchecked(packs[i / 3] |= bitsOf(w, pos, n) << <u32>QUINT_CHUNK_SHIFT[k]);
            pos += n;
        }
    }
    if (trits) {
        for (let g = 0; g * 5 < count; g++) {
            unpackTrits(unchecked(packs[g]), unpacked);
            for (let k = 0; k < 5 && g * 5 + k < count; k++) {
                unchecked(out[g * 5 + k] |= unchecked(unpacked[k]) << nb);
            }
        }
    } else if (quints) {
        for (let g = 0; g * 3 < count; g++) {
            unpackQuints(unchecked(packs[g]), unpacked);
            for (let k = 0; k < 3 && g * 3 + k < count; k++) {
                unchecked(out[g * 3 + k] |= unchecked(unpacked[k]) << nb);
            }
        }
    }
}

// --- unquantisation ----------------------------------------------------------

// `v` of `n` bits replicated to fill `to` bits (bit replication).
function replicate(v: i32, n: i32, to: i32): i32 {
    if (n <= 0) return 0;
    let r = 0;
    let shift = to;
    while (shift > 0) {
        shift -= n;
        r |= shift >= 0 ? v << shift : v >> -shift;
    }
    return r & ((1 << to) - 1);
}

// The colour value `v` of range `quant` unquantised to 0..255 (the
// specification's table of B and C per range).
export function unquantColor(v: i32, quant: i32): i32 {
    const nb = ISE_BITS[quant];
    if (ISE_TRITS[quant] == 0 && ISE_QUINTS[quant] == 0) return replicate(v, nb, 8);
    const m = v & ((1 << nb) - 1);
    const dd = v >> nb;
    const a = (m & 1) != 0 ? 0x1FF : 0;
    const b1 = (m >> 1) & 1;
    const b2 = (m >> 2) & 1;
    const b3 = (m >> 3) & 1;
    const b4 = (m >> 4) & 1;
    const b5 = (m >> 5) & 1;
    let bb = 0;
    let c = 0;
    if (ISE_TRITS[quant] != 0) {
        switch (nb) {
            case 1: c = 204; break;
            case 2: c = 93; bb = (b1 << 8) | (b1 << 4) | (b1 << 2) | (b1 << 1); break;
            case 3: c = 44; bb = (b2 << 8) | (b1 << 7) | (b2 << 3) | (b1 << 2) | (b2 << 1) | b1; break;
            case 4: c = 22; bb = (b3 << 8) | (b2 << 7) | (b1 << 6) | (b3 << 2) | (b2 << 1) | b1; break;
            case 5: c = 11; bb = (b4 << 8) | (b3 << 7) | (b2 << 6) | (b1 << 5) | (b4 << 1) | b3; break;
            default: c = 5; bb = (b5 << 8) | (b4 << 7) | (b3 << 6) | (b2 << 5) | (b1 << 4) | b5; break;
        }
    } else {
        switch (nb) {
            case 1: c = 113; break;
            case 2: c = 54; bb = (b1 << 8) | (b1 << 3) | (b1 << 2); break;
            case 3: c = 26; bb = (b2 << 8) | (b1 << 7) | (b2 << 2) | (b1 << 1) | b2; break;
            case 4: c = 13; bb = (b3 << 8) | (b2 << 7) | (b1 << 6) | (b3 << 1) | b2; break;
            default: c = 6; bb = (b4 << 8) | (b3 << 7) | (b2 << 6) | (b1 << 5) | b4; break;
        }
    }
    let t = dd * c + bb;
    t ^= a;
    return (a & 0x80) | (t >> 2);
}

// The weight value `v` of range `quant` (0..11) unquantised to 0..64.
export function unquantWeight(v: i32, quant: i32): i32 {
    const nb = ISE_BITS[quant];
    let t: i32;
    if (ISE_TRITS[quant] == 0 && ISE_QUINTS[quant] == 0) {
        t = replicate(v, nb, 6);
    } else if (nb == 0) {
        // 3 levels: 0, 32, 63; 5 levels: 0, 16, 32, 47, 63 (before the
        // step past 32 below).
        if (ISE_TRITS[quant] != 0) t = v == 0 ? 0 : v == 1 ? 32 : 63;
        else t = v == 0 ? 0 : v == 1 ? 16 : v == 2 ? 32 : v == 3 ? 47 : 63;
    } else {
        const m = v & ((1 << nb) - 1);
        const dd = v >> nb;
        const a = (m & 1) != 0 ? 0x7F : 0;
        const b1 = (m >> 1) & 1;
        const b2 = (m >> 2) & 1;
        let bb = 0;
        let c = 0;
        if (ISE_TRITS[quant] != 0) {
            if (nb == 1) c = 50;
            else if (nb == 2) { c = 23; bb = (b1 << 6) | (b1 << 2) | b1; }
            else { c = 11; bb = (b2 << 6) | (b1 << 5) | (b2 << 1) | b1; }
        } else {
            if (nb == 1) c = 28;
            else { c = 13; bb = (b1 << 6) | (b1 << 1); }
        }
        t = dd * c + bb;
        t ^= a;
        t = (a & 0x20) | (t >> 2);
    }
    if (t > 32) t += 1;
    return t;
}

// --- partitions --------------------------------------------------------------

function hash52(p: u32): u32 {
    p ^= p >> 15;
    p -= p << 17;
    p += p << 7;
    p += p << 4;
    p ^= p >> 5;
    p += p << 16;
    p ^= p >> 7;
    p ^= p >> 3;
    p ^= p << 6;
    p ^= p >> 17;
    return p;
}

// The partition hash of one partition index, worked out once per block
// (partitionSetup) and then read per texel (partitionAt): the eight seeds
// shifted, the four offsets, the partition count, whether texel
// coordinates are doubled (a block of fewer than 31 texels).
const hashSeeds = new StaticArray<i32>(8);
const hashOffsets = new StaticArray<i32>(4);
let hashCount = 1;
let hashSmall = false;

export function partitionSetup(seed: i32, count: i32, texels: i32): void {
    hashCount = count;
    hashSmall = texels < 31;
    const s = seed + (count - 1) * 1024;
    const rnum = hash52(<u32>s);
    let sh1: i32;
    let sh2: i32;
    if ((s & 1) != 0) {
        sh1 = (s & 2) != 0 ? 4 : 5;
        sh2 = count == 3 ? 6 : 5;
    } else {
        sh1 = count == 3 ? 6 : 5;
        sh2 = (s & 2) != 0 ? 4 : 5;
    }
    for (let k = 0; k < 8; k++) {
        const v = <i32>((rnum >> <u32>(k * 4)) & 0xF);
        unchecked(hashSeeds[k] = (v * v) >> ((k & 1) == 0 ? sh1 : sh2));
    }
    // (z is 0: the seeds 9 to 12 that multiply it drop out)
    unchecked(hashOffsets[0] = <i32>(rnum >> 14));
    unchecked(hashOffsets[1] = <i32>(rnum >> 10));
    unchecked(hashOffsets[2] = <i32>(rnum >> 6));
    unchecked(hashOffsets[3] = <i32>(rnum >> 2));
}

export function partitionAt(x: i32, y: i32): i32 {
    if (hashCount <= 1) return 0;
    if (hashSmall) {
        x <<= 1;
        y <<= 1;
    }
    const a = (unchecked(hashSeeds[0]) * x + unchecked(hashSeeds[1]) * y + unchecked(hashOffsets[0])) & 0x3F;
    const b = (unchecked(hashSeeds[2]) * x + unchecked(hashSeeds[3]) * y + unchecked(hashOffsets[1])) & 0x3F;
    const c = hashCount < 3 ? 0 : (unchecked(hashSeeds[4]) * x + unchecked(hashSeeds[5]) * y + unchecked(hashOffsets[2])) & 0x3F;
    const d = hashCount < 4 ? 0 : (unchecked(hashSeeds[6]) * x + unchecked(hashSeeds[7]) * y + unchecked(hashOffsets[3])) & 0x3F;
    if (a >= b && a >= c && a >= d) return 0;
    if (b >= c && b >= d) return 1;
    if (c >= d) return 2;
    return 3;
}

// The partition (0..count-1) of texel (x, y) of a block of `texels`
// texels, for partition index `seed` (the specification's
// select_partition, 2D: z = 0; the squares of the 4-bit seeds fit a byte,
// so the specification's u8 arithmetic needs no wrapping here).
export function selectPartition(seed: i32, x: i32, y: i32, count: i32, texels: i32): i32 {
    if (count <= 1) return 0;
    partitionSetup(seed, count, texels);
    return partitionAt(x, y);
}

// --- endpoints ---------------------------------------------------------------

function clamp255(v: i32): i32 {
    return v < 0 ? 0 : v > 255 ? 255 : v;
}

// Endpoints of one partition, RGBA, 0..255 each: e[0..4) and e[4..8).
// Returns false for an HDR mode (the partition is then the error colour).
function decodeEndpoints(mode: i32, v: StaticArray<i32>, o: i32, e: StaticArray<i32>): bool {
    let v0 = unchecked(v[o]);
    let v1 = unchecked(v[o + 1]);
    switch (mode) {
        case 0: {
            setE(e, v0, v0, v0, 255, v1, v1, v1, 255);
            return true;
        }
        case 1: {
            const l0 = (v0 >> 2) | (v1 & 0xC0);
            const l1 = min<i32>(l0 + (v1 & 0x3F), 255);
            setE(e, l0, l0, l0, 255, l1, l1, l1, 255);
            return true;
        }
        case 4: {
            const v2 = unchecked(v[o + 2]);
            const v3 = unchecked(v[o + 3]);
            setE(e, v0, v0, v0, v2, v1, v1, v1, v3);
            return true;
        }
        case 5: {
            let v2 = unchecked(v[o + 2]);
            let v3 = unchecked(v[o + 3]);
            // bit_transfer_signed(v1, v0) and (v3, v2)
            v0 = (v0 >> 1) | (v1 & 0x80);
            v1 = (v1 >> 1) & 0x3F;
            if ((v1 & 0x20) != 0) v1 -= 0x40;
            v2 = (v2 >> 1) | (v3 & 0x80);
            v3 = (v3 >> 1) & 0x3F;
            if ((v3 & 0x20) != 0) v3 -= 0x40;
            const l1 = clamp255(v0 + v1);
            const a1 = clamp255(v2 + v3);
            setE(e, v0, v0, v0, v2, l1, l1, l1, a1);
            return true;
        }
        case 6:
        case 10: {
            const v2 = unchecked(v[o + 2]);
            const v3 = unchecked(v[o + 3]);
            const a0 = mode == 10 ? unchecked(v[o + 4]) : 255;
            const a1 = mode == 10 ? unchecked(v[o + 5]) : 255;
            setE(e, (v0 * v3) >> 8, (v1 * v3) >> 8, (v2 * v3) >> 8, a0, v0, v1, v2, a1);
            return true;
        }
        case 8:
        case 12: {
            const v2 = unchecked(v[o + 2]);
            const v3 = unchecked(v[o + 3]);
            const v4 = unchecked(v[o + 4]);
            const v5 = unchecked(v[o + 5]);
            const v6 = mode == 12 ? unchecked(v[o + 6]) : 255;
            const v7 = mode == 12 ? unchecked(v[o + 7]) : 255;
            const s0 = v0 + v2 + v4;
            const s1 = v1 + v3 + v5;
            if (s1 >= s0) {
                setE(e, v0, v2, v4, v6, v1, v3, v5, v7);
            } else {
                // blue_contract of each, swapped
                setE(e, (v1 + v5) >> 1, (v3 + v5) >> 1, v5, v7, (v0 + v4) >> 1, (v2 + v4) >> 1, v4, v6);
            }
            return true;
        }
        case 9:
        case 13: {
            let v2 = unchecked(v[o + 2]);
            let v3 = unchecked(v[o + 3]);
            let v4 = unchecked(v[o + 4]);
            let v5 = unchecked(v[o + 5]);
            let v6 = mode == 13 ? unchecked(v[o + 6]) : 255;
            let v7 = mode == 13 ? unchecked(v[o + 7]) : 0;
            v0 = (v0 >> 1) | (v1 & 0x80);
            v1 = (v1 >> 1) & 0x3F;
            if ((v1 & 0x20) != 0) v1 -= 0x40;
            v2 = (v2 >> 1) | (v3 & 0x80);
            v3 = (v3 >> 1) & 0x3F;
            if ((v3 & 0x20) != 0) v3 -= 0x40;
            v4 = (v4 >> 1) | (v5 & 0x80);
            v5 = (v5 >> 1) & 0x3F;
            if ((v5 & 0x20) != 0) v5 -= 0x40;
            if (mode == 13) {
                v6 = (v6 >> 1) | (v7 & 0x80);
                v7 = (v7 >> 1) & 0x3F;
                if ((v7 & 0x20) != 0) v7 -= 0x40;
            }
            const a0 = v6;
            const a1 = mode == 13 ? v6 + v7 : 255;
            if (v1 + v3 + v5 >= 0) {
                setE(e, clamp255(v0), clamp255(v2), clamp255(v4), clamp255(a0),
                    clamp255(v0 + v1), clamp255(v2 + v3), clamp255(v4 + v5), clamp255(a1));
            } else {
                // blue_contract(v0 + v1, ...) and blue_contract(v0, ...)
                const r0 = v0 + v1;
                const g0 = v2 + v3;
                const b0 = v4 + v5;
                setE(e, clamp255((r0 + b0) >> 1), clamp255((g0 + b0) >> 1), clamp255(b0), clamp255(a1),
                    clamp255((v0 + v4) >> 1), clamp255((v2 + v4) >> 1), clamp255(v4), clamp255(a0));
            }
            return true;
        }
        default:
            // 2, 3, 7, 11, 14, 15: HDR modes, an error in the LDR profile.
            return false;
    }
}

function setE(e: StaticArray<i32>, r0: i32, g0: i32, b0: i32, a0: i32, r1: i32, g1: i32, b1: i32, a1: i32): void {
    unchecked(e[0] = r0);
    unchecked(e[1] = g0);
    unchecked(e[2] = b0);
    unchecked(e[3] = a0);
    unchecked(e[4] = r1);
    unchecked(e[5] = g1);
    unchecked(e[6] = b1);
    unchecked(e[7] = a1);
}

// --- one block -----------------------------------------------------------------

const words = new StaticArray<u32>(4);
const reversed = new StaticArray<u32>(4);
const weightVals = new StaticArray<i32>(64);
const colorVals = new StaticArray<i32>(32);
const gridW1 = new StaticArray<i32>(64);
const gridW2 = new StaticArray<i32>(64);
const texW1 = new StaticArray<i32>(144);
const texW2 = new StaticArray<i32>(144);
const cems = new StaticArray<i32>(4);
const ends = new StaticArray<i32>(32);
const partOk = new StaticArray<bool>(4);
const oneEnd = new StaticArray<i32>(8);
const mode = new BlockMode();

// Decodes the 16 bytes at data[off..off + 16) as a bw x bh block into
// `out` (bw * bh RGBA texels, row by row). Never traps.
export function decodeAstcBlock(data: Uint8Array, off: i32, bw: i32, bh: i32, out: StaticArray<u8>): void {
    for (let i = 0; i < 4; i++) {
        const o = off + i * 4;
        unchecked(words[i] = <u32>data[o] | (<u32>data[o + 1] << 8) | (<u32>data[o + 2] << 16) | (<u32>data[o + 3] << 24));
    }
    decodeWords(bw, bh, out);
}

function fillError(n: i32, out: StaticArray<u8>): void {
    for (let i = 0; i < n; i++) {
        unchecked(out[i * 4] = 255);
        unchecked(out[i * 4 + 1] = 0);
        unchecked(out[i * 4 + 2] = 255);
        unchecked(out[i * 4 + 3] = 255);
    }
}

function decodeWords(bw: i32, bh: i32, out: StaticArray<u8>): void {
    const texels = bw * bh;
    const bm = <i32>bitsOf(words, 0, 11);
    // Void extent: one colour for the whole block.
    if ((bm & 0x1FF) == 0x1FC) {
        if ((bm & 0x200) != 0 || bitsOf(words, 10, 2) != 3) {
            fillError(texels, out);
            return;
        }
        const ls = <i32>bitsOf(words, 12, 13);
        const hs = <i32>bitsOf(words, 25, 13);
        const lt = <i32>bitsOf(words, 38, 13);
        const ht = <i32>bitsOf(words, 51, 13);
        const allOnes = ls == 0x1FFF && hs == 0x1FFF && lt == 0x1FFF && ht == 0x1FFF;
        if (!allOnes && (ls >= hs || lt >= ht)) {
            fillError(texels, out);
            return;
        }
        const r = <u8>(bitsOf(words, 64, 16) >> 8);
        const g = <u8>(bitsOf(words, 80, 16) >> 8);
        const b = <u8>(bitsOf(words, 96, 16) >> 8);
        const a = <u8>(bitsOf(words, 112, 16) >> 8);
        for (let i = 0; i < texels; i++) {
            unchecked(out[i * 4] = r);
            unchecked(out[i * 4 + 1] = g);
            unchecked(out[i * 4 + 2] = b);
            unchecked(out[i * 4 + 3] = a);
        }
        return;
    }
    if (!decodeBlockMode(bm, bw, bh, mode)) {
        fillError(texels, out);
        return;
    }
    const parts = <i32>bitsOf(words, 11, 2) + 1;
    if (parts == 4 && mode.dualPlane) {
        fillError(texels, out);
        return;
    }
    // The weights, from the top of the block down.
    for (let i = 0; i < 4; i++) unchecked(reversed[i] = bitrev32(unchecked(words[3 - i])));
    iseDecode(reversed, 0, mode.weightCount, mode.weightQuant, weightVals);
    let below = 128 - mode.weightBits;
    // The endpoint modes.
    let colorStart = 17;
    let seed = 0;
    if (parts == 1) {
        unchecked(cems[0] = <i32>bitsOf(words, 13, 4));
    } else {
        seed = <i32>bitsOf(words, 13, 10);
        colorStart = 29;
        let enc = <i32>bitsOf(words, 23, 6);
        if ((enc & 3) == 0) {
            const m = (enc >> 2) & 0xF;
            for (let p = 0; p < parts; p++) unchecked(cems[p] = m);
        } else {
            const high = 3 * parts - 4;
            below -= high;
            enc |= <i32>bitsOf(words, below, high) << 6;
            const base = (enc & 3) - 1;
            let pos = 2;
            for (let p = 0; p < parts; p++) {
                unchecked(cems[p] = (((enc >> pos) & 1) + base) << 2);
                pos++;
            }
            for (let p = 0; p < parts; p++) {
                unchecked(cems[p] |= (enc >> pos) & 3);
                pos += 2;
            }
        }
    }
    let ccs = -1;
    if (mode.dualPlane) {
        below -= 2;
        ccs = <i32>bitsOf(words, below, 2);
    }
    let values = 0;
    for (let p = 0; p < parts; p++) values += ((unchecked(cems[p]) >> 2) + 1) * 2;
    if (values > 18) {
        fillError(texels, out);
        return;
    }
    const colorBits = below - colorStart;
    // The finest colour range whose values fit in the bits left.
    let cq = -1;
    for (let q = COLOR_MAX_QUANT; q >= COLOR_MIN_QUANT; q--) {
        if (iseBitCount(values, q) <= colorBits) {
            cq = q;
            break;
        }
    }
    if (cq < 0) {
        fillError(texels, out);
        return;
    }
    iseDecode(words, colorStart, values, cq, colorVals);
    for (let i = 0; i < values; i++) unchecked(colorVals[i] = unquantColor(unchecked(colorVals[i]), cq));
    let vo = 0;
    for (let p = 0; p < parts; p++) {
        const ok = decodeEndpoints(unchecked(cems[p]), colorVals, vo, oneEnd);
        unchecked(partOk[p] = ok);
        for (let k = 0; k < 8; k++) unchecked(ends[p * 8 + k] = unchecked(oneEnd[k]));
        vo += ((unchecked(cems[p]) >> 2) + 1) * 2;
    }
    // Weights unquantised onto the grid, then infilled onto the texels.
    const gw = mode.gridW;
    const gh = mode.gridH;
    const grid = gw * gh;
    const wq = mode.weightQuant;
    if (mode.dualPlane) {
        for (let i = 0; i < grid; i++) {
            unchecked(gridW1[i] = unquantWeight(unchecked(weightVals[i * 2]), wq));
            unchecked(gridW2[i] = unquantWeight(unchecked(weightVals[i * 2 + 1]), wq));
        }
    } else {
        for (let i = 0; i < grid; i++) unchecked(gridW1[i] = unquantWeight(unchecked(weightVals[i]), wq));
    }
    infill(gridW1, gw, gh, bw, bh, texW1);
    if (mode.dualPlane) infill(gridW2, gw, gh, bw, bh, texW2);
    if (parts > 1) partitionSetup(seed, parts, texels);
    for (let y = 0; y < bh; y++) {
        for (let x = 0; x < bw; x++) {
            const t = y * bw + x;
            const p = parts > 1 ? partitionAt(x, y) : 0;
            const o = t * 4;
            if (!unchecked(partOk[p])) {
                unchecked(out[o] = 255);
                unchecked(out[o + 1] = 0);
                unchecked(out[o + 2] = 255);
                unchecked(out[o + 3] = 255);
                continue;
            }
            const w1 = unchecked(texW1[t]);
            const w2 = mode.dualPlane ? unchecked(texW2[t]) : w1;
            for (let c = 0; c < 4; c++) {
                const w = c == ccs ? w2 : w1;
                const c0 = unchecked(ends[p * 8 + c]) * 257;
                const c1 = unchecked(ends[p * 8 + 4 + c]) * 257;
                const v = (c0 * (64 - w) + c1 * w + 32) >> 6;
                unchecked(out[o + c] = <u8>(v >> 8));
            }
        }
    }
}

// The grid's weights (gw x gh, 0..64) bilinearly infilled onto the bw x bh
// texels, as the specification's integer infill does.
export function infill(g: StaticArray<i32>, gw: i32, gh: i32, bw: i32, bh: i32, out: StaticArray<i32>): void {
    const ds = (1024 + (bw >> 1)) / (bw - 1);
    const dt = (1024 + (bh >> 1)) / (bh - 1);
    for (let t = 0; t < bh; t++) {
        for (let s = 0; s < bw; s++) {
            const cs = ds * s;
            const ct = dt * t;
            const gs = (cs * (gw - 1) + 32) >> 6;
            const gt = (ct * (gh - 1) + 32) >> 6;
            const js = gs >> 4;
            const fs = gs & 0xF;
            const jt = gt >> 4;
            const ft = gt & 0xF;
            const w11 = (fs * ft + 8) >> 4;
            const w10 = ft - w11;
            const w01 = fs - w11;
            const w00 = 16 - fs - ft + w11;
            const v0 = js + jt * gw;
            const p00 = unchecked(g[v0]);
            const p01 = w01 != 0 || w11 != 0 ? unchecked(g[min<i32>(v0 + 1, gw * gh - 1)]) : 0;
            const p10 = w10 != 0 || w11 != 0 ? unchecked(g[min<i32>(v0 + gw, gw * gh - 1)]) : 0;
            const p11 = w11 != 0 ? unchecked(g[min<i32>(v0 + gw + 1, gw * gh - 1)]) : 0;
            unchecked(out[t * bw + s] = (p00 * w00 + p01 * w01 + p10 * w10 + p11 * w11 + 8) >> 4);
        }
    }
}

const blockTexels = new StaticArray<u8>(8 * 8 * 4);

// A w x h level of bw x bh blocks (4 x 4, 6 x 6 or 8 x 8), decoded to RGBA8.
// `data` holds ceil(w / bw) * ceil(h / bh) blocks of 16 bytes, row by row
// (decode.as checks the length; a short `data` decodes its missing blocks
// as errors rather than trapping). Another footprint decodes as errors.
export function decodeAstc(data: Uint8Array, w: u32, h: u32, bw: u32, bh: u32): Image {
    const img = new Image(w, h, new Uint8Array(<i32>(w * h * 4)));
    const fw = <i32>bw;
    const fh = <i32>bh;
    const ok = (fw == 4 || fw == 6 || fw == 8) && fh == fw;
    if (w == 0 || h == 0) return img;
    const cols = ok ? (<i32>w + fw - 1) / fw : 0;
    const rows = ok ? (<i32>h + fh - 1) / fh : 0;
    const pix = img.data;
    const iw = <i32>w;
    const ih = <i32>h;
    if (!ok) {
        for (let i = 0; i < iw * ih; i++) {
            pix[i * 4] = 255;
            pix[i * 4 + 1] = 0;
            pix[i * 4 + 2] = 255;
            pix[i * 4 + 3] = 255;
        }
        return img;
    }
    for (let by = 0; by < rows; by++) {
        for (let bx = 0; bx < cols; bx++) {
            const off = (by * cols + bx) * 16;
            if (off + 16 <= data.length) decodeAstcBlock(data, off, fw, fh, blockTexels);
            else fillError(fw * fh, blockTexels);
            for (let y = 0; y < fh; y++) {
                const py = by * fh + y;
                if (py >= ih) break;
                for (let x = 0; x < fw; x++) {
                    const px = bx * fw + x;
                    if (px >= iw) break;
                    const s = (y * fw + x) * 4;
                    const d = (py * iw + px) * 4;
                    pix[d] = unchecked(blockTexels[s]);
                    pix[d + 1] = unchecked(blockTexels[s + 1]);
                    pix[d + 2] = unchecked(blockTexels[s + 2]);
                    pix[d + 3] = unchecked(blockTexels[s + 3]);
                }
            }
        }
    }
    return img;
}
