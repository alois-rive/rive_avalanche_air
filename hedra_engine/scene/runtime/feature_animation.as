// The animation feature of the run time (milestone 45, features.as
// FEATURE_ANIMATION; docs/plans/RIVE_MODEL.md sections 3.2, 3.3, 3.6 and
// 5): Rive's timelines and state machines in a running scene.
//
// Each instance's part plays what was asked of it, in the order asked:
//
//   - SceneInstance.playAnimation(name) (the Scene3D component's
//     `animation`): the root scene's animation `name`, from its start,
//     replacing the one played this way before ("" stops it; a name the
//     scene does not have is the instance's error, once);
//   - a script's `this.scene!.animation(name)` (../script/scene_api.as
//     ScriptAnimation): advance() and setTime*() apply at once; play() has
//     the part advance it every frame until stop() or a oneShot's end.
//
// In PHASE_ANIMATION every played instance advances by the frame's
// seconds (../anim/instance.as LinearAnimationInstance.advance) and is
// applied with its mix onto its scene's nodes (../anim/scene_anims.as
// SceneAnimations.apply), in play order, so that a later one layers over
// an earlier one as a Rive blend state's do; a mix of 0 is not applied
// (Rive's BlendStateInstance skips it). A oneShot that has reached its end
// is applied there once more and stops playing. The KeyFrameCallbacks
// crossed fire: `event:<Name>` fires the scene's Event
// (SceneInstance.fireEvent: queued for takeEvents, and the scene's root
// emits `event_fired` with the name), `signal:<name>` makes the node emit
// that signal. The advance answers true while a played animation wrote a
// changed value.
//
// Milestone 46: the scene's state machines (../sm/runner.as
// MachineRunner). On attach the root scene runs its
// default_state_machine ("" the first it declares, "-" none) and each
// instanced scene its instancing node's instance_state_machine (or its
// instance_animation instead); a subtree a script adds runs its own, and
// one removed stops them. PHASE_ANIMATION advances the machines first
// (the root's, then the instanced scenes' in tree order), then the
// instancing animations, then the played timelines above (so a script's
// or the Scene3D's `animation` plays over the machine); PHASE_SETTLE has
// each machine try its transitions again with no time (Rive's settle: a
// binding pushed or a script moved what a condition reads), at most
// SETTLE_MAX times. The machines read the instance's data
// (SceneInstance.dataValues: the view model the host bound; globalValues:
// a global found by the bindings or the host's lookup, looked for again on
// each advance for GLOBAL_LOOKUP_ADVANCES advances, then said once in the
// status's errors). Their fire actions' events go to
// SceneInstance.fireEvent as a timeline's do; the view model triggers they
// fire are held and fired at the start of the next frame (PHASE_ARTBOARDS,
// before the artboard textures advance: the part goes before the
// artboards feature, installAnimationFeature), since a Rive host resets a
// trigger at the end of the frame it fires in, as the bindings' signal
// triggers are. playStateMachine(name) (the Scene3D's `stateMachine`, a
// script's play()) runs another machine in the root scene from its start.
//
// Milestone 47 (docs/plans/RIVE_MODEL.md section 3.5; docs/scene/
// STATE_MACHINES.md "Listeners"): the machines' listeners. A pointer event
// no script's _input handled (Godot's order, as the interaction feature's;
// a pointer exit always, so that nothing stays hovered) goes to the
// runner's listeners with what it hits (SceneInstance.listenerHits: picked
// once for the event, which the artboards part reads too); a listener that
// performed asks for a new picture. The part answers listenerGroups with
// the running machines' pointer targets, so that the pick casts the
// collision objects among them, and only while one has a pointer
// listener. An event the scene fires (a timeline's key, a machine's or a
// listener's fire action, a script's scene.fireEvent: all go through
// SceneInstance.fireEvent) fires each `<binding property="fire" path=...
// [global=...]/>` of its declaration: the view model trigger at that path
// in the firing scene's data context (as a binding the scene's file
// declares on its root would find it: ../binding/binder.as
// contextCandidates, the innermost data_path first), or in the global,
// held to the next PHASE_ARTBOARDS as the machines' own trigger firings
// are, so that a Rive state machine reading it sees it once; each
// binding's path is resolved the first time its event fires from that
// scene and kept (again only when the data answers other values). Then the
// runner's event listeners hear it (at their next advance).
//
// A scene that plays nothing costs nothing: no instance is made until
// asked, and an idle part allocates nothing per frame; a played animation
// allocates nothing per frame after its first but for a node property's
// write (an effective property's new Value, as a binding's), and so does a
// running machine (../sm/instance.as says why). The events and signals its
// keys fire are made once each (SceneInstance.emitKeyed, fireEvent) and
// their queues' entries are reused once dropped, so a loop that fires them
// allocates nothing either; a held trigger's handle is looked up once.
//
// The status gains "animations" (how many are playing) for a scene that
// declares any, and, while the root scene runs a machine,
// `"state_machine":"Main","states":["Door/Open"]` (made again only when a
// state changed), so every other scene's status is as before.

import { ViewModel } from "rive/data";
import { jsonQuote } from "../../base/json";
import { InputEvent, InputKind as PointerKind } from "../script";
import { VmKind } from "../riv/riv_info";
import { contextCandidates } from "../binding/binder";
import { SceneNode } from "../tree/node";
import { EventDecl } from "../anim/decl";
import { ScriptAnimation, ScriptInput, ScriptScene, ScriptStateMachine } from "../script/scene_api";
import { LinearAnimationInstance, CallbackSink } from "../anim/instance";
import {
    SceneAnimations, flushQuaternions, rootSceneAnimations, sceneAnimationsFor, sceneAnimationsOf,
} from "../anim/scene_anims";
import { TriggerSink, ViewModelValues } from "../binding/values";
import { ActionKind, ConditionKind, FireActionDecl, InputKind, ListenerActionKind, StateMachineDecl } from "../sm/decl";
import { GLOBAL_LOOKUP_ADVANCES, SmData } from "../sm/data";
import { SmEventSink, StateMachineInstance } from "../sm/instance";
import { MachineRunner, MachineSlot } from "../sm/runner";
import { SceneMachines, sceneMachinesFor, sceneMachinesOf } from "../sm/scene_machines";
import {
    FEATURE_ANIMATION, FEATURE_ARTBOARDS, Feature, InstanceFeature, PHASE_ANIMATION, PHASE_ARTBOARDS, PHASE_SETTLE,
} from "./features";
import { SceneInstance, SceneRuntime } from "./scene_runtime";

export class AnimationFeature extends Feature {
    bit(): u32 {
        return FEATURE_ANIMATION;
    }

    forInstance(inst: SceneInstance): InstanceFeature {
        return new AnimationPart(inst);
    }
}

// Where a played animation's callbacks go: the event or signal its track
// names, fired on the instance.
class FireCallbacks extends CallbackSink {
    inst: SceneInstance;
    // The animation advanced now.
    scene: SceneAnimations? = null;
    index: i32 = -1;

    constructor(inst: SceneInstance) {
        super();
        this.inst = inst;
    }

    callback(objectIndex: i32, trackIndex: i32, delaySeconds: f32): void {
        const sa = this.scene;
        if (sa == null) return;
        const t = sa.trackTarget(this.index, objectIndex, trackIndex);
        if (t == null) return;
        const ev = t.event;
        if (ev != null) {
            this.inst.fireEvent(sa.root, ev.name, ev, delaySeconds);
            return;
        }
        if (t.signal.length == 0) return;
        const node = sa.targetNode(this.index, objectIndex);
        // (its event made once: a loop that crosses the key allocates
        // nothing for it)
        if (node != null) this.inst.emitKeyed(node, t.signal);
    }
}

// Milestone 46: where the machines' actions go. Events fire on the
// instance at once; a view model trigger is held for the next frame's
// PHASE_ARTBOARDS (see the header), its handle looked up the first time
// (by the values it is in and its path) and kept.
class MachineEvents extends SmEventSink {
    part: AnimationPart;
    // The triggers looked up: their values, paths and handles (null: the
    // path names no trigger there).
    private looked: Array<ViewModelValues> = [];
    private paths: Array<string> = [];
    private sinks: Array<TriggerSink?> = [];
    // The firings held, in order (the first `held` entries).
    private queue: Array<TriggerSink> = [];
    held: i32 = 0;

    constructor(part: AnimationPart) {
        super();
        this.part = part;
    }

    fireEvent(sceneRoot: SceneNode, name: string, decl: EventDecl?, delaySeconds: f32): void {
        this.part.inst.fireEvent(sceneRoot, name, decl, delaySeconds);
    }

    fireTrigger(sceneRoot: SceneNode, path: string, global: string): void {
        const d = this.part.data;
        const vm = global.length > 0 ? d.global(global) : d.values();
        if (vm == null) return;
        const sink = this.sinkOf(vm, path);
        if (sink == null) return;
        if (this.held < this.queue.length) this.queue[this.held] = sink;
        else this.queue.push(sink);
        this.held++;
    }

    emitKeyed(node: SceneNode, signal: string): void {
        this.part.inst.emitKeyed(node, signal);
    }

    // Fires what was held (allocates nothing).
    fireHeld(): void {
        const n = this.held;
        if (n == 0) return;
        this.held = 0;
        for (let i = 0; i < n; i++) unchecked(this.queue[i]).fire();
    }

    private sinkOf(vm: ViewModelValues, path: string): TriggerSink? {
        for (let i = 0; i < this.looked.length; i++) {
            if (unchecked(this.looked[i]) === vm && unchecked(this.paths[i]) == path) return unchecked(this.sinks[i]);
        }
        const s = vm.trigger(path);
        this.looked.push(vm);
        this.paths.push(path);
        this.sinks.push(s);
        return s;
    }
}

// Milestone 46: the machines' data: the instance's bound values, and each
// global looked up through the instance (found ones kept; a missing one
// tried once an advance for GLOBAL_LOOKUP_ADVANCES advances, then said once
// in the status's errors).
class InstanceData extends SmData {
    inst: SceneInstance;
    // The advances so far (a global is tried at most once in each).
    advances: i64 = 0;
    private names: Array<string> = [];
    private found: Array<ViewModelValues?> = [];
    private tries: Array<i32> = [];
    private lastTry: Array<i64> = [];

    constructor(inst: SceneInstance) {
        super();
        this.inst = inst;
    }

    values(): ViewModelValues? {
        return this.inst.dataValues();
    }

    global(name: string): ViewModelValues? {
        let i = this.names.indexOf(name);
        if (i < 0) {
            i = this.names.length;
            this.names.push(name);
            this.found.push(null);
            this.tries.push(0);
            this.lastTry.push(-1);
        }
        const had = this.found[i];
        if (had != null) return had;
        if (this.tries[i] >= GLOBAL_LOOKUP_ADVANCES || this.lastTry[i] == this.advances) return null;
        this.lastTry[i] = this.advances;
        this.tries[i] = this.tries[i] + 1;
        const v = this.inst.globalValues(name);
        if (v != null) {
            this.found[i] = v;
            return v;
        }
        if (this.tries[i] >= GLOBAL_LOOKUP_ADVANCES) this.inst.fail("global view model \"" + name + "\" not found");
        return null;
    }

    // The host bound `name` anew: looked up again.
    forget(name: string): void {
        const i = this.names.indexOf(name);
        if (i < 0) return;
        this.found[i] = null;
        this.tries[i] = 0;
        this.lastTry[i] = -1;
    }
}

// One animation of one scene, for scripts and the Scene3D's route: its
// instance (made the first time it is used) and whether the part plays it.
export class RunAnimation extends ScriptAnimation {
    part: AnimationPart;
    scene: SceneAnimations;
    index: i32;
    // Whether the part plays it, and whether it is in the part's list (a
    // stop during the phase leaves it there until the phase ends).
    playing: bool = false;
    listed: bool = false;
    // Played or set since the last apply: applied on the next frame even
    // when no time passes (a scene paused, the frame it is played).
    fresh: bool = false;
    private made: LinearAnimationInstance? = null;

    constructor(part: AnimationPart, scene: SceneAnimations, index: i32) {
        super();
        this.part = part;
        this.scene = scene;
        this.index = index;
        const a = scene.animations[index];
        this.name = a.name;
        this.duration = a.durationSeconds();
    }

    get instance(): LinearAnimationInstance {
        const m = this.made;
        if (m != null) return m;
        const made = new LinearAnimationInstance(this.scene.animations[this.index]);
        this.made = made;
        return made;
    }

    advance(seconds: f32): bool {
        const more = this.part.step(this, seconds);
        this.part.applyNow(this);
        return more;
    }

    setTime(seconds: f32): void {
        this.instance.setTime(seconds);
        this.part.applyNow(this);
    }

    setTimeFrames(frames: f32): void {
        this.instance.setTimeFrames(frames);
        this.part.applyNow(this);
    }

    setTimePercentage(fraction: f32): void {
        this.instance.setTimePercentage(fraction);
        this.part.applyNow(this);
    }

    time(): f32 {
        const m = this.made;
        return m != null ? m.time : this.scene.animations[this.index].startTime();
    }

    play(): void {
        const inst = this.instance;
        if (!inst.keepGoing()) inst.reset();
        this.part.start(this);
    }

    stop(): void {
        this.part.halt(this);
    }

    isPlaying(): bool {
        return this.playing;
    }
}

// Milestone 46: one input of a scene's machine, for a script: the
// machine's instance's (the one the scene runs when it runs this machine).
export class RunInput extends ScriptInput {
    machine: RunStateMachine;
    index: i32;

    constructor(machine: RunStateMachine, index: i32, kind: InputKind, name: string) {
        super();
        this.machine = machine;
        this.index = index;
        this.kind = <i32>kind;
        this.name = name;
    }

    number(): f64 {
        return this.machine.instance().inputNumber(this.index);
    }

    setNumber(v: f64): void {
        this.machine.instance().setInputNumber(this.index, v);
    }

    boolean(): bool {
        return this.machine.instance().inputBool(this.index);
    }

    setBoolean(b: bool): void {
        this.machine.instance().setInputBool(this.index, b);
    }

    fire(): void {
        this.machine.instance().fireInput(this.index);
    }
}

// Milestone 46: one state machine of one scene, for scripts: its instance
// in the scene's slot (one object, whether the scene runs it or not).
export class RunStateMachine extends ScriptStateMachine {
    part: AnimationPart;
    scene: SceneMachines;
    index: i32;
    private inputs: Array<RunInput?> = [];

    constructor(part: AnimationPart, scene: SceneMachines, index: i32) {
        super();
        this.part = part;
        this.scene = scene;
        this.index = index;
        this.name = scene.machines[index].name;
        for (let i = 0; i < scene.machines[index].inputs.length; i++) this.inputs.push(null);
    }

    // The machine's instance in its scene's slot (made the first time).
    instance(): StateMachineInstance {
        const r = this.part.runnerOf();
        return r.instanceOf(this.part.slotOf(this.scene), this.index);
    }

    input(name: string): ScriptInput? {
        const i = this.scene.machines[this.index].inputIndex(name);
        if (i < 0) return null;
        const had = this.inputs[i];
        if (had != null) return had;
        const inp = this.scene.machines[this.index].inputs[i];
        const made = new RunInput(this, i, inp.kind, inp.name);
        this.inputs[i] = made;
        return made;
    }

    currentStates(): Array<string> {
        return this.instance().currentStates();
    }

    isPlaying(): bool {
        const slot = this.part.slotOf(this.scene);
        return slot.running == this.index;
    }

    play(): void {
        this.part.runMachine(this.scene, this.index);
    }

    stop(): void {
        if (this.isPlaying()) this.part.runMachine(this.scene, -1);
    }
}

// One scene, for its scripts: its animations, each one object; milestone
// 46: its state machines, each one object, and the instance's data.
export class RunScene extends ScriptScene {
    part: AnimationPart;
    // null: a scene that declares no timelines.
    scene: SceneAnimations?;
    // Milestone 46: the scene's machines (null: it declares none).
    machines: SceneMachines? = null;
    private runs: Array<RunAnimation?> = [];
    private machineRuns: Array<RunStateMachine?> = [];

    constructor(part: AnimationPart, scene: SceneAnimations?) {
        super();
        this.part = part;
        this.scene = scene;
        if (scene != null) for (let i = 0; i < scene.animations.length; i++) this.runs.push(null);
    }

    // The animation at `i` (made once).
    at(i: i32): RunAnimation {
        const had = this.runs[i];
        if (had != null) return had;
        const made = new RunAnimation(this.part, this.scene as SceneAnimations, i);
        this.runs[i] = made;
        return made;
    }

    animation(name: string): ScriptAnimation? {
        const sa = this.scene;
        if (sa == null) return null;
        const i = sa.index(name);
        return i >= 0 ? this.at(i) : null;
    }

    animationNames(): Array<string> {
        const sa = this.scene;
        return sa != null ? sa.names() : [];
    }

    fireEvent(name: string): bool {
        const sa = this.scene;
        if (sa == null) return false;
        const ev = sa.event(name);
        if (ev == null) return false;
        this.part.inst.fireEvent(sa.root, name, ev, 0);
        return true;
    }

    stateMachine(name: string): ScriptStateMachine? {
        const sm = this.machines;
        if (sm == null) return null;
        const i = sm.index(name);
        if (i < 0) return null;
        while (this.machineRuns.length < sm.machines.length) this.machineRuns.push(null);
        const had = this.machineRuns[i];
        if (had != null) return had;
        const made = new RunStateMachine(this.part, sm, i);
        this.machineRuns[i] = made;
        return made;
    }

    stateMachineNames(): Array<string> {
        const sm = this.machines;
        return sm != null ? sm.names() : [];
    }

    bindViewModel(vm: ViewModel?): void {
        this.part.inst.bindViewModel(vm);
    }

    bindGlobal(name: string, vm: ViewModel?): void {
        this.part.inst.bindGlobal(name, vm);
    }
}

// One instance's animations and state machines.
export class AnimationPart extends InstanceFeature {
    inst: SceneInstance;
    // What plays, in play order.
    played: Array<RunAnimation> = [];
    // Milestone 46: the tree's machines (null until the tree is attached),
    // their data and their sink.
    runner: MachineRunner? = null;
    data: InstanceData;
    machineEvents: MachineEvents;
    // Each scene's script object (one per SceneAnimations), and the one of
    // the scenes that declare no timelines.
    // (by the scene's root's serial, never the object: a map keyed by an
    // object finds nothing once a baked project's collector moved it,
    // ../tree/node.as SceneNode.serial)
    private scenes: Map<i32, RunScene> = new Map<i32, RunScene>();
    private noScene: RunScene? = null;
    // Milestone 46: the script objects of scenes with machines and no
    // timelines, by their machines.
    private machineScenes: Map<SceneMachines, RunScene> = new Map<SceneMachines, RunScene>();
    // What the Scene3D's route plays (playAnimation), or null.
    private routed: RunAnimation? = null;
    // Whether the tree declares any animation (the status says
    // "animations" then).
    private declares: bool = false;
    // How many times something started or stopped (the status's stamp).
    private changes: i64 = 0;
    private sink: FireCallbacks;
    // Whether a value changed since the phase last answered (a script's
    // advance or setTime between frames).
    private dirty: bool = false;
    private iterating: bool = false;
    // Milestone 46: the status's machine part, and what it was made from
    // (the root's machine instance, and its state changes then).
    private machineStatus: string = "";
    private statusOf: StateMachineInstance? = null;
    private statusChanges: i64 = -1;
    // Whether the last PHASE_ANIMATION changed a value (tests, tools).
    changedLast: bool = false;
    // Milestone 46: whether the last PHASE_SETTLE changed a state (tests).
    settledLast: bool = false;
    // Milestone 47: the running machines' pointer targets (listenerGroups,
    // refilled), the fire bindings resolved (FireBinding: by event
    // declaration, scene and binding), and the pointer events a listener
    // performed on (tests).
    private targets: Array<SceneNode> = [];
    private fireBindings: Array<FireBinding> = [];
    listenerEvents: i64 = 0;

    constructor(inst: SceneInstance) {
        super();
        this.inst = inst;
        this.sink = new FireCallbacks(inst);
        this.data = new InstanceData(inst);
        this.machineEvents = new MachineEvents(this);
    }

    attach(inst: SceneInstance, root: SceneNode): void {
        // (the tree's root: every scene's slot; a subtree added later: its
        // own, after the others)
        const r = this.runnerOf();
        r.build(root);
        this.sayProblems(r);
        // (a condition reading a node's screen output needs the view the
        // bindings' push works it out from, as a binding of one does)
        if (!inst.wantsOutputView) {
            for (let i = 0; i < r.slots.length; i++) {
                const sm = r.slots[i].scene;
                if (sm != null && readsScreenOutput(sm)) inst.wantsOutputView = true;
            }
        }
        if (this.declares) return;
        const all = root === inst.tree.root ? sceneAnimationsOf(inst.tree) : subtreeAnimations(root);
        for (let i = 0; i < all.length; i++) if (all[i].animations.length > 0) this.declares = true;
    }

    private sayProblems(r: MachineRunner): void {
        if (r.problems.length == 0) return;
        const p = r.takeProblems();
        for (let i = 0; i < p.length; i++) this.inst.fail(p[i]);
    }

    // A subtree leaves the tree: what plays on its scenes stops, and its
    // scenes' machines stop running.
    detach(inst: SceneInstance, root: SceneNode): void {
        for (let i = this.played.length - 1; i >= 0; i--) {
            const r = this.played[i];
            if (isWithin(r.scene.root, root)) this.halt(r);
        }
        const run = this.runner;
        if (run != null && root !== inst.tree.root) run.remove(root);
        // (The scripts' scene objects stay: removeChild is also how a node
        // is reparented, and a script that kept its scene or an animation
        // from _ready must still hold the one `this.scene` answers. Those
        // of freed subtrees are dropped when a new one is made,
        // sceneObject.)
    }

    advance(inst: SceneInstance, seconds: f64, phase: i32): bool {
        if (phase == PHASE_ARTBOARDS) {
            this.machineEvents.fireHeld();
            return false;
        }
        if (phase == PHASE_SETTLE) {
            const r = this.runner;
            const settled = r != null && r.slots.length > 0 && r.settle();
            this.settledLast = settled;
            return settled;
        }
        if (phase != PHASE_ANIMATION) return false;
        let changed = false;
        const r = this.runner;
        if (r != null && r.slots.length > 0) {
            this.data.advances++;
            if (r.advance(<f32>seconds)) changed = true;
        }
        if (this.advancePlayed(<f32>seconds)) changed = true;
        this.changedLast = changed;
        return changed;
    }

    // The phase's work: every played animation advanced and applied.
    private advancePlayed(dt: f32): bool {
        let changed = this.dirty;
        this.dirty = false;
        const list = this.played;
        if (list.length == 0) return changed;
        // (a callback may play or stop animations: one stopped stays in
        // the list until the loop ends, one started now plays from the
        // next frame)
        this.iterating = true;
        const n = list.length;
        for (let i = 0; i < n; i++) {
            const r = unchecked(list[i]);
            if (!r.playing) continue;
            if (dt == 0 && !r.fresh) continue;
            if (dt != 0) {
                // (its callbacks may run scripts: they see the rotations
                // the animations before it left)
                if (r.scene.animations[r.index].callbackTracks.length > 0) flushQuaternions();
                this.step(r, dt);
            }
            if (this.applyRun(r, true)) changed = true;
            if (!r.instance.keepGoing()) this.halt(r);
        }
        this.iterating = false;
        flushQuaternions();
        let k = 0;
        for (let i = 0; i < list.length; i++) {
            const r = unchecked(list[i]);
            if (r.playing) list[k++] = r;
            else r.listed = false;
        }
        list.length = k;
        return changed;
    }

    // Advances `r`'s instance by `seconds`, its callbacks fired; whether it
    // keeps going.
    // The sink is shared, and a callback runs a script that may advance
    // or set another animation (a nested step): what the sink pointed at
    // is put back afterwards, not cleared, so the outer animation's later
    // callbacks of the same advance still reach it, and only it.
    step(r: RunAnimation, seconds: f32): bool {
        const sink = this.sink;
        const outerScene = sink.scene;
        const outerIndex = sink.index;
        sink.scene = r.scene;
        sink.index = r.index;
        const more = r.instance.advance(seconds, sink);
        sink.scene = outerScene;
        sink.index = outerIndex;
        return more;
    }

    // Applies `r` now (a script's advance or setTime): the next draw is new
    // when a value changed.
    applyNow(r: RunAnimation): void {
        if (this.applyRun(r)) {
            this.dirty = true;
            this.inst.touch();
        }
    }

    // Applies `r` with its mix (`deferred`: its quaternions left for the
    // phase's end, flushQuaternions).
    private applyRun(r: RunAnimation, deferred: bool = false): bool {
        r.fresh = false;
        const mix = r.mix;
        if (!(mix > 0)) return false;
        const m: f32 = mix < 1 ? mix : 1;
        return deferred ? r.scene.applyDeferred(this.inst.tree, r.instance, m) : r.scene.apply(this.inst.tree, r.instance, m);
    }

    // `r` plays (after the others; once).
    start(r: RunAnimation): void {
        r.fresh = true;
        if (r.playing) return;
        r.playing = true;
        this.changes++;
        if (r.listed) return;
        r.listed = true;
        this.played.push(r);
    }

    // `r` stops playing (its values stay where it left them).
    halt(r: RunAnimation): void {
        if (!r.playing) return;
        r.playing = false;
        if (this.routed === r) this.routed = null;
        this.changes++;
        if (this.iterating) return;
        const i = this.played.indexOf(r);
        if (i >= 0) this.played.splice(i, 1);
        r.listed = false;
    }

    // How many play.
    get playingCount(): i32 {
        let n = 0;
        for (let i = 0; i < this.played.length; i++) if (unchecked(this.played[i]).playing) n++;
        return n;
    }

    playAnimation(inst: SceneInstance, name: string): bool {
        const was = this.routed;
        if (name.length == 0) {
            if (was != null) this.halt(was);
            this.routed = null;
            return true;
        }
        const sa = rootSceneAnimations(inst.tree);
        const i = sa != null ? sa.index(name) : -1;
        if (sa == null || i < 0) {
            inst.fail("animation \"" + name + "\" not found in " + inst.scenePath);
            return false;
        }
        const r = this.sceneObject(sa).at(i);
        if (was != null && was !== r) this.halt(was);
        r.instance.reset();
        this.start(r);
        this.routed = r;
        return true;
    }

    // Milestone 46: the root scene runs machine `name` ("" its
    // default_state_machine, "-" none) from its start.
    playStateMachine(inst: SceneInstance, name: string): bool {
        const r = this.runnerOf();
        if (r.playRoot(name)) {
            this.changes++;
            inst.touch();
            return true;
        }
        inst.fail("state machine \"" + name + "\" not found in " + inst.scenePath);
        return false;
    }

    // The runner (made over the tree when asked before the attach).
    runnerOf(): MachineRunner {
        const have = this.runner;
        if (have != null) return have;
        const r = new MachineRunner(this.inst.tree);
        r.data = this.data;
        r.events = this.machineEvents;
        r.view = this.inst.outputView;
        this.runner = r;
        return r;
    }

    // The slot of `scene` (made when it has none: a scene whose machine
    // runs none yet).
    slotOf(scene: SceneMachines): MachineSlot {
        const r = this.runnerOf();
        const had = r.slotFor(scene.root);
        if (had != null) return had;
        const s = new MachineSlot(scene.root, scene.root === this.inst.tree.root, scene);
        // (a scene no longer in the tree, which a script may still hold,
        // gets a slot the runner never advances: its nodes may be freed)
        if (!scene.root.freed && within(scene.root, this.inst.tree.root)) r.slots.push(s);
        return s;
    }

    // `scene` runs its machine `mi` (-1: none) from its start (a script's
    // play or stop).
    runMachine(scene: SceneMachines, mi: i32): void {
        const r = this.runnerOf();
        r.run(this.slotOf(scene), mi);
        this.changes++;
        this.inst.touch();
    }

    bindGlobal(inst: SceneInstance, name: string, vm: ViewModel?): void {
        this.data.forget(name);
    }

    // Milestone 47: a pointer event to the machines' listeners (see the
    // header). Never handled: the interaction feature's signals and the
    // artboards hear the same event.
    input(inst: SceneInstance, e: InputEvent): bool {
        if (!e.isPointer()) return false;
        const r = this.runner;
        if (e.handled && e.kind != PointerKind.PointerExit) {
            // (a release a script handled still ends the listeners' press)
            if (e.kind == PointerKind.PointerUp && r != null) r.cancelPress(e.pointer);
            return false;
        }
        if (r == null || r.slots.length == 0 || !r.hasPointerListeners()) return false;
        if (r.pointer(e.kind, e.pointer, inst.listenerHits(e))) {
            this.listenerEvents++;
            // (a write, an input or a moved node: the machine applies it at
            // its next advance, and the picture after shows it)
            this.dirty = true;
            inst.touch();
        }
        return false;
    }

    listenerGroups(inst: SceneInstance, out: Array<SceneNode>): bool {
        const r = this.runner;
        if (r == null || r.slots.length == 0 || !r.hasPointerListeners()) return false;
        const t = this.targets;
        r.listenerTargets(t);
        for (let i = 0; i < t.length; i++) out.push(unchecked(t[i]));
        return true;
    }

    eventFired(inst: SceneInstance, sceneRoot: SceneNode, name: string, decl: EventDecl?): void {
        if (decl != null) {
            const bs = decl.bindings;
            for (let i = 0; i < bs.length; i++) {
                const b = unchecked(bs[i]);
                if (b.property != FIRE_PROPERTY || b.path.length == 0) continue;
                const fb = this.fireBinding(decl, sceneRoot, i);
                const vm = b.global.length > 0 ? this.data.global(b.global) : this.data.values();
                if (vm == null) continue;
                if (fb.values !== vm) fb.resolve(vm, b.path, b.global);
                if (fb.found) this.machineEvents.fireTrigger(sceneRoot, fb.resolved, b.global);
            }
        }
        const r = this.runner;
        if (r != null && r.slots.length > 0) r.eventFired(sceneRoot, name);
    }

    // The resolution of binding `index` of `decl` fired from the scene at
    // `sceneRoot` (made the first time; a scan: a scene's events are few).
    private fireBinding(decl: EventDecl, sceneRoot: SceneNode, index: i32): FireBinding {
        const list = this.fireBindings;
        for (let i = 0; i < list.length; i++) {
            const f = unchecked(list[i]);
            if (f.decl === decl && f.root === sceneRoot && f.index == index) return f;
        }
        // (those of freed scenes go first: a scene spawned and freed again
        // and again keeps no list of the dead)
        let w = 0;
        for (let i = 0; i < list.length; i++) {
            const f = unchecked(list[i]);
            if (!f.root.freed) list[w++] = f;
        }
        list.length = w;
        const sa = sceneRoot.animations;
        const file = sa != null && sa.root === sceneRoot ? sa.file : sceneRoot.sceneFile;
        const made = new FireBinding(decl, sceneRoot, index, file);
        list.push(made);
        return made;
    }

    sceneOf(inst: SceneInstance, node: SceneNode): ScriptScene? {
        const sa = sceneAnimationsFor(node);
        const sm = sceneMachinesFor(node);
        // (each looks up the nearest scene that has its kind: a scene with
        // machines and no timelines inside one with timelines is the
        // nearer, and the script's)
        if (sa != null && (sm == null || sm.root === sa.root || !within(sm.root, sa.root))) {
            const s = this.sceneObject(sa);
            if (s.machines == null && sm != null && sm.root === sa.root) s.machines = sm;
            return s;
        }
        if (sm != null) {
            if (this.machineScenes.has(sm)) return this.machineScenes.get(sm);
            const made = new RunScene(this, null);
            made.machines = sm;
            this.machineScenes.set(sm, made);
            return made;
        }
        let none = this.noScene;
        if (none == null) {
            none = new RunScene(this, null);
            this.noScene = none;
        }
        return none;
    }

    // How many scenes' script objects are held (tests: a spawn-and-free
    // loop must not grow it).
    sceneObjectCount(): i32 {
        return this.scenes.size;
    }

    private sceneObject(sa: SceneAnimations): RunScene {
        const key = sa.root.serial;
        if (this.scenes.has(key)) {
            const had = this.scenes.get(key);
            if (had.scene === sa) return had;
        }
        // Kept, the scene objects of freed subtrees would each hold their
        // animations' instances and, through the scene's root, the freed
        // subtree, so a spawn-and-free loop would grow without bound: they
        // go before a new one is made (so at most the last one freed is
        // held). (Their plays were halted when the subtree left the tree.)
        if (this.scenes.size > 0) {
            const keys = this.scenes.keys();
            for (let i = 0; i < keys.length; i++) {
                const held = this.scenes.get(keys[i]).scene;
                if (held == null || held.root.freed) this.scenes.delete(keys[i]);
            }
        }
        const made = new RunScene(this, sa);
        this.scenes.set(key, made);
        return made;
    }

    // The root scene's machine running now, or null.
    private rootMachine(): StateMachineInstance? {
        const r = this.runner;
        if (r == null) return null;
        const s = r.rootSlot();
        return s != null ? s.current : null;
    }

    status(inst: SceneInstance): string {
        const head = this.declares ? ",\"animations\":" + this.playingCount.toString() : "";
        const m = this.rootMachine();
        if (m == null) return head;
        if (m !== this.statusOf || m.stateChanges != this.statusChanges) {
            this.statusOf = m;
            this.statusChanges = m.stateChanges;
            const states = m.currentStates();
            const quoted = new Array<string>();
            for (let i = 0; i < states.length; i++) quoted.push(jsonQuote(states[i]));
            this.machineStatus = ",\"state_machine\":" + jsonQuote(m.machine.name) + ",\"states\":[" + quoted.join(",") + "]";
        }
        return head + this.machineStatus;
    }

    stamp(inst: SceneInstance): i64 {
        const m = this.rootMachine();
        const machine: i64 = m != null ? (m.stateChanges + 1) * 7919 + <i64>changeId(m) : 0;
        // (`changes` counted whether or not the scene declares timelines: a
        // machine switched for another of as many layers and inputs, at the
        // same count of state changes, says its new name too)
        return this.changes * 1000003 + machine;
    }

    dispose(inst: SceneInstance): void {
        for (let i = 0; i < this.played.length; i++) {
            this.played[i].playing = false;
            this.played[i].listed = false;
        }
        this.played.length = 0;
        this.routed = null;
        // (the scripts' scene objects hold the tree's scenes)
        this.scenes.clear();
        this.machineScenes.clear();
        this.runner = null;
        this.statusOf = null;
    }

    // Milestone 49 (features.as): whether a scene of the tree declares an
    // Event with a fire binding, or a state machine that writes the data.
    writesData(inst: SceneInstance): bool {
        const anims = sceneAnimationsOf(inst.tree);
        for (let i = 0; i < anims.length; i++) if (eventsWrite(anims[i].events)) return true;
        const machines = sceneMachinesOf(inst.tree);
        for (let i = 0; i < machines.length; i++) if (machinesWrite(machines[i].decls)) return true;
        return false;
    }

    // Milestone 49 (features.as): whether a scene of the tree declares an
    // Event (its timelines, machines and listeners fire only declared
    // ones).
    firesEvents(inst: SceneInstance): bool {
        const anims = sceneAnimationsOf(inst.tree);
        for (let i = 0; i < anims.length; i++) if (anims[i].events.length > 0) return true;
        return false;
    }
}

// Milestone 49: whether one of `events` fires a view model trigger (a
// `<binding property="fire">`).
export function eventsWrite(events: Array<EventDecl>): bool {
    for (let i = 0; i < events.length; i++) {
        const bs = events[i].bindings;
        for (let k = 0; k < bs.length; k++) if (bs[k].property == FIRE_PROPERTY && bs[k].path.length > 0) return true;
    }
    return false;
}

// Milestone 49: whether one of `decls` writes the view model: a listener's
// ListenerViewModelChange, or a state's or a transition's
// StateMachineFireTrigger.
export function machinesWrite(decls: Array<StateMachineDecl>): bool {
    for (let m = 0; m < decls.length; m++) {
        const d = decls[m];
        for (let l = 0; l < d.listeners.length; l++) {
            const actions = d.listeners[l].actions;
            for (let a = 0; a < actions.length; a++) if (actions[a].kind == ListenerActionKind.ViewModelChange) return true;
        }
        for (let l = 0; l < d.layers.length; l++) {
            const states = d.layers[l].states;
            for (let s = 0; s < states.length; s++) {
                if (firesTrigger(states[s].actions)) return true;
                const ts = states[s].transitions;
                for (let t = 0; t < ts.length; t++) if (firesTrigger(ts[t].actions)) return true;
            }
        }
    }
    return false;
}

function firesTrigger(actions: Array<FireActionDecl>): bool {
    for (let i = 0; i < actions.length; i++) if (actions[i].kind == ActionKind.FireTrigger) return true;
    return false;
}

// Milestone 47: the node property an Event's binding fires
// (`<binding property="fire" path="..."/>`).
const FIRE_PROPERTY = "fire";

// Milestone 47: one `<binding property="fire">` of one event declaration as
// fired from one scene: the path it names in that scene's data context,
// resolved against the values it last fired in (the first candidate that
// names a property wins, as a binding's does; it fires only when that
// property is a trigger).
class FireBinding {
    decl: EventDecl;
    root: SceneNode;
    index: i32;
    file: string;
    values: ViewModelValues? = null;
    resolved: string = "";
    found: bool = false;
    private candidates: Array<string>? = null;

    constructor(decl: EventDecl, root: SceneNode, index: i32, file: string) {
        this.decl = decl;
        this.root = root;
        this.index = index;
        this.file = file;
    }

    resolve(vm: ViewModelValues, path: string, global: string): void {
        this.values = vm;
        this.found = false;
        this.resolved = "";
        let cs = this.candidates;
        if (cs == null) {
            cs = global.length > 0 ? [path] : contextCandidates(this.root, this.file, path);
            this.candidates = cs;
        }
        for (let i = 0; i < cs.length; i++) {
            const k = vm.kindOf(unchecked(cs[i]));
            if (k == VmKind.Other) continue;
            this.resolved = unchecked(cs[i]);
            this.found = k == VmKind.Trigger;
            return;
        }
    }
}

// A number telling machines apart in the stamp (their layer and state
// counts: two machines of a scene rarely share both).
function changeId(m: StateMachineInstance): i32 {
    return m.machine.layers.length * 131 + m.machine.inputs.length;
}

// Whether `n` is `root` or below it.
function isWithin(n: SceneNode, root: SceneNode): bool {
    let at: SceneNode? = n;
    while (at != null) {
        if (at === root) return true;
        at = at.parent;
    }
    return false;
}

// The scenes of the subtree at `root` (a subtree added at run time).
function subtreeAnimations(root: SceneNode): Array<SceneAnimations> {
    const out = new Array<SceneAnimations>();
    const stack = new Array<SceneNode>();
    stack.push(root);
    while (stack.length > 0) {
        const n = stack.pop();
        const sa = n.animations;
        if (sa != null && sa.root === n) out.push(sa);
        for (let i = 0; i < n.children.length; i++) stack.push(n.children[i]);
    }
    return out;
}

// Adds the animation feature to `rt` (newSceneRuntime, ../../scene.as),
// before the artboards feature when that is installed already (milestone
// 46: so that its part fires the triggers its machines held in the
// artboards phase before the artboard textures advance; the status names
// each part, so its order is unchanged).
export function installAnimationFeature(rt: SceneRuntime): void {
    rt.install(new AnimationFeature());
    const fs = rt.features;
    let artboards = -1;
    let animation = -1;
    for (let i = 0; i < fs.length; i++) {
        const bit = fs[i].bit();
        if (bit == FEATURE_ARTBOARDS && artboards < 0) artboards = i;
        else if (bit == FEATURE_ANIMATION) animation = i;
    }
    if (artboards < 0 || animation < artboards) return;
    const f = fs[animation];
    for (let i = animation; i > artboards; i--) fs[i] = fs[i - 1];
    fs[artboards] = f;
}

// Whether a machine of `sm` has a component condition on a node's screen
// output (screen_position:x, screen_visible...).
function readsScreenOutput(sm: SceneMachines): bool {
    for (let m = 0; m < sm.decls.length; m++) {
        const layers = sm.decls[m].layers;
        for (let l = 0; l < layers.length; l++) {
            const states = layers[l].states;
            for (let s = 0; s < states.length; s++) {
                const ts = states[s].transitions;
                for (let t = 0; t < ts.length; t++) {
                    const cs = ts[t].conditions;
                    for (let c = 0; c < cs.length; c++) {
                        if (cs[c].kind == ConditionKind.Component && cs[c].property.startsWith("screen_")) return true;
                    }
                }
            }
        }
    }
    return false;
}

// Whether `n` is `top` or below it.
function within(n: SceneNode, top: SceneNode): bool {
    let p: SceneNode? = n;
    while (p != null) {
        if (p === top) return true;
        p = p.parent;
    }
    return false;
}
