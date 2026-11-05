// Axis conversion in the style of Blender's
// `axis_conversion`. Hedra is Y-forward, Z-up (Blender's convention); the
// exporter rotates into the requested frame. glTF wants -Z forward, Y up.

import {
    Vec3, Mat3, Mat4, MAT4_ZERO, VEC3_X, VEC3_Y, VEC3_Z, VEC3_NEG_X, VEC3_NEG_Y, VEC3_NEG_Z,
} from "../../../base/vecmath";
import { toAsciiUppercase } from "../../../base/util";

export enum Axis {
    X = 0,
    Y = 1,
    Z = 2,
    NegX = 3,
    NegY = 4,
    NegZ = 5,
}

// Axis::parse (case-insensitive: "-z" is -Z). The Axis, or -1 for None.
export function axisParse(s: string): i32 {
    const u = toAsciiUppercase(s);
    if (u == "X") return Axis.X;
    if (u == "Y") return Axis.Y;
    if (u == "Z") return Axis.Z;
    if (u == "-X") return Axis.NegX;
    if (u == "-Y") return Axis.NegY;
    if (u == "-Z") return Axis.NegZ;
    return -1;
}

// Axis::vector.
export function axisVector(a: Axis): Vec3 {
    switch (a) {
        case Axis.X: return VEC3_X;
        case Axis.Y: return VEC3_Y;
        case Axis.Z: return VEC3_Z;
        case Axis.NegX: return VEC3_NEG_X;
        case Axis.NegY: return VEC3_NEG_Y;
        default: return VEC3_NEG_Z;
    }
}

// Axis::label.
export function axisLabel(a: Axis): string {
    switch (a) {
        case Axis.X: return "X";
        case Axis.Y: return "Y";
        case Axis.Z: return "Z";
        case Axis.NegX: return "-X";
        case Axis.NegY: return "-Y";
        default: return "-Z";
    }
}

// Derived Debug of Axis.
export function axisDebug(a: Axis): string {
    switch (a) {
        case Axis.X: return "X";
        case Axis.Y: return "Y";
        case Axis.Z: return "Z";
        case Axis.NegX: return "NegX";
        case Axis.NegY: return "NegY";
        default: return "NegZ";
    }
}

// A Mat4 that may be absent (a struct cannot be nullable).
export class OptionMat4 {
    isSome: bool;
    value: Mat4;

    constructor(isSome: bool, value: Mat4) {
        this.isSome = isSome;
        this.value = value;
    }
}

// Rotation taking Hedra's frame (forward +Y, up +Z) to one whose forward
// and up are the given axes. None (`isSome == false`) when the axes are not
// perpendicular.
export function conversion(forward: Axis, up: Axis): OptionMat4 {
    const f = axisVector(forward);
    const u = axisVector(up);
    if (Mathf.abs(f.dot(u)) > <f32>1e-6) {
        return new OptionMat4(false, MAT4_ZERO);
    }
    // Target basis expressed in target coordinates: right = forward x up
    // keeps the frame right-handed (Blender: X = Y x Z).
    const r = f.cross(u);
    // Columns map source X, Y, Z to target right, forward, up.
    const m = Mat3.fromCols(r, f, u);
    return new OptionMat4(true, Mat4.fromMat3(m));
}
