// A shape drawn as lines (milestone 31): its wire frame for the editor's
// gizmos (editor/src/scene/shape_gizmo.as), `the CLI render
// --shapes` and Play's --shapes (debug_draw.as), Godot's Visible Collision
// Shapes. A box's 12 edges; a sphere's three great circles; a capsule's
// two cap circles and four lines along y and its caps' half circles in the
// xy and zy planes; a cylinder's two circles and four lines along y; a
// convex hull's edges; a concave shape's triangles' edges, each once. A
// circle has SHAPE_CIRCLE_SEGMENTS lines.
//
// Lines are in render space (the frame's: Z up, ../space.as): `toRender`
// maps the shape's space there (SCENE_TO_MODEL times the
// CollisionShape3D's global transform). Each function writes its lines
// into `out` from `at` (set in place where `out` has lines already, pushed
// past its end, as the probe gizmo does), so a frame planned again
// allocates nothing; it returns the index after the last.
//
// What is drawn is the shape's fields as they are, a degenerate shape too
// (a box of size 0 on an axis is drawn flat: the gizmo shows what the
// handles are editing).

import { Mat4, Vec3, Vec4 } from "../../base/vecmath";
import { LineInstance } from "../../render/gpu/layouts";
import {
    BoxShape3D, CapsuleShape3D, ConcavePolygonShape3D, ConvexPolygonShape3D, CylinderShape3D, SHAPE_BOX,
    SHAPE_CAPSULE, SHAPE_CONCAVE, SHAPE_CONVEX, SHAPE_CYLINDER, SHAPE_SPHERE, Shape3D, SphereShape3D,
} from "../resource/types";
import { concaveEdgesOf, convexHullOf } from "./prepared";

export const SHAPE_CIRCLE_SEGMENTS: i32 = 32;

// Godot's colours, sRGB with alpha: debug/shapes/collision/shape_color (a
// shape drawn by --shapes), contact_color (a ray that hits), and the
// editor's 3D gizmo colour of shapes (editors/3d_gizmos/gizmo_colors/shape).
export const DEBUG_SHAPE_COLOR: Vec4 = Vec4(0.0, 0.6, 0.7, 0.42);
export const DEBUG_CONTACT_COLOR: Vec4 = Vec4(1.0, 0.2, 0.1, 0.8);
export const EDITOR_SHAPE_COLOR: Vec4 = Vec4(0.5, 0.7, 1.0, 1.0);

// How many lines shapeLinesInto writes for `s` as it is now.
export function shapeLineCount(s: Shape3D): i32 {
    switch (s.kind()) {
        case SHAPE_BOX:
            return 12;
        case SHAPE_SPHERE:
            return 3 * SHAPE_CIRCLE_SEGMENTS;
        case SHAPE_CAPSULE:
            return 2 * SHAPE_CIRCLE_SEGMENTS + 4 + 4 * (SHAPE_CIRCLE_SEGMENTS / 2);
        case SHAPE_CYLINDER:
            return 2 * SHAPE_CIRCLE_SEGMENTS + 4;
        case SHAPE_CONVEX:
            return convexHullOf(<ConvexPolygonShape3D>s).edges.length / 2;
        case SHAPE_CONCAVE:
            return concaveEdgesOf(<ConcavePolygonShape3D>s).length / 6;
    }
    return 0;
}

// The shape's lines (see the header); `color` linear, `width` in pixels.
export function shapeLinesInto(s: Shape3D, toRender: Mat4, color: Vec4, width: f32, out: Array<LineInstance>,
    at: i32): i32 {
    let k = at;
    switch (s.kind()) {
        case SHAPE_BOX: {
            const size = (<BoxShape3D>s).size;
            const hx = <f64>size.x * 0.5, hy = <f64>size.y * 0.5, hz = <f64>size.z * 0.5;
            for (let e = 0; e < 12; e++) {
                const c0 = BOX_EDGES[e * 2], c1 = BOX_EDGES[e * 2 + 1];
                k = lineInto(toRender, (c0 & 1) != 0 ? hx : -hx, (c0 & 2) != 0 ? hy : -hy, (c0 & 4) != 0 ? hz : -hz,
                    (c1 & 1) != 0 ? hx : -hx, (c1 & 2) != 0 ? hy : -hy, (c1 & 4) != 0 ? hz : -hz, color, width, out, k);
            }
            break;
        }
        case SHAPE_SPHERE: {
            const r = (<SphereShape3D>s).radius;
            k = arcInto(toRender, 0, 0, 0, AXIS_X, AXIS_Y, r, 0, SHAPE_CIRCLE_SEGMENTS, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            k = arcInto(toRender, 0, 0, 0, AXIS_Y, AXIS_Z, r, 0, SHAPE_CIRCLE_SEGMENTS, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            k = arcInto(toRender, 0, 0, 0, AXIS_Z, AXIS_X, r, 0, SHAPE_CIRCLE_SEGMENTS, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            break;
        }
        case SHAPE_CAPSULE: {
            const c = <CapsuleShape3D>s;
            const r = c.effectiveRadius(), hs = c.halfSegment();
            const half = SHAPE_CIRCLE_SEGMENTS / 2;
            k = arcInto(toRender, 0, hs, 0, AXIS_Z, AXIS_X, r, 0, SHAPE_CIRCLE_SEGMENTS, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            k = arcInto(toRender, 0, -hs, 0, AXIS_Z, AXIS_X, r, 0, SHAPE_CIRCLE_SEGMENTS, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            k = sideLinesInto(toRender, r, hs, color, width, out, k);
            // The caps' half circles: over the top from +x (+z) to -x (-z),
            // and under the bottom back.
            k = arcInto(toRender, 0, hs, 0, AXIS_X, AXIS_Y, r, 0, half, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            k = arcInto(toRender, 0, -hs, 0, AXIS_X, AXIS_Y, r, half, half, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            k = arcInto(toRender, 0, hs, 0, AXIS_Z, AXIS_Y, r, 0, half, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            k = arcInto(toRender, 0, -hs, 0, AXIS_Z, AXIS_Y, r, half, half, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            break;
        }
        case SHAPE_CYLINDER: {
            const c = <CylinderShape3D>s;
            const r = c.radius, h = c.height * 0.5;
            k = arcInto(toRender, 0, h, 0, AXIS_Z, AXIS_X, r, 0, SHAPE_CIRCLE_SEGMENTS, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            k = arcInto(toRender, 0, -h, 0, AXIS_Z, AXIS_X, r, 0, SHAPE_CIRCLE_SEGMENTS, SHAPE_CIRCLE_SEGMENTS, color, width, out, k);
            k = sideLinesInto(toRender, r, h, color, width, out, k);
            break;
        }
        case SHAPE_CONVEX: {
            const hull = convexHullOf(<ConvexPolygonShape3D>s);
            const p = hull.points, e = hull.edges;
            for (let i = 0; i + 1 < e.length; i += 2) {
                const a = e[i] * 3, b = e[i + 1] * 3;
                k = lineInto(toRender, p[a], p[a + 1], p[a + 2], p[b], p[b + 1], p[b + 2], color, width, out, k);
            }
            break;
        }
        case SHAPE_CONCAVE: {
            const e = concaveEdgesOf(<ConcavePolygonShape3D>s);
            for (let i = 0; i + 5 < e.length; i += 6) {
                k = lineInto(toRender, e[i], e[i + 1], e[i + 2], e[i + 3], e[i + 4], e[i + 5], color, width, out, k);
            }
            break;
        }
    }
    return k;
}

// The box's corners by bits (x 1, y 2, z 4: set is +half) and its 12
// edges as corner pairs.
const BOX_EDGES: StaticArray<i32> = [
    0, 1, 2, 3, 4, 5, 6, 7,
    0, 2, 1, 3, 4, 6, 5, 7,
    0, 4, 1, 5, 2, 6, 3, 7,
];

const AXIS_X: i32 = 0;
const AXIS_Y: i32 = 1;
const AXIS_Z: i32 = 2;

// One line between two points of the shape's space.
function lineInto(toRender: Mat4, ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64, color: Vec4, width: f32,
    out: Array<LineInstance>, at: i32): i32 {
    const a = toRender.transformPoint3(Vec3(<f32>ax, <f32>ay, <f32>az));
    const b = toRender.transformPoint3(Vec3(<f32>bx, <f32>by, <f32>bz));
    const line = LineInstance(a, b, color, width, 0);
    if (at < out.length) out[at] = line;
    else out.push(line);
    return at + 1;
}

// `count` segments of the circle of radius r about (cx, cy, cz) in the
// plane of axes u and v (the point at angle a is c + r (cos a u + sin a
// v)), from segment `first` of a circle cut into `of` segments.
function arcInto(toRender: Mat4, cx: f64, cy: f64, cz: f64, u: i32, v: i32, r: f64, first: i32, count: i32, of: i32,
    color: Vec4, width: f32, out: Array<LineInstance>, at: i32): i32 {
    let k = at;
    const step = 2.0 * Math.PI / <f64>of;
    let pc = Math.cos(<f64>first * step) * r, ps = Math.sin(<f64>first * step) * r;
    for (let i = first + 1; i <= first + count; i++) {
        // The last point of a whole circle is its first exactly.
        const j = i % of;
        const qc = Math.cos(<f64>j * step) * r, qs = Math.sin(<f64>j * step) * r;
        k = lineInto(toRender,
            cx + (u == AXIS_X ? pc : 0) + (v == AXIS_X ? ps : 0),
            cy + (u == AXIS_Y ? pc : 0) + (v == AXIS_Y ? ps : 0),
            cz + (u == AXIS_Z ? pc : 0) + (v == AXIS_Z ? ps : 0),
            cx + (u == AXIS_X ? qc : 0) + (v == AXIS_X ? qs : 0),
            cy + (u == AXIS_Y ? qc : 0) + (v == AXIS_Y ? qs : 0),
            cz + (u == AXIS_Z ? qc : 0) + (v == AXIS_Z ? qs : 0),
            color, width, out, k);
        pc = qc;
        ps = qs;
    }
    return k;
}

// The four lines along y at +x, -x, +z and -z, radius r, from -h to h.
function sideLinesInto(toRender: Mat4, r: f64, h: f64, color: Vec4, width: f32, out: Array<LineInstance>, at: i32): i32 {
    let k = at;
    k = lineInto(toRender, r, -h, 0, r, h, 0, color, width, out, k);
    k = lineInto(toRender, -r, -h, 0, -r, h, 0, color, width, out, k);
    k = lineInto(toRender, 0, -h, r, 0, h, r, color, width, out, k);
    k = lineInto(toRender, 0, -h, -r, 0, h, -r, color, width, out, k);
    return k;
}

// One line from `a` to `b` (render space): a RayCast3D drawn, and its hit.
export function segmentInto(a: Vec3, b: Vec3, color: Vec4, width: f32, out: Array<LineInstance>, at: i32): i32 {
    const line = LineInstance(a, b, color, width, 0);
    if (at < out.length) out[at] = line;
    else out.push(line);
    return at + 1;
}
