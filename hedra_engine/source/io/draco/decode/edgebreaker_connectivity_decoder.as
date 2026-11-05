// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The EdgeBreaker traversal-decoder interface and the connectivity
// reconstruction the standard, valence and predictive traversals share
// (Draco's `mesh_edgebreaker_traversal_decoder.h` plus the DecodeConnectivity
// loop).
//
// Notes:
// - `EdgebreakerTraversalDecoder` is an abstract class with default methods;
//   the connectivity decode takes the base class.
// - `decodeSymbol` answers the symbol, or -1 with the error left in
//   `symbolError` (one Result per symbol would be one allocation per face
//   under the never-freeing runtime).
// - `isTopologySplit` answers a `SplitHit` or null.
// - Internal helpers that can fail answer `DracoError?` (null = Ok),
//   for the same reason.

import { Result } from "../../../../base/util";
import { DracoError } from "../core/status";
import { CornerIndex, VertexIndex, INVALID_CORNER_INDEX, INVALID_VERTEX_INDEX } from "../geometry/geometry_indices";
import { CornerTable } from "../mesh/corner_table";
import { EdgeFaceName, TopologySplitEventData } from "../mesh/mesh_edgebreaker_shared";

// A topology split found by `isTopologySplit`: the edge and the split symbol.
export class SplitHit {
    edge: EdgeFaceName;
    splitSymbolId: i32;

    constructor(edge: EdgeFaceName, splitSymbolId: i32) {
        this.edge = edge;
        this.splitSymbolId = splitSymbolId;
    }
}

// The split-event lookup the three traversal decoders share verbatim: C++
// checks from the back of the list (highest source_symbol_id first) and
// pops; events are sorted ascending by source_symbol_id, so `remaining`
// counts how many are left, from the end.
export class SplitEventCursor {
    data: Array<TopologySplitEventData>;
    remaining: i32;

    constructor(data: Array<TopologySplitEventData>) {
        this.data = data;
        this.remaining = data.length;
    }

    isTopologySplit(encoderSymbolId: i32): SplitHit? {
        if (this.remaining > 0) {
            const event = this.data[this.remaining - 1];
            if (event.sourceSymbolId == <u32>encoderSymbolId) {
                // Found a match - consume this event (like C++ pop_back).
                this.remaining -= 1;
                return new SplitHit(event.sourceEdge, <i32>event.splitSymbolId);
            } else if (event.sourceSymbolId > <u32>encoderSymbolId) {
                // encoder_symbol_id only decreases and nothing matched: an
                // invalid id signals the error (matching C++).
                return new SplitHit(EdgeFaceName.LeftFaceEdge, -1);
            }
            // event.source_symbol_id < encoder_symbol_id: not reached yet.
        }
        return null;
    }
}

// The per-symbol source the connectivity decode reads from.
export abstract class EdgebreakerTraversalDecoder {
    // The error of the last `decodeSymbol` that answered -1.
    symbolError: DracoError? = null;

    // The next symbol (0..=u32 range), or -1 with `symbolError` set.
    abstract decodeSymbol(): i64;
    abstract decodeStartFaceConfiguration(): bool;
    abstract mergeVertices(p: VertexIndex, n: VertexIndex): void;
    abstract isTopologySplit(encoderSymbolId: i32): SplitHit?;
    abstract onVertexCreated(vertex: VertexIndex, symbolId: i32, cornerIndex: i32): void;
    abstract onVerticesSwapped(v1: VertexIndex, v2: VertexIndex): void;
    abstract onStartFaceDecoded(corner: CornerIndex): void;
    onSplitSymbolDecoded(_corner: CornerIndex): void {}

    // Matches C++ traversal_decoder_.NewActiveCornerReached(active_corner_stack.back()).
    newActiveCornerReached(_corner: CornerIndex, _cornerTable: CornerTable): void {}

    // Capacity hints; an AS Array grows on push, so these only exist for
    // the call sequence.
    reserveTraversalOrder(_faces: u64): void {}
    reserveVertices(_vertices: u64): void {}

    // Helper for implementations: a failed decodeSymbol.
    protected symbolFail(e: DracoError): i64 {
        this.symbolError = e;
        return -1;
    }
}

function satMulU64(a: u64, b: u64): u64 {
    if (a != 0 && b > u64.MAX_VALUE / a) return u64.MAX_VALUE;
    return a * b;
}

// The most faces the corner table is reserved for up front (three times as
// many vertices). The caller's bound is the header's face count, capped by
// the input size. A reservation is a zero-filled, never-freed Array<u32>,
// and one longer than an Array<u32> can be (CORNER_TABLE_MAX_LEN) would be
// refused with "Failed to allocate corner table", so a header claiming
// ~90M+ faces over a 6 MB payload would fail before decoding anything.
// Reservation is capacity only, so the hint is capped: past the cap the
// tables grow as faces are decoded (doubling, capped at the declared total),
// and growth past what an Array<u32> holds is still refused when it happens.
const RESERVE_FACES_CAP: u64 = 1 << 22;

export class EdgebreakerConnectivityDecoder {
    cornerTable: CornerTable = new CornerTable(0);
    isVertHole: Array<bool> = new Array<bool>();
    // Face and vertex counts the bitstream declared. They bound the decode,
    // but nothing is allocated for them up front.
    private declaredNumFaces: i32;
    private maxNumVertices: u64;
    private activeCornerStack: Array<u32> = new Array<u32>();
    private topologySplitActiveCorners: Map<i32, u32> = new Map<i32, u32>();
    private invalidVertices: Array<u32> = new Array<u32>();

    constructor(numFaces: i32, maxNumVertices: i32) {
        this.declaredNumFaces = numFaces;
        this.maxNumVertices = <u64>(maxNumVertices > 0 ? maxNumVertices : 0);
    }

    // Fallible constructor mirroring `new` (never fails).
    static tryNew(numFaces: i32, maxNumVertices: i32): Result<EdgebreakerConnectivityDecoder> {
        return Result.okv<EdgebreakerConnectivityDecoder>(new EdgebreakerConnectivityDecoder(numFaces, maxNumVertices));
    }

    // Marks `vertex` as not lying on a hole, growing the table to reach it
    // (entries are `true` until written).
    private markVertNotHole(vertex: VertexIndex, context: string): DracoError? {
        if (vertex == INVALID_VERTEX_INDEX || <u64>vertex >= this.maxNumVertices) {
            return EdgebreakerConnectivityDecoder.invalidVertex(vertex, context);
        }
        const index = <i32>vertex;
        const h = this.isVertHole;
        if (index < h.length) {
            unchecked((h[index] = false));
        } else {
            while (h.length < index) h.push(true);
            h.push(false);
        }
        return null;
    }

    decodeConnectivity(
        numSymbols: i32,
        traversalDecoder: EdgebreakerTraversalDecoder,
        removeInvalidVertices: bool,
        inputFaceBound: u64,
    ): Result<i32> {
        const maxNumVertices = <i32>this.maxNumVertices;
        let numFaces: i32 = 0;
        const ct = this.cornerTable;
        const declaredFaces = <u64>(this.declaredNumFaces > 0 ? this.declaredNumFaces : 0);

        // Capacity hints, capped at RESERVE_FACES_CAP (see there).
        const rf = ct.tryReserveFaces(inputFaceBound < RESERVE_FACES_CAP ? inputFaceBound : RESERVE_FACES_CAP);
        if (!rf.ok) return rf.forward<i32>();
        // Three vertices per face is the geometric ceiling.
        const faceVerts = satMulU64(inputFaceBound, 3);
        const vertexBound = this.maxNumVertices < faceVerts ? this.maxNumVertices : faceVerts;
        const vertexCap: u64 = 3 * RESERVE_FACES_CAP;
        const rv = ct.tryReserveVertices(vertexBound < vertexCap ? vertexBound : vertexCap);
        if (!rv.ok) return rv.forward<i32>();
        // is_vert_hole.try_reserve: the table grows by push; nothing to size.
        traversalDecoder.reserveTraversalOrder(inputFaceBound);
        traversalDecoder.reserveVertices(vertexBound);

        const stack = this.activeCornerStack;

        for (let symbolId: i32 = 0; symbolId < numSymbols; symbolId++) {
            const face = <u32>numFaces;
            numFaces += 1;
            // Faces are created strictly in order: the table's end is always
            // this face's first corner.
            const rp = ct.tryPushFace(declaredFaces);
            if (!rp.ok) return rp.forward<i32>();

            let checkTopologySplit = false;
            const sym = traversalDecoder.decodeSymbol();
            if (sym < 0) return fail<i32>(symbolErrorOf(traversalDecoder));
            const symbol = <u32>sym;

            // Internal symbol mapping (see `EdgebreakerSymbol`):
            //   Center = 0, Split = 1, Left = 2, Right = 3, End = 4
            if (symbol == 0) {
                // TOPOLOGY_C
                if (stack.length == 0) {
                    return fail<i32>(DracoError.general("active_corner_stack empty in TOPOLOGY_C"));
                }

                const cornerA = stack[stack.length - 1];
                const vertexX = ct.vertexAfter(cornerA);
                const cornerB = ct.next(ct.leftMostCorner(vertexX));

                if (cornerA == cornerB) {
                    return fail<i32>(DracoError.general("corner_a == corner_b in TOPOLOGY_C"));
                }
                if (ct.opposite(cornerA) != INVALID_CORNER_INDEX || ct.opposite(cornerB) != INVALID_CORNER_INDEX) {
                    return fail<i32>(DracoError.general("Edge already opposite in TOPOLOGY_C"));
                }

                const corner: u32 = 3 * face;
                let e = this.setOppositeCorners(cornerA, corner + 1);
                if (e != null) return fail<i32>(e);
                e = this.setOppositeCorners(cornerB, corner + 2);
                if (e != null) return fail<i32>(e);

                const vertAPrev = ct.vertexBefore(cornerA);
                const vertBNext = ct.vertexAfter(cornerB);
                if (vertexX == vertAPrev || vertexX == vertBNext) {
                    return fail<i32>(DracoError.general("Degenerate face in TOPOLOGY_C"));
                }

                ct.mapCornerToVertex(corner, vertexX);
                ct.mapCornerToVertex(corner + 1, vertBNext);
                ct.mapCornerToVertex(corner + 2, vertAPrev);
                ct.setLeftMostCorner(vertAPrev, corner + 2);

                e = this.markVertNotHole(vertexX, "TOPOLOGY_C");
                if (e != null) return fail<i32>(e);
                stack[stack.length - 1] = corner;
            } else if (symbol == 3 || symbol == 2) {
                // Right (3) or Left (2).
                if (stack.length == 0) {
                    return fail<i32>(DracoError.general("active_corner_stack empty in TOPOLOGY_R/L"));
                }
                const cornerA = stack[stack.length - 1];
                if (ct.opposite(cornerA) != INVALID_CORNER_INDEX) {
                    return fail<i32>(DracoError.general("Edge already opposite in TOPOLOGY_R/L"));
                }

                // C++ `MeshEdgebreakerDecoderImpl::DecodeConnectivity()`:
                // - Right: opp_corner = corner + 2, corner_l = corner + 1, corner_r = corner
                // - Left:  opp_corner = corner + 1, corner_l = corner,     corner_r = corner + 2
                const corner: u32 = 3 * face;
                let oppCorner: u32;
                let cornerL: u32;
                let cornerR: u32;
                if (symbol == 3) {
                    oppCorner = corner + 2;
                    cornerL = corner + 1;
                    cornerR = corner;
                } else {
                    oppCorner = corner + 1;
                    cornerL = corner;
                    cornerR = corner + 2;
                }

                const e = this.setOppositeCorners(oppCorner, cornerA);
                if (e != null) return fail<i32>(e);
                const newVertIndex = ct.addNewVertex();
                traversalDecoder.onVertexCreated(newVertIndex, symbolId, <i32>oppCorner);

                if (ct.numVertices() > maxNumVertices) {
                    return fail<i32>(DracoError.general("Unexpected number of vertices in TOPOLOGY_R/L"));
                }

                ct.mapCornerToVertex(oppCorner, newVertIndex);
                ct.setLeftMostCorner(newVertIndex, oppCorner);

                const vertexR = ct.vertexBefore(cornerA);
                ct.mapCornerToVertex(cornerR, vertexR);
                ct.setLeftMostCorner(vertexR, cornerR);

                ct.mapCornerToVertex(cornerL, ct.vertexAfter(cornerA));
                stack[stack.length - 1] = corner;
                checkTopologySplit = true;
            } else if (symbol == 1) {
                // TOPOLOGY_S
                if (stack.length == 0) {
                    return fail<i32>(DracoError.general("active_corner_stack empty in TOPOLOGY_S"));
                }
                const cornerB = stack.pop();

                const decoderSplitSymbolId = symbolId;
                if (this.topologySplitActiveCorners.has(decoderSplitSymbolId)) {
                    stack.push(this.topologySplitActiveCorners.get(decoderSplitSymbolId));
                }

                if (stack.length == 0) {
                    return fail<i32>(DracoError.general("active_corner_stack empty in TOPOLOGY_S after split retrieval"));
                }
                const cornerA = stack[stack.length - 1];

                if (cornerA == cornerB) {
                    return fail<i32>(DracoError.general("corner_a == corner_b in TOPOLOGY_S"));
                }
                if (ct.opposite(cornerA) != INVALID_CORNER_INDEX || ct.opposite(cornerB) != INVALID_CORNER_INDEX) {
                    return fail<i32>(DracoError.general("Edge already opposite in TOPOLOGY_S"));
                }

                const corner: u32 = 3 * face;
                let e = this.setOppositeCorners(cornerA, corner + 2);
                if (e != null) return fail<i32>(e);
                e = this.setOppositeCorners(cornerB, corner + 1);
                if (e != null) return fail<i32>(e);

                const vertexP = ct.vertexBefore(cornerA);
                ct.mapCornerToVertex(corner, vertexP);
                ct.mapCornerToVertex(corner + 1, ct.vertexAfter(cornerA));

                const vertBPrev = ct.vertexBefore(cornerB);
                ct.mapCornerToVertex(corner + 2, vertBPrev);
                ct.setLeftMostCorner(vertBPrev, corner + 2);

                let cornerN = ct.next(cornerB);
                const vertexN = ct.vertex(cornerN);

                if (vertexN != vertexP && vertexN != INVALID_VERTEX_INDEX) {
                    traversalDecoder.mergeVertices(vertexP, vertexN);
                    ct.setLeftMostCorner(vertexP, ct.leftMostCorner(vertexN));

                    const firstCorner = cornerN;
                    while (cornerN != INVALID_CORNER_INDEX) {
                        ct.mapCornerToVertex(cornerN, vertexP);
                        cornerN = ct.swingLeft(cornerN);
                        if (cornerN == firstCorner) {
                            return fail<i32>(DracoError.general("Cycle detected in vertex merge"));
                        }
                    }

                    ct.makeVertexIsolated(vertexN);
                    if (removeInvalidVertices) {
                        this.invalidVertices.push(vertexN);
                    }
                }
                stack[stack.length - 1] = corner;
                traversalDecoder.onSplitSymbolDecoded(corner);
            } else if (symbol == 4) {
                // TOPOLOGY_E
                const corner: u32 = 3 * face;
                const v0 = ct.addNewVertex();
                const v1 = ct.addNewVertex();
                const v2 = ct.addNewVertex();

                traversalDecoder.onVertexCreated(v0, symbolId, <i32>corner);
                traversalDecoder.onVertexCreated(v1, symbolId, <i32>(corner + 1));
                traversalDecoder.onVertexCreated(v2, symbolId, <i32>(corner + 2));

                if (ct.numVertices() > maxNumVertices) {
                    return fail<i32>(DracoError.general("Unexpected number of vertices in TOPOLOGY_E"));
                }

                ct.mapCornerToVertex(corner, v0);
                ct.mapCornerToVertex(corner + 1, v1);
                ct.mapCornerToVertex(corner + 2, v2);

                ct.setLeftMostCorner(v0, corner);
                ct.setLeftMostCorner(v1, corner + 1);
                ct.setLeftMostCorner(v2, corner + 2);

                stack.push(corner);
                checkTopologySplit = true;
            } else {
                return fail<i32>(DracoError.general("Unknown symbol " + symbol.toString()));
            }

            if (checkTopologySplit) {
                // encoder_symbol_id in C++ is num_symbols - symbol_id - 1.
                const encoderSymbolId = numSymbols - symbolId - 1;
                while (true) {
                    const hit = traversalDecoder.isTopologySplit(encoderSymbolId);
                    if (hit == null) break;
                    const encoderSplitSymbolId = hit.splitSymbolId;
                    if (encoderSplitSymbolId < 0) {
                        return fail<i32>(DracoError.general("Invalid split symbol id"));
                    }
                    if (stack.length == 0) {
                        return fail<i32>(EdgebreakerConnectivityDecoder.emptyActiveStack("topology split"));
                    }
                    const actTopCorner = stack[stack.length - 1];
                    const newActiveCorner = hit.edge == EdgeFaceName.RightFaceEdge
                        ? ct.next(actTopCorner)
                        : ct.previous(actTopCorner);
                    const decoderSplitSymbolId = numSymbols - encoderSplitSymbolId - 1;
                    this.topologySplitActiveCorners.set(decoderSplitSymbolId, newActiveCorner);
                }
            }

            // Inform the traversal decoder that a new active corner has been
            // reached (the decoder-side corner visitation order).
            if (stack.length > 0) {
                traversalDecoder.newActiveCornerReached(stack[stack.length - 1], ct);
            } else {
                return fail<i32>(DracoError.general("active_corner_stack empty after decoding symbol"));
            }
        }

        if (ct.numVertices() > maxNumVertices) {
            return fail<i32>(DracoError.general("Unexpected number of vertices after first pass"));
        }

        // Process component roots in LIFO order (matching C++ pop_back()).
        while (stack.length > 0) {
            const corner = stack.pop();
            const interiorFace = traversalDecoder.decodeStartFaceConfiguration();
            if (interiorFace) {
                if (numFaces >= this.declaredNumFaces) {
                    return fail<i32>(DracoError.general("More faces than expected in start face config"));
                }
                const cornerA = corner;
                const vertN = ct.vertexAfter(cornerA);
                if (ct.leftMostCorner(vertN) == INVALID_CORNER_INDEX) {
                    return fail<i32>(DracoError.general("Invalid left_most_corner for vert_n=" + vertN.toString()));
                }

                const cornerB = ct.next(ct.leftMostCorner(vertN));
                const vertX = ct.vertexAfter(cornerB);
                if (ct.leftMostCorner(vertX) == INVALID_CORNER_INDEX) {
                    return fail<i32>(DracoError.general("Invalid left_most_corner for vert_x"));
                }

                const cornerC = ct.next(ct.leftMostCorner(vertX));
                const vertP = ct.vertexAfter(cornerC);

                const face = <u32>numFaces;
                numFaces += 1;
                const rp = ct.tryPushFace(declaredFaces);
                if (!rp.ok) return rp.forward<i32>();
                const newCorner: u32 = 3 * face;
                let e = this.setOppositeCorners(newCorner, cornerA);
                if (e != null) return fail<i32>(e);
                e = this.setOppositeCorners(newCorner + 1, cornerB);
                if (e != null) return fail<i32>(e);
                e = this.setOppositeCorners(newCorner + 2, cornerC);
                if (e != null) return fail<i32>(e);

                ct.mapCornerToVertex(newCorner, vertX);
                ct.mapCornerToVertex(newCorner + 1, vertP);
                ct.mapCornerToVertex(newCorner + 2, vertN);

                for (let i: u32 = 0; i < 3; i++) {
                    const vertex = ct.vertex(newCorner + i);
                    e = this.markVertNotHole(vertex, "start face config");
                    if (e != null) return fail<i32>(e);
                }
                // Matching C++ init_corners_.push_back(new_corner).
                traversalDecoder.onStartFaceDecoded(newCorner);
            } else {
                // Boundary case: matching C++ init_corners_.push_back(corner).
                traversalDecoder.onStartFaceDecoded(corner);
            }
        }

        if (numFaces != this.declaredNumFaces) {
            return fail<i32>(DracoError.general("Unexpected number of faces at end"));
        }

        // Give the hole table its full extent now that the real vertex count
        // is known.
        const decodedNumVertices = ct.numVertices();
        const hole = this.isVertHole;
        while (hole.length < decodedNumVertices) hole.push(true);

        let numVertices: i32 = ct.numVertices();

        // Compact vertices (remove isolated/invalid ones), iterating
        // invalid_vertices in the order they were added (as C++).
        const invalid = this.invalidVertices;
        for (let k = 0; k < invalid.length; k++) {
            const invalidVert = invalid[k];

            // Find the last valid vertex (srcVert). `numVertices - 1` wraps
            // in u32 when there are no vertices.
            let srcVert: u32 = <u32>numVertices - 1;
            while (srcVert > 0 && ct.leftMostCorner(srcVert) == INVALID_CORNER_INDEX) {
                numVertices -= 1;
                if (numVertices == 0) {
                    break;
                }
                srcVert = <u32>numVertices - 1;
            }
            if (srcVert < invalidVert) {
                continue; // No need to swap.
            }

            // Remap all corners mapped to src_vert to invalid_vert (SwingRight,
            // matching C++ VertexCornersIterator).
            const startCorner = ct.leftMostCorner(srcVert);
            if (startCorner != INVALID_CORNER_INDEX) {
                let c = startCorner;
                while (true) {
                    if (ct.vertex(c) != srcVert) {
                        return fail<i32>(DracoError.general(
                            "Vertex mismatch during compaction: corner " + c.toString() + " maps to " +
                            ct.vertex(c).toString() + " expected " + srcVert.toString(),
                        ));
                    }
                    ct.mapCornerToVertex(c, invalidVert);
                    c = ct.swingRight(c);
                    if (c == INVALID_CORNER_INDEX || c == startCorner) {
                        break;
                    }
                }
            }

            ct.setLeftMostCorner(invalidVert, ct.leftMostCorner(srcVert));
            traversalDecoder.onVerticesSwapped(invalidVert, srcVert);
            ct.makeVertexIsolated(srcVert);

            if (<i64>invalidVert < <i64>hole.length && <i64>srcVert < <i64>hole.length) {
                hole[<i32>invalidVert] = hole[<i32>srcVert];
                hole[<i32>srcVert] = false;
            }

            numVertices -= 1;
        }

        return Result.okv<i32>(numVertices);
    }

    // The error for an empty active-corner stack.
    static emptyActiveStack(context: string): DracoError {
        return DracoError.general("active_corner_stack empty in " + context);
    }

    // The error for an out-of-range vertex.
    static invalidVertex(vertex: VertexIndex, context: string): DracoError {
        return DracoError.general("Invalid vertex " + vertex.toString() + " while decoding " + context);
    }

    // Pairs two corners as each other's opposite, refusing either that is
    // past the table (null = Ok).
    setOppositeCorners(c1: CornerIndex, c2: CornerIndex): DracoError? {
        if (c1 != INVALID_CORNER_INDEX && !this.cornerTable.trySetOpposite(c1, c2)) {
            return DracoError.general("Invalid opposite corner " + c1.toString());
        }
        if (c2 != INVALID_CORNER_INDEX && !this.cornerTable.trySetOpposite(c2, c1)) {
            return DracoError.general("Invalid opposite corner " + c2.toString());
        }
        return null;
    }
}

function symbolErrorOf(td: EdgebreakerTraversalDecoder): DracoError {
    const e = td.symbolError;
    if (e != null) return e;
    return DracoError.general("Unknown error");
}

function fail<T>(e: DracoError): Result<T> {
    return e.fail<T>();
}
