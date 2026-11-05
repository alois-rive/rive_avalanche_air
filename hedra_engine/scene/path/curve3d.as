// Milestone 32: Godot's Curve3D (docs/formats/RSCN.md, "Paths"), the curve
// a Path3D holds: control points, each a position with an in and an out
// handle (relative to the position) and a tilt (radians about the curve's
// tangent), and the bake Godot samples from: points about bake_interval
// apart along the curve, the distance to each, its tilt, its forward
// (tangent) and, with up_vector_enabled, its up vector (Godot's parallel
// transport frames). ./bake.as bakes and samples, as Godot 4.4's
// scene/resources/curve.cpp does, in f32 as Godot's real_t.
//
// The points are kept as Godot stores them in `_data` (and as the .rscn
// writes them): `points` nine numbers a point, the in handle, the out
// handle, then the position; `tilts` one number a point. Every change goes
// through a method here, which marks the bake stale (Godot's mark_dirty)
// and tells the curve's listeners (the Path3D nodes using it, which place
// their PathFollow3D children again, as Godot's Path3D hears its curve's
// `changed`). The bake is made again on the next query that needs it, into
// the same arrays: a query allocates nothing, a bake only what the arrays
// grow by.

import { Mat3, Mat4, Vec3 } from "../../base/vecmath";
import { Resource } from "../resource/types";
// (the sampling functions under other names: the methods have Godot's)
import {
    bakeCurve, closestOffset, closestPoint, pointBakedPosture, sampleBaked as bakedPoint,
    sampleBakedUpVector as bakedUpVector, sampleBakedWithRotation as bakedFrame, sampleBakedTilt as bakedTilt,
    samplePoint, samplef, tessellateEvenLengthInto, tessellateInto,
} from "./bake";

// Numbers a point takes in `points`: in, out, position.
export const CURVE_POINT_STRIDE: i32 = 9;

// What hears that a curve changed (a Path3D: ../tree/node.as).
export abstract class CurveListener {
    abstract curveChanged(c: Curve3D): void;
}

export class Curve3D extends Resource {
    closed: bool = false;
    bakeInterval: f32 = 0.2;
    upVectorEnabled: bool = true;
    // The control points, as `_data` holds them (see the header). Read
    // them freely; change them through the methods below, or call
    // markDirty() after writing them directly (the loader and the editor's
    // live drag do).
    points: Array<f64> = [];
    tilts: Array<f64> = [];
    // Bumped by every change: what was made from an older version (a
    // gizmo's lines, a follower's placement) is made again.
    version: i32 = 0;
    listeners: Array<CurveListener> = [];

    // The bake (./bake.as fills it; Godot's baked_*_cache): xyz a point
    // for points, forwards and ups, one number a point for tilts and
    // distances. `bakedUps` is empty without up_vector_enabled.
    // `pointsInCache[i]` is the baked index of control point i (Godot's
    // points_in_cache, for the editor's tilt handles).
    bakedDirty: bool = true;
    bakedPoints: Array<f32> = [];
    bakedTilts: Array<f32> = [];
    bakedDists: Array<f32> = [];
    bakedForwards: Array<f32> = [];
    bakedUps: Array<f32> = [];
    pointsInCache: Array<i32> = [];
    bakedMaxOfs: f32 = 0;

    className(): string {
        return "Curve3D";
    }

    // Godot's mark_dirty: the bake is stale, the version moves, and the
    // listeners hear of it.
    markDirty(): void {
        this.bakedDirty = true;
        this.version++;
        for (let i = 0; i < this.listeners.length; i++) unchecked(this.listeners[i]).curveChanged(this);
    }

    addListener(l: CurveListener): void {
        if (!this.listeners.includes(l)) this.listeners.push(l);
    }

    removeListener(l: CurveListener): void {
        const i = this.listeners.indexOf(l);
        if (i >= 0) this.listeners.splice(i, 1);
    }

    // The bake, made now if it is stale.
    bake(): void {
        if (this.bakedDirty) bakeCurve(this);
    }

    // --- the points (Godot's Curve3D methods) --------------------------------

    getPointCount(): i32 {
        return this.points.length / CURVE_POINT_STRIDE;
    }

    // Godot's set_point_count: fewer drops the last points, more adds
    // points at the origin with no handles and no tilt.
    setPointCount(n: i32): void {
        if (n < 0) return;
        const have = this.getPointCount();
        if (n == have) return;
        if (n < have) {
            this.points.length = n * CURVE_POINT_STRIDE;
            this.tilts.length = n;
        } else {
            for (let i = have; i < n; i++) {
                for (let k = 0; k < CURVE_POINT_STRIDE; k++) this.points.push(0);
                this.tilts.push(0);
            }
        }
        this.markDirty();
    }

    // Godot's add_point: at `index` (the end when it is -1 or past it).
    addPoint(position: Vec3, inHandle: Vec3 = Vec3(0, 0, 0), outHandle: Vec3 = Vec3(0, 0, 0), index: i32 = -1): void {
        const n = this.getPointCount();
        const at = index >= 0 && index < n ? index : n;
        const base = at * CURVE_POINT_STRIDE;
        const v: Array<f64> = [
            <f64>inHandle.x, <f64>inHandle.y, <f64>inHandle.z,
            <f64>outHandle.x, <f64>outHandle.y, <f64>outHandle.z,
            <f64>position.x, <f64>position.y, <f64>position.z,
        ];
        // (AssemblyScript's splice inserts nothing: grow, then shift up)
        const pts = this.points;
        const was = pts.length;
        for (let k = 0; k < CURVE_POINT_STRIDE; k++) pts.push(0);
        for (let k = was - 1; k >= base; k--) pts[k + CURVE_POINT_STRIDE] = pts[k];
        for (let k = 0; k < CURVE_POINT_STRIDE; k++) pts[base + k] = v[k];
        const tilts = this.tilts;
        tilts.push(0);
        for (let k = tilts.length - 2; k >= at; k--) tilts[k + 1] = tilts[k];
        tilts[at] = 0;
        this.markDirty();
    }

    removePoint(index: i32): void {
        if (index < 0 || index >= this.getPointCount()) return;
        this.points.splice(index * CURVE_POINT_STRIDE, CURVE_POINT_STRIDE);
        this.tilts.splice(index, 1);
        this.markDirty();
    }

    clearPoints(): void {
        if (this.points.length == 0) return;
        this.points.length = 0;
        this.tilts.length = 0;
        this.markDirty();
    }

    private vec(index: i32, k: i32): Vec3 {
        const b = index * CURVE_POINT_STRIDE + k;
        if (index < 0 || index >= this.getPointCount()) return Vec3(0, 0, 0);
        return Vec3(<f32>this.points[b], <f32>this.points[b + 1], <f32>this.points[b + 2]);
    }

    private setVec(index: i32, k: i32, v: Vec3): void {
        if (index < 0 || index >= this.getPointCount()) return;
        const b = index * CURVE_POINT_STRIDE + k;
        this.points[b] = <f64>v.x;
        this.points[b + 1] = <f64>v.y;
        this.points[b + 2] = <f64>v.z;
        this.markDirty();
    }

    getPointIn(index: i32): Vec3 {
        return this.vec(index, 0);
    }

    getPointOut(index: i32): Vec3 {
        return this.vec(index, 3);
    }

    getPointPosition(index: i32): Vec3 {
        return this.vec(index, 6);
    }

    setPointIn(index: i32, v: Vec3): void {
        this.setVec(index, 0, v);
    }

    setPointOut(index: i32, v: Vec3): void {
        this.setVec(index, 3, v);
    }

    setPointPosition(index: i32, v: Vec3): void {
        this.setVec(index, 6, v);
    }

    getPointTilt(index: i32): f32 {
        return index >= 0 && index < this.tilts.length ? <f32>this.tilts[index] : 0;
    }

    setPointTilt(index: i32, tilt: f32): void {
        if (index < 0 || index >= this.tilts.length) return;
        this.tilts[index] = <f64>tilt;
        this.markDirty();
    }

    setClosed(on: bool): void {
        if (this.closed == on) return;
        this.closed = on;
        this.markDirty();
    }

    isClosed(): bool {
        return this.closed;
    }

    setBakeInterval(d: f32): void {
        this.bakeInterval = d;
        this.markDirty();
    }

    getBakeInterval(): f32 {
        return this.bakeInterval;
    }

    setUpVectorEnabled(on: bool): void {
        this.upVectorEnabled = on;
        this.markDirty();
    }

    isUpVectorEnabled(): bool {
        return this.upVectorEnabled;
    }

    // --- sampling (./bake.as) -------------------------------------------------

    getBakedLength(): f32 {
        this.bake();
        return this.bakedMaxOfs;
    }

    // Godot's sample: on the Bézier segment from point `index`, at t.
    sample(index: i32, t: f32): Vec3 {
        return samplePoint(this, index, t);
    }

    sampleF(findex: f32): Vec3 {
        return samplef(this, findex);
    }

    sampleBaked(offset: f32, cubic: bool = false): Vec3 {
        this.bake();
        return bakedPoint(this, offset, cubic);
    }

    // The frame at `offset`: its basis's -z along the curve, y its up (the
    // baked up vector, or +y without up_vector_enabled), turned by the tilt
    // with applyTilt; its origin the point. Godot's Transform3D as a Mat4
    // (columns x, y, z, origin), in the curve's space.
    sampleBakedWithRotation(offset: f32, cubic: bool = false, applyTilt: bool = false): Mat4 {
        this.bake();
        return bakedFrame(this, offset, cubic, applyTilt);
    }

    sampleBakedTilt(offset: f32): f32 {
        this.bake();
        return bakedTilt(this, offset);
    }

    sampleBakedUpVector(offset: f32, applyTilt: bool = false): Vec3 {
        this.bake();
        return bakedUpVector(this, offset, applyTilt);
    }

    getClosestOffset(to: Vec3): f32 {
        this.bake();
        return closestOffset(this, to);
    }

    getClosestPoint(to: Vec3): Vec3 {
        this.bake();
        return closestPoint(this, to);
    }

    // The frame at control point `index` (Godot's get_point_baked_posture,
    // the editor's tilt handle and disk).
    getPointBakedPosture(index: i32, applyTilt: bool = false): Mat3 {
        this.bake();
        return pointBakedPosture(this, index, applyTilt);
    }

    // The baked points as Vec3s (a new array: Godot's get_baked_points).
    getBakedPoints(): Array<Vec3> {
        this.bake();
        const n = this.bakedPoints.length / 3;
        const out = new Array<Vec3>(n);
        for (let i = 0; i < n; i++) {
            out[i] = Vec3(this.bakedPoints[i * 3], this.bakedPoints[i * 3 + 1], this.bakedPoints[i * 3 + 2]);
        }
        return out;
    }

    // Godot's tessellate (max_stages 5, tolerance 4 degrees by default) and
    // tessellate_even_length, as xyz numbers into `out` (cleared first);
    // the number of points.
    tessellate(out: Array<f32>, maxStages: i32 = 5, toleranceDegrees: f32 = 4): i32 {
        return tessellateInto(this, maxStages, toleranceDegrees, out);
    }

    tessellateEvenLength(out: Array<f32>, maxStages: i32 = 5, length: f32 = 0.2): i32 {
        return tessellateEvenLengthInto(this, maxStages, length, out);
    }
}
