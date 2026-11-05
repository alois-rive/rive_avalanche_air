// Named attributes, generic per-element layers on
// the four mesh domains (Blender's named attributes).
//
// Storage: each layer keeps one flat array indexed by element id; ids are
// never reused, so the array grows with `idBound` and carries holes where
// elements were deleted. New elements get the type's zero unless the
// operator that made them says otherwise (`Mesh.addVertFrom` interpolates
// point attributes, `Mesh.addFaceLike` copies face attributes).
//
// This module holds the data types. The Mesh methods (attrIndex, attr,
// attrMut, addAttr, removeAttr, growAttrs, attrValue, attrOn, copyAttrs,
// interpolatePointAttrs, convertAttr, ...) are on the Mesh class in
// engine/src/source/model/mesh/mod.as, under the "attributes" section.

import { Vec3 } from "../../../base/vecmath";
import { f64ToI32, roundF64 } from "../../../base/util";
import { debugF64, debugTuple } from "../../../base/fmt";
import { ElemKind } from "./mod";

// Which element an attribute is stored on. Blender's four domains, under
// Blender's names. Variant order is the file format.
export enum Domain {
    Point,
    Edge,
    Face,
    // A face corner: one entry per loop.
    Corner,
}

export namespace Domain {
    export function name(d: Domain): string {
        switch (d) {
            case Domain.Point: return "point";
            case Domain.Edge: return "edge";
            case Domain.Face: return "face";
            default: return "corner";
        }
    }

    // The variant name ("Point", ...), also used in saved data.
    export function debug(d: Domain): string {
        switch (d) {
            case Domain.Point: return "Point";
            case Domain.Edge: return "Edge";
            case Domain.Face: return "Face";
            default: return "Corner";
        }
    }

    // The domain named by `s`, or -1.
    export function parse(s: string): i32 {
        if (s == "point" || s == "vert" || s == "vertex" || s == "verts" || s == "vertices" || s == "points") return Domain.Point;
        if (s == "edge" || s == "edges") return Domain.Edge;
        if (s == "face" || s == "faces") return Domain.Face;
        if (s == "corner" || s == "corners" || s == "loop" || s == "loops") return Domain.Corner;
        return -1;
    }

    // The selection domain an element kind reads from.
    export function of(kind: ElemKind): Domain {
        switch (kind) {
            case ElemKind.Vert: return Domain.Point;
            case ElemKind.Edge: return Domain.Edge;
            default: return Domain.Face;
        }
    }
}

export const DOMAINS: Array<string> = ["point", "edge", "face", "corner"];
export const TYPES: Array<string> = ["float", "int", "bool", "vec3"];

// Variant order is the file format (and matches the AttrData variants).
export enum AttrType {
    Float,
    Int,
    Bool,
    Vec3,
}

export namespace AttrType {
    export function name(t: AttrType): string {
        switch (t) {
            case AttrType.Float: return "float";
            case AttrType.Int: return "int";
            case AttrType.Bool: return "bool";
            default: return "vec3";
        }
    }

    // The variant name ("Float", ...), also used in saved data.
    export function debug(t: AttrType): string {
        switch (t) {
            case AttrType.Float: return "Float";
            case AttrType.Int: return "Int";
            case AttrType.Bool: return "Bool";
            default: return "Vec3";
        }
    }

    // The type named by `s`, or -1.
    export function parse(s: string): i32 {
        if (s == "float" || s == "number") return AttrType.Float;
        if (s == "int" || s == "integer") return AttrType.Int;
        if (s == "bool" || s == "boolean") return AttrType.Bool;
        if (s == "vec3" || s == "vector" || s == "float_vector") return AttrType.Vec3;
        return -1;
    }
}

export enum AttrValueKind {
    Num,
    Vec3,
}

// One element's value: a number (f64) or a Vec3.
// Scalars are f64 at the boundary (what the expression language speaks).
// Treat instances as immutable values: build new ones with
// AttrValue.num / AttrValue.vec3 instead of writing the fields.
export class AttrValue {
    kind: AttrValueKind = AttrValueKind.Num;
    // The payload of Num.
    n: f64 = 0;
    // The payload of Vec3.
    v: Vec3 = Vec3(0, 0, 0);

    static num(n: f64): AttrValue {
        const a = new AttrValue();
        a.kind = AttrValueKind.Num;
        a.n = n;
        return a;
    }

    static vec3(v: Vec3): AttrValue {
        const a = new AttrValue();
        a.kind = AttrValueKind.Vec3;
        a.v = v;
        return a;
    }

    isNum(): bool {
        return this.kind == AttrValueKind.Num;
    }

    isVec3(): bool {
        return this.kind == AttrValueKind.Vec3;
    }

    // A vector used where a number is wanted reads as its length.
    asF64(): f64 {
        if (this.kind == AttrValueKind.Num) return this.n;
        return <f64>this.v.length();
    }

    asVec3(): Vec3 {
        if (this.kind == AttrValueKind.Num) return Vec3.splat(<f32>this.n);
        return this.v;
    }

    // Field-wise equality (float `==`: NaN != NaN, 0.0 == -0.0).
    equals(o: AttrValue?): bool {
        if (o == null) return false;
        const other = o!;
        if (this.kind != other.kind) return false;
        if (this.kind == AttrValueKind.Num) return this.n == other.n;
        return this.v == other.v;
    }

    // Debug text: `Num(1.0)` / `Vec3(Vec3(0.0, 0.0, 1.0))`.
    debug(): string {
        if (this.kind == AttrValueKind.Num) return debugTuple("Num", [debugF64(this.n)]);
        return debugTuple("Vec3", [this.v.debug()]);
    }
}

// Equality of optional values for tests: both null, or both equal.
export function attrValueEq(a: AttrValue?, b: AttrValue?): bool {
    if (a == null) return b == null;
    return a!.equals(b);
}

// The values of one layer, flat and indexed by element id: f32, i32, bool
// or Vec3. `kind` is the variant (same order as AttrType) and only the matching
// array is used; the others stay empty.
export class AttrData {
    kind: AttrType = AttrType.Float;
    floats: Array<f32> = [];
    ints: Array<i32> = [];
    bools: Array<bool> = [];
    vecs: Array<Vec3> = [];

    // A layer of `len` zeros.
    static new(ty: AttrType, len: i32): AttrData {
        const d = new AttrData();
        d.kind = ty;
        d.resize(len);
        return d;
    }

    len(): i32 {
        switch (this.kind) {
            case AttrType.Float: return this.floats.length;
            case AttrType.Int: return this.ints.length;
            case AttrType.Bool: return this.bools.length;
            default: return this.vecs.length;
        }
    }

    isEmpty(): bool {
        return this.len() == 0;
    }

    // Resizes, filling with the type's zero (truncates when shorter).
    resize(len: i32): void {
        switch (this.kind) {
            case AttrType.Float: {
                const v = this.floats;
                const old = v.length;
                v.length = len;
                for (let i = old; i < len; i++) v[i] = 0;
                break;
            }
            case AttrType.Int: {
                const v = this.ints;
                const old = v.length;
                v.length = len;
                for (let i = old; i < len; i++) v[i] = 0;
                break;
            }
            case AttrType.Bool: {
                const v = this.bools;
                const old = v.length;
                v.length = len;
                for (let i = old; i < len; i++) v[i] = false;
                break;
            }
            default: {
                const v = this.vecs;
                while (v.length > len) v.pop();
                while (v.length < len) v.push(Vec3(0, 0, 0));
                break;
            }
        }
    }

    // The value at `i`, or null past the end.
    get(i: i32): AttrValue? {
        if (i < 0 || i >= this.len()) return null;
        switch (this.kind) {
            case AttrType.Float: return AttrValue.num(<f64>this.floats[i]);
            case AttrType.Int: return AttrValue.num(<f64>this.ints[i]);
            case AttrType.Bool: return AttrValue.num(this.bools[i] ? 1.0 : 0.0);
            default: return AttrValue.vec3(this.vecs[i]);
        }
    }

    // Stores `value` converted to the layer's type; ignored past the end.
    set(i: i32, value: AttrValue): void {
        if (i < 0 || i >= this.len()) return;
        switch (this.kind) {
            case AttrType.Float:
                this.floats[i] = <f32>value.asF64();
                break;
            case AttrType.Int:
                this.ints[i] = f64ToI32(roundF64(value.asF64()));
                break;
            case AttrType.Bool:
                this.bools[i] = value.asF64() != 0.0;
                break;
            default: {
                // Array<struct> takes no indexed store: write the fields.
                const v = value.asVec3();
                this.vecs[i].x = v.x;
                this.vecs[i].y = v.y;
                this.vecs[i].z = v.z;
                break;
            }
        }
    }

    clone(): AttrData {
        const d = new AttrData();
        d.kind = this.kind;
        d.floats = this.floats.slice(0);
        d.ints = this.ints.slice(0);
        d.bools = this.bools.slice(0);
        d.vecs = this.vecs.slice(0);
        return d;
    }

    // Field-wise equality.
    equals(o: AttrData): bool {

        if (this.kind != o.kind) return false;
        const n = this.len();
        if (n != o.len()) return false;
        switch (this.kind) {
            case AttrType.Float: {
                for (let i = 0; i < n; i++) if (this.floats[i] != o.floats[i]) return false;
                return true;
            }
            case AttrType.Int: {
                for (let i = 0; i < n; i++) if (this.ints[i] != o.ints[i]) return false;
                return true;
            }
            case AttrType.Bool: {
                for (let i = 0; i < n; i++) if (this.bools[i] != o.bools[i]) return false;
                return true;
            }
            default: {
                for (let i = 0; i < n; i++) if (!(this.vecs[i] == o.vecs[i])) return false;
                return true;
            }
        }
    }
}

export class AttrLayer {
    name: string = "";
    domain: Domain = Domain.Point;
    data: AttrData = new AttrData();

    static new(name: string, domain: Domain, data: AttrData): AttrLayer {
        const l = new AttrLayer();
        l.name = name;
        l.domain = domain;
        l.data = data;
        return l;
    }

    ty(): AttrType {
        return this.data.kind;
    }

    get(id: u32): AttrValue? {
        return this.data.get(<i32>id);
    }

    set(id: u32, value: AttrValue): void {
        this.data.set(<i32>id, value);
    }

    clone(): AttrLayer {
        return AttrLayer.new(this.name, this.domain, this.data.clone());
    }

    equals(o: AttrLayer): bool {
        return this.name == o.name && this.domain == o.domain && this.data.equals(o.data);
    }
}

// Names a user attribute may not take, because `attribute set` already
// means something by them.
export const RESERVED_NAMES: Array<string> = ["position", "normal", "id", "index"];

// The mean of a list of values: a vector if any value was one (divided by
// `n as f32`), otherwise the f64 mean of the scalars. Null for no values.
export function attrMean(values: Array<AttrValue>): AttrValue? {
    let num: f64 = 0.0;
    let vec = Vec3(0, 0, 0);
    let anyVec = false;
    let n: f64 = 0.0;
    for (let i = 0; i < values.length; i++) {
        const v = values[i];
        if (v.kind == AttrValueKind.Num) {
            num += v.n;
        } else {
            vec = vec + v.v;
            anyVec = true;
        }
        n += 1.0;
    }
    if (n == 0.0) return null;
    if (anyVec) return AttrValue.vec3(vec / <f32>n);
    return AttrValue.num(num / n);
}
