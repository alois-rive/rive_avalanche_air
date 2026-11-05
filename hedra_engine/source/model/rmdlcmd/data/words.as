// The data form's vocabulary: the record names and the form each one takes
// (what an error's hint shows), the enum words that are not the scene's own
// name functions, and the defaults a writer leaves out and a reader fills
// in.
//
// Enum words are Hedra's command-language words for the same value
// (engine/src/commands/lang/registry: `--type mesh`, `--mode edit`,
// `modifier add edge-split`, `constraint add copy-location --space local`,
// `attribute add --type vec3`); where the language has none (a keyframe's
// interpolation inside `--keys`, a selection-history entry's kind) the
// codec's variant index stands in.

import { Scene, Material, Camera, Light, RenderDefaults } from "../../scene";
import { Bone } from "../../armature/mod";
import { ShapeKey } from "../../mesh/shapekey";
import { FlagSpec, sw, one, many } from "./line";

// ObjectData kinds by CameraKind index.
export const CAMERA_TYPES: Array<string> = ["perspective", "orthographic"];
// By ParentKindTag (Object, Bone, Armature).
export const PARENT_TYPES: Array<string> = ["object", "bone", "armature"];
// By ModifierKindTag. `ext` carries the extension's own kind in --ext-kind.
export const MODIFIER_KINDS: Array<string> = [
    "mirror", "subsurf", "array", "solidify", "bevel", "triangulate", "weld", "edge-split", "armature", "tool",
    "instance", "ext",
];
// The material texture slots, in the codec's order (MaterialTextures).
export const TEXTURE_SLOTS: Array<string> = ["base-color", "normal", "metallic-roughness", "emission", "occlusion"];

// The index of `w` in `words`, -1 when absent.
export function wordIndex(words: Array<string>, w: string): i32 {
    for (let i = 0; i < words.length; i++) if (words[i] == w) return i;
    return -1;
}

// The records, in file order, and the form of each (the hint of an error at
// such a line).
export const RECORDS: Array<string> = [
    "scene", "material", "action", "fcurve", "object", "vgroup", "modifier", "mesh", "shapekey", "attribute",
    "selection-set", "armature", "bone", "constraint", "pose-clip", "import",
];

const FORMS: Array<string> = [
    "data scene [--objects N] [--object-holes \"i...\"] [--actions N] [--action-holes \"i...\"] [--active <id>] [--mode object|edit|pose|weight] [--select-mode \"v e f\"] [--cursor \"9 numbers\"] [--pivot <word>] [--orientation <word>] [--frame N] [--frame-range \"start end\"] [--fps F] [--frame-step N] [--render-size \"w h\"] [--render-background \"r g b a\"] [--render-shading <word>]",
    "data material <index> <name> [--file <path.mtlx>] [--base-color \"r g b\"] [--metallic F] [--roughness F] [--emission \"r g b\"] [--emission-strength F] [--alpha F] [--alpha-mode opaque|mask|blend] [--alpha-cutoff F] [--double-sided] [--<slot>-texture <path> [--<slot>-uv <layer>]]",
    "data action <id> <name>",
    "data fcurve <action id> <data-path> <array-index> [--keys \"12 numbers a key\"] [--extrapolation constant|linear|cyclic] [--mute]",
    "data object <id> <name> --type mesh|armature|camera|light|empty [--transform \"9 numbers\"] [--parent <id> [--parent-type object|bone|armature] [--parent-bone <name>]] [--parent-inverse \"16 numbers\"] [--select] [--hide] [--hide-render] [--material-slots \"i...\"] [--active-vgroup <i>] [--animation <action id>|none] [camera, light or empty flags: --empty-display, --empty-size, --instance <model file>]",
    "data vgroup <object id> <name> [--lock]",
    "data modifier <object id> <name> <kind> [--disabled] [the kind's flags]",
    "data mesh <object id> [--verts N --vert-holes \"i...\" --co \"x y z...\" --vert-flags --vert-groups] [--edges N --edge-holes --edge-verts \"a b...\" --edge-flags --crease --bevel-weight] [--faces N --face-holes --face-loops \"start len...\" --face-normals --face-flags --face-materials] [--loops N --loop-holes --loop-refs \"vert edge face...\" --loop-uvs --loop-uv-flags] [--uv-layer <name>...] [--active-uv N] [--select-history \"kind id...\"] [--active-shape-key N]",
    "data shapekey <object id> <name> [--value F] [--slider-min F] [--slider-max F] [--relative-to N] [--mute] [--co \"x y z...\"]",
    "data attribute <object id> <name> [--domain point|edge|face|corner] [--type float|int|bool|vec3] [--values \"...\"]",
    "data selection-set <object id> <name> [--verts \"i...\"] [--edges \"i...\"] [--faces \"i...\"]",
    "data armature <object id> [--bones N] [--bone-holes \"i...\"] [--active <bone id>] [--display octahedral|stick] [--collection <name> <0|1>...]",
    "data bone <object id> <bone id> <name> [--head \"x y z\"] [--tail \"x y z\"] [--roll F] [--parent <bone id>] [--connected] [--deform] [--inherit-rotation] [--inherit-scale] [--envelope \"distance weight\"] [--radius \"head tail\"] [--collection <name>...] [--select] [--select-head] [--select-tail] [--hide] [--pose-location \"x y z\"] [--pose-rotation \"x y z w\"] [--pose-scale \"x y z\"] [--pose-select] [--pose-hide]",
    "data constraint <object id> <bone id> <name> <kind> [--influence F] [--disabled] [--space world|local] [--target <object id> [--subtarget <bone>]] [the kind's flags]",
    "data pose-clip <bone name> [--location \"x y z\"] [--rotation \"x y z w\"] [--scale \"x y z\"]",
    "data import <path> [--hash <hex>] [--bytes N] [--object <name>...]",
];

// The form of a record, for a hint: "the form is `data ...`".
export function formHint(record: string): string {
    const i = wordIndex(RECORDS, record);
    if (i < 0) return "a data line is `data <record> ...`, one of: " + RECORDS.join(", ");
    return "the form is `" + FORMS[i] + "`";
}

// ------------------------------------------------------------ flag tables

// Each record's flags, in the order the writer writes them (write.as), and
// how many positionals it takes: what splits a line (line.as splitLine),
// for the replay (read.as) and for the .rmdl document's bridge, which
// splits the lines it writes with them (../../rmdl/write.as).

function sceneSpecs(): Array<FlagSpec> {
    return [
        one("objects"), one("object-holes"), one("objects-live"), one("actions"), one("action-holes"),
        one("actions-live"), one("active"), one("mode"), one("select-mode"), one("cursor"), one("pivot"),
        one("orientation"), one("frame"), one("frame-range"), one("fps"), one("frame-step"), one("render-size"),
        one("render-background"), one("render-shading"),
    ];
}

function materialSpecs(): Array<FlagSpec> {
    const out: Array<FlagSpec> = [
        one("file"), one("base-color"), one("metallic"), one("roughness"), one("emission"), one("emission-strength"), one("alpha"),
        one("alpha-mode"), one("alpha-cutoff"), sw("double-sided"),
    ];
    for (let i = 0; i < TEXTURE_SLOTS.length; i++) {
        out.push(one(TEXTURE_SLOTS[i] + "-texture"));
        out.push(one(TEXTURE_SLOTS[i] + "-uv"));
    }
    return out;
}

function fcurveSpecs(): Array<FlagSpec> {
    return [one("keys"), one("extrapolation"), sw("mute")];
}

function objectSpecs(): Array<FlagSpec> {
    return [
        one("type"), one("transform"), one("parent"), one("parent-type"), one("parent-bone"), one("parent-inverse"),
        sw("select"), sw("hide"), sw("hide-render"), one("material-slots"), one("active-vgroup"), one("animation"),
        one("camera-type"), one("focal-length"), one("ortho-scale"), one("clip-start"), one("clip-end"),
        one("light-type"), one("color"), one("energy"), one("empty-display"), one("empty-size"), one("instance"),
    ];
}

function modifierSpecs(): Array<FlagSpec> {
    return [
        sw("disabled"), one("axis"), sw("clipping"), sw("merge"), one("merge-threshold"), one("levels"),
        one("render-levels"), one("count"), one("relative-offset"), one("constant-offset"), one("thickness"),
        one("offset"), sw("even"), one("width"), one("segments"), one("angle-limit"), one("distance"), one("angle"),
        one("object"), sw("preserve-volume"), sw("use-vertex-groups"), sw("use-envelopes"), one("tool"),
        many("param", 1), one("hash"), one("scale"), one("scale-attr"), sw("align"), one("rotation"),
        one("rotation-attr"), one("ext-kind"), many("prop", 1),
    ];
}

function meshSpecs(): Array<FlagSpec> {
    return [
        one("verts"), one("vert-holes"), one("verts-live"), one("co"), one("vert-flags"), one("vert-groups"),
        one("edges"), one("edge-holes"), one("edges-live"), one("edge-verts"), one("edge-flags"), one("crease"),
        one("bevel-weight"), one("faces"), one("face-holes"), one("faces-live"), one("face-loops"),
        one("face-normals"), one("face-flags"), one("face-materials"), one("loops"), one("loop-holes"),
        one("loops-live"), one("loop-refs"), one("loop-uvs"), one("loop-uv-flags"), many("uv-layer", 1),
        one("active-uv"), one("select-history"), one("active-shape-key"),
    ];
}

function shapeKeySpecs(): Array<FlagSpec> {
    return [one("value"), one("slider-min"), one("slider-max"), one("relative-to"), sw("mute"), one("co")];
}

function attributeSpecs(): Array<FlagSpec> {
    return [one("domain"), one("type"), one("values")];
}

function selectionSetSpecs(): Array<FlagSpec> {
    return [one("verts"), one("edges"), one("faces")];
}

function armatureSpecs(): Array<FlagSpec> {
    return [one("bones"), one("bone-holes"), one("bones-live"), one("active"), one("display"), many("collection", 2)];
}

function boneSpecs(): Array<FlagSpec> {
    return [
        one("head"), one("tail"), one("roll"), one("parent"), sw("connected"), sw("deform"), sw("inherit-rotation"),
        sw("inherit-scale"), one("envelope"), one("radius"), many("collection", 1), sw("select"), sw("select-head"),
        sw("select-tail"), sw("hide"), one("pose-location"), one("pose-rotation"), one("pose-scale"),
        sw("pose-select"), sw("pose-hide"),
    ];
}

function constraintSpecs(): Array<FlagSpec> {
    return [
        one("influence"), sw("disabled"), one("space"), one("target"), one("subtarget"), one("pole"),
        one("pole-subtarget"), one("pole-angle"), one("chain-length"), one("iterations"), sw("use-tail"), one("axes"),
        one("invert"), sw("offset"), one("mix"), one("min"), one("max"), one("use-min"), one("use-max"), one("track"),
        one("up"), one("rest-length"), sw("volume"), one("inverse"),
    ];
}

function poseClipSpecs(): Array<FlagSpec> {
    return [one("location"), one("rotation"), one("scale")];
}

function importSpecs(): Array<FlagSpec> {
    return [one("hash"), one("bytes"), many("object", 1)];
}

// The tables, built once, by the records' indices in RECORDS.
let SPECS: Array<Array<FlagSpec>>? = null;
export const POSITIONALS: Array<i32> = [0, 2, 2, 3, 2, 2, 3, 1, 2, 2, 2, 1, 3, 4, 1, 1];

export function specsOf(record: i32): Array<FlagSpec> {
    if (SPECS == null) {
        SPECS = [
            sceneSpecs(), materialSpecs(), [], fcurveSpecs(), objectSpecs(), [sw("lock")], modifierSpecs(), meshSpecs(),
            shapeKeySpecs(), attributeSpecs(), selectionSetSpecs(), armatureSpecs(), boneSpecs(), constraintSpecs(),
            poseClipSpecs(), importSpecs(),
        ];
    }
    return SPECS![record];
}

// ------------------------------------------------------------ defaults

// What a field is when its flag is left out: a new datablock's value
// (a bool flag is always false when absent: it is a switch).
let defaultScene: Scene? = null;
let defaultMaterial: Material? = null;
let defaultCamera: Camera? = null;
let defaultLight: Light? = null;
let defaultBone: Bone? = null;
let defaultShapeKey: ShapeKey? = null;
let defaultRender: RenderDefaults? = null;

export function sceneDefaults(): Scene {
    if (defaultScene == null) defaultScene = new Scene();
    return defaultScene!;
}

export function materialDefaults(): Material {
    if (defaultMaterial == null) defaultMaterial = new Material();
    return defaultMaterial!;
}

export function cameraDefaults(): Camera {
    if (defaultCamera == null) defaultCamera = new Camera();
    return defaultCamera!;
}

export function lightDefaults(): Light {
    if (defaultLight == null) defaultLight = new Light();
    return defaultLight!;
}

export function boneDefaults(): Bone {
    if (defaultBone == null) defaultBone = new Bone();
    return defaultBone!;
}

export function shapeKeyDefaults(): ShapeKey {
    if (defaultShapeKey == null) defaultShapeKey = new ShapeKey();
    return defaultShapeKey!;
}

export function renderDefaults(): RenderDefaults {
    if (defaultRender == null) defaultRender = new RenderDefaults();
    return defaultRender!;
}
