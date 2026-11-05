// The shapes' geometry (milestone 31, docs/formats/RSCN.md "Interaction"):
// a ray against one shape and a point in one shape, in the shape's own
// space, its bounds, and the support point of a convex one (gjk.as). The
// interaction world (world.as) carries rays and points into each shape's
// space through the inverse of its global transform, so a scaled or
// sheared shape is exact, a non-uniformly scaled sphere an ellipsoid
// (Godot warns about non-uniform scale and is approximate there).
//
// Conventions: the shape's space is its CollisionShape3D's (scene space,
// Y up, metres), centred on the origin; a capsule and a cylinder stand
// along y. A ray is origin + t * dir with dir as given (not normalised), t
// from 0 to tMax; a hit's normal is the unit outward normal in the
// shape's space. Nothing here allocates per call: a ConvexPolygonShape3D's
// hull and a ConcavePolygonShape3D's BVH are made once per version of the
// shape (prepared.as) and kept on it.
//
// How each solid shape is hit: the line's interval inside the shape
// (entry and exit along the ray, and the entry's normal) by the box's
// slabs, the sphere's quadratic, the capsule's two cap spheres and the
// cylinder between them (the capsule is convex: the interval is the
// parts' union), the cylinder's side quadratic within its two caps' slab,
// and the convex hull's planes (each clips the line; the last plane
// entered gives the normal). Then Godot's rules: a start strictly inside
// (more than POINT_TOLERANCE from the surface) hits at t = 0 with a zero
// normal only with hit_from_inside, and else misses the shape; a start on
// the surface is outside (the ray hits at t = 0 going in, and nothing
// going out); a ray that only grazes the surface hits it there. A
// degenerate shape (a box with a negative side or every side 0, a radius
// or height of 0 or less, a convex shape of fewer than four points out of
// one plane, a concave shape with no triangle) is hit nowhere and holds no
// point. A flat box (one or two sides 0) is not degenerate: Godot casts it,
// and the slab test meets its plane.

import { Vec3 } from "../../base/vecmath";
import { RayHit } from "../../render/raycast";
import {
    BoxShape3D, CapsuleShape3D, ConcavePolygonShape3D, ConvexPolygonShape3D, CylinderShape3D, SHAPE_BOX,
    SHAPE_CAPSULE, SHAPE_CONCAVE, SHAPE_CONVEX, SHAPE_CYLINDER, SHAPE_SPHERE, Shape3D, SphereShape3D,
} from "../resource/types";
import { concaveBvhOf, convexHullOf } from "./prepared";

// Metres: a point this close to a shape's surface is on it (inside for
// pointInShape, not strictly inside for a ray's start).
export const POINT_TOLERANCE: f64 = 1e-9;

// A ray's hit on one shape (a kept object, filled again by each call).
export class ShapeHit {
    // Along the ray: the point is origin + t * dir.
    t: f64 = Infinity;
    // The unit outward normal at the point, in the shape's space (zero for
    // a ray that started inside: `inside`).
    nx: f64 = 0;
    ny: f64 = 0;
    nz: f64 = 0;
    // A ConcavePolygonShape3D's triangle hit (its index: data / 9); -1
    // for any other shape.
    face: i32 = -1;
    // The ray started inside the shape (hitFromInside): t is 0.
    inside: bool = false;
}

// An axis-aligned box, min and max (empty when min > max).
export class Aabb {
    minX: f64 = Infinity;
    minY: f64 = Infinity;
    minZ: f64 = Infinity;
    maxX: f64 = -Infinity;
    maxY: f64 = -Infinity;
    maxZ: f64 = -Infinity;

    set(minX: f64, minY: f64, minZ: f64, maxX: f64, maxY: f64, maxZ: f64): void {
        this.minX = minX;
        this.minY = minY;
        this.minZ = minZ;
        this.maxX = maxX;
        this.maxY = maxY;
        this.maxZ = maxZ;
    }

    setEmpty(): void {
        this.set(Infinity, Infinity, Infinity, -Infinity, -Infinity, -Infinity);
    }

    isEmpty(): bool {
        return !(this.minX <= this.maxX && this.minY <= this.maxY && this.minZ <= this.maxZ);
    }

    // Grows to hold the point.
    include(x: f64, y: f64, z: f64): void {
        if (x < this.minX) this.minX = x;
        if (y < this.minY) this.minY = y;
        if (z < this.minZ) this.minZ = z;
        if (x > this.maxX) this.maxX = x;
        if (y > this.maxY) this.maxY = y;
        if (z > this.maxZ) this.maxZ = z;
    }

    // Whether the two boxes share a point (touching counts).
    overlaps(o: Aabb): bool {
        return this.minX <= o.maxX && o.minX <= this.maxX && this.minY <= o.maxY && o.minY <= this.maxY
            && this.minZ <= o.maxZ && o.minZ <= this.maxZ;
    }

    copyFrom(o: Aabb): void {
        this.set(o.minX, o.minY, o.minZ, o.maxX, o.maxY, o.maxZ);
    }
}

// Whether a shape kind (resource/types.as SHAPE_*) is convex: every kind
// but SHAPE_CONCAVE.
export function isConvexKind(kind: i32): bool {
    return kind >= 0 && kind != SHAPE_CONCAVE;
}

// Whether the shape is degenerate (the header): no ray hits it, it holds
// no point and overlaps nothing. A degenerate primitive's bounds are
// empty; a flat convex shape's are its points' box (its lines still draw).
export function shapeIsDegenerate(s: Shape3D): bool {
    switch (s.kind()) {
        case SHAPE_BOX: {
            // (a flat box, one or two sides 0, is a box: Godot draws and
            // casts it, a thin trigger plane; only a negative side or a
            // box with no extent at all is nothing)
            const size = (<BoxShape3D>s).size;
            if (!(size.x >= 0 && size.y >= 0 && size.z >= 0)) return true;
            return size.x == 0 && size.y == 0 && size.z == 0;
        }
        case SHAPE_SPHERE:
            return !((<SphereShape3D>s).radius > 0);
        case SHAPE_CAPSULE: {
            const c = <CapsuleShape3D>s;
            return !(c.radius > 0 && c.height > 0);
        }
        case SHAPE_CYLINDER: {
            const c = <CylinderShape3D>s;
            return !(c.radius > 0 && c.height > 0);
        }
        case SHAPE_CONVEX:
            return !convexHullOf(<ConvexPolygonShape3D>s).solid();
        case SHAPE_CONCAVE:
            return (<ConcavePolygonShape3D>s).triangleCount() == 0;
    }
    return true;
}

// The shape's bounds in its own space into `out`: exact for the box,
// sphere, capsule and cylinder, the points' or triangles' box for a
// polygon (empty for one with no points).
export function shapeLocalBounds(s: Shape3D, out: Aabb): void {
    out.setEmpty();
    const kind = s.kind();
    if (kind == SHAPE_CONVEX) {
        const p = (<ConvexPolygonShape3D>s).points;
        for (let i = 0; i + 2 < p.length; i += 3) {
            if (isFinite(p[i]) && isFinite(p[i + 1]) && isFinite(p[i + 2])) out.include(p[i], p[i + 1], p[i + 2]);
        }
        return;
    }
    if (kind == SHAPE_CONCAVE) {
        const c = <ConcavePolygonShape3D>s;
        const p = c.data;
        const n = c.triangleCount() * 9;
        for (let i = 0; i < n; i += 3) out.include(p[i], p[i + 1], p[i + 2]);
        return;
    }
    if (shapeIsDegenerate(s)) return;
    switch (kind) {
        case SHAPE_BOX: {
            const size = (<BoxShape3D>s).size;
            const hx = <f64>size.x * 0.5, hy = <f64>size.y * 0.5, hz = <f64>size.z * 0.5;
            out.set(-hx, -hy, -hz, hx, hy, hz);
            break;
        }
        case SHAPE_SPHERE: {
            const r = (<SphereShape3D>s).radius;
            out.set(-r, -r, -r, r, r, r);
            break;
        }
        case SHAPE_CAPSULE: {
            const c = <CapsuleShape3D>s;
            const r = c.effectiveRadius();
            const h = c.halfSegment() + r;
            out.set(-r, -h, -r, r, h, r);
            break;
        }
        case SHAPE_CYLINDER: {
            const c = <CylinderShape3D>s;
            const r = c.radius, h = c.height * 0.5;
            out.set(-r, -h, -r, r, h, r);
            break;
        }
    }
}

// The line's interval in a solid shape, found by lineInterval: entry,
// exit, and the outward normal at the entry. Module-level so a call
// allocates nothing.
let gIn: f64 = 0;
let gOut: f64 = 0;
let gNx: f64 = 0;
let gNy: f64 = 0;
let gNz: f64 = 0;

// A ConcavePolygonShape3D's tree hit (kept).
const treeHit = new RayHit();

// The ray origin + t * dir, t in [0, tMax], against the shape in its own
// space: whether it hits, the nearest hit in `out`. A ray starting inside
// a solid shape (on its surface counts as outside) hits at t = 0 with a
// zero normal and `inside` when `hitFromInside`, else misses the shape
// (Godot's hit_from_inside). A ConcavePolygonShape3D is hit on the front
// of its faces, and on their back too only when its backfaceCollision and
// `hitBackFaces` are both on; it has no inside.
export function rayShape(s: Shape3D, ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64, tMax: f64,
    hitFromInside: bool, hitBackFaces: bool, out: ShapeHit): bool {
    out.t = Infinity;
    out.nx = 0;
    out.ny = 0;
    out.nz = 0;
    out.face = -1;
    out.inside = false;
    if (!(tMax >= 0)) return false;
    const kind = s.kind();
    const d2 = dx * dx + dy * dy + dz * dz;
    const goodDir = d2 > 0 && isFinite(d2);
    if (kind == SHAPE_CONCAVE) {
        if (!goodDir || (<ConcavePolygonShape3D>s).triangleCount() == 0) return false;
        return rayConcave(<ConcavePolygonShape3D>s, ox, oy, oz, dx, dy, dz, d2, tMax, hitBackFaces, out);
    }
    let strictlyInside = false;
    let met = false;
    if (kind == SHAPE_CONVEX) {
        // One pass over the planes: the start's side of each and the
        // line's clipping (a convex shape's cost is its planes).
        const hull = convexHullOf(<ConvexPolygonShape3D>s);
        if (!hull.solid()) return false;
        met = convexPass(hull.planes, ox, oy, oz, dx, dy, dz, goodDir);
        strictlyInside = gInside;
    } else {
        if (shapeIsDegenerate(s)) return false;
        strictlyInside = pointInSolid(s, ox, oy, oz, -POINT_TOLERANCE);
        if (!strictlyInside && goodDir) met = lineInterval(s, ox, oy, oz, dx, dy, dz);
    }
    if (strictlyInside) {
        if (!hitFromInside) return false;
        out.t = 0;
        out.inside = true;
        return true;
    }
    if (!goodDir || !met) return false;
    if (gOut < gIn) return false;
    // Behind the start, or (the start on the surface) leaving the shape.
    const tolT = POINT_TOLERANCE / Math.sqrt(d2);
    if (gIn < -tolT) return false;
    const t = max<f64>(gIn, 0);
    if (t > tMax) return false;
    out.t = t;
    out.nx = gNx;
    out.ny = gNy;
    out.nz = gNz;
    return true;
}

// Whether the point (the shape's space) is inside the solid shape or on
// its surface. A ConcavePolygonShape3D has no inside: false.
export function pointInShape(s: Shape3D, x: f64, y: f64, z: f64): bool {
    if (s.kind() == SHAPE_CONCAVE) return false;
    if (shapeIsDegenerate(s)) return false;
    return pointInSolid(s, x, y, z, POINT_TOLERANCE);
}

// The point of a convex shape farthest along the direction d (its space;
// any length but zero), for GJK (gjk.as). For a ConcavePolygonShape3D, the
// origin.
export function supportLocal(s: Shape3D, dx: f64, dy: f64, dz: f64): Vec3 {
    supportInto(s, dx, dy, dz);
    return Vec3(<f32>support.x, <f32>support.y, <f32>support.z);
}

// A support point in f64 (supportInto's answer, kept).
export class SupportPoint {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
}

export const support = new SupportPoint();

// supportLocal in f64, into `support` (what gjk.as reads: no rounding to
// f32, no allocation).
export function supportInto(s: Shape3D, dx: f64, dy: f64, dz: f64): void {
    let supX: f64 = 0, supY: f64 = 0, supZ: f64 = 0;
    switch (s.kind()) {
        case SHAPE_BOX: {
            const size = (<BoxShape3D>s).size;
            const hx = <f64>size.x * 0.5, hy = <f64>size.y * 0.5, hz = <f64>size.z * 0.5;
            supX = dx >= 0 ? hx : -hx;
            supY = dy >= 0 ? hy : -hy;
            supZ = dz >= 0 ? hz : -hz;
            break;
        }
        case SHAPE_SPHERE: {
            const len = Math.sqrt(dx * dx + dy * dy + dz * dz);
            if (len > 0) {
                const r = (<SphereShape3D>s).radius / len;
                supX = dx * r;
                supY = dy * r;
                supZ = dz * r;
            }
            break;
        }
        case SHAPE_CAPSULE: {
            const c = <CapsuleShape3D>s;
            const len = Math.sqrt(dx * dx + dy * dy + dz * dz);
            const hs = c.halfSegment();
            supY = dy >= 0 ? hs : -hs;
            if (len > 0) {
                const r = c.effectiveRadius() / len;
                supX = dx * r;
                supY += dy * r;
                supZ = dz * r;
            }
            break;
        }
        case SHAPE_CYLINDER: {
            const c = <CylinderShape3D>s;
            const h = c.height * 0.5;
            supY = dy >= 0 ? h : -h;
            const rl = Math.sqrt(dx * dx + dz * dz);
            if (rl > 0) {
                supX = dx * c.radius / rl;
                supZ = dz * c.radius / rl;
            }
            break;
        }
        case SHAPE_CONVEX: {
            const p = convexHullOf(<ConvexPolygonShape3D>s).points;
            let best = -Infinity;
            for (let i = 0; i + 2 < p.length; i += 3) {
                const v = p[i] * dx + p[i + 1] * dy + p[i + 2] * dz;
                if (v > best) {
                    best = v;
                    supX = p[i];
                    supY = p[i + 1];
                    supZ = p[i + 2];
                }
            }
            break;
        }
    }
    support.x = supX;
    support.y = supY;
    support.z = supZ;
}

// Whether the point is inside the solid (not concave, not degenerate)
// shape grown by `pad` (negative: strictly inside by -pad).
function pointInSolid(s: Shape3D, x: f64, y: f64, z: f64, pad: f64): bool {
    switch (s.kind()) {
        case SHAPE_BOX: {
            const size = (<BoxShape3D>s).size;
            return within(Math.abs(x), <f64>size.x * 0.5 + pad, pad) && within(Math.abs(y), <f64>size.y * 0.5 + pad, pad)
                && within(Math.abs(z), <f64>size.z * 0.5 + pad, pad);
        }
        case SHAPE_SPHERE:
            return within(Math.sqrt(x * x + y * y + z * z), (<SphereShape3D>s).radius + pad, pad);
        case SHAPE_CAPSULE: {
            const c = <CapsuleShape3D>s;
            const hs = c.halfSegment();
            const cy = y > hs ? y - hs : (y < -hs ? y + hs : 0);
            return within(Math.sqrt(x * x + cy * cy + z * z), c.effectiveRadius() + pad, pad);
        }
        case SHAPE_CYLINDER: {
            const c = <CylinderShape3D>s;
            return within(Math.sqrt(x * x + z * z), c.radius + pad, pad) && within(Math.abs(y), c.height * 0.5 + pad, pad);
        }
        case SHAPE_CONVEX: {
            const pl = convexHullOf(<ConvexPolygonShape3D>s).planes;
            for (let i = 0; i < pl.length; i += 4) {
                if (!within(pl[i] * x + pl[i + 1] * y + pl[i + 2] * z - pl[i + 3], pad, pad)) return false;
            }
            return true;
        }
    }
    return false;
}

// v <= limit for a tolerance (pad >= 0), v < limit for strictly inside.
@inline
function within(v: f64, limit: f64, pad: f64): bool {
    return pad >= 0 ? v <= limit : v < limit;
}

// The line origin + t * dir in a solid shape: whether it meets it, the
// interval and the entry's normal in gIn, gOut, gN*.
function lineInterval(s: Shape3D, ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64): bool {
    switch (s.kind()) {
        case SHAPE_BOX: {
            const size = (<BoxShape3D>s).size;
            return boxInterval(<f64>size.x * 0.5, <f64>size.y * 0.5, <f64>size.z * 0.5, ox, oy, oz, dx, dy, dz);
        }
        case SHAPE_SPHERE:
            return sphereInterval((<SphereShape3D>s).radius, 0, ox, oy, oz, dx, dy, dz);
        case SHAPE_CAPSULE:
            return capsuleInterval(<CapsuleShape3D>s, ox, oy, oz, dx, dy, dz);
        case SHAPE_CYLINDER: {
            const c = <CylinderShape3D>s;
            return cylinderInterval(c.radius, c.height * 0.5, ox, oy, oz, dx, dy, dz, false);
        }
        case SHAPE_CONVEX:
            return convexPass(convexHullOf(<ConvexPolygonShape3D>s).planes, ox, oy, oz, dx, dy, dz, true);
    }
    return false;
}

// The box of half sizes h: the slabs.
function boxInterval(hx: f64, hy: f64, hz: f64, ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64): bool {
    let tIn = -Infinity, tOut = Infinity;
    let axis = -1;
    let sign: f64 = 0;
    for (let a = 0; a < 3; a++) {
        const o = a == 0 ? ox : (a == 1 ? oy : oz);
        const d = a == 0 ? dx : (a == 1 ? dy : dz);
        const h = a == 0 ? hx : (a == 1 ? hy : hz);
        if (d == 0) {
            if (o < -h || o > h) return false;
            continue;
        }
        const t1 = (-h - o) / d, t2 = (h - o) / d;
        const near = min<f64>(t1, t2), far = max<f64>(t1, t2);
        if (near > tIn) {
            tIn = near;
            axis = a;
            sign = d > 0 ? -1 : 1;
        }
        if (far < tOut) tOut = far;
        if (tIn > tOut) return false;
    }
    if (axis < 0) return false;
    gIn = tIn;
    gOut = tOut;
    gNx = axis == 0 ? sign : 0;
    gNy = axis == 1 ? sign : 0;
    gNz = axis == 2 ? sign : 0;
    return true;
}

// The sphere of radius r centred at (0, cy, 0): the quadratic.
function sphereInterval(r: f64, cy: f64, ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64): bool {
    const py = oy - cy;
    const a = dx * dx + dy * dy + dz * dz;
    const b = ox * dx + py * dy + oz * dz;
    const c = ox * ox + py * py + oz * oz - r * r;
    const disc = b * b - a * c;
    if (disc < 0) return false;
    const sq = Math.sqrt(disc);
    const t0 = (-b - sq) / a;
    gIn = t0;
    gOut = (-b + sq) / a;
    const nx = ox + t0 * dx, ny = py + t0 * dy, nz = oz + t0 * dz;
    const len = Math.sqrt(nx * nx + ny * ny + nz * nz);
    gNx = len > 0 ? nx / len : 0;
    gNy = len > 0 ? ny / len : 0;
    gNz = len > 0 ? nz / len : 0;
    return true;
}

// The cylinder of radius r along y between -h and h: its side's quadratic
// within the caps' slab. `sideOnly`: an entry through a cap is no entry
// (the capsule's middle, whose caps are inside its spheres).
function cylinderInterval(r: f64, h: f64, ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64, sideOnly: bool): bool {
    let rIn = -Infinity, rOut = Infinity;
    const a = dx * dx + dz * dz;
    const c = ox * ox + oz * oz - r * r;
    if (a == 0) {
        if (c > 0) return false;
    } else {
        const b = ox * dx + oz * dz;
        const disc = b * b - a * c;
        if (disc < 0) return false;
        const sq = Math.sqrt(disc);
        rIn = (-b - sq) / a;
        rOut = (-b + sq) / a;
    }
    let yIn = -Infinity, yOut = Infinity;
    if (dy == 0) {
        if (oy < -h || oy > h) return false;
    } else {
        const t1 = (-h - oy) / dy, t2 = (h - oy) / dy;
        yIn = min<f64>(t1, t2);
        yOut = max<f64>(t1, t2);
    }
    const tIn = max<f64>(rIn, yIn), tOut = min<f64>(rOut, yOut);
    if (tIn > tOut) return false;
    gIn = tIn;
    gOut = tOut;
    if (rIn >= yIn) {
        const nx = ox + rIn * dx, nz = oz + rIn * dz;
        const len = Math.sqrt(nx * nx + nz * nz);
        gNx = len > 0 ? nx / len : 0;
        gNy = 0;
        gNz = len > 0 ? nz / len : 0;
    } else {
        if (sideOnly) gIn = Infinity;
        gNx = 0;
        gNy = dy > 0 ? -1 : 1;
        gNz = 0;
    }
    return true;
}

// The capsule: its two cap spheres and the side between them; the line's
// interval is their union's (the earliest entry, the latest exit).
function capsuleInterval(c: CapsuleShape3D, ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64): bool {
    const r = c.effectiveRadius(), hs = c.halfSegment();
    let found = false;
    let tIn = Infinity, tOut = -Infinity;
    let nx: f64 = 0, ny: f64 = 0, nz: f64 = 0;
    for (let k = 0; k < 3; k++) {
        let met = false;
        if (k < 2) met = sphereInterval(r, k == 0 ? hs : -hs, ox, oy, oz, dx, dy, dz);
        else if (hs > 0) met = cylinderInterval(r, hs, ox, oy, oz, dx, dy, dz, true);
        if (!met) continue;
        found = true;
        // The spheres first: a side entry replaces theirs only when
        // strictly earlier.
        if (gIn < tIn) {
            tIn = gIn;
            nx = gNx;
            ny = gNy;
            nz = gNz;
        }
        if (gOut > tOut) tOut = gOut;
    }
    if (!found || tIn == Infinity) return false;
    gIn = tIn;
    gOut = tOut;
    gNx = nx;
    gNy = ny;
    gNz = nz;
    return true;
}

// Whether the start is strictly inside, from convexPass.
let gInside = false;

// A convex hull's planes (nx, ny, nz, d; inside n . p <= d): whether the
// start is strictly inside every one (gInside), and (`clip`) the line
// clipped by each, the last plane entered giving the normal; whether the
// line meets the hull.
function convexPass(pl: Array<f64>, ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64, clip: bool): bool {
    let tIn = -Infinity, tOut = Infinity;
    let face = -1;
    let inside = true;
    let met = clip;
    const n = pl.length;
    for (let i = 0; i < n; i += 4) {
        const px = unchecked(pl[i]), py = unchecked(pl[i + 1]), pz = unchecked(pl[i + 2]);
        const dist = px * ox + py * oy + pz * oz - unchecked(pl[i + 3]);
        if (!(dist < -POINT_TOLERANCE)) inside = false;
        if (!met) continue;
        const denom = px * dx + py * dy + pz * dz;
        if (denom == 0) {
            if (dist > 0) met = false;
            continue;
        }
        const t = -dist / denom;
        if (denom < 0) {
            if (t > tIn) {
                tIn = t;
                face = i;
            }
        } else if (t < tOut) {
            tOut = t;
        }
        if (tIn > tOut) met = false;
    }
    gInside = inside;
    if (!met || face < 0) return false;
    gIn = tIn;
    gOut = tOut;
    gNx = pl[face];
    gNy = pl[face + 1];
    gNz = pl[face + 2];
    return true;
}

// A ConcavePolygonShape3D: its BVH's nearest hit of the side(s) that
// count (Godot's front is the tree's back: cull the tree's front). A
// start on a face counts (t a hair below 0 is 0).
function rayConcave(s: ConcavePolygonShape3D, ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64, d2: f64,
    tMax: f64, hitBackFaces: bool, out: ShapeHit): bool {
    const bvh = concaveBvhOf(s);
    const both = s.backfaceCollision && hitBackFaces;
    const tolT = POINT_TOLERANCE / Math.sqrt(d2);
    if (!bvh.nearestHitCulled(ox, oy, oz, dx, dy, dz, -tolT, tMax + tolT, !both, false, treeHit)) return false;
    const t = max<f64>(treeHit.t, 0);
    if (t > tMax) return false;
    // Godot's normal, (c - a) x (b - a), turned to face the ray.
    const p = s.data;
    const o = treeHit.tri * 9;
    const ax = p[o], ay = p[o + 1], az = p[o + 2];
    const bx = p[o + 3] - ax, by = p[o + 4] - ay, bz = p[o + 5] - az;
    const cx = p[o + 6] - ax, cy = p[o + 7] - ay, cz = p[o + 8] - az;
    let nx = cy * bz - cz * by, ny = cz * bx - cx * bz, nz = cx * by - cy * bx;
    const len = Math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 0) {
        nx /= len;
        ny /= len;
        nz /= len;
    }
    if (nx * dx + ny * dy + nz * dz > 0) {
        nx = -nx;
        ny = -ny;
        nz = -nz;
    }
    out.t = t;
    out.nx = nx;
    out.ny = ny;
    out.nz = nz;
    out.face = treeHit.tri;
    return true;
}
