// Animation data (PLAN §3.3): actions made of F-curves addressed by
// Blender data paths, the per-object `AnimData` slot, and the frame
// evaluator that writes animated values into the scene.
//
// `fcurve.as` holds the keyframe math, `path.as` the data-path grammar,
// `eval.as` frame evaluation (applyFrame / evaluateAt). Import each type from
// the module that defines it.

import { FCurve, FrameRange, FRAME_EPSILON, insertAt } from "./fcurve";
import { cmpStr, minF32, maxF32, partialCmpF32, stableSort } from "../../../base/util";

export type ActionId = u32;

// "No action" (AnimData.action).
export const ACTION_NONE: u32 = u32.MAX_VALUE;

// Whether (c.dataPath, c.arrayIndex) sorts before (dataPath, index).
function pathIndexLess(c: FCurve, dataPath: string, index: u32): bool {
    const o = cmpStr(c.dataPath, dataPath);
    if (o != 0) return o < 0;
    return c.arrayIndex < index;
}

// A named set of F-curves (Blender's Action datablock). Field order is the
// file format. `Default` is `new Action("")`.
export class Action {
    name: string = "";
    fcurves: Array<FCurve> = [];

    constructor(name: string = "") {
        this.name = name;
        this.fcurves = [];
    }

    // Deep copy.
    clone(): Action {
        const a = new Action(this.name);
        for (let i = 0; i < this.fcurves.length; i++) a.fcurves.push(this.fcurves[i].clone());
        return a;
    }

    // PartialEq.
    equals(o: Action): bool {
        if (this.name != o.name || this.fcurves.length != o.fcurves.length) return false;
        for (let i = 0; i < this.fcurves.length; i++) {
            if (!this.fcurves[i].equals(o.fcurves[i])) return false;
        }
        return true;
    }

    // First and last keyed frame over every curve (null when there is none).
    frameRange(): FrameRange? {
        let out: FrameRange? = null;
        for (let i = 0; i < this.fcurves.length; i++) {
            const r = this.fcurves[i].frameRange();
            if (r != null) {
                const o = out;
                if (o != null) {
                    out = new FrameRange(minF32(o.lo, r.lo), maxF32(o.hi, r.hi));
                } else {
                    out = new FrameRange(r.lo, r.hi);
                }
            }
        }
        return out;
    }

    keyframeCount(): i32 {
        let n = 0;
        for (let i = 0; i < this.fcurves.length; i++) n += this.fcurves[i].keyframes.length;
        return n;
    }

    // Index of the curve for a path / index, or -1.
    find(dataPath: string, index: u32): i32 {
        for (let i = 0; i < this.fcurves.length; i++) {
            const c = this.fcurves[i];
            if (c.dataPath == dataPath && c.arrayIndex == index) return i;
        }
        return -1;
    }

    fcurve(dataPath: string, index: u32): FCurve? {
        const i = this.find(dataPath, index);
        return i >= 0 ? this.fcurves[i] : null;
    }

    // The curve for a path / index, created (sorted by path then index,
    // like Blender's channel list) when missing.
    ensure(dataPath: string, index: u32): FCurve {
        let i = this.find(dataPath, index);
        if (i < 0) {
            // The insertion point, by the binary search in fcurve.as.
            const cs = this.fcurves;
            let size = cs.length;
            let pos = 0;
            if (size > 0) {
                let base = 0;
                while (size > 1) {
                    const half = size / 2;
                    const mid = base + half;
                    if (pathIndexLess(cs[mid], dataPath, index)) base = mid;
                    size -= half;
                }
                pos = pathIndexLess(cs[base], dataPath, index) ? base + 1 : base;
            }
            insertAt<FCurve>(this.fcurves, pos, new FCurve(dataPath, index));
            i = pos;
        }
        return this.fcurves[i];
    }

    // Drop curves without keyframes.
    prune(): void {
        let w = 0;
        for (let i = 0; i < this.fcurves.length; i++) {
            const c = this.fcurves[i];
            if (c.keyframes.length != 0) {
                this.fcurves[w] = c;
                w++;
            }
        }
        this.fcurves.length = w;
    }

    // Every keyed frame, ascending and unique (for `frame jump`).
    keyedFrames(): Array<f32> {
        const frames: Array<f32> = [];
        for (let i = 0; i < this.fcurves.length; i++) {
            const ks = this.fcurves[i].keyframes;
            for (let j = 0; j < ks.length; j++) frames.push(ks[j].frame);
        }
        stableSort<f32>(frames, (a: f32, b: f32): i32 => partialCmpF32(a, b));
        // dedup_by(|a, b| (a - b).abs() < FRAME_EPSILON): `a` is the current
        // element, `b` the last kept one.
        const n = frames.length;
        if (n < 2) return frames;
        let w = 1;
        for (let i = 1; i < n; i++) {
            if (!(Mathf.abs(frames[i] - frames[w - 1]) < FRAME_EPSILON)) {
                frames[w] = frames[i];
                w++;
            }
        }
        frames.length = w;
        return frames;
    }
}

// An object's animation slot (Blender's `AnimData`; NLA comes later).
// `action == ACTION_NONE` means no action.

export class AnimData {
    action: u32 = ACTION_NONE;

    constructor(action: u32 = ACTION_NONE) {
        this.action = action;
    }

    hasAction(): bool {
        return this.action != ACTION_NONE;
    }

    clone(): AnimData {
        return new AnimData(this.action);
    }

    equals(o: AnimData): bool {
        return this.action == o.action;
    }
}
