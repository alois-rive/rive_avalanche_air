// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Depth-first traversal of a corner table (Draco's
// `DepthFirstTraverser::TraverseFromCorner`).
//
// The new-vertex callback is a `NewVertexObserver` subclass (state lives in
// its fields). The visited flags are `Array<bool>` (an index past the end
// panics), the corner stack is the caller's scratch `Array<u32>`.

import { panic } from "../../../../base/util";
import { CornerTable } from "./corner_table";
import {
    CornerIndex,
    VertexIndex,
    INVALID_CORNER_INDEX,
    INVALID_FACE_INDEX,
    INVALID_VERTEX_INDEX,
} from "../geometry/geometry_indices";

// What a traversal records per newly visited vertex.
export abstract class NewVertexObserver {
    abstract onNewVertex(vertex: VertexIndex, corner: CornerIndex): void;
}

// Walks the connected component reachable from `startCorner`, marking faces
// and vertices visited and calling `onNewVertex` once per vertex, in
// discovery order, with the corner it was discovered through.
//
// Returns immediately if the start face is invalid or already visited, so a
// caller can drive this over every face in order.
export function traverseFromCorner(
    cornerTable: CornerTable,
    startCorner: CornerIndex,
    cornerStack: Array<u32>,
    visitedFaces: Array<bool>,
    visitedVertices: Array<bool>,
    onNewVertex: NewVertexObserver,
): void {
    const startFace = cornerTable.face(startCorner);
    if (startFace == INVALID_FACE_INDEX || visitedFaces[<i32>startFace]) return;

    cornerStack.length = 0;
    cornerStack.push(startCorner);

    // The first face's other two corners may never be reached by the walk
    // itself, so C++ visits Next and then Previous before the main loop.
    const nextCorner = cornerTable.next(startCorner);
    const prevCorner = cornerTable.previous(startCorner);
    const nextVert = cornerTable.vertex(nextCorner);
    const prevVert = cornerTable.vertex(prevCorner);
    if (nextVert == INVALID_VERTEX_INDEX || prevVert == INVALID_VERTEX_INDEX) return;

    if (!visitedVertices[<i32>nextVert]) {
        visitedVertices[<i32>nextVert] = true;
        onNewVertex.onNewVertex(nextVert, nextCorner);
    }
    if (!visitedVertices[<i32>prevVert]) {
        visitedVertices[<i32>prevVert] = true;
        onNewVertex.onNewVertex(prevVert, prevCorner);
    }

    while (cornerStack.length > 0) {
        let cornerId = cornerStack.pop();
        let faceId = cornerTable.face(cornerId);
        if (cornerId == INVALID_CORNER_INDEX || visitedFaces[<i32>faceId]) continue;

        while (true) {
            // Panic past the end: a plain AS Array write would grow.
            if (faceId >= <u32>visitedFaces.length) {
                panic("index out of bounds: the len is " + visitedFaces.length.toString() + " but the index is " + faceId.toString());
            }
            visitedFaces[<i32>faceId] = true;

            const vertId = cornerTable.vertex(cornerId);
            if (vertId == INVALID_VERTEX_INDEX) break;

            if (!visitedVertices[<i32>vertId]) {
                const onBoundary = cornerTable.isVertexOnBoundary(vertId);
                visitedVertices[<i32>vertId] = true;
                onNewVertex.onNewVertex(vertId, cornerId);

                if (!onBoundary) {
                    cornerId = cornerTable.rightCorner(cornerId);
                    if (cornerId == INVALID_CORNER_INDEX) break;
                    faceId = cornerTable.face(cornerId);
                    continue;
                }
            }

            // The vertex was already visited, or it sits on a boundary: look at
            // the two neighbouring faces instead.
            const rightCornerId = cornerTable.rightCorner(cornerId);
            const leftCornerId = cornerTable.leftCorner(cornerId);

            const rightFaceId = rightCornerId == INVALID_CORNER_INDEX ? INVALID_FACE_INDEX : cornerTable.face(rightCornerId);
            const leftFaceId = leftCornerId == INVALID_CORNER_INDEX ? INVALID_FACE_INDEX : cornerTable.face(leftCornerId);

            const rightVisited = rightFaceId == INVALID_FACE_INDEX || visitedFaces[<i32>rightFaceId];
            const leftVisited = leftFaceId == INVALID_FACE_INDEX || visitedFaces[<i32>leftFaceId];

            if (rightVisited) {
                if (leftVisited) {
                    // Both neighbours are done: this end of the walk is finished.
                    break;
                }
                cornerId = leftCornerId;
                faceId = leftFaceId;
            } else if (leftVisited) {
                cornerId = rightCornerId;
                faceId = rightFaceId;
            } else {
                // Both are unvisited, so the walk splits. The right face is
                // pushed last and therefore taken first.
                cornerStack.push(leftCornerId);
                cornerStack.push(rightCornerId);
                break;
            }
        }
    }
}
