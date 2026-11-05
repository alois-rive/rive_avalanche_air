// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// PredictionParent, the attribute a prediction scheme reads its parent
// through.
//
// A predictor never holds a PointAttribute: it holds a PredictionParent,
// which exposes only the point-to-entry lookup and the canonical widening
// reads. `portable()` validates the declared type against what the portable
// pass writes; `legacy()` is the pre-2.0 binding of the attribute itself.
//
// The read methods return whether a value was read and leave it in
// `lastI64` / `lastF32`, so a hot predictor loop allocates nothing:
//   `if (!p.readComponentAsI64(e, c)) {..} const v = p.lastI64;`

import { Result } from "../../../../base/util";
import { DataType, dataTypeByteLength, dataTypeDebug } from "../core/draco_types";
import { DracoError } from "../core/status";
import { GeometryAttributeType, PointAttribute } from "./geometry_attribute";
import {
    readI8, readU8, readI16Le, readU16Le, readI32Le, readI64Le, readU64Le, readF32Le, readF64Le,
    checkedMulU64, checkedAddU64, U64_NONE,
} from "./bytes";

export class PredictionParent {
    private att: PointAttribute;
    // The value of the last successful readComponentAsI64 / readComponentAsF32.
    lastI64: i64 = 0;
    lastF32: f32 = 0;

    // Use portable() or legacy().
    constructor(att: PointAttribute) {
        this.att = att;
    }

    // Binds the portable int32 copy as a prediction parent, refusing any
    // type the portable pass cannot have written (float, 64-bit, bool).
    static portable(att: PointAttribute): Result<PredictionParent> {
        const t = att.dataType();
        if (
            !(t == DataType.Int8 ||
                t == DataType.Uint8 ||
                t == DataType.Int16 ||
                t == DataType.Uint16 ||
                t == DataType.Int32 ||
                t == DataType.Uint32)
        ) {
            return DracoError.invalidParameter(
                "A prediction parent must be the portable int32 copy, got a " + dataTypeDebug(t) + " attribute",
            ).fail<PredictionParent>();
        }
        return Result.okv<PredictionParent>(new PredictionParent(att));
    }

    // Binds the attribute itself, for bitstreams below 2.0.
    static legacy(att: PointAttribute): PredictionParent {
        return new PredictionParent(att);
    }

    attributeType(): GeometryAttributeType {
        return this.att.attributeType();
    }

    numComponents(): u8 {
        return this.att.numComponents();
    }

    // The attribute value entry a point reads from.
    mappedIndex(pointId: u32): u32 {
        return this.att.mappedIndex(pointId);
    }

    // Byte offset of `entry`/`component`, or U64_NONE when it overflows.
    private offsetOf(entry: u64, component: u64): u64 {
        const stride = this.att.byteStride();
        if (stride < 0) return U64_NONE;
        const a = checkedMulU64(entry, <u64>stride);
        if (a == U64_NONE) return U64_NONE;
        const b = checkedMulU64(component, <u64>dataTypeByteLength(this.att.dataType()));
        if (b == U64_NONE) return U64_NONE;
        return checkedAddU64(a, b);
    }

    // Whether `n` bytes at `offset` are in the buffer (DataBuffer::try_read).
    private fits(offset: u64, n: u64): bool {
        if (offset == U64_NONE) return false;
        const end = checkedAddU64(offset, n);
        return end != U64_NONE && end <= <u64>this.att.buffer().dataSize();
    }

    // The portable value at `entry`/`component`, widened to i64, into
    // `lastI64`. Integral types widen numerically except uint32, read as the
    // int32 the portable copy carries; floats (pre-2.0 binding) truncate, and
    // a non-finite one reads as nothing.
    readComponentAsI64(entry: u64, component: u64): bool {
        const offset = this.offsetOf(entry, component);
        const data = this.att.buffer().data();
        switch (this.att.dataType()) {
            case DataType.Int8: {
                if (!this.fits(offset, 1)) return false;
                this.lastI64 = <i64>readI8(data, <i32>offset);
                return true;
            }
            case DataType.Uint8: {
                if (!this.fits(offset, 1)) return false;
                this.lastI64 = <i64>readU8(data, <i32>offset);
                return true;
            }
            case DataType.Int16: {
                if (!this.fits(offset, 2)) return false;
                this.lastI64 = <i64>readI16Le(data, <i32>offset);
                return true;
            }
            case DataType.Uint16: {
                if (!this.fits(offset, 2)) return false;
                this.lastI64 = <i64>readU16Le(data, <i32>offset);
                return true;
            }
            case DataType.Int32:
            case DataType.Uint32: {
                if (!this.fits(offset, 4)) return false;
                this.lastI64 = <i64>readI32Le(data, <i32>offset);
                return true;
            }
            case DataType.Int64: {
                if (!this.fits(offset, 8)) return false;
                this.lastI64 = readI64Le(data, <i32>offset);
                return true;
            }
            case DataType.Uint64: {
                if (!this.fits(offset, 8)) return false;
                const v = readU64Le(data, <i32>offset);
                if (v > <u64>i64.MAX_VALUE) return false;
                this.lastI64 = <i64>v;
                return true;
            }
            case DataType.Float32: {
                if (!this.fits(offset, 4)) return false;
                return this.floatToI64(<f64>readF32Le(data, <i32>offset));
            }
            case DataType.Float64: {
                if (!this.fits(offset, 8)) return false;
                return this.floatToI64(readF64Le(data, <i32>offset));
            }
            case DataType.Bool: {
                if (!this.fits(offset, 1)) return false;
                this.lastI64 = <i64>readU8(data, <i32>offset);
                return true;
            }
        }
        return false;
    }

    // Three components at once, for the position parents (`out` gets them;
    // false leaves the components read so far).
    readVector3AsI64(entry: u64, out: StaticArray<i64>): bool {
        for (let c = 0; c < 3; c++) {
            if (!this.readComponentAsI64(entry, <u64>c)) {
                return false;
            }
            out[c] = this.lastI64;
        }
        return true;
    }

    // The parent value read at its declared type and converted to f32, into
    // `lastF32` (only the deprecated tex-coord predictor reads this way).
    // uint32 reads as int32, like readComponentAsI64.
    readComponentAsF32(entry: u64, component: u64): bool {
        const offset = this.offsetOf(entry, component);
        const data = this.att.buffer().data();
        switch (this.att.dataType()) {
            case DataType.Int8: {
                if (!this.fits(offset, 1)) return false;
                this.lastF32 = <f32>readI8(data, <i32>offset);
                return true;
            }
            case DataType.Uint8: {
                if (!this.fits(offset, 1)) return false;
                this.lastF32 = <f32>readU8(data, <i32>offset);
                return true;
            }
            case DataType.Int16: {
                if (!this.fits(offset, 2)) return false;
                this.lastF32 = <f32>readI16Le(data, <i32>offset);
                return true;
            }
            case DataType.Uint16: {
                if (!this.fits(offset, 2)) return false;
                this.lastF32 = <f32>readU16Le(data, <i32>offset);
                return true;
            }
            case DataType.Int32:
            case DataType.Uint32: {
                if (!this.fits(offset, 4)) return false;
                this.lastF32 = <f32>readI32Le(data, <i32>offset);
                return true;
            }
            case DataType.Float32: {
                if (!this.fits(offset, 4)) return false;
                this.lastF32 = readF32Le(data, <i32>offset);
                return true;
            }
            case DataType.Float64: {
                if (!this.fits(offset, 8)) return false;
                this.lastF32 = <f32>readF64Le(data, <i32>offset);
                return true;
            }
        }
        return false;
    }

    // Converts to i64 into `lastI64`; false for non-finite values and values
    // outside i64.
    private floatToI64(value: f64): bool {
        if (!isFinite<f64>(value)) {
            return false;
        }
        if (value < -9223372036854775808.0 || value >= 9223372036854775808.0) {
            return false;
        }
        this.lastI64 = <i64>value;
        return true;
    }
}
