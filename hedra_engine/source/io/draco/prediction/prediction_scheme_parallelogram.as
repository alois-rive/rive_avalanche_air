// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The single-parallelogram mesh predictor.
//
// Predicts a vertex value with the parallelogram rule over one adjacent
// triangle (`v ~ next + prev - opposite`), found through the corner table. A
// strong predictor for smooth surfaces and the building block of the multi-
// and constrained-multi-parallelogram schemes.
//
// Only i32 data is predicted: `computeParallelogramPredictionI32` and
// `addAsUnsigned` below.

import { panic } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DracoError, Status, okStatus } from "../core/status";
import { GeometryAttributeType, PointAttribute } from "../geometry/geometry_attribute";
import { CornerIndex, INVALID_CORNER_INDEX } from "../geometry/geometry_indices";
import { PredictionParent } from "../geometry/portable_attribute";
import { CornerTable } from "../mesh/corner_table";
import { MeshPredictionSchemeData } from "../mesh/mesh_prediction_scheme_data";
import {
    EntryToPointIdMap,
    PredictionSchemeDecoder,
    PredictionSchemeDecodingTransform,
    PredictionSchemeEncoder,
    PredictionSchemeEncodingTransform,
    PredictionSchemeMethod,
    PredictionSchemeTransformType,
} from "./prediction_scheme";

// `<i32 as ParallelogramDataType>::compute_parallelogram_prediction`:
// wrapping `next + prev - opp`, the arithmetic upstream performs.
// @ts-ignore: decorator
@inline
export function computeParallelogramPredictionI32(next: i32, prev: i32, opp: i32): i32 {
    return next + prev - opp;
}

// `<i32 as ParallelogramDataType>::add_as_unsigned` (C++ AddAsUnsigned):
// a wrapping add.
// @ts-ignore: decorator
@inline
export function addAsUnsigned(a: i32, b: i32): i32 {
    return <i32>(<u32>a + <u32>b);
}

// Parallelogram prediction for one corner. Reads only entries
// below `dataEntryId` of `inData` and writes `numComponents` values of
// `outPrediction` (from index 0). Returns false when the corner has no
// opposite, a neighbor is outside the map, or a neighbor is not yet coded.
export function computeParallelogramPrediction(
    dataEntryId: i32,
    ci: CornerIndex,
    table: CornerTable,
    vertexToDataMap: Array<i32>,
    inData: Int32Array,
    numComponents: i32,
    outPrediction: Int32Array,
): bool {
    const oci = table.opposite(ci);
    if (oci == INVALID_CORNER_INDEX) {
        return false;
    }

    // Entries come from the OPPOSITE corner (oci), the tip of the neighbor
    // face. The shared vertices are next(oci) and prev(oci); the opposite
    // vertex is vertex(oci).
    const vertOppIdx = table.vertex(oci);
    const vertNextIdx = table.vertexAfter(oci);
    const vertPrevIdx = table.vertexBefore(oci);

    const mapLen = <u32>vertexToDataMap.length;
    if (vertOppIdx >= mapLen || vertNextIdx >= mapLen || vertPrevIdx >= mapLen) {
        return false;
    }

    const vertOpp = unchecked(vertexToDataMap[<i32>vertOppIdx]);
    const vertNext = unchecked(vertexToDataMap[<i32>vertNextIdx]);
    const vertPrev = unchecked(vertexToDataMap[<i32>vertPrevIdx]);

    // Ensure all three neighbors have been processed already.
    if (
        vertOpp >= 0 &&
        vertNext >= 0 &&
        vertPrev >= 0 &&
        vertOpp < dataEntryId &&
        vertNext < dataEntryId &&
        vertPrev < dataEntryId
    ) {
        const vOppOff = vertOpp * numComponents;
        const vNextOff = vertNext * numComponents;
        const vPrevOff = vertPrev * numComponents;
        // The output and the three neighbor slices are walked together: the
        // shortest bounds the loop.
        let n = numComponents;
        if (outPrediction.length < n) n = outPrediction.length;
        for (let c = 0; c < n; c++) {
            outPrediction[c] = computeParallelogramPredictionI32(
                inData[vNextOff + c],
                inData[vPrevOff + c],
                inData[vOppOff + c],
            );
        }
        return true;
    }
    return false;
}

export class PredictionSchemeParallelogramEncodingTransform extends PredictionSchemeEncodingTransform {
    constructor() {
        super();
    }

    getType(): PredictionSchemeTransformType {
        return PredictionSchemeTransformType.Parallelogram;
    }

    init(_origData: Int32Array, _size: i32, _numComponents: i32): void {
        // No init needed
    }

    computeCorrection(
        originalVals: Int32Array, origOff: i32,
        predictedVals: Int32Array, predOff: i32,
        outCorrVals: Int32Array, outOff: i32,
        n: i32,
    ): void {
        for (let i = 0; i < n; i++) {
            // `(o - p) as i32` of the i64 difference: the wrapping i32 difference.
            const o = <i64>originalVals[origOff + i];
            const p = <i64>predictedVals[predOff + i];
            outCorrVals[outOff + i] = <i32>(o - p);
        }
    }

    encodeTransformData(_buffer: ByteVec): Status {
        return okStatus();
    }
}

export class PredictionSchemeParallelogramDecodingTransform extends PredictionSchemeDecodingTransform {
    constructor() {
        super();
    }

    getType(): PredictionSchemeTransformType {
        return PredictionSchemeTransformType.Parallelogram;
    }

    init(_numComponents: i32): Status {
        return okStatus();
    }

    computeOriginalValue(
        predictedVals: Int32Array, predOff: i32,
        data: Int32Array, dataOff: i32,
        n: i32,
    ): void {
        for (let i = 0; i < n; i++) {
            const p = <i64>predictedVals[predOff + i];
            const c = <i64>data[dataOff + i];
            data[dataOff + i] = <i32>(p + c);
        }
    }

    decodeTransformData(_buffer: DecoderBuffer): Status {
        return okStatus();
    }
}

function unwrapNone<T>(v: T?): T {
    if (v == null) panic("called `Option::unwrap()` on a `None` value");
    return v!;
}

export class MeshPredictionSchemeParallelogramEncoder extends PredictionSchemeEncoder {
    attribute: PointAttribute;
    transform: PredictionSchemeEncodingTransform;
    meshData: MeshPredictionSchemeData;

    constructor(attribute: PointAttribute, transform: PredictionSchemeEncodingTransform, meshData: MeshPredictionSchemeData) {
        super();
        this.attribute = attribute;
        this.transform = transform;
        this.meshData = meshData;
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionParallelogram;
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    isInitialized(): bool {
        return this.meshData.cornerTable() != null;
    }

    getNumParentAttributes(): i32 {
        return 0;
    }

    getParentAttributeType(_i: i32): GeometryAttributeType {
        return GeometryAttributeType.Invalid;
    }

    setParentAttribute(_parent: PredictionParent): Status {
        return DracoError.invalidParameter(
            "The parallelogram prediction scheme takes no parent attribute",
        ).fail<bool>();
    }

    computeCorrectionValues(
        inData: Int32Array,
        outCorr: Int32Array,
        size: i32,
        numComponents: i32,
        _entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        this.transform.init(inData, size, numComponents);

        // An attribute with no values has no entry 0, and the tail of this
        // function encodes entry 0 unconditionally.
        if (numComponents == 0 || size % numComponents != 0) {
            return DracoError.invalidParameter(
                `${size} values do not divide into ${numComponents} components`,
            ).fail<bool>();
        }
        if (size == 0) {
            return okStatus();
        }

        const table = unwrapNone<CornerTable>(this.meshData.cornerTable());
        const vertexToDataMap = unwrapNone<Array<i32>>(this.meshData.vertexToDataMap());
        const dataToCornerMap = unwrapNone<Array<u32>>(this.meshData.dataToCornerMap());

        const numEntries = size / numComponents;
        const predVals = new Int32Array(numComponents);

        // Process from the end (highest data id) down to 1. Index 0 is
        // handled separately at the end.
        for (let p = numEntries - 1; p >= 1; p--) {
            const cornerId: CornerIndex = dataToCornerMap[p];
            const dstOffset = p * numComponents;

            const isParallelogram = computeParallelogramPrediction(
                p,
                cornerId,
                table,
                vertexToDataMap,
                inData,
                numComponents,
                predVals,
            );

            if (!isParallelogram) {
                // Delta coding: use previous entry as prediction
                const srcOffset = (p - 1) * numComponents;
                this.transform.computeCorrection(inData, dstOffset, inData, srcOffset, outCorr, dstOffset, numComponents);
            } else {
                this.transform.computeCorrection(inData, dstOffset, predVals, 0, outCorr, dstOffset, numComponents);
            }
        }

        // First element: no prediction (use zero as prediction)
        for (let i = 0; i < numComponents; i++) {
            predVals[i] = 0;
        }
        this.transform.computeCorrection(inData, 0, predVals, 0, outCorr, 0, numComponents);

        return okStatus();
    }

    encodePredictionData(buffer: ByteVec): Status {
        return this.transform.encodeTransformData(buffer);
    }
}

export class MeshPredictionSchemeParallelogramDecoder extends PredictionSchemeDecoder {
    attribute: PointAttribute;
    transform: PredictionSchemeDecodingTransform;
    meshData: MeshPredictionSchemeData;

    constructor(attribute: PointAttribute, transform: PredictionSchemeDecodingTransform, meshData: MeshPredictionSchemeData) {
        super();
        this.attribute = attribute;
        this.transform = transform;
        this.meshData = meshData;
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionParallelogram;
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    isInitialized(): bool {
        return this.meshData.cornerTable() != null;
    }

    getNumParentAttributes(): i32 {
        return 0;
    }

    getParentAttributeType(_i: i32): GeometryAttributeType {
        return GeometryAttributeType.Invalid;
    }

    setParentAttribute(_parent: PredictionParent): Status {
        return DracoError.invalidParameter(
            "The parallelogram prediction scheme takes no parent attribute",
        ).fail<bool>();
    }

    computeOriginalValues(
        data: Int32Array,
        _size: i32,
        numComponents: i32,
        _entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        const s = this.transform.init(numComponents);
        if (!s.ok) return s;

        if (numComponents == 0) {
            return DracoError.invalidParameter(
                "Parallelogram prediction needs at least one component",
            ).fail<bool>();
        }

        const tableOpt = this.meshData.cornerTable();
        if (tableOpt == null) {
            return DracoError.general("Parallelogram prediction has no corner table").fail<bool>();
        }
        const table = tableOpt;
        const v2dOpt = this.meshData.vertexToDataMap();
        if (v2dOpt == null) {
            return DracoError.general("Parallelogram prediction has no vertex-to-data map").fail<bool>();
        }
        const vertexToDataMap = v2dOpt;
        const d2cOpt = this.meshData.dataToCornerMap();
        if (d2cOpt == null) {
            return DracoError.general("Parallelogram prediction has no data-to-corner map").fail<bool>();
        }
        const dataToCornerMap = d2cOpt;
        // An i32 * i32 product always fits i64: no overflow check needed.
        const requiredValues = <i64>dataToCornerMap.length * <i64>numComponents;
        if (requiredValues == 0 || <i64>data.length < requiredValues) {
            return DracoError.general(
                `Parallelogram prediction needs ${requiredValues} values, has ${data.length}`,
            ).fail<bool>();
        }

        const predVals = new Int32Array(numComponents);

        // Restore the first value.
        const zeroVals = new Int32Array(numComponents);
        this.transform.computeOriginalValue(zeroVals, 0, data, 0, numComponents);

        const numEntries = dataToCornerMap.length;
        for (let p = 1; p < numEntries; p++) {
            const cornerId: CornerIndex = unchecked(dataToCornerMap[p]);
            const dstOffset = p * numComponents;

            const isParallelogram = computeParallelogramPrediction(
                p,
                cornerId,
                table,
                vertexToDataMap,
                data,
                numComponents,
                predVals,
            );

            if (!isParallelogram) {
                // Delta coding
                const srcOffset = (p - 1) * numComponents;
                for (let c = 0; c < numComponents; c++) {
                    predVals[c] = data[srcOffset + c];
                }
            }
            this.transform.computeOriginalValue(predVals, 0, data, dstOffset, numComponents);
        }

        return okStatus();
    }

    decodePredictionData(buffer: DecoderBuffer): Status {
        return this.transform.decodeTransformData(buffer);
    }
}
