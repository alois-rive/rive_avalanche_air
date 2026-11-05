// UV layers, per-corner UV editor state (selection
// and pinning) and UV topology queries (islands, UV vertices) shared by the
// UV operators.
//
// UVs live on loops (face corners), so a mesh vertex can carry several UVs.
// A *UV vertex* is a cluster of corners around one mesh vertex that are
// joined through edges the unwrap does not cut (non-seam edges, or edges
// whose corner UVs agree on both sides); an *island* is a set of faces
// connected through such edges.
//
// Free functions `fn(m: Mesh, ...)`, with one-line delegating methods on
// Mesh (section "UVs" of mod.as). Layer indices are i32; -1 means none.

import { Vec2, VEC2_ZERO } from "../../../base/vecmath";
import { Mesh, UvLayer, VertId, EdgeId, FaceId, LoopId, NO_ID } from "./mod";
import { dedup } from "../../../base/util";
import { zeroPad } from "../../../base/fmt";

// Corner is selected in the UV editor.
export const UV_SELECT: u8 = 1;
// Corner is pinned (unwrap keeps it in place).
export const UV_PIN: u8 = 2;

// Two UVs closer than this are the same UV vertex.
export const UV_EPS: f32 = 1e-5;

export enum JoinKind {
    // Across every edge that is not marked as a seam (what `unwrap` cuts).
    Seams,
    // Across edges whose UVs agree on both sides in `layer` (what the UV
    // editor shows as connected).
    Uv,
}

// How faces join: across non-seam edges, or where a UV layer's corners
// agree. Treat as immutable.
export class Join {
    kind: JoinKind = JoinKind.Seams;
    // The layer of a Uv join; 0 for Seams.
    layer: i32 = 0;

    static seams(): Join {
        return new Join();
    }

    static uv(layer: i32): Join {
        const j = new Join();
        j.kind = JoinKind.Uv;
        j.layer = layer;
        return j;
    }

    equals(o: Join): bool {
        return this.kind == o.kind && this.layer == o.layer;
    }

    // Debug text: `Seams` / `Uv(0)`.
    debug(): string {
        return this.kind == JoinKind.Seams ? "Seams" : "Uv(" + this.layer.toString() + ")";
    }
}

// What uvVertices returns: the loop -> UV vertex map and the UV vertex count.
export class UvVertices {
    // loop -> UV vertex id; inserted in ascending loop order.
    map: Map<LoopId, u32> = new Map<LoopId, u32>();
    count: u32 = 0;
}

// What uvBounds returns (null when there is nothing to bound).
export class UvBounds {
    lo: Vec2 = VEC2_ZERO;
    hi: Vec2 = VEC2_ZERO;
}

function sortU32(a: Array<u32>): void {
    a.sort((x: u32, y: u32): i32 => (x < y ? -1 : (x > y ? 1 : 0)));
}

// ------------------------------------------------------------------ layers

// Index of the named layer, or of the active layer for null; -1 for none.
export function uvLayerIndex(m: Mesh, name: string?): i32 {
    if (name != null) {
        for (let i = 0; i < m.uvLayers.length; i++) {
            if (m.uvLayers[i].name == name) return i;
        }
        return -1;
    }
    const i = m.activeUv;
    return i < <u32>m.uvLayers.length ? <i32>i : -1;
}

export function uvLayerNames(m: Mesh): Array<string> {
    const out: Array<string> = [];
    for (let i = 0; i < m.uvLayers.length; i++) out.push(m.uvLayers[i].name);
    return out;
}

function hasUvLayer(m: Mesh, name: string): bool {
    for (let i = 0; i < m.uvLayers.length; i++) {
        if (m.uvLayers[i].name == name) return true;
    }
    return false;
}

// Blender-style unique layer naming (`UVMap`, `UVMap.001`, ...).
export function uniqueUvLayerName(m: Mesh, base: string): string {
    if (!hasUvLayer(m, base)) return base;
    for (let n = 1; n < 10000; n++) {
        const candidate = base + "." + zeroPad(n, 3);
        if (!hasUvLayer(m, candidate)) return candidate;
    }
    return base + "." + m.uvLayers.length.toString();
}

// Resize an Array<Vec2> in place, filling with ZERO.
function resizeVec2(a: Array<Vec2>, n: i32): void {
    while (a.length > n) a.pop();
    while (a.length < n) a.push(VEC2_ZERO);
}

// Resize an Array<u8> in place, filling with 0.
function resizeU8(a: Array<u8>, n: i32): void {
    if (a.length > n) a.length = n;
    while (a.length < n) a.push(0);
}

// Add a UV layer. Like Blender, the new layer starts as a copy of the active
// layer (or zeros when there is none). Returns its index.
export function addUvLayer(m: Mesh, name: string): i32 {
    m.touch();
    const src = uvLayerIndex(m, null);
    m.uvLayers.push(UvLayer.new(name));
    const n = m.uvLayers.length;
    const bound = m.loops.idBound();
    for (let id: u32 = 0; id < bound; id++) {
        const l = m.loops.get(id);
        if (l == null) continue;
        let uv = VEC2_ZERO;
        if (src >= 0 && src < l.uv.length) uv = l.uv[src];
        resizeVec2(l.uv, n - 1);
        l.uv.push(uv);
        resizeU8(l.uvFlags, n - 1);
        l.uvFlags.push(0);
    }
    return n - 1;
}

// Removes element i of an Array<Vec2> in place, shifting the rest down.
function removeVec2At(a: Array<Vec2>, i: i32): void {
    for (let j = i; j < a.length - 1; j++) {
        a[j].x = a[j + 1].x;
        a[j].y = a[j + 1].y;
    }
    a.pop();
}

// Remove a UV layer; the active index is kept valid.
export function removeUvLayer(m: Mesh, index: i32): void {
    if (index < 0 || index >= m.uvLayers.length) return;
    m.touch();
    m.uvLayers.splice(index, 1);
    const bound = m.loops.idBound();
    for (let id: u32 = 0; id < bound; id++) {
        const l = m.loops.get(id);
        if (l == null) continue;
        if (index < l.uv.length) removeVec2At(l.uv, index);
        if (index < l.uvFlags.length) l.uvFlags.splice(index, 1);
    }
    const n = <u32>m.uvLayers.length;
    if (n == 0) {
        m.activeUv = 0;
    } else if (m.activeUv >= n) {
        m.activeUv = n - 1;
    } else if (m.activeUv > <u32>index) {
        m.activeUv -= 1;
    }
}

// ----------------------------------------------------------------- corners

// UV of a corner on `layer` (zero when the layer is missing).
export function uvOf(m: Mesh, l: LoopId, layer: i32): Vec2 {
    const uvs = m.loops.at(l).uv;
    if (layer >= 0 && layer < uvs.length) return uvs[layer];
    return VEC2_ZERO;
}

export function setUv(m: Mesh, l: LoopId, layer: i32, uv: Vec2): void {
    const uvs = m.loops.at(l).uv;
    if (layer >= 0 && layer < uvs.length) {
        uvs[layer].x = uv.x;
        uvs[layer].y = uv.y;
    }
}

export function uvFlag(m: Mesh, l: LoopId, layer: i32, flag: u8): bool {
    const fl = m.loops.at(l).uvFlags;
    const v: u8 = layer >= 0 && layer < fl.length ? fl[layer] : 0;
    return (v & flag) != 0;
}

export function setUvFlag(m: Mesh, l: LoopId, layer: i32, flag: u8, on: bool): void {
    const lp = m.loops.at(l);
    if (lp.uvFlags.length <= layer) resizeU8(lp.uvFlags, layer + 1);
    if (on) {
        lp.uvFlags[layer] = lp.uvFlags[layer] | flag;
    } else {
        lp.uvFlags[layer] = lp.uvFlags[layer] & ~flag;
    }
}

export function uvSelected(m: Mesh, l: LoopId, layer: i32): bool {
    return uvFlag(m, l, layer, UV_SELECT);
}

export function uvPinned(m: Mesh, l: LoopId, layer: i32): bool {
    return uvFlag(m, l, layer, UV_PIN);
}

// Faces the UV editor works on: selected and visible (Blender's UV sync
// selection off shows only the selected faces).
export function uvFaces(m: Mesh): Array<FaceId> {
    const out: Array<FaceId> = [];
    const bound = m.faces.idBound();
    for (let id: u32 = 0; id < bound; id++) {
        const f = m.faces.get(id);
        if (f == null) continue;
        if (f.select && !f.hide) out.push(id);
    }
    return out;
}

// Corners of `faces` whose UV is selected on `layer`.
export function uvSelectedLoops(m: Mesh, faces: Array<FaceId>, layer: i32): Array<LoopId> {
    const out: Array<LoopId> = [];
    for (let i = 0; i < faces.length; i++) {
        const f = m.faces.at(faces[i]);
        for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
            if (uvSelected(m, l, layer)) out.push(l);
        }
    }
    return out;
}

// Set the UV selection of every corner of `faces`.
export function uvSelectFaces(m: Mesh, faces: Array<FaceId>, layer: i32, on: bool): void {
    m.touch();
    for (let i = 0; i < faces.length; i++) {
        const f = m.faces.at(faces[i]);
        for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
            setUvFlag(m, l, layer, UV_SELECT, on);
        }
    }
}

// Blender's sticky selection (shared location): any selected corner also
// selects the other corners at its vertex with the same UV.
export function uvSelectSticky(m: Mesh, faces: Array<FaceId>, layer: i32): void {
    const set = new Set<FaceId>();
    for (let i = 0; i < faces.length; i++) set.add(faces[i]);
    const byVert = new Map<VertId, Array<LoopId>>();
    for (let i = 0; i < faces.length; i++) {
        const f = m.faces.at(faces[i]);
        for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
            const v = m.loops.at(l).vert;
            if (byVert.has(v)) byVert.get(v).push(l);
            else byVert.set(v, [l]);
        }
    }
    // The walk order only affects the order flags are set in, not the result.
    const extra: Array<LoopId> = [];
    const groups = byVert.values();
    for (let g = 0; g < groups.length; g++) {
        const loops = groups[g];
        for (let i = 0; i < loops.length; i++) {
            const a = loops[i];
            if (!uvSelected(m, a, layer)) continue;
            const ua = uvOf(m, a, layer);
            for (let j = 0; j < loops.length; j++) {
                const b = loops[j];
                if (!uvSelected(m, b, layer)
                    && set.has(m.loops.at(b).face)
                    && uvOf(m, b, layer).distance(ua) <= UV_EPS) {
                    extra.push(b);
                }
            }
        }
    }
    if (extra.length != 0) {
        m.touch();
        for (let i = 0; i < extra.length; i++) setUvFlag(m, extra[i], layer, UV_SELECT, true);
    }
}

// ---------------------------------------------------------------- topology

// True when `e` connects faces `f` and `g` for `join`.

export function uvCrossable(m: Mesh, e: EdgeId, f: FaceId, g: FaceId, join: Join): bool {
    if (join.kind == JoinKind.Seams) return !m.edges.at(e).seam;
    const layer = join.layer;
    const edge = m.edges.at(e);
    const a = edge.v[0];
    const b = edge.v[1];
    const fa = m.faceLoopOf(f, a);
    const ga = m.faceLoopOf(g, a);
    const fb = m.faceLoopOf(f, b);
    const gb = m.faceLoopOf(g, b);
    if (fa == NO_ID || ga == NO_ID || fb == NO_ID || gb == NO_ID) return false;
    return uvOf(m, fa, layer).distance(uvOf(m, ga, layer)) <= UV_EPS
        && uvOf(m, fb, layer).distance(uvOf(m, gb, layer)) <= UV_EPS;
}

// Partition `faces` into islands: groups connected through crossable edges
// (see Join). Islands and their faces are in ascending id order, so results
// are deterministic.
export function uvIslands(m: Mesh, faces: Array<FaceId>, join: Join): Array<Array<FaceId>> {
    const set = new Set<FaceId>();
    for (let i = 0; i < faces.length; i++) set.add(faces[i]);
    const sorted = faces.slice(0);
    sortU32(sorted);
    dedup<u32>(sorted);
    const seen = new Set<FaceId>();
    const out: Array<Array<FaceId>> = [];
    for (let s = 0; s < sorted.length; s++) {
        const start = sorted[s];
        if (seen.has(start)) continue;
        seen.add(start);
        const island: Array<FaceId> = [start];
        const queue: Array<FaceId> = [start];
        let head = 0;
        while (head < queue.length) {
            const f = queue[head++];
            const es = m.faceEdges(f);
            for (let i = 0; i < es.length; i++) {
                const e = es[i];
                const gs = m.edgeFaces(e);
                for (let j = 0; j < gs.length; j++) {
                    const g = gs[j];
                    if (g != f && set.has(g) && !seen.has(g) && uvCrossable(m, e, f, g, join)) {
                        seen.add(g);
                        island.push(g);
                        queue.push(g);
                    }
                }
            }
        }
        sortU32(island);
        out.push(island);
    }
    return out;
}

function ufFind(p: Array<i32>, start: i32): i32 {
    let i = start;
    while (p[i] != i) {
        p[i] = p[p[i]];
        i = p[i];
    }
    return i;
}

// Cluster the corners of `faces` into UV vertices: corners at the same mesh
// vertex joined through crossable edges between faces of the set. Returns
// `loop -> uv vertex` and the number of UV vertices; ids are assigned in
// ascending loop order.
export function uvVertices(m: Mesh, faces: Array<FaceId>, join: Join): UvVertices {
    const set = new Set<FaceId>();
    for (let i = 0; i < faces.length; i++) set.add(faces[i]);
    const loops: Array<LoopId> = [];
    for (let i = 0; i < faces.length; i++) {
        const f = m.faces.at(faces[i]);
        for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) loops.push(l);
    }
    sortU32(loops);
    const index = new Map<LoopId, i32>();
    for (let i = 0; i < loops.length; i++) index.set(loops[i], i);
    const parent: Array<i32> = [];
    for (let i = 0; i < loops.length; i++) parent.push(i);
    // Each corner l of face f at vertex v touches two edges of f: the loop's
    // own edge (v -> next) and the previous loop's edge. Across either, the
    // neighbouring face's corner at v is the same UV vertex.
    for (let li = 0; li < loops.length; li++) {
        const l = loops[li];
        const lp = m.loops.at(l);
        const f = lp.face;
        const v = lp.vert;
        const prev = m.loopPrev(l);
        for (let k = 0; k < 2; k++) {
            const e = k == 0 ? lp.edge : m.loops.at(prev).edge;
            const gs = m.edgeFaces(e);
            for (let j = 0; j < gs.length; j++) {
                const g = gs[j];
                if (g == f || !set.has(g) || !uvCrossable(m, e, f, g, join)) continue;
                const mm = m.faceLoopOf(g, v);
                if (mm != NO_ID) {
                    const a = ufFind(parent, index.get(l));
                    const b = ufFind(parent, index.get(mm));
                    if (a != b) parent[a > b ? a : b] = a < b ? a : b;
                }
            }
        }
    }
    const ids = new Map<i32, u32>();
    const out = new UvVertices();
    for (let i = 0; i < loops.length; i++) {
        const root = ufFind(parent, i);
        const next = <u32>ids.size;
        if (!ids.has(root)) ids.set(root, next);
        out.map.set(loops[i], ids.get(root));
    }
    out.count = <u32>ids.size;
    return out;
}

// Axis-aligned UV bounds of some corners on `layer` (null when empty).
export function uvBounds(m: Mesh, loops: Array<LoopId>, layer: i32): UvBounds? {
    if (loops.length == 0) return null;
    const first = uvOf(m, loops[0], layer);
    let lo = first;
    let hi = first;
    for (let i = 1; i < loops.length; i++) {
        const p = uvOf(m, loops[i], layer);
        lo = lo.min(p);
        hi = hi.max(p);
    }
    const b = new UvBounds();
    b.lo = lo;
    b.hi = hi;
    return b;
}

// Signed UV area of a face (positive when the UV winding matches the face
// winding, i.e. the island is not flipped).
export function uvFaceArea(m: Mesh, f: FaceId, layer: i32): f32 {
    const face = m.faces.at(f);
    const loops: Array<LoopId> = [];
    for (let l = face.loopStart; l < face.loopStart + face.loopLen; l++) loops.push(l);
    let a: f32 = 0;
    for (let i = 0; i < loops.length; i++) {
        const p = uvOf(m, loops[i], layer);
        const q = uvOf(m, loops[(i + 1) % loops.length], layer);
        a += p.x * q.y - q.x * p.y;
    }
    return a * <f32>0.5;
}
