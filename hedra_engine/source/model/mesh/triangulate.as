// Ear-clipping triangulation for display
// and export. Quads and ngons are split in the plane of their (Newell)
// normal, so concave faces come out right; degenerate input falls back to a
// fan so callers always get `n - 2` triangles.
//
// A triangle is a `StaticArray<u32>` of length 3.
// `Mesh.triangulateFace` (section "triangulation" of mod.as) delegates
// to `triangulateFace` here.

import { Vec2, Vec3, VEC3_ZERO } from "../../../base/vecmath";
import { Mesh, FaceId, LoopId } from "./mod";

function tri(a: u32, b: u32, c: u32): StaticArray<u32> {
    const t = new StaticArray<u32>(3);
    t[0] = a;
    t[1] = b;
    t[2] = c;
    return t;
}

// Triangulate a polygon given as an ordered ring of points. Returns local
// corner indices, `points.length - 2` triangles with the ring's winding.
export function triangulatePolygon(points: Array<Vec3>): Array<StaticArray<u32>> {
    const n = points.length;
    if (n < 3) return [];
    if (n == 3) return [tri(0, 1, 2)];
    if (n == 4) {
        return quadSplits02(points[0], points[1], points[2], points[3])
            ? [tri(0, 1, 2), tri(0, 2, 3)]
            : [tri(1, 2, 3), tri(1, 3, 0)];
    }
    const normal = newellNormal(points);
    if (normal == VEC3_ZERO) return fan(n);
    // Project onto the face plane; the basis is right-handed with the normal
    // so a counter-clockwise ring stays counter-clockwise in 2D.
    const u = normal.anyOrthonormalVector();
    const v = normal.cross(u);
    const pts: Array<Vec2> = [];
    for (let i = 0; i < n; i++) pts.push(Vec2(points[i].dot(u), points[i].dot(v)));
    const ring: Array<u32> = [];
    for (let i = 0; i < n; i++) ring.push(<u32>i);
    const out: Array<StaticArray<u32>> = [];
    let guard = 0;
    while (ring.length > 3) {
        const m = ring.length;
        let clipped = false;
        for (let i = 0; i < m; i++) {
            const prev = ring[(i + m - 1) % m];
            const cur = ring[i];
            const next = ring[(i + 1) % m];
            const a = pts[<i32>prev];
            const b = pts[<i32>cur];
            const c = pts[<i32>next];
            if (cross2(a, b, c) <= 0) continue; // reflex or degenerate corner
            let containsOther = false;
            for (let j = 0; j < ring.length; j++) {
                const k = ring[j];
                if (k != prev && k != cur && k != next && pointInTriangle(pts[<i32>k], a, b, c)) {
                    containsOther = true;
                    break;
                }
            }
            if (containsOther) continue;
            out.push(tri(prev, cur, next));
            ring.splice(i, 1);
            clipped = true;
            break;
        }
        if (!clipped) {
            // Self-intersecting or fully degenerate: fan what is left so the
            // triangle count stays predictable.
            for (let i = 1; i < ring.length - 1; i++) out.push(tri(ring[0], ring[i], ring[i + 1]));
            return out;
        }
        guard += 1;
        if (guard > n) break;
    }
    if (ring.length == 3) out.push(tri(ring[0], ring[1], ring[2]));
    return out;
}

// Which diagonal the quad `p0 p1 p2 p3` splits along: true for 0-2
// (triangles 0 1 2 and 0 2 3), false for 1-3 (1 2 3 and 1 3 0). Split in the
// plane of the Newell normal: with a reflex corner the diagonal must start
// there; a convex quad takes the shorter one, as Blender does for planar
// quads. A degenerate quad (no normal) is fanned from corner 0, which is the
// 0-2 split. Allocates nothing (`triangulateFaceInto` runs it per face).
export function quadSplits02(p0: Vec3, p1: Vec3, p2: Vec3, p3: Vec3): bool {
    const normal = newellNormal4(p0, p1, p2, p3);
    if (normal == VEC3_ZERO) return true;
    // The basis is right-handed with the normal, so a counter-clockwise ring
    // stays counter-clockwise in 2D.
    const u = normal.anyOrthonormalVector();
    const v = normal.cross(u);
    const q0 = Vec2(p0.dot(u), p0.dot(v));
    const q1 = Vec2(p1.dot(u), p1.dot(v));
    const q2 = Vec2(p2.dot(u), p2.dot(v));
    const q3 = Vec2(p3.dot(u), p3.dot(v));
    // Corner i is reflex when (i-1, i, i+1) turns clockwise.
    if (cross2(q3, q0, q1) < 0 || cross2(q1, q2, q3) < 0) return true;
    if (cross2(q0, q1, q2) < 0 || cross2(q2, q3, q0) < 0) return false;
    return q0.distanceSquared(q2) <= q1.distanceSquared(q3);
}

function fan(n: i32): Array<StaticArray<u32>> {
    const out: Array<StaticArray<u32>> = [];
    for (let i: u32 = 1; i < <u32>n - 1; i++) out.push(tri(0, i, i + 1));
    return out;
}

function newellNormal(points: Array<Vec3>): Vec3 {
    let nx: f32 = 0;
    let ny: f32 = 0;
    let nz: f32 = 0;
    const len = points.length;
    for (let i = 0; i < len; i++) {
        const a = points[i];
        const b = points[(i + 1) % len];
        nx += (a.y - b.y) * (a.z + b.z);
        ny += (a.z - b.z) * (a.x + b.x);
        nz += (a.x - b.x) * (a.y + b.y);
    }
    return Vec3(nx, ny, nz).normalizeOrZero();
}

// `newellNormal` of a quad, term for term (the same sums in the same order).
function newellNormal4(p0: Vec3, p1: Vec3, p2: Vec3, p3: Vec3): Vec3 {
    let nx: f32 = 0;
    let ny: f32 = 0;
    let nz: f32 = 0;
    nx += (p0.y - p1.y) * (p0.z + p1.z);
    ny += (p0.z - p1.z) * (p0.x + p1.x);
    nz += (p0.x - p1.x) * (p0.y + p1.y);
    nx += (p1.y - p2.y) * (p1.z + p2.z);
    ny += (p1.z - p2.z) * (p1.x + p2.x);
    nz += (p1.x - p2.x) * (p1.y + p2.y);
    nx += (p2.y - p3.y) * (p2.z + p3.z);
    ny += (p2.z - p3.z) * (p2.x + p3.x);
    nz += (p2.x - p3.x) * (p2.y + p3.y);
    nx += (p3.y - p0.y) * (p3.z + p0.z);
    ny += (p3.z - p0.z) * (p3.x + p0.x);
    nz += (p3.x - p0.x) * (p3.y + p0.y);
    return Vec3(nx, ny, nz).normalizeOrZero();
}

// Twice the signed area of `abc`; positive for counter-clockwise.
function cross2(a: Vec2, b: Vec2, c: Vec2): f32 {
    return (b - a).perpDot(c - a);
}

function pointInTriangle(p: Vec2, a: Vec2, b: Vec2, c: Vec2): bool {
    const eps: f32 = -1e-7;
    return cross2(a, b, p) >= eps && cross2(b, c, p) >= eps && cross2(c, a, p) >= eps;
}

// Triangulates one face; each triangle is three

// loop ids of that face, in the face's winding.
export function triangulateFace(m: Mesh, id: FaceId): Array<StaticArray<LoopId>> {
    const f = m.faces.at(id);
    const loops: Array<LoopId> = [];
    for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) loops.push(l);
    const points: Array<Vec3> = [];
    for (let i = 0; i < loops.length; i++) points.push(m.verts.at(m.loops.at(loops[i]).vert).co);
    const tris = triangulatePolygon(points);
    const out: Array<StaticArray<LoopId>> = [];
    for (let i = 0; i < tris.length; i++) {
        const t = tris[i];
        out.push(tri(loops[<i32>t[0]], loops[<i32>t[1]], loops[<i32>t[2]]));
    }
    return out;
}

// `triangulateFace` appended to `out` as loop-id triples (three per
// triangle, the same triangles in the same order), without allocating for
// triangles and quads: the renderer triangulates every face of a mesh each
// time it rebuilds its buffers.
export function triangulateFaceInto(m: Mesh, id: FaceId, out: Array<LoopId>): void {
    const f = m.faces.at(id);
    const s = f.loopStart;
    const n = f.loopLen;
    if (n < 3) return;
    if (n == 3) {
        out.push(s);
        out.push(s + 1);
        out.push(s + 2);
        return;
    }
    if (n == 4) {
        const p0 = m.verts.at(m.loops.at(s).vert).co;
        const p1 = m.verts.at(m.loops.at(s + 1).vert).co;
        const p2 = m.verts.at(m.loops.at(s + 2).vert).co;
        const p3 = m.verts.at(m.loops.at(s + 3).vert).co;
        if (quadSplits02(p0, p1, p2, p3)) {
            out.push(s);
            out.push(s + 1);
            out.push(s + 2);
            out.push(s);
            out.push(s + 2);
            out.push(s + 3);
        } else {
            out.push(s + 1);
            out.push(s + 2);
            out.push(s + 3);
            out.push(s + 1);
            out.push(s + 3);
            out.push(s);
        }
        return;
    }
    const tris = triangulateFace(m, id);
    for (let i = 0; i < tris.length; i++) {
        const t = tris[i];
        out.push(t[0]);
        out.push(t[1]);
        out.push(t[2]);
    }
}
