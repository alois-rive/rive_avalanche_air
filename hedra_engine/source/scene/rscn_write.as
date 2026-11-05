// The canonical .rscn writer: an RscnDoc (doc.as) to text in the one layout
// docs/formats/RSCN.md ("Canonical form") specifies, so that
//   writeRscn(parse(writeRscn(parse(x)))) == writeRscn(parse(x))
// byte for byte for any x that reads, and a file in canonical form is
// written back unchanged. Comments and unknown elements and attributes are
// written back where they were.
//
// The layout: the declaration line; prolog comments and PIs one per line;
// `<rscn>` with its entries indented 2 spaces and their bodies 4, one
// element per line; one blank line where the section changes (a comment or
// an unknown element counts as part of the section of the next known entry,
// so that a comment above the first node stays above it, after the blank
// line); the epilog after `</rscn>`. Known attributes come first in a fixed
// order, then the unknown ones in the order they were read.
//
// Milestone 42: <rscn>'s format is the version the document needs
// (doc.as formatNeeded), not the one it was read with, so a file that uses
// nothing of format 2 is written as format 1 (byte for byte what it was);
// a scene's converters are written in their section, between the
// sub_resources and the nodes, as RML writes them (name first, then the
// attributes in order; a group's members as <DataConverterGroupItem
// converter="..."/>, then the other children, each indented 2 more).
//
// Milestone 45: a scene's timelines, its <Event>s and <LinearAnimation>s,
// are written in their sections between the nodes and the connections
// (RSCN.md, "Animations", gives the canonical form): RML's elements, each
// level 2 spaces deeper, the known attributes in a fixed order (those with
// Rive's default left out where RSCN.md says so), then the unknown ones;
// the known children, then the kept ones (comments, unknown elements) in
// their order; an element without children self-closes.
//
// Milestone 46: a scene's state machines are written in their section,
// after the animations and before the connections (RSCN.md, "State
// machines", gives the canonical form): the same rules, the inputs, then
// the layers, then what was kept; a state's blend animations, then its
// actions, then its transitions; a transition's interpolator, then its
// conditions, then its actions; RML's misspelt exitTimeIsPercetange is
// written exitTimeIsPercentage. Milestone 47: a machine's listeners
// after its layers (a listener read before a layer is written after them,
// as inputs are written first), each with its actions in order.
//
// A material document (milestone 14, DocKind.Material) is not written here:
// its file is MaterialX (../resource/material_file.as writeMaterialFile).

import { StringBuilder } from "../../base/util";
import { base64Encode } from "../../fs/base64";
import { XmlAttr, XmlNode, escapeXmlText, writeXmlNode } from "../../base/xml";
import { XML_DECLARATION_LINE, pushAttr } from "../textdoc/write";
import { printNumber, printValue } from "../../scene/value_text";
import { BindingDecl, BodyItem, BodyKind, Declaration, Entry, RscnDoc, formatNeeded } from "../../scene/rscn/doc";
import { DataConverterDecl } from "../../scene/data/model";
import {
    ANIMATION_ELEMENT, CUSTOM_PROPERTY_ELEMENTS, CustomPropertyDecl, CustomPropertyKind, EVENT_ELEMENT, EventDecl, INTERPOLATION_NAMES,
    INTERPOLATOR_ELEMENTS, InterpolationType, InterpolatorDecl, InterpolatorKind, KEYED_OBJECT_ELEMENT, KEYED_PROPERTY_ELEMENT,
    KEYFRAME_ELEMENTS, KeyFrameDecl, KeyFrameKind, KeyedObjectDecl, KeyedPropertyDecl, LOOP_NAMES, LinearAnimationDecl,
} from "../../scene/anim/decl";
import {
    ACTION_ELEMENTS, ActionKind, BLEND_ANIMATION_1D_ELEMENT, BLEND_ANIMATION_DIRECT_ELEMENT, BlendAnimationDecl, BlendSource,
    CONDITION_ELEMENTS, CONDITION_OP_NAMES, ConditionDecl, ConditionKind, FireActionDecl, INPUT_ELEMENTS, InputDecl, InputKind,
    LAYER_ELEMENT, LISTENER_ACTION_ELEMENTS, LISTENER_ELEMENT, LISTENER_TYPE_NAMES, LayerDecl, ListenerActionDecl, ListenerActionKind,
    ListenerDecl, STATE_ELEMENTS, STATE_MACHINE_ELEMENT, StateDecl, StateKind, StateMachineDecl, TRANSITION_ELEMENT, TransitionDecl,
    isBlendState, isSystemState,
} from "../../scene/sm/decl";
import { rmlNumberOf } from "../../scene/data/rml_read";

const EXT_ATTRS: Array<string> = ["id", "type", "path", "uid"];
const SUB_ATTRS: Array<string> = ["id", "type"];
const RESOURCE_ATTRS: Array<string> = ["type"];
const NODE_ATTRS: Array<string> = ["name", "type", "parent", "instance"];
const CONNECTION_ATTRS: Array<string> = ["signal", "from", "to", "method", "flags"];
const ROOT_ATTRS: Array<string> = ["format", "uid"];
const EMBEDDED_ATTRS: Array<string> = ["path", "size"];
// Milestone 17: a <binding>'s attributes, in this order, each but the first
// two written only when set (milestone 42: once, global and converter after
// mode; once only when not false).
const BINDING_ATTRS: Array<string> = ["property", "path", "mode", "once", "global", "converter", "scale", "offset", "convert"];

// An embedded file's base64 goes on lines of this many characters (MIME's
// 76), indented 4 spaces: a packed scene stays a text file that diffs by
// line and that no editor struggles with.
export const EMBEDDED_LINE: i32 = 76;

// ` name="value"`, escaped (../textdoc/write.as, which the .rmdl writer
// shares).
function attr(out: StringBuilder, name: string, value: string): void {
    pushAttr(out, name, value);
}

// The attributes whose names are not in `known`, in source order.
function unknownAttrs(out: StringBuilder, attrs: Array<XmlAttr>, known: Array<string>): void {
    for (let k = 0; k < attrs.length; k++) {
        const a = attrs[k];
        if (!known.includes(a.name)) attr(out, a.name, a.value);
    }
}

function xmlLine(out: StringBuilder, indent: string, n: XmlNode): void {
    out.push(indent);
    writeXmlNode(n, out);
    out.push("\n");
}

// A <binding> at `indent` (a node's, or milestone 45: an Event's).
function binding(out: StringBuilder, indent: string, bd: BindingDecl): void {
    out.push(indent).push("<binding");
    attr(out, "property", bd.property);
    attr(out, "path", bd.path);
    if (bd.mode.length > 0) attr(out, "mode", bd.mode);
    if (bd.writesOnce()) attr(out, "once", bd.once);
    if (bd.global.length > 0) attr(out, "global", bd.global);
    if (bd.converter.length > 0) attr(out, "converter", bd.converter);
    if (bd.scale.length > 0) attr(out, "scale", bd.scale);
    if (bd.offset.length > 0) attr(out, "offset", bd.offset);
    if (bd.convert.length > 0) attr(out, "convert", bd.convert);
    unknownAttrs(out, bd.attrs, BINDING_ATTRS);
    out.push("/>\n");
}

function bodyItem(out: StringBuilder, b: BodyItem): void {
    const p = b.property;
    if (b.kind == BodyKind.Property && p != null) {
        out.push("    <property");
        attr(out, "name", p.name);
        for (let k = 0; k < p.extraAttrs.length; k++) {
            const a = p.extraAttrs[k];
            if (a.name != "name") attr(out, a.name, a.value);
        }
        out.push(">");
        const text = printValue(p.value);
        // A CDATA section cannot hold "]]>": such a value is escaped instead.
        if (p.cdata && text.indexOf("]]>") < 0) out.push("<![CDATA[").push(text).push("]]>");
        else out.push(escapeXmlText(text));
        out.push("</property>\n");
        return;
    }
    if (b.kind == BodyKind.Group) {
        out.push("    <group");
        attr(out, "name", b.group);
        for (let k = 0; k < b.groupExtraAttrs.length; k++) {
            const a = b.groupExtraAttrs[k];
            if (a.name != "name") attr(out, a.name, a.value);
        }
        out.push("/>\n");
        return;
    }
    const bd = b.binding;
    if (b.kind == BodyKind.Binding && bd != null) {
        binding(out, "    ", bd);
        return;
    }
    const x = b.xml;
    if (x != null) xmlLine(out, "    ", x);
}

// Closes a start tag already written up to its attributes: `/>` when there
// is no body, else `>`, the body, and the end tag.
function bodyOf(out: StringBuilder, tag: string, d: Declaration): void {
    if (d.items.length == 0) {
        out.push("/>\n");
        return;
    }
    out.push(">\n");
    for (let k = 0; k < d.items.length; k++) bodyItem(out, d.items[k]);
    out.push("  </").push(tag).push(">\n");
}

function childrenOf(out: StringBuilder, tag: string, children: Array<XmlNode>): void {
    if (children.length == 0) {
        out.push("/>\n");
        return;
    }
    out.push(">\n");
    for (let k = 0; k < children.length; k++) xmlLine(out, "    ", children[k]);
    out.push("  </").push(tag).push(">\n");
}

// Milestone 42: a converter at `indent` (and its children 2 deeper): the
// name (a top-level one's), then its attributes in order (an `id` among
// them, when one was written: kept, and warned of by the validator).
function converter(out: StringBuilder, indent: string, d: DataConverterDecl, top: bool): void {
    out.push(indent).push("<").push(d.type);
    if (top) attr(out, "name", d.name);
    for (let k = 0; k < d.attrs.length; k++) attr(out, d.attrs[k].name, d.attrs[k].value);
    if (d.items.length == 0 && d.children.length == 0) {
        out.push("/>\n");
        return;
    }
    out.push(">\n");
    const inner = indent + "  ";
    for (let k = 0; k < d.items.length; k++) {
        out.push(inner).push("<DataConverterGroupItem");
        attr(out, "converter", d.items[k]);
        out.push("/>\n");
    }
    for (let k = 0; k < d.children.length; k++) converter(out, inner, d.children[k], false);
    out.push(indent).push("</").push(d.type).push(">\n");
}

// --- timelines (milestone 45)

// Every attribute of `attrs` (the declaration's extraAttrs: none of them a
// known one), in order.
function extraAttrs(out: StringBuilder, attrs: Array<XmlAttr>): void {
    for (let k = 0; k < attrs.length; k++) attr(out, attrs[k].name, attrs[k].value);
}

// The kept children of an element, one a line at `indent`.
function extraLines(out: StringBuilder, indent: string, children: Array<XmlNode>): void {
    for (let k = 0; k < children.length; k++) xmlLine(out, indent, children[k]);
}

// A colour as RML writes one: 8 uppercase hex digits, ARGB.
export function argbText(c: u32): string {
    let t = c.toString(16).toUpperCase();
    while (t.length < 8) t = "0" + t;
    return t;
}

function customProperty(out: StringBuilder, indent: string, p: CustomPropertyDecl): void {
    out.push(indent).push("<").push(CUSTOM_PROPERTY_ELEMENTS[<i32>p.kind]);
    attr(out, "name", p.name);
    let v = p.text;
    if (p.kind == CustomPropertyKind.Number) v = printNumber(p.number);
    else if (p.kind == CustomPropertyKind.Boolean) v = p.boolean ? "true" : "false";
    attr(out, "propertyValue", v);
    extraAttrs(out, p.extraAttrs);
    out.push("/>\n");
}

function event(out: StringBuilder, d: EventDecl): void {
    out.push("  <").push(EVENT_ELEMENT);
    attr(out, "name", d.name);
    extraAttrs(out, d.extraAttrs);
    if (d.properties.length == 0 && d.bindings.length == 0 && d.extraChildren.length == 0) {
        out.push("/>\n");
        return;
    }
    out.push(">\n");
    for (let k = 0; k < d.properties.length; k++) customProperty(out, "    ", d.properties[k]);
    for (let k = 0; k < d.bindings.length; k++) binding(out, "    ", d.bindings[k]);
    extraLines(out, "    ", d.extraChildren);
    out.push("  </").push(EVENT_ELEMENT).push(">\n");
}

// A keyframe's value as its `value` attribute says it ("" for a callback,
// which has none).
export function keyValueText(k: KeyFrameDecl): string {
    switch (k.kind) {
        case KeyFrameKind.Double:
        case KeyFrameKind.Int:
        case KeyFrameKind.Uint:
            return printNumber(k.number);
        case KeyFrameKind.Bool: return k.boolean ? "true" : "false";
        case KeyFrameKind.Color: return argbText(k.color);
        case KeyFrameKind.Quaternion:
            return printNumber(k.qx) + ", " + printNumber(k.qy) + ", " + printNumber(k.qz) + ", " + printNumber(k.qw);
        case KeyFrameKind.Callback: return "";
        default: return k.text;
    }
}

function interpolator(out: StringBuilder, indent: string, d: InterpolatorDecl): void {
    const tag = INTERPOLATOR_ELEMENTS[<i32>d.kind];
    out.push(indent).push("<").push(tag);
    if (d.kind == InterpolatorKind.Elastic) {
        attr(out, "easingValue", d.easingValue.toString());
        attr(out, "amplitude", printNumber(d.amplitude));
        attr(out, "period", printNumber(d.period));
    } else {
        attr(out, "x1", printNumber(d.x1));
        attr(out, "y1", printNumber(d.y1));
        attr(out, "x2", printNumber(d.x2));
        attr(out, "y2", printNumber(d.y2));
    }
    extraAttrs(out, d.extraAttrs);
    if (d.extraChildren.length == 0) {
        out.push("/>\n");
        return;
    }
    out.push(">\n");
    extraLines(out, indent + "  ", d.extraChildren);
    out.push(indent).push("</").push(tag).push(">\n");
}

function keyFrame(out: StringBuilder, indent: string, k: KeyFrameDecl): void {
    const tag = KEYFRAME_ELEMENTS[<i32>k.kind];
    out.push(indent).push("<").push(tag);
    attr(out, "frame", k.frame.toString());
    if (k.kind != KeyFrameKind.Callback) attr(out, "value", keyValueText(k));
    if (k.interpolation != InterpolationType.Hold) attr(out, "interpolationType", INTERPOLATION_NAMES[<i32>k.interpolation]);
    extraAttrs(out, k.extraAttrs);
    const ip = k.interpolator;
    if (ip == null && k.extraChildren.length == 0) {
        out.push("/>\n");
        return;
    }
    out.push(">\n");
    const inner = indent + "  ";
    if (ip != null) interpolator(out, inner, ip);
    extraLines(out, inner, k.extraChildren);
    out.push(indent).push("</").push(tag).push(">\n");
}

function keyedProperty(out: StringBuilder, p: KeyedPropertyDecl): void {
    out.push("      <").push(KEYED_PROPERTY_ELEMENT);
    attr(out, "property", p.property);
    extraAttrs(out, p.extraAttrs);
    if (p.keys.length == 0 && p.extraChildren.length == 0) {
        out.push("/>\n");
        return;
    }
    out.push(">\n");
    for (let k = 0; k < p.keys.length; k++) keyFrame(out, "        ", p.keys[k]);
    extraLines(out, "        ", p.extraChildren);
    out.push("      </").push(KEYED_PROPERTY_ELEMENT).push(">\n");
}

function keyedObject(out: StringBuilder, o: KeyedObjectDecl): void {
    out.push("    <").push(KEYED_OBJECT_ELEMENT);
    attr(out, "target", o.target);
    extraAttrs(out, o.extraAttrs);
    if (o.properties.length == 0 && o.extraChildren.length == 0) {
        out.push("/>\n");
        return;
    }
    out.push(">\n");
    for (let k = 0; k < o.properties.length; k++) keyedProperty(out, o.properties[k]);
    extraLines(out, "      ", o.extraChildren);
    out.push("    </").push(KEYED_OBJECT_ELEMENT).push(">\n");
}

function animation(out: StringBuilder, d: LinearAnimationDecl): void {
    out.push("  <").push(ANIMATION_ELEMENT);
    attr(out, "name", d.name);
    attr(out, "fps", d.fps.toString());
    attr(out, "duration", d.duration.toString());
    if (d.speed != 1) attr(out, "speed", printNumber(d.speed));
    attr(out, "loopValue", LOOP_NAMES[<i32>d.loop]);
    if (d.workStart >= 0) attr(out, "workStart", d.workStart.toString());
    if (d.workEnd >= 0) attr(out, "workEnd", d.workEnd.toString());
    if (d.enableWorkArea) attr(out, "enableWorkArea", "true");
    if (d.quantize) attr(out, "quantize", "true");
    extraAttrs(out, d.extraAttrs);
    if (d.objects.length == 0 && d.extraChildren.length == 0) {
        out.push("/>\n");
        return;
    }
    out.push(">\n");
    for (let k = 0; k < d.objects.length; k++) keyedObject(out, d.objects[k]);
    extraLines(out, "    ", d.extraChildren);
    out.push("  </").push(ANIMATION_ELEMENT).push(">\n");
}

// --- state machines

// Closes an element whose attributes are written: `/>` when `empty`, else
// `>` (the caller writes the children, then elementEnd).
function opened(out: StringBuilder, empty: bool): bool {
    out.push(empty ? "/>\n" : ">\n");
    return !empty;
}

function elementEnd(out: StringBuilder, indent: string, tag: string): void {
    out.push(indent).push("</").push(tag).push(">\n");
}

function flag(out: StringBuilder, name: string, on: bool): void {
    if (on) attr(out, name, "true");
}

function smInput(out: StringBuilder, indent: string, d: InputDecl): void {
    const tag = INPUT_ELEMENTS[<i32>d.kind];
    out.push(indent).push("<").push(tag);
    attr(out, "name", d.name);
    if (d.kind == InputKind.Number) attr(out, "value", printNumber(d.number));
    else if (d.kind == InputKind.Bool) attr(out, "value", d.boolean ? "true" : "false");
    extraAttrs(out, d.extraAttrs);
    if (!opened(out, d.bindings.length == 0 && d.extraChildren.length == 0)) return;
    const inner = indent + "  ";
    for (let k = 0; k < d.bindings.length; k++) binding(out, inner, d.bindings[k]);
    extraLines(out, inner, d.extraChildren);
    elementEnd(out, indent, tag);
}

function smBlend(out: StringBuilder, indent: string, b: BlendAnimationDecl): void {
    const tag = b.direct ? BLEND_ANIMATION_DIRECT_ELEMENT : BLEND_ANIMATION_1D_ELEMENT;
    out.push(indent).push("<").push(tag);
    attr(out, "animation", b.animation);
    if (!b.direct) attr(out, "value", printNumber(b.value));
    else {
        // (the source's attribute; any other one set too is written as well,
        // so that blend-source-ambiguous survives a format)
        if (b.source == BlendSource.Input || b.input.length > 0) attr(out, "input", b.input);
        if (b.source == BlendSource.ViewModel || b.path.length > 0) attr(out, "path", b.path);
        if (b.global.length > 0) attr(out, "global", b.global);
        if (b.converter.length > 0) attr(out, "converter", b.converter);
        if (b.mixValue != 100) attr(out, "mixValue", printNumber(b.mixValue));
    }
    extraAttrs(out, b.extraAttrs);
    if (!opened(out, b.extraChildren.length == 0)) return;
    extraLines(out, indent + "  ", b.extraChildren);
    elementEnd(out, indent, tag);
}

function smAction(out: StringBuilder, indent: string, a: FireActionDecl): void {
    const tag = ACTION_ELEMENTS[<i32>a.kind];
    out.push(indent).push("<").push(tag);
    if (a.kind == ActionKind.FireEvent) attr(out, "event", a.event);
    else {
        attr(out, "path", a.path);
        if (a.global.length > 0) attr(out, "global", a.global);
    }
    attr(out, "occursValue", a.occurs.toString());
    extraAttrs(out, a.extraAttrs);
    if (!opened(out, a.extraChildren.length == 0)) return;
    extraLines(out, indent + "  ", a.extraChildren);
    elementEnd(out, indent, tag);
}

function smCondition(out: StringBuilder, indent: string, c: ConditionDecl): void {
    const tag = CONDITION_ELEMENTS[<i32>c.kind];
    out.push(indent).push("<").push(tag);
    const op = CONDITION_OP_NAMES[<i32>c.op];
    switch (c.kind) {
        case ConditionKind.ViewModel:
        case ConditionKind.Component: {
            if (c.kind == ConditionKind.ViewModel) {
                attr(out, "path", c.path);
                if (c.global.length > 0) attr(out, "global", c.global);
                if (c.converter.length > 0) attr(out, "converter", c.converter);
            } else {
                attr(out, "target", c.target);
                attr(out, "property", c.property);
            }
            attr(out, "opValue", op);
            // (both sides when both were given: condition-value-both
            // survives a format)
            if (c.hasValue) attr(out, "value", c.value);
            if (c.rightPath.length > 0 || c.rightGlobal.length > 0 || c.rightConverter.length > 0) {
                attr(out, "rightPath", c.rightPath);
                if (c.rightGlobal.length > 0) attr(out, "rightGlobal", c.rightGlobal);
                if (c.rightConverter.length > 0) attr(out, "rightConverter", c.rightConverter);
            }
            break;
        }
        case ConditionKind.Number:
            attr(out, "input", c.input);
            attr(out, "opValue", op);
            if (c.hasValue) attr(out, "value", c.value);
            break;
        case ConditionKind.Bool:
            attr(out, "input", c.input);
            attr(out, "opValue", op);
            break;
        default:
            attr(out, "input", c.input);
    }
    extraAttrs(out, c.extraAttrs);
    if (!opened(out, c.extraChildren.length == 0)) return;
    extraLines(out, indent + "  ", c.extraChildren);
    elementEnd(out, indent, tag);
}

function smTransition(out: StringBuilder, indent: string, t: TransitionDecl): void {
    out.push(indent).push("<").push(TRANSITION_ELEMENT);
    attr(out, "to", t.to);
    if (t.duration != 0) attr(out, "duration", t.duration.toString());
    flag(out, "durationIsPercentage", t.durationIsPercentage);
    if (t.exitTime != 0) attr(out, "exitTime", t.exitTime.toString());
    flag(out, "enableExitTime", t.enableExitTime);
    flag(out, "exitTimeIsPercentage", t.exitTimeIsPercentage);
    if (t.interpolation != InterpolationType.Linear) attr(out, "interpolationType", INTERPOLATION_NAMES[<i32>t.interpolation]);
    if (t.randomWeight != 1) attr(out, "randomWeight", t.randomWeight.toString());
    flag(out, "pauseOnExit", t.pauseOnExit);
    flag(out, "enableEarlyExit", t.enableEarlyExit);
    flag(out, "disabled", t.disabled);
    extraAttrs(out, t.extraAttrs);
    const ip = t.interpolator;
    if (!opened(out, ip == null && t.conditions.length == 0 && t.actions.length == 0 && t.extraChildren.length == 0)) return;
    const inner = indent + "  ";
    if (ip != null) interpolator(out, inner, ip);
    for (let k = 0; k < t.conditions.length; k++) smCondition(out, inner, t.conditions[k]);
    for (let k = 0; k < t.actions.length; k++) smAction(out, inner, t.actions[k]);
    extraLines(out, inner, t.extraChildren);
    elementEnd(out, indent, TRANSITION_ELEMENT);
}

function smState(out: StringBuilder, indent: string, s: StateDecl): void {
    const tag = STATE_ELEMENTS[<i32>s.kind];
    out.push(indent).push("<").push(tag);
    if (s.kind == StateKind.Animation) {
        if (s.name.length > 0 && s.name != s.animation) attr(out, "name", s.name);
        if (s.animation.length > 0) attr(out, "animation", s.animation);
    } else if (isBlendState(s.kind)) {
        attr(out, "name", s.name);
        if (s.kind == StateKind.Blend1DViewModel) {
            attr(out, "path", s.path);
            if (s.global.length > 0) attr(out, "global", s.global);
            if (s.converter.length > 0) attr(out, "converter", s.converter);
        } else if (s.kind == StateKind.Blend1DInput) {
            attr(out, "input", s.input);
        }
    }
    if (!isSystemState(s.kind)) {
        if (s.speed != 1) attr(out, "speed", printNumber(s.speed));
        flag(out, "reset", s.reset);
        flag(out, "random", s.random);
    }
    attr(out, "x", printNumber(s.x));
    attr(out, "y", printNumber(s.y));
    extraAttrs(out, s.extraAttrs);
    if (!opened(out, s.blends.length == 0 && s.actions.length == 0 && s.transitions.length == 0 && s.extraChildren.length == 0)) return;
    const inner = indent + "  ";
    for (let k = 0; k < s.blends.length; k++) smBlend(out, inner, s.blends[k]);
    for (let k = 0; k < s.actions.length; k++) smAction(out, inner, s.actions[k]);
    for (let k = 0; k < s.transitions.length; k++) smTransition(out, inner, s.transitions[k]);
    extraLines(out, inner, s.extraChildren);
    elementEnd(out, indent, tag);
}

function smLayer(out: StringBuilder, indent: string, l: LayerDecl): void {
    out.push(indent).push("<").push(LAYER_ELEMENT);
    attr(out, "name", l.name);
    extraAttrs(out, l.extraAttrs);
    if (!opened(out, l.states.length == 0 && l.extraChildren.length == 0)) return;
    const inner = indent + "  ";
    for (let k = 0; k < l.states.length; k++) smState(out, inner, l.states[k]);
    extraLines(out, inner, l.extraChildren);
    elementEnd(out, indent, LAYER_ELEMENT);
}

// Milestone 47: a ListenerNumberChange's value in its shortest form (one
// that does not read as a number, which only a document built in code
// holds, as it is).
export function listenerNumberText(v: string): string {
    const x = rmlNumberOf(v);
    return isNaN(x) ? v : printNumber(x);
}

// A listener's action: the attributes its kind reads, in RSCN.md's order
// (a ListenerViewModelChange's sources each when set: two of them, the
// validator's listener-action-source-ambiguous, are written as kept).
function smListenerAction(out: StringBuilder, indent: string, a: ListenerActionDecl): void {
    const tag = LISTENER_ACTION_ELEMENTS[<i32>a.kind];
    out.push(indent).push("<").push(tag);
    switch (a.kind) {
        case ListenerActionKind.ViewModelChange:
            attr(out, "path", a.path);
            if (a.global.length > 0) attr(out, "global", a.global);
            if (a.hasValue) attr(out, "value", a.value);
            if (a.fromPath.length > 0) attr(out, "fromPath", a.fromPath);
            if (a.fromGlobal.length > 0) attr(out, "fromGlobal", a.fromGlobal);
            if (a.input.length > 0) attr(out, "input", a.input);
            if (a.converter.length > 0) attr(out, "converter", a.converter);
            break;
        case ListenerActionKind.BoolChange:
            attr(out, "input", a.input);
            attr(out, "value", a.value);
            break;
        case ListenerActionKind.NumberChange:
            attr(out, "input", a.input);
            attr(out, "value", listenerNumberText(a.value));
            break;
        case ListenerActionKind.TriggerChange:
            attr(out, "input", a.input);
            break;
        case ListenerActionKind.FireEvent:
            attr(out, "event", a.event);
            break;
        default:
            attr(out, "target", a.target);
            flag(out, "surface", a.surface);
            flag(out, "preserveOffset", a.preserveOffset);
    }
    extraAttrs(out, a.extraAttrs);
    if (!opened(out, a.extraChildren.length == 0)) return;
    extraLines(out, indent + "  ", a.extraChildren);
    elementEnd(out, indent, tag);
}

// `<StateMachineListener name target listenerType event path global>`
// (each of target, event, path and global only when not empty; the type
// always) and its actions in order, then what is kept.
function smListener(out: StringBuilder, indent: string, l: ListenerDecl): void {
    out.push(indent).push("<").push(LISTENER_ELEMENT);
    attr(out, "name", l.name);
    if (l.target.length > 0) attr(out, "target", l.target);
    attr(out, "listenerType", LISTENER_TYPE_NAMES[<i32>l.type]);
    if (l.event.length > 0) attr(out, "event", l.event);
    if (l.path.length > 0) attr(out, "path", l.path);
    if (l.global.length > 0) attr(out, "global", l.global);
    extraAttrs(out, l.extraAttrs);
    if (!opened(out, l.actions.length == 0 && l.extraChildren.length == 0)) return;
    const inner = indent + "  ";
    for (let k = 0; k < l.actions.length; k++) smListenerAction(out, inner, l.actions[k]);
    extraLines(out, inner, l.extraChildren);
    elementEnd(out, indent, LISTENER_ELEMENT);
}

function stateMachine(out: StringBuilder, d: StateMachineDecl): void {
    out.push("  <").push(STATE_MACHINE_ELEMENT);
    attr(out, "name", d.name);
    extraAttrs(out, d.extraAttrs);
    if (!opened(out, d.inputs.length == 0 && d.layers.length == 0 && d.listeners.length == 0 && d.extraChildren.length == 0)) return;
    for (let k = 0; k < d.inputs.length; k++) smInput(out, "    ", d.inputs[k]);
    for (let k = 0; k < d.layers.length; k++) smLayer(out, "    ", d.layers[k]);
    for (let k = 0; k < d.listeners.length; k++) smListener(out, "    ", d.listeners[k]);
    extraLines(out, "    ", d.extraChildren);
    elementEnd(out, "  ", STATE_MACHINE_ELEMENT);
}

function entry(out: StringBuilder, e: Entry): void {
    const ext = e.ext;
    if (ext != null) {
        out.push("  <ext_resource");
        attr(out, "id", ext.id);
        attr(out, "type", ext.type);
        attr(out, "path", ext.path);
        const uid = ext.uid;
        if (uid != null) attr(out, "uid", uid);
        unknownAttrs(out, ext.attrs, EXT_ATTRS);
        childrenOf(out, "ext_resource", ext.extraChildren);
        return;
    }
    const sub = e.sub;
    if (sub != null) {
        out.push("  <sub_resource");
        attr(out, "id", sub.id);
        attr(out, "type", sub.type);
        unknownAttrs(out, sub.attrs, SUB_ATTRS);
        bodyOf(out, "sub_resource", sub);
        return;
    }
    const res = e.res;
    if (res != null) {
        out.push("  <resource");
        attr(out, "type", res.type);
        unknownAttrs(out, res.attrs, RESOURCE_ATTRS);
        bodyOf(out, "resource", res);
        return;
    }
    const node = e.node;
    if (node != null) {
        out.push("  <node");
        attr(out, "name", node.name);
        const type = node.type;
        if (type != null) attr(out, "type", type);
        const parent = node.parent;
        if (parent != null) attr(out, "parent", parent);
        const inst = node.instance;
        if (inst != null) attr(out, "instance", printValue(inst));
        unknownAttrs(out, node.attrs, NODE_ATTRS);
        bodyOf(out, "node", node);
        return;
    }
    const c = e.connection;
    if (c != null) {
        out.push("  <connection");
        attr(out, "signal", c.signal);
        attr(out, "from", c.from);
        attr(out, "to", c.to);
        attr(out, "method", c.method);
        if (c.flags != 0) attr(out, "flags", c.flags.toString());
        unknownAttrs(out, c.attrs, CONNECTION_ATTRS);
        childrenOf(out, "connection", c.extraChildren);
        return;
    }
    const conv = e.converter;
    if (conv != null) {
        converter(out, "  ", conv, true);
        return;
    }
    const ev = e.event;
    if (ev != null) {
        event(out, ev);
        return;
    }
    const an = e.animation;
    if (an != null) {
        animation(out, an);
        return;
    }
    const sm = e.stateMachine;
    if (sm != null) {
        stateMachine(out, sm);
        return;
    }
    const em = e.embedded;
    if (em != null) {
        // Content that did not decode is written back as it was read, so
        // that a bad file is reported (validate.as) rather than lost.
        const raw = em.xml;
        if (em.invalid.length > 0 && raw != null) {
            xmlLine(out, "  ", raw);
            return;
        }
        out.push("  <embedded");
        attr(out, "path", em.path);
        attr(out, "size", em.size.toString());
        unknownAttrs(out, em.attrs, EMBEDDED_ATTRS);
        if (em.data.length == 0) {
            out.push("/>\n");
            return;
        }
        out.push(">\n");
        const b64 = base64Encode(em.data);
        for (let at = 0; at < b64.length; at += EMBEDDED_LINE) {
            out.push("    ").push(b64.substring(at, at + EMBEDDED_LINE)).push("\n");
        }
        out.push("  </embedded>\n");
        return;
    }
    const x = e.xml;
    if (x != null) xmlLine(out, "  ", x);
}

// The group each entry's blank-line rule uses (see the header).
function groupsOf(entries: Array<Entry>): Array<i32> {
    const groups = new Array<i32>(entries.length);
    let next = -1;
    for (let k = entries.length - 1; k >= 0; k--) {
        const s = entries[k].section();
        if (s >= 0) next = s;
        groups[k] = next;
    }
    // Trailing comments and unknown elements (no known entry after them)
    // stay with the last known entry; with no known entry at all, 0.
    let last = 0;
    for (let k = 0; k < entries.length; k++) {
        const s = entries[k].section();
        if (s >= 0) last = s;
        if (groups[k] < 0) groups[k] = last;
    }
    return groups;
}

// The document's canonical text (UTF-8 once encoded; "\n" line ends; ends
// with "\n").
export function writeRscn(doc: RscnDoc): string {
    const out = new StringBuilder();
    const tag = doc.rootTag();
    out.push(XML_DECLARATION_LINE).push("\n");
    for (let k = 0; k < doc.prolog.length; k++) xmlLine(out, "", doc.prolog[k]);
    out.push("<").push(tag);
    attr(out, "format", formatNeeded(doc).toString());
    const uid = doc.uid;
    if (uid != null) attr(out, "uid", uid);
    unknownAttrs(out, doc.rootAttrs, ROOT_ATTRS);
    if (doc.entries.length == 0) out.push("/>\n");
    else {
        out.push(">\n");
        const groups = groupsOf(doc.entries);
        for (let k = 0; k < doc.entries.length; k++) {
            if (k > 0 && groups[k] != groups[k - 1]) out.push("\n");
            entry(out, doc.entries[k]);
        }
        out.push("</").push(tag).push(">\n");
    }
    for (let k = 0; k < doc.epilog.length; k++) xmlLine(out, "", doc.epilog[k]);
    return out.toString();
}
