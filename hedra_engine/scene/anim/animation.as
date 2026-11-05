// A LinearAnimation prepared for evaluation (milestone 45,
// docs/plans/RIVE_MODEL.md section 5): the declarations (./decl.as) turned
// into what Rive's runtime holds once a file is imported (rive-runtime
// src/animation/linear_animation.cpp, keyed_object.cpp, keyed_property.cpp,
// keyframe*.cpp): per keyed property, its keys' times in seconds (frame /
// fps in f32, Rive's KeyFrame::computeSeconds), their values as f32 (four
// for a quaternion, ARGB for a colour), their interpolation types and
// interpolators, so that a frame binary-searches arrays and allocates
// nothing.
//
// Prepared once per scene file (cached per document by the instancer and
// the trees sharing its resources: ./scene_anims.as attachSceneAnimations)
// and shared by every instance of it; what a node is and how its property
// is written is resolved per instance (./scene_anims.as SceneAnimations).
//
// The time arithmetic is Rive's, in f32: startSeconds, endSeconds,
// startTime, endTime, durationSeconds and globalToLocalSeconds as
// linear_animation.cpp has them, and closestFrameIndex and
// reportKeyedCallbacks (keyed_property.cpp) with their rules for a key
// exactly at the start or the end of a step.

import { InterpolationType, KeyFrameDecl, KeyFrameKind, LinearAnimationDecl, LoopMode } from "./decl";
import { Interpolator } from "./interp";

// One keyed property's keys, prepared.
export class KeyedTrack {
    // As written ("rotation_degrees:y", "event:Creak", "quaternion").
    property: string;
    kind: KeyFrameKind;
    // Per key, in increasing time.
    frames: Array<i32> = [];
    seconds: Array<f32> = [];
    // Double, Int, Uint, Bool (0 or 1): one value a key; Quaternion: four
    // (x, y, z, w, normalised); Color: none (colors).
    values: Array<f32> = [];
    colors: Array<u32> = [];
    // String and Id keys' texts.
    texts: Array<string> = [];
    interpolations: Array<InterpolationType> = [];
    // Per key, its interpolator (null: none).
    interpolators: Array<Interpolator?> = [];
    // This track's index among every track of its animation (the
    // instance's cache of the last key found is indexed by it).
    flat: i32 = 0;

    constructor(property: string, kind: KeyFrameKind) {
        this.property = property;
        this.kind = kind;
    }

    get length(): i32 {
        return this.seconds.length;
    }

    // Rive's KeyedProperty::closestFrameIndex: the index of the first key
    // at or after `seconds` (the key's own index plus `exactOffset` when one
    // is exactly there; the key count when every key is before it).
    closestFrameIndex(seconds: f32, exactOffset: i32 = 0): i32 {
        const s = this.seconds;
        let start = 0;
        let end = s.length - 1;
        if (end < 0) return 0;
        // If it's the last keyframe, the binary search is skipped.
        if (seconds > unchecked(s[end])) return end + 1;
        while (start <= end) {
            const mid = (start + end) >> 1;
            const closest = unchecked(s[mid]);
            if (closest < seconds) start = mid + 1;
            else if (closest > seconds) end = mid - 1;
            else return mid + exactOffset;
        }
        return start;
    }

    // closestFrameIndex(seconds) starting from `hint`, the index a previous
    // call found: the same answer, without a search while time moves within
    // a segment or into the next (keys are at distinct times).
    closestFrameIndexFrom(seconds: f32, hint: i32): i32 {
        const s = this.seconds;
        const n = s.length;
        if (hint >= 0 && hint <= n) {
            if ((hint == 0 || unchecked(s[hint - 1]) < seconds) && (hint == n || seconds <= unchecked(s[hint]))) return hint;
            const next = hint + 1;
            if (next <= n && unchecked(s[next - 1]) < seconds && (next == n || seconds <= unchecked(s[next]))) return next;
        }
        return this.closestFrameIndex(seconds, 0);
    }
}

// One keyed object's tracks.
export class KeyedObjectTracks {
    // The node's path from the scene's root ("." the root).
    target: string;
    tracks: Array<KeyedTrack> = [];

    constructor(target: string) {
        this.target = target;
    }
}

// Rive's LinearAnimation, prepared.
export class LinearAnimation {
    name: string;
    fps: i32 = 60;
    duration: i32 = 60;
    speed: f32 = 1;
    loop: LoopMode = LoopMode.OneShot;
    workStart: i32 = -1;
    workEnd: i32 = -1;
    enableWorkArea: bool = false;
    quantize: bool = false;
    objects: Array<KeyedObjectTracks> = [];
    // How many tracks the objects hold in all (KeyedTrack.flat).
    trackCount: i32 = 0;
    // The callback tracks (`event:` and `signal:`), as pairs of the object's
    // and the track's index, so that an advance reports them without
    // visiting every track.
    callbackTracks: Array<i32> = [];

    constructor(name: string) {
        this.name = name;
    }

    // Rive's startSeconds: the work area's start when enabled, else 0.
    startSeconds(): f32 {
        return (this.enableWorkArea ? <f32>this.workStart : <f32>0) / <f32>this.fps;
    }

    // Rive's endSeconds: the work area's end when enabled, else the
    // duration.
    endSeconds(): f32 {
        return <f32>(this.enableWorkArea ? this.workEnd : this.duration) / <f32>this.fps;
    }

    // Rive's startTime(multiplier): where an instance starts, the end when
    // played backwards.
    startTime(multiplier: f32 = 1): f32 {
        return this.speed * multiplier >= 0 ? this.startSeconds() : this.endSeconds();
    }

    endTime(): f32 {
        return this.speed >= 0 ? this.endSeconds() : this.startSeconds();
    }

    // Rive's durationSeconds: |end - start| (the work area's length when it
    // is enabled).
    durationSeconds(): f32 {
        return Mathf.abs(this.endSeconds() - this.startSeconds());
    }

    // Rive's globalToLocalSeconds: a time from the start of play to one in
    // the animation, by the loop mode.
    globalToLocalSeconds(seconds: f32): f32 {
        const d = this.durationSeconds();
        if (this.loop == LoopMode.OneShot) return seconds + this.startTime();
        if (this.loop == LoopMode.Loop) return positiveMod(seconds, d) + this.startTime();
        const localTime = positiveMod(seconds, d);
        const direction = (<i32>(seconds / d)) % 2;
        return direction == 0 ? localTime + this.startTime() : this.endTime() - localTime;
    }

    // The time Rive's LinearAnimation::apply evaluates at: `seconds`, down
    // to a whole frame when the animation quantizes.
    applyTime(seconds: f32): f32 {
        if (!this.quantize) return seconds;
        const ffps = <f32>this.fps;
        return Mathf.floor(seconds * ffps) / ffps;
    }

    // Rive's LinearAnimation::reportKeyedCallbacks: the callback keys
    // crossed going from `secondsFrom` to `secondsTo`, to `sink`.
    reportKeyedCallbacks(sink: CallbackReporter, secondsFrom: f32, secondsTo: f32, speedDirection: f32, fromPong: bool): void {
        const isAtStartFrame = this.startTime(speedDirection) == secondsFrom;
        if (isAtStartFrame && fromPong) return;
        const cb = this.callbackTracks;
        for (let i = 0; i + 1 < cb.length; i += 2) {
            const o = unchecked(cb[i]);
            const t = unchecked(cb[i + 1]);
            reportTrackCallbacks(sink, o, t, unchecked(this.objects[o]).tracks[t], secondsFrom, secondsTo, isAtStartFrame);
        }
    }
}

// What reportKeyedCallbacks reports to (./instance.as CallbackSink is
// one): Rive's KeyedCallbackReporter.
export abstract class CallbackReporter {
    abstract callback(objectIndex: i32, trackIndex: i32, delaySeconds: f32): void;
}

// Rive's KeyedProperty::reportKeyedCallbacks: each key in the step, with
// Rive's rules for a key exactly at either end (forward: a key at the
// start of the step is reported only at the animation's start frame, one at
// its end is; backward the reverse).
function reportTrackCallbacks(sink: CallbackReporter, objectIndex: i32, trackIndex: i32, track: KeyedTrack,
    secondsFrom: f32, secondsTo: f32, isAtStartFrame: bool): void {
    if (secondsFrom == secondsTo || track.length == 0) return;
    const isForward = secondsFrom <= secondsTo;
    let fromExactOffset = 0;
    const toExactOffset = isForward ? 1 : 0;
    if (isForward) {
        if (!isAtStartFrame) fromExactOffset = 1;
    } else if (isAtStartFrame) {
        fromExactOffset = 1;
    }
    let idx = track.closestFrameIndex(secondsFrom, fromExactOffset);
    let idxTo = track.closestFrameIndex(secondsTo, toExactOffset);
    if (idxTo < idx) {
        const swap = idx;
        idx = idxTo;
        idxTo = swap;
    }
    while (idxTo > idx) {
        sink.callback(objectIndex, trackIndex, secondsTo - unchecked(track.seconds[idx]));
        idx++;
    }
}

// rive::math::positive_mod (Dart's modulus).
export function positiveMod(value: f32, range: f32): f32 {
    let r = range;
    if (r < 0) r = -r;
    let v = value % r;
    if (v < 0) v += r;
    return v;
}

function isCallbackProperty(property: string): bool {
    return property.startsWith("event:") || property.startsWith("signal:");
}

// The keys of `keys` in increasing frame (a stable sort: keys out of order
// are evaluated sorted, as the validator's keyframe-order warning says).
function sortedKeys(keys: Array<KeyFrameDecl>): Array<KeyFrameDecl> {
    const out = keys.slice(0);
    for (let i = 1; i < out.length; i++) {
        const k = out[i];
        let j = i - 1;
        while (j >= 0 && out[j].frame > k.frame) {
            out[j + 1] = out[j];
            j--;
        }
        out[j + 1] = k;
    }
    return out;
}

// Prepares `d`. Keys out of order are sorted by frame (the validator
// already refused a file with two keys on one frame). A keyed property's
// kind is its first key's (the validator refuses a property mixing kinds;
// a key of another kind is left out here). An fps below 1 is taken as 1
// (the reader refuses it; a declaration made in code may not).
export function prepareAnimation(d: LinearAnimationDecl): LinearAnimation {
    const a = new LinearAnimation(d.name);
    a.fps = d.fps >= 1 ? d.fps : 1;
    a.duration = d.duration;
    a.speed = <f32>d.speed;
    a.loop = d.loop;
    a.workStart = d.workStart;
    a.workEnd = d.workEnd;
    a.enableWorkArea = d.enableWorkArea;
    a.quantize = d.quantize;
    const fps = <f32>a.fps;
    let flat = 0;
    for (let o = 0; o < d.objects.length; o++) {
        const od = d.objects[o];
        const obj = new KeyedObjectTracks(od.target);
        for (let p = 0; p < od.properties.length; p++) {
            const pd = od.properties[p];
            const keys = sortedKeys(pd.keys);
            const kind = keys.length > 0 ? keys[0].kind : KeyFrameKind.Double;
            const t = new KeyedTrack(pd.property, kind);
            for (let k = 0; k < keys.length; k++) {
                const kd = keys[k];
                if (kd.kind != kind) continue;
                t.frames.push(kd.frame);
                t.seconds.push(<f32>kd.frame / fps);
                if (kind == KeyFrameKind.Color) t.colors.push(kd.color);
                else if (kind == KeyFrameKind.Bool) t.values.push(kd.boolean ? 1 : 0);
                else if (kind == KeyFrameKind.Quaternion) {
                    // (normalised once here, not at each slerp; a zero one
                    // is the identity)
                    const len = Math.sqrt(kd.qx * kd.qx + kd.qy * kd.qy + kd.qz * kd.qz + kd.qw * kd.qw);
                    const inv = len > 0 ? 1 / len : 0;
                    t.values.push(<f32>(kd.qx * inv));
                    t.values.push(<f32>(kd.qy * inv));
                    t.values.push(<f32>(kd.qz * inv));
                    t.values.push(len > 0 ? <f32>(kd.qw * inv) : 1);
                } else if (kind == KeyFrameKind.String || kind == KeyFrameKind.Id) t.texts.push(kd.text);
                else if (kind != KeyFrameKind.Callback) t.values.push(<f32>kd.number);
                t.interpolations.push(kd.interpolation);
                const ip = kd.interpolator;
                t.interpolators.push(ip != null ? new Interpolator(ip) : null);
            }
            t.flat = flat++;
            if (kind == KeyFrameKind.Callback && isCallbackProperty(pd.property)) {
                a.callbackTracks.push(o);
                a.callbackTracks.push(obj.tracks.length);
            }
            obj.tracks.push(t);
        }
        a.objects.push(obj);
    }
    a.trackCount = flat;
    return a;
}
