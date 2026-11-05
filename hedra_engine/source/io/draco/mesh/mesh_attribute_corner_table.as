// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Deriving an attribute's own corner table from the position corner table.
//
// An interior seam is a base-connectivity edge where the attribute's value
// differs on its two sides. `cutSeamEdgesAndRecomputeVertices` turns "these
// edges are seams" into "here is the per-attribute corner table, with its own
// vertex ids split at every seam". Both the mesh encoder and decoder call it.
//
// The result pairs the corner table with the seam flags in a `SeamCut`.

import { Result, panic } from "../../../../base/util";
import { DracoError } from "../core/status";
import { CornerTable, setU32At } from "./corner_table";
import {
    CornerIndex,
    INVALID_CORNER_INDEX,
    INVALID_VERTEX_INDEX,
} from "../geometry/geometry_indices";

// The result of `cutSeamEdgesAndRecomputeVertices`: the attribute's corner
// table and, per *base* vertex, whether it sits on a seam.
export class SeamCut {
    ct: CornerTable;
    isVertexOnSeam: Array<bool>;

    constructor(ct: CornerTable, isVertexOnSeam: Array<bool>) {
        this.ct = ct;
        this.isVertexOnSeam = isVertexOnSeam;
    }
}

// `a[i] = v`, panicking out of bounds (a plain AS Array write would grow).
function setBoolAt(a: Array<bool>, i: u32, v: bool): void {
    if (i >= <u32>a.length) {
        panic("index out of bounds: the len is " + a.length.toString() + " but the index is " + i.toString());
    }
    unchecked((a[<i32>i] = v));
}

// `a[i]`, panicking out of bounds.
function getBoolAt(a: Array<bool>, i: u32): bool {
    if (i >= <u32>a.length) {
        panic("index out of bounds: the len is " + a.length.toString() + " but the index is " + i.toString());
    }
    return unchecked(a[<i32>i]);
}

// A seam-aware swing, taken over the *uncut* base table: it walks past a seam
// like any other edge (the `seam_swing_left` closure).
function seamSwingLeft(baseCt: CornerTable, isEdgeOnSeam: Array<bool>, corner: CornerIndex): CornerIndex {
    let opposite = baseCt.next(corner);
    const onSeam = opposite < <u32>isEdgeOnSeam.length ? unchecked(isEdgeOnSeam[<i32>opposite]) : false;
    if (onSeam) {
        opposite = INVALID_CORNER_INDEX;
    } else {
        opposite = baseCt.opposite(opposite);
    }
    return baseCt.next(opposite);
}

// Cuts every marked seam edge out of a clone of `baseCt` and gives each
// resulting fan piece its own vertex id.
//
// `isEdgeOnSeam` is indexed by corner and must mark both sides of a cut edge.
// A malformed seam pattern that made a fan cycle without ever reaching a cut
// is refused rather than looped on forever.
export function cutSeamEdgesAndRecomputeVertices(baseCt: CornerTable, isEdgeOnSeam: Array<bool>): Result<SeamCut> {
    const ct = baseCt.clone();
    const numCorners = baseCt.numCorners();
    for (let cIdx = 0; cIdx < numCorners; cIdx++) {
        if (getBoolAt(isEdgeOnSeam, <u32>cIdx)) ct.setOpposite(<u32>cIdx, INVALID_CORNER_INDEX);
    }

    const isVertexOnSeam = new Array<bool>(baseCt.numVertices());
    for (let cIdx = 0; cIdx < numCorners; cIdx++) {
        if (!getBoolAt(isEdgeOnSeam, <u32>cIdx)) continue;
        const c = <u32>cIdx;
        const nextVertex = baseCt.vertexAfter(c);
        if (nextVertex != INVALID_VERTEX_INDEX) setBoolAt(isVertexOnSeam, nextVertex, true);
        const previousVertex = baseCt.vertexBefore(c);
        if (previousVertex != INVALID_VERTEX_INDEX) setBoolAt(isVertexOnSeam, previousVertex, true);
    }

    ct.cornerToVertexMap.fill(INVALID_VERTEX_INDEX);
    ct.vertexCorners.length = 0;

    const maxSwingSteps: i64 = <i64>numCorners + 1;
    let numNewVertices: u32 = 0;
    const numVertices = baseCt.numVertices();
    for (let v = 0; v < numVertices; v++) {
        const c = baseCt.leftMostCorner(<u32>v);
        if (c == INVALID_CORNER_INDEX) continue;

        let firstVertexId = numNewVertices;
        numNewVertices += 1;

        let firstC = c;
        if (unchecked(isVertexOnSeam[v])) {
            let actC = seamSwingLeft(baseCt, isEdgeOnSeam, firstC);
            let swingSteps: i64 = 0;
            while (actC != INVALID_CORNER_INDEX) {
                swingSteps += 1;
                if (swingSteps > maxSwingSteps) {
                    return DracoError.general("Attribute seam left-swing traversal did not terminate").fail<SeamCut>();
                }
                firstC = actC;
                actC = seamSwingLeft(baseCt, isEdgeOnSeam, actC);
            }
        }

        setU32At(ct.cornerToVertexMap, firstC, firstVertexId);
        ct.vertexCorners.push(firstC);

        let actC = baseCt.swingRight(firstC);
        let swingSteps: i64 = 0;
        while (actC != INVALID_CORNER_INDEX && actC != firstC) {
            swingSteps += 1;
            if (swingSteps > maxSwingSteps) {
                return DracoError.general("Attribute seam right-swing traversal did not terminate").fail<SeamCut>();
            }
            if (getBoolAt(isEdgeOnSeam, baseCt.next(actC))) {
                firstVertexId = numNewVertices;
                numNewVertices += 1;
                ct.vertexCorners.push(actC);
            }
            setU32At(ct.cornerToVertexMap, actC, firstVertexId);
            actC = baseCt.swingRight(actC);
        }
    }

    ct.numOriginalVertices = ct.vertexCorners.length;
    ct.numIsolatedVertices_ = 0;
    ct.numDegeneratedFaces_ = baseCt.numDegeneratedFaces_;

    return Result.okv<SeamCut>(new SeamCut(ct, isVertexOnSeam));
}
