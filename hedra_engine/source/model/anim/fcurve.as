// F-curves: one animated scalar per curve, keyframes as 2D Bezier
// triples with Blender's interpolation, easing, handle and extrapolation
// semantics. Handle recalculation reproduces Blender's `BKE_fcurve_handles_recalc` /
// `calchandleNurb_intern` (auto and auto-clamped handles, the 2.5614
// factor, the 1:5 length clamp, extrema flattening, end flattening under
// constant extrapolation, cyclic neighbours); evaluation reproduces
// `fcurve_eval_keyframes` (exact-key shortcut, `correct_bezpart`, the
// cubic x-solve for the frame, linear / handle-slope extrapolation and the
// Cycles modifier's repeat mapping).

import { Vec2, remEuclidF32 } from "../../../base/vecmath";
import { toAsciiLowercase, clampF32, maxF32, partialCmpF32, stableSort } from "../../../base/util";
import * as easing from "./easing";

// Frames closer than this are the same keyframe (Blender's
// `BEZT_BINARYSEARCH_THRESH`).
export const FRAME_EPSILON: f32 = 0.01;

// Blender's auto-handle length factor.
export const AUTO_LEN: f32 = 2.5614;

// Machine epsilon of f32 (2^-23).
const F32_EPSILON: f32 = 1.1920929e-7;

// ---------------------------------------------------------------------------
// Enums. Variant order is the file format (postcard variant index). The
// `...Parse` functions return -1 for an unknown name; cast the result with
// `<Interpolation>r` etc. once checked.

export enum Interpolation {
    Constant = 0,
    Linear = 1,
    Bezier = 2, // the default
    Sine = 3,
    Quad = 4,
    Cubic = 5,
    Quart = 6,
    Quint = 7,
    Expo = 8,
    Circ = 9,
    Back = 10,
    Bounce = 11,
    Elastic = 12,
}

export const INTERPOLATION_DEFAULT: Interpolation = Interpolation.Bezier;

export const INTERPOLATION_NAMES: Array<string> = [
    "constant", "linear", "bezier", "sine", "quad", "cubic", "quart", "quint", "expo", "circ",
    "back", "bounce", "elastic",
];

// The interpolation named by `s` (ASCII case-insensitive, with aliases), or -1.
export function interpolationParse(s: string): i32 {
    const l = toAsciiLowercase(s);
    if (l == "constant" || l == "const" || l == "step") return Interpolation.Constant;
    if (l == "linear" || l == "lin") return Interpolation.Linear;
    if (l == "bezier" || l == "bez") return Interpolation.Bezier;
    if (l == "sine" || l == "sinusoidal") return Interpolation.Sine;
    if (l == "quad" || l == "quadratic") return Interpolation.Quad;
    if (l == "cubic") return Interpolation.Cubic;
    if (l == "quart" || l == "quartic") return Interpolation.Quart;
    if (l == "quint" || l == "quintic") return Interpolation.Quint;
    if (l == "expo" || l == "exponential") return Interpolation.Expo;
    if (l == "circ" || l == "circular") return Interpolation.Circ;
    if (l == "back") return Interpolation.Back;
    if (l == "bounce") return Interpolation.Bounce;
    if (l == "elastic") return Interpolation.Elastic;
    return -1;
}

export function interpolationName(i: Interpolation): string {
    switch (i) {
        case Interpolation.Constant: return "constant";
        case Interpolation.Linear: return "linear";
        case Interpolation.Bezier: return "bezier";
        case Interpolation.Sine: return "sine";
        case Interpolation.Quad: return "quad";
        case Interpolation.Cubic: return "cubic";
        case Interpolation.Quart: return "quart";
        case Interpolation.Quint: return "quint";
        case Interpolation.Expo: return "expo";
        case Interpolation.Circ: return "circ";
        case Interpolation.Back: return "back";
        case Interpolation.Bounce: return "bounce";
        default: return "elastic";
    }
}

// The easing modes (everything but constant, linear and Bezier).
export function interpolationIsEasing(i: Interpolation): bool {
    return !(i == Interpolation.Constant || i == Interpolation.Linear || i == Interpolation.Bezier);
}

export enum Easing {
    // Ease in for the plain curves, ease out for back / bounce / elastic
    // (Blender's "Automatic Easing"). The default.
    Auto = 0,
    In = 1,
    Out = 2,
    InOut = 3,
}

export const EASING_DEFAULT: Easing = Easing.Auto;

export const EASING_NAMES: Array<string> = ["auto", "in", "out", "in-out"];

// The easing named by `s`, or -1.
export function easingParse(s: string): i32 {
    const l = toAsciiLowercase(s);
    if (l == "auto" || l == "automatic") return Easing.Auto;
    if (l == "in" || l == "ease-in" || l == "ease_in") return Easing.In;
    if (l == "out" || l == "ease-out" || l == "ease_out") return Easing.Out;
    if (l == "in-out" || l == "inout" || l == "in_out" || l == "ease-in-out" || l == "ease_in_out") return Easing.InOut;
    return -1;
}

export function easingName(e: Easing): string {
    switch (e) {
        case Easing.Auto: return "auto";
        case Easing.In: return "in";
        case Easing.Out: return "out";
        default: return "in-out";
    }
}

export enum HandleType {
    Free = 0,
    Aligned = 1,
    Vector = 2,
    Auto = 3,
    // Blender's default: auto handles that stay flat on extremes so keyed
    // values are never overshot. The default.
    AutoClamped = 4,
}

export const HANDLE_TYPE_DEFAULT: HandleType = HandleType.AutoClamped;

// Not declaration order: the order the names are listed in help and errors.
export const HANDLE_TYPE_NAMES: Array<string> = ["auto-clamped", "auto", "vector", "aligned", "free"];

// The handle type named by `s`, or -1.
export function handleTypeParse(s: string): i32 {
    const l = toAsciiLowercase(s);
    if (l == "free") return HandleType.Free;
    if (l == "aligned" || l == "align") return HandleType.Aligned;
    if (l == "vector" || l == "vect") return HandleType.Vector;
    if (l == "auto" || l == "automatic") return HandleType.Auto;
    if (l == "auto-clamped" || l == "auto_clamped" || l == "autoclamped" || l == "clamped") return HandleType.AutoClamped;
    return -1;
}

export function handleTypeName(h: HandleType): string {
    switch (h) {
        case HandleType.Free: return "free";
        case HandleType.Aligned: return "aligned";
        case HandleType.Vector: return "vector";
        case HandleType.Auto: return "auto";
        default: return "auto-clamped";
    }
}

export function handleTypeIsAuto(h: HandleType): bool {
    return h == HandleType.Auto || h == HandleType.AutoClamped;
}

export enum Extrapolation {
    Constant = 0, // the default
    Linear = 1,
    // Repeat the keyed range (Blender's Cycles F-modifier in repeat mode).
    Cyclic = 2,
}

export const EXTRAPOLATION_DEFAULT: Extrapolation = Extrapolation.Constant;

export const EXTRAPOLATION_NAMES: Array<string> = ["constant", "linear", "cyclic"];

// The extrapolation named by `s`, or -1.
export function extrapolationParse(s: string): i32 {
    const l = toAsciiLowercase(s);
    if (l == "constant" || l == "const") return Extrapolation.Constant;
    if (l == "linear" || l == "lin") return Extrapolation.Linear;
    if (l == "cyclic" || l == "cycle" || l == "cycles" || l == "repeat") return Extrapolation.Cyclic;
    return -1;
}

export function extrapolationName(e: Extrapolation): string {
    switch (e) {
        case Extrapolation.Constant: return "constant";
        case Extrapolation.Linear: return "linear";
        default: return "cyclic";
    }
}

// ---------------------------------------------------------------------------

// What frameRange returns (null for a curve without keys).
export class FrameRange {
    lo: f32 = 0;
    hi: f32 = 0;
    constructor(lo: f32, hi: f32) {
        this.lo = lo;
        this.hi = hi;
    }
    equals(o: FrameRange): bool { return this.lo == o.lo && this.hi == o.hi; }
}

// What FCurve.insert returns: the key's index and whether it replaced one.
export class InsertResult {
    index: i32 = 0;
    replaced: bool = false;
    constructor(index: i32, replaced: bool) {
        this.index = index;
        this.replaced = replaced;
    }
}

// One Bezier triple: the key point plus its two handles (absolute frame /
// value coordinates, like Blender's `BezTriple::vec`).
// Keyframe is a value: it is a class, so call clone() wherever a copy is
// meant (assignment shares the object). Field order is the file format.
export class Keyframe {
    frame: f32 = 0;
    value: f32 = 0;
    interpolation: Interpolation = Interpolation.Bezier;
    easing: Easing = Easing.Auto;
    handleLeft: Vec2 = Vec2(0, 0);
    handleRight: Vec2 = Vec2(0, 0);
    handleType: HandleType = HandleType.AutoClamped;
    // Overshoot of the Back easing (Blender's default 1.70158).
    back: f32 = 1.70158;
    // Amplitude / period of the Elastic easing (Blender's 0.8 / 4.1).
    amplitude: f32 = 0.8;
    period: f32 = 4.1;

    // A key with Blender's defaults for a freshly
    // inserted one: Bezier, auto-clamped handles one frame on either side
    // (recalculated by the curve afterwards).
    constructor(frame: f32, value: f32) {
        this.frame = frame;
        this.value = value;
        this.interpolation = Interpolation.Bezier;
        this.easing = Easing.Auto;
        this.handleLeft = Vec2(frame - <f32>1.0, value);
        this.handleRight = Vec2(frame + <f32>1.0, value);
        this.handleType = HandleType.AutoClamped;
        this.back = 1.70158;
        this.amplitude = 0.8;
        this.period = 4.1;
    }

    point(): Vec2 {
        return Vec2(this.frame, this.value);
    }

    // Move the key point; handles follow (Blender's grab).
    setPoint(frame: f32, value: f32): void {
        const d = Vec2(frame - this.frame, value - this.value);
        this.frame = frame;
        this.value = value;
        this.handleLeft += d;
        this.handleRight += d;
    }

    clone(): Keyframe {
        const k = new Keyframe(this.frame, this.value);
        k.interpolation = this.interpolation;
        k.easing = this.easing;
        k.handleLeft = this.handleLeft;
        k.handleRight = this.handleRight;
        k.handleType = this.handleType;
        k.back = this.back;
        k.amplitude = this.amplitude;
        k.period = this.period;
        return k;
    }

    // PartialEq (f32 `==`: NaN != NaN, 0.0 == -0.0).
    equals(o: Keyframe): bool {
        return this.frame == o.frame
            && this.value == o.value
            && this.interpolation == o.interpolation
            && this.easing == o.easing
            && this.handleLeft == o.handleLeft
            && this.handleRight == o.handleRight
            && this.handleType == o.handleType
            && this.back == o.back
            && this.amplitude == o.amplitude
            && this.period == o.period;
    }
}

// The first index whose frame is not < `frame`, by a fixed binary search
// (halving `size`, probing `base + size / 2`), so even an unsorted list
// gives a deterministic index.
function partitionFrame(keys: Array<Keyframe>, frame: f32): i32 {
    let size = keys.length;
    if (size == 0) return 0;
    let base = 0;
    while (size > 1) {
        const half = size / 2;
        const mid = base + half;
        // pred true -> Less -> base = mid; false -> Greater -> keep base.
        if (keys[mid].frame < frame) base = mid;
        size -= half;
    }
    return keys[base].frame < frame ? base + 1 : base;
}

// Inserts v at pos, shifting the rest up (Array.splice cannot insert in rasc 1.1.0).
export function insertAt<T>(a: Array<T>, pos: i32, v: T): void {
    a.push(v);
    for (let i = a.length - 1; i > pos; i--) a[i] = a[i - 1];
    a[pos] = v;
}

export class FCurve {
    // Blender style: `location`, `rotation_euler`,
    // `pose.bones["Spine"].rotation_quaternion`, `key_blocks["Smile"].value`.
    dataPath: string = "";
    arrayIndex: u32 = 0;
    // Sorted by frame, frames unique within FRAME_EPSILON.
    keyframes: Array<Keyframe> = [];
    extrapolation: Extrapolation = Extrapolation.Constant;
    // Muted curves are skipped by evaluation.
    mute: bool = false;

    constructor(dataPath: string, arrayIndex: u32) {
        this.dataPath = dataPath;
        this.arrayIndex = arrayIndex;
        this.keyframes = [];
        this.extrapolation = Extrapolation.Constant;
        this.mute = false;
    }

    // Deep copy.

    clone(): FCurve {
        const c = new FCurve(this.dataPath, this.arrayIndex);
        for (let i = 0; i < this.keyframes.length; i++) c.keyframes.push(this.keyframes[i].clone());
        c.extrapolation = this.extrapolation;
        c.mute = this.mute;
        return c;
    }

    // PartialEq.
    equals(o: FCurve): bool {
        if (this.dataPath != o.dataPath || this.arrayIndex != o.arrayIndex) return false;
        if (this.keyframes.length != o.keyframes.length) return false;
        for (let i = 0; i < this.keyframes.length; i++) {
            if (!this.keyframes[i].equals(o.keyframes[i])) return false;
        }
        return this.extrapolation == o.extrapolation && this.mute == o.mute;
    }

    // First and last keyed frame (null when there is none).
    frameRange(): FrameRange? {
        const n = this.keyframes.length;
        if (n == 0) return null;
        return new FrameRange(this.keyframes[0].frame, this.keyframes[n - 1].frame);
    }

    // Index of the key at `frame` (within FRAME_EPSILON), or -1.
    keyAt(frame: f32): i32 {
        for (let i = 0; i < this.keyframes.length; i++) {
            if (Mathf.abs(this.keyframes[i].frame - frame) < FRAME_EPSILON) return i;
        }
        return -1;
    }

    // Insert or replace the key at `frame` (Blender's `insert_vert_fcurve`
    // with `INSERTKEY_NEEDED` off): an existing key keeps its interpolation
    // and handle types and has its handles moved with the value; a new key
    // gets Blender's defaults. Handles are recalculated. Returns the index
    // and whether a key was replaced.
    insert(frame: f32, value: f32): InsertResult {
        let index: i32;
        let replaced: bool;
        const at = this.keyAt(frame);
        if (at >= 0) {
            const k = this.keyframes[at];
            const dy = value - k.value;
            k.value = value;
            k.handleLeft.y += dy;
            k.handleRight.y += dy;
            index = at;
            replaced = true;
        } else {
            // Blender inherits interpolation / easing from the key
            // before the new one (keeps a stepped curve stepped).
            const key = new Keyframe(frame, value);
            const pos = partitionFrame(this.keyframes, frame);
            if (pos >= 1) {
                const prev = this.keyframes[pos - 1];
                key.interpolation = prev.interpolation;
                key.easing = prev.easing;
                key.handleType = prev.handleType;
            }
            insertAt<Keyframe>(this.keyframes, pos, key);
            index = pos;
            replaced = false;
        }
        this.recalcHandles();
        return new InsertResult(index, replaced);
    }

    // Remove the key at `frame`; true when one was there.
    removeAt(frame: f32): bool {
        const i = this.keyAt(frame);
        if (i >= 0) {
            this.keyframes.splice(i, 1);
            this.recalcHandles();
            return true;
        }
        return false;
    }

    // Re-sort after frames changed and merge keys that collided (the
    // first in list order wins; `keyframe move` removes the key at the
    // destination first so the moved key survives).
    sortAndDedup(): void {
        stableSort<Keyframe>(this.keyframes, (a: Keyframe, b: Keyframe): i32 => partialCmpF32(a.frame, b.frame));
        let i = 1;
        while (i < this.keyframes.length) {
            if (Mathf.abs(this.keyframes[i].frame - this.keyframes[i - 1].frame) < FRAME_EPSILON) {
                this.keyframes.splice(i, 1);
            } else {
                i += 1;
            }
        }
        this.recalcHandles();
    }

    // Shift every key (and its handles) by `delta` frames.
    offset(delta: f32): void {
        for (let i = 0; i < this.keyframes.length; i++) {
            const k = this.keyframes[i];
            k.frame += delta;
            k.handleLeft.x += delta;
            k.handleRight.x += delta;
        }
        this.recalcHandles();
    }

    // True when the first key's handles / the whole curve use cyclic
    // neighbours (Blender: Cycles modifier first, both end keys auto).
    handlesCycle(): bool {
        return this.extrapolation == Extrapolation.Cyclic
            && this.keyframes.length >= 2
            && handleTypeIsAuto(this.keyframes[0].handleType)
            && handleTypeIsAuto(this.keyframes[this.keyframes.length - 1].handleType);
    }

    // Blender's `BKE_fcurve_handles_recalc`.
    recalcHandles(): void {
        const n = this.keyframes.length;
        if (n < 2) {
            return;
        }
        const cycle = this.handlesCycle();
        const first = this.keyframes[0].point();
        const last = this.keyframes[n - 1].point();
        const locked = new Array<bool>(n);
        for (let i = 0; i < n; i++) locked[i] = false;
        for (let i = 0; i < n; i++) {
            const k = this.keyframes[i];
            if (k.handleLeft.x > k.frame) {
                k.handleLeft.x = k.frame;
            }
            if (k.handleRight.x < k.frame) {
                k.handleRight.x = k.frame;
            }
            let hasPrev = false;
            let prev = Vec2(0, 0);
            if (i > 0) {
                hasPrev = true;
                prev = this.keyframes[i - 1].point();
            } else if (cycle) {
                hasPrev = true;
                prev = this.keyframes[n - 2].point() + (first - last);
            }
            let hasNext = false;
            let next = Vec2(0, 0);
            if (i + 1 < n) {
                hasNext = true;
                next = this.keyframes[i + 1].point();
            } else if (cycle) {
                hasNext = true;
                next = this.keyframes[1].point() + (last - first);
            }
            locked[i] = calcHandle(k, hasPrev, prev, hasNext, next);
            if (handleTypeIsAuto(k.handleType)
                && !cycle
                && (i == 0 || i == n - 1)
                && this.extrapolation == Extrapolation.Constant) {
                k.handleLeft.y = k.value;
                k.handleRight.y = k.value;
                locked[i] = true;
            }
            if (hasPrev && prev.x >= k.frame) {
                locked[i] = true;
                if (i > 0) {
                    locked[i - 1] = true;
                }
            }
        }
        if (cycle && (locked[0] || locked[n - 1])) {
            const ends: StaticArray<i32> = [0, n - 1];
            for (let j = 0; j < 2; j++) {
                const k = this.keyframes[ends[j]];
                k.handleLeft.y = k.value;
                k.handleRight.y = k.value;
            }
        }
    }

    // Value at `frame` (0 for an empty curve).
    evaluate(frame: f32): f32 {
        const keys = this.keyframes;
        const n = keys.length;
        if (n == 0) {
            return 0.0;
        }
        if (n == 1) {
            return keys[0].value;
        }
        const first = keys[0];
        const last = keys[n - 1];
        let t = frame;
        if (this.extrapolation == Extrapolation.Cyclic && (t < first.frame || t > last.frame)) {
            const period = last.frame - first.frame;
            if (period > <f32>0.0) {
                t = first.frame + remEuclidF32(t - first.frame, period);
            } else {
                return last.value;
            }
        }
        if (t <= first.frame) {
            return this.extrapolate(t, 0, 1);
        }
        if (t >= last.frame) {
            return this.extrapolate(t, n - 1, n - 2);
        }
        // The first key at or after t; t is strictly inside the range.
        const i = partitionFrame(keys, t);
        const next = keys[i];
        if (Mathf.abs(next.frame - t) < <f32>1e-4) {
            return next.value;
        }
        const prev = keys[i - 1];
        if (Mathf.abs(prev.frame - t) < <f32>1e-8) {
            return prev.value;
        }
        return segment(prev, next, t);
    }

    // Blender's `fcurve_eval_keyframes_extrapolate`: constant, linear
    // through the neighbour, or along the end key's outer handle.
    extrapolate(t: f32, end: i32, neighbour: i32): f32 {
        const k = this.keyframes[end];
        if (k.interpolation == Interpolation.Constant || this.extrapolation == Extrapolation.Constant) {
            return k.value;
        }
        const dx = k.frame - t;
        if (k.interpolation == Interpolation.Linear) {
            const nb = this.keyframes[neighbour];
            const fac = nb.frame - k.frame;
            if (fac == <f32>0.0) {
                return k.value;
            }
            const slope = (nb.value - k.value) / fac;
            return k.value - slope * dx;
        }
        const handle = end == 0 ? k.handleLeft : k.handleRight;
        const fac = k.frame - handle.x;
        if (fac == <f32>0.0) {
            return k.value;
        }
        const slope = (k.value - handle.y) / fac;
        return k.value - slope * dx;
    }
}

// Blender's `calchandleNurb_intern` for F-curves (`is_fcurve`, no
// smoothing, no selection order). `prev` / `next` are the neighbouring
// key points (valid when hasPrev / hasNext); a missing one is mirrored
// through the key. Returns true when the auto-clamp flattened a handle
// (Blender's `HD_AUTOTYPE_LOCKED_FINAL`).
export function calcHandle(k: Keyframe, hasPrev: bool, prev: Vec2, hasNext: bool, next: Vec2): bool {
    if (k.handleType == HandleType.Free) {
        return false;
    }
    const p2 = k.point();
    let p1: Vec2;
    let p3: Vec2;
    if (hasPrev && hasNext) {
        p1 = prev;
        p3 = next;
    } else if (hasNext) {
        p1 = p2 * <f32>2.0 - next;
        p3 = next;
    } else if (hasPrev) {
        p1 = prev;
        p3 = p2 * <f32>2.0 - prev;
    } else {
        return false;
    }
    const dvecA = p2 - p1;
    const dvecB = p3 - p2;
    let lenA = dvecA.x;
    let lenB = dvecB.x;
    if (lenA == <f32>0.0) {
        lenA = 1.0;
    }
    if (lenB == <f32>0.0) {
        lenB = 1.0;
    }
    let locked = false;
    if (handleTypeIsAuto(k.handleType)) {
        const tvec = dvecB / lenB + dvecA / lenA;
        const len = tvec.x * AUTO_LEN;
        if (len != <f32>0.0) {
            if (lenA > <f32>5.0 * lenB) {
                lenA = <f32>5.0 * lenB;
            }
            if (lenB > <f32>5.0 * lenA) {
                lenB = <f32>5.0 * lenA;
            }
            const clamped = k.handleType == HandleType.AutoClamped && hasPrev && hasNext;
            let leftViolate = false;
            let rightViolate = false;
            k.handleLeft = p2 - tvec * (lenA / len);
            if (clamped) {
                const ydiff1 = p1.y - p2.y;
                const ydiff2 = p3.y - p2.y;
                if ((ydiff1 <= <f32>0.0 && ydiff2 <= <f32>0.0) || (ydiff1 >= <f32>0.0 && ydiff2 >= <f32>0.0)) {
                    k.handleLeft.y = p2.y;
                    locked = true;
                } else if (ydiff1 <= <f32>0.0) {
                    if (p1.y > k.handleLeft.y) {
                        k.handleLeft.y = p1.y;
                        leftViolate = true;
                    }
                } else if (p1.y < k.handleLeft.y) {
                    k.handleLeft.y = p1.y;
                    leftViolate = true;
                }
            }
            k.handleRight = p2 + tvec * (lenB / len);
            if (clamped) {
                const ydiff1 = p1.y - p2.y;
                const ydiff2 = p3.y - p2.y;
                if ((ydiff1 <= <f32>0.0 && ydiff2 <= <f32>0.0) || (ydiff1 >= <f32>0.0 && ydiff2 >= <f32>0.0)) {
                    k.handleRight.y = p2.y;
                    locked = true;
                } else if (ydiff1 <= <f32>0.0) {
                    if (p3.y < k.handleRight.y) {
                        k.handleRight.y = p3.y;
                        rightViolate = true;
                    }
                } else if (p3.y > k.handleRight.y) {
                    k.handleRight.y = p3.y;
                    rightViolate = true;
                }
            }
            if (leftViolate || rightViolate) {
                // Re-align the other handle with the clamped one.
                const h1x = k.handleLeft.x - p2.x;
                const h2x = p2.x - k.handleRight.x;
                if (leftViolate) {
                    k.handleRight.y = p2.y + ((p2.y - k.handleLeft.y) / h1x) * h2x;
                } else {
                    k.handleLeft.y = p2.y + ((p2.y - k.handleRight.y) / h2x) * h1x;
                }
            }
        }
    }
    if (k.handleType == HandleType.Vector) {
        k.handleLeft = p2 - dvecA / <f32>3.0;
        k.handleRight = p2 + dvecB / <f32>3.0;
    }
    if (k.handleType == HandleType.Aligned) {
        const EPS: f32 = 1e-5;
        let lenB2 = (p2 - k.handleRight).length();
        let lenA2 = (p2 - k.handleLeft).length();
        if (lenA2 == <f32>0.0) {
            lenA2 = 1.0;
        }
        if (lenB2 == <f32>0.0) {
            lenB2 = 1.0;
        }
        if (lenB2 > EPS) {
            k.handleLeft = p2 + (p2 - k.handleRight) * (lenA2 / lenB2);
        }
        if (lenA2 > EPS) {
            k.handleRight = p2 + (p2 - k.handleLeft) * (lenB2 / lenA2);
        }
    }
    return locked;
}

// Value between two keys at frame `t` (strictly inside), per the first
// key's interpolation (`fcurve_eval_keyframes_interpolate`).
export function segment(prev: Keyframe, next: Keyframe, t: f32): f32 {
    const begin = prev.value;
    const change = next.value - prev.value;
    const duration = next.frame - prev.frame;
    const time = t - prev.frame;
    if (prev.interpolation == Interpolation.Constant || duration == <f32>0.0) {
        return prev.value;
    }
    const ipo = prev.interpolation;
    if (ipo == Interpolation.Bezier) {
        const v1 = prev.point();
        let v2 = prev.handleRight;
        let v3 = next.handleLeft;
        const v4 = next.point();
        if (Mathf.abs(v1.y - v4.y) < F32_EPSILON
            && Mathf.abs(v2.y - v3.y) < F32_EPSILON
            && Mathf.abs(v3.y - v4.y) < F32_EPSILON) {
            return v1.y;
        }
        // Blender's correct_bezpart(v1, v2, v3, v4), inlined: it adjusts v2 and
        // v3 (Vec2 is a value, so they are written back here).
        const h1 = v1 - v2;
        const h2 = v4 - v3;
        const len = v4.x - v1.x;
        const len1 = Mathf.abs(h1.x);
        const len2 = Mathf.abs(h2.x);
        if (len1 + len2 != <f32>0.0 && len1 + len2 > len) {
            const fac = len / (len1 + len2);
            v2 = v1 - h1 * fac;
            v3 = v4 - h2 * fac;
        }
        const s = solveBezierX(v1.x, v2.x, v3.x, v4.x, t);
        return bezierAt(v1.y, v2.y, v3.y, v4.y, s);
    }
    if (ipo == Interpolation.Linear) return easing.linear(time, begin, change, duration);
    // Auto: ease in for the plain curves, ease out for the dynamic ones.
    let e = prev.easing;
    if (e == Easing.Auto) {
        e = (ipo == Interpolation.Back || ipo == Interpolation.Bounce || ipo == Interpolation.Elastic)
            ? Easing.Out
            : Easing.In;
    }
    const a = time;
    const b = begin;
    const c = change;
    const d = duration;
    switch (ipo) {
        case Interpolation.Sine:
            return e == Easing.In ? easing.sineIn(a, b, c, d) : e == Easing.Out ? easing.sineOut(a, b, c, d) : easing.sineInOut(a, b, c, d);
        case Interpolation.Quad:
            return e == Easing.In ? easing.quadIn(a, b, c, d) : e == Easing.Out ? easing.quadOut(a, b, c, d) : easing.quadInOut(a, b, c, d);
        case Interpolation.Cubic:
            return e == Easing.In ? easing.cubicIn(a, b, c, d) : e == Easing.Out ? easing.cubicOut(a, b, c, d) : easing.cubicInOut(a, b, c, d);
        case Interpolation.Quart:
            return e == Easing.In ? easing.quartIn(a, b, c, d) : e == Easing.Out ? easing.quartOut(a, b, c, d) : easing.quartInOut(a, b, c, d);
        case Interpolation.Quint:
            return e == Easing.In ? easing.quintIn(a, b, c, d) : e == Easing.Out ? easing.quintOut(a, b, c, d) : easing.quintInOut(a, b, c, d);
        case Interpolation.Expo:
            return e == Easing.In ? easing.expoIn(a, b, c, d) : e == Easing.Out ? easing.expoOut(a, b, c, d) : easing.expoInOut(a, b, c, d);
        case Interpolation.Circ:
            return e == Easing.In ? easing.circIn(a, b, c, d) : e == Easing.Out ? easing.circOut(a, b, c, d) : easing.circInOut(a, b, c, d);
        case Interpolation.Back:
            return e == Easing.In ? easing.backIn(a, b, c, d, prev.back)
                : e == Easing.Out ? easing.backOut(a, b, c, d, prev.back)
                : easing.backInOut(a, b, c, d, prev.back);
        case Interpolation.Bounce:
            return e == Easing.In ? easing.bounceIn(a, b, c, d) : e == Easing.Out ? easing.bounceOut(a, b, c, d) : easing.bounceInOut(a, b, c, d);
        case Interpolation.Elastic:
            return e == Easing.In ? easing.elasticIn(a, b, c, d, prev.amplitude, prev.period)
                : e == Easing.Out ? easing.elasticOut(a, b, c, d, prev.amplitude, prev.period)
                : easing.elasticInOut(a, b, c, d, prev.amplitude, prev.period);
        default:
            return easing.linear(a, b, c, d);
    }
}

// Cubic Bezier at parameter `s`.
export function bezierAt(p0: f32, p1: f32, p2: f32, p3: f32, s: f32): f32 {
    const u = <f32>1.0 - s;
    return u * u * u * p0 + <f32>3.0 * u * u * s * p1 + <f32>3.0 * u * s * s * p2 + s * s * s * p3;
}

// Parameter `s` in 0..1 with `x(s) == x` for a Bezier whose x control
// points are monotone (guaranteed after `correct_bezpart`), by bisection
// refined with Newton steps (Blender's `findzero` solves the same cubic
// analytically; the root is the same to float precision).
export function solveBezierX(x0: f32, x1: f32, x2: f32, x3: f32, x: f32): f32 {
    const span = x3 - x0;
    if (span <= <f32>0.0) {
        return 0.0;
    }
    let s = clampF32((x - x0) / span, 0.0, 1.0);
    let lo: f32 = 0.0;
    let hi: f32 = 1.0;
    for (let iter = 0; iter < 64; iter++) {
        const fs = bezierAt(x0, x1, x2, x3, s) - x;
        if (Mathf.abs(fs) < <f32>1e-6 * maxF32(span, 1.0)) {
            return s;
        }
        if (fs > <f32>0.0) {
            hi = s;
        } else {
            lo = s;
        }
        const u = <f32>1.0 - s;
        const d = <f32>3.0 * u * u * (x1 - x0) + <f32>6.0 * u * s * (x2 - x1) + <f32>3.0 * s * s * (x3 - x2);
        let next: f32 = Mathf.abs(d) > <f32>1e-12 ? s - fs / d : (lo + hi) * <f32>0.5;
        if (!(next >= lo && next <= hi) || !isFinite<f32>(next)) {
            next = (lo + hi) * <f32>0.5;
        }
        if (Mathf.abs(next - s) < <f32>1e-7) {
            return next;
        }
        s = next;
    }
    return s;
}
