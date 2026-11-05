// Whether two shapes overlap (milestone 31): what an Area3D's monitoring
// asks of each pair whose world boxes meet (world.as). Two convex shapes
// are tested by GJK on their support functions (geometry.as supportLocal,
// carried into the world by each shape's transform, any affine one); a
// ConcavePolygonShape3D against a convex shape by each of its triangles
// whose box meets the convex shape's (its BVH's box query: prepared.as),
// a triangle being a convex shape of three points; two concave shapes
// never overlap, as in Godot (neither has an inside). Overlapping means
// sharing a point more than OVERLAP_EPSILON inside both: shapes that only
// touch do not overlap, so a body resting on an area's face is not in it.
// Allocates nothing.
//
// The method (no EPA): A and B overlap when the origin is inside their
// Minkowski difference D = A - B, more than OVERLAP_EPSILON deep. GJK runs
// on the support s(v) = s_A(v) - s_B(-v) - OVERLAP_EPSILON v/|v|, every
// support point of D moved by the epsilon against its direction. Every
// such point lies within the epsilon of D, so a pair apart by more than
// the epsilon is never found to overlap; when D holds the origin more than
// the epsilon deep, the set of those points holds it too (the support
// function of D shrunk by the epsilon is h_D(v) - epsilon |v|, which each
// point reaches), so GJK finds a tetrahedron around it. Shapes that only
// touch (D with the origin on its boundary) give points all strictly on
// one side of the origin: GJK proves them apart. Between 0 and the epsilon
// deep the answer may go either way: well below what any test or scene
// tells apart. GJK stops after GJK_MAX_ITERATIONS steps without an answer
// as "apart" (a pair that close to touching).
//
// A sphere against a sphere or a box, each placed by a rotation and a
// uniform scale (what areas and pickups mostly are), skips GJK: the same
// rule, more than OVERLAP_EPSILON deep, from the exact distance. GJK costs
// about 4 us a pair in the run time's interpreter, these a tenth of that.
//
// A shape's support in the world: a shape placed by W (linear part L,
// translation t) has s_world(v) = L s_local(L^T v) + t, exact for any
// affine W (scaled, sheared): a non-uniformly scaled sphere is an
// ellipsoid here.

import { Mat4 } from "../../base/vecmath";
import { BoxShape3D, ConcavePolygonShape3D, SHAPE_BOX, SHAPE_CONCAVE, SHAPE_SPHERE, Shape3D, SphereShape3D } from "../resource/types";
import { Aabb, shapeIsDegenerate, shapeLocalBounds, support, supportInto } from "./geometry";
import { concaveBvhOf } from "./prepared";

// Metres: how far shapes must go into each other to overlap.
export const OVERLAP_EPSILON: f64 = 1e-6;

// GJK's steps before it gives up (as apart).
export const GJK_MAX_ITERATIONS: i32 = 64;

// The two sides: a shape and its matrix (12 numbers: L's columns, then
// t), or a triangle's three world points.
const SIDE_SHAPE: i32 = 0;
const SIDE_TRIANGLE: i32 = 1;

class Side {
    kind: i32 = SIDE_SHAPE;
    shape: Shape3D? = null;
    m: Float64Array = new Float64Array(12);
    tri: Float64Array = new Float64Array(9);
    // Its centre in the world (GJK's first direction).
    cx: f64 = 0;
    cy: f64 = 0;
    cz: f64 = 0;

    setShape(s: Shape3D, w: Mat4): void {
        this.kind = SIDE_SHAPE;
        this.shape = s;
        const m = this.m;
        m[0] = w.xAxis.x; m[1] = w.xAxis.y; m[2] = w.xAxis.z;
        m[3] = w.yAxis.x; m[4] = w.yAxis.y; m[5] = w.yAxis.z;
        m[6] = w.zAxis.x; m[7] = w.zAxis.y; m[8] = w.zAxis.z;
        m[9] = w.wAxis.x; m[10] = w.wAxis.y; m[11] = w.wAxis.z;
        this.cx = m[9];
        this.cy = m[10];
        this.cz = m[11];
    }

    // The support along (dx, dy, dz) into sx, sy, sz.
    supportAlong(dx: f64, dy: f64, dz: f64): void {
        if (this.kind == SIDE_TRIANGLE) {
            const t = this.tri;
            let best = 0;
            let bestV = t[0] * dx + t[1] * dy + t[2] * dz;
            const v1 = t[3] * dx + t[4] * dy + t[5] * dz;
            if (v1 > bestV) {
                bestV = v1;
                best = 3;
            }
            const v2 = t[6] * dx + t[7] * dy + t[8] * dz;
            if (v2 > bestV) best = 6;
            sx = t[best];
            sy = t[best + 1];
            sz = t[best + 2];
            return;
        }
        const m = this.m;
        // L^T d into the shape's space, its support, carried back by L, t.
        supportInto(this.shape!, m[0] * dx + m[1] * dy + m[2] * dz, m[3] * dx + m[4] * dy + m[5] * dz,
            m[6] * dx + m[7] * dy + m[8] * dz);
        const lx = support.x, ly = support.y, lz = support.z;
        sx = m[0] * lx + m[3] * ly + m[6] * lz + m[9];
        sy = m[1] * lx + m[4] * ly + m[7] * lz + m[10];
        sz = m[2] * lx + m[5] * ly + m[8] * lz + m[11];
    }
}

let sx: f64 = 0;
let sy: f64 = 0;
let sz: f64 = 0;

const sideA = new Side();
const sideB = new Side();
// The simplex: up to four points of the shrunk difference, the newest
// last (x, y, z each).
const simplex = new Float64Array(12);
let simplexCount = 0;
// GJK's search direction.
let dirX: f64 = 0;
let dirY: f64 = 0;
let dirZ: f64 = 0;
// The concave case's triangles meeting the convex shape's box (kept).
const candidates: Array<i32> = [];
const bounds = new Aabb();

// Whether `a`, placed by `wa` (its shape space to the world; `ia` the
// inverse), and `b`, by `wb` and `ib`, overlap.
export function shapesOverlap(a: Shape3D, wa: Mat4, ia: Mat4, b: Shape3D, wb: Mat4, ib: Mat4): bool {
    const ca = a.kind() == SHAPE_CONCAVE, cb = b.kind() == SHAPE_CONCAVE;
    if (ca && cb) return false;
    if (shapeIsDegenerate(a) || shapeIsDegenerate(b)) return false;
    if (!ca && !cb) {
        const ka = a.kind(), kb = b.kind();
        if (ka == SHAPE_SPHERE) {
            const r = sphereAgainst(<SphereShape3D>a, wa, b, kb, wb, ib);
            if (r >= 0) return r == 1;
        } else if (kb == SHAPE_SPHERE) {
            const r = sphereAgainst(<SphereShape3D>b, wb, a, ka, wa, ia);
            if (r >= 0) return r == 1;
        }
        sideA.setShape(a, wa);
        sideB.setShape(b, wb);
        return gjk();
    }
    if (ca) return concaveOverlap(<ConcavePolygonShape3D>a, wa, ia, b, wb);
    return concaveOverlap(<ConcavePolygonShape3D>b, wb, ib, a, wa);
}

// The sphere `s` (placed by ws) against `o` (of kind `ko`, placed by wo,
// inverse io) when `o` is a sphere or a box and both placements are a
// rotation and a uniform scale: 1 overlapping, 0 apart, -1 not a case
// this answers (GJK does).
function sphereAgainst(s: SphereShape3D, ws: Mat4, o: Shape3D, ko: i32, wo: Mat4, io: Mat4): i32 {
    if (ko != SHAPE_SPHERE && ko != SHAPE_BOX) return -1;
    const ss = similarityScale(ws);
    if (ss < 0) return -1;
    const so = similarityScale(wo);
    if (so < 0) return -1;
    const r = s.radius * ss;
    const cx = <f64>ws.wAxis.x, cy = <f64>ws.wAxis.y, cz = <f64>ws.wAxis.z;
    if (ko == SHAPE_SPHERE) {
        const dx = cx - <f64>wo.wAxis.x, dy = cy - <f64>wo.wAxis.y, dz = cz - <f64>wo.wAxis.z;
        const deep = r + (<SphereShape3D>o).radius * so - Math.sqrt(dx * dx + dy * dy + dz * dz);
        return deep > OVERLAP_EPSILON ? 1 : 0;
    }
    // (the centre in the box's space, the nearest point of the box to it;
    // a centre inside is at least the radius deep)
    const px = <f64>io.xAxis.x * cx + <f64>io.yAxis.x * cy + <f64>io.zAxis.x * cz + <f64>io.wAxis.x;
    const py = <f64>io.xAxis.y * cx + <f64>io.yAxis.y * cy + <f64>io.zAxis.y * cz + <f64>io.wAxis.y;
    const pz = <f64>io.xAxis.z * cx + <f64>io.yAxis.z * cy + <f64>io.zAxis.z * cz + <f64>io.wAxis.z;
    const size = (<BoxShape3D>o).size;
    const hx = <f64>size.x * 0.5, hy = <f64>size.y * 0.5, hz = <f64>size.z * 0.5;
    const qx = px < -hx ? px + hx : px > hx ? px - hx : 0;
    const qy = py < -hy ? py + hy : py > hy ? py - hy : 0;
    const qz = pz < -hz ? pz + hz : pz > hz ? pz - hz : 0;
    const deep = r - Math.sqrt(qx * qx + qy * qy + qz * qz) * so;
    return deep > OVERLAP_EPSILON ? 1 : 0;
}

// The scale of `m` when its linear part is a rotation times a uniform
// scale (columns of one length, at right angles, within float rounding),
// else -1.
function similarityScale(m: Mat4): f64 {
    const x0 = <f64>m.xAxis.x, x1 = <f64>m.xAxis.y, x2 = <f64>m.xAxis.z;
    const y0 = <f64>m.yAxis.x, y1 = <f64>m.yAxis.y, y2 = <f64>m.yAxis.z;
    const z0 = <f64>m.zAxis.x, z1 = <f64>m.zAxis.y, z2 = <f64>m.zAxis.z;
    const lx = x0 * x0 + x1 * x1 + x2 * x2;
    const ly = y0 * y0 + y1 * y1 + y2 * y2;
    const lz = z0 * z0 + z1 * z1 + z2 * z2;
    if (!(lx > 0)) return -1;
    const tol = lx * SIMILARITY_TOLERANCE;
    if (Math.abs(ly - lx) > tol || Math.abs(lz - lx) > tol) return -1;
    if (Math.abs(x0 * y0 + x1 * y1 + x2 * y2) > tol || Math.abs(x0 * z0 + x1 * z1 + x2 * z2) > tol
        || Math.abs(y0 * z0 + y1 * z1 + y2 * z2) > tol) return -1;
    return Math.sqrt(lx);
}

// How far from a uniform scale a placement may be (relative, squared
// lengths and dot products) and still count as one: f32 rounding of a
// rotation is about 1e-7; 1e-5 is still 5 micrometres on a 1 m sphere.
const SIMILARITY_TOLERANCE: f64 = 1e-5;

// The concave shape `c` (placed by wc, inverse ic) against the convex
// shape `s` (placed by ws): each triangle meeting the convex shape's box,
// in the concave shape's space, until one overlaps.
function concaveOverlap(c: ConcavePolygonShape3D, wc: Mat4, ic: Mat4, s: Shape3D, ws: Mat4): bool {
    shapeLocalBounds(s, bounds);
    if (bounds.isEmpty()) return false;
    // The convex shape's box corners, to the world, to c's space.
    let mnx = Infinity, mny = Infinity, mnz = Infinity, mxx = -Infinity, mxy = -Infinity, mxz = -Infinity;
    for (let k = 0; k < 8; k++) {
        const lx = (k & 1) != 0 ? bounds.maxX : bounds.minX;
        const ly = (k & 2) != 0 ? bounds.maxY : bounds.minY;
        const lz = (k & 4) != 0 ? bounds.maxZ : bounds.minZ;
        const wx = <f64>ws.xAxis.x * lx + <f64>ws.yAxis.x * ly + <f64>ws.zAxis.x * lz + <f64>ws.wAxis.x;
        const wy = <f64>ws.xAxis.y * lx + <f64>ws.yAxis.y * ly + <f64>ws.zAxis.y * lz + <f64>ws.wAxis.y;
        const wz = <f64>ws.xAxis.z * lx + <f64>ws.yAxis.z * ly + <f64>ws.zAxis.z * lz + <f64>ws.wAxis.z;
        const x = <f64>ic.xAxis.x * wx + <f64>ic.yAxis.x * wy + <f64>ic.zAxis.x * wz + <f64>ic.wAxis.x;
        const y = <f64>ic.xAxis.y * wx + <f64>ic.yAxis.y * wy + <f64>ic.zAxis.y * wz + <f64>ic.wAxis.y;
        const z = <f64>ic.xAxis.z * wx + <f64>ic.yAxis.z * wy + <f64>ic.zAxis.z * wz + <f64>ic.wAxis.z;
        if (x < mnx) mnx = x;
        if (y < mny) mny = y;
        if (z < mnz) mnz = z;
        if (x > mxx) mxx = x;
        if (y > mxy) mxy = y;
        if (z > mxz) mxz = z;
    }
    const bvh = concaveBvhOf(c);
    const n = bvh.queryBox(mnx, mny, mnz, mxx, mxy, mxz, candidates);
    if (n == 0) return false;
    sideB.setShape(s, ws);
    sideA.kind = SIDE_TRIANGLE;
    sideA.shape = null;
    const data = c.data;
    const t = sideA.tri;
    for (let k = 0; k < n; k++) {
        const o = candidates[k] * 9;
        for (let v = 0; v < 3; v++) {
            const lx = data[o + v * 3], ly = data[o + v * 3 + 1], lz = data[o + v * 3 + 2];
            t[v * 3] = <f64>wc.xAxis.x * lx + <f64>wc.yAxis.x * ly + <f64>wc.zAxis.x * lz + <f64>wc.wAxis.x;
            t[v * 3 + 1] = <f64>wc.xAxis.y * lx + <f64>wc.yAxis.y * ly + <f64>wc.zAxis.y * lz + <f64>wc.wAxis.y;
            t[v * 3 + 2] = <f64>wc.xAxis.z * lx + <f64>wc.yAxis.z * ly + <f64>wc.zAxis.z * lz + <f64>wc.wAxis.z;
        }
        sideA.cx = (t[0] + t[3] + t[6]) / 3;
        sideA.cy = (t[1] + t[4] + t[7]) / 3;
        sideA.cz = (t[2] + t[5] + t[8]) / 3;
        if (gjk()) return true;
    }
    return false;
}

// The shrunk difference's support along (dx, dy, dz) into sx, sy, sz.
function supportDiff(dx: f64, dy: f64, dz: f64): void {
    sideB.supportAlong(-dx, -dy, -dz);
    const bx = sx, by = sy, bz = sz;
    sideA.supportAlong(dx, dy, dz);
    const len = Math.sqrt(dx * dx + dy * dy + dz * dz);
    const k = OVERLAP_EPSILON / len;
    sx = sx - bx - dx * k;
    sy = sy - by - dy * k;
    sz = sz - bz - dz * k;
}

// GJK on sideA - sideB (shrunk): whether the origin is inside.
function gjk(): bool {
    let dx = sideA.cx - sideB.cx, dy = sideA.cy - sideB.cy, dz = sideA.cz - sideB.cz;
    if (!(dx * dx + dy * dy + dz * dz > 0)) {
        dx = 1;
        dy = 0;
        dz = 0;
    }
    supportDiff(dx, dy, dz);
    simplex[0] = sx;
    simplex[1] = sy;
    simplex[2] = sz;
    simplexCount = 1;
    dirX = -sx;
    dirY = -sy;
    dirZ = -sz;
    for (let iter = 0; iter < GJK_MAX_ITERATIONS; iter++) {
        const dd = dirX * dirX + dirY * dirY + dirZ * dirZ;
        // The origin on the simplex.
        if (!(dd > 0)) return dd == 0;
        supportDiff(dirX, dirY, dirZ);
        // The farthest point along the direction to the origin does not
        // pass it: a plane parts the origin from the set.
        if (sx * dirX + sy * dirY + sz * dirZ <= 0) return false;
        const o = simplexCount * 3;
        simplex[o] = sx;
        simplex[o + 1] = sy;
        simplex[o + 2] = sz;
        simplexCount++;
        if (doSimplex()) return true;
    }
    return false;
}

// Sets simplex to points (indices into the current simplex, oldest
// first) and keeps the newest last.
@inline
function keep2(i: i32, j: i32): void {
    const ix = simplex[i * 3], iy = simplex[i * 3 + 1], iz = simplex[i * 3 + 2];
    const jx = simplex[j * 3], jy = simplex[j * 3 + 1], jz = simplex[j * 3 + 2];
    simplex[0] = ix; simplex[1] = iy; simplex[2] = iz;
    simplex[3] = jx; simplex[4] = jy; simplex[5] = jz;
    simplexCount = 2;
}

@inline
function keep3(i: i32, j: i32, k: i32): void {
    const ix = simplex[i * 3], iy = simplex[i * 3 + 1], iz = simplex[i * 3 + 2];
    const jx = simplex[j * 3], jy = simplex[j * 3 + 1], jz = simplex[j * 3 + 2];
    const kx = simplex[k * 3], ky = simplex[k * 3 + 1], kz = simplex[k * 3 + 2];
    simplex[0] = ix; simplex[1] = iy; simplex[2] = iz;
    simplex[3] = jx; simplex[4] = jy; simplex[5] = jz;
    simplex[6] = kx; simplex[7] = ky; simplex[8] = kz;
    simplexCount = 3;
}

// The simplex's nearest feature to the origin: the simplex reduced to it
// and the direction to the origin from it; true when a tetrahedron holds
// the origin. The newest point (a) is last; points older than it are
// known not to face the origin.
function doSimplex(): bool {
    if (simplexCount == 2) return lineCase();
    if (simplexCount == 3) return triangleCase();
    return tetraCase();
}

// Simplex [b, a].
function lineCase(): bool {
    const ax = simplex[3], ay = simplex[4], az = simplex[5];
    const abx = simplex[0] - ax, aby = simplex[1] - ay, abz = simplex[2] - az;
    const aox = -ax, aoy = -ay, aoz = -az;
    if (abx * aox + aby * aoy + abz * aoz > 0) {
        // (ab x ao) x ab: towards the origin, square to ab.
        const cx = aby * aoz - abz * aoy, cy = abz * aox - abx * aoz, cz = abx * aoy - aby * aox;
        dirX = cy * abz - cz * aby;
        dirY = cz * abx - cx * abz;
        dirZ = cx * aby - cy * abx;
    } else {
        simplex[0] = ax; simplex[1] = ay; simplex[2] = az;
        simplexCount = 1;
        dirX = aox;
        dirY = aoy;
        dirZ = aoz;
    }
    return false;
}

// Simplex [c, b, a].
function triangleCase(): bool {
    const ax = simplex[6], ay = simplex[7], az = simplex[8];
    const abx = simplex[3] - ax, aby = simplex[4] - ay, abz = simplex[5] - az;
    const acx = simplex[0] - ax, acy = simplex[1] - ay, acz = simplex[2] - az;
    const aox = -ax, aoy = -ay, aoz = -az;
    // abc = ab x ac.
    const nx = aby * acz - abz * acy, ny = abz * acx - abx * acz, nz = abx * acy - aby * acx;
    const nn = nx * nx + ny * ny + nz * nz;
    const scale = (abx * abx + aby * aby + abz * abz) * (acx * acx + acy * acy + acz * acz);
    if (!(nn > 1e-24 * scale)) {
        // A flat triangle (a, b and c in a line): its edge ab.
        keep2(1, 2);
        return lineCase();
    }
    // abc x ac: outward from edge ac.
    const ex = ny * acz - nz * acy, ey = nz * acx - nx * acz, ez = nx * acy - ny * acx;
    if (ex * aox + ey * aoy + ez * aoz > 0) {
        if (acx * aox + acy * aoy + acz * aoz > 0) {
            keep2(0, 2);
            const cx = acy * aoz - acz * aoy, cy = acz * aox - acx * aoz, cz = acx * aoy - acy * aox;
            dirX = cy * acz - cz * acy;
            dirY = cz * acx - cx * acz;
            dirZ = cx * acy - cy * acx;
            return false;
        }
        keep2(1, 2);
        return lineCase();
    }
    // ab x abc: outward from edge ab.
    const fx = aby * nz - abz * ny, fy = abz * nx - abx * nz, fz = abx * ny - aby * nx;
    if (fx * aox + fy * aoy + fz * aoz > 0) {
        keep2(1, 2);
        return lineCase();
    }
    // Above or below the triangle: keep it wound so that the next point
    // makes a tetrahedron whose faces tetraCase reads outward.
    if (nx * aox + ny * aoy + nz * aoz > 0) {
        dirX = nx;
        dirY = ny;
        dirZ = nz;
    } else {
        keep3(1, 0, 2);
        dirX = -nx;
        dirY = -ny;
        dirZ = -nz;
    }
    return false;
}

// Simplex [d, c, b, a].
function tetraCase(): bool {
    const ax = simplex[9], ay = simplex[10], az = simplex[11];
    const abx = simplex[6] - ax, aby = simplex[7] - ay, abz = simplex[8] - az;
    const acx = simplex[3] - ax, acy = simplex[4] - ay, acz = simplex[5] - az;
    const adx = simplex[0] - ax, ady = simplex[1] - ay, adz = simplex[2] - az;
    const aox = -ax, aoy = -ay, aoz = -az;
    // abc = ab x ac
    const n1x = aby * acz - abz * acy, n1y = abz * acx - abx * acz, n1z = abx * acy - aby * acx;
    if (n1x * aox + n1y * aoy + n1z * aoz > 0) {
        // [c, b, a]
        keep3(1, 2, 3);
        return triangleCase();
    }
    // acd = ac x ad
    const n2x = acy * adz - acz * ady, n2y = acz * adx - acx * adz, n2z = acx * ady - acy * adx;
    if (n2x * aox + n2y * aoy + n2z * aoz > 0) {
        // [d, c, a]
        keep3(0, 1, 3);
        return triangleCase();
    }
    // adb = ad x ab
    const n3x = ady * abz - adz * aby, n3y = adz * abx - adx * abz, n3z = adx * aby - ady * abx;
    if (n3x * aox + n3y * aoy + n3z * aoz > 0) {
        // [b, d, a]
        keep3(2, 0, 3);
        return triangleCase();
    }
    return true;
}
