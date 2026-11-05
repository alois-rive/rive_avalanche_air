// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Reads uncompressed bits packed into 32-bit words (Draco's
// `direct_bit_decoder.h`).

import { BIT_NONE } from "../core/bit_utils";
import { DecoderBuffer } from "../core/decoder_buffer";

export class DirectBitDecoder {
    bits: Array<u32> = [];
    pos: i32 = 0;
    numUsedBits: u32 = 0;

    constructor() {}

    clear(): void {
        this.bits.length = 0;
        this.pos = 0;
        this.numUsedBits = 0;
    }

    startDecoding(sourceBuffer: DecoderBuffer): bool {
        this.clear();
        const sr = sourceBuffer.decodeU32();
        if (!sr.ok) return false;
        const sizeInBytes = sr.value;

        if (sizeInBytes == 0 || (sizeInBytes & 0x3) != 0) {
            return false;
        }
        const numWords = <i32>(sizeInBytes / 4);
        if (<u64>sourceBuffer.remainingSize() < <u64>sizeInBytes) {
            return false;
        }
        for (let i = 0; i < numWords; i++) {
            const w = sourceBuffer.decodeU32();
            if (!w.ok) return false;
            this.bits.push(w.value);
        }
        this.pos = 0;
        this.numUsedBits = 0;
        return true;
    }

    // The next bit, 1 or 0, or BIT_NONE once the
    // buffer is spent (exact: `pos` past the words is the whole condition).
    decodeNextBit(): i64 {
        if (this.pos >= this.bits.length) {
            return BIT_NONE;
        }
        const selector = <u32>1 << (31 - this.numUsedBits);
        const bit = (this.bits[this.pos] & selector) != 0;
        this.numUsedBits += 1;
        if (this.numUsedBits == 32) {
            this.pos += 1;
            this.numUsedBits = 0;
        }
        return bit ? 1 : 0;
    }

    // The next `nbits` bits as a value, or BIT_NONE when they are not
    // there (nothing is consumed then).
    decodeLeastSignificantBits32(nbits: u32): i64 {
        if (nbits == 0 || nbits > 32) {
            return BIT_NONE;
        }
        const remaining: u32 = 32 - this.numUsedBits;
        let value: u32;
        if (nbits <= remaining) {
            if (this.pos < 0 || this.pos >= this.bits.length) {
                return BIT_NONE;
            }
            const word = this.bits[this.pos];
            value = (word << this.numUsedBits) >> (32 - nbits);
            this.numUsedBits += nbits;
            if (this.numUsedBits == 32) {
                this.pos += 1;
                this.numUsedBits = 0;
            }
        } else {
            if (this.pos == i32.MAX_VALUE) {
                return BIT_NONE;
            }
            const nextPos = this.pos + 1;
            if (this.pos < 0 || nextPos >= this.bits.length) {
                return BIT_NONE;
            }
            const wordL = this.bits[this.pos];
            const wordR = this.bits[nextPos];
            const valueL = wordL << this.numUsedBits;
            this.numUsedBits = nbits - remaining;
            this.pos = nextPos;
            const valueR = wordR >> (32 - this.numUsedBits);
            value = (valueL >> (32 - this.numUsedBits - remaining)) | valueR;
        }
        return <i64>value;
    }

    endDecoding(): void {}
}
