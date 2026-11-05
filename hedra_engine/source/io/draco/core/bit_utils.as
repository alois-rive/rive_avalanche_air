// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Bit packing into a byte slice, bit counting and reversal.
//
// The encoder and decoder hold a
// Uint8Array (a `subarray` view works the same way: writes go to the
// underlying buffer). A missing result from getBits/getBit is a `-1`
// sentinel in an i64 (`BIT_NONE`).

// BitDecoder.getBits / getBit found no bits.
export const BIT_NONE: i64 = -1;

export class BitEncoder {
    private buffer: Uint8Array;
    private bitOffset: i64 = 0;

    constructor(buffer: Uint8Array) {
        this.buffer = buffer;
    }

    putBits(data: u32, nbits: u32): void {
        for (let i: u32 = 0; i < nbits; i++) {
            // `data >> i`: nbits must be at most 32.
            this.putBit((data >> i) & 1);
        }
    }

    putBit(bit: u32): void {
        const byteOffset = this.bitOffset / 8;
        const bitShift = <u32>(this.bitOffset % 8);
        if (byteOffset < <i64>this.buffer.length) {
            const i = <i32>byteOffset;
            if (bit != 0) {
                this.buffer[i] = this.buffer[i] | <u8>(1 << bitShift);
            } else {
                this.buffer[i] = this.buffer[i] & ~<u8>(1 << bitShift);
            }
        }
        this.bitOffset += 1;
    }

    bits(): i64 {
        return this.bitOffset;
    }
}

export class BitDecoder {
    private buffer: Uint8Array;
    private bitOffset: i64 = 0;

    constructor(buffer: Uint8Array) {
        this.buffer = buffer;
    }

    // `nbits` bits LSB first, or BIT_NONE when the buffer runs out.
    getBits(nbits: u32): i64 {
        let value: u32 = 0;
        for (let i: u32 = 0; i < nbits; i++) {
            const bit = this.getBit();
            if (bit < 0) return BIT_NONE;
            value |= (<u32>bit) << i;
        }
        return <i64>value;
    }

    // One bit (0 or 1), or BIT_NONE past the end.
    getBit(): i64 {
        const byteOffset = this.bitOffset / 8;
        const bitShift = <u32>(this.bitOffset % 8);
        if (byteOffset < <i64>this.buffer.length) {
            const bit = (<u32>this.buffer[<i32>byteOffset] >> bitShift) & 1;
            this.bitOffset += 1;
            return <i64>bit;
        }
        return BIT_NONE;
    }

    bitsDecoded(): i64 {
        return this.bitOffset;
    }
}

export function reverseBits32(n: u32): u32 {
    n = ((n >> 1) & 0x55555555) | ((n & 0x55555555) << 1);
    n = ((n >> 2) & 0x33333333) | ((n & 0x33333333) << 2);
    n = ((n >> 4) & 0x0F0F0F0F) | ((n & 0x0F0F0F0F) << 4);
    n = ((n >> 8) & 0x00FF00FF) | ((n & 0x00FF00FF) << 8);
    return rotl<u32>(n, 16);
}

export function countOneBits32(n: u32): u32 {
    return popcnt<u32>(n);
}
