// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The multi-parallelogram mesh predictor.
//
// Averages parallelogram predictions from every triangle incident to a
// vertex, improving accuracy over the single-parallelogram scheme at higher
// cost.

import { panic } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DracoError, Status, okStatus } from "../core/status";
import { GeometryAttributeType } from "../geometry/geometry_attribute";
import { CornerIndex, INVALID_CORNER_INDEX } from "../geometry/geometry_indices";
import { PredictionParent } from "../geometry/portable_attribute";
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
import { addAsUnsigned, computeParallelogramPrediction } from "./prediction_scheme_parallelogram";

export class MeshPredictionSchemeMultiParallelogramEncoder extends PredictionSchemeEncoder {
    transform: PredictionSchemeEncodingTransform;
    meshData: MeshPredictionSchemeData;

    constructor(transform: PredictionSchemeEncodingTransform, meshData: MeshPredictionSchemeData) {
        super();
        this.transform = transform;
        this.meshData = meshData;
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionMultiParallelogram;
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
            "The multi-parallelogram prediction scheme takes no parent attribute",
        ).fail<bool>();
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    encodePredictionData(buffer: ByteVec): Status {
        return this.transform.encodeTransformData(buffer);
    }

    computeCorrectionValues(
        inData: Int32Array,
        outCorr: Int32Array,
        size: i32,
        numComponents: i32,
        _entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        if (numComponents == 0 || size % numComponents != 0) {
            return DracoError.invalidParameter(
                `${size} values do not divide into ${numComponents} components`,
            ).fail<bool>();
        }
        if (size == 0) {
            // No values, so no entry 0 for the tail of this function to encode.
            return okStatus();
        }

        const tableOpt = this.meshData.cornerTable();
        if (tableOpt == null) {
            return DracoError.general("Multi-parallelogram prediction has no corner table").fail<bool>();
        }
        const table = tableOpt;
        const v2dOpt = this.meshData.vertexToDataMap();
        if (v2dOpt == null) {
            return DracoError.general("Multi-parallelogram prediction has no vertex-to-data map").fail<bool>();
        }
        const vertexToDataMap = v2dOpt;
        const d2cOpt = this.meshData.dataToCornerMap();
        if (d2cOpt == null) {
            return DracoError.general("Multi-parallelogram prediction has no data-to-corner map").fail<bool>();
        }
        const dataToCornerMap = d2cOpt;

        const numEntries = size / numComponents;
        if (dataToCornerMap.length < numEntries || inData.length < size || outCorr.length < size) {
            return DracoError.general(
                `Multi-parallelogram prediction needs ${numEntries} corners and ${size} values, has ${dataToCornerMap.length} corners, ${inData.length} inputs and ${outCorr.length} outputs`,
            ).fail<bool>();
        }

        this.transform.init(inData, size, numComponents);

        const predVals = new Int32Array(numComponents);
        const parallelogramPredVals = new Int32Array(numComponents);

        for (let p = numEntries - 1; p >= 1; p--) {
            const startCornerId: CornerIndex = unchecked(dataToCornerMap[p]);
            if (startCornerId == INVALID_CORNER_INDEX) {
                const srcOffset = (p - 1) * numComponents;
                for (let c = 0; c < numComponents; c++) predVals[c] = inData[srcOffset + c];
            } else {
                predVals.fill(0);
                let numParallelograms: i64 = 0;
                let cornerId = startCornerId;

                while (cornerId != INVALID_CORNER_INDEX) {
                    if (
                        computeParallelogramPrediction(
                            p,
                            cornerId,
                            table,
                            vertexToDataMap,
                            inData,
                            numComponents,
                            parallelogramPredVals,
                        )
                    ) {
                        for (let c = 0; c < numComponents; c++) {
                            predVals[c] = <i32>(<i64>predVals[c] + <i64>parallelogramPredVals[c]);
                        }
                        numParallelograms += 1;
                    }

                    cornerId = table.swingRight(cornerId);
                    if (cornerId == startCornerId) {
                        cornerId = INVALID_CORNER_INDEX;
                    }
                }

                if (numParallelograms == 0) {
                    const srcOffset = (p - 1) * numComponents;
                    for (let c = 0; c < numComponents; c++) predVals[c] = inData[srcOffset + c];
                } else {
                    for (let c = 0; c < numComponents; c++) {
                        predVals[c] = <i32>(<i64>predVals[c] / numParallelograms);
                    }
                }
            }

            const dstOffset = p * numComponents;
            this.transform.computeCorrection(inData, dstOffset, predVals, 0, outCorr, dstOffset, numComponents);
        }

        predVals.fill(0);
        this.transform.computeCorrection(inData, 0, predVals, 0, outCorr, 0, numComponents);

        return okStatus();
    }
}

export class MeshPredictionSchemeMultiParallelogramDecoder extends PredictionSchemeDecoder {
    transform: PredictionSchemeDecodingTransform;
    meshData: MeshPredictionSchemeData;

    constructor(transform: PredictionSchemeDecodingTransform, meshData: MeshPredictionSchemeData) {
        super();
        this.transform = transform;
        this.meshData = meshData;
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionMultiParallelogram;
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
            "The multi-parallelogram prediction scheme takes no parent attribute",
        ).fail<bool>();
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    decodePredictionData(buffer: DecoderBuffer): Status {
        return this.transform.decodeTransformData(buffer);
    }

    computeOriginalValues(
        data: Int32Array,
        _size: i32,
        numComponents: i32,
        _entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        if (numComponents == 0) {
            return DracoError.invalidParameter(
                "Multi-parallelogram prediction needs at least one component",
            ).fail<bool>();
        }

        const tableOpt = this.meshData.cornerTable();
        if (tableOpt == null) {
            return DracoError.general("Multi-parallelogram prediction has no corner table").fail<bool>();
        }
        const table = tableOpt;
        const v2dOpt = this.meshData.vertexToDataMap();
        if (v2dOpt == null) {
            return DracoError.general("Multi-parallelogram prediction has no vertex-to-data map").fail<bool>();
        }
        const vertexToDataMap = v2dOpt;
        const d2cOpt = this.meshData.dataToCornerMap();
        if (d2cOpt == null) {
            return DracoError.general("Multi-parallelogram prediction has no data-to-corner map").fail<bool>();
        }
        const dataToCornerMap = d2cOpt;
        // An i32 * i32 product always fits i64: no overflow check needed.
        const requiredValues = <i64>dataToCornerMap.length * <i64>numComponents;
        if (<i64>data.length < requiredValues) {
            return DracoError.general(
                `Multi-parallelogram prediction needs ${requiredValues} values, has ${data.length}`,
            ).fail<bool>();
        }

        const s = this.transform.init(numComponents);
        if (!s.ok) return s;

        const predVals = new Int32Array(numComponents);
        const parallelogramPredVals = new Int32Array(numComponents);

        // Reading `data[0..numComponents]` panics on an empty map with no data.
        if (numComponents > data.length) {
            panic(`range end index ${numComponents} out of range for slice of length ${data.length}`);
        }
        this.transform.computeOriginalValue(predVals, 0, data, 0, numComponents);

        const numEntries = dataToCornerMap.length;
        for (let p = 1; p < numEntries; p++) {
            const startCornerId: CornerIndex = unchecked(dataToCornerMap[p]);
            if (startCornerId == INVALID_CORNER_INDEX) {
                const srcOffset = (p - 1) * numComponents;
                const dstOffset = p * numComponents;
                for (let c = 0; c < numComponents; c++) predVals[c] = data[srcOffset + c];
                this.transform.computeOriginalValue(predVals, 0, data, dstOffset, numComponents);
                continue;
            }

            predVals.fill(0);
            let numParallelograms: i64 = 0;
            let cornerId = startCornerId;

            while (cornerId != INVALID_CORNER_INDEX) {
                if (
                    computeParallelogramPrediction(
                        p,
                        cornerId,
                        table,
                        vertexToDataMap,
                        data,
                        numComponents,
                        parallelogramPredVals,
                    )
                ) {
                    for (let c = 0; c < numComponents; c++) {
                        predVals[c] = addAsUnsigned(predVals[c], parallelogramPredVals[c]);
                    }
                    numParallelograms += 1;
                }

                cornerId = table.swingRight(cornerId);
                if (cornerId == startCornerId) {
                    cornerId = INVALID_CORNER_INDEX;
                }
            }

            const dstOffset = p * numComponents;
            if (numParallelograms == 0) {
                const srcOffset = (p - 1) * numComponents;
                for (let c = 0; c < numComponents; c++) predVals[c] = data[srcOffset + c];
            } else {
                for (let c = 0; c < numComponents; c++) {
                    predVals[c] = <i32>(<i64>predVals[c] / numParallelograms);
                }
            }

            this.transform.computeOriginalValue(predVals, 0, data, dstOffset, numComponents);
        }

        return okStatus();
    }
}
