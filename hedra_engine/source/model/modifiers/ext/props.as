// Typed properties over the untyped text core stores.
//
// A `ModifierKindExt` holds a `Map<string, string>` kept in key order — the
// scene file is `postcard`, and a stable layout for a growing family of
// modifiers is worth more than a typed variant each. The types live here
// instead: `PropDef` declares one, `validate` is the gate every stored value
// passes through, and `Props` reads them back at evaluation with the same
// parser, so a value that was accepted cannot fail later.

import { Vec3, VEC3_ZERO, VEC3_X, VEC3_Y, VEC3_Z, toRadians } from "../../../../base/vecmath";
import {
    Result, clampF32, f32ToU32, trimUnicode, toAsciiLowercase, isUnicodeWhitespace,
} from "../../../../base/util";
import { parseF32, parseU32 } from "../../../../base/parse";
import { displayF32 } from "../../../../base/fmt";

// The kinds of property, one per `PropKind` constructor.
export enum PropKindTag {
    Float,
    // A float clamped into a range when it is set.
    Range,
    Int,
    // An int clamped into a range when it is set.
    IntRange,
    Bool,
    // One of a fixed set of words.
    Choice,
    // `x`, `y` or `z`.
    Axis,
    // Any subset of x, y, z as a list (`x,z`, `xyz`, `none`).
    Axes,
    // An angle, written and printed in degrees.
    Degrees,
    // Three numbers.
    Vec3,
    // An object, vertex group or attribute name; `none` clears it.
    Name,
}

// What a property accepts: one
// class with a `tag` and the payload fields of the variants that have one
// (`lo`/`hi` for Range, `ilo`/`ihi` for IntRange, `words` for Choice).
// Build with the static constructors named like the variants.
export class PropKind {
    tag: PropKindTag = PropKindTag.Float;
    lo: f32 = 0;
    hi: f32 = 0;
    ilo: u32 = 0;
    ihi: u32 = 0;
    words: Array<string> = [];

    static of(tag: PropKindTag): PropKind {
        const k = new PropKind();
        k.tag = tag;
        return k;
    }
    static Float(): PropKind { return PropKind.of(PropKindTag.Float); }
    static Range(lo: f32, hi: f32): PropKind {
        const k = PropKind.of(PropKindTag.Range);
        k.lo = lo;
        k.hi = hi;
        return k;
    }
    static Int(): PropKind { return PropKind.of(PropKindTag.Int); }
    static IntRange(lo: u32, hi: u32): PropKind {
        const k = PropKind.of(PropKindTag.IntRange);
        k.ilo = lo;
        k.ihi = hi;
        return k;
    }
    static Bool(): PropKind { return PropKind.of(PropKindTag.Bool); }
    static Choice(words: Array<string>): PropKind {
        const k = PropKind.of(PropKindTag.Choice);
        k.words = words;
        return k;
    }
    static Axis(): PropKind { return PropKind.of(PropKindTag.Axis); }
    static Axes(): PropKind { return PropKind.of(PropKindTag.Axes); }
    static Degrees(): PropKind { return PropKind.of(PropKindTag.Degrees); }
    static Vec3(): PropKind { return PropKind.of(PropKindTag.Vec3); }
    static Name(): PropKind { return PropKind.of(PropKindTag.Name); }

    // Same variant and equal payload (f32 `==`, the
    // word lists element by element).
    equals(o: PropKind): bool {
        if (this.tag != o.tag) return false;
        switch (this.tag) {
            case PropKindTag.Range:
                return this.lo == o.lo && this.hi == o.hi;
            case PropKindTag.IntRange:
                return this.ilo == o.ilo && this.ihi == o.ihi;
            case PropKindTag.Choice: {
                if (this.words.length != o.words.length) return false;
                for (let i = 0; i < this.words.length; i++) {
                    if (this.words[i] != o.words[i]) return false;
                }
                return true;
            }
            default:
                return true;
        }
    }

    label(): string {
        switch (this.tag) {
            case PropKindTag.Float:
            case PropKindTag.Range:
                return "number";
            case PropKindTag.Int:
            case PropKindTag.IntRange:
                return "int";
            case PropKindTag.Bool:
                return "on|off";
            case PropKindTag.Choice:
                return this.words.join("|");
            case PropKindTag.Axis:
                return "x|y|z";
            case PropKindTag.Axes:
                return "x,y,z";
            case PropKindTag.Degrees:
                return "degrees";
            case PropKindTag.Vec3:
                return "x y z";
            default:
                return "name";
        }
    }
}

// One property of one modifier.
export class PropDef {
    name: string = "";
    kind: PropKind = new PropKind();
    // Blender's default, as the text that would be stored.
    default: string = "";
    help: string = "";
}

export function prop(name: string, kind: PropKind, dflt: string, help: string): PropDef {
    const d = new PropDef();
    d.name = name;
    d.kind = kind;
    d.default = dflt;
    d.help = help;
    return d;
}

// Check a value and hand back the text to store.
//
// Normalizing here rather than at read time means the scene, the log and
// `modifier list` all show the same spelling, and a value that round-trips
// through a file is the one that was validated.
export function validate(def: PropDef, value: string): Result<string> {
    const v = trimUnicode(value);
    const name = def.name;
    const kind = def.kind;
    switch (kind.tag) {
        case PropKindTag.Float:
        case PropKindTag.Degrees: {
            const r = number(name, v);
            if (!r.ok) return r.forward<string>();
            return Result.okv<string>(displayF32(r.value));
        }
        case PropKindTag.Range: {
            const r = number(name, v);
            if (!r.ok) return r.forward<string>();
            return Result.okv<string>(displayF32(clampF32(r.value, kind.lo, kind.hi)));
        }
        case PropKindTag.Int: {
            const r = integer(name, v);
            if (!r.ok) return r.forward<string>();
            return Result.okv<string>(r.value.toString());
        }
        case PropKindTag.IntRange: {
            const r = integer(name, v);
            if (!r.ok) return r.forward<string>();
            let n = r.value;
            if (n < kind.ilo) n = kind.ilo;
            if (n > kind.ihi) n = kind.ihi;
            return Result.okv<string>(n.toString());
        }
        case PropKindTag.Bool: {
            const r = boolean(name, v);
            if (!r.ok) return r.forward<string>();
            return Result.okv<string>(r.value ? "true" : "false");
        }
        case PropKindTag.Choice: {
            const lower = toAsciiLowercase(v);
            const words = kind.words;
            for (let i = 0; i < words.length; i++) {
                if (words[i] == lower) return Result.okv<string>(words[i]);
            }
            return Result.fail<string>(name + " takes one of " + words.join(", ") + ", got '" + v + "'");
        }
        case PropKindTag.Axis: {
            const lower = toAsciiLowercase(v);
            if (lower == "x" || lower == "y" || lower == "z") return Result.okv<string>(lower);
            return Result.fail<string>(name + " takes x, y or z, got '" + v + "'");
        }
        case PropKindTag.Axes: {
            const r = parseAxes(name, v);
            if (!r.ok) return r.forward<string>();
            return Result.okv<string>(fmtAxes(r.value));
        }
        case PropKindTag.Vec3: {
            const r = vector(name, v);
            if (!r.ok) return r.forward<string>();
            const p = r.value.v;
            return Result.okv<string>(displayF32(p.x) + " " + displayF32(p.y) + " " + displayF32(p.z));
        }
        default: {
            // Name
            if (v.length == 0) return Result.okv<string>("none");
            return Result.okv<string>(v);
        }
    }
}

function number(name: string, v: string): Result<f32> {
    const r = parseF32(v);
    if (r.ok && isFinite<f32>(r.value)) return Result.okv<f32>(r.value);
    return Result.fail<f32>(name + " takes a number, got '" + v + "'");
}

function integer(name: string, v: string): Result<u32> {
    const r = number(name, v);
    if (!r.ok) return r.forward<u32>();
    const f = r.value;
    // `f.fract()` is `f - f.trunc()`.
    if (f < 0.0 || f - Mathf.trunc(f) != 0.0) {
        return Result.fail<u32>(name + " takes a whole number 0 or more, got '" + v + "'");
    }
    return Result.okv<u32>(f32ToU32(f));
}

function boolean(name: string, v: string): Result<bool> {
    const l = toAsciiLowercase(v);
    if (l == "true" || l == "on" || l == "yes" || l == "1") return Result.okv<bool>(true);
    if (l == "false" || l == "off" || l == "no" || l == "0") return Result.okv<bool>(false);
    return Result.fail<bool>(name + " takes true or false, got '" + v + "'");
}

// `Result<Vec3>` is not allowed (a struct cannot be a generic argument).
class Vec3Box {
    v: Vec3 = Vec3(0, 0, 0);
}

function vector(name: string, v: string): Result<Vec3Box> {
    // `split(|c| c.is_whitespace() || c == ',')`, empty pieces dropped.
    const parts: Array<f32> = [];
    const n = v.length;
    let start = 0;
    for (let i = 0; i <= n; i++) {
        const sep = i == n || isUnicodeWhitespace(v.charCodeAt(i)) || v.charCodeAt(i) == 0x2c;
        if (!sep) continue;
        if (i > start) {
            const r = number(name, v.substring(start, i));
            if (!r.ok) return r.forward<Vec3Box>();
            parts.push(r.value);
        }
        start = i + 1;
    }
    const out = new Vec3Box();
    if (parts.length == 1) {
        out.v = Vec3.splat(parts[0]);
        return Result.okv<Vec3Box>(out);
    }
    if (parts.length == 3) {
        out.v = Vec3(parts[0], parts[1], parts[2]);
        return Result.okv<Vec3Box>(out);
    }
    return Result.fail<Vec3Box>(name + " takes three numbers (\"x y z\"), got '" + v + "'");
}

function bool3(x: bool, y: bool, z: bool): Array<bool> {
    const out: Array<bool> = [];
    out.push(x);
    out.push(y);
    out.push(z);
    return out;
}

// Parse an axis set such as `xz` into three flags.
function parseAxes(name: string, v: string): Result<Array<bool>> {
    let x = false;
    let y = false;
    let z = false;
    const lower = toAsciiLowercase(v);
    if (lower == "none" || lower.length == 0) {
        return Result.okv<Array<bool>>(bool3(false, false, false));
    }
    for (let i = 0; i < lower.length; i++) {
        const c = lower.charCodeAt(i);
        if (c == 0x2c || c == 0x20 || c == 0x2b) continue; // ',' ' ' '+'
        if (c == 0x78) x = true;
        else if (c == 0x79) y = true;
        else if (c == 0x7a) z = true;
        else return Result.fail<Array<bool>>(name + " takes a list of x, y, z, got '" + v + "'");
    }
    return Result.okv<Array<bool>>(bool3(x, y, z));
}

function fmtAxes(a: Array<bool>): string {
    const s: Array<string> = [];
    if (a[0]) s.push("x");
    if (a[1]) s.push("y");
    if (a[2]) s.push("z");
    if (s.length == 0) return "none";
    return s.join(",");
}

// Read-side view of a validated property map.
//
// Every getter falls back to the declared default, so a map written by an
// older build that is missing a property evaluates as Blender would rather
// than failing.
export class Props {
    map: Map<string, string>;
    defs: Array<PropDef>;

    constructor(map: Map<string, string>, defs: Array<PropDef>) {
        this.map = map;
        this.defs = defs;
    }

    static new(map: Map<string, string>, defs: Array<PropDef>): Props {
        return new Props(map, defs);
    }

    private raw(name: string): string {
        if (this.map.has(name)) return this.map.get(name);
        for (let i = 0; i < this.defs.length; i++) {
            if (this.defs[i].name == name) return this.defs[i].default;
        }
        return "";
    }

    f32(name: string): f32 {
        return parseF32(this.raw(name)).unwrapOr(0.0);
    }

    // An angle property, in radians.
    radians(name: string): f32 {
        return toRadians(this.f32(name));
    }

    u32(name: string): u32 {
        return parseU32(this.raw(name)).unwrapOr(0);
    }

    bool(name: string): bool {
        const r = this.raw(name);
        return r == "true" || r == "on" || r == "yes" || r == "1";
    }

    str(name: string): string {
        return this.raw(name);
    }

    // A `PropKind.Name` property, with `none` as "not set" (null).
    optStr(name: string): string? {
        const v = this.raw(name);
        if (v.length == 0 || v == "none") return null;
        return v;
    }

    // A `PropKind.Axis` property as 0, 1 or 2.
    axis(name: string): i32 {
        const r = this.raw(name);
        if (r == "y") return 1;
        if (r == "z") return 2;
        return 0;
    }

    axisVec(name: string): Vec3 {
        const a = this.axis(name);
        if (a == 1) return VEC3_Y;
        if (a == 2) return VEC3_Z;
        return VEC3_X;
    }

    // A `PropKind.Axes` property as three flags.
    axes(name: string): Array<bool> {
        const r = parseAxes(name, this.raw(name));
        if (r.ok) return r.value;
        return bool3(false, false, false);
    }

    vec3(name: string): Vec3 {
        const r = vector(name, this.raw(name));
        if (r.ok) return r.value.v;
        return VEC3_ZERO;
    }
}
