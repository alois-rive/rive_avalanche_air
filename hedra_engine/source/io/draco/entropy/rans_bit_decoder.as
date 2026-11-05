// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Binary (two-symbol) rANS decoder (Draco's `rans_bit_decoder.h`). Used for
// boolean side channels such as crease flags and EdgeBreaker symbols.

import { BIT_NONE } from "../core/bit_utils";
import { DecoderBuffer } from "../core/decoder_buffer";
import { ANS_L_BASE, AnsDecoder } from "./ans";

export class RAnsBitDecoder {
    ansDecoder: AnsDecoder? = null;
    probZero: u8 = 0;

    constructor() {}

    startDecoding(sourceBuffer: DecoderBuffer): bool {
        this.clear();

        // Read zero_prob
        const probR = sourceBuffer.decode<u8>();
        if (!probR.ok) return false;
        this.probZero = probR.value;

        // Read size_in_bytes. v < 2.2 uses a fixed u32, v >= 2.2 a varint
        // (both layouts are decoded).
        const bitstreamVersion = sourceBuffer.bitstreamVersion();
        let size: u32;
        if (bitstreamVersion < 0x0202) {
            const r = sourceBuffer.decode<u32>();
            if (!r.ok) return false;
            size = r.value;
        } else {
            const r = sourceBuffer.decodeVarint();
            if (!r.ok) return false;
            size = <u32>r.value;
        }

        const sliceR = sourceBuffer.decodeSlice(<u64>size);
        if (sliceR.ok) {
            const decoder = new AnsDecoder(sliceR.value);
            // Binary rABS uses the 1..=3 byte final-state encoding (no 0xC0 tag).
            if (decoder.readInit(ANS_L_BASE, false)) {
                this.ansDecoder = decoder;
                return true;
            }
        }

        return false;
    }

    // Reads the next bit, answering false both for an encoded zero and for a
    // decoder that was never started. It cannot report reading past the
    // encoded bits (the rABS tail legitimately draws from state alone), so
    // callers bound their read counts structurally.
    decodeNextBit(): bool {
        const decoder = this.ansDecoder;
        if (decoder != null) {
            return decoder.rabsDescRead(this.probZero);
        }
        return false;
    }

    // The next `nbits` bits as a value (MSB-first accumulation, like Draco
    // C++), or BIT_NONE when decoding fails.
    decodeLeastSignificantBits32(nbits: i32): i64 {
        if (nbits <= 0 || nbits > 32 || this.ansDecoder == null) {
            return BIT_NONE;
        }

        let value: u32 = 0;
        for (let i = 0; i < nbits; i++) {
            const bit = this.decodeNextBit();
            value = (value << 1) + (bit ? 1 : 0);
        }
        return <i64>value;
    }

    endDecoding(): void {
        this.ansDecoder = null;
    }

    private clear(): void {
        this.ansDecoder = null;
        this.probZero = 0;
    }
}
