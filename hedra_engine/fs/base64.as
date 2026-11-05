// Standard base64 (RFC 4648, `+/`, `=` padding) for the host channel: the
// host contract (CONTRACT.md §4) carries file contents as base64 inside
// JSON, in `data` fields. base64DecodeSpan decodes a field straight from the
// bytes of the host's batch (strictly, see there), and
// base64EncodeUtf16Unsafe writes a field into a program batch, which is
// built as UTF-16 code units (host/src/wire.as). base64Encode and
// base64Decode work on whole strings.

import { Result, panic } from "../base/util";

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// Two base64 digits per 12-bit value, as the little-endian u16 whose low
// byte is the first digit (so one store writes both), built on first use.
let PAIRS: StaticArray<u16>? = null;

function pairTable(): StaticArray<u16> {
    let t = PAIRS;
    if (t == null) {
        const table = new StaticArray<u16>(4096);
        for (let x = 0; x < 4096; x++) {
            table[x] = <u16>(ALPHABET.charCodeAt(x >> 6) | (ALPHABET.charCodeAt(x & 63) << 8));
        }
        PAIRS = table;
        t = table;
    }
    return t;
}

// The length of the base64 of `n` bytes.
export function base64Len(n: i32): i32 {
    return ((n + 2) / 3) * 4;
}

// Writes the base64 of `bytes` into `out` from `at` (the caller made room for
// base64Len(bytes.length) bytes there); returns the end offset. One 12-bit
// table lookup and one u16 store per two digits.
export function base64EncodeInto(bytes: Uint8Array, out: Uint8Array, at: i32): i32 {
    const n = bytes.length;
    if (at < 0 || <i64>at + <i64>base64Len(n) > <i64>out.length) {
        panic("base64EncodeInto: " + n.toString() + " bytes do not fit at " + at.toString());
    }
    return encodeUnchecked(bytes, out, at, pairTable());
}

unsafe function encodeUnchecked(bytes: Uint8Array, out: Uint8Array, at: i32, table: StaticArray<u16>): i32 {
    const n = bytes.length;
    const tp = changetype<usize>(table);
    let src = bytes.dataStart;
    const whole = src + <usize>(n - n % 3);
    let dst = out.dataStart + <usize>at;
    while (src < whole) {
        const v = (<u32>load<u8>(src) << 16) | (<u32>load<u8>(src + 1) << 8) | <u32>load<u8>(src + 2);
        store<u16>(dst, load<u16>(tp + (<usize>(v >> 12) << 1)));
        store<u16>(dst + 2, load<u16>(tp + (<usize>(v & 0xfff) << 1)));
        src += 3;
        dst += 4;
    }
    const rest = n % 3;
    if (rest == 1) {
        const v = <u32>load<u8>(src) << 16;
        store<u8>(dst, <u8>ALPHABET.charCodeAt((v >> 18) & 63));
        store<u8>(dst + 1, <u8>ALPHABET.charCodeAt((v >> 12) & 63));
        store<u8>(dst + 2, 61);
        store<u8>(dst + 3, 61);
        dst += 4;
    } else if (rest == 2) {
        const v = (<u32>load<u8>(src) << 16) | (<u32>load<u8>(src + 1) << 8);
        store<u8>(dst, <u8>ALPHABET.charCodeAt((v >> 18) & 63));
        store<u8>(dst + 1, <u8>ALPHABET.charCodeAt((v >> 12) & 63));
        store<u8>(dst + 2, <u8>ALPHABET.charCodeAt((v >> 6) & 63));
        store<u8>(dst + 3, 61);
        dst += 4;
    }
    return <i32>(dst - out.dataStart);
}

export function base64Encode(bytes: Uint8Array): string {
    const out = new Uint8Array(base64Len(bytes.length));
    base64EncodeInto(bytes, out, 0);
    return String.UTF8.decode(out.buffer);
}

function sextet(c: i32): i32 {
    if (c >= 65 && c <= 90) return c - 65;
    if (c >= 97 && c <= 122) return c - 71;
    if (c >= 48 && c <= 57) return c + 4;
    if (c == 43) return 62;
    if (c == 47) return 63;
    return -1;
}

// Decodes padded or unpadded base64; ASCII whitespace is skipped (a
// wrapped text, as `base64` writes by default). Anything else is an error.
export function base64Decode(s: string): Result<Uint8Array> {
    const vals: Array<i32> = [];
    let pad = 0;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c == 32 || c == 9 || c == 10 || c == 13) continue;
        if (c == 61) {
            pad++;
            continue;
        }
        if (pad > 0) return Result.fail<Uint8Array>("invalid base64: data after padding");
        const v = sextet(c);
        if (v < 0) return Result.fail<Uint8Array>("invalid base64 character at offset " + i.toString());
        vals.push(v);
    }
    if (vals.length % 4 == 1 || pad > 2) return Result.fail<Uint8Array>("invalid base64 length");
    const full = vals.length / 4;
    const tail = vals.length % 4;
    const out = new Uint8Array(full * 3 + (tail == 0 ? 0 : tail - 1));
    let o = 0;
    let k = 0;
    for (let g = 0; g < full; g++) {
        const v = (<u32>vals[k] << 18) | (<u32>vals[k + 1] << 12) | (<u32>vals[k + 2] << 6) | <u32>vals[k + 3];
        k += 4;
        out[o++] = <u8>(v >> 16);
        out[o++] = <u8>(v >> 8);
        out[o++] = <u8>v;
    }
    if (tail == 2) {
        const v = (<u32>vals[k] << 18) | (<u32>vals[k + 1] << 12);
        out[o++] = <u8>(v >> 16);
    } else if (tail == 3) {
        const v = (<u32>vals[k] << 18) | (<u32>vals[k + 1] << 12) | (<u32>vals[k + 2] << 6);
        out[o++] = <u8>(v >> 16);
        out[o++] = <u8>(v >> 8);
    }
    return Result.okv<Uint8Array>(out);
}

// ---------------------------------------------------------------------------
// The host contract's `data` fields

// Each byte's sextet (0..63), or 0xFF for a byte outside the alphabet;
// built on first use.
let SEXTETS: StaticArray<u8>? = null;

function sextetTable(): StaticArray<u8> {
    let t = SEXTETS;
    if (t == null) {
        const table = new StaticArray<u8>(256);
        for (let c = 0; c < 256; c++) {
            const v = sextet(c);
            table[c] = v < 0 ? 0xFF : <u8>v;
        }
        SEXTETS = table;
        t = table;
    }
    return t;
}

// Decodes the base64 in src[start, end), strictly as the contract writes
// it: the length is a multiple of 4, `=` appears only as the last one or two
// digits, and nothing else (no whitespace) is allowed. Unused bits of the
// last digit are ignored. Errors name the offset from `start`.
export function base64DecodeSpan(src: Uint8Array, start: i32, end: i32): Result<Uint8Array> {
    if (start < 0 || end < start || end > src.length) panic("base64DecodeSpan: bad span");
    const n = end - start;
    if (n % 4 != 0) return Result.fail<Uint8Array>("invalid base64 length " + n.toString());
    if (n == 0) return Result.okv<Uint8Array>(new Uint8Array(0));
    let pad = 0;
    if (src[end - 1] == 61) pad = src[end - 2] == 61 ? 2 : 1;
    const out = new Uint8Array((n / 4) * 3 - pad);
    const bad = decodeSpanUnsafe(src, start, end, pad, out, sextetTable());
    if (bad >= 0) {
        const c = <i32>src[start + bad];
        if (c == 61) return Result.fail<Uint8Array>("invalid base64 padding at offset " + bad.toString());
        return Result.fail<Uint8Array>("invalid base64 character at offset " + bad.toString());
    }
    return Result.okv<Uint8Array>(out);
}

// The decode loop of base64DecodeSpan: -1, or the offset (from start) of
// the first digit outside the alphabet.
unsafe function decodeSpanUnsafe(src: Uint8Array, start: i32, end: i32, pad: i32,
                                 out: Uint8Array, table: StaticArray<u8>): i32 {
    const t = changetype<usize>(table);
    const base = src.dataStart;
    const whole = end - (pad > 0 ? 4 : 0);
    let p = start;
    let o = out.dataStart;
    while (p < whole) {
        const q = load<u32>(base + <usize>p);
        const a = <u32>load<u8>(t + <usize>(q & 255));
        const b = <u32>load<u8>(t + <usize>((q >> 8) & 255));
        const c = <u32>load<u8>(t + <usize>((q >> 16) & 255));
        const d = <u32>load<u8>(t + <usize>(q >> 24));
        if (((a | b | c | d) & 0x80) != 0) return firstBad(src, p, p + 4, table) - start;
        const v = (a << 18) | (b << 12) | (c << 6) | d;
        store<u8>(o, <u8>(v >> 16));
        store<u8>(o + 1, <u8>(v >> 8));
        store<u8>(o + 2, <u8>v);
        p += 4;
        o += 3;
    }
    if (pad > 0) {
        // the last group: two or three digits and its padding
        const a = <u32>load<u8>(t + <usize>load<u8>(base + <usize>p));
        const b = <u32>load<u8>(t + <usize>load<u8>(base + <usize>(p + 1)));
        const c = pad == 1 ? <u32>load<u8>(t + <usize>load<u8>(base + <usize>(p + 2))) : 0;
        if (((a | b | c) & 0x80) != 0) return firstBad(src, p, p + 4 - pad, table) - start;
        const v = (a << 18) | (b << 12) | (c << 6);
        store<u8>(o, <u8>(v >> 16));
        if (pad == 1) store<u8>(o + 1, <u8>(v >> 8));
    }
    return -1;
}

function firstBad(src: Uint8Array, from: i32, to: i32, table: StaticArray<u8>): i32 {
    for (let i = from; i < to; i++) {
        if (table[src[i]] == 0xFF) return i;
    }
    return to;
}

// Two base64 digits per 12-bit value as two UTF-16 code units (one u32,
// the first digit in the low half), built on first use.
let PAIRS16: StaticArray<u32>? = null;

function pairTable16(): StaticArray<u32> {
    let t = PAIRS16;
    if (t == null) {
        const table = new StaticArray<u32>(4096);
        for (let x = 0; x < 4096; x++) {
            table[x] = <u32>ALPHABET.charCodeAt(x >> 6) | (<u32>ALPHABET.charCodeAt(x & 63) << 16);
        }
        PAIRS16 = table;
        t = table;
    }
    return t;
}

// Writes the base64 of bytes[from, to) as UTF-16 code units at `dst`, which
// has room for 2 * base64Len(to - from) bytes (the caller checked). Returns
// the number of bytes written.
export unsafe function base64EncodeUtf16Unsafe(bytes: Uint8Array, from: i32, to: i32, dst: usize): usize {
    const tp = changetype<usize>(pairTable16());
    const n = to - from;
    let src = bytes.dataStart + <usize>from;
    const whole = src + <usize>(n - n % 3);
    let out = dst;
    while (src < whole) {
        const v = (<u32>load<u8>(src) << 16) | (<u32>load<u8>(src + 1) << 8) | <u32>load<u8>(src + 2);
        store<u32>(out, load<u32>(tp + (<usize>(v >> 12) << 2)));
        store<u32>(out + 4, load<u32>(tp + (<usize>(v & 0xfff) << 2)));
        src += 3;
        out += 8;
    }
    const rest = n % 3;
    if (rest > 0) {
        let v = <u32>load<u8>(src) << 16;
        if (rest == 2) v |= <u32>load<u8>(src + 1) << 8;
        store<u16>(out, <u16>ALPHABET.charCodeAt((v >> 18) & 63));
        store<u16>(out + 2, <u16>ALPHABET.charCodeAt((v >> 12) & 63));
        store<u16>(out + 4, rest == 2 ? <u16>ALPHABET.charCodeAt((v >> 6) & 63) : 61);
        store<u16>(out + 6, 61);
        out += 8;
    }
    return out - dst;
}
