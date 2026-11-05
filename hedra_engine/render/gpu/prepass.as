// The main pass's depth prepass (docs/engine/PERFORMANCE.md, "Overdraw";
// Godot's `rendering/driver/depth_prepass/enable` and
// `.../disable_for_vendors`): before the main pass, the view's opaque
// surfaces are drawn into its depth target alone, with no fragment stage
// (pass label `hedra prepass`); the main pass then loads that depth and
// tests lessEqual as before, so each pixel's surfaces are shaded only
// where they are the nearest (the depth test rejects the others before
// their fragment stage runs, where the GPU tests early).
//
// What the prepass draws (`rangeInDepthPrepass`): a range of an item the
// main pass draws, in a material shading, that writes the depth it is
// shaded at: opaque (not alpha-blended, not alpha-masked: a cut-out's
// depth is its fragment stage's), not emerging (Hedra's emerge cuts its
// pixels), of a mesh with no hidden face (their fragments are discarded),
// depth-tested (not the top pass), not a next pass (it draws its owner's
// surface again), not a ShaderMaterial's (its own vertex stage), not
// drawn in a split frame's second half (the ranges that refract: what is
// behind them must be in the screen texture), and not skinned (the
// renderer's gatherOpaque: Metal compiles the skinned vertex entry of a
// pipeline without a fragment stage into positions a rounding apart from
// the full pipeline's, so a skinned surface would lose its own depth
// test along whole triangles). Each is drawn through the
// depth pipeline of the very module and vertex entry its main pass uses
// (the ubershader's Pipelines.prepassPipeline, or its specialised
// variant's, gpu/variants.as pickDepth), with the surfaces' depth bias, so
// the main pass finds the depth it computes itself.
//
// When it runs (`prepassWanted`): the project's
// rendering/driver/depth_prepass/enable (true by default, Godot's) and an
// adapter whose name matches none of disable_for_vendors (Godot's list,
// "PowerVR,Mali,Adreno,Apple": the tile-based GPUs, whose hidden surface
// removal does the prepass's work, and where a second geometry pass costs
// more than it saves). Godot's Compatibility renderer matches each entry
// against GL_RENDERER, ignoring case (drivers/gles3/storage/config.cpp);
// Hedra matches it against the adapter's vendor (device.as
// AdapterSummary.vendor: "Apple" on Metal, which the rive host draws with
// on macOS and iOS, else unknown), so on Apple's GPUs the prepass is off
// by default, as in Godot.

import { RenderQuality } from "../quality";
import { ALPHA_BLEND, ALPHA_MASK, materialRefracts } from "../material";
import { DrawItem, RenderFrame, emerging } from "../frame";
import { PostPlan } from "../post";
import { rangeDrawn } from "../cull";
import { isTopItem } from "../top_pass";

// Whether `vendor` contains, ignoring ASCII case, one of the comma
// separated entries of `list` (each trimmed of spaces; an empty entry
// matches nothing), as Godot's disable_for_vendors is matched. Allocates
// nothing.
export function vendorListed(list: string, vendor: string): bool {
    if (vendor.length == 0) return false;
    let start = 0;
    const n = list.length;
    while (start <= n) {
        let end = start;
        while (end < n && list.charCodeAt(end) != 44) end++;
        let a = start;
        let b = end;
        while (a < b && isSpace(list.charCodeAt(a))) a++;
        while (b > a && isSpace(list.charCodeAt(b - 1))) b--;
        if (b > a && containsIgnoringCase(vendor, list, a, b)) return true;
        start = end + 1;
    }
    return false;
}

function isSpace(c: i32): bool {
    return c == 32 || c == 9 || c == 10 || c == 13;
}

function lower(c: i32): i32 {
    return c >= 65 && c <= 90 ? c + 32 : c;
}

// Whether `hay` contains needle[a..b), ignoring ASCII case.
function containsIgnoringCase(hay: string, needle: string, a: i32, b: i32): bool {
    const m = b - a;
    const n = hay.length;
    for (let i = 0; i + m <= n; i++) {
        let k = 0;
        while (k < m && lower(hay.charCodeAt(i + k)) == lower(needle.charCodeAt(a + k))) k++;
        if (k == m) return true;
    }
    return false;
}

// Whether a view drawn with quality `q` on an adapter of vendor `vendor`
// draws the depth prepass (see the header).
export function prepassWanted(q: RenderQuality, vendor: string): bool {
    return q.depthPrepass && !vendorListed(q.prepassVendors, vendor);
}

// Whether range `k` of item `d` of frame `f` (material `key`; `hiddenFaces`
// its mesh has faces hidden, `custom` its material draws with a ready
// ShaderMaterial module, `late` it is drawn in a split frame's second
// half under plan `plan`) is drawn by the depth prepass (see the header).
// Frame-pure, for the tests.
export function rangeInDepthPrepass(
    f: RenderFrame, d: DrawItem, k: i32, key: i64, hiddenFaces: bool, custom: bool, late: bool,
): bool {
    if (!f.materialMode || !f.drawSurfaces) return false;
    if (hiddenFaces || custom || late || emerging(d) || isTopItem(d) || d.nextPassOf >= 0) return false;
    if (!rangeDrawn(d, k)) return false;
    if (key >= 0) {
        if (key >= <i64>f.materials.length) return false;
        const m = unchecked(f.materials[<i32>key]);
        if (m.alphaMode == ALPHA_BLEND || m.alphaMode == ALPHA_MASK) return false;
    }
    return true;
}

// Whether plan `plan` may draw range material `key` of frame `f` in a
// split frame's second half: a range that refracts (renderer.as
// rangeRefracts's rule), left out of the prepass whether the frame is
// split or not.
export function lateRange(f: RenderFrame, plan: PostPlan, key: i64): bool {
    if (!plan.refraction || key < 0 || key >= <i64>f.materials.length) return false;
    const m = unchecked(f.materials[<i32>key]);
    return materialRefracts(m) && m.alphaMode != ALPHA_BLEND;
}
