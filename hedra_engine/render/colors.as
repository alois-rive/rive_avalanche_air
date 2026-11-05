// Colours every view draws with: the sRGB-to-linear helper and Blender's
// axis theme colours, which the floor axes (Hedra's overlay.as) and the
// axis gizmo (composite.as) share.

import { Vec3, Vec4 } from "../base/vecmath";
import { srgbToLinear } from "./image";

// sRGB color to linear, with alpha.
export function lin(rgb: Vec3, a: f32): Vec4 {
    return Vec4(srgbToLinear(rgb.x), srgbToLinear(rgb.y), srgbToLinear(rgb.z), a);
}

// Blender's theme colors (sRGB).
export const AXIS_X: Vec3 = Vec3(1.0, 0.2, 0.32);
export const AXIS_Y: Vec3 = Vec3(0.55, 0.86, 0.0);
export const AXIS_Z: Vec3 = Vec3(0.16, 0.56, 1.0);
