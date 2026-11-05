// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The canonicalized octahedral-normal transform base.
//
// Extends the octahedral transform base by rotating each correction into a
// canonical octant before coding, which concentrates residuals and improves
// compression of normals. Shared by the canonicalized encoding and decoding
// transforms. Points are OctCoords value structs (`s`, `t`).

import { OctCoords } from "../geometry/normal_compression_utils";
import { PredictionSchemeTransformType } from "./prediction_scheme";
import { PredictionSchemeNormalOctahedronTransformBase } from "./prediction_scheme_normal_octahedron_transform_base";

export class PredictionSchemeNormalOctahedronCanonicalizedTransformBase {
    private base_: PredictionSchemeNormalOctahedronTransformBase;

    constructor(maxQuantizedValue: i32) {
        this.base_ = new PredictionSchemeNormalOctahedronTransformBase(maxQuantizedValue);
    }

    // The underlying octahedron transform base (shared, mutable).
    base(): PredictionSchemeNormalOctahedronTransformBase {
        return this.base_;
    }

    baseMut(): PredictionSchemeNormalOctahedronTransformBase {
        return this.base_;
    }

    static getType(): PredictionSchemeTransformType {
        return PredictionSchemeTransformType.NormalOctahedronCanonicalized;
    }

    getRotationCount(pred: OctCoords): i32 {
        const signX = pred.s;
        const signY = pred.t;

        if (signX == 0) {
            if (signY == 0) {
                return 0;
            } else if (signY > 0) {
                return 3;
            } else {
                return 1;
            }
        } else if (signX > 0) {
            if (signY >= 0) {
                return 2;
            } else {
                return 1;
            }
        } else if (signY <= 0) {
            return 0;
        } else {
            return 3;
        }
    }

    rotatePoint(p: OctCoords, rotationCount: i32): OctCoords {
        switch (rotationCount) {
            case 1: return OctCoords(p.t, -p.s);
            case 2: return OctCoords(-p.s, -p.t);
            case 3: return OctCoords(-p.t, p.s);
            default: return p;
        }
    }

    isInBottomLeft(p: OctCoords): bool {
        if (p.s == 0 && p.t == 0) {
            return true;
        }
        return p.s < 0 && p.t <= 0;
    }
}
