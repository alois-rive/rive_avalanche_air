// Pose evaluation. Rest matrices from
// head/tail/roll, parent-space channels with Blender's `connected` /
// inherit flags, constraints in stack order and an IK pass (FABRIK) that
// re-drives the FK chain.
//
// All matrices are in armature space. Targets outside the armature are
// resolved by the caller (`Scene.poseEval`) through a `TargetFn` that
// returns the target's matrix already in armature space.
//
// Notes:
//   * `restEval(arm)` / `evaluatePose(arm, selfId, targets)` are free
//     functions; Armature (mod.as) has one-line delegating methods of the
//     same names.
//   * `TargetFn` is an abstract class; `resolve` returns a `TargetMatrix`
//     box or null (Mat4 is a struct and cannot be nullable).
//   * `selfId` is a u32 with NO_OBJ (u32.MAX_VALUE) for "none".
//   * basisFor returns the struct `PoseBasis` (location, rotation, scale).

import {
    Vec3, Mat3, Mat4, Quat, VEC3_ZERO, VEC3_X, VEC3_Y, VEC3_Z, MAT4_IDENTITY,
} from "../../../base/vecmath";
import { minF32, maxF32, panic } from "../../../base/util";
import { debugF32 } from "../../../base/fmt";
import { eulerXyzFromQuat, quatFromEulerXyz } from "../../../base/math";
import { Armature, BoneId, NO_BONE, rotationBetween } from "./mod";
import {
    Constraint, ConstraintKindTag, ConstraintSpace, ConstraintTarget, RotationMix, TrackAxis,
    trackAxisVector, ConstraintKindIk, ConstraintKindCopyLocation, ConstraintKindCopyRotation,
    ConstraintKindCopyScale, ConstraintKindCopyTransforms, ConstraintKindLimitRotation,
    ConstraintKindLimitLocation, ConstraintKindTrackTo, ConstraintKindDampedTrack,
    ConstraintKindStretchTo, ConstraintKindChildOf,
} from "./constraints";
import { fabrik, applyPole } from "./ik";

// "No object" for evaluatePose's `selfId`.
export const NO_OBJ: u32 = u32.MAX_VALUE;

// A resolved target matrix (what a `TargetFn` returns when it knows the target).
export class TargetMatrix {
    m: Mat4 = MAT4_IDENTITY;
    constructor(m: Mat4) {
        this.m = m;
    }
}

// Resolves a constraint target to its matrix in armature space
// Return null for an unknown target.
export abstract class TargetFn {
    abstract resolve(t: ConstraintTarget): TargetMatrix?;
}

// A resolver that knows no target (for tests).
export class NoTargets extends TargetFn {
    resolve(t: ConstraintTarget): TargetMatrix? {
        return null;
    }
}

// What basisFor returns: location, rotation and scale.
export struct PoseBasis {
    location: Vec3 = Vec3(0, 0, 0);
    rotation: Quat = Quat(0, 0, 0, 1);
    scale: Vec3 = Vec3(1, 1, 1);
    constructor(location: Vec3, rotation: Quat, scale: Vec3) {
        this.location = location;
        this.rotation = rotation;
        this.scale = scale;
    }
}

// The evaluated skeleton. Arrays are indexed by bone id (identity / zero
// for unused ids).
export class PoseEval {
    // Parents before children.
    order: Array<u32> = [];
    // Blender's `matrix_local`: rest pose in armature space.
    rest: Array<Mat4> = [];
    // Blender's `pose.bones[].matrix`: posed bone in armature space.
    pose: Array<Mat4> = [];
    length: Array<f32> = [];
    // Matrix the channel basis is measured in: `pose = parent_space * basis`.
    parentSpace: Array<Mat4> = [];
    warnings: Array<string> = [];

    // Skinning matrix (Blender's `chan_mat`): rest space -> posed space.
    deformMatrix(id: BoneId): Mat4 {
        return this.pose[<i32>id] * this.rest[<i32>id].inverse();
    }

    head(id: BoneId): Vec3 {
        return this.pose[<i32>id].transformPoint3(VEC3_ZERO);
    }

    tail(id: BoneId): Vec3 {
        return this.pose[<i32>id].transformPoint3(VEC3_Y * this.length[<i32>id]);
    }

    restHead(id: BoneId): Vec3 {
        return this.rest[<i32>id].transformPoint3(VEC3_ZERO);
    }

    restTail(id: BoneId): Vec3 {
        return this.rest[<i32>id].transformPoint3(VEC3_Y * this.length[<i32>id]);
    }

    // The channel values that would place a bone at `newPose` given its
    // current parent space: `(location, rotation, scale)`.
    basisFor(id: BoneId, newPose: Mat4): PoseBasis {
        const basis = this.parentSpace[<i32>id].inverse() * newPose;
        const srt = basis.toScaleRotationTranslation();
        return PoseBasis(srt.translation, srt.rotation.normalize(), srt.scale);
    }

    // True when the bone was posed away from rest by more than noise.
    isPosed(id: BoneId): bool {
        const d = this.pose[<i32>id] - this.rest[<i32>id];
        const cols = d.toColsArray();
        for (let i = 0; i < cols.length; i++) {
            if (Mathf.abs(cols[i]) > <f32>1e-5) return true;
        }
        return false;
    }

    // Deep copy.
    clone(): PoseEval {
        const e = new PoseEval();
        e.order = this.order.slice(0);
        e.rest = copyMats(this.rest);
        e.pose = copyMats(this.pose);
        e.length = this.length.slice(0);
        e.parentSpace = copyMats(this.parentSpace);
        e.warnings = this.warnings.slice(0);
        return e;
    }

    // Field-wise equality.
    equals(o: PoseEval): bool {
        if (this.order.length != o.order.length) return false;
        for (let i = 0; i < this.order.length; i++) if (this.order[i] != o.order[i]) return false;
        if (!matsEq(this.rest, o.rest) || !matsEq(this.pose, o.pose) || !matsEq(this.parentSpace, o.parentSpace)) {
            return false;
        }
        if (this.length.length != o.length.length) return false;
        for (let i = 0; i < this.length.length; i++) if (this.length[i] != o.length[i]) return false;
        if (this.warnings.length != o.warnings.length) return false;
        for (let i = 0; i < this.warnings.length; i++) if (this.warnings[i] != o.warnings[i]) return false;
        return true;
    }
}

function copyMats(a: Array<Mat4>): Array<Mat4> {
    const out: Array<Mat4> = [];
    for (let i = 0; i < a.length; i++) out.push(a[i]);
    return out;
}

function matsEq(a: Array<Mat4>, b: Array<Mat4>): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (!(a[i] == b[i])) return false;
    return true;
}

// Blend two affine matrices by decomposition (location lerp, rotation
// slerp, scale lerp), used for constraint influence.
export function blendMatrices(a: Mat4, b: Mat4, t: f32): Mat4 {
    if (t <= <f32>0.0) {
        return a;
    }
    if (t >= <f32>1.0) {
        return b;
    }
    const da = a.toScaleRotationTranslation();
    const db = b.toScaleRotationTranslation();
    return Mat4.fromScaleRotationTranslation(
        da.scale.lerp(db.scale, t), da.rotation.slerp(db.rotation, t), da.translation.lerp(db.translation, t),
    );
}

// Drop the scale of a matrix's 3x3 part, keeping rotation and translation.
function withoutScale(m: Mat4): Mat4 {
    const d = m.toScaleRotationTranslation();
    return Mat4.fromRotationTranslation(d.rotation, d.translation);
}

function withTranslation(m: Mat4, t: Vec3): Mat4 {
    let out = m;
    out.wAxis = t.extend(1.0);
    return out;
}

class Ctx {
    arm: Armature;
    selfId: u32;
    targets: TargetFn;
    constructor(arm: Armature, selfId: u32, targets: TargetFn) {
        this.arm = arm;
        this.selfId = selfId;
        this.targets = targets;
    }
}

// Rest matrices only (edit mode
// display, inverse bind matrices).
export function restEval(arm: Armature): PoseEval {
    const n = <i32>arm.bones.idBound();
    const order = arm.hierarchyOrder();
    const rest: Array<Mat4> = [];
    const length: Array<f32> = [];
    for (let i = 0; i < n; i++) {
        rest.push(MAT4_IDENTITY);
        length.push(0);
    }
    for (let id: u32 = 0; id < <u32>n; id++) {
        const b = arm.bones.get(id);
        if (b == null) continue;
        rest[<i32>id] = b.restMatrix();
        length[<i32>id] = b.length();
    }
    const parentSpace: Array<Mat4> = [];
    for (let i = 0; i < n; i++) parentSpace.push(MAT4_IDENTITY);
    for (let i = 0; i < order.length; i++) {
        const id = order[i];
        // In rest the parent's pose is its rest matrix, so the channel
        // space collapses to the bone's own rest matrix.
        parentSpace[<i32>id] = rest[<i32>id];
    }
    const e = new PoseEval();
    e.order = order;
    e.pose = copyMats(rest);
    e.rest = rest;
    e.length = length;
    e.parentSpace = parentSpace;
    return e;
}

// Full pose (channels, constraints, IK). `selfId` (NO_OBJ = none) lets
// constraints target bones of this armature; `targets` resolves the rest.
export function evaluatePose(arm: Armature, selfId: u32, targets: TargetFn): PoseEval {
    const ctx = new Ctx(arm, selfId, targets);
    const pinned = new Map<u32, Mat4>();
    let ev = fkPass(ctx, pinned);
    // IK constraints in hierarchy order; each re-drives the chain and
    // the FK pass below it.
    let anyIk = false;
    const order = ev.order.slice(0);
    for (let oi = 0; oi < order.length; oi++) {
        const id = order[oi];
        const bone = arm.bones.at(id);
        const cs = bone.pose.constraints;
        for (let ci = 0; ci < cs.length; ci++) {
            const c = cs[ci];
            if (!(c.enabled && c.influence > <f32>0.0)) continue;
            if (c.kind.tag == ConstraintKindTag.Ik) {
                anyIk = true;
                solveIk(ctx, ev, id, c, pinned);
                ev = fkPass(ctx, pinned);
            }
        }
    }
    if (!anyIk) {
        return ev;
    }
    return ev;
}

// One forward-kinematics pass with non-IK constraints; bones in `pinned`
// take the given matrix instead (IK results).
function fkPass(ctx: Ctx, pinned: Map<u32, Mat4>): PoseEval {
    const arm = ctx.arm;
    const ev = restEval(arm);
    const n = ev.rest.length;
    const done: Array<bool> = [];
    for (let i = 0; i < n; i++) done.push(false);
    const order = ev.order.slice(0);
    for (let oi = 0; oi < order.length; oi++) {
        const id = order[oi];
        const bone = arm.bones.at(id);
        const rest = ev.rest[<i32>id];
        let parentSpace = MAT4_IDENTITY;
        const p = bone.parent;
        if (p != NO_BONE) {
            const prest = ev.rest[<i32>p];
            const ppose = ev.pose[<i32>p];
            let parentEff = ppose;
            if (!bone.inheritRotation) {
                // Hinge: the parent's posed location with its rest rotation.
                parentEff = withTranslation(prest, ppose.transformPoint3(VEC3_ZERO));
            }
            if (!bone.inheritScale) {
                parentEff = withoutScale(parentEff);
            }
            if (bone.connected && (!bone.inheritRotation || !bone.inheritScale)) {
                // Keep the head on the parent's posed tail whatever the
                // flags dropped from the parent matrix.
                const tail = ev.tail(p);
                const offs = prest.inverse() * rest;
                const rot3 = Mat3.fromMat4(parentEff);
                parentEff = withTranslation(parentEff, tail - rot3.mulVec3(offs.wAxis.truncate()));
            }
            parentSpace = parentEff * prest.inverse();
        }
        // `pose = parent_space * rest * basis`: the channel is measured in
        // the bone's rest frame.
        const space = parentSpace * rest;
        ev.parentSpace[<i32>id] = space;
        const isPinned = pinned.has(id);
        let pose = isPinned ? pinned.get(id) : space * bone.pose.basis(bone.connected);
        if (!isPinned) {
            const cs = bone.pose.constraints;
            for (let ci = 0; ci < cs.length; ci++) {
                const c = cs[ci];
                if (!(c.enabled && c.influence > <f32>0.0)) continue;
                if (c.kind.tag == ConstraintKindTag.Ik) {
                    continue;
                }
                const r = applyConstraint(ctx, ev, done, id, c, pose);
                if (r.kind == OUTCOME_SOME) {
                    pose = blendMatrices(pose, r.m, minF32(c.influence, 1.0));
                } else if (r.kind == OUTCOME_ERR) {
                    if (!ev.warnings.includes(r.err)) {
                        ev.warnings.push(r.err);
                    }
                }
            }
        }
        ev.pose[<i32>id] = pose;
        done[<i32>id] = true;
    }
    return ev;
}

// A matrix or an error message.
class MatResult {
    ok: bool = false;
    m: Mat4 = MAT4_IDENTITY;
    err: string = "";
    static okv(m: Mat4): MatResult {
        const r = new MatResult();
        r.ok = true;
        r.m = m;
        return r;
    }
    static fail(err: string): MatResult {
        const r = new MatResult();
        r.err = err;
        return r;
    }
}

const OUTCOME_SOME: i32 = 0;
const OUTCOME_NONE: i32 = 1;
const OUTCOME_ERR: i32 = 2;

// A matrix, nothing (OUTCOME_NONE), or an error message.
class Outcome {
    kind: i32 = OUTCOME_NONE;
    m: Mat4 = MAT4_IDENTITY;
    err: string = "";
    static some(m: Mat4): Outcome {
        const r = new Outcome();
        r.kind = OUTCOME_SOME;
        r.m = m;
        return r;
    }
    static none(): Outcome {
        return new Outcome();
    }
    static fail(err: string): Outcome {
        const r = new Outcome();
        r.kind = OUTCOME_ERR;
        r.err = err;
        return r;
    }
}

function missingText(t: ConstraintTarget, c: Constraint): string {
    // A target cleared when its object was deleted (as Blender's None).
    if (t.object == NO_OBJ) return "constraint '" + c.name + "' has no target";
    const sub = t.subtarget;
    const what = sub != null ? "bone '" + sub + "'" : "object #" + t.object.toString();
    return "constraint '" + c.name + "': target " + what + " is missing";
}

// A target's matrix in armature space. Bones of this armature use their
// already evaluated pose (or rest when they come later in the order).
function targetMatrix(ctx: Ctx, ev: PoseEval, done: Array<bool>, t: ConstraintTarget, c: Constraint): MatResult {
    const sub = t.subtarget;
    if (ctx.selfId != NO_OBJ && sub != null && t.object == ctx.selfId) {
        const bid = ctx.arm.find(sub);
        if (bid == NO_BONE) return MatResult.fail(missingText(t, c));
        return MatResult.okv(done[<i32>bid] ? ev.pose[<i32>bid] : ev.rest[<i32>bid]);
    }
    const r = ctx.targets.resolve(t);
    if (r == null) return MatResult.fail(missingText(t, c));
    return MatResult.okv(r.m);
}

// The target read in `space`: world = armature space; local = the target
// bone's channel (or the object's own matrix for objects).
function targetInSpace(ctx: Ctx, ev: PoseEval, done: Array<bool>, t: ConstraintTarget, c: Constraint): MatResult {
    const w = targetMatrix(ctx, ev, done, t, c);
    if (!w.ok) return w;
    const world = w.m;
    const sub = t.subtarget;
    if (c.space == ConstraintSpace.Local && ctx.selfId != NO_OBJ && sub != null && t.object == ctx.selfId) {
        const bid = ctx.arm.find(sub);
        if (bid != NO_BONE) {
            return MatResult.okv(ev.parentSpace[<i32>bid].inverse() * world);
        }
    }
    return MatResult.okv(world);
}

// Owner matrix in the constraint's space (`owner`) and the conversion back
// (`back`).
struct OwnerSpace {
    owner: Mat4 = MAT4_IDENTITY;
    back: Mat4 = MAT4_IDENTITY;
    constructor(owner: Mat4, back: Mat4) {
        this.owner = owner;
        this.back = back;
    }
}

function ownerInSpace(ev: PoseEval, id: BoneId, space: ConstraintSpace, pose: Mat4): OwnerSpace {
    if (space == ConstraintSpace.World) {
        return OwnerSpace(pose, MAT4_IDENTITY);
    }
    const ps = ev.parentSpace[<i32>id];
    return OwnerSpace(ps.inverse() * pose, ps);
}

// Clamp that panics when `lo > hi` or either bound is NaN (util's clampF32
// does not).
function clampF32Checked(x: f32, lo: f32, hi: f32): f32 {
    if (!(lo <= hi)) {
        panic("min > max, or either was NaN. min = " + debugF32(lo) + ", max = " + debugF32(hi));
    }
    let r = x;
    if (r < lo) r = lo;
    if (r > hi) r = hi;
    return r;
}

function maskedEuler(base: Vec3, from: Vec3, axes: Array<bool>): Vec3 {
    return Vec3(
        axes[0] ? from.x : base.x,
        axes[1] ? from.y : base.y,
        axes[2] ? from.z : base.z,
    );
}

function allTrue(axes: Array<bool>): bool {
    for (let i = 0; i < axes.length; i++) if (!axes[i]) return false;
    return true;
}

// An optional Mat3 (`some` says whether `m` is set).
struct Mat3Opt {
    some: bool = false;
    m: Mat3 = Mat3(Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0));
    constructor(some: bool, m: Mat3) {
        this.some = some;
        this.m = m;
    }
}

// Frame whose `track` axis points along `dir` and whose `up` axis leans
// towards `upHint`.
function trackRotation(track: TrackAxis, up: TrackAxis, dir: Vec3, upHint: Vec3): Mat3Opt {
    const none = Mat3Opt(false, Mat3(Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0)));
    const a = trackAxisVector(track);
    const b = trackAxisVector(up);
    if (Mathf.abs(a.dot(b)) > <f32>0.5) {
        return none;
    }
    const aa = dir.normalizeOrZero();
    if (aa == VEC3_ZERO) {
        return none;
    }
    let bb = upHint - aa * aa.dot(upHint);
    if (bb.lengthSquared() < <f32>1e-8) {
        bb = VEC3_Y - aa * aa.dot(VEC3_Y);
        if (bb.lengthSquared() < <f32>1e-8) {
            bb = VEC3_X - aa * aa.dot(VEC3_X);
        }
    }
    const bn = bb.normalize();
    const local = Mat3.fromCols(a, b, a.cross(b));
    const world = Mat3.fromCols(aa, bn, aa.cross(bn));
    return Mat3Opt(true, world * local.inverse());
}

// One non-IK constraint. `Outcome.none()` = nothing to do.
function applyConstraint(ctx: Ctx, ev: PoseEval, done: Array<bool>, id: BoneId, c: Constraint, pose: Mat4): Outcome {
    const os = ownerInSpace(ev, id, c.space, pose);
    const owner = os.owner;
    const back = os.back;
    const srt = owner.toScaleRotationTranslation();
    const scale = srt.scale;
    const rot = srt.rotation;
    const loc = srt.translation;
    let result = MAT4_IDENTITY;
    switch (c.kind.tag) {
        case ConstraintKindTag.Ik:
            return Outcome.none();
        case ConstraintKindTag.CopyLocation: {
            const k = c.kind as ConstraintKindCopyLocation;
            const r = targetInSpace(ctx, ev, done, k.target, c);
            if (!r.ok) return Outcome.fail(r.err);
            const tl = r.m.wAxis.truncate();
            let out = loc;
            for (let i = 0; i < 3; i++) {
                if (k.axes[i]) {
                    const v = k.invert[i] ? -tl.get(i) : tl.get(i);
                    out.set(i, k.offset ? loc.get(i) + v : v);
                }
            }
            result = Mat4.fromScaleRotationTranslation(scale, rot, out);
            break;
        }
        case ConstraintKindTag.CopyRotation: {
            const k = c.kind as ConstraintKindCopyRotation;
            const r = targetInSpace(ctx, ev, done, k.target, c);
            if (!r.ok) return Outcome.fail(r.err);
            let tr = r.m.toScaleRotationTranslation().rotation;
            if (!allTrue(k.axes)) {
                const e = maskedEuler(VEC3_ZERO, eulerXyzFromQuat(tr), k.axes);
                tr = quatFromEulerXyz(e);
            }
            let q = tr;
            switch (k.mix) {
                case RotationMix.Replace: {
                    if (allTrue(k.axes)) {
                        q = tr;
                    } else {
                        const e = maskedEuler(eulerXyzFromQuat(rot), eulerXyzFromQuat(tr), k.axes);
                        q = quatFromEulerXyz(e);
                    }
                    break;
                }
                case RotationMix.Before: {
                    q = tr * rot;
                    break;
                }
                default: {
                    q = rot * tr;
                    break;
                }
            }
            result = Mat4.fromScaleRotationTranslation(scale, q, loc);
            break;
        }
        case ConstraintKindTag.CopyScale: {
            const k = c.kind as ConstraintKindCopyScale;
            const r = targetInSpace(ctx, ev, done, k.target, c);
            if (!r.ok) return Outcome.fail(r.err);
            const ts = r.m.toScaleRotationTranslation().scale;
            let s = scale;
            for (let i = 0; i < 3; i++) {
                if (k.axes[i]) {
                    s.set(i, ts.get(i));
                }
            }
            result = Mat4.fromScaleRotationTranslation(s, rot, loc);
            break;
        }
        case ConstraintKindTag.CopyTransforms: {
            const k = c.kind as ConstraintKindCopyTransforms;
            const r = targetInSpace(ctx, ev, done, k.target, c);
            if (!r.ok) return Outcome.fail(r.err);
            const tm = r.m;
            switch (k.mix) {
                case RotationMix.Replace: {
                    result = tm;
                    break;
                }
                case RotationMix.Before: {
                    result = tm * (ev.parentSpace[<i32>id].inverse() * pose);
                    break;
                }
                default: {
                    result = pose * (ev.parentSpace[<i32>id].inverse() * tm);
                    break;
                }
            }
            break;
        }
        case ConstraintKindTag.LimitRotation: {
            const k = c.kind as ConstraintKindLimitRotation;
            let e = eulerXyzFromQuat(rot);
            for (let i = 0; i < 3; i++) {
                if (k.axes[i]) {
                    const mn = k.min.get(i);
                    const mx = k.max.get(i);
                    // Panics only when both bounds are NaN.

                    e.set(i, clampF32Checked(e.get(i), minF32(mn, mx), maxF32(mx, mn)));
                }
            }
            result = Mat4.fromScaleRotationTranslation(scale, quatFromEulerXyz(e), loc);
            break;
        }
        case ConstraintKindTag.LimitLocation: {
            const k = c.kind as ConstraintKindLimitLocation;
            let l = loc;
            for (let i = 0; i < 3; i++) {
                if (k.useMin[i]) {
                    l.set(i, maxF32(l.get(i), k.min.get(i)));
                }
                if (k.useMax[i]) {
                    l.set(i, minF32(l.get(i), k.max.get(i)));
                }
            }
            result = Mat4.fromScaleRotationTranslation(scale, rot, l);
            break;
        }
        case ConstraintKindTag.TrackTo: {
            const k = c.kind as ConstraintKindTrackTo;
            const r = targetInSpace(ctx, ev, done, k.target, c);
            if (!r.ok) return Outcome.fail(r.err);
            const dir = r.m.wAxis.truncate() - loc;
            const tr = trackRotation(k.track, k.up, dir, VEC3_Z);
            if (!tr.some) {
                return Outcome.fail(
                    "constraint '" + c.name
                    + "': track and up axes must differ and the target must not sit on the head",
                );
            }
            result = Mat4.fromScaleRotationTranslation(scale, Quat.fromMat3(tr.m), loc);
            break;
        }
        case ConstraintKindTag.DampedTrack: {
            const k = c.kind as ConstraintKindDampedTrack;
            const r = targetInSpace(ctx, ev, done, k.target, c);
            if (!r.ok) return Outcome.fail(r.err);
            const dir = r.m.wAxis.truncate() - loc;
            if (dir.lengthSquared() < <f32>1e-12) {
                return Outcome.none();
            }
            const cur = rot.mulVec3(trackAxisVector(k.track));
            const q = rotationBetween(cur, dir);
            result = Mat4.fromScaleRotationTranslation(scale, (q * rot).normalize(), loc);
            break;
        }
        case ConstraintKindTag.StretchTo: {
            const k = c.kind as ConstraintKindStretchTo;
            const r = targetInSpace(ctx, ev, done, k.target, c);
            if (!r.ok) return Outcome.fail(r.err);
            const dir = r.m.wAxis.truncate() - loc;
            const dist = dir.length();
            if (dist < <f32>1e-9) {
                return Outcome.none();
            }
            const restLen: f32 = k.restLength > <f32>0.0 ? k.restLength : maxF32(ev.length[<i32>id], 1e-6);
            const cur = rot.mulVec3(VEC3_Y);
            const q = (rotationBetween(cur, dir) * rot).normalize();
            const f = dist / restLen;
            const side: f32 = k.volume ? <f32>1.0 / Mathf.sqrt(f) : <f32>1.0;
            const s = Vec3(scale.x * side, scale.y * f, scale.z * side);
            result = Mat4.fromScaleRotationTranslation(s, q, loc);
            break;
        }
        default: {
            // ChildOf
            const k = c.kind as ConstraintKindChildOf;
            const r = targetInSpace(ctx, ev, done, k.target, c);
            if (!r.ok) return Outcome.fail(r.err);
            result = r.m * k.inverse * owner;
            break;
        }
    }
    return Outcome.some(back * result);
}

// Solve one IK constraint on `owner`: FABRIK over the chain, pole target,
// then pin the chain bones to the solved matrices.
function solveIk(ctx: Ctx, ev: PoseEval, owner: BoneId, c: Constraint, pinned: Map<u32, Mat4>): void {
    if (c.kind.tag != ConstraintKindTag.Ik) {
        return;
    }
    const k = c.kind as ConstraintKindIk;
    const arm = ctx.arm;
    const done: Array<bool> = [];
    for (let i = 0; i < ev.rest.length; i++) done.push(true);
    const tr = targetMatrix(ctx, ev, done, k.target, c);
    if (!tr.ok) {
        if (!ev.warnings.includes(tr.err)) {
            ev.warnings.push(tr.err);
        }
        return;
    }
    const targetPos = tr.m.wAxis.truncate();
    // Chain from the owner up, then reversed so the root comes first.
    const chain: Array<u32> = [];
    let cur: u32 = k.useTail ? owner : arm.bones.at(owner).parent;
    const max: u64 = k.chainLength == 0 ? u64.MAX_VALUE : <u64>k.chainLength;
    while (cur != NO_BONE) {
        if (<u64>chain.length >= max) {
            break;
        }
        chain.push(cur);
        cur = arm.bones.at(cur).parent;
    }
    if (chain.length == 0) {
        return;
    }
    chain.reverse();
    const joints: Array<Vec3> = [];
    for (let i = 0; i < chain.length; i++) joints.push(ev.head(chain[i]));
    const last = chain[chain.length - 1];
    joints.push(ev.tail(last));
    let scale: f32 = 0.0;
    for (let i = 0; i < ev.length.length; i++) scale = maxF32(scale, ev.length[i]);
    scale = maxF32(scale, 1e-3);
    fabrik(joints, targetPos, k.iterations > 1 ? k.iterations : 1, scale * <f32>1e-5);
    const pole = k.pole;
    if (pole != null) {
        const pm = targetMatrix(ctx, ev, done, pole, c);
        if (pm.ok) {
            applyPole(joints, pm.m.wAxis.truncate(), k.poleAngle);
        }
    }
    for (let i = 0; i < chain.length; i++) {
        const b = chain[i];
        const before = ev.pose[<i32>b];
        const d = before.toScaleRotationTranslation();
        const s = d.scale;
        const r = d.rotation;
        const curDir = r.mulVec3(VEC3_Y);
        const newDir = joints[i + 1] - joints[i];
        const q = rotationBetween(curDir, newDir);
        const after = Mat4.fromScaleRotationTranslation(s, (q * r).normalize(), joints[i]);
        const blended = blendMatrices(before, after, minF32(c.influence, 1.0));
        ev.pose[<i32>b] = blended;
        pinned.set(b, blended);
    }
}
