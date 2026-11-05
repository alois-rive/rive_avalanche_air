// The data subset of RML (docs/plans/RIVE_MODEL.md section 3.4): reads a
// Rive project's .rml text (rive's docs/format.md and data.md) for its
// ViewModel elements (their ViewModelProperty<Kind>s and ViewModelInstances
// with their values), DataEnumCustom with its DataEnumValues, and every root
// DataConverter* and ScriptedDataConverter (./model.as). Artboards and every
// other root element are skipped without being looked at. Engine code: the
// library reads a Rive project's declared .rml blobs with it at run time (a
// scene drawn from its text), the tools every .rml of the project
// (engine/src/source/project/project_data.as) and an .rml a scene's ViewModel names.
//
// RML refers by id (`client:object`). References are resolved within the
// file in two passes (a view model may name one declared after it); one to
// an id the file does not declare (another file of the project declares it:
// RML compiles a project's files as one document) is kept as "@" + the id,
// for ./source.as to resolve across the project's docs:
//
//   DataProperty.reference   viewModelReferenceId  (a view model's name)
//   DataProperty.enumName    enumId of a custom enum (an enum's name)
//   DataValue.instance       a nested view model value (an instance's name)
//   DataValue.text           an enum value (its key; number -1 until then)
//   DataConverterDecl.items  a group's converterId (a converter's name)
//
// An enum value is written as the id of its DataEnumValue (rive refuses a
// key there: "is not a reference"), read as the key, its index in
// DataValue.number. A system enum (DataEnumSystem) is not in the doc's
// enums (its property has no enum name, as the model says) but in its
// systemEnums, by id (DataProperty.systemEnum), so that it can be written
// back; its values still read as their keys.
//
// What rive refuses, this refuses too, as an error at the element
// (`rml-data`, with the file, line and column): an id that is not
// `client:object`, an id declared twice among the data elements, a property
// of a kind RML has not, an instance value that names no property of its
// view model or is of another kind than the property, a value its kind
// cannot read (a number with junk after it, a boolean other than
// true/false/1/0, a colour other than 6 or 8 hex digits), a reference of the
// file to an element of the wrong kind, a defaultInstanceId naming no
// instance of the view model. XML that does not read is `xml-syntax`, a root
// other than <Rive> `rml-root`.

import { Result } from "../../base/util";
import { parseF64 } from "../../base/parse";
import { XmlDocument, XmlKind, XmlNode, parseXmlText, xmlErrorOf } from "../../base/xml";
import { SceneryError } from "../error";
import { VmKind } from "../riv/riv_info";
import {
    DataAttr, DataConverterDecl, DataDoc, DataEnum, DataInstance, DataProperty, DataValue, DataViewModel, DataWhere,
    isConverterElement,
} from "./model";

// The code of a data element rive would refuse.
export const RML_DATA_ERROR = "rml-data";
// The code of a document whose root is not <Rive>.
export const RML_ROOT_ERROR = "rml-root";
// The warning of a data source that does not read (an .rml of the project,
// or the one a ViewModel names): the scene still draws.
export const DATA_SOURCE_UNREADABLE = "data-source-unreadable";

const RML_HINT = "rive's docs/data.md describes view models, enums and converters in RML";

export const RML_PROPERTY_PREFIX = "ViewModelProperty";
export const RML_INSTANCE_PREFIX = "ViewModelInstance";

// The kind of a ViewModelProperty<Kind> or ViewModelInstance<Kind> element
// by its <Kind> (the prefix taken off), or -1 when RML has no such kind.
// Kinds the tools do not bind (artboards, assets, a list's symbol index)
// read as Other.
export function rmlKindOf(suffix: string): i32 {
    if (suffix == "Number") return <i32>VmKind.Number;
    if (suffix == "String") return <i32>VmKind.String;
    if (suffix == "Boolean") return <i32>VmKind.Boolean;
    if (suffix == "Color") return <i32>VmKind.Color;
    if (suffix == "EnumCustom" || suffix == "EnumSystem" || suffix == "Enum") return <i32>VmKind.Enum;
    if (suffix == "Trigger") return <i32>VmKind.Trigger;
    if (suffix == "ViewModel") return <i32>VmKind.ViewModel;
    if (suffix == "List") return <i32>VmKind.List;
    if (suffix == "Artboard" || suffix == "SymbolListIndex" || suffix == "AssetImage" || suffix == "AssetFont"
        || suffix == "AssetBlob") {
        return <i32>VmKind.Other;
    }
    return -1;
}

// Whether `s` is an RML id: `client:object`, both decimal without a leading
// zero (format.md: "04:23" is malformed), and not the reserved 0:0.
export function isRmlId(s: string): bool {
    const colon = s.indexOf(":");
    if (colon <= 0 || colon == s.length - 1) return false;
    if (!isNumberPart(s, 0, colon) || !isNumberPart(s, colon + 1, s.length)) return false;
    return s != "0:0";
}

function isNumberPart(s: string, from: i32, to: i32): bool {
    if (to - from > 1 && s.charCodeAt(from) == 48) return false;
    for (let i = from; i < to; i++) {
        const c = s.charCodeAt(i);
        if (c < 48 || c > 57) return false;
    }
    return to > from;
}

// A colour as RML writes it: 8 hex digits of ARGB, or 6 of RGB taken as
// opaque; -1 when it is not one (an i64, so that every u32 fits).
export function rmlColorOf(s: string): i64 {
    if (s.length != 8 && s.length != 6) return -1;
    let v: u32 = 0;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        let d: i32 = -1;
        if (c >= 48 && c <= 57) d = c - 48;
        else if (c >= 65 && c <= 70) d = c - 55;
        else if (c >= 97 && c <= 102) d = c - 87;
        if (d < 0) return -1;
        v = (v << 4) | <u32>d;
    }
    if (s.length == 6) v |= 0xFF000000;
    return <i64>v;
}

// A number as RML writes one: decimal and finite; NaN when it is not one.
export function rmlNumberOf(s: string): f64 {
    if (s.length == 0) return NaN;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        // (parseF64 also takes "inf" and "nan": RML does not)
        if (!(c >= 48 && c <= 57) && c != 45 && c != 43 && c != 46 && c != 101 && c != 69) return NaN;
    }
    const r = parseF64(s);
    if (!r.ok || !isFinite(r.value)) return NaN;
    return r.value;
}

const ID_VIEW_MODEL = 0;
const ID_INSTANCE = 1;
const ID_PROPERTY = 2;
const ID_ENUM = 3;
const ID_ENUM_VALUE = 4;
const ID_CONVERTER = 5;

// What the first pass learnt of an id.
class IdEntry {
    // ID_*.
    what: i32;
    // The view model (for itself, a property and an instance), the enum
    // (for itself and a value) or the converter: its index.
    owner: i32;
    // A property's, an instance's or an enum value's index in its owner.
    index: i32;

    constructor(what: i32, owner: i32, index: i32) {
        this.what = what;
        this.owner = owner;
        this.index = index;
    }
}

// An enum of the file, custom or system.
class EnumRead {
    decl: DataEnum;
    system: bool;

    constructor(decl: DataEnum, system: bool) {
        this.decl = decl;
        this.system = system;
    }
}

function attrOr(n: XmlNode, name: string, dflt: string): string {
    const v = n.attr(name);
    return v != null ? v as string : dflt;
}

function vmKindWord(k: VmKind): string {
    switch (k) {
        case VmKind.Number: return "Number";
        case VmKind.String: return "String";
        case VmKind.Boolean: return "Boolean";
        case VmKind.Color: return "Color";
        case VmKind.Enum: return "Enum";
        case VmKind.Trigger: return "Trigger";
        case VmKind.ViewModel: return "ViewModel";
        case VmKind.List: return "List";
        default: return "another kind";
    }
}

class Reader {
    file: string;
    doc: DataDoc = new DataDoc();
    ids: Map<string, IdEntry> = new Map<string, IdEntry>();
    enums: Array<EnumRead> = [];
    err: SceneryError? = null;
    // What the second pass reads, with where it belongs.
    vmElements: Array<XmlNode> = [];
    instanceElements: Array<XmlNode> = [];
    instanceOwners: Array<i32> = [];
    instanceIndices: Array<i32> = [];
    propertyElements: Array<XmlNode> = [];
    propertyOwners: Array<i32> = [];
    propertyIndices: Array<i32> = [];
    converterElements: Array<XmlNode> = [];

    constructor(file: string) {
        this.file = file;
        this.doc.file = file;
    }

    where(n: XmlNode): DataWhere {
        const w = new DataWhere();
        w.file = this.file;
        w.line = n.pos.line;
        w.col = n.pos.col;
        return w;
    }

    fail(n: XmlNode, message: string): bool {
        if (this.err == null) this.err = SceneryError.at(RML_DATA_ERROR, this.file, n.pos.line, n.pos.col, message, RML_HINT);
        return false;
    }

    lookup(id: string): IdEntry? {
        return id.length > 0 && this.ids.has(id) ? this.ids.get(id) : null;
    }

    // Records the element's id (when it has one) and answers it ("" for
    // none); fails on one malformed or declared twice.
    declare(n: XmlNode, entry: IdEntry): string {
        const id = n.attr("id");
        if (id == null) return "";
        const s = id as string;
        if (!isRmlId(s)) {
            this.fail(n, "id=\"" + s + "\" is not an id; ids are numeric \"client:object\", like \"0:12\"");
            return "";
        }
        if (this.ids.has(s)) {
            this.fail(n, "duplicate id \"" + s + "\"; every authored id must be unique");
            return "";
        }
        this.ids.set(s, entry);
        return s;
    }

    // A reference attribute's id: "" when absent; null (and failed) when it
    // is not an id.
    ref(n: XmlNode, attr: string): string? {
        const v = n.attr(attr);
        if (v == null) return "";
        const s = v as string;
        if (!isRmlId(s)) {
            this.fail(n, attr + "=\"" + s + "\" is not a reference; ids are numeric \"client:object\", like \"0:12\"");
            return null;
        }
        return s;
    }

    read(xml: XmlDocument): DataDoc? {
        const root = xml.root;
        if (root.name != "Rive") {
            this.err = SceneryError.at(RML_ROOT_ERROR, this.file, root.pos.line, root.pos.col,
                "not an RML document: its root is <" + root.name + ">, not <Rive>",
                "an .rml file is `<Rive version=\"1\" kind=\"fragment\">` holding root elements (rive's docs/format.md)");
            return null;
        }
        // Pass 1: every data element and its id.
        const roots = root.children;
        for (let i = 0; i < roots.length && this.err == null; i++) {
            const n = roots[i];
            if (n.kind != XmlKind.Element) continue;
            const tag = n.name;
            if (tag == "ViewModel") this.viewModel(n);
            else if (tag == "DataEnumCustom") this.enumElement(n, false);
            else if (tag == "DataEnumSystem") this.enumElement(n, true);
            else if (isConverterElement(tag)) this.converterHead(n);
        }
        // Instances and properties at the root naming their view model by
        // viewModelId (format.md: nesting sets that reference; writing it
        // does too).
        for (let i = 0; i < roots.length && this.err == null; i++) {
            const n = roots[i];
            if (n.kind != XmlKind.Element) continue;
            const instance = n.name == "ViewModelInstance";
            if (!instance && !n.name.startsWith(RML_PROPERTY_PREFIX)) continue;
            const vmId = this.ref(n, "viewModelId");
            if (vmId == null) break;
            const e = this.lookup(vmId);
            if (e == null || e.what != ID_VIEW_MODEL) {
                this.fail(n, "<" + n.name + "> at the root names no view model of this file"
                    + (vmId.length > 0 ? " (viewModelId=\"" + vmId + "\")" : " (it has no viewModelId)"));
                break;
            }
            if (instance) this.instanceHead(n, e.owner);
            else this.propertyHead(n, e.owner);
        }
        // Pass 2: references and values.
        for (let i = 0; i < this.propertyElements.length && this.err == null; i++) {
            this.propertyRefs(this.propertyElements[i], this.propertyOwners[i], this.propertyIndices[i]);
        }
        for (let i = 0; i < this.instanceElements.length && this.err == null; i++) {
            this.instanceValues(this.instanceElements[i], this.instanceOwners[i], this.instanceIndices[i]);
        }
        for (let i = 0; i < this.vmElements.length && this.err == null; i++) this.defaultInstance(this.vmElements[i], i);
        for (let i = 0; i < this.converterElements.length && this.err == null; i++) {
            this.converterItems(this.converterElements[i], this.doc.converters[i]);
        }
        return this.err != null ? null : this.doc;
    }

    viewModel(n: XmlNode): void {
        const vm = new DataViewModel();
        const index = this.doc.viewModels.length;
        vm.name = attrOr(n, "name", "");
        vm.global = attrOr(n, "viewModelType", "") == "global";
        vm.where = this.where(n);
        vm.id = this.declare(n, new IdEntry(ID_VIEW_MODEL, index, 0));
        if (this.err != null) return;
        this.doc.viewModels.push(vm);
        this.vmElements.push(n);
        const kids = n.children;
        for (let i = 0; i < kids.length && this.err == null; i++) {
            const k = kids[i];
            if (k.kind != XmlKind.Element) continue;
            if (k.name == "ViewModelInstance") this.instanceHead(k, index);
            else if (k.name.startsWith(RML_PROPERTY_PREFIX)) this.propertyHead(k, index);
            // (anything else is left alone)
        }
    }

    propertyHead(n: XmlNode, vmIndex: i32): void {
        const vm = this.doc.viewModels[vmIndex];
        const k = rmlKindOf(n.name.substring(RML_PROPERTY_PREFIX.length));
        if (k < 0) {
            this.fail(n, "<" + n.name + "> is not a view model property; the kinds are Number, String, Boolean, Color, "
                + "EnumCustom, EnumSystem, Trigger, ViewModel, List, Artboard, AssetImage, AssetFont, AssetBlob and "
                + "SymbolListIndex");
            return;
        }
        const p = new DataProperty();
        p.name = attrOr(n, "name", "");
        p.kind = <VmKind>k;
        p.where = this.where(n);
        const index = vm.properties.length;
        p.id = this.declare(n, new IdEntry(ID_PROPERTY, vmIndex, index));
        if (this.err != null) return;
        vm.properties.push(p);
        this.propertyElements.push(n);
        this.propertyOwners.push(vmIndex);
        this.propertyIndices.push(index);
    }

    instanceHead(n: XmlNode, vmIndex: i32): void {
        const vm = this.doc.viewModels[vmIndex];
        const inst = new DataInstance();
        inst.name = attrOr(n, "name", "");
        inst.where = this.where(n);
        const index = vm.instances.length;
        inst.id = this.declare(n, new IdEntry(ID_INSTANCE, vmIndex, index));
        if (this.err != null) return;
        vm.instances.push(inst);
        this.instanceElements.push(n);
        this.instanceOwners.push(vmIndex);
        this.instanceIndices.push(index);
    }

    enumElement(n: XmlNode, system: bool): void {
        const e = new DataEnum();
        e.name = attrOr(n, "name", "");
        e.where = this.where(n);
        const index = this.enums.length;
        e.id = this.declare(n, new IdEntry(ID_ENUM, index, 0));
        if (this.err != null) return;
        this.enums.push(new EnumRead(e, system));
        if (system) {
            e.system = true;
            e.enumType = attrOr(n, "enumType", "");
            this.doc.systemEnums.push(e);
        } else {
            this.doc.enums.push(e);
        }
        const kids = n.children;
        for (let i = 0; i < kids.length && this.err == null; i++) {
            const k = kids[i];
            if (k.kind != XmlKind.Element || k.name != "DataEnumValue") continue;
            const vid = this.declare(k, new IdEntry(ID_ENUM_VALUE, index, e.values.length));
            e.values.push(attrOr(k, "key", ""));
            e.valueIds.push(vid);
            e.labels.push(attrOr(k, "value", ""));
        }
    }

    converterHead(n: XmlNode): void {
        const c = this.converterDecl(n, new IdEntry(ID_CONVERTER, this.doc.converters.length, 0));
        if (c == null) return;
        this.doc.converters.push(c);
        this.converterElements.push(n);
    }

    // A converter, or a child of one (a formula's tokens, an interpolator):
    // its type, name, id and other attributes, its element children kept
    // as written. A group's items are read in the second pass.
    converterDecl(n: XmlNode, entry: IdEntry?): DataConverterDecl? {
        const c = new DataConverterDecl();
        c.type = n.name;
        c.name = attrOr(n, "name", "");
        c.where = this.where(n);
        if (entry != null) c.id = this.declare(n, entry);
        else c.id = attrOr(n, "id", "");
        if (this.err != null) return null;
        for (let i = 0; i < n.attrs.length; i++) {
            const a = n.attrs[i];
            if (a.name == "name" || a.name == "id") continue;
            c.attrs.push(new DataAttr(a.name, a.value));
        }
        const kids = n.children;
        for (let i = 0; i < kids.length; i++) {
            const k = kids[i];
            if (k.kind != XmlKind.Element || k.name == "DataConverterGroupItem") continue;
            const child = this.converterDecl(k, null);
            if (child == null) return null;
            c.children.push(child);
        }
        return c;
    }

    converterItems(n: XmlNode, c: DataConverterDecl): void {
        const kids = n.children;
        for (let i = 0; i < kids.length && this.err == null; i++) {
            const k = kids[i];
            if (k.kind != XmlKind.Element || k.name != "DataConverterGroupItem") continue;
            const id = this.ref(k, "converterId");
            if (id == null) return;
            if (id.length == 0) {
                this.fail(k, "<DataConverterGroupItem> names no converter (it has no converterId)");
                return;
            }
            const e = this.lookup(id);
            if (e == null) c.items.push("@" + id);
            else if (e.what != ID_CONVERTER) this.fail(k, "converterId=\"" + id + "\" names no converter");
            else c.items.push(this.doc.converters[e.owner].name);
        }
    }

    propertyRefs(n: XmlNode, vmIndex: i32, index: i32): void {
        const p = this.doc.viewModels[vmIndex].properties[index];
        if (p.kind == VmKind.ViewModel) {
            const id = this.ref(n, "viewModelReferenceId");
            if (id == null || id.length == 0) return;
            const e = this.lookup(id);
            if (e == null) p.reference = "@" + id;
            else if (e.what != ID_VIEW_MODEL) this.fail(n, "viewModelReferenceId=\"" + id + "\" names no view model");
            else p.reference = this.doc.viewModels[e.owner].name;
        } else if (p.kind == VmKind.Enum) {
            const id = this.ref(n, "enumId");
            if (n.name.endsWith("EnumSystem")) {
                p.enumSystem = true;
                p.enumType = attrOr(n, "enumType", "");
                p.systemEnum = id != null ? id : "";
            }
            if (id == null || id.length == 0) return;
            const e = this.lookup(id);
            const custom = n.name.endsWith("EnumCustom");
            if (e == null) {
                if (custom) p.enumName = "@" + id;
            } else if (e.what != ID_ENUM) {
                this.fail(n, "enumId=\"" + id + "\" names no enum");
            } else if (!this.enums[e.owner].system) {
                p.enumName = this.enums[e.owner].decl.name;
            }
        }
    }

    instanceValues(n: XmlNode, vmIndex: i32, index: i32): void {
        const vm = this.doc.viewModels[vmIndex];
        const inst = vm.instances[index];
        const kids = n.children;
        for (let i = 0; i < kids.length && this.err == null; i++) {
            const k = kids[i];
            if (k.kind != XmlKind.Element || !k.name.startsWith(RML_INSTANCE_PREFIX)) continue;
            const kind = rmlKindOf(k.name.substring(RML_INSTANCE_PREFIX.length));
            if (kind < 0) {
                this.fail(k, "<" + k.name + "> is not a view model instance value");
                return;
            }
            const pid = this.ref(k, "viewModelPropertyId");
            if (pid == null) return;
            const e = this.lookup(pid);
            if (e == null || e.what != ID_PROPERTY || e.owner != vmIndex) {
                this.fail(k, "<" + k.name + "> names no property of the view model " + vm.name
                    + (pid.length > 0 ? " (viewModelPropertyId=\"" + pid + "\")" : " (it has no viewModelPropertyId)"));
                return;
            }
            const prop = vm.properties[e.index];
            if (<i32>prop.kind != kind) {
                this.fail(k, "<" + k.name + "> sets " + prop.name + ", a " + vmKindWord(prop.kind) + " property");
                return;
            }
            const v = new DataValue();
            v.property = e.index;
            v.kind = prop.kind;
            v.id = attrOr(k, "id", "");
            if (!this.value(k, prop, v)) return;
            inst.values.push(v);
        }
    }

    // The value of `k` (its propertyValue) into `v`, by the property's kind.
    value(k: XmlNode, prop: DataProperty, v: DataValue): bool {
        const raw = k.attr("propertyValue");
        const s = raw != null ? raw as string : "";
        if (prop.kind == VmKind.Number) {
            if (raw == null) return true;
            const x = rmlNumberOf(s);
            if (isNaN(x)) return this.fail(k, "propertyValue=\"" + s + "\" is not a number");
            v.number = x;
        } else if (prop.kind == VmKind.Boolean) {
            if (raw == null) return true;
            if (s == "true" || s == "1") v.boolean = true;
            else if (s == "false" || s == "0") v.boolean = false;
            else return this.fail(k, "propertyValue=\"" + s + "\" is not a boolean (true, false, 1 or 0)");
        } else if (prop.kind == VmKind.Color) {
            // (ViewModelInstanceColor's default: opaque black)
            v.color = 0xFF000000;
            if (raw == null) return true;
            const c = rmlColorOf(s);
            if (c < 0) return this.fail(k, "propertyValue=\"" + s + "\" is not a colour (8 hex digits of ARGB)");
            v.color = <u32>c;
        } else if (prop.kind == VmKind.String) {
            v.text = s;
        } else if (prop.kind == VmKind.Enum) {
            v.number = -1;
            if (raw == null) return true;
            const id = this.ref(k, "propertyValue");
            if (id == null) return false;
            const e = this.lookup(id);
            if (e == null) {
                v.text = "@" + id;
            } else if (e.what != ID_ENUM_VALUE) {
                return this.fail(k, "propertyValue=\"" + id + "\" names no enum value");
            } else {
                v.text = this.enums[e.owner].decl.values[e.index];
                v.number = <f64>e.index;
            }
        } else if (prop.kind == VmKind.ViewModel) {
            if (raw == null) return true;
            const id = this.ref(k, "propertyValue");
            if (id == null) return false;
            const e = this.lookup(id);
            if (e == null) v.instance = "@" + id;
            else if (e.what != ID_INSTANCE) return this.fail(k, "propertyValue=\"" + id + "\" names no view model instance");
            else v.instance = this.doc.viewModels[e.owner].instances[e.index].name;
        }
        return true;
    }

    defaultInstance(n: XmlNode, vmIndex: i32): void {
        const vm = this.doc.viewModels[vmIndex];
        vm.defaultInstance = vm.instances.length > 0 ? 0 : -1;
        const id = this.ref(n, "defaultInstanceId");
        if (id == null || id.length == 0) return;
        const e = this.lookup(id);
        if (e == null || e.what != ID_INSTANCE || e.owner != vmIndex) {
            this.fail(n, "defaultInstanceId=\"" + id + "\" names no instance of the view model " + vm.name);
            return;
        }
        vm.defaultInstance = e.index;
    }
}

// `text` with every `-` inside a comment's body made a space: rive's XML
// reader (tinyxml2) takes `--` inside a comment, which XML refuses and
// ../../base/xml.as refuses with it ("`rive x --artboard=y`" in a comment
// of the samples' scene.rml). Lengths, lines and columns are unchanged, so
// every position read from the result is one in `text`. CDATA sections are
// left as they are.
export function relaxRmlComments(text: string): string {
    let at = text.indexOf("<!--");
    if (at < 0) return text;
    let out = "";
    let from = 0;
    // Where the next CDATA search starts. Not `from`, which stays at the
    // last comment's end while CDATA sections are skipped: searching from
    // there finds the same section on every pass and never ends.
    let scan = 0;
    while (at >= 0) {
        const cdata = text.indexOf("<![CDATA[", scan);
        if (cdata >= 0 && cdata < at) {
            const close = text.indexOf("]]>", cdata);
            if (close < 0) break;
            scan = close + 3;
            at = text.indexOf("<!--", scan);
            continue;
        }
        const body = at + 4;
        // (the first `-->` ends it, as for tinyxml2: in "--->" the first
        // dash is the body's)
        const end = text.indexOf("-->", body);
        if (end < 0) break;
        out += text.substring(from, body) + text.substring(body, end).replaceAll("-", " ");
        from = end;
        scan = end + 3;
        at = text.indexOf("<!--", scan);
    }
    return out + text.substring(from);
}

// The data model `text` declares (`file` as errors name it). Fails on text
// that is not XML (`xml-syntax`), or not an RML document (`rml-root`); a
// data element that is malformed fails with its position (`rml-data`, see
// the header), as `rive` would refuse it.
export function readRmlData(text: string, file: string): Result<DataDoc> {
    const r = parseXmlText(relaxRmlComments(text), file);
    if (!r.ok) {
        const e = xmlErrorOf<XmlDocument>(r);
        if (e != null) return SceneryError.at("xml-syntax", file, e.pos.line, e.pos.col, e.message).fail<DataDoc>();
        return SceneryError.at("xml-syntax", file, 0, 0, r.err).fail<DataDoc>();
    }
    const reader = new Reader(file);
    const doc = reader.read(r.value);
    const err = reader.err;
    if (err != null) return err.fail<DataDoc>();
    if (doc == null) return SceneryError.at(RML_DATA_ERROR, file, 0, 0, "unreadable RML").fail<DataDoc>();
    return Result.okv<DataDoc>(doc);
}
