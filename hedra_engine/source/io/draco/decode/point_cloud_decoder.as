// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Decoder for Draco point-cloud bitstreams. Reads a point-cloud `.drc` stream
// and rebuilds a PointCloud with its attributes and metadata. Both the KD-tree
// (method 1) and the sequential attribute encodings are decoded.

import { DecoderBuffer } from "../core/decoder_buffer";
import { DataType, dataTypeByteLength, dataTypeTryFrom } from "../core/draco_types";
import { DracoError, Status, okStatus } from "../core/status";
import { VERSION_FLAGS_INTRODUCED, bitstreamVersion as packBitstreamVersion, versionAtLeast } from "../core/version";
import { AttributeOctahedronTransform } from "../geometry/attribute_octahedron_transform";
import { AttributeQuantizationTransform } from "../geometry/attribute_quantization_transform";
import { U64_NONE, checkedMulU64 } from "../geometry/bytes";
import { EncodedGeometryType } from "../geometry/compression_config";
import {
    GeometryAttributeType,
    PointAttribute,
    geometryAttributeTypeTryFrom,
} from "../geometry/geometry_attribute";
import { GeometryMetadata, METADATA_FLAG_MASK } from "../geometry/metadata";
import { PointCloud } from "../geometry/point_cloud";
import { EntryToPointIdMap } from "../prediction/prediction_scheme";
import { KdTreeAttributesDecoder } from "./kd_tree_attributes_decoder";
import { SequentialGenericAttributeDecoder } from "./sequential_generic_attribute_decoder";
import { PortableExtent, SequentialIntegerAttributeDecoder, withContext } from "./sequential_integer_attribute_decoder";
import { SequentialNormalAttributeDecoder } from "./sequential_normal_attribute_decoder";
import { SequentialQuantizationAttributeDecoder } from "./sequential_quantization_attribute_decoder";

// Whether a prediction transform byte follows this prediction method byte.
//
// Upstream writes the transform only when the method is not PREDICTION_NONE
// (-2, 0xFE on the wire); 0xFF (-1) was once written for the same meaning,
// so both read as "nothing follows". The pre-2.0 shims in the normal and
// quantization decoders walk the prediction header by hand with this.
export function carriesTransformByte(methodByte: u8): bool {
    return methodByte != 0xff && methodByte != 0xfe;
}

// Each attribute needs at least type, data type, component count, normalized
// flag, unique id and a decoder type byte: refuse impossible counts before
// reserving anything from untrusted input.
export function validateNumAttributesInDecoder(numAttributesInDecoder: u64, remainingBytes: u64): Status {
    const MIN_ATTRIBUTE_BYTES: u64 = 6;
    if (numAttributesInDecoder == 0 || numAttributesInDecoder > remainingBytes / MIN_ATTRIBUTE_BYTES) {
        return DracoError.general("Invalid number of attributes").fail<bool>();
    }
    return okStatus();
}

export function validateNumComponents(numComponents: u8): Status {
    if (numComponents == 0) {
        return DracoError.general("Invalid attribute component count").fail<bool>();
    }
    return okStatus();
}

// The decoded description of one attribute.
class AttributeSpec {
    attType: GeometryAttributeType;
    dataType: DataType;
    numComponents: u8;
    normalized: bool;
    uniqueId: u32;

    constructor(attType: GeometryAttributeType, dataType: DataType, numComponents: u8, normalized: bool, uniqueId: u32) {
        this.attType = attType;
        this.dataType = dataType;
        this.numComponents = numComponents;
        this.normalized = normalized;
        this.uniqueId = uniqueId;
    }
}

// A quantized attribute waiting for its inverse transform.
export class PendingQuant {
    attId: i32;
    portable: PointAttribute;
    transform: AttributeQuantizationTransform;

    constructor(attId: i32, portable: PointAttribute, transform: AttributeQuantizationTransform) {
        this.attId = attId;
        this.portable = portable;
        this.transform = transform;
    }
}

// An octahedral normal waiting for its inverse transform.
export class PendingNormal {
    attId: i32;
    portable: PointAttribute;
    quantizationBits: u8;

    constructor(attId: i32, portable: PointAttribute, quantizationBits: u8) {
        this.attId = attId;
        this.portable = portable;
        this.quantizationBits = quantizationBits;
    }
}

export function findPendingQuant(pending: Array<PendingQuant>, attId: i32): i32 {
    for (let i = 0; i < pending.length; i++) {
        if (pending[i].attId == attId) return i;
    }
    return -1;
}

export function findPendingNormal(pending: Array<PendingNormal>, attId: i32): i32 {
    for (let i = 0; i < pending.length; i++) {
        if (pending[i].attId == attId) return i;
    }
    return -1;
}

export class PointCloudDecoder {
    private geometryType: EncodedGeometryType = EncodedGeometryType.PointCloud;
    private method: u8 = 0;
    private flags: u16 = 0;
    private versionMajor: u8 = 0;
    private versionMinor: u8 = 0;

    constructor() {}

    // The packed bitstream version (`0xMMmm`), 0 before a header was read.
    bitstreamVersion(): u16 {
        return packBitstreamVersion(this.versionMajor, this.versionMinor);
    }

    // Carries the version to a decoder that did not read the header itself.
    setBitstreamVersion(major: u8, minor: u8): void {
        this.versionMajor = major;
        this.versionMinor = minor;
    }

    // Decodes a Draco point cloud from `inBuffer` into `outPc`, replacing
    // whatever it held.
    decode(inBuffer: DecoderBuffer, outPc: PointCloud): Status {
        outPc.clear();

        // 1. Decode Header
        const sh = this.decodeHeader(inBuffer);
        if (!sh.ok) return sh;

        if (
            versionAtLeast(this.versionMajor, this.versionMinor, VERSION_FLAGS_INTRODUCED) &&
            (this.flags & METADATA_FLAG_MASK) != 0
        ) {
            const rm = GeometryMetadata.decode(inBuffer);
            if (!rm.ok) {
                return DracoError.general("Failed to decode metadata").fail<bool>();
            }
            outPc.setMetadata(rm.value);
        }

        // 2. Decode Geometry Data
        return this.decodeGeometryData(inBuffer, outPc);
    }

    // Decodes point cloud data when the header and metadata were already
    // parsed (MeshDecoder delegates point-cloud streams here).
    decodeAfterHeader(versionMajor: u8, versionMinor: u8, method: u8, buffer: DecoderBuffer, outPc: PointCloud): Status {
        this.versionMajor = versionMajor;
        this.versionMinor = versionMinor;
        this.method = method;
        this.flags = 0;
        this.geometryType = EncodedGeometryType.PointCloud;
        return this.decodeGeometryData(buffer, outPc);
    }

    private decodeHeader(buffer: DecoderBuffer): Status {
        const magic = new Uint8Array(5);
        const sm = buffer.decodeBytes(magic);
        if (!sm.ok) return sm;
        if (!isDracoMagic(magic)) {
            return DracoError.general("Invalid magic").fail<bool>();
        }

        const rmaj = buffer.decodeU8();
        if (!rmaj.ok) return rmaj.forward<bool>();
        this.versionMajor = rmaj.value;
        const rmin = buffer.decodeU8();
        if (!rmin.ok) return rmin.forward<bool>();
        this.versionMinor = rmin.value;
        buffer.setVersion(this.versionMajor, this.versionMinor);

        const rg = buffer.decodeU8();
        if (!rg.ok) return rg.forward<bool>();
        const gType = rg.value;
        if (gType == 0) {
            this.geometryType = EncodedGeometryType.PointCloud;
        } else if (gType == 1) {
            this.geometryType = EncodedGeometryType.TriangularMesh;
        } else {
            return DracoError.general("Invalid geometry type").fail<bool>();
        }
        if (this.geometryType != EncodedGeometryType.PointCloud) {
            return DracoError.general("PointCloudDecoder cannot decode mesh bitstreams").fail<bool>();
        }

        const rmeth = buffer.decodeU8();
        if (!rmeth.ok) return rmeth.forward<bool>();
        this.method = rmeth.value;

        // The flags field is always present in the binary header.
        const rf = buffer.decodeU16();
        if (!rf.ok) {
            return DracoError.general("Failed to decode flags").fail<bool>();
        }
        this.flags = rf.value;

        return okStatus();
    }

    private decodeGeometryData(buffer: DecoderBuffer, pc: PointCloud): Status {
        const bitstreamVersion_: u16 = packBitstreamVersion(this.versionMajor, this.versionMinor);
        // The point count is a fixed-width int32 for both sequential and
        // KD-tree encodings, refused when negative (as upstream does).
        const rp = buffer.decodeU32();
        if (!rp.ok) return rp.forward<bool>();
        const declaredPoints = <i32>rp.value;
        if (declaredPoints < 0) {
            return DracoError.general("Point cloud declares " + declaredPoints.toString() + " points").fail<bool>();
        }
        const numPoints = declaredPoints;
        const sc = buffer.checkPoints(<u64>numPoints);
        if (!sc.ok) return sc;
        pc.setNumPoints(numPoints);

        const rn = buffer.decodeU8();
        if (!rn.ok) return rn.forward<bool>();
        const numAttributesDecoders = <i32>rn.value;

        if (this.method == 1) {
            // KD-tree encoding.
            for (let d = 0; d < numAttributesDecoders; d++) {
                const attDecoder = new KdTreeAttributesDecoder(0);
                const s1 = attDecoder.decodeAttributesDecoderData(pc, buffer);
                if (!s1.ok) return withContext<bool>(s1, "Failed to decode attribute metadata");
                const s2 = attDecoder.decodeAttributes(pc, buffer);
                if (!s2.ok) return withContext<bool>(s2, "Failed to decode attributes");
            }
            return okStatus();
        }

        // Sequential encoding.
        for (let d = 0; d < numAttributesDecoders; d++) {
            let numAttributesInDecoder: u64;
            if (bitstreamVersion_ < 0x0200) {
                const r = buffer.decodeU32();
                if (!r.ok) return r.forward<bool>();
                numAttributesInDecoder = <u64>r.value;
            } else {
                const r = buffer.decodeVarint();
                if (!r.ok) return r.forward<bool>();
                numAttributesInDecoder = r.value;
            }
            if (numAttributesInDecoder == 0) {
                return DracoError.general("Invalid number of attributes").fail<bool>();
            }
            const sv = validateNumAttributesInDecoder(numAttributesInDecoder, <u64>buffer.remainingSize());
            if (!sv.ok) return sv;
            const count = <i32>numAttributesInDecoder;

            const attributeSpecs = new Array<AttributeSpec>();
            const attIds = new Array<i32>();
            const decoderTypes = new Array<u8>();
            const pendingQuant = new Array<PendingQuant>();
            const pendingNormals = new Array<PendingNormal>();

            for (let i = 0; i < count; i++) {
                const rt = buffer.decodeU8();
                if (!rt.ok) return rt.forward<bool>();
                const rat = geometryAttributeTypeTryFrom(rt.value);
                if (!rat.ok) return rat.forward<bool>();

                const rd = buffer.decodeU8();
                if (!rd.ok) return rd.forward<bool>();
                const rdt = dataTypeTryFrom(rd.value);
                if (!rdt.ok) return rdt.forward<bool>();

                const rc = buffer.decodeU8();
                if (!rc.ok) return rc.forward<bool>();
                const numComponents = rc.value;
                const sn = validateNumComponents(numComponents);
                if (!sn.ok) return sn;
                const rnorm = buffer.decodeU8();
                if (!rnorm.ok) return rnorm.forward<bool>();
                const normalized = rnorm.value != 0;
                let uniqueId: u32;
                if (bitstreamVersion_ < 0x0103) {
                    const r = buffer.decodeU16();
                    if (!r.ok) return r.forward<bool>();
                    uniqueId = <u32>r.value;
                } else {
                    const r = buffer.decodeVarint();
                    if (!r.ok) return r.forward<bool>();
                    uniqueId = <u32>r.value;
                }

                attributeSpecs.push(new AttributeSpec(rat.value, rdt.value, numComponents, normalized, uniqueId));
            }

            for (let i = 0; i < count; i++) {
                const r = buffer.decodeU8();
                if (!r.ok) return r.forward<bool>();
                decoderTypes.push(r.value);
            }

            for (let localI = 0; localI < attributeSpecs.length; localI++) {
                const spec = attributeSpecs[localI];
                if (decoderTypes[localI] == 0) {
                    const entrySize = <u64>spec.numComponents * <u64>dataTypeByteLength(spec.dataType);
                    const bytesNeeded = checkedMulU64(entrySize, <u64>numPoints);
                    if (bytesNeeded == U64_NONE) {
                        return DracoError.general("Raw point cloud attribute byte count overflow").fail<bool>();
                    }
                    if (<u64>buffer.remainingSize() < bytesNeeded) {
                        return DracoError.general("Not enough data for raw point cloud attribute values").fail<bool>();
                    }
                }

                const charged = satMulU64(
                    satMulU64(<u64>spec.numComponents, <u64>dataTypeByteLength(spec.dataType)),
                    <u64>numPoints,
                );
                const sb = buffer.chargeDecodedBytes(charged);
                if (!sb.ok) return sb;
                // The buffer is left unreserved: whichever decoder writes the
                // values sizes it once they exist.
                const att = new PointAttribute();
                const si = att.initDeferred(spec.attType, spec.numComponents, spec.dataType, spec.normalized, <u64>numPoints);
                if (!si.ok) return si;
                att.setUniqueId(spec.uniqueId);
                const attId = pc.addAttributePreserveUniqueId(att);
                attIds.push(attId);
            }

            // The identity, not written out (entry i is point i).
            let anyNonGeneric = false;
            for (let i = 0; i < decoderTypes.length; i++) {
                if (decoderTypes[i] != 0) anyNonGeneric = true;
            }
            const pointIds: EntryToPointIdMap? = anyNonGeneric ? EntryToPointIdMap.identity(numPoints) : null;

            for (let localI = 0; localI < attIds.length; localI++) {
                const attId = attIds[localI];
                const decoderType = decoderTypes[localI];
                switch (decoderType) {
                    case 1: {
                        if (pointIds == null) {
                            return DracoError.general("Point ids missing for integer attribute decoder").fail<bool>();
                        }
                        const attDecoder = new SequentialIntegerAttributeDecoder();
                        attDecoder.init(this, attId);
                        const s = attDecoder.decodeValues(pc, pointIds, buffer, null, null, null, null, null, null);
                        if (!s.ok) return s;
                        break;
                    }
                    case 2: {
                        const attDecoder = new SequentialQuantizationAttributeDecoder();
                        const si = attDecoder.init(this, pc, attId);
                        if (!si.ok) return si;
                        if (pointIds == null) {
                            return DracoError.general("Point ids missing for quantized attribute decoder").fail<bool>();
                        }
                        const rv = attDecoder.decodeValues(
                            pc,
                            pointIds,
                            buffer,
                            bitstreamVersion_,
                            PortableExtent.declared(<u64>numPoints),
                            null,
                            null,
                            null,
                            null,
                        );
                        if (!rv.ok) return rv.forward<bool>();
                        pendingQuant.push(new PendingQuant(attId, rv.value, attDecoder.intoTransform()));
                        break;
                    }
                    case 3: {
                        const attDecoder = new SequentialNormalAttributeDecoder();
                        const si = attDecoder.init(this, pc, attId);
                        if (!si.ok) return si;
                        if (pointIds == null) {
                            return DracoError.general("Point ids missing for normal attribute decoder").fail<bool>();
                        }
                        const rv = attDecoder.decodeValues(
                            pc,
                            pointIds,
                            buffer,
                            bitstreamVersion_,
                            PortableExtent.declared(<u64>numPoints),
                            null,
                            null,
                            null,
                            null,
                        );
                        if (!rv.ok) return rv.forward<bool>();
                        pendingNormals.push(new PendingNormal(attId, rv.value, attDecoder.quantizationBits()));
                        break;
                    }
                    case 0: {
                        // The values are copied verbatim, in order: the
                        // identity map is all this decoder reads.
                        const attDecoder = new SequentialGenericAttributeDecoder();
                        attDecoder.init(this, attId);
                        const s = attDecoder.decodeValues(pc, EntryToPointIdMap.identity(numPoints), buffer);
                        if (!s.ok) return s;
                        break;
                    }
                    default:
                        return DracoError.general("Unsupported sequential decoder type: " + decoderType.toString()).fail<bool>();
                }
            }

            for (let localI = 0; localI < attIds.length; localI++) {
                const attId = attIds[localI];
                const decoderType = decoderTypes[localI];
                if (decoderType == 2 && bitstreamVersion_ >= 0x0200) {
                    const idx = findPendingQuant(pendingQuant, attId);
                    if (idx < 0) {
                        return DracoError.general("Missing pending quantized attribute transform").fail<bool>();
                    }
                    const ro = pc.tryAttribute(attId);
                    if (!ro.ok) return ro.forward<bool>();
                    const sp = pendingQuant[idx].transform.decodeParameters(ro.value, buffer);
                    if (!sp.ok) {
                        return DracoError.general("Failed to decode quantization parameters: " + sp.err).fail<bool>();
                    }
                } else if (decoderType == 3 && bitstreamVersion_ >= 0x0200) {
                    const idx = findPendingNormal(pendingNormals, attId);
                    if (idx < 0) {
                        return DracoError.general("Missing pending normal attribute transform").fail<bool>();
                    }
                    const rq = buffer.decodeU8();
                    if (!rq.ok) return rq.forward<bool>();
                    const quantizationBits = rq.value;
                    if (!AttributeOctahedronTransform.isValidQuantizationBits(<i32>quantizationBits)) {
                        return DracoError.general("Invalid normal quantization bits").fail<bool>();
                    }
                    pendingNormals[idx].quantizationBits = quantizationBits;
                }
            }

            for (let i = 0; i < pendingQuant.length; i++) {
                const q = pendingQuant[i];
                const rd = pc.tryAttributeMut(q.attId);
                if (!rd.ok) return rd.forward<bool>();
                const s = q.transform.inverseTransformAttribute(q.portable, rd.value);
                if (!s.ok) {
                    return DracoError.general("Failed to dequantize attribute: " + s.err).fail<bool>();
                }
            }
            for (let i = 0; i < pendingNormals.length; i++) {
                const n = pendingNormals[i];
                const oct = new AttributeOctahedronTransform(-1);
                const sp = oct.setParameters(<i32>n.quantizationBits);
                if (!sp.ok) return sp;
                const rd = pc.tryAttributeMut(n.attId);
                if (!rd.ok) return rd.forward<bool>();
                const s = oct.inverseTransformAttributeWithLegacyOctahedron(n.portable, rd.value, bitstreamVersion_ < 0x0200);
                if (!s.ok) {
                    return DracoError.general("Failed to decode normals: " + s.err).fail<bool>();
                }
            }
        }

        return okStatus();
    }

    // The encoded geometry type handled by this decoder.
    getGeometryType(): EncodedGeometryType {
        return this.geometryType;
    }
}

// `&magic == b"DRACO"`.
export function isDracoMagic(magic: Uint8Array): bool {
    return (
        magic.length == 5 &&
        magic[0] == 0x44 &&
        magic[1] == 0x52 &&
        magic[2] == 0x41 &&
        magic[3] == 0x43 &&
        magic[4] == 0x4f
    );
}

// a * b, saturating at u64::MAX.
export function satMulU64(a: u64, b: u64): u64 {
    if (a == 0 || b == 0) return 0;
    if (a > u64.MAX_VALUE / b) return u64.MAX_VALUE;
    return a * b;
}
