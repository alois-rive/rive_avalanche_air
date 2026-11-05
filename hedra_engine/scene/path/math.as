// Godot 4.4's f32 math for paths: the vector, Basis and Quaternion
// operations Curve3D's bake and sampling and PathFollow3D's placement use
// (core/math/math_funcs.h, vector3.h, basis.cpp, quaternion.cpp), written
// again over Hedra's value types so that a curve bakes to Godot's numbers
// (tests/path/godot_match_test.as holds it to Godot's own answers). Every
// function names the Godot one it follows and keeps its operation order: a
// sum is added in Godot's order and nothing is reassociated, because the
// bake's discrete choices (where a segment is cut, whether a loop is
// twisted) turn on the last bits.
//
// Godot's Basis stores rows; Hedra's Mat3 stores columns (xAxis is
// column 0). The helpers here take and return Mat3 as columns, as the rest
// of the engine does, and read rows where Godot does (`rows[i][j]` is
// column j's component i). Everything is a value: nothing allocates.
//
// The transcendentals are base/vecmath's (the same Apple libm results as
// Godot's macOS build, the platform tests/fixtures/path/godot_curves.json
// came from); sqrt, floor and fmod are exact everywhere. Godot's float
// math mixes in doubles in a few places (`1.0 - UNIT_EPSILON` in the bake,
// a sine of `(1.0 - weight) * omega` in the slerp): those stay f64 here.

import { Mat3, Quat, Vec3, acosf, asinf, atan2f, cosf, sinf } from "../../base/vecmath";

// core/math/math_defs.h. UNIT_EPSILON is the release builds' (Godot's
// PRECISE_MATH_CHECKS tightens it to 1e-5; no shipped build sets it).
export const CMP_EPSILON: f32 = 0.00001;
export const UNIT_EPSILON: f64 = 0.001;
// C's FLT_EPSILON (Curve3D::_find_interval's zero-length test).
export const FLT_EPSILON: f32 = 1.1920928955078125e-7;
const F32_PI: f32 = 3.14159265358979323846;

// --- scalars (math_funcs.h) ------------------------------------------------

// Math::is_zero_approx(float).
export function isZeroApproxF(s: f32): bool {
    return Mathf.abs(s) < CMP_EPSILON;
}

// Math::is_equal_approx(float, float): CMP_EPSILON scaled by |a|, never
// below CMP_EPSILON.
export function isEqualApproxF(a: f32, b: f32): bool {
    if (a == b) return true;
    let tolerance: f32 = CMP_EPSILON * Mathf.abs(a);
    if (tolerance < CMP_EPSILON) tolerance = CMP_EPSILON;
    return Mathf.abs(a - b) < tolerance;
}

// Math::lerp(float).
export function lerpF(from: f32, to: f32, weight: f32): f32 {
    return from + (to - from) * weight;
}

// Math::acos(float): clamped to its domain.
export function acosG(x: f32): f32 {
    return x < -1 ? F32_PI : (x > 1 ? <f32>0 : acosf(x));
}

// Math::asin(float): clamped to its domain.
export function asinG(x: f32): f32 {
    return x < -1 ? -F32_PI / 2 : (x > 1 ? F32_PI / 2 : asinf(x));
}

// typedefs.h SIGN: 0 for 0, else -1 or +1.
export function sign(x: f32): f32 {
    return x == 0 ? <f32>0 : (x < 0 ? <f32>-1 : <f32>1);
}

// Math::fposmod(float): the remainder with the divisor's sign.
export function fposmodF(x: f32, y: f32): f32 {
    let value: f32 = x % y;
    if ((value < 0 && y > 0) || (value > 0 && y < 0)) value += y;
    value += 0;
    return value;
}

// Math::cubic_interpolate(float), Catmull-Rom through pre, from, to, post.
function cubicF(from: f32, to: f32, pre: f32, post: f32, w: f32): f32 {
    return <f32>0.5 * ((from * 2) + (-pre + to) * w + (<f32>2 * pre - <f32>5 * from + <f32>4 * to - post) * (w * w)
        + (-pre + <f32>3 * from - <f32>3 * to + post) * (w * w * w));
}

// Math::bezier_interpolate(float).
function bezierF(start: f32, c1: f32, c2: f32, end: f32, t: f32): f32 {
    const omt: f32 = <f32>1 - t;
    const omt2 = omt * omt;
    const omt3 = omt2 * omt;
    const t2 = t * t;
    const t3 = t2 * t;
    return start * omt3 + c1 * omt2 * t * 3 + c2 * omt * t2 * 3 + end * t3;
}

// Math::bezier_derivative(float).
function bezierDerivF(start: f32, c1: f32, c2: f32, end: f32, t: f32): f32 {
    const omt: f32 = <f32>1 - t;
    const omt2 = omt * omt;
    const t2 = t * t;
    return (c1 - start) * 3 * omt2 + (c2 - c1) * 6 * omt * t + (end - c2) * 3 * t2;
}

// --- Vector3 ----------------------------------------------------------------

// Vector3::bezier_interpolate, per component.
export function bezierInterpolate(a: Vec3, c1: Vec3, c2: Vec3, b: Vec3, t: f32): Vec3 {
    return Vec3(bezierF(a.x, c1.x, c2.x, b.x, t), bezierF(a.y, c1.y, c2.y, b.y, t), bezierF(a.z, c1.z, c2.z, b.z, t));
}

// Vector3::bezier_derivative, per component.
export function bezierDerivative(a: Vec3, c1: Vec3, c2: Vec3, b: Vec3, t: f32): Vec3 {
    return Vec3(bezierDerivF(a.x, c1.x, c2.x, b.x, t), bezierDerivF(a.y, c1.y, c2.y, b.y, t),
        bezierDerivF(a.z, c1.z, c2.z, b.z, t));
}

// Vector3::cubic_interpolate: from this (`from`) to `to` with neighbours.
export function cubicInterpolate(from: Vec3, to: Vec3, pre: Vec3, post: Vec3, w: f32): Vec3 {
    return Vec3(cubicF(from.x, to.x, pre.x, post.x, w), cubicF(from.y, to.y, pre.y, post.y, w),
        cubicF(from.z, to.z, pre.z, post.z, w));
}

// Vector3::lerp.
export function lerpV(a: Vec3, b: Vec3, w: f32): Vec3 {
    return Vec3(lerpF(a.x, b.x, w), lerpF(a.y, b.y, w), lerpF(a.z, b.z, w));
}

// Vector3::length_squared.
export function lengthSquared(v: Vec3): f32 {
    const x2 = v.x * v.x;
    const y2 = v.y * v.y;
    const z2 = v.z * v.z;
    return x2 + y2 + z2;
}

// Vector3::length.
export function lengthOf(v: Vec3): f32 {
    return Mathf.sqrt(lengthSquared(v));
}

// Vector3::normalized: a zero vector stays zero (no NaN).
export function normalized(v: Vec3): Vec3 {
    const lsq = lengthSquared(v);
    if (lsq == 0) return Vec3(0, 0, 0);
    const len = Mathf.sqrt(lsq);
    return Vec3(v.x / len, v.y / len, v.z / len);
}

// Vector3::is_equal_approx, per component.
export function isEqualApprox(a: Vec3, b: Vec3): bool {
    return isEqualApproxF(a.x, b.x) && isEqualApproxF(a.y, b.y) && isEqualApproxF(a.z, b.z);
}

// Vector3::is_zero_approx, per component.
export function isZeroApproxV(v: Vec3): bool {
    return isZeroApproxF(v.x) && isZeroApproxF(v.y) && isZeroApproxF(v.z);
}

// Vector3::get_any_perpendicular: crossed with +x or +y, whichever is
// further from it.
export function anyPerpendicular(v: Vec3): Vec3 {
    if (isZeroApproxV(v)) return Vec3(0, 0, 0);
    const ax = Mathf.abs(v.x);
    const useX = ax <= Mathf.abs(v.y) && ax <= Mathf.abs(v.z);
    return normalized(v.cross(useX ? Vec3(1, 0, 0) : Vec3(0, 1, 0)));
}

// Curve3D::_calculate_tangent: the Bézier's direction at t, with its two
// corner cases (a handle on its end point at t = 0 or 1 has no derivative
// there: the chord's direction stands in).
export function calculateTangent(begin: Vec3, c1: Vec3, c2: Vec3, end: Vec3, t: f32): Vec3 {
    if (isZeroApproxF(t - <f32>0) && isEqualApprox(c1, begin)) return normalized(end - begin);
    if (isZeroApproxF(t - <f32>1) && isEqualApprox(c2, end)) return normalized(end - begin);
    return normalized(bezierDerivative(begin, c1, c2, end, t));
}

// --- Basis (rows as Godot holds them) ---------------------------------------

// Godot's Basis(xx, xy, xz, yx, ...) row-major constructor, as columns.
export function fromRows(r00: f32, r01: f32, r02: f32, r10: f32, r11: f32, r12: f32, r20: f32, r21: f32, r22: f32): Mat3 {
    return Mat3(Vec3(r00, r10, r20), Vec3(r01, r11, r21), Vec3(r02, r12, r22));
}

function row0(m: Mat3): Vec3 {
    return Vec3(m.xAxis.x, m.yAxis.x, m.zAxis.x);
}

function row1(m: Mat3): Vec3 {
    return Vec3(m.xAxis.y, m.yAxis.y, m.zAxis.y);
}

function row2(m: Mat3): Vec3 {
    return Vec3(m.xAxis.z, m.yAxis.z, m.zAxis.z);
}

// Basis::operator*: rows[i][j] = b.tdot_j(a.rows[i]), each a sum over
// b's column j in row order.
export function basisMul(a: Mat3, b: Mat3): Mat3 {
    const bx = b.xAxis;
    const by = b.yAxis;
    const bz = b.zAxis;
    const a0 = row0(a);
    const a1 = row1(a);
    const a2 = row2(a);
    return fromRows(
        bx.x * a0.x + bx.y * a0.y + bx.z * a0.z, by.x * a0.x + by.y * a0.y + by.z * a0.z, bz.x * a0.x + bz.y * a0.y + bz.z * a0.z,
        bx.x * a1.x + bx.y * a1.y + bx.z * a1.z, by.x * a1.x + by.y * a1.y + by.z * a1.z, bz.x * a1.x + bz.y * a1.y + bz.z * a1.z,
        bx.x * a2.x + bx.y * a2.y + bx.z * a2.z, by.x * a2.x + by.y * a2.y + by.z * a2.z, bz.x * a2.x + bz.y * a2.y + bz.z * a2.z,
    );
}

// Basis::xform: each row dotted with v.
export function basisXform(m: Mat3, v: Vec3): Vec3 {
    return Vec3(row0(m).dot(v), row1(m).dot(v), row2(m).dot(v));
}

// Basis::determinant, in Godot's order.
export function determinant(m: Mat3): f32 {
    const r0 = row0(m);
    const r1 = row1(m);
    const r2 = row2(m);
    return r0.x * (r1.y * r2.z - r2.y * r1.z) - r1.x * (r0.y * r2.z - r2.y * r0.z) + r2.x * (r0.y * r1.z - r1.y * r0.z);
}

// Basis::from_scale.
export function fromScale(s: Vec3): Mat3 {
    return Mat3(Vec3(s.x, 0, 0), Vec3(0, s.y, 0), Vec3(0, 0, s.z));
}

// Basis(axis, angle), Basis::set_axis_angle (Rodrigues, written out).
export function axisAngle(axis: Vec3, angle: f32): Mat3 {
    const sqx = axis.x * axis.x;
    const sqy = axis.y * axis.y;
    const sqz = axis.z * axis.z;
    const cosine = cosf(angle);
    const r00 = sqx + cosine * (<f32>1 - sqx);
    const r11 = sqy + cosine * (<f32>1 - sqy);
    const r22 = sqz + cosine * (<f32>1 - sqz);
    const sine = sinf(angle);
    const t: f32 = <f32>1 - cosine;
    let xyzt = axis.x * axis.y * t;
    let zyxs = axis.z * sine;
    const r01 = xyzt - zyxs;
    const r10 = xyzt + zyxs;
    xyzt = axis.x * axis.z * t;
    zyxs = axis.y * sine;
    const r02 = xyzt + zyxs;
    const r20 = xyzt - zyxs;
    xyzt = axis.y * axis.z * t;
    zyxs = axis.x * sine;
    const r12 = xyzt - zyxs;
    const r21 = xyzt + zyxs;
    return fromRows(r00, r01, r02, r10, r11, r12, r20, r21, r22);
}

// Basis::looking_at(target, up), use_model_front false: -z towards the
// target, y as near `up` as it can be (any perpendicular of `up` when they
// are colinear, where Godot warns).
export function lookingAt(target: Vec3, up: Vec3): Mat3 {
    const vz = -normalized(target);
    let vx = up.cross(vz);
    if (isZeroApproxV(vx)) vx = anyPerpendicular(up);
    vx = normalized(vx);
    const vy = vz.cross(vx);
    return Mat3(vx, vy, vz);
}

// Basis::rotate_to_align: `m` turned (premultiplied) by the rotation taking
// direction `from` to `to`, unchanged when they are colinear.
export function rotateToAlign(m: Mat3, from: Vec3, to: Vec3): Mat3 {
    const axis = normalized(from.cross(to));
    if (lengthSquared(axis) == 0) return m;
    let dot = from.dot(to);
    dot = dot < -1 ? <f32>-1 : (dot > 1 ? <f32>1 : dot);
    return basisMul(axisAngle(axis, acosG(dot)), m);
}

// Basis::orthonormalized: Gram-Schmidt on the columns, x first.
export function orthonormalized(m: Mat3): Mat3 {
    const x = normalized(m.xAxis);
    let y = m.yAxis - x * x.dot(m.yAxis);
    y = normalized(y);
    let z = m.zAxis - x * x.dot(m.zAxis) - y * y.dot(m.zAxis);
    z = normalized(z);
    return Mat3(x, y, z);
}

// Basis::get_quaternion (also from an unnormalised basis).
export function basisToQuat(m: Mat3): Quat {
    const r0 = row0(m);
    const r1 = row1(m);
    const r2 = row2(m);
    const trace = r0.x + r1.y + r2.z;
    if (trace > 0) {
        let s = Mathf.sqrt(trace + <f32>1);
        const w = s * <f32>0.5;
        s = <f32>0.5 / s;
        return Quat((r2.y - r1.z) * s, (r0.z - r2.x) * s, (r1.x - r0.y) * s, w);
    }
    // The largest diagonal term's axis i, then j and k after it.
    const i = r0.x < r1.y ? (r1.y < r2.z ? 2 : 1) : (r0.x < r2.z ? 2 : 0);
    const j = (i + 1) % 3;
    const k = (i + 2) % 3;
    let s = Mathf.sqrt(at(m, i, i) - at(m, j, j) - at(m, k, k) + <f32>1);
    const ti = s * <f32>0.5;
    s = <f32>0.5 / s;
    const w = (at(m, k, j) - at(m, j, k)) * s;
    const tj = (at(m, j, i) + at(m, i, j)) * s;
    const tk = (at(m, k, i) + at(m, i, k)) * s;
    let x: f32 = 0;
    let y: f32 = 0;
    let z: f32 = 0;
    if (i == 0) { x = ti; y = tj; z = tk; }
    else if (i == 1) { y = ti; z = tj; x = tk; }
    else { z = ti; x = tj; y = tk; }
    return Quat(x, y, z, w);
}

// Godot's rows[r][c].
function at(m: Mat3, r: i32, c: i32): f32 {
    const col = c == 0 ? m.xAxis : (c == 1 ? m.yAxis : m.zAxis);
    return r == 0 ? col.x : (r == 1 ? col.y : col.z);
}

// Basis(Quaternion), Basis::set_quaternion.
export function quatToBasis(q: Quat): Mat3 {
    const d = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w;
    const s: f32 = <f32>2 / d;
    const xs = q.x * s;
    const ys = q.y * s;
    const zs = q.z * s;
    const wx = q.w * xs;
    const wy = q.w * ys;
    const wz = q.w * zs;
    const xx = q.x * xs;
    const xy = q.x * ys;
    const xz = q.x * zs;
    const yy = q.y * ys;
    const yz = q.y * zs;
    const zz = q.z * zs;
    return fromRows(<f32>1 - (yy + zz), xy - wz, xz + wy,
        xy + wz, <f32>1 - (xx + zz), yz - wx,
        xz - wy, yz + wx, <f32>1 - (xx + yy));
}

// Quaternion::slerp: the shorter way round, linear when the two are within
// CMP_EPSILON. (Godot takes the first sine of a double.)
export function quatSlerp(a: Quat, b: Quat, weight: f32): Quat {
    let cosom = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    let to1 = b;
    if (cosom < 0) {
        cosom = -cosom;
        to1 = Quat(-b.x, -b.y, -b.z, -b.w);
    }
    let scale0: f32;
    let scale1: f32;
    if ((<f32>1 - cosom) > CMP_EPSILON) {
        const omega = acosG(cosom);
        const sinom = sinf(omega);
        scale0 = <f32>(Math.sin((1.0 - <f64>weight) * <f64>omega) / <f64>sinom);
        scale1 = sinf(weight * omega) / sinom;
    } else {
        scale0 = <f32>1 - weight;
        scale1 = weight;
    }
    return Quat(scale0 * a.x + scale1 * to1.x, scale0 * a.y + scale1 * to1.y, scale0 * a.z + scale1 * to1.z,
        scale0 * a.w + scale1 * to1.w);
}

// Basis::slerp: the rotations slerped through quaternions, each row scaled
// by its lerped length.
export function basisSlerp(a: Mat3, b: Mat3, weight: f32): Mat3 {
    const q = quatSlerp(basisToQuat(a), basisToQuat(b), weight);
    const m = quatToBasis(q);
    const s0 = lerpF(lengthOf(row0(a)), lengthOf(row0(b)), weight);
    const s1 = lerpF(lengthOf(row1(a)), lengthOf(row1(b)), weight);
    const s2 = lerpF(lengthOf(row2(a)), lengthOf(row2(b)), weight);
    const r0 = row0(m) * s0;
    const r1 = row1(m) * s1;
    const r2 = row2(m) * s2;
    return fromRows(r0.x, r0.y, r0.z, r1.x, r1.y, r1.z, r2.x, r2.y, r2.z);
}

// Basis::get_euler(EulerOrder::YXZ): (x, y, z) angles with the rotation
// Ry * Rx * Rz. (Godot's own `atan2`/`asin` here are the float ones.)
export function eulerYXZ(m: Mat3): Vec3 {
    const epsilon: f32 = 0.00000025;
    const m12 = m.zAxis.y;
    if (m12 < <f32>1 - epsilon) {
        if (m12 > -(<f32>1 - epsilon)) {
            // A pure X rotation: its simplest form.
            if (m.xAxis.y == 0 && m.yAxis.x == 0 && m.zAxis.x == 0 && m.xAxis.z == 0 && m.xAxis.x == 1) {
                return Vec3(atan2f(-m12, m.yAxis.y), 0, 0);
            }
            return Vec3(asinf(-m12), atan2f(m.zAxis.x, m.zAxis.z), atan2f(m.xAxis.y, m.yAxis.y));
        }
        return Vec3(F32_PI * <f32>0.5, atan2f(m.yAxis.x, m.xAxis.x), 0);
    }
    return Vec3(-F32_PI * <f32>0.5, -atan2f(m.yAxis.x, m.xAxis.x), 0);
}

// Basis::get_euler_normalized(YXZ): the angles of the orthonormalised
// basis, a mirrored one flipped first (scale(-1, -1, -1)).
export function eulerNormalizedYXZ(m: Mat3): Vec3 {
    let o = orthonormalized(m);
    if (determinant(o) < 0) o = Mat3(-o.xAxis, -o.yAxis, -o.zAxis);
    return eulerYXZ(o);
}

// Basis::from_euler(e, YXZ), Basis::set_euler: ymat * xmat * zmat.
export function fromEulerYXZ(e: Vec3): Mat3 {
    let c = cosf(e.x);
    let s = sinf(e.x);
    const xmat = fromRows(1, 0, 0, 0, c, -s, 0, s, c);
    c = cosf(e.y);
    s = sinf(e.y);
    const ymat = fromRows(c, 0, s, 0, 1, 0, -s, 0, c);
    c = cosf(e.z);
    s = sinf(e.z);
    const zmat = fromRows(c, -s, 0, s, c, 0, 0, 0, 1);
    return basisMul(basisMul(ymat, xmat), zmat);
}

// Quaternion(v0, v1).get_angle(): the angle of the shortest arc from v0 to
// v1 (0 for the same direction, pi for opposite ones).
export function quatAngle(v0: Vec3, v1: Vec3): f32 {
    const almostOne: f32 = <f32>1 - CMP_EPSILON;
    const n0 = normalized(v0);
    const n1 = normalized(v1);
    const d = n0.dot(n1);
    let w: f32 = 1;
    if (Mathf.abs(d) > almostOne) {
        if (d < 0) w = 0;
    } else {
        const s = Mathf.sqrt((<f32>1 + d) * <f32>2);
        w = s * <f32>0.5;
    }
    return <f32>2 * acosG(w);
}
