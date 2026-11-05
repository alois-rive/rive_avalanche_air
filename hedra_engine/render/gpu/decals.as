// Decals on the GPU (milestone 33; engine/src/render/decal.as says how a
// frame carries them, decal_select.as which ones each item paints): the
// atlas their textures live in, and the frame's decal block.
//
// The atlas is one 2D array texture (layouts.as DECAL_ATLAS_FORMAT,
// rgba8unorm, renderable), DECAL_LAYER_SIZE texels square with
// DECAL_LEVELS levels, a layer per distinct texture of the frame's decals
// (keyed by its path and slot form, as the material binder keys it:
// texKey; DecalLayerKeys), in the order first met, grown by powers of two
// (1, 2, 4, 8, 16) up to DECAL_MAX_LAYERS; a texture past them is left out
// of its decal, with DECAL_ATLAS_FULL_WARNING. Every decal of the frame
// counts, not only the pool's: a camera that moves never resolves or draws
// anything new. A texture is resolved through the frame renderer's
// MaterialBinder (`texture`: a file decoded and uploaded once, a processed
// form, an ArtboardTexture's placeholder, or a live view set by the
// player), only when the frame's decals (the array, their paths) or the
// binder's live views changed, and drawn into its layer by a blit
// (shaders/render/decal_blit.wgsl): a colour slot sRGB-encoded (a linear
// rgba16float upload or live target: fs_decal_encode; a compressed form
// uploaded as stored, which holds the file's sRGB bytes, copied), a data
// slot as it is (fs_decal_copy). A static layer is drawn once, every
// level from the source's own chain; a live layer (the binder's `live`
// view) again every host frame, its level 0 alone, which the shader
// samples it at (its decal's DECAL_LIVE_* bit). The object group (group 1)
// binds `view` at layouts.as DECAL_ATLAS_BINDING and `sampler` at
// DECAL_SAMPLER_BINDING; `generation` moves whenever `view` does, so the
// renderer remakes its object groups (FrameRenderer.uploadObjects).
//
// The block (layouts.as DecalUniform, group 1, DECAL_BLOCK_BINDING): the
// pool's entries (decal.as DecalDesc with the plan's distance fade and the
// layers: fillDecalUniform), and the lod header from the frame's camera. A
// frame without decals writes it as zeros once and binds the 1 x 1 x 1
// dummy atlas, so it draws as before.
//
// A host that refuses the atlas or the blit's pipelines draws no decal and
// raises DECAL_ATLAS_WARNING or DECAL_BLIT_WARNING once. One that refuses
// a render into one layer and level of the array (the view, its group or
// its pass) gets the static layers composed on the CPU (material.as
// resampleBilinear and mipChain, uploaded as the extension arrays are) and
// the live ones as their placeholder, raising DECAL_CPU_WARNING. These and
// DECAL_ATLAS_FULL_WARNING go to FrameRenderer.warnings, for a host that
// reads them (takeWarnings); the tools and the run time drop them, as they
// drop the shadow and probe atlases' (SceneRenderer.present), so a full
// atlas is reported by the checks (decal-atlas-full) instead.
//
// Nothing here allocates once the atlas holds the frame's textures: the
// plan, the uniform, the bytes, the views, the pass descriptors and the
// bind groups are made once and kept (the editor's and the demo's soaks
// hold every frame to 0 bytes).

import { abi } from "rive/bindings";
import {
    GPUBindGroup, GPUBindGroupLayout, GPUBindGroupSampler, GPUBindGroupTexture, GPUBindGroupUBO, GPUBuffer,
    GPUColorAttachment, GPUColorTargetDesc, GPUPassDesc, GPUPipeline, GPUPipelineDesc, GPURenderPass, GPUSampler,
    GPUShaderModule, GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc,
} from "rive/gpu";
import {
    BufferUsage, CullMode, Filter, LoadOp, PrimitiveTopology, StoreOp, TextureType, TextureViewDimension, WrapMode,
} from "rive/gpu_enums";
import { Vec4, log2f, powf, toRadians } from "../../base/vecmath";
import { appleTanf } from "../../base/libm";
import { Image, Rgba } from "../image";
import { MaterialBinder, mipChain, resampleBilinear, texKey } from "../material";
import { RenderFrame } from "../frame";
import { ProjectionKind } from "../camera";
import {
    DECAL_LAYER_SIZE, DECAL_LEVELS, DECAL_MAX_LAYERS, DECAL_TEXTURES, DECAL_TEXTURE_NORMAL, DecalDesc, DecalPlan,
    decalSlotIsSrgb,
} from "../decal";
import { clearItemDecals, prepareDecals } from "../decal_select";
import {
    DECAL_ATLAS_FORMAT, DECAL_LIVE_ALBEDO, DECAL_LIVE_EMISSION, DECAL_LIVE_NORMAL, DECAL_LIVE_ORM, DECAL_UNIFORM_SIZE,
    DecalUniform, U32x4,
} from "./layouts";
import { levelBytes } from "./materials";
import { shaderAsset } from "./pipelines";
import { Gpu } from "./device";
import { uploadRegion } from "./upload";

// What the renderer says when the atlas cannot hold a frame's textures, or
// the host refuses it or the blit (the decals are then drawn without the
// textures it could not hold), or a render into one of its layers.
export const DECAL_ATLAS_FULL_WARNING = "decals: more textures than the atlas holds; the last ones are not drawn";
export const DECAL_ATLAS_WARNING = "decals: the host refused the decal atlas; decals are not drawn";
export const DECAL_BLIT_WARNING = "decals: the host refused the decal blit's pipelines; decals are not drawn";
export const DECAL_CPU_WARNING = "decals: the host cannot draw into a layer of the decal atlas; its textures are composed on the CPU and artboard textures show their placeholder";

// The blit's shader asset (engine/src/shaders/render/decal_blit.wgsl) and
// its entry points.
export const DECAL_BLIT_SHADER = "shaders/render/decal_blit";
export const DECAL_BLIT_VERTEX = "vs_decal_blit";
export const DECAL_BLIT_COPY = "fs_decal_copy";
export const DECAL_BLIT_ENCODE = "fs_decal_encode";
// The blit's level block (decal_blit.wgsl's DecalBlitU: x the target's
// level) and its binding in group 0.
export const DECAL_BLIT_UNIFORM_SIZE: u32 = 16;
export const DECAL_BLIT_LEVEL_BINDING: u32 = 2;

// The atlas's layer count for `layers` textures: the least power of two
// that holds them (1 at least), at most DECAL_MAX_LAYERS.
export function decalAtlasCapacity(layers: i32): i32 {
    let c = 1;
    while (c < layers && c < DECAL_MAX_LAYERS) c <<= 1;
    return c;
}

// Whether a layer's blit encodes (fs_decal_encode) rather than copies: a
// colour slot whose source holds linear colour (an uploaded texture, a
// live colour target), not one sampled as stored (`srgbInShader`: a
// compressed form, holding the file's sRGB bytes).
export function decalBlitEncodes(srgb: bool, srgbInShader: bool, live: bool): bool {
    return srgb && (live || !srgbInShader);
}

// What fs_decal_encode writes for a linear channel: clamped to 0..1, the
// exact sRGB curve (engine/src/base/color.as linearToSrgb, which the
// surface shader's srgb_to_linear inverts). The shader's mirror.
export function decalEncodeReference(c: f32): f32 {
    const x = c < 0 ? <f32>0 : c > 1 ? <f32>1 : c;
    if (x <= <f32>0.0031308) return x * <f32>12.92;
    return <f32>1.055 * powf(x, <f32>1.0 / <f32>2.4) - <f32>0.055;
}

// The level the blit reads a source whose larger side is `side` texels at
// for the target's `level`: level + log2(side / DECAL_LAYER_SIZE), never
// under 0. The shader's mirror.
export function decalSourceLevel(level: u32, side: u32): f32 {
    const l = <f32>level + log2f(<f32>max<u32>(side, 1) / <f32>DECAL_LAYER_SIZE);
    return l > 0 ? l : 0;
}

// The atlas's layers for a frame's decals, on the CPU (the tests read it
// without a device): one per distinct (path, colour or data) in the order
// first met, each decal's slots mapped to their layer.
export class DecalLayerKeys {
    // By layer: its texKey, the path as the first decal names it, whether
    // it is a colour layer, and the slot that met it first.
    keys: Array<string> = [];
    paths: Array<string> = [];
    srgb: Array<bool> = [];
    slot: Array<i32> = [];
    // By decal and slot (decal * DECAL_TEXTURES + slot): the layer, -1 for
    // none (no texture, or one past DECAL_MAX_LAYERS).
    slots: Array<i32> = [];
    // Whether a texture was left out (DECAL_ATLAS_FULL_WARNING).
    full: bool = false;
    // The decals and paths last planned, to tell a frame refreshed in place
    // (nothing to plan again) from a new one.
    private from: Array<DecalDesc>? = null;
    private planned: Array<string?> = [];

    // Whether `decals` is what was planned last: the same array, its descs
    // naming the same paths (allocates nothing).
    same(decals: Array<DecalDesc>): bool {
        if (this.from !== decals || this.planned.length != decals.length * DECAL_TEXTURES) return false;
        for (let i = 0; i < decals.length; i++) {
            const t = unchecked(decals[i]).textures;
            for (let s = 0; s < DECAL_TEXTURES; s++) {
                const p = s < t.length ? unchecked(t[s]) : null;
                const q = unchecked(this.planned[i * DECAL_TEXTURES + s]);
                if (p == null) {
                    if (q != null) return false;
                } else if (q == null || p != q) {
                    return false;
                }
            }
        }
        return true;
    }

    // Plans the layers of `decals` (see the class).
    plan(decals: Array<DecalDesc>): void {
        this.keys.length = 0;
        this.paths.length = 0;
        this.srgb.length = 0;
        this.slot.length = 0;
        this.slots.length = 0;
        this.planned.length = 0;
        this.full = false;
        this.from = decals;
        for (let i = 0; i < decals.length; i++) {
            const t = decals[i].textures;
            for (let s = 0; s < DECAL_TEXTURES; s++) {
                const p = s < t.length ? t[s] : null;
                this.planned.push(p);
                if (p == null) {
                    this.slots.push(-1);
                    continue;
                }
                const srgb = decalSlotIsSrgb(s);
                const key = texKey(p, srgb);
                let layer = this.keys.indexOf(key);
                if (layer < 0) {
                    if (this.keys.length >= DECAL_MAX_LAYERS) {
                        this.full = true;
                    } else {
                        layer = this.keys.length;
                        this.keys.push(key);
                        this.paths.push(p);
                        this.srgb.push(srgb);
                        this.slot.push(s);
                    }
                }
                this.slots.push(layer);
            }
        }
    }
}

// The lod header of frame `f`'s decal block (layouts.as DecalUniform.lod):
// the world size of a pixel at distance 1 from the eye (2 tan(fovY / 2)
// over the target's height in pixels, SSAA included), or with y 1 the
// world size of an orthographic view's pixel (its height over the
// target's).
export function decalLod(f: RenderFrame): Vec4 {
    const h = <f32>(max<u32>(f.height, 1) * max<u32>(f.ssaa, 1));
    const p = f.camera.projection;
    if (p.kind == ProjectionKind.Orthographic) return Vec4(<f32>2 * p.value / h, 1, 0, 0);
    return Vec4(<f32>2 * appleTanf(toRadians(p.value) * <f32>0.5) / h, 0, 0, 0);
}

// Fills `u` from frame `f`'s decals and `plan` (see the header): entry k
// the pool's k-th decal, its distance fade on modulate.a and on the
// emission energy (axisX.w), axisY.w the world size of a level-0 texel,
// its layers (+ 1; 0 none) from `slots` (DecalLayerKeys.slots), its
// DECAL_LIVE_* bits from `live` (by layer); the counts and the lod. In
// place: allocates nothing.
export function fillDecalUniform(
    u: DecalUniform, f: RenderFrame, plan: DecalPlan, slots: Array<i32>, live: Array<bool>,
): void {
    const decals = f.decals;
    const n = plan.count;
    for (let k = 0; k < n; k++) {
        const i = unchecked(plan.pool[k]);
        const c = unchecked(decals[i]);
        const fade = unchecked(plan.fade[k]);
        const e = unchecked(u.entries[k]);
        e.toLocal = c.toLocal;
        e.modulate = Vec4(c.modulate.x, c.modulate.y, c.modulate.z, c.modulate.w * fade);
        e.fades = Vec4(c.upperFade, c.lowerFade, c.normalFade, c.albedoMix);
        e.axisX = Vec4(c.axisX.x, c.axisX.y, c.axisX.z, c.emissionEnergy * fade);
        e.axisY = Vec4(c.axisY.x, c.axisY.y, c.axisY.z, max<f32>(c.size.x, c.size.z) / <f32>DECAL_LAYER_SIZE);
        e.axisZ = Vec4(c.axisZ.x, c.axisZ.y, c.axisZ.z, 0);
        const at = i * DECAL_TEXTURES;
        const l0 = slotLayer(slots, at);
        const l1 = slotLayer(slots, at + 1);
        const l2 = slotLayer(slots, at + 2);
        const l3 = slotLayer(slots, at + 3);
        let bits: u32 = 0;
        if (layerLive(live, l0)) bits |= DECAL_LIVE_ALBEDO;
        if (layerLive(live, l1)) bits |= DECAL_LIVE_NORMAL;
        if (layerLive(live, l2)) bits |= DECAL_LIVE_ORM;
        if (layerLive(live, l3)) bits |= DECAL_LIVE_EMISSION;
        e.layers = U32x4(<u32>(l0 + 1), <u32>(l1 + 1), <u32>(l2 + 1), <u32>(l3 + 1));
        e.flags = U32x4(bits, 0, 0, 0);
    }
    u.counts = U32x4(<u32>n, n > 0 ? DECAL_LEVELS : 0, 0, 0);
    u.lod = n > 0 ? decalLod(f) : Vec4(0, 0, 0, 0);
}

function slotLayer(slots: Array<i32>, at: i32): i32 {
    return at < slots.length ? unchecked(slots[at]) : -1;
}

function layerLive(live: Array<bool>, l: i32): bool {
    return l >= 0 && l < live.length && unchecked(live[l]);
}

export class GpuDecals {
    // The atlas's whole view (every layer, every level), or the dummy's.
    view: GPUTextureView;
    // Linear, linear, mip linear, clamp to edge.
    sampler: GPUSampler;
    // Moves whenever `view` does.
    generation: u32 = 0;
    // The frame's block, written by `prepare`, and its bytes.
    uniform: DecalUniform = new DecalUniform();
    bytes: ArrayBuffer = new ArrayBuffer(<i32>DECAL_UNIFORM_SIZE);
    bytesView: DataView;
    // What prepareDecals chose for the last frame (the statistics read it).
    plan: DecalPlan = new DecalPlan();
    // This host frame's work: the static layers drawn (every level) and the
    // live layers drawn again (level 0).
    blits: i32 = 0;
    liveBlits: i32 = 0;
    // The atlas's layers holding a texture of the last frame's decals, and
    // how many of them are live (an ArtboardTexture played by the player).
    // The statistics (`render`'s answer) read them.
    layersUsed: i32 = 0;
    liveLayers: i32 = 0;
    // The frame's layers (see the header) and, by layer, its source view,
    // whether the blit encodes it, whether it is live, and whether the
    // atlas holds it (a static layer's every level).
    keys: DecalLayerKeys = new DecalLayerKeys();
    private sources: Array<GPUTextureView> = [];
    private encodes: Array<bool> = [];
    private live: Array<bool> = [];
    private drawn: Array<bool> = [];
    // The binder's liveGeneration and the base directory the layers were
    // resolved with, and the warnings resolving raised (said again every
    // frame, as the materials' are).
    private resolvedLive: i32 = -1;
    private resolvedBaseDir: string = "";
    private resolveWarnings: Array<string> = [];
    // The atlas (null until a frame has a decal texture), its layers, and
    // by layer * DECAL_LEVELS + level the view and pass that draw into it.
    private atlas: GPUTexture? = null;
    private capacity: i32 = 0;
    private targets: Array<GPUTextureView?> = [];
    private passes: Array<GPUPassDesc?> = [];
    // The blit: its layout, pipelines, sampler and a block per level, made
    // on first use; and by layer * DECAL_LEVELS + level the group binding
    // the layer's source and that level's block.
    private blitTried: bool = false;
    private layout: GPUBindGroupLayout? = null;
    private copyPipeline: GPUPipeline? = null;
    private encodePipeline: GPUPipeline? = null;
    private blitSampler: GPUSampler? = null;
    private levelBlocks: Array<GPUBuffer> = [];
    private groups: Array<GPUBindGroup?> = [];
    private passWrapper: GPURenderPass = new GPURenderPass(0);
    // A refusal (see the header): no decal is drawn (`refused`), or the
    // layers are composed on the CPU (`cpu`); each said once.
    private refused: bool = false;
    private cpu: bool = false;
    private cpuWarned: bool = false;
    // Live layers drawn this host frame (once a frame, however many views
    // draw it).
    private liveDone: bool = false;
    // What a new atlas or a new resolution replaced, released at the next
    // host frame (groups and views the frame recorded may still bind them).
    private retiredTextures: Array<GPUTexture> = [];
    private retiredViews: Array<GPUTextureView> = [];
    private retiredGroups: Array<GPUBindGroup> = [];
    private dummy: GPUTexture;
    private dummyView: GPUTextureView;

    constructor() {
        const d = new GPUTextureDesc();
        d.width = 1;
        d.height = 1;
        d.depthOrArrayLayers = 1;
        d.textureType = TextureType.array2D;
        d.format = DECAL_ATLAS_FORMAT;
        d.numMipmaps = 1;
        d.sampleCount = 1;
        d.renderTarget = false;
        this.dummy = new GPUTexture(d);
        if (this.dummy.handle != 0) {
            this.dummy.upload(uploadRegion(1, 1, 0, 0), new ArrayBuffer(4));
        }
        const vd = new GPUTextureViewDesc();
        vd.dimension = TextureViewDimension.array2D;
        vd.layerCount = 1;
        this.dummyView = this.dummy.view(vd);
        this.view = this.dummyView;
        this.sampler = new GPUSampler(
            Filter.linear, Filter.linear, Filter.linear, WrapMode.clampToEdge, WrapMode.clampToEdge);
        this.bytesView = new DataView(this.bytes, 0, this.bytes.byteLength);
    }

    // A new host frame (FrameRenderer.beginFrame): what the last frame
    // replaced is released, and the live layers are drawn again.
    beginFrame(): void {
        this.blits = 0;
        this.liveBlits = 0;
        this.liveDone = false;
        for (let i = 0; i < this.retiredGroups.length; i++) this.retiredGroups[i].release();
        for (let i = 0; i < this.retiredViews.length; i++) this.retiredViews[i].release();
        for (let i = 0; i < this.retiredTextures.length; i++) this.retiredTextures[i].release();
        this.retiredGroups.length = 0;
        this.retiredViews.length = 0;
        this.retiredTextures.length = 0;
    }

    // The frame's decals for its camera (see the header): the pool and every
    // item's list (decal_select.as prepareDecals), the atlas holding the
    // frame's textures, and the block. Called by FrameRenderer.renderFrame
    // before it writes the items' uniforms; what cannot be drawn is said in
    // `warnings`. Milestone 34: `blitLive` false (a viewport's view, and
    // the main camera's again after the viewports drew) leaves the live
    // layers as this host frame's first prepare drew them, but a live
    // layer the atlas does not hold yet (one that went live since: a
    // viewport's first picture) or holds an older picture of (a viewport
    // drew since: liveChanged) is drawn all the same.
    prepare(f: RenderFrame, binder: MaterialBinder<GPUTextureView, GPUBindGroup>, gpu: Gpu, warnings: Array<string>,
        blitLive: bool = true): void {
        const plan = prepareDecals(f, this.plan);
        this.layersUsed = 0;
        this.liveLayers = 0;
        if (f.decals.length == 0 || this.refused) {
            this.drawNone(f);
            return;
        }
        if (!this.keys.same(f.decals) || this.resolvedLive != binder.liveGeneration
            || this.resolvedBaseDir != f.baseDir) {
            this.resolve(f, binder);
        }
        for (let i = 0; i < this.resolveWarnings.length; i++) warnings.push(this.resolveWarnings[i]);
        const layers = this.keys.keys.length;
        if (layers > 0) {
            if (!this.ready(gpu, layers, warnings)) {
                this.drawNone(f);
                return;
            }
            this.draw(f, binder, gpu, warnings, blitLive);
        }
        this.layersUsed = layers;
        if (!this.cpu) {
            for (let l = 0; l < layers; l++) if (unchecked(this.live[l])) this.liveLayers++;
        }
        if (plan.count == 0) {
            this.clearUniform();
            return;
        }
        fillDecalUniform(this.uniform, f, plan, this.keys.slots, this.live);
    }

    // The live layers whose keys (texKey) are among `keys` hold a picture
    // older than their source's (a viewport just drew into its targets,
    // after this host frame's first prepare copied them): the next prepare
    // copies them again, `blitLive` false or not, so a decal shows the
    // viewport's picture of this frame, as a material does. Allocates
    // nothing.
    liveChanged(keys: Array<string>): void {
        const k = this.keys.keys;
        const n = min<i32>(k.length, min<i32>(this.live.length, this.drawn.length));
        for (let l = 0; l < n; l++) {
            if (!unchecked(this.live[l]) || !unchecked(this.drawn[l])) continue;
            const key = unchecked(k[l]);
            for (let j = 0; j < keys.length; j++) {
                if (unchecked(keys[j]) == key) {
                    unchecked(this.drawn[l] = false);
                    break;
                }
            }
        }
    }

    // No decal this frame: a block of zeros.
    clearUniform(): void {
        this.uniform.counts = U32x4(0, 0, 0, 0);
        this.uniform.lod = Vec4(0, 0, 0, 0);
    }

    // Nothing drawn (no decal, or a host that refused): no item paints one.
    private drawNone(f: RenderFrame): void {
        const p = this.plan;
        if (p.count > 0) {
            const items = f.items;
            for (let i = 0; i < items.length; i++) clearItemDecals(unchecked(items[i]));
            p.count = 0;
            p.items = 0;
            p.overBudget = 0;
        }
        this.clearUniform();
    }

    // The layers of `f`'s decals and their sources (see the header). A
    // layer whose key and source are what its index held before keeps what
    // the atlas holds of it.
    private resolve(f: RenderFrame, binder: MaterialBinder<GPUTextureView, GPUBindGroup>): void {
        const k = this.keys;
        const oldKeys = k.keys.slice(0);
        const oldSources = this.sources.slice(0);
        const oldDrawn = this.drawn.slice(0);
        k.plan(f.decals);
        this.resolveWarnings.length = 0;
        this.resolvedLive = binder.liveGeneration;
        this.resolvedBaseDir = f.baseDir;
        if (k.full) this.resolveWarnings.push(DECAL_ATLAS_FULL_WARNING);
        const n = k.keys.length;
        this.sources.length = 0;
        this.encodes.length = 0;
        this.live.length = 0;
        this.drawn.length = 0;
        for (let l = 0; l < n; l++) {
            const path = k.paths[l];
            const srgb = k.srgb[l];
            const fallback = srgb ? binder.magenta : k.slot[l] == DECAL_TEXTURE_NORMAL ? binder.flatNormal : binder.white;
            const view = binder.texture(path, srgb, fallback, f.baseDir, this.resolveWarnings);
            const inShader = binder.lastSrgbInShader;
            const live = binder.live.size > 0 && binder.live.has(texKey(path, srgb));
            const kept = l < oldKeys.length && oldKeys[l] == k.keys[l] && oldSources[l] === view;
            if (!kept) this.retireGroups(l);
            this.sources.push(view);
            this.encodes.push(decalBlitEncodes(srgb, inShader, live));
            this.live.push(live);
            this.drawn.push(kept && oldDrawn[l]);
        }
        for (let l = n; l < oldKeys.length; l++) this.retireGroups(l);
    }

    // Layer `l`'s groups retired (its source changed).
    private retireGroups(l: i32): void {
        const at = l * <i32>DECAL_LEVELS;
        for (let m = 0; m < <i32>DECAL_LEVELS && at + m < this.groups.length; m++) {
            const g = this.groups[at + m];
            if (g != null) this.retiredGroups.push(g);
            this.groups[at + m] = null;
        }
    }

    // Whether the atlas holds `layers` layers and the blit is there, made
    // as needed; false (said once: nothing is asked again) when the host
    // refuses either.
    private ready(gpu: Gpu, layers: i32, warnings: Array<string>): bool {
        if (!this.cpu && !this.blitReady(gpu)) {
            this.refused = true;
            warnings.push(DECAL_BLIT_WARNING);
            return false;
        }
        if (layers <= this.capacity) return true;
        const cap = decalAtlasCapacity(layers);
        const d = new GPUTextureDesc();
        d.width = DECAL_LAYER_SIZE;
        d.height = DECAL_LAYER_SIZE;
        d.depthOrArrayLayers = <u32>cap;
        d.textureType = TextureType.array2D;
        d.format = DECAL_ATLAS_FORMAT;
        d.numMipmaps = DECAL_LEVELS;
        d.sampleCount = 1;
        d.renderTarget = true;
        const t = new GPUTexture(d);
        let v: GPUTextureView? = null;
        if (t.handle != 0) {
            const vd = new GPUTextureViewDesc();
            vd.dimension = TextureViewDimension.array2D;
            vd.layerCount = <u32>cap;
            v = t.view(vd);
        }
        if (v == null || v.handle == 0) {
            if (t.handle != 0) t.release();
            this.refused = true;
            warnings.push(DECAL_ATLAS_WARNING);
            return false;
        }
        const old = this.atlas;
        if (old != null) {
            this.retiredTextures.push(old);
            this.retiredViews.push(this.view);
        }
        for (let i = 0; i < this.targets.length; i++) {
            const tv = this.targets[i];
            if (tv != null) this.retiredViews.push(tv);
        }
        this.atlas = t;
        this.view = v;
        this.capacity = cap;
        this.generation++;
        const slots = cap * <i32>DECAL_LEVELS;
        this.targets.length = 0;
        this.passes.length = 0;
        for (let i = 0; i < slots; i++) {
            this.targets.push(null);
            this.passes.push(null);
        }
        while (this.groups.length < slots) this.groups.push(null);
        for (let l = 0; l < this.drawn.length; l++) this.drawn[l] = false;
        return true;
    }

    // Every layer the atlas does not hold yet, and the live ones once a
    // host frame (see the header; `blitLive` false: only a live layer the
    // atlas does not hold yet).
    private draw(f: RenderFrame, binder: MaterialBinder<GPUTextureView, GPUBindGroup>, gpu: Gpu, warnings: Array<string>,
        blitLive: bool): void {
        if (!this.cpu) {
            const liveNow = blitLive && !this.liveDone;
            if (blitLive) this.liveDone = true;
            const n = this.keys.keys.length;
            for (let l = 0; l < n; l++) {
                if (unchecked(this.live[l])) {
                    if (!liveNow && unchecked(this.drawn[l])) continue;
                    if (!this.blit(gpu, l, 0)) break;
                    this.liveBlits++;
                    this.drawn[l] = true;
                    continue;
                }
                if (unchecked(this.drawn[l])) continue;
                let m: u32 = 0;
                while (m < DECAL_LEVELS && this.blit(gpu, l, m)) m++;
                if (m < DECAL_LEVELS) break;
                this.drawn[l] = true;
                this.blits++;
            }
            if (!this.cpu) return;
            // (a refused render: every layer again, on the CPU)
            for (let l = 0; l < this.drawn.length; l++) this.drawn[l] = false;
        }
        this.compose(f, binder, warnings);
    }

    // Draws layer `l`'s level `level` from its source; false when the host
    // refused the view, the group or the pass (the layers are then
    // composed on the CPU: `cpu`).
    private blit(gpu: Gpu, l: i32, level: u32): bool {
        const at = l * <i32>DECAL_LEVELS + <i32>level;
        let target = this.targets[at];
        const atlas = this.atlas;
        if (target == null && atlas != null) {
            const vd = new GPUTextureViewDesc();
            vd.dimension = TextureViewDimension.texture2D;
            vd.baseLayer = <u32>l;
            vd.layerCount = 1;
            vd.baseMipLevel = level;
            vd.mipCount = 1;
            const v = atlas.view(vd);
            if (v.handle != 0) {
                target = v;
                this.targets[at] = v;
            }
        }
        if (target == null) {
            this.cpu = true;
            return false;
        }
        let desc = this.passes[at];
        if (desc == null) {
            const a = new GPUColorAttachment();
            a.view = target;
            // Every texel is written: the clear only spares the host a load.
            a.loadOp = LoadOp.clear;
            a.storeOp = StoreOp.store;
            a.clearR = 0;
            a.clearG = 0;
            a.clearB = 0;
            a.clearA = 0;
            desc = new GPUPassDesc();
            desc.color = [a];
            this.passes[at] = desc;
        }
        let group = this.groups[at];
        if (group == null) {
            const g = new GPUBindGroup(
                this.layout!,
                [new GPUBindGroupUBO(DECAL_BLIT_LEVEL_BINDING, this.levelBlocks[<i32>level], 0, DECAL_BLIT_UNIFORM_SIZE)],
                [new GPUBindGroupTexture(0, unchecked(this.sources[l]))],
                [new GPUBindGroupSampler(1, this.blitSampler!)],
            );
            if (g.handle == 0) {
                this.cpu = true;
                return false;
            }
            group = g;
            this.groups[at] = g;
        }
        desc.label = "hedra decal blit";
        const pass = gpu.canvas.beginRenderPass(desc, this.passWrapper);
        if (pass.handle == 0) {
            this.cpu = true;
            return false;
        }
        pass.setPipeline(unchecked(this.encodes[l]) ? this.encodePipeline! : this.copyPipeline!);
        // GPURenderPass.setBindGroup's default offsets are a new array per
        // call: the binding itself, with none (renderer.as `bindGroup`).
        abi.rive_gpu_pass_set_bind_group(pass.handle, 0, group.handle, 0, 0);
        pass.draw(3);
        pass.finish();
        return true;
    }

    // The CPU's road (see the header): each layer the atlas does not hold,
    // its image as the files give it (a colour file's sRGB bytes as they
    // are: what the atlas holds), resampled to a layer, its chain uploaded.
    // A live layer draws its placeholder (the file the binder was given for
    // it), so it is not live here.
    private compose(f: RenderFrame, binder: MaterialBinder<GPUTextureView, GPUBindGroup>, warnings: Array<string>): void {
        if (!this.cpuWarned) {
            this.cpuWarned = true;
            warnings.push(DECAL_CPU_WARNING);
        }
        const atlas = this.atlas;
        if (atlas == null) return;
        const k = this.keys;
        for (let l = 0; l < k.keys.length; l++) {
            this.live[l] = false;
            if (this.drawn[l]) continue;
            let img = binder.image(k.paths[l], f.baseDir, this.resolveWarnings);
            if (img == null) {
                img = Image.new(1, 1, k.srgb[l] ? Rgba(255, 0, 255, 255)
                    : k.slot[l] == DECAL_TEXTURE_NORMAL ? Rgba(128, 128, 255, 255) : Rgba(255, 255, 255, 255));
            }
            const chain = mipChain(resampleBilinear(img, DECAL_LAYER_SIZE, DECAL_LAYER_SIZE));
            for (let m = 0; m < chain.length && m < <i32>DECAL_LEVELS; m++) {
                const level = chain[m];
                atlas.upload(uploadRegion(level.width, level.height, <u32>m, <u32>l), levelBytes(level, false));
            }
            this.drawn[l] = true;
            this.blits++;
        }
    }

    // The blit's layout, pipelines, sampler and level blocks, made once;
    // false when the project has no DECAL_BLIT_SHADER or the host rejects
    // any of them.
    private blitReady(gpu: Gpu): bool {
        if (this.blitTried) return this.copyPipeline != null;
        this.blitTried = true;
        const mod = gpu.ctx.shader(shaderAsset(DECAL_BLIT_SHADER));
        if (mod == null) return false;
        const layout = GPUBindGroupLayout.fromShader(mod, 0);
        if (layout == null) return false;
        const copy = decalBlitPipeline(mod, layout, DECAL_BLIT_COPY);
        const encode = decalBlitPipeline(mod, layout, DECAL_BLIT_ENCODE);
        const sampler = new GPUSampler(
            Filter.linear, Filter.linear, Filter.linear, WrapMode.clampToEdge, WrapMode.clampToEdge);
        if (copy.handle == 0 || encode.handle == 0 || sampler.handle == 0) {
            if (copy.handle != 0) copy.release();
            if (encode.handle != 0) encode.release();
            if (sampler.handle != 0) sampler.release();
            return false;
        }
        const bytes = new ArrayBuffer(<i32>DECAL_BLIT_UNIFORM_SIZE);
        const dv = new DataView(bytes, 0, bytes.byteLength);
        for (let m: u32 = 0; m < DECAL_LEVELS; m++) {
            dv.setFloat32(0, <f32>m, true);
            this.levelBlocks.push(new GPUBuffer(BufferUsage.uniform, DECAL_BLIT_UNIFORM_SIZE, bytes));
        }
        this.layout = layout;
        this.copyPipeline = copy;
        this.encodePipeline = encode;
        this.blitSampler = sampler;
        return true;
    }

    // Releases the atlas, the blit and the dummy.
    release(): void {
        this.beginFrame();
        for (let i = 0; i < this.groups.length; i++) {
            const g = this.groups[i];
            if (g != null) g.release();
        }
        this.groups.length = 0;
        for (let i = 0; i < this.targets.length; i++) {
            const v = this.targets[i];
            if (v != null) v.release();
        }
        this.targets.length = 0;
        this.passes.length = 0;
        for (let i = 0; i < this.levelBlocks.length; i++) this.levelBlocks[i].release();
        this.levelBlocks.length = 0;
        const c = this.copyPipeline;
        if (c != null) c.release();
        const e = this.encodePipeline;
        if (e != null) e.release();
        const s = this.blitSampler;
        if (s != null) s.release();
        this.copyPipeline = null;
        this.encodePipeline = null;
        this.blitSampler = null;
        const a = this.atlas;
        if (a != null) {
            this.view.release();
            a.release();
        }
        this.atlas = null;
        this.capacity = 0;
        this.view = this.dummyView;
        this.dummyView.release();
        this.dummy.release();
        this.sampler.release();
    }
}

// One blit pipeline: the full-screen triangle into one layer and level of
// the atlas, no blending (the source replaces the texels), no depth, one
// sample.
function decalBlitPipeline(mod: GPUShaderModule, layout: GPUBindGroupLayout, fs: string): GPUPipeline {
    const d = new GPUPipelineDesc();
    d.vertexModule = mod;
    d.vertexEntryPoint = DECAL_BLIT_VERTEX;
    d.fragmentModule = mod;
    d.fragmentEntryPoint = fs;
    const t = new GPUColorTargetDesc();
    t.format = DECAL_ATLAS_FORMAT;
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
