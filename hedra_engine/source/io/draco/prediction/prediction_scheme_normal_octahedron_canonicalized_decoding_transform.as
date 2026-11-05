// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The decode side of the canonicalized normal transform.
//
// Reads the quantization parameters and inverts the canonical-octant rotation
// to reconstruct the octahedral normal. With `setCanonicalized(false)` it is
// the pre-canonicalized octahedron transform (id 2, Draco <= 0.9.1): it skips
// only the canonical-octant rotation and keeps the shared diamond inversion
// and correction steps.

import { panic } from "../../../../base/util";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DracoError, Status, okStatus } from "../core/status";
import { OctCoords } from "../geometry/normal_compression_utils";
import { PredictionSchemeDecodingTransform, PredictionSchemeTransformType } from "./prediction_scheme";
import { PredictionSchemeNormalOctahedronCanonicalizedTransformBase } from "./prediction_scheme_normal_octahedron_canonicalized_transform_base";

export class PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform extends PredictionSchemeDecodingTransform {
    private base: PredictionSchemeNormalOctahedronCanonicalizedTransformBase;
    numComponents: i32 = 0;
    private isCanonicalized: bool = true;

    constructor() {
        super();
        this.base = new PredictionSchemeNormalOctahedronCanonicalizedTransformBase(0);
    }

    // Selects the canonicalized (id 3) vs the legacy non-canonicalized (id 2)
    // octahedron transform. Defaults to canonicalized.
    setCanonicalized(canonicalized: bool): void {
        this.isCanonicalized = canonicalized;
    }

    maxQuantizedValue(): i32 {
        return this.base.base().maxQuantizedValue();
    }

    quantizationBits(): i32 {
        return this.base.base().quantizationBits();
    }

    init(numComponents: i32): Status {
        // An octahedral value is a coordinate pair, and this reads and writes
        // both without asking: refuse any other width once, here.
        if (numComponents != 2) {
            return DracoError.invalidParameter(
                `Octahedral transform needs 2 components, got ${numComponents}`,
            ).fail<bool>();
        }
        this.numComponents = numComponents;
        return okStatus();
    }

    decodeTransformData(buffer: DecoderBuffer): Status {
        const rMax = buffer.decode<i32>();
        if (!rMax.ok) {
            return DracoError.buffer(
                "Stream ends before the octahedral transform's maximum quantized value",
            ).fail<bool>();
        }
        const maxQuantizedValue = rMax.value;
        const rCenter = buffer.decode<i32>();
        if (!rCenter.ok) {
            return DracoError.buffer("Stream ends before the octahedral transform's center value").fail<bool>();
        }

        if (!this.base.baseMut().setMaxQuantizedValue(maxQuantizedValue)) {
            return DracoError.invalidParameter(
                `Octahedral maximum quantized value ${maxQuantizedValue} is not representable`,
            ).fail<bool>();
        }
        // Account for wrong values (e.g., due to stream mismatch/fuzzing).
        // C++ requires quantization bits in [2, 30].
        const q = this.base.base().quantizationBits();
        if (!(q >= 2 && q <= 30)) {
            return DracoError.invalidParameter(
                `Octahedral quantization bits ${q} outside the supported range 2..=30`,
            ).fail<bool>();
        }
        return okStatus();
    }

    computeOriginalValue(
        predVals: Int32Array, predOff: i32,
        data: Int32Array, dataOff: i32,
        n: i32,
    ): void {
        // Components [0] and [1] are read: fewer than two panics.
        if (n < 2) {
            panic(`index out of bounds: the len is ${n} but the index is ${n}`);
        }
        const b = this.base.base();
        const center = b.centerValue();

        let pred = OctCoords(predVals[predOff] - center, predVals[predOff + 1] - center);
        const corrS = data[dataOff];
        const corrT = data[dataOff + 1];

        const predIsInDiamond = b.isInDiamond(pred.s, pred.t);
        if (!predIsInDiamond) {
            pred = b.invertDiamond(pred.s, pred.t);
        }

        // The canonical-octant rotation is only part of the canonicalized
        // (id 3) transform.
        let predIsInBottomLeft = false;
        let rotationCount = 0;
        if (this.isCanonicalized) {
            predIsInBottomLeft = this.base.isInBottomLeft(pred);
            rotationCount = this.base.getRotationCount(pred);
            if (!predIsInBottomLeft) {
                pred = this.base.rotatePoint(pred, rotationCount);
            }
        }

        let orig = OctCoords(b.modMax(pred.s + corrS), b.modMax(pred.t + corrT));

        // The trailing diamond inversion is part of both the old (id 2) and
        // the canonicalized (id 3) transform.
        if (this.isCanonicalized && !predIsInBottomLeft) {
            const reverseRotationCount = (4 - rotationCount) % 4;
            orig = this.base.rotatePoint(orig, reverseRotationCount);
        }
        if (!predIsInDiamond) {
            orig = b.invertDiamond(orig.s, orig.t);
        }

        data[dataOff] = orig.s + center;
        data[dataOff + 1] = orig.t + center;
    }

    getType(): PredictionSchemeTransformType {
        if (this.isCanonicalized) {
            return PredictionSchemeTransformType.NormalOctahedronCanonicalized;
        }
        return PredictionSchemeTransformType.NormalOctahedron;
    }

    areCorrectionsPositive(): bool {
        // Corrections from octahedron transforms are always in [0, max_quantized_value]
        return true;
    }
}
