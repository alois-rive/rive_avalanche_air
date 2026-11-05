// Minimum-area rectangles of 2D point sets: a convex hull and the rotation
// that boxes it tightest (rotating calipers). It lives with the modelling
// geometry because two callers share it and neither owns the other:
// Hedra's `uv pack` (engine/src/commands/ops/uv/pack.as, which imports and
// re-exports it) and the lightmap unwrapper
// (compiler/src/bake/lightmap/unwrap.as), which turns every chart the same
// way. Plain 2D maths with no render or lightmap dependency, so the
// modelling side reaches it without reaching into the renderer. Bit for bit
// what Hedra did: Apple's sincosf and atan2f, the same ties.

import { Vec2, VEC2_MIN, VEC2_MAX, remEuclidF32 } from "../../../../../base/vecmath";
import { appleSincosf, appleAtan2f } from "../../../../../base/libm";
import { totalCmpF32, stableSort } from "../../../../../base/util";

function cross(o: Vec2, a: Vec2, b: Vec2): f32 {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

// Andrew's monotone chain; returns the hull counter-clockwise.
export function convexHull(points: Array<Vec2>): Array<Vec2> {
    // Stable sort by x then y (total order); structs cannot be generic
    // arguments, so sort indices (stable, same order).
    const xs: Array<f32> = [];
    const ys: Array<f32> = [];
    const idx: Array<i32> = [];
    for (let i = 0; i < points.length; i++) {
        xs.push(points[i].x);
        ys.push(points[i].y);
        idx.push(i);
    }
    stableSort<i32>(idx, (a: i32, b: i32): i32 => {
        const c = totalCmpF32(xs[a], xs[b]);
        return c != 0 ? c : totalCmpF32(ys[a], ys[b]);
    });
    const sorted: Array<Vec2> = [];
    for (let i = 0; i < idx.length; i++) sorted.push(points[idx[i]]);
    // Drop points closer than 1e-9 to the last retained point.
    const pts: Array<Vec2> = [];
    for (let i = 0; i < sorted.length; i++) {
        const p = sorted[i];
        if (pts.length > 0 && p.distance(pts[pts.length - 1]) < <f32>1e-9) continue;
        pts.push(p);
    }
    if (pts.length < 3) return pts;
    const lower: Array<Vec2> = [];
    for (let i = 0; i < pts.length; i++) {
        const p = pts[i];
        while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], p) <= <f32>0.0) {
            lower.pop();
        }
        lower.push(p);
    }
    const upper: Array<Vec2> = [];
    for (let i = pts.length - 1; i >= 0; i--) {
        const p = pts[i];
        while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], p) <= <f32>0.0) {
            upper.pop();
        }
        upper.push(p);
    }
    lower.pop();
    upper.pop();
    for (let i = 0; i < upper.length; i++) lower.push(upper[i]);
    return lower;
}

// Rotate `p` by `angle` radians (exported for the tests; Hedra's `uv rotate`
// operator is `rotate` in its engine/src/commands/ops/uv/mod.as).
export function rotate(p: Vec2, angle: f32): Vec2 {
    // sin/cos as Apple's `__sincosf_stret` computes them, bit for bit.
    const sc = appleSincosf(angle);
    const s = sc.s;
    const c = sc.c;
    return Vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

const FRAC_PI_2: f32 = <f32>1.57079632679489661923132169163975144;

// Rotation (radians) that minimizes the bounding-box area of `points`,
// among the orientations of the hull edges (one of them is optimal).
// Among equal areas the one closest to zero wins, so already-aligned
// islands stay put.
export function bestRotation(points: Array<Vec2>): f32 {
    const hull = convexHull(points);
    if (hull.length < 3) return 0.0;
    let bestArea: f32 = f32.MAX_VALUE;
    let bestAngle: f32 = 0.0;
    for (let i = 0; i < hull.length; i++) {
        const e = hull[(i + 1) % hull.length] - hull[i];
        if (e.lengthSquared() < <f32>1e-18) continue;
        // Rotate so this edge lies along +x; normalize to [-45, 45) degrees
        // since a box is symmetric under quarter turns.
        let angle = -appleAtan2f(e.y, e.x); // Apple's atan2f, bit for bit
        const quarter = FRAC_PI_2;
        angle = remEuclidF32(angle + quarter / <f32>2.0, quarter) - quarter / <f32>2.0;
        let lo = VEC2_MAX;
        let hi = VEC2_MIN;
        for (let k = 0; k < hull.length; k++) {
            const q = rotate(hull[k], angle);
            lo = lo.min(q);
            hi = hi.max(q);
        }
        const area = (hi.x - lo.x) * (hi.y - lo.y);
        const better = area < bestArea - <f32>1e-9
            || (Mathf.abs(area - bestArea) <= <f32>1e-9 && Mathf.abs(angle) < Mathf.abs(bestAngle));
        if (better) {
            bestArea = area;
            bestAngle = angle;
        }
    }
    return Mathf.abs(bestAngle) < <f32>1e-6 ? <f32>0.0 : bestAngle;
}
