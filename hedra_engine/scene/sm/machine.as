// A state machine prepared for the engine (milestone 46, docs/plans/
// RIVE_MODEL.md sections 3.3 and 5): its declaration (./decl.as) turned
// into indices once per scene document, shared by every instance of the
// scene (./scene_machines.as attachSceneMachines keeps them, and the
// instancer's share keeps them per document as it keeps the timelines), so
// that a frame never looks a name up: a state's animations are indices
// into its scene's prepared animations (../anim/scene_anims.as
// SceneAnimations), a transition's target an index into its layer's
// states, a condition's input an index into the machine's inputs, a
// transition's flags Rive's StateTransitionFlags bits.
//
// What only an instance can know is left to it (./instance.as): a view
// model side's path is chosen among its data contexts' candidates
// (../binding/binder.as contextCandidates, which depend on where the scene
// is instanced) when the instance first reads it, its converter is built
// then (converters keep state: an Interpolator mid-ease), a literal is read
// once the left side's kind is known (a "true" is a boolean only against a
// boolean property), and a component condition's node is found from the
// scene's root in the instance's tree. The prepared parts here hold the
// names those need (SmPath, SmCondition).
//
// A name that resolves to nothing prepares to -1 (an unknown animation
// plays nothing, an unknown target state is never entered, an unknown
// input reads as Rive reads a missing one: its condition passes); the
// validator (./check.as) reports each such name, so a scene that passes
// it has none.

import { SmListener, prepareListeners } from "./listeners";
import { EventDecl, InterpolationType } from "../anim/decl";
import { Interpolator } from "../anim/interp";
import { SceneAnimations } from "../anim/scene_anims";
import {
    ActionKind, BlendSource, ConditionDecl, ConditionKind, ConditionOp, EXIT_STATE_NAME, FireActionDecl, InputDecl, InputKind,
    LayerDecl, StateDecl, StateKind, StateMachineDecl, TransitionDecl,
} from "./decl";

// Rive's StateTransitionFlags (state_transition_flags.hpp), which the
// binary scene's STMC section writes too.
export const TRANSITION_DISABLED: u8 = 1;
export const TRANSITION_DURATION_IS_PERCENTAGE: u8 = 2;
export const TRANSITION_ENABLE_EXIT_TIME: u8 = 4;
export const TRANSITION_EXIT_TIME_IS_PERCENTAGE: u8 = 8;
export const TRANSITION_PAUSE_ON_EXIT: u8 = 16;
export const TRANSITION_ENABLE_EARLY_EXIT: u8 = 32;

// The flags of `d`, as Rive's bits.
export function transitionFlagsOf(d: TransitionDecl): u8 {
    let f: u8 = 0;
    if (d.disabled) f |= TRANSITION_DISABLED;
    if (d.durationIsPercentage) f |= TRANSITION_DURATION_IS_PERCENTAGE;
    if (d.enableExitTime) f |= TRANSITION_ENABLE_EXIT_TIME;
    if (d.exitTimeIsPercentage) f |= TRANSITION_EXIT_TIME_IS_PERCENTAGE;
    if (d.pauseOnExit) f |= TRANSITION_PAUSE_ON_EXIT;
    if (d.enableEarlyExit) f |= TRANSITION_ENABLE_EARLY_EXIT;
    return f;
}

// One input of a machine, with its declared start value.
export class SmInput {
    kind: InputKind;
    name: string;
    number: f64 = 0;
    boolean: bool = false;
    decl: InputDecl;
    // Its `<binding property="value">` (null: none): the view model
    // property the input follows, pulled at each advance's start (Rive's
    // updateDataBinds).
    binding: SmPath? = null;

    constructor(decl: InputDecl) {
        this.decl = decl;
        this.kind = decl.kind;
        this.name = decl.name;
        this.number = decl.number;
        this.boolean = decl.boolean;
        for (let i = 0; i < decl.bindings.length; i++) {
            const b = decl.bindings[i];
            if (b.property == "value" && b.path.length > 0) this.binding = new SmPath(b.path, b.global, b.converter);
        }
    }
}

// A view model property a machine reads (a condition's side, a 1D blend's
// number, a direct blend's weight, a fire action's trigger, an input's
// binding): its path in the scene's data context, or in the global
// `global`, and the converter its value goes through ("" none). The
// instance resolves it (./instance.as PathRun).
export class SmPath {
    path: string;
    global: string;
    converter: string;
    // Its index among its machine's paths (StateMachine.paths): where an
    // instance keeps what it resolved.
    id: i32 = -1;

    constructor(path: string, global: string, converter: string) {
        this.path = path;
        this.global = global;
        this.converter = converter;
    }
}

// One condition, prepared. Which fields a kind reads: ViewModel `left`
// and `right` or `value`; Component `target`, `property` and `right` or
// `value`; Number `input` and `number`; Bool and Trigger `input`.
export class SmCondition {
    kind: ConditionKind;
    op: ConditionOp;
    decl: ConditionDecl;
    // Its index among its machine's conditions (StateMachine.conditions).
    id: i32 = -1;
    // The machine's input (-1: none of that name and kind).
    input: i32 = -1;
    // A Number condition's value (Rive's float).
    number: f32 = 0;
    // A view model left side (ViewModel), and a view model right side
    // (null: the literal `value`, or none).
    left: SmPath? = null;
    right: SmPath? = null;
    // Component: the node's path from the scene's root and its property.
    target: string = "";
    property: string = "";
    // The literal as the file wrote it, and whether it wrote one.
    value: string = "";
    hasValue: bool = false;

    constructor(decl: ConditionDecl) {
        this.decl = decl;
        this.kind = decl.kind;
        this.op = decl.op;
        this.value = decl.value;
        this.hasValue = decl.hasValue;
    }
}

// One fire action, prepared: an event of the scene (`event`, its
// declaration when the scene declares it) or a view model trigger
// (`trigger`), as its state or transition starts (OCCURS_AT_START) or ends.
export class SmAction {
    kind: ActionKind;
    occurs: i32;
    decl: FireActionDecl;
    event: string = "";
    eventDecl: EventDecl? = null;
    trigger: SmPath? = null;

    constructor(decl: FireActionDecl) {
        this.decl = decl;
        this.kind = decl.kind;
        this.occurs = decl.occurs;
    }
}

// One transition, prepared.
export class SmTransition {
    // The state it goes to, an index into its layer's states (-1: none
    // resolved: the validator's transition-target-unknown).
    to: i32 = -1;
    // The state it leaves (an index into its layer's states: Any State's
    // for one of Any State's transitions), and its place among that state's
    // transitions (the editor lights it by the two).
    from: i32 = -1;
    index: i32 = -1;
    decl: TransitionDecl;
    interpolation: InterpolationType = InterpolationType.Linear;
    // Rive applies a transition's interpolator whenever it has one (its
    // interpolationType aside), and mixes linearly without one.
    interpolator: Interpolator? = null;
    // Rive's StateTransitionFlags (TRANSITION_*), duration and exit time
    // (milliseconds, or percent of the from state's animation with their
    // flags), random weight.
    flags: u8 = 0;
    duration: u32 = 0;
    exitTime: u32 = 0;
    randomWeight: u32 = 1;
    conditions: Array<SmCondition> = [];
    actions: Array<SmAction> = [];

    constructor(decl: TransitionDecl) {
        this.decl = decl;
        this.interpolation = decl.interpolation;
        this.flags = transitionFlagsOf(decl);
        this.duration = <u32>max<i32>(0, decl.duration);
        this.exitTime = <u32>max<i32>(0, decl.exitTime);
        this.randomWeight = <u32>max<i32>(0, decl.randomWeight);
        const ip = decl.interpolator;
        if (ip != null) this.interpolator = new Interpolator(ip);
    }

    has(flag: u8): bool {
        return (this.flags & flag) == flag;
    }

    get disabled(): bool {
        return this.has(TRANSITION_DISABLED);
    }

    get enableExitTime(): bool {
        return this.has(TRANSITION_ENABLE_EXIT_TIME);
    }

    get pauseOnExit(): bool {
        return this.has(TRANSITION_PAUSE_ON_EXIT);
    }

    get enableEarlyExit(): bool {
        return this.has(TRANSITION_ENABLE_EARLY_EXIT);
    }

    // Rive's StateMachineLayerInstance::resolvedMixTime: the duration in
    // seconds, a percentage taken of the from state's animation
    // (`fromDuration`, its durationSeconds; 0 for a state without one).
    mixTime(fromDuration: f32): f32 {
        if (this.duration == 0) return 0;
        if (this.has(TRANSITION_DURATION_IS_PERCENTAGE)) return <f32>this.duration / <f32>100 * fromDuration;
        return <f32>this.duration / <f32>1000;
    }

    // Rive's exitTimeSeconds: the exit time in seconds, a percentage taken
    // of the from state's animation (`fromStart` its startSeconds, added
    // when `absolute`; `fromDuration` its durationSeconds).
    exitTimeSeconds(fromStart: f32, fromDuration: f32, absolute: bool): f32 {
        if (this.has(TRANSITION_EXIT_TIME_IS_PERCENTAGE)) {
            const start: f32 = absolute ? fromStart : 0;
            return start + <f32>this.exitTime / <f32>100 * fromDuration;
        }
        return <f32>this.exitTime / <f32>1000;
    }
}

// One animation of a blend state: its index in the scene's prepared
// animations (-1 none), its place on a 1D blend's axis (Rive's float), and
// a direct blend's weight: from an input (`input`), the view model
// (`path`), or the fixed `mixValue` (0 to 100).
export class SmBlend {
    animation: i32 = -1;
    value: f32 = 0;
    source: BlendSource = BlendSource.MixValue;
    mixValue: f32 = 100;
    input: i32 = -1;
    path: SmPath? = null;
}

// One state, prepared. `animations`: an AnimationState's one animation, a
// blend state's in its children's order, each an index into the scene's
// prepared animations (-1: the name resolved to none, which plays nothing).
export class SmState {
    kind: StateKind;
    name: string;
    decl: StateDecl;
    animations: Array<i32> = [];
    speed: f32 = 1;
    // Rive's LayerStateFlags: random (a random allowed transition is taken,
    // by their weights) and reset (a 1D blend writes its animations' first
    // keys before it mixes them).
    random: bool = false;
    reset: bool = false;
    transitions: Array<SmTransition> = [];
    actions: Array<SmAction> = [];
    // A blend state's animations (`animations` holds their indices too),
    // in the file's order (Rive binary-searches a 1D blend's values as
    // given: the validator warns when they are not ascending).
    blends: Array<SmBlend> = [];
    // A 1D blend's number: an input (Blend1DInput) or a view model number
    // (Blend1DViewModel).
    input: i32 = -1;
    path: SmPath? = null;

    constructor(decl: StateDecl) {
        this.decl = decl;
        this.kind = decl.kind;
        this.name = decl.displayName();
        this.speed = <f32>decl.speed;
        this.random = decl.random;
        this.reset = decl.reset;
    }
}

// One layer: its states, and where its Entry, Any and Exit are (-1: the
// layer lacks one: the validator's layer-state-missing).
export class SmLayer {
    name: string;
    decl: LayerDecl;
    states: Array<SmState> = [];
    entry: i32 = -1;
    any: i32 = -1;
    exit: i32 = -1;
    // Any State's transitions (the Any state's own list; empty without
    // one), tried before the current state's at every change.
    anyTransitions: Array<SmTransition> = [];
    // The most transitions one of its states has (an instance's scratch
    // of random weights is that long).
    maxTransitions: i32 = 0;

    constructor(decl: LayerDecl) {
        this.decl = decl;
        this.name = decl.name;
    }

    // The index of the state called `name`, or -1.
    stateIndex(name: string): i32 {
        for (let i = 0; i < this.states.length; i++) if (this.states[i].name == name) return i;
        return -1;
    }
}

export class StateMachine {
    name: string;
    decl: StateMachineDecl;
    layers: Array<SmLayer> = [];
    inputs: Array<SmInput> = [];
    // Every view model path and every condition of the machine, by id (an
    // instance keeps one record of each, made the first time it is read).
    paths: Array<SmPath> = [];
    conditions: Array<SmCondition> = [];
    // The globals its paths name, each once (an instance looks each up
    // once a frame).
    globals: Array<string> = [];
    // Milestone 47: its listeners (./listeners.as), in file order.
    listeners: Array<SmListener> = [];

    constructor(decl: StateMachineDecl) {
        this.decl = decl;
        this.name = decl.name;
    }

    // The index of layer `name`, or -1.
    layerIndex(name: string): i32 {
        for (let i = 0; i < this.layers.length; i++) if (this.layers[i].name == name) return i;
        return -1;
    }

    // The index of input `name`, or -1.
    inputIndex(name: string): i32 {
        for (let i = 0; i < this.inputs.length; i++) if (this.inputs[i].name == name) return i;
        return -1;
    }

    // The index of input `name` when it is of kind `kind`, else -1.
    inputOfKind(name: string, kind: InputKind): i32 {
        const i = this.inputIndex(name);
        return i >= 0 && this.inputs[i].kind == kind ? i : -1;
    }

    // `p`, given its id.
    path(p: SmPath): SmPath {
        p.id = this.paths.length;
        this.paths.push(p);
        if (p.global.length > 0 && !this.globals.includes(p.global)) this.globals.push(p.global);
        return p;
    }
}

// Prepares `d` against `scene`'s animations and events (null: a scene with
// no timelines, every state's animation then -1 and every event action
// without its declaration).
export function prepareStateMachine(d: StateMachineDecl, scene: SceneAnimations?): StateMachine {
    const m = new StateMachine(d);
    for (let i = 0; i < d.inputs.length; i++) {
        const input = new SmInput(d.inputs[i]);
        const b = input.binding;
        if (b != null) m.path(b);
        m.inputs.push(input);
    }
    for (let l = 0; l < d.layers.length; l++) {
        const ld = d.layers[l];
        const layer = new SmLayer(ld);
        for (let s = 0; s < ld.states.length; s++) {
            const sd = ld.states[s];
            const st = new SmState(sd);
            if (sd.kind == StateKind.Entry && layer.entry < 0) layer.entry = s;
            else if (sd.kind == StateKind.Any && layer.any < 0) layer.any = s;
            else if (sd.kind == StateKind.Exit && layer.exit < 0) layer.exit = s;
            if (sd.kind == StateKind.Animation) {
                if (sd.animation.length > 0) st.animations.push(animationIndex(scene, sd.animation));
            } else {
                for (let b = 0; b < sd.blends.length; b++) {
                    const bd = sd.blends[b];
                    const blend = new SmBlend();
                    blend.animation = animationIndex(scene, bd.animation);
                    blend.value = <f32>bd.value;
                    blend.mixValue = <f32>bd.mixValue;
                    // (the source the attributes say: ./decl.as BlendSource)
                    if (bd.input.length > 0) {
                        blend.source = BlendSource.Input;
                        blend.input = m.inputOfKind(bd.input, InputKind.Number);
                    } else if (bd.path.length > 0) {
                        blend.source = BlendSource.ViewModel;
                        blend.path = m.path(new SmPath(bd.path, bd.global, bd.converter));
                    } else {
                        blend.source = BlendSource.MixValue;
                    }
                    st.blends.push(blend);
                    st.animations.push(blend.animation);
                }
            }
            if (sd.kind == StateKind.Blend1DInput) st.input = m.inputOfKind(sd.input, InputKind.Number);
            else if (sd.kind == StateKind.Blend1DViewModel) st.path = m.path(new SmPath(sd.path, sd.global, sd.converter));
            for (let a = 0; a < sd.actions.length; a++) st.actions.push(compileAction(sd.actions[a], scene, m));
            layer.states.push(st);
        }
        for (let s = 0; s < ld.states.length; s++) {
            const sd = ld.states[s];
            for (let t = 0; t < sd.transitions.length; t++) {
                const td = sd.transitions[t];
                const tr = new SmTransition(td);
                tr.from = s;
                tr.index = t;
                tr.to = td.to == EXIT_STATE_NAME ? layer.exit : layer.stateIndex(td.to);
                // (Entry and Any are never entered: Rive's editor draws no
                // arrow into them, and the validator refuses one)
                if (tr.to >= 0) {
                    const k = layer.states[tr.to].kind;
                    if (k == StateKind.Entry || k == StateKind.Any) tr.to = -1;
                }
                for (let c = 0; c < td.conditions.length; c++) tr.conditions.push(compileCondition(td.conditions[c], m));
                for (let a = 0; a < td.actions.length; a++) tr.actions.push(compileAction(td.actions[a], scene, m));
                layer.states[s].transitions.push(tr);
            }
            if (sd.transitions.length > layer.maxTransitions) layer.maxTransitions = sd.transitions.length;
        }
        if (layer.any >= 0) layer.anyTransitions = layer.states[layer.any].transitions;
        m.layers.push(layer);
    }
    prepareListeners(m, d, scene);
    return m;
}

function animationIndex(scene: SceneAnimations?, name: string): i32 {
    return scene != null && name.length > 0 ? scene.index(name) : -1;
}

function compileCondition(cd: ConditionDecl, m: StateMachine): SmCondition {
    const c = new SmCondition(cd);
    c.id = m.conditions.length;
    m.conditions.push(c);
    switch (cd.kind) {
        case ConditionKind.ViewModel:
            c.left = m.path(new SmPath(cd.path, cd.global, cd.converter));
            break;
        case ConditionKind.Component:
            c.target = cd.target;
            c.property = cd.property;
            break;
        case ConditionKind.Number: {
            c.input = m.inputOfKind(cd.input, InputKind.Number);
            const x = parseFloat(cd.value);
            c.number = isFinite(x) ? <f32>x : 0;
            break;
        }
        case ConditionKind.Bool:
            c.input = m.inputOfKind(cd.input, InputKind.Bool);
            break;
        default:
            c.input = m.inputOfKind(cd.input, InputKind.Trigger);
            break;
    }
    if ((cd.kind == ConditionKind.ViewModel || cd.kind == ConditionKind.Component) && cd.rightPath.length > 0) {
        c.right = m.path(new SmPath(cd.rightPath, cd.rightGlobal, cd.rightConverter));
    }
    return c;
}

function compileAction(ad: FireActionDecl, scene: SceneAnimations?, m: StateMachine): SmAction {
    const a = new SmAction(ad);
    if (ad.kind == ActionKind.FireEvent) {
        a.event = ad.event;
        a.eventDecl = scene != null ? scene.event(ad.event) : null;
    } else {
        a.trigger = m.path(new SmPath(ad.path, ad.global, ""));
    }
    return a;
}
