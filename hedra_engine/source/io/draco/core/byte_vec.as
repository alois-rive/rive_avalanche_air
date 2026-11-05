// A growable byte vector: the byte store behind the Draco buffers
// (EncoderBuffer, DataBuffer).
//
// Storage is a Uint8Array with spare capacity; `length` is the live size.
// Growth zero-fills, and indexing past `length` panics with an
// out-of-bounds message instead of reading the spare capacity.
// `data()` is a view (`subarray`) of the live bytes: it is only valid
// until the next call that grows the vector.

import { panic } from "../../../../base/util";

// The largest Uint8Array rasc can allocate: OBJECT_MAXSIZE in std/rt/common,
// i.e. BLOCK_MAXSIZE (2^30 - 4 on wasm32) minus the 16-byte object header.
// `__new` traps past it (measured with rive 1.1.0 / stub runtime: a
// Uint8Array of 2^30 - 20 bytes allocates, 2^30 - 19 traps).
export const BYTE_VEC_MAX_CAPACITY: i32 = (1 << 30) - 20;

export class ByteVec {
    private buf: Uint8Array;
    private len: i32 = 0;

    constructor(capacity: i32 = 0) {
        this.buf = new Uint8Array(capacity > 0 ? capacity : 0);
    }

    // Wraps a copy of `bytes`.
    static fromBytes(bytes: Uint8Array): ByteVec {
        const v = new ByteVec(bytes.length);
        v.buf.set(bytes, 0);
        v.len = bytes.length;
        return v;
    }

    get length(): i32 {
        return this.len;
    }

    capacity(): i32 {
        return this.buf.length;
    }

    isEmpty(): bool {
        return this.len == 0;
    }

    // Makes room for `additional` more bytes past `length`.
    reserve(additional: i32): void {
        const need = <i64>this.len + <i64>additional;
        if (need <= <i64>this.buf.length) return;
        if (need > <i64>BYTE_VEC_MAX_CAPACITY) panic("capacity overflow");
        let cap = <i64>this.buf.length * 2;
        if (cap < need) cap = need;
        if (cap < 8) cap = 8;
        if (cap > <i64>BYTE_VEC_MAX_CAPACITY) cap = <i64>BYTE_VEC_MAX_CAPACITY;
        const nb = new Uint8Array(<i32>cap);
        nb.set(this.buf.subarray(0, this.len), 0);
        this.buf = nb;
    }

    // Ensures room for exactly `additional` more bytes.
    reserveExact(additional: i32): void {
        const need = <i64>this.len + <i64>additional;
        if (need <= <i64>this.buf.length) return;
        if (need > <i64>BYTE_VEC_MAX_CAPACITY) panic("capacity overflow");
        const nb = new Uint8Array(<i32>need);
        nb.set(this.buf.subarray(0, this.len), 0);
        this.buf = nb;
    }

    push(b: u8): void {
        if (this.len == this.buf.length) this.reserve(1);
        this.buf[this.len] = b;
        this.len++;
    }

    // Appends a copy of `src`.
    extend(src: Uint8Array): void {
        const n = src.length;
        if (n == 0) return;
        this.reserve(n);
        this.buf.set(src, this.len);
        this.len += n;
    }

    // Resizes to `n` bytes: truncates, or grows filling with `fill`.
    resize(n: i32, fill: u8 = 0): void {
        if (n < 0) panic("capacity overflow");
        if (n > this.len) {
            this.reserve(n - this.len);
            this.buf.fill(fill, this.len, n);
        }
        this.len = n;
    }

    // Shortens to `n` bytes (no-op when already shorter).
    truncate(n: i32): void {
        if (n < this.len) this.len = n;
    }

    clear(): void {
        this.len = 0;
    }

    // Byte `i` (panics out of bounds).
    get(i: i32): u8 {
        if (i < 0 || i >= this.len) {
            panic("index out of bounds: the len is " + this.len.toString() + " but the index is " + i.toString());
        }
        return unchecked(this.buf[i]);
    }

    // Sets byte `i` to `b` (panics out of bounds).
    set(i: i32, b: u8): void {
        if (i < 0 || i >= this.len) {
            panic("index out of bounds: the len is " + this.len.toString() + " but the index is " + i.toString());
        }
        unchecked((this.buf[i] = b));
    }

    // The live bytes as a view (valid until the vector grows).
    data(): Uint8Array {
        return this.buf.subarray(0, this.len);
    }

    // A view of `start..end`, panicking when out of range.
    range(start: i32, end: i32): Uint8Array {
        checkRange(start, end, this.len);
        return this.buf.subarray(start, end);
    }

    // A copy of the live bytes.
    toBytes(): Uint8Array {
        return this.buf.slice(0, this.len);
    }

    // Copies bytes `src..srcEnd` to `dst` (the ranges may overlap).
    copyWithin(dst: i32, src: i32, srcEnd: i32): void {
        checkRange(src, srcEnd, this.len);
        checkRange(dst, dst + (srcEnd - src), this.len);
        const n = srcEnd - src;
        const b = this.buf;
        if (dst < src) {
            for (let i = 0; i < n; i++) unchecked((b[dst + i] = b[src + i]));
        } else if (dst > src) {
            for (let i = n - 1; i >= 0; i--) unchecked((b[dst + i] = b[src + i]));
        }
    }

    clone(): ByteVec {
        const v = new ByteVec(this.len);
        v.buf.set(this.buf.subarray(0, this.len), 0);
        v.len = this.len;
        return v;
    }
}

// Panics with a slice-index message when `start..end` is not inside `len`.
export function checkRange(start: i64, end: i64, len: i64): void {
    if (start > end) {
        panic("slice index starts at " + start.toString() + " but ends at " + end.toString());
    }
    if (end > len) {
        panic("range end index " + end.toString() + " out of range for slice of length " + len.toString());
    }
    if (start < 0) {
        panic("range start index " + start.toString() + " out of range for slice of length " + len.toString());
    }
}
