// Frame evaluation, writing every animated value
// of the scene at a frame. `applyFrame` works in place (the caller usually
// does it on a clone, see `evaluateAt`); armatures whose pose channels
// changed are touched so the pose cache and the render fingerprint
// invalidate, meshes whose shape key values changed get a new revision.
//
// applyFrame, evaluateAt and actionUsers are free functions; Scene
// (engine/src/source/model/scene.as) has one-line delegating methods of the same names.
// evaluateAt returns the scene and its report as a `FrameEvaluation`.

import { Vec3, Quat, QUAT_IDENTITY } from "../../../base/vecmath";
import { clampF32, f32ToI32, roundF32, panic } from "../../../base/util";
import { debugF32 } from "../../../base/fmt";
import { eulerXyzFromQuat, quatFromEulerXyz } from "../../../base/math";
import { Channel, DataPath, DataPathKind } from "./path";
import { NO_BONE } from "../armature/mod";
import { Scene } from "../scene";

export class FrameReport {
    frame: f32 = 0;
    // Objects with an action.
    objects: i32 = 0;
    // Distinct pose bones written.
    bones: i32 = 0;
    shapeKeys: i32 = 0;
    constraints: i32 = 0;
    fcurves: i32 = 0;
    warnings: Array<string> = [];

    clone(): FrameReport {
        const r = new FrameReport();
        r.frame = this.frame;
        r.objects = this.objects;
        r.bones = this.bones;
        r.shapeKeys = this.shapeKeys;
        r.constraints = this.constraints;
        r.fcurves = this.fcurves;
        r.warnings = this.warnings.slice(0);
        return r;
    }

    equals(o: FrameReport): bool {
        if (this.frame != o.frame || this.objects != o.objects || this.bones != o.bones
            || this.shapeKeys != o.shapeKeys || this.constraints != o.constraints || this.fcurves != o.fcurves) {
            return false;
        }
        if (this.warnings.length != o.warnings.length) return false;
        for (let i = 0; i < this.warnings.length; i++) if (this.warnings[i] != o.warnings[i]) return false;
        return true;
    }
}

// `Scene::evaluate_at`'s `(Scene, FrameReport)`.
export class FrameEvaluation {
    scene: Scene;
    report: FrameReport;
    constructor(scene: Scene, report: FrameReport) {
        this.scene = scene;
        this.report = report;
    }
}

// Quaternion components in Blender's W X Y Z order.
function quatArray(q: Quat): Array<f32> {
    const a: Array<f32> = [];
    a.push(q.w);
    a.push(q.x);
    a.push(q.y);
    a.push(q.z);
    return a;
}

function quatFromArray(a: Array<f32>): Quat {
    const q = Quat.fromXyzw(a[1], a[2], a[3], a[0]);
    if (q.lengthSquared() < <f32>1e-12) {
        return QUAT_IDENTITY;
    }
    return q.normalize();
}

// Clamp that panics when `lo > hi` or either bound is NaN (util's clampF32
// does not). Only the shape key slider range can trip it.
function clampF32Checked(x: f32, lo: f32, hi: f32): f32 {
    if (!(lo <= hi)) {
        panic("min > max, or either was NaN. min = " + debugF32(lo) + ", max = " + debugF32(hi));
    }
    let r = x;
    if (r < lo) r = lo;
    if (r > hi) r = hi;
    return r;
}

function outOfRange(objName: string, dataPath: string, index: u32): string {
    return "'" + objName + "': " + dataPath + "[" + index.toString() + "] is out of range";
}

// Writes the animated values of every object with
// an action at `frame`. The scene's own `frame` is left alone.
export function applyFrame(scene: Scene, frame: f32): FrameReport {
    const report = new FrameReport();
    report.frame = frame;
    const objects = scene.objects;
    const actions = scene.actions;
    const poseDirty: Array<u32> = [];
    for (let id: u32 = 0; id < objects.idBound(); id++) {
        const obj = objects.get(id);
        if (obj == null) continue;
        const anim = obj.animation;
        if (anim == null || !anim.hasAction()) {
            continue;
        }
        const action = actions.get(anim.action);
        if (action == null) {
            report.warnings.push("'" + obj.name + "': its action no longer exists");
            continue;
        }
        report.objects += 1;
        // Quaternion and Euler channels are gathered per target and
        // written once, normalized, after every component is known.
        let objQuat: Array<f32>? = null;
        const boneQuat = new Map<u32, Array<f32>>();
        const boneEuler = new Map<u32, Vec3>();
        const bonesWritten: Array<u32> = [];
        let poseTouched = false;
        let keysTouched = false;
        const fcurves = action.fcurves;
        for (let fi = 0; fi < fcurves.length; fi++) {
            const fc = fcurves[fi];
            if (fc.mute || fc.keyframes.length == 0) {
                continue;
            }
            report.fcurves += 1;
            const v = fc.evaluate(frame);
            const i = fc.arrayIndex;
            const dp = DataPath.parse(fc.dataPath);
            switch (dp.kind) {
                case DataPathKind.Object: {
                    const ch = dp.chan;
                    if (ch == Channel.Location && i < 3) {
                        let t = obj.transform;
                        t.location.set(<i32>i, v);
                        obj.transform = t;
                    } else if (ch == Channel.RotationEuler && i < 3) {
                        let t = obj.transform;
                        t.rotation.set(<i32>i, v);
                        obj.transform = t;
                    } else if (ch == Channel.Scale && i < 3) {
                        let t = obj.transform;
                        t.scale.set(<i32>i, v);
                        obj.transform = t;
                    } else if (ch == Channel.RotationQuaternion && i < 4) {
                        let q = objQuat;
                        if (q == null) {
                            q = quatArray(quatFromEulerXyz(obj.transform.rotation));
                            objQuat = q;
                        }
                        q[<i32>i] = v;
                    } else {
                        report.warnings.push(outOfRange(obj.name, fc.dataPath, fc.arrayIndex));
                    }
                    break;
                }
                case DataPathKind.Bone: {
                    const bone = dp.bone;
                    const channel = dp.chan;
                    const arm = obj.armature();
                    if (arm == null) {
                        report.warnings.push(
                            "'" + obj.name + "': " + fc.dataPath + " animates a pose bone but the object is not an armature",
                        );
                        continue;
                    }
                    const bid = arm.find(bone);
                    if (bid == NO_BONE) {
                        report.warnings.push("'" + obj.name + "': no bone '" + bone + "' for " + fc.dataPath);
                        continue;
                    }
                    const pb = arm.bones.at(bid).pose;
                    if (channel == Channel.Location && i < 3) {
                        pb.location.set(<i32>i, v);
                    } else if (channel == Channel.Scale && i < 3) {
                        pb.scale.set(<i32>i, v);
                    } else if (channel == Channel.RotationQuaternion && i < 4) {
                        if (!boneQuat.has(bid)) boneQuat.set(bid, quatArray(pb.rotation));
                        const q = boneQuat.get(bid);
                        q[<i32>i] = v;
                    } else if (channel == Channel.RotationEuler && i < 3) {
                        let e = boneEuler.has(bid) ? boneEuler.get(bid) : eulerXyzFromQuat(pb.rotation);
                        e.set(<i32>i, v);
                        boneEuler.set(bid, e);
                    } else {
                        report.warnings.push(outOfRange(obj.name, fc.dataPath, fc.arrayIndex));
                        continue;
                    }
                    poseTouched = true;
                    if (!bonesWritten.includes(bid)) {
                        bonesWritten.push(bid);
                    }
                    break;
                }
                case DataPathKind.ConstraintInfluence: {
                    const bone = dp.bone;
                    const constraint = dp.constraint;
                    const arm = obj.armature();
                    if (arm == null) {
                        report.warnings.push("'" + obj.name + "': " + fc.dataPath + " needs an armature");
                        continue;
                    }
                    const bid = arm.find(bone);
                    if (bid == NO_BONE) {
                        report.warnings.push("'" + obj.name + "': no bone '" + bone + "' for " + fc.dataPath);
                        continue;
                    }
                    const cs = arm.bones.at(bid).pose.constraints;
                    let found = false;
                    for (let ci = 0; ci < cs.length; ci++) {
                        const c = cs[ci];
                        if (c.name == constraint) {
                            c.influence = clampF32(v, 0.0, 1.0);
                            poseTouched = true;
                            report.constraints += 1;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        report.warnings.push(
                            "'" + obj.name + "': bone '" + bone + "' has no constraint '" + constraint + "'",
                        );
                    }
                    break;
                }
                case DataPathKind.ShapeKeyValue: {
                    const key = dp.key;
                    const mesh = obj.mesh();
                    if (mesh == null) {
                        report.warnings.push("'" + obj.name + "': " + fc.dataPath + " needs a mesh");
                        continue;
                    }
                    const keys = mesh.shapeKeys;
                    let found = false;
                    for (let ki = 0; ki < keys.length; ki++) {
                        const k = keys[ki];
                        if (k.name == key) {
                            const clamped = clampF32Checked(v, k.sliderMin, k.sliderMax);
                            if (k.value != clamped) {
                                k.value = clamped;
                                keysTouched = true;
                            }
                            report.shapeKeys += 1;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        report.warnings.push("'" + obj.name + "': no shape key '" + key + "'");
                    }
                    break;
                }
                default: {
                    // An unknown data path.
                    report.warnings.push("'" + obj.name + "': unsupported data path '" + dp.raw + "'");
                    break;
                }
            }
        }
        const oq = objQuat;
        if (oq != null) {
            let t = obj.transform;
            t.rotation = eulerXyzFromQuat(quatFromArray(oq));
            obj.transform = t;
        }
        const arm = obj.armature();
        if (arm != null) {
            // The bones are disjoint within each map and quaternions are
            // written before Eulers, so the order within a map is not
            // observable.
            const qk = boneQuat.keys();
            for (let j = 0; j < qk.length; j++) {
                const bid = qk[j];
                arm.bones.at(bid).pose.rotation = quatFromArray(boneQuat.get(bid));
            }
            const ek = boneEuler.keys();
            for (let j = 0; j < ek.length; j++) {
                const bid = ek[j];
                arm.bones.at(bid).pose.rotation = quatFromEulerXyz(boneEuler.get(bid));
            }
            if (poseTouched) {
                arm.touch();
                poseDirty.push(id);
            }
        }
        if (keysTouched) {
            const mesh = obj.mesh();
            if (mesh != null) mesh.touch();
        }
        report.bones += bonesWritten.length;
    }
    return report;
}

// A copy of the scene with every action applied
// at `frame` and the current frame set to it.
export function evaluateAt(scene: Scene, frame: f32): FrameEvaluation {
    const s = scene.clone();
    const report = applyFrame(s, frame);
    s.frame = f32ToI32(roundF32(frame));
    return new FrameEvaluation(s, report);
}

// The objects whose animation uses `action`,

// in id order.
export function actionUsers(scene: Scene, action: u32): Array<u32> {
    const out: Array<u32> = [];
    const objects = scene.objects;
    for (let id: u32 = 0; id < objects.idBound(); id++) {
        const o = objects.get(id);
        if (o == null) continue;
        const a = o.animation;
        if (a != null && a.hasAction() && a.action == action) out.push(id);
    }
    return out;
}
