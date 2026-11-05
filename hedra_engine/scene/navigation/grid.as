// Derived from Godot Engine 4.4 (MIT); see THIRD_PARTY_NOTICES.md.
//
// The navigation map's spatial index and the geometry its queries use
// (docs/engine/NAVIGATION.md "The map"): a uniform grid over the polygons'
// boxes on x and z, which the closest-point queries (the start and end
// polygons of a path, getClosestPoint, a link's ends, an agent held to the
// mesh) walk ring by ring outwards from the point's cell instead of
// testing every polygon, and the exact point-to-triangle, point-to-segment
// and segment-to-segment answers Godot's Face3 and Geometry3D give.
//
// The grid's cell is max(4 x cell_size, the polygons' mean box side), so a
// polygon sits in a few cells and a cell holds a few polygons whatever the
// bake's resolution; a grid of more cells than 4 x polygons + 64 is made
// coarser until it fits (a map of a few large polygons spread far apart).
// It is made again by each rebuild of the map (./map.as), its arrays
// grown, never shrunk: a map rebuilt as it was allocates nothing.
//
// Everything here is f64 scalar arithmetic on numbers read from the map's
// arrays (Godot's is f32 real_t: the answers agree to the f32 the paths
// are given in), and writes its answers into arrays the caller passes, so
// a query allocates nothing.

// Godot's CMP_EPSILON (core/math/math_defs.h).
export const NAV_CMP_EPSILON: f64 = 0.00001;

// Godot's Math::is_equal_approx(a, b): equal within CMP_EPSILON, relative
// to |a| past 1.
export function navEqualApprox(a: f64, b: f64): bool {
    if (a == b) return true;
    let tolerance = NAV_CMP_EPSILON * Math.abs(a);
    if (tolerance < NAV_CMP_EPSILON) tolerance = NAV_CMP_EPSILON;
    return Math.abs(a - b) < tolerance;
}

// Godot's Vector3::is_equal_approx.
export function navPointsEqualApprox(ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64): bool {
    return navEqualApprox(ax, bx) && navEqualApprox(ay, by) && navEqualApprox(az, bz);
}

// The point of the triangle (a, b, c) nearest p, into out[0..3); returns
// its squared distance to p. Ericson's ClosestPtPointTriangle (Real-Time
// Collision Detection, 5.1.5), the answer Godot's Face3::get_closest_point_to
// gives; a degenerate triangle answers the nearest point of its edges.
export function closestOnTriangle(px: f64, py: f64, pz: f64, ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64,
    cx: f64, cy: f64, cz: f64, out: StaticArray<f64>): f64 {
    const abx = bx - ax, aby = by - ay, abz = bz - az;
    const acx = cx - ax, acy = cy - ay, acz = cz - az;
    const apx = px - ax, apy = py - ay, apz = pz - az;
    const d1 = abx * apx + aby * apy + abz * apz;
    const d2 = acx * apx + acy * apy + acz * apz;
    let rx: f64, ry: f64, rz: f64;
    if (d1 <= 0 && d2 <= 0) {
        rx = ax;
        ry = ay;
        rz = az;
    } else {
        const bpx = px - bx, bpy = py - by, bpz = pz - bz;
        const d3 = abx * bpx + aby * bpy + abz * bpz;
        const d4 = acx * bpx + acy * bpy + acz * bpz;
        if (d3 >= 0 && d4 <= d3) {
            rx = bx;
            ry = by;
            rz = bz;
        } else {
            const vc = d1 * d4 - d3 * d2;
            if (vc <= 0 && d1 >= 0 && d3 <= 0) {
                const v = d1 - d3 != 0 ? d1 / (d1 - d3) : 0;
                rx = ax + abx * v;
                ry = ay + aby * v;
                rz = az + abz * v;
            } else {
                const cpx = px - cx, cpy = py - cy, cpz = pz - cz;
                const d5 = abx * cpx + aby * cpy + abz * cpz;
                const d6 = acx * cpx + acy * cpy + acz * cpz;
                if (d6 >= 0 && d5 <= d6) {
                    rx = cx;
                    ry = cy;
                    rz = cz;
                } else {
                    const vb = d5 * d2 - d1 * d6;
                    if (vb <= 0 && d2 >= 0 && d6 <= 0) {
                        const w = d2 - d6 != 0 ? d2 / (d2 - d6) : 0;
                        rx = ax + acx * w;
                        ry = ay + acy * w;
                        rz = az + acz * w;
                    } else {
                        const va = d3 * d6 - d5 * d4;
                        if (va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0) {
                            const den = (d4 - d3) + (d5 - d6);
                            const w = den != 0 ? (d4 - d3) / den : 0;
                            rx = bx + (cx - bx) * w;
                            ry = by + (cy - by) * w;
                            rz = bz + (cz - bz) * w;
                        } else {
                            const sum = va + vb + vc;
                            if (sum == 0) {
                                // (a degenerate triangle: its nearest edge point)
                                return closestOnDegenerate(px, py, pz, ax, ay, az, bx, by, bz, cx, cy, cz, out);
                            }
                            const denom = 1 / sum;
                            const v = vb * denom;
                            const w = vc * denom;
                            rx = ax + abx * v + acx * w;
                            ry = ay + aby * v + acy * w;
                            rz = az + abz * v + acz * w;
                        }
                    }
                }
            }
        }
    }
    unchecked(out[0] = rx);
    unchecked(out[1] = ry);
    unchecked(out[2] = rz);
    const dx = rx - px, dy = ry - py, dz = rz - pz;
    return dx * dx + dy * dy + dz * dz;
}

function closestOnDegenerate(px: f64, py: f64, pz: f64, ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64,
    cx: f64, cy: f64, cz: f64, out: StaticArray<f64>): f64 {
    let best = closestOnSegment(px, py, pz, ax, ay, az, bx, by, bz, out);
    let x = unchecked(out[0]), y = unchecked(out[1]), z = unchecked(out[2]);
    const d2 = closestOnSegment(px, py, pz, bx, by, bz, cx, cy, cz, out);
    if (d2 < best) {
        best = d2;
        x = unchecked(out[0]);
        y = unchecked(out[1]);
        z = unchecked(out[2]);
    }
    const d3 = closestOnSegment(px, py, pz, cx, cy, cz, ax, ay, az, out);
    if (d3 < best) {
        best = d3;
        x = unchecked(out[0]);
        y = unchecked(out[1]);
        z = unchecked(out[2]);
    }
    unchecked(out[0] = x);
    unchecked(out[1] = y);
    unchecked(out[2] = z);
    return best;
}

// Godot's Geometry3D::get_closest_point_to_segment: the point of the
// segment (a, b) nearest p, into out[0..3); returns its squared distance.
// A segment shorter than 1e-10 m answers a.
export function closestOnSegment(px: f64, py: f64, pz: f64, ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64,
    out: StaticArray<f64>): f64 {
    const nx = bx - ax, ny = by - ay, nz = bz - az;
    const l2 = nx * nx + ny * ny + nz * nz;
    let rx = ax, ry = ay, rz = az;
    if (l2 >= 1e-20) {
        const d = ((px - ax) * nx + (py - ay) * ny + (pz - az) * nz) / l2;
        if (d >= 1) {
            rx = bx;
            ry = by;
            rz = bz;
        } else if (d > 0) {
            rx = ax + nx * d;
            ry = ay + ny * d;
            rz = az + nz * d;
        }
    }
    unchecked(out[0] = rx);
    unchecked(out[1] = ry);
    unchecked(out[2] = rz);
    const dx = rx - px, dy = ry - py, dz = rz - pz;
    return dx * dx + dy * dy + dz * dz;
}

// Godot's Geometry3D::segment_intersects_triangle (Möller-Trumbore on the
// segment from `f` to `t`): whether it meets the triangle, the point into
// out[0..3) and its fraction along the segment into out[3].
export function segmentMeetsTriangle(fx: f64, fy: f64, fz: f64, tx: f64, ty: f64, tz: f64, ax: f64, ay: f64, az: f64,
    bx: f64, by: f64, bz: f64, cx: f64, cy: f64, cz: f64, out: StaticArray<f64>): bool {
    const rx = tx - fx, ry = ty - fy, rz = tz - fz;
    const e1x = bx - ax, e1y = by - ay, e1z = bz - az;
    const e2x = cx - ax, e2y = cy - ay, e2z = cz - az;
    // h = rel x e2
    const hx = ry * e2z - rz * e2y;
    const hy = rz * e2x - rx * e2z;
    const hz = rx * e2y - ry * e2x;
    const a = e1x * hx + e1y * hy + e1z * hz;
    if (a > -NAV_CMP_EPSILON && a < NAV_CMP_EPSILON) return false;
    const f = 1.0 / a;
    const sx = fx - ax, sy = fy - ay, sz = fz - az;
    const u = f * (sx * hx + sy * hy + sz * hz);
    if (u < 0 || u > 1) return false;
    // q = s x e1
    const qx = sy * e1z - sz * e1y;
    const qy = sz * e1x - sx * e1z;
    const qz = sx * e1y - sy * e1x;
    const v = f * (rx * qx + ry * qy + rz * qz);
    if (v < 0 || u + v > 1) return false;
    const t = f * (e2x * qx + e2y * qy + e2z * qz);
    if (t < 0 || t > 1) return false;
    unchecked(out[0] = fx + rx * t);
    unchecked(out[1] = fy + ry * t);
    unchecked(out[2] = fz + rz * t);
    unchecked(out[3] = t);
    return true;
}

// Godot's Geometry3D::get_closest_points_between_segments (Ericson's
// ClosestPtSegmentSegment, 5.1.9): the nearest points of (p1, q1) and
// (p2, q2), into out[0..3) and out[3..6); returns their squared distance.
export function closestBetweenSegments(p1x: f64, p1y: f64, p1z: f64, q1x: f64, q1y: f64, q1z: f64, p2x: f64, p2y: f64,
    p2z: f64, q2x: f64, q2y: f64, q2z: f64, out: StaticArray<f64>): f64 {
    const d1x = q1x - p1x, d1y = q1y - p1y, d1z = q1z - p1z;
    const d2x = q2x - p2x, d2y = q2y - p2y, d2z = q2z - p2z;
    const rx = p1x - p2x, ry = p1y - p2y, rz = p1z - p2z;
    const a = d1x * d1x + d1y * d1y + d1z * d1z;
    const e = d2x * d2x + d2y * d2y + d2z * d2z;
    const f = d2x * rx + d2y * ry + d2z * rz;
    let s: f64 = 0;
    let t: f64 = 0;
    const tiny: f64 = 1e-20;
    if (a <= tiny && e <= tiny) {
        s = 0;
        t = 0;
    } else if (a <= tiny) {
        s = 0;
        t = clamp01(f / e);
    } else {
        const c = d1x * rx + d1y * ry + d1z * rz;
        if (e <= tiny) {
            t = 0;
            s = clamp01(-c / a);
        } else {
            const b = d1x * d2x + d1y * d2y + d1z * d2z;
            const denom = a * e - b * b;
            s = denom != 0 ? clamp01((b * f - c * e) / denom) : 0;
            t = (b * s + f) / e;
            if (t < 0) {
                t = 0;
                s = clamp01(-c / a);
            } else if (t > 1) {
                t = 1;
                s = clamp01((b - c) / a);
            }
        }
    }
    const c1x = p1x + d1x * s, c1y = p1y + d1y * s, c1z = p1z + d1z * s;
    const c2x = p2x + d2x * t, c2y = p2y + d2y * t, c2z = p2z + d2z * t;
    unchecked(out[0] = c1x);
    unchecked(out[1] = c1y);
    unchecked(out[2] = c1z);
    unchecked(out[3] = c2x);
    unchecked(out[4] = c2y);
    unchecked(out[5] = c2z);
    const dx = c1x - c2x, dy = c1y - c2y, dz = c1z - c2z;
    return dx * dx + dy * dy + dz * dz;
}

function clamp01(v: f64): f64 {
    return v < 0 ? 0 : v > 1 ? 1 : v;
}

// The typed arrays the map and its scratch grow (never shrink): `a` when it
// holds `n` already, else a new one of max(n, twice its length).
export function grownF64(a: Float64Array, n: i32): Float64Array {
    if (a.length >= n) return a;
    return new Float64Array(max<i32>(n, a.length * 2));
}

export function grownI32(a: Int32Array, n: i32): Int32Array {
    if (a.length >= n) return a;
    return new Int32Array(max<i32>(n, a.length * 2));
}

export function grownU32(a: Uint32Array, n: i32): Uint32Array {
    if (a.length >= n) return a;
    return new Uint32Array(max<i32>(n, a.length * 2));
}

export function grownU8(a: Uint8Array, n: i32): Uint8Array {
    if (a.length >= n) return a;
    return new Uint8Array(max<i32>(n, a.length * 2));
}

// `a` grown to `n` keeping its first `keep` numbers (a list built a push at
// a time).
export function keptF64(a: Float64Array, n: i32, keep: i32): Float64Array {
    if (a.length >= n) return a;
    const b = new Float64Array(max<i32>(n, a.length * 2));
    for (let i = 0; i < keep; i++) unchecked(b[i] = a[i]);
    return b;
}

export function keptI32(a: Int32Array, n: i32, keep: i32): Int32Array {
    if (a.length >= n) return a;
    const b = new Int32Array(max<i32>(n, a.length * 2));
    for (let i = 0; i < keep; i++) unchecked(b[i] = a[i]);
    return b;
}

export function keptU8(a: Uint8Array, n: i32, keep: i32): Uint8Array {
    if (a.length >= n) return a;
    const b = new Uint8Array(max<i32>(n, a.length * 2));
    for (let i = 0; i < keep; i++) unchecked(b[i] = a[i]);
    return b;
}

// The most cells a grid may have, for `count` polygons.
function cellBudget(count: i32): i32 {
    return count * 4 + 64;
}

// A uniform grid over boxes on x and z (see the header). `boxes` holds six
// numbers a polygon: min x, y, z, max x, y, z.
export class NavGrid {
    // The grid's corner (min x, min z), its cell side and its cells across
    // (x) and deep (z); 0 x 0 for no polygon.
    originX: f64 = 0;
    originZ: f64 = 0;
    cell: f64 = 1;
    width: i32 = 0;
    depth: i32 = 0;
    // CSR: cell c's polygons are items[starts[c] .. starts[c + 1]), each
    // polygon in every cell its box overlaps, in polygon order.
    starts: Int32Array = new Int32Array(1);
    items: Int32Array = new Int32Array(0);
    private cursor: Int32Array = new Int32Array(0);

    // Made again over `count` polygons' `boxes`, the least cell
    // `minCell` (4 x cell_size).
    build(boxes: Float64Array, count: i32, minCell: f64): void {
        if (count == 0) {
            this.width = 0;
            this.depth = 0;
            this.starts = grownI32(this.starts, 1);
            unchecked(this.starts[0] = 0);
            return;
        }
        let lx = Infinity, lz = Infinity, hx = -Infinity, hz = -Infinity;
        let sides: f64 = 0;
        for (let k = 0; k < count; k++) {
            const o = k * 6;
            const ax = unchecked(boxes[o]), az = unchecked(boxes[o + 2]);
            const bx = unchecked(boxes[o + 3]), bz = unchecked(boxes[o + 5]);
            if (ax < lx) lx = ax;
            if (az < lz) lz = az;
            if (bx > hx) hx = bx;
            if (bz > hz) hz = bz;
            sides += ((bx - ax) + (bz - az)) * 0.5;
        }
        let cell = sides / <f64>count;
        if (!(cell > minCell)) cell = minCell;
        if (!(cell > 1e-6)) cell = 1e-6;
        // (counted in f64 until they fit the budget: regions far apart
        // give more columns than an i32 holds, and the conversion of such
        // a number would trap)
        let fw = Math.floor((hx - lx) / cell) + 1;
        let fd = Math.floor((hz - lz) / cell) + 1;
        const budget = <f64>cellBudget(count);
        while (fw * fd > budget) {
            cell *= 2;
            fw = Math.floor((hx - lx) / cell) + 1;
            fd = Math.floor((hz - lz) / cell) + 1;
        }
        const w = <i32>fw;
        const d = <i32>fd;
        this.originX = lx;
        this.originZ = lz;
        this.cell = cell;
        this.width = w;
        this.depth = d;
        const cells = w * d;
        this.starts = grownI32(this.starts, cells + 1);
        this.cursor = grownI32(this.cursor, cells);
        const starts = this.starts;
        for (let c = 0; c <= cells; c++) unchecked(starts[c] = 0);
        let total = 0;
        for (let k = 0; k < count; k++) {
            const o = k * 6;
            const x0 = this.colOf(unchecked(boxes[o])), x1 = this.colOf(unchecked(boxes[o + 3]));
            const z0 = this.rowOf(unchecked(boxes[o + 2])), z1 = this.rowOf(unchecked(boxes[o + 5]));
            for (let z = z0; z <= z1; z++) {
                for (let x = x0; x <= x1; x++) {
                    unchecked(starts[z * w + x + 1] += 1);
                    total++;
                }
            }
        }
        for (let c = 0; c < cells; c++) unchecked(starts[c + 1] += starts[c]);
        this.items = grownI32(this.items, total);
        const cursor = this.cursor;
        for (let c = 0; c < cells; c++) unchecked(cursor[c] = starts[c]);
        const items = this.items;
        for (let k = 0; k < count; k++) {
            const o = k * 6;
            const x0 = this.colOf(unchecked(boxes[o])), x1 = this.colOf(unchecked(boxes[o + 3]));
            const z0 = this.rowOf(unchecked(boxes[o + 2])), z1 = this.rowOf(unchecked(boxes[o + 5]));
            for (let z = z0; z <= z1; z++) {
                for (let x = x0; x <= x1; x++) {
                    const c = z * w + x;
                    unchecked(items[cursor[c]] = k);
                    unchecked(cursor[c] += 1);
                }
            }
        }
    }

    // The column of x within the grid (clamped).
    // (clamped before the conversion, which traps on a NaN or a number
    // outside the i32 range; a NaN takes the first cell)
    colOf(x: f64): i32 {
        const c = Math.floor((x - this.originX) / this.cell);
        return !(c >= 0) ? 0 : c >= <f64>this.width ? this.width - 1 : <i32>c;
    }

    rowOf(z: f64): i32 {
        const r = Math.floor((z - this.originZ) / this.cell);
        return !(r >= 0) ? 0 : r >= <f64>this.depth ? this.depth - 1 : <i32>r;
    }

    // The column and row of x and z, not clamped (a point outside the grid;
    // a NaN is taken as one far before the first cell).
    rawCol(x: f64): i32 {
        const c = Math.floor((x - this.originX) / this.cell);
        return !(c >= -1e8) ? -100000000 : c > 1e8 ? 100000000 : <i32>c;
    }

    rawRow(z: f64): i32 {
        const r = Math.floor((z - this.originZ) / this.cell);
        return !(r >= -1e8) ? -100000000 : r > 1e8 ? 100000000 : <i32>r;
    }
}
