// What every shading but `lit` takes from Hedra (milestone 5): the values
// Hedra's `render` draws its viewport shadings with when nothing overrides
// them, copied rather than imported (shared code never imports a program).
// With them, the CLI's `render --shading solid` of a model and the CLI's
// `render --shading solid --overlay none` of the same model are the same
// picture (cli/tests/scene_render, the consistency test).

import { f32ToU32 } from "../../base/util";
import { Vec3, Vec4 } from "../../base/vecmath";
import { lin } from "../../render/colors";
import { srgbToLinear } from "../../render/image";

// The clear colour of every shading but lit: Hedra's default background
// (sRGB, RenderOptions.background).
export const MATERIAL_BACKGROUND: Vec4 = Vec4(0.2, 0.2, 0.2, 1.0);

// Modeler's default matcap, Clay (`Matcap.id(Matcap.Clay)`).
export const MATCAP_CLAY: u32 = 0;

// Modeler's wire colour when `--wire-color` is not given (sRGB black,
// scene_view.as DEFAULT_WIRE); `wireColour()` makes it linear as Hedra
// does (black stays black).
export const DEFAULT_WIRE: Vec3 = Vec3(0.0, 0.0, 0.0);

export function wireColour(): Vec4 {
    return lin(DEFAULT_WIRE, 1.0);
}

// Checker cells per UV unit of the uv-checker shading (Hedra's
// RenderOptions.checkerSize default).
export const UV_CHECKER_SIZE: f32 = 8.0;

// The random shading's colour of an object named `name`, linear: FNV-1a 32
// of the name's UTF-8 bytes to a hue at saturation 0.55 and value 0.85,
// Hedra's `hashColor`, so a model's objects get the colours they have in
// Hedra.
export function hashColor(name: string): Vec4 {
    let h: u32 = 2166136261;
    const bytes = Uint8Array.wrap(String.UTF8.encode(name));
    for (let i = 0; i < bytes.length; i++) {
        h ^= <u32>bytes[i];
        h = h * 16777619;
    }
    const hue = <f32>(h % 360);
    const s: f32 = 0.55;
    const v: f32 = 0.85;
    const c = v * s;
    const x = c * (<f32>1.0 - Mathf.abs((hue / <f32>60.0) % <f32>2.0 - <f32>1.0));
    const m = v - c;
    let r: f32;
    let g: f32;
    let b: f32;
    switch (f32ToU32(hue / <f32>60.0)) {
        case 0: { r = c; g = x; b = 0.0; break; }
        case 1: { r = x; g = c; b = 0.0; break; }
        case 2: { r = 0.0; g = c; b = x; break; }
        case 3: { r = 0.0; g = x; b = c; break; }
        case 4: { r = x; g = 0.0; b = c; break; }
        default: { r = c; g = 0.0; b = x; break; }
    }
    return Vec4(srgbToLinear(r + m), srgbToLinear(g + m), srgbToLinear(b + m), 1.0);
}
