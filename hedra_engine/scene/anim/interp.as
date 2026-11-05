// Rive's keyframe interpolators (milestone 45, docs/plans/RIVE_MODEL.md
// section 1.2), ported from rive-runtime with its f32 arithmetic and
// constants: src/animation/cubic_ease_interpolator.cpp,
// cubic_value_interpolator.cpp, cubic_interpolator_solver.cpp (the
// bezier's x solved for t: an 11-sample table, then 4 Newton steps or 10
// bisections), elastic_interpolator.cpp and elastic_ease.cpp. Every
// operation is an f32 one in the order Rive's C++ writes it (Mathf: sinf,
// powf, asinf), so that a scene's timeline gives the numbers a Rive
// artboard's gives for the same keys; the parity suite
// (cli/tests/scene/test_rive_anim.py) compares the two frame by frame
// against the pinned rive.
//
// Made once per key when an animation is prepared (./animation.as) and
// shared by every instance: evaluating allocates nothing.

import { ELASTIC_EASE_IN, ELASTIC_EASE_IN_OUT, ELASTIC_EASE_OUT, InterpolatorDecl, InterpolatorKind } from "./decl";

// rive::math::PI.
const PI: f32 = 3.14159265;

// cubic_interpolator_solver.cpp's constants, verbatim.
const NEWTON_ITERATIONS: i32 = 4;
const NEWTON_MIN_SLOPE: f32 = 0.001;
const SUBDIVISION_PRECISION: f32 = 0.0000001;
const SUBDIVISION_MAX_ITERATIONS: i32 = 10;
const SPLINE_TABLE_SIZE: i32 = 11;
// 1.0f / (SplineTableSize - 1.0f)
const SAMPLE_STEP_SIZE: f32 = <f32>1.0 / (<f32>SPLINE_TABLE_SIZE - <f32>1.0);

const ONE: f32 = 1;
const TWO: f32 = 2;
const THREE: f32 = 3;
const SIX: f32 = 6;
const TEN: f32 = 10;
const HALF: f32 = 0.5;

// CubicInterpolatorSolver::calcBezier: x(t) given x1 and x2, or y(t) given
// y1 and y2.
export function calcBezier(aT: f32, aA1: f32, aA2: f32): f32 {
    return (((ONE - THREE * aA2 + THREE * aA1) * aT + (THREE * aA2 - SIX * aA1)) * aT + (THREE * aA1)) * aT;
}

// getSlope: dx/dt given t, x1 and x2.
function getSlope(aT: f32, aA1: f32, aA2: f32): f32 {
    return THREE * (ONE - THREE * aA2 + THREE * aA1) * aT * aT + TWO * (THREE * aA2 - SIX * aA1) * aT + (THREE * aA1);
}

// Rive's CubicInterpolatorSolver: x(t) sampled at 11 points when built,
// then getT(x) finds t for an x.
export class CubicSolver {
    private values: StaticArray<f32> = new StaticArray<f32>(SPLINE_TABLE_SIZE);
    private x1: f32 = 0;
    private x2: f32 = 0;

    build(x1: f32, x2: f32): void {
        this.x1 = x1;
        this.x2 = x2;
        for (let i = 0; i < SPLINE_TABLE_SIZE; ++i) {
            unchecked(this.values[i] = calcBezier(<f32>i * SAMPLE_STEP_SIZE, x1, x2));
        }
    }

    getT(x: f32): f32 {
        const values = this.values;
        let intervalStart: f32 = 0;
        let currentSample = 1;
        const lastSample = SPLINE_TABLE_SIZE - 1;
        for (; currentSample != lastSample && unchecked(values[currentSample]) <= x; ++currentSample) {
            intervalStart += SAMPLE_STEP_SIZE;
        }
        --currentSample;

        // Interpolate to provide an initial guess for t.
        const at = unchecked(values[currentSample]);
        const dist: f32 = (x - at) / (unchecked(values[currentSample + 1]) - at);
        let guessForT: f32 = intervalStart + dist * SAMPLE_STEP_SIZE;

        const initialSlope = getSlope(guessForT, this.x1, this.x2);
        if (initialSlope >= NEWTON_MIN_SLOPE) {
            for (let i = 0; i < NEWTON_ITERATIONS; ++i) {
                const currentSlope = getSlope(guessForT, this.x1, this.x2);
                if (currentSlope == 0) return guessForT;
                const currentX: f32 = calcBezier(guessForT, this.x1, this.x2) - x;
                guessForT -= currentX / currentSlope;
            }
            return guessForT;
        } else if (initialSlope == 0) {
            return guessForT;
        }
        let aB: f32 = intervalStart + SAMPLE_STEP_SIZE;
        let currentX: f32 = 0;
        let currentT: f32 = 0;
        let i = 0;
        do {
            currentT = intervalStart + (aB - intervalStart) / TWO;
            currentX = calcBezier(currentT, this.x1, this.x2) - x;
            if (currentX > 0) aB = currentT;
            else intervalStart = currentT;
        } while (Mathf.abs(currentX) > SUBDIVISION_PRECISION && ++i < SUBDIVISION_MAX_ITERATIONS);
        return currentT;
    }
}

// Rive's ElasticEase: the decaying sine of an elastic key, its phase shift
// `s` computed once.
export class ElasticEase {
    amplitude: f32;
    period: f32;
    s: f32;

    constructor(amplitude: f32, period: f32) {
        this.amplitude = amplitude;
        this.period = period;
        this.s = amplitude < ONE ? period / <f32>4 : period / (TWO * PI) * Mathf.asin(ONE / amplitude);
    }

    // Below an amplitude of 1, the start of the curve ramps from 1 to the
    // amplitude over |s| (Rive's computeActualAmplitude).
    actualAmplitude(time: f32): f32 {
        if (this.amplitude < ONE) {
            const t = Mathf.abs(this.s);
            const absTime = Mathf.abs(time);
            if (absTime < t) {
                const l: f32 = absTime / t;
                return (this.amplitude * l) + (ONE - l);
            }
        }
        return this.amplitude;
    }

    easeOut(factor: f32): f32 {
        const time = factor;
        const a = this.actualAmplitude(time);
        return (a * Mathf.pow(TWO, TEN * -time) * Mathf.sin((time - this.s) * (TWO * PI) / this.period)) + ONE;
    }

    easeIn(factor: f32): f32 {
        const time: f32 = factor - ONE;
        const a = this.actualAmplitude(time);
        return -(a * Mathf.pow(TWO, TEN * time) * Mathf.sin((-time - this.s) * (TWO * PI) / this.period));
    }

    easeInOut(factor: f32): f32 {
        const time: f32 = factor * TWO - ONE;
        const a = this.actualAmplitude(time);
        if (time < 0) {
            return -HALF * a * Mathf.pow(TWO, TEN * time) * Mathf.sin((-time - this.s) * (TWO * PI) / this.period);
        }
        return HALF * (a * Mathf.pow(TWO, TEN * -time) * Mathf.sin((time - this.s) * (TWO * PI) / this.period)) + ONE;
    }
}

// One interpolator of a key, prepared from its declaration.
export class Interpolator {
    kind: InterpolatorKind;
    x1: f32;
    y1: f32;
    x2: f32;
    y2: f32;
    easingValue: i32;
    amplitude: f32;
    period: f32;
    // CubicEase and CubicValue: the x curve's solver (Rive's
    // CubicInterpolator builds it from x1 and x2 when added).
    private solver: CubicSolver = new CubicSolver();
    // Elastic: its ease (a period of 0 is taken as 0.5, Rive's initialize).
    private elastic: ElasticEase;
    // CubicValue: the polynomial through [from, y1, y2, to], computed again
    // only when from or to change (Rive's m_A to m_D and m_ValueTo).
    private pa: f32 = 0;
    private pb: f32 = 0;
    private pc: f32 = 0;
    private pd: f32 = 0;
    private valueTo: f32 = 0;

    constructor(d: InterpolatorDecl) {
        this.kind = d.kind;
        this.x1 = <f32>d.x1;
        this.y1 = <f32>d.y1;
        this.x2 = <f32>d.x2;
        this.y2 = <f32>d.y2;
        this.easingValue = d.easingValue;
        this.amplitude = <f32>d.amplitude;
        this.period = <f32>d.period;
        this.solver.build(this.x1, this.x2);
        this.elastic = new ElasticEase(this.amplitude, this.period == 0 ? HALF : this.period);
        this.computeParameters();
    }

    // CubicValueInterpolator::computeParameters.
    private computeParameters(): void {
        const y1 = this.pd;
        const y2 = this.y1;
        const y3 = this.y2;
        const y4 = this.valueTo;
        this.pa = y4 + THREE * (y2 - y3) - y1;
        this.pb = THREE * (y3 - y2 * TWO + y1);
        this.pc = THREE * (y2 - y1);
    }

    // The eased fraction of a segment at `t` (0 to 1): CubicEase's bezier
    // y at the x solved for t, Elastic's ease (Rive's
    // KeyFrameInterpolator::transform). CubicValue has none in Rive (its
    // transform asserts, and gives `t` back in a release build, so a colour
    // keyed with it moves linearly): `t` here too.
    transform(t: f32): f32 {
        if (this.kind == InterpolatorKind.CubicEase) return calcBezier(this.solver.getT(t), this.y1, this.y2);
        if (this.kind == InterpolatorKind.Elastic) {
            const e = this.easingValue;
            if (e == ELASTIC_EASE_IN) return this.elastic.easeIn(t);
            if (e == ELASTIC_EASE_OUT) return this.elastic.easeOut(t);
            if (e == ELASTIC_EASE_IN_OUT) return this.elastic.easeInOut(t);
        }
        return t;
    }

    // The fraction a quaternion key's slerp takes at `t`: transform(t),
    // but a CubicValue eases it as a cubic ease of its x1 y1 x2 y2 (a value
    // curve has no meaning on a slerp's parameter; quaternion keys are a 3D
    // addition).
    ease(t: f32): f32 {
        if (this.kind == InterpolatorKind.CubicValue) return calcBezier(this.solver.getT(t), this.y1, this.y2);
        return this.transform(t);
    }

    // The value at `t` between `from` and `to`: CubicValue's bezier through
    // [from, y1, y2, to] at the x solved for `t`; the others lerp by
    // transform(t) (Rive's KeyFrameInterpolator::transformValue).
    transformValue(from: f32, to: f32, t: f32): f32 {
        if (this.kind != InterpolatorKind.CubicValue) return from + (to - from) * this.transform(t);
        if (this.pd != from || this.valueTo != to) {
            this.pd = from;
            this.valueTo = to;
            this.computeParameters();
        }
        const s = this.solver.getT(t);
        return ((this.pa * s + this.pb) * s + this.pc) * s + this.pd;
    }
}
