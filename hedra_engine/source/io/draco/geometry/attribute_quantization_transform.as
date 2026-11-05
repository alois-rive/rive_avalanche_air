// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Maps floating-point attribute values onto a fixed-point integer grid
// (origin, range, bit count), and inverts it (dequantizes) on decode.

import { DataType, dataTypeDebug } from "../core/draco_types";
import { DecoderBuffer } from "../core/decoder_buffer";
import { EncoderBuffer } from "../core/encoder_buffer";
import { DracoError, Status, okStatus } from "../core/status";
import { EntryToPointIdMap } from "../prediction/prediction_scheme";
import { displayF32 } from "../../../../base/fmt";
import { Result } from "../../../../base/util";
import { AttributeTransform, AttributeTransformType, attributeTransformTypeDebug } from "./attribute_transform";
import { AttributeTransformData } from "./attribute_transform_data";
import { PointAttribute } from "./geometry_attribute";
import { Dequantizer, Quantizer } from "./quantization_utils";
import { readF32Le, readI32Le, writeF32Le, writeU32Le, checkedMulU64, checkedAddU64, U64_NONE } from "./bytes";

// The quantization bit counts this transform can represent (upstream's
// `IsQuantizationValid`: 1..=30).
function validQuantizationBits(bits: i32): bool {
    return bits >= 1 && bits <= 30;
}

function invalidQuantizationBits(bits: i32): DracoError {
    return DracoError.invalidParameter(
        "Quantization bits " + bits.toString() + " outside the supported range 1..=30",
    );
}

// `((1u64 << bits) - 1) as i32`
function maxQuantizedValueOf(bits: i32): i32 {
    return <i32>((<u64>1 << <u64><u32>bits) - 1);
}

export class AttributeQuantizationTransform extends AttributeTransform {
    quantizationBits: i32 = -1;
    minValues: Array<f32> = new Array<f32>();
    range: f32 = 0;

    constructor() {
        super();
    }

    setParameters(quantizationBits: i32, minValues: Array<f32>, range: f32): Status {
        if (!validQuantizationBits(quantizationBits)) {
            return invalidQuantizationBits(quantizationBits).fail<bool>();
        }
        this.quantizationBits = quantizationBits;
        this.minValues = minValues.slice(0);
        this.range = range;
        return okStatus();
    }

    // What `value` on component `component` becomes after a quantize /
    // dequantize round trip through these parameters (monotonic in the value).
    roundTripComponent(component: i32, value: f32): Result<f32> {
        if (!validQuantizationBits(this.quantizationBits)) {
            return invalidQuantizationBits(this.quantizationBits).fail<f32>();
        }
        if (component < 0 || component >= this.minValues.length) {
            return DracoError.invalidParameter(
                "Quantization parameters cover " + this.minValues.length.toString() + " components, asked for " + component.toString(),
            ).fail<f32>();
        }
        const minValue = this.minValues[component];
        const maxQuantizedValue = maxQuantizedValueOf(this.quantizationBits);

        const quantizer = new Quantizer();
        quantizer.init(this.range, maxQuantizedValue);
        const quantized = quantizer.quantizeFloat(value - minValue);

        const dequantizer = new Dequantizer();
        if (!dequantizer.init(this.range, maxQuantizedValue)) {
            return DracoError.invalidParameter(
                "Dequantizer rejects range " + displayF32(this.range) + " over " + maxQuantizedValue.toString() + " steps",
            ).fail<f32>();
        }
        return Result.okv<f32>(dequantizer.dequantizeFloat(quantized) + minValue);
    }

    computeParameters(attribute: PointAttribute, quantizationBits: i32): Status {
        if (!validQuantizationBits(quantizationBits)) {
            return invalidQuantizationBits(quantizationBits).fail<bool>();
        }
        this.quantizationBits = quantizationBits;
        const numComponents = <i32>attribute.numComponents();

        const numEntries = attribute.size();
        if (numEntries == 0) {
            return DracoError.invalidParameter("Cannot compute quantization parameters from an empty attribute").fail<bool>();
        }

        if (attribute.dataType() != DataType.Float32) {
            return DracoError.invalidParameter(
                "Quantization needs a float32 attribute, got " + dataTypeDebug(attribute.dataType()),
            ).fail<bool>();
        }

        const data = attribute.buffer().data();
        const byteStride = <u64>attribute.byteStride();
        const dataLen = <u64>data.length;

        this.minValues = new Array<f32>(numComponents);
        const maxValues = new Array<f32>(numComponents);

        // Read the first entry to initialize min/max (matching C++ behavior).
        for (let c = 0; c < numComponents; c++) {
            const start = <u64>(c * 4);
            if (start + 4 > dataLen) {
                return truncatedSource();
            }
            const val = readF32Le(data, <i32>start);
            this.minValues[c] = val;
            maxValues[c] = val;
        }

        // The remaining entries, from index 1 (matching the C++ loop).
        for (let i = 1; i < numEntries; i++) {
            const offset = checkedMulU64(<u64>i, byteStride);
            if (offset == U64_NONE) {
                return DracoError.general("Attribute byte offset overflow").fail<bool>();
            }
            const end = checkedAddU64(offset, <u64>(numComponents * 4));
            if (end == U64_NONE) {
                return DracoError.general("Attribute byte offset overflow").fail<bool>();
            }
            if (end > dataLen) {
                return truncatedSource();
            }
            const o = <i32>offset;
            for (let c = 0; c < numComponents; c++) {
                const val = readF32Le(data, o + c * 4);
                if (isNaN<f32>(val)) {
                    return DracoError.invalidParameter("Attribute value is NaN and cannot be quantized").fail<bool>();
                }
                if (unchecked(this.minValues[c]) > val) {
                    unchecked((this.minValues[c] = val));
                }
                if (unchecked(maxValues[c]) < val) {
                    unchecked((maxValues[c] = val));
                }
            }
        }

        // Check for NaN/Inf and compute range (matching C++).
        this.range = 0;
        for (let c = 0; c < numComponents; c++) {
            const mn = this.minValues[c];
            const mx = maxValues[c];
            if (!isFinite<f32>(mn) || !isFinite<f32>(mx)) {
                return DracoError.invalidParameter(
                    "Attribute component " + c.toString() + " spans a non-finite range and cannot be quantized",
                ).fail<bool>();
            }
            const diff: f32 = mx - mn;
            if (diff > this.range) {
                this.range = diff;
            }
        }

        // Every value the same leaves a zero range: unit length instead, as
        // upstream does, so they all quantize to the same bucket.
        if (this.range == <f32>0) {
            this.range = 1;
        }

        return okStatus();
    }

    // Quantizes `attribute` into `targetAttribute` (re-initialized as Uint32).
    private generatePortableAttribute(
        attribute: PointAttribute,
        pointIds: EntryToPointIdMap,
        targetAttribute: PointAttribute,
    ): Status {
        if (!validQuantizationBits(this.quantizationBits)) {
            return invalidQuantizationBits(this.quantizationBits).fail<bool>();
        }
        const numPoints = pointIds.isEmpty() ? attribute.size() : pointIds.len();
        const numComponents = <i32>attribute.numComponents();

        if (this.minValues.length < numComponents) {
            return DracoError.invalidParameter(
                "Quantization parameters cover " + this.minValues.length.toString() + " components, attribute has " + numComponents.toString(),
            ).fail<bool>();
        }

        targetAttribute.init(
            attribute.attributeType(),
            <u8>numComponents,
            DataType.Uint32,
            false,
            numPoints,
        );

        const maxQuantizedValue = maxQuantizedValueOf(this.quantizationBits);
        const quantizer = new Quantizer();
        quantizer.init(this.range, maxQuantizedValue);

        const srcStride = <i64>attribute.byteStride();
        const dstStride = <i64>targetAttribute.byteStride();
        const srcData = attribute.buffer().data();
        const dstData = targetAttribute.bufferMut().dataMut();
        const srcLen = <i64>srcData.length;
        const dstLen = <i64>dstData.length;

        // Fast path: 3-component float -> 3-component uint32 with identity
        // mapping (sequential encoding). It reads entry i, not mapped_index(i).
        if (numComponents == 3 && pointIds.isEmpty()) {
            const m0 = this.minValues[0];
            const m1 = this.minValues[1];
            const m2 = this.minValues[2];
            for (let i = 0; i < numPoints; i++) {
                const srcOffset = <i64>i * srcStride;
                const dstOffset = <i64>i * dstStride;
                if (srcOffset + 12 > srcLen || dstOffset + 12 > dstLen) {
                    return DracoError.general("Quantization source or target data is truncated").fail<bool>();
                }
                const so = <i32>srcOffset;
                const d0 = <i32>dstOffset;
                const rawX = readF32Le(srcData, so);
                const rawY = readF32Le(srcData, so + 4);
                const rawZ = readF32Le(srcData, so + 8);

                const qX = <u32>quantizer.quantizeFloat(rawX - m0);
                const qY = <u32>quantizer.quantizeFloat(rawY - m1);
                const qZ = <u32>quantizer.quantizeFloat(rawZ - m2);

                writeU32Le(dstData, d0, qX);
                writeU32Le(dstData, d0 + 4, qY);
                writeU32Le(dstData, d0 + 8, qZ);
            }
        } else {
            // Generic path.
            for (let i = 0; i < numPoints; i++) {
                // mapped_index gives the attribute value index, matching C++.
                let pointIdx: u32;
                if (pointIds.isEmpty()) {
                    pointIdx = <u32>i;
                } else {
                    const p = pointIds.get(i);
                    pointIdx = p < 0 ? u32.MAX_VALUE : <u32>p;
                }
                const attValIdx = attribute.mappedIndex(pointIdx);
                const srcOffset = checkedMulU64(<u64>attValIdx, <u64>srcStride);
                if (srcOffset == U64_NONE) {
                    return DracoError.general("Attribute byte offset overflow").fail<bool>();
                }
                const dstOffset = <i64>i * dstStride;
                const span = <u64>(numComponents * 4);
                if (srcOffset + span > <u64>srcLen || <u64>dstOffset + span > <u64>dstLen) {
                    return DracoError.general("Quantization source or target data is truncated").fail<bool>();
                }

                const so = <i32>srcOffset;
                const d0 = <i32>dstOffset;
                for (let c = 0; c < numComponents; c++) {
                    // Read the raw component, then subtract min (C++ order).
                    const rawVal = readF32Le(srcData, so + c * 4);
                    const val: f32 = rawVal - unchecked(this.minValues[c]);
                    const qVal = quantizer.quantizeFloat(val);
                    writeU32Le(dstData, d0 + c * 4, <u32>qVal);
                }
            }
        }

        return okStatus();
    }

    transformType(): AttributeTransformType {
        return AttributeTransformType.QuantizationTransform;
    }

    initFromAttribute(attribute: PointAttribute): Status {
        const data = attribute.attributeTransformData();
        if (data == null) {
            return DracoError.invalidParameter("Attribute carries no transform data").fail<bool>();
        }
        if (data.transformType() != AttributeTransformType.QuantizationTransform) {
            return DracoError.invalidParameter(
                "Attribute carries " + attributeTransformTypeDebug(data.transformType()) + ", not a quantization transform",
            ).fail<bool>();
        }

        let byteOffset: u64 = 0;
        const bits = data.getParameterValue<i32>(byteOffset);
        if (!bits.ok) {
            return truncatedParameters();
        }
        this.quantizationBits = bits.value;
        byteOffset += 4;

        const numComponents = <i32>attribute.numComponents();
        resizeF32Array(this.minValues, numComponents);
        for (let i = 0; i < numComponents; i++) {
            const val = data.getParameterValue<f32>(byteOffset);
            if (!val.ok) {
                return truncatedParameters();
            }
            this.minValues[i] = val.value;
            byteOffset += 4;
        }

        const range = data.getParameterValue<f32>(byteOffset);
        if (!range.ok) {
            return truncatedParameters();
        }
        this.range = range.value;

        return okStatus();
    }

    copyToAttributeTransformData(outData: AttributeTransformData): void {
        outData.setTransformType(AttributeTransformType.QuantizationTransform);
        outData.appendParameterValue<i32>(this.quantizationBits);
        for (let i = 0; i < this.minValues.length; i++) {
            outData.appendParameterValue<f32>(this.minValues[i]);
        }
        outData.appendParameterValue<f32>(this.range);
    }

    transformAttribute(
        attribute: PointAttribute,
        pointIds: EntryToPointIdMap,
        targetAttribute: PointAttribute,
    ): Status {
        return this.generatePortableAttribute(attribute, pointIds, targetAttribute);
    }

    inverseTransformAttribute(attribute: PointAttribute, targetAttribute: PointAttribute): Status {
        if (targetAttribute.dataType() != DataType.Float32) {
            return DracoError.invalidParameter(
                "Dequantization needs a float32 target, got " + dataTypeDebug(targetAttribute.dataType()),
            ).fail<bool>();
        }

        if (!validQuantizationBits(this.quantizationBits)) {
            return invalidQuantizationBits(this.quantizationBits).fail<bool>();
        }

        const maxQuantizedValue = maxQuantizedValueOf(this.quantizationBits);
        const dequantizer = new Dequantizer();
        if (!dequantizer.init(this.range, maxQuantizedValue)) {
            return DracoError.invalidParameter(
                "Dequantizer rejects range " + displayF32(this.range) + " over " + maxQuantizedValue.toString() + " steps",
            ).fail<bool>();
        }

        const numComponents = <i32>targetAttribute.numComponents();
        if (this.minValues.length < numComponents) {
            return DracoError.invalidParameter(
                "Quantization parameters cover " + this.minValues.length.toString() + " components, attribute has " + numComponents.toString(),
            ).fail<bool>();
        }
        const numValues = <u64>targetAttribute.size();

        if (targetAttribute.byteStride() < 0) {
            return DracoError.general("Negative target byte stride").fail<bool>();
        }
        const dstStride = <u64>targetAttribute.byteStride();
        if (attribute.byteStride() < 0) {
            return DracoError.general("Negative source byte stride").fail<bool>();
        }
        const srcStride = <u64>attribute.byteStride();
        // The target arrives unreserved from a decode; it is sized here, where
        // the values to put in it already exist in the source.
        {
            const requiredSrc = checkedMulU64(numValues, srcStride);
            const requiredDst = checkedMulU64(numValues, dstStride);
            if (requiredSrc != U64_NONE && requiredDst != U64_NONE) {
                if (
                    <u64>attribute.buffer().dataSize() >= requiredSrc &&
                    <u64>targetAttribute.buffer().dataSize() < requiredDst
                ) {
                    if (!targetAttribute.bufferMut().tryResize(requiredDst).ok) {
                        return DracoError.general("Failed to allocate dequantized values").fail<bool>();
                    }
                }
            }
        }

        const srcData = attribute.buffer().data();
        const dstData = targetAttribute.bufferMut().dataMut();
        const srcLen = <u64>srcData.length;
        const dstLen = <u64>dstData.length;

        const COMPONENT_SIZE: u64 = 4;
        const tightStride = <u64>numComponents * COMPONENT_SIZE;
        if (
            attribute.dataType() == DataType.Uint32 &&
            numComponents > 0 &&
            srcStride == tightStride &&
            dstStride == tightStride
        ) {
            const requiredSrc = checkedMulU64(numValues, srcStride);
            if (requiredSrc == U64_NONE) {
                return overflowError();
            }
            const requiredDst = checkedMulU64(numValues, dstStride);
            if (requiredDst == U64_NONE) {
                return overflowError();
            }
            if (srcLen < requiredSrc || dstLen < requiredDst) {
                return truncatedDequantization();
            }

            // Both sides tightly packed: component k of entry i is at
            // (i * numComponents + k) * 4 on each side.
            const total = <i32>numValues * numComponents;
            for (let j = 0; j < total; j++) {
                const c = j % numComponents;
                const quantized = readI32Le(srcData, j * 4);
                writeF32Le(dstData, j * 4, dequantizer.dequantizeFloat(quantized) + unchecked(this.minValues[c]));
            }

            return okStatus();
        }

        for (let i: u64 = 0; i < numValues; i++) {
            const srcOffset = checkedMulU64(i, srcStride);
            if (srcOffset == U64_NONE) {
                return overflowError();
            }
            const dstOffset = checkedMulU64(i, dstStride);
            if (dstOffset == U64_NONE) {
                return overflowError();
            }

            for (let c = 0; c < numComponents; c++) {
                const componentOffset = <u64>(c * 4);
                const srcPos = checkedAddU64(srcOffset, componentOffset);
                if (srcPos == U64_NONE) {
                    return overflowError();
                }
                const srcEnd = checkedAddU64(srcPos, 4);
                if (srcEnd == U64_NONE) {
                    return overflowError();
                }
                if (srcEnd > srcLen) {
                    return truncatedDequantization();
                }
                const qVal = readI32Le(srcData, <i32>srcPos);

                const val: f32 = dequantizer.dequantizeFloat(qVal) + this.minValues[c];
                const dstPos = checkedAddU64(dstOffset, componentOffset);
                if (dstPos == U64_NONE) {
                    return overflowError();
                }
                const dstEnd = checkedAddU64(dstPos, 4);
                if (dstEnd == U64_NONE) {
                    return overflowError();
                }
                if (dstEnd > dstLen) {
                    return truncatedDequantization();
                }
                writeF32Le(dstData, <i32>dstPos, val);
            }
        }

        return okStatus();
    }

    encodeParameters(encoderBuffer: EncoderBuffer): Status {
        // Parameters that were never computed (bits -1) are refused rather
        // than written as 0xFF.
        if (!validQuantizationBits(this.quantizationBits)) {
            return invalidQuantizationBits(this.quantizationBits).fail<bool>();
        }
        for (let i = 0; i < this.minValues.length; i++) {
            encoderBuffer.encode<f32>(this.minValues[i]);
        }
        encoderBuffer.encode<f32>(this.range);
        encoderBuffer.encodeU8(<u8>this.quantizationBits);
        return okStatus();
    }

    decodeParameters(attribute: PointAttribute, decoderBuffer: DecoderBuffer): Status {
        const numComponents = <i32>attribute.numComponents();

        resizeF32Array(this.minValues, numComponents);
        for (let i = 0; i < numComponents; i++) {
            const val = decoderBuffer.decode<f32>();
            if (!val.ok) {
                return truncatedStream("minimum values");
            }
            this.minValues[i] = val.value;
        }

        const range = decoderBuffer.decode<f32>();
        if (!range.ok) {
            return truncatedStream("range");
        }
        this.range = range.value;

        const bits = decoderBuffer.decodeU8();
        if (!bits.ok) {
            return truncatedStream("bit count");
        }
        this.quantizationBits = <i32>bits.value;

        if (!validQuantizationBits(this.quantizationBits)) {
            return invalidQuantizationBits(this.quantizationBits).fail<bool>();
        }

        return okStatus();
    }

    getTransformedDataType(_attribute: PointAttribute): DataType {
        return DataType.Uint32;
    }

    getTransformedNumComponents(attribute: PointAttribute): i32 {
        return <i32>attribute.numComponents();
    }

    // A deep copy.
    clone(): AttributeQuantizationTransform {
        const t = new AttributeQuantizationTransform();
        t.quantizationBits = this.quantizationBits;
        t.minValues = this.minValues.slice(0);
        t.range = this.range;
        return t;
    }
}

// Resizes `a` to `n` entries, new ones 0.
function resizeF32Array(a: Array<f32>, n: i32): void {
    const old = a.length;
    a.length = n;
    for (let i = old; i < n; i++) unchecked((a[i] = 0));
}

function truncatedSource(): Status {
    return DracoError.general("Attribute source data is truncated relative to its value count").fail<bool>();
}

function truncatedParameters(): Status {
    return DracoError.invalidParameter("Attribute transform data is shorter than the quantization parameters").fail<bool>();
}

function overflowError(): Status {
    return DracoError.general("Attribute byte range overflow").fail<bool>();
}

function truncatedDequantization(): Status {
    return DracoError.general("Dequantization source or target data is truncated").fail<bool>();
}

function truncatedStream(what: string): Status {
    return DracoError.buffer("Stream ends before the quantization " + what + " it declares").fail<bool>();
}
