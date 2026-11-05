// The quadric error metric behind Decimate's collapse mode.
//
// Garland and Heckbert: a vertex carries the sum of the squared-distance
// forms of the planes of its faces, so collapsing an edge costs the sum of
// the two, evaluated at the point it collapses to. Storing the form (ten
// numbers, symmetric 4x4) rather than the planes keeps the cost of a
// collapse independent of how many faces have already merged into it.
//
// Everything stays in f64; inputs are widened from f32 and the optimum narrowed back.

import { Vec3, Vec4, VEC3_ZERO } from "../../../../../base/vecmath";
import { maxF64, partialCmpF64 } from "../../../../../base/util";

// A symmetric 4x4 in the upper-triangular order `xx xy xz xw yy yz yw zz
// zw ww`. A Quadric is a value: `clone()` before keeping one that
// something else may change; `sum()` already returns a fresh one.
export class Quadric {
    // The ten coefficients.
    q: StaticArray<f64> = new StaticArray<f64>(10);

    // All zero.
    static default(): Quadric {
        return new Quadric();
    }

    static of(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64, i: f64, j: f64): Quadric {
        const out = new Quadric();
        const q = out.q;
        q[0] = a; q[1] = b; q[2] = c; q[3] = d; q[4] = e;
        q[5] = f; q[6] = g; q[7] = h; q[8] = i; q[9] = j;
        return out;
    }

    clone(): Quadric {
        const out = new Quadric();
        for (let k = 0; k < 10; k++) out.q[k] = this.q[k];
        return out;
    }

    // Entrywise f64 ==.
    equals(o: Quadric): bool {
        for (let k = 0; k < 10; k++) {
            if (this.q[k] != o.q[k]) return false;
        }
        return true;
    }

    // The form of the plane through `p` with unit normal `n`.
    static plane(p: Vec3, n0: Vec3): Quadric {
        const n = n0.normalizeOrZero();
        if (n == VEC3_ZERO) {
            return Quadric.default();
        }
        const d = <f64>(-n.dot(p));
        const a = <f64>n.x;
        const b = <f64>n.y;
        const c = <f64>n.z;
        return Quadric.of(a * a, a * b, a * c, a * d, b * b, b * c, b * d, c * c, c * d, d * d);
    }

    // The form weighted by a face's area, which is what makes a large flat
    // wall resist collapsing more than a sliver does.
    static face(p: Vec3, n: Vec3, area: f32): Quadric {
        const q = Quadric.plane(p, n);
        for (let k = 0; k < 10; k++) q.q[k] = q.q[k] * <f64>area;
        return q;
    }

    add(other: Quadric): void {
        for (let k = 0; k < 10; k++) this.q[k] = this.q[k] + other.q[k];
    }

    static sum(a: Quadric, b: Quadric): Quadric {
        const q = a.clone();
        q.add(b);
        return q;
    }

    // `vᵀ Q v`: the squared distance from `v` to the planes this form was
    // built from. Clamped at zero because rounding can take it slightly
    // negative on a perfectly flat neighbourhood, and a negative cost would
    // sort ahead of every real collapse.
    error(v: Vec3): f64 {
        const q = this.q;
        const x = <f64>v.x;
        const y = <f64>v.y;
        const z = <f64>v.z;
        const e = q[0] * x * x
            + 2.0 * q[1] * x * y
            + 2.0 * q[2] * x * z
            + 2.0 * q[3] * x
            + q[4] * y * y
            + 2.0 * q[5] * y * z
            + 2.0 * q[6] * y
            + q[7] * z * z
            + 2.0 * q[8] * z
            + q[9];
        return maxF64(e, 0.0);
    }

    // The point of least error, or `null` when the form is singular — a
    // vertex on a straight edge or a flat plane, where any point along the
    // free direction is as good. The caller then picks among the endpoints
    // and the midpoint, as Blender's decimator does.
    optimum(): QuadricPoint? {
        const q = this.q;
        // The 3x3 block, inverted by cofactors.
        const m00 = q[0], m01 = q[1], m02 = q[2];
        const m10 = q[1], m11 = q[4], m12 = q[5];
        const m20 = q[2], m21 = q[5], m22 = q[7];
        const c00 = m11 * m22 - m12 * m21;
        const c01 = m12 * m20 - m10 * m22;
        const c02 = m10 * m21 - m11 * m20;
        const det = m00 * c00 + m01 * c01 + m02 * c02;
        // Scale-aware: a tiny mesh has a tiny determinant without being
        // degenerate, so compare against the magnitude of the entries.
        let scale: f64 = 0.0;
        scale = maxF64(scale, Math.abs(m00));
        scale = maxF64(scale, Math.abs(m01));
        scale = maxF64(scale, Math.abs(m02));
        scale = maxF64(scale, Math.abs(m10));
        scale = maxF64(scale, Math.abs(m11));
        scale = maxF64(scale, Math.abs(m12));
        scale = maxF64(scale, Math.abs(m20));
        scale = maxF64(scale, Math.abs(m21));
        scale = maxF64(scale, Math.abs(m22));
        // `powi(3)` is (s * s) * s.
        if (Math.abs(det) <= 1e-12 * maxF64(scale * scale * scale, 1e-30)) {
            return null;
        }
        const c10 = m02 * m21 - m01 * m22;
        const c11 = m00 * m22 - m02 * m20;
        const c12 = m01 * m20 - m00 * m21;
        const c20 = m01 * m12 - m02 * m11;
        const c21 = m02 * m10 - m00 * m12;
        const c22 = m00 * m11 - m01 * m10;
        const i00 = c00 / det, i01 = c10 / det, i02 = c20 / det;
        const i10 = c01 / det, i11 = c11 / det, i12 = c21 / det;
        const i20 = c02 / det, i21 = c12 / det, i22 = c22 / det;
        const b0 = -q[3];
        const b1 = -q[6];
        const b2 = -q[8];
        const v = Vec3(
            <f32>(i00 * b0 + i01 * b1 + i02 * b2),
            <f32>(i10 * b0 + i11 * b1 + i12 * b2),
            <f32>(i20 * b0 + i21 * b1 + i22 * b2),
        );
        if (!v.isFinite()) return null;
        const out = new QuadricPoint();
        out.v = v;
        return out;
    }

    // Where to put the merged vertex and what it costs: the optimum when
    // the form allows one, otherwise the cheapest of the two endpoints and
    // their midpoint (the first on ties, as `min_by`).
    bestPosition(a: Vec3, b: Vec3): BestPosition {
        const opt = this.optimum();
        if (opt != null) {
            return new BestPosition(opt.v, this.error(opt.v));
        }
        const cands: Array<Vec3> = [];
        cands.push(a);
        cands.push(b);
        cands.push((a + b) * <f32>0.5);
        let best = new BestPosition(cands[0], this.error(cands[0]));
        for (let k = 1; k < 3; k++) {
            const e = this.error(cands[k]);
            if (partialCmpF64(best.cost, e) > 0) {
                best = new BestPosition(cands[k], e);
            }
        }
        return best;
    }
}

// The point `optimum` found.
export class QuadricPoint {
    v: Vec3 = Vec3(0, 0, 0);
}

// The position `bestPosition` chose and its cost.
export class BestPosition {
    p: Vec3 = Vec3(0, 0, 0);
    cost: f64 = 0;
    constructor(p: Vec3, cost: f64) {
        this.p = p;
        this.cost = cost;
    }
}

// The plane of a triangle from `triPlane`: point, unit normal, area.
export class TriPlane {
    p: Vec3 = Vec3(0, 0, 0);
    n: Vec3 = Vec3(0, 0, 0);
    area: f32 = 0;
}

// The plane of a triangle as (point, unit normal, area), or `null` when it
// has no area.
export function triPlane(a: Vec3, b: Vec3, c: Vec3): TriPlane? {
    const n = (b - a).cross(c - a);
    const len = n.length();
    if (!(len > <f32>1e-12)) return null;
    const out = new TriPlane();
    out.p = a;
    out.n = n / len;
    out.area = len * <f32>0.5;
    return out;
}

// A plane as `Vec4` (`xyz` normal, `w` offset), for callers that want it.
export function planeVec4(p: Vec3, n: Vec3): Vec4 {
    return Vec4(n.x, n.y, n.z, -n.dot(p));
}
