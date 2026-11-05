// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Input buffer for reading a compressed Draco stream, with byte-aligned reads,
// bit-level reads, the per-decode allocation budget and the caller's
// DecodeLimits.
//
// The input is a Uint8Array (never copied: decodeSlice and
// remainingData return `subarray` views of it). Positions are i32 (a wasm
// buffer is < 2^31 bytes); lengths and counts that come out of a stream are
// taken as u64 so they are
// range-checked before any narrowing, and error texts print them unchanged.

import { Result } from "../../../../base/util";
import { DracoError, Status, okStatus } from "./status";
import { DEFAULT_MESH_VERSION, bitstreamVersion as packVersion } from "./version";
import { DecodeLimits } from "./decode_limits";
import { ensureAllocationIsBacked } from "./decode_budget";

export class DecoderBuffer {
    private data: Uint8Array;
    private pos: i32 = 0;
    private bitDecoderActive: bool = false;
    private bitStartPos: i32 = 0;
    private currentBitOffset: i64 = 0;
    private bitStreamEndPos: i32 = 0;
    private bitSequenceSizeKnown: bool = false;
    private versionMajor_: u8 = DEFAULT_MESH_VERSION.major;
    private versionMinor_: u8 = DEFAULT_MESH_VERSION.minor;
    // Bytes this decode has reserved so far, across every buffer it sized.
    private spent_: u64 = 0;
    // The caller's ceilings on what this decode may produce.
    private limits: DecodeLimits = new DecodeLimits();
    private decodedBytes: u64 = 0;

    // Reads `data` from its start under the default limits.
    constructor(data: Uint8Array) {
        this.data = data;
    }

    // Decodes under `limits` rather than under the defaults (consumes and
    // returns this buffer, builder style).
    withLimits(limits: DecodeLimits): DecoderBuffer {
        this.limits = limits.clone();
        return this;
    }

    // Refuses a decoded point count over the caller's ceiling.
    checkPoints(points: u64): Status {
        return this.limits.checkPoints(points);
    }

    // Refuses a decoded face count over the caller's ceiling.
    checkFaces(faces: u64): Status {
        return this.limits.checkFaces(faces);
    }

    // Adds one attribute's declared size to this decode's running total and
    // refuses when the total passes the caller's ceiling.
    chargeDecodedBytes(bytes: u64): Status {
        const total = satAddU64(this.decodedBytes, bytes);
        const r = this.limits.checkDecodedBytes(total);
        if (!r.ok) return r;
        this.decodedBytes = total;
        return okStatus();
    }

    // Charges `bytes` against what this stream may make the decoder allocate
    // (cumulative, never credited back).
    charge(bytes: u64): Status {
        const total = satAddU64(this.spent_, bytes);
        const r = ensureAllocationIsBacked(total, <u64>this.data.length);
        if (!r.ok) return r;
        this.spent_ = total;
        return okStatus();
    }

    // charge() for `count` elements of `elementSize` bytes (saturating product).
    chargeElements(count: u64, elementSize: u64): Status {
        return this.charge(satMulU64(count, elementSize));
    }

    // What this decode has reserved so far (for the tests).
    spent(): u64 {
        return this.spent_;
    }

    // Sets the Draco bitstream version for version-dependent decoding.
    setVersion(major: u8, minor: u8): void {
        this.versionMajor_ = major;
        this.versionMinor_ = minor;
    }

    versionMajor(): u8 {
        return this.versionMajor_;
    }

    versionMinor(): u8 {
        return this.versionMinor_;
    }

    // Packed `0xMMmm` bitstream version.
    bitstreamVersion(): u16 {
        return packVersion(this.versionMajor_, this.versionMinor_);
    }

    // Current read position in bytes.
    position(): i32 {
        return this.pos;
    }

    setPosition(pos: u64): Status {
        if (this.bitDecoderActive) {
            return DracoError.buffer("Cannot set position while bit decoding is active").fail<bool>();
        }
        if (pos > <u64>this.data.length) {
            return DracoError.buffer(
                "Position " + pos.toString() + " exceeds buffer length " + this.data.length.toString(),
            ).fail<bool>();
        }
        this.pos = <i32>pos;
        return okStatus();
    }

    // Bytes remaining in the buffer.
    remainingSize(): i32 {
        const r = this.data.length - this.pos;
        return r > 0 ? r : 0;
    }

    // Total size of the buffer, read or not.
    size(): i32 {
        return this.data.length;
    }

    // A copy of the next `len` bytes (clamped to the end), without advancing.
    peekBytes(len: u64): Uint8Array {
        const n = this.data.length;
        const start = this.pos < n ? this.pos : n;
        const endWide = <u64>start + len;
        const end = endWide < <u64>start || endWide > <u64>n ? n : <i32>endWide;
        return this.data.slice(start, end);
    }

    // Starts bit-level decoding. When `decodeSize` is true, reads the bit
    // sequence size (in bytes) from the buffer and returns it.
    startBitDecoding(decodeSize: bool): Result<u64> {
        if (this.bitDecoderActive) {
            return DracoError.buffer("Bit decoding already active").fail<u64>();
        }
        const version = this.bitstreamVersion();
        let sizeBytes: u64 = 0;
        if (decodeSize) {
            if (version < 0x0202) {
                // Legacy bitstreams (< 2.2) are always decoded.
                const r = this.decodeU64();
                if (!r.ok) return r;
                sizeBytes = r.value;
            } else {
                const r = this.decodeVarint();
                if (!r.ok) return r;
                sizeBytes = r.value;
            }
        }

        this.bitStartPos = this.pos;
        this.bitDecoderActive = true;
        this.currentBitOffset = 0;
        this.bitSequenceSizeKnown = decodeSize;

        if (decodeSize) {
            // Bounded by the buffer, not by the declared size: a size past the
            // end only shortens the bit sequence to what the buffer holds.
            const start = <u64>this.bitStartPos;
            if (sizeBytes > u64.MAX_VALUE - start) {
                return DracoError.buffer("Bit stream end position overflow").fail<u64>();
            }
            const declaredEnd = start + sizeBytes;
            this.bitStreamEndPos = declaredEnd < <u64>this.data.length ? <i32>declaredEnd : this.data.length;
        } else {
            this.bitStreamEndPos = this.data.length;
        }

        return Result.okv<u64>(sizeBytes);
    }

    // Ends bit-level decoding and advances the byte position.
    endBitDecoding(): void {
        this.bitDecoderActive = false;
        if (this.bitSequenceSizeKnown) {
            this.pos = this.bitStreamEndPos;
        } else {
            const bytesConsumed = (this.currentBitOffset + 7) / 8;
            this.pos = this.bitStartPos + <i32>bytesConsumed;
        }
    }

    // Decodes the `nbits` least significant bits as a u32.
    decodeLeastSignificantBits32(nbits: u32): Result<u32> {
        if (!this.bitDecoderActive) {
            return DracoError.buffer("Bit decoding not active").fail<u32>();
        }
        return this.decodeLeastSignificantBits32Fast(nbits);
    }

    // The hot-path variant (does not check that bit decoding is active).
    decodeLeastSignificantBits32Fast(nbits: u32): Result<u32> {
        if (nbits == 0) {
            return Result.okv<u32>(0);
        }
        if (nbits > 32) {
            return DracoError.buffer("Bit width exceeds 32 bits").fail<u32>();
        }

        const totalBitOffset = this.currentBitOffset;
        const byteOffsetWide = <i64>this.bitStartPos + totalBitOffset / 8;
        const bitShift = <u32>(totalBitOffset % 8);

        if (byteOffsetWide >= <i64>this.bitStreamEndPos || byteOffsetWide >= <i64>this.data.length) {
            return DracoError.buffer("Unexpected end of bit stream").fail<u32>();
        }
        const byteOffset = <i32>byteOffsetWide;
        const availableEnd = this.bitStreamEndPos < this.data.length ? this.bitStreamEndPos : this.data.length;
        const remaining = availableEnd - byteOffset;

        let raw: u64 = 0;
        if (remaining >= 8) {
            // Fast path: 8 bytes at once.
            for (let i = 0; i < 8; i++) {
                raw |= (<u64>unchecked(this.data[byteOffset + i])) << (<u64>i * 8);
            }
        } else {
            const neededBytes = <i32>((bitShift + nbits + 7) / 8);
            if (remaining < neededBytes) {
                return DracoError.buffer("Unexpected end of bit stream").fail<u32>();
            }
            for (let i = 0; i < neededBytes; i++) {
                raw |= (<u64>unchecked(this.data[byteOffset + i])) << (<u64>i * 8);
            }
        }
        const mask: u64 = ((<u64>1) << <u64>nbits) - 1;
        const value = <u32>((raw >> <u64>bitShift) & mask);

        this.currentBitOffset += <i64>nbits;
        return Result.okv<u32>(value);
    }

    // Currently unused: one
    // bit of the active bit sequence, LSB first.
    private getBit(): Result<u32> {
        const totalBitOffset = this.currentBitOffset;
        const byteOffset = <i64>this.bitStartPos + totalBitOffset / 8;
        const bitShift = <u32>(totalBitOffset % 8);
        if (byteOffset < <i64>this.bitStreamEndPos && byteOffset < <i64>this.data.length) {
            const bit = (<u32>this.data[<i32>byteOffset] >> bitShift) & 1;
            this.currentBitOffset += 1;
            return Result.okv<u32>(bit);
        }
        return DracoError.buffer("Unexpected end of bit stream").fail<u32>();
    }

    // Decodes a value of type T by raw (little-endian) memory copy. Fails while
    // bit decoding is active or when too few bytes remain.
    decode<T>(): Result<T> {
        // Numbers only (a reference type would load a pointer).
        if (!isInteger<T>() && !isFloat<T>()) ERROR("DecoderBuffer.decode<T> needs a number type");
        if (this.bitDecoderActive) {
            return DracoError.buffer("Cannot decode bytes while bit decoding is active").fail<T>();
        }
        const size = <i32>sizeof<T>();
        if (size > this.remainingSize()) {
            return DracoError.buffer(
                "Unexpected end of buffer: need " + size.toString() + " bytes, have " + this.remainingSize().toString(),
            ).fail<T>();
        }
        const val = loadAt<T>(this.data, this.pos);
        this.pos += size;
        return Result.okv<T>(val);
    }

    // Decodes a single byte.
    decodeU8(): Result<u8> {
        return this.decode<u8>();
    }

    // Little-endian u16.
    decodeU16(): Result<u16> {
        const r = this.takeBytes(2);
        if (!r.ok) return r.forward<u16>();
        return Result.okv<u16>(loadAt<u16>(this.data, r.value));
    }

    // Little-endian u32.
    decodeU32(): Result<u32> {
        const r = this.takeBytes(4);
        if (!r.ok) return r.forward<u32>();
        return Result.okv<u32>(loadAt<u32>(this.data, r.value));
    }

    // Little-endian u64.
    decodeU64(): Result<u64> {
        const r = this.takeBytes(8);
        if (!r.ok) return r.forward<u64>();
        return Result.okv<u64>(loadAt<u64>(this.data, r.value));
    }

    // Little-endian f32.
    decodeF32(): Result<f32> {
        const r = this.takeBytes(4);
        if (!r.ok) return r.forward<f32>();
        return Result.okv<f32>(loadAt<f32>(this.data, r.value));
    }

    // Little-endian f64.
    decodeF64(): Result<f64> {
        const r = this.takeBytes(8);
        if (!r.ok) return r.forward<f64>();
        return Result.okv<f64>(loadAt<f64>(this.data, r.value));
    }

    // Decodes a null-terminated UTF-8 string.
    decodeString(): Result<string> {
        const start = this.pos;
        while (true) {
            const r = this.decodeU8();
            if (!r.ok) return r.forward<string>();
            if (r.value == 0) break;
        }
        const bytes = this.data.subarray(start, this.pos - 1);
        const bad = utf8ErrorText(bytes);
        if (bad.length > 0) {
            return DracoError.buffer("Invalid UTF-8 string: " + bad).fail<string>();
        }
        return Result.okv<string>(String.UTF8.decode(bytes.slice(0).buffer));
    }

    // Decodes `out.length` bytes into `out`. Does not check whether
    // bit decoding is active.
    decodeBytes(out: Uint8Array): Status {
        const r = this.takeBytes(out.length);
        if (!r.ok) return r.forward<bool>();
        out.set(this.data.subarray(r.value, r.value + out.length), 0);
        return okStatus();
    }

    // Advances over `size` bytes and returns their start (the shared
    // bounds check of decode_bytes).
    private takeBytes(size: i32): Result<i32> {
        if (size > this.remainingSize()) {
            return DracoError.buffer(
                "Unexpected end of buffer: need " + size.toString() + " bytes, have " + this.remainingSize().toString(),
            ).fail<i32>();
        }
        const start = this.pos;
        this.pos += size;
        return Result.okv<i32>(start);
    }

    // Decodes a variable-length unsigned integer (varint).
    decodeVarint(): Result<u64> {
        let val: u64 = 0;
        let shift: u64 = 0;
        while (true) {
            const r = this.decodeU8();
            if (!r.ok) return r.forward<u64>();
            const b = r.value;
            val |= (<u64>(b & 0x7F)) << shift;
            if ((b & 0x80) == 0) {
                break;
            }
            shift += 7;
            if (shift >= 64) {
                return DracoError.buffer("Varint exceeds 64 bits").fail<u64>();
            }
        }
        return Result.okv<u64>(val);
    }

    // Decodes a Draco-compatible signed varint (ConvertSymbolToSignedInt).
    decodeVarintSignedI32(): Result<i32> {
        const r = this.decodeVarint();
        if (!r.ok) return r.forward<i32>();
        const symbol = <u32>r.value;
        const isPositive = (symbol & 1) == 0;
        const v = symbol >> 1;
        if (isPositive) {
            return Result.okv<i32>(<i32>v);
        }
        return Result.okv<i32>(-(<i32>v) - 1);
    }

    // A view of the remaining data, without advancing.
    remainingData(): Uint8Array {
        return this.data.subarray(this.pos);
    }

    // Advances by `n` bytes, clamped to the end.
    advance(n: u64): void {
        const target = <u64>this.pos + n;
        const len = <u64>this.data.length;
        this.pos = target < <u64>this.pos || target > len ? this.data.length : <i32>target;
    }

    // Advances by `n` bytes, failing when that would pass the end.
    tryAdvance(n: u64): Status {
        const p = <u64>this.pos;
        if (n > u64.MAX_VALUE - p) {
            return DracoError.buffer("Buffer advance overflow").fail<bool>();
        }
        const newPos = p + n;
        if (newPos > <u64>this.data.length) {
            return DracoError.buffer(
                "Cannot advance buffer by " + n.toString() + " bytes: need position " + newPos.toString() +
                ", buffer length " + this.data.length.toString(),
            ).fail<bool>();
        }
        this.pos = <i32>newPos;
        return okStatus();
    }

    // Returns a view of the next `size` bytes and advances past them.
    decodeSlice(size: u64): Result<Uint8Array> {
        if (size > <u64>this.remainingSize()) {
            return DracoError.buffer(
                "Unexpected end of buffer: need " + size.toString() + " bytes, have " + this.remainingSize().toString(),
            ).fail<Uint8Array>();
        }
        const start = this.pos;
        this.pos += <i32>size;
        return Result.okv<Uint8Array>(this.data.subarray(start, this.pos));
    }
}

function satAddU64(a: u64, b: u64): u64 {
    const s = a + b;
    return s < a ? u64.MAX_VALUE : s;
}

function satMulU64(a: u64, b: u64): u64 {
    if (a == 0 || b == 0) return 0;
    if (a > u64.MAX_VALUE / b) return u64.MAX_VALUE;
    return a * b;
}

// Loads a T (little-endian, unaligned) at `data[pos]`; the caller checked bounds.
function loadAt<T>(data: Uint8Array, pos: i32): T {
    return unsafeLoad<T>(data, pos);
}

unsafe function unsafeLoad<T>(data: Uint8Array, pos: i32): T {
    return load<T>(data.dataStart + <usize>pos);
}

// UTF-8 validation: "" when `b` is valid UTF-8, otherwise
// the Display of the Utf8Error ("invalid utf-8 sequence of N bytes from index
// I" / "incomplete utf-8 byte sequence from index I").
export function utf8ErrorText(b: Uint8Array): string {
    const len = b.length;
    let index = 0;
    while (index < len) {
        const oldOffset = index;
        const first = <u32>b[index];
        if (first >= 128) {
            const w = utf8CharWidth(first);
            let errLen = 0; // 0: none; -1: incomplete
            if (w == 2) {
                index++;
                if (index >= len) errLen = -1;
                else if (!isCont(b[index])) errLen = 1;
            } else if (w == 3) {
                index++;
                if (index >= len) errLen = -1;
                else {
                    const s = <u32>b[index];
                    const okSecond =
                        (first == 0xE0 && s >= 0xA0 && s <= 0xBF) ||
                        (first >= 0xE1 && first <= 0xEC && s >= 0x80 && s <= 0xBF) ||
                        (first == 0xED && s >= 0x80 && s <= 0x9F) ||
                        (first >= 0xEE && first <= 0xEF && s >= 0x80 && s <= 0xBF);
                    if (!okSecond) errLen = 1;
                    else {
                        index++;
                        if (index >= len) errLen = -1;
                        else if (!isCont(b[index])) errLen = 2;
                    }
                }
            } else if (w == 4) {
                index++;
                if (index >= len) errLen = -1;
                else {
                    const s = <u32>b[index];
                    const okSecond =
                        (first == 0xF0 && s >= 0x90 && s <= 0xBF) ||
                        (first >= 0xF1 && first <= 0xF3 && s >= 0x80 && s <= 0xBF) ||
                        (first == 0xF4 && s >= 0x80 && s <= 0x8F);
                    if (!okSecond) errLen = 1;
                    else {
                        index++;
                        if (index >= len) errLen = -1;
                        else if (!isCont(b[index])) errLen = 2;
                        else {
                            index++;
                            if (index >= len) errLen = -1;
                            else if (!isCont(b[index])) errLen = 3;
                        }
                    }
                }
            } else {
                errLen = 1;
            }
            if (errLen == -1) return "incomplete utf-8 byte sequence from index " + oldOffset.toString();
            if (errLen > 0) {
                return "invalid utf-8 sequence of " + errLen.toString() + " bytes from index " + oldOffset.toString();
            }
        }
        index++;
    }
    return "";
}

function isCont(b: u8): bool {
    return (b & 0xC0) == 0x80;
}

function utf8CharWidth(first: u32): i32 {
    if (first < 0x80) return 1;
    if (first < 0xC2) return 0;
    if (first < 0xE0) return 2;
    if (first < 0xF0) return 3;
    if (first < 0xF5) return 4;
    return 0;
}
