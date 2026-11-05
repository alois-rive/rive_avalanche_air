// The .rmdl document against the model's data form: each data-form record
// (../rmdlcmd/data/words.as RECORDS) and the element that holds it, each
// of its positionals and the attribute (or the nesting, or the order) that
// gives it, each of its flags and the property that holds it: the name, the
// kind of value, how a packed array wraps, what a reference names. The
// writer (write.as) reads this table one way, the reader (elements.as) the
// other, and docs/formats/RMDL.md's tables are this table written out.
//
// The rule: a record's positionals are attributes (or nothing, where the
// nesting says it: a vertex group's object, a bone's armature), its flags
// are properties named as the flags in snake case, except where a property
// below says otherwise; `type` and `parent` on <object> and `parent` on
// <bone> are attributes, as on .rscn's <node>. The order of the properties
// here is the order of the data form's flags (the canonical order).

import { RECORDS, TEXTURE_SLOTS } from "../rmdlcmd/data/words";

// The kind of a property's value, as the document writes it.
export enum Kind {
    // An integer (`12`, `-3`; any width the field has, u64 included).
    Int,
    // A number (`0.5`, `1`, `-0`, `nan`, `inf`, `-inf`): an f32.
    Float,
    // `true` or `false` (a data-form switch: written only when true).
    Bool,
    // A string literal (`"Wood"`; enum words are strings: `"blend"`).
    Str,
    // An array of strings (`["UVMap", "Second"]`): a repeated flag.
    StrList,
    Vec2,
    Vec3,
    Quat,
    Vec2i,
    Vec3i,
    // `Color(r, g, b)`: the kernel's colours are three numbers.
    Color3,
    // `Color(r, g, b, a)`.
    Color4,
    // Packed arrays.
    F32s,
    V3s,
    I32s,
    // An attribute's values: PackedFloat32Array, PackedInt32Array or
    // PackedVector3Array by the attribute's type.
    Nums,
    // `{"Deform": true, ...}`: an armature's bone collections, name to
    // visible.
    Dict,
    // A string naming an object of the document.
    ObjName,
    // A string naming a bone of the armature the element is in.
    BoneName,
    // `SubResource("...")` naming an Action, or `null`.
    Action,
    // `ExtResource("...")` naming a Texture2D.
    Texture,
    // `ExtResource("...")` naming a Model (a glTF file an import copied
    // geometry from: named, never read).
    Model,
    // `ExtResource("...")` naming a Material (a MaterialX file).
    MaterialFile,
    // `ExtResource("...")` naming a PackedScene (a model file an empty
    // instances).
    Scene,
    // `[SubResource("..."), ...]` naming Materials.
    Materials,
    // `SubResource("...")` naming the object's Mesh or Armature (no flag of
    // the data form: the record that follows the object's).
    Data,
    // Three Vector3 properties from one flag of nine numbers (a transform:
    // location, rotation, scale), each left out at its default.
    Split3,
}

// The name of a kind in messages: "base_color is a Color, found Vector3".
export function kindName(k: Kind): string {
    switch (k) {
        case Kind.Int: return "int";
        case Kind.Float: return "float";
        case Kind.Bool: return "bool";
        case Kind.Str: return "String";
        case Kind.StrList: return "Array of String";
        case Kind.Vec2: return "Vector2";
        case Kind.Vec3: return "Vector3";
        case Kind.Quat: return "Quaternion";
        case Kind.Vec2i: return "Vector2i";
        case Kind.Vec3i: return "Vector3i";
        case Kind.Color3: return "Color";
        case Kind.Color4: return "Color";
        case Kind.F32s: return "PackedFloat32Array";
        case Kind.V3s: return "PackedVector3Array";
        case Kind.I32s: return "PackedInt32Array";
        case Kind.Nums: return "packed array";
        case Kind.Dict: return "Dictionary";
        case Kind.ObjName: return "String (an object's name)";
        case Kind.BoneName: return "String (a bone's name)";
        case Kind.Action: return "SubResource (an Action) or null";
        case Kind.Texture: return "ExtResource (a Texture2D)";
        case Kind.Model: return "ExtResource (a Model)";
        case Kind.MaterialFile: return "ExtResource (a Material)";
        case Kind.Scene: return "ExtResource (a PackedScene)";
        case Kind.Materials: return "Array of SubResource (Materials)";
        case Kind.Data: return "SubResource (a Mesh or an Armature)";
        default: return "Vector3";
    }
}

// How many numbers a vector kind holds (0 for the others).
export function componentsOf(k: Kind): i32 {
    switch (k) {
        case Kind.Vec2: case Kind.Vec2i: return 2;
        case Kind.Vec3: case Kind.Vec3i: case Kind.Color3: return 3;
        case Kind.Quat: case Kind.Color4: return 4;
        default: return 0;
    }
}

// The constructor a kind is written with ("" for the kinds that have none).
export function ctorOf(k: Kind): string {
    switch (k) {
        case Kind.Vec2: return "Vector2";
        case Kind.Vec3: return "Vector3";
        case Kind.Quat: return "Quaternion";
        case Kind.Vec2i: return "Vector2i";
        case Kind.Vec3i: return "Vector3i";
        case Kind.Color3: case Kind.Color4: return "Color";
        case Kind.F32s: return "PackedFloat32Array";
        case Kind.V3s: return "PackedVector3Array";
        case Kind.I32s: return "PackedInt32Array";
        default: return "";
    }
}

// Whether the kind's numbers are integers.
export function isIntKind(k: Kind): bool {
    return k == Kind.Int || k == Kind.Vec2i || k == Kind.Vec3i || k == Kind.I32s;
}

// The wrapping of a packed array (2.5 of the design, RMDL.md "Wrapping"):
// `group` numbers a line, or with `variable` one element a line, an element
// being a count `k` and `k * per` numbers (`vert_groups`: `k g w g w`).
export const PER_LINE_FLAT: i32 = 16;

// One property: the data-form flag it holds ("" for Data), its name, its
// kind, its wrapping, and whether it is written as an attribute.
export class PropSpec {
    flag: string;
    name: string;
    kind: Kind;
    group: i32 = 0;
    variable: bool = false;
    per: i32 = 0;
    attr: bool = false;
    // Split3: the three properties' names, and their defaults' text.
    names: Array<string> = [];
    defaults: Array<string> = [];

    constructor(flag: string, name: string, kind: Kind) {
        this.flag = flag;
        this.name = name;
        this.kind = kind;
    }
}

// What gives a positional of the record.
export enum PosRole {
    // The element the record's element is in (an object's id, an action's,
    // a bone's).
    Owner,
    // The order of the elements, with the owner's holes (an object's, an
    // action's, a bone's slot; a material's index).
    Slot,
    // An attribute of the element (a name, a kind, a data path).
    Attr,
    // A property of the element (a material's or an action's name, an
    // import's source).
    Prop,
}

export class PosSpec {
    role: PosRole;
    name: string;
    kind: Kind;

    constructor(role: PosRole, name: string, kind: Kind) {
        this.role = role;
        this.name = name;
        this.kind = kind;
    }
}

// One record: its index in RECORDS, the element (and for a sub_resource,
// its type), where the element stands ("" at the top, else its parent
// element), the positionals and the properties.
export class RecordSpec {
    ri: i32;
    record: string;
    element: string;
    subType: string;
    parent: string;
    positionals: Array<PosSpec> = [];
    props: Array<PropSpec> = [];
    // flag -> property name, for the replay's messages (Replay.names).
    private flagNames: Map<string, string>? = null;

    constructor(ri: i32, element: string, subType: string, parent: string) {
        this.ri = ri;
        this.record = RECORDS[ri];
        this.element = element;
        this.subType = subType;
        this.parent = parent;
    }

    // The property by its name (a Split3's names included), or null.
    byName(name: string): PropSpec? {
        for (let i = 0; i < this.props.length; i++) {
            const p = this.props[i];
            if (p.name == name) return p;
            if (p.kind == Kind.Split3 && p.names.includes(name)) return p;
        }
        return null;
    }

    // The property that holds a flag, or null (a count the document derives).
    byFlag(flag: string): PropSpec? {
        for (let i = 0; i < this.props.length; i++) if (this.props[i].flag == flag) return this.props[i];
        return null;
    }

    // The positional named `name` (an attribute or a property), or null.
    positional(name: string): PosSpec? {
        for (let i = 0; i < this.positionals.length; i++) if (this.positionals[i].name == name) return this.positionals[i];
        return null;
    }

    // Every flag's name as the document says it.
    names(): Map<string, string> {
        let m = this.flagNames;
        if (m == null) {
            m = new Map<string, string>();
            for (let i = 0; i < this.props.length; i++) {
                const p = this.props[i];
                if (p.flag.length == 0) continue;
                m.set(p.flag, p.kind == Kind.Split3 ? p.names.join(", ") : p.name);
            }
            this.flagNames = m;
        }
        return m;
    }
}

// The counts the document derives (they are not properties): a scene's
// objects and actions, an armature's bones.
export const DERIVED_FLAGS: Array<string> = ["objects", "actions", "bones"];

// ------------------------------------------------------------ the table

function p(flag: string, kind: Kind): PropSpec {
    return new PropSpec(flag, flag.replaceAll("-", "_"), kind);
}

function named(flag: string, name: string, kind: Kind): PropSpec {
    return new PropSpec(flag, name, kind);
}

function packed(flag: string, kind: Kind, group: i32): PropSpec {
    const s = p(flag, kind);
    s.group = group;
    return s;
}

function variable(flag: string, kind: Kind, per: i32): PropSpec {
    const s = p(flag, kind);
    s.variable = true;
    s.per = per;
    return s;
}

function attr(flag: string, name: string, kind: Kind): PropSpec {
    const s = named(flag, name, kind);
    s.attr = true;
    return s;
}

function split3(flag: string, names: Array<string>): PropSpec {
    const s = new PropSpec(flag, names[0], Kind.Split3);
    s.names = names;
    s.defaults = ["0 0 0", "0 0 0", "1 1 1"];
    return s;
}

function pos(role: PosRole, name: string, kind: Kind): PosSpec {
    return new PosSpec(role, name, kind);
}

function sceneRecord(): RecordSpec {
    const r = new RecordSpec(0, "scene", "", "");
    r.props = [
        packed("object-holes", Kind.I32s, PER_LINE_FLAT), p("objects-live", Kind.Int),
        packed("action-holes", Kind.I32s, PER_LINE_FLAT), p("actions-live", Kind.Int),
        p("active", Kind.ObjName), p("mode", Kind.Str), p("select-mode", Kind.Vec3i),
        split3("cursor", ["cursor_location", "cursor_rotation", "cursor_scale"]),
        p("pivot", Kind.Str), p("orientation", Kind.Str), p("frame", Kind.Int), p("frame-range", Kind.Vec2i), p("fps", Kind.Float),
        p("frame-step", Kind.Int), p("render-size", Kind.Vec2i), p("render-background", Kind.Color4), p("render-shading", Kind.Str),
    ];
    return r;
}

function materialRecord(): RecordSpec {
    const r = new RecordSpec(1, "sub_resource", "Material", "");
    r.positionals = [pos(PosRole.Slot, "index", Kind.Int), pos(PosRole.Prop, "name", Kind.Str)];
    r.props = [
        p("file", Kind.MaterialFile), p("base-color", Kind.Color3), p("metallic", Kind.Float), p("roughness", Kind.Float), p("emission", Kind.Color3),
        p("emission-strength", Kind.Float), p("alpha", Kind.Float), p("alpha-mode", Kind.Str), p("alpha-cutoff", Kind.Float),
        p("double-sided", Kind.Bool),
    ];
    for (let i = 0; i < TEXTURE_SLOTS.length; i++) {
        r.props.push(p(TEXTURE_SLOTS[i] + "-texture", Kind.Texture));
        r.props.push(p(TEXTURE_SLOTS[i] + "-uv", Kind.Str));
    }
    return r;
}

function actionRecord(): RecordSpec {
    const r = new RecordSpec(2, "sub_resource", "Action", "");
    r.positionals = [pos(PosRole.Slot, "id", Kind.Int), pos(PosRole.Prop, "name", Kind.Str)];
    return r;
}

function fcurveRecord(): RecordSpec {
    const r = new RecordSpec(3, "fcurve", "", "Action");
    r.positionals = [
        pos(PosRole.Owner, "action", Kind.Int), pos(PosRole.Attr, "data_path", Kind.Str), pos(PosRole.Attr, "index", Kind.Int),
    ];
    r.props = [packed("keys", Kind.F32s, 12), p("extrapolation", Kind.Str), p("mute", Kind.Bool)];
    return r;
}

function objectRecord(): RecordSpec {
    const r = new RecordSpec(4, "object", "", "");
    r.positionals = [pos(PosRole.Slot, "id", Kind.Int), pos(PosRole.Attr, "name", Kind.Str)];
    r.props = [
        attr("type", "type", Kind.Str), split3("transform", ["location", "rotation", "scale"]),
        attr("parent", "parent", Kind.ObjName), p("parent-type", Kind.Str), p("parent-bone", Kind.Str),
        packed("parent-inverse", Kind.F32s, 4), p("select", Kind.Bool), p("hide", Kind.Bool), p("hide-render", Kind.Bool),
        named("", "data", Kind.Data), p("material-slots", Kind.Materials), named("active-vgroup", "active_vertex_group", Kind.Int),
        p("animation", Kind.Action), p("camera-type", Kind.Str), p("focal-length", Kind.Float), p("ortho-scale", Kind.Float),
        p("clip-start", Kind.Float), p("clip-end", Kind.Float), p("light-type", Kind.Str), p("color", Kind.Color3),
        p("energy", Kind.Float), p("empty-display", Kind.Str), p("empty-size", Kind.Float), p("instance", Kind.Scene),
    ];
    return r;
}

function vgroupRecord(): RecordSpec {
    const r = new RecordSpec(5, "vertex_group", "", "object");
    r.positionals = [pos(PosRole.Owner, "object", Kind.Int), pos(PosRole.Attr, "name", Kind.Str)];
    r.props = [p("lock", Kind.Bool)];
    return r;
}

function modifierRecord(): RecordSpec {
    const r = new RecordSpec(6, "modifier", "", "object");
    r.positionals = [
        pos(PosRole.Owner, "object", Kind.Int), pos(PosRole.Attr, "name", Kind.Str), pos(PosRole.Attr, "type", Kind.Str),
    ];
    r.props = [
        p("disabled", Kind.Bool), p("axis", Kind.Vec3i), p("clipping", Kind.Bool), p("merge", Kind.Bool),
        p("merge-threshold", Kind.Float), p("levels", Kind.Int), p("render-levels", Kind.Int), p("count", Kind.Int),
        p("relative-offset", Kind.Vec3), p("constant-offset", Kind.Vec3), p("thickness", Kind.Float), p("offset", Kind.Float),
        p("even", Kind.Bool), p("width", Kind.Float), p("segments", Kind.Int), p("angle-limit", Kind.Float),
        p("distance", Kind.Float), p("angle", Kind.Float), p("object", Kind.ObjName), p("preserve-volume", Kind.Bool),
        p("use-vertex-groups", Kind.Bool), p("use-envelopes", Kind.Bool), p("tool", Kind.Str), named("param", "params", Kind.StrList),
        p("hash", Kind.Int), p("scale", Kind.Float), p("scale-attr", Kind.Str), p("align", Kind.Bool), p("rotation", Kind.Vec3),
        p("rotation-attr", Kind.Str), p("ext-kind", Kind.Str), named("prop", "props", Kind.StrList),
    ];
    return r;
}

function meshRecord(): RecordSpec {
    const r = new RecordSpec(7, "sub_resource", "Mesh", "");
    r.positionals = [pos(PosRole.Owner, "object", Kind.Int)];
    r.props = [
        p("verts", Kind.Int), packed("vert-holes", Kind.I32s, PER_LINE_FLAT), p("verts-live", Kind.Int), packed("co", Kind.V3s, 3),
        packed("vert-flags", Kind.I32s, PER_LINE_FLAT), variable("vert-groups", Kind.F32s, 2),
        p("edges", Kind.Int), packed("edge-holes", Kind.I32s, PER_LINE_FLAT), p("edges-live", Kind.Int),
        packed("edge-verts", Kind.I32s, 2), packed("edge-flags", Kind.I32s, PER_LINE_FLAT), packed("crease", Kind.F32s, PER_LINE_FLAT),
        packed("bevel-weight", Kind.F32s, PER_LINE_FLAT),
        p("faces", Kind.Int), packed("face-holes", Kind.I32s, PER_LINE_FLAT), p("faces-live", Kind.Int),
        packed("face-loops", Kind.I32s, 2), packed("face-normals", Kind.V3s, 3), packed("face-flags", Kind.I32s, PER_LINE_FLAT),
        packed("face-materials", Kind.I32s, PER_LINE_FLAT),
        p("loops", Kind.Int), packed("loop-holes", Kind.I32s, PER_LINE_FLAT), p("loops-live", Kind.Int),
        packed("loop-refs", Kind.I32s, 3), variable("loop-uvs", Kind.F32s, 2), variable("loop-uv-flags", Kind.I32s, 1),
        named("uv-layer", "uv_layers", Kind.StrList), p("active-uv", Kind.Int), packed("select-history", Kind.I32s, 2),
        p("active-shape-key", Kind.Int),
    ];
    return r;
}

function shapeKeyRecord(): RecordSpec {
    const r = new RecordSpec(8, "shape_key", "", "Mesh");
    r.positionals = [pos(PosRole.Owner, "object", Kind.Int), pos(PosRole.Attr, "name", Kind.Str)];
    r.props = [
        p("value", Kind.Float), p("slider-min", Kind.Float), p("slider-max", Kind.Float), p("relative-to", Kind.Int),
        p("mute", Kind.Bool), packed("co", Kind.V3s, 3),
    ];
    return r;
}

function attributeRecord(): RecordSpec {
    const r = new RecordSpec(9, "attribute", "", "Mesh");
    r.positionals = [pos(PosRole.Owner, "object", Kind.Int), pos(PosRole.Attr, "name", Kind.Str)];
    r.props = [p("domain", Kind.Str), p("type", Kind.Str), packed("values", Kind.Nums, PER_LINE_FLAT)];
    return r;
}

function selectionSetRecord(): RecordSpec {
    const r = new RecordSpec(10, "selection_set", "", "Mesh");
    r.positionals = [pos(PosRole.Owner, "object", Kind.Int), pos(PosRole.Attr, "name", Kind.Str)];
    r.props = [
        packed("verts", Kind.I32s, PER_LINE_FLAT), packed("edges", Kind.I32s, PER_LINE_FLAT), packed("faces", Kind.I32s, PER_LINE_FLAT),
    ];
    return r;
}

function armatureRecord(): RecordSpec {
    const r = new RecordSpec(11, "sub_resource", "Armature", "");
    r.positionals = [pos(PosRole.Owner, "object", Kind.Int)];
    r.props = [
        packed("bone-holes", Kind.I32s, PER_LINE_FLAT), p("bones-live", Kind.Int), p("active", Kind.BoneName), p("display", Kind.Str),
        named("collection", "collections", Kind.Dict),
    ];
    return r;
}

function boneRecord(): RecordSpec {
    const r = new RecordSpec(12, "bone", "", "Armature");
    r.positionals = [
        pos(PosRole.Owner, "object", Kind.Int), pos(PosRole.Slot, "id", Kind.Int), pos(PosRole.Attr, "name", Kind.Str),
    ];
    r.props = [
        p("head", Kind.Vec3), p("tail", Kind.Vec3), p("roll", Kind.Float), attr("parent", "parent", Kind.BoneName),
        p("connected", Kind.Bool), p("deform", Kind.Bool), p("inherit-rotation", Kind.Bool), p("inherit-scale", Kind.Bool),
        p("envelope", Kind.Vec2), p("radius", Kind.Vec2), named("collection", "collections", Kind.StrList), p("select", Kind.Bool),
        p("select-head", Kind.Bool), p("select-tail", Kind.Bool), p("hide", Kind.Bool), p("pose-location", Kind.Vec3),
        p("pose-rotation", Kind.Quat), p("pose-scale", Kind.Vec3), p("pose-select", Kind.Bool), p("pose-hide", Kind.Bool),
    ];
    return r;
}

function constraintRecord(): RecordSpec {
    const r = new RecordSpec(13, "constraint", "", "bone");
    r.positionals = [
        pos(PosRole.Owner, "object", Kind.Int), pos(PosRole.Owner, "bone", Kind.Int), pos(PosRole.Attr, "name", Kind.Str),
        pos(PosRole.Attr, "type", Kind.Str),
    ];
    r.props = [
        p("influence", Kind.Float), p("disabled", Kind.Bool), p("space", Kind.Str), p("target", Kind.ObjName),
        p("subtarget", Kind.Str), p("pole", Kind.ObjName), p("pole-subtarget", Kind.Str), p("pole-angle", Kind.Float),
        p("chain-length", Kind.Int), p("iterations", Kind.Int), p("use-tail", Kind.Bool), p("axes", Kind.Vec3i),
        p("invert", Kind.Vec3i), p("offset", Kind.Bool), p("mix", Kind.Str), p("min", Kind.Vec3), p("max", Kind.Vec3),
        p("use-min", Kind.Vec3i), p("use-max", Kind.Vec3i), p("track", Kind.Str), p("up", Kind.Str), p("rest-length", Kind.Float),
        p("volume", Kind.Bool), packed("inverse", Kind.F32s, 4),
    ];
    return r;
}

function poseClipRecord(): RecordSpec {
    const r = new RecordSpec(14, "pose_clip", "", "");
    r.positionals = [pos(PosRole.Attr, "bone", Kind.Str)];
    r.props = [p("location", Kind.Vec3), p("rotation", Kind.Quat), p("scale", Kind.Vec3)];
    return r;
}

function importRecord(): RecordSpec {
    const r = new RecordSpec(15, "import", "", "");
    r.positionals = [pos(PosRole.Prop, "source", Kind.Model)];
    r.props = [p("hash", Kind.Str), p("bytes", Kind.Int), named("object", "objects", Kind.StrList)];
    return r;
}

let TABLE: Array<RecordSpec>? = null;

// Every record's spec, by its index in RECORDS.
export function recordSpecs(): Array<RecordSpec> {
    let t = TABLE;
    if (t == null) {
        t = [
            sceneRecord(), materialRecord(), actionRecord(), fcurveRecord(), objectRecord(), vgroupRecord(), modifierRecord(),
            meshRecord(), shapeKeyRecord(), attributeRecord(), selectionSetRecord(), armatureRecord(), boneRecord(),
            constraintRecord(), poseClipRecord(), importRecord(),
        ];
        TABLE = t;
    }
    return t;
}

export function recordSpec(ri: i32): RecordSpec {
    return recordSpecs()[ri];
}

// The record indices, by name.
export const R_SCENE: i32 = 0;
export const R_MATERIAL: i32 = 1;
export const R_ACTION: i32 = 2;
export const R_FCURVE: i32 = 3;
export const R_OBJECT: i32 = 4;
export const R_VGROUP: i32 = 5;
export const R_MODIFIER: i32 = 6;
export const R_MESH: i32 = 7;
export const R_SHAPEKEY: i32 = 8;
export const R_ATTRIBUTE: i32 = 9;
export const R_SELECTION_SET: i32 = 10;
export const R_ARMATURE: i32 = 11;
export const R_BONE: i32 = 12;
export const R_CONSTRAINT: i32 = 13;
export const R_POSE_CLIP: i32 = 14;
export const R_IMPORT: i32 = 15;

// The sub_resource types, and the ext_resource types with the extensions
// each takes ([] for any). A Texture2D, a Material and a PackedScene are
// read when the model loads (a material's image, a material that is a
// MaterialX file, a model an empty instances: .rscn's types for the same
// files); a Model is only named (the glTF file an import copied geometry
// from).
export const SUB_TYPES: Array<string> = ["Material", "Action", "Mesh", "Armature"];
// (milestone 61: a Material's `shader`, a .wgsl file: doc.as RmdlShader)
export const EXT_TYPES: Array<string> = ["Texture2D", "Material", "PackedScene", "Model", "Shader"];
export const MODEL_EXTENSIONS: Array<string> = ["gltf", "glb"];
export const MATERIAL_EXTENSIONS: Array<string> = ["mtlx"];
export const SCENE_EXTENSIONS: Array<string> = ["rmdl", "rmdlcmd", "gltf", "glb"];
export const SHADER_EXTENSIONS: Array<string> = ["wgsl"];

// The ext_resource type a kind of property names ("" for the others).
export function extTypeOf(k: Kind): string {
    switch (k) {
        case Kind.Texture: return "Texture2D";
        case Kind.MaterialFile: return "Material";
        case Kind.Scene: return "PackedScene";
        case Kind.Model: return "Model";
        default: return "";
    }
}

// The extensions an ext_resource type takes ([] for any), and how a
// message says them.
export function extExtensions(type: string): Array<string> {
    if (type == "Model") return MODEL_EXTENSIONS;
    if (type == "Material") return MATERIAL_EXTENSIONS;
    if (type == "PackedScene") return SCENE_EXTENSIONS;
    if (type == "Shader") return SHADER_EXTENSIONS;
    return [];
}

export function extExtensionsText(type: string): string {
    if (type == "Model") return "a .gltf or .glb file";
    if (type == "Material") return "a MaterialX file (.mtlx)";
    if (type == "PackedScene") return "a model file (.rmdl, .rmdlcmd, .gltf or .glb)";
    if (type == "Shader") return "a shader file (.wgsl)";
    return "any file";
}
