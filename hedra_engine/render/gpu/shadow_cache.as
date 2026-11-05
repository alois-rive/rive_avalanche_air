// Milestone 67 (docs/engine/PERFORMANCE.md, "Shadows kept"): shadow maps
// kept from one frame to the next. Godot keeps an omni or spot light's map
// in its shadow atlas and draws it again only when the light or a geometry
// instance paired with it changed (RendererSceneCull's light instance
// `shadow_dirty`); Hedra does the same for every tile of its atlas
// (shadow.as: a cascade of a directional light, an omni light's cube face, a
// spot light's cone), the cascades too, which Godot draws every frame: a
// cascade's matrix follows the camera, so it is drawn again whenever the
// camera moves (it is snapped to whole texels and its radius to sixteenths,
// so a camera at rest keeps it).
//
// What a tile holds is the depth of the casters culling gave it (cull.as
// CullResult.casters, a bit per tile), each drawn with the tile's
// view-projection: its depth is a function of that matrix and of each
// caster's world matrix, mesh (its buffers, its level of detail and its
// material ranges), instances and, for a caster drawn through `fs_shadow`
// (an alpha-masked range, a mesh with hidden faces), its materials' values
// and textures. A tile is kept when every one of these is what it was the
// last time this cache drew the tile, no other view drew into the tile
// since (FrameRenderer.atlasOwner) and the atlas and the shadow pipelines
// are the same objects; it is then not drawn at all, and its draws count as
// made (FrameRenderer.drawCountError holds). The depth test keeps the
// nearest depth whatever the order, so a tile drawn again from the same
// casters is the same texels, to the bit: the pictures are the ones a full
// pass draws (every golden is unchanged).
//
// Compared exactly, never hashed: each item's record holds the world
// matrix's bits, its mesh, buffers, level of detail, material keys, next
// pass, instances (their buffer, count and version) and, for a masked
// caster, the renderer's material epoch (any material group or value
// written again since: FrameRenderer.materialEpoch). A caster whose depth
// can change with nothing here changing is volatile and draws its tiles
// every frame: a skinned item (its palette), a mesh rewritten in place
// (GpuMesh.deforms: blend shapes, the CPU skin), an item emerging from its
// fog (its cut moves), a ShaderMaterial range (its vertex stage or TIME),
// and a masked range whose material shows a live texture (an artboard's
// alpha). Items are recorded by their index in the frame; the cache belongs
// to one RenderFrame (a new plan is a new frame: every tile is drawn).
//
// A pass that keeps some tiles loads the atlas and clears each tile it
// draws with `shadow_clear.wgsl`'s triangle (depth 1.0, the clear value),
// scissored to the tile; a pass that draws every tile clears the whole
// atlas as before, and one that keeps every tile is not begun. A host that
// refuses the clear pipeline draws every tile whenever one must be.
//
// Allocates nothing once its arrays have grown to the frame's items.

import { GPUDepthStencilDesc, GPUPipeline, GPUPipelineDesc, GPUTextureView } from "rive/gpu";
import { CullMode, FaceWinding, IndexFormat, PrimitiveTopology } from "rive/gpu_enums";
import { Context } from "rive/host";
import { Mat4 } from "../../base/vecmath";
import { DrawItem, RenderFrame } from "../frame";
import { InstanceGpuBuffer } from "../instances";
import { GpuMesh, MeshGpuBuffers } from "../mesh";
import { SHADOW_ATLAS_FORMAT, SHADOW_TILES, depthState } from "./layouts";
import { ShadowPipelines, shaderAsset } from "./pipelines";

// The clear's module (engine/src/shaders/render/shadow_clear.wgsl) and entry.
export const SHADOW_CLEAR_SHADER = "shaders/render/shadow_clear";
export const SHADOW_CLEAR_ENTRY = "vs_shadow_clear";

// How a caster's depth may change (see the header).
export const CASTER_PLAIN: u8 = 0;
// Drawn through `fs_shadow`: its materials' values and textures count.
export const CASTER_MASKED: u8 = 1;
// Drawn again every frame.
export const CASTER_VOLATILE: u8 = 2;

// The bits of tiles 0 to n - 1.
export function tileBits(n: i32): u32 {
    if (n <= 0) return 0;
    return n >= 32 ? 0xffffffff : ((<u32>1 << <u32>n) - 1);
}

// The clear's pipeline: the triangle at depth 1 into the atlas, compared
// `always`, written, without bias, culling, bindings or a fragment stage.
// Null when the project lacks the module or the host refuses it.
export function shadowClearPipeline(ctx: Context): GPUPipeline? {
    const mod = ctx.shader(shaderAsset(SHADOW_CLEAR_SHADER));
    if (mod == null) return null;
    const d = new GPUPipelineDesc();
    d.vertexModule = mod;
    d.vertexEntryPoint = SHADOW_CLEAR_ENTRY;
    d.fragmentModule = null;
    d.colorTargets = [];
    d.vertexBuffers = [];
    d.bindGroupLayouts = [];
    d.topology = PrimitiveTopology.triangleList;
    d.indexFormat = IndexFormat.uint32;
    d.cullMode = CullMode.none;
    d.winding = FaceWinding.counterClockwise;
    const ds = depthState(false, true, 0);
    const dd = new GPUDepthStencilDesc();
    dd.format = SHADOW_ATLAS_FORMAT;
    dd.compare = ds.compare;
    dd.write = ds.write;
    dd.depthBias = 0;
    dd.depthBiasSlopeScale = 0.0;
    dd.depthBiasClamp = 0.0;
    d.depthStencil = dd;
    d.sampleCount = 1;
    const p = new GPUPipeline(d);
    if (p.handle == 0) return null;
    return p;
}

// What one RenderFrame's shadow passes last drew into each tile, and what
// each of its items was when they did (see the header).
export class ShadowTileCache {
    // The frame the records are of, and when it was last drawn (the
    // renderer's pass serial: the least recently used cache is taken for a
    // new frame).
    frame: RenderFrame? = null;
    used: i64 = 0;
    // What the last pass drew with.
    atlas: GPUTextureView? = null;
    pipelines: ShadowPipelines? = null;
    materialMode: bool = false;
    // By tile index: whether the tile holds what its record says, the bits
    // of the view-projection it was drawn with, and its draws then (made,
    // and not drawable).
    private valid: StaticArray<bool> = new StaticArray<bool>(SHADOW_TILES);
    private vp: StaticArray<u32> = new StaticArray<u32>(SHADOW_TILES * 16);
    made: StaticArray<i32> = new StaticArray<i32>(SHADOW_TILES);
    missed: StaticArray<i32> = new StaticArray<i32>(SHADOW_TILES);
    // By item index (the first `count` recorded): its tiles, its kind and
    // what its depth was drawn from.
    count: i32 = 0;
    private casters: Array<u32> = [];
    private kinds: Array<u8> = [];
    private world: Array<u32> = [];
    private meshes: Array<GpuMesh?> = [];
    private buffers: Array<MeshGpuBuffers?> = [];
    private lods: Array<i32> = [];
    private materials: Array<Array<i64>?> = [];
    private nextPass: Array<i32> = [];
    private instGpu: Array<InstanceGpuBuffer?> = [];
    private instCount: Array<u32> = [];
    private instVersion: Array<u32> = [];
    private epochs: Array<i32> = [];

    // Forgets everything: the cache now belongs to `f`.
    reset(f: RenderFrame): void {
        this.frame = f;
        this.atlas = null;
        this.pipelines = null;
        this.count = 0;
        for (let t = 0; t < SHADOW_TILES; t++) unchecked(this.valid[t] = false);
    }

    // Before a pass: whether everything recorded is void (another atlas,
    // other pipelines, another shading), which then becomes current; and
    // the item arrays grown to `n`.
    begin(atlas: GPUTextureView, sp: ShadowPipelines, materialMode: bool, n: i32): bool {
        const void_ = this.atlas !== atlas || this.pipelines !== sp || this.materialMode != materialMode;
        this.atlas = atlas;
        this.pipelines = sp;
        this.materialMode = materialMode;
        while (this.casters.length < n) {
            this.casters.push(0);
            this.kinds.push(CASTER_PLAIN);
            for (let k = 0; k < 16; k++) this.world.push(0);
            this.meshes.push(null);
            this.buffers.push(null);
            this.lods.push(0);
            this.materials.push(null);
            this.nextPass.push(-1);
            this.instGpu.push(null);
            this.instCount.push(0);
            this.instVersion.push(0);
            this.epochs.push(-1);
        }
        if (void_) {
            for (let t = 0; t < SHADOW_TILES; t++) unchecked(this.valid[t] = false);
        }
        return void_;
    }

    // Whether tile `t` holds what its record says and was drawn with
    // `viewProj` (bit for bit).
    tileKept(t: i32, viewProj: Mat4): bool {
        if (!unchecked(this.valid[t])) return false;
        const o = t * 16;
        return sameMat4(this.vp, o, viewProj);
    }

    // Tile `t` drawn with `viewProj`: `made` and `missed` its draws.
    drew(t: i32, viewProj: Mat4, made: i32, missed: i32): void {
        unchecked(this.valid[t] = true);
        writeMat4(this.vp, t * 16, viewProj);
        unchecked(this.made[t] = made);
        unchecked(this.missed[t] = missed);
    }

    // Tile `t` cleared or overwritten by another view: it holds nothing of
    // the records.
    forget(t: i32): void {
        unchecked(this.valid[t] = false);
    }

    // Whether item `i` was recorded with any tile.
    had(i: i32): bool {
        return i < this.count && unchecked(this.casters[i]) != 0;
    }

    // Item `i` is no more (the frame holds fewer items): the tiles it was
    // in, its record emptied.
    gone(i: i32): u32 {
        if (i >= this.count) return 0;
        const prev = unchecked(this.casters[i]);
        unchecked(this.casters[i] = 0);
        return prev;
    }

    // Item `i`, `d` now, in the tiles `now` as `kind` (its masked ranges
    // read the material epoch `epoch`, -1 when it has none; `buffers` and
    // `instGpu` its mesh's and instances' uploads): the tiles to draw again
    // for it (those it is in or was in when it changed or is volatile,
    // those it entered or left otherwise); its record made current.
    item(
        i: i32, now: u32, d: DrawItem, kind: u8, epoch: i32, buffers: MeshGpuBuffers?,
        instGpu: InstanceGpuBuffer?,
    ): u32 {
        const prev = i < this.count ? unchecked(this.casters[i]) : 0;
        if ((now | prev) == 0) return 0;
        unchecked(this.casters[i] = now);
        if (now == 0) return prev;
        let out: u32;
        if (prev == 0 || kind == CASTER_VOLATILE || unchecked(this.kinds[i]) == CASTER_VOLATILE
            || !this.same(i, d, kind, epoch, buffers, instGpu)) {
            out = now | prev;
        } else {
            out = now ^ prev;
        }
        this.record(i, d, kind, epoch, buffers, instGpu);
        return out;
    }

    private same(
        i: i32, d: DrawItem, kind: u8, epoch: i32, buffers: MeshGpuBuffers?, instGpu: InstanceGpuBuffer?,
    ): bool {
        if (unchecked(this.kinds[i]) != kind || unchecked(this.epochs[i]) != epoch) return false;
        if (unchecked(this.meshes[i]) !== d.mesh || unchecked(this.buffers[i]) !== buffers) return false;
        if (unchecked(this.lods[i]) != d.lod || unchecked(this.materials[i]) !== d.materials
            || unchecked(this.nextPass[i]) != d.nextPassOf) return false;
        const inst = d.instances;
        if (unchecked(this.instGpu[i]) !== instGpu) return false;
        if (inst != null && (unchecked(this.instCount[i]) != inst.count || unchecked(this.instVersion[i]) != inst.version)) {
            return false;
        }
        return sameMat4Array(this.world, i * 16, d.world);
    }

    private record(
        i: i32, d: DrawItem, kind: u8, epoch: i32, buffers: MeshGpuBuffers?, instGpu: InstanceGpuBuffer?,
    ): void {
        unchecked(this.kinds[i] = kind);
        unchecked(this.epochs[i] = epoch);
        unchecked(this.meshes[i] = d.mesh);
        unchecked(this.buffers[i] = buffers);
        unchecked(this.lods[i] = d.lod);
        unchecked(this.materials[i] = d.materials);
        unchecked(this.nextPass[i] = d.nextPassOf);
        unchecked(this.instGpu[i] = instGpu);
        const inst = d.instances;
        unchecked(this.instCount[i] = inst != null ? inst.count : 0);
        unchecked(this.instVersion[i] = inst != null ? inst.version : 0);
        writeMat4Array(this.world, i * 16, d.world);
    }
}

// The bits of `m` against `a[o..o + 16]` (column by column).
function sameMat4(a: StaticArray<u32>, o: i32, m: Mat4): bool {
    return unchecked(a[o]) == reinterpret<u32>(m.xAxis.x) && unchecked(a[o + 1]) == reinterpret<u32>(m.xAxis.y)
        && unchecked(a[o + 2]) == reinterpret<u32>(m.xAxis.z) && unchecked(a[o + 3]) == reinterpret<u32>(m.xAxis.w)
        && unchecked(a[o + 4]) == reinterpret<u32>(m.yAxis.x) && unchecked(a[o + 5]) == reinterpret<u32>(m.yAxis.y)
        && unchecked(a[o + 6]) == reinterpret<u32>(m.yAxis.z) && unchecked(a[o + 7]) == reinterpret<u32>(m.yAxis.w)
        && unchecked(a[o + 8]) == reinterpret<u32>(m.zAxis.x) && unchecked(a[o + 9]) == reinterpret<u32>(m.zAxis.y)
        && unchecked(a[o + 10]) == reinterpret<u32>(m.zAxis.z) && unchecked(a[o + 11]) == reinterpret<u32>(m.zAxis.w)
        && unchecked(a[o + 12]) == reinterpret<u32>(m.wAxis.x) && unchecked(a[o + 13]) == reinterpret<u32>(m.wAxis.y)
        && unchecked(a[o + 14]) == reinterpret<u32>(m.wAxis.z) && unchecked(a[o + 15]) == reinterpret<u32>(m.wAxis.w);
}

function writeMat4(a: StaticArray<u32>, o: i32, m: Mat4): void {
    unchecked(a[o] = reinterpret<u32>(m.xAxis.x));
    unchecked(a[o + 1] = reinterpret<u32>(m.xAxis.y));
    unchecked(a[o + 2] = reinterpret<u32>(m.xAxis.z));
    unchecked(a[o + 3] = reinterpret<u32>(m.xAxis.w));
    unchecked(a[o + 4] = reinterpret<u32>(m.yAxis.x));
    unchecked(a[o + 5] = reinterpret<u32>(m.yAxis.y));
    unchecked(a[o + 6] = reinterpret<u32>(m.yAxis.z));
    unchecked(a[o + 7] = reinterpret<u32>(m.yAxis.w));
    unchecked(a[o + 8] = reinterpret<u32>(m.zAxis.x));
    unchecked(a[o + 9] = reinterpret<u32>(m.zAxis.y));
    unchecked(a[o + 10] = reinterpret<u32>(m.zAxis.z));
    unchecked(a[o + 11] = reinterpret<u32>(m.zAxis.w));
    unchecked(a[o + 12] = reinterpret<u32>(m.wAxis.x));
    unchecked(a[o + 13] = reinterpret<u32>(m.wAxis.y));
    unchecked(a[o + 14] = reinterpret<u32>(m.wAxis.z));
    unchecked(a[o + 15] = reinterpret<u32>(m.wAxis.w));
}

function sameMat4Array(a: Array<u32>, o: i32, m: Mat4): bool {
    return unchecked(a[o]) == reinterpret<u32>(m.xAxis.x) && unchecked(a[o + 1]) == reinterpret<u32>(m.xAxis.y)
        && unchecked(a[o + 2]) == reinterpret<u32>(m.xAxis.z) && unchecked(a[o + 3]) == reinterpret<u32>(m.xAxis.w)
        && unchecked(a[o + 4]) == reinterpret<u32>(m.yAxis.x) && unchecked(a[o + 5]) == reinterpret<u32>(m.yAxis.y)
        && unchecked(a[o + 6]) == reinterpret<u32>(m.yAxis.z) && unchecked(a[o + 7]) == reinterpret<u32>(m.yAxis.w)
        && unchecked(a[o + 8]) == reinterpret<u32>(m.zAxis.x) && unchecked(a[o + 9]) == reinterpret<u32>(m.zAxis.y)
        && unchecked(a[o + 10]) == reinterpret<u32>(m.zAxis.z) && unchecked(a[o + 11]) == reinterpret<u32>(m.zAxis.w)
        && unchecked(a[o + 12]) == reinterpret<u32>(m.wAxis.x) && unchecked(a[o + 13]) == reinterpret<u32>(m.wAxis.y)
        && unchecked(a[o + 14]) == reinterpret<u32>(m.wAxis.z) && unchecked(a[o + 15]) == reinterpret<u32>(m.wAxis.w);
}

function writeMat4Array(a: Array<u32>, o: i32, m: Mat4): void {
    unchecked(a[o] = reinterpret<u32>(m.xAxis.x));
    unchecked(a[o + 1] = reinterpret<u32>(m.xAxis.y));
    unchecked(a[o + 2] = reinterpret<u32>(m.xAxis.z));
    unchecked(a[o + 3] = reinterpret<u32>(m.xAxis.w));
    unchecked(a[o + 4] = reinterpret<u32>(m.yAxis.x));
    unchecked(a[o + 5] = reinterpret<u32>(m.yAxis.y));
    unchecked(a[o + 6] = reinterpret<u32>(m.yAxis.z));
    unchecked(a[o + 7] = reinterpret<u32>(m.yAxis.w));
    unchecked(a[o + 8] = reinterpret<u32>(m.zAxis.x));
    unchecked(a[o + 9] = reinterpret<u32>(m.zAxis.y));
    unchecked(a[o + 10] = reinterpret<u32>(m.zAxis.z));
    unchecked(a[o + 11] = reinterpret<u32>(m.zAxis.w));
    unchecked(a[o + 12] = reinterpret<u32>(m.wAxis.x));
    unchecked(a[o + 13] = reinterpret<u32>(m.wAxis.y));
    unchecked(a[o + 14] = reinterpret<u32>(m.wAxis.z));
    unchecked(a[o + 15] = reinterpret<u32>(m.wAxis.w));
}
