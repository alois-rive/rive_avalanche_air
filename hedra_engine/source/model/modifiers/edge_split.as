// The Edge Split modifier, disconnect
// faces across sharp edges and edges whose face angle exceeds `angle`, so
// shading breaks there.

import { Mesh, Edge, VertId, EdgeId, FaceId, NO_ID } from "../mesh/mod";
import { Domain } from "../mesh/attr";

// Union-find root with path compression.
function find(parent: Array<i32>, i: i32): i32 {
    let r = i;
    while (parent[r] != r) r = parent[r];
    let c = i;
    while (parent[c] != r) {
        const n = parent[c];
        parent[c] = r;
        c = n;
    }
    return r;
}

function cmpU32(a: u32, b: u32): i32 {
    return a < b ? -1 : (a > b ? 1 : 0);
}

// Returns the number of added vertices.
export function edgeSplit(mesh: Mesh, angle: f32): i32 {
    const split = new Set<EdgeId>();
    const eb = mesh.edges.idBound();
    for (let id: u32 = 0; id < eb; id++) {
        const e = mesh.edges.get(id);
        if (e == null) continue;
        // edgeFaceAngle is NaN without two faces, and NaN > x is false.
        if (e.sharp || mesh.edgeFaceAngle(id) > angle) split.add(id);
    }
    if (split.size == 0) return 0;
    // Around each vertex, faces connected through unsplit edges form a
    // sector; the first sector keeps the vertex, the others get copies.
    // (Iterated below in sorted face id order.)
    const rings = new Map<FaceId, Array<VertId>>();
    const verts = mesh.verts.ids();
    let added = 0;
    for (let vi = 0; vi < verts.length; vi++) {
        const v = verts[vi];
        const faces = mesh.vertFaces(v);
        if (faces.length < 2) continue;
        const index = new Map<FaceId, i32>();
        for (let i = 0; i < faces.length; i++) index.set(faces[i], i);
        const parent: Array<i32> = [];
        for (let i = 0; i < faces.length; i++) parent.push(i);
        const vedges = mesh.vertEdges(v);
        for (let k = 0; k < vedges.length; k++) {
            const e = vedges[k];
            if (split.has(e)) continue;
            const ef = mesh.edgeFaces(e);
            for (let j = 1; j < ef.length; j++) {
                const a = find(parent, index.get(ef[0]));
                const b = find(parent, index.get(ef[j]));
                if (a != b) parent[a > b ? a : b] = a < b ? a : b;
            }
        }
        const keep = find(parent, 0);
        const copies = new Map<i32, VertId>();
        for (let i = 0; i < faces.length; i++) {
            const f = faces[i];
            const root = find(parent, i);
            if (root == keep) continue;
            let nv: VertId;
            if (copies.has(root)) {
                nv = copies.get(root);
            } else {
                added += 1;
                // A split vertex is a copy of the original, attributes
                // included: it is the same point of the surface, seen from
                // the other side of a sharp edge.
                const clone = mesh.verts.at(v).clone();
                nv = mesh.verts.push(clone);
                mesh.growAttrs(Domain.Point);
                mesh.copyAttrs(Domain.Point, v, nv);
                copies.set(root, nv);
            }
            if (!rings.has(f)) rings.set(f, mesh.faceVerts(f));
            const ring = rings.get(f);
            for (let r = 0; r < ring.length; r++) {
                if (ring[r] == v) ring[r] = nv;
            }
        }
    }
    if (added == 0) return 0;
    mesh.touch();
    const ringFaces = rings.keys();
    ringFaces.sort(cmpU32);
    for (let k = 0; k < ringFaces.length; k++) {
        const f = ringFaces[k];
        const ring = rings.get(f);
        const oldIds = mesh.faceEdges(f);
        const old: Array<Edge> = [];
        for (let i = 0; i < oldIds.length; i++) old.push(mesh.edges.at(oldIds[i]).clone());
        mesh.remapFaceVerts(f, ring);
        const n = ring.length;
        for (let i = 0; i < old.length; i++) {
            const src = old[i];
            const ne = mesh.findEdge(ring[i], ring[(i + 1) % n]);
            if (ne != NO_ID) {
                const dst = mesh.edges.at(ne);
                dst.copyMarks(src);
                dst.hide = src.hide;
            }
        }
    }
    // Split edges whose faces all moved to copies are left as wire: drop them.
    const candidates = split.values();
    const stale: Array<EdgeId> = [];
    for (let i = 0; i < candidates.length; i++) {
        const e = candidates[i];
        if (mesh.edges.contains(e) && mesh.edgeFaces(e).length == 0) stale.push(e);
    }
    stale.sort(cmpU32);
    for (let i = 0; i < stale.length; i++) mesh.removeEdge(stale[i]);
    return added;
}
