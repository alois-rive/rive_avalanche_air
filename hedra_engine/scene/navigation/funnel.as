// Derived from Godot Engine 4.4 (MIT); see THIRD_PARTY_NOTICES.md.
//
// A path's points from the polygons a search went through (docs/engine/
// NAVIGATION.md "Paths"): Godot 4.4's three post-processings and its
// simplification (modules/navigation/3d/nav_mesh_queries_3d.cpp
// _query_task_post_process_corridorfunnel, _edgecentered,
// _nopostprocessing, _query_task_clip_path, get_simplified_path_indices),
// over the way back a search left in its scratch (./astar.as: each node's
// back node, back edge and the pathway it was entered by).
//
//   - corridorfunnel (Godot's default): string pulling through the
//     pathways, from the end back to the start, in the plane seen from the
//     map's up (+Y), with Godot's clipping: where a straight step between
//     two corners crosses a pathway, the point where it crosses is kept (at
//     the pathway's height), so the path follows ramps and steps rather
//     than cutting through them, and a straight path over flat ground has a
//     point on each edge it crosses, as Godot's does (simplify_path leaves
//     them out); a corner is never kept twice in a row (Hedra's: Godot's
//     can be, see pushApex);
//   - edgecentered: the middle of each edge crossed (a link's point for a
//     link);
//   - none: each polygon's entry point.
//
// Each writes the points into the scratch from the end to the start, as
// Godot's do, each with the node it lies on (for the path's metadata); the
// caller reverses them (NavQueryScratch.reverse). simplifyPathInto then
// keeps Godot's Ramer-Douglas-Peucker subset. Nothing is allocated.

import { NavGraph, NavQueryScratch } from "./astar";
import { closestOnSegment, navPointsEqualApprox } from "./grid";

// Godot's THREE_POINTS_CROSS_PRODUCT(a, b, c).dot(up) for up = +Y:
// ((c - a) x (b - a)).y.
function crossUp(ax: f64, az: f64, bx: f64, bz: f64, cx: f64, cz: f64): f64 {
    const ux = cx - ax, uz = cz - az;
    const vx = bx - ax, vz = bz - az;
    return uz * vx - ux * vz;
}

// The corridor funnel from node `endNode` (the end point s.ex/ey/ez) back
// to node `beginNode` (s.bx/by/bz).
export function corridorFunnelInto(gr: NavGraph, s: NavQueryScratch, endNode: i32, beginNode: i32): void {
    s.count = 0;
    const back = s.back;
    const bp = s.backPath;
    const ex = s.ex, ey = s.ey, ez = s.ez;
    let apexPoly = endNode;
    // (the end point on the last pathway crossed: funnelling round its
    // corners would at best do nothing, at worst add a point before the
    // last, so the funnel starts a polygon back)
    {
        const o = apexPoly * 6;
        closestOnSegment(ex, ey, ez, unchecked(bp[o]), unchecked(bp[o + 1]), unchecked(bp[o + 2]), unchecked(bp[o + 3]),
            unchecked(bp[o + 4]), unchecked(bp[o + 5]), s.tmp);
        if (navPointsEqualApprox(ex, ey, ez, unchecked(s.tmp[0]), unchecked(s.tmp[1]), unchecked(s.tmp[2]))) {
            const b = unchecked(back[apexPoly]);
            if (b != -1) apexPoly = b;
        }
    }
    let apexX = ex, apexY = ey, apexZ = ez;
    let leftPoly = apexPoly;
    let lpx = apexX, lpy = apexY, lpz = apexZ;
    let rightPoly = apexPoly;
    let rpx = apexX, rpy = apexY, rpz = apexZ;
    let p = apexPoly;
    s.push(ex, ey, ez, endNode);
    while (p != -1) {
        const o = p * 6;
        let lx = unchecked(bp[o]), ly = unchecked(bp[o + 1]), lz = unchecked(bp[o + 2]);
        let rx = unchecked(bp[o + 3]), ry = unchecked(bp[o + 4]), rz = unchecked(bp[o + 5]);
        if (crossUp(apexX, apexZ, lx, lz, rx, rz) < 0) {
            const tx = lx, ty = ly, tz = lz;
            lx = rx;
            ly = ry;
            lz = rz;
            rx = tx;
            ry = ty;
            rz = tz;
        }
        let skip = false;
        if (crossUp(apexX, apexZ, lpx, lpz, lx, lz) >= 0) {
            const leftAtApex = lpx == apexX && lpy == apexY && lpz == apexZ;
            if (leftAtApex || crossUp(apexX, apexZ, lx, lz, rpx, rpz) > 0) {
                leftPoly = p;
                lpx = lx;
                lpy = ly;
                lpz = lz;
            } else {
                clipPathInto(s, apexPoly, rpx, rpy, rpz, rightPoly);
                apexX = rpx;
                apexY = rpy;
                apexZ = rpz;
                p = rightPoly;
                leftPoly = p;
                apexPoly = p;
                lpx = apexX;
                lpy = apexY;
                lpz = apexZ;
                rpx = apexX;
                rpy = apexY;
                rpz = apexZ;
                pushApex(s, apexX, apexY, apexZ, apexPoly);
                skip = true;
            }
        }
        if (!skip && crossUp(apexX, apexZ, rpx, rpz, rx, rz) <= 0) {
            const rightAtApex = rpx == apexX && rpy == apexY && rpz == apexZ;
            if (rightAtApex || crossUp(apexX, apexZ, rx, rz, lpx, lpz) < 0) {
                rightPoly = p;
                rpx = rx;
                rpy = ry;
                rpz = rz;
            } else {
                clipPathInto(s, apexPoly, lpx, lpy, lpz, leftPoly);
                apexX = lpx;
                apexY = lpy;
                apexZ = lpz;
                p = leftPoly;
                rightPoly = p;
                apexPoly = p;
                rpx = apexX;
                rpy = apexY;
                rpz = apexZ;
                lpx = apexX;
                lpy = apexY;
                lpz = apexZ;
                pushApex(s, apexX, apexY, apexZ, apexPoly);
            }
        }
        p = unchecked(back[p]);
    }
    // (the begin point last, unless the funnel ended on it)
    if (s.lastX() != s.bx || s.lastY() != s.by || s.lastZ() != s.bz) s.push(s.bx, s.by, s.bz, beginNode);
}

// An apex point, unless it is the last point again (Hedra's: Godot's
// funnel pushes a corner twice when the pathway after it starts at that
// corner, as it does round a vertex shared by consecutive portals, which
// gives an agent a waypoint of no length).
function pushApex(s: NavQueryScratch, x: f64, y: f64, z: f64, node: i32): void {
    if (s.count > 0 && navPointsEqualApprox(x, y, z, s.lastX(), s.lastY(), s.lastZ())) return;
    s.push(x, y, z, node);
}

// Godot's _query_task_clip_path: the points where the straight step from
// the last point to (tx, ty, tz) crosses the pathways of the polygons from
// `fromPoly` back to `toPoly`, cut by the vertical plane through the step.
function clipPathInto(s: NavQueryScratch, fromPoly: i32, tx: f64, ty: f64, tz: f64, toPoly: i32): void {
    const fx = s.lastX(), fy = s.lastY(), fz = s.lastZ();
    if (navPointsEqualApprox(fx, fy, fz, tx, ty, tz)) return;
    // (the cut plane's normal: (from - to) x up, up = +Y)
    const ax = fx - tx, az = fz - tz;
    let nx = -az;
    let nz = ax;
    if (nx == 0 && nz == 0) return;
    const len = Math.sqrt(nx * nx + nz * nz);
    nx /= len;
    nz /= len;
    const d = nx * fx + nz * fz;
    const back = s.back;
    const bp = s.backPath;
    let poly = fromPoly;
    while (poly != toPoly) {
        const o = poly * 6;
        const sx = unchecked(bp[o]), sy = unchecked(bp[o + 1]), sz = unchecked(bp[o + 2]);
        const qx = unchecked(bp[o + 3]), qy = unchecked(bp[o + 4]), qz = unchecked(bp[o + 5]);
        const prev = unchecked(back[poly]);
        if (prev == -1) return;
        poly = prev;
        if (navPointsEqualApprox(sx, sy, sz, qx, qy, qz)) continue;
        // (Godot's Plane::intersects_segment)
        const gx = sx - qx, gz = sz - qz;
        const gy = sy - qy;
        const den = nx * gx + nz * gz;
        if (Math.abs(den) < 0.00001) continue;
        let dist = (nx * sx + nz * sz - d) / den;
        if (dist < -0.00001 || dist > 1.00001) continue;
        dist = -dist;
        const ix = sx + gx * dist, iy = sy + gy * dist, iz = sz + gz * dist;
        if (navPointsEqualApprox(ix, iy, iz, tx, ty, tz)) continue;
        if (navPointsEqualApprox(ix, iy, iz, s.lastX(), s.lastY(), s.lastZ())) continue;
        s.push(ix, iy, iz, poly);
    }
}

// The middle of each edge crossed from `endNode` back to `beginNode`
// (Godot's edgecentered: a link's way, which has no edge, its entry).
export function edgeCenteredInto(gr: NavGraph, s: NavQueryScratch, endNode: i32, beginNode: i32): void {
    s.count = 0;
    s.push(s.ex, s.ey, s.ez, endNode);
    const back = s.back;
    let np = endNode;
    while (np != -1 && unchecked(back[np]) != -1) {
        const edge = unchecked(s.backEdge[np]);
        if (edge != -1) {
            const a = unchecked(gr.cornerStart[np]);
            const n = unchecked(gr.cornerStart[np + 1]) - a;
            const i0 = a + edge;
            const i1 = a + (edge + 1) % n;
            s.push((unchecked(gr.px[i0]) + unchecked(gr.px[i1])) * 0.5, (unchecked(gr.py[i0]) + unchecked(gr.py[i1])) * 0.5,
                (unchecked(gr.pz[i0]) + unchecked(gr.pz[i1])) * 0.5, np);
        } else {
            s.push(unchecked(s.entry[np * 3]), unchecked(s.entry[np * 3 + 1]), unchecked(s.entry[np * 3 + 2]), np);
        }
        np = unchecked(back[np]);
    }
    s.push(s.bx, s.by, s.bz, beginNode);
}

// Each polygon's entry point from `endNode` back to `beginNode` (Godot's
// none).
export function entriesInto(gr: NavGraph, s: NavQueryScratch, endNode: i32, beginNode: i32): void {
    s.count = 0;
    s.push(s.ex, s.ey, s.ez, endNode);
    const back = s.back;
    let np = endNode;
    while (np != -1 && unchecked(back[np]) != -1) {
        s.push(unchecked(s.entry[np * 3]), unchecked(s.entry[np * 3 + 1]), unchecked(s.entry[np * 3 + 2]), np);
        np = unchecked(back[np]);
    }
    s.push(s.bx, s.by, s.bz, beginNode);
}

// Godot's simplification of the scratch's points (in path order): the
// Ramer-Douglas-Peucker subset within `epsilon` metres (a negative one is
// 0), the first and last points always kept; a path of 2 points or fewer
// is kept whole. The points are compacted in place.
export function simplifyPathInto(s: NavQueryScratch, epsilon: f64): void {
    const n = s.count;
    if (n <= 2) return;
    const e = epsilon > 0 ? epsilon : 0;
    s.keepCount = 0;
    unchecked(s.keep[s.keepCount++] = 0);
    simplifySegment(s, 0, n - 1, e * e);
    unchecked(s.keep[s.keepCount++] = n - 1);
    const kept = s.keepCount;
    const p = s.ptX;
    const nd = s.ptNode;
    for (let i = 0; i < kept; i++) {
        const k = unchecked(s.keep[i]);
        unchecked(p[i * 3] = p[k * 3]);
        unchecked(p[i * 3 + 1] = p[k * 3 + 1]);
        unchecked(p[i * 3 + 2] = p[k * 3 + 2]);
        unchecked(nd[i] = nd[k]);
    }
    s.count = kept;
}

// Godot's simplify_path_segment: the point of (start, end) farthest from
// their segment, kept (and both halves done) when farther than the
// epsilon (squared). Recursion depth is at most the path's points.
function simplifySegment(s: NavQueryScratch, start: i32, end: i32, epsilon2: f64): void {
    const p = s.ptX;
    const ax = unchecked(p[start * 3]), ay = unchecked(p[start * 3 + 1]), az = unchecked(p[start * 3 + 2]);
    const bx = unchecked(p[end * 3]), by = unchecked(p[end * 3 + 1]), bz = unchecked(p[end * 3 + 2]);
    let maxD: f64 = 0;
    let maxI = 0;
    for (let i = start; i < end; i++) {
        const d = closestOnSegment(unchecked(p[i * 3]), unchecked(p[i * 3 + 1]), unchecked(p[i * 3 + 2]), ax, ay, az, bx,
            by, bz, s.tmp);
        if (d > maxD) {
            maxI = i;
            maxD = d;
        }
    }
    if (maxD > epsilon2) {
        simplifySegment(s, start, maxI, epsilon2);
        unchecked(s.keep[s.keepCount++] = maxI);
        simplifySegment(s, maxI, end, epsilon2);
    }
}
