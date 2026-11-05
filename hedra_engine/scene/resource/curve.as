// Godot's Curve (milestone 35; docs/formats/RSCN.md "Particles"): a value
// over 0 to 1, which a CPUParticles3D reads over each particle's life
// (its *_curve properties). Points sorted by offset, each with a left and
// a right tangent and their modes, between min_value and max_value; read
// from `_data` as Godot writes it (five items a point: Vector2(offset,
// value), left_tangent, right_tangent, left_mode, right_mode), then
// `point_count`, as Godot's loader sets them.
//
// Sampling is Godot's: `sample(offset)` the cubic Bézier between the two
// points around the offset (each tangent a third of the way along), and
// `sampleBaked(offset)` the line between two of `bakeResolution` samples
// of it, baked on the first call after a change; a particle reads the
// baked one, as Godot's CPUParticles3D does. The bake allocates once per
// change, sampling never. (Godot 4's CPUParticles3D reads sample(); a
// particle here reads the bake, Godot 3's way: at the default resolution
// within 0.0002 of the curve for the sample's curves, and a fraction of
// the cost each step.)

import { Value, ValueKind } from "../value";
import { Resource } from "./types";

// Godot's Curve.TangentMode.
export const CURVE_TANGENT_FREE: i32 = 0;
export const CURVE_TANGENT_LINEAR: i32 = 1;

// The items a point takes in `_data`.
export const CURVE_DATA_STRIDE: i32 = 5;

// Godot's default bake_resolution, and the most a file may ask for (a
// bake is kept per curve; 4096 floats is 16 KB).
export const CURVE_BAKE_DEFAULT: i32 = 100;
export const CURVE_BAKE_MAX: i32 = 4096;

export class Curve extends Resource {
    minValue: f32 = 0;
    maxValue: f32 = 1;
    bakeResolution: i32 = CURVE_BAKE_DEFAULT;
    // The points, by offset, side by side: offset (x), value (y), the
    // tangents and their modes.
    offsets: Array<f32> = [];
    values: Array<f32> = [];
    leftTangents: Array<f32> = [];
    rightTangents: Array<f32> = [];
    leftModes: Array<i32> = [];
    rightModes: Array<i32> = [];
    // The bake (bakeResolution samples over 0 to 1), made by sampleBaked
    // when `dirty`.
    baked: StaticArray<f32> = new StaticArray<f32>(0);
    dirty: bool = true;

    className(): string {
        return "Curve";
    }

    pointCount(): i32 {
        return this.offsets.length;
    }

    // Sets the points from `_data` (Godot's _set_data): five items a point,
    // a point whose items are of the wrong kinds left out (the validator's
    // curve-points says so). Sorts them by offset, as Godot keeps them.
    // Marks the bake stale.
    setData(v: Value): void {
        this.offsets = [];
        this.values = [];
        this.leftTangents = [];
        this.rightTangents = [];
        this.leftModes = [];
        this.rightModes = [];
        if (v.kind == ValueKind.Array) {
            const items = v.items;
            for (let i = 0; i + CURVE_DATA_STRIDE <= items.length; i += CURVE_DATA_STRIDE) {
                const p = items[i];
                if (p.kind != ValueKind.Vector2 || p.n.length < 2) continue;
                if (!items[i + 1].isNumber() || !items[i + 2].isNumber()) continue;
                if (!items[i + 3].isNumber() || !items[i + 4].isNumber()) continue;
                this.insertPoint(<f32>p.n[0], <f32>p.n[1], items[i + 1].asF32(), items[i + 2].asF32(),
                    items[i + 3].asI32(), items[i + 4].asI32());
            }
        }
        this.dirty = true;
    }

    // Godot's set_point_count: fewer drops the last points, more adds
    // points at (0, 0) with free tangents.
    setPointCount(n: i32): void {
        const want = n < 0 ? 0 : n;
        while (this.offsets.length > want) {
            this.offsets.pop();
            this.values.pop();
            this.leftTangents.pop();
            this.rightTangents.pop();
            this.leftModes.pop();
            this.rightModes.pop();
        }
        while (this.offsets.length < want) {
            this.offsets.push(0);
            this.values.push(0);
            this.leftTangents.push(0);
            this.rightTangents.push(0);
            this.leftModes.push(CURVE_TANGENT_FREE);
            this.rightModes.push(CURVE_TANGENT_FREE);
        }
        this.dirty = true;
    }

    // Adds a point in offset order (after any of the same offset).
    insertPoint(x: f32, y: f32, left: f32, right: f32, leftMode: i32, rightMode: i32): void {
        this.offsets.push(x);
        this.values.push(y);
        this.leftTangents.push(left);
        this.rightTangents.push(right);
        this.leftModes.push(leftMode);
        this.rightModes.push(rightMode);
        let at = this.offsets.length - 1;
        while (at > 0 && this.offsets[at - 1] > x) {
            this.swap(at - 1, at);
            at--;
        }
        this.dirty = true;
    }

    private swap(a: i32, b: i32): void {
        const o = this.offsets[a];
        this.offsets[a] = this.offsets[b];
        this.offsets[b] = o;
        const v = this.values[a];
        this.values[a] = this.values[b];
        this.values[b] = v;
        const l = this.leftTangents[a];
        this.leftTangents[a] = this.leftTangents[b];
        this.leftTangents[b] = l;
        const r = this.rightTangents[a];
        this.rightTangents[a] = this.rightTangents[b];
        this.rightTangents[b] = r;
        const lm = this.leftModes[a];
        this.leftModes[a] = this.leftModes[b];
        this.leftModes[b] = lm;
        const rm = this.rightModes[a];
        this.rightModes[a] = this.rightModes[b];
        this.rightModes[b] = rm;
    }

    // Godot's update_auto_tangents(index): a point's tangent whose mode is
    // linear, and its neighbours' toward it, made the slope of the line to
    // the neighbour (the editor's presets and point edits call it; a file's
    // tangents are kept as written, as Godot's _set_data keeps them).
    updateAutoTangents(index: i32): void {
        const n = this.offsets.length;
        if (index < 0 || index >= n) return;
        if (index > 0) {
            const slope = this.slope(index, index - 1);
            if (this.leftModes[index] == CURVE_TANGENT_LINEAR) this.leftTangents[index] = slope;
            if (this.rightModes[index - 1] == CURVE_TANGENT_LINEAR) this.rightTangents[index - 1] = slope;
        }
        if (index + 1 < n) {
            const slope = this.slope(index, index + 1);
            if (this.rightModes[index] == CURVE_TANGENT_LINEAR) this.rightTangents[index] = slope;
            if (this.leftModes[index + 1] == CURVE_TANGENT_LINEAR) this.leftTangents[index + 1] = slope;
        }
        this.dirty = true;
    }

    // Godot's v.y / v.x of the unit vector from point a to point b (two
    // points at one offset give an infinite slope, as Godot's do).
    private slope(a: i32, b: i32): f32 {
        const dx = this.offsets[b] - this.offsets[a];
        const dy = this.values[b] - this.values[a];
        const len = Mathf.sqrt(dx * dx + dy * dy);
        if (len == 0) return 0;
        return (dy / len) / (dx / len);
    }

    // Godot's get_index: the point at or before `offset` (a lower-bound
    // binary search; the last point past the end, the first before it).
    private indexAt(offset: f32): i32 {
        let lo = 0;
        let hi = this.offsets.length - 1;
        while (hi - lo > 1) {
            const m = (lo + hi) / 2;
            const a = unchecked(this.offsets[m]);
            const b = unchecked(this.offsets[m + 1]);
            if (a < offset && b < offset) lo = m;
            else if (a > offset) hi = m;
            else return m;
        }
        if (offset > unchecked(this.offsets[hi])) return hi;
        return lo;
    }

    // Godot's sample(offset): the value at `offset` (0 to 1) along the
    // points: the cubic Bézier between the point at or before it and the
    // next (Godot's sample_local_nocheck, each control point a third of
    // the way along, at the point's tangent); the first point's value at or
    // before it, the last's past it; 0 without points. Allocates nothing.
    sample(offset: f32): f32 {
        const n = this.offsets.length;
        if (n == 0) return 0;
        if (n == 1) return unchecked(this.values[0]);
        const i = this.indexAt(offset);
        if (i == n - 1) return unchecked(this.values[i]);
        const local = offset - unchecked(this.offsets[i]);
        if (i == 0 && local <= 0) return unchecked(this.values[0]);
        const ax = unchecked(this.offsets[i]);
        const ay = unchecked(this.values[i]);
        const bx = unchecked(this.offsets[i + 1]);
        const by = unchecked(this.values[i + 1]);
        let d = bx - ax;
        // (Godot's is_zero_approx: CMP_EPSILON)
        if (Mathf.abs(d) < <f32>0.00001) return by;
        const t = local / d;
        d /= 3;
        const yac = ay + d * unchecked(this.rightTangents[i]);
        const ybc = by - d * unchecked(this.leftTangents[i + 1]);
        // Godot's bezier_interpolate.
        const omt = <f32>1 - t;
        const omt2 = omt * omt;
        const t2 = t * t;
        return ay * omt2 * omt + yac * omt2 * t * 3 + ybc * omt * t2 * 3 + by * t2 * t;
    }

    // Godot's _bake: bakeResolution samples over 0 to 1, the first and the
    // last the end points' values (0 without points). Allocates only when
    // the resolution changed.
    bake(): void {
        const res = min<i32>(max<i32>(this.bakeResolution, 1), CURVE_BAKE_MAX);
        if (this.baked.length != res) this.baked = new StaticArray<f32>(res);
        const b = this.baked;
        for (let i = 1; i < res - 1; i++) unchecked(b[i] = this.sample(<f32>(<f64>i / <f64>(res - 1))));
        const n = this.offsets.length;
        // (the last written after the first, as Godot's: a bake of one
        // sample holds the last point's value)
        unchecked(b[0] = n > 0 ? unchecked(this.values[0]) : 0);
        unchecked(b[res - 1] = n > 0 ? unchecked(this.values[n - 1]) : 0);
        this.dirty = false;
    }

    // Godot's sample_baked(offset): what a particle reads, the line
    // between the two baked samples around `offset` (the first before 0,
    // the last past 1; 0 for an offset that is not finite, as Godot's
    // refuses one). Bakes first when the points changed; allocates nothing
    // otherwise.
    sampleBaked(offset: f32): f32 {
        if (this.dirty) this.bake();
        if (!isFinite<f32>(offset)) return 0;
        const b = this.baked;
        const len = b.length;
        if (len == 0) return 0;
        if (len == 1) return unchecked(b[0]);
        let fi = offset * <f32>(len - 1);
        let i: i32;
        if (fi < 0) {
            i = 0;
            fi = 0;
        } else if (fi >= <f32>len) {
            i = len - 1;
            fi = 0;
        } else {
            i = <i32>Mathf.floor(fi);
        }
        if (i + 1 < len) {
            const t = fi - <f32>i;
            const a = unchecked(b[i]);
            return a + (unchecked(b[i + 1]) - a) * t;
        }
        return unchecked(b[len - 1]);
    }
}
