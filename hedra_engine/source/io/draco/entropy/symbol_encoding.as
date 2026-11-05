// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Encoding/decoding u32 symbol streams with the tagged and raw schemes over
// rANS (Draco's `symbol_encoding.h`).
//
// Inputs are Array<u32>; the output is an Array<u32> that the decoders
// clear/append to. Counts that come from a stream (`num_values`) are u64.

import { i64FitsI32 } from "../../../../base/util";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DracoError, ErrorKind, Status, okStatus } from "../core/status";
import { computeRansPrecisionFromUniqueSymbolsBitLength } from "./rans_symbol_coding";
import { RAnsSymbolDecoder, SYMBOL_NONE } from "./rans_symbol_decoder";

export class SymbolEncodingOptions {
    compressionLevel: i32 = 7;

    // The default options.
    constructor() {}
}

// ============================================================================
// Encoder-only functions
// ============================================================================

// a * b and a + b, saturated at i32's largest (below i32's least they
// wrap), tested with i64FitsI32 (base/util.as).
export function satMulI32(a: i32, b: i32): i32 {
    const p = <i64>a * <i64>b;
    return p > 0 && !i64FitsI32(p) ? i32.MAX_VALUE : <i32>p;
}

export function satAddI32(a: i32, b: i32): i32 {
    const s = <i64>a + <i64>b;
    return s > 0 && !i64FitsI32(s) ? i32.MAX_VALUE : <i32>s;
}

// ============================================================================
// Decoder-only functions
// ============================================================================

// Capacity bookkeeping for the output sink, modelled on a growable vector:
// the capacity is what decides the chunk boundaries of the raw decode (so
// where a failing decode stops), and it is never allowed to run ahead of
// decoded symbols.
// The minimum non-zero capacity for 4-byte elements.
const MIN_NON_ZERO_CAP: u64 = 4;

// Largest u32 sink that can be allocated (AS ArrayBuffer block limit / 4).
const MAX_SYMBOL_CAPACITY: u64 = ((1 << 30) - 16) / 4;

export function decodeSymbols(
    numValues: u64,
    numComponents: u64,
    options: SymbolEncodingOptions,
    inBuffer: DecoderBuffer,
    symbols: Array<u32>,
): Status {
    symbols.length = 0;
    if (numValues == 0) {
        return okStatus();
    }
    if (numComponents == 0) {
        return DracoError.invalidParameter("Symbol decode needs at least one component").fail<bool>();
    }
    if (numValues % numComponents != 0) {
        return DracoError.invalidParameter(
            "Symbol count " + numValues.toString() + " is not a multiple of the " + numComponents.toString() +
            " components it is read into",
        ).fail<bool>();
    }
    const capacity = reserveWithinInput(0, numValues, inBuffer);

    const schemeR = inBuffer.decodeU8();
    if (!schemeR.ok) {
        return DracoError.buffer("Buffer ran out reading the symbol coding scheme").fail<bool>();
    }
    const scheme = schemeR.value;

    // Draco uses: 0 = TAGGED, 1 = RAW.
    switch (scheme) {
        case 0:
            return decodeTaggedSymbols(numValues, numComponents, inBuffer, symbols);
        case 1:
            return decodeRawSymbolsWithCapacity(numValues, inBuffer, symbols, capacity);
        default:
            return DracoError.unsupportedFeature(
                "Unknown symbol coding scheme " + scheme.toString() + ": Draco defines 0 (tagged) and 1 (raw)",
            ).fail<bool>();
    }
}

// Reserves for what the stream could plausibly produce, not for what it
// says: at most sixty-four symbols per remaining input byte. Returns the
// sink's capacity after reserving that many symbols in an empty sink whose
// capacity was `cap` (amortized growth: at least doubling).
function reserveWithinInput(cap: u64, numValues: u64, inBuffer: DecoderBuffer): u64 {
    const byInput = <u64>inBuffer.remainingSize() * 64;
    const additional = numValues < byInput ? numValues : byInput;
    if (additional <= cap) return cap;
    let newCap = cap * 2 > additional ? cap * 2 : additional;
    if (newCap < MIN_NON_ZERO_CAP) newCap = MIN_NON_ZERO_CAP;
    return newCap;
}

// Decodes `numValues` raw-coded symbols and appends them to
// `symbols` (a sink with no spare capacity).
export function decodeRawSymbols(numValues: u64, inBuffer: DecoderBuffer, symbols: Array<u32>): Status {
    return decodeRawSymbolsWithCapacity(numValues, inBuffer, symbols, <u64>symbols.length);
}

function decodeRawSymbolsWithCapacity(
    numValues: u64,
    inBuffer: DecoderBuffer,
    symbols: Array<u32>,
    capacity: u64,
): Status {
    // Read the serialized symbol-bit-length header (written by the encoder).
    const blR = inBuffer.decodeU8();
    if (!blR.ok) {
        return DracoError.buffer("Buffer ran out reading the raw symbol bit length").fail<bool>();
    }
    const symbolsBitLength = <u32>blR.value;
    if (!(symbolsBitLength >= 1 && symbolsBitLength <= 18)) {
        return DracoError.general(
            "Raw symbol bit length " + symbolsBitLength.toString() + " outside the supported range 1..=18",
        ).fail<bool>();
    }
    const uniqueSymbolsBitLength = symbolsBitLength;
    const precisionBits = computeRansPrecisionFromUniqueSymbolsBitLength(uniqueSymbolsBitLength);

    const decoder = new RAnsSymbolDecoder(precisionBits);
    if (!decoder.create(inBuffer)) {
        return DracoError.general("Failed to read the raw scheme's rANS frequency table").fail<bool>();
    }
    // Taken before startDecoding walks past the coded bytes.
    const beforePayload = inBuffer.remainingSize();
    if (!decoder.startDecoding(inBuffer)) {
        return DracoError.general("Failed to start rANS decoding of the raw symbols").fail<bool>();
    }
    const after = inBuffer.remainingSize();
    const payloadBytes: u64 = beforePayload > after ? <u64>(beforePayload - after) : 0;
    // Only the part of the count the payload cannot plausibly account for
    // (sixty-four symbols per payload byte) is charged to the budget.
    const backedByPayload = payloadBytes * 64;
    if (numValues > backedByPayload) {
        const c = inBuffer.chargeElements(numValues - backedByPayload, 4);
        if (!c.ok) return c;
    }

    // Growth is capped at `numValues`, and only ever doubles proven content.
    let cap = capacity;
    let index: u64 = 0;
    while (index < numValues) {
        const len = <u64>symbols.length;
        if (len == cap) {
            const twice = cap > u64.MAX_VALUE / 2 ? u64.MAX_VALUE : cap * 2;
            const doubled = twice > len + 1 ? twice : len + 1;
            const upper = numValues > len + 1 ? numValues : len + 1;
            const target = doubled < upper ? doubled : upper;
            // Grows exactly to `target`; past the block limit the allocation
            // is refused instead of trapping.
            if (target > MAX_SYMBOL_CAPACITY) {
                return DracoError.general("Failed to allocate " + target.toString() + " raw symbols").fail<bool>();
            }
            if (target > cap) cap = target;
        }
        const room = cap - <u64>symbols.length;
        const chunkEnd = numValues < index + room ? numValues : index + room;
        // One call per chunk: the run loop owns the whole span.
        const filled = symbols.length;
        const newLen = filled + <i32>(chunkEnd - index);
        symbols.length = newLen;
        if (!decoder.decodeRun(symbols, filled, newLen)) {
            return DracoError.create(
                ErrorKind.AllocationExceedsInput,
                "the stream declared " + numValues.toString() + " symbols, more than its coded bytes carry",
            ).fail<bool>();
        }
        index = chunkEnd;
    }
    return okStatus();
}

export function decodeTaggedSymbols(
    numValues: u64,
    numComponents: u64,
    inBuffer: DecoderBuffer,
    symbols: Array<u32>,
): Status {
    if (numComponents == 0 || numValues % numComponents != 0) {
        return DracoError.invalidParameter(
            "Tagged symbol count " + numValues.toString() + " is not a multiple of the " + numComponents.toString() +
            " components it is read into",
        ).fail<bool>();
    }

    // C++ RAnsSymbolDecoder<5>: unique_symbols_bit_length 5 = precision 12.
    const tagDecoder = new RAnsSymbolDecoder(12);

    if (!tagDecoder.create(inBuffer)) {
        return DracoError.general("Failed to read the tagged scheme's rANS frequency table").fail<bool>();
    }
    if (!tagDecoder.startDecoding(inBuffer)) {
        return DracoError.general("Failed to start rANS decoding of the tagged symbol tags").fail<bool>();
    }

    // Start bit-decoding for the raw values (value_buffer).
    if (!inBuffer.startBitDecoding(false).ok) {
        return DracoError.buffer("Buffer ran out starting the tagged value bit stream").fail<bool>();
    }

    const numChunks = numValues / numComponents;

    for (let chunk: u64 = 0; chunk < numChunks; chunk++) {
        const lenR = tagDecoder.tryDecodeSymbol();
        if (lenR == SYMBOL_NONE) {
            return DracoError.general(
                "Tag stream ended after " + chunk.toString() + " of " + numChunks.toString() + " chunks",
            ).fail<bool>();
        }
        const len = <u32>lenR;
        if (len == 0 || len > 32) {
            return DracoError.general(
                "Tagged value width " + len.toString() + " outside the supported range 1..=32",
            ).fail<bool>();
        }
        for (let c: u64 = 0; c < numComponents; c++) {
            const valR = inBuffer.decodeLeastSignificantBits32Fast(len);
            if (!valR.ok) {
                return DracoError.buffer(
                    "Value bit stream ran out reading " + len.toString() + " bits in chunk " + chunk.toString() +
                    " of " + numChunks.toString(),
                ).fail<bool>();
            }
            symbols.push(valR.value);
        }
    }

    inBuffer.endBitDecoding();

    return okStatus();
}
