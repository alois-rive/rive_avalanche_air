// postcard 1.1.3 wire format: the
// primitive writer and reader the scene file, undo ring and snapshot codecs
// are built from (engine/src/source/model/io/codec.as, engine/src/authoring/model_project/undo.as).
//
// postcard is positional and not self-describing:
//   bool            1 byte, 0 or 1 (anything else is an error)
//   u8              1 raw byte
//   u16/u32/u64     unsigned LEB128 varint (at most 3 / 5 / 10 bytes)
//   usize           a u64 varint (counts and lengths)
//   i32             zigzag, then a u32 varint
//   f32 / f64       4 / 8 bytes little endian
//   String          varint byte length + UTF-8
//   Vec / map       varint count + items (a map: key, value per entry)
//   Option<T>       0x00, or 0x01 then T
//   enum            varint variant index (u32) + the variant's fields
//   struct, tuple, fixed array, vector/matrix types   the fields in order, no prefix
//
// The reader is exactly as strict as postcard's `from_bytes`: the same
// inputs fail with the same PostcardError, and trailing bytes after the
// value are ignored. Errors are sticky: after the first one every read
// returns a default value without consuming input, so a decoder can read on
// and check `failed` once (loops over lengths must stop on `failed`).

// postcard::Error, in declaration order.
export enum PostcardError {
    None = -1,
    WontImplement = 0,
    NotYetImplemented,
    SerializeBufferFull,
    SerializeSeqLengthUnknown,
    DeserializeUnexpectedEnd,
    DeserializeBadVarint,
    DeserializeBadBool,
    DeserializeBadChar,
    DeserializeBadUtf8,
    DeserializeBadOption,
    DeserializeBadEnum,
    DeserializeBadEncoding,
    DeserializeBadCrc,
    SerdeSerCustom,
    SerdeDeCustom,
    CollectStrError,
}

// The message of a postcard error (user-visible).
export function postcardErrorText(e: PostcardError): string {
    switch (e) {
        case PostcardError.WontImplement: return "This is a feature that PostCard will never implement";
        case PostcardError.NotYetImplemented: return "This is a feature that Postcard intends to support, but does not yet";
        case PostcardError.SerializeBufferFull: return "The serialize buffer is full";
        case PostcardError.SerializeSeqLengthUnknown: return "The length of a sequence must be known";
        case PostcardError.DeserializeUnexpectedEnd: return "Hit the end of buffer, expected more data";
        case PostcardError.DeserializeBadVarint: return "Found a varint that didn't terminate. Is the usize too big for this platform?";
        case PostcardError.DeserializeBadBool: return "Found a bool that wasn't 0 or 1";
        case PostcardError.DeserializeBadChar: return "Found an invalid unicode char";
        case PostcardError.DeserializeBadUtf8: return "Tried to parse invalid utf-8";
        case PostcardError.DeserializeBadOption: return "Found an Option discriminant that wasn't 0 or 1";
        case PostcardError.DeserializeBadEnum: return "Found an enum discriminant that was > u32::max_value()";
        case PostcardError.DeserializeBadEncoding: return "The original data was not well encoded";
        case PostcardError.DeserializeBadCrc: return "Bad CRC while deserializing";
        case PostcardError.SerdeSerCustom: return "Serialization Error";
        case PostcardError.SerdeDeCustom: return "Found an enum variant index that was out of range";
        case PostcardError.CollectStrError: return "Error while processing `collect_str` during serialization";
        default: return "";
    }
}

// ---------------------------------------------------------------------------
// Writer

export class PostcardWriter {
    // The bytes so far live in an unmanaged heap block grown with
    // __realloc (heap.realloc), and finish() copies them out. Under the stub runtime
    // (which never frees) the block at the end of the heap grows and shrinks
    // in place, where a doubling Uint8Array left every outgrown copy behind:
    // encoding a 79 MB scene allocated ~330 MB, now ~160 MB. Nothing here
    // allocates between two growths (str() encodes in place), so they stay
    // at the end of the heap.
    private ptr: usize = 0;
    private cap: i32 = 0;
    len: i32 = 0;

    private reserve(n: i32): void {
        const need = this.len + n;
        if (need <= this.cap) return;
        let cap = this.cap * 2;
        if (cap < 64) cap = 64;
        if (cap < need) cap = need;
        this.ptr = reallocBlock(this.ptr, cap);
        this.cap = cap;
    }

    u8(v: u8): void {
        this.reserve(1);
        storeU8(this.ptr, this.len, v);
        this.len++;
    }

    bool(b: bool): void {
        this.u8(b ? 1 : 0);
    }

    // Unsigned LEB128 (postcard's varint for every unsigned width).
    varU64(v: u64): void {
        this.reserve(10);
        let x = v;
        while (x >= 0x80) {
            storeU8(this.ptr, this.len, <u8>((x & 0x7F) | 0x80));
            this.len++;
            x >>= 7;
        }
        storeU8(this.ptr, this.len, <u8>x);
        this.len++;
    }

    varU32(v: u32): void {
        this.varU64(<u64>v);
    }

    varU16(v: u16): void {
        this.varU64(<u64>v);
    }

    // usize: a u64 varint.
    varUsize(v: u64): void {
        this.varU64(v);
    }

    // i32: zigzag, then a u32 varint.
    i32(v: i32): void {
        this.varU32(<u32>((v << 1) ^ (v >> 31)));
    }

    f32(v: f32): void {
        this.reserve(4);
        storeU32(this.ptr, this.len, reinterpret<u32>(v));
        this.len += 4;
    }

    f64(v: f64): void {
        this.reserve(8);
        storeU64(this.ptr, this.len, reinterpret<u64>(v));
        this.len += 8;
    }

    // Raw bytes, no prefix.
    raw(b: Uint8Array): void {
        this.reserve(b.length);
        copyIn(this.ptr, this.len, b);
        this.len += b.length;
    }

    // The UTF-8 of `s` (as String.UTF8.encode gives it), written in place.
    str(s: string): void {
        const n = utf8Len(s);
        this.varUsize(<u64>n);
        this.reserve(n);
        utf8Into(s, this.ptr, this.len);
        this.len += n;
    }

    // A byte sequence: the count, then the raw bytes.
    bytes(b: Uint8Array): void {
        this.varUsize(<u64>b.length);
        this.raw(b);
    }

    // A sequence / map length.
    seqLen(n: i32): void {
        this.varUsize(<u64>n);
    }

    none(): void {
        this.u8(0);
    }

    some(): void {
        this.u8(1);
    }

    // Enum variant index.
    variant(idx: u32): void {
        this.varU32(idx);
    }

    // The bytes written so far (a copy). The block first shrinks to them,
    // so under the stub runtime the copy reuses the space it gave back.
    finish(): Uint8Array {
        if (this.cap > this.len && this.len > 0) {
            this.ptr = reallocBlock(this.ptr, this.len);
            this.cap = this.len;
        }
        const out = new Uint8Array(this.len);
        copyOut(this.ptr, out);
        return out;
    }
}

// The raw-memory side of PostcardWriter (callers keep every access within
// the block: reserve() comes first).
function reallocBlock(ptr: usize, size: i32): usize {
    return reallocUnsafe(ptr, size);
}

unsafe function reallocUnsafe(ptr: usize, size: i32): usize {
    return ptr == 0 ? __alloc(<usize>size) : __realloc(ptr, <usize>size);
}

function storeU8(ptr: usize, at: i32, v: u8): void {
    storeU8Unsafe(ptr + <usize>at, v);
}

unsafe function storeU8Unsafe(p: usize, v: u8): void {
    store<u8>(p, v);
}

function storeU32(ptr: usize, at: i32, v: u32): void {
    storeU32Unsafe(ptr + <usize>at, v);
}

unsafe function storeU32Unsafe(p: usize, v: u32): void {
    store<u32>(p, v);
}

function storeU64(ptr: usize, at: i32, v: u64): void {
    storeU64Unsafe(ptr + <usize>at, v);
}

unsafe function storeU64Unsafe(p: usize, v: u64): void {
    store<u64>(p, v);
}

function copyIn(ptr: usize, at: i32, b: Uint8Array): void {
    copyInUnsafe(ptr + <usize>at, b);
}

unsafe function copyInUnsafe(p: usize, b: Uint8Array): void {
    memory.copy(p, b.dataStart, <usize>b.length);
}

function copyOut(ptr: usize, out: Uint8Array): void {
    copyOutUnsafe(ptr, out);
}

unsafe function copyOutUnsafe(ptr: usize, out: Uint8Array): void {
    if (out.length > 0) memory.copy(out.dataStart, ptr, <usize>out.length);
}

function utf8Len(s: string): i32 {
    return utf8LenUnsafe(s);
}

unsafe function utf8LenUnsafe(s: string): i32 {
    return String.UTF8.byteLength(s);
}

function utf8Into(s: string, ptr: usize, at: i32): void {
    utf8IntoUnsafe(s, ptr + <usize>at);
}

unsafe function utf8IntoUnsafe(s: string, p: usize): void {
    String.UTF8.encodeUnsafe(changetype<usize>(s), s.length, p);
}

// ---------------------------------------------------------------------------
// Reader

// Whether b[start..end) is valid UTF-8.
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

export class PostcardReader {
    data: Uint8Array;
    pos: i32 = 0;
    error: PostcardError = PostcardError.None;

    constructor(data: Uint8Array) {
        this.data = data;
    }

    get failed(): bool {
        return this.error != PostcardError.None;
    }

    // The message of the first failure ("" when none).
    errorText(): string {
        return postcardErrorText(this.error);
    }

    // Record a failure (the first one wins).
    fail(e: PostcardError): void {
        if (this.error == PostcardError.None) this.error = e;
    }

    remaining(): i32 {
        return this.data.length - this.pos;
    }

    private pop(): u8 {
        if (this.failed) return 0;
        if (this.pos >= this.data.length) {
            this.fail(PostcardError.DeserializeUnexpectedEnd);
            return 0;
        }
        const v = this.data[this.pos];
        this.pos++;
        return v;
    }

    // `try_take_n`: the start of `n` bytes, or -1 (UnexpectedEnd).
    private take(n: u64): i32 {
        if (this.failed) return -1;
        if (n > <u64>this.remaining()) {
            this.fail(PostcardError.DeserializeUnexpectedEnd);
            return -1;
        }
        const at = this.pos;
        this.pos += <i32>n;
        return at;
    }

    u8(): u8 {
        return this.pop();
    }

    bool(): bool {
        const v = this.pop();
        if (this.failed) return false;
        if (v == 0) return false;
        if (v == 1) return true;
        this.fail(PostcardError.DeserializeBadBool);
        return false;
    }

    // `try_take_varint_*`: at most `maxBytes` bytes; the last one may carry
    // only `lastMax` (the bits left of the width).
    private varint(maxBytes: i32, lastMax: u8, bits: u64): u64 {
        let out: u64 = 0;
        for (let i = 0; i < maxBytes; i++) {
            const val = this.pop();
            if (this.failed) return 0;
            const carry = <u64>(val & 0x7F);
            out |= carry << (<u64>(7 * i));
            if ((val & 0x80) == 0) {
                if (i == maxBytes - 1 && val > lastMax) {
                    this.fail(PostcardError.DeserializeBadVarint);
                    return 0;
                }
                return bits == 64 ? out : out & ((<u64>1 << bits) - 1);
            }
        }
        this.fail(PostcardError.DeserializeBadVarint);
        return 0;
    }

    varU16(): u16 {
        return <u16>this.varint(3, 3, 16);
    }

    varU32(): u32 {
        return <u32>this.varint(5, 15, 32);
    }

    varU64(): u64 {
        return this.varint(10, 1, 64);
    }

    // usize: a u64 varint.
    varUsize(): u64 {
        return this.varU64();
    }

    // Sequence / map length (usize).
    seqLen(): u64 {
        return this.varUsize();
    }

    i32(): i32 {
        const n = this.varU32();
        return <i32>(n >> 1) ^ -(<i32>(n & 1));
    }

    f32(): f32 {
        const at = this.take(4);
        if (at < 0) return 0;
        const d = this.data;
        const b = <u32>d[at] | (<u32>d[at + 1] << 8) | (<u32>d[at + 2] << 16) | (<u32>d[at + 3] << 24);
        return reinterpret<f32>(b);
    }

    f64(): f64 {
        const at = this.take(8);
        if (at < 0) return 0;
        let b: u64 = 0;
        for (let i = 0; i < 8; i++) b |= <u64>this.data[at + i] << (<u64>(8 * i));
        return reinterpret<f64>(b);
    }

    str(): string {
        const n = this.varUsize();
        const at = this.take(n);
        if (at < 0) return "";
        const end = at + <i32>n;
        if (!validUtf8(this.data, at, end)) {
            this.fail(PostcardError.DeserializeBadUtf8);
            return "";
        }
        if (end == at) return "";
        const off = this.data.byteOffset;
        return String.UTF8.decode(this.data.buffer.slice(off + at, off + end));
    }

    // A byte sequence: the count, then the raw bytes.
    bytes(): Uint8Array {
        const n = this.seqLen();
        const at = this.take(n);
        if (at < 0) return new Uint8Array(0);
        return this.data.slice(at, at + <i32>n);
    }

    // Option tag: true for Some.
    option(): bool {
        const v = this.pop();
        if (this.failed) return false;
        if (v == 0) return false;
        if (v == 1) return true;
        this.fail(PostcardError.DeserializeBadOption);
        return false;
    }

    // Enum variant index of an enum with `count` variants. An index out of
    // range is reported as SerdeDeCustom (postcard's error for an invalid
    // value).

    variant(count: u32): u32 {
        const idx = this.varU32();
        if (this.failed) return 0;
        if (idx >= count) {
            this.fail(PostcardError.SerdeDeCustom);
            return 0;
        }
        return idx;
    }
}
