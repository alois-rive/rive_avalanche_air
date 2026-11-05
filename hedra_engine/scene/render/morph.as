// Blend shapes as the renderer draws them (docs/plans/RIVE_MODEL.md
// section 3.7; docs/engine/ANIMATION.md, "Skeletons and imported clips").
//
// A mesh with blend shapes (GpuMesh.morphs: glTF's morph targets, an
// .rmdl's shape keys) is drawn, by a node whose weights are not all 0, as
// a copy of the mesh with each vertex moved by its weighted deltas: the
// position base + sum(w * delta), the normal likewise, then normalised.
// The blending is done here, on the CPU, into the node's own copy
// (`MorphCache`), and only when the node's weights changed
// (MeshInstance3D.blendVersion moved): a blend shape changes at most once a
// frame, and blending on the GPU would cost a vertex attribute per target.
// A skinned mesh is blended first and skinned after, on the GPU, from the
// blended copy, which carries the base's skin.
//
// The copy (`DeformedMesh`, which the wire shadings' CPU skinning in
// skinning.as uses too) shares everything with its base but its vertices
// and wire edges: its vertex and edge buffers are made rewritable
// (GpuMesh.deforms) and written again in place (MeshUploader
// .updateVertices), so a node whose weights move every frame allocates
// nothing once its copy exists. All weights 0 draws the base itself.
//
// Milestone 67b: the base's vertices are read again whenever the weights
// move, so a run time that releases CPU copies after upload never releases
// a mesh with blend shapes, a skin or rewritable buffers
// (scene/resource/cpu_copy.as); a copy made from one released all the same
// counts a miss.

import { Vec3 } from "../../base/vecmath";
import { noteCpuMiss } from "../resource/cpu_copy";
import { Bounds } from "../../render/camera";
import { GpuMesh, MeshUploader } from "../../render/mesh";
import { LineInstance, SurfaceVertex } from "../../render/gpu/layouts";

// A copy of `base` whose vertices (and edges) are rewritten (see the
// header). `out.verts` start as the base's; after writing them, `finish`
// moves the edges with them, measures the box and hands the result to the
// device.
export class DeformedMesh {
    base: GpuMesh;
    out: GpuMesh;
    // For edge e of the base, the vertex of `verts` at each of its ends (an
    // edge is two positions, and the vertices of one position move alike:
    // they share their weights, or their deltas), -1 for an end no vertex
    // is at (left where the base has it).
    private edgeA: Int32Array;
    private edgeB: Int32Array;
    // The box of `out.verts` as last written.
    local: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    // The copy changed while there was no uploader to hand it to: the next
    // `flush` with one does.
    stale: bool = false;

    constructor(base: GpuMesh) {
        this.base = base;
        if (base.cpuReleased) noteCpuMiss("deform: a released mesh");
        const out = new GpuMesh();
        out.verts = base.verts.slice(0);
        out.uv1 = base.uv1;
        out.indices = base.indices;
        out.indexCount = base.indexCount;
        out.ranges = base.ranges;
        out.lods = base.lods;
        out.skinJoints = base.skinJoints;
        out.skinWeights = base.skinWeights;
        out.morphs = base.morphs;
        out.edges = base.edges.slice(0);
        out.edgeCount = base.edgeCount;
        out.deforms = true;
        this.out = out;
        const ne = base.edges.length;
        this.edgeA = new Int32Array(ne);
        this.edgeB = new Int32Array(ne);
        if (ne > 0) {
            // Each position's first vertex, by the bits of its coordinates
            // (-0 made 0), once.
            const at = new Map<string, i32>();
            const vs = base.verts;
            for (let i = 0; i < vs.length; i++) {
                const k = positionKey(vs[i].pos);
                if (!at.has(k)) at.set(k, i);
            }
            for (let e = 0; e < ne; e++) {
                const l = base.edges[e];
                const ka = positionKey(l.a);
                const kb = positionKey(l.b);
                this.edgeA[e] = at.has(ka) ? at.get(ka) : -1;
                this.edgeB[e] = at.has(kb) ? at.get(kb) : -1;
            }
        }
        this.local = boxOf(out.verts);
    }

    // After `out.verts` were written: the edges moved to their vertices,
    // the box measured, and the copy uploaded (the first time) or written
    // in place through `uploader`; with no uploader (a plan made without a
    // device), marked stale for `flush`. A device that cannot rewrite it
    // gets it uploaded anew, the old buffers handed to `replaced` for the
    // renderer to release. Allocates nothing once uploaded.
    finish(uploader: MeshUploader?, replaced: Array<GpuMesh>): void {
        const out = this.out;
        const vs = out.verts;
        const edges = out.edges;
        const ea = this.edgeA;
        const eb = this.edgeB;
        for (let e = 0; e < edges.length; e++) {
            const a = unchecked(ea[e]);
            const b = unchecked(eb[e]);
            if (a < 0 && b < 0) continue;
            const l = unchecked(edges[e]);
            unchecked(edges[e] = LineInstance(a >= 0 ? unchecked(vs[a]).pos : l.a, b >= 0 ? unchecked(vs[b]).pos : l.b,
                l.color, l.width, l.flags));
        }
        this.local = boxOf(vs);
        // (picking and label occlusion build their BVH from these vertices)
        out.invalidateBvh();
        this.flush(uploader, replaced);
    }

    // The copy is given up (its base changed): its buffers, if it has any,
    // go to `replaced` for the renderer to release with the frame's.
    retire(replaced: Array<GpuMesh>): void {
        const out = this.out;
        if (out.gpu == null) return;
        const old = new GpuMesh();
        old.gpu = out.gpu;
        out.gpu = null;
        replaced.push(old);
    }

    // Whether this copy's vertices and edges fit `g` as well as its base:
    // the same vertex count, triangles and edge count (a node's blended
    // copy of the base, which shares them), so the copy can be kept when
    // the mesh it is made from switches between the two.
    fits(g: GpuMesh): bool {
        const b = this.base;
        return g === b || (g.indices === b.indices && g.verts.length == b.verts.length
            && g.edges.length == b.edges.length);
    }

    // Hands the copy to the device when it changed without one (`stale`),
    // or was never uploaded.
    flush(uploader: MeshUploader?, replaced: Array<GpuMesh>): void {
        const out = this.out;
        if (uploader == null) {
            if (out.gpu != null) this.stale = true;
            return;
        }
        this.stale = false;
        if (out.gpu == null) {
            uploader.upload(out);
            return;
        }
        if (uploader.updateVertices(out)) return;
        const old = new GpuMesh();
        old.gpu = out.gpu;
        out.gpu = null;
        replaced.push(old);
        uploader.upload(out);
    }
}

// What a node's blend shapes draw (see the header): one per node (and per
// part of a model drawn as one node), kept by the scene render cache.
export class MorphCache {
    // The copy, made from the first base asked for (a new base, a mesh
    // rebuilt, makes a new copy).
    mesh: DeformedMesh? = null;
    // The weights' version the copy was blended at (`known`: it was).
    version: u32 = 0;
    known: bool = false;
    // How many times the copy was blended (tests see an unchanged weight
    // do no work).
    blends: i32 = 0;
    // The scene render cache's epoch when a plan last used it.
    seen: u32 = 0;

    // `base` drawn with `weights` (by blend shape, as base.morphs): `base`
    // itself when every weight is 0 or it has no blend shapes, else this
    // node's copy, blended again only when `version` differs from the last
    // (the weights are the node's, whose version moves whenever one
    // changes) and then handed to `uploader` (see DeformedMesh.finish).
    blended(
        base: GpuMesh, weights: Array<f32>, version: u32, uploader: MeshUploader? = null,
        replaced: Array<GpuMesh>? = null,
    ): GpuMesh {
        const morphs = base.morphs;
        if (morphs == null || !anyWeight(weights, morphs.length)) return base;
        const keep = replaced != null ? replaced : noReplaced;
        let d = this.mesh;
        if (d == null || d.base !== base) {
            // (a new base: the old copy's buffers are released)
            if (d != null) d.retire(keep);
            d = new DeformedMesh(base);
            this.mesh = d;
            this.known = false;
        }
        if (this.known && this.version == version) {
            if (d.stale || d.out.gpu == null) d.flush(uploader, keep);
            return d.out;
        }
        blendInto(base, weights, d.out.verts);
        d.finish(uploader, keep);
        this.version = version;
        this.known = true;
        this.blends++;
        return d.out;
    }

    // The box of what `blended` returned last (the base's when it was the
    // base: the caller's own).
    get local(): Bounds {
        const d = this.mesh;
        return d != null ? d.local : Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    }
}

// (where `blended` puts replaced buffers when its caller keeps none: a test)
const noReplaced: Array<GpuMesh> = [];

// Whether any of the first `n` weights is not 0.
function anyWeight(weights: Array<f32>, n: i32): bool {
    const m = min<i32>(weights.length, n);
    for (let i = 0; i < m; i++) if (unchecked(weights[i]) != 0) return true;
    return false;
}

// `out[i]` = base.verts[i] with its position base + sum(w * delta) and its
// normal likewise, normalised when a target moves the normals (a zero sum
// keeps the base's). Allocates nothing: `out` has the base's length.
export function blendInto(base: GpuMesh, weights: Array<f32>, out: Array<SurfaceVertex>): void {
    const morphs = base.morphs;
    const vs = base.verts;
    const n = min<i32>(vs.length, out.length);
    if (morphs == null) {
        for (let i = 0; i < n; i++) unchecked(out[i] = unchecked(vs[i]));
        return;
    }
    const targets = min<i32>(morphs.length, weights.length);
    for (let i = 0; i < n; i++) {
        const v = unchecked(vs[i]);
        let px = v.pos.x, py = v.pos.y, pz = v.pos.z;
        let nx = v.normal.x, ny = v.normal.y, nz = v.normal.z;
        let moved = false;
        const k = i * 3;
        for (let t = 0; t < targets; t++) {
            const w = unchecked(weights[t]);
            if (w == 0) continue;
            const m = unchecked(morphs[t]);
            const dp = m.positions;
            if (k + 2 < dp.length) {
                px += w * unchecked(dp[k]);
                py += w * unchecked(dp[k + 1]);
                pz += w * unchecked(dp[k + 2]);
            }
            const dn = m.normals;
            if (dn != null && k + 2 < dn.length) {
                nx += w * unchecked(dn[k]);
                ny += w * unchecked(dn[k + 1]);
                nz += w * unchecked(dn[k + 2]);
                moved = true;
            }
        }
        let normal = v.normal;
        if (moved) {
            const len = Mathf.sqrt(nx * nx + ny * ny + nz * nz);
            if (len > 0) normal = Vec3(nx / len, ny / len, nz / len);
        }
        unchecked(out[i] = SurfaceVertex(Vec3(px, py, pz), normal, v.uv, v.flags, v.tangent, v.weight));
    }
}

// The box of `vs` (a point at the origin for none).
export function boxOf(vs: Array<SurfaceVertex>): Bounds {
    if (vs.length == 0) return Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    let lx = f32.MAX_VALUE, ly = f32.MAX_VALUE, lz = f32.MAX_VALUE;
    let hx = -f32.MAX_VALUE, hy = -f32.MAX_VALUE, hz = -f32.MAX_VALUE;
    for (let i = 0; i < vs.length; i++) {
        const p = unchecked(vs[i]).pos;
        if (p.x < lx) lx = p.x;
        if (p.y < ly) ly = p.y;
        if (p.z < lz) lz = p.z;
        if (p.x > hx) hx = p.x;
        if (p.y > hy) hy = p.y;
        if (p.z > hz) hz = p.z;
    }
    return Bounds(Vec3(lx, ly, lz), Vec3(hx, hy, hz));
}

// A position's key: its coordinates' bits, -0 made 0 (meshes.as's
// triangleEdges keys positions the same way).
function positionKey(p: Vec3): string {
    const x = p.x == 0 ? <f32>0 : p.x;
    const y = p.y == 0 ? <f32>0 : p.y;
    const z = p.z == 0 ? <f32>0 : p.z;
    return reinterpret<u32>(x).toString() + "," + reinterpret<u32>(y).toString() + "," + reinterpret<u32>(z).toString();
}
