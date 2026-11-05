// Which items of a frame each pass draws (milestone 13): frustum culling of
// the main view and of every shadow tile, Godot's visibility ranges, and
// the render statistics they give (draws, instances, triangles, culled).
//
// One function decides for everyone: the renderer (gpu/renderer.as) draws
// what `cullFrame` leaves in, and the CLI's `inspect --stats` and the
// preview's statistics line report its `stats`, so the numbers are the
// draws the GPU was given.
//
// Culling changes no pixel. An item is left out of a pass only when its
// box (DrawItem.bounds, frame world space, every instance included) is
// wholly outside that pass's frustum (the main view's, or a shadow tile's
// view-projection), where the GPU would have clipped every triangle of it
// anyway; and it is never left out when its box is unknown
// (`hasBounds` false: every Hedra item), so Hedra draws as before.
// The visibility range does change pictures, as it is meant to: an item
// outside its range is drawn in no pass, as in Godot.
//
// The visibility range, Godot 4's rule (RendererSceneCull
// `_visibility_range_check`): with d the distance from the eye to
// `rangeCenter`, and the item's state `was` (RenderFrame.rangeState: drawn
// the last time this frame was culled, or, for a frame not culled yet, what
// its program seeded, Hedra's from the frame before; false otherwise),
//   fade disabled, was drawn, or a fade mode:
//     drawn when (begin == 0 or d >= begin - beginMargin)
//            and (end == 0 or d <= end + endMargin)
//   fade disabled and was not drawn:
//     drawn when (begin == 0 or d >= begin + beginMargin)
//            and (end == 0 or d <= end - endMargin)
// so a margin is a hysteresis band, and the first picture of a frame (every
// `render`) takes the narrow range. The fade modes are drawn without the
// fade, over the wide range.
//
// Allocation: `cullFrame` writes into `out`, whose arrays keep their
// storage from call to call, and the frusta are module-level scratch
// objects, so culling the same frame again (the preview's every moving
// frame) allocates nothing once `out` has held as many items.
//
// Exactness. The test is conservative twice over: a plane rejects a box
// only when the box's corner furthest along the plane's normal is behind it
// by more than a relative tolerance (TOLERANCE, far above the rounding of
// the f32 matrices the CPU and the GPU each multiply), and the main pass's
// frustum is widened for what the line shader draws past a mesh's
// triangles: an item that shows its edges or points (DrawItem.showEdges,
// .showPoints, or lines or points of its own in the frame) keeps OVERLAY_PX
// pixels beyond each side of the picture, where half a wide line or a point
// can still reach in, and is never culled by the far plane, as lines are
// pulled towards the eye (lines.wgsl `to_view`). An item that is not drawn
// is therefore always one whose pixels would all have been clipped.
//
// Statistics count what the renderer's passes draw: `draws` a main-pass
// surface call per drawn item or per material range, and `shadowDraws` the
// shadow pass's calls over every tile by gpu/renderer.as `shadowPass`'s
// rule (in material mode one per range that does not blend, else one).
// `shadowCulled` counts the (caster, tile) pairs a tile's frustum left out;
// a caster out of its visibility range is counted once, in `culledRange`,
// and in no tile. An instanced item in a shading without surfaces (wire)
// is not drawn (no instanced edges or points), so it counts nothing.
//
// Worlds (milestone 34, viewport.as): an item of another world than the
// frame's (DrawItem.scenario != RenderFrame.scenario: a node under a
// SubViewport with a world of its own, seen from the main view, or a main
// world item seen from that world's view) is in no pass and counts
// nowhere, not even in `items`; its visibility-range state is left as it
// was. Every item of a scene without such a SubViewport is in the
// frame's world (both 0), so nothing changes for it.
//
// Occlusion (milestone 37, occlusion.as): when the frustum test is on, the
// frame culls with occluders (RenderFrame.occlusion, and an occluder in
// RenderFrame.occluders) and its shading draws surfaces, `frameOcclusion`
// is made from the frame's camera before the items are tested, and an item
// the view's frustum keeps is left out of the main pass (CULL_OCCLUDED,
// counted in `culledOcclusion` and `culled`) when it has a box, draws no
// lines or points of its own (drawsOverlay: an overlay is drawn over what
// hides it), is depth-tested, and its box is wholly behind what the
// occluders cover (OcclusionBuffer.occluded). Its shadow tiles are those
// it had: an occluded item still casts its shadow. `occluders` and
// `occluderTriangles` are the buffer's. A frame without occluders (every
// frame of a scene without an OccluderInstance3D) makes no buffer and
// tests nothing, so it culls exactly as before; the shadow tiles and a
// probe's captures never read the buffer.
//
// Custom shaders and next passes (milestone 61, gpu/custom.as): a next
// pass's item (DrawItem.nextPassOf) draws only its ranges with a next pass
// (a material key of -1 is a range without one, `rangeDrawn`), and only in
// a material shading (the matcap, normals and the other shadings draw no
// material, so no next pass either: it is CULL_NOT_DRAWN there, as it is in
// a material shading other than lit when all its ranges are ShaderMaterials,
// which draw in lit alone: `nextPassDrawn`); a range
// whose ShaderMaterial casts no shadow (program.as castsShadows: Godot's
// shadows_disabled, or a transparent shader) is no shadow draw. Every
// other item counts as before.
//
// Which items a pass reads (CullResult.used): those drawn in the main pass
// or a shadow tile, and those with lines or points of their own (drawn with
// their object block whether their mesh is or not); of those, the main
// pass alone reads an item's lights and fog volumes (CullResult.shaded).
// The renderer writes the object blocks of the first alone and chooses
// lights and fog for the second alone, so an item culled by the frustum,
// its range or the occluders costs nothing more than its test, and a
// shadow caster no more than its block (every frame, with occluders or
// without: the pictures are the same, as no pass reads what is left out).

import { Mat4, Vec3, Vec4 } from "../base/vecmath";
import { Bounds } from "./camera";
import { ALPHA_BLEND } from "./material";
import {
    CAST_SHADOW_OFF, CAST_SHADOW_SHADOWS_ONLY, DrawItem, RANGE_FADE_DISABLED, RenderFrame, SHADE_LIT, chooseLods,
} from "./frame";
import { lodTriangles } from "./mesh";
import { OCCLUSION_RECT_WORDS, OcclusionStats, frameOcclusion } from "./occlusion";
import { Job, MAX_JOB_WORKERS, jobs, unitCount } from "../base/jobs";
import { ShadowPlan } from "./shadow";

// How far behind a plane (relative to the size of the terms of the plane's
// equation at the box's corner) a box must be to be left out.
export const TOLERANCE: f32 = 1e-4;

// The pixels an item that draws lines or points keeps beyond each side of
// the picture (before SSAA; the widest line or point the renderer draws is
// under half of it).
export const OVERLAY_PX: f32 = 16;

// CullResult.main, by item.
export const CULL_DRAWN: u8 = 0;
// Wholly outside the view's frustum.
export const CULL_FRUSTUM: u8 = 1;
// Outside its visibility range (drawn in no pass).
export const CULL_RANGE: u8 = 2;
// Not in the main pass for another reason: no mesh, or shadows only. Not
// counted as culled.
export const CULL_NOT_DRAWN: u8 = 3;
// Milestone 37: hidden behind the frame's occluders (occlusion.as), in
// the view's frustum. Drawn in its shadow tiles all the same.
export const CULL_OCCLUDED: u8 = 4;

// What a frame's main pass draws, and what culling left out.
export class RenderStats {
    // Items with a mesh (shadows-only ones included).
    items: i32 = 0;
    // Surface draw calls of the main pass: one per drawn item, or one per
    // material range in the material and lit modes; 0 when the shading
    // draws no surface (wire).
    draws: i32 = 0;
    // Copies of meshes the main pass draws: 1 per drawn item, an instanced
    // item's instance count.
    instances: i64 = 0;
    // Triangles the main pass draws (each mesh's times its copies).
    triangles: i64 = 0;
    // Items left out of the main pass: by the frustum, by their visibility
    // range, and both together.
    culledFrustum: i32 = 0;
    culledRange: i32 = 0;
    culled: i32 = 0;
    // Draw calls of the shadow pass over every tile, and the (caster, tile)
    // pairs culling left out of it.
    shadowDraws: i32 = 0;
    shadowCulled: i32 = 0;
    // Milestone 37 (occlusion.as): items left out of the main pass by the
    // occluders (counted in `culled` too), the frame's occluders of its
    // world, and the triangles rasterised for them. 0, 0, 0 without
    // occluders.
    culledOcclusion: i32 = 0;
    occluders: i32 = 0;
    occluderTriangles: i32 = 0;
    // Milestone 61 (gpu/custom.as): the main pass's draws with a custom
    // shader's pipelines, those drawn with their fallback instead (the
    // shader is compiling, failed or has no source), and of these the ones
    // waiting for a compile. 0, 0, 0 without ShaderMaterials.
    shaderDraws: i32 = 0;
    shaderFallbacks: i32 = 0;
    shaderPending: i32 = 0;
    // The occlusion buffer's texels across and down (0, 0 without it):
    // half as many across while the view moves (occlusion.as).
    occlusionWidth: i32 = 0;
    occlusionHeight: i32 = 0;
    // Milestone 62 (gpu/renderer.as): the material ranges the main pass's
    // second half drew that refract the screen (post.as PostPlan
    // `refraction`), and the passes the screen-space effects ran (the screen
    // texture's levels, the second half of the main pass, the reflections'
    // trace, the depth of field's three). 0, 0 without them.
    refractionDraws: i32 = 0;
    screenPasses: i32 = 0;
    // And which effects the GPU drew (the plan's, less what the host
    // refused: SCREEN_PIPELINE_WARNING, SSR_PIPELINE_WARNING,
    // DOF_PIPELINE_WARNING): the reflections traced and merged, the screen
    // texture made for the refraction, the depth of field composed. The
    // runtime's status says these, not the plan.
    ssrTraced: bool = false;
    refracted: bool = false;
    dofDrawn: bool = false;
    // Milestone 67 (gpu/renderer.as, docs/engine/PERFORMANCE.md): how the
    // main pass was drawn: its MSAA samples, whether into the Mobile
    // renderer's 32-bit HDR target (r11g11b10float) rather than
    // rgba16float, whether its opaque ranges were sorted (gpu/order.as),
    // whether a depth prepass ran (gpu/prepass.as) and how many ranges it
    // drew, and whether the picture was drawn again keeping the culling,
    // the shadows, the normal-depth pass and SSAO of the frame before
    // (FrameRenderer.renderFrameReusing). 0 and false before a view is
    // drawn.
    samples: i32 = 0;
    compactTarget: bool = false;
    sorted: bool = false;
    prepass: bool = false;
    prepassDraws: i32 = 0;
    reused: bool = false;
    // Milestone 67 (gpu/shadow_cache.as, docs/engine/PERFORMANCE.md
    // "Shadows kept"): the shadow tiles the view's shadow pass drew, and
    // those it kept from an earlier drawing because their light and casters
    // were the same (0 and 0 without shadows; a picture drawn again,
    // renderFrameReusing, keeps every tile and says the last drawing's).
    shadowTilesDrawn: i32 = 0;
    shadowTilesKept: i32 = 0;

    reset(): void {
        this.items = 0;
        this.draws = 0;
        this.instances = 0;
        this.triangles = 0;
        this.culledFrustum = 0;
        this.culledRange = 0;
        this.culled = 0;
        this.shadowDraws = 0;
        this.shadowCulled = 0;
        this.culledOcclusion = 0;
        this.occluders = 0;
        this.occluderTriangles = 0;
        this.shaderDraws = 0;
        this.shaderFallbacks = 0;
        this.shaderPending = 0;
        this.occlusionWidth = 0;
        this.occlusionHeight = 0;
        this.refractionDraws = 0;
        this.screenPasses = 0;
        this.ssrTraced = false;
        this.refracted = false;
        this.dofDrawn = false;
        this.samples = 0;
        this.compactTarget = false;
        this.sorted = false;
        this.prepass = false;
        this.prepassDraws = 0;
        this.reused = false;
        this.shadowTilesDrawn = 0;
        this.shadowTilesKept = 0;
    }

    copyFrom(o: RenderStats): void {
        this.items = o.items;
        this.draws = o.draws;
        this.instances = o.instances;
        this.triangles = o.triangles;
        this.culledFrustum = o.culledFrustum;
        this.culledRange = o.culledRange;
        this.culled = o.culled;
        this.shadowDraws = o.shadowDraws;
        this.shadowCulled = o.shadowCulled;
        this.culledOcclusion = o.culledOcclusion;
        this.occluders = o.occluders;
        this.occluderTriangles = o.occluderTriangles;
        this.shaderDraws = o.shaderDraws;
        this.shaderFallbacks = o.shaderFallbacks;
        this.shaderPending = o.shaderPending;
        this.occlusionWidth = o.occlusionWidth;
        this.occlusionHeight = o.occlusionHeight;
        this.refractionDraws = o.refractionDraws;
        this.screenPasses = o.screenPasses;
        this.ssrTraced = o.ssrTraced;
        this.refracted = o.refracted;
        this.dofDrawn = o.dofDrawn;
        this.samples = o.samples;
        this.compactTarget = o.compactTarget;
        this.sorted = o.sorted;
        this.prepass = o.prepass;
        this.prepassDraws = o.prepassDraws;
        this.reused = o.reused;
        this.shadowTilesDrawn = o.shadowTilesDrawn;
        this.shadowTilesKept = o.shadowTilesKept;
    }
}

export class CullResult {
    // By item: CULL_*.
    main: Array<u8> = [];
    // By item: bit t set when the item is drawn into shadow tile t (the
    // plan's tiles, at most SHADOW_TILES = 16).
    casters: Array<u32> = [];
    // By item: whether a pass of the view reads its object block: drawn in
    // the main pass or a shadow tile, or with lines or points of its own
    // (RenderFrame.itemLines, .itemPoints: drawn with its block whether its
    // mesh is or not, as a skeleton's bones over a hidden mesh). The
    // renderer writes the block of these alone (gpu/renderer.as drawView).
    used: Array<bool> = [];
    // By item: whether the main pass shades it (CULL_DRAWN), the one pass
    // that reads its lights and fog volumes (a shadow tile reads its
    // transform alone): the renderer chooses those for these alone.
    shaded: Array<bool> = [];
    stats: RenderStats = new RenderStats();
}

// The six planes of a view-projection's clip volume (WebGPU's: x and y in
// -w..w, z in 0..w), each (a, b, c, d) with a*x + b*y + c*z + d >= 0 inside,
// normalised so that (a, b, c) is a unit vector. A plane that cannot be
// normalised (a degenerate matrix, or one with a non-finite number) is
// stored as (0, 0, 0, 1), which keeps everything: culling never guesses.
export class Frustum {
    // Plane k is planes[4k .. 4k + 3]: left, right, bottom, top, near, far.
    planes: StaticArray<f32> = new StaticArray<f32>(24);

    // Sets the planes from `viewProj` (Gribb and Hartmann), allocating
    // nothing.
    setFrom(viewProj: Mat4): void {
        this.setWidened(viewProj, 0, 0, false);
    }

    // `setFrom` with the sides moved out by `mx` and `my` of the clip
    // volume's half width and height (x in -(1 + mx)w..(1 + mx)w), and
    // without a far plane when `noFar`: the main pass's frustum for what
    // draws lines and points (the header).
    setWidened(viewProj: Mat4, mx: f32, my: f32, noFar: bool): void {
        // Row r of the matrix: clip coordinate r of a point is row r . (p, 1).
        const m = viewProj;
        const r0 = Vec4(m.xAxis.x, m.yAxis.x, m.zAxis.x, m.wAxis.x);
        const r1 = Vec4(m.xAxis.y, m.yAxis.y, m.zAxis.y, m.wAxis.y);
        const r2 = Vec4(m.xAxis.z, m.yAxis.z, m.zAxis.z, m.wAxis.z);
        const r3 = Vec4(m.xAxis.w, m.yAxis.w, m.zAxis.w, m.wAxis.w);
        const wx = r3 * (<f32>1 + mx);
        const wy = r3 * (<f32>1 + my);
        this.put(0, wx + r0); // x >= -w
        this.put(1, wx - r0); // x <= w
        this.put(2, wy + r1); // y >= -w
        this.put(3, wy - r1); // y <= w
        this.put(4, r2); // z >= 0
        if (noFar) this.put(5, Vec4(0, 0, 0, 1));
        else this.put(5, r3 - r2); // z <= w
    }

    private put(k: i32, p: Vec4): void {
        const len = Mathf.sqrt(p.x * p.x + p.y * p.y + p.z * p.z);
        const o = 4 * k;
        if (len > 0 && isFinite(len) && isFinite(p.w)) {
            const inv = <f32>1 / len;
            this.planes[o] = p.x * inv;
            this.planes[o + 1] = p.y * inv;
            this.planes[o + 2] = p.z * inv;
            this.planes[o + 3] = p.w * inv;
        } else {
            this.planes[o] = 0;
            this.planes[o + 1] = 0;
            this.planes[o + 2] = 0;
            this.planes[o + 3] = 1;
        }
    }

    // Whether `b` may have a point inside (false only when it is wholly
    // outside one plane: conservative). The "p-vertex" test: for each plane
    // the corner of `b` furthest along its normal; a box with a NaN is kept.
    intersects(b: Bounds): bool {
        const lo = b.min;
        const hi = b.max;
        const pl = this.planes;
        for (let k = 0; k < 6; k++) {
            const o = 4 * k;
            const a = unchecked(pl[o]);
            const bb = unchecked(pl[o + 1]);
            const c = unchecked(pl[o + 2]);
            const d = unchecked(pl[o + 3]);
            const tx = a * (a >= 0 ? hi.x : lo.x);
            const ty = bb * (bb >= 0 ? hi.y : lo.y);
            const tz = c * (c >= 0 ? hi.z : lo.z);
            const dist = tx + ty + tz + d;
            const scale = Mathf.abs(tx) + Mathf.abs(ty) + Mathf.abs(tz) + Mathf.abs(d);
            if (dist < -TOLERANCE * scale) return false;
        }
        return true;
    }
}

// The view-projection the main pass draws `f` with (frame.as frameGlobals').
export function frameViewProj(f: RenderFrame): Mat4 {
    const aspect = <f32>f.width / <f32>max<u32>(f.height, 1);
    return f.camera.projectionMatrix(aspect) * f.camera.viewMatrix();
}

// Whether `d` is inside its visibility range seen from `eye`, by the rule
// in the header (`was`: drawn the last time). An item without a range
// (begin and end both 0 or less) always is.
export function inVisibilityRange(d: DrawItem, eye: Vec3, was: bool): bool {
    const begin = d.rangeBegin;
    const end = d.rangeEnd;
    if (!(begin > 0) && !(end > 0)) return true;
    const dist = eye.distance(d.rangeCenter);
    const wide = was || d.rangeFadeMode != RANGE_FADE_DISABLED;
    const bm: f32 = d.rangeBeginMargin > 0 ? d.rangeBeginMargin : 0;
    const em: f32 = d.rangeEndMargin > 0 ? d.rangeEndMargin : 0;
    if (begin > 0 && !(dist >= begin + (wide ? -bm : bm))) return false;
    if (end > 0 && !(dist <= end + (wide ? em : -em))) return false;
    return true;
}

// Scratch, kept across calls so that culling allocates nothing: the main
// view's exact and widened frusta, one per shadow tile, and which items
// draw lines or points of their own (by item).
const mainFrustum = new Frustum();
const overlayFrustum = new Frustum();
const tileFrusta = new Array<Frustum>();
const itemOverlay = new Array<bool>();

// Whether item `i` of `f` draws lines or points (the header's widening).
function drawsOverlay(d: DrawItem, i: i32): bool {
    return d.showEdges || d.showPoints || (i < itemOverlay.length && unchecked(itemOverlay[i]));
}

// Marks the items with lines or points of their own in `f` (by slot) in
// `itemOverlay`, sized to the items.
function markOverlays(f: RenderFrame): void {
    const n = f.items.length;
    itemOverlay.length = n;
    for (let i = 0; i < n; i++) unchecked(itemOverlay[i] = false);
    for (let k = 0; k < f.itemLines.length; k++) {
        const s = <i32>f.itemLines[k].slot - 1;
        if (s >= 0 && s < n) unchecked(itemOverlay[s] = true);
    }
    for (let k = 0; k < f.itemPoints.length; k++) {
        const s = <i32>f.itemPoints[k].slot - 1;
        if (s >= 0 && s < n) unchecked(itemOverlay[s] = true);
    }
}

// Culls `f` for its main pass and for each tile of `shadows` (null or no
// tile: no shadow pass), into `out` (returned), and counts its stats.
// Updates f.rangeState. With `frustum` false the frustum and caster tests
// keep everything (FrameRenderer.cullingEnabled: the golden that proves
// culling changes no pixel); the visibility ranges still apply, as they are
// part of the picture.
export function cullFrame(f: RenderFrame, shadows: ShadowPlan?, out: CullResult, frustum: bool = true): CullResult {
    const items = f.items;
    const n = items.length;
    out.main.length = n;
    out.casters.length = n;
    const state = f.rangeState;
    // Grown with false in place: an item not culled before was not drawn.
    if (state.length < n) state.length = n;
    const s = out.stats;
    s.reset();
    // Milestone 26: each item's level of detail for this camera (level 0
    // in every frame whose lodThreshold is 0), before anything counts its
    // triangles.
    chooseLods(f);

    const tiles = shadows != null ? min<i32>(shadows.tiles.length, 32) : 0;
    if (frustum) {
        const vp = frameViewProj(f);
        mainFrustum.setFrom(vp);
        const w = <f32>max<u32>(f.width, 1);
        const h = <f32>max<u32>(f.height, 1);
        overlayFrustum.setWidened(vp, <f32>2 * OVERLAY_PX / w, <f32>2 * OVERLAY_PX / h, true);
        markOverlays(f);
        while (tileFrusta.length < tiles) tileFrusta.push(new Frustum());
        if (shadows != null) {
            for (let t = 0; t < tiles; t++) unchecked(tileFrusta[t]).setFrom(unchecked(shadows.tiles[t]).viewProj);
        }
    }
    const eye = f.camera.eye;
    // Milestone 37: the occluders' buffer (the header).
    const occlusion = frustum && f.occlusion && f.occluders.length > 0 && f.drawSurfaces;
    if (occlusion) frameOcclusion.prepare(f);
    else frameOcclusion.clear();
    const occluding = occlusion && frameOcclusion.active;

    // The items, a job of CULL_GRAIN items a unit (jobs.as): each unit
    // writes its items' answers and counts in its own stats, added up after
    // the run in unit order.
    const job = cullJob;
    job.f = f;
    job.shadows = shadows;
    job.out = out;
    job.frustum = frustum;
    job.tiles = tiles;
    job.occluding = occluding;
    job.eye = eye;
    const units = unitCount(n, CULL_GRAIN);
    job.prepare(units);
    if (occluding) frameOcclusion.reserveAnswers(n);
    jobs().run(job, n, CULL_GRAIN);
    job.f = null;
    job.shadows = null;
    job.out = null;
    const tested = frameOcclusion.stats;
    for (let u = 0; u < units; u++) {
        const us = unchecked(job.stats[u]);
        s.items += us.items;
        s.draws += us.draws;
        s.instances += us.instances;
        s.triangles += us.triangles;
        s.culledFrustum += us.culledFrustum;
        s.culledRange += us.culledRange;
        s.shadowDraws += us.shadowDraws;
        s.shadowCulled += us.shadowCulled;
        s.culledOcclusion += us.culledOcclusion;
        const uo = unchecked(job.occlusion[u]);
        tested.tested += uo.tested;
        tested.occluded += uo.occluded;
    }
    if (occlusion) {
        s.occluders = frameOcclusion.stats.occluders;
        s.occluderTriangles = frameOcclusion.stats.triangles;
        s.occlusionWidth = frameOcclusion.width;
        s.occlusionHeight = frameOcclusion.height;
    }
    s.culled = s.culledFrustum + s.culledRange + s.culledOcclusion;
    markUsed(f, out);
    return out;
}

// The items a unit of cullFrame's job culls (CULL_GRAIN).
const CULL_GRAIN = 64;

// cullFrame's items as a job (jobs.as): what every unit reads, set before
// the run, and each unit's counts (`stats`, `occlusion`: by unit, grown to
// the most units a frame had), each worker's rectangles for the occlusion
// test (OcclusionBuffer.occludedInto).
class CullJob extends Job {
    f: RenderFrame? = null;
    shadows: ShadowPlan? = null;
    out: CullResult? = null;
    frustum: bool = true;
    tiles: i32 = 0;
    occluding: bool = false;
    eye: Vec3 = Vec3(0, 0, 0);
    stats: Array<RenderStats> = [];
    occlusion: Array<OcclusionStats> = [];
    rects: Array<StaticArray<i32>> = [];

    constructor() {
        super();
        for (let w = 0; w < MAX_JOB_WORKERS; w++) this.rects.push(new StaticArray<i32>(OCCLUSION_RECT_WORDS));
    }

    // Each of `units` units' counts at 0.
    prepare(units: i32): void {
        while (this.stats.length < units) {
            this.stats.push(new RenderStats());
            this.occlusion.push(new OcclusionStats());
        }
        for (let u = 0; u < units; u++) {
            unchecked(this.stats[u]).reset();
            unchecked(this.occlusion[u]).reset();
        }
    }

    runUnit(unit: i32, begin: i32, end: i32, worker: i32): void {
        const s = unchecked(this.stats[unit]);
        const counts = unchecked(this.occlusion[unit]);
        const rect = unchecked(this.rects[worker]);
        cullItems(this, begin, end, s, counts, rect);
    }
}

const cullJob = new CullJob();

// Items [begin, end) of the job's frame culled into its result, counted in
// `s` (and their occlusion tests in `counts`, worked in `rect`), by
// cullFrame's rules.
function cullItems(job: CullJob, begin: i32, end: i32, s: RenderStats, counts: OcclusionStats, rect: StaticArray<i32>): void {
    const f = job.f!;
    const out = job.out!;
    const shadows = job.shadows;
    const frustum = job.frustum;
    const tiles = job.tiles;
    const occluding = job.occluding;
    const eye = job.eye;
    const items = f.items;
    const state = f.rangeState;
    const scenario = f.scenario;
    for (let i = begin; i < end; i++) {
        const d = unchecked(items[i]);
        const g = d.mesh;
        // (milestone 35: a CPUParticles3D's item with no particle alive is
        // kept in the plan, so that frames refresh in place while particles
        // come and go, and drawn in no pass)
        const inst = d.instances;
        if (g == null || d.scenario != scenario || (inst != null && inst.count == 0) || (d.nextPassOf >= 0 && !nextPassDrawn(f, d))) {
            unchecked(out.main[i] = CULL_NOT_DRAWN);
            unchecked(out.casters[i] = 0);
            continue;
        }
        s.items++;
        // 1. the visibility range: out of it, drawn in no pass
        if (d.rangeBegin > 0 || d.rangeEnd > 0) {
            const drawn = inVisibilityRange(d, eye, unchecked(state[i]));
            unchecked(state[i] = drawn);
            if (!drawn) {
                unchecked(out.main[i] = CULL_RANGE);
                unchecked(out.casters[i] = 0);
                s.culledRange++;
                continue;
            }
        } else {
            unchecked(state[i] = true);
        }
        // 4. the shadow tiles it is drawn into
        let bits: u32 = 0;
        if (d.castShadow != CAST_SHADOW_OFF && tiles > 0 && shadows != null) {
            const each = shadowDrawsOf(f, d);
            for (let t = 0; t < tiles; t++) {
                if (!frustum || !d.hasBounds || unchecked(tileFrusta[t]).intersects(d.bounds)) {
                    bits |= <u32>1 << <u32>t;
                    s.shadowDraws += each;
                } else {
                    s.shadowCulled++;
                }
            }
        }
        unchecked(out.casters[i] = bits);
        // 2. shadows only: not in the picture, and not culled either
        if (d.castShadow == CAST_SHADOW_SHADOWS_ONLY) {
            unchecked(out.main[i] = CULL_NOT_DRAWN);
            continue;
        }
        // 3. the view's frustum
        if (frustum && d.hasBounds) {
            const fr = drawsOverlay(d, i) ? overlayFrustum : mainFrustum;
            if (!fr.intersects(d.bounds)) {
                unchecked(out.main[i] = CULL_FRUSTUM);
                s.culledFrustum++;
                continue;
            }
            // 3b. behind the occluders (milestone 37: the header)
            if (occluding && !d.noDepthTest && !drawsOverlay(d, i) && frameOcclusion.occludedAtInto(i, d.bounds, counts, rect)) {
                unchecked(out.main[i] = CULL_OCCLUDED);
                s.culledOcclusion++;
                continue;
            }
        }
        // 5. an instanced item in a shading without surfaces (wire): the
        // renderer draws no instanced edges or points, so nothing of it
        // is drawn (and no instance buffer is set up for it)
        if (d.instances != null && !f.drawSurfaces) {
            unchecked(out.main[i] = CULL_NOT_DRAWN);
            continue;
        }
        unchecked(out.main[i] = CULL_DRAWN);
        countDrawn(f, d, s);
    }
}

// CullResult.used and .shaded of `out`, from its main pass and shadow
// tiles and `f`'s items' lines and points.
function markUsed(f: RenderFrame, out: CullResult): void {
    const n = f.items.length;
    const used = out.used;
    const shaded = out.shaded;
    used.length = n;
    shaded.length = n;
    for (let i = 0; i < n; i++) {
        const drawn = unchecked(out.main[i]) == CULL_DRAWN;
        unchecked(shaded[i] = drawn);
        unchecked(used[i] = drawn || unchecked(out.casters[i]) != 0);
    }
    for (let k = 0; k < f.itemLines.length; k++) {
        const s = <i32>f.itemLines[k].slot - 1;
        if (s >= 0 && s < n) unchecked(used[s] = true);
    }
    for (let k = 0; k < f.itemPoints.length; k++) {
        const s = <i32>f.itemPoints[k].slot - 1;
        if (s >= 0 && s < n) unchecked(used[s] = true);
    }
}

// The draw calls the shadow pass makes for caster `d` in one tile
// (gpu/renderer.as `shadowPass`): in material mode one per range whose
// material does not blend, else one. A range with no material of its own
// (key -1) is drawn with the default group, so it counts too.
export function shadowDrawsOf(f: RenderFrame, d: DrawItem): i32 {
    const g = d.mesh;
    if (g == null) return 0;
    if (!f.materialMode) return 1;
    let draws = 0;
    for (let k = 0; k < g.ranges.length; k++) if (castsRange(f, d, k)) draws++;
    return draws;
}

// Milestone 61: whether next pass's item `d` is drawn in this frame's
// shading: never without materials; in a shading other than lit only when
// one of its ranges is no ShaderMaterial (custom shaders draw in lit alone,
// and a next pass's ShaderMaterial without its module is drawn in no pass:
// gpu/renderer.as nextPassWithout). Allocates nothing.
function nextPassDrawn(f: RenderFrame, d: DrawItem): bool {
    if (!f.materialMode) return false;
    if (f.shading == SHADE_LIT) return true;
    const mats = f.materials;
    for (let k = 0; k < d.materials.length; k++) {
        const key = unchecked(d.materials[k]);
        if (key >= 0 && key < <i64>mats.length && mats[<i32>key].custom == null) return true;
    }
    return false;
}

// Milestone 61: whether range `k` of `d` is drawn at all (a next pass's
// item's ranges without a next pass are not: see the header).
export function rangeDrawn(d: DrawItem, k: i32): bool {
    return d.nextPassOf < 0 || (k < d.materials.length && unchecked(d.materials[k]) >= 0);
}

// Whether range `k` of `d` is drawn into the shadow tiles (in a material
// shading): drawn, not blended, and not a ShaderMaterial that casts no
// shadow. A range with no material of its own (key -1) is drawn with the
// default group, so it casts.
export function castsRange(f: RenderFrame, d: DrawItem, k: i32): bool {
    if (!rangeDrawn(d, k)) return false;
    const key: i64 = k < d.materials.length ? unchecked(d.materials[k]) : -1;
    const mats = f.materials;
    if (key < 0 || key >= <i64>mats.length) return true;
    const m = mats[<i32>key];
    if (m.alphaMode == ALPHA_BLEND) return false;
    const c = m.custom;
    return c == null || c.program.castsShadows();
}

// The surface draws `d` makes in the main pass (one per range in a
// material shading, its ranges without a next pass left out for a next
// pass's item; else one).
export function mainRangeDraws(f: RenderFrame, d: DrawItem): i32 {
    const g = d.mesh;
    if (g == null || !f.drawSurfaces) return 0;
    if (!f.materialMode) return 1;
    if (d.nextPassOf < 0) return g.ranges.length;
    let n = 0;
    for (let k = 0; k < g.ranges.length; k++) if (rangeDrawn(d, k)) n++;
    return n;
}

// Adds a drawn item to `s`: its draws, copies and triangles.
export function countDrawn(f: RenderFrame, d: DrawItem, s: RenderStats): void {
    const g = d.mesh;
    if (g == null) return;
    const inst = d.instances;
    const copies: i64 = inst != null ? <i64>inst.count : 1;
    s.draws += mainRangeDraws(f, d);
    s.instances += copies;
    s.triangles += <i64>lodTriangles(g, d.lod) * copies;
}

// Milestone 48: the box of a skinned item (DrawItem.skin) in the frame's
// world space, from its palette's first `joints` matrices and `local`, the
// box of its mesh as stored (the bind pose). Every skinned vertex is a
// weighted mean (the weights are at least 0 and sum to 1) of its point
// through four palette matrices, and each of those lies in the box of
// `local` through that matrix, so the vertex lies in the box around all of
// them: the box returned, which culling can therefore never leave out
// wrongly, whatever the pose. (It is the skeleton's box grown by the
// mesh's extent: a matrix's translation is where its bone carries the bind
// space's origin.) Nothing is allocated; `local` itself for no joint.
export function skinnedBounds(palette: Float32Array, joints: i32, local: Bounds): Bounds {
    const n = min<i32>(joints, palette.length / 12);
    if (n <= 0) return local;
    const lo = local.min;
    const hi = local.max;
    let mnx = f32.MAX_VALUE, mny = f32.MAX_VALUE, mnz = f32.MAX_VALUE;
    let mxx = -f32.MAX_VALUE, mxy = -f32.MAX_VALUE, mxz = -f32.MAX_VALUE;
    for (let k = 0; k < n; k++) {
        const o = k * 12;
        for (let r = 0; r < 3; r++) {
            const a = unchecked(palette[o + r * 4]);
            const b = unchecked(palette[o + r * 4 + 1]);
            const c = unchecked(palette[o + r * 4 + 2]);
            const t = unchecked(palette[o + r * 4 + 3]);
            const ax = a * lo.x, bx = a * hi.x;
            const ay = b * lo.y, by = b * hi.y;
            const az = c * lo.z, bz = c * hi.z;
            const lowest = t + Mathf.min(ax, bx) + Mathf.min(ay, by) + Mathf.min(az, bz);
            const highest = t + Mathf.max(ax, bx) + Mathf.max(ay, by) + Mathf.max(az, bz);
            if (r == 0) {
                mnx = Mathf.min(mnx, lowest);
                mxx = Mathf.max(mxx, highest);
            } else if (r == 1) {
                mny = Mathf.min(mny, lowest);
                mxy = Mathf.max(mxy, highest);
            } else {
                mnz = Mathf.min(mnz, lowest);
                mxz = Mathf.max(mxz, highest);
            }
        }
    }
    return Bounds(Vec3(mnx, mny, mnz), Vec3(mxx, mxy, mxz));
}
