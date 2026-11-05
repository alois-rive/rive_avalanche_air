// JSON: a Value tree, byte-stable writers and a parser.
//
//   JsonValue                 a kind tag + payload fields
//   JsonMap                   insertion order; insert keeps a key's slot,
//                             remove is a swap-remove (the last key takes its place)
//   JsonValue.fromU64/fromI64/fromI32/fromF64/fromF32/str/bool/nul
//                             constructors. fromF32(x) widens to f64, so 1.1f32
//                             is written 1.100000023841858: a Value stores every
//                             float as f64.
//   JsonValue.serializeF32(x) an f32 written with f32 digits (1.1f32 -> 1.1), for
//                             fields serialized straight to text.
//   v.toString()              compact text
//   v.toStringPretty()        2-space indent, "[]" / "{}" when empty
//   parseJson(s)              Result<JsonValue>; r.err reads like
//                             "expected `,` or `]` at line 1 column 5"
//   parseJsonBytes(b)         the same, and also rejects invalid UTF-8 in strings
//   v.idx("k"), v.get("k"), v.asF64() …  access
//
// Floats are written with shortest round-trip digits, plain decimal for
// decimal exponents -5..=15 (f32: -6..=12), otherwise "1e+16" / "1.5e-7"
// (see fmt.jsonF64).
//
// Numbers have three kinds: PosInt (u64), NegInt (i64 < 0) and
// Float (f64, always finite; a non-finite f64 becomes Null). F32 is an extra
// output-only kind for Serialize impls that write an f32 directly.

import { Result, ErrorValue, i64ToI32 } from "./util";
import { jsonF64, jsonF32, displayI64 } from "./fmt";

export enum JsonKind {
    Null,
    Bool,
    Number,
    String,
    Array,
    Object,
}

export enum JsonNumberKind {
    PosInt,
    NegInt,
    Float,
    F32,
}

// ---------------------------------------------------------------------------
// Map

// A JSON object that keeps its keys in insertion order.
export class JsonMap {
    private keyList: Array<string> = [];
    private valueList: Array<JsonValue> = [];
    private slots: Map<string, i32> = new Map<string, i32>();

    get length(): i32 {
        return this.keyList.length;
    }

    // Keys in order (a copy).
    keys(): Array<string> {
        return this.keyList.slice(0);
    }

    // Values in key order (a copy).
    values(): Array<JsonValue> {
        return this.valueList.slice(0);
    }

    keyAt(i: i32): string {
        return this.keyList[i];
    }

    valueAt(i: i32): JsonValue {
        return this.valueList[i];
    }

    has(key: string): bool {
        return this.slots.has(key);
    }

    get(key: string): JsonValue? {
        if (!this.slots.has(key)) return null;
        return this.valueList[this.slots.get(key)];
    }

    // Map::insert: a new key goes last; an existing key keeps its position
    // and gets the new value. Returns the previous value, or null.
    insert(key: string, value: JsonValue): JsonValue? {
        if (this.slots.has(key)) {
            const i = this.slots.get(key);
            const old = this.valueList[i];
            this.valueList[i] = value;
            return old;
        }
        this.slots.set(key, this.keyList.length);
        this.keyList.push(key);
        this.valueList.push(value);
        return null;
    }

    // Map::remove with preserve_order is IndexMap::swap_remove: the last entry
    // moves into the removed slot.
    remove(key: string): JsonValue? {
        if (!this.slots.has(key)) return null;
        const i = this.slots.get(key);
        const old = this.valueList[i];
        const last = this.keyList.length - 1;
        this.slots.delete(key);
        if (i != last) {
            const movedKey = this.keyList[last];
            this.keyList[i] = movedKey;
            this.valueList[i] = this.valueList[last];
            this.slots.set(movedKey, i);
        }
        this.keyList.pop();
        this.valueList.pop();
        return old;
    }

    // Map::shift_remove: removes and keeps the order of the others.
    shiftRemove(key: string): JsonValue? {
        if (!this.slots.has(key)) return null;
        const i = this.slots.get(key);
        const old = this.valueList[i];
        this.slots.delete(key);
        this.keyList.splice(i, 1);
        this.valueList.splice(i, 1);
        for (let j = i; j < this.keyList.length; j++) this.slots.set(this.keyList[j], j);
        return old;
    }

    // IndexMap equality: same entries, order ignored.
    equals(other: JsonMap): bool {
        if (this.length != other.length) return false;
        for (let i = 0; i < this.keyList.length; i++) {
            const o = other.get(this.keyList[i]);
            if (o == null) return false;
            if (!this.valueList[i].equals(o)) return false;
        }
        return true;
    }
}

// ---------------------------------------------------------------------------
// Value

export class JsonValue {
    kind: JsonKind = JsonKind.Null;
    boolValue: bool = false;
    numKind: JsonNumberKind = JsonNumberKind.PosInt;
    u: u64 = 0; // PosInt
    i: i64 = 0; // NegInt
    f: f64 = 0; // Float, F32 (widened)
    str: string = "";
    items: Array<JsonValue>? = null;
    map: JsonMap? = null;

    // A null value.
    static nul(): JsonValue {
        return new JsonValue();
    }

    // A boolean value.
    static bool(b: bool): JsonValue {
        const v = new JsonValue();
        v.kind = JsonKind.Bool;
        v.boolValue = b;
        return v;
    }

    // A string value.
    static str(s: string): JsonValue {
        const v = new JsonValue();
        v.kind = JsonKind.String;
        v.str = s;
        return v;
    }

    // A u64 (or any smaller unsigned integer).
    static fromU64(n: u64): JsonValue {
        const v = new JsonValue();
        v.kind = JsonKind.Number;
        v.numKind = JsonNumberKind.PosInt;
        v.u = n;
        return v;
    }

    // An i64 (or any smaller signed integer): non-negative values are PosInt.
    static fromI64(n: i64): JsonValue {
        if (n >= 0) return JsonValue.fromU64(<u64>n);
        const v = new JsonValue();
        v.kind = JsonKind.Number;
        v.numKind = JsonNumberKind.NegInt;
        v.i = n;
        return v;
    }

    static fromI32(n: i32): JsonValue {
        return JsonValue.fromI64(<i64>n);
    }

    // An f64: NaN and infinities become Null.
    static fromF64(x: f64): JsonValue {
        if (!isFinite(x)) return JsonValue.nul();
        const v = new JsonValue();
        v.kind = JsonKind.Number;
        v.numKind = JsonNumberKind.Float;
        v.f = x;
        return v;
    }

    // An f32, widened to f64 (1.1f32 -> 1.100000023841858).
    static fromF32(x: f32): JsonValue {
        return JsonValue.fromF64(<f64>x);
    }

    // An f32 field written straight to text: shortest f32 digits
    // (1.1f32 -> 1.1), `null` for NaN and infinities.
    static serializeF32(x: f32): JsonValue {
        const v = new JsonValue();
        v.kind = JsonKind.Number;
        v.numKind = JsonNumberKind.F32;
        v.f = <f64>x;
        return v;
    }

    // An array value.
    static array(items: Array<JsonValue> = []): JsonValue {
        const v = new JsonValue();
        v.kind = JsonKind.Array;
        v.items = items;
        return v;
    }

    // An object value.
    static object(map: JsonMap? = null): JsonValue {
        const v = new JsonValue();
        v.kind = JsonKind.Object;
        v.map = map != null ? map : new JsonMap();
        return v;
    }

    // An array value of strings.
    static strArray(xs: Array<string>): JsonValue {
        const items: Array<JsonValue> = [];
        for (let i = 0; i < xs.length; i++) items.push(JsonValue.str(xs[i]));
        return JsonValue.array(items);
    }

    // ---- predicates (Value::is_*)
    isNull(): bool { return this.kind == JsonKind.Null; }
    isBool(): bool { return this.kind == JsonKind.Bool; }
    isNumber(): bool { return this.kind == JsonKind.Number; }
    isString(): bool { return this.kind == JsonKind.String; }
    isArray(): bool { return this.kind == JsonKind.Array; }
    isObject(): bool { return this.kind == JsonKind.Object; }
    isU64(): bool { return this.kind == JsonKind.Number && this.numKind == JsonNumberKind.PosInt; }
    isI64(): bool {
        if (this.kind != JsonKind.Number) return false;
        if (this.numKind == JsonNumberKind.NegInt) return true;
        return this.numKind == JsonNumberKind.PosInt && this.u <= <u64>i64.MAX_VALUE;
    }
    isF64(): bool {
        return this.kind == JsonKind.Number
            && (this.numKind == JsonNumberKind.Float || this.numKind == JsonNumberKind.F32);
    }

    // ---- accessors; check the matching is* first where a missing value
    // must be told apart from the fallback.
    asBool(): bool { return this.kind == JsonKind.Bool && this.boolValue; }

    // Any number as f64; NaN when not a number.
    asF64(): f64 {
        if (this.kind != JsonKind.Number) return NaN;
        switch (this.numKind) {
            case JsonNumberKind.PosInt: return <f64>this.u;
            case JsonNumberKind.NegInt: return <f64>this.i;
            default: return this.f;
        }
    }

    // The value as i64; 0 when !isI64().
    asI64(): i64 {
        if (!this.isI64()) return 0;
        return this.numKind == JsonNumberKind.NegInt ? this.i : <i64>this.u;
    }

    // The value as u64; 0 when !isU64().
    asU64(): u64 {
        return this.isU64() ? this.u : 0;
    }

    // The string payload; null when not a string.
    asStr(): string? {
        return this.kind == JsonKind.String ? this.str : null;
    }

    asArray(): Array<JsonValue>? {
        return this.kind == JsonKind.Array ? this.items : null;
    }

    asObject(): JsonMap? {
        return this.kind == JsonKind.Object ? this.map : null;
    }

    // The member of an object; null otherwise.
    get(key: string): JsonValue? {
        if (this.kind != JsonKind.Object) return null;
        const m = this.map;
        if (m == null) return null;
        return m.get(key);
    }

    // An array element; null when out of range.
    at(index: i32): JsonValue? {
        if (this.kind != JsonKind.Array) return null;
        const a = this.items;
        if (a == null || index < 0 || index >= a.length) return null;
        return a[index];
    }

    // value["key"]: like get() but a fresh Null for a missing member.
    idx(key: string): JsonValue {
        const v = this.get(key);
        return v != null ? v : JsonValue.nul();
    }

    // value[i]
    idxAt(index: i32): JsonValue {
        const v = this.at(index);
        return v != null ? v : JsonValue.nul();
    }

    // ---- building
    // Appends to an array value.
    push(v: JsonValue): JsonValue {
        const a = this.items;
        if (this.kind == JsonKind.Array && a != null) a.push(v);
        return this;
    }

    // Map::insert on an object value; returns this for chaining.
    set(key: string, v: JsonValue): JsonValue {
        const m = this.map;
        if (this.kind == JsonKind.Object && m != null) m.insert(key, v);
        return this;
    }

    // Structural equality: PosInt(1) != Float(1.0); objects compare as maps.
    equals(o: JsonValue): bool {
        if (this.kind != o.kind) return false;
        switch (this.kind) {
            case JsonKind.Null: return true;
            case JsonKind.Bool: return this.boolValue == o.boolValue;
            case JsonKind.String: return this.str == o.str;
            case JsonKind.Number: {
                const a = this.numKind == JsonNumberKind.F32 ? JsonNumberKind.Float : this.numKind;
                const b = o.numKind == JsonNumberKind.F32 ? JsonNumberKind.Float : o.numKind;
                if (a != b) return false;
                if (a == JsonNumberKind.PosInt) return this.u == o.u;
                if (a == JsonNumberKind.NegInt) return this.i == o.i;
                return this.f == o.f;
            }
            case JsonKind.Array: {
                const x = this.items;
                const y = o.items;
                if (x == null || y == null) return x == y;
                if (x.length != y.length) return false;
                for (let i = 0; i < x.length; i++) {
                    if (!x[i].equals(y[i])) return false;
                }
                return true;
            }
            default: {
                const x = this.map;
                const y = o.map;
                if (x == null || y == null) return x == y;
                return x.equals(y);
            }
        }
    }

    // Compact text.
    toString(): string {
        const out: Array<string> = [];
        writeJson(this, out, false, 0);
        return out.join("");
    }

    // Pretty text, 2-space indent.
    toStringPretty(): string {
        const out: Array<string> = [];
        writeJson(this, out, true, 0);
        return out.join("");
    }
}

// ---------------------------------------------------------------------------
// Writer

const HEX = "0123456789abcdef";

// String escaping: `"` `\\` and the C0 controls (\b \t \n \f \r,
// others \u00XX with lower-case hex). Everything else, DEL and U+2028
// included, is written as is.
export function jsonQuote(s: string): string {
    const out: Array<string> = [];
    writeJsonStr(s, out);
    return out.join("");
}

function writeJsonStr(s: string, out: Array<string>): void {
    out.push("\"");
    const n = s.length;
    let run = 0;
    for (let i = 0; i < n; i++) {
        const c = s.charCodeAt(i);
        if (c >= 0x20 && c != 34 && c != 92) continue;
        if (i > run) out.push(s.substring(run, i));
        run = i + 1;
        switch (c) {
            case 34: out.push("\\\""); break;
            case 92: out.push("\\\\"); break;
            case 8: out.push("\\b"); break;
            case 9: out.push("\\t"); break;
            case 10: out.push("\\n"); break;
            case 12: out.push("\\f"); break;
            case 13: out.push("\\r"); break;
            default:
                out.push("\\u00" + HEX.charAt(c >> 4) + HEX.charAt(c & 15));
        }
    }
    if (run < n) out.push(run == 0 ? s : s.substring(run));
    out.push("\"");
}

// The JSON text of a number value.
export function jsonNumberText(v: JsonValue): string {
    switch (v.numKind) {
        case JsonNumberKind.PosInt: return v.u.toString();
        case JsonNumberKind.NegInt: return displayI64(v.i);
        case JsonNumberKind.F32: return jsonF32(<f32>v.f);
        default: return jsonF64(v.f);
    }
}

const INDENT_CACHE: Array<string> = [""];

function indentOf(level: i32): string {
    while (INDENT_CACHE.length <= level) INDENT_CACHE.push(INDENT_CACHE[INDENT_CACHE.length - 1] + "  ");
    return INDENT_CACHE[level];
}

// Compact or pretty (indent "  ") writer.
function writeJson(v: JsonValue, out: Array<string>, pretty: bool, level: i32): void {
    switch (v.kind) {
        case JsonKind.Null: out.push("null"); break;
        case JsonKind.Bool: out.push(v.boolValue ? "true" : "false"); break;
        case JsonKind.Number: out.push(jsonNumberText(v)); break;
        case JsonKind.String: writeJsonStr(v.str, out); break;
        case JsonKind.Array: {
            const items = v.items;
            if (items == null || items.length == 0) {
                out.push("[]");
                break;
            }
            out.push("[");
            for (let i = 0; i < items.length; i++) {
                if (pretty) {
                    out.push(i == 0 ? "\n" : ",\n");
                    out.push(indentOf(level + 1));
                } else if (i > 0) {
                    out.push(",");
                }
                writeJson(items[i], out, pretty, level + 1);
            }
            if (pretty) {
                out.push("\n");
                out.push(indentOf(level));
            }
            out.push("]");
            break;
        }
        default: {
            const m = v.map;
            if (m == null || m.length == 0) {
                out.push("{}");
                break;
            }
            out.push("{");
            for (let i = 0; i < m.length; i++) {
                if (pretty) {
                    out.push(i == 0 ? "\n" : ",\n");
                    out.push(indentOf(level + 1));
                } else if (i > 0) {
                    out.push(",");
                }
                writeJsonStr(m.keyAt(i), out);
                out.push(pretty ? ": " : ":");
                writeJson(m.valueAt(i), out, pretty, level + 1);
            }
            if (pretty) {
                out.push("\n");
                out.push(indentOf(level));
            }
            out.push("}");
        }
    }
}

// ---------------------------------------------------------------------------
// Parser

// The syntax errors a Value parse can raise.
export enum JsonErrorCode {
    EofWhileParsingList,
    EofWhileParsingObject,
    EofWhileParsingString,
    EofWhileParsingValue,
    ExpectedColon,
    ExpectedListCommaOrEnd,
    ExpectedObjectCommaOrEnd,
    ExpectedSomeIdent,
    ExpectedSomeValue,
    InvalidEscape,
    InvalidNumber,
    NumberOutOfRange,
    InvalidUnicodeCodePoint,
    ControlCharacterWhileParsingString,
    KeyMustBeAString,
    LoneLeadingSurrogateInHexEscape,
    TrailingComma,
    TrailingCharacters,
    UnexpectedEndOfHexEscape,
    RecursionLimitExceeded,
}

export function jsonErrorCodeText(code: JsonErrorCode): string {
    switch (code) {
        case JsonErrorCode.EofWhileParsingList: return "EOF while parsing a list";
        case JsonErrorCode.EofWhileParsingObject: return "EOF while parsing an object";
        case JsonErrorCode.EofWhileParsingString: return "EOF while parsing a string";
        case JsonErrorCode.EofWhileParsingValue: return "EOF while parsing a value";
        case JsonErrorCode.ExpectedColon: return "expected `:`";
        case JsonErrorCode.ExpectedListCommaOrEnd: return "expected `,` or `]`";
        case JsonErrorCode.ExpectedObjectCommaOrEnd: return "expected `,` or `}`";
        case JsonErrorCode.ExpectedSomeIdent: return "expected ident";
        case JsonErrorCode.ExpectedSomeValue: return "expected value";
        case JsonErrorCode.InvalidEscape: return "invalid escape";
        case JsonErrorCode.InvalidNumber: return "invalid number";
        case JsonErrorCode.NumberOutOfRange: return "number out of range";
        case JsonErrorCode.InvalidUnicodeCodePoint: return "invalid unicode code point";
        case JsonErrorCode.ControlCharacterWhileParsingString:
            return "control character (\\u0000-\\u001F) found while parsing a string";
        case JsonErrorCode.KeyMustBeAString: return "key must be a string";
        case JsonErrorCode.LoneLeadingSurrogateInHexEscape: return "lone leading surrogate in hex escape";
        case JsonErrorCode.TrailingComma: return "trailing comma";
        case JsonErrorCode.TrailingCharacters: return "trailing characters";
        case JsonErrorCode.UnexpectedEndOfHexEscape: return "unexpected end of hex escape";
        default: return "recursion limit exceeded";
    }
}

// A syntax error; toString() is its message with the line and column.
export class JsonError extends ErrorValue {
    code: JsonErrorCode;
    line: i32;
    column: i32;
    constructor(code: JsonErrorCode, line: i32, column: i32) {
        super();
        this.code = code;
        this.line = line;
        this.column = column;
    }
    toString(): string {
        return jsonErrorCodeText(this.code) + " at line " + this.line.toString()
            + " column " + this.column.toString();
    }
}

// Parses a JSON document.
export function parseJson(s: string): Result<JsonValue> {
    return new JsonParser(Uint8Array.wrap(String.UTF8.encode(s)), false).run();
}

// Parses a JSON document from bytes: strings must also be valid UTF-8.
export function parseJsonBytes(bytes: Uint8Array): Result<JsonValue> {
    return new JsonParser(bytes, true).run();
}

function isDigit(c: i32): bool {
    return c >= 48 && c <= 57;
}

const U64_MAX_DIV_10: u64 = 1844674407370955161;
const U64_MAX_MOD_10: u64 = 5;
const I32_MAX_DIV_10: i32 = 214748364;
const I32_MAX_MOD_10: i32 = 7;

class JsonParser {
    b: Uint8Array;
    len: i32;
    idx: i32 = 0;
    remainingDepth: i32 = 128;
    validateUtf8: bool;
    failed: bool = false;
    errCode: JsonErrorCode = JsonErrorCode.ExpectedSomeValue;
    errAt: i32 = 0;
    // parsed number: kind 0 = u64, 1 = i64, 2 = f64
    numKind: i32 = 0;
    numU: u64 = 0;
    numI: i64 = 0;
    numF: f64 = 0;
    scratch: Uint8Array = new Uint8Array(64);
    scratchLen: i32 = 0;

    constructor(b: Uint8Array, validateUtf8: bool) {
        this.b = b;
        this.len = b.length;
        this.validateUtf8 = validateUtf8;
    }

    run(): Result<JsonValue> {
        const v = this.parseValue();
        if (!this.failed) this.end();
        if (this.failed) {
            // position_of_index
            const i = this.errAt;
            let startOfLine = 0;
            let line = 1;
            for (let k = 0; k < i; k++) {
                if (this.b[k] == 10) {
                    startOfLine = k + 1;
                    line++;
                }
            }
            return Result.failWith<JsonValue>(new JsonError(this.errCode, line, i - startOfLine));
        }
        return Result.okv<JsonValue>(v);
    }

    // ---- read primitives (SliceRead)
    peek(): i32 {
        return this.idx < this.len ? <i32>this.b[this.idx] : -1;
    }
    peekOrNull(): i32 {
        return this.idx < this.len ? <i32>this.b[this.idx] : 0;
    }
    eatChar(): void {
        this.idx++;
    }
    nextChar(): i32 {
        if (this.idx < this.len) {
            const c = <i32>this.b[this.idx];
            this.idx++;
            return c;
        }
        return -1;
    }
    // Deserializer::error: position of the current index.
    error(code: JsonErrorCode): void {
        if (this.failed) return;
        this.failed = true;
        this.errCode = code;
        this.errAt = this.idx;
    }
    // Deserializer::peek_error: position one past the current index.
    peekError(code: JsonErrorCode): void {
        if (this.failed) return;
        this.failed = true;
        this.errCode = code;
        this.errAt = this.idx + 1 < this.len ? this.idx + 1 : this.len;
    }

    parseWhitespace(): i32 {
        while (true) {
            const c = this.peek();
            if (c == 32 || c == 10 || c == 9 || c == 13) {
                this.eatChar();
            } else {
                return c;
            }
        }
        return -1;
    }

    end(): void {
        if (this.parseWhitespace() >= 0) this.peekError(JsonErrorCode.TrailingCharacters);
    }

    parseIdent(ident: string): bool {
        for (let i = 0; i < ident.length; i++) {
            const c = this.nextChar();
            if (c < 0) {
                this.error(JsonErrorCode.EofWhileParsingValue);
                return false;
            }
            if (c != ident.charCodeAt(i)) {
                this.error(JsonErrorCode.ExpectedSomeIdent);
                return false;
            }
        }
        return true;
    }

    // Parses any value.
    parseValue(): JsonValue {
        const peek = this.parseWhitespace();
        if (peek < 0) {
            this.peekError(JsonErrorCode.EofWhileParsingValue);
            return JsonValue.nul();
        }
        switch (peek) {
            case 110: // n
                this.eatChar();
                this.parseIdent("ull");
                return JsonValue.nul();
            case 116: // t
                this.eatChar();
                this.parseIdent("rue");
                return JsonValue.bool(true);
            case 102: // f
                this.eatChar();
                this.parseIdent("alse");
                return JsonValue.bool(false);
            case 45: // -
                this.eatChar();
                return this.numberValue(false);
            case 34: { // "
                this.eatChar();
                return JsonValue.str(this.parseStr());
            }
            case 91: { // [
                this.remainingDepth -= 1;
                if (this.remainingDepth == 0) {
                    this.peekError(JsonErrorCode.RecursionLimitExceeded);
                    return JsonValue.nul();
                }
                this.eatChar();
                const v = this.parseSeq();
                this.remainingDepth += 1;
                if (this.failed) return v;
                this.endSeq();
                return v;
            }
            case 123: { // {
                this.remainingDepth -= 1;
                if (this.remainingDepth == 0) {
                    this.peekError(JsonErrorCode.RecursionLimitExceeded);
                    return JsonValue.nul();
                }
                this.eatChar();
                const v = this.parseMap();
                this.remainingDepth += 1;
                if (this.failed) return v;
                this.endMap();
                return v;
            }
            default:
                if (isDigit(peek)) return this.numberValue(true);
                this.peekError(JsonErrorCode.ExpectedSomeValue);
                return JsonValue.nul();
        }
    }

    numberValue(positive: bool): JsonValue {
        this.parseInteger(positive);
        if (this.failed) return JsonValue.nul();
        if (this.numKind == 0) return JsonValue.fromU64(this.numU);
        if (this.numKind == 1) return JsonValue.fromI64(this.numI);
        return JsonValue.fromF64(this.numF);
    }

    // SeqAccess + ValueVisitor::visit_seq
    parseSeq(): JsonValue {
        const items: Array<JsonValue> = [];
        let first = true;
        while (true) {
            // has_next_element
            const peek = this.parseWhitespace();
            if (peek < 0) {
                this.peekError(JsonErrorCode.EofWhileParsingList);
                break;
            }
            if (peek == 93) break; // ]
            if (first) {
                first = false;
            } else if (peek == 44) { // ,
                this.eatChar();
                const p2 = this.parseWhitespace();
                if (p2 == 93) {
                    this.peekError(JsonErrorCode.TrailingComma);
                    break;
                }
                if (p2 < 0) {
                    this.peekError(JsonErrorCode.EofWhileParsingValue);
                    break;
                }
            } else {
                this.peekError(JsonErrorCode.ExpectedListCommaOrEnd);
                break;
            }
            const v = this.parseValue();
            if (this.failed) break;
            items.push(v);
        }
        return JsonValue.array(items);
    }

    // MapAccess + ValueVisitor::visit_map (Map::insert: a repeated key keeps
    // its first position and takes the last value).
    parseMap(): JsonValue {
        const obj = JsonValue.object();
        const m = obj.map as JsonMap;
        let first = true;
        while (true) {
            // has_next_key
            const peek = this.parseWhitespace();
            if (peek < 0) {
                this.peekError(JsonErrorCode.EofWhileParsingObject);
                break;
            }
            if (peek == 125) break; // }
            if (first) {
                first = false;
                if (peek != 34) {
                    this.peekError(JsonErrorCode.KeyMustBeAString);
                    break;
                }
            } else if (peek == 44) {
                this.eatChar();
                const p2 = this.parseWhitespace();
                if (p2 == 34) {
                    // key follows
                } else if (p2 == 125) {
                    this.peekError(JsonErrorCode.TrailingComma);
                    break;
                } else if (p2 < 0) {
                    this.peekError(JsonErrorCode.EofWhileParsingValue);
                    break;
                } else {
                    this.peekError(JsonErrorCode.KeyMustBeAString);
                    break;
                }
            } else {
                this.peekError(JsonErrorCode.ExpectedObjectCommaOrEnd);
                break;
            }
            // MapKey::deserialize_any
            this.eatChar();
            const key = this.parseStr();
            if (this.failed) break;
            // parse_object_colon
            const c = this.parseWhitespace();
            if (c == 58) {
                this.eatChar();
            } else if (c >= 0) {
                this.peekError(JsonErrorCode.ExpectedColon);
                break;
            } else {
                this.peekError(JsonErrorCode.EofWhileParsingObject);
                break;
            }
            const v = this.parseValue();
            if (this.failed) break;
            m.insert(key, v);
        }
        return obj;
    }

    endSeq(): void {
        const c = this.parseWhitespace();
        if (c == 93) {
            this.eatChar();
        } else if (c == 44) {
            this.eatChar();
            if (this.parseWhitespace() == 93) this.peekError(JsonErrorCode.TrailingComma);
            else this.peekError(JsonErrorCode.TrailingCharacters);
        } else if (c >= 0) {
            this.peekError(JsonErrorCode.TrailingCharacters);
        } else {
            this.peekError(JsonErrorCode.EofWhileParsingList);
        }
    }

    endMap(): void {
        const c = this.parseWhitespace();
        if (c == 125) {
            this.eatChar();
        } else if (c == 44) {
            this.peekError(JsonErrorCode.TrailingComma);
        } else if (c >= 0) {
            this.peekError(JsonErrorCode.TrailingCharacters);
        } else {
            this.peekError(JsonErrorCode.EofWhileParsingObject);
        }
    }

    // ---- strings (control characters are rejected)

    scratchPush(byte: i32): void {
        if (this.scratchLen == this.scratch.length) {
            const n = new Uint8Array(this.scratch.length * 2);
            n.set(this.scratch);
            this.scratch = n;
        }
        this.scratch[this.scratchLen] = <u8>byte;
        this.scratchLen++;
    }

    scratchPushRange(from: i32, to: i32): void {
        for (let i = from; i < to; i++) this.scratchPush(<i32>this.b[i]);
    }

    pushCodePoint(n: u32): void {
        if (n < 0x80) {
            this.scratchPush(<i32>n);
        } else if (n < 0x800) {
            this.scratchPush(<i32>(((n >> 6) & 0x1F) | 0xC0));
            this.scratchPush(<i32>((n & 0x3F) | 0x80));
        } else if (n < 0x10000) {
            this.scratchPush(<i32>(((n >> 12) & 0x0F) | 0xE0));
            this.scratchPush(<i32>(((n >> 6) & 0x3F) | 0x80));
            this.scratchPush(<i32>((n & 0x3F) | 0x80));
        } else {
            this.scratchPush(<i32>(((n >> 18) & 0x07) | 0xF0));
            this.scratchPush(<i32>(((n >> 12) & 0x3F) | 0x80));
            this.scratchPush(<i32>(((n >> 6) & 0x3F) | 0x80));
            this.scratchPush(<i32>((n & 0x3F) | 0x80));
        }
    }

    // Called after the opening quote. Returns "" on error (failed is set).
    parseStr(): string {
        this.scratchLen = 0;
        let usedScratch = false;
        let start = this.idx;
        while (true) {
            // skip_to_escape(forbid_control_characters = true)
            while (this.idx < this.len) {
                const c = <i32>this.b[this.idx];
                if (c == 34 || c == 92 || c < 0x20) break;
                this.idx++;
            }
            if (this.idx == this.len) {
                this.error(JsonErrorCode.EofWhileParsingString);
                return "";
            }
            const c = <i32>this.b[this.idx];
            if (c == 34) {
                let text: string;
                if (!usedScratch) {
                    const end = this.idx;
                    this.idx++;
                    if (this.validateUtf8 && !validUtf8(this.b, start, end)) {
                        this.error(JsonErrorCode.InvalidUnicodeCodePoint);
                        return "";
                    }
                    text = decodeUtf8(this.b, start, end);
                } else {
                    this.scratchPushRange(start, this.idx);
                    this.idx++;
                    if (this.validateUtf8 && !validUtf8(this.scratch, 0, this.scratchLen)) {
                        this.error(JsonErrorCode.InvalidUnicodeCodePoint);
                        return "";
                    }
                    text = decodeUtf8(this.scratch, 0, this.scratchLen);
                }
                return text;
            }
            if (c == 92) {
                usedScratch = true;
                this.scratchPushRange(start, this.idx);
                this.idx++;
                if (!this.parseEscape()) return "";
                start = this.idx;
                continue;
            }
            this.idx++;
            this.error(JsonErrorCode.ControlCharacterWhileParsingString);
            return "";
        }
        return "";
    }

    parseEscape(): bool {
        const ch = this.nextChar();
        if (ch < 0) {
            this.error(JsonErrorCode.EofWhileParsingString);
            return false;
        }
        switch (ch) {
            case 34: this.scratchPush(34); return true;
            case 92: this.scratchPush(92); return true;
            case 47: this.scratchPush(47); return true;
            case 98: this.scratchPush(8); return true;
            case 102: this.scratchPush(12); return true;
            case 110: this.scratchPush(10); return true;
            case 114: this.scratchPush(13); return true;
            case 116: this.scratchPush(9); return true;
            case 117: return this.parseUnicodeEscape();
            default:
                this.error(JsonErrorCode.InvalidEscape);
                return false;
        }
    }

    // SliceRead::decode_hex_escape; -1 on error.
    decodeHexEscape(): i32 {
        if (this.len - this.idx >= 4) {
            let v = 0;
            let bad = false;
            for (let k = 0; k < 4; k++) {
                const c = <i32>this.b[this.idx + k];
                let d = -1;
                if (c >= 48 && c <= 57) d = c - 48;
                else if (c >= 65 && c <= 70) d = c - 55;
                else if (c >= 97 && c <= 102) d = c - 87;
                if (d < 0) bad = true;
                v = (v << 4) | (d & 15);
            }
            this.idx += 4;
            if (bad) {
                this.error(JsonErrorCode.InvalidEscape);
                return -1;
            }
            return v;
        }
        this.idx = this.len;
        this.error(JsonErrorCode.EofWhileParsingString);
        return -1;
    }

    // peek_or_eof; -1 (and the error) at EOF.
    peekOrEof(): i32 {
        const c = this.peek();
        if (c < 0) this.error(JsonErrorCode.EofWhileParsingString);
        return c;
    }

    parseUnicodeEscape(): bool {
        const n = this.decodeHexEscape();
        if (n < 0) return false;
        if (n >= 0xDC00 && n <= 0xDFFF) {
            this.error(JsonErrorCode.LoneLeadingSurrogateInHexEscape);
            return false;
        }
        if (n < 0xD800 || n > 0xDBFF) {
            this.pushCodePoint(<u32>n);
            return true;
        }
        const n1 = n;
        const c1 = this.peekOrEof();
        if (c1 < 0) return false;
        this.eatChar();
        if (c1 != 92) {
            this.error(JsonErrorCode.UnexpectedEndOfHexEscape);
            return false;
        }
        const c2 = this.peekOrEof();
        if (c2 < 0) return false;
        this.eatChar();
        if (c2 != 117) {
            this.error(JsonErrorCode.UnexpectedEndOfHexEscape);
            return false;
        }
        const n2 = this.decodeHexEscape();
        if (n2 < 0) return false;
        if (n2 < 0xDC00 || n2 > 0xDFFF) {
            this.error(JsonErrorCode.LoneLeadingSurrogateInHexEscape);
            return false;
        }
        this.pushCodePoint(((<u32>(n1 - 0xD800) << 10) | <u32>(n2 - 0xDC00)) + 0x10000);
        return true;
    }

    // ---- numbers (no float_roundtrip: f64_from_parts multiplies by POW10)

    setU64(v: u64): void {
        this.numKind = 0;
        this.numU = v;
    }
    setF64(v: f64): void {
        this.numKind = 2;
        this.numF = v;
    }

    parseInteger(positive: bool): void {
        const next = this.nextChar();
        if (next < 0) {
            this.error(JsonErrorCode.EofWhileParsingValue);
            return;
        }
        if (next == 48) {
            if (isDigit(this.peekOrNull())) {
                this.peekError(JsonErrorCode.InvalidNumber);
                return;
            }
            this.parseNumber(positive, 0);
            return;
        }
        if (next >= 49 && next <= 57) {
            let significand = <u64>(next - 48);
            while (true) {
                const c = this.peekOrNull();
                if (!isDigit(c)) {
                    this.parseNumber(positive, significand);
                    return;
                }
                const digit = <u64>(c - 48);
                if (significand > U64_MAX_DIV_10 || (significand == U64_MAX_DIV_10 && digit > U64_MAX_MOD_10)) {
                    this.parseLongInteger(positive, significand);
                    return;
                }
                this.eatChar();
                significand = significand * 10 + digit;
            }
        }
        this.error(JsonErrorCode.InvalidNumber);
    }

    parseNumber(positive: bool, significand: u64): void {
        const c = this.peekOrNull();
        if (c == 46) {
            this.parseDecimal(positive, significand, 0);
        } else if (c == 101 || c == 69) {
            this.parseExponent(positive, significand, 0);
        } else if (positive) {
            this.setU64(significand);
        } else {
            const neg = <i64>(<u64>0 - significand);
            if (neg >= 0) {
                this.setF64(-(<f64>significand));
            } else {
                this.numKind = 1;
                this.numI = neg;
            }
        }
    }

    parseDecimal(positive: bool, significandIn: u64, exponentBeforeDecimalPoint: i32): void {
        this.eatChar();
        let significand = significandIn;
        let exponentAfterDecimalPoint = 0;
        while (true) {
            const c = this.peekOrNull();
            if (!isDigit(c)) break;
            const digit = <u64>(c - 48);
            if (significand > U64_MAX_DIV_10 || (significand == U64_MAX_DIV_10 && digit > U64_MAX_MOD_10)) {
                this.parseDecimalOverflow(positive, significand, exponentBeforeDecimalPoint + exponentAfterDecimalPoint);
                return;
            }
            this.eatChar();
            significand = significand * 10 + digit;
            exponentAfterDecimalPoint -= 1;
        }
        if (exponentAfterDecimalPoint == 0) {
            if (this.peek() >= 0) this.peekError(JsonErrorCode.InvalidNumber);
            else this.peekError(JsonErrorCode.EofWhileParsingValue);
            return;
        }
        const exponent = exponentBeforeDecimalPoint + exponentAfterDecimalPoint;
        const c = this.peekOrNull();
        if (c == 101 || c == 69) this.parseExponent(positive, significand, exponent);
        else this.f64FromParts(positive, significand, exponent);
    }

    parseExponent(positive: bool, significand: u64, startingExp: i32): void {
        this.eatChar();
        let positiveExp = true;
        const s = this.peekOrNull();
        if (s == 43) {
            this.eatChar();
        } else if (s == 45) {
            this.eatChar();
            positiveExp = false;
        }
        const next = this.nextChar();
        if (next < 0) {
            this.error(JsonErrorCode.EofWhileParsingValue);
            return;
        }
        if (!isDigit(next)) {
            this.error(JsonErrorCode.InvalidNumber);
            return;
        }
        let exp = next - 48;
        while (true) {
            const c = this.peekOrNull();
            if (!isDigit(c)) break;
            this.eatChar();
            const digit = c - 48;
            if (exp > I32_MAX_DIV_10 || (exp == I32_MAX_DIV_10 && digit > I32_MAX_MOD_10)) {
                this.parseExponentOverflow(positive, significand == 0, positiveExp);
                return;
            }
            exp = exp * 10 + digit;
        }
        // i32::saturating_add / saturating_sub
        const wide = positiveExp ? <i64>startingExp + <i64>exp : <i64>startingExp - <i64>exp;
        const finalExp = i64ToI32(wide);
        this.f64FromParts(positive, significand, finalExp);
    }

    f64FromParts(positive: bool, significand: u64, exponentIn: i32): void {
        let f = <f64>significand;
        let exponent = exponentIn;
        while (true) {
            const a: u32 = exponent < 0 ? <u32>(0 - exponent) : <u32>exponent;
            if (a < 309) {
                const pow = reinterpret<f64>(POW10_BITS[<i32>a]);
                if (exponent >= 0) {
                    f *= pow;
                    if (!isFinite(f)) {
                        this.error(JsonErrorCode.NumberOutOfRange);
                        return;
                    }
                } else {
                    f /= pow;
                }
                break;
            }
            if (f == 0) break;
            if (exponent >= 0) {
                this.error(JsonErrorCode.NumberOutOfRange);
                return;
            }
            f /= 1e308;
            exponent += 308;
        }
        this.setF64(positive ? f : -f);
    }

    parseLongInteger(positive: bool, significand: u64): void {
        let exponent = 0;
        while (true) {
            const c = this.peekOrNull();
            if (isDigit(c)) {
                this.eatChar();
                exponent += 1;
            } else if (c == 46) {
                this.parseDecimal(positive, significand, exponent);
                return;
            } else if (c == 101 || c == 69) {
                this.parseExponent(positive, significand, exponent);
                return;
            } else {
                this.f64FromParts(positive, significand, exponent);
                return;
            }
        }
    }

    parseDecimalOverflow(positive: bool, significand: u64, exponent: i32): void {
        while (isDigit(this.peekOrNull())) this.eatChar();
        const c = this.peekOrNull();
        if (c == 101 || c == 69) this.parseExponent(positive, significand, exponent);
        else this.f64FromParts(positive, significand, exponent);
    }

    parseExponentOverflow(positive: bool, zeroSignificand: bool, positiveExp: bool): void {
        if (!zeroSignificand && positiveExp) {
            this.error(JsonErrorCode.NumberOutOfRange);
            return;
        }
        while (isDigit(this.peekOrNull())) this.eatChar();
        this.setF64(positive ? 0.0 : -0.0);
    }
}

// Whether b[start..end) is valid UTF-8 (no overlongs, surrogates or code
// points above U+10FFFF).
function validUtf8(b: Uint8Array, start: i32, end: i32): bool {
    let i = start;
    while (i < end) {
        const c = <i32>b[i];
        if (c < 0x80) {
            i++;
            continue;
        }
        let need = 0;
        let lo = 0x80;
        let hi = 0xBF;
        if (c >= 0xC2 && c <= 0xDF) {
            need = 1;
        } else if (c >= 0xE0 && c <= 0xEF) {
            need = 2;
            if (c == 0xE0) lo = 0xA0;
            if (c == 0xED) hi = 0x9F;
        } else if (c >= 0xF0 && c <= 0xF4) {
            need = 3;
            if (c == 0xF0) lo = 0x90;
            if (c == 0xF4) hi = 0x8F;
        } else {
            return false;
        }
        if (i + need >= end) return false;
        for (let k = 1; k <= need; k++) {
            const d = <i32>b[i + k];
            const l = k == 1 ? lo : 0x80;
            const h = k == 1 ? hi : 0xBF;
            if (d < l || d > h) return false;
        }
        i += need + 1;
    }
    return true;
}

function decodeUtf8(b: Uint8Array, start: i32, end: i32): string {
    if (end <= start) return "";
    const off = b.byteOffset;
    return String.UTF8.decode(b.buffer.slice(off + start, off + end));
}

// 1e0 ..= 1e308 as f64 bit patterns.

const POW10_BITS: StaticArray<u64> = [
    0x3ff0000000000000, 0x4024000000000000, 0x4059000000000000, 0x408f400000000000,
    0x40c3880000000000, 0x40f86a0000000000, 0x412e848000000000, 0x416312d000000000,
    0x4197d78400000000, 0x41cdcd6500000000, 0x4202a05f20000000, 0x42374876e8000000,
    0x426d1a94a2000000, 0x42a2309ce5400000, 0x42d6bcc41e900000, 0x430c6bf526340000,
    0x4341c37937e08000, 0x4376345785d8a000, 0x43abc16d674ec800, 0x43e158e460913d00,
    0x4415af1d78b58c40, 0x444b1ae4d6e2ef50, 0x4480f0cf064dd592, 0x44b52d02c7e14af6,
    0x44ea784379d99db4, 0x45208b2a2c280291, 0x4554adf4b7320335, 0x4589d971e4fe8402,
    0x45c027e72f1f1281, 0x45f431e0fae6d721, 0x46293e5939a08cea, 0x465f8def8808b024,
    0x4693b8b5b5056e17, 0x46c8a6e32246c99c, 0x46fed09bead87c03, 0x4733426172c74d82,
    0x476812f9cf7920e3, 0x479e17b84357691b, 0x47d2ced32a16a1b1, 0x48078287f49c4a1d,
    0x483d6329f1c35ca5, 0x48725dfa371a19e7, 0x48a6f578c4e0a061, 0x48dcb2d6f618c879,
    0x4911efc659cf7d4c, 0x49466bb7f0435c9e, 0x497c06a5ec5433c6, 0x49b18427b3b4a05c,
    0x49e5e531a0a1c873, 0x4a1b5e7e08ca3a8f, 0x4a511b0ec57e649a, 0x4a8561d276ddfdc0,
    0x4ababa4714957d30, 0x4af0b46c6cdd6e3e, 0x4b24e1878814c9ce, 0x4b5a19e96a19fc41,
    0x4b905031e2503da9, 0x4bc4643e5ae44d13, 0x4bf97d4df19d6057, 0x4c2fdca16e04b86d,
    0x4c63e9e4e4c2f344, 0x4c98e45e1df3b015, 0x4ccf1d75a5709c1b, 0x4d03726987666191,
    0x4d384f03e93ff9f5, 0x4d6e62c4e38ff872, 0x4da2fdbb0e39fb47, 0x4dd7bd29d1c87a19,
    0x4e0dac74463a989f, 0x4e428bc8abe49f64, 0x4e772ebad6ddc73d, 0x4eacfa698c95390c,
    0x4ee21c81f7dd43a7, 0x4f16a3a275d49491, 0x4f4c4c8b1349b9b5, 0x4f81afd6ec0e1411,
    0x4fb61bcca7119916, 0x4feba2bfd0d5ff5b, 0x502145b7e285bf99, 0x50559725db272f7f,
    0x508afcef51f0fb5f, 0x50c0de1593369d1b, 0x50f5159af8044462, 0x512a5b01b605557b,
    0x516078e111c3556d, 0x5194971956342ac8, 0x51c9bcdfabc1357a, 0x5200160bcb58c16c,
    0x52341b8ebe2ef1c7, 0x526922726dbaae39, 0x529f6b0f092959c7, 0x52d3a2e965b9d81d,
    0x53088ba3bf284e24, 0x533eae8caef261ad, 0x53732d17ed577d0c, 0x53a7f85de8ad5c4f,
    0x53ddf67562d8b363, 0x5412ba095dc7701e, 0x5447688bb5394c25, 0x547d42aea2879f2e,
    0x54b249ad2594c37d, 0x54e6dc186ef9f45c, 0x551c931e8ab87173, 0x5551dbf316b346e8,
    0x558652efdc6018a2, 0x55bbe7abd3781eca, 0x55f170cb642b133f, 0x5625ccfe3d35d80e,
    0x565b403dcc834e12, 0x569108269fd210cb, 0x56c54a3047c694fe, 0x56fa9cbc59b83a3d,
    0x5730a1f5b8132466, 0x5764ca732617ed80, 0x5799fd0fef9de8e0, 0x57d03e29f5c2b18c,
    0x58044db473335def, 0x583961219000356b, 0x586fb969f40042c5, 0x58a3d3e2388029bb,
    0x58d8c8dac6a0342a, 0x590efb1178484135, 0x59435ceaeb2d28c1, 0x59783425a5f872f1,
    0x59ae412f0f768fad, 0x59e2e8bd69aa19cc, 0x5a17a2ecc414a03f, 0x5a4d8ba7f519c84f,
    0x5a827748f9301d32, 0x5ab7151b377c247e, 0x5aecda62055b2d9e, 0x5b22087d4358fc82,
    0x5b568a9c942f3ba3, 0x5b8c2d43b93b0a8c, 0x5bc19c4a53c4e697, 0x5bf6035ce8b6203d,
    0x5c2b843422e3a84d, 0x5c6132a095ce4930, 0x5c957f48bb41db7c, 0x5ccadf1aea12525b,
    0x5d00cb70d24b7379, 0x5d34fe4d06de5057, 0x5d6a3de04895e46d, 0x5da066ac2d5daec4,
    0x5dd4805738b51a75, 0x5e09a06d06e26112, 0x5e400444244d7cab, 0x5e7405552d60dbd6,
    0x5ea906aa78b912cc, 0x5edf485516e7577f, 0x5f138d352e5096af, 0x5f48708279e4bc5b,
    0x5f7e8ca3185deb72, 0x5fb317e5ef3ab327, 0x5fe7dddf6b095ff1, 0x601dd55745cbb7ed,
    0x6052a5568b9f52f4, 0x60874eac2e8727b1, 0x60bd22573a28f19d, 0x60f2357684599702,
    0x6126c2d4256ffcc3, 0x615c73892ecbfbf4, 0x6191c835bd3f7d78, 0x61c63a432c8f5cd6,
    0x61fbc8d3f7b3340c, 0x62315d847ad00087, 0x6265b4e5998400a9, 0x629b221effe500d4,
    0x62d0f5535fef2084, 0x630532a837eae8a5, 0x633a7f5245e5a2cf, 0x63708f936baf85c1,
    0x63a4b378469b6732, 0x63d9e056584240fe, 0x64102c35f729689f, 0x6444374374f3c2c6,
    0x647945145230b378, 0x64af965966bce056, 0x64e3bdf7e0360c36, 0x6518ad75d8438f43,
    0x654ed8d34e547314, 0x6583478410f4c7ec, 0x65b819651531f9e8, 0x65ee1fbe5a7e7861,
    0x6622d3d6f88f0b3d, 0x665788ccb6b2ce0c, 0x668d6affe45f818f, 0x66c262dfeebbb0f9,
    0x66f6fb97ea6a9d38, 0x672cba7de5054486, 0x6761f48eaf234ad4, 0x679671b25aec1d89,
    0x67cc0e1ef1a724eb, 0x680188d357087713, 0x6835eb082cca94d7, 0x686b65ca37fd3a0d,
    0x68a11f9e62fe4448, 0x68d56785fbbdd55a, 0x690ac1677aad4ab1, 0x6940b8e0acac4eaf,
    0x6974e718d7d7625a, 0x69aa20df0dcd3af1, 0x69e0548b68a044d6, 0x6a1469ae42c8560c,
    0x6a498419d37a6b8f, 0x6a7fe52048590673, 0x6ab3ef342d37a408, 0x6ae8eb0138858d0a,
    0x6b1f25c186a6f04c, 0x6b537798f4285630, 0x6b88557f31326bbb, 0x6bbe6adefd7f06aa,
    0x6bf302cb5e6f642a, 0x6c27c37e360b3d35, 0x6c5db45dc38e0c82, 0x6c9290ba9a38c7d1,
    0x6cc734e940c6f9c6, 0x6cfd022390f8b837, 0x6d3221563a9b7323, 0x6d66a9abc9424feb,
    0x6d9c5416bb92e3e6, 0x6dd1b48e353bce70, 0x6e0621b1c28ac20c, 0x6e3baa1e332d728f,
    0x6e714a52dffc6799, 0x6ea59ce797fb817f, 0x6edb04217dfa61df, 0x6f10e294eebc7d2c,
    0x6f451b3a2a6b9c76, 0x6f7a6208b5068394, 0x6fb07d457124123d, 0x6fe49c96cd6d16cc,
    0x7019c3bc80c85c7f, 0x70501a55d07d39cf, 0x708420eb449c8843, 0x70b9292615c3aa54,
    0x70ef736f9b3494e9, 0x7123a825c100dd11, 0x7158922f31411456, 0x718eb6bafd91596b,
    0x71c33234de7ad7e3, 0x71f7fec216198ddc, 0x722dfe729b9ff153, 0x7262bf07a143f6d4,
    0x72976ec98994f489, 0x72cd4a7bebfa31ab, 0x73024e8d737c5f0b, 0x7336e230d05b76cd,
    0x736c9abd04725481, 0x73a1e0b622c774d0, 0x73d658e3ab795204, 0x740bef1c9657a686,
    0x74417571ddf6c814, 0x7475d2ce55747a18, 0x74ab4781ead1989e, 0x74e10cb132c2ff63,
    0x75154fdd7f73bf3c, 0x754aa3d4df50af0b, 0x7580a6650b926d67, 0x75b4cffe4e7708c0,
    0x75ea03fde214caf1, 0x7620427ead4cfed6, 0x7654531e58a03e8c, 0x768967e5eec84e2f,
    0x76bfc1df6a7a61bb, 0x76f3d92ba28c7d15, 0x7728cf768b2f9c5a, 0x775f03542dfb8370,
    0x779362149cbd3226, 0x77c83a99c3ec7eb0, 0x77fe494034e79e5c, 0x7832edc82110c2f9,
    0x7867a93a2954f3b8, 0x789d9388b3aa30a5, 0x78d27c35704a5e67, 0x79071b42cc5cf601,
    0x793ce2137f743382, 0x79720d4c2fa8a031, 0x79a6909f3b92c83d, 0x79dc34c70a777a4d,
    0x7a11a0fc668aac70, 0x7a46093b802d578c, 0x7a7b8b8a6038ad6f, 0x7ab137367c236c65,
    0x7ae585041b2c477f, 0x7b1ae64521f7595e, 0x7b50cfeb353a97db, 0x7b8503e602893dd2,
    0x7bba44df832b8d46, 0x7bf06b0bb1fb384c, 0x7c2485ce9e7a065f, 0x7c59a742461887f6,
    0x7c9008896bcf54fa, 0x7cc40aabc6c32a38, 0x7cf90d56b873f4c7, 0x7d2f50ac6690f1f8,
    0x7d63926bc01a973b, 0x7d987706b0213d0a, 0x7dce94c85c298c4c, 0x7e031cfd3999f7b0,
    0x7e37e43c8800759c, 0x7e6ddd4baa009303, 0x7ea2aa4f4a405be2, 0x7ed754e31cd072da,
    0x7f0d2a1be4048f90, 0x7f423a516e82d9ba, 0x7f76c8e5ca239029, 0x7fac7b1f3cac7433,
    0x7fe1ccf385ebc8a0,
];
