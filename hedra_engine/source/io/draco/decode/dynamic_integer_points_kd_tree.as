// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The decoder half of the dynamic integer-points KD-tree: the
// spatial-partitioning core behind KD-tree point-cloud coding (Draco's
// `dynamic_integer_points_kd_tree_decoder`). It consumes the per-node splits
// the attribute coder entropy-coded and rebuilds the integer points.
//
// Notes:
//   - This file holds the decoder half and the helpers both halves use
//     (`mostSignificantBit`, `incrementMod`). The encoder half
//     (`DynamicIntegerPointsKdTreeEncoder`, `PointDVector`, `NumbersEncoder`)
//     is engine/src/source/io/draco/encode/dynamic_integer_points_kd_tree.as.
//   - The entropy decoders' bit reads return an `i64`: the value, or
//     BIT_NONE on failure; `getAxis` returns -1 when there is no axis.
//   - A reservation cannot exceed one rasc object (BYTE_VEC_MAX_CAPACITY
//     bytes). A walk stack row count or an output that would outgrow one
//     refuses the walk instead of trapping (the budget and the caller's
//     limits bound it first in practice).

import { BIT_NONE } from "../core/bit_utils";
import { BYTE_VEC_MAX_CAPACITY } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DracoError } from "../core/status";
import { Result, panic } from "../../../../base/util";
import { DirectBitDecoder } from "../entropy/direct_bit_decoder";
import { FoldedBit32Decoder } from "../entropy/folded_bit32_coder";
import { RAnsBitDecoder } from "../entropy/rans_bit_decoder";

// The most u32 entries one Array<u32> can hold (one rasc object).
const MAX_U32_ENTRIES: u64 = <u64>(BYTE_VEC_MAX_CAPACITY / 4);

// `31 - value.leading_zeros()` (value > 0).
export function mostSignificantBit(value: u32): u32 {
    return 31 - <u32>clz<u32>(value);
}

// `v + 1`, wrapped to 0 at `m`.
export function incrementMod(v: u32, m: u32): u32 {
    const next = v + 1;
    if (next >= m) {
        return 0;
    }
    return next;
}

// Grows both walk stacks to hold at least `rows` rows of `dimension` entries
// (doubling), and returns how many rows they hold afterwards, or -1
// when the size overflows or cannot be allocated.
export function growRows(base: Array<u32>, levels: Array<u32>, dimension: u64, rows: u64, have: u64): i64 {
    const doubled = have > u64.MAX_VALUE / 2 ? u64.MAX_VALUE : have * 2;
    const target = rows > doubled ? rows : doubled;
    if (dimension != 0 && target > u64.MAX_VALUE / dimension) {
        return -1;
    }
    const needed = target * dimension;
    if (needed > MAX_U32_ENTRIES) {
        return -1;
    }
    const n = <i32>needed;
    if (base.length < n) {
        while (base.length < n) base.push(0);
    }
    if (levels.length < n) {
        while (levels.length < n) levels.push(0);
    }
    return <i64>target;
}

// Copies the row at `src` onto the `dim` values that follow it (the caller
// has bounded both rows).
export function copyRowToNext(stack: Array<u32>, src: i32, dim: i32): void {
    if (<i64>src + 2 * <i64>dim > <i64>stack.length) {
        // When the rows do not fit, rows of up to 12 values are left
        // unchanged; wider ones panic.
        if (dim <= 12) return;
        panic("range end index " + (src + 2 * dim).toString() + " out of range for slice of length " + stack.length.toString());
    }
    for (let i = 0; i < dim; i++) {
        unchecked((stack[src + dim + i] = unchecked(stack[src + i])));
    }
}

// Which entropy decoder a NumbersDecoder wraps.
enum NumbersDecoderKind {
    Direct,
    RAns,
    Folded,
}

class NumbersDecoder {
    kind: NumbersDecoderKind;
    direct: DirectBitDecoder = new DirectBitDecoder();
    rans: RAnsBitDecoder = new RAnsBitDecoder();
    folded: FoldedBit32Decoder? = null;

    constructor(kind: NumbersDecoderKind) {
        this.kind = kind;
        if (kind == NumbersDecoderKind.Folded) this.folded = new FoldedBit32Decoder();
    }

    startDecoding(buffer: DecoderBuffer): bool {
        switch (this.kind) {
            case NumbersDecoderKind.Direct:
                return this.direct.startDecoding(buffer);
            case NumbersDecoderKind.RAns:
                return this.rans.startDecoding(buffer);
            default:
                return (this.folded as FoldedBit32Decoder).startDecoding(buffer);
        }
    }

    // The value, or BIT_NONE on failure.
    decodeLeastSignificantBits32(nbits: u32): i64 {
        switch (this.kind) {
            case NumbersDecoderKind.Direct:
                return this.direct.decodeLeastSignificantBits32(nbits);
            case NumbersDecoderKind.RAns:
                return this.rans.decodeLeastSignificantBits32(<i32>nbits);
            default:
                return (this.folded as FoldedBit32Decoder).decodeLeastSignificantBits32(nbits);
        }
    }

    endDecoding(): void {
        switch (this.kind) {
            case NumbersDecoderKind.Direct:
                this.direct.endDecoding();
                break;
            case NumbersDecoderKind.RAns:
                this.rans.endDecoding();
                break;
            default:
                (this.folded as FoldedBit32Decoder).endDecoding();
        }
    }
}

// One node waiting on the walk stack.
class WalkStatus {
    numRemainingPoints: u32;
    lastAxis: u32;
    stackPos: i32;

    constructor(numRemainingPoints: u32, lastAxis: u32, stackPos: i32) {
        this.numRemainingPoints = numRemainingPoints;
        this.lastAxis = lastAxis;
        this.stackPos = stackPos;
    }
}

export class DynamicIntegerPointsKdTreeDecoder {
    private compressionLevel: u8;
    private bitLength: u32 = 0;
    private numPoints: u32 = 0;
    private numDecodedPoints_: u32 = 0;
    private dimension: u32;
    private baseStack: Array<u32> = new Array<u32>();
    private levelsStack: Array<u32> = new Array<u32>();
    private numbersDecoder: NumbersDecoder;
    private remainingBitsDecoder: DirectBitDecoder = new DirectBitDecoder();
    private axisDecoder: DirectBitDecoder = new DirectBitDecoder();
    private halfDecoder: DirectBitDecoder = new DirectBitDecoder();

    // A decoder for `dimension`-component points; the walk stacks are grown by
    // the walk, a row at a time, as the splits that need them are decoded.
    constructor(compressionLevel: u8, dimension: u32) {
        if (!(compressionLevel <= 6)) panic("assertion failed: compression_level <= 6");
        this.compressionLevel = compressionLevel;
        this.dimension = dimension;
        let kind = NumbersDecoderKind.Folded;
        if (compressionLevel <= 1) kind = NumbersDecoderKind.Direct;
        else if (compressionLevel <= 3) kind = NumbersDecoderKind.RAns;
        this.numbersDecoder = new NumbersDecoder(kind);
    }

    numDecodedPoints(): u32 {
        return this.numDecodedPoints_;
    }

    decodePoints(buffer: DecoderBuffer, oitMaxPoints: u32): Result<Array<u32>> {
        const rb = buffer.decodeU32();
        if (!rb.ok) return DracoError.buffer("Buffer ran out reading the KD-tree bit length").fail<Array<u32>>();
        this.bitLength = rb.value;
        if (this.bitLength > 32) {
            return DracoError.general(
                "KD-tree bit length " + this.bitLength.toString() + " above the 32 a u32 coordinate holds",
            ).fail<Array<u32>>();
        }
        const rn = buffer.decodeU32();
        if (!rn.ok) return DracoError.buffer("Buffer ran out reading the KD-tree point count").fail<Array<u32>>();
        this.numPoints = rn.value;
        if (this.numPoints == 0) {
            this.numDecodedPoints_ = 0;
            return Result.okv<Array<u32>>(new Array<u32>());
        }
        if (this.numPoints > oitMaxPoints) {
            return DracoError.general(
                "KD-tree declares " + this.numPoints.toString() + " points against the " + oitMaxPoints.toString() +
                " the header allows",
            ).fail<Array<u32>>();
        }

        this.numDecodedPoints_ = 0;

        // Every decoder is started before any result is checked; the first
        // failure is named.
        // (Checked one by one: a rasc 1.1.0 `Array<bool>` literal reads back
        // wrong values.)
        const s0 = this.numbersDecoder.startDecoding(buffer);
        const s1 = this.remainingBitsDecoder.startDecoding(buffer);
        const s2 = this.axisDecoder.startDecoding(buffer);
        const s3 = this.halfDecoder.startDecoding(buffer);
        let failed = "";
        if (!s0) failed = "numbers";
        else if (!s1) failed = "remaining bits";
        else if (!s2) failed = "axis";
        else if (!s3) failed = "half";
        if (failed.length > 0) {
            return DracoError.general("Failed to start the KD-tree's " + failed + " decoder").fail<Array<u32>>();
        }

        // `numPoints * dimension` cannot overflow u64, and the
        // reservation against the input (eight values per remaining byte)
        // cannot fail below one rasc object.
        const out = new Array<u32>();
        if (!this.decodeInternal(this.numPoints, out)) {
            return DracoError.general(
                "KD-tree traversal failed after " + this.numDecodedPoints_.toString() + " of " + this.numPoints.toString() +
                " points",
            ).fail<Array<u32>>();
        }

        this.numbersDecoder.endDecoding();
        this.remainingBitsDecoder.endDecoding();
        this.axisDecoder.endDecoding();
        this.halfDecoder.endDecoding();

        return Result.okv<Array<u32>>(out);
    }

    // The axis to split next, or -1 when the axis stream runs out.
    // `levels` is the node's row, `levels[rowStart..rowStart + dimension]`.
    getAxis(numRemainingPoints: u32, levels: Array<u32>, rowStart: i32, lastAxis: u32): i64 {
        if (this.compressionLevel != 6) {
            return <i64>incrementMod(lastAxis, this.dimension);
        }

        if (numRemainingPoints < 64) {
            // The shallowest axis, and on a tie the first of them; 0 for an
            // empty row.
            let best: i32 = 0;
            const dim = <i32>this.dimension;
            for (let i = 1; i < dim; i++) {
                if (levels[rowStart + i] < levels[rowStart + best]) best = i;
            }
            return <i64>best;
        }
        const v = this.axisDecoder.decodeLeastSignificantBits32(4);
        if (v == BIT_NONE) return -1;
        return v;
    }

    private decodeInternal(numPoints: u32, out: Array<u32>): bool {
        this.baseStack.length = 0;
        this.levelsStack.length = 0;
        return this.decodeWalk(numPoints, out, this.baseStack, this.levelsStack);
    }

    private decodeWalk(numPoints: u32, out: Array<u32>, baseStack: Array<u32>, levelsStack: Array<u32>): bool {
        const dimension = <i32>this.dimension;
        // The root's row, and a little beyond it.
        let rows = growRows(baseStack, levelsStack, <u64>dimension, 8, 0);
        if (rows < 0) {
            return false;
        }
        for (let i = 0; i < dimension; i++) {
            baseStack[i] = 0;
            levelsStack[i] = 0;
        }

        const stack = new Array<WalkStatus>();
        stack.push(new WalkStatus(numPoints, 0, 0));

        while (stack.length > 0) {
            const status = stack.pop();
            const numRemainingPoints = status.numRemainingPoints;
            const lastAxis = status.lastAxis;
            const stackPos = status.stackPos;

            const rowStart = stackPos * dimension;
            const rowEnd = rowStart + dimension;
            const childStart = rowEnd;
            if (baseStack.length < rowEnd || levelsStack.length < rowEnd) {
                return false;
            }

            if (numRemainingPoints > numPoints) {
                return false;
            }

            const axisOrNone = this.getAxis(numRemainingPoints, levelsStack, rowStart, lastAxis);
            if (axisOrNone < 0) {
                return false;
            }
            if (<u64>axisOrNone >= <u64>this.dimension) {
                return false;
            }
            const axis = <i32>axisOrNone;

            const level = levelsStack[rowStart + axis];

            if (this.bitLength - level == 0) {
                if (<u64>out.length + <u64>numRemainingPoints * <u64>dimension > MAX_U32_ENTRIES) {
                    return false;
                }
                for (let k: u32 = 0; k < numRemainingPoints; k++) {
                    for (let i = rowStart; i < rowEnd; i++) out.push(unchecked(baseStack[i]));
                    this.numDecodedPoints_ += 1;
                }
                continue;
            }

            if (numRemainingPoints <= 2) {
                for (let k: u32 = 0; k < numRemainingPoints; k++) {
                    if (<u64>out.length + <u64>dimension > MAX_U32_ENTRIES) {
                        return false;
                    }
                    // The point is assembled in place: the axis order is a
                    // rotation of every dimension, so each slot is written once.
                    const start = out.length;
                    for (let i = 0; i < dimension; i++) out.push(0);
                    let axisJ = axis;
                    for (let i = 0; i < dimension; i++) {
                        const numBits = this.bitLength - levelsStack[rowStart + axisJ];
                        let value: u32 = 0;
                        if (numBits != 0) {
                            const v = this.remainingBitsDecoder.decodeLeastSignificantBits32(numBits);
                            if (v == BIT_NONE) {
                                return false;
                            }
                            value = <u32>v;
                        }
                        out[start + axisJ] = value | baseStack[rowStart + axisJ];
                        axisJ = <i32>incrementMod(<u32>axisJ, this.dimension);
                    }
                    this.numDecodedPoints_ += 1;
                }
                continue;
            }

            if (this.numDecodedPoints_ > this.numPoints) {
                return false;
            }

            // Splitting is the one branch that writes the child's row, so it
            // is the one that adds it.
            if (<i64>stackPos + 2 > rows) {
                const grown = growRows(baseStack, levelsStack, <u64>dimension, <u64>(stackPos + 2), <u64>rows);
                if (grown < 0) {
                    return false;
                }
                rows = grown;
            }

            const numRemainingBits = this.bitLength - level;
            const modifier: u32 = <u32>1 << (numRemainingBits - 1);
            copyRowToNext(baseStack, rowStart, dimension);
            baseStack[childStart + axis] += modifier;

            const incomingBits = mostSignificantBit(numRemainingPoints);
            const nv = this.numbersDecoder.decodeLeastSignificantBits32(incomingBits);
            if (nv == BIT_NONE) {
                return false;
            }
            const number = <u32>nv;

            let firstHalf = numRemainingPoints / 2;
            if (firstHalf < number) {
                return false;
            }
            firstHalf -= number;
            let secondHalf = numRemainingPoints - firstHalf;

            if (firstHalf != secondHalf) {
                // DirectBitDecoder reports the exhaustion exactly: refuse
                // rather than invent the swap.
                const keep = this.halfDecoder.decodeNextBit();
                if (keep == BIT_NONE) {
                    return false;
                }
                if (keep == 0) {
                    const t = firstHalf;
                    firstHalf = secondHalf;
                    secondHalf = t;
                }
            }

            levelsStack[rowStart + axis] += 1;
            copyRowToNext(levelsStack, rowStart, dimension);

            if (firstHalf != 0) {
                stack.push(new WalkStatus(firstHalf, <u32>axis, stackPos));
            }
            if (secondHalf != 0) {
                stack.push(new WalkStatus(secondHalf, <u32>axis, stackPos + 1));
            }
        }

        return true;
    }
}
