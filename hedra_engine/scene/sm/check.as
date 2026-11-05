// The validator's checks of a scene's state machines (docs/formats/RSCN.md,
// "State machines"; docs/plans/RIVE_MODEL.md sections 3.3 and 4): what one
// <StateMachine> must satisfy beyond its syntax, found from the document
// alone, and what the state machine's node properties must. ../rscn/
// validate.as calls SmChecker.stateMachine for each such entry, in document
// order, and checkStateMachineProperty for each such property of a node,
// and sorts each entry's problems by position.
//
// What only the data can tell (a view model path, a global, a converter, a
// condition's literal against its property's kind, an input's binding) is
// checked when a machine is bound to its data (./scene_machines.as
// stateMachineDataDiagnostics), and an instanced scene's machines and
// animations when it is instanced: a file alone does not know them. A
// condition's node target is checked as a key's is (../anim/check.as): as
// far as the file can tell.
//
// Milestone 47: a machine's listeners (RSCN.md "Listeners"): unique names,
// what each type reads (a pointer listener's target, an event listener's
// event, a viewModel listener's path; what it does not read warned of),
// and their actions (one source a view model change, the machine's inputs
// of the right kind, the scene's events, the align target's node). A
// listener's view model paths, globals, converters and literals are the
// data's, checked as the conditions' are (stateMachineDataDiagnostics).
//
// Positions: a declaration keeps its element's position only, so every
// problem is reported at the element that has it (an unknown attribute at
// the attribute).

import { XmlAttr, XmlKind, XmlNode, XmlPos } from "../../base/xml";
import { Diagnostic, Severity } from "../error";
import { classInfo, isA } from "../classdb";
import { NodeDecl, Property, RscnDoc } from "../rscn/doc";
import { findBindingTarget } from "../binding/targets";
import { rmlNumberOf } from "../data/rml_read";
import { ValueKind } from "../value";
import { AnimChecker } from "../anim/check";
import { splitImportedClipLabel } from "../skeleton/names";
import { INTERPOLATION_NAMES, INTERPOLATOR_ELEMENTS, InterpolationType, InterpolatorDecl, InterpolatorKind, finiteAsF32 } from "../anim/decl";
import {
    ACTION_ELEMENTS, ActionKind, BLEND_ANIMATION_1D_ELEMENT, BLEND_ANIMATION_DIRECT_ELEMENT, BlendAnimationDecl, BlendSource,
    CONDITION_ELEMENTS, CONDITION_OP_NAMES, ConditionDecl, ConditionKind, ConditionOp, DEFAULT_STATE_MACHINE_PROPERTY,
    FireActionDecl, INPUT_ELEMENTS, INSTANCE_PROPERTIES, InputDecl, InputKind, LAYER_ELEMENT, LISTENER_ACTION_ELEMENTS,
    LISTENER_ELEMENT, LISTENER_TYPE_NAMES, LayerDecl, ListenerActionDecl, ListenerActionKind, ListenerDecl, ListenerType,
    NO_STATE_MACHINE, STATE_ELEMENTS, STATE_MACHINE_ELEMENT, STATE_SYSTEM_NAMES, StateDecl, StateKind, StateMachineDecl,
    TRANSITION_ELEMENT, TransitionDecl, isPointerListenerType, isSystemState,
} from "./decl";
import { CLI } from "../../base/names";

// Milestone 47: the codes of a listener's and an align action's target
// naming no node (the load's checks of a path into an instanced scene
// report the first as a warning, ./scene_machines.as).
export const LISTENER_TARGET_UNKNOWN_CODE = "listener-target-unknown";
export const LISTENER_ACTION_TARGET_UNKNOWN_CODE = "listener-action-target-unknown";

const KEPT_HINT = "it is kept and written back unchanged, and otherwise ignored";
const FORMAT_FEATURE_HINT = "write format=\"2\" on <rscn> (" + CLI + " format writes the version a file needs)";
const LISTENER_HINT = "write a listener as <StateMachineListener name=\"...\" target=\"...\" listenerType=\"...\">, one type a "
    + "listener (RML's folded StateMachineListenerSingle is not read): it is kept and written back, and not run";
const LISTENER_PART_HINT = "a listener holds its actions (ListenerViewModelChange, ListenerBoolChange, ListenerNumberChange, "
    + "ListenerTriggerChange, ListenerFireEvent, ListenerAlignTarget) and takes its one type from listenerType; Rive's "
    + "ListenerInputType children and scripted actions are kept and written back, and not run";
const LISTENER_NAME_HINT = "a listener is shown and edited by its name: give each listener of a machine its own";
const LISTENER_TARGET_HINT = "a pointer listener hears the pointer over its target, a node path from the root: \".\" (the root, "
    + "anything of the scene), \"Door\", \"Hinge/Panel\"";
const LISTENER_UNPICKABLE_HINT = "the pointer hits a GeometryInstance3D by its triangles and a CollisionObject3D by its shapes, the "
    + "target itself or one under it: target such a node, or a node holding one";
const LISTENER_EVENT_HINT = "an event listener hears an event of its scene, or of a scene under its target: <StateMachineListener "
    + "name=\"...\" listenerType=\"event\" event=\"Creak\">";
const LISTENER_PATH_HINT = "a viewModel listener performs when the view model property at its path changes: <StateMachineListener "
    + "name=\"...\" listenerType=\"viewModel\" path=\"button/pressed\">";
const LISTENER_IGNORED_HINT = "target is read by pointer and event listeners, event by event listeners, path and global by viewModel "
    + "listeners: it is kept and written back, and otherwise ignored";
const LISTENER_SOURCE_HINT = "a ListenerViewModelChange writes one source: a literal (value), another property (fromPath, with "
    + "fromGlobal), or a pointer input (input); none fires a trigger";
const LISTENER_INPUT_KIND_HINT = "ListenerBoolChange sets a StateMachineBool, ListenerNumberChange a StateMachineNumber, "
    + "ListenerTriggerChange fires a StateMachineTrigger";
const LISTENER_POINTER_HINT = "only a pointer listener has a hit: on an event or viewModel listener a pointer input reads 0 and "
    + "ListenerAlignTarget does nothing";
const LISTENER_ALIGN_HINT = "ListenerAlignTarget moves a node, named by its path from the root: \".\" (the root), \"Cursor\"";
const LAYER_STATES_HINT = "every layer holds one EntryState, one AnyState and one ExitState, as in Rive (the editor's New Layer "
    + "adds them)";
const STATE_NAME_HINT = "a state is named by `name` (an AnimationState by its animation when it has none): give each state of a "
    + "layer its own name";
const RESERVED_HINT = "Entry, Any and Exit name the layer's own three states: give the state another name";
const TARGET_HINT = "a transition goes to a state of its layer, by name, or to Exit";
const TARGET_INVALID_HINT = "a transition goes to an AnimationState, a blend state or Exit: the machine starts at Entry, and "
    + "Any State is where transitions taken from any state start";
const INTERPOLATOR_HINT = "the interpolator child decides the curve (as in Rive): cubic takes a CubicEaseInterpolator, cubicValue a "
    + "CubicValueInterpolator, elastic an ElasticInterpolator, hold and linear none";
const BLEND_ORDER_HINT = "Rive binary-searches a 1D blend's animations by value: write them in ascending value order";
const BLEND_SOURCE_HINT = "a BlendAnimationDirect takes its weight from one source: input (a number input), path (a view model "
    + "number) or mixValue (a constant, 100 when left out)";
const INPUT_KIND_HINT = "TransitionNumberCondition reads a StateMachineNumber, TransitionBoolCondition a StateMachineBool, "
    + "TransitionTriggerCondition a StateMachineTrigger; a blend reads a StateMachineNumber";
const VALUE_HINT = "compare with a literal (value=\"80\") or with another view model property (rightPath=\"limit\")";
const BOTH_HINT = "a condition's right side is a literal (value) or a view model property (rightPath), not both";
const BOOL_OP_HINT = "a TransitionBoolCondition passes on equal (the input is true) or notEqual (it is false)";
const TRIGGER_OP_HINT = "a TransitionTriggerCondition passes when its trigger fired since the layer last used it: it takes no opValue";
const CONDITION_TARGET_HINT = "a condition's target is a node path from the root: \".\" (the root), \"Door\", \"Arm/Hand\"";
const CONDITION_PROPERTY_HINT = "a TransitionComponentCondition reads a property its node's class can bind (docs/formats/RSCN.md, "
    + "\"Targets and flags\"), an output among them";
const DEFAULT_SM_HINT = "default_state_machine names one of the scene's state machines, \"\" for the first it declares, or - for none";
const DEFAULT_SM_ROOT_HINT = "only the scene's root chooses the machine it runs: a node that instances a scene chooses the instanced "
    + "scene's with instance_state_machine";
const INSTANCE_HINT = "the instance_ properties go on a node that instances a scene (instance=\"ExtResource(...)\"): they choose and "
    + "drive that scene's state machine or animation";
const F32_HINT = "keep the number between -3.4e38 and 3.4e38";

// " (first at line N)" when the earlier position is known, else "".
function firstAt(p: XmlPos): string {
    return p.line > 0 ? " (first at line " + p.line.toString() + ")" : "";
}

// Why a target path is malformed, or "" (as a keyed target's: ../anim/check.as).
function pathProblem(path: string): string {
    if (path.length == 0) return "it is empty";
    if (path == ".") return "";
    if (path.startsWith("/")) return "it starts with \"/\" (paths are relative to the root)";
    if (path.endsWith("/")) return "it ends with \"/\"";
    const segs = path.split("/");
    for (let i = 0; i < segs.length; i++) {
        const s = segs[i];
        if (s.length == 0) return "it has an empty segment";
        if (s == "..") return "\"..\" is not allowed";
        if (s == ".") return "\".\" may only stand alone, for the root";
        if (s.includes(".")) return "segment \"" + s + "\" holds a \".\", which no name may";
    }
    return "";
}

// The interpolator kind an interpolation type takes, or -1 for none.
function interpolatorOf(t: InterpolationType): i32 {
    if (t == InterpolationType.Cubic) return <i32>InterpolatorKind.CubicEase;
    if (t == InterpolationType.CubicValue) return <i32>InterpolatorKind.CubicValue;
    if (t == InterpolationType.Elastic) return <i32>InterpolatorKind.Elastic;
    return -1;
}

// Whether an element kept in a machine is one of Rive's listeners in a
// spelling .rscn does not read (RML's folded StateMachineListenerSingle:
// the reader reads every <StateMachineListener>).
function isListener(n: XmlNode): bool {
    return n.kind == XmlKind.Element && n.name.startsWith(LISTENER_ELEMENT);
}

// Whether an element kept in a listener is one of Rive's listener parts
// .rscn does not run (a general form's ListenerInputType children, a
// ScriptedListenerAction).
function isListenerPart(n: XmlNode): bool {
    return n.kind == XmlKind.Element && (n.name.startsWith("ListenerInputType") || n.name == "ScriptedListenerAction");
}

// "a <Tag>" or "an <Tag>", as English reads the element's name.
function aTag(tag: string): string {
    const c = tag.length > 0 ? tag.charAt(0) : "";
    return (c == "A" || c == "E" || c == "I" || c == "O" || c == "U" ? "an <" : "a <") + tag + ">";
}

// "a, b and c", or "none".
function nameList(names: Array<string>): string {
    if (names.length == 0) return "none";
    if (names.length == 1) return names[0];
    return names.slice(0, names.length - 1).join(", ") + " and " + names[names.length - 1];
}

// Whether a direct blend's weight has more than one source (its source's
// attribute and another one set).
export function blendSourceAmbiguous(b: BlendAnimationDecl): bool {
    let n = 0;
    if (b.source == BlendSource.Input || b.input.length > 0) n++;
    if (b.source == BlendSource.ViewModel || b.path.length > 0) n++;
    if (b.mixValue != 100) n++;
    // (one the reader kept as written: a mixValue of 100 or an empty path
    // beside another source)
    for (let i = 0; i < b.extraAttrs.length; i++) {
        const name = b.extraAttrs[i].name;
        if (b.direct && (name == "mixValue" || name == "path" || name == "input")) n++;
    }
    return n > 1;
}

// The checks of a document's state machines. One per validation: made at
// the first machine, then `stateMachine` for each in document order, each
// adding its problems to `out` (the validator sorts and flushes them).
export class SmChecker {
    doc: RscnDoc;
    file: string;
    out: Array<Diagnostic>;
    machines: Map<string, XmlPos> = new Map<string, XmlPos>();
    animationNames: Set<string> = new Set<string>();
    eventNames: Set<string> = new Set<string>();
    // The node paths the file declares (a timeline checker's: its
    // `resolve` tells a condition's target as it tells a key's).
    paths: AnimChecker;

    constructor(doc: RscnDoc, out: Array<Diagnostic>) {
        this.doc = doc;
        this.file = doc.file;
        this.out = out;
        const anims = doc.animations();
        for (let i = 0; i < anims.length; i++) this.animationNames.add(anims[i].name);
        const events = doc.events();
        for (let i = 0; i < events.length; i++) this.eventNames.add(events[i].name);
        this.paths = new AnimChecker(doc, new Array<Diagnostic>());
    }

    error(p: XmlPos, code: string, message: string, hint: string? = null): void {
        this.out.push(new Diagnostic(Severity.Error, code, this.file, p.line, p.col, message, hint));
    }

    warning(p: XmlPos, code: string, message: string, hint: string? = null): void {
        this.out.push(new Diagnostic(Severity.Warning, code, this.file, p.line, p.col, message, hint));
    }

    // (`sources`: a direct blend's, whose kept second source is
    // blend-source-ambiguous rather than unknown)
    unknownAttrs(attrs: Array<XmlAttr>, element: string, sources: bool = false): void {
        for (let i = 0; i < attrs.length; i++) {
            const a = attrs[i];
            if (sources && (a.name == "mixValue" || a.name == "path" || a.name == "input")) continue;
            this.warning(a.pos.isKnown() ? a.pos : a.valuePos, "attribute-unknown", "unknown attribute \"" + a.name + "\" on <" + element + ">",
                KEPT_HINT);
        }
    }

    unknownChildren(children: Array<XmlNode>, where: string): void {
        for (let i = 0; i < children.length; i++) {
            const n = children[i];
            if (n.kind == XmlKind.Element) {
                this.warning(n.pos, "element-unknown", "unknown element <" + n.name + "> in <" + where + ">", KEPT_HINT);
            } else if (n.kind == XmlKind.Pi) {
                this.warning(n.pos, "element-unknown", "unknown processing instruction <?" + n.name + "?> in <" + where + ">", KEPT_HINT);
            }
        }
    }

    // A number the engine reads as an f32.
    f32(p: XmlPos, v: f64, what: string): void {
        if (finiteAsF32(v)) return;
        this.error(p, "attribute-invalid", what + " " + v.toString() + " is beyond what a 32-bit float holds", F32_HINT);
    }

    // --- <StateMachine>

    stateMachine(d: StateMachineDecl): void {
        if (this.doc.format < 2) {
            this.error(d.pos, "format-feature", "the state machine <StateMachine name=\"" + d.name + "\"> needs format 2: this file is format "
                + this.doc.format.toString(), FORMAT_FEATURE_HINT);
        }
        if (this.machines.has(d.name)) {
            this.error(d.pos, "state-machine-name-duplicate", "state machine \"" + d.name + "\" is declared twice"
                + firstAt(this.machines.get(d.name)), "a scene's state machines are named, and the root, an instancing node or a "
                + "script chooses one by its name: give each its own");
        } else {
            this.machines.set(d.name, d.pos);
        }
        this.unknownAttrs(d.extraAttrs, STATE_MACHINE_ELEMENT);
        for (let i = 0; i < d.extraChildren.length; i++) {
            const n = d.extraChildren[i];
            if (isListener(n)) {
                this.warning(n.pos, "state-machine-listener-unsupported", "state machine \"" + d.name + "\"'s <" + n.name
                    + "> is not read", LISTENER_HINT);
            } else if (n.kind == XmlKind.Element) {
                this.warning(n.pos, "element-unknown", "unknown element <" + n.name + "> in <" + STATE_MACHINE_ELEMENT + ">", KEPT_HINT);
            } else if (n.kind == XmlKind.Pi) {
                this.warning(n.pos, "element-unknown", "unknown processing instruction <?" + n.name + "?> in <" + STATE_MACHINE_ELEMENT + ">",
                    KEPT_HINT);
            }
        }
        const inputs = new Map<string, XmlPos>();
        for (let i = 0; i < d.inputs.length; i++) {
            const input = d.inputs[i];
            if (inputs.has(input.name)) {
                this.error(input.pos, "input-name-duplicate", "state machine \"" + d.name + "\" declares input \"" + input.name + "\" twice"
                    + firstAt(inputs.get(input.name)), "conditions and blends name an input: give each its own name");
            } else {
                inputs.set(input.name, input.pos);
            }
            this.input(input);
        }
        const layers = new Map<string, XmlPos>();
        for (let i = 0; i < d.layers.length; i++) {
            const l = d.layers[i];
            if (layers.has(l.name)) {
                this.error(l.pos, "layer-name-duplicate", "state machine \"" + d.name + "\" has two layers named \"" + l.name + "\""
                    + firstAt(layers.get(l.name)), "a state is shown as layer/state: give each layer its own name");
            } else {
                layers.set(l.name, l.pos);
            }
            this.layer(d, l);
        }
        const listeners = new Map<string, XmlPos>();
        for (let i = 0; i < d.listeners.length; i++) {
            const l = d.listeners[i];
            if (listeners.has(l.name)) {
                this.error(l.pos, "listener-name-duplicate", "state machine \"" + d.name + "\" has two listeners named \"" + l.name + "\""
                    + firstAt(listeners.get(l.name)), LISTENER_NAME_HINT);
            } else {
                listeners.set(l.name, l.pos);
            }
            this.listener(d, l);
        }
    }

    // --- listeners (milestone 47)

    // A listener's own attributes and children, what its type reads, and
    // its actions.
    listener(m: StateMachineDecl, l: ListenerDecl): void {
        this.unknownAttrs(l.extraAttrs, LISTENER_ELEMENT);
        for (let i = 0; i < l.extraChildren.length; i++) {
            const n = l.extraChildren[i];
            if (isListenerPart(n)) {
                this.warning(n.pos, "state-machine-listener-unsupported", "listener \"" + l.name + "\"'s <" + n.name + "> is not run",
                    LISTENER_PART_HINT);
            } else if (n.kind == XmlKind.Element) {
                this.warning(n.pos, "element-unknown", "unknown element <" + n.name + "> in <" + LISTENER_ELEMENT + ">", KEPT_HINT);
            } else if (n.kind == XmlKind.Pi) {
                this.warning(n.pos, "element-unknown", "unknown processing instruction <?" + n.name + "?> in <" + LISTENER_ELEMENT + ">",
                    KEPT_HINT);
            }
        }
        const what = "listener \"" + l.name + "\"";
        const type = LISTENER_TYPE_NAMES[<i32>l.type];
        const pointer = isPointerListenerType(l.type);
        if (pointer) {
            if (l.target.length == 0) {
                this.error(l.pos, "listener-target-missing", what + " (" + type + ") has no target: it hears the pointer over nothing",
                    LISTENER_TARGET_HINT);
            } else {
                const at = this.listenerTarget(l.pos, l.target, what, LISTENER_TARGET_UNKNOWN_CODE, LISTENER_TARGET_HINT);
                if (at >= 0 && !this.pickable(at)) {
                    this.warning(l.pos, "listener-target-unpickable", what + "'s target \"" + l.target + "\" is a " + (this.paths.nodes[at].type
                        as string) + " with nothing the pointer can hit in it", LISTENER_UNPICKABLE_HINT);
                }
            }
        } else if (l.target.length > 0 && l.type == ListenerType.ViewModel) {
            this.warning(l.pos, "listener-attribute-ignored", what + " (viewModel) has a target, which it does not read", LISTENER_IGNORED_HINT);
        } else if (l.target.length > 0) {
            // (an event listener's target scopes the scenes it hears)
            this.listenerTarget(l.pos, l.target, what, LISTENER_TARGET_UNKNOWN_CODE, LISTENER_TARGET_HINT);
        }
        if (l.type == ListenerType.Event) {
            if (l.event.length == 0) {
                this.error(l.pos, "listener-event-missing", what + " (event) names no event", LISTENER_EVENT_HINT);
            } else if (!this.eventNames.has(l.event) && !this.instancesScenes()) {
                this.warning(l.pos, "listener-event-unknown", what + " hears event \"" + l.event + "\", which the scene does not declare",
                    this.eventsHint(l.event));
            }
        } else if (l.event.length > 0) {
            this.warning(l.pos, "listener-attribute-ignored", what + " (" + type + ") has an event, which only an event listener reads",
                LISTENER_IGNORED_HINT);
        }
        if (l.type == ListenerType.ViewModel) {
            if (l.path.length == 0) {
                this.error(l.pos, "listener-path-missing", what + " (viewModel) has no path: it hears no view model property",
                    LISTENER_PATH_HINT);
            }
        } else {
            if (l.path.length > 0) {
                this.warning(l.pos, "listener-attribute-ignored", what + " (" + type + ") has a path, which only a viewModel listener reads",
                    LISTENER_IGNORED_HINT);
            }
            if (l.global.length > 0) {
                this.warning(l.pos, "listener-attribute-ignored", what + " (" + type + ") has a global, which only a viewModel listener reads",
                    LISTENER_IGNORED_HINT);
            }
        }
        for (let i = 0; i < l.actions.length; i++) this.listenerAction(m, l, l.actions[i]);
    }

    // A listener's or an align action's node path: its index among the
    // file's nodes, -1 when the file cannot tell (a path into an instanced
    // scene, checked when the scene loads), -2 after reporting `code`.
    listenerTarget(p: XmlPos, path: string, what: string, code: string, hint: string): i32 {
        const problem = pathProblem(path);
        if (problem.length > 0) {
            this.error(p, code, what + "'s target \"" + path + "\" is not a node path: " + problem, hint);
            return -2;
        }
        const at = this.paths.resolve(path);
        if (at == -2) {
            this.error(p, code, what + "'s target \"" + path + "\" is no node of this file", this.rootHint(path, hint));
        }
        return at;
    }

    // AnimChecker's hint for a path starting with the root's name, else `hint`.
    rootHint(path: string, hint: string): string {
        const h = this.paths.targetHint(path);
        return h.startsWith("paths start below the root") ? h : hint;
    }

    // Whether the pointer can hit node `at` (as far as the file tells): it
    // is a GeometryInstance3D or a CollisionObject3D, holds one, instances
    // a scene or holds a node that does; a node whose class the file does
    // not give (an override, an unknown type) is given the benefit.
    pickable(at: i32): bool {
        const nodes = this.paths.nodes;
        const n = nodes[at];
        if (hitClassOrUnknown(n)) return true;
        const base = at == 0 ? "" : n.path() + "/";
        for (let i = 1; i < nodes.length; i++) {
            if (i == at) continue;
            const c = nodes[i];
            if (c.parent == null) continue;
            if (at != 0 && !c.path().startsWith(base)) continue;
            if (hitClassOrUnknown(c)) return true;
        }
        return false;
    }

    // Whether any node of the file instances a scene (whose events and
    // nodes only loading knows).
    instancesScenes(): bool {
        const nodes = this.paths.nodes;
        for (let i = 0; i < nodes.length; i++) if (nodes[i].instance != null) return true;
        return false;
    }

    eventsHint(name: string): string {
        const list = new Array<string>();
        const events = this.doc.events();
        for (let i = 0; i < events.length; i++) list.push(events[i].name);
        return list.length > 0 ? "the scene's events are " + nameList(list) : "declare it: <Event name=\"" + name + "\"/>";
    }

    listenerAction(m: StateMachineDecl, l: ListenerDecl, a: ListenerActionDecl): void {
        const tag = LISTENER_ACTION_ELEMENTS[<i32>a.kind];
        this.unknownAttrs(a.extraAttrs, tag);
        this.unknownChildren(a.extraChildren, tag);
        const pointer = isPointerListenerType(l.type);
        const what = "listener \"" + l.name + "\"'s <" + tag + ">";
        switch (a.kind) {
            case ListenerActionKind.ViewModelChange: {
                let sources = 0;
                if (a.hasValue) sources++;
                if (a.fromPath.length > 0) sources++;
                if (a.input.length > 0) sources++;
                if (sources > 1 || (a.fromGlobal.length > 0 && a.fromPath.length == 0)) {
                    this.error(a.pos, "listener-action-source-ambiguous", what + " on \"" + a.path + "\" " + (sources > 1
                        ? "has more than one source" : "has fromGlobal without fromPath"), LISTENER_SOURCE_HINT);
                }
                if (a.input.length > 0 && !pointer) {
                    this.warning(a.pos, "listener-action-pointer-misplaced", what + " writes the pointer input " + a.input + " on a "
                        + LISTENER_TYPE_NAMES[<i32>l.type] + " listener, which has no hit: it reads 0", LISTENER_POINTER_HINT);
                }
                break;
            }
            case ListenerActionKind.BoolChange:
            case ListenerActionKind.NumberChange:
            case ListenerActionKind.TriggerChange: {
                const want = a.kind == ListenerActionKind.BoolChange ? InputKind.Bool : a.kind == ListenerActionKind.NumberChange
                    ? InputKind.Number : InputKind.Trigger;
                const input = m.input(a.input);
                if (input == null) {
                    this.error(a.pos, "listener-action-input-unknown", what + " sets input \"" + a.input + "\", which state machine \""
                        + m.name + "\" does not declare", this.inputsHint(m));
                } else if (input.kind != want) {
                    this.error(a.pos, "listener-action-input-kind", what + " sets input \"" + a.input + "\", a <"
                        + INPUT_ELEMENTS[<i32>input.kind] + ">", LISTENER_INPUT_KIND_HINT);
                }
                if (a.kind == ListenerActionKind.NumberChange) {
                    const x = rmlNumberOf(a.value);
                    if (!isNaN(x)) this.f32(a.pos, x, what + "'s value");
                }
                break;
            }
            case ListenerActionKind.FireEvent: {
                if (!this.eventNames.has(a.event)) {
                    this.error(a.pos, "listener-action-event-unknown", what + " fires event \"" + a.event + "\", which the scene does not "
                        + "declare", this.eventsHint(a.event));
                }
                break;
            }
            default: {
                this.listenerTarget(a.pos, a.target, what, LISTENER_ACTION_TARGET_UNKNOWN_CODE, LISTENER_ALIGN_HINT);
                if (!pointer) {
                    this.warning(a.pos, "listener-action-pointer-misplaced", what + " on a " + LISTENER_TYPE_NAMES[<i32>l.type]
                        + " listener, which has no hit: it moves nothing", LISTENER_POINTER_HINT);
                }
            }
        }
    }

    input(d: InputDecl): void {
        const tag = INPUT_ELEMENTS[<i32>d.kind];
        this.unknownAttrs(d.extraAttrs, tag);
        this.unknownChildren(d.extraChildren, tag);
        if (d.kind == InputKind.Number) this.f32(d.pos, d.number, "input \"" + d.name + "\"'s value");
        for (let i = 0; i < d.bindings.length; i++) {
            const b = d.bindings[i];
            if (b.property != "value") {
                this.error(b.attrPos("property"), "binding-property", "an input's binding is property=\"value\", found \"" + b.property + "\"",
                    "an input follows the view model property its binding names: <binding property=\"value\" path=\"...\"/>");
            }
        }
    }

    layer(m: StateMachineDecl, l: LayerDecl): void {
        this.unknownAttrs(l.extraAttrs, LAYER_ELEMENT);
        this.unknownChildren(l.extraChildren, LAYER_ELEMENT);
        // Entry, Any and Exit: one each.
        for (let k = 0; k < 3; k++) {
            let first: StateDecl? = null;
            for (let i = 0; i < l.states.length; i++) {
                const s = l.states[i];
                if (<i32>s.kind != k) continue;
                if (first == null) {
                    first = s;
                    continue;
                }
                this.error(s.pos, "layer-state-extra", "layer \"" + l.name + "\" has a second <" + STATE_ELEMENTS[k] + ">" + firstAt(first.pos),
                    LAYER_STATES_HINT);
            }
            if (first == null) {
                this.error(l.pos, "layer-state-missing", "layer \"" + l.name + "\" of state machine \"" + m.name + "\" has no <"
                    + STATE_ELEMENTS[k] + ">", LAYER_STATES_HINT);
            }
        }
        const names = new Map<string, XmlPos>();
        for (let i = 0; i < l.states.length; i++) {
            const s = l.states[i];
            if (isSystemState(s.kind)) continue;
            const name = s.displayName();
            if (name.length == 0) {
                this.error(s.pos, "state-name-missing", aTag(STATE_ELEMENTS[<i32>s.kind]) + " of layer \"" + l.name + "\" has no name",
                    STATE_NAME_HINT);
            } else if (STATE_SYSTEM_NAMES.includes(name)) {
                this.error(s.pos, "state-name-reserved", aTag(STATE_ELEMENTS[<i32>s.kind]) + " of layer \"" + l.name + "\" is named \""
                    + name + "\"", RESERVED_HINT);
            } else if (names.has(name)) {
                this.error(s.pos, "state-name-duplicate", "layer \"" + l.name + "\" has two states named \"" + name + "\""
                    + firstAt(names.get(name)), STATE_NAME_HINT);
            } else {
                names.set(name, s.pos);
            }
        }
        for (let i = 0; i < l.states.length; i++) this.state(m, l, l.states[i]);
    }

    animationKnown(p: XmlPos, name: string, what: string): void {
        if (this.animationNames.has(name)) return;
        // (a model's clip, "Walk (hero.glb)": the scene's own animation
        // too, but only the tree it instances knows it, so the load checks
        // it, scene_machines.as importedAnimationProblems)
        if (this.importedSource(name)) return;
        const list = new Array<string>();
        const anims = this.doc.animations();
        for (let i = 0; i < anims.length; i++) list.push(anims[i].name);
        this.error(p, "state-animation-unknown", what + " names animation \"" + name + "\", which the scene does not declare",
            list.length > 0 ? "the scene's animations are " + nameList(list) : "declare it: <LinearAnimation name=\"" + name + "\" ...>");
    }

    // Whether `name` is an imported clip's label ("<clip> (<source>)",
    // ../skeleton/names.as) whose source is a file this scene instances
    // (its name, "hero.glb") or the path of a node instancing one.
    importedSource(name: string): bool {
        const split = splitImportedClipLabel(name);
        if (split == null) return false;
        const source = split[1];
        const exts = this.doc.extResources();
        for (let i = 0; i < exts.length; i++) {
            const path = exts[i].path;
            if (path.substring(path.lastIndexOf("/") + 1) == source) return true;
        }
        const n = this.doc.findNode(source);
        return n != null && n.instance != null;
    }

    // The input `name` of `m` for a reader of number inputs (a blend), or a
    // problem: blend-input-unknown, condition-input-kind.
    numberInput(m: StateMachineDecl, p: XmlPos, name: string, what: string): void {
        const input = m.input(name);
        if (input == null) {
            this.error(p, "blend-input-unknown", what + " reads input \"" + name + "\", which state machine \"" + m.name + "\" does not declare",
                this.inputsHint(m));
        } else if (input.kind != InputKind.Number) {
            this.error(p, "condition-input-kind", what + " reads input \"" + name + "\", a <" + INPUT_ELEMENTS[<i32>input.kind]
                + ">: a blend reads a number", INPUT_KIND_HINT);
        }
    }

    inputsHint(m: StateMachineDecl): string {
        const list = new Array<string>();
        for (let i = 0; i < m.inputs.length; i++) list.push(m.inputs[i].name);
        return list.length > 0 ? "the machine's inputs are " + nameList(list) : "declare it on the machine: <StateMachineNumber name=\"...\"/>";
    }

    state(m: StateMachineDecl, l: LayerDecl, s: StateDecl): void {
        const tag = STATE_ELEMENTS[<i32>s.kind];
        const name = s.displayName();
        const what = "state \"" + (name.length > 0 ? name : tag) + "\"";
        this.unknownAttrs(s.extraAttrs, tag);
        this.unknownChildren(s.extraChildren, tag);
        this.f32(s.pos, s.x, what + "'s x");
        this.f32(s.pos, s.y, what + "'s y");
        this.f32(s.pos, s.speed, what + "'s speed");
        if (s.kind == StateKind.Animation && s.animation.length > 0) this.animationKnown(s.pos, s.animation, what);
        if (s.kind == StateKind.Blend1DInput) this.numberInput(m, s.pos, s.input, what);
        let last = -Infinity;
        let ordered = true;
        for (let i = 0; i < s.blends.length; i++) {
            const b = s.blends[i];
            const btag = b.direct ? BLEND_ANIMATION_DIRECT_ELEMENT : BLEND_ANIMATION_1D_ELEMENT;
            this.unknownAttrs(b.extraAttrs, btag, b.direct);
            this.unknownChildren(b.extraChildren, btag);
            this.animationKnown(b.pos, b.animation, what + "'s blend");
            if (!b.direct) {
                this.f32(b.pos, b.value, what + "'s blend value");
                if (ordered && b.value < last) {
                    ordered = false;
                    this.warning(b.pos, "blend-animation-order", what + ": the blend of \"" + b.animation + "\" at " + b.value.toString()
                        + " comes after one at " + last.toString(), BLEND_ORDER_HINT);
                }
                if (b.value > last) last = b.value;
                continue;
            }
            this.f32(b.pos, b.mixValue, what + "'s mixValue");
            if (blendSourceAmbiguous(b)) {
                this.error(b.pos, "blend-source-ambiguous", what + "'s blend of \"" + b.animation + "\" gives its weight more than one "
                    + "source", BLEND_SOURCE_HINT);
            } else if (b.source == BlendSource.Input) {
                this.numberInput(m, b.pos, b.input, what + "'s blend of \"" + b.animation + "\"");
            }
        }
        for (let i = 0; i < s.actions.length; i++) this.action(s.actions[i]);
        for (let i = 0; i < s.transitions.length; i++) this.transition(m, l, s, s.transitions[i]);
    }

    transition(m: StateMachineDecl, l: LayerDecl, from: StateDecl, t: TransitionDecl): void {
        this.unknownAttrs(t.extraAttrs, TRANSITION_ELEMENT);
        this.unknownChildren(t.extraChildren, TRANSITION_ELEMENT);
        const fromName = from.displayName();
        const what = "the transition " + fromName + " → " + t.to;
        if (from.kind == StateKind.Exit) {
            this.error(t.pos, "transition-target-invalid", "layer \"" + l.name + "\"'s ExitState has a transition: the layer ends there",
                TARGET_INVALID_HINT);
        } else {
            const to = l.state(t.to);
            if (to == null) {
                const list = new Array<string>();
                for (let i = 0; i < l.states.length; i++) {
                    const s = l.states[i];
                    if (s.kind != StateKind.Entry && s.kind != StateKind.Any && s.displayName().length > 0) list.push(s.displayName());
                }
                this.error(t.pos, "transition-target-unknown", what + " goes to no state of layer \"" + l.name + "\"",
                    "the layer's states are " + nameList(list) + "; " + TARGET_HINT);
            } else if (to.kind == StateKind.Entry || to.kind == StateKind.Any) {
                this.error(t.pos, "transition-target-invalid", what + " goes to the layer's " + STATE_ELEMENTS[<i32>to.kind],
                    TARGET_INVALID_HINT);
            }
        }
        const ip = t.interpolator;
        if (ip != null) this.interpolator(ip, t.interpolation, what);
        for (let i = 0; i < t.conditions.length; i++) this.condition(m, t.conditions[i]);
        for (let i = 0; i < t.actions.length; i++) this.action(t.actions[i]);
    }

    interpolator(ip: InterpolatorDecl, t: InterpolationType, what: string): void {
        const tag = INTERPOLATOR_ELEMENTS[<i32>ip.kind];
        if (<i32>ip.kind != interpolatorOf(t)) {
            this.warning(ip.pos, "transition-interpolator-mismatch", "a " + tag + " under interpolationType=\""
                + INTERPOLATION_NAMES[<i32>t] + "\" (" + what + ")", INTERPOLATOR_HINT);
        }
        if (!(finiteAsF32(ip.x1) && finiteAsF32(ip.y1) && finiteAsF32(ip.x2) && finiteAsF32(ip.y2) && finiteAsF32(ip.amplitude)
            && finiteAsF32(ip.period))) {
            this.error(ip.pos, "attribute-invalid", "the " + tag + " of " + what + " has a number beyond what a 32-bit float holds", F32_HINT);
        }
        this.unknownAttrs(ip.extraAttrs, tag);
        this.unknownChildren(ip.extraChildren, tag);
    }

    condition(m: StateMachineDecl, c: ConditionDecl): void {
        const tag = CONDITION_ELEMENTS[<i32>c.kind];
        // (an opValue on a trigger condition is kept as an unknown
        // attribute by the reader: it is reported as what it is)
        for (let i = 0; i < c.extraAttrs.length; i++) {
            const a = c.extraAttrs[i];
            if (c.kind == ConditionKind.Trigger && a.name == "opValue") {
                this.error(a.pos.isKnown() ? a.pos : c.pos, "condition-op-invalid", "a <" + tag + "> has an opValue (\"" + a.value + "\")",
                    TRIGGER_OP_HINT);
            } else {
                this.warning(a.pos.isKnown() ? a.pos : a.valuePos, "attribute-unknown", "unknown attribute \"" + a.name + "\" on <" + tag + ">",
                    KEPT_HINT);
            }
        }
        this.unknownChildren(c.extraChildren, tag);
        const hasRight = c.rightPath.length > 0;
        if (c.kind == ConditionKind.Component || c.kind == ConditionKind.Number) {
            if (!c.hasValue && !hasRight) {
                this.error(c.pos, "condition-value-missing", "a <" + tag + "> compares with nothing: it has neither value nor rightPath",
                    c.kind == ConditionKind.Number ? "compare the input with a number: value=\"80\"" : VALUE_HINT);
            }
        }
        if (c.hasValue && hasRight) this.error(c.pos, "condition-value-both", "a <" + tag + "> has both value and rightPath", BOTH_HINT);
        // (an input's number is an f32, as Rive's: a literal past it never compares)
        if (c.kind == ConditionKind.Number && c.hasValue) {
            const x = rmlNumberOf(c.value);
            if (!isNaN(x)) this.f32(c.pos, x, "a <" + tag + ">'s value");
        }
        if (c.kind == ConditionKind.Bool && c.op != ConditionOp.Equal && c.op != ConditionOp.NotEqual) {
            this.error(c.pos, "condition-op-invalid", "a <" + tag + "> with opValue=\"" + CONDITION_OP_NAMES[<i32>c.op] + "\"", BOOL_OP_HINT);
        }
        if (c.kind == ConditionKind.Number || c.kind == ConditionKind.Bool || c.kind == ConditionKind.Trigger) {
            const want = c.kind == ConditionKind.Number ? InputKind.Number : c.kind == ConditionKind.Bool ? InputKind.Bool : InputKind.Trigger;
            const input = m.input(c.input);
            if (input == null) {
                this.error(c.pos, "condition-input-unknown", "a <" + tag + "> reads input \"" + c.input + "\", which state machine \"" + m.name
                    + "\" does not declare", this.inputsHint(m));
            } else if (input.kind != want) {
                this.error(c.pos, "condition-input-kind", "a <" + tag + "> reads input \"" + c.input + "\", a <" + INPUT_ELEMENTS[<i32>input.kind]
                    + ">", INPUT_KIND_HINT);
            }
        }
        if (c.kind == ConditionKind.Component) this.componentTarget(c, tag);
    }

    // A component condition's node and property, as far as the file can
    // tell (a keyed target's rule).
    componentTarget(c: ConditionDecl, tag: string): void {
        const problem = pathProblem(c.target);
        if (problem.length > 0) {
            this.error(c.pos, "condition-target-unknown", "a <" + tag + ">'s target \"" + c.target + "\" is not a node path: " + problem,
                CONDITION_TARGET_HINT);
            return;
        }
        const at = this.paths.resolve(c.target);
        if (at == -2) {
            this.error(c.pos, "condition-target-unknown", "a <" + tag + "> reads \"" + c.target + "\", which is no node of this file",
                this.paths.targetHint(c.target));
            return;
        }
        if (at < 0) return;
        const n = this.paths.nodes[at];
        const type = n.type;
        if (type == null || n.instance != null) return;
        const info = classInfo(type);
        if (info == null || !info.isNode) return;
        if (findBindingTarget(type, c.property) == null) {
            this.error(c.pos, "condition-property-unknown", "a <" + tag + "> reads \"" + c.property + "\" of " + type + " \"" + c.target
                + "\", which is no readable property of its class", CONDITION_PROPERTY_HINT);
        }
    }

    action(a: FireActionDecl): void {
        const tag = ACTION_ELEMENTS[<i32>a.kind];
        this.unknownAttrs(a.extraAttrs, tag);
        this.unknownChildren(a.extraChildren, tag);
        if (a.kind == ActionKind.FireEvent && !this.eventNames.has(a.event)) {
            const list = new Array<string>();
            const events = this.doc.events();
            for (let i = 0; i < events.length; i++) list.push(events[i].name);
            this.error(a.pos, "action-event-unknown", "a <" + tag + "> fires event \"" + a.event + "\", which the scene does not declare",
                list.length > 0 ? "the scene's events are " + nameList(list) : "declare it: <Event name=\"" + a.event + "\"/>");
        }
    }
}

// Whether node `n` is one the pointer can hit (a GeometryInstance3D or a
// CollisionObject3D), instances a scene, or has a class the file does not
// give (an override, an unknown type): listener-target-unpickable's test.
function hitClassOrUnknown(n: NodeDecl): bool {
    if (n.instance != null) return true;
    const type = n.type;
    if (type == null) return true;
    const info = classInfo(type);
    if (info == null || !info.isNode) return true;
    return isA(type, "GeometryInstance3D") || isA(type, "CollisionObject3D");
}

// --- the node properties

// The checks of a node's state machine property (`p`, one of
// DEFAULT_STATE_MACHINE_PROPERTY and INSTANCE_PROPERTIES) on node `n`
// (`root`: the scene's root): format 2, default_state_machine on the root
// naming a machine of the scene, the instance_ properties on a node that
// instances a scene. The value's type is the validator's (a String or a
// number, as classdb says).
export function checkStateMachineProperty(doc: RscnDoc, n: NodeDecl, root: bool, p: Property, out: Array<Diagnostic>): void {
    if (doc.format < 2) {
        out.push(new Diagnostic(Severity.Error, "format-feature", doc.file, p.pos.line, p.pos.col, p.name + " needs format 2: this file is "
            + "format " + doc.format.toString(), FORMAT_FEATURE_HINT));
    }
    if (p.name == DEFAULT_STATE_MACHINE_PROPERTY) {
        if (!root) {
            out.push(new Diagnostic(Severity.Warning, "default-state-machine-not-root", doc.file, p.pos.line, p.pos.col, "node \"" + n.path()
                + "\" sets default_state_machine, which only the scene's root reads: it is ignored", DEFAULT_SM_ROOT_HINT));
            return;
        }
        if (p.value.kind != ValueKind.String && p.value.kind != ValueKind.StringName) return;
        const name = p.value.s;
        if (name.length == 0 || name == NO_STATE_MACHINE || doc.findStateMachine(name) != null) return;
        const list = new Array<string>();
        const machines = doc.stateMachines();
        for (let i = 0; i < machines.length; i++) list.push(machines[i].name);
        const at = p.valuePos.isKnown() ? p.valuePos : p.pos;
        out.push(new Diagnostic(Severity.Error, "default-state-machine-unknown", doc.file, at.line, at.col, "default_state_machine names \""
            + name + "\", which the scene does not declare", (list.length > 0 ? "the scene's state machines are " + nameList(list) + "; "
            : "") + DEFAULT_SM_HINT));
        return;
    }
    if (!INSTANCE_PROPERTIES.includes(p.name)) return;
    // (an override inside an instance has no type: what it overrides may
    // instance a scene, which only instancing tells)
    if (n.instance == null && n.type != null) {
        out.push(new Diagnostic(Severity.Warning, "instance-property-misplaced", doc.file, p.pos.line, p.pos.col, "node \"" + n.path()
            + "\" instances no scene: its " + p.name + " is ignored", INSTANCE_HINT));
    }
}
