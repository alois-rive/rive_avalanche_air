// Cameras, Blender's numpad view presets and bounding-box framing.
//
// Conventions: Z up, right-handed. Azimuth is measured around Z from the
// front view (camera on -Y looking along +Y) towards +X, so 90 degrees is
// the right view; elevation is degrees above the XY plane.

import {
    Mat4, Vec2, Vec3, Vec4, VEC3_X, VEC3_Y, VEC3_Z, VEC3_NEG_Y, VEC3_ZERO,
    camera, toDegrees, toRadians,
} from "../base/vecmath";
import { clampF32, maxF32, minF32, toAsciiLowercase } from "../base/util";
import { appleAtanf, appleSinf, appleTanf, appleSincosf } from "../base/libm";

// Blender's default startup view: the camera sits front-right-above at
// roughly (7.4, -6.9, 5.0), which is this azimuth / elevation.
export const ISO_AZIMUTH: f32 = 46.7;
export const ISO_ELEVATION: f32 = 26.1;
// Blender's 50mm lens on a 36mm sensor, measured across the larger side.
export const DEFAULT_FOV: f32 = 39.6;
// Fraction of extra room around the framed bounds.
export const FRAME_MARGIN: f32 = 1.12;

export enum ViewPreset {
    Iso,
    Front,
    Back,
    Left,
    Right,
    Top,
    Bottom,
}

// Every preset, in declaration order.
export const VIEW_PRESET_ALL: StaticArray<ViewPreset> = [
    ViewPreset.Iso,
    ViewPreset.Front,
    ViewPreset.Back,
    ViewPreset.Left,
    ViewPreset.Right,
    ViewPreset.Top,
    ViewPreset.Bottom,
];

export namespace ViewPreset {
    // The preset a name selects, or -1 for none.
    export function parse(s: string): i32 {
        const l = toAsciiLowercase(s);
        if (l == "iso" || l == "user" || l == "persp") return ViewPreset.Iso;
        if (l == "front") return ViewPreset.Front;
        if (l == "back") return ViewPreset.Back;
        if (l == "left") return ViewPreset.Left;
        if (l == "right") return ViewPreset.Right;
        if (l == "top") return ViewPreset.Top;
        if (l == "bottom") return ViewPreset.Bottom;
        return -1;
    }

    export function name(p: ViewPreset): string {
        switch (p) {
            case ViewPreset.Iso: return "iso";
            case ViewPreset.Front: return "front";
            case ViewPreset.Back: return "back";
            case ViewPreset.Left: return "left";
            case ViewPreset.Right: return "right";
            case ViewPreset.Top: return "top";
            default: return "bottom";
        }
    }

    // (azimuth, elevation) in degrees, Blender numpad conventions.
    export function angles(p: ViewPreset): Vec2 {
        switch (p) {
            case ViewPreset.Iso: return Vec2(ISO_AZIMUTH, ISO_ELEVATION);
            case ViewPreset.Front: return Vec2(0.0, 0.0);
            case ViewPreset.Back: return Vec2(180.0, 0.0);
            case ViewPreset.Right: return Vec2(90.0, 0.0);
            case ViewPreset.Left: return Vec2(-90.0, 0.0);
            case ViewPreset.Top: return Vec2(0.0, 90.0);
            default: return Vec2(0.0, -90.0);
        }
    }

    // Axis views are orthographic, like Blender's auto-perspective.
    export function isOrtho(p: ViewPreset): bool {
        return p != ViewPreset.Iso;
    }
}

// Unit vector from the target towards the eye.
export function orbitDirection(azimuthDeg: f32, elevationDeg: f32): Vec3 {
    // Apple libm `__sincosf_stret`, so the orbit is reproducible bit for bit.
    const a = appleSincosf(toRadians(azimuthDeg));
    const sa = a.s;
    const ca = a.c;
    const e = appleSincosf(toRadians(elevationDeg));
    const se = e.s;
    const ce = e.c;
    return Vec3(sa * ce, -ca * ce, se).normalize();
}

// Up vector for a view direction: Z, except straight down / up where
// Blender uses +Y (top) and -Y (bottom) so X still points right.
export function upFor(elevationDeg: f32): Vec3 {
    if (elevationDeg > 89.0) {
        return VEC3_Y;
    } else if (elevationDeg < -89.0) {
        return VEC3_NEG_Y;
    } else {
        return VEC3_Z;
    }
}

export enum ProjectionKind {
    // `value` is the vertical field of view in degrees (`fov_y_deg`).
    Perspective,
    // `value` is half of the visible height in world units (`half_height`).
    Orthographic,
}

// Perspective (vertical fov in degrees) or orthographic (half height): the
// kind and its one payload.
export struct Projection {
    kind: ProjectionKind = ProjectionKind.Perspective;
    value: f32 = 0;

    constructor(kind: ProjectionKind, value: f32) {
        this.kind = kind;
        this.value = value;
    }

    operator==(a: Projection, b: Projection): bool { return a.kind == b.kind && a.value == b.value; }
    readonly hash(): u32 { return (<u32>this.kind * 31) ^ reinterpret<u32>(this.value == 0 ? <f32>0 : this.value); }
}

export namespace Projection {
    export function perspective(fovYDeg: f32): Projection {
        return Projection(ProjectionKind.Perspective, fovYDeg);
    }
    export function orthographic(halfHeight: f32): Projection {
        return Projection(ProjectionKind.Orthographic, halfHeight);
    }
}

// Axis-aligned world bounds (a value struct, copied on assignment).
export struct Bounds {
    min: Vec3 = Vec3(0, 0, 0);
    max: Vec3 = Vec3(0, 0, 0);

    constructor(min: Vec3, max: Vec3) {
        this.min = min;
        this.max = max;
    }

    operator==(a: Bounds, b: Bounds): bool { return a.min == b.min && a.max == b.max; }
    readonly hash(): u32 { return this.min.hash() * 31 + this.max.hash(); }

    readonly union(other: Bounds): Bounds {
        return Bounds(this.min.min(other.min), this.max.max(other.max));
    }

    readonly include(p: Vec3): Bounds {
        return Bounds(this.min.min(p), this.max.max(p));
    }

    // Bounds of this box after `m`, from its 8 transformed corners: the
    // min and max of `m.transformPoint3(c)` over `corners()`, number for
    // number. Worked out in scalars, each corner's sum in transformPoint3's
    // order with the products it shares with other corners made once, so a
    // plan of thousands of items allocates nothing here and spends a third
    // of the time (milestone 13).
    readonly transformed(m: Mat4): Bounds {
        const lo = this.min;
        const hi = this.max;
        const x = m.xAxis;
        const y = m.yAxis;
        const z = m.zAxis;
        const w = m.wAxis;
        return Bounds(
            Vec3(axisMin(x.x, y.x, z.x, w.x, lo, hi), axisMin(x.y, y.y, z.y, w.y, lo, hi),
                axisMin(x.z, y.z, z.z, w.z, lo, hi)),
            Vec3(axisMax(x.x, y.x, z.x, w.x, lo, hi), axisMax(x.y, y.y, z.y, w.y, lo, hi),
                axisMax(x.z, y.z, z.z, w.z, lo, hi)),
        );
    }

    // Corner `i` (0..7) of `corners()`, without the array: bit 0 picks max
    // x, bit 1 max y, bit 2 max z.
    readonly corner(i: i32): Vec3 {
        const a = this.min;
        const b = this.max;
        return Vec3((i & 1) != 0 ? b.x : a.x, (i & 2) != 0 ? b.y : a.y, (i & 4) != 0 ? b.z : a.z);
    }

    readonly corners(): Array<Vec3> {
        const a = this.min;
        const b = this.max;
        const out = new Array<Vec3>();
        out.push(Vec3(a.x, a.y, a.z));
        out.push(Vec3(b.x, a.y, a.z));
        out.push(Vec3(a.x, b.y, a.z));
        out.push(Vec3(b.x, b.y, a.z));
        out.push(Vec3(a.x, a.y, b.z));
        out.push(Vec3(b.x, a.y, b.z));
        out.push(Vec3(a.x, b.y, b.z));
        out.push(Vec3(b.x, b.y, b.z));
        return out;
    }

    readonly center(): Vec3 {
        return (this.min + this.max) * <f32>0.5;
    }

    // Radius of the bounding sphere, never zero (a point gets a 1-unit sphere).
    readonly radius(): f32 {
        const r = (this.max - this.min).length() * <f32>0.5;
        return r < <f32>1e-4 ? <f32>1.0 : r;
    }
}

// One component of `transformPoint3` at the 8 corners of (lo, hi), as
// transformPoint3 sums it: ((a * cx + ...) in the order x, y, z, then the
// translation. `axisMin` and `axisMax` are the least and greatest of the
// 8, taken in `corners()` order with Vec3.min's and max's comparisons (so
// a NaN or a signed zero comes out as it did from them).
function axisMin(a: f32, b: f32, c: f32, d: f32, lo: Vec3, hi: Vec3): f32 {
    const x0 = a * lo.x;
    const x1 = a * hi.x;
    const y0 = b * lo.y;
    const y1 = b * hi.y;
    const z0 = c * lo.z;
    const z1 = c * hi.z;
    const s00 = y0 + x0;
    const s10 = y0 + x1;
    const s01 = y1 + x0;
    const s11 = y1 + x1;
    let r = d + (z0 + s00);
    let v: f32 = 0;
    v = d + (z0 + s10);
    r = r < v ? r : v;
    v = d + (z0 + s01);
    r = r < v ? r : v;
    v = d + (z0 + s11);
    r = r < v ? r : v;
    v = d + (z1 + s00);
    r = r < v ? r : v;
    v = d + (z1 + s10);
    r = r < v ? r : v;
    v = d + (z1 + s01);
    r = r < v ? r : v;
    v = d + (z1 + s11);
    return r < v ? r : v;
}

function axisMax(a: f32, b: f32, c: f32, d: f32, lo: Vec3, hi: Vec3): f32 {
    const x0 = a * lo.x;
    const x1 = a * hi.x;
    const y0 = b * lo.y;
    const y1 = b * hi.y;
    const z0 = c * lo.z;
    const z1 = c * hi.z;
    const s00 = y0 + x0;
    const s10 = y0 + x1;
    const s01 = y1 + x0;
    const s11 = y1 + x1;
    let r = d + (z0 + s00);
    let v: f32 = 0;
    v = d + (z0 + s10);
    r = r > v ? r : v;
    v = d + (z0 + s01);
    r = r > v ? r : v;
    v = d + (z0 + s11);
    r = r > v ? r : v;
    v = d + (z1 + s00);
    r = r > v ? r : v;
    v = d + (z1 + s10);
    r = r > v ? r : v;
    v = d + (z1 + s01);
    r = r > v ? r : v;
    v = d + (z1 + s11);
    return r > v ? r : v;
}

// A boxed `Bounds`, for results that may be absent (a struct cannot be
// nullable or a `Result` payload).
export class BoundsBox {
    value: Bounds;
    constructor(value: Bounds) {
        this.value = value;
    }
}

export namespace Bounds {
    // The bounds of `points`: null for no points.
    export function fromPoints(points: Array<Vec3>): BoundsBox? {
        if (points.length == 0) return null;
        const first = points[0];
        let lo = first;
        let hi = first;
        for (let i = 1; i < points.length; i++) {
            const p = points[i];
            lo = lo.min(p);
            hi = hi.max(p);
        }
        return new BoundsBox(Bounds(lo, hi));
    }
}

// Everything needed to place a camera around some bounds.
export struct FramingRequest {
    azimuth: f32 = 0;
    elevation: f32 = 0;
    ortho: bool = false;
    // Field of view in degrees across the larger image side.
    fov: f32 = 0;
    aspect: f32 = 0;
    // Explicit eye distance instead of fitting, used when `hasDistance`.
    hasDistance: bool = false;
    distance: f32 = 0;
    // Fit the bounding sphere (stable across azimuths, used by turntables)
    // instead of the tighter projected-corner fit.
    sphereFit: bool = false;

    constructor(
        azimuth: f32, elevation: f32, ortho: bool, fov: f32, aspect: f32,
        hasDistance: bool, distance: f32, sphereFit: bool,
    ) {
        this.azimuth = azimuth;
        this.elevation = elevation;
        this.ortho = ortho;
        this.fov = fov;
        this.aspect = aspect;
        this.hasDistance = hasDistance;
        this.distance = distance;
        this.sphereFit = sphereFit;
    }
}

// A projected point: pixel x, pixel y (y down) and NDC depth, valid when
// `some`.
export struct Projected {
    some: bool = false;
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;

    constructor(some: bool, x: f32, y: f32, z: f32) {
        this.some = some;
        this.x = x;
        this.y = y;
        this.z = z;
    }
}

// A camera: a class, so copy with `clone()`.
export class Camera {
    eye: Vec3;
    target: Vec3;
    up: Vec3;
    projection: Projection;
    near: f32;
    far: f32;

    constructor(eye: Vec3, target: Vec3, up: Vec3, projection: Projection, near: f32, far: f32) {
        this.eye = eye;
        this.target = target;
        this.up = up;
        this.projection = projection;
        this.near = near;
        this.far = far;
    }

    clone(): Camera {
        return new Camera(this.eye, this.target, this.up, this.projection, this.near, this.far);
    }

    // Takes `o`'s pose and projection, allocating nothing (milestone 13:
    // the preview moves one frame's camera in place every frame).
    copyFrom(o: Camera): void {
        this.eye = o.eye;
        this.target = o.target;
        this.up = o.up;
        this.projection = o.projection;
        this.near = o.near;
        this.far = o.far;
    }

    equals(o: Camera): bool {
        return this.eye == o.eye && this.target == o.target && this.up == o.up
            && this.projection == o.projection && this.near == o.near && this.far == o.far;
    }

    // Frame `bounds` from the requested angle so that everything is in view.
    static frame(bounds: Bounds, req: FramingRequest): Camera {
        const target = bounds.center();
        const dir = orbitDirection(req.azimuth, req.elevation);
        const up = upFor(req.elevation);
        const radius = bounds.radius();
        const aspect: f32 = isFinite(req.aspect) && req.aspect > 0.0 ? req.aspect : <f32>1.0;
        // Camera basis: forward towards the target, right, true up.
        const forward = -dir;
        let right = forward.cross(up).normalizeOrZero();
        if (right == VEC3_ZERO) right = VEC3_X;
        const camUp = right.cross(forward).normalize();
        const fov = clampF32(req.fov, 1.0, 170.0);
        let fovX: f32;
        let fovY: f32;
        if (aspect >= 1.0) {
            const fy = <f32>2.0 * appleAtanf(appleTanf(toRadians(fov) * <f32>0.5) / aspect);
            fovX = toRadians(fov);
            fovY = fy;
        } else {
            const fx = <f32>2.0 * appleAtanf(appleTanf(toRadians(fov) * <f32>0.5) * aspect);
            fovX = fx;
            fovY = toRadians(fov);
        }
        // Extents of the corners in camera space, relative to the target.
        let maxX: f32 = 0.0;
        let maxY: f32 = 0.0;
        let needD: f32 = 0.0;
        const corners = bounds.corners();
        for (let i = 0; i < 8; i++) {
            const rel = corners[i] - target;
            const x = Mathf.abs(rel.dot(right)) * FRAME_MARGIN;
            const y = Mathf.abs(rel.dot(camUp)) * FRAME_MARGIN;
            const z = rel.dot(forward); // positive = beyond the target
            maxX = maxF32(maxX, x);
            maxY = maxF32(maxY, y);
            needD = maxF32(maxF32(needD, x / appleTanf(fovX * <f32>0.5) - z), y / appleTanf(fovY * <f32>0.5) - z);
        }
        const sphereD = radius * FRAME_MARGIN / appleSinf(minF32(fovX, fovY) * <f32>0.5);
        let distance: f32;
        if (req.hasDistance && req.distance > 0.0) {
            distance = req.distance;
        } else if (req.ortho) {
            distance = maxF32(sphereD, radius * <f32>2.0);
        } else if (req.sphereFit) {
            distance = sphereD;
        } else {
            distance = maxF32(needD, radius * <f32>0.5);
        }
        let projection: Projection;
        if (req.ortho) {
            const halfHeight = req.sphereFit
                ? radius * FRAME_MARGIN
                : maxF32(maxF32(maxY, maxX / aspect), <f32>1e-3);
            projection = Projection.orthographic(halfHeight);
        } else {
            projection = Projection.perspective(toDegrees(fovY));
        }
        const eye = target + dir * distance;
        // Depth range: from just in front of the eye to well past the grid.
        const reach = maxF32(distance + radius * <f32>2.0 + <f32>1.0, gridExtent(bounds) * <f32>3.0);
        return new Camera(
            eye,
            target,
            up,
            projection,
            clampF32(distance * <f32>0.02, 0.001, 1.0),
            distance + reach,
        );
    }

    viewMatrix(): Mat4 {
        return camera.lookAtMat4Rh(this.eye, this.target, this.up);
    }

    // WebGPU clip space: depth 0..1, y up.
    projectionMatrix(aspect: f32): Mat4 {
        if (this.projection.kind == ProjectionKind.Perspective) {
            return perspectiveRhDirectx(toRadians(this.projection.value), aspect, this.near, this.far);
        }
        const halfHeight = this.projection.value;
        const hw = halfHeight * aspect;
        return camera.orthographicRhDirectx(-hw, hw, -halfHeight, halfHeight, this.near, this.far);
    }

    viewProj(aspect: f32): Mat4 {
        return this.projectionMatrix(aspect) * this.viewMatrix();
    }

    isOrtho(): bool {
        return this.projection.kind == ProjectionKind.Orthographic;
    }

    forward(): Vec3 {
        return (this.target - this.eye).normalize();
    }

    // World-space size of one pixel at depth `d` (distance along the view
    // direction) for an image `height` pixels tall.
    worldPerPixel(d: f32, height: u32): f32 {
        const h = <f32>max<u32>(height, 1);
        if (this.projection.kind == ProjectionKind.Perspective) {
            return <f32>2.0 * maxF32(d, <f32>1e-6) * appleTanf(toRadians(this.projection.value) * <f32>0.5) / h;
        }
        return <f32>2.0 * this.projection.value / h;
    }

    // Project a world point to pixel coordinates (y down) and NDC depth.
    // `some == false` when behind the camera.
    project(viewProj: Mat4, width: u32, height: u32, p: Vec3): Projected {
        const clip = viewProj.mulVec4(p.extend(1.0));
        if (clip.w <= <f32>1e-6) {
            return Projected(false, 0, 0, 0);
        }
        const ndc = clip.xyz() / clip.w;
        const x = (ndc.x * <f32>0.5 + <f32>0.5) * <f32>width;
        const y = (<f32>1.0 - (ndc.y * <f32>0.5 + <f32>0.5)) * <f32>height;
        return Projected(true, x, y, ndc.z);
    }
}

// Right-handed perspective projection with a 0..1 depth range. It uses
// Apple libm's `appleSincosf` (as vecmath's `camera.perspectiveRhDirectx`
// does too); a correctly rounded sin/cos gives a different `cos/sin` on
// ~0.045% of half-angles, e.g. a 496x96 or 1056x784 view at the default fov,
// and the recorded reference images would no longer match.
function perspectiveRhDirectx(verticalFov: f32, aspectRatio: f32, near: f32, far: f32): Mat4 {
    const sc = appleSincosf(<f32>0.5 * verticalFov);
    const h = sc.c / sc.s;
    const xx = h / aspectRatio;
    const yy = h;
    const zRangeInv = <f32>1.0 / (far - near);
    const zz = -far * zRangeInv;
    const tz = -near * far * zRangeInv;
    return Mat4(Vec4(xx, 0, 0, 0), Vec4(0, yy, 0, 0), Vec4(0, 0, zz, -1), Vec4(0, 0, tz, 0));
}

// Half-size of the floor grid for a scene of these bounds: at least 10
// units, more for big or far-away scenes.
export function gridExtent(bounds: Bounds): f32 {
    const c = bounds.corners();
    let far: f32 = 0.0;
    for (let i = 0; i < 8; i++) {
        far = maxF32(far, maxF32(Mathf.abs(c[i].x), Mathf.abs(c[i].y)));
    }
    return Mathf.ceil(maxF32(far + bounds.radius() * <f32>2.0, 10.0));
}
