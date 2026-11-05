// The device side of mesh data: the buffer uploads of a freshly built
// mesh. `GpuMesh` is engine/src/render/mesh.as (a program builds and caches
// its meshes: Hedra's meshdata.as); this uploader turns a built
// `GpuMesh`'s CPU arrays into host buffers.
//
// Milestone 67b (docs/engine/RESOURCES.md, "CPU copies" and "Lifetimes"):
// in a run time that releases CPU copies (../../scene/resource/cpu_copy.as
// CPU_COPY_RELEASE), a mesh whose vertices are never written again packs
// its streams into pooled buffers where their sizes allow (the device
// takes a buffer exactly as long as its contents: ../../base/scratch.as
// hands out powers of two from 4 KiB) and keeps none of them once its
// buffers exist (`uploadBytes` empty: nothing re-packs it); everywhere
// else (the tools, a deforming mesh, a project keeping its copies) it
// packs and keeps them as before. The bytes uploaded are the same either
// way (packMeshStreams). A resource's meshes are let go of through
// `meshBuffersRelease`, which the run time's GPU ledger calls a frame
// after the resource was freed.

import { GPUBuffer } from "rive/gpu";
import { BufferUsage } from "rive/gpu_enums";
import { GpuMesh, MeshGpuBuffers, MeshUploader } from "../mesh";
import { emitMeshForgotten, emitMeshUploaded, uploadListenerCount } from "../upload_events";
import { GpuRelease, LEDGER_BUFFER } from "./ledger";
import { ScratchPool, SCRATCH_MIN_SHIFT, scratch } from "../../base/scratch";
import { CPU_COPY_RELEASE, cpuCopyPolicy, noteCpuMiss } from "../../scene/resource/cpu_copy";
import {
    F_HIDDEN, LINE_INSTANCE_SIZE, LM_UV_STRIDE, POINT_INSTANCE_SIZE, SURFACE_VERTEX_SIZE, SurfaceVertex, UV1_STRIDE, packLineInstances, packPointInstances, packSkinVertices,
    packSurfaceVertices, packU32s, writeLineInstances, writeSurfaceVertices,
} from "./layouts";

// The host buffers of a `GpuMesh`; a buffer is null when its data is empty.
export class GpuMeshBuffers extends MeshGpuBuffers {
    tris: GPUBuffer? = null;
    // Indices into `tris`, grouped by material slot.
    indices: GPUBuffer? = null;
    edges: GPUBuffer? = null;
    points: GPUBuffer? = null;
    // Whether a triangle carries F_HIDDEN (a face hidden in a .modeler
    // model): the shadow pass draws such a mesh through `fs_shadow`, which
    // discards those faces, as the main pass does.
    hiddenFaces: bool = false;
    // Milestone 14, part 2: UV set 1 (UV1_STRIDE bytes a vertex), uploaded
    // the first time an extended material draws the mesh (`uv1Buffer`).
    uv1: GPUBuffer? = null;
    // Milestone 19: the lightmap coordinates (LM_UV_STRIDE bytes a vertex)
    // of a lightmapped mesh (GpuMesh.lightmapUv), uploaded with it; null
    // for every other mesh.
    lightmapUv: GPUBuffer? = null;
    // Milestone 48: the palette slots and weights (layouts.as SKIN_STRIDE
    // bytes a vertex) of a skinned mesh (`hasSkin`), uploaded with it; null
    // for every other mesh.
    skin: GPUBuffer? = null;
}

// Milestone 48: whether `mesh` carries a skin the skinned pipelines can
// draw: a palette slot word and four weights for every vertex.
export function hasSkin(mesh: GpuMesh): bool {
    const j = mesh.skinJoints;
    const w = mesh.skinWeights;
    const n = mesh.verts.length;
    return j != null && w != null && n > 0 && j.length == n && w.length == n * 4;
}

// The skin vertex buffer of an uploaded mesh (null when it was never
// uploaded or has no skin).
export function skinBuffer(mesh: GpuMesh): GPUBuffer? {
    const b = buffersOf(mesh);
    return b != null ? b.skin : null;
}

// UV set 1 of `mesh` as the extended pipelines' vertex buffer reads it:
// GpuMesh.uv1, else a copy of set 0 (a mesh with one UV layer draws set 1 as
// set 0). Length UV1_STRIDE bytes a vertex of `mesh.verts`.
export function uv1Bytes(mesh: GpuMesh): ArrayBuffer {
    const n = mesh.verts.length;
    const out = new ArrayBuffer(n * <i32>UV1_STRIDE);
    const dv = new DataView(out, 0, out.byteLength);
    const uv1 = mesh.uv1;
    for (let i = 0; i < n; i++) {
        const uv = uv1 != null && i < uv1.length ? uv1[i] : mesh.verts[i].uv;
        dv.setFloat32(i * 8, uv.x, true);
        dv.setFloat32(i * 8 + 4, uv.y, true);
    }
    return out;
}

// The UV set 1 buffer of an uploaded mesh, made on first use and kept with
// its other buffers (released with them: FrameRenderer.retire); null when
// the mesh was never uploaded or has no vertex.
export function uv1Buffer(mesh: GpuMesh): GPUBuffer? {
    const b = buffersOf(mesh);
    if (b == null) return null;
    const have = b.uv1;
    if (have != null) return have;
    if (mesh.cpuReleased) noteCpuMiss("mesh: UV set 1 built after its release");
    const made = uploadWith(uv1Bytes(mesh), BufferUsage.vertex);
    b.uv1 = made;
    return made;
}

// The lightmap coordinates of `mesh` as the lightmap pipelines' vertex
// buffer reads them (LM_UV_STRIDE bytes a vertex of `mesh.verts`): its
// lightmapUv, (0, 0) for a vertex past it; empty for a mesh without them.
export function lightmapUvBytes(mesh: GpuMesh): ArrayBuffer {
    const uv = mesh.lightmapUv;
    if (uv == null) return new ArrayBuffer(0);
    const n = mesh.verts.length;
    const out = new ArrayBuffer(n * <i32>LM_UV_STRIDE);
    const dv = new DataView(out, 0, out.byteLength);
    for (let i = 0; i < n && i < uv.length; i++) {
        dv.setFloat32(i * 8, uv[i].x, true);
        dv.setFloat32(i * 8 + 4, uv[i].y, true);
    }
    return out;
}

// The lightmap coordinate buffer of an uploaded mesh (uploaded with it by
// GpuMeshUploader; made here for a mesh whose lightmapUv was set after),
// kept with its other buffers and released with them (FrameRenderer
// .retire); null when the mesh was never uploaded or has none.
export function lightmapUvBuffer(mesh: GpuMesh): GPUBuffer? {
    const b = buffersOf(mesh);
    if (b == null) return null;
    const have = b.lightmapUv;
    if (have != null) return have;
    if (mesh.lightmapUv == null) return null;
    if (mesh.cpuReleased) noteCpuMiss("mesh: lightmap UVs built after their release");
    const made = uploadWith(lightmapUvBytes(mesh), BufferUsage.vertex);
    b.lightmapUv = made;
    return made;
}

// A buffer for non-empty contents, null for empty ones.
export function uploadWith(bytes: ArrayBuffer, usage: BufferUsage): GPUBuffer? {
    if (bytes.byteLength == 0) {
        return null;
    }
    return new GPUBuffer(usage, <u32>bytes.byteLength, bytes, true);
}

export class GpuMeshUploader extends MeshUploader {
    // The bytes are packed into `mesh.uploadBytes` (tris, indices, edges,
    // points), which a rebuild of the same object hands on: a mesh
    // re-uploaded every frame at the same size (a skinned mesh in
    // `render --anim`) packs into the same memory each time.
    upload(mesh: GpuMesh): void {
        // (milestone 67b: see the header; a released mesh is never uploaded
        // again, SceneRenderCache.ready and lightmapMesh keep its buffers)
        if (mesh.cpuReleased) noteCpuMiss("mesh: uploaded again after its release");
        const pooled = cpuCopyPolicy() == CPU_COPY_RELEASE && !mesh.deforms;
        const st = packMeshStreams(mesh, pooled);
        const tris = st.tris;
        const indices = st.indices;
        const edges = st.edges;
        const points = st.points;
        if (!pooled) mesh.uploadBytes = [tris, indices, edges, points];
        const b = new GpuMeshBuffers();
        // Milestone 48: a mesh whose vertices are rewritten in place (a
        // node's blended copy: GpuMesh.deforms) gets a buffer that can be;
        // every other mesh's is made as before.
        b.tris = mesh.deforms ? mutableWith(tris, BufferUsage.vertex) : uploadWith(tris, BufferUsage.vertex);
        b.indices = uploadWith(indices, BufferUsage.index);
        b.edges = mesh.deforms ? mutableWith(edges, BufferUsage.vertex) : uploadWith(edges, BufferUsage.vertex);
        b.points = uploadWith(points, BufferUsage.vertex);
        b.hiddenFaces = anyHidden(mesh.verts);
        const lods = mesh.lods;
        b.lodLevels = lods != null ? lods.length : 0;
        // Milestone 19: a lightmapped mesh's coordinates go up with it (no
        // other mesh has any, so nothing else changes).
        if (mesh.lightmapUv != null) b.lightmapUv = uploadWith(lightmapUvBytes(mesh), BufferUsage.vertex);
        // Milestone 48: a skinned mesh's slots and weights go up with it (no
        // other mesh has any).
        if (hasSkin(mesh)) {
            const j = mesh.skinJoints;
            const w = mesh.skinWeights;
            if (j != null && w != null) b.skin = uploadWith(packSkinVertices(j, w, mesh.verts.length), BufferUsage.vertex);
        }
        mesh.gpu = b;
        if (pooled) {
            st.giveBack();
            if (mesh.uploadBytes.length > 0) mesh.uploadBytes = [];
        }
        // (milestone 67b: the run time's listeners, ../upload_events.as)
        if (uploadListenerCount() > 0) emitMeshUploaded(mesh, meshBufferBytes(b));
    }

    // Milestone 48: `mesh.verts` (and its wire edges, which follow them)
    // packed into the bytes its upload kept and written into its buffers
    // (made rewritable: GpuMesh.deforms), allocating nothing; false when it
    // has no such buffers (never uploaded, not deforming, or counts that
    // changed).
    updateVertices(mesh: GpuMesh): bool {
        const b = buffersOf(mesh);
        if (b == null || !mesh.deforms) return false;
        const tris = b.tris;
        if (tris == null || tris.size != <u32>mesh.verts.length * SURFACE_VERTEX_SIZE) return false;
        const edges = b.edges;
        const edgeBytes = <u32>mesh.edges.length * LINE_INSTANCE_SIZE;
        if ((edges == null) != (edgeBytes == 0) || (edges != null && edges.size != edgeBytes)) return false;
        const kept = mesh.uploadBytes;
        if (kept.length < 3) return false;
        // (the bytes the upload packed, written again through views kept on
        // the mesh: a rewrite allocates nothing)
        const bytes = kept[0];
        if (<u32>bytes.byteLength != tris.size) return false;
        if (edges != null && <u32>kept[2].byteLength != edges.size) return false;
        writeSurfaceVertices(mesh.verts, keptView(mesh, 0, bytes));
        tris.update(0, bytes);
        if (edges != null) {
            const eb = kept[2];
            writeLineInstances(mesh.edges, keptView(mesh, 1, eb));
            edges.update(0, eb);
        }
        return true;
    }
}

// A buffer for non-empty contents that can be written again
// (GPUBuffer.update), null for empty ones.
function mutableWith(bytes: ArrayBuffer, usage: BufferUsage): GPUBuffer? {
    if (bytes.byteLength == 0) return null;
    return new GPUBuffer(usage, <u32>bytes.byteLength, bytes, false);
}

// Milestone 26: a mesh's index buffer with its levels of detail (GpuMesh
// .lods) after level 0's indices, each level where the one before ends
// (mesh.as lodFirst finds a level there). A mesh without levels packs as
// before (packU32s), byte for byte.
export function packIndicesWithLods(mesh: GpuMesh, reuse: ArrayBuffer?): ArrayBuffer {
    const lods = mesh.lods;
    let count = mesh.indices.length;
    if (lods != null) for (let i = 0; i < lods.length; i++) count += lods[i].indices.length;
    const buf = reuse != null && reuse.byteLength == count * 4 ? reuse : new ArrayBuffer(count * 4);
    const dv = new DataView(buf, 0, buf.byteLength);
    let o = 0;
    const base = mesh.indices;
    for (let i = 0; i < base.length; i++) dv.setUint32((o++) << 2, base[i], true);
    if (lods != null) {
        for (let k = 0; k < lods.length; k++) {
            const ix = lods[k].indices;
            for (let i = 0; i < ix.length; i++) dv.setUint32((o++) << 2, ix[i], true);
        }
    }
    return buf;
}

function anyHidden(verts: Array<SurfaceVertex>): bool {
    for (let i = 0; i < verts.length; i++) {
        if ((verts[i].flags & F_HIDDEN) != 0) return true;
    }
    return false;
}

// Milestone 48: view `i` of `mesh`'s kept views (GpuMesh.uploadViews) over
// `buf`, made once (again only when the bytes were replaced).
function keptView(mesh: GpuMesh, i: i32, buf: ArrayBuffer): DataView {
    const views = mesh.uploadViews;
    while (views.length <= i) views.push(null);
    const v = views[i];
    if (v != null && v.buffer === buf && v.byteLength == buf.byteLength) return v;
    const made = new DataView(buf, 0, buf.byteLength);
    views[i] = made;
    return made;
}

function keptAt(kept: Array<ArrayBuffer>, i: i32): ArrayBuffer? {
    return i < kept.length ? kept[i] : null;
}

// Milestone 67b: the four streams a mesh's upload packs (its vertices, its
// indices with its levels', its wire edges, its points), in their device
// layouts.
export class MeshStreams {
    tris: ArrayBuffer;
    indices: ArrayBuffer;
    edges: ArrayBuffer;
    points: ArrayBuffer;
    pool: ScratchPool;
    // The pooled ones, to give back once the buffers are made.
    pooled: Array<Uint8Array> = [];

    constructor(tris: ArrayBuffer, indices: ArrayBuffer, edges: ArrayBuffer, points: ArrayBuffer, pool: ScratchPool) {
        this.tris = tris;
        this.indices = indices;
        this.edges = edges;
        this.points = points;
        this.pool = pool;
    }

    // Gives the pooled streams back (their bytes are the device's now).
    giveBack(): void {
        for (let i = 0; i < this.pooled.length; i++) this.pool.give(this.pooled[i]);
        this.pooled.length = 0;
    }
}

// A pooled buffer of exactly `bytes` bytes, recorded in `out` (a size
// the pool's classes do not hold exactly: null, the packer then makes one).
function pooledExactly(bytes: i32, pool: ScratchPool, out: Array<Uint8Array>): ArrayBuffer? {
    if (bytes < (1 << SCRATCH_MIN_SHIFT) || (bytes & (bytes - 1)) != 0) return null;
    const v = pool.take(bytes);
    if (v.byteOffset != 0 || v.buffer.byteLength != bytes) {
        pool.give(v);
        return null;
    }
    out.push(v);
    return v.buffer;
}

// Milestone 67b: `mesh`'s streams as its upload packs them: into the
// buffers its last upload kept (`uploadBytes`, when their sizes still fit:
// a mesh re-uploaded at the same size packs into the same memory), or,
// `pooled`, into `pool`'s buffers where a stream's size is one exactly
// (MeshStreams.giveBack returns them). The same bytes either way.
export function packMeshStreams(mesh: GpuMesh, pooled: bool, pool: ScratchPool = scratch()): MeshStreams {
    const kept = mesh.uploadBytes;
    const out = new Array<Uint8Array>();
    let ixCount = mesh.indices.length;
    const lods = mesh.lods;
    if (lods != null) for (let i = 0; i < lods.length; i++) ixCount += lods[i].indices.length;
    const r0 = pooled ? pooledExactly(mesh.verts.length * <i32>SURFACE_VERTEX_SIZE, pool, out) : keptAt(kept, 0);
    const r1 = pooled ? pooledExactly(ixCount * 4, pool, out) : keptAt(kept, 1);
    const r2 = pooled ? pooledExactly(mesh.edges.length * <i32>LINE_INSTANCE_SIZE, pool, out) : keptAt(kept, 2);
    const r3 = pooled ? pooledExactly(mesh.points.length * <i32>POINT_INSTANCE_SIZE, pool, out) : keptAt(kept, 3);
    const tris = packSurfaceVertices(mesh.verts, r0);
    const indices = lods != null ? packIndicesWithLods(mesh, r1) : packU32s(mesh.indices, r1);
    const edges = packLineInstances(mesh.edges, r2);
    const points = packPointInstances(mesh.points, r3);
    const st = new MeshStreams(tris, indices, edges, points, pool);
    st.pooled = out;
    return st;
}

// Milestone 67b: what releases `mesh`'s device buffers (see the header):
// each released and nulled as FrameRenderer.retire does, `mesh.gpu` then
// null (a later draw would upload it again), and the upload listeners told
// (meshForgotten). `bytes` is what its upload charged (the ledger refunds
// that figure; -1: its buffers' sizes now). A mesh whose buffers are not
// GpuMeshBuffers (a test's) only loses them.
export function meshBuffersRelease(mesh: GpuMesh, bytes: i64 = -1): MeshBuffersRelease {
    let n = bytes;
    if (n < 0) {
        const b = buffersOf(mesh);
        n = b != null && b instanceof GpuMeshBuffers ? meshBufferBytes(b) : 0;
    }
    return new MeshBuffersRelease(mesh, n);
}

export class MeshBuffersRelease extends GpuRelease {
    mesh: GpuMesh;
    // The bytes charged (a re-upload moves it: ledger.as recharge).
    n: i64;
    done: bool = false;

    constructor(mesh: GpuMesh, n: i64) {
        super();
        this.mesh = mesh;
        this.n = n;
    }

    release(): void {
        if (this.done) return;
        this.done = true;
        const g = this.mesh.gpu;
        if (g != null && g instanceof GpuMeshBuffers) {
            const b = g as GpuMeshBuffers;
            const bufs: Array<GPUBuffer?> = [b.tris, b.indices, b.edges, b.points, b.uv1, b.lightmapUv, b.skin];
            for (let i = 0; i < bufs.length; i++) {
                const x = bufs[i];
                if (x != null) x.release();
            }
            b.skin = null;
            b.uv1 = null;
            b.lightmapUv = null;
            b.tris = null;
            b.indices = null;
            b.edges = null;
            b.points = null;
        }
        this.mesh.gpu = null;
        if (uploadListenerCount() > 0) emitMeshForgotten(this.mesh, this.n);
    }

    bytes(): i64 {
        return this.n;
    }

    kind(): i32 {
        return LEDGER_BUFFER;
    }
}

// Milestone 67b: the bytes `b`'s buffers hold on the device (what the GPU
// ledger charges a mesh: ledger.as).
export function meshBufferBytes(b: GpuMeshBuffers): i64 {
    const bufs: Array<GPUBuffer?> = [b.tris, b.indices, b.edges, b.points, b.uv1, b.lightmapUv, b.skin];
    let total: i64 = 0;
    for (let i = 0; i < bufs.length; i++) {
        const x = bufs[i];
        if (x != null) total += <i64>x.size;
    }
    return total;
}

// The device buffers of a cached mesh (null when it was never uploaded).
export function buffersOf(mesh: GpuMesh): GpuMeshBuffers? {
    const g = mesh.gpu;
    if (g == null) return null;
    return g as GpuMeshBuffers;
}
