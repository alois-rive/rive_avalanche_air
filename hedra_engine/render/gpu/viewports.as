// Viewports on the GPU (milestone 34; engine/src/render/viewport.as says
// what a frame carries and which viewports draw): the targets each
// viewport's picture is kept in, and binding them where a texture slot
// names one of its ViewportTextures.
//
// FrameRenderer.renderFramePlanned draws the viewports the schedule picks
// (ViewportSchedule.plan) before the main view, each as a view of its own
// (its frame, its own uniform slot: FrameRenderer's viewport slots, kept
// apart from the main views' so that neither's pooled targets change size
// from frame to frame), the full pipeline of a view: shadows, the sky
// (none with a transparent background), the surfaces of its world, its
// environment's post-processing, the sRGB encode. The picture that view
// gives (rgba8unorm, straight-alpha sRGB bytes, the layout of a CPU
// Image) lasts only until the renderer's next frame, so `finish` blits it
// at once into the viewport's own targets, made on its first draw and kept
// by ViewportDesc.key from plan to plan: a colour target (the renderer's
// colour format, rgba16float: linear colour, as an sRGB texture upload
// is) when a slot samples it as colour, a data target (rgba8unorm, the
// bytes as they are) when one samples it as data, the blit
// gpu/live_texture.as's (its straight-alpha entry points: with a
// transparent background the encode passes divide the resolve's
// premultiplied colour by alpha, so the picture is straight already). Then each of its textures' paths is set live
// on the frame renderer's MaterialBinder (setLive), so every material
// group, decal layer and probe capture that names one binds the target, as
// an artboard's: nothing a material binds changes for a viewport. A
// viewport never drawn leaves its textures' `image` bound (one transparent
// black texel).
//
// Godot's semantics hold for a loop: a view that shows its own texture (a
// monitor its camera sees) samples the target while its new picture is
// drawn into its view's slot, so it shows the picture of the frame before.
//
// A host that refuses a target or the blit draws that viewport as never
// drawn and raises VIEWPORT_TARGET_WARNING or VIEWPORT_BLIT_WARNING once
// (FrameRenderer.warnings, for a host that reads them; the checks report
// the budgets: viewport-too-many, viewport-too-deep).
//
// Nothing here allocates once each viewport has drawn once: the targets,
// the blit's groups and pass descriptors, the binder's keys (texKey of
// each path, made once a plan) are kept.
//
// A viewport whose world is lit by another sky than the main frame's (a
// world of its own with a WorldEnvironment of its own) gets an image-based
// light of its own: an (IblCache, GpuEnvironment) pair kept here by its
// key, which its view's environment group binds (`ownIbl`,
// `ownEnvironment`), so the main frame's pair never sees its sky and
// neither is built again every frame. Every other viewport is lit through
// the main pair and builds nothing.
//
// What a frame's views drew of the viewports' textures (`noteUsed`: an OR
// of the drawn items' DrawItem.viewports and the pooled decals'
// DecalDesc.viewports) goes to the schedule, which when_visible reads at
// the next frame.
//
// The targets and live keys of a viewport that leaves the plan (a new
// RenderFrame.viewports array without its key, a frame without viewports
// among them) are released and dropped when the plan changes, never per
// frame, and the schedule forgets its state (ViewportSchedule.forgetKey),
// so that when it comes back its picture is drawn again rather than left
// transparent black (a `once` that was done, a `when_visible` whose use
// nothing noted meanwhile). One whose size changes gets new targets, the
// old ones released at the next beginFrame (the passes of this frame may
// still sample them).

import { GPUBindGroup, GPUTextureView } from "rive/gpu";
import { CULL_DRAWN } from "../cull";
import { DecalPlan } from "../decal";
import { MaterialBinder, texKey } from "../material";
import { RenderFrame, SKY_NONE } from "../frame";
import { IblCache, sameSky } from "../sky";
import { ViewportDesc, ViewportSchedule, ViewportStats } from "../viewport";
import { Gpu } from "./device";
import { GpuEnvironment } from "./environment";
import { LiveTarget, LiveTextureBlit } from "./live_texture";

// What the renderer says, once, when a host refuses a viewport's targets
// or the blit.
export const VIEWPORT_TARGET_WARNING = "a viewport is not drawn: the host refused its render targets";
export const VIEWPORT_BLIT_WARNING = "viewports are not drawn: the host refused the blit into their targets";

// One viewport on the GPU, by ViewportDesc.key.
export class GpuViewport {
    key: string;
    // Its targets (null until a draw needs one): the colour form (the
    // blit's colour format, linear) and the data form (rgba8unorm).
    colour: LiveTarget? = null;
    data: LiveTarget? = null;
    // The desc's paths array its live keys were made for (by identity),
    // the keys (texKey of each path and form a slot samples) and their
    // forms (true: colour).
    paths: Array<string>? = null;
    keys: Array<string> = [];
    srgb: Array<bool> = [];
    // Whether its targets hold a picture, and whether the binder holds
    // them under its keys (`live` of them).
    drawn: bool = false;
    bound: bool = false;
    live: i32 = 0;
    // Drawn in this host frame (each viewport draws at most once a frame).
    drawnThisFrame: bool = false;
    // Its own image-based light, when its world's sky is not the main
    // frame's (made on first need, kept).
    ibl: IblCache? = null;
    environment: GpuEnvironment? = null;

    constructor(key: string) {
        this.key = key;
    }

    // The target its key `j` binds (null before a draw made it).
    targetOf(j: i32): LiveTarget? {
        return unchecked(this.srgb[j]) ? this.colour : this.data;
    }
}

// Whether `d`'s textures sample it as colour (`srgb`) or as data in some
// slot (ViewportDesc.colour, .data).
export function viewportWants(d: ViewportDesc, srgb: bool): bool {
    const flags = srgb ? d.colour : d.data;
    for (let i = 0; i < flags.length; i++) if (unchecked(flags[i])) return true;
    return false;
}

// The live keys of `d` into `keys` and their forms into `srgb`: per path,
// texKey(path, true) when a slot samples it as colour, texKey(path, false)
// when one samples it as data (the binder's keys for those slots).
export function viewportKeysInto(d: ViewportDesc, keys: Array<string>, srgb: Array<bool>): void {
    keys.length = 0;
    srgb.length = 0;
    for (let i = 0; i < d.paths.length; i++) {
        const path = d.paths[i];
        if (i < d.colour.length && d.colour[i]) {
            keys.push(texKey(path, true));
            srgb.push(true);
        }
        if (i < d.data.length && d.data[i]) {
            keys.push(texKey(path, false));
            srgb.push(false);
        }
    }
}

// The bits of the viewports whose textures a view of `f` drew: the items
// its main pass drew (`main`, cull.as CULL_DRAWN) and the decals of its
// pool (`plan`). Allocates nothing.
export function usedViewportBits(f: RenderFrame, main: Array<u8>, plan: DecalPlan): u32 {
    let bits: u32 = 0;
    const items = f.items;
    const n = min<i32>(items.length, main.length);
    for (let i = 0; i < n; i++) {
        if (unchecked(main[i]) == CULL_DRAWN) bits |= unchecked(items[i]).viewports;
    }
    const decals = f.decals;
    for (let k = 0; k < plan.count; k++) {
        const at = unchecked(plan.pool[k]);
        if (at >= 0 && at < decals.length) bits |= unchecked(decals[at]).viewports;
    }
    return bits;
}

export class GpuViewports {
    // Which viewports draw each frame (viewport.as), kept by key.
    schedule: ViewportSchedule = new ViewportSchedule();
    // The last frame's (the schedule's counts, `live` and `pixels`
    // added).
    stats: ViewportStats;
    // Every viewport held (by key), and by index of the plan held
    // (`planned`, a RenderFrame.viewports array by identity) its own.
    records: Array<GpuViewport> = [];
    byIndex: Array<GpuViewport?> = [];
    private planned: Array<ViewportDesc>? = null;
    // The blit (made on the first draw), and whether making it or a
    // target was refused (said once each).
    private blit: LiveTextureBlit? = null;
    private blitTried: bool = false;
    private blitWarned: bool = false;
    private targetWarned: bool = false;
    // What a resize or a plan replaced, released at the next beginFrame.
    private retiredTargets: Array<LiveTarget> = [];
    private retiredEnvironments: Array<GpuEnvironment> = [];

    constructor() {
        this.stats = this.schedule.stats;
    }

    // Whether any viewport is held (a frame's views then report what they
    // drew of their textures: `noteUsed`).
    active(): bool {
        return this.records.length > 0;
    }

    // At the start of every host frame that renders (FrameRenderer
    // .beginFrame).
    beginFrame(): void {
        for (let i = 0; i < this.retiredTargets.length; i++) this.retiredTargets[i].release();
        this.retiredTargets.length = 0;
        for (let i = 0; i < this.retiredEnvironments.length; i++) this.retiredEnvironments[i].release();
        this.retiredEnvironments.length = 0;
        const b = this.blit;
        if (b != null) b.releaseRetired();
        const recs = this.records;
        for (let i = 0; i < recs.length; i++) {
            const r = unchecked(recs[i]);
            r.drawnThisFrame = false;
            const e = r.environment;
            if (e != null) e.releaseRetired();
        }
    }

    // The record of viewport `k` of the plan held (null past it).
    at(k: i32): GpuViewport? {
        return k >= 0 && k < this.byIndex.length ? unchecked(this.byIndex[k]) : null;
    }

    // Whether viewport `k` drew already in this host frame.
    drewThisFrame(k: i32): bool {
        const r = this.at(k);
        return r != null && r.drawnThisFrame;
    }

    // The image-based light viewport `k` of `f` is lit with when it is
    // not the main frame's (its world's sky differs), made on first need;
    // null: the main pair (FrameRenderer.ibl, .environment). Allocates
    // nothing once made.
    ownIbl(k: i32, f: RenderFrame): IblCache? {
        const r = this.at(k);
        if (r == null || k >= f.viewports.length) return null;
        const e = f.viewports[k].frame.environment;
        if (e.skyDesc.kind == SKY_NONE || sameSky(e, f.environment)) return null;
        if (r.ibl == null) {
            r.ibl = new IblCache();
            r.environment = new GpuEnvironment();
        }
        return r.ibl;
    }

    // The maps of `ownIbl`'s light (null with the main pair).
    ownEnvironment(k: i32): GpuEnvironment? {
        const r = this.at(k);
        return r != null && r.ibl != null ? r.environment : null;
    }

    // After viewport `d`'s view drew `picture` (`width` x `height`, the
    // view's result: FrameRenderer's GpuImage view): blits it into `d`'s
    // targets and sets each of `d.paths` live on `binder` as its slots need
    // (ViewportDesc.colour, .data). False (said once in `warnings`) when
    // the host refused a target or the blit.
    finish(d: ViewportDesc, picture: GPUTextureView, width: u32, height: u32, gpu: Gpu,
        binder: MaterialBinder<GPUTextureView, GPUBindGroup>, warnings: Array<string>): bool {
        const r = this.recordFor(d);
        if (r == null) return false;
        r.drawnThisFrame = true;
        this.stats.pixels += <i64>width * <i64>height;
        const blit = this.blitOn(gpu, warnings);
        if (blit == null) return false;
        const colour = viewportWants(d, true);
        const data = viewportWants(d, false);
        let ok = true;
        if (colour) ok = this.ensure(r, true, width, height, blit, warnings) && ok;
        else this.drop(r, true);
        if (data) ok = this.ensure(r, false, width, height, blit, warnings) && ok;
        else this.drop(r, false);
        const c = r.colour;
        if (c != null && !blit.blitStraight(picture, c)) ok = this.blitRefused(warnings);
        const t = r.data;
        if (ok && t != null && !blit.blitStraight(picture, t)) ok = this.blitRefused(warnings);
        if (!ok) return false;
        r.drawn = true;
        if (!r.bound) this.bind(r, binder);
        return true;
    }

    // Sets live again, on `binder`, the targets of every viewport of `f`
    // that has drawn, where the binder no longer holds them (an owner's
    // clearLive dropped them: the player's artboards on a new renderer).
    // Allocates nothing. Also takes `f`'s plan (see the header): on a new
    // one the viewports that left it are released.
    keepLive(f: RenderFrame, binder: MaterialBinder<GPUTextureView, GPUBindGroup>): void {
        if (f.viewports !== this.planned) this.takePlan(f, binder);
        const by = this.byIndex;
        for (let k = 0; k < by.length; k++) {
            const r = unchecked(by[k]);
            if (r == null || !r.drawn) continue;
            if (!r.bound) {
                this.bind(r, binder);
                continue;
            }
            const keys = r.keys;
            for (let j = 0; j < keys.length; j++) {
                const t = r.targetOf(j);
                if (t != null && !binder.live.has(unchecked(keys[j]))) binder.setLiveKey(unchecked(keys[j]), t.view);
            }
        }
    }

    // The views bound live, into stats.live (after a frame's draws).
    countLive(): void {
        let n = 0;
        const by = this.byIndex;
        for (let k = 0; k < by.length; k++) {
            const r = unchecked(by[k]);
            if (r != null && r.bound) n += r.live;
        }
        this.stats.live = n;
    }

    // What a view of `f` drew of the viewports' textures (see the header),
    // for the schedule's next plan.
    noteUsed(f: RenderFrame, main: Array<u8>, plan: DecalPlan): void {
        this.schedule.used(usedViewportBits(f, main, plan));
    }

    // Releases every target (the renderer is gone); the binder's live
    // views of them are dropped (MaterialBinder.dropLive).
    release(binder: MaterialBinder<GPUTextureView, GPUBindGroup>? = null): void {
        const recs = this.records;
        for (let i = 0; i < recs.length; i++) this.forgetRecord(unchecked(recs[i]), binder);
        recs.length = 0;
        this.byIndex.length = 0;
        this.planned = null;
        this.beginFrame();
        const b = this.blit;
        if (b != null) b.release();
        this.blit = null;
        this.blitTried = false;
        this.schedule.forget();
    }

    // `f`'s plan held (see the header): each viewport's record, made the
    // first time its key is seen, its keys made again when its paths are
    // new, and the records of the keys that left the plan released.
    private takePlan(f: RenderFrame, binder: MaterialBinder<GPUTextureView, GPUBindGroup>): void {
        const vs = f.viewports;
        this.planned = vs;
        const by = this.byIndex;
        by.length = vs.length;
        for (let k = 0; k < vs.length; k++) {
            const d = vs[k];
            const r = this.recordOf(d.key);
            unchecked(by[k] = r);
            if (r.paths !== d.paths) {
                this.unbind(r, binder);
                viewportKeysInto(d, r.keys, r.srgb);
                r.paths = d.paths;
                // A slot that samples it in a form it has no target of yet
                // (its texture put in a normal slot): only a draw makes
                // that target, so a viewport that had drawn and would not
                // again (`once` done, `disabled`) draws one more picture
                // rather than leave that slot blank.
                if (r.drawn) {
                    let missing = false;
                    for (let j = 0; j < r.keys.length && !missing; j++) missing = r.targetOf(j) == null;
                    if (missing) this.schedule.forgetKey(r.key);
                }
            }
        }
        const recs = this.records;
        for (let i = recs.length - 1; i >= 0; i--) {
            const r = recs[i];
            let held = false;
            for (let k = 0; k < by.length && !held; k++) held = unchecked(by[k]) === r;
            if (held) continue;
            this.forgetRecord(r, binder);
            recs.splice(i, 1);
        }
        this.schedule.trim(vs);
    }

    // The record of `key`, made the first time it is seen.
    private recordOf(key: string): GpuViewport {
        const recs = this.records;
        for (let i = 0; i < recs.length; i++) if (unchecked(recs[i]).key == key) return unchecked(recs[i]);
        const r = new GpuViewport(key);
        recs.push(r);
        return r;
    }

    // `d`'s record in the plan held (null when the plan holds none).
    private recordFor(d: ViewportDesc): GpuViewport? {
        const by = this.byIndex;
        for (let k = 0; k < by.length; k++) {
            const r = unchecked(by[k]);
            if (r != null && r.key == d.key) return r;
        }
        return null;
    }

    // `r`'s target of form `srgb` at `width` x `height`: kept when it is
    // that size, else made (the old one released at the next beginFrame,
    // the binder's views of it set again at the next bind). False (said
    // once) when the host refused it: the viewport then keeps its last.
    private ensure(r: GpuViewport, srgb: bool, width: u32, height: u32, blit: LiveTextureBlit,
        warnings: Array<string>): bool {
        const old = srgb ? r.colour : r.data;
        if (old != null && old.width == max<u32>(width, 1) && old.height == max<u32>(height, 1)) return true;
        const t = blit.target(width, height, srgb);
        if (t == null) {
            if (!this.targetWarned) {
                this.targetWarned = true;
                warnings.push(VIEWPORT_TARGET_WARNING);
            }
            return false;
        }
        if (old != null) this.retiredTargets.push(old);
        if (srgb) r.colour = t;
        else r.data = t;
        r.bound = false;
        return true;
    }

    // `r`'s target of form `srgb` released (no slot samples it so now).
    private drop(r: GpuViewport, srgb: bool): void {
        const old = srgb ? r.colour : r.data;
        if (old == null) return;
        this.retiredTargets.push(old);
        if (srgb) r.colour = null;
        else r.data = null;
        r.bound = false;
    }

    // Sets `r`'s keys live on `binder`, each its form's target (a key
    // whose target is not made yet stays unbound: its slot keeps the
    // blank image).
    private bind(r: GpuViewport, binder: MaterialBinder<GPUTextureView, GPUBindGroup>): void {
        let n = 0;
        const keys = r.keys;
        for (let j = 0; j < keys.length; j++) {
            const t = r.targetOf(j);
            if (t == null) continue;
            binder.setLiveKey(unchecked(keys[j]), t.view);
            n++;
        }
        r.live = n;
        r.bound = true;
    }

    // `r`'s keys dropped from `binder` (its paths changed, or it left).
    private unbind(r: GpuViewport, binder: MaterialBinder<GPUTextureView, GPUBindGroup>?): void {
        if (binder != null) {
            for (let j = 0; j < r.keys.length; j++) binder.dropLive(r.keys[j]);
        }
        r.bound = false;
        r.live = 0;
    }

    // `r` forgotten: its keys dropped, its targets and light released at
    // the next beginFrame, and the schedule's state of it forgotten (see
    // the header).
    private forgetRecord(r: GpuViewport, binder: MaterialBinder<GPUTextureView, GPUBindGroup>?): void {
        this.schedule.forgetKey(r.key);
        this.unbind(r, binder);
        this.drop(r, true);
        this.drop(r, false);
        const e = r.environment;
        if (e != null) this.retiredEnvironments.push(e);
        r.environment = null;
        r.ibl = null;
        r.drawn = false;
    }

    // The blit, made on the first draw; null (said once) when the host
    // refused it. Its 8-bit warning (no half-float targets) is said with
    // it.
    private blitOn(gpu: Gpu, warnings: Array<string>): LiveTextureBlit? {
        const b = this.blit;
        if (b != null) return b;
        if (this.blitTried) return null;
        this.blitTried = true;
        const made = LiveTextureBlit.create(gpu);
        if (!made.ok) {
            this.blitRefused(warnings);
            return null;
        }
        const blit = made.value;
        for (let i = 0; i < blit.warnings.length; i++) warnings.push(blit.warnings[i]);
        this.blit = blit;
        return blit;
    }

    // VIEWPORT_BLIT_WARNING, once; false.
    private blitRefused(warnings: Array<string>): bool {
        if (!this.blitWarned) {
            this.blitWarned = true;
            warnings.push(VIEWPORT_BLIT_WARNING);
        }
        return false;
    }
}
