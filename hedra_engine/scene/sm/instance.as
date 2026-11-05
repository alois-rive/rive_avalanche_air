// One running state machine of one scene (docs/plans/RIVE_MODEL.md
// sections 1.5, 3.3 and 5): the port of rive-runtime's StateMachineInstance
// and StateMachineLayerInstance (src/animation/state_machine_instance.cpp),
// with animation_state_instance.cpp, blend_state_1d_instance.cpp,
// blend_state_direct_instance.cpp, state_transition.cpp (exitTimeSeconds,
// mixTime, allowed, applyExitCondition), the conditions
// (transition_*_condition.cpp and the view model condition's comparisons)
// and animation_reset_factory.cpp. Its states' animations are its scene's
// (../anim/scene_anims.as SceneAnimations), applied onto the scene's nodes in
// its tree with their mixes, a later layer over an earlier one.
//
// Each layer, every advance, as Rive's:
//
//   1. the current state advances (an animation by the seconds times the
//      state's speed; a blend's animations by the seconds, Rive's blend
//      states ignoring their speed), the transition's mix moves on (its
//      duration in ms, or in % of the from state's animation), and the
//      state mixed out of advances too while it mixes, unless the
//      transition paused it on exit;
//   2. apply: the values the transition started from (Rive's
//      AnimationReset: each number or colour the two animations key, read
//      when the transition began), the held exit frame of the state left,
//      the from state at the mix it had when the transition began, then
//      the current state at the mix, both through the transition's
//      interpolator when it has one;
//   3. state changes are tried until none is allowed, at most TRY_CHANGE_MAX
//      times, each one applied: Any State's transitions first, then the
//      current state's, in order (by their random weights for a state
//      marked random), the first allowed one taken. A transition is allowed
//      when it is not disabled, every condition passes and, with an exit
//      time, the from animation has reached it in its current loop; while a
//      transition with a duration mixes, no other is tried unless it
//      enables early exit.
//
// A state change fires the left state's actions at its end, the new
// state's at its start, then the transition's at its start (and at its end
// at once when it has no duration, else when the mix reaches 1). Entering a
// state starts its animations again from their start (Rive makes a new
// state instance; here each state's instance is made once and reset). The
// Exit state holds nothing and plays nothing: the layer has ended (Any
// State's transitions can still leave it, as in Rive).
//
// Inputs (Rive's StateMachineNumber, Bool and Trigger): an input with a
// `<binding property="value">` follows its view model property, read at
// the start of each advance and of each settle's try (Rive's
// updateDataBinds). A trigger input fired is seen by each layer's trigger
// conditions until a transition of that layer uses it, and is spent at the
// end of the advance (Rive's SMITrigger: useInLayer, advanced). A view
// model trigger is the same: its condition passes when it fired since the
// end of the last advance and no transition of the layer used that firing.
//
// `random`: Rive draws from its RandomProvider; here a 32-bit linear
// congruential generator (Numerical Recipes' 1664525 and 1013904223)
// seeded with `seed` (RANDOM_SEED unless set) and started again by
// reset(), so that a machine runs the same way every time, in the tools,
// the editor and a baked project alike.
//
// The same object runs everywhere: the run time (../runtime/
// feature_animation.as, through ./runner.as), the tools (`the CLI render
// --state-machine`, `inspect --state-machine --frame`: ./scene_machines.as
// runStateMachine) and the editor's Play. Conditions and blend numbers read
// `data` (./data.as, ./resolve.as); fired events and triggers go to
// `events`.
//
// Memory: everything an advance uses is made with the instance (a state's
// animation instances, the layers' reset buffers sized for the largest
// transition, the random weights) or on the first advance after data is
// given (each path resolved, each converter built), so that an advance
// after the first allocates nothing but what its animations' writes do
// (../anim/scene_anims.as says which) and a literal read once its left
// side's kind is known; currentStates (which makes strings) is for the
// tools and the status, not for frames.

import { SceneNode } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { EventDecl, LinearAnimationDecl, LoopMode } from "../anim/decl";
import { LinearAnimation, prepareAnimation } from "../anim/animation";
import { CallbackSink, LinearAnimationInstance } from "../anim/instance";
import { SceneAnimations, flushQuaternions } from "../anim/scene_anims";
import { BoundValue, ViewModelValues } from "../binding/values";
import { BindingTarget } from "../binding/targets";
import { nodeBindingTarget } from "../binding/shader_targets";
import { readTarget } from "../binding/apply";
import { OutputView } from "../binding/outputs";
import { VmKind } from "../riv/riv_info";
import { ActionKind, BlendSource, ConditionKind, ConditionOp, InputKind, OCCURS_AT_END, OCCURS_AT_START, StateKind } from "./decl";
import { SmAction, SmCondition, SmLayer, SmState, SmTransition, StateMachine } from "./machine";
import { SmData } from "./data";
import { SceneMachines } from "./scene_machines";
import { PATH_FOUND, PathRun, compareNumbers, compareValues, parseLiteral, valuesFor } from "./resolve";
import { ListenerRun } from "./listeners";

// How many times a layer may change state in one advance (Rive's
// StateMachineLayerInstance: maxIterations 100), and how many times the
// settle pass tries state changes again with no time (Rive's
// advanceAndApply: 5).
export const TRY_CHANGE_MAX: i32 = 100;
export const SETTLE_MAX: i32 = 5;

// The random generator's start (see the header).
export const RANDOM_SEED: u32 = 0x2545F491;

// Where a machine's actions go: the scene's Event `name` fired (`decl` its
// declaration; delaySeconds into the frame, as a timeline's callbacks), a
// view model trigger fired (`path` in the scene's data, its data context's
// prefix included, as the machine resolved it; or in the global `global`).
export abstract class SmEventSink {
    abstract fireEvent(sceneRoot: SceneNode, name: string, decl: EventDecl?, delaySeconds: f32): void;
    abstract fireTrigger(sceneRoot: SceneNode, path: string, global: string): void;

    // A state's animation crossed a `signal:<name>` key of `node` (the
    // run time makes the node emit it; the tools and the editor ignore it).
    emitKeyed(node: SceneNode, signal: string): void {}
}

// What allowed() answers (Rive's AllowTransition).
const ALLOW_NO: i32 = 0;
const ALLOW_YES: i32 = 1;
const ALLOW_WAITING: i32 = 2;

// The animation a state without one runs (Rive's emptyAnimation: 60
// frames at 60 fps, one shot, no keys): an exit time still counts on it.
let emptyAnimation: LinearAnimation? = null;

function theEmptyAnimation(): LinearAnimation {
    const had = emptyAnimation;
    if (had != null) return had;
    const d = new LinearAnimationDecl("");
    d.loop = LoopMode.OneShot;
    const e = prepareAnimation(d);
    emptyAnimation = e;
    return e;
}

// One property a reset writes back (Rive's AnimationReset entry): which
// track it was read through, and the value.
class ResetEntry {
    animation: i32 = -1;
    object: i32 = -1;
    track: i32 = -1;
    node: SceneNode? = null;
    property: string = "";
    value: BoundValue = new BoundValue();
}

// A reset's entries, in place (sized when the instance is made; a larger
// one than foreseen grows it).
class ResetBuffer {
    entries: Array<ResetEntry> = [];
    count: i32 = 0;

    constructor(capacity: i32) {
        for (let i = 0; i < capacity; i++) this.entries.push(new ResetEntry());
    }

    clear(): void {
        this.count = 0;
    }

    // Whether `node`'s `property` has an entry already.
    has(node: SceneNode, property: string): bool {
        for (let i = 0; i < this.count; i++) {
            const e = unchecked(this.entries[i]);
            if (e.node === node && e.property == property) return true;
        }
        return false;
    }

    take(): ResetEntry {
        if (this.count == this.entries.length) this.entries.push(new ResetEntry());
        return unchecked(this.entries[this.count++]);
    }
}

// One state of one layer, as the instance runs it (Rive's StateInstance:
// AnimationStateInstance, BlendState1DInstance, BlendStateDirectInstance,
// SystemStateInstance), made once and reset when the state is entered.
class StateRun {
    state: SmState;
    index: i32;
    // Per animation (an AnimationState's one, a blend's each), its instance
    // (null: a blend's animation that resolved to none) and its index in
    // the scene's animations (-1: none, applied nowhere).
    insts: Array<LinearAnimationInstance?> = [];
    anims: StaticArray<i32>;
    // A blend's mix of each animation (0 to 1).
    mixes: StaticArray<f32>;
    keepGoing: bool = true;
    // A 1D blend marked reset: the values its animations start from.
    reset: ResetBuffer? = null;

    constructor(state: SmState, index: i32, scene: SceneAnimations?) {
        this.state = state;
        this.index = index;
        const n = state.kind == StateKind.Animation ? 1 : state.blends.length;
        this.anims = new StaticArray<i32>(n);
        this.mixes = new StaticArray<f32>(n);
        if (state.kind == StateKind.Animation) {
            const ai = state.animations.length > 0 ? state.animations[0] : -1;
            const a = scene != null && ai >= 0 && ai < scene.animations.length ? scene.animations[ai] : null;
            this.anims[0] = a != null ? ai : -1;
            this.insts.push(new LinearAnimationInstance(a != null ? a : theEmptyAnimation(), state.speed));
        } else {
            for (let i = 0; i < n; i++) {
                const ai = state.blends[i].animation;
                const a = scene != null && ai >= 0 && ai < scene.animations.length ? scene.animations[ai] : null;
                this.anims[i] = a != null ? ai : -1;
                this.insts.push(a != null ? new LinearAnimationInstance(a) : null);
            }
        }
    }

    get isAnimation(): bool {
        return this.state.kind == StateKind.Animation;
    }

    // An AnimationState's instance (null for any other state).
    get animationInstance(): LinearAnimationInstance? {
        return this.state.kind == StateKind.Animation ? unchecked(this.insts[0]) : null;
    }
}

// One layer, as the instance runs it (Rive's StateMachineLayerInstance).
class LayerRun {
    layer: SmLayer;
    index: i32;
    states: Array<StateRun> = [];
    current: StateRun? = null;
    from: StateRun? = null;
    transition: SmTransition? = null;
    mix: f32 = 1;
    mixFrom: f32 = 1;
    // The animation to apply once more at holdTime and mixFrom (the exit
    // frame of the state left: Rive's m_holdAnimation), -1 none.
    holdAnimation: i32 = -1;
    holdTime: f32 = 0;
    transitionCompleted: bool = false;
    holdAnimationFrom: bool = false;
    changedOnAdvance: bool = false;
    waitingForExit: bool = false;
    // The transition's reset (Rive's AnimationReset), on while it mixes.
    reset: ResetBuffer;
    resetOn: bool = false;
    // The random weights of the transitions tried (Rive keeps them on the
    // transitions; here per instance).
    weights: StaticArray<u32>;

    constructor(layer: SmLayer, index: i32, resetCapacity: i32) {
        this.layer = layer;
        this.index = index;
        this.reset = new ResetBuffer(resetCapacity);
        let most = layer.maxTransitions;
        if (layer.anyTransitions.length > most) most = layer.anyTransitions.length;
        this.weights = new StaticArray<u32>(most);
    }
}

// Where a state's animation reports its callback keys: the scene's events
// and nodes' signals, to the instance's sink.
class StateCallbacks extends CallbackSink {
    owner: StateMachineInstance;
    // The animation advanced now (an index into the scene's).
    index: i32 = -1;

    constructor(owner: StateMachineInstance) {
        super();
        this.owner = owner;
    }

    callback(objectIndex: i32, trackIndex: i32, delaySeconds: f32): void {
        const sa = this.owner.animations;
        const sink = this.owner.events;
        if (sa == null || sink == null || this.index < 0) return;
        const t = sa.trackTarget(this.index, objectIndex, trackIndex);
        if (t == null) return;
        const ev = t.event;
        if (ev != null) {
            sink.fireEvent(sa.root, ev.name, ev, delaySeconds);
            return;
        }
        if (t.signal.length == 0) return;
        const node = sa.targetNode(this.index, objectIndex);
        if (node != null) sink.emitKeyed(node, t.signal);
    }
}

// A component condition's node and property, found once.
class ComponentRun {
    looked: bool = false;
    node: SceneNode? = null;
    target: BindingTarget? = null;
    value: BoundValue = new BoundValue();
}

// One condition's literal, read once its left side's kind is known.
class LiteralRun {
    kind: VmKind = VmKind.Other;
    ok: bool = false;
    value: BoundValue = new BoundValue();
}

export class StateMachineInstance {
    machine: StateMachine;
    scene: SceneMachines;
    tree: SceneTree;
    // Where conditions and blend numbers are read, and fire actions'
    // triggers fired (null: no data; a view model condition is then false).
    data: SmData? = null;
    events: SmEventSink? = null;
    // What a component condition on a screen output projects through
    // (null: the outputs read nothing; the run time sets its view).
    view: OutputView? = null;
    // The instancing node's instance_speed and instance_paused (the root
    // scene's: 1 and false): an advance's seconds are multiplied by speed;
    // paused, an advance does nothing.
    speed: f32 = 1;
    paused: bool = false;
    // Bumped on every state change (a status's stamp, the editor's lit
    // states).
    stateChanges: i64 = 0;
    // The random generator's seed (see the header); reset() starts it
    // again from here.
    seed: u32 = RANDOM_SEED;
    // The inputs' values, by the machine's inputs' indices: a number's in
    // `numbers`, a boolean's in `booleans`; a trigger's `booleans` entry
    // says whether it was fired and not yet spent, its `numbers` entry how
    // many times it was fired since the last reset.
    numbers: StaticArray<f64>;
    booleans: StaticArray<bool>;
    // The scene's timelines (null: none; every state then plays nothing).
    animations: SceneAnimations? = null;
    // Milestone 47: its listeners (./listeners.as), made with it.
    listeners: ListenerRun;
    private layers: Array<LayerRun> = [];
    private random: u32 = RANDOM_SEED;
    // Per view model path the machine names (StateMachine.paths), how this
    // instance reads it; per condition, its literal and its node.
    private paths: Array<PathRun> = [];
    private literals: Array<LiteralRun> = [];
    private components: Array<ComponentRun> = [];
    // A trigger input used by a layer (layer * inputs + input), and the
    // count of a view model trigger a layer used (layer * paths + path).
    private inputUsed: StaticArray<bool>;
    private triggerUsed: StaticArray<i32>;
    // Which paths read another property after the last re-resolve.
    private pathChanged: StaticArray<bool>;
    // Each bound trigger input's view model count when last pulled (-1:
    // not pulled yet).
    private inputTriggerCounts: StaticArray<i32>;
    // The data and the values the paths were resolved in (the scene's;
    // each global's by StateMachine.globals), so that other ones resolve
    // them again.
    private resolvedData: SmData? = null;
    private resolvedValues: ViewModelValues? = null;
    private resolvedGlobals: Array<ViewModelValues?> = [];
    private resolvedOnce: bool = false;
    private callbacks: StateCallbacks;
    // Whether the advance under way wrote a changed value or changed state.
    private changed: bool = false;
    // Milestone 47: a listener performed since the last advance (Rive's
    // markNeedsAdvance): that advance answers changed, so that its host
    // draws again. And how many times the paths were resolved again (a
    // view model listener records its property's value afresh after one).
    needsAdvance: bool = false;
    resolveEpoch: i32 = 0;
    // Whether the last advance itself wrote a changed value or changed
    // state, a listener's mark aside: what a host that draws only what
    // moved (the editor) reads, where the run time keeps Rive's answer.
    wrote: bool = false;

    constructor(machine: StateMachine, scene: SceneMachines, tree: SceneTree) {
        this.machine = machine;
        this.scene = scene;
        this.tree = tree;
        this.callbacks = new StateCallbacks(this);
        this.listeners = new ListenerRun(machine, scene.root, tree);
        this.listeners.owner = this;
        const sa = scene.root.animations;
        const anims = sa != null && sa.root === scene.root ? sa : null;
        this.animations = anims;
        const n = machine.inputs.length;
        this.numbers = new StaticArray<f64>(n);
        this.booleans = new StaticArray<bool>(n);
        this.inputTriggerCounts = new StaticArray<i32>(n);
        const nl = machine.layers.length;
        this.inputUsed = new StaticArray<bool>(nl * n);
        const np = machine.paths.length;
        this.triggerUsed = new StaticArray<i32>(nl * np);
        this.pathChanged = new StaticArray<bool>(np);
        for (let i = 0; i < np; i++) this.paths.push(new PathRun(machine.paths[i], scene.root, scene.file));
        for (let i = 0; i < machine.conditions.length; i++) {
            this.literals.push(new LiteralRun());
            this.components.push(new ComponentRun());
        }
        for (let i = 0; i < machine.globals.length; i++) this.resolvedGlobals.push(null);
        for (let l = 0; l < nl; l++) {
            const layer = machine.layers[l];
            // (a transition's reset holds what its two animations key: at
            // most every keyed number and colour of the layer's animation
            // states)
            let capacity = 0;
            for (let s = 0; s < layer.states.length; s++) {
                const st = layer.states[s];
                if (st.kind == StateKind.Animation && st.animations.length > 0) capacity += resetTracks(anims, st.animations[0]);
            }
            const lr = new LayerRun(layer, l, capacity);
            for (let s = 0; s < layer.states.length; s++) {
                const st = layer.states[s];
                const run = new StateRun(st, s, anims);
                if ((st.kind == StateKind.Blend1DViewModel || st.kind == StateKind.Blend1DInput) && st.reset) {
                    let c = 0;
                    for (let b = 0; b < run.anims.length; b++) c += resetTracks(anims, run.anims[b]);
                    run.reset = new ResetBuffer(c);
                }
                lr.states.push(run);
            }
            this.layers.push(lr);
        }
        this.reset();
    }

    // Back to the start: every layer at its Entry, no transition under way,
    // the inputs at their declared values, the random generator at its
    // seed. (The nodes keep the values the machine left them.)
    reset(): void {
        this.random = this.seed;
        for (let i = 0; i < this.machine.inputs.length; i++) {
            const inp = this.machine.inputs[i];
            this.numbers[i] = inp.kind == InputKind.Number ? inp.number : 0;
            this.booleans[i] = inp.kind == InputKind.Bool ? inp.boolean : false;
            // (a bound trigger input restarted counts from its property's
            // count now: a firing before the restart is not the new run's;
            // never resolved yet, -1, the first pull's)
            const b = inp.binding;
            this.inputTriggerCounts[i] = b != null && this.resolvedOnce ? unchecked(this.paths[b.id]).triggerCount() : -1;
        }
        for (let i = 0; i < this.inputUsed.length; i++) this.inputUsed[i] = false;
        for (let i = 0; i < this.triggerUsed.length; i++) this.triggerUsed[i] = 0;
        for (let l = 0; l < this.layers.length; l++) {
            const lr = this.layers[l];
            lr.current = null;
            lr.from = null;
            lr.transition = null;
            lr.mix = 1;
            lr.mixFrom = 1;
            lr.holdAnimation = -1;
            lr.transitionCompleted = false;
            lr.holdAnimationFrom = false;
            lr.changedOnAdvance = false;
            lr.waitingForExit = false;
            lr.resetOn = false;
            lr.reset.clear();
            if (lr.layer.entry >= 0) this.changeState(lr, lr.layer.entry);
        }
        // (milestone 47: every pointer released, nothing heard)
        this.listeners.reset();
    }

    // One frame of `seconds` (multiplied by `speed`; nothing while
    // `paused`): Rive's StateMachineInstance::advance, step 4 of
    // RIVE_MODEL.md section 5. Whether a value written changed (a new
    // picture) or a state changed.
    advance(seconds: f32): bool {
        this.wrote = false;
        if (this.paused) return false;
        const dt: f32 = seconds * this.speed;
        return this.advanceBy(isFinite(dt) ? dt : 0, true);
    }

    // Rive's settle (advanceAndApply's loop): tries state changes again
    // with no time, up to SETTLE_MAX times, after the bindings moved what a
    // condition reads, applying each time one changed; whether one did.
    settle(): bool {
        if (this.paused) return false;
        let changed = false;
        for (let i = 0; i < SETTLE_MAX; i++) {
            if (!this.tryChangeState()) break;
            this.advanceBy(0, false);
            changed = true;
        }
        return changed;
    }

    get layerCount(): i32 {
        return this.layers.length;
    }

    // Layer `layer`'s current state (an index into its states), or -1.
    stateIndex(layer: i32): i32 {
        if (layer < 0 || layer >= this.layers.length) return -1;
        const c = this.layers[layer].current;
        return c != null ? c.index : -1;
    }

    // Its name ("" for none).
    stateName(layer: i32): string {
        const i = this.stateIndex(layer);
        return i >= 0 ? this.machine.layers[layer].states[i].name : "";
    }

    // Whether layer `layer` is mixing out of the state it left (Rive's
    // isTransitioning).
    transitioning(layer: i32): bool {
        return layer >= 0 && layer < this.layers.length && this.isTransitioning(this.layers[layer]);
    }

    // The transition layer `layer` took last (the one under way while it
    // is transitioning): its place among its state's transitions
    // (transitionIndex) and that state (fromState: an index into the
    // layer's states, Any State's for one of Any State's transitions); -1
    // before any.
    transitionIndex(layer: i32): i32 {
        if (layer < 0 || layer >= this.layers.length) return -1;
        const t = this.layers[layer].transition;
        return t != null ? t.index : -1;
    }

    fromState(layer: i32): i32 {
        if (layer < 0 || layer >= this.layers.length) return -1;
        const t = this.layers[layer].transition;
        return t != null ? t.from : -1;
    }

    // Layer `layer`'s mix of its current state (1 when no transition is
    // under way).
    mix(layer: i32): f32 {
        return layer >= 0 && layer < this.layers.length ? this.layers[layer].mix : 1;
    }

    // "Layer/State" for each layer, in order (the tools'; allocates).
    currentStates(): Array<string> {
        const out = new Array<string>();
        for (let l = 0; l < this.machine.layers.length; l++) out.push(this.machine.layers[l].name + "/" + this.stateName(l));
        return out;
    }

    // An input by name (-1: none), and its value.
    inputIndex(name: string): i32 {
        return this.machine.inputIndex(name);
    }

    inputNumber(i: i32): f64 {
        return i >= 0 && i < this.numbers.length ? this.numbers[i] : 0;
    }

    setInputNumber(i: i32, v: f64): void {
        if (i >= 0 && i < this.numbers.length && this.machine.inputs[i].kind == InputKind.Number) this.numbers[i] = v;
    }

    inputBool(i: i32): bool {
        return i >= 0 && i < this.booleans.length ? this.booleans[i] : false;
    }

    setInputBool(i: i32, b: bool): void {
        if (i >= 0 && i < this.booleans.length && this.machine.inputs[i].kind == InputKind.Bool) this.booleans[i] = b;
    }

    // Fires trigger input `i`: seen by each layer's conditions on the next
    // advance (until a transition of the layer uses it), then spent, as
    // Rive's.
    fireInput(i: i32): void {
        if (i < 0 || i >= this.numbers.length || this.machine.inputs[i].kind != InputKind.Trigger) return;
        this.booleans[i] = true;
        this.numbers[i] += 1;
    }

    // The next number of the random generator, 0 (included) to 1 (see the
    // header).
    nextRandom(): f64 {
        this.random = this.random * 1664525 + 1013904223;
        return <f64>this.random / 4294967296.0;
    }

    // Milestone 47 (./listeners.as): the record of how this instance reads
    // its machine's path `id` (StateMachine.paths), resolved against the
    // data as of the last prepare().
    pathRun(id: i32): PathRun {
        return unchecked(this.paths[id]);
    }

    // Resolves the paths against the data now when the data changed (what
    // an advance does first): a listener performing between two advances
    // writes where the machine reads.
    prepare(): void {
        this.prepareData();
    }

    // --- the advance -----------------------------------------------------

    private advanceBy(dt: f32, newFrame: bool): bool {
        const marked = this.needsAdvance;
        this.changed = false;
        this.needsAdvance = false;
        this.prepareData();
        // (milestone 47: Rive's applyEvents, before the data binds are
        // pulled: the events heard since the last frame, the view model
        // changes; a settle's pass is no new frame)
        let performed = false;
        if (newFrame && this.listeners.advance()) {
            performed = true;
            this.needsAdvance = false;
            this.prepareData();
        }
        this.pullInputs();
        for (let l = 0; l < this.layers.length; l++) this.advanceLayer(unchecked(this.layers[l]), dt, newFrame);
        // (Rive's advanceDataBinds: the converters' time)
        for (let i = 0; i < this.paths.length; i++) unchecked(this.paths[i]).advance(<f64>dt);
        this.spendTriggers();
        flushQuaternions();
        this.wrote = this.changed;
        return this.changed || marked || performed;
    }

    // Rive's StateMachineLayerInstance::advance.
    private advanceLayer(lr: LayerRun, seconds: f32, newFrame: bool): void {
        if (newFrame) lr.changedOnAdvance = false;
        const cur = lr.current;
        if (cur != null) this.advanceState(cur, seconds);
        this.updateMix(lr, seconds);
        const from = lr.from;
        if (from != null && lr.mix < 1 && !lr.holdAnimationFrom) this.advanceState(from, seconds);
        this.apply(lr);
        for (let i = 0; this.updateState(lr); i++) {
            this.changed = true;
            this.apply(lr);
            if (i == TRY_CHANGE_MAX) break;
        }
        const now = lr.current;
        if (now != null) {
            for (let k = 0; k < now.insts.length; k++) {
                const inst = unchecked(now.insts[k]);
                if (inst != null) inst.spilledTime = 0;
            }
        }
    }

    // Rive's tryChangeState (the settle's): the inputs pulled, each layer's
    // updateState once; whether any changed.
    private tryChangeState(): bool {
        this.prepareData();
        this.pullInputs();
        let any = false;
        for (let l = 0; l < this.layers.length; l++) if (this.updateState(unchecked(this.layers[l]))) any = true;
        return any;
    }

    private isTransitioning(lr: LayerRun): bool {
        const t = lr.transition;
        return t != null && lr.from != null && t.duration != 0 && lr.mix < 1;
    }

    // The from state's animation's duration (0 for a state without one),
    // which a duration in % is taken of.
    private fromDuration(lr: LayerRun): f32 {
        const from = lr.from;
        if (from == null || !from.isAnimation || unchecked(from.anims[0]) < 0) return 0;
        const inst = unchecked(from.insts[0]);
        return inst != null ? inst.animation.durationSeconds() : 0;
    }

    private updateMix(lr: LayerRun, seconds: f32): void {
        const t = lr.transition;
        if (t != null && lr.from != null && t.duration != 0) {
            const mixTime = t.mixTime(this.fromDuration(lr));
            if (mixTime == 0) {
                lr.mix = 1;
            } else {
                lr.mix = Mathf.min(1, Mathf.max(0, lr.mix + seconds / mixTime));
            }
            if (lr.mix == 1 && !lr.transitionCompleted) {
                lr.transitionCompleted = true;
                lr.resetOn = false;
                this.fireActions(t.actions, OCCURS_AT_END);
            }
        } else {
            lr.mix = 1;
        }
    }

    // Rive's updateState: Any State's transitions, then the current
    // state's; none while a transition without early exit mixes.
    private updateState(lr: LayerRun): bool {
        const t = lr.transition;
        if (t != null && this.isTransitioning(lr) && !t.enableEarlyExit) return false;
        lr.waitingForExit = false;
        const layer = lr.layer;
        if (layer.any >= 0 && layer.anyTransitions.length > 0 && this.tryChangeFrom(lr, layer.any, null)) return true;
        const cur = lr.current;
        if (cur == null) return false;
        return this.tryChangeFrom(lr, cur.index, cur);
    }

    // Rive's changeState: the left state's end actions, the new state
    // entered (its animations from their start), its start actions.
    private changeState(lr: LayerRun, to: i32): void {
        const cur = lr.current;
        if (cur != null && cur.index == to) return;
        if (cur != null) this.fireActions(cur.state.actions, OCCURS_AT_END);
        if (to < 0) {
            lr.current = null;
            return;
        }
        const run = unchecked(lr.states[to]);
        this.enterState(run);
        lr.current = run;
        this.stateChanges++;
        this.fireActions(run.state.actions, OCCURS_AT_START);
    }

    // Rive's tryChangeState from the state at `fromIndex` (`fromRun` its
    // run; null for Any State).
    private tryChangeFrom(lr: LayerRun, fromIndex: i32, fromRun: StateRun?): bool {
        const outState = lr.current;
        const t = this.findAllowedTransition(lr, fromIndex, fromRun);
        if (t == null) return false;
        lr.resetOn = false;
        this.changeState(lr, t.to);
        lr.changedOnAdvance = true;
        lr.transition = t;
        this.fireActions(t.actions, OCCURS_AT_START);
        if (t.duration == 0) {
            lr.transitionCompleted = true;
            this.fireActions(t.actions, OCCURS_AT_END);
        } else {
            lr.transitionCompleted = false;
        }
        lr.from = outState;
        if (!lr.transitionCompleted) this.buildTransitionReset(lr);
        // (an exit time: the left animation is applied once more at its
        // exit frame, where pauseOnExit holds it)
        if (outState != null && this.applyExitCondition(t, outState)) {
            const inst = outState.animationInstance;
            lr.holdAnimation = unchecked(outState.anims[0]);
            lr.holdTime = inst != null ? inst.time : 0;
        }
        lr.mixFrom = lr.mix;
        if (lr.mix != 0) lr.holdAnimationFrom = t.pauseOnExit;
        const cur = lr.current;
        if (cur != null) {
            let advanceTime: f32 = 0;
            if (outState != null) {
                const inst = outState.animationInstance;
                if (inst != null) advanceTime = inst.spilledTime;
            }
            this.advanceState(cur, advanceTime);
        }
        lr.mix = 0;
        this.updateMix(lr, 0);
        lr.waitingForExit = false;
        return true;
    }

    private findAllowedTransition(lr: LayerRun, fromIndex: i32, fromRun: StateRun?): SmTransition? {
        const state = lr.layer.states[fromIndex];
        const list = state.transitions;
        if (state.random) return this.findRandomTransition(lr, list, fromRun);
        for (let i = 0; i < list.length; i++) {
            const t = unchecked(list[i]);
            if (!this.canChangeState(lr, t.to)) continue;
            const a = this.allowed(t, lr, fromRun);
            if (a == ALLOW_YES) {
                this.useInLayer(t, lr);
                return t;
            }
            if (a == ALLOW_WAITING) lr.waitingForExit = true;
        }
        return null;
    }

    private findRandomTransition(lr: LayerRun, list: Array<SmTransition>, fromRun: StateRun?): SmTransition? {
        let total: u32 = 0;
        const w = lr.weights;
        for (let i = 0; i < list.length; i++) {
            const t = unchecked(list[i]);
            w[i] = 0;
            if (!this.canChangeState(lr, t.to)) continue;
            const a = this.allowed(t, lr, fromRun);
            if (a == ALLOW_YES) {
                w[i] = t.randomWeight;
                total += t.randomWeight;
            } else if (a == ALLOW_WAITING) {
                lr.waitingForExit = true;
            }
        }
        if (total == 0) return null;
        const pick = this.nextRandom() * <f64>total;
        let at: f64 = 0;
        for (let i = 0; i < list.length; i++) {
            const weight = <f64>w[i];
            if (at + weight > pick) {
                const t = unchecked(list[i]);
                this.useInLayer(t, lr);
                return t;
            }
            at += weight;
        }
        return null;
    }

    // Whether the layer may go to state `to` (not the one it is in; a
    // target that resolved to none is never taken).
    private canChangeState(lr: LayerRun, to: i32): bool {
        if (to < 0) return false;
        const cur = lr.current;
        return cur == null || cur.index != to;
    }

    // Rive's StateTransition::allowed.
    private allowed(t: SmTransition, lr: LayerRun, fromRun: StateRun?): i32 {
        if (t.disabled) return ALLOW_NO;
        const cs = t.conditions;
        for (let i = 0; i < cs.length; i++) if (!this.evaluate(unchecked(cs[i]), lr)) return ALLOW_NO;
        if (t.enableExitTime && fromRun != null) {
            const inst = fromRun.animationInstance;
            if (inst != null) {
                // (an exit time below one loop is brought up to the loop the
                // last time was in, so a looping animation exits on any)
                const lastTime = inst.lastTotalTime;
                const time = inst.totalTime;
                let exitTime = this.exitTimeSeconds(t, fromRun, false);
                const animationFrom = inst.animation;
                const duration = animationFrom.durationSeconds();
                if (exitTime <= duration && animationFrom.loop != LoopMode.OneShot && duration > 0) {
                    exitTime += Mathf.floor(lastTime / duration) * duration;
                }
                if (time < exitTime) return ALLOW_WAITING;
            }
        }
        return ALLOW_YES;
    }

    // Rive's exitTimeSeconds: in % of the from state's animation (none for
    // a state without one), from its start when `absolute`.
    private exitTimeSeconds(t: SmTransition, fromRun: StateRun, absolute: bool): f32 {
        let start: f32 = 0;
        let duration: f32 = 0;
        if (fromRun.isAnimation && unchecked(fromRun.anims[0]) >= 0) {
            const inst = unchecked(fromRun.insts[0]);
            if (inst != null) {
                start = inst.animation.startSeconds();
                duration = inst.animation.durationSeconds();
            }
        }
        return t.exitTimeSeconds(start, duration, absolute);
    }

    // Rive's applyExitCondition: with an exit time from an animation state,
    // whether its exit frame is held; pauseOnExit moves it there.
    private applyExitCondition(t: SmTransition, from: StateRun): bool {
        const useExitTime = t.enableExitTime && from.isAnimation;
        if (t.pauseOnExit && useExitTime) {
            const inst = from.animationInstance;
            if (inst != null) inst.setTime(this.exitTimeSeconds(t, from, true));
            return true;
        }
        return useExitTime;
    }

    // --- states ----------------------------------------------------------

    private enterState(run: StateRun): void {
        run.keepGoing = true;
        for (let k = 0; k < run.insts.length; k++) {
            const inst = unchecked(run.insts[k]);
            if (inst != null) inst.reset();
            unchecked(run.mixes[k] = 0);
        }
        const r = run.reset;
        if (r != null) this.buildBlendReset(run, r);
    }

    private advanceState(run: StateRun, seconds: f32): void {
        const kind = run.state.kind;
        const sink: CallbackSink? = this.events != null ? this.callbacks : null;
        if (kind == StateKind.Animation) {
            const inst = unchecked(run.insts[0]);
            if (inst == null) return;
            this.callbacks.index = unchecked(run.anims[0]);
            run.keepGoing = inst.advance(seconds, sink);
            return;
        }
        if (kind != StateKind.Blend1DViewModel && kind != StateKind.Blend1DInput && kind != StateKind.BlendDirect) {
            run.keepGoing = false;
            return;
        }
        // (Rive's BlendStateInstance: each animation advanced while it
        // keeps going, whatever its mix)
        for (let k = 0; k < run.insts.length; k++) {
            const inst = unchecked(run.insts[k]);
            if (inst == null || !inst.keepGoing()) continue;
            this.callbacks.index = unchecked(run.anims[k]);
            inst.advance(seconds, sink);
        }
        if (kind == StateKind.BlendDirect) this.directMixes(run);
        else this.blend1DMixes(run);
    }

    // BlendState1DInstance::advance's mixes: the two animations around the
    // value (the blends as given, binary-searched as Rive does), mixed by
    // where it falls between them.
    private blend1DMixes(run: StateRun): void {
        const st = run.state;
        let value: f32 = 0;
        if (st.kind == StateKind.Blend1DInput) {
            if (st.input >= 0) value = <f32>this.numbers[st.input];
        } else {
            const p = st.path;
            if (p != null) {
                const v = unchecked(this.paths[p.id]).read();
                if (v != null && v.kind == VmKind.Number) value = <f32>v.number;
            }
        }
        // (NaN would mix NaN into the nodes: read as 0)
        if (isNaN(value)) value = 0;
        const blends = st.blends;
        const count = blends.length;
        let idx = 0;
        let start = 0;
        let end = count - 1;
        while (start <= end) {
            const mid = (start + end) >> 1;
            const closest = unchecked(blends[mid]).value;
            if (closest < value) start = mid + 1;
            else if (closest > value) end = mid - 1;
            else {
                idx = start = mid;
                break;
            }
            idx = start;
        }
        const toI = idx >= 0 && idx < count ? idx : -1;
        const fromI = idx - 1 >= 0 && idx - 1 < count ? idx - 1 : -1;
        const toValue: f32 = toI >= 0 ? unchecked(blends[toI]).value : 0;
        const fromValue: f32 = fromI >= 0 ? unchecked(blends[fromI]).value : 0;
        let mix: f32;
        let mixFrom: f32;
        if (toI < 0 || fromI < 0 || toValue == fromValue) {
            mix = 1;
            mixFrom = 1;
        } else {
            mix = (value - fromValue) / (toValue - fromValue);
            mixFrom = 1 - mix;
        }
        for (let k = 0; k < count; k++) {
            const av = unchecked(blends[k]).value;
            if (toI >= 0 && av == toValue) unchecked(run.mixes[k] = mix);
            else if (fromI >= 0 && av == fromValue) unchecked(run.mixes[k] = mixFrom);
            else unchecked(run.mixes[k] = 0);
        }
    }

    // BlendStateDirectInstance::advance's mixes: each animation's weight
    // (its input, its view model number or its mixValue) / 100, clamped; a
    // view model weight that reads nothing keeps its last mix.
    private directMixes(run: StateRun): void {
        const blends = run.state.blends;
        for (let k = 0; k < blends.length; k++) {
            const b = unchecked(blends[k]);
            let value: f32 = 0;
            const p = b.path;
            if (b.source == BlendSource.Input) {
                // (an input the machine lacks weighs nothing, as Rive's
                // blend reads no number from it)
                if (b.input >= 0) value = <f32>this.numbers[b.input];
            } else if (p != null) {
                const v = unchecked(this.paths[p.id]).read();
                if (v == null || v.kind != VmKind.Number) continue;
                value = <f32>v.number;
            } else {
                value = b.mixValue;
            }
            // (a number that is not one, NaN, weighs nothing: it would write
            // NaN into the nodes)
            unchecked(run.mixes[k] = isNaN(value) ? 0 : Mathf.min(1, Mathf.max(0, value / 100)));
        }
    }

    // A state's animations applied at `mix` (blends at their own mixes
    // times it; a blend's animation at 0 is not applied, as Rive's).
    private applyState(run: StateRun, mix: f32): void {
        const sa = this.animations;
        if (sa == null) return;
        const kind = run.state.kind;
        if (kind == StateKind.Animation) {
            const inst = unchecked(run.insts[0]);
            if (inst != null && unchecked(run.anims[0]) >= 0 && sa.applyDeferred(this.tree, inst, mix)) this.changed = true;
            return;
        }
        if (kind != StateKind.Blend1DViewModel && kind != StateKind.Blend1DInput && kind != StateKind.BlendDirect) return;
        const r = run.reset;
        if (r != null && this.writeReset(r)) this.changed = true;
        for (let k = 0; k < run.insts.length; k++) {
            const inst = unchecked(run.insts[k]);
            const m = mix * unchecked(run.mixes[k]);
            if (inst == null || m == 0) continue;
            if (sa.applyDeferred(this.tree, inst, m)) this.changed = true;
        }
    }

    // Rive's StateMachineLayerInstance::apply.
    private apply(lr: LayerRun): void {
        if (lr.resetOn && this.writeReset(lr.reset)) this.changed = true;
        const sa = this.animations;
        if (lr.holdAnimation >= 0 && sa != null) {
            const a = sa.animations[lr.holdAnimation];
            if (sa.applyAt(this.tree, lr.holdAnimation, a.applyTime(lr.holdTime), lr.mixFrom, null)) this.changed = true;
        }
        lr.holdAnimation = -1;
        const t = lr.transition;
        const ip = t != null ? t.interpolator : null;
        const from = lr.from;
        if (from != null && lr.mix < 1) this.applyState(from, ip != null ? ip.transform(lr.mixFrom) : lr.mixFrom);
        const cur = lr.current;
        if (cur != null) this.applyState(cur, ip != null ? ip.transform(lr.mix) : lr.mix);
    }

    // --- resets (Rive's AnimationResetFactory) -----------------------------

    // fromStates: every number and colour the from and to animation states
    // key, as the nodes hold them now.
    private buildTransitionReset(lr: LayerRun): void {
        const r = lr.reset;
        r.clear();
        const sa = this.animations;
        if (sa != null) {
            const from = lr.from;
            if (from != null && from.isAnimation) this.addReset(sa, r, unchecked(from.anims[0]), false);
            const cur = lr.current;
            if (cur != null && cur.isAnimation) this.addReset(sa, r, unchecked(cur.anims[0]), false);
        }
        lr.resetOn = r.count > 0;
    }

    // fromAnimations with the first as the baseline: the first animation's
    // properties at its first key, the others' as the nodes hold them now.
    private buildBlendReset(run: StateRun, r: ResetBuffer): void {
        r.clear();
        const sa = this.animations;
        if (sa == null) return;
        for (let k = 0; k < run.anims.length; k++) this.addReset(sa, r, unchecked(run.anims[k]), k == 0);
    }

    private addReset(sa: SceneAnimations, r: ResetBuffer, ai: i32, baseline: bool): void {
        if (ai < 0) return;
        const a = sa.animations[ai];
        for (let o = 0; o < a.objects.length; o++) {
            const node = sa.targetNode(ai, o);
            if (node == null) continue;
            const tracks = unchecked(a.objects[o]).tracks;
            for (let t = 0; t < tracks.length; t++) {
                if (sa.resetKind(ai, o, t) == 0) continue;
                const property = unchecked(tracks[t]).property;
                if (r.has(node, property)) continue;
                const e = r.take();
                e.animation = ai;
                e.object = o;
                e.track = t;
                e.node = node;
                e.property = property;
                const ok = baseline ? sa.firstKey(ai, o, t, e.value) : sa.readTrack(ai, o, t, e.value);
                if (!ok) r.count--;
            }
        }
    }

    private writeReset(r: ResetBuffer): bool {
        const sa = this.animations;
        if (sa == null) return false;
        let changed = false;
        for (let i = 0; i < r.count; i++) {
            const e = unchecked(r.entries[i]);
            if (sa.writeTrack(this.tree, e.animation, e.object, e.track, e.value)) changed = true;
        }
        return changed;
    }

    // --- conditions ------------------------------------------------------

    private evaluate(c: SmCondition, lr: LayerRun): bool {
        const kind = c.kind;
        if (kind == ConditionKind.Number) {
            // (Rive: an input that is not there lets the condition pass)
            if (c.input < 0) return true;
            return compareNumbers(c.op, <f32>this.numbers[c.input], c.number);
        }
        if (kind == ConditionKind.Bool) {
            if (c.input < 0) return true;
            const v = this.booleans[c.input];
            return (v && c.op == ConditionOp.Equal) || (!v && c.op == ConditionOp.NotEqual);
        }
        if (kind == ConditionKind.Trigger) {
            if (c.input < 0) return true;
            return this.booleans[c.input] && !this.inputUsed[lr.index * this.numbers.length + c.input];
        }
        if (kind == ConditionKind.ViewModel) {
            const left = c.left;
            if (left == null) return false;
            const lp = unchecked(this.paths[left.id]);
            if (lp.state != PATH_FOUND) return false;
            if (lp.kind == VmKind.Trigger) {
                const n = lp.triggerCount();
                return n > lp.triggerBase && n > this.triggerUsed[lr.index * this.paths.length + left.id];
            }
            const lv = lp.read();
            if (lv == null) return false;
            return this.compareRight(c, lv);
        }
        const v = this.componentValue(c);
        if (v == null) return false;
        return this.compareRight(c, v);
    }

    // `left` against the condition's right side: another path, or the
    // literal read as `left`'s kind.
    private compareRight(c: SmCondition, left: BoundValue): bool {
        const right = c.right;
        if (right != null) {
            const rv = unchecked(this.paths[right.id]).read();
            return rv != null && compareValues(c.op, left, rv);
        }
        if (!c.hasValue) return false;
        const lit = unchecked(this.literals[c.id]);
        if (lit.kind != left.kind) {
            lit.kind = left.kind;
            lit.ok = parseLiteral(left.kind, c.value, lit.value);
        }
        return lit.ok && compareValues(c.op, left, lit.value);
    }

    // A component condition's node property now (null: no such node or
    // property, or nothing to read there).
    private componentValue(c: SmCondition): BoundValue? {
        const cr = unchecked(this.components[c.id]);
        if (!cr.looked) {
            cr.looked = true;
            const root = this.scene.root;
            const node = c.target.length == 0 || c.target == "." ? root : root.getNode(c.target);
            cr.node = node;
            // (a shader parameter resolved against the node's material)
            cr.target = node != null ? nodeBindingTarget(node, c.property) : null;
        }
        const node = cr.node;
        const target = cr.target;
        if (node == null || target == null) return null;
        if (!readTarget(node, target, cr.value, node.bindingPose, this.view)) return null;
        return cr.value;
    }

    // The transition `t` is taken: the triggers its conditions read are
    // used by the layer (Rive's useLayerInConditions).
    private useInLayer(t: SmTransition, lr: LayerRun): void {
        const cs = t.conditions;
        for (let i = 0; i < cs.length; i++) {
            const c = unchecked(cs[i]);
            if (c.kind == ConditionKind.Trigger) {
                if (c.input >= 0) this.inputUsed[lr.index * this.numbers.length + c.input] = true;
            } else if (c.kind == ConditionKind.ViewModel) {
                const left = c.left;
                if (left == null) continue;
                const lp = unchecked(this.paths[left.id]);
                if (lp.state != PATH_FOUND || lp.kind != VmKind.Trigger) continue;
                // (the property is used, whichever of the machine's paths
                // names it: Rive marks the view model trigger itself)
                const n = lp.triggerCount();
                const np = this.paths.length;
                for (let k = 0; k < np; k++) {
                    const other = unchecked(this.paths[k]);
                    if (other === lp || (other.state == PATH_FOUND && other.values === lp.values && other.resolved == lp.resolved)) {
                        this.triggerUsed[lr.index * np + k] = n;
                    }
                }
            }
        }
    }

    // --- actions ---------------------------------------------------------

    private fireActions(actions: Array<SmAction>, occurs: i32): void {
        if (actions.length == 0) return;
        const sink = this.events;
        if (sink == null) return;
        for (let i = 0; i < actions.length; i++) {
            const a = unchecked(actions[i]);
            if (a.occurs != occurs) continue;
            if (a.kind == ActionKind.FireEvent) {
                // (Rive's StateMachineFireEvent fires nothing for an event
                // the artboard does not have)
                if (a.eventDecl != null) sink.fireEvent(this.scene.root, a.event, a.eventDecl, 0);
                continue;
            }
            const p = a.trigger;
            if (p == null) continue;
            const pr = unchecked(this.paths[p.id]);
            if (pr.state == PATH_FOUND && pr.kind == VmKind.Trigger) sink.fireTrigger(this.scene.root, pr.resolved, p.global);
        }
    }

    // --- data ------------------------------------------------------------

    // Resolves every path again when the data answers other values (the
    // first advance, a host binding another instance, a global found).
    private prepareData(): void {
        const data = this.data;
        let again = !this.resolvedOnce || data !== this.resolvedData;
        const scene = data != null ? data.values() : null;
        if (scene !== this.resolvedValues) again = true;
        const globals = this.machine.globals;
        for (let i = 0; i < globals.length; i++) {
            const g = data != null ? data.global(unchecked(globals[i])) : null;
            if (g !== unchecked(this.resolvedGlobals[i])) {
                this.resolvedGlobals[i] = g;
                again = true;
            }
        }
        if (!again) return;
        const first = !this.resolvedOnce;
        this.resolvedOnce = true;
        this.resolveEpoch++;
        this.resolvedData = data;
        this.resolvedValues = scene;
        let named = false;
        for (let i = 0; i < this.paths.length; i++) if (unchecked(this.paths[i]).path.converter.length > 0) named = true;
        const lookup = named ? this.scene.converterLookup(this.tree) : null;
        // (only a path that reads another property than before forgets its
        // trigger's uses: one found again where it was keeps them, so a
        // global turning up later does not fire the scene's old triggers
        // again)
        const np = this.paths.length;
        for (let i = 0; i < np; i++) {
            const pr = unchecked(this.paths[i]);
            const changed = pr.resolve(valuesFor(pr.path, data), lookup);
            this.pathChanged[i] = changed;
            if (!changed) continue;
            for (let l = 0; l < this.layers.length; l++) this.triggerUsed[l * np + i] = 0;
        }
        const inputs = this.machine.inputs;
        for (let i = 0; i < inputs.length; i++) {
            const b = unchecked(inputs[i]).binding;
            if (b == null || !this.pathChanged[b.id]) continue;
            // (a bound trigger input reading another property counts from
            // its count now; the first data, -1: a firing before the first
            // pull is the first frame's)
            this.inputTriggerCounts[i] = first ? -1 : unchecked(this.paths[b.id]).triggerCount();
        }
        // (each literal read again against the kinds found now)
        for (let i = 0; i < this.literals.length; i++) unchecked(this.literals[i]).kind = VmKind.Other;
    }

    // Rive's updateDataBinds for the inputs: each bound input takes its
    // view model property's value (a trigger input is fired when its view
    // model trigger fired since the last pull, or before the first).
    private pullInputs(): void {
        const inputs = this.machine.inputs;
        for (let i = 0; i < inputs.length; i++) {
            const inp = unchecked(inputs[i]);
            const b = inp.binding;
            if (b == null) continue;
            const pr = unchecked(this.paths[b.id]);
            if (pr.state != PATH_FOUND) continue;
            if (inp.kind == InputKind.Trigger) {
                const n = pr.triggerCount();
                const was = this.inputTriggerCounts[i];
                this.inputTriggerCounts[i] = n;
                if (n > (was >= 0 ? was : 0)) {
                    this.booleans[i] = true;
                    this.numbers[i] += 1;
                }
                continue;
            }
            const v = pr.read();
            if (v == null) continue;
            if (inp.kind == InputKind.Number) {
                if (v.kind == VmKind.Number || v.kind == VmKind.Enum) this.numbers[i] = v.number;
                else if (v.kind == VmKind.Boolean) this.numbers[i] = v.boolean ? 1 : 0;
            } else if (v.kind == VmKind.Boolean) {
                this.booleans[i] = v.boolean;
            } else if (v.kind == VmKind.Number) {
                this.booleans[i] = v.number != 0;
            }
        }
    }

    // Rive's inputs' advanced(): the trigger inputs spent and their uses
    // forgotten; each view model trigger's count kept as the one the next
    // frame's firings are counted from.
    private spendTriggers(): void {
        const inputs = this.machine.inputs;
        let any = false;
        for (let i = 0; i < inputs.length; i++) {
            if (unchecked(inputs[i]).kind != InputKind.Trigger) continue;
            this.booleans[i] = false;
            any = true;
        }
        if (any) for (let i = 0; i < this.inputUsed.length; i++) this.inputUsed[i] = false;
        for (let i = 0; i < this.paths.length; i++) {
            const pr = unchecked(this.paths[i]);
            if (pr.state != PATH_FOUND || pr.kind != VmKind.Trigger) continue;
            const n = pr.triggerCount();
            if (n >= 0) pr.triggerBase = n;
        }
    }
}

// How many numbers and colours animation `ai` keys (a reset's entries at
// most).
function resetTracks(sa: SceneAnimations?, ai: i32): i32 {
    if (sa == null || ai < 0 || ai >= sa.animations.length) return 0;
    const a = sa.animations[ai];
    let n = 0;
    for (let o = 0; o < a.objects.length; o++) {
        const tracks = a.objects[o].tracks;
        for (let t = 0; t < tracks.length; t++) if (sa.resetKind(ai, o, t) != 0) n++;
    }
    return n;
}
