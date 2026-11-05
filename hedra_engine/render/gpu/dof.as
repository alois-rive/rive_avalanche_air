// Milestone 62: the depth of field on the GPU (../screen.as says what it
// is, ../dof.as is the CPU reference of the shader;
// docs/engine/SCREEN_EFFECTS.md how it is drawn). The renderer
// (./renderer.as drawView) calls, for a view whose plan has `dof`, after
// the main pass and before the glow:
//
//   draw(gpu, f, plan, inp, warnings)  the three passes of
//       shaders/render/post_dof.wgsl: fs_dof_coc (the half-size colour and
//       circle of confusion, DOF_FORMAT at plan.dofWidth x plan.dofHeight,
//       from inp.colour and inp.normalDepth), fs_dof_gather (the bokeh
//       gather, the shape and taps of f.screenQuality, the same size) and
//       fs_dof_compose (each pixel blended by its own circle, DOF_FORMAT at
//       the render size); returns the composition's view, which the glow
//       and the final pass then read instead of inp.colour, or null (a
//       warning pushed once) when the host refuses its module, pipelines
//       or targets, and the view is then drawn sharp.
//
// beginFrame() starts a host frame: the targets and groups replaced in the
// frame before (a view drawn at a new size) are released there, and so is
// everything of a slot no view drew for ./ssr.as SCREEN_SLOT_IDLE_FRAMES
// frames. Each slot (inp.slot) keeps its own block, groups and targets
// from frame to frame: a view drawn again at the same size with the same
// inputs allocates nothing.
//
// One group 0 serves the three entries (the module's layout): the block at
// 0, the sharp colour at 1, the normal-depth target at 2, the half-size
// texture the pass reads at 3 (the circles for the gather, the gather for
// the composition; a 1 x 1 dummy for the first pass) and the linear sampler
// at 4.

import { abi } from "rive/bindings";
import {
    GPUBindGroup, GPUBindGroupLayout, GPUBindGroupSampler, GPUBindGroupTexture, GPUBindGroupUBO, GPUBuffer,
    GPUColorAttachment, GPUColorTargetDesc, GPUPassDesc, GPUPipeline, GPUPipelineDesc, GPURenderPass, GPUSampler,
    GPUShaderModule, GPUTexture, GPUTextureDesc, GPUTextureView,
} from "rive/gpu";
import { BufferUsage, CullMode, Filter, LoadOp, PrimitiveTopology, StoreOp, WrapMode } from "rive/gpu_enums";
import { Vec4 } from "../../base/vecmath";
import { RenderFrame } from "../frame";
import { PostPlan } from "../post";
import { DOF_TAPS, dofRadiusPx } from "../screen";
import { dofRingCount, dofRingTaps } from "../dof";
import { DOF_FORMAT, U32x4 } from "./layouts";
import { shaderAsset } from "./pipelines";
import { SCREEN_SLOT_IDLE_FRAMES } from "./ssr";
import { Gpu } from "./device";
import { ScreenInputs } from "./screen_inputs";

// The depth of field's shader asset (engine/src/shaders/render/post_dof.wgsl)
// and its entry points.
export const DOF_SHADER = "shaders/render/post_dof";
export const DOF_VERTEX = "vs_dof";
export const DOF_COC = "fs_dof_coc";
export const DOF_GATHER = "fs_dof_gather";
export const DOF_COMPOSE = "fs_dof_compose";

// What the renderer's warnings say when the host refuses the depth of
// field's module, pipelines or targets (the frame is drawn sharp).
export const DOF_PIPELINE_WARNING = "depth of field is not drawn: the host refused its pipelines";

// The block's bytes (post_dof.wgsl DofU) and the group's bindings.
export const DOF_UNIFORM_SIZE: u32 = 80;
export const DOF_BLOCK_BINDING: u32 = 0;
export const DOF_COLOUR_BINDING: u32 = 1;
export const DOF_ND_BINDING: u32 = 2;
export const DOF_HALF_BINDING: u32 = 3;
export const DOF_SAMPLER_BINDING: u32 = 4;

// post_dof.wgsl's DofU, written in place (dofUniformInto) and into kept
// bytes (writeAt), so filling it allocates nothing.
export class DofUniform {
    // xy the render size, zw the half size.
    size: Vec4 = Vec4(0, 0, 0, 0);
    // x 1 if dof_blur_far_enabled, y its distance, z its transition, w the
    // radius (dofRadiusPx: render pixels).
    far: Vec4 = Vec4(0, 0, 0, 0);
    // x 1 if dof_blur_near_enabled, y its distance, z its transition, w
    // the camera's far distance (where nothing is drawn).
    near: Vec4 = Vec4(0, 0, 0, 0);
    // x the bokeh shape (DOF_SHAPE_*), y the rings (dofRingCount), z 1
    // with jitter, w the taps (DOF_TAPS).
    shape: U32x4 = U32x4(0, 0, 0, 0);
    // The taps of rings 1 to 4 (dofRingTaps; 0 past the last).
    rings: U32x4 = U32x4(0, 0, 0, 0);

    writeAt(dv: DataView, off: u32): void {
        putVec4(dv, off, this.size);
        putVec4(dv, off + 16, this.far);
        putVec4(dv, off + 32, this.near);
        putU32x4(dv, off + 48, this.shape);
        putU32x4(dv, off + 64, this.rings);
    }
}

// `out` set for a view of frame `f` drawn at `pxW` x `pxH` (the render
// size), gathered at the plan's size. Returns `out`.
export function dofUniformInto(f: RenderFrame, plan: PostPlan, pxW: u32, pxH: u32, out: DofUniform): DofUniform {
    const d = f.dof;
    const q = f.screenQuality;
    out.size = Vec4(<f32>pxW, <f32>pxH, <f32>max<u32>(plan.dofWidth, 1), <f32>max<u32>(plan.dofHeight, 1));
    out.far = Vec4(d.farEnabled ? 1 : 0, d.farDistance, d.farTransition, dofRadiusPx(d, pxH));
    out.near = Vec4(d.nearEnabled ? 1 : 0, d.nearDistance, d.nearTransition, f.camera.far);
    const rings = dofRingCount(q.dofQuality);
    out.shape = U32x4(q.dofShape, <u32>rings, q.dofJitter ? 1 : 0, <u32>DOF_TAPS[rings - 1]);
    out.rings = U32x4(
        <u32>dofRingTaps(q.dofQuality, 1), rings >= 2 ? <u32>dofRingTaps(q.dofQuality, 2) : 0,
        rings >= 3 ? <u32>dofRingTaps(q.dofQuality, 3) : 0, rings >= 4 ? <u32>dofRingTaps(q.dofQuality, 4) : 0,
    );
    return out;
}

function putVec4(dv: DataView, off: u32, v: Vec4): void {
    dv.setFloat32(<i32>off, v.x, true);
    dv.setFloat32(<i32>off + 4, v.y, true);
    dv.setFloat32(<i32>off + 8, v.z, true);
    dv.setFloat32(<i32>off + 12, v.w, true);
}

function putU32x4(dv: DataView, off: u32, v: U32x4): void {
    dv.setUint32(<i32>off, v.x, true);
    dv.setUint32(<i32>off + 4, v.y, true);
    dv.setUint32(<i32>off + 8, v.z, true);
    dv.setUint32(<i32>off + 12, v.w, true);
}

// One target a slot keeps.
class DofTarget {
    texture: GPUTexture;
    view: GPUTextureView;
    width: u32;
    height: u32;

    constructor(texture: GPUTexture, view: GPUTextureView, width: u32, height: u32) {
        this.texture = texture;
        this.view = view;
        this.width = width;
        this.height = height;
    }
}

// One pass's group and the views it binds.
class DofDraw {
    group: GPUBindGroup? = null;
    colour: GPUTextureView? = null;
    nd: GPUTextureView? = null;
    half: GPUTextureView? = null;
}

// What one view slot keeps.
class DofSlot {
    buffer: GPUBuffer;
    coc: DofTarget? = null;
    gather: DofTarget? = null;
    compose: DofTarget? = null;
    cocDraw: DofDraw = new DofDraw();
    gatherDraw: DofDraw = new DofDraw();
    composeDraw: DofDraw = new DofDraw();
    // The last frame (GpuDof's count) a view drew this slot.
    used: i32 = 0;

    constructor(buffer: GPUBuffer) {
        this.buffer = buffer;
    }
}

export class GpuDof {
    // How many depth of field compositions were drawn since the module was
    // made (the tests and the cost tables read it).
    draws: i32 = 0;
    private tried: bool = false;
    private ready: bool = false;
    private warned: bool = false;
    private layout: GPUBindGroupLayout? = null;
    private cocPipeline: GPUPipeline? = null;
    private gatherPipeline: GPUPipeline? = null;
    private composePipeline: GPUPipeline? = null;
    private sampler: GPUSampler? = null;
    private dummyTexture: GPUTexture? = null;
    private dummy: GPUTextureView? = null;
    private slots: Array<DofSlot?> = [];
    // What a slot replaced this frame, released at the next beginFrame.
    private oldTextures: Array<GPUTexture> = [];
    private oldViews: Array<GPUTextureView> = [];
    private oldGroups: Array<GPUBindGroup> = [];
    private oldBuffers: Array<GPUBuffer> = [];
    private frame: i32 = 0;
    private block: DofUniform = new DofUniform();
    private bytes: ArrayBuffer = new ArrayBuffer(<i32>DOF_UNIFORM_SIZE);
    private dv: DataView;
    private colour: GPUColorAttachment = new GPUColorAttachment();
    private desc: GPUPassDesc = new GPUPassDesc();
    private passWrapper: GPURenderPass = new GPURenderPass(0);

    constructor() {
        this.dv = new DataView(this.bytes, 0, this.bytes.byteLength);
        const c = this.colour;
        // Every texel is written: the clear only spares the host a load.
        c.loadOp = LoadOp.clear;
        c.storeOp = StoreOp.store;
        c.clearR = 0;
        c.clearG = 0;
        c.clearB = 0;
        c.clearA = 0;
        this.desc.color = [c];
    }

    // The view's depth of field (see the header): the composition, or null.
    draw(gpu: Gpu, f: RenderFrame, plan: PostPlan, inp: ScreenInputs, warnings: Array<string>): GPUTextureView? {
        if (!plan.dof || inp.slot < 0) return null;
        const colour = inp.colour;
        const nd = inp.normalDepth;
        if (colour == null || nd == null) return null;
        if (!this.prepare(gpu)) return this.refuse(warnings);
        const s = this.slotOf(inp.slot);
        s.used = this.frame;
        const hw = max<u32>(plan.dofWidth, 1);
        const hh = max<u32>(plan.dofHeight, 1);
        // (each field takes what targetOf returns, null too: a target it
        // retired is never kept, released twice or drawn into again)
        const coc = this.targetOf(s.coc, hw, hh);
        s.coc = coc;
        if (coc == null) return this.refuse(warnings);
        const gather = this.targetOf(s.gather, hw, hh);
        s.gather = gather;
        if (gather == null) return this.refuse(warnings);
        const compose = this.targetOf(s.compose, max<u32>(inp.pxW, 1), max<u32>(inp.pxH, 1));
        s.compose = compose;
        if (compose == null) return this.refuse(warnings);
        dofUniformInto(f, plan, inp.pxW, inp.pxH, this.block).writeAt(this.dv, 0);
        s.buffer.update(0, this.bytes, DOF_UNIFORM_SIZE);
        const g0 = this.groupOf(s, s.cocDraw, colour, nd, this.dummy!);
        const g1 = this.groupOf(s, s.gatherDraw, colour, nd, coc.view);
        const g2 = this.groupOf(s, s.composeDraw, colour, nd, gather.view);
        if (g0 == null || g1 == null || g2 == null) return this.refuse(warnings);
        if (!this.pass(gpu, coc.view, this.cocPipeline!, g0)) return this.refuse(warnings);
        if (!this.pass(gpu, gather.view, this.gatherPipeline!, g1)) return this.refuse(warnings);
        if (!this.pass(gpu, compose.view, this.composePipeline!, g2)) return this.refuse(warnings);
        this.draws++;
        return compose.view;
    }

    beginFrame(): void {
        this.frame++;
        for (let i = 0; i < this.oldGroups.length; i++) this.oldGroups[i].release();
        for (let i = 0; i < this.oldViews.length; i++) this.oldViews[i].release();
        for (let i = 0; i < this.oldTextures.length; i++) this.oldTextures[i].release();
        for (let i = 0; i < this.oldBuffers.length; i++) this.oldBuffers[i].release();
        // (emptied in place: the lists keep their storage)
        this.oldGroups.length = 0;
        this.oldViews.length = 0;
        this.oldTextures.length = 0;
        this.oldBuffers.length = 0;
        // The slots no view drew for a while, released with the next frame.
        for (let i = 0; i < this.slots.length; i++) {
            const s = this.slots[i];
            if (s == null || this.frame - s.used <= SCREEN_SLOT_IDLE_FRAMES) continue;
            this.retireSlot(s);
            this.slots[i] = null;
        }
    }

    // How many view slots hold a block and targets (the tests read it).
    slotCount(): i32 {
        let n = 0;
        for (let i = 0; i < this.slots.length; i++) if (this.slots[i] != null) n++;
        return n;
    }

    // Everything of slot `s` to be released at the next beginFrame.
    private retireSlot(s: DofSlot): void {
        this.retireTarget(s.coc);
        this.retireTarget(s.gather);
        this.retireTarget(s.compose);
        s.coc = null;
        s.gather = null;
        s.compose = null;
        this.retireDraw(s.cocDraw);
        this.retireDraw(s.gatherDraw);
        this.retireDraw(s.composeDraw);
        this.oldBuffers.push(s.buffer);
    }

    // Releases everything the module made (the renderer's release).
    release(): void {
        this.beginFrame();
        for (let i = 0; i < this.slots.length; i++) {
            const s = this.slots[i];
            if (s == null) continue;
            this.retireSlot(s);
            this.slots[i] = null;
        }
        this.beginFrame();
        const a = this.cocPipeline;
        if (a != null) a.release();
        const b = this.gatherPipeline;
        if (b != null) b.release();
        const c = this.composePipeline;
        if (c != null) c.release();
        this.cocPipeline = null;
        this.gatherPipeline = null;
        this.composePipeline = null;
        const sm = this.sampler;
        if (sm != null) sm.release();
        this.sampler = null;
        const dv = this.dummy;
        if (dv != null) dv.release();
        const dt = this.dummyTexture;
        if (dt != null) dt.release();
        this.dummy = null;
        this.dummyTexture = null;
        this.layout = null;
        this.ready = false;
        this.tried = false;
    }

    // The warning, once; null.
    private refuse(warnings: Array<string>): GPUTextureView? {
        if (!this.warned) {
            this.warned = true;
            warnings.push(DOF_PIPELINE_WARNING);
        }
        return null;
    }

    // The module's layout, its three pipelines, the sampler and the dummy,
    // made once; false when the project has no DOF_SHADER or the host
    // refuses any of them.
    private prepare(gpu: Gpu): bool {
        if (this.tried) return this.ready;
        this.tried = true;
        const mod = gpu.ctx.shader(shaderAsset(DOF_SHADER));
        if (mod == null) return false;
        const layout = GPUBindGroupLayout.fromShader(mod, 0);
        if (layout == null) return false;
        const coc = dofPipeline(mod, layout, DOF_COC);
        const gather = dofPipeline(mod, layout, DOF_GATHER);
        const compose = dofPipeline(mod, layout, DOF_COMPOSE);
        const sampler = new GPUSampler(Filter.linear, Filter.linear, Filter.nearest, WrapMode.clampToEdge, WrapMode.clampToEdge);
        const d = new GPUTextureDesc();
        d.width = 1;
        d.height = 1;
        d.format = DOF_FORMAT;
        d.sampleCount = 1;
        d.renderTarget = true;
        d.numMipmaps = 1;
        const dummyTexture = new GPUTexture(d);
        const dummy = dummyTexture.handle != 0 ? dummyTexture.view() : null;
        if (coc.handle == 0 || gather.handle == 0 || compose.handle == 0 || sampler.handle == 0 || dummy == null
            || dummy.handle == 0) {
            if (coc.handle != 0) coc.release();
            if (gather.handle != 0) gather.release();
            if (compose.handle != 0) compose.release();
            if (sampler.handle != 0) sampler.release();
            if (dummy != null && dummy.handle != 0) dummy.release();
            if (dummyTexture.handle != 0) dummyTexture.release();
            return false;
        }
        this.layout = layout;
        this.cocPipeline = coc;
        this.gatherPipeline = gather;
        this.composePipeline = compose;
        this.sampler = sampler;
        this.dummyTexture = dummyTexture;
        this.dummy = dummy;
        this.ready = true;
        return true;
    }

    private slotOf(id: i32): DofSlot {
        while (this.slots.length <= id) this.slots.push(null);
        const kept = this.slots[id];
        if (kept != null) return kept;
        const s = new DofSlot(new GPUBuffer(BufferUsage.uniform, DOF_UNIFORM_SIZE));
        s.used = this.frame;
        this.slots[id] = s;
        return s;
    }

    // `kept` when it is `w` x `h`, else a new target replacing it (the old
    // released at the next beginFrame, whether or not the new one is made);
    // null when the host refuses it. The caller stores what it returns.
    private targetOf(kept: DofTarget?, w: u32, h: u32): DofTarget? {
        if (kept != null && kept.width == w && kept.height == h) return kept;
        this.retireTarget(kept);
        const d = new GPUTextureDesc();
        d.width = w;
        d.height = h;
        d.format = DOF_FORMAT;
        d.sampleCount = 1;
        d.renderTarget = true;
        d.numMipmaps = 1;
        const texture = new GPUTexture(d);
        if (texture.handle == 0) return null;
        const view = texture.view();
        if (view.handle == 0) {
            texture.release();
            return null;
        }
        return new DofTarget(texture, view, w, h);
    }

    private retireTarget(t: DofTarget?): void {
        if (t == null) return;
        this.oldViews.push(t.view);
        this.oldTextures.push(t.texture);
    }

    private retireDraw(d: DofDraw): void {
        const g = d.group;
        if (g != null) this.oldGroups.push(g);
        d.group = null;
        d.colour = null;
        d.nd = null;
        d.half = null;
    }

    // Draw `d`'s group, kept while it binds the same views.
    private groupOf(
        s: DofSlot, d: DofDraw, colour: GPUTextureView, nd: GPUTextureView, half: GPUTextureView,
    ): GPUBindGroup? {
        const kept = d.group;
        if (kept != null && d.colour === colour && d.nd === nd && d.half === half) return kept;
        this.retireDraw(d);
        const g = new GPUBindGroup(
            this.layout!,
            [new GPUBindGroupUBO(DOF_BLOCK_BINDING, s.buffer, 0, DOF_UNIFORM_SIZE)],
            [
                new GPUBindGroupTexture(DOF_COLOUR_BINDING, colour), new GPUBindGroupTexture(DOF_ND_BINDING, nd),
                new GPUBindGroupTexture(DOF_HALF_BINDING, half),
            ],
            [new GPUBindGroupSampler(DOF_SAMPLER_BINDING, this.sampler!)],
        );
        if (g.handle == 0) return null;
        d.group = g;
        d.colour = colour;
        d.nd = nd;
        d.half = half;
        return g;
    }

    // One full-screen draw of `pipeline` with `group` into `target`.
    private pass(gpu: Gpu, target: GPUTextureView, pipeline: GPUPipeline, group: GPUBindGroup): bool {
        this.colour.view = target;
        this.colour.resolveTarget = null;
        this.desc.label = "hedra dof";
        const pass = gpu.canvas.beginRenderPass(this.desc, this.passWrapper);
        if (pass.handle == 0) return false;
        pass.setPipeline(pipeline);
        // GPURenderPass.setBindGroup's default offsets are a new array per
        // call: the binding itself, with none (renderer.as `bindGroup`).
        abi.rive_gpu_pass_set_bind_group(pass.handle, 0, group.handle, 0, 0);
        pass.draw(3);
        pass.finish();
        return true;
    }
}

// One of the module's pipelines: the full-screen triangle, fragment entry
// `fs`, one DOF_FORMAT target written as it is, no depth, one sample.
function dofPipeline(mod: GPUShaderModule, layout: GPUBindGroupLayout, fs: string): GPUPipeline {
    const d = new GPUPipelineDesc();
    d.vertexModule = mod;
    d.vertexEntryPoint = DOF_VERTEX;
    d.fragmentModule = mod;
    d.fragmentEntryPoint = fs;
    const t = new GPUColorTargetDesc();
    t.format = DOF_FORMAT;
    t.blend = null;
    d.colorTargets = [t];
    d.vertexBuffers = [];
    const layouts: Array<GPUBindGroupLayout?> = [layout];
    d.bindGroupLayouts = layouts;
    d.topology = PrimitiveTopology.triangleList;
    d.cullMode = CullMode.none;
    d.depthStencil = null;
    d.sampleCount = 1;
    return new GPUPipeline(d);
}
