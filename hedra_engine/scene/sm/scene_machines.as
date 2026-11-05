// A scene's state machines in an instanced tree (docs/plans/RIVE_MODEL.md
// sections 3.3 and 5): one SceneMachines per instanced scene file that
// declares any, on the root of what that file made (SceneNode.machines),
// attached by the instancer (../tree/instance.as) after the file's
// timelines (../anim/scene_anims.as attachSceneAnimations: a machine's
// states play those). Each instanced scene runs its own machine, as a Rive
// nested artboard does (RIVE_MODEL.md section 3.3's table: the instancing
// node's instance_state_machine, instance_animation,
// instance_animation_time, instance_speed and instance_paused, ./decl.as);
// the root scene runs its default_state_machine ("" the first it
// declares, "-" none). ./runner.as runs them, for the run time and the
// tools alike.
//
// The tools sample with runStateMachine (`the CLI render --state-machine
// <name> --frame <n>`, `inspect --state-machine <name> --frame <n>`): the
// tree's machines as the run time runs them (the root's `name`, then every
// instanced scene's, or its instance_animation), over the scene's data
// (./data.as), n frames of 1/60 s, each settled.
//
// stateMachineDataDiagnostics says, beside the bindings' warnings, what
// only the scene's data shows about its machines (the validator, ./check.as,
// says what the file alone shows): a view model path a condition, a blend,
// a fire action or an input's binding names that the data lacks, a
// converter it cannot build, two sides that cannot compare, and an
// instancing node naming a machine or an animation its scene does not have.
//
//   condition-path-unknown       a view model condition's path names nothing
//   condition-global-unknown     its global is none of the data's
//   condition-converter-unknown  its converter is none of the scene's or the
//                                project's (-unsupported, -invalid, -cycle:
//                                as a binding's)
//   condition-type               the two sides cannot compare (their kinds
//                                differ; the literal does not read as the
//                                left side's kind; an operator other than
//                                equal or notEqual on what is not a number;
//                                a value given to a trigger)
//   blend-path-unknown           a 1D blend's or a direct blend's path (or
//                                its global) names nothing
//   blend-type                   it names something other than a number
//   trigger-path-unknown         a fire action's trigger path names no
//                                trigger
//   input-binding-path-unknown   an input's binding names nothing
//   input-binding-type           of a kind the input cannot take
//   instance-state-machine-unknown, instance-animation-unknown
//                                an instancing node names a machine or an
//                                animation its instanced scene lacks
//
// Milestone 47, the listeners' and the events' (RSCN.md "Listeners"):
//
//   listener-target-unknown, listener-action-target-unknown
//                                a listener's target, or an align's, is a
//                                path into an instanced scene that holds
//                                no such node (the file's own paths are the
//                                validator's)
//   listener-event-unknown       an event listener's event is fired by no
//                                scene it hears, when the scene instances
//                                others (the file's own events are the
//                                validator's)
//   listener-path-unknown        a viewModel listener's property (or its
//                                global) names nothing
//   listener-action-path-unknown a ListenerViewModelChange's path or
//                                fromPath names nothing
//   listener-action-global-unknown  its global is none of the data's
//   listener-action-converter-unknown  its converter cannot be built
//   listener-action-type         a literal that does not read as the
//                                property's kind, a source of a kind the
//                                property cannot take, or no source on a
//                                property that is no trigger
//   event-binding-path-unknown   an Event's fire binding names nothing (or
//                                its global is none of the data's)
//   event-binding-type           it names something that is no trigger
//
// Each is a warning (a run reads such a path as no value), at the element,
// its hint listing what the data has, as the binder's do.

import { ListenerFiring } from "./listeners";
import { PointerInput, PointerStep } from "./pointer_input";
import { ListenerHits, ListenerPicker } from "../listen/pick";
import { SceneFrame, SceneRenderOptions, buildSceneFrame } from "../render/adapter";
import { SceneRenderCache } from "../render/cache";
import { InteractionWorld } from "../interaction/world";
import { MachineSlot } from "./runner";
import { Result } from "../../base/util";
import { Diagnostic, Diagnostics, SceneryError, Severity } from "../error";
import { RscnDoc } from "../rscn/doc";
import { XmlPos } from "../../base/xml";
import { SceneNode } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { VmKind, vmKindName } from "../riv/riv_info";
import { BoundValue, MemoryViewModel } from "../binding/values";
import { ConverterLookup, ConverterProblem, buildNamedConverter } from "../binding/converters";
import { SceneData } from "../binding/scene_data";
import { contextCandidates, sceneConverters } from "../binding/binder";
import { BindKind } from "../binding/targets";
import { nodeBindingTarget } from "../binding/shader_targets";
import { DataSource, dataSourceOf } from "../data/source";
import {
    ANIMATION_PROPERTY, ActionKind, CONDITION_ELEMENTS, CONDITION_OP_NAMES, ConditionDecl, ConditionKind, ConditionOp,
    DEFAULT_STATE_MACHINE_PROPERTY, InputKind, ListenerActionDecl, ListenerActionKind, ListenerDecl, ListenerType, NO_STATE_MACHINE,
    STATE_MACHINE_PROPERTY, StateKind, StateMachineDecl,
} from "./decl";
import { StateMachine, prepareStateMachine } from "./machine";
import { SmData } from "./data";
import { comparableKind, parseLiteral } from "./resolve";
import { SmEventSink } from "./instance";
import { MachineRunner, propString } from "./runner";
import { LISTENER_ACTION_TARGET_UNKNOWN_CODE, LISTENER_TARGET_UNKNOWN_CODE } from "./check";
import { EventDecl } from "../anim/decl";
import { SceneAnimations } from "../anim/scene_anims";
import { splitImportedClipLabel } from "../skeleton/names";

// The error of a state machine the scene does not have (render, inspect,
// the Scene3D's stateMachine, an instancing node's state_machine).
export const STATE_MACHINE_UNKNOWN = "state-machine-unknown";

// Milestone 47: an Event's `<binding property="fire" path="...">` names a
// view model trigger the event fires (RSCN.md "Events").
export const EVENT_FIRE_PROPERTY = "fire";

// The frames a tool's sample advances by: 1/60 s each, Rive's preview rate.
export const SAMPLE_FPS: f64 = 60;


// The data-time codes (section 2.4 of the header's table): what only
// the data, or the instanced scene, can tell.
export const CONDITION_PATH_UNKNOWN_CODE = "condition-path-unknown";
export const CONDITION_TYPE_CODE = "condition-type";
export const CONDITION_GLOBAL_UNKNOWN_CODE = "condition-global-unknown";
export const CONDITION_CONVERTER_UNKNOWN_CODE = "condition-converter-unknown";
export const BLEND_PATH_UNKNOWN_CODE = "blend-path-unknown";
export const TRIGGER_PATH_UNKNOWN_CODE = "trigger-path-unknown";
export const INPUT_BINDING_PATH_UNKNOWN_CODE = "input-binding-path-unknown";
export const INPUT_BINDING_TYPE_CODE = "input-binding-type";
// Milestone 47 (see the header).
export const LISTENER_EVENT_UNKNOWN_LOAD_CODE = "listener-event-unknown";
export const LISTENER_PATH_UNKNOWN_CODE = "listener-path-unknown";
export const LISTENER_ACTION_PATH_UNKNOWN_CODE = "listener-action-path-unknown";
export const LISTENER_ACTION_GLOBAL_UNKNOWN_CODE = "listener-action-global-unknown";
export const LISTENER_ACTION_CONVERTER_UNKNOWN_CODE = "listener-action-converter-unknown";
export const LISTENER_ACTION_TYPE_CODE = "listener-action-type";
export const EVENT_BINDING_PATH_UNKNOWN_CODE = "event-binding-path-unknown";
export const EVENT_BINDING_TYPE_CODE = "event-binding-type";

export class SceneMachines {
    // The scene's root in the tree, and its file as errors name it.
    root: SceneNode;
    file: string;
    // As declared, and prepared (the same order).
    decls: Array<StateMachineDecl> = [];
    machines: Array<StateMachine> = [];
    // The load warnings of this scene's machines (each once), also given to
    // the instancer's diagnostics (`diag`) when it had some.
    warnings: Diagnostics = new Diagnostics();
    diag: Diagnostics? = null;
    // Where its converters are looked up (made the first time a machine
    // needs one).
    private lookup: ConverterLookup? = null;

    constructor(root: SceneNode, file: string) {
        this.root = root;
        this.file = file;
    }

    // The index of machine `name`, or -1.
    index(name: string): i32 {
        for (let i = 0; i < this.machines.length; i++) if (this.machines[i].name == name) return i;
        return -1;
    }

    machine(name: string): StateMachine? {
        const i = this.index(name);
        return i >= 0 ? this.machines[i] : null;
    }

    names(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.machines.length; i++) out.push(this.machines[i].name);
        return out;
    }

    // The machine a choice names (an instancing node's state_machine, the
    // root's default_state_machine, the Scene3D's stateMachine): "" the
    // first declared, "-" none (-1), else by name (-1: none of that name).
    choose(choice: string): i32 {
        if (choice == "-") return -1;
        if (choice.length == 0) return this.machines.length > 0 ? 0 : -1;
        return this.index(choice);
    }

    // The scene's own choice: its root's default_state_machine ("" when it
    // sets none).
    defaultChoice(): string {
        return propString(this.root, DEFAULT_STATE_MACHINE_PROPERTY, "");
    }

    // Where its machines' converters are found: the scene file's own, then
    // the project's data (as its bindings'), looked up once.
    converterLookup(tree: SceneTree): ConverterLookup {
        const have = this.lookup;
        if (have != null) return have;
        const l = new ConverterLookup();
        l.scene = sceneConverters(tree, this.file);
        const s = dataSourceOf(tree);
        l.source = s.ok ? s.value : null;
        this.lookup = l;
        return l;
    }
}

// The instancer's call (../tree/instance.as): `doc`'s state machines on
// `root`, the root of the scene the instancer just made from `doc` (`file`
// as errors name it), after attachSceneAnimations put its timelines there.
// Nothing for a scene that declares none. `prepared` keeps the prepared
// machines per document (null: prepared each time), as the timelines'.
export function attachSceneMachines(root: SceneNode, doc: RscnDoc, file: string, diag: Diagnostics,
    prepared: Map<RscnDoc, Array<StateMachine>>? = null): void {
    const decls = doc.stateMachines();
    if (decls.length == 0) return;
    const sm = new SceneMachines(root, file);
    sm.decls = decls;
    sm.diag = diag;
    if (prepared != null && prepared.has(doc) && sameDecls(prepared.get(doc), decls)) {
        sm.machines = prepared.get(doc);
    } else {
        const made = new Array<StateMachine>();
        const anims = root.animations;
        for (let i = 0; i < decls.length; i++) made.push(prepareStateMachine(decls[i], anims != null && anims.root === root ? anims : null));
        sm.machines = made;
        if (prepared != null) prepared.set(doc, made);
    }
    importedAnimationProblems(root, decls, file, diag);
    root.machines = sm;
}

// The animations the document's checks left to the load (../sm/check.as
// SmChecker.importedSource): a state naming an imported clip's label,
// "Walk (hero.glb)", that the scene's animations (its own, then the clips
// of the models it instances) do not hold is state-animation-unknown, an
// error, once per place.
function importedAnimationProblems(root: SceneNode, decls: Array<StateMachineDecl>, file: string, diag: Diagnostics): void {
    const anims = root.animations;
    const scene = anims != null && anims.root === root ? anims : null;
    for (let m = 0; m < decls.length; m++) {
        const layers = decls[m].layers;
        for (let l = 0; l < layers.length; l++) {
            const states = layers[l].states;
            for (let s = 0; s < states.length; s++) {
                const sd = states[s];
                const what = "state \"" + sd.name + "\"";
                if (sd.kind == StateKind.Animation && sd.animation.length > 0) {
                    importedKnown(scene, sd.animation, sd.pos, what, file, diag);
                }
                for (let b = 0; b < sd.blends.length; b++) {
                    importedKnown(scene, sd.blends[b].animation, sd.blends[b].pos, what + "'s blend", file, diag);
                }
            }
        }
    }
}

function importedKnown(scene: SceneAnimations?, name: string, pos: XmlPos, what: string, file: string,
    diag: Diagnostics): void {
    if (splitImportedClipLabel(name) == null) return;
    if (scene != null && scene.index(name) >= 0) return;
    addOnce(diag.items, new Diagnostic(Severity.Error, "state-animation-unknown", file, pos.line, pos.col,
        what + " names animation \"" + name + "\", which the scene does not declare",
        scene != null && scene.animations.length > 0 ? "the scene's animations are " + scene.names().join(", ")
            : "the scene instances no model with a clip of that name"));
}

// Whether `machines` were prepared from `decls` (the same objects: a
// document edited since prepares again).
function sameDecls(machines: Array<StateMachine>, decls: Array<StateMachineDecl>): bool {
    if (machines.length != decls.length) return false;
    for (let i = 0; i < decls.length; i++) if (machines[i].decl !== decls[i]) return false;
    return true;
}

// Every scene of `tree` that declares state machines: the root's first,
// then the instanced scenes' in tree order (the order the run time
// advances them: a parent's before its children's, as Rive's nested
// artboards advance after their host's machine).
export function sceneMachinesOf(tree: SceneTree): Array<SceneMachines> {
    const out = new Array<SceneMachines>();
    collect(tree.root, out);
    return out;
}

function collect(n: SceneNode, out: Array<SceneMachines>): void {
    const sm = n.machines;
    if (sm != null && sm.root === n) out.push(sm);
    for (let i = 0; i < n.children.length; i++) collect(n.children[i], out);
}

// The root scene's (null when it declares none).
export function rootSceneMachines(tree: SceneTree): SceneMachines? {
    return tree.root.machines;
}

// The scene that declared `node` (its owner chain's first root holding
// machines: `node` itself when it is a scene's root), or null.
export function sceneMachinesFor(node: SceneNode): SceneMachines? {
    const own = node.machines;
    if (own != null) return own;
    let o = node.owner;
    while (o != null) {
        const sm = o.machines;
        if (sm != null) return sm;
        o = o.owner;
    }
    return null;
}

// The hint of an unknown machine: the scene's names.
export function stateMachineNamesHint(scene: SceneMachines?): string {
    if (scene == null || scene.machines.length == 0) return "the scene has no state machines";
    return "the scene's state machines are " + scene.names().join(", ");
}

// What runStateMachine did: the machine, the frames advanced (1/60 s
// each) and the seconds they make, each layer's state at the end
// ("Layer/State"), and the events its actions fired, in order.
export class StateMachineSample {
    name: string;
    frames: i32;
    seconds: f64;
    states: Array<string> = [];
    events: Array<string> = [];
    // Milestone 47: the listeners that performed (with a pointer script,
    // or an event or view model listener), in order.
    listeners: Array<ListenerFiring> = [];

    constructor(name: string, frames: i32) {
        this.name = name;
        this.frames = frames;
        this.seconds = <f64>frames / SAMPLE_FPS;
    }
}

// The tools' sink: the events fired, by name, in order; a view model
// trigger held and fired in the data at the next frame's start (`fireHeld`),
// as the run time holds it to the next frame's artboards phase, so that
// every layer sees it on the next frame as a run's would.
// Milestone 47: an event also fires its `<binding property="fire">`
// triggers (in the data context of the scene that fired it, held to the
// next frame as the machines' are) and reaches the machines' event
// listeners (`runner`).
class SampleSink extends SmEventSink {
    data: SmData?;
    events: Array<string> = [];
    runner: MachineRunner? = null;
    private heldPaths: Array<string> = [];
    private heldGlobals: Array<string> = [];

    constructor(data: SmData?) {
        super();
        this.data = data;
    }

    fireEvent(sceneRoot: SceneNode, name: string, decl: EventDecl?, delaySeconds: f32): void {
        this.events.push(name);
        if (decl != null) this.fireBindings(sceneRoot, decl);
        const r = this.runner;
        if (r != null) r.eventFired(sceneRoot, name);
    }

    // The event's fire bindings: each names a view model trigger, found as
    // a binding of the scene's root would find it (its data contexts'
    // candidates, innermost first; a global's path in the global alone):
    // the first candidate naming a property is the binding's, and fires
    // only when it is a trigger (the run time's FireBinding.resolve: a
    // property of another kind nearer in shadows a trigger further out).
    private fireBindings(sceneRoot: SceneNode, decl: EventDecl): void {
        const d = this.data;
        if (d == null) return;
        for (let i = 0; i < decl.bindings.length; i++) {
            const b = decl.bindings[i];
            if (b.property != EVENT_FIRE_PROPERTY || b.path.length == 0) continue;
            if (b.global.length > 0) {
                const g = d.global(b.global);
                if (g != null && g.kindOf(b.path) == VmKind.Trigger) this.fireTrigger(sceneRoot, b.path, b.global);
                continue;
            }
            const vm = d.values();
            if (vm == null) continue;
            const candidates = contextCandidates(sceneRoot, sceneRoot.sceneFile, b.path);
            for (let k = 0; k < candidates.length; k++) {
                const kind = vm.kindOf(candidates[k]);
                if (kind == VmKind.Other) continue;
                if (kind == VmKind.Trigger) this.fireTrigger(sceneRoot, candidates[k], "");
                break;
            }
        }
    }

    fireTrigger(sceneRoot: SceneNode, path: string, global: string): void {
        this.heldPaths.push(path);
        this.heldGlobals.push(global);
    }

    // The triggers held since the last frame, fired now.
    fireHeld(): void {
        const d = this.data;
        for (let i = 0; d != null && i < this.heldPaths.length; i++) {
            const global = this.heldGlobals[i];
            const vm = global.length > 0 ? d.global(global) : d.values();
            if (vm == null) continue;
            const t = vm.trigger(this.heldPaths[i]);
            if (t != null) t.fire();
        }
        this.heldPaths.length = 0;
        this.heldGlobals.length = 0;
    }
}

// What runStateMachine calls after each frame (milestone 35).
export abstract class SampleFrameHook {
    abstract afterFrame(frame: i32): void;
}

// The tools' sampling: the root scene's machine `name` ("" its
// default_state_machine's choice: the first it declares unless that names
// another or "-"), and every instanced scene's machine or instance_animation
// as the run time runs them, over `tree`, reading `data`, advanced `frames`
// times by 1/60 s, each frame settled; the tree is left at the last
// frame's values. With `scene`, that scene's machine `name` alone. An
// unknown name is STATE_MACHINE_UNKNOWN, its hint listing the scene's
// machines.
// Milestone 47: `pointer` (null: none) plays its steps into the machines'
// listeners, each after its frame's advances and before the next (a step
// at frame 0 before the first), picked in a picture of the script's size
// (1024 x 1024 when it gives none) through its camera (the scene's when it
// names none), planned again for each step (what moved is hit where it
// is), and the tree's collision objects synced first; the run lasts to the
// last step's frame + 1 when that is past `frames`. Every listener that
// performed (pointer, event and view model ones) is in the sample's
// `listeners`, with its frame. The scene's events fire their fire
// bindings' triggers (held to the next frame) and reach the event
// listeners.
// Milestone 35: `frameHook` (null: none) is called after each frame's
// advance and settle, with the frame's index: the CLI advances the scene's
// particles there by the frame's 1/60 s (../particles/clock.as), so a
// machine that keys `emitting` starts and stops the flow as in Play.
export function runStateMachine(tree: SceneTree, name: string, frames: i32, data: SmData?,
    scene: SceneMachines? = null, pointer: PointerInput? = null, frameHook: SampleFrameHook? = null): Result<StateMachineSample> {
    const root = rootSceneMachines(tree);
    const sm = scene != null ? scene : root;
    const choice = sm != null && name.length == 0 ? sm.defaultChoice() : name;
    const mi = sm != null ? sm.choose(choice) : -1;
    if (sm == null || (mi < 0 && choice != NO_STATE_MACHINE)) {
        const file = sm != null ? sm.file : tree.root.sceneFile;
        const what = name.length == 0 ? (choice.length == 0 ? "the scene has no state machines"
            : "the scene's default_state_machine \"" + choice + "\" names none of its state machines")
            : "the scene has no state machine \"" + name + "\"";
        return SceneryError.at(STATE_MACHINE_UNKNOWN, file, 0, 0, what, stateMachineNamesHint(sm)).fail<StateMachineSample>();
    }
    const runner = new MachineRunner(tree);
    runner.data = data;
    const sink = new SampleSink(data);
    sink.runner = runner;
    runner.events = sink;
    if (scene != null && scene !== root) runner.buildOne(scene.root, choice);
    else {
        runner.rootChoice = choice;
        runner.build(tree.root);
    }
    let total = frames;
    if (pointer != null && pointer.lastFrame() + 1 > total) total = pointer.lastFrame() + 1;
    const sample = new StateMachineSample(mi >= 0 ? sm.machines[mi].name : choice, total);
    const player = pointer != null ? new PointerPlayer(tree, pointer) : null;
    let step = 0;
    for (let f = 0; f < total; f++) {
        logFrame(runner, f);
        if (player != null) {
            const steps = player.script.steps;
            while (step < steps.length && steps[step].frame <= f) {
                const r = player.play(runner, steps[step]);
                if (!r.ok) return r.forward<StateMachineSample>();
                step++;
            }
            takeFired(runner, sample.listeners);
        }
        sink.fireHeld();
        runner.advance(<f32>(1.0 / SAMPLE_FPS));
        runner.settle();
        takeFired(runner, sample.listeners);
        if (frameHook != null) frameHook.afterFrame(f);
    }
    const inst = runner.instanceFor(sm.root);
    if (inst != null) sample.states = inst.currentStates();
    sample.events = sink.events;
    return Result.okv<StateMachineSample>(sample);
}

// Every instance of the runner logs its listeners at frame `f`.
function logFrame(runner: MachineRunner, f: i32): void {
    for (let i = 0; i < runner.slots.length; i++) {
        const s: MachineSlot = runner.slots[i];
        for (let k = 0; k < s.instances.length; k++) {
            const inst = s.instances[k];
            if (inst == null) continue;
            inst.listeners.logging = true;
            inst.listeners.frame = f;
        }
    }
}

// What the runner's machines' listeners performed since the last call,
// appended to `out` in slot order.
function takeFired(runner: MachineRunner, out: Array<ListenerFiring>): void {
    for (let i = 0; i < runner.slots.length; i++) {
        const s: MachineSlot = runner.slots[i];
        for (let k = 0; k < s.instances.length; k++) {
            const inst = s.instances[k];
            if (inst == null) continue;
            const fired = inst.listeners.takeFired();
            for (let j = 0; j < fired.length; j++) out.push(fired[j]);
        }
    }
}

// The tools' pointer: each step picked in a picture planned then (see
// runStateMachine).
class PointerPlayer {
    tree: SceneTree;
    script: PointerInput;
    cache: SceneRenderCache = new SceneRenderCache();
    picker: ListenerPicker = new ListenerPicker();
    hits: ListenerHits = new ListenerHits();
    groups: Array<SceneNode> = [];
    world: InteractionWorld? = null;

    constructor(tree: SceneTree, script: PointerInput) {
        this.tree = tree;
        this.script = script;
        const w = new InteractionWorld(tree);
        if (w.objects.length > 0) this.world = w;
    }

    play(runner: MachineRunner, step: PointerStep): Result<bool> {
        const opts = new SceneRenderOptions();
        const sc = this.script;
        opts.width = sc.width > 0 ? sc.width : 1024;
        opts.height = sc.height > 0 ? sc.height : 1024;
        // (null, a SceneRenderOptions' "no camera", or "": the scene's
        // current one)
        const cam = sc.camera;
        if (cam != null && cam.length > 0) opts.camera = cam;
        const r = buildSceneFrame(this.tree, opts, this.cache, null);
        if (!r.ok) return r.forward<bool>();
        const sf: SceneFrame = r.value;
        const w = this.world;
        if (w != null) w.update();
        runner.listenerTargets(this.groups);
        this.picker.pick(sf, step.x, step.y, w, this.groups, this.hits);
        runner.pointer(step.kind, step.pointerId, this.hits);
        return Result.okv<bool>(true);
    }
}

// ---------------------------------------------------------------------------
// What only the data shows (see the header)

// The data-time warnings of `tree`'s machines against `data` (the tools'
// SceneData: the scene's view model instance and the globals), each once,
// in tree order.
export function stateMachineDataDiagnostics(tree: SceneTree, data: SceneData): Array<Diagnostic> {
    const w = new DataWarnings(tree, data);
    const scenes = sceneMachinesOf(tree);
    for (let i = 0; i < scenes.length; i++) {
        const sm = scenes[i];
        for (let m = 0; m < sm.decls.length; m++) w.machine(sm, sm.decls[m]);
    }
    instancingWarnings(tree.root, w.out);
    w.eventBindings(tree.root);
    return w.out;
}

// The instancing nodes under `n` (and `n`) whose instance_state_machine or
// instance_animation names nothing of their instanced scene (the loader's
// warnings too: ../tree/instance.as).
export function instancingWarnings(n: SceneNode, out: Array<Diagnostic>): void {
    if (n.instancePath.length > 0) instancingWarningsOf(n, out);
    for (let i = 0; i < n.children.length; i++) instancingWarnings(n.children[i], out);
}

function instancingWarningsOf(n: SceneNode, out: Array<Diagnostic>): void {
    const owner = n.owner;
    const file = owner != null ? owner.sceneFile : n.sceneFile;
    const anim = propString(n, ANIMATION_PROPERTY, "");
    const sa = n.animations;
    const anims = sa != null && sa.root === n ? sa : null;
    if (anim.length > 0) {
        if (anims == null || anims.index(anim) < 0) {
            addOnce(out, new Diagnostic(Severity.Warning, "instance-animation-unknown", file, 0, 0,
                "\"" + n.name + "\" plays animation \"" + anim + "\" (instance_animation), which " + n.sceneFile + " does not have",
                anims != null && anims.animations.length > 0 ? "its animations: " + anims.names().join(", ") : n.sceneFile + " has no animations"));
        }
        return;
    }
    const choice = propString(n, STATE_MACHINE_PROPERTY, "");
    if (choice.length == 0 || choice == NO_STATE_MACHINE) return;
    const own = n.machines;
    const sm = own != null && own.root === n ? own : null;
    if (sm == null || sm.index(choice) < 0) {
        addOnce(out, new Diagnostic(Severity.Warning, "instance-state-machine-unknown", file, 0, 0,
            "\"" + n.name + "\" runs state machine \"" + choice + "\" (instance_state_machine), which " + n.sceneFile + " does not have",
            stateMachineNamesHint(sm)));
    }
}

function addOnce(out: Array<Diagnostic>, d: Diagnostic): void {
    for (let i = 0; i < out.length; i++) {
        const e = out[i];
        if (e.code == d.code && e.file == d.file && e.line == d.line && e.col == d.col && e.message == d.message) return;
    }
    out.push(d);
}

// What a path resolved to in the tools' data.
class Found {
    schema: MemoryViewModel? = null;
    path: string = "";
    kind: VmKind = VmKind.Other;
    // The converter's output kind (the kind when none is named; Other when
    // it could not be built: warned).
    outKind: VmKind = VmKind.Other;
    ok: bool = false;
}

class DataWarnings {
    tree: SceneTree;
    data: SceneData;
    out: Array<Diagnostic> = [];
    sm: SceneMachines? = null;
    machineName: string = "";
    // The scene the paths are looked for from (its root and file): the
    // machine's, or the scene whose events are checked.
    root: SceneNode? = null;
    file: string = "";

    constructor(tree: SceneTree, data: SceneData) {
        this.tree = tree;
        this.data = data;
    }

    machine(sm: SceneMachines, d: StateMachineDecl): void {
        this.sm = sm;
        this.machineName = d.name;
        this.root = sm.root;
        this.file = sm.file;
        this.listeners(sm, d);
        for (let i = 0; i < d.inputs.length; i++) {
            const inp = d.inputs[i];
            for (let b = 0; b < inp.bindings.length; b++) {
                const bd = inp.bindings[b];
                if (bd.property != "value" || bd.path.length == 0) continue;
                const where = "input \"" + inp.name + "\" of state machine \"" + d.name + "\"";
                const f = this.find(bd.path, bd.global, bd.converter, bd.pos, INPUT_BINDING_PATH_UNKNOWN_CODE, where);
                if (!f.ok) continue;
                const k = f.outKind;
                let fits: bool;
                if (inp.kind == InputKind.Trigger) fits = f.kind == VmKind.Trigger;
                else if (inp.kind == InputKind.Number) fits = k == VmKind.Number || k == VmKind.Boolean || k == VmKind.Enum;
                else fits = k == VmKind.Boolean || k == VmKind.Number;
                if (!fits) {
                    this.warn(INPUT_BINDING_TYPE_CODE, bd.pos, where + " follows \"" + bd.path + "\", " + article(vmKindName(f.kind))
                        + " property", "a number input follows a number (or a boolean), a boolean input a boolean (or a number), "
                        + "a trigger input a trigger");
                }
            }
        }
        for (let l = 0; l < d.layers.length; l++) {
            const layer = d.layers[l];
            for (let s = 0; s < layer.states.length; s++) {
                const st = layer.states[s];
                const sname = "state \"" + st.displayName() + "\" of layer \"" + layer.name + "\" (state machine \"" + d.name + "\")";
                if (st.kind == StateKind.Blend1DViewModel && st.path.length > 0) {
                    this.blendPath(st.path, st.global, st.converter, st.pos, sname);
                }
                for (let b = 0; b < st.blends.length; b++) {
                    const bd = st.blends[b];
                    if (bd.direct && bd.path.length > 0 && bd.input.length == 0) {
                        this.blendPath(bd.path, bd.global, bd.converter, bd.pos, "animation \"" + bd.animation + "\" of " + sname);
                    }
                }
                for (let a = 0; a < st.actions.length; a++) {
                    const ad = st.actions[a];
                    this.action(ad.path, ad.global, ad.kind == ActionKind.FireTrigger, ad.pos, sname);
                }
                for (let t = 0; t < st.transitions.length; t++) {
                    const tr = st.transitions[t];
                    const tname = "the transition " + st.displayName() + " > " + tr.to + " of layer \"" + layer.name + "\" (state machine \""
                        + d.name + "\")";
                    for (let c = 0; c < tr.conditions.length; c++) this.condition(tr.conditions[c], tname);
                    for (let a = 0; a < tr.actions.length; a++) {
                        const ad = tr.actions[a];
                        this.action(ad.path, ad.global, ad.kind == ActionKind.FireTrigger, ad.pos, tname);
                    }
                }
            }
        }
    }

    private blendPath(path: string, global: string, converter: string, pos: XmlPos, where: string): void {
        const f = this.find(path, global, converter, pos, BLEND_PATH_UNKNOWN_CODE, where);
        if (!f.ok || f.outKind == VmKind.Number) return;
        this.warn("blend-type", pos, where + " blends by \"" + path + "\", " + article(vmKindName(f.outKind)) + " property",
            "a blend reads a number (0 to 100, Rive's scale); a converter turns another kind into one");
    }

    private action(path: string, global: string, trigger: bool, pos: XmlPos, where: string): void {
        if (!trigger || path.length == 0) return;
        const f = this.find(path, global, "", pos, TRIGGER_PATH_UNKNOWN_CODE, where);
        if (!f.ok || f.kind == VmKind.Trigger) return;
        const schema = f.schema;
        const paths = schema != null ? schema.schema.triggerPaths() : new Array<string>();
        this.warn(TRIGGER_PATH_UNKNOWN_CODE, pos, where + " fires \"" + path + "\", " + article(vmKindName(f.kind)) + " property",
            "a fire action fires a view model trigger; the triggers: " + (paths.length > 0 ? paths.join(", ") : "none"));
    }

    private condition(c: ConditionDecl, where: string): void {
        const what = CONDITION_ELEMENTS[<i32>c.kind] + " of " + where;
        if (c.kind != ConditionKind.ViewModel && c.kind != ConditionKind.Component) return;
        let leftKind = VmKind.Other;
        if (c.kind == ConditionKind.ViewModel) {
            const f = this.find(c.path, c.global, c.converter, c.pos, CONDITION_PATH_UNKNOWN_CODE, what);
            if (!f.ok) return;
            if (f.kind == VmKind.Trigger) {
                if (c.hasValue || c.rightPath.length > 0) {
                    this.warn(CONDITION_TYPE_CODE, c.pos, what + " compares \"" + c.path + "\", a trigger, with a value",
                        "a condition on a trigger takes no value: it passes when the trigger fired");
                }
                return;
            }
            leftKind = f.outKind;
        } else {
            const sm = this.sm as SceneMachines;
            const node = c.target.length == 0 || c.target == "." ? sm.root : sm.root.getNode(c.target);
            if (node == null) return;
            // (a shader parameter of its kind: the node's material says)
            const t = nodeBindingTarget(node, c.property);
            if (t == null) return;
            leftKind = vmKindOfBind(t.kind);
        }
        if (!comparableKind(leftKind)) {
            this.warn(CONDITION_TYPE_CODE, c.pos, what + " compares " + article(vmKindName(leftKind)) + " value",
                "a condition compares a number, a boolean, a color, a string or an enum");
            return;
        }
        if (leftKind != VmKind.Number && c.op != ConditionOp.Equal && c.op != ConditionOp.NotEqual) {
            this.warn(CONDITION_TYPE_CODE, c.pos, what + " compares " + article(vmKindName(leftKind)) + " value with "
                + CONDITION_OP_NAMES[<i32>c.op], "only numbers compare with " + CONDITION_OP_NAMES[<i32>c.op]
                + "; " + vmKindName(leftKind) + "s take equal and notEqual");
            return;
        }
        if (c.rightPath.length > 0) {
            const r = this.find(c.rightPath, c.rightGlobal, c.rightConverter, c.pos, CONDITION_PATH_UNKNOWN_CODE, what);
            if (!r.ok) return;
            if (r.outKind != leftKind) {
                this.warn(CONDITION_TYPE_CODE, c.pos, what + " compares " + article(vmKindName(leftKind)) + " with \"" + c.rightPath + "\", "
                    + article(vmKindName(r.outKind)), "the two sides of a condition are of one kind (a converter turns one into the other)");
            }
            return;
        }
        if (!c.hasValue) {
            // (the reader cannot tell a trigger, which takes no value, from
            // the rest: the data can, and such a condition never passes)
            if (c.kind == ConditionKind.ViewModel) {
                this.warn("condition-value-missing", c.pos, what + " compares \"" + c.path + "\", "
                    + article(vmKindName(leftKind)) + " property, with nothing", "give it a value=\"...\" or a "
                    + "rightPath=\"...\" (only a condition on a trigger takes none)");
            }
            return;
        }
        const lit = new BoundValue();
        if (!parseLiteral(leftKind, c.value, lit)) {
            this.warn(CONDITION_TYPE_CODE, c.pos, what + " compares " + article(vmKindName(leftKind)) + " with \"" + c.value
                + "\", which is not one", literalHint(leftKind));
        }
    }

    // `path` in the data (a global's, or the scene's through its data
    // contexts), its converter built; null and `code`'s warning (or the
    // global's, or the converter's) when it names nothing.
    private find(path: string, global: string, converter: string, pos: XmlPos, code: string, where: string,
        globalCode: string = "", converterCode: string = ""): Found {
        const out = new Found();
        let vm: MemoryViewModel?;
        if (global.length > 0) {
            vm = this.data.global(global);
            if (vm == null) {
                const names = new Array<string>();
                for (let i = 0; i < this.data.globals.length; i++) names.push(this.data.globals[i].schema.name);
                const src = this.data.source;
                const gcode = globalCode.length > 0 ? globalCode
                    : (code == CONDITION_PATH_UNKNOWN_CODE ? CONDITION_GLOBAL_UNKNOWN_CODE : code);
                this.warn(gcode, pos, where + " reads \"" + path
                    + "\" of the global view model \"" + global + "\", which the scene's data does not have",
                    names.length > 0 ? "its global view models: " + names.join(", ")
                        : (src != null ? (src as DataSource).label + " declares no global view model" : "the scene has no data"));
                return out;
            }
        } else {
            vm = this.data.root;
            if (vm == null) {
                this.warn(code, pos, where + " reads \"" + path + "\", but the scene has no view model",
                    "set the scene root's view_model to a ViewModel sub_resource; see docs/engine/STATE_MACHINES.md");
                return out;
            }
        }
        const values = vm as MemoryViewModel;
        const candidates = global.length > 0 ? [path] : contextCandidates(this.root as SceneNode, this.file, path);
        for (let i = 0; i < candidates.length; i++) {
            const k = values.kindOf(candidates[i]);
            if (k == VmKind.Other) continue;
            out.schema = values;
            out.path = candidates[i];
            out.kind = k;
            out.outKind = k;
            out.ok = true;
            break;
        }
        if (!out.ok) {
            const innermost = candidates[0].substring(0, candidates[0].length - path.length);
            const named = global.length > 0 ? "the global view model " + global : "the view model " + values.schema.name;
            const paths = values.schema.pathsUnder(innermost);
            const triggers = values.schema.triggerPaths();
            const all = new Array<string>();
            for (let i = 0; i < paths.length; i++) all.push(paths[i]);
            for (let i = 0; i < triggers.length; i++) {
                if (triggers[i].startsWith(innermost)) all.push(triggers[i].substring(innermost.length));
            }
            this.warn(code, pos, named + " has no property at \"" + path + "\""
                + (innermost.length > 0 ? " (in the data context \"" + innermost.substring(0, innermost.length - 1) + "\" or above it, "
                    + where + ")" : " (" + where + ")"), "its paths: " + (all.length > 0 ? all.join(", ") : "none"));
            return out;
        }
        if (converter.length > 0) {
            const sm = this.sm as SceneMachines;
            const problem = new ConverterProblem();
            const c = buildNamedConverter(converter, sm.converterLookup(this.tree), problem);
            if (c == null) {
                const pc = problem.code.length > 0 ? problem.code : "binding-converter-unknown";
                const ccode = converterCode.length > 0 ? converterCode
                    : (pc.startsWith("binding-") ? "condition-" + pc.substring(8) : pc);
                const lookup = sm.converterLookup(this.tree);
                const names = lookup.names();
                this.warn(ccode, pos, where + " reads \"" + path + "\" through the converter \"" + converter + "\": "
                    + (problem.message.length > 0 ? problem.message : "no converter of that name"),
                    problem.hint.length > 0 ? problem.hint : (names.length > 0 ? "the scene's converters: " + names.join(", ")
                        : "declare it in the scene or in the project's data"));
                out.ok = false;
                return out;
            }
            c.bind(values);
            out.outKind = c.outputKind(out.kind);
        }
        return out;
    }

    private warn(code: string, pos: XmlPos, message: string, hint: string): void {
        addOnce(this.out, new Diagnostic(Severity.Warning, code, this.file, pos.line, pos.col, message, hint));
    }

    // --- milestone 47: listeners and event bindings (see the header) -----

    private listeners(sm: SceneMachines, d: StateMachineDecl): void {
        for (let i = 0; i < d.listeners.length; i++) {
            const ld = d.listeners[i];
            const where = "listener \"" + ld.name + "\" of state machine \"" + d.name + "\"";
            if (ld.type != ListenerType.ViewModel) {
                this.loadTarget(sm, ld.target, ld.pos, where + " targets", LISTENER_TARGET_UNKNOWN_CODE);
            }
            if (ld.type == ListenerType.Event && ld.event.length > 0) this.loadEvent(sm, ld, where);
            if (ld.type == ListenerType.ViewModel && ld.path.length > 0) {
                this.find(ld.path, ld.global, "", ld.pos, LISTENER_PATH_UNKNOWN_CODE, where, LISTENER_PATH_UNKNOWN_CODE);
            }
            for (let k = 0; k < ld.actions.length; k++) {
                const a = ld.actions[k];
                const aw = "action " + (k + 1).toString() + " of " + where;
                if (a.kind == ListenerActionKind.AlignTarget) this.loadTarget(sm, a.target, a.pos, aw + " aligns", LISTENER_ACTION_TARGET_UNKNOWN_CODE);
                else if (a.kind == ListenerActionKind.ViewModelChange) this.viewModelChange(a, aw);
            }
        }
    }

    // A path into an instanced scene that names no node (the file's own
    // paths are the validator's: listener-target-unknown, an error).
    private loadTarget(sm: SceneMachines, path: string, pos: XmlPos, what: string, code: string): void {
        if (path.length == 0 || path == ".") return;
        if (sm.root.getNode(path) != null) return;
        // (the longest leading part that names a node: an instanced
        // scene's root, or the path is the file's to check)
        const segs = path.split("/");
        let at: SceneNode? = sm.root;
        let instanced = false;
        for (let i = 0; i < segs.length - 1 && at != null; i++) {
            at = at.child(segs[i]);
            if (at != null && at.instancePath.length > 0) instanced = true;
        }
        if (!instanced) return;
        this.warn(code, pos, what + " \"" + path + "\", which names no node of the scene it instances",
            "a path into an instanced scene goes through its instancing node: \"Door/Hinge/Panel\"");
    }

    // An event no scene the listener hears declares, when the scene
    // instances others.
    private loadEvent(sm: SceneMachines, ld: ListenerDecl, where: string): void {
        if (!instancesAny(sm.root)) return;
        const scope = ld.target.length == 0 ? sm.root : (ld.target == "." ? sm.root : sm.root.getNode(ld.target));
        if (scope == null) return;
        const names = new Array<string>();
        eventNamesUnder(scope, names);
        if (names.includes(ld.event)) return;
        this.warn(LISTENER_EVENT_UNKNOWN_LOAD_CODE, ld.pos, where + " hears event \"" + ld.event + "\", which no scene it hears declares",
            names.length > 0 ? "the events it can hear: " + names.join(", ") : "the scenes it hears declare no events");
    }

    private viewModelChange(a: ListenerActionDecl, where: string): void {
        if (a.path.length == 0) return;
        const to = this.find(a.path, a.global, "", a.pos, LISTENER_ACTION_PATH_UNKNOWN_CODE, where,
            LISTENER_ACTION_GLOBAL_UNKNOWN_CODE, LISTENER_ACTION_CONVERTER_UNKNOWN_CODE);
        if (!to.ok || to.kind == VmKind.Trigger) return;
        const target = to.kind;
        let source = VmKind.Other;
        if (a.fromPath.length > 0) {
            const from = this.find(a.fromPath, a.fromGlobal, a.converter, a.pos, LISTENER_ACTION_PATH_UNKNOWN_CODE, where,
                LISTENER_ACTION_GLOBAL_UNKNOWN_CODE, LISTENER_ACTION_CONVERTER_UNKNOWN_CODE);
            if (!from.ok) return;
            source = from.outKind;
        } else if (a.input.length > 0) {
            source = this.converted(a, VmKind.Number, where);
            if (source == VmKind.Other && a.converter.length > 0) return;
        } else if (a.hasValue) {
            if (a.converter.length == 0) {
                const lit = new BoundValue();
                if (!parseLiteral(target, a.value, lit)) {
                    this.warn(LISTENER_ACTION_TYPE_CODE, a.pos, where + " writes \"" + a.value + "\" to \"" + a.path + "\", "
                        + article(vmKindName(target)) + " property", literalHint(target));
                }
                return;
            }
            const lk = a.value == "true" || a.value == "false" ? VmKind.Boolean
                : (a.value.length > 0 && isFinite(parseFloat(a.value)) ? VmKind.Number : VmKind.String);
            source = this.converted(a, lk, where);
            if (source == VmKind.Other) return;
        } else {
            this.warn(LISTENER_ACTION_TYPE_CODE, a.pos, where + " writes nothing to \"" + a.path + "\", "
                + article(vmKindName(target)) + " property", "give it a value=\"...\", a fromPath=\"...\" or an input=\"...\" "
                + "(only a trigger takes none: it is fired)");
            return;
        }
        if (writable(source, target)) return;
        this.warn(LISTENER_ACTION_TYPE_CODE, a.pos, where + " writes " + article(vmKindName(source)) + " to \"" + a.path + "\", "
            + article(vmKindName(target)) + " property", "a property takes a value of its kind (a number also goes to a "
            + "boolean or an enum, a string to an enum); a converter turns one kind into another");
    }

    // The kind a literal or a pointer input of kind `k` has after the
    // action's converter (Other, warned, when it cannot be built).
    private converted(a: ListenerActionDecl, k: VmKind, where: string): VmKind {
        if (a.converter.length == 0) return k;
        const sm = this.sm as SceneMachines;
        const problem = new ConverterProblem();
        const lookup = sm.converterLookup(this.tree);
        const c = buildNamedConverter(a.converter, lookup, problem);
        if (c == null) {
            const names = lookup.names();
            this.warn(LISTENER_ACTION_CONVERTER_UNKNOWN_CODE, a.pos, where + " writes through the converter \"" + a.converter + "\": "
                + (problem.message.length > 0 ? problem.message : "no converter of that name"),
                problem.hint.length > 0 ? problem.hint : (names.length > 0 ? "the scene's converters: " + names.join(", ")
                    : "declare it in the scene or in the project's data"));
            return VmKind.Other;
        }
        return c.outputKind(k);
    }

    // Every scene's events' fire bindings under `n` (n's own first).
    eventBindings(n: SceneNode): void {
        const sa = n.animations;
        if (sa != null && sa.root === n) {
            this.sm = null;
            this.root = n;
            this.file = sa.file;
            for (let i = 0; i < sa.events.length; i++) {
                const e = sa.events[i];
                for (let b = 0; b < e.bindings.length; b++) {
                    const bd = e.bindings[b];
                    if (bd.property != EVENT_FIRE_PROPERTY || bd.path.length == 0) continue;
                    const where = "event \"" + e.name + "\"";
                    const f = this.find(bd.path, bd.global, "", bd.pos, EVENT_BINDING_PATH_UNKNOWN_CODE, where,
                        EVENT_BINDING_PATH_UNKNOWN_CODE);
                    if (!f.ok || f.kind == VmKind.Trigger) continue;
                    const schema = f.schema;
                    const paths = schema != null ? schema.schema.triggerPaths() : new Array<string>();
                    this.warn(EVENT_BINDING_TYPE_CODE, bd.pos, where + " fires \"" + bd.path + "\", " + article(vmKindName(f.kind))
                        + " property", "an event's fire binding names a view model trigger; the triggers: "
                        + (paths.length > 0 ? paths.join(", ") : "none"));
                }
            }
        }
        for (let i = 0; i < n.children.length; i++) this.eventBindings(n.children[i]);
    }
}

// Whether a value of kind `from` can be written to a property of kind `to`
// (ViewModelValues.write: a number also to a boolean or an enum, a string
// to an enum).
function writable(from: VmKind, to: VmKind): bool {
    if (from == to) return from != VmKind.Other;
    if (from == VmKind.Number) return to == VmKind.Boolean || to == VmKind.Enum;
    return from == VmKind.String && to == VmKind.Enum;
}

// Whether a node under `root` (or `root`) instances a scene.
function instancesAny(root: SceneNode): bool {
    for (let i = 0; i < root.children.length; i++) {
        const c = root.children[i];
        if (c.instancePath.length > 0 || instancesAny(c)) return true;
    }
    return false;
}

// The events of the scenes rooted at `n` or under it, each name once.
function eventNamesUnder(n: SceneNode, out: Array<string>): void {
    const sa = n.animations;
    if (sa != null && sa.root === n) {
        for (let i = 0; i < sa.events.length; i++) if (!out.includes(sa.events[i].name)) out.push(sa.events[i].name);
    }
    for (let i = 0; i < n.children.length; i++) eventNamesUnder(n.children[i], out);
}

// The kind of value a node property of bind kind `k` reads as.
function vmKindOfBind(k: BindKind): VmKind {
    switch (k) {
        case BindKind.Number: return VmKind.Number;
        case BindKind.Boolean: return VmKind.Boolean;
        case BindKind.Color: return VmKind.Color;
        case BindKind.String: return VmKind.String;
        case BindKind.Enum: return VmKind.Enum;
        default: return VmKind.Other;
    }
}

function article(word: string): string {
    if (word.length == 0) return word;
    const c = word.charCodeAt(0);
    const vowel = c == 0x61 || c == 0x65 || c == 0x69 || c == 0x6f || c == 0x75;
    return (vowel ? "an " : "a ") + word;
}

function literalHint(k: VmKind): string {
    if (k == VmKind.Number) return "a number condition's value is a number: 80, -0.5";
    if (k == VmKind.Boolean) return "a boolean condition's value is true, false, 1 or 0";
    if (k == VmKind.Color) return "a color condition's value is 8 hex digits of ARGB (FF57A5E0) or 6 of RGB";
    return "the value is read as the property's kind";
}
