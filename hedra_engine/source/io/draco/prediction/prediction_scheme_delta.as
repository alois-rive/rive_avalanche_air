// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The delta transform and the difference predictor.
//
// The simplest residual transform: the correction is `value - prediction`,
// stored directly with no range wrapping. Paired with the difference
// predictor (each entry predicted by the previous one) it is the default
// scheme when no mesh connectivity is available.

import { panic } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DracoError, Status, okStatus } from "../core/status";
import { GeometryAttributeType } from "../geometry/geometry_attribute";
import { PredictionParent } from "../geometry/portable_attribute";
import {
    EntryToPointIdMap,
    PredictionSchemeDecoder,
    PredictionSchemeDecodingTransform,
    PredictionSchemeEncoder,
    PredictionSchemeEncodingTransform,
    PredictionSchemeMethod,
    PredictionSchemeTransformType,
} from "./prediction_scheme";

export class PredictionSchemeDeltaEncodingTransform extends PredictionSchemeEncodingTransform {
    numComponents: i32 = 0;

    constructor() {
        super();
    }

    init(_origData: Int32Array, _size: i32, numComponents: i32): void {
        this.numComponents = numComponents;
    }

    computeCorrection(
        originalVals: Int32Array, origOff: i32,
        predictedVals: Int32Array, predOff: i32,
        outCorrVals: Int32Array, outOff: i32,
        _n: i32,
    ): void {
        for (let i = 0; i < this.numComponents; i++) {
            outCorrVals[outOff + i] = originalVals[origOff + i] - predictedVals[predOff + i];
        }
    }

    encodeTransformData(_buffer: ByteVec): Status {
        return okStatus();
    }

    getType(): PredictionSchemeTransformType {
        return PredictionSchemeTransformType.Delta;
    }
}

export class PredictionSchemeDeltaDecodingTransform extends PredictionSchemeDecodingTransform {
    numComponents: i32 = 0;

    constructor() {
        super();
    }

    init(numComponents: i32): Status {
        this.numComponents = numComponents;
        return okStatus();
    }

    computeOriginalValue(
        predictedVals: Int32Array, predOff: i32,
        data: Int32Array, dataOff: i32,
        _n: i32,
    ): void {
        for (let i = 0; i < this.numComponents; i++) {
            data[dataOff + i] = predictedVals[predOff + i] + data[dataOff + i];
        }
    }

    decodeTransformData(_buffer: DecoderBuffer): Status {
        return okStatus();
    }

    getType(): PredictionSchemeTransformType {
        return PredictionSchemeTransformType.Delta;
    }
}

export class PredictionSchemeDeltaEncoder extends PredictionSchemeEncoder {
    transform: PredictionSchemeEncodingTransform;

    constructor(transform: PredictionSchemeEncodingTransform) {
        super();
        this.transform = transform;
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.Difference;
    }

    isInitialized(): bool {
        return true;
    }

    getNumParentAttributes(): i32 {
        return 0;
    }

    getParentAttributeType(_i: i32): GeometryAttributeType {
        return GeometryAttributeType.Invalid;
    }

    setParentAttribute(_parent: PredictionParent): Status {
        return DracoError.invalidParameter("The delta prediction scheme takes no parent attribute").fail<bool>();
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    areCorrectionsPositive(): bool {
        return this.transform.areCorrectionsPositive();
    }

    computeCorrectionValues(
        inData: Int32Array,
        outCorr: Int32Array,
        size: i32,
        numComponents: i32,
        _entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        this.transform.init(inData, size, numComponents);

        // No values means no entry 0, which the tail encodes unconditionally,
        // and `size - numComponents` below would wrap.
        if (numComponents == 0 || size % numComponents != 0) {
            return DracoError.invalidParameter(
                `${size} values do not divide into ${numComponents} components`,
            ).fail<bool>();
        }
        if (size == 0) {
            return okStatus();
        }

        // Encode data from the back using D(i) = D(i) - D(i - 1).
        let i = size - numComponents;
        while (i > 0) {
            this.transform.computeCorrection(inData, i, inData, i - numComponents, outCorr, i, numComponents);
            if (i < numComponents) {
                break;
            }
            i -= numComponents;
        }

        // Encode correction for the first element.
        const zeroVals = new Int32Array(numComponents);
        this.transform.computeCorrection(inData, 0, zeroVals, 0, outCorr, 0, numComponents);

        return okStatus();
    }

    encodePredictionData(buffer: ByteVec): Status {
        return this.transform.encodeTransformData(buffer);
    }
}

export class PredictionSchemeDeltaDecoder extends PredictionSchemeDecoder {
    transform: PredictionSchemeDecodingTransform;

    constructor(transform: PredictionSchemeDecodingTransform) {
        super();
        this.transform = transform;
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.Difference;
    }

    isInitialized(): bool {
        return true;
    }

    getNumParentAttributes(): i32 {
        return 0;
    }

    getParentAttributeType(_i: i32): GeometryAttributeType {
        return GeometryAttributeType.Invalid;
    }

    setParentAttribute(_parent: PredictionParent): Status {
        return DracoError.invalidParameter("The delta prediction scheme takes no parent attribute").fail<bool>();
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    areCorrectionsPositive(): bool {
        return this.transform.areCorrectionsPositive();
    }

    computeOriginalValues(
        data: Int32Array,
        size: i32,
        numComponents: i32,
        _entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        const s = this.transform.init(numComponents);
        if (!s.ok) return s;

        // The first element has no predecessor, so it predicts from zeros.
        // Reading `data[0..numComponents]` panics past the end.
        if (numComponents > data.length) {
            panic(`range end index ${numComponents} out of range for slice of length ${data.length}`);
        }
        const zeros = new Int32Array(numComponents);
        this.transform.computeOriginalValue(zeros, 0, data, 0, numComponents);

        // Stepping by `numComponents` needs a non-zero step.
        if (numComponents == 0) {
            panic("assertion failed: step != 0");
        }
        // Decode data from the front using D(i) = D(i) + D(i - 1): the
        // previous entry is the prediction, already sitting in `data`.
        for (let i = numComponents; i < size; i += numComponents) {
            this.transform.computeOriginalValue(data, i - numComponents, data, i, numComponents);
        }

        return okStatus();
    }

    decodePredictionData(buffer: DecoderBuffer): Status {
        return this.transform.decodeTransformData(buffer);
    }
}
