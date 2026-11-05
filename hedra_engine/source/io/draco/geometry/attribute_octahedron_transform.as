// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Projects unit normals onto an octahedron and quantizes the 2D result (two
// int32 per normal); decode inverts the projection.

import { ByteVec, BYTE_VEC_MAX_CAPACITY } from "../core/byte_vec";
import { DataType, dataTypeDebug } from "../core/draco_types";
import { DecoderBuffer } from "../core/decoder_buffer";
import { EncoderBuffer } from "../core/encoder_buffer";
import { DracoError, Status, okStatus } from "../core/status";
import { EntryToPointIdMap } from "../prediction/prediction_scheme";
import { Vec3 } from "../../../../base/vecmath";
import { AttributeTransform, AttributeTransformType, attributeTransformTypeDebug } from "./attribute_transform";
import { AttributeTransformData } from "./attribute_transform_data";
import { PointAttribute } from "./geometry_attribute";
import { OctahedronToolBox, OctCoords } from "./normal_compression_utils";
import { readF32Le, readI32Le, writeF32Le, writeU32Le, checkedMulU64, checkedAddU64, U64_NONE } from "./bytes";

export class AttributeOctahedronTransform extends AttributeTransform {
    private quantizationBits_: i32;

    constructor(quantizationBits: i32) {
        super();
        this.quantizationBits_ = quantizationBits;
    }

    static isValidQuantizationBits(quantizationBits: i32): bool {
        return quantizationBits >= 2 && quantizationBits <= 30;
    }

    setParameters(quantizationBits: i32): Status {
        if (!AttributeOctahedronTransform.isValidQuantizationBits(quantizationBits)) {
            return invalidOctahedralBits(quantizationBits).fail<bool>();
        }
        this.quantizationBits_ = quantizationBits;
        return okStatus();
    }

    isInitialized(): bool {
        return this.quantizationBits_ != -1;
    }

    quantizationBits(): i32 {
        return this.quantizationBits_;
    }

    generatePortableAttribute(
        attribute: PointAttribute,
        pointIds: EntryToPointIdMap,
        numPoints: i32,
        targetAttribute: PointAttribute,
    ): Status {
        if (!this.isInitialized()) {
            return DracoError.invalidParameter("Not initialized").fail<bool>();
        }

        const converter = new OctahedronToolBox();
        if (!converter.setQuantizationBits(this.quantizationBits_)) {
            return invalidOctahedralBits(this.quantizationBits_).fail<bool>();
        }

        const portableDataSize = checkedMulU64(checkedMulU64(<u64>numPoints, 2), 4);
        if (portableDataSize == U64_NONE) {
            return DracoError.general("Portable octahedron buffer size overflow").fail<bool>();
        }
        if (portableDataSize > <u64>BYTE_VEC_MAX_CAPACITY) {
            return DracoError.general("Failed to allocate portable octahedron buffer").fail<bool>();
        }
        const portableData = new ByteVec();
        portableData.reserveExact(<i32>portableDataSize);
        if (attribute.byteStride() < 0) {
            return DracoError.general("Negative attribute byte stride").fail<bool>();
        }
        const byteStride = <u64>attribute.byteStride();
        const sourceData = attribute.buffer().data();
        const pair = new Uint8Array(8);

        const count = !pointIds.isEmpty() ? pointIds.len() : numPoints;
        for (let entry = 0; entry < count; entry++) {
            let pointId: u32;
            if (!pointIds.isEmpty()) {
                const p = pointIds.get(entry);
                pointId = p < 0 ? u32.MAX_VALUE : <u32>p;
            } else {
                pointId = <u32>entry;
            }
            const attValId = attribute.mappedIndex(pointId);
            // read_normal
            const offset = checkedMulU64(<u64>attValId, byteStride);
            if (offset == U64_NONE) {
                return DracoError.general("Attribute byte offset overflow").fail<bool>();
            }
            const end = checkedAddU64(offset, 12);
            if (end == U64_NONE) {
                return DracoError.general("Attribute byte range overflow").fail<bool>();
            }
            if (end > <u64>sourceData.length) {
                return DracoError.general("Attribute normal source data is truncated").fail<bool>();
            }
            const o = <i32>offset;
            const st: OctCoords = converter.floatVectorToQuantizedOctahedralCoords3(
                readF32Le(sourceData, o),
                readF32Le(sourceData, o + 4),
                readF32Le(sourceData, o + 8),
            );
            writeU32Le(pair, 0, <u32>st.s);
            writeU32Le(pair, 4, <u32>st.t);
            portableData.extend(pair);
        }

        if (!targetAttribute.bufferMut().tryResize(<u64>portableData.length).ok) {
            return DracoError.general("Failed to allocate portable octahedron output").fail<bool>();
        }
        targetAttribute.bufferMut().write(0, portableData.data());

        return okStatus();
    }

    inverseTransformAttributeWithLegacyOctahedron(
        attribute: PointAttribute,
        targetAttribute: PointAttribute,
        legacyOctahedronToVector: bool,
    ): Status {
        return this.inverseTransformAttributeImpl(attribute, targetAttribute, legacyOctahedronToVector);
    }

    private inverseTransformAttributeImpl(
        attribute: PointAttribute,
        targetAttribute: PointAttribute,
        legacyOctahedronToVector: bool,
    ): Status {
        if (targetAttribute.dataType() != DataType.Float32) {
            return DracoError.invalidParameter(
                "Octahedral decode needs a float32 target, got " + dataTypeDebug(targetAttribute.dataType()),
            ).fail<bool>();
        }
        if (targetAttribute.numComponents() != 3) {
            return DracoError.invalidParameter(
                "Octahedral decode needs 3 target components, got " + targetAttribute.numComponents().toString(),
            ).fail<bool>();
        }

        const numPoints = <u64>targetAttribute.size();
        const converter = new OctahedronToolBox();
        if (!converter.setQuantizationBits(this.quantizationBits_)) {
            return invalidOctahedralBits(this.quantizationBits_).fail<bool>();
        }

        // The source (int32 (s, t) pairs) is checked before the target is
        // sized, so the allocation follows data that exists.
        const sourceByteSize = checkedMulU64(checkedMulU64(numPoints, 2), 4);
        if (sourceByteSize == U64_NONE) {
            return DracoError.general("Octahedral source buffer size overflow").fail<bool>();
        }
        if (<u64>attribute.buffer().dataSize() < sourceByteSize) {
            return DracoError.general("Octahedral portable data is truncated").fail<bool>();
        }

        const targetByteSize = checkedMulU64(checkedMulU64(numPoints, 3), 4);
        if (targetByteSize == U64_NONE) {
            return DracoError.general("Octahedral target buffer size overflow").fail<bool>();
        }

        const targetBuffer = targetAttribute.bufferMut();
        if (!targetBuffer.tryResize(targetByteSize).ok) {
            return DracoError.general("Failed to allocate the octahedral target buffer").fail<bool>();
        }

        const sourceData = attribute.buffer().data();
        const targetData = targetBuffer.dataMut();
        const n = <i32>numPoints;
        for (let i = 0; i < n; i++) {
            const offset = i * 8; // 2 int32s.
            const s = readI32Le(sourceData, offset);
            const t = readI32Le(sourceData, offset + 4);

            const attVal: Vec3 = legacyOctahedronToVector
                ? converter.quantizedOctahedralCoordsToUnitVectorLegacy(s, t)
                : converter.quantizedOctahedralCoordsToUnitVector(s, t);

            const targetOffset = i * 12;
            writeF32Le(targetData, targetOffset, attVal.x);
            writeF32Le(targetData, targetOffset + 4, attVal.y);
            writeF32Le(targetData, targetOffset + 8, attVal.z);
        }

        return okStatus();
    }

    transformType(): AttributeTransformType {
        return AttributeTransformType.OctahedronTransform;
    }

    initFromAttribute(attribute: PointAttribute): Status {
        const transformData = attribute.attributeTransformData();
        if (transformData == null) {
            return DracoError.invalidParameter("Attribute carries no transform data").fail<bool>();
        }
        if (transformData.transformType() != AttributeTransformType.OctahedronTransform) {
            return DracoError.invalidParameter(
                "Attribute carries " + attributeTransformTypeDebug(transformData.transformType()) + ", not an octahedron transform",
            ).fail<bool>();
        }
        const bits = transformData.getParameterValue<i32>(0);
        if (!bits.ok) {
            return DracoError.invalidParameter(
                "Attribute transform data is shorter than the octahedral bit count",
            ).fail<bool>();
        }
        return this.setParameters(bits.value);
    }

    copyToAttributeTransformData(outData: AttributeTransformData): void {
        outData.setTransformType(AttributeTransformType.OctahedronTransform);
        outData.appendParameterValue<i32>(this.quantizationBits_);
    }

    transformAttribute(
        attribute: PointAttribute,
        pointIds: EntryToPointIdMap,
        targetAttribute: PointAttribute,
    ): Status {
        return this.generatePortableAttribute(attribute, pointIds, targetAttribute.size(), targetAttribute);
    }

    inverseTransformAttribute(attribute: PointAttribute, targetAttribute: PointAttribute): Status {
        return this.inverseTransformAttributeImpl(attribute, targetAttribute, false);
    }

    encodeParameters(encoderBuffer: EncoderBuffer): Status {
        if (!this.isInitialized()) {
            return DracoError.invalidParameter("Octahedron transform parameters were never set").fail<bool>();
        }
        encoderBuffer.encode<u8>(<u8>this.quantizationBits_);
        return okStatus();
    }

    decodeParameters(_attribute: PointAttribute, decoderBuffer: DecoderBuffer): Status {
        const quantizationBits = decoderBuffer.decode<u8>();
        if (!quantizationBits.ok) {
            return DracoError.buffer("Stream ends before the octahedral bit count it declares").fail<bool>();
        }
        return this.setParameters(<i32>quantizationBits.value);
    }

    getTransformedDataType(_attribute: PointAttribute): DataType {
        return DataType.Uint32;
    }

    getTransformedNumComponents(_attribute: PointAttribute): i32 {
        return 2;
    }
}

function invalidOctahedralBits(bits: i32): DracoError {
    return DracoError.invalidParameter(
        "Octahedral quantization bits " + bits.toString() + " outside the supported range 2..=30",
    );
}
