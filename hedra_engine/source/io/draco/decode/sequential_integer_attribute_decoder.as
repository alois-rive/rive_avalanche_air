// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The integer sequential attribute decoder (Draco's
// `sequential_integer_attribute_decoder.h`). It decodes integer (and quantized
// portable) attribute values, applying the inverse prediction scheme the
// bitstream selected to rebuild each value from its predecessors -- the decode
// workhorse for positions, texture coordinates and other quantized attributes.
//
// Notes:
//   - The selected predictor is one `PredictionSchemeDecoder?` (the Difference arm picks the octahedron
//     or the wrap transform when it builds it); the order of every read, check
//     and error is unchanged.
//   - The optional pre-integer-decode hook is a `PreIntegerDecodeHook` object.
//   - Values live in one Int32Array; counts derived from the stream are u64.

import { Result } from "../../../../base/util";
import { BYTE_VEC_MAX_CAPACITY } from "../core/byte_vec";
import { DataBuffer } from "../core/data_buffer";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DataType, dataTypeByteLength } from "../core/draco_types";
import { DracoError, Status, dracoErrorOf, okStatus } from "../core/status";
import { U64_NONE, checkedAddU64, checkedMulU64 } from "../geometry/bytes";
import { GeometryAttributeType, PointAttribute } from "../geometry/geometry_attribute";
import { CornerIndex, INVALID_CORNER_INDEX } from "../geometry/geometry_indices";
import { PointCloud } from "../geometry/point_cloud";
import { PredictionParent } from "../geometry/portable_attribute";
import { CornerTable } from "../mesh/corner_table";
import { MeshPredictionSchemeData } from "../mesh/mesh_prediction_scheme_data";
import { SymbolEncodingOptions, decodeSymbols } from "../entropy/symbol_encoding";
import {
    EntryToPointIdMap,
    EntryToPointIdMapKind,
    PredictionSchemeDecoder,
    PredictionSchemeMethod,
    PredictionSchemeTransformType,
    predictionSchemeMethodDebug,
    predictionSchemeMethodTryFrom,
    predictionSchemeTransformTypeTryFrom,
} from "../prediction/prediction_scheme";
import { MeshPredictionSchemeConstrainedMultiParallelogramDecoder } from "../prediction/prediction_scheme_constrained_multi_parallelogram";
import { PredictionSchemeDeltaDecoder } from "../prediction/prediction_scheme_delta";
import { MeshPredictionSchemeGeometricNormalDecoder } from "../prediction/prediction_scheme_geometric_normal";
import { MeshPredictionSchemeMultiParallelogramDecoder } from "../prediction/prediction_scheme_multi_parallelogram";
import { PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform } from "../prediction/prediction_scheme_normal_octahedron_canonicalized_decoding_transform";
import { MeshPredictionSchemeParallelogramDecoder } from "../prediction/prediction_scheme_parallelogram";
import { MeshPredictionSchemeTexCoordsDeprecatedDecoder } from "../prediction/prediction_scheme_tex_coords_deprecated";
import { MeshPredictionSchemeTexCoordsPortableDecoder } from "../prediction/prediction_scheme_tex_coords_portable";
import { PredictionSchemeWrapDecodingTransform } from "../prediction/prediction_scheme_wrap";
import { PointCloudDecoder } from "./point_cloud_decoder";

// How a portable attribute may be sized before a value has been read: from
// a decoded count or from a declared one.
//
// The two geometry decoders answer this differently and both are right: a
// mesh's point-id list comes out of the decoded corner table, so its length
// is backed by data, while a point cloud has only the count the header states.
export enum PortableExtentKind {
    // A count the connectivity already produced; reserve it in one go.
    Decoded,
    // A count nothing has backed yet; let the buffer grow as values arrive.
    Declared,
}

export class PortableExtent {
    kind: PortableExtentKind;
    size: u64;

    constructor(kind: PortableExtentKind, size: u64) {
        this.kind = kind;
        this.size = size;
    }

    static decoded(size: u64): PortableExtent {
        return new PortableExtent(PortableExtentKind.Decoded, size);
    }

    static declared(size: u64): PortableExtent {
        return new PortableExtent(PortableExtentKind.Declared, size);
    }

    // The extent of the values a point-id map describes: the identity is a
    // number the stream declared, the array variants are counts something
    // already produced.
    static of(map: EntryToPointIdMap): PortableExtent {
        if (map.kind == EntryToPointIdMapKind.Identity) {
            return PortableExtent.declared(<u64>map.numPoints);
        }
        return PortableExtent.decoded(<u64>map.len());
    }

    // Initializes `portable` to hold values of this shape, reserving or
    // deferring according to what backs the count.
    init(
        portable: PointAttribute,
        attributeType: GeometryAttributeType,
        numComponents: u8,
        dataType: DataType,
        normalized: bool,
    ): Status {
        if (this.kind == PortableExtentKind.Decoded) {
            return portable.tryInit(attributeType, numComponents, dataType, normalized, this.size);
        }
        return portable.initDeferred(attributeType, numComponents, dataType, normalized, this.size);
    }
}

// An optional hook that runs right
// before the correction symbols are read (the pre-2.0 layouts use it to step
// over inline transform parameters).
export abstract class PreIntegerDecodeHook {
    abstract run(buffer: DecoderBuffer): bool;
}

// The pre-2.0 skip closure of the normal and quantization decoders:
// `skip_bytes == 0 || buf.try_advance(skip_bytes).is_ok()`.
export class SkipBytesHook extends PreIntegerDecodeHook {
    skipBytes: u64;

    constructor(skipBytes: u64) {
        super();
        this.skipBytes = skipBytes;
    }

    run(buffer: DecoderBuffer): bool {
        return this.skipBytes == 0 || buffer.tryAdvance(this.skipBytes).ok;
    }
}

// Adds `context` to the DracoError of a failed Result.
export function withContext<T>(r: Result<T>, context: string): Result<T> {
    const e = dracoErrorOf<T>(r);
    if (e != null) return e.context(context).fail<T>();
    return DracoError.general(r.err).context(context).fail<T>();
}

// Resizes `a` to `n` entries: new slots get `fill`.
function resizeI32Array(a: Array<i32>, n: i32, fill: i32): void {
    if (a.length > n) {
        a.length = n;
        return;
    }
    while (a.length < n) a.push(fill);
}

// Derives, per corner-table vertex, the data id that holds its value.
export function buildVertexToDataMapFromDataToCornerMap(
    cornerTable: CornerTable,
    dataToCornerMap: Array<u32>,
    vertexToDataMap: Array<i32>,
): Status {
    resizeI32Array(vertexToDataMap, cornerTable.numVertices(), -1);
    for (let dataId = 0; dataId < dataToCornerMap.length; dataId++) {
        const cornerU32 = unchecked(dataToCornerMap[dataId]);
        const cornerId: CornerIndex = cornerU32;
        if (cornerId == INVALID_CORNER_INDEX) {
            continue;
        }
        if (<i64>cornerId >= <i64>cornerTable.numCorners()) {
            return DracoError.general(
                "Entry " + dataId.toString() + " maps to corner " + cornerU32.toString() + ", past the " +
                cornerTable.numCorners().toString() + " in the table",
            ).fail<bool>();
        }
        const v = cornerTable.vertex(cornerId);
        if (<i64>v >= <i64>vertexToDataMap.length) {
            return DracoError.general(
                "Corner " + cornerU32.toString() + " maps to vertex " + v.toString() + ", past the " +
                cornerTable.numVertices().toString() + " in the table",
            ).fail<bool>();
        }
        vertexToDataMap[<i32>v] = dataId;
    }
    return okStatus();
}

// The corner and vertex maps a mesh predictor reads (live views, not
// copies).
export class PredictionMaps {
    dataToCorner: Array<u32>;
    vertexToData: Array<i32>;

    constructor(dataToCorner: Array<u32>, vertexToData: Array<i32>) {
        this.dataToCorner = dataToCorner;
        this.vertexToData = vertexToData;
    }
}

// The maps a mesh predictor reads, taken from the mesh decoder's own
// traversal when it built them, derived otherwise.
export function predictionMaps(
    cornerTable: CornerTable,
    numPoints: u64,
    dataToCornerMapOverride: Array<u32>?,
    vertexToDataMapOverride: Array<i32>?,
): Result<PredictionMaps> {
    let dataToCorner: Array<u32>;
    if (dataToCornerMapOverride != null) {
        if (<u64>dataToCornerMapOverride.length == numPoints) {
            dataToCorner = dataToCornerMapOverride;
        } else {
            return DracoError.general("Invalid data_to_corner_map_override length").fail<PredictionMaps>();
        }
    } else {
        // No override: the map stays empty of meaning (zeros); the vertex map
        // below is what the predictor actually reads in that case.
        dataToCorner = new Array<u32>(<i32>numPoints);
    }

    let vertexToData: Array<i32>;
    if (vertexToDataMapOverride != null) {
        if (vertexToDataMapOverride.length == cornerTable.numVertices()) {
            vertexToData = vertexToDataMapOverride;
        } else {
            return DracoError.general("Invalid vertex_to_data_map_override length").fail<PredictionMaps>();
        }
    } else {
        // The corner table may carry seam-split vertices with ids outside the
        // original point range, so this is derived rather than assumed.
        vertexToData = new Array<i32>();
        const s = buildVertexToDataMapFromDataToCornerMap(cornerTable, dataToCorner, vertexToData);
        if (!s.ok) return s.forward<PredictionMaps>();
    }

    return Result.okv<PredictionMaps>(new PredictionMaps(dataToCorner, vertexToData));
}

// Runs `decodePredictionData` on the selected predictor, failing when the
// slot is empty.
function runDecodePredictionData(predictor: PredictionSchemeDecoder?, buffer: DecoderBuffer): Status {
    if (predictor == null) {
        return DracoError.general("Predictor was selected but not initialized").fail<bool>();
    }
    return predictor.decodePredictionData(buffer);
}

// Runs `computeOriginalValues` on the selected predictor, with the same
// empty-slot handling. `values` holds the corrections on entry and the
// reconstructed values on return.
function runComputeOriginalValues(
    predictor: PredictionSchemeDecoder?,
    values: Int32Array,
    numValues: i32,
    numComponents: i32,
    entryToPointIdMap: EntryToPointIdMap?,
): Status {
    if (predictor == null) {
        return DracoError.general("Predictor was selected but not initialized").fail<bool>();
    }
    return predictor.computeOriginalValues(values, numValues, numComponents, entryToPointIdMap);
}

// The mesh prediction methods (the ones that read an entry-to-point map).
function isMeshMethod(m: PredictionSchemeMethod): bool {
    return (
        m == PredictionSchemeMethod.MeshPredictionParallelogram ||
        m == PredictionSchemeMethod.MeshPredictionMultiParallelogram ||
        m == PredictionSchemeMethod.MeshPredictionConstrainedMultiParallelogram ||
        m == PredictionSchemeMethod.MeshPredictionTexCoordsDeprecated ||
        m == PredictionSchemeMethod.MeshPredictionTexCoordsPortable ||
        m == PredictionSchemeMethod.MeshPredictionGeometricNormal
    );
}

export class SequentialIntegerAttributeDecoder {
    private attribute: i32 = -1;
    private predictionScheme: PredictionSchemeDecoder? = null;
    // The bitstream version, captured at `init` the way upstream reads
    // `decoder_->bitstream_version()` inside `InitPredictionScheme`.
    private bitstreamVersion_: u16 = 0;

    constructor() {}

    init(decoder: PointCloudDecoder, attributeId: i32): void {
        this.attribute = attributeId;
        this.bitstreamVersion_ = decoder.bitstreamVersion();
    }

    attributeId(): i32 {
        return this.attribute;
    }

    setPredictionScheme(scheme: PredictionSchemeDecoder): void {
        this.predictionScheme = scheme;
    }

    // Binds the position parent the way the bitstream version demands: a
    // registered portable copy wins; without one, below 2.0 the attribute
    // itself (legacy), from 2.0 the attribute validated as portable.
    private resolveParent(
        pointCloud: PointCloud,
        portableParentAttribute: PointAttribute?,
        posAttId: i32,
    ): Result<PredictionParent> {
        if (portableParentAttribute != null) {
            return PredictionParent.portable(portableParentAttribute);
        }
        const r = pointCloud.tryAttribute(posAttId);
        if (!r.ok) return r.forward<PredictionParent>();
        const att = r.value;
        if (this.bitstreamVersion_ < 0x0200) {
            return Result.okv<PredictionParent>(PredictionParent.legacy(att));
        }
        return PredictionParent.portable(att);
    }

    // Binds the position parent of a mesh predictor that needs one (the
    // shared tail of the TexCoords* and GeometricNormal arms).
    private bindPositionParent(
        predictor: PredictionSchemeDecoder,
        pointCloud: PointCloud,
        portableParentAttribute: PointAttribute?,
        name: string,
    ): Status {
        const posAttId = pointCloud.namedAttributeId(GeometryAttributeType.Position);
        if (posAttId >= 0) {
            const rp = this.resolveParent(pointCloud, portableParentAttribute, posAttId);
            if (!rp.ok) return rp.forward<bool>();
            if (!predictor.setParentAttribute(rp.value).ok) {
                return DracoError.general("Failed to set parent attribute for " + name).fail<bool>();
            }
            return okStatus();
        }
        return DracoError.general("Position attribute not found for " + name).fail<bool>();
    }

    decodeValues(
        pointCloud: PointCloud,
        pointIds: EntryToPointIdMap,
        inBuffer: DecoderBuffer,
        cornerTable: CornerTable?,
        dataToCornerMapOverride: Array<u32>?,
        vertexToDataMapOverride: Array<i32>?,
        portableAttribute: PointAttribute?,
        portableParentAttribute: PointAttribute?,
        preIntegerDecode: PreIntegerDecodeHook?,
    ): Status {
        const attId = this.attribute;
        if (attId < 0) {
            return DracoError.invalidParameter("Integer attribute decoder was never given an attribute").fail<bool>();
        }

        const numPoints = <u64>pointIds.len();
        // No shortcut for an empty attribute: the prediction header and the
        // entropy stream's own header are read whether or not a value follows.

        let attribute: PointAttribute;
        if (portableAttribute != null) {
            attribute = portableAttribute;
        } else {
            const ra = pointCloud.tryAttribute(attId);
            if (!ra.ok) return ra.forward<bool>();
            attribute = ra.value;
        }

        const numComponents = <u64>attribute.numComponents();
        const numValues = checkedMulU64(numPoints, numComponents);
        if (numValues == U64_NONE) {
            return DracoError.general(
                numPoints.toString() + " points times " + numComponents.toString() + " components overflows",
            ).fail<bool>();
        }

        // 3. Decode Prediction Method and (optional) prepare predictor
        const rm = inBuffer.decodeU8();
        if (!rm.ok) {
            return DracoError.general("Failed to decode prediction method").fail<bool>();
        }
        const methodByte = rm.value;

        // Draco stores the prediction method as int8 (0xFE == -2 == None);
        // 0xFF is accepted as None too (older encoders wrote it).
        let selectedMethod: PredictionSchemeMethod;
        if (methodByte == 0xff || methodByte == 0xfe) {
            selectedMethod = PredictionSchemeMethod.None;
        } else {
            const r = predictionSchemeMethodTryFrom(methodByte);
            if (!r.ok) {
                return DracoError.unsupportedFeature("Prediction method " + methodByte.toString()).fail<bool>();
            }
            selectedMethod = r.value;
        }

        // No transform is the `None` variant (-1), which the tag lookup
        // never yields.
        let selectedTransform = PredictionSchemeTransformType.None;
        if (selectedMethod != PredictionSchemeMethod.None) {
            // Draco stores the transform type as int8 (0xFF == -1 == None).
            const rt = inBuffer.decodeU8();
            if (!rt.ok) {
                return DracoError.buffer("Stream ends before the prediction transform type").fail<bool>();
            }
            const transformByte = rt.value;
            if (transformByte != 0xff) {
                const r = predictionSchemeTransformTypeTryFrom(transformByte);
                if (!r.ok) {
                    return DracoError.unsupportedFeature("Prediction transform type " + transformByte.toString()).fail<bool>();
                }
                selectedTransform = r.value;
            }
        }

        const scheme = this.predictionScheme;
        if (scheme != null) {
            if (scheme.getPredictionMethod() != selectedMethod) {
                return DracoError.general(
                    "Prediction method mismatch. Stream: " + predictionSchemeMethodDebug(selectedMethod) +
                    ", Scheme: " + predictionSchemeMethodDebug(scheme.getPredictionMethod()),
                ).fail<bool>();
            }
        }

        let predictor: PredictionSchemeDecoder? = null;
        if (scheme == null) {
            switch (selectedMethod) {
                case PredictionSchemeMethod.Difference: {
                    if (selectedTransform == PredictionSchemeTransformType.NormalOctahedronCanonicalized) {
                        const transform = new PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform();
                        predictor = new PredictionSchemeDeltaDecoder(transform);
                    } else if (selectedTransform == PredictionSchemeTransformType.NormalOctahedron) {
                        // Pre-0.10.0 normals use the legacy non-canonicalized
                        // octahedron transform (id 2).
                        const transform = new PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform();
                        transform.setCanonicalized(false);
                        predictor = new PredictionSchemeDeltaDecoder(transform);
                    } else {
                        const transform = new PredictionSchemeWrapDecodingTransform();
                        predictor = new PredictionSchemeDeltaDecoder(transform);
                    }
                    break;
                }
                case PredictionSchemeMethod.MeshPredictionParallelogram: {
                    if (cornerTable == null) {
                        return DracoError.general("Parallelogram prediction requires corner table").fail<bool>();
                    }
                    const rmaps = predictionMaps(cornerTable, numPoints, dataToCornerMapOverride, vertexToDataMapOverride);
                    if (!rmaps.ok) return rmaps.forward<bool>();
                    const meshData = new MeshPredictionSchemeData();
                    meshData.set(cornerTable, rmaps.value.dataToCorner, rmaps.value.vertexToData);
                    const transform = new PredictionSchemeWrapDecodingTransform();
                    predictor = new MeshPredictionSchemeParallelogramDecoder(attribute, transform, meshData);
                    break;
                }
                case PredictionSchemeMethod.MeshPredictionMultiParallelogram: {
                    if (cornerTable == null) {
                        return DracoError.general("MultiParallelogram prediction requires corner table").fail<bool>();
                    }
                    const rmaps = predictionMaps(cornerTable, numPoints, dataToCornerMapOverride, vertexToDataMapOverride);
                    if (!rmaps.ok) return rmaps.forward<bool>();
                    const meshData = new MeshPredictionSchemeData();
                    meshData.set(cornerTable, rmaps.value.dataToCorner, rmaps.value.vertexToData);
                    const transform = new PredictionSchemeWrapDecodingTransform();
                    predictor = new MeshPredictionSchemeMultiParallelogramDecoder(transform, meshData);
                    break;
                }
                case PredictionSchemeMethod.MeshPredictionConstrainedMultiParallelogram: {
                    if (cornerTable == null) {
                        return DracoError.general("ConstrainedMultiParallelogram prediction requires corner table").fail<bool>();
                    }
                    const rmaps = predictionMaps(cornerTable, numPoints, dataToCornerMapOverride, vertexToDataMapOverride);
                    if (!rmaps.ok) return rmaps.forward<bool>();
                    const meshData = new MeshPredictionSchemeData();
                    meshData.set(cornerTable, rmaps.value.dataToCorner, rmaps.value.vertexToData);
                    const transform = new PredictionSchemeWrapDecodingTransform();
                    predictor = new MeshPredictionSchemeConstrainedMultiParallelogramDecoder(transform, meshData);
                    break;
                }
                case PredictionSchemeMethod.MeshPredictionTexCoordsDeprecated: {
                    if (cornerTable == null) {
                        return DracoError.general("TexCoordsDeprecated prediction requires corner table").fail<bool>();
                    }
                    const rmaps = predictionMaps(cornerTable, numPoints, dataToCornerMapOverride, vertexToDataMapOverride);
                    if (!rmaps.ok) return rmaps.forward<bool>();
                    const meshData = new MeshPredictionSchemeData();
                    meshData.set(cornerTable, rmaps.value.dataToCorner, rmaps.value.vertexToData);
                    const transform = new PredictionSchemeWrapDecodingTransform();
                    const p = new MeshPredictionSchemeTexCoordsDeprecatedDecoder(transform);
                    p.init(meshData);
                    const s = this.bindPositionParent(p, pointCloud, portableParentAttribute, "TexCoordsDeprecated");
                    if (!s.ok) return s;
                    predictor = p;
                    break;
                }
                case PredictionSchemeMethod.MeshPredictionTexCoordsPortable: {
                    if (cornerTable == null) {
                        return DracoError.general("TexCoordsPortable prediction requires corner table").fail<bool>();
                    }
                    const rmaps = predictionMaps(cornerTable, numPoints, dataToCornerMapOverride, vertexToDataMapOverride);
                    if (!rmaps.ok) return rmaps.forward<bool>();
                    const meshData = new MeshPredictionSchemeData();
                    meshData.set(cornerTable, rmaps.value.dataToCorner, rmaps.value.vertexToData);
                    const transform = new PredictionSchemeWrapDecodingTransform();
                    const p = new MeshPredictionSchemeTexCoordsPortableDecoder(transform);
                    p.init(meshData);
                    const s = this.bindPositionParent(p, pointCloud, portableParentAttribute, "TexCoordsPortable");
                    if (!s.ok) return s;
                    predictor = p;
                    break;
                }
                case PredictionSchemeMethod.MeshPredictionGeometricNormal: {
                    if (cornerTable == null) {
                        return DracoError.general("GeometricNormal prediction requires corner table").fail<bool>();
                    }
                    const rmaps = predictionMaps(cornerTable, numPoints, dataToCornerMapOverride, vertexToDataMapOverride);
                    if (!rmaps.ok) return rmaps.forward<bool>();
                    const meshData = new MeshPredictionSchemeData();
                    meshData.set(cornerTable, rmaps.value.dataToCorner, rmaps.value.vertexToData);
                    const transform = new PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform();
                    // Pre-0.10.0 streams use the legacy non-canonicalized
                    // octahedron transform (id 2); 0.10.0+ the canonicalized one.
                    if (selectedTransform == PredictionSchemeTransformType.NormalOctahedron) {
                        transform.setCanonicalized(false);
                    }
                    const p = new MeshPredictionSchemeGeometricNormalDecoder(transform);
                    p.init(meshData);
                    // Mapping from decoded-entry index to original point id.
                    p.setEntryToPointIdMap(pointIds);
                    const s = this.bindPositionParent(p, pointCloud, portableParentAttribute, "GeometricNormal");
                    if (!s.ok) return s;
                    predictor = p;
                    break;
                }
                case PredictionSchemeMethod.None:
                    break;
                default:
                    return DracoError.unsupportedFeature(
                        "Prediction method " + predictionSchemeMethodDebug(selectedMethod),
                    ).fail<bool>();
            }
        }

        // 1. Decode correction symbols. For v < 2.0, transform parameters sit
        // before the integer values; the caller's hook steps over them.
        if (preIntegerDecode != null) {
            if (!preIntegerDecode.run(inBuffer)) {
                return DracoError.general("Failed to decode the pre-2.0 inline transform parameters").fail<bool>();
            }
        }
        // Entropy-coded symbols (compressed=1) or raw symbols (compressed=0).
        const rc = inBuffer.decodeU8();
        if (!rc.ok) {
            return DracoError.buffer("Stream ends before the compression flag").fail<bool>();
        }
        const compressed = rc.value;

        // Octahedron transforms produce positive corrections (no ZigZag).
        let areCorrectionsPositive: bool;
        if (
            selectedTransform == PredictionSchemeTransformType.NormalOctahedron ||
            selectedTransform == PredictionSchemeTransformType.NormalOctahedronCanonicalized
        ) {
            areCorrectionsPositive = true;
        } else if (scheme != null) {
            areCorrectionsPositive = scheme.areCorrectionsPositive();
        } else {
            areCorrectionsPositive = false;
        }
        const needsZigzagConversion = !areCorrectionsPositive;

        // One buffer for the whole pipeline: the decoded corrections first,
        // then the values the prediction pass rebuilds over them in place.
        let values: Int32Array;
        if (compressed > 0) {
            // Empty on purpose: `decodeSymbols` grows it as symbols arrive.
            const symbols = new Array<u32>();
            const options = new SymbolEncodingOptions();
            const s = decodeSymbols(numValues, numComponents, options, inBuffer, symbols);
            if (!s.ok) return withContext<bool>(s, "Failed to decode the entropy-coded symbols");
            values = symbolsToCorrections(symbols, needsZigzagConversion);
        } else {
            // Raw uncompressed integers, read directly as bytes.
            const rb = inBuffer.decodeU8();
            if (!rb.ok) {
                return DracoError.buffer("Stream ends before the raw correction byte width").fail<bool>();
            }
            const numBytes = <u64>rb.value;
            if (numBytes > 4) {
                return DracoError.general(
                    "Raw corrections declare " + numBytes.toString() + " bytes per value, at most 4 fit an i32",
                ).fail<bool>();
            }

            // `numBytes == 0` reads nothing: the count is a claim the stream
            // does not back, so the allocation budget is charged for it.
            if (numBytes == 0) {
                const s = inBuffer.chargeElements(numValues, 4);
                if (!s.ok) return s;
            } else {
                const byteLen = checkedMulU64(numValues, numBytes);
                if (byteLen == U64_NONE) {
                    return DracoError.general(
                        numValues.toString() + " " + numBytes.toString() + "-byte corrections overflow a byte count",
                    ).fail<bool>();
                }
                if (byteLen > <u64>inBuffer.remainingSize()) {
                    return DracoError.buffer(
                        "declared " + numValues.toString() + " raw corrections of " + numBytes.toString() +
                        " bytes, more than the \n" + " ".repeat(25) + inBuffer.remainingSize().toString() +
                        " bytes left in the stream",
                    ).fail<bool>();
                }
            }

            // Nothing can be allocated past one
            // rasc object (see BYTE_VEC_MAX_CAPACITY).
            if (numValues > <u64>(BYTE_VEC_MAX_CAPACITY / 4)) {
                return DracoError.general("Failed to allocate " + numValues.toString() + " raw corrections").fail<bool>();
            }
            const n = <i32>numValues;
            const rawCorrections = new Int32Array(n);
            if (numBytes == 0) {
                // All values are zero -- nothing to read from the buffer.
            } else if (numBytes == 4) {
                const byteLen = checkedMulU64(numValues, 4);
                if (byteLen == U64_NONE) {
                    return DracoError.general(
                        numValues.toString() + " four-byte corrections overflow a byte count",
                    ).fail<bool>();
                }
                const rs = inBuffer.decodeSlice(byteLen);
                if (!rs.ok) {
                    return DracoError.buffer(
                        "Stream holds fewer than the " + byteLen.toString() + " bytes of raw corrections it declares",
                    ).fail<bool>();
                }
                const bytes = rs.value;
                for (let i = 0; i < n; i++) {
                    const o = i * 4;
                    const symbol =
                        <u32>unchecked(bytes[o]) |
                        (<u32>unchecked(bytes[o + 1]) << 8) |
                        (<u32>unchecked(bytes[o + 2]) << 16) |
                        (<u32>unchecked(bytes[o + 3]) << 24);
                    unchecked((rawCorrections[i] = symbolToCorrection(symbol, needsZigzagConversion)));
                }
            } else {
                const tmp = new Uint8Array(4);
                const head = tmp.subarray(0, <i32>numBytes);
                for (let i = 0; i < n; i++) {
                    tmp[0] = 0;
                    tmp[1] = 0;
                    tmp[2] = 0;
                    tmp[3] = 0;
                    if (!inBuffer.decodeBytes(head).ok) {
                        return DracoError.buffer("Stream ends inside the raw corrections").fail<bool>();
                    }
                    const symbol = <u32>tmp[0] | (<u32>tmp[1] << 8) | (<u32>tmp[2] << 16) | (<u32>tmp[3] << 24);
                    rawCorrections[i] = symbolToCorrection(symbol, needsZigzagConversion);
                }
            }
            values = rawCorrections;
        }

        // 3. Decode prediction scheme data (if any).
        if (scheme != null) {
            const s = runDecodePredictionData(scheme, inBuffer);
            if (!s.ok) return s;
        } else if (selectedMethod != PredictionSchemeMethod.None) {
            const s = runDecodePredictionData(predictor, inBuffer);
            if (!s.ok) return s;
        }

        // 4. Apply Inverse Prediction. Nothing to revert without a value.
        if (numValues == 0) {
            return okStatus();
        }
        if (scheme != null) {
            const map: EntryToPointIdMap? = isMeshMethod(selectedMethod) ? pointIds : null;
            const s = runComputeOriginalValues(scheme, values, <i32>numValues, <i32>numComponents, map);
            if (!s.ok) return s;
        } else if (selectedMethod != PredictionSchemeMethod.None) {
            // Only the tex-coord and geometric-normal arms hand the map down.
            const passMap =
                selectedMethod == PredictionSchemeMethod.MeshPredictionTexCoordsDeprecated ||
                selectedMethod == PredictionSchemeMethod.MeshPredictionTexCoordsPortable ||
                selectedMethod == PredictionSchemeMethod.MeshPredictionGeometricNormal;
            const map: EntryToPointIdMap? = passMap ? pointIds : null;
            const s = runComputeOriginalValues(predictor, values, <i32>numValues, <i32>numComponents, map);
            if (!s.ok) return s;
        }

        // 5. Store values.
        if (portableAttribute != null) {
            if (!storeI32ValuesToAttribute(portableAttribute, values, numPoints, numComponents)) {
                return DracoError.general("Decoded values do not fit the portable attribute").fail<bool>();
            }
        } else {
            const rd = pointCloud.tryAttributeMut(attId);
            if (!rd.ok) return rd.forward<bool>();
            if (!storeI32ValuesToAttribute(rd.value, values, numPoints, numComponents)) {
                return DracoError.general("Decoded values do not fit the destination attribute").fail<bool>();
            }
        }

        return okStatus();
    }
}

// Unzigzags one symbol, unless the scheme guarantees positive corrections.
export function symbolToCorrection(symbol: u32, needsZigzagConversion: bool): i32 {
    if (needsZigzagConversion) {
        return (<i32>(symbol >> 1)) ^ -(<i32>(symbol & 1));
    }
    return <i32>symbol;
}

export function symbolsToCorrections(symbols: Array<u32>, needsZigzagConversion: bool): Int32Array {
    const n = symbols.length;
    const out = new Int32Array(n);
    for (let i = 0; i < n; i++) {
        unchecked((out[i] = symbolToCorrection(unchecked(symbols[i]), needsZigzagConversion)));
    }
    return out;
}

// Stores decoded i32 values into an attribute buffer, converting to the
// attribute's integer type. False when the values do not fit.
export function storeI32ValuesToAttribute(
    attr: PointAttribute,
    values: Int32Array,
    numPoints: u64,
    numComponents: u64,
): bool {
    const stride = attr.byteStride();
    if (stride < 0) {
        return false;
    }
    const byteStride = <u64>stride;
    const dataType = attr.dataType();
    const componentSize = <u64>dataTypeByteLength(dataType);
    const packedRow = checkedMulU64(numComponents, componentSize);
    if (packedRow == U64_NONE) {
        return false;
    }
    const numValuesRequired = checkedMulU64(numPoints, numComponents);
    if (numValuesRequired == U64_NONE) {
        return false;
    }
    if (<u64>values.length < numValuesRequired) {
        return false;
    }

    // Ensure the buffer is large enough for numPoints entries.
    const required = checkedMulU64(numPoints, byteStride);
    if (required == U64_NONE) {
        return false;
    }
    if (<u64>attr.buffer().dataSize() < required && !attr.bufferMut().tryResize(required).ok) {
        return false;
    }

    // Fast path: i32/u32 tightly packed -- copy the whole values array.
    if ((dataType == DataType.Int32 || dataType == DataType.Uint32) && byteStride == packedRow) {
        const dst = attr.bufferMut().dataMut();
        const srcLen = numValuesRequired * 4;
        if (<u64>dst.length < srcLen) {
            return false;
        }
        const n = <i32>numValuesRequired;
        for (let i = 0; i < n; i++) {
            const v = <u32>unchecked(values[i]);
            const o = i * 4;
            unchecked((dst[o] = <u8>v));
            unchecked((dst[o + 1] = <u8>(v >> 8)));
            unchecked((dst[o + 2] = <u8>(v >> 16)));
            unchecked((dst[o + 3] = <u8>(v >> 24)));
        }
        return true;
    }

    // Slow path: per-component write with type conversion.
    const dstBuffer = attr.bufferMut();
    for (let i: u64 = 0; i < numPoints; i++) {
        const entryOffset = checkedMulU64(i, byteStride);
        if (entryOffset == U64_NONE) {
            return false;
        }
        for (let c: u64 = 0; c < numComponents; c++) {
            const componentByteOffset = checkedMulU64(c, componentSize);
            if (componentByteOffset == U64_NONE) {
                return false;
            }
            const componentOffset = checkedAddU64(entryOffset, componentByteOffset);
            if (componentOffset == U64_NONE) {
                return false;
            }
            if (!writeValueFromI32(dstBuffer, componentOffset, dataType, values[<i32>(i * numComponents + c)])) {
                return false;
            }
        }
    }
    return true;
}

// Writes `val` converted to `dataType` (little-endian) at `offset`; false
// past the end. Non-integer types write nothing.
function writeValueFromI32(buffer: DataBuffer, offset: u64, dataType: DataType, val: i32): bool {
    let width: u64 = 0;
    switch (dataType) {
        case DataType.Int8:
        case DataType.Uint8:
            width = 1;
            break;
        case DataType.Int16:
        case DataType.Uint16:
            width = 2;
            break;
        case DataType.Int32:
        case DataType.Uint32:
            width = 4;
            break;
        default:
            return true;
    }
    if (offset > u64.MAX_VALUE - width || offset + width > <u64>buffer.dataSize()) {
        return false;
    }
    const d = buffer.dataMut();
    const o = <i32>offset;
    const v = <u32>val;
    d[o] = <u8>v;
    if (width >= 2) d[o + 1] = <u8>(v >> 8);
    if (width == 4) {
        d[o + 2] = <u8>(v >> 16);
        d[o + 3] = <u8>(v >> 24);
    }
    return true;
}
