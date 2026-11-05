// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The EdgeBreaker connectivity decoder. MeshEdgebreakerDecoder reconstructs
// mesh topology from the EdgeBreaker symbol stream (C, L, R, S, E), rebuilding
// the corner table and the maps the attribute decoders need. Per-symbol
// traversal is delegated to the standard (InternalTraversalDecoder), valence
// or predictive traversal decoder. Follows Draco's
// `mesh_edgebreaker_decoder.h`.
//
// Legacy (pre-2.2) layouts and the valence and predictive traversals are all
// decoded.

import { Result } from "../../../../base/util";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DracoError, Status, okStatus, errorStatus } from "../core/status";
import { bitstreamVersion as packVersion } from "../core/version";
import { Mesh } from "../geometry/mesh";
import { CornerIndex, VertexIndex, INVALID_CORNER_INDEX } from "../geometry/geometry_indices";
import { CornerTable } from "../mesh/corner_table";
import { EdgeFaceName, EdgebreakerSymbol, TopologySplitEventData } from "../mesh/mesh_edgebreaker_shared";
import { RAnsBitDecoder } from "../entropy/rans_bit_decoder";
import {
    EdgebreakerConnectivityDecoder,
    EdgebreakerTraversalDecoder,
    SplitEventCursor,
    SplitHit,
} from "./edgebreaker_connectivity_decoder";
import { MeshEdgebreakerTraversalValenceDecoder } from "./mesh_edgebreaker_traversal_valence_decoder";
import { MeshEdgebreakerTraversalPredictiveDecoder } from "./mesh_edgebreaker_traversal_predictive_decoder";

// The result of `decodeHoleAndTopologySplitEvents`: the events and the position the
// event buffer reached.
export class SplitEventsDecoded {
    events: Array<TopologySplitEventData>;
    decodedBytes: u64;

    constructor(events: Array<TopologySplitEventData>, decodedBytes: u64) {
        this.events = events;
        this.decodedBytes = decodedBytes;
    }
}

function satMulU64(a: u64, b: u64): u64 {
    if (a != 0 && b > u64.MAX_VALUE / a) return u64.MAX_VALUE;
    return a * b;
}

function minU64(a: u64, b: u64): u64 {
    return a < b ? a : b;
}

function general<T>(msg: string): Result<T> {
    return DracoError.general(msg).fail<T>();
}

// The bits of a size-prefixed sequence the caller has just opened with
// `inBuffer.startBitDecoding(true)` (which answered `sizeBytes`), read LSB
// first without allocating a Result per read: `DecoderBuffer.
// decodeLeastSignificantBits32` does, and these loops read up to three bits
// per face under a runtime that never frees. The sequence is the buffer's
// bytes from its position (the sequence start) up to `sizeBytes`, capped at
// the buffer's end -- DecoderBuffer's `bitStreamEndPos` -- and a read of n
// bits (n <= 32) at bit offset b succeeds there exactly when
// b + n <= 8 * that length. The caller still ends with `endBitDecoding()`,
// which moves a size-known sequence to its declared end whatever was read.
class SizedBitReader {
    private data: Uint8Array;
    private limitBits: u64;
    private offset: u64 = 0;

    constructor(inBuffer: DecoderBuffer, sizeBytes: u64) {
        this.data = inBuffer.remainingData();
        const n = <u64>this.data.length;
        this.limitBits = (sizeBytes < n ? sizeBytes : n) * 8;
    }

    // The next `nbits` (1..=2 here) as an unsigned value, or -1 where
    // decodeLeastSignificantBits32 would fail (nothing is consumed then).
    read(nbits: u32): i32 {
        const start = this.offset;
        if (start + <u64>nbits > this.limitBits) return -1;
        let v: i32 = 0;
        for (let k: u32 = 0; k < nbits; k++) {
            const b = start + <u64>k;
            const byte = <i32>unchecked(this.data[<i32>(b >> 3)]);
            v |= ((byte >> <i32>(b & 7)) & 1) << <i32>k;
        }
        this.offset = start + <u64>nbits;
        return v;
    }
}

// `topology_bit_pattern_to_symbol_id` without the Result: the internal
// symbol id, or -1 for a pattern it refuses.
function patternToSymbolId(topology: u32): i32 {
    switch (topology) {
        case 0: return <i32>EdgebreakerSymbol.Center;
        case 1: return <i32>EdgebreakerSymbol.Split;
        case 3: return <i32>EdgebreakerSymbol.Left;
        case 5: return <i32>EdgebreakerSymbol.Right;
        case 7: return <i32>EdgebreakerSymbol.End;
    }
    return -1;
}

// Reads a count that is a u32 below bitstream 2.0 and a varint from 2.0 on,
// mapping a failed read to DracoError.general(msg).
function decodeCount(inBuffer: DecoderBuffer, legacyU32: bool, msg: string): Result<u64> {
    if (legacyU32) {
        const r = inBuffer.decodeU32();
        if (!r.ok) return general<u64>(msg);
        return Result.okv<u64>(<u64>r.value);
    }
    const r = inBuffer.decodeVarint();
    if (!r.ok) return general<u64>(msg);
    return Result.okv<u64>(r.value);
}

export class MeshEdgebreakerDecoder {
    private dataToCornerMap: Array<u32>? = null;
    private attributeSeamCorners: Array<Array<u32>> = new Array<Array<u32>>();
    // Traversal order for attribute decoding (C++ processed_connectivity_corners_).
    private processedConnectivityCorners: Array<u32> = new Array<u32>();
    // Corner table built during connectivity decoding, with its opposite mappings.
    private cornerTable: CornerTable? = null;
    private traversalDecoderType: u8 = 0;
    private vertexToCornerMap: Array<u32> = new Array<u32>();
    private isVertHole: Array<bool> = new Array<bool>();

    constructor() {}

    getCornerTable(): CornerTable? {
        return this.cornerTable;
    }

    // Hands the corner table over, leaving null behind.
    takeCornerTable(): CornerTable? {
        const ct = this.cornerTable;
        this.cornerTable = null;
        return ct;
    }

    takeDataToCornerMap(): Array<u32>? {
        const m = this.dataToCornerMap;
        this.dataToCornerMap = null;
        return m;
    }

    // Hands the seam corners over, leaving an empty list behind.
    takeAttributeSeamCorners(): Array<Array<u32>> {
        const s = this.attributeSeamCorners;
        this.attributeSeamCorners = new Array<Array<u32>>();
        return s;
    }

    getAttributeSeamCorners(attributeIndex: i32): Array<u32>? {
        if (attributeIndex < 0 || attributeIndex >= this.attributeSeamCorners.length) return null;
        return this.attributeSeamCorners[attributeIndex];
    }

    takeProcessedConnectivityCorners(): Array<u32> {
        const c = this.processedConnectivityCorners;
        this.processedConnectivityCorners = new Array<u32>();
        return c;
    }

    takeVertexToCornerMap(): Array<u32> {
        const m = this.vertexToCornerMap;
        this.vertexToCornerMap = new Array<u32>();
        return m;
    }

    takeIsVertHole(): Array<bool> {
        const h = this.isVertHole;
        this.isVertHole = new Array<bool>();
        return h;
    }

    getTraversalDecoderType(): u8 {
        return this.traversalDecoderType;
    }

    decodeConnectivity(inBuffer: DecoderBuffer, outMesh: Mesh): Status {
        this.dataToCornerMap = null;

        const versionMajor = inBuffer.versionMajor();
        const versionMinor = inBuffer.versionMinor();
        const bitstreamVersion = packVersion(versionMajor, versionMinor);
        // (Pre-2.2 streams are decoded.)

        // The traversal decoder type is always present.
        const rt = inBuffer.decodeU8();
        if (!rt.ok) return general<bool>("Failed to read traversal decoder type");
        this.traversalDecoderType = rt.value;
        // Type 0 = Standard, Type 1 = Predictive (deprecated), Type 2 = Valence.
        if (this.traversalDecoderType > 2) {
            return general<bool>("Unsupported Edgebreaker traversal decoder type: " + this.traversalDecoderType.toString());
        }

        if (bitstreamVersion < 0x0202) {
            // num_new_vertices: read and unused.
            const r = decodeCount(inBuffer, bitstreamVersion < 0x0200, "Failed to read num_new_vertices");
            if (!r.ok) return r.forward<bool>();
        }

        const rv = decodeCount(inBuffer, bitstreamVersion < 0x0200, "Failed to read num_encoded_vertices");
        if (!rv.ok) return rv.forward<bool>();
        const numEncodedVertices = <u32>rv.value;

        const rfc = decodeCount(inBuffer, bitstreamVersion < 0x0200, "Failed to read num_faces");
        if (!rfc.ok) return rfc.forward<bool>();
        const numFaces = <u32>rfc.value;

        const ra = inBuffer.decodeU8();
        if (!ra.ok) return general<bool>("Failed to read attribute data count");
        const numAttributeData = ra.value;

        // Reject impossible geometry counts before allocating face and
        // connectivity storage (the C++ MeshEdgebreakerDecoderImpl checks).
        if (numFaces > u32.MAX_VALUE / 3) {
            return general<bool>("Edgebreaker num_faces exceeds maximum");
        }
        if (<u64>numEncodedVertices > <u64>numFaces * 3) {
            return general<bool>("Edgebreaker num_encoded_vertices exceeds 3 * num_faces");
        }
        // A manifold mesh with F faces needs at least 3F/2 edges, while V
        // vertices can form at most V(V-1)/2 edges.
        const minNumFaceEdges: u64 = (<u64>3 * <u64>numFaces) / 2;
        const nv64 = <u64>numEncodedVertices;
        const maxNumVertexEdges: u64 = (nv64 * (nv64 > 0 ? nv64 - 1 : 0)) / 2;
        if (maxNumVertexEdges < minNumFaceEdges) {
            return general<bool>("Edgebreaker vertex/face counts cannot form a manifold mesh");
        }

        const rs = decodeCount(inBuffer, bitstreamVersion < 0x0200, "Failed to read symbol count");
        if (!rs.ok) return rs.forward<bool>();
        const numSymbols = rs.value;

        const rss = decodeCount(inBuffer, bitstreamVersion < 0x0200, "Failed to read split symbol count");
        if (!rss.ok) return rss.forward<bool>();
        const numSplitSymbols = rss.value;

        // Symbol-count invariants (mirrors C++): num_faces lies between
        // num_symbols and num_symbols * 4/3, and split symbols are a subset.
        if (<u64>numFaces < numSymbols) {
            return general<bool>("Edgebreaker num_faces is smaller than num_symbols");
        }
        const maxEncodedFaces = numSymbols + numSymbols / 3;
        if (<u64>numFaces > maxEncodedFaces) {
            return general<bool>("Edgebreaker num_faces exceeds maximum implied by num_symbols");
        }
        if (numSplitSymbols > numSymbols) {
            return general<bool>("Edgebreaker num_split_symbols exceeds num_symbols");
        }

        // Last, once the counts are coherent: only a file that got this far
        // can be refused for being large rather than wrong.
        const rcf = inBuffer.checkFaces(<u64>numFaces);
        if (!rcf.ok) return rcf;

        // Not sized from num_faces: the faces are written from the corner
        // table the traversal actually built. (A point count past i32 is
        // clamped; it is always replaced below on success.)
        outMesh.setNumPoints(numEncodedVertices > <u32>i32.MAX_VALUE ? i32.MAX_VALUE : <i32>numEncodedVertices);

        // Hole/topology split events: inline for v2.2+, after the traversal
        // buffer (whose size is encoded) for older streams.
        let topologySplitData: Array<TopologySplitEventData>;
        let topologySplitDecodedBytes: u64 = 0;
        if (bitstreamVersion < 0x0202) {
            const rc = decodeCount(inBuffer, bitstreamVersion < 0x0200, "Failed to read encoded_connectivity_size");
            if (!rc.ok) return rc.forward<bool>();
            const encodedConnectivitySize = rc.value;

            if (encodedConnectivitySize == 0 || encodedConnectivitySize > <u64>inBuffer.remainingSize()) {
                return general<bool>("Invalid encoded_connectivity_size");
            }

            // Decode the events from a temporary buffer starting at the end
            // of the traversal buffer, keeping inBuffer at its start.
            const remaining = inBuffer.remainingData();
            const eventsSlice = remaining.subarray(<i32>encodedConnectivitySize);
            const eventBuffer = new DecoderBuffer(eventsSlice);
            eventBuffer.setVersion(versionMajor, versionMinor);

            const re = MeshEdgebreakerDecoder.decodeHoleAndTopologySplitEvents(eventBuffer, bitstreamVersion, <u64>numFaces);
            if (!re.ok) return re.forward<bool>();
            topologySplitData = re.value.events;
            topologySplitDecodedBytes = re.value.decodedBytes;
        } else {
            const re = MeshEdgebreakerDecoder.decodeTopologySplitEventsInline(inBuffer, bitstreamVersion, <u64>numFaces);
            if (!re.ok) return re.forward<bool>();
            topologySplitData = re.value;
        }

        // Validate the split data count.
        if (<u64>topologySplitData.length > numSplitSymbols) {
            return errorStatus(
                "Split event count exceeds split-symbol count (split_symbols=" + numSplitSymbols.toString() +
                ", events=" + topologySplitData.length.toString() + ")",
            ).fail<bool>();
        }

        // The symbol stream. The valence (2) and predictive (1) traversals
        // read the main symbol stream on demand, so skip the eager decode.
        let symbols: Array<u32>;
        if (this.traversalDecoderType == 1 || this.traversalDecoderType == 2) {
            symbols = new Array<u32>();
        } else {
            const rsym = MeshEdgebreakerDecoder.decodeSymbolStream(inBuffer, numSymbols);
            if (!rsym.ok) return rsym.forward<bool>();
            symbols = rsym.value;
        }

        // Up to num_encoded_vertices + num_split_symbols vertices exist during
        // connectivity decoding (split symbols introduce temporary vertices).
        const nevU64 = <u64>numEncodedVertices;
        const maxNumVertices: u64 = numSplitSymbols > u64.MAX_VALUE - nevU64 ? u64.MAX_VALUE : nevU64 + numSplitSymbols;

        const rr = this.reconstructMesh(
            symbols,
            topologySplitData,
            outMesh,
            <u64>numFaces,
            maxNumVertices,
            numAttributeData,
            numSymbols,
            inBuffer,
        );
        if (!rr.ok) return rr.forward<bool>();

        // Pre-2.2: the event payload was decoded from a temporary buffer and
        // the main buffer now sits at its start; skip past it.
        if (topologySplitDecodedBytes > 0) {
            if (topologySplitDecodedBytes > <u64>inBuffer.remainingSize()) {
                return general<bool>("Invalid topology split decoded byte count");
            }
            const ra2 = inBuffer.tryAdvance(topologySplitDecodedBytes);
            if (!ra2.ok) return ra2;
        }

        return okStatus();
    }

    // Decodes the hole and topology-split events (public for tests).
    static decodeHoleAndTopologySplitEvents(
        inBuffer: DecoderBuffer,
        bitstreamVersion: u16,
        numFaces: u64,
    ): Result<SplitEventsDecoded> {
        // Matches MeshEdgebreakerDecoderImpl::DecodeHoleAndTopologySplitEvents.
        const rn = decodeCount(inBuffer, bitstreamVersion < 0x0200, "Failed to read num_topology_splits");
        if (!rn.ok) return rn.forward<SplitEventsDecoded>();
        const numTopologySplits = <u32>rn.value;

        if (<u64>numTopologySplits > numFaces) {
            return general<SplitEventsDecoded>("Topology split count exceeds face count");
        }

        // Every event consumes at least one payload byte.
        if (<u64>numTopologySplits > <u64>inBuffer.remainingSize()) {
            return general<SplitEventsDecoded>(
                "Topology split count " + numTopologySplits.toString() + " exceeds the " +
                inBuffer.remainingSize().toString() + " bytes left to hold it",
            );
        }

        const events = new Array<TopologySplitEventData>();
        if (numTopologySplits > 0) {
            if (bitstreamVersion < 0x0102) {
                // Legacy (<1.2): absolute ids + explicit edge byte.
                for (let k: u32 = 0; k < numTopologySplits; k++) {
                    const r1 = inBuffer.decodeU32();
                    if (!r1.ok) return general<SplitEventsDecoded>("Failed to read split_symbol_id");
                    const r2 = inBuffer.decodeU32();
                    if (!r2.ok) return general<SplitEventsDecoded>("Failed to read source_symbol_id");
                    const r3 = inBuffer.decodeU8();
                    if (!r3.ok) return general<SplitEventsDecoded>("Failed to read source_edge byte");
                    events.push(new TopologySplitEventData(
                        r1.value,
                        r2.value,
                        (r3.value & 1) == 0 ? EdgeFaceName.LeftFaceEdge : EdgeFaceName.RightFaceEdge,
                    ));
                }
            } else {
                // Delta + varint ids.
                let lastSourceSymbolId: i32 = 0;
                for (let k: u32 = 0; k < numTopologySplits; k++) {
                    const rd = inBuffer.decodeVarint();
                    if (!rd.ok) return general<SplitEventsDecoded>("Failed to read source symbol delta");
                    const delta = <i32>rd.value;
                    // Wrapping, as C++ int arithmetic.
                    const sourceSymbolId = lastSourceSymbolId + delta;

                    const rsd = inBuffer.decodeVarint();
                    if (!rsd.ok) return general<SplitEventsDecoded>("Failed to read split symbol delta");
                    const splitDelta = <i32>rsd.value;
                    if (splitDelta > sourceSymbolId) {
                        return general<SplitEventsDecoded>("Invalid split symbol delta");
                    }
                    const splitSymbolId = sourceSymbolId - splitDelta;

                    events.push(new TopologySplitEventData(<u32>splitSymbolId, <u32>sourceSymbolId, EdgeFaceName.LeftFaceEdge));

                    lastSourceSymbolId = sourceSymbolId;
                }

                // Split edges are bit-coded; below 2.2 the decoder reads 2 bits.
                if (events.length > 0) {
                    const rb = inBuffer.startBitDecoding(false);
                    if (!rb.ok) {
                        return general<SplitEventsDecoded>("Failed to start bit decoding for split-event source_edge bits");
                    }
                    const bits: u32 = bitstreamVersion < 0x0202 ? 2 : 1;
                    for (let i = 0; i < events.length; i++) {
                        const re = inBuffer.decodeLeastSignificantBits32(bits);
                        if (!re.ok) return general<SplitEventsDecoded>("Failed to read split-event source_edge bits");
                        events[i].sourceEdge = (re.value & 1) == 0 ? EdgeFaceName.LeftFaceEdge : EdgeFaceName.RightFaceEdge;
                    }
                    inBuffer.endBitDecoding();
                }
            }
        }

        const rh = MeshEdgebreakerDecoder.skipHoleEvents(inBuffer, bitstreamVersion);
        if (!rh.ok) return rh.forward<SplitEventsDecoded>();
        return Result.okv<SplitEventsDecoded>(new SplitEventsDecoded(events, <u64>inBuffer.position()));
    }

    // Hole events exist only below 2.1; C++ parses and never uses them, so
    // only the buffer position matters.
    private static skipHoleEvents(inBuffer: DecoderBuffer, bitstreamVersion: u16): Status {
        let numHoleEvents: u32 = 0;
        if (bitstreamVersion < 0x0200) {
            const r = inBuffer.decodeU32();
            if (!r.ok) return general<bool>("Failed to read num_hole_events");
            numHoleEvents = r.value;
        } else if (bitstreamVersion < 0x0201) {
            const r = inBuffer.decodeVarint();
            if (!r.ok) return general<bool>("Failed to read num_hole_events");
            numHoleEvents = <u32>r.value;
        }

        if (numHoleEvents > 0) {
            if (bitstreamVersion < 0x0102) {
                for (let k: u32 = 0; k < numHoleEvents; k++) {
                    // Legacy: raw i32 symbol id.
                    const r = inBuffer.decode<i32>();
                    if (!r.ok) return general<bool>("Failed to read hole event");
                }
            } else {
                // Delta + varint; nothing reads the ids.
                for (let k: u32 = 0; k < numHoleEvents; k++) {
                    const r = inBuffer.decodeVarint();
                    if (!r.ok) return general<bool>("Failed to read hole event delta");
                }
            }
        }

        return okStatus();
    }

    // Decodes inline topology-split events (public for tests).
    static decodeTopologySplitEventsInline(
        inBuffer: DecoderBuffer,
        bitstreamVersion: u16,
        numFaces: u64,
    ): Result<Array<TopologySplitEventData>> {
        // The inline event format is only used in v2.2+ streams.
        if (bitstreamVersion < 0x0202) {
            return Result.okv<Array<TopologySplitEventData>>(new Array<TopologySplitEventData>());
        }

        const rn = inBuffer.decodeVarint();
        if (!rn.ok) return general<Array<TopologySplitEventData>>("Failed to read split event count");
        const numEvents = rn.value;
        if (numEvents > numFaces) {
            return general<Array<TopologySplitEventData>>("Topology split count exceeds face count");
        }
        const events = new Array<TopologySplitEventData>();

        if (numEvents > 0) {
            let lastSourceSymbolId: i32 = 0;
            for (let k: u64 = 0; k < numEvents; k++) {
                const rd = inBuffer.decodeVarint();
                if (!rd.ok) return general<Array<TopologySplitEventData>>("Failed to read source symbol delta");
                const delta = <i32>rd.value;
                // Wrapping, as C++ int arithmetic.
                const sourceSymbolId = lastSourceSymbolId + delta;

                const rsd = inBuffer.decodeVarint();
                if (!rsd.ok) return general<Array<TopologySplitEventData>>("Failed to read split symbol delta");
                const splitDelta = <i32>rsd.value;
                const splitSymbolId = sourceSymbolId - splitDelta;

                events.push(new TopologySplitEventData(<u32>splitSymbolId, <u32>sourceSymbolId, EdgeFaceName.LeftFaceEdge));

                lastSourceSymbolId = sourceSymbolId;
            }
        }

        if (numEvents > 0) {
            const rb = inBuffer.startBitDecoding(false);
            if (!rb.ok) {
                return general<Array<TopologySplitEventData>>("Failed to start bit decoding for split-event source_edge bits");
            }
            for (let i = 0; i < events.length; i++) {
                const re = inBuffer.decodeLeastSignificantBits32(1);
                if (!re.ok) return general<Array<TopologySplitEventData>>("Failed to read split-event source_edge bit");
                events[i].sourceEdge = re.value == 0 ? EdgeFaceName.LeftFaceEdge : EdgeFaceName.RightFaceEdge;
            }
            inBuffer.endBitDecoding();
        }

        return Result.okv<Array<TopologySplitEventData>>(events);
    }

    // Draco topology bit patterns C=0, S=1, L=3, R=5, E=7 to the internal
    // symbol ids C=0, S=1, L=2, R=3, E=4.
    static topologyBitPatternToSymbolId(topology: u32): Result<u32> {
        switch (topology) {
            case 0: return Result.okv<u32>(<u32>EdgebreakerSymbol.Center);
            case 1: return Result.okv<u32>(<u32>EdgebreakerSymbol.Split);
            case 3: return Result.okv<u32>(<u32>EdgebreakerSymbol.Left);
            case 5: return Result.okv<u32>(<u32>EdgebreakerSymbol.Right);
            case 7: return Result.okv<u32>(<u32>EdgebreakerSymbol.End);
        }
        return general<u32>("Invalid Edgebreaker topology bit pattern: " + topology.toString());
    }

    private reconstructMesh(
        symbols: Array<u32>,
        topologySplitData: Array<TopologySplitEventData>,
        mesh: Mesh,
        totalNumFaces: u64,
        maxNumVertices: u64,
        numAttributeData: u8,
        numSymbols: u64,
        inBuffer: DecoderBuffer,
    ): Result<u64> {
        // The standard traversal pre-decodes its symbols; valence/predictive
        // read them on demand, so they use the header count.
        const actualNumSymbols: u64 = this.traversalDecoderType == 1 || this.traversalDecoderType == 2
            ? numSymbols
            : <u64>symbols.length;

        // Corner storage reserved for the header's face count, capped by what
        // the remaining bytes could describe at sixteen faces per byte.
        const inputFaceBound = minU64(totalNumFaces, satMulU64(<u64>inBuffer.remainingSize(), 16));

        if (actualNumSymbols == 0) {
            this.cornerTable = new CornerTable(0);
            this.dataToCornerMap = new Array<u32>();
            return Result.okv<u64>(0);
        }

        const bitstreamVersion = inBuffer.bitstreamVersion();

        // v < 2.2: start face configuration bits are a raw bit buffer (u64
        // size prefix + raw bits); v >= 2.2: an RAnsBitDecoder.
        const startFaceDecoder = new RAnsBitDecoder();
        let hasStartFaceBits = false;
        let startFaceBitsLegacy: Array<bool>? = null;
        // Pre-2.2 valence/predictive streams carry the main traversal symbol
        // stream as region 1, replayed when no context is active.
        let legacyDirectSymbolBits: Array<bool>? = null;

        if (bitstreamVersion < 0x0202) {
            if (this.traversalDecoderType == 1 || this.traversalDecoderType == 2) {
                const rb = inBuffer.startBitDecoding(true);
                if (!rb.ok) return general<u64>("Failed to start valence main-symbol bit decoding");
                // Each direct symbol is 1 or 3 bits, at most num_symbols of them.
                const cap = minU64(satMulU64(actualNumSymbols, 3), satMulU64(<u64>inBuffer.remainingSize(), 8));
                const reader = new SizedBitReader(inBuffer, rb.value);
                const bits = new Array<bool>();
                for (let k: u64 = 0; k < cap; k++) {
                    const v = reader.read(1);
                    if (v < 0) break;
                    bits.push(v != 0);
                }
                inBuffer.endBitDecoding();
                legacyDirectSymbolBits = bits;
            }

            // The raw start-face bit buffer.
            const rb = inBuffer.startBitDecoding(true);
            if (!rb.ok) return general<u64>("Failed to start start-face bit decoding");
            // Up to actual_num_symbols bits; unused ones are harmless.
            const numBitsToRead = minU64(actualNumSymbols, <u64>inBuffer.remainingSize() * 8);
            const reader = new SizedBitReader(inBuffer, rb.value);
            const bits = new Array<bool>();
            for (let k: u64 = 0; k < numBitsToRead; k++) {
                const v = reader.read(1);
                if (v < 0) break;
                bits.push(v != 0);
            }
            inBuffer.endBitDecoding();
            startFaceBitsLegacy = bits;
        } else {
            hasStartFaceBits = startFaceDecoder.startDecoding(inBuffer);
        }

        // The declared face count bounds the traversal; the mesh is sized
        // below from the corner table the traversal actually produced.
        const rc = EdgebreakerConnectivityDecoder.tryNew(<i32>totalNumFaces, <i32>maxNumVertices);
        if (!rc.ok) return rc.forward<u64>();
        const connectivityDecoder = rc.value;

        let startFaceDecoderOpt: RAnsBitDecoder? = null;
        let hasStartFaceBitsFlag = false;
        let processedConnectivityCorners: Array<u32>;

        // Valence and predictive modes start the seam decoders before the
        // per-context / prediction streams, and decode from them afterwards.
        const legacySeamDecoders = new Array<RAnsBitDecoder>();
        const removeInvalidVertices = numAttributeData == 0 || bitstreamVersion < 0x0202;

        let numVertices: u64;
        if (this.traversalDecoderType == 1) {
            // Predictive mode (legacy, pre-0.10.0): start faces (read above),
            // attribute seams, a split-symbol count, the prediction stream.
            for (let k: u8 = 0; k < numAttributeData; k++) {
                const seamDecoder = new RAnsBitDecoder();
                if (!seamDecoder.startDecoding(inBuffer)) {
                    return general<u64>("Failed to start attribute seam decoding for predictive");
                }
                legacySeamDecoders.push(seamDecoder);
            }

            // Split-symbol count (raw int32 pre-2.0), already folded into
            // max_num_vertices: read only to advance the buffer.
            if (!inBuffer.decodeU32().ok) {
                return general<u64>("Failed to read predictive split-symbol count");
            }
            // Binary prediction stream (whether each prediction was correct).
            const predictionDecoder = new RAnsBitDecoder();
            if (!predictionDecoder.startDecoding(inBuffer)) {
                return general<u64>("Failed to start predictive prediction stream");
            }

            const predictive = new MeshEdgebreakerTraversalPredictiveDecoder(
                startFaceDecoder,
                hasStartFaceBits,
                cloneEvents(topologySplitData),
                startFaceBitsLegacy,
                legacyDirectSymbolBits,
                predictionDecoder,
                maxNumVertices,
            );
            startFaceBitsLegacy = null;
            legacyDirectSymbolBits = null;

            const rn = connectivityDecoder.decodeConnectivity(<i32>actualNumSymbols, predictive, removeInvalidVertices, inputFaceBound);
            if (!rn.ok) return rn.forward<u64>();
            numVertices = <u64><i64>rn.value;

            hasStartFaceBitsFlag = predictive.hasStartFaceBits;
            startFaceDecoderOpt = predictive.startFaceDecoder;
            processedConnectivityCorners = predictive.processedConnectivityCorners;
        } else if (this.traversalDecoderType == 2) {
            // Valence mode: start faces (read above), attribute seam decoders
            // (started now to position the buffer), context symbols.
            for (let k: u8 = 0; k < numAttributeData; k++) {
                const seamDecoder = new RAnsBitDecoder();
                if (!seamDecoder.startDecoding(inBuffer)) {
                    return general<u64>("Failed to start attribute seam decoding for valence");
                }
                legacySeamDecoders.push(seamDecoder);
            }

            const valence = new MeshEdgebreakerTraversalValenceDecoder(
                startFaceDecoder,
                hasStartFaceBits,
                cloneEvents(topologySplitData),
                startFaceBitsLegacy,
                legacyDirectSymbolBits,
            );
            startFaceBitsLegacy = null;
            legacyDirectSymbolBits = null;
            // Initialize the contexts from the buffer.
            const ri = valence.initFromBuffer(inBuffer, maxNumVertices, bitstreamVersion, actualNumSymbols);
            if (!ri.ok) {
                return general<u64>("Failed to init valence traversal decoder: " + ri.err);
            }

            const rn = connectivityDecoder.decodeConnectivity(<i32>actualNumSymbols, valence, removeInvalidVertices, inputFaceBound);
            if (!rn.ok) return rn.forward<u64>();
            numVertices = <u64><i64>rn.value;

            // The seam decoders are read after the corner table is built.
            hasStartFaceBitsFlag = valence.hasStartFaceBits;
            startFaceDecoderOpt = valence.startFaceDecoder;
            processedConnectivityCorners = valence.processedConnectivityCorners;
        } else {
            const traversal = new InternalTraversalDecoder(
                symbols,
                topologySplitData,
                startFaceDecoder,
                hasStartFaceBits,
                startFaceBitsLegacy,
                maxNumVertices,
            );
            startFaceBitsLegacy = null;

            const rn = connectivityDecoder.decodeConnectivity(<i32>actualNumSymbols, traversal, removeInvalidVertices, inputFaceBound);
            if (!rn.ok) return rn.forward<u64>();
            numVertices = <u64><i64>rn.value;

            hasStartFaceBitsFlag = traversal.hasStartFaceBits;
            startFaceDecoderOpt = traversal.startFaceDecoder;
            processedConnectivityCorners = traversal.processedConnectivityCorners;
        }

        if (hasStartFaceBitsFlag) {
            const sfd = startFaceDecoderOpt;
            if (sfd != null) sfd.endDecoding();
        }

        // Reverse the connectivity corner order to match the encoder-side
        // reversal applied before attribute sequencing.
        processedConnectivityCorners.reverse();
        this.processedConnectivityCorners = processedConnectivityCorners;

        // Store the corner table, truncated to the actual vertex count.
        const ct = connectivityDecoder.cornerTable;
        if (numVertices < <u64>ct.vertexCorners.length) ct.vertexCorners.length = <i32>numVertices;
        // Size the mesh from what was decoded.
        const rsf = mesh.trySetNumFaces(<u64>ct.numFaces());
        if (!rsf.ok) return rsf.forward<u64>();
        const hole = connectivityDecoder.isVertHole;
        if (numVertices < <u64>hole.length) hole.length = <i32>numVertices;
        this.isVertHole = hole;

        // Every vertex's left-most corner is exactly vertex_corners[v].
        this.vertexToCornerMap = ct.vertexCorners.slice(0);

        this.cornerTable = ct;

        const rp = this.assignPointsToCorners(mesh);
        if (!rp.ok) return rp.forward<u64>();

        // Decode the attribute seams.
        this.attributeSeamCorners.length = 0;

        const usesLegacyAttributeConnectivity = bitstreamVersion < 0x0201;

        if (this.traversalDecoderType == 1 || this.traversalDecoderType == 2) {
            // Valence/predictive: the seam decoders already started.
            for (let i = 0; i < legacySeamDecoders.length; i++) {
                const seamDecoder = legacySeamDecoders[i];
                this.attributeSeamCorners.push(decodeSeamCorners(ct, mesh, seamDecoder, usesLegacyAttributeConnectivity));
                seamDecoder.endDecoding();
            }
        } else {
            // Non-valence: start the seam decoders from the buffer now.
            for (let k: u8 = 0; k < numAttributeData; k++) {
                const seamDecoder = new RAnsBitDecoder();
                if (!seamDecoder.startDecoding(inBuffer)) {
                    return general<u64>("Failed to start seam decoding");
                }
                this.attributeSeamCorners.push(decodeSeamCorners(ct, mesh, seamDecoder, usesLegacyAttributeConnectivity));
                seamDecoder.endDecoding();
            }
        }

        return Result.okv<u64>(<u64>mesh.numFaces());
    }

    static decodeSymbolStream(inBuffer: DecoderBuffer, numSymbols: u64): Result<Array<u32>> {
        if (numSymbols == 0) {
            return Result.okv<Array<u32>>(new Array<u32>());
        }

        // Traversal symbols are a size-prefixed bit sequence.
        const rb = inBuffer.startBitDecoding(true);
        if (!rb.ok) return general<Array<u32>>("Failed to start traversal symbol bit decoding");
        const bits = new SizedBitReader(inBuffer, rb.value);

        const symbols = new Array<u32>();
        for (let k: u64 = 0; k < numSymbols; k++) {
            const firstBit = bits.read(1);
            if (firstBit < 0) return general<Array<u32>>("Failed to read traversal symbol");
            let topology: u32;
            if (firstBit == 0) {
                topology = 0;
            } else {
                const suffix = bits.read(2);
                if (suffix < 0) return general<Array<u32>>("Failed to read traversal symbol suffix");
                topology = 1 | (<u32>suffix << 1);
            }
            const id = patternToSymbolId(topology);
            if (id < 0) {
                // Unreachable (0 and 1|suffix<<1 are all valid patterns);
                // the refusal is the Result form's.
                return MeshEdgebreakerDecoder.topologyBitPatternToSymbolId(topology).forward<Array<u32>>();
            }
            symbols.push(<u32>id);
        }

        // Skip to the end of the symbol bit sequence so what follows (start
        // faces, seams) is aligned.
        inBuffer.endBitDecoding();

        return Result.okv<Array<u32>>(symbols);
    }

    // C++ MeshEdgebreakerDecoderImpl::AssignPointsToCorners, the
    // `attribute_data_.empty()` branch: a corner table vertex index is a
    // point index outright.
    private assignPointsToCorners(mesh: Mesh): Status {
        const cornerTable = this.cornerTable;
        if (cornerTable == null) return general<bool>("Corner table not initialized");

        // Reject an inconsistent table before per-face arrays are indexed by
        // table-derived ids.
        if (!cornerTable.isIndexConsistent()) {
            return general<bool>("Inconsistent corner table for attribute traversal");
        }

        const numVertices = cornerTable.numVertices();

        // face[c] = corner_table_->Vertex(start_corner + c): one copy.
        mesh.setFacesFromCornerVertices(cornerTable.cornerToVertexMap);
        mesh.setNumPoints(numVertices);

        return okStatus();
    }
}

// The seam corners of one attribute: every boundary corner, plus each
// interior corner whose seam bit is set (every interior corner reads a bit
// below 2.1; from 2.1 only the face with the smaller index reads it).
function decodeSeamCorners(ct: CornerTable, mesh: Mesh, seamDecoder: RAnsBitDecoder, legacy: bool): Array<u32> {
    const seamCorners = new Array<u32>();
    const nf = mesh.numFaces();
    for (let f = 0; f < nf; f++) {
        for (let k = 0; k < 3; k++) {
            const c = <u32>(f * 3 + k);
            const opp = ct.opposite(c);
            if (opp != INVALID_CORNER_INDEX) {
                const oppFace = <i64>(opp / 3);
                if (legacy) {
                    if (seamDecoder.decodeNextBit()) {
                        seamCorners.push(c);
                    }
                } else if (<i64>f < oppFace && seamDecoder.decodeNextBit()) {
                    seamCorners.push(c);
                }
            } else {
                seamCorners.push(c);
            }
        }
    }
    return seamCorners;
}

// A deep copy of the events.
function cloneEvents(events: Array<TopologySplitEventData>): Array<TopologySplitEventData> {
    const out = new Array<TopologySplitEventData>();
    for (let i = 0; i < events.length; i++) out.push(events[i].clone());
    return out;
}

// The standard traversal: symbols pre-decoded from the symbol stream.
export class InternalTraversalDecoder extends EdgebreakerTraversalDecoder {
    private symbols: Array<u32>;
    private symbolIndex: i32 = 0;
    private splits: SplitEventCursor;
    startFaceDecoder: RAnsBitDecoder;
    hasStartFaceBits: bool;
    // v < 2.2: pre-read start face configuration bits (raw bit buffer), used
    // in place of the RAnsBitDecoder when present.
    private startFaceBitsLegacy: Array<bool>?;
    private startFaceBitsLegacyIndex: i32 = 0;
    processedConnectivityCorners: Array<u32> = new Array<u32>();

    constructor(
        symbols: Array<u32>,
        topologySplitData: Array<TopologySplitEventData>,
        startFaceDecoder: RAnsBitDecoder,
        hasStartFaceBits: bool,
        startFaceBitsLegacy: Array<bool>?,
        _maxNumVertices: u64,
    ) {
        super();
        this.symbols = symbols;
        this.splits = new SplitEventCursor(topologySplitData);
        this.startFaceDecoder = startFaceDecoder;
        this.hasStartFaceBits = hasStartFaceBits;
        this.startFaceBitsLegacy = startFaceBitsLegacy;
    }

    decodeSymbol(): i64 {
        const i = this.symbolIndex;
        if (i >= this.symbols.length) {
            return this.symbolFail(DracoError.general("Traversal symbol stream exhausted"));
        }
        this.symbolIndex = i + 1;
        return <i64>this.symbols[i];
    }

    decodeStartFaceConfiguration(): bool {
        // v < 2.2: the pre-read raw bit buffer.
        const bits = this.startFaceBitsLegacy;
        if (bits != null) {
            const idx = this.startFaceBitsLegacyIndex;
            this.startFaceBitsLegacyIndex += 1;
            return idx < bits.length ? bits[idx] : true;
        }
        // v >= 2.2: the RAnsBitDecoder.
        if (this.hasStartFaceBits) {
            return this.startFaceDecoder.decodeNextBit();
        }
        return true;
    }

    mergeVertices(_p: VertexIndex, _n: VertexIndex): void {
        // Points are logically merged in the corner table.
    }

    isTopologySplit(encoderSymbolId: i32): SplitHit? {
        return this.splits.isTopologySplit(encoderSymbolId);
    }

    onVertexCreated(_vertex: VertexIndex, _symbolId: i32, _cornerIndex: i32): void {}

    onVerticesSwapped(_v1: VertexIndex, _v2: VertexIndex): void {}

    onStartFaceDecoded(_corner: CornerIndex): void {}

    onSplitSymbolDecoded(_corner: CornerIndex): void {}

    newActiveCornerReached(corner: CornerIndex, _cornerTable: CornerTable): void {
        // C++ processed_connectivity_corners_: corners in visiting order.
        this.processedConnectivityCorners.push(corner);
    }
}
