// Catmull-Clark subdivision with
// semi-sharp creases (PLAN §5).
//
// Rules, per level:
// - face point: face centroid; edge point: mean of the two end points and
//   the two adjacent face points; vertex point: `(F + 2R + (n-3)P) / n`.
// - boundary edges are infinitely sharp: their edge point is the midpoint
//   and a vertex on two of them uses the B-spline curve rule
//   `(6P + A + B) / 8` (Blender's default "All" boundary smoothing, which
//   rounds the corners of an open plane).
// - creases follow OpenSubdiv's semi-sharp scheme with Blender's mapping:
//   crease `c` in 0..1 is sharpness `10 c²` (1 = infinitely sharp). An edge
//   with sharpness `s` blends the smooth and sharp (midpoint) edge points by
//   `min(s, 1)`; a vertex on exactly two sharp edges blends the smooth and
//   crease vertex rules the same way, three or more make it a corner.
//   Child edges inherit sharpness `s - 1` (so a crease of 1 stays sharp
//   forever and lower values wear off level by level).
// - `sharp`-marked edges are treated as crease 1.
// - UVs are interpolated per loop, so seams survive; new faces keep the
//   parent's smooth flag and material.
//
// The three stencil passes (face, edge and vertex points) each only read
// the input mesh and write their own slot, so they are order-independent.

import { maxF32, minF32 } from "../../../base/util";
import { Vec2, Vec3 } from "../../../base/vecmath";
import { Mesh, Edge, NO_ID, GroupWeight, cloneGroups, interpolateGroups } from "../mesh/mod";
import { assignMesh } from "./mod";

export function subdivide(mesh: Mesh, levels: u32): void {
    for (let i: u32 = 0; i < levels; i++) {
        assignMesh(mesh, oneLevel(mesh));
    }
}

// Blender's `crease_to_sharpness`: quadratic, 1.0 is infinite. (Exported
// for the tests.)
export function sharpness(e: Edge): f32 {
    if (e.sharp || e.crease >= <f32>1.0) {
        return f32.POSITIVE_INFINITY;
    }
    // Squared as x * x.
    const c = maxF32(e.crease, 0);
    return (c * c) * <f32>10.0;
}

export function creaseFromSharpness(s: f32): f32 {
    if (isInfF32(s)) {
        return 1.0;
    }
    return minF32(Mathf.sqrt(s / <f32>10.0), 1.0);
}

function isInfF32(s: f32): bool {
    return s == f32.POSITIVE_INFINITY || s == f32.NEGATIVE_INFINITY;
}

const NONE: u32 = u32.MAX_VALUE;

function oneLevel(m: Mesh): Mesh {
    const out = Mesh.new();
    for (let i = 0; i < m.uvLayers.length; i++) out.uvLayers.push(m.uvLayers[i].clone());
    out.activeUv = m.activeUv;
    const layers = m.uvLayers.length;
    const vb = <i32>m.verts.idBound();
    const eb = <i32>m.edges.idBound();
    const fb = <i32>m.faces.idBound();

    // Face points and their UVs.
    const fpt = new Array<Vec3>(fb);
    const fuv = new Array<Array<Vec2>>(fb);
    for (let i = 0; i < fb; i++) {
        fpt[i] = Vec3(0, 0, 0);
        fuv[i] = [];
        const fid = <u32>i;
        const f = m.faces.get(fid);
        if (f == null) continue;
        fpt[i] = m.faceCenter(fid);
        const uv: Array<Vec2> = [];
        for (let k = 0; k < layers; k++) uv.push(Vec2(0, 0));
        for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
            const luv = m.loops.at(l).uv;
            for (let k = 0; k < luv.length; k++) {
                const u = luv[k];
                uv[k].x = uv[k].x + u.x;
                uv[k].y = uv[k].y + u.y;
            }
        }
        const len = <f32>f.loopLen;
        for (let k = 0; k < uv.length; k++) {
            uv[k].x = uv[k].x / len;
            uv[k].y = uv[k].y / len;
        }
        fuv[i] = uv;
    }

    // Effective sharpness: boundary edges are infinitely sharp.
    const esharp = new Array<f32>(eb);
    const ept = new Array<Vec3>(eb);
    for (let i = 0; i < eb; i++) {
        esharp[i] = 0;
        ept[i] = Vec3(0, 0, 0);
        const eid = <u32>i;
        const e = m.edges.get(eid);
        if (e == null) continue;
        const faces = m.edgeFaces(eid);
        const s = faces.length == 1 ? f32.POSITIVE_INFINITY : sharpness(e);
        esharp[i] = s;
        const mid = m.edgeCenter(eid);
        if (faces.length != 2 || s >= <f32>1.0) {
            ept[i] = mid;
        } else {
            const smooth = (m.verts.at(e.v[0]).co
                + m.verts.at(e.v[1]).co
                + fpt[<i32>faces[0]]
                + fpt[<i32>faces[1]])
                * <f32>0.25;
            ept[i] = smooth.lerp(mid, s);
        }
    }

    // Vertex points.
    const vpt = new Array<Vec3>(vb);
    for (let i = 0; i < vb; i++) {
        vpt[i] = Vec3(0, 0, 0);
        const vid = <u32>i;
        const v = m.verts.get(vid);
        if (v == null) continue;
        const p = v.co;
        const faces = m.vertFaces(vid);
        const edges: Array<u32> = [];
        const ve = m.vertEdges(vid);
        for (let k = 0; k < ve.length; k++) {
            if (m.edgeFaces(ve[k]).length != 0) edges.push(ve[k]);
        }
        const n = edges.length;
        if (faces.length == 0 || n < 2) {
            vpt[i] = p;
            continue;
        }
        let smooth = p;
        if (n >= 3) {
            // The Vec3 sum starts from ZERO.
            let fs = Vec3(0, 0, 0);
            for (let k = 0; k < faces.length; k++) fs = fs + fpt[<i32>faces[k]];
            const f = fs / <f32>faces.length;
            let rs = Vec3(0, 0, 0);
            for (let k = 0; k < n; k++) rs = rs + m.edgeCenter(edges[k]);
            const r = rs / <f32>n;
            smooth = (f + r * <f32>2.0 + p * (<f32>n - <f32>3.0)) / <f32>n;
        }
        const sharpE: Array<u32> = [];
        const sharpS: Array<f32> = [];
        for (let k = 0; k < n; k++) {
            const s = esharp[<i32>edges[k]];
            if (s > <f32>0.0) {
                sharpE.push(edges[k]);
                sharpS.push(s);
            }
        }
        const ns = sharpE.length;
        if (ns <= 1) {
            vpt[i] = smooth;
        } else if (ns == 2) {
            let a = m.edges.at(sharpE[0]).other(vid);
            if (a == NO_ID) a = vid;
            let b = m.edges.at(sharpE[1]).other(vid);
            if (b == NO_ID) b = vid;
            const crease = (p * <f32>6.0 + m.verts.at(a).co + m.verts.at(b).co) / <f32>8.0;
            const vs = (sharpS[0] + sharpS[1]) * <f32>0.5;
            vpt[i] = smooth.lerp(crease, minF32(vs, 1.0));
        } else {
            // The sum starts from -0.0, so an empty sum is -0.0.

            let sum: f32 = -0.0;
            for (let k = 0; k < ns; k++) sum += sharpS[k];
            const vs = sum / <f32>ns;
            vpt[i] = smooth.lerp(p, minF32(vs, 1.0));
        }
    }

    // One new vertex per old vertex, edge and face; one quad per corner.
    let corners = 0;
    const fvals = m.faces.values();
    for (let i = 0; i < fvals.length; i++) corners += <i32>fvals[i].loopLen;
    out.reserve(m.verts.len() + m.edges.len() + m.faces.len(), corners * 2, corners, corners * 4);

    // New vertices, in old id order so the result is deterministic.
    // Vertex group weights follow the same stencils as positions (the
    // vertex point keeps its own, edge and face points average theirs).
    const vmap = new Array<u32>(vb);
    vmap.fill(NONE);
    for (let i = 0; i < vb; i++) {
        const v = m.verts.get(<u32>i);
        if (v == null) continue;
        const nv = out.addVert(vpt[i]);
        const dst = out.verts.at(nv);
        dst.hide = v.hide;
        dst.groups = cloneGroups(v.groups);
        vmap[i] = nv;
    }
    const emap = new Array<u32>(eb);
    emap.fill(NONE);
    for (let i = 0; i < eb; i++) {
        const e = m.edges.get(<u32>i);
        if (e == null) continue;
        const nv = out.addVert(ept[i]);
        out.verts.at(nv).groups = interpolateGroups(
            [m.verts.at(e.v[0]).groups, m.verts.at(e.v[1]).groups],
            [<f32>0.5, <f32>0.5],
        );
        emap[i] = nv;
    }
    const fmap = new Array<u32>(fb);
    fmap.fill(NONE);
    for (let i = 0; i < fb; i++) {
        const f = m.faces.get(<u32>i);
        if (f == null) continue;
        const nv = out.addVert(fpt[i]);
        const w = <f32>1.0 / <f32>(f.loopLen > 1 ? f.loopLen : 1);
        const lists: Array<Array<GroupWeight>> = [];
        const factors: Array<f32> = [];
        for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
            lists.push(m.verts.at(m.loops.at(l).vert).groups);
            factors.push(w);
        }
        out.verts.at(nv).groups = interpolateGroups(lists, factors);
        fmap[i] = nv;
    }

    // One quad per face corner.
    for (let fi = 0; fi < fb; fi++) {
        const fid = <u32>fi;
        const f = m.faces.get(fid);
        if (f == null) continue;
        const loops = f.loops();
        const n = loops.length;
        for (let i = 0; i < n; i++) {
            const l = loops[i];
            const lp = loops[(i + n - 1) % n];
            const ln = loops[(i + 1) % n];
            const ll = m.loops.at(l);
            const llp = m.loops.at(lp);
            const lln = m.loops.at(ln);
            const v = ll.vert;
            const ring: Array<u32> = [
                vmap[<i32>v],
                emap[<i32>ll.edge],
                fmap[fi],
                emap[<i32>llp.edge],
            ];
            const nf = out.addFace(ring);
            const dst = out.faces.at(nf);
            dst.smooth = f.smooth;
            dst.materialIndex = f.materialIndex;
            dst.hide = f.hide;
            const start = dst.loopStart;
            const centers = fuv[fi];
            for (let layer = 0; layer < centers.length; layer++) {
                const centerUv = centers[layer];
                const uv0 = ll.uv[layer];
                const uvn = lln.uv[layer];
                const uvp = llp.uv[layer];
                const uvs: Array<Vec2> = [];
                uvs.push(uv0);
                uvs.push((uv0 + uvn) * <f32>0.5);
                uvs.push(centerUv);
                uvs.push((uv0 + uvp) * <f32>0.5);
                for (let k = 0; k < 4; k++) {
                    const target = out.loops.at(start + <u32>k).uv;
                    target[layer].x = uvs[k].x;
                    target[layer].y = uvs[k].y;
                }
            }
        }
    }

    // Child edges inherit the parent's marks with worn-down sharpness;
    // wire edges are kept as two halves.
    for (let i = 0; i < eb; i++) {
        const e = m.edges.get(<u32>i);
        if (e == null) continue;
        const s = sharpness(e);
        const child = creaseFromSharpness(isInfF32(s) ? s : maxF32(s - <f32>1.0, 0));
        const mid = emap[i];
        for (let k = 0; k < 2; k++) {
            const x = k == 0 ? vmap[<i32>e.v[0]] : mid;
            const y = k == 0 ? mid : vmap[<i32>e.v[1]];
            let ne = out.findEdge(x, y);
            if (ne == NO_ID) ne = out.addEdge(x, y);
            const dst = out.edges.at(ne);
            dst.seam = e.seam;
            dst.sharp = e.sharp;
            dst.crease = child;
            dst.bevelWeight = e.bevelWeight;
            dst.hide = e.hide;
        }
    }
    return out;
}
