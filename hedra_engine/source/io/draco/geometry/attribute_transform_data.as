// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Serialized parameters for an attribute transform (its type tag plus raw
// little-endian parameter bytes).
//
// `getParameterValue<T>` returns a Result<T> whose failure (err "None", no
// cause) means the value is absent. T is a number type (i8..u64, f32, f64).

import { Result } from "../../../../base/util";
import { DataBuffer } from "../core/data_buffer";
import { AttributeTransformType } from "./attribute_transform";
import { checkedAddU64, U64_NONE } from "./bytes";

export class AttributeTransformData {
    private transformType_: AttributeTransformType = AttributeTransformType.InvalidTransform;
    private buffer: DataBuffer = new DataBuffer();

    constructor() {}


    transformType(): AttributeTransformType {
        return this.transformType_;
    }

    setTransformType(transformType: AttributeTransformType): void {
        this.transformType_ = transformType;
    }

    // The value of type T stored at `byteOffset`; fails (err "None") when it
    // does not fit in the stored bytes.
    getParameterValue<T>(byteOffset: u64): Result<T> {
        const size = <u64>sizeof<T>();
        const end = checkedAddU64(byteOffset, size);
        if (end == U64_NONE || end > <u64>this.buffer.dataSize()) {
            return Result.fail<T>("None");
        }
        const tmp = new Uint8Array(<i32>size);
        if (!this.buffer.tryRead(byteOffset, tmp)) {
            return Result.fail<T>("None");
        }
        return Result.okv<T>(RawBytes.load<T>(tmp));
    }

    // Stores `inData` at `byteOffset`, growing the parameter bytes when
    // needed; silently does nothing when the offset overflows or the growth
    // cannot be allocated.
    setParameterValue<T>(byteOffset: u64, inData: T): void {
        const size = <u64>sizeof<T>();
        const end = checkedAddU64(byteOffset, size);
        if (end == U64_NONE) {
            return;
        }
        if (end > <u64>this.buffer.dataSize() && !this.buffer.tryResize(end).ok) {
            return;
        }
        const tmp = new Uint8Array(<i32>size);
        RawBytes.store<T>(tmp, inData);
        this.buffer.tryWrite(byteOffset, tmp);
    }

    appendParameterValue<T>(inData: T): void {
        this.setParameterValue<T>(<u64>this.buffer.dataSize(), inData);
    }

    // A deep copy.
    clone(): AttributeTransformData {
        const d = new AttributeTransformData();
        d.transformType_ = this.transformType_;
        d.buffer = this.buffer.clone();
        return d;
    }
}

// A T read from or written to the start of a byte array. rasc requires
// `load`/`store` inside an `unsafe` function; they are static methods, not
// functions, because the linter does not see calls from generic methods and
// would report two functions as never used (W3002).
class RawBytes {
    static unsafe load<T>(b: Uint8Array): T {
        return load<T>(b.dataStart);
    }

    static unsafe store<T>(b: Uint8Array, v: T): void {
        store<T>(b.dataStart, v);
    }
}
