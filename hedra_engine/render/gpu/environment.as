// The sky's maps on the GPU (milestone 11): the radiance cube the lit
// shader reads reflections and aerial perspective from, and the panorama
// the sky pass draws, with their samplers (surface.wgsl group 0, bindings 6
// to 9). sky.as builds both on the CPU once per environment (`IblCache`);
// this uploads a plan when the renderer hands it a new one and keeps it
// while the plan is the same object, so a preview drawing many frames of
// one sky uploads it once.
//
// Group 0 of the surface module always declares these bindings, so every
// renderer (Hedra's too) binds something there: until a plan arrives, a
// 1 x 1 x 6 black cube and a 1 x 1 black image (48 and 8 bytes of texels),
// which a frame with flags 0 never reads. A frame without a Sky hands
// `update` null, which changes nothing: no upload, no new bind group.
//
// Both maps are rgba16float (layouts.as RADIANCE_FORMAT and
// PANORAMA_FORMAT) with alpha 1. Half floats hold 0 to 65504; a brighter
// texel (the sun of some HDRIs) is clamped to that, a negative one to 0,
// and a NaN is written as 0, so no texel poisons a filtered lookup.

import {
    GPUSampler, GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc,
} from "rive/gpu";
import { Filter, TextureType, TextureViewDimension, WrapMode } from "rive/gpu_enums";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";
import { Vec3 } from "../../base/vecmath";
import { FloatImage } from "../hdr";
import { CubeLevel, IblPlan } from "../sky";
import { PANORAMA_FORMAT, RADIANCE_FORMAT } from "./layouts";
import { f32ToF16Bits } from "./materials";
import { uploadRegion } from "./upload";

// Bytes per rgba16float texel.
const TEXEL_BYTES: u32 = 8;
// Half-float 1, the alpha of every texel.
const HALF_ONE: u16 = 0x3c00;
// The largest finite half float.
const HALF_MAX: f32 = 65504;

// What FrameRenderer.warnings says when the host refuses a map: the sky is
// then drawn and lit from the previous map (the black dummies at first).
// The Hedra programs' SceneRenderer drops the GPU pass's warnings (they
// come after the answer is printed), so only a caller that reads
// FrameRenderer.warnings sees it; nothing seen so far refuses a map.
export const ENVIRONMENT_WARNING = "the sky's light is not drawn: the host rejected its maps";

// Half-float bits of a texel channel, clamped to what a half holds.
function halfOf(v: f32): u16 {
    if (isNaN<f32>(v)) return 0;
    return f32ToF16Bits(Mathf.min(Mathf.max(v, 0), HALF_MAX));
}

// `n` rgb texels of `src` (3 f32 each, from `at`) as rgba16float bytes.
function rgbToHalf(src: Float32Array, at: i32, n: i32): ArrayBuffer {
    const out = new ArrayBuffer(n * <i32>TEXEL_BYTES);
    const dv = new DataView(out, 0, out.byteLength);
    for (let i = 0; i < n; i++) {
        const s = at + i * 3;
        const o = i * <i32>TEXEL_BYTES;
        dv.setUint16(o, halfOf(src[s]), true);
        dv.setUint16(o + 2, halfOf(src[s + 1]), true);
        dv.setUint16(o + 4, halfOf(src[s + 2]), true);
        dv.setUint16(o + 6, HALF_ONE, true);
    }
    return out;
}

// One face of a cube level as the upload takes it: rgba16float, rows top
// first, alpha 1.
export function cubeFaceBytes(level: CubeLevel, face: i32): ArrayBuffer {
    return rgbToHalf(level.faces[face], 0, <i32>(level.size * level.size));
}

// A float image as the upload takes it: rgba16float, rows top first,
// alpha 1.
export function floatImageBytes(img: FloatImage): ArrayBuffer {
    return rgbToHalf(img.data, 0, <i32>(img.width * img.height));
}

// The upload region of `w` x `h` texels at `mip` of `layer` (the
// renderer's one region: gpu/upload.as).
function region(w: u32, h: u32, mip: u32, layer: u32): rive_gpu_texture_upload_v1 {
    return uploadRegion(w, h, mip, layer, 0, 0, w * TEXEL_BYTES);
}

// A cube texture holding `levels` (level 0 the largest, each half the one
// before), one upload per face per level; its handle is 0 when the host
// refuses it (nothing is uploaded then).
function uploadCube(levels: Array<CubeLevel>): GPUTexture {
    const d = new GPUTextureDesc();
    d.width = levels[0].size;
    d.height = levels[0].size;
    d.depthOrArrayLayers = 6;
    d.textureType = TextureType.cube;
    d.format = RADIANCE_FORMAT;
    d.numMipmaps = <u32>levels.length;
    d.sampleCount = 1;
    d.renderTarget = false;
    const t = new GPUTexture(d);
    if (t.handle == 0) return t;
    for (let m = 0; m < levels.length; m++) {
        const level = levels[m];
        for (let face = 0; face < 6; face++) {
            t.upload(region(level.size, level.size, <u32>m, <u32>face), cubeFaceBytes(level, face));
        }
    }
    return t;
}

// A 2D texture holding `img` (one level); its handle is 0 when the host
// refuses it.
function uploadImage2D(img: FloatImage): GPUTexture {
    const d = new GPUTextureDesc();
    d.width = img.width;
    d.height = img.height;
    d.format = PANORAMA_FORMAT;
    d.numMipmaps = 1;
    d.sampleCount = 1;
    d.renderTarget = false;
    const t = new GPUTexture(d);
    if (t.handle == 0) return t;
    t.upload(region(img.width, img.height, 0, 0), floatImageBytes(img));
    return t;
}

// The view a `texture_cube` binding samples: all six faces, every level.
function cubeView(t: GPUTexture): GPUTextureView {
    const d = new GPUTextureViewDesc();
    d.dimension = TextureViewDimension.cube;
    d.layerCount = 6;
    return t.view(d);
}

export class GpuEnvironment {
    // The cube view (binding 6); the black dummy until a plan is uploaded.
    radianceView: GPUTextureView;
    // The panorama (binding 7); the black dummy likewise, and again for a
    // procedural sky, which reads none.
    panoramaView: GPUTextureView;
    // Trilinear and clamped: the cube's faces meet at their edges, and the
    // shader reads a mip by roughness.
    radianceSampler: GPUSampler;
    // Bilinear, one level; repeating across (the panorama's seam at the
    // back) and clamped down (its poles), as sky.as `samplePanorama`.
    panoramaSampler: GPUSampler;
    // +1 whenever a view changes: the renderer remakes the bind groups that
    // hold the old ones.
    generation: u32 = 0;
    // A message for the renderer's warnings when a map was refused since
    // the last `takeWarning` ("" none).
    private warning: string = "";
    // The plan uploaded last (compared by identity).
    private uploaded: IblPlan? = null;
    // The panorama image behind `panorama` (compared by identity): IblCache
    // hands a rebuilt plan the same image when only the energy, filter or
    // radiance size changed, and its texels are not uploaded again.
    private uploadedPanorama: FloatImage? = null;
    // The dummies, kept for the renderer's life.
    private dummyCube: GPUTexture;
    private dummyCubeView: GPUTextureView;
    private dummyPanorama: GPUTexture;
    private dummyPanoramaView: GPUTextureView;
    // The uploaded maps (null: the dummy is bound).
    private radiance: GPUTexture? = null;
    private panorama: GPUTexture? = null;
    // What `update` replaced, freed by `releaseRetired` once the frame that
    // may still sample it is recorded.
    private retiredTextures: Array<GPUTexture> = [];
    private retiredViews: Array<GPUTextureView> = [];

    constructor() {
        // A host that refuses even these could not make the surface
        // pipelines either (group 0 declares a texture_cube), so the
        // renderer never gets this far on one.
        this.dummyCube = uploadCube([new CubeLevel(1)]);
        this.dummyCubeView = cubeView(this.dummyCube);
        this.dummyPanorama = uploadImage2D(FloatImage.new(1, 1, Vec3(0, 0, 0)));
        this.dummyPanoramaView = this.dummyPanorama.view();
        this.radianceView = this.dummyCubeView;
        this.panoramaView = this.dummyPanoramaView;
        this.radianceSampler = new GPUSampler(
            Filter.linear, Filter.linear, Filter.linear, WrapMode.clampToEdge, WrapMode.clampToEdge);
        this.panoramaSampler = new GPUSampler(
            Filter.linear, Filter.linear, Filter.nearest, WrapMode.repeat, WrapMode.clampToEdge);
    }

    // The plan uploaded last, or null.
    current(): IblPlan? {
        return this.uploaded;
    }

    // Uploads `plan` unless it is (by identity) the plan uploaded last; null
    // changes nothing (the flags keep the shader away from the maps).
    update(plan: IblPlan?): void {
        if (plan == null) return;
        if (this.uploaded === plan) return;
        this.uploaded = plan;
        if (plan.radiance.levels.length == 0) return;
        const cube = uploadCube(plan.radiance.levels);
        if (cube.handle == 0) {
            this.warning = ENVIRONMENT_WARNING;
            return;
        }
        const view = cubeView(cube);
        if (view.handle == 0) {
            cube.release();
            this.warning = ENVIRONMENT_WARNING;
            return;
        }
        const img = plan.panorama;
        if (img != null && img === this.uploadedPanorama && this.panorama != null) {
            // The same texels are on the GPU already: only the cube changes.
            this.retire(this.radiance, this.radianceView);
            this.radiance = cube;
            this.radianceView = view;
            this.generation++;
            return;
        }
        let pano: GPUTexture? = null;
        let panoView = this.dummyPanoramaView;
        if (img != null) {
            const t = uploadImage2D(img);
            const v = t.handle != 0 ? t.view() : null;
            if (v == null || v.handle == 0) {
                if (t.handle != 0) t.release();
                view.release();
                cube.release();
                this.warning = ENVIRONMENT_WARNING;
                return;
            }
            pano = t;
            panoView = v;
        }
        this.retire(this.radiance, this.radianceView);
        this.retire(this.panorama, this.panoramaView);
        this.radiance = cube;
        this.radianceView = view;
        this.panorama = pano;
        this.panoramaView = panoView;
        this.uploadedPanorama = img;
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

    // Frees everything, the dummies included (milestone 34: a viewport's
    // own environment, gpu/viewports.as, when the viewport leaves the
    // plan); the main one lives as long as its renderer. Call once the
    // frames that sampled it are recorded.
    release(): void {
        this.releaseRetired();
        this.retire(this.radiance, this.radianceView);
        this.retire(this.panorama, this.panoramaView);
        this.releaseRetired();
        this.radiance = null;
        this.panorama = null;
        this.uploaded = null;
        this.uploadedPanorama = null;
        this.dummyCubeView.release();
        this.dummyCube.release();
        this.dummyPanoramaView.release();
        this.dummyPanorama.release();
        this.radianceSampler.release();
        this.panoramaSampler.release();
    }

    // An uploaded map and its view, to free at the next `releaseRetired`
    // (a dummy is never retired: `texture` is null then).
    private retire(texture: GPUTexture?, view: GPUTextureView): void {
        if (texture == null) return;
        this.retiredViews.push(view);
        this.retiredTextures.push(texture);
    }
}
