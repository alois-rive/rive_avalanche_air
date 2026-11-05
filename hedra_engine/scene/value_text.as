// The text form of a Value (value.as): Godot's variant literal syntax, as
// docs/formats/RSCN.md ("Values") specifies it, parsed exactly and printed
// canonically, so that print(parse(print(v))) == print(v) byte for byte and
// parse(print(v)).equals(v) for every value.
//
// Parsing knows nothing about files: an error gives the UTF-16 offset in the
// text where it is, and the .rscn reader maps that offset to a line and
// column (XmlNode.positionAt / XmlAttr.positionAt).
//
import { Result, StringBuilder, f64ToI64, i64FitsI32 } from "../base/util";
import { displayF64 } from "../base/fmt";
import { parseF64, parseI64 } from "../base/parse";
import { Value, ValueKind, componentCount } from "./value";

// The outcome of parseValueText: the value, or where and why it failed.
export class ValueParse {
    ok: bool = false;
    value: Value = Value.nil();
    // The UTF-16 offset in the text of the offending character (the text's
    // length for an unexpected end).
    errOffset: i32 = 0;
    // What is wrong, e.g. "Vector3 takes 3 numbers, found 2" (no position).
    errMessage: string = "";
    // How to fix it, when the reader knows (null otherwise).
    errHint: string? = null;
}

// Arrays and dictionaries nest at most this deep: a hostile file cannot
// exhaust the stack of the recursive reader below.
const MAX_DEPTH: i32 = 64;

function isSpace(c: i32): bool {
    return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
}

function isDigit(c: i32): bool {
    return c >= 48 && c <= 57;
}

function isWordStart(c: i32): bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
}

function isWordChar(c: i32): bool {
    return isWordStart(c) || isDigit(c);
}

function hexValue(c: i32): i32 {
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 97 && c <= 102) return c - 87;
    if (c >= 65 && c <= 70) return c - 55;
    return -1;
}

// The constructors whose arguments are numbers, and how many (Color takes
// 3 or 4: see numericCtor).
function isNumericCtor(name: string): bool {
    return name == "Vector2" || name == "Vector2i" || name == "Vector3" || name == "Vector3i" || name == "Vector4"
        || name == "Color" || name == "Quaternion" || name == "Basis" || name == "Transform3D";
}

function numericKind(name: string): ValueKind {
    if (name == "Vector2") return ValueKind.Vector2;
    if (name == "Vector2i") return ValueKind.Vector2i;
    if (name == "Vector3") return ValueKind.Vector3;
    if (name == "Vector3i") return ValueKind.Vector3i;
    if (name == "Vector4") return ValueKind.Vector4;
    if (name == "Color") return ValueKind.Color;
    if (name == "Quaternion") return ValueKind.Quaternion;
    if (name == "Basis") return ValueKind.Basis;
    return ValueKind.Transform3D;
}

// The constructors that take one string.
function isStringCtor(name: string): bool {
    return name == "NodePath" || name == "ExtResource" || name == "SubResource" || name == "StringName";
}

// A number token: where it is in the text, whether it is an integer (no
// `.`, no exponent, not inf or nan), and its value when the scan could
// compute it exactly. The reader keeps one and fills it for each number, so
// that reading a number allocates nothing: a MultiMesh's buffer is 160,000
// of them in scale/forest.rscn, and a substring, a Result and parseF64's
// bignums for each made that file 3.4 s and 360 MB to read (milestone 13).
class NumberToken {
    start: i32 = 0;
    end: i32 = 0;
    isInt: bool = false;
    // `fast`: `value` is the number, exactly what parseF64 (for a float) or
    // parseI64 (for an integer, in `int`) gives for the text.
    fast: bool = false;
    value: f64 = 0;
    int: i64 = 0;
}

// 10^0 to 10^22: the powers of ten a double holds exactly (5^22 < 2^53).
const POW10: StaticArray<f64> = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20,
    1e21, 1e22,
];

// 2^53: every integer up to it is a double exactly.
const EXACT_INT: u64 = 9007199254740992;

class ValueReader {
    s: string;
    n: i32;
    i: i32 = 0;
    depth: i32 = 0;
    errAt: i32 = -1;
    errMessage: string = "";
    errHint: string? = null;
    // The number being read (numberToken): one for the whole text.
    token: NumberToken = new NumberToken();

    constructor(s: string) {
        this.s = s;
        this.n = s.length;
    }

    c(k: i32): i32 {
        return k < this.n ? <i32>this.s.charCodeAt(k) : -1;
    }

    // Keeps the first error (the innermost call reports it first) and
    // returns null, so that every step can `return this.fail(...)`.
    fail(at: i32, message: string, hint: string? = null): Value? {
        if (this.errAt < 0) {
            this.errAt = at;
            this.errMessage = message;
            this.errHint = hint;
        }
        return null;
    }

    failed(): bool {
        return this.errAt >= 0;
    }

    skipSpace(): void {
        while (this.i < this.n && isSpace(this.c(this.i))) this.i++;
    }

    // What is at `k`, for messages: "'x'" or "the end of the text".
    found(k: i32): string {
        if (k >= this.n) return "the end of the text";
        return "'" + String.fromCodePoint(this.s.codePointAt(k)) + "'";
    }

    // Whether the word `w` is at `k`, not followed by a word character.
    hasWord(k: i32, w: string): bool {
        if (k + w.length > this.n) return false;
        for (let j = 0; j < w.length; j++) if (this.s.charCodeAt(k + j) != w.charCodeAt(j)) return false;
        return !isWordChar(this.c(k + w.length));
    }

    startsNumber(k: i32): bool {
        const c = this.c(k);
        return c == 45 || c == 46 || isDigit(c) || this.hasWord(k, "inf") || this.hasWord(k, "nan");
    }

    value(): Value? {
        this.skipSpace();
        const at = this.i;
        const c = this.c(at);
        if (c < 0) return this.fail(at, "expected a value, found the end of the text");
        if (c == 34) {
            const s = this.string();
            return s == null ? null : Value.str(s);
        }
        if (c == 38 || c == 94) {
            // &"name" is a StringName, ^"path" a NodePath.
            this.i++;
            this.skipSpace();
            if (this.c(this.i) != 34) return this.fail(this.i, "expected a string after '" + String.fromCharCode(c) + "', found " + this.found(this.i));
            const s = this.string();
            if (s == null) return null;
            return c == 38 ? Value.stringName(s) : Value.nodePath(s);
        }
        if (c == 91) return this.array();
        if (c == 123) return this.dictionary();
        if (this.startsNumber(at)) return this.number();
        if (isWordStart(c)) return this.word();
        return this.fail(at, "expected a value, found " + this.found(at));
    }

    // A standalone number: an Int (i64) or a Float.
    number(): Value? {
        const at = this.i;
        const t = this.numberToken();
        if (t == null) return null;
        if (t.isInt) {
            if (t.fast) return Value.int(t.int);
            const text = this.tokenText(t);
            const r = parseI64(text);
            if (!r.ok) return this.fail(at, "integer " + text + " does not fit in 64 bits");
            return Value.int(r.value);
        }
        return Value.float(this.floatOf(t));
    }

    tokenText(t: NumberToken): string {
        return this.s.substring(t.start, t.end);
    }

    floatOf(t: NumberToken): f64 {
        if (t.fast) return t.value;
        // The grammar above is a subset of parseF64's, so this cannot fail;
        // parseF64 rounds correctly where parseFloat does not.
        const r = parseF64(this.tokenText(t));
        return r.ok ? r.value : NaN;
    }

    // `-`? digits [. digits] [exponent], `.5`, `5.`, `inf`, `-inf`, `nan`.
    //
    // While scanning it gathers the significant digits into an integer w and
    // the power of ten e the text scales it by. When w <= 2^53 and |e| <=
    // 22, w and 10^|e| are both doubles exactly, so w * 10^e (or w / 10^-e)
    // is one correctly rounded operation (Clinger's fast path): the same
    // double parseF64's exact bignum arithmetic gives, bit for bit. Every
    // number the writer prints with up to 15 significant digits and a
    // small exponent takes it; longer ones (up to 17 digits of a shortest
    // form) and large exponents go to parseF64 through a substring. An
    // integer of up to 18 digits is its value at once.
    numberToken(): NumberToken? {
        const start = this.i;
        const t = this.token;
        t.start = start;
        t.isInt = false;
        t.fast = false;
        if (this.hasWord(start, "nan")) {
            this.i += 3;
            t.end = this.i;
            t.fast = true;
            t.value = NaN;
            return t;
        }
        let k = start;
        const neg = this.c(k) == 45;
        if (neg) k++;
        if (this.hasWord(k, "inf")) {
            this.i = k + 3;
            t.end = this.i;
            t.fast = true;
            t.value = neg ? -Infinity : Infinity;
            return t;
        }
        let digits = 0;
        // The significant digits (leading zeros skipped), how many, and the
        // power of ten they are scaled by.
        let w: u64 = 0;
        let sig = 0;
        let e10 = 0;
        let c = this.c(k);
        while (isDigit(c)) {
            if (w != 0 || c != 48) {
                if (sig < 19) w = w * 10 + <u64>(c - 48);
                else e10++;
                sig++;
            }
            k++;
            digits++;
            c = this.c(k);
        }
        let dot = false;
        if (c == 46) {
            dot = true;
            k++;
            c = this.c(k);
            while (isDigit(c)) {
                if (w != 0 || c != 48) {
                    if (sig < 19) {
                        w = w * 10 + <u64>(c - 48);
                        e10--;
                    }
                    sig++;
                } else e10--;
                k++;
                digits++;
                c = this.c(k);
            }
        }
        let exp = false;
        if (digits > 0 && (c == 101 || c == 69)) {
            let j = k + 1;
            let eneg = false;
            if (this.c(j) == 43 || this.c(j) == 45) {
                eneg = this.c(j) == 45;
                j++;
            }
            if (isDigit(this.c(j))) {
                // Saturated: past 10^6 only "huge" matters, and parseF64 has
                // the last word on anything outside the fast path.
                let ev = 0;
                while (isDigit(this.c(j))) {
                    if (ev < 1000000) ev = ev * 10 + (this.c(j) - 48);
                    j++;
                }
                k = j;
                exp = true;
                e10 += eneg ? -ev : ev;
            }
        }
        // `1.2.3`, `12abc`, `1e`, a lone `-` or `.`: one bad token, named
        // whole in the message.
        if (digits == 0 || isWordChar(this.c(k)) || this.c(k) == 46) {
            let e = k;
            while (isWordChar(this.c(e)) || this.c(e) == 46) e++;
            if (e == start) e = start + 1;
            return this.failToken(start, "invalid number '" + this.s.substring(start, e) + "'");
        }
        this.i = k;
        t.end = k;
        t.isInt = !dot && !exp;
        if (t.isInt) {
            // Up to 18 digits cannot overflow an i64, and the i64 to f64
            // conversion rounds to nearest, ties to even, as parseF64 does
            // (the same number in a float context: Vector3(1, 2, 3)).
            if (sig <= 18) {
                t.fast = true;
                t.int = neg ? -(<i64>w) : <i64>w;
                t.value = neg ? -(<f64>w) : <f64>w;
            }
            return t;
        }
        if (w == 0) {
            // Every zero, whatever its exponent ("0e999" is 0 to parseF64).
            t.fast = true;
            t.value = neg ? -0.0 : 0.0;
        } else if (sig <= 19 && w <= EXACT_INT && e10 >= -22 && e10 <= 22) {
            const m = <f64>w;
            const v = e10 >= 0 ? m * unchecked(POW10[e10]) : m / unchecked(POW10[-e10]);
            t.fast = true;
            t.value = neg ? -v : v;
        }
        return t;
    }

    failToken(at: i32, message: string): NumberToken? {
        this.fail(at, message);
        return null;
    }

    // A quoted string, at its `"`. Null on error (recorded).
    string(): string? {
        const start = this.i;
        // Most strings (a resource id, a node path) hold no escape: they
        // are their text, without a builder.
        let at = start + 1;
        while (at < this.n) {
            const c = <i32>this.s.charCodeAt(at);
            if (c == 34) {
                this.i = at + 1;
                return this.s.substring(start + 1, at);
            }
            if (c == 92 || (c < 0x20 && c != 0x09)) break;
            at++;
        }
        this.i++;
        const out = new StringBuilder();
        let from = this.i;
        while (true) {
            const k = this.i;
            const c = this.c(k);
            if (c < 0) {
                this.fail(start, "unterminated string");
                return null;
            }
            if (c == 34) {
                out.push(this.s.substring(from, k));
                this.i = k + 1;
                return out.toString();
            }
            if (c < 0x20 && c != 0x09) {
                this.fail(k, "a string cannot hold " + codeName(c) + " as it is: write it as an escape");
                return null;
            }
            if (c != 92) {
                this.i++;
                continue;
            }
            out.push(this.s.substring(from, k));
            const e = this.c(k + 1);
            this.i = k + 2;
            if (e == 34) out.push("\"");
            else if (e == 92) out.push("\\");
            else if (e == 47) out.push("/");
            else if (e == 110) out.push("\n");
            else if (e == 116) out.push("\t");
            else if (e == 114) out.push("\r");
            else if (e == 98) out.push("\u0008");
            else if (e == 102) out.push("\u000C");
            else if (e == 117) {
                const hi = this.hex(k + 2, 4);
                if (hi < 0) {
                    this.fail(k, "\\u takes 4 hex digits");
                    return null;
                }
                this.i = k + 6;
                if (hi >= 0xDC00 && hi <= 0xDFFF) {
                    this.fail(k, "unpaired surrogate " + this.s.substring(k, k + 6));
                    return null;
                }
                if (hi >= 0xD800 && hi <= 0xDBFF) {
                    // A pair of \u escapes is one character past the BMP
                    // (JSON's way); anything else is a lone half.
                    const lo = this.c(k + 6) == 92 && this.c(k + 7) == 117 ? this.hex(k + 8, 4) : -1;
                    if (lo < 0xDC00 || lo > 0xDFFF) {
                        this.fail(k, "unpaired surrogate " + this.s.substring(k, k + 6));
                        return null;
                    }
                    this.i = k + 12;
                    out.push(String.fromCodePoint(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)));
                } else out.push(String.fromCharCode(hi));
            } else if (e == 85) {
                const cp = this.hex(k + 2, 6);
                if (cp < 0) {
                    this.fail(k, "\\U takes 6 hex digits");
                    return null;
                }
                if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
                    this.fail(k, this.s.substring(k, k + 8) + " is not a Unicode character");
                    return null;
                }
                this.i = k + 8;
                out.push(String.fromCodePoint(cp));
            } else if (e < 0) {
                this.fail(start, "unterminated string");
                return null;
            } else {
                this.fail(k, "unknown escape \\" + String.fromCodePoint(this.s.codePointAt(k + 1)));
                return null;
            }
            from = this.i;
        }
    }

    // `count` hex digits at `k` as a number, or -1.
    hex(k: i32, count: i32): i32 {
        let v = 0;
        for (let j = 0; j < count; j++) {
            const d = hexValue(this.c(k + j));
            if (d < 0) return -1;
            v = (v << 4) | d;
        }
        return v;
    }

    enter(at: i32): bool {
        this.depth++;
        if (this.depth > MAX_DEPTH) {
            this.fail(at, "values nest deeper than " + MAX_DEPTH.toString() + " levels");
            return false;
        }
        return true;
    }

    array(): Value? {
        const at = this.i;
        if (!this.enter(at)) return null;
        this.i++;
        const items = new Array<Value>();
        this.skipSpace();
        if (this.c(this.i) == 93) {
            this.i++;
            this.depth--;
            return Value.array(items);
        }
        while (true) {
            const v = this.value();
            if (v == null) return null;
            items.push(v);
            this.skipSpace();
            const c = this.c(this.i);
            if (c == 44) {
                this.i++;
                this.skipSpace();
                // A trailing comma is allowed.
                if (this.c(this.i) == 93) {
                    this.i++;
                    break;
                }
                continue;
            }
            if (c == 93) {
                this.i++;
                break;
            }
            return this.fail(this.i, "expected ',' or ']' in the array, found " + this.found(this.i));
        }
        this.depth--;
        return Value.array(items);
    }

    dictionary(): Value? {
        const at = this.i;
        if (!this.enter(at)) return null;
        this.i++;
        const keys = new Array<Value>();
        const items = new Array<Value>();
        this.skipSpace();
        if (this.c(this.i) == 125) {
            this.i++;
            this.depth--;
            return Value.dictionary(keys, items);
        }
        while (true) {
            const k = this.value();
            if (k == null) return null;
            this.skipSpace();
            if (this.c(this.i) != 58) return this.fail(this.i, "expected ':' after a dictionary key, found " + this.found(this.i));
            this.i++;
            const v = this.value();
            if (v == null) return null;
            keys.push(k);
            items.push(v);
            this.skipSpace();
            const c = this.c(this.i);
            if (c == 44) {
                this.i++;
                this.skipSpace();
                if (this.c(this.i) == 125) {
                    this.i++;
                    break;
                }
                continue;
            }
            if (c == 125) {
                this.i++;
                break;
            }
            return this.fail(this.i, "expected ',' or '}' in the dictionary, found " + this.found(this.i));
        }
        this.depth--;
        return Value.dictionary(keys, items);
    }

    // null, true, false, inf, nan, or a constructor.
    word(): Value? {
        const at = this.i;
        let k = at;
        while (isWordChar(this.c(k))) k++;
        const name = this.s.substring(at, k);
        this.i = k;
        if (name == "null") return Value.nil();
        if (name == "true") return Value.bool(true);
        if (name == "false") return Value.bool(false);
        this.skipSpace();
        let open = this.i;
        const c = this.c(open);
        let typed = false;
        if (c == 91) {
            typed = true;
            // A typed constructor, Array[int]([1, 2]): not in format 1, kept
            // whole as an Unknown.
            const close = this.matching(open, 91, 93);
            if (close < 0) return this.fail(open, "'[' after " + name + " is not closed");
            this.i = close;
            this.skipSpace();
            open = this.i;
            if (this.c(open) != 40) return this.fail(open, "expected '(' after " + this.s.substring(at, close) + ", found " + this.found(open));
        } else if (c != 40) {
            return this.fail(at, "unknown word '" + name + "'");
        }
        if (!typed && isNumericCtor(name)) return this.numericCtor(name, at, open);
        if (!typed && name == "PackedFloat32Array") return this.packedFloats(open);
        if (!typed && name == "PackedVector3Array") return this.packedVector3s(at, open);
        if (!typed && name == "PackedColorArray") return this.packedColors(at, open);
        if (!typed && name == "PackedVector2Array") return this.packedVector2s(at, open);
        if (!typed && name == "PackedInt32Array") return this.packedInts(at, open);
        if (!typed && isStringCtor(name)) return this.stringCtor(name, at, open);
        const end = this.matching(open, 40, 41);
        if (end < 0) return this.fail(at, name + "( is not closed");
        this.i = end;
        return Value.unknown(this.s.substring(at, end));
    }

    // The index just after the bracket that closes the one at `open`
    // (strings skipped, so that a ")" inside one does not count), or -1.
    matching(open: i32, o: i32, cl: i32): i32 {
        let depth = 0;
        let k = open;
        while (k < this.n) {
            const c = this.c(k);
            if (c == 34) {
                k++;
                while (k < this.n && this.c(k) != 34) k += this.c(k) == 92 ? 2 : 1;
                if (k >= this.n) return -1;
            } else if (c == o) depth++;
            else if (c == cl) {
                depth--;
                if (depth == 0) return k + 1;
            }
            k++;
        }
        return -1;
    }

    numericCtor(name: string, at: i32, open: i32): Value? {
        const kind = numericKind(name);
        const ints = kind == ValueKind.Vector2i || kind == ValueKind.Vector3i;
        const nums = new Array<f64>();
        this.i = open + 1;
        this.skipSpace();
        if (this.c(this.i) == 41) this.i++;
        else {
            while (true) {
                this.skipSpace();
                const argAt = this.i;
                if (!this.startsNumber(argAt)) return this.fail(argAt, name + " takes numbers, found " + this.found(argAt));
                const t = this.numberToken();
                if (t == null) return null;
                if (ints) {
                    if (!t.isInt) return this.fail(argAt, name + " takes integers, found " + this.tokenText(t));
                    // Godot's integer vectors hold 32-bit integers.
                    const r = t.fast ? Result.okv<i64>(t.int) : parseI64(this.tokenText(t));
                    if (!r.ok || !i64FitsI32(r.value)) {
                        return this.fail(argAt, name + " takes 32-bit integers, found " + this.tokenText(t));
                    }
                    nums.push(<f64>r.value);
                } else nums.push(this.floatOf(t));
                this.skipSpace();
                const c = this.c(this.i);
                if (c == 44) {
                    this.i++;
                    continue;
                }
                if (c == 41) {
                    this.i++;
                    break;
                }
                return this.fail(this.i, "expected ',' or ')' in " + name + "(...), found " + this.found(this.i));
            }
        }
        if (kind == ValueKind.Color) {
            if (nums.length != 3 && nums.length != 4) return this.fail(at, "Color takes 3 or 4 numbers, found " + nums.length.toString());
            if (nums.length == 3) nums.push(1);
        } else {
            const want = componentCount(kind);
            if (nums.length != want) {
                return this.fail(at, name + " takes " + want.toString() + " numbers, found " + nums.length.toString());
            }
        }
        // (nums is this value's own: no copy)
        const v = new Value(kind);
        v.n = nums;
        return v;
    }

    // Milestone 31: PackedVector3Array(x, y, z, x, y, z, ...), Godot's
    // text of it: three numbers a point, flat, none included (a
    // ConvexPolygonShape3D's points, a ConcavePolygonShape3D's triangles).
    // A count that is not a multiple of 3 is refused at the name.
    packedVector3s(at: i32, open: i32): Value? {
        const v = this.packedFloats(open, "PackedVector3Array");
        if (v == null) return null;
        if (v.n.length % 3 != 0) {
            return this.fail(at, "PackedVector3Array takes three numbers a point, found " + v.n.length.toString()
                + " number" + (v.n.length == 1 ? "" : "s"), "write x, y, z for each point, all flat in one list");
        }
        v.kind = ValueKind.PackedVector3Array;
        return v;
    }

    // Milestone 35: PackedColorArray(r, g, b, a, r, g, b, a, ...), Godot's
    // text of it: four numbers a colour, flat, none included (a Gradient's
    // colors, a CPUParticles3D's emission_colors). A count that is not a
    // multiple of 4 is refused at the name.
    packedColors(at: i32, open: i32): Value? {
        const v = this.packedFloats(open, "PackedColorArray");
        if (v == null) return null;
        if (v.n.length % 4 != 0) {
            return this.fail(at, "PackedColorArray takes four numbers a colour, found " + v.n.length.toString()
                + " number" + (v.n.length == 1 ? "" : "s"), "write r, g, b, a for each colour, all flat in one list");
        }
        v.kind = ValueKind.PackedColorArray;
        return v;
    }

    // Milestone 37: PackedVector2Array(x, y, x, y, ...), Godot's text of
    // it: two numbers a point, flat, none included (a PolygonOccluder3D's
    // polygon). An odd count is refused at the name.
    packedVector2s(at: i32, open: i32): Value? {
        const v = this.packedFloats(open, "PackedVector2Array");
        if (v == null) return null;
        if (v.n.length % 2 != 0) {
            return this.fail(at, "PackedVector2Array takes two numbers a point, found " + v.n.length.toString()
                + " number" + (v.n.length == 1 ? "" : "s"), "write x, y for each point, all flat in one list");
        }
        v.kind = ValueKind.PackedVector2Array;
        return v;
    }

    // Milestone 37: PackedInt32Array(i, i, ...), Godot's text of it:
    // whole numbers within the i32 range, none included (an
    // ArrayOccluder3D's indices). A fraction or a number out of range is
    // refused at the name.
    packedInts(at: i32, open: i32): Value? {
        const v = this.packedFloats(open, "PackedInt32Array");
        if (v == null) return null;
        for (let k = 0; k < v.n.length; k++) {
            const x = v.n[k];
            if (x != Math.floor(x) || x < <f64>i32.MIN_VALUE || x > <f64>i32.MAX_VALUE) {
                return this.fail(at, "PackedInt32Array takes 32-bit integers, found " + printNumber(x),
                    "write whole numbers from -2147483648 to 2147483647");
            }
        }
        v.kind = ValueKind.PackedInt32Array;
        return v;
    }

    // PackedFloat32Array(n, n, ...): any count of numbers, none included
    // (milestone 13: a MultiMesh's buffer, 12 to 20 numbers an instance).
    // Integers and floats alike, as Godot writes them. (`name`: the
    // constructor the messages name; milestone 31 reads PackedVector3Array
    // with it too.)
    packedFloats(open: i32, name: string = "PackedFloat32Array"): Value? {
        const nums = new Array<f64>();
        this.i = open + 1;
        this.skipSpace();
        if (this.c(this.i) == 41) {
            this.i++;
            return Value.packedFloats(nums);
        }
        while (true) {
            this.skipSpace();
            const argAt = this.i;
            if (!this.startsNumber(argAt)) {
                return this.fail(argAt, name + " takes numbers, found " + this.found(argAt));
            }
            const t = this.numberToken();
            if (t == null) return null;
            nums.push(this.floatOf(t));
            this.skipSpace();
            const c = this.c(this.i);
            if (c == 44) {
                this.i++;
                continue;
            }
            if (c == 41) {
                this.i++;
                break;
            }
            return this.fail(this.i, "expected ',' or ')' in " + name + "(...), found " + this.found(this.i));
        }
        const v = new Value(ValueKind.PackedFloat32Array);
        v.n = nums;
        return v;
    }

    stringCtor(name: string, at: i32, open: i32): Value? {
        this.i = open + 1;
        this.skipSpace();
        if (this.c(this.i) != 34) return this.fail(this.i, name + " takes one string, found " + this.found(this.i));
        const s = this.string();
        if (s == null) return null;
        this.skipSpace();
        if (this.c(this.i) != 41) return this.fail(this.i, name + " takes one string, found " + this.found(this.i));
        this.i++;
        if (name == "NodePath") return Value.nodePath(s);
        if (name == "StringName") return Value.stringName(s);
        if (name == "ExtResource") return Value.extResource(s);
        return Value.subResource(s);
    }
}

// "U+000A" for messages.
function codeName(c: i32): string {
    let h = c.toString(16).toUpperCase();
    while (h.length < 4) h = "0" + h;
    return "U+" + h;
}

// Parses one value; leading and trailing whitespace is allowed, anything
// else after the value is an error.
export function parseValueText(text: string): ValueParse {
    const p = new ValueParse();
    const r = new ValueReader(text);
    const v = r.value();
    if (v != null && !r.failed()) {
        r.skipSpace();
        if (r.i < r.n) r.fail(r.i, "unexpected text after the value");
    }
    if (r.failed() || v == null) {
        p.errOffset = r.errAt < 0 ? 0 : r.errAt;
        p.errMessage = r.errMessage;
        p.errHint = r.errHint;
        return p;
    }
    p.ok = true;
    p.value = v;
    return p;
}

// parseValueText as a Result: the error is "at offset <n>: <message>".
// (For code and tests that have no file; the reader uses parseValueText.)
export function parseValue(text: string): Result<Value> {
    const p = parseValueText(text);
    if (p.ok) return Result.okv<Value>(p.value);
    return Result.fail<Value>("at offset " + p.errOffset.toString() + ": " + p.errMessage);
}

// The canonical text of a value (one line, no trailing newline; an Unknown
// is its source text, which may span lines).
export function printValue(v: Value): string {
    const out = new StringBuilder();
    printInto(v, out);
    return out.toString();
}

function printInto(v: Value, out: StringBuilder): void {
    switch (v.kind) {
        case ValueKind.Nil:
            out.push("null");
            return;
        case ValueKind.Bool:
            out.push(v.b ? "true" : "false");
            return;
        case ValueKind.Int:
            out.push(v.i.toString());
            return;
        case ValueKind.Float:
            out.push(printFloat(v.f));
            return;
        case ValueKind.String:
            out.push(quoteString(v.s));
            return;
        case ValueKind.StringName:
            out.push("&").push(quoteString(v.s));
            return;
        case ValueKind.NodePath:
            out.push("NodePath(").push(quoteString(v.s)).push(")");
            return;
        case ValueKind.ExtResource:
            out.push("ExtResource(").push(quoteString(v.s)).push(")");
            return;
        case ValueKind.SubResource:
            out.push("SubResource(").push(quoteString(v.s)).push(")");
            return;
        case ValueKind.Unknown:
            out.push(v.s);
            return;
        case ValueKind.Array: {
            out.push("[");
            for (let k = 0; k < v.items.length; k++) {
                if (k > 0) out.push(", ");
                printInto(v.items[k], out);
            }
            out.push("]");
            return;
        }
        case ValueKind.PackedFloat32Array:
        case ValueKind.PackedVector3Array:
        case ValueKind.PackedColorArray:
        case ValueKind.PackedVector2Array:
        case ValueKind.PackedInt32Array: {
            out.push(v.kind == ValueKind.PackedFloat32Array ? "PackedFloat32Array("
                : v.kind == ValueKind.PackedVector3Array ? "PackedVector3Array("
                : v.kind == ValueKind.PackedColorArray ? "PackedColorArray("
                : v.kind == ValueKind.PackedVector2Array ? "PackedVector2Array(" : "PackedInt32Array(");
            for (let k = 0; k < v.n.length; k++) {
                if (k > 0) out.push(", ");
                out.push(printNumber(v.n[k]));
            }
            out.push(")");
            return;
        }
        case ValueKind.Dictionary: {
            out.push("{");
            for (let k = 0; k < v.keys.length; k++) {
                if (k > 0) out.push(", ");
                printInto(v.keys[k], out);
                out.push(": ");
                if (k < v.items.length) printInto(v.items[k], out);
                else out.push("null");
            }
            out.push("}");
            return;
        }
        default:
            break;
    }
    // The fixed-size kinds. A value built in code with too few numbers
    // prints the missing ones as 0 (a Color's alpha as 1), so that what is
    // written always reads back.
    const count = componentCount(v.kind);
    const ints = v.kind == ValueKind.Vector2i || v.kind == ValueKind.Vector3i;
    out.push(v.kindName()).push("(");
    for (let k = 0; k < count; k++) {
        if (k > 0) out.push(", ");
        const x: f64 = k < v.n.length ? v.n[k] : (v.kind == ValueKind.Color && k == 3 ? 1 : 0);
        out.push(ints ? f64ToI64(x).toString() : printNumber(x));
    }
    out.push(")");
}

// A float as a standalone value: the shortest text that parses back to the
// same f64, with ".0" when it would otherwise read as an int; "inf",
// "-inf", "nan".
export function printFloat(x: f64): string {
    const t = printNumber(x);
    if (!isFinite(x)) return t;
    return t.indexOf(".") < 0 ? t + ".0" : t;
}

// A number inside a constructor (Vector3(0, 1, 0.5)): the shortest text
// that parses back to the same f64, no ".0" added; "inf", "-inf", "nan".
export function printNumber(x: f64): string {
    if (isNaN(x)) return "nan";
    if (!isFinite(x)) return x > 0 ? "inf" : "-inf";
    return displayF64(x);
}

// A string literal: double quotes, `"` `\` and control characters escaped
// (and U+FFFE, U+FFFF, which XML refuses as characters).
export function quoteString(s: string): string {
    const out = new StringBuilder();
    out.push("\"");
    let from = 0;
    const n = s.length;
    for (let k = 0; k < n; k++) {
        const c = s.charCodeAt(k);
        let e: string? = null;
        if (c == 34) e = "\\\"";
        else if (c == 92) e = "\\\\";
        else if (c == 10) e = "\\n";
        else if (c == 9) e = "\\t";
        else if (c == 13) e = "\\r";
        else if (c == 8) e = "\\b";
        else if (c == 12) e = "\\f";
        else if (c < 0x20 || c == 0x7F) e = "\\u00" + (c < 16 ? "0" : "") + c.toString(16);
        // U+FFFE and U+FFFF read from a \u escape, but XML cannot carry them
        // as characters: written literally, the file would not read back.
        else if (c == 0xFFFE || c == 0xFFFF) e = "\\u" + c.toString(16);
        if (e == null) continue;
        out.push(s.substring(from, k));
        out.push(e);
        from = k + 1;
    }
    out.push(s.substring(from));
    out.push("\"");
    return out.toString();
}
