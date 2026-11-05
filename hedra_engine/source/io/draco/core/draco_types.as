// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The scalar data type of a geometry attribute.

import { Result } from "../../../../base/util";
import { DracoError } from "./status";

// Scalar data type stored in a Draco geometry attribute. The discriminants
// are the wire values (Invalid = 0 … Bool = 11).
export enum DataType {
    Invalid = 0,
    Int8 = 1,
    Uint8 = 2,
    Int16 = 3,
    Uint16 = 4,
    Int32 = 5,
    Uint32 = 6,
    Int64 = 7,
    Uint64 = 8,
    Float32 = 9,
    Float64 = 10,
    Bool = 11,
}

// The DataType of a raw byte, or an error when it names none.
export function dataTypeTryFrom(value: u8): Result<DataType> {
    if (value >= 1 && value <= 11) return Result.okv<DataType>(<DataType>value);
    return DracoError.general("Invalid attribute data type: " + value.toString()).fail<DataType>();
}

// Byte width of one scalar value.
export function dataTypeByteLength(t: DataType): i32 {
    switch (t) {
        case DataType.Invalid: return 0;
        case DataType.Int8:
        case DataType.Uint8:
        case DataType.Bool: return 1;
        case DataType.Int16:
        case DataType.Uint16: return 2;
        case DataType.Int32:
        case DataType.Uint32:
        case DataType.Float32: return 4;
        case DataType.Int64:
        case DataType.Uint64:
        case DataType.Float64: return 8;
    }
    return 0;
}

// True for integer-like attribute storage types.
export function dataTypeIsIntegral(t: DataType): bool {
    return !(t == DataType.Float32 || t == DataType.Float64 || t == DataType.Invalid);
}

// `{:?}` of a DataType (the variant name).
export function dataTypeDebug(t: DataType): string {
    switch (t) {
        case DataType.Invalid: return "Invalid";
        case DataType.Int8: return "Int8";
        case DataType.Uint8: return "Uint8";
        case DataType.Int16: return "Int16";
        case DataType.Uint16: return "Uint16";
        case DataType.Int32: return "Int32";
        case DataType.Uint32: return "Uint32";
        case DataType.Int64: return "Int64";
        case DataType.Uint64: return "Uint64";
        case DataType.Float32: return "Float32";
        case DataType.Float64: return "Float64";
        case DataType.Bool: return "Bool";
    }
    return "";
}
