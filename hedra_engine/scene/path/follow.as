// Milestone 32: where a PathFollow3D stands on its Path3D's curve, Godot
// 4.4's PathFollow3D::update_transform and correct_posture
// (scene/3d/path_3d.cpp), as a pure function of the curve and the
// follower's fields, so that the node (../tree/node.as PathFollow3D), the
// tools and the tests share one placement. In f32 and Godot's operation
// order (./math.as). Allocates nothing: a follower moved every frame (a
// tween, a binding, a script) costs no heap.

import { Mat3, Mat4, Vec3 } from "../../base/vecmath";
import { Curve3D } from "./curve3d";
import { axisAngle, basisMul, eulerNormalizedYXZ, fromEulerYXZ, fromScale, lookingAt } from "./math";

// PathFollow3D.rotation_mode, Godot's RotationMode.
export const ROTATION_NONE: i32 = 0;
export const ROTATION_Y: i32 = 1;
export const ROTATION_XY: i32 = 2;
export const ROTATION_XYZ: i32 = 3;
export const ROTATION_ORIENTED: i32 = 4;

function basisOf(t: Mat4): Mat3 {
    return Mat3(t.xAxis.truncate(), t.yAxis.truncate(), t.zAxis.truncate());
}

function withBasis(m: Mat3, origin: Vec3): Mat4 {
    return Mat4(m.xAxis.extend(0), m.yAxis.extend(0), m.zAxis.extend(0), origin.extend(1));
}

// Godot's PathFollow3D::correct_posture: the frame `t` with its rotation
// locked by `mode` (none clears it; y keeps only the yaw and xy the yaw
// and pitch of its YXZ Euler angles, read from the orthonormalised basis;
// oriented looks along its -z with +y up; xyz keeps it). The origin stays.
export function correctPosture(t: Mat4, mode: i32): Mat4 {
    const origin = t.wAxis.truncate();
    if (mode == ROTATION_NONE) {
        return withBasis(Mat3(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)), origin);
    }
    if (mode == ROTATION_ORIENTED) {
        const tangent = -t.zAxis.truncate();
        return withBasis(lookingAt(tangent, Vec3(0, 1, 0)), origin);
    }
    let euler = eulerNormalizedYXZ(basisOf(t));
    if (mode == ROTATION_Y) {
        euler.x = 0;
        euler.z = 0;
    } else if (mode == ROTATION_XY) {
        euler.z = 0;
    }
    return withBasis(fromEulerYXZ(euler), origin);
}

// Godot's update_transform for a follower `progress` metres along `c`
// (held to the curve by the sampling: a progress set before the node
// entered the tree is kept as written, as Godot keeps it), offset by
// h_offset along its x and v_offset along its y, with `scale` (the node's
// own, kept as Godot keeps get_scale()). The caller checks that the curve
// has a baked length above 0 (Godot leaves the transform alone otherwise).
// The local transform, in the Path3D's space.
export function pathFollowLocal(c: Curve3D, progress: f64, hOffset: f64, vOffset: f64, mode: i32, cubic: bool,
    tiltEnabled: bool, useModelFront: bool, scale: Vec3): Mat4 {
    // (Godot's progress and offsets are real_t: f32)
    const p = <f32>progress;
    let basis = Mat3(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
    let origin: Vec3;
    if (mode == ROTATION_NONE) {
        origin = c.sampleBaked(p, cubic);
    } else {
        let t = c.sampleBakedWithRotation(p, cubic, false);
        // The tangent before correct_posture, for the tilt.
        const tangent = -t.zAxis.truncate();
        t = correctPosture(t, mode);
        basis = basisOf(t);
        origin = t.wAxis.truncate();
        // Switch +z and -z: the model's front (+z) along the path.
        if (useModelFront) basis = basisMul(basis, fromScale(Vec3(-1, 1, -1)));
        // The tilt after correct_posture, about the curve's own tangent.
        if (tiltEnabled) basis = basisMul(axisAngle(tangent, c.sampleBakedTilt(p)), basis);
    }
    // Transform3D::translate_local: each row of the basis dotted with the
    // offset; then Basis::scale_local, basis * from_scale(scale).
    const offset = Vec3(<f32>hOffset, <f32>vOffset, 0);
    origin = Vec3(
        origin.x + Vec3(basis.xAxis.x, basis.yAxis.x, basis.zAxis.x).dot(offset),
        origin.y + Vec3(basis.xAxis.y, basis.yAxis.y, basis.zAxis.y).dot(offset),
        origin.z + Vec3(basis.xAxis.z, basis.yAxis.z, basis.zAxis.z).dot(offset),
    );
    basis = basisMul(basis, fromScale(scale));
    return withBasis(basis, origin);
}
