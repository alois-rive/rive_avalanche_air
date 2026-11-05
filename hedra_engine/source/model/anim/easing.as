// Robert Penner's easing equations as Blender ships them in `BLI_easing`
// (`time` runs 0..`duration`, the result runs `begin`..`begin + change`).
// Used by the easing interpolation modes of F-curves (Sine, Quad, ...).
//
// All arithmetic is f32 in a fixed association order; literals are f32
// (`<f32>`), and the libm calls go through vecmath's sinf/cosf/asinf/exp2f
// (Apple's libsystem_m results, bit for bit). 2^x is written `exp2f(x)`, not
// powf(2, x): Apple's exp2f and powf round differently, and the recorded
// curves use exp2f.

import { sinf, cosf, asinf, exp2f } from "../../../base/vecmath";
import { maxF32 } from "../../../base/util";

// PI and PI / 2 as f32
const PI: f32 = 3.14159265358979323846;
const FRAC_PI_2: f32 = 1.57079632679489661923;

// asin(change / amplitude) in the elastic amplitude rule. The

// elastic easings reach exactly ±1 whenever amplitude == |change|, where
// Apple's asinf gives ±0x3fc90fda (PI/2 rounded down); vecmath's asinf is
// that routine.
function asinElastic(x: f32): f32 {
    return asinf(x);
}

export function linear(time: f32, begin: f32, change: f32, duration: f32): f32 {
    return change * time / duration + begin;
}

export function backIn(time: f32, begin: f32, change: f32, duration: f32, overshoot: f32): f32 {
    const t = time / duration;
    return change * t * t * ((overshoot + <f32>1.0) * t - overshoot) + begin;
}

export function backOut(time: f32, begin: f32, change: f32, duration: f32, overshoot: f32): f32 {
    const t = time / duration - <f32>1.0;
    return change * (t * t * ((overshoot + <f32>1.0) * t + overshoot) + <f32>1.0) + begin;
}

export function backInOut(time: f32, begin: f32, change: f32, duration: f32, overshoot0: f32): f32 {
    const overshoot = overshoot0 * <f32>1.525;
    let t = time / (duration / <f32>2.0);
    if (t < <f32>1.0) {
        return change / <f32>2.0 * (t * t * ((overshoot + <f32>1.0) * t - overshoot)) + begin;
    }
    t -= <f32>2.0;
    return change / <f32>2.0 * (t * t * ((overshoot + <f32>1.0) * t + overshoot) + <f32>2.0) + begin;
}

export function bounceOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    let t = time / duration;
    if (t < <f32>1.0 / <f32>2.75) {
        return change * (<f32>7.5625 * t * t) + begin;
    } else if (t < <f32>2.0 / <f32>2.75) {
        t -= <f32>1.5 / <f32>2.75;
        return change * (<f32>7.5625 * t * t + <f32>0.75) + begin;
    } else if (t < <f32>2.5 / <f32>2.75) {
        t -= <f32>2.25 / <f32>2.75;
        return change * (<f32>7.5625 * t * t + <f32>0.9375) + begin;
    } else {
        t -= <f32>2.625 / <f32>2.75;
        return change * (<f32>7.5625 * t * t + <f32>0.984375) + begin;
    }
}

export function bounceIn(time: f32, begin: f32, change: f32, duration: f32): f32 {
    return change - bounceOut(duration - time, <f32>0.0, change, duration) + begin;
}

export function bounceInOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    if (time < duration / <f32>2.0) {
        return bounceIn(time * <f32>2.0, <f32>0.0, change, duration) * <f32>0.5 + begin;
    } else {
        return bounceOut(time * <f32>2.0 - duration, <f32>0.0, change, duration) * <f32>0.5 + change * <f32>0.5 + begin;
    }
}

export function circIn(time: f32, begin: f32, change: f32, duration: f32): f32 {
    const t = time / duration;
    return -change * (Mathf.sqrt(maxF32(<f32>1.0 - t * t, <f32>0.0)) - <f32>1.0) + begin;
}

export function circOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    const t = time / duration - <f32>1.0;
    return change * Mathf.sqrt(maxF32(<f32>1.0 - t * t, <f32>0.0)) + begin;
}

export function circInOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    let t = time / (duration / <f32>2.0);
    if (t < <f32>1.0) {
        return -change / <f32>2.0 * (Mathf.sqrt(maxF32(<f32>1.0 - t * t, <f32>0.0)) - <f32>1.0) + begin;
    }
    t -= <f32>2.0;
    return change / <f32>2.0 * (Mathf.sqrt(maxF32(<f32>1.0 - t * t, <f32>0.0)) + <f32>1.0) + begin;
}

export function cubicIn(time: f32, begin: f32, change: f32, duration: f32): f32 {
    const t = time / duration;
    return change * t * t * t + begin;
}

export function cubicOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    const t = time / duration - <f32>1.0;
    return change * (t * t * t + <f32>1.0) + begin;
}

export function cubicInOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    let t = time / (duration / <f32>2.0);
    if (t < <f32>1.0) {
        return change / <f32>2.0 * t * t * t + begin;
    }
    t -= <f32>2.0;
    return change / <f32>2.0 * (t * t * t + <f32>2.0) + begin;
}

// Penner's elastic ease-in with Blender's amplitude / period parameters
// (`period` 0 means 0.3 of the duration; an amplitude below the change
// falls back to the change itself).
export function elasticIn(time: f32, begin: f32, change: f32, duration: f32, amplitude0: f32, period0: f32): f32 {
    if (time == <f32>0.0) {
        return begin;
    }
    let t = time / duration;
    if (t == <f32>1.0) {
        return begin + change;
    }
    t -= <f32>1.0;
    const period: f32 = period0 == <f32>0.0 ? duration * <f32>0.3 : period0;
    let amplitude: f32;
    let s: f32;
    if (amplitude0 == <f32>0.0 || amplitude0 < Mathf.abs(change)) {
        amplitude = change;
        s = period / <f32>4.0;
    } else {
        amplitude = amplitude0;
        s = period / (<f32>2.0 * PI) * asinElastic(change / amplitude0);
    }
    return -(amplitude * exp2f(<f32>10.0 * t) * sinf((t * duration - s) * (<f32>2.0 * PI) / period)) + begin;
}

export function elasticOut(time: f32, begin: f32, change: f32, duration: f32, amplitude0: f32, period0: f32): f32 {
    if (time == <f32>0.0) {
        return begin;
    }
    const t = time / duration;
    if (t == <f32>1.0) {
        return begin + change;
    }
    const period: f32 = period0 == <f32>0.0 ? duration * <f32>0.3 : period0;
    let amplitude: f32;
    let s: f32;
    if (amplitude0 == <f32>0.0 || amplitude0 < Mathf.abs(change)) {
        amplitude = change;
        s = period / <f32>4.0;
    } else {
        amplitude = amplitude0;
        s = period / (<f32>2.0 * PI) * asinElastic(change / amplitude0);
    }
    return amplitude * exp2f(<f32>-10.0 * t) * sinf((t * duration - s) * (<f32>2.0 * PI) / period)
        + change
        + begin;
}

export function elasticInOut(time: f32, begin: f32, change: f32, duration: f32, amplitude0: f32, period0: f32): f32 {
    if (time == <f32>0.0) {
        return begin;
    }
    let t = time / (duration / <f32>2.0);
    if (t == <f32>2.0) {
        return begin + change;
    }
    t -= <f32>1.0;
    const period: f32 = period0 == <f32>0.0 ? duration * (<f32>0.3 * <f32>1.5) : period0;
    let amplitude: f32;
    let s: f32;
    if (amplitude0 == <f32>0.0 || amplitude0 < Mathf.abs(change)) {
        amplitude = change;
        s = period / <f32>4.0;
    } else {
        amplitude = amplitude0;
        s = period / (<f32>2.0 * PI) * asinElastic(change / amplitude0);
    }
    if (t < <f32>0.0) {
        return <f32>-0.5 * (amplitude * exp2f(<f32>10.0 * t) * sinf((t * duration - s) * (<f32>2.0 * PI) / period))
            + begin;
    } else {
        return amplitude * exp2f(<f32>-10.0 * t) * sinf((t * duration - s) * (<f32>2.0 * PI) / period) * <f32>0.5
            + change
            + begin;
    }
}

export function expoIn(time: f32, begin: f32, change: f32, duration: f32): f32 {
    if (time == <f32>0.0) {
        return begin;
    } else {
        return change * exp2f(<f32>10.0 * (time / duration - <f32>1.0)) + begin;
    }
}

export function expoOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    if (time == duration) {
        return begin + change;
    } else {
        return change * (-(exp2f(<f32>-10.0 * time / duration)) + <f32>1.0) + begin;
    }
}

export function expoInOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    if (time == <f32>0.0) {
        return begin;
    }
    if (time == duration) {
        return begin + change;
    }
    let t = time / (duration / <f32>2.0);
    if (t < <f32>1.0) {
        return change / <f32>2.0 * exp2f(<f32>10.0 * (t - <f32>1.0)) + begin;
    }
    t -= <f32>1.0;
    return change / <f32>2.0 * (-(exp2f(<f32>-10.0 * t)) + <f32>2.0) + begin;
}

export function quadIn(time: f32, begin: f32, change: f32, duration: f32): f32 {
    const t = time / duration;
    return change * t * t + begin;
}

export function quadOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    const t = time / duration;
    return -change * t * (t - <f32>2.0) + begin;
}

export function quadInOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    let t = time / (duration / <f32>2.0);
    if (t < <f32>1.0) {
        return change / <f32>2.0 * t * t + begin;
    }
    t -= <f32>1.0;
    return -change / <f32>2.0 * (t * (t - <f32>2.0) - <f32>1.0) + begin;
}

export function quartIn(time: f32, begin: f32, change: f32, duration: f32): f32 {
    const t = time / duration;
    return change * t * t * t * t + begin;
}

export function quartOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    const t = time / duration - <f32>1.0;
    return -change * (t * t * t * t - <f32>1.0) + begin;
}

export function quartInOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    let t = time / (duration / <f32>2.0);
    if (t < <f32>1.0) {
        return change / <f32>2.0 * t * t * t * t + begin;
    }
    t -= <f32>2.0;
    return -change / <f32>2.0 * (t * t * t * t - <f32>2.0) + begin;
}

export function quintIn(time: f32, begin: f32, change: f32, duration: f32): f32 {
    const t = time / duration;
    return change * t * t * t * t * t + begin;
}

export function quintOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    const t = time / duration - <f32>1.0;
    return change * (t * t * t * t * t + <f32>1.0) + begin;
}

export function quintInOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    let t = time / (duration / <f32>2.0);
    if (t < <f32>1.0) {
        return change / <f32>2.0 * t * t * t * t * t + begin;
    }
    t -= <f32>2.0;
    return change / <f32>2.0 * (t * t * t * t * t + <f32>2.0) + begin;
}

export function sineIn(time: f32, begin: f32, change: f32, duration: f32): f32 {
    return -change * cosf(time / duration * FRAC_PI_2) + change + begin;
}

export function sineOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    return change * sinf(time / duration * FRAC_PI_2) + begin;
}

export function sineInOut(time: f32, begin: f32, change: f32, duration: f32): f32 {
    return -change / <f32>2.0 * (cosf(PI * time / duration) - <f32>1.0) + begin;
}
