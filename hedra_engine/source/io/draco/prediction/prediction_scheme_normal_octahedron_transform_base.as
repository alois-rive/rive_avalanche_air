// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The base octahedral-normal prediction transform.
//
// Shared logic for residual transforms that operate in octahedral normal
// space: corrections are computed and wrapped on the octahedron's 2D quantized
// grid (via OctahedronToolBox) rather than as plain integer deltas. Extended
// by the canonicalized variant.

import { OctCoords, OctahedronToolBox } from "../geometry/normal_compression_utils";
import { PredictionSchemeTransformType } from "./prediction_scheme";

// `u32::is_power_of_two`.
function isPowerOfTwoU32(v: u32): bool {
    return v != 0 && (v & (v - 1)) == 0;
}

export class PredictionSchemeNormalOctahedronTransformBase {
    private maxQuantizedValue_: i32;
    private centerValue_: i32;
    private octahedronToolBox: OctahedronToolBox;

    constructor(maxQuantizedValue: i32) {
        const octahedronToolBox = new OctahedronToolBox();
        // Keep defaults for an uninitialized base. Actual values are set via
        // setMaxQuantizedValue() during decodeTransformData().
        if (maxQuantizedValue > 0) {
            const plusOne = <u32>maxQuantizedValue + 1;
            if (isPowerOfTwoU32(plusOne)) {
                const quantizationBits = <i32>ctz(plusOne);
                octahedronToolBox.setQuantizationBits(quantizationBits);
            }
        }
        this.maxQuantizedValue_ = maxQuantizedValue;
        this.centerValue_ = maxQuantizedValue / 2;
        this.octahedronToolBox = octahedronToolBox;
    }

    setMaxQuantizedValue(maxQuantizedValue: i32): bool {
        // Draco expects max_quantized_value to be of form 2^q - 1.
        if (maxQuantizedValue <= 0) {
            return false;
        }
        if ((maxQuantizedValue & 1) == 0) {
            return false;
        }

        const plusOne = <u32>maxQuantizedValue + 1;
        if (!isPowerOfTwoU32(plusOne)) {
            return false;
        }

        const quantizationBits = <i32>ctz(plusOne);
        if (!this.octahedronToolBox.setQuantizationBits(quantizationBits)) {
            return false;
        }

        this.maxQuantizedValue_ = maxQuantizedValue;
        this.centerValue_ = maxQuantizedValue / 2;
        return true;
    }

    static getType(): PredictionSchemeTransformType {
        return PredictionSchemeTransformType.NormalOctahedron;
    }

    areCorrectionsPositive(): bool {
        return true;
    }

    maxQuantizedValue(): i32 {
        return this.maxQuantizedValue_;
    }

    centerValue(): i32 {
        return this.centerValue_;
    }

    quantizationBits(): i32 {
        return this.octahedronToolBox.quantizationBits();
    }

    isInDiamond(s: i32, t: i32): bool {
        return this.octahedronToolBox.isInDiamond(s, t);
    }

    // Reflects (s, t) across the diamond; the result is returned.
    invertDiamond(s: i32, t: i32): OctCoords {
        return this.octahedronToolBox.invertDiamond(s, t);
    }

    modMax(x: i32): i32 {
        return this.octahedronToolBox.modMax(x);
    }

    makePositive(x: i32): i32 {
        return this.octahedronToolBox.makePositive(x);
    }
}
