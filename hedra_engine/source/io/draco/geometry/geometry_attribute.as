// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The attribute format descriptor (GeometryAttribute) and the typed per-point
// value store (PointAttribute).
//
// Sizes and counts are i32 (a wasm32 buffer cannot hold more), computed in
// i64/u64 where they must be checked for overflow. Value-index lists are
// Array<u32>.

import { Result, panic } from "../../../../base/util";
import { DataBuffer } from "../core/data_buffer";
import { ByteVec } from "../core/byte_vec";
import { DataType, dataTypeByteLength, dataTypeDebug } from "../core/draco_types";
import { DracoError, Status, okStatus } from "../core/status";
import { AttributeTransformData } from "./attribute_transform_data";
import { INVALID_ATTRIBUTE_VALUE_INDEX } from "./geometry_indices";
import {
    readF32Le, readF64Le, readI8, readU8, readI16Le, readU16Le, readI32Le, readU32Le,
    checkedMulU64, U64_NONE,
} from "./bytes";

// Widens one stored scalar at `data[o]` to f32, whatever Draco declared its
// type to be. A type with no numeric reading (Bool and the 64-bit integers)
// reads as zero.
function scalarAsF32(dataType: DataType, data: Uint8Array, o: i32): f32 {
    switch (dataType) {
        case DataType.Float32: return readF32Le(data, o);
        case DataType.Float64: return <f32>readF64Le(data, o);
        case DataType.Int8: return <f32>readI8(data, o);
        case DataType.Uint8: return <f32>readU8(data, o);
        case DataType.Int16: return <f32>readI16Le(data, o);
        case DataType.Uint16: return <f32>readU16Le(data, o);
        case DataType.Int32: return <f32>readI32Le(data, o);
        case DataType.Uint32: return <f32>readU32Le(data, o);
    }
    return 0;
}

// The largest value count an attribute can hold: `size()` is an i32. A
// larger count is refused as a size overflow.
export const MAX_VALUE_COUNT: u64 = <u64>i32.MAX_VALUE;

// Semantic role of a geometry attribute (wire values 0..4).
export enum GeometryAttributeType {
    Invalid = -1,
    Position = 0,
    Normal = 1,
    Color = 2,
    TexCoord = 3,
    Generic = 4,
}

// The attribute type of a raw byte, or an error when it names none.
export function geometryAttributeTypeTryFrom(value: u8): Result<GeometryAttributeType> {
    if (value <= 4) return Result.okv<GeometryAttributeType>(<GeometryAttributeType><i32>value);
    return DracoError.general("Invalid geometry attribute type: " + value.toString()).fail<GeometryAttributeType>();
}

// `{:?}` of a GeometryAttributeType (the variant name).
export function geometryAttributeTypeDebug(t: GeometryAttributeType): string {
    switch (t) {
        case GeometryAttributeType.Invalid: return "Invalid";
        case GeometryAttributeType.Position: return "Position";
        case GeometryAttributeType.Normal: return "Normal";
        case GeometryAttributeType.Color: return "Color";
        case GeometryAttributeType.TexCoord: return "TexCoord";
        case GeometryAttributeType.Generic: return "Generic";
    }
    return "";
}

// Format descriptor shared by point and mesh attributes.
export class GeometryAttribute {
    private attributeType_: GeometryAttributeType = GeometryAttributeType.Invalid;
    private dataType_: DataType = DataType.Invalid;
    private numComponents_: u8 = 0;
    private normalized_: bool = false;
    private byteStride_: i64 = 0;
    private byteOffset_: i64 = 0;
    private uniqueId_: u32 = 0;

    constructor() {}

    // Initializes the attribute format descriptor (the buffer is ignored).
    init(
        attributeType: GeometryAttributeType,
        _buffer: DataBuffer?,
        numComponents: u8,
        dataType: DataType,
        normalized: bool,
        byteStride: i64,
        byteOffset: i64,
    ): void {
        this.attributeType_ = attributeType;
        this.numComponents_ = numComponents;
        this.dataType_ = dataType;
        this.normalized_ = normalized;
        this.byteStride_ = byteStride;
        this.byteOffset_ = byteOffset;
    }

    attributeType(): GeometryAttributeType { return this.attributeType_; }
    dataType(): DataType { return this.dataType_; }
    numComponents(): u8 { return this.numComponents_; }
    normalized(): bool { return this.normalized_; }
    byteStride(): i64 { return this.byteStride_; }
    byteOffset(): i64 { return this.byteOffset_; }
    uniqueId(): u32 { return this.uniqueId_; }
    setUniqueId(id: u32): void { this.uniqueId_ = id; }
    setAttributeType(attributeType: GeometryAttributeType): void { this.attributeType_ = attributeType; }
    setDataType(dataType: DataType): void { this.dataType_ = dataType; }
    setNumComponents(numComponents: u8): void { this.numComponents_ = numComponents; }

    clone(): GeometryAttribute {
        const g = new GeometryAttribute();
        g.attributeType_ = this.attributeType_;
        g.dataType_ = this.dataType_;
        g.numComponents_ = this.numComponents_;
        g.normalized_ = this.normalized_;
        g.byteStride_ = this.byteStride_;
        g.byteOffset_ = this.byteOffset_;
        g.uniqueId_ = this.uniqueId_;
        return g;
    }
}

// The value storage and explicit map an attribute gives up (`takeStorage`).
// `mapCapacity` is the map's capacity: the largest length it ever had.
export class AttributeStorage {
    bytes: ByteVec;
    map: Array<u32>;
    mapCapacity: i32;

    constructor(bytes: ByteVec, map: Array<u32>, mapCapacity: i32) {
        this.bytes = bytes;
        this.map = map;
        this.mapCapacity = mapCapacity;
    }
}

// Resizes `a` to `n` entries: new slots get `fill`
// (an AS `length =` growth can expose stale values).
export function resizeU32Array(a: Array<u32>, n: i32, fill: u32): void {
    const old = a.length;
    a.length = n;
    for (let i = old; i < n; i++) unchecked((a[i] = fill));
}

// Typed attribute values attached to points in a point cloud or mesh.
//
// Attribute data is stored in a contiguous byte buffer. Point ids either map
// directly to attribute value ids, or through an explicit point-to-value map
// when multiple points share or reorder attribute entries.
export class PointAttribute {
    private base: GeometryAttribute = new GeometryAttribute();
    private buffer_: DataBuffer = new DataBuffer();
    private indicesMap: Array<u32> = new Array<u32>();
    // The map's capacity, tracked as the largest length reached.
    private indicesMapCapacity: i32 = 0;
    private identityMapping: bool = true;
    private numUniqueEntries: i32 = 0;
    private attributeTransformData_: AttributeTransformData? = null;

    constructor() {}


    private noteMapLength(): void {
        if (this.indicesMap.length > this.indicesMapCapacity) this.indicesMapCapacity = this.indicesMap.length;
    }

    // Initializes the attribute and allocates storage for its values.
    init(
        attributeType: GeometryAttributeType,
        numComponents: u8,
        dataType: DataType,
        normalized: bool,
        numAttributeValues: i32,
    ): void {
        const byteStride = <i64>numComponents * <i64>dataTypeByteLength(dataType);
        this.base.init(attributeType, null, numComponents, dataType, normalized, byteStride, 0);
        this.buffer_.resize(<i64>numAttributeValues * byteStride);
        this.numUniqueEntries = numAttributeValues;
        this.identityMapping = true;
    }

    // Fallibly initializes the attribute and allocates storage for its values.
    tryInit(
        attributeType: GeometryAttributeType,
        numComponents: u8,
        dataType: DataType,
        normalized: bool,
        numAttributeValues: u64,
    ): Status {
        const byteStride = <u64>numComponents * <u64>dataTypeByteLength(dataType);
        const bufferSize = checkedMulU64(numAttributeValues, byteStride);
        if (bufferSize == U64_NONE || numAttributeValues > MAX_VALUE_COUNT) {
            return DracoError.general("Point attribute buffer size overflow").fail<bool>();
        }
        this.base.init(attributeType, null, numComponents, dataType, normalized, <i64>byteStride, 0);
        if (!this.buffer_.tryResize(bufferSize).ok) {
            return DracoError.general("Failed to allocate point attribute buffer").fail<bool>();
        }
        this.numUniqueEntries = <i32>numAttributeValues;
        this.identityMapping = true;
        return okStatus();
    }

    // The same shape, without reserving for the values (decode paths where the
    // count comes from the header; the decoders size the buffer themselves).
    // `size()` still reports the declared count.
    initDeferred(
        attributeType: GeometryAttributeType,
        numComponents: u8,
        dataType: DataType,
        normalized: bool,
        numAttributeValues: u64,
    ): Status {
        const byteStride = <u64>numComponents * <u64>dataTypeByteLength(dataType);
        if (checkedMulU64(numAttributeValues, byteStride) == U64_NONE || numAttributeValues > MAX_VALUE_COUNT) {
            return DracoError.general("Point attribute buffer size overflow").fail<bool>();
        }
        this.base.init(attributeType, null, numComponents, dataType, normalized, <i64>byteStride, 0);
        this.numUniqueEntries = <i32>numAttributeValues;
        this.identityMapping = true;
        return okStatus();
    }

    // Maps a point id to the corresponding attribute value id.
    mappedIndex(pointIndex: u32): u32 {
        if (this.identityMapping) {
            return pointIndex;
        } else if (<u64>pointIndex < <u64>this.indicesMap.length) {
            return unchecked(this.indicesMap[<i32>pointIndex]);
        }
        return INVALID_ATTRIBUTE_VALUE_INDEX;
    }

    // Returns the number of unique attribute values.
    size(): i32 {
        return this.numUniqueEntries;
    }

    // Reads `components` scalars per point as f32, in point order, following
    // the value mapping and widening any component type. Always
    // `numPoints * components` long, zero where the attribute has nothing.
    readF32s(numPoints: i32, components: i32): Float32Array {
        const values = new Float32Array(numPoints * components);
        if (components == 0) {
            return values;
        }
        const stride = <i32>this.byteStride();
        const width = dataTypeByteLength(this.dataType());
        const data = this.buffer_.data();

        if (
            this.identityMapping &&
            this.dataType() == DataType.Float32 &&
            components == <i32>this.numComponents() &&
            stride == components * 4 &&
            <i64>data.length >= <i64>numPoints * <i64>stride
        ) {
            const n = numPoints * components;
            for (let i = 0; i < n; i++) {
                unchecked((values[i] = readF32Le(data, i * 4)));
            }
            return values;
        }

        const available = min(<i32>this.numComponents(), components);
        for (let point = 0; point < numPoints; point++) {
            const valueIndex = this.mappedIndex(<u32>point);
            // Also catches INVALID_ATTRIBUTE_VALUE_INDEX.
            if (<u64>valueIndex >= <u64>this.numUniqueEntries) {
                continue;
            }
            const base = <i64>valueIndex * <i64>stride;
            for (let component = 0; component < available; component++) {
                const offset = base + <i64>(component * width);
                if (offset + <i64>width > <i64>data.length) {
                    continue;
                }
                values[point * components + component] = scalarAsF32(this.dataType(), data, <i32>offset);
            }
        }
        return values;
    }

    // Resizes the unique attribute value storage.
    resizeUniqueEntries(numAttributeValues: u64): Status {
        const byteStride = <u64>this.byteStride();
        const bufferSize = checkedMulU64(numAttributeValues, byteStride);
        if (bufferSize == U64_NONE || numAttributeValues > MAX_VALUE_COUNT) {
            return DracoError.general("Point attribute buffer size overflow").fail<bool>();
        }
        if (!this.buffer_.tryResize(bufferSize).ok) {
            return DracoError.general("Failed to allocate point attribute buffer").fail<bool>();
        }
        this.numUniqueEntries = <i32>numAttributeValues;
        if (this.identityMapping) {
            this.indicesMap.length = 0;
        }
        return okStatus();
    }

    // Merges values that are bit-identical (compared as raw bytes), remapping
    // the point map onto what survives. Returns how many values are left.
    // Refuses 64-bit types and component counts outside 1..=4.
    deduplicateValues(): Result<i32> {
        let width: i32;
        switch (this.dataType()) {
            case DataType.Int8:
            case DataType.Uint8:
            case DataType.Bool:
                width = 1;
                break;
            case DataType.Int16:
            case DataType.Uint16:
                width = 2;
                break;
            case DataType.Int32:
            case DataType.Uint32:
            case DataType.Float32:
                width = 4;
                break;
            default:
                return DracoError.unsupportedFeature(
                    "deduplicating " + dataTypeDebug(this.dataType()) + " attribute values",
                ).fail<i32>();
        }
        const stride = width * <i32>this.numComponents();
        const nc = this.numComponents();
        if (!(nc >= 1 && nc <= 4)) {
            return DracoError.unsupportedFeature(
                "deduplicating a " + nc.toString() + "-component attribute",
            ).fail<i32>();
        }

        const count = this.numUniqueEntries;
        const seen = new Map<string, u32>();
        const valueMap = new Array<u32>();
        let unique = 0;
        const data = this.buffer_.dataMut();
        const keyUnits = new Array<i32>(stride);
        for (let i = 0; i < count; i++) {
            const at = i * stride;
            if (at + stride > data.length) {
                panic("range end index " + (at + stride).toString() + " out of range for slice of length " + data.length.toString());
            }
            for (let k = 0; k < stride; k++) unchecked((keyUnits[k] = <i32>data[at + k]));
            const key = String.fromCharCodes(keyUnits);
            if (seen.has(key)) {
                valueMap.push(seen.get(key));
            } else {
                seen.set(key, <u32>unique);
                // Survivors are packed forward as they are found.
                data.copyWithin(unique * stride, at, at + stride);
                valueMap.push(<u32>unique);
                unique += 1;
            }
        }
        if (unique == count) {
            return Result.okv<i32>(unique);
        }

        if (this.identityMapping) {
            // The map was point == value, so the old value count is the point
            // count this attribute has to keep answering for.
            this.setExplicitMapping(count);
            for (let point = 0; point < valueMap.length; point++) {
                this.indicesMap[point] = valueMap[point];
            }
        } else {
            for (let e = 0; e < this.indicesMap.length; e++) {
                const entry = unchecked(this.indicesMap[e]);
                unchecked((this.indicesMap[e] = <u64>entry < <u64>valueMap.length
                    ? unchecked(valueMap[<i32>entry])
                    : INVALID_ATTRIBUTE_VALUE_INDEX));
            }
        }
        // The survivors were packed forward, so the tail is stale bytes: the
        // buffer length follows the value count.
        this.buffer_.resize(<i64>unique * <i64>stride);
        this.numUniqueEntries = unique;
        return Result.okv<i32>(unique);
    }

    // Drops values no point maps to, and remaps the point map onto what is
    // left. Returns how many values survive. Nothing to do under identity
    // mapping.
    removeUnusedValues(): i32 {
        if (this.identityMapping) {
            return this.numUniqueEntries;
        }
        const n = this.numUniqueEntries;
        const used = new StaticArray<bool>(n);
        let numUsed = 0;
        for (let k = 0; k < this.indicesMap.length; k++) {
            const index = unchecked(this.indicesMap[k]);
            if (<u64>index < <u64>n && !used[<i32>index]) {
                used[<i32>index] = true;
                numUsed += 1;
            }
        }
        if (numUsed == n) {
            return numUsed;
        }

        const stride = <i32>this.numComponents() * dataTypeByteLength(this.dataType());
        const oldToNew = new StaticArray<u32>(n);
        for (let k = 0; k < n; k++) oldToNew[k] = INVALID_ATTRIBUTE_VALUE_INDEX;
        let next = 0;
        {
            const data = this.buffer_.dataMut();
            for (let old = 0; old < n; old++) {
                if (!used[old]) {
                    continue;
                }
                if (old != next && stride > 0) {
                    if (old * stride + stride > data.length) {
                        panic("range end index " + (old * stride + stride).toString() + " out of range for slice of length " + data.length.toString());
                    }
                    data.copyWithin(next * stride, old * stride, old * stride + stride);
                }
                oldToNew[old] = <u32>next;
                next += 1;
            }
        }
        for (let e = 0; e < this.indicesMap.length; e++) {
            const entry = unchecked(this.indicesMap[e]);
            // An entry past the value count stays the invalid index.
            unchecked((this.indicesMap[e] = <u64>entry < <u64>n ? oldToNew[<i32>entry] : INVALID_ATTRIBUTE_VALUE_INDEX));
        }
        this.buffer_.resize(<i64>numUsed * <i64>stride);
        this.numUniqueEntries = numUsed;
        return numUsed;
    }

    // Returns the raw attribute value buffer.
    buffer(): DataBuffer {
        return this.buffer_;
    }

    // Returns the mutable raw attribute value buffer (the same object).
    bufferMut(): DataBuffer {
        return this.buffer_;
    }

    attributeType(): GeometryAttributeType { return this.base.attributeType(); }
    uniqueId(): u32 { return this.base.uniqueId(); }
    setUniqueId(id: u32): void { this.base.setUniqueId(id); }
    setAttributeType(attributeType: GeometryAttributeType): void { this.base.setAttributeType(attributeType); }
    setDataType(dataType: DataType): void { this.base.setDataType(dataType); }
    setNumComponents(numComponents: u8): void { this.base.setNumComponents(numComponents); }

    // Whether point ids are used directly as attribute value ids.
    isMappingIdentity(): bool {
        return this.identityMapping;
    }

    // Takes the value storage and the explicit map out, leaving both empty.
    takeStorage(): AttributeStorage {
        const s = new AttributeStorage(this.buffer_.takeStorage(), this.indicesMap, this.indicesMapCapacity);
        this.indicesMap = new Array<u32>();
        this.indicesMapCapacity = 0;
        return s;
    }

    // Adopts storage taken from another attribute, emptied, when this one
    // holds none of its own yet.
    adoptStorage(storage: AttributeStorage): void {
        if (!this.buffer_.hasStorage()) {
            this.buffer_.adoptStorage(storage.bytes);
        }
        if (this.indicesMapCapacity == 0) {
            storage.map.length = 0;
            this.indicesMap = storage.map;
            this.indicesMapCapacity = storage.mapCapacity;
        }
    }

    // Uses point ids directly as attribute value ids.
    setIdentityMapping(): void {
        this.identityMapping = true;
        this.indicesMap.length = 0;
    }

    // Allocates an explicit point-to-attribute-value map (new entries get the
    // invalid index; existing ones are kept).
    setExplicitMapping(numPoints: i32): void {
        this.identityMapping = false;
        resizeU32Array(this.indicesMap, numPoints, INVALID_ATTRIBUTE_VALUE_INDEX);
        this.noteMapLength();
    }

    // The explicit point-to-attribute-value map (the live array), or null
    // under identity mapping.
    explicitMapping(): Array<u32>? {
        if (this.identityMapping) {
            return null;
        }
        return this.indicesMap;
    }

    // Replaces the whole point-to-attribute-value map with a copy of `entries`.
    setExplicitMappingFrom(entries: Array<u32>): void {
        this.identityMapping = false;
        this.indicesMap.length = 0;
        for (let i = 0; i < entries.length; i++) this.indicesMap.push(unchecked(entries[i]));
        this.noteMapLength();
    }

    // Sets one point-to-attribute-value map entry (panics out of range).
    setPointMapEntry(pointIndex: u32, entryIndex: u32): void {
        this.trySetPointMapEntry(pointIndex, entryIndex).expect("point map entry must be in range");
    }

    // Fallibly sets one point-to-attribute-value map entry.
    trySetPointMapEntry(pointIndex: u32, entryIndex: u32): Status {
        if (this.identityMapping) {
            return okStatus();
        }
        if (<u64>pointIndex >= <u64>this.indicesMap.length) {
            return DracoError.general("Point map entry index out of range").fail<bool>();
        }
        this.indicesMap[<i32>pointIndex] = entryIndex;
        return okStatus();
    }

    // Stores transform metadata associated with this attribute.
    setAttributeTransformData(data: AttributeTransformData): void {
        this.attributeTransformData_ = data;
    }

    // Transform metadata associated with this attribute, if present.
    attributeTransformData(): AttributeTransformData? {
        return this.attributeTransformData_;
    }

    dataType(): DataType { return this.base.dataType(); }
    normalized(): bool { return this.base.normalized(); }
    numComponents(): u8 { return this.base.numComponents(); }
    byteStride(): i64 { return this.base.byteStride(); }

    // A deep copy.
    clone(): PointAttribute {
        const a = new PointAttribute();
        a.base = this.base.clone();
        a.buffer_ = this.buffer_.clone();
        a.indicesMap = this.indicesMap.slice(0);
        a.indicesMapCapacity = this.indicesMap.length;
        a.identityMapping = this.identityMapping;
        a.numUniqueEntries = this.numUniqueEntries;
        const t = this.attributeTransformData_;
        a.attributeTransformData_ = t != null ? t.clone() : null;
        return a;
    }
}
