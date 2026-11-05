// What the queries keep of a polygon shape between calls (milestone 31): a
// ConvexPolygonShape3D's hull (hull.as) and a ConcavePolygonShape3D's
// triangles in a BVH (../../render/raycast.as TriBvh, the renderer's own:
// its nearestHit and its box query), made on first use and again only
// when the shape changed (Shape3D.version), kept in Shape3D.prepared.
//
// A query asks for them on every call; the answer is the kept object
// after the first, so a query allocates nothing. Making one allocates
// (the hull's arrays, the tree), once per version of the shape: a handle
// dragged in the editor makes them again per drag step of a polygon
// shape, which the editor does not offer (polygon shapes come from a mesh).

import { TriBvh } from "../../render/raycast";
import { ConcavePolygonShape3D, ConvexPolygonShape3D, ShapePrepared } from "../resource/types";
import { ConvexHull, convexHull } from "./hull";

export class PreparedConvex extends ShapePrepared {
    hull: ConvexHull;

    constructor(hull: ConvexHull) {
        super();
        this.hull = hull;
    }
}

export class PreparedConcave extends ShapePrepared {
    bvh: TriBvh;
    // The triangles' edges, each once (a pair of endpoints, six numbers,
    // whichever way the triangles walk it), for drawing (lines.as): made on
    // first use, null before.
    edges: Array<f64>? = null;

    constructor(bvh: TriBvh) {
        super();
        this.bvh = bvh;
    }
}

// The hull of the shape's points as they are now.
export function convexHullOf(s: ConvexPolygonShape3D): ConvexHull {
    const p = s.prepared;
    if (p != null && p instanceof PreparedConvex && p.version == s.version) return (<PreparedConvex>p).hull;
    const made = new PreparedConvex(convexHull(s.points));
    made.version = s.version;
    s.prepared = made;
    return made.hull;
}

// The kept BVH (and edges) of the shape's triangles as they are now.
export function preparedConcaveOf(s: ConcavePolygonShape3D): PreparedConcave {
    const p = s.prepared;
    if (p != null && p instanceof PreparedConcave && p.version == s.version) return <PreparedConcave>p;
    const n = s.triangleCount() * 9;
    const pos = new Array<f32>(n);
    const data = s.data;
    for (let i = 0; i < n; i++) pos[i] = <f32>data[i];
    const made = new PreparedConcave(TriBvh.fromTrianglesSah(pos));
    made.version = s.version;
    s.prepared = made;
    return made;
}

// The BVH of the shape's triangles as they are now (TriBvh's triangle
// index is the shape's: data / 9).
export function concaveBvhOf(s: ConcavePolygonShape3D): TriBvh {
    return preparedConcaveOf(s).bvh;
}

// The shape's triangles' edges, each once (six numbers an edge: its two
// endpoints, the lower first), in the order the triangles first walk
// them. Two edges are one when their endpoints are the same numbers.
export function concaveEdgesOf(s: ConcavePolygonShape3D): Array<f64> {
    const prep = preparedConcaveOf(s);
    const kept = prep.edges;
    if (kept != null) return kept;
    const edges: Array<f64> = [];
    const seen = new Set<string>();
    const data = s.data;
    const count = s.triangleCount();
    for (let t = 0; t < count; t++) {
        for (let e = 0; e < 3; e++) {
            let a = t * 9 + e * 3;
            let b = t * 9 + ((e + 1) % 3) * 3;
            if (pointBefore(data, b, a)) {
                const q = a;
                a = b;
                b = q;
            }
            const key = data[a].toString() + "," + data[a + 1].toString() + "," + data[a + 2].toString() + ";"
                + data[b].toString() + "," + data[b + 1].toString() + "," + data[b + 2].toString();
            if (seen.has(key)) continue;
            seen.add(key);
            for (let k = 0; k < 3; k++) edges.push(data[a + k]);
            for (let k = 0; k < 3; k++) edges.push(data[b + k]);
        }
    }
    prep.edges = edges;
    return edges;
}

// Whether the point at data[i..] comes before the one at data[j..] (x,
// then y, then z).
function pointBefore(data: Array<f64>, i: i32, j: i32): bool {
    for (let k = 0; k < 3; k++) {
        if (data[i + k] < data[j + k]) return true;
        if (data[i + k] > data[j + k]) return false;
    }
    return false;
}
