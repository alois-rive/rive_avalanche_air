// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The predictive EdgeBreaker traversal decoder (legacy "type 1" traversal, the
// default in Draco 0.9.1 and earlier). It keeps per-vertex valences of the
// decoded part of the mesh and predicts the next symbol from them: after a C
// or R symbol it predicts R when the pivot vertex valence is < 6, otherwise C.
// A binary prediction stream says whether each prediction was correct;
// mispredicted (and unpredicted) symbols come from the main traversal symbol
// stream. Follows Draco's `mesh_edgebreaker_traversal_predictive_decoder.h`.

import { DracoError } from "../core/status";
import { CornerIndex, VertexIndex, INVALID_CORNER_INDEX } from "../geometry/geometry_indices";
import { CornerTable } from "../mesh/corner_table";
import { TopologySplitEventData } from "../mesh/mesh_edgebreaker_shared";
import { RAnsBitDecoder } from "../entropy/rans_bit_decoder";
import { EdgebreakerTraversalDecoder, SplitEventCursor, SplitHit } from "./edgebreaker_connectivity_decoder";
import {
    checkedCornerVertexValence,
    decodeDirectSymbolFrom,
    updateValencesForSymbol,
} from "./mesh_edgebreaker_traversal_valence_decoder";

// Internal EdgeBreaker symbol ids (C=0, S=1, L=2, R=3, E=4).
const SYMBOL_C: i32 = 0;
const SYMBOL_R: i32 = 3;

export class MeshEdgebreakerTraversalPredictiveDecoder extends EdgebreakerTraversalDecoder {
    numVertices: u64;
    vertexValences: Array<i32> = new Array<i32>();
    lastSymbol: i32 = -1;
    predictedSymbol: i32 = -1;
    private predictionDecoder: RAnsBitDecoder;
    private splits: SplitEventCursor;
    startFaceDecoder: RAnsBitDecoder;
    hasStartFaceBits: bool;
    startFaceBitsLegacy: Array<bool>?;
    private startFaceBitsLegacyIndex: i32 = 0;
    processedConnectivityCorners: Array<u32> = new Array<u32>();
    // Raw bits of the main traversal symbol stream, decoded on demand for
    // unpredicted / mispredicted symbols (1 bit for C, otherwise 3 bits).
    private directSymbolBits: Array<bool>?;
    private directSymbolBitIndex: Int32Array = new Int32Array(1);
    private valenceOut: Int32Array = new Int32Array(1);

    constructor(
        startFaceDecoder: RAnsBitDecoder,
        hasStartFaceBits: bool,
        topologySplitData: Array<TopologySplitEventData>,
        startFaceBitsLegacy: Array<bool>?,
        directSymbolBits: Array<bool>?,
        predictionDecoder: RAnsBitDecoder,
        numVertices: u64,
    ) {
        super();
        this.numVertices = numVertices;
        // Empty for the same reason as the valence traversal: `numVertices` is
        // the header's own claim; on_vertex_created grows the table.
        this.predictionDecoder = predictionDecoder;
        this.splits = new SplitEventCursor(topologySplitData);
        this.startFaceDecoder = startFaceDecoder;
        this.hasStartFaceBits = hasStartFaceBits;
        this.startFaceBitsLegacy = startFaceBitsLegacy;
        this.directSymbolBits = directSymbolBits;
    }

    decodeSymbol(): i64 {
        // Use the prediction if there is one and the prediction bit confirms it.
        if (this.predictedSymbol != -1 && this.predictionDecoder.decodeNextBit()) {
            this.lastSymbol = this.predictedSymbol;
            return <i64><u32>this.lastSymbol;
        }
        // No prediction, or the symbol was mispredicted: decode it directly.
        const d = decodeDirectSymbolFrom(this.directSymbolBits, this.directSymbolBitIndex);
        if (d < 0) {
            return this.symbolFail(DracoError.general("Edgebreaker predictive symbol stream exhausted"));
        }
        this.lastSymbol = d;
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
            this.predictedSymbol = -1;
            return;
        }

        // Update valences based on last_symbol (C=0, S=1, L=2, R=3, E=4).
        const next = cornerTable.next(corner);
        const prev = cornerTable.previous(corner);
        const updated = updateValencesForSymbol(this.vertexValences, cornerTable, this.lastSymbol, corner, next, prev);
        if (!updated) {
            this.predictedSymbol = -1;
            return;
        }

        // Predict the next symbol from the pivot vertex valence. Only C and R
        // symbols seed a prediction.
        if (this.lastSymbol == SYMBOL_C || this.lastSymbol == SYMBOL_R) {
            if (checkedCornerVertexValence(this.vertexValences, cornerTable, next, this.valenceOut)) {
                this.predictedSymbol = this.valenceOut[0] < 6 ? SYMBOL_R : SYMBOL_C;
            } else {
                this.predictedSymbol = -1;
            }
        } else {
            this.predictedSymbol = -1;
        }

        this.processedConnectivityCorners.push(corner);
    }
}
