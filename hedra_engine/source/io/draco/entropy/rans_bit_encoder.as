// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Binary (two-symbol) rANS encoder. Buffers boolean bits, estimates the zero
// probability and rANS-encodes them (Draco's `rans_bit_encoder.h`).

import { f64ToU32, panic } from "../../../../base/util";
import { EncoderBuffer } from "../core/encoder_buffer";
import { countOneBits32, reverseBits32 } from "../core/bit_utils";
import { ANS_L_BASE, AnsCoder } from "./ans";

export class RAnsBitEncoder {
    bitCounts0: u64 = 0;
    bitCounts1: u64 = 0;
    bits: Array<u32> = [];
    localBits: u32 = 0;
    numLocalBits: u32 = 0;

    constructor() {}

    startEncoding(): void {
        this.clear();
    }

    clear(): void {
        this.bitCounts0 = 0;
        this.bitCounts1 = 0;
        this.bits.length = 0;
        this.localBits = 0;
        this.numLocalBits = 0;
    }

    encodeBit(bit: bool): void {
        if (bit) {
            this.bitCounts1 += 1;
            this.localBits |= <u32>1 << this.numLocalBits;
        } else {
            this.bitCounts0 += 1;
        }
        this.numLocalBits += 1;

        if (this.numLocalBits == 32) {
            this.bits.push(this.localBits);
            this.numLocalBits = 0;
            this.localBits = 0;
        }
    }

    encodeLeastSignificantBits32(nbits: u32, value: u32): void {
        if (!(nbits <= 32)) panic("assertion failed: nbits <= 32");
        if (!(nbits > 0)) panic("assertion failed: nbits > 0");

        const reversed = reverseBits32(value) >> (32 - nbits);
        const ones = countOneBits32(reversed);
        this.bitCounts0 += <u64>(nbits - ones);
        this.bitCounts1 += <u64>ones;

        const remaining: u32 = 32 - this.numLocalBits;

        if (nbits <= remaining) {
            this.localBits |= reversed << this.numLocalBits;
            this.numLocalBits += nbits;
            if (this.numLocalBits == 32) {
                this.bits.push(this.localBits);
                this.localBits = 0;
                this.numLocalBits = 0;
            }
        } else {
            this.localBits |= reversed << this.numLocalBits;
            this.bits.push(this.localBits);
            this.localBits = reversed >> remaining;
            this.numLocalBits = nbits - remaining;
        }
    }

    endEncoding(targetBuffer: EncoderBuffer): void {
        let total = this.bitCounts1 + this.bitCounts0;
        if (total == 0) total = 1;

        const zeroProbRaw = f64ToU32((<f64>this.bitCounts0 / <f64>total) * 256.0 + 0.5);
        let zeroProb: u8 = zeroProbRaw < 255 ? <u8>zeroProbRaw : 255;
        if (zeroProb == 0) {
            zeroProb += 1;
        }

        const ansCoder = new AnsCoder();
        ansCoder.writeInit(ANS_L_BASE);

        // Encode remaining local bits
        for (let i = <i32>this.numLocalBits - 1; i >= 0; i--) {
            const bit = (this.localBits >> <u32>i) & 1;
            ansCoder.rabsDescWrite(bit != 0, zeroProb);
        }

        // Encode stored bits
        for (let k = this.bits.length - 1; k >= 0; k--) {
            const val = unchecked(this.bits[k]);
            for (let i = 31; i >= 0; i--) {
                const bit = (val >> <u32>i) & 1;
                ansCoder.rabsDescWrite(bit != 0, zeroProb);
            }
        }

        const sizeR = ansCoder.writeEnd(false);
        const size = sizeR.expect("ANS state should always be valid for bit encoding");

        targetBuffer.encodeU8(zeroProb);

        // Pre-2.2 stores the rANS payload size as a fixed u32; 2.2+ uses a
        // varint; both layouts are written.
        const bitstreamVersion = targetBuffer.bitstreamVersion();
        if (bitstreamVersion != 0 && bitstreamVersion < 0x0202) {
            targetBuffer.encodeU32(<u32>size);
        } else {
            targetBuffer.encodeVarint(<u64>size);
        }

        targetBuffer.encodeData(ansCoder.data());
    }
}
