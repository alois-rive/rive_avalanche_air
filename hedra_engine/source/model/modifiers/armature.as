// The Armature modifier, linear blend
// skinning (PLAN §5) by an armature's evaluated pose, with weights from the
// mesh's vertex groups named after deform bones and, for vertices without
// any, bone envelopes.
//
// Everything happens in armature space: `arm_world^-1 * obj_world` takes
// a vertex there, each deform bone's `pose * rest^-1` moves it, and the
// inverse brings the blend back into the object. `preserve_volume` blends
// the rotations as quaternions before translating (a cheap stand-in for
// dual quaternion skinning that avoids the candy-wrapper collapse on
// twists; it is not Blender's exact DQS).

import { clampF32, maxF32 } from "../../../base/util";
import { Vec3, Quat, Mat4, MAT4_IDENTITY, QUAT_IDENTITY } from "../../../base/vecmath";
import { Mesh } from "../mesh/mod";
import { Armature } from "../armature/mod";
import { PoseEval } from "../armature/pose";
import { VertexGroup, NO_VGROUP } from "../scene";

// Per-bone data the deform needs, resolved once per evaluation.
export class SkinBone {
    // Vertex group index feeding this bone; NO_VGROUP = none (no group of
    // that name).
    group: u32 = NO_VGROUP;
    deform: Mat4 = MAT4_IDENTITY;
    // Rest head, tail and radii in armature space, for envelopes.
    head: Vec3 = Vec3(0, 0, 0);
    tail: Vec3 = Vec3(0, 0, 0);
    headRadius: f32 = 0;
    tailRadius: f32 = 0;
    envelopeDistance: f32 = 0;
    envelopeWeight: f32 = 0;
}

// Blender's `distfactor_to_bone`: 1 inside the head/tail radii, falling
// to 0 over `distance` outside them.
export function envelopeFactor(p: Vec3, head: Vec3, tail: Vec3, radHead: f32, radTail: f32, distance: f32): f32 {
    const axis = tail - head;
    const len2 = axis.lengthSquared();
    let closest = head;
    let rad = radHead;
    if (!(len2 < <f32>1e-12)) {
        const t = clampF32((p - head).dot(axis) / len2, 0, 1);
        closest = head + axis * t;
        rad = radHead + (radTail - radHead) * t;
    }
    const d = p.distance(closest);
    if (d <= rad) {
        return 1.0;
    }
    if (distance <= <f32>0.0 || d >= rad + distance) {
        return 0.0;
    }
    const a = (d - rad) / distance;
    return maxF32(<f32>1.0 - a * a, 0);
}

// Resolve the bones of `arm` against the mesh's vertex groups: every deform
// bone, in id order.
export function skinBones(arm: Armature, ev: PoseEval, groups: Array<VertexGroup>): Array<SkinBone> {
    const out: Array<SkinBone> = [];
    const bb = arm.bones.idBound();
    for (let id: u32 = 0; id < bb; id++) {
        const b = arm.bones.get(id);
        if (b == null || !b.deform) continue;
        const s = new SkinBone();
        let group = NO_VGROUP;
        for (let i = 0; i < groups.length; i++) {
            if (groups[i].name == b.name) {
                group = <u32>i;
                break;
            }
        }
        s.group = group;
        s.deform = ev.deformMatrix(id);
        s.head = b.head;
        s.tail = b.tail;
        s.headRadius = b.headRadius;
        s.tailRadius = b.tailRadius;
        s.envelopeDistance = b.envelopeDistance;
        s.envelopeWeight = b.envelopeWeight;
        out.push(s);
    }
    return out;
}

// Deform `mesh` in place. `toArm` takes object space to armature space.
export function deform(
    mesh: Mesh,
    bones: Array<SkinBone>,
    toArm: Mat4,
    useVertexGroups: bool,
    useEnvelopes: bool,
    preserveVolume: bool,
): void {
    const fromArm = toArm.inverse();
    // The vertex's (bone index, weight) influences: two parallel lists, cleared per vertex.
    const infBone: Array<i32> = [];
    const infW: Array<f32> = [];
    const vb = mesh.verts.idBound();
    for (let vid: u32 = 0; vid < vb; vid++) {
        const v = mesh.verts.get(vid);
        if (v == null) continue;
        infBone.length = 0;
        infW.length = 0;
        const p = toArm.transformPoint3(v.co);
        if (useVertexGroups) {
            for (let i = 0; i < bones.length; i++) {
                const g = bones[i].group;
                if (g == NO_VGROUP) continue;
                // `groups.iter().find(..)`: the first entry of that group.
                for (let k = 0; k < v.groups.length; k++) {
                    if (v.groups[k].group == g) {
                        const w = v.groups[k].weight;
                        if (w > <f32>0.0) {
                            infBone.push(i);
                            infW.push(w);
                        }
                        break;
                    }
                }
            }
        }
        if (infBone.length == 0 && useEnvelopes) {
            for (let i = 0; i < bones.length; i++) {
                const b = bones[i];
                const f = envelopeFactor(p, b.head, b.tail, b.headRadius, b.tailRadius, b.envelopeDistance)
                    * b.envelopeWeight;
                if (f > <f32>0.0) {
                    infBone.push(i);
                    infW.push(f);
                }
            }
        }
        const n = infBone.length;
        if (n == 0) {
            continue;
        }
        // The sum starts from -0.0, so an empty sum is -0.0.
        let total: f32 = -0.0;
        for (let k = 0; k < n; k++) total += infW[k];
        if (total <= <f32>1e-12) {
            continue;
        }
        // Blender: weights over 1 in total are normalized, under 1 leave
        // the remainder at rest.
        const norm: f32 = total > <f32>1.0 ? <f32>1.0 / total : <f32>1.0;
        const restShare: f32 = total < <f32>1.0 ? <f32>1.0 - total : <f32>0.0;
        let moved: Vec3;
        if (preserveVolume) {
            let qAcc = QUAT_IDENTITY.mulScalar(0);
            let tAcc = Vec3(0, 0, 0);
            let sAcc = Vec3(0, 0, 0);
            let hasFirst = false;
            let first = QUAT_IDENTITY;
            for (let k = 0; k < n; k++) {
                const w = infW[k] * norm;
                const srt = bones[infBone[k]].deform.toScaleRotationTranslation();
                const s = srt.scale;
                let r = srt.rotation;
                if (hasFirst && first.dot(r) < <f32>0.0) r = -r;
                if (!hasFirst) {
                    first = r;
                    hasFirst = true;
                }
                qAcc = Quat(
                    qAcc.x + r.x * w,
                    qAcc.y + r.y * w,
                    qAcc.z + r.z * w,
                    qAcc.w + r.w * w,
                );
                sAcc = sAcc + s * w;
                // Rotate about the bone's rest head: translation part of the
                // deform matrix applied to the vertex offset separately.
                tAcc = tAcc + bones[infBone[k]].deform.transformPoint3(p) * w;
            }
            let share: f32 = -0.0;
            for (let k = 0; k < n; k++) share += infW[k] * norm;
            const q = qAcc.lengthSquared() > <f32>1e-12 ? qAcc.normalize() : QUAT_IDENTITY;
            // Blend: the linear position gives the translation, the
            // normalized quaternion re-orients the offset from the linear
            // centroid of the bone heads to keep volume on twists.
            const lin = tAcc / maxF32(share, 1e-12);
            let centroid = Vec3(0, 0, 0);
            for (let k = 0; k < n; k++) {
                const b = bones[infBone[k]];
                centroid = centroid + b.deform.transformPoint3(b.head) * (infW[k] * norm / share);
            }
            let restCentroid = Vec3(0, 0, 0);
            for (let k = 0; k < n; k++) {
                restCentroid = restCentroid + bones[infBone[k]].head * (infW[k] * norm / share);
            }
            const offset = p - restCentroid;
            const dq = centroid + q.mulVec3(offset.mul(sAcc / maxF32(share, 1e-12)));
            // Mix DQ-style and linear halfway: cheap and stable.
            moved = (dq + lin) * <f32>0.5 * share + p * restShare;
        } else {
            let acc = p * restShare;
            for (let k = 0; k < n; k++) {
                acc = acc + bones[infBone[k]].deform.transformPoint3(p) * (infW[k] * norm);
            }
            moved = acc;
        }
        v.co = fromArm.transformPoint3(moved);
    }
    mesh.touch();
    mesh.recalcNormals();
}
