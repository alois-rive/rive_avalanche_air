// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The encode side of the canonicalized normal transform.
//
// Rotates each correction into a canonical octant and writes the quantization
// parameters so the decoder can invert it. With `setCanonicalized(false)` it
// is the legacy non-canonicalized octahedron transform (id 2).

import { panic } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { Status, okStatus } from "../core/status";
import { i32LeBytes } from "../geometry/bytes";
import { OctCoords } from "../geometry/normal_compression_utils";
import { PredictionSchemeEncodingTransform, PredictionSchemeTransformType } from "./prediction_scheme";
import { PredictionSchemeNormalOctahedronCanonicalizedTransformBase } from "./prediction_scheme_normal_octahedron_canonicalized_transform_base";

export class PredictionSchemeNormalOctahedronCanonicalizedEncodingTransform extends PredictionSchemeEncodingTransform {
    private base: PredictionSchemeNormalOctahedronCanonicalizedTransformBase;
    numComponents: i32 = 0;
    // When false, emits and computes corrections for the legacy
    // non-canonicalized octahedron transform (id 2, Draco <= 0.9.1).
    private isCanonicalized: bool = true;

    constructor(maxQuantizedValue: i32) {
        super();
        this.base = new PredictionSchemeNormalOctahedronCanonicalizedTransformBase(maxQuantizedValue);
    }

    // Quantization bits behind the transform's max value, which the
    // geometric-normal encoder needs to set up its octahedron toolbox.
    quantizationBits(): i32 {
        return this.base.base().quantizationBits();
    }

    // Selects the canonicalized (id 3) vs legacy non-canonicalized (id 2)
    // octahedron transform. Defaults to canonicalized.
    setCanonicalized(canonicalized: bool): void {
        this.isCanonicalized = canonicalized;
    }

    init(_origData: Int32Array, _size: i32, numComponents: i32): void {
        this.numComponents = numComponents;
    }

    encodeTransformData(buffer: ByteVec): Status {
        buffer.extend(i32LeBytes(this.base.base().maxQuantizedValue()));
        buffer.extend(i32LeBytes(this.base.base().centerValue()));
        return okStatus();
    }

    computeCorrection(
        origVals: Int32Array, origOff: i32,
        predVals: Int32Array, predOff: i32,
        outCorrVals: Int32Array, outOff: i32,
        n: i32,
    ): void {
        // Components [0] and [1] are read: fewer than two panics.
        if (n < 2) {
            panic(`index out of bounds: the len is ${n} but the index is ${n}`);
        }
        const b = this.base.base();
        const center = b.centerValue();

        let orig = OctCoords(origVals[origOff] - center, origVals[origOff + 1] - center);
        let pred = OctCoords(predVals[predOff] - center, predVals[predOff + 1] - center);

        if (!b.isInDiamond(pred.s, pred.t)) {
            orig = b.invertDiamond(orig.s, orig.t);
            pred = b.invertDiamond(pred.s, pred.t);
        }

        // Canonicalized id 3 rotates to a canonical octant. Legacy id 2 skips
        // the rotation while keeping the shared diamond handling.
        if (this.isCanonicalized && !this.base.isInBottomLeft(pred)) {
            const rotationCount = this.base.getRotationCount(pred);
            pred = this.base.rotatePoint(pred, rotationCount);
            orig = this.base.rotatePoint(orig, rotationCount);
        }

        outCorrVals[outOff] = b.makePositive(orig.s - pred.s);
        outCorrVals[outOff + 1] = b.makePositive(orig.t - pred.t);
    }

    getType(): PredictionSchemeTransformType {
        if (this.isCanonicalized) {
            return PredictionSchemeTransformType.NormalOctahedronCanonicalized;
        }
        return PredictionSchemeTransformType.NormalOctahedron;
    }

    areCorrectionsPositive(): bool {
        // Corrections from octahedron transforms are always in
        // [0, max_quantized_value] because makePositive() ensures they are
        // non-negative.
        return true;
    }
}
