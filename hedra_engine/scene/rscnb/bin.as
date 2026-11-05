// Little-endian binary I/O for the built files (milestone 39): the
// binary scene .rscnb (codec.as) and the asset container it carries
// (../bundle/). One writer that grows as it goes, one reader that never
// traps, and the string table both files start from.
//
// The reader checks every read against its window: a read past the end
// gives 0 (or an empty string or array), sets `failed` with the first
// reason and leaves the position at the end, so a decoder reads a whole
// record and checks `failed` once rather than after every field (a
// damaged file is an error at the file, never a trap: ENGINEERING.md
// pitfall 13).
//
// The common ground of everything that reads or writes the built
// binaries (.rscnb and the asset container).

import { Result, panic } from "../../base/util";

// A four-character code as a little-endian u32 ("STRS" reads as the bytes
// S, T, R, S in the file).
export function fourcc(s: string): u32 {
    let v: u32 = 0;
    for (let i = 0; i < 4; i++) {
        const c = i < s.length ? <u32>(s.charCodeAt(i) & 0xFF) : 32;
        v |= c << (<u32>i * 8);
    }
    return v;
}

// The four characters of a code (`fourcc`'s inverse), for messages.
export function fourccText(v: u32): string {
    let s = "";
    for (let i = 0; i < 4; i++) s += String.fromCharCode(<i32>((v >> (<u32>i * 8)) & 0xFF));
    return s;
}

// A growing byte buffer. Every write appends at the end; `patchU32`
// rewrites a field written earlier (a section's size, an offset known
// only later).
export class BinWriter {
    private buf: Uint8Array;
    private len: i32 = 0;

    constructor(capacity: i32 = 256) {
        this.buf = new Uint8Array(max<i32>(capacity, 16));
    }

    // Bytes written so far.
    get length(): i32 {
        return this.len;
    }

    private reserve(n: i32): void {
        const need = this.len + n;
        if (need <= this.buf.length) return;
        let cap = this.buf.length;
        while (cap < need) cap = cap < (1 << 26) ? cap * 2 : cap + (1 << 26);
        const next = new Uint8Array(cap);
        next.set(this.buf.subarray(0, this.len), 0);
        this.buf = next;
    }

    u8(v: u32): void {
        this.reserve(1);
        this.buf[this.len++] = <u8>(v & 0xFF);
    }

    u16(v: u32): void {
        this.reserve(2);
        this.buf[this.len++] = <u8>(v & 0xFF);
        this.buf[this.len++] = <u8>((v >> 8) & 0xFF);
    }

    u32(v: u32): void {
        this.reserve(4);
        for (let i = 0; i < 4; i++) this.buf[this.len++] = <u8>((v >> (<u32>i * 8)) & 0xFF);
    }

    i32(v: i32): void {
        this.u32(<u32>v);
    }

    u64(v: u64): void {
        this.reserve(8);
        for (let i = 0; i < 8; i++) this.buf[this.len++] = <u8>((v >> (<u64>i * 8)) & 0xFF);
    }

    i64(v: i64): void {
        this.u64(<u64>v);
    }

    // The f32's bits, so that -0, the NaNs and every value round-trip.
    f32(v: f32): void {
        this.u32(reinterpret<u32>(v));
    }

    f64(v: f64): void {
        this.u64(reinterpret<u64>(v));
    }

    // `b[from, from + n)` (all of it by default).
    bytes(b: Uint8Array, from: i32 = 0, n: i32 = -1): void {
        const count = n < 0 ? b.length - from : n;
        if (count <= 0) return;
        this.reserve(count);
        this.buf.set(b.subarray(from, from + count), this.len);
        this.len += count;
    }

    // `s` as UTF-8, with no length (the caller writes it).
    utf8(s: string): void {
        this.bytes(Uint8Array.wrap(String.UTF8.encode(s)));
    }

    // Zero bytes up to the next multiple of `n` (a power of two).
    align(n: i32): void {
        while ((this.len & (n - 1)) != 0) this.u8(0);
    }

    // Rewrites the u32 at byte `at` (already written).
    patchU32(at: i32, v: u32): void {
        if (at < 0 || at + 4 > this.len) panic("BinWriter.patchU32 past the end");
        for (let i = 0; i < 4; i++) this.buf[at + i] = <u8>((v >> (<u32>i * 8)) & 0xFF);
    }

    // Rewrites the u64 at byte `at` (already written).
    patchU64(at: i32, v: u64): void {
        if (at < 0 || at + 8 > this.len) panic("BinWriter.patchU64 past the end");
        for (let i = 0; i < 8; i++) this.buf[at + i] = <u8>((v >> (<u64>i * 8)) & 0xFF);
    }

    // A copy of the bytes written (the writer may go on).
    toBytes(): Uint8Array {
        const out = new Uint8Array(this.len);
        out.set(this.buf.subarray(0, this.len), 0);
        return out;
    }

    // A view of the bytes written, without a copy: valid until the next
    // write.
    view(): Uint8Array {
        return this.buf.subarray(0, this.len);
    }
}

// A bounds-checked reader over `bytes[start, end)`. Positions are relative
// to `start`.
export class BinReader {
    readonly bytes: Uint8Array;
    readonly start: i32;
    readonly end: i32;
    pos: i32 = 0;
    // The first read that did not fit, or `fail` (the reason in `why`).
    failed: bool = false;
    why: string = "";

    constructor(bytes: Uint8Array, start: i32 = 0, end: i32 = -1) {
        this.bytes = bytes;
        this.start = max<i32>(0, min<i32>(start, bytes.length));
        const e = end < 0 ? bytes.length : min<i32>(end, bytes.length);
        this.end = max<i32>(this.start, e);
    }

    // The window's length.
    get size(): i32 {
        return this.end - this.start;
    }

    remaining(): i32 {
        return this.size - this.pos;
    }

    // Marks the reader failed (the first reason is kept) and moves to the
    // end, so nothing more is read.
    fail(why: string): void {
        if (!this.failed) {
            this.failed = true;
            this.why = why;
        }
        this.pos = this.size;
    }

    // Moves to `pos` (a position past the end fails).
    seek(pos: i32): void {
        if (pos < 0 || pos > this.size) {
            this.fail("an offset (" + pos.toString() + ") past the end (" + this.size.toString() + ")");
            return;
        }
        this.pos = pos;
    }

    // Whether `n` more bytes can be read; fails when not.
    private has(n: i32): bool {
        if (this.failed) return false;
        // Compared without `pos + n`, which a forged length near 2^31 would
        // overflow past the check.
        if (n < 0 || n > this.size - this.pos) {
            this.fail("the data ends early (" + n.toString() + " bytes wanted at " + this.pos.toString()
                + ", " + this.remaining().toString() + " left)");
            return false;
        }
        return true;
    }

    u8(): u32 {
        if (!this.has(1)) return 0;
        return <u32>this.bytes[this.start + this.pos++];
    }

    u16(): u32 {
        if (!this.has(2)) return 0;
        const at = this.start + this.pos;
        this.pos += 2;
        return <u32>this.bytes[at] | (<u32>this.bytes[at + 1] << 8);
    }

    u32(): u32 {
        if (!this.has(4)) return 0;
        const at = this.start + this.pos;
        this.pos += 4;
        let v: u32 = 0;
        for (let i = 0; i < 4; i++) v |= <u32>this.bytes[at + i] << (<u32>i * 8);
        return v;
    }

    i32(): i32 {
        return <i32>this.u32();
    }

    u64(): u64 {
        if (!this.has(8)) return 0;
        const at = this.start + this.pos;
        this.pos += 8;
        let v: u64 = 0;
        for (let i = 0; i < 8; i++) v |= <u64>this.bytes[at + i] << (<u64>i * 8);
        return v;
    }

    i64(): i64 {
        return <i64>this.u64();
    }

    f32(): f32 {
        return reinterpret<f32>(this.u32());
    }

    f64(): f64 {
        return reinterpret<f64>(this.u64());
    }

    // A count that must fit in what is left at `each` bytes an item (a
    // damaged count fails here rather than allocating a huge array).
    count(each: i32): i32 {
        const n = this.u32();
        if (this.failed) return 0;
        const room = each > 0 ? this.remaining() / each : this.remaining() + 1;
        if (n > <u32>room) {
            this.fail("a count (" + n.toString() + ") larger than the data left");
            return 0;
        }
        return <i32>n;
    }

    // A view of the next `n` bytes (no copy).
    view(n: i32): Uint8Array {
        if (!this.has(n)) return new Uint8Array(0);
        const at = this.start + this.pos;
        this.pos += n;
        return this.bytes.subarray(at, at + n);
    }

    // A copy of the next `n` bytes.
    copy(n: i32): Uint8Array {
        const v = this.view(n);
        const out = new Uint8Array(v.length);
        out.set(v, 0);
        return out;
    }

    // `n` bytes of UTF-8 as a string ("" and failed when they are not
    // UTF-8 or not there).
    utf8(n: i32): string {
        if (n == 0) return "";
        const v = this.view(n);
        if (this.failed) return "";
        return String.UTF8.decodeUnsafe(v.dataStart, <usize>v.length);
    }

    // Skips to the next multiple of `n` (a power of two) from `start`.
    align(n: i32): void {
        const p = (this.pos + n - 1) & ~(n - 1);
        if (p > this.size) {
            this.fail("padding past the end");
            return;
        }
        this.pos = p;
    }

    // The reader's state as a Result: `v` when nothing failed.
    result<T>(v: T, file: string): Result<T> {
        if (!this.failed) return Result.okv<T>(v);
        return Result.fail<T>(file + ": " + this.why);
    }
}

// The string table a file starts from: each string once, numbered in the
// order first interned. Index 0 is always "" (so that an absent name and
// an empty one cost nothing). Written as a count, then each string's
// UTF-8 byte length, then the bytes one after another.
export class StringTable {
    strings: Array<string> = [""];
    private index: Map<string, u32> = new Map<string, u32>();

    constructor() {
        this.index.set("", 0);
    }

    // The string's index, adding it when new.
    intern(s: string): u32 {
        if (this.index.has(s)) return this.index.get(s);
        const i = <u32>this.strings.length;
        this.strings.push(s);
        this.index.set(s, i);
        return i;
    }

    get count(): i32 {
        return this.strings.length;
    }

    write(w: BinWriter): void {
        const enc = new Array<Uint8Array>();
        for (let i = 0; i < this.strings.length; i++) enc.push(Uint8Array.wrap(String.UTF8.encode(this.strings[i])));
        w.u32(<u32>enc.length);
        for (let i = 0; i < enc.length; i++) w.u32(<u32>enc[i].length);
        for (let i = 0; i < enc.length; i++) w.bytes(enc[i]);
    }

    // The strings `write` wrote (the reader failed, and null, when the
    // table is damaged; its first string must be "").
    static read(r: BinReader): Array<string>? {
        const n = r.count(4);
        const lengths = new Array<i32>();
        // Every length is checked against what is left, and so is their
        // sum, so a forged length fails here instead of reading past the
        // table or wrapping round.
        let total: u64 = 0;
        for (let i = 0; i < n; i++) {
            const len = r.u32();
            total += <u64>len;
            lengths.push(<i32>len);
        }
        if (r.failed) return null;
        if (total > <u64>r.remaining()) {
            r.fail("string lengths (" + total.toString() + " bytes) larger than the data left");
            return null;
        }
        const out = new Array<string>();
        for (let i = 0; i < n; i++) out.push(r.utf8(lengths[i]));
        if (r.failed) return null;
        if (out.length == 0 || out[0].length != 0) {
            r.fail("the string table does not start with the empty string");
            return null;
        }
        return out;
    }
}

// The string at `i` of `strings` ("" and `r` failed when out of range).
export function stringAt(r: BinReader, strings: Array<string>, i: u32): string {
    if (i >= <u32>strings.length) {
        r.fail("a string index (" + i.toString() + ") past the table (" + strings.length.toString() + ")");
        return "";
    }
    return strings[<i32>i];
}

// The index that stands for "none" where a string or a value may be
// absent (a null uid, a node without a type).
export const NONE: u32 = 0xFFFFFFFF;
