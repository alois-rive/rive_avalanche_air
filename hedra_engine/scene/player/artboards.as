// The artboard textures of a built project (milestone 15): each
// ArtboardTexture the scene's materials use, played live. A script cannot
// load a Rive file, so the artboards come from the project itself:
// the CLI's `build` copies each RiveFile's RML source into the project and
// hands its artboards to the generated main.as as artboard inputs
// (`@input("artboard_<i>")`, ScriptInputArtboard children of its
// ScriptedLayout), in the order of the generated ARTBOARD_SOURCES
// (src/artboards.as: artboardSourceKey strings), and main.as passes each
// to `provide`.
//
// For each texture (by its `path`), once its source is provided: one
// instance of the artboard (Artboard.instance(), which runs the
// artboard's default state machine; the build made the texture's
// state_machine the default of the copy, docs/guide/GUIDE.md "Building
// a project"), made and advanced by `advance` every frame; one Rive canvas of the
// texture's size (Context.canvas) the instance is drawn into by `draw`,
// scaled from the artboard's size to the texture's; and the live targets
// (gpu/live_texture.as) the canvas's image view is blitted into, a colour
// one and a data one as the texture's slots need, set on the renderer's
// material binder (MaterialBinder.setLive) before the first frame that
// draws them, so that the materials' groups bind them from the start.
// A texture is set live only once its first canvas frame was drawn and
// blitted: a host that cannot draw leaves the placeholder bound, never an
// empty target.
//
// What cannot be played is drawn as its placeholder (the texture's
// `image`, which the material binder draws through SceneTextureFiles) and
// said once in the player's errors: no source for the texture (a project
// built before the artboard was named), a host without a canvas
// recording host (Canvas.beginFrame answers null: the CLI's `render` and the
// other tools' host), the blit refused. An extension slot (clear coat,
// sheen, ...) always draws the placeholder: the renderer composes those
// slots' textures on the CPU (MaterialBinder.extArray).
//
// Which slots a texture fills is read from the tree's materials as the
// adapter turns them into MaterialDescs (../render/materials.as
// materialDesc): albedo always, emission, normal and ambient occlusion
// when their switches are on, metallic and roughness as the one
// metallic-roughness binding (roughness alone beside a different metallic
// texture is an extension layer). Base colour and emission sample a colour
// target (linear rgba16float), the other three a data target (rgba8unorm).
// Milestone 33: a Decal's textures too (../tree/artboards.as), its albedo
// and emission from the colour target, its normal and ORM from the data
// target: the renderer's decal atlas (../../render/gpu/decals.as) blits the
// view setLive gave it into its layer every frame, so nothing here differs
// for a decal.
//
// After the first frame `advance` and `draw` allocate nothing of their own
// (the std's Canvas.beginFrame wraps each frame's renderer in a new
// Renderer object, which the player cannot avoid).
//
// The status (player.as) gains "artboards": the number of textures
// playing live (`live`).
//
// Milestone 17: a source flagged in `viewModelSources` (its artboard binds
// the scene's view model) is instanced bound to `viewModel`, the instance
// of the scene's artboard, which the player sets once the host has bound
// it; until then its textures wait (a texture is never played bound to a
// view model instance of its own, which would show other values than the
// scene's).
//
// Milestone 49 (docs/plans/RIVE_MODEL.md section 7): such a source is
// bound only when its artboard's view model fits the scene's instance
// (viewModelMisfits: every property of the artboard's, nested ones
// included, is in the instance with the same name and kind; more are
// allowed), checked against the live instance when the source is first
// instanced; one that does not fit plays unbound, and `problems` says
// which properties are missing. A host that says it binds no view model
// (`noViewModel`, SceneInstance.bind(null): the Scene3D component whose
// view model has no `data`) has such sources played unbound rather than
// left waiting.
//
// Milestone 67 (docs/engine/PERFORMANCE.md, "Pictures that change"): Godot's
// SubViewport.render_target_update_mode and Hedra's update_fps decide when
// a texture that changed is drawn again (ArtboardSchedule). The artboard
// always advances (its state machine, its events, the view model it binds
// run as before); only drawing its canvas into the targets, and so the 3D's
// new picture, is governed:
//   disabled             never drawn again after its first picture
//   once                 drawn once more each time the mode becomes once
//                        (ArtboardTexture.onceWrites), then as disabled
//   when_visible         (the default, Godot's) drawn while a surface that
//                        shows it was drawn in the last frame: its bit
//                        (../render/artboard_bits.as) in the renderer's
//                        artboardsDrawn after that frame; a texture a decal
//                        paints, or past the first 32, counts as seen
//   when_parent_visible  as when_visible (a resource has no parent)
//   always               whenever it changed (as before)
// and with update_fps above 0, at most that many times a second of the
// scene's clock (the advances' seconds), the first change after a pause
// drawn at once. Every texture's first picture is drawn as soon as it can
// be, whatever its mode, so that no placeholder is shown in its place. A
// texture drawn again after its first asks only for a new picture
// (`changed`, which the run time turns into SceneInstance.texturesChanged);
// one drawn for the first time (`starting`) for a new plan, as before,
// since its live targets replace the placeholder in the materials' groups.

import { Context } from "rive/host";
import { Artboard } from "rive/artboard";
import { ViewModel } from "rive/data";
import { Canvas } from "rive/canvas";
import { GPUTextureView } from "rive/gpu";
import { Mat2D } from "rive/mat2d";
import { PointerEvent } from "rive/events";
import { Vector } from "rive/vector";
import { FrameRenderer } from "../../render/gpu/renderer";
import { LiveTarget, LiveTextureBlit } from "../../render/gpu/live_texture";
import { MATERIAL_TEXTURE_PROPS } from "../classdb";
import { SceneTree } from "../tree/tree";
import { ArtboardSlots, artboardSlotsOf, artboardTexturesOf } from "../tree/artboards";
import { ARTBOARD_TEXTURE_MARK, ArtboardTexture, RiveFile } from "../resource/types";
import { artboardSourceKey } from "../resource/artboard_texture";
import { bundlePathOf } from "../bundle/format";
import { InputKind } from "../script";
import { RivInfo, VmKind } from "../riv/riv_info";
import { ViewModelSchema, schemaOf } from "../binding/schema";
import { ViewModelValues } from "../binding/values";
import { RiveViewModelValues } from "./view_model";
import { CLI } from "../../base/names";
import { UPDATE_ALWAYS, UPDATE_DISABLED, UPDATE_ONCE } from "../../render/viewport";
import { Decal } from "../tree/node";
import { DECAL_TEXTURES } from "../../render/decal";
import { ARTBOARD_BITS } from "../render/artboard_bits";

// Where a texture is used (../tree/artboards.as, beside the warnings that
// read it too), for this file's readers.
export { ArtboardSlots, artboardSlotsOf };

// Milestone 67: when a texture already drawn is drawn again (see the
// header), one per texture: whether its last `once` was answered, and when
// its rate lets it draw next. Pure (no GPU, no artboard), so the tests
// drive it with a clock of their own; allocates nothing.
export class ArtboardSchedule {
    // The texture's onceWrites already answered, and whether a `once` is
    // waiting to be drawn.
    onceSeen: i32 = 0;
    onceArmed: bool = false;
    // When (the scene's clock, seconds) the rate lets it draw next:
    // -Infinity, at once.
    nextAt: f64 = -Infinity;
    // How many times it was drawn again after its first picture.
    redraws: i64 = 0;

    // Starts afresh for texture `t` (its first picture is about to be
    // drawn, or was): a `once` written before counts as answered.
    reset(t: ArtboardTexture): void {
        this.onceSeen = t.onceWrites;
        this.onceArmed = false;
        this.nextAt = -Infinity;
    }

    // `t`'s first picture was drawn at `clock` (a `once` written before is
    // answered by it, and the rate counts from it).
    started(t: ArtboardTexture, clock: f64): void {
        this.reset(t);
        const fps = t.updateFps;
        if (fps > 0 && isFinite(fps)) this.nextAt = clock + 1 / <f64>fps;
    }

    // Whether `t`, drawn before and `dirty` (its artboard changed since its
    // last picture), is drawn again now: `seen` whether a surface showing
    // it was drawn in the last frame, `clock` the scene's time and `step`
    // the last advance's seconds (a redraw due within half a step is drawn:
    // the frame nearest the rate's tick). A `once` armed while the artboard
    // is at rest is answered without a picture (it would be the same).
    wants(t: ArtboardTexture, dirty: bool, seen: bool, clock: f64, step: f64): bool {
        if (t.onceWrites != this.onceSeen) {
            this.onceSeen = t.onceWrites;
            if (t.updateMode == UPDATE_ONCE) this.onceArmed = true;
        }
        const mode = t.updateMode;
        let wants = false;
        if (mode == UPDATE_DISABLED) {
            return false;
        } else if (mode == UPDATE_ONCE) {
            if (!this.onceArmed) return false;
            if (!dirty) {
                this.onceArmed = false;
                return false;
            }
            wants = true;
        } else if (mode == UPDATE_ALWAYS) {
            wants = dirty;
        } else {
            // (when_visible, when_parent_visible and any other number)
            wants = dirty && seen;
        }
        if (!wants) return false;
        const fps = t.updateFps;
        if (fps > 0 && isFinite(fps)) {
            const half = step > 0 && isFinite(step) ? step * 0.5 : 0;
            if (clock + half < this.nextAt) return false;
        }
        return true;
    }

    // Whether `t`, dirty and not drawn now, may still be drawn again
    // without a new write of its mode: not disabled, and not a `once`
    // already answered (its rate or its being out of view only wait). The
    // run time keeps the scene advancing while one waits (waiting).
    mayDrawLater(t: ArtboardTexture): bool {
        const mode = t.updateMode;
        if (mode == UPDATE_DISABLED) return false;
        if (mode == UPDATE_ONCE) return this.onceArmed;
        return true;
    }

    // `t` was drawn again at `clock`: a `once` is answered, and the next
    // redraw the rate allows is a period on (from the last tick, so that
    // the rate holds on average; from now when it last drew more than a
    // period ago).
    drew(t: ArtboardTexture, clock: f64): void {
        this.redraws++;
        if (t.updateMode == UPDATE_ONCE) this.onceArmed = false;
        const fps = t.updateFps;
        if (fps > 0 && isFinite(fps)) {
            const period = 1 / <f64>fps;
            this.nextAt = clock - this.nextAt > period ? clock + period : this.nextAt + period;
        } else {
            this.nextAt = -Infinity;
        }
    }
}

// What `draw` says, once, when the host has no canvas recording host.
export const ARTBOARD_NO_CANVAS_HOST = "artboard textures are drawn as placeholders: the host cannot draw into a canvas";

// One texture played live: its source, and what `draw` made for it.
class LiveArtboard {
    texture: ArtboardTexture;
    // Its index in `sources`, -1 when the project has none for it.
    source: i32;
    slots: ArtboardSlots;
    width: u32;
    height: u32;
    instance: Artboard? = null;
    canvas: Canvas? = null;
    view: GPUTextureView? = null;
    colour: LiveTarget? = null;
    data: LiveTarget? = null;
    // The artboard's size to the texture's.
    scaleX: f32 = 1;
    scaleY: f32 = 1;
    // Set live on the renderer (its first frame was drawn and blitted).
    live: bool = false;
    // Gave up (said in `problems`): it keeps its placeholder.
    failed: bool = false;
    // Milestone 47: the event the pointer reaches the instance with (made
    // the first time, refilled).
    event: PointerEvent? = null;
    // Milestone 50: whether the canvas must be drawn again (the instance
    // changed since its last frame: a new instance, an advance that wants
    // more, the advance after the last such, a forwarded pointer event),
    // and whether its last advance wanted more. An artboard at rest is
    // drawn once and its targets kept.
    dirty: bool = true;
    moving: bool = true;
    // Milestone 67: when it is drawn again (see the header), whether the
    // last advance decided it is (drawn by the next `draw`), its index's
    // bit in the renderer's artboardsDrawn (0: past the first 32), and
    // whether a decal paints it (the renderer cannot say whether it is seen).
    schedule: ArtboardSchedule = new ArtboardSchedule();
    due: bool = false;
    bit: u32 = 0;
    decal: bool = false;
    // The tests' stand-in for an instance (ArtboardTextures.simulate): it
    // plays without one, wanting more while `simMoving`, and `draw` draws it
    // without a GPU.
    simulated: bool = false;
    simMoving: bool = false;

    // Whether it plays (an instance, or the tests' stand-in).
    plays(): bool {
        return this.instance != null || this.simulated;
    }

    constructor(texture: ArtboardTexture, source: i32, slots: ArtboardSlots) {
        this.texture = texture;
        this.source = source;
        this.slots = slots;
        this.width = <u32>max<i32>(texture.width, 1);
        this.height = <u32>max<i32>(texture.height, 1);
    }

    // Lets go of the GPU and canvas resources (a new scene or renderer).
    release(): void {
        const c = this.colour;
        if (c != null) c.release();
        const d = this.data;
        if (d != null) d.release();
        const v = this.view;
        if (v != null) v.release();
        const cv = this.canvas;
        if (cv != null) cv.release();
        this.colour = null;
        this.data = null;
        this.view = null;
        this.canvas = null;
        this.live = false;
        this.dirty = true;
        this.due = false;
    }
}

export class ArtboardTextures {
    // The generated ARTBOARD_SOURCES (artboardSourceKey strings), set
    // before ScenePlayer.start; empty for a project without artboards.
    sources: Array<string> = [];
    // Milestone 17: by source index, whether the source's artboard binds
    // the scene's view model (the generated ARTBOARD_VIEW_MODEL, set
    // before ScenePlayer.start by a project whose scene names a view model;
    // empty otherwise). Such a source's instances are made bound to
    // `viewModel`, the instance of the scene's artboard, so that the
    // artboard and the 3D scene share one view model instance.
    viewModelSources: Array<bool> = [];
    // The scene artboard's view model instance (the player sets it once
    // the host has bound it); null until then, and without one.
    viewModel: ViewModel? = null;
    // Milestone 49: the host binds no view model (see the header): a source
    // that binds the scene's plays unbound instead of waiting.
    noViewModel: bool = false;
    // Every ArtboardTexture the tree's materials use, in the order first
    // met walking the tree (collect).
    textures: Array<ArtboardTexture> = [];
    // How many textures play live: instanced and advancing, and not given
    // up (none once the host showed it cannot draw them). Counted by every
    // `advance` and `draw`: a host may advance without drawing (`rive
    // --data-dump`), and the instances still play there.
    live: i32 = 0;
    // Milestone 50: how many of them changed in the last `advance` (and so
    // must be drawn again): a texture at rest costs nothing a frame and
    // asks for no new picture. Milestone 67: those drawn again that its
    // update mode and rate let draw now (see the header), and, apart, those
    // whose first picture is yet to be drawn (`starting`), which ask for a
    // new plan rather than a new picture.
    changed: i32 = 0;
    starting: i32 = 0;
    // How many live textures are held back after the last `advance`: not
    // drawn now by their mode, rate or being out of view, while their
    // artboard still plays (it wants more) or has a change their schedule
    // will draw later. They make no picture, but the scene must keep
    // advancing (SceneInstance.keepsRunning): the artboard always plays,
    // only its redraw waits.
    waiting: i32 = 0;
    // Milestone 67: the scene's clock (the seconds `advance` was given), and
    // the artboard textures a surface drawn in the last frame showed (the
    // renderer's artboardsDrawn, a bit per texture by index; `seenKnown`
    // false: not known, every texture counts as seen), which the run time
    // sets before each advance (setSeen).
    clock: f64 = 0;
    private step: f64 = 0;
    private seenBits: u32 = 0;
    private seenKnown: bool = false;
    // How many times a texture was drawn again after its first picture, all
    // textures together (the status's "artboardRedraws").
    redraws: i64 = 0;
    // What went wrong, one line each, once (the player adds them to its
    // errors).
    problems: Array<string> = [];
    // The artboards main.as provided, by source index (null until given).
    private provided: Array<Artboard?> = [];
    private entries: Array<LiveArtboard> = [];
    // The renderer the canvases and targets were made for, and its blit.
    private renderer: FrameRenderer? = null;
    private blit: LiveTextureBlit? = null;
    // Set once the blit or the canvas host failed: nothing more is tried.
    private stopped: bool = false;
    private saidOutOfRange: bool = false;

    // Finds the textures of `tree` (every material of every mesh the
    // tree draws, models' and MultiMeshes' included) and forgets the
    // instances of any earlier tree.
    collect(tree: SceneTree): void {
        this.releaseGpu();
        for (let i = 0; i < this.entries.length; i++) this.entries[i].instance = null;
        this.entries = [];
        this.problems = [];
        this.live = 0;
        this.stopped = false;
        this.seenKnown = false;
        // (the bits of an earlier tree's textures given back: a texture no
        // player holds carries none)
        for (let i = 0; i < this.textures.length; i++) this.textures[i].seenBit = 0;
        this.textures = artboardTexturesOf(tree);
        const painted = decalArtboards(tree);
        for (let i = 0; i < this.textures.length; i++) {
            const t = this.textures[i];
            const slots = artboardSlotsOf(tree, t);
            const rive = t.rive;
            const key = rive != null ? artboardSourceKey(rive.file, t.artboard) : "";
            const source = rive != null ? this.sourceIndexOf(rive, t.artboard) : -1;
            const e = new LiveArtboard(t, source, slots);
            e.bit = i < ARTBOARD_BITS ? (<u32>1) << <u32>i : 0;
            // (the frame's items carry this very bit: artboard_bits.as)
            t.seenBit = e.bit;
            e.decal = painted.includes(t);
            e.schedule.reset(t);
            this.entries.push(e);
            if (slots.extension >= 0) {
                // A .mtlx texture's label already names its slot.
                const slot = MATERIAL_TEXTURE_PROPS[slots.extension];
                const where = label(t).endsWith("(" + slot + ")") ? "" : " in " + slot;
                this.problems.push("artboard texture " + label(t) + where
                    + " is drawn as its placeholder: that slot is composed on the CPU, so it cannot be live");
            }
            if (!slots.live()) {
                e.failed = true;
                continue;
            }
            if (source < 0) {
                e.failed = true;
                this.problems.push("artboard texture " + label(t) + " is drawn as its placeholder: the project has no "
                    + "artboard input for " + (key.length > 0 ? key : "it (no Rive file)")
                    + " (build the project again with " + CLI + " build)");
            }
        }
    }

    // The source of artboard `artboard` of `rive`, or -1. A source is keyed
    // by the RiveFile's res:// path, unless a build of several projects
    // found two different files sharing it: those are keyed by their
    // bundle paths (editor/program/src/build/artboards.as RiveIds), which
    // is tried first.
    private sourceIndexOf(rive: RiveFile, artboard: string): i32 {
        const under = bundlePathOf(rive.path);
        if (under != null) {
            const own = this.sources.indexOf(artboardSourceKey(under, artboard));
            if (own >= 0) return own;
        }
        return this.sources.indexOf(artboardSourceKey(rive.file, artboard));
    }

    // The artboard of ARTBOARD_SOURCES[index], as main.as's input holds it
    // (null until the host sets it). Called every advance until each is
    // given; a later call with the same artboard does nothing.
    provide(index: i32, artboard: Artboard?): void {
        if (index < 0 || index >= this.sources.length) {
            if (!this.saidOutOfRange) {
                this.saidOutOfRange = true;
                this.problems.push("artboard input " + index.toString() + " has no source: the project names "
                    + this.sources.length.toString() + " (ARTBOARD_SOURCES)");
            }
            return;
        }
        if (artboard == null) return;
        // (Grown with nulls on the first call: `sources` is a field main.as
        // sets, so its length is only known here.)
        while (this.provided.length < this.sources.length) this.provided.push(null);
        if (this.provided[index] == null) this.provided[index] = artboard;
    }

    // Advances every instance's state machine by `seconds`, making the
    // instance of each texture whose source was provided since. (Made here,
    // not by the first `draw`: a host may advance many frames before it
    // draws one, `rive --screenshot --advance=45` does, and the artboard's
    // time must be the scene's.)
    advance(seconds: f64): void {
        const dt = seconds > 0 && isFinite(seconds) ? seconds : 0;
        this.clock += dt;
        this.step = dt;
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i];
            if (e.failed) continue;
            let more = false;
            if (e.simulated) {
                more = e.simMoving;
            } else {
                let inst = e.instance;
                if (inst == null) {
                    inst = this.instanceOf(e);
                    if (inst == null) continue;
                }
                more = inst.advance(seconds);
            }
            // (the advance after the last that wanted more applies its
            // last change too)
            if (more || e.moving) e.dirty = true;
            e.moving = more;
        }
        this.decide();
    }

    // Milestone 67: the textures a surface drawn in the last frame showed
    // (FrameRenderer.artboardsDrawn after it), for the next advance's
    // when_visible; `known` false when the frame drawn last is not known to
    // be this tree's (every texture then counts as seen).
    setSeen(bits: u32, known: bool): void {
        this.seenBits = bits;
        this.seenKnown = known;
    }

    // Whether entry `e` was seen in the last frame (see setSeen; a texture
    // a decal paints or past the first 32 always is).
    private seen(e: LiveArtboard): bool {
        if (!this.seenKnown || e.bit == 0 || e.decal) return true;
        return (this.seenBits & e.bit) != 0;
    }

    // Milestone 67: which textures the next `draw` draws (`due`), and the
    // counts `changed`, `starting` and `live`.
    private decide(): void {
        for (let i = 0; i < this.entries.length; i++) {
            const e = unchecked(this.entries[i]);
            if (e.failed || !e.plays() || this.stopped) {
                e.due = false;
                continue;
            }
            if (!e.live) {
                e.due = true;
                continue;
            }
            // (one already due stays so until it is drawn)
            if (!e.due) e.due = e.schedule.wants(e.texture, e.dirty, this.seen(e), this.clock, this.step);
        }
        this.live = this.playing();
        this.changed = this.changing();
        this.starting = this.toStart();
        this.waiting = this.holding();
    }

    // Milestone 47 (RIVE_MODEL.md section 3.5: an artboard shown in 3D is a
    // nested artboard): the pointer event `kind` of pointer `pointerId` at
    // (x, y) on `texture`, in the texture's pixels (the canvas the artboard
    // is drawn into: ../listen/pick.as ListenerHit.artboardX/Y), passed to
    // its instance's state machine at the same point in the artboard's own
    // coordinates (divided by the scale the canvas draws it at: a 512 x 256
    // artboard on a 1024 x 512 texture gets half of each), through
    // Artboard.pointerDown, pointerMove, pointerUp or pointerExit and one
    // PointerEvent kept per texture (Vector is a value: refilling it
    // allocates nothing); whether the artboard's state machine reported a
    // hit. False when the texture plays no instance (yet, or at all: its
    // placeholder is drawn) or is not one of the tree's.
    pointer(texture: ArtboardTexture, kind: InputKind, x: f32, y: f32, pointerId: i32): bool {
        let e: LiveArtboard? = null;
        for (let i = 0; i < this.entries.length; i++) {
            const c = unchecked(this.entries[i]);
            if (c.texture === texture) {
                e = c;
                break;
            }
        }
        if (e == null || e.failed) return false;
        const inst = e.instance;
        if (inst == null) return false;
        let ev = e.event;
        if (ev == null) {
            ev = new PointerEvent(0, Vector(0, 0));
            e.event = ev;
        }
        ev.id = pointerId;
        ev.position = Vector(artboardCoordinate(x, e.scaleX), artboardCoordinate(y, e.scaleY));
        let hit: f64 = 0;
        if (kind == InputKind.PointerDown) hit = inst.pointerDown(ev);
        else if (kind == InputKind.PointerMove) hit = inst.pointerMove(ev);
        else if (kind == InputKind.PointerUp) hit = inst.pointerUp(ev);
        else if (kind == InputKind.PointerExit) hit = inst.pointerExit(ev);
        else return false;
        // (its state machine heard it: drawn again; the next advance plays
        // what the listener did)
        e.dirty = true;
        e.moving = true;
        return hit != 0;
    }

    // Whether `texture` plays an instance now (pointer reaches it).
    plays(texture: ArtboardTexture): bool {
        for (let i = 0; i < this.entries.length; i++) {
            const c = unchecked(this.entries[i]);
            if (c.texture === texture) return !c.failed && c.instance != null;
        }
        return false;
    }

    // The textures playing (see `live`).
    private playing(): i32 {
        if (this.stopped) return 0;
        let n = 0;
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i];
            if (!e.failed && e.plays()) n++;
        }
        return n;
    }

    // Milestone 67, for the tests (no Rive file can be instanced in them):
    // texture `index` plays without an instance, its artboard changing at
    // every advance while `moving`, and `draw` without a context or a
    // renderer "draws" it (its first picture, then each one its schedule
    // lets through), with the same counts and decisions as a real one.
    simulate(index: i32, moving: bool): void {
        if (index < 0 || index >= this.entries.length) return;
        const e = this.entries[index];
        e.failed = false;
        e.simulated = true;
        e.simMoving = moving;
        if (moving) e.dirty = true;
    }

    // The textures playing whose canvas the next `draw` draws again (see
    // `changed`): drawn before, changed since, and let by their mode and
    // rate.
    private changing(): i32 {
        if (this.stopped) return 0;
        let n = 0;
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i];
            if (!e.failed && e.plays() && e.live && e.due) n++;
        }
        return n;
    }

    // The live textures playing that are held back (see `waiting`).
    private holding(): i32 {
        if (this.stopped) return 0;
        let n = 0;
        for (let i = 0; i < this.entries.length; i++) {
            const e = unchecked(this.entries[i]);
            if (e.failed || !e.plays() || !e.live || e.due) continue;
            if (e.moving || (e.dirty && e.schedule.mayDrawLater(e.texture))) n++;
        }
        return n;
    }

    // The textures playing whose first picture is yet to be drawn (see
    // `starting`).
    private toStart(): i32 {
        if (this.stopped) return 0;
        let n = 0;
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i];
            if (!e.failed && e.plays() && !e.live) n++;
        }
        return n;
    }

    // Milestone 67: the scheduling state of texture `index` of `textures`
    // (tests and the status), null past them.
    scheduleOf(index: i32): ArtboardSchedule? {
        return index >= 0 && index < this.entries.length ? this.entries[index].schedule : null;
    }

    // `e`'s instance, made once its source is provided; null before.
    private instanceOf(e: LiveArtboard): Artboard? {
        const src = e.source >= 0 && e.source < this.provided.length ? this.provided[e.source] : null;
        if (src == null) return null;
        // Milestone 17: a source that binds the scene's view model is made
        // bound to the scene artboard's instance, once the player has it
        // (deferred until then; the player sets it before this advance once
        // the host has bound it). Its state machine and the scene's
        // bindings then read and write one instance.
        const binds = e.source < this.viewModelSources.length && this.viewModelSources[e.source];
        let inst: Artboard;
        if (binds) {
            const vm = this.viewModel;
            if (vm == null) {
                if (!this.noViewModel) return null;
                inst = src.instance();
            } else {
                // (milestone 49: bound only when it fits, see the header;
                // checked once, as the source is instanced)
                const misfits = textureMisfits(e.texture, new RiveViewModelValues(vm));
                if (misfits.length == 0) {
                    inst = src.instance(vm);
                } else {
                    this.problems.push("artboard texture " + label(e.texture) + " plays unbound: the scene's view model "
                        + "instance lacks (or holds as another kind) " + misfits.join(", ")
                        + " of the view model its artboard binds");
                    inst = src.instance();
                }
            }
        } else {
            inst = src.instance();
        }
        // The runtime turns frame origin off for a scripted instance, which
        // draws content relative to the artboard's origin: an artboard whose
        // originX/originY is not 0 would come out cropped and shifted. On,
        // content spans 0..width by 0..height, which the scale below expects.
        inst.frameOrigin = true;
        // Applies the state machine's first state before anything reads it.
        inst.advance(0);
        e.instance = inst;
        const aw = inst.width;
        const ah = inst.height;
        e.scaleX = aw > 0 ? <f32>(<f64>e.width / aw) : 1;
        e.scaleY = ah > 0 ? <f32>(<f64>e.height / ah) : 1;
        return inst;
    }

    // Draws every instance into its canvas and blits the canvases into
    // their targets, on `r`'s GPU, before `r` draws the frame; the first
    // call makes the canvases and targets and sets the targets on
    // r.materials (setLive). `ctx` null (tests) draws nothing.
    draw(ctx: Context?, r: FrameRenderer?): void {
        if (this.stopped || this.entries.length == 0) return;
        if (ctx == null || r == null) {
            this.drawSimulated();
            return;
        }
        if (this.renderer !== r) {
            // A new renderer (the player started again): its binder and
            // GPU canvas are new, so is everything drawn for the old one.
            this.releaseGpu();
            this.renderer = r;
        }
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i];
            if (e.failed || e.simulated) continue;
            if (!e.live) {
                if (!this.start(e, ctx, r) && this.stopped) break;
                continue;
            }
            // (milestone 67: only what the last advance decided; a texture
            // that changed and is not due keeps its picture, and its change)
            if (!e.due) continue;
            e.due = false;
            if (!e.dirty) continue;
            if (!this.frame(e)) break;
            this.blitInto(e);
            e.dirty = false;
            e.schedule.drew(e.texture, this.clock);
            this.redraws++;
        }
        this.live = this.playing();
        this.changed = this.changing();
        this.starting = this.toStart();
        this.waiting = this.holding();
    }

    // `draw` of the tests' simulated textures (see `simulate`): a first
    // picture, else what was decided, as `draw` would draw them.
    private drawSimulated(): void {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i];
            if (e.failed || !e.simulated) continue;
            if (!e.live) {
                e.live = true;
                e.dirty = false;
                e.due = false;
                e.schedule.started(e.texture, this.clock);
                continue;
            }
            if (!e.due) continue;
            e.due = false;
            if (!e.dirty) continue;
            e.dirty = false;
            e.schedule.drew(e.texture, this.clock);
            this.redraws++;
        }
        this.live = this.playing();
        this.changed = this.changing();
        this.starting = this.toStart();
        this.waiting = this.holding();
    }

    // The first frame of `e`: its instance, canvas, view and targets, drawn
    // and blitted, then set live. False when it is not drawn (yet: its
    // source is not provided; or for good: `failed`, or `stopped`).
    private start(e: LiveArtboard, ctx: Context, r: FrameRenderer): bool {
        // (Normally made by `advance`; a draw before any advance makes it.)
        if (e.instance == null && this.instanceOf(e) == null) return false;
        if (this.blit == null && !this.makeBlit(r)) return false;
        const t = e.texture;
        const size = e.width.toString() + " x " + e.height.toString();
        if (e.canvas == null) {
            const c = ctx.canvas(e.width, e.height);
            if (c == null) return this.giveUp(e, "the host gave no " + size + " canvas");
            e.canvas = c;
        }
        if (!this.frame(e)) return false;
        if (e.view == null) {
            const v = e.canvas!.image.view();
            if (v == null) return this.giveUp(e, "the host gave no view of its " + size + " canvas");
            e.view = v;
        }
        const blit = this.blit!;
        if (e.slots.colour && e.colour == null) {
            const target = blit.target(e.width, e.height, true);
            if (target == null) return this.giveUp(e, "the host refused its " + size + " colour target");
            e.colour = target;
        }
        if (e.slots.data && e.data == null) {
            const target = blit.target(e.width, e.height, false);
            if (target == null) return this.giveUp(e, "the host refused its " + size + " data target");
            e.data = target;
        }
        this.blitInto(e);
        e.dirty = false;
        e.due = false;
        // (milestone 67: its first picture; a once written before is
        // answered by it, and the rate counts from here)
        e.schedule.started(t, this.clock);
        const colour = e.colour;
        if (colour != null) r.materials.setLive(t.path, true, colour.view);
        const data = e.data;
        if (data != null) r.materials.setLive(t.path, false, data.view);
        e.live = true;
        return true;
    }

    // Draws `e`'s instance into its canvas, scaled to the texture's size,
    // over a transparent clear. False (and nothing more is drawn, said
    // once) when the host has no canvas recording host.
    private frame(e: LiveArtboard): bool {
        const c = e.canvas;
        const inst = e.instance;
        if (c == null || inst == null) return false;
        const fr = c.beginFrame(0);
        if (fr == null) {
            this.stopped = true;
            this.problems.push(ARTBOARD_NO_CANVAS_HOST);
            return false;
        }
        fr.transform(Mat2D.withScaleAndTranslation(e.scaleX, e.scaleY, 0, 0));
        inst.draw(fr);
        c.endFrame();
        return true;
    }

    private blitInto(e: LiveArtboard): void {
        const blit = this.blit;
        const v = e.view;
        if (blit == null || v == null) return;
        const colour = e.colour;
        if (colour != null) blit.blit(v, colour);
        const data = e.data;
        if (data != null) blit.blit(v, data);
    }

    // The blit's pipelines on `r`'s GPU; false (said once, nothing more is
    // tried) when they cannot be made.
    private makeBlit(r: FrameRenderer): bool {
        const b = LiveTextureBlit.create(r.gpu);
        if (!b.ok) {
            this.stopped = true;
            this.problems.push(b.err);
            return false;
        }
        const blit = b.value;
        for (let i = 0; i < blit.warnings.length; i++) this.problems.push(blit.warnings[i]);
        this.blit = blit;
        return true;
    }

    // `e` keeps its placeholder from now on; says why, once.
    private giveUp(e: LiveArtboard, why: string): bool {
        e.failed = true;
        e.release();
        this.problems.push("artboard texture " + label(e.texture) + " is drawn as its placeholder: " + why);
        return false;
    }

    // Releases every canvas, target and the blit (their renderer is gone or
    // a new tree is played); the instances stay with their entries.
    private releaseGpu(): void {
        for (let i = 0; i < this.entries.length; i++) this.entries[i].release();
        const b = this.blit;
        if (b != null) b.release();
        this.blit = null;
        const r = this.renderer;
        if (r != null) r.materials.clearLive();
        this.renderer = null;
    }
}

// Milestone 67: the ArtboardTextures `tree`'s Decals paint (the renderer
// draws them into its decal atlas, not through an item: whether one is
// seen cannot be told, so it counts as seen).
function decalArtboards(tree: SceneTree): Array<ArtboardTexture> {
    const out = new Array<ArtboardTexture>();
    const decals = tree.decals();
    for (let i = 0; i < decals.length; i++) {
        const d: Decal = decals[i];
        for (let slot = 0; slot < DECAL_TEXTURES; slot++) {
            const t = d.textureAt(slot);
            const isArtboard = t != null && t instanceof ArtboardTexture;
            if (isArtboard && !out.includes(t as ArtboardTexture)) out.push(t as ArtboardTexture);
        }
    }
    return out;
}

// Milestone 47: a point on a texture (its pixels) in the artboard drawn
// into it at `scale` texture pixels a point (LiveArtboard.scaleX/Y: the
// texture's size to the artboard's).
export function artboardCoordinate(texturePixels: f32, scale: f32): f32 {
    return scale > 0 && isFinite(scale) ? texturePixels / scale : texturePixels;
}

// Milestone 49: the view model the artboard `artboard` of `info` binds,
// flattened (../binding/schema.as), or null when it binds none (or the
// file has no such artboard).
export function artboardViewModelSchema(info: RivInfo, artboard: string): ViewModelSchema? {
    for (let k = 0; k < info.artboards.length; k++) {
        const a = info.artboards[k];
        if (a.name != artboard) continue;
        if (a.viewModel < 0 || a.viewModel >= info.viewModels.length) return null;
        const s = schemaOf(info, info.viewModels[a.viewModel].name, "");
        return s.ok ? s.value : null;
    }
    return null;
}

// Milestone 49: the paths of `want` that `have` lacks or holds as another
// kind (nested view models' included; a kind this reader does not tell
// apart, VmKind.Other, is not compared): [] when `want` fits `have`, the
// rule the CLI's `format --upgrade` matches a view model by (same names and
// kinds, recursively; more allowed).
export function viewModelMisfits(want: ViewModelSchema, have: ViewModelValues): Array<string> {
    const out = new Array<string>();
    for (let i = 0; i < want.fields.length; i++) {
        const f = want.fields[i];
        if (f.kind == VmKind.Other) continue;
        if (have.kindOf(f.path) != f.kind) out.push(f.path);
    }
    return out;
}

// The misfits of texture `t`'s artboard's view model in `have` (none when
// its file is not read or its artboard binds none: nothing to compare).
function textureMisfits(t: ArtboardTexture, have: ViewModelValues): Array<string> {
    const rive = t.rive;
    const info = rive != null ? rive.info : null;
    if (info == null) return [];
    const want = artboardViewModelSchema(info, t.artboard);
    return want != null ? viewModelMisfits(want, have) : [];
}

// How the problems name a texture: its artboard and where it is declared
// (the sub_resource id, or the material file's slot property).
function label(t: ArtboardTexture): string {
    const at = t.path.indexOf(ARTBOARD_TEXTURE_MARK);
    const key = at >= 0 ? t.path.substring(at + ARTBOARD_TEXTURE_MARK.length) : t.path;
    return "'" + t.artboard + "' (" + key + ")";
}
