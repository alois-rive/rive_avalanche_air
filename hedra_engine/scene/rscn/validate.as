// The .rscn validator: what one document must satisfy beyond its syntax
// (the reader, parse.as, has checked that), found without loading anything
// it refers to: unique ids, declared and earlier references, parents that
// exist, names that are valid and unique, types and properties checked
// against the classes of format 1 (../classdb.as), connections between
// nodes that exist. It collects every problem rather than stopping at the
// first: errors, and warnings for what a newer tool may have written
// (unknown types, properties, elements and attributes), which are kept and
// written back. docs/formats/RSCN.md, "Validation", is the normative list,
// with the code of each problem.
//
// What only instancing can check (a path through an instanced scene, an
// override of a node inside one) is left to the scene tree
// (../tree/instance.as): the validator accepts a path whose first unknown
// segment is below an instanced node.
//
// Milestone 42: format 2 (doc.as formatNeeded). A file that says format 1
// and uses a construct of format 2 is the error format-feature, at the
// construct; a scene's converters (a name each, unique: converter-
// duplicate), a property that is an output (property-output), data_path on
// a node that instances nothing (data-path-misplaced) and the new binding
// attributes (../binding/binding.as) are checked here.
//
// Milestone 45: a scene's timelines (<Event>, <LinearAnimation>) are
// checked by ../anim/check.as, entry by entry, with the same reporting.
//
// Milestone 46: a scene's state machines (<StateMachine>) and the state
// machine's node properties (default_state_machine, instance_*) are
// checked by ../sm/check.as, with the same reporting.
//
// Milestone 47: a state machine's listeners are checked there too; the
// listeners' node properties (listener_pass_through, a
// GeometryInstance3D's input_ray_pickable and pointer_forward) need format
// 2 (format-feature, as doc.as isListenerNodeProperty says).
//
// Diagnostics come in source order: the entries are checked in the order
// they are written, and the problems of one entry are sorted by position
// (when every one of them has a position: a document built in code has
// none, and then the order is the order of the checks).

import { XmlAttr, XmlKind, XmlNode, XmlPos } from "../../base/xml";
import { toAsciiLowercase } from "../../base/util";
import { Diagnostic, Diagnostics, Severity } from "../error";
import {
    PropInfo, PropType, classInfo, extTypeAccepts, extTypeNames, findProp, isA, nodeClassNames, subResourceClassNames,
} from "../classdb";
import { Value, ValueKind } from "../value";
import {
    BindingDecl, BodyItem, BodyKind, ConnectionDecl, Declaration, DocKind, EmbeddedDecl, EntryKind, ExtResourceDecl, NodeDecl, Property, RscnDoc,
    SubResourceDecl, bindingFormat2Feature, isFormat2NodeProperty, isListenerNodeProperty, viewModelFormat2Feature,
} from "./doc";
import { DataConverterDecl } from "../data/model";
import { newPrimitive, setPrimitiveField, tooLargeHint, tooLargeMessage } from "../resource/primitives";
import { isUniqueSegment } from "../tree/paths";
import { printNumber } from "../value_text";
import { BINDING_PATH_HINT, BindingProblem, readBindingDecl } from "../binding/binding";
import { BindKind, BindingTarget, bindingTargets, bindingTargetsOf, findBindingTarget, isFormat1Target } from "../binding/targets";
import { AnimChecker } from "../anim/check";
import { EventDecl, LinearAnimationDecl } from "../anim/decl";
import { SmChecker, checkStateMachineProperty } from "../sm/check";
import { StateMachineDecl } from "../sm/decl";
import { CURVE_POINT_STRIDE } from "../path/curve3d";
import { CURVE_DATA_STRIDE } from "../resource/curve";
import { CLI } from "../../base/names";
import { ID_HINT, SCENE_PATHS, idProblem, pathExtensionOf, resourcePathProblem } from "../textdoc/check";

// Every problem of the document, in source order.
export function validateRscn(doc: RscnDoc): Diagnostics {
    return new Validator(doc).run();
}

// --- small helpers -------------------------------------------------------------

// The characters a node name may not hold: Godot's, which its node paths
// (`A/B`, `%Name`, `Node:property`, `@` for generated names) give a meaning.
const NAME_FORBIDDEN = ".:@/\"%";
const NAME_HINT = "a node name may not be empty or hold any of . : @ / \" %";
const PARENT_HINT = "a parent is \".\" (the root) or the path from the root of a node declared before it, such as \"Arm/Hand\"";
const PATH_HINT = "name a file by res://<path> (from the project root) or by a path relative to this file, with /";
export const KEPT_HINT = "it is kept and written back unchanged, and otherwise ignored";

// The first character of `name` that NAME_FORBIDDEN holds, or "" (by
// code, so that a good name, which every node of a scene has, allocates
// nothing).
function forbiddenChar(name: string): string {
    for (let i = 0; i < name.length; i++) {
        const c = name.charCodeAt(i);
        for (let k = 0; k < NAME_FORBIDDEN.length; k++) if (NAME_FORBIDDEN.charCodeAt(k) == c) return name.charAt(i);
    }
    return "";
}

// The numbers one MultiMesh instance takes in its buffer: Godot's layout
// (a 3D transform 12, a 2D one 8; a colour 4; custom data 4).
export function multiMeshStride(is3d: bool, colors: bool, custom: bool): i32 {
    return (is3d ? 12 : 8) + (colors ? 4 : 0) + (custom ? 4 : 0);
}

export const MULTIMESH_STRIDE_HINT = "buffer holds instance_count instances, each 12 numbers (8 for transform_2d), "
    + "4 more with use_colors and 4 more with use_custom_data";

const RANGE_MARGINS: Array<string> = ["visibility_range_begin_margin", "visibility_range_end_margin"];

// The attributes each element knows (built once: the validator checks
// them on every node and property of a scene).
const EXT_ATTRS: Array<string> = ["id", "type", "path", "uid"];
const SUB_ATTRS: Array<string> = ["id", "type"];
const NODE_ATTRS: Array<string> = ["name", "type", "parent", "instance"];
const NAME_ATTRS: Array<string> = ["name"];
const CONNECTION_ATTRS: Array<string> = ["signal", "from", "to", "method", "flags"];
const EMBEDDED_ATTRS: Array<string> = ["path", "size"];
const ROOT_ATTRS: Array<string> = ["format", "uid"];
const RESOURCE_ATTRS: Array<string> = ["type"];
const BINDING_ATTRS: Array<string> = ["property", "path", "mode", "once", "global", "converter", "scale", "offset", "convert"];

// Milestone 17: the hints of the binding problems only the validator finds
// (../binding/binding.as has those of a binding's own attributes).
const BINDING_PROPERTY_HINT = "a binding's property is a target of the node's class: docs/formats/RSCN.md, \"Bindings\", lists them";
const BINDING_CONVERSION_HINT = "scale, offset and convert convert numbers: a boolean or colour target takes the view model's value as it is";
// Milestone 42.
export const FORMAT_FEATURE_HINT = "write format=\"2\" on <rscn> (" + CLI + " format writes the version a file needs)";
const PROPERTY_OUTPUT_HINT = "an output is computed by the run time and is never written: bind it with "
    + "<binding property=\"...\" path=\"...\" mode=\"to_source\"/> to read it into the view model";
const PROPERTY_DERIVED_HINT = "progress_ratio stands for progress over the curve's baked length: write progress (metres), "
    + "or key and bind progress_ratio; see docs/formats/RSCN.md \"Paths\"";
const DATA_PATH_HINT = "data_path goes on a node that instances a scene (instance=\"ExtResource(...)\"): "
    + "it names the nested view model that scene's bindings start from";
const CONVERTER_DUPLICATE_HINT = "a scene's converters are named, and a binding names one by its name: give each its own";
const CONVERTER_ID_HINT = "a scene's converter is named, not numbered (RML's ids are the Rive project's): "
    + "it is kept and written back, and otherwise ignored";

const VIEW_MODEL_ROOT_HINT = "only the scene's root names its view model (an instanced scene's bindings use the outermost scene's): "
    + "set view_model on the root";

// The most targets a binding-property message lists; a class with more
// (a MeshInstance3D has hundreds since format 2) gets those that share the
// property's own first part (`material_override:` for a slip in one), else
// its format-1 targets, else its first ones, and a count of the rest.
const TARGET_LIST_MAX: i32 = 24;

// The binding targets of `className` as a list for messages: "a, b or c",
// or for a class with many, those near `property` and how many more.
function targetList(className: string, property: string = ""): string {
    const ts = bindingTargetsOf(className);
    const names = new Array<string>();
    for (let i = 0; i < ts.length; i++) names.push(ts[i].property);
    if (names.length <= TARGET_LIST_MAX) return orList(names);
    const colon = property.indexOf(":");
    const stem = colon > 0 ? property.substring(0, colon + 1) : property + ":";
    let near = new Array<string>();
    for (let i = 0; i < names.length && near.length < TARGET_LIST_MAX; i++) if (names[i].startsWith(stem)) near.push(names[i]);
    if (near.length == 0) {
        for (let i = 0; i < names.length && near.length < TARGET_LIST_MAX; i++) if (isFormat1Target(names[i])) near.push(names[i]);
    }
    if (near.length == 0) near = names.slice(0, TARGET_LIST_MAX);
    return near.join(", ") + " and " + (names.length - near.length).toString() + " more (docs/formats/RSCN.md, \"Bindings\")";
}

// A target kind as a binding-conversion message says it ("a boolean
// target", "an enum target").
function kindWord(k: BindKind): string {
    if (k == BindKind.Boolean) return "boolean";
    if (k == BindKind.Color) return "colour";
    if (k == BindKind.String) return "string";
    if (k == BindKind.Enum) return "enum";
    return "number";
}

// The attribute a format-2 feature of a binding is at (bindingFormat2Feature's
// words), for format-feature's position.
function featureAttr(feature: string): string {
    if (feature.startsWith("mode")) return "mode";
    if (feature == "once" || feature == "global" || feature == "converter") return feature;
    return "property";
}

// The owner of the first target named `property` whatever its class (for
// "light_energy is a Light3D's"), or "".
function targetOwner(property: string): string {
    const all = bindingTargets();
    for (let i = 0; i < all.length; i++) if (all[i].property == property) return all[i].owner;
    return "";
}

// Milestone 31: the collision shapes' warnings (checkShape).
export const SHAPE_DATA_HINT = "a ConcavePolygonShape3D's data is three points a triangle, nine numbers";
export const SHAPE_SIZE_HINT = "a shape's lengths are in metres, more than 0 (a box's sides 0 or more); see docs/formats/RSCN.md \"Interaction\"";
const SHAPE_EMPTY = "the shape is empty (nothing overlaps it, no ray meets it)";
const AXES: Array<string> = ["x", "y", "z"];
const SPHERE_SIZES: Array<string> = ["radius"];
const RADIUS_HEIGHT: Array<string> = ["radius", "height"];

// Milestone 32: a Curve3D's warnings (checkCurve).
export const CURVE_DATA_HINT = "write _data as {\"points\": PackedVector3Array(...), \"tilts\": PackedFloat32Array(...)}, "
    + "as Godot does; see docs/formats/RSCN.md \"Paths\"";
export const CURVE_POINT_COUNT_HINT = "point_count is the number of points in _data; the editor writes both";
export const CURVE_BAKE_INTERVAL_HINT = "Godot's range is 0.01 to 512 metres; 0.2 is the default";

// Milestone 35: a Curve's and a Gradient's warnings (checkParticleCurve,
// checkGradientStops).
export const PARTICLE_CURVE_HINT = "write _data as Godot does, five items a point: Vector2(offset, value), "
    + "left_tangent, right_tangent, left_mode, right_mode (0 free, 1 linear); see docs/formats/RSCN.md \"Particles\"";
export const GRADIENT_STOPS_HINT = "offsets has one number a stop and colors one colour (four numbers) a stop, "
    + "in the same order; see docs/formats/RSCN.md \"Particles\"";

// Milestone 14: the classes a material document's <resource> may be (the concrete
// materials a sub_resource may be: StandardMaterial3D in format 1; the sky
// materials are SkyMaterials, a Sky's, not Materials), for the messages.
export function materialClassNames(): Array<string> {
    const out = new Array<string>();
    const names = subResourceClassNames();
    for (let i = 0; i < names.length; i++) if (isMaterialClass(names[i])) out.push(names[i]);
    return out;
}

// Whether `type` is a class a material document's <resource> may be: a Material a
// sub_resource may have (so, concrete), which a Material slot takes.
// (Milestone 37: not a FogMaterial, which only a FogVolume draws: a material
// file is a surface's. Milestone 61: nor a ShaderMaterial, which MaterialX
// cannot hold: its shader is a .wgsl file a scene names.)
export function isMaterialClass(type: string): bool {
    const info = classInfo(type);
    return info != null && info.subResource && isA(type, "Material") && type != "FogMaterial" && type != "ShaderMaterial";
}

// The hints of the material document's own problems.
export const RESOURCE_MISSING_HINT = "a material document holds one <resource type=\"StandardMaterial3D\"> after its ext_resources "
    + "(a material file is MaterialX: docs/formats/MATERIALS.md)";

// " (first at line N)" when the earlier position is known, else "".
function firstAt(p: XmlPos): string {
    return p.line > 0 ? " (first at line " + p.line.toString() + ")" : "";
}

// " (line N)" when known, else "".
function lineOf(p: XmlPos): string {
    return p.line > 0 ? " (line " + p.line.toString() + ")" : "";
}

// "a", "b or c", "a, b or c".
function orList(items: Array<string>): string {
    if (items.length == 0) return "";
    if (items.length == 1) return items[0];
    return items.slice(0, items.length - 1).join(", ") + " or " + items[items.length - 1];
}

// What a value is, for "found ..." in messages: its kind as the format
// spells it, and for a constructor this format version does not know, its
// name ("AABB").
export function foundText(v: Value): string {
    if (v.kind == ValueKind.Unknown) {
        const paren = v.s.indexOf("(");
        return paren > 0 ? v.s.substring(0, paren).trim() : v.s;
    }
    return v.kindName();
}

// "a float", "an int", "a Resource (Mesh)", "an Environment".
export function withArticle(t: string): string {
    return (t.length > 0 && "AEIOUaeiou".includes(t.charAt(0)) ? "an " : "a ") + t;
}

// The first number of `v` (a float, or a component of a vector or colour)
// that is inf or nan once held as the f32 a material holds, as the format
// prints it ("inf", "nan"; a number finite as an f64 but too large for an
// f32, which would be written "inf", says so), or "" when every one is
// finite (or `v` holds no numbers).
function firstNonFinite(v: Value): string {
    if (v.kind == ValueKind.Float) return nonFiniteText(v.f);
    for (let k = 0; k < v.n.length; k++) {
        const t = nonFiniteText(v.n[k]);
        if (t.length > 0) return t;
    }
    return "";
}

function nonFiniteText(x: f64): string {
    if (isFinite(<f32>x)) return "";
    return isFinite(x) ? printNumber(x) + ", too large for a material's 32-bit float" : printNumber(x);
}

// The message of an `enum-range` error for an Int value of an enum
// property outside 0 to count - 1, or of a property that is 0 or more (a
// UV set) below 0, or "" when the value is in range (or the property has
// no range). Shared with instancing (../tree/instance.as), which checks the
// properties of overrides against the class they land on.
export function enumRangeProblem(info: PropInfo, v: Value): string {
    if (info.nonNegative && v.kind == ValueKind.Int && v.i < 0) {
        return info.name + " is a UV set, 0 or more, found " + v.i.toString();
    }
    if (info.enumNames.length == 0 || v.kind != ValueKind.Int) return "";
    if (v.i >= 0 && v.i < <i64>info.enumNames.length) return "";
    const names = new Array<string>();
    for (let i = 0; i < info.enumNames.length; i++) names.push(i.toString() + " (" + info.enumNames[i] + ")");
    return info.name + " is " + orList(names) + ", found " + v.i.toString();
}

// The hint of a `property-resource-class` error whose resource is of a type
// this format version does not load.
export const UNUSABLE_HINT = "a resource of a type format 1 does not load is never usable";

// The message of a `property-resource-class` error: property `name` wants
// a `want`, the value `v` (an ExtResource or SubResource) names a resource
// of class `found`. Shared with the scene tree (../tree/node.as).
// A resource of the right class declared as an ext_resource when its class
// is only ever a sub_resource (a NavigationMesh, a BoxMesh) is said so.
export function resourceClassMessage(name: string, want: string, found: string, v: Value): string {
    const ref = (v.kind == ValueKind.ExtResource ? "ExtResource" : "SubResource") + "(\"" + v.s + "\")";
    if (subResourceAsExt(want, found, v)) return name + " must be " + withArticle(found) + " sub_resource, found " + ref;
    return name + " must be " + withArticle(want) + ", found " + found + " " + ref;
}

// The hint of such an error whose resource is of a type this format
// version does not load (UNUSABLE_HINT), or for a sub_resource class
// declared as an ext_resource, how to declare it instead.
export function unusableHint(want: string, found: string, v: Value): string {
    if (!subResourceAsExt(want, found, v)) return UNUSABLE_HINT;
    return "a " + found + " is written in the scene itself: declare it as <sub_resource type=\"" + found
        + "\" id=\"...\"> and name it SubResource(\"...\")";
}

// Whether `v` is an ExtResource naming a `found` that is the `want` asked
// for but a class only a sub_resource declares.
function subResourceAsExt(want: string, found: string, v: Value): bool {
    if (v.kind != ValueKind.ExtResource || !isA(found, want)) return false;
    const c = classInfo(found);
    return c != null && c.subResource && !c.extType;
}

// Why a node path (a parent, or a connection's end) is malformed, or ""
// when it is a well-formed path relative to the root: "." alone, or names
// separated by single slashes, with no "." or ".." segment and no "."
// inside a segment (no name holds one, so such a path could only ever
// fail later, and through an instance only at instancing).
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

const EMBEDDED_PATH_HINT = "an embedded file is named by its res:// path, such as res://models/bench.rmdl (no . or .. segment)";
const EMBEDDED_CONTENT_HINT = "pack the scene again (`" + CLI + " build <scene> --pack`) rather than editing its embedded files";

// Why an <embedded> path is not the res:// path of a file, or "". Stricter
// than an ext_resource's: no relative form and no "." or ".." segment, so
// that one file has one spelling and duplicates can be told.
export function embeddedPathProblem(path: string): string {
    if (!path.startsWith("res://")) return "embedded path \"" + path + "\" is not a res:// path";
    const rel = path.substring(6);
    if (rel.length == 0 || rel.endsWith("/")) return "embedded path \"" + path + "\" names a directory";
    if (rel.includes("\\")) return "embedded path \"" + path + "\" has a backslash";
    const segs = rel.split("/");
    for (let i = 0; i < segs.length; i++) {
        const seg = segs[i];
        if (seg.length == 0 || seg == "." || seg == "..") return "embedded path \"" + path + "\" has an empty, . or .. segment";
    }
    return "";
}

// The item of a Dictionary value under the String (or StringName) key
// `key`, or null (as ../resource/build.as dictionaryItem, which the
// validator does not import).
function dictionaryEntry(d: Value, key: string): Value? {
    if (d.kind != ValueKind.Dictionary) return null;
    for (let i = 0; i < d.keys.length && i < d.items.length; i++) {
        const k = d.keys[i];
        if ((k.kind == ValueKind.String || k.kind == ValueKind.StringName) && k.s == key) return d.items[i];
    }
    return null;
}

// Stable insertion sort by position (a handful of items per entry).
function sortByPosition(a: Array<Diagnostic>): void {
    for (let i = 1; i < a.length; i++) {
        const d = a[i];
        let j = i - 1;
        while (j >= 0 && (a[j].line > d.line || (a[j].line == d.line && a[j].col > d.col))) {
            a[j + 1] = a[j];
            j--;
        }
        a[j + 1] = d;
    }
}

// How a path resolves at file level (Validator.resolve).
enum Resolved {
    // Declared in this file: `index` is the node.
    Found,
    // Goes through an instanced node (`index`; the root when the root is
    // an instance): only instancing can tell.
    Deferred,
    // Neither: `index` is the deepest declared prefix, -1 for none.
    NotFound,
}

class Resolution {
    how: Resolved;
    index: i32;
    // The declared prefix's path ("" when none).
    prefix: string;

    constructor(how: Resolved, index: i32, prefix: string) {
        this.how = how;
        this.index = index;
        this.prefix = prefix;
    }
}

// --- the validator ---------------------------------------------------------------

class Validator {
    doc: RscnDoc;
    out: Diagnostics = new Diagnostics();
    // The current entry's problems, sorted by position when it is done.
    pending: Array<Diagnostic> = [];

    nodes: Array<NodeDecl> = [];
    // path() -> index of the first node declared with it (nodes that have
    // no parent but are not the root are left out: their path would be
    // the root's).
    byPath: Map<string, i32> = new Map<string, i32>();
    // Resource ids: the first declaration of each, and its sub_resource
    // ordinal (for subresource-order).
    exts: Map<string, ExtResourceDecl> = new Map<string, ExtResourceDecl>();
    subs: Map<string, SubResourceDecl> = new Map<string, SubResourceDecl>();
    subOrdinal: Map<string, i32> = new Map<string, i32>();

    // While checking: the node index or sub_resource ordinal (-1 outside).
    nodeAt: i32 = -1;
    subAt: i32 = -1;

    // Milestone 45: the timelines' checks (made at the first timeline: a
    // scene without any pays nothing).
    animChecker: AnimChecker? = null;
    // Milestone 46: the state machines' checks (made at the first one).
    smChecker: SmChecker? = null;

    constructor(doc: RscnDoc) {
        this.doc = doc;
    }

    anim(): AnimChecker {
        let c = this.animChecker;
        if (c == null) {
            c = new AnimChecker(this.doc, this.pending);
            this.animChecker = c;
        }
        return c;
    }

    sm(): SmChecker {
        let c = this.smChecker;
        if (c == null) {
            c = new SmChecker(this.doc, this.pending);
            this.smChecker = c;
        }
        return c;
    }

    run(): Diagnostics {
        this.collect();
        // A document made from another format (an .mtlx file) brings the
        // warnings its reader found, at the file's own positions.
        for (let i = 0; i < this.doc.warnings.length; i++) this.out.add(this.doc.warnings[i]);
        this.checkRoot();
        this.flush();
        const material = this.doc.kind == DocKind.Material;
        let nodeIndex = 0;
        let subIndex = 0;
        let firstResource: SubResourceDecl? = null;
        const seenIds = new Map<string, XmlPos>();
        const seenPaths = new Map<string, XmlPos>();
        const seenEmbedded = new Map<string, XmlPos>();
        const seenConverters = new Map<string, XmlPos>();
        for (let i = 0; i < this.doc.entries.length; i++) {
            const e = this.doc.entries[i];
            // A material file has no nodes, connections or embedded files:
            // the reader keeps such elements as unknown ones; a document
            // built in code with them gets the same warning.
            if (material && (e.kind == EntryKind.Node || e.kind == EntryKind.Connection || e.kind == EntryKind.Embedded)) {
                this.foreignEntry(e.kind, e.node, e.connection, e.embedded);
                this.flush();
                continue;
            }
            switch (e.kind) {
                case EntryKind.ExtResource:
                    this.checkExt(e.ext as ExtResourceDecl, seenIds);
                    break;
                case EntryKind.SubResource:
                    this.subAt = subIndex++;
                    this.checkSub(e.sub as SubResourceDecl, seenIds);
                    this.subAt = -1;
                    break;
                case EntryKind.Node:
                    this.nodeAt = nodeIndex++;
                    this.checkNode(e.node as NodeDecl, seenPaths);
                    this.nodeAt = -1;
                    break;
                case EntryKind.Connection:
                    this.checkConnection(e.connection as ConnectionDecl);
                    break;
                case EntryKind.Unknown:
                    this.unknownXml(e.xml, "");
                    break;
                case EntryKind.Embedded:
                    this.checkEmbedded(e.embedded as EmbeddedDecl, seenEmbedded);
                    break;
                case EntryKind.Converter:
                    this.checkConverter(e.converter as DataConverterDecl, seenConverters);
                    break;
                case EntryKind.Event:
                    this.anim().event(e.event as EventDecl);
                    break;
                case EntryKind.Animation:
                    this.anim().animation(e.animation as LinearAnimationDecl);
                    break;
                case EntryKind.StateMachine:
                    this.sm().stateMachine(e.stateMachine as StateMachineDecl);
                    break;
                case EntryKind.Resource: {
                    // Only a material file's (a scene's reader never makes
                    // one; a scene built in code with one gets nothing).
                    if (!material) break;
                    const d = e.res as SubResourceDecl;
                    this.checkResource(d, firstResource);
                    if (firstResource == null) firstResource = d;
                    break;
                }
                default:
                    break;
            }
            this.flush();
        }
        return this.out;
    }

    // --- format 2 (milestone 42)

    // A construct of format 2 in a file that says format 1.
    formatFeature(p: XmlPos, what: string): void {
        if (this.doc.format >= 2) return;
        this.error(p, "format-feature", what + " needs format 2: this file is format " + this.doc.format.toString(),
            FORMAT_FEATURE_HINT);
    }

    // A converter the scene declares: its name unique among the scene's
    // (the reader has checked it is there and not empty), no id.
    checkConverter(d: DataConverterDecl, seen: Map<string, XmlPos>): void {
        const at = new XmlPos(d.where.line, d.where.col);
        this.formatFeature(at, "the converter <" + d.type + " name=\"" + d.name + "\">");
        if (seen.has(d.name)) {
            this.error(at, "converter-duplicate", "converter \"" + d.name + "\" is declared twice" + firstAt(seen.get(d.name)),
                CONVERTER_DUPLICATE_HINT);
        } else {
            seen.set(d.name, at);
        }
        const id = d.attr("id");
        if (id != null) {
            this.warning(at, "attribute-unknown", "unknown attribute \"id\" on <" + d.type + ">", CONVERTER_ID_HINT);
        }
    }

    // --- reporting

    at(p: XmlPos, severity: Severity, code: string, message: string, hint: string?): void {
        this.pending.push(new Diagnostic(severity, code, this.doc.file, p.line, p.col, message, hint));
    }

    error(p: XmlPos, code: string, message: string, hint: string? = null): void {
        this.at(p, Severity.Error, code, message, hint);
    }

    warning(p: XmlPos, code: string, message: string, hint: string? = null): void {
        this.at(p, Severity.Warning, code, message, hint);
    }

    flush(): void {
        let known = true;
        for (let i = 0; i < this.pending.length; i++) if (this.pending[i].line <= 0) known = false;
        if (known) sortByPosition(this.pending);
        for (let i = 0; i < this.pending.length; i++) this.out.add(this.pending[i]);
        // (emptied in place: most entries have no problem, and a scene has
        // 10,000 of them)
        this.pending.length = 0;
    }

    // --- the declarations, before anything is checked (references may point
    // forward: a wrong order is its own problem)

    collect(): void {
        const entries = this.doc.entries;
        let ordinal = 0;
        for (let i = 0; i < entries.length; i++) {
            const ext = entries[i].ext;
            if (ext != null && !this.exts.has(ext.id)) this.exts.set(ext.id, ext);
            const sub = entries[i].sub;
            if (sub != null) {
                if (!this.subs.has(sub.id)) {
                    this.subs.set(sub.id, sub);
                    this.subOrdinal.set(sub.id, ordinal);
                }
                ordinal++;
            }
            const node = entries[i].node;
            if (node != null) {
                const index = this.nodes.length;
                this.nodes.push(node);
                if (index > 0 && node.parent == null) continue;
                const path = index == 0 ? "." : node.path();
                if (!this.byPath.has(path)) this.byPath.set(path, index);
            }
        }
    }

    // --- <rscn>

    checkRoot(): void {
        this.unknownAttrs(this.doc.rootAttrs, ROOT_ATTRS, this.doc.rootTag());
        if (this.doc.kind == DocKind.Material) {
            if (this.doc.resource() == null) {
                this.error(this.doc.pos, "resource-missing", "the material file has no <resource>", RESOURCE_MISSING_HINT);
            }
            return;
        }
        if (this.nodes.length == 0) {
            this.error(this.doc.pos, "root-missing", "the scene has no node",
                "the first <node> is the root: give it a name and a type, such as type=\"Node3D\"");
        }
    }

    // --- a material document's <resource> (milestone 14)

    // `first`: the file's first <resource>, when this is not it.
    checkResource(d: SubResourceDecl, first: SubResourceDecl?): void {
        this.unknownAttrs(d.attrs, RESOURCE_ATTRS, "resource");
        if (first != null) {
            this.error(d.pos, "resource-duplicate", "a second <resource>" + firstAt(first.pos) + ": a material file holds one",
                "remove one of them: only the first is built, the other is kept and written back");
        }
        const info = classInfo(d.type);
        let cls: string? = null;
        const classes = orList(materialClassNames());
        if (info == null) {
            this.warning(d.attrPos("type"), "resource-type-unknown", "unknown resource type \"" + d.type + "\"",
                "it is kept but not built, and the file cannot be used as a material; the material classes are " + classes);
        } else if (!isMaterialClass(d.type)) {
            this.error(d.attrPos("type"), "resource-type-invalid", d.type + " is not a material a file can hold",
                "a material file's resource is " + withArticle(classes) + " (the material classes are " + classes + ")");
        } else {
            cls = d.type;
        }
        this.checkBody(d, cls, false, "resource");
    }

    // A <node>, <connection> or <embedded> of a material file built in code.
    foreignEntry(kind: EntryKind, node: NodeDecl?, c: ConnectionDecl?, em: EmbeddedDecl?): void {
        let name = "embedded";
        let at = em != null ? em.pos : this.doc.pos;
        if (node != null) {
            name = "node";
            at = node.pos;
        } else if (c != null) {
            name = "connection";
            at = c.pos;
        }
        this.warning(at, "element-unknown", "unknown element <" + name + "> in a material file", KEPT_HINT);
    }

    unknownAttrs(attrs: Array<XmlAttr>, known: Array<string>, element: string): void {
        for (let i = 0; i < attrs.length; i++) {
            const a = attrs[i];
            if (known.includes(a.name)) continue;
            this.warning(a.pos.isKnown() ? a.pos : a.valuePos, "attribute-unknown",
                "unknown attribute \"" + a.name + "\" on <" + element + ">", KEPT_HINT);
        }
    }

    // An element or processing instruction this format version does not
    // know (`where` names the element it is in, "" at the top level).
    unknownXml(n: XmlNode?, where: string): void {
        if (n == null) return;
        const inside = where.length > 0 ? " in <" + where + ">" : "";
        if (n.kind == XmlKind.Element) {
            this.warning(n.pos, "element-unknown", "unknown element <" + n.name + ">" + inside, KEPT_HINT);
        } else if (n.kind == XmlKind.Pi) {
            this.warning(n.pos, "element-unknown", "unknown processing instruction <?" + n.name + "?>" + inside, KEPT_HINT);
        }
    }

    // --- resources

    checkId(id: string, p: XmlPos, kind: string, seenIds: Map<string, XmlPos>): void {
        const bad = idProblem(id, kind);
        if (bad.length > 0) this.error(p, "id-invalid", bad, ID_HINT);
        if (seenIds.has(id)) {
            this.error(p, "id-duplicate", "id \"" + id + "\" is already used" + firstAt(seenIds.get(id)),
                "ids are unique across ext_resources and sub_resources");
        } else {
            seenIds.set(id, p);
        }
    }

    checkExt(d: ExtResourceDecl, seenIds: Map<string, XmlPos>): void {
        this.unknownAttrs(d.attrs, EXT_ATTRS, "ext_resource");
        this.checkId(d.id, d.attrPos("id"), "ext_resource", seenIds);
        const info = classInfo(d.type);
        const types = extTypeNames();
        // (milestone 36: an Ogg sound is the runtime's limit, said as such,
        // in place of the type's or the extension's complaint)
        const ogg = isOggAudio(d.type, d.path);
        if (ogg) {
            this.error(d.attrPos("path"), "audio-format", d.path + " is Ogg, which the Rive runtime cannot decode",
                "convert it to WAV, MP3 or FLAC");
        } else if (info == null) {
            this.warning(d.attrPos("type"), "ext-type-unknown", "unknown ext_resource type \"" + d.type + "\"",
                "it is kept but not loaded; the ext_resource types are " + orList(types));
        } else if (!info.extType) {
            this.warning(d.attrPos("type"), "ext-type-unknown", d.type + " is not an ext_resource type",
                "it is kept but not loaded; the ext_resource types are " + orList(types));
        }
        const problem = resourcePathProblem(d.path, SCENE_PATHS);
        if (problem.length > 0) {
            this.error(d.attrPos("path"), "path-invalid", problem, PATH_HINT);
        } else if (!ogg && info != null && info.extType && !extTypeAccepts(d.type, pathExtensionOf(d.path))) {
            const exts = new Array<string>();
            for (let i = 0; i < info.extensions.length; i++) exts.push("." + info.extensions[i]);
            this.error(d.attrPos("path"), "ext-type-extension",
                withArticle(d.type) + " is a " + orList(exts) + " file, not \"" + d.path + "\"");
        }
        for (let i = 0; i < d.extraChildren.length; i++) this.unknownXml(d.extraChildren[i], "ext_resource");
    }

    checkSub(d: SubResourceDecl, seenIds: Map<string, XmlPos>): void {
        this.unknownAttrs(d.attrs, SUB_ATTRS, "sub_resource");
        this.checkId(d.id, d.attrPos("id"), "sub_resource", seenIds);
        const info = classInfo(d.type);
        let cls: string? = null;
        if (info == null) {
            this.warning(d.attrPos("type"), "sub-type-unknown", "unknown sub_resource type \"" + d.type + "\"",
                "it is kept but not built; the sub_resource types are " + orList(subResourceClassNames()));
        } else if (!info.subResource) {
            this.error(d.attrPos("type"), "sub-type-invalid", d.type + " cannot be a sub_resource",
                "the sub_resource types are " + orList(subResourceClassNames()));
        } else {
            cls = d.type;
        }
        this.checkBody(d, cls, false, "sub_resource");
        const feature = this.doc.format < 2 ? viewModelFormat2Feature(this.doc, d) : "";
        if (feature.length > 0) {
            const file = d.property("file");
            this.formatFeature(file != null ? file.pos : d.pos, feature);
        }
        if (cls != null) this.checkPrimitiveSize(d, cls);
        if (cls == "MultiMesh") this.checkMultiMesh(d);
        if (cls != null) this.checkShape(d, cls);
        if (cls == "Curve3D") this.checkCurve(d);
        if (cls == "Curve") this.checkParticleCurve(d);
        if (cls == "Gradient") this.checkGradientStops(d);
    }

    // The property of that name whose value the builder takes (the last
    // one of the type the class wants: ../resource/build.as and node.as
    // pass a value of the wrong type over, which property-type reported),
    // or null.
    typedProperty(d: Declaration, cls: string, name: string): Property? {
        const info = findProp(cls, name);
        if (info == null) return null;
        for (let i = d.items.length - 1; i >= 0; i--) {
            const p = d.items[i].property;
            if (p != null && p.name == name && info.accepts(p.value)) return p;
        }
        return null;
    }

    // Where a property's value is, else the element's position.
    valueAt(p: Property?, d: Declaration): XmlPos {
        if (p == null) return d.pos;
        return p.valuePos.isKnown() ? p.valuePos : p.pos;
    }

    // A MultiMesh's buffer holds instance_count instances of its stride
    // (RSCN.md, "MultiMesh"); a 2D one is not drawn.
    checkMultiMesh(d: SubResourceDecl): void {
        const fmt = this.typedProperty(d, "MultiMesh", "transform_format");
        const colors = this.typedProperty(d, "MultiMesh", "use_colors");
        const custom = this.typedProperty(d, "MultiMesh", "use_custom_data");
        const count = this.typedProperty(d, "MultiMesh", "instance_count");
        const buffer = this.typedProperty(d, "MultiMesh", "buffer");
        const is3d = fmt != null && fmt.value.i == 1;
        const useColors = colors != null && colors.value.b;
        const useCustom = custom != null && custom.value.b;
        const n: i64 = count != null ? count.value.i : 0;
        const have = buffer != null ? buffer.value.n.length : 0;
        const where = "MultiMesh \"" + d.id + "\"";
        if (!is3d && (fmt == null || fmt.value.i == 0)) {
            this.warning(this.valueAt(fmt, d), "multimesh-2d", where + " has transform_2d instances, which are not drawn",
                "write <property name=\"transform_format\">1</property> (transform_3d): Godot's default is 2D");
        }
        if (n < 0) {
            this.error(this.valueAt(count, d), "multimesh-instance-count", where + ": instance_count is " + n.toString(),
                "instance_count is how many instances the buffer holds: 0 or more");
            return;
        }
        const stride = multiMeshStride(is3d, useColors, useCustom);
        const want = n * <i64>stride;
        if (<i64>have == want) return;
        let flags = "";
        if (useColors && useCustom) flags = " with use_colors and use_custom_data";
        else if (useColors) flags = " with use_colors";
        else if (useCustom) flags = " with use_custom_data";
        this.error(this.valueAt(buffer != null ? buffer : count, d), "multimesh-buffer-size",
            where + ": buffer holds " + have.toString() + (have == 1 ? " number" : " numbers") + "; instance_count "
                + n.toString() + flags + " needs " + want.toString() + " (" + stride.toString() + " an instance)",
            MULTIMESH_STRIDE_HINT);
    }

    // Milestone 31: a collision shape that holds less than it says
    // (RSCN.md, "Interaction"). A ConcavePolygonShape3D's data is nine
    // numbers a triangle: a trailing part (three or six numbers, as a
    // PackedVector3Array holds whole points) is left out (`shape-data`). A
    // box with a negative side or every side 0, or a sphere, capsule or cylinder whose
    // radius or height is 0 or less, is empty: nothing overlaps it and no
    // ray meets it (`shape-size`). Warnings, at the property's value: the
    // scene still loads and draws, as Godot's does.
    checkShape(d: SubResourceDecl, cls: string): void {
        if (cls == "ConcavePolygonShape3D") {
            const data = this.typedProperty(d, cls, "data");
            if (data == null) return;
            const n = data.value.n.length;
            const left = n % 9;
            if (left == 0) return;
            this.warning(this.valueAt(data, d), "shape-data",
                "data holds " + n.toString() + " numbers: the last " + left.toString() + " make no whole triangle and are left out",
                SHAPE_DATA_HINT);
            return;
        }
        if (cls == "BoxShape3D") {
            const size = this.typedProperty(d, cls, "size");
            if (size == null) return;
            const v = size.value.n;
            for (let k = 0; k < v.length; k++) {
                if (v[k] >= 0) continue;
                this.warning(this.valueAt(size, d), "shape-size",
                    "BoxShape3D size must not be negative (" + AXES[k] + " is " + printNumber(v[k]) + "): " + SHAPE_EMPTY,
                    SHAPE_SIZE_HINT);
                return;
            }
            // (a flat box, one or two sides 0, is a plane or a line Godot
            // casts; with no extent at all it holds nothing)
            if (v.length == 3 && v[0] == 0 && v[1] == 0 && v[2] == 0) {
                this.warning(this.valueAt(size, d), "shape-size",
                    "BoxShape3D size must not be 0 on every side: " + SHAPE_EMPTY, SHAPE_SIZE_HINT);
            }
            return;
        }
        let names: Array<string>;
        if (cls == "SphereShape3D") names = SPHERE_SIZES;
        else if (cls == "CapsuleShape3D" || cls == "CylinderShape3D") names = RADIUS_HEIGHT;
        else return;
        for (let k = 0; k < names.length; k++) {
            const p = this.typedProperty(d, cls, names[k]);
            if (p == null) continue;
            const x = p.value.kind == ValueKind.Int ? <f64>p.value.i : p.value.f;
            if (x > 0) continue;
            this.warning(this.valueAt(p, d), "shape-size",
                cls + " " + names[k] + " must be more than 0: " + SHAPE_EMPTY,
                names[k] + " is " + printNumber(x) + " here; " + SHAPE_SIZE_HINT);
        }
    }

    // Milestone 32: a Curve3D that holds less, or other, than it says
    // (RSCN.md, "Paths"). Its properties are read in file order, as the
    // builder sets them (../resource/build.as setCurveField, Godot's
    // loader): each `_data` must hold "points", a PackedVector3Array of
    // nine numbers a point, and "tilts", a PackedFloat32Array of one a
    // point (`curve-data`: a malformed one leaves the points as they were;
    // a tilt short is 0, one over is left out); a `point_count` that is not
    // the number of points the curve holds by then resizes it, dropping
    // the last ones or adding new ones at the origin (`curve-point-count`;
    // not said of one a later, well-formed `_data` replaces); a
    // `bake_interval` of 0 or less cuts every segment to the bake's depth
    // (`curve-bake-interval`). Warnings, at the property's value: the scene
    // still loads, as Godot's does.
    checkCurve(d: SubResourceDecl): void {
        const cls = "Curve3D";
        const items = d.items;
        let count = 0;
        for (let i = 0; i < items.length; i++) {
            const p = items[i].property;
            if (p == null) continue;
            const info = findProp(cls, p.name);
            if (info == null || !info.accepts(p.value)) continue;
            if (p.name == "_data") {
                const held = this.curveDataPoints(p, d);
                if (held >= 0) count = held;
            } else if (p.name == "point_count") {
                const n = p.value.i;
                if (n < 0 || n == <i64>count || this.laterCurveData(items, i)) {
                    if (n >= 0) count = <i32>n;
                    continue;
                }
                this.warning(this.valueAt(p, d), "curve-point-count",
                    "point_count is " + n.toString() + " but _data holds " + count.toString() + (count == 1 ? " point" : " points")
                        + ": the curve gets " + n.toString() + ", " + (n < <i64>count ? "the last ones dropped" : "the new ones at the origin"),
                    CURVE_POINT_COUNT_HINT);
                count = <i32>n;
            } else if (p.name == "bake_interval") {
                const x = p.value.kind == ValueKind.Int ? <f64>p.value.i : p.value.f;
                if (x > 0) continue;
                this.warning(this.valueAt(p, d), "curve-bake-interval",
                    "Curve3D bake_interval " + printNumber(x) + " is not more than 0: every segment is cut 10 times over, into 1,024 baked pieces",
                    CURVE_BAKE_INTERVAL_HINT);
            }
        }
    }

    // Milestone 35: a Curve's `_data` (RSCN.md, "Particles") is five items
    // a point, Godot's: Vector2(offset, value), left_tangent and
    // right_tangent (numbers), left_mode and right_mode (ints). The builder
    // reads the properties in file order (../resource/build.as
    // setParticleCurveField, Godot's loader): `_data` keeps each whole five
    // whose first is a Vector2 and the rest numbers and leaves out the rest
    // (../resource/curve.as setData); a later `point_count` then drops the
    // last points or adds new ones at (0, 0) (Godot's set_point_count). The
    // warning (`curve-points`, at the value) says what the curve ends with
    // when either leaves it other than the file's points.
    checkParticleCurve(d: SubResourceDecl): void {
        const items = d.items;
        let count = 0;
        let dataAt: Property? = null;
        let problem = "";
        for (let i = 0; i < items.length; i++) {
            const p = items[i].property;
            if (p == null) continue;
            const info = findProp("Curve", p.name);
            if (info == null || !info.accepts(p.value)) continue;
            if (p.name == "_data" && p.value.kind == ValueKind.Array) {
                const vs = p.value.items;
                const n = vs.length;
                let kept = 0;
                let wrong = n % CURVE_DATA_STRIDE != 0;
                for (let k = 0; k + CURVE_DATA_STRIDE <= n; k += CURVE_DATA_STRIDE) {
                    const reads = vs[k].kind == ValueKind.Vector2 && vs[k + 1].isNumber() && vs[k + 2].isNumber()
                        && vs[k + 3].isNumber() && vs[k + 4].isNumber();
                    if (reads) kept++;
                    if (!reads || vs[k + 3].kind != ValueKind.Int || vs[k + 4].kind != ValueKind.Int) wrong = true;
                }
                count = kept;
                dataAt = p;
                problem = wrong
                    ? "Curve \"" + d.id + "\" _data holds " + n.toString() + (n == 1 ? " item" : " items")
                        + ", not five a point of Vector2, number, number, int, int: the curve keeps "
                        + kept.toString() + (kept == 1 ? " point" : " points")
                    : "";
            } else if (p.name == "point_count") {
                const want = p.value.i < 0 ? 0 : <i32>p.value.i;
                if (want == count) continue;
                const was = count;
                count = want;
                const then = "point_count " + want.toString() + " then makes it " + want.toString()
                    + (want < was ? ", the last ones dropped" : ", the new ones at (0, 0)");
                if (problem.length > 0) {
                    problem += "; " + then;
                } else {
                    problem = "Curve \"" + d.id + "\" _data holds " + was.toString() + (was == 1 ? " point" : " points") + ": " + then;
                    if (dataAt == null) dataAt = p;
                }
            }
        }
        if (problem.length == 0) return;
        this.warning(this.valueAt(dataAt, d), "curve-points", problem, PARTICLE_CURVE_HINT);
    }

    // Milestone 35: a Gradient's stops pair `offsets` with `colors` (four
    // numbers a colour); more of one than of the other leaves the extra
    // out (`gradient-stops`, at the later of the two values; Godot keeps as
    // many stops as the property set last).
    checkGradientStops(d: SubResourceDecl): void {
        const offs = this.typedProperty(d, "Gradient", "offsets");
        const cols = this.typedProperty(d, "Gradient", "colors");
        if (offs == null && cols == null) return;
        const no = offs != null ? offs.value.n.length : 2;
        const nc = cols != null ? cols.value.n.length / 4 : 2;
        if (no == nc) return;
        let at = offs != null ? offs : cols;
        if (offs != null && cols != null && cols.pos.line > offs.pos.line) at = cols;
        const kept = no < nc ? no : nc;
        this.warning(this.valueAt(at, d), "gradient-stops",
            "Gradient \"" + d.id + "\" has " + no.toString() + (no == 1 ? " offset" : " offsets") + " and "
                + nc.toString() + (nc == 1 ? " colour" : " colours") + ": it keeps " + kept.toString()
                + (kept == 1 ? " stop" : " stops") + ", the extra " + (no > nc ? "offsets" : "colours") + " left out",
            GRADIENT_STOPS_HINT);
    }

    // The number of points a Curve3D's `_data` property gives the curve
    // (-1: none, it is malformed), warning `curve-data` about what is
    // wrong with it.
    curveDataPoints(p: Property, d: SubResourceDecl): i32 {
        const pts = dictionaryEntry(p.value, "points");
        const tilts = dictionaryEntry(p.value, "tilts");
        const at = this.valueAt(p, d);
        if (pts == null || tilts == null || pts.kind != ValueKind.PackedVector3Array || tilts.kind != ValueKind.PackedFloat32Array) {
            this.warning(at, "curve-data",
                "Curve3D _data needs \"points\", a PackedVector3Array, and \"tilts\", a PackedFloat32Array: the curve keeps no points from it",
                CURVE_DATA_HINT);
            return -1;
        }
        const n = pts.n.length;
        if (n % CURVE_POINT_STRIDE != 0) {
            this.warning(at, "curve-data",
                "_data's points hold " + n.toString() + (n == 1 ? " number" : " numbers")
                    + ": a point is nine (its in handle, out handle and position), so the curve keeps none of them",
                CURVE_DATA_HINT);
            return -1;
        }
        const count = n / CURVE_POINT_STRIDE;
        const t = tilts.n.length;
        if (t != count) {
            this.warning(at, "curve-data",
                "_data holds " + count.toString() + (count == 1 ? " point" : " points") + " and " + t.toString()
                    + (t == 1 ? " tilt" : " tilts") + ": a missing tilt is 0, an extra one is left out",
                CURVE_DATA_HINT);
        }
        return count;
    }

    // Whether a well-formed `_data` comes after the item at `from`.
    laterCurveData(items: Array<BodyItem>, from: i32): bool {
        for (let i = from + 1; i < items.length; i++) {
            const p = items[i].property;
            if (p == null || p.name != "_data") continue;
            const pts = dictionaryEntry(p.value, "points");
            const tilts = dictionaryEntry(p.value, "tilts");
            if (pts != null && tilts != null && pts.kind == ValueKind.PackedVector3Array && tilts.kind == ValueKind.PackedFloat32Array
                && pts.n.length % CURVE_POINT_STRIDE == 0) return true;
        }
        return false;
    }

    // A built-in mesh must stay within PRIMITIVE_VERTEX_LIMIT: its fields
    // are set as the builder sets them (the last of a duplicated property
    // wins, a value of the wrong type is passed over), so the two agree.
    checkPrimitiveSize(d: SubResourceDecl, cls: string): void {
        const m = newPrimitive(cls);
        if (m == null) return;
        const props = d.properties();
        for (let i = 0; i < props.length; i++) {
            const p = props[i];
            const info = findProp(cls, p.name);
            if (info != null && info.type != PropType.Resource && info.accepts(p.value)) setPrimitiveField(m, p.name, p.value);
        }
        if (m.tooLarge()) this.error(d.pos, "primitive-too-large", tooLargeMessage(m, d.id), tooLargeHint(m));
    }

    // --- nodes

    checkNode(d: NodeDecl, seenPaths: Map<string, XmlPos>): void {
        const index = this.nodeAt;
        const isRoot = index == 0;
        this.unknownAttrs(d.attrs, NODE_ATTRS, "node");

        // Name.
        if (d.name.length == 0) {
            this.error(d.attrPos("name"), "name-invalid", "the node name is empty", NAME_HINT);
        } else {
            const c = forbiddenChar(d.name);
            if (c.length > 0) this.error(d.attrPos("name"), "name-invalid", "node name \"" + d.name + "\" holds \"" + c + "\"", NAME_HINT);
        }

        // Type and instance.
        const type = d.type;
        const instance = d.instance;
        if (type != null && instance != null) {
            this.error(d.attrPos("type"), "node-type-and-instance", "node \"" + d.name + "\" has both type and instance",
                "an instanced scene's root keeps its own class: remove type");
        }
        if (isRoot && type == null && instance == null) {
            this.error(d.pos, "node-type-missing", "the root node \"" + d.name + "\" has neither type nor instance",
                "give it a type, such as type=\"Node3D\", or instance a scene");
        }
        // The class whose properties this node's are checked against: a
        // known node class, else only Node's own (every node is a Node).
        let cls: string? = null;
        let checkProps = true;
        if (type != null && instance == null) {
            const info = classInfo(type);
            if (info == null) {
                this.warning(d.attrPos("type"), "type-unknown", "unknown node type \"" + type + "\"",
                    "it is kept and written back; the node classes are " + orList(nodeClassNames()));
            } else if (!info.isNode) {
                this.error(d.attrPos("type"), "type-not-node", type + " is a resource class, not a node class",
                    "declare it as a sub_resource or ext_resource and name it from a node's property");
                checkProps = false;
            } else {
                if (info.isAbstract) {
                    this.error(d.attrPos("type"), "type-abstract", type + " is an abstract class",
                        "use one of " + orList(concreteNodeClasses(type)));
                }
                cls = type;
            }
        }
        if (instance != null) this.checkInstance(d, instance);

        // Parent.
        const parent = d.parent;
        if (isRoot) {
            if (parent != null) {
                this.error(d.attrPos("parent"), "root-parent", "the root node \"" + d.name + "\" has a parent",
                    "the first node is the root: remove its parent, or declare the root before it");
            }
        } else if (parent == null) {
            this.error(d.pos, "parent-missing", "node \"" + d.name + "\" has no parent",
                "only the first node is the root: give this one parent=\".\" (the root) or a path from the root");
        } else {
            const problem = pathProblem(parent);
            if (problem.length > 0) {
                this.error(d.attrPos("parent"), "parent-invalid", "parent \"" + parent + "\" is not a node path: " + problem, PARENT_HINT);
            } else {
                this.checkParent(d, parent, index);
            }
            if (type == null && instance == null && this.overrideOutside(parent)) {
                this.error(d.pos, "override-outside-instance",
                    "node \"" + d.path() + "\" has no type and is not inside an instanced scene",
                    "give it a type; only a node inside an instanced scene is named without one, to override it");
            }
        }

        // Duplicates (only nodes whose path means something).
        if (isRoot || parent != null) {
            const path = isRoot ? "." : d.path();
            if (seenPaths.has(path)) {
                this.error(d.attrPos("name"), "name-duplicate", "node \"" + path + "\" is declared twice" + firstAt(seenPaths.get(path)),
                    "sibling nodes need distinct names");
            } else {
                seenPaths.set(path, d.attrPos("name"));
            }
        }

        this.checkBody(d, cls, checkProps, "node");
        this.checkBindings(d, cls, type != null);
        if (cls != null && isA(cls, "GeometryInstance3D")) this.checkVisibilityRange(d, cls);
    }

    // A geometry node's visibility range (RSCN.md, "Visibility ranges"):
    // an end below its begin draws nothing, and a negative margin is drawn
    // as 0. Both are drawn as they say, so both are warnings. Without a
    // fade, an end below the begin is never drawn; a fade mode draws the
    // wide range every frame (begin - margin to end + margin), which the
    // margins can open even then, so the warning waits for that to be
    // empty too. Only an end below the begin is warned of, as RSCN.md
    // defines the warning: without a fade, margins wide enough to cross
    // (begin 10 and end 12, both margins 3) also leave the narrow range
    // (begin + margin to end - margin), where drawing starts, empty, so
    // such a node is never drawn either, with no warning.
    checkVisibilityRange(d: NodeDecl, cls: string): void {
        const begin = this.typedProperty(d, cls, "visibility_range_begin");
        const end = this.typedProperty(d, cls, "visibility_range_end");
        const b = begin != null ? begin.value.asF64() : 0;
        const e = end != null ? end.value.asF64() : 0;
        let empty = e > 0 && e < b;
        const fade = this.typedProperty(d, cls, "visibility_range_fade_mode");
        if (empty && fade != null && fade.value.asI64() != 0) {
            const bm = this.typedProperty(d, cls, "visibility_range_begin_margin");
            const em = this.typedProperty(d, cls, "visibility_range_end_margin");
            const bmv = bm != null ? max<f64>(bm.value.asF64(), 0) : 0;
            const emv = em != null ? max<f64>(em.value.asF64(), 0) : 0;
            empty = e + emv < b - bmv;
        }
        if (empty) {
            this.warning(this.valueAt(end, d), "visibility-range-empty",
                "visibility_range_end " + printNumber(e) + " is below visibility_range_begin " + printNumber(b)
                    + ": node \"" + d.name + "\" is never drawn",
                "visibility_range_end is the distance where drawing stops: make it larger than visibility_range_begin, or 0 for no limit");
        }
        for (let k = 0; k < RANGE_MARGINS.length; k++) {
            const m = this.typedProperty(d, cls, RANGE_MARGINS[k]);
            if (m == null) continue;
            const v = m.value.asF64();
            if (!(v < 0)) continue;
            this.warning(this.valueAt(m, d), "visibility-range-margin", RANGE_MARGINS[k] + " is " + printNumber(v) + ": it is drawn as 0",
                "a margin is a distance, 0 or more: how far past the range's edge the change waits");
        }
    }

    checkInstance(d: NodeDecl, v: Value): void {
        const p = d.attrPos("instance");
        if (v.kind != ValueKind.ExtResource) {
            this.error(p, "instance-invalid", "instance must be ExtResource(\"id\"), found " + foundText(v),
                "instance names an ext_resource of type PackedScene");
            return;
        }
        if (!this.exts.has(v.s)) {
            this.undeclared(v, p);
            return;
        }
        const ext = this.exts.get(v.s);
        if (ext.type != "PackedScene") {
            this.error(p, "instance-invalid", "instance names ext_resource \"" + v.s + "\" of type " + ext.type + ", not PackedScene",
                "declare the file with type=\"PackedScene\" to instance it");
        }
    }

    // Whether node `i` lets a path go on below it without declaring the
    // rest: an instanced node, or an override of a node inside one.
    defers(i: i32): bool {
        const n = this.nodes[i];
        if (n.instance != null) return true;
        return i > 0 && n.type == null && n.parent != null;
    }

    // A well-formed path at file level (RSCN.md, "Node paths").
    resolve(path: string): Resolution {
        if (this.nodes.length == 0) return new Resolution(Resolved.NotFound, -1, "");
        if (path == ".") return new Resolution(Resolved.Found, 0, ".");
        if (this.byPath.has(path)) return new Resolution(Resolved.Found, this.byPath.get(path), path);
        const segs = path.split("/");
        for (let k = segs.length - 1; k >= 1; k--) {
            const prefix = segs.slice(0, k).join("/");
            if (this.byPath.has(prefix)) {
                const j = this.byPath.get(prefix);
                return new Resolution(this.defers(j) ? Resolved.Deferred : Resolved.NotFound, j, prefix);
            }
        }
        // The root is a prefix of every path: an inherited scene (a root
        // with instance) has children this file does not declare.
        return new Resolution(this.defers(0) ? Resolved.Deferred : Resolved.NotFound, this.defers(0) ? 0 : -1, this.defers(0) ? "." : "");
    }

    checkParent(d: NodeDecl, parent: string, index: i32): void {
        const p = d.attrPos("parent");
        const r = this.resolve(parent);
        if (r.how == Resolved.NotFound) {
            this.error(p, "parent-not-found", "parent \"" + parent + "\" not found" + this.missingDetail(parent, r), this.pathHint(parent));
            return;
        }
        if (r.index > index) {
            const at = lineOf(this.nodes[r.index].pos);
            if (r.how == Resolved.Found) {
                this.error(p, "parent-order", "parent \"" + parent + "\" is declared after this node" + at, "declare a parent before its children");
            } else {
                this.error(p, "parent-order", "\"" + r.prefix + "\", in parent \"" + parent + "\", is declared after this node" + at,
                    "declare a parent before its children");
            }
        }
    }

    // " (\"A\" has no child \"B\" in this file)" when a proper prefix is
    // declared, else "".
    missingDetail(path: string, r: Resolution): string {
        if (r.index < 0 || r.prefix.length == 0 || r.prefix == ".") return "";
        const rest = path.substring(r.prefix.length + 1);
        const slash = rest.indexOf("/");
        const child = slash >= 0 ? rest.substring(0, slash) : rest;
        return " (\"" + r.prefix + "\" has no child \"" + child + "\" in this file)";
    }

    // A path that starts with the root's own name is a common slip: say so.
    pathHint(path: string): string {
        if (this.nodes.length > 0) {
            const rootName = this.nodes[0].name;
            if (rootName.length > 0 && (path == rootName || path.startsWith(rootName + "/"))) {
                const rest = path == rootName ? "." : path.substring(rootName.length + 1);
                return "paths start below the root: write \"" + rest + "\" rather than \"" + path + "\"";
            }
        }
        return PARENT_HINT;
    }

    // An override node (no type, no instance) whose parent is declared in
    // this file and not inside an instanced scene: it names nothing to
    // override. (A parent that cannot be found is its own problem.)
    overrideOutside(parent: string): bool {
        if (pathProblem(parent).length > 0) return false;
        const r = this.resolve(parent);
        if (r.how != Resolved.Found) return false;
        return !this.defers(r.index);
    }

    // --- bodies (nodes and sub_resources)

    // `cls`: the class to check properties against (null: none, and then
    // Node's own properties are checked on a node when `nodeProps`).
    checkBody(d: Declaration, cls: string?, nodeProps: bool, element: string): void {
        for (let i = 0; i < d.items.length; i++) {
            const item = d.items[i];
            switch (item.kind) {
                case BodyKind.Property:
                    this.checkProperty(item.property as Property, cls, nodeProps && element == "node", element, d, i);
                    break;
                case BodyKind.Group:
                    this.checkGroup(item, element);
                    break;
                case BodyKind.Unknown:
                    this.unknownXml(item.xml, element);
                    break;
                case BodyKind.Binding:
                    // A node's are checked by checkBindings, which knows
                    // the node's class.
                    if (element != "node") this.misplacedBinding(item.binding as BindingDecl, element);
                    break;
                default:
                    break;
            }
        }
    }

    checkGroup(item: BodyItem, element: string): void {
        if (element != "node") {
            this.warning(item.groupPos, "element-unknown", "a " + element + " has no groups: <group name=\"" + item.group + "\"> is ignored", KEPT_HINT);
            return;
        }
        this.unknownAttrs(item.groupExtraAttrs, NAME_ATTRS, "group");
        if (item.group.length == 0) {
            this.error(item.groupPos, "group-invalid", "the group name is empty", "name the group, as in <group name=\"props\"/>");
        }
    }

    // `at`: the property's index in `d.items`, whose earlier properties are
    // the ones it may duplicate (a body holds a handful: a scan of them
    // costs less than a map per declaration).
    checkProperty(p: Property, cls: string?, nodeProps: bool, element: string, d: Declaration, at: i32): void {
        this.unknownAttrs(p.extraAttrs, NAME_ATTRS, "property");
        for (let k = 0; k < at; k++) {
            const q = d.items[k].property;
            if (q != null && q.name == p.name) {
                this.error(p.pos, "property-duplicate", "property \"" + p.name + "\" is set twice" + firstAt(q.pos),
                    "keep one of them");
                break;
            }
        }
        const vp = p.valuePos.isKnown() ? p.valuePos : p.pos;
        // References anywhere in the value.
        this.references(p.value, vp);

        let info: PropInfo? = null;
        if (cls != null) {
            info = findProp(cls, p.name);
            if (info == null) {
                this.warning(p.pos, "property-unknown", cls + " has no property \"" + p.name + "\"", KEPT_HINT);
                return;
            }
        } else if (nodeProps) {
            // An instanced node, an override or an unknown type: its class
            // is not known here, but every node is a Node.
            info = findProp("Node", p.name);
        }
        // (milestone 47: a listener's node property, as formatNeeded tells
        // it, whether or not the class here knows it)
        if (element == "node" && isListenerNodeProperty(p.name, (d as NodeDecl).type)) this.formatFeature(p.pos, p.name);
        if (info == null) return;
        if (info.output) {
            this.error(p.pos, "property-output", info.name + " is computed: bind it with mode=\"to_source\" to read it",
                PROPERTY_OUTPUT_HINT);
            return;
        }
        // (milestone 32: progress_ratio is progress over the curve's length,
        // never stored: the loader ignores it, as Godot's does)
        if (info.derived) {
            this.warning(p.pos, "property-derived", info.name + " is not stored: the value is ignored",
                PROPERTY_DERIVED_HINT);
            return;
        }
        this.checkValue(info, p.value, vp);
        if (element == "node" && p.name == "data_path") {
            const n = d as NodeDecl;
            this.formatFeature(p.pos, "data_path");
            if (n.instance == null && n.type != null) {
                this.warning(p.pos, "data-path-misplaced", "node \"" + n.path() + "\" instances no scene: its data_path is ignored",
                    DATA_PATH_HINT);
            }
        }
        if (element == "node" && p.name != "data_path" && isFormat2NodeProperty(p.name)) {
            checkStateMachineProperty(this.doc, d as NodeDecl, this.nodeAt == 0, p, this.pending);
        }
        if (nodeProps && this.nodeAt > 0 && p.name == "view_model") {
            const root = this.nodes.length > 0 ? this.nodes[0].name : "";
            this.warning(p.pos, "view-model-not-root", "node \"" + (d as NodeDecl).path() + "\" sets view_model, which only the root \""
                + root + "\" may: it is ignored", VIEW_MODEL_ROOT_HINT);
        }
    }

    // --- bindings (milestone 17)

    // A <binding> in a sub_resource or a material document's <resource>:
    // only nodes have bindings.
    misplacedBinding(b: BindingDecl, element: string): void {
        this.error(b.pos, "binding-misplaced", "a " + element + " has no bindings: <binding property=\"" + b.property + "\"> is ignored",
            "bind a node's property instead: a material's colour through the node, as material_override:albedo_color");
    }

    // A node's bindings: their own attributes (../binding/binding.as
    // readBindingDecl), then what depends on the node: a typed node's path
    // is not empty (only an override removes a binding), its property is a
    // target of its class, a conversion applies to a Number target only,
    // and one declaration binds a property once. `cls`: the node's known
    // class, null for an override, an instanced node or an unknown type,
    // whose targets the binder (../binding/binder.as) checks once the class
    // is known; `typed`: the node has a type.
    checkBindings(d: NodeDecl, cls: string?, typed: bool): void {
        const problems = new Array<BindingProblem>();
        for (let i = 0; i < d.items.length; i++) {
            const b = d.items[i].binding;
            if (b == null) continue;
            this.unknownAttrs(b.attrs, BINDING_ATTRS, "binding");
            for (let k = 0; k < i; k++) {
                const q = d.items[k].binding;
                if (q != null && q.property == b.property) {
                    this.error(b.attrPos("property"), "binding-duplicate", "property \"" + b.property + "\" is bound twice" + firstAt(q.pos),
                        "keep one of them: a declaration binds a property once");
                    break;
                }
            }
            // (only a format-1 file can misuse format 2)
            const feature = this.doc.format < 2 ? bindingFormat2Feature(b) : "";
            if (feature.length > 0) this.formatFeature(b.attrPos(featureAttr(feature)), feature);
            const target = cls != null ? findBindingTarget(cls, b.property) : null;
            if (cls != null && target == null) this.unknownTarget(b, cls);
            if (target != null) this.checkConversion(b, target);
            problems.length = 0;
            readBindingDecl(b, this.doc.file, problems);
            for (let k = 0; k < problems.length; k++) {
                const pr = problems[k];
                // A scale of 0 on a boolean or colour target is already a
                // conversion it takes none of (checkConversion).
                if (pr.code == "binding-scale" && target != null && target.kind != BindKind.Number) continue;
                this.error(b.attrPos(pr.attr), pr.code, pr.message, pr.hint);
            }
            if (b.path.length == 0 && typed) {
                this.error(b.attrPos("path"), "binding-path", "the binding of \"" + b.property + "\" has an empty path",
                    "an empty path removes an inherited binding, in an override (a node without type) only; " + BINDING_PATH_HINT);
            }
        }
    }

    unknownTarget(b: BindingDecl, cls: string): void {
        const list = targetList(cls, b.property);
        let message = cls + " has no binding target \"" + b.property + "\"";
        const owner = targetOwner(b.property);
        if (owner.length > 0) message += " (" + b.property + " is " + withArticle(owner) + "'s)";
        message += list.length > 0 ? "; its targets are " + list : "; it has no binding targets";
        this.error(b.attrPos("property"), "binding-property", message, BINDING_PROPERTY_HINT);
    }

    // scale, offset and convert convert numbers: on a Boolean or Color
    // target each one written is an error, at the attribute.
    checkConversion(b: BindingDecl, target: BindingTarget): void {
        if (target.kind == BindKind.Number) return;
        // A signal binding's conversions are refused by readBindingDecl
        // (binding-conversion, worded for a signal): one error each.
        if (target.kind == BindKind.Trigger) return;
        const attrs = ["scale", "offset", "convert"];
        const values = [b.scale, b.offset, b.convert];
        for (let k = 0; k < attrs.length; k++) {
            if (values[k].length == 0) continue;
            this.error(b.attrPos(attrs[k]), "binding-conversion",
                b.property + " is " + withArticle(kindWord(target.kind)) + " target: it takes no " + attrs[k],
                BINDING_CONVERSION_HINT);
        }
    }

    checkValue(info: PropInfo, v: Value, p: XmlPos): void {
        if (!info.accepts(v)) {
            this.error(p, "property-type", info.name + " is " + withArticle(info.typeText()) + ", found " + foundText(v));
            return;
        }
        if (info.type == PropType.Resource && v.isResource()) this.checkResourceClass(info, v, p);
        const range = enumRangeProblem(info, v);
        if (range.length > 0) this.error(p, "enum-range", range);
        // A scene may hold inf and nan; a material document becomes an
        // .mtlx file, whose numbers are plain decimals, so they could be
        // written but never read back: refused here, naming the property,
        // rather than by the reader of the text written.
        if (this.doc.kind == DocKind.Material) {
            const bad = firstNonFinite(v);
            if (bad.length > 0) {
                this.error(p, "value-not-finite", info.name + " holds " + bad + "; a material file holds finite numbers only",
                    "give it a finite number, or leave " + info.name + " out for its default");
            }
        }
    }

    // A resource value of a declared id: its declared class must be the
    // property's (an undeclared id was reported by `references`).
    checkResourceClass(info: PropInfo, v: Value, p: XmlPos): void {
        const want = info.resourceClass;
        let declared = "";
        let usable = false;
        if (v.kind == ValueKind.ExtResource) {
            if (!this.exts.has(v.s)) return;
            declared = this.exts.get(v.s).type;
            const c = classInfo(declared);
            usable = c != null && c.extType;
        } else {
            if (!this.subs.has(v.s)) return;
            declared = this.subs.get(v.s).type;
            const c = classInfo(declared);
            usable = c != null && c.subResource;
        }
        if (usable && isA(declared, want)) return;
        this.error(p, "property-resource-class", resourceClassMessage(info.name, want, declared, v),
            usable ? null : unusableHint(want, declared, v));
    }

    // Every ExtResource and SubResource in a value (arrays and dictionaries
    // walked) names a declaration, and a sub_resource names only earlier
    // sub_resources.
    references(v: Value, p: XmlPos): void {
        if (v.kind == ValueKind.Array || v.kind == ValueKind.Dictionary) {
            for (let i = 0; i < v.keys.length; i++) this.references(v.keys[i], p);
            for (let i = 0; i < v.items.length; i++) this.references(v.items[i], p);
            return;
        }
        if (v.kind == ValueKind.ExtResource) {
            if (!this.exts.has(v.s)) this.undeclared(v, p);
            return;
        }
        if (v.kind == ValueKind.SubResource) {
            if (!this.subs.has(v.s)) {
                this.undeclared(v, p);
                return;
            }
            if (this.subAt >= 0) {
                const other = this.subOrdinal.get(v.s);
                if (other == this.subAt) {
                    this.error(p, "subresource-order", "sub_resource \"" + v.s + "\" refers to itself");
                } else if (other > this.subAt) {
                    this.error(p, "subresource-order",
                        "sub_resource \"" + v.s + "\" is declared after the sub_resource that uses it" + lineOf(this.subs.get(v.s).pos),
                        "declare a sub_resource before the ones that use it");
                }
            }
        }
    }

    undeclared(v: Value, p: XmlPos): void {
        const isExt = v.kind == ValueKind.ExtResource;
        const kind = isExt ? "ext_resource" : "sub_resource";
        const otherHas = isExt ? this.subs.has(v.s) : this.exts.has(v.s);
        if (otherHas) {
            const other = isExt ? "sub_resource" : "ext_resource";
            const write = (isExt ? "SubResource" : "ExtResource") + "(\"" + v.s + "\")";
            this.error(p, "resource-undeclared", "no " + kind + " with id \"" + v.s + "\" (\"" + v.s + "\" is " + withArticle(other) + ")",
                "write " + write);
        } else {
            this.error(p, "resource-undeclared", "no " + kind + " with id \"" + v.s + "\"",
                "declare it with <" + kind + " id=\"" + v.s + "\" .../> before the nodes");
        }
    }

    // --- connections

    checkConnection(c: ConnectionDecl): void {
        this.unknownAttrs(c.attrs, CONNECTION_ATTRS, "connection");
        if (c.signal.length == 0) this.error(c.attrPos("signal"), "connection-invalid", "the connection's signal is empty");
        this.checkEnd(c, "from", c.from);
        this.checkEnd(c, "to", c.to);
        if (c.method.length == 0) this.error(c.attrPos("method"), "connection-invalid", "the connection's method is empty");
        for (let i = 0; i < c.extraChildren.length; i++) this.unknownXml(c.extraChildren[i], "connection");
    }

    // --- <embedded>

    checkEmbedded(d: EmbeddedDecl, seen: Map<string, XmlPos>): void {
        this.unknownAttrs(d.attrs, EMBEDDED_ATTRS, "embedded");
        const at = d.attrPos("path");
        const problem = embeddedPathProblem(d.path);
        if (problem.length > 0) {
            this.error(at, "embedded-invalid", problem, EMBEDDED_PATH_HINT);
        } else if (seen.has(d.path)) {
            this.error(at, "embedded-duplicate", "\"" + d.path + "\" is embedded twice" + firstAt(seen.get(d.path)),
                "a packed scene carries each file once: remove one of them");
        } else {
            seen.set(d.path, at);
        }
        if (d.invalid.length > 0) {
            this.error(d.contentPos, "embedded-invalid", "embedded \"" + d.path + "\": " + d.invalid, EMBEDDED_CONTENT_HINT);
        } else if (<i64>d.data.length != d.size) {
            this.error(d.attrPos("size"), "embedded-invalid",
                "embedded \"" + d.path + "\" holds " + d.data.length.toString() + " bytes, not the " + d.size.toString() + " its size says",
                EMBEDDED_CONTENT_HINT);
        }
    }

    checkEnd(c: ConnectionDecl, attr: string, path: string): void {
        const p = c.attrPos(attr);
        const problem = pathProblem(path);
        if (problem.length > 0) {
            this.error(p, "connection-invalid", "connection " + attr + " \"" + path + "\" is not a node path: " + problem,
                "name a node by its path from the root: \".\" (the root), \"Lamp\", \"Arm/Hand\"");
            return;
        }
        if (this.nodes.length == 0) return;
        // A %Name segment is resolved by the run-time rules (SceneNode.getNode),
        // which need the instanced scenes' unique nodes: left to instancing.
        const segs = path.split("/");
        for (let i = 0; i < segs.length; i++) if (isUniqueSegment(segs[i])) return;
        const r = this.resolve(path);
        if (r.how == Resolved.NotFound) {
            const hint = this.pathHint(path);
            this.error(p, "connection-node-missing", "connection " + attr + " node \"" + path + "\" not found" + this.missingDetail(path, r),
                hint == PARENT_HINT ? "name a node by its path from the root: \".\" (the root), \"Lamp\", \"Arm/Hand\"" : hint);
        }
    }
}

// The concrete node classes deriving from an abstract one.
function concreteNodeClasses(base: string): Array<string> {
    const out = new Array<string>();
    const names = nodeClassNames();
    for (let i = 0; i < names.length; i++) if (isA(names[i], base)) out.push(names[i]);
    return out;
}

// Milestone 14: a material document's problems (the document an .mtlx
// file reads as, ../resource/mtlx_doc.as, or one the editor built), as
// validateRscn's for a scene: the reader's warnings (mtlx-ignored), the
// ext_resources and sub_resources as a scene's, exactly one <resource>
// (`resource-missing`, `resource-duplicate`) whose type is a Material class
// a sub_resource may have (`resource-type-invalid`; an unknown type is the
// warning `resource-type-unknown`, kept and not built), its properties as a
// sub_resource's, and <node>, <connection> or <embedded> warned about as
// elements a material document does not have (`element-unknown`).
// validateRscn(doc) of a DocKind.Material document gives the same: the
// validator follows the document's kind; this names the intent.
export function validateMaterialDoc(doc: RscnDoc): Diagnostics {
    return validateRscn(doc);
}

// Milestone 36: whether an ext_resource is an Ogg sound (Ogg Vorbis or
// Opus by its extension, any case) declared as one of the audio stream
// types, Godot's AudioStreamOggVorbis included: the runtime decodes WAV, MP3
// and FLAC only (the validator's audio-format).
function isOggAudio(type: string, path: string): bool {
    if (type != "AudioStream" && type != "AudioStreamWAV" && type != "AudioStreamMP3" && type != "AudioStreamOggVorbis") {
        return false;
    }
    const e = toAsciiLowercase(pathExtensionOf(path));
    return e == "ogg" || e == "oga" || e == "opus";
}
