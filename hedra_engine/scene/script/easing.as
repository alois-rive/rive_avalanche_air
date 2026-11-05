// Milestone 27: Godot's tween easing equations (scene/animation/
// easing_equations.h, Robert Penner's, as Godot 4 ships them: its
// exponential curves offset by a thousandth, so that Expo In stops 0.1 %
// short of the end, and its Spring). A tweener writes its end value
// exactly when its time is up, whatever the curve gives there.
// `t` runs 0..`d`, the result `b`..`b + c`. Computed in f64: Godot's are in
// real_t (f32) with f32 constants, which differs from these by less than
// 1e-6 over 0..1.
//
// ../model/anim/easing.as is Blender's set of the same family (an elastic
// with an amplitude rule, no Spring, f32 bit for bit with Blender), which is
// why the tweens do not reuse it.

// Godot's Tween.TransitionType, in its order (the numbers are Godot's).
export enum TransitionType {
    Linear,
    Sine,
    Quint,
    Quart,
    Quad,
    Expo,
    Elastic,
    Cubic,
    Circ,
    Bounce,
    Back,
    Spring,
}

// Godot's Tween.EaseType.
export enum EaseType {
    In,
    Out,
    InOut,
    OutIn,
}

const PI: f64 = Math.PI;

function sineIn(t: f64, b: f64, c: f64, d: f64): f64 {
    return -c * Math.cos(t / d * (PI / 2)) + c + b;
}

function sineOut(t: f64, b: f64, c: f64, d: f64): f64 {
    return c * Math.sin(t / d * (PI / 2)) + b;
}

function sineInOut(t: f64, b: f64, c: f64, d: f64): f64 {
    return -c / 2 * (Math.cos(PI * t / d) - 1) + b;
}

function quintIn(t: f64, b: f64, c: f64, d: f64): f64 {
    return c * Math.pow(t / d, 5) + b;
}

function quintOut(t: f64, b: f64, c: f64, d: f64): f64 {
    return c * (Math.pow(t / d - 1, 5) + 1) + b;
}

function quintInOut(t: f64, b: f64, c: f64, d: f64): f64 {
    const u = t / d * 2;
    if (u < 1) return c / 2 * Math.pow(u, 5) + b;
    return c / 2 * (Math.pow(u - 2, 5) + 2) + b;
}

function quartIn(t: f64, b: f64, c: f64, d: f64): f64 {
    return c * Math.pow(t / d, 4) + b;
}

function quartOut(t: f64, b: f64, c: f64, d: f64): f64 {
    return -c * (Math.pow(t / d - 1, 4) - 1) + b;
}

function quartInOut(t: f64, b: f64, c: f64, d: f64): f64 {
    const u = t / d * 2;
    if (u < 1) return c / 2 * Math.pow(u, 4) + b;
    return -c / 2 * (Math.pow(u - 2, 4) - 2) + b;
}

function quadIn(t: f64, b: f64, c: f64, d: f64): f64 {
    return c * Math.pow(t / d, 2) + b;
}

function quadOut(t: f64, b: f64, c: f64, d: f64): f64 {
    const u = t / d;
    return -c * u * (u - 2) + b;
}

function quadInOut(t: f64, b: f64, c: f64, d: f64): f64 {
    const u = t / d * 2;
    if (u < 1) return c / 2 * Math.pow(u, 2) + b;
    return -c / 2 * ((u - 1) * (u - 3) - 1) + b;
}

function expoIn(t: f64, b: f64, c: f64, d: f64): f64 {
    if (t == 0) return b;
    return c * Math.pow(2, 10 * (t / d - 1)) + b - c * 0.001;
}

function expoOut(t: f64, b: f64, c: f64, d: f64): f64 {
    if (t == d) return b + c;
    return c * 1.001 * (-Math.pow(2, -10 * t / d) + 1) + b;
}

function expoInOut(t: f64, b: f64, c: f64, d: f64): f64 {
    if (t == 0) return b;
    if (t == d) return b + c;
    const u = t / (d / 2);
    if (u < 1) return c / 2 * Math.pow(2, 10 * (u - 1)) + b - c * 0.0005;
    return c / 2 * 1.0005 * (-Math.pow(2, -10 * (u - 1)) + 2) + b;
}

function elasticIn(t: f64, b: f64, c: f64, d: f64): f64 {
    if (t == 0) return b;
    let u = t / d;
    if (u == 1) return b + c;
    u -= 1;
    const p = d * 0.3;
    const a = c * Math.pow(2, 10 * u);
    const s = p / 4;
    return -(a * Math.sin((u * d - s) * (2 * PI) / p)) + b;
}

function elasticOut(t: f64, b: f64, c: f64, d: f64): f64 {
    if (t == 0) return b;
    const u = t / d;
    if (u == 1) return b + c;
    const p = d * 0.3;
    const s = p / 4;
    return c * Math.pow(2, -10 * u) * Math.sin((u * d - s) * (2 * PI) / p) + c + b;
}

function elasticInOut(t: f64, b: f64, c: f64, d: f64): f64 {
    if (t == 0) return b;
    let u = t / (d / 2);
    if (u == 2) return b + c;
    const p = d * (0.3 * 1.5);
    let a = c;
    const s = p / 4;
    if (u < 1) {
        u -= 1;
        a *= Math.pow(2, 10 * u);
        return -0.5 * (a * Math.sin((u * d - s) * (2 * PI) / p)) + b;
    }
    u -= 1;
    a *= Math.pow(2, -10 * u);
    return a * Math.sin((u * d - s) * (2 * PI) / p) * 0.5 + c + b;
}

function cubicIn(t: f64, b: f64, c: f64, d: f64): f64 {
    const u = t / d;
    return c * u * u * u + b;
}

function cubicOut(t: f64, b: f64, c: f64, d: f64): f64 {
    const u = t / d - 1;
    return c * (u * u * u + 1) + b;
}

function cubicInOut(t: f64, b: f64, c: f64, d: f64): f64 {
    let u = t / (d / 2);
    if (u < 1) return c / 2 * u * u * u + b;
    u -= 2;
    return c / 2 * (u * u * u + 2) + b;
}

function circIn(t: f64, b: f64, c: f64, d: f64): f64 {
    const u = t / d;
    return -c * (Math.sqrt(1 - u * u) - 1) + b;
}

function circOut(t: f64, b: f64, c: f64, d: f64): f64 {
    const u = t / d - 1;
    return c * Math.sqrt(1 - u * u) + b;
}

function circInOut(t: f64, b: f64, c: f64, d: f64): f64 {
    let u = t / (d / 2);
    if (u < 1) return -c / 2 * (Math.sqrt(1 - u * u) - 1) + b;
    u -= 2;
    return c / 2 * (Math.sqrt(1 - u * u) + 1) + b;
}

function bounceOut(t: f64, b: f64, c: f64, d: f64): f64 {
    let u = t / d;
    if (u < 1 / 2.75) return c * (7.5625 * u * u) + b;
    if (u < 2 / 2.75) {
        u -= 1.5 / 2.75;
        return c * (7.5625 * u * u + 0.75) + b;
    }
    if (u < 2.5 / 2.75) {
        u -= 2.25 / 2.75;
        return c * (7.5625 * u * u + 0.9375) + b;
    }
    u -= 2.625 / 2.75;
    return c * (7.5625 * u * u + 0.984375) + b;
}

function bounceIn(t: f64, b: f64, c: f64, d: f64): f64 {
    return c - bounceOut(d - t, 0, c, d) + b;
}

function backIn(t: f64, b: f64, c: f64, d: f64): f64 {
    const s = 1.70158;
    const u = t / d;
    return c * u * u * ((s + 1) * u - s) + b;
}

function backOut(t: f64, b: f64, c: f64, d: f64): f64 {
    const s = 1.70158;
    const u = t / d - 1;
    return c * (u * u * ((s + 1) * u + s) + 1) + b;
}

function backInOut(t: f64, b: f64, c: f64, d: f64): f64 {
    const s = 1.70158 * 1.525;
    let u = t / (d / 2);
    if (u < 1) return c / 2 * (u * u * ((s + 1) * u - s)) + b;
    u -= 2;
    return c / 2 * (u * u * ((s + 1) * u + s) + 2) + b;
}

function springOut(t: f64, b: f64, c: f64, d: f64): f64 {
    const u = t / d;
    const s = 1.0 - u;
    const v = (Math.sin(u * PI * (0.2 + 2.5 * u * u * u)) * Math.pow(s, 2.2) + u) * (1.0 + 1.2 * s);
    return c * v + b;
}

function springIn(t: f64, b: f64, c: f64, d: f64): f64 {
    return c - springOut(d - t, 0, c, d) + b;
}

// The In or Out equation of `trans` (InOut and OutIn are made of these
// for the curves whose InOut Godot builds from halves: Bounce, Spring, and
// every OutIn).
function inOf(trans: TransitionType, t: f64, b: f64, c: f64, d: f64): f64 {
    switch (trans) {
        case TransitionType.Sine: return sineIn(t, b, c, d);
        case TransitionType.Quint: return quintIn(t, b, c, d);
        case TransitionType.Quart: return quartIn(t, b, c, d);
        case TransitionType.Quad: return quadIn(t, b, c, d);
        case TransitionType.Expo: return expoIn(t, b, c, d);
        case TransitionType.Elastic: return elasticIn(t, b, c, d);
        case TransitionType.Cubic: return cubicIn(t, b, c, d);
        case TransitionType.Circ: return circIn(t, b, c, d);
        case TransitionType.Bounce: return bounceIn(t, b, c, d);
        case TransitionType.Back: return backIn(t, b, c, d);
        case TransitionType.Spring: return springIn(t, b, c, d);
        default: return c * t / d + b;
    }
}

function outOf(trans: TransitionType, t: f64, b: f64, c: f64, d: f64): f64 {
    switch (trans) {
        case TransitionType.Sine: return sineOut(t, b, c, d);
        case TransitionType.Quint: return quintOut(t, b, c, d);
        case TransitionType.Quart: return quartOut(t, b, c, d);
        case TransitionType.Quad: return quadOut(t, b, c, d);
        case TransitionType.Expo: return expoOut(t, b, c, d);
        case TransitionType.Elastic: return elasticOut(t, b, c, d);
        case TransitionType.Cubic: return cubicOut(t, b, c, d);
        case TransitionType.Circ: return circOut(t, b, c, d);
        case TransitionType.Bounce: return bounceOut(t, b, c, d);
        case TransitionType.Back: return backOut(t, b, c, d);
        case TransitionType.Spring: return springOut(t, b, c, d);
        default: return c * t / d + b;
    }
}

function inOutOf(trans: TransitionType, t: f64, b: f64, c: f64, d: f64): f64 {
    switch (trans) {
        case TransitionType.Sine: return sineInOut(t, b, c, d);
        case TransitionType.Quint: return quintInOut(t, b, c, d);
        case TransitionType.Quart: return quartInOut(t, b, c, d);
        case TransitionType.Quad: return quadInOut(t, b, c, d);
        case TransitionType.Expo: return expoInOut(t, b, c, d);
        case TransitionType.Elastic: return elasticInOut(t, b, c, d);
        case TransitionType.Cubic: return cubicInOut(t, b, c, d);
        case TransitionType.Circ: return circInOut(t, b, c, d);
        case TransitionType.Back: return backInOut(t, b, c, d);
        case TransitionType.Bounce:
        case TransitionType.Spring: {
            if (t < d / 2) return inOf(trans, t * 2, b, c / 2, d);
            const h = c / 2;
            return outOf(trans, t * 2 - d, b + h, h, d);
        }
        default: return c * t / d + b;
    }
}

// Godot's Tween.interpolate_value: the value at `t` seconds of a tween of
// `d` seconds from `b` by `c`.
export function interpolate(trans: TransitionType, ease: EaseType, t: f64, b: f64, c: f64, d: f64): f64 {
    if (d <= 0) return b + c;
    switch (ease) {
        case EaseType.In: return inOf(trans, t, b, c, d);
        case EaseType.Out: return outOf(trans, t, b, c, d);
        case EaseType.InOut: return inOutOf(trans, t, b, c, d);
        default: {
            if (trans == TransitionType.Linear) return c * t / d + b;
            if (t < d / 2) return outOf(trans, t * 2, b, c / 2, d);
            const h = c / 2;
            return inOf(trans, t * 2 - d, b + h, h, d);
        }
    }
}
