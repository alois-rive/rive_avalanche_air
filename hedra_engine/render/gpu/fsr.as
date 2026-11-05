// AMD FidelityFX Super Resolution 1.0 (MIT; THIRD_PARTY_NOTICES.md), the
// spatial upscale of Godot's scaling_3d_mode FSR (docs/engine/
// PERFORMANCE.md, "Render scale"): a picture drawn smaller than the
// Scene3D's pixels (../scaling.as) is upscaled to them by EASU (edge
// adaptive spatial upsampling) and sharpened by RCAS (robust contrast
// adaptive sharpening, Godot's fsr_sharpness: 0 the sharpest, 2 the
// softest; Godot's default 0.2), each a full-screen fragment pass of
// shaders/render/post_fsr.wgsl (WebGL 2 has no compute), into a target of
// the output's size kept from frame to frame. Godot runs it after the tone
// map, on the finished picture, as here (the overlay and the selection
// outline are drawn before it, as Godot's 2D is not; the label is the
// host's).
//
// The renderer (./renderer.as renderFramePlanned) calls `upscale` after a
// view whose frame asks for an output size (RenderFrame.outputWidth); the
// picture it returns is presented 1:1. A host that refuses the pipelines
// presents the small picture stretched (bilinear), saying so once
// (FSR_PIPELINE_WARNING).
//
// The bilinear mode (SCALING_3D_BILINEAR) is the tools' stretch (`hedra
// render --render-scale`), one pass of fs_stretch: a Scene3D stretches its
// picture with Rive's image filter instead and sets no output size. A
// picture drawn larger than its output (a render scale above 1) is always
// brought down by the stretch, whatever the mode, since EASU only upscales:
// at exactly 2x its one bilinear tap, at the output pixel's centre,
// averages the 2 x 2 texels under it.
//
// The passes' labels: `hedra fsr easu`, `hedra fsr rcas`, `hedra stretch`.
// Memory: the module, its pipelines, sampler and block are made once; the
// two targets and their groups are kept while the size and the source view
// stay (a picture drawn again at the same size allocates nothing: the
// block is written from kept bytes); a target a resize replaced is
// released at the resize after (the picture of the size before may still
// be presented until the next one is drawn).

import { abi } from "rive/bindings";
import {
    GPUBindGroup, GPUBindGroupLayout, GPUBindGroupSampler, GPUBindGroupTexture, GPUBindGroupUBO, GPUBuffer,
    GPUColorAttachment, GPUColorTargetDesc, GPUPassDesc, GPUPipeline, GPUPipelineDesc, GPURenderPass, GPUSampler,
    GPUShaderModule, GPUTexture, GPUTextureDesc, GPUTextureView,
} from "rive/gpu";
import { BufferUsage, CullMode, Filter, LoadOp, PrimitiveTopology, StoreOp, WrapMode } from "rive/gpu_enums";
import { Gpu } from "./device";
import { POST_FORMAT, shaderAsset } from "./pipelines";
import { SCALING_3D_FSR } from "../quality";

export const FSR_PIPELINE_WARNING = "FSR 1.0 is not drawn: the host rejected its pipelines (the picture is stretched)";

// The module (engine/src/shaders/render/post_fsr.wgsl) and its entries.
export const FSR_SHADER = "shaders/render/post_fsr";
export const FSR_VERTEX = "vs_fsr";
export const FSR_EASU = "fs_easu";
export const FSR_RCAS = "fs_rcas";
export const FSR_STRETCH = "fs_stretch";

// The passes' labels (Metal System Trace keys its timings by them).
export const FSR_EASU_LABEL = "hedra fsr easu";
export const FSR_RCAS_LABEL = "hedra fsr rcas";
export const STRETCH_LABEL = "hedra stretch";

// post_fsr.wgsl's FsrU, and the group's bindings.
export const FSR_UNIFORM_SIZE: u32 = 48;
export const FSR_BLOCK_BINDING: u32 = 0;
export const FSR_SOURCE_BINDING: u32 = 1;
export const FSR_SAMPLER_BINDING: u32 = 2;

// RCAS's constant for Godot's fsr_sharpness (ffx's FsrRcasCon: stops of
// sharpness off the sharpest, as a factor), the sharpness clamped to 0..2
// (Godot's range).
export function rcasSharpness(sharpness: f32): f32 {
    const s = isFinite(sharpness) ? min<f32>(max<f32>(sharpness, 0), 2) : <f32>0.2;
    return <f32>Math.pow(2, -<f64>s);
}

// FsrU for an input `srcW` x `srcH` upscaled to `outW` x `outH` (ffx's
// FsrEasuCon con0) and RCAS's `sharpness`, into `dv` (allocates nothing).
export function fsrUniformInto(dv: DataView, srcW: u32, srcH: u32, outW: u32, outH: u32, sharpness: f32): void {
    const sx = <f32>srcW / <f32>max<u32>(outW, 1);
    const sy = <f32>srcH / <f32>max<u32>(outH, 1);
    dv.setFloat32(0, sx, true);
    dv.setFloat32(4, sy, true);
    dv.setFloat32(8, <f32>0.5 * sx - <f32>0.5, true);
    dv.setFloat32(12, <f32>0.5 * sy - <f32>0.5, true);
    dv.setFloat32(16, <f32>srcW, true);
    dv.setFloat32(20, <f32>srcH, true);
    dv.setFloat32(24, <f32>outW, true);
    dv.setFloat32(28, <f32>outH, true);
    dv.setFloat32(32, rcasSharpness(sharpness), true);
    dv.setFloat32(36, 0, true);
    dv.setFloat32(40, 0, true);
    dv.setFloat32(44, 0, true);
}

// An upscaled picture: the target's texture and view, of the output size.
export class FsrOutput {
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

// One pass's group and the view it binds.
class FsrDraw {
    group: GPUBindGroup? = null;
    source: GPUTextureView? = null;
}

export class FsrUpscaler {
    // How many upscales were drawn (FSR's and the stretch's; the tests read
    // them).
    fsrDraws: i32 = 0;
    stretchDraws: i32 = 0;
    private tried: bool = false;
    private ready: bool = false;
    private warned: bool = false;
    private layout: GPUBindGroupLayout? = null;
    private easu: GPUPipeline? = null;
    private rcas: GPUPipeline? = null;
    private stretch: GPUPipeline? = null;
    private sampler: GPUSampler? = null;
    private buffer: GPUBuffer? = null;
    // EASU's target (RCAS reads it) and the output (RCAS's, or the
    // stretch's), each of the output size.
    private mid: FsrOutput? = null;
    private out: FsrOutput? = null;
    private easuDraw: FsrDraw = new FsrDraw();
    private rcasDraw: FsrDraw = new FsrDraw();
    private stretchDraw: FsrDraw = new FsrDraw();
    // What a resize replaced, released at the next resize.
    private oldTextures: Array<GPUTexture> = [];
    private oldViews: Array<GPUTextureView> = [];
    private oldGroups: Array<GPUBindGroup> = [];
    private bytes: ArrayBuffer = new ArrayBuffer(<i32>FSR_UNIFORM_SIZE);
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

    // `src` (`srcW` x `srcH`, the finished picture, POST_FORMAT) upscaled
    // to `outW` x `outH`: by FSR 1.0 and sharpened by `sharpness` when
    // `mode` is SCALING_3D_FSR, else stretched bilinearly (the tools'
    // `render --render-scale` in the bilinear mode: a Scene3D stretches its
    // picture with Rive's own image filter instead, and sets no output
    // size); null when it is not drawn (the caller presents `src`), with a
    // warning pushed to `warnings` once.
    upscale(
        gpu: Gpu, src: GPUTextureView, srcW: u32, srcH: u32, outW: u32, outH: u32, mode: i32, sharpness: f32,
        warnings: Array<string>,
    ): FsrOutput? {
        if (outW == 0 || outH == 0 || srcW == 0 || srcH == 0) return null;
        if (!this.prepare(gpu)) return this.refuse(warnings);
        const fsr = mode == SCALING_3D_FSR;
        if (!this.sized(outW, outH, fsr)) return this.refuse(warnings);
        fsrUniformInto(this.dv, srcW, srcH, outW, outH, sharpness);
        this.buffer!.update(0, this.bytes, FSR_UNIFORM_SIZE);
        const out = this.out!;
        if (fsr) {
            const mid = this.mid!;
            const g0 = this.groupOf(this.easuDraw, src);
            const g1 = this.groupOf(this.rcasDraw, mid.view);
            if (g0 == null || g1 == null) return this.refuse(warnings);
            if (!this.pass(gpu, mid.view, this.easu!, g0, FSR_EASU_LABEL)) return this.refuse(warnings);
            if (!this.pass(gpu, out.view, this.rcas!, g1, FSR_RCAS_LABEL)) return this.refuse(warnings);
            this.fsrDraws++;
        } else {
            const g = this.groupOf(this.stretchDraw, src);
            if (g == null) return this.refuse(warnings);
            if (!this.pass(gpu, out.view, this.stretch!, g, STRETCH_LABEL)) return this.refuse(warnings);
            this.stretchDraws++;
        }
        return out;
    }

    // Its targets and pipelines released.
    release(): void {
        this.retire(this.mid);
        this.retire(this.out);
        this.mid = null;
        this.out = null;
        this.retireDraw(this.easuDraw);
        this.retireDraw(this.rcasDraw);
        this.retireDraw(this.stretchDraw);
        this.releaseOld();
        const a = this.easu;
        if (a != null) a.release();
        const b = this.rcas;
        if (b != null) b.release();
        const c = this.stretch;
        if (c != null) c.release();
        this.easu = null;
        this.rcas = null;
        this.stretch = null;
        const sm = this.sampler;
        if (sm != null) sm.release();
        this.sampler = null;
        const bf = this.buffer;
        if (bf != null) bf.release();
        this.buffer = null;
        this.layout = null;
        this.ready = false;
        this.tried = false;
    }

    // The warning, once; null.
    private refuse(warnings: Array<string>): FsrOutput? {
        if (!this.warned) {
            this.warned = true;
            warnings.push(FSR_PIPELINE_WARNING);
        }
        return null;
    }

    // The module's layout, its three pipelines, the sampler and the block,
    // made once; false when the program has no FSR_SHADER or the host
    // refuses any of them.
    private prepare(gpu: Gpu): bool {
        if (this.tried) return this.ready;
        this.tried = true;
        const mod = gpu.ctx.shader(shaderAsset(FSR_SHADER));
        if (mod == null) return false;
        const layout = GPUBindGroupLayout.fromShader(mod, 0);
        if (layout == null) return false;
        const easu = fsrPipeline(mod, layout, FSR_EASU);
        const rcas = fsrPipeline(mod, layout, FSR_RCAS);
        const stretch = fsrPipeline(mod, layout, FSR_STRETCH);
        const sampler = new GPUSampler(Filter.linear, Filter.linear, Filter.nearest, WrapMode.clampToEdge, WrapMode.clampToEdge);
        const buffer = new GPUBuffer(BufferUsage.uniform, FSR_UNIFORM_SIZE);
        if (easu.handle == 0 || rcas.handle == 0 || stretch.handle == 0 || sampler.handle == 0 || buffer.handle == 0) {
            if (easu.handle != 0) easu.release();
            if (rcas.handle != 0) rcas.release();
            if (stretch.handle != 0) stretch.release();
            if (sampler.handle != 0) sampler.release();
            if (buffer.handle != 0) buffer.release();
            return false;
        }
        this.layout = layout;
        this.easu = easu;
        this.rcas = rcas;
        this.stretch = stretch;
        this.sampler = sampler;
        this.buffer = buffer;
        this.ready = true;
        return true;
    }

    // The output target (and EASU's, for `fsr`) of `w` x `h`, kept or made;
    // false when the host refuses one.
    private sized(w: u32, h: u32, fsr: bool): bool {
        const out = this.out;
        const mid = this.mid;
        const outOk = out != null && out.width == w && out.height == h;
        const midOk = !fsr || mid != null && mid.width == w && mid.height == h;
        if (outOk && midOk) return true;
        // (what the resize before replaced is no longer presented)
        this.releaseOld();
        if (!outOk) {
            this.retire(out);
            this.retireDraw(this.rcasDraw);
            this.retireDraw(this.stretchDraw);
            const t = makeTarget(w, h);
            this.out = t;
            if (t == null) return false;
        }
        if (!midOk) {
            this.retire(mid);
            this.retireDraw(this.rcasDraw);
            const t = makeTarget(w, h);
            this.mid = t;
            if (t == null) return false;
        }
        return true;
    }

    private retire(t: FsrOutput?): void {
        if (t == null) return;
        this.oldViews.push(t.view);
        this.oldTextures.push(t.texture);
    }

    private retireDraw(d: FsrDraw): void {
        const g = d.group;
        if (g != null) this.oldGroups.push(g);
        d.group = null;
        d.source = null;
    }

    private releaseOld(): void {
        for (let i = 0; i < this.oldGroups.length; i++) this.oldGroups[i].release();
        for (let i = 0; i < this.oldViews.length; i++) this.oldViews[i].release();
        for (let i = 0; i < this.oldTextures.length; i++) this.oldTextures[i].release();
        this.oldGroups.length = 0;
        this.oldViews.length = 0;
        this.oldTextures.length = 0;
    }

    // Draw `d`'s group, kept while it binds the same view (the renderer's
    // pictures are kept targets: the same view from frame to frame).
    private groupOf(d: FsrDraw, source: GPUTextureView): GPUBindGroup? {
        const kept = d.group;
        if (kept != null && d.source === source) return kept;
        this.retireDraw(d);
        const g = new GPUBindGroup(
            this.layout!,
            [new GPUBindGroupUBO(FSR_BLOCK_BINDING, this.buffer!, 0, FSR_UNIFORM_SIZE)],
            [new GPUBindGroupTexture(FSR_SOURCE_BINDING, source)],
            [new GPUBindGroupSampler(FSR_SAMPLER_BINDING, this.sampler!)],
        );
        if (g.handle == 0) return null;
        d.group = g;
        d.source = source;
        return g;
    }

    // One full-screen draw of `pipeline` with `group` into `target`.
    private pass(gpu: Gpu, target: GPUTextureView, pipeline: GPUPipeline, group: GPUBindGroup, label: string): bool {
        this.colour.view = target;
        this.colour.resolveTarget = null;
        this.desc.label = label;
        this.desc.depthView = null;
        const pass = gpu.canvas.beginRenderPass(this.desc, this.passWrapper);
        if (pass.handle == 0) return false;
        pass.setPipeline(pipeline);
        // (GPURenderPass.setBindGroup's default offsets are a new array per
        // call: the binding itself, with none, as renderer.as `bindGroup`)
        abi.rive_gpu_pass_set_bind_group(pass.handle, 0, group.handle, 0, 0);
        pass.draw(3);
        pass.finish();
        return true;
    }
}

// A POST_FORMAT target of `w` x `h`, or null when the host refuses it.
function makeTarget(w: u32, h: u32): FsrOutput? {
    const d = new GPUTextureDesc();
    d.width = w;
    d.height = h;
    d.format = POST_FORMAT;
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
    return new FsrOutput(texture, view, w, h);
}

// One of the module's pipelines: the full-screen triangle, fragment entry
// `fs`, one POST_FORMAT target written as it is, no depth, one sample.
function fsrPipeline(mod: GPUShaderModule, layout: GPUBindGroupLayout, fs: string): GPUPipeline {
    const d = new GPUPipelineDesc();
    d.vertexModule = mod;
    d.vertexEntryPoint = FSR_VERTEX;
    d.fragmentModule = mod;
    d.fragmentEntryPoint = fs;
    const t = new GPUColorTargetDesc();
    t.format = POST_FORMAT;
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
