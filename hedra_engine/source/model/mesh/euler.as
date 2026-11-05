// Euler-style topology primitives (PLAN §5):
// split edge, split face, join faces, collapse edge, merge verts, dissolve
// edge / vert. Every operator is built from these so the invariants checked
// by validate hold between steps. Ids of surviving elements never change.
//
// Free functions `fn(m: Mesh, ...)`; `Mesh` (engine/src/source/model/mesh/mod.as) has
// one-line delegating methods for each.

import { Vec2, Vec3 } from "../../../base/vecmath";
import { Result, panic, dedup, maxF32, swapRemove, f32ToI64 } from "../../../base/util";
import { CoreError } from "../../../base/error";
import { Mesh, Edge, CornerUv, ElemKind, ElemRef, NO_ID, VertId, EdgeId, FaceId } from "./mod";

// What splitEdge returns: the new vert and the new edge.
export class SplitEdgeResult {
    vert: VertId = 0;
    edge: EdgeId = 0;

    static new(vert: VertId, edge: EdgeId): SplitEdgeResult {
        const r = new SplitEdgeResult();
        r.vert = vert;
        r.edge = edge;
        return r;
    }
}

// What splitFace returns: the new face and the new edge.
export class SplitFaceResult {
    face: FaceId = 0;
    edge: EdgeId = 0;

    static new(face: FaceId, edge: EdgeId): SplitFaceResult {
        const r = new SplitFaceResult();
        r.face = face;
        r.edge = edge;
        return r;
    }
}

// A face taken apart for rebuilding: id, its new ring, and the corner UVs
// it had (by vertex) so `attachFaceLoops` can restore them.
class Detached {
    f: FaceId = 0;
    ring: Array<VertId> = [];
    uvs: Array<CornerUv> = [];

    static new(f: FaceId, ring: Array<VertId>, uvs: Array<CornerUv>): Detached {
        const d = new Detached();
        d.f = f;
        d.ring = ring;
        d.uvs = uvs;
        return d;
    }
}

// One face of a dissolved vertex's fan: its ring minus the vertex.
class FanPath {
    f: FaceId = 0;
    p: Array<VertId> = [];

    static new(f: FaceId, p: Array<VertId>): FanPath {
        const r = new FanPath();
        r.f = f;
        r.p = p;
        return r;
    }
}

function bad<T>(msg: string): Result<T> {
    return CoreError.invalidArgument(msg).fail<T>();
}

// Sorts ids ascending (equal keys are indistinguishable, so stability does not matter).
function sortIds(a: Array<u32>): void {
    a.sort((x: u32, y: u32): i32 => (x < y ? -1 : (x > y ? 1 : 0)));
}

// Binary search for v in a sorted array.
function sortedContains(a: Array<u32>, v: u32): bool {
    let lo = 0;
    let hi = a.length;
    while (lo < hi) {
        const mid = (lo + hi) >>> 1;
        const x = a[mid];
        if (x == v) return true;
        if (x < v) lo = mid + 1;
        else hi = mid;
    }
    return false;
}

// Index of the corner of vertex `v` in `uvs`, or -1.
function cornerOf(uvs: Array<CornerUv>, v: VertId): i32 {
    for (let i = 0; i < uvs.length; i++) {
        if (uvs[i].vert == v) return i;
    }
    return -1;
}

// Copy of `ids` sorted and deduplicated.
function sortedDistinct(ids: Array<u32>): Array<u32> {
    const d = ids.slice(0);
    sortIds(d);
    dedup<u32>(d);
    return d;
}

// Insert a vertex on edge `e` at parameter `t` from `e.v[0]` to `e.v[1]`.
// `e` keeps its id and now runs `v[0] -> new`; a new edge runs `new -> v[1]`
// with the same marks and selection. Every face using `e` gets the new vertex
// inserted in its ring (UVs interpolated). Returns the new vertex and the new
// edge.
export function splitEdge(m: Mesh, e: EdgeId, t: f32): SplitEdgeResult {
    const edge = m.edges.at(e);
    const a = edge.v[0];
    const b = edge.v[1];
    const co = m.verts.at(a).co.lerp(m.verts.at(b).co, t);
    const v = m.addVertFrom(co, [a, b], [<f32>1.0 - t, t]);
    const marks = m.edges.at(e).clone();
    const nv = m.verts.at(v);
    nv.hide = marks.hide;
    nv.select = marks.select;
    const faces = m.edgeFaces(e).slice(0);
    const detached: Array<Detached> = [];
    for (let fi = 0; fi < faces.length; fi++) {
        const f = faces[fi];
        const ring = m.faceVerts(f);
        const n = ring.length;
        const out: Array<VertId> = [];
        for (let i = 0; i < n; i++) {
            out.push(ring[i]);
            const next = ring[(i + 1) % n];
            if ((ring[i] == a && next == b) || (ring[i] == b && next == a)) out.push(v);
        }
        const uvs = m.detachFaceLoops(f);
        // The new corner interpolates the two ends of the split edge.
        const ia = cornerOf(uvs, a);
        const ib = cornerOf(uvs, b);
        if (ia >= 0 && ib >= 0) {
            const ua = uvs[ia].uv;
            const ub = uvs[ib].uv;
            const mixed: Array<Vec2> = [];
            const k = min(ua.length, ub.length);
            for (let j = 0; j < k; j++) mixed.push(ua[j].lerp(ub[j], t));
            const flags: Array<u8> = [];
            for (let j = 0; j < mixed.length; j++) flags.push(0);
            uvs.push(CornerUv.new(v, mixed, flags));
        }
        detached.push(Detached.new(f, out, uvs));
    }
    m.setEdgeVerts(e, a, v);
    const e2 = m.addEdge(v, b);
    {
        const dst = m.edges.at(e2);
        dst.copyMarks(marks);
        dst.select = marks.select;
        dst.hide = marks.hide;
    }
    for (let i = 0; i < detached.length; i++) {
        const d = detached[i];
        m.attachFaceLoops(d.f, d.ring, d.uvs);
    }
    return SplitEdgeResult.new(v, e2);
}

// For splitFace: ring[from], ring[from+1], ..., ring[to].
function walk(ring: Array<VertId>, from: i32, to: i32): Array<VertId> {
    const n = ring.length;
    const out: Array<VertId> = [];
    let i = from;
    while (true) {
        out.push(ring[i]);
        if (i == to) break;
        i = (i + 1) % n;
    }
    return out;
}

// Split face `f` along a new edge between two of its non-adjacent vertices.
// `f` keeps the ring `a .. b`; the new face gets `b .. a`. Returns
// `(new_face, new_edge)`.
export function splitFace(m: Mesh, f: FaceId, a: VertId, b: VertId): Result<SplitFaceResult> {
    const ring = m.faceVerts(f);
    const n = ring.length;
    const ia = ring.indexOf(a);
    if (ia < 0) return bad<SplitFaceResult>(`vert ${a} is not on face ${f}`);
    const ib = ring.indexOf(b);
    if (ib < 0) return bad<SplitFaceResult>(`vert ${b} is not on face ${f}`);
    if (ia == ib || (ia + 1) % n == ib || (ib + 1) % n == ia) {
        return bad<SplitFaceResult>(`verts ${a} and ${b} are adjacent on face ${f}; nothing to split`);
    }
    if (m.findEdge(a, b) != NO_ID) {
        return bad<SplitFaceResult>(`an edge between verts ${a} and ${b} already exists`);
    }
    const first = walk(ring, ia, ib);
    const second = walk(ring, ib, ia);
    const uvs = m.detachFaceLoops(f);
    const select = m.faces.at(f).select;
    m.attachFaceLoops(f, first, uvs);
    const nf = m.addFaceLike(second, f);
    const face = m.faces.at(nf);
    face.select = select;
    for (let l = face.loopStart; l < face.loopStart + face.loopLen; l++) {
        const lp = m.loops.at(l);
        const k = cornerOf(uvs, lp.vert);
        if (k >= 0) {
            lp.uv = uvs[k].uv.slice(0);
            lp.uvFlags = uvs[k].flags.slice(0);
        }
    }
    const e = m.findEdge(a, b);
    if (e == NO_ID) panic("split_face created the diagonal edge");
    return Result.okv<SplitFaceResult>(SplitFaceResult.new(nf, e));
}

// For joinFaces: `ring` rotated to start at `start`
// (unchanged when `start` is not on it).
function rot(ring: Array<VertId>, start: VertId): Array<VertId> {
    let i = ring.indexOf(start);
    if (i < 0) i = 0;
    const out: Array<VertId> = [];
    for (let k = i; k < ring.length; k++) out.push(ring[k]);
    for (let k = 0; k < i; k++) out.push(ring[k]);
    return out;
}

// Merge two faces that share exactly one edge into one ngon. `f1` survives;
// `f2` and the shared edge are removed.
export function joinFaces(m: Mesh, f1: FaceId, f2: FaceId): Result<FaceId> {
    if (f1 == f2) return bad<FaceId>("cannot join a face with itself");
    const shared: Array<EdgeId> = [];
    const fe = m.faceEdges(f1);
    for (let i = 0; i < fe.length; i++) {
        if (m.edgeFaces(fe[i]).includes(f2)) shared.push(fe[i]);
    }
    if (shared.length != 1) {
        return bad<FaceId>(`faces ${f1} and ${f2} share ${shared.length} edges; join needs exactly one`);
    }
    const e = shared[0];
    const edge = m.edges.at(e);
    const a = edge.v[0];
    const b = edge.v[1];
    const fwd1 = m.faceWalksEdgeForward(f1, e);
    const fwd2 = m.faceWalksEdgeForward(f2, e);
    if (fwd1 == fwd2) {
        return bad<FaceId>(`faces ${f1} and ${f2} have inconsistent winding across edge ${e}`);
    }
    // f1 walks start1 -> end1 across the edge; rotate f1 to start at end1
    // (so it ends at start1) and f2 to start at start1 (ending at end1), then
    // concatenate without repeating the two shared corners.
    const start1 = fwd1 ? a : b;
    const end1 = fwd1 ? b : a;
    const r1 = rot(m.faceVerts(f1), end1);
    const r2 = rot(m.faceVerts(f2), start1);
    const merged: Array<VertId> = r1.slice(0);
    const take = r2.length >= 2 ? r2.length - 2 : 0;
    for (let k = 1; k < r2.length && k <= take; k++) merged.push(r2[k]);
    const check = sortedDistinct(merged);
    if (check.length != merged.length) {
        return bad<FaceId>(`joining faces ${f1} and ${f2} would create a face that touches itself`);
    }
    const uvs = m.detachFaceLoops(f1);
    const uvs2 = m.detachFaceLoops(f2);
    for (let i = 0; i < uvs2.length; i++) {
        if (cornerOf(uvs, uvs2[i].vert) < 0) uvs.push(uvs2[i]);
    }
    const select = m.faces.at(f1).select || m.faces.at(f2).select;
    m.deleteFaces([f2]);
    m.removeEdge(e);
    m.attachFaceLoops(f1, merged, uvs);
    m.faces.at(f1).select = select;
    return Result.okv<FaceId>(f1);
}

// Collapse edge `e` into its first vertex, moved to `co` when `hasCo`, else
// to the edge midpoint. Faces that degenerate are removed.
// Returns the survivor.
export function collapseEdge(m: Mesh, e: EdgeId, co: Vec3, hasCo: bool): VertId {
    const edge = m.edges.at(e);
    const a = edge.v[0];
    const b = edge.v[1];
    const target = hasCo ? co : m.edgeCenter(e);
    mergeVerts(m, a, [b]);
    m.verts.at(a).co = target;
    const faces = m.vertFaces(a);
    m.recalcFaceNormals(faces);
    return a;
}

// Merge `others` into `target`: their edges and face corners are re-pointed,
// duplicate edges unified, and faces that lose distinct corners are fixed up
// or removed. `target` keeps its position.
export function mergeVerts(m: Mesh, target: VertId, othersIn: Array<VertId>): void {
    const others: Array<VertId> = [];
    for (let i = 0; i < othersIn.length; i++) {
        const v = othersIn[i];
        if (v != target && m.verts.contains(v)) others.push(v);
    }
    sortIds(others);
    dedup<u32>(others);
    if (others.length == 0) return;
    // Detach every face touching a merged vertex first, so edge removal
    // below never deletes faces.
    const affected: Array<FaceId> = [];
    for (let i = 0; i < others.length; i++) {
        const vf = m.vertFaces(others[i]);
        for (let j = 0; j < vf.length; j++) affected.push(vf[j]);
    }
    sortIds(affected);
    dedup<u32>(affected);
    const detached: Array<Detached> = [];
    for (let i = 0; i < affected.length; i++) {
        const f = affected[i];
        const src = m.faceVerts(f);
        const ring: Array<VertId> = [];
        for (let k = 0; k < src.length; k++) ring.push(sortedContains(others, src[k]) ? target : src[k]);
        const uvs = m.detachFaceLoops(f);
        // The target keeps its own UV if it was already a corner.
        if (cornerOf(uvs, target) < 0) {
            let pos = -1;
            for (let k = 0; k < uvs.length; k++) {
                if (sortedContains(others, uvs[k].vert)) {
                    pos = k;
                    break;
                }
            }
            if (pos >= 0) {
                const uv = uvs[pos].uv.slice(0);
                const flags = uvs[pos].flags.slice(0);
                uvs.push(CornerUv.new(target, uv, flags));
            }
        }
        detached.push(Detached.new(f, ring, uvs));
    }
    let selected = m.verts.at(target).select;
    for (let i = 0; i < others.length; i++) {
        const v = others[i];
        selected = selected || m.verts.at(v).select;
        const edges = m.vertEdges(v).slice(0);
        for (let k = 0; k < edges.length; k++) {
            const e = edges[k];
            const other = m.edges.at(e).other(v);
            if (other == NO_ID) panic("edge on vert");
            if (other == target || sortedContains(others, other)) {
                // Both ends collapse onto the target: the edge vanishes.
                m.removeEdge(e);
                continue;
            }
            const existing = m.findEdge(target, other);
            if (existing != NO_ID && existing != e) {
                const src: Edge = m.edges.at(e).clone();
                const dst = m.edges.at(existing);
                dst.select = dst.select || src.select;
                dst.seam = dst.seam || src.seam;
                dst.sharp = dst.sharp || src.sharp;
                dst.crease = maxF32(dst.crease, src.crease);
                dst.bevelWeight = maxF32(dst.bevelWeight, src.bevelWeight);
                m.removeEdge(e);
            } else {
                const ev = m.edges.at(e);
                const ea = ev.v[0];
                const eb = ev.v[1];
                if (ea == v) m.setEdgeVerts(e, target, eb);
                else m.setEdgeVerts(e, ea, target);
            }
        }
    }
    for (let i = 0; i < detached.length; i++) {
        const d = detached[i];
        const clean: Array<VertId> = [];
        for (let k = 0; k < d.ring.length; k++) {
            const v = d.ring[k];
            if (clean.length == 0 || clean[clean.length - 1] != v) clean.push(v);
        }
        while (clean.length > 1 && clean[0] == clean[clean.length - 1]) clean.pop();
        const distinct = sortedDistinct(clean);
        if (clean.length < 3 || distinct.length != clean.length) {
            m.deleteFaces([d.f]);
        } else {
            m.attachFaceLoops(d.f, clean, d.uvs);
        }
    }
    for (let i = 0; i < others.length; i++) m.removeVert(others[i]);
    m.verts.at(target).select = selected;
    const h = m.selectionHistory;
    let w = 0;
    for (let i = 0; i < h.length; i++) {
        const r: ElemRef = h[i];
        if (!(r.kind == ElemKind.Vert && sortedContains(others, r.id))) {
            h[w] = r;
            w++;
        }
    }
    h.length = w;
    m.touch();
}

// Dissolve an edge: join its two faces into one. A boundary edge removes its
// face, a wire edge is simply deleted. Ok(NO_ID) when no joined face results.
export function dissolveEdge(m: Mesh, e: EdgeId): Result<FaceId> {
    const faces = m.edgeFaces(e).slice(0);
    switch (faces.length) {
        case 0: {
            const edge = m.edges.at(e);
            const a = edge.v[0];
            const b = edge.v[1];
            m.removeEdge(e);
            if (m.vertEdges(a).length == 0) m.removeVert(a);
            if (m.vertEdges(b).length == 0) m.removeVert(b);
            return Result.okv<FaceId>(NO_ID);
        }
        case 1: {
            m.deleteFacesCleanup([faces[0]]);
            return Result.okv<FaceId>(NO_ID);
        }
        case 2:
            return joinFaces(m, faces[0], faces[1]);
        default:
            return bad<FaceId>(`edge ${e} is non-manifold (${faces.length} faces); dissolve needs two`);
    }
}

// Dissolve a vertex: a vertex with two edges and no faces merges them; a
// vertex on a face boundary or inside a fan of faces is removed from the
// ring(s), joining the fan into one ngon first.
export function dissolveVert(m: Mesh, v: VertId): Result<bool> {
    const edges = m.vertEdges(v).slice(0);
    const faces = m.vertFaces(v);
    if (faces.length == 0) {
        switch (edges.length) {
            case 0: {
                m.removeVert(v);
                break;
            }
            case 2: {
                const a = m.edges.at(edges[0]).other(v);
                if (a == NO_ID) panic("edge on vert");
                const b = m.edges.at(edges[1]).other(v);
                if (b == NO_ID) panic("edge on vert");
                const marks = m.edges.at(edges[0]).clone();
                m.removeVert(v);
                if (a != b) {
                    const e = m.addEdge(a, b);
                    const dst = m.edges.at(e);
                    dst.copyMarks(marks);
                    dst.select = marks.select;
                }
                break;
            }
            default:
                return bad<bool>(`vert ${v} joins ${edges.length} wire edges; dissolve needs exactly two`);
        }
        return Result.okv<bool>(true);
    }
    // Walk the fan: each face contributes its ring minus `v`, a path from
    // next(v) to prev(v); paths chain across the shared edges. The result is
    // one ngon spanning the fan (closed by a new edge when `v` sits on a
    // boundary).
    const paths: Array<FanPath> = [];
    for (let fi = 0; fi < faces.length; fi++) {
        const f = faces[fi];
        const ring = m.faceVerts(f);
        const i = ring.indexOf(v);
        if (i < 0) panic("v on its face");
        const path: Array<VertId> = [];
        for (let k = 1; k < ring.length; k++) path.push(ring[(i + k) % ring.length]);
        paths.push(FanPath.new(f, path));
    }
    const ends: Array<VertId> = [];
    for (let i = 0; i < paths.length; i++) {
        const p = paths[i].p;
        if (p.length == 0) panic("path");
        ends.push(p[p.length - 1]);
    }
    let first = 0;
    for (let i = 0; i < paths.length; i++) {
        if (!ends.includes(paths[i].p[0])) {
            first = i;
            break;
        }
    }
    const start = swapRemove<FanPath>(paths, first);
    const survivor = start.f;
    const ring = start.p;
    const order: Array<FaceId> = [survivor];
    while (true) {
        const tail = ring[ring.length - 1];
        let pos = -1;
        for (let i = 0; i < paths.length; i++) {
            if (paths[i].p[0] == tail) {
                pos = i;
                break;
            }
        }
        if (pos < 0) break;
        const next = swapRemove<FanPath>(paths, pos);
        order.push(next.f);
        for (let k = 1; k < next.p.length; k++) ring.push(next.p[k]);
    }
    if (paths.length != 0) {
        return bad<bool>(`vert ${v} is non-manifold; its faces do not form one fan`);
    }
    if (ring.length > 1 && ring[0] == ring[ring.length - 1]) ring.pop();
    const distinct = sortedDistinct(ring);
    if (distinct.length != ring.length) {
        return bad<bool>(`dissolving vert ${v} would create a face that touches itself`);
    }
    const uvs = m.detachFaceLoops(survivor);
    for (let i = 1; i < order.length; i++) {
        const corners = m.detachFaceLoops(order[i]);
        for (let k = 0; k < corners.length; k++) {
            if (cornerOf(uvs, corners[k].vert) < 0) uvs.push(corners[k]);
        }
    }
    let select = false;
    for (let i = 0; i < order.length; i++) {
        if (m.faces.at(order[i]).select) {
            select = true;
            break;
        }
    }
    m.deleteFaces(order.slice(1));
    m.removeVert(v);
    if (ring.length >= 3) {
        m.attachFaceLoops(survivor, ring, uvs);
        m.faces.at(survivor).select = select;
    } else {
        m.deleteFaces([survivor]);
    }
    return Result.okv<bool>(true);
}

// One occupied cell of the merge-by-distance grid, keyed by (kx, ky, kz).
class GridCell {
    kx: i64 = 0;
    ky: i64 = 0;
    kz: i64 = 0;
    list: Array<VertId> = [];
}

// Map from (kx, ky, kz) to the cell's verts, lookup only: cells are
// bucketed by a mixed 64-bit hash and matched on the exact key.
export class CellGrid {
    buckets: Map<u64, Array<GridCell>> = new Map<u64, Array<GridCell>>();

    private static hash(kx: i64, ky: i64, kz: i64): u64 {
        let h: u64 = <u64>kx * 0x9E3779B97F4A7C15;
        h ^= <u64>ky * 0xC2B2AE3D27D4EB4F + (h << 6) + (h >> 2);
        h ^= <u64>kz * 0x165667B19E3779F9 + (h << 6) + (h >> 2);
        return h;
    }

    // The cell's list, or null.
    get(kx: i64, ky: i64, kz: i64): Array<VertId>? {
        const h = CellGrid.hash(kx, ky, kz);
        if (!this.buckets.has(h)) return null;
        const b = this.buckets.get(h);
        for (let i = 0; i < b.length; i++) {
            const c = b[i];
            if (c.kx == kx && c.ky == ky && c.kz == kz) return c.list;
        }
        return null;
    }

    // Appends v to the cell's list, creating the cell when missing.
    push(kx: i64, ky: i64, kz: i64, v: VertId): void {
        const found = this.get(kx, ky, kz);
        if (found != null) {
            found.push(v);
            return;
        }
        const c = new GridCell();
        c.kx = kx;
        c.ky = ky;
        c.kz = kz;
        c.list.push(v);
        const h = CellGrid.hash(kx, ky, kz);
        if (this.buckets.has(h)) this.buckets.get(h).push(c);
        else this.buckets.set(h, [c]);
    }
}

// floor(p / cell) as i64 per axis (saturating).
export function cellKey(x: f32, cell: f32): i64 {
    return f32ToI64(Mathf.floor(x / cell));
}

// Union-find root of `v` with path compression.

function findRoot(parent: Map<VertId, VertId>, v: VertId): VertId {
    let r = v;
    while (parent.get(r) != r) r = parent.get(r);
    let cur = v;
    while (parent.get(cur) != r) {
        const next = parent.get(cur);
        parent.set(cur, r);
        cur = next;
    }
    return r;
}

// Weld all vertices closer than `dist` (Blender's "merge by distance").
// Returns the number of vertices removed. Deterministic: the lowest id in
// each cluster survives.
export function mergeByDistance(m: Mesh, verts: Array<VertId>, dist: f32): i32 {
    const ids: Array<VertId> = [];
    for (let i = 0; i < verts.length; i++) {
        if (m.verts.contains(verts[i])) ids.push(verts[i]);
    }
    sortIds(ids);
    dedup<u32>(ids);
    // Spatial hash on a grid of `dist` cells; check the 27 neighbors.
    const cell = maxF32(dist, <f32>1e-9);
    const grid = new CellGrid();
    for (let i = 0; i < ids.length; i++) {
        const p = m.verts.at(ids[i]).co;
        grid.push(cellKey(p.x, cell), cellKey(p.y, cell), cellKey(p.z, cell), ids[i]);
    }
    const parent = new Map<VertId, VertId>();
    for (let i = 0; i < ids.length; i++) parent.set(ids[i], ids[i]);
    const d2 = dist * dist;
    for (let i = 0; i < ids.length; i++) {
        const v = ids[i];
        const p = m.verts.at(v).co;
        const kx = cellKey(p.x, cell);
        const ky = cellKey(p.y, cell);
        const kz = cellKey(p.z, cell);
        for (let dx: i64 = -1; dx <= 1; dx++) {
            for (let dy: i64 = -1; dy <= 1; dy++) {
                for (let dz: i64 = -1; dz <= 1; dz++) {
                    const list = grid.get(kx + dx, ky + dy, kz + dz);
                    if (list == null) continue;
                    for (let k = 0; k < list.length; k++) {
                        const w = list[k];
                        if (w > v && m.verts.at(w).co.distanceSquared(p) <= d2) {
                            const ra = findRoot(parent, v);
                            const rb = findRoot(parent, w);
                            if (ra != rb) {
                                const lo = ra < rb ? ra : rb;
                                const hi = ra < rb ? rb : ra;
                                parent.set(hi, lo);
                            }
                        }
                    }
                }
            }
        }
    }
    const clusters = new Map<VertId, Array<VertId>>();
    for (let i = 0; i < ids.length; i++) {
        const v = ids[i];
        const r = findRoot(parent, v);
        if (r != v) {
            if (clusters.has(r)) clusters.get(r).push(v);
            else clusters.set(r, [v]);
        }
    }
    let removed = 0;
    const roots = clusters.keys();
    sortIds(roots);
    for (let i = 0; i < roots.length; i++) {
        const members = clusters.get(roots[i]);
        removed += members.length;
        mergeVerts(m, roots[i], members);
    }
    if (removed > 0) m.recalcNormals();
    return removed;
}
