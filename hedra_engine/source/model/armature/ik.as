// FABRIK (forward and backward reaching inverse
// kinematics) over a chain of joint positions, with an optional pole target.
//
// The joint positions are an Array<Vec3>, written in place.


import { Vec3, Quat, VEC3_ZERO, VEC3_Y } from "../../../base/vecmath";
import { signedAngle } from "./mod";

// Solve a chain in place. `joints` are the chain's positions from the root
// (fixed) to the end effector; consecutive distances are preserved.
// Returns the remaining distance to the target.
export function fabrik(joints: Array<Vec3>, target: Vec3, iterations: u32, tolerance: f32): f32 {
    const n = joints.length;
    if (n < 2) return <f32>Infinity;
    const lengths: Array<f32> = [];
    for (let i = 0; i < n - 1; i++) lengths.push(joints[i + 1].distance(joints[i]));
    let total: f32 = 0;
    for (let i = 0; i < lengths.length; i++) total += lengths[i];
    const root = joints[0];
    if (root.distance(target) >= total) {
        // Out of reach: straighten the chain towards the target.
        let dir = (target - root).normalizeOrZero();
        if (dir == VEC3_ZERO) dir = VEC3_Y;
        for (let i = 1; i < n; i++) {
            joints[i] = joints[i - 1] + dir * lengths[i - 1];
        }
        return joints[n - 1].distance(target);
    }
    let err = joints[n - 1].distance(target);
    const iters: u32 = iterations > 1 ? iterations : 1;
    for (let it: u32 = 0; it < iters; it++) {
        if (err <= tolerance) break;
        // Forward: pull the end to the target and walk back to the root.
        joints[n - 1] = target;
        for (let i = n - 2; i >= 0; i--) {
            let d = (joints[i] - joints[i + 1]).normalizeOrZero();
            if (d == VEC3_ZERO) d = VEC3_Y;
            joints[i] = joints[i + 1] + d * lengths[i];
        }
        // Backward: pin the root and walk out to the end.
        joints[0] = root;
        for (let i = 0; i < n - 1; i++) {
            let d = (joints[i + 1] - joints[i]).normalizeOrZero();
            if (d == VEC3_ZERO) d = VEC3_Y;
            joints[i + 1] = joints[i] + d * lengths[i];
        }
        err = joints[n - 1].distance(target);
    }
    return err;
}

// Swing the intermediate joints about the root -> end axis so they lie in
// the plane through `pole` (Blender's pole target), then turn them by
// `poleAngle` about that axis.
export function applyPole(joints: Array<Vec3>, pole: Vec3, poleAngle: f32): void {
    const n = joints.length;
    if (n < 3) return;
    const root = joints[0];
    const axis = (joints[n - 1] - root).normalizeOrZero();
    if (axis == VEC3_ZERO) return;
    let v = pole - root;
    v = v - axis * v.dot(axis);
    if (v.lengthSquared() < <f32>1e-12) return;
    const poleDir = v.normalize();
    // The chain's current bend direction: the mid joints' mean offset.
    let bend = VEC3_ZERO;
    for (let i = 1; i < n - 1; i++) {
        const w = joints[i] - root;
        bend += w - axis * w.dot(axis);
    }
    if (bend.lengthSquared() < <f32>1e-12) {
        // A straight chain has no bend to swing; nothing to do.
        return;
    }
    bend = bend.normalize();
    const angle = signedAngle(bend, poleDir, axis) + poleAngle;
    const rot = Quat.fromAxisAngle(axis, angle);
    for (let i = 1; i < n - 1; i++) {
        joints[i] = root + rot.mulVec3(joints[i] - root);
    }
}
