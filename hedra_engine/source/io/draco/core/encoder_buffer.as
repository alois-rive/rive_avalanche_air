// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Output buffer for a Draco bitstream, with byte-aligned writes and packed
// bit-level encoding.
//
// `data()` is a view of the encoded bytes, valid until the next write; use
// `toBytes()` for a copy.

import { panic } from "../../../../base/util";
import { ByteVec } from "./byte_vec";
import { DEFAULT_MESH_VERSION, bitstreamVersion as packVersion } from "./version";

export class EncoderBuffer {
    private buffer: ByteVec = new ByteVec();
    private bitEncoderActive: bool = false;
    private bitStartPos: i32 = 0;
    private currentBitOffset: i64 = 0;
    // Default to the latest mesh version so standalone encode/decode agrees
    // with `new DecoderBuffer(..)`.
    private versionMajor_: u8 = DEFAULT_MESH_VERSION.major;
    private versionMinor_: u8 = DEFAULT_MESH_VERSION.minor;
    private encodeBitSequenceSize: bool = false;

    constructor() {}

    // Sets the target Draco bitstream version.
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

    // Packed `0xMMmm` target bitstream version.
    bitstreamVersion(): u16 {
        return packVersion(this.versionMajor_, this.versionMinor_);
    }

    // Clears all encoded bytes and resets active bit encoding state.
    clear(): void {
        this.buffer.clear();
        this.bitEncoderActive = false;
        this.currentBitOffset = 0;
    }

    // Resizes the underlying byte buffer (zero-filling growth).
    resize(nbytes: i32): void {
        this.buffer.resize(nbytes, 0);
    }

    // Starts writing a packed bit sequence of at most `requiredBits` bits.
    startBitEncoding(requiredBits: i64, encodeSize: bool): bool {
        if (this.bitEncoderActive) {
            return false;
        }
        this.encodeBitSequenceSize = encodeSize;
        if (encodeSize) {
            // Reserve 8 bytes for the size (replaced by a varint or 8 fixed bytes later).
            for (let i = 0; i < 8; i++) {
                this.buffer.push(0);
            }
        }
        const requiredBytes = divCeil8(requiredBits);
        this.bitStartPos = this.buffer.length;
        this.buffer.resize(this.bitStartPos + <i32>requiredBytes, 0);
        this.bitEncoderActive = true;
        this.currentBitOffset = 0;
        return true;
    }

    // Finishes the active packed bit sequence.
    endBitEncoding(): void {
        if (!this.bitEncoderActive) {
            return;
        }
        this.bitEncoderActive = false;

        if (this.encodeBitSequenceSize) {
            const encodedBits = this.currentBitOffset;
            const encodedBytes = <i32>divCeil8(encodedBits);
            const version = this.bitstreamVersion();

            const varSizeBuffer = new ByteVec();
            if (version >= 0x0202) {
                // Encode size as varint
                let v = <u64>encodedBytes;
                while (true) {
                    let byte = <u8>(v & 0x7F);
                    v >>= 7;
                    if (v != 0) {
                        byte |= 0x80;
                        varSizeBuffer.push(byte);
                    } else {
                        varSizeBuffer.push(byte);
                        break;
                    }
                }
            } else {
                // Encode size as fixed 8 bytes
                pushU64Le(varSizeBuffer, <u64>encodedBytes);
            }

            const sizeLen = varSizeBuffer.length;
            const reservedPos = this.bitStartPos - 8;

            // Move encoded data to its final position
            const srcPos = this.bitStartPos;
            const dstPos = reservedPos + sizeLen;

            if (dstPos != srcPos) {
                this.buffer.copyWithin(dstPos, srcPos, srcPos + encodedBytes);
            }

            // Write the size
            this.buffer.range(reservedPos, reservedPos + sizeLen).set(varSizeBuffer.data(), 0);

            // Resize buffer to final size
            this.buffer.resize(dstPos + encodedBytes, 0);
        } else {
            // Just resize to actual encoded bytes
            const encodedBytes = <i32>divCeil8(this.currentBitOffset);
            this.buffer.resize(this.bitStartPos + encodedBytes, 0);
        }
    }

    // Writes the least significant `nbits` bits of `value`, LSB first.
    encodeLeastSignificantBits32(nbits: u32, value: u32): bool {
        if (!this.bitEncoderActive) {
            return false;
        }
        if (nbits == 0) {
            return true;
        }

        let remainingBits = nbits;
        let v = value;
        while (remainingBits > 0) {
            const totalBitOffset = this.currentBitOffset;
            const byteOffset = this.bitStartPos + <i32>(totalBitOffset / 8);
            const bitShift = <u32>(totalBitOffset % 8);
            const available: u32 = 8 - bitShift;
            const take = remainingBits < available ? remainingBits : available;
            const mask: u32 = (<u32>1 << take) - 1;
            const bits = v & mask;
            this.buffer.set(byteOffset, this.buffer.get(byteOffset) | <u8>(<u8>bits << <u8>bitShift));

            // `v >>= take` with take <= 8, never 32.
            v >>= take;
            remainingBits -= take;
            this.currentBitOffset += <i64>take;
        }
        return true;
    }

    // Appends a plain-old-data value in native (little-endian) representation.
    encode<T>(data: T): bool {
        // Numbers only (a reference type would store a pointer).
        if (!isInteger<T>() && !isFloat<T>()) ERROR("EncoderBuffer.encode<T> needs a number type");
        if (this.bitEncoderActive) {
            return false;
        }
        this.appendLe<T>(data);
        return true;
    }

    // Appends raw bytes.
    encodeData(data: Uint8Array): bool {
        if (this.bitEncoderActive) {
            return false;
        }
        this.buffer.extend(data);
        return true;
    }

    // Appends one byte.
    encodeU8(val: u8): void {
        this.buffer.push(val);
    }

    // Appends a little-endian u16 (no bit-encoder check).
    encodeU16(val: u16): void {
        this.appendLe<u16>(val);
    }

    // Appends a little-endian u32 (no bit-encoder check).
    encodeU32(val: u32): void {
        this.appendLe<u32>(val);
    }

    // Appends a little-endian u64 (no bit-encoder check).
    encodeU64(val: u64): void {
        this.appendLe<u64>(val);
    }

    // `extend_from_slice(&v.to_le_bytes())`.
    private appendLe<T>(v: T): void {
        const size = <i32>sizeof<T>();
        const pos = this.buffer.length;
        this.buffer.resize(pos + size, 0);
        storeAt<T>(this.buffer.range(pos, pos + size), v);
    }

    // Appends an unsigned LEB128-style Draco varint.
    encodeVarint(val: u64): void {
        let v = val;
        while (true) {
            let byte = <u8>(v & 0x7F);
            v >>= 7;
            if (v != 0) {
                byte |= 0x80;
                this.buffer.push(byte);
            } else {
                this.buffer.push(byte);
                break;
            }
        }
    }

    // Draco-compatible signed varint (ConvertSignedIntToSymbol + unsigned varint).
    encodeVarintSignedI32(val: i32): void {
        let symbol: u32;
        if (val >= 0) {
            symbol = (<u32>val) << 1;
        } else {
            // `-(val + 1)` never overflows (val + 1 >= i32::MIN + 1).
            const mapped = <u32>(-(val + 1));
            symbol = (mapped << 1) | 1;
        }
        this.encodeVarint(<u64>symbol);
    }

    // The encoded bytes (a view, valid until the next write).
    data(): Uint8Array {
        return this.buffer.data();
    }

    // A copy of the encoded bytes.
    toBytes(): Uint8Array {
        return this.buffer.toBytes();
    }

    // The encoded byte length.
    size(): i32 {
        return this.buffer.length;
    }
}

function divCeil8(bits: i64): i64 {
    if (bits < 0) panic("negative bit count");
    return (bits + 7) / 8;
}

function pushU64Le(out: ByteVec, val: u64): void {
    for (let i: u64 = 0; i < 8; i++) {
        out.push(<u8>(val >> (i * 8)));
    }
}

// Stores `v` little-endian into `dst` (exactly sizeof<T>() bytes).
function storeAt<T>(dst: Uint8Array, v: T): void {
    unsafeStore<T>(dst, v);
}

unsafe function unsafeStore<T>(dst: Uint8Array, v: T): void {
    store<T>(dst.dataStart, v);
}
