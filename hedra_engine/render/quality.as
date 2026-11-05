// The render quality a frame is drawn with: the project's settings that
// trade the picture's cost against its look (docs/engine/PERFORMANCE.md),
// in Godot's names where Godot has the setting, written in the project's
// hedra.yaml as Godot writes them in project.godot, one a line:
//
//   rendering/anti_aliasing/quality/msaa_3d: 4x
//   rendering/renderer/rendering_method: forward_plus
//   rendering/driver/depth_prepass/enable: false   (Godot's: true; on the
//                                                   web's runtime true)
//   rendering/driver/depth_prepass/disable_for_vendors: PowerVR,Mali,Adreno,Apple
//   rendering/scaling_3d/mode: bilinear
//   rendering/scaling_3d/scale: 1.0
//   rendering/scaling_3d/fsr_sharpness: 0.2
//   rendering/scaling_3d/max_density: 2.0          (Hedra's)
//   rendering/scaling_3d/max_pixels: 3686400       (Hedra's)
//   rendering/shading/sort_opaque: false           (Hedra's)
//   rendering/shading/specialize_surfaces: true    (Hedra's)
//   rendering/environment/ssao/half_size: false    (Godot's: true)
//
// read by renderQualityFromSettings (a choice by its name or Godot's
// number; a bad value a warning, the key left at its default). A line
// `<key>.web: <value>` (Godot's feature tags: `rendering/scaling_3d/
// scale.web: 0.75`) overrides `<key>` on the web's WebGL 2 runtime,
// whatever their order in the file. The tools
// read the scene's project's file (../source/project/render_settings.as);
// `hedra build` passes the keys' lines in the generated hedra_project.as
// with the screen-space effects' (the sixth argument of registerProject),
// which the run time parses once (../scene/runtime/projects.as), so that
// a built project draws with the quality the tools drew with.
//
// The defaults keep every picture the tools drew before: 4 x MSAA into
// rgba16float, no render scale. Hedra deviates from Godot's defaults there
// (Godot's msaa_3d is disabled by default, which would change every
// picture), and both ways of drawing less overdraw are off by default:
// the depth prepass (Godot's Compatibility renderer enables it, but for
// the vendors of disable_for_vendors, Apple's among them) and the opaque
// sort. Measured on Apple's GPUs, whose hidden-surface removal already
// shades each pixel once, neither gained anything past the noise; the sort
// changes which of two surfaces at exactly the same depth wins (0.27 % of
// the pixels of the baked room's corners). On the website's WebGL 2
// runtime the depth prepass is on unless a line says otherwise
// (WEB_DEPTH_PREPASS): there it took the chess study's menu at a density
// of 2 from 14.2 to 8.7 ms a frame and the demo's corridor from 7.3 to
// 4.4, the pages' pictures the same to the byte, as WebGL 2 through
// ANGLE does not get the hidden-surface removal Metal gives the native
// runtime. SSAO is traced at the picture's full size unless
// ssao/half_size is set: Godot traces it at half size by default, which
// would change every picture with SSAO (it then blurs the half-size
// occlusion back up to the picture's size along the surfaces'
// edges). docs/engine/PERFORMANCE.md says so. The two caps are the
// Scene3D's policy only (a Rive project's root view): `hedra render`
// draws at the size it is given.

import { parseF64, parseI32 } from "../base/parse";

// Godot's Viewport.MSAA (rendering/anti_aliasing/quality/msaa_3d).
export const MSAA_DISABLED: i32 = 0;
export const MSAA_2X: i32 = 1;
export const MSAA_4X: i32 = 2;
export const MSAA_8X: i32 = 3;

// Godot's rendering/renderer/rendering_method, as far as Hedra has it: the
// main pass's colour target, rgba16float (Forward+) or the 32-bit
// r11g11b10float where the host renders and blends it (Mobile: Godot's
// Mobile renderer keeps a 10-bit RGB10A2 target with a luminance
// multiplier instead, which Hedra's shaders do not have); gl_compatibility
// is not Hedra's (refused with a warning).
export const RENDERING_FORWARD_PLUS: i32 = 0;
export const RENDERING_MOBILE: i32 = 1;

// Godot's Viewport.Scaling3DMode, as far as Hedra has it.
export const SCALING_3D_BILINEAR: i32 = 0;
export const SCALING_3D_FSR: i32 = 1;

// Godot's defaults, and Hedra's for its own keys (see the header).
export const DEFAULT_MSAA_3D: i32 = MSAA_4X;
export const DEFAULT_FSR_SHARPNESS: f32 = 0.2;
export const DEFAULT_MAX_DENSITY: f32 = 2.0;
export const DEFAULT_MAX_PIXELS: i32 = 2560 * 1440;
export const DEFAULT_PREPASS_VENDORS: string = "PowerVR,Mali,Adreno,Apple";
// The depth prepass's default on the website's WebGL 2 runtime (the
// `web` parse), where neither `enable` nor `enable.web` is written: on (see
// the header). Natively the default is RenderQuality.depthPrepass's, off.
export const WEB_DEPTH_PREPASS: bool = true;

// The keys hedra.yaml may set (every line passed to the run time).
export const RENDER_SETTING_KEYS: StaticArray<string> = [
    "rendering/anti_aliasing/quality/msaa_3d",
    "rendering/renderer/rendering_method",
    "rendering/driver/depth_prepass/enable",
    "rendering/driver/depth_prepass/disable_for_vendors",
    "rendering/scaling_3d/mode",
    "rendering/scaling_3d/scale",
    "rendering/scaling_3d/fsr_sharpness",
    "rendering/scaling_3d/max_density",
    "rendering/scaling_3d/max_pixels",
    "rendering/shading/sort_opaque",
    "rendering/shading/specialize_surfaces",
    "rendering/environment/ssao/half_size",
];

export class RenderQuality {
    msaa3d: i32 = DEFAULT_MSAA_3D;
    renderingMethod: i32 = RENDERING_FORWARD_PLUS;
    depthPrepass: bool = false;
    prepassVendors: string = DEFAULT_PREPASS_VENDORS;
    scaling3dMode: i32 = SCALING_3D_BILINEAR;
    scaling3dScale: f32 = 1.0;
    fsrSharpness: f32 = DEFAULT_FSR_SHARPNESS;
    // 0: no cap.
    maxDensity: f32 = DEFAULT_MAX_DENSITY;
    maxPixels: i32 = DEFAULT_MAX_PIXELS;
    sortOpaque: bool = false;
    specializeSurfaces: bool = true;
    // SSAO traced at half the picture's size each side (a quarter of its
    // pixels), blurred back up to it (gpu/renderer.as ssaoPasses).
    ssaoHalfSize: bool = false;

    copyFrom(o: RenderQuality): RenderQuality {
        this.msaa3d = o.msaa3d;
        this.renderingMethod = o.renderingMethod;
        this.depthPrepass = o.depthPrepass;
        this.prepassVendors = o.prepassVendors;
        this.scaling3dMode = o.scaling3dMode;
        this.scaling3dScale = o.scaling3dScale;
        this.fsrSharpness = o.fsrSharpness;
        this.maxDensity = o.maxDensity;
        this.maxPixels = o.maxPixels;
        this.sortOpaque = o.sortOpaque;
        this.specializeSurfaces = o.specializeSurfaces;
        this.ssaoHalfSize = o.ssaoHalfSize;
        return this;
    }

    equals(o: RenderQuality): bool {
        return this.msaa3d == o.msaa3d && this.renderingMethod == o.renderingMethod
            && this.depthPrepass == o.depthPrepass && this.prepassVendors == o.prepassVendors
            && this.scaling3dMode == o.scaling3dMode && this.scaling3dScale == o.scaling3dScale
            && this.fsrSharpness == o.fsrSharpness && this.maxDensity == o.maxDensity
            && this.maxPixels == o.maxPixels && this.sortOpaque == o.sortOpaque
            && this.specializeSurfaces == o.specializeSurfaces && this.ssaoHalfSize == o.ssaoHalfSize;
    }

    // The main pass's MSAA sample count (1, 2, 4 or 8).
    samples(): u32 {
        return this.msaa3d <= MSAA_DISABLED ? 1 : (<u32>1 << <u32>min<i32>(this.msaa3d, MSAA_8X));
    }
}

// The feature tag of the web's overrides (Godot's `.web`).
export const WEB_FEATURE_TAG: string = ".web";

// The settings' choices, in Godot's numbering.
export const MSAA_3D_NAMES: StaticArray<string> = ["disabled", "2x", "4x", "8x"];
export const RENDERING_METHOD_NAMES: StaticArray<string> = ["forward_plus", "mobile"];
export const SCALING_3D_MODE_NAMES: StaticArray<string> = ["bilinear", "fsr"];

// The ranges of the numbers (Godot's for the scale and the sharpness).
export const SCALING_3D_SCALE_MIN: f32 = 0.25;
export const SCALING_3D_SCALE_MAX: f32 = 2.0;
export const FSR_SHARPNESS_MIN: f32 = 0.0;
export const FSR_SHARPNESS_MAX: f32 = 2.0;

// Whether `key` is one of RENDER_SETTING_KEYS, or one with the web's tag
// (the lines hedra build passes to the run time).
export function isRenderSettingKey(key: string): bool {
    const base = key.endsWith(WEB_FEATURE_TAG) ? key.substring(0, key.length - WEB_FEATURE_TAG.length) : key;
    for (let i = 0; i < RENDER_SETTING_KEYS.length; i++) if (unchecked(RENDER_SETTING_KEYS[i]) == base) return true;
    return false;
}

// `out` with each key of RENDER_SETTING_KEYS that `text` (hedra.yaml's
// lines, or the lines the generated hedra_project.as passes) sets; a key it
// does not set left as `out` holds it; a bad value adds
// "hedra.yaml: <key> is <v>, not ..." to `warnings` and leaves the key.
// With `web`, the depth prepass starts on (WEB_DEPTH_PREPASS) and the
// `<key>.web` lines then apply over the others (Godot's
// feature tag); without, they are only checked (their warnings said on
// every platform, so that the tools say what the web would). Lines of
// other keys are passed over (the screen quality's, the navigation's). A
// choice is its name or Godot's number, a bool true, false, 1 or 0.
// Returns `out`. (Parsed once a project: allocates.)
export function renderQualityFromSettings(text: string, out: RenderQuality, warnings: Array<string>, web: bool = false): RenderQuality {
    const lines = text.split("\n");
    // (the web's own default for the prepass, under any line that sets it)
    if (web) out.depthPrepass = WEB_DEPTH_PREPASS;
    applySettings(lines, false, out, warnings);
    applySettings(lines, true, web ? out : new RenderQuality(), warnings);
    return out;
}

// The lines of `lines` of the keys with the web's tag (`tagged`) or
// without, applied to `out`.
function applySettings(lines: Array<string>, tagged: bool, out: RenderQuality, warnings: Array<string>): void {
    for (let i = 0; i < lines.length; i++) {
        const line = stripComment(lines[i]).trim();
        const colon = line.indexOf(":");
        if (colon <= 0) continue;
        const written = line.substring(0, colon).trim();
        if (written.endsWith(WEB_FEATURE_TAG) != tagged) continue;
        const key = tagged ? written.substring(0, written.length - WEB_FEATURE_TAG.length) : written;
        const value = unquote(line.substring(colon + 1).trim());
        applySetting(written, key, value, out, warnings);
    }
}

function applySetting(written: string, key: string, value: string, out: RenderQuality, warnings: Array<string>): void {
    if (key == RENDER_SETTING_KEYS[0]) {
        const c = choiceOf(MSAA_3D_NAMES, value);
        if (c >= 0) out.msaa3d = c;
        else warnings.push(badChoice(written, value, MSAA_3D_NAMES));
    } else if (key == RENDER_SETTING_KEYS[1]) {
        if (value == "gl_compatibility") {
            warnings.push("hedra.yaml: " + written + " is gl_compatibility, which Hedra does not have (Hedra draws "
                + "WebGL 2 with its own renderer): forward_plus or mobile");
            return;
        }
        // (Godot writes the method's name; a number is not Godot's here)
        const c = settingIndex(RENDERING_METHOD_NAMES, value);
        if (c >= 0) out.renderingMethod = c;
        else warnings.push(badChoice(written, value, RENDERING_METHOD_NAMES));
    } else if (key == RENDER_SETTING_KEYS[2]) {
        const b = boolOf(value);
        if (b >= 0) out.depthPrepass = b == 1;
        else warnings.push(badBool(written, value));
    } else if (key == RENDER_SETTING_KEYS[3]) {
        out.prepassVendors = value;
    } else if (key == RENDER_SETTING_KEYS[4]) {
        if (value == "fsr2" || value == "2") {
            warnings.push("hedra.yaml: " + written + " is " + value + ", which Hedra does not draw (FSR 2 needs "
                + "motion vectors): bilinear or fsr");
            return;
        }
        const c = choiceOf(SCALING_3D_MODE_NAMES, value);
        if (c >= 0) out.scaling3dMode = c;
        else warnings.push(badChoice(written, value, SCALING_3D_MODE_NAMES));
    } else if (key == RENDER_SETTING_KEYS[5]) {
        const n = numberIn(value, SCALING_3D_SCALE_MIN, SCALING_3D_SCALE_MAX);
        if (n >= 0) out.scaling3dScale = <f32>n;
        else warnings.push(badRange(written, value, "0.25 to 2"));
    } else if (key == RENDER_SETTING_KEYS[6]) {
        const n = numberIn(value, FSR_SHARPNESS_MIN, FSR_SHARPNESS_MAX);
        if (n >= 0) out.fsrSharpness = <f32>n;
        else warnings.push(badRange(written, value, "0 to 2"));
    } else if (key == RENDER_SETTING_KEYS[7]) {
        const n = numberIn(value, 0, f32.MAX_VALUE);
        if (n >= 0) out.maxDensity = <f32>n;
        else warnings.push("hedra.yaml: " + written + " is " + value + ", not a number of 0 or more (0: no cap)");
    } else if (key == RENDER_SETTING_KEYS[8]) {
        const n = wholeOf(value);
        if (n >= 0) out.maxPixels = n;
        else warnings.push("hedra.yaml: " + written + " is " + value + ", not a whole number of 0 or more (0: no cap)");
    } else if (key == RENDER_SETTING_KEYS[9] || key == RENDER_SETTING_KEYS[10] || key == RENDER_SETTING_KEYS[11]) {
        const b = boolOf(value);
        if (b < 0) warnings.push(badBool(written, value));
        else if (key == RENDER_SETTING_KEYS[9]) out.sortOpaque = b == 1;
        else if (key == RENDER_SETTING_KEYS[10]) out.specializeSurfaces = b == 1;
        else out.ssaoHalfSize = b == 1;
    }
}

// The index of `value` in `names`, by name or Godot's number; -1.
function choiceOf(names: StaticArray<string>, value: string): i32 {
    const byName = settingIndex(names, value);
    if (byName >= 0) return byName;
    for (let i = 0; i < names.length; i++) if (value == i.toString()) return i;
    return -1;
}

function settingIndex(names: StaticArray<string>, value: string): i32 {
    for (let i = 0; i < names.length; i++) if (unchecked(names[i]) == value) return i;
    return -1;
}

// 1 true, 0 false, -1 neither.
function boolOf(value: string): i32 {
    if (value == "true" || value == "1") return 1;
    if (value == "false" || value == "0") return 0;
    return -1;
}

// `value` as a number from `lo` to `hi`, or -1 (every range here is of
// numbers of 0 or more).
function numberIn(value: string, lo: f64, hi: f64): f64 {
    const n = parseF64(value);
    if (!n.ok || !isFinite(n.value) || n.value < lo || n.value > hi) return -1;
    return n.value;
}

// `value` as a whole number of 0 or more, or -1.
function wholeOf(value: string): i32 {
    const n = parseI32(value);
    if (!n.ok || n.value < 0) return -1;
    return n.value;
}

function badChoice(key: string, value: string, names: StaticArray<string>): string {
    let list = "";
    for (let i = 0; i < names.length; i++) list += (i > 0 ? ", " : "") + names[i];
    return "hedra.yaml: " + key + " is " + value + ", not one of " + list;
}

function badBool(key: string, value: string): string {
    return "hedra.yaml: " + key + " is " + value + ", not true or false";
}

function badRange(key: string, value: string, range: string): string {
    return "hedra.yaml: " + key + " is " + value + ", not a number from " + range;
}

// `line` up to a `#` outside quotes (as screen.as reads hedra.yaml).
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
