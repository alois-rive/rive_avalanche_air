// Topology queries used by operators, tests, `inspect stats` and
// `inspect check`.
//
// Free functions `fn(m: Mesh, ...)`; `Mesh` (engine/src/source/model/mesh/mod.as) has
// one-line delegating methods for each.

import { dedup, maxF32, clampF32 } from "../../../base/util";
import { acosf } from "../../../base/vecmath";
import { Mesh, NO_ID, VertId, EdgeId, FaceId } from "./mod";
import { CellGrid, cellKey } from "./euler";

function sortIds(a: Array<u32>): void {
    a.sort((x: u32, y: u32): i32 => (x < y ? -1 : (x > y ? 1 : 0)));
}

// Number of faces using each edge (filled in ascending edge id order).
export function edgeFaceCounts(m: Mesh): Map<EdgeId, i32> {
    const out = new Map<EdgeId, i32>();
    const b = m.edges.idBound();
    for (let e: u32 = 0; e < b; e++) {
        if (!m.edges.contains(e)) continue;
        out.set(e, m.edgeFaces(e).length);
    }
    return out;
}

// True when every edge borders exactly two faces and the two faces walk the
// edge in opposite directions (consistent winding, no boundary).
export function isClosedManifold(m: Mesh): bool {
    if (m.faces.isEmpty()) return false;
    const b = m.edges.idBound();
    for (let e: u32 = 0; e < b; e++) {
        if (!m.edges.contains(e)) continue;
        const faces = m.edgeFaces(e);
        const ok = faces.length == 2
            && m.faceWalksEdgeForward(faces[0], e) != m.faceWalksEdgeForward(faces[1], e);
        if (!ok) return false;
    }
    return true;
}

// Euler characteristic V - E + F.
export function eulerCharacteristic(m: Mesh): i64 {
    return <i64>m.verts.len() - <i64>m.edges.len() + <i64>m.faces.len();
}

// Faces with fewer than three distinct vertices or zero area.
export function degenerateFaces(m: Mesh): Array<FaceId> {
    const out: Array<FaceId> = [];
    const b = m.faces.idBound();
    for (let id: u32 = 0; id < b; id++) {
        if (!m.faces.contains(id)) continue;
        const v = m.faceVerts(id);
        sortIds(v);
        dedup<u32>(v);
        if (v.length < 3 || m.faceArea(id) < <f32>1e-12) out.push(id);
    }
    return out;
}

export function degenerateFaceCount(m: Mesh): i32 {
    return degenerateFaces(m).length;
}

// Number of faces that are not triangles or quads.
export function ngonCount(m: Mesh): i32 {
    let n = 0;
    const b = m.faces.idBound();
    for (let id: u32 = 0; id < b; id++) {
        const f = m.faces.get(id);
        if (f != null && f.loopLen > 4) n++;
    }
    return n;
}

export function ngons(m: Mesh): Array<FaceId> {
    const out: Array<FaceId> = [];
    const b = m.faces.idBound();
    for (let id: u32 = 0; id < b; id++) {
        const f = m.faces.get(id);
        if (f != null && f.loopLen > 4) out.push(id);
    }
    return out;
}

// Edges with one face (boundary), or with more than two, or with two faces
// winding the same way (Blender counts all as non-manifold).
export function nonManifoldEdges(m: Mesh): Array<EdgeId> {
    const out: Array<EdgeId> = [];
    const b = m.edges.idBound();
    for (let e: u32 = 0; e < b; e++) {
        if (!m.edges.contains(e)) continue;
        const faces = m.edgeFaces(e);
        let bad = false;
        switch (faces.length) {
            case 2:
                bad = m.faceWalksEdgeForward(faces[0], e) == m.faceWalksEdgeForward(faces[1], e);
                break;
            case 1:
                bad = true;
                break;
            case 0:
                bad = false;
                break;
            default:
                bad = true;
                break;
        }
        if (bad) out.push(e);
    }
    return out;
}

// Boundary edges (exactly one face).
export function boundaryEdges(m: Mesh): Array<EdgeId> {
    const out: Array<EdgeId> = [];
    const b = m.edges.idBound();
    for (let e: u32 = 0; e < b; e++) {
        if (m.edges.contains(e) && m.edgeFaces(e).length == 1) out.push(e);
    }
    return out;
}

// Edges with no faces.
export function wireEdges(m: Mesh): Array<EdgeId> {
    const out: Array<EdgeId> = [];
    const b = m.edges.idBound();
    for (let e: u32 = 0; e < b; e++) {
        if (m.edges.contains(e) && m.edgeFaces(e).length == 0) out.push(e);
    }
    return out;
}

// Verts with no edges.
export function looseVerts(m: Mesh): Array<VertId> {
    const out: Array<VertId> = [];
    const b = m.verts.idBound();
    for (let v: u32 = 0; v < b; v++) {
        if (m.verts.contains(v) && m.vertEdges(v).length == 0) out.push(v);
    }
    return out;
}

// Verts whose faces do not form a single fan or where a wire edge meets
// faces (Blender's non-manifold vertices), plus verts on non-manifold edges.
// (Results come in ascending vert id order.)
export function nonManifoldVerts(m: Mesh): Array<VertId> {
    const badEdges = new Set<EdgeId>();
    const nm = nonManifoldEdges(m);
    for (let i = 0; i < nm.length; i++) {
        if (m.edgeFaces(nm[i]).length != 1) badEdges.add(nm[i]);
    }
    const out: Array<VertId> = [];
    const bound = m.verts.idBound();
    for (let v: u32 = 0; v < bound; v++) {
        if (!m.verts.contains(v)) continue;
        if (nonManifoldVert(m, v, badEdges)) out.push(v);
    }
    return out;
}

// Scratch lists for nonManifoldVert, reused from one vertex to the next:
// the check runs for every vertex, and fresh arrays per vertex made `inspect
// stats` keep ~1 GB (never freed) on a million-triangle mesh.
const FAN_FACES: Array<FaceId> = [];
const FAN_SEEN: Array<FaceId> = [];
const FAN_QUEUE: Array<FaceId> = [];

function nonManifoldVert(m: Mesh, v: VertId, badEdges: Set<EdgeId>): bool {
    const edges = m.vertEdges(v);
    if (edges.length == 0) return false;
    let hasFaces = false;
    let hasWire = false;
    let onBad = false;
    // (the faces around v are gathered on the way: m.vertFaces(v) is these,
    // sorted and deduplicated)
    const faces = FAN_FACES;
    faces.length = 0;
    for (let i = 0; i < edges.length; i++) {
        const fs = m.edgeFaces(edges[i]);
        const n = fs.length;
        if (n != 0) hasFaces = true;
        else hasWire = true;
        if (badEdges.has(edges[i])) onBad = true;
        for (let j = 0; j < n; j++) faces.push(fs[j]);
    }
    if ((hasFaces && hasWire) || onBad) return true;
    if (!hasFaces) return false;
    sortIds(faces);
    dedup<u32>(faces);
    // Walk the fan: the faces around v must be one connected chain. Fans are
    // small, so an array beats a hash set.
    const seen = FAN_SEEN;
    const queue = FAN_QUEUE;
    seen.length = 0;
    queue.length = 0;
    seen.push(faces[0]);
    queue.push(faces[0]);
    let head = 0;
    while (head < queue.length) {
        const f = queue[head++];
        // The face's own loops rather than `faceEdges`, which would allocate
        // an array per visited face.
        const face = m.faces.at(f);
        for (let l = face.loopStart; l < face.loopStart + face.loopLen; l++) {
            const e = m.loops.at(l).edge;
            if (!m.edges.at(e).hasVert(v)) continue;
            const gs = m.edgeFaces(e);
            for (let k = 0; k < gs.length; k++) {
                const g = gs[k];
                if (!seen.includes(g)) {
                    seen.push(g);
                    queue.push(g);
                }
            }
        }
    }
    return seen.length != faces.length;
}

// Pairs of faces that share an edge but wind it the same way.
export function inconsistentNormalEdges(m: Mesh): Array<EdgeId> {
    const out: Array<EdgeId> = [];
    const b = m.edges.idBound();
    for (let e: u32 = 0; e < b; e++) {
        if (!m.edges.contains(e)) continue;
        const faces = m.edgeFaces(e);
        if (faces.length == 2 && m.faceWalksEdgeForward(faces[0], e) == m.faceWalksEdgeForward(faces[1], e)) {
            out.push(e);
        }
    }
    return out;
}

// Groups of vertices closer than `eps` (each group sorted, lowest id first;
// deterministic).
export function duplicateVertGroups(m: Mesh, eps: f32): Array<Array<VertId>> {
    const ids = m.verts.ids();
    sortIds(ids);
    const cell = maxF32(eps, <f32>1e-9);
    const grid = new CellGrid();
    for (let i = 0; i < ids.length; i++) {
        const p = m.verts.at(ids[i]).co;
        grid.push(cellKey(p.x, cell), cellKey(p.y, cell), cellKey(p.z, cell), ids[i]);
    }
    const used = new Set<VertId>();
    const groups: Array<Array<VertId>> = [];
    for (let i = 0; i < ids.length; i++) {
        const v = ids[i];
        if (used.has(v)) continue;
        const p = m.verts.at(v).co;
        const kx = cellKey(p.x, cell);
        const ky = cellKey(p.y, cell);
        const kz = cellKey(p.z, cell);
        const group: Array<VertId> = [v];
        for (let dx: i64 = -1; dx <= 1; dx++) {
            for (let dy: i64 = -1; dy <= 1; dy++) {
                for (let dz: i64 = -1; dz <= 1; dz++) {
                    const list = grid.get(kx + dx, ky + dy, kz + dz);
                    if (list == null) continue;
                    for (let k = 0; k < list.length; k++) {
                        const w = list[k];
                        if (w != v && !used.has(w) && m.verts.at(w).co.distance(p) <= eps) group.push(w);
                    }
                }
            }
        }
        if (group.length > 1) {
            sortIds(group);
            for (let k = 0; k < group.length; k++) used.add(group[k]);
            groups.push(group);
        }
    }
    return groups;
}

// Connected components over vertices (through edges), each sorted.
export function connectedComponents(m: Mesh): Array<Array<VertId>> {
    const seen = new Set<VertId>();
    const out: Array<Array<VertId>> = [];
    const ids = m.verts.ids();
    sortIds(ids);
    for (let i = 0; i < ids.length; i++) {
        const start = ids[i];
        if (seen.has(start)) continue;
        const comp: Array<VertId> = [];
        const queue: Array<VertId> = [start];
        let head = 0;
        seen.add(start);
        while (head < queue.length) {
            const v = queue[head++];
            comp.push(v);
            const ns = m.vertNeighbors(v);
            for (let k = 0; k < ns.length; k++) {
                const n = ns[k];
                if (!seen.has(n)) {
                    seen.add(n);
                    queue.push(n);
                }
            }
        }
        sortIds(comp);
        out.push(comp);
    }
    return out;
}

// Faces connected to `start` through edges that pass `cross`.
export function linkedFaces(m: Mesh, start: FaceId, cross: (e: EdgeId) => bool): Array<FaceId> {
    const seen = new Set<FaceId>();
    const queue: Array<FaceId> = [start];
    let head = 0;
    seen.add(start);
    const out: Array<FaceId> = [];
    while (head < queue.length) {
        const f = queue[head++];
        out.push(f);
        const es = m.faceEdges(f);
        for (let i = 0; i < es.length; i++) {
            const e = es[i];
            if (!cross(e)) continue;
            const gs = m.edgeFaces(e);
            for (let k = 0; k < gs.length; k++) {
                const g = gs[k];
                if (!seen.has(g)) {
                    seen.add(g);
                    queue.push(g);
                }
            }
        }
    }
    sortIds(out);
    return out;
}

// Angle in radians between the two faces of a manifold edge; NaN for
// boundary or non-manifold edges. It is also NaN when a face normal is NaN
// (only a loaded file can carry one); a caller that must tell the two apart
// tests `m.edgeFaces(e).length == 2`.

export function edgeFaceAngle(m: Mesh, e: EdgeId): f32 {
    const faces = m.edgeFaces(e);
    if (faces.length != 2) return NaN;
    const a = m.faces.at(faces[0]).normal;
    const b = m.faces.at(faces[1]).normal;
    return acosf(clampF32(a.dot(b), -1.0, 1.0));
}

// Given the edge `e` of quad `f`, the edge on the other side of the quad
// (the "ring" neighbour). NO_ID when `f` is not a quad or `e` is not on it.
export function oppositeEdgeInQuad(m: Mesh, f: FaceId, e: EdgeId): EdgeId {
    const edges = m.faceEdges(f);
    if (edges.length != 4) return NO_ID;
    const i = edges.indexOf(e);
    if (i < 0) return NO_ID;
    return edges[(i + 2) % 4];
}
