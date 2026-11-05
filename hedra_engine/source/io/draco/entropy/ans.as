// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The low-level rANS state machine (AnsCoder / AnsDecoder) behind Draco's
// symbol and bit coders (Draco's `ans.h`).
//
// The decoder reads a Uint8Array view (never copied); `buf_offset` is an
// i32 index into it. The coder writes to a ByteVec. All state arithmetic is
// u32 and wraps.

import { Result } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { DracoError } from "../core/status";

export const ANS_P8_PRECISION: u32 = 256;
export const ANS_L_BASE: u32 = 4096;
export const ANS_IO_BASE: u32 = 256;

export class AnsCoder {
    buf: ByteVec = new ByteVec();
    state: u32 = ANS_L_BASE;
    lBase: u32 = ANS_L_BASE;

    constructor() {}

    writeInit(lBase: u32): void {
        this.buf.clear();
        this.lBase = lBase;
        this.state = lBase;
    }

    // Initializes the encoder state and reserves space for the emitted bytes.
    writeInitWithCapacity(lBase: u32, byteCapacity: i32): void {
        this.writeInit(lBase);
        this.buf.reserve(byteCapacity);
    }

    // Serializes the final coder state to the buffer tail and returns the
    // buffer length. `allowFourByteState` mirrors AnsDecoder.readInit: the
    // multi-symbol coder may use the 4-byte (0xC0) encoding for states up to
    // 1 << 30; the binary rABS coder treats that tag as out of range.
    writeEnd(allowFourByteState: bool): Result<i32> {
        const state = this.state - this.lBase;
        if (state < (1 << 6)) {
            this.buf.push(<u8>state);
        } else if (state < (1 << 14)) {
            this.buf.push(<u8>(state & 0xFF));
            this.buf.push(<u8>((0x01 << 6) + ((state >> 8) & 0x3F)));
        } else if (state < (1 << 22)) {
            this.buf.push(<u8>(state & 0xFF));
            this.buf.push(<u8>((state >> 8) & 0xFF));
            this.buf.push(<u8>((0x02 << 6) + ((state >> 16) & 0x3F)));
        } else if (allowFourByteState && state < (1 << 30)) {
            this.buf.push(<u8>(state & 0xFF));
            this.buf.push(<u8>((state >> 8) & 0xFF));
            this.buf.push(<u8>((state >> 16) & 0xFF));
            this.buf.push(<u8>((0x03 << 6) + ((state >> 24) & 0x3F)));
        } else {
            return DracoError.general("State is too large to be serialized: " + state.toString()).fail<i32>();
        }
        return Result.okv<i32>(this.buf.length);
    }

    @inline
    rabsDescWrite(val: bool, p0: u8): void {
        const p = ANS_P8_PRECISION - <u32>p0;
        const lS: u32 = val ? p : <u32>p0;

        if (this.state >= ANS_L_BASE / ANS_P8_PRECISION * ANS_IO_BASE * lS) {
            // ANS_IO_BASE is 256.
            this.buf.push(<u8>(this.state & 0xFF));
            this.state >>= 8;
        }

        const quot = this.state / lS;
        const rem = this.state - quot * lS;
        this.state = quot * ANS_P8_PRECISION + rem + (val ? 0 : p);
    }

    @inline
    rabsDescWriteBits(val: u32, bitLength: u32): void {
        const limit = (this.lBase >> bitLength) * ANS_IO_BASE;
        if (this.state >= limit) {
            // ANS_IO_BASE is 256.
            this.buf.push(<u8>(this.state & 0xFF));
            this.state >>= 8;
        }

        const mask: u32 = (<u32>1 << bitLength) - 1;
        const quot = this.state >> bitLength;
        const rem = this.state & mask;

        this.state = (quot << (bitLength + 8)) + rem + val;
    }

    // The emitted bytes (a view, valid until the next write).
    data(): Uint8Array {
        return this.buf.data();
    }
}

export class AnsDecoder {
    buf: Uint8Array;
    bufOffset: i32 = 0;
    state: u32 = 0;
    lBase: u32 = ANS_L_BASE;

    // Decodes from `buf` (not copied).
    constructor(buf: Uint8Array) {
        this.buf = buf;
    }

    @inline
    readNormalize(): void {
        while (this.state < this.lBase && this.bufOffset > 0) {
            this.bufOffset -= 1;
            this.state = (this.state << 8) | <u32>this.buf[this.bufOffset];
        }
    }

    // Initializes the decoder state from the tail of the buffer.
    //
    // `allowFourByteState` selects between the two C++ variants: the
    // multi-symbol rANS decoder accepts the 0xC0 tag as a 4-byte (30-bit)
    // final state, the binary rABS decoder treats it as malformed. Both then
    // reject any state outside the [lBase, lBase * ANS_IO_BASE) window.
    readInit(lBase: u32, allowFourByteState: bool): bool {
        this.lBase = lBase;
        this.bufOffset = this.buf.length;
        if (this.bufOffset == 0) {
            return false;
        }

        const val = <u32>this.buf[this.bufOffset - 1];
        this.bufOffset -= 1;

        if ((val & 0xC0) == 0x00) {
            this.state = (val & 0x3F) + this.lBase;
        } else if ((val & 0xC0) == 0x40) {
            if (this.bufOffset == 0) {
                return false;
            }
            const val0 = <u32>this.buf[this.bufOffset - 1];
            this.bufOffset -= 1;
            const state = ((val & 0x3F) << 8) | val0;
            this.state = state + this.lBase;
        } else if ((val & 0xC0) == 0x80) {
            if (this.bufOffset < 2) {
                return false;
            }
            const val0 = <u32>this.buf[this.bufOffset - 1];
            const val1 = <u32>this.buf[this.bufOffset - 2];
            this.bufOffset -= 2;
            const state = ((val & 0x3F) << 16) | (val0 << 8) | val1;
            this.state = state + this.lBase;
        } else if (allowFourByteState) {
            // 0xC0 tag: 4-byte (30-bit) final state, only emitted by the
            // multi-symbol rANS encoder.
            if (this.bufOffset < 3) {
                return false;
            }
            const val0 = <u32>this.buf[this.bufOffset - 1];
            const val1 = <u32>this.buf[this.bufOffset - 2];
            const val2 = <u32>this.buf[this.bufOffset - 3];
            this.bufOffset -= 3;
            const state = ((val & 0x3F) << 24) | (val0 << 16) | (val1 << 8) | val2;
            this.state = state + this.lBase;
        } else {
            return false;
        }

        if (this.state >= this.lBase * ANS_IO_BASE) {
            return false;
        }
        return true;
    }

    rabsDescRead(p0: u8): bool {
        const p = ANS_P8_PRECISION - <u32>p0;
        this.readNormalize();

        const x = this.state;
        const quot = x / ANS_P8_PRECISION;
        const rem = x % ANS_P8_PRECISION;
        const xn = quot * p;
        const val = rem < p;

        if (val) {
            this.state = xn + rem;
        } else {
            this.state = x - xn - p;
        }
        return val;
    }
}
