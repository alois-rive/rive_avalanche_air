// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// A 32-bit integer coded as a sequence of bits, each bit position with its own
// binary rANS context (Draco's `FoldedBit32` coders; used by the KD-tree
// point-cloud coders).

import { panic } from "../../../../base/util";
import { BIT_NONE } from "../core/bit_utils";
import { DecoderBuffer } from "../core/decoder_buffer";
import { EncoderBuffer } from "../core/encoder_buffer";
import { RAnsBitDecoder } from "./rans_bit_decoder";
import { RAnsBitEncoder } from "./rans_bit_encoder";

export class FoldedBit32Encoder {
    foldedNumberEncoders: Array<RAnsBitEncoder> = [];
    bitEncoder: RAnsBitEncoder = new RAnsBitEncoder();

    constructor() {
        for (let i = 0; i < 32; i++) this.foldedNumberEncoders.push(new RAnsBitEncoder());
    }

    startEncoding(): void {
        for (let i = 0; i < this.foldedNumberEncoders.length; i++) {
            this.foldedNumberEncoders[i].startEncoding();
        }
        this.bitEncoder.startEncoding();
    }

    encodeBit(bit: bool): void {
        this.bitEncoder.encodeBit(bit);
    }

    encodeLeastSignificantBits32(nbits: u32, value: u32): void {
        if (!(nbits > 0 && nbits <= 32)) panic("assertion failed: nbits > 0 && nbits <= 32");
        let selector = <u32>1 << (nbits - 1);
        for (let i: u32 = 0; i < nbits; i++) {
            const bit = (value & selector) != 0;
            this.foldedNumberEncoders[<i32>i].encodeBit(bit);
            selector >>= 1;
        }
    }

    endEncoding(targetBuffer: EncoderBuffer): void {
        for (let i = 0; i < this.foldedNumberEncoders.length; i++) {
            this.foldedNumberEncoders[i].endEncoding(targetBuffer);
        }
        this.bitEncoder.endEncoding(targetBuffer);
    }
}

export class FoldedBit32Decoder {
    foldedNumberDecoders: Array<RAnsBitDecoder> = [];
    bitDecoder: RAnsBitDecoder = new RAnsBitDecoder();

    constructor() {
        for (let i = 0; i < 32; i++) this.foldedNumberDecoders.push(new RAnsBitDecoder());
    }

    startDecoding(sourceBuffer: DecoderBuffer): bool {
        for (let i = 0; i < this.foldedNumberDecoders.length; i++) {
            if (!this.foldedNumberDecoders[i].startDecoding(sourceBuffer)) {
                return false;
            }
        }
        return this.bitDecoder.startDecoding(sourceBuffer);
    }

    // Reads the next bit, answering false both for an encoded zero and for a
    // spent stream (see RAnsBitDecoder.decodeNextBit).
    decodeNextBit(): bool {
        return this.bitDecoder.decodeNextBit();
    }

    // The next `nbits` bits as a value, or BIT_NONE when decoding fails.
    decodeLeastSignificantBits32(nbits: u32): i64 {
        if (nbits == 0 || nbits > 32) {
            return BIT_NONE;
        }
        let result: u32 = 0;
        for (let i: u32 = 0; i < nbits; i++) {
            if (<i32>i >= this.foldedNumberDecoders.length) {
                return BIT_NONE;
            }
            const bit = this.foldedNumberDecoders[<i32>i].decodeNextBit();
            result = (result << 1) + (bit ? 1 : 0);
        }
        return <i64>result;
    }

    endDecoding(): void {
        this.bitDecoder.endDecoding();
        for (let i = 0; i < this.foldedNumberDecoders.length; i++) {
            this.foldedNumberDecoders[i].endDecoding();
        }
    }
}
