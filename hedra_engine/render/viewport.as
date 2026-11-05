// Viewports as textures (milestone 34, Godot's SubViewport and
// ViewportTexture): what a frame carries of the viewports it shows, the
// budgets, and which of them draw in a frame. The scene's side
// (engine/src/scene/render/viewports.as) fills RenderFrame.viewports; the
// GPU side (gpu/viewports.as) draws each one the schedule picks into its
// targets before the main view, as the probes' live captures are drawn,
// and binds them wherever a texture slot names one of its textures
// (MaterialBinder.setLive), so a material, a decal or a probe's capture
// samples the picture as it samples an artboard's.
//
// A viewport's view is a RenderFrame of its own (`ViewportDesc.frame`):
// its camera, its size, its lights and environment, its background; it
// shares the main frame's items, materials, decals and bake, and draws
// only the items of its world (DrawItem.scenario == its frame's scenario:
// cull.as leaves the others out of every pass). A viewport that shares
// its parent's world (own_world_3d off, Godot's default) has the main
// frame's scenario; one with a world of its own has its own scenario, its
// own lights and environment, and the items of the nodes under it alone.
//
// The order of RenderFrame.viewports is the drawing order: each viewport
// after those whose textures its world shows, so that it shows their
// pictures of this frame; a loop (a monitor in the view of its own camera,
// two mirrors facing each other) is cut where it closes, and there the
// picture shown is the one of the frame before, as in Godot. Each
// viewport draws at most once a frame, so a loop costs nothing more.
//
// Godot's update modes (SubViewport.render_target_update_mode), as the
// schedule applies them:
//   disabled             never drawn again; the texture keeps its last
//                        picture (transparent black when it never drew)
//   once                 drawn once, then as disabled until `once` is
//                        written again: a change to it (a key, a binding,
//                        the Inspector), or any write of it from a script,
//                        even over `once` (ViewportDesc.onceWrites), as
//                        Godot takes a new picture at each write
//   when_visible         drawn while its texture was drawn in the frame
//                        before (Godot's render_target_was_used: an item
//                        that shows it drawn in a view, a decal that paints
//                        it in a view's pool)
//   when_parent_visible  drawn while the SubViewport's parent is visible
//   always               drawn every frame
// A viewport that has never drawn draws at the first frame it may (every
// mode but disabled), so that a scene's first picture, `render`'s, holds
// every viewport. The frame budget (VIEWPORT_RENDERS_PER_FRAME) bounds the
// rest: past it, the viewports that waited longest draw first, the others
// keep their picture for a later frame.
//
// The GPU side lets a viewport's picture go when a frame no longer shows
// it (a frame without viewports: another shading, a tab without them; a
// plan without its key) and says so (ViewportSchedule.forgetKey): its next
// frame then draws it as a first picture again, in every mode, and a
// `disabled` one that had drawn draws once more, to keep a picture rather
// than none.

import { Vec3 } from "../base/vecmath";
import { Camera, Projection } from "./camera";
import { RenderFrame } from "./frame";

// The viewports a frame draws: past MAX_VIEWPORTS (in the scene's order)
// a SubViewport is not drawn (its textures stay transparent black).
export const MAX_VIEWPORTS: i32 = 8;
// How deep SubViewports nest: one inside MAX_VIEWPORT_DEPTH others (a
// screen in a world of its own, inside another) is not drawn.
export const MAX_VIEWPORT_DEPTH: i32 = 3;
// How many viewports draw in one frame, at most, after their first.
export const VIEWPORT_RENDERS_PER_FRAME: i32 = 4;
// A SubViewport's size: each side 1 to MAX_VIEWPORT_SIDE, Godot's default
// DEFAULT_VIEWPORT_SIDE square.
export const MAX_VIEWPORT_SIDE: i32 = 4096;
export const DEFAULT_VIEWPORT_SIDE: i32 = 512;
// How many records of viewports no longer planned the schedule keeps
// (ViewportSchedule.trim), so that a renderer drawing one tree after
// another (a built project's scenes, the editor's reloads) holds a bounded
// number: a viewport that comes back after more than this many others left
// draws as one never seen (a `disabled` one stays blank).
export const VIEWPORT_RECORDS_KEPT: i32 = 32;

// Godot's SubViewport.UpdateMode, by number.
export const UPDATE_DISABLED: i32 = 0;
export const UPDATE_ONCE: i32 = 1;
export const UPDATE_WHEN_VISIBLE: i32 = 2;
export const UPDATE_WHEN_PARENT_VISIBLE: i32 = 3;
export const UPDATE_ALWAYS: i32 = 4;

// The scenario (Godot's RenderingServer name for a world being drawn) of
// the main world: every item and decal of a scene without a SubViewport
// that has a world of its own.
export const SCENARIO_MAIN: i32 = 0;

// The update mode's name as the format writes it ("when_visible").
export function updateModeName(mode: i32): string {
    switch (mode) {
        case UPDATE_DISABLED: return "disabled";
        case UPDATE_ONCE: return "once";
        case UPDATE_WHEN_PARENT_VISIBLE: return "when_parent_visible";
        case UPDATE_ALWAYS: return "always";
        default: return "when_visible";
    }
}

// One viewport of a frame (see the header). Filled by the scene's side,
// refreshed in place; read by the schedule and the GPU side.
export class ViewportDesc {
    // What the GPU side keeps its targets and the schedule its state by,
    // from plan to plan: the SubViewport's path (`path`) within its tree,
    // the tree told apart ("12:Monitor/Feed": its root's serial), so that
    // another tree drawn by the same renderer (another tab, the scene a
    // Scene3D changed to, the same file loaded again) starts afresh.
    key: string = "";
    // The SubViewport's path from the root ("Monitor/Feed"), as the tools
    // print it.
    path: string = "";
    // The node's name, for the statistics and the warnings.
    label: string = "";
    // What it draws: its camera, its size (width x height, ssaa 1), its
    // scenario, lights, environment and background (`transparent`: alpha
    // 0 where nothing is drawn); the main frame's items, materials, decals,
    // lightmap and probes. No grid, overlay, line or outline.
    frame: RenderFrame;
    // Whether its world has a camera it looks through; without one it
    // draws nothing (its texture keeps its clear picture), as Godot's.
    camera: bool = false;
    // Its render_target_update_mode (UPDATE_*), and whether its parent is
    // visible (UPDATE_WHEN_PARENT_VISIBLE reads it).
    mode: i32 = UPDATE_WHEN_VISIBLE;
    // How many times `once` was written to its node (SubViewport
    // .onceWrites): a new count re-arms `once`, even over `once`.
    onceWrites: i32 = 0;
    parentVisible: bool = true;
    // 1 for a SubViewport under none, 2 under one, ...
    depth: i32 = 1;
    // Within MAX_VIEWPORTS and MAX_VIEWPORT_DEPTH (the scene's side says
    // which are not, with a warning): the GPU side draws only these.
    drawable: bool = true;
    // The ViewportTextures that show it: their paths (the binder's live
    // keys are texKey(path, srgb)), and for each whether a slot samples
    // it as colour (base colour, emission: the colour target) and as data
    // (normal, ORM, metallic-roughness: the data target).
    paths: Array<string> = [];
    colour: Array<bool> = [];
    data: Array<bool> = [];
    // Its bit in DrawItem.viewports and DecalDesc.viewports: 1 << its index
    // in RenderFrame.viewports (at most MAX_VIEWPORTS, so a u32 holds all).
    bit: u32 = 0;

    constructor() {
        const cam = new Camera(Vec3(0, 0, 0), Vec3(0, -1, 0), Vec3(0, 0, 1), Projection.perspective(75), 0.05, 4000);
        this.frame = new RenderFrame(<u32>DEFAULT_VIEWPORT_SIDE, <u32>DEFAULT_VIEWPORT_SIDE, cam);
    }
}

// What a frame's viewports came to (the GPU side's after each frame; the
// CLI's `render` works out the first frame's on the CPU with the same
// schedule): `scene` the viewports the frame carries, `drawable` those
// within the budgets, `drawn` those drawn this frame, `deferred` those
// that wanted to and were left for a later frame by the frame budget,
// `disabled` those whose mode keeps them from drawing (disabled, once
// done, a parent hidden), `noCamera` those with no camera, `live` the
// texture views bound live, `pixels` the pixels drawn this frame (each
// drawn viewport's width x height).
export class ViewportStats {
    scene: i32 = 0;
    drawable: i32 = 0;
    drawn: i32 = 0;
    deferred: i32 = 0;
    disabled: i32 = 0;
    noCamera: i32 = 0;
    live: i32 = 0;
    pixels: i64 = 0;

    reset(): void {
        this.scene = 0;
        this.drawable = 0;
        this.drawn = 0;
        this.deferred = 0;
        this.disabled = 0;
        this.noCamera = 0;
        this.live = 0;
        this.pixels = 0;
    }
}

// What the schedule keeps of one viewport (by ViewportDesc.key) from frame
// to frame and plan to plan: whether it has ever drawn, whether `once` is
// done, the mode and the count of `once` writes it had at the last plan (a
// change to `once`, or a new count, re-arms it), whether the GPU side let
// its picture go after it drew (`lost`: forgetKey), the plans since its
// last draw, whether its texture was drawn in the host frame before, and
// its bit in the frame planned last (what `used` bits mean).
export class ViewportRecord {
    key: string;
    everDrawn: bool = false;
    onceDone: bool = false;
    lastMode: i32 = -1;
    onceWrites: i32 = 0;
    lost: bool = false;
    age: i32 = 0;
    usedLast: bool = false;
    // In the frame planned last, with this bit.
    planned: bool = false;
    bit: u32 = 0;
    // The plan it was last in (ViewportSchedule's count of plans), which
    // `trim` keeps the latest of; and whether `trim` is dropping it.
    seen: i64 = 0;
    dropping: bool = false;

    constructor(key: string) {
        this.key = key;
    }
}

// Which of a frame's viewports draw (the header's rules), kept from frame
// to frame by ViewportDesc.key: a frame drawn again, or planned again from
// the same tree, picks as the one before it would have. Allocates nothing
// once each key has been seen.
export class ViewportSchedule {
    // The indices in RenderFrame.viewports of those that draw this frame,
    // in the frame's order: chosen[0 .. count).
    chosen: Array<i32> = [];
    count: i32 = 0;
    // The frame budget (tests lower it).
    budget: i32 = VIEWPORT_RENDERS_PER_FRAME;
    stats: ViewportStats = new ViewportStats();
    // Every key seen since the schedule was made (or forgotten), and by
    // index of the frame planned last, its record.
    records: Array<ViewportRecord> = [];
    byIndex: Array<ViewportRecord?> = [];
    // The bits `used` collected since the last plan.
    private usedNow: u32 = 0;
    // How many plans were made: each record's `seen` is one of these.
    private plans: i64 = 0;
    // By index of the frame being planned: 0 not drawn, 1 a first draw
    // (outside the budget), 2 wants to draw (within the budget), 3 picked.
    private want: Array<u8> = [];

    // Picks the viewports of `f` that draw this frame into `chosen`, and
    // counts `stats` (all but `live` and `pixels`, the GPU side's); returns
    // `count`.
    plan(f: RenderFrame): i32 {
        // The bits the views drew since the last plan, by the records of
        // the frame planned then (its bits, not this frame's: a replan may
        // number the viewports anew).
        const recs = this.records;
        const used = this.usedNow;
        for (let i = 0; i < recs.length; i++) {
            const r = unchecked(recs[i]);
            r.usedLast = r.planned && (used & r.bit) != 0;
            r.planned = false;
        }
        this.usedNow = 0;
        this.chosen.length = 0;
        this.count = 0;
        const stamp = ++this.plans;
        const s = this.stats;
        s.reset();
        const vs = f.viewports;
        const n = vs.length;
        s.scene = n;
        const by = this.byIndex;
        if (by.length < n) by.length = n;
        const want = this.want;
        if (want.length < n) want.length = n;
        let wanting = 0;
        for (let k = 0; k < n; k++) {
            const d = unchecked(vs[k]);
            let r = unchecked(by[k]);
            if (r == null || r.key != d.key) {
                r = this.recordOf(d.key);
                unchecked(by[k] = r);
            }
            r.planned = true;
            r.seen = stamp;
            r.bit = d.bit;
            if (r.age < i32.MAX_VALUE) r.age++;
            const rearm = r.lastMode != UPDATE_ONCE || d.onceWrites != r.onceWrites;
            if (d.mode == UPDATE_ONCE && rearm) r.onceDone = false;
            r.lastMode = d.mode;
            r.onceWrites = d.onceWrites;
            unchecked(want[k] = 0);
            if (!d.drawable) continue;
            s.drawable++;
            if (!d.camera) {
                s.noCamera++;
                continue;
            }
            // (a disabled one whose picture was let go draws it again)
            if (d.mode == UPDATE_DISABLED && !r.lost) {
                s.disabled++;
                continue;
            }
            // Its first picture, at the first frame it may: outside the
            // budget.
            if (!r.everDrawn) {
                unchecked(want[k] = 1);
                continue;
            }
            let wants = false;
            switch (d.mode) {
                case UPDATE_ONCE: wants = !r.onceDone; break;
                case UPDATE_WHEN_PARENT_VISIBLE: wants = d.parentVisible; break;
                case UPDATE_ALWAYS: wants = true; break;
                default: wants = r.usedLast; break;
            }
            if (!wants) {
                s.disabled++;
                continue;
            }
            unchecked(want[k] = 2);
            wanting++;
        }
        // The budget: every one that wants to while they fit, else the
        // longest waiting (the first in the frame's order among equals).
        if (wanting <= this.budget) {
            for (let k = 0; k < n; k++) if (unchecked(want[k]) == 2) unchecked(want[k] = 3);
        } else {
            for (let p = 0; p < this.budget; p++) {
                let best = -1;
                let bestAge = -1;
                for (let k = 0; k < n; k++) {
                    if (unchecked(want[k]) != 2) continue;
                    const age = unchecked(by[k])!.age;
                    if (age > bestAge) {
                        best = k;
                        bestAge = age;
                    }
                }
                if (best < 0) break;
                unchecked(want[best] = 3);
            }
            s.deferred = wanting - max<i32>(this.budget, 0);
        }
        for (let k = 0; k < n; k++) {
            const w = unchecked(want[k]);
            if (w == 1 || w == 3) this.chosen.push(k);
        }
        this.count = this.chosen.length;
        s.drawn = this.count;
        return this.count;
    }

    // The viewport `k` of the frame planned last drew (its first picture is
    // made; once is done).
    drew(k: i32): void {
        if (k < 0 || k >= this.byIndex.length) return;
        const r = unchecked(this.byIndex[k]);
        if (r == null) return;
        r.everDrawn = true;
        r.onceDone = true;
        r.lost = false;
        r.age = 0;
    }

    // The GPU side let viewport `key`'s picture go (see the header): its
    // record starts afresh, so its next frame draws it as a first picture
    // (`lost` when it had drawn: a disabled one draws once more). Kept
    // rather than removed, so the frame planned last still finds it.
    // Allocates nothing.
    forgetKey(key: string): void {
        const recs = this.records;
        for (let i = 0; i < recs.length; i++) {
            const r = unchecked(recs[i]);
            if (r.key != key) continue;
            r.lost = r.lost || r.everDrawn;
            r.everDrawn = false;
            r.onceDone = false;
            r.usedLast = false;
            r.age = 0;
            return;
        }
    }

    // The viewports whose textures the frame's views drew (an OR of the
    // drawn items' DrawItem.viewports and the pooled decals'
    // DecalDesc.viewports): what when_visible reads at the next plan.
    used(bits: u32): void {
        this.usedNow |= bits;
    }

    // Keeps the records of `plan`'s viewports and, of the others, the
    // VIEWPORT_RECORDS_KEPT seen last (in the latest plans; insertion
    // order breaks ties); the index of the frame planned last
    // is dropped (the next plan finds its records again). The GPU side
    // calls it when its plan changes, never per frame; allocates nothing.
    trim(plan: Array<ViewportDesc>): void {
        const recs = this.records;
        let others = 0;
        for (let i = 0; i < recs.length; i++) if (!planHas(plan, unchecked(recs[i]).key)) others++;
        let drop = others - VIEWPORT_RECORDS_KEPT;
        if (drop <= 0) return;
        // The `drop` others planned longest ago, one at a time (a few dozen
        // records, a trim per plan change: no sort, no allocation).
        for (; drop > 0; drop--) {
            let oldest = -1;
            for (let i = 0; i < recs.length; i++) {
                const r = unchecked(recs[i]);
                if (r.dropping || planHas(plan, r.key)) continue;
                if (oldest < 0 || r.seen < unchecked(recs[oldest]).seen) oldest = i;
            }
            unchecked(recs[oldest]).dropping = true;
        }
        let w = 0;
        for (let i = 0; i < recs.length; i++) {
            const r = unchecked(recs[i]);
            if (r.dropping) continue;
            unchecked(recs[w++] = r);
        }
        recs.length = w;
        this.byIndex.length = 0;
    }

    // Forgets every viewport (a new renderer, a released one).
    forget(): void {
        this.chosen.length = 0;
        this.count = 0;
        this.records.length = 0;
        this.byIndex.length = 0;
        this.usedNow = 0;
    }

    // The record of `key`, made the first time it is seen.
    private recordOf(key: string): ViewportRecord {
        const recs = this.records;
        for (let i = 0; i < recs.length; i++) {
            const r = unchecked(recs[i]);
            if (r.key == key) return r;
        }
        const r = new ViewportRecord(key);
        recs.push(r);
        return r;
    }
}

// Whether one of `plan`'s viewports is keyed `key`.
function planHas(plan: Array<ViewportDesc>, key: string): bool {
    for (let k = 0; k < plan.length; k++) if (unchecked(plan[k]).key == key) return true;
    return false;
}
