// Lights per object (milestone 59): the budgets, and what a frame's light
// selection holds for the camera it was planned from. Godot's Mobile and
// Compatibility renderers draw up to 8 lights per mesh, chosen from all of
// the scene's lights; Hedra does the same within what WebGL 2 allows (no
// storage buffers; uniform blocks of 16 KB): the lit block (gpu/layouts.as
// LitUniform) holds the frame's pool of at most MAX_FRAME_LIGHTS lights,
// each item names up to MAX_OBJECT_LIGHTS entries of the pool in its
// ObjectUniform.lights, and the surface shader's light loops read those
// (surface.wgsl `object_light`), so a pixel never pays for more than 8.
//
// light_select.as chooses (planLightPool: the pool for the frame's camera;
// assignItemLights: each item's list); this file only holds the numbers,
// so that frame.as can carry a LightPlan without importing the selection.
// Imports nothing of the renderer's.

// The most lights a frame draws (the lit block's entries: gpu/layouts.as
// LIT_UNIFORM_LIGHTS; the light tests check they agree). Beyond it the
// directional lights are kept first, then the omni and spot lights nearest
// the camera, and the statistics count the rest.
export const MAX_FRAME_LIGHTS: i32 = 64;
// The most lights one item draws (Godot Mobile's 8 per mesh instance):
// every directional light first, then those of the rest whose contribution
// at the item is the largest (light_select.as says how).
export const MAX_OBJECT_LIGHTS: i32 = 8;
// The most lights whose shadow one view draws (gpu/layouts.as
// SHADOW_UNIFORM_LIGHTS): every shadowed light takes at least one of the
// atlas's SHADOW_TILES tiles, so no view can shadow more.
export const MAX_SHADOW_LIGHTS: i32 = 16;
// The directional lights the lit block lists for the fog's sun scatter and
// the sky's suns (LitUniform.dirs): the first ones of the pool, in its
// order.
export const MAX_POOL_DIRECTIONAL: i32 = 8;

// The numbers LightPlan.tests holds a light (light_select.as reads them).
export const LIGHT_TEST_FLOATS: i32 = 12;
// MatchScratch.entries (light_select.as): the bit added to a position in `order` when the light
// reaches every item of the cluster (the positions are below 64).
export const ENTRY_WHOLE: i32 = 0x100;

// The lights shading's colours (frame.as SHADE_LIGHT_COUNT; surface.wgsl's
// LIGHT_COUNT_COLORS, which the WGSL test checks against these), sRGB
// 0xRRGGBB, by the number of lights reaching an item: 0 (grey: unlit but
// for the ambient light), 1 to 8 a ramp from deep blue through green and
// yellow to orange (8: the budget full), and past 8 magenta (over budget:
// the item draws the 8 that matter most and leaves the rest out).
export const LIGHT_COUNT_COLORS: StaticArray<u32> = [
    0x5a5a5a, 0x2b3f99, 0x2166ac, 0x1a9fb8, 0x1fa187, 0x4dbb5a, 0xa6d43a, 0xf2c80f, 0xf28e0f, 0xe0218a,
];

// What planLightPool and assignItemLights chose for one camera (kept on the
// frame, RenderFrame.lightPlan, and refilled in place every time the
// renderer draws a view of it: a warm frame allocates nothing).
export class LightPlan {
    // Indices into RenderFrame.lights, in the scene's order (the order an
    // item's lights are summed in, so that a scene of 8 lights or fewer
    // draws exactly as before lights per object), the first `count` of
    // MAX_FRAME_LIGHTS.
    pool: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS);
    count: i32 = 0;
    // The pool entries of its directional lights, in pool order, the first
    // `dirCount` of MAX_POOL_DIRECTIONAL.
    dirs: StaticArray<i32> = new StaticArray<i32>(MAX_POOL_DIRECTIONAL);
    dirCount: i32 = 0;
    // The frame's lights in the view (every directional light, and the
    // omni and spot lights whose range meets the camera's frustum), and
    // those of them left out of the pool (beyond MAX_FRAME_LIGHTS), the
    // first of them by index into RenderFrame.lights in `droppedLights`
    // (its length is `dropped`; its storage is kept).
    visible: i32 = 0;
    dropped: i32 = 0;
    droppedLights: Array<i32> = [];
    // Set by assignItemLights: the items that draw at least one light, the
    // light entries given out in all (the statistics' lights per draw), the
    // items more than MAX_OBJECT_LIGHTS reach (they draw the 8 that matter
    // most), and the most lights any one item is reached by.
    items: i32 = 0;
    assigned: i32 = 0;
    overBudget: i32 = 0;
    maxReached: i32 = 0;
    // Whether the pool was planned without the frustum test (a probe's
    // capture, which looks every way from one point): every light, nearest
    // to the eye first past MAX_FRAME_LIGHTS.
    everyWay: bool = false;

    // The selection's scratch, kept from frame to frame (their storage is
    // reused; light_select.as owns what they hold): the candidates' indices
    // into RenderFrame.lights and their distance keys, the nearest
    // MAX_FRAME_LIGHTS of them when there are more, and per pool entry what
    // matching the items reads, flat, so that it reads no struct.
    candidates: Array<i32> = [];
    keys: Array<f32> = [];
    nearest: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS);
    // By pool entry: the kind (frame.as LIGHT_*).
    kinds: StaticArray<u32> = new StaticArray<u32>(MAX_FRAME_LIGHTS);
    // By pool entry, 8 numbers: position x, y, z, range, then the spot's
    // unit direction x, y, z and the cosine of its cone's half angle (0 0 0
    // and -1 for an omni or a directional light).
    spheres: StaticArray<f32> = new StaticArray<f32>(MAX_FRAME_LIGHTS * 8);
    // By pool entry, 2 numbers: |energy| times the colour's luminance, and
    // the distance attenuation exponent (the score's).
    weights: StaticArray<f32> = new StaticArray<f32>(MAX_FRAME_LIGHTS * 2);
    // What matching an item reads of the pool's omni and spot lights
    // (`others` of them, in the order below): each one's pool entry (`order`), and
    // LIGHT_TEST_FLOATS numbers a light: its position x, y, z and the
    // square of the distance its reach test allows (its range widened by a
    // hair for f32 rounding); a spot's unit direction x, y, z and the
    // cosine and the sine of its half angle widened the same way (0 0 0, -2
    // and 0: an omni light, or a cone of 89.9 degrees or more, which every
    // box meets); and its score's numbers, the square of its weight, 1 /
    // range^2 and its attenuation. The pool's directional lights as bits by
    // entry (all of them, the first MAX_OBJECT_LIGHTS of them), and how many
    // there are. light_select.as says why.
    order: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS);
    others: i32 = 0;
    tests: StaticArray<f32> = new StaticArray<f32>(MAX_FRAME_LIGHTS * LIGHT_TEST_FLOATS);
    dirBits: u64 = 0;
    dirBitsKept: u64 = 0;
    dirTotal: i32 = 0;
    // The same without the static lights (bakeMode LIGHT_BAKE_STATIC), for
    // an item drawn lightmapped, whose shading skips them (its lightmap
    // holds their light): `order` lists the omni and spot lights that are
    // not static first (`liveOthers` of them), then the static ones, each in
    // pool order; the directional lights that are not static as bits by
    // entry (all, the first MAX_OBJECT_LIGHTS) and their number. `statics`:
    // whether the pool holds any static light (else no item is told apart).
    liveOthers: i32 = 0;
    liveDirBits: u64 = 0;
    liveDirBitsKept: u64 = 0;
    liveDirTotal: i32 = 0;
    statics: bool = false;
    // The items' clusters (light_select.as says when and how): by item, its
    // cell of the grid or -1 (matched alone); by cell, how many items, then
    // where its run of `cellItems` (item indices, cell by cell) begins; the
    // clusters matched last (a count for the tests and the benches).
    itemCell: Array<i32> = [];
    cellStart: Array<i32> = [];
    cellItems: Array<i32> = [];
    clusters: i32 = 0;
    // (what matching an item and a cluster works in is each worker's own:
    // light_select.as MatchScratch)

    // Empties the plan's choices (the pool and the counts), keeping every
    // storage.
    reset(): void {
        this.count = 0;
        this.dirCount = 0;
        this.visible = 0;
        this.dropped = 0;
        this.droppedLights.length = 0;
        this.items = 0;
        this.assigned = 0;
        this.overBudget = 0;
        this.maxReached = 0;
        this.everyWay = false;
        this.others = 0;
        this.dirBits = 0;
        this.dirBitsKept = 0;
        this.dirTotal = 0;
        this.liveOthers = 0;
        this.liveDirBits = 0;
        this.liveDirBitsKept = 0;
        this.liveDirTotal = 0;
        this.statics = false;
    }

    // Pool entry `k`'s index into RenderFrame.lights (0 <= k < count).
    lightAt(k: i32): i32 {
        return unchecked(this.pool[k]);
    }

    // The pool entry of RenderFrame.lights index `light`, or -1 when it is
    // not in the pool.
    entryOf(light: i32): i32 {
        for (let k = 0; k < this.count; k++) if (unchecked(this.pool[k]) == light) return k;
        return -1;
    }
}
