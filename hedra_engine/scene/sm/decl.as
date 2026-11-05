// Rive's state machines in a scene, as the file writes them (milestone 46,
// docs/plans/RIVE_MODEL.md sections 3.3 and 4; docs/formats/RSCN.md, "State
// machines"): the declarations the reader (../rscn/parse.as) fills, the
// validator (../rscn/validate.as, ./check.as) checks, the writer
// (engine/src/source/scene/rscn_write.as) prints, the binary scene carries
// (../rscnb/sm.as, the STMC section) and the editor edits. The engine
// prepares them (./machine.as) and never reads them per frame.
//
// The elements are RML's and take RML's attribute names; they differ from
// RML only in their references (RIVE_MODEL.md section 4.1) and in the
// compact condition forms of section 4.3: a state is named by `name` (Rive's
// states are anonymous; an AnimationState's default name is its
// animation's), a transition names the state it goes to by `to`, an
// animation, an event, an input or a converter is named by `name`, a node
// by its path from the scene's root, and a view model property by its path
// in the scene's data context (`path`, or a global's with `global`). RML's
// ids are absent.
//
//   <StateMachine name="Main">                          StateMachineDecl
//     <StateMachineNumber name="speed" value="0"/>      InputDecl
//     <StateMachineLayer name="Door">                   LayerDecl
//       <EntryState x="0" y="0">                        StateDecl (Entry)
//         <StateTransition to="Closed"/>                TransitionDecl
//       </EntryState>
//       <AnyState x="0" y="-120"/>
//       <ExitState x="600" y="-120"/>
//       <AnimationState animation="Close" x="200" y="0">    (named "Close")
//         <StateTransition to="Open" duration="150" interpolationType="cubic">
//           <CubicEaseInterpolator x1="0.42" y1="0" x2="0.58" y2="1"/>
//           <TransitionViewModelCondition path="door/open" opValue="equal" value="true"/>
//         </StateTransition>
//       </AnimationState>
//       <AnimationState animation="Open" x="400" y="0">
//         <StateMachineFireEvent event="Creak" occursValue="0"/>
//         <StateTransition to="Close" enableExitTime="true" exitTime="100"
//                          exitTimeIsPercentage="true">
//           <TransitionViewModelCondition path="door/open" opValue="equal" value="false"/>
//         </StateTransition>
//       </AnimationState>
//       <BlendState1DViewModel name="Walk" path="hero/speed" x="200" y="120">
//         <BlendAnimation1D animation="Idle" value="0"/>
//         <BlendAnimation1D animation="Run" value="100"/>
//       </BlendState1DViewModel>
//     </StateMachineLayer>
//   </StateMachine>
//
// Every field holds what the file says, defaults as Rive's (a transition
// interpolates linearly, a state's speed is 1, a direct blend's mix value
// 100). Numbers are kept as the f64 the text gave, so that text, binary and
// text again are the same bytes; the engine evaluates them as Rive's f32.
// A condition's literal (`value`) is kept as the text the file gave: its
// kind is the view model property's (or the input's, or the node
// property's), which only the data knows, so it is read when the machine is
// bound to data (./machine.as). Attributes and child elements this version
// does not know are kept in order (extraAttrs, extraChildren) and written
// back after the known ones. Milestone 47: a StateMachineListener is read
// into its machine's `listeners` (ListenerDecl, below); RML's folded
// StateMachineListenerSingle and the general form's ListenerInputType
// children are not .rscn's spelling and stay kept, unknown.
//
// Plain data with no behaviour but lookups: everything that checks,
// evaluates or edits lives elsewhere.

import { XmlAttr, XmlNode, XmlPos } from "../../base/xml";
import { BindingDecl } from "../rscn/doc";
import { InterpolationType, InterpolatorDecl } from "../anim/decl";

// The top-level element of a state machine, and its parts' elements.
export const STATE_MACHINE_ELEMENT = "StateMachine";
export const LAYER_ELEMENT = "StateMachineLayer";
export const TRANSITION_ELEMENT = "StateTransition";
export const BLEND_ANIMATION_1D_ELEMENT = "BlendAnimation1D";
export const BLEND_ANIMATION_DIRECT_ELEMENT = "BlendAnimationDirect";
// Rive's listeners (milestone 47: read into StateMachineDecl.listeners and
// run; the declarations are at the end of this file).
export const LISTENER_ELEMENT = "StateMachineListener";

// The node properties a state machine adds (classdb.as, on Node; RSCN.md
// "State machines"). On the scene's root: the machine it runs ("" the
// first it declares, "-" none). On a node that instances a scene (Rive's
// NestedArtboard): which of the instanced scene's machines runs ("" its
// default, "-" none), or one of its animations played instead
// (instance_animation, "" none), scrubbed rather than played when
// instance_animation_time is 0 to 1 (a fraction of its duration; below 0,
// the default -1, it plays), at instance_speed (default 1), held while
// instance_paused. The last three animate and bind. (RIVE_MODEL.md names
// them state_machine, animation, animation_time, speed and is_paused; on
// Node those names would shadow a script's exported properties of the same
// names, `speed` above all, so they take the instance_ prefix.)
export const DEFAULT_STATE_MACHINE_PROPERTY = "default_state_machine";
export const STATE_MACHINE_PROPERTY = "instance_state_machine";
export const ANIMATION_PROPERTY = "instance_animation";
export const ANIMATION_TIME_PROPERTY = "instance_animation_time";
export const SPEED_PROPERTY = "instance_speed";
export const IS_PAUSED_PROPERTY = "instance_paused";
// The value of default_state_machine or state_machine that runs none.
export const NO_STATE_MACHINE = "-";
// The instancing node's properties, in the class reference's order.
export const INSTANCE_PROPERTIES: StaticArray<string> = [
    STATE_MACHINE_PROPERTY, ANIMATION_PROPERTY, ANIMATION_TIME_PROPERTY, SPEED_PROPERTY, IS_PAUSED_PROPERTY,
];

// A layer's state, by its element (STATE_ELEMENTS, the same order). Entry,
// Any and Exit are Rive's EntryState, AnyState and ExitState, one of each
// in every layer; Animation plays one LinearAnimation (or holds, with
// none); the blend states mix several: along one number read from the view
// model (Blend1DViewModel) or from a number input (Blend1DInput), or each
// by its own weight (BlendDirect).
export enum StateKind {
    Entry = 0,
    Any = 1,
    Exit = 2,
    Animation = 3,
    Blend1DViewModel = 4,
    Blend1DInput = 5,
    BlendDirect = 6,
}

export const STATE_ELEMENTS: StaticArray<string> = [
    "EntryState", "AnyState", "ExitState", "AnimationState", "BlendState1DViewModel", "BlendState1DInput", "BlendStateDirect",
];

// The kind of a state element, or -1.
export function stateKindOf(tag: string): i32 {
    for (let i = 0; i < STATE_ELEMENTS.length; i++) if (STATE_ELEMENTS[i] == tag) return i;
    return -1;
}

// The names Entry, Any and Exit go by (a transition's `to="Exit"` goes to
// the layer's ExitState); no other state may take them.
export const STATE_SYSTEM_NAMES: StaticArray<string> = ["Entry", "Any", "Exit"];
export const EXIT_STATE_NAME = "Exit";

// Whether a state of kind `k` is one of the three every layer has.
export function isSystemState(k: StateKind): bool {
    return k == StateKind.Entry || k == StateKind.Any || k == StateKind.Exit;
}

// Whether a state of kind `k` blends several animations.
export function isBlendState(k: StateKind): bool {
    return k == StateKind.Blend1DViewModel || k == StateKind.Blend1DInput || k == StateKind.BlendDirect;
}

// A machine's input, by its element (INPUT_ELEMENTS, the same order):
// Rive's deprecated inputs, kept for parity (RIVE_MODEL.md section 3.3).
export enum InputKind {
    Number = 0,
    Bool = 1,
    Trigger = 2,
}

export const INPUT_ELEMENTS: StaticArray<string> = ["StateMachineNumber", "StateMachineBool", "StateMachineTrigger"];

// The kind of an input element, or -1.
export function inputKindOf(tag: string): i32 {
    for (let i = 0; i < INPUT_ELEMENTS.length; i++) if (INPUT_ELEMENTS[i] == tag) return i;
    return -1;
}

// A transition's condition, by its element (CONDITION_ELEMENTS, the same
// order), each the compact form of RIVE_MODEL.md section 4.3:
//
//   ViewModel   <TransitionViewModelCondition path global converter opValue
//                 value | rightPath rightGlobal rightConverter/>
//               a view model property against a literal or another one
//   Component   <TransitionComponentCondition target property opValue
//                 value | rightPath rightGlobal rightConverter/>
//               a node's readable property (an output too) against them
//   Number      <TransitionNumberCondition input opValue value/>
//   Bool        <TransitionBoolCondition input opValue/>    (equal: true)
//   Trigger     <TransitionTriggerCondition input/>         (fired)
export enum ConditionKind {
    ViewModel = 0,
    Component = 1,
    Number = 2,
    Bool = 3,
    Trigger = 4,
}

export const CONDITION_ELEMENTS: StaticArray<string> = [
    "TransitionViewModelCondition", "TransitionComponentCondition", "TransitionNumberCondition", "TransitionBoolCondition",
    "TransitionTriggerCondition",
];

// The kind of a condition element, or -1.
export function conditionKindOf(tag: string): i32 {
    for (let i = 0; i < CONDITION_ELEMENTS.length; i++) if (CONDITION_ELEMENTS[i] == tag) return i;
    return -1;
}

// Rive's TransitionConditionOp, its numbers and its names (RML's opValue
// words; the file writes the names).
export enum ConditionOp {
    Equal = 0,
    NotEqual = 1,
    LessThanOrEqual = 2,
    GreaterThanOrEqual = 3,
    LessThan = 4,
    GreaterThan = 5,
}

export const CONDITION_OP_NAMES: StaticArray<string> = [
    "equal", "notEqual", "lessThanOrEqual", "greaterThanOrEqual", "lessThan", "greaterThan",
];

// The operator named `name`, or -1.
export function conditionOpOf(name: string): i32 {
    for (let i = 0; i < CONDITION_OP_NAMES.length; i++) if (CONDITION_OP_NAMES[i] == name) return i;
    return -1;
}

// A state's or a transition's action, by its element (ACTION_ELEMENTS):
// Rive's StateMachineFireEvent (one of the scene's Events, by name) and
// StateMachineFireTrigger (a view model trigger, by path).
export enum ActionKind {
    FireEvent = 0,
    FireTrigger = 1,
}

export const ACTION_ELEMENTS: StaticArray<string> = ["StateMachineFireEvent", "StateMachineFireTrigger"];

// The kind of an action element, or -1.
export function actionKindOf(tag: string): i32 {
    for (let i = 0; i < ACTION_ELEMENTS.length; i++) if (ACTION_ELEMENTS[i] == tag) return i;
    return -1;
}

// When an action fires (Rive's occursValue, which RML writes as the
// number): as its state or transition starts, or as it ends.
export const OCCURS_AT_START: i32 = 0;
export const OCCURS_AT_END: i32 = 1;

// Where a BlendAnimationDirect's weight comes from (Rive's blendSource
// numbers). The file does not write it: the attributes say (`input` an
// input, `path` a view model number, otherwise `mixValue`).
export enum BlendSource {
    Input = 0,
    MixValue = 1,
    ViewModel = 2,
}

// One condition of a transition (see ConditionKind for which fields each
// kind reads). `value` is the literal as the file wrote it ("true", "80",
// "FF57A5E0", "open"; "" when absent: a right side given by `rightPath`, a
// Bool or Trigger condition).
export class ConditionDecl {
    kind: ConditionKind;
    op: ConditionOp = ConditionOp.Equal;
    // ViewModel: the left side's view model property, and the converter
    // its value goes through.
    path: string = "";
    global: string = "";
    converter: string = "";
    // Component: the node (a path from the scene's root, "." the root) and
    // its property, with subnames (rotation_degrees:y).
    target: string = "";
    property: string = "";
    // Number, Bool, Trigger: the machine's input.
    input: string = "";
    // The right side: a literal, or a view model property (rightPath, with
    // rightGlobal and rightConverter).
    value: string = "";
    hasValue: bool = false;
    rightPath: string = "";
    rightGlobal: string = "";
    rightConverter: string = "";
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(kind: ConditionKind) {
        this.kind = kind;
    }

    clone(): ConditionDecl {
        const c = new ConditionDecl(this.kind);
        c.op = this.op;
        c.path = this.path;
        c.global = this.global;
        c.converter = this.converter;
        c.target = this.target;
        c.property = this.property;
        c.input = this.input;
        c.value = this.value;
        c.hasValue = this.hasValue;
        c.rightPath = this.rightPath;
        c.rightGlobal = this.rightGlobal;
        c.rightConverter = this.rightConverter;
        c.extraAttrs = this.extraAttrs.slice(0);
        c.extraChildren = this.extraChildren.slice(0);
        return c;
    }
}

// `<StateMachineFireEvent event occursValue/>` or `<StateMachineFireTrigger
// path global occursValue/>`.
export class FireActionDecl {
    kind: ActionKind;
    event: string = "";
    path: string = "";
    global: string = "";
    occurs: i32 = OCCURS_AT_START;
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(kind: ActionKind) {
        this.kind = kind;
    }

    clone(): FireActionDecl {
        const c = new FireActionDecl(this.kind);
        c.event = this.event;
        c.path = this.path;
        c.global = this.global;
        c.occurs = this.occurs;
        c.extraAttrs = this.extraAttrs.slice(0);
        c.extraChildren = this.extraChildren.slice(0);
        return c;
    }
}

// `<StateTransition to duration exitTime interpolationType randomWeight
// disabled durationIsPercentage enableExitTime exitTimeIsPercentage
// pauseOnExit enableEarlyExit>`, with its interpolator, conditions and
// actions. `duration` and `exitTime` are milliseconds, or percent of the
// state's animation with their flags (Rive's uint32s). RML spells the exit
// time's flag `exitTimeIsPercetange`; the reader takes that spelling too,
// and the writer writes `exitTimeIsPercentage`.
export class TransitionDecl {
    // The state it goes to, by name ("Exit" the layer's ExitState).
    to: string;
    duration: i32 = 0;
    exitTime: i32 = 0;
    // Rive's default for a transition is linear (a keyframe's is hold).
    interpolation: InterpolationType = InterpolationType.Linear;
    interpolator: InterpolatorDecl? = null;
    randomWeight: i32 = 1;
    disabled: bool = false;
    durationIsPercentage: bool = false;
    enableExitTime: bool = false;
    exitTimeIsPercentage: bool = false;
    pauseOnExit: bool = false;
    enableEarlyExit: bool = false;
    conditions: Array<ConditionDecl> = [];
    actions: Array<FireActionDecl> = [];
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(to: string) {
        this.to = to;
    }

    clone(): TransitionDecl {
        const c = new TransitionDecl(this.to);
        c.duration = this.duration;
        c.exitTime = this.exitTime;
        c.interpolation = this.interpolation;
        const ip = this.interpolator;
        c.interpolator = ip != null ? ip.clone() : null;
        c.randomWeight = this.randomWeight;
        c.disabled = this.disabled;
        c.durationIsPercentage = this.durationIsPercentage;
        c.enableExitTime = this.enableExitTime;
        c.exitTimeIsPercentage = this.exitTimeIsPercentage;
        c.pauseOnExit = this.pauseOnExit;
        c.enableEarlyExit = this.enableEarlyExit;
        for (let i = 0; i < this.conditions.length; i++) c.conditions.push(this.conditions[i].clone());
        for (let i = 0; i < this.actions.length; i++) c.actions.push(this.actions[i].clone());
        c.extraAttrs = this.extraAttrs.slice(0);
        c.extraChildren = this.extraChildren.slice(0);
        return c;
    }
}

// `<BlendAnimation1D animation value/>` or `<BlendAnimationDirect animation
// mixValue | input | path global converter/>`: one animation of a blend
// state, and where it sits (1D: `value` on the state's axis, 0 to 100 as
// Rive's) or how strongly it mixes (direct: `source`).
export class BlendAnimationDecl {
    // Whether it is a BlendAnimationDirect (else a BlendAnimation1D).
    direct: bool;
    animation: string;
    value: f64 = 0;
    source: BlendSource = BlendSource.MixValue;
    mixValue: f64 = 100;
    input: string = "";
    path: string = "";
    global: string = "";
    converter: string = "";
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(direct: bool, animation: string) {
        this.direct = direct;
        this.animation = animation;
    }

    clone(): BlendAnimationDecl {
        const c = new BlendAnimationDecl(this.direct, this.animation);
        c.value = this.value;
        c.source = this.source;
        c.mixValue = this.mixValue;
        c.input = this.input;
        c.path = this.path;
        c.global = this.global;
        c.converter = this.converter;
        c.extraAttrs = this.extraAttrs.slice(0);
        c.extraChildren = this.extraChildren.slice(0);
        return c;
    }
}

// One state of a layer (StateKind says which fields it reads): its name
// (`name`, "" when the file gave none: then displayName()), its place on
// the editor's graph (x, y), Rive's `speed` and the `reset` and `random`
// flags, an AnimationState's `animation` ("" holds), a 1D blend's number
// (`path` and `global` and `converter`, or `input`), a blend's animations,
// its transitions and its actions, in file order.
export class StateDecl {
    kind: StateKind;
    name: string = "";
    x: f64 = 0;
    y: f64 = 0;
    animation: string = "";
    speed: f64 = 1;
    reset: bool = false;
    random: bool = false;
    path: string = "";
    global: string = "";
    converter: string = "";
    input: string = "";
    blends: Array<BlendAnimationDecl> = [];
    transitions: Array<TransitionDecl> = [];
    actions: Array<FireActionDecl> = [];
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(kind: StateKind) {
        this.kind = kind;
    }

    // What the state is called: its name; else Entry, Any or Exit for
    // those; else an AnimationState's animation (RIVE_MODEL.md section
    // 4.1: "the default name is the animation's"); else "".
    displayName(): string {
        if (this.name.length > 0) return this.name;
        if (isSystemState(this.kind)) return STATE_SYSTEM_NAMES[<i32>this.kind];
        if (this.kind == StateKind.Animation) return this.animation;
        return "";
    }

    // The transition to `to`, the first of them, or null.
    transitionTo(to: string): TransitionDecl? {
        for (let i = 0; i < this.transitions.length; i++) if (this.transitions[i].to == to) return this.transitions[i];
        return null;
    }

    clone(): StateDecl {
        const c = new StateDecl(this.kind);
        c.name = this.name;
        c.x = this.x;
        c.y = this.y;
        c.animation = this.animation;
        c.speed = this.speed;
        c.reset = this.reset;
        c.random = this.random;
        c.path = this.path;
        c.global = this.global;
        c.converter = this.converter;
        c.input = this.input;
        for (let i = 0; i < this.blends.length; i++) c.blends.push(this.blends[i].clone());
        for (let i = 0; i < this.transitions.length; i++) c.transitions.push(this.transitions[i].clone());
        for (let i = 0; i < this.actions.length; i++) c.actions.push(this.actions[i].clone());
        c.extraAttrs = this.extraAttrs.slice(0);
        c.extraChildren = this.extraChildren.slice(0);
        return c;
    }
}

// `<StateMachineLayer name>` and its states, in file order.
export class LayerDecl {
    name: string;
    states: Array<StateDecl> = [];
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(name: string) {
        this.name = name;
    }

    // The state called `name` (displayName), or null.
    state(name: string): StateDecl? {
        for (let i = 0; i < this.states.length; i++) if (this.states[i].displayName() == name) return this.states[i];
        return null;
    }

    // The index of the state called `name`, or -1.
    stateIndex(name: string): i32 {
        for (let i = 0; i < this.states.length; i++) if (this.states[i].displayName() == name) return i;
        return -1;
    }

    // The first state of kind `k` (Entry, Any, Exit), or null.
    stateOfKind(k: StateKind): StateDecl? {
        for (let i = 0; i < this.states.length; i++) if (this.states[i].kind == k) return this.states[i];
        return null;
    }
}

// `<StateMachineNumber name value/>`, `<StateMachineBool name value/>` or
// `<StateMachineTrigger name/>`, and its bindings (`<binding
// property="value" path="..."/>`: the input follows a view model property,
// RIVE_MODEL.md section 7).
export class InputDecl {
    kind: InputKind;
    name: string;
    number: f64 = 0;
    boolean: bool = false;
    bindings: Array<BindingDecl> = [];
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(kind: InputKind, name: string) {
        this.kind = kind;
        this.name = name;
    }
}

// `<StateMachine name>`: its inputs, then its layers (in the order they
// mix: a later layer over an earlier one), then its listeners (milestone
// 47), then what this version keeps without knowing.
export class StateMachineDecl {
    name: string;
    inputs: Array<InputDecl> = [];
    layers: Array<LayerDecl> = [];
    listeners: Array<ListenerDecl> = [];
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(name: string) {
        this.name = name;
    }

    // The layer `name`, or null.
    layer(name: string): LayerDecl? {
        for (let i = 0; i < this.layers.length; i++) if (this.layers[i].name == name) return this.layers[i];
        return null;
    }

    // The input `name`, or null.
    input(name: string): InputDecl? {
        for (let i = 0; i < this.inputs.length; i++) if (this.inputs[i].name == name) return this.inputs[i];
        return null;
    }

    // The listener `name`, or null.
    listener(name: string): ListenerDecl? {
        for (let i = 0; i < this.listeners.length; i++) if (this.listeners[i].name == name) return this.listeners[i];
        return null;
    }
}

// A new layer as Rive's editor makes one: Entry, Any and Exit, at Rive's
// places (the editor's New Layer; the reader never adds them).
export function newLayerDecl(name: string): LayerDecl {
    const l = new LayerDecl(name);
    const entry = new StateDecl(StateKind.Entry);
    const any = new StateDecl(StateKind.Any);
    any.y = -120;
    const exit = new StateDecl(StateKind.Exit);
    exit.x = 600;
    exit.y = -120;
    l.states.push(entry);
    l.states.push(any);
    l.states.push(exit);
    return l;
}

// ---------------------------------------------------------------------------
// Milestone 47: listeners (docs/plans/RIVE_MODEL.md sections 3.5 and 4.3;
// docs/engine/STATE_MACHINES.md "Listeners"; RSCN.md "State machines").
// A listener belongs to its machine and runs while the machine runs: a
// pointer listener hears the pointer over its target node (a mesh by its
// triangles, a collision object by its shapes, any other node by whatever
// of those is under it: Rive's group), an event listener an event of its
// scene or of a scene under it, a view model listener a change of a view
// model property; each performs its actions in order. The compact form:
//
//   <StateMachineListener name="Knock" target="Door" listenerType="click">
//     <ListenerViewModelChange path="open" fromPath="open" converter="Not"/>
//     <ListenerFireEvent event="Creak"/>
//   </StateMachineListener>
//   <StateMachineListener name="Aim" target="Floor" listenerType="drag">
//     <ListenerAlignTarget target="Cursor" surface="true"/>
//     <ListenerViewModelChange path="aim/x" input="hitX"/>
//   </StateMachineListener>
//   <StateMachineListener name="Heard" listenerType="event" event="Creak">...
//   <StateMachineListener name="Pressed" listenerType="viewModel" path="button/pressed">...

// Rive's ListenerType numbers (include/rive/listener_type.hpp): the index
// into LISTENER_TYPE_NAMES is the number. componentProvided, textInput,
// focus, blur, keyboard, semanticAction and gamepad are Rive's but not
// 3D's (listenerTypeOf refuses them: attribute-invalid).
export enum ListenerType {
    Enter = 0,
    Exit = 1,
    Down = 2,
    Up = 3,
    Move = 4,
    Event = 5,
    Click = 6,
    DragStart = 9,
    DragEnd = 10,
    ViewModel = 11,
    Drag = 12,
}

export const LISTENER_TYPE_NAMES: StaticArray<string> = [
    "enter", "exit", "down", "up", "move", "event", "click", "componentProvided", "textInput", "dragStart", "dragEnd",
    "viewModel", "drag",
];

// The type named `name` when 3D runs it (enter, exit, down, up, move,
// event, click, dragStart, dragEnd, viewModel, drag), or -1.
export function listenerTypeOf(name: string): i32 {
    for (let i = 0; i < LISTENER_TYPE_NAMES.length; i++) {
        if (LISTENER_TYPE_NAMES[i] != name) continue;
        return i == 7 || i == 8 ? -1 : i;
    }
    return -1;
}

// Whether a listener of type `t` hears the pointer (it has a target and
// hit inputs): every type but event and viewModel.
export function isPointerListenerType(t: ListenerType): bool {
    return t != ListenerType.Event && t != ListenerType.ViewModel;
}

// A listener's action, by its element (LISTENER_ACTION_ELEMENTS, the same
// order), each Rive's in the compact form:
//
//   ViewModelChange  <ListenerViewModelChange path global (value | fromPath
//                     fromGlobal | input) converter/>: writes a view model
//                     property (a literal, another property, or a pointer
//                     input; a trigger with none of them is fired)
//   BoolChange       <ListenerBoolChange input value/>    value true, false, toggle
//   NumberChange     <ListenerNumberChange input value/>
//   TriggerChange    <ListenerTriggerChange input/>
//   FireEvent        <ListenerFireEvent event/>
//   AlignTarget      <ListenerAlignTarget target surface preserveOffset/>
export enum ListenerActionKind {
    ViewModelChange = 0,
    BoolChange = 1,
    NumberChange = 2,
    TriggerChange = 3,
    FireEvent = 4,
    AlignTarget = 5,
}

export const LISTENER_ACTION_ELEMENTS: StaticArray<string> = [
    "ListenerViewModelChange", "ListenerBoolChange", "ListenerNumberChange", "ListenerTriggerChange", "ListenerFireEvent",
    "ListenerAlignTarget",
];

// The kind of a listener action element, or -1.
export function listenerActionKindOf(tag: string): i32 {
    for (let i = 0; i < LISTENER_ACTION_ELEMENTS.length; i++) if (LISTENER_ACTION_ELEMENTS[i] == tag) return i;
    return -1;
}

// ListenerBoolChange's value: Rive's numbers (0 false, 1 true, 2 toggle),
// written by name.
export const BOOL_CHANGE_FALSE: i32 = 0;
export const BOOL_CHANGE_TRUE: i32 = 1;
export const BOOL_CHANGE_TOGGLE: i32 = 2;
export const BOOL_CHANGE_NAMES: StaticArray<string> = ["false", "true", "toggle"];

// The pointer inputs a ListenerViewModelChange may write (`input`), the 3D
// counterparts of Rive's pointer inputs: the hit point and its normal in
// the scene's space (metres; Y up), the hit's texture coordinates (UV set
// 0; 0 for a collision shape), the pointer in the picture (pixels from its
// top-left corner) and its move since the listener's last event for that
// pointer (pixels). On a listener that is no pointer listener each reads 0.
export enum PointerInput {
    HitX = 0,
    HitY = 1,
    HitZ = 2,
    HitNormalX = 3,
    HitNormalY = 4,
    HitNormalZ = 5,
    HitU = 6,
    HitV = 7,
    ScreenX = 8,
    ScreenY = 9,
    DeltaX = 10,
    DeltaY = 11,
}

export const POINTER_INPUT_NAMES: StaticArray<string> = [
    "hitX", "hitY", "hitZ", "hitNormalX", "hitNormalY", "hitNormalZ", "hitU", "hitV", "screenX", "screenY", "deltaX",
    "deltaY",
];

// The pointer input named `name`, or -1.
export function pointerInputOf(name: string): i32 {
    for (let i = 0; i < POINTER_INPUT_NAMES.length; i++) if (POINTER_INPUT_NAMES[i] == name) return i;
    return -1;
}

// How many pointers (pointer ids) a listener tracks at once (Rive keeps a
// map; 3D keeps a fixed pool so that the pointer allocates nothing). A new
// pointer when every slot is held takes the slot of the pointer heard
// least recently, which hears its exit first (a touch host that sends a
// release without an exit for each finger never runs out).
export const LISTENER_MAX_POINTERS: i32 = 4;

// The node properties listeners read (classdb.as; RSCN.md "Listeners"):
// a GeometryInstance3D is hit by its triangles while input_ray_pickable
// (true unless set false: a mesh in front of a target hides it); a hit on a
// node with listener_pass_through (or under one) lets the pointer go on to
// what is behind it (3D's hits are opaque by default, Rive's 2D ones are
// not); a GeometryInstance3D showing an ArtboardTexture (or an
// ArtboardSprite3D) passes the pointer on to that artboard's state machine
// at the hit's texture coordinates while pointer_forward (true unless set
// false).
export const INPUT_RAY_PICKABLE_PROPERTY = "input_ray_pickable";
export const LISTENER_PASS_THROUGH_PROPERTY = "listener_pass_through";
export const POINTER_FORWARD_PROPERTY = "pointer_forward";

// One action of a listener (see ListenerActionKind for the fields each
// kind reads). `value` is the literal as the file wrote it ("" when
// absent); its kind is the property's or the input's.
export class ListenerActionDecl {
    kind: ListenerActionKind;
    // ViewModelChange: the property written (path, global) and its source
    // (one of value, fromPath/fromGlobal, input; none: fire a trigger), the
    // converter the source goes through.
    path: string = "";
    global: string = "";
    value: string = "";
    hasValue: bool = false;
    fromPath: string = "";
    fromGlobal: string = "";
    // A POINTER_INPUT_NAMES name for ViewModelChange; the machine's input
    // for the Bool, Number and Trigger changes.
    input: string = "";
    converter: string = "";
    // FireEvent: the scene's event.
    event: string = "";
    // AlignTarget: the node moved (a path from the scene's root, "." the
    // root), onto the hit surface (`surface`) or along the plane through it
    // facing the camera, keeping the offset it was grabbed at
    // (`preserveOffset`).
    target: string = "";
    surface: bool = false;
    preserveOffset: bool = false;
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(kind: ListenerActionKind) {
        this.kind = kind;
    }

    clone(): ListenerActionDecl {
        const c = new ListenerActionDecl(this.kind);
        c.path = this.path;
        c.global = this.global;
        c.value = this.value;
        c.hasValue = this.hasValue;
        c.fromPath = this.fromPath;
        c.fromGlobal = this.fromGlobal;
        c.input = this.input;
        c.converter = this.converter;
        c.event = this.event;
        c.target = this.target;
        c.surface = this.surface;
        c.preserveOffset = this.preserveOffset;
        c.extraAttrs = this.extraAttrs.slice(0);
        c.extraChildren = this.extraChildren.slice(0);
        return c;
    }
}

// `<StateMachineListener name target listenerType event path global>` and
// its actions, in file order. `target` is a node path from the scene's root
// ("." the root: anything of the scene); a pointer listener needs one. An
// event listener names its event (`event`), a view model listener its
// property (`path`, `global`).
export class ListenerDecl {
    name: string;
    type: ListenerType = ListenerType.Click;
    target: string = "";
    event: string = "";
    path: string = "";
    global: string = "";
    actions: Array<ListenerActionDecl> = [];
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(name: string) {
        this.name = name;
    }

    clone(): ListenerDecl {
        const c = new ListenerDecl(this.name);
        c.type = this.type;
        c.target = this.target;
        c.event = this.event;
        c.path = this.path;
        c.global = this.global;
        for (let i = 0; i < this.actions.length; i++) c.actions.push(this.actions[i].clone());
        c.extraAttrs = this.extraAttrs.slice(0);
        c.extraChildren = this.extraChildren.slice(0);
        return c;
    }
}
