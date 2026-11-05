// Derived from Godot Engine 4.x (MIT); see THIRD_PARTY_NOTICES.md.
// Node transforms as a scene file states them (docs/formats/RSCN.md,
// "Transforms"): a node's local transform is a Transform3D, and the
// shorthands `position`, `rotation` (Euler angles in radians, order YXZ),
// `rotation_degrees` and `scale` each replace their part of it, as Godot's
// Node3D does when its properties are set.
//
// A declaration's properties are one layer. Within a layer `transform`
// applies first and then the shorthands in a fixed order (position,
// rotation, rotation_degrees, scale), whatever order the file lists them
// in, so that reordering properties never moves a node. Across layers (an
// instanced scene's own declaration, then the outer scene's override) a
// layer without `transform` edits the transform the earlier layers left:
// an outer `position` moves an instance without undoing its rotation.

import { Mat3, Mat4, Vec3, Vec4, atan2f, asinf, sinCosf } from "../../base/vecmath";
import { Property } from "../rscn/doc";
import { Value, ValueKind } from "../value";

// Godot's CMP_EPSILON: how close to +-1 the sine of the X angle must be
// for eulerYXZFromBasis to treat the basis as gimbal-locked.
const EULER_EPSILON: f32 = 0.00001;
const HALF_PI: f32 = 1.57079632679489661923;

// The rotation of Euler angles (radians) in Godot's default order YXZ:
// Ry * Rx * Rz, so a vector is turned about Z first, then X, then Y.
export function basisFromEulerYXZ(e: Vec3): Mat3 {
    const sx = sinCosf(e.x);
    const sy = sinCosf(e.y);
    const sz = sinCosf(e.z);
    // Columns of each elementary rotation (right-handed, counter-clockwise
    // seen from the positive axis).
    const ry = Mat3(Vec3(sy.c, 0, -sy.s), Vec3(0, 1, 0), Vec3(sy.s, 0, sy.c));
    const rx = Mat3(Vec3(1, 0, 0), Vec3(0, sx.c, sx.s), Vec3(0, -sx.s, sx.c));
    const rz = Mat3(Vec3(sz.c, sz.s, 0), Vec3(-sz.s, sz.c, 0), Vec3(0, 0, 1));
    return ry * rx * rz;
}

// Element (row, col) of a column-major basis.
function at(m: Mat3, row: i32, col: i32): f32 {
    const c = m.col(col);
    return row == 0 ? c.x : row == 1 ? c.y : c.z;
}

// The YXZ Euler angles (radians) of a rotation, as Godot's
// Basis::get_euler(EULER_ORDER_YXZ) computes them: X in [-pi/2, pi/2], a
// pure X rotation given as (x, 0, 0), and Z = 0 at the gimbal lock.
export function eulerYXZFromBasis(m: Mat3): Vec3 {
    const m12 = at(m, 1, 2);
    if (m12 < <f32>1 - EULER_EPSILON) {
        if (m12 > -(<f32>1 - EULER_EPSILON)) {
            if (at(m, 1, 0) == 0 && at(m, 0, 1) == 0 && at(m, 0, 2) == 0 && at(m, 2, 0) == 0 && at(m, 0, 0) == 1) {
                return Vec3(atan2f(-m12, at(m, 1, 1)), 0, 0);
            }
            return Vec3(asinf(-m12), atan2f(at(m, 0, 2), at(m, 2, 2)), atan2f(at(m, 1, 0), at(m, 1, 1)));
        }
        return Vec3(HALF_PI, atan2f(at(m, 0, 1), at(m, 0, 0)), 0);
    }
    return Vec3(-HALF_PI, -atan2f(at(m, 0, 1), at(m, 0, 0)), 0);
}

// The scale of a transform as Godot's Basis::get_scale gives it: the
// lengths of the basis columns, all three negated when the basis mirrors
// (negative determinant). Godot's sign of a zero determinant is 0, which
// would zero the whole scale of a flattened node and lose it for the next
// shorthand; a flat basis counts as unmirrored here instead.
export function signedScale(m: Mat4): Vec3 {
    const x = m.xAxis.truncate();
    const y = m.yAxis.truncate();
    const z = m.zAxis.truncate();
    const s = Vec3(x.length(), y.length(), z.length());
    return Mat3(x, y, z).determinant() < 0 ? -s : s;
}

// The basis of a transform with its scale divided out (the rotation, a
// proper one even when the basis mirrors, since the sign goes with the
// scale). A column of length 0 (a node flattened by a zero scale) still
// has its rotation in the other two, so it is rebuilt from them as their
// cross product (x = y × z, y = z × x, z = x × y): a later `scale` then
// keeps the rotation, as Godot's Node3D keeps it beside a zero scale. With
// one column left the basis is completed around it, and with none the
// rotation is the identity. (Exported for the script API of node.as.)
export function rotationOf(m: Mat4): Mat3 {
    const s = signedScale(m);
    const hasX = s.x != 0;
    const hasY = s.y != 0;
    const hasZ = s.z != 0;
    let x = hasX ? m.xAxis.truncate() / s.x : Vec3(1, 0, 0);
    let y = hasY ? m.yAxis.truncate() / s.y : Vec3(0, 1, 0);
    let z = hasZ ? m.zAxis.truncate() / s.z : Vec3(0, 0, 1);
    if (hasY && hasZ) {
        if (!hasX) x = y.cross(z).normalize();
    } else if (hasZ && hasX) {
        y = z.cross(x).normalize();
    } else if (hasX && hasY) {
        z = x.cross(y).normalize();
    } else if (hasX) {
        y = x.anyOrthonormalVector();
        z = x.cross(y);
    } else if (hasY) {
        z = y.anyOrthonormalVector();
        x = y.cross(z);
    } else if (hasZ) {
        x = z.anyOrthonormalVector();
        y = z.cross(x);
    }
    return Mat3(x, y, z);
}

// `m` with its basis replaced by `b`, the origin kept.
export function withBasis(m: Mat4, b: Mat3): Mat4 {
    return Mat4(b.xAxis.extend(0), b.yAxis.extend(0), b.zAxis.extend(0), m.wAxis);
}

// `b` with each column multiplied by its component of `s`.
export function scaled(b: Mat3, s: Vec3): Mat3 {
    return Mat3(b.xAxis * s.x, b.yAxis * s.y, b.zAxis * s.z);
}

// The last property of that name whose value has the kind wanted (a value
// of another kind is the validator's error, and changes nothing here).
function find(layer: Array<Property>, name: string, kind: ValueKind): Value? {
    for (let i = layer.length - 1; i >= 0; i--) {
        if (layer[i].name == name) return layer[i].value.kind == kind ? layer[i].value : null;
    }
    return null;
}

const DEG_TO_RAD: f64 = 3.14159265358979323846 / 180;

// Component k of a rotation in degrees, in radians (converted from the f64
// the file holds, so that 90 degrees is the nearest f32 to pi/2).
function radians(v: Value, k: i32): f32 {
    return k < v.n.length ? <f32>(v.n[k] * DEG_TO_RAD) : 0;
}

// The local transform after one layer of properties (see the header):
// `transform` replaces it, then position, rotation, rotation_degrees and
// scale each replace their part, in that order.
export function applyLayer(local: Mat4, layer: Array<Property>): Mat4 {
    let m = local;
    const t = find(layer, "transform", ValueKind.Transform3D);
    if (t != null) m = t.mat4();
    const p = find(layer, "position", ValueKind.Vector3);
    if (p != null) m = Mat4(m.xAxis, m.yAxis, m.zAxis, Vec4(p.at(0), p.at(1), p.at(2), 1));
    const r = find(layer, "rotation", ValueKind.Vector3);
    if (r != null) m = withBasis(m, scaled(basisFromEulerYXZ(r.vec3()), signedScale(m)));
    const rd = find(layer, "rotation_degrees", ValueKind.Vector3);
    if (rd != null) {
        const e = Vec3(radians(rd, 0), radians(rd, 1), radians(rd, 2));
        m = withBasis(m, scaled(basisFromEulerYXZ(e), signedScale(m)));
    }
    const s = find(layer, "scale", ValueKind.Vector3);
    if (s != null) m = withBasis(m, scaled(rotationOf(m), s.vec3()));
    return m;
}
