// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The constrained multi-parallelogram mesh predictor.
//
// Like multi-parallelogram, but the encoder selects, per vertex, the best
// subset of incident triangles and codes the choice as crease/selection flags
// so the decoder reproduces it exactly. Draco's highest-quality mesh position
// predictor. Follows Draco's `prediction_scheme_constrained_multi_parallelogram_*`.
//
// DataType = CorrType = i32 (the only instantiation), as in the rest of the
// prediction schemes: data is an Int32Array.

import { f64ToI64 } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { EncoderBuffer } from "../core/encoder_buffer";
import { DracoError, Status, okStatus } from "../core/status";
import { RAnsBitDecoder } from "../entropy/rans_bit_decoder";
import { RAnsBitEncoder } from "../entropy/rans_bit_encoder";
import {
    EntropyData,
    ShannonEntropyTracker,
    computeBinaryShannonEntropy,
} from "../entropy/shannon_entropy";
import { GeometryAttributeType } from "../geometry/geometry_attribute";
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
import { addAsUnsigned, computeParallelogramPredictionI32 } from "./prediction_scheme_parallelogram";

export const MAX_NUM_PARALLELOGRAMS: i32 = 4;

// The data id of vertex `v`, or -1 past the end of the map.
// @ts-ignore: decorator
@inline
function dataIdOf(vertexToDataMap: Array<i32>, v: u32): i32 {
    return v < <u32>vertexToDataMap.length ? unchecked(vertexToDataMap[<i32>v]) : -1;
}

// The corner an entry predicts from: the data-to-corner map when there is
// one, else the vertex's left-most corner (entry id = vertex id).
function cornerOfEntry(meshData: MeshPredictionSchemeData, table: CornerTable, dataId: i32): CornerIndex {
    const map = meshData.dataToCornerMap();
    if (map != null) {
        return dataId < map.length ? unchecked(map[dataId]) : INVALID_CORNER_INDEX;
    }
    if (dataId < table.numVertices()) {
        return table.leftMostCorner(<u32>dataId);
    }
    return INVALID_CORNER_INDEX;
}

// Zig-zags a residual for the entropy estimate, as C++
// `ConvertSignedIntToSymbol` does (map -1 to 0, -2 to 1, then shift and set
// the low bit; `as u32` keeps the low 32 bits).
export function convertSignedIntToSymbol(val: i64): u32 {
    if (val >= 0) {
        return (<u32>val) << 1;
    }
    const magnitude = -(val + 1);
    return ((<u32>magnitude) << 1) | 1;
}

// Advances `arr[0..len]` to its next lexicographic permutation in place
// (`false` < `true`), matching `std::next_permutation`. Returns false and
// leaves the slice sorted ascending when it was already the last permutation.
// The encoder's config search needs this exact order: ties in cost are broken
// by whichever configuration is visited first, and the configuration itself
// is part of the stream.
export function nextPermutation(arr: StaticArray<bool>, len: i32): bool {
    if (len < 2) {
        return false;
    }
    let i = len - 1;
    while (true) {
        if (i == 0) {
            reverseRange(arr, 0, len);
            return false;
        }
        i -= 1;
        if (!arr[i] && arr[i + 1]) {
            break;
        }
    }
    let j = len - 1;
    // `arr[j] <= arr[i]` on bools (false < true).
    while (<i32>arr[j] <= <i32>arr[i]) {
        j -= 1;
    }
    const t = arr[i];
    arr[i] = arr[j];
    arr[j] = t;
    reverseRange(arr, i + 1, len);
    return true;
}

function reverseRange(arr: StaticArray<bool>, start: i32, end: i32): void {
    let a = start;
    let b = end - 1;
    while (a < b) {
        const t = arr[a];
        arr[a] = arr[b];
        arr[b] = t;
        a++;
        b--;
    }
}

// The cost of a configuration: `(numBits, residualError)`, compared
// lexicographically.
class CostError {
    numBits: i64 = 0;
    residualError: i64 = 0;

    lessThan(other: CostError): bool {
        if (this.numBits != other.numBits) return this.numBits < other.numBits;
        return this.residualError < other.residualError;
    }
}

// Computes the total cumulative overhead bits for the entire overhead stream:
// `ceil(total_parallelograms * binary_shannon_entropy(total_used / total))`,
// as C++ `ComputeOverheadBits()` does.
export function computeOverheadBits(totalUsedParallelograms: i64, totalParallelograms: i64): i64 {
    const entropy = computeBinaryShannonEntropy(<u32>totalParallelograms, <u32>totalUsedParallelograms);
    // Round up to the nearest full bit.
    return f64ToI64(Math.ceil(<f64>totalParallelograms * entropy));
}

export class MeshPredictionSchemeConstrainedMultiParallelogramEncoder extends PredictionSchemeEncoder {
    meshData: MeshPredictionSchemeData;
    transform: PredictionSchemeEncodingTransform;
    isCreaseEdge: Array<Array<bool>> = [[], [], [], []];
    entropyTracker: ShannonEntropyTracker = new ShannonEntropyTracker();
    // Target bitstream version (0 = default/2.2). Pre-2.2 crease-edge rANS
    // streams need a fixed-u32 size prefix instead of a varint.
    bitstreamVersion: u16 = 0;

    constructor(transform: PredictionSchemeEncodingTransform, meshData: MeshPredictionSchemeData) {
        super();
        this.meshData = meshData;
        this.transform = transform;
    }

    // Sets the target bitstream version (packed `0xMMmm`).
    setBitstreamVersion(version: u16): void {
        this.bitstreamVersion = version;
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionConstrainedMultiParallelogram;
    }

    isInitialized(): bool {
        return this.meshData.cornerTable() != null;
    }

    getNumParentAttributes(): i32 {
        return 0;
    }

    getParentAttributeType(_i: i32): GeometryAttributeType {
        return GeometryAttributeType.Generic;
    }

    setParentAttribute(_parent: PredictionParent): Status {
        return DracoError.invalidParameter(
            "The constrained multi-parallelogram prediction scheme takes no parent attribute",
        ).fail<bool>();
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    // The entropy cost of `symbols` added to the running history.
    private costBits(symbols: Array<u32>): i64 {
        const entropyData: EntropyData = this.entropyTracker.peek(symbols);
        return this.entropyTracker.numberOfDataBits(entropyData) +
            ShannonEntropyTracker.getNumberOfRAnsTableBitsStatic(entropyData);
    }

    computeCorrectionValues(
        inData: Int32Array,
        outCorr: Int32Array,
        size: i32,
        numComponents: i32,
        _entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        this.transform.init(inData, size, numComponents);

        if (numComponents == 0 || size % numComponents != 0) {
            return DracoError.invalidParameter(
                `${size} values do not divide into ${numComponents} components`,
            ).fail<bool>();
        }
        if (size == 0) {
            // No values, so no entry 0 for the tail of this function to encode.
            return okStatus();
        }
        const numEntries = size / numComponents;

        const tableOpt = this.meshData.cornerTable();
        if (tableOpt == null) {
            return DracoError.general("Constrained multi-parallelogram prediction has no corner table").fail<bool>();
        }
        const table = tableOpt;
        const v2dOpt = this.meshData.vertexToDataMap();
        if (v2dOpt == null) {
            return DracoError.general(
                "Constrained multi-parallelogram prediction has no vertex-to-data map",
            ).fail<bool>();
        }
        const vertexToDataMap = v2dOpt;

        for (let i = 0; i < MAX_NUM_PARALLELOGRAMS; i++) {
            this.isCreaseEdge[i].length = 0;
        }

        const predVals = new Array<Int32Array>(MAX_NUM_PARALLELOGRAMS);
        for (let i = 0; i < MAX_NUM_PARALLELOGRAMS; i++) predVals[i] = new Int32Array(numComponents);
        const multiPredVals = new Int32Array(numComponents);
        const entropySymbols = new Array<u32>(numComponents);
        const predictedVal = new Int32Array(numComponents);
        const corrVal = new Int32Array(numComponents);

        // Total parallelograms and used parallelograms, for the overhead estimate.
        const totalParallelograms = new StaticArray<i64>(MAX_NUM_PARALLELOGRAMS);
        const totalUsedParallelograms = new StaticArray<i64>(MAX_NUM_PARALLELOGRAMS);
        const corners = new StaticArray<CornerIndex>(MAX_NUM_PARALLELOGRAMS);
        const excluded = new StaticArray<bool>(MAX_NUM_PARALLELOGRAMS);
        const maxSwingSteps = <i64>table.numCorners() + 1;

        // C++ processes entries from the end, because this prediction uses
        // data of earlier entries: backward from numEntries - 1 down to 1.
        for (let dataId = numEntries - 1; dataId >= 1; dataId--) {
            const dataOffset = dataId * numComponents;
            const cornerId = cornerOfEntry(this.meshData, table, dataId);

            if (cornerId == INVALID_CORNER_INDEX) {
                predictedVal.fill(0);
                if (dataId > 0) {
                    const prevOffset = (dataId - 1) * numComponents;
                    for (let c = 0; c < numComponents; c++) predictedVal[c] = inData[prevOffset + c];
                }
                corrVal.fill(0);
                this.transform.computeCorrection(inData, dataOffset, predictedVal, 0, corrVal, 0, numComponents);
                for (let c = 0; c < numComponents; c++) {
                    outCorr[dataOffset + c] = corrVal[c];
                    // An entry that predicted nothing still feeds the tracker
                    // (value minus prediction here).
                    const dif = <i64>inData[dataOffset + c] - <i64>predictedVal[c];
                    entropySymbols[c] = convertSignedIntToSymbol(dif);
                }
                this.entropyTracker.push(entropySymbols);
                continue;
            }

            corners.fill(INVALID_CORNER_INDEX);
            let numParallelograms = 0;

            const startC = cornerId;
            let c = startC;
            let firstPass = true;
            let swingSteps: i64 = 0;
            while (c != INVALID_CORNER_INDEX) {
                swingSteps += 1;
                if (swingSteps > maxSwingSteps) {
                    return DracoError.general(
                        "Corner fan does not close after every corner was visited",
                    ).fail<bool>();
                }
                const opp = table.opposite(c);
                if (opp != INVALID_CORNER_INDEX) {
                    // next/prev come from the opposite corner, as in C++
                    // ComputeParallelogramPrediction().
                    const oppDataId = dataIdOf(vertexToDataMap, table.vertex(opp));
                    const nextDataId = dataIdOf(vertexToDataMap, table.vertexAfter(opp));
                    const prevDataId = dataIdOf(vertexToDataMap, table.vertexBefore(opp));

                    if (
                        oppDataId >= 0 && nextDataId >= 0 && prevDataId >= 0 &&
                        oppDataId < dataId && nextDataId < dataId && prevDataId < dataId &&
                        numParallelograms < MAX_NUM_PARALLELOGRAMS
                    ) {
                        corners[numParallelograms] = c;
                        numParallelograms += 1;
                        if (numParallelograms == MAX_NUM_PARALLELOGRAMS) {
                            break;
                        }
                    }
                }

                // Swing left first; at a boundary, swing right from the start.
                c = firstPass ? table.swingLeft(c) : table.swingRight(c);
                if (c == startC) {
                    break;
                }
                if (c == INVALID_CORNER_INDEX && firstPass) {
                    firstPass = false;
                    c = table.swingRight(startC);
                }
            }

            if (numParallelograms == 0) {
                predictedVal.fill(0);
                if (dataId > 0) {
                    const prevOffset = (dataId - 1) * numComponents;
                    for (let k = 0; k < numComponents; k++) predictedVal[k] = inData[prevOffset + k];
                }
                corrVal.fill(0);
                this.transform.computeCorrection(inData, dataOffset, predictedVal, 0, corrVal, 0, numComponents);
                for (let k = 0; k < numComponents; k++) {
                    outCorr[dataOffset + k] = corrVal[k];
                    // For entropy tracking, C++ uses predicted - actual.
                    const dif = <i64>predictedVal[k] - <i64>inData[dataOffset + k];
                    entropySymbols[k] = convertSignedIntToSymbol(dif);
                }
                this.entropyTracker.push(entropySymbols);
                continue;
            }

            for (let i = 0; i < numParallelograms; i++) {
                const ci = corners[i];
                const oci = table.opposite(ci);
                const vertOpp = vertexToDataMap[<i32>table.vertex(oci)];
                const vertNext = vertexToDataMap[<i32>table.vertexAfter(oci)];
                const vertPrev = vertexToDataMap[<i32>table.vertexBefore(oci)];

                const vOppOff = vertOpp * numComponents;
                const vNextOff = vertNext * numComponents;
                const vPrevOff = vertPrev * numComponents;

                const pv = predVals[i];
                for (let k = 0; k < numComponents; k++) {
                    pv[k] = computeParallelogramPredictionI32(
                        inData[vNextOff + k],
                        inData[vPrevOff + k],
                        inData[vOppOff + k],
                    );
                }
            }

            // C++ increments total_parallelograms before evaluating any
            // configuration.
            const context = numParallelograms - 1;
            totalParallelograms[context] += <i64>numParallelograms;

            // Delta prediction (no parallelogram used): the baseline.
            let bestError = new CostError();
            let bestConfig: u8 = 0;
            let bestNumUsed: i32 = 0;
            {
                predictedVal.fill(0);
                if (dataId > 0) {
                    const prevOffset = (dataId - 1) * numComponents;
                    for (let k = 0; k < numComponents; k++) predictedVal[k] = inData[prevOffset + k];
                }

                const error = new CostError();
                for (let k = 0; k < numComponents; k++) {
                    const dif = <i64>predictedVal[k] - <i64>inData[dataOffset + k];
                    error.residualError += dif < 0 ? -dif : dif;
                    entropySymbols[k] = convertSignedIntToSymbol(dif);
                }
                error.numBits = this.costBits(entropySymbols);
                error.numBits += computeOverheadBits(totalUsedParallelograms[context], totalParallelograms[context]);
                bestError = error;
            }

            // Multi-parallelogram configurations, by increasing count used and,
            // within a count, in C++'s next_permutation order.
            for (let numUsed = 1; numUsed <= numParallelograms; numUsed++) {
                for (let s = 0; s < numParallelograms; s++) {
                    excluded[s] = s >= numUsed;
                }

                const overheadBits = computeOverheadBits(
                    totalUsedParallelograms[context] + <i64>numUsed,
                    totalParallelograms[context],
                );

                while (true) {
                    let config: u32 = 0;
                    for (let i = 0; i < numParallelograms; i++) {
                        if (!excluded[i]) {
                            config |= (<u32>1) << i;
                        }
                    }

                    // Same accumulation as the decoder: AddAsUnsigned (wrapping).
                    for (let k = 0; k < numComponents; k++) {
                        let sum: i32 = 0;
                        for (let i = 0; i < numParallelograms; i++) {
                            if ((config & ((<u32>1) << i)) != 0) {
                                sum = <i32>(<u32>sum + <u32>unchecked(predVals[i])[k]);
                            }
                        }
                        // C++ uses truncating integer division (not rounding).
                        multiPredVals[k] = sum / numUsed;
                    }

                    const error = new CostError();
                    for (let k = 0; k < numComponents; k++) {
                        const dif = <i64>multiPredVals[k] - <i64>inData[dataOffset + k];
                        error.residualError += dif < 0 ? -dif : dif;
                        entropySymbols[k] = convertSignedIntToSymbol(dif);
                    }
                    error.numBits = this.costBits(entropySymbols);
                    error.numBits += overheadBits;

                    if (error.lessThan(bestError)) {
                        bestError = error;
                        bestConfig = <u8>config;
                        bestNumUsed = numUsed;
                    }

                    if (!nextPermutation(excluded, numParallelograms)) {
                        break;
                    }
                }
            }

            // C++ updates total_used_parallelograms after choosing.
            totalUsedParallelograms[context] += <i64>bestNumUsed;

            const flags = this.isCreaseEdge[context];
            for (let i = 0; i < numParallelograms; i++) {
                const isUsed = (<u32>bestConfig & ((<u32>1) << i)) != 0;
                // is_crease_edge stores true when NOT used (crease).
                flags.push(!isUsed);
            }

            // Recompute the prediction for the best config.
            if (bestNumUsed == 0) {
                predictedVal.fill(0);
                if (dataId > 0) {
                    const prevOffset = (dataId - 1) * numComponents;
                    for (let k = 0; k < numComponents; k++) predictedVal[k] = inData[prevOffset + k];
                }
                corrVal.fill(0);
                this.transform.computeCorrection(inData, dataOffset, predictedVal, 0, corrVal, 0, numComponents);
                for (let k = 0; k < numComponents; k++) {
                    outCorr[dataOffset + k] = corrVal[k];
                    const dif = <i64>predictedVal[k] - <i64>inData[dataOffset + k];
                    entropySymbols[k] = convertSignedIntToSymbol(dif);
                }
            } else {
                for (let k = 0; k < numComponents; k++) {
                    let sum: i32 = 0;
                    for (let i = 0; i < numParallelograms; i++) {
                        if ((<u32>bestConfig & ((<u32>1) << i)) != 0) {
                            sum = <i32>(<u32>sum + <u32>unchecked(predVals[i])[k]);
                        }
                    }
                    multiPredVals[k] = sum / bestNumUsed;
                }
                corrVal.fill(0);
                this.transform.computeCorrection(inData, dataOffset, multiPredVals, 0, corrVal, 0, numComponents);
                for (let k = 0; k < numComponents; k++) {
                    outCorr[dataOffset + k] = corrVal[k];
                    const dif = <i64>multiPredVals[k] - <i64>inData[dataOffset + k];
                    entropySymbols[k] = convertSignedIntToSymbol(dif);
                }
            }
            this.entropyTracker.push(entropySymbols);
        }

        // The first entry cannot be predicted: zero prediction, like C++.
        predictedVal.fill(0);
        corrVal.fill(0);
        this.transform.computeCorrection(inData, 0, predictedVal, 0, corrVal, 0, numComponents);
        for (let k = 0; k < numComponents; k++) {
            outCorr[k] = corrVal[k];
        }

        return okStatus();
    }

    encodePredictionData(buffer: ByteVec): Status {
        const enc = new EncoderBuffer();
        // The target version picks the crease-edge rANS size prefix
        // (pre-2.2 u32 vs 2.2+ varint).
        enc.setVersion(<u8>(this.bitstreamVersion >> 8), <u8>(this.bitstreamVersion & 0xff));

        // C++ bitstream order: crease edges first, then transform data.
        for (let i = 0; i < MAX_NUM_PARALLELOGRAMS; i++) {
            const flags = this.isCreaseEdge[i];
            const numFlags = <u32>flags.length;
            enc.encodeVarint(<u64>numFlags);

            if (numFlags > 0) {
                const ansEncoder = new RAnsBitEncoder();
                ansEncoder.startEncoding();

                // Flags are written group by group from the last group back
                // (rANS is LIFO); `i` is the context, so a group is i + 1 flags.
                const numUsedParallelograms = i + 1;
                let j = flags.length - numUsedParallelograms;
                while (j >= 0) {
                    for (let k = 0; k < numUsedParallelograms; k++) {
                        ansEncoder.encodeBit(flags[j + k]);
                    }
                    j -= numUsedParallelograms;
                }

                ansEncoder.endEncoding(enc);
            }
        }

        // Then the underlying transform data (e.g. the wrap bounds).
        const transformData = new ByteVec();
        const s = this.transform.encodeTransformData(transformData);
        if (!s.ok) return s;
        enc.encodeData(transformData.data());

        buffer.extend(enc.data());
        return okStatus();
    }
}

export class MeshPredictionSchemeConstrainedMultiParallelogramDecoder extends PredictionSchemeDecoder {
    meshData: MeshPredictionSchemeData;
    transform: PredictionSchemeDecodingTransform;
    isCreaseEdge: Array<Array<bool>> = [[], [], [], []];

    constructor(transform: PredictionSchemeDecodingTransform, meshData: MeshPredictionSchemeData) {
        super();
        this.meshData = meshData;
        this.transform = transform;
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionConstrainedMultiParallelogram;
    }

    isInitialized(): bool {
        return this.meshData.cornerTable() != null;
    }

    getNumParentAttributes(): i32 {
        return 0;
    }

    getParentAttributeType(_i: i32): GeometryAttributeType {
        return GeometryAttributeType.Generic;
    }

    setParentAttribute(_parent: PredictionParent): Status {
        return DracoError.invalidParameter(
            "The constrained multi-parallelogram prediction scheme takes no parent attribute",
        ).fail<bool>();
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    decodePredictionData(buffer: DecoderBuffer): Status {
        // Bitstream order: (pre-2.2) mode byte, crease-edge flag streams,
        // then the transform data.

        // Pre-2.2 streams prefix a prediction-mode byte (only the optimal
        // multi-parallelogram mode, 0, is supported).
        if (buffer.bitstreamVersion() < 0x0202) {
            const r = buffer.decodeU8();
            if (!r.ok) {
                return DracoError.buffer("Stream ends before the pre-2.2 prediction mode byte").fail<bool>();
            }
            const mode = r.value;
            if (mode != 0) {
                return DracoError.unsupportedFeature(
                    `Constrained multi-parallelogram prediction mode ${mode}`,
                ).fail<bool>();
            }
        }

        const tableOpt = this.meshData.cornerTable();
        if (tableOpt == null) {
            return DracoError.general("Constrained multi-parallelogram prediction has no corner table").fail<bool>();
        }
        const table = tableOpt;

        for (let i = 0; i < MAX_NUM_PARALLELOGRAMS; i++) {
            const r = buffer.decodeVarint();
            if (!r.ok) {
                return DracoError.buffer(
                    `Stream ends before the crease-edge flag count for context ${i}`,
                ).fail<bool>();
            }
            const numFlags = <u32>r.value;

            if (numFlags > <u32>table.numCorners()) {
                return DracoError.general(
                    `Context ${i} declares ${numFlags} crease-edge flags, more than the ${table.numCorners()} corners`,
                ).fail<bool>();
            }

            if (numFlags > 0) {
                const flags = this.isCreaseEdge[i];
                flags.length = <i32>numFlags;
                const ansDecoder = new RAnsBitDecoder();
                if (!ansDecoder.startDecoding(buffer)) {
                    return DracoError.buffer(`Crease-edge rANS stream for context ${i} is truncated`).fail<bool>();
                }
                for (let j = 0; j < <i32>numFlags; j++) {
                    flags[j] = ansDecoder.decodeNextBit();
                }
                ansDecoder.endDecoding();
            }
        }

        // The underlying transform data last (e.g. the wrap bounds).
        return this.transform.decodeTransformData(buffer);
    }

    computeOriginalValues(
        data: Int32Array,
        size: i32,
        numComponents: i32,
        _entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        const si = this.transform.init(numComponents);
        if (!si.ok) return si;

        if (size == 0) {
            return okStatus();
        }
        if (numComponents == 0 || size % numComponents != 0 || size < numComponents) {
            return DracoError.invalidParameter(
                `${size} values do not divide into ${numComponents} components`,
            ).fail<bool>();
        }
        const numEntries = size / numComponents;

        const tableOpt = this.meshData.cornerTable();
        if (tableOpt == null) {
            return DracoError.general("Constrained multi-parallelogram prediction has no corner table").fail<bool>();
        }
        const table = tableOpt;
        const v2dOpt = this.meshData.vertexToDataMap();
        if (v2dOpt == null) {
            return DracoError.general(
                "Constrained multi-parallelogram prediction has no vertex-to-data map",
            ).fail<bool>();
        }
        const vertexToDataMap = v2dOpt;
        if (data.length < size) {
            return DracoError.general(
                `Constrained multi-parallelogram prediction needs ${size} values, has ${data.length}`,
            ).fail<bool>();
        }
        // An i32 count never exceeds u32::MAX, so no count check is needed.

        const multiPredVals = new Int32Array(numComponents);
        const zeroVals = new Int32Array(numComponents);
        const predictedVal = new Int32Array(numComponents);

        // Current position in each context's is_crease_edge.
        const isCreaseEdgePos = new StaticArray<i32>(MAX_NUM_PARALLELOGRAMS);
        // (opp, next, prev) data ids of each qualifying corner's opposite corner.
        const oppIds = new StaticArray<u32>(MAX_NUM_PARALLELOGRAMS);
        const nextIds = new StaticArray<u32>(MAX_NUM_PARALLELOGRAMS);
        const prevIds = new StaticArray<u32>(MAX_NUM_PARALLELOGRAMS);
        const maxSwingSteps = <i64>table.numCorners() + 1;

        // First value.
        this.transform.computeOriginalValue(zeroVals, 0, data, 0, numComponents);

        for (let dataId = 1; dataId < numEntries; dataId++) {
            const dataOffset = dataId * numComponents;
            const cornerId = cornerOfEntry(this.meshData, table, dataId);

            if (cornerId == INVALID_CORNER_INDEX) {
                const prevOffset = (dataId - 1) * numComponents;
                for (let k = 0; k < numComponents; k++) predictedVal[k] = data[prevOffset + k];
                this.transform.computeOriginalValue(predictedVal, 0, data, dataOffset, numComponents);
                continue;
            }

            let numParallelograms = 0;
            const startC = cornerId;
            let c = startC;
            let firstPass = true;
            let swingSteps: i64 = 0;
            while (c != INVALID_CORNER_INDEX) {
                swingSteps += 1;
                if (swingSteps > maxSwingSteps) {
                    return DracoError.general(
                        "Corner fan does not close after every corner was visited",
                    ).fail<bool>();
                }
                const opp = table.opposite(c);
                if (opp != INVALID_CORNER_INDEX) {
                    const oppDataId = dataIdOf(vertexToDataMap, table.vertex(opp));
                    const nextDataId = dataIdOf(vertexToDataMap, table.vertexAfter(opp));
                    const prevDataId = dataIdOf(vertexToDataMap, table.vertexBefore(opp));

                    // `-1` read as a u32 is past every data id, so one
                    // unsigned comparison of the largest answers for all three.
                    let newest = <u32>oppDataId;
                    if (<u32>nextDataId > newest) newest = <u32>nextDataId;
                    if (<u32>prevDataId > newest) newest = <u32>prevDataId;
                    if (newest < <u32>dataId && numParallelograms < MAX_NUM_PARALLELOGRAMS) {
                        oppIds[numParallelograms] = <u32>oppDataId;
                        nextIds[numParallelograms] = <u32>nextDataId;
                        prevIds[numParallelograms] = <u32>prevDataId;
                        numParallelograms += 1;
                        if (numParallelograms == MAX_NUM_PARALLELOGRAMS) {
                            break;
                        }
                    }
                }

                c = firstPass ? table.swingLeft(c) : table.swingRight(c);
                if (c == startC) {
                    break;
                }
                if (c == INVALID_CORNER_INDEX && firstPass) {
                    firstPass = false;
                    c = table.swingRight(startC);
                }
            }

            let numUsedParallelograms = 0;
            if (numParallelograms > 0) {
                // The context is the parallelogram count, fixed for the entry.
                const context = numParallelograms - 1;
                const creases = this.isCreaseEdge[context];
                const firstPos = isCreaseEdgePos[context];
                isCreaseEdgePos[context] += numParallelograms;
                if (firstPos + numParallelograms > creases.length) {
                    return DracoError.general(
                        `Entry ${dataId} reads crease-edge flag ${firstPos + numParallelograms - 1} of ${creases.length} in context ${context}`,
                    ).fail<bool>();
                }

                for (let i = 0; i < numParallelograms; i++) {
                    const isCrease = creases[firstPos + i];
                    if (!isCrease) {
                        const vOppOff = <i64>oppIds[i] * <i64>numComponents;
                        const vNextOff = <i64>nextIds[i] * <i64>numComponents;
                        const vPrevOff = <i64>prevIds[i] * <i64>numComponents;
                        let widest = vOppOff;
                        if (vNextOff > widest) widest = vNextOff;
                        if (vPrevOff > widest) widest = vPrevOff;
                        if (widest + <i64>numComponents > <i64>data.length) {
                            return DracoError.general(
                                "Parallelogram corner reads past the decoded values",
                            ).fail<bool>();
                        }
                        const oOff = <i32>vOppOff;
                        const nOff = <i32>vNextOff;
                        const pOff = <i32>vPrevOff;
                        const accumulate = numUsedParallelograms > 0;
                        for (let k = 0; k < numComponents; k++) {
                            const p = computeParallelogramPredictionI32(data[nOff + k], data[pOff + k], data[oOff + k]);
                            // add_as_unsigned: C++ compatible accumulation.
                            multiPredVals[k] = accumulate ? addAsUnsigned(multiPredVals[k], p) : p;
                        }
                        numUsedParallelograms += 1;
                    }
                }
            }

            if (numUsedParallelograms == 0) {
                const prevOffset = (dataId - 1) * numComponents;
                for (let k = 0; k < numComponents; k++) predictedVal[k] = data[prevOffset + k];
                this.transform.computeOriginalValue(predictedVal, 0, data, dataOffset, numComponents);
            } else {
                // C++ uses truncating integer division (not rounding).
                const divisor = <i64>numUsedParallelograms;
                for (let k = 0; k < numComponents; k++) {
                    multiPredVals[k] = <i32>(<i64>multiPredVals[k] / divisor);
                }
                this.transform.computeOriginalValue(multiPredVals, 0, data, dataOffset, numComponents);
            }
        }
        return okStatus();
    }
}
