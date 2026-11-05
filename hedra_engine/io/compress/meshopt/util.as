// Derived from meshopt-rs 0.1.2 (MIT); see THIRD_PARTY_NOTICES.md.
//
// The byte I/O the codecs are written against: a reader and a writer over a
// window `[start, start + len)` of a Uint8Array:
// - ByteReader: a read past the end yields 0 and does not move the position.
//   The position can be set past the end.
// - ByteWriter: a write past the end is dropped (0 bytes written); `len()` is
//   the room left.

import { ErrorValue, Result } from "../../../base/util";

export class ByteReader {
    buf: Uint8Array;
    start: i32;
    len: i32;
    pos: i32 = 0;

    constructor(buf: Uint8Array, start: i32, len: i32) {
        this.buf = buf;
        this.start = start;
        this.len = len;
    }

    // The next byte, or 0 past the end.
    readByte(): u8 {
        if (this.pos >= 0 && this.pos < this.len) {
            const b = this.buf[this.start + this.pos];
            this.pos++;
            return b;
        }
        return 0;
    }

    // Bytes left after the position.
    remaining(): i32 {
        return this.len - this.pos;
    }
}

// Why a vertex or index decode failed (both codecs share these variants).
export enum DecodeError {
    InvalidHeader,
    UnsupportedVersion,
    ExtraBytes,
    UnexpectedEof,
}

// The debug name of a DecodeError.
export function decodeErrorDebug(e: DecodeError): string {
    switch (e) {
        case DecodeError.InvalidHeader: return "InvalidHeader";
        case DecodeError.UnsupportedVersion: return "UnsupportedVersion";
        case DecodeError.ExtraBytes: return "ExtraBytes";
        default: return "UnexpectedEof";
    }
}

// The typed error of a failed decode: `r.err` is its debug name.
export class DecodeErrorValue extends ErrorValue {
    kind: DecodeError;

    constructor(kind: DecodeError) {
        super();
        this.kind = kind;
    }

    toString(): string {
        return decodeErrorDebug(this.kind);
    }
}

// A failed decode result carrying `e`.
export function decodeFail(e: DecodeError): Result<bool> {
    return Result.failWith<bool>(new DecodeErrorValue(e));
}

// A successful decode result.
export function decodeOk(): Result<bool> {
    return Result.okv<bool>(true);
}

// The kind of a failed decode result (-1 when it succeeded or carries no DecodeErrorValue).
export function decodeErrorOf(r: Result<bool>): i32 {
    const c = r.cause;
    if (r.ok || c == null) return -1;
    const is = c instanceof DecodeErrorValue;
    if (!is) return -1;
    return <i32>(c as DecodeErrorValue).kind;
}
