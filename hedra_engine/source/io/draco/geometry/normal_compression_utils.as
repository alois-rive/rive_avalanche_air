// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// OctahedronToolBox converts unit normals to and from the quantized 2D
// octahedral representation and provides the wrap/clamp math the normal
// transforms and predictors use.
//
// Conventions:
//   (s, t) pairs, including invertDiamond's result  -> OctCoords struct (returned by value)
//   3-component integer or float inputs              -> StaticArray<f32> / StaticArray<i32> (mutated in place)
//   3-component float results                        -> Vec3 (vecmath value struct)
// Integer arithmetic wraps on overflow.

import { f64ToI32, minF32 } from "../../../../base/util";
import { Vec3 } from "../../../../base/vecmath";

// An octahedral coordinate pair `(s, t)`.
export struct OctCoords {
    s: i32 = 0;
    t: i32 = 0;

    constructor(s: i32, t: i32) {
        this.s = s;
        this.t = t;
    }
}

function wrappingAbs(v: i32): i32 {
    return v < 0 ? -v : v;
}

export class OctahedronToolBox {
    private quantizationBits_: i32 = 0;
    private maxQuantizedValue_: i32 = 0;
    private maxValue_: i32 = 0;
    private dequantizationScale: f32 = 0;
    private centerValue_: i32 = 0;
    // Reused by floatVectorToQuantizedOctahedralCoords3.
    private scratch: StaticArray<i32> = new StaticArray<i32>(3);

    constructor() {}

    setQuantizationBits(q: i32): bool {
        if (!(q >= 2 && q <= 30)) {
            return false;
        }
        this.quantizationBits_ = q;
        this.maxQuantizedValue_ = (1 << q) - 1;
        this.maxValue_ = this.maxQuantizedValue_ - 1;
        this.dequantizationScale = <f32>2 / <f32>this.maxValue_;
        this.centerValue_ = this.maxValue_ / 2;
        return true;
    }

    isInitialized(): bool {
        return this.quantizationBits_ != -1;
    }

    quantizationBits(): i32 { return this.quantizationBits_; }
    maxQuantizedValue(): i32 { return this.maxQuantizedValue_; }
    maxValue(): i32 { return this.maxValue_; }
    centerValue(): i32 { return this.centerValue_; }

    // Whether `(s, t)`, with the centre already at the origin, is inside the
    // diamond (no range assertion: the decode path cannot honour it).
    isInDiamond(s: i32, t: i32): bool {
        const st = <u32>wrappingAbs(s) + <u32>wrappingAbs(t);
        return st <= <u32>this.centerValue_;
    }

    // Reflects `(s, t)` across the diamond's edge.
    invertDiamond(s: i32, t: i32): OctCoords {
        let signS: i32;
        let signT: i32;
        if (s >= 0 && t >= 0) {
            signS = 1;
            signT = 1;
        } else if (s <= 0 && t <= 0) {
            signS = -1;
            signT = -1;
        } else {
            signS = s > 0 ? 1 : -1;
            signT = t > 0 ? 1 : -1;
        }

        // Unsigned arithmetic, to avoid signed overflow on bad data.
        const cornerPointS = <u32>(signS * this.centerValue_);
        const cornerPointT = <u32>(signT * this.centerValue_);

        let us = <u32>s;
        let ut = <u32>t;

        us = us + us - cornerPointS;
        ut = ut + ut - cornerPointT;

        if (signS * signT >= 0) {
            const temp = us;
            us = <u32>(-(<i32>ut));
            ut = <u32>(-(<i32>temp));
        } else {
            const temp = us;
            us = ut;
            ut = temp;
        }

        us = us + cornerPointS;
        ut = ut + cornerPointT;

        let rs = <i32>us;
        let rt = <i32>ut;
        rs /= 2;
        rt /= 2;
        return OctCoords(rs, rt);
    }

    invertDirection(s: i32, t: i32): OctCoords {
        return this.invertDiamond(s * -1, t * -1);
    }

    modMax(x: i32): i32 {
        const over = <i32>(x > this.centerValue_);
        const under = <i32>(x < -this.centerValue_);
        return x + (under - over) * this.maxQuantizedValue_;
    }

    modMaxPositive(x: i32): i32 {
        return x & this.maxQuantizedValue_;
    }

    makePositive(x: i32): i32 {
        if (x < 0) {
            return x + this.maxQuantizedValue_;
        }
        return x;
    }

    canonicalizeOctahedralCoords(s0: i32, t0: i32): OctCoords {
        let s = s0;
        let t = t0;
        const isCorner = (s == 0 && (t == 0 || t == this.maxValue_)) || (s == this.maxValue_ && t == 0);
        if (isCorner) {
            s = this.maxValue_;
            t = this.maxValue_;
        } else if (s == 0 && t > this.centerValue_) {
            t = this.centerValue_ - (t - this.centerValue_);
        } else if (s == this.maxValue_ && t < this.centerValue_) {
            t = this.centerValue_ + (this.centerValue_ - t);
        } else if (t == this.maxValue_ && s < this.centerValue_) {
            s = this.centerValue_ + (this.centerValue_ - s);
        } else if (t == 0 && s > this.centerValue_) {
            s = this.centerValue_ - (s - this.centerValue_);
        }
        return OctCoords(s, t);
    }

    // Scales an integer vector (in place) onto the `|x| + |y| + |z| =
    // center_value` diamond. Absolute values wrap at i32::MIN.
    canonicalizeIntegerVector(vec: StaticArray<i32>): void {
        const absSum = <i64>wrappingAbs(vec[0]) + <i64>wrappingAbs(vec[1]) + <i64>wrappingAbs(vec[2]);

        if (absSum == 0) {
            vec[0] = this.centerValue_;
            vec[1] = 0;
            vec[2] = 0;
        } else {
            vec[0] = <i32>((<i64>vec[0] * <i64>this.centerValue_) / absSum);
            vec[1] = <i32>((<i64>vec[1] * <i64>this.centerValue_) / absSum);
            const remainder = this.centerValue_ - wrappingAbs(vec[0]) - wrappingAbs(vec[1]);
            vec[2] = vec[2] >= 0 ? remainder : -remainder;
        }
    }

    integerVectorToQuantizedOctahedralCoords(intVec: StaticArray<i32>): OctCoords {
        let s: i32;
        let t: i32;
        if (intVec[0] >= 0) {
            // Right hemisphere.
            s = intVec[1] + this.centerValue_;
            t = intVec[2] + this.centerValue_;
        } else {
            // Left hemisphere.
            if (intVec[1] < 0) {
                s = wrappingAbs(intVec[2]);
            } else {
                s = this.maxValue_ - wrappingAbs(intVec[2]);
            }
            if (intVec[2] < 0) {
                t = wrappingAbs(intVec[1]);
            } else {
                t = this.maxValue_ - wrappingAbs(intVec[1]);
            }
        }
        return this.canonicalizeOctahedralCoords(s, t);
    }

    // Done in f64, as upstream does it (the floored value lands exactly on .5
    // for ordinary normals, and f32 resolves that tie the other way).
    floatVectorToQuantizedOctahedralCoords(vector: StaticArray<f32>): OctCoords {
        return this.floatVectorToQuantizedOctahedralCoords3(vector[0], vector[1], vector[2]);
    }

    // floatVectorToQuantizedOctahedralCoords on three scalars.
    floatVectorToQuantizedOctahedralCoords3(v0: f32, v1: f32, v2: f32): OctCoords {
        const absSum: f64 = Math.abs(<f64>v0) + Math.abs(<f64>v1) + Math.abs(<f64>v2);

        // Adjust values such that abs sum equals 1.
        let sv0: f64 = 0;
        let sv1: f64 = 0;
        let sv2: f64 = 0;
        if (absSum > 1e-6) {
            const scale: f64 = 1.0 / absSum;
            sv0 = <f64>v0 * scale;
            sv1 = <f64>v1 * scale;
            sv2 = <f64>v2 * scale;
        } else {
            sv0 = 1.0;
            sv1 = 0.0;
            sv2 = 0.0;
        }

        // Scale vector such that the sum equals the center value.
        const intVec = this.scratch;
        intVec[0] = f64ToI32(Math.floor(sv0 * <f64>this.centerValue_ + 0.5));
        intVec[1] = f64ToI32(Math.floor(sv1 * <f64>this.centerValue_ + 0.5));

        // Make sure the sum is exactly the center value.
        intVec[2] = this.centerValue_ - wrappingAbs(intVec[0]) - wrappingAbs(intVec[1]);
        if (intVec[2] < 0) {
            // The first two coordinates are too long: shorten one of them.
            if (intVec[1] > 0) {
                intVec[1] += intVec[2];
            } else {
                intVec[1] -= intVec[2];
            }
            intVec[2] = 0;
        }
        // Take care of the sign.
        if (sv2 < 0.0) {
            intVec[2] *= -1;
        }

        return this.integerVectorToQuantizedOctahedralCoords(intVec);
    }

    quantizedOctahedralCoordsToUnitVector(s: i32, t: i32): Vec3 {
        // Scale s and t to [-1, 1].
        const inSScaled: f32 = <f32>s * this.dequantizationScale - <f32>1;
        const inTScaled: f32 = <f32>t * this.dequantizationScale - <f32>1;

        // s is y, t is z, and x comes from the octahedron constraint.
        let y: f32 = inSScaled;
        let z: f32 = inTScaled;
        const x: f32 = <f32>1 - Mathf.abs(y) - Mathf.abs(z);

        // The left hemisphere (x < 0) unwraps along the diamond's diagonals.
        if (x < <f32>0) {
            const xOffset: f32 = -x;
            y += y < <f32>0 ? xOffset : -xOffset;
            z += z < <f32>0 ? xOffset : -xOffset;
        }

        const normSquared: f32 = x * x + y * y + z * z;
        if (normSquared < <f32>1e-6) {
            return Vec3(0, 0, 0);
        }
        const d: f32 = <f32>1 / Mathf.sqrt(normSquared);
        return Vec3(x * d, y * d, z * d);
    }

    quantizedOctahedralCoordsToUnitVectorLegacy(s: i32, t: i32): Vec3 {
        const maxQuantizedValue = <f32>this.maxValue_;
        const inS: f32 = <f32>s / maxQuantizedValue;
        const inT: f32 = <f32>t / maxQuantizedValue;

        let outS: f32 = inS;
        let outT: f32 = inT;
        let spt: f32 = outS + outT;
        let smt: f32 = outS - outT;
        let xSign: f32 = 1;

        if (!(spt >= <f32>0.5 && spt <= <f32>1.5) || !(smt >= <f32>-0.5 && smt <= <f32>0.5)) {
            xSign = -1;
            if (spt <= <f32>0.5) {
                outS = <f32>0.5 - inT;
                outT = <f32>0.5 - inS;
            } else if (spt >= <f32>1.5) {
                outS = <f32>1.5 - inT;
                outT = <f32>1.5 - inS;
            } else if (smt <= <f32>-0.5) {
                outS = inT - <f32>0.5;
                outT = inS + <f32>0.5;
            } else {
                outS = inT + <f32>0.5;
                outT = inS - <f32>0.5;
            }
            spt = outS + outT;
            smt = outS - outT;
        }

        const y: f32 = <f32>2 * outS - <f32>1;
        const z: f32 = <f32>2 * outT - <f32>1;
        const x: f32 =
            minF32(minF32(minF32(<f32>2 * spt - <f32>1, <f32>3 - <f32>2 * spt), <f32>2 * smt + <f32>1), <f32>1 - <f32>2 * smt) *
            xSign;

        const normSquared: f32 = x * x + y * y + z * z;
        if (normSquared < <f32>1e-6) {
            return Vec3(0, 0, 0);
        }
        const d: f32 = <f32>1 / Mathf.sqrt(normSquared);
        return Vec3(x * d, y * d, z * d);
    }

    clone(): OctahedronToolBox {
        const o = new OctahedronToolBox();
        o.quantizationBits_ = this.quantizationBits_;
        o.maxQuantizedValue_ = this.maxQuantizedValue_;
        o.maxValue_ = this.maxValue_;
        o.dequantizationScale = this.dequantizationScale;
        o.centerValue_ = this.centerValue_;
        return o;
    }
}
