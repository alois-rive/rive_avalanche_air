// The classes of format 1 and their properties: the schema the validator
// checks a document against (rscn/validate.as), where the scene tree and the
// resource builders take their defaults, and what docs/formats/RSCN.md
// documents class by class. Names, types and defaults follow Godot 4 where
// Godot has the property, so that a scene reads the same to someone who
// knows Godot.
//
// Colours (albedo_color, light_color, background_color, ...) are sRGB-encoded
// with straight alpha, as in Godot: the renderer linearises them. Angles in
// degrees are named so (fov, spot_angle, rotation_degrees); `rotation` is in
// radians.
//
// Every class is a node class or a resource class. A resource class may be
// declared as a `sub_resource` (subResource), named by an `ext_resource`'s
// type (extType), or be neither: a runtime class (ArrayMesh, the meshes a
// model holds) or an abstract base (Mesh, Material, SkyMaterial, Light3D,
// GeometryInstance3D).

import { MAT4_IDENTITY } from "../base/vecmath";
import { panicAs, toAsciiLowercase } from "../base/util";
import { Value, ValueKind } from "./value";
import {
    BLEND_SHAPES_PREFIX, BONE_FIELD_POSITION, BONE_FIELD_QUATERNION, BONE_FIELD_SCALE, blendShapeOf, parseBoneProperty,
} from "./skeleton/names";
import { CLI, RETIRED_MODEL_EXTENSION } from "../base/names";

export enum PropType {
    Bool,
    Int,
    Float,
    String,
    StringName,
    NodePath,
    Vector2,
    Vector3,
    Color,
    Transform3D,
    // Milestone 13: a MultiMesh's buffer, numbers of any count.
    PackedFloat32Array,
    // Milestone 15: two whole numbers (an ArtboardTexture's size).
    Vector2i,
    // An ExtResource or a SubResource (or null) whose class is, or derives
    // from, PropInfo.resourceClass.
    Resource,
    // Milestone 31, appended: points, three numbers each (a
    // ConvexPolygonShape3D's points, a ConcavePolygonShape3D's triangles).
    PackedVector3Array,
    // Milestone 48, appended: a rotation as x, y, z, w (a Skeleton3D's
    // `bones/<bone>:quaternion`).
    Quaternion,
    // Milestone 32, appended: a Dictionary (a Curve3D's `_data`, as Godot
    // stores it); what its keys hold is the validator's to check.
    Dictionary,
    // Milestone 35, appended: an Array (a Curve's `_data`, as Godot stores
    // it: five items a point); what it holds is the validator's to check.
    Array,
    // Milestone 35, appended: colours, four numbers each (a Gradient's
    // `colors`, a CPUParticles3D's `emission_colors`).
    PackedColorArray,
    // Milestone 37, appended: points of a plane, two numbers each (a
    // PolygonOccluder3D's `polygon`), and 32-bit whole numbers (an
    // ArrayOccluder3D's `indices`).
    PackedVector2Array,
    PackedInt32Array,
    // Milestone 61, appended: a value whose type a file decides (a
    // ShaderMaterial's `shader_parameter/<name>`, typed by its shader's
    // uniform: a number, a bool, a vector, a colour, or a texture); the
    // loader checks it against the shader (shader-parameter-type).
    Variant,
}

export function propTypeName(t: PropType): string {
    switch (t) {
        case PropType.Bool: return "bool";
        case PropType.Int: return "int";
        case PropType.Float: return "float";
        case PropType.String: return "String";
        case PropType.StringName: return "StringName";
        case PropType.NodePath: return "NodePath";
        case PropType.Vector2: return "Vector2";
        case PropType.Vector3: return "Vector3";
        case PropType.Color: return "Color";
        case PropType.Transform3D: return "Transform3D";
        case PropType.PackedFloat32Array: return "PackedFloat32Array";
        case PropType.Vector2i: return "Vector2i";
        case PropType.PackedVector3Array: return "PackedVector3Array";
        case PropType.Quaternion: return "Quaternion";
        case PropType.Dictionary: return "Dictionary";
        case PropType.Array: return "Array";
        case PropType.PackedColorArray: return "PackedColorArray";
        case PropType.PackedVector2Array: return "PackedVector2Array";
        case PropType.PackedInt32Array: return "PackedInt32Array";
        case PropType.Variant: return "Variant";
        default: return "Resource";
    }
}

export class PropInfo {
    name: string;
    type: PropType;
    // PropType.Resource: the class the resource must be (or derive from).
    resourceClass: string = "";
    // PropType.Resource: the file extensions the editor offers for it when
    // narrower than what resourceClass's file types take (empty: all of
    // them). A material's texture slots take a Texture2D, which may be a
    // .hdr for a panorama, but the renderer draws only PNGs there.
    offerExtensions: Array<string> = [];
    // The value when the property is not set.
    def: Value;
    // PropType.Int used as an enum: the name of each value, from 0.
    enumNames: Array<string> = [];
    // PropType.Int that is 0 or more (a texture's UV set: glTF's texCoord
    // is an index), checked as an enum's range is.
    nonNegative: bool = false;
    // One line for RSCN.md and the CLI's `inspect`.
    doc: string;
    // Milestone 42, Rive's property flags (docs/plans/RIVE_MODEL.md section
    // 3.1): a timeline may key it (`animates`), a binding may drive it
    // (`bindable`), it is computed and may only be read (`output`: the
    // source of a to_source binding, never a target), and writing it
    // rebuilds GPU data (`costly`). applyFlagDefaults sets them once the
    // table is defined, from the property's type and one list of
    // exceptions; RSCN.md's table of flags is generated from them
    // (../binding/targets.as).
    animates: bool = false;
    bindable: bool = false;
    output: bool = false;
    costly: bool = false;
    // Milestone 32: computed from the node's other properties and never
    // stored (PathFollow3D.progress_ratio, its progress as a share of its
    // curve's baked length): a timeline keys it and a binding drives it,
    // both writing through the node (../binding/apply.as), the Inspector
    // shows it beside the property it stands for, and a file that sets it
    // is warned (property-derived) and the value ignored.
    derived: bool = false;
    // Milestone 48: the family a property of a name the class does not list
    // belongs to (FAMILY_*: `bones/<bone>:quaternion` on a Skeleton3D,
    // `blend_shapes/<name>` on a MeshInstance3D), FAMILY_NONE for a listed
    // one. A family's template (ClassInfo.families) names its shape
    // ("bones/<bone>:quaternion"); findProp answers each name of that shape
    // with a property of its own, made from the template.
    family: i32 = FAMILY_NONE;

    constructor(name: string, type: PropType, def: Value, doc: string) {
        this.name = name;
        this.type = type;
        this.def = def;
        this.doc = doc;
    }

    // Whether a value has this property's type: a Float property takes an
    // Int too, a StringName one a String, a Resource one null; the class of
    // a resource is checked by the validator, which knows the declarations.
    accepts(v: Value): bool {
        const k = v.kind;
        switch (this.type) {
            case PropType.Bool: return k == ValueKind.Bool;
            case PropType.Int: return k == ValueKind.Int;
            case PropType.Float: return k == ValueKind.Int || k == ValueKind.Float;
            case PropType.String: return k == ValueKind.String;
            case PropType.StringName: return k == ValueKind.String || k == ValueKind.StringName;
            case PropType.NodePath: return k == ValueKind.NodePath;
            case PropType.Vector2: return k == ValueKind.Vector2;
            case PropType.Vector3: return k == ValueKind.Vector3;
            case PropType.Color: return k == ValueKind.Color;
            case PropType.Transform3D: return k == ValueKind.Transform3D;
            case PropType.PackedFloat32Array: return k == ValueKind.PackedFloat32Array;
            case PropType.Vector2i: return k == ValueKind.Vector2i;
            case PropType.PackedVector3Array: return k == ValueKind.PackedVector3Array;
            case PropType.Quaternion: return k == ValueKind.Quaternion;
            case PropType.Dictionary: return k == ValueKind.Dictionary;
            case PropType.Array: return k == ValueKind.Array;
            case PropType.PackedColorArray: return k == ValueKind.PackedColorArray;
            case PropType.PackedVector2Array: return k == ValueKind.PackedVector2Array;
            case PropType.PackedInt32Array: return k == ValueKind.PackedInt32Array;
            case PropType.Variant:
                return k == ValueKind.Bool || k == ValueKind.Int || k == ValueKind.Float || k == ValueKind.Vector2
                    || k == ValueKind.Vector2i || k == ValueKind.Vector3 || k == ValueKind.Vector3i
                    || k == ValueKind.Vector4 || k == ValueKind.Color || k == ValueKind.Nil
                    || k == ValueKind.ExtResource || k == ValueKind.SubResource;
            default: return k == ValueKind.Nil || k == ValueKind.ExtResource || k == ValueKind.SubResource;
        }
    }

    // What `accepts` wants, for messages ("float", "Resource (Mesh)").
    typeText(): string {
        if (this.type == PropType.Resource) return "Resource (" + this.resourceClass + ")";
        return propTypeName(this.type);
    }
}

export class ClassInfo {
    name: string;
    // The class it derives from (null for Node and Resource).
    base: string?;
    isNode: bool;
    isAbstract: bool = false;
    // May be the type of a sub_resource.
    subResource: bool = false;
    // May be the type of an ext_resource.
    extType: bool = false;
    // The file extensions an ext_resource of this type may name (lower
    // case, without the dot).
    extensions: Array<string> = [];
    // Its own properties, in documentation order (the base's come first in
    // allProps).
    props: Array<PropInfo> = [];
    // Milestone 31: the signals it emits itself, Godot's, as Godot's class
    // reference writes them ("body_entered(body)"): the name is what comes
    // before "(" (classSignals, hasSignal). A script may emit any other
    // (NodeScript.emitSignal).
    signals: Array<string> = [];
    doc: string;

    constructor(name: string, base: string?, isNode: bool, doc: string) {
        this.name = name;
        this.base = base;
        this.isNode = isNode;
        this.doc = doc;
    }

    own(name: string): PropInfo? {
        for (let i = 0; i < this.props.length; i++) if (this.props[i].name == name) return this.props[i];
        return null;
    }

    // Milestone 48: the families of properties it has besides `props`
    // (templates: see PropInfo.family), which the class reference and the
    // binding targets' table leave out, as they leave out `signal:<name>`.
    families: Array<PropInfo> = [];

    // Every property of the class and its bases by name, made on the
    // first findProp (milestone 13: loading reads a node's typed fields
    // through findProp, a dozen for each of 10,000 nodes, and a walk of the
    // class chain for each was a tenth of the load).
    index: Map<string, PropInfo>? = null;
}

// --- the table ---------------------------------------------------------------

let classes: Map<string, ClassInfo>? = null;
let classOrder: Array<string> = [];

// Milestone 48: the families of properties (PropInfo.family), named by
// shape (./skeleton/names.as reads them): a bone's position, rotation and
// scale on a Skeleton3D, whole (`bones/<bone>:position`; the timelines key
// a component, `bones/<bone>:position:x`), and a blend shape's weight on a
// MeshInstance3D.
export const FAMILY_NONE: i32 = 0;
export const FAMILY_BONE_POSITION: i32 = 1;
export const FAMILY_BONE_QUATERNION: i32 = 2;
export const FAMILY_BONE_SCALE: i32 = 3;
export const FAMILY_BLEND_SHAPE: i32 = 4;
// Milestone 61: a ShaderMaterial's parameter, `shader_parameter/<name>`
// (Godot's name), a uniform of its shader; typed by that uniform
// (PropType.Variant here).
export const FAMILY_SHADER_PARAMETER: i32 = 5;

// What a shader parameter's property starts with.
export const SHADER_PARAMETER_PREFIX = "shader_parameter/";

// The uniform a `shader_parameter/<name>` property names, or null when
// `name` is no such property (the name after the prefix must be a WGSL
// identifier: [A-Za-z_][A-Za-z0-9_]*).
export function shaderParameterOf(name: string): string? {
    if (!name.startsWith(SHADER_PARAMETER_PREFIX)) return null;
    const start = SHADER_PARAMETER_PREFIX.length;
    const n = name.length;
    if (n == start) return null;
    for (let i = start; i < n; i++) {
        const c = name.charCodeAt(i);
        const letter = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
        const digit = c >= 0x30 && c <= 0x39;
        if (!letter && !(digit && i > start)) return null;
    }
    return name.substring(start);
}

// The family a property name has the shape of (FAMILY_NONE for any other).
export function familyOfName(name: string): i32 {
    if (name.startsWith(SHADER_PARAMETER_PREFIX)) return shaderParameterOf(name) != null ? FAMILY_SHADER_PARAMETER : FAMILY_NONE;
    if (name.startsWith(BLEND_SHAPES_PREFIX)) return blendShapeOf(name) != null ? FAMILY_BLEND_SHAPE : FAMILY_NONE;
    const b = parseBoneProperty(name);
    if (b == null || b.axis >= 0) return FAMILY_NONE;
    if (b.field == BONE_FIELD_POSITION) return FAMILY_BONE_POSITION;
    if (b.field == BONE_FIELD_QUATERNION) return FAMILY_BONE_QUATERNION;
    if (b.field == BONE_FIELD_SCALE) return FAMILY_BONE_SCALE;
    return FAMILY_NONE;
}

function f(x: f64): Value {
    return Value.float(x);
}

function define(c: ClassInfo): ClassInfo {
    (classes as Map<string, ClassInfo>).set(c.name, c);
    classOrder.push(c.name);
    return c;
}

function prop(c: ClassInfo, name: string, type: PropType, def: Value, doc: string): PropInfo {
    const p = new PropInfo(name, type, def, doc);
    c.props.push(p);
    return p;
}

// A family's template (PropInfo.family): its flags are set here, not by
// applyFlagDefaults, which sees `props` only.
function family(c: ClassInfo, shape: string, kind: i32, type: PropType, def: Value, animates: bool, bindable: bool, doc: string): PropInfo {
    const p = new PropInfo(shape, type, def, doc);
    p.family = kind;
    p.animates = animates;
    p.bindable = bindable;
    c.families.push(p);
    return p;
}

function res(c: ClassInfo, name: string, resourceClass: string, doc: string): PropInfo {
    const p = prop(c, name, PropType.Resource, Value.nil(), doc);
    p.resourceClass = resourceClass;
    return p;
}

// A material's texture slot: a Texture2D the editor offers only PNGs for.
function pngTexture(c: ClassInfo, name: string, doc: string): PropInfo {
    const p = res(c, name, "Texture2D", doc);
    p.offerExtensions = ["png"];
    return p;
}

function enumProp(c: ClassInfo, name: string, def: i32, names: Array<string>, doc: string): PropInfo {
    const p = prop(c, name, PropType.Int, Value.int(def), doc);
    p.enumNames = names;
    return p;
}

// StandardMaterial3D's texture properties, in engine/src/material/pbr.as
// PbrSlot order: the slot a texture property fills is its index here.
// Godot's names where Godot has the texture, glTF's otherwise
// (docs/formats/MATERIALS.md has the table).
export const MATERIAL_TEXTURE_PROPS: StaticArray<string> = [
    "albedo_texture", "metallic_texture", "roughness_texture", "normal_texture", "ao_texture", "emission_texture",
    "clearcoat_texture", "clearcoat_roughness_texture", "clearcoat_normal_texture",
    "sheen_color_texture", "sheen_roughness_texture", "specular_texture", "specular_color_texture",
    "refraction_texture", "thickness_texture", "iridescence_texture", "iridescence_thickness_texture",
    "anisotropy_texture", "diffuse_transmission_texture", "backlight_texture",
];

// The four properties of a texture slot's UV set and KHR_texture_transform:
// `<texture property><suffix>` ("albedo_texture_scale").
export const MATERIAL_UV_SUFFIXES: StaticArray<string> = ["_texcoord", "_offset", "_rotation", "_scale"];

// Milestone 14: the rest of glTF 2.0's material on StandardMaterial3D,
// so that a glTF material survives import, editing and an .mtlx file
// (engine/src/material/pbr.as). Godot's names where Godot has the
// feature (clearcoat, anisotropy, refraction, back lighting, shading_mode),
// glTF's otherwise; a feature Godot switches on (clearcoat_enabled...) is
// glTF's extension present. Then every texture slot's UV set and transform.
function materialPbrProps(c: ClassInfo): void {
    enumProp(c, "shading_mode", 1, ["unshaded", "per_pixel"],
        "per_pixel lights the material; unshaded draws its albedo as it is (glTF's KHR_materials_unlit).");
    prop(c, "ao_strength", PropType.Float, f(1), "How much ao_texture darkens: 0 not at all, 1 fully (glTF's occlusion strength).");
    prop(c, "ior", PropType.Float, f(1.5),
        "The index of refraction: the reflectance of the non-metal part, and how transmitted light bends (KHR_materials_ior).");
    prop(c, "specular", PropType.Float, f(1), "Scales the non-metal reflection (KHR_materials_specular's specularFactor).");
    pngTexture(c, "specular_texture", "Multiplies specular (its alpha channel, as glTF).");
    prop(c, "specular_color", PropType.Color, Value.color(1, 1, 1, 1),
        "Tints the non-metal reflection seen head-on (specularColorFactor).");
    pngTexture(c, "specular_color_texture", "Multiplies specular_color.");
    prop(c, "clearcoat_enabled", PropType.Bool, Value.bool(false), "A clear coat over the material (KHR_materials_clearcoat).");
    prop(c, "clearcoat", PropType.Float, f(1), "The clear coat's strength.");
    prop(c, "clearcoat_roughness", PropType.Float, f(0.5), "The clear coat's roughness.");
    pngTexture(c, "clearcoat_texture", "Multiplies clearcoat (its red channel, as glTF).");
    pngTexture(c, "clearcoat_roughness_texture", "Multiplies clearcoat_roughness (its green channel, as glTF).");
    pngTexture(c, "clearcoat_normal_texture", "The clear coat's own tangent-space normal map.");
    prop(c, "clearcoat_normal_scale", PropType.Float, f(1), "The strength of clearcoat_normal_texture.");
    prop(c, "anisotropy_enabled", PropType.Bool, Value.bool(false),
        "Highlights stretched along a direction, as brushed metal (KHR_materials_anisotropy).");
    prop(c, "anisotropy", PropType.Float, f(0), "How far the highlights stretch: 0 not at all, 1 fully.");
    prop(c, "anisotropy_rotation", PropType.Float, f(0),
        "The direction of the stretch, in radians from the tangent, counter-clockwise.");
    pngTexture(c, "anisotropy_texture",
        "The direction (red and green, from the tangent) and a strength (blue) multiplying anisotropy, as glTF.");
    prop(c, "sheen_color", PropType.Color, Value.color(0, 0, 0, 1),
        "The colour of a cloth's sheen at grazing angles; black has none (KHR_materials_sheen).");
    pngTexture(c, "sheen_color_texture", "Multiplies sheen_color.");
    prop(c, "sheen_roughness", PropType.Float, f(0), "The sheen's roughness.");
    pngTexture(c, "sheen_roughness_texture", "Multiplies sheen_roughness (its alpha channel, as glTF).");
    prop(c, "refraction_enabled", PropType.Bool, Value.bool(false),
        "Light passes through the surface, as glass (KHR_materials_transmission).");
    // Milestone 62: Godot's refraction_scale, drawn while the Environment's
    // screen_refraction_enabled is on.
    prop(c, "refraction_scale", PropType.Float, f(0.05),
        "How far a thin wall (thickness 0) bends the scene behind it along its normal, as a share of the picture (with the Environment's screen_refraction_enabled).");
    prop(c, "transmission", PropType.Float, f(1), "How much light passes through (with refraction_enabled).");
    pngTexture(c, "refraction_texture", "Multiplies transmission (its red channel, as glTF).");
    prop(c, "thickness", PropType.Float, f(0),
        "The thickness of the volume under the surface, in the mesh's units; 0 is a thin wall (KHR_materials_volume).");
    pngTexture(c, "thickness_texture", "Multiplies thickness (its green channel, as glTF).");
    prop(c, "attenuation_distance", PropType.Float, f(0),
        "The distance light travels in the volume before it is tinted to attenuation_color; 0 is never.");
    prop(c, "attenuation_color", PropType.Color, Value.color(1, 1, 1, 1), "The colour light takes on through the volume.");
    prop(c, "dispersion", PropType.Float, f(0),
        "Spreads transmitted light into colours, as Abbe's number does: 20 / Abbe (KHR_materials_dispersion).");
    prop(c, "iridescence", PropType.Float, f(0), "A thin film's rainbow colours, as soap (KHR_materials_iridescence).");
    pngTexture(c, "iridescence_texture", "Multiplies iridescence (its red channel, as glTF).");
    prop(c, "iridescence_ior", PropType.Float, f(1.3), "The thin film's index of refraction.");
    prop(c, "iridescence_thickness_minimum", PropType.Float, f(100),
        "The film's thickness in nanometres where iridescence_thickness_texture is 0.");
    prop(c, "iridescence_thickness_maximum", PropType.Float, f(400),
        "The film's thickness in nanometres where iridescence_thickness_texture is 1, and everywhere without one.");
    pngTexture(c, "iridescence_thickness_texture", "Chooses the film's thickness (its green channel, as glTF).");
    prop(c, "backlight_enabled", PropType.Bool, Value.bool(false),
        "Light passes through and scatters, as leaves and paper (KHR_materials_diffuse_transmission).");
    prop(c, "diffuse_transmission", PropType.Float, f(1), "How much light scatters through (with backlight_enabled).");
    pngTexture(c, "diffuse_transmission_texture", "Multiplies diffuse_transmission (its alpha channel, as glTF).");
    prop(c, "backlight", PropType.Color, Value.color(1, 1, 1, 1), "The colour of the light scattered through.");
    pngTexture(c, "backlight_texture", "Multiplies backlight.");
    for (let i = 0; i < MATERIAL_TEXTURE_PROPS.length; i++) {
        const t = MATERIAL_TEXTURE_PROPS[i];
        prop(c, t + "_texcoord", PropType.Int, Value.int(0), "The UV set " + t + " samples: 0 the first, 1 the second.")
            .nonNegative = true;
        prop(c, t + "_offset", PropType.Vector2, Value.vector2(0, 0), "Moves " + t + " (KHR_texture_transform's offset).");
        prop(c, t + "_rotation", PropType.Float, f(0),
            "Turns " + t + " counter-clockwise, in radians (KHR_texture_transform's rotation).");
        prop(c, t + "_scale", PropType.Vector2, Value.vector2(1, 1), "Scales " + t + " (KHR_texture_transform's scale).");
    }
}

// shadow_bias and shadow_normal_bias, with a light class's own defaults.
function shadowBiases(c: ClassInfo, bias: f64, normalBias: f64): void {
    prop(c, "shadow_bias", PropType.Float, f(bias),
        "Pushes the shadow's test towards the light, in shadow-map texels, against acne (Light3D's in Godot).");
    prop(c, "shadow_normal_bias", PropType.Float, f(normalBias),
        "Pushes the shadow's test along the surface's normal, in shadow-map texels (Light3D's in Godot).");
}

function build(): Map<string, ClassInfo> {
    classes = new Map<string, ClassInfo>();
    classOrder = [];
    let c: ClassInfo;

    // Nodes.
    c = define(new ClassInfo("Node", null, true, "The base of every node: a name in the tree, a script, groups."));
    res(c, "script", "Script", "The node's script: an .as file holding one class that extends NodeScript.");
    prop(c, "unique_name_in_owner", PropType.Bool, Value.bool(false),
        "The node can be reached as %Name from any node of the same scene.");
    // Milestone 17: the view model the scene's bindings read (RSCN.md,
    // "Bindings"); only the root node's counts.
    res(c, "view_model", "ViewModel",
        "On the scene's root: the Rive view model its nodes' bindings read and write (other nodes' are ignored, with a warning).");
    // Milestone 42: the data context of an instanced scene
    // (docs/plans/RIVE_MODEL.md section 3.4; RSCN.md, "Data contexts").
    prop(c, "data_path", PropType.String, Value.str(""),
        "On a node that instances a scene: the path, in this scene's data context, of the nested view model the instanced scene's bindings start from; empty to share this scene's context.");
    // Milestone 46: Rive's state machines (docs/plans/RIVE_MODEL.md section
    // 3.3; RSCN.md, "State machines"; ../sm/decl.as names them): the root's
    // default machine, and on a node that instances a scene, what the
    // instanced scene runs (Rive's NestedArtboard: NestedStateMachine,
    // NestedSimpleAnimation, NestedRemapAnimation's time, speed and
    // isPaused; the instance_ prefix keeps them from shadowing a script's
    // exported `speed`). Strings never animate; the last three animate and
    // bind.
    prop(c, "default_state_machine", PropType.String, Value.str(""),
        "On the scene's root: the state machine the scene runs; empty for the first it declares, - for none.");
    prop(c, "instance_state_machine", PropType.String, Value.str(""),
        "On a node that instances a scene: the instanced scene's state machine it runs; empty for its default, - for none.");
    prop(c, "instance_animation", PropType.String, Value.str(""),
        "On a node that instances a scene: one of the instanced scene's animations, played instead of its state machine; empty for none.");
    prop(c, "instance_animation_time", PropType.Float, f(-1),
        "On a node that instances a scene and names an animation: 0 to 1 scrubs the animation to that fraction of its duration; below 0 plays it.");
    prop(c, "instance_speed", PropType.Float, f(1),
        "On a node that instances a scene: how fast its state machine or animation runs (1 as authored, negative backwards).");
    prop(c, "instance_paused", PropType.Bool, Value.bool(false),
        "On a node that instances a scene: its state machine or animation holds where it is.");

    c = define(new ClassInfo("Node3D", "Node", true, "A node with a transform in 3D space."));
    prop(c, "transform", PropType.Transform3D, Value.transform(MAT4_IDENTITY), "The local transform (relative to the parent).");
    prop(c, "position", PropType.Vector3, Value.vector3(0, 0, 0), "The local origin; applies over transform.");
    prop(c, "rotation", PropType.Vector3, Value.vector3(0, 0, 0),
        "The local rotation as Euler angles in radians, order YXZ; applies over transform.");
    prop(c, "rotation_degrees", PropType.Vector3, Value.vector3(0, 0, 0),
        "rotation in degrees; applies over transform and rotation.");
    prop(c, "scale", PropType.Vector3, Value.vector3(1, 1, 1), "The local scale; applies over transform.");
    prop(c, "visible", PropType.Bool, Value.bool(true), "Whether the node and its children are drawn.");
    // Milestone 42: Rive's outputs (docs/plans/RIVE_MODEL.md section 3.1):
    // computed each frame, never written in a file (property-output); a
    // to_source binding writes them into the view model, so that a 2D label
    // follows a 3D node.
    output(prop(c, "global_position", PropType.Vector3, Value.vector3(0, 0, 0),
        "The node's origin in the scene's space, in metres (computed: bind it with mode=\"to_source\")."));
    output(prop(c, "screen_position", PropType.Vector2, Value.vector2(0, 0),
        "The node's origin projected into the view, in points from its top-left corner, y down, as Rive's layout measures (computed; behind the camera it keeps its last value)."));
    output(prop(c, "screen_visible", PropType.Bool, Value.bool(false),
        "Whether the node's origin is in front of the camera and inside the view (computed)."));
    // Milestone 47: listeners (../sm/decl.as LISTENER_PASS_THROUGH_PROPERTY;
    // RSCN.md "Listeners"). Read at each pointer event; not keyed nor bound.
    prop(c, "listener_pass_through", PropType.Bool, Value.bool(false),
        "A state machine listener's pointer goes on past a hit on this node (or on a node under it) to what is behind; off, the nearest hit hides the rest.");

    // Godot's base of the nodes that draw geometry, for cast_shadow and the
    // visibility range (milestone 13; its other properties are not in
    // format 1).
    c = define(new ClassInfo("GeometryInstance3D", "Node3D", true, "The base of the nodes that draw geometry."));
    c.isAbstract = true;
    enumProp(c, "cast_shadow", 1, ["off", "on", "double_sided", "shadows_only"],
        "Whether it casts shadows: not at all, yes, from both sides (the same here: faces are never culled), or only its shadow, the geometry itself not drawn.");
    prop(c, "visibility_range_begin", PropType.Float, f(0),
        "Drawn only from this distance to the camera on (0: from up close); measured to the centre of its box.");
    prop(c, "visibility_range_begin_margin", PropType.Float, f(0),
        "How far past visibility_range_begin the change waits once drawn or hidden, so it does not flicker at the edge.");
    prop(c, "visibility_range_end", PropType.Float, f(0),
        "Drawn only up to this distance to the camera (0: however far).");
    prop(c, "visibility_range_end_margin", PropType.Float, f(0),
        "How far past visibility_range_end the change waits once drawn or hidden, so it does not flicker at the edge.");
    enumProp(c, "visibility_range_fade_mode", 0, ["disabled", "self", "dependencies"],
        "Godot's fade over the margins; self and dependencies are drawn without the fade, over the whole margin.");
    // Milestone 19: how the geometry takes part in baked lighting (a
    // LightmapGI's bake), Godot's names and defaults.
    enumProp(c, "gi_mode", 1, ["disabled", "static", "dynamic"],
        "Baked lighting: none; static (it casts baked light and shadows and is drawn with its lightmap); dynamic (it is lit by the bake's probes).");
    prop(c, "gi_lightmap_texel_scale", PropType.Float, f(1),
        "Multiplies the lightmap's texel density on this geometry (2: twice the texels along each side).");
    // Milestone 20: Godot's VisualInstance3D.layers, which reflection
    // probes select by.
    prop(c, "layers", PropType.Int, Value.int(1),
        "The visual layers it is on (bit k: layer k + 1): a ReflectionProbe captures it and reflects in it by these.");
    // Hedra's emerge (not Godot's; tree/node.as GeometryInstance3D.emerge).
    prop(c, "emerge", PropType.Float, f(1),
        "How far it has come out of a fog of emerge_color: 0 not drawn, 1 drawn as usual; in between it shows pixel by pixel, each first in the fog's colour.");
    prop(c, "emerge_color", PropType.Color, Value.color(0, 0, 0, 1),
        "The colour of the fog it emerges from (emerge below 1), as the environment's fog_light_color.");
    // Hedra's fade (not Godot's; tree/node.as GeometryInstance3D.fade).
    prop(c, "fade", PropType.Float, f(0),
        "How far its shown colour (lit shading, emission included) goes toward fade_color: 0 drawn as usual, 1 all fade_color.");
    prop(c, "fade_color", PropType.Color, Value.color(0, 0, 0, 1),
        "The colour it fades toward (fade above 0), as the environment's background_color: at fade 1 it matches a background of that colour.");
    // Milestone 47: listeners hit geometry by its triangles, and pass the
    // pointer on to an artboard it shows (../sm/decl.as; RSCN.md
    // "Listeners"). Read at each pointer event; not keyed nor bound.
    prop(c, "input_ray_pickable", PropType.Bool, Value.bool(true),
        "State machine listeners hit it by its triangles (as drawn, a skinned mesh posed); off, the pointer passes through it.");
    prop(c, "pointer_forward", PropType.Bool, Value.bool(true),
        "A pointer on an ArtboardTexture it shows (or an ArtboardSprite3D's artboard) reaches that artboard's state machine at the hit's texture coordinates.");

    c = define(new ClassInfo("MeshInstance3D", "GeometryInstance3D", true,
        "Draws a mesh. A model's skinned mesh follows a Skeleton3D, and a mesh with blend shapes has a `blend_shapes/<name>` property for each (a weight, 0 to 1: animates, bindable; see \"Skeletons\")."));
    res(c, "mesh", "Mesh", "The mesh: a primitive mesh sub_resource.");
    res(c, "material_override", "Material", "A material used for every surface instead of the mesh's own.");
    // Milestone 48: Godot's skeleton (a NodePath: not flagged).
    prop(c, "skeleton", PropType.NodePath, Value.nodePath(".."),
        "The Skeleton3D a model's skinned mesh follows, by its path from the mesh (`..`, the parent, when not set); a path that finds none draws the mesh as it was bound.");
    family(c, "blend_shapes/<name>", FAMILY_BLEND_SHAPE, PropType.Float, f(0), true, true,
        "A blend shape's weight (the model's when not set).");

    c = define(new ClassInfo("ModelInstance3D", "GeometryInstance3D", true,
        "Draws a whole model (.rmdl, .rmdlcmd, .modeler, .gltf or .glb): its meshes, as they are placed in the model."));
    res(c, "model", "Model", "The model: an ext_resource of type Model.");

    c = define(new ClassInfo("MultiMeshInstance3D", "GeometryInstance3D", true,
        "Draws a MultiMesh: one mesh many times, with GPU instancing."));
    res(c, "multimesh", "MultiMesh", "The MultiMesh: its mesh, and a transform (and colour) per instance.");

    c = define(new ClassInfo("Camera3D", "Node3D", true, "A camera; the scene is seen through the current one."));
    prop(c, "current", PropType.Bool, Value.bool(false), "This camera is the one the scene is seen through.");
    prop(c, "fov", PropType.Float, f(75), "The field of view in degrees, along the axis keep_aspect names.");
    prop(c, "near", PropType.Float, f(0.05), "The near clipping distance.");
    prop(c, "far", PropType.Float, f(4000), "The far clipping distance.");
    enumProp(c, "projection", 0, ["perspective", "orthogonal"], "The projection.");
    prop(c, "size", PropType.Float, f(1), "The orthogonal view's extent, along the axis keep_aspect names.");
    enumProp(c, "keep_aspect", 1, ["keep_width", "keep_height"], "Which axis fov and size measure.");
    // Milestone 62: Godot's Camera3D.attributes (a CameraAttributesPractical:
    // depth of field and exposure), which replaces the WorldEnvironment's.
    res(c, "attributes", "CameraAttributes",
        "The camera's depth of field and exposure, a CameraAttributesPractical (none: the WorldEnvironment's camera_attributes).");

    c = define(new ClassInfo("Light3D", "Node3D", true, "The base of the lights."));
    c.isAbstract = true;
    prop(c, "light_color", PropType.Color, Value.color(1, 1, 1, 1), "The light's colour.");
    prop(c, "light_energy", PropType.Float, f(1), "The light's strength (a multiplier, as in Godot).");
    prop(c, "light_specular", PropType.Float, f(0.5), "How strongly the light shows in specular highlights (as in Godot).");
    prop(c, "shadow_enabled", PropType.Bool, Value.bool(false), "The light casts shadows.");
    prop(c, "shadow_blur", PropType.Float, f(1),
        "The softness of the shadow's edge: the filter's radius in shadow-map texels (0: a hard edge).");
    prop(c, "shadow_opacity", PropType.Float, f(1), "How dark the shadow is: 0 none, 1 full.");
    // Milestone 19: what a LightmapGI's bake does with the light.
    enumProp(c, "light_bake_mode", 2, ["disabled", "static", "dynamic"],
        "Baked lighting: not baked; static (its light and shadows are baked, and it lights only what is not lightmapped in real time); dynamic (only its bounced light is baked).");
    prop(c, "light_size", PropType.Float, f(0),
        "Omni and spot: the light's size in metres, which softens its baked shadows (a sun's is light_angular_distance).");
    prop(c, "light_indirect_energy", PropType.Float, f(1), "Multiplies the light's bounced light in a bake.");
    // Milestone 37: how much the light lights fog volumes and the
    // Environment's volumetric fog (Godot's Light3D property).
    prop(c, "light_volumetric_fog_energy", PropType.Float, f(1),
        "Multiplies the light it gives fog volumes and the environment's volumetric fog (0: they are not lit by it).");

    // Godot declares shadow_bias and shadow_normal_bias on Light3D and gives
    // each light class its own defaults; classdb has one default per
    // property, so each concrete light declares them with its own.
    c = define(new ClassInfo("DirectionalLight3D", "Light3D", true,
        "A light from infinitely far away, shining along the node's -Z axis (the sun)."));
    prop(c, "light_angular_distance", PropType.Float, f(0),
        "The sun disc's size in degrees, as a sky draws it (0: only its glow).");
    shadowBiases(c, 0.1, 2);
    enumProp(c, "directional_shadow_mode", 2, ["orthogonal", "parallel_2_splits", "parallel_4_splits"],
        "How many cascades cover the view: 1, 2 or 4.");
    prop(c, "directional_shadow_split_1", PropType.Float, f(0.1),
        "Where the first cascade ends, as a fraction of directional_shadow_max_distance.");
    prop(c, "directional_shadow_split_2", PropType.Float, f(0.2), "Where the second cascade ends (4 splits).");
    prop(c, "directional_shadow_split_3", PropType.Float, f(0.5), "Where the third cascade ends (4 splits).");
    prop(c, "directional_shadow_fade_start", PropType.Float, f(0.8),
        "Where the shadow starts to fade out, as a fraction of directional_shadow_max_distance.");
    prop(c, "directional_shadow_max_distance", PropType.Float, f(100), "How far from the camera the shadow reaches.");

    c = define(new ClassInfo("OmniLight3D", "Light3D", true, "A light shining in every direction from a point."));
    prop(c, "omni_range", PropType.Float, f(5), "The distance the light reaches.");
    prop(c, "omni_attenuation", PropType.Float, f(1), "How the light falls off over its range.");
    shadowBiases(c, 0.1, 1);

    c = define(new ClassInfo("SpotLight3D", "Light3D", true, "A cone of light along the node's -Z axis."));
    prop(c, "spot_range", PropType.Float, f(5), "The distance the light reaches.");
    prop(c, "spot_attenuation", PropType.Float, f(1), "How the light falls off over its range.");
    prop(c, "spot_angle", PropType.Float, f(45), "The cone's half angle, in degrees.");
    prop(c, "spot_angle_attenuation", PropType.Float, f(1), "How the light falls off toward the cone's edge.");
    shadowBiases(c, 0.03, 1);

    c = define(new ClassInfo("WorldEnvironment", "Node", true, "The scene's environment: background, ambient light, sky, tone mapping."));
    res(c, "environment", "Environment", "The environment.");
    // Milestone 62: Godot's WorldEnvironment.camera_attributes.
    res(c, "camera_attributes", "CameraAttributes",
        "The depth of field and exposure of every camera without attributes of its own, a CameraAttributesPractical.");

    c = define(new ClassInfo("Marker3D", "Node3D", true, "A point in space, drawn as a cross in the editor."));
    prop(c, "gizmo_extents", PropType.Float, f(0.25), "The size of the cross.");

    // Milestone 16: an artboard drawn on a quad in the scene, with Godot 4's
    // SpriteBase3D properties (names, defaults and meanings), the texture
    // an ArtboardTexture (docs/formats/RSCN.md, "ArtboardSprite3D").
    // Godot's fixed_size, render_priority, texture_filter, alpha_hash_scale
    // and alpha_antialiasing_* are not in format 1 (kept as unknown
    // properties, as any other).
    c = define(new ClassInfo("ArtboardSprite3D", "GeometryInstance3D", true,
        "Draws an ArtboardTexture on a quad, as Godot's Sprite3D draws a texture: a placeholder in the tools, the live artboard in a built project."));
    res(c, "texture", "ArtboardTexture", "The artboard drawn: its size in pixels, times pixel_size, is the quad's.");
    prop(c, "centered", PropType.Bool, Value.bool(true),
        "The quad is centred on the node's origin; off, its bottom-left corner is there.");
    prop(c, "offset", PropType.Vector2, Value.vector2(0, 0),
        "Moves the quad in its own plane, in texture pixels (x right, y up).");
    prop(c, "flip_h", PropType.Bool, Value.bool(false), "The texture is mirrored left to right.");
    prop(c, "flip_v", PropType.Bool, Value.bool(false), "The texture is mirrored top to bottom.");
    prop(c, "modulate", PropType.Color, Value.color(1, 1, 1, 1), "Multiplies the texture's colour and alpha.");
    prop(c, "pixel_size", PropType.Float, f(0.01), "The size of one texture pixel in the scene, in metres.");
    enumProp(c, "axis", 2, ["x", "y", "z"], "The axis the quad faces when it is not a billboard.");
    enumProp(c, "billboard", 0, ["disabled", "enabled", "fixed_y"],
        "Whether the quad turns to the camera: not at all, wholly (it lies in the camera's plane), or about the scene's Y axis only.");
    prop(c, "transparent", PropType.Bool, Value.bool(true), "The texture's alpha is drawn; off, the quad is opaque.");
    prop(c, "shaded", PropType.Bool, Value.bool(false), "The scene's lights light the quad; off, the texture is drawn as it is.");
    prop(c, "double_sided", PropType.Bool, Value.bool(true), "The quad is drawn from behind too; off, it is not seen from behind.");
    prop(c, "no_depth_test", PropType.Bool, Value.bool(false), "The quad is drawn over everything, whatever is in front of it.");
    enumProp(c, "alpha_cut", 0, ["disabled", "discard", "opaque_prepass", "alpha_hash"],
        "How alpha is cut: blended (with transparent), cut out at alpha_scissor_threshold, or Godot's two other modes (drawn as blended and as cut out).");
    prop(c, "alpha_scissor_threshold", PropType.Float, f(0.5), "With alpha_cut discard: the alpha below which nothing is drawn.");

    // Milestone 19: baked lighting, Godot's LightmapGI and LightmapProbe
    // (docs/formats/RSCN.md, "LightmapGI"). Godot's camera_attributes and
    // shadowmask_mode are not in format 1 (kept as unknown properties).
    c = define(new ClassInfo("LightmapGI", "Node3D", true,
        "Bakes the light of the scene's static geometry into lightmaps (`" + CLI + " bake`), and draws the scene with them."));
    enumProp(c, "quality", 1, ["low", "medium", "high", "ultra"], "How many rays the bake traces: more is smoother and slower.");
    prop(c, "bounces", PropType.Int, Value.int(3), "How many times light bounces between surfaces in the bake (0: direct light only).");
    prop(c, "bounce_indirect_energy", PropType.Float, f(1), "Multiplies the light of every bounce.");
    prop(c, "directional", PropType.Bool, Value.bool(false),
        "Godot's directional lightmaps: not made here (the bake says so); the lightmaps hold the light from all around.");
    prop(c, "use_texture_for_bounces", PropType.Bool, Value.bool(true),
        "Bounced light takes the colour of the albedo textures it bounces off, not only of the albedo colours.");
    prop(c, "interior", PropType.Bool, Value.bool(false), "The scene is indoors: the environment adds no light to the bake.");
    prop(c, "use_denoiser", PropType.Bool, Value.bool(true), "Smooth the bake's noise.");
    prop(c, "denoiser_strength", PropType.Float, f(0.1), "How strongly the denoiser smooths (0 to 1).");
    prop(c, "denoiser_range", PropType.Int, Value.int(10), "How far the denoiser looks, in texels.");
    prop(c, "bias", PropType.Float, f(0.0005), "Moves the bake's rays off their surface, in metres, against acne.");
    prop(c, "texel_scale", PropType.Float, f(1), "Multiplies the texel density of every lightmap (2: twice the texels along each side).");
    prop(c, "max_texture_size", PropType.Int, Value.int(16384),
        "The largest lightmap image, in texels on a side; more charts go into more layers (the bake makes at most 4096).");
    prop(c, "lightmap_texel_size", PropType.Float, f(0.2),
        "The size of a lightmap texel on a surface, in metres, before texel_scale and gi_lightmap_texel_scale.");
    enumProp(c, "environment_mode", 1, ["disabled", "scene", "custom_sky", "custom_color"],
        "The light the environment adds to the bake: none, the scene's WorldEnvironment's, a sky of its own, or a colour.");
    res(c, "environment_custom_sky", "Sky", "With environment_mode custom_sky: the sky the bake sees (without one, no light).");
    prop(c, "environment_custom_color", PropType.Color, Value.color(1, 1, 1, 1), "With environment_mode custom_color: its colour.");
    prop(c, "environment_custom_energy", PropType.Float, f(1), "With environment_mode custom_sky or custom_color: its strength.");
    enumProp(c, "generate_probes_subdiv", 2, ["disabled", "4", "8", "16", "32"],
        "The automatic light probes: none, or a grid of this many cells along the static geometry's longest side, inside its box.");
    res(c, "light_data", "LightmapGIData", "The bake: an .lmbake file `" + CLI + " bake` writes; without it the scene is drawn with real-time light.");

    c = define(new ClassInfo("LightmapProbe", "Node3D", true,
        "A point where a LightmapGI's bake measures light for the geometry that is not lightmapped."));

    // Milestone 20: reflection probes, Godot's ReflectionProbe
    // (docs/formats/RSCN.md, "ReflectionProbe"). Godot's mesh_lod_threshold
    // is not in format 1 (kept as an unknown property).
    c = define(new ClassInfo("ReflectionProbe", "Node3D", true,
        "Captures the scene around it into a cube map that the geometry inside its box reflects (`" + CLI + " bake` captures it once)."));
    enumProp(c, "update_mode", 0, ["once", "always"],
        "once: captured by `" + CLI + " bake` into probe_data (without one, when first drawn); always: captured again as the scene is drawn.");
    prop(c, "intensity", PropType.Float, f(1), "Multiplies its reflections.");
    prop(c, "blend_distance", PropType.Float, f(1),
        "How far inside its box, from the faces, it fades in, in metres (0: no fade); overlapping probes blend over it.");
    prop(c, "max_distance", PropType.Float, f(0), "How far the capture sees, in metres (0: the box's diagonal).");
    prop(c, "size", PropType.Vector3, Value.vector3(20, 20, 20),
        "The box it reflects in, centred on the node, in metres along the node's axes (the node's scale is not used).");
    prop(c, "origin_offset", PropType.Vector3, Value.vector3(0, 0, 0),
        "Where it captures from, from the node's origin along its axes, in metres.");
    prop(c, "box_projection", PropType.Bool, Value.bool(false),
        "Reflections are corrected for where they are in the box (parallax), as for a room's walls.");
    prop(c, "interior", PropType.Bool, Value.bool(false),
        "Indoors: the capture sees no sky and takes no light from the environment.");
    prop(c, "enable_shadows", PropType.Bool, Value.bool(false), "The capture draws the lights' shadows.");
    prop(c, "cull_mask", PropType.Int, Value.int(1048575), "The visual layers it captures (GeometryInstance3D.layers).");
    prop(c, "reflection_mask", PropType.Int, Value.int(1048575), "The visual layers that reflect it.");
    enumProp(c, "ambient_mode", 1, ["disabled", "environment", "constant_color"],
        "The ambient light inside its box: disabled leaves the environment's, environment takes the capture's own, constant_color ambient_color.");
    prop(c, "ambient_color", PropType.Color, Value.color(0, 0, 0, 1), "With ambient_mode constant_color: the ambient light's colour.");
    prop(c, "ambient_color_energy", PropType.Float, f(1), "Multiplies ambient_color.");
    res(c, "probe_data", "ReflectionProbeData",
        "Its capture: an .rprobe file `" + CLI + " bake` writes; without one, a once probe is captured when first drawn.");

    // Milestone 27: Godot's Timer, a Node (not 3D) that counts down while
    // the scene plays and emits `timeout` (RSCN.md, "Timer").
    c = define(new ClassInfo("Timer", "Node", true,
        "Counts wait_time seconds down while the scene plays, then emits the signal timeout, which connections and scripts hear."));
    prop(c, "wait_time", PropType.Float, f(1), "The seconds it counts, more than 0.");
    prop(c, "one_shot", PropType.Bool, Value.bool(false), "It stops after one timeout; off, it starts over each time.");
    prop(c, "autostart", PropType.Bool, Value.bool(false), "It starts when the scene starts (when the node is first ready).");
    prop(c, "paused", PropType.Bool, Value.bool(false), "It does not count while true.");
    c.signals = ["timeout()"];

    // Milestone 31: interaction without a physics simulation, Godot's
    // classes (RSCN.md, "Interaction"): areas that detect what overlaps
    // them, static bodies, their shapes, and rays. Nothing moves by itself;
    // what scripts, tweens, bindings and animations move is detected.
    c = define(new ClassInfo("CollisionObject3D", "Node3D", true,
        "The base of the nodes that have collision shapes (its CollisionShape3D children): areas and bodies."));
    c.isAbstract = true;
    prop(c, "collision_layer", PropType.Int, Value.int(1),
        "The layers it is in (bit k: layer k + 1), which other objects' collision_mask and queries' masks find it by.");
    prop(c, "collision_mask", PropType.Int, Value.int(1),
        "The layers it finds others in: an Area3D detects what is in a layer of its mask.");
    prop(c, "input_ray_pickable", PropType.Bool, Value.bool(true),
        "The pointer picks it: it gets input_event, mouse_entered and mouse_exited.");
    prop(c, "input_capture_on_drag", PropType.Bool, Value.bool(false),
        "A press on it keeps its input_event coming while the pointer is dragged off it, until the release.");
    c.signals = [
        "input_event(camera, event, event_position, normal, shape_idx)", "mouse_entered()", "mouse_exited()",
    ];

    c = define(new ClassInfo("PhysicsBody3D", "CollisionObject3D", true,
        "The base of the bodies; nothing is simulated, so StaticBody3D is the one body."));
    c.isAbstract = true;

    c = define(new ClassInfo("StaticBody3D", "PhysicsBody3D", true,
        "A body: what areas detect as a body, and rays and the pointer hit; it moves only when something moves it."));

    c = define(new ClassInfo("Area3D", "CollisionObject3D", true,
        "A region that detects the bodies and areas overlapping it, and the pointer over it."));
    prop(c, "monitoring", PropType.Bool, Value.bool(true),
        "It detects what overlaps it and emits body_entered, body_exited, area_entered and area_exited.");
    prop(c, "monitorable", PropType.Bool, Value.bool(true), "Other areas detect it.");
    c.signals = ["body_entered(body)", "body_exited(body)", "area_entered(area)", "area_exited(area)"];

    c = define(new ClassInfo("CollisionShape3D", "Node3D", true,
        "Gives its parent CollisionObject3D a shape, placed by its own transform."));
    res(c, "shape", "Shape3D", "The shape: a box, sphere, capsule, cylinder, convex or concave polygon.");
    prop(c, "disabled", PropType.Bool, Value.bool(false), "The shape takes no part: no overlap, ray or pick finds it.");

    c = define(new ClassInfo("RayCast3D", "Node3D", true,
        "A ray from the node's origin to target_position, cast every frame while the scene plays; scripts read what it hits."));
    prop(c, "enabled", PropType.Bool, Value.bool(true), "It casts every frame.");
    prop(c, "exclude_parent", PropType.Bool, Value.bool(true), "Its parent, when a CollisionObject3D, is never hit.");
    prop(c, "target_position", PropType.Vector3, Value.vector3(0, -1, 0),
        "Where the ray ends, in the node's own space; it starts at the node's origin.");
    prop(c, "collision_mask", PropType.Int, Value.int(1), "The layers it hits objects in (their collision_layer).");
    prop(c, "hit_from_inside", PropType.Bool, Value.bool(false),
        "A ray starting inside a shape hits it at its start, with a zero normal; off, that shape is not hit.");
    prop(c, "hit_back_faces", PropType.Bool, Value.bool(true),
        "It hits the back of a ConcavePolygonShape3D's faces when the shape's backface_collision is on.");
    prop(c, "collide_with_areas", PropType.Bool, Value.bool(false), "It hits Area3D shapes.");
    prop(c, "collide_with_bodies", PropType.Bool, Value.bool(true), "It hits StaticBody3D shapes.");
    prop(c, "debug_shape_custom_color", PropType.Color, Value.color(0, 0, 0, 1),
        "The colour its line is drawn in by `render --shapes` and in the editor; black: the default colour.");
    prop(c, "debug_shape_thickness", PropType.Int, Value.int(2), "Its line's width in pixels when drawn, 1 to 5.");

    // Milestone 48: a model's armature and the nodes that follow its bones
    // (RSCN.md, "Skeletons"; docs/plans/RIVE_MODEL.md section 3.7).
    c = define(new ClassInfo("Skeleton3D", "Node3D", true,
        "A model's armature: its bones, posed by its `bones/<bone>:position`, `bones/<bone>:quaternion` and `bones/<bone>:scale` properties (the model's pose when not set; they animate, a vector by its components, and are not bindable), by timelines and by scripts. Made from a model; see \"Skeletons\"."));
    family(c, "bones/<bone>:position", FAMILY_BONE_POSITION, PropType.Vector3, Value.vector3(0, 0, 0), true, false,
        "The bone's position relative to its parent bone (the skeleton for a root bone), in metres.");
    family(c, "bones/<bone>:quaternion", FAMILY_BONE_QUATERNION, PropType.Quaternion, Value.quaternion(0, 0, 0, 1), true, false,
        "The bone's rotation relative to its parent bone, keyed whole (KeyFrameQuaternion).");
    family(c, "bones/<bone>:scale", FAMILY_BONE_SCALE, PropType.Vector3, Value.vector3(1, 1, 1), true, false,
        "The bone's scale.");
    c = define(new ClassInfo("BoneAttachment3D", "Node3D", true,
        "Follows a bone of the Skeleton3D it is a child of: its transform is the bone's pose, so what is under it moves with the bone."));
    prop(c, "bone_name", PropType.StringName, Value.str(""), "The bone it follows.");
    prop(c, "bone_idx", PropType.Int, Value.int(-1),
        "The bone's index in the skeleton, used when bone_name is empty; -1 for none.");

    // Milestone 32: paths, Godot's Path3D and PathFollow3D (RSCN.md,
    // "Paths"): a curve in the node's space, and nodes placed along it by
    // their progress, for camera rails, moving platforms and objects on
    // tracks. Their numbers, choice and switches take Rive's flags as any
    // node's (animates, bindable). Godot's PathFollow3D.progress_ratio is
    // not stored (Godot's is an editor-only property): it is `derived`, a
    // property timelines key and bindings drive like any other, read and
    // written through `progress`.
    c = define(new ClassInfo("Path3D", "Node3D", true,
        "A curve in the node's space (a Curve3D); its PathFollow3D children are placed along it."));
    res(c, "curve", "Curve3D", "The curve: Bézier points with in and out handles and tilts.");
    c.signals = ["curve_changed()"];

    c = define(new ClassInfo("PathFollow3D", "Node3D", true,
        "Placed on its parent Path3D's curve, progress metres along it, and turned to follow it by rotation_mode."));
    prop(c, "progress", PropType.Float, f(0),
        "How far along the curve it is, in metres; set while the scene plays it wraps round with loop, else it is held to the curve.");
    const ratio = prop(c, "progress_ratio", PropType.Float, f(0),
        "progress as a share of the curve's baked length, 0 at its start and 1 at its end; not stored: keyed, bound and edited, it sets progress.");
    ratio.derived = true;
    prop(c, "h_offset", PropType.Float, f(0), "How far it sits to the side of the curve, along its own x, in metres.");
    prop(c, "v_offset", PropType.Float, f(0), "How far it sits above the curve, along its own y, in metres.");
    enumProp(c, "rotation_mode", 3, ["none", "y", "xy", "xyz", "oriented"],
        "How it turns with the curve: not at all, about y only, about x and y, about all three, or oriented (its -z along the curve and its y the curve's up).");
    prop(c, "use_model_front", PropType.Bool, Value.bool(false),
        "Its +z, a model's front (glTF's), faces along the curve rather than its -z (Godot's forward).");
    prop(c, "cubic_interp", PropType.Bool, Value.bool(true),
        "Its position between baked points is interpolated cubically; off, linearly.");
    prop(c, "loop", PropType.Bool, Value.bool(true), "A progress past either end wraps round to the other.");
    prop(c, "tilt_enabled", PropType.Bool, Value.bool(true), "It leans by the curve's tilts (with any rotation_mode but none).");

    // Milestone 33: Godot's Decal (RSCN.md, "Decals"): textures projected
    // along the node's -Y, through a box of `size` centred on it, onto the
    // surfaces inside the box whose layers meet its cull_mask. Godot's
    // names, defaults and order (its groups Textures, Parameters, Vertical
    // Fade, Distance Fade and Cull Mask). Its numbers, colour and switch
    // take Rive's flags as any node's (animates, bindable); its textures
    // and cull_mask do not (resources, and a plain int mask, as
    // GeometryInstance3D.layers). Godot's Decal is a VisualInstance3D,
    // whose `layers` are not in format 1 (nothing draws a decal into a
    // probe's capture by them).
    c = define(new ClassInfo("Decal", "Node3D", true,
        "Projects its textures along its -Y axis onto the surfaces inside its box (size, centred on the node), as Godot's Decal: colour, a normal map, occlusion-roughness-metallic and emission, any of them an ArtboardTexture."));
    prop(c, "size", PropType.Vector3, Value.vector3(2, 2, 2),
        "The box it projects through, centred on the node, in metres along the node's axes (each at least 0.001); it projects along -Y.");
    pngTexture(c, "texture_albedo",
        "The colour and alpha it paints; its alpha also blends the normal and ORM maps in. Without it, only emission is drawn.");
    pngTexture(c, "texture_normal",
        "A normal map blended over the surface's normal by the albedo's alpha (OpenGL's convention, green up the picture, as Godot reads it); needs texture_albedo.");
    pngTexture(c, "texture_orm",
        "Ambient occlusion (red), roughness (green) and metallic (blue), blended over the surface's by the albedo's alpha; needs texture_albedo.");
    pngTexture(c, "texture_emission", "Light it adds, times modulate and emission_energy, whatever the albedo.");
    prop(c, "emission_energy", PropType.Float, f(1), "Multiplies texture_emission.");
    prop(c, "modulate", PropType.Color, Value.color(1, 1, 1, 1),
        "Multiplies the albedo and the emission; its alpha fades the whole decal.");
    prop(c, "albedo_mix", PropType.Float, f(1),
        "How much of the albedo's colour covers the surface, 0 to 1; at 0 only the normal, ORM and emission maps show.");
    prop(c, "normal_fade", PropType.Float, f(0),
        "Fades the decal on surfaces turned away from its projection: 0 never, towards 1 only where they face it squarely.");
    prop(c, "upper_fade", PropType.Float, f(0.3),
        "How it fades towards the top of its box (an exponent: 0 no fade, higher fades sooner).");
    prop(c, "lower_fade", PropType.Float, f(0.3),
        "How it fades towards the bottom of its box (an exponent: 0 no fade, higher fades sooner).");
    prop(c, "distance_fade_enabled", PropType.Bool, Value.bool(false),
        "It fades out with its distance to the camera, from distance_fade_begin over distance_fade_length, and is not drawn beyond.");
    prop(c, "distance_fade_begin", PropType.Float, f(40),
        "With distance_fade_enabled: the distance from the camera where it starts to fade, in metres.");
    prop(c, "distance_fade_length", PropType.Float, f(10),
        "With distance_fade_enabled: how far it takes to fade out, in metres.");
    prop(c, "cull_mask", PropType.Int, Value.int(1048575),
        "The visual layers it paints (GeometryInstance3D.layers, bit k layer k + 1).");

    // Milestone 34: Godot's Viewport and SubViewport (docs/formats/RSCN.md,
    // "Viewports"): a SubViewport draws the 3D world through its own
    // Camera3D into a texture of `size` pixels, which a ViewportTexture
    // names and any texture slot takes. Godot's class chain, names, defaults
    // and enum numbers; of Viewport, only own_world_3d and transparent_bg
    // are in format 2 (msaa_3d, screen_space_aa, use_taa, the 2D and XR
    // properties, the scaling and the rest are kept as unknown properties,
    // as any other), and of SubViewport size and render_target_update_mode
    // (size_2d_override and render_target_clear_mode likewise). Both are
    // Nodes, not Node3Ds, as in Godot: a Node3D under one starts its
    // transforms afresh. `size` is a Vector2i, which takes no flags (a new
    // size makes new render targets); the update mode, the world and the
    // background animate and bind, own_world_3d costly (the plan is made
    // again).
    c = define(new ClassInfo("Viewport", "Node", true, "The base of the viewports: what a SubViewport's world and background are."));
    c.isAbstract = true;
    prop(c, "own_world_3d", PropType.Bool, Value.bool(false),
        "Draws a world of its own, holding only the nodes under it (their lights and WorldEnvironment too); off, the world of the viewport it is in.");
    prop(c, "transparent_bg", PropType.Bool, Value.bool(false),
        "Its background is transparent: neither the sky nor the background colour is drawn, so its texture's alpha is 0 where nothing is.");
    c = define(new ClassInfo("SubViewport", "Viewport", true,
        "Draws the 3D world through its own current Camera3D into a texture of `size` pixels, which a ViewportTexture shows in any texture slot: in-world screens, security cameras, mirrors, minimaps."));
    prop(c, "size", PropType.Vector2i, Value.numbers(ValueKind.Vector2i, [512, 512]),
        "The texture's size in pixels, 1 to 4096 each.");
    enumProp(c, "render_target_update_mode", 2, ["disabled", "once", "when_visible", "when_parent_visible", "always"],
        "When it draws again: never (the texture keeps its last picture), once, while its texture was drawn in the last frame, while its parent is visible, or every frame.");

    // Milestone 35: Godot's CPUParticles3D (docs/formats/RSCN.md
    // "Particles", docs/engine/PARTICLES.md): particles simulated on the CPU
    // from a seed and the frame clock, drawn as one instanced draw of `mesh`.
    // Godot's names, defaults and enum numbers, group by group as Godot's
    // inspector shows them; Hedra adds emission_points_from and
    // emission_points_count (the points of a mesh, which Godot's editor
    // bakes into emission_points: here they are computed when the scene
    // loads, and at build). Godot's accelerations (linear, radial,
    // tangential), orbit velocity, animation frames and
    // particle_flag_disable_z are not in the format: kept as unknown
    // properties. The numbers, bools, colours, vectors and choices animate
    // and bind (emitting above all: a timeline keys it, a state machine
    // plays the timeline); amount, seed and fixed_fps are plain ints and
    // take no flags; the curves and gradients are resources.
    c = define(new ClassInfo("CPUParticles3D", "GeometryInstance3D", true,
        "Emits particles simulated on the CPU, deterministically from its seed and the frame clock, each one a copy of `mesh` drawn with GPU instancing; emits the signal finished when a one_shot emission has ended."));
    prop(c, "emitting", PropType.Bool, Value.bool(true),
        "It emits new particles; off, those alive live their lifetime out. Turned on after a one_shot emission ended, it starts again.");
    const amount = prop(c, "amount", PropType.Int, Value.int(8),
        "How many particles an emission cycle (lifetime seconds) emits, 1 to 10000; each one is drawn while it lives.");
    amount.nonNegative = true;
    prop(c, "lifetime", PropType.Float, f(1), "The seconds a particle lives (at least 0.01): one emission cycle.");
    prop(c, "one_shot", PropType.Bool, Value.bool(false), "It emits one cycle, then stops (emitting turns off and finished is emitted).");
    prop(c, "preprocess", PropType.Float, f(0), "Seconds simulated before the first frame, so it starts mid-flow.");
    prop(c, "speed_scale", PropType.Float, f(1), "Multiplies the time it is simulated at (0 freezes it).");
    prop(c, "explosiveness", PropType.Float, f(0),
        "0 spreads a cycle's particles over its lifetime; 1 emits them all at once, 0 to 1.");
    prop(c, "randomness", PropType.Float, f(0), "How much each particle's emission time varies, 0 to 1.");
    prop(c, "lifetime_randomness", PropType.Float, f(0), "How much shorter a particle's lifetime may be, 0 to 1.");
    prop(c, "use_fixed_seed", PropType.Bool, Value.bool(false),
        "Every emission uses seed; off, the seed is made from the node's path, so emitters differ and stay deterministic.");
    const seed = prop(c, "seed", PropType.Int, Value.int(0), "The random seed with use_fixed_seed, 0 to 4294967295.");
    seed.nonNegative = true;
    const fps = prop(c, "fixed_fps", PropType.Int, Value.int(0),
        "Simulates at this many steps a second whatever the frame rate (0: a step a frame, as long as the frame).");
    fps.nonNegative = true;
    prop(c, "fract_delta", PropType.Bool, Value.bool(true),
        "A particle emitted within a step moves for the part of the step after its emission, which smooths a fast flow.");
    prop(c, "local_coords", PropType.Bool, Value.bool(false),
        "Particles move with the node; off, they stay in the scene where they were emitted when the node moves.");
    enumProp(c, "draw_order", 0, ["index", "lifetime", "view_depth", "reverse_lifetime"],
        "The order the particles are drawn in: as emitted, oldest first, farthest from the camera first (for blended ones), or youngest first.");
    res(c, "mesh", "Mesh", "The mesh each particle draws: a QuadMesh with a billboard material for sprites, or any mesh.");
    enumProp(c, "emission_shape", 0, ["point", "sphere", "sphere_surface", "box", "points", "directed_points", "ring"],
        "Where particles start: the origin, in or on a sphere, in a box, at emission_points (directed: along emission_normals), or in a ring.");
    prop(c, "emission_sphere_radius", PropType.Float, f(1), "The sphere's radius.");
    prop(c, "emission_box_extents", PropType.Vector3, Value.vector3(1, 1, 1), "The box's half size on each axis.");
    prop(c, "emission_points", PropType.PackedVector3Array, Value.packedVector3s([]),
        "The points particles start at, one chosen at random each time (points and directed_points).");
    prop(c, "emission_normals", PropType.PackedVector3Array, Value.packedVector3s([]),
        "With directed_points, a direction per point that turns `direction` (as many as emission_points).");
    prop(c, "emission_colors", PropType.PackedColorArray, Value.packedColors([]),
        "A colour per point, multiplying `color` (as many as emission_points).");
    prop(c, "emission_ring_axis", PropType.Vector3, Value.vector3(0, 0, 1), "The ring's axis.");
    prop(c, "emission_ring_height", PropType.Float, f(1), "The ring's height along its axis.");
    prop(c, "emission_ring_radius", PropType.Float, f(1), "The ring's outer radius.");
    prop(c, "emission_ring_inner_radius", PropType.Float, f(0), "The ring's inner radius (0: a disc).");
    prop(c, "emission_ring_cone_angle", PropType.Float, f(90),
        "The angle of the ring's side in degrees: 90 a cylinder, less a cone narrowing along the axis.");
    prop(c, "emission_points_from", PropType.NodePath, Value.nodePath(""),
        "A MeshInstance3D or ModelInstance3D whose surface fills emission_points (and emission_normals) when they are empty, in this node's space at load and at build.");
    const pointsCount = prop(c, "emission_points_count", PropType.Int, Value.int(512),
        "How many points emission_points_from samples, 1 to 65536.");
    pointsCount.nonNegative = true;
    prop(c, "particle_flag_align_y", PropType.Bool, Value.bool(false), "Each particle's Y axis points along its velocity.");
    prop(c, "particle_flag_rotate_y", PropType.Bool, Value.bool(false), "Each particle turns about its Y axis by its angle.");
    prop(c, "direction", PropType.Vector3, Value.vector3(1, 0, 0), "The direction particles are emitted in.");
    prop(c, "spread", PropType.Float, f(45), "How far from `direction` a particle may set off, in degrees, 0 to 180.");
    prop(c, "flatness", PropType.Float, f(0), "Flattens the spread onto the plane across `direction`'s up side, 0 to 1.");
    prop(c, "gravity", PropType.Vector3, Value.vector3(0, -9.8, 0), "The acceleration every particle takes, in metres a second squared.");
    prop(c, "initial_velocity_min", PropType.Float, f(0), "The least speed a particle starts at.");
    prop(c, "initial_velocity_max", PropType.Float, f(0), "The greatest speed a particle starts at.");
    prop(c, "angular_velocity_min", PropType.Float, f(0), "The least speed its angle turns at, degrees a second.");
    prop(c, "angular_velocity_max", PropType.Float, f(0), "The greatest speed its angle turns at, degrees a second.");
    res(c, "angular_velocity_curve", "Curve", "Multiplies the angular velocity over a particle's life (0 to 1).");
    prop(c, "damping_min", PropType.Float, f(0), "The least a particle slows by, metres a second each second.");
    prop(c, "damping_max", PropType.Float, f(0), "The most a particle slows by, metres a second each second.");
    res(c, "damping_curve", "Curve", "Multiplies the damping over a particle's life.");
    prop(c, "angle_min", PropType.Float, f(0), "The least angle a particle starts at, degrees (a billboard's roll, particle_flag_rotate_y's turn).");
    prop(c, "angle_max", PropType.Float, f(0), "The greatest angle a particle starts at, degrees.");
    res(c, "angle_curve", "Curve", "Multiplies the angle over a particle's life.");
    prop(c, "scale_amount_min", PropType.Float, f(1), "The least scale a particle has.");
    prop(c, "scale_amount_max", PropType.Float, f(1), "The greatest scale a particle has.");
    res(c, "scale_amount_curve", "Curve", "Multiplies the scale over a particle's life.");
    prop(c, "split_scale", PropType.Bool, Value.bool(false), "Scales each axis by its own curve (scale_curve_x, _y, _z) in place of scale_amount_curve.");
    res(c, "scale_curve_x", "Curve", "With split_scale, multiplies the scale along X over a particle's life.");
    res(c, "scale_curve_y", "Curve", "With split_scale, multiplies the scale along Y over a particle's life.");
    res(c, "scale_curve_z", "Curve", "With split_scale, multiplies the scale along Z over a particle's life.");
    prop(c, "color", PropType.Color, Value.color(1, 1, 1, 1),
        "Each particle's colour, which multiplies the albedo of a material with vertex_color_use_as_albedo.");
    res(c, "color_ramp", "Gradient", "Multiplies the colour over a particle's life.");
    res(c, "color_initial_ramp", "Gradient", "Multiplies the colour by a point of it chosen at random for each particle.");
    prop(c, "hue_variation_min", PropType.Float, f(0), "The least a particle's hue is turned by, -1 to 1 (a whole turn).");
    prop(c, "hue_variation_max", PropType.Float, f(0), "The most a particle's hue is turned by, -1 to 1.");
    res(c, "hue_variation_curve", "Curve", "Multiplies the hue variation over a particle's life.");
    c.signals = ["finished()"];

    // Milestone 36: Godot 4.4's AudioStreamPlayer3D and AudioListener3D
    // (docs/formats/RSCN.md "Audio", docs/engine/AUDIO.md): a sound played
    // from a point of the scene through the Rive runtime's audio (the
    // stream is a Rive AudioAsset the build declares), its volume Godot's
    // attenuation of the distance to the listener and its stereo balance
    // Godot's panning, both computed each frame. Godot's names, defaults
    // and enum numbers in its inspector's order. The numbers, bools and
    // choices animate and bind (playing above all: a timeline keys it, a
    // state machine plays the timeline, a view model drives it);
    // max_polyphony and area_mask are plain ints and bus a name: no flags.
    // What the runtime cannot do is kept and warned about (AUDIO.md
    // "Where we differ from Godot"): the pitch, the bus, the attenuation
    // filter, Doppler and the playback type. Hedra adds two outputs: what
    // the listener hears of the player, for a 2D meter.
    c = define(new ClassInfo("AudioStreamPlayer3D", "Node3D", true,
        "Plays a sound from its place in the scene: its volume falls with the distance to the listener (attenuation_model, unit_size, max_distance) and it is panned to the listener's left or right; emits the signal finished when a playback ends."));
    res(c, "stream", "AudioStream", "The sound: a WAV, MP3 or FLAC file (an AudioStream ext_resource), declared as a Rive audio asset by the build.");
    enumProp(c, "attenuation_model", 0, ["inverse_distance", "inverse_square_distance", "logarithmic", "disabled"],
        "How the volume falls with the distance d to the listener: as unit_size / d, as its square, by 20 ln(d / unit_size) dB, or not at all.");
    prop(c, "volume_db", PropType.Float, f(0), "The volume at unit_size from the listener, in dB (-80 to 80).");
    prop(c, "unit_size", PropType.Float, f(10), "The distance, in metres, at which the volume is volume_db (0.1 to 100): larger is heard farther.");
    prop(c, "max_db", PropType.Float, f(3), "The loudest the sound is heard, however near, in dB (-24 to 6).");
    prop(c, "pitch_scale", PropType.Float, f(1),
        "Godot's playback speed; kept and not applied: the runtime plays a sound at its own rate (audio-pitch).");
    prop(c, "playing", PropType.Bool, Value.bool(false),
        "Whether it plays: turned on, it plays from the start; off, it stops. It reads false again once its last playback has ended.");
    prop(c, "autoplay", PropType.Bool, Value.bool(false), "It plays from the start when the scene starts.");
    prop(c, "stream_paused", PropType.Bool, Value.bool(false), "Its playbacks hold where they are; off, they go on.");
    prop(c, "max_distance", PropType.Float, f(0),
        "Beyond this distance it is not heard, fading to silence on the way there (0: no limit; up to 4096 m).");
    const polyphony = prop(c, "max_polyphony", PropType.Int, Value.int(1),
        "How many playbacks may overlap (1 to 8): a play past it stops the oldest.");
    polyphony.nonNegative = true;
    prop(c, "panning_strength", PropType.Float, f(1),
        "How far it is panned to the listener's side (0 centred, 1 Godot's, up to 3); a stream without its left and right forms plays centred (audio-not-panned).");
    prop(c, "bus", PropType.StringName, Value.str("Master"), "Godot's bus; kept: every sound plays on the runtime's one mix (audio-bus).");
    const areaMask = prop(c, "area_mask", PropType.Int, Value.int(1), "Godot's area mask for reverb buses; kept, not used.");
    areaMask.nonNegative = true;
    enumProp(c, "playback_type", 0, ["default", "stream", "sample"], "Godot's playback type; kept, not used: the runtime decides.");
    prop(c, "emission_angle_enabled", PropType.Bool, Value.bool(false),
        "It is heard fully only within emission_angle_degrees of its -Z axis.");
    prop(c, "emission_angle_degrees", PropType.Float, f(45),
        "The half-angle of the cone it is heard fully in, degrees (0.1 to 90).");
    prop(c, "emission_angle_filter_attenuation_db", PropType.Float, f(-12),
        "How much quieter it is outside the cone, in dB (-80 to 0): the whole sound, where Godot cuts its high frequencies.");
    prop(c, "attenuation_filter_cutoff_hz", PropType.Float, f(5000),
        "Godot's high-frequency cut with distance; kept and not applied: the runtime has no filters (audio-filter).");
    prop(c, "attenuation_filter_db", PropType.Float, f(-24), "Godot's high-frequency cut with distance, in dB; kept and not applied.");
    enumProp(c, "doppler_tracking", 0, ["disabled", "idle_step", "physics_step"],
        "Godot's Doppler effect; kept and not applied: the runtime has no pitch (audio-doppler).");
    output(prop(c, "listener_volume_db", PropType.Float, f(-80),
        "What the listener hears of it, in dB: volume_db attenuated by the distance, max_distance and the emission angle; -80 when silent or not playing (computed: bind it with mode=\"to_source\")."));
    output(prop(c, "listener_pan", PropType.Float, f(0),
        "Where the listener hears it, -1 left to 1 right; 0 centred or not playing (computed)."));
    c.signals = ["finished()"];

    // Godot's AudioListener3D: the ear the players are heard from (the last
    // current one, else the first: ./audio/listener.as); with none,
    // the camera the scene is seen through.
    c = define(new ClassInfo("AudioListener3D", "Node3D", true,
        "The point and the facing sounds are heard from while it is the scene's listener (current, or the first listener when none is); with no listener, the camera the scene is seen through hears them."));
    prop(c, "current", PropType.Bool, Value.bool(false),
        "This listener hears the scene's players (the last current one in tree order when several are; the first listener when none is, as Godot makes the first to enter current).");

    // Milestone 37: Godot's FogVolume (docs/formats/RSCN.md "Fog volumes",
    // docs/engine/FOG.md): local fog in a box, an ellipsoid, a cone or a
    // cylinder of `size` (or the whole world), its look its FogMaterial's,
    // drawn while the Environment's volumetric fog is on, as in Godot.
    // Godot's names, defaults and enum numbers (RenderingServer's
    // FogVolumeShape); `size` and `shape` animate and bind, the material's
    // properties through `material:<p>`.
    c = define(new ClassInfo("FogVolume", "Node3D", true,
        "Local fog in a box, an ellipsoid, a cone or a cylinder (or everywhere), as its FogMaterial describes it; drawn while the Environment's volumetric_fog_enabled is on."));
    prop(c, "size", PropType.Vector3, Value.vector3(2, 2, 2),
        "The shape's size in metres along the node's axes (the world shape has none); a cone or a cylinder is as wide as the smaller of x and z.");
    enumProp(c, "shape", 3, ["ellipsoid", "cone", "cylinder", "box", "world"],
        "The fog's shape: an ellipsoid, a cone pointing up its Y axis, a cylinder along Y, a box, or the whole world.");
    res(c, "material", "Material",
        "The fog's look: a FogMaterial (none: Godot's default, a white fog of density 1).");

    // Milestone 37: Godot's OccluderInstance3D (docs/formats/RSCN.md
    // "Occlusion culling", docs/engine/OCCLUSION.md): its occluder hides
    // what is wholly behind it from the renderer, tested on the CPU. Its
    // bake settings take no flags (a bake reads them, as a LightmapGI's);
    // `visible` turns it off, keyed or bound.
    c = define(new ClassInfo("OccluderInstance3D", "Node3D", true,
        "An occluder: the objects wholly behind its shape, seen from the camera, are not drawn (occlusion culling on the CPU); `hedra bake --occluders` makes its shape from the scene's static geometry."));
    res(c, "occluder", "Occluder3D",
        "Its shape: a BoxOccluder3D, SphereOccluder3D, QuadOccluder3D or PolygonOccluder3D, or an ArrayOccluder3D (a baked .occ file).");
    const bakeMask = prop(c, "bake_mask", PropType.Int, Value.int(4294967295),
        "The visual layers a bake takes geometry from (GeometryInstance3D.layers, bit k layer k + 1).");
    bakeMask.nonNegative = true;
    prop(c, "bake_simplification_distance", PropType.Float, f(0.1),
        "How far, in metres, a bake may move the baked shape's surface to simplify it (0: not simplified).");

    // Milestone 63: Godot 4.4's navigation (docs/formats/RSCN.md
    // "Navigation", docs/engine/NAVIGATION.md): regions holding a baked
    // NavigationMesh, which the scene's map joins by their shared edges
    // (./navigation/), links between two points of it, agents that find
    // their way over it and avoid each other, and obstacles they avoid.
    // Godot's names, defaults and enum numbers in its inspector's order.
    // The numbers, switches, choices and vectors animate and bind (an
    // agent's target_position above all: a view model says where it goes);
    // the layer masks and max_neighbors are plain ints, without flags, as
    // collision_layer is. Hedra adds the agent's drive_parent and
    // drive_turn_speed (it moves its parent itself) and four outputs.
    c = define(new ClassInfo("NavigationRegion3D", "Node3D", true,
        "A part of the scene's navigation map: its NavigationMesh's polygons, placed by the node's transform, joined to the other regions' where their edges meet; `hedra bake --navmesh` bakes the mesh from the scene's geometry."));
    res(c, "navigation_mesh", "NavigationMesh",
        "Its polygons and the settings they are baked with: a NavigationMesh sub_resource.");
    prop(c, "enabled", PropType.Bool, Value.bool(true), "Its polygons are in the map; off, no path crosses it.");
    prop(c, "use_edge_connections", PropType.Bool, Value.bool(true),
        "Its free edges join other regions' free edges within the map's edge_connection_margin.");
    const regionLayers = prop(c, "navigation_layers", PropType.Int, Value.int(1),
        "The navigation layers it is in (bit k: layer k + 1): a path query finds it only through a layer of its mask.");
    regionLayers.nonNegative = true;
    prop(c, "enter_cost", PropType.Float, f(0), "What a path pays to enter it from another region, added to the path's cost.");
    prop(c, "travel_cost", PropType.Float, f(1), "What a path pays per metre within it (a multiplier of the distance).");
    c.signals = ["navigation_mesh_changed()", "bake_finished()"];

    // Godot's NavigationAgent3D is a Node, not a Node3D: it steers its
    // parent, the Node3D a script (or, Hedra's, drive_parent) moves.
    c = define(new ClassInfo("NavigationAgent3D", "Node", true,
        "Finds a path over the navigation map from its parent Node3D to target_position, follows it waypoint by waypoint, avoids other agents and obstacles when avoidance_enabled, and emits Godot's signals (target_reached, navigation_finished, velocity_computed, ...); with drive_parent it moves its parent itself."));
    prop(c, "target_position", PropType.Vector3, Value.vector3(0, 0, 0),
        "Where it goes, global (scene space, metres): setting it asks for a new path.");
    prop(c, "path_desired_distance", PropType.Float, f(1),
        "How near its parent must come to a waypoint for it to go on to the next.");
    prop(c, "target_desired_distance", PropType.Float, f(1),
        "How near its parent must come to the target for it to be reached (target_reached).");
    prop(c, "path_height_offset", PropType.Float, f(0),
        "How far below the navigation mesh its parent's origin is (a baked mesh floats above its floor): subtracted from the height of every point of its path.");
    prop(c, "path_max_distance", PropType.Float, f(5),
        "How far its parent may stray from its path before a new one is asked for.");
    const agentLayers = prop(c, "navigation_layers", PropType.Int, Value.int(1),
        "The navigation layers its paths may cross (bit k: layer k + 1).");
    agentLayers.nonNegative = true;
    enumProp(c, "pathfinding_algorithm", 0, ["astar"], "How a path is searched: A* over the map's polygons.");
    enumProp(c, "path_postprocessing", 0, ["corridorfunnel", "edgecentered", "none"],
        "How the polygons found become points: the shortest line through them (the corridor funnel), the middle of each edge crossed, or each polygon's entry point.");
    const metadata = prop(c, "path_metadata_flags", PropType.Int, Value.int(7),
        "What a path keeps besides its points (1 the types, 2 the owners (Godot's RIDs), 4 the owners and their ids; Godot's PathMetadataFlags). A drive_parent agent's query always asks for the types, which its move needs to follow links.");
    metadata.nonNegative = true;
    prop(c, "simplify_path", PropType.Bool, Value.bool(false), "Its path is simplified: points within simplify_epsilon of the line are left out.");
    prop(c, "simplify_epsilon", PropType.Float, f(0), "How far, in metres, a point may lie off the simplified path.");
    prop(c, "avoidance_enabled", PropType.Bool, Value.bool(false),
        "It avoids the other agents and the obstacles of its avoidance_mask: velocity in, the safe velocity out (velocity_computed).");
    prop(c, "velocity", PropType.Vector3, Value.vector3(0, 0, 0),
        "The velocity it wants (Godot's: set by a script each frame); the avoidance answers with velocity_computed.");
    prop(c, "height", PropType.Float, f(1), "Its height, for avoidance in 3D (use_3d_avoidance) and Visible Navigation.");
    prop(c, "radius", PropType.Float, f(0.5), "Its radius in the avoidance, in metres.");
    prop(c, "neighbor_distance", PropType.Float, f(50), "How far, in metres, it looks for agents to avoid.");
    const neighbours = prop(c, "max_neighbors", PropType.Int, Value.int(10), "The most agents it avoids at once, the nearest.");
    neighbours.nonNegative = true;
    prop(c, "time_horizon_agents", PropType.Float, f(1),
        "How far ahead, in seconds, it avoids other agents: longer is safer and turns sooner.");
    prop(c, "time_horizon_obstacles", PropType.Float, f(0), "How far ahead, in seconds, it avoids obstacles.");
    prop(c, "max_speed", PropType.Float, f(10), "The fastest it goes, metres a second: the avoidance's limit, and drive_parent's speed.");
    prop(c, "use_3d_avoidance", PropType.Bool, Value.bool(false),
        "Godot's avoidance in 3D; kept and not applied: Hedra avoids on the ground plane (navigation-3d-avoidance).");
    prop(c, "keep_y_velocity", PropType.Bool, Value.bool(true), "The safe velocity keeps the vertical part of velocity.");
    const avoidLayers = prop(c, "avoidance_layers", PropType.Int, Value.int(1), "The avoidance layers it is in (bit k: layer k + 1).");
    avoidLayers.nonNegative = true;
    const avoidMask = prop(c, "avoidance_mask", PropType.Int, Value.int(1), "The avoidance layers of the agents and obstacles it avoids.");
    avoidMask.nonNegative = true;
    prop(c, "avoidance_priority", PropType.Float, f(1),
        "0 to 1: it is avoided by agents of a lower priority and avoids those of a higher one without them avoiding it.");
    prop(c, "debug_enabled", PropType.Bool, Value.bool(false), "Its path is drawn while Visible Navigation is on.");
    prop(c, "debug_use_custom", PropType.Bool, Value.bool(false), "Its path is drawn in its own colour and point size.");
    prop(c, "debug_path_custom_color", PropType.Color, Value.color(1, 1, 1, 1), "The colour of its path when debug_use_custom.");
    prop(c, "debug_path_custom_point_size", PropType.Float, f(4), "The size of its path's points, in pixels, when debug_use_custom.");
    prop(c, "drive_parent", PropType.Bool, Value.bool(false),
        "Hedra's: it moves its parent itself, along its path at max_speed (the safe velocity when avoidance_enabled), held to the navigation mesh, until the target is reached; off, as in Godot, a script moves it.");
    prop(c, "drive_turn_speed", PropType.Float, f(720),
        "Hedra's: how fast drive_parent turns its parent about Y to face where it goes, degrees a second (0: it never turns).");
    output(prop(c, "current_speed", PropType.Float, f(0),
        "How fast its parent moved this frame, metres a second, on the ground plane, whoever moved it (drive_parent, a script, a timeline) (computed: bind it with mode=\"to_source\", say to blend a walk and an idle)."));
    output(prop(c, "distance_to_target", PropType.Float, f(0),
        "How far its parent is from target_position, in metres (computed; Godot's distance_to_target())."));
    output(prop(c, "is_target_reached", PropType.Bool, Value.bool(false),
        "Its parent came within target_desired_distance of the target (computed; Godot's is_target_reached())."));
    output(prop(c, "is_navigation_finished", PropType.Bool, Value.bool(true),
        "It has nothing left to follow: the target reached, or the path's end (computed; Godot's is_navigation_finished())."));
    c.signals = [
        "path_changed()", "target_reached()", "waypoint_reached(details)", "link_reached(details)", "navigation_finished()",
        "velocity_computed(safe_velocity)",
    ];

    c = define(new ClassInfo("NavigationObstacle3D", "Node3D", true,
        "What agents avoid: a circle of radius (moving with velocity) or the outline of vertices on the ground plane, between its origin and height above it."));
    prop(c, "radius", PropType.Float, f(0), "The radius of the circle agents avoid (0: none; the vertices' outline then).");
    prop(c, "height", PropType.Float, f(1), "How tall it is, from its origin up: agents on another storey do not avoid it.");
    prop(c, "vertices", PropType.PackedVector3Array, Value.packedVector3s([]),
        "Its outline, in the node's space, on its ground plane (y is ignored): a static obstacle agents never enter.");
    prop(c, "affect_navigation_mesh", PropType.Bool, Value.bool(false),
        "A bake leaves its outline out of the navigation mesh (Godot's; read by `hedra bake --navmesh`).");
    prop(c, "carve_navigation_mesh", PropType.Bool, Value.bool(false),
        "With affect_navigation_mesh, its outline is cut out exactly, not grown by the agent's radius.");
    prop(c, "avoidance_enabled", PropType.Bool, Value.bool(true), "Agents avoid it.");
    prop(c, "velocity", PropType.Vector3, Value.vector3(0, 0, 0), "How fast a radius obstacle moves, which the agents take into account.");
    const obstacleLayers = prop(c, "avoidance_layers", PropType.Int, Value.int(1), "The avoidance layers it is in.");
    obstacleLayers.nonNegative = true;
    prop(c, "use_3d_avoidance", PropType.Bool, Value.bool(false),
        "Godot's avoidance in 3D; kept and not applied (navigation-3d-avoidance).");

    c = define(new ClassInfo("NavigationLink3D", "Node3D", true,
        "A way between two points of the navigation map that its polygons do not join: a jump, a ladder, a door; paths take it like any polygon, and an agent coming to it emits link_reached."));
    prop(c, "enabled", PropType.Bool, Value.bool(true), "Paths may take it.");
    prop(c, "bidirectional", PropType.Bool, Value.bool(true), "Paths take it both ways; off, from start_position to end_position only.");
    const linkLayers = prop(c, "navigation_layers", PropType.Int, Value.int(1), "The navigation layers it is in.");
    linkLayers.nonNegative = true;
    prop(c, "start_position", PropType.Vector3, Value.vector3(0, 0, 0),
        "One end, in the node's space: joined to the nearest polygon within the map's link_connection_radius.");
    prop(c, "end_position", PropType.Vector3, Value.vector3(0, 0, 0), "The other end, in the node's space.");
    prop(c, "enter_cost", PropType.Float, f(0), "What a path pays to take it.");
    prop(c, "travel_cost", PropType.Float, f(1), "What a path pays per metre along it.");

    // Resources.
    c = define(new ClassInfo("Resource", null, false, "The base of every resource."));
    c.isAbstract = true;
    prop(c, "resource_name", PropType.String, Value.str(""), "A name for people; the library does not use it.");

    c = define(new ClassInfo("Mesh", "Resource", false, "The base of the meshes."));
    c.isAbstract = true;

    c = define(new ClassInfo("PrimitiveMesh", "Mesh", false, "The base of the built-in meshes."));
    c.isAbstract = true;
    res(c, "material", "Material", "The mesh's material.");

    c = define(new ClassInfo("BoxMesh", "PrimitiveMesh", false, "A box centred on the origin."));
    c.subResource = true;
    prop(c, "size", PropType.Vector3, Value.vector3(1, 1, 1), "The box's size.");
    prop(c, "subdivide_width", PropType.Int, Value.int(0), "Extra cuts along X.");
    prop(c, "subdivide_height", PropType.Int, Value.int(0), "Extra cuts along Y.");
    prop(c, "subdivide_depth", PropType.Int, Value.int(0), "Extra cuts along Z.");

    c = define(new ClassInfo("SphereMesh", "PrimitiveMesh", false, "A UV sphere centred on the origin, poles on Y."));
    c.subResource = true;
    prop(c, "radius", PropType.Float, f(0.5), "The radius.");
    prop(c, "height", PropType.Float, f(1), "The height (2 x radius for a round sphere).");
    prop(c, "radial_segments", PropType.Int, Value.int(64), "Segments around Y.");
    prop(c, "rings", PropType.Int, Value.int(32), "Rings from pole to pole.");
    prop(c, "is_hemisphere", PropType.Bool, Value.bool(false), "Only the upper half.");

    c = define(new ClassInfo("CylinderMesh", "PrimitiveMesh", false, "A cylinder or cone centred on the origin, along Y."));
    c.subResource = true;
    prop(c, "top_radius", PropType.Float, f(0.5), "The radius at the top (0: a cone).");
    prop(c, "bottom_radius", PropType.Float, f(0.5), "The radius at the bottom.");
    prop(c, "height", PropType.Float, f(2), "The height.");
    prop(c, "radial_segments", PropType.Int, Value.int(64), "Segments around Y.");
    prop(c, "rings", PropType.Int, Value.int(4), "Extra rings along the side.");
    prop(c, "cap_top", PropType.Bool, Value.bool(true), "Close the top.");
    prop(c, "cap_bottom", PropType.Bool, Value.bool(true), "Close the bottom.");

    c = define(new ClassInfo("PlaneMesh", "PrimitiveMesh", false, "A flat rectangle centred on the origin."));
    c.subResource = true;
    prop(c, "size", PropType.Vector2, Value.vector2(2, 2), "The plane's size.");
    prop(c, "subdivide_width", PropType.Int, Value.int(0), "Extra cuts along the width.");
    prop(c, "subdivide_depth", PropType.Int, Value.int(0), "Extra cuts along the depth.");
    prop(c, "center_offset", PropType.Vector3, Value.vector3(0, 0, 0), "Moves the plane off the origin.");
    enumProp(c, "orientation", 1, ["face_x", "face_y", "face_z"], "The axis the plane faces.");

    // Milestone 35: Godot's QuadMesh, a PlaneMesh of 1 x 1 facing +Z (the
    // mesh a billboard particle draws); its own size and orientation hold
    // its defaults, the rest are PlaneMesh's.
    c = define(new ClassInfo("QuadMesh", "PlaneMesh", false,
        "A PlaneMesh facing +Z, 1 x 1: the quad billboard particles draw (a StandardMaterial3D with billboard_mode particles)."));
    c.subResource = true;
    prop(c, "size", PropType.Vector2, Value.vector2(1, 1), "The quad's size.");
    enumProp(c, "orientation", 2, ["face_x", "face_y", "face_z"], "The axis the quad faces.");

    c = define(new ClassInfo("MultiMesh", "Resource", false,
        "One mesh drawn many times: a transform per instance, and optionally a colour, in one buffer as Godot keeps it."));
    c.subResource = true;
    enumProp(c, "transform_format", 0, ["transform_2d", "transform_3d"],
        "The instances' transforms: 2D (8 numbers, not drawn) or 3D (12); Godot's default is 2D, so a 3D MultiMesh says transform_3d.");
    prop(c, "use_colors", PropType.Bool, Value.bool(false),
        "Each instance has a colour (4 numbers after its transform), multiplying the albedo of a material with vertex_color_use_as_albedo.");
    prop(c, "use_custom_data", PropType.Bool, Value.bool(false),
        "Each instance has 4 numbers of custom data after its colour, which a ShaderMaterial's shader reads as INSTANCE_CUSTOM (0 without it).");
    prop(c, "instance_count", PropType.Int, Value.int(0), "How many instances the buffer holds.");
    prop(c, "visible_instance_count", PropType.Int, Value.int(-1), "How many of them are drawn, from the first (-1: all).");
    res(c, "mesh", "Mesh", "The mesh each instance draws.");
    prop(c, "buffer", PropType.PackedFloat32Array, Value.packedFloats([]),
        "Per instance: the transform's three rows (basis row, then origin), then the colour, then the custom data.");

    define(new ClassInfo("ArrayMesh", "Mesh", false,
        "Triangles with their materials: the meshes of a model. Not declared in a file in format 1."));

    // Milestone 14: a material may stand on its own, as a MaterialX file
    // (docs/formats/MATERIALS.md), named by an ext_resource of type
    // Material, which loads as a StandardMaterial3D.
    c = define(new ClassInfo("Material", "Resource", false,
        "The base of the materials; as an ext_resource type, a MaterialX (.mtlx) material file."));
    c.isAbstract = true;
    c.extType = true;
    c.extensions = ["mtlx"];
    // Milestone 61: Godot's Material properties, which every material has
    // (Godot's defaults: none, 0). render_priority animates and binds (a
    // number: `material_override:render_priority`, as Godot keys an int);
    // next_pass is a resource, which neither does (a binding drives no
    // resource slot; its own material's properties are reached through it).
    res(c, "next_pass", "Material",
        "A material the surface is drawn with again, after this one (an outline, a glow): Godot's next pass.");
    const priority = prop(c, "render_priority", PropType.Int, Value.int(0),
        "The order blended surfaces are drawn in, -128 to 127: higher drawn later, in front (opaque surfaces keep their order).");
    priority.animates = true;
    priority.bindable = true;

    c = define(new ClassInfo("StandardMaterial3D", "Material", false,
        "A physically based material (metallic-roughness), as glTF's and the .rmdl's."));
    c.subResource = true;
    prop(c, "albedo_color", PropType.Color, Value.color(1, 1, 1, 1), "The base colour and alpha.");
    pngTexture(c, "albedo_texture", "Multiplies albedo_color.");
    prop(c, "metallic", PropType.Float, f(0), "0 dielectric, 1 metal.");
    pngTexture(c, "metallic_texture", "Multiplies metallic (its blue channel, as glTF).");
    prop(c, "roughness", PropType.Float, f(1), "0 mirror, 1 matte.");
    pngTexture(c, "roughness_texture", "Multiplies roughness (its green channel, as glTF).");
    prop(c, "emission_enabled", PropType.Bool, Value.bool(false), "The material emits light.");
    prop(c, "emission", PropType.Color, Value.color(0, 0, 0, 1), "The emitted colour.");
    prop(c, "emission_energy_multiplier", PropType.Float, f(1), "Scales emission.");
    pngTexture(c, "emission_texture", "Multiplies emission.");
    prop(c, "normal_enabled", PropType.Bool, Value.bool(false), "normal_texture is used.");
    prop(c, "normal_scale", PropType.Float, f(1), "The strength of normal_texture.");
    pngTexture(c, "normal_texture", "A tangent-space normal map.");
    prop(c, "ao_enabled", PropType.Bool, Value.bool(false), "ao_texture is used.");
    pngTexture(c, "ao_texture", "Ambient occlusion (its red channel, as glTF).");
    enumProp(c, "transparency", 0, ["disabled", "alpha", "alpha_scissor"],
        "How alpha is used: opaque, blended, or cut out at alpha_scissor_threshold.");
    prop(c, "alpha_scissor_threshold", PropType.Float, f(0.5), "The cut-out threshold.");
    enumProp(c, "cull_mode", 0, ["back", "front", "disabled"], "Which faces are not drawn (disabled: double sided).");
    prop(c, "vertex_color_use_as_albedo", PropType.Bool, Value.bool(false),
        "Multiplies the albedo by the vertex colour: a MultiMesh instance's colour.");
    prop(c, "vertex_color_is_srgb", PropType.Bool, Value.bool(false),
        "The vertex colour is sRGB, and is made linear before it multiplies the albedo.");
    // Milestone 14: Godot's UV1 group. Only x and y are drawn (z is
    // triplanar mapping's, which format 1 does not have).
    prop(c, "uv1_scale", PropType.Vector3, Value.vector3(1, 1, 1),
        "Scales the texture coordinates of every texture slot (x and y; z is kept, not drawn).");
    prop(c, "uv1_offset", PropType.Vector3, Value.vector3(0, 0, 0),
        "Moves the texture coordinates of every texture slot, after uv1_scale (x and y; z is kept, not drawn).");
    materialPbrProps(c);
    // Milestone 35: Godot's Billboard group. Drawn on a CPUParticles3D's
    // mesh, whose particles' transforms are turned to the camera on the
    // CPU (docs/engine/PARTICLES.md); any other geometry draws as if
    // disabled (material-billboard-ignored).
    enumProp(c, "billboard_mode", 0, ["disabled", "enabled", "fixed_y", "particles"],
        "Turns a CPUParticles3D's mesh to face the camera: enabled wholly, fixed_y about Y only, particles wholly and rolled by each particle's angle.");
    prop(c, "billboard_keep_scale", PropType.Bool, Value.bool(false),
        "A billboard keeps its particle's scale (scale_amount and its curves); off, it is drawn at the mesh's own size, as Godot draws it.");

    c = define(new ClassInfo("Environment", "Resource", false,
        "Background, ambient light, sky, tone mapping, fog and post-processing."));
    c.subResource = true;
    enumProp(c, "background_mode", 0, ["clear_color", "color", "sky"],
        "The background: the renderer's clear colour, background_color, or the sky (with no sky, the gradient of the sky_*_color and ground_*_color properties).");
    prop(c, "background_color", PropType.Color, Value.color(0, 0, 0, 1), "The background with background_mode color.");
    prop(c, "background_energy_multiplier", PropType.Float, f(1), "Multiplies the background, and the light the sky gives.");
    res(c, "sky", "Sky", "The sky: drawn with background_mode sky, and the source of ambient light and reflections.");
    prop(c, "sky_rotation", PropType.Vector3, Value.vector3(0, 0, 0),
        "Turns the sky and its light (Euler angles in radians, order YXZ).");
    enumProp(c, "ambient_light_source", 0, ["background", "disabled", "color", "sky"],
        "Where the ambient light comes from: the background (its colour, or the sky), none, ambient_light_color, or the sky.");
    prop(c, "ambient_light_color", PropType.Color, Value.color(0, 0, 0, 1), "The ambient light's colour with ambient_light_source color.");
    prop(c, "ambient_light_sky_contribution", PropType.Float, f(1),
        "With a sky as the source: the sky's share of the ambient light (the rest is ambient_light_color).");
    prop(c, "ambient_light_energy", PropType.Float, f(1), "The ambient light's strength, with the sources color and sky (and background under a sky).");
    enumProp(c, "reflected_light_source", 0, ["background", "disabled", "sky"],
        "Where reflections come from: the background (the sky, or with a colour background the ambient colour), none, or the sky.");
    // The gradient milestone 4 drew under background_mode sky, kept for the
    // scenes without a Sky (Godot has these on ProceduralSkyMaterial).
    prop(c, "sky_top_color", PropType.Color, Value.color(0.385, 0.454, 0.55, 1),
        "The gradient straight up, drawn when there is no sky (the gradient of scenes before Sky; a sky's material has its own).");
    prop(c, "sky_horizon_color", PropType.Color, Value.color(0.6463, 0.6558, 0.6708, 1),
        "The gradient at the horizon from above, drawn when there is no sky.");
    prop(c, "ground_bottom_color", PropType.Color, Value.color(0.2, 0.169, 0.133, 1),
        "The gradient straight down, drawn when there is no sky.");
    prop(c, "ground_horizon_color", PropType.Color, Value.color(0.6463, 0.6558, 0.6708, 1),
        "The gradient at the horizon from below, drawn when there is no sky.");
    enumProp(c, "tonemap_mode", 0, ["linear", "reinhard", "filmic", "aces", "agx"],
        "Tone mapping: how the lit colour becomes the picture's (linear clips at white).");
    prop(c, "tonemap_exposure", PropType.Float, f(1), "Exposure before tone mapping.");
    prop(c, "tonemap_white", PropType.Float, f(1),
        "The brightness drawn as white by reinhard, filmic and aces (linear and agx ignore it).");
    // Milestone 62: Godot's screen-space reflections where its inspector
    // has them (after the tone map, before SSAO), then Hedra's switch of
    // the screen-space refraction (docs/engine/SCREEN_EFFECTS.md). Godot's
    // names and defaults; ssr_max_steps, an int, animates and binds as a
    // number (as render_priority does).
    prop(c, "ssr_enabled", PropType.Bool, Value.bool(false),
        "Screen-space reflections: smooth surfaces reflect what the picture shows of the scene; where a reflection leaves the picture, the reflection probes' or the sky's reflection stays.");
    const ssrSteps = prop(c, "ssr_max_steps", PropType.Int, Value.int(64),
        "How many steps a reflection's ray is marched in, 1 to 512: more reach further across the picture and cost more.");
    ssrSteps.animates = true;
    ssrSteps.bindable = true;
    prop(c, "ssr_fade_in", PropType.Float, f(0.15),
        "How a reflection fades in from the surface it starts on (an exponent of the share of the march taken: 0 none).");
    prop(c, "ssr_fade_out", PropType.Float, f(2),
        "How a reflection fades out towards the end of its march, into the probes' or the sky's reflection (an exponent: 0 none).");
    prop(c, "ssr_depth_tolerance", PropType.Float, f(0.2),
        "How far behind a surface in the picture a reflection's ray may pass and still hit it, in metres: larger fills gaps, smaller keeps thin objects apart.");
    prop(c, "screen_refraction_enabled", PropType.Bool, Value.bool(false),
        "Glass (a material with refraction_enabled, or glTF's transmission) refracts the scene behind it, from the picture; off, it refracts only the sky and the ambient light.");
    // Milestone 12: screen-space ambient occlusion and glow listed where
    // Godot's inspector has them (after the tone map, before fog), the
    // adjustments after fog; RSCN.md's "Post-processing" gives the order the
    // passes draw in.
    prop(c, "ssao_enabled", PropType.Bool, Value.bool(false),
        "Screen-space ambient occlusion: the ambient light is darkened in creases and corners.");
    prop(c, "ssao_radius", PropType.Float, f(1), "How far away an occluder darkens a point, in metres.");
    prop(c, "ssao_intensity", PropType.Float, f(2), "How dark the occlusion is.");
    prop(c, "ssao_power", PropType.Float, f(1.5), "The occlusion's exponent: larger darkens deep creases more than shallow ones.");
    prop(c, "ssao_detail", PropType.Float, f(0.5), "How much a finer occlusion, at a quarter of ssao_radius, adds.");
    prop(c, "ssao_horizon", PropType.Float, f(0.06),
        "Occluders this close to a surface's plane (0 to 1) are ignored, so flat and gently curved surfaces stay unoccluded.");
    prop(c, "ssao_sharpness", PropType.Float, f(0.98), "How strictly the occlusion's blur keeps within one surface (1: never across an edge).");
    prop(c, "ssao_light_affect", PropType.Float, f(0),
        "How much the occlusion also darkens direct light, times ssao_ao_channel_affect (at 0, not at all).");
    prop(c, "ssao_ao_channel_affect", PropType.Float, f(0),
        "How much of ssao_light_affect darkens direct light (Godot's rule: their product counts).");
    prop(c, "glow_enabled", PropType.Bool, Value.bool(false), "Bright parts of the picture glow (bloom).");
    const glowLevels = [0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0];
    for (let i = 0; i < glowLevels.length; i++) {
        const k = i + 1;
        prop(c, "glow_levels/" + k.toString(), PropType.Float, f(glowLevels[i]),
            "How much the blur at 1/" + (1 << k).toString() + " of the picture's size adds to the glow.");
    }
    prop(c, "glow_normalized", PropType.Bool, Value.bool(false), "The levels are scaled to add up to 1.");
    prop(c, "glow_intensity", PropType.Float, f(0.8), "The glow's brightness.");
    prop(c, "glow_strength", PropType.Float, f(1), "Scales each level's blur (larger reaches further).");
    prop(c, "glow_mix", PropType.Float, f(0.05), "With glow_blend_mode mix: how much the glow replaces the picture.");
    prop(c, "glow_bloom", PropType.Float, f(0), "How much the whole picture glows, not only what is above glow_hdr_threshold.");
    enumProp(c, "glow_blend_mode", 2, ["additive", "screen", "softlight", "replace", "mix"],
        "How the glow is laid over the picture.");
    prop(c, "glow_hdr_threshold", PropType.Float, f(1), "The brightness above which a pixel glows.");
    prop(c, "glow_hdr_scale", PropType.Float, f(2), "How far above glow_hdr_threshold a pixel glows fully.");
    prop(c, "glow_hdr_luminance_cap", PropType.Float, f(12), "The brightest a pixel counts as in the glow.");
    prop(c, "fog_enabled", PropType.Bool, Value.bool(false), "Fog is drawn.");
    enumProp(c, "fog_mode", 0, ["exponential", "depth"],
        "How fog thickens with distance: exponentially by fog_density, or between fog_depth_begin and fog_depth_end.");
    prop(c, "fog_light_color", PropType.Color, Value.color(0.518, 0.553, 0.608, 1), "The fog's colour.");
    prop(c, "fog_light_energy", PropType.Float, f(1), "The fog's brightness.");
    prop(c, "fog_sun_scatter", PropType.Float, f(0), "How much the directional lights brighten the fog looking towards them.");
    prop(c, "fog_density", PropType.Float, f(0.01),
        "Exponential: the fog's density per metre; depth: its strength at fog_depth_end (1 hides everything).");
    prop(c, "fog_aerial_perspective", PropType.Float, f(0),
        "How much the fog takes the sky's colour instead of fog_light_color (with a sky).");
    prop(c, "fog_sky_affect", PropType.Float, f(1), "How much of the fog covers the sky.");
    prop(c, "fog_height", PropType.Float, f(0), "The height below which height fog thickens.");
    prop(c, "fog_height_density", PropType.Float, f(0),
        "Height fog's density per metre below fog_height (0 none; negative: fog above it).");
    prop(c, "fog_depth_curve", PropType.Float, f(1), "Depth fog: the exponent of its curve.");
    prop(c, "fog_depth_begin", PropType.Float, f(10), "Depth fog: where it starts, from the camera.");
    prop(c, "fog_depth_end", PropType.Float, f(100), "Depth fog: where it is full.");
    // Milestone 37: Godot's volumetric fog, as Hedra draws it without
    // froxels (docs/engine/FOG.md): the fog volumes' switch, and a fog of
    // its own over the first volumetric_fog_length metres from the eye,
    // integrated per pixel; lit by the lights (their
    // light_volumetric_fog_energy), the ambient light by ambient_inject,
    // over the depth and height fog above. Godot's names and defaults; gi
    // inject, detail spread and temporal reprojection tune Godot's froxels
    // and are kept, not drawn.
    prop(c, "volumetric_fog_enabled", PropType.Bool, Value.bool(false),
        "Volumetric fog is drawn: its own (volumetric_fog_density) and the scene's FogVolumes, which are drawn only while it is on.");
    prop(c, "volumetric_fog_density", PropType.Float, f(0.05),
        "The volumetric fog's density per metre everywhere within volumetric_fog_length (0: only the FogVolumes' fog).");
    prop(c, "volumetric_fog_albedo", PropType.Color, Value.color(1, 1, 1, 1),
        "The colour the volumetric fog scatters the lights' light with.");
    prop(c, "volumetric_fog_emission", PropType.Color, Value.color(0, 0, 0, 1),
        "Light the volumetric fog gives off itself, unlit (black: none).");
    prop(c, "volumetric_fog_emission_energy", PropType.Float, f(1), "Multiplies volumetric_fog_emission.");
    prop(c, "volumetric_fog_gi_inject", PropType.Float, f(1),
        "Kept for Godot (its SDFGI and VoxelGI light in the fog); not drawn.");
    prop(c, "volumetric_fog_anisotropy", PropType.Float, f(0.2),
        "How much more light the fog scatters forward than back, -0.9 to 0.9 (0: the same every way): the fog glows looking towards a light.");
    prop(c, "volumetric_fog_length", PropType.Float, f(64),
        "How far from the camera the volumetric fog reaches, in metres.");
    prop(c, "volumetric_fog_detail_spread", PropType.Float, f(2),
        "Kept for Godot (how its froxels spread with distance); not drawn.");
    prop(c, "volumetric_fog_ambient_inject", PropType.Float, f(0),
        "How much the ambient light lights the volumetric fog and the fog volumes (0: only the lights do).");
    prop(c, "volumetric_fog_sky_affect", PropType.Float, f(1),
        "How much of the volumetric fog covers the sky (0: none).");
    prop(c, "volumetric_fog_temporal_reprojection_enabled", PropType.Bool, Value.bool(true),
        "Kept for Godot (its froxels' smoothing over frames); not drawn.");
    prop(c, "volumetric_fog_temporal_reprojection_amount", PropType.Float, f(0.9),
        "Kept for Godot; not drawn.");
    prop(c, "adjustment_enabled", PropType.Bool, Value.bool(false), "Brightness, contrast and saturation are applied to the picture.");
    prop(c, "adjustment_brightness", PropType.Float, f(1), "Multiplies the picture (1: unchanged).");
    prop(c, "adjustment_contrast", PropType.Float, f(1), "Spreads the picture's values from mid grey (1: unchanged).");
    prop(c, "adjustment_saturation", PropType.Float, f(1), "Spreads the picture's colours from grey (0: grey, 1: unchanged).");

    // Milestone 62: Godot's CameraAttributes and CameraAttributesPractical
    // (docs/engine/SCREEN_EFFECTS.md): a camera's depth of field and
    // exposure, Godot's names, defaults and order. exposure_multiplier
    // multiplies the tone map's exposure; the sensitivity and auto exposure
    // are kept for Godot and not drawn (they take no flags).
    c = define(new ClassInfo("CameraAttributes", "Resource", false,
        "The base of a camera's attributes: its exposure (and, a CameraAttributesPractical, its depth of field)."));
    c.isAbstract = true;
    prop(c, "exposure_sensitivity", PropType.Float, f(100),
        "Kept for Godot (the camera's ISO, with physical light units); not drawn.");
    prop(c, "exposure_multiplier", PropType.Float, f(1),
        "Multiplies the Environment's tonemap_exposure for this camera's picture.");
    prop(c, "auto_exposure_enabled", PropType.Bool, Value.bool(false),
        "Kept for Godot (exposure adapting to the picture's brightness); not drawn.");
    prop(c, "auto_exposure_scale", PropType.Float, f(0.4), "Kept for Godot; not drawn.");
    prop(c, "auto_exposure_speed", PropType.Float, f(0.5), "Kept for Godot; not drawn.");
    c = define(new ClassInfo("CameraAttributesPractical", "CameraAttributes", false,
        "A camera's depth of field (what lies beyond or before the focus is blurred) and exposure, in Godot's practical terms."));
    c.subResource = true;
    prop(c, "dof_blur_far_enabled", PropType.Bool, Value.bool(false),
        "What lies beyond dof_blur_far_distance is blurred.");
    prop(c, "dof_blur_far_distance", PropType.Float, f(10),
        "Where the far blur starts, in metres from the camera.");
    prop(c, "dof_blur_far_transition", PropType.Float, f(5),
        "Over how many metres past dof_blur_far_distance the far blur grows to dof_blur_amount (negative: as a lens does, growing with the distance).");
    prop(c, "dof_blur_near_enabled", PropType.Bool, Value.bool(false),
        "What lies before dof_blur_near_distance is blurred.");
    prop(c, "dof_blur_near_distance", PropType.Float, f(2),
        "Where the near blur starts, in metres from the camera.");
    prop(c, "dof_blur_near_transition", PropType.Float, f(1),
        "Over how many metres before dof_blur_near_distance the near blur grows to dof_blur_amount (negative: as a lens does).");
    prop(c, "dof_blur_amount", PropType.Float, f(0.1),
        "How strong the blur is, 0 to 1 (1: a blur of 64 pixels' radius in a picture 1080 pixels high, in proportion at any size).");
    prop(c, "auto_exposure_min_sensitivity", PropType.Float, f(0), "Kept for Godot; not drawn.");
    prop(c, "auto_exposure_max_sensitivity", PropType.Float, f(800), "Kept for Godot; not drawn.");

    // The sky (milestone 11), as Godot's Sky and its two materials.
    c = define(new ClassInfo("Sky", "Resource", false, "The sky an Environment draws and lights the scene with."));
    c.subResource = true;
    res(c, "sky_material", "SkyMaterial", "What the sky looks like: a ProceduralSkyMaterial or a PanoramaSkyMaterial.");
    enumProp(c, "radiance_size", 3, ["32", "64", "128", "256", "512", "1024", "2048"],
        "The reflection map's face in texels (drawn at most 128).");

    // Godot's sky materials derive from Material; here a Material slot (a
    // mesh's) takes a StandardMaterial3D, so the sky materials have a base
    // of their own and neither kind is offered for the other's slot.
    c = define(new ClassInfo("SkyMaterial", "Resource", false,
        "The base of the sky materials (Materials in Godot; apart here, so neither kind of material goes in the other's slot)."));
    c.isAbstract = true;

    c = define(new ClassInfo("ProceduralSkyMaterial", "SkyMaterial", false,
        "A sky drawn from colours: a gradient from the horizon up and one down, with a glow around each directional light."));
    c.subResource = true;
    prop(c, "sky_top_color", PropType.Color, Value.color(0.385, 0.454, 0.55, 1), "The sky straight up.");
    prop(c, "sky_horizon_color", PropType.Color, Value.color(0.6463, 0.6558, 0.6708, 1), "The sky at the horizon.");
    prop(c, "sky_curve", PropType.Float, f(0.15),
        "How quickly the sky turns from the horizon's colour to the top's (smaller: nearer the horizon).");
    prop(c, "sky_energy_multiplier", PropType.Float, f(1), "The sky's brightness.");
    prop(c, "ground_bottom_color", PropType.Color, Value.color(0.2, 0.169, 0.133, 1), "The ground straight down.");
    prop(c, "ground_horizon_color", PropType.Color, Value.color(0.6463, 0.6558, 0.6708, 1), "The ground at the horizon.");
    prop(c, "ground_curve", PropType.Float, f(0.02), "How quickly the ground turns from the horizon's colour to the bottom's.");
    prop(c, "ground_energy_multiplier", PropType.Float, f(1), "The ground's brightness.");
    prop(c, "sun_angle_max", PropType.Float, f(30), "How far the sun's glow reaches from its centre, in degrees.");
    prop(c, "sun_curve", PropType.Float, f(0.15), "How the glow fades towards sun_angle_max.");
    prop(c, "energy_multiplier", PropType.Float, f(1), "Multiplies the whole sky.");

    c = define(new ClassInfo("PanoramaSkyMaterial", "SkyMaterial", false,
        "A sky drawn from an equirectangular image around the scene."));
    c.subResource = true;
    res(c, "panorama", "Texture2D", "The equirectangular image: a Radiance HDR (.hdr) or a PNG file.");
    prop(c, "filter", PropType.Bool, Value.bool(true), "Sample the panorama smoothly (off: its texels show).");
    prop(c, "energy_multiplier", PropType.Float, f(1), "Multiplies the panorama.");

    // The ext_resource types.
    c = define(new ClassInfo("PackedScene", "Resource", false,
        "A scene to instance: an .rscn or .rscnb file, or a model whose objects become nodes."));
    c.extType = true;
    // (milestone 39: a binary scene, .rscnb, instances as its .rscn does)
    // (a model file is a document, .rmdl, or the commands that build it,
    // .rmdlcmd: engine/src/source/model/formats.as, which this runtime
    // module does not import; the retired .modeler is named for its hint)
    c.extensions = ["rscn", "rscnb", "rmdl", "rmdlcmd", RETIRED_MODEL_EXTENSION, "gltf", "glb"];
    c = define(new ClassInfo("Model", "Resource", false,
        "A model for ModelInstance3D: .rmdl (a model document), .rmdlcmd (its commands), .modeler, .gltf or .glb."));
    c.extType = true;
    c.extensions = ["rmdl", "rmdlcmd", RETIRED_MODEL_EXTENSION, "gltf", "glb"];
    c = define(new ClassInfo("Script", "Resource", false, "An AnimaScript file (Rive's scripting language) holding one class that extends NodeScript."));
    c.extType = true;
    c.extensions = ["as"];
    c = define(new ClassInfo("Texture2D", "Resource", false,
        "An image: a PNG file, or a Radiance HDR (.hdr) file for a panorama."));
    c.extType = true;
    c.extensions = ["png", "hdr"];

    // Milestone 15: a Rive file, and a texture drawn from one of its
    // artboards (docs/formats/RSCN.md, "ArtboardTexture"). An
    // ArtboardTexture is a Texture2D, so every material texture slot takes
    // one; it is declared as a sub_resource only.
    // Milestone 42: what a ViewModel's data comes from, a .riv or an .rml
    // (Rive's text format, its data part: docs/plans/RIVE_MODEL.md section
    // 3.4), under one abstract base so that ViewModel.file takes either.
    c = define(new ClassInfo("RiveSource", "Resource", false,
        "The base of the files a view model is declared in: a Rive file (.riv) or Rive's text data (.rml)."));
    c.isAbstract = true;
    c = define(new ClassInfo("RiveFile", "RiveSource", false,
        "A Rive file (.riv), whose artboards an ArtboardTexture draws and whose view models a ViewModel names."));
    c.extType = true;
    c.extensions = ["riv"];
    c = define(new ClassInfo("RiveData", "RiveSource", false,
        "Rive's text format (.rml), read for its data only: the view models, enums and converters a ViewModel names."));
    c.extType = true;
    c.extensions = ["rml"];
    c = define(new ClassInfo("ArtboardTexture", "Texture2D", false,
        "A texture drawn from an artboard of a Rive file: a placeholder in the tools, the live artboard in a built project."));
    c.subResource = true;
    res(c, "file", "RiveFile", "The Rive file (.riv) that holds the artboard.");
    prop(c, "artboard", PropType.String, Value.str(""), "The artboard's name.");
    prop(c, "state_machine", PropType.String, Value.str(""),
        "The state machine an instance runs; empty for the artboard's default one.");
    prop(c, "size", PropType.Vector2i, Value.numbers(ValueKind.Vector2i, [0, 0]),
        "The texture's size in pixels, 1 to 8192 each; 0 x 0 for the artboard's own size.");
    // Milestone 67 (docs/engine/PERFORMANCE.md): Godot's SubViewport
    // render_target_update_mode (its names, numbers and default), and
    // Hedra's cap on the redraws a second. Both animate and bind (through a
    // node that shows the texture: `artboard:<property>`, binding/
    // targets.as), set by hand: a texture is not one of the flagged
    // resource classes (FLAG_RESOURCE_BASES), whose other fields (the file,
    // the artboard, the size) a frame cannot change.
    const updateMode = enumProp(c, "render_target_update_mode", 2,
        ["disabled", "once", "when_visible", "when_parent_visible", "always"],
        "When its picture is drawn again after the first: never, once (again each time this is set to once), while a surface that shows it was drawn in the last frame (when_parent_visible is the same: a texture has no parent), or whenever the artboard changes. The artboard always plays.");
    updateMode.animates = true;
    updateMode.bindable = true;
    const updateFps = prop(c, "update_fps", PropType.Float, f(0),
        "At most this many new pictures a second, by the scene's clock (the first change after a pause is drawn at once); 0 draws every change.");
    updateFps.animates = true;
    updateFps.bindable = true;

    // Milestone 34: Godot's ViewportTexture, the picture a SubViewport
    // draws (RSCN.md, "Viewports"). A Texture2D, so every texture slot
    // takes one; declared as a sub_resource only, its viewport_path from the
    // root of the scene that declares it, as Godot's (a resource local to
    // its scene).
    c = define(new ClassInfo("ViewportTexture", "Texture2D", false,
        "The picture a SubViewport draws, drawn live in any texture slot; its size is the SubViewport's."));
    c.subResource = true;
    prop(c, "viewport_path", PropType.NodePath, Value.nodePath(""),
        "The SubViewport, by its path from the root of the scene that declares the texture.");

    // Milestone 17: a view model of a Rive file, which a scene's root names
    // so that its nodes' bindings read and write it (RSCN.md, "Bindings").
    c = define(new ClassInfo("ViewModel", "Resource", false,
        "A view model of a Rive file: the data a scene's bindings read and write, bound to the scene's artboard in a built project."));
    c.subResource = true;
    res(c, "file", "RiveSource",
        "The Rive file (.riv) or RML data (.rml) that declares the view model; empty for the data of the Rive project the scene is in.");
    prop(c, "view_model", PropType.String, Value.str(""), "The view model's name.");
    prop(c, "instance", PropType.String, Value.str(""),
        "The instance whose values the scene starts from; empty for the view model's default instance.");

    // Milestone 19: a LightmapGI's bake (RSCN.md, "LightmapGIData").
    c = define(new ClassInfo("LightmapGIData", "Resource", false,
        "A LightmapGI's bake: an .lmbake file and the lightmap images and UVs beside it, as `" + CLI + " bake` writes them."));
    c.extType = true;
    c.extensions = ["lmbake"];

    // Milestone 20: a ReflectionProbe's capture (RSCN.md, "ReflectionProbeData").
    c = define(new ClassInfo("ReflectionProbeData", "Resource", false,
        "A ReflectionProbe's capture: an .rprobe file, its filtered cube map, as `" + CLI + " bake` writes it."));
    c.extType = true;
    c.extensions = ["rprobe"];

    // Milestone 36: a sound (RSCN.md, "Audio"), what Godot's tscn names
    // AudioStream, with Godot's two concrete classes so that their names
    // read too. The formats are those the Rive runtime decodes; Ogg Vorbis
    // is not one (audio-format, the validator's).
    c = define(new ClassInfo("AudioStream", "Resource", false,
        "A sound an AudioStreamPlayer3D plays: a WAV, MP3 or FLAC file, which the build declares as a Rive audio asset."));
    c.extType = true;
    c.extensions = ["wav", "mp3", "flac"];
    c = define(new ClassInfo("AudioStreamWAV", "AudioStream", false, "A WAV file (Godot's class name for one)."));
    c.extType = true;
    c.extensions = ["wav"];
    c = define(new ClassInfo("AudioStreamMP3", "AudioStream", false, "An MP3 file (Godot's class name for one)."));
    c.extType = true;
    c.extensions = ["mp3"];

    // Milestone 31: the shapes of a CollisionShape3D (RSCN.md,
    // "Interaction"), sub_resources, centred on the origin of the node that
    // uses them, Y up as Godot's.
    c = define(new ClassInfo("Shape3D", "Resource", false, "The base of the collision shapes."));
    c.isAbstract = true;
    prop(c, "margin", PropType.Float, f(0.04),
        "Kept for Godot, whose physics engines pad shapes by it; overlaps, rays and picks here are exact.");
    c = define(new ClassInfo("BoxShape3D", "Shape3D", false, "A box centred on the origin."));
    c.subResource = true;
    prop(c, "size", PropType.Vector3, Value.vector3(1, 1, 1), "Its size along x, y and z.");
    c = define(new ClassInfo("SphereShape3D", "Shape3D", false, "A sphere centred on the origin."));
    c.subResource = true;
    prop(c, "radius", PropType.Float, f(0.5), "Its radius.");
    c = define(new ClassInfo("CapsuleShape3D", "Shape3D", false,
        "A cylinder with a half sphere at each end, along y, centred on the origin."));
    c.subResource = true;
    prop(c, "radius", PropType.Float, f(0.5), "The radius of its cylinder and caps.");
    prop(c, "height", PropType.Float, f(2), "Its whole height, the caps included; under twice the radius, the radius is half of it.");
    c = define(new ClassInfo("CylinderShape3D", "Shape3D", false, "A cylinder along y, centred on the origin."));
    c.subResource = true;
    prop(c, "height", PropType.Float, f(2), "Its height.");
    prop(c, "radius", PropType.Float, f(0.5), "Its radius.");
    c = define(new ClassInfo("ConvexPolygonShape3D", "Shape3D", false,
        "The convex hull of a set of points: a mesh's, made by the editor's Create Collision Shape, or written by hand."));
    c.subResource = true;
    prop(c, "points", PropType.PackedVector3Array, Value.packedVector3s([]),
        "The points, in any order; those inside the hull change nothing.");
    c = define(new ClassInfo("ConcavePolygonShape3D", "Shape3D", false,
        "A surface of triangles, any shape (a mesh's, made by the editor's Create Collision Shape); it has no inside."));
    c.subResource = true;
    prop(c, "data", PropType.PackedVector3Array, Value.packedVector3s([]),
        "Its triangles, three points each, the front face clockwise as Godot winds them.");
    prop(c, "backface_collision", PropType.Bool, Value.bool(false),
        "Its faces are hit from both sides; off, only from the front.");

    // Milestone 32: a Path3D's curve (RSCN.md, "Paths"), stored as Godot
    // stores it: its points in `_data` (each point's in handle, out handle
    // and position, nine numbers, then a tilt each), then `point_count`.
    c = define(new ClassInfo("Curve3D", "Resource", false,
        "A 3D Bézier curve: points with in and out handles (relative to the point) and tilts, baked into points bake_interval apart."));
    c.subResource = true;
    prop(c, "closed", PropType.Bool, Value.bool(false), "Its last point joins back to its first.");
    prop(c, "bake_interval", PropType.Float, f(0.2),
        "About how far apart its baked points are, in metres; what follows it is sampled between them.");
    prop(c, "_data", PropType.Dictionary, curveDataDefault(),
        "Its points, as Godot stores them: \"points\", a PackedVector3Array of each point's in, out and position, and \"tilts\", a PackedFloat32Array of each point's tilt in radians.");
    const count = prop(c, "point_count", PropType.Int, Value.int(0),
        "How many points it has: fewer than _data holds drops the last ones, more adds points at the origin.");
    count.nonNegative = true;
    prop(c, "up_vector_enabled", PropType.Bool, Value.bool(true),
        "It bakes an up vector at each baked point (parallel transport frames, so the curve does not twist), which PathFollow3D's oriented mode needs.");

    // Milestone 35: Godot's Curve (a value over 0 to 1, a particle's life)
    // and Gradient (colours over 0 to 1), as Godot writes them: `_data` five
    // items a point (its position, a Vector2, its left and right tangents,
    // and their modes, 0 free and 1 linear), `point_count` after it, as
    // Curve3D's; a Gradient's offsets and colors side by side. Not flagged:
    // the particles read them, nothing keys them.
    c = define(new ClassInfo("Curve", "Resource", false,
        "A value over 0 to 1 (a particle's life): points with tangents, between min_value and max_value, sampled from a bake of bake_resolution points."));
    c.subResource = true;
    prop(c, "min_value", PropType.Float, f(0), "The least value a point may have.");
    prop(c, "max_value", PropType.Float, f(1), "The greatest value a point may have.");
    const bakeRes = prop(c, "bake_resolution", PropType.Int, Value.int(100), "How many points it is baked into, at least 1.");
    bakeRes.nonNegative = true;
    prop(c, "_data", PropType.Array, Value.array([]),
        "Its points, as Godot stores them: for each, Vector2(offset, value), the left and right tangents, and the left and right tangent modes (0 free, 1 linear).");
    const curveCount = prop(c, "point_count", PropType.Int, Value.int(0),
        "How many points it has: fewer than _data holds drops the last ones, more adds points at (0, 0).");
    curveCount.nonNegative = true;

    c = define(new ClassInfo("Gradient", "Resource", false,
        "Colours over 0 to 1 (a particle's life): stops at offsets, blended between them."));
    c.subResource = true;
    prop(c, "offsets", PropType.PackedFloat32Array, Value.packedFloats([0, 1]),
        "Each stop's place, 0 to 1, in the order of `colors`.");
    prop(c, "colors", PropType.PackedColorArray, Value.packedColors([0, 0, 0, 1, 1, 1, 1, 1]),
        "Each stop's colour (sRGB, straight alpha), as many as offsets.");
    enumProp(c, "interpolation_mode", 0, ["linear", "constant", "cubic"],
        "How colours blend between stops: linearly, not at all (each stop's until the next), or along a cubic.");
    enumProp(c, "interpolation_color_space", 0, ["srgb", "linear_srgb", "oklab"],
        "The space colours blend in.");

    // Milestone 61: Godot's ShaderMaterial, with WGSL in place of Godot's
    // shading language (docs/engine/SHADERS.md), and its Shader, a .wgsl
    // file named by an ext_resource. Its parameters are the shader's
    // uniforms, `shader_parameter/<name>` (a family: which there are, only
    // the shader tells), each keyed and bound (through material_override:
    // and mesh:material: on its node). Godot's Shader `code` (a shader
    // written inside the scene) is not in the format: a shader is a file.
    c = define(new ClassInfo("ShaderMaterial", "Material", false,
        "A material drawn by a shader of your own: a .wgsl file of WGSL with Godot's stage functions, render modes and uniforms, whose uniforms are its parameters."));
    c.subResource = true;
    res(c, "shader", "Shader", "The shader (a .wgsl file) that draws the material; none draws the fallback.");
    family(c, "shader_parameter/<name>", FAMILY_SHADER_PARAMETER, PropType.Variant, Value.nil(), true, true,
        "The value of the shader's uniform <name>: a number, a bool, a vector, a Color (a source_color uniform) or a texture.");
    c = define(new ClassInfo("Shader", "Resource", false,
        "A shader file (.wgsl): WGSL with Godot's shader_type, render_mode and uniform declarations and stage functions vertex(), fragment() and light()."));
    c.extType = true;
    c.extensions = ["wgsl"];

    // Milestone 37: Godot's FogMaterial (a FogVolume's look; Godot's
    // built-in fog shader, number for number: docs/engine/FOG.md). Its
    // density_texture (a Texture3D) is not in the format: kept as an
    // unknown property, warned. Every property animates and binds
    // (`material:<p>` on its FogVolume).
    c = define(new ClassInfo("FogMaterial", "Material", false,
        "A FogVolume's look, Godot's built-in fog: its density, the colour it scatters light with, the light it gives off, how it thins with height and how soft its edges are."));
    c.subResource = true;
    prop(c, "density", PropType.Float, f(1),
        "The fog's density per metre (negative takes fog away from the volumetric fog and the other volumes there).");
    prop(c, "albedo", PropType.Color, Value.color(1, 1, 1, 1),
        "The colour it scatters the lights' light with.");
    prop(c, "emission", PropType.Color, Value.color(0, 0, 0, 1),
        "Light it gives off itself, unlit (black: none).");
    prop(c, "height_falloff", PropType.Float, f(0),
        "How fast it thins above the volume's origin, per metre (0: the same density at every height).");
    prop(c, "edge_fade", PropType.Float, f(0.1),
        "How softly it fades out towards the shape's edges (an exponent: 0 a hard edge, higher softer).");

    // Milestone 37: Godot's occluder shapes (OccluderInstance3D.occluder),
    // in the node's space; each is triangles to the culling
    // (scene/render/occluder_shapes.as makes them: Godot's own meshes). Not
    // flagged: occluders are static, as in Godot.
    c = define(new ClassInfo("Occluder3D", "Resource", false, "The base of the occluder shapes."));
    c.isAbstract = true;
    c = define(new ClassInfo("ArrayOccluder3D", "Occluder3D", false,
        "Triangles that occlude: a baked .occ file (hedra bake --occluders), or written by hand as a sub_resource."));
    c.subResource = true;
    c.extType = true;
    c.extensions = ["occ"];
    prop(c, "vertices", PropType.PackedVector3Array, Value.packedVector3s([]), "Its points, in the node's space.");
    const occIndices = prop(c, "indices", PropType.PackedInt32Array, Value.packedInts([]),
        "Its triangles: three indices into vertices each.");
    occIndices.nonNegative = true;
    c = define(new ClassInfo("BoxOccluder3D", "Occluder3D", false, "A box centred on the node."));
    c.subResource = true;
    prop(c, "size", PropType.Vector3, Value.vector3(1, 1, 1), "Its size along x, y and z.");
    c = define(new ClassInfo("SphereOccluder3D", "Occluder3D", false,
        "A sphere centred on the node (Godot's mesh of it, 7 rings of 7 segments, which lies inside the sphere)."));
    c.subResource = true;
    prop(c, "radius", PropType.Float, f(1), "Its radius.");
    c = define(new ClassInfo("QuadOccluder3D", "Occluder3D", false,
        "A rectangle in the node's XY plane, centred on it (it occludes from both sides)."));
    c.subResource = true;
    prop(c, "size", PropType.Vector2, Value.vector2(1, 1), "Its width (x) and height (y).");
    c = define(new ClassInfo("PolygonOccluder3D", "Occluder3D", false,
        "A flat polygon in the node's XY plane, convex or not, its edges not crossing (it occludes from both sides)."));
    c.subResource = true;
    prop(c, "polygon", PropType.PackedVector2Array, Value.packedVector2s([]), "Its corners, in order (x, y each).");

    // Milestone 63: Godot 4.4's NavigationMesh (NavigationRegion3D's
    // navigation_mesh; docs/formats/RSCN.md "Navigation"): the bake's
    // settings in Godot's names, defaults and enum numbers, and the baked
    // polygons in Godot's own form (vertices, and polygons: an Array of
    // PackedInt32Array, each a convex polygon's corners). A bake
    // (hedra_compiler/bake/navmesh/) writes vertices and polygons; a file
    // may write them by hand (a floor is 4 vertices and 1 polygon). Not
    // flagged: a bake reads the settings, as a LightmapGI's. Godot's
    // filter_baking_aabb and filter_baking_aabb_offset are not in the
    // format (it has no AABB value; NAVIGATION.md says so).
    c = define(new ClassInfo("NavigationMesh", "Resource", false,
        "A region's walkable polygons and the settings a bake makes them with (agent size, cells, regions, edges, detail, filters, source geometry)."));
    c.subResource = true;
    prop(c, "vertices", PropType.PackedVector3Array, Value.packedVector3s([]), "The polygons' corners, in the region's space.");
    prop(c, "polygons", PropType.Array, Value.array([]),
        "The polygons: an Array of PackedInt32Array, each the indices into vertices of a convex polygon's corners, clockwise seen from above (Godot's order).");
    enumProp(c, "sample_partition_type", 0, ["watershed", "monotone", "layers"],
        "How a bake cuts the walkable cells into regions: watershed (the best polygons, slowest), monotone (fastest, long thin polygons) or layers.");
    enumProp(c, "geometry_parsed_geometry_type", 2, ["mesh_instances", "static_colliders", "both"],
        "What a bake reads as geometry: MeshInstance3Ds (and ModelInstance3Ds' parts), StaticBody3Ds' collision shapes in geometry_collision_mask, or both.");
    const geoMask = prop(c, "geometry_collision_mask", PropType.Int, Value.int(4294967295),
        "The collision layers of the static bodies a bake reads (bit k: layer k + 1).");
    geoMask.nonNegative = true;
    enumProp(c, "geometry_source_geometry_mode", 0, ["root_node_children", "groups_with_children", "groups_explicit"],
        "Where a bake finds its geometry: under the region, under the nodes of geometry_source_group_name, or those nodes alone.");
    prop(c, "geometry_source_group_name", PropType.StringName, Value.str("navigation_mesh_source_group"),
        "The group a bake takes its geometry from in the two group modes.");
    prop(c, "cell_size", PropType.Float, f(0.25), "The width of a bake's cells, in metres (it should be the map's cell_size).");
    prop(c, "cell_height", PropType.Float, f(0.25), "The height of a bake's cells, in metres (it should be the map's cell_height).");
    prop(c, "border_size", PropType.Float, f(0), "Metres a bake reads beyond the baked area's edge, so that tiles meet.");
    prop(c, "agent_height", PropType.Float, f(1.5), "The least height, in metres, an agent needs over a walkable floor.");
    prop(c, "agent_radius", PropType.Float, f(0.5), "How far, in metres, the mesh keeps from walls and ledges.");
    prop(c, "agent_max_climb", PropType.Float, f(0.25), "The highest step, in metres, an agent climbs.");
    prop(c, "agent_max_slope", PropType.Float, f(45), "The steepest floor, in degrees, an agent walks on (0 to 90).");
    prop(c, "region_min_size", PropType.Float, f(2), "A walkable island smaller than this many cells across is left out.");
    prop(c, "region_merge_size", PropType.Float, f(20), "Regions smaller than this many cells across are merged into bigger ones.");
    prop(c, "edge_max_length", PropType.Float, f(0), "The longest an outline's edge may be, in metres (0: no limit).");
    prop(c, "edge_max_error", PropType.Float, f(1.3), "How far, in cells, a simplified outline may stray from the cells' edge.");
    prop(c, "vertices_per_polygon", PropType.Float, f(6), "The most corners a polygon has (3 to 6) before the detail mesh splits it.");
    prop(c, "detail_sample_distance", PropType.Float, f(6),
        "How far apart, in cells, the detail mesh samples the floor's height (under 0.9: no samples).");
    prop(c, "detail_sample_max_error", PropType.Float, f(1),
        "How far, in cell heights, the detail mesh may stray from the floor.");
    prop(c, "filter_low_hanging_obstacles", PropType.Bool, Value.bool(false),
        "Low obstacles an agent can step over (kerbs, stairs) are walkable.");
    prop(c, "filter_ledge_spans", PropType.Bool, Value.bool(false), "Cells at a drop higher than agent_max_climb are not walkable.");
    prop(c, "filter_walkable_low_height_spans", PropType.Bool, Value.bool(false),
        "Cells with less than agent_height above them are not walkable.");

    applyFlagDefaults();
    return classes as Map<string, ClassInfo>;
}

// Milestone 32: a Curve3D's `_data` when it has no points, as Godot writes
// an empty curve's.
export function curveDataDefault(): Value {
    return Value.dictionary([Value.str("points"), Value.str("tilts")], [Value.packedVector3s([]), Value.packedFloats([])]);
}

// Marks a property an output (computed, read only): never bindable as a
// target, never keyed.
function output(p: PropInfo): PropInfo {
    p.output = true;
    return p;
}

// --- the flags (milestone 42) ---------------------------------------------------

// The classes whose properties take the flags by default: the node classes
// and these resources, whose properties a binding reaches through a node
// (`material_override:<p>`, `mesh:<p>`, `environment:<p>`).
const FLAG_RESOURCE_BASES: StaticArray<string> = [
    "StandardMaterial3D", "Environment", "PrimitiveMesh", "FogMaterial", "CameraAttributes",
];

// The exceptions, in one place: every property of these classes (a bake
// depends on them, or they hold no value to animate) ...
const NO_FLAG_CLASSES: StaticArray<string> = ["LightmapGI", "LightmapProbe", "ReflectionProbe"];

// ... and these properties ("Class.property").
const NO_FLAG_PROPS: StaticArray<string> = [
    "Node.view_model", "Node.data_path", "Node.script", "Node.unique_name_in_owner",
    "GeometryInstance3D.visibility_range_begin", "GeometryInstance3D.visibility_range_begin_margin",
    "GeometryInstance3D.visibility_range_end", "GeometryInstance3D.visibility_range_end_margin",
    "GeometryInstance3D.visibility_range_fade_mode", "GeometryInstance3D.gi_mode", "GeometryInstance3D.gi_lightmap_texel_scale",
    "GeometryInstance3D.layers", "CollisionObject3D.collision_layer", "CollisionObject3D.collision_mask",
    // Milestone 47: read at each pointer event, never per frame.
    "Node3D.listener_pass_through", "GeometryInstance3D.input_ray_pickable", "GeometryInstance3D.pointer_forward",
    // Milestone 37: what a bake reads (as LightmapGI's), and Godot's
    // froxel settings, kept and not drawn.
    "OccluderInstance3D.bake_simplification_distance", "Environment.volumetric_fog_gi_inject",
    "Environment.volumetric_fog_detail_spread", "Environment.volumetric_fog_temporal_reprojection_enabled",
    "Environment.volumetric_fog_temporal_reprojection_amount",
    // Milestone 62: Godot's sensitivity and auto exposure, kept and not
    // drawn.
    "CameraAttributes.exposure_sensitivity", "CameraAttributes.auto_exposure_enabled",
    "CameraAttributes.auto_exposure_scale", "CameraAttributes.auto_exposure_speed",
    "CameraAttributesPractical.auto_exposure_min_sensitivity", "CameraAttributesPractical.auto_exposure_max_sensitivity",
    // Milestone 63: Godot's one pathfinding algorithm, nothing to choose
    // between.
    "NavigationAgent3D.pathfinding_algorithm",
];

// StandardMaterial3D's properties that change the pipeline its draws use
// (a new shader variant or blend state), besides every `*_enabled` and
// `vertex_color_*` one: costly.
const COSTLY_MATERIAL_PROPS: StaticArray<string> = ["transparency", "cull_mode"];

// Milestone 34: node properties whose write makes the plan again (a
// renderer frame carries what they decide), costly as a material's
// pipeline fields are.
const COSTLY_NODE_PROPS: StaticArray<string> = ["Viewport.own_world_3d"];

// Whether a property of type `type` (with `enumNames` when an Int) takes
// the flags: a number, a choice, a bool, a colour or a float vector.
// (Transform3D, resources, strings, node paths, packed arrays, Vector2i
// and a plain int never do.)
function flaggedType(p: PropInfo): bool {
    switch (p.type) {
        case PropType.Float:
        case PropType.Bool:
        case PropType.Color:
        case PropType.Vector2:
        case PropType.Vector3:
            return true;
        case PropType.Int:
            return p.enumNames.length > 0;
        default:
            return false;
    }
}

// Whether class `c` (by its chain) is one whose properties take the flags.
function flaggedClass(c: ClassInfo): bool {
    if (NO_FLAG_CLASSES.includes(c.name)) return false;
    if (c.isNode) return true;
    for (let i = 0; i < FLAG_RESOURCE_BASES.length; i++) if (isA(c.name, FLAG_RESOURCE_BASES[i])) return true;
    return false;
}

// Sets every property's animates, bindable and costly (docs/plans/
// RIVE_MODEL.md section 3.1): by type in the flagged classes, less the
// exceptions above; an output takes neither. Run once, when the table is
// built.
function applyFlagDefaults(): void {
    for (let i = 0; i < classOrder.length; i++) {
        const c = (classes as Map<string, ClassInfo>).get(classOrder[i]);
        const flagged = flaggedClass(c);
        const primitive = isA(c.name, "PrimitiveMesh");
        const material = c.name == "StandardMaterial3D";
        for (let k = 0; k < c.props.length; k++) {
            const p = c.props[k];
            if (p.output || !flagged || !flaggedType(p) || NO_FLAG_PROPS.includes(c.name + "." + p.name)) continue;
            p.animates = true;
            p.bindable = true;
            // A built-in mesh's every field rebuilds its geometry; a
            // material's pipeline fields make a new variant.
            if (primitive) p.costly = true;
            if (COSTLY_NODE_PROPS.includes(c.name + "." + p.name)) p.costly = true;
            if (material && (COSTLY_MATERIAL_PROPS.includes(p.name) || p.name.endsWith("_enabled") || p.name.startsWith("vertex_color_"))) {
                p.costly = true;
            }
        }
    }
}

// The flags of `p` as RSCN.md's table writes them ("animates, bindable",
// "output", "animates, bindable, costly"; "" for none).
export function propFlagsText(p: PropInfo): string {
    const out = new Array<string>();
    if (p.animates) out.push("animates");
    if (p.bindable) out.push("bindable");
    if (p.output) out.push("output");
    if (p.costly) out.push("costly");
    if (p.derived) out.push("derived");
    return out.join(", ");
}

function table(): Map<string, ClassInfo> {
    const t = classes;
    return t != null ? t : build();
}

// --- queries -----------------------------------------------------------------

export function classInfo(name: string): ClassInfo? {
    const t = table();
    return t.has(name) ? t.get(name) : null;
}

export function isNodeClass(name: string): bool {
    const c = classInfo(name);
    return c != null && c.isNode;
}

export function isResourceClass(name: string): bool {
    const c = classInfo(name);
    return c != null && !c.isNode;
}

// Whether `name` is `base` or derives from it (false when either is
// unknown).
export function isA(name: string, base: string): bool {
    let c = classInfo(name);
    while (c != null) {
        if (c.name == base) return true;
        const b = c.base;
        c = b != null ? classInfo(b) : null;
    }
    return false;
}

// A property of the class or of one of its bases.
// The class findProp looked up last: loading asks about one node's class a
// dozen times in a row.
let lastClassName: string = "";
let lastClass: ClassInfo? = null;

export function findProp(className: string, name: string): PropInfo? {
    let c = lastClass;
    if (c == null || lastClassName != className) {
        c = classInfo(className);
        if (c == null) return null;
        lastClassName = className;
        lastClass = c;
    }
    let index = c.index;
    if (index == null) {
        // The bases' first, so that a class's own property of a name wins,
        // as the walk from the class up would find it.
        const made = new Map<string, PropInfo>();
        const all = allProps(className);
        for (let i = 0; i < all.length; i++) made.set(all[i].name, all[i]);
        c.index = made;
        index = made;
    }
    if (index.has(name)) return index.get(name);
    // Milestone 48: a name of a family's shape, answered with its own
    // property (kept in the index, so a binding written every frame finds
    // it without making another).
    const kind = familyOfName(name);
    if (kind == FAMILY_NONE) return null;
    let at: ClassInfo? = c;
    while (at != null) {
        const fs = at.families;
        for (let i = 0; i < fs.length; i++) {
            const t = fs[i];
            if (t.family != kind) continue;
            const p = new PropInfo(name, t.type, t.def, t.doc);
            p.family = kind;
            p.animates = t.animates;
            p.bindable = t.bindable;
            index.set(name, p);
            return p;
        }
        const b = at.base;
        at = b != null ? classInfo(b) : null;
    }
    return null;
}

// Milestone 48: the families of properties of the class and its bases
// (their templates, the root base's first).
export function classFamilies(className: string): Array<PropInfo> {
    const chain = new Array<ClassInfo>();
    let c = classInfo(className);
    while (c != null) {
        chain.unshift(c);
        const b = c.base;
        c = b != null ? classInfo(b) : null;
    }
    const out = new Array<PropInfo>();
    for (let i = 0; i < chain.length; i++) for (let j = 0; j < chain[i].families.length; j++) out.push(chain[i].families[j]);
    return out;
}

// Every property of the class, the root base's first.
export function allProps(className: string): Array<PropInfo> {
    const chain = new Array<ClassInfo>();
    let c = classInfo(className);
    while (c != null) {
        chain.unshift(c);
        const b = c.base;
        c = b != null ? classInfo(b) : null;
    }
    const out = new Array<PropInfo>();
    for (let i = 0; i < chain.length; i++) for (let j = 0; j < chain[i].props.length; j++) out.push(chain[i].props[j]);
    return out;
}

// The default of a known property (a copy); panics for an unknown one.
export function defaultValue(className: string, name: string): Value {
    const p = findProp(className, name);
    if (p == null) return panicAs<Value>("classdb: " + className + " has no property " + name);
    return p.def.clone();
}

// Milestone 31: the signals a class emits itself, its bases' first (their
// names: "body_entered", not its arguments).
export function classSignals(className: string): Array<string> {
    const chain = new Array<ClassInfo>();
    let c = classInfo(className);
    while (c != null) {
        chain.unshift(c);
        const b = c.base;
        c = b != null ? classInfo(b) : null;
    }
    const out = new Array<string>();
    for (let i = 0; i < chain.length; i++) {
        const sigs = chain[i].signals;
        for (let j = 0; j < sigs.length; j++) {
            const at = sigs[j].indexOf("(");
            out.push(at < 0 ? sigs[j] : sigs[j].substring(0, at));
        }
    }
    return out;
}

// Whether the class (or a base) emits `signal` itself.
export function hasSignal(className: string, signal: string): bool {
    return classSignals(className).includes(signal);
}

// Every class name in definition order (nodes first, then resources).
export function classNames(): Array<string> {
    table();
    return classOrder.slice(0);
}

// The node classes a document may use as `type` (the concrete ones).
export function nodeClassNames(): Array<string> {
    const out = new Array<string>();
    const names = classNames();
    for (let i = 0; i < names.length; i++) {
        const c = classInfo(names[i]) as ClassInfo;
        if (c.isNode && !c.isAbstract) out.push(c.name);
    }
    return out;
}

// The types a sub_resource may have.
export function subResourceClassNames(): Array<string> {
    const out = new Array<string>();
    const names = classNames();
    for (let i = 0; i < names.length; i++) {
        const c = classInfo(names[i]) as ClassInfo;
        if (c.subResource) out.push(c.name);
    }
    return out;
}

// The types an ext_resource may have.
export function extTypeNames(): Array<string> {
    const out = new Array<string>();
    const names = classNames();
    for (let i = 0; i < names.length; i++) {
        const c = classInfo(names[i]) as ClassInfo;
        if (c.extType) out.push(c.name);
    }
    return out;
}

// Whether an ext_resource of `type` may name a file with this extension
// (compared without case; no dot).
export function extTypeAccepts(type: string, extension: string): bool {
    const c = classInfo(type);
    if (c == null || !c.extType) return false;
    const e = toAsciiLowercase(extension);
    return c.extensions.includes(e);
}
