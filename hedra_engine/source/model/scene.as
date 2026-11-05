// The scene model (PLAN §3.3). Objects with typed
// data, transforms, parenting, and the session state Blender keeps in the
// .blend (mode, select mode, cursor, pivot, orientation, frame).
//
// Conventions:
//   * Field order of every type is the postcard file format; enum values
//     are the variant indices.
//   * An optional object id is a u32 with NO_OBJ (u32.MAX_VALUE) for "none"
//     (`Scene.active`, `find`, `ModifierKindArmature.object`, ...); optional
//     vgroup indices use NO_VGROUP; optional material indices are i32 with
//     -1; an optional action uses ACTION_NONE.
//   * Enum `parse` functions return i32 with -1 for an unknown name.
//   * Enums with payloads: `ObjectData` and `ParentKind` are tagged classes;
//     `ModifierKind` is an abstract base with one subclass per variant
//     (`ModifierKindMirror`, ...), dispatched on `tag` (the Ext variant has a
//     field named `kind`).
//   * String maps are Map<string, string>; iterate them with
//     `sortedKeys(m)` (byte order), never in insertion order.
//   * `Transform`, `SelectMode`, `FrameRangeI32` are structs (values).
//     Everything else is a class with a deep `clone()` and, where
//     comparison is needed, `equals()`.
//   * The caches are plain Maps; `poseKey` / `modifierFingerprint` are
//     in-process cache keys only, hashed with FNV-1a.

import { Vec3, Mat4, MAT4_IDENTITY } from "../../base/vecmath";
import { SlotVec } from "../../base/slot";
import {
    Result, stableSort, cmpStr, toAsciiLowercase, lowerCaseUnicode, FNV64_OFFSET, FNV64_PRIME, FNV64_PRIME_MODELER,
    fnv1a64Bytes,
} from "../../base/util";
import { CoreError } from "../../base/error";
import { decompose, quatFromEulerXyz } from "../../base/math";
import {
    debugStr, debugStruct, debugList, debugSet, debugSome, DEBUG_NONE, debugF32, zeroPad, hexU64,
} from "../../base/fmt";
import { Mesh } from "./mesh/mod";
import { SelectMode, selectModeDefault } from "./mesh/select_mode";
import { Armature, Bone, BoneId, PoseBone, NO_BONE } from "./armature/mod";
import { ConstraintTarget, ConstraintKindIk, ConstraintKindTag, bool3 } from "./armature/constraints";
import { PoseEval, TargetFn, TargetMatrix, NO_OBJ } from "./armature/pose";
import { Action, AnimData, ACTION_NONE } from "./anim/mod";
import { PoseClip } from "./armature/pose_clip";
import {
    ModifierEnv, evaluate as modifiersEvaluate, extTypeName, extModifiers,
    objectHasActiveModifiers, objectModifierFingerprint, objectEvaluatedMesh, reevaluateDeform, stackIsDeformOnly,
} from "./modifiers/mod";
import {
    FrameReport, FrameEvaluation, applyFrame as evalApplyFrame, evaluateAt as evalEvaluateAt,
    actionUsers as evalActionUsers,
} from "./anim/eval";

export { SelectMode, selectModeDefault, NO_OBJ };
// Re-exported so scene users need not import the armature module.
export { Armature, Bone, BoneId, PoseBone };

export type ObjId = u32;

// "No vertex group" for `Object.activeVgroup` / `vgroupIndex`.
export const NO_VGROUP: u32 = u32.MAX_VALUE;

// The keys of a string map in byte order.
export function sortedKeys(m: Map<string, string>): Array<string> {
    const keys = m.keys();
    stableSort<string>(keys, cmpStr);
    return keys;
}

function cloneStrMap(m: Map<string, string>): Map<string, string> {
    const out = new Map<string, string>();
    const keys = sortedKeys(m);
    for (let i = 0; i < keys.length; i++) out.set(keys[i], m.get(keys[i]));
    return out;
}

function strMapEquals(a: Map<string, string>, b: Map<string, string>): bool {
    if (a.size != b.size) return false;
    const keys = a.keys();
    for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        if (!b.has(k) || b.get(k) != a.get(k)) return false;
    }
    return true;
}

// Debug text of a string map, keys in byte order: `{"a": "b", "c": "d"}`.
function debugStrMap(m: Map<string, string>): string {
    const keys = sortedKeys(m);
    const parts: Array<string> = [];
    for (let i = 0; i < keys.length; i++) parts.push(debugStr(keys[i]) + ": " + debugStr(m.get(keys[i])));
    return debugSet(parts);
}

function debugBool(b: bool): string {
    return b ? "true" : "false";
}

function debugOptStr(s: string?): string {
    return s != null ? debugSome(debugStr(s)) : DEBUG_NONE;
}

function debugOptObj(id: u32): string {
    return id != NO_OBJ ? debugSome(id.toString()) : DEBUG_NONE;
}

function optStrEq(a: string?, b: string?): bool {
    if (a == null) return b == null;
    if (b == null) return false;
    return a == b;
}

function copyBools(a: Array<bool>): Array<bool> {
    const out: Array<bool> = [];
    for (let i = 0; i < a.length; i++) out.push(a[i]);
    return out;
}

function copyF32s(a: Array<f32>): Array<f32> {
    const out: Array<f32> = [];
    for (let i = 0; i < a.length; i++) out.push(a[i]);
    return out;
}

function f32ArrEq(a: Array<f32>, b: Array<f32>): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
    return true;
}

// ---------------------------------------------------------------- Transform

// Location, rotation and scale (a value).
export struct Transform {
    location: Vec3 = Vec3(0, 0, 0);
    // Euler XYZ in radians.
    rotation: Vec3 = Vec3(0, 0, 0);
    scale: Vec3 = Vec3(1, 1, 1);

    constructor(location: Vec3, rotation: Vec3, scale: Vec3) {
        this.location = location;
        this.rotation = rotation;
        this.scale = scale;
    }

    operator==(a: Transform, b: Transform): bool {
        return a.location == b.location && a.rotation == b.rotation && a.scale == b.scale;
    }

    readonly hash(): u32 {
        return this.location.hash() ^ (this.rotation.hash() * 31) ^ (this.scale.hash() * 961);
    }

    readonly matrix(): Mat4 {
        return Mat4.fromScaleRotationTranslation(this.scale, quatFromEulerXyz(this.rotation), this.location);
    }

    // Derived Debug.
    readonly debug(): string {
        return debugStruct(
            "Transform",
            ["location", "rotation", "scale"],
            [this.location.debug(), this.rotation.debug(), this.scale.debug()],
        );
    }
}

export namespace Transform {
    export function fromMatrix(m: Mat4): Transform {
        const d = decompose(m);
        return Transform(d.location, d.rotation, d.scale);
    }}

// The identity transform (also the default).
export const TRANSFORM_IDENTITY: Transform = Transform(Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1));

// ------------------------------------------------------------------ Camera

export enum CameraKind {
    Perspective = 0,
    Orthographic = 1,
}

// Derived Debug of CameraKind (`inspect` lowercases it).
export function cameraKindDebug(k: CameraKind): string {
    return k == CameraKind.Perspective ? "Perspective" : "Orthographic";
}

export class Camera {
    kind: CameraKind = CameraKind.Perspective;
    focalLengthMm: f32 = 50.0;
    orthoScale: f32 = 6.0;
    clipStart: f32 = 0.1;
    clipEnd: f32 = 1000.0;

    // Blender's default camera.
    constructor() {}

    clone(): Camera {
        const c = new Camera();
        c.kind = this.kind;
        c.focalLengthMm = this.focalLengthMm;
        c.orthoScale = this.orthoScale;
        c.clipStart = this.clipStart;
        c.clipEnd = this.clipEnd;
        return c;
    }

    equals(o: Camera): bool {
        return this.kind == o.kind && this.focalLengthMm == o.focalLengthMm && this.orthoScale == o.orthoScale
            && this.clipStart == o.clipStart && this.clipEnd == o.clipEnd;
    }
}

// ------------------------------------------------------------------- Light

export enum LightKind {
    Point = 0,
    Sun = 1,
    Spot = 2,
    Area = 3,
}

// Parses a LightKind name; -1 when unknown.
export function lightKindParse(s: string): i32 {
    if (s == "point") return LightKind.Point;
    if (s == "sun") return LightKind.Sun;
    if (s == "spot") return LightKind.Spot;
    if (s == "area") return LightKind.Area;
    return -1;
}

export function lightKindName(k: LightKind): string {
    switch (k) {
        case LightKind.Point: return "point";
        case LightKind.Sun: return "sun";
        case LightKind.Spot: return "spot";
        default: return "area";
    }
}

export class Light {
    kind: LightKind = LightKind.Point;
    color: Vec3 = Vec3(1, 1, 1);
    energy: f32 = 1000.0;

    // Blender's default light.
    constructor() {}

    clone(): Light {
        const l = new Light();
        l.kind = this.kind;
        l.color = this.color;
        l.energy = this.energy;
        return l;
    }

    equals(o: Light): bool {
        return this.kind == o.kind && this.color == o.color && this.energy == o.energy;
    }
}

// ------------------------------------------------------------------- Empty

export enum EmptyDisplay {
    PlainAxes = 0,
    Arrows = 1,
    Cube = 2,
}

// Parses an EmptyDisplay name; -1 when unknown.
export function emptyDisplayParse(s: string): i32 {
    if (s == "plain-axes" || s == "plain_axes") return EmptyDisplay.PlainAxes;
    if (s == "arrows") return EmptyDisplay.Arrows;
    if (s == "cube") return EmptyDisplay.Cube;
    return -1;
}

export function emptyDisplayName(d: EmptyDisplay): string {
    switch (d) {
        case EmptyDisplay.PlainAxes: return "plain-axes";
        case EmptyDisplay.Arrows: return "arrows";
        default: return "cube";
    }
}

export class Empty {
    display: EmptyDisplay = EmptyDisplay.PlainAxes;
    // The default-constructed empty has size 0.0.
    size: f32 = 0.0;
    // A model file the empty instances (.rmdl, .rmdlcmd, .gltf, .glb):
    // relative to the model file, or absolute; null for none. Blender's
    // collection instance (an empty whose instance_type is COLLECTION),
    // Godot's instanced scene: the file's objects are drawn, exported and
    // placed in a scene as the empty's children (compose.as), never copied
    // into this scene, so an edit of that file shows wherever it is
    // instanced.
    instance: string? = null;

    constructor(display: EmptyDisplay = EmptyDisplay.PlainAxes, size: f32 = 0.0, instance: string? = null) {
        this.display = display;
        this.size = size;
        this.instance = instance;
    }

    clone(): Empty {
        return new Empty(this.display, this.size, this.instance);
    }

    equals(o: Empty): bool {
        return this.display == o.display && this.size == o.size && optStrEq(this.instance, o.instance);
    }
}

// -------------------------------------------------------------- ObjectData

export enum ObjectDataKind {
    Mesh = 0,
    Armature = 1,
    Camera = 2,
    Light = 3,
    Empty = 4,
}

// An object's data (Mesh, Armature, Camera, Light or Empty): the field
// matching `kind` is set, the others are null.
export class ObjectData {
    kind: ObjectDataKind = ObjectDataKind.Empty;
    meshData: Mesh? = null;
    armatureData: Armature? = null;
    cameraData: Camera? = null;
    lightData: Light? = null;
    emptyData: Empty? = null;

    static fromMesh(m: Mesh): ObjectData {
        const d = new ObjectData();
        d.kind = ObjectDataKind.Mesh;
        d.meshData = m;
        return d;
    }

    static fromArmature(a: Armature): ObjectData {
        const d = new ObjectData();
        d.kind = ObjectDataKind.Armature;
        d.armatureData = a;
        return d;
    }

    static fromCamera(c: Camera): ObjectData {
        const d = new ObjectData();
        d.kind = ObjectDataKind.Camera;
        d.cameraData = c;
        return d;
    }

    static fromLight(l: Light): ObjectData {
        const d = new ObjectData();
        d.kind = ObjectDataKind.Light;
        d.lightData = l;
        return d;
    }

    static fromEmpty(e: Empty): ObjectData {
        const d = new ObjectData();
        d.kind = ObjectDataKind.Empty;
        d.emptyData = e;
        return d;
    }

    typeName(): string {
        switch (this.kind) {
            case ObjectDataKind.Mesh: return "mesh";
            case ObjectDataKind.Armature: return "armature";
            case ObjectDataKind.Camera: return "camera";
            case ObjectDataKind.Light: return "light";
            default: return "empty";
        }
    }

    // The returned mesh is the object's own: changes apply to it.
    mesh(): Mesh? {
        return this.kind == ObjectDataKind.Mesh ? this.meshData : null;
    }

    armature(): Armature? {
        return this.kind == ObjectDataKind.Armature ? this.armatureData : null;
    }

    camera(): Camera? {
        return this.kind == ObjectDataKind.Camera ? this.cameraData : null;
    }

    light(): Light? {
        return this.kind == ObjectDataKind.Light ? this.lightData : null;
    }

    empty(): Empty? {
        return this.kind == ObjectDataKind.Empty ? this.emptyData : null;
    }

    // Deep copy of the payload.
    clone(): ObjectData {
        const d = new ObjectData();
        d.kind = this.kind;
        const m = this.meshData;
        if (m != null) d.meshData = m.clone();
        const a = this.armatureData;
        if (a != null) d.armatureData = a.clone();
        const c = this.cameraData;
        if (c != null) d.cameraData = c.clone();
        const l = this.lightData;
        if (l != null) d.lightData = l.clone();
        const e = this.emptyData;
        if (e != null) d.emptyData = e.clone();
        return d;
    }
}

// ------------------------------------------------------------------ Parent

export enum ParentKindTag {
    Object = 0,
    Bone = 1,
    Armature = 2,
}

// How an object is parented: to the object, to a bone (by name), or with
// armature deform.
export class ParentKind {
    tag: ParentKindTag = ParentKindTag.Object;
    // Bone: the bone name.
    bone: string = "";

    static object(): ParentKind {
        return new ParentKind();
    }

    static boneOf(name: string): ParentKind {
        const k = new ParentKind();
        k.tag = ParentKindTag.Bone;
        k.bone = name;
        return k;
    }

    static armature(): ParentKind {
        const k = new ParentKind();
        k.tag = ParentKindTag.Armature;
        return k;
    }

    clone(): ParentKind {
        const k = new ParentKind();
        k.tag = this.tag;
        k.bone = this.bone;
        return k;
    }

    equals(o: ParentKind): bool {
        if (this.tag != o.tag) return false;
        return this.tag != ParentKindTag.Bone || this.bone == o.bone;
    }

    debug(): string {
        switch (this.tag) {
            case ParentKindTag.Object: return "Object";
            case ParentKindTag.Bone: return "Bone(" + debugStr(this.bone) + ")";
            default: return "Armature";
        }
    }
}

export class Parent {
    id: ObjId = 0;
    kind: ParentKind = new ParentKind();

    constructor(id: ObjId = 0, kind: ParentKind = new ParentKind()) {
        this.id = id;
        this.kind = kind;
    }

    clone(): Parent {
        return new Parent(this.id, this.kind.clone());
    }

    equals(o: Parent): bool {
        return this.id == o.id && this.kind.equals(o.kind);
    }
}

// ------------------------------------------------------------ ModifierKind

// Variant index = postcard tag (append only).
export enum ModifierKindTag {
    Mirror = 0,
    Subsurf = 1,
    Array = 2,
    Solidify = 3,
    Bevel = 4,
    Triangulate = 5,
    Weld = 6,
    EdgeSplit = 7,
    Armature = 8,
    Tool = 9,
    Instance = 10,
    Ext = 11,
}

// One entry of an object's modifier stack (PLAN §4, Object mode >
// Modifiers). Evaluation lives in `shared/src/model/modifiers`.
export abstract class ModifierKind {
    abstract get tag(): ModifierKindTag;
    abstract clone(): ModifierKind;
    abstract equals(o: ModifierKind): bool;
    // Derived Debug (`Mirror { axis: [true, false, false], ... }`).
    abstract debug(): string;

    typeName(): string {
        switch (this.tag) {
            case ModifierKindTag.Mirror: return "mirror";
            case ModifierKindTag.Subsurf: return "subsurf";
            case ModifierKindTag.Array: return "array";
            case ModifierKindTag.Solidify: return "solidify";
            case ModifierKindTag.Bevel: return "bevel";
            case ModifierKindTag.Triangulate: return "triangulate";
            case ModifierKindTag.Weld: return "weld";
            case ModifierKindTag.EdgeSplit: return "edge-split";
            case ModifierKindTag.Armature: return "armature";
            case ModifierKindTag.Instance: return "instance";
            case ModifierKindTag.Tool: return "tool";
            default: return extTypeName((this as ModifierKindExt).kind);
        }
    }

    // Blender's default modifier name for the type.
    defaultName(): string {
        switch (this.tag) {
            case ModifierKindTag.Mirror: return "Mirror";
            case ModifierKindTag.Subsurf: return "Subdivision";
            case ModifierKindTag.Array: return "Array";
            case ModifierKindTag.Solidify: return "Solidify";
            case ModifierKindTag.Bevel: return "Bevel";
            case ModifierKindTag.Triangulate: return "Triangulate";
            case ModifierKindTag.Weld: return "Weld";
            case ModifierKindTag.EdgeSplit: return "EdgeSplit";
            case ModifierKindTag.Armature: return "Armature";
            case ModifierKindTag.Instance: return "Instance";
            // Named after the tool rather than the type: a stack with three
            // of them reads as Greeble/Panel/Rivets, not Tool/Tool.001.
            case ModifierKindTag.Tool: return "Tool";
            // An extension's Blender name is the extension's to know;
            // `suggestedName` asks it, and this is only the fallback for a
            // build with no extension installed.
            default: return "Modifier";
        }
    }

    // The name a new modifier of this kind takes by default. Same as
    // `defaultName` except for a tool, which is named after the tool it runs.
    suggestedName(): string {
        switch (this.tag) {
            case ModifierKindTag.Tool: {
                const tool = (this as ModifierKindTool).tool;
                if (tool.length == 0) return "Tool";
                const cp = tool.codePointAt(0);
                const w = cp > 0xffff ? 2 : 1;
                return String.fromCodePoint(cp).toUpperCase() + tool.substring(w);
            }
            case ModifierKindTag.Ext: {
                const kind = (this as ModifierKindExt).kind;
                const e = extModifiers();
                if (e != null) {
                    const n = e.displayName(kind);
                    if (n != null) return n;
                }
                return "Modifier";
            }
            default:
                return this.defaultName();
        }
    }
}

export class ModifierKindMirror extends ModifierKind {
    axis: Array<bool> = bool3(false, false, false);
    clipping: bool = false;
    merge: bool = false;
    mergeThreshold: f32 = 0;

    get tag(): ModifierKindTag { return ModifierKindTag.Mirror; }

    static create(axis: Array<bool>, clipping: bool, merge: bool, mergeThreshold: f32): ModifierKindMirror {
        const k = new ModifierKindMirror();
        k.axis = copyBools(axis);
        k.clipping = clipping;
        k.merge = merge;
        k.mergeThreshold = mergeThreshold;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindMirror.create(this.axis, this.clipping, this.merge, this.mergeThreshold);
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.Mirror) return false;
        const k = o as ModifierKindMirror;
        return this.axis[0] == k.axis[0] && this.axis[1] == k.axis[1] && this.axis[2] == k.axis[2]
            && this.clipping == k.clipping && this.merge == k.merge && this.mergeThreshold == k.mergeThreshold;
    }

    debug(): string {
        return debugStruct("Mirror", ["axis", "clipping", "merge", "merge_threshold"], [
            debugList([debugBool(this.axis[0]), debugBool(this.axis[1]), debugBool(this.axis[2])]),
            debugBool(this.clipping), debugBool(this.merge), debugF32(this.mergeThreshold),
        ]);
    }
}

export class ModifierKindSubsurf extends ModifierKind {
    levels: u32 = 0;
    renderLevels: u32 = 0;

    get tag(): ModifierKindTag { return ModifierKindTag.Subsurf; }

    static create(levels: u32, renderLevels: u32): ModifierKindSubsurf {
        const k = new ModifierKindSubsurf();
        k.levels = levels;
        k.renderLevels = renderLevels;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindSubsurf.create(this.levels, this.renderLevels);
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.Subsurf) return false;
        const k = o as ModifierKindSubsurf;
        return this.levels == k.levels && this.renderLevels == k.renderLevels;
    }

    debug(): string {
        return debugStruct("Subsurf", ["levels", "render_levels"], [this.levels.toString(), this.renderLevels.toString()]);
    }
}

export class ModifierKindArray extends ModifierKind {
    count: u32 = 0;
    relativeOffset: Vec3 = Vec3(0, 0, 0);
    constantOffset: Vec3 = Vec3(0, 0, 0);
    merge: bool = false;
    mergeThreshold: f32 = 0;

    get tag(): ModifierKindTag { return ModifierKindTag.Array; }

    static create(count: u32, relativeOffset: Vec3, constantOffset: Vec3, merge: bool, mergeThreshold: f32): ModifierKindArray {
        const k = new ModifierKindArray();
        k.count = count;
        k.relativeOffset = relativeOffset;
        k.constantOffset = constantOffset;
        k.merge = merge;
        k.mergeThreshold = mergeThreshold;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindArray.create(this.count, this.relativeOffset, this.constantOffset, this.merge, this.mergeThreshold);
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.Array) return false;
        const k = o as ModifierKindArray;
        return this.count == k.count && this.relativeOffset == k.relativeOffset && this.constantOffset == k.constantOffset
            && this.merge == k.merge && this.mergeThreshold == k.mergeThreshold;
    }

    debug(): string {
        return debugStruct("Array", ["count", "relative_offset", "constant_offset", "merge", "merge_threshold"], [
            this.count.toString(), this.relativeOffset.debug(), this.constantOffset.debug(),
            debugBool(this.merge), debugF32(this.mergeThreshold),
        ]);
    }
}

export class ModifierKindSolidify extends ModifierKind {
    thickness: f32 = 0;
    offset: f32 = 0;
    even: bool = false;

    get tag(): ModifierKindTag { return ModifierKindTag.Solidify; }

    static create(thickness: f32, offset: f32, even: bool): ModifierKindSolidify {
        const k = new ModifierKindSolidify();
        k.thickness = thickness;
        k.offset = offset;
        k.even = even;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindSolidify.create(this.thickness, this.offset, this.even);
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.Solidify) return false;
        const k = o as ModifierKindSolidify;
        return this.thickness == k.thickness && this.offset == k.offset && this.even == k.even;
    }

    debug(): string {
        return debugStruct("Solidify", ["thickness", "offset", "even"], [
            debugF32(this.thickness), debugF32(this.offset), debugBool(this.even),
        ]);
    }
}

export class ModifierKindBevel extends ModifierKind {
    width: f32 = 0;
    segments: u32 = 0;
    // Radians; edges flatter than this are not beveled.
    angleLimit: f32 = 0;

    get tag(): ModifierKindTag { return ModifierKindTag.Bevel; }

    static create(width: f32, segments: u32, angleLimit: f32): ModifierKindBevel {
        const k = new ModifierKindBevel();
        k.width = width;
        k.segments = segments;
        k.angleLimit = angleLimit;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindBevel.create(this.width, this.segments, this.angleLimit);
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.Bevel) return false;
        const k = o as ModifierKindBevel;
        return this.width == k.width && this.segments == k.segments && this.angleLimit == k.angleLimit;
    }

    debug(): string {
        return debugStruct("Bevel", ["width", "segments", "angle_limit"], [
            debugF32(this.width), this.segments.toString(), debugF32(this.angleLimit),
        ]);
    }
}

export class ModifierKindTriangulate extends ModifierKind {
    get tag(): ModifierKindTag { return ModifierKindTag.Triangulate; }

    static create(): ModifierKindTriangulate {
        return new ModifierKindTriangulate();
    }

    clone(): ModifierKind {
        return new ModifierKindTriangulate();
    }

    equals(o: ModifierKind): bool {
        return o.tag == ModifierKindTag.Triangulate;
    }

    debug(): string {
        return "Triangulate";
    }
}

export class ModifierKindWeld extends ModifierKind {
    distance: f32 = 0;

    get tag(): ModifierKindTag { return ModifierKindTag.Weld; }

    static create(distance: f32): ModifierKindWeld {
        const k = new ModifierKindWeld();
        k.distance = distance;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindWeld.create(this.distance);
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.Weld) return false;
        return this.distance == (o as ModifierKindWeld).distance;
    }

    debug(): string {
        return debugStruct("Weld", ["distance"], [debugF32(this.distance)]);
    }
}

export class ModifierKindEdgeSplit extends ModifierKind {
    // Radians.
    angle: f32 = 0;

    get tag(): ModifierKindTag { return ModifierKindTag.EdgeSplit; }

    static create(angle: f32): ModifierKindEdgeSplit {
        const k = new ModifierKindEdgeSplit();
        k.angle = angle;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindEdgeSplit.create(this.angle);
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.EdgeSplit) return false;
        return this.angle == (o as ModifierKindEdgeSplit).angle;
    }

    debug(): string {
        return debugStruct("EdgeSplit", ["angle"], [debugF32(this.angle)]);
    }
}

// Linear blend skinning by an armature object's pose (PLAN §5).
export class ModifierKindArmature extends ModifierKind {
    // NO_OBJ = none.
    object: u32 = NO_OBJ;
    // Dual-quaternion style volume preservation (approximated).
    preserveVolume: bool = false;
    useVertexGroups: bool = false;
    useEnvelopes: bool = false;

    get tag(): ModifierKindTag { return ModifierKindTag.Armature; }

    static create(object: u32, preserveVolume: bool, useVertexGroups: bool, useEnvelopes: bool): ModifierKindArmature {
        const k = new ModifierKindArmature();
        k.object = object;
        k.preserveVolume = preserveVolume;
        k.useVertexGroups = useVertexGroups;
        k.useEnvelopes = useEnvelopes;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindArmature.create(this.object, this.preserveVolume, this.useVertexGroups, this.useEnvelopes);
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.Armature) return false;
        const k = o as ModifierKindArmature;
        return this.object == k.object && this.preserveVolume == k.preserveVolume
            && this.useVertexGroups == k.useVertexGroups && this.useEnvelopes == k.useEnvelopes;
    }

    debug(): string {
        return debugStruct("Armature", ["object", "preserve_volume", "use_vertex_groups", "use_envelopes"], [
            debugOptObj(this.object), debugBool(this.preserveVolume), debugBool(this.useVertexGroups),
            debugBool(this.useEnvelopes),
        ]);
    }
}

// A user tool run as a modifier (PLAN §8/M9 stage 2), re-evaluated on every
// render, export and inspect instead of baked into the mesh.
export class ModifierKindTool extends ModifierKind {
    // The tool's command name, as `tool list` shows it.
    tool: string = "";
    // Parameter values, as the text the caller wrote them with (iterate
    // with sortedKeys).
    params: Map<string, string> = new Map<string, string>();
    // The tool file's content hash when this modifier was added.
    hash: u64 = 0;

    get tag(): ModifierKindTag { return ModifierKindTag.Tool; }

    static create(tool: string, params: Map<string, string>, hash: u64): ModifierKindTool {
        const k = new ModifierKindTool();
        k.tool = tool;
        k.params = params;
        k.hash = hash;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindTool.create(this.tool, cloneStrMap(this.params), this.hash);
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.Tool) return false;
        const k = o as ModifierKindTool;
        return this.tool == k.tool && strMapEquals(this.params, k.params) && this.hash == k.hash;
    }

    debug(): string {
        return debugStruct("Tool", ["tool", "params", "hash"], [
            debugStr(this.tool), debugStrMap(this.params), this.hash.toString(),
        ]);
    }
}

// A copy of another object at every point of this one (PLAN §8/M9 stage 4).
export class ModifierKindInstance extends ModifierKind {
    // NO_OBJ = none.
    object: u32 = NO_OBJ;
    scale: f32 = 0;
    // A named point attribute multiplying that scale, per copy.
    scaleAttr: string? = null;
    // Stand each copy on the point's `surface_normal`.
    align: bool = false;
    // Euler XYZ radians, after the alignment.
    rotation: Vec3 = Vec3(0, 0, 0);
    // A named point attribute turning each copy on its own, Euler XYZ in
    // degrees, applied after `rotation`.
    rotationAttr: string? = null;

    get tag(): ModifierKindTag { return ModifierKindTag.Instance; }

    static create(object: u32, scale: f32, scaleAttr: string?, align: bool, rotation: Vec3, rotationAttr: string?): ModifierKindInstance {
        const k = new ModifierKindInstance();
        k.object = object;
        k.scale = scale;
        k.scaleAttr = scaleAttr;
        k.align = align;
        k.rotation = rotation;
        k.rotationAttr = rotationAttr;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindInstance.create(this.object, this.scale, this.scaleAttr, this.align, this.rotation, this.rotationAttr);
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.Instance) return false;
        const k = o as ModifierKindInstance;
        return this.object == k.object && this.scale == k.scale && optStrEq(this.scaleAttr, k.scaleAttr)
            && this.align == k.align && this.rotation == k.rotation && optStrEq(this.rotationAttr, k.rotationAttr);
    }

    debug(): string {
        return debugStruct("Instance", ["object", "scale", "scale_attr", "align", "rotation", "rotation_attr"], [
            debugOptObj(this.object), debugF32(this.scale), debugOptStr(this.scaleAttr), debugBool(this.align),
            this.rotation.debug(), debugOptStr(this.rotationAttr),
        ]);
    }
}

// A modifier whose behaviour lives outside shared/src/model (in engine/src/commands/blender);
// core stores the type name and its kebab-case properties as text.
export class ModifierKindExt extends ModifierKind {
    // The type name `modifier add` spells, e.g. `boolean`.
    kind: string = "";
    // Every property of that type (iterate with sortedKeys).
    props: Map<string, string> = new Map<string, string>();

    get tag(): ModifierKindTag { return ModifierKindTag.Ext; }

    static create(kind: string, props: Map<string, string>): ModifierKindExt {
        const k = new ModifierKindExt();
        k.kind = kind;
        k.props = props;
        return k;
    }

    clone(): ModifierKind {
        return ModifierKindExt.create(this.kind, cloneStrMap(this.props));
    }

    equals(o: ModifierKind): bool {
        if (o.tag != ModifierKindTag.Ext) return false;
        const k = o as ModifierKindExt;
        return this.kind == k.kind && strMapEquals(this.props, k.props);
    }

    debug(): string {
        return debugStruct("Ext", ["kind", "props"], [debugStr(this.kind), debugStrMap(this.props)]);
    }
}

export class Modifier {
    name: string;
    kind: ModifierKind;
    // Blender's "show in viewport / render" toggles, folded into one.
    enabled: bool;

    constructor(name: string, kind: ModifierKind, enabled: bool) {
        this.name = name;
        this.kind = kind;
        this.enabled = enabled;
    }

    clone(): Modifier {
        return new Modifier(this.name, this.kind.clone(), this.enabled);
    }

    equals(o: Modifier): bool {
        return this.name == o.name && this.kind.equals(o.kind) && this.enabled == o.enabled;
    }

    debug(): string {
        return debugStruct("Modifier", ["name", "kind", "enabled"], [debugStr(this.name), this.kind.debug(), debugBool(this.enabled)]);
    }
}

export class VertexGroup {
    name: string = "";
    // Locked groups are left alone by normalize / smooth / clean.
    lock: bool = false;

    constructor(name: string = "", lock: bool = false) {
        this.name = name;
        this.lock = lock;
    }

    clone(): VertexGroup {
        return new VertexGroup(this.name, this.lock);
    }

    equals(o: VertexGroup): bool {
        return this.name == o.name && this.lock == o.lock;
    }
}

// What evaluatedMesh returns: `owned == false` means
// `mesh` is the object's own mesh (borrowed): read it, or `intoOwned()`
// before changing it.
export class CowMesh {
    mesh: Mesh;
    owned: bool;

    constructor(mesh: Mesh, owned: bool) {
        this.mesh = mesh;
        this.owned = owned;
    }

    static borrowed(m: Mesh): CowMesh {
        return new CowMesh(m, false);
    }

    static ownedOf(m: Mesh): CowMesh {
        return new CowMesh(m, true);
    }

    // A mesh the caller may change (a copy when it is borrowed).
    intoOwned(): Mesh {
        return this.owned ? this.mesh : this.mesh.clone();
    }
}

// ------------------------------------------------------------------ Object

export class Object {
    name: string = "";
    data: ObjectData;
    transform: Transform = TRANSFORM_IDENTITY;
    parent: Parent? = null;
    // Blender's `matrix_parent_inverse`: world = parent_world * parent_inverse * local.
    parentInverse: Mat4 = MAT4_IDENTITY;
    select: bool = false;
    hide: bool = false;
    hideRender: bool = false;
    materialSlots: Array<u32> = [];
    modifiers: Array<Modifier> = [];
    vertexGroups: Array<VertexGroup> = [];
    // Index into `vertexGroups` (Blender's active group); NO_VGROUP = none.
    activeVgroup: u32 = NO_VGROUP;
    // Assigned action (PLAN §3.3 `animation`); null when none.
    animation: AnimData? = null;

    // An object with a default transform.
    constructor(name: string, data: ObjectData) {
        this.name = name;
        this.data = data;
    }

    // The action driving this object, or ACTION_NONE.
    action(): u32 {
        const a = this.animation;
        return a != null ? a.action : ACTION_NONE;
    }

    typeName(): string {
        return this.data.typeName();
    }

    // The object's own armature (changes apply to it), or null.
    armature(): Armature? {
        return this.data.armature();
    }

    vgroupIndex(name: string): u32 {
        for (let i = 0; i < this.vertexGroups.length; i++) {
            if (this.vertexGroups[i].name == name) return <u32>i;
        }
        return NO_VGROUP;
    }

    // The armature object driving this mesh (first enabled Armature
    // modifier with an object), or NO_OBJ.
    armatureModifierTarget(): u32 {
        for (let i = 0; i < this.modifiers.length; i++) {
            const m = this.modifiers[i];
            if (m.kind.tag == ModifierKindTag.Armature && m.enabled) {
                const id = (m.kind as ModifierKindArmature).object;
                if (id != NO_OBJ) return id;
            }
        }
        return NO_OBJ;
    }

    // The object's own mesh (changes apply to it), or null.
    mesh(): Mesh? {
        return this.data.mesh();
    }

    // Deep copy.
    clone(): Object {
        const o = new Object(this.name, this.data.clone());
        o.transform = this.transform;
        const p = this.parent;
        if (p != null) o.parent = p.clone();
        o.parentInverse = this.parentInverse;
        o.select = this.select;
        o.hide = this.hide;
        o.hideRender = this.hideRender;
        o.materialSlots = this.materialSlots.slice(0);
        const ms: Array<Modifier> = [];
        for (let i = 0; i < this.modifiers.length; i++) ms.push(this.modifiers[i].clone());
        o.modifiers = ms;
        const gs: Array<VertexGroup> = [];
        for (let i = 0; i < this.vertexGroups.length; i++) gs.push(this.vertexGroups[i].clone());
        o.vertexGroups = gs;
        o.activeVgroup = this.activeVgroup;
        const a = this.animation;
        if (a != null) o.animation = a.clone();
        return o;
    }

    // === modifier stack: delegates to engine/src/source/model/modifiers/mod.as.

    // True when at least one enabled modifier would run.
    hasActiveModifiers(): bool {
        return objectHasActiveModifiers(this);
    }

    // A stable fingerprint of the modifier stack; 0 when nothing would run.
    modifierFingerprint(): u64 {
        return objectModifierFingerprint(this);
    }

    // The mesh after its modifier stack without scene context, or null for
    // non-mesh objects.
    evaluatedMesh(): CowMesh? {
        return objectEvaluatedMesh(this);
    }
}

// ------------------------------------------------------------ session enums

export enum Mode {
    Object = 0,
    Edit = 1,
    Pose = 2,
    WeightPaint = 3,
}

// Parses a Mode name; -1 when unknown.
export function modeParse(s: string): i32 {
    if (s == "object") return Mode.Object;
    if (s == "edit") return Mode.Edit;
    if (s == "pose") return Mode.Pose;
    if (s == "weight" || s == "weight-paint") return Mode.WeightPaint;
    return -1;
}

export function modeName(m: Mode): string {
    switch (m) {
        case Mode.Object: return "object";
        case Mode.Edit: return "edit";
        case Mode.Pose: return "pose";
        default: return "weight";
    }
}

export enum Pivot {
    Median = 0,
    Individual = 1,
    Cursor = 2,
    Active = 3,
    BoundingBox = 4,
}

// Parses a Pivot name; -1 when unknown.
export function pivotParse(s: string): i32 {
    if (s == "median") return Pivot.Median;
    if (s == "individual") return Pivot.Individual;
    if (s == "cursor") return Pivot.Cursor;
    if (s == "active") return Pivot.Active;
    if (s == "bounding-box" || s == "bbox") return Pivot.BoundingBox;
    return -1;
}

export function pivotName(p: Pivot): string {
    switch (p) {
        case Pivot.Median: return "median";
        case Pivot.Individual: return "individual";
        case Pivot.Cursor: return "cursor";
        case Pivot.Active: return "active";
        default: return "bounding-box";
    }
}

export enum Orientation {
    Global = 0,
    Local = 1,
    Normal = 2,
    View = 3,
}

// Parses an Orientation name; -1 when unknown.
export function orientationParse(s: string): i32 {
    if (s == "global") return Orientation.Global;
    if (s == "local") return Orientation.Local;
    if (s == "normal") return Orientation.Normal;
    if (s == "view") return Orientation.View;
    return -1;
}

export function orientationName(o: Orientation): string {
    switch (o) {
        case Orientation.Global: return "global";
        case Orientation.Local: return "local";
        case Orientation.Normal: return "normal";
        default: return "view";
    }
}

// ---------------------------------------------------------------- materials

// glTF's alpha modes (PLAN §3.3 material model).
export enum AlphaMode {
    Opaque = 0,
    // Fragments below `alpha_cutoff` are discarded.
    Mask = 1,
    Blend = 2,
}

// Parses an AlphaMode name (ASCII case-insensitive); -1 when unknown.
export function alphaModeParse(s: string): i32 {
    const l = toAsciiLowercase(s);
    if (l == "opaque") return AlphaMode.Opaque;
    if (l == "mask" || l == "clip" || l == "alpha-clip") return AlphaMode.Mask;
    if (l == "blend" || l == "alpha-blend") return AlphaMode.Blend;
    return -1;
}

export function alphaModeName(m: AlphaMode): string {
    switch (m) {
        case AlphaMode.Opaque: return "opaque";
        case AlphaMode.Mask: return "mask";
        default: return "blend";
    }
}

// The texture inputs of the glTF metallic-roughness model.
export enum TextureSlot {
    BaseColor = 0,
    Normal = 1,
    MetallicRoughness = 2,
    Emission = 3,
    Occlusion = 4,
}

// Every texture slot, in order.
export const TEXTURE_SLOT_ALL: Array<TextureSlot> = [
    TextureSlot.BaseColor, TextureSlot.Normal, TextureSlot.MetallicRoughness, TextureSlot.Emission, TextureSlot.Occlusion,
];

// Parses a TextureSlot name (ASCII case-insensitive); -1 when unknown.
export function textureSlotParse(s: string): i32 {
    const l = toAsciiLowercase(s);
    if (l == "base-color" || l == "base_color" || l == "basecolor" || l == "albedo" || l == "color" || l == "diffuse") {
        return TextureSlot.BaseColor;
    }
    if (l == "normal" || l == "normal-map") return TextureSlot.Normal;
    if (l == "metallic-roughness" || l == "metallic_roughness" || l == "roughness-metallic" || l == "roughness"
        || l == "metallic" || l == "orm") {
        return TextureSlot.MetallicRoughness;
    }
    if (l == "emission" || l == "emissive") return TextureSlot.Emission;
    if (l == "occlusion" || l == "ao") return TextureSlot.Occlusion;
    return -1;
}

export function textureSlotName(s: TextureSlot): string {
    switch (s) {
        case TextureSlot.BaseColor: return "base-color";
        case TextureSlot.Normal: return "normal";
        case TextureSlot.MetallicRoughness: return "metallic-roughness";
        case TextureSlot.Emission: return "emission";
        default: return "occlusion";
    }
}

// An image used by a material. `path` is relative to the project file (or
// absolute); it is resolved and validated when rendering or exporting.
export class TextureRef {
    path: string = "";
    // UV layer to sample through; null = the mesh's active layer.
    uvLayer: string? = null;

    constructor(path: string = "", uvLayer: string? = null) {
        this.path = path;
        this.uvLayer = uvLayer;
    }

    clone(): TextureRef {
        return new TextureRef(this.path, this.uvLayer);
    }

    equals(o: TextureRef): bool {
        return this.path == o.path && optStrEq(this.uvLayer, o.uvLayer);
    }
}

function optTexEq(a: TextureRef?, b: TextureRef?): bool {
    if (a == null) return b == null;
    if (b == null) return false;
    return a.equals(b);
}

function optTexClone(a: TextureRef?): TextureRef? {
    return a != null ? a.clone() : null;
}

// `(TextureSlot, &TextureRef)` of MaterialTextures::iter.
export class SlotTexture {
    slot: TextureSlot;
    tex: TextureRef;
    constructor(slot: TextureSlot, tex: TextureRef) {
        this.slot = slot;
        this.tex = tex;
    }
}

export class MaterialTextures {
    baseColor: TextureRef? = null;
    normal: TextureRef? = null;
    metallicRoughness: TextureRef? = null;
    emission: TextureRef? = null;
    occlusion: TextureRef? = null;

    get(slot: TextureSlot): TextureRef? {
        switch (slot) {
            case TextureSlot.BaseColor: return this.baseColor;
            case TextureSlot.Normal: return this.normal;
            case TextureSlot.MetallicRoughness: return this.metallicRoughness;
            case TextureSlot.Emission: return this.emission;
            default: return this.occlusion;
        }
    }

    // Sets one texture slot.
    setSlot(slot: TextureSlot, value: TextureRef?): void {
        switch (slot) {
            case TextureSlot.BaseColor: this.baseColor = value; break;
            case TextureSlot.Normal: this.normal = value; break;
            case TextureSlot.MetallicRoughness: this.metallicRoughness = value; break;
            case TextureSlot.Emission: this.emission = value; break;
            default: this.occlusion = value; break;
        }
    }

    // Every assigned texture with its slot, in TEXTURE_SLOT_ALL order.
    iter(): Array<SlotTexture> {
        const out: Array<SlotTexture> = [];
        for (let i = 0; i < TEXTURE_SLOT_ALL.length; i++) {
            const s = TEXTURE_SLOT_ALL[i];
            const t = this.get(s);
            if (t != null) out.push(new SlotTexture(s, t));
        }
        return out;
    }

    isEmpty(): bool {
        return this.iter().length == 0;
    }

    clone(): MaterialTextures {
        const t = new MaterialTextures();
        t.baseColor = optTexClone(this.baseColor);
        t.normal = optTexClone(this.normal);
        t.metallicRoughness = optTexClone(this.metallicRoughness);
        t.emission = optTexClone(this.emission);
        t.occlusion = optTexClone(this.occlusion);
        return t;
    }

    equals(o: MaterialTextures): bool {
        return optTexEq(this.baseColor, o.baseColor) && optTexEq(this.normal, o.normal)
            && optTexEq(this.metallicRoughness, o.metallicRoughness) && optTexEq(this.emission, o.emission)
            && optTexEq(this.occlusion, o.occlusion);
    }
}

// glTF metallic-roughness material (PLAN §3.3). Colors are sRGB 0..1.
export class Material {
    name: string = "Material";
    // [f32; 3]
    baseColor: Array<f32> = [0.8, 0.8, 0.8];
    metallic: f32 = 0.0;
    roughness: f32 = 0.5;
    // [f32; 3]
    emission: Array<f32> = [0.0, 0.0, 0.0];
    emissionStrength: f32 = 1.0;
    alpha: f32 = 1.0;
    alphaMode: AlphaMode = AlphaMode.Opaque;
    alphaCutoff: f32 = 0.5;
    doubleSided: bool = false;
    textures: MaterialTextures = new MaterialTextures();
    // A MaterialX file (.mtlx, docs/formats/MATERIALS.md) the material is:
    // relative to the model file, or absolute; null for none. Where the
    // file reads, it is what is drawn and exported (compose.as), as an
    // .rscn's Material ext_resource is; the fields above are what a program
    // that cannot read it shows instead, so a model whose file went missing
    // still draws. Godot's external material resource on a surface,
    // Blender's material linked from a library.
    file: string? = null;

    // The default material.
    constructor() {}

    // The defaults with that name.
    static new(name: string): Material {
        const m = new Material();
        m.name = name;
        return m;
    }

    // Base color with alpha, as glTF's `baseColorFactor`.
    baseColorRgba(): Array<f32> {
        return [this.baseColor[0], this.baseColor[1], this.baseColor[2], this.alpha];
    }

    clone(): Material {
        const m = new Material();
        m.name = this.name;
        m.baseColor = copyF32s(this.baseColor);
        m.metallic = this.metallic;
        m.roughness = this.roughness;
        m.emission = copyF32s(this.emission);
        m.emissionStrength = this.emissionStrength;
        m.alpha = this.alpha;
        m.alphaMode = this.alphaMode;
        m.alphaCutoff = this.alphaCutoff;
        m.doubleSided = this.doubleSided;
        m.textures = this.textures.clone();
        m.file = this.file;
        return m;
    }

    equals(o: Material): bool {
        return this.name == o.name && f32ArrEq(this.baseColor, o.baseColor) && this.metallic == o.metallic
            && this.roughness == o.roughness && f32ArrEq(this.emission, o.emission)
            && this.emissionStrength == o.emissionStrength && this.alpha == o.alpha && this.alphaMode == o.alphaMode
            && this.alphaCutoff == o.alphaCutoff && this.doubleSided == o.doubleSided && this.textures.equals(o.textures)
            && optStrEq(this.file, o.file);
    }
}

export class RenderDefaults {
    // [u32; 2]
    size: Array<u32> = [1024, 768];
    // [f32; 4]
    background: Array<f32> = [0.2, 0.2, 0.2, 1.0];
    shading: string = "wire-solid";

    // The default render settings.
    constructor() {}

    clone(): RenderDefaults {
        const r = new RenderDefaults();
        r.size = this.size.slice(0);
        r.background = copyF32s(this.background);
        r.shading = this.shading;
        return r;
    }

    equals(o: RenderDefaults): bool {
        return this.size.length == o.size.length && this.size[0] == o.size[0] && this.size[1] == o.size[1]
            && f32ArrEq(this.background, o.background) && this.shading == o.shading;
    }
}

// Where imported geometry came from (PLAN §3.4).
export class ImportRecord {
    // The source file, relative to the project when it lives beside it.
    path: string = "";
    // FNV-1a 64 of the file's bytes, hex (see hashBytes).
    hash: string = "";
    bytes: u64 = 0;
    // Objects the import added, by name, in the order they were created.
    objects: Array<string> = [];

    constructor(path: string = "", hash: string = "", bytes: u64 = 0, objects: Array<string> = []) {
        this.path = path;
        this.hash = hash;
        this.bytes = bytes;
        this.objects = objects;
    }

    // FNV-1a 64 as lowercase hex, the hash `ImportRecord.hash` holds. The
    // prime is `0x1000000001b3` (FNV64_PRIME_MODELER), not the standard one.
    static hashBytes(bytes: Uint8Array): string {
        return hexU64(fnv1a64Bytes(bytes, FNV64_PRIME_MODELER), 16);
    }

    clone(): ImportRecord {
        return new ImportRecord(this.path, this.hash, this.bytes, this.objects.slice(0));
    }

    equals(o: ImportRecord): bool {
        if (this.path != o.path || this.hash != o.hash || this.bytes != o.bytes) return false;
        if (this.objects.length != o.objects.length) return false;
        for (let i = 0; i < this.objects.length; i++) if (this.objects[i] != o.objects[i]) return false;
        return true;
    }
}

// Scene.frameRange: first and last frame.
export struct FrameRangeI32 {
    start: i32 = 1;
    end: i32 = 250;
    constructor(start: i32, end: i32) {
        this.start = start;
        this.end = end;
    }
    operator==(a: FrameRangeI32, b: FrameRangeI32): bool {
        return a.start == b.start && a.end == b.end;
    }
    readonly hash(): u32 {
        return <u32>this.start * 31 ^ <u32>this.end;
    }
}

// ---------------------------------------------------------------- hashing

// In-process cache keys: FNV-1a 64 over the bytes of
// the values written. Not persisted, not user-visible.
class KeyHasher {
    h: u64 = FNV64_OFFSET;

    byte(b: u64): void {
        this.h ^= b & 0xff;
        this.h *= FNV64_PRIME;
    }

    u64(v: u64): void {
        for (let i = 0; i < 8; i++) this.byte(v >> (<u64>i * 8));
    }

    u32(v: u32): void {
        for (let i = 0; i < 4; i++) this.byte(<u64>(v >> (<u32>i * 8)));
    }

    bool(b: bool): void {
        this.byte(b ? 1 : 0);
    }

    // The bytes then 0xff, so adjacent strings cannot run together.
    str(s: string): void {
        const b = Uint8Array.wrap(String.UTF8.encode(s));
        for (let i = 0; i < b.length; i++) this.byte(<u64>b[i]);
        this.byte(0xff);
    }

    // `m.to_cols_array().map(f32::to_bits).hash(h)`.
    mat4(m: Mat4): void {
        const cols = m.toColsArray();
        for (let i = 0; i < cols.length; i++) this.u32(reinterpret<u32>(cols[i]));
    }

    finish(): u64 {
        return this.h;
    }
}

export class PoseCacheEntry {
    key: u64;
    eval: PoseEval;
    constructor(key: u64, ev: PoseEval) {
        this.key = key;
        this.eval = ev;
    }
}

// A cache entry: base revision, stack fingerprint, evaluated mesh.
const NO_STACK_WARNINGS: Array<string> = [];

export class EvalEntry {
    revision: u64;
    fingerprint: u64;
    mesh: Mesh;
    // The mesh came from a deform-only stack on the unmixed base mesh
    // (`stackIsDeformOnly`): it has the base's elements, so the next pose
    // can be evaluated into it (`reevaluateDeform`).
    deformOnly: bool = false;
    // Another scene holds this entry too (`Scene.clone` shares entries): its
    // mesh must not change, so the next evaluation makes a new one.
    shared: bool = false;
    // What the evaluation said (Scene.stackWarnings). A deform-only
    // re-evaluation keeps the first one's: the stack is the same.
    warnings: Array<string> = NO_STACK_WARNINGS;
    constructor(revision: u64, fingerprint: u64, mesh: Mesh) {
        this.revision = revision;
        this.fingerprint = fingerprint;
        this.mesh = mesh;
    }
}

// The target resolver `pose_eval_depth` hands to `evaluate_pose`.
class SceneTargets extends TargetFn {
    scene: Scene;
    arm: u32;
    depth: i32;
    inv: Mat4;

    constructor(scene: Scene, arm: u32, depth: i32, inv: Mat4) {
        super();
        this.scene = scene;
        this.arm = arm;
        this.depth = depth;
        this.inv = inv;
    }

    resolve(t: ConstraintTarget): TargetMatrix? {
        const obj = this.scene.objects.get(t.object);
        if (obj == null) return null;
        const world = this.scene.worldMatrix(t.object);
        const other = obj.armature();
        const sub = t.subtarget;
        if (other != null && sub != null) {
            if (t.object == this.arm || this.depth > 8) return null;
            const bid = other.find(sub);
            if (bid == NO_BONE) return null;
            const e = this.scene.poseEvalDepth(t.object, this.depth + 1);
            if (e == null) return null;
            return new TargetMatrix(this.inv * world * e.pose[<i32>bid]);
        }
        if (other == null && sub != null) return null;
        return new TargetMatrix(this.inv * world);
    }
}

class ScoredName {
    dist: i32;
    name: string;
    constructor(dist: i32, name: string) {
        this.dist = dist;
        this.name = name;
    }
}

// Scores every name (distance, then name, ascending); returns the best one.
function bestScored(names: Array<string>, name: string): ScoredName {
    const scored: Array<ScoredName> = [];
    for (let i = 0; i < names.length; i++) scored.push(new ScoredName(editDistance(names[i], name), names[i]));
    stableSort<ScoredName>(scored, (x: ScoredName, y: ScoredName): i32 => {
        if (x.dist != y.dist) return x.dist < y.dist ? -1 : 1;
        return cmpStr(x.name, y.name);
    });
    return scored[0];
}

// The `.ddd` stem rule of every unique_*_name: `base` minus a trailing
// `.` + exactly three ASCII digits.
function nameStem(base: string): string {
    const i = base.lastIndexOf(".");
    if (i >= 0) {
        const tail = base.substring(i + 1);
        if (tail.length == 3) {
            let digits = true;
            for (let j = 0; j < 3; j++) {
                const c = tail.charCodeAt(j);
                if (c < 0x30 || c > 0x39) { digits = false; break; }
            }
            if (digits) return base.substring(0, i);
        }
    }
    return base;
}

// ------------------------------------------------------------------- Scene

export class Scene {
    objects: SlotVec<Object> = new SlotVec<Object>();
    // NO_OBJ = none.
    active: u32 = NO_OBJ;
    mode: Mode = Mode.Object;
    selectMode: SelectMode = SelectMode(true, false, false);
    cursor: Transform = TRANSFORM_IDENTITY;
    pivot: Pivot = Pivot.Median;
    orientation: Orientation = Orientation.Global;
    frame: i32 = 1;
    frameRange: FrameRangeI32 = FrameRangeI32(1, 250);
    fps: f32 = 24.0;
    // Frames advanced by `frame next` / `render --anim` by default.
    frameStep: i32 = 1;
    materials: Array<Material> = [];
    actions: SlotVec<Action> = new SlotVec<Action>();
    renderDefaults: RenderDefaults = new RenderDefaults();
    // `pose copy` buffer (empty by default).
    poseClipboard: Array<PoseClip> = [];
    // Provenance of imported geometry, oldest first (schema 6; empty by default).
    imports: Array<ImportRecord> = [];
    // Not serialized: evaluated poses per armature object, keyed by
    // `poseKey` (see poseEval).
    poseCache: Map<u32, PoseCacheEntry> = new Map<u32, PoseCacheEntry>();
    // Not serialized: evaluated modifier stacks, keyed by the base mesh's
    // revision and `modifierFingerprint`.
    evalCache: Map<u32, EvalEntry> = new Map<u32, EvalEntry>();
    // Not serialized: compose.as built this scene, its instances put in
    // already (so it is never put together twice).
    composed: bool = false;

    // An empty scene.
    constructor() {}

    // An empty scene.
    static new(): Scene {
        return new Scene();
    }

    // Deep copy. The caches are copied too; their entries are shared.
    clone(): Scene {
        const s = new Scene();
        s.objects = this.objects.map<Object>((o: Object): Object => o.clone());
        s.active = this.active;
        s.mode = this.mode;
        s.selectMode = this.selectMode;
        s.cursor = this.cursor;
        s.pivot = this.pivot;
        s.orientation = this.orientation;
        s.frame = this.frame;
        s.frameRange = this.frameRange;
        s.fps = this.fps;
        s.frameStep = this.frameStep;
        const mats: Array<Material> = [];
        for (let i = 0; i < this.materials.length; i++) mats.push(this.materials[i].clone());
        s.materials = mats;
        s.actions = this.actions.map<Action>((a: Action): Action => a.clone());
        s.renderDefaults = this.renderDefaults.clone();
        const clips: Array<PoseClip> = [];
        for (let i = 0; i < this.poseClipboard.length; i++) clips.push(this.poseClipboard[i].clone());
        s.poseClipboard = clips;
        const imps: Array<ImportRecord> = [];
        for (let i = 0; i < this.imports.length; i++) imps.push(this.imports[i].clone());
        s.imports = imps;
        const pk = this.poseCache.keys();
        for (let i = 0; i < pk.length; i++) s.poseCache.set(pk[i], this.poseCache.get(pk[i]));
        const ek = this.evalCache.keys();
        for (let i = 0; i < ek.length; i++) {
            const e = this.evalCache.get(ek[i]);
            // Both scenes keep it now: neither may evaluate into its mesh.
            e.shared = true;
            s.evalCache.set(ek[i], e);
        }
        return s;
    }

    // Rebuild transient state after deserialization.
    afterLoad(): void {
        for (let id: u32 = 0; id < this.objects.idBound(); id++) {
            const o = this.objects.get(id);
            if (o == null) continue;
            const m = o.mesh();
            if (m != null) m.afterLoad();
            const a = o.armature();
            if (a != null) a.afterLoad();
        }
        this.poseCache.clear();
    }

    // First object (in id order) with this name, or NO_OBJ.
    find(name: string): u32 {
        for (let id: u32 = 0; id < this.objects.idBound(); id++) {
            const o = this.objects.get(id);
            if (o != null && o.name == name) return id;
        }
        return NO_OBJ;
    }

    // Look up by name, with a hint listing near matches on failure.
    require(name: string): Result<u32> {
        const id = this.find(name);
        if (id == NO_OBJ) return Result.failWith<u32>(CoreError.noSuchObject(name, this.nameHint(name)));
        return Result.okv<u32>(id);
    }

    nameHint(name: string): string {
        const objs = this.objects.values();
        const names: Array<string> = [];
        for (let i = 0; i < objs.length; i++) names.push(objs[i].name);
        if (names.length == 0) {
            return "the scene is empty; `add mesh cube` creates an object";
        }
        const best = bestScored(names, name);
        if (best.dist <= 3) {
            return "did you mean '" + best.name + "'? `list objects` shows all names";
        }
        const shown: Array<string> = [];
        for (let i = 0; i < names.length && i < 8; i++) shown.push(names[i]);
        stableSort<string>(shown, cmpStr);
        const more = names.length > 8 ? ", ..." : "";
        return "valid names: " + shown.join(", ") + more;
    }

    // Blender-style unique naming: `Cube`, `Cube.001`, `Cube.002`, ...
    uniqueName(base: string): string {
        if (this.find(base) == NO_OBJ) return base;
        const stem = nameStem(base);
        for (let n = 1; n < 10000; n++) {
            const candidate = stem + "." + zeroPad(n, 3);
            if (this.find(candidate) == NO_OBJ) return candidate;
        }
        return stem + "." + this.objects.idBound().toString();
    }

    addObject(obj: Object): u32 {
        return this.objects.push(obj);
    }

    activeObject(): Object? {
        return this.active != NO_OBJ ? this.objects.get(this.active) : null;
    }

    requireActive(): Result<u32> {
        if (this.active != NO_OBJ && this.objects.contains(this.active)) return Result.okv<u32>(this.active);
        return Result.failWith<u32>(CoreError.noActiveObject("`active <name>` sets the active object"));
    }

    // Selected and visible objects, in id order.
    selectedIds(): Array<u32> {
        const out: Array<u32> = [];
        for (let id: u32 = 0; id < this.objects.idBound(); id++) {
            const o = this.objects.get(id);
            if (o != null && o.select && !o.hide) out.push(id);
        }
        return out;
    }

    requireSelected(): Result<Array<u32>> {
        const ids = this.selectedIds();
        if (ids.length == 0) {
            return Result.failWith<Array<u32>>(CoreError.nothingSelected("`select <name>` or `select all` first"));
        }
        return Result.okv<Array<u32>>(ids);
    }

    names(ids: Array<u32>): Array<string> {
        const out: Array<string> = [];
        for (let i = 0; i < ids.length; i++) {
            const o = this.objects.get(ids[i]);
            if (o != null) out.push(o.name);
        }
        return out;
    }

    children(parent: u32): Array<u32> {
        const out: Array<u32> = [];
        for (let id: u32 = 0; id < this.objects.idBound(); id++) {
            const o = this.objects.get(id);
            if (o == null) continue;
            const p = o.parent;
            if (p != null && p.id == parent) out.push(id);
        }
        return out;
    }

    // World matrix through the parent chain (cycles are prevented on set).
    worldMatrix(id: u32): Mat4 {
        const obj = this.objects.get(id);
        if (obj == null) return MAT4_IDENTITY;
        const local = obj.transform.matrix();
        const p = obj.parent;
        if (p != null && this.objects.contains(p.id)) {
            return this.worldMatrix(p.id) * obj.parentInverse * local;
        }
        return local;
    }

    // Parent-space matrix an object's local transform is measured in.
    parentSpace(id: u32): Mat4 {
        const obj = this.objects.get(id);
        if (obj == null) return MAT4_IDENTITY;
        const p = obj.parent;
        if (p != null && this.objects.contains(p.id)) return this.worldMatrix(p.id) * obj.parentInverse;
        return MAT4_IDENTITY;
    }

    // Set the local transform so that the world matrix becomes `world`.
    setWorldMatrix(id: u32, world: Mat4): void {
        const local = this.parentSpace(id).inverse() * world;
        const o = this.objects.get(id);
        if (o != null) o.transform = Transform.fromMatrix(local);
    }

    isAncestor(ancestor: u32, of: u32): bool {
        let cur = NO_OBJ;
        let has = false;
        const o0 = this.objects.get(of);
        if (o0 != null) {
            const p0 = o0.parent;
            if (p0 != null) { cur = p0.id; has = true; }
        }
        let guard = 0;
        while (has) {
            if (cur == ancestor) return true;
            guard += 1;
            if (guard > 100000) break;
            has = false;
            const o = this.objects.get(cur);
            if (o != null) {
                const p = o.parent;
                if (p != null) { cur = p.id; has = true; }
            }
        }
        return false;
    }

    // Remove an object; children keep their world transform, and what
    // pointed at it points at nothing (see `clearReferencesTo`).
    removeObject(id: u32): Object? {
        const kids = this.children(id);
        for (let i = 0; i < kids.length; i++) {
            const child = kids[i];
            const world = this.worldMatrix(child);
            const c = this.objects.get(child);
            if (c != null) {
                c.parent = null;
                c.parentInverse = MAT4_IDENTITY;
            }
            this.setWorldMatrix(child, world);
        }
        const removed = this.objects.remove(id);
        if (this.active == id) this.active = NO_OBJ;
        if (removed != null) this.clearReferencesTo(id);
        return removed;
    }

    // Blender sets a reference to a deleted object to None: an armature or
    // instance modifier's object, a bone constraint's target (its bone
    // name with it) and an IK constraint's pole. Ids are never reused, so a
    // dangling id would read as nothing anyway; clearing it keeps every
    // scene the kernel makes one a document can name (an .rmdl spells
    // object references as names), and `NO_OBJ` is what "none" already is.
    private clearReferencesTo(id: u32): void {
        for (let oid: u32 = 0; oid < this.objects.idBound(); oid++) {
            const o = this.objects.get(oid);
            if (o == null) continue;
            for (let m = 0; m < o.modifiers.length; m++) {
                const k = o.modifiers[m].kind;
                if (k.tag == ModifierKindTag.Armature) {
                    const a = k as ModifierKindArmature;
                    if (a.object == id) a.object = NO_OBJ;
                } else if (k.tag == ModifierKindTag.Instance) {
                    const x = k as ModifierKindInstance;
                    if (x.object == id) x.object = NO_OBJ;
                }
            }
            const arm = o.armature();
            if (arm == null) continue;
            for (let bid: u32 = 0; bid < arm.bones.idBound(); bid++) {
                const b = arm.bones.get(bid);
                if (b == null) continue;
                const cs = b.pose.constraints;
                for (let ci = 0; ci < cs.length; ci++) {
                    const t = cs[ci].kind.getTarget();
                    if (t != null && t.object == id) {
                        t.object = NO_OBJ;
                        t.subtarget = null;
                    }
                    if (cs[ci].kind.tag == ConstraintKindTag.Ik) {
                        const ik = cs[ci].kind as ConstraintKindIk;
                        const p = ik.pole;
                        if (p != null && p.object == id) ik.pole = null;
                    }
                }
            }
        }
    }

    // Keep an object's children in place after its world matrix changed
    // from `oldWorld` by adjusting each child's parent inverse.
    keepChildrenInPlace(id: u32, oldWorld: Mat4): void {
        const newWorld = this.worldMatrix(id);
        const fix = newWorld.inverse() * oldWorld;
        const kids = this.children(id);
        for (let i = 0; i < kids.length; i++) {
            const c = this.objects.get(kids[i]);
            if (c != null) c.parentInverse = fix * c.parentInverse;
        }
    }

    meshObjectCount(): i32 {
        let n = 0;
        for (let id: u32 = 0; id < this.objects.idBound(); id++) {
            const o = this.objects.get(id);
            if (o != null && o.mesh() != null) n++;
        }
        return n;
    }

    // ---------------------------------------------------------- materials

    // Index of the first material with this name, or -1.
    findMaterial(name: string): i32 {
        for (let i = 0; i < this.materials.length; i++) {
            if (this.materials[i].name == name) return i;
        }
        return -1;
    }

    // Look up a material by name, with a hint listing near matches.
    requireMaterial(name: string): Result<i32> {
        const i = this.findMaterial(name);
        if (i >= 0) return Result.okv<i32>(i);
        const names: Array<string> = [];
        for (let j = 0; j < this.materials.length; j++) names.push(this.materials[j].name);
        let hint: string;
        if (names.length == 0) {
            hint = "no materials yet; `material new <name>` creates one";
        } else {
            const best = bestScored(names, name);
            if (best.dist <= 3) {
                hint = "did you mean '" + best.name + "'? `material list` shows all";
            } else {
                hint = "materials: " + names.join(", ");
            }
        }
        return Result.failWith<i32>(CoreError.noSuchMaterial(name, hint));
    }

    // Blender-style unique material naming (`Material`, `Material.001`).
    uniqueMaterialName(base: string): string {
        if (this.findMaterial(base) < 0) return base;
        const stem = nameStem(base);
        for (let n = 1; n < 10000; n++) {
            const candidate = stem + "." + zeroPad(n, 3);
            if (this.findMaterial(candidate) < 0) return candidate;
        }
        return stem + "." + this.materials.length.toString();
    }

    // The material a face of `obj` uses (its slot resolved), if any.
    faceMaterial(obj: Object, materialIndex: u16): Material? {
        const mi = <i32>materialIndex;
        if (mi >= obj.materialSlots.length) return null;
        const i = obj.materialSlots[mi];
        if (i >= <u32>this.materials.length) return null;
        return this.materials[<i32>i];
    }

    // ------------------------------------------------------------ actions

    // First action (in id order) with this name, or ACTION_NONE.
    findAction(name: string): u32 {
        for (let id: u32 = 0; id < this.actions.idBound(); id++) {
            const a = this.actions.get(id);
            if (a != null && a.name == name) return id;
        }
        return ACTION_NONE;
    }

    // Look up an action by name, with a "did you mean" hint.
    requireAction(name: string): Result<u32> {
        const id = this.findAction(name);
        if (id != ACTION_NONE) return Result.okv<u32>(id);
        const acts = this.actions.values();
        const names: Array<string> = [];
        for (let i = 0; i < acts.length; i++) names.push(acts[i].name);
        let hint: string;
        if (names.length == 0) {
            hint = "no actions yet; `keyframe insert` or `action new <name>` creates one";
        } else {
            const best = bestScored(names, name);
            if (best.dist <= 3) {
                hint = "did you mean '" + best.name + "'? `action list` shows all";
            } else {
                hint = "actions: " + names.join(", ");
            }
        }
        return Result.failWith<u32>(CoreError.noSuchAction(name, hint));
    }

    // Blender-style unique action naming (`Walk`, `Walk.001`).
    uniqueActionName(base: string): string {
        if (this.findAction(base) == ACTION_NONE) return base;
        const stem = nameStem(base);
        for (let n = 1; n < 10000; n++) {
            const candidate = stem + "." + zeroPad(n, 3);
            if (this.findAction(candidate) == ACTION_NONE) return candidate;
        }
        return stem + "." + this.actions.idBound().toString();
    }

    // Whether the mesh of `id` is drawn / evaluated with its shape key mix
    // (object-mode look). The mesh being edited shows its active key.
    appliesShapeKeyMix(id: u32): bool {
        const o = this.objects.get(id);
        if (o == null) return false;
        const mesh = o.mesh();
        if (mesh == null) return false;
        const editing = this.mode == Mode.Edit && this.active == id;
        return !editing && mesh.hasShapeKeyMix();
    }

    // ------------------------------------------------------- armatures

    // Look up a bone of an armature object by name. Panics ("dangling
    // element id") when `arm` is not an object.
    requireBone(arm: u32, name: string): Result<u32> {
        const obj = this.objects.at(arm);
        const a = obj.armature();
        if (a == null) {
            return Result.failWith<u32>(CoreError.invalidArgument("'" + obj.name + "' is not an armature"));
        }
        const bid = a.find(name);
        if (bid == NO_BONE) return Result.failWith<u32>(CoreError.noSuchBone(name, a.nameHint(name)));
        return Result.okv<u32>(bid);
    }

    // Cache key of an armature's pose: its revision plus everything its
    // constraints read from other objects.
    poseKey(arm: u32, a: Armature): u64 {
        const h = new KeyHasher();
        h.u64(a.revision);
        h.mat4(this.worldMatrix(arm));
        for (let bid: u32 = 0; bid < a.bones.idBound(); bid++) {
            const b = a.bones.get(bid);
            if (b == null) continue;
            const cs = b.pose.constraints;
            for (let ci = 0; ci < cs.length; ci++) {
                const objs = cs[ci].kind.referencedObjects();
                for (let oi = 0; oi < objs.length; oi++) {
                    const obj = objs[oi];
                    h.u32(obj);
                    if (obj == arm || !this.objects.contains(obj)) continue;
                    h.mat4(this.worldMatrix(obj));
                    const other = this.objects.at(obj).armature();
                    if (other != null) h.u64(other.revision);
                }
            }
        }
        return h.finish();
    }

    // The evaluated pose of an armature object (rest, pose, deform matrices
    // in armature space), or null for other objects. Memoized per revision /
    // target state: the result is shared with the cache, so do
    // not change it.
    poseEval(arm: u32): PoseEval? {
        return this.poseEvalDepth(arm, 0);
    }

    poseEvalDepth(arm: u32, depth: i32): PoseEval? {
        const o = this.objects.get(arm);
        if (o == null) return null;
        const a = o.armature();
        if (a == null) return null;
        const key = this.poseKey(arm, a);
        if (this.poseCache.has(arm)) {
            const e = this.poseCache.get(arm);
            if (e.key == key) return e.eval;
        }
        const inv = this.worldMatrix(arm).inverse();
        const ev = a.evaluatePose(arm, new SceneTargets(this, arm, depth, inv));
        this.poseCache.set(arm, new PoseCacheEntry(key, ev));
        return ev;
    }

    // ------------------------------------------------------- modifiers

    // The mesh of an object after its modifier stack, evaluated with the
    // scene at hand (armature modifiers need it). Borrows the base mesh
    // when nothing would run; otherwise a copy the caller owns. Null for a
    // missing or non-mesh object. A caller that only reads the mesh takes
    // `evaluatedMeshShared` and saves the copy.
    evaluatedMesh(id: u32): CowMesh? {
        const obj = this.objects.get(id);
        if (obj == null) return null;
        const base = obj.mesh();
        if (base == null) return null;
        const mix = this.appliesShapeKeyMix(id);
        if (!obj.hasActiveModifiers() && !mix) return CowMesh.borrowed(base);
        if (!obj.hasActiveModifiers()) return CowMesh.ownedOf(base.withShapeKeyMix());
        return CowMesh.ownedOf(this.stackMesh(id, obj, base, mix).clone());
    }

    // The mesh `evaluatedMesh` describes, without the copy: the base mesh
    // when nothing would run, else the cache's own evaluated mesh. Read it
    // and let it go: the next evaluation of this object (another frame, a
    // changed pose) may rewrite it in place. Null for a missing or non-mesh
    // object.
    evaluatedMeshShared(id: u32): Mesh? {
        const obj = this.objects.get(id);
        if (obj == null) return null;
        const base = obj.mesh();
        if (base == null) return null;
        const mix = this.appliesShapeKeyMix(id);
        if (!obj.hasActiveModifiers()) return mix ? base.withShapeKeyMix() : base;
        return this.stackMesh(id, obj, base, mix);
    }

    // The cached result of the object's modifier stack (it has one), made or
    // refreshed as needed. A deform-only stack (armature skinning) whose
    // base mesh did not change is evaluated into the entry's own mesh when
    // no other scene shares it, so posing a skinned mesh frame after frame
    // allocates nothing the size of the mesh.
    private stackMesh(id: u32, obj: Object, base: Mesh, mix: bool): Mesh {
        const rev = base.revision;
        const fp = this.modifierFingerprint(id);
        const deformOnly = !mix && stackIsDeformOnly(obj.modifiers);
        if (this.evalCache.has(id)) {
            const e = this.evalCache.get(id);
            if (e.revision == rev) {
                if (e.fingerprint == fp) return e.mesh;
                if (deformOnly && e.deformOnly && !e.shared) {
                    reevaluateDeform(e.mesh, base, obj.modifiers, new ModifierEnv(this, id, 0));
                    e.fingerprint = fp;
                    return e.mesh;
                }
            }
        }
        // Shape keys deform the base mesh before the modifier stack, as in
        // Blender.
        const input = mix ? base.withShapeKeyMix() : base;
        const evaluated = modifiersEvaluate(input, obj.modifiers, new ModifierEnv(this, id, 0));
        const mesh = evaluated.mesh;
        const entry = new EvalEntry(rev, fp, mesh);
        entry.deformOnly = deformOnly;
        entry.warnings = evaluated.warnings;
        this.evalCache.set(id, entry);
        return mesh;
    }

    // The warnings of the object's last stack evaluation (a modifier left
    // out: a tool that is not there, a build with no tool evaluator), so a
    // caller that converts the evaluated mesh can pass them on rather than
    // draw less than the file says without a word. Empty when the stack
    // has not been evaluated, or said nothing; never changed by the caller.
    stackWarnings(id: u32): Array<string> {
        if (!this.evalCache.has(id)) return NO_STACK_WARNINGS;
        return this.evalCache.get(id).warnings;
    }

    // Like Object.modifierFingerprint but also covering what the stack
    // reads from the scene: the driving armature's pose.
    modifierFingerprint(id: u32): u64 {
        const obj = this.objects.get(id);
        if (obj == null) return 0;
        const base = obj.modifierFingerprint();
        const mix = this.appliesShapeKeyMix(id);
        if (base == 0 && !mix) return 0;
        const h = new KeyHasher();
        h.u64(base);
        if (mix) {
            const mesh = obj.mesh();
            if (mesh != null) {
                h.str("shape-keys");
                const keys = mesh.shapeKeys;
                for (let i = 0; i < keys.length; i++) {
                    const k = keys[i];
                    h.u32(reinterpret<u32>(k.clampedValue()));
                    h.bool(k.mute);
                    h.u32(k.relativeTo);
                }
            }
        }
        let anyTool = false;
        for (let i = 0; i < obj.modifiers.length; i++) {
            const m = obj.modifiers[i];
            if (m.enabled && m.kind.tag == ModifierKindTag.Tool) { anyTool = true; break; }
        }
        if (anyTool) {
            // A tool body runs against a scene built from this object, so it
            // can read the names the object carries even though they are
            // nowhere in the stack itself.
            for (let i = 0; i < obj.vertexGroups.length; i++) h.str(obj.vertexGroups[i].name);
            h.u64(<u64>obj.materialSlots.length);
            for (let i = 0; i < obj.materialSlots.length; i++) h.u32(obj.materialSlots[i]);
        }
        for (let i = 0; i < obj.modifiers.length; i++) {
            const m = obj.modifiers[i];
            if (!m.enabled) continue;
            const t = m.kind.tag;
            if (t == ModifierKindTag.Armature) {
                const arm = (m.kind as ModifierKindArmature).object;
                if (arm == NO_OBJ) continue;
                const ao = this.objects.get(arm);
                if (ao == null) continue;
                const a = ao.armature();
                if (a != null) {
                    h.u64(this.poseKey(arm, a));
                    h.mat4(this.worldMatrix(id));
                }
            } else if (t == ModifierKindTag.Mirror) {
                for (let g = 0; g < obj.vertexGroups.length; g++) h.str(obj.vertexGroups[g].name);
            }
        }
        const f = h.finish();
        return f > 1 ? f : 1;
    }

    // === frame evaluation: delegates to anim/eval.as.

    // Write the animated values of every object with an action at `frame`.
    // The scene's own `frame` is left alone.
    applyFrame(frame: f32): FrameReport {
        return evalApplyFrame(this, frame);
    }

    // A copy of the scene with every action applied at `frame` and the
    // current frame set to it.
    evaluateAt(frame: f32): FrameEvaluation {
        return evalEvaluateAt(this, frame);
    }

    // The objects using `action`, in id order.
    actionUsers(action: u32): Array<u32> {
        return evalActionUsers(this, action);
    }
}

// Levenshtein distance, used for "did you mean" hints. Compares the
// Unicode scalar values of the lowercased strings (lowerCaseUnicode: the
// std's toLowerCase maps ς wrongly).

export function editDistance(a: string, b: string): i32 {
    const ac = codePoints(lowerCaseUnicode(a));
    const bc = codePoints(lowerCaseUnicode(b));
    let prev: Array<i32> = [];
    for (let j = 0; j <= bc.length; j++) prev.push(j);
    let cur: Array<i32> = [];
    for (let j = 0; j <= bc.length; j++) cur.push(0);
    for (let i = 1; i <= ac.length; i++) {
        cur[0] = i;
        for (let j = 1; j <= bc.length; j++) {
            const cost = ac[i - 1] != bc[j - 1] ? 1 : 0;
            cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
        }
        const t = prev;
        prev = cur;
        cur = t;
    }
    return prev[bc.length];
}

function codePoints(s: string): Array<i32> {
    const out: Array<i32> = [];
    const n = s.length;
    let i = 0;
    while (i < n) {
        const c = s.codePointAt(i);
        out.push(c);
        i += c > 0xffff ? 2 : 1;
    }
    return out;
}
