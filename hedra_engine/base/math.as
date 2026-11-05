// Small math helpers on top of vecmath.as, with
// Blender's conventions (Z up, right-handed, Euler XYZ in radians).

import { Vec3, Quat, Mat3, Mat4, toRadians, toDegrees, asinf, cosf, atan2f } from "./vecmath";
import { roundF32 } from "./util";
import { fixedF32 } from "./fmt";

// Blender's Euler XYZ (extrinsic X, then Y, then Z): `R = Rz * Ry * Rx`.
export function quatFromEulerXyz(e: Vec3): Quat {
    return (Quat.fromRotationZ(e.z) * Quat.fromRotationY(e.y) * Quat.fromRotationX(e.x)).normalize();
}

// Inverse of quatFromEulerXyz.
export function eulerXyzFromQuat(q: Quat): Vec3 {
    return eulerXyzFromMat3(Mat3.fromQuat(q.normalize()));
}

export function eulerXyzFromMat3(m: Mat3): Vec3 {
    // With R = Rz Ry Rx: R[2][0] = -sin(y), R[2][1] = cos(y) sin(x),
    // R[2][2] = cos(y) cos(x), R[1][0] = cos(y) sin(z), R[0][0] = cos(y) cos(z).
    // Matrices are column-major: R[row][col] = m.col(col)[row].
    const r20 = m.xAxis.z;
    // Clamp to [-1, 1] for asin.
    let sy: f32 = -r20;
    if (sy < <f32>-1.0) sy = <f32>-1.0;
    if (sy > <f32>1.0) sy = <f32>1.0;
    const y = asinf(sy);
    const cy = cosf(y);
    if (Mathf.abs(cy) > <f32>1e-6) {
        const x = atan2f(m.yAxis.z, m.zAxis.z);
        const z = atan2f(m.xAxis.y, m.xAxis.x);
        return Vec3(x, y, z);
    }
    // Gimbal lock: fold z into x.
    const x = atan2f(-m.zAxis.y, m.yAxis.y);
    return Vec3(x, y, 0);
}

export function degToRad(v: Vec3): Vec3 {
    return Vec3(toRadians(v.x), toRadians(v.y), toRadians(v.z));
}

export function radToDeg(v: Vec3): Vec3 {
    return Vec3(toDegrees(v.x), toDegrees(v.y), toDegrees(v.z));
}

// Unit vector for an axis name: the first character of `axis`, ASCII
// case-insensitive; x -> X, y -> Y, anything else -> Z.
export function axisVector(axis: string): Vec3 {
    const c = axis.length > 0 ? axis.charCodeAt(0) : 0;
    if (c == 0x78 || c == 0x58) return Vec3(1, 0, 0);
    if (c == 0x79 || c == 0x59) return Vec3(0, 1, 0);
    return Vec3(0, 0, 1);
}

// Snap values that are within `eps` of an integer (kills `-0` and 1e-8 noise).
export function snapSmall(v: f32, eps: f32): f32 {
    const r = roundF32(v);
    if (Mathf.abs(v - r) < eps) {
        return r == <f32>0.0 ? <f32>0.0 : r;
    }
    return v;
}

export function snapVec(v: Vec3, eps: f32): Vec3 {
    return Vec3(snapSmall(v.x, eps), snapSmall(v.y, eps), snapSmall(v.z, eps));
}

// What decompose returns: location, Euler XYZ, scale.
export struct Decomposed {
    location: Vec3 = Vec3(0, 0, 0);
    rotation: Vec3 = Vec3(0, 0, 0);
    scale: Vec3 = Vec3(1, 1, 1);
    constructor(location: Vec3, rotation: Vec3, scale: Vec3) {
        this.location = location;
        this.rotation = rotation;
        this.scale = scale;
    }
}

// Decompose an affine matrix into Blender-style location / Euler XYZ / scale.
export function decompose(m: Mat4): Decomposed {
    const srt = m.toScaleRotationTranslation();
    return Decomposed(srt.translation, eulerXyzFromQuat(srt.rotation), srt.scale);
}

// Compact, stable float formatting for messages and inspect output:
// 4 decimals (exact, round-half-even), trailing zeros trimmed,

// then a trailing '.', and "-0" becomes "0".
export function fmtF32(v: f32): string {
    let s = fixedF32(v, 4);
    let end = s.length;
    while (end > 0 && s.charCodeAt(end - 1) == 0x30) end--;
    while (end > 0 && s.charCodeAt(end - 1) == 0x2E) end--;
    s = s.substring(0, end);
    return s == "-0" ? "0" : s;
}

export function fmtVec3(v: Vec3): string {
    return fmtF32(v.x) + " " + fmtF32(v.y) + " " + fmtF32(v.z);
}
