// Textures drawn on the GPU every frame and sampled by the materials
// (milestone 15: the artboard textures of a project the CLI's `build`
// writes). Their owner draws into a source view each frame (a Rive
// canvas's image view, which holds 8-bit sRGB-encoded colour with
// premultiplied alpha); `blit` copies it into a target the material
// binder binds (MaterialBinder.setLive), in the form the renderer's own
// textures have: a colour slot's (srgb) target is rgba16float holding
// linear colour, as uploadTexture makes an sRGB image (gpu/materials.as),
// a data slot's rgba8unorm as it is; both with straight alpha (the blit
// divides by alpha where it is above 0). One level, no mip chain: the
// material sampler's mipmap filter then reads level 0.
//
// The blit is one full-screen triangle of shaders/render/artboard_blit
// (vs_blit, fs_blit_srgb, fs_blit_linear), its group 0 the source view at
// binding 0 and a linear clamp sampler at binding 1. The source's row 0 is
// its top, as the targets' is: no flip (a Rive canvas image's view is
// sampled top row first; the milestone's experiment, docs/milestones/
// M15.md, shows it).
//
// A host without half-float render targets gets an rgba8unorm colour
// target holding linear colour (banding in the darks), and a warning.
//
// Nothing here allocates once a source and a target have been blitted
// together: the pass descriptor is the target's, the bind group the
// source's (both made on first use and kept), the pass wrapper and the
// group binding the blit's own (as renderer.as's passes do).
//
// Milestone 34: viewports (gpu/viewports.as) blit their pictures into
// targets of their own with `blitStraight`: the renderer's result holds
// straight alpha already (a transparent background's premultiplied
// resolve is divided by alpha in fs_post or fs_outline), so
// fs_blit_srgb_straight and
// fs_blit_linear_straight copy it without the division. Their pipelines
// are made on the first such blit and kept, so a project without a
// viewport asks the host for nothing more. A target keeps the group of the
// one source it is blitted from (a viewport's picture, the same view while
// its size is), compared by the view object and not its handle: a view
// released when the picture changed size could hand its handle number to
// the next; the group it replaces is released at `releaseRetired`.

import { abi } from "rive/bindings";
import {
    GPUBindGroup, GPUBindGroupLayout, GPUBindGroupSampler, GPUBindGroupTexture, GPUColorAttachment,
    GPUColorTargetDesc, GPUPassDesc, GPUPipeline, GPUPipelineDesc, GPURenderPass, GPUSampler, GPUShaderModule,
    GPUTexture, GPUTextureDesc, GPUTextureView,
} from "rive/gpu";
import { CullMode, Filter, LoadOp, PrimitiveTopology, StoreOp, TextureFormat, WrapMode } from "rive/gpu_enums";
import { Result } from "../../base/util";
import { srgbToLinear } from "../../base/color";
import { RenderError } from "../errors";
import { Gpu } from "./device";
import { COLOR_FORMAT, COLOR_FORMAT_FALLBACK } from "./layouts";
import { shaderAsset } from "./pipelines";

// The blit's shader asset (engine/src/shaders/render/artboard_blit.wgsl).
export const BLIT_SHADER = "shaders/render/artboard_blit";

// What the blit warns when the host has no half-float render targets.
export const LIVE_TEXTURE_8BIT_WARNING = "artboard textures are drawn into 8-bit targets: the host has no half-float render targets";

// The data targets' format: the bytes a data texture's PNG uploads as.
const DATA_FORMAT: TextureFormat = TextureFormat.rgba8unorm;

// One target: the texture, its view (what the binder binds), its size and
// form.
export class LiveTarget {
    texture: GPUTexture;
    view: GPUTextureView;
    width: u32;
    height: u32;
    srgb: bool;
    // The pass that draws into it, made by its first blit and kept.
    pass: GPUPassDesc? = null;
    // Milestone 34: the source `blitStraight` draws it from and the group
    // binding that source (LiveTextureBlit.blitStraight).
    source: GPUTextureView? = null;
    sourceGroup: GPUBindGroup? = null;

    constructor(texture: GPUTexture, view: GPUTextureView, width: u32, height: u32, srgb: bool) {
        this.texture = texture;
        this.view = view;
        this.width = width;
        this.height = height;
        this.srgb = srgb;
    }

    release(): void {
        const g = this.sourceGroup;
        if (g != null) g.release();
        this.sourceGroup = null;
        this.source = null;
        this.view.release();
        this.texture.release();
    }
}

// A source view and the group binding it, kept for the next blits of it.
class SourceGroup {
    view: GPUTextureView;
    group: GPUBindGroup;

    constructor(view: GPUTextureView, group: GPUBindGroup) {
        this.view = view;
        this.group = group;
    }
}

export class LiveTextureBlit {
    gpu: Gpu;
    // Raised by `create` (LIVE_TEXTURE_8BIT_WARNING); the owner reports it.
    warnings: Array<string> = [];
    // The colour targets' format: the renderer's main target format
    // (layouts.as COLOR_FORMAT, rgba16float), or its fallback when the host
    // has no half-float render targets (FrameRenderer.create's choice).
    colorFormat: TextureFormat = COLOR_FORMAT;
    private layout: GPUBindGroupLayout? = null;
    private sampler: GPUSampler? = null;
    private srgbPipeline: GPUPipeline? = null;
    private linearPipeline: GPUPipeline? = null;
    // The straight-alpha pipelines (`blitStraight`), made on first use;
    // `straightTried` set once that was tried, so a host that refused them
    // is not asked again.
    private module: GPUShaderModule? = null;
    private srgbStraight: GPUPipeline? = null;
    private linearStraight: GPUPipeline? = null;
    private straightTried: bool = false;
    private retiredGroups: Array<GPUBindGroup> = [];
    private groups: Array<SourceGroup> = [];
    private passWrapper: GPURenderPass = new GPURenderPass(0);

    constructor(gpu: Gpu) {
        this.gpu = gpu;
    }

    // The blit's pipelines on `gpu`; fails when the project has no
    // BLIT_SHADER or the host rejects a pipeline (the owner then draws its
    // placeholders, saying why).
    static create(gpu: Gpu): Result<LiveTextureBlit> {
        const mod = gpu.ctx.shader(shaderAsset(BLIT_SHADER));
        if (mod == null) {
            return RenderError.device("shader asset '" + shaderAsset(BLIT_SHADER)
                + "' not found (is shaders/render/ in the project?): artboard textures are drawn as placeholders")
                .fail<LiveTextureBlit>();
        }
        const layout = GPUBindGroupLayout.fromShader(mod, 0);
        if (layout == null) {
            return RenderError.device("the host rejected the artboard blit's bind group layout").fail<LiveTextureBlit>();
        }
        const b = new LiveTextureBlit(gpu);
        if (!gpu.features.colorBufferHalfFloat) {
            b.colorFormat = COLOR_FORMAT_FALLBACK;
            b.warnings.push(LIVE_TEXTURE_8BIT_WARNING);
        }
        const srgb = blitPipeline(mod, layout, "fs_blit_srgb", b.colorFormat);
        const linear = blitPipeline(mod, layout, "fs_blit_linear", DATA_FORMAT);
        const sampler = new GPUSampler(
            Filter.linear, Filter.linear, Filter.nearest, WrapMode.clampToEdge, WrapMode.clampToEdge);
        if (srgb.handle == 0 || linear.handle == 0 || sampler.handle == 0) {
            if (srgb.handle != 0) srgb.release();
            if (linear.handle != 0) linear.release();
            if (sampler.handle != 0) sampler.release();
            return RenderError.device("the host rejected the artboard blit's pipelines").fail<LiveTextureBlit>();
        }
        b.module = mod;
        b.layout = layout;
        b.sampler = sampler;
        b.srgbPipeline = srgb;
        b.linearPipeline = linear;
        return Result.okv<LiveTextureBlit>(b);
    }

    // A target of `width` x `height` (each 1 or more) for a colour slot
    // (`srgb`) or a data slot; null when the host refuses the texture.
    target(width: u32, height: u32, srgb: bool): LiveTarget? {
        const d = new GPUTextureDesc();
        d.width = max<u32>(width, 1);
        d.height = max<u32>(height, 1);
        d.format = srgb ? this.colorFormat : DATA_FORMAT;
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
        return new LiveTarget(texture, view, d.width, d.height, srgb);
    }

    // Draws `source` into `into`, filling it (bilinear when the sizes
    // differ), in a render pass of its own on the renderer's GPU canvas.
    blit(source: GPUTextureView, into: LiveTarget): void {
        const pipeline = into.srgb ? this.srgbPipeline : this.linearPipeline;
        if (pipeline == null) return;
        const group = this.groupOf(source);
        if (group == null) return;
        const pass = this.gpu.canvas.beginRenderPass(this.passOf(into), this.passWrapper);
        pass.setPipeline(pipeline);
        // GPURenderPass.setBindGroup's default offsets are a new array per
        // call: the binding itself, with none (renderer.as `bindGroup`).
        abi.rive_gpu_pass_set_bind_group(pass.handle, 0, group.handle, 0, 0);
        pass.draw(3);
        pass.finish();
    }

    // Draws `source`, which holds straight alpha (a viewport's picture:
    // 8-bit sRGB-encoded colour, as a CPU Image), into `into` the way
    // `blit` does without undoing a premultiplication: a colour target
    // gets the sRGB curve decoded, a data target the values as they are.
    // False when the host refused the pipelines (asked once) or the group.
    blitStraight(source: GPUTextureView, into: LiveTarget): bool {
        if (!this.straightTried) {
            this.straightTried = true;
            const mod = this.module;
            const layout = this.layout;
            if (mod != null && layout != null) {
                const srgb = blitPipeline(mod, layout, "fs_blit_srgb_straight", this.colorFormat);
                const linear = blitPipeline(mod, layout, "fs_blit_linear_straight", DATA_FORMAT);
                if (srgb.handle != 0 && linear.handle != 0) {
                    this.srgbStraight = srgb;
                    this.linearStraight = linear;
                } else {
                    if (srgb.handle != 0) srgb.release();
                    if (linear.handle != 0) linear.release();
                }
            }
        }
        const pipeline = into.srgb ? this.srgbStraight : this.linearStraight;
        if (pipeline == null) return false;
        let group = into.sourceGroup;
        if (group == null || into.source !== source) {
            if (group != null) this.retiredGroups.push(group);
            into.sourceGroup = null;
            into.source = null;
            const layout = this.layout;
            const sampler = this.sampler;
            if (layout == null || sampler == null) return false;
            const g = new GPUBindGroup(layout, [], [new GPUBindGroupTexture(0, source)], [new GPUBindGroupSampler(1, sampler)]);
            if (g.handle == 0) return false;
            into.sourceGroup = g;
            into.source = source;
            group = g;
        }
        const pass = this.gpu.canvas.beginRenderPass(this.passOf(into), this.passWrapper);
        pass.setPipeline(pipeline);
        abi.rive_gpu_pass_set_bind_group(pass.handle, 0, group.handle, 0, 0);
        pass.draw(3);
        pass.finish();
        return true;
    }

    // Releases the groups `blitStraight` replaced (call once the passes
    // that bound them are recorded: at the owner's next frame).
    releaseRetired(): void {
        for (let i = 0; i < this.retiredGroups.length; i++) this.retiredGroups[i].release();
        this.retiredGroups.length = 0;
    }

    // The pass that draws into `into`, made on its first blit and kept.
    private passOf(into: LiveTarget): GPUPassDesc {
        let desc = into.pass;
        if (desc == null) {
            const a = new GPUColorAttachment();
            a.view = into.view;
            // Every texel is written: the clear only spares the host a load.
            a.loadOp = LoadOp.clear;
            a.storeOp = StoreOp.store;
            a.clearR = 0;
            a.clearG = 0;
            a.clearB = 0;
            a.clearA = 0;
            desc = new GPUPassDesc();
            desc.color = [a];
            desc.label = "hedra live texture";
            into.pass = desc;
        }
        return desc;
    }

    // The group binding `source`, made on its first blit.
    private groupOf(source: GPUTextureView): GPUBindGroup? {
        for (let i = 0; i < this.groups.length; i++) {
            if (this.groups[i].view.handle == source.handle) return this.groups[i].group;
        }
        const layout = this.layout;
        const sampler = this.sampler;
        if (layout == null || sampler == null) return null;
        const g = new GPUBindGroup(layout, [], [new GPUBindGroupTexture(0, source)], [new GPUBindGroupSampler(1, sampler)]);
        if (g.handle == 0) return null;
        this.groups.push(new SourceGroup(source, g));
        return g;
    }

    // Releases the pipelines and the groups (the targets are their
    // owner's).
    release(): void {
        for (let i = 0; i < this.groups.length; i++) this.groups[i].group.release();
        this.groups.length = 0;
        this.releaseRetired();
        const ss = this.srgbStraight;
        if (ss != null) ss.release();
        const ls = this.linearStraight;
        if (ls != null) ls.release();
        this.srgbStraight = null;
        this.linearStraight = null;
        const s = this.srgbPipeline;
        if (s != null) s.release();
        const l = this.linearPipeline;
        if (l != null) l.release();
        const sm = this.sampler;
        if (sm != null) sm.release();
        this.srgbPipeline = null;
        this.linearPipeline = null;
        this.sampler = null;
    }
}

// One blit pipeline: the full-screen triangle into one `format` target,
// no blending (the source replaces the target), no depth, one sample.
function blitPipeline(mod: GPUShaderModule, layout: GPUBindGroupLayout, fs: string, format: TextureFormat): GPUPipeline {
    const d = new GPUPipelineDesc();
    d.vertexModule = mod;
    d.vertexEntryPoint = "vs_blit";
    d.fragmentModule = mod;
    d.fragmentEntryPoint = fs;
    const t = new GPUColorTargetDesc();
    t.format = format;
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

// What fs_blit_srgb writes for a source texel (r, g, b, a), each 0..1:
// straight alpha (rgb / a, at most 1, where a > 0; 0 where nothing
// covers), then the exact sRGB curve on colour, alpha unchanged. The
// shader's mirror, for the tests (the GPU's result differs in rounding
// only).
export function blitSrgbReference(r: f32, g: f32, b: f32, a: f32): StaticArray<f32> {
    const s = blitLinearReference(r, g, b, a);
    s[0] = srgbToLinear(s[0]);
    s[1] = srgbToLinear(s[1]);
    s[2] = srgbToLinear(s[2]);
    return s;
}

// What fs_blit_linear writes: straight alpha only.
export function blitLinearReference(r: f32, g: f32, b: f32, a: f32): StaticArray<f32> {
    const out = new StaticArray<f32>(4);
    if (a > 0) {
        out[0] = min<f32>(r / a, 1);
        out[1] = min<f32>(g / a, 1);
        out[2] = min<f32>(b / a, 1);
        out[3] = a;
    }
    return out;
}

// What fs_blit_srgb_straight writes for a source texel (r, g, b, a), each
// 0..1, of a straight-alpha picture: the exact sRGB curve on colour, alpha
// unchanged (no division: a texel a transparent background leaves partly
// covered keeps its colour). The shader's mirror, for the tests.
export function blitStraightSrgbReference(r: f32, g: f32, b: f32, a: f32): StaticArray<f32> {
    const out = new StaticArray<f32>(4);
    out[0] = srgbToLinear(r);
    out[1] = srgbToLinear(g);
    out[2] = srgbToLinear(b);
    out[3] = a;
    return out;
}

// What fs_blit_linear_straight writes: the texel as it is.
export function blitStraightLinearReference(r: f32, g: f32, b: f32, a: f32): StaticArray<f32> {
    const out = new StaticArray<f32>(4);
    out[0] = r;
    out[1] = g;
    out[2] = b;
    out[3] = a;
    return out;
}
