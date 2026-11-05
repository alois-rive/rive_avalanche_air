// Milestone 62: the screen texture on the GPU (Godot's screen texture: the
// copy of the opaque picture that refracting glass and the screen-space
// reflections read; ../screen.as says what they are,
// docs/engine/SCREEN_EFFECTS.md how they are drawn). The renderer
// (./renderer.as drawView) asks, for a view whose plan splits its main pass
// (post.as PostPlan `split`):
//
//   prepare(gpu, slot, pxW, pxH, levels, warnings)  before the view's object
//       groups are made: the view of the slot's texture (SCREEN_FORMAT,
//       `pxW` x `pxH`, `levels` mips, all of them), which every object group
//       of the view binds at SCREEN_BINDING; null (SCREEN_PIPELINE_WARNING
//       pushed) when the host refuses the module, its pipelines or the
//       texture, and the view is then drawn unsplit (post.as dropSplit);
//   draw(gpu, slot, source, pxW, pxH, levels, warnings)  between the main
//       pass's two halves: shaders/render/post_screen.wgsl's fs_screen_copy
//       from `source` (the first half's resolved colour) into level 0, then
//       fs_screen_down into each level 1 .. levels - 1, one pass a level
//       (as the glow's levels are drawn into one texture's mips); the same
//       view as `prepare`'s, or null as it says;
//   canExpand(gpu, samples)  before the main pass's first half: whether
//       `expand` can draw into a second half of `samples` samples (its
//       pipeline made on first use; a host that refuses it is never asked
//       again), so that the first half need not store its MSAA colour;
//   expand(pass, slot)  first in the main pass's second half: level 0 (the
//       first half's resolved colour, texel for texel) written to every
//       sample of each pixel, fs_screen_copy through a pipeline of the
//       main pass's samples, its depth compared always and not written.
//       The first half then resolves its colour and discards its samples
//       (what the one pass does) instead of storing and loading them again
//       (some 66 MB each way at 1920 x 1080, 4 samples of rgba16float: most
//       of the split's cost, measured): a pixel nothing is drawn over in
//       the second half resolves to the very value it had, and one the
//       glass or a blended surface is drawn over blends over its resolved
//       colour, which is the mean of what it blended over each sample (the
//       blend is linear) but at the edges where a blended surface ends on
//       an opaque one's;
//
// Each slot (ViewBuffers.customId) keeps its texture, its views and its
// passes' groups from frame to frame: a view drawn again at the same size
// allocates nothing. A texture replaced by a new size, and the groups that
// bound the old one, are released at the next `beginFrame`, once the
// passes recorded with them have run; so is everything of a slot no view
// prepared for ./ssr.as SCREEN_SLOT_IDLE_FRAMES frames (the demo's player
// out of the room with the mirror floor, the reflections and refraction
// turned off, a SubViewport no longer drawn), as the reflections' and the
// depth of field's slots are: the texture is the picture's size in
// rgba16float with its mips, some 22 MB at 1080p.

import {
    GPUBindGroup, GPUBindGroupLayout, GPUBindGroupTexture, GPUColorAttachment, GPUColorTargetDesc,
    GPUDepthStencilDesc, GPUPassDesc, GPUPipeline, GPUPipelineDesc, GPURenderPass, GPUShaderModule, GPUTexture,
    GPUTextureDesc, GPUTextureView, GPUTextureViewDesc,
} from "rive/gpu";
import { CompareFunction, CullMode, LoadOp, PrimitiveTopology, StoreOp, TextureFormat } from "rive/gpu_enums";
import { abi } from "rive/bindings";
import { Gpu } from "./device";
import { COLOR_FORMAT, DEPTH_FORMAT, SCREEN_FORMAT } from "./layouts";
import { fullScreenPipeline, shaderAsset } from "./pipelines";
import { SCREEN_SLOT_IDLE_FRAMES } from "./ssr";

// The screen texture's shader asset (engine/src/shaders/render/post_screen.wgsl).
export const SCREEN_SHADER = "shaders/render/post_screen";
// Its entry points.
export const SCREEN_VERTEX_ENTRY = "vs_screen";
export const SCREEN_COPY_ENTRY = "fs_screen_copy";
export const SCREEN_DOWN_ENTRY = "fs_screen_down";

// What the renderer's warnings say when the host refuses the screen
// texture's module, pipelines or texture: the view's main pass is then
// drawn in one, without reflections, and its glass refracts the
// environment.
export const SCREEN_PIPELINE_WARNING =
    "screen-space reflections and refraction are not drawn: the host refused the screen texture's pipelines";

// One view slot's screen texture: the texture, the view of all its mips
// (what the object groups bind), a view of each mip alone (what each pass
// draws into, and the next one reads), and the group of each pass (level
// 0's binds the source it was made with).
class ScreenSlot {
    slot: i32;
    texture: GPUTexture;
    view: GPUTextureView;
    width: u32;
    height: u32;
    mips: i32;
    levels: Array<GPUTextureView>;
    groups: Array<GPUBindGroup?> = [];
    source: GPUTextureView? = null;
    // The expand's group (level 0), made on its first use.
    expandGroup: GPUBindGroup? = null;
    // The chain's frame the slot was last prepared in.
    used: i32 = 0;

    constructor(slot: i32, texture: GPUTexture, view: GPUTextureView, width: u32, height: u32, mips: i32,
        levels: Array<GPUTextureView>) {
        this.slot = slot;
        this.texture = texture;
        this.view = view;
        this.width = width;
        this.height = height;
        this.mips = mips;
        this.levels = levels;
        for (let i = 0; i < mips; i++) this.groups.push(null);
    }
}

// The size of mip `m` of a side `px` (WebGPU's: halved, rounded down, at
// least 1).
export function screenMipSide(px: u32, m: i32): u32 {
    return max<u32>(px >> <u32>m, 1);
}

export class GpuScreenChain {
    private tried: bool = false;
    private layout: GPUBindGroupLayout? = null;
    private copy: GPUPipeline? = null;
    private down: GPUPipeline? = null;
    private module: GPUShaderModule? = null;
    // The expand's pipelines by sample count, and the counts a host
    // refused.
    private expandSamples: Array<u32> = [];
    private expandPipelines: Array<GPUPipeline> = [];
    private expandRefused: Array<u32> = [];
    private slots: Array<ScreenSlot> = [];
    private frame: i32 = 0;
    private retiredTextures: Array<GPUTexture> = [];
    private retiredViews: Array<GPUTextureView> = [];
    private retiredGroups: Array<GPUBindGroup> = [];
    private color: GPUColorAttachment = new GPUColorAttachment();
    private desc: GPUPassDesc = new GPUPassDesc();
    private passWrapper: GPURenderPass = new GPURenderPass(0);
    // The passes the last `draw` ran (RenderStats.screenPasses).
    lastPasses: i32 = 0;

    constructor() {
        this.desc.color = [this.color];
    }

    // Starts a host frame: what a size change replaced is released, and the
    // slots no view prepared for SCREEN_SLOT_IDLE_FRAMES frames are retired
    // (released at the next one, after this frame's passes).
    beginFrame(): void {
        this.frame++;
        for (let i = 0; i < this.retiredGroups.length; i++) this.retiredGroups[i].release();
        for (let i = 0; i < this.retiredViews.length; i++) this.retiredViews[i].release();
        for (let i = 0; i < this.retiredTextures.length; i++) this.retiredTextures[i].release();
        this.retiredGroups.length = 0;
        this.retiredViews.length = 0;
        this.retiredTextures.length = 0;
        // (swapped with the last and popped: in place, nothing allocated)
        const slots = this.slots;
        for (let i = slots.length - 1; i >= 0; i--) {
            const e = unchecked(slots[i]);
            if (this.frame - e.used <= SCREEN_SLOT_IDLE_FRAMES) continue;
            this.retire(e);
            const last = slots.length - 1;
            if (i != last) slots[i] = unchecked(slots[last]);
            slots.pop();
        }
    }

    // How many view slots hold a screen texture (the tests read it).
    slotCount(): i32 {
        return this.slots.length;
    }

    // Whether the pipelines are there, made on the first call (a host that
    // refuses one is never asked again).
    private ready(gpu: Gpu): bool {
        if (this.tried) return this.copy != null;
        this.tried = true;
        const mod = gpu.ctx.shader(shaderAsset(SCREEN_SHADER));
        if (mod == null) return false;
        const layout = GPUBindGroupLayout.fromShader(mod, 0);
        if (layout == null) return false;
        const copy = fullScreenPipeline(mod, layout, SCREEN_VERTEX_ENTRY, SCREEN_COPY_ENTRY, SCREEN_FORMAT);
        const down = fullScreenPipeline(mod, layout, SCREEN_VERTEX_ENTRY, SCREEN_DOWN_ENTRY, SCREEN_FORMAT);
        if (copy.handle == 0 || down.handle == 0) {
            if (copy.handle != 0) copy.release();
            if (down.handle != 0) down.release();
            return false;
        }
        this.layout = layout;
        this.module = mod;
        this.copy = copy;
        this.down = down;
        return true;
    }

    // The expand's pipeline for `samples` samples (see the header), made
    // on first use; null when the host refuses it (never asked again).
    // Milestone 67: of the main pass's colour format `format` (quality.as),
    // kept by samples | format << 8.
    private expandPipeline(gpu: Gpu, samples: u32, format: TextureFormat = COLOR_FORMAT): GPUPipeline? {
        const keyed = samples | (<u32>format << 8);
        for (let i = 0; i < this.expandSamples.length; i++) {
            if (unchecked(this.expandSamples[i]) == keyed) return unchecked(this.expandPipelines[i]);
        }
        if (this.expandRefused.includes(keyed) || !this.ready(gpu)) return null;
        const d = new GPUPipelineDesc();
        d.vertexModule = this.module!;
        d.vertexEntryPoint = SCREEN_VERTEX_ENTRY;
        d.fragmentModule = this.module!;
        d.fragmentEntryPoint = SCREEN_COPY_ENTRY;
        const t = new GPUColorTargetDesc();
        t.format = format;
        t.blend = null;
        d.colorTargets = [t];
        d.vertexBuffers = [];
        const layouts: Array<GPUBindGroupLayout?> = [this.layout!];
        d.bindGroupLayouts = layouts;
        d.topology = PrimitiveTopology.triangleList;
        d.cullMode = CullMode.none;
        const ds = new GPUDepthStencilDesc();
        ds.format = DEPTH_FORMAT;
        ds.compare = CompareFunction.always;
        ds.write = false;
        ds.depthBias = 0;
        ds.depthBiasSlopeScale = 0;
        ds.depthBiasClamp = 0;
        d.depthStencil = ds;
        d.sampleCount = samples;
        const p = new GPUPipeline(d);
        if (p.handle == 0) {
            this.expandRefused.push(keyed);
            return null;
        }
        this.expandSamples.push(keyed);
        this.expandPipelines.push(p);
        return p;
    }

    // Whether `expand` can draw into a second half of `samples` samples
    // (see the header). Allocates nothing once its pipeline is made.
    canExpand(gpu: Gpu, samples: u32, format: TextureFormat = COLOR_FORMAT): bool {
        return samples > 1 && this.expandPipeline(gpu, samples, format) != null;
    }

    // Writes slot `slot`'s level 0 to every sample of `pass` (see the
    // header): false when there is nothing to write (no texture drawn for
    // the slot, a refused pipeline or group). The caller binds its own
    // pipeline again after it.
    expand(gpu: Gpu, pass: GPURenderPass, slot: i32, samples: u32, format: TextureFormat = COLOR_FORMAT): bool {
        let e: ScreenSlot? = null;
        for (let i = 0; i < this.slots.length; i++) {
            if (unchecked(this.slots[i]).slot == slot) e = unchecked(this.slots[i]);
        }
        const layout = this.layout;
        const p = this.expandPipeline(gpu, samples, format);
        if (e == null || layout == null || p == null) return false;
        let g = e.expandGroup;
        if (g == null) {
            g = new GPUBindGroup(layout, [], [new GPUBindGroupTexture(0, unchecked(e.levels[0]))]);
            if (g.handle == 0) return false;
            e.expandGroup = g;
        }
        pass.setPipeline(p);
        abi.rive_gpu_pass_set_bind_group(pass.handle, 0, g.handle, 0, 0);
        pass.draw(3);
        return true;
    }

    // The slot's entry at `pxW` x `pxH` with `levels` mips: kept, or made
    // (replacing one of another size); null when the host refuses the
    // texture.
    private entry(slot: i32, pxW: u32, pxH: u32, levels: i32): ScreenSlot? {
        let at = -1;
        const slots = this.slots;
        for (let i = 0; i < slots.length; i++) {
            if (unchecked(slots[i]).slot == slot) {
                at = i;
                break;
            }
        }
        if (at >= 0) {
            const e = unchecked(slots[at]);
            if (e.width == pxW && e.height == pxH && e.mips == levels) return e;
            this.retire(e);
        }
        const d = new GPUTextureDesc();
        d.width = pxW;
        d.height = pxH;
        d.format = SCREEN_FORMAT;
        d.sampleCount = 1;
        d.renderTarget = true;
        d.numMipmaps = <u32>levels;
        const texture = new GPUTexture(d);
        if (texture.handle == 0) {
            if (at >= 0) slots.splice(at, 1);
            return null;
        }
        const view = texture.view();
        const mips = new Array<GPUTextureView>();
        for (let m = 0; m < levels; m++) {
            const vd = new GPUTextureViewDesc();
            vd.baseMipLevel = <u32>m;
            vd.mipCount = 1;
            mips.push(texture.view(vd));
        }
        const made = new ScreenSlot(slot, texture, view, pxW, pxH, levels, mips);
        if (at >= 0) slots[at] = made;
        else slots.push(made);
        return made;
    }

    private retire(e: ScreenSlot): void {
        for (let i = 0; i < e.groups.length; i++) {
            const g = e.groups[i];
            if (g != null) this.retiredGroups.push(g);
        }
        const xg = e.expandGroup;
        if (xg != null) this.retiredGroups.push(xg);
        e.expandGroup = null;
        for (let i = 0; i < e.levels.length; i++) this.retiredViews.push(e.levels[i]);
        this.retiredViews.push(e.view);
        this.retiredTextures.push(e.texture);
    }

    // The view of slot `slot`'s screen texture (see the header), made as
    // needed; null, with SCREEN_PIPELINE_WARNING, when the host refuses it.
    prepare(gpu: Gpu, slot: i32, pxW: u32, pxH: u32, levels: i32, warnings: Array<string>): GPUTextureView? {
        if (levels < 1 || !this.ready(gpu)) {
            warnings.push(SCREEN_PIPELINE_WARNING);
            return null;
        }
        const e = this.entry(slot, pxW, pxH, levels);
        if (e == null) {
            warnings.push(SCREEN_PIPELINE_WARNING);
            return null;
        }
        e.used = this.frame;
        return e.view;
    }

    // The screen texture of slot `slot` drawn from `source` (see the
    // header): its view, or null as `prepare` says.
    draw(gpu: Gpu, slot: i32, source: GPUTextureView, pxW: u32, pxH: u32, levels: i32, warnings: Array<string>,
    ): GPUTextureView? {
        this.lastPasses = 0;
        const view = this.prepare(gpu, slot, pxW, pxH, levels, warnings);
        const e = this.entry(slot, pxW, pxH, levels);
        const layout = this.layout;
        const copy = this.copy;
        const down = this.down;
        if (view == null || e == null || layout == null || copy == null || down == null) return null;
        for (let m = 0; m < levels; m++) {
            const src = m == 0 ? source : unchecked(e.levels[m - 1]);
            let g = unchecked(e.groups[m]);
            if (g == null || (m == 0 && e.source !== source)) {
                if (g != null) this.retiredGroups.push(g);
                g = new GPUBindGroup(layout, [], [new GPUBindGroupTexture(0, src)]);
                e.groups[m] = g;
                if (m == 0) e.source = source;
            }
            const c = this.color;
            c.view = unchecked(e.levels[m]);
            c.resolveTarget = null;
            c.loadOp = LoadOp.clear;
            c.storeOp = StoreOp.store;
            c.clearR = 0;
            c.clearG = 0;
            c.clearB = 0;
            c.clearA = 0;
            this.desc.label = "hedra screen texture";
            const pass = gpu.canvas.beginRenderPass(this.desc, this.passWrapper);
            pass.setPipeline(m == 0 ? copy : down);
            // (through the host binding: GPURenderPass.setBindGroup packs
            // its offsets into a new buffer every call)
            abi.rive_gpu_pass_set_bind_group(pass.handle, 0, g.handle, 0, 0);
            pass.draw(3);
            pass.finish();
            this.lastPasses++;
        }
        return view;
    }
}
