// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Multi-symbol rANS decoder (Draco's `rans_symbol_decoder.h`). Precision is a
// runtime value (`new RAnsSymbolDecoder(bits)`).

import { DecoderBuffer } from "../core/decoder_buffer";
import { AnsDecoder } from "./ans";
import { RAnsSymbol } from "./rans_symbol_coding";

// tryDecodeSymbol found no symbol.
export const SYMBOL_NONE: i64 = -1;

// Cap on the probability-table entries the decoder allocates (see the
// guard in decodeTable).
const MAX_TABLE_SYMBOLS: u64 = 1 << 26;

export class RAnsSymbolDecoder {
    ans: AnsDecoder = new AnsDecoder(new Uint8Array(0));
    probabilityTable: Array<RAnsSymbol> = [];
    lut: Uint32Array = new Uint32Array(0);
    numSymbols_: i32 = 0;
    // `probabilityTable.length - 1`, the table having been padded to a power
    // of two, so a masked symbol id always indexes in bounds.
    tableMask: u32 = 0;
    ransPrecisionBits: u32;
    ransPrecisionMask: u32;
    ransPrecision: u32;
    lRansBase: u32;

    constructor(ransPrecisionBits: u32) {
        const ransPrecision = <u32>1 << ransPrecisionBits;
        this.ransPrecisionBits = ransPrecisionBits;
        this.ransPrecisionMask = ransPrecision - 1;
        this.ransPrecision = ransPrecision;
        this.lRansBase = ransPrecision * 4;
    }

    create(buffer: DecoderBuffer): bool {
        if (!this.decodeTable(buffer)) {
            return false;
        }
        return true;
    }

    private decodeTable(buffer: DecoderBuffer): bool {
        const bitstreamVersion = buffer.bitstreamVersion();
        let numSymbols: u64;
        if (bitstreamVersion < 0x0200) {
            // Legacy (< 2.0) layout: a fixed u32 symbol count.
            const r = buffer.decodeU32();
            if (!r.ok) return false;
            numSymbols = <u64>r.value;
        } else {
            const r = buffer.decodeVarint();
            if (!r.ok) return false;
            numSymbols = r.value;
        }
        // The count is stored (saturated) before any check.
        this.numSymbols_ = numSymbols > <u64>i32.MAX_VALUE ? i32.MAX_VALUE : <i32>numSymbols;
        if (numSymbols == 0) {
            return true;
        }

        // Each table entry consumes at least one input byte and one byte
        // covers at most 64 entries, so a larger count cannot be backed by
        // the remaining input.
        if (numSymbols > <u64>buffer.remainingSize() * 64) {
            return false;
        }
        // A table this large does not fit the wasm heap. Unreachable for any real
        // stream (raw tables hold at most 2^18 entries, tagged ones 33).
        if (numSymbols > MAX_TABLE_SYMBOLS) {
            return false;
        }
        const n = <i32>numSymbols;

        resizeTable(this.probabilityTable, n);
        const table = this.probabilityTable;

        // C++ only early-returns for num_symbols == 0: for 1 it still reads
        // the probability byte, and so must we to stay in sync.
        let i = 0;
        while (i < n) {
            const br = buffer.decodeU8();
            if (!br.ok) return false;
            const b = br.value;

            const mode = b & 3;
            if (mode == 3) {
                // Zero frequency offset
                const offset = <i32>(b >> 2);
                for (let j = 0; j <= offset; j++) {
                    if (i + j >= n) {
                        return false;
                    }
                    table[i + j].prob = 0;
                }
                i += offset;
            } else {
                const numExtraBytes = <i32>mode;
                let prob = <u32>(b >> 2);
                for (let bIdx = 0; bIdx < numExtraBytes; bIdx++) {
                    const er = buffer.decodeU8();
                    if (!er.ok) return false;
                    prob |= (<u32>er.value) << <u32>(8 * (bIdx + 1) - 2);
                }
                table[i].prob = prob;
            }
            i += 1;
        }

        // Compute cumulative probabilities and LUT.
        const precision = <i32>this.ransPrecision;
        if (this.lut.length != precision) {
            const nl = new Uint32Array(precision);
            const keep = this.lut.length < precision ? this.lut.length : precision;
            for (let k = 0; k < keep; k++) nl[k] = this.lut[k];
            this.lut = nl;
        }
        const lut = this.lut;
        let cumProb: u32 = 0;
        for (let s = 0; s < n; s++) {
            const prob = table[s].prob;
            table[s].cumProb = cumProb;
            // Bounds check: ensure we don't write past the LUT.
            const sum = cumProb + prob;
            const endIdx: u32 = sum < cumProb ? u32.MAX_VALUE : sum; // saturating_add
            if (endIdx > this.ransPrecision) {
                // Malformed probability table - probabilities exceed precision
                return false;
            }
            lut.fill(<u32>s, <i32>cumProb, <i32>endIdx);
            cumProb = endIdx;
        }

        if (cumProb != this.ransPrecision) {
            return false;
        }

        // Pad the table to a power of two so decodeRun can mask instead of check.
        let padded = 1;
        while (padded < n) padded <<= 1;
        resizeTable(table, padded);
        this.tableMask = <u32>(padded - 1);
        return true;
    }

    // How many distinct symbols the table holds. One or none means no rANS
    // state at all: the run is that symbol repeated.
    numSymbols(): i32 {
        return this.numSymbols_;
    }

    startDecoding(buffer: DecoderBuffer): bool {
        // Draco advances past the encoded rANS data regardless of the number
        // of symbols. v < 2.0 uses a fixed u64, v >= 2.0 a varint.
        const bitstreamVersion = buffer.bitstreamVersion();
        let bytesToRead: u64;
        if (bitstreamVersion < 0x0200) {
            const r = buffer.decode<u64>();
            if (!r.ok) return false;
            bytesToRead = r.value;
        } else {
            const r = buffer.decodeVarint();
            if (!r.ok) return false;
            bytesToRead = r.value;
        }
        if (this.numSymbols_ <= 1) {
            // Still need to advance the buffer past the encoded bytes.
            if (!buffer.tryAdvance(bytesToRead).ok) {
                return false;
            }
            return true;
        }
        const data = buffer.remainingData();
        if (<u64>data.length < bytesToRead) {
            return false;
        }

        const ransData = data.subarray(0, <i32>bytesToRead);
        this.ans = new AnsDecoder(ransData);
        // Multi-symbol rANS may use the 4-byte (0xC0) final-state encoding.
        if (!this.ans.readInit(this.lRansBase, true)) {
            return false;
        }

        if (!buffer.tryAdvance(bytesToRead).ok) {
            return false;
        }
        return true;
    }

    // Decodes one symbol into every slot of `out[start..end)`.
    // Returns whether every symbol came
    // out of the coded bytes: false once the run outlived its payload (the
    // state could no longer renormalize), in which case the remaining slots
    // are still filled from the state alone.
    decodeRun(out: Array<u32>, start: i32, end: i32): bool {
        // A single-symbol alphabet carries no rANS state: the run is that
        // symbol repeated.
        if (this.numSymbols_ <= 1) {
            for (let k = start; k < end; k++) out[k] = 0;
            return true;
        }
        const precision = <i32>this.ransPrecision;
        if (this.lut.length < precision || this.probabilityTable.length == 0) {
            for (let k = start; k < end; k++) out[k] = 0;
            return false;
        }
        const lut = this.lut;
        const table = this.probabilityTable;
        const tableMask = this.tableMask;
        const mask = this.ransPrecisionMask;
        const bits = this.ransPrecisionBits;
        const lBase = this.ans.lBase;
        const buf = this.ans.buf;
        let offset = this.ans.bufOffset < buf.length ? this.ans.bufOffset : buf.length;
        let state = this.ans.state;

        // Set once the state could not be refilled, never cleared.
        let backed = true;
        for (let k = start; k < end; k++) {
            while (state < lBase && offset > 0) {
                offset -= 1;
                state = (state << 8) | <u32>unchecked(buf[offset]);
            }
            backed = backed && state >= lBase;
            const quo = state >> bits;
            const rem = state & mask;
            const symbolId = unchecked(lut[<i32>rem]);
            const sym = table[<i32>(symbolId & tableMask)];
            state = quo * sym.prob + (rem - sym.cumProb);
            out[k] = symbolId;
        }

        this.ans.bufOffset = offset;
        this.ans.state = state;
        return backed;
    }

    @inline
    decodeSymbol(): u32 {
        const r = this.tryDecodeSymbol();
        return r < 0 ? 0 : <u32>r;
    }

    // The next symbol, or SYMBOL_NONE when the table or the
    // state is inconsistent.
    tryDecodeSymbol(): i64 {
        if (this.numSymbols_ <= 1) {
            return 0;
        }
        // Normalize first, then shift/mask by the power-of-two precision
        // (Draco C++ rans_read()).
        this.ans.readNormalize();
        const quo = this.ans.state >> this.ransPrecisionBits;
        const rem = this.ans.state & this.ransPrecisionMask;
        if (<i64>rem >= <i64>this.lut.length) return SYMBOL_NONE;
        const symbolId = this.lut[<i32>rem];
        if (<u64>symbolId >= <u64>this.probabilityTable.length) return SYMBOL_NONE;
        const sym = this.probabilityTable[<i32>symbolId];
        const stateBase = <u64>quo * <u64>sym.prob;
        if (stateBase > <u64>u32.MAX_VALUE) return SYMBOL_NONE;
        if (rem < sym.cumProb) return SYMBOL_NONE;
        const stateOffset = rem - sym.cumProb;
        const next = stateBase + <u64>stateOffset;
        if (next > <u64>u32.MAX_VALUE) return SYMBOL_NONE;
        this.ans.state = <u32>next;
        return <i64>symbolId;
    }
}

// Resizes `t` to `n` entries, new ones zeroed.
function resizeTable(t: Array<RAnsSymbol>, n: i32): void {
    while (t.length > n) t.pop();
    while (t.length < n) t.push(RAnsSymbol(0, 0));
}
