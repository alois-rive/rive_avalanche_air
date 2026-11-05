// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The valence-based EdgeBreaker traversal decoder (Draco's higher-compression
// "valence" traversal), which picks each symbol's context from the local
// vertex degree. Follows Draco's
// `mesh_edgebreaker_traversal_valence_decoder.h`.

import { DracoError, Status, okStatus } from "../core/status";
import { DecoderBuffer } from "../core/decoder_buffer";
import { CornerIndex, VertexIndex, INVALID_CORNER_INDEX } from "../geometry/geometry_indices";
import { CornerTable } from "../mesh/corner_table";
import { TopologySplitEventData } from "../mesh/mesh_edgebreaker_shared";
import { RAnsBitDecoder } from "../entropy/rans_bit_decoder";
import { SymbolEncodingOptions, decodeSymbols } from "../entropy/symbol_encoding";
import { EdgebreakerTraversalDecoder, SplitEventCursor, SplitHit } from "./edgebreaker_connectivity_decoder";

// Shared by the valence and predictive decoders: the next "direct" symbol of the legacy main traversal stream (1 bit for C,
// otherwise 3 bits), as the internal id (C=0, S=1, L=2, R=3, E=4), or -1 for
// None. `state[0]` is the bit index, advanced only on success.
export function decodeDirectSymbolFrom(bits: Array<bool>?, state: Int32Array): i32 {
    if (bits == null) return -1;
    const i = state[0];
    if (i < 0 || i >= bits.length) return -1;
    const first = bits[i];
    let topology: u32;
    if (!first) {
        state[0] = i + 1;
        topology = 0;
    } else {
        // Two suffix bits, LSB first: suffix = b1 | (b2 << 1); topology = 1 | (suffix << 1).
        if (i + 1 >= bits.length) return -1;
        const b1 = bits[i + 1];
        if (i + 2 >= bits.length) return -1;
        const b2 = bits[i + 2];
        state[0] = i + 3;
        topology = 1 | ((b1 ? <u32>1 : 0) << 1) | ((b2 ? <u32>1 : 0) << 2);
    }
    switch (topology) {
        case 0: return 0;
        case 1: return 1;
        case 3: return 2;
        case 5: return 3;
        case 7: return 4;
    }
    return -1;
}

// Adds `delta` to the valence of a corner's vertex, refusing an out-of-range
// vertex (shared with the predictive decoder).
export function checkedAddCornerVertexValence(
    valences: Array<i32>,
    cornerTable: CornerTable,
    corner: CornerIndex,
    delta: i32,
): bool {
    if (corner == INVALID_CORNER_INDEX || <i64>corner >= <i64>cornerTable.numCorners()) {
        return false;
    }
    const vertex = cornerTable.vertex(corner);
    if (<i64>vertex >= <i64>valences.length) return false;
    valences[<i32>vertex] += delta;
    return true;
}

// The valence of a corner's vertex, or `has = false` when out of range.
export function checkedCornerVertexValence(
    valences: Array<i32>,
    cornerTable: CornerTable,
    corner: CornerIndex,
    out: Int32Array,
): bool {
    if (corner == INVALID_CORNER_INDEX || <i64>corner >= <i64>cornerTable.numCorners()) {
        return false;
    }
    const vertex = cornerTable.vertex(corner);
    if (<i64>vertex >= <i64>valences.length) return false;
    out[0] = valences[<i32>vertex];
    return true;
}

// The valence bookkeeping of `new_active_corner_reached`, per last symbol
// (C=0, S=1, L=2, R=3, E=4). `&&` short-circuits.
export function updateValencesForSymbol(
    valences: Array<i32>,
    ct: CornerTable,
    lastSymbol: i32,
    corner: CornerIndex,
    next: CornerIndex,
    prev: CornerIndex,
): bool {
    switch (lastSymbol) {
        case 0:
        case 1:
            // Center (C) or Split (S)
            return checkedAddCornerVertexValence(valences, ct, next, 1) &&
                checkedAddCornerVertexValence(valences, ct, prev, 1);
        case 3:
            // Right (R)
            return checkedAddCornerVertexValence(valences, ct, corner, 1) &&
                checkedAddCornerVertexValence(valences, ct, next, 1) &&
                checkedAddCornerVertexValence(valences, ct, prev, 2);
        case 2:
            // Left (L)
            return checkedAddCornerVertexValence(valences, ct, corner, 1) &&
                checkedAddCornerVertexValence(valences, ct, next, 2) &&
                checkedAddCornerVertexValence(valences, ct, prev, 1);
        case 4:
            // End (E)
            return checkedAddCornerVertexValence(valences, ct, corner, 2) &&
                checkedAddCornerVertexValence(valences, ct, next, 2) &&
                checkedAddCornerVertexValence(valences, ct, prev, 2);
    }
    return true;
}

export class MeshEdgebreakerTraversalValenceDecoder extends EdgebreakerTraversalDecoder {
    numVertices: u64 = 0;
    vertexValences: Array<i32> = new Array<i32>();
    lastSymbol: i32 = -1;
    activeContext: i32 = -1;
    minValence: i32 = 2;
    maxValence: i32 = 7;
    contextSymbols: Array<Array<u32>> = new Array<Array<u32>>();
    contextCounters: Array<i32> = new Array<i32>();
    private splits: SplitEventCursor;
    startFaceDecoder: RAnsBitDecoder;
    hasStartFaceBits: bool;
    startFaceBitsLegacy: Array<bool>?;
    private startFaceBitsLegacyIndex: i32 = 0;
    processedConnectivityCorners: Array<u32> = new Array<u32>();
    // Pre-1.0 (bitstream < 2.2) only: raw bits of the main traversal symbol
    // stream, replayed when no valence context is active. null for modern
    // streams, where that case is always E.
    private directSymbolBits: Array<bool>?;
    private directSymbolBitIndex: Int32Array = new Int32Array(1);
    private valenceOut: Int32Array = new Int32Array(1);

    constructor(
        startFaceDecoder: RAnsBitDecoder,
        hasStartFaceBits: bool,
        topologySplitData: Array<TopologySplitEventData>,
        startFaceBitsLegacy: Array<bool>?,
        directSymbolBits: Array<bool>?,
    ) {
        super();
        this.splits = new SplitEventCursor(topologySplitData);
        this.startFaceDecoder = startFaceDecoder;
        this.hasStartFaceBits = hasStartFaceBits;
        this.startFaceBitsLegacy = startFaceBitsLegacy;
        this.directSymbolBits = directSymbolBits;
    }

    // Initializes the contexts by reading counts and symbol arrays from the buffer.
    initFromBuffer(
        inBuffer: DecoderBuffer,
        numVertices: u64,
        bitstreamVersion: u16,
        maxContextSymbols: u64,
    ): Status {
        this.numVertices = numVertices;

        // Before bitstream 2.2 the valence stream prefixes its own
        // split-symbol count and a valence-mode byte.
        if (bitstreamVersion < 0x0202) {
            let numSplitSymbols: u64;
            if (bitstreamVersion < 0x0200) {
                const r = inBuffer.decodeU32();
                if (!r.ok) {
                    return DracoError.buffer("Buffer ran out reading the legacy split-symbol count").fail<bool>();
                }
                numSplitSymbols = <u64>r.value;
            } else {
                const r = inBuffer.decodeVarint();
                if (!r.ok) {
                    return DracoError.buffer("Buffer ran out reading the legacy split-symbol count").fail<bool>();
                }
                numSplitSymbols = r.value;
            }
            if (numSplitSymbols >= this.numVertices) {
                return DracoError.general(
                    "Legacy valence stream claims " + numSplitSymbols.toString() + " split symbols against " +
                    this.numVertices.toString() + " vertices",
                ).fail<bool>();
            }
            // Valence mode byte; only EDGEBREAKER_VALENCE_MODE_2_7 (0) is supported.
            const rm = inBuffer.decodeU8();
            if (!rm.ok) {
                return DracoError.buffer("Buffer ran out reading the legacy valence mode byte").fail<bool>();
            }
            const mode = rm.value;
            if (mode != 0) {
                return DracoError.unsupportedFeature(
                    "Valence mode " + mode.toString() + ": only mode 0 (valences 2..7) is defined",
                ).fail<bool>();
            }
        }

        // Grown by on_vertex_created as vertices appear, never pre-sized from
        // the header's claim.
        this.vertexValences.length = 0;

        this.minValence = 2;
        this.maxValence = 7;
        const numUniqueValences = this.maxValence - this.minValence + 1;
        this.contextSymbols = new Array<Array<u32>>();
        this.contextCounters = new Array<i32>();
        for (let i = 0; i < numUniqueValences; i++) {
            this.contextSymbols.push(new Array<u32>());
            this.contextCounters.push(0);
        }

        // For each context, read count and symbols.
        let totalContextSymbols: u64 = 0;
        for (let i = 0; i < numUniqueValences; i++) {
            const r = inBuffer.decodeVarint();
            if (!r.ok) {
                return DracoError.buffer(
                    "Buffer ran out reading the symbol count for valence context " + i.toString(),
                ).fail<bool>();
            }
            const numSymbols = r.value;
            if (numSymbols > u64.MAX_VALUE - totalContextSymbols || totalContextSymbols + numSymbols > maxContextSymbols) {
                return DracoError.general(
                    "Valence contexts claim more than " + maxContextSymbols.toString() +
                    " symbols in total, which is more than the connectivity has",
                ).fail<bool>();
            }
            totalContextSymbols += numSymbols;
            if (numSymbols > 0) {
                const options = new SymbolEncodingOptions();
                const s = decodeSymbols(numSymbols, 1, options, inBuffer, this.contextSymbols[i]);
                if (!s.ok) {
                    const e = dracoErrorOfStatus(s);
                    return e.context("Valence context " + i.toString() + " of 6").fail<bool>();
                }
                // Set counter to read from back.
                this.contextCounters[i] = <i32>numSymbols;
            }
        }

        return okStatus();
    }

    decodeSymbol(): i64 {
        if (this.activeContext != -1) {
            const ctx = this.activeContext;
            if (ctx < 0 || ctx >= this.contextCounters.length) {
                return this.symbolFail(DracoError.general("Invalid Edgebreaker valence context"));
            }
            const counter = this.contextCounters[ctx] - 1;
            this.contextCounters[ctx] = counter;
            if (counter < 0) {
                return this.symbolFail(DracoError.general("Edgebreaker valence context symbol stream exhausted"));
            }
            if (ctx >= this.contextSymbols.length || counter >= this.contextSymbols[ctx].length) {
                return this.symbolFail(DracoError.general("Edgebreaker valence context symbol stream exhausted"));
            }
            const symbolId = this.contextSymbols[ctx][counter];
            // symbol_id is an EdgebreakerSymbol id (0..4).
            if (symbolId > 4) {
                return this.symbolFail(DracoError.general("Invalid Edgebreaker valence symbol " + symbolId.toString()));
            }
            this.lastSymbol = <i32>symbolId;
        } else {
            // No active valence context (component start / misprediction):
            // for bitstream < 2.2 the symbol comes from the main traversal
            // stream; modern streams always have E here.
            const d = decodeDirectSymbolFrom(this.directSymbolBits, this.directSymbolBitIndex);
            this.lastSymbol = d >= 0 ? d : 4;
        }
        return <i64><u32>this.lastSymbol;
    }

    decodeStartFaceConfiguration(): bool {
        const bits = this.startFaceBitsLegacy;
        if (bits != null) {
            const idx = this.startFaceBitsLegacyIndex;
            this.startFaceBitsLegacyIndex += 1;
            return idx < bits.length ? bits[idx] : true;
        }
        if (this.hasStartFaceBits) {
            return this.startFaceDecoder.decodeNextBit();
        }
        return true;
    }

    mergeVertices(dest: VertexIndex, source: VertexIndex): void {
        const v = this.vertexValences;
        if (<i64>dest < <i64>v.length && <i64>source < <i64>v.length) {
            v[<i32>dest] += v[<i32>source];
        }
    }

    isTopologySplit(encoderSymbolId: i32): SplitHit? {
        return this.splits.isTopologySplit(encoderSymbolId);
    }

    onVertexCreated(vertex: VertexIndex, _symbolId: i32, _cornerIndex: i32): void {
        // A new vertex starts at valence 0; the updates happen in
        // new_active_corner_reached.
        const v = this.vertexValences;
        if (<i64>vertex >= <i64>v.length) {
            while (<i64>v.length < <i64>vertex + 1) v.push(0);
            this.numVertices = <u64>v.length;
        }
    }

    onVerticesSwapped(_v1: VertexIndex, _v2: VertexIndex): void {}

    onStartFaceDecoded(_corner: CornerIndex): void {}

    onSplitSymbolDecoded(_corner: CornerIndex): void {}

    newActiveCornerReached(corner: CornerIndex, cornerTable: CornerTable): void {
        if (corner == INVALID_CORNER_INDEX || <i64>corner >= <i64>cornerTable.numCorners()) {
            this.activeContext = -1;
            return;
        }

        // Update valences based on last_symbol (C=0, S=1, L=2, R=3, E=4).
        const next = cornerTable.next(corner);
        const prev = cornerTable.previous(corner);
        const updated = updateValencesForSymbol(this.vertexValences, cornerTable, this.lastSymbol, corner, next, prev);
        if (!updated) {
            this.activeContext = -1;
            return;
        }

        if (!checkedCornerVertexValence(this.vertexValences, cornerTable, next, this.valenceOut)) {
            this.activeContext = -1;
            return;
        }
        const activeValence = this.valenceOut[0];
        let clamped: i32;
        if (activeValence < this.minValence) {
            clamped = this.minValence;
        } else if (activeValence > this.maxValence) {
            clamped = this.maxValence;
        } else {
            clamped = activeValence;
        }
        this.activeContext = clamped - this.minValence;

        // Record the processed connectivity corner.
        this.processedConnectivityCorners.push(corner);
    }
}

function dracoErrorOfStatus(s: Status): DracoError {
    const c = s.cause;
    if (c != null) {
        const isDraco = c instanceof DracoError;
        if (isDraco) return c as DracoError;
    }
    return DracoError.general(s.err);
}
