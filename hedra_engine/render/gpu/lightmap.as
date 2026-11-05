// A frame's lightmap on the GPU (milestone 19, Godot's LightmapGI): the
// layers of RenderFrame.lightmap as one texture_2d_array, and the sampler
// the lightmap entry points read it with (surface.wgsl group 3, bindings 4
// and 5). compiler/src/bake/lightmap/ bakes the layers on the CPU and
// Hedra loads them from an .lmbake; this uploads them the first time a
// frame hands the renderer that LightmapImages object and keeps them while
// the frames hand it the same one, so a preview drawing many frames of one
// bake uploads it once.
//
// Group 0 of the surface module always declares both bindings, so every
// renderer (Hedra's too) binds something there: until a lightmap
// arrives, a 1 x 1 x 1 black layer (8 bytes of texels), which no frame
// reads (only an item with OBJ_LIGHTMAP does, and only a frame with a
// lightmap sets it). A frame without one hands `update` null, which changes
// nothing: no upload, no new bind group, the last lightmap kept (a viewport
// switching between the lit and solid shadings of one baked scene uploads
// it once).
//
// The layers are rgba16float with alpha 1, converted as the sky's maps are
// (gpu/environment.as `floatImageBytes`: a texel past the half float's
// 65504 clamped to it, a negative one or NaN to 0), rows top first: v of a
// lightmap coordinate grows down the rows (lightmap/data.as), which is the
// texture's own orientation, so the shader samples the coordinate as it is.
// One mip: a lightmap is seen close and its texels are a few centimetres,
// and a mip chain would bleed the padding between charts into them.

import {
    GPUSampler, GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc,
} from "rive/gpu";
import { Filter, TextureFormat, TextureType, TextureViewDimension, WrapMode } from "rive/gpu_enums";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";
import { Vec3 } from "../../base/vecmath";
import { FloatImage } from "../hdr";
import { LightmapImages } from "../lightmap/data";
import { floatImageBytes } from "./environment";
import { uploadRegion } from "./upload";

// The format of every layer.
export const LIGHTMAP_FORMAT: TextureFormat = TextureFormat.rgba16float;

// Bytes per rgba16float texel.
const TEXEL_BYTES: u32 = 8;

// What FrameRenderer.warnings says when the host refuses a lightmap's
// texture: its items are then drawn in real time (the lightmap pipelines
// are not used for them), as if the scene had no bake.
export const LIGHTMAP_TEXTURE_WARNING =
    "lightmapped items are drawn with real-time light: the host rejected the lightmap texture";

// The upload region of layer `layer`, `w` x `h` texels (the renderer's
// one region: gpu/upload.as).
function region(w: u32, h: u32, layer: u32): rive_gpu_texture_upload_v1 {
    return uploadRegion(w, h, 0, layer, 0, 0, w * TEXEL_BYTES);
}

// A 2D array texture of `layers` (all `w` x `h`), one level; its handle is
// 0 when the host refuses it (nothing is uploaded then).
function uploadLayers(w: u32, h: u32, layers: Array<FloatImage>): GPUTexture {
    const d = new GPUTextureDesc();
    d.width = w;
    d.height = h;
    d.depthOrArrayLayers = <u32>layers.length;
    d.textureType = TextureType.array2D;
    d.format = LIGHTMAP_FORMAT;
    d.numMipmaps = 1;
    d.sampleCount = 1;
    d.renderTarget = false;
    const t = new GPUTexture(d);
    if (t.handle == 0) return t;
    for (let i = 0; i < layers.length; i++) {
        t.upload(region(w, h, <u32>i), floatImageBytes(layers[i]));
    }
    return t;
}

// The view a `texture_2d_array` binding samples: every layer.
function arrayView(t: GPUTexture, layers: u32): GPUTextureView {
    const d = new GPUTextureViewDesc();
    d.dimension = TextureViewDimension.array2D;
    d.layerCount = layers;
    return t.view(d);
}

// Whether `img` can be one layer of `images`: its size, and texels for all
// of it.
function layerFits(images: LightmapImages, img: FloatImage): bool {
    return <i32>img.width == images.width && <i32>img.height == images.height
        && img.data.length >= <i32>(img.width * img.height * 3);
}

export class GpuLightmap {
    // The layers (binding 11): the black dummy until a lightmap is uploaded.
    view: GPUTextureView;
    // Bilinear, one level, clamped at the layer's edges (binding 12): the
    // padding between charts holds each chart's light dilated, so a lookup
    // near a chart's edge reads its own chart.
    sampler: GPUSampler;
    // +1 whenever `view` changes: the renderer remakes the bind groups that
    // hold the old one.
    generation: u32 = 0;
    // A message for the renderer's warnings when a lightmap was refused
    // since the last `takeWarning` ("" none).
    private warning: string = "";
    // The lightmap handed over last (compared by identity), and whether
    // its layers are the ones bound (false: refused, or empty).
    private handed: LightmapImages? = null;
    private ok: bool = false;
    // The dummy, kept for the renderer's life.
    private dummy: GPUTexture;
    private dummyView: GPUTextureView;
    // The uploaded layers (null: the dummy is bound).
    private texture: GPUTexture? = null;
    // What `update` replaced, freed by `releaseRetired` once the frame that
    // may still sample it is recorded.
    private retiredTextures: Array<GPUTexture> = [];
    private retiredViews: Array<GPUTextureView> = [];

    constructor() {
        // A host that refuses even this could not make the surface
        // pipelines either (group 0 declares the array), so the renderer
        // never gets this far on one.
        this.dummy = uploadLayers(1, 1, [FloatImage.new(1, 1, Vec3(0, 0, 0))]);
        this.dummyView = arrayView(this.dummy, 1);
        this.view = this.dummyView;
        this.sampler = new GPUSampler(
            Filter.linear, Filter.linear, Filter.nearest, WrapMode.clampToEdge, WrapMode.clampToEdge);
    }

    // Whether `images` is the lightmap whose layers are bound (`update` has
    // uploaded it): the renderer draws a frame's lightmapped items with the
    // lightmap pipelines only then.
    holds(images: LightmapImages?): bool {
        return images != null && this.handed === images && this.ok;
    }

    // Uploads `images` unless it is (by identity) the lightmap handed over
    // last; null changes nothing. A lightmap without a layer, or whose
    // layers are not all its size, is not uploaded (the frame's
    // lightmapped items are then drawn in real time).
    update(images: LightmapImages?): void {
        if (images == null) return;
        if (this.handed === images) return;
        this.handed = images;
        this.ok = false;
        // The last lightmap goes whatever becomes of this one (the dummy is
        // bound until it is up).
        if (this.texture != null) {
            this.retire();
            this.generation++;
        }
        const layers = images.layers;
        if (layers.length == 0 || images.width <= 0 || images.height <= 0) return;
        for (let i = 0; i < layers.length; i++) {
            if (!layerFits(images, layers[i])) return;
        }
        const t = uploadLayers(<u32>images.width, <u32>images.height, layers);
        if (t.handle == 0) {
            this.warning = LIGHTMAP_TEXTURE_WARNING;
            return;
        }
        const v = arrayView(t, <u32>layers.length);
        if (v.handle == 0) {
            t.release();
            this.warning = LIGHTMAP_TEXTURE_WARNING;
            return;
        }
        this.texture = t;
        this.view = v;
        this.ok = true;
        this.generation++;
    }

    // The warning raised since the last call ("" none).
    takeWarning(): string {
        const w = this.warning;
        this.warning = "";
        return w;
    }

    // Frees what `update` replaced; the renderer calls it in beginFrame.
    releaseRetired(): void {
        for (let i = 0; i < this.retiredViews.length; i++) this.retiredViews[i].release();
        for (let i = 0; i < this.retiredTextures.length; i++) this.retiredTextures[i].release();
        // (emptied in place: the renderer calls this every frame, and the
        // stub runtime never frees)
        this.retiredViews.length = 0;
        this.retiredTextures.length = 0;
    }

    // The bound layers, to free at the next `releaseRetired` (the dummy is
    // never retired).
    private retire(): void {
        const t = this.texture;
        if (t == null) return;
        this.retiredViews.push(this.view);
        this.retiredTextures.push(t);
        this.texture = null;
        this.view = this.dummyView;
    }
}
