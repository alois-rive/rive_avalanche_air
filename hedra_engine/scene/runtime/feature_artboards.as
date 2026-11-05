// The artboards feature of the run time (milestone 39,
// features.as FEATURE_ARTBOARDS): each instance's artboard textures played
// live, by the player's ArtboardTextures (../player/artboards.as). The
// sources are the scene's (SceneRuntime.artboardSources, which the
// Scene3D component sets from artboardSourcesOf), the
// artboards the host's inputs hold (SceneInstance.provideArtboard), given
// over every advance; the textures advance in the artboards phase (before
// the bindings and the scripts, as in the player) and are drawn into their
// targets before each new picture. A texture playing live makes a new
// picture each frame its artboard changes (milestone 50: one at rest, such
// as a sign, is drawn once and costs nothing a frame).
//
// The textures are those of the tree as instanced: a scene a script adds
// at run time draws its artboard textures as their placeholders.
//
// Milestone 41: a scene loaded through hedra_engine/scene (the library's
// Scene3D) has no generated sources: unless the host set some, they are
// the tree's own, each Rive file's artboard once in the order the tree's
// materials first use it (artboardSourcesOf), and so the Scene3D's inputs
// artboard_0 to artboard_7 take the scene's artboard textures in that
// order.
//
// Milestone 47 (docs/plans/RIVE_MODEL.md section 3.5: an artboard shown in
// 3D is a nested artboard): a pointer event no script's _input handled (a
// pointer exit always) reaches the artboard drawn where it points. Of what
// the event hits (SceneInstance.listenerHits: picked once for the event,
// which the state machines' listeners read too; nearest first, up to the
// first opaque hit, so a wall in front of a screen hides it), the first hit
// on a surface showing an artboard texture with pointer_forward on gets the
// event at its point (../player/artboards.as ArtboardTextures.pointer: the
// texture's pixel, in the artboard's own coordinates), and the artboard's
// own state machine runs its listeners. Per pointer the texture last
// forwarded to is kept: when the pointer leaves it (another artboard, a
// surface that shows none, nothing, or the pointer leaves the picture) it
// gets a pointer exit at the last point it had first, so its hovers end.
// A press holds the pointer, as Rive's nested artboard hears every pointer
// event of its host, in its own coordinates, out of its bounds too: while
// the pointer that pressed on an artboard is down, its moves and its release
// off that artboard's surface still reach it, at the point of the plane of
// its last hit the ray meets, in the artboard's coordinates (out of its
// bounds: the hit's artboardGradX and artboardGradY carry it there), so
// that a drag that leaves a 2D slider goes on and its release ends it. Only
// a hit hiding that point (an opaque hit nearer than it: Rive's canHit
// false), or a ray that never meets the plane, ends the hold with an exit.
// A pointer past LISTENER_MAX_POINTERS takes the slot of the one heard
// least recently, whose artboard hears it leave. A forwarded event asks for a new picture (the artboard redraws).
//
// Milestone 67 (docs/engine/PERFORMANCE.md, "Pictures that change"): a
// texture drawn again after its first picture asks for a new picture of the
// frame as planned (SceneInstance.texturesChanged), never a new plan; only a
// texture's first picture, whose live targets replace its placeholder in the
// materials' groups, plans again, as before. Which textures are drawn again
// is their update mode's and rate's (../player/artboards.as
// ArtboardSchedule); when_visible reads what the renderer drew in the last
// frame (FrameRenderer.artboardsDrawn), taken before each advance when this
// instance drew that frame (else not known: every texture counts as seen).
// A texture held back that still plays (ArtboardTextures.waiting) keeps
// the scene advancing (SceneInstance.keepsRunning) without a new picture:
// the artboard always plays, only its redraw waits.
// The status gains "artboardRedraws" (the redraws after the first pictures,
// all textures together) when a texture's mode or rate is not the default. The part
// wants the pick only while the scene shows an artboard texture
// (listenerGroups). The artboard's Rive events stay inside it: they reach
// the scene through its view model (a property the scene binds or a
// viewModel listener hears). Allocates nothing an event once each texture's
// PointerEvent exists.

import { ViewModel } from "rive/data";
import { FrameRenderer } from "../../render/gpu/renderer";
import { SceneNode } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { artboardTexturesOf } from "../tree/artboards";
import { artboardSourceKey } from "../resource/artboard_texture";
import { resolveSchemaIn, sceneViewModelOf } from "../binding/binder";
import { MemoryViewModel } from "../binding/values";
import { dataSourceOf } from "../data/source";
import { ArtboardTextures, artboardViewModelSchema, viewModelMisfits } from "../player/artboards";
import { ArtboardTexture } from "../resource/types";
import { InputEvent, InputKind } from "../script";
import { ListenerHit, ListenerHits } from "../listen/pick";
import { LISTENER_MAX_POINTERS } from "../sm/decl";
import { FEATURE_ARTBOARDS, Feature, InstanceFeature, PHASE_ARTBOARDS } from "./features";
import { SceneInstance, SceneRuntime } from "./scene_runtime";
import { UPDATE_WHEN_VISIBLE } from "../../render/viewport";

// The numbers kept of a held pointer's plane (ArtboardsPart.planes).
const PLANE_STRIDE: i32 = 14;

// Milestone 67: the part whose instance's frame a renderer drew last (and
// that renderer), so that an instance reads FrameRenderer.artboardsDrawn
// only when it is its own frame's (several instances may share one).
let lastDrawer: ArtboardsPart? = null;
let lastRenderer: FrameRenderer? = null;

export class ArtboardsFeature extends Feature {
    bit(): u32 {
        return FEATURE_ARTBOARDS;
    }

    forInstance(inst: SceneInstance): InstanceFeature {
        return new ArtboardsPart();
    }
}

// One instance's artboard textures.
export class ArtboardsPart extends InstanceFeature {
    textures: ArtboardTextures = new ArtboardTextures();
    // How many of the textures' problems are in the instance's errors.
    private said: i32 = 0;
    // Milestone 47: per pointer slot (LISTENER_MAX_POINTERS), the pointer's
    // id (-1: free), the texture it was last forwarded to (null: none) and
    // where on it.
    private pointerIds: StaticArray<i32> = new StaticArray<i32>(LISTENER_MAX_POINTERS);
    private forwarded: Array<ArtboardTexture?> = [];
    private lastX: StaticArray<f32> = new StaticArray<f32>(LISTENER_MAX_POINTERS);
    private lastY: StaticArray<f32> = new StaticArray<f32>(LISTENER_MAX_POINTERS);
    // Per slot: whether it pressed on the artboard it was forwarded to (a
    // hold, see the header), and that artboard's last hit: its point, its
    // normal and its artboard gradients (scene space) and its point in the
    // artboard, PLANE_STRIDE numbers.
    private held: StaticArray<bool> = new StaticArray<bool>(LISTENER_MAX_POINTERS);
    private planes: StaticArray<f64> = new StaticArray<f64>(LISTENER_MAX_POINTERS * PLANE_STRIDE);
    // When each slot was last heard (a count of events).
    private heardAt: StaticArray<i64> = new StaticArray<i64>(LISTENER_MAX_POINTERS);
    private heard: i64 = 0;
    // Where a held pointer meets its plane, in the artboard (holdAt).
    private holdX: f32 = 0;
    private holdY: f32 = 0;
    // How many events were forwarded to an artboard (tests).
    forwardedEvents: i64 = 0;

    constructor() {
        super();
        for (let i = 0; i < LISTENER_MAX_POINTERS; i++) {
            this.pointerIds[i] = -1;
            this.forwarded.push(null);
        }
    }

    attach(inst: SceneInstance, root: SceneNode): void {
        if (root !== inst.tree.root) return;
        for (let i = 0; i < LISTENER_MAX_POINTERS; i++) {
            this.pointerIds[i] = -1;
            this.forwarded[i] = null;
            this.held[i] = false;
        }
        const t = this.textures;
        const rt = inst.runtime;
        const derive = rt.artboardSources.length == 0 && rt.deriveArtboards;
        t.sources = derive ? artboardSourcesOf(inst.tree) : rt.artboardSources;
        t.viewModelSources = derive ? artboardViewModelOf(inst.tree) : inst.runtime.artboardViewModel;
        t.collect(inst.tree);
        this.said = 0;
        this.takeProblems(inst);
    }

    advance(inst: SceneInstance, seconds: f64, phase: i32): bool {
        if (phase != PHASE_ARTBOARDS) return false;
        const t = this.textures;
        if (t.textures.length == 0) return false;
        const given = inst.artboards;
        for (let i = 0; i < given.length; i++) {
            const a = unchecked(given[i]);
            if (a != null) t.provide(i, a);
        }
        // (milestone 67: what the last frame showed, when it was ours)
        const r = inst.renderer;
        const ours = r != null && lastDrawer === this && lastRenderer === r;
        t.setSeen(ours ? r!.artboardsDrawn : 0, ours);
        t.advance(seconds);
        this.takeProblems(inst);
        // (milestone 50: only a texture that changed makes a new picture;
        // milestone 67: a new plan only for a first picture, else the frame
        // as planned)
        if (t.starting > 0) return true;
        if (t.changed > 0) inst.texturesChanged();
        // (a texture held back by its mode, rate or being out of view still
        // plays: the scene keeps advancing, with no new picture, so that its
        // state machine, its view-model writes and its next redraw come)
        if (t.waiting > 0 && inst.playing) inst.keepsRunning = true;
        return false;
    }

    beforeDraw(inst: SceneInstance, r: FrameRenderer): void {
        lastDrawer = this;
        lastRenderer = r;
        const t = this.textures;
        if (t.textures.length == 0) return;
        t.draw(inst.ctx, r);
        this.takeProblems(inst);
    }

    // (milestone 49: null is the host saying it binds none: the sources
    // that bind the scene's view model play unbound rather than wait)
    bind(inst: SceneInstance, vm: ViewModel?): void {
        this.textures.viewModel = vm;
        this.textures.noViewModel = vm == null;
    }

    // Milestone 47: a pointer event to the artboard under it (see the
    // header). Never handled: the listeners and the interaction feature's
    // signals hear the same event.
    input(inst: SceneInstance, e: InputEvent): bool {
        if (!e.isPointer()) return false;
        const exit = e.kind == InputKind.PointerExit;
        const t = this.textures;
        if (t.textures.length == 0) return false;
        if (e.handled && !exit) {
            // (a release a script handled ends the hold: the artboard
            // pressed hears the pointer leave, so it does not go on
            // dragging with the button up)
            if (e.kind == InputKind.PointerUp) this.endHold(inst, e.pointer);
            return false;
        }
        let sent = false;
        const slot = this.slotOf(e.pointer, !exit);
        if (slot < 0) return false;
        if (slot >= LISTENER_MAX_POINTERS) {
            // (a slot taken from the pointer heard least recently: its
            // artboard heard it leave)
            sent = true;
        }
        const s = slot % LISTENER_MAX_POINTERS;
        unchecked(this.heardAt[s] = ++this.heard);
        let target: ArtboardTexture? = null;
        let x: f32 = 0;
        let y: f32 = 0;
        const was = unchecked(this.forwarded[s]);
        if (!exit) {
            const hits = inst.listenerHits(e);
            for (let i = 0; i < hits.count; i++) {
                const h = unchecked(hits.hits[i]);
                const a = h.artboard;
                if (a == null) continue;
                target = a;
                x = h.artboardX;
                y = h.artboardY;
                if (a === was || e.kind == InputKind.PointerDown) this.keepPlane(s, h);
                break;
            }
            // (held: off its artboard, the pointer still reaches it on the
            // plane of its last hit, unless something opaque hides that)
            if (target !== was && was != null && unchecked(this.held[s]) && this.holdAt(s, hits)) {
                target = was;
                x = this.holdX;
                y = this.holdY;
            }
        }
        if (was != null && was !== target) {
            // (the artboard it leaves hears it leave where it last was)
            if (t.pointer(was, InputKind.PointerExit, unchecked(this.lastX[s]), unchecked(this.lastY[s]), e.pointer)) {
                sent = true;
            }
            this.forwarded[s] = null;
            unchecked(this.held[s] = false);
        }
        if (target != null) {
            if (t.pointer(target, e.kind, x, y, e.pointer)) sent = true;
            this.forwarded[s] = target;
            unchecked(this.lastX[s] = x);
            unchecked(this.lastY[s] = y);
            if (e.kind == InputKind.PointerDown) unchecked(this.held[s] = true);
            else if (e.kind == InputKind.PointerUp) unchecked(this.held[s] = false);
        }
        if (exit) {
            unchecked(this.pointerIds[s] = -1);
            unchecked(this.held[s] = false);
        }
        if (sent) {
            this.forwardedEvents++;
            inst.touch();
        }
        return false;
    }

    // Pointer `id`'s hold, if any, ended: its artboard hears it leave where
    // it last was.
    private endHold(inst: SceneInstance, id: i32): void {
        const s = this.slotOf(id, false);
        if (s < 0 || !unchecked(this.held[s])) return;
        unchecked(this.held[s] = false);
        const was = unchecked(this.forwarded[s]);
        if (was == null) return;
        this.forwarded[s] = null;
        if (this.textures.pointer(was, InputKind.PointerExit, unchecked(this.lastX[s]), unchecked(this.lastY[s]), id)) {
            this.forwardedEvents++;
            inst.touch();
        }
    }

    // An artboard texture is shown: the pick is wanted (no groups: the
    // artboards are hit on the drawn surfaces).
    listenerGroups(inst: SceneInstance, out: Array<SceneNode>): bool {
        return this.textures.textures.length > 0;
    }

    // The slot of pointer `id` (taken when `take` and it has none: a free
    // one, else the least recently heard pointer's, whose artboard hears
    // it leave at its last point: then the slot plus LISTENER_MAX_POINTERS
    // is answered); -1 when it has none and `take` is false.
    private slotOf(id: i32, take: bool): i32 {
        const ids = this.pointerIds;
        for (let i = 0; i < LISTENER_MAX_POINTERS; i++) if (unchecked(ids[i]) == id) return i;
        if (!take) return -1;
        let oldest = 0;
        for (let i = 0; i < LISTENER_MAX_POINTERS; i++) {
            if (unchecked(ids[i]) < 0) {
                unchecked(ids[i] = id);
                this.forwarded[i] = null;
                unchecked(this.held[i] = false);
                return i;
            }
            if (unchecked(this.heardAt[i]) < unchecked(this.heardAt[oldest])) oldest = i;
        }
        const was = unchecked(this.forwarded[oldest]);
        let left = false;
        if (was != null) {
            left = this.textures.pointer(was, InputKind.PointerExit, unchecked(this.lastX[oldest]), unchecked(this.lastY[oldest]),
                unchecked(ids[oldest]));
        }
        unchecked(ids[oldest] = id);
        this.forwarded[oldest] = null;
        unchecked(this.held[oldest] = false);
        return left ? oldest + LISTENER_MAX_POINTERS : oldest;
    }

    // Keeps hit `h` (on the artboard slot `s` is forwarded to, or pressed
    // on) as the plane a hold reaches it on.
    private keepPlane(s: i32, h: ListenerHit): void {
        const o = s * PLANE_STRIDE;
        const p = this.planes;
        unchecked(p[o] = <f64>h.point.x);
        unchecked(p[o + 1] = <f64>h.point.y);
        unchecked(p[o + 2] = <f64>h.point.z);
        unchecked(p[o + 3] = <f64>h.normal.x);
        unchecked(p[o + 4] = <f64>h.normal.y);
        unchecked(p[o + 5] = <f64>h.normal.z);
        unchecked(p[o + 6] = <f64>h.artboardGradX.x);
        unchecked(p[o + 7] = <f64>h.artboardGradX.y);
        unchecked(p[o + 8] = <f64>h.artboardGradX.z);
        unchecked(p[o + 9] = <f64>h.artboardGradY.x);
        unchecked(p[o + 10] = <f64>h.artboardGradY.y);
        unchecked(p[o + 11] = <f64>h.artboardGradY.z);
        unchecked(p[o + 12] = <f64>h.artboardX);
        unchecked(p[o + 13] = <f64>h.artboardY);
    }

    // Where the event's ray meets the plane of slot `s`'s last hit, in its
    // artboard (holdX, holdY: the hit's point in it moved along the plane by
    // the gradients); false when the ray misses the plane (along it, or behind
    // the camera) or an opaque hit nearer than that point hides it.
    private holdAt(s: i32, hits: ListenerHits): bool {
        if (!hits.valid) return false;
        const o = s * PLANE_STRIDE;
        const p = this.planes;
        const px = unchecked(p[o]), py = unchecked(p[o + 1]), pz = unchecked(p[o + 2]);
        const nx = unchecked(p[o + 3]), ny = unchecked(p[o + 4]), nz = unchecked(p[o + 5]);
        const ro = hits.rayOrigin;
        const rd = hits.rayDir;
        const denom = <f64>rd.x * nx + <f64>rd.y * ny + <f64>rd.z * nz;
        if (Math.abs(denom) < 1e-12) return false;
        const t = ((px - <f64>ro.x) * nx + (py - <f64>ro.y) * ny + (pz - <f64>ro.z) * nz) / denom;
        if (!(t >= 0) || !isFinite(t)) return false;
        for (let i = 0; i < hits.count; i++) {
            const h = unchecked(hits.hits[i]);
            // (an opaque item drawn on top hides the plane wherever it is)
            if (h.opaque && (h.t < t || h.top)) return false;
        }
        const dx = <f64>ro.x + <f64>rd.x * t - px, dy = <f64>ro.y + <f64>rd.y * t - py, dz = <f64>ro.z + <f64>rd.z * t - pz;
        this.holdX = <f32>(unchecked(p[o + 12]) + dx * unchecked(p[o + 6]) + dy * unchecked(p[o + 7])
            + dz * unchecked(p[o + 8]));
        this.holdY = <f32>(unchecked(p[o + 13]) + dx * unchecked(p[o + 9]) + dy * unchecked(p[o + 10])
            + dz * unchecked(p[o + 11]));
        return true;
    }

    // Milestone 49 (features.as): a texture played bound to the scene's
    // instance runs its artboard's state machine on it, which may write it.
    writesData(inst: SceneInstance): bool {
        const t = this.textures;
        if (t.textures.length == 0) return false;
        const flags = t.viewModelSources;
        for (let i = 0; i < flags.length; i++) if (flags[i]) return true;
        return false;
    }

    status(inst: SceneInstance): string {
        const t = this.textures;
        if (t.sources.length == 0) return "";
        const live = ",\"artboards\":" + t.live.toString();
        return governed(t.textures) ? live + ",\"artboardRedraws\":" + t.redraws.toString() : live;
    }

    stamp(inst: SceneInstance): i64 {
        const t = this.textures;
        if (t.sources.length == 0) return 0;
        // (milestone 67: the redraws, when the status says them)
        return governed(t.textures) ? (<i64>t.live + 1) * 1000003 + t.redraws : <i64>t.live + 1;
    }

    dispose(inst: SceneInstance): void {
        this.textures.viewModel = null;
        if (lastDrawer === this) {
            lastDrawer = null;
            lastRenderer = null;
        }
    }

    // The textures' problems not yet in the instance's errors.
    private takeProblems(inst: SceneInstance): void {
        const ps = this.textures.problems;
        if (this.said > ps.length) this.said = 0;
        for (let i = this.said; i < ps.length; i++) inst.fail(ps[i]);
        this.said = ps.length;
    }
}

// Milestone 41: the artboard sources of `tree` (see the header): one
// artboardSourceKey per Rive file and artboard its materials' textures
// draw, in the order first met.
export function artboardSourcesOf(tree: SceneTree): Array<string> {
    const out = new Array<string>();
    const textures = artboardTexturesOf(tree);
    for (let i = 0; i < textures.length; i++) {
        const rive = textures[i].rive;
        if (rive == null) continue;
        const key = artboardSourceKey(rive.file, textures[i].artboard);
        if (!out.includes(key)) out.push(key);
    }
    return out;
}

// Milestone 41: whether each of artboardSourcesOf(tree) binds the scene's
// view model (Scene3D's artboardViewModel): its artboard binds the view
// model of the scene's view model's name (RivArtboard.viewModel), and,
// when the scene's view model is a .riv's, the texture's Rive file is that
// one. Milestone 49 (docs/plans/RIVE_MODEL.md section 7): a scene whose
// view model is no .riv's (the Rive project's data, or a RiveData .rml)
// has no file to match, so the name alone decides: the artboard binds a
// view model of that name in its own file, which in a Rive project is the
// project's copy of it (docs/cli/BUILD.md section 8, "Artboard
// textures"), and, when the scene's view model resolves here (a scene drawn
// from its text: its data source read), it must fit it
// (../player/artboards.as viewModelMisfits: every property of the
// artboard's view model, nested ones included, of the same name and kind;
// more allowed). A built scene has no data source at run time: the live
// instance is checked when the source is instanced (ArtboardTextures).
// Such a source is instanced bound to the scene's instance, so its state
// machine and the scene's bindings read and write one instance.
export function artboardViewModelOf(tree: SceneTree): Array<bool> {
    const out = new Array<bool>();
    const vm = sceneViewModelOf(tree);
    const vmRive = vm != null ? vm.rive : null;
    // (milestone 49: the scene's view model as its data source has it, for
    // a view model of no .riv; null when it does not resolve here)
    let scene: MemoryViewModel? = null;
    if (vm != null && vmRive == null) {
        const src = dataSourceOf(tree);
        if (src.ok) {
            const r = resolveSchemaIn(tree, vm, src.value, "");
            if (r.ok) scene = new MemoryViewModel(r.value);
        }
    }
    const seen = new Array<string>();
    const textures = artboardTexturesOf(tree);
    for (let i = 0; i < textures.length; i++) {
        const rive = textures[i].rive;
        if (rive == null) continue;
        const key = artboardSourceKey(rive.file, textures[i].artboard);
        if (seen.includes(key)) continue;
        seen.push(key);
        let binds = false;
        const info = rive.info;
        const sameFile = vmRive == null || rive === vmRive || rive.path == vmRive.path;
        if (vm != null && vm.viewModel.length > 0 && info != null && sameFile) {
            for (let k = 0; k < info.artboards.length; k++) {
                const a = info.artboards[k];
                if (a.name != textures[i].artboard) continue;
                binds = a.viewModel >= 0 && a.viewModel < info.viewModels.length && info.viewModels[a.viewModel].name == vm.viewModel;
                if (binds && scene != null) {
                    const want = artboardViewModelSchema(info, a.name);
                    binds = want != null && viewModelMisfits(want, scene).length == 0;
                }
                break;
            }
        }
        out.push(binds);
    }
    return out;
}

// Milestone 67: whether any of `textures` has an update mode or a rate other
// than the default (when_visible, 0): the status then counts the redraws.
function governed(textures: Array<ArtboardTexture>): bool {
    for (let i = 0; i < textures.length; i++) {
        const t = unchecked(textures[i]);
        if (t.updateMode != UPDATE_WHEN_VISIBLE || t.updateFps != 0) return true;
    }
    return false;
}

// Adds the artboards feature to `rt` (the module's generated features.as
// calls it when the bundle's scenes use an ArtboardTexture).
export function installArtboardsFeature(rt: SceneRuntime): void {
    rt.install(new ArtboardsFeature());
}
