// A mesh as the renderer draws it: triangle vertices and indices grouped by
// material slot, edge and point instances, and the CPU-side data labels and
// normals need, plus the device buffers a `MeshUploader` made from them.
// A program builds these (Hedra's meshdata.as from its meshes;
// `GpuMesh.fromArrays` from plain triangle lists) and uploads them through
// the GPU side (gpu/mesh_cache.as). The CPU arrays stay on the mesh (the
// label ray cast needs `verts` and `indices`, see raycast.as), unless a
// run time lets go of them once the buffers exist (milestone 67b,
// `GpuMesh.releaseCpu`: what is read later, its counts, its box, its
// levels' sphere and the triangles the listeners pick, is worked out first
// and kept).

import { Vec2, Vec3 } from "../base/vecmath";
import { stableSort } from "../base/util";
import { Bounds } from "./camera";
import {
    F_HIDDEN, LINE_INSTANCE_SIZE, LineInstance, POINT_INSTANCE_SIZE, PointInstance, SURFACE_VERTEX_SIZE, SurfaceVertex,
} from "./gpu/layouts";
import { TriBvh, appendTriangles } from "./raycast";

// A run of triangle vertices sharing one material slot.
export struct MaterialRange {
    slot: u16 = 0;
    first: u32 = 0;
    count: u32 = 0;

    constructor(slot: u16, first: u32, count: u32) {
        this.slot = slot;
        this.first = first;
        this.count = count;
    }

    operator==(a: MaterialRange, b: MaterialRange): bool {
        return a.slot == b.slot && a.first == b.first && a.count == b.count;
    }
    readonly hash(): u32 { return <u32>this.slot * 73856093 ^ this.first * 19349663 ^ this.count * 83492791; }
    // Debug text.
    readonly debug(): string { return `MaterialRange { slot: ${this.slot}, first: ${this.first}, count: ${this.count} }`; }
}

// Milestone 26: one generated level of detail of a mesh (Godot's
// automatic LODs): the same vertices as level 0, fewer triangles. Made by
// compiler/src/meshproc/lods.as generateLods from the mesh's own arrays, kept
// on the mesh (GpuMesh.lods, coarser levels later), stored in a bundle's
// Mesh entry, and drawn when the renderer's LOD threshold lets it (a level
// is drawn while its error, projected, stays under the threshold in
// pixels: Godot's mesh_lod_threshold, 1.0 in a Rive project's run time; the
// tools draw level 0 unless `render --lod-threshold` says otherwise).
export class MeshLod {
    // The level's triangles, indices into the mesh's `verts`, grouped by
    // material slot as GpuMesh.indices is.
    indices: Array<u32> = [];
    // Its material runs: `first`/`count` are offsets into `indices` above
    // (the uploader adds where the level starts in the index buffer).
    ranges: Array<MaterialRange> = [];
    // The simplification's error, as a fraction of the mesh's bounding
    // radius (meshoptimizer's relative error): how far, at most, a surface
    // of this level lies from level 0's.
    error: f32 = 0;
    // Milestone 67b: `indices` were let go of with the mesh's other CPU
    // arrays (GpuMesh.releaseCpu; they are in the index buffer), and how
    // many there were, which the draws still need (lodIndexCount).
    released: bool = false;
    releasedCount: u32 = 0;
}

// Milestone 67b: how many indices level `l` has, released or not.
export function lodIndexCount(l: MeshLod): u32 {
    return l.released ? l.releasedCount : <u32>l.indices.length;
}

// Milestone 26: the level `lod` (0 level 0, k > 0 lods[k - 1]) of a mesh as
// the renderer draws it: its first index and index count in the index
// buffer, whole or of range k. The index buffer holds level 0's indices,
// then each level's in turn (gpu/mesh_cache.as packIndicesWithLods), so a
// level starts where the ones before it end. A level that does not exist,
// whose ranges do not match the mesh's, or that the uploaded index buffer
// does not hold (MeshGpuBuffers.lodLevels; a mesh not uploaded yet is
// planned as if it held them all) is drawn as level 0, so level 0's numbers
// are exactly the mesh's own and every frame without levels draws as
// before. Nothing is allocated.
export function lodUsable(g: GpuMesh, lod: i32): bool {
    if (lod <= 0) return false;
    const ls = g.lods;
    if (ls == null || lod > ls.length) return false;
    if (unchecked(ls[lod - 1]).ranges.length != g.ranges.length) return false;
    const b = g.gpu;
    return b == null || lod <= b.lodLevels;
}

function lodStart(g: GpuMesh, lod: i32): u32 {
    let o = <u32>g.indexLength();
    const ls = g.lods;
    if (ls != null) for (let k = 0; k < lod - 1; k++) o += lodIndexCount(unchecked(ls[k]));
    return o;
}

export function lodFirst(g: GpuMesh, lod: i32): u32 {
    return lodUsable(g, lod) ? lodStart(g, lod) : 0;
}

export function lodCount(g: GpuMesh, lod: i32): u32 {
    if (!lodUsable(g, lod)) return g.indexCount;
    const ls = g.lods;
    return ls != null ? lodIndexCount(unchecked(ls[lod - 1])) : g.indexCount;
}

export function lodRangeFirst(g: GpuMesh, lod: i32, k: i32): u32 {
    const ls = g.lods;
    if (ls == null || !lodUsable(g, lod)) return g.ranges[k].first;
    return lodStart(g, lod) + unchecked(ls[lod - 1]).ranges[k].first;
}

export function lodRangeCount(g: GpuMesh, lod: i32, k: i32): u32 {
    const ls = g.lods;
    if (ls == null || !lodUsable(g, lod)) return g.ranges[k].count;
    return unchecked(ls[lod - 1]).ranges[k].count;
}

// The triangles level `lod` of `g` draws.
export function lodTriangles(g: GpuMesh, lod: i32): u32 {
    return lodCount(g, lod) / 3;
}

// Works out g.lodCenter and g.lodRadius from its vertices the first time
// (a mesh's vertices do not change once built; one rebuilt is a new
// GpuMesh). Allocates nothing.
export function lodSphere(g: GpuMesh): void {
    if (g.lodRadius >= 0) return;
    const vs = g.verts;
    if (vs.length == 0) {
        g.lodCenter = Vec3(0, 0, 0);
        g.lodRadius = 0;
        return;
    }
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
    g.lodCenter = Vec3((lx + hx) * <f32>0.5, (ly + hy) * <f32>0.5, (lz + hz) * <f32>0.5);
    const dx = hx - lx;
    const dy = hy - ly;
    const dz = hz - lz;
    g.lodRadius = Mathf.sqrt(dx * dx + dy * dy + dz * dz) * <f32>0.5;
}

// The box of `verts`' positions (a point at the origin for none): what
// the scene's render cache places a mesh by (scene/render/cache.as
// SceneMesh.local).
function boxOfVerts(vs: Array<SurfaceVertex>): Bounds {
    if (vs.length == 0) return Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    let lo = vs[0].pos;
    let hi = lo;
    for (let i = 1; i < vs.length; i++) {
        const p = vs[i].pos;
        lo = lo.min(p);
        hi = hi.max(p);
    }
    return Bounds(lo, hi);
}

// Milestone 67b: the box of `g`'s vertices, from its vertices, or the box
// kept when they were released (GpuMesh.releaseCpu), the same numbers.
export function vertexBox(g: GpuMesh): Bounds {
    if (g.cpuReleased) return Bounds(g.boxMin, g.boxMax);
    return boxOfVerts(g.verts);
}

// Milestone 67b: a mesh's visible triangles as the listeners pick them
// (engine/src/scene/listen/pick.as MeshPick), worked out from its arrays
// before they are released (GpuMesh.releaseCpu with keepTriangles) so that
// picking needs nothing else of them: each triangle whose first corner is
// not F_HIDDEN, in index order, its first index into GpuMesh.indices
// (`corners`, which says its material range) and its three vertices
// (`tris`), and each vertex's position and UV set 0 (the renderer's
// bottom-left origin): the same numbers the arrays hold. 16 bytes a
// triangle and 20 a vertex, where the arrays it replaces hold 12 and 56
// and their packed copies as much again.
export class MeshTriangles {
    count: i32 = 0;
    // The mesh's index count they were made from.
    indexCount: i32 = 0;
    corners: Int32Array = new Int32Array(0);
    // Three vertex numbers a triangle.
    tris: Uint32Array = new Uint32Array(0);
    // Three numbers a vertex (x, y, z) and two (u, v).
    positions: Float32Array = new Float32Array(0);
    uvs: Float32Array = new Float32Array(0);

    // The bytes it holds.
    byteSize(): i64 {
        return <i64>(this.corners.length + this.tris.length + this.positions.length + this.uvs.length) * 4;
    }
}

export function visibleTriangles(g: GpuMesh): MeshTriangles {
    const t = new MeshTriangles();
    const verts = g.verts;
    const idx = g.indices;
    let n = 0;
    for (let i = 0; i + 2 < idx.length; i += 3) if ((verts[<i32>idx[i]].flags & F_HIDDEN) == 0) n++;
    const corners = new Int32Array(n);
    const tris = new Uint32Array(n * 3);
    let k = 0;
    for (let i = 0; i + 2 < idx.length; i += 3) {
        if ((verts[<i32>idx[i]].flags & F_HIDDEN) != 0) continue;
        corners[k] = i;
        tris[k * 3] = idx[i];
        tris[k * 3 + 1] = idx[i + 1];
        tris[k * 3 + 2] = idx[i + 2];
        k++;
    }
    const nv = verts.length;
    const pos = new Float32Array(nv * 3);
    const uvs = new Float32Array(nv * 2);
    for (let i = 0; i < nv; i++) {
        const v = verts[i];
        pos[i * 3] = v.pos.x;
        pos[i * 3 + 1] = v.pos.y;
        pos[i * 3 + 2] = v.pos.z;
        uvs[i * 2] = v.uv.x;
        uvs[i * 2 + 1] = v.uv.y;
    }
    t.count = n;
    t.indexCount = idx.length;
    t.corners = corners;
    t.tris = tris;
    t.positions = pos;
    t.uvs = uvs;
    return t;
}

// Milestone 67b: the bytes `g`'s CPU arrays hold (the vertices, indices
// and instances as their packed layouts size them, the labels, the packed
// upload bytes, the levels' indices): what releaseCpu lets go of.
export function meshCpuBytes(g: GpuMesh): i64 {
    let n: i64 = <i64>g.verts.length * <i64>SURFACE_VERTEX_SIZE + <i64>g.indices.length * 4;
    const uv1 = g.uv1;
    if (uv1 != null) n += <i64>uv1.length * 8;
    const lm = g.lightmapUv;
    if (lm != null) n += <i64>lm.length * 8;
    n += <i64>g.edges.length * <i64>LINE_INSTANCE_SIZE + <i64>g.points.length * <i64>POINT_INSTANCE_SIZE;
    // (an id and a position; an id, two vectors and a flag)
    n += <i64>(g.vertLabels.length + g.edgeLabels.length) * 16 + <i64>g.faces.length * 32;
    for (let i = 0; i < g.uploadBytes.length; i++) n += <i64>g.uploadBytes[i].byteLength;
    const ls = g.lods;
    if (ls != null) for (let i = 0; i < ls.length; i++) n += <i64>ls[i].indices.length * 4;
    return n;
}

// `(u32, Vec3)`: an element id and a local position (vertex / edge labels).
export class IdPos {
    id: u32;
    pos: Vec3;

    constructor(id: u32, pos: Vec3) {
        this.id = id;
        this.pos = pos;
    }
}

// `(u32, Vec3, Vec3, bool)`: face id, local center, local normal, selected.
export class FaceLabel {
    id: u32;
    center: Vec3;
    normal: Vec3;
    selected: bool;

    constructor(id: u32, center: Vec3, normal: Vec3, selected: bool) {
        this.id = id;
        this.center = center;
        this.normal = normal;
        this.selected = selected;
    }
}

// The device side of a `GpuMesh` (the optional buffers `tris`, `indices`,
// `edges`, `points`). The GPU side subclasses it.
export abstract class MeshGpuBuffers {
    // Milestone 26: how many of the mesh's levels of detail the index
    // buffer holds after level 0's (gpu/mesh_cache.as appends them); a
    // level past them (given after the upload) is not drawn until the mesh
    // is uploaded again.
    lodLevels: i32 = 0;
}

// Uploads a freshly built mesh (a buffer per non-empty byte array, null for
// an empty one) and stores the result in `mesh.gpu`.
export abstract class MeshUploader {
    abstract upload(mesh: GpuMesh): void;

    // Milestone 48: writes `mesh.verts` again into the vertex buffer an
    // earlier `upload` made for it (a mesh with GpuMesh.deforms: its blend
    // shapes moved), in place; false when this uploader cannot (no device,
    // or a mesh never uploaded), and the caller then uploads it anew.
    updateVertices(mesh: GpuMesh): bool {
        return false;
    }
}

// Milestone 48: one blend shape of a mesh (glTF's morph target, a
// Blender shape key relative to its basis): what it adds to each vertex of
// GpuMesh.verts at weight 1, three numbers a vertex. Named as the mesh's
// blend shapes are (ModelObject.blendShapes), in the same order.
export class MorphTarget {
    name: string;
    positions: Array<f32>;
    // Null: the normals do not move.
    normals: Array<f32>?;

    constructor(name: string, positions: Array<f32>, normals: Array<f32>? = null) {
        this.name = name;
        this.positions = positions;
        this.normals = normals;
    }
}

export class GpuMesh {
    // Milestone 48: the skin (docs/engine/ANIMATION.md, "Skeletons and
    // imported clips"; engine/src/scene/skeleton/model_skin.as):
    // for each vertex of `verts`, four palette slots, one byte each, little
    // endian (slot k in bits 8k to 8k + 7), and their four weights, which
    // sum to 1 (a slot of weight 0 is 0). Null for a mesh that is not
    // skinned; the renderer then draws `verts` as they are.
    skinJoints: Array<u32>? = null;
    skinWeights: Array<f32>? = null;
    // Milestone 48: its blend shapes (null: none).
    morphs: Array<MorphTarget>? = null;
    // Milestone 48: `verts` are written again after the upload (a node's
    // blended copy of a mesh with blend shapes, engine/src/scene/render/morph.as),
    // so the uploader makes its vertex buffer one that can be rewritten in
    // place (MeshUploader.updateVertices). False for every other mesh, whose
    // buffers are made as before.
    deforms: bool = false;
    // Device buffers, set by the MeshUploader (null when none ran).
    gpu: MeshGpuBuffers? = null;
    // CPU copies of what the buffers hold. `verts` / `indices` back `tris` /
    // `indices`; pack them with packSurfaceVertices / packU32s.
    verts: Array<SurfaceVertex> = [];
    // Milestone 14, part 2: UV set 1 of each vertex of `verts` (the
    // mesh's second UV layer, glTF's TEXCOORD_1), which the extended
    // pipelines read; null when the mesh has one layer (set 1 is then set
    // 0: gpu/mesh_cache.as `uv1Buffer`). Only Hedra asks for it.
    uv1: Array<Vec2>? = null;
    // Milestone 19: each vertex's place in its item's lightmap layer (0 to
    // 1 across the layer, v down its rows; RenderFrame.lightmap), set only
    // on the mesh a lightmapped item draws, which Hedra builds for that
    // item from its bake (engine/src/scene/render/lightmap.as); null on
    // every other mesh.
    lightmapUv: Array<Vec2>? = null;
    // Indices into `verts`, grouped by material slot.
    indices: Array<u32> = [];
    indexCount: u32 = 0;
    // Triangles grouped by material slot, ascending; `first`/`count` are
    // offsets into the index buffer.
    ranges: Array<MaterialRange> = [];
    // Milestone 26: the generated levels of detail, coarser later; null
    // (level 0 alone) on every mesh until an import or a bundle gives some,
    // so that a mesh built on every frame of a drag allocates nothing more.
    lods: Array<MeshLod>? = null;
    // The sphere the levels' errors are relative to (the centre of the
    // vertices' box, half its diagonal), worked out on first use
    // (lodSphere); a negative radius: not yet.
    lodCenter: Vec3 = Vec3(0, 0, 0);
    lodRadius: f32 = -1;
    edges: Array<LineInstance> = [];
    edgeCount: u32 = 0;
    points: Array<PointInstance> = [];
    pointCount: u32 = 0;
    // (id, local position) for vertex labels.
    vertLabels: Array<IdPos> = [];
    // (id, local midpoint) for edge labels.
    edgeLabels: Array<IdPos> = [];
    // (id, local center, local normal, selected) for face labels/normals.
    faces: Array<FaceLabel> = [];
    // Byte buffers the uploader packed this mesh's arrays into; the next
    // build of the same object takes them over, so the uploader can pack a
    // same-sized mesh into the same memory (gpu/mesh_cache.as).
    uploadBytes: Array<ArrayBuffer> = [];
    // Milestone 48: DataViews over some of `uploadBytes`, kept for a mesh
    // whose vertices are rewritten in place (gpu/mesh_cache.as
    // updateVertices), so a rewrite allocates none.
    uploadViews: Array<DataView?> = [];
    // Milestone 67b (docs/engine/RESOURCES.md, "CPU copies"): the CPU
    // arrays were let go of once the buffers existed (releaseCpu): `verts`,
    // `indices`, `uv1`, `lightmapUv` (empty, not null: a mesh that had a
    // second UV set or lightmap coordinates still says so), the edges,
    // points and labels, the upload bytes and the levels' indices; kept are
    // the counts (vertexCount, indexLength, indexCount, edgeCount,
    // pointCount), the ranges, the levels' ranges and counts, the box
    // (vertexBox), the levels' sphere and, when asked, the visible
    // triangles (`triangles`).
    cpuReleased: bool = false;
    // Kept on the CPU after its upload (../scene/resource/cpu_copy.as
    // pinMesh): a flag, so a pin keeps nothing alive.
    cpuPinned: bool = false;
    private keptVerts: i32 = 0;
    private keptIndices: i32 = 0;
    // The box releaseCpu kept (vertexBox).
    boxMin: Vec3 = Vec3(0, 0, 0);
    boxMax: Vec3 = Vec3(0, 0, 0);
    // The visible triangles the listeners pick (visibleTriangles), kept by
    // releaseCpu when asked; null otherwise (the picker reads the arrays).
    triangles: MeshTriangles? = null;
    // Milestone 67b: lightmapDigest's answer (render/lightmap/data.as) for
    // the vertices of revision `lightmapDigestRevision` (-1: none yet), so
    // that a bake still finds a mesh whose arrays were released.
    lightmapDigestKept: string = "";
    lightmapDigestRevision: i64 = -1;
    // Local-space BVH over the visible triangles, built on first use.
    private bvhCache: TriBvh? = null;
    // BVHs without some material slots, keyed by the sorted slot list.
    private bvhSkipCache: Map<string, TriBvh> = new Map<string, TriBvh>();

    // A mesh from triangle lists (glTF primitives, Hedra's primitive
    // meshes): no edges, points or labels. The arrays are taken, not copied;
    // `ranges` must cover `indices` as `build` makes them (ascending slots,
    // `first`/`count` offsets into the index list). Nothing is uploaded: the
    // caller hands the mesh to its `MeshUploader`.
    static fromArrays(verts: Array<SurfaceVertex>, indices: Array<u32>, ranges: Array<MaterialRange>): GpuMesh {
        const g = new GpuMesh();
        g.verts = verts;
        g.indices = indices;
        g.indexCount = <u32>indices.length;
        g.ranges = ranges;
        return g;
    }

    // Milestone 48: moves whenever `verts` were rewritten in place after a
    // BVH may have been built (`invalidateBvh`), so a cache of what was
    // built from them (engine/src/authoring/render/pick.as) knows it is stale.
    vertsRevision: u32 = 0;

    // Milestone 67b: how many vertices and indices the mesh has, its arrays
    // released or not (releaseCpu).
    vertexCount(): i32 {
        return this.cpuReleased ? this.keptVerts : this.verts.length;
    }

    indexLength(): i32 {
        return this.cpuReleased ? this.keptIndices : this.indices.length;
    }

    // Milestone 67b: lets go of the CPU arrays (see `cpuReleased`) once the
    // device buffers hold them, after working out what is read later: the
    // levels' sphere (lodSphere), the box (vertexBox), the counts, and the
    // visible triangles when `keepTriangles` (a scene that picks). The
    // bytes it let go of (meshCpuBytes); 0 when released already. A mesh
    // whose vertices are rewritten (`deforms`, a skin, blend shapes) must
    // not be released: the caller (cpu_copy.as) leaves those alone.
    releaseCpu(keepTriangles: bool = false): i64 {
        if (this.cpuReleased) return 0;
        lodSphere(this);
        const box = boxOfVerts(this.verts);
        this.boxMin = box.min;
        this.boxMax = box.max;
        if (keepTriangles && this.triangles == null) this.triangles = visibleTriangles(this);
        const bytes = meshCpuBytes(this);
        this.keptVerts = this.verts.length;
        this.keptIndices = this.indices.length;
        this.verts = [];
        this.indices = [];
        if (this.uv1 != null) this.uv1 = [];
        if (this.lightmapUv != null) this.lightmapUv = [];
        this.edges = [];
        this.points = [];
        this.vertLabels = [];
        this.edgeLabels = [];
        this.faces = [];
        this.uploadBytes = [];
        this.uploadViews = [];
        const ls = this.lods;
        if (ls != null) {
            for (let i = 0; i < ls.length; i++) {
                const l = ls[i];
                if (l.released) continue;
                l.releasedCount = <u32>l.indices.length;
                l.indices = [];
                l.released = true;
            }
        }
        // (built from the arrays: a BVH asked for after this is built from
        // none, an empty tree: only the tools' labels ask)
        this.bvhCache = null;
        if (this.bvhSkipCache.size > 0) this.bvhSkipCache.clear();
        this.cpuReleased = true;
        return bytes;
    }

    // Milestone 48: `verts` were rewritten in place (a node's blended or
    // CPU-skinned copy, engine/src/scene/render/morph.as DeformedMesh): the BVHs
    // built from the old positions are dropped, to be built again on next
    // use. Allocates nothing.
    invalidateBvh(): void {
        this.bvhCache = null;
        if (this.bvhSkipCache.size > 0) this.bvhSkipCache.clear();
        this.vertsRevision++;
    }

    // The label-occlusion BVH (triangles of `verts`/`indices`, hidden faces
    // skipped), built lazily: only renders with labels need it.
    bvh(): TriBvh {
        let b = this.bvhCache;
        if (b == null) {
            b = TriBvh.fromSurface(this.verts, this.indices);
            this.bvhCache = b;
        }
        return b;
    }

    // The label-occlusion BVH without the triangles of the material slots in
    // `skipSlots`. In material mode a range whose material
    // `cutsOut` (material.as) discards every fragment, so those
    // ranges hide no label.
    bvhSkipping(skipSlots: Array<u16>): TriBvh {
        if (skipSlots.length == 0) return this.bvh();
        const sorted = skipSlots.slice(0);
        stableSort<u16>(sorted, (a: u16, b: u16): i32 => (a < b ? -1 : a > b ? 1 : 0));
        const parts: Array<string> = [];
        for (let i = 0; i < sorted.length; i++) parts.push(sorted[i].toString());
        const key = parts.join(",");
        if (this.bvhSkipCache.has(key)) return this.bvhSkipCache.get(key);
        const pos: Array<f32> = [];
        for (let i = 0; i < this.ranges.length; i++) {
            const r = this.ranges[i];
            if (sorted.includes(r.slot)) continue;
            appendTriangles(pos, this.verts, this.indices, <i32>r.first, <i32>(r.first + r.count), F_HIDDEN);
        }
        const b = TriBvh.fromTriangles(pos);
        this.bvhSkipCache.set(key, b);
        return b;
    }
}
