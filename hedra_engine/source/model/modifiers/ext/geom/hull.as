// Convex hull (Blender's Mesh > Convex Hull, `mesh.convex_hull`).
//
// Incremental construction: start from a non-degenerate tetrahedron, then
// add the remaining points one at a time, deleting every face they can see
// and stitching the horizon. Points are added in a fixed order and ties
// break on index, so the same input gives the same hull everywhere.
//
// A triangle is an `Array<u32>` of length 3 (a fresh array per triangle).

import { Vec3, VEC3_ZERO } from "../../../../../base/vecmath";
import { partialCmpF32, swapRemove } from "../../../../../base/util";

function tri3(a: u32, b: u32, c: u32): Array<u32> {
    const t: Array<u32> = [];
    t.push(a);
    t.push(b);
    t.push(c);
    return t;
}

// The hull of `points` as triangles of indices into `points`, wound
// counter-clockwise seen from outside, sorted lexicographically.
//
// Fewer than four points, or points that are all coplanar or collinear,
// have no volume and produce no triangles — the caller decides what that
// means (the operator leaves the mesh alone and says so).
export function convexHull(points: Array<Vec3>, epsilon: f32): Array<Array<u32>> {
    const n = points.length;
    if (n < 4) {
        return [];
    }
    const seed = initialTetra(points, epsilon);
    if (seed == null) {
        return [];
    }
    const a = seed[0];
    const b = seed[1];
    const c = seed[2];
    const d = seed[3];
    // Wound so every face looks outward from the centroid.
    const centroid = (points[<i32>a] + points[<i32>b] + points[<i32>c] + points[<i32>d]) / <f32>4.0;
    const faces: Array<Array<u32>> = [];
    faces.push(orient(tri3(a, b, c), points, centroid));
    faces.push(orient(tri3(a, b, d), points, centroid));
    faces.push(orient(tri3(a, c, d), points, centroid));
    faces.push(orient(tri3(b, c, d), points, centroid));

    for (let ii = 0; ii < n; ii++) {
        const i = <u32>ii;
        if (a == i || b == i || c == i || d == i) {
            continue;
        }
        const p = points[ii];
        // Faces this point is in front of.
        const visible: Array<i32> = [];
        for (let k = 0; k < faces.length; k++) {
            if (signedDist(p, faces[k], points) > epsilon) visible.push(k);
        }
        if (visible.length == 0) {
            continue;
        }
        // The horizon: edges used by exactly one visible face. Keys are
        // `(min, max)` pairs as [lo, hi] in parallel arrays.
        const eu: Array<u32> = [];
        const ev: Array<u32> = [];
        for (let vi = 0; vi < visible.length; vi++) {
            const f = faces[visible[vi]];
            for (let s = 0; s < 3; s++) {
                const e0 = f[s];
                const e1 = f[(s + 1) % 3];
                const k0 = e0 < e1 ? e0 : e1;
                const k1 = e0 < e1 ? e1 : e0;
                let pos = -1;
                for (let x = 0; x < eu.length; x++) {
                    if (eu[x] == k0 && ev[x] == k1) {
                        pos = x;
                        break;
                    }
                }
                if (pos >= 0) {
                    swapRemove<u32>(eu, pos);
                    swapRemove<u32>(ev, pos);
                } else {
                    eu.push(k0);
                    ev.push(k1);
                }
            }
        }
        for (let vi = visible.length - 1; vi >= 0; vi--) {
            swapRemove<Array<u32>>(faces, visible[vi]);
        }
        // A degenerate step can eat every face; rebuilding from a cone with
        // no base would corrupt the hull, so stop rather than go on.
        if (faces.length == 0 && eu.length == 0) {
            return [];
        }
        const hc = hullCentroid(faces, points);
        const inner = hc != null ? hc.v : centroid;
        for (let x = 0; x < eu.length; x++) {
            faces.push(orient(tri3(eu[x], ev[x], i), points, inner));
        }
    }
    // `sort_unstable` on [u32; 3]: lexicographic; distinct faces never tie.
    faces.sort((x: Array<u32>, y: Array<u32>): i32 => {
        for (let k = 0; k < 3; k++) {
            if (x[k] < y[k]) return -1;
            if (x[k] > y[k]) return 1;
        }
        return 0;
    });
    return faces;
}

// Four points that are not collinear or coplanar, or `null`.
function initialTetra(points: Array<Vec3>, epsilon: f32): Array<u32>? {
    const n = points.length;
    if (n == 0) return null;
    // Two extremes along x give the longest guaranteed-distinct pair.
    // `min_by` keeps the first minimum, `max_by` the last maximum.
    let a = 0;
    for (let i = 1; i < n; i++) {
        if (partialCmpF32(points[a].x, points[i].x) > 0) a = i;
    }
    let b = 0;
    for (let i = 1; i < n; i++) {
        if (partialCmpF32(points[b].x, points[i].x) <= 0) b = i;
    }
    if ((points[a] - points[b]).length() <= epsilon) {
        return null;
    }
    const dir = points[b] - points[a];
    let c = -1;
    let cBest: f32 = 0;
    for (let i = 0; i < n; i++) {
        if (i == a || i == b) continue;
        const di = (points[i] - points[a]).cross(dir).length();
        if (c < 0 || partialCmpF32(cBest, di) <= 0) {
            c = i;
            cBest = di;
        }
    }
    if (c < 0) return null;
    let normal = (points[b] - points[a]).cross(points[c] - points[a]);
    if (normal.length() <= epsilon) {
        return null;
    }
    normal = normal.normalize();
    let d = -1;
    let dBest: f32 = 0;
    for (let i = 0; i < n; i++) {
        if (i == a || i == b || i == c) continue;
        const di = Mathf.abs((points[i] - points[a]).dot(normal));
        if (d < 0 || partialCmpF32(dBest, di) <= 0) {
            d = i;
            dBest = di;
        }
    }
    if (d < 0) return null;
    if (Mathf.abs((points[d] - points[a]).dot(normal)) <= epsilon) {
        return null;
    }
    const out: Array<u32> = [];
    out.push(<u32>a);
    out.push(<u32>b);
    out.push(<u32>c);
    out.push(<u32>d);
    return out;
}

function orient(f: Array<u32>, points: Array<Vec3>, inside: Vec3): Array<u32> {
    if (signedDist(inside, f, points) > 0.0) {
        return tri3(f[0], f[2], f[1]);
    }
    return f;
}

// Signed distance of `p` from the plane of face `f` (0 for a degenerate
// face). Exported for the tests.
export function signedDist(p: Vec3, f: Array<u32>, points: Array<Vec3>): f32 {
    const a = points[<i32>f[0]];
    const b = points[<i32>f[1]];
    const c = points[<i32>f[2]];
    const n = (b - a).cross(c - a);
    const len = n.length();
    if (len < <f32>1e-20) {
        return 0.0;
    }
    return (n / len).dot(p - a);
}

// A hull centroid (see `hullCentroid`).
export class HullCentroid {
    v: Vec3 = Vec3(0, 0, 0);
}

// Mean of the face centroids, or `null` without faces. Exported for
// the tests.
export function hullCentroid(faces: Array<Array<u32>>, points: Array<Vec3>): HullCentroid? {
    if (faces.length == 0) {
        return null;
    }
    let sum = VEC3_ZERO;
    for (let k = 0; k < faces.length; k++) {
        const f = faces[k];
        sum += (points[<i32>f[0]] + points[<i32>f[1]] + points[<i32>f[2]]) / <f32>3.0;
    }
    const out = new HullCentroid();
    out.v = sum / <f32>faces.length;
    return out;
}
