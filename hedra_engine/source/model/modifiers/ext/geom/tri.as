// Triangle primitives: closest point, ray hit, and the segment where two
// triangles cross. The boolean solver, shrinkwrap and the convex hull all
// reduce to these.

import { Vec3, VEC3_ZERO } from "../../../../../base/vecmath";
import { minF32, maxF32 } from "../../../../../base/util";

// A triangle carrying the face it came from, so a hit can be traced back
// to the mesh element that produced it.
//
// Nothing mutates a Tri once built, so it is safe to share. `v` always holds exactly three corners.
export class Tri {
    v: Array<Vec3> = [];
    // Index into whatever table the caller built the triangles from
    // (usually a `FaceId`).
    src: u32 = 0;

    static new(a: Vec3, b: Vec3, c: Vec3, src: u32): Tri {
        const t = new Tri();
        t.v.push(a);
        t.v.push(b);
        t.v.push(c);
        t.src = src;
        return t;
    }

    clone(): Tri {
        return Tri.new(this.v[0], this.v[1], this.v[2], this.src);
    }

    normal(): Vec3 {
        return (this.v[1] - this.v[0]).cross(this.v[2] - this.v[0]);
    }

    center(): Vec3 {
        return (this.v[0] + this.v[1] + this.v[2]) / <f32>3.0;
    }

    min(): Vec3 {
        return this.v[0].min(this.v[1]).min(this.v[2]);
    }

    max(): Vec3 {
        return this.v[0].max(this.v[1]).max(this.v[2]);
    }

    area(): f32 {
        return this.normal().length() * <f32>0.5;
    }

    // Barycentric coordinates of a point assumed to lie in the plane.
    // Degenerate triangles answer `(1, 0, 0)` rather than NaN.
    // Returned as a Vec3 (x, y, z = the three weights).
    bary(p: Vec3): Vec3 {
        const v0 = this.v[1] - this.v[0];
        const v1 = this.v[2] - this.v[0];
        const v2 = p - this.v[0];
        const d00 = v0.dot(v0);
        const d01 = v0.dot(v1);
        const d11 = v1.dot(v1);
        const d20 = v2.dot(v0);
        const d21 = v2.dot(v1);
        const denom = d00 * d11 - d01 * d01;
        if (Mathf.abs(denom) < <f32>1e-20) {
            return Vec3(1.0, 0.0, 0.0);
        }
        const v = (d11 * d20 - d01 * d21) / denom;
        const w = (d00 * d21 - d01 * d20) / denom;
        return Vec3(<f32>1.0 - v - w, v, w);
    }
}

// The point of `t` closest to `p` — inside the triangle, on an edge, or at
// a corner. Ericson's region test, which needs no square roots.
export function closestPointOnTri(p: Vec3, t: Tri): Vec3 {
    const a = t.v[0];
    const b = t.v[1];
    const c = t.v[2];
    const ab = b - a;
    const ac = c - a;
    const ap = p - a;
    const d1 = ab.dot(ap);
    const d2 = ac.dot(ap);
    if (d1 <= 0.0 && d2 <= 0.0) {
        return a;
    }
    const bp = p - b;
    const d3 = ab.dot(bp);
    const d4 = ac.dot(bp);
    if (d3 >= 0.0 && d4 <= d3) {
        return b;
    }
    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        return a + ab * (d1 / (d1 - d3));
    }
    const cp = p - c;
    const d5 = ab.dot(cp);
    const d6 = ac.dot(cp);
    if (d6 >= 0.0 && d5 <= d6) {
        return c;
    }
    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        return a + ac * (d2 / (d2 - d6));
    }
    const va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
        return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)));
    }
    const denom = <f32>1.0 / (va + vb + vc);
    return a + ab * (vb * denom) + ac * (vc * denom);
}

// Möller-Trumbore, both faces. Returns the ray parameter `t` of the hit,
// or NaN for no hit (a hit is always > EPS, so NaN is unambiguous).
export function rayTri(origin: Vec3, dir: Vec3, t: Tri): f32 {
    const EPS: f32 = 1e-9;
    const e1 = t.v[1] - t.v[0];
    const e2 = t.v[2] - t.v[0];
    const h = dir.cross(e2);
    const a = e1.dot(h);
    if (Mathf.abs(a) < EPS) {
        return <f32>NaN;
    }
    const f = <f32>1.0 / a;
    const s = origin - t.v[0];
    const u = f * s.dot(h);
    // `!(-EPS..=1.0 + EPS).contains(&u)`: NaN is not contained.
    if (!(u >= -EPS && u <= <f32>1.0 + EPS)) {
        return <f32>NaN;
    }
    const q = s.cross(e1);
    const v = f * dir.dot(q);
    if (v < -EPS || u + v > <f32>1.0 + EPS) {
        return <f32>NaN;
    }
    const dist = f * e2.dot(q);
    return dist > EPS ? dist : <f32>NaN;
}

// The segment where two triangles cross (see triTriIntersect): the two ends.
export class TriSegment {
    p: Vec3 = Vec3(0, 0, 0);
    q: Vec3 = Vec3(0, 0, 0);
    constructor(p: Vec3, q: Vec3) {
        this.p = p;
        this.q = q;
    }
}

const TT_EPS: f32 = 1e-7;

// Interval of one triangle along the intersection line. `ok == false`
// means there is none.
class Interval {
    ok: bool = false;
    lo: f32 = 0;
    hi: f32 = 0;
}

function interval(dir: Vec3, t: Tri, d: StaticArray<f32>): Interval {
    let lo: f32 = Infinity;
    let hi: f32 = -Infinity;
    let hits = 0;
    for (let i = 0; i < 3; i++) {
        const j = (i + 1) % 3;
        const di = d[i];
        const dj = d[j];
        if (Mathf.abs(di) <= TT_EPS) {
            const v = dir.dot(t.v[i]);
            lo = minF32(lo, v);
            hi = maxF32(hi, v);
            hits += 1;
        }
        if ((di > TT_EPS && dj < -TT_EPS) || (di < -TT_EPS && dj > TT_EPS)) {
            const s = di / (di - dj);
            const v = dir.dot(t.v[i] + (t.v[j] - t.v[i]) * s);
            lo = minF32(lo, v);
            hi = maxF32(hi, v);
            hits += 1;
        }
    }
    const out = new Interval();
    out.ok = hits >= 2;
    out.lo = lo;
    out.hi = hi;
    return out;
}

function allAbove(d: StaticArray<f32>, eps: f32): bool {
    return d[0] > eps && d[1] > eps && d[2] > eps;
}

function allBelow(d: StaticArray<f32>, eps: f32): bool {
    return d[0] < -eps && d[1] < -eps && d[2] < -eps;
}

// The segment along which two triangles cross, or `null` when they miss or
// are coplanar.
//
// Coplanar pairs are deliberately not reported: a boolean between two
// meshes that share a flat wall would otherwise produce a tangle of
// zero-area cuts, and Blender's exact solver resolves those by winding
// instead. The BVH finds the candidate pairs; this decides whether they
// really meet.
export function triTriIntersect(a: Tri, b: Tri): TriSegment? {
    const na = a.normal().normalizeOrZero();
    const nb = b.normal().normalizeOrZero();
    if (na == VEC3_ZERO || nb == VEC3_ZERO) {
        return null;
    }
    const da = new StaticArray<f32>(3);
    const db = new StaticArray<f32>(3);
    for (let i = 0; i < 3; i++) {
        da[i] = nb.dot(b.v[0] - a.v[i]);
        db[i] = na.dot(a.v[0] - b.v[i]);
    }
    // All on one side of the other's plane: no crossing. The epsilon is
    // absolute because the meshes a boolean runs on are modelling-scale.
    if (allAbove(da, TT_EPS) || allBelow(da, TT_EPS)) {
        return null;
    }
    if (allAbove(db, TT_EPS) || allBelow(db, TT_EPS)) {
        return null;
    }
    // Coplanar.
    if (Mathf.abs(da[0]) <= TT_EPS && Mathf.abs(da[1]) <= TT_EPS && Mathf.abs(da[2]) <= TT_EPS) {
        return null;
    }
    const dir = na.cross(nb);
    if (dir.lengthSquared() < <f32>1e-20) {
        return null;
    }
    // Each triangle meets the intersection line in an interval; the overlap
    // of the two intervals is the segment.
    const ia = interval(dir, a, da);
    if (!ia.ok) return null;
    const ib = interval(dir, b, db);
    if (!ib.ok) return null;
    const lo = maxF32(ia.lo, ib.lo);
    const hi = minF32(ia.hi, ib.hi);
    if (lo > hi) {
        return null;
    }
    // Back from the line parameter to points: pick any point on the line.
    const denom = dir.lengthSquared();
    if (denom < <f32>1e-20) {
        return null;
    }
    const p0 = linePoint(a.v[0], na, b.v[0], nb, dir);
    const base = dir.dot(p0);
    const d2 = dir.lengthSquared();
    const p = p0 + dir * ((lo - base) / d2);
    const q = p0 + dir * ((hi - base) / d2);
    return new TriSegment(p, q);
}

// A point on the line where two planes meet. The caller has checked that
// `dir` is not degenerate (triTriIntersect makes the same check first, so
// there is no failure case here).
function linePoint(pa: Vec3, na: Vec3, pb: Vec3, nb: Vec3, dir: Vec3): Vec3 {
    const da = na.dot(pa);
    const db = nb.dot(pb);
    const denom = dir.lengthSquared();
    return (dir.cross(nb) * da + na.cross(dir) * db) / denom;
}
