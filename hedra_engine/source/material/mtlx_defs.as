// What Hedra's MaterialX profile knows of MaterialX's node definitions
// (milestone 14): the nodes a material file may use, each input with its
// type and its nodedef's default, and the table of glTF's texture slots
// that the reader (mtlx.as) and the writer (mtlx_write.as) share, so that
// the two cannot disagree about a node's name, kind or channel.
//
// The definitions are MaterialX's own, copied by hand from the pinned
// commit 33ff76c93665e44cdcb29d40eb978b39e0890edf (2026-06-22):
// libraries/bxdf/gltf_pbr.mtlx (ND_gltf_pbr_surfaceshader 2.0.1 and the
// glTF texture nodes) and libraries/stdlib/stdlib_defs.mtlx (extract,
// normalmap, mix, texcoord, constant). Only what the profile reads is
// here; docs/formats/MATERIALS.md is the normative description.

import { PbrSlot } from "../../material/pbr";

// The version the writer writes, and the newest the reader reads.
export const MTLX_DEFS_VERSION = "1.39";

// One input of a node definition: its name, type and default as MaterialX
// writes it ("" for none: an input whose default is a geometric property,
// as gltf_pbr's `normal`, or that has no value, as `attenuation_distance`).
export class MtlxInputDef {
    name: string;
    type: string;
    def: string;

    constructor(name: string, type: string, def: string) {
        this.name = name;
        this.type = type;
        this.def = def;
    }
}

function i(name: string, type: string, def: string): MtlxInputDef {
    return new MtlxInputDef(name, type, def);
}

// gltf_pbr's inputs, in its nodedef's order (the order the writer writes).
export const GLTF_PBR_INPUTS: Array<MtlxInputDef> = [
    i("base_color", "color3", "1, 1, 1"),
    i("metallic", "float", "1"),
    i("roughness", "float", "1"),
    i("normal", "vector3", ""),
    i("tangent", "vector3", ""),
    i("occlusion", "float", "1"),
    i("transmission", "float", "0"),
    i("specular", "float", "1"),
    i("specular_color", "color3", "1, 1, 1"),
    i("ior", "float", "1.5"),
    i("alpha", "float", "1"),
    i("alpha_mode", "integer", "0"),
    i("alpha_cutoff", "float", "0.5"),
    i("iridescence", "float", "0"),
    i("iridescence_ior", "float", "1.3"),
    i("iridescence_thickness", "float", "100"),
    i("sheen_color", "color3", "0, 0, 0"),
    i("sheen_roughness", "float", "0"),
    i("clearcoat", "float", "0"),
    i("clearcoat_roughness", "float", "0"),
    i("clearcoat_normal", "vector3", ""),
    i("emissive", "color3", "0, 0, 0"),
    i("emissive_strength", "float", "1"),
    i("thickness", "float", "0"),
    i("attenuation_distance", "float", ""),
    i("attenuation_color", "color3", "1, 1, 1"),
    i("anisotropy_strength", "float", "0"),
    i("anisotropy_rotation", "float", "0"),
    i("dispersion", "float", "0"),
];

// The image inputs every glTF texture node has, before its own: `factor`
// (gltf_image's, of its type) comes between `file` and `default`.
function imageInputs(factorType: string, defaultType: string, defaultValue: string, pivot: string, order: string): Array<MtlxInputDef> {
    const out: Array<MtlxInputDef> = [i("file", "filename", "")];
    if (factorType.length > 0) out.push(i("factor", factorType, ones(factorType)));
    out.push(i("default", defaultType, defaultValue));
    out.push(i("texcoord", "vector2", ""));
    out.push(i("pivot", "vector2", pivot));
    out.push(i("scale", "vector2", "1, 1"));
    out.push(i("rotate", "float", "0"));
    out.push(i("offset", "vector2", "0, 0"));
    if (order.length > 0) out.push(i("operationorder", "integer", order));
    out.push(i("uaddressmode", "string", "periodic"));
    out.push(i("vaddressmode", "string", "periodic"));
    out.push(i("filtertype", "string", "linear"));
    return out;
}

function ones(type: string): string {
    if (type == "color3" || type == "vector3") return "1, 1, 1";
    if (type == "color4") return "1, 1, 1, 1";
    return "1";
}

// The inputs of node `category` whose output type is `type` (a gltf_image's
// type chooses its nodedef; a multi-output node's is "multioutput"), or
// null when the profile has no such node. `inType` is an extract's `in`
// type (color3, color4 or vector3), which chooses its nodedef.
export function nodeInputs(category: string, type: string, inType: string = "color3"): Array<MtlxInputDef>? {
    if (category == "gltf_image") {
        if (type == "float") return imageInputs("float", "float", "0", "0, 1", "0");
        if (type == "color3") return imageInputs("color3", "color3", "0, 0, 0", "0, 1", "0");
        if (type == "color4") return imageInputs("color4", "color4", "0, 0, 0, 0", "0, 1", "1");
        if (type == "vector3") return imageInputs("", "vector3", "0, 0, 0", "0, 1", "0");
        return null;
    }
    if (category == "gltf_colorimage") {
        if (type != "multioutput") return null;
        const out = imageInputs("", "color4", "0, 0, 0, 0", "0, 1", "1");
        out.push(i("color", "color4", "1, 1, 1, 1"));
        out.push(i("geomcolor", "color4", "1, 1, 1, 1"));
        return out;
    }
    if (category == "gltf_normalmap") {
        if (type != "vector3") return null;
        return imageInputs("", "vector3", "0.5, 0.5, 1", "0, 1", "0");
    }
    if (category == "gltf_iridescence_thickness") {
        if (type != "float") return null;
        const out = imageInputs("", "vector3", "0, 0, 0", "0, 0", "");
        out.push(i("thicknessMin", "float", "100"));
        out.push(i("thicknessMax", "float", "400"));
        return out;
    }
    if (category == "gltf_anisotropy_image") {
        if (type != "multioutput") return null;
        const out = imageInputs("", "vector3", "1, 0.5, 1", "0, 1", "0");
        out.push(i("anisotropy_strength", "float", "1"));
        out.push(i("anisotropy_rotation", "float", "0"));
        return out;
    }
    if (category == "extract") {
        const zero = inType == "color4" ? "0, 0, 0, 0" : "0, 0, 0";
        return [i("in", inType, zero), i("index", "integer", "0")];
    }
    if (category == "normalmap") {
        // `space` is 1.38's (its ND_normalmap reads tangent or object
        // space; 1.39 has tangent space alone), read for 1.38's files.
        return [i("in", "vector3", "0.5, 0.5, 1"), i("scale", "float", "1"), i("normal", "vector3", ""),
            i("tangent", "vector3", ""), i("bitangent", "vector3", ""), i("space", "string", "tangent")];
    }
    if (category == "mix") return [i("fg", "float", "0"), i("bg", "float", "0"), i("mix", "float", "0")];
    if (category == "texcoord") return [i("index", "integer", "0")];
    if (category == "constant") {
        if (type == "float" || type == "integer") return [i("value", type, "0")];
        if (type == "boolean") return [i("value", type, "false")];
        if (type == "color3" || type == "vector3") return [i("value", type, "0, 0, 0")];
        if (type == "color4") return [i("value", type, "0, 0, 0, 0")];
        if (type == "vector2") return [i("value", type, "0, 0")];
        return null;
    }
    return null;
}

// The input definition `name` of a list, or null.
export function findInput(defs: Array<MtlxInputDef>, name: string): MtlxInputDef? {
    for (let k = 0; k < defs.length; k++) if (defs[k].name == name) return defs[k];
    return null;
}

// The image inputs the profile does not model (MaterialX has them, glTF
// has not): kept out of a material at their defaults, warned about
// (mtlx-ignored) otherwise.
export const UNMODELLED_IMAGE_INPUTS: Array<string> = [
    "default", "pivot", "operationorder", "uaddressmode", "vaddressmode", "filtertype", "geomcolor",
];

// How a texture slot is written and read: the image node (its name in the
// canonical form, category and type), where it goes (a gltf_pbr input, or
// an output of the hedra_extras nodegraph), and, for a slot read from one
// channel through an `extract`, that channel and the extract's name.
export class MtlxSlot {
    slot: i32;
    node: string;
    category: string;
    type: string;
    // The gltf_pbr input it feeds, or "" (`extra` then names the output).
    input: string;
    extra: string;
    // The channel an `extract` takes (-1: none; the node's output is the
    // value).
    channel: i32;
    // The slot's colours are sRGB (its factor is a colour).
    srgb: bool;

    constructor(slot: i32, node: string, category: string, type: string, input: string, extra: string, channel: i32, srgb: bool) {
        this.slot = slot;
        this.node = node;
        this.category = category;
        this.type = type;
        this.input = input;
        this.extra = extra;
        this.channel = channel;
        this.srgb = srgb;
    }

    // The extract's name: `<input>_channel`.
    channelNode(): string {
        return (this.input.length > 0 ? this.input : this.extra) + "_channel";
    }
}

function s(slot: i32, node: string, category: string, type: string, input: string, channel: i32, srgb: bool): MtlxSlot {
    return new MtlxSlot(slot, node, category, type, input, "", channel, srgb);
}

// By PbrSlot. A normal slot is gltf_normalmap here; with a scale other
// than 1 the writer makes it a gltf_image vector3 and a `normalmap`.
export const MTLX_SLOTS: Array<MtlxSlot> = [
    s(PbrSlot.BaseColor, "base_color_texture", "gltf_colorimage", "multioutput", "base_color", -1, true),
    s(PbrSlot.Metallic, "metallic_texture", "gltf_image", "color3", "metallic", 2, false),
    s(PbrSlot.Roughness, "roughness_texture", "gltf_image", "color3", "roughness", 1, false),
    s(PbrSlot.Normal, "normal_texture", "gltf_normalmap", "vector3", "normal", -1, false),
    s(PbrSlot.Occlusion, "occlusion_texture", "gltf_image", "float", "occlusion", -1, false),
    s(PbrSlot.Emissive, "emissive_texture", "gltf_image", "color3", "emissive", -1, true),
    s(PbrSlot.Clearcoat, "clearcoat_texture", "gltf_image", "float", "clearcoat", -1, false),
    s(PbrSlot.ClearcoatRoughness, "clearcoat_roughness_texture", "gltf_image", "color3", "clearcoat_roughness", 1, false),
    s(PbrSlot.ClearcoatNormal, "clearcoat_normal_texture", "gltf_normalmap", "vector3", "clearcoat_normal", -1, false),
    s(PbrSlot.SheenColor, "sheen_color_texture", "gltf_image", "color3", "sheen_color", -1, true),
    s(PbrSlot.SheenRoughness, "sheen_roughness_texture", "gltf_image", "color4", "sheen_roughness", 3, false),
    s(PbrSlot.Specular, "specular_texture", "gltf_image", "color4", "specular", 3, false),
    s(PbrSlot.SpecularColor, "specular_color_texture", "gltf_image", "color3", "specular_color", -1, true),
    s(PbrSlot.Transmission, "transmission_texture", "gltf_image", "float", "transmission", -1, false),
    s(PbrSlot.Thickness, "thickness_texture", "gltf_image", "color3", "thickness", 1, false),
    s(PbrSlot.Iridescence, "iridescence_texture", "gltf_image", "float", "iridescence", -1, false),
    s(PbrSlot.IridescenceThickness, "iridescence_thickness_texture", "gltf_iridescence_thickness", "float",
        "iridescence_thickness", -1, false),
    s(PbrSlot.Anisotropy, "anisotropy_texture", "gltf_anisotropy_image", "multioutput", "anisotropy_strength", -1, false),
    new MtlxSlot(PbrSlot.DiffuseTransmission, "diffuse_transmission_texture", "gltf_image", "color4", "",
        "diffuse_transmission", 3, false),
    new MtlxSlot(PbrSlot.DiffuseTransmissionColor, "diffuse_transmission_color_texture", "gltf_image", "color3", "",
        "diffuse_transmission_color", -1, true),
];

// A side of an artboard texture's rive_size, at most (Hedra's limit on a
// texture side, as artboard_texture.as MAX_ARTBOARD_TEXTURE_SIDE): the
// reader refuses a larger one, so the writer leaves it out.
export const RIVE_SIZE_MAX: i32 = 8192;

// The node a shared metallic-roughness texture is written as.
export const METALLIC_ROUGHNESS_NODE = "metallic_roughness_texture";

// The nodegraph that holds what gltf_pbr has no input for.
export const EXTRAS_GRAPH = "hedra_extras";

// Its outputs, in the order the writer writes them, with their types
// (milestone 35: StandardMaterial3D's billboard_mode, Godot's enum 0 to 3,
// and billboard_keep_scale, last, so that a material without them writes
// the bytes it wrote before; milestone 62: Godot's refraction_scale after
// them, for the same reason).
export const EXTRA_NAMES: Array<string> = [
    "double_sided", "cull_front", "unlit", "iridescence_thickness_minimum", "diffuse_transmission",
    "diffuse_transmission_color", "vertex_color_use_as_albedo", "vertex_color_is_srgb", "billboard_mode",
    "billboard_keep_scale", "refraction_scale",
];
export const EXTRA_TYPES: Array<string> = [
    "boolean", "boolean", "boolean", "float", "float", "color3", "boolean", "boolean", "integer", "boolean", "float",
];

// Godot's StandardMaterial3D refraction_scale, which the writer leaves out.
export const MTLX_REFRACTION_SCALE_DEFAULT: f32 = 0.05;

// Milestone 35: what a material file keeps that a PbrMaterial (glTF's
// model) has no field for: StandardMaterial3D's billboard_mode (0
// disabled, 1 enabled, 2 fixed_y, 3 particles: the turn a CPUParticles3D
// gives its particles) and billboard_keep_scale, carried beside the
// PbrMaterial (MtlxRead.billboard, writeMtlx's `billboard`). Milestone 62:
// Godot's refraction_scale too (how far a thin wall moves what it shows
// when the scene refracts the screen), the class keeping its first
// extras' name.
export class MtlxBillboard {
    mode: i32 = 0;
    keepScale: bool = false;
    refractionScale: f32 = MTLX_REFRACTION_SCALE_DEFAULT;
}

// billboard_mode's largest value (particles).
export const MTLX_BILLBOARD_MAX: i32 = 3;

// The type of extra `name`, or "" when there is none of that name.
export function extraType(name: string): string {
    const k = EXTRA_NAMES.indexOf(name);
    return k >= 0 ? EXTRA_TYPES[k] : "";
}

// The node categories the profile reads (anything else in a material's
// graph is mtlx-node-unsupported).
export const NODE_CATEGORIES: Array<string> = [
    "gltf_pbr", "gltf_colorimage", "gltf_image", "gltf_normalmap", "gltf_anisotropy_image", "gltf_iridescence_thickness",
    "extract", "normalmap", "mix", "texcoord", "constant",
];

// Elements of a document that are not part of a material (looks, material
// assignments, geometry information, ...): read past with an mtlx-ignored
// warning.
export const IGNORED_ELEMENTS: Array<string> = [
    "look", "lookgroup", "materialassign", "visibility", "collection", "geominfo", "geompropdef", "backdrop", "propertyset",
    "propertysetassign", "variantset", "variantassign", "typedef", "nodedef", "implementation", "unitdef", "unittypedef",
    "attributedef", "targetdef", "token",
];

// Attributes a node or an input may carry for a user interface or a
// document's own bookkeeping: read past with an mtlx-ignored warning.
export const UI_ATTRIBUTES: Array<string> = [
    "xpos", "ypos", "width", "height", "uiname", "uifolder", "uicolor", "uimin", "uimax", "uisoftmin", "uisoftmax", "uistep",
    "uiadvanced", "uivisible", "doc", "hint", "enum", "enumvalues", "minimized", "defaultgeomprop",
];
