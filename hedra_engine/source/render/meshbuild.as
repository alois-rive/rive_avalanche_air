// Mesh -> GPU buffers (triangles, edge instances, point instances) plus the
// CPU side data labels and normals need, cached per object and keyed by the
// mesh revision, the modifier stack and the UV layer sampled. Every program
// that draws a .modeler model builds its meshes here, so a model is drawn
// from the same vertices whichever program draws it: Hedra
// (engine/src/authoring/model_view/meshdata.as re-exports this module, where it
// lived until milestone 4) and Hedra's tools (engine/src/source/scene/resource/
// model_source.as, which the engine's engine/src/scene/render/meshes.as asks).
//
// Objects with an active modifier stack draw the evaluated mesh. For the
// object being edited the surface is the evaluated mesh while edges, points
// and labels come from the base mesh (Blender's default "on cage off" look:
// the cage floats over the smooth result).
//
// Everything that does not touch the device is here. The upload itself
// is a `MeshUploader` the GPU side supplies (gpu/mesh_cache.as); it stores
// its buffers in `GpuMesh.gpu` (mesh.as). The CPU arrays stay on the entry
// (the label ray cast needs `verts` and `indices`, see raycast.as).

import { Vec2, Vec3, VEC2_ZERO, VEC3_ZERO, VEC4_ZERO } from "../../base/vecmath";
import { stableSort } from "../../base/util";
import { Mesh, GroupWeight, LoopId } from "../model/mesh/mod";
import { triangulateFaceInto } from "../model/mesh/triangulate";
import { Scene, Object } from "../model/scene";
import {
    F_HIDDEN, F_MESH, F_SEAM, F_SELECTED, F_SHARP, LineInstance, PointInstance, SurfaceVertex, WEIGHT_NONE,
} from "../../render/gpu/layouts";
import { FaceLabel, GpuMesh, IdPos, MaterialRange, MeshUploader } from "../../render/mesh";
import { MeshRequest, finishTangent, uv1LayerOf } from "../../render/mesh_build";
// (milestone 40: the model-free parts moved into the engine, which builds
// primitives' meshes with the same tangent rule; re-exported so every
// import of them from here holds)
export { MeshRequest, anyPerpendicular, finishTangent, uv1LayerOf } from "../../render/mesh_build";

// What a cached mesh was built from: mesh revision, modifier stack, cage
// mode, UV layer and weight group.
export class MeshKey {
    revision: u64;
    stack: u64;
    cage: bool;
    uvLayer: i32;
    // Vertex group baked into the `weight` attribute; -1 = none.
    weightGroup: i64;
    // The layer UV set 1 (GpuMesh.uv1) is built from; -1 = none.
    uv1Layer: i32;

    constructor(revision: u64, stack: u64, cage: bool, uvLayer: i32, weightGroup: i64, uv1Layer: i32 = -1) {
        this.revision = revision;
        this.stack = stack;
        this.cage = cage;
        this.uvLayer = uvLayer;
        this.weightGroup = weightGroup;
        this.uv1Layer = uv1Layer;
    }

    equals(o: MeshKey): bool {
        return this.revision == o.revision && this.stack == o.stack && this.cage == o.cage
            && this.uvLayer == o.uvLayer && this.weightGroup == o.weightGroup && this.uv1Layer == o.uv1Layer;
    }
}

class Entry {
    key: MeshKey;
    mesh: GpuMesh;

    constructor(key: MeshKey, mesh: GpuMesh) {
        this.key = key;
        this.mesh = mesh;
    }
}

export class MeshCache {
    // Keyed by ObjId. Only probed, never iterated for output.
    entries: Map<u32, Entry> = new Map<u32, Entry>();
    // How many meshes `get` built (lets tests and the GPU side see the cache
    // hit).
    builds: u32 = 0;

    // Buffers for a mesh object, rebuilt only when its mesh revision,
    // modifier stack or the request changed. null for non-mesh objects.
    // A rebuild is a new GpuMesh that takes over the CPU arrays of the one
    // it replaces (`build`'s `reuse`), so a mesh rebuilt every frame (a
    // skinned mesh in `render --anim`) keeps using the same memory: the
    // replaced GpuMesh keeps only its device buffers, for the caller to
    // release (FrameRenderer.retire).
    get(scene: Scene, id: u32, obj: Object, req: MeshRequest, uploader: MeshUploader?): GpuMesh? {
        const cage = req.cage;
        const weightGroup = req.weightGroup;
        const base = obj.mesh();
        if (base == null) return null;
        const stack = scene.modifierFingerprint(id);
        const li = base.uvLayerIndex(req.uvLayer);
        const layer = li >= 0 ? li : <i32>base.activeUv;
        const uv1Layer = req.uv1 ? uv1LayerOf(layer, base.uvLayers.length) : -1;
        const key = new MeshKey(base.revision, stack, cage && stack != 0, layer, weightGroup, uv1Layer);
        const had = this.entries.has(id);
        const stale = !had || !this.entries.get(id).key.equals(key);
        if (stale) {
            const old = had ? this.entries.get(id).mesh : null;
            let mesh: GpuMesh;
            if (stack == 0) {
                mesh = build(base, base, layer, weightGroup, uploader, old, uv1Layer);
            } else {
                // Read only, so the scene's own evaluated mesh (no copy).
                const evaluated = scene.evaluatedMeshShared(id);
                if (evaluated == null) return null;
                if (key.cage) {
                    mesh = build(evaluated, base, layer, weightGroup, uploader, old, uv1Layer);
                } else {
                    mesh = build(evaluated, evaluated, layer, weightGroup, uploader, old, uv1Layer);
                }
            }
            this.builds++;
            this.entries.set(id, new Entry(key, mesh));
        }
        return this.entries.has(id) ? this.entries.get(id).mesh : null;
    }

    peekEntry(id: u32): GpuMesh? {
        return this.entries.has(id) ? this.entries.get(id).mesh : null;
    }

    // Already-built buffers for an object, if any.
    peek(id: u32): GpuMesh? {
        return this.peekEntry(id);
    }

    // Drop entries for objects that no longer exist.
    retain(alive: (id: u32) => bool): void {
        const ids = this.entries.keys();
        for (let i = 0; i < ids.length; i++) {
            if (!alive(ids[i])) this.entries.delete(ids[i]);
        }
    }
}

// `(Vec3, Vec3)` tangent / bitangent sums.
class TangentPair {
    t: Vec3;
    b: Vec3;

    constructor(t: Vec3, b: Vec3) {
        this.t = t;
        this.b = b;
    }
}

// The running sums of `addTriTangent` (module scratch: they never escape a
// call of `faceTangent` or `buildVertices`).
let accT: Vec3 = VEC3_ZERO;
let accB: Vec3 = VEC3_ZERO;

// Adds the tangent and bitangent of the triangle `l0 l1 l2` (loop ids), from
// its UVs on `layer`, to `accT` / `accB`; nothing when the UVs are degenerate.
function addTriTangent(mesh: Mesh, l0: LoopId, l1: LoopId, l2: LoopId, layer: i32): void {
    const p0 = mesh.verts.at(mesh.loops.at(l0).vert).co;
    const p1 = mesh.verts.at(mesh.loops.at(l1).vert).co;
    const p2 = mesh.verts.at(mesh.loops.at(l2).vert).co;
    const uv0 = mesh.uv(l0, layer);
    const uv1 = mesh.uv(l1, layer);
    const uv2 = mesh.uv(l2, layer);
    const e1 = p1 - p0;
    const e2 = p2 - p0;
    const d1 = uv1 - uv0;
    const d2 = uv2 - uv0;
    const det = d1.x * d2.y - d2.x * d1.y;
    if (Mathf.abs(det) < <f32>1e-12) return;
    const r = <f32>1.0 / det;
    accT = accT + (e1 * d2.y - e2 * d1.y) * r;
    accB = accB + (e2 * d1.x - e1 * d2.x) * r;
}

// Unnormalized tangent and bitangent of a face from its UVs on `layer`
// (sum over its triangles; zero when the UVs are degenerate).
export function faceTangent(mesh: Mesh, f: u32, layer: i32): TangentPair {
    accT = VEC3_ZERO;
    accB = VEC3_ZERO;
    const tris = mesh.triangulateFace(f);
    for (let i = 0; i < tris.length; i++) {
        const tri = tris[i];
        addTriTangent(mesh, tri[0], tri[1], tri[2], layer);
    }
    return new TangentPair(accT, accB);
}

// A vertex's weight in `group`, WEIGHT_NONE when it is not a member (or no
// group is shown: group -1).
export function vertexWeight(groups: Array<GroupWeight>, group: i64): f32 {
    if (group < 0) return WEIGHT_NONE;
    for (let i = 0; i < groups.length; i++) {
        if (<i64>groups[i].group == group) return groups[i].weight;
    }
    return WEIGHT_NONE;
}

// The surface vertices, triangle indices and per-material index ranges of a
// mesh.
export class BuiltVertices {
    verts: Array<SurfaceVertex>;
    indices: Array<u32>;
    ranges: Array<MaterialRange>;
    // UV set 1 by vertex when `buildVertices` was asked for it, else null.
    uv1: Array<Vec2>? = null;

    constructor(verts: Array<SurfaceVertex>, indices: Array<u32>, ranges: Array<MaterialRange>) {
        this.verts = verts;
        this.indices = indices;
        this.ranges = ranges;
    }
}

// Working memory of `buildVertices`, kept from one call to the next (one
// build runs at a time and nothing in it escapes a call), so building the
// same mesh again, as `render --anim` does for a skinned mesh every frame,
// allocates nothing new.
class BuildScratch {
    // Per vertex id: smooth normal and tangent sums, and whether a smooth
    // face touched it.
    vnormals: Array<Vec3> = [];
    vtT: Array<Vec3> = [];
    vtB: Array<Vec3> = [];
    vhas: Uint8Array = new Uint8Array(0);
    // Per face id: the face's tangent and bitangent sums.
    ftT: Array<Vec3> = [];
    ftB: Array<Vec3> = [];
    // Every face's triangles, as loop-id triples, faces in id order; the
    // run of face `f` is `tris[triStart[f] .. triStart[f + 1]]`.
    tris: Array<LoopId> = [];
    triStart: Int32Array = new Int32Array(0);
    // Per entry of `tris`: the index of its corner's vertex in `verts`.
    corner: Array<u32> = [];
    // The dedup table: open addressing over `SurfaceVertex.hash`, holding
    // index + 1 into `verts` (0 = empty).
    table: Int32Array = new Int32Array(0);
    // Per material slot: the corners using it, then the next free index in
    // its range. Only the slots in `slots` are nonzero between calls.
    slotCount: Int32Array = new Int32Array(0x10000);
    slotNext: Int32Array = new Int32Array(0x10000);
    // The slots the mesh uses, in first-use order.
    slots: Array<u16> = [];
    // Per entry of `verts`, its mesh vertex id (buildVertices' `origins`
    // only).
    vertOf: Array<u32> = [];
}

let buildScratch: BuildScratch? = null;

function scratch(): BuildScratch {
    let s = buildScratch;
    if (s == null) {
        s = new BuildScratch();
        buildScratch = s;
    }
    return s;
}

// `a` holding `n` copies of VEC3_ZERO (reusing its storage).
function zeroed(a: Array<Vec3>, n: i32): void {
    a.length = 0;
    for (let i = 0; i < n; i++) a.push(VEC3_ZERO);
}

// Triangle vertices of `surface` sampling UV `layer`, with an index list
// grouped by material slot, smooth or flat normals and tangents to match,
// and the weight in `weightGroup` (vertex groups survive modifier
// evaluation; -1 = none).
//
// Vertices are deduplicated on their exact bit pattern, so a smooth-shaded
// mesh uploads roughly one vertex per mesh vertex instead of three per
// triangle. Flat faces and UV seams keep their own copies, because their
// corners differ in the normal or the UV.
//
// `into` (optional): arrays to fill instead of new ones (their contents are
// replaced); the result is then `into` itself.
//
// `uv1Layer` (milestone 14, part 2; -1 = none): UV set 1 is read from that
// layer into `uv1`, a vertex's alongside it, and two corners merge only when
// their set 1 agrees too. Without it the vertices are exactly as before.
//
// `origins` (null: none): filled with the loop id of the first corner each
// vertex of `verts` was made from, and two corners merge only when they
// are of the same mesh vertex too, so that a vertex of `verts` is one mesh
// vertex's: a skinned or morphed model's mesh reads each one's weights and
// shape key offsets from there (engine/src/source/scene/resource/
// model_skeleton.as). Two coincident vertices of a mesh may belong to
// different bones; merged, one would follow the other's. Without it the
// vertices are exactly as before, as Hedra draws them.
export function buildVertices(
    surface: Mesh, layer: i32, weightGroup: i64, into: BuiltVertices? = null, uv1Layer: i32 = -1,
    origins: Array<u32>? = null,
): BuiltVertices {
    const sc = scratch();
    // Smooth vertex normals / tangents: sums over the adjacent smooth faces,
    // in face order (arrays indexed by id, only probed, never iterated).
    const vbound = <i32>surface.verts.idBound();
    const fbound = <i32>surface.faces.idBound();
    const vnormals = sc.vnormals;
    const vtT = sc.vtT;
    const vtB = sc.vtB;
    zeroed(vnormals, vbound);
    zeroed(vtT, vbound);
    zeroed(vtB, vbound);
    if (sc.vhas.length < vbound) sc.vhas = new Uint8Array(vbound);
    const vhas = sc.vhas;
    vhas.fill(0, 0, vbound);
    const ftT = sc.ftT;
    const ftB = sc.ftB;
    zeroed(ftT, fbound);
    zeroed(ftB, fbound);
    // Each face is triangulated once, for both passes.
    const tris = sc.tris;
    tris.length = 0;
    if (sc.triStart.length < fbound + 1) sc.triStart = new Int32Array(fbound + 1);
    const triStart = sc.triStart;
    for (let fid: u32 = 0; fid < <u32>fbound; fid++) {
        triStart[fid] = tris.length;
        const f = surface.faces.get(fid);
        if (f == null) continue;
        triangulateFaceInto(surface, fid, tris);
        accT = VEC3_ZERO;
        accB = VEC3_ZERO;
        for (let k = <i32>triStart[fid]; k < tris.length; k += 3) {
            addTriTangent(surface, tris[k], tris[k + 1], tris[k + 2], layer);
        }
        const t = accT;
        const b = accB;
        ftT[fid] = t;
        ftB[fid] = b;
        if (f.smooth) {
            for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
                const v = surface.loops.at(l).vert;
                vhas[v] = 1;
                vnormals[v] = vnormals[v] + f.normal;
                vtT[v] = vtT[v] + t;
                vtB[v] = vtB[v] + b;
            }
        }
    }
    triStart[fbound] = tris.length;
    let verts: Array<SurfaceVertex>;
    let indices: Array<u32>;
    let ranges: Array<MaterialRange>;
    if (into != null) {
        verts = into.verts;
        indices = into.indices;
        ranges = into.ranges;
        verts.length = 0;
        ranges.length = 0;
    } else {
        verts = [];
        indices = [];
        ranges = [];
    }
    // The key is the vertex's own bytes, so two corners merge only when the
    // GPU would draw them identically: a table of indices into `verts`,
    // probed with the vertex's hash, at most half full.
    let cap = 16;
    while (cap < tris.length * 2) cap <<= 1;
    if (sc.table.length < cap) sc.table = new Int32Array(cap);
    const table = sc.table;
    table.fill(0, 0, cap);
    const mask = <u32>(cap - 1);
    const corner = sc.corner;
    corner.length = 0;
    const uv1s: Array<Vec2>? = uv1Layer >= 0 ? [] : null;
    // (the vertex's own id beside it, for `origins`: one per entry of
    // `verts`, compared before the vertex is taken as a match)
    const byVert = origins != null;
    if (origins != null) origins.length = 0;
    const vertOf = sc.vertOf;
    vertOf.length = 0;
    const slotCount = sc.slotCount;
    const slots = sc.slots;
    slots.length = 0;
    for (let fid: u32 = 0; fid < <u32>fbound; fid++) {
        const f = surface.faces.get(fid);
        if (f == null) continue;
        let flags: u32 = 0;
        if (f.select) flags |= F_SELECTED;
        if (f.hide) flags |= F_HIDDEN;
        const from = <i32>triStart[fid];
        const to = <i32>triStart[fid + 1];
        for (let k = from; k < to; k++) {
            const lp = surface.loops.at(tris[k]);
            let n: Vec3;
            let t: Vec3;
            let b: Vec3;
            if (f.smooth) {
                if (vhas[lp.vert] != 0) {
                    n = vnormals[lp.vert].normalizeOrZero();
                    t = vtT[lp.vert];
                    b = vtB[lp.vert];
                } else {
                    n = f.normal;
                    t = VEC3_ZERO;
                    b = VEC3_ZERO;
                }
            } else {
                // Every face was filled by the loop above.
                n = f.normal;
                t = ftT[fid];
                b = ftB[fid];
            }
            const vert = surface.verts.at(lp.vert);
            const uv: Vec2 = layer >= 0 && layer < lp.uv.length ? lp.uv[layer] : VEC2_ZERO;
            const sv = SurfaceVertex(vert.co, n, uv, flags, finishTangent(n, t, b), vertexWeight(vert.groups, weightGroup));
            let h = sv.hash() & mask;
            let idx: u32 = 0;
            if (byVert) {
                // The vertex id is part of the key (see `origins`).
                const vid = lp.vert;
                const uv1: Vec2 = uv1Layer >= 0 && uv1Layer < lp.uv.length ? lp.uv[uv1Layer] : VEC2_ZERO;
                h = (h ^ (vid * 2246822519)) & mask;
                while (true) {
                    const e = table[h];
                    if (e == 0) {
                        verts.push(sv);
                        vertOf.push(vid);
                        (origins as Array<u32>).push(tris[k]);
                        if (uv1s != null) uv1s.push(uv1);
                        idx = <u32>(verts.length - 1);
                        table[h] = <i32>idx + 1;
                        break;
                    }
                    const j = e - 1;
                    if (vertOf[j] == vid && verts[j] == sv) {
                        if (uv1s == null) {
                            idx = <u32>j;
                            break;
                        }
                        const o = uv1s[j];
                        if (reinterpret<u32>(o.x) == reinterpret<u32>(uv1.x) && reinterpret<u32>(o.y) == reinterpret<u32>(uv1.y)) {
                            idx = <u32>j;
                            break;
                        }
                    }
                    h = (h + 1) & mask;
                }
                corner.push(idx);
                continue;
            }
            if (uv1s != null) {
                // UV set 1 is part of the key.
                const uv1: Vec2 = uv1Layer < lp.uv.length ? lp.uv[uv1Layer] : VEC2_ZERO;
                h = (h ^ ((reinterpret<u32>(uv1.x) * 16777619) ^ (reinterpret<u32>(uv1.y) * 2654435761))) & mask;
                while (true) {
                    const e = table[h];
                    if (e == 0) {
                        verts.push(sv);
                        uv1s.push(uv1);
                        idx = <u32>(verts.length - 1);
                        table[h] = <i32>idx + 1;
                        break;
                    }
                    const o = uv1s[e - 1];
                    if (verts[e - 1] == sv && reinterpret<u32>(o.x) == reinterpret<u32>(uv1.x)
                        && reinterpret<u32>(o.y) == reinterpret<u32>(uv1.y)) {
                        idx = <u32>(e - 1);
                        break;
                    }
                    h = (h + 1) & mask;
                }
                corner.push(idx);
                continue;
            }
            while (true) {
                const e = table[h];
                if (e == 0) {
                    verts.push(sv);
                    idx = <u32>(verts.length - 1);
                    table[h] = <i32>idx + 1;
                    break;
                }
                if (verts[e - 1] == sv) {
                    idx = <u32>(e - 1);
                    break;
                }
                h = (h + 1) & mask;
            }
            corner.push(idx);
        }
        // A face without triangles still gives its slot a (0-long) range.
        const slot = f.materialIndex;
        if (slotCount[slot] == 0 && !slots.includes(slot)) slots.push(slot);
        slotCount[slot] += to - from;
    }
    // Ranges in ascending slot order; within a slot, faces in id order.
    stableSort<u16>(slots, (a: u16, b: u16): i32 => (a < b ? -1 : a > b ? 1 : 0));
    const slotNext = sc.slotNext;
    let total = 0;
    for (let i = 0; i < slots.length; i++) {
        const slot = slots[i];
        const count = slotCount[slot];
        ranges.push(MaterialRange(slot, <u32>total, <u32>count));
        slotNext[slot] = total;
        total += count;
    }
    indices.length = total;
    for (let fid: u32 = 0; fid < <u32>fbound; fid++) {
        const f = surface.faces.get(fid);
        if (f == null) continue;
        const slot = f.materialIndex;
        let at = slotNext[slot];
        for (let k = <i32>triStart[fid]; k < <i32>triStart[fid + 1]; k++) {
            indices[at] = corner[k];
            at++;
        }
        slotNext[slot] = at;
    }
    for (let i = 0; i < slots.length; i++) {
        slotCount[slots[i]] = 0;
        slotNext[slots[i]] = 0;
    }
    if (into != null) {
        into.uv1 = uv1s;
        return into;
    }
    const out = new BuiltVertices(verts, indices, ranges);
    out.uv1 = uv1s;
    return out;
}

// Triangles from `surface`; edges, points and labels from `wire` (the same
// mesh unless a cage is drawn over an evaluated surface). `uploader` (the
// device) turns the arrays into buffers; null builds the CPU side only.
// `reuse`: the GpuMesh this one replaces; the new one takes over its CPU
// arrays (and label objects), refilled, and `reuse` is left with empty ones
// and its device buffers.
// `uv1Layer`: buildVertices's (milestone 14, part 2), into GpuMesh.uv1.
// `origins`: buildVertices's, filled with each vertex's first loop (null:
// vertices as Hedra draws them).
export function build(
    surface: Mesh, wire: Mesh, layer: i32, weightGroup: i64, uploader: MeshUploader?, reuse: GpuMesh? = null,
    uv1Layer: i32 = -1, origins: Array<u32>? = null,
): GpuMesh {
    const g = new GpuMesh();
    let into: BuiltVertices? = null;
    if (reuse != null) {
        into = new BuiltVertices(reuse.verts, reuse.indices, reuse.ranges);
        g.faces = reuse.faces;
        g.edges = reuse.edges;
        g.edgeLabels = reuse.edgeLabels;
        g.points = reuse.points;
        g.vertLabels = reuse.vertLabels;
        g.uploadBytes = reuse.uploadBytes;
        reuse.verts = [];
        reuse.indices = [];
        reuse.ranges = [];
        reuse.faces = [];
        reuse.edges = [];
        reuse.edgeLabels = [];
        reuse.points = [];
        reuse.vertLabels = [];
        reuse.uploadBytes = [];
    }
    const built = buildVertices(surface, layer, weightGroup, into, uv1Layer, origins);
    const faces = g.faces;
    let nf = 0;
    const fbound = wire.faces.idBound();
    for (let fid: u32 = 0; fid < fbound; fid++) {
        const f = wire.faces.get(fid);
        if (f == null) continue;
        const center = wire.faceCenter(fid);
        if (nf < faces.length) {
            const x = faces[nf];
            x.id = fid;
            x.center = center;
            x.normal = f.normal;
            x.selected = f.select;
        } else {
            faces.push(new FaceLabel(fid, center, f.normal, f.select));
        }
        nf++;
    }
    faces.length = nf;
    const edges = g.edges;
    edges.length = 0;
    const edgeLabels = g.edgeLabels;
    let ne = 0;
    const ebound = wire.edges.idBound();
    for (let eid: u32 = 0; eid < ebound; eid++) {
        const e = wire.edges.get(eid);
        if (e == null) continue;
        let flags = F_MESH;
        if (e.select) flags |= F_SELECTED;
        if (e.hide) flags |= F_HIDDEN;
        if (e.seam) flags |= F_SEAM;
        if (e.sharp) flags |= F_SHARP;
        const ev = e.v;
        const a = wire.verts.at(ev[0]).co;
        const b = wire.verts.at(ev[1]).co;
        edges.push(LineInstance(a, b, VEC4_ZERO, 1.0, flags));
        setIdPos(edgeLabels, ne, eid, (a + b) * <f32>0.5);
        ne++;
    }
    edgeLabels.length = ne;
    const points = g.points;
    points.length = 0;
    const vertLabels = g.vertLabels;
    let nv = 0;
    const vbound = wire.verts.idBound();
    for (let vid: u32 = 0; vid < vbound; vid++) {
        const v = wire.verts.get(vid);
        if (v == null) continue;
        let flags = F_MESH;
        if (v.select) flags |= F_SELECTED;
        if (v.hide) flags |= F_HIDDEN;
        points.push(PointInstance(v.co, 4.0, VEC4_ZERO, flags));
        setIdPos(vertLabels, nv, vid, v.co);
        nv++;
    }
    vertLabels.length = nv;
    g.verts = built.verts;
    g.uv1 = built.uv1;
    g.indices = built.indices;
    g.indexCount = <u32>built.indices.length;
    g.ranges = built.ranges;
    g.edgeCount = <u32>edges.length;
    g.pointCount = <u32>points.length;
    if (uploader != null) uploader.upload(g);
    return g;
}

// `list[i] = (id, pos)`, reusing the IdPos already there.
function setIdPos(list: Array<IdPos>, i: i32, id: u32, pos: Vec3): void {
    if (i < list.length) {
        const x = list[i];
        x.id = id;
        x.pos = pos;
    } else {
        list.push(new IdPos(id, pos));
    }
}

// The UV layer an object's textures sample through: the first texture
// reference across its material slots that names a layer, else the active
// layer (null). One layer serves all textures of an object.
export function textureLayer(scene: Scene, obj: Object): string? {
    for (let s = 0; s < obj.materialSlots.length; s++) {
        const i = obj.materialSlots[s];
        if (<i64>i >= <i64>scene.materials.length) continue;
        const texs = scene.materials[i].textures.iter();
        for (let k = 0; k < texs.length; k++) {
            const l = texs[k].tex.uvLayer;
            if (l != null) return l;
        }
    }
    return null;
}

// Index into `scene.materials` for a face's material slot, -1
// when the slot is missing or dangling (the default material then applies).
export function materialIndex(scene: Scene, obj: Object, slot: u16): i64 {
    if (<i32>slot >= obj.materialSlots.length) return -1;
    const i = obj.materialSlots[slot];
    return <i64>i < <i64>scene.materials.length ? <i64>i : -1;
}
