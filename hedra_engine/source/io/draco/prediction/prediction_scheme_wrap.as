// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The wrap transform.
//
// Maps prediction corrections into the attribute's value range with modular
// wrap-around, so residuals stay small even when a prediction overshoots the
// min/max. The standard residual transform for quantized integer attributes.
// Only the i32 instantiation exists.

import { i64FitsI32 } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DracoError, Status, okStatus } from "../core/status";
import { i32LeBytes } from "../geometry/bytes";
import {
    PredictionSchemeDecodingTransform,
    PredictionSchemeEncodingTransform,
    PredictionSchemeTransformType,
} from "./prediction_scheme";

export class PredictionSchemeWrapEncodingTransform extends PredictionSchemeEncodingTransform {
    numComponents: i32 = 0;
    minValue: i32 = 0;
    maxValue: i32 = 0;
    maxDif: i32 = 0;
    minCorrection: i32 = 0;
    maxCorrection: i32 = 0;

    constructor() {
        super();
    }

    getType(): PredictionSchemeTransformType {
        return PredictionSchemeTransformType.Wrap;
    }

    init(origData: Int32Array, size: i32, numComponents: i32): void {
        this.numComponents = numComponents;

        if (size == 0) {
            return;
        }

        let minVal = origData[0];
        let maxVal = origData[0];

        for (let i = 1; i < size; i++) {
            const val = origData[i];
            if (val < minVal) {
                minVal = val;
            }
            if (val > maxVal) {
                maxVal = val;
            }
        }

        this.minValue = minVal;
        this.maxValue = maxVal;

        // InitCorrectionBounds
        const dif = <i64>maxVal - <i64>minVal;

        this.maxDif = <i32>(1 + dif);
        this.maxCorrection = this.maxDif / 2;
        this.minCorrection = -this.maxCorrection;
        if ((this.maxDif & 1) == 0) {
            this.maxCorrection -= 1;
        }
    }

    computeCorrection(
        originalVals: Int32Array, origOff: i32,
        predictedVals: Int32Array, predOff: i32,
        outCorrVals: Int32Array, outOff: i32,
        _n: i32,
    ): void {
        for (let i = 0; i < this.numComponents; i++) {
            // Clamp predicted value
            let pred = predictedVals[predOff + i];
            if (pred > this.maxValue) {
                pred = this.maxValue;
            } else if (pred < this.minValue) {
                pred = this.minValue;
            }

            let corrVal = originalVals[origOff + i] - pred;

            // Wrap around
            if (corrVal < this.minCorrection) {
                corrVal = corrVal + this.maxDif;
            } else if (corrVal > this.maxCorrection) {
                corrVal = corrVal - this.maxDif;
            }
            outCorrVals[outOff + i] = corrVal;
        }
    }

    encodeTransformData(buffer: ByteVec): Status {
        buffer.extend(i32LeBytes(this.minValue));
        buffer.extend(i32LeBytes(this.maxValue));
        return okStatus();
    }
}

export class PredictionSchemeWrapDecodingTransform extends PredictionSchemeDecodingTransform {
    numComponents: i32 = 0;
    minValue: i32 = 0;
    maxValue: i32 = 0;
    maxDif: i32 = 0;

    constructor() {
        super();
    }

    getType(): PredictionSchemeTransformType {
        return PredictionSchemeTransformType.Wrap;
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
        const minValue = this.minValue;
        const maxValue = this.maxValue;
        const maxDif = this.maxDif;
        for (let i = 0; i < this.numComponents; i++) {
            let pred = predictedVals[predOff + i];
            if (pred < minValue) {
                pred = minValue;
            } else if (pred > maxValue) {
                pred = maxValue;
            }

            // The add is exact: when the i32 sum would overflow, it
            // is taken in i64, where the value sits
            // at most half a span outside [min, max], so the single wrap lands
            // on the value the encoder coded.
            const corr = data[dataOff + i];
            const wide = <i64>pred + <i64>corr;
            let val: i32;
            if (i64FitsI32(wide)) {
                const sum = <i32>wide;
                if (sum < minValue) {
                    val = sum + maxDif;
                } else if (sum > maxValue) {
                    val = sum - maxDif;
                } else {
                    val = sum;
                }
            } else {
                if (wide > <i64>maxValue) {
                    val = <i32>(wide - <i64>maxDif);
                } else {
                    val = <i32>(wide + <i64>maxDif);
                }
            }

            data[dataOff + i] = val;
        }
    }

    decodeTransformData(buffer: DecoderBuffer): Status {
        const rMin = buffer.decode<i32>();
        if (!rMin.ok) {
            return DracoError.buffer("Stream ends before the wrap transform's minimum value").fail<bool>();
        }
        const minValue = rMin.value;
        const rMax = buffer.decode<i32>();
        if (!rMax.ok) {
            return DracoError.buffer("Stream ends before the wrap transform's maximum value").fail<bool>();
        }
        const maxValue = rMax.value;

        // Both bounds are read straight off the wire; everything below assumes
        // the range is non-empty and that its span is representable.
        const dif = <i64>maxValue - <i64>minValue;
        if (dif < 0) {
            return DracoError.general(
                `Wrap transform's range is empty: minimum ${minValue} is above maximum ${maxValue}`,
            ).fail<bool>();
        }
        // (dif >= i32.MAX_VALUE: dif is 0 or more)
        if (!i64FitsI32(dif + 1)) {
            return DracoError.general(
                `Wrap transform's range ${minValue}..=${maxValue} is too wide for its span to be represented`,
            ).fail<bool>();
        }

        this.minValue = minValue;
        this.maxValue = maxValue;
        this.maxDif = 1 + <i32>dif;

        return okStatus();
    }
}
