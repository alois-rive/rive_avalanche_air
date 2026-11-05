// The Mirror modifier, append a mirrored
// copy of the mesh across each enabled local axis plane (X, Y, Z combine to
// up to eight copies), optionally clipping vertices onto the plane and
// welding the seam.

import { maxF32, stableSort } from "../../../base/util";
import { Mesh, VertId, GroupWeight } from "../mesh/mod";

function byGroup(a: GroupWeight, b: GroupWeight): i32 {
    return a.group < b.group ? -1 : (a.group > b.group ? 1 : 0);
}

// `axis` holds 3 bools (X, Y, Z). `flip[g]` is the vertex group a mirrored
// vertex's group `g` becomes (`.L` <-> `.R`); an empty array keeps groups as
// they are.
export function mirror(mesh: Mesh, axis: Array<bool>, clipping: bool, merge: bool, threshold: f32, flip: Array<u32>): void {
    const thr = maxF32(threshold, 0);
    for (let i = 0; i < 3; i++) {
        if (!axis[i]) continue;
        if (clipping) {
            // Blender's clipping keeps vertices from crossing the plane; for a
            // static mesh that means snapping the ones inside the merge band
            // onto it, which also makes the weld exact.
            mesh.touch();
            const vb = mesh.verts.idBound();
            for (let id: u32 = 0; id < vb; id++) {
                const v = mesh.verts.get(id);
                if (v == null) continue;
                if (Mathf.abs(v.co.get(i)) <= thr) v.co.set(i, 0);
            }
        }
        const copy = mesh.clone();
        const cb = copy.verts.idBound();
        for (let id: u32 = 0; id < cb; id++) {
            const v = copy.verts.get(id);
            if (v == null) continue;
            v.co.set(i, -v.co.get(i));
            if (flip.length > 0) {
                const groups = v.groups;
                for (let k = 0; k < groups.length; k++) {
                    const g = groups[k].group;
                    if (<i64>g < <i64>flip.length) groups[k].group = flip[<i32>g];
                }
                stableSort<GroupWeight>(groups, byGroup);
            }
        }
        flipFaces(copy);
        const vmap = mesh.append(copy, 0);
        if (merge && thr > 0) {
            // Only vertices near the plane can have a mirror image within the
            // threshold; the copy's images are found through the map.
            // (mergeByDistance sorts and dedups its input, so the order does
            // not matter.)
            const near: Array<VertId> = [];
            const srcs = vmap.keys();
            for (let k = 0; k < srcs.length; k++) {
                const src = srcs[k];
                if (Mathf.abs(copy.verts.at(src).co.get(i)) <= thr) {
                    near.push(src);
                    near.push(vmap.get(src));
                }
            }
            mesh.mergeByDistance(near, thr);
        }
    }
    mesh.recalcNormals();
}

// Reverse every face ring so normals point the other way (used after a
// reflection, which flips winding). Also used by solidify.

export function flipFaces(mesh: Mesh): void {
    const faces = mesh.faces.ids();
    for (let i = 0; i < faces.length; i++) {
        const f = faces[i];
        const ring = mesh.faceVerts(f);
        ring.reverse();
        mesh.setFaceVerts(f, ring);
    }
    mesh.recalcNormals();
}
