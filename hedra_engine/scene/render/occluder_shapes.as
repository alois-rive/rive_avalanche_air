// The triangles of an occluder shape (milestone 37; ../resource/
// occluders.as holds the shapes, hedra_engine/render/occluder.as what a
// frame carries): Godot's own meshes of its primitives, in the node's
// space, so that an occluder occludes in Hedra what it occludes in Godot
// (occluder_instance_3d.cpp `_update_arrays`):
//   - BoxOccluder3D: its 8 corners (+-size / 2; the front four, z =
//     +size.z / 2, first) and 12 triangles, Godot's order (front, right,
//     back, left, bottom, top);
//   - QuadOccluder3D: 4 corners (-x -y, -x +y, +x +y, +x -y at z = 0, each
//     half the size) and 2 triangles (0 1 2, 0 2 3);
//   - SphereOccluder3D: Godot's UV sphere of RINGS 7 and RADIAL_SEGMENTS 7,
//     (7 + 2) x (7 + 1) points (cos(u tau) sin(v pi), cos(v pi),
//     sin(u tau) sin(v pi)) * radius, ring by ring from the top, and
//     (7 + 1) x 7 x 2 triangles (inside the sphere: its triangles are
//     chords);
//   - PolygonOccluder3D: its corners at z = 0, reversed when their signed
//     area is positive (as Godot's), ear-clipped (Godot's
//     Geometry2D::triangulate_polygon; the 2D case of ../../source/model/
//     mesh/triangulate.as, which the run time cannot import); fewer than 3
//     corners give no triangle, and so do edges that cross or a polygon
//     with no area to clip: `problem` says why, and the warnings say so
//     (occluder-empty, occluder-polygon);
//   - ArrayOccluder3D: its own arrays (none when they are not whole
//     triangles of its vertices: occluder-invalid).
// A size or radius below 0 is taken as 0, as Godot's setters clamp it.
// Each mesh is kept on its occluder (Occluder3D.mesh) until its version
// moves, so a frame refreshed in place reads the same arrays and allocates
// nothing.

import {
    ArrayOccluder3D, BoxOccluder3D, Occluder3D, OccluderMesh, PolygonOccluder3D, QuadOccluder3D, SphereOccluder3D,
} from "../resource/occluders";

// Godot's SphereOccluder3D mesh.
export const SPHERE_OCCLUDER_RINGS: i32 = 7;
export const SPHERE_OCCLUDER_RADIAL_SEGMENTS: i32 = 7;

// What OccluderMesh.problem says when a shape gives no triangle.
export const ARRAY_INVALID_PROBLEM = "its indices are not whole triangles of its vertices";
export const POLYGON_FEW_PROBLEM = "it has fewer than 3 points";
export const POLYGON_CROSSED_PROBLEM = "its edges cross";
export const POLYGON_FLAT_PROBLEM = "it has no area to triangulate";

// Godot's box (occluder_instance_3d.cpp): the corners' signs, and the
// triangles.
const BOX_SIGNS: StaticArray<f32> = [
    -1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1,
    -1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1,
];
const BOX_INDICES: StaticArray<u32> = [
    0, 1, 2, 2, 3, 0,
    1, 5, 6, 6, 2, 1,
    7, 6, 5, 5, 4, 7,
    4, 0, 3, 3, 7, 4,
    4, 5, 1, 1, 0, 4,
    3, 2, 6, 6, 7, 3,
];

// `o`'s triangles (see the header), made again only when its version
// moved.
export function occluderMeshOf(o: Occluder3D): OccluderMesh {
    const m = o.mesh;
    if (m.version == <i64>o.version) return m;
    m.version = <i64>o.version;
    m.problem = "";
    m.vertices = new Float32Array(0);
    m.indices = new Uint32Array(0);
    const isArray = o instanceof ArrayOccluder3D;
    if (isArray) {
        const a = o as ArrayOccluder3D;
        if (a.valid) {
            m.vertices = a.vertices;
            m.indices = a.indices;
        } else {
            m.problem = ARRAY_INVALID_PROBLEM;
        }
        return m;
    }
    const isBox = o instanceof BoxOccluder3D;
    if (isBox) {
        boxMesh(o as BoxOccluder3D, m);
        return m;
    }
    const isQuad = o instanceof QuadOccluder3D;
    if (isQuad) {
        quadMesh(o as QuadOccluder3D, m);
        return m;
    }
    const isSphere = o instanceof SphereOccluder3D;
    if (isSphere) {
        sphereMesh(o as SphereOccluder3D, m);
        return m;
    }
    const isPolygon = o instanceof PolygonOccluder3D;
    if (isPolygon) polygonMesh(o as PolygonOccluder3D, m);
    return m;
}

function half(x: f32): f32 {
    return x > 0 ? x / <f32>2 : <f32>0;
}

function boxMesh(b: BoxOccluder3D, m: OccluderMesh): void {
    const hx = half(b.size.x);
    const hy = half(b.size.y);
    const hz = half(b.size.z);
    const v = new Float32Array(24);
    for (let i = 0; i < 8; i++) {
        v[i * 3] = BOX_SIGNS[i * 3] * hx;
        v[i * 3 + 1] = BOX_SIGNS[i * 3 + 1] * hy;
        v[i * 3 + 2] = BOX_SIGNS[i * 3 + 2] * hz;
    }
    const idx = new Uint32Array(36);
    for (let i = 0; i < 36; i++) idx[i] = BOX_INDICES[i];
    m.vertices = v;
    m.indices = idx;
}

function quadMesh(q: QuadOccluder3D, m: OccluderMesh): void {
    const hx = half(q.size.x);
    const hy = half(q.size.y);
    const v = new Float32Array(12);
    v[0] = -hx;
    v[1] = -hy;
    v[3] = -hx;
    v[4] = hy;
    v[6] = hx;
    v[7] = hy;
    v[9] = hx;
    v[10] = -hy;
    const idx = new Uint32Array(6);
    idx[0] = 0;
    idx[1] = 1;
    idx[2] = 2;
    idx[3] = 0;
    idx[4] = 2;
    idx[5] = 3;
    m.vertices = v;
    m.indices = idx;
}

// Godot's loop, point for point and triangle for triangle (in f32, as
// Godot's floats).
function sphereMesh(s: SphereOccluder3D, m: OccluderMesh): void {
    const rings = SPHERE_OCCLUDER_RINGS;
    const segs = SPHERE_OCCLUDER_RADIAL_SEGMENTS;
    const r: f32 = s.radius > 0 ? s.radius : 0;
    const v = new Float32Array((rings + 2) * (segs + 1) * 3);
    const idx = new Uint32Array((rings + 1) * segs * 6);
    let vi = 0;
    let ii = 0;
    let current = 0;
    let previous = 0;
    let point = 0;
    for (let j = 0; j <= rings + 1; j++) {
        const fv = <f32>j / <f32>(rings + 1);
        const w = Mathf.sin(Mathf.PI * fv);
        const y = Mathf.cos(Mathf.PI * fv);
        for (let i = 0; i <= segs; i++) {
            const u = <f32>i / <f32>segs;
            const x = Mathf.cos(u * <f32>2 * Mathf.PI);
            const z = Mathf.sin(u * <f32>2 * Mathf.PI);
            v[vi++] = x * w * r;
            v[vi++] = y * r;
            v[vi++] = z * w * r;
            if (i > 0 && j > 0) {
                idx[ii++] = <u32>(previous + i - 1);
                idx[ii++] = <u32>(previous + i);
                idx[ii++] = <u32>(current + i - 1);
                idx[ii++] = <u32>(previous + i);
                idx[ii++] = <u32>(current + i);
                idx[ii++] = <u32>(current + i - 1);
            }
            point++;
        }
        previous = current;
        current = point;
    }
    m.vertices = v;
    m.indices = idx;
}

function polygonMesh(p: PolygonOccluder3D, m: OccluderMesh): void {
    const src = p.polygon;
    const n = src.length / 2;
    if (n < 3) {
        m.problem = POLYGON_FEW_PROBLEM;
        return;
    }
    // Godot: reversed when the signed area is positive.
    const pts = new Float32Array(n * 2);
    const area = signedArea(src, n);
    for (let i = 0; i < n; i++) {
        const k = area > 0 ? n - 1 - i : i;
        pts[i * 2] = src[k * 2];
        pts[i * 2 + 1] = src[k * 2 + 1];
    }
    if (edgesCross(pts, n)) {
        m.problem = POLYGON_CROSSED_PROBLEM;
        return;
    }
    const tris = earClip(pts, n);
    if (tris == null) {
        m.problem = POLYGON_FLAT_PROBLEM;
        return;
    }
    const v = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) {
        v[i * 3] = pts[i * 2];
        v[i * 3 + 1] = pts[i * 2 + 1];
    }
    m.vertices = v;
    m.indices = tris;
}

// Godot's Triangulate::get_area: positive counter-clockwise (y up).
export function polygonSignedArea(p: Float32Array): f32 {
    return signedArea(p, p.length / 2);
}

function signedArea(p: Float32Array, n: i32): f32 {
    let a: f32 = 0;
    let q = n - 1;
    for (let i = 0; i < n; i++) {
        a += p[q * 2] * p[i * 2 + 1] - p[i * 2] * p[q * 2 + 1];
        q = i;
    }
    return a * <f32>0.5;
}

// Twice the signed area of (a, b, c); positive counter-clockwise.
function cross2(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32): f32 {
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
}

// Whether segments ab and cd meet (touching counts).
function segmentsMeet(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, dx: f32, dy: f32): bool {
    const d1 = cross2(cx, cy, dx, dy, ax, ay);
    const d2 = cross2(cx, cy, dx, dy, bx, by);
    const d3 = cross2(ax, ay, bx, by, cx, cy);
    const d4 = cross2(ax, ay, bx, by, dx, dy);
    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) return true;
    if (d1 == 0 && onSegment(cx, cy, dx, dy, ax, ay)) return true;
    if (d2 == 0 && onSegment(cx, cy, dx, dy, bx, by)) return true;
    if (d3 == 0 && onSegment(ax, ay, bx, by, cx, cy)) return true;
    if (d4 == 0 && onSegment(ax, ay, bx, by, dx, dy)) return true;
    return false;
}

// Whether p, on the line through a and b, lies within the segment.
function onSegment(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32): bool {
    return px >= Mathf.min(ax, bx) && px <= Mathf.max(ax, bx) && py >= Mathf.min(ay, by) && py <= Mathf.max(ay, by);
}

// Whether two edges of the ring that are not neighbours meet.
function edgesCross(p: Float32Array, n: i32): bool {
    for (let i = 0; i < n; i++) {
        const i1 = (i + 1) % n;
        for (let j = i + 1; j < n; j++) {
            const j1 = (j + 1) % n;
            if (j == i1 || i == j1) continue;
            if (segmentsMeet(p[i * 2], p[i * 2 + 1], p[i1 * 2], p[i1 * 2 + 1],
                p[j * 2], p[j * 2 + 1], p[j1 * 2], p[j1 * 2 + 1])) return true;
        }
    }
    return false;
}

// Whether p is in triangle abc (whose winding is `s`: 1 counter-clockwise,
// -1 clockwise), its edges included.
function inTriangle(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, s: f32): bool {
    const eps: f32 = -1e-7;
    return s * cross2(ax, ay, bx, by, px, py) >= eps && s * cross2(bx, by, cx, cy, px, py) >= eps
        && s * cross2(cx, cy, ax, ay, px, py) >= eps;
}

// Ear clipping of a simple ring of `n` points (triangulate.as's 2D case,
// either winding), n - 2 triangles of the ring's indices; null when no ear
// is left to clip (no area).
function earClip(p: Float32Array, n: i32): Uint32Array? {
    const area = signedArea(p, n);
    if (!(area != 0)) return null;
    const s: f32 = area > 0 ? 1 : -1;
    const ring = new Array<i32>(n);
    for (let i = 0; i < n; i++) ring[i] = i;
    const out = new Uint32Array((n - 2) * 3);
    let o = 0;
    while (ring.length > 3) {
        const m = ring.length;
        let clipped = false;
        for (let i = 0; i < m; i++) {
            const a = ring[(i + m - 1) % m];
            const b = ring[i];
            const c = ring[(i + 1) % m];
            const ax = p[a * 2], ay = p[a * 2 + 1];
            const bx = p[b * 2], by = p[b * 2 + 1];
            const cx = p[c * 2], cy = p[c * 2 + 1];
            // (a reflex or flat corner is no ear)
            if (!(s * cross2(ax, ay, bx, by, cx, cy) > 0)) continue;
            let other = false;
            for (let j = 0; j < m; j++) {
                const k = ring[j];
                if (k == a || k == b || k == c) continue;
                if (inTriangle(p[k * 2], p[k * 2 + 1], ax, ay, bx, by, cx, cy, s)) {
                    other = true;
                    break;
                }
            }
            if (other) continue;
            out[o++] = <u32>a;
            out[o++] = <u32>b;
            out[o++] = <u32>c;
            ring.splice(i, 1);
            clipped = true;
            break;
        }
        if (!clipped) return null;
    }
    out[o++] = <u32>ring[0];
    out[o++] = <u32>ring[1];
    out[o++] = <u32>ring[2];
    return out;
}
