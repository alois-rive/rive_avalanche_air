// Post-processing (milestone 12): Godot's Environment glow, screen-space
// ambient occlusion and adjustments, and the tone map moved after the glow.
// Pure: what runs (`planPost`), the blocks each pass reads (PostUniform,
// layouts.as), and a CPU reference of every formula the shaders apply, so a
// Tests suite checks them number by number
// (editor/program/tests/render/post_test.as). The GPU passes are
// gpu/renderer.as's and shaders/render/post_effects.wgsl's.
//
// A frame draws with post-processing only in the lit mode, and only for what
// its environment turns on; with nothing on the plan is empty, no pass runs
// and no block changes, so the picture is what it was before this milestone
// (the byte-identity check says so). In order, inside one host `draw`:
//
//   SSAO   (ssao_enabled) the normal-depth pass draws every opaque and
//          masked surface's view-space normal and view depth
//          (NORMAL_DEPTH_FORMAT, the render size, no MSAA); fs_ssao turns
//          it into occlusion (AO_FORMAT), fs_ssao_blur blurs that within a
//          surface; the main pass then reads it at each pixel (group 0,
//          binding 10 of the surface module) and darkens the ambient light
//          (and the direct light by ssao_light_affect times
//          ssao_ao_channel_affect), as Godot's scene
//          shader does. It is not Godot's ASSAO: a scalable ambient
//          obscurance (McGuire et al. 2012) over SSAO_SAMPLES taps in a
//          spiral of SSAO_TURNS turns, turned per pixel by the 4 x 4 Bayer
//          matrix, plus a second estimate at SSAO_DETAIL_RADIUS of the
//          radius mixed in by ssao_detail, blurred over one Bayer period.
//          Each tap is taken at its texel's centre and must clear the
//          tangent plane by SSAO_DEPTH_BIAS of the depth.
//   main   as before; with glow on, lit() and the sky write HDR colour (the
//          lit block's tone map is linear at exposure 1: `litUniform`),
//          and the post pass exposes and tone maps it.
//   glow   (glow_enabled, a level weighted) fs_glow_bright box-filters the
//          resolved colour down to level 1's size (half the picture's
//          size before SSAA: `glowLevelSize`), exposes it and keeps what is
//          above glow_hdr_threshold (Godot's glow first pass); each level k
//          is then Godot's separable Gaussian (GLOW_WEIGHTS_H, 7 taps
//          half a level-k texel apart, as Godot's reads a source twice the
//          size a source texel apart, times glow_strength; GLOW_WEIGHTS_V,
//          5 taps a level-k texel apart) of level k - 1
//          halved (level 1: of the bright pass), up to the highest level
//          with a weight; level k is mip k - 1 of one texture, which
//          fs_post samples at each level's mip.
//   final  (glow or adjustments) fs_post, per pixel at the render size:
//          `postPixel`, then the overlay layer (the lines and points the
//          main pass would have drawn: grid, edges, gizmos, drawn by a pass
//          of their own) laid over it untouched, into sRGB bytes that the
//          outline pass reads as already encoded.
//
// then the id, outline and compose passes as before, so the selection
// outline, labels and axis gizmo are drawn over the finished picture and
// the SSAA downsample averages it.
//
// Milestone 62 (screen.as, docs/engine/SCREEN_EFFECTS.md) adds three
// effects to the chain, in Godot's order:
//
//   prepass  (SSAO, reflections or depth of field) the normal-depth pass,
//            which writes a second target, SSR_SURFACE_FORMAT: the
//            surface's F0 (rgb) and perceptual roughness (a), (0, 0, 0, 1)
//            where nothing is drawn. SSAO reads the first as before.
//   split    (reflections or refraction) the main pass in two: A, the sky
//            and the opaque and masked surfaces but those that refract,
//            its MSAA colour and depth stored; the screen texture, a copy
//            of A's resolved colour with `screenLevels` mips; the
//            reflections traced (`ssr`, at ssrWidth x ssrHeight) from it,
//            the normal-depth pass and its second target; B, on A's
//            samples and depth: the reflections laid over the colour, the
//            surfaces that refract (sampling the screen texture), the
//            blended ones and the top pass.
//   dof      (a camera's depth of field) after the main pass: the circle
//            of confusion and the half-size colour, the gather, the
//            composition at the render size; glow and the final pass read
//            its result instead of the resolve.
//
// Any of the three keeps the main pass's colour HDR and moves the tone map
// to the final pass (`toneInPost`), as the glow does. A frame that turns
// none on plans none of it and draws as before.

import { linearToSrgb } from "../base/color";
import { Mat4, Vec3, Vec4, log2f, powf } from "../base/vecmath";
import {
    AdjustmentDesc, EnvironmentDesc, GLOW_BLEND_ADDITIVE, GLOW_BLEND_MIX, GLOW_BLEND_REPLACE, GLOW_BLEND_SCREEN,
    CAST_SHADOW_SHADOWS_ONLY, GLOW_BLEND_SOFTLIGHT, GLOW_LEVELS, GlowDesc, RenderFrame, SHADE_LIT, TONEMAP_ACES,
    TONEMAP_AGX, TONEMAP_FILMIC, TONEMAP_REINHARD,
} from "./frame";
import {
    POST_ADJUST, POST_DOWNSAMPLE, POST_GLOW, POST_SSAO_HALF, POST_STRAIGHT, POST_TONEMAP, PostUniform, U32x4,
} from "./gpu/layouts";
import { CULL_DRAWN, rangeDrawn } from "./cull";
import { materialRefracts } from "./material";
import {
    DOF_TAPS, SCREEN_DOF, SCREEN_REFRACTION, SCREEN_SSR, ScreenStats, dofDrawn, dofRadiusPx, dofSide, screenLevelCount,
    ssrQuarter, ssrSide, ssrSteps,
} from "./screen";

// Godot's glow blur (gaussian_glow.glsl): the horizontal taps at 0, 1, 2
// and 3 texels of the level above (half a texel of the level written; each
// weight but the first on both sides), the vertical at 0, 1 and 2 texels
// of the level written. Each set sums to 1.
export const GLOW_WEIGHTS_H: StaticArray<f32> = [0.174938, 0.165569, 0.140367, 0.106595];
export const GLOW_WEIGHTS_V: StaticArray<f32> = [0.288713, 0.233062, 0.122581];

// The 4 x 4 Bayer matrix, row by row: a pixel (x, y) turns its SSAO spiral
// by 2 pi * BAYER4[(y % 4) * 4 + x % 4] / 16, and the blur averages one
// 4 x 4 period, so the pattern leaves no trace.
export const BAYER4: StaticArray<u32> = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];

// SSAO's taps per estimate, the turns of their spiral, and the detail
// estimate's radius as a fraction of ssao_radius.
export const SSAO_SAMPLES: i32 = 12;
export const SSAO_TURNS: f32 = 7;
export const SSAO_DETAIL_RADIUS: f32 = 0.25;

// A tap occludes only when it rises above the pixel's tangent plane by more
// than its depth / 1024: the normal-depth target is half float (11 bits of
// mantissa), so without this margin its rounding alone drew bands on flat
// walls and speckle on curved surfaces.
export const SSAO_DEPTH_BIAS: f32 = 0.0009765625; // 1 / 1024

// What FrameRenderer.warnings says when a frame asks for post-processing
// the device cannot draw (its main target is the rgba8unorm fallback, which
// holds no HDR colour); the frame is then drawn as if it asked for none.
export const POST_HALF_FLOAT_WARNING = "post-processing is not drawn: the device has no half-float render target";

// What a frame's post-processing runs (`planPost`). Empty (`any()` false)
// for every frame that asks for none: nothing runs and nothing changes.
export class PostPlan {
    // The normal-depth, SSAO and blur passes; the main pass reads the result.
    ssao: bool = false;
    // The glow's bright pass and levels, and the final pass adds them.
    glow: bool = false;
    // The final pass applies brightness, contrast and saturation.
    adjust: bool = false;
    // The main pass writes HDR colour (the lit block's tone map is linear at
    // exposure 1) and the final pass exposes and tone maps it: set with glow,
    // which must see the colour before its tone map.
    toneInPost: bool = false;
    // The highest glow level with a weight (1..GLOW_LEVELS), 0 without glow.
    glowLevels: i32 = 0;
    // GLOW_LEVELS weights (`glowWeights`), zeros without glow.
    weights: Array<f32> = [0, 0, 0, 0, 0, 0, 0];
    // Set when the frame asked for post-processing the device cannot draw
    // (POST_HALF_FLOAT_WARNING); the plan is then empty.
    warning: string = "";
    // Milestone 62 (see the header): the reflections, the screen-space
    // refraction (the frame has a material that refracts) and the depth of
    // field; the normal-depth pass (`prepass`: SSAO, reflections or depth
    // of field), the main pass in two (`split`: reflections or
    // refraction), the screen texture's mips (0 without the split), the
    // reflections' target size (0 x 0 without them), the gather's (0 x 0
    // without depth of field). All off, 0, for a frame that turns none on.
    ssr: bool = false;
    refraction: bool = false;
    dof: bool = false;
    prepass: bool = false;
    split: bool = false;
    screenLevels: i32 = 0;
    ssrWidth: u32 = 0;
    ssrHeight: u32 = 0;
    dofWidth: u32 = 0;
    dofHeight: u32 = 0;

    // Any pass runs.
    any(): bool {
        return this.ssao || this.glow || this.adjust || this.ssr || this.refraction || this.dof;
    }

    // The final pass (fs_post) runs.
    final(): bool {
        return this.glow || this.adjust || this.ssr || this.refraction || this.dof;
    }
}

// Where glowDrawn works out the weights, so that asking allocates nothing.
const weightsScratch = new Array<f32>(GLOW_LEVELS);

// Godot's glow level weights: glow_levels/1 .. /7 (negative read as 0),
// divided by their sum when `normalized` (all 0 when the sum is), each
// times glow_intensity (negative read as 0) in every blend mode but mix. A
// missing level is 0. Godot 4.4 ignores glow_intensity under mix: its
// renderer (renderer_scene_render_rd.cpp) hands the tonemap shader
// glow_mix in the intensity's place, and the shader mixes the raw sum of
// the levels by it, so here the weights are left unscaled and the final
// pass mixes by glow_mix.
export function glowWeights(g: GlowDesc): Array<f32> {
    return glowWeightsInto(g, new Array<f32>(GLOW_LEVELS));
}

// `glowWeights` into `out` (GLOW_LEVELS long, its storage kept), returned.
function glowWeightsInto(g: GlowDesc, out: Array<f32>): Array<f32> {
    out.length = GLOW_LEVELS;
    let sum: f32 = 0;
    for (let i = 0; i < GLOW_LEVELS; i++) {
        if (i < g.levels.length) sum += max<f32>(g.levels[i], 0);
    }
    const intensity: f32 = g.blendMode == GLOW_BLEND_MIX ? 1 : max<f32>(g.intensity, 0);
    for (let i = 0; i < GLOW_LEVELS; i++) {
        let v: f32 = i < g.levels.length ? max<f32>(g.levels[i], 0) : 0;
        if (g.normalized) v = sum > 0 ? v / sum : 0;
        out[i] = v * intensity;
    }
    return out;
}

// The glow shows: it is enabled, some level has a weight and, under mix,
// glow_mix is above 0 (at 0 mix draws the picture alone).
export function glowDrawn(g: GlowDesc): bool {
    if (!g.enabled) return false;
    if (g.blendMode == GLOW_BLEND_MIX && !(g.mix > 0)) return false;
    const w = glowWeightsInto(g, weightsScratch);
    for (let i = 0; i < w.length; i++) {
        if (w[i] > 0) return true;
    }
    return false;
}

// What frame `f` runs. `halfFloat`: the renderer's main target holds HDR
// colour (rgba16float); without it a frame asking for post-processing gets
// an empty plan and POST_HALF_FLOAT_WARNING.
export function planPost(f: RenderFrame, halfFloat: bool): PostPlan {
    return planPostInto(f, halfFloat, new PostPlan());
}

// `planPost` into `out`, returned (milestone 13; see shadow.as
// `planShadowsInto`): every field set again, the weights written in place,
// so planning the same frame again allocates nothing. The same plan
// exactly (`planPost` fills a new one). `main`, when given, is the view's
// culling (cull.as CullResult.main): the screen refraction is then planned
// only for glass the main pass draws (frameRefracts).
export function planPostInto(f: RenderFrame, halfFloat: bool, out: PostPlan, main: Array<u8>? = null): PostPlan {
    const p = out;
    p.ssao = false;
    p.glow = false;
    p.adjust = false;
    p.toneInPost = false;
    p.glowLevels = 0;
    p.weights.length = GLOW_LEVELS;
    for (let i = 0; i < GLOW_LEVELS; i++) p.weights[i] = 0;
    p.warning = "";
    p.ssr = false;
    p.refraction = false;
    p.dof = false;
    p.prepass = false;
    p.split = false;
    p.screenLevels = 0;
    p.ssrWidth = 0;
    p.ssrHeight = 0;
    p.dofWidth = 0;
    p.dofHeight = 0;
    if (f.shading != SHADE_LIT) return p;
    const e = f.environment;
    const glow = glowDrawn(e.glow);
    const ssao = e.ssao.enabled;
    const adjust = e.adjustment.enabled;
    // Milestone 62: each only where the view may draw it (screenEffects),
    // the refraction only for a frame with a material that refracts.
    const mask = f.screenEffects;
    const ssr = e.ssr.enabled && (mask & SCREEN_SSR) != 0;
    const refraction = e.screenRefraction.enabled && (mask & SCREEN_REFRACTION) != 0 && frameRefracts(f, main);
    const dof = dofDrawn(f.dof) && (mask & SCREEN_DOF) != 0;
    if (!glow && !ssao && !adjust && !ssr && !refraction && !dof) return p;
    if (!halfFloat) {
        p.warning = POST_HALF_FLOAT_WARNING;
        return p;
    }
    p.ssao = ssao;
    p.glow = glow;
    p.adjust = adjust;
    p.toneInPost = glow || ssr || refraction || dof;
    p.ssr = ssr;
    p.refraction = refraction;
    p.dof = dof;
    p.prepass = ssao || ssr || dof;
    p.split = ssr || refraction;
    const ssaa = max<u32>(f.ssaa, 1);
    const pxW = f.width * ssaa;
    const pxH = f.height * ssaa;
    if (p.split) p.screenLevels = screenLevelCount(pxW, pxH);
    if (ssr) {
        const half = f.screenQuality.ssrHalfSize;
        // (at a quarter from SSR_QUARTER_HEIGHT on, or from
        // SSR_QUARTER_SIZE_HEIGHT with quarter_size: screen.as ssrQuarter)
        const quarter = ssrQuarter(pxH, half, f.screenQuality.ssrQuarterSize);
        p.ssrWidth = ssrSide(pxW, half, quarter);
        p.ssrHeight = ssrSide(pxH, half, quarter);
    }
    if (dof) {
        p.dofWidth = dofSide(pxW);
        p.dofHeight = dofSide(pxH);
    }
    if (glow) {
        glowWeightsInto(e.glow, p.weights);
        // The levels are the mips of one texture the size of level 1, and a
        // texture holds at most floor(log2(longer side)) + 1 mips (WebGPU,
        // Vulkan and D3D11 refuse more): 4 for a 16 x 16 picture, 1 for
        // 2 x 2. Levels beyond that are dropped, their weights zeroed. Level
        // 1 always fits, so a drawn glow keeps at least one level. (Level
        // 1's size is glowLevelSize(f.width, f.height, 1)'s, worked out here
        // without the object.)
        const mips = glowMipLimit(max<u32>((f.width + 1) / 2, 1), max<u32>((f.height + 1) / 2, 1));
        for (let i = 0; i < GLOW_LEVELS; i++) {
            if (i >= mips) p.weights[i] = 0;
            else if (p.weights[i] > 0) p.glowLevels = i + 1;
        }
        if (p.glowLevels == 0) p.glowLevels = 1;
    }
    return p;
}

// Milestone 62: plan `p` without the main pass drawn in two (the renderer's
// fallback when the host refuses the screen texture's pipelines or target:
// gpu/renderer.as SCREEN_PIPELINE_WARNING): no reflections, no screen
// refraction (the glass refracts the environment, as without the
// Environment's switch), no screen texture; the tone map stays in the
// final pass only while the glow or the depth of field still needs it,
// and the normal-depth pass runs only for SSAO or the depth of field.
// Returns `p`, every other field as it was. Allocates nothing.
export function dropSplit(p: PostPlan): PostPlan {
    p.split = false;
    p.ssr = false;
    p.refraction = false;
    p.screenLevels = 0;
    p.ssrWidth = 0;
    p.ssrHeight = 0;
    p.toneInPost = p.glow || p.dof;
    p.prepass = p.ssao || p.dof;
    return p;
}

// Milestone 62: whether frame `f` draws a material range that refracts the
// screen (material.as materialRefracts). Only the items of the frame's own
// world count, only those the main pass draws, and only their drawn ranges
// (cull.as rangeDrawn): the frame's materials are shared with its
// SubViewports' frames, so glass in a SubViewport with a world of its own,
// a next pass's range that is not drawn, glass that only casts shadows
// (cast_shadow shadows only) and, given the view's culling `main`
// (CullResult.main), glass culled out of the view must not split this
// frame's main pass: the split moves the tone map after the MSAA resolve,
// which changes the edges of a picture with no glass in it. Allocates
// nothing.
export function frameRefracts(f: RenderFrame, main: Array<u8>? = null): bool {
    return refractingRanges(f, true, main) > 0;
}

// The material ranges of frame `f`'s own world that are drawn and refract
// the screen (frameRefracts; screenStatsInto's count, as inspect/screen.as
// lists them). With `first`, stops at the first. Allocates nothing.
function refractingRanges(f: RenderFrame, first: bool, main: Array<u8>?): i32 {
    const items = f.items;
    const ms = f.materials;
    let n = 0;
    for (let i = 0; i < items.length; i++) {
        const d = unchecked(items[i]);
        if (d.scenario != f.scenario) continue;
        if (d.castShadow == CAST_SHADOW_SHADOWS_ONLY) continue;
        if (main != null && i < main!.length && unchecked(main![i]) != CULL_DRAWN) continue;
        for (let k = 0; k < d.materials.length; k++) {
            if (!rangeDrawn(d, k)) continue;
            const key = unchecked(d.materials[k]);
            if (key >= 0 && key < <i64>ms.length && materialRefracts(unchecked(ms[<i32>key]))) {
                n++;
                if (first) return n;
            }
        }
    }
    return n;
}

// Milestone 62: what frame `f`'s plan `plan` comes to (render's `screen`,
// inspect --stats, the editor's statistics), into `out` (every field set;
// nothing allocated): the reflections' size and steps, the material ranges
// that refract the screen, the screen texture, the depth of field's
// sides, its radius in pixels, its gather's size and taps, and the passes
// the effects add (the screen texture's copy and its mips; the trace; the
// second main pass; the circle of confusion, the gather and the
// composition). `main` is the view's culling, as planPostInto takes it.
export function screenStatsInto(
    f: RenderFrame, plan: PostPlan, out: ScreenStats, main: Array<u8>? = null,
): ScreenStats {
    out.reset();
    const ssaa = max<u32>(f.ssaa, 1);
    const pxW = f.width * ssaa;
    const pxH = f.height * ssaa;
    if (plan.ssr) {
        out.ssr = true;
        out.ssrWidth = plan.ssrWidth;
        out.ssrHeight = plan.ssrHeight;
        out.ssrSteps = ssrSteps(f.environment.ssr);
        // (the trace, and at a size not the render's the trace-size copy of
        // what its march reads: gpu/ssr.as)
        out.passes += plan.ssrWidth != pxW || plan.ssrHeight != pxH ? 2 : 1;
    }
    if (plan.refraction) {
        out.refraction = true;
        out.refractingRanges = refractingRanges(f, false, main);
    }
    if (plan.split) {
        out.screenWidth = pxW;
        out.screenHeight = pxH;
        out.screenLevels = plan.screenLevels;
        out.passes += plan.screenLevels + 1;
    }
    if (plan.dof) {
        out.dof = true;
        out.dofFar = f.dof.farEnabled;
        out.dofNear = f.dof.nearEnabled;
        out.dofRadiusPx = dofRadiusPx(f.dof, pxH);
        out.dofWidth = plan.dofWidth;
        out.dofHeight = plan.dofHeight;
        const q = <i32>min<u32>(f.screenQuality.dofQuality, <u32>(DOF_TAPS.length - 1));
        out.dofTaps = DOF_TAPS[q];
        out.passes += 3;
    }
    return out;
}

// The most mips a texture `width` x `height` holds: floor(log2(longer
// side)) + 1.
export function glowMipLimit(width: u32, height: u32): i32 {
    return 32 - <i32>clz<u32>(max<u32>(max<u32>(width, height), 1));
}

// A glow level's size in texels.
export class LevelSize {
    width: u32;
    height: u32;

    constructor(width: u32, height: u32) {
        this.width = width;
        this.height = height;
    }
}

// Glow level `level` (1..GLOW_LEVELS) of a picture `width` x `height`
// (before SSAA, so the glow reaches as far at any --ssaa): level 1 is each
// side halved, rounded up, and level k mip k - 1 of it (halved k - 1
// times, rounded down, at least 1), since the levels are the mips of one
// texture (gpu/renderer.as `postChain`, as Godot keeps them).
export function glowLevelSize(width: u32, height: u32, level: i32): LevelSize {
    return new LevelSize(glowLevelSide(width, level), glowLevelSide(height, level));
}

// One side of glowLevelSize's (the renderer's per-frame form: no object).
export function glowLevelSide(side: u32, level: i32): u32 {
    const half = max<u32>((side + 1) / 2, 1);
    return max<u32>(half >> <u32>(level - 1), 1);
}

function sizeVec(w: u32, h: u32): Vec4 {
    return Vec4(<f32>w, <f32>h, <f32>1.0 / <f32>w, <f32>1.0 / <f32>h);
}

// The render size's block vector (before SSAA times the factor).
function renderSizeVec(f: RenderFrame): Vec4 {
    const ssaa = max<u32>(f.ssaa, 1);
    return sizeVec(f.width * ssaa, f.height * ssaa);
}

function glowLevelVec(f: RenderFrame, level: i32): Vec4 {
    return sizeVec(glowLevelSide(f.width, level), glowLevelSide(f.height, level));
}

// Every field of `u` as a new PostUniform's, so that an `*Into` form
// filling a kept block gives exactly what its allocating form gives.
function clearPostUniform(u: PostUniform): void {
    const z = Vec4(0, 0, 0, 0);
    u.target = z;
    u.source = z;
    u.flags = U32x4(0, 0, 0, 0);
    u.tone = z;
    u.glow = z;
    u.levelsLow = z;
    u.levelsHigh = z;
    u.bcs = z;
    u.ssao = z;
    u.ssao2 = z;
    const id = Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));
    u.invProj = id;
    u.proj = id;
}

// The block of fs_ssao and fs_ssao_blur: target and source the render size,
// the SSAO properties (radius at least 1e-3, horizon and sharpness clamped
// to 0..1), the pixels a world unit spans at view depth 1 (at any depth in
// an orthographic view), the projection and its inverse.
export function ssaoUniform(f: RenderFrame): PostUniform {
    return ssaoUniformInto(f, new PostUniform());
}

// `ssaoUniform` into `out` (every field written; nothing allocated: the
// renderer's per-frame form, milestone 13).
export function ssaoUniformInto(f: RenderFrame, out: PostUniform): PostUniform {
    clearPostUniform(out);
    const px = renderSizeVec(f);
    out.target = px;
    out.source = px;
    const s = f.environment.ssao;
    out.ssao = Vec4(max<f32>(s.radius, 1e-3), s.intensity, s.power, s.detail);
    const cam = f.camera;
    const perPixel = cam.worldPerPixel(1, f.height * max<u32>(f.ssaa, 1));
    out.ssao2 = Vec4(
        min<f32>(max<f32>(s.horizon, 0), 1), min<f32>(max<f32>(s.sharpness, 0), 1),
        <f32>1.0 / max<f32>(perPixel, 1e-9), cam.isOrtho() ? 1 : 0,
    );
    const proj = cam.projectionMatrix(<f32>f.width / <f32>f.height);
    out.proj = proj;
    out.invProj = proj.inverse();
    // (milestone 67: traced at half size, blurred back up; flags 0 as
    // before at full size)
    if (f.renderQuality.ssaoHalfSize) out.flags = U32x4(POST_SSAO_HALF, 0, 0, 0);
    return out;
}

// The block of fs_glow_bright: target level 1, source the render size, the
// SSAA factor (the block averaged is 2 x it on a side), exposure and the
// threshold's properties.
export function glowBrightUniform(f: RenderFrame): PostUniform {
    return glowBrightUniformInto(f, new PostUniform());
}

// `glowBrightUniform` into `out` (every field written; nothing allocated).
export function glowBrightUniformInto(f: RenderFrame, out: PostUniform): PostUniform {
    clearPostUniform(out);
    out.target = glowLevelVec(f, 1);
    out.source = renderSizeVec(f);
    out.flags = U32x4(0, 0, 0, max<u32>(f.ssaa, 1));
    const e = f.environment;
    const g = e.glow;
    out.tone = Vec4(e.exposure, e.white, g.mix, g.strength);
    out.glow = Vec4(g.hdrThreshold, max<f32>(g.hdrScale, 1e-4), g.hdrLuminanceCap, g.bloom);
    return out;
}

// The block of level `level`'s horizontal (`vertical` false: fs_glow_blur_h)
// or vertical blur: target the level; source the bright pass or level - 1
// (horizontal: POST_DOWNSAMPLE after level 1) or the level itself
// (vertical); glow_strength in tone.w.
export function glowBlurUniform(f: RenderFrame, level: i32, vertical: bool): PostUniform {
    return glowBlurUniformInto(f, level, vertical, new PostUniform());
}

// `glowBlurUniform` into `out` (every field written; nothing allocated).
export function glowBlurUniformInto(f: RenderFrame, level: i32, vertical: bool, out: PostUniform): PostUniform {
    clearPostUniform(out);
    const size = glowLevelVec(f, level);
    out.target = size;
    if (vertical || level <= 1) {
        out.source = size;
    } else {
        out.source = glowLevelVec(f, level - 1);
        out.flags = U32x4(POST_DOWNSAMPLE, 0, 0, 0);
    }
    const e = f.environment;
    out.tone = Vec4(e.exposure, e.white, e.glow.mix, e.glow.strength);
    return out;
}

// The block of fs_post: target and source the render size; the plan's
// POST_* bits, the tone map and the glow's blend mode; exposure, white,
// glow_mix; the level weights (zeros without glow); the adjustments.
export function postFinalUniform(f: RenderFrame, plan: PostPlan): PostUniform {
    return postFinalUniformInto(f, plan, new PostUniform());
}

// `postFinalUniform` into `out` (every field written; nothing allocated).
export function postFinalUniformInto(f: RenderFrame, plan: PostPlan, out: PostUniform): PostUniform {
    clearPostUniform(out);
    const px = renderSizeVec(f);
    out.target = px;
    out.source = px;
    const e = f.environment;
    let bits: u32 = 0;
    if (plan.toneInPost) bits |= POST_TONEMAP;
    if (plan.glow) bits |= POST_GLOW;
    if (plan.adjust) bits |= POST_ADJUST;
    if (f.transparent) bits |= POST_STRAIGHT;
    out.flags = U32x4(bits, e.tonemap, e.glow.blendMode, 0);
    out.tone = Vec4(e.exposure, e.white, e.glow.mix, e.glow.strength);
    if (plan.glow) {
        const w = plan.weights;
        out.levelsLow = Vec4(w[0], w[1], w[2], w[3]);
        out.levelsHigh = Vec4(w[4], w[5], w[6], 0);
    }
    const a = e.adjustment;
    out.bcs = Vec4(a.brightness, a.contrast, a.saturation, 0);
    return out;
}

// The angle a pixel turns its SSAO spiral by (radians).
export function ssaoAngle(x: u32, y: u32): f32 {
    return <f32>2.0 * <f32>Math.PI * <f32>BAYER4[<i32>((y & 3) * 4 + (x & 3))] / <f32>16.0;
}

// ---------------------------------------------------------------- CPU references
//
// The arithmetic of the shaders, on one colour, for the tests (and for the
// adapter's clear colour, which no shader draws). The formulas are the
// spec's, channel by channel in f32; sRGB is the exact curve
// (hedra_engine/base/color `linearToSrgb`, the shaders' `linear_to_srgb`).

function sat(x: f32): f32 {
    return min<f32>(max<f32>(x, 0), 1);
}

function sat3(c: Vec3): Vec3 {
    return Vec3(sat(c.x), sat(c.y), sat(c.z));
}

function srgb3(c: Vec3): Vec3 {
    return Vec3(linearToSrgb(c.x), linearToSrgb(c.y), linearToSrgb(c.z));
}

// WGSL's mix: a (1 - t) + b t, so t = 1 gives b exactly (MIX at glow_mix 1
// shows the glow alone, not the glow plus a rounding of the colour).
function mixF(a: f32, b: f32, t: f32): f32 {
    return a * (<f32>1 - t) + b * t;
}

function mix3(a: Vec3, b: Vec3, t: f32): Vec3 {
    return Vec3(mixF(a.x, b.x, t), mixF(a.y, b.y, t), mixF(a.z, b.z, t));
}

function smoothstepF(e0: f32, e1: f32, x: f32): f32 {
    const t = sat((x - e0) / (e1 - e0));
    return t * t * (<f32>3 - <f32>2 * t);
}

// Godot's filmic curve (surface.wgsl filmic_curve, exposure bias 2 baked
// into A and B), the same operations as lights.as's, so the clear colour
// and this reference agree to the bit.
function filmicCurve(x: f32): f32 {
    const a: f32 = 0.22 * 4.0;
    const b: f32 = 0.30 * 2.0;
    const c: f32 = 0.10;
    const d: f32 = 0.20;
    const e: f32 = 0.01;
    const f: f32 = 0.30;
    return (x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f) - e / f;
}

// Godot 4's tonemap_aces: the exposure bias its RRT matrix carries, and
// the fitted RRT + ODT curve per channel.
const ACES_BIAS: f32 = 1.8;

function acesCurve(x: f32): f32 {
    return (x * (x + <f32>0.0245786) - <f32>0.000090537) / (x * (<f32>0.983729 * x + <f32>0.432951) + <f32>0.238081);
}

function acesTone(c: Vec3, white: f32): Vec3 {
    const k = ACES_BIAS;
    const r = acesCurve(k * (<f32>0.59719 * c.x + <f32>0.35458 * c.y + <f32>0.04823 * c.z));
    const g = acesCurve(k * (<f32>0.07600 * c.x + <f32>0.90834 * c.y + <f32>0.01566 * c.z));
    const b = acesCurve(k * (<f32>0.02840 * c.x + <f32>0.13383 * c.y + <f32>0.83777 * c.z));
    const w = acesCurve(k * white);
    return Vec3(
        (<f32>1.60475 * r - <f32>0.53108 * g - <f32>0.07367 * b) / w,
        (<f32>-0.10208 * r + <f32>1.10813 * g - <f32>0.00605 * b) / w,
        (<f32>-0.00327 * r - <f32>0.07276 * g + <f32>1.07602 * b) / w,
    );
}

// Godot 4.4's tonemap_agx (surface.wgsl agx_curve): the colour kept at
// 2e-10 at least, the combined sRGB to Rec. 2020 and AgX inset matrix, a
// log2 encoding over -12.4739311883324 .. 4.02606881166759 stops, the
// 6th-order fit of the AgX sigmoid, a 2.4 power, then the combined outset
// and Rec. 2020 to sRGB matrix. The matrices are Godot's mat3 literals
// read as columns, written here by rows.
const AGX_MIN_EV: f32 = -12.4739311883324;
const AGX_MAX_EV: f32 = 4.02606881166759;

function agxEncode(x: f32): f32 {
    const l = min<f32>(max<f32>(log2f(x), AGX_MIN_EV), AGX_MAX_EV);
    return (l - AGX_MIN_EV) / (AGX_MAX_EV - AGX_MIN_EV);
}

// agx_contrast_approx, in the order of Godot's GLSL (x2, x4 shared).
function agxContrast(x: f32): f32 {
    const x2 = x * x;
    const x4 = x2 * x2;
    return <f32>0.021 * x + <f32>4.0111 * x2 - <f32>25.682 * x2 * x + <f32>70.359 * x4
        - <f32>74.778 * x4 * x + <f32>27.069 * x4 * x2;
}

function agxPow(x: f32): f32 {
    return powf(max<f32>(x, 1e-10), 2.4);
}

function agxTone(c: Vec3): Vec3 {
    const x = max<f32>(c.x, 2e-10);
    const y = max<f32>(c.y, 2e-10);
    const z = max<f32>(c.z, 2e-10);
    const r = agxPow(agxContrast(agxEncode(
        <f32>0.54490813676363087053 * x + <f32>0.37377945959812267119 * y + <f32>0.081384976686407536266 * z)));
    const g = agxPow(agxContrast(agxEncode(
        <f32>0.14044005884001287035 * x + <f32>0.75410959864013760045 * y + <f32>0.10543358536857773485 * z)));
    const b = agxPow(agxContrast(agxEncode(
        <f32>0.088827411851915368603 * x + <f32>0.17887712465043811023 * y + <f32>0.73224999956948382528 * z)));
    return Vec3(
        <f32>1.9645509602733325934 * r - <f32>0.85585845117807513559 * g - <f32>0.10886710826831608324 * b,
        <f32>-0.29932243390911083839 * r + <f32>1.3264510741502356555 * g - <f32>0.027084020983874825605 * b,
        <f32>-0.16436833806080403409 * r - <f32>0.23822464068860595117 * g + <f32>1.402665347143271889 * b,
    );
}

// Godot's tone curve `mode` (TONEMAP_*) on an exposed colour whose
// negatives are already 0: linear (as is), Reinhard and filmic with
// `white` (surface.wgsl's formulas), ACES (Godot 4's fitted RRT + ODT, with
// `white`), AgX (Godot 4.4's; ignores `white`).
export function toneCurve(c: Vec3, mode: u32, white: f32): Vec3 {
    if (mode == TONEMAP_REINHARD) {
        const w = white;
        return Vec3(
            (w * c.x + c.x) / (c.x * w + w),
            (w * c.y + c.y) / (c.y * w + w),
            (w * c.z + c.z) / (c.z * w + w),
        );
    }
    if (mode == TONEMAP_FILMIC) {
        const fw = filmicCurve(white);
        return Vec3(filmicCurve(c.x) / fw, filmicCurve(c.y) / fw, filmicCurve(c.z) / fw);
    }
    if (mode == TONEMAP_ACES) return acesTone(c, white);
    if (mode == TONEMAP_AGX) return agxTone(c);
    return c;
}

// `toneCurve(max(c * exposure, 0), e.tonemap, e.white)`.
export function toneMap(c: Vec3, e: EnvironmentDesc): Vec3 {
    const x = c * e.exposure;
    return toneCurve(Vec3(max<f32>(x.x, 0), max<f32>(x.y, 0), max<f32>(x.z, 0)), e.tonemap, e.white);
}

// Godot's glow first pass on one (box-filtered) colour: exposed, then kept
// by `max(smoothstep(threshold, threshold + scale, max(r, g, b)), bloom)`
// and capped at the luminance cap. The scale is at least 1e-4, as the
// block carries it (glowBrightUniform), so the step never divides by 0.
export function glowBright(c: Vec3, g: GlowDesc, exposure: f32): Vec3 {
    const x = c * exposure;
    const l = max<f32>(max<f32>(x.x, x.y), x.z);
    const thr = g.hdrThreshold;
    const keep = max<f32>(smoothstepF(thr, thr + max<f32>(g.hdrScale, 1e-4), l), g.bloom);
    const k = x * keep;
    const cap = g.hdrLuminanceCap;
    return Vec3(min<f32>(k.x, cap), min<f32>(k.y, cap), min<f32>(k.z, cap));
}

// Godot's soft light, one channel: `c` the colour (clamped), `g` the glow.
function softLight(x: f32, g: f32): f32 {
    const c = sat(x);
    const h = g * <f32>0.5 + <f32>0.5;
    if (h <= 0.5) return c - (<f32>1 - <f32>2 * h) * c * (<f32>1 - c);
    if (c <= 0.25) return c + (<f32>2 * h - <f32>1) * (<f32>4 * c * (<f32>4 * c + <f32>1) * (c - <f32>1) + <f32>7 * c);
    return c + (<f32>2 * h - <f32>1) * (Mathf.sqrt(c) - c);
}

function screen(x: f32, y: f32): f32 {
    const c = sat(x);
    const g = sat(y);
    return max<f32>(c + g - c * g, 0);
}

// Godot's apply_glow for the modes other than mix: `c` and `glow` are sRGB
// values (glow already tone mapped and encoded). MIX mixes before the tone
// curve (`postPixel`), so here it leaves `c` as it is.
export function glowBlend(c: Vec3, glow: Vec3, mode: u32): Vec3 {
    if (mode == GLOW_BLEND_ADDITIVE) return c + glow;
    if (mode == GLOW_BLEND_SCREEN) return Vec3(screen(c.x, glow.x), screen(c.y, glow.y), screen(c.z, glow.z));
    if (mode == GLOW_BLEND_SOFTLIGHT) {
        return Vec3(softLight(c.x, glow.x), softLight(c.y, glow.y), softLight(c.z, glow.z));
    }
    if (mode == GLOW_BLEND_REPLACE) return glow;
    return c;
}

// Godot's apply_bcs on an sRGB colour.
export function applyBcs(c: Vec3, a: AdjustmentDesc): Vec3 {
    let x = mix3(Vec3(0, 0, 0), c, a.brightness);
    x = mix3(Vec3(0.5, 0.5, 0.5), x, a.contrast);
    const grey = (x.x + x.y + x.z) / <f32>3;
    return mix3(Vec3(grey, grey, grey), x, a.saturation);
}

// fs_post on one pixel: `hdr` the resolved colour (HDR when
// `plan.toneInPost`, else already tone mapped), `glow` the sum of the
// levels there by `glowWeights` (under mix, not scaled by glow_intensity:
// mix blends it in by glow_mix alone); the sRGB result, clamped to 0..1.
export function postPixel(hdr: Vec3, glow: Vec3, e: EnvironmentDesc, plan: PostPlan): Vec3 {
    let c = hdr;
    const blend = e.glow.blendMode;
    if (plan.toneInPost) {
        const x = c * e.exposure;
        c = Vec3(max<f32>(x.x, 0), max<f32>(x.y, 0), max<f32>(x.z, 0));
    }
    if (plan.glow && blend == GLOW_BLEND_MIX) c = mix3(c, glow, e.glow.mix);
    if (plan.toneInPost) c = toneCurve(c, e.tonemap, e.white);
    c = srgb3(sat3(c));
    if (plan.glow && blend != GLOW_BLEND_MIX) {
        const gs = srgb3(sat3(toneCurve(glow, e.tonemap, e.white)));
        c = glowBlend(c, gs, blend);
    }
    if (plan.adjust) c = applyBcs(c, e.adjustment);
    return sat3(c);
}

