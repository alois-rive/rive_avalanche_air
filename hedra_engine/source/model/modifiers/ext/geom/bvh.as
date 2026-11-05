// A bounding-volume hierarchy over triangles.
//
// Every tool here that asks a spatial question — shrinkwrap's nearest
// surface point, the boolean solver's "is this inside?" ray cast, remesh's
// voxel sampling — would otherwise be O(faces) per query and quadratic
// overall. The tree is built once per mesh and queried per vertex.
//
// Built by median split on the widest axis, which needs no heuristics and
// is deterministic: the same mesh gives the same tree on every platform,
// which is what the golden tests rely on.

import { Vec3, VEC3_ZERO } from "../../../../../base/vecmath";
import { minF32, maxF32, stableSort, partialCmpF32 } from "../../../../../base/util";
import { Tri, closestPointOnTri, rayTri } from "./tri";

// Triangles per leaf. Small enough that a leaf scan is short, large enough
// that the tree stays shallow on a million-triangle mesh.
const LEAF_SIZE: u32 = 8;

class Node {
    min: Vec3 = Vec3(0, 0, 0);
    max: Vec3 = Vec3(0, 0, 0);
    // Range into `Bvh.order` for a leaf (`isLeaf`).
    isLeaf: bool = true;
    lo: u32 = 0;
    hi: u32 = 0;
    // Children, for an inner node.
    kid0: u32 = 0;
    kid1: u32 = 0;
}

// What a nearest-point query found.
export class Nearest {
    point: Vec3 = Vec3(0, 0, 0);
    // Squared distance, so callers that only compare need no square root.
    distSq: f32 = 0;
    // The `Tri.src` of the triangle it landed on.
    src: u32 = 0;
    // Index into `Bvh.tris()`.
    tri: i32 = 0;

    clone(): Nearest {
        const n = new Nearest();
        n.point = this.point;
        n.distSq = this.distSq;
        n.src = this.src;
        n.tri = this.tri;
        return n;
    }
}

// A `raycast` hit: the distance and the triangle.
export class RayHit {
    dist: f32 = 0;
    tri: i32 = 0;
    constructor(dist: f32, tri: i32) {
        this.dist = dist;
        this.tri = tri;
    }
}

// Mutable query state, shared with the recursive walks.
class NearestBest {
    best: Nearest? = null;
}
class RayBest {
    best: RayHit? = null;
}

// Sort key context for the build (the comparator closure must not capture
// mutable locals).
class SortCtx {
    tris: Array<Tri> = [];
    axis: i32 = 0;
}

export class Bvh {
    private _tris: Array<Tri> = [];
    // Triangle indices, permuted so every leaf is a contiguous run.
    order: Array<u32> = [];
    private nodes: Array<Node> = [];

    // Build over `tris`. An empty set is allowed; every query then answers
    // `null`, which is what a shrinkwrap onto an empty target needs.
    static build(tris: Array<Tri>): Bvh {
        const bvh = new Bvh();
        const n = tris.length;
        for (let i = 0; i < n; i++) bvh.order.push(<u32>i);
        bvh._tris = tris;
        if (n > 0) {
            bvh.buildNode(0, <u32>n);
        }
        return bvh;
    }

    isEmpty(): bool {
        return this._tris.length == 0;
    }

    tris(): Array<Tri> {
        return this._tris;
    }

    // Build the node covering `order[lo..hi]` and return its index.
    private buildNode(lo: u32, hi: u32): u32 {
        let min = Vec3.splat(Infinity);
        let max = Vec3.splat(-Infinity);
        for (let k = lo; k < hi; k++) {
            const t = this._tris[<i32>this.order[<i32>k]];
            min = min.min(t.min());
            max = max.max(t.max());
        }
        const id = <u32>this.nodes.length;
        const node = new Node();
        node.min = min;
        node.max = max;
        node.isLeaf = true;
        node.lo = lo;
        node.hi = hi;
        this.nodes.push(node);
        if (hi - lo <= LEAF_SIZE) {
            return id;
        }
        // Median split on the widest axis. Sorting on the centre coordinate
        // with the triangle index as the tie-break keeps the permutation
        // deterministic even when centres coincide.
        const extent = max - min;
        let axis = 0;
        if (extent.x >= extent.y && extent.x >= extent.z) {
            axis = 0;
        } else if (extent.y >= extent.z) {
            axis = 1;
        } else {
            axis = 2;
        }
        const slice = this.order.slice(<i32>lo, <i32>hi);
        const ctx = new SortCtx();
        ctx.tris = this._tris;
        ctx.axis = axis;
        stableSort<u32>(slice, (a: u32, b: u32): i32 => {
            const ca = ctx.tris[<i32>a].center().get(ctx.axis);
            const cb = ctx.tris[<i32>b].center().get(ctx.axis);
            const c = partialCmpF32(ca, cb);
            if (c != 0) return c;
            return a < b ? -1 : a > b ? 1 : 0;
        });
        for (let k = 0; k < slice.length; k++) this.order[<i32>lo + k] = slice[k];
        const mid = lo + (hi - lo) / 2;
        const left = this.buildNode(lo, mid);
        const right = this.buildNode(mid, hi);
        node.isLeaf = false;
        node.kid0 = left;
        node.kid1 = right;
        return id;
    }

    // The closest point on any triangle, or `null` when the tree is empty.
    nearest(p: Vec3): Nearest? {
        if (this._tris.length == 0) {
            return null;
        }
        const best = new NearestBest();
        this.nearestIn(0, p, best);
        return best.best;
    }

    private nearestIn(node: u32, p: Vec3, best: NearestBest): void {
        const n = this.nodes[<i32>node];
        const b = best.best;
        if (b != null && boxDistSq(p, n.min, n.max) > b.distSq) {
            return;
        }
        if (n.isLeaf) {
            for (let k = n.lo; k < n.hi; k++) {
                const t = this.order[<i32>k];
                const tri = this._tris[<i32>t];
                const q = closestPointOnTri(p, tri);
                const d = (q - p).lengthSquared();
                const cur = best.best;
                if (cur == null || d < cur.distSq) {
                    const nb = new Nearest();
                    nb.point = q;
                    nb.distSq = d;
                    nb.src = tri.src;
                    nb.tri = <i32>t;
                    best.best = nb;
                }
            }
        } else {
            // Nearer child first, so the far one is usually pruned.
            const a = n.kid0;
            const bk = n.kid1;
            const na = this.nodes[<i32>a];
            const nb = this.nodes[<i32>bk];
            const da = boxDistSq(p, na.min, na.max);
            const db = boxDistSq(p, nb.min, nb.max);
            if (da <= db) {
                this.nearestIn(a, p, best);
                this.nearestIn(bk, p, best);
            } else {
                this.nearestIn(bk, p, best);
                this.nearestIn(a, p, best);
            }
        }
    }

    // The nearest hit along `dir` from `origin`, as (distance, triangle).
    raycast(origin: Vec3, dir: Vec3): RayHit? {
        if (this._tris.length == 0) {
            return null;
        }
        const inv = Vec3(<f32>1.0 / dir.x, <f32>1.0 / dir.y, <f32>1.0 / dir.z);
        const best = new RayBest();
        this.rayIn(0, origin, dir, inv, best);
        return best.best;
    }

    private rayIn(node: u32, o: Vec3, d: Vec3, inv: Vec3, best: RayBest): void {
        const n = this.nodes[<i32>node];
        const cur = best.best;
        const limit: f32 = cur != null ? cur.dist : <f32>Infinity;
        if (!rayBox(o, inv, n.min, n.max, limit)) {
            return;
        }
        if (n.isLeaf) {
            for (let k = n.lo; k < n.hi; k++) {
                const t = this.order[<i32>k];
                const dist = rayTri(o, d, this._tris[<i32>t]);
                if (!isNaN(dist)) {
                    const b = best.best;
                    if (b == null || dist < b.dist) {
                        best.best = new RayHit(dist, <i32>t);
                    }
                }
            }
        } else {
            this.rayIn(n.kid0, o, d, inv, best);
            this.rayIn(n.kid1, o, d, inv, best);
        }
    }

    // How many triangles a ray from `origin` along `dir` crosses. Used for
    // the inside test: an odd count means the point is enclosed.
    rayCrossings(origin: Vec3, dir: Vec3): i32 {
        if (this._tris.length == 0) {
            return 0;
        }
        const inv = Vec3(<f32>1.0 / dir.x, <f32>1.0 / dir.y, <f32>1.0 / dir.z);
        const hits: Array<f32> = [];
        this.hitsIn(0, origin, dir, inv, hits);
        // A ray that grazes a shared edge hits both triangles at the same
        // distance and would be counted twice. Collapsing equal distances
        // is the cheap fix, and the caster votes over several directions
        // anyway (see `inside`).
        stableSort<f32>(hits, (a: f32, b: f32): i32 => partialCmpF32(a, b));
        // Drop duplicates: each element is compared with the last one kept.
        let kept = 0;
        for (let i = 0; i < hits.length; i++) {
            if (kept > 0 && Mathf.abs(hits[i] - hits[kept - 1]) < <f32>1e-6) {
                continue;
            }
            hits[kept] = hits[i];
            kept++;
        }
        return kept;
    }

    private hitsIn(node: u32, o: Vec3, d: Vec3, inv: Vec3, out: Array<f32>): void {
        const n = this.nodes[<i32>node];
        if (!rayBox(o, inv, n.min, n.max, <f32>Infinity)) {
            return;
        }
        if (n.isLeaf) {
            for (let k = n.lo; k < n.hi; k++) {
                const t = this.order[<i32>k];
                const dist = rayTri(o, d, this._tris[<i32>t]);
                if (!isNaN(dist)) {
                    out.push(dist);
                }
            }
        } else {
            this.hitsIn(n.kid0, o, d, inv, out);
            this.hitsIn(n.kid1, o, d, inv, out);
        }
    }

    // Is `p` inside the surface? Three rays vote, so a ray that slips
    // through a shared edge or hits a coplanar face cannot decide it alone.
    // Only meaningful for a closed mesh, which is what Blender says about
    // its own boolean too.
    inside(p: Vec3): bool {
        let votes = 0;
        if (this.rayCrossings(p, Vec3(<f32>0.57735, <f32>0.57735, <f32>0.57735)) % 2 == 1) votes++;
        if (this.rayCrossings(p, Vec3(<f32>-0.7021, <f32>0.3129, <f32>0.6394)) % 2 == 1) votes++;
        if (this.rayCrossings(p, Vec3(<f32>0.2713, <f32>-0.8132, <f32>0.5149)) % 2 == 1) votes++;
        return votes >= 2;
    }

    // Every triangle whose box overlaps `min..max`, in leaf order.
    overlapping(min: Vec3, max: Vec3): Array<i32> {
        const out: Array<i32> = [];
        if (this._tris.length > 0) {
            this.overlapIn(0, min, max, out);
        }
        return out;
    }

    private overlapIn(node: u32, min: Vec3, max: Vec3, out: Array<i32>): void {
        const n = this.nodes[<i32>node];
        if (
            n.min.x > max.x ||
            n.max.x < min.x ||
            n.min.y > max.y ||
            n.max.y < min.y ||
            n.min.z > max.z ||
            n.max.z < min.z
        ) {
            return;
        }
        if (n.isLeaf) {
            for (let k = n.lo; k < n.hi; k++) out.push(<i32>this.order[<i32>k]);
        } else {
            this.overlapIn(n.kid0, min, max, out);
            this.overlapIn(n.kid1, min, max, out);
        }
    }
}

function boxDistSq(p: Vec3, min: Vec3, max: Vec3): f32 {
    const d = (min - p).max(VEC3_ZERO).max(p - max);
    return d.lengthSquared();
}

function rayBox(o: Vec3, inv: Vec3, min: Vec3, max: Vec3, limit: f32): bool {
    const t0 = (min - o).mul(inv);
    const t1 = (max - o).mul(inv);
    const lo = t0.min(t1);
    const hi = t0.max(t1);
    const near = maxF32(maxF32(maxF32(lo.x, lo.y), lo.z), 0.0);
    const far = minF32(minF32(minF32(hi.x, hi.y), hi.z), limit);
    return near <= far;
}
