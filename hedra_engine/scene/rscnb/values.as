// The values table of the built binaries (milestone 39): every property
// value a file holds, each distinct value once, as Godot's .scn keeps its
// variants. A file names a value by its index in the table.
//
// A value is one tag byte, its ValueKind (../value.as), then its payload:
//
//   Nil                         nothing
//   Bool                        u8 (0 or 1)
//   Int                         i64
//   Float                       f64 (its bits: -0 and NaNs survive)
//   String, StringName, NodePath,
//   ExtResource, SubResource,
//   Unknown                     u32: an index into the file's string table
//   Vector2 .. Transform3D,
//   PackedFloat32Array,
//   PackedVector3Array,
//   PackedColorArray,
//   PackedVector2Array,
//   PackedInt32Array            u32 n, then n f64 (the numbers as the text
//                               has them: printing a decoded value gives
//                               back the text's number; a PackedVector3Array's
//                               n is a multiple of 3, milestone 31, a
//                               PackedColorArray's of 4, milestone 35, a
//                               PackedVector2Array's of 2, milestone 37,
//                               and a PackedInt32Array's numbers whole
//                               i32s, milestone 37)
//   Array                       u32 n, then n u32 value indices
//   Dictionary                  u32 n, then n pairs of u32 (key, value)
//                               value indices
//
// An Array's or a Dictionary's items are interned before it, so every
// index a value names is smaller than its own: the table decodes front to
// back, and a damaged index (forward, or past the table) is an error, never
// a cycle. Two values are the same entry when their encodings are the same
// bytes, so 1 and 1.0 (Int and Float) stay apart, as the text keeps them.
//
// The table is written as u32 count, u32 byte length of the entries, then
// the entries one after another (unaligned: read through BinReader).
//
// The common ground of everything that reads or writes the built
// binaries (.rscnb and the asset container's models).

import { Value, ValueKind } from "../value";
import { BinReader, BinWriter, StringTable, stringAt } from "./bin";

// The kinds whose payload is a string-table index.
function isStringKind(k: ValueKind): bool {
    return k == ValueKind.String || k == ValueKind.StringName || k == ValueKind.NodePath
        || k == ValueKind.ExtResource || k == ValueKind.SubResource || k == ValueKind.Unknown;
}

// The kinds whose payload is numbers.
function isNumbersKind(k: ValueKind): bool {
    return k == ValueKind.Vector2 || k == ValueKind.Vector2i || k == ValueKind.Vector3 || k == ValueKind.Vector3i
        || k == ValueKind.Vector4 || k == ValueKind.Color || k == ValueKind.Quaternion || k == ValueKind.Basis
        || k == ValueKind.Transform3D || k == ValueKind.PackedFloat32Array || k == ValueKind.PackedVector3Array
        || k == ValueKind.PackedColorArray || k == ValueKind.PackedVector2Array || k == ValueKind.PackedInt32Array;
}

// The highest ValueKind this version knows (a newer tag is an error).
// (milestone 35: PackedColorArray, a tag a reader of before refuses as
// unknown, as it refused every value kind added after it; milestone 37:
// PackedVector2Array and PackedInt32Array likewise)
const LAST_KIND: i32 = <i32>ValueKind.PackedInt32Array;

function hex2(b: u8): string {
    const d = "0123456789abcdef";
    return d.charAt(<i32>(b >> 4)) + d.charAt(<i32>(b & 15));
}

// Builds a values table: `intern` returns a value's index, adding it (and
// its items first) when no entry has the same encoding.
export class ValueTable {
    private strings: StringTable;
    private entries: BinWriter = new BinWriter(1024);
    private keys: Map<string, u32> = new Map<string, u32>();
    private n: u32 = 0;

    // The strings go to `strings`, the file's own table.
    constructor(strings: StringTable) {
        this.strings = strings;
    }

    get count(): i32 {
        return <i32>this.n;
    }

    intern(v: Value): u32 {
        const one = new BinWriter(32);
        one.u8(<u32>v.kind);
        const k = v.kind;
        if (k == ValueKind.Bool) {
            one.u8(v.b ? 1 : 0);
        } else if (k == ValueKind.Int) {
            one.i64(v.i);
        } else if (k == ValueKind.Float) {
            one.f64(v.f);
        } else if (isStringKind(k)) {
            one.u32(this.strings.intern(v.s));
        } else if (isNumbersKind(k)) {
            one.u32(<u32>v.n.length);
            for (let i = 0; i < v.n.length; i++) one.f64(v.n[i]);
        } else if (k == ValueKind.Array) {
            const idx = new Array<u32>();
            for (let i = 0; i < v.items.length; i++) idx.push(this.intern(v.items[i]));
            one.u32(<u32>idx.length);
            for (let i = 0; i < idx.length; i++) one.u32(idx[i]);
        } else if (k == ValueKind.Dictionary) {
            const pairs = new Array<u32>();
            const count = min<i32>(v.keys.length, v.items.length);
            for (let i = 0; i < count; i++) {
                pairs.push(this.intern(v.keys[i]));
                pairs.push(this.intern(v.items[i]));
            }
            one.u32(<u32>count);
            for (let i = 0; i < pairs.length; i++) one.u32(pairs[i]);
        }
        // (Nil: the tag alone)
        const bytes = one.view();
        const parts = new Array<string>();
        for (let i = 0; i < bytes.length; i++) parts.push(hex2(bytes[i]));
        const key = parts.join("");
        if (this.keys.has(key)) return this.keys.get(key);
        const index = this.n++;
        this.keys.set(key, index);
        this.entries.bytes(bytes);
        return index;
    }

    write(w: BinWriter): void {
        w.u32(this.n);
        w.u32(<u32>this.entries.length);
        w.bytes(this.entries.view());
    }
}

// The values `ValueTable.write` wrote, decoded with the file's `strings`
// (null, with `r` failed, when the table is damaged).
export function readValueTable(r: BinReader, strings: Array<string>): Array<Value>? {
    const n = r.count(1);
    const size = <i32>r.u32();
    if (r.failed) return null;
    if (size > r.remaining()) {
        r.fail("the values table (" + size.toString() + " bytes) runs past the end");
        return null;
    }
    const end = r.pos + size;
    const out = new Array<Value>();
    for (let i = 0; i < n && !r.failed; i++) out.push(readValue(r, strings, out));
    if (r.failed) return null;
    if (r.pos != end) {
        r.fail("the values table's entries do not fill its " + size.toString() + " bytes");
        return null;
    }
    return out;
}

// An index to an entry already read.
function earlier(r: BinReader, done: Array<Value>): Value {
    const i = r.u32();
    if (r.failed) return Value.nil();
    if (i >= <u32>done.length) {
        r.fail("a value names value " + i.toString() + ", which is not before it");
        return Value.nil();
    }
    return done[<i32>i];
}

function readValue(r: BinReader, strings: Array<string>, done: Array<Value>): Value {
    const tag = <i32>r.u8();
    if (r.failed) return Value.nil();
    if (tag > LAST_KIND) {
        r.fail("an unknown value kind (" + tag.toString() + ")");
        return Value.nil();
    }
    const k = <ValueKind>tag;
    if (k == ValueKind.Nil) return Value.nil();
    if (k == ValueKind.Bool) {
        const b = r.u8();
        if (b > 1) r.fail("a bool that is neither 0 nor 1");
        return Value.bool(b == 1);
    }
    if (k == ValueKind.Int) return Value.int(r.i64());
    if (k == ValueKind.Float) return Value.float(r.f64());
    if (isStringKind(k)) {
        const v = new Value(k);
        v.s = stringAt(r, strings, r.u32());
        return v;
    }
    if (isNumbersKind(k)) {
        const n = r.count(8);
        if (k == ValueKind.PackedVector3Array && n % 3 != 0) {
            r.fail("a PackedVector3Array of " + n.toString() + " numbers, not three a point");
            return Value.nil();
        }
        if (k == ValueKind.PackedColorArray && n % 4 != 0) {
            r.fail("a PackedColorArray of " + n.toString() + " numbers, not four a colour");
            return Value.nil();
        }
        if (k == ValueKind.PackedVector2Array && n % 2 != 0) {
            r.fail("a PackedVector2Array of " + n.toString() + " numbers, not two a point");
            return Value.nil();
        }
        const nums = new Array<f64>(n);
        for (let i = 0; i < n; i++) nums[i] = r.f64();
        if (k == ValueKind.PackedInt32Array) {
            for (let i = 0; i < n; i++) {
                const x = nums[i];
                if (x != Math.floor(x) || x < <f64>i32.MIN_VALUE || x > <f64>i32.MAX_VALUE) {
                    r.fail("a PackedInt32Array holding " + x.toString() + ", not a 32-bit integer");
                    return Value.nil();
                }
            }
        }
        const v = new Value(k);
        v.n = nums;
        return v;
    }
    if (k == ValueKind.Array) {
        const n = r.count(4);
        const items = new Array<Value>();
        for (let i = 0; i < n; i++) items.push(earlier(r, done));
        return Value.array(items);
    }
    if (k == ValueKind.Dictionary) {
        const n = r.count(8);
        const keys = new Array<Value>();
        const items = new Array<Value>();
        for (let i = 0; i < n; i++) {
            keys.push(earlier(r, done));
            items.push(earlier(r, done));
        }
        return Value.dictionary(keys, items);
    }
    r.fail("a value kind this version cannot decode (" + tag.toString() + ")");
    return Value.nil();
}

// The value at `i` of `values` (nil and `r` failed when out of range).
export function valueAt(r: BinReader, values: Array<Value>, i: u32): Value {
    if (i >= <u32>values.length) {
        r.fail("a value index (" + i.toString() + ") past the table (" + values.length.toString() + ")");
        return Value.nil();
    }
    return values[<i32>i];
}
