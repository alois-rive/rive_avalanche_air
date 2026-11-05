// Decoding of the glTF JSON text into a typed `Root`, with an error message
// and a line and column for everything that goes wrong.
//
// Two passes:
//   1. `parseJsonBytes` (engine/src/base/json) checks the syntax, UTF-8 and the
//      recursion limit, and gives its syntax errors verbatim;
//   2. a span scanner rebuilds the (now known valid) text as a tree of
//      byte ranges, and the typed decoders below walk it in document order,
//      raising typed errors ("missing field `asset`", "invalid type:
//      string \"x\", expected u32", ...) at the position of the offending
//      value. Raw values (`extras`) are kept as the exact source bytes;
//      untyped values (`min`, `max`, extension objects) are parsed from their
//      own bytes by `parseJsonBytes`.
//
// `ioRead` selects the position rules for a `.gltf` file read whole instead
// of those for the JSON chunk of a `.glb`: an error raised at a `[` or `{`
// that was peeked but not consumed is one column further on with ioRead.
//
// Only what is decoded is parsed strictly: ignored fields and raw values are
// skipped with a lenient grammar (see lenientValid). A text pass 1 rejects
// but that grammar accepts is decoded anyway, and pass 1 is rerun with the
// skipped spans blanked (see rootFromBytes). Where a structural syntax error
// comes later in the text than a typed error, the syntax error is the one
// reported.

import { Result, ErrorValue } from "../../../base/util";
import { JsonValue, JsonNumberKind, parseJsonBytes, jsonErrorCodeText, JsonErrorCode, JsonError } from "../../../base/json";
import { jsonF64, debugStr } from "../../../base/fmt";
import {
    Root, Accessor, Sparse, SparseIndices, SparseValues, Animation, Channel, ChannelTarget, AnimationSampler,
    Asset, Buffer, BufferView, Camera, CameraOrthographic, CameraPerspective, Image, Material,
    PbrMetallicRoughness, NormalTexture, OcclusionTexture, TextureInfo, Mesh, Primitive, MorphTarget, Node,
    Sampler, Scene, Skin, Texture, KhrLight, KhrLightSpot, KhrLightsPunctual, RootExtensions, NodeExtensions,
    NodeLightRef, MaterialExtensions, EmissiveStrength, Extensions, EmptyExtensions, Semantic,
    CHECKED_NONE, indexFromU32,
    componentTypeFromGl, indexComponentTypeFromGl, accessorTypeFromName, bufferTargetFromGl, modeFromGl,
    alphaModeFromName, magFilterFromGl, minFilterFromGl, wrappingModeFromGl, interpolationFromName,
    propertyFromName, cameraTypeFromName, khrLightTypeFromName, KHR_LIGHTS_PUNCTUAL,
    KHR_MATERIALS_EMISSIVE_STRENGTH,
} from "./doc";

// ---------------------------------------------------------------------------
// The error: a message plus line and column

export class DeError extends ErrorValue {
    message: string = "";
    line: i32 = 0;
    column: i32 = 0;
    // Display: "{message} at line {line} column {column}".
    toString(): string {
        if (this.line == 0) return this.message;
        return this.message + " at line " + this.line.toString() + " column " + this.column.toString();
    }
}

// ---------------------------------------------------------------------------
// Span tree

const K_NULL = 0;
const K_TRUE = 1;
const K_FALSE = 2;
const K_NUMBER = 3;
const K_STRING = 4;
const K_ARRAY = 5;
const K_OBJECT = 6;

export class SNode {
    kind: i32 = K_NULL;
    start: i32 = 0; // first byte of the value
    end: i32 = 0; // one past its last byte
    kids: Array<SNode> = []; // array elements / object values
    keys: Array<string> = []; // object keys (decoded)
    colons: Array<i32> = []; // index of the ':' after each key
    // A struct read from a sequence (a positional struct): the fields
    // the elements stand for, and the struct's name and field list.
    seqFields: Array<string>? = null;
    seqName: string = "";
}

function isWs(c: i32): bool {
    return c == 32 || c == 10 || c == 9 || c == 13;
}

// Containers nested deeper than this are skipped without building their
// children (a lenient document can nest without limit inside raw and
// ignored values, which are skipped iteratively; no typed decoder
// reaches this depth).
const SCAN_DEPTH = 256;

// Builds the span tree of a structurally valid JSON text (see lenientValid).
class Scanner {
    b: Uint8Array;
    i: i32 = 0;
    constructor(b: Uint8Array) {
        this.b = b;
    }

    // Skips the container starting at `this.i` without recursion.
    skipContainer(): void {
        let depth = 0;
        while (true) {
            const c = <i32>this.b[this.i];
            if (c == 34) {
                this.skipString();
                continue;
            }
            this.i++;
            if (c == 91 || c == 123) depth++;
            else if (c == 93 || c == 125) {
                depth--;
                if (depth == 0) return;
            }
        }
    }

    ws(): void {
        while (this.i < this.b.length && isWs(<i32>this.b[this.i])) this.i++;
    }

    // Index one past the closing quote of the string starting at `this.i`.
    skipString(): void {
        this.i++; // opening quote
        while (true) {
            const c = <i32>this.b[this.i];
            if (c == 34) {
                this.i++;
                return;
            }
            if (c == 92) this.i += 2;
            else this.i++;
        }
    }

    value(depth: i32 = 0): SNode {
        this.ws();
        const n = new SNode();
        n.start = this.i;
        const c = <i32>this.b[this.i];
        if ((c == 123 || c == 91) && depth >= SCAN_DEPTH) {
            n.kind = c == 123 ? K_OBJECT : K_ARRAY;
            this.skipContainer();
        } else if (c == 123) { // {
            n.kind = K_OBJECT;
            this.i++;
            this.ws();
            if (<i32>this.b[this.i] == 125) {
                this.i++;
            } else {
                while (true) {
                    this.ws();
                    const ks = this.i;
                    this.skipString();
                    n.keys.push(decodeString(this.b, ks, this.i));
                    this.ws();
                    n.colons.push(this.i);
                    this.i++; // ':'
                    n.kids.push(this.value(depth + 1));
                    this.ws();
                    const d = <i32>this.b[this.i];
                    this.i++;
                    if (d == 125) break; // '}'
                }
            }
        } else if (c == 91) { // [
            n.kind = K_ARRAY;
            this.i++;
            this.ws();
            if (<i32>this.b[this.i] == 93) {
                this.i++;
            } else {
                while (true) {
                    n.kids.push(this.value(depth + 1));
                    this.ws();
                    const d = <i32>this.b[this.i];
                    this.i++;
                    if (d == 93) break; // ']'
                }
            }
        } else if (c == 34) {
            n.kind = K_STRING;
            this.skipString();
        } else if (c == 116) {
            n.kind = K_TRUE;
            this.i += 4;
        } else if (c == 102) {
            n.kind = K_FALSE;
            this.i += 5;
        } else if (c == 110) {
            n.kind = K_NULL;
            this.i += 4;
        } else {
            n.kind = K_NUMBER;
            while (this.i < this.b.length) {
                const d = <i32>this.b[this.i];
                if ((d >= 48 && d <= 57) || d == 45 || d == 43 || d == 46 || d == 101 || d == 69) this.i++;
                else break;
            }
        }
        n.end = this.i;
        return n;
    }
}

// The decoded text of the JSON string literal b[start..end) (quotes included).
function decodeString(b: Uint8Array, start: i32, end: i32): string {
    let plain = true;
    for (let k = start + 1; k < end - 1; k++) {
        if (<i32>b[k] == 92) {
            plain = false;
            break;
        }
    }
    if (plain) return String.UTF8.decode(b.slice(start + 1, end - 1).buffer);
    // In a lenient document the escapes may not decode (a lone surrogate);
    // the strict pass over the sanitized text reports that (see rootFromBytes).
    const r = parseJsonBytes(b.subarray(start, end));
    if (!r.ok) return "";
    const s = r.value.asStr();
    return s != null ? s : "";
}

// Whether `b` is valid UTF-8.
export function isValidUtf8(b: Uint8Array): bool {
    let i = 0;
    const n = b.length;
    while (i < n) {
        const c = <i32>b[i];
        if (c < 0x80) {
            i++;
            continue;
        }
        let need = 0;
        let lo = 0x80;
        let hi = 0xBF;
        if (c >= 0xC2 && c <= 0xDF) need = 1;
        else if (c == 0xE0) { need = 2; lo = 0xA0; }
        else if (c >= 0xE1 && c <= 0xEC) need = 2;
        else if (c == 0xED) { need = 2; hi = 0x9F; }
        else if (c >= 0xEE && c <= 0xEF) need = 2;
        else if (c == 0xF0) { need = 3; lo = 0x90; }
        else if (c >= 0xF1 && c <= 0xF3) need = 3;
        else if (c == 0xF4) { need = 3; hi = 0x8F; }
        else return false;
        if (i + need >= n) return false;
        const c1 = <i32>b[i + 1];
        if (c1 < lo || c1 > hi) return false;
        for (let k = 2; k <= need; k++) {
            const ck = <i32>b[i + k];
            if (ck < 0x80 || ck > 0xBF) return false;
        }
        i += need + 1;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Decoding context

export class De {
    b: Uint8Array;
    ioRead: bool;
    failed: bool = false;
    message: string = "";
    pos: i32 = 0;
    peeked: bool = false;
    // The spans [start, end) of the values skipped without
    // parsing them strictly: ignored fields and raw values, in document
    // order.
    skipped: Array<i32> = [];

    constructor(b: Uint8Array, ioRead: bool) {
        this.b = b;
        this.ioRead = ioRead;
    }

    // An unknown field's value (or any field of an empty struct), skipped
    // with the lenient grammar.
    ignored(n: SNode): void {
        this.skipped.push(n.start);
        this.skipped.push(n.end);
    }

    // Records the first error. `peeked`: raised with the byte at `pos`
    // peeked but not consumed (IoRead counts it).
    fail(message: string, pos: i32, peeked: bool): void {
        if (this.failed) return;
        this.failed = true;
        this.message = message;
        this.pos = pos;
        this.peeked = peeked;
    }

    error(): DeError {
        const e = new DeError();
        e.message = this.message;
        // IoRead counts a peeked byte as read (LineColIterator).
        const at = this.ioRead && this.peeked && this.pos < this.b.length ? this.pos + 1 : this.pos;
        let line = 1;
        let startOfLine = 0;
        for (let k = 0; k < at; k++) {
            if (<i32>this.b[k] == 10) {
                startOfLine = k + 1;
                line++;
            }
        }
        e.line = line;
        e.column = at - startOfLine;
        return e;
    }

    // How an error message names the value it did not expect.
    unexpected(n: SNode): string {
        switch (n.kind) {
            case K_NULL: return "null";
            case K_TRUE: return "boolean `true`";
            case K_FALSE: return "boolean `false`";
            case K_STRING: return "string " + debugStr(this.str(n));
            case K_ARRAY: return "sequence";
            case K_OBJECT: return "map";
            default: {
                const v = this.num(n);
                if (v.numKind == JsonNumberKind.PosInt) return "integer `" + v.u.toString() + "`";
                if (v.numKind == JsonNumberKind.NegInt) return "integer `" + v.i.toString() + "`";
                return "floating point `" + jsonF64(v.f) + "`";
            }
        }
    }

    // Raised with the value's first byte peeked (a sequence or map), or
    // after the value; a number is only known to end when the byte after
    // it has been peeked.
    invalidType(n: SNode, expected: string): void {
        const container = n.kind == K_ARRAY || n.kind == K_OBJECT;
        this.fail("invalid type: " + this.unexpected(n) + ", expected " + expected,
            container ? n.start : n.end, container || n.kind == K_NUMBER);
    }

    invalidValue(n: SNode, unexpected: string, expected: string): void {
        this.fail("invalid value: " + unexpected + ", expected " + expected, n.end, n.kind == K_NUMBER);
    }

    // A required field absent from a map: true once the error is recorded.
    // A positional struct reports its short length in endStruct instead.
    missingField(obj: SNode, name: string): bool {
        if (obj.seqFields != null) return false;
        this.fail("missing field `" + name + "`", obj.end, false);
        return true;
    }

    // The node a struct is decoded from: a map as is, or a sequence as the
    // map of its elements under the first field names (both
    // are accepted). `fields` lists the struct's fields (see F_*).
    structNode(n: SNode, name: string, fields: string): SNode? {
        if (n.kind == K_OBJECT) return n;
        if (n.kind != K_ARRAY) {
            this.invalidType(n, "struct " + name);
            return null;
        }
        const names = fields.length == 0 ? new Array<string>(0) : fields.split(" ");
        const m = new SNode();
        m.kind = K_OBJECT;
        m.start = n.start;
        m.end = n.end;
        m.seqFields = names;
        m.seqName = name;
        const count = min(names.length, n.kids.length);
        for (let i = 0; i < count; i++) {
            const f = names[i];
            m.keys.push(f.startsWith("?") ? f.substring(1) : f);
            m.kids.push(n.kids[i]);
            m.colons.push(n.kids[i].start);
        }
        return m;
    }

    // After a struct's fields: a positional struct must have an element for
    // every field without a default, and no more elements than fields.
    endStruct(n0: SNode, n: SNode): bool {
        if (this.failed) return false;
        const names = n.seqFields;
        if (names == null) return true;
        for (let i = n0.kids.length; i < names.length; i++) {
            if (!names[i].startsWith("?")) {
                this.fail("invalid length " + i.toString() + ", expected struct " + n.seqName + " with "
                    + names.length.toString() + (names.length == 1 ? " element" : " elements"), n0.end, false);
                return false;
            }
        }
        if (n0.kids.length > names.length) {
            this.fail(jsonErrorCodeText(JsonErrorCode.TrailingCharacters), n0.kids[names.length].start + 1, false);
            return false;
        }
        return true;
    }

    // A struct with a flattened map (the extension containers): only a map
    // will do.
    flatStruct(n: SNode, name: string): bool {
        if (n.kind == K_OBJECT) return true;
        this.invalidType(n, "struct " + name);
        return false;
    }

    // A known field seen twice: raised right after its second key, with the
    // ':' peeked.
    duplicateField(obj: SNode, k: i32, name: string): void {
        this.fail("duplicate field `" + name + "`", obj.colons[k], true);
    }

    str(n: SNode): string {
        return decodeString(this.b, n.start, n.end);
    }

    // The number at `n`, as a u64, an i64 or an f64.
    num(n: SNode): JsonValue {
        const len = n.end - n.start;
        if (len <= 18) {
            let digits = true;
            let v: u64 = 0;
            for (let k = n.start; k < n.end; k++) {
                const c = <i32>this.b[k];
                if (c < 48 || c > 57) {
                    digits = false;
                    break;
                }
                v = v * 10 + <u64>(c - 48);
            }
            if (digits) return JsonValue.fromU64(v);
        }
        // Out of range in a lenient document: the strict pass reports it.
        const r = parseJsonBytes(this.b.subarray(n.start, n.end));
        return r.ok ? r.value : JsonValue.fromU64(0);
    }

    // A raw value: the source text, which is only checked to be
    // UTF-8 (its escapes, numbers and depth are not looked at).
    raw(n: SNode): string {
        this.ignored(n);
        const bytes = this.b.slice(n.start, n.end);
        if (!isValidUtf8(bytes)) {
            this.fail(jsonErrorCodeText(JsonErrorCode.InvalidUnicodeCodePoint), n.end, false);
            return "";
        }
        return String.UTF8.decode(bytes.buffer);
    }

    value(n: SNode): JsonValue {
        // A value the strict pass rejects (lenient document): null here, the
        // strict pass over the sanitized text reports the error.
        const r = parseJsonBytes(this.b.subarray(n.start, n.end));
        return r.ok ? r.value : JsonValue.nul();
    }

    // ---- primitives

    f32(n: SNode): f32 {
        if (n.kind != K_NUMBER) {
            this.invalidType(n, "f32");
            return 0;
        }
        const v = this.num(n);
        if (v.numKind == JsonNumberKind.PosInt) return <f32>v.u;
        if (v.numKind == JsonNumberKind.NegInt) return <f32>v.i;
        return <f32>v.f;
    }

    // An unsigned integer no larger than `max`.
    uint(n: SNode, max: u64, expected: string): u64 {
        if (n.kind != K_NUMBER) {
            this.invalidType(n, expected);
            return 0;
        }
        const v = this.num(n);
        if (v.numKind == JsonNumberKind.PosInt) {
            if (v.u > max) {
                this.invalidValue(n, "integer `" + v.u.toString() + "`", expected);
                return 0;
            }
            return v.u;
        }
        if (v.numKind == JsonNumberKind.NegInt) {
            this.invalidValue(n, "integer `" + v.i.toString() + "`", expected);
            return 0;
        }
        this.invalidType(n, expected);
        return 0;
    }

    u32(n: SNode): u32 {
        return <u32>this.uint(n, <u64>u32.MAX_VALUE, "u32");
    }

    u64(n: SNode): u64 {
        return this.uint(n, u64.MAX_VALUE, "u64");
    }

    // A visitor with only `visit_u64` (Index<T>, the GLenum checked enums):
    // the raw value, or -1 after an error.
    visitU64(n: SNode, expected: string): i64 {
        if (n.kind == K_NUMBER) {
            const v = this.num(n);
            if (v.numKind == JsonNumberKind.PosInt) return <i64>(v.u & 0xFFFFFFFF); // the low 32 bits
        }
        this.invalidType(n, expected);
        return -1;
    }

    // Index<T>: "index into child of root".
    index(n: SNode): i32 {
        const v = this.visitU64(n, "index into child of root");
        if (v < 0) return 0;
        return indexFromU32(<u32>v);
    }

    optIndex(n: SNode): i32 {
        if (n.kind == K_NULL) return -1;
        return this.index(n);
    }

    bool(n: SNode): bool {
        if (n.kind == K_TRUE) return true;
        if (n.kind == K_FALSE) return false;
        this.invalidType(n, "a boolean");
        return false;
    }

    string(n: SNode): string {
        if (n.kind != K_STRING) {
            this.invalidType(n, "a string");
            return "";
        }
        return this.str(n);
    }

    optString(n: SNode): string? {
        if (n.kind == K_NULL) return null;
        return this.string(n);
    }

    optRaw(n: SNode): string? {
        if (n.kind == K_NULL) return null;
        return this.raw(n);
    }

    optValue(n: SNode): JsonValue? {
        if (n.kind == K_NULL) return null;
        return this.value(n);
    }

    // A visitor with only `visit_str` (the string checked enums): the string,
    // or null after an error.
    visitStr(n: SNode, expected: string): string? {
        if (n.kind == K_STRING) return this.str(n);
        this.invalidType(n, expected);
        return null;
    }

    // A fixed-length f32 array ("an array of length N").
    f32Array(n: SNode, len: i32): StaticArray<f32> {
        const out = new StaticArray<f32>(len);
        const expected = "an array of length " + len.toString();
        if (n.kind != K_ARRAY) {
            this.invalidType(n, expected);
            return out;
        }
        for (let k = 0; k < len; k++) {
            if (k >= n.kids.length) {
                this.fail("invalid length " + k.toString() + ", expected " + expected, n.end, false);
                return out;
            }
            out[k] = this.f32(n.kids[k]);
            if (this.failed) return out;
        }
        if (n.kids.length > len) {
            // end_seq: ',' eaten, the next value's first byte peeked.
            this.fail(jsonErrorCodeText(JsonErrorCode.TrailingCharacters), n.kids[len].start + 1, false);
        }
        return out;
    }

    optF32Array(n: SNode, len: i32): StaticArray<f32>? {
        if (n.kind == K_NULL) return null;
        return this.f32Array(n, len);
    }

    // An array of f32.
    f32Vec(n: SNode): Array<f32> {
        const out: Array<f32> = [];
        if (!this.seq(n)) return out;
        for (let k = 0; k < n.kids.length; k++) {
            out.push(this.f32(n.kids[k]));
            if (this.failed) return out;
        }
        return out;
    }

    optF32Vec(n: SNode): Array<f32>? {
        if (n.kind == K_NULL) return null;
        return this.f32Vec(n);
    }

    // An array of indices.
    indexVec(n: SNode): Array<i32> {
        const out: Array<i32> = [];
        if (!this.seq(n)) return out;
        for (let k = 0; k < n.kids.length; k++) {
            out.push(this.index(n.kids[k]));
            if (this.failed) return out;
        }
        return out;
    }

    stringVec(n: SNode): Array<string> {
        const out: Array<string> = [];
        if (!this.seq(n)) return out;
        for (let k = 0; k < n.kids.length; k++) {
            out.push(this.string(n.kids[k]));
            if (this.failed) return out;
        }
        return out;
    }

    // An array: true when `n` is a sequence.
    seq(n: SNode): bool {
        if (n.kind == K_ARRAY) return true;
        this.invalidType(n, "a sequence");
        return false;
    }

}

// An optional size or stride in its i64 field (-1 = absent): a u64 above i64.MAX saturates (it is out of range of any
// buffer either way, and an invalid stride stays invalid).
function optSize(v: u64): i64 {
    return v > <u64>i64.MAX_VALUE ? i64.MAX_VALUE : <i64>v;
}

// Tracks the known fields a struct has seen, to reject duplicates.
class Seen {
    names: Array<string> = [];

    // False (and the error recorded) when `name` was already seen.
    first(de: De, obj: SNode, k: i32, name: string): bool {
        for (let i = 0; i < this.names.length; i++) {
            if (this.names[i] == name) {
                de.duplicateField(obj, k, name);
                return false;
            }
        }
        this.names.push(name);
        return true;
    }

    has(name: string): bool {
        for (let i = 0; i < this.names.length; i++) {
            if (this.names[i] == name) return true;
        }
        return false;
    }
}

// ---------------------------------------------------------------------------
// Enums (an unknown value decodes as CHECKED_INVALID)

const EXP_COMPONENT = "any of: [5120, 5121, 5122, 5123, 5125, 5126]";
const EXP_INDEX_COMPONENT = "any of: [5121, 5123, 5125]";
const EXP_ACCESSOR_TYPE = "any of: [\"SCALAR\", \"VEC2\", \"VEC3\", \"VEC4\", \"MAT2\", \"MAT3\", \"MAT4\"]";
const EXP_TARGET = "any of: [34962, 34963]";
const EXP_MODE = "any of: [0, 1, 2, 3, 4, 5, 6]";
const EXP_ALPHA = "any of: [\"OPAQUE\", \"MASK\", \"BLEND\"]";
const EXP_MAG = "any of: [9728, 9729]";
const EXP_MIN = "any of: [9728, 9729, 9984, 9985, 9986, 9987]";
const EXP_WRAP = "any of: [33071, 33648, 10497]";
const EXP_INTERPOLATION = "any of: [\"LINEAR\", \"STEP\", \"CUBICSPLINE\"]";
const EXP_PROPERTY = "any of: [\"translation\", \"rotation\", \"scale\", \"weights\"]";
const EXP_CAMERA = "any of: [\"perspective\", \"orthographic\"]";
const EXP_LIGHT = "any of: [\"directional\", \"point\", \"spot\"]";

function glEnum(de: De, n: SNode, expected: string): i64 {
    return de.visitU64(n, expected);
}

// Struct fields in declaration order (JSON names); `?` marks a field
// with a default, which a positional (sequence) struct may leave out.
const F_ACCESSOR = "bufferView ?byteOffset count componentType ?extensions ?extras type ?min ?max name ?normalized ?sparse";
const F_SPARSE = "count indices values ?extensions ?extras";
const F_INDICES = "bufferView ?byteOffset componentType ?extensions ?extras";
const F_VALUES = "bufferView ?byteOffset ?extensions ?extras";
const F_TARGET = "?extensions ?extras node path";
const F_CHANNEL = "sampler target ?extensions ?extras";
const F_SAMPLER_ANIM = "?extensions ?extras input ?interpolation output";
const F_ANIMATION = "?extensions ?extras channels name samplers";
const F_ASSET = "copyright ?extensions ?extras generator minVersion version";
const F_BUFFER = "?byteLength name uri ?extensions ?extras";
const F_VIEW = "buffer byteLength ?byteOffset byteStride name target ?extensions ?extras";
const F_ORTHOGRAPHIC = "xmag ymag zfar znear ?extensions ?extras";
const F_PERSPECTIVE = "aspectRatio yfov zfar znear ?extensions ?extras";
const F_CAMERA = "name orthographic perspective type ?extensions ?extras";
const F_IMAGE = "bufferView mimeType name uri ?extensions ?extras";
const F_INFO = "index ?texCoord ?extensions ?extras";
const F_NORMALTEXTURE = "index ?scale ?texCoord ?extensions ?extras";
const F_OCCLUSIONTEXTURE = "index ?strength ?texCoord ?extensions ?extras";
const F_PBRMETALLICROUGHNESS = "?baseColorFactor ?baseColorTexture ?metallicFactor ?roughnessFactor ?metallicRoughnessTexture ?extensions ?extras";
const F_MATERIAL = "?alphaCutoff ?alphaMode ?doubleSided ?name ?pbrMetallicRoughness ?normalTexture ?occlusionTexture ?emissiveTexture ?emissiveFactor ?extensions ?extras";
const F_MORPHTARGET = "POSITION NORMAL TANGENT";
const F_PRIMITIVE = "attributes ?extensions ?extras indices material ?mode targets";
const F_MESH = "?extensions ?extras name primitives weights";
const F_NODE = "camera children ?extensions ?extras matrix mesh name rotation scale translation skin weights";
const F_SAMPLER_TEX = "?magFilter ?minFilter ?name ?wrapS ?wrapT ?extensions ?extras";
const F_SCENE = "?extensions ?extras name nodes";
const F_SKIN = "?extensions ?extras inverseBindMatrices joints name skeleton";
const F_TEXTURE = "name sampler ?source ?extensions ?extras";
const F_SPOT = "?innerConeAngle ?outerConeAngle";
const F_LIGHT = "?color ?extensions ?extras ?intensity name ?range ?spot type";
const F_ROOT = "?accessors ?animations asset ?buffers ?bufferViews scene ?extensions ?extras ?extensionsUsed ?extensionsRequired ?cameras ?images ?materials ?meshes ?nodes ?samplers ?scenes ?skins ?textures";
const F_EMISSIVESTRENGTH = "?emissiveStrength";
const F_KHRLIGHTSPUNCTUAL_NODE = "light";
const F_KHRLIGHTSPUNCTUAL_ROOT = "lights";

// ---------------------------------------------------------------------------
// Extension containers

// A struct that is only a map of `others`: every entry, in order.
function deExtensions(de: De, n: SNode, name: string): Extensions? {
    if (n.kind == K_NULL) return null;
    if (!de.flatStruct(n, name)) return null;
    const e = new Extensions();
    for (let k = 0; k < n.keys.length; k++) e.others.insert(n.keys[k], de.value(n.kids[k]));
    return e;
}

// An empty struct (`struct Asset {}`): any map is accepted and dropped.
function deEmptyExtensions(de: De, n0: SNode, name: string): EmptyExtensions? {
    if (n0.kind == K_NULL) return null;
    const n = de.structNode(n0, name, "");
    if (n == null) return null;
    // Every field is unknown: its value is skipped.
    for (let k = 0; k < n.kids.length; k++) de.ignored(n.kids[k]);
    if (!de.endStruct(n0, n)) return null;
    return new EmptyExtensions();
}

// ---------------------------------------------------------------------------
// Structs

function deAccessor(de: De, n0: SNode): Accessor? {
    const n = de.structNode(n0, "Accessor", F_ACCESSOR);
    if (n == null) return null;
    const a = new Accessor();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "bufferView") {
            if (!seen.first(de, n, k, key)) return null;
            a.bufferView = de.optIndex(v);
        } else if (key == "byteOffset") {
            if (!seen.first(de, n, k, key)) return null;
            a.byteOffset = v.kind == K_NULL ? -1 : optSize(de.u64(v));
        } else if (key == "count") {
            if (!seen.first(de, n, k, key)) return null;
            a.count = de.u64(v);
        } else if (key == "componentType") {
            if (!seen.first(de, n, k, key)) return null;
            const g = glEnum(de, v, EXP_COMPONENT);
            if (g >= 0) a.componentType = componentTypeFromGl(<u32>g);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            a.extensions = deExtensions(de, v, "Accessor");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            a.extras = de.optRaw(v);
        } else if (key == "type") {
            if (!seen.first(de, n, k, key)) return null;
            const s = de.visitStr(v, EXP_ACCESSOR_TYPE);
            if (s != null) a.type_ = accessorTypeFromName(s);
        } else if (key == "min") {
            if (!seen.first(de, n, k, key)) return null;
            a.min = de.optValue(v);
        } else if (key == "max") {
            if (!seen.first(de, n, k, key)) return null;
            a.max = de.optValue(v);
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            a.name = de.optString(v);
        } else if (key == "normalized") {
            if (!seen.first(de, n, k, key)) return null;
            a.normalized = de.bool(v);
        } else if (key == "sparse") {
            if (!seen.first(de, n, k, key)) return null;
            a.sparse = v.kind == K_NULL ? null : deSparse(de, v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("count") && de.missingField(n, "count")) return null;
    if (!seen.has("componentType") && de.missingField(n, "componentType")) return null;
    if (!seen.has("type") && de.missingField(n, "type")) return null;
    if (!de.endStruct(n0, n)) return null;
    return a;
}

function deSparse(de: De, n0: SNode): Sparse? {
    const n = de.structNode(n0, "Sparse", F_SPARSE);
    if (n == null) return null;
    const s = new Sparse();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "count") {
            if (!seen.first(de, n, k, key)) return null;
            s.count = de.u64(v);
        } else if (key == "indices") {
            if (!seen.first(de, n, k, key)) return null;
            const i = deSparseIndices(de, v);
            if (i != null) s.indices = i;
        } else if (key == "values") {
            if (!seen.first(de, n, k, key)) return null;
            const x = deSparseValues(de, v);
            if (x != null) s.values = x;
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            s.extensions = deEmptyExtensions(de, v, "Sparse");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            s.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("count") && de.missingField(n, "count")) return null;
    if (!seen.has("indices") && de.missingField(n, "indices")) return null;
    if (!seen.has("values") && de.missingField(n, "values")) return null;
    if (!de.endStruct(n0, n)) return null;
    return s;
}

function deSparseIndices(de: De, n0: SNode): SparseIndices? {
    const n = de.structNode(n0, "Indices", F_INDICES);
    if (n == null) return null;
    const s = new SparseIndices();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "bufferView") {
            if (!seen.first(de, n, k, key)) return null;
            s.bufferView = de.index(v);
        } else if (key == "byteOffset") {
            if (!seen.first(de, n, k, key)) return null;
            s.byteOffset = de.u64(v);
        } else if (key == "componentType") {
            if (!seen.first(de, n, k, key)) return null;
            const g = glEnum(de, v, EXP_INDEX_COMPONENT);
            if (g >= 0) s.componentType = indexComponentTypeFromGl(<u32>g);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            s.extensions = deEmptyExtensions(de, v, "Indices");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            s.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("bufferView") && de.missingField(n, "bufferView")) return null;
    if (!seen.has("componentType") && de.missingField(n, "componentType")) return null;
    if (!de.endStruct(n0, n)) return null;
    return s;
}

function deSparseValues(de: De, n0: SNode): SparseValues? {
    const n = de.structNode(n0, "Values", F_VALUES);
    if (n == null) return null;
    const s = new SparseValues();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "bufferView") {
            if (!seen.first(de, n, k, key)) return null;
            s.bufferView = de.index(v);
        } else if (key == "byteOffset") {
            if (!seen.first(de, n, k, key)) return null;
            s.byteOffset = de.u64(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            s.extensions = deEmptyExtensions(de, v, "Values");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            s.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("bufferView") && de.missingField(n, "bufferView")) return null;
    if (!de.endStruct(n0, n)) return null;
    return s;
}

function deChannelTarget(de: De, n0: SNode): ChannelTarget? {
    const n = de.structNode(n0, "Target", F_TARGET);
    if (n == null) return null;
    const t = new ChannelTarget();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            t.extensions = deEmptyExtensions(de, v, "Target");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            t.extras = de.optRaw(v);
        } else if (key == "node") {
            if (!seen.first(de, n, k, key)) return null;
            t.node = de.index(v);
        } else if (key == "path") {
            if (!seen.first(de, n, k, key)) return null;
            const s = de.visitStr(v, EXP_PROPERTY);
            if (s != null) t.path = propertyFromName(s);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("node") && de.missingField(n, "node")) return null;
    if (!seen.has("path") && de.missingField(n, "path")) return null;
    if (!de.endStruct(n0, n)) return null;
    return t;
}

function deChannel(de: De, n0: SNode): Channel? {
    const n = de.structNode(n0, "Channel", F_CHANNEL);
    if (n == null) return null;
    const c = new Channel();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "sampler") {
            if (!seen.first(de, n, k, key)) return null;
            c.sampler = de.index(v);
        } else if (key == "target") {
            if (!seen.first(de, n, k, key)) return null;
            const t = deChannelTarget(de, v);
            if (t != null) c.target = t;
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            c.extensions = deEmptyExtensions(de, v, "Channel");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            c.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("sampler") && de.missingField(n, "sampler")) return null;
    if (!seen.has("target") && de.missingField(n, "target")) return null;
    if (!de.endStruct(n0, n)) return null;
    return c;
}

function deAnimationSampler(de: De, n0: SNode): AnimationSampler? {
    const n = de.structNode(n0, "Sampler", F_SAMPLER_ANIM);
    if (n == null) return null;
    const s = new AnimationSampler();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            s.extensions = deEmptyExtensions(de, v, "Sampler");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            s.extras = de.optRaw(v);
        } else if (key == "input") {
            if (!seen.first(de, n, k, key)) return null;
            s.input = de.index(v);
        } else if (key == "interpolation") {
            if (!seen.first(de, n, k, key)) return null;
            const str = de.visitStr(v, EXP_INTERPOLATION);
            if (str != null) s.interpolation = interpolationFromName(str);
        } else if (key == "output") {
            if (!seen.first(de, n, k, key)) return null;
            s.output = de.index(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("input") && de.missingField(n, "input")) return null;
    if (!seen.has("output") && de.missingField(n, "output")) return null;
    if (!de.endStruct(n0, n)) return null;
    return s;
}

function deAnimation(de: De, n0: SNode): Animation? {
    const n = de.structNode(n0, "Animation", F_ANIMATION);
    if (n == null) return null;
    const a = new Animation();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            a.extensions = deExtensions(de, v, "Animation");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            a.extras = de.optRaw(v);
        } else if (key == "channels") {
            if (!seen.first(de, n, k, key)) return null;
            if (de.seq(v)) {
                for (let i = 0; i < v.kids.length; i++) {
                    const c = deChannel(de, v.kids[i]);
                    if (c == null) return null;
                    a.channels.push(c);
                }
            }
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            a.name = de.optString(v);
        } else if (key == "samplers") {
            if (!seen.first(de, n, k, key)) return null;
            if (de.seq(v)) {
                for (let i = 0; i < v.kids.length; i++) {
                    const s = deAnimationSampler(de, v.kids[i]);
                    if (s == null) return null;
                    a.samplers.push(s);
                }
            }
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("channels") && de.missingField(n, "channels")) return null;
    if (!seen.has("samplers") && de.missingField(n, "samplers")) return null;
    if (!de.endStruct(n0, n)) return null;
    return a;
}

function deAsset(de: De, n0: SNode): Asset? {
    const n = de.structNode(n0, "Asset", F_ASSET);
    if (n == null) return null;
    const a = new Asset();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "copyright") {
            if (!seen.first(de, n, k, key)) return null;
            a.copyright = de.optString(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            a.extensions = deEmptyExtensions(de, v, "Asset");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            a.extras = de.optRaw(v);
        } else if (key == "generator") {
            if (!seen.first(de, n, k, key)) return null;
            a.generator = de.optString(v);
        } else if (key == "minVersion") {
            if (!seen.first(de, n, k, key)) return null;
            a.minVersion = de.optString(v);
        } else if (key == "version") {
            if (!seen.first(de, n, k, key)) return null;
            a.version = de.string(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("version") && de.missingField(n, "version")) return null;
    if (!de.endStruct(n0, n)) return null;
    return a;
}

function deBuffer(de: De, n0: SNode): Buffer? {
    const n = de.structNode(n0, "Buffer", F_BUFFER);
    if (n == null) return null;
    const b = new Buffer();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "byteLength") {
            if (!seen.first(de, n, k, key)) return null;
            b.byteLength = de.u64(v);
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            b.name = de.optString(v);
        } else if (key == "uri") {
            if (!seen.first(de, n, k, key)) return null;
            b.uri = de.optString(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            b.extensions = deExtensions(de, v, "Buffer");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            b.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!de.endStruct(n0, n)) return null;
    return b;
}

function deView(de: De, n0: SNode): BufferView? {
    const n = de.structNode(n0, "View", F_VIEW);
    if (n == null) return null;
    const b = new BufferView();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "buffer") {
            if (!seen.first(de, n, k, key)) return null;
            b.buffer = de.index(v);
        } else if (key == "byteLength") {
            if (!seen.first(de, n, k, key)) return null;
            b.byteLength = de.u64(v);
        } else if (key == "byteOffset") {
            if (!seen.first(de, n, k, key)) return null;
            b.byteOffset = v.kind == K_NULL ? -1 : optSize(de.u64(v));
        } else if (key == "byteStride") {
            if (!seen.first(de, n, k, key)) return null;
            b.byteStride = v.kind == K_NULL ? -1 : optSize(de.uint(v, u64.MAX_VALUE, "usize"));
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            b.name = de.optString(v);
        } else if (key == "target") {
            if (!seen.first(de, n, k, key)) return null;
            if (v.kind == K_NULL) {
                b.target = CHECKED_NONE;
            } else {
                const g = glEnum(de, v, EXP_TARGET);
                if (g >= 0) b.target = bufferTargetFromGl(<u32>g);
            }
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            b.extensions = deExtensions(de, v, "View");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            b.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("buffer") && de.missingField(n, "buffer")) return null;
    if (!seen.has("byteLength") && de.missingField(n, "byteLength")) return null;
    if (!de.endStruct(n0, n)) return null;
    return b;
}

function deOrthographic(de: De, n0: SNode): CameraOrthographic? {
    const n = de.structNode(n0, "Orthographic", F_ORTHOGRAPHIC);
    if (n == null) return null;
    const o = new CameraOrthographic();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "xmag") {
            if (!seen.first(de, n, k, key)) return null;
            o.xmag = de.f32(v);
        } else if (key == "ymag") {
            if (!seen.first(de, n, k, key)) return null;
            o.ymag = de.f32(v);
        } else if (key == "zfar") {
            if (!seen.first(de, n, k, key)) return null;
            o.zfar = de.f32(v);
        } else if (key == "znear") {
            if (!seen.first(de, n, k, key)) return null;
            o.znear = de.f32(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            o.extensions = deExtensions(de, v, "Orthographic");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            o.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("xmag") && de.missingField(n, "xmag")) return null;
    if (!seen.has("ymag") && de.missingField(n, "ymag")) return null;
    if (!seen.has("zfar") && de.missingField(n, "zfar")) return null;
    if (!seen.has("znear") && de.missingField(n, "znear")) return null;
    if (!de.endStruct(n0, n)) return null;
    return o;
}

function dePerspective(de: De, n0: SNode): CameraPerspective? {
    const n = de.structNode(n0, "Perspective", F_PERSPECTIVE);
    if (n == null) return null;
    const p = new CameraPerspective();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "aspectRatio") {
            if (!seen.first(de, n, k, key)) return null;
            p.aspectRatio = v.kind == K_NULL ? NaN : de.f32(v);
        } else if (key == "yfov") {
            if (!seen.first(de, n, k, key)) return null;
            p.yfov = de.f32(v);
        } else if (key == "zfar") {
            if (!seen.first(de, n, k, key)) return null;
            p.zfar = v.kind == K_NULL ? NaN : de.f32(v);
        } else if (key == "znear") {
            if (!seen.first(de, n, k, key)) return null;
            p.znear = de.f32(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            p.extensions = deExtensions(de, v, "Perspective");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            p.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("yfov") && de.missingField(n, "yfov")) return null;
    if (!seen.has("znear") && de.missingField(n, "znear")) return null;
    if (!de.endStruct(n0, n)) return null;
    return p;
}

function deCamera(de: De, n0: SNode): Camera? {
    const n = de.structNode(n0, "Camera", F_CAMERA);
    if (n == null) return null;
    const c = new Camera();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            c.name = de.optString(v);
        } else if (key == "orthographic") {
            if (!seen.first(de, n, k, key)) return null;
            c.orthographic = v.kind == K_NULL ? null : deOrthographic(de, v);
        } else if (key == "perspective") {
            if (!seen.first(de, n, k, key)) return null;
            c.perspective = v.kind == K_NULL ? null : dePerspective(de, v);
        } else if (key == "type") {
            if (!seen.first(de, n, k, key)) return null;
            const s = de.visitStr(v, EXP_CAMERA);
            if (s != null) c.type_ = cameraTypeFromName(s);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            c.extensions = deExtensions(de, v, "Camera");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            c.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("type") && de.missingField(n, "type")) return null;
    if (!de.endStruct(n0, n)) return null;
    return c;
}

function deImage(de: De, n0: SNode): Image? {
    const n = de.structNode(n0, "Image", F_IMAGE);
    if (n == null) return null;
    const im = new Image();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "bufferView") {
            if (!seen.first(de, n, k, key)) return null;
            im.bufferView = de.optIndex(v);
        } else if (key == "mimeType") {
            if (!seen.first(de, n, k, key)) return null;
            im.mimeType = de.optString(v);
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            im.name = de.optString(v);
        } else if (key == "uri") {
            if (!seen.first(de, n, k, key)) return null;
            im.uri = de.optString(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            im.extensions = deExtensions(de, v, "Image");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            im.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!de.endStruct(n0, n)) return null;
    return im;
}

function deTextureInfo(de: De, n0: SNode): TextureInfo? {
    const n = de.structNode(n0, "Info", F_INFO);
    if (n == null) return null;
    const t = new TextureInfo();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "index") {
            if (!seen.first(de, n, k, key)) return null;
            t.index = de.index(v);
        } else if (key == "texCoord") {
            if (!seen.first(de, n, k, key)) return null;
            t.texCoord = de.u32(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            t.extensions = deExtensions(de, v, "Info");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            t.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("index") && de.missingField(n, "index")) return null;
    if (!de.endStruct(n0, n)) return null;
    return t;
}

function deNormalTexture(de: De, n0: SNode): NormalTexture? {
    const n = de.structNode(n0, "NormalTexture", F_NORMALTEXTURE);
    if (n == null) return null;
    const t = new NormalTexture();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "index") {
            if (!seen.first(de, n, k, key)) return null;
            t.index = de.index(v);
        } else if (key == "scale") {
            if (!seen.first(de, n, k, key)) return null;
            t.scale = de.f32(v);
        } else if (key == "texCoord") {
            if (!seen.first(de, n, k, key)) return null;
            t.texCoord = de.u32(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            t.extensions = deExtensions(de, v, "NormalTexture");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            t.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("index") && de.missingField(n, "index")) return null;
    if (!de.endStruct(n0, n)) return null;
    return t;
}

function deOcclusionTexture(de: De, n0: SNode): OcclusionTexture? {
    const n = de.structNode(n0, "OcclusionTexture", F_OCCLUSIONTEXTURE);
    if (n == null) return null;
    const t = new OcclusionTexture();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "index") {
            if (!seen.first(de, n, k, key)) return null;
            t.index = de.index(v);
        } else if (key == "strength") {
            if (!seen.first(de, n, k, key)) return null;
            t.strength = de.f32(v);
        } else if (key == "texCoord") {
            if (!seen.first(de, n, k, key)) return null;
            t.texCoord = de.u32(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            t.extensions = deExtensions(de, v, "OcclusionTexture");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            t.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("index") && de.missingField(n, "index")) return null;
    if (!de.endStruct(n0, n)) return null;
    return t;
}

function dePbr(de: De, n0: SNode): PbrMetallicRoughness? {
    const n = de.structNode(n0, "PbrMetallicRoughness", F_PBRMETALLICROUGHNESS);
    if (n == null) return null;
    const p = new PbrMetallicRoughness();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "baseColorFactor") {
            if (!seen.first(de, n, k, key)) return null;
            p.baseColorFactor = de.f32Array(v, 4);
        } else if (key == "baseColorTexture") {
            if (!seen.first(de, n, k, key)) return null;
            p.baseColorTexture = v.kind == K_NULL ? null : deTextureInfo(de, v);
        } else if (key == "metallicFactor") {
            if (!seen.first(de, n, k, key)) return null;
            p.metallicFactor = de.f32(v);
        } else if (key == "roughnessFactor") {
            if (!seen.first(de, n, k, key)) return null;
            p.roughnessFactor = de.f32(v);
        } else if (key == "metallicRoughnessTexture") {
            if (!seen.first(de, n, k, key)) return null;
            p.metallicRoughnessTexture = v.kind == K_NULL ? null : deTextureInfo(de, v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            p.extensions = deExtensions(de, v, "PbrMetallicRoughness");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            p.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!de.endStruct(n0, n)) return null;
    return p;
}

function deEmissiveStrength(de: De, n0: SNode): EmissiveStrength? {
    const n = de.structNode(n0, "EmissiveStrength", F_EMISSIVESTRENGTH);
    if (n == null) return null;
    const es = new EmissiveStrength();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "emissiveStrength") {
            if (!seen.first(de, n, k, key)) return null;
            es.emissiveStrength = de.f32(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!de.endStruct(n0, n)) return null;
    return es;
}

function deMaterialExtensions(de: De, n: SNode): MaterialExtensions? {
    if (n.kind == K_NULL) return null;
    if (!de.flatStruct(n, "Material")) return null;
    const e = new MaterialExtensions();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == KHR_MATERIALS_EMISSIVE_STRENGTH) {
            if (!seen.first(de, n, k, key)) return null;
            e.emissiveStrength = v.kind == K_NULL ? null : deEmissiveStrength(de, v);
        } else {
            e.others.insert(key, de.value(v));
        }
        if (de.failed) return null;
    }
    return e;
}

function deMaterial(de: De, n0: SNode): Material? {
    const n = de.structNode(n0, "Material", F_MATERIAL);
    if (n == null) return null;
    const m = new Material();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "alphaCutoff") {
            if (!seen.first(de, n, k, key)) return null;
            m.alphaCutoff = v.kind == K_NULL ? NaN : de.f32(v);
        } else if (key == "alphaMode") {
            if (!seen.first(de, n, k, key)) return null;
            const s = de.visitStr(v, EXP_ALPHA);
            if (s != null) m.alphaMode = alphaModeFromName(s);
        } else if (key == "doubleSided") {
            if (!seen.first(de, n, k, key)) return null;
            m.doubleSided = de.bool(v);
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            m.name = de.optString(v);
        } else if (key == "pbrMetallicRoughness") {
            if (!seen.first(de, n, k, key)) return null;
            const p = dePbr(de, v);
            if (p != null) m.pbrMetallicRoughness = p;
        } else if (key == "normalTexture") {
            if (!seen.first(de, n, k, key)) return null;
            m.normalTexture = v.kind == K_NULL ? null : deNormalTexture(de, v);
        } else if (key == "occlusionTexture") {
            if (!seen.first(de, n, k, key)) return null;
            m.occlusionTexture = v.kind == K_NULL ? null : deOcclusionTexture(de, v);
        } else if (key == "emissiveTexture") {
            if (!seen.first(de, n, k, key)) return null;
            m.emissiveTexture = v.kind == K_NULL ? null : deTextureInfo(de, v);
        } else if (key == "emissiveFactor") {
            if (!seen.first(de, n, k, key)) return null;
            m.emissiveFactor = de.f32Array(v, 3);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            m.extensions = deMaterialExtensions(de, v);
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            m.extras = de.optRaw(v);
        }
        if (de.failed) return null;
    }
    if (!de.endStruct(n0, n)) return null;
    return m;
}

function deMorphTarget(de: De, n0: SNode): MorphTarget? {
    const n = de.structNode(n0, "MorphTarget", F_MORPHTARGET);
    if (n == null) return null;
    const t = new MorphTarget();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "POSITION") {
            if (!seen.first(de, n, k, key)) return null;
            t.positions = de.optIndex(v);
        } else if (key == "NORMAL") {
            if (!seen.first(de, n, k, key)) return null;
            t.normals = de.optIndex(v);
        } else if (key == "TANGENT") {
            if (!seen.first(de, n, k, key)) return null;
            t.tangents = de.optIndex(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!de.endStruct(n0, n)) return null;
    return t;
}

function dePrimitive(de: De, n0: SNode): Primitive? {
    const n = de.structNode(n0, "Primitive", F_PRIMITIVE);
    if (n == null) return null;
    const p = new Primitive();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "attributes") {
            if (!seen.first(de, n, k, key)) return null;
            if (v.kind != K_OBJECT) {
                de.invalidType(v, "a map");
                return null;
            }
            for (let j = 0; j < v.keys.length; j++) {
                const sem = Semantic.checked(v.keys[j]);
                const acc = de.index(v.kids[j]);
                if (de.failed) return null;
                p.attributes.insert(sem, acc);
            }
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            p.extensions = deExtensions(de, v, "Primitive");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            p.extras = de.optRaw(v);
        } else if (key == "indices") {
            if (!seen.first(de, n, k, key)) return null;
            p.indices = de.optIndex(v);
        } else if (key == "material") {
            if (!seen.first(de, n, k, key)) return null;
            p.material = de.optIndex(v);
        } else if (key == "mode") {
            if (!seen.first(de, n, k, key)) return null;
            const g = glEnum(de, v, EXP_MODE);
            if (g >= 0) p.mode = modeFromGl(<u32>g);
        } else if (key == "targets") {
            if (!seen.first(de, n, k, key)) return null;
            if (v.kind == K_NULL) {
                p.targets = null;
            } else if (de.seq(v)) {
                const ts: Array<MorphTarget> = [];
                for (let j = 0; j < v.kids.length; j++) {
                    const t = deMorphTarget(de, v.kids[j]);
                    if (t == null) return null;
                    ts.push(t);
                }
                p.targets = ts;
            }
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("attributes") && de.missingField(n, "attributes")) return null;
    if (!de.endStruct(n0, n)) return null;
    return p;
}

function deMesh(de: De, n0: SNode): Mesh? {
    const n = de.structNode(n0, "Mesh", F_MESH);
    if (n == null) return null;
    const m = new Mesh();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            m.extensions = deExtensions(de, v, "Mesh");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            m.extras = de.optRaw(v);
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            m.name = de.optString(v);
        } else if (key == "primitives") {
            if (!seen.first(de, n, k, key)) return null;
            if (de.seq(v)) {
                for (let j = 0; j < v.kids.length; j++) {
                    const p = dePrimitive(de, v.kids[j]);
                    if (p == null) return null;
                    m.primitives.push(p);
                }
            }
        } else if (key == "weights") {
            if (!seen.first(de, n, k, key)) return null;
            m.weights = de.optF32Vec(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("primitives") && de.missingField(n, "primitives")) return null;
    if (!de.endStruct(n0, n)) return null;
    return m;
}

function deNodeLightRef(de: De, n0: SNode): NodeLightRef? {
    const n = de.structNode(n0, "KhrLightsPunctual", F_KHRLIGHTSPUNCTUAL_NODE);
    if (n == null) return null;
    const r = new NodeLightRef();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "light") {
            if (!seen.first(de, n, k, key)) return null;
            r.light = de.index(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("light") && de.missingField(n, "light")) return null;
    if (!de.endStruct(n0, n)) return null;
    return r;
}

function deNodeExtensions(de: De, n: SNode): NodeExtensions? {
    if (n.kind == K_NULL) return null;
    if (!de.flatStruct(n, "Node")) return null;
    const e = new NodeExtensions();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == KHR_LIGHTS_PUNCTUAL) {
            if (!seen.first(de, n, k, key)) return null;
            e.khrLightsPunctual = v.kind == K_NULL ? null : deNodeLightRef(de, v);
        } else {
            e.others.insert(key, de.value(v));
        }
        if (de.failed) return null;
    }
    return e;
}

function deNode(de: De, n0: SNode): Node? {
    const n = de.structNode(n0, "Node", F_NODE);
    if (n == null) return null;
    const node = new Node();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "camera") {
            if (!seen.first(de, n, k, key)) return null;
            node.camera = de.optIndex(v);
        } else if (key == "children") {
            if (!seen.first(de, n, k, key)) return null;
            node.children = v.kind == K_NULL ? null : de.indexVec(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            node.extensions = deNodeExtensions(de, v);
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            node.extras = de.optRaw(v);
        } else if (key == "matrix") {
            if (!seen.first(de, n, k, key)) return null;
            node.matrix = de.optF32Array(v, 16);
        } else if (key == "mesh") {
            if (!seen.first(de, n, k, key)) return null;
            node.mesh = de.optIndex(v);
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            node.name = de.optString(v);
        } else if (key == "rotation") {
            if (!seen.first(de, n, k, key)) return null;
            node.rotation = de.optF32Array(v, 4);
        } else if (key == "scale") {
            if (!seen.first(de, n, k, key)) return null;
            node.scale = de.optF32Array(v, 3);
        } else if (key == "translation") {
            if (!seen.first(de, n, k, key)) return null;
            node.translation = de.optF32Array(v, 3);
        } else if (key == "skin") {
            if (!seen.first(de, n, k, key)) return null;
            node.skin = de.optIndex(v);
        } else if (key == "weights") {
            if (!seen.first(de, n, k, key)) return null;
            node.weights = de.optF32Vec(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!de.endStruct(n0, n)) return null;
    return node;
}

function deSampler(de: De, n0: SNode): Sampler? {
    const n = de.structNode(n0, "Sampler", F_SAMPLER_TEX);
    if (n == null) return null;
    const s = new Sampler();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "magFilter") {
            if (!seen.first(de, n, k, key)) return null;
            if (v.kind == K_NULL) {
                s.magFilter = CHECKED_NONE;
            } else {
                const g = glEnum(de, v, EXP_MAG);
                if (g >= 0) s.magFilter = magFilterFromGl(<u32>g);
            }
        } else if (key == "minFilter") {
            if (!seen.first(de, n, k, key)) return null;
            if (v.kind == K_NULL) {
                s.minFilter = CHECKED_NONE;
            } else {
                const g = glEnum(de, v, EXP_MIN);
                if (g >= 0) s.minFilter = minFilterFromGl(<u32>g);
            }
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            s.name = de.optString(v);
        } else if (key == "wrapS") {
            if (!seen.first(de, n, k, key)) return null;
            const g = glEnum(de, v, EXP_WRAP);
            if (g >= 0) s.wrapS = wrappingModeFromGl(<u32>g);
        } else if (key == "wrapT") {
            if (!seen.first(de, n, k, key)) return null;
            const g = glEnum(de, v, EXP_WRAP);
            if (g >= 0) s.wrapT = wrappingModeFromGl(<u32>g);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            s.extensions = deExtensions(de, v, "Sampler");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            s.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!de.endStruct(n0, n)) return null;
    return s;
}

function deScene(de: De, n0: SNode): Scene? {
    const n = de.structNode(n0, "Scene", F_SCENE);
    if (n == null) return null;
    const s = new Scene();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            s.extensions = deExtensions(de, v, "Scene");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            s.extras = de.optRaw(v);
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            s.name = de.optString(v);
        } else if (key == "nodes") {
            if (!seen.first(de, n, k, key)) return null;
            s.nodes = de.indexVec(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("nodes") && de.missingField(n, "nodes")) return null;
    if (!de.endStruct(n0, n)) return null;
    return s;
}

function deSkin(de: De, n0: SNode): Skin? {
    const n = de.structNode(n0, "Skin", F_SKIN);
    if (n == null) return null;
    const s = new Skin();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            s.extensions = deExtensions(de, v, "Skin");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            s.extras = de.optRaw(v);
        } else if (key == "inverseBindMatrices") {
            if (!seen.first(de, n, k, key)) return null;
            s.inverseBindMatrices = de.optIndex(v);
        } else if (key == "joints") {
            if (!seen.first(de, n, k, key)) return null;
            s.joints = de.indexVec(v);
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            s.name = de.optString(v);
        } else if (key == "skeleton") {
            if (!seen.first(de, n, k, key)) return null;
            s.skeleton = de.optIndex(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("joints") && de.missingField(n, "joints")) return null;
    if (!de.endStruct(n0, n)) return null;
    return s;
}

function deTexture(de: De, n0: SNode): Texture? {
    const n = de.structNode(n0, "Texture", F_TEXTURE);
    if (n == null) return null;
    const t = new Texture();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            t.name = de.optString(v);
        } else if (key == "sampler") {
            if (!seen.first(de, n, k, key)) return null;
            t.sampler = de.optIndex(v);
        } else if (key == "source") {
            if (!seen.first(de, n, k, key)) return null;
            const g = de.visitU64(v, "index into child of root");
            if (g >= 0) t.source = <u32>g;
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            t.extensions = deExtensions(de, v, "Texture");
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            t.extras = de.optRaw(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!de.endStruct(n0, n)) return null;
    return t;
}

function deSpot(de: De, n0: SNode): KhrLightSpot? {
    const n = de.structNode(n0, "Spot", F_SPOT);
    if (n == null) return null;
    const s = new KhrLightSpot();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "innerConeAngle") {
            if (!seen.first(de, n, k, key)) return null;
            s.innerConeAngle = de.f32(v);
        } else if (key == "outerConeAngle") {
            if (!seen.first(de, n, k, key)) return null;
            s.outerConeAngle = de.f32(v);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!de.endStruct(n0, n)) return null;
    return s;
}

function deLight(de: De, n0: SNode): KhrLight? {
    const n = de.structNode(n0, "Light", F_LIGHT);
    if (n == null) return null;
    const l = new KhrLight();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "color") {
            if (!seen.first(de, n, k, key)) return null;
            l.color = de.f32Array(v, 3);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            l.extensions = de.optRaw(v);
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            l.extras = de.optRaw(v);
        } else if (key == "intensity") {
            if (!seen.first(de, n, k, key)) return null;
            l.intensity = de.f32(v);
        } else if (key == "name") {
            if (!seen.first(de, n, k, key)) return null;
            l.name = de.optString(v);
        } else if (key == "range") {
            if (!seen.first(de, n, k, key)) return null;
            l.range = v.kind == K_NULL ? NaN : de.f32(v);
        } else if (key == "spot") {
            if (!seen.first(de, n, k, key)) return null;
            l.spot = v.kind == K_NULL ? null : deSpot(de, v);
        } else if (key == "type") {
            if (!seen.first(de, n, k, key)) return null;
            const s = de.visitStr(v, EXP_LIGHT);
            if (s != null) l.type_ = khrLightTypeFromName(s);
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("type") && de.missingField(n, "type")) return null;
    if (!de.endStruct(n0, n)) return null;
    return l;
}

function deKhrLightsPunctual(de: De, n0: SNode): KhrLightsPunctual? {
    const n = de.structNode(n0, "KhrLightsPunctual", F_KHRLIGHTSPUNCTUAL_ROOT);
    if (n == null) return null;
    const kl = new KhrLightsPunctual();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "lights") {
            if (!seen.first(de, n, k, key)) return null;
            if (de.seq(v)) {
                for (let i = 0; i < v.kids.length; i++) {
                    const l = deLight(de, v.kids[i]);
                    if (l == null) return null;
                    kl.lights.push(l);
                }
            }
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("lights") && de.missingField(n, "lights")) return null;
    if (!de.endStruct(n0, n)) return null;
    return kl;
}

function deRootExtensions(de: De, n: SNode): RootExtensions? {
    if (n.kind == K_NULL) return null;
    if (!de.flatStruct(n, "Root")) return null;
    const e = new RootExtensions();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == KHR_LIGHTS_PUNCTUAL) {
            if (!seen.first(de, n, k, key)) return null;
            e.khrLightsPunctual = v.kind == K_NULL ? null : deKhrLightsPunctual(de, v);
        } else {
            e.others.insert(key, de.value(v));
        }
        if (de.failed) return null;
    }
    return e;
}

function deRoot(de: De, n0: SNode): Root? {
    const n = de.structNode(n0, "Root", F_ROOT);
    if (n == null) return null;
    const r = new Root();
    const seen = new Seen();
    for (let k = 0; k < n.keys.length; k++) {
        const key = n.keys[k];
        const v = n.kids[k];
        if (key == "accessors") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deAccessor(de, v.kids[i]);
                if (x == null) return null;
                r.accessors.push(x);
            }
        } else if (key == "animations") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deAnimation(de, v.kids[i]);
                if (x == null) return null;
                r.animations.push(x);
            }
        } else if (key == "asset") {
            if (!seen.first(de, n, k, key)) return null;
            const a = deAsset(de, v);
            if (a == null) return null;
            r.asset = a;
        } else if (key == "buffers") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deBuffer(de, v.kids[i]);
                if (x == null) return null;
                r.buffers.push(x);
            }
        } else if (key == "bufferViews") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deView(de, v.kids[i]);
                if (x == null) return null;
                r.bufferViews.push(x);
            }
        } else if (key == "scene") {
            if (!seen.first(de, n, k, key)) return null;
            r.scene = de.optIndex(v);
        } else if (key == "extensions") {
            if (!seen.first(de, n, k, key)) return null;
            r.extensions = deRootExtensions(de, v);
        } else if (key == "extras") {
            if (!seen.first(de, n, k, key)) return null;
            r.extras = de.optRaw(v);
        } else if (key == "extensionsUsed") {
            if (!seen.first(de, n, k, key)) return null;
            r.extensionsUsed = de.stringVec(v);
        } else if (key == "extensionsRequired") {
            if (!seen.first(de, n, k, key)) return null;
            r.extensionsRequired = de.stringVec(v);
        } else if (key == "cameras") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deCamera(de, v.kids[i]);
                if (x == null) return null;
                r.cameras.push(x);
            }
        } else if (key == "images") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deImage(de, v.kids[i]);
                if (x == null) return null;
                r.images.push(x);
            }
        } else if (key == "materials") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deMaterial(de, v.kids[i]);
                if (x == null) return null;
                r.materials.push(x);
            }
        } else if (key == "meshes") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deMesh(de, v.kids[i]);
                if (x == null) return null;
                r.meshes.push(x);
            }
        } else if (key == "nodes") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deNode(de, v.kids[i]);
                if (x == null) return null;
                r.nodes.push(x);
            }
        } else if (key == "samplers") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deSampler(de, v.kids[i]);
                if (x == null) return null;
                r.samplers.push(x);
            }
        } else if (key == "scenes") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deScene(de, v.kids[i]);
                if (x == null) return null;
                r.scenes.push(x);
            }
        } else if (key == "skins") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deSkin(de, v.kids[i]);
                if (x == null) return null;
                r.skins.push(x);
            }
        } else if (key == "textures") {
            if (!seen.first(de, n, k, key)) return null;
            if (!de.seq(v)) return null;
            for (let i = 0; i < v.kids.length; i++) {
                const x = deTexture(de, v.kids[i]);
                if (x == null) return null;
                r.textures.push(x);
            }
        } else {
            de.ignored(v);
        }
        if (de.failed) return null;
    }
    if (!seen.has("asset") && de.missingField(n, "asset")) return null;
    if (!de.endStruct(n0, n)) return null;
    return r;
}

// ---------------------------------------------------------------------------
// Entry points

// The byte offset of a (line, column) position (1-based lines).
function offsetOf(b: Uint8Array, line: i32, column: i32): i32 {
    let at = 0;
    for (let l = 1; l < line; l++) {
        while (at < b.length && <i32>b[at] != 10) at++;
        at++;
    }
    return at + column;
}

// A failed strict (json.as) parse as a decode error for `bytes`.
function syntaxError(syntax: Result<JsonValue>, bytes: Uint8Array, ioRead: bool): Result<Root> {
    const c = syntax.cause;
    const isJson = c instanceof JsonError;
    if (isJson && ioRead) {
        // NumberOutOfRange is raised with the byte after the number
        // peeked, which IoRead has already counted.
        const je = c as JsonError;
        if (je.code == JsonErrorCode.NumberOutOfRange) {
            const at = offsetOf(bytes, je.line, je.column);
            if (at < bytes.length) {
                const de = new De(bytes, true);
                de.fail(jsonErrorCodeText(je.code), at, true);
                return Result.failWith<Root>(de.error());
            }
        }
    }
    return syntax.forward<Root>();
}

// Whether `b` is a JSON text by the lenient grammar used for skipped
// values: strings may hold any bytes but control characters (no UTF-8
// check) and any `\uXXXX` (lone surrogates too), numbers are only checked
// for syntax (not range), and nesting has no limit. Iterative.
export function lenientValid(b: Uint8Array): bool {
    const n = b.length;
    let i = 0;
    // Open containers: 1 = array, 2 = object.
    const stack: Array<i32> = [];
    // Expecting a value (after `[`, `,` in an array, `:`), else the end of
    // one (`,` or the closing bracket).
    let wantValue = true;
    let first = false; // right after `[` / `{`: the closing bracket may come
    while (true) {
        while (i < n && isWs(<i32>b[i])) i++;
        if (wantValue) {
            if (i >= n) return false;
            let c = <i32>b[i];
            if (first && (c == 93 || c == 125)) {
                const top = stack.pop();
                if ((top == 1) != (c == 93)) return false;
                i++;
                first = false;
                wantValue = false;
                if (stack.length == 0) break;
                continue;
            }
            const top = stack.length > 0 ? stack[stack.length - 1] : 0;
            if (top == 2) {
                // a key, then `:`
                if (c != 34) return false;
                i = lenientString(b, i);
                if (i < 0) return false;
                while (i < n && isWs(<i32>b[i])) i++;
                if (i >= n || <i32>b[i] != 58) return false;
                i++;
                while (i < n && isWs(<i32>b[i])) i++;
                if (i >= n) return false;
                c = <i32>b[i];
            }
            first = false;
            if (c == 91 || c == 123) {
                stack.push(c == 91 ? 1 : 2);
                i++;
                first = true;
                continue;
            }
            if (c == 34) {
                i = lenientString(b, i);
            } else if (c == 116) {
                i = lenientIdent(b, i, "true");
            } else if (c == 102) {
                i = lenientIdent(b, i, "false");
            } else if (c == 110) {
                i = lenientIdent(b, i, "null");
            } else {
                i = lenientNumber(b, i);
            }
            if (i < 0) return false;
            wantValue = false;
            if (stack.length == 0) break;
            continue;
        }
        // after a value inside a container
        if (i >= n) return false;
        const c = <i32>b[i];
        const top = stack[stack.length - 1];
        if (c == 44) {
            i++;
            wantValue = true;
            continue;
        }
        if ((top == 1 && c == 93) || (top == 2 && c == 125)) {
            stack.pop();
            i++;
            if (stack.length == 0) break;
            continue;
        }
        return false;
    }
    while (i < n && isWs(<i32>b[i])) i++;
    return i == n;
}

function isHex(c: i32): bool {
    return (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);
}

// ignore_str from the opening quote at `i`: the index after the closing
// quote, or -1.
function lenientString(b: Uint8Array, i: i32): i32 {
    const n = b.length;
    i++;
    while (i < n) {
        const c = <i32>b[i];
        if (c == 34) return i + 1;
        if (c < 0x20) return -1;
        if (c == 92) {
            if (i + 1 >= n) return -1;
            const e = <i32>b[i + 1];
            if (e == 117) {
                if (i + 5 >= n) return -1;
                for (let k = 2; k < 6; k++) if (!isHex(<i32>b[i + k])) return -1;
                i += 6;
                continue;
            }
            if (e != 34 && e != 92 && e != 47 && e != 98 && e != 102 && e != 110 && e != 114 && e != 116) return -1;
            i += 2;
            continue;
        }
        i++;
    }
    return -1;
}

function lenientIdent(b: Uint8Array, i: i32, word: string): i32 {
    for (let k = 0; k < word.length; k++) {
        if (i + k >= b.length || <i32>b[i + k] != word.charCodeAt(k)) return -1;
    }
    return i + word.length;
}

// ignore_number: `-`? int frac? exp?, syntax only.
function lenientNumber(b: Uint8Array, i: i32): i32 {
    const n = b.length;
    if (i < n && <i32>b[i] == 45) i++;
    if (i >= n) return -1;
    let c = <i32>b[i];
    if (c == 48) {
        i++;
        if (i < n && <i32>b[i] >= 48 && <i32>b[i] <= 57) return -1;
    } else if (c >= 49 && c <= 57) {
        while (i < n && <i32>b[i] >= 48 && <i32>b[i] <= 57) i++;
    } else {
        return -1;
    }
    if (i < n && <i32>b[i] == 46) {
        i++;
        const s = i;
        while (i < n && <i32>b[i] >= 48 && <i32>b[i] <= 57) i++;
        if (i == s) return -1;
    }
    if (i < n && (<i32>b[i] == 101 || <i32>b[i] == 69)) {
        i++;
        if (i < n && (<i32>b[i] == 43 || <i32>b[i] == 45)) i++;
        const s = i;
        while (i < n && <i32>b[i] >= 48 && <i32>b[i] <= 57) i++;
        if (i == s) return -1;
    }
    return i;
}

// `bytes` with every skipped span blanked to `0` and spaces (newlines kept,
// so every other byte keeps its line and column).
function sanitized(bytes: Uint8Array, spans: Array<i32>): Uint8Array {
    const out = bytes.slice(0);
    for (let k = 0; k + 1 < spans.length; k += 2) {
        const s = spans[k];
        const e = spans[k + 1];
        out[s] = 48;
        for (let i = s + 1; i < e; i++) if (out[i] != 10) out[i] = 32;
    }
    return out;
}

// Decodes the JSON of a `.glb` chunk (ioRead = false) or of a `.gltf` file
// (ioRead = true). The error is a DeError, or the JsonError of a syntax
// error.
//
// A text json.as parses is decoded directly. One it rejects may still be
// one the decoder accepts: only what is decoded is parsed strictly, and
// ignored fields and raw values (`extras`) with a
// lenient grammar (no UTF-8, surrogate, number range or depth checks). Such
// a text is decoded anyway, recording the skipped spans; the strict parse is
// then rerun with those spans blanked, and the earlier of its error and the
// typed error is reported.
export function rootFromBytes(bytes: Uint8Array, ioRead: bool): Result<Root> {
    const syntax = parseJsonBytes(bytes);
    if (syntax.ok) {
        const tree = new Scanner(bytes).value();
        const de = new De(bytes, ioRead);
        const root = deRoot(de, tree);
        if (de.failed || root == null) return Result.failWith<Root>(de.error());
        return Result.okv<Root>(root);
    }
    // A structural error is reported wherever it is: the strict error.
    if (!lenientValid(bytes)) return syntaxError(syntax, bytes, ioRead);
    const tree = new Scanner(bytes).value();
    const de = new De(bytes, ioRead);
    const root = deRoot(de, tree);
    const strict = parseJsonBytes(sanitized(bytes, de.skipped));
    if (!strict.ok) {
        const c = strict.cause;
        const isJson = c instanceof JsonError;
        let at = i32.MAX_VALUE;
        if (isJson) {
            const je = c as JsonError;
            at = offsetOf(bytes, je.line, je.column);
        }
        // Parsing comes before visiting: a tie goes to the parse error.
        if (!de.failed || at <= de.pos) return syntaxError(strict, bytes, ioRead);
    }
    if (de.failed || root == null) return Result.failWith<Root>(de.error());
    return Result.okv<Root>(root);
}

// Decodes a JSON string (with the `.glb` chunk position rules).
export function rootFromStr(s: string): Result<Root> {
    return rootFromBytes(Uint8Array.wrap(String.UTF8.encode(s)), false);
}
