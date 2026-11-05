// A property value of the scene format: one of Godot's variant literals
// (docs/formats/RSCN.md, "Values"). A Value is what the text says, exactly:
// numbers are kept as f64 (an Int as i64), so that printing a parsed value
// gives back the same number, and the library converts to f32 only where it
// builds its runtime objects. The text form (parse and print) is in
// value_text.as.
//
// One class with a kind tag and the union of the payloads (as CoreError):
//   Bool b; Int i; Float f;
//   String, StringName, NodePath: s;
//   ExtResource, SubResource: s is the resource id;
//   Unknown: s is the literal's source text, kept verbatim (a constructor
//     this format version does not know, e.g. AABB(...), so that a newer
//     file survives an older tool);
//   Vector2(i), Vector3(i), Vector4, Color, Quaternion, Basis, Transform3D:
//     n, the numbers in their text order (Color r, g, b, a; Quaternion x, y,
//     z, w; Basis the x, y and z axis; Transform3D the three axes, then the
//     origin);
//   Array: items; Dictionary: keys and items, pairwise, in source order;
//   PackedFloat32Array: n, the numbers in their text order (milestone 13:
//     a MultiMesh's `buffer`), of any length, kept as f64 like the others
//     so that a number printed back is the one read;
//   PackedVector3Array: n, three numbers a point, x y z (milestone 31: a
//     ConvexPolygonShape3D's `points`, a ConcavePolygonShape3D's `data`),
//     kept as f64 for the same reason;
//   PackedColorArray: n, four numbers a colour, r g b a (milestone 35: a
//     Gradient's `colors`, a CPUParticles3D's `emission_colors`), likewise;
//   PackedVector2Array: n, two numbers a point, x y (milestone 37: a
//     PolygonOccluder3D's `polygon`), likewise;
//   PackedInt32Array: n, whole numbers within the i32 range (milestone 37:
//     an ArrayOccluder3D's `indices`), kept as f64 like the others (every
//     i32 is exact in an f64).

import { i64ToI32, i64ToU32 } from "../base/util";
import { Mat3, Mat4, Quat, Vec2, Vec3, Vec4 } from "../base/vecmath";

export enum ValueKind {
    Nil,
    Bool,
    Int,
    Float,
    String,
    StringName,
    NodePath,
    Vector2,
    Vector2i,
    Vector3,
    Vector3i,
    Vector4,
    Color,
    Quaternion,
    Basis,
    Transform3D,
    Array,
    Dictionary,
    ExtResource,
    SubResource,
    Unknown,
    // Milestone 13, last so that no earlier kind's number moves.
    PackedFloat32Array,
    // Milestone 31, after it for the same reason (.rscnb's value tags are
    // these numbers).
    PackedVector3Array,
    // Milestone 35, last for the same reason.
    PackedColorArray,
    // Milestone 37, last for the same reason.
    PackedVector2Array,
    PackedInt32Array,
}

// The kind as the format spells it ("Vector3", "ExtResource"); Nil is
// "null", Bool "bool", Int "int", Float "float", String "String".
export function valueKindName(k: ValueKind): string {
    switch (k) {
        case ValueKind.Nil: return "null";
        case ValueKind.Bool: return "bool";
        case ValueKind.Int: return "int";
        case ValueKind.Float: return "float";
        case ValueKind.String: return "String";
        case ValueKind.StringName: return "StringName";
        case ValueKind.NodePath: return "NodePath";
        case ValueKind.Vector2: return "Vector2";
        case ValueKind.Vector2i: return "Vector2i";
        case ValueKind.Vector3: return "Vector3";
        case ValueKind.Vector3i: return "Vector3i";
        case ValueKind.Vector4: return "Vector4";
        case ValueKind.Color: return "Color";
        case ValueKind.Quaternion: return "Quaternion";
        case ValueKind.Basis: return "Basis";
        case ValueKind.Transform3D: return "Transform3D";
        case ValueKind.Array: return "Array";
        case ValueKind.Dictionary: return "Dictionary";
        case ValueKind.ExtResource: return "ExtResource";
        case ValueKind.SubResource: return "SubResource";
        case ValueKind.PackedFloat32Array: return "PackedFloat32Array";
        case ValueKind.PackedVector3Array: return "PackedVector3Array";
        case ValueKind.PackedColorArray: return "PackedColorArray";
        case ValueKind.PackedVector2Array: return "PackedVector2Array";
        case ValueKind.PackedInt32Array: return "PackedInt32Array";
        default: return "unknown";
    }
}

// How many numbers a fixed-size kind holds (0 for the others).
export function componentCount(k: ValueKind): i32 {
    switch (k) {
        case ValueKind.Vector2:
        case ValueKind.Vector2i: return 2;
        case ValueKind.Vector3:
        case ValueKind.Vector3i: return 3;
        case ValueKind.Vector4:
        case ValueKind.Color:
        case ValueKind.Quaternion: return 4;
        case ValueKind.Basis: return 9;
        case ValueKind.Transform3D: return 12;
        default: return 0;
    }
}

// f64 equality that tells NaN from NaN by bits, so that `equals` is exact.
function sameF64(a: f64, b: f64): bool {
    return reinterpret<u64>(a) == reinterpret<u64>(b);
}

// The payload arrays of a Value whose kind has none (milestone 13: a scene
// of 10,000 nodes reads 30,000 values, and three empty arrays each were
// most of what reading one allocated). Shared, so never changed: a Value's
// arrays are always replaced by new ones (Value.numbers, Value.array, ...),
// never grown in place.
const NO_NUMBERS: Array<f64> = [];
const NO_VALUES: Array<Value> = [];

export class Value {
    kind: ValueKind = ValueKind.Nil;
    b: bool = false;
    i: i64 = 0;
    f: f64 = 0;
    s: string = "";
    // (NO_NUMBERS and NO_VALUES until set: assign, never push)
    n: Array<f64> = NO_NUMBERS;
    items: Array<Value> = NO_VALUES;
    keys: Array<Value> = NO_VALUES;

    constructor(kind: ValueKind = ValueKind.Nil) {
        this.kind = kind;
    }

    static nil(): Value {
        return new Value(ValueKind.Nil);
    }

    static bool(b: bool): Value {
        const v = new Value(ValueKind.Bool);
        v.b = b;
        return v;
    }

    static int(i: i64): Value {
        const v = new Value(ValueKind.Int);
        v.i = i;
        return v;
    }

    static float(f: f64): Value {
        const v = new Value(ValueKind.Float);
        v.f = f;
        return v;
    }

    static str(s: string): Value {
        const v = new Value(ValueKind.String);
        v.s = s;
        return v;
    }

    static stringName(s: string): Value {
        const v = new Value(ValueKind.StringName);
        v.s = s;
        return v;
    }

    static nodePath(s: string): Value {
        const v = new Value(ValueKind.NodePath);
        v.s = s;
        return v;
    }

    // A fixed-size kind from its numbers (componentCount(kind) of them).
    static numbers(kind: ValueKind, n: Array<f64>): Value {
        const v = new Value(kind);
        v.n = n.slice(0);
        return v;
    }

    // A PackedFloat32Array of `n` (copied), of any length.
    static packedFloats(n: Array<f64>): Value {
        const v = new Value(ValueKind.PackedFloat32Array);
        v.n = n.slice(0);
        return v;
    }

    // Milestone 31: a PackedVector3Array of `n` (copied): three numbers a
    // point, so its length is a multiple of 3 (the parser refuses any
    // other; built in code, the caller sees to it).
    static packedVector3s(n: Array<f64>): Value {
        const v = new Value(ValueKind.PackedVector3Array);
        v.n = n.slice(0);
        return v;
    }

    // Milestone 35: a PackedColorArray of `n` (copied): four numbers a
    // colour, so its length is a multiple of 4 (the parser refuses any
    // other; built in code, the caller sees to it).
    static packedColors(n: Array<f64>): Value {
        const v = new Value(ValueKind.PackedColorArray);
        v.n = n.slice(0);
        return v;
    }

    // Milestone 37: a PackedVector2Array of `n` (copied): two numbers a
    // point, so its length is even (the parser refuses any other; built
    // in code, the caller sees to it).
    static packedVector2s(n: Array<f64>): Value {
        const v = new Value(ValueKind.PackedVector2Array);
        v.n = n.slice(0);
        return v;
    }

    // Milestone 37: a PackedInt32Array of `n` (copied): whole numbers in
    // the i32 range (the parser refuses any other; built in code, the
    // caller sees to it).
    static packedInts(n: Array<f64>): Value {
        const v = new Value(ValueKind.PackedInt32Array);
        v.n = n.slice(0);
        return v;
    }

    static vector2(x: f64, y: f64): Value {
        return Value.numbers(ValueKind.Vector2, [x, y]);
    }

    static vector3(x: f64, y: f64, z: f64): Value {
        return Value.numbers(ValueKind.Vector3, [x, y, z]);
    }

    static color(r: f64, g: f64, b: f64, a: f64 = 1): Value {
        return Value.numbers(ValueKind.Color, [r, g, b, a]);
    }

    static quaternion(x: f64, y: f64, z: f64, w: f64): Value {
        return Value.numbers(ValueKind.Quaternion, [x, y, z, w]);
    }

    // Transform3D from a Mat4: its basis row by row, then its origin. The
    // rows, not the axes, because that is the order Godot 4 writes (its
    // Basis holds rows), so that a transform copied from a .tscn means the
    // same rotation here rather than its inverse.
    static transform(m: Mat4): Value {
        return Value.numbers(ValueKind.Transform3D, [
            <f64>m.xAxis.x, <f64>m.yAxis.x, <f64>m.zAxis.x,
            <f64>m.xAxis.y, <f64>m.yAxis.y, <f64>m.zAxis.y,
            <f64>m.xAxis.z, <f64>m.yAxis.z, <f64>m.zAxis.z,
            <f64>m.wAxis.x, <f64>m.wAxis.y, <f64>m.wAxis.z,
        ]);
    }

    static array(items: Array<Value>): Value {
        const v = new Value(ValueKind.Array);
        v.items = items;
        return v;
    }

    static dictionary(keys: Array<Value>, items: Array<Value>): Value {
        const v = new Value(ValueKind.Dictionary);
        v.keys = keys;
        v.items = items;
        return v;
    }

    static extResource(id: string): Value {
        const v = new Value(ValueKind.ExtResource);
        v.s = id;
        return v;
    }

    static subResource(id: string): Value {
        const v = new Value(ValueKind.SubResource);
        v.s = id;
        return v;
    }

    static unknown(text: string): Value {
        const v = new Value(ValueKind.Unknown);
        v.s = text;
        return v;
    }

    kindName(): string {
        return valueKindName(this.kind);
    }

    isNumber(): bool {
        return this.kind == ValueKind.Int || this.kind == ValueKind.Float;
    }

    isResource(): bool {
        return this.kind == ValueKind.ExtResource || this.kind == ValueKind.SubResource;
    }

    // An Int or Float as f64 (0 for anything else).
    asF64(): f64 {
        if (this.kind == ValueKind.Int) return <f64>this.i;
        if (this.kind == ValueKind.Float) return this.f;
        return 0;
    }

    asF32(): f32 {
        return <f32>this.asF64();
    }

    // An Int as it is, or a Float truncated toward zero, saturated to the
    // i64 range (0 for anything else, and for a NaN). A plain <i64> of a
    // NaN, an infinity or 1e30 traps in wasm, so a script's i64 or u32
    // exported property set to one would stop the built scene at init.
    asI64(): i64 {
        if (this.kind == ValueKind.Int) return this.i;
        if (this.kind == ValueKind.Float) {
            const f = this.f;
            if (isNaN(f)) return 0;
            // 2^63 exactly: i64.MAX_VALUE is not representable as an f64.
            if (f >= 9223372036854775808.0) return i64.MAX_VALUE;
            if (f <= -9223372036854775808.0) return i64.MIN_VALUE;
            return <i64>f;
        }
        return 0;
    }

    // An Int, or a Float truncated toward zero (0 for anything else, and
    // for a NaN), saturated to the i32 range: 4294967300 is i32.MAX_VALUE,
    // not the 4 a wrapping cast would give, so a value too large for a
    // field stays too large for the checks on it (a primitive's vertex
    // limit) instead of turning into a small one. (i64ToI32, not a compare
    // with i32's bounds, which Safari 26.6.2 ran wrong: base/util.as.)
    asI32(): i32 {
        if (this.kind == ValueKind.Int) return i64ToI32(this.i);
        if (this.kind == ValueKind.Float) {
            const f = this.f;
            if (isNaN(f)) return 0;
            if (f >= <f64>i32.MAX_VALUE) return i32.MAX_VALUE;
            if (f <= <f64>i32.MIN_VALUE) return i32.MIN_VALUE;
            return <i32>f;
        }
        return 0;
    }

    // asI64 saturated to the u32 range: a negative value is 0 rather than
    // a wrapped 4294967295, 4294967296 is u32.MAX_VALUE.
    asU32(): u32 {
        return i64ToU32(this.asI64());
    }

    // Number k of a fixed-size kind, as f32.
    at(k: i32): f32 {
        return k < this.n.length ? <f32>this.n[k] : 0;
    }

    vec2(): Vec2 {
        return Vec2(this.at(0), this.at(1));
    }

    vec3(): Vec3 {
        return Vec3(this.at(0), this.at(1), this.at(2));
    }

    // Vector4, Color (r, g, b, a) and Quaternion (x, y, z, w).
    vec4(): Vec4 {
        return Vec4(this.at(0), this.at(1), this.at(2), this.at(3));
    }

    quat(): Quat {
        return Quat(this.at(0), this.at(1), this.at(2), this.at(3));
    }

    // Basis (or the basis of a Transform3D). The nine numbers are its rows,
    // as Godot 4 writes them (see `transform`): the X axis is numbers 0, 3
    // and 6, the Y axis 1, 4 and 7, the Z axis 2, 5 and 8.
    mat3(): Mat3 {
        return Mat3(
            Vec3(this.at(0), this.at(3), this.at(6)),
            Vec3(this.at(1), this.at(4), this.at(7)),
            Vec3(this.at(2), this.at(5), this.at(8)),
        );
    }

    // Transform3D as a Mat4 (a Basis gets a zero origin); rows as in mat3.
    mat4(): Mat4 {
        return Mat4(
            Vec4(this.at(0), this.at(3), this.at(6), 0),
            Vec4(this.at(1), this.at(4), this.at(7), 0),
            Vec4(this.at(2), this.at(5), this.at(8), 0),
            Vec4(this.at(9), this.at(10), this.at(11), 1),
        );
    }

    // Exact equality: the same kind and the same payload, numbers compared
    // by bits (so -0 differs from 0 and NaN equals the same NaN).
    equals(o: Value): bool {
        if (this.kind != o.kind) return false;
        switch (this.kind) {
            case ValueKind.Nil: return true;
            case ValueKind.Bool: return this.b == o.b;
            case ValueKind.Int: return this.i == o.i;
            case ValueKind.Float: return sameF64(this.f, o.f);
            case ValueKind.Array:
            case ValueKind.Dictionary: {
                if (this.items.length != o.items.length || this.keys.length != o.keys.length) return false;
                for (let k = 0; k < this.items.length; k++) if (!this.items[k].equals(o.items[k])) return false;
                for (let k = 0; k < this.keys.length; k++) if (!this.keys[k].equals(o.keys[k])) return false;
                return true;
            }
            default: {
                if (this.s != o.s || this.n.length != o.n.length) return false;
                for (let k = 0; k < this.n.length; k++) if (!sameF64(this.n[k], o.n[k])) return false;
                return true;
            }
        }
    }

    clone(): Value {
        const v = new Value(this.kind);
        v.b = this.b;
        v.i = this.i;
        v.f = this.f;
        v.s = this.s;
        v.n = this.n.length > 0 ? this.n.slice(0) : NO_NUMBERS;
        if (this.items.length > 0) {
            const items = new Array<Value>(this.items.length);
            for (let k = 0; k < this.items.length; k++) items[k] = this.items[k].clone();
            v.items = items;
        }
        if (this.keys.length > 0) {
            const keys = new Array<Value>(this.keys.length);
            for (let k = 0; k < this.keys.length; k++) keys[k] = this.keys[k].clone();
            v.keys = keys;
        }
        return v;
    }
}
