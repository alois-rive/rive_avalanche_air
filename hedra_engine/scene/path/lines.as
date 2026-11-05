// Milestone 32: a curve drawn as lines, as Godot draws a Path3D (its
// editor gizmo, scene/3d/path_3d.cpp's debug mesh under Debug > Visible
// Paths, which the CLI's `render --paths` draws): a ribbon through samples
// every 0.1 m along the bake (sample_baked_with_rotation, cubic, with
// tilt) and, at every fourth sample, a fish bone, two short lines back
// from the curve to either side, which show which way it runs and how it
// leans.
//
// Lines are in render space (the frame's: Z up, ../space.as): `toRender`
// maps the curve's space there (SCENE_TO_MODEL times the Path3D's global
// transform). Each function writes into `out` from `at` (set in place
// where `out` has lines already, pushed past its end:
// ../interaction/lines.as's convention), so drawing again allocates
// nothing once `out` has grown; it returns the index after the last.
//
// The samples follow Godot exactly (f32, its order): sample_count =
// int(length / 0.1) + 2, spaced length / (sample_count - 1), so the ribbon
// ends on the curve's last baked point; a fish bone at samples 0, 4, 8, ...
// is p -> p + (side + forward - up * 0.3) * 0.06 and p -> p + (-side +
// forward - up * 0.3) * 0.06, side, up and forward the frame's columns 0, 1
// and 2. Godot's mesh keeps zero-length bones for the samples between; they
// draw nothing, so none is written here.

import { Mat4, Vec3, Vec4 } from "../../base/vecmath";
import { LineInstance } from "../../render/gpu/layouts";
import { Curve3D } from "./curve3d";

// Godot's colours, sRGB with alpha: debug/shapes/paths/geometry_color (a
// path drawn by --paths, and the editor's path gizmo, which takes the same
// setting), the editor's handle lines (path_thin_material), its tilt
// colour (editors/3d_gizmos/gizmo_colors/path_tilt) and its first, last
// and closing point handles.
export const DEBUG_PATH_COLOR: Vec4 = Vec4(0.1, 1.0, 0.7, 0.4);
export const DEBUG_PATH_WIDTH: f32 = 2;
export const EDITOR_PATH_HANDLE_LINE_COLOR: Vec4 = Vec4(0.6, 0.6, 0.6, 1.0);
export const EDITOR_PATH_TILT_COLOR: Vec4 = Vec4(1.0, 1.0, 0.4, 0.9);
export const EDITOR_PATH_FIRST_POINT_COLOR: Vec4 = Vec4(0.2, 1.0, 0.0, 1.0);
export const EDITOR_PATH_LAST_POINT_COLOR: Vec4 = Vec4(1.0, 0.2, 0.0, 1.0);
export const EDITOR_PATH_CLOSED_POINT_COLOR: Vec4 = Vec4(1.0, 0.8, 0.0, 1.0);
// Godot's editors/3d_gizmos/gizmo_settings/path3d_tilt_disk_size.
export const EDITOR_PATH_TILT_DISK_SIZE: f32 = 0.8;
// The ribbon's sample spacing, metres, and a fish bone every this many
// samples, as Godot's.
export const PATH_RIBBON_INTERVAL: f32 = 0.1;
export const PATH_FISH_BONE_EVERY: i32 = 4;

// How many lines pathLinesInto writes for `c` as it is now (0 for a curve
// shorter than CMP_EPSILON, as Godot draws nothing then).
export function pathLineCount(c: Curve3D): i32 {
    const n = sampleCount(c);
    if (n == 0) return 0;
    // The ribbon's segments, then two bones at every PATH_FISH_BONE_EVERY-th
    // sample from the first.
    return (n - 1) + 2 * ((n + PATH_FISH_BONE_EVERY - 1) / PATH_FISH_BONE_EVERY);
}

// The curve's ribbon and fish bones; `color` linear, `width` in pixels.
// Each sample's frame is made once (sampleBakedWithRotation, cubic, with
// tilt): its segment to the previous sample, then its bones.
export function pathLinesInto(c: Curve3D, toRender: Mat4, color: Vec4, width: f32, out: Array<LineInstance>,
    at: i32): i32 {
    const n = sampleCount(c);
    if (n == 0) return at;
    const interval = c.getBakedLength() / <f32>(n - 1);
    let k = at;
    let prev = Vec3(0, 0, 0);
    for (let i = 0; i < n; i++) {
        const r = c.sampleBakedWithRotation(<f32>i * interval, true, true);
        const p1 = r.wAxis.xyz();
        const p = toRender.transformPoint3(p1);
        if (i > 0) k = put(prev, p, color, width, out, k);
        if (i % PATH_FISH_BONE_EVERY == 0) {
            const side = r.xAxis.xyz(), up = r.yAxis.xyz(), forward = r.zAxis.xyz();
            // (Godot's order of operations, so its f32 roundings)
            const left = p1 + (side + forward - up * <f32>0.3) * <f32>0.06;
            const right = p1 + (-side + forward - up * <f32>0.3) * <f32>0.06;
            k = put(p, toRender.transformPoint3(left), color, width, out, k);
            k = put(p, toRender.transformPoint3(right), color, width, out, k);
        }
        prev = p;
    }
    return k;
}

// Godot's sample_count for the curve, or 0 when nothing is drawn: fewer
// than 2 points, or a baked length at most CMP_EPSILON.
function sampleCount(c: Curve3D): i32 {
    if (c.getPointCount() < 2) return 0;
    const length = c.getBakedLength();
    if (!(length > CMP_EPSILON)) return 0;
    return <i32>(length / PATH_RIBBON_INTERVAL) + 2;
}

// Godot's CMP_EPSILON (core/math/math_defs.h).
const CMP_EPSILON: f32 = 0.00001;

// One line, set in place or pushed past the end.
function put(a: Vec3, b: Vec3, color: Vec4, width: f32, out: Array<LineInstance>, at: i32): i32 {
    const line = LineInstance(a, b, color, width, 0);
    if (at < out.length) out[at] = line;
    else out.push(line);
    return at + 1;
}
