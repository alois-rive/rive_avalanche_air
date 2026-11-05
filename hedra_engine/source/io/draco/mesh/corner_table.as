// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Corner-table mesh connectivity.
//
// `CornerTable` is Draco's corner-based connectivity structure: each triangle
// contributes three corners, and `next`/`previous`/`opposite` plus the
// corner->vertex map let traversal walk the mesh in O(1) per step. It
// underpins EdgeBreaker connectivity and every mesh prediction scheme.
//
// API summary:
//   new CornerTable(n) / new CornerTable()    a table for n faces / an empty one
//   CornerTable.tryNew(n: u64)                fallible form: Result<CornerTable>
//   ct.cornerToVertexMap: Array<u32>          live corner -> vertex map
//   ct.oppositeCorners / ct.vertexCorners     live opposite and vertex -> corner maps
//   ct.numOriginalVertices                    vertex count before non-manifold splits
//   ct.numDegeneratedFaces()                  (field numDegeneratedFaces_)
//   ct.numIsolatedVertices()                  (field numIsolatedVertices_)
//   init(facesFlat: Array<u32>)               3 entries per face
//   counts                                    i32 (numVertices/numCorners/numFaces); stream-fed sizes u64
//
// `init` does not re-validate the table invariants after building it.

import { Result, i64FitsU32, panic } from "../../../../base/util";
import { debugList, debugStruct, debugTuple } from "../../../../base/fmt";
import { DracoError, Status, okStatus } from "../core/status";
import { BYTE_VEC_MAX_CAPACITY } from "../core/byte_vec";
import { resizeU32Array } from "../geometry/geometry_attribute";
import {
    CornerIndex,
    FaceIndex,
    PointIndex,
    VertexIndex,
    INVALID_CORNER_INDEX,
    INVALID_FACE_INDEX,
    INVALID_VERTEX_INDEX,
} from "../geometry/geometry_indices";
import { clock } from "rive/os";

// The longest Array<u32> rasc can back (its buffer is capped at
// BYTE_VEC_MAX_CAPACITY bytes). A table past this length cannot exist, so
// the fallible constructors refuse it with an allocation-failure message.
export const CORNER_TABLE_MAX_LEN: i64 = <i64>(BYTE_VEC_MAX_CAPACITY >> 2);

// The stages `CornerTable.initWithStageTimings` reports, in the order it
// reports them.
export enum InitStage {
    OppositeCorners = 0,
    BreakNonManifoldEdges = 1,
    VertexCorners = 2,
}

// Number of init stages.
export const INIT_STAGE_COUNT: i32 = 3;
// Every init stage, in order.
export const INIT_STAGE_ALL: StaticArray<InitStage> = [
    InitStage.OppositeCorners,
    InitStage.BreakNonManifoldEdges,
    InitStage.VertexCorners,
];

// `InitStage::name`.
export function initStageName(stage: InitStage): string {
    switch (stage) {
        case InitStage.OppositeCorners: return "opposite_corners";
        case InitStage.BreakNonManifoldEdges: return "break_non_manifold";
        case InitStage.VertexCorners: return "vertex_corners";
    }
    return "";
}

// `{:?}` of an InitStage.
export function initStageDebug(stage: InitStage): string {
    switch (stage) {
        case InitStage.OppositeCorners: return "OppositeCorners";
        case InitStage.BreakNonManifoldEdges: return "BreakNonManifoldEdges";
        case InitStage.VertexCorners: return "VertexCorners";
    }
    return "";
}

// The next corner within the same face, sentinel test omitted.
//
// Total on all of u32 (wrapping). It **absorbs** the sentinel: u32::MAX + 1
// wraps to 0, a multiple of three, so the answer is u32::MAX - 2 -- past the
// end of any table, so a bounds-checked lookup it feeds answers the sentinel
// again. Use it in the inner position only.
// @ts-ignore: decorator
@inline
export function nextInFace(corner: u32): u32 {
    const n: u32 = corner + 1;
    if (n % 3 != 0) return n;
    return corner - 2;
}

// The previous corner within the same face, sentinel test omitted. It
// **preserves** the sentinel: u32::MAX is a multiple of three, so the `+ 2`
// arm is taken and saturates at u32::MAX.
// @ts-ignore: decorator
@inline
export function prevInFace(corner: u32): u32 {
    if (corner % 3 != 0) return corner - 1;
    return corner > u32.MAX_VALUE - 2 ? u32.MAX_VALUE : corner + 2;
}

// `a[i] = v`, panicking out of bounds (a plain AS Array write would grow).
// @ts-ignore: decorator
@inline
export function setU32At(a: Array<u32>, i: u32, v: u32): void {
    if (i >= <u32>a.length) {
        panic("index out of bounds: the len is " + a.length.toString() + " but the index is " + i.toString());
    }
    unchecked((a[<i32>i] = v));
}

// `a[i]`, panicking out of bounds with an index-out-of-bounds message.
// @ts-ignore: decorator
@inline
export function getU32At(a: Array<u32>, i: u32): u32 {
    if (i >= <u32>a.length) {
        panic("index out of bounds: the len is " + a.length.toString() + " but the index is " + i.toString());
    }
    return unchecked(a[<i32>i]);
}

// The capacity of an Array<u32> (its backing store, in elements).
export unsafe function capacityU32(a: Array<u32>): i64 {
    return <i64>(load<u32>(changetype<usize>(a), offsetof<ArrayBufferView>("byteLength")) >>> 2);
}

// Reserves exactly a total capacity of `total` (no change when
// the capacity already covers it). The caller has checked `total` against
// CORNER_TABLE_MAX_LEN.
function reserveTotalU32(a: Array<u32>, total: i64): void {
    if (total <= capacityU32(a)) return;
    const len = a.length;
    a.length = <i32>total; // grows the backing store to exactly `total`
    a.length = len; // shrinking keeps the store
}

function failedToAllocate<T>(): Result<T> {
    return DracoError.general("Failed to allocate corner table").fail<T>();
}

function sizeOverflow<T>(): Result<T> {
    return DracoError.general("Corner table size overflow").fail<T>();
}

function newFilledU32(n: i32, fill: u32): Array<u32> {
    const a = new Array<u32>(n);
    if (fill != 0) a.fill(fill);
    return a;
}

function debugIndexList(name: string, a: Array<u32>): string {
    const parts = new Array<string>(a.length);
    for (let i = 0; i < a.length; i++) parts[i] = debugTuple(name, [unchecked(a[i]).toString()]);
    return debugList(parts);
}

// The growth policy of `tryGrowToCorners`, for one of the two maps:
// reserve by doubling capped at the declared total, then fill.
function growMap(vec: Array<u32>, numCorners: i64, declaredCorners: i64, fill: u32): Status {
    const capacity = capacityU32(vec);
    if (numCorners > capacity) {
        let doubled = capacity * 2;
        if (doubled < numCorners) doubled = numCorners;
        let target: i64;
        if (capacity < declaredCorners) {
            target = doubled < declaredCorners ? doubled : declaredCorners;
            if (target < numCorners) target = numCorners;
        } else {
            target = doubled;
        }
        // Past what an Array<u32> can hold the reservation fails. A larger
        // target than needed is capped rather than refused, so only a count
        // that truly cannot be backed fails.
        if (numCorners > CORNER_TABLE_MAX_LEN) return failedToAllocate<bool>();
        if (target > CORNER_TABLE_MAX_LEN) target = CORNER_TABLE_MAX_LEN;
        reserveTotalU32(vec, target);
    }
    resizeU32Array(vec, <i32>numCorners, fill);
    return okStatus();
}

// "sentinel, or below the bound" as one biased signed comparison (used by
// the index-consistency check): true when some value is at or past
// `bound` and is not the sentinel.
function exceeds(values: Array<u32>, bound: i64): bool {
    const b: u32 = bound > 0 && !i64FitsU32(bound) ? u32.MAX_VALUE : <u32>bound;
    const biasedBound = <i32>(b ^ 0x8000_0000);
    let hit: u32 = 0;
    const n = values.length;
    for (let i = 0; i < n; i++) {
        const v = unchecked(values[i]);
        hit |= <u32>(<i32>(v + 0x8000_0001) > biasedBound);
    }
    return hit != 0;
}

export class CornerTable {
    cornerToVertexMap: Array<u32>;
    oppositeCorners: Array<u32>;
    vertexCorners: Array<u32>;
    numOriginalVertices: i32 = 0;
    numDegeneratedFaces_: i32 = 0;
    numIsolatedVertices_: i32 = 0;

    // A table for `numFaces` faces, every entry unset; `new CornerTable()`
    // is an empty table.
    constructor(numFaces: i32 = 0) {
        this.cornerToVertexMap = newFilledU32(numFaces * 3, INVALID_VERTEX_INDEX);
        this.oppositeCorners = newFilledU32(numFaces * 3, INVALID_CORNER_INDEX);
        this.vertexCorners = new Array<u32>();
    }

    // Fallible constructor: an oversized `numFaces` returns a DracoError
    // instead of aborting. Behaviorally identical to `new` on success.
    static tryNew(numFaces: u64): Result<CornerTable> {
        if (numFaces > u64.MAX_VALUE / 3) return sizeOverflow<CornerTable>();
        const numCorners = numFaces * 3;
        if (numCorners > <u64>CORNER_TABLE_MAX_LEN) return failedToAllocate<CornerTable>();
        const ct = new CornerTable();
        ct.cornerToVertexMap = newFilledU32(<i32>numCorners, INVALID_VERTEX_INDEX);
        ct.oppositeCorners = newFilledU32(<i32>numCorners, INVALID_CORNER_INDEX);
        return Result.okv<CornerTable>(ct);
    }

    // A deep copy.
    clone(): CornerTable {
        const ct = new CornerTable();
        ct.cornerToVertexMap = this.cornerToVertexMap.slice(0);
        ct.oppositeCorners = this.oppositeCorners.slice(0);
        ct.vertexCorners = this.vertexCorners.slice(0);
        ct.numOriginalVertices = this.numOriginalVertices;
        ct.numDegeneratedFaces_ = this.numDegeneratedFaces_;
        ct.numIsolatedVertices_ = this.numIsolatedVertices_;
        return ct;
    }

    // Debug text of every field.
    debug(): string {
        return debugStruct(
            "CornerTable",
            [
                "corner_to_vertex_map",
                "opposite_corners",
                "vertex_corners",
                "num_original_vertices",
                "num_degenerated_faces",
                "num_isolated_vertices",
            ],
            [
                debugIndexList("VertexIndex", this.cornerToVertexMap),
                debugIndexList("CornerIndex", this.oppositeCorners),
                debugIndexList("CornerIndex", this.vertexCorners),
                this.numOriginalVertices.toString(),
                this.numDegeneratedFaces_.toString(),
                this.numIsolatedVertices_.toString(),
            ],
        );
    }

    // Reserves corner storage for `faces` without changing `numFaces()`.
    // A face count whose corner count overflows is accepted as a no-op.
    tryReserveFaces(faces: u64): Status {
        if (faces > u64.MAX_VALUE / 3) return okStatus();
        const numCorners = faces * 3;
        for (let k = 0; k < 2; k++) {
            const vec = k == 0 ? this.cornerToVertexMap : this.oppositeCorners;
            const len = <u64>vec.length;
            const extra = numCorners > len ? numCorners - len : 0;
            if (extra == 0) continue;
            // Reserve `extra` more: capacity for len + extra = numCorners.
            if (numCorners > <u64>CORNER_TABLE_MAX_LEN) return failedToAllocate<bool>();
            // A non-exact reservation may round up: the store grows by
            // amortized doubling.
            const cap = capacityU32(vec);
            if (<i64>numCorners > cap) {
                let target = cap * 2;
                if (target < <i64>numCorners) target = <i64>numCorners;
                if (target > CORNER_TABLE_MAX_LEN) target = CORNER_TABLE_MAX_LEN;
                reserveTotalU32(vec, target);
            }
        }
        return okStatus();
    }

    // Reserves `vertexCorners` for `vertices`, the same way `tryReserveFaces`
    // reserves the other two tables.
    tryReserveVertices(vertices: u64): Status {
        const len = <u64>this.vertexCorners.length;
        const extra = vertices > len ? vertices - len : 0;
        if (extra == 0) return okStatus();
        if (vertices > <u64>CORNER_TABLE_MAX_LEN) return failedToAllocate<bool>();
        const cap = capacityU32(this.vertexCorners);
        if (<i64>vertices > cap) {
            let target = cap * 2;
            if (target < <i64>vertices) target = <i64>vertices;
            if (target > CORNER_TABLE_MAX_LEN) target = CORNER_TABLE_MAX_LEN;
            reserveTotalU32(this.vertexCorners, target);
        }
        return okStatus();
    }

    // Grows the corner storage so `face` and its three corners are
    // addressable. `declaredFaces` (the face count the bitstream claims) is
    // only a growth target, never an allocation.
    tryGrowToFace(face: u64, declaredFaces: u64): Status {
        if (face == u64.MAX_VALUE) return sizeOverflow<bool>();
        const faces = face + 1;
        if (faces > u64.MAX_VALUE / 3) return sizeOverflow<bool>();
        const numCorners = faces * 3;
        if (numCorners <= <u64>this.cornerToVertexMap.length) return okStatus();
        return this.tryGrowToCorners(numCorners, declaredFaces);
    }

    // Appends one face, for a caller that builds them strictly in order.
    tryPushFace(declaredFaces: u64): Status {
        const len = this.cornerToVertexMap.length;
        if (
            this.oppositeCorners.length == len &&
            capacityU32(this.cornerToVertexMap) - <i64>len >= 3 &&
            capacityU32(this.oppositeCorners) - <i64>len >= 3
        ) {
            const m = this.cornerToVertexMap;
            m.push(INVALID_VERTEX_INDEX);
            m.push(INVALID_VERTEX_INDEX);
            m.push(INVALID_VERTEX_INDEX);
            const o = this.oppositeCorners;
            o.push(INVALID_CORNER_INDEX);
            o.push(INVALID_CORNER_INDEX);
            o.push(INVALID_CORNER_INDEX);
            return okStatus();
        }
        const numCorners = <u64>len + 3;
        return this.tryGrowToCorners(numCorners, declaredFaces);
    }

    // The growth policy both entry points share: reserve by doubling capped
    // at the declared total, then fill the new corners.
    private tryGrowToCorners(numCorners: u64, declaredFaces: u64): Status {
        const declaredCorners: u64 = declaredFaces > u64.MAX_VALUE / 3 ? u64.MAX_VALUE : declaredFaces * 3;
        const nc: i64 = numCorners > <u64>i64.MAX_VALUE ? i64.MAX_VALUE : <i64>numCorners;
        const dc: i64 = declaredCorners > <u64>i64.MAX_VALUE ? i64.MAX_VALUE : <i64>declaredCorners;
        const s = growMap(this.cornerToVertexMap, nc, dc, INVALID_VERTEX_INDEX);
        if (!s.ok) return s;
        return growMap(this.oppositeCorners, nc, dc, INVALID_CORNER_INDEX);
    }

    mapCornerToVertex(corner: CornerIndex, vertex: VertexIndex): void {
        setU32At(this.cornerToVertexMap, corner, vertex);
    }

    setFaceVertices(face: FaceIndex, v0: PointIndex, v1: PointIndex, v2: PointIndex): void {
        const c0 = this.firstCorner(face);
        const c1 = this.next(c0);
        const c2 = this.previous(c0);

        this.mapCornerToVertex(c0, v0);
        this.mapCornerToVertex(c1, v1);
        this.mapCornerToVertex(c2, v2);

        // Ensure vertex_corners is large enough and set deterministically.
        let maxV: u32 = v1 > v2 ? v1 : v2;
        if (v0 > maxV) maxV = v0;
        if (<u32>this.vertexCorners.length <= maxV) {
            if (<i64>maxV + 1 > CORNER_TABLE_MAX_LEN) panic("capacity overflow");
            resizeU32Array(this.vertexCorners, <i32>maxV + 1, INVALID_CORNER_INDEX);
        }
        setU32At(this.vertexCorners, v0, c0);
        setU32At(this.vertexCorners, v1, c1);
        setU32At(this.vertexCorners, v2, c2);
    }

    setOpposite(corner: CornerIndex, opposite: CornerIndex): void {
        setU32At(this.oppositeCorners, corner, opposite);
    }

    // Writes `opposite` at `corner`, answering whether the corner was on the
    // table rather than panicking.
    trySetOpposite(corner: CornerIndex, opposite: CornerIndex): bool {
        const o = this.oppositeCorners;
        if (corner >= <u32>o.length) return false;
        unchecked((o[<i32>corner] = opposite));
        return true;
    }

    // `faces` is the face array read as one flat run (3 vertices per face).
    init(faces: Array<u32>): bool {
        return this.initInner(faces, null);
    }

    // `init`, with each stage's wall time (microseconds) written to `stages`
    // (length INIT_STAGE_COUNT) in the order InitStage gives.
    initWithStageTimings(faces: Array<u32>, stages: StaticArray<f64>): bool {
        return this.initInner(faces, stages);
    }

    private initInner(faces: Array<u32>, stages: StaticArray<f64>?): bool {
        // Corner `3f + i` is face `f`'s vertex `i`: the map is the flat face run.
        this.cornerToVertexMap = faces.slice(0);

        // Every clock read sits behind `stages`.
        let started: f64 = stages != null ? clock() : NaN;

        const numVertices = this.computeOppositeCorners();
        if (numVertices < 0) return false;
        started = markStage(stages, InitStage.OppositeCorners, started);

        if (!this.breakNonManifoldEdges(numVertices)) return false;
        started = markStage(stages, InitStage.BreakNonManifoldEdges, started);

        if (!this.computeVertexCorners(numVertices)) return false;
        started = markStage(stages, InitStage.VertexCorners, started);

        // num_degenerated_faces is counted inside computeOppositeCorners,
        // against the pre-split vertex map, matching where C++ counts it.

        this.numIsolatedVertices_ = 0;
        const vc = this.vertexCorners;
        const nv = this.numVertices();
        for (let v = 0; v < nv; v++) {
            if (unchecked(vc[v]) == INVALID_CORNER_INDEX) this.numIsolatedVertices_ += 1;
        }

        // debug_assert!(self.validate_invariants()) is a debug-build check only.
        return true;
    }

    numVertices(): i32 {
        return this.vertexCorners.length;
    }

    numIsolatedVertices(): i32 {
        return this.numIsolatedVertices_;
    }

    numDegeneratedFaces(): i32 {
        return this.numDegeneratedFaces_;
    }

    // Whether a face has two corners on the same vertex. A face past the end
    // (including the invalid face) counts as degenerated.
    isDegenerated(face: FaceIndex): bool {
        const m = this.cornerToVertexMap;
        const chunks = <u32>(m.length / 3);
        if (face >= chunks) return true;
        const base = <i32>(face * 3);
        const v0 = unchecked(m[base]);
        const v1 = unchecked(m[base + 1]);
        const v2 = unchecked(m[base + 2]);
        return v0 == v1 || v0 == v2 || v1 == v2;
    }

    numCorners(): i32 {
        return this.cornerToVertexMap.length;
    }

    // Validates that every vertex index is INVALID or < numVertices, every
    // opposite-corner index INVALID or < numCorners, and that the opposite
    // map matches the corner count.
    isIndexConsistent(): bool {
        if (this.oppositeCorners.length != this.cornerToVertexMap.length) return false;
        const numVertices = this.vertexCorners.length;
        const numCorners = this.cornerToVertexMap.length;
        if (exceeds(this.cornerToVertexMap, <i64>numVertices)) return false;
        if (exceeds(this.oppositeCorners, <i64>numCorners)) return false;
        return true;
    }

    numFaces(): i32 {
        return this.cornerToVertexMap.length / 3;
    }

    addNewVertex(): VertexIndex {
        const newIdx = this.vertexCorners.length;
        this.vertexCorners.push(INVALID_CORNER_INDEX);
        return <u32>newIdx;
    }

    leftMostCorner(v: VertexIndex): CornerIndex {
        const vc = this.vertexCorners;
        if (v < <u32>vc.length) return unchecked(vc[<i32>v]);
        return INVALID_CORNER_INDEX;
    }

    setLeftMostCorner(v: VertexIndex, c: CornerIndex): void {
        const vc = this.vertexCorners;
        if (v >= <u32>vc.length) {
            if (<i64>v + 1 > CORNER_TABLE_MAX_LEN) panic("capacity overflow");
            resizeU32Array(vc, <i32>v + 1, INVALID_CORNER_INDEX);
        }
        unchecked((vc[<i32>v] = c));
    }

    makeVertexIsolated(v: VertexIndex): void {
        const vc = this.vertexCorners;
        if (v < <u32>vc.length) unchecked((vc[<i32>v] = INVALID_CORNER_INDEX));
    }

    // The corner across the edge from `corner`, or the sentinel (also for a
    // corner past the table).
    oppositeInternal(corner: CornerIndex): CornerIndex {
        const o = this.oppositeCorners;
        if (corner < <u32>o.length) return unchecked(o[<i32>corner]);
        return INVALID_CORNER_INDEX;
    }

    // The corner across the edge from `corner`, or the invalid sentinel.
    opposite(corner: CornerIndex): CornerIndex {
        const o = this.oppositeCorners;
        if (corner < <u32>o.length) return unchecked(o[<i32>corner]);
        return INVALID_CORNER_INDEX;
    }

    // The next corner within the same face.
    next(corner: CornerIndex): CornerIndex {
        if (corner == INVALID_CORNER_INDEX) return corner;
        return nextInFace(corner);
    }

    // The previous corner within the same face.
    previous(corner: CornerIndex): CornerIndex {
        if (corner == INVALID_CORNER_INDEX) return corner;
        return prevInFace(corner);
    }

    // The vertex at `corner`, or the invalid sentinel.
    vertex(corner: CornerIndex): VertexIndex {
        const m = this.cornerToVertexMap;
        if (corner < <u32>m.length) return unchecked(m[<i32>corner]);
        return INVALID_VERTEX_INDEX;
    }

    // `vertex(next(corner))` in one lookup.
    vertexAfter(corner: CornerIndex): VertexIndex {
        const m = this.cornerToVertexMap;
        const c = nextInFace(corner);
        if (c < <u32>m.length) return unchecked(m[<i32>c]);
        return INVALID_VERTEX_INDEX;
    }

    // `vertex(previous(corner))` in one lookup.
    vertexBefore(corner: CornerIndex): VertexIndex {
        const m = this.cornerToVertexMap;
        const c = prevInFace(corner);
        if (c < <u32>m.length) return unchecked(m[<i32>c]);
        return INVALID_VERTEX_INDEX;
    }

    face(corner: CornerIndex): FaceIndex {
        if (corner == INVALID_CORNER_INDEX) return INVALID_FACE_INDEX;
        return corner / 3;
    }

    firstCorner(face: FaceIndex): CornerIndex {
        return face * 3;
    }

    // Validates that every opposite corner pair corresponds to the same
    // undirected edge.
    validateOppositeEdgeConsistency(): bool {
        const n = this.numCorners();
        for (let cIdx = 0; cIdx < n; cIdx++) {
            const c = <u32>cIdx;
            const opp = this.oppositeInternal(c);
            if (opp == INVALID_CORNER_INDEX) continue;
            const a = this.vertexAfter(c);
            const b = this.vertexBefore(c);
            const oa = this.vertexAfter(opp);
            const ob = this.vertexBefore(opp);
            if (!((a == oa && b == ob) || (a == ob && b == oa))) return false;
        }
        return true;
    }

    // The corner on the left-adjacent face. C++: Opposite(Previous(corner)).
    leftCorner(corner: CornerIndex): CornerIndex {
        const o = this.oppositeCorners;
        const c = prevInFace(corner);
        if (c < <u32>o.length) return unchecked(o[<i32>c]);
        return INVALID_CORNER_INDEX;
    }

    // The corner on the right-adjacent face. C++: Opposite(Next(corner)).
    rightCorner(corner: CornerIndex): CornerIndex {
        const o = this.oppositeCorners;
        const c = nextInFace(corner);
        if (c < <u32>o.length) return unchecked(o[<i32>c]);
        return INVALID_CORNER_INDEX;
    }

    // C++: Previous(Opposite(Previous(corner))).
    swingRight(corner: CornerIndex): CornerIndex {
        const o = this.oppositeCorners;
        const c = prevInFace(corner);
        const opposite = c < <u32>o.length ? unchecked(o[<i32>c]) : INVALID_CORNER_INDEX;
        return prevInFace(opposite);
    }

    // C++: Next(Opposite(Next(corner))).
    swingLeft(corner: CornerIndex): CornerIndex {
        const o = this.oppositeCorners;
        const c = nextInFace(corner);
        const opposite = c < <u32>o.length ? unchecked(o[<i32>c]) : INVALID_CORNER_INDEX;
        if (opposite == INVALID_CORNER_INDEX) return INVALID_CORNER_INDEX;
        return nextInFace(opposite);
    }

    // Whether the fan around `v` fails to close: an isolated vertex, or one
    // whose left-most corner cannot swing left.
    isVertexOnBoundary(v: VertexIndex): bool {
        const corner = this.leftMostCorner(v);
        return corner == INVALID_CORNER_INDEX || this.swingLeft(corner) == INVALID_CORNER_INDEX;
    }

    // Detects and breaks non-manifold edges caused by folds in the 1-ring
    // around a vertex (public for the tests).
    breakNonManifoldEdges(numVertices: i32): bool {
        const numCorners = this.numCorners();
        const visitedCorners = new Uint8Array(numCorners);

        // The edges seen so far around the current pivot, keyed by sink vertex:
        // the first two corners recorded per key, stamped with the walk.
        const leftWalk = new Array<u32>();
        const invalidSlot = numVertices;
        const slotStamp = new StaticArray<u64>(numVertices + 1);
        const slotC0 = new Uint32Array(numVertices + 1);
        const slotC1 = new Uint32Array(numVertices + 1);
        const slotLen = new Uint8Array(numVertices + 1);
        slotC0.fill(INVALID_CORNER_INDEX);
        slotC1.fill(INVALID_CORNER_INDEX);
        let walk: u64 = 0;

        const map = this.cornerToVertexMap;
        const opp = this.oppositeCorners;

        while (true) {
            let meshConnectivityUpdated = false;
            for (let c = 0; c < this.numCorners(); c++) {
                const cIdx = <u32>c;
                if (visitedCorners[c] != 0) continue;

                walk += 1;

                // First swing all the way to find the left-most corner connected
                // to the corner's vertex, recording the walk for the replay.
                let firstC = cIdx;
                let currentC = cIdx;
                leftWalk.length = 0;
                leftWalk.push(cIdx);

                while (true) {
                    const nextC = this.swingLeft(currentC);
                    if (nextC == firstC || nextC == INVALID_CORNER_INDEX || visitedCorners[<i32>nextC] != 0) {
                        break;
                    }
                    currentC = nextC;
                    leftWalk.push(nextC);
                }

                firstC = currentC;
                // Consumed from the end.
                let replay = leftWalk.length;

                // Swing right from the first corner and check if all visited
                // edges are unique.
                while (true) {
                    visitedCorners[<i32>currentC] = 1;

                    // Each new edge is defined by the pivot vertex and the sink
                    // vertex (the |next| vertex from the current pivot corner).
                    const sinkC = this.next(currentC);
                    const sinkV = getU32At(map, sinkC);

                    // Corner that defines the edge on the face.
                    const edgeCorner = this.previous(currentC);

                    const s = sinkV == INVALID_VERTEX_INDEX ? invalidSlot : <i32>sinkV;
                    if (<u32>s >= <u32>(numVertices + 1)) panic("index out of bounds: the len is " + (numVertices + 1).toString() + " but the index is " + sinkV.toString());
                    let oppEdgeCorner = INVALID_CORNER_INDEX;
                    let hasOther = false;
                    let otherEdgeCorner: u32 = INVALID_CORNER_INDEX;
                    if (unchecked(slotStamp[s]) == walk) {
                        oppEdgeCorner = this.oppositeInternal(edgeCorner);
                        if (slotC0[s] != oppEdgeCorner) {
                            hasOther = true;
                            otherEdgeCorner = slotC0[s];
                        } else if (slotLen[s] > 1) {
                            hasOther = true;
                            otherEdgeCorner = slotC1[s];
                        }
                    }

                    if (hasOther) {
                        // A non-manifold edge: break the connectivity on it.
                        const oppOtherEdgeCorner = this.oppositeInternal(otherEdgeCorner);
                        if (oppEdgeCorner != INVALID_CORNER_INDEX) setU32At(opp, oppEdgeCorner, INVALID_CORNER_INDEX);
                        if (oppOtherEdgeCorner != INVALID_CORNER_INDEX) setU32At(opp, oppOtherEdgeCorner, INVALID_CORNER_INDEX);
                        setU32At(opp, edgeCorner, INVALID_CORNER_INDEX);
                        setU32At(opp, otherEdgeCorner, INVALID_CORNER_INDEX);

                        // Not all corners connected to this vertex have been
                        // processed: sweep again.
                        meshConnectivityUpdated = true;
                        break;
                    }

                    // Insert new sink vertex information <sink vertex, edge corner>.
                    const key = getU32At(map, edgeCorner);
                    const k = key == INVALID_VERTEX_INDEX ? invalidSlot : <i32>key;
                    if (<u32>k >= <u32>(numVertices + 1)) panic("index out of bounds: the len is " + (numVertices + 1).toString() + " but the index is " + key.toString());
                    if (unchecked(slotStamp[k]) != walk) {
                        unchecked((slotStamp[k] = walk));
                        slotLen[k] = 0;
                    }
                    if (slotLen[k] < 2) {
                        if (slotLen[k] == 0) slotC0[k] = sinkC;
                        else slotC1[k] = sinkC;
                        slotLen[k] = slotLen[k] + 1;
                    }

                    if (replay > 1) {
                        replay -= 1;
                        currentC = unchecked(leftWalk[replay - 1]);
                    } else {
                        replay = 0;
                        currentC = this.swingRight(currentC);
                        if (currentC == firstC || currentC == INVALID_CORNER_INDEX) break;
                    }
                }
            }

            if (!meshConnectivityUpdated) break;
        }

        return true;
    }

    // Computes the opposite corners and returns the vertex count, or -1 on
    // failure (never returned in practice). Public for the tests.
    computeOppositeCorners(): i32 {
        this.numDegeneratedFaces_ = 0;
        resizeU32Array(this.oppositeCorners, this.numCorners(), INVALID_CORNER_INDEX);

        const map = this.cornerToVertexMap;
        const numCorners = map.length;

        // 1. Count outgoing half-edges per vertex. The invalid vertex wraps
        // to zero under `+ 1`, so it never wins the maximum.
        let seen: u32 = 0;
        for (let i = 0; i < numCorners; i++) {
            const v = unchecked(map[i]) + 1;
            if (v > seen) seen = v;
        }
        if (<i64>seen > CORNER_TABLE_MAX_LEN) {
            // The per-vertex scratch takes 8 bytes per vertex.
            panic("memory allocation of " + (<u64>seen * 8).toString() + " bytes failed");
        }
        const numVerticesSeen = <i32>seen;

        const numCornersOnVertices = new Int32Array(numVerticesSeen);
        for (let i = 0; i < numCorners; i++) {
            const v1 = unchecked(map[i]);
            if (v1 == INVALID_VERTEX_INDEX) continue;
            numCornersOnVertices[<i32>v1] += 1;
        }

        // 2. Storage for half-edges (sink vertex, edge corner).
        const edgeSink = new Uint32Array(numCorners);
        const edgeCorner = new Uint32Array(numCorners);
        edgeSink.fill(INVALID_VERTEX_INDEX);
        edgeCorner.fill(INVALID_CORNER_INDEX);

        // 3. Offsets.
        const vertexOffset = new Int32Array(numVerticesSeen);
        let offset = 0;
        for (let i = 0; i < numVerticesSeen; i++) {
            vertexOffset[i] = offset;
            offset += numCornersOnVertices[i];
        }

        // 4. Connect half-edges, a face at a time (whole faces only).
        const opp = this.oppositeCorners;
        const numFaces = numCorners / 3;
        for (let f = 0; f < numFaces; f++) {
            const faceBase = f * 3;
            const f0 = unchecked(map[faceBase]);
            const f1 = unchecked(map[faceBase + 1]);
            const f2 = unchecked(map[faceBase + 2]);
            // A face with any repeated vertex is degenerated.
            if (f0 == f1 || f1 == f2 || f2 == f0) {
                this.numDegeneratedFaces_ += 1;
                continue;
            }
            for (let local = 0; local < 3; local++) {
                const c = faceBase + local;
                const cIdx = <u32>c;
                // NEXT_LOCAL = [1, 2, 0], PREV_LOCAL = [2, 0, 1]
                const tipV = local == 0 ? f0 : local == 1 ? f1 : f2;
                const sourceV = local == 0 ? f1 : local == 1 ? f2 : f0;
                const sinkV = local == 0 ? f2 : local == 1 ? f0 : f1;

                const sinkStart = vertexOffset[<i32>sinkV];
                const sinkEnd = sinkStart + numCornersOnVertices[<i32>sinkV];

                // Search for the matching half-edge on the sink vertex, taking
                // the first match, as C++ does.
                let matchPos = -1;
                for (let i = sinkStart; i < sinkEnd; i++) {
                    const es = edgeSink[i];
                    if (es == INVALID_VERTEX_INDEX) break; // No matching half-edge.
                    if (es == sourceV) {
                        if (tipV == this.vertex(edgeCorner[i])) continue; // Don't connect mirrored faces.
                        matchPos = i;
                        break;
                    }
                }

                if (matchPos < 0) {
                    // No opposite corner found; insert this half-edge into the
                    // first free slot on the source vertex.
                    const sourceStart = vertexOffset[<i32>sourceV];
                    const sourceEnd = sourceStart + numCornersOnVertices[<i32>sourceV];
                    for (let i = sourceStart; i < sourceEnd; i++) {
                        if (edgeSink[i] == INVALID_VERTEX_INDEX) {
                            edgeSink[i] = sinkV;
                            edgeCorner[i] = cIdx;
                            break;
                        }
                    }
                    continue;
                }

                const oppositeC = edgeCorner[matchPos];

                // Remove the matched half-edge by shifting the entries after it
                // one slot down, stopping at the first unused one.
                let last = matchPos;
                for (let j = matchPos + 1; j < sinkEnd; j++) {
                    if (edgeSink[j] == INVALID_VERTEX_INDEX) break;
                    edgeSink[last] = edgeSink[j];
                    edgeCorner[last] = edgeCorner[j];
                    last = j;
                }
                edgeSink[last] = INVALID_VERTEX_INDEX;
                edgeCorner[last] = INVALID_CORNER_INDEX;

                setU32At(opp, cIdx, oppositeC);
                setU32At(opp, oppositeC, cIdx);
            }
        }

        return numVerticesSeen;
    }

    // The list-scanning form of `breakNonManifoldEdges`, kept for the tests
    // as a reference to check the indexed one against.
    breakNonManifoldEdgesByList(): void {
        const visitedCorners = new Uint8Array(this.numCorners());
        const sinkV_: Array<u32> = [];
        const sinkC_: Array<u32> = [];
        const map = this.cornerToVertexMap;
        const opp = this.oppositeCorners;

        while (true) {
            let meshConnectivityUpdated = false;
            for (let c = 0; c < this.numCorners(); c++) {
                const cIdx = <u32>c;
                if (visitedCorners[c] != 0) continue;
                sinkV_.length = 0;
                sinkC_.length = 0;

                let firstC = cIdx;
                let currentC = cIdx;
                while (true) {
                    const nextC = this.swingLeft(currentC);
                    if (nextC == firstC || nextC == INVALID_CORNER_INDEX || visitedCorners[<i32>nextC] != 0) break;
                    currentC = nextC;
                }
                firstC = currentC;

                while (true) {
                    visitedCorners[<i32>currentC] = 1;
                    const sinkC = this.next(currentC);
                    const sinkV = getU32At(map, sinkC);
                    const edgeCorner = this.previous(currentC);
                    let vertexConnectivityUpdated = false;

                    for (let a = 0; a < sinkV_.length; a++) {
                        if (unchecked(sinkV_[a]) == sinkV) {
                            const otherEdgeCorner = unchecked(sinkC_[a]);
                            const oppEdgeCorner = this.oppositeInternal(edgeCorner);
                            if (oppEdgeCorner == otherEdgeCorner) continue;
                            const oppOtherEdgeCorner = this.oppositeInternal(otherEdgeCorner);
                            if (oppEdgeCorner != INVALID_CORNER_INDEX) setU32At(opp, oppEdgeCorner, INVALID_CORNER_INDEX);
                            if (oppOtherEdgeCorner != INVALID_CORNER_INDEX) setU32At(opp, oppOtherEdgeCorner, INVALID_CORNER_INDEX);
                            setU32At(opp, edgeCorner, INVALID_CORNER_INDEX);
                            setU32At(opp, otherEdgeCorner, INVALID_CORNER_INDEX);
                            vertexConnectivityUpdated = true;
                            break;
                        }
                    }

                    if (vertexConnectivityUpdated) {
                        meshConnectivityUpdated = true;
                        break;
                    }

                    sinkV_.push(getU32At(map, this.previous(currentC)));
                    sinkC_.push(sinkC);

                    currentC = this.swingRight(currentC);
                    if (currentC == firstC || currentC == INVALID_CORNER_INDEX) break;
                }
            }

            if (!meshConnectivityUpdated) break;
        }
    }

    computeVertexCorners(numVertices: i32): bool {
        this.numOriginalVertices = numVertices;
        resizeU32Array(this.vertexCorners, numVertices, INVALID_CORNER_INDEX);

        // Arrays for marking visited vertices and corners that allow us to
        // detect non-manifold vertices.
        const visitedVertices = new Array<bool>(numVertices);
        const visitedCorners = new Uint8Array(this.numCorners());
        const map = this.cornerToVertexMap;
        const vc = this.vertexCorners;

        const numFaces = this.numFaces();
        for (let f = 0; f < numFaces; f++) {
            const firstFaceCorner = this.firstCorner(<u32>f);

            // Check whether the face is degenerated. If so ignore it.
            if (this.isDegenerated(<u32>f)) continue;

            for (let k: u32 = 0; k < 3; k++) {
                const c = firstFaceCorner + k;
                if (visitedCorners[<i32>c] != 0) continue;

                let v = getU32At(map, c);

                // One vertex maps to many corners; if the vertex was already
                // visited on another corner, create a new vertex (non-manifold).
                let isNonManifoldVertex = false;
                if (<u32>visitedVertices.length <= v) {
                    // Defensive: grow visited_vertices if the table had a larger index.
                    // `visitedVertices` and `vc` always have the same length here,
                    // so `v` is past `vc` too and the write
                    // `vertexCorners[v] = actC` below panics. A `v` too large
                    // to back an array gets that same panic without the resize.
                    if (<i64>v + 1 > CORNER_TABLE_MAX_LEN) {
                        panic("index out of bounds: the len is " + vc.length.toString() + " but the index is " + v.toString());
                    }
                    visitedVertices.length = <i32>v + 1;
                }
                if (visitedVertices[<i32>v]) {
                    vc.push(INVALID_CORNER_INDEX);
                    visitedVertices.push(false);
                    v = <u32>numVertices;
                    numVertices += 1;
                    isNonManifoldVertex = true;
                }

                // Mark the vertex as visited.
                visitedVertices[<i32>v] = true;

                // First swing all the way to the left and mark all corners on
                // the way; the vertex ends up on the left-most corner.
                let actC = c;
                while (actC != INVALID_CORNER_INDEX) {
                    visitedCorners[<i32>actC] = 1;
                    setU32At(vc, v, actC);
                    if (isNonManifoldVertex) {
                        // Update vertex index in the corresponding face.
                        setU32At(map, actC, v);
                    }
                    actC = this.swingLeft(actC);
                    if (actC == c) break; // Full circle reached.
                }

                if (actC == INVALID_CORNER_INDEX) {
                    // Open boundary: swing right from the initial corner to mark
                    // all corners in the opposite direction.
                    actC = this.swingRight(c);
                    while (actC != INVALID_CORNER_INDEX) {
                        visitedCorners[<i32>actC] = 1;
                        if (isNonManifoldVertex) setU32At(map, actC, v);
                        actC = this.swingRight(actC);
                    }
                }
            }
        }

        // Count the number of isolated (unprocessed) vertices.
        this.numIsolatedVertices_ = 0;
        for (let i = 0; i < visitedVertices.length; i++) {
            if (!unchecked(visitedVertices[i])) this.numIsolatedVertices_ += 1;
        }

        return true;
    }

    // Validates basic corner-table invariants. Returns true if all checks pass.
    validateInvariants(): bool {
        // Opposite corner symmetry: opposite(opposite(c)) == c or INVALID.
        const n = this.numCorners();
        for (let c = 0; c < n; c++) {
            const ci = <u32>c;
            const o = this.oppositeInternal(ci);
            if (o != INVALID_CORNER_INDEX && this.oppositeInternal(o) != ci) return false;
        }

        // Non-degenerated faces must have valid vertex mappings.
        const nf = this.numFaces();
        for (let f = 0; f < nf; f++) {
            const face = <u32>f;
            if (this.isDegenerated(face)) continue;
            const c0 = this.firstCorner(face);
            if (
                this.vertex(c0) == INVALID_VERTEX_INDEX ||
                this.vertexAfter(c0) == INVALID_VERTEX_INDEX ||
                this.vertexBefore(c0) == INVALID_VERTEX_INDEX
            ) {
                return false;
            }
        }

        // vertex_corners must reference the expected vertex.
        const vc = this.vertexCorners;
        for (let v = 0; v < vc.length; v++) {
            const c = unchecked(vc[v]);
            if (c == INVALID_CORNER_INDEX) continue;
            if (this.vertex(c) != <u32>v) return false;
        }

        return true;
    }

    valence(v: VertexIndex): i32 {
        let valence = 0;
        const startCorner = this.leftMostCorner(v);
        if (startCorner == INVALID_CORNER_INDEX) return 0;
        let actC = startCorner;
        while (true) {
            valence += 1;
            actC = this.swingRight(actC);
            if (actC == startCorner) break;
            if (actC == INVALID_CORNER_INDEX) {
                // On a boundary: one extra edge.
                valence += 1;
                break;
            }
        }
        return valence;
    }
}

// The `mark` closure of `init_inner`: writes the elapsed microseconds since
// `started` into `stages[stage]` and returns the new start.
function markStage(stages: StaticArray<f64>?, stage: InitStage, started: f64): f64 {
    if (stages == null) return started;
    const now = clock();
    if (!isNaN(started)) stages[<i32>stage] = (now - started) * 1e6;
    return now;
}
