// The STMC section of a binary scene (milestone 46, docs/plans/
// RIVE_MODEL.md section 4.6): a scene's state machines (../sm/decl.as),
// so that a built scene runs them without reading any text. codec.as
// writes it exactly when the document has a StateMachine; a scene without
// one has no STMC, so its .rscnb is byte for byte what it was before. It
// comes after ANIM and before BNDS (format.as OPTIONAL_SECTION_ORDER).
//
// Self-contained as ANIM is: its strings are its own (`str` is u32 n, then
// n bytes of UTF-8), not indices into STRS. Numbers are the f64 the text
// gave, so that text, binary and text again are the same bytes (the engine
// prepares them to f32: ../sm/machine.as); names, node paths and view model
// paths stay strings, resolved when the machine is prepared and bound, as
// the text's are.
//
//   u32 version = 1, or 2 when a machine has a listener (milestone 47)
//   u32 nMachines x machine
//     machine    = str name, extras,
//                  u32 nInputs x (u8 kind, str name, f64 number, u8 boolean,
//                                 u32 nBindings x binding, extras),
//                  u32 nLayers x (str name, extras, u32 nStates x state),
//                  u32 nInterpolators x (u8 kind, f64 a, f64 b, f64 c, f64 d, extras)
//     state      = u8 kind, str name, f64 x, f64 y, str animation, f64 speed,
//                  u8 flags (1 reset, 2 random), str path, str global, str converter,
//                  str input, extras,
//                  u32 nBlends x (u8 direct, str animation, f64 value, u8 source,
//                                 f64 mixValue, str input, str path, str global,
//                                 str converter, extras),
//                  u32 nActions x action,
//                  u32 nTransitions x transition
//     transition = str to, u32 duration, u32 exitTime, u8 interpolationType,
//                  i32 interpolator (an index into the machine's table, -1 none),
//                  u32 randomWeight, u8 flags (Rive's StateTransitionFlags: 1 disabled,
//                  2 durationIsPercentage, 4 enableExitTime, 8 exitTimeIsPercentage,
//                  16 pauseOnExit, 32 enableEarlyExit), extras,
//                  u32 nConditions x (u8 kind, u8 op, str path, str global, str converter,
//                                     str target, str property, str input, u8 hasValue,
//                                     str value, str rightPath, str rightGlobal,
//                                     str rightConverter, extras),
//                  u32 nActions x action
//     action     = u8 kind, str event, str path, str global, u8 occurs, extras
//   binding = ANIM's event binding record: str property, str path, str mode,
//             str once, str global, str converter, attrs (scale, offset and
//             convert when written, and the unknown ones with fidelity)
//   attrs  = u32 n x (str name, str value)
//   extras = attrs, u32 nChildren x str xml
//   (version 2 only, after the machines:)
//   nMachines x (u32 nListeners x listener)    one count per machine, in their order
//     listener = str name, u8 type (Rive's ListenerType number), str target, str event,
//                str path, str global, extras, u32 nActions x laction
//     laction  = u8 kind (ListenerActionKind), str path, str global, u8 hasValue,
//                str value, str fromPath, str fromGlobal, str input, str converter,
//                str event, str target, u8 flags (1 surface, 2 preserveOffset), extras
//
// Milestone 47: the section is version 2 exactly when a machine has a
// listener, and version 1, its bytes what they were, otherwise; so every
// scene without listeners keeps its .rscnb, and a reader that knows only
// version 1 (a 1.7 library) refuses a scene whose listeners it would drop.
// A version-2 section without any listener would not encode back to its
// bytes: refused.
//
// As in ANIM, the unknown attributes and the kept children (a machine's
// listeners among them) are written only with RSCNB_FLAG_FIDELITY. The
// decoder refuses what the validator refuses as attribute-invalid (a
// number beyond a 32-bit float, a kind, an operator, a flag or an
// interpolation type out of range) and any field a declaration of its
// kind does not have (a name on an EntryState, a mixValue on a 1D
// blend), which no text could hold: every decoded machine writes as text
// and encodes back to the same bytes. A reader of this version reads these
// fields and ignores bytes after them, so a later version may append
// fields. docs/formats/RSCN.md, "Binary scenes", is normative.

import { XmlAttr, XmlNode, XmlPos } from "../../base/xml";
import { BindingDecl, EntryKind, RscnDoc } from "../rscn/doc";
import { ELASTIC_EASE_IN_OUT, InterpolationType, InterpolatorDecl, InterpolatorKind, finiteAsF32 } from "../anim/decl";
import {
    ActionKind, BOOL_CHANGE_NAMES, BlendAnimationDecl, BlendSource, ConditionDecl, ConditionKind, ConditionOp, FireActionDecl, InputDecl,
    InputKind, LISTENER_TYPE_NAMES, LayerDecl, ListenerActionDecl, ListenerActionKind, ListenerDecl, ListenerType, StateDecl, StateKind,
    StateMachineDecl, TransitionDecl, isBlendState, isSystemState, listenerTypeOf, pointerInputOf,
} from "../sm/decl";
import { printNumber } from "../value_text";
import { rmlNumberOf } from "../data/rml_read";
import { BinReader } from "./bin";
import { XmlNodesReader } from "./anim";

// The section's own version (its first field): 1, or (milestone 47)
// STMC_LISTENERS_VERSION when a machine has a listener.
export const STMC_VERSION: u32 = 1;
export const STMC_LISTENERS_VERSION: u32 = 2;

// A ListenerAlignTarget's flags.
export const ALIGN_FLAG_SURFACE: u32 = 1;
export const ALIGN_FLAG_PRESERVE_OFFSET: u32 = 2;

// A state's flags.
export const STATE_FLAG_RESET: u32 = 1;
export const STATE_FLAG_RANDOM: u32 = 2;

// A transition's flags (Rive's StateTransitionFlags).
export const TRANSITION_FLAG_DISABLED: u32 = 1;
export const TRANSITION_FLAG_DURATION_IS_PERCENTAGE: u32 = 2;
export const TRANSITION_FLAG_ENABLE_EXIT_TIME: u32 = 4;
export const TRANSITION_FLAG_EXIT_TIME_IS_PERCENTAGE: u32 = 8;
export const TRANSITION_FLAG_PAUSE_ON_EXIT: u32 = 16;
export const TRANSITION_FLAG_ENABLE_EARLY_EXIT: u32 = 32;
const TRANSITION_FLAGS_ALL: u32 = 63;

// The binding attributes the record holds in fields of its own (ANIM's).
export const BINDING_FIELDS: Array<string> = ["property", "path", "mode", "once", "global", "converter"];
export const BINDING_KEPT: Array<string> = ["scale", "offset", "convert"];

// Whether `doc` needs an STMC section: a StateMachine.
export function stmcNeeded(doc: RscnDoc): bool {
    for (let i = 0; i < doc.entries.length; i++) {
        const e = doc.entries[i];
        if (e.kind == EntryKind.StateMachine && e.stateMachine != null) return true;
    }
    return false;
}

// --- encoding

// --- decoding

// (each count is checked against the bytes left at the least a record can
// take: a machine 24 bytes, an input 26, a binding 28, a layer 16, a state
// 70, a blend 46, an action 22, a transition 38, a condition 51, an
// interpolator 41, a listener 33, a listener's action 47)

class SmReader {
    r: BinReader;
    fidelity: bool;
    // The kept children's XML texts, and the list each goes into once
    // parsed (in one go, at the end).
    texts: Array<string> = [];
    owners: Array<Array<XmlNode>> = [];

    constructor(r: BinReader, fidelity: bool) {
        this.r = r;
        this.fidelity = fidelity;
    }

    str(): string {
        const n = this.r.count(1);
        return this.r.utf8(n);
    }

    attrs(into: Array<XmlAttr>, what: string): void {
        const r = this.r;
        const n = r.count(8);
        for (let k = 0; k < n && !r.failed; k++) {
            const name = this.str();
            const value = this.str();
            into.push(new XmlAttr(name, value));
        }
        if (!r.failed && n > 0 && !this.fidelity) r.fail(what + " has unknown attributes in a file without fidelity");
    }

    extras(attrs: Array<XmlAttr>, children: Array<XmlNode>, what: string): void {
        this.attrs(attrs, what);
        const r = this.r;
        const n = r.count(4);
        if (!r.failed && n > 0 && !this.fidelity) {
            r.fail(what + " keeps children in a file without fidelity");
            return;
        }
        for (let k = 0; k < n && !r.failed; k++) {
            this.texts.push(this.str());
            this.owners.push(children);
        }
    }

    // A u8 that must be at most `max`.
    small(max: u32, what: string): u32 {
        const v = this.r.u8();
        if (!this.r.failed && v > max) this.r.fail(what + " is " + v.toString() + ", not 0 to " + max.toString());
        return v;
    }

    // A u32 that must fit in an i32.
    whole(what: string): i32 {
        const v = this.r.u32();
        if (!this.r.failed && v > <u32>i32.MAX_VALUE) this.r.fail(what + " is " + v.toString());
        return <i32>v;
    }

    // An f64 the engine reads as an f32 (as the validator: attribute-invalid).
    number(what: string): f64 {
        const v = this.r.f64();
        if (!this.r.failed && !finiteAsF32(v)) this.r.fail(what + " is " + v.toString() + ", beyond a 32-bit float");
        return v;
    }

    // A field a declaration of its kind does not have (no text holds it).
    stray(set: bool, what: string): void {
        if (set && !this.r.failed) this.r.fail(what);
    }

    machine(index: i32): StateMachineDecl? {
        const r = this.r;
        const d = new StateMachineDecl(this.str());
        const what = "state machine " + index.toString();
        if (!r.failed && d.name.length == 0) r.fail(what + " has no name");
        this.extras(d.extraAttrs, d.extraChildren, what);
        const nInputs = r.count(26);
        for (let k = 0; k < nInputs && !r.failed; k++) d.inputs.push(this.input(what + "'s input " + k.toString()));
        const transitions = new Array<TransitionDecl>();
        const indices = new Array<i32>();
        const nLayers = r.count(16);
        for (let k = 0; k < nLayers && !r.failed; k++) {
            const lw = what + "'s layer " + k.toString();
            const l = new LayerDecl(this.str());
            if (!r.failed && l.name.length == 0) r.fail(lw + " has no name");
            this.extras(l.extraAttrs, l.extraChildren, lw);
            const nStates = r.count(70);
            for (let j = 0; j < nStates && !r.failed; j++) l.states.push(this.state(lw + "'s state " + j.toString(), transitions, indices));
            d.layers.push(l);
        }
        const nTable = r.count(41);
        const table = new Array<InterpolatorDecl>();
        for (let k = 0; k < nTable && !r.failed; k++) {
            const iw = what + "'s interpolator " + k.toString();
            const kind = this.small(<u32>InterpolatorKind.Elastic, iw + "'s kind");
            const ip = new InterpolatorDecl(<InterpolatorKind>kind);
            const a = r.f64();
            const b = r.f64();
            const c = r.f64();
            const e = r.f64();
            if (!r.failed && !(finiteAsF32(a) && finiteAsF32(b) && finiteAsF32(c) && finiteAsF32(e))) {
                r.fail(iw + " has a number beyond a 32-bit float");
            }
            if (kind == <u32>InterpolatorKind.Elastic) {
                if (!r.failed && !(a >= 0 && a <= <f64>ELASTIC_EASE_IN_OUT && a == Math.floor(a))) r.fail(iw + "'s easingValue is not 0, 1 or 2");
                if (!r.failed && e != 0) r.fail(iw + "'s fourth number is not 0");
                ip.easingValue = <i32>a;
                ip.amplitude = b;
                ip.period = c;
            } else {
                ip.x1 = a;
                ip.y1 = b;
                ip.x2 = c;
                ip.y2 = e;
            }
            this.extras(ip.extraAttrs, ip.extraChildren, iw);
            table.push(ip);
        }
        if (r.failed) return null;
        // Each transition its own interpolator, numbered in the order the
        // transitions come, as the encoder numbers them (anything else, an
        // entry named twice, out of order or never, would not encode back
        // to these bytes).
        let next = 0;
        for (let k = 0; k < transitions.length; k++) {
            const i = indices[k];
            if (i < 0) continue;
            if (i >= table.length) {
                r.fail(what + " names interpolator " + i.toString() + " of " + table.length.toString());
                return null;
            }
            if (i != next) {
                r.fail(what + " names interpolator " + i.toString() + " where the next is " + next.toString());
                return null;
            }
            transitions[k].interpolator = table[i];
            next++;
        }
        if (next != table.length) {
            r.fail(what + " has " + table.length.toString() + " interpolators, of which its transitions name " + next.toString());
            return null;
        }
        return d;
    }

    input(what: string): InputDecl {
        const r = this.r;
        const kind = this.small(<u32>InputKind.Trigger, what + "'s kind");
        const d = new InputDecl(<InputKind>kind, this.str());
        if (!r.failed && d.name.length == 0) r.fail(what + " has no name");
        d.number = this.number(what + "'s number");
        d.boolean = this.small(1, what + "'s boolean") == 1;
        this.stray(kind != <u32>InputKind.Number && d.number != 0, what + " is no number input but has a number");
        this.stray(kind != <u32>InputKind.Bool && d.boolean, what + " is no boolean input but has a boolean");
        const nBindings = r.count(28);
        for (let k = 0; k < nBindings && !r.failed; k++) {
            const b = new BindingDecl(this.str(), this.str());
            b.mode = this.str();
            b.once = this.str();
            b.global = this.str();
            b.converter = this.str();
            const n = r.count(8);
            for (let j = 0; j < n && !r.failed; j++) {
                const a = new XmlAttr(this.str(), this.str());
                if (a.name == "scale") b.scale = a.value;
                else if (a.name == "offset") b.offset = a.value;
                else if (a.name == "convert") b.convert = a.value;
                else if (!this.fidelity) r.fail(what + "'s binding has unknown attributes in a file without fidelity");
                b.attrs.push(a);
            }
            d.bindings.push(b);
        }
        this.extras(d.extraAttrs, d.extraChildren, what);
        return d;
    }

    state(what: string, transitions: Array<TransitionDecl>, indices: Array<i32>): StateDecl {
        const r = this.r;
        const kind = <StateKind>this.small(<u32>StateKind.BlendDirect, what + "'s kind");
        const s = new StateDecl(kind);
        s.name = this.str();
        s.x = this.number(what + "'s x");
        s.y = this.number(what + "'s y");
        s.animation = this.str();
        s.speed = this.number(what + "'s speed");
        const flags = this.small(STATE_FLAG_RESET | STATE_FLAG_RANDOM, what + "'s flags");
        s.reset = (flags & STATE_FLAG_RESET) != 0;
        s.random = (flags & STATE_FLAG_RANDOM) != 0;
        s.path = this.str();
        s.global = this.str();
        s.converter = this.str();
        s.input = this.str();
        const system = isSystemState(kind);
        this.stray(system && (s.name.length > 0 || s.speed != 1 || flags != 0), what + " is an Entry, Any or Exit state with a name, "
            + "a speed or flags");
        this.stray(kind != StateKind.Animation && s.animation.length > 0, what + " is no AnimationState but has an animation");
        this.stray(kind == StateKind.Animation && s.name.length > 0 && s.name == s.animation, what + " is named as its animation, "
            + "which the encoder leaves out");
        this.stray(kind != StateKind.Blend1DViewModel && (s.path.length > 0 || s.global.length > 0 || s.converter.length > 0),
            what + " reads no view model but has a path, global or converter");
        this.stray(kind != StateKind.Blend1DInput && s.input.length > 0, what + " reads no input but has one");
        this.extras(s.extraAttrs, s.extraChildren, what);
        const blend = isBlendState(kind);
        const direct = kind == StateKind.BlendDirect;
        const nBlends = r.count(46);
        this.stray(nBlends > 0 && !blend, what + " is no blend state but has blend animations");
        for (let k = 0; k < nBlends && !r.failed; k++) {
            const bw = what + "'s blend " + k.toString();
            const isDirect = this.small(1, bw + "'s direct") == 1;
            this.stray(isDirect != direct, bw + " is of the other blend state's kind");
            const b = new BlendAnimationDecl(isDirect, this.str());
            b.value = this.number(bw + "'s value");
            b.source = <BlendSource>this.small(<u32>BlendSource.ViewModel, bw + "'s source");
            b.mixValue = this.number(bw + "'s mixValue");
            b.input = this.str();
            b.path = this.str();
            b.global = this.str();
            b.converter = this.str();
            this.stray(isDirect && b.value != 0, bw + " is direct but has a 1D value");
            this.stray(!isDirect && (b.source != BlendSource.MixValue || b.mixValue != 100 || b.input.length > 0 || b.path.length > 0
                || b.global.length > 0 || b.converter.length > 0), bw + " is 1D but has a direct blend's source");
            // (the text names the source by the attribute it writes: input
            // when there is one, else path)
            this.stray(isDirect && b.source != BlendSource.Input && (b.input.length > 0
                || (b.source == BlendSource.MixValue && b.path.length > 0)), bw + "'s source is not the one its fields name");
            this.extras(b.extraAttrs, b.extraChildren, bw);
            s.blends.push(b);
        }
        const nActions = r.count(22);
        for (let k = 0; k < nActions && !r.failed; k++) s.actions.push(this.action(what + "'s action " + k.toString()));
        const nTransitions = r.count(38);
        for (let k = 0; k < nTransitions && !r.failed; k++) {
            s.transitions.push(this.transition(what + "'s transition " + k.toString(), transitions, indices));
        }
        return s;
    }

    transition(what: string, transitions: Array<TransitionDecl>, indices: Array<i32>): TransitionDecl {
        const r = this.r;
        const t = new TransitionDecl(this.str());
        t.duration = this.whole(what + "'s duration");
        t.exitTime = this.whole(what + "'s exit time");
        t.interpolation = <InterpolationType>this.small(<u32>InterpolationType.Elastic, what + "'s interpolation");
        const ip = r.i32();
        if (!r.failed && ip < -1) r.fail(what + "'s interpolator index is " + ip.toString());
        transitions.push(t);
        indices.push(ip);
        t.randomWeight = this.whole(what + "'s random weight");
        const flags = this.small(TRANSITION_FLAGS_ALL, what + "'s flags");
        t.disabled = (flags & TRANSITION_FLAG_DISABLED) != 0;
        t.durationIsPercentage = (flags & TRANSITION_FLAG_DURATION_IS_PERCENTAGE) != 0;
        t.enableExitTime = (flags & TRANSITION_FLAG_ENABLE_EXIT_TIME) != 0;
        t.exitTimeIsPercentage = (flags & TRANSITION_FLAG_EXIT_TIME_IS_PERCENTAGE) != 0;
        t.pauseOnExit = (flags & TRANSITION_FLAG_PAUSE_ON_EXIT) != 0;
        t.enableEarlyExit = (flags & TRANSITION_FLAG_ENABLE_EARLY_EXIT) != 0;
        this.extras(t.extraAttrs, t.extraChildren, what);
        const nConditions = r.count(51);
        for (let k = 0; k < nConditions && !r.failed; k++) t.conditions.push(this.condition(what + "'s condition " + k.toString()));
        const nActions = r.count(22);
        for (let k = 0; k < nActions && !r.failed; k++) t.actions.push(this.action(what + "'s action " + k.toString()));
        return t;
    }

    condition(what: string): ConditionDecl {
        const kind = <ConditionKind>this.small(<u32>ConditionKind.Trigger, what + "'s kind");
        const c = new ConditionDecl(kind);
        c.op = <ConditionOp>this.small(<u32>ConditionOp.GreaterThan, what + "'s operator");
        c.path = this.str();
        c.global = this.str();
        c.converter = this.str();
        c.target = this.str();
        c.property = this.str();
        c.input = this.str();
        c.hasValue = this.small(1, what + "'s hasValue") == 1;
        c.value = this.str();
        c.rightPath = this.str();
        c.rightGlobal = this.str();
        c.rightConverter = this.str();
        const vm = kind == ConditionKind.ViewModel;
        const sides = vm || kind == ConditionKind.Component;
        this.stray(!vm && (c.path.length > 0 || c.global.length > 0 || c.converter.length > 0), what + " reads no view model but has a path");
        this.stray(kind != ConditionKind.Component && (c.target.length > 0 || c.property.length > 0),
            what + " reads no node but has a target");
        this.stray(sides && c.input.length > 0, what + " reads no input but has one");
        this.stray(!sides && (c.rightPath.length > 0 || c.rightGlobal.length > 0 || c.rightConverter.length > 0),
            what + " has a right side its kind does not take");
        this.stray(!c.hasValue && c.value.length > 0, what + " has a value it says it has not");
        this.stray(c.hasValue && !sides && kind != ConditionKind.Number, what + " has a value its kind does not take");
        this.stray(kind == ConditionKind.Trigger && c.op != ConditionOp.Equal, what + " is a trigger condition with an operator");
        this.stray(kind == ConditionKind.Number && c.hasValue && isNaN(rmlNumberOf(c.value)), what + "'s value \"" + c.value
            + "\" is not a number");
        this.stray(kind == ConditionKind.Number && c.hasValue && !isNaN(rmlNumberOf(c.value)) && !finiteAsF32(rmlNumberOf(c.value)),
            what + "'s value \"" + c.value + "\" is beyond a 32-bit float");
        this.extras(c.extraAttrs, c.extraChildren, what);
        return c;
    }

    listener(what: string): ListenerDecl {
        const r = this.r;
        const l = new ListenerDecl(this.str());
        if (!r.failed && l.name.length == 0) r.fail(what + " has no name");
        const type = this.small(<u32>ListenerType.Drag, what + "'s type");
        if (!r.failed && listenerTypeOf(LISTENER_TYPE_NAMES[<i32>type]) < 0) {
            r.fail(what + "'s type is " + type.toString() + " (" + LISTENER_TYPE_NAMES[<i32>type] + "), which 3D does not run");
        }
        l.type = <ListenerType>type;
        l.target = this.str();
        l.event = this.str();
        l.path = this.str();
        l.global = this.str();
        this.extras(l.extraAttrs, l.extraChildren, what);
        const n = r.count(47);
        for (let k = 0; k < n && !r.failed; k++) l.actions.push(this.listenerAction(what + "'s action " + k.toString()));
        return l;
    }

    // A listener's action: the fields its kind has (any other set is a
    // field no text holds), its value as the text writes it.
    listenerAction(what: string): ListenerActionDecl {
        const r = this.r;
        const kind = <ListenerActionKind>this.small(<u32>ListenerActionKind.AlignTarget, what + "'s kind");
        const a = new ListenerActionDecl(kind);
        a.path = this.str();
        a.global = this.str();
        a.hasValue = this.small(1, what + "'s hasValue") == 1;
        a.value = this.str();
        a.fromPath = this.str();
        a.fromGlobal = this.str();
        a.input = this.str();
        a.converter = this.str();
        a.event = this.str();
        a.target = this.str();
        const flags = this.small(ALIGN_FLAG_SURFACE | ALIGN_FLAG_PRESERVE_OFFSET, what + "'s flags");
        a.surface = (flags & ALIGN_FLAG_SURFACE) != 0;
        a.preserveOffset = (flags & ALIGN_FLAG_PRESERVE_OFFSET) != 0;
        const vm = kind == ListenerActionKind.ViewModelChange;
        const inputs = kind == ListenerActionKind.BoolChange || kind == ListenerActionKind.NumberChange
            || kind == ListenerActionKind.TriggerChange;
        const valued = kind == ListenerActionKind.BoolChange || kind == ListenerActionKind.NumberChange;
        this.stray(!vm && (a.path.length > 0 || a.global.length > 0 || a.fromPath.length > 0 || a.fromGlobal.length > 0
            || a.converter.length > 0), what + " writes no view model property but has a path, a source or a converter");
        this.stray(!vm && !inputs && a.input.length > 0, what + " sets no input but names one");
        this.stray(vm && a.input.length > 0 && pointerInputOf(a.input) < 0, what + "'s input \"" + a.input + "\" is no pointer input");
        this.stray(!a.hasValue && a.value.length > 0, what + " has a value it says it has not");
        this.stray(valued && !a.hasValue, what + " has no value");
        this.stray(!vm && !valued && a.hasValue, what + " has a value its kind does not take");
        this.stray(kind == ListenerActionKind.BoolChange && a.hasValue && !BOOL_CHANGE_NAMES.includes(a.value),
            what + "'s value \"" + a.value + "\" is not true, false or toggle");
        if (kind == ListenerActionKind.NumberChange && a.hasValue && !r.failed) {
            const x = rmlNumberOf(a.value);
            if (isNaN(x)) r.fail(what + "'s value \"" + a.value + "\" is not a number");
            else if (!finiteAsF32(x)) r.fail(what + "'s value \"" + a.value + "\" is beyond a 32-bit float");
            else if (printNumber(x) != a.value) r.fail(what + "'s value \"" + a.value + "\" is not in its shortest form");
        }
        this.stray(kind != ListenerActionKind.FireEvent && a.event.length > 0, what + " fires no event but names one");
        this.stray(kind != ListenerActionKind.AlignTarget && (a.target.length > 0 || flags != 0), what + " moves no node but has a target "
            + "or flags");
        this.extras(a.extraAttrs, a.extraChildren, what);
        return a;
    }

    action(what: string): FireActionDecl {
        const kind = <ActionKind>this.small(<u32>ActionKind.FireTrigger, what + "'s kind");
        const a = new FireActionDecl(kind);
        a.event = this.str();
        a.path = this.str();
        a.global = this.str();
        a.occurs = <i32>this.small(1, what + "'s occursValue");
        this.stray(kind == ActionKind.FireEvent && (a.path.length > 0 || a.global.length > 0), what + " fires an event but has a path");
        this.stray(kind == ActionKind.FireTrigger && a.event.length > 0, what + " fires a trigger but names an event");
        this.extras(a.extraAttrs, a.extraChildren, what);
        return a;
    }
}

// The section's `bytes` read, its kept children parsed with `xml`; null
// with why not in `why[0]`: a newer version, a count past the end, bytes
// left after the last field, a kind,
// an operator, a flag or a number out of range, a field its declaration
// does not have, an interpolator index past the table, children that are
// not XML (or kept in a file without `fidelity`).
export function decodeStmc(bytes: Uint8Array, fidelity: bool, xml: XmlNodesReader, why: Array<string>): Array<StateMachineDecl>? {
    const r = new BinReader(bytes);
    const version = r.u32();
    if (!r.failed && version != STMC_VERSION && version != STMC_LISTENERS_VERSION) {
        why.push("its version is " + version.toString() + ", this build reads " + STMC_VERSION.toString() + " and "
            + STMC_LISTENERS_VERSION.toString());
        return null;
    }
    const s = new SmReader(r, fidelity);
    const out = new Array<StateMachineDecl>();
    const n = r.count(24);
    // (the encoder writes STMC only for a scene with a machine)
    if (!r.failed && n == 0) {
        why.push("it holds no state machine");
        return null;
    }
    for (let k = 0; k < n && !r.failed; k++) {
        const d = s.machine(k);
        if (d != null) out.push(d);
    }
    // (version 2: each machine's listeners, at least one among them)
    if (!r.failed && version == STMC_LISTENERS_VERSION) {
        let any = false;
        for (let k = 0; k < out.length && !r.failed; k++) {
            const nl = r.count(33);
            for (let j = 0; j < nl && !r.failed; j++) {
                out[k].listeners.push(s.listener("state machine " + k.toString() + "'s listener " + j.toString()));
                any = true;
            }
        }
        if (!r.failed && !any) r.fail("its version is 2 but no machine has a listener (version 1 is written then)");
    }
    // (every byte read: a version-2 section relabelled 1 would otherwise
    // load with its listeners silently gone)
    if (!r.failed && r.remaining() != 0) {
        r.fail(r.remaining().toString() + " bytes are left after its " + (version == STMC_LISTENERS_VERSION ? "listeners" : "machines"));
    }
    if (r.failed) {
        why.push(r.why);
        return null;
    }
    if (s.texts.length > 0) {
        const nodes = xml(s.texts);
        if (nodes == null) {
            why.push("its kept children are not " + s.texts.length.toString() + " well-formed XML nodes");
            return null;
        }
        for (let k = 0; k < nodes.length; k++) s.owners[k].push(nodes[k]);
    }
    return out;
}

// A decoded machine's elements numbered in document order from `from` (a
// binary file has no lines: codec.as gives every element line 0 and its
// ordinal as its column); the last number used.
export function numberStateMachine(d: StateMachineDecl, from: i32): i32 {
    let n = from;
    d.pos = new XmlPos(0, ++n);
    for (let i = 0; i < d.inputs.length; i++) {
        const input = d.inputs[i];
        input.pos = new XmlPos(0, ++n);
        for (let k = 0; k < input.bindings.length; k++) input.bindings[k].pos = new XmlPos(0, ++n);
    }
    for (let i = 0; i < d.layers.length; i++) {
        const l = d.layers[i];
        l.pos = new XmlPos(0, ++n);
        for (let j = 0; j < l.states.length; j++) {
            const s = l.states[j];
            s.pos = new XmlPos(0, ++n);
            for (let k = 0; k < s.blends.length; k++) s.blends[k].pos = new XmlPos(0, ++n);
            for (let k = 0; k < s.actions.length; k++) s.actions[k].pos = new XmlPos(0, ++n);
            for (let k = 0; k < s.transitions.length; k++) {
                const t = s.transitions[k];
                t.pos = new XmlPos(0, ++n);
                const ip = t.interpolator;
                if (ip != null) ip.pos = new XmlPos(0, ++n);
                for (let c = 0; c < t.conditions.length; c++) t.conditions[c].pos = new XmlPos(0, ++n);
                for (let c = 0; c < t.actions.length; c++) t.actions[c].pos = new XmlPos(0, ++n);
            }
        }
    }
    for (let i = 0; i < d.listeners.length; i++) {
        const l = d.listeners[i];
        l.pos = new XmlPos(0, ++n);
        for (let k = 0; k < l.actions.length; k++) l.actions[k].pos = new XmlPos(0, ++n);
    }
    return n;
}
