// Milestone 62: the screen-space effects, what a frame carries of them and
// Godot's curves as CPU references (docs/engine/SCREEN_EFFECTS.md says how
// each is drawn). Pure: no device, no frame (frame.as imports this module;
// post.as plans the passes from both, `planPostInto`).
//
//   reflections  Godot's Environment ssr_* (SsrDesc): each opaque pixel's
//                mirror ray marched over the normal-depth pass's depth,
//                faded by Godot's curves (ssrStepFade, ssrMarginFade,
//                ssrRoughnessFade) and laid over the surface by its
//                Fresnel weight (ssrMergeWeight); a miss leaves the
//                reflection the surface was drawn with (probes, sky).
//   refraction   the Environment's screen_refraction_enabled (Hedra's;
//                ScreenRefractionDesc): glass (a material with
//                transmission, material.as `materialRefracts`) samples a
//                copy of the opaque picture and its mips (the screen
//                texture) instead of the environment: a thin wall at
//                thinRefractionOffset, a volume where its bent ray leaves
//                it, at refractionLod.
//   depth of     Godot's CameraAttributesPractical dof_blur_* (DofDesc),
//   field        Godot's signed circle of confusion (dofCoc) over a
//                bokeh-shaped gather at half the render size.
//
// Each is off by default and a frame with all three off plans no pass of
// them (post.as): its passes and its picture are what they were before.
// The quality is the project's (Godot's project settings, read from
// hedra.yaml's lines by screenQualityFromSettings), the same for every
// view of a frame.

import { Vec3, Vec4, log2f, powf } from "../base/vecmath";

// --- what a frame carries ---------------------------------------------------

// Godot's Environment screen-space reflections, as the file wrote them
// (the renderer clamps: ssrSteps, and the fades and the tolerance at 0 or
// more).
export class SsrDesc {
    enabled: bool = false;
    maxSteps: i32 = 64;
    fadeIn: f32 = 0.15;
    fadeOut: f32 = 2.0;
    depthTolerance: f32 = 0.2;

    copyFrom(o: SsrDesc): void {
        this.enabled = o.enabled;
        this.maxSteps = o.maxSteps;
        this.fadeIn = o.fadeIn;
        this.fadeOut = o.fadeOut;
        this.depthTolerance = o.depthTolerance;
    }
}

// The Environment's screen_refraction_enabled (Hedra's: Godot refracts the
// screen whenever a material refracts; here an Environment turns it on, so
// that the glass of a scene drawn before keeps its picture).
export class ScreenRefractionDesc {
    enabled: bool = false;

    copyFrom(o: ScreenRefractionDesc): void {
        this.enabled = o.enabled;
    }
}

// Godot's CameraAttributesPractical dof_blur_* of the frame's camera (its
// own `attributes`, else its WorldEnvironment's `camera_attributes`), in
// the frame world's units (metres from the eye along the view).
export class DofDesc {
    farEnabled: bool = false;
    farDistance: f32 = 10;
    farTransition: f32 = 5;
    nearEnabled: bool = false;
    nearDistance: f32 = 2;
    nearTransition: f32 = 1;
    amount: f32 = 0.1;

    copyFrom(o: DofDesc): void {
        this.farEnabled = o.farEnabled;
        this.farDistance = o.farDistance;
        this.farTransition = o.farTransition;
        this.nearEnabled = o.nearEnabled;
        this.nearDistance = o.nearDistance;
        this.nearTransition = o.nearTransition;
        this.amount = o.amount;
    }
}

// Whether `d` blurs anything: a side enabled and an amount above 0.
export function dofDrawn(d: DofDesc): bool {
    return (d.farEnabled || d.nearEnabled) && d.amount > 0;
}

// --- quality: Godot's project settings ---------------------------------------

// rendering/environment/screen_space_reflection/roughness_quality.
export const SSR_ROUGHNESS_DISABLED: u32 = 0;
export const SSR_ROUGHNESS_LOW: u32 = 1;
export const SSR_ROUGHNESS_MEDIUM: u32 = 2;
export const SSR_ROUGHNESS_HIGH: u32 = 3;
export const SSR_ROUGHNESS_QUALITY_NAMES: StaticArray<string> = ["disabled", "low", "medium", "high"];

// rendering/camera/depth_of_field/depth_of_field_bokeh_shape.
export const DOF_SHAPE_BOX: u32 = 0;
export const DOF_SHAPE_HEXAGON: u32 = 1;
export const DOF_SHAPE_CIRCLE: u32 = 2;
export const DOF_SHAPE_NAMES: StaticArray<string> = ["box", "hexagon", "circle"];

// rendering/camera/depth_of_field/depth_of_field_bokeh_quality.
export const DOF_QUALITY_VERY_LOW: u32 = 0;
export const DOF_QUALITY_LOW: u32 = 1;
export const DOF_QUALITY_MEDIUM: u32 = 2;
export const DOF_QUALITY_HIGH: u32 = 3;
export const DOF_QUALITY_NAMES: StaticArray<string> = ["very_low", "low", "medium", "high"];

// The gather's taps by DOF_QUALITY_* (the centre's not counted).
export const DOF_TAPS: StaticArray<i32> = [8, 16, 32, 64];

// The settings' keys in hedra.yaml (Godot's project.godot names).
export const SETTING_SSR_ROUGHNESS_QUALITY = "rendering/environment/screen_space_reflection/roughness_quality";
// (half_size is Hedra's: Godot 4.4 always traces at half the internal
// size, ss_effects.cpp ssr_allocate_buffers, and has no such setting; the
// key sits beside Godot's roughness_quality.)
export const SETTING_SSR_HALF_SIZE = "rendering/environment/screen_space_reflection/half_size";
// (quarter_size is Hedra's too: with half_size, a render 1,080 pixels tall
// or more traces at a quarter of its size rather than only from 2,160
// (ssrQuarter); the low preset's, the website's, which brings the
// reflections within their cost at 1920 x 1080.)
export const SETTING_SSR_QUARTER_SIZE = "rendering/environment/screen_space_reflection/quarter_size";
export const SETTING_DOF_SHAPE = "rendering/camera/depth_of_field/depth_of_field_bokeh_shape";
export const SETTING_DOF_QUALITY = "rendering/camera/depth_of_field/depth_of_field_bokeh_quality";
export const SETTING_DOF_JITTER = "rendering/camera/depth_of_field/depth_of_field_use_jitter";
export const SCREEN_SETTING_KEYS: StaticArray<string> = [
    SETTING_SSR_ROUGHNESS_QUALITY, SETTING_SSR_HALF_SIZE, SETTING_SSR_QUARTER_SIZE, SETTING_DOF_SHAPE, SETTING_DOF_QUALITY,
    SETTING_DOF_JITTER,
];

// The effects' quality, the same for every view of a frame: Godot's
// defaults (roughness quality low, half size on, a hexagon at low quality,
// no jitter), and Hedra's quarter size off.
export class ScreenQuality {
    ssrRoughnessQuality: u32 = SSR_ROUGHNESS_LOW;
    ssrHalfSize: bool = true;
    ssrQuarterSize: bool = false;
    dofShape: u32 = DOF_SHAPE_HEXAGON;
    dofQuality: u32 = DOF_QUALITY_LOW;
    dofJitter: bool = false;

    copyFrom(o: ScreenQuality): void {
        this.ssrRoughnessQuality = o.ssrRoughnessQuality;
        this.ssrHalfSize = o.ssrHalfSize;
        this.ssrQuarterSize = o.ssrQuarterSize;
        this.dofShape = o.dofShape;
        this.dofQuality = o.dofQuality;
        this.dofJitter = o.dofJitter;
    }

    equals(o: ScreenQuality): bool {
        return this.ssrRoughnessQuality == o.ssrRoughnessQuality && this.ssrHalfSize == o.ssrHalfSize
            && this.ssrQuarterSize == o.ssrQuarterSize && this.dofShape == o.dofShape && this.dofQuality == o.dofQuality && this.dofJitter == o.dofJitter;
    }
}

// Three presets of the quality (render's --screen-quality, the editor's
// View › Screen Quality: Low, Medium and High, the cost tables), each
// setting everything but the bokeh's shape (a look, not a cost):
//   low     roughness quality low, half size and a quarter from 1,080
//           lines (quarter_size), bokeh very low (the website's)
//   medium  roughness quality medium, half size, bokeh low
//   high    roughness quality high, full size, bokeh high
// Godot's defaults (the project's when it sets none) lie between low and
// medium: roughness low, half size, bokeh low.
export const SCREEN_QUALITY_LOW: i32 = 0;
export const SCREEN_QUALITY_MEDIUM: i32 = 1;
export const SCREEN_QUALITY_HIGH: i32 = 2;
export const SCREEN_QUALITY_NAMES: StaticArray<string> = ["low", "medium", "high"];

// `out` set to preset `preset` (SCREEN_QUALITY_*; out of range: high), its
// shape and jitter kept. Returns `out`.
export function screenQualityPreset(preset: i32, out: ScreenQuality): ScreenQuality {
    if (preset == SCREEN_QUALITY_LOW) {
        out.ssrRoughnessQuality = SSR_ROUGHNESS_LOW;
        out.ssrHalfSize = true;
        out.ssrQuarterSize = true;
        out.dofQuality = DOF_QUALITY_VERY_LOW;
    } else if (preset == SCREEN_QUALITY_MEDIUM) {
        out.ssrRoughnessQuality = SSR_ROUGHNESS_MEDIUM;
        out.ssrHalfSize = true;
        out.ssrQuarterSize = false;
        out.dofQuality = DOF_QUALITY_LOW;
    } else {
        out.ssrRoughnessQuality = SSR_ROUGHNESS_HIGH;
        out.ssrHalfSize = false;
        out.ssrQuarterSize = false;
        out.dofQuality = DOF_QUALITY_HIGH;
    }
    return out;
}

// The index of `name` in `names`, or -1.
export function settingChoice(names: StaticArray<string>, name: string): i32 {
    for (let i = 0; i < names.length; i++) {
        if (names[i] == name) return i;
    }
    return -1;
}

// `out` set from the settings `text` (hedra.yaml's lines, `key: value`, `#`
// comments; the keys above, the others ignored), each key it does not set
// left as it was; a value that is not one of a key's adds a warning
// ("hedra.yaml: <key> is <value>, not one of low, medium, ...") and leaves
// it. A choice is its name or its number (Godot writes the number); a bool
// true, false, 1 or 0. Returns `out`.
export function screenQualityFromSettings(text: string, out: ScreenQuality, warnings: Array<string>): ScreenQuality {
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const line = stripComment(lines[i]).trim();
        const colon = line.indexOf(":");
        if (colon <= 0) continue;
        const key = line.substring(0, colon).trim();
        const value = unquote(line.substring(colon + 1).trim());
        if (key == SETTING_SSR_ROUGHNESS_QUALITY) {
            const c = choiceOf(SSR_ROUGHNESS_QUALITY_NAMES, value);
            if (c >= 0) out.ssrRoughnessQuality = <u32>c;
            else warnings.push(badSetting(key, value, SSR_ROUGHNESS_QUALITY_NAMES));
        } else if (key == SETTING_DOF_SHAPE) {
            const c = choiceOf(DOF_SHAPE_NAMES, value);
            if (c >= 0) out.dofShape = <u32>c;
            else warnings.push(badSetting(key, value, DOF_SHAPE_NAMES));
        } else if (key == SETTING_DOF_QUALITY) {
            const c = choiceOf(DOF_QUALITY_NAMES, value);
            if (c >= 0) out.dofQuality = <u32>c;
            else warnings.push(badSetting(key, value, DOF_QUALITY_NAMES));
        } else if (key == SETTING_SSR_HALF_SIZE || key == SETTING_SSR_QUARTER_SIZE || key == SETTING_DOF_JITTER) {
            const b = boolOf(value);
            if (b < 0) {
                warnings.push("hedra.yaml: " + key + " is " + value + ", not true or false");
            } else if (key == SETTING_SSR_HALF_SIZE) {
                out.ssrHalfSize = b == 1;
            } else if (key == SETTING_SSR_QUARTER_SIZE) {
                out.ssrQuarterSize = b == 1;
            } else {
                out.dofJitter = b == 1;
            }
        }
    }
    return out;
}

function choiceOf(names: StaticArray<string>, value: string): i32 {
    const byName = settingChoice(names, value);
    if (byName >= 0) return byName;
    for (let i = 0; i < names.length; i++) {
        if (value == i.toString()) return i;
    }
    return -1;
}

// 1 true, 0 false, -1 neither.
function boolOf(value: string): i32 {
    if (value == "true" || value == "1") return 1;
    if (value == "false" || value == "0") return 0;
    return -1;
}

function badSetting(key: string, value: string, names: StaticArray<string>): string {
    let list = "";
    for (let i = 0; i < names.length; i++) list += (i > 0 ? ", " : "") + names[i];
    return "hedra.yaml: " + key + " is " + value + ", not one of " + list;
}

// `line` up to a `#` outside quotes.
function stripComment(line: string): string {
    let q = 0;
    for (let i = 0; i < line.length; i++) {
        const c = line.charCodeAt(i);
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == 34 || c == 39) {
            q = c;
        } else if (c == 35) {
            return line.substring(0, i);
        }
    }
    return line;
}

function unquote(v: string): string {
    if (v.length >= 2) {
        const a = v.charCodeAt(0);
        if ((a == 34 || a == 39) && v.charCodeAt(v.length - 1) == a) return v.substring(1, v.length - 1);
    }
    return v;
}

// --- which effects a view may draw --------------------------------------------

// RenderFrame.screenEffects bits: the effects a view draws when its scene
// turns them on (the editor's View › Screen-Space Effects, render's --ssr,
// --screen-refraction and --dof off clear one). All by default.
export const SCREEN_SSR: u32 = 1;
export const SCREEN_REFRACTION: u32 = 2;
export const SCREEN_DOF: u32 = 4;
export const SCREEN_EFFECTS_ALL: u32 = 7;

// --- sizes and limits -----------------------------------------------------------

// The screen texture's mips at most (level 0 the render size): rough glass
// and rough reflections read up to level SCREEN_LEVELS_MAX - 1, 1/128 of
// the picture.
export const SCREEN_LEVELS_MAX: i32 = 8;

// Godot's ssr_max_steps range.
export const SSR_STEPS_MIN: i32 = 1;
export const SSR_STEPS_MAX: i32 = 512;

// The halvings that refine a reflection's hit after the march.
export const SSR_REFINE_STEPS: i32 = 4;

// The blur's radius at dof_blur_amount 1, in pixels of a picture 1080
// pixels high (Godot's bokeh size, 64 times the amount), scaled with the
// render height so that a picture drawn at twice the density blurs as far.
export const DOF_SIZE_AT_1080: f32 = 64;

// The screen texture's mips for a render `width` x `height`: as many as
// the size holds (floor(log2(longer side)) + 1), at most SCREEN_LEVELS_MAX.
export function screenLevelCount(width: u32, height: u32): i32 {
    const m = max<u32>(max<u32>(width, height), 1);
    return min<i32>(32 - <i32>clz<u32>(m), SCREEN_LEVELS_MAX);
}

// The render height from which half_size traces the reflections at a
// quarter of the render size rather than a half: a picture of 1080 lines
// drawn at a density of 2 (the website on a high-density screen), whose
// march at half size would cost four times what it costs at 1080 lines
// for texels a quarter the size on the screen. At a quarter, its texels
// cover as much of the picture as at 1080 lines, and cost the same.
export const SSR_QUARTER_HEIGHT: u32 = 2160;
// The height from which it does so with ScreenQuality.ssrQuarterSize too
// (quarter_size, the low preset's): at 1920 x 1080 the trace is then 480 x
// 270, and the merge's upsample, which weighs each texel by its depth's
// difference from the pixel's, keeps the edges; the trace costs a third
// of what it costs at half size (SCREEN_EFFECTS.md, "Costs").
export const SSR_QUARTER_SIZE_HEIGHT: u32 = 1080;

// Whether a render `pxH` pixels tall traces its reflections at a quarter
// of its size with ScreenQuality.ssrHalfSize `half` and ssrQuarterSize
// `quarterSize` (SSR_QUARTER_HEIGHT, SSR_QUARTER_SIZE_HEIGHT).
export function ssrQuarter(pxH: u32, half: bool, quarterSize: bool = false): bool {
    return half && pxH >= (quarterSize ? SSR_QUARTER_SIZE_HEIGHT : SSR_QUARTER_HEIGHT);
}

// One side of the reflections' target for a render side `px`: halved
// (rounded up) with ScreenQuality.ssrHalfSize, quartered (rounded up)
// with `quarter` too (ssrQuarter), else the side.
export function ssrSide(px: u32, half: bool, quarter: bool = false): u32 {
    if (!half) return max<u32>(px, 1);
    return quarter ? max<u32>((px + 3) / 4, 1) : max<u32>((px + 1) / 2, 1);
}

// One side of the depth of field's gather (half the render side, rounded
// up).
export function dofSide(px: u32): u32 {
    return max<u32>((px + 1) / 2, 1);
}

// ssr_max_steps within Godot's range.
export function ssrSteps(d: SsrDesc): i32 {
    return min<i32>(max<i32>(d.maxSteps, SSR_STEPS_MIN), SSR_STEPS_MAX);
}

// The blur's largest radius in pixels of a render `pxH` pixels high:
// dof_blur_amount (0 to 1) times DOF_SIZE_AT_1080 times pxH / 1080.
export function dofRadiusPx(d: DofDesc, pxH: u32): f32 {
    const a = min<f32>(max<f32>(d.amount, 0), 1);
    return a * DOF_SIZE_AT_1080 * <f32>pxH / <f32>1080;
}

// --- Godot's curves (the shaders' formulas, the tests' references) -------------

function sat(x: f32): f32 {
    return min<f32>(max<f32>(x, 0), 1);
}

function smoothstepF(e0: f32, e1: f32, x: f32): f32 {
    if (e1 == e0) return x < e0 ? 0 : 1;
    const t = sat((x - e0) / (e1 - e0));
    return t * t * (<f32>3 - <f32>2 * t);
}

// Godot's circle of confusion at view depth `z` (metres), in pixels, signed
// (near blur negative), `radius` dofRadiusPx's: far, past far_distance,
// smoothstep(distance, distance + transition, z) * radius; near, before
// near_distance, -(1 - smoothstep(distance - transition, distance, z)) *
// radius; 0 in between; the near side tested first. A transition of 0 is a
// step (GLSL's smoothstep of equal edges is undefined). A negative
// transition is Godot's physically based scaling: far (z - d) / z * radius,
// near -(d - z) / z * radius.
//
// Checked against Godot 4.4's bokeh_dof_raster.glsl `get_blur_size` and
// bokeh_dof.cpp: blur_far_end = distance + transition, blur_near_end =
// distance - transition, `use_physical_*` when that side's transition is
// negative, the physical far d / (begin + d) and near d / (begin - d) with
// d = |begin - z| (the two forms above). Godot leaves the physical near
// side unbounded (an object at a tenth of the distance blurs nine times the
// radius) and caps the gather at 32 pixels when both sides are physical;
// here the near side is held to the radius, which draws the same picture
// (the gather reaches no farther than the radius, and the composition's
// blend is full from 3 pixels) and keeps the half float in range.
export function dofCoc(d: DofDesc, z: f32, radius: f32): f32 {
    if (d.nearEnabled && z < d.nearDistance) {
        if (d.nearTransition < 0) {
            return -min<f32>((d.nearDistance - z) / max<f32>(z, 1e-4), 1) * radius;
        }
        return -(<f32>1 - smoothstepF(d.nearDistance - d.nearTransition, d.nearDistance, z)) * radius;
    }
    if (d.farEnabled && z > d.farDistance) {
        if (d.farTransition < 0) {
            return min<f32>((z - d.farDistance) / max<f32>(z, 1e-4), 1) * radius;
        }
        return smoothstepF(d.farDistance, d.farDistance + d.farTransition, z) * radius;
    }
    return 0;
}

// Godot's fade of a reflection by how far along its march it hit: `steps`
// the steps taken before the hit, of `maxSteps`; grad = (steps + 1) /
// maxSteps, fade_in grad^fadeIn (1 at fadeIn 0), fade_out (1 -
// grad)^fadeOut, their product; above 0.999 it is 1 (Godot 4.4's
// screen_space_reflection.glsl: "precision errors" must not let the
// specular light below leak through a whole reflection). Godot steps a
// pixel a step, so its grad is the distance in pixels over ssr_max_steps;
// Hedra's march strides so that its steps cross the whole picture
// (render/ssr.as), so grad is how far along the clipped ray the hit lies.
export function ssrStepFade(steps: f32, maxSteps: i32, fadeIn: f32, fadeOut: f32): f32 {
    const grad = sat((steps + 1) / <f32>max<i32>(maxSteps, 1));
    const initial: f32 = fadeIn <= 0 ? 1 : powf(grad, max<f32>(fadeIn, 0));
    const fade = powf(<f32>1 - grad, max<f32>(fadeOut, 0)) * initial;
    return fade > <f32>0.999 ? <f32>1 : fade;
}

// Godot's fade at the picture's margin: the hit at (x, y) of a target
// `w` x `h` (in texels, 0 to w), a margin of 5 % of (w + h), and
// smoothstep(0, margin^2, gx gy) of the distances to the nearer edges;
// 0 outside the picture (Godot 4.4's `margin_blend`, exactly).
export function ssrMarginFade(x: f32, y: f32, w: f32, h: f32): f32 {
    if (x < 0 || y < 0 || x > w || y > h) return 0;
    const margin = (w + h) * <f32>0.05;
    const gx = x < w * 0.5 ? x : w - x;
    const gy = y < h * 0.5 ? y : h - y;
    return smoothstepF(0, margin * margin, gx * gy);
}

// Godot's fade by roughness, smoothstep(0.4, 0.7, 1 - roughness): whole
// below 0.3, none above 0.6 (Godot 4.4 also skips the march of a surface
// above 0.6, which the fade's 0 does here: render/ssr.as).
export function ssrRoughnessFade(roughness: f32): f32 {
    return smoothstepF(0.4, 0.7, <f32>1 - roughness);
}

// Schlick's Fresnel of a surface of reflectance `f0` seen at cos `nv`.
export function fresnelSchlickRgb(f0: Vec3, nv: f32): Vec3 {
    const m = sat(<f32>1 - nv);
    const m5 = m * m * m * m * m;
    return Vec3(f0.x + (1 - f0.x) * m5, f0.y + (1 - f0.y) * m5, f0.z + (1 - f0.z) * m5);
}

// How a reflection of fade `fade` is laid over the surface's colour c
// (premultiplied over: c (1 - w.w) + reflection * w.rgb): rgb the Fresnel
// weight per channel times the fade, w the largest of them, so that a
// metal's tint colours the reflection and the surface's own colour is
// taken away by its strongest channel. Godot 4.4 multiplies the
// reflection by a scalar Schlick term of mix(0.04, 1, metallic) and mixes
// it over the specular light alone by the fade (specular_merge.glsl);
// Hedra's forward colour holds diffuse and specular together, so the
// Fresnel weight takes its share of both.
export function ssrMergeWeight(f0: Vec3, nv: f32, fade: f32): Vec4 {
    const f = fresnelSchlickRgb(f0, nv);
    const a = sat(fade);
    return Vec4(f.x * a, f.y * a, f.z * a, max<f32>(max<f32>(f.x, f.y), f.z) * a);
}

// The screen texture's level glass of transmission roughness `rough`
// (sqrt of KHR's alpha * clamp(2 ior - 2, 0, 1), surface.wgsl's
// ext_refracted `rough`) reads in a picture `width` wide: the Khronos
// sample viewer's log2(width) * rough, held to the texture's levels.
export function refractionLod(width: u32, rough: f32, levels: i32): f32 {
    if (levels <= 1) return 0;
    const lod = log2f(<f32>max<u32>(width, 1)) * max<f32>(rough, 0);
    return min<f32>(lod, <f32>(levels - 1));
}

// How far a thin wall moves what it shows, in the picture's UV (x right, y
// down): Godot's -normal.xy * refraction_scale, the view-space normal's y
// turned to the picture's rows.
export function thinRefractionOffset(nView: Vec3, scale: f32): Vec4 {
    return Vec4(-nView.x * scale, nView.y * scale, 0, 0);
}

// --- what a view drew (render's `screen`, inspect --stats) ---------------------

// What post.as `screenStatsInto` makes of a frame's plan: no GPU needed.
export class ScreenStats {
    ssr: bool = false;
    ssrWidth: u32 = 0;
    ssrHeight: u32 = 0;
    ssrSteps: i32 = 0;
    refraction: bool = false;
    // The frame's material ranges that refract the screen (each material
    // range of a drawn item whose material refracts, in the lit shading).
    refractingRanges: i32 = 0;
    screenWidth: u32 = 0;
    screenHeight: u32 = 0;
    screenLevels: i32 = 0;
    dof: bool = false;
    dofFar: bool = false;
    dofNear: bool = false;
    dofRadiusPx: f32 = 0;
    dofWidth: u32 = 0;
    dofHeight: u32 = 0;
    dofTaps: i32 = 0;
    // The passes the effects add to the frame (for the cost tables).
    passes: i32 = 0;

    reset(): void {
        this.ssr = false;
        this.ssrWidth = 0;
        this.ssrHeight = 0;
        this.ssrSteps = 0;
        this.refraction = false;
        this.refractingRanges = 0;
        this.screenWidth = 0;
        this.screenHeight = 0;
        this.screenLevels = 0;
        this.dof = false;
        this.dofFar = false;
        this.dofNear = false;
        this.dofRadiusPx = 0;
        this.dofWidth = 0;
        this.dofHeight = 0;
        this.dofTaps = 0;
        this.passes = 0;
    }

    any(): bool {
        return this.ssr || this.refraction || this.dof;
    }
}
