// The .rscn document model: one file as it is written, before anything is
// loaded or instanced (docs/formats/RSCN.md is the format). The reader
// (parse.as) builds it, the validator (validate.as) checks it, the canonical
// writer (write.as) prints it, and the scene editor (milestone 8) edits it,
// which is why it keeps what a tool must not lose: the order of everything,
// comments, and whatever a newer format version added (unknown elements,
// attributes and properties), each where it was.
//
// `entries` is the file's content in source order, comments and unknown
// elements included; the typed views (extResources(), nodes(), ...) list the
// known elements of each kind in that order. Edit through the methods below
// so that an added element lands in its section.
//
// Positions are those of the source (XmlPos, 1-based); an element built in
// code has none (line 0), and errors about it name only the file.
//
// Milestone 3 scaffolding: complete; the agreed interface of every package.
//
// Milestone 14: the same model holds a material file's material: `kind` is
// DocKind.Material, and the entries are the ext_resources (the textures it
// names) and one <resource type="StandardMaterial3D"> (an Entry of kind
// Resource, whose declaration is a SubResourceDecl with no id), so the
// validator, the loader and the editor's document operations serve scenes
// and materials alike. The file is MaterialX (.mtlx, docs/scene/
// MATERIALS.md), never parsed or written here: ../resource/mtlx_doc.as
// makes the material document from it, with the file's positions, the
// reader's warnings and what writing it back would drop (`warnings`,
// `dropped`), and writes it back.
//
// Milestone 42: format 2 (docs/formats/RSCN.md, "Format 2"; docs/plans/
// RIVE_MODEL.md section 4) adds the top-level converters (a section of
// their own between sub_resource and node: EntryKind.Converter), the
// binding attributes `mode="to_source"`, `once`, `global` and `converter`,
// the targets beyond format 1's, `data_path`, and a ViewModel whose data is
// an .rml or the Rive project's. formatNeeded tells which version a
// document needs; the writer writes that one, so that a file using none of
// it stays format 1, byte for byte.
//
// Milestone 45: format 2 also holds Rive's timelines (docs/plans/
// RIVE_MODEL.md sections 3.2, 3.6 and 4.1; ../anim/decl.as): the scene's
// Events and LinearAnimations, two sections of their own between the nodes
// and the connections (EntryKind.Event, EntryKind.Animation; Entry.event,
// Entry.animation). A document with either needs format 2.
//
// Milestone 46: format 2 also holds Rive's state machines (docs/plans/
// RIVE_MODEL.md sections 3.3 and 4; ../sm/decl.as): a section of their own
// after the animations and before the connections (EntryKind.StateMachine,
// Entry.stateMachine). A document with one, or with a node setting one of
// the state machine's node properties (default_state_machine on the root;
// state_machine, animation, animation_time, speed or is_paused on a node
// that instances a scene), needs format 2.

import { XmlAttr, XmlNode, XmlPos } from "../../base/xml";
import { Diagnostic } from "../error";
import { Value, ValueKind } from "../value";
import { DataConverterDecl } from "../data/model";
import { EventDecl, LinearAnimationDecl } from "../anim/decl";
import {
    DEFAULT_STATE_MACHINE_PROPERTY, INPUT_RAY_PICKABLE_PROPERTY, INSTANCE_PROPERTIES, LISTENER_PASS_THROUGH_PROPERTY,
    POINTER_FORWARD_PROPERTY, StateMachineDecl,
} from "../sm/decl";
import { isA } from "../classdb";
import { bindingTargets, isFormat1Target } from "../binding/targets";

// The newest format version this build reads and writes (milestone 42: 2).
// A document is written as the version it needs (formatNeeded), so a file
// that uses nothing of format 2 is written as format 1.
export const FORMAT_VERSION: i32 = 2;

// Milestone 14: what a document is. A scene (.rscn, root <rscn>) or a
// material file's material (an .mtlx file read by mtlx_doc.as, holding one
// <resource>).
export enum DocKind {
    Scene,
    Material,
}

// The root element of a scene file.
export const SCENE_ROOT = "rscn";

// Inserts `v` at index `at` (0..length) of `a` (AssemblyScript's splice
// only removes).
function insertAt<T>(a: Array<T>, at: i32, v: T): void {
    a.push(v);
    for (let i = a.length - 1; i > at; i--) a[i] = a[i - 1];
    a[at] = v;
}

// A `<property name="...">value</property>`.
export class Property {
    name: string;
    value: Value;
    // The <property> element.
    pos: XmlPos = new XmlPos();
    // The value's first character (where the value text starts: an error
    // in the value is at an offset from here, see XmlNode.positionAt).
    valuePos: XmlPos = new XmlPos();
    // The value was one CDATA section: the writer writes it as one again.
    cdata: bool = false;
    // Attributes other than `name`, in source order (kept, and written back).
    extraAttrs: Array<XmlAttr> = [];

    constructor(name: string, value: Value) {
        this.name = name;
        this.value = value;
    }
}

export enum BodyKind {
    Property,
    // `<group name="..."/>`: the node belongs to that group.
    Group,
    // A comment, kept where it was.
    Comment,
    // An element this format version does not know, kept verbatim.
    Unknown,
    // Milestone 17: `<binding property="..." path="..."/>`, a node property
    // bound to a view model property (docs/formats/RSCN.md, "Bindings").
    // Appended, so that no existing value moves.
    Binding,
}

// Milestone 17: `<binding property="..." path="..." mode="..." scale="..."
// offset="..." convert="..."/>`, one child of a node (RSCN.md,
// "Bindings"). The attributes are kept as written (`mode`, `scale`,
// `offset` and `convert` are "" when absent), so that a value this version
// refuses still round-trips; ../binding/binding.as parseBindingDecl reads
// them as a BindingSpec and the validator (validate.as) reports what is
// wrong with them.
export class BindingDecl {
    // The node property bound, Godot's property path with `:` subnames:
    // "position:y", "light_energy", "material_override:albedo_color".
    property: string;
    // The view model property, a path relative to the scene's view model
    // instance, `/` through nested view models: "angle", "lamp/level".
    // Empty in an override: the binding inherited for `property` is removed.
    path: string;
    mode: string = "";
    scale: string = "";
    offset: string = "";
    convert: string = "";
    // Milestone 42 (docs/plans/RIVE_MODEL.md section 3.4): `once`
    // ("true"), `global` (a global view model's name) and `converter` (a
    // converter's name), as written ("" when absent).
    once: string = "";
    global: string = "";
    converter: string = "";
    // The <binding> element.
    pos: XmlPos = new XmlPos();
    // Every attribute in source order, the known ones included (their
    // positions for errors; the unknown ones are written back after the
    // known ones, in this order).
    attrs: Array<XmlAttr> = [];

    constructor(property: string, path: string) {
        this.property = property;
        this.path = path;
    }

    // Milestone 42: whether attribute `name` was written (an empty value
    // included, which the fields cannot tell from an absent one), or is
    // set on a declaration built in code.
    has(name: string): bool {
        for (let i = 0; i < this.attrs.length; i++) if (this.attrs[i].name == name) return true;
        if (name == "once") return this.once.length > 0;
        if (name == "global") return this.global.length > 0;
        if (name == "converter") return this.converter.length > 0;
        if (name == "mode") return this.mode.length > 0;
        if (name == "scale") return this.scale.length > 0;
        if (name == "offset") return this.offset.length > 0;
        if (name == "convert") return this.convert.length > 0;
        return name == "property" || name == "path";
    }

    // Milestone 42: whether the writer writes `once` (a value other than
    // false: "true", or one the validator refuses, kept as written).
    writesOnce(): bool {
        return this.once.length > 0 && this.once != "false";
    }

    // Where attribute `name` is (its value's first character), else the
    // element's position.
    attrPos(name: string): XmlPos {
        for (let i = 0; i < this.attrs.length; i++) {
            if (this.attrs[i].name == name) return this.attrs[i].valuePos;
        }
        return this.pos;
    }

    // A copy: its attributes as written, unknown ones included (the writer
    // puts those back after the known ones), so that two declarations (a
    // duplicated node, an edit and the command that wrote it) never share
    // one. The attributes themselves are only ever read, so they are shared.
    clone(): BindingDecl {
        const c = new BindingDecl(this.property, this.path);
        c.mode = this.mode;
        c.scale = this.scale;
        c.offset = this.offset;
        c.convert = this.convert;
        c.once = this.once;
        c.global = this.global;
        c.converter = this.converter;
        const attrs = new Array<XmlAttr>();
        for (let i = 0; i < this.attrs.length; i++) attrs.push(this.attrs[i]);
        c.attrs = attrs;
        return c;
    }
}

// One item of a node's or a sub_resource's content.
export class BodyItem {
    kind: BodyKind;
    property: Property? = null;
    // Group: its name, and where the <group> element is.
    group: string = "";
    groupPos: XmlPos = new XmlPos();
    // Group: attributes other than `name`.
    groupExtraAttrs: Array<XmlAttr> = [];
    // Comment, Unknown: the XML node.
    xml: XmlNode? = null;
    // Binding (milestone 17).
    binding: BindingDecl? = null;

    constructor(kind: BodyKind) {
        this.kind = kind;
    }

    static ofBinding(b: BindingDecl): BodyItem {
        const item = new BodyItem(BodyKind.Binding);
        item.binding = b;
        return item;
    }

    static ofProperty(p: Property): BodyItem {
        const b = new BodyItem(BodyKind.Property);
        b.property = p;
        return b;
    }

    static ofGroup(name: string): BodyItem {
        const b = new BodyItem(BodyKind.Group);
        b.group = name;
        return b;
    }

    static ofXml(kind: BodyKind, n: XmlNode): BodyItem {
        const b = new BodyItem(kind);
        b.xml = n;
        return b;
    }
}

// What nodes and sub_resources share: an element with attributes and a body
// of properties, groups, comments and unknown elements.
export class Declaration {
    // The element's `<`.
    pos: XmlPos = new XmlPos();
    // Every attribute in source order, the known ones included (their
    // positions for errors; the unknown ones are written back after the
    // known ones, in this order).
    attrs: Array<XmlAttr> = [];
    items: Array<BodyItem> = [];

    // Where attribute `name` is (its value's first character), else the
    // element's position.
    attrPos(name: string): XmlPos {
        for (let i = 0; i < this.attrs.length; i++) {
            if (this.attrs[i].name == name) return this.attrs[i].valuePos;
        }
        return this.pos;
    }

    attrNode(name: string): XmlAttr? {
        for (let i = 0; i < this.attrs.length; i++) if (this.attrs[i].name == name) return this.attrs[i];
        return null;
    }

    properties(): Array<Property> {
        const out = new Array<Property>();
        for (let i = 0; i < this.items.length; i++) {
            const p = this.items[i].property;
            if (p != null) out.push(p);
        }
        return out;
    }

    // The last property of that name (a document with two is invalid; the
    // validator reports it), or null.
    property(name: string): Property? {
        for (let i = this.items.length - 1; i >= 0; i--) {
            const p = this.items[i].property;
            if (p != null && p.name == name) return p;
        }
        return null;
    }

    // Sets a property: in place when there is one of that name, else
    // appended after the last property (or at the end).
    setProperty(name: string, value: Value): Property {
        const have = this.property(name);
        if (have != null) {
            have.value = value;
            return have;
        }
        const p = new Property(name, value);
        let at = this.items.length;
        for (let i = this.items.length - 1; i >= 0; i--) {
            if (this.items[i].kind == BodyKind.Property) {
                at = i + 1;
                break;
            }
        }
        insertAt<BodyItem>(this.items, at, BodyItem.ofProperty(p));
        return p;
    }

    // Removes every property of that name; returns whether there was one.
    removeProperty(name: string): bool {
        let removed = false;
        for (let i = this.items.length - 1; i >= 0; i--) {
            const p = this.items[i].property;
            if (p != null && p.name == name) {
                this.items.splice(i, 1);
                removed = true;
            }
        }
        return removed;
    }

    groups(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.items.length; i++) {
            if (this.items[i].kind == BodyKind.Group) out.push(this.items[i].group);
        }
        return out;
    }

    // Adds a group (before the first property, after the other groups);
    // nothing when the node already has it.
    addGroup(name: string): void {
        let at = 0;
        for (let i = 0; i < this.items.length; i++) {
            if (this.items[i].kind == BodyKind.Group) {
                if (this.items[i].group == name) return;
                at = i + 1;
            }
        }
        insertAt<BodyItem>(this.items, at, BodyItem.ofGroup(name));
    }

    // Milestone 17: the bindings, in source order.
    bindings(): Array<BindingDecl> {
        const out = new Array<BindingDecl>();
        for (let i = 0; i < this.items.length; i++) {
            const b = this.items[i].binding;
            if (b != null) out.push(b);
        }
        return out;
    }

    // The last binding of that property (a declaration with two is
    // invalid: binding-duplicate), or null.
    binding(property: string): BindingDecl? {
        for (let i = this.items.length - 1; i >= 0; i--) {
            const b = this.items[i].binding;
            if (b != null && b.property == property) return b;
        }
        return null;
    }

    // Sets a binding: replaces the one of the same property in place, else
    // appends it after the last binding, else after the last property or
    // group, else at the start (bindings come after properties: RSCN.md,
    // "Canonical form").
    setBinding(b: BindingDecl): BindingDecl {
        for (let i = this.items.length - 1; i >= 0; i--) {
            const have = this.items[i].binding;
            if (have != null && have.property == b.property) {
                this.items[i].binding = b;
                return b;
            }
        }
        let at = -1;
        for (let i = this.items.length - 1; i >= 0 && at < 0; i--) {
            if (this.items[i].kind == BodyKind.Binding) at = i + 1;
        }
        for (let i = this.items.length - 1; i >= 0 && at < 0; i--) {
            const k = this.items[i].kind;
            if (k == BodyKind.Property || k == BodyKind.Group) at = i + 1;
        }
        if (at < 0) at = 0;
        insertAt<BodyItem>(this.items, at, BodyItem.ofBinding(b));
        return b;
    }

    // Removes every binding of that property; returns whether there was one.
    removeBinding(property: string): bool {
        let removed = false;
        for (let i = this.items.length - 1; i >= 0; i--) {
            const b = this.items[i].binding;
            if (b != null && b.property == property) {
                this.items.splice(i, 1);
                removed = true;
            }
        }
        return removed;
    }
}

// `<ext_resource id="..." type="..." path="..."/>`.
export class ExtResourceDecl {
    id: string;
    type: string;
    // As written: `res://...` or a path relative to this file.
    path: string;
    uid: string? = null;
    pos: XmlPos = new XmlPos();
    attrs: Array<XmlAttr> = [];
    // Children (none in format 1: whatever is there is kept verbatim).
    extraChildren: Array<XmlNode> = [];

    constructor(id: string, type: string, path: string) {
        this.id = id;
        this.type = type;
        this.path = path;
    }

    attrPos(name: string): XmlPos {
        for (let i = 0; i < this.attrs.length; i++) if (this.attrs[i].name == name) return this.attrs[i].valuePos;
        return this.pos;
    }
}

// `<sub_resource id="..." type="...">` and its properties.
export class SubResourceDecl extends Declaration {
    id: string;
    type: string;

    constructor(id: string, type: string) {
        super();
        this.id = id;
        this.type = type;
    }
}

// `<node name="..." type="..." parent="..." instance="...">`.
export class NodeDecl extends Declaration {
    name: string;
    // The class (null for an instanced scene, and for an override of a
    // node inside one).
    type: string? = null;
    // The parent's path relative to the root: "." or "A/B"; null for the
    // root.
    parent: string? = null;
    // An instanced scene: ExtResource("id"), as parsed from the attribute.
    instance: Value? = null;

    constructor(name: string) {
        super();
        this.name = name;
    }

    // The node's path relative to the root: "." for the root, the name for
    // a child of the root, "<parent>/<name>" below that.
    path(): string {
        const p = this.parent;
        if (p == null) return ".";
        if (p == ".") return this.name;
        return p + "/" + this.name;
    }
}

// `<connection signal="..." from="..." to="..." method="..."/>`.
export class ConnectionDecl {
    signal: string;
    from: string;
    to: string;
    method: string;
    // Godot's connection flags (0 when absent: written only when not 0).
    flags: i32 = 0;
    pos: XmlPos = new XmlPos();
    attrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(signal: string, from: string, to: string, method: string) {
        this.signal = signal;
        this.from = from;
        this.to = to;
        this.method = method;
    }

    attrPos(name: string): XmlPos {
        for (let i = 0; i < this.attrs.length; i++) if (this.attrs[i].name == name) return this.attrs[i].valuePos;
        return this.pos;
    }
}

// `<embedded path="res://..." size="N">base64</embedded>`: the bytes of a
// file a packed scene carries (docs/formats/RSCN.md, "Packed scenes").
export class EmbeddedDecl {
    // The file's res:// path, as written.
    path: string;
    // The `size` attribute: the decoded byte count it states.
    size: i64;
    // The decoded bytes (empty when the content is not base64: see
    // `invalid`).
    data: Uint8Array;
    pos: XmlPos = new XmlPos();
    attrs: Array<XmlAttr> = [];
    // Why the content does not decode ("" when it does). The validator
    // reports it as `embedded-invalid`; the writer then writes the element
    // back as it was read (`xml`) rather than lose the bytes.
    invalid: string = "";
    // Where the content starts, for `invalid` (the element's position when
    // there is no content).
    contentPos: XmlPos = new XmlPos();
    // The element as read (null for one built in code).
    xml: XmlNode? = null;

    constructor(path: string, data: Uint8Array) {
        this.path = path;
        this.size = <i64>data.length;
        this.data = data;
    }

    attrPos(name: string): XmlPos {
        for (let i = 0; i < this.attrs.length; i++) if (this.attrs[i].name == name) return this.attrs[i].valuePos;
        return this.pos;
    }
}

export enum EntryKind {
    ExtResource,
    SubResource,
    Node,
    Connection,
    Comment,
    Unknown,
    // Appended after Unknown, so that no existing value moves.
    Embedded,
    // Milestone 14: the <resource type="..."> of a material document (its
    // declaration is `Entry.res`).
    Resource,
    // Milestone 42: a top-level converter declaration (`Entry.converter`,
    // docs/plans/RIVE_MODEL.md section 4.4), RML's DataConverter* element.
    Converter,
    // Milestone 45: an <Event> (`Entry.event`) and a <LinearAnimation>
    // (`Entry.animation`), sections of their own after the nodes
    // (RIVE_MODEL.md section 4.1).
    Event,
    Animation,
    // Milestone 46: a <StateMachine> (`Entry.stateMachine`), a section of
    // its own after the animations (RIVE_MODEL.md section 4.1).
    StateMachine,
}

// One child of <rscn>, in source order.
export class Entry {
    kind: EntryKind;
    ext: ExtResourceDecl? = null;
    sub: SubResourceDecl? = null;
    node: NodeDecl? = null;
    connection: ConnectionDecl? = null;
    embedded: EmbeddedDecl? = null;
    // Milestone 14: a material document's <resource> (its `id` is "").
    res: SubResourceDecl? = null;
    // Milestone 42: a converter the scene declares (EntryKind.Converter).
    converter: DataConverterDecl? = null;
    // Milestone 45: an event and an animation the scene declares.
    event: EventDecl? = null;
    animation: LinearAnimationDecl? = null;
    // Milestone 46: a state machine the scene declares.
    stateMachine: StateMachineDecl? = null;
    // Comment, Unknown.
    xml: XmlNode? = null;

    constructor(kind: EntryKind) {
        this.kind = kind;
    }

    // The section of a known element: 0 ext_resource, 1 sub_resource, 2 a
    // converter (milestone 42), 3 node (a material document's resource), 4
    // an Event and 5 a LinearAnimation (milestone 45), 6 a StateMachine
    // (milestone 46), 7 connection, 8 embedded; -1 for comments and unknown
    // elements.
    section(): i32 {
        switch (this.kind) {
            case EntryKind.ExtResource: return 0;
            case EntryKind.SubResource: return 1;
            case EntryKind.Converter: return 2;
            case EntryKind.Node: return 3;
            case EntryKind.Resource: return 3;
            case EntryKind.Event: return 4;
            case EntryKind.Animation: return 5;
            case EntryKind.StateMachine: return 6;
            case EntryKind.Connection: return 7;
            case EntryKind.Embedded: return 8;
            default: return -1;
        }
    }
}

export class RscnDoc {
    // The file as errors name it (the loader's display path).
    file: string = "";
    // Milestone 14: a scene (the default) or a material file's material.
    kind: DocKind = DocKind.Scene;
    format: i32 = FORMAT_VERSION;
    uid: string? = null;
    // The <rscn> element and all its attributes (format and uid included).
    pos: XmlPos = new XmlPos();
    rootAttrs: Array<XmlAttr> = [];
    // Comments and processing instructions before and after <rscn>.
    prolog: Array<XmlNode> = [];
    epilog: Array<XmlNode> = [];
    entries: Array<Entry> = [];
    // Milestone 14: a material document made from a MaterialX file
    // (../resource/mtlx_doc.as) rather than parsed: the reader's warnings
    // (mtlx-ignored, at the file's positions), which the validator lists
    // with its own, and what writing the document back would drop, as
    // "2 comments, xpos" ("" when nothing: every scene parsed from .rscn,
    // which its writer keeps whole).
    warnings: Array<Diagnostic> = [];
    dropped: string = "";
    // Milestone 42: the converters of the scene's data source (its Rive
    // project's RML) that its bindings name, carried by a built scene
    // (../rscnb/binds.as, the BNDS section) so that the run time looks a
    // converter up without reading RML; empty in a scene read from text.
    projectConverters: Array<DataConverterDecl> = [];

    constructor(file: string = "", kind: DocKind = DocKind.Scene) {
        this.file = file;
        this.kind = kind;
    }

    // The root element's name: "rscn" (a material document is written as
    // MaterialX, never as this XML).
    rootTag(): string {
        return SCENE_ROOT;
    }

    // A material document's <resource> (the first one: a second is the
    // validator's `resource-duplicate`), or null (a scene; a material
    // document built in code without one, `resource-missing`).
    resource(): SubResourceDecl? {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].res;
            if (e != null) return e;
        }
        return null;
    }

    // Sets a material document's <resource>: replaces the first one's declaration
    // in place, or appends a new entry at the end of its section.
    setResource(d: SubResourceDecl): SubResourceDecl {
        for (let i = 0; i < this.entries.length; i++) {
            if (this.entries[i].res != null) {
                this.entries[i].res = d;
                return d;
            }
        }
        const e = new Entry(EntryKind.Resource);
        e.res = d;
        this.insert(e);
        return d;
    }

    extResources(): Array<ExtResourceDecl> {
        const out = new Array<ExtResourceDecl>();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].ext;
            if (e != null) out.push(e);
        }
        return out;
    }

    subResources(): Array<SubResourceDecl> {
        const out = new Array<SubResourceDecl>();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].sub;
            if (e != null) out.push(e);
        }
        return out;
    }

    nodes(): Array<NodeDecl> {
        const out = new Array<NodeDecl>();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].node;
            if (e != null) out.push(e);
        }
        return out;
    }

    connections(): Array<ConnectionDecl> {
        const out = new Array<ConnectionDecl>();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].connection;
            if (e != null) out.push(e);
        }
        return out;
    }

    // Milestone 42: the converters the scene declares, in document order.
    converters(): Array<DataConverterDecl> {
        const out = new Array<DataConverterDecl>();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].converter;
            if (e != null) out.push(e);
        }
        return out;
    }

    // The first converter the scene declares named `name`, or null.
    findConverter(name: string): DataConverterDecl? {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].converter;
            if (e != null && e.name == name) return e;
        }
        return null;
    }

    // Milestone 45: the events the scene declares, in document order.
    events(): Array<EventDecl> {
        const out = new Array<EventDecl>();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].event;
            if (e != null) out.push(e);
        }
        return out;
    }

    // The first event named `name`, or null.
    findEvent(name: string): EventDecl? {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].event;
            if (e != null && e.name == name) return e;
        }
        return null;
    }

    // Milestone 45: the animations the scene declares, in document order.
    animations(): Array<LinearAnimationDecl> {
        const out = new Array<LinearAnimationDecl>();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].animation;
            if (e != null) out.push(e);
        }
        return out;
    }

    // The first animation named `name`, or null.
    findAnimation(name: string): LinearAnimationDecl? {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].animation;
            if (e != null && e.name == name) return e;
        }
        return null;
    }

    // Milestone 46: the state machines the scene declares, in document
    // order.
    stateMachines(): Array<StateMachineDecl> {
        const out = new Array<StateMachineDecl>();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].stateMachine;
            if (e != null) out.push(e);
        }
        return out;
    }

    // The first state machine named `name`, or null.
    findStateMachine(name: string): StateMachineDecl? {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].stateMachine;
            if (e != null && e.name == name) return e;
        }
        return null;
    }

    // The files a packed scene carries, in document order.
    embeddedFiles(): Array<EmbeddedDecl> {
        const out = new Array<EmbeddedDecl>();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].embedded;
            if (e != null) out.push(e);
        }
        return out;
    }

    // The first embedded file whose path is `path`, or null.
    findEmbedded(path: string): EmbeddedDecl? {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].embedded;
            if (e != null && e.path == path) return e;
        }
        return null;
    }

    findExt(id: string): ExtResourceDecl? {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].ext;
            if (e != null && e.id == id) return e;
        }
        return null;
    }

    findSub(id: string): SubResourceDecl? {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].sub;
            if (e != null && e.id == id) return e;
        }
        return null;
    }

    // The declaration whose path() is `path` ("." for the root), or null.
    // Only nodes declared in this file: not those inside an instance.
    findNode(path: string): NodeDecl? {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].node;
            if (e != null && e.path() == path) return e;
        }
        return null;
    }

    // The root declaration (the first node), or null.
    root(): NodeDecl? {
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i].node;
            if (e != null) return e;
        }
        return null;
    }

    // Inserts an entry at the end of its section (after the last entry of
    // the same or an earlier section; comments and unknown elements that
    // follow that entry stay with the next one).
    private insert(e: Entry): void {
        const section = e.section();
        let at = 0;
        for (let i = 0; i < this.entries.length; i++) {
            const s = this.entries[i].section();
            if (s >= 0 && s <= section) at = i + 1;
        }
        insertAt<Entry>(this.entries, at, e);
    }

    addExtResource(d: ExtResourceDecl): ExtResourceDecl {
        const e = new Entry(EntryKind.ExtResource);
        e.ext = d;
        this.insert(e);
        return d;
    }

    addSubResource(d: SubResourceDecl): SubResourceDecl {
        const e = new Entry(EntryKind.SubResource);
        e.sub = d;
        this.insert(e);
        return d;
    }

    // Appends a node at the end of the node section (a parent must come
    // before its children: add parents first).
    addNode(d: NodeDecl): NodeDecl {
        const e = new Entry(EntryKind.Node);
        e.node = d;
        this.insert(e);
        return d;
    }

    // Adds an override of a node inside an instance, `d` (its path
    // `path`), before the first node this file declares under it, else at
    // the end of the node section: a parent comes before its children, and
    // the file may already declare a node under the one it now overrides
    // (a BoneAttachment3D under a model's armature).
    addNodeBeforeChildren(d: NodeDecl, path: string): NodeDecl {
        const under = path + "/";
        for (let i = 0; i < this.entries.length; i++) {
            const n = this.entries[i].node;
            if (this.entries[i].kind != EntryKind.Node || n == null) continue;
            if (n.path().startsWith(under)) {
                const e = new Entry(EntryKind.Node);
                e.node = d;
                insertAt<Entry>(this.entries, i, e);
                return d;
            }
        }
        return this.addNode(d);
    }

    addConnection(d: ConnectionDecl): ConnectionDecl {
        const e = new Entry(EntryKind.Connection);
        e.connection = d;
        this.insert(e);
        return d;
    }

    // Milestone 42: appends a converter at the end of the converters'
    // section.
    addConverter(d: DataConverterDecl): DataConverterDecl {
        const e = new Entry(EntryKind.Converter);
        e.converter = d;
        this.insert(e);
        return d;
    }

    // Milestone 45: appends an event at the end of the events' section.
    addEvent(d: EventDecl): EventDecl {
        const e = new Entry(EntryKind.Event);
        e.event = d;
        this.insert(e);
        return d;
    }

    // Milestone 45: appends an animation at the end of the animations'
    // section.
    addAnimation(d: LinearAnimationDecl): LinearAnimationDecl {
        const e = new Entry(EntryKind.Animation);
        e.animation = d;
        this.insert(e);
        return d;
    }

    // Milestone 46: appends a state machine at the end of the state
    // machines' section.
    addStateMachine(d: StateMachineDecl): StateMachineDecl {
        const e = new Entry(EntryKind.StateMachine);
        e.stateMachine = d;
        this.insert(e);
        return d;
    }

    // Appends an embedded file at the end of the embedded section.
    addEmbedded(d: EmbeddedDecl): EmbeddedDecl {
        const e = new Entry(EntryKind.Embedded);
        e.embedded = d;
        this.insert(e);
        return d;
    }

    private removeAt(i: i32): bool {
        if (i < 0) return false;
        this.entries.splice(i, 1);
        return true;
    }

    // Each removes the entry holding that declaration; returns whether it
    // was there. (Removing a node does not remove its children.)
    removeExtResource(d: ExtResourceDecl): bool {
        for (let i = 0; i < this.entries.length; i++) if (this.entries[i].ext === d) return this.removeAt(i);
        return false;
    }

    removeSubResource(d: SubResourceDecl): bool {
        for (let i = 0; i < this.entries.length; i++) if (this.entries[i].sub === d) return this.removeAt(i);
        return false;
    }

    removeNode(d: NodeDecl): bool {
        for (let i = 0; i < this.entries.length; i++) if (this.entries[i].node === d) return this.removeAt(i);
        return false;
    }

    removeConnection(d: ConnectionDecl): bool {
        for (let i = 0; i < this.entries.length; i++) if (this.entries[i].connection === d) return this.removeAt(i);
        return false;
    }

    removeEmbedded(d: EmbeddedDecl): bool {
        for (let i = 0; i < this.entries.length; i++) if (this.entries[i].embedded === d) return this.removeAt(i);
        return false;
    }

    removeConverter(d: DataConverterDecl): bool {
        for (let i = 0; i < this.entries.length; i++) if (this.entries[i].converter === d) return this.removeAt(i);
        return false;
    }

    removeEvent(d: EventDecl): bool {
        for (let i = 0; i < this.entries.length; i++) if (this.entries[i].event === d) return this.removeAt(i);
        return false;
    }

    removeAnimation(d: LinearAnimationDecl): bool {
        for (let i = 0; i < this.entries.length; i++) if (this.entries[i].animation === d) return this.removeAt(i);
        return false;
    }

    removeStateMachine(d: StateMachineDecl): bool {
        for (let i = 0; i < this.entries.length; i++) if (this.entries[i].stateMachine === d) return this.removeAt(i);
        return false;
    }
}

// --- format 2 (milestone 42) ------------------------------------------------------

// Whether `property` names a target that format 2 added: a known target
// (an output included) that is not one of format 1's. A name no class has
// is no format's: the validator's binding-property, in either version.
export function isFormat2Target(property: string): bool {
    if (property.length == 0 || isFormat1Target(property)) return false;
    const all = bindingTargets();
    for (let i = 0; i < all.length; i++) if (all[i].property == property) return true;
    return false;
}

// What makes a binding need format 2, or "" when nothing does: the words
// of a format-feature error ("mode=\"to_source\"", "once", "global",
// "converter", "the target material_override:metallic_texture_scale:x").
export function bindingFormat2Feature(b: BindingDecl): string {
    if (b.mode == "to_source") return "mode=\"to_source\"";
    if (b.writesOnce()) return "once";
    if (b.global.length > 0) return "global";
    if (b.converter.length > 0) return "converter";
    if (isFormat2Target(b.property)) return "the target " + b.property;
    return "";
}

// What makes a ViewModel sub_resource need format 2, or "": no file (the
// Rive project's data), or a file that is an .rml (a RiveData).
export function viewModelFormat2Feature(doc: RscnDoc, d: SubResourceDecl): string {
    if (d.type != "ViewModel") return "";
    const file = d.property("file");
    if (file == null) return "a ViewModel without a file";
    const v = file.value;
    // (an ExtResource: the id in `s`; another value is the validator's
    // property-type or property-resource-class, in either version)
    if (v.kind == ValueKind.ExtResource) {
        const ext = doc.findExt(v.s);
        if (ext != null && ext.type == "RiveData") return "a ViewModel of RiveData";
    }
    return "";
}

// The format version `doc` needs: 2 when it uses anything format 2 added
// (a converter declaration, a binding with mode="to_source", once (true),
// global or converter, or naming a target format 1 did not have, a
// data_path property on a node, a ViewModel whose file is a RiveData or
// is absent; milestone 45: an Event or a LinearAnimation; milestone 46: a
// StateMachine, or a node setting a state machine's node property:
// isFormat2NodeProperty; milestone 47: a listener's node property,
// isListenerNodeProperty), else 1. The
// writer writes it as <rscn>'s format.
export function formatNeeded(doc: RscnDoc): i32 {
    for (let i = 0; i < doc.entries.length; i++) {
        const e = doc.entries[i];
        if (e.kind == EntryKind.Converter && e.converter != null) return 2;
        if (e.kind == EntryKind.Event && e.event != null) return 2;
        if (e.kind == EntryKind.Animation && e.animation != null) return 2;
        if (e.kind == EntryKind.StateMachine && e.stateMachine != null) return 2;
        const sub = e.sub;
        if (sub != null && viewModelFormat2Feature(doc, sub).length > 0) return 2;
        const node = e.node;
        if (node == null) continue;
        for (let k = 0; k < node.items.length; k++) {
            const item = node.items[k];
            const b = item.binding;
            if (b != null && bindingFormat2Feature(b).length > 0) return 2;
            const p = item.property;
            if (p != null && isFormat2NodeProperty(p.name)) return 2;
            if (p != null && isListenerNodeProperty(p.name, node.type)) return 2;
        }
    }
    return 1;
}

// Whether a node property named `name` is one format 2 added: data_path
// (milestone 42), and the state machine's (milestone 46: ../sm/decl.as
// DEFAULT_STATE_MACHINE_PROPERTY and INSTANCE_PROPERTIES).
export function isFormat2NodeProperty(name: string): bool {
    if (name == "data_path" || name == DEFAULT_STATE_MACHINE_PROPERTY) return true;
    for (let i = 0; i < INSTANCE_PROPERTIES.length; i++) if (INSTANCE_PROPERTIES[i] == name) return true;
    return false;
}

// Milestone 47: whether a node property named `name`, on a node of class
// `type` (null: an instanced scene's node, whose class only the instanced
// file says), is one of the listeners' (../sm/decl.as): listener_pass_through
// on any node; input_ray_pickable and pointer_forward on a
// GeometryInstance3D (a CollisionObject3D's input_ray_pickable is format
// 1's, milestone 31's). A file setting one needs format 2. An instancing
// node's own class is unknown here: its input_ray_pickable and
// pointer_forward keep the file's format (the validator checks them
// against the instanced root's class when the scene loads).
export function isListenerNodeProperty(name: string, type: string?): bool {
    if (name == LISTENER_PASS_THROUGH_PROPERTY) return true;
    if (name != INPUT_RAY_PICKABLE_PROPERTY && name != POINTER_FORWARD_PROPERTY) return false;
    return type != null && isA(type, "GeometryInstance3D");
}
