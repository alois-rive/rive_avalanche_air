// The typed glTF 2.0 document (with names, extensions, extras,
// KHR_lights_punctual and KHR_materials_emissive_strength), and its JSON
// serialization.
//
//   glTF value                             Representation here
//   root, accessor, mesh, ...              Root, Accessor, Mesh, ... (the glTF field names)
//   enum field                             i32: the enum value, or CHECKED_INVALID (-1)
//   optional enum (target, filters)        i32: CHECKED_NONE (0) when absent, else as above
//   index                                  i32 (a u32 above i32.MAX saturates to i32.MAX; it
//                                          is out of bounds of any array either way)
//   optional index                         i32, -1 when absent
//   texture source (u32::MAX = no source)  u32, TEXTURE_SOURCE_EMPTY
//   byte size                              u64; optional sizes and strides are i64, -1 = absent
//   optional f32                           f32, NaN when absent
//   f32[N] / optional f32[N]               StaticArray<f32> / StaticArray<f32>?
//   optional array                         Array<T>?
//   optional string                        string?
//   untyped JSON (min, max, others)        JsonValue / JsonMap (engine/src/base/json)
//   extras                                 string?: the raw JSON text, written verbatim
//   primitive attributes                   Attributes (sorted by semantic)
//   extension objects { others }           Extensions { others: JsonMap }
//   empty extension objects (asset, ...)   EmptyExtensions (always serialized as {})
//
// Serialization (`rootToString`, `rootToStringPretty`, `rootToVec`) is fixed
// byte for byte: field declaration order, skipped defaults, the shortest f32
// digits for f32 fields, `null` for non-finite floats, raw extras verbatim.
// An invalid enum value anywhere fails with "invalid item".

import { Result, cmpStr, panic } from "../../../base/util";
import { JsonValue, JsonMap, jsonQuote } from "../../../base/json";
import { parseU32 } from "../../../base/parse";

// ---------------------------------------------------------------------------
// Enum and optional-value conventions

// An i32-typed enum field whose value the file got wrong.
export const CHECKED_INVALID: i32 = -1;
// An absent optional enum field (enum discriminants start at 1).
export const CHECKED_NONE: i32 = 0;
// `Texture::source` when absent.
export const TEXTURE_SOURCE_EMPTY: u32 = 0xFFFFFFFF;

// The error for serializing an invalid enum value.
export const INVALID_ITEM = "invalid item";
// The panic when an invalid enum value is used.
export const UNWRAP_INVALID_ITEM = "attempted to unwrap an invalid item";

// An index read as u32, as it is stored (saturated to i32).
export function indexFromU32(v: u32): i32 {
    return v > <u32>i32.MAX_VALUE ? i32.MAX_VALUE : <i32>v;
}

// ---------------------------------------------------------------------------
// accessor

// An accessor's component type (discriminants start at 1).
export enum ComponentType {
    I8 = 1,
    U8 = 2,
    I16 = 3,
    U16 = 4,
    U32 = 5,
    F32 = 6,
}

export const BYTE: u32 = 5120;
export const UNSIGNED_BYTE: u32 = 5121;
export const SHORT: u32 = 5122;
export const UNSIGNED_SHORT: u32 = 5123;
export const UNSIGNED_INT: u32 = 5125;
export const FLOAT: u32 = 5126;

// ComponentType::size
export function componentTypeSize(c: ComponentType): i32 {
    switch (c) {
        case ComponentType.I8:
        case ComponentType.U8: return 1;
        case ComponentType.I16:
        case ComponentType.U16: return 2;
        default: return 4;
    }
}

// ComponentType::as_gl_enum
export function componentTypeGlEnum(c: ComponentType): u32 {
    switch (c) {
        case ComponentType.I8: return BYTE;
        case ComponentType.U8: return UNSIGNED_BYTE;
        case ComponentType.I16: return SHORT;
        case ComponentType.U16: return UNSIGNED_SHORT;
        case ComponentType.U32: return UNSIGNED_INT;
        default: return FLOAT;
    }
}

// An accessor component type from its GLenum, or CHECKED_INVALID.
export function componentTypeFromGl(v: u32): i32 {
    switch (v) {
        case BYTE: return ComponentType.I8;
        case UNSIGNED_BYTE: return ComponentType.U8;
        case SHORT: return ComponentType.I16;
        case UNSIGNED_SHORT: return ComponentType.U16;
        case UNSIGNED_INT: return ComponentType.U32;
        case FLOAT: return ComponentType.F32;
        default: return CHECKED_INVALID;
    }
}

// An index component type from its GLenum, or CHECKED_INVALID.
export function indexComponentTypeFromGl(v: u32): i32 {
    switch (v) {
        case UNSIGNED_BYTE: return ComponentType.U8;
        case UNSIGNED_SHORT: return ComponentType.U16;
        case UNSIGNED_INT: return ComponentType.U32;
        default: return CHECKED_INVALID;
    }
}

// An accessor's element type (SCALAR, VEC2, ...).
export enum AccessorType {
    Scalar = 1,
    Vec2 = 2,
    Vec3 = 3,
    Vec4 = 4,
    Mat2 = 5,
    Mat3 = 6,
    Mat4 = 7,
}

// Type::multiplicity
export function accessorTypeMultiplicity(t: AccessorType): i32 {
    switch (t) {
        case AccessorType.Scalar: return 1;
        case AccessorType.Vec2: return 2;
        case AccessorType.Vec3: return 3;
        case AccessorType.Vec4:
        case AccessorType.Mat2: return 4;
        case AccessorType.Mat3: return 9;
        default: return 16;
    }
}

export function accessorTypeName(t: AccessorType): string {
    switch (t) {
        case AccessorType.Scalar: return "SCALAR";
        case AccessorType.Vec2: return "VEC2";
        case AccessorType.Vec3: return "VEC3";
        case AccessorType.Vec4: return "VEC4";
        case AccessorType.Mat2: return "MAT2";
        case AccessorType.Mat3: return "MAT3";
        default: return "MAT4";
    }
}

export function accessorTypeFromName(s: string): i32 {
    if (s == "SCALAR") return AccessorType.Scalar;
    if (s == "VEC2") return AccessorType.Vec2;
    if (s == "VEC3") return AccessorType.Vec3;
    if (s == "VEC4") return AccessorType.Vec4;
    if (s == "MAT2") return AccessorType.Mat2;
    if (s == "MAT3") return AccessorType.Mat3;
    if (s == "MAT4") return AccessorType.Mat4;
    return CHECKED_INVALID;
}

// ---------------------------------------------------------------------------
// buffer

export const ARRAY_BUFFER: u32 = 34962;
export const ELEMENT_ARRAY_BUFFER: u32 = 34963;
export const MIN_BYTE_STRIDE: i64 = 4;
export const MAX_BYTE_STRIDE: i64 = 252;

// A buffer view's target.
export enum BufferTarget {
    ArrayBuffer = 1,
    ElementArrayBuffer = 2,
}

export function bufferTargetGlEnum(t: BufferTarget): u32 {
    return t == BufferTarget.ArrayBuffer ? ARRAY_BUFFER : ELEMENT_ARRAY_BUFFER;
}

export function bufferTargetFromGl(v: u32): i32 {
    if (v == ARRAY_BUFFER) return BufferTarget.ArrayBuffer;
    if (v == ELEMENT_ARRAY_BUFFER) return BufferTarget.ElementArrayBuffer;
    return CHECKED_INVALID;
}

// ---------------------------------------------------------------------------
// mesh

export const POINTS: u32 = 0;
export const LINES: u32 = 1;
export const LINE_LOOP: u32 = 2;
export const LINE_STRIP: u32 = 3;
export const TRIANGLES: u32 = 4;
export const TRIANGLE_STRIP: u32 = 5;
export const TRIANGLE_FAN: u32 = 6;

// A primitive's topology mode.
export enum Mode {
    Points = 1,
    Lines = 2,
    LineLoop = 3,
    LineStrip = 4,
    Triangles = 5,
    TriangleStrip = 6,
    TriangleFan = 7,
}

export function modeGlEnum(m: Mode): u32 {
    return <u32>(m - 1);
}

export function modeFromGl(v: u32): i32 {
    return v <= TRIANGLE_FAN ? <i32>v + 1 : CHECKED_INVALID;
}

export enum SemanticKind {
    Extras = 0,
    Positions = 1,
    Normals = 2,
    Tangents = 3,
    Colors = 4,
    TexCoords = 5,
    Joints = 6,
    Weights = 7,
    // An unknown attribute name (sorts after every valid semantic).
    Invalid = 8,
}

// A vertex attribute name.
export class Semantic {
    kind: SemanticKind = SemanticKind.Invalid;
    set: u32 = 0; // Colors/TexCoords/Joints/Weights
    name: string = ""; // Extras: the name without its leading '_'

    static of(kind: SemanticKind, set: u32 = 0): Semantic {
        const s = new Semantic();
        s.kind = kind;
        s.set = set;
        return s;
    }
    static positions(): Semantic { return Semantic.of(SemanticKind.Positions); }
    static normals(): Semantic { return Semantic.of(SemanticKind.Normals); }
    static tangents(): Semantic { return Semantic.of(SemanticKind.Tangents); }
    static colors(set: u32): Semantic { return Semantic.of(SemanticKind.Colors, set); }
    static texCoords(set: u32): Semantic { return Semantic.of(SemanticKind.TexCoords, set); }
    static joints(set: u32): Semantic { return Semantic.of(SemanticKind.Joints, set); }
    static weights(set: u32): Semantic { return Semantic.of(SemanticKind.Weights, set); }
    static extras(name: string): Semantic {
        const s = Semantic.of(SemanticKind.Extras);
        s.name = name;
        return s;
    }
    static invalid(): Semantic { return Semantic.of(SemanticKind.Invalid); }

    // Semantic::checked (the name as it appears in a file).
    static checked(s: string): Semantic {
        if (s == "NORMAL") return Semantic.normals();
        if (s == "POSITION") return Semantic.positions();
        if (s == "TANGENT") return Semantic.tangents();
        if (s.startsWith("_")) return Semantic.extras(s.substring(1));
        if (s.startsWith("COLOR_")) return Semantic.numbered(SemanticKind.Colors, s.substring(6));
        if (s.startsWith("TEXCOORD_")) return Semantic.numbered(SemanticKind.TexCoords, s.substring(9));
        if (s.startsWith("JOINTS_")) return Semantic.numbered(SemanticKind.Joints, s.substring(7));
        if (s.startsWith("WEIGHTS_")) return Semantic.numbered(SemanticKind.Weights, s.substring(8));
        return Semantic.invalid();
    }

    private static numbered(kind: SemanticKind, digits: string): Semantic {
        const r = parseU32(digits);
        if (!r.ok) return Semantic.invalid();
        return Semantic.of(kind, r.value);
    }

    isValid(): bool {
        return this.kind != SemanticKind.Invalid;
    }

    // The attribute name as glTF spells it.
    toString(): string {
        switch (this.kind) {
            case SemanticKind.Positions: return "POSITION";
            case SemanticKind.Normals: return "NORMAL";
            case SemanticKind.Tangents: return "TANGENT";
            case SemanticKind.Colors: return "COLOR_" + this.set.toString();
            case SemanticKind.TexCoords: return "TEXCOORD_" + this.set.toString();
            case SemanticKind.Joints: return "JOINTS_" + this.set.toString();
            case SemanticKind.Weights: return "WEIGHTS_" + this.set.toString();
            case SemanticKind.Extras: return "_" + this.name;
            default: return "<invalid semantic name>";
        }
    }

    equals(o: Semantic): bool {
        return compareSemantic(this, o) == 0;
    }

    clone(): Semantic {
        const s = Semantic.of(this.kind, this.set);
        s.name = this.name;
        return s;
    }
}

// The order of semantics: every valid one before Invalid; kinds in
// declaration order (Extras, Positions, Normals, Tangents, Colors, TexCoords,
// Joints, Weights), then the payload (string bytes / set number).
export function compareSemantic(a: Semantic, b: Semantic): i32 {
    if (a.kind != b.kind) return a.kind < b.kind ? -1 : 1;
    switch (a.kind) {
        case SemanticKind.Extras: return cmpStr(a.name, b.name);
        case SemanticKind.Colors:
        case SemanticKind.TexCoords:
        case SemanticKind.Joints:
        case SemanticKind.Weights:
            return a.set < b.set ? -1 : (a.set > b.set ? 1 : 0);
        default: return 0;
    }
}

// A primitive's attributes, semantic -> accessor index; entries kept sorted.
export class Attributes {
    keys: Array<Semantic> = [];
    values: Array<i32> = [];

    get length(): i32 {
        return this.keys.length;
    }

    private find(s: Semantic): i32 {
        // Binary search: the position of `s`, or -(insertion point) - 1.
        let lo = 0;
        let hi = this.keys.length;
        while (lo < hi) {
            const mid = (lo + hi) >>> 1;
            const c = compareSemantic(this.keys[mid], s);
            if (c == 0) return mid;
            if (c < 0) lo = mid + 1;
            else hi = mid;
        }
        return -lo - 1;
    }

    // The accessor index for `s`, or -1.
    get(s: Semantic): i32 {
        const i = this.find(s);
        return i >= 0 ? this.values[i] : -1;
    }

    has(s: Semantic): bool {
        return this.find(s) >= 0;
    }

    // Inserts in order: an equal key keeps its entry and takes the value.
    insert(s: Semantic, accessor: i32): void {
        const i = this.find(s);
        if (i >= 0) {
            this.values[i] = accessor;
            return;
        }
        const at = -i - 1;
        this.keys.push(s);
        this.values.push(accessor);
        for (let j = this.keys.length - 1; j > at; j--) {
            this.keys[j] = this.keys[j - 1];
            this.values[j] = this.values[j - 1];
        }
        this.keys[at] = s;
        this.values[at] = accessor;
    }

    // Removes `s`: the removed accessor index, or -1.
    remove(s: Semantic): i32 {
        const i = this.find(s);
        if (i < 0) return -1;
        const v = this.values[i];
        this.keys.splice(i, 1);
        this.values.splice(i, 1);
        return v;
    }

    clone(): Attributes {
        const a = new Attributes();
        for (let i = 0; i < this.keys.length; i++) {
            a.keys.push(this.keys[i].clone());
            a.values.push(this.values[i]);
        }
        return a;
    }
}

// ---------------------------------------------------------------------------
// material, texture, animation, camera, light enums

// A material's alpha mode.
export enum AlphaMode {
    Opaque = 1,
    Mask = 2,
    Blend = 3,
}

export function alphaModeName(m: AlphaMode): string {
    if (m == AlphaMode.Opaque) return "OPAQUE";
    if (m == AlphaMode.Mask) return "MASK";
    return "BLEND";
}

export function alphaModeFromName(s: string): i32 {
    if (s == "OPAQUE") return AlphaMode.Opaque;
    if (s == "MASK") return AlphaMode.Mask;
    if (s == "BLEND") return AlphaMode.Blend;
    return CHECKED_INVALID;
}

export const NEAREST: u32 = 9728;
export const LINEAR: u32 = 9729;
export const NEAREST_MIPMAP_NEAREST: u32 = 9984;
export const LINEAR_MIPMAP_NEAREST: u32 = 9985;
export const NEAREST_MIPMAP_LINEAR: u32 = 9986;
export const LINEAR_MIPMAP_LINEAR: u32 = 9987;
export const CLAMP_TO_EDGE: u32 = 33071;
export const MIRRORED_REPEAT: u32 = 33648;
export const REPEAT: u32 = 10497;

// A sampler's magnification filter.
export enum MagFilter {
    Nearest = 1,
    Linear = 2,
}

export function magFilterGlEnum(f: MagFilter): u32 {
    return f == MagFilter.Nearest ? NEAREST : LINEAR;
}

export function magFilterFromGl(v: u32): i32 {
    if (v == NEAREST) return MagFilter.Nearest;
    if (v == LINEAR) return MagFilter.Linear;
    return CHECKED_INVALID;
}

// A sampler's minification filter.
export enum MinFilter {
    Nearest = 1,
    Linear = 2,
    NearestMipmapNearest = 3,
    LinearMipmapNearest = 4,
    NearestMipmapLinear = 5,
    LinearMipmapLinear = 6,
}

export function minFilterGlEnum(f: MinFilter): u32 {
    switch (f) {
        case MinFilter.Nearest: return NEAREST;
        case MinFilter.Linear: return LINEAR;
        case MinFilter.NearestMipmapNearest: return NEAREST_MIPMAP_NEAREST;
        case MinFilter.LinearMipmapNearest: return LINEAR_MIPMAP_NEAREST;
        case MinFilter.NearestMipmapLinear: return NEAREST_MIPMAP_LINEAR;
        default: return LINEAR_MIPMAP_LINEAR;
    }
}

export function minFilterFromGl(v: u32): i32 {
    switch (v) {
        case NEAREST: return MinFilter.Nearest;
        case LINEAR: return MinFilter.Linear;
        case NEAREST_MIPMAP_NEAREST: return MinFilter.NearestMipmapNearest;
        case LINEAR_MIPMAP_NEAREST: return MinFilter.LinearMipmapNearest;
        case NEAREST_MIPMAP_LINEAR: return MinFilter.NearestMipmapLinear;
        case LINEAR_MIPMAP_LINEAR: return MinFilter.LinearMipmapLinear;
        default: return CHECKED_INVALID;
    }
}

// A sampler's wrapping mode.
export enum WrappingMode {
    ClampToEdge = 1,
    MirroredRepeat = 2,
    Repeat = 3,
}

export function wrappingModeGlEnum(w: WrappingMode): u32 {
    if (w == WrappingMode.ClampToEdge) return CLAMP_TO_EDGE;
    if (w == WrappingMode.MirroredRepeat) return MIRRORED_REPEAT;
    return REPEAT;
}

export function wrappingModeFromGl(v: u32): i32 {
    if (v == CLAMP_TO_EDGE) return WrappingMode.ClampToEdge;
    if (v == MIRRORED_REPEAT) return WrappingMode.MirroredRepeat;
    if (v == REPEAT) return WrappingMode.Repeat;
    return CHECKED_INVALID;
}

// An animation sampler's interpolation.
export enum Interpolation {
    Linear = 1,
    Step = 2,
    CubicSpline = 3,
}

export function interpolationName(i: Interpolation): string {
    if (i == Interpolation.Linear) return "LINEAR";
    if (i == Interpolation.Step) return "STEP";
    return "CUBICSPLINE";
}

export function interpolationFromName(s: string): i32 {
    if (s == "LINEAR") return Interpolation.Linear;
    if (s == "STEP") return Interpolation.Step;
    if (s == "CUBICSPLINE") return Interpolation.CubicSpline;
    return CHECKED_INVALID;
}

// The node property an animation channel targets.
export enum Property {
    Translation = 1,
    Rotation = 2,
    Scale = 3,
    MorphTargetWeights = 4,
}

export function propertyName(p: Property): string {
    if (p == Property.Translation) return "translation";
    if (p == Property.Rotation) return "rotation";
    if (p == Property.Scale) return "scale";
    return "weights";
}

export function propertyFromName(s: string): i32 {
    if (s == "translation") return Property.Translation;
    if (s == "rotation") return Property.Rotation;
    if (s == "scale") return Property.Scale;
    if (s == "weights") return Property.MorphTargetWeights;
    return CHECKED_INVALID;
}

// A camera's projection type.
export enum CameraType {
    Perspective = 1,
    Orthographic = 2,
}

export function cameraTypeName(t: CameraType): string {
    return t == CameraType.Perspective ? "perspective" : "orthographic";
}

export function cameraTypeFromName(s: string): i32 {
    if (s == "perspective") return CameraType.Perspective;
    if (s == "orthographic") return CameraType.Orthographic;
    return CHECKED_INVALID;
}

// A KHR_lights_punctual light type.
export enum KhrLightType {
    Directional = 1,
    Point = 2,
    Spot = 3,
}

export function khrLightTypeName(t: KhrLightType): string {
    if (t == KhrLightType.Directional) return "directional";
    if (t == KhrLightType.Point) return "point";
    return "spot";
}

export function khrLightTypeFromName(s: string): i32 {
    if (s == "directional") return KhrLightType.Directional;
    if (s == "point") return KhrLightType.Point;
    if (s == "spot") return KhrLightType.Spot;
    return CHECKED_INVALID;
}

// The extensions the reader supports.
export const ENABLED_EXTENSIONS: Array<string> = [
    "KHR_lights_punctual",
    "KHR_materials_emissive_strength",
];

export const KHR_LIGHTS_PUNCTUAL = "KHR_lights_punctual";
export const KHR_MATERIALS_EMISSIVE_STRENGTH = "KHR_materials_emissive_strength";

// ---------------------------------------------------------------------------
// Extension containers

// An extensions object held as a map of `others`.
export class Extensions {
    others: JsonMap = new JsonMap();

    // `others.get(name)`.
    get(name: string): JsonValue? {
        return this.others.get(name);
    }
}

// An extensions struct with no fields (`struct Asset {}`): drops whatever the
// file had and serializes as `{}`.
export class EmptyExtensions {}

// extensions::root::KhrLightsPunctual.
export class KhrLightsPunctual {
    lights: Array<KhrLight> = [];
}

// extensions::root::Root.
export class RootExtensions extends Extensions {
    khrLightsPunctual: KhrLightsPunctual? = null;
}

// extensions::scene::khr_lights_punctual::KhrLightsPunctual (on a node).
export class NodeLightRef {
    light: i32 = 0;
}

// extensions::scene::Node.
export class NodeExtensions extends Extensions {
    khrLightsPunctual: NodeLightRef? = null;
}

// extensions::material::EmissiveStrength.
export class EmissiveStrength {
    emissiveStrength: f32 = 1.0;
}

// extensions::material::Material.
export class MaterialExtensions extends Extensions {
    emissiveStrength: EmissiveStrength? = null;
}

// ---------------------------------------------------------------------------
// Document types

// A sparse accessor's indices.
export class SparseIndices {
    bufferView: i32 = 0;
    byteOffset: u64 = 0;
    // U8/U16/U32 or CHECKED_INVALID.
    componentType: i32 = CHECKED_INVALID;
    extensions: EmptyExtensions? = null;
    extras: string? = null;
}

// A sparse accessor's values.
export class SparseValues {
    bufferView: i32 = 0;
    byteOffset: u64 = 0;
    extensions: EmptyExtensions? = null;
    extras: string? = null;
}

// A sparse accessor's storage.
export class Sparse {
    count: u64 = 0;
    indices: SparseIndices = new SparseIndices();
    values: SparseValues = new SparseValues();
    extensions: EmptyExtensions? = null;
    extras: string? = null;
}

// An accessor.
export class Accessor {
    bufferView: i32 = -1;
    byteOffset: i64 = -1; // -1 when absent
    count: u64 = 0;
    // A ComponentType or CHECKED_INVALID.
    componentType: i32 = CHECKED_INVALID;
    extensions: Extensions? = null;
    extras: string? = null;
    // An AccessorType or CHECKED_INVALID.
    type_: i32 = CHECKED_INVALID;
    min: JsonValue? = null;
    max: JsonValue? = null;
    name: string? = null;
    normalized: bool = false;
    sparse: Sparse? = null;

    clone(): Accessor {
        const a = new Accessor();
        a.bufferView = this.bufferView;
        a.byteOffset = this.byteOffset;
        a.count = this.count;
        a.componentType = this.componentType;
        a.extensions = cloneExtensions(this.extensions);
        a.extras = this.extras;
        a.type_ = this.type_;
        const mn = this.min;
        a.min = mn != null ? jsonDeepClone(mn) : null;
        const mx = this.max;
        a.max = mx != null ? jsonDeepClone(mx) : null;
        a.name = this.name;
        a.normalized = this.normalized;
        const s = this.sparse;
        if (s != null) {
            const c = new Sparse();
            c.count = s.count;
            c.indices.bufferView = s.indices.bufferView;
            c.indices.byteOffset = s.indices.byteOffset;
            c.indices.componentType = s.indices.componentType;
            c.indices.extensions = s.indices.extensions;
            c.indices.extras = s.indices.extras;
            c.values.bufferView = s.values.bufferView;
            c.values.byteOffset = s.values.byteOffset;
            c.values.extensions = s.values.extensions;
            c.values.extras = s.values.extras;
            c.extensions = s.extensions;
            c.extras = s.extras;
            a.sparse = c;
        }
        return a;
    }
}

// An animation channel's target.
export class ChannelTarget {
    extensions: EmptyExtensions? = null;
    extras: string? = null;
    node: i32 = 0;
    // A Property or CHECKED_INVALID.
    path: i32 = CHECKED_INVALID;
}

// An animation channel.
export class Channel {
    sampler: i32 = 0;
    target: ChannelTarget = new ChannelTarget();
    extensions: EmptyExtensions? = null;
    extras: string? = null;
}

// An animation sampler.
export class AnimationSampler {
    extensions: EmptyExtensions? = null;
    extras: string? = null;
    input: i32 = 0;
    // An Interpolation or CHECKED_INVALID, default LINEAR.
    interpolation: i32 = Interpolation.Linear;
    output: i32 = 0;
}

// An animation.
export class Animation {
    extensions: Extensions? = null;
    extras: string? = null;
    channels: Array<Channel> = [];
    name: string? = null;
    samplers: Array<AnimationSampler> = [];
}

// The asset description (default: version "2.0").
export class Asset {
    copyright: string? = null;
    extensions: EmptyExtensions? = null;
    extras: string? = null;
    generator: string? = null;
    minVersion: string? = null;
    version: string = "2.0";
}

// A buffer.
export class Buffer {
    byteLength: u64 = 0;
    name: string? = null;
    uri: string? = null;
    extensions: Extensions? = null;
    extras: string? = null;
}

// A buffer view.
export class BufferView {
    buffer: i32 = 0;
    byteLength: u64 = 0;
    byteOffset: i64 = -1; // -1 when absent
    byteStride: i64 = -1; // -1 when absent
    name: string? = null;
    // CHECKED_NONE, a BufferTarget or CHECKED_INVALID.
    target: i32 = CHECKED_NONE;
    extensions: Extensions? = null;
    extras: string? = null;

    clone(): BufferView {
        const v = new BufferView();
        v.buffer = this.buffer;
        v.byteLength = this.byteLength;
        v.byteOffset = this.byteOffset;
        v.byteStride = this.byteStride;
        v.name = this.name;
        v.target = this.target;
        v.extensions = cloneExtensions(this.extensions);
        v.extras = this.extras;
        return v;
    }
}

// A perspective projection.
export class CameraPerspective {
    aspectRatio: f32 = NaN; // NaN when absent
    yfov: f32 = 0;
    zfar: f32 = NaN; // NaN when absent
    znear: f32 = 0;
    extensions: Extensions? = null;
    extras: string? = null;
}

// An orthographic projection.
export class CameraOrthographic {
    xmag: f32 = 0;
    ymag: f32 = 0;
    zfar: f32 = 0;
    znear: f32 = 0;
    extensions: Extensions? = null;
    extras: string? = null;
}

// A camera.
export class Camera {
    name: string? = null;
    orthographic: CameraOrthographic? = null;
    perspective: CameraPerspective? = null;
    // A CameraType or CHECKED_INVALID.
    type_: i32 = CHECKED_INVALID;
    extensions: Extensions? = null;
    extras: string? = null;
}

// An image.
export class Image {
    bufferView: i32 = -1;
    mimeType: string? = null;
    name: string? = null;
    uri: string? = null;
    extensions: Extensions? = null;
    extras: string? = null;
}

// A texture reference.
export class TextureInfo {
    index: i32 = 0;
    texCoord: u32 = 0;
    extensions: Extensions? = null;
    extras: string? = null;
}

// A material's normal texture.
export class NormalTexture {
    index: i32 = 0;
    scale: f32 = 1.0;
    texCoord: u32 = 0;
    extensions: Extensions? = null;
    extras: string? = null;
}

// A material's occlusion texture.
export class OcclusionTexture {
    index: i32 = 0;
    strength: f32 = 1.0;
    texCoord: u32 = 0;
    extensions: Extensions? = null;
    extras: string? = null;
}

// A material's metallic-roughness parameters (default: factors 1).
export class PbrMetallicRoughness {
    baseColorFactor: StaticArray<f32> = [1, 1, 1, 1];
    baseColorTexture: TextureInfo? = null;
    metallicFactor: f32 = 1.0;
    roughnessFactor: f32 = 1.0;
    metallicRoughnessTexture: TextureInfo? = null;
    extensions: Extensions? = null;
    extras: string? = null;
}

// A material (default: opaque, single-sided, black emission).
export class Material {
    alphaCutoff: f32 = NaN; // NaN when absent
    // An AlphaMode or CHECKED_INVALID, default OPAQUE.
    alphaMode: i32 = AlphaMode.Opaque;
    doubleSided: bool = false;
    name: string? = null;
    pbrMetallicRoughness: PbrMetallicRoughness = new PbrMetallicRoughness();
    normalTexture: NormalTexture? = null;
    occlusionTexture: OcclusionTexture? = null;
    emissiveTexture: TextureInfo? = null;
    emissiveFactor: StaticArray<f32> = [0, 0, 0];
    extensions: MaterialExtensions? = null;
    extras: string? = null;
}

// A morph target.
export class MorphTarget {
    positions: i32 = -1;
    normals: i32 = -1;
    tangents: i32 = -1;

    clone(): MorphTarget {
        const t = new MorphTarget();
        t.positions = this.positions;
        t.normals = this.normals;
        t.tangents = this.tangents;
        return t;
    }
}

export function cloneMorphTargets(ts: Array<MorphTarget>?): Array<MorphTarget>? {
    if (ts == null) return null;
    const out: Array<MorphTarget> = [];
    for (let i = 0; i < ts.length; i++) out.push(ts[i].clone());
    return out;
}

// A mesh primitive.
export class Primitive {
    attributes: Attributes = new Attributes();
    extensions: Extensions? = null;
    extras: string? = null;
    indices: i32 = -1;
    material: i32 = -1;
    // A Mode or CHECKED_INVALID, default TRIANGLES.
    mode: i32 = Mode.Triangles;
    targets: Array<MorphTarget>? = null;
}

// A mesh.
export class Mesh {
    extensions: Extensions? = null;
    extras: string? = null;
    name: string? = null;
    primitives: Array<Primitive> = [];
    weights: Array<f32>? = null;
}

// A node.
export class Node {
    camera: i32 = -1;
    children: Array<i32>? = null;
    extensions: NodeExtensions? = null;
    extras: string? = null;
    matrix: StaticArray<f32>? = null; // [f32; 16], column major
    mesh: i32 = -1;
    name: string? = null;
    rotation: StaticArray<f32>? = null; // UnitQuaternion [x, y, z, w]
    scale: StaticArray<f32>? = null;
    translation: StaticArray<f32>? = null;
    skin: i32 = -1;
    weights: Array<f32>? = null;
}

// A texture sampler.
export class Sampler {
    // CHECKED_NONE, a filter or CHECKED_INVALID.
    magFilter: i32 = CHECKED_NONE;
    minFilter: i32 = CHECKED_NONE;
    name: string? = null;
    // A WrappingMode or CHECKED_INVALID, default REPEAT.
    wrapS: i32 = WrappingMode.Repeat;
    wrapT: i32 = WrappingMode.Repeat;
    extensions: Extensions? = null;
    extras: string? = null;
}

// A scene.
export class Scene {
    extensions: Extensions? = null;
    extras: string? = null;
    name: string? = null;
    nodes: Array<i32> = [];
}

// A skin.
export class Skin {
    extensions: Extensions? = null;
    extras: string? = null;
    inverseBindMatrices: i32 = -1;
    joints: Array<i32> = [];
    name: string? = null;
    skeleton: i32 = -1;
}

// A texture.
export class Texture {
    name: string? = null;
    sampler: i32 = -1;
    source: u32 = TEXTURE_SOURCE_EMPTY;
    extensions: Extensions? = null;
    extras: string? = null;
}

// khr_lights_punctual::Spot (defaults: inner 0, outer pi/4).
export class KhrLightSpot {
    innerConeAngle: f32 = 0;
    outerConeAngle: f32 = <f32>(Math.PI / 4);
}

// khr_lights_punctual::Light (defaults: color [1,1,1], intensity 1).
export class KhrLight {
    color: StaticArray<f32> = [1, 1, 1];
    // The raw JSON text, or null.
    extensions: string? = null;
    extras: string? = null;
    intensity: f32 = 1;
    name: string? = null;
    range: f32 = NaN; // NaN when absent
    spot: KhrLightSpot? = null;
    // A KhrLightType or CHECKED_INVALID.
    type_: i32 = CHECKED_INVALID;
}

// The document root.
export class Root {
    accessors: Array<Accessor> = [];
    animations: Array<Animation> = [];
    asset: Asset = new Asset();
    buffers: Array<Buffer> = [];
    bufferViews: Array<BufferView> = [];
    scene: i32 = -1;
    extensions: RootExtensions? = null;
    extras: string? = null;
    extensionsUsed: Array<string> = [];
    extensionsRequired: Array<string> = [];
    cameras: Array<Camera> = [];
    images: Array<Image> = [];
    materials: Array<Material> = [];
    meshes: Array<Mesh> = [];
    nodes: Array<Node> = [];
    samplers: Array<Sampler> = [];
    scenes: Array<Scene> = [];
    skins: Array<Skin> = [];
    textures: Array<Texture> = [];

    // `AsRef<[Light]> for Root`: the KHR_lights_punctual lights (empty when
    // the extension is absent).
    lights(): Array<KhrLight> {
        const e = this.extensions;
        if (e == null) return [];
        const k = e.khrLightsPunctual;
        if (k == null) return [];
        return k.lights;
    }

    // The lights list, creating the extension objects on demand.
    lightsMut(): Array<KhrLight> {
        let e = this.extensions;
        if (e == null) {
            e = new RootExtensions();
            this.extensions = e;
        }
        let k = e.khrLightsPunctual;
        if (k == null) {
            k = new KhrLightsPunctual();
            e.khrLightsPunctual = k;
        }
        return k.lights;
    }
}

// ---------------------------------------------------------------------------
// Copies

// A deep copy of a JSON value.
export function jsonDeepClone(v: JsonValue): JsonValue {
    const c = new JsonValue();
    c.kind = v.kind;
    c.boolValue = v.boolValue;
    c.numKind = v.numKind;
    c.u = v.u;
    c.i = v.i;
    c.f = v.f;
    c.str = v.str;
    const items = v.items;
    if (items != null) {
        const out: Array<JsonValue> = [];
        for (let i = 0; i < items.length; i++) out.push(jsonDeepClone(items[i]));
        c.items = out;
    }
    const m = v.map;
    if (m != null) {
        const out = new JsonMap();
        for (let i = 0; i < m.length; i++) out.insert(m.keyAt(i), jsonDeepClone(m.valueAt(i)));
        c.map = out;
    }
    return c;
}

export function jsonMapDeepClone(m: JsonMap): JsonMap {
    const out = new JsonMap();
    for (let i = 0; i < m.length; i++) out.insert(m.keyAt(i), jsonDeepClone(m.valueAt(i)));
    return out;
}

export function cloneExtensions(e: Extensions?): Extensions? {
    if (e == null) return null;
    const c = new Extensions();
    c.others = jsonMapDeepClone(e.others);
    return c;
}

// ---------------------------------------------------------------------------
// Serialization (compact, pretty and byte output of a Root)

// Raw JSON fragments (extras) go through the Value writer as placeholder
// strings and are spliced in afterwards, verbatim
// (in compact and pretty output alike). A document string equal to a
// placeholder (NUL-delimited) would be mistaken for one.
const RAW_MARK = "\u0000gltf-doc-raw:";

class Ser {
    raws: Array<string> = [];
    failed: bool = false;

    raw(text: string): JsonValue {
        const v = JsonValue.str(RAW_MARK + this.raws.length.toString() + "\u0000");
        this.raws.push(text);
        return v;
    }

    checked(v: i32): bool {
        if (v == CHECKED_INVALID) {
            this.failed = true;
            return false;
        }
        return true;
    }
}

function f32v(x: f32): JsonValue {
    return JsonValue.serializeF32(x);
}

function f32Array(xs: StaticArray<f32>): JsonValue {
    const items: Array<JsonValue> = [];
    for (let i = 0; i < xs.length; i++) items.push(JsonValue.serializeF32(xs[i]));
    return JsonValue.array(items);
}

function f32Vec(xs: Array<f32>): JsonValue {
    const items: Array<JsonValue> = [];
    for (let i = 0; i < xs.length; i++) items.push(JsonValue.serializeF32(xs[i]));
    return JsonValue.array(items);
}

// Index<T> serializes as u64.
function idx(i: i32): JsonValue {
    return JsonValue.fromU64(<u64><u32>i);
}

function idxVec(xs: Array<i32>): JsonValue {
    const items: Array<JsonValue> = [];
    for (let i = 0; i < xs.length; i++) items.push(idx(xs[i]));
    return JsonValue.array(items);
}

function strOpt(m: JsonMap, key: string, s: string?): void {
    if (s != null) m.insert(key, JsonValue.str(s));
}

function extrasOpt(ser: Ser, m: JsonMap, extras: string?): void {
    if (extras != null) m.insert("extras", ser.raw(extras));
}

function othersInto(m: JsonMap, others: JsonMap): void {
    for (let i = 0; i < others.length; i++) m.insert(others.keyAt(i), others.valueAt(i));
}

function extOpt(m: JsonMap, e: Extensions?): void {
    if (e == null) return;
    const o = new JsonMap();
    othersInto(o, e.others);
    m.insert("extensions", JsonValue.object(o));
}

function emptyExtOpt(m: JsonMap, e: EmptyExtensions?): void {
    if (e != null) m.insert("extensions", JsonValue.object(new JsonMap()));
}

function serTextureInfo(ser: Ser, t: TextureInfo): JsonValue {
    const m = new JsonMap();
    m.insert("index", idx(t.index));
    m.insert("texCoord", JsonValue.fromU64(<u64>t.texCoord));
    extOpt(m, t.extensions);
    extrasOpt(ser, m, t.extras);
    return JsonValue.object(m);
}

function serAccessor(ser: Ser, a: Accessor): JsonValue {
    const m = new JsonMap();
    if (a.bufferView >= 0) m.insert("bufferView", idx(a.bufferView));
    if (a.byteOffset >= 0) m.insert("byteOffset", JsonValue.fromU64(<u64>a.byteOffset));
    m.insert("count", JsonValue.fromU64(a.count));
    if (ser.checked(a.componentType)) {
        m.insert("componentType", JsonValue.fromU64(<u64>componentTypeGlEnum(<ComponentType>a.componentType)));
    }
    extOpt(m, a.extensions);
    extrasOpt(ser, m, a.extras);
    if (ser.checked(a.type_)) m.insert("type", JsonValue.str(accessorTypeName(<AccessorType>a.type_)));
    const mn = a.min;
    if (mn != null) m.insert("min", mn);
    const mx = a.max;
    if (mx != null) m.insert("max", mx);
    strOpt(m, "name", a.name);
    if (a.normalized) m.insert("normalized", JsonValue.bool(true));
    const s = a.sparse;
    if (s != null) {
        const sm = new JsonMap();
        sm.insert("count", JsonValue.fromU64(s.count));
        const im = new JsonMap();
        im.insert("bufferView", idx(s.indices.bufferView));
        im.insert("byteOffset", JsonValue.fromU64(s.indices.byteOffset));
        if (ser.checked(s.indices.componentType)) {
            im.insert("componentType",
                JsonValue.fromU64(<u64>componentTypeGlEnum(<ComponentType>s.indices.componentType)));
        }
        emptyExtOpt(im, s.indices.extensions);
        extrasOpt(ser, im, s.indices.extras);
        sm.insert("indices", JsonValue.object(im));
        const vm = new JsonMap();
        vm.insert("bufferView", idx(s.values.bufferView));
        vm.insert("byteOffset", JsonValue.fromU64(s.values.byteOffset));
        emptyExtOpt(vm, s.values.extensions);
        extrasOpt(ser, vm, s.values.extras);
        sm.insert("values", JsonValue.object(vm));
        emptyExtOpt(sm, s.extensions);
        extrasOpt(ser, sm, s.extras);
        m.insert("sparse", JsonValue.object(sm));
    }
    return JsonValue.object(m);
}

function serAnimation(ser: Ser, a: Animation): JsonValue {
    const m = new JsonMap();
    extOpt(m, a.extensions);
    extrasOpt(ser, m, a.extras);
    if (a.channels.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < a.channels.length; i++) {
            const c = a.channels[i];
            const cm = new JsonMap();
            cm.insert("sampler", idx(c.sampler));
            const tm = new JsonMap();
            emptyExtOpt(tm, c.target.extensions);
            extrasOpt(ser, tm, c.target.extras);
            tm.insert("node", idx(c.target.node));
            if (ser.checked(c.target.path)) tm.insert("path", JsonValue.str(propertyName(<Property>c.target.path)));
            cm.insert("target", JsonValue.object(tm));
            emptyExtOpt(cm, c.extensions);
            extrasOpt(ser, cm, c.extras);
            items.push(JsonValue.object(cm));
        }
        m.insert("channels", JsonValue.array(items));
    }
    strOpt(m, "name", a.name);
    if (a.samplers.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < a.samplers.length; i++) {
            const s = a.samplers[i];
            const sm = new JsonMap();
            emptyExtOpt(sm, s.extensions);
            extrasOpt(ser, sm, s.extras);
            sm.insert("input", idx(s.input));
            if (ser.checked(s.interpolation)) {
                sm.insert("interpolation", JsonValue.str(interpolationName(<Interpolation>s.interpolation)));
            }
            sm.insert("output", idx(s.output));
            items.push(JsonValue.object(sm));
        }
        m.insert("samplers", JsonValue.array(items));
    }
    return JsonValue.object(m);
}

function serAsset(ser: Ser, a: Asset): JsonValue {
    const m = new JsonMap();
    strOpt(m, "copyright", a.copyright);
    emptyExtOpt(m, a.extensions);
    extrasOpt(ser, m, a.extras);
    strOpt(m, "generator", a.generator);
    strOpt(m, "minVersion", a.minVersion);
    m.insert("version", JsonValue.str(a.version));
    return JsonValue.object(m);
}

function serBuffer(ser: Ser, b: Buffer): JsonValue {
    const m = new JsonMap();
    m.insert("byteLength", JsonValue.fromU64(b.byteLength));
    strOpt(m, "name", b.name);
    strOpt(m, "uri", b.uri);
    extOpt(m, b.extensions);
    extrasOpt(ser, m, b.extras);
    return JsonValue.object(m);
}

function serView(ser: Ser, v: BufferView): JsonValue {
    const m = new JsonMap();
    m.insert("buffer", idx(v.buffer));
    m.insert("byteLength", JsonValue.fromU64(v.byteLength));
    if (v.byteOffset >= 0) m.insert("byteOffset", JsonValue.fromU64(<u64>v.byteOffset));
    if (v.byteStride >= 0) m.insert("byteStride", JsonValue.fromU64(<u64>v.byteStride));
    strOpt(m, "name", v.name);
    if (v.target != CHECKED_NONE && ser.checked(v.target)) {
        m.insert("target", JsonValue.fromU64(<u64>bufferTargetGlEnum(<BufferTarget>v.target)));
    }
    extOpt(m, v.extensions);
    extrasOpt(ser, m, v.extras);
    return JsonValue.object(m);
}

function serCamera(ser: Ser, c: Camera): JsonValue {
    const m = new JsonMap();
    strOpt(m, "name", c.name);
    const o = c.orthographic;
    if (o != null) {
        const om = new JsonMap();
        om.insert("xmag", f32v(o.xmag));
        om.insert("ymag", f32v(o.ymag));
        om.insert("zfar", f32v(o.zfar));
        om.insert("znear", f32v(o.znear));
        extOpt(om, o.extensions);
        extrasOpt(ser, om, o.extras);
        m.insert("orthographic", JsonValue.object(om));
    }
    const p = c.perspective;
    if (p != null) {
        const pm = new JsonMap();
        if (!isNaN(p.aspectRatio)) pm.insert("aspectRatio", f32v(p.aspectRatio));
        pm.insert("yfov", f32v(p.yfov));
        if (!isNaN(p.zfar)) pm.insert("zfar", f32v(p.zfar));
        pm.insert("znear", f32v(p.znear));
        extOpt(pm, p.extensions);
        extrasOpt(ser, pm, p.extras);
        m.insert("perspective", JsonValue.object(pm));
    }
    if (ser.checked(c.type_)) m.insert("type", JsonValue.str(cameraTypeName(<CameraType>c.type_)));
    extOpt(m, c.extensions);
    extrasOpt(ser, m, c.extras);
    return JsonValue.object(m);
}

function serImage(ser: Ser, im: Image): JsonValue {
    const m = new JsonMap();
    if (im.bufferView >= 0) m.insert("bufferView", idx(im.bufferView));
    strOpt(m, "mimeType", im.mimeType);
    strOpt(m, "name", im.name);
    strOpt(m, "uri", im.uri);
    extOpt(m, im.extensions);
    extrasOpt(ser, m, im.extras);
    return JsonValue.object(m);
}

function serMaterial(ser: Ser, mat: Material): JsonValue {
    const m = new JsonMap();
    if (!isNaN(mat.alphaCutoff)) m.insert("alphaCutoff", f32v(mat.alphaCutoff));
    if (ser.checked(mat.alphaMode)) m.insert("alphaMode", JsonValue.str(alphaModeName(<AlphaMode>mat.alphaMode)));
    m.insert("doubleSided", JsonValue.bool(mat.doubleSided));
    strOpt(m, "name", mat.name);
    const pbr = mat.pbrMetallicRoughness;
    const pm = new JsonMap();
    pm.insert("baseColorFactor", f32Array(pbr.baseColorFactor));
    const bct = pbr.baseColorTexture;
    if (bct != null) pm.insert("baseColorTexture", serTextureInfo(ser, bct));
    pm.insert("metallicFactor", f32v(pbr.metallicFactor));
    pm.insert("roughnessFactor", f32v(pbr.roughnessFactor));
    const mrt = pbr.metallicRoughnessTexture;
    if (mrt != null) pm.insert("metallicRoughnessTexture", serTextureInfo(ser, mrt));
    extOpt(pm, pbr.extensions);
    extrasOpt(ser, pm, pbr.extras);
    m.insert("pbrMetallicRoughness", JsonValue.object(pm));
    const nt = mat.normalTexture;
    if (nt != null) {
        const nm = new JsonMap();
        nm.insert("index", idx(nt.index));
        nm.insert("scale", f32v(nt.scale));
        nm.insert("texCoord", JsonValue.fromU64(<u64>nt.texCoord));
        extOpt(nm, nt.extensions);
        extrasOpt(ser, nm, nt.extras);
        m.insert("normalTexture", JsonValue.object(nm));
    }
    const ot = mat.occlusionTexture;
    if (ot != null) {
        const om = new JsonMap();
        om.insert("index", idx(ot.index));
        om.insert("strength", f32v(ot.strength));
        om.insert("texCoord", JsonValue.fromU64(<u64>ot.texCoord));
        extOpt(om, ot.extensions);
        extrasOpt(ser, om, ot.extras);
        m.insert("occlusionTexture", JsonValue.object(om));
    }
    const et = mat.emissiveTexture;
    if (et != null) m.insert("emissiveTexture", serTextureInfo(ser, et));
    m.insert("emissiveFactor", f32Array(mat.emissiveFactor));
    const e = mat.extensions;
    if (e != null) {
        const em = new JsonMap();
        const es = e.emissiveStrength;
        if (es != null) {
            const sm = new JsonMap();
            sm.insert("emissiveStrength", f32v(es.emissiveStrength));
            em.insert(KHR_MATERIALS_EMISSIVE_STRENGTH, JsonValue.object(sm));
        }
        othersInto(em, e.others);
        m.insert("extensions", JsonValue.object(em));
    }
    extrasOpt(ser, m, mat.extras);
    return JsonValue.object(m);
}

function serPrimitive(ser: Ser, p: Primitive): JsonValue {
    const m = new JsonMap();
    const am = new JsonMap();
    for (let i = 0; i < p.attributes.keys.length; i++) {
        const k = p.attributes.keys[i];
        if (!k.isValid()) {
            ser.failed = true;
            continue;
        }
        am.insert(k.toString(), idx(p.attributes.values[i]));
    }
    m.insert("attributes", JsonValue.object(am));
    extOpt(m, p.extensions);
    extrasOpt(ser, m, p.extras);
    if (p.indices >= 0) m.insert("indices", idx(p.indices));
    if (p.material >= 0) m.insert("material", idx(p.material));
    if (p.mode != Mode.Triangles && ser.checked(p.mode)) {
        m.insert("mode", JsonValue.fromU64(<u64>modeGlEnum(<Mode>p.mode)));
    }
    const ts = p.targets;
    if (ts != null) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < ts.length; i++) {
            const t = ts[i];
            const tm = new JsonMap();
            if (t.positions >= 0) tm.insert("POSITION", idx(t.positions));
            if (t.normals >= 0) tm.insert("NORMAL", idx(t.normals));
            if (t.tangents >= 0) tm.insert("TANGENT", idx(t.tangents));
            items.push(JsonValue.object(tm));
        }
        m.insert("targets", JsonValue.array(items));
    }
    return JsonValue.object(m);
}

function serMesh(ser: Ser, mesh: Mesh): JsonValue {
    const m = new JsonMap();
    extOpt(m, mesh.extensions);
    extrasOpt(ser, m, mesh.extras);
    strOpt(m, "name", mesh.name);
    const items: Array<JsonValue> = [];
    for (let i = 0; i < mesh.primitives.length; i++) items.push(serPrimitive(ser, mesh.primitives[i]));
    m.insert("primitives", JsonValue.array(items));
    const w = mesh.weights;
    if (w != null) m.insert("weights", f32Vec(w));
    return JsonValue.object(m);
}

function serNode(ser: Ser, n: Node): JsonValue {
    const m = new JsonMap();
    if (n.camera >= 0) m.insert("camera", idx(n.camera));
    const ch = n.children;
    if (ch != null) m.insert("children", idxVec(ch));
    const e = n.extensions;
    if (e != null) {
        const em = new JsonMap();
        const k = e.khrLightsPunctual;
        if (k != null) {
            const km = new JsonMap();
            km.insert("light", idx(k.light));
            em.insert(KHR_LIGHTS_PUNCTUAL, JsonValue.object(km));
        }
        othersInto(em, e.others);
        m.insert("extensions", JsonValue.object(em));
    }
    extrasOpt(ser, m, n.extras);
    const mat = n.matrix;
    if (mat != null) m.insert("matrix", f32Array(mat));
    if (n.mesh >= 0) m.insert("mesh", idx(n.mesh));
    strOpt(m, "name", n.name);
    const r = n.rotation;
    if (r != null) m.insert("rotation", f32Array(r));
    const s = n.scale;
    if (s != null) m.insert("scale", f32Array(s));
    const t = n.translation;
    if (t != null) m.insert("translation", f32Array(t));
    if (n.skin >= 0) m.insert("skin", idx(n.skin));
    const w = n.weights;
    if (w != null) m.insert("weights", f32Vec(w));
    return JsonValue.object(m);
}

function serSampler(ser: Ser, s: Sampler): JsonValue {
    const m = new JsonMap();
    if (s.magFilter != CHECKED_NONE && ser.checked(s.magFilter)) {
        m.insert("magFilter", JsonValue.fromU64(<u64>magFilterGlEnum(<MagFilter>s.magFilter)));
    }
    if (s.minFilter != CHECKED_NONE && ser.checked(s.minFilter)) {
        m.insert("minFilter", JsonValue.fromU64(<u64>minFilterGlEnum(<MinFilter>s.minFilter)));
    }
    strOpt(m, "name", s.name);
    if (ser.checked(s.wrapS)) m.insert("wrapS", JsonValue.fromU64(<u64>wrappingModeGlEnum(<WrappingMode>s.wrapS)));
    if (ser.checked(s.wrapT)) m.insert("wrapT", JsonValue.fromU64(<u64>wrappingModeGlEnum(<WrappingMode>s.wrapT)));
    extOpt(m, s.extensions);
    extrasOpt(ser, m, s.extras);
    return JsonValue.object(m);
}

function serScene(ser: Ser, s: Scene): JsonValue {
    const m = new JsonMap();
    extOpt(m, s.extensions);
    extrasOpt(ser, m, s.extras);
    strOpt(m, "name", s.name);
    if (s.nodes.length > 0) m.insert("nodes", idxVec(s.nodes));
    return JsonValue.object(m);
}

function serSkin(ser: Ser, s: Skin): JsonValue {
    const m = new JsonMap();
    extOpt(m, s.extensions);
    extrasOpt(ser, m, s.extras);
    if (s.inverseBindMatrices >= 0) m.insert("inverseBindMatrices", idx(s.inverseBindMatrices));
    if (s.joints.length > 0) m.insert("joints", idxVec(s.joints));
    strOpt(m, "name", s.name);
    if (s.skeleton >= 0) m.insert("skeleton", idx(s.skeleton));
    return JsonValue.object(m);
}

function serTexture(ser: Ser, t: Texture): JsonValue {
    const m = new JsonMap();
    strOpt(m, "name", t.name);
    if (t.sampler >= 0) m.insert("sampler", idx(t.sampler));
    if (t.source != TEXTURE_SOURCE_EMPTY) m.insert("source", JsonValue.fromU64(<u64>t.source));
    extOpt(m, t.extensions);
    extrasOpt(ser, m, t.extras);
    return JsonValue.object(m);
}

function serLight(ser: Ser, l: KhrLight): JsonValue {
    const m = new JsonMap();
    m.insert("color", f32Array(l.color));
    const e = l.extensions;
    if (e != null) m.insert("extensions", ser.raw(e));
    extrasOpt(ser, m, l.extras);
    m.insert("intensity", f32v(l.intensity));
    strOpt(m, "name", l.name);
    if (!isNaN(l.range)) m.insert("range", f32v(l.range));
    const s = l.spot;
    if (s != null) {
        const sm = new JsonMap();
        sm.insert("innerConeAngle", f32v(s.innerConeAngle));
        sm.insert("outerConeAngle", f32v(s.outerConeAngle));
        m.insert("spot", JsonValue.object(sm));
    }
    if (ser.checked(l.type_)) m.insert("type", JsonValue.str(khrLightTypeName(<KhrLightType>l.type_)));
    return JsonValue.object(m);
}

function serRoot(ser: Ser, r: Root): JsonValue {
    const m = new JsonMap();
    if (r.accessors.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.accessors.length; i++) items.push(serAccessor(ser, r.accessors[i]));
        m.insert("accessors", JsonValue.array(items));
    }
    if (r.animations.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.animations.length; i++) items.push(serAnimation(ser, r.animations[i]));
        m.insert("animations", JsonValue.array(items));
    }
    m.insert("asset", serAsset(ser, r.asset));
    if (r.buffers.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.buffers.length; i++) items.push(serBuffer(ser, r.buffers[i]));
        m.insert("buffers", JsonValue.array(items));
    }
    if (r.bufferViews.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.bufferViews.length; i++) items.push(serView(ser, r.bufferViews[i]));
        m.insert("bufferViews", JsonValue.array(items));
    }
    if (r.scene >= 0) m.insert("scene", idx(r.scene));
    const e = r.extensions;
    if (e != null) {
        const em = new JsonMap();
        const k = e.khrLightsPunctual;
        if (k != null) {
            const km = new JsonMap();
            const lights: Array<JsonValue> = [];
            for (let i = 0; i < k.lights.length; i++) lights.push(serLight(ser, k.lights[i]));
            km.insert("lights", JsonValue.array(lights));
            em.insert(KHR_LIGHTS_PUNCTUAL, JsonValue.object(km));
        }
        othersInto(em, e.others);
        m.insert("extensions", JsonValue.object(em));
    }
    extrasOpt(ser, m, r.extras);
    if (r.extensionsUsed.length > 0) m.insert("extensionsUsed", JsonValue.strArray(r.extensionsUsed));
    if (r.extensionsRequired.length > 0) m.insert("extensionsRequired", JsonValue.strArray(r.extensionsRequired));
    if (r.cameras.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.cameras.length; i++) items.push(serCamera(ser, r.cameras[i]));
        m.insert("cameras", JsonValue.array(items));
    }
    if (r.images.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.images.length; i++) items.push(serImage(ser, r.images[i]));
        m.insert("images", JsonValue.array(items));
    }
    if (r.materials.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.materials.length; i++) items.push(serMaterial(ser, r.materials[i]));
        m.insert("materials", JsonValue.array(items));
    }
    if (r.meshes.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.meshes.length; i++) items.push(serMesh(ser, r.meshes[i]));
        m.insert("meshes", JsonValue.array(items));
    }
    if (r.nodes.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.nodes.length; i++) items.push(serNode(ser, r.nodes[i]));
        m.insert("nodes", JsonValue.array(items));
    }
    if (r.samplers.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.samplers.length; i++) items.push(serSampler(ser, r.samplers[i]));
        m.insert("samplers", JsonValue.array(items));
    }
    if (r.scenes.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.scenes.length; i++) items.push(serScene(ser, r.scenes[i]));
        m.insert("scenes", JsonValue.array(items));
    }
    if (r.skins.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.skins.length; i++) items.push(serSkin(ser, r.skins[i]));
        m.insert("skins", JsonValue.array(items));
    }
    if (r.textures.length > 0) {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < r.textures.length; i++) items.push(serTexture(ser, r.textures[i]));
        m.insert("textures", JsonValue.array(items));
    }
    return JsonValue.object(m);
}

function finish(ser: Ser, v: JsonValue, pretty: bool): Result<string> {
    if (ser.failed) return Result.fail<string>(INVALID_ITEM);
    const text = pretty ? v.toStringPretty() : v.toString();
    if (ser.raws.length == 0) return Result.okv<string>(text);
    // One pass: the placeholders are written in the order they were made
    // (each struct's map is built in field order), so each is searched for
    // after the previous one. (A `replace` per raw value would copy the
    // whole text once per `extras`.)
    const parts: Array<string> = [];
    let from = 0;
    for (let i = 0; i < ser.raws.length; i++) {
        const token = jsonQuote(RAW_MARK + i.toString() + "\u0000");
        let at = text.indexOf(token, from);
        if (at < 0) {
            // Not in creation order after all: fall back to a plain search.
            parts.push(text.substring(from));
            let rest = parts.join("");
            for (let k = i; k < ser.raws.length; k++) {
                rest = rest.replace(jsonQuote(RAW_MARK + k.toString() + "\u0000"), ser.raws[k]);
            }
            return Result.okv<string>(rest);
        }
        parts.push(text.substring(from, at));
        parts.push(ser.raws[i]);
        from = at + token.length;
    }
    parts.push(text.substring(from));
    return Result.okv<string>(parts.join(""));
}

// Root::to_string: compact JSON.
export function rootToString(r: Root): Result<string> {
    const ser = new Ser();
    const v = serRoot(ser, r);
    return finish(ser, v, false);
}

// Root::to_string_pretty.
export function rootToStringPretty(r: Root): Result<string> {
    const ser = new Ser();
    const v = serRoot(ser, r);
    return finish(ser, v, true);
}

// Root::to_vec: the compact JSON as UTF-8 bytes.
export function rootToVec(r: Root): Result<Uint8Array> {
    const s = rootToString(r);
    if (!s.ok) return s.forward<Uint8Array>();
    return Result.okv<Uint8Array>(Uint8Array.wrap(String.UTF8.encode(s.value)));
}

// The compact JSON of a Camera (the io tests look at it).
export function cameraToString(c: Camera): Result<string> {
    const ser = new Ser();
    const v = serCamera(ser, c);
    return finish(ser, v, false);
}

// The compact JSON of a KHR_lights_punctual Light.
export function khrLightToString(l: KhrLight): Result<string> {
    const ser = new Ser();
    const v = serLight(ser, l);
    return finish(ser, v, false);
}

// An i32 enum field's value; panics when it is CHECKED_INVALID.
export function unwrapChecked(v: i32): i32 {
    if (v == CHECKED_INVALID) panic(UNWRAP_INVALID_ITEM);
    return v;
}
