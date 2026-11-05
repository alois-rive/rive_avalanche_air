// The .rscn reader: bytes to an RscnDoc (doc.as), through the XML reader
// (engine/src/base/xml.as) and the value literal parser (../value_text.as).
// It checks the structure (the root element and its format, the elements
// and attributes each kind requires, the order of the sections, the value
// literals) and stops at the first problem, as a SceneryError naming
// file:line:column; what depends on more than one element (ids, parents,
// references, the classes' properties) is the validator's (validate.as).
// docs/formats/RSCN.md, "Reading", is the normative list.
//
// Everything the reader does not know (elements, attributes, processing
// instructions) and every comment is kept where it was in the RscnDoc, so
// that the writer puts it back and a file from a newer tool survives.
//
// Milestone 42: format 2 (doc.as). A top-level element whose name is a
// converter's (RML's DataConverter*, ../data/model.as isConverterElement)
// is a converter declaration, in a section of its own between the
// sub_resources and the nodes; `<binding>` gains once, global and
// converter. Whether a format-1 file uses any of it is the validator's to
// say (format-feature), with every other problem.
//
// Format 2 also holds Rive's timelines (../anim/decl.as; RSCN.md,
// "Animations"): top-level <Event> and <LinearAnimation> elements, two
// sections of their own between the nodes and the connections, read whole
// into their declarations. Their attributes are RML's, read by name
// (interpolationType and loopValue as words, never as numbers); what this
// version does not know (attributes, elements, comments) is kept in each
// declaration's extraAttrs and extraChildren and written back.
//
// Format 2 also holds Rive's state machines (../sm/decl.as; RSCN.md, "State
// machines"): top-level <StateMachine> elements, a section of their own
// after the animations, read whole into their declarations with the same
// rules (RML's names, words for interpolationType and opValue, the compact
// condition forms, RML's misspelt exitTimeIsPercetange read as
// exitTimeIsPercentage). Milestone 47: a machine's <StateMachineListener>s
// are read into its listeners (RML's names; ListenerBoolChange's RML values
// 0, 1 and 2 read as false, true and toggle); RML's folded
// StateMachineListenerSingle, a general form's ListenerInputType children
// and a ScriptedListenerAction are not .rscn's and stay kept, unknown.

import { Result, i64FitsI32, i64FitsU32 } from "../../base/util";
import { base64DecodeSpan } from "../../fs/base64";
import { XmlAttr, XmlDocument, XmlKind, XmlNode, parseXml, parseXmlHead, parseXmlText, xmlErrorOf } from "../../base/xml";
import { SceneryError } from "../error";
import { DocReader, decimalOf, firstNonSpace, isBlank, isSpace } from "../textdoc/read";
import { DataAttr, DataConverterDecl, isConverterElement } from "../data/model";
import { rmlColorOf, rmlNumberOf } from "../data/rml_read";
import {
    ANIMATION_ELEMENT, CustomPropertyDecl, CustomPropertyKind, EVENT_ELEMENT, ELASTIC_EASE_IN, ELASTIC_EASE_IN_OUT, EventDecl,
    INTERPOLATION_NAMES, InterpolationType, InterpolatorDecl, InterpolatorKind, KEYED_OBJECT_ELEMENT, KEYED_PROPERTY_ELEMENT,
    KeyFrameDecl, KeyFrameKind, KeyedObjectDecl, KeyedPropertyDecl, LOOP_NAMES, LinearAnimationDecl, LoopMode, customPropertyKindOf,
    interpolationOf, interpolatorKindOf, keyFrameKindOf, loopOf,
} from "../anim/decl";
import {
    ACTION_ELEMENTS, ActionKind, BLEND_ANIMATION_1D_ELEMENT, BLEND_ANIMATION_DIRECT_ELEMENT, BlendAnimationDecl, BlendSource,
    CONDITION_ELEMENTS, CONDITION_OP_NAMES, ConditionDecl, ConditionKind, ConditionOp, FireActionDecl, INPUT_ELEMENTS, InputDecl,
    InputKind, LAYER_ELEMENT, LISTENER_ACTION_ELEMENTS, LISTENER_ELEMENT, LISTENER_TYPE_NAMES, LayerDecl, ListenerActionDecl,
    ListenerActionKind, ListenerDecl, ListenerType, OCCURS_AT_END, POINTER_INPUT_NAMES, STATE_ELEMENTS, STATE_MACHINE_ELEMENT,
    StateDecl, StateKind, StateMachineDecl, TRANSITION_ELEMENT, TransitionDecl, actionKindOf, conditionKindOf, conditionOpOf,
    inputKindOf, listenerActionKindOf, listenerTypeOf, pointerInputOf, stateKindOf,
} from "../sm/decl";
import { ValueKind } from "../value";
import { parseValueText, printNumber, printValue } from "../value_text";
import {
    BindingDecl, BodyItem, BodyKind, ConnectionDecl, Declaration, DocKind, EmbeddedDecl, Entry, EntryKind, FORMAT_VERSION,
    NodeDecl, Property, RscnDoc, SubResourceDecl,
} from "./doc";

// The sections by Entry.section()'s index: the converters' (milestone 42)
// is every converter element, named so in messages; the events' and the
// animations' (milestone 45) are named by their elements, and so are the
// state machines' (milestone 46).
const SECTION_NAMES: Array<string> = [
    "ext_resource", "sub_resource", "converter", "node", EVENT_ELEMENT, ANIMATION_ELEMENT, STATE_MACHINE_ELEMENT, "connection",
    "embedded",
];
const CONVERTER_SECTION: i32 = 2;
const NODE_SECTION: i32 = 3;
const EVENT_SECTION: i32 = 4;
const ANIMATION_SECTION: i32 = 5;
const STATE_MACHINE_SECTION: i32 = 6;
const EMBEDDED_SECTION: i32 = 8;

// The hint of a `scripted` interpolation, which Rive has and 3D does not.
export const SCRIPTED_HINT = "Rive's scripted interpolation is not supported in 3D: use hold, linear, cubic, cubicValue or elastic";

// The section of a top-level element named `tag`, or -1 for an unknown one.
function sectionOf(tag: string): i32 {
    const k = SECTION_NAMES.indexOf(tag);
    if (k == CONVERTER_SECTION) return -1;
    if (k >= 0) return k;
    return isConverterElement(tag) ? CONVERTER_SECTION : -1;
}

// What `element-order` says the order is: format 1's sections, with the
// converters' and the packed scenes' named only where one is involved, so
// that the older messages stay as they were.
function orderText(a: i32, b: i32): string {
    const out = ["ext_resource", "sub_resource"];
    if (a == CONVERTER_SECTION || b == CONVERTER_SECTION) out.push("converters");
    out.push("node");
    if (a == EVENT_SECTION || b == EVENT_SECTION || a == ANIMATION_SECTION || b == ANIMATION_SECTION
        || a == STATE_MACHINE_SECTION || b == STATE_MACHINE_SECTION) {
        out.push(EVENT_ELEMENT);
        out.push(ANIMATION_ELEMENT);
    }
    if (a == STATE_MACHINE_SECTION || b == STATE_MACHINE_SECTION) out.push(STATE_MACHINE_ELEMENT);
    out.push("connection");
    if (a == EMBEDDED_SECTION || b == EMBEDDED_SECTION) out.push("embedded");
    return out.join(", ");
}

// A section's name in "<x> after a <y>".
function sectionWord(k: i32): string {
    if (k == CONVERTER_SECTION) return "a converter";
    return (k == EMBEDDED_SECTION || k == EVENT_SECTION ? "an " : "a ") + SECTION_NAMES[k];
}

// The hint of every `xml-syntax` error: the message says what the XML
// reader expected; this says what usually causes it.
export const XML_SYNTAX_HINT = "a .rscn is XML: close every element, quote every attribute value, and write & < > in text as &amp; &lt; &gt;";

// What the first problem was (DocReader: `fail` keeps it and returns
// false; the root, required attributes, blank text, ext_resources and a
// property's text are read there, as the .rmdl reader reads them).
class Reader extends DocReader {
    constructor(file: string) {
        super(file);
    }

    document(x: XmlDocument): RscnDoc? {
        const root = x.root;
        const doc = new RscnDoc(this.file, DocKind.Scene);
        const tag = doc.rootTag();
        const info = this.root(x, tag, "a scene file", FORMAT_VERSION, "write format=\"1\" on <" + tag + "> (format=\""
            + FORMAT_VERSION.toString() + "\" for a file that uses what format " + FORMAT_VERSION.toString() + " adds)");
        if (info == null) return null;
        doc.pos = root.pos.clone();
        doc.prolog = x.prolog;
        doc.epilog = x.epilog;
        for (let k = 0; k < info.attrs.length; k++) doc.rootAttrs.push(info.attrs[k]);
        doc.format = info.format;
        doc.uid = info.uid;

        let highest = -1;
        for (let k = 0; k < root.children.length; k++) {
            const c = root.children[k];
            if (c.kind == XmlKind.Text) {
                if (!this.blankText(c, "<" + tag + ">")) return null;
                continue;
            }
            if (c.kind == XmlKind.CData) {
                this.fail("text-unexpected", c.pos, "a CDATA section inside <" + tag + ">: only elements and comments belong there");
                return null;
            }
            if (c.kind == XmlKind.Comment) {
                const e = new Entry(EntryKind.Comment);
                e.xml = c;
                doc.entries.push(e);
                continue;
            }
            if (c.kind == XmlKind.Pi) {
                const e = new Entry(EntryKind.Unknown);
                e.xml = c;
                doc.entries.push(e);
                continue;
            }
            const section = sectionOf(c.name);
            if (section < 0) {
                const e = new Entry(EntryKind.Unknown);
                e.xml = c;
                doc.entries.push(e);
                continue;
            }
            if (section < highest) {
                this.fail("element-order", c.pos, c.name + " after " + sectionWord(highest)
                    + ": elements come in the order " + orderText(section, highest));
                return null;
            }
            highest = section;
            const e = this.entry(c, section);
            if (e == null) return null;
            doc.entries.push(e);
        }
        return doc;
    }

    entry(el: XmlNode, section: i32): Entry? {
        if (section == EMBEDDED_SECTION) return this.embedded(el);
        if (section == CONVERTER_SECTION) return this.converterEntry(el);
        if (section == EVENT_SECTION) {
            const ev = this.event(el);
            if (ev == null) return null;
            const e = new Entry(EntryKind.Event);
            e.event = ev;
            return e;
        }
        if (section == STATE_MACHINE_SECTION) {
            const sm = this.stateMachine(el);
            if (sm == null) return null;
            const e = new Entry(EntryKind.StateMachine);
            e.stateMachine = sm;
            return e;
        }
        if (section == ANIMATION_SECTION) {
            const an = this.animation(el);
            if (an == null) return null;
            const e = new Entry(EntryKind.Animation);
            e.animation = an;
            return e;
        }
        if (section == 0) {
            const d = this.extResource(el);
            if (d == null) return null;
            const e = new Entry(EntryKind.ExtResource);
            e.ext = d;
            return e;
        }
        if (section == 1) {
            const id = this.required(el, "id");
            if (id == null) return null;
            const type = this.required(el, "type");
            if (type == null || !this.typeOk(type, el)) return null;
            const d = new SubResourceDecl(id.value, type.value);
            d.pos = el.pos.clone();
            d.attrs = el.attrs;
            if (!this.body(el, d)) return null;
            const e = new Entry(EntryKind.SubResource);
            e.sub = d;
            return e;
        }
        if (section == NODE_SECTION) {
            const name = this.required(el, "name");
            if (name == null) return null;
            const d = new NodeDecl(name.value);
            const type = el.attrNode("type");
            if (!this.typeOk(type, el)) return null;
            if (type != null) d.type = type.value;
            d.parent = el.attr("parent");
            const inst = el.attrNode("instance");
            if (inst != null) {
                const p = parseValueText(inst.value);
                if (!p.ok) {
                    this.fail("value-syntax", inst.positionAt(p.errOffset), p.errMessage, p.errHint);
                    return null;
                }
                if (p.value.kind != ValueKind.ExtResource) {
                    this.fail("attribute-invalid", inst.valuePos, "instance must be ExtResource(\"id\")");
                    return null;
                }
                d.instance = p.value;
            }
            d.pos = el.pos.clone();
            d.attrs = el.attrs;
            if (!this.body(el, d)) return null;
            const e = new Entry(EntryKind.Node);
            e.node = d;
            return e;
        }
        const signal = this.required(el, "signal");
        if (signal == null) return null;
        const from = this.required(el, "from");
        if (from == null) return null;
        const to = this.required(el, "to");
        if (to == null) return null;
        const method = this.required(el, "method");
        if (method == null) return null;
        const d = new ConnectionDecl(signal.value, from.value, to.value, method.value);
        const flags = el.attrNode("flags");
        if (flags != null) {
            const f = decimalOf(flags.value);
            if (!i64FitsI32(f)) {
                this.fail("attribute-invalid", flags.valuePos, "flags must be an integer, found \"" + flags.value + "\"");
                return null;
            }
            d.flags = <i32>f;
        }
        d.pos = el.pos.clone();
        d.attrs = el.attrs;
        if (!this.extraChildren(el, d.extraChildren)) return null;
        const e = new Entry(EntryKind.Connection);
        e.connection = d;
        return e;
    }

    // `<embedded path="res://..." size="N">base64</embedded>`. A missing
    // or malformed attribute is the reader's; content that is not padded
    // base64, or does not hold `size` bytes, is kept (`invalid`, and the
    // element itself) for the validator to report as embedded-invalid, so
    // that one bad file does not hide every other problem of the scene.
    embedded(el: XmlNode): Entry? {
        const path = this.required(el, "path");
        if (path == null) return null;
        const size = this.required(el, "size");
        if (size == null) return null;
        const n = decimalOf(size.value);
        if (n < 0 || size.value.startsWith("-")) {
            this.fail("attribute-invalid", size.valuePos, "size must be a whole number of bytes, found \"" + size.value + "\"");
            return null;
        }
        const d = new EmbeddedDecl(path.value, new Uint8Array(0));
        d.size = n;
        d.pos = el.pos.clone();
        d.attrs = el.attrs;
        d.xml = el;
        d.contentPos = el.children.length > 0 ? el.children[0].pos.clone() : el.pos.clone();
        // The base64 digits, whitespace dropped (lines of any length read).
        let total = 0;
        for (let k = 0; k < el.children.length; k++) total += el.children[k].text.length;
        const digits = new Uint8Array(total);
        let count = 0;
        for (let k = 0; k < el.children.length && d.invalid.length == 0; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Text) {
                const what = c.kind == XmlKind.Element ? "<" + c.name + ">" : c.kind == XmlKind.Comment ? "a comment"
                    : c.kind == XmlKind.CData ? "a CDATA section" : "a processing instruction";
                d.invalid = "<embedded> holds base64 text only, found " + what;
                d.contentPos = c.pos.clone();
                break;
            }
            const t = c.text;
            for (let j = 0; j < t.length; j++) {
                const ch = t.charCodeAt(j);
                if (isSpace(ch)) continue;
                if (ch > 0x7F) {
                    d.invalid = "the content is not base64: \"" + String.fromCharCode(ch) + "\" is not a base64 digit";
                    d.contentPos = c.positionAt(j);
                    break;
                }
                digits[count++] = <u8>ch;
            }
        }
        if (d.invalid.length == 0) {
            if (count % 4 != 0) {
                d.invalid = "the content is not padded base64: " + count.toString() + " digits, not a multiple of 4";
            } else {
                const r = base64DecodeSpan(digits, 0, count);
                if (!r.ok) d.invalid = "the content is not base64: " + r.err;
                else d.data = r.value;
            }
        }
        const e = new Entry(EntryKind.Embedded);
        e.embedded = d;
        return e;
    }

    // Milestone 42: a converter the scene declares (RIVE_MODEL.md section
    // 4.4): RML's element and attribute names, `name` required and not
    // empty; every other attribute kept in order (an `id`, which a scene's
    // converter does not take, too: the validator warns of it).
    converterEntry(el: XmlNode): Entry? {
        const d = this.converter(el, true);
        if (d == null) return null;
        const e = new Entry(EntryKind.Converter);
        e.converter = d;
        return e;
    }

    // A converter element, or one of its children (`top` false: a
    // formula's token, which has no name). Its children are elements only:
    // a group's `<DataConverterGroupItem converter="Name"/>` becomes one of
    // its `items` (only when that is all it holds), any other element a
    // child, kept as written; text, comments and processing instructions
    // are refused (a converter is data, which the writer prints whole).
    converter(el: XmlNode, top: bool): DataConverterDecl? {
        const d = new DataConverterDecl();
        d.type = el.name;
        d.where.file = this.file;
        d.where.line = el.pos.line;
        d.where.col = el.pos.col;
        if (top) {
            const name = this.required(el, "name");
            if (name == null) return null;
            if (name.value.length == 0) {
                this.fail("attribute-invalid", name.valuePos, "<" + el.name + "> name is empty");
                return null;
            }
            d.name = name.value;
        }
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            if (top && a.name == "name") continue;
            d.attrs.push(new DataAttr(a.name, a.value));
        }
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind == XmlKind.Text) {
                if (!this.blankText(c, "<" + el.name + ">")) return null;
                continue;
            }
            if (c.kind != XmlKind.Element) {
                const what = c.kind == XmlKind.Comment ? "a comment" : c.kind == XmlKind.CData ? "a CDATA section" : "a processing instruction";
                this.fail("property-content", c.pos, "<" + el.name + "> holds elements only, found " + what);
                return null;
            }
            if (c.name == "DataConverterGroupItem" && c.attrs.length == 1 && c.attrs[0].name == "converter" && c.children.length == 0) {
                d.items.push(c.attrs[0].value);
                continue;
            }
            const child = this.converter(c, false);
            if (child == null) return null;
            d.children.push(child);
        }
        return d;
    }

    // (ext_resource and connection have no content in format 1: whatever a
    // newer format puts there, elements, comments, PIs, is kept as it is by
    // DocReader.extraChildren.)

    // The content of a node or a sub_resource.
    body(el: XmlNode, d: Declaration): bool {
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind == XmlKind.Text) {
                if (!this.blankText(c, "<" + el.name + ">")) return false;
                continue;
            }
            if (c.kind == XmlKind.CData) {
                return this.fail("text-unexpected", c.pos, "a CDATA section inside <" + el.name + ">: only elements and comments belong there");
            }
            if (c.kind == XmlKind.Comment) {
                d.items.push(BodyItem.ofXml(BodyKind.Comment, c));
                continue;
            }
            if (c.kind == XmlKind.Pi || (c.name != "property" && c.name != "group" && c.name != "binding")) {
                d.items.push(BodyItem.ofXml(BodyKind.Unknown, c));
                continue;
            }
            if (c.name == "group") {
                const name = this.required(c, "name");
                if (name == null) return false;
                for (let j = 0; j < c.children.length; j++) {
                    const g = c.children[j];
                    if (g.kind == XmlKind.Text && isBlank(g.text)) continue;
                    const where = g.kind == XmlKind.Text ? g.positionAt(firstNonSpace(g.text)) : g.pos;
                    return this.fail("property-content", where, "<group> has no content: write it <group name=\"" + name.value + "\"/>");
                }
                const b = BodyItem.ofGroup(name.value);
                b.groupPos = c.pos.clone();
                for (let j = 0; j < c.attrs.length; j++) if (c.attrs[j].name != "name") b.groupExtraAttrs.push(c.attrs[j]);
                d.items.push(b);
                continue;
            }
            if (c.name == "binding") {
                const b = this.binding(c);
                if (b == null) return false;
                d.items.push(BodyItem.ofBinding(b));
                continue;
            }
            const p = this.property(c);
            if (p == null) return false;
            d.items.push(BodyItem.ofProperty(p));
        }
        return true;
    }

    // Milestone 17: a `<binding>` (a node's, and milestone 45: an
    // Event's), its attributes as written; the validator checks their
    // values (../binding/binding.as).
    binding(c: XmlNode): BindingDecl? {
        const property = this.required(c, "property");
        if (property == null) return null;
        const path = this.required(c, "path");
        if (path == null) return null;
        for (let j = 0; j < c.children.length; j++) {
            const g = c.children[j];
            if (g.kind == XmlKind.Text && isBlank(g.text)) continue;
            const where = g.kind == XmlKind.Text ? g.positionAt(firstNonSpace(g.text)) : g.pos;
            this.fail("property-content", where, "<binding> has no content: write it <binding property=\"" + property.value
                + "\" path=\"" + path.value + "\"/>");
            return null;
        }
        const b = new BindingDecl(property.value, path.value);
        b.pos = c.pos.clone();
        for (let j = 0; j < c.attrs.length; j++) {
            const a = c.attrs[j];
            b.attrs.push(a);
            if (a.name == "mode") b.mode = a.value;
            else if (a.name == "scale") b.scale = a.value;
            else if (a.name == "offset") b.offset = a.value;
            else if (a.name == "convert") b.convert = a.value;
            else if (a.name == "once") b.once = a.value;
            else if (a.name == "global") b.global = a.value;
            else if (a.name == "converter") b.converter = a.value;
        }
        return b;
    }

    // --- timelines (milestone 45: RSCN.md, "Animations")

    // An attribute's value as a whole number of at least `min` (and at
    // most i32's largest), else a failure saying so.
    wholeAttr(a: XmlAttr, el: XmlNode, min: i64, what: string): i32 {
        const v = decimalOf(a.value);
        if (v == i64.MIN_VALUE || v < min || !i64FitsI32(v)) {
            this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> " + a.name + " must be " + what + ", found \"" + a.value + "\"");
            return 0;
        }
        return <i32>v;
    }

    // An attribute's value as a number, written as RML writes one
    // (decimal, finite).
    numberAttr(a: XmlAttr, el: XmlNode): f64 {
        const v = rmlNumberOf(a.value);
        if (isNaN(v)) {
            this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> " + a.name + " must be a number, found \"" + a.value + "\"");
            return 0;
        }
        return v;
    }

    boolAttr(a: XmlAttr, el: XmlNode): bool {
        if (a.value == "true") return true;
        if (a.value != "false") {
            this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> " + a.name + " must be true or false, found \"" + a.value + "\"");
        }
        return false;
    }

    // A required attribute that may not be empty (a name, a target).
    nonEmpty(el: XmlNode, name: string): XmlAttr? {
        const a = this.required(el, name);
        if (a == null) return null;
        if (a.value.length == 0) {
            this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> " + name + " is empty");
            return null;
        }
        return a;
    }

    // Whether the reader has failed since `this.err` was last null (the
    // attribute readers above report through it).
    get failed(): bool {
        return this.err != null;
    }

    // The children of a timeline element other than those `known` takes:
    // whitespace skipped, other text and CDATA refused, comments, processing
    // instructions and unknown elements kept in `extras`. Elements `known`
    // reads are left for the caller (it walks the children again).
    extras(el: XmlNode, known: Array<string>, extras: Array<XmlNode>): bool {
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind == XmlKind.Text) {
                if (!this.blankText(c, "<" + el.name + ">")) return false;
                continue;
            }
            if (c.kind == XmlKind.CData) {
                return this.fail("text-unexpected", c.pos, "a CDATA section inside <" + el.name + ">: only elements and comments belong there");
            }
            if (c.kind == XmlKind.Element && known.includes(c.name)) continue;
            extras.push(c);
        }
        return true;
    }

    // An element that holds nothing (a custom property): whitespace only.
    empty(el: XmlNode, how: string): bool {
        for (let j = 0; j < el.children.length; j++) {
            const g = el.children[j];
            if (g.kind == XmlKind.Text && isBlank(g.text)) continue;
            const where = g.kind == XmlKind.Text ? g.positionAt(firstNonSpace(g.text)) : g.pos;
            return this.fail("property-content", where, "<" + el.name + "> has no content: write it " + how);
        }
        return true;
    }

    // `<Event name="...">`: its custom properties, its bindings, the rest
    // kept.
    event(el: XmlNode): EventDecl? {
        const name = this.nonEmpty(el, "name");
        if (name == null) return null;
        const d = new EventDecl(name.value);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) if (el.attrs[k].name != "name") d.extraAttrs.push(el.attrs[k]);
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element) continue;
            const kind = customPropertyKindOf(c.name);
            if (kind >= 0) {
                const p = this.customProperty(c, <CustomPropertyKind>kind);
                if (p == null) return null;
                d.properties.push(p);
            } else if (c.name == "binding") {
                const b = this.binding(c);
                if (b == null) return null;
                d.bindings.push(b);
            }
        }
        if (!this.extras(el, EVENT_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    customProperty(el: XmlNode, kind: CustomPropertyKind): CustomPropertyDecl? {
        // (RML's custom properties may be unnamed: only the attribute is
        // required)
        const name = this.required(el, "name");
        if (name == null) return null;
        const d = new CustomPropertyDecl(kind, name.value);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            if (a.name == "name") continue;
            if (a.name != "propertyValue") {
                d.extraAttrs.push(a);
                continue;
            }
            if (kind == CustomPropertyKind.Number) d.number = this.numberAttr(a, el);
            else if (kind == CustomPropertyKind.Boolean) d.boolean = this.boolAttr(a, el);
            else d.text = a.value;
            if (this.failed) return null;
        }
        if (!this.empty(el, "<" + el.name + " name=\"" + name.value + "\" propertyValue=\"...\"/>")) return null;
        return d;
    }

    // `<LinearAnimation name fps duration speed loopValue workStart workEnd
    // enableWorkArea quantize>` and its keyed objects.
    animation(el: XmlNode): LinearAnimationDecl? {
        const name = this.nonEmpty(el, "name");
        if (name == null) return null;
        const d = new LinearAnimationDecl(name.value);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            const n = a.name;
            if (n == "name") continue;
            if (n == "fps") d.fps = this.wholeAttr(a, el, 1, "a whole number of frames a second, 1 or more");
            else if (n == "duration") d.duration = this.wholeAttr(a, el, 0, "a whole number of frames, 0 or more");
            else if (n == "speed") d.speed = this.numberAttr(a, el);
            else if (n == "loopValue") {
                const l = loopOf(a.value);
                if (l < 0) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> loopValue must be " + LOOP_NAMES.join(", ")
                        + ", found \"" + a.value + "\"", "loopValue is written as a word, as RML writes it");
                } else d.loop = <LoopMode>l;
            } else if (n == "workStart") d.workStart = this.wholeAttr(a, el, -1, "a frame, or -1 for none");
            else if (n == "workEnd") d.workEnd = this.wholeAttr(a, el, -1, "a frame, or -1 for none");
            else if (n == "enableWorkArea") d.enableWorkArea = this.boolAttr(a, el);
            else if (n == "quantize") d.quantize = this.boolAttr(a, el);
            else d.extraAttrs.push(a);
            if (this.failed) return null;
        }
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element || c.name != KEYED_OBJECT_ELEMENT) continue;
            const o = this.keyedObject(c);
            if (o == null) return null;
            d.objects.push(o);
        }
        if (!this.extras(el, ANIMATION_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    keyedObject(el: XmlNode): KeyedObjectDecl? {
        const target = this.nonEmpty(el, "target");
        if (target == null) return null;
        const d = new KeyedObjectDecl(target.value);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) if (el.attrs[k].name != "target") d.extraAttrs.push(el.attrs[k]);
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element || c.name != KEYED_PROPERTY_ELEMENT) continue;
            const p = this.keyedProperty(c);
            if (p == null) return null;
            d.properties.push(p);
        }
        if (!this.extras(el, OBJECT_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    keyedProperty(el: XmlNode): KeyedPropertyDecl? {
        const property = this.nonEmpty(el, "property");
        if (property == null) return null;
        const d = new KeyedPropertyDecl(property.value);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) if (el.attrs[k].name != "property") d.extraAttrs.push(el.attrs[k]);
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element) continue;
            const kind = keyFrameKindOf(c.name);
            if (kind < 0) continue;
            const key = this.keyFrame(c, <KeyFrameKind>kind);
            if (key == null) return null;
            d.keys.push(key);
        }
        if (!this.extras(el, KEYFRAME_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    keyFrame(el: XmlNode, kind: KeyFrameKind): KeyFrameDecl? {
        const d = new KeyFrameDecl(kind);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            const n = a.name;
            if (n == "frame") d.frame = this.wholeAttr(a, el, 0, "a whole number of frames, 0 or more");
            else if (n == "value") this.keyValue(a, el, d);
            else if (n == "interpolationType") {
                const t = interpolationOf(a.value);
                if (a.value == "scripted") {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> interpolationType \"scripted\" is not supported", SCRIPTED_HINT);
                } else if (t < 0) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> interpolationType must be " + INTERPOLATION_NAMES.join(", ")
                        + ", found \"" + a.value + "\"", "interpolationType is written as a word, as RML writes it");
                } else d.interpolation = <InterpolationType>t;
            } else d.extraAttrs.push(a);
            if (this.failed) return null;
        }
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element) continue;
            const ik = interpolatorKindOf(c.name);
            if (ik < 0) continue;
            if (d.interpolator != null) {
                this.fail("attribute-invalid", c.pos, "<" + el.name + "> has two interpolators",
                    "a key has at most one interpolator: the curve of the segment that leaves it");
                return null;
            }
            const ip = this.interpolator(c, <InterpolatorKind>ik);
            if (ip == null) return null;
            d.interpolator = ip;
        }
        if (!this.extras(el, INTERPOLATOR_ELEMENTS_LIST, d.extraChildren)) return null;
        return d;
    }

    // A keyframe's `value`, by its kind (RSCN.md, "Animations": the
    // keyframe table).
    keyValue(a: XmlAttr, el: XmlNode, d: KeyFrameDecl): void {
        const v = a.value;
        switch (d.kind) {
            case KeyFrameKind.Double:
                d.number = this.numberAttr(a, el);
                return;
            case KeyFrameKind.Int:
            case KeyFrameKind.Uint: {
                const n = decimalOf(v);
                // (a Uint from 0, an Int from i32's least, both to u32's largest)
                const fits = i64FitsU32(n) || (d.kind != KeyFrameKind.Uint && i64FitsI32(n));
                if (n == i64.MIN_VALUE || !fits) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> value must be a whole number"
                        + (d.kind == KeyFrameKind.Uint ? ", 0 or more" : "") + ", found \"" + v + "\"");
                    return;
                }
                d.number = <f64>n;
                return;
            }
            case KeyFrameKind.Bool:
                d.boolean = this.boolAttr(a, el);
                return;
            case KeyFrameKind.Color: {
                const c = v.length == 8 ? rmlColorOf(v) : -1;
                if (c < 0) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> value must be 8 hex digits of ARGB, found \"" + v + "\"",
                        "a colour key is written as RML writes one: alpha, red, green, blue, as FF57A5E0");
                    return;
                }
                d.color = <u32>c;
                return;
            }
            case KeyFrameKind.String:
                d.text = v;
                return;
            case KeyFrameKind.Id: {
                const p = parseValueText(v);
                if (!p.ok || (p.value.kind != ValueKind.SubResource && p.value.kind != ValueKind.ExtResource)) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> value must be SubResource(\"id\") or ExtResource(\"id\"), found \""
                        + v + "\"");
                    return;
                }
                // (its canonical spelling: the writer prints it as it is)
                d.text = printValue(p.value);
                return;
            }
            case KeyFrameKind.Quaternion: {
                const parts = v.split(",");
                let ok = parts.length == 4;
                const q = new Array<f64>(4);
                for (let i = 0; ok && i < 4; i++) {
                    q[i] = rmlNumberOf(parts[i].trim());
                    if (isNaN(q[i])) ok = false;
                }
                if (!ok) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> value must be four numbers x, y, z, w, found \"" + v + "\"");
                    return;
                }
                d.qx = q[0];
                d.qy = q[1];
                d.qz = q[2];
                d.qw = q[3];
                return;
            }
            default:
                this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> has no value: it fires when the playhead crosses it");
        }
    }

    interpolator(el: XmlNode, kind: InterpolatorKind): InterpolatorDecl? {
        const d = new InterpolatorDecl(kind);
        d.pos = el.pos.clone();
        const elastic = kind == InterpolatorKind.Elastic;
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            const n = a.name;
            if (!elastic && n == "x1") d.x1 = this.numberAttr(a, el);
            else if (!elastic && n == "y1") d.y1 = this.numberAttr(a, el);
            else if (!elastic && n == "x2") d.x2 = this.numberAttr(a, el);
            else if (!elastic && n == "y2") d.y2 = this.numberAttr(a, el);
            else if (elastic && n == "easingValue") {
                d.easingValue = this.wholeAttr(a, el, ELASTIC_EASE_IN, "0 (easeIn), 1 (easeOut) or 2 (easeInOut)");
                if (!this.failed && d.easingValue > ELASTIC_EASE_IN_OUT) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> easingValue must be 0 (easeIn), 1 (easeOut) or 2 (easeInOut), found \""
                        + a.value + "\"");
                }
            } else if (elastic && n == "amplitude") d.amplitude = this.numberAttr(a, el);
            else if (elastic && n == "period") d.period = this.numberAttr(a, el);
            else d.extraAttrs.push(a);
            if (this.failed) return null;
        }
        if (!this.extras(el, NO_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    // --- state machines (RSCN.md, "State machines"; ../sm/decl.as)

    // An `interpolationType` word: its InterpolationType, or -1 with the
    // reader failed (Rive's `scripted` refused, as a keyframe's is).
    interpolationAttr(a: XmlAttr, el: XmlNode): i32 {
        const t = interpolationOf(a.value);
        if (a.value == "scripted") {
            this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> interpolationType \"scripted\" is not supported", SCRIPTED_HINT);
            return -1;
        }
        if (t < 0) {
            this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> interpolationType must be " + INTERPOLATION_NAMES.join(", ")
                + ", found \"" + a.value + "\"", "interpolationType is written as a word, as RML writes it");
        }
        return t;
    }

    // `<StateMachine name>`: its inputs, layers and listeners; everything
    // else (comments, unknown elements, RML's StateMachineListenerSingle)
    // kept in order.
    stateMachine(el: XmlNode): StateMachineDecl? {
        const name = this.nonEmpty(el, "name");
        if (name == null) return null;
        const d = new StateMachineDecl(name.value);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) if (el.attrs[k].name != "name") d.extraAttrs.push(el.attrs[k]);
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element) continue;
            const ik = inputKindOf(c.name);
            if (ik >= 0) {
                const input = this.smInput(c, <InputKind>ik);
                if (input == null) return null;
                d.inputs.push(input);
            } else if (c.name == LAYER_ELEMENT) {
                const layer = this.smLayer(c);
                if (layer == null) return null;
                d.layers.push(layer);
            } else if (c.name == LISTENER_ELEMENT) {
                const listener = this.smListener(c);
                if (listener == null) return null;
                d.listeners.push(listener);
            }
        }
        if (!this.extras(el, MACHINE_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    // `<StateMachineNumber name value>`, `<StateMachineBool name value>`,
    // `<StateMachineTrigger name>`, and the input's <binding>s.
    smInput(el: XmlNode, kind: InputKind): InputDecl? {
        const name = this.nonEmpty(el, "name");
        if (name == null) return null;
        const d = new InputDecl(kind, name.value);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            if (a.name == "name") continue;
            if (a.name != "value") {
                d.extraAttrs.push(a);
                continue;
            }
            if (kind == InputKind.Number) d.number = this.numberAttr(a, el);
            else if (kind == InputKind.Bool) d.boolean = this.boolAttr(a, el);
            else {
                this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> has no value: a trigger is fired, never set",
                    "write it <" + el.name + " name=\"" + name.value + "\"/>");
            }
            if (this.failed) return null;
        }
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element || c.name != "binding") continue;
            const b = this.binding(c);
            if (b == null) return null;
            d.bindings.push(b);
        }
        if (!this.extras(el, BINDING_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    // `<StateMachineLayer name>` and its states.
    smLayer(el: XmlNode): LayerDecl? {
        const name = this.nonEmpty(el, "name");
        if (name == null) return null;
        const d = new LayerDecl(name.value);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) if (el.attrs[k].name != "name") d.extraAttrs.push(el.attrs[k]);
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element) continue;
            const sk = stateKindOf(c.name);
            if (sk < 0) continue;
            const s = this.smState(c, <StateKind>sk);
            if (s == null) return null;
            d.states.push(s);
        }
        if (!this.extras(el, LAYER_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    // A state: Entry, Any and Exit take only their place on the graph; an
    // AnimationState its animation; the blend states their source and
    // animations. Every state its actions and transitions.
    smState(el: XmlNode, kind: StateKind): StateDecl? {
        const d = new StateDecl(kind);
        d.pos = el.pos.clone();
        const system = kind == StateKind.Entry || kind == StateKind.Any || kind == StateKind.Exit;
        const blend1d = kind == StateKind.Blend1DViewModel || kind == StateKind.Blend1DInput;
        const blend = blend1d || kind == StateKind.BlendDirect;
        if (blend && this.required(el, "name") == null) return null;
        if (kind == StateKind.Blend1DViewModel && this.required(el, "path") == null) return null;
        if (kind == StateKind.Blend1DInput && this.required(el, "input") == null) return null;
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            const n = a.name;
            if (n == "x") d.x = this.numberAttr(a, el);
            else if (n == "y") d.y = this.numberAttr(a, el);
            else if (system) d.extraAttrs.push(a);
            else if (n == "name") d.name = a.value;
            else if (n == "speed") d.speed = this.numberAttr(a, el);
            else if (n == "reset") d.reset = this.boolAttr(a, el);
            else if (n == "random") d.random = this.boolAttr(a, el);
            else if (n == "animation" && kind == StateKind.Animation) d.animation = a.value;
            else if (n == "path" && kind == StateKind.Blend1DViewModel) d.path = a.value;
            else if (n == "global" && kind == StateKind.Blend1DViewModel) d.global = a.value;
            else if (n == "converter" && kind == StateKind.Blend1DViewModel) d.converter = a.value;
            else if (n == "input" && kind == StateKind.Blend1DInput) d.input = a.value;
            else d.extraAttrs.push(a);
            if (this.failed) return null;
        }
        const blendTag = blend1d ? BLEND_ANIMATION_1D_ELEMENT : kind == StateKind.BlendDirect ? BLEND_ANIMATION_DIRECT_ELEMENT : "";
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element) continue;
            if (blendTag.length > 0 && c.name == blendTag) {
                const b = this.smBlend(c, kind == StateKind.BlendDirect);
                if (b == null) return null;
                d.blends.push(b);
                continue;
            }
            const ak = actionKindOf(c.name);
            if (ak >= 0) {
                const act = this.smAction(c, <ActionKind>ak);
                if (act == null) return null;
                d.actions.push(act);
            } else if (c.name == TRANSITION_ELEMENT) {
                const t = this.smTransition(c);
                if (t == null) return null;
                d.transitions.push(t);
            }
        }
        const known = blend1d ? BLEND_1D_STATE_CHILDREN : kind == StateKind.BlendDirect ? BLEND_DIRECT_STATE_CHILDREN : STATE_CHILDREN;
        if (!this.extras(el, known, d.extraChildren)) return null;
        // (an AnimationState named as its animation is called after it, as
        // the writer writes it: a rename of the animation then carries the
        // transitions to it along, read from text or from a format alike)
        if (kind == StateKind.Animation && d.name == d.animation) d.name = "";
        return d;
    }

    // `<BlendAnimation1D animation value>` or `<BlendAnimationDirect
    // animation input | path global converter | mixValue>`. A direct
    // blend's source is the attribute written: `input` an input, else
    // `path` a view model number, else its mixValue (two of them is the
    // validator's blend-source-ambiguous).
    smBlend(el: XmlNode, direct: bool): BlendAnimationDecl? {
        const anim = this.required(el, "animation");
        if (anim == null) return null;
        const d = new BlendAnimationDecl(direct, anim.value);
        d.pos = el.pos.clone();
        let hasInput = false;
        let hasPath = false;
        let mixAttr: XmlAttr? = null;
        let pathAttr: XmlAttr? = null;
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            const n = a.name;
            if (n == "animation") continue;
            if (!direct && n == "value") d.value = this.numberAttr(a, el);
            else if (direct && n == "mixValue") {
                d.mixValue = this.numberAttr(a, el);
                mixAttr = a;
            } else if (direct && n == "input") {
                d.input = a.value;
                hasInput = true;
            } else if (direct && n == "path") {
                d.path = a.value;
                hasPath = true;
                pathAttr = a;
            } else if (direct && n == "global") d.global = a.value;
            else if (direct && n == "converter") d.converter = a.value;
            else d.extraAttrs.push(a);
            if (this.failed) return null;
        }
        if (direct) d.source = hasInput ? BlendSource.Input : hasPath ? BlendSource.ViewModel : BlendSource.MixValue;
        // (a second source the declaration cannot tell from its default, a
        // mixValue of 100 or an empty path beside another source, is kept
        // as written, so that blend-source-ambiguous sees it and a format
        // keeps it)
        if (direct && (hasInput || hasPath)) {
            const m = mixAttr;
            if (m != null && d.mixValue == 100) d.extraAttrs.push(m);
        }
        if (direct && hasInput && hasPath && d.path.length == 0) {
            const p = pathAttr;
            if (p != null) d.extraAttrs.push(p);
        }
        if (!this.extras(el, NO_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    // `<StateTransition to ...>`: its interpolator (at most one), its
    // conditions and its actions. RML's misspelt `exitTimeIsPercetange`
    // is read as `exitTimeIsPercentage`.
    smTransition(el: XmlNode): TransitionDecl? {
        const to = this.required(el, "to");
        if (to == null) return null;
        const d = new TransitionDecl(to.value);
        d.pos = el.pos.clone();
        // (both spellings: refused, rather than one silently overriding the
        // other; the writer writes one)
        let exitPercentRead = false;
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            const n = a.name;
            if (n == "to") continue;
            if ((n == "exitTimeIsPercentage" || n == "exitTimeIsPercetange") && exitPercentRead) {
                this.fail("attribute-invalid", a.pos, "<StateTransition> gives exitTimeIsPercentage twice (RML's spelling "
                    + "exitTimeIsPercetange is the same attribute): give it once");
                return null;
            } else if (n == "duration") d.duration = this.wholeAttr(a, el, 0, "a whole number, 0 or more (milliseconds, or percent)");
            else if (n == "exitTime") d.exitTime = this.wholeAttr(a, el, 0, "a whole number, 0 or more (milliseconds, or percent)");
            else if (n == "interpolationType") {
                const t = this.interpolationAttr(a, el);
                if (t >= 0) d.interpolation = <InterpolationType>t;
            } else if (n == "randomWeight") d.randomWeight = this.wholeAttr(a, el, 0, "a whole number, 0 or more");
            else if (n == "disabled") d.disabled = this.boolAttr(a, el);
            else if (n == "durationIsPercentage") d.durationIsPercentage = this.boolAttr(a, el);
            else if (n == "enableExitTime") d.enableExitTime = this.boolAttr(a, el);
            else if (n == "exitTimeIsPercentage" || n == "exitTimeIsPercetange") {
                d.exitTimeIsPercentage = this.boolAttr(a, el);
                exitPercentRead = true;
            }
            else if (n == "pauseOnExit") d.pauseOnExit = this.boolAttr(a, el);
            else if (n == "enableEarlyExit") d.enableEarlyExit = this.boolAttr(a, el);
            else d.extraAttrs.push(a);
            if (this.failed) return null;
        }
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element) continue;
            const ik = interpolatorKindOf(c.name);
            if (ik >= 0) {
                if (d.interpolator != null) {
                    this.fail("attribute-invalid", c.pos, "<" + el.name + "> has two interpolators",
                        "a transition has at most one interpolator: the curve of its mix");
                    return null;
                }
                const ip = this.interpolator(c, <InterpolatorKind>ik);
                if (ip == null) return null;
                d.interpolator = ip;
                continue;
            }
            const ck = conditionKindOf(c.name);
            if (ck >= 0) {
                const cond = this.smCondition(c, <ConditionKind>ck);
                if (cond == null) return null;
                d.conditions.push(cond);
                continue;
            }
            const ak = actionKindOf(c.name);
            if (ak >= 0) {
                const act = this.smAction(c, <ActionKind>ak);
                if (act == null) return null;
                d.actions.push(act);
            }
        }
        if (!this.extras(el, TRANSITION_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    // A condition in its compact form (../sm/decl.as ConditionKind). A
    // Trigger condition reads no operator: an `opValue` on one is kept as
    // an unknown attribute, which the validator reports as
    // condition-op-invalid.
    smCondition(el: XmlNode, kind: ConditionKind): ConditionDecl? {
        const vm = kind == ConditionKind.ViewModel;
        const component = kind == ConditionKind.Component;
        const input = kind == ConditionKind.Number || kind == ConditionKind.Bool || kind == ConditionKind.Trigger;
        if (vm && this.required(el, "path") == null) return null;
        if (component && (this.required(el, "target") == null || this.required(el, "property") == null)) return null;
        if (input && this.required(el, "input") == null) return null;
        const d = new ConditionDecl(kind);
        d.pos = el.pos.clone();
        const sides = vm || component;
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            const n = a.name;
            if (vm && n == "path") d.path = a.value;
            else if (vm && n == "global") d.global = a.value;
            else if (vm && n == "converter") d.converter = a.value;
            else if (component && n == "target") d.target = a.value;
            else if (component && n == "property") d.property = a.value;
            else if (input && n == "input") d.input = a.value;
            else if (n == "opValue" && kind != ConditionKind.Trigger) {
                const op = conditionOpOf(a.value);
                if (op < 0) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> opValue must be " + CONDITION_OP_NAMES.join(", ")
                        + ", found \"" + a.value + "\"", "opValue is written as a word, as RML writes it");
                } else d.op = <ConditionOp>op;
            } else if (n == "value" && (sides || kind == ConditionKind.Number)) {
                // (a number input's literal is a number; any other side's
                // kind is the data's, read when the machine is bound)
                if (kind == ConditionKind.Number) this.numberAttr(a, el);
                d.value = a.value;
                d.hasValue = true;
            } else if (sides && n == "rightPath") d.rightPath = a.value;
            else if (sides && n == "rightGlobal") d.rightGlobal = a.value;
            else if (sides && n == "rightConverter") d.rightConverter = a.value;
            else d.extraAttrs.push(a);
            if (this.failed) return null;
        }
        if (!this.extras(el, NO_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    // `<StateMachineFireEvent event occursValue>` or
    // `<StateMachineFireTrigger path global occursValue>`.
    smAction(el: XmlNode, kind: ActionKind): FireActionDecl? {
        const key = kind == ActionKind.FireEvent ? "event" : "path";
        if (this.required(el, key) == null) return null;
        const d = new FireActionDecl(kind);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            const n = a.name;
            if (kind == ActionKind.FireEvent && n == "event") d.event = a.value;
            else if (kind == ActionKind.FireTrigger && n == "path") d.path = a.value;
            else if (kind == ActionKind.FireTrigger && n == "global") d.global = a.value;
            else if (n == "occursValue") {
                const v = decimalOf(a.value);
                if (v < 0 || v > <i64>OCCURS_AT_END || a.value.startsWith("-")) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> occursValue must be 0 (at start) or 1 (at end), found \""
                        + a.value + "\"", "occursValue is written as the number, as RML writes it");
                } else d.occurs = <i32>v;
            } else d.extraAttrs.push(a);
            if (this.failed) return null;
        }
        if (!this.extras(el, NO_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    // --- listeners (milestone 47; RSCN.md "Listeners", ../sm/decl.as)

    // `<StateMachineListener name listenerType target event path global>`
    // and its actions in file order. Which of target, event and path a
    // type reads is the validator's to say (listener-attribute-ignored):
    // each is read on every listener, so that a type changed in the editor
    // keeps them.
    smListener(el: XmlNode): ListenerDecl? {
        const name = this.nonEmpty(el, "name");
        if (name == null) return null;
        if (this.required(el, "listenerType") == null) return null;
        const d = new ListenerDecl(name.value);
        d.pos = el.pos.clone();
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            const n = a.name;
            if (n == "name") continue;
            if (n == "listenerType") {
                const t = listenerTypeOf(a.value);
                if (t >= 0) d.type = <ListenerType>t;
                else if (RIVE_ONLY_LISTENER_TYPES.includes(a.value)) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> listenerType \"" + a.value + "\" is not run in 3D",
                        LISTENER_TYPE_HINT);
                } else {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> listenerType must be " + runListenerTypes() + ", found \""
                        + a.value + "\"", "listenerType is written as a word, as RML writes it");
                }
            } else if (n == "target") d.target = a.value;
            else if (n == "event") d.event = a.value;
            else if (n == "path") d.path = a.value;
            else if (n == "global") d.global = a.value;
            else d.extraAttrs.push(a);
            if (this.failed) return null;
        }
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind != XmlKind.Element) continue;
            const ak = listenerActionKindOf(c.name);
            if (ak < 0) continue;
            const act = this.smListenerAction(c, <ListenerActionKind>ak);
            if (act == null) return null;
            d.actions.push(act);
        }
        if (!this.extras(el, LISTENER_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    // A listener's action (../sm/decl.as ListenerActionKind): the attributes
    // its kind reads, any other kept as unknown (a value on a
    // ListenerTriggerChange, a surface on a ListenerFireEvent). A
    // ListenerViewModelChange's sources are read as written, two of them
    // included (the validator's listener-action-source-ambiguous); a
    // ListenerNumberChange's value is kept in its shortest form, a
    // ListenerBoolChange's as its name (RML's 0, 1 and 2 read as false, true
    // and toggle), so that the writer writes it canonically.
    smListenerAction(el: XmlNode, kind: ListenerActionKind): ListenerActionDecl? {
        const key = kind == ListenerActionKind.ViewModelChange ? "path" : kind == ListenerActionKind.FireEvent ? "event"
            : kind == ListenerActionKind.AlignTarget ? "target" : "input";
        if (this.required(el, key) == null) return null;
        const valued = kind == ListenerActionKind.BoolChange || kind == ListenerActionKind.NumberChange;
        if (valued && this.required(el, "value") == null) return null;
        const d = new ListenerActionDecl(kind);
        d.pos = el.pos.clone();
        const vm = kind == ListenerActionKind.ViewModelChange;
        const align = kind == ListenerActionKind.AlignTarget;
        const inputs = kind == ListenerActionKind.BoolChange || valued || kind == ListenerActionKind.TriggerChange;
        for (let k = 0; k < el.attrs.length; k++) {
            const a = el.attrs[k];
            const n = a.name;
            if (vm && n == "path") d.path = a.value;
            else if (vm && n == "global") d.global = a.value;
            else if (vm && n == "value") {
                d.value = a.value;
                d.hasValue = true;
            } else if (vm && n == "fromPath") d.fromPath = a.value;
            else if (vm && n == "fromGlobal") d.fromGlobal = a.value;
            else if (vm && n == "input") {
                if (pointerInputOf(a.value) < 0) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> input must be a pointer input (" + POINTER_INPUT_NAMES.join(", ")
                        + "), found \"" + a.value + "\"", POINTER_INPUT_HINT);
                } else d.input = a.value;
            } else if (vm && n == "converter") d.converter = a.value;
            else if (inputs && n == "input") d.input = a.value;
            else if (kind == ListenerActionKind.BoolChange && n == "value") {
                const v = boolChangeName(a.value);
                if (v.length == 0) {
                    this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> value must be true, false or toggle, found \"" + a.value + "\"",
                        "RML's 1, 0 and 2 are read as true, false and toggle; the writer writes the names");
                } else {
                    d.value = v;
                    d.hasValue = true;
                }
            } else if (kind == ListenerActionKind.NumberChange && n == "value") {
                const v = this.numberAttr(a, el);
                if (!this.failed) {
                    d.value = printNumber(v);
                    d.hasValue = true;
                }
            } else if (kind == ListenerActionKind.FireEvent && n == "event") d.event = a.value;
            else if (align && n == "target") d.target = a.value;
            else if (align && n == "surface") d.surface = this.boolAttr(a, el);
            else if (align && n == "preserveOffset") d.preserveOffset = this.boolAttr(a, el);
            else d.extraAttrs.push(a);
            if (this.failed) return null;
        }
        if (!this.extras(el, NO_CHILDREN, d.extraChildren)) return null;
        return d;
    }

    property(el: XmlNode): Property? {
        const t = this.propertyText(el);
        if (t == null) return null;
        const pv = parseValueText(t.text);
        if (!pv.ok) {
            this.fail("value-syntax", this.positionIn(el, pv.errOffset), pv.errMessage, pv.errHint);
            return null;
        }
        const p = new Property(t.name, pv.value);
        p.pos = t.pos;
        p.valuePos = t.valuePos;
        p.cdata = t.cdata;
        for (let k = 0; k < t.extraAttrs.length; k++) p.extraAttrs.push(t.extraAttrs[k]);
        return p;
    }
}

// The children each timeline element reads itself (the rest are kept).
const EVENT_CHILDREN: Array<string> = ["CustomPropertyNumber", "CustomPropertyString", "CustomPropertyBoolean", "binding"];
const ANIMATION_CHILDREN: Array<string> = [KEYED_OBJECT_ELEMENT];
const OBJECT_CHILDREN: Array<string> = [KEYED_PROPERTY_ELEMENT];
const KEYFRAME_CHILDREN: Array<string> = [
    "KeyFrameDouble", "KeyFrameColor", "KeyFrameBool", "KeyFrameInt", "KeyFrameUint", "KeyFrameString", "KeyFrameId",
    "KeyFrameCallback", "KeyFrameQuaternion",
];
const INTERPOLATOR_ELEMENTS_LIST: Array<string> = ["CubicEaseInterpolator", "CubicValueInterpolator", "ElasticInterpolator"];
const NO_CHILDREN: Array<string> = [];
// The children each state machine element reads itself.
const MACHINE_CHILDREN: Array<string> = [INPUT_ELEMENTS[0], INPUT_ELEMENTS[1], INPUT_ELEMENTS[2], LAYER_ELEMENT, LISTENER_ELEMENT];
const LISTENER_CHILDREN: Array<string> = [
    LISTENER_ACTION_ELEMENTS[0], LISTENER_ACTION_ELEMENTS[1], LISTENER_ACTION_ELEMENTS[2], LISTENER_ACTION_ELEMENTS[3],
    LISTENER_ACTION_ELEMENTS[4], LISTENER_ACTION_ELEMENTS[5],
];

// Rive's listener types that 3D does not run (include/rive/listener_type.hpp):
// attribute-invalid, with LISTENER_TYPE_HINT.
const RIVE_ONLY_LISTENER_TYPES: Array<string> = ["componentProvided", "textInput", "focus", "blur", "keyboard", "semanticAction", "gamepad"];
export const LISTENER_TYPE_HINT = "3D's listeners hear the pointer (enter, exit, down, up, move, click, drag, dragStart, dragEnd), an "
    + "event (event) or a view model property (viewModel); keyboard, focus, text and gamepad listeners are not run in 3D";
const POINTER_INPUT_HINT = "a ListenerViewModelChange writes a literal (value), another property (fromPath) or what the pointer hit "
    + "(input); a machine's input is set by ListenerBoolChange, ListenerNumberChange and ListenerTriggerChange";

// The listener types 3D runs, as listenerType's message lists them.
function runListenerTypes(): string {
    const out = new Array<string>();
    for (let i = 0; i < LISTENER_TYPE_NAMES.length; i++) if (listenerTypeOf(LISTENER_TYPE_NAMES[i]) >= 0) out.push(LISTENER_TYPE_NAMES[i]);
    return out.join(", ");
}

// A ListenerBoolChange's value by its name ("true", "false", "toggle"),
// RML's numbers (1, 0, 2) read as those; "" for anything else.
function boolChangeName(v: string): string {
    if (v == "true" || v == "1") return "true";
    if (v == "false" || v == "0") return "false";
    if (v == "toggle" || v == "2") return "toggle";
    return "";
}
const BINDING_CHILDREN: Array<string> = ["binding"];
const LAYER_CHILDREN: Array<string> = [
    STATE_ELEMENTS[0], STATE_ELEMENTS[1], STATE_ELEMENTS[2], STATE_ELEMENTS[3], STATE_ELEMENTS[4], STATE_ELEMENTS[5], STATE_ELEMENTS[6],
];
const STATE_CHILDREN: Array<string> = [ACTION_ELEMENTS[0], ACTION_ELEMENTS[1], TRANSITION_ELEMENT];
const BLEND_1D_STATE_CHILDREN: Array<string> = [ACTION_ELEMENTS[0], ACTION_ELEMENTS[1], TRANSITION_ELEMENT, BLEND_ANIMATION_1D_ELEMENT];
const BLEND_DIRECT_STATE_CHILDREN: Array<string> = [ACTION_ELEMENTS[0], ACTION_ELEMENTS[1], TRANSITION_ELEMENT, BLEND_ANIMATION_DIRECT_ELEMENT];
const TRANSITION_CHILDREN: Array<string> = [
    "CubicEaseInterpolator", "CubicValueInterpolator", "ElasticInterpolator", CONDITION_ELEMENTS[0], CONDITION_ELEMENTS[1],
    CONDITION_ELEMENTS[2], CONDITION_ELEMENTS[3], CONDITION_ELEMENTS[4], ACTION_ELEMENTS[0], ACTION_ELEMENTS[1],
];

function fromXml(r: Result<XmlDocument>, file: string): Result<RscnDoc> {
    if (!r.ok) {
        const hint = XML_SYNTAX_HINT;
        const e = xmlErrorOf<XmlDocument>(r);
        if (e != null) return SceneryError.at("xml-syntax", file, e.pos.line, e.pos.col, e.message, hint).fail<RscnDoc>();
        return SceneryError.at("xml-syntax", file, 0, 0, r.err, hint).fail<RscnDoc>();
    }
    const reader = new Reader(file);
    const doc = reader.document(r.value);
    const err = reader.err;
    if (err != null) return err.fail<RscnDoc>();
    if (doc == null) return SceneryError.at("xml-syntax", file, 0, 0, "unreadable scene").fail<RscnDoc>();
    return Result.okv<RscnDoc>(doc);
}

// Reads a document. `file` is how errors name it (the loader passes its
// display path, `res://...`).
export function parseRscn(bytes: Uint8Array, file: string): Result<RscnDoc> {
    return fromXml(parseXml(bytes, file), file);
}

// parseRscn of a string.
export function parseRscnText(text: string, file: string): Result<RscnDoc> {
    return fromXml(parseXmlText(text, file), file);
}

// The ext_resources of a document and what comes before them (a document
// with every entry up to its first sub_resource, node, connection or
// embedded file, none of which is read): what a scene names, for a caller
// that fetches files ahead of loading it (Hedra's prefetcher) and so
// must not pay for reading its nodes. An error is the reader's, as far as
// the head goes.
export function parseRscnHead(bytes: Uint8Array, file: string): Result<RscnDoc> {
    return fromXml(parseXmlHead(bytes, file, HEAD_ELEMENTS, AFTER_HEAD), file);
}

// The elements parseRscnHead reads (comments and processing instructions
// are always read), and those after them, where the bytes it decodes end.
const HEAD_ELEMENTS: Array<string> = ["ext_resource"];
// (a converter's element ends the head too, but its names are open-ended:
// the head of a scene with converters reads them, which costs little)
const AFTER_HEAD: Array<string> = [
    "sub_resource", "node", EVENT_ELEMENT, ANIMATION_ELEMENT, STATE_MACHINE_ELEMENT, "connection", "embedded",
];
