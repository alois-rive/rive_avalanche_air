// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The EdgeBreaker traversal symbols and constants shared by the EdgeBreaker
// encoder and decoder.

import { debugStruct } from "../../../../base/fmt";

// The traversal symbols, numbered as the valence coder counts them.
//
// These are indices, not the bit patterns that reach the stream: upstream
// writes C, S, L, R and E as `0`, `1`, `3`, `5` and `7`, and the encoder maps
// to those where it emits them. `Hole` is the classic Edgebreaker H symbol,
// which Draco's bitstream has no encoding for.
export enum EdgebreakerSymbol {
    Center = 0,
    Split = 1,
    Left = 2,
    Right = 3,
    End = 4,
    Hole = 5,
}

// The symbol for a raw value: anything unknown is Center.
export function edgebreakerSymbolFromU32(v: u32): EdgebreakerSymbol {
    switch (v) {
        case 0: return EdgebreakerSymbol.Center;
        case 1: return EdgebreakerSymbol.Split;
        case 2: return EdgebreakerSymbol.Left;
        case 3: return EdgebreakerSymbol.Right;
        case 4: return EdgebreakerSymbol.End;
        case 5: return EdgebreakerSymbol.Hole;
    }
    // Only symbols this encoder produced reach here, so the arm is
    // unreachable rather than lenient.
    return EdgebreakerSymbol.Center;
}

// `{:?}` of an EdgebreakerSymbol.
export function edgebreakerSymbolDebug(s: EdgebreakerSymbol): string {
    switch (s) {
        case EdgebreakerSymbol.Center: return "Center";
        case EdgebreakerSymbol.Split: return "Split";
        case EdgebreakerSymbol.Left: return "Left";
        case EdgebreakerSymbol.Right: return "Right";
        case EdgebreakerSymbol.End: return "End";
        case EdgebreakerSymbol.Hole: return "Hole";
    }
    return "";
}

export enum EdgeFaceName {
    LeftFaceEdge = 0,
    RightFaceEdge = 1,
}

// `{:?}` of an EdgeFaceName.
export function edgeFaceNameDebug(e: EdgeFaceName): string {
    switch (e) {
        case EdgeFaceName.LeftFaceEdge: return "LeftFaceEdge";
        case EdgeFaceName.RightFaceEdge: return "RightFaceEdge";
    }
    return "";
}

export class TopologySplitEventData {
    splitSymbolId: u32 = 0;
    sourceSymbolId: u32 = 0;
    sourceEdge: EdgeFaceName = EdgeFaceName.LeftFaceEdge;

    constructor(splitSymbolId: u32 = 0, sourceSymbolId: u32 = 0, sourceEdge: EdgeFaceName = EdgeFaceName.LeftFaceEdge) {
        this.splitSymbolId = splitSymbolId;
        this.sourceSymbolId = sourceSymbolId;
        this.sourceEdge = sourceEdge;
    }

    clone(): TopologySplitEventData {
        return new TopologySplitEventData(this.splitSymbolId, this.sourceSymbolId, this.sourceEdge);
    }

    // Debug text of every field.
    debug(): string {
        return debugStruct(
            "TopologySplitEventData",
            ["split_symbol_id", "source_symbol_id", "source_edge"],
            [this.splitSymbolId.toString(), this.sourceSymbolId.toString(), edgeFaceNameDebug(this.sourceEdge)],
        );
    }
}
