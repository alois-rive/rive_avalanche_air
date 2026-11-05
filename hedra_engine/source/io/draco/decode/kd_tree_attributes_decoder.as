// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Decodes point-cloud attributes compressed with Draco's KD-tree scheme, which
// exploits spatial coherence instead of explicit connectivity (Draco's
// `kd_tree_attributes_decoder.h`). Used for point clouds (no mesh faces).
//
// Notes:
//   - Some internals (`decodePortableAttributes`, `cachedDecoded`,
//     `writeU32ComponentsFromDecoded`) are public so the tests can reach them.
//   - Counts are u64.

import { DataBuffer } from "../core/data_buffer";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DataType, dataTypeByteLength, dataTypeDebug, dataTypeTryFrom } from "../core/draco_types";
import { DracoError, Status, dracoErrorOf, okStatus } from "../core/status";
import { AttributeQuantizationTransform } from "../geometry/attribute_quantization_transform";
import { U64_NONE, checkedAddU64, checkedMulU64 } from "../geometry/bytes";
import { PointAttribute, geometryAttributeTypeTryFrom } from "../geometry/geometry_attribute";
import { PointCloud } from "../geometry/point_cloud";
import { DynamicIntegerPointsKdTreeDecoder } from "./dynamic_integer_points_kd_tree";
import { satMulU64 } from "./point_cloud_decoder";

// One attribute's place in the decoded rows (for the unsigned and the
// signed pass alike).
class AttributeSpec {
    attId: i32;
    offset: u64;
    numComponents: u64;
    dataType: DataType;

    constructor(attId: i32, offset: u64, numComponents: u64, dataType: DataType) {
        this.attId = attId;
        this.offset = offset;
        this.numComponents = numComponents;
        this.dataType = dataType;
    }
}

// A float attribute's column range.
class FloatSpec {
    attId: i32;
    offset: u64;
    numComponents: u64;

    constructor(attId: i32, offset: u64, numComponents: u64) {
        this.attId = attId;
        this.offset = offset;
        this.numComponents = numComponents;
    }
}

// The decoded KD-tree points, kept for the signed pass.
export class CachedDecoded {
    decoded: Array<u32>;
    totalDimensionality: u64;

    constructor(decoded: Array<u32>, totalDimensionality: u64) {
        this.decoded = decoded;
        this.totalDimensionality = totalDimensionality;
    }
}

// Adds `context` to the error of a failed Status.
function statusContext(s: Status, context: string): Status {
    const e = dracoErrorOf<bool>(s);
    if (e != null) return e.context(context).fail<bool>();
    return DracoError.general(s.err).context(context).fail<bool>();
}

export class KdTreeAttributesDecoder {
    attributeIds: Array<i32> = new Array<i32>();
    quantizedPortableAttributes: Array<PointAttribute> = new Array<PointAttribute>();
    attributeQuantizationTransforms: Array<AttributeQuantizationTransform> = new Array<AttributeQuantizationTransform>();
    minSignedValues: Array<i32> = new Array<i32>();
    private attributeSpecs: Array<AttributeSpec> = new Array<AttributeSpec>();
    private signedAttributeSpecs: Array<AttributeSpec> = new Array<AttributeSpec>();
    cachedDecoded: CachedDecoded? = null;

    // A decoder whose first attribute is `firstAttId`.
    constructor(firstAttId: i32) {
        this.attributeIds.push(firstAttId);
    }

    addAttributeId(attId: i32): void {
        this.attributeIds.push(attId);
    }

    decodeAttributesDecoderData(pointCloud: PointCloud, inBuffer: DecoderBuffer): Status {
        this.attributeIds.length = 0;
        const rn = inBuffer.decodeVarint();
        if (!rn.ok) return DracoError.buffer("Buffer ran out reading the KD-tree attribute count").fail<bool>();
        const numAttributes = rn.value;
        // Four one-byte fields plus at least one byte of unique-id varint.
        const MIN_ATTRIBUTE_DESCRIPTOR_BYTES: u64 = 5;
        if (numAttributes == 0) {
            return DracoError.general("A KD-tree attributes decoder must carry at least one attribute").fail<bool>();
        }
        if (numAttributes > <u64>inBuffer.remainingSize() / MIN_ATTRIBUTE_DESCRIPTOR_BYTES) {
            return DracoError.general(
                numAttributes.toString() + " attribute descriptors need at least " +
                MIN_ATTRIBUTE_DESCRIPTOR_BYTES.toString() + " bytes each, and " + inBuffer.remainingSize().toString() +
                " remain",
            ).fail<bool>();
        }

        const count = <i32>numAttributes;
        for (let index = 0; index < count; index++) {
            const rt = inBuffer.decodeU8();
            if (!rt.ok) {
                return DracoError.buffer("Buffer ran out reading attribute " + index.toString() + "'s type").fail<bool>();
            }
            const attTypeVal = rt.value;
            const rat = geometryAttributeTypeTryFrom(attTypeVal);
            if (!rat.ok) {
                return DracoError.general(
                    "Attribute " + index.toString() + " names geometry attribute type " + attTypeVal.toString() +
                    ", which is not defined",
                ).fail<bool>();
            }

            const rd = inBuffer.decodeU8();
            if (!rd.ok) {
                return DracoError.buffer("Buffer ran out reading attribute " + index.toString() + "'s data type").fail<bool>();
            }
            const dataTypeVal = rd.value;
            const rdt = dataTypeTryFrom(dataTypeVal);
            if (!rdt.ok) {
                return DracoError.general(
                    "Attribute " + index.toString() + " names data type " + dataTypeVal.toString() + ", which is not defined",
                ).fail<bool>();
            }
            const dataType = rdt.value;

            const rc = inBuffer.decodeU8();
            if (!rc.ok) {
                return DracoError.buffer(
                    "Buffer ran out reading attribute " + index.toString() + "'s component count",
                ).fail<bool>();
            }
            const numComponents = rc.value;
            if (numComponents == 0) {
                return DracoError.general("Attribute " + index.toString() + " declares zero components").fail<bool>();
            }
            const rnorm = inBuffer.decodeU8();
            if (!rnorm.ok) {
                return DracoError.buffer(
                    "Buffer ran out reading attribute " + index.toString() + "'s normalized flag",
                ).fail<bool>();
            }
            const normalized = rnorm.value != 0;
            const ru = inBuffer.decodeVarint();
            if (!ru.ok) {
                return DracoError.buffer("Buffer ran out reading attribute " + index.toString() + "'s unique id").fail<bool>();
            }
            const uniqueId = <u32>ru.value;

            // Uncharged against the budget (the buffer is left unreserved and
            // sized once the KD-tree has produced the values); the caller's
            // ceiling is charged here, where the size is first known.
            const numPoints = <u64>pointCloud.numPoints();
            const sb = inBuffer.chargeDecodedBytes(
                satMulU64(satMulU64(<u64>numComponents, <u64>dataTypeByteLength(dataType)), numPoints),
            );
            if (!sb.ok) return sb;
            const att = new PointAttribute();
            const si = att.initDeferred(rat.value, numComponents, dataType, normalized, numPoints);
            if (!si.ok) return si;
            att.setUniqueId(uniqueId);

            const attId = pointCloud.addAttributePreserveUniqueId(att);
            this.attributeIds.push(attId);
        }
        return okStatus();
    }

    decodeAttributes(pointCloud: PointCloud, inBuffer: DecoderBuffer): Status {
        const s1 = this.decodePortableAttributes(pointCloud, inBuffer);
        if (!s1.ok) return s1;
        const s2 = this.decodeDataNeededByPortableTransforms(pointCloud, inBuffer);
        if (!s2.ok) return s2;
        return this.transformAttributesToOriginalFormat(pointCloud);
    }

    // Public for the tests.
    decodePortableAttributes(pointCloud: PointCloud, inBuffer: DecoderBuffer): Status {
        const numExpectedPoints = <u64>pointCloud.numPoints();
        // Transforms and minimum values are decoded separately: not cleared.
        this.quantizedPortableAttributes.length = 0;
        this.attributeSpecs.length = 0;
        this.signedAttributeSpecs.length = 0;
        this.cachedDecoded = null;

        const rl = inBuffer.decodeU8();
        if (!rl.ok) return DracoError.buffer("Buffer ran out reading the KD-tree compression level").fail<bool>();
        const compressionLevel = rl.value;
        if (compressionLevel > 6) {
            return DracoError.general(
                "KD-tree compression level " + compressionLevel.toString() + " outside the supported range 0..=6",
            ).fail<bool>();
        }

        let totalDimensionality: u64 = 0;
        const floatSpecs = new Array<FloatSpec>();

        for (let i = 0; i < this.attributeIds.length; i++) {
            const attId = this.attributeIds[i];
            const ra = pointCloud.tryAttribute(attId);
            if (!ra.ok) return ra.forward<bool>();
            const att = ra.value;
            const numComponents = <u64>att.numComponents();
            this.attributeSpecs.push(new AttributeSpec(attId, totalDimensionality, numComponents, att.dataType()));
            switch (att.dataType()) {
                case DataType.Uint32:
                case DataType.Uint16:
                case DataType.Uint8:
                    break;
                case DataType.Int32:
                case DataType.Int16:
                case DataType.Int8: {
                    this.signedAttributeSpecs.push(new AttributeSpec(attId, totalDimensionality, numComponents, att.dataType()));
                    for (let c: u64 = 0; c < numComponents; c++) this.minSignedValues.push(0);
                    break;
                }
                case DataType.Float32:
                    floatSpecs.push(new FloatSpec(attId, totalDimensionality, numComponents));
                    break;
                default:
                    return DracoError.unsupportedFeature(
                        "The KD-tree coder does not carry " + dataTypeDebug(att.dataType()) + " attributes",
                    ).fail<bool>();
            }
            const sum = checkedAddU64(totalDimensionality, numComponents);
            if (sum == U64_NONE) {
                return DracoError.general("The attributes' components overflow a usize in total").fail<bool>();
            }
            totalDimensionality = sum;
        }
        if (totalDimensionality == 0) {
            return DracoError.general("The KD-tree attributes have no components between them").fail<bool>();
        }

        if (totalDimensionality > <u64>u32.MAX_VALUE) {
            return DracoError.general(
                "Total dimensionality " + totalDimensionality.toString() + " does not fit the coder's u32",
            ).fail<bool>();
        }
        const decoder = new DynamicIntegerPointsKdTreeDecoder(compressionLevel, <u32>totalDimensionality);
        const rd = decoder.decodePoints(inBuffer, <u32>numExpectedPoints);
        if (!rd.ok) return rd.forward<bool>();
        const decoded = rd.value;
        if (<u64>decoder.numDecodedPoints() != numExpectedPoints) {
            return DracoError.general(
                "KD-tree produced " + decoder.numDecodedPoints().toString() + " points against the " +
                numExpectedPoints.toString() + " the header declares",
            ).fail<bool>();
        }
        const expectedDecodedLen = checkedMulU64(numExpectedPoints, totalDimensionality);
        if (expectedDecodedLen == U64_NONE) {
            return DracoError.general("Point count times dimensionality overflows a usize").fail<bool>();
        }
        if (<u64>decoded.length != expectedDecodedLen) {
            return DracoError.general(
                "KD-tree produced " + decoded.length.toString() + " values against the " + expectedDecodedLen.toString() +
                " expected",
            ).fail<bool>();
        }

        // The attribute buffers are taken now that the values exist.
        for (let i = 0; i < this.attributeIds.length; i++) {
            const attId = this.attributeIds[i];
            const ra = pointCloud.tryAttributeMut(attId);
            if (!ra.ok) return ra.forward<bool>();
            const att = ra.value;
            const byteStride = att.byteStride();
            if (byteStride < 0) {
                return DracoError.general("Attribute " + attId.toString() + " has a negative byte stride").fail<bool>();
            }
            const required = checkedMulU64(<u64>att.size(), <u64>byteStride);
            if (required == U64_NONE) {
                return DracoError.general("Attribute " + attId.toString() + "'s buffer size overflows a usize").fail<bool>();
            }
            if (<u64>att.buffer().dataSize() < required) {
                if (!att.bufferMut().tryResize(required).ok) {
                    return DracoError.allocationExceedsInput(required, <u64>decoded.length * 4).fail<bool>();
                }
            }
        }

        // Portable copies for the float attributes.
        for (let i = 0; i < floatSpecs.length; i++) {
            const fs = floatSpecs[i];
            const ra = pointCloud.tryAttribute(fs.attId);
            if (!ra.ok) return ra.forward<bool>();
            const att = ra.value;
            const portable = new PointAttribute();
            const si = portable.tryInit(att.attributeType(), att.numComponents(), DataType.Uint32, false, numExpectedPoints);
            if (!si.ok) return si;
            portable.setIdentityMapping();

            const sw = writeU32ComponentsFromDecoded(
                decoded,
                totalDimensionality,
                fs.offset,
                fs.numComponents,
                numExpectedPoints,
                portable,
                DataType.Uint32,
            );
            if (!sw.ok) return statusContext(sw, "Portable copy of attribute " + fs.attId.toString());

            this.quantizedPortableAttributes.push(portable);
        }

        // The unsigned attributes, written directly.
        for (let i = 0; i < this.attributeSpecs.length; i++) {
            const spec = this.attributeSpecs[i];
            if (spec.dataType == DataType.Uint32 || spec.dataType == DataType.Uint16 || spec.dataType == DataType.Uint8) {
                const attId = spec.attId;
                const ra = pointCloud.tryAttributeMut(attId);
                if (!ra.ok) return ra.forward<bool>();
                const sw = writeU32ComponentsFromDecoded(
                    decoded,
                    totalDimensionality,
                    spec.offset,
                    spec.numComponents,
                    numExpectedPoints,
                    ra.value,
                    spec.dataType,
                );
                if (!sw.ok) return statusContext(sw, "Attribute " + attId.toString());
            }
        }

        // Kept for the signed pass.
        this.cachedDecoded = new CachedDecoded(decoded, totalDimensionality);

        return okStatus();
    }

    decodeDataNeededByPortableTransforms(pointCloud: PointCloud, inBuffer: DecoderBuffer): Status {
        // Float quantization parameters in attribute order.
        for (let i = 0; i < this.attributeIds.length; i++) {
            const attId = this.attributeIds[i];
            const ra = pointCloud.tryAttribute(attId);
            if (!ra.ok) return ra.forward<bool>();
            const att = ra.value;
            if (att.dataType() == DataType.Float32) {
                const nc = <i32>att.numComponents();
                const minValues = new Array<f32>(nc);
                for (let component = 0; component < nc; component++) {
                    const rv = inBuffer.decode<f32>();
                    if (!rv.ok) {
                        return DracoError.buffer(
                            "Buffer ran out reading minimum " + component.toString() + " of attribute " + attId.toString(),
                        ).fail<bool>();
                    }
                    minValues[component] = rv.value;
                }
                const rr = inBuffer.decode<f32>();
                if (!rr.ok) {
                    return DracoError.buffer(
                        "Buffer ran out reading the quantization range of attribute " + attId.toString(),
                    ).fail<bool>();
                }
                const range = rr.value;
                const rb = inBuffer.decodeU8();
                if (!rb.ok) {
                    return DracoError.buffer(
                        "Buffer ran out reading the quantization bits of attribute " + attId.toString(),
                    ).fail<bool>();
                }
                const bits = rb.value;
                if (bits > 31) {
                    return DracoError.general(
                        "Attribute " + attId.toString() + " declares " + bits.toString() +
                        " quantization bits, above the 31 a u32 holds",
                    ).fail<bool>();
                }
                const t = new AttributeQuantizationTransform();
                const sp = t.setParameters(<i32>bits, minValues, range);
                if (!sp.ok) return sp;
                this.attributeQuantizationTransforms.push(t);
            }
        }

        // Signed minimum values.
        for (let i = 0; i < this.minSignedValues.length; i++) {
            const rv = inBuffer.decodeVarintSignedI32();
            if (!rv.ok) {
                return DracoError.buffer(
                    "Buffer ran out reading signed minimum " + i.toString() + " of " + this.minSignedValues.length.toString(),
                ).fail<bool>();
            }
            this.minSignedValues[i] = rv.value;
        }

        return okStatus();
    }

    transformAttributesToOriginalFormat(pointCloud: PointCloud): Status {
        const cached = this.cachedDecoded;
        this.cachedDecoded = null;
        if (cached == null) {
            return DracoError.general(
                "No decoded KD-tree points to transform: the portable decode did not run",
            ).fail<bool>();
        }

        // Floats.
        let floatAttrIndex = 0;
        for (let i = 0; i < this.attributeIds.length; i++) {
            const attId = this.attributeIds[i];
            const ra = pointCloud.tryAttribute(attId);
            if (!ra.ok) return ra.forward<bool>();
            const dt = ra.value.dataType();
            if (dt == DataType.Float32) {
                if (floatAttrIndex >= this.quantizedPortableAttributes.length) {
                    return DracoError.general(
                        "Attribute " + attId.toString() + " has no portable copy at index " + floatAttrIndex.toString(),
                    ).fail<bool>();
                }
                const portable = this.quantizedPortableAttributes[floatAttrIndex];
                if (floatAttrIndex >= this.attributeQuantizationTransforms.length) {
                    return DracoError.general(
                        "Attribute " + attId.toString() + " has no quantization parameters at index " +
                        floatAttrIndex.toString(),
                    ).fail<bool>();
                }
                const transform = this.attributeQuantizationTransforms[floatAttrIndex];

                const rt = pointCloud.tryAttributeMut(attId);
                if (!rt.ok) return rt.forward<bool>();
                const s = transform.inverseTransformAttribute(portable, rt.value);
                if (!s.ok) return s;

                floatAttrIndex += 1;
            }
        }

        // Signed integers.
        let minIndex: u64 = 0;
        for (let si = 0; si < this.signedAttributeSpecs.length; si++) {
            const spec = this.signedAttributeSpecs[si];
            const ra = pointCloud.tryAttributeMut(spec.attId);
            if (!ra.ok) return ra.forward<bool>();
            const att = ra.value;
            const numPoints = att.size();
            if (numPoints == 0) {
                continue;
            }

            // The stride reinterpreted as u64 (a negative stride becomes huge).
            const stride = <u64>att.byteStride();
            const componentSize = <u64>dataTypeByteLength(att.dataType());

            // The buffer is not resized below: its bytes are fetched once.
            const dstBuffer = att.bufferMut();
            const dst = dstBuffer.dataMut();
            for (let p = 0; p < numPoints; p++) {
                const avi = att.mappedIndex(<u32>p);
                const base = checkedMulU64(<u64>avi, stride);
                if (base == U64_NONE) {
                    return DracoError.general("A signed attribute's value offset overflows a usize").fail<bool>();
                }
                for (let c: u64 = 0; c < spec.numComponents; c++) {
                    const a = checkedMulU64(<u64>p, cached.totalDimensionality);
                    const b = a == U64_NONE ? U64_NONE : checkedAddU64(a, spec.offset);
                    const decodedIndex = b == U64_NONE ? U64_NONE : checkedAddU64(b, c);
                    if (decodedIndex == U64_NONE) {
                        return DracoError.general("A decoded value index overflows a usize").fail<bool>();
                    }
                    if (decodedIndex >= <u64>cached.decoded.length) {
                        return DracoError.general(
                            "Point " + p.toString() + " component " + c.toString() + " reads past the " +
                            cached.decoded.length.toString() + " decoded values",
                        ).fail<bool>();
                    }
                    const unsigned = cached.decoded[<i32>decodedIndex];
                    const minPos = minIndex + c;
                    if (minPos >= <u64>this.minSignedValues.length) {
                        return DracoError.general(
                            "No signed minimum at index " + minPos.toString() + " of " +
                            this.minSignedValues.length.toString(),
                        ).fail<bool>();
                    }
                    const minValue = this.minSignedValues[<i32>minPos];
                    const signed = <i64>unsigned + <i64>minValue;
                    const delta = checkedMulU64(c, componentSize);
                    const componentOffset = delta == U64_NONE ? U64_NONE : checkedAddU64(base, delta);
                    if (componentOffset == U64_NONE) {
                        return DracoError.general("A component offset overflows a usize").fail<bool>();
                    }
                    if (!writeSignedInto(dst, componentOffset, spec.dataType, signed)) {
                        const sw = signedWriteError(dstBuffer, componentOffset, spec.dataType);
                        return statusContext(sw, "Point " + p.toString() + " component " + c.toString());
                    }
                }
            }
            minIndex += spec.numComponents;
        }

        return okStatus();
    }
}

// Writes `numComponents` decoded values per point, from column `offset` of
// the decoded rows, into `targetAttribute` as `targetType` (little-endian).
export function writeU32ComponentsFromDecoded(
    decoded: Array<u32>,
    totalDimensionality: u64,
    offset: u64,
    numComponents: u64,
    numPoints: u64,
    targetAttribute: PointAttribute,
    targetType: DataType,
): Status {
    // The stride reinterpreted as u64.
    const stride = <u64>targetAttribute.byteStride();
    const componentSize = <u64>dataTypeByteLength(targetType);
    const rowBytes = checkedMulU64(numComponents, componentSize);
    if (rowBytes == U64_NONE) {
        return DracoError.general("Attribute row size overflows a usize").fail<bool>();
    }

    // The buffer is not resized here: its bytes are fetched once.
    const data = targetAttribute.bufferMut().dataMut();
    for (let p: u64 = 0; p < numPoints; p++) {
        const avi = targetAttribute.mappedIndex(<u32>p);
        const base = checkedMulU64(<u64>avi, stride);
        if (base == U64_NONE) {
            return DracoError.general("Point " + p.toString() + "'s value offset overflows a usize").fail<bool>();
        }
        const rowEnd = checkedAddU64(base, rowBytes);
        if (rowEnd == U64_NONE) {
            return DracoError.general("Point " + p.toString() + "'s row end overflows a usize").fail<bool>();
        }

        const m = checkedMulU64(p, totalDimensionality);
        const srcStart = m == U64_NONE ? U64_NONE : checkedAddU64(m, offset);
        if (srcStart == U64_NONE) {
            return DracoError.general("Point " + p.toString() + " indexes past what a usize holds").fail<bool>();
        }
        const srcEnd = checkedAddU64(srcStart, numComponents);
        if (srcEnd == U64_NONE) {
            return DracoError.general("Point " + p.toString() + "'s component run overflows a usize").fail<bool>();
        }
        if (srcEnd > <u64>decoded.length) {
            return DracoError.general(
                "Point " + p.toString() + " reads " + srcStart.toString() + ".." + srcEnd.toString() + " of " +
                decoded.length.toString() + " decoded values",
            ).fail<bool>();
        }

        if (rowEnd > <u64>data.length) {
            return DracoError.general(
                "Point " + p.toString() + " writes " + base.toString() + ".." + rowEnd.toString() +
                " past the attribute buffer",
            ).fail<bool>();
        }

        const o = <i32>base;
        const s = <i32>srcStart;
        const n = <i32>numComponents;
        switch (targetType) {
            case DataType.Uint8: {
                for (let i = 0; i < n; i++) unchecked((data[o + i] = <u8>unchecked(decoded[s + i])));
                break;
            }
            case DataType.Uint16: {
                for (let i = 0; i < n; i++) {
                    const v = <u16>unchecked(decoded[s + i]);
                    unchecked((data[o + 2 * i] = <u8>v));
                    unchecked((data[o + 2 * i + 1] = <u8>(v >> 8)));
                }
                break;
            }
            case DataType.Uint32: {
                for (let i = 0; i < n; i++) {
                    const v = unchecked(decoded[s + i]);
                    unchecked((data[o + 4 * i] = <u8>v));
                    unchecked((data[o + 4 * i + 1] = <u8>(v >> 8)));
                    unchecked((data[o + 4 * i + 2] = <u8>(v >> 16)));
                    unchecked((data[o + 4 * i + 3] = <u8>(v >> 24)));
                }
                break;
            }
            default:
                break;
        }
    }
    return okStatus();
}

// Writes one signed value at `offset` as `dataType` (little-endian); a buffer
// error when it lands past the end. Other types write nothing.
export function writeSignedComponent(buffer: DataBuffer, offset: u64, dataType: DataType, value: i64): Status {
    if (writeSignedInto(buffer.dataMut(), offset, dataType, value)) {
        return okStatus();
    }
    return signedWriteError(buffer, offset, dataType);
}

function signedWriteError(buffer: DataBuffer, offset: u64, dataType: DataType): Status {
    return DracoError.buffer(
        "Write of " + dataTypeDebug(dataType) + " at byte " + offset.toString() + " lands past the attribute buffer's " +
        buffer.dataSize().toString() + " bytes",
    ).fail<bool>();
}

// Writes `value` narrowed to the signed type, little-endian, straight into
// the buffer's bytes (no scratch array per component): false when the write
// would end past them. Types other than Int8/16/32 write nothing (true).
function writeSignedInto(data: Uint8Array, offset: u64, dataType: DataType, value: i64): bool {
    let width: u64 = 0;
    switch (dataType) {
        case DataType.Int8:
            width = 1;
            break;
        case DataType.Int16:
            width = 2;
            break;
        case DataType.Int32:
            width = 4;
            break;
        default:
            return true;
    }
    if (offset > u64.MAX_VALUE - width || offset + width > <u64>data.length) {
        return false;
    }
    const o = <i32>offset;
    const v = <u32><i32>value;
    unchecked((data[o] = <u8>v));
    if (width >= 2) unchecked((data[o + 1] = <u8>(v >> 8)));
    if (width == 4) {
        unchecked((data[o + 2] = <u8>(v >> 16)));
        unchecked((data[o + 3] = <u8>(v >> 24)));
    }
    return true;
}
