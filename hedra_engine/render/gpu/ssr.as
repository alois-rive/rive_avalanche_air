// Milestone 62: screen-space reflections on the GPU (../screen.as says
// what they are, ../ssr.as is the CPU reference of the shader;
// docs/engine/SCREEN_EFFECTS.md how they are drawn). The renderer
// (./renderer.as drawView) calls, for a view whose plan has `ssr`, after
// the screen texture is made and before the main pass's second half:
//
//   trace(gpu, f, plan, inp, warnings)  at a trace size that is not the
//       render size, one full-screen pass of shaders/render/post_ssr.wgsl
//       (fs_ssr_nd_half) copying the normal-depth texels the march reads
//       into the view's NORMAL_DEPTH_FORMAT target of the trace's size
//       (a quarter of the bytes, or a sixteenth, for the march's many reads
//       and the merge's upsample, the same values); then one
//       (fs_ssr_trace) at plan.ssrWidth x
//       plan.ssrHeight into the view's SSR_FORMAT target, from
//       inp.normalDepth, inp.surface and inp.screen, marching over that
//       copy (or over inp.normalDepth at the render size); false (a
//       warning pushed once) when the host refuses its module, pipelines
//       or targets, and the view then draws no reflection;
//   merge(pass, slot)  inside the main pass's second half (begun with
//       inp.samples samples, COLOR_FORMAT and DEPTH_FORMAT), a full-screen
//       draw (fs_ssr_merge) laying the traced reflections over the colour
//       (premultiplied over: colour one, one minus source alpha; alpha
//       zero, one, so a transparent view's alpha is kept; the depth
//       compared always and not written); nothing when trace returned
//       false for that slot this frame. The caller binds its own pipeline
//       again after it (the pass's state is the renderer's).
//   mergeOver(gpu, slot, colour)  the same draw in a pass of its own, one
//       sample and no depth, over `colour` (COLOR_FORMAT, loaded and
//       stored): when the second half would draw nothing but the merge
//       (inp.mergeAlone, set before trace), the renderer draws no second
//       half. Its samples would all hold the first half's resolve (the
//       expand) and resolve to one blended value, so the bytes are the
//       same, without writing and resolving every sample again.
//
// beginFrame() starts a host frame: the targets and groups replaced in the
// frame before (a view drawn at a new size) are released there, after the
// passes that read them were submitted, and so is everything of a slot no
// view traced for SCREEN_SLOT_IDLE_FRAMES frames (a closed viewport, a view
// whose reflections were turned off). Each slot (inp.slot, the view's
// ViewBuffers.customId) keeps its own block, groups and target from frame
// to frame: a view drawn again at the same size with the same inputs
// allocates nothing (the block is written into kept bytes, the groups are
// kept while they bind the same views, the pass descriptor is the
// module's).
//
// One group 0 serves every entry (the module's layout): the block at 0,
// the normal-depth target at 1, the surface target at 2, the screen
// texture at 3, the linear sampler at 4, the trace at 5 and what the march
// reads at 6 (the trace-size copy, or the normal-depth target), each pass's
// own group filling what it draws into, or does not read, with a 1 x 1
// dummy (a target is never bound while it is drawn into).

import { abi } from "rive/bindings";
import {
    GPUBindGroup, GPUBindGroupLayout, GPUBindGroupSampler, GPUBindGroupTexture, GPUBindGroupUBO, GPUBlendState,
    GPUBuffer, GPUColorAttachment, GPUColorTargetDesc, GPUDepthStencilDesc, GPUPassDesc, GPUPipeline,
    GPUPipelineDesc, GPURenderPass, GPUSampler, GPUShaderModule, GPUTexture, GPUTextureDesc, GPUTextureView,
} from "rive/gpu";
import {
    BlendFactor, BlendOp, BufferUsage, CompareFunction, CullMode, Filter, LoadOp, PrimitiveTopology, StoreOp,
    TextureFormat, WrapMode,
} from "rive/gpu_enums";
import { Mat4, Vec4 } from "../../base/vecmath";
import { RenderFrame } from "../frame";
import { PostPlan } from "../post";
import { ssrSteps } from "../screen";
import { COLOR_FORMAT, DEPTH_FORMAT, NORMAL_DEPTH_FORMAT, SSR_FORMAT, U32x4 } from "./layouts";
import { shaderAsset } from "./pipelines";
import { Gpu } from "./device";
import { ScreenInputs } from "./screen_inputs";

// The reflections' shader asset (engine/src/shaders/render/post_ssr.wgsl)
// and its entry points.
export const SSR_SHADER = "shaders/render/post_ssr";
export const SSR_VERTEX = "vs_ssr";
export const SSR_TRACE = "fs_ssr_trace";
export const SSR_ND_HALF = "fs_ssr_nd_half";
export const SSR_MERGE = "fs_ssr_merge";

// What the renderer's warnings say when the host refuses the reflections'
// module, pipelines or target (the frame is drawn without them).
export const SSR_PIPELINE_WARNING = "screen-space reflections are not drawn: the host refused their pipelines";

// The frames a slot is kept without a trace before beginFrame releases it
// (2 s at 60 frames a second; a view drawn again later makes it again).
export const SCREEN_SLOT_IDLE_FRAMES: i32 = 120;

// The block's bytes (post_ssr.wgsl SsrU) and the group's bindings.
export const SSR_UNIFORM_SIZE: u32 = 192;
export const SSR_BLOCK_BINDING: u32 = 0;
export const SSR_ND_BINDING: u32 = 1;
export const SSR_SURFACE_BINDING: u32 = 2;
export const SSR_SCREEN_BINDING: u32 = 3;
export const SSR_SAMPLER_BINDING: u32 = 4;
export const SSR_TRACE_BINDING: u32 = 5;
export const SSR_MARCH_BINDING: u32 = 6;

// post_ssr.wgsl's SsrU, written in place (ssrUniformInto) and into kept
// bytes (writeAt), so filling it allocates nothing.
export class SsrUniform {
    // xy the render size, zw the trace's.
    size: Vec4 = Vec4(0, 0, 0, 0);
    // x the camera's near distance, y its far, z 1 if orthographic, w
    // ssr_depth_tolerance (0 at least).
    cam: Vec4 = Vec4(0, 0, 0, 0);
    // x the steps (ssrSteps), y ssr_fade_in, z ssr_fade_out (0 at least),
    // w the screen texture's levels.
    march: Vec4 = Vec4(0, 0, 0, 0);
    // x the roughness quality (SSR_ROUGHNESS_*), y 1 when the trace is not
    // the render size (the merge's bilateral upsample).
    flags: U32x4 = U32x4(0, 0, 0, 0);
    proj: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
    invProj: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));

    writeAt(dv: DataView, off: u32): void {
        putVec4(dv, off, this.size);
        putVec4(dv, off + 16, this.cam);
        putVec4(dv, off + 32, this.march);
        dv.setUint32(<i32>off + 48, this.flags.x, true);
        dv.setUint32(<i32>off + 52, this.flags.y, true);
        dv.setUint32(<i32>off + 56, this.flags.z, true);
        dv.setUint32(<i32>off + 60, this.flags.w, true);
        putMat4(dv, off + 64, this.proj);
        putMat4(dv, off + 128, this.invProj);
    }
}

// `out` set for a view of frame `f` drawn at `pxW` x `pxH` (the render
// size) whose screen texture holds `levels` levels, traced at the plan's
// size. Returns `out`.
export function ssrUniformInto(f: RenderFrame, plan: PostPlan, pxW: u32, pxH: u32, levels: i32, out: SsrUniform): SsrUniform {
    const s = f.environment.ssr;
    const cam = f.camera;
    const tw = max<u32>(plan.ssrWidth, 1);
    const th = max<u32>(plan.ssrHeight, 1);
    out.size = Vec4(<f32>pxW, <f32>pxH, <f32>tw, <f32>th);
    out.cam = Vec4(cam.near, cam.far, cam.isOrtho() ? 1 : 0, max<f32>(s.depthTolerance, 0));
    out.march = Vec4(<f32>ssrSteps(s), max<f32>(s.fadeIn, 0), max<f32>(s.fadeOut, 0), <f32>max<i32>(levels, 0));
    out.flags = U32x4(f.screenQuality.ssrRoughnessQuality, tw != pxW || th != pxH ? 1 : 0, 0, 0);
    const proj = cam.projectionMatrix(<f32>f.width / <f32>f.height);
    out.proj = proj;
    out.invProj = proj.inverse();
    return out;
}

function putVec4(dv: DataView, off: u32, v: Vec4): void {
    dv.setFloat32(<i32>off, v.x, true);
    dv.setFloat32(<i32>off + 4, v.y, true);
    dv.setFloat32(<i32>off + 8, v.z, true);
    dv.setFloat32(<i32>off + 12, v.w, true);
}

// Column-major, x axis first (WGSL's mat4x4).
function putMat4(dv: DataView, off: u32, m: Mat4): void {
    putVec4(dv, off, m.xAxis);
    putVec4(dv, off + 16, m.yAxis);
    putVec4(dv, off + 32, m.zAxis);
    putVec4(dv, off + 48, m.wAxis);
}

// What one view slot keeps.
class SsrSlot {
    buffer: GPUBuffer;
    texture: GPUTexture? = null;
    view: GPUTextureView? = null;
    width: u32 = 0;
    height: u32 = 0;
    // The trace-size copy of the normal-depth texels the march reads (null
    // while the trace is at the render size), and its pass's group and the
    // view it binds.
    halfTexture: GPUTexture? = null;
    halfView: GPUTextureView? = null;
    halfGroup: GPUBindGroup? = null;
    halfNd: GPUTextureView? = null;
    // The trace's group and the views it binds.
    traceGroup: GPUBindGroup? = null;
    traceNd: GPUTextureView? = null;
    traceSurface: GPUTextureView? = null;
    traceScreen: GPUTextureView? = null;
    traceMarch: GPUTextureView? = null;
    // The merge's group, the views it binds and its pipeline.
    mergeGroup: GPUBindGroup? = null;
    mergeNd: GPUTextureView? = null;
    mergeSurface: GPUTextureView? = null;
    mergeScreen: GPUTextureView? = null;
    mergeTrace: GPUTextureView? = null;
    mergeMarch: GPUTextureView? = null;
    mergePipeline: GPUPipeline? = null;
    // The frame (GpuSsr.frame) whose trace this slot's merge lays over.
    traced: i32 = -1;
    // The last frame a trace asked for this slot.
    used: i32 = 0;

    constructor(buffer: GPUBuffer) {
        this.buffer = buffer;
    }
}

export class GpuSsr {
    // How many traces, merges and half-size copies were drawn since the
    // module was made (the tests and the cost tables read them).
    traces: i32 = 0;
    merges: i32 = 0;
    halves: i32 = 0;
    // Of `merges`, those drawn in a pass of their own (mergeOver).
    mergesAlone: i32 = 0;
    // The passes the last `trace` drew (0 when it returned false; 2 with
    // the trace-size copy).
    lastPasses: i32 = 0;
    private tried: bool = false;
    private ready: bool = false;
    private warned: bool = false;
    private layout: GPUBindGroupLayout? = null;
    private module: GPUShaderModule? = null;
    private tracePipeline: GPUPipeline? = null;
    private halfPipeline: GPUPipeline? = null;
    // Milestone 67: the main pass's colour format the merge draws into
    // (the renderer sets it before `trace`: quality.as's format of the
    // view being drawn).
    colorFormat: TextureFormat = COLOR_FORMAT;
    // The merge's pipelines by sample count (0: mergeOver's, one sample
    // and no depth) and, milestone 67, colour format (the format << 8).
    private mergeSamples: Array<u32> = [];
    private mergePipelines: Array<GPUPipeline> = [];
    private sampler: GPUSampler? = null;
    private dummyTexture: GPUTexture? = null;
    private dummy: GPUTextureView? = null;
    private slots: Array<SsrSlot?> = [];
    private frame: i32 = 0;
    // What a slot replaced this frame, released at the next beginFrame.
    private oldTextures: Array<GPUTexture> = [];
    private oldViews: Array<GPUTextureView> = [];
    private oldGroups: Array<GPUBindGroup> = [];
    private oldBuffers: Array<GPUBuffer> = [];
    private block: SsrUniform = new SsrUniform();
    private bytes: ArrayBuffer = new ArrayBuffer(<i32>SSR_UNIFORM_SIZE);
    private dv: DataView;
    private colour: GPUColorAttachment = new GPUColorAttachment();
    private desc: GPUPassDesc = new GPUPassDesc();
    // mergeOver's pass: the colour loaded and stored.
    private mergeColour: GPUColorAttachment = new GPUColorAttachment();
    private mergeDesc: GPUPassDesc = new GPUPassDesc();
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
        const m = this.mergeColour;
        m.loadOp = LoadOp.load;
        m.storeOp = StoreOp.store;
        this.mergeDesc.color = [m];
    }

    // Draws the view's reflections into its target (see the header):
    // whether there is something for `merge` to lay over the colour.
    trace(gpu: Gpu, f: RenderFrame, plan: PostPlan, inp: ScreenInputs, warnings: Array<string>): bool {
        this.lastPasses = 0;
        if (!plan.ssr || inp.slot < 0) return false;
        const nd = inp.normalDepth;
        const surface = inp.surface;
        const screen = inp.screen;
        if (nd == null || surface == null || screen == null) return false;
        if (!this.prepare(gpu)) return this.refuse(warnings);
        const slot = this.slotOf(inp.slot);
        slot.used = this.frame;
        const tw = max<u32>(plan.ssrWidth, 1);
        const th = max<u32>(plan.ssrHeight, 1);
        const target = this.targetOf(slot, tw, th);
        if (target == null) return this.refuse(warnings);
        const merge = this.mergePipelineFor(inp.samples, inp.mergeAlone);
        if (merge == null) return this.refuse(warnings);
        // (what the march reads: the trace-size copy, or the normal-depth
        // target itself at the render size)
        const halved = tw != inp.pxW || th != inp.pxH;
        let march: GPUTextureView = nd;
        if (halved) {
            const half = this.halfOf(slot, tw, th);
            if (half == null) return this.refuse(warnings);
            march = half;
        } else {
            this.retireHalf(slot);
        }
        ssrUniformInto(f, plan, inp.pxW, inp.pxH, inp.screenLevels, this.block).writeAt(this.dv, 0);
        slot.buffer.update(0, this.bytes, SSR_UNIFORM_SIZE);
        const halfGroup = halved ? this.halfGroupOf(slot, nd, surface, screen) : null;
        const traceGroup = this.traceGroupOf(slot, nd, surface, screen, march);
        const mergeGroup = this.mergeGroupOf(slot, nd, surface, screen, target, march);
        if ((halved && halfGroup == null) || traceGroup == null || mergeGroup == null) return this.refuse(warnings);
        if (halfGroup != null) {
            this.colour.view = march;
            this.colour.resolveTarget = null;
            this.desc.label = "hedra ssr copy";
            const hp = gpu.canvas.beginRenderPass(this.desc, this.passWrapper);
            if (hp.handle == 0) return this.refuse(warnings);
            hp.setPipeline(this.halfPipeline!);
            abi.rive_gpu_pass_set_bind_group(hp.handle, 0, halfGroup.handle, 0, 0);
            hp.draw(3);
            hp.finish();
            this.halves++;
            this.lastPasses++;
        }
        this.colour.view = target;
        this.colour.resolveTarget = null;
        this.desc.label = "hedra ssr trace";
        const pass = gpu.canvas.beginRenderPass(this.desc, this.passWrapper);
        if (pass.handle == 0) return this.refuse(warnings);
        pass.setPipeline(this.tracePipeline!);
        // GPURenderPass.setBindGroup's default offsets are a new array per
        // call: the binding itself, with none (renderer.as `bindGroup`).
        abi.rive_gpu_pass_set_bind_group(pass.handle, 0, traceGroup.handle, 0, 0);
        pass.draw(3);
        pass.finish();
        slot.mergePipeline = merge;
        slot.traced = this.frame;
        this.traces++;
        this.lastPasses++;
        return true;
    }

    // Lays slot `slot`'s traced reflections over the colour of `pass` (see
    // the header).
    merge(pass: GPURenderPass, slot: i32): void {
        if (slot < 0 || slot >= this.slots.length) return;
        const s = this.slots[slot];
        if (s == null || s.traced != this.frame) return;
        const pipeline = s.mergePipeline;
        const group = s.mergeGroup;
        if (pipeline == null || group == null) return;
        pass.setPipeline(pipeline);
        abi.rive_gpu_pass_set_bind_group(pass.handle, 0, group.handle, 0, 0);
        pass.draw(3);
        this.merges++;
    }

    // Lays slot `slot`'s traced reflections over `colour` in a pass of
    // their own (see the header): whether they were drawn (not when trace
    // returned false for that slot this frame, or the host refused the
    // pass).
    mergeOver(gpu: Gpu, slot: i32, colour: GPUTextureView): bool {
        if (slot < 0 || slot >= this.slots.length) return false;
        const s = this.slots[slot];
        if (s == null || s.traced != this.frame || s.mergePipeline == null || s.mergeGroup == null) return false;
        this.mergeColour.view = colour;
        this.mergeColour.resolveTarget = null;
        this.mergeDesc.label = "hedra ssr merge";
        const pass = gpu.canvas.beginRenderPass(this.mergeDesc, this.passWrapper);
        if (pass.handle == 0) return false;
        this.merge(pass, slot);
        pass.finish();
        this.mergesAlone++;
        return true;
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
        // The slots no view traced for a while, released with the next frame.
        for (let i = 0; i < this.slots.length; i++) {
            const s = this.slots[i];
            if (s == null || this.frame - s.used <= SCREEN_SLOT_IDLE_FRAMES) continue;
            this.retire(s);
            this.oldBuffers.push(s.buffer);
            this.slots[i] = null;
        }
    }

    // How many view slots hold a block and targets (the tests read it).
    slotCount(): i32 {
        let n = 0;
        for (let i = 0; i < this.slots.length; i++) if (this.slots[i] != null) n++;
        return n;
    }

    // Releases everything the module made (the renderer's release).
    release(): void {
        this.beginFrame();
        for (let i = 0; i < this.slots.length; i++) {
            const s = this.slots[i];
            if (s == null) continue;
            this.retire(s);
            this.oldBuffers.push(s.buffer);
            this.slots[i] = null;
        }
        this.beginFrame();
        for (let i = 0; i < this.mergePipelines.length; i++) this.mergePipelines[i].release();
        this.mergePipelines.length = 0;
        this.mergeSamples.length = 0;
        const t = this.tracePipeline;
        if (t != null) t.release();
        this.tracePipeline = null;
        const hp = this.halfPipeline;
        if (hp != null) hp.release();
        this.halfPipeline = null;
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
        this.module = null;
        this.ready = false;
        this.tried = false;
    }

    // The warning, once; false.
    private refuse(warnings: Array<string>): bool {
        if (!this.warned) {
            this.warned = true;
            warnings.push(SSR_PIPELINE_WARNING);
        }
        return false;
    }

    // The module, its layout, the trace's pipeline, the sampler and the
    // dummy, made once; false when the project has no SSR_SHADER or the
    // host refuses any of them.
    private prepare(gpu: Gpu): bool {
        if (this.tried) return this.ready;
        this.tried = true;
        const mod = gpu.ctx.shader(shaderAsset(SSR_SHADER));
        if (mod == null) return false;
        const layout = GPUBindGroupLayout.fromShader(mod, 0);
        if (layout == null) return false;
        const trace = ssrPipeline(mod, layout, SSR_TRACE, SSR_FORMAT, null, null, 1);
        const half = ssrPipeline(mod, layout, SSR_ND_HALF, NORMAL_DEPTH_FORMAT, null, null, 1);
        const sampler = new GPUSampler(Filter.linear, Filter.linear, Filter.linear, WrapMode.clampToEdge, WrapMode.clampToEdge);
        const d = new GPUTextureDesc();
        d.width = 1;
        d.height = 1;
        d.format = SSR_FORMAT;
        d.sampleCount = 1;
        d.renderTarget = true;
        d.numMipmaps = 1;
        const dummyTexture = new GPUTexture(d);
        const dummy = dummyTexture.handle != 0 ? dummyTexture.view() : null;
        if (trace.handle == 0 || half.handle == 0 || sampler.handle == 0 || dummy == null || dummy.handle == 0) {
            if (trace.handle != 0) trace.release();
            if (half.handle != 0) half.release();
            if (sampler.handle != 0) sampler.release();
            if (dummy != null && dummy.handle != 0) dummy.release();
            if (dummyTexture.handle != 0) dummyTexture.release();
            return false;
        }
        this.module = mod;
        this.layout = layout;
        this.tracePipeline = trace;
        this.halfPipeline = half;
        this.sampler = sampler;
        this.dummyTexture = dummyTexture;
        this.dummy = dummy;
        this.ready = true;
        return true;
    }

    // The merge's pipeline for `samples` samples, or with `alone`
    // mergeOver's (one sample, no depth), made on first use; null when the
    // host refuses it.
    private mergePipelineFor(samples: u32, alone: bool): GPUPipeline? {
        const n = alone ? 0 : max<u32>(samples, 1);
        const format = this.colorFormat;
        const keyed = n | (<u32>format << 8);
        for (let i = 0; i < this.mergeSamples.length; i++) {
            if (this.mergeSamples[i] == keyed) return this.mergePipelines[i];
        }
        const b = new GPUBlendState();
        b.srcColor = BlendFactor.one;
        b.dstColor = BlendFactor.oneMinusSrcAlpha;
        b.colorOp = BlendOp.add;
        b.srcAlpha = BlendFactor.zero;
        b.dstAlpha = BlendFactor.one;
        b.alphaOp = BlendOp.add;
        let ds: GPUDepthStencilDesc? = null;
        if (!alone) {
            const d = new GPUDepthStencilDesc();
            d.format = DEPTH_FORMAT;
            d.compare = CompareFunction.always;
            d.write = false;
            d.depthBias = 0;
            d.depthBiasSlopeScale = 0;
            d.depthBiasClamp = 0;
            ds = d;
        }
        const p = ssrPipeline(this.module!, this.layout!, SSR_MERGE, format, b, ds, max<u32>(n, 1));
        if (p.handle == 0) return null;
        this.mergeSamples.push(keyed);
        this.mergePipelines.push(p);
        return p;
    }

    private slotOf(id: i32): SsrSlot {
        while (this.slots.length <= id) this.slots.push(null);
        const kept = this.slots[id];
        if (kept != null) return kept;
        const s = new SsrSlot(new GPUBuffer(BufferUsage.uniform, SSR_UNIFORM_SIZE));
        s.used = this.frame;
        this.slots[id] = s;
        return s;
    }

    // The slot's trace target at `w` x `h`: kept, or a new one replacing
    // it (the old released at the next beginFrame); null when the host
    // refuses it.
    private targetOf(s: SsrSlot, w: u32, h: u32): GPUTextureView? {
        const kept = s.view;
        if (kept != null && s.width == w && s.height == h) return kept;
        this.retire(s);
        const d = new GPUTextureDesc();
        d.width = w;
        d.height = h;
        d.format = SSR_FORMAT;
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
        s.texture = texture;
        s.view = view;
        s.width = w;
        s.height = h;
        return view;
    }

    // The slot's target and groups to be released at the next beginFrame.
    private retire(s: SsrSlot): void {
        const t = s.texture;
        const v = s.view;
        if (v != null) this.oldViews.push(v);
        if (t != null) this.oldTextures.push(t);
        const tg = s.traceGroup;
        if (tg != null) this.oldGroups.push(tg);
        const mg = s.mergeGroup;
        if (mg != null) this.oldGroups.push(mg);
        s.texture = null;
        s.view = null;
        s.width = 0;
        s.height = 0;
        s.traceGroup = null;
        s.mergeGroup = null;
        s.mergeTrace = null;
        s.mergeMarch = null;
        this.retireHalf(s);
    }

    // The slot's trace-size copy and its group to be released at the next
    // beginFrame (a trace at the render size reads none); the trace's and
    // the merge's groups bind it, so they go too.
    private retireHalf(s: SsrSlot): void {
        const v = s.halfView;
        const t = s.halfTexture;
        const g = s.halfGroup;
        if (v == null && t == null && g == null) return;
        if (v != null) this.oldViews.push(v);
        if (t != null) this.oldTextures.push(t);
        if (g != null) this.oldGroups.push(g);
        s.halfView = null;
        s.halfTexture = null;
        s.halfGroup = null;
        s.halfNd = null;
        const tg = s.traceGroup;
        if (tg != null && s.traceMarch !== s.traceNd) {
            this.oldGroups.push(tg);
            s.traceGroup = null;
            s.traceMarch = null;
        }
        const mg = s.mergeGroup;
        if (mg != null && s.mergeMarch !== s.mergeNd) {
            this.oldGroups.push(mg);
            s.mergeGroup = null;
            s.mergeMarch = null;
        }
    }

    // The slot's trace-size copy at `w` x `h` (the trace's size): kept, or
    // a new one; null when the host refuses it.
    private halfOf(s: SsrSlot, w: u32, h: u32): GPUTextureView? {
        const kept = s.halfView;
        if (kept != null && s.width == w && s.height == h) return kept;
        this.retireHalf(s);
        const d = new GPUTextureDesc();
        d.width = w;
        d.height = h;
        d.format = NORMAL_DEPTH_FORMAT;
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
        s.halfTexture = texture;
        s.halfView = view;
        return view;
    }

    // The trace-size copy's group: the normal-depth target read, the copy
    // (drawn into) and the trace bound as the dummy.
    private halfGroupOf(s: SsrSlot, nd: GPUTextureView, surface: GPUTextureView, screen: GPUTextureView): GPUBindGroup? {
        const kept = s.halfGroup;
        if (kept != null && s.halfNd === nd) return kept;
        if (kept != null) this.oldGroups.push(kept);
        s.halfGroup = null;
        const g = this.group(s, nd, surface, screen, this.dummy!, this.dummy!);
        if (g == null) return null;
        s.halfGroup = g;
        s.halfNd = nd;
        return g;
    }

    private traceGroupOf(
        s: SsrSlot, nd: GPUTextureView, surface: GPUTextureView, screen: GPUTextureView, march: GPUTextureView,
    ): GPUBindGroup? {
        const kept = s.traceGroup;
        if (kept != null && s.traceNd === nd && s.traceSurface === surface && s.traceScreen === screen
            && s.traceMarch === march) return kept;
        if (kept != null) this.oldGroups.push(kept);
        s.traceGroup = null;
        const g = this.group(s, nd, surface, screen, this.dummy!, march);
        if (g == null) return null;
        s.traceGroup = g;
        s.traceNd = nd;
        s.traceSurface = surface;
        s.traceScreen = screen;
        s.traceMarch = march;
        return g;
    }

    private mergeGroupOf(
        s: SsrSlot, nd: GPUTextureView, surface: GPUTextureView, screen: GPUTextureView, trace: GPUTextureView,
        march: GPUTextureView,
    ): GPUBindGroup? {
        const kept = s.mergeGroup;
        if (kept != null && s.mergeNd === nd && s.mergeSurface === surface && s.mergeScreen === screen
            && s.mergeTrace === trace && s.mergeMarch === march) return kept;
        if (kept != null) this.oldGroups.push(kept);
        s.mergeGroup = null;
        const g = this.group(s, nd, surface, screen, trace, march);
        if (g == null) return null;
        s.mergeGroup = g;
        s.mergeNd = nd;
        s.mergeSurface = surface;
        s.mergeScreen = screen;
        s.mergeTrace = trace;
        s.mergeMarch = march;
        return g;
    }

    private group(
        s: SsrSlot, nd: GPUTextureView, surface: GPUTextureView, screen: GPUTextureView, trace: GPUTextureView,
        march: GPUTextureView,
    ): GPUBindGroup? {
        const g = new GPUBindGroup(
            this.layout!,
            [new GPUBindGroupUBO(SSR_BLOCK_BINDING, s.buffer, 0, SSR_UNIFORM_SIZE)],
            [
                new GPUBindGroupTexture(SSR_ND_BINDING, nd), new GPUBindGroupTexture(SSR_SURFACE_BINDING, surface),
                new GPUBindGroupTexture(SSR_SCREEN_BINDING, screen), new GPUBindGroupTexture(SSR_TRACE_BINDING, trace),
                new GPUBindGroupTexture(SSR_MARCH_BINDING, march),
            ],
            [new GPUBindGroupSampler(SSR_SAMPLER_BINDING, this.sampler!)],
        );
        if (g.handle == 0) return null;
        return g;
    }
}

// One of the module's pipelines: the full-screen triangle, fragment entry
// `fs`, one target of `format` blended by `blend` (null: written as it
// is), the depth state `depth` (null: no depth attachment), `samples`
// samples.
function ssrPipeline(
    mod: GPUShaderModule, layout: GPUBindGroupLayout, fs: string, format: TextureFormat, blend: GPUBlendState?,
    depth: GPUDepthStencilDesc?, samples: u32,
): GPUPipeline {
    const d = new GPUPipelineDesc();
    d.vertexModule = mod;
    d.vertexEntryPoint = SSR_VERTEX;
    d.fragmentModule = mod;
    d.fragmentEntryPoint = fs;
    const t = new GPUColorTargetDesc();
    t.format = format;
    t.blend = blend;
    d.colorTargets = [t];
    d.vertexBuffers = [];
    const layouts: Array<GPUBindGroupLayout?> = [layout];
    d.bindGroupLayouts = layouts;
    d.topology = PrimitiveTopology.triangleList;
    d.cullMode = CullMode.none;
    d.depthStencil = depth;
    d.sampleCount = samples;
    return new GPUPipeline(d);
}
