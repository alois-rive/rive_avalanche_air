// Label occlusion without GPU readback.
//
// A label is hidden when the surface depth at its pixel is in front of the
// (pulled) label anchor. The Rive GPU API has no readback of the id-depth
// buffer, so the renderer casts the label's pixel ray
// against the triangles the CPU already holds (`GpuMesh.verts/indices`),
// through a BVH per mesh built in local space on first use. The caller turns
// the nearest hit into NDC z with its view-projection matrix.
//
// Triangles are two-sided (the pipelines cull nothing) and faces flagged
// F_HIDDEN are skipped (the surface shader discards them). In material mode
// fs_id also discards alpha-mask cutouts: a material that cuts out
// everywhere (`cutsOutEverywhere` in material.as) is left out through
// `GpuMesh.bvhSkipping`, but a per-texel cutout of a textured material is not
// known on the CPU and counts as solid.
//
// Milestone 19 (the lightmap baker, lightmap/baker.as) traces millions of
// rays through one world-space BVH, so the tree also answers without
// allocating: `nearestHit` (the hit's input triangle, barycentrics and
// side) and `anyHit` (an early-out shadow test) walk a traversal stack
// made once with the tree, and `fromTrianglesSah` builds a better tree for
// it (a binned surface-area split). `nearest` and `nearestWorld` and the
// median-split `fromTriangles` are exactly what they were: picking and
// label occlusion keep their answers.

import { Vec3, Mat4 } from "../base/vecmath";
import { SurfaceVertex, F_HIDDEN } from "./gpu/layouts";

const LEAF_SIZE: i32 = 4;

// The binned SAH build's bins along an axis, and the cost of a box test
// against a triangle test (Wald's usual ratio: a node visit costs about
// as much as one triangle).
const SAH_BINS: i32 = 12;
const SAH_TRAVERSAL_COST: f64 = 1.0;

// A ray's nearest hit (`TriBvh.nearestHit`): its parameter, the triangle's
// index in the input of the build, the barycentric weights of its second
// and third corners (the point is (1 - u - v) a + u b + v c), and whether
// the ray met the triangle's back (the side its winding, a b c counter-
// clockwise, does not face). One kept by the caller and filled again.
export class RayHit {
    t: f64 = Infinity;
    tri: i32 = -1;
    u: f64 = 0;
    v: f64 = 0;
    backFace: bool = false;
}

export class TriBvh {
    // Triangle corners, 9 f32 per triangle, in BVH leaf order.
    tris: Float32Array = new Float32Array(0);
    triCount: i32 = 0;
    // Per node: min xyz, max xyz.
    boxes: Float32Array = new Float32Array(0);
    // Per node: for a leaf, the first triangle and -count (count < 0); for an
    // inner node, the left child index and the right child index.
    a: Int32Array = new Int32Array(0);
    b: Int32Array = new Int32Array(0);
    nodeCount: i32 = 0;
    // Leaf position (the triangle's place in `tris`) to the triangle's
    // index in the input of the build.
    triOrder: Int32Array = new Int32Array(0);
    // The traversal stack of nearestHit and anyHit, sized from the tree's
    // depth at build (a depth-first walk holds at most depth + 1 nodes),
    // with each node's entry distance beside it: made once, so a ray
    // allocates nothing.
    private walk: Int32Array = new Int32Array(1);
    private walkT: Float64Array = new Float64Array(1);

    // The visible triangles of a built surface (hidden faces skipped).
    static fromSurface(verts: Array<SurfaceVertex>, indices: Array<u32>, skipFlags: u32 = F_HIDDEN): TriBvh {
        const pos: Array<f32> = [];
        appendTriangles(pos, verts, indices, 0, indices.length, skipFlags);
        return TriBvh.fromTriangles(pos);
    }

    // `pos`: 9 floats per triangle.
    static fromTriangles(pos: Array<f32>): TriBvh {
        const n = pos.length / 9;
        const bvh = new TriBvh();
        bvh.triCount = n;
        const order = new Array<i32>(n);
        const cx = new Float32Array(n);
        const cy = new Float32Array(n);
        const cz = new Float32Array(n);
        for (let i = 0; i < n; i++) {
            order[i] = i;
            const o = i * 9;
            cx[i] = (pos[o] + pos[o + 3] + pos[o + 6]) / 3;
            cy[i] = (pos[o + 1] + pos[o + 4] + pos[o + 7]) / 3;
            cz[i] = (pos[o + 2] + pos[o + 5] + pos[o + 8]) / 3;
        }
        const cap = n > 0 ? 2 * n : 1;
        const boxes = new Float32Array(cap * 6);
        const na = new Int32Array(cap);
        const nb = new Int32Array(cap);
        let nodes = 0;
        // Explicit stack of (node, start, end) over `order`.
        const stack: Array<i32> = [];
        if (n > 0) {
            nodes = 1;
            stack.push(0);
            stack.push(0);
            stack.push(n);
        }
        while (stack.length > 0) {
            const end = stack.pop();
            const start = stack.pop();
            const node = stack.pop();
            // Bounds of the triangles and of their centroids.
            let mnx = Infinity, mny = Infinity, mnz = Infinity, mxx = -Infinity, mxy = -Infinity, mxz = -Infinity;
            let cmnx = Infinity, cmny = Infinity, cmnz = Infinity, cmxx = -Infinity, cmxy = -Infinity, cmxz = -Infinity;
            for (let i = start; i < end; i++) {
                const t = order[i];
                const o = t * 9;
                for (let k = 0; k < 3; k++) {
                    const x = <f64>pos[o + k * 3], y = <f64>pos[o + k * 3 + 1], z = <f64>pos[o + k * 3 + 2];
                    if (x < mnx) mnx = x;
                    if (y < mny) mny = y;
                    if (z < mnz) mnz = z;
                    if (x > mxx) mxx = x;
                    if (y > mxy) mxy = y;
                    if (z > mxz) mxz = z;
                }
                const x = <f64>cx[t], y = <f64>cy[t], z = <f64>cz[t];
                if (x < cmnx) cmnx = x;
                if (y < cmny) cmny = y;
                if (z < cmnz) cmnz = z;
                if (x > cmxx) cmxx = x;
                if (y > cmxy) cmxy = y;
                if (z > cmxz) cmxz = z;
            }
            const bo = node * 6;
            boxes[bo] = <f32>mnx;
            boxes[bo + 1] = <f32>mny;
            boxes[bo + 2] = <f32>mnz;
            boxes[bo + 3] = <f32>mxx;
            boxes[bo + 4] = <f32>mxy;
            boxes[bo + 5] = <f32>mxz;
            const count = end - start;
            const ex = cmxx - cmnx, ey = cmxy - cmny, ez = cmxz - cmnz;
            if (count <= LEAF_SIZE || (ex <= 0 && ey <= 0 && ez <= 0)) {
                na[node] = start;
                nb[node] = -count;
                continue;
            }
            // Median split on the longest centroid axis.
            const axis = ex >= ey && ex >= ez ? 0 : (ey >= ez ? 1 : 2);
            const key = axis == 0 ? cx : (axis == 1 ? cy : cz);
            const part = order.slice(start, end);
            part.sort((p: i32, q: i32): i32 => {
                const kp = key[p], kq = key[q];
                return kp < kq ? -1 : kp > kq ? 1 : p - q;
            });
            for (let i = 0; i < part.length; i++) order[start + i] = part[i];
            const mid = start + (count >> 1);
            const left = nodes;
            const right = nodes + 1;
            nodes += 2;
            na[node] = left;
            nb[node] = right;
            stack.push(right);
            stack.push(mid);
            stack.push(end);
            stack.push(left);
            stack.push(start);
            stack.push(mid);
        }
        // Copy the triangles into leaf order.
        const tris = new Float32Array(n * 9);
        for (let i = 0; i < n; i++) {
            const o = order[i] * 9;
            for (let k = 0; k < 9; k++) tris[i * 9 + k] = pos[o + k];
        }
        bvh.tris = tris;
        bvh.boxes = boxes;
        bvh.a = na;
        bvh.b = nb;
        bvh.nodeCount = nodes;
        const triOrder = new Int32Array(n);
        for (let i = 0; i < n; i++) triOrder[i] = order[i];
        bvh.triOrder = triOrder;
        bvh.makeWalk();
        return bvh;
    }

    // `pos` (9 floats per triangle) in a tree split by the surface area
    // heuristic over SAH_BINS bins of the centroids' longest axis, for many
    // incoherent rays (the lightmap baker's). Leaves of at most LEAF_SIZE
    // triangles, unless a split would cost more than the leaf; the same
    // layout as fromTriangles, so every query reads either. Deterministic:
    // ties go to the lower bin and the lower triangle.
    static fromTrianglesSah(pos: Array<f32>): TriBvh {
        const n = pos.length / 9;
        const bvh = new TriBvh();
        bvh.triCount = n;
        const order = new Int32Array(n);
        const scratch = new Int32Array(n);
        const cx = new Float64Array(n);
        const cy = new Float64Array(n);
        const cz = new Float64Array(n);
        const tb = new Float64Array(n * 6);
        for (let i = 0; i < n; i++) {
            order[i] = i;
            const o = i * 9;
            let mnx = Infinity, mny = Infinity, mnz = Infinity, mxx = -Infinity, mxy = -Infinity, mxz = -Infinity;
            for (let k = 0; k < 3; k++) {
                const x = <f64>pos[o + k * 3], y = <f64>pos[o + k * 3 + 1], z = <f64>pos[o + k * 3 + 2];
                if (x < mnx) mnx = x;
                if (y < mny) mny = y;
                if (z < mnz) mnz = z;
                if (x > mxx) mxx = x;
                if (y > mxy) mxy = y;
                if (z > mxz) mxz = z;
            }
            tb[i * 6] = mnx; tb[i * 6 + 1] = mny; tb[i * 6 + 2] = mnz;
            tb[i * 6 + 3] = mxx; tb[i * 6 + 4] = mxy; tb[i * 6 + 5] = mxz;
            cx[i] = (mnx + mxx) * 0.5;
            cy[i] = (mny + mxy) * 0.5;
            cz[i] = (mnz + mxz) * 0.5;
        }
        const cap = n > 0 ? 2 * n : 1;
        const boxes = new Float32Array(cap * 6);
        const na = new Int32Array(cap);
        const nb = new Int32Array(cap);
        // Per bin: count and box; then the sweeps' areas and counts.
        const binCount = new Int32Array(SAH_BINS);
        const binBox = new Float64Array(SAH_BINS * 6);
        const leftArea = new Float64Array(SAH_BINS);
        const leftCount = new Int32Array(SAH_BINS);
        let nodes = 0;
        // (node, start, end) triples over `order`; at most 3 * (depth + 1)
        // entries, and a depth is below n.
        const stack = new Int32Array(3 * (n + 2));
        let sp = 0;
        if (n > 0) {
            nodes = 1;
            stack[sp++] = 0;
            stack[sp++] = 0;
            stack[sp++] = n;
        }
        while (sp > 0) {
            const end = stack[--sp];
            const start = stack[--sp];
            const node = stack[--sp];
            let mnx = Infinity, mny = Infinity, mnz = Infinity, mxx = -Infinity, mxy = -Infinity, mxz = -Infinity;
            let cmnx = Infinity, cmny = Infinity, cmnz = Infinity, cmxx = -Infinity, cmxy = -Infinity, cmxz = -Infinity;
            for (let i = start; i < end; i++) {
                const t = order[i];
                const o = t * 6;
                if (tb[o] < mnx) mnx = tb[o];
                if (tb[o + 1] < mny) mny = tb[o + 1];
                if (tb[o + 2] < mnz) mnz = tb[o + 2];
                if (tb[o + 3] > mxx) mxx = tb[o + 3];
                if (tb[o + 4] > mxy) mxy = tb[o + 4];
                if (tb[o + 5] > mxz) mxz = tb[o + 5];
                const x = cx[t], y = cy[t], z = cz[t];
                if (x < cmnx) cmnx = x;
                if (y < cmny) cmny = y;
                if (z < cmnz) cmnz = z;
                if (x > cmxx) cmxx = x;
                if (y > cmxy) cmxy = y;
                if (z > cmxz) cmxz = z;
            }
            const bo = node * 6;
            boxes[bo] = <f32>mnx;
            boxes[bo + 1] = <f32>mny;
            boxes[bo + 2] = <f32>mnz;
            boxes[bo + 3] = <f32>mxx;
            boxes[bo + 4] = <f32>mxy;
            boxes[bo + 5] = <f32>mxz;
            const count = end - start;
            const ex = cmxx - cmnx, ey = cmxy - cmny, ez = cmxz - cmnz;
            if (count <= 1 || (ex <= 0 && ey <= 0 && ez <= 0)) {
                na[node] = start;
                nb[node] = -count;
                continue;
            }
            const axis = ex >= ey && ex >= ez ? 0 : (ey >= ez ? 1 : 2);
            const key = axis == 0 ? cx : (axis == 1 ? cy : cz);
            const lo = axis == 0 ? cmnx : (axis == 1 ? cmny : cmnz);
            const extent = axis == 0 ? ex : (axis == 1 ? ey : ez);
            const scale = <f64>SAH_BINS / extent;
            for (let k = 0; k < SAH_BINS; k++) {
                binCount[k] = 0;
                binBox[k * 6] = Infinity; binBox[k * 6 + 1] = Infinity; binBox[k * 6 + 2] = Infinity;
                binBox[k * 6 + 3] = -Infinity; binBox[k * 6 + 4] = -Infinity; binBox[k * 6 + 5] = -Infinity;
            }
            for (let i = start; i < end; i++) {
                const t = order[i];
                const k = sahBin(key[t], lo, scale);
                binCount[k] = binCount[k] + 1;
                const o = t * 6, q = k * 6;
                for (let c = 0; c < 3; c++) {
                    if (tb[o + c] < binBox[q + c]) binBox[q + c] = tb[o + c];
                    if (tb[o + 3 + c] > binBox[q + 3 + c]) binBox[q + 3 + c] = tb[o + 3 + c];
                }
            }
            // Left sweep: the area and count of bins 0..k.
            let ax0 = Infinity, ay0 = Infinity, az0 = Infinity, ax1 = -Infinity, ay1 = -Infinity, az1 = -Infinity;
            let acc = 0;
            for (let k = 0; k < SAH_BINS; k++) {
                const q = k * 6;
                if (binCount[k] > 0) {
                    ax0 = min<f64>(ax0, binBox[q]); ay0 = min<f64>(ay0, binBox[q + 1]); az0 = min<f64>(az0, binBox[q + 2]);
                    ax1 = max<f64>(ax1, binBox[q + 3]); ay1 = max<f64>(ay1, binBox[q + 4]); az1 = max<f64>(az1, binBox[q + 5]);
                }
                acc += binCount[k];
                leftCount[k] = acc;
                leftArea[k] = acc > 0 ? boxArea(ax0, ay0, az0, ax1, ay1, az1) : 0;
            }
            // Right sweep, and the cheapest split after bin k.
            let bx0 = Infinity, by0 = Infinity, bz0 = Infinity, bx1 = -Infinity, by1 = -Infinity, bz1 = -Infinity;
            let bestCost = Infinity;
            let bestSplit = -1;
            for (let k = SAH_BINS - 1; k > 0; k--) {
                const q = k * 6;
                if (binCount[k] > 0) {
                    bx0 = min<f64>(bx0, binBox[q]); by0 = min<f64>(by0, binBox[q + 1]); bz0 = min<f64>(bz0, binBox[q + 2]);
                    bx1 = max<f64>(bx1, binBox[q + 3]); by1 = max<f64>(by1, binBox[q + 4]); bz1 = max<f64>(bz1, binBox[q + 5]);
                }
                const nl = leftCount[k - 1];
                const nr = count - nl;
                if (nl == 0 || nr == 0) continue;
                const cost = leftArea[k - 1] * <f64>nl + boxArea(bx0, by0, bz0, bx1, by1, bz1) * <f64>nr;
                if (cost <= bestCost) {
                    bestCost = cost;
                    bestSplit = k;
                }
            }
            const parentArea = boxArea(mnx, mny, mnz, mxx, mxy, mxz);
            const leafCost = <f64>count;
            const splitCost = parentArea > 0 ? SAH_TRAVERSAL_COST + bestCost / parentArea : Infinity;
            if (bestSplit < 0 || (count <= LEAF_SIZE && leafCost <= splitCost)) {
                na[node] = start;
                nb[node] = -count;
                continue;
            }
            // Stable partition: the triangles of bins below the split keep
            // their order on the left, the others theirs on the right.
            let w = start;
            let r = 0;
            for (let i = start; i < end; i++) {
                const t = order[i];
                if (sahBin(key[t], lo, scale) < bestSplit) order[w++] = t;
                else scratch[r++] = t;
            }
            for (let i = 0; i < r; i++) order[w + i] = scratch[i];
            const mid = w;
            const left = nodes;
            const right = nodes + 1;
            nodes += 2;
            na[node] = left;
            nb[node] = right;
            stack[sp++] = right;
            stack[sp++] = mid;
            stack[sp++] = end;
            stack[sp++] = left;
            stack[sp++] = start;
            stack[sp++] = mid;
        }
        const tris = new Float32Array(n * 9);
        const triOrder = new Int32Array(n);
        for (let i = 0; i < n; i++) {
            const o = order[i] * 9;
            triOrder[i] = order[i];
            for (let k = 0; k < 9; k++) tris[i * 9 + k] = pos[o + k];
        }
        bvh.tris = tris;
        bvh.boxes = boxes;
        bvh.a = na;
        bvh.b = nb;
        bvh.nodeCount = nodes;
        bvh.triOrder = triOrder;
        bvh.makeWalk();
        return bvh;
    }

    // The tree's depth (a lone root is 1; an empty tree 0).
    depth(): i32 {
        if (this.nodeCount == 0) return 0;
        const node = new Int32Array(this.nodeCount);
        const level = new Int32Array(this.nodeCount);
        let sp = 0;
        node[sp] = 0;
        level[sp++] = 1;
        let deepest = 0;
        while (sp > 0) {
            sp--;
            const at = node[sp], d = level[sp];
            if (d > deepest) deepest = d;
            if (this.b[at] > 0) {
                node[sp] = this.a[at];
                level[sp++] = d + 1;
                node[sp] = this.b[at];
                level[sp++] = d + 1;
            }
        }
        return deepest;
    }

    // Milestone 47: the same triangles moved (a skinned mesh posed again, a
    // blended copy rewritten): `positions` holds them in the input order
    // of the build, 9 floats each, as the build's `pos` did. The tree's
    // order and topology are kept: each leaf's triangles are rewritten in
    // leaf order through triOrder, then every box is recomputed from the
    // bottom up (a node's children always come after it). Rays then answer
    // for the new positions exactly, only more slowly when the triangles
    // moved far from where the tree grouped them. A `positions` that holds
    // fewer triangles than the tree changes nothing. Allocates nothing.
    refit(positions: Float32Array): void {
        const n = this.triCount;
        if (positions.length < n * 9) return;
        const tris = this.tris;
        const order = this.triOrder;
        for (let i = 0; i < n; i++) {
            const o = unchecked(order[i]) * 9;
            const d = i * 9;
            for (let k = 0; k < 9; k++) unchecked(tris[d + k] = positions[o + k]);
        }
        const boxes = this.boxes;
        const na = this.a, nb = this.b;
        for (let node = this.nodeCount - 1; node >= 0; node--) {
            const first = unchecked(na[node]), second = unchecked(nb[node]);
            let mnx: f32 = Infinity, mny: f32 = Infinity, mnz: f32 = Infinity;
            let mxx: f32 = -Infinity, mxy: f32 = -Infinity, mxz: f32 = -Infinity;
            if (second <= 0) {
                const end = first - second;
                for (let i = first; i < end; i++) {
                    for (let k = 0; k < 3; k++) {
                        const o = i * 9 + k * 3;
                        const x = unchecked(tris[o]), y = unchecked(tris[o + 1]), z = unchecked(tris[o + 2]);
                        if (x < mnx) mnx = x;
                        if (y < mny) mny = y;
                        if (z < mnz) mnz = z;
                        if (x > mxx) mxx = x;
                        if (y > mxy) mxy = y;
                        if (z > mxz) mxz = z;
                    }
                }
            } else {
                for (let c = 0; c < 2; c++) {
                    const bo = (c == 0 ? first : second) * 6;
                    if (unchecked(boxes[bo]) < mnx) mnx = unchecked(boxes[bo]);
                    if (unchecked(boxes[bo + 1]) < mny) mny = unchecked(boxes[bo + 1]);
                    if (unchecked(boxes[bo + 2]) < mnz) mnz = unchecked(boxes[bo + 2]);
                    if (unchecked(boxes[bo + 3]) > mxx) mxx = unchecked(boxes[bo + 3]);
                    if (unchecked(boxes[bo + 4]) > mxy) mxy = unchecked(boxes[bo + 4]);
                    if (unchecked(boxes[bo + 5]) > mxz) mxz = unchecked(boxes[bo + 5]);
                }
            }
            const bo = node * 6;
            unchecked(boxes[bo] = mnx);
            unchecked(boxes[bo + 1] = mny);
            unchecked(boxes[bo + 2] = mnz);
            unchecked(boxes[bo + 3] = mxx);
            unchecked(boxes[bo + 4] = mxy);
            unchecked(boxes[bo + 5] = mxz);
        }
    }

    private makeWalk(): void {
        const size = this.depth() + 2;
        this.walk = new Int32Array(size);
        this.walkT = new Float64Array(size);
    }

    // The nearest hit of `o + t d` with tMin < t < tMax on either side of a
    // triangle, into `hit`; false (hit.t +Infinity, hit.tri -1) for none.
    // `d` need not be unit. Nearer child first, and a node whose entry is
    // past the best hit is skipped. Allocates nothing.
    nearestHit(ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64, tMin: f64, tMax: f64, hit: RayHit): bool {
        hit.t = Infinity;
        hit.tri = -1;
        hit.u = 0;
        hit.v = 0;
        hit.backFace = false;
        if (this.nodeCount == 0) return false;
        const ix = 1.0 / dx, iy = 1.0 / dy, iz = 1.0 / dz;
        const boxes = this.boxes;
        const tris = this.tris;
        const na = this.a, nb = this.b;
        const walk = this.walk, walkT = this.walkT;
        let best = tMax;
        let bestLeaf = -1;
        let bu: f64 = 0, bv: f64 = 0, bdet: f64 = 0;
        const t0 = slabEntry(boxes, 0, ox, oy, oz, ix, iy, iz, tMin, best);
        if (t0 == Infinity) return false;
        let sp = 0;
        walk[sp] = 0;
        walkT[sp++] = t0;
        while (sp > 0) {
            sp--;
            if (walkT[sp] >= best) continue;
            const node = walk[sp];
            const first = na[node], second = nb[node];
            if (second <= 0) {
                const end = first - second;
                for (let i = first; i < end; i++) {
                    // Möller-Trumbore, as hitTriangle, keeping u, v and det.
                    const o = i * 9;
                    const ax = <f64>tris[o], ay = <f64>tris[o + 1], az = <f64>tris[o + 2];
                    const e1x = <f64>tris[o + 3] - ax, e1y = <f64>tris[o + 4] - ay, e1z = <f64>tris[o + 5] - az;
                    const e2x = <f64>tris[o + 6] - ax, e2y = <f64>tris[o + 7] - ay, e2z = <f64>tris[o + 8] - az;
                    const px = dy * e2z - dz * e2y, py = dz * e2x - dx * e2z, pz = dx * e2y - dy * e2x;
                    const det = e1x * px + e1y * py + e1z * pz;
                    if (det == 0 || !isFinite(det)) continue;
                    const inv = 1.0 / det;
                    const sx = ox - ax, sy = oy - ay, sz = oz - az;
                    const u = (sx * px + sy * py + sz * pz) * inv;
                    if (u < -1e-9 || u > 1 + 1e-9) continue;
                    const qx = sy * e1z - sz * e1y, qy = sz * e1x - sx * e1z, qz = sx * e1y - sy * e1x;
                    const v = (dx * qx + dy * qy + dz * qz) * inv;
                    if (v < -1e-9 || u + v > 1 + 1e-9) continue;
                    const t = (e2x * qx + e2y * qy + e2z * qz) * inv;
                    if (t > tMin && t < best) {
                        best = t;
                        bestLeaf = i;
                        bu = u;
                        bv = v;
                        bdet = det;
                    }
                }
            } else {
                const tl = slabEntry(boxes, first * 6, ox, oy, oz, ix, iy, iz, tMin, best);
                const tr = slabEntry(boxes, second * 6, ox, oy, oz, ix, iy, iz, tMin, best);
                // The farther pushed first, so the nearer is walked first.
                if (tl <= tr) {
                    if (tr != Infinity) { walk[sp] = second; walkT[sp++] = tr; }
                    if (tl != Infinity) { walk[sp] = first; walkT[sp++] = tl; }
                } else {
                    if (tl != Infinity) { walk[sp] = first; walkT[sp++] = tl; }
                    if (tr != Infinity) { walk[sp] = second; walkT[sp++] = tr; }
                }
            }
        }
        if (bestLeaf < 0) return false;
        hit.t = best;
        hit.tri = this.triOrder[bestLeaf];
        hit.u = bu;
        hit.v = bv;
        // det = e1 . (d x e2) = -d . (e1 x e2): negative when the ray runs
        // along the winding's normal, so meets the back.
        hit.backFace = bdet < 0;
        return true;
    }

    // Whether `o + t d` meets any triangle with tMin < t < tMax (a shadow
    // ray: the first hit found ends the walk). Allocates nothing.
    anyHit(ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64, tMin: f64, tMax: f64): bool {
        if (this.nodeCount == 0) return false;
        const ix = 1.0 / dx, iy = 1.0 / dy, iz = 1.0 / dz;
        const boxes = this.boxes;
        const tris = this.tris;
        const na = this.a, nb = this.b;
        const walk = this.walk;
        if (slabEntry(boxes, 0, ox, oy, oz, ix, iy, iz, tMin, tMax) == Infinity) return false;
        let sp = 0;
        walk[sp++] = 0;
        while (sp > 0) {
            const node = walk[--sp];
            const first = na[node], second = nb[node];
            if (second <= 0) {
                const end = first - second;
                for (let i = first; i < end; i++) {
                    const t = hitTriangle(tris, i * 9, ox, oy, oz, dx, dy, dz);
                    if (t > tMin && t < tMax) return true;
                }
            } else {
                if (slabEntry(boxes, second * 6, ox, oy, oz, ix, iy, iz, tMin, tMax) != Infinity) walk[sp++] = second;
                if (slabEntry(boxes, first * 6, ox, oy, oz, ix, iy, iz, tMin, tMax) != Infinity) walk[sp++] = first;
            }
        }
        return false;
    }

    // Milestone 31: `nearestHit` with the triangles of one side left out
    // (an interaction ConcavePolygonShape3D's front-only faces: Godot winds
    // a front face clockwise, which is this tree's back, so its rays cull
    // this tree's front). `cullFront` skips a triangle the ray meets on
    // the side its counter-clockwise winding faces, `cullBack` one it
    // meets on the other; both false is nearestHit's answer. A culled
    // triangle does not hide one behind it. Allocates nothing.
    nearestHitCulled(ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64, tMin: f64, tMax: f64, cullFront: bool,
        cullBack: bool, hit: RayHit): bool {
        hit.t = Infinity;
        hit.tri = -1;
        hit.u = 0;
        hit.v = 0;
        hit.backFace = false;
        if (this.nodeCount == 0) return false;
        const ix = 1.0 / dx, iy = 1.0 / dy, iz = 1.0 / dz;
        const boxes = this.boxes;
        const tris = this.tris;
        const na = this.a, nb = this.b;
        const walk = this.walk, walkT = this.walkT;
        let best = tMax;
        let bestLeaf = -1;
        let bu: f64 = 0, bv: f64 = 0, bdet: f64 = 0;
        const t0 = slabEntry(boxes, 0, ox, oy, oz, ix, iy, iz, tMin, best);
        if (t0 == Infinity) return false;
        let sp = 0;
        walk[sp] = 0;
        walkT[sp++] = t0;
        while (sp > 0) {
            sp--;
            if (walkT[sp] >= best) continue;
            const node = walk[sp];
            const first = na[node], second = nb[node];
            if (second <= 0) {
                const end = first - second;
                for (let i = first; i < end; i++) {
                    const o = i * 9;
                    const ax = <f64>tris[o], ay = <f64>tris[o + 1], az = <f64>tris[o + 2];
                    const e1x = <f64>tris[o + 3] - ax, e1y = <f64>tris[o + 4] - ay, e1z = <f64>tris[o + 5] - az;
                    const e2x = <f64>tris[o + 6] - ax, e2y = <f64>tris[o + 7] - ay, e2z = <f64>tris[o + 8] - az;
                    const px = dy * e2z - dz * e2y, py = dz * e2x - dx * e2z, pz = dx * e2y - dy * e2x;
                    const det = e1x * px + e1y * py + e1z * pz;
                    if (det == 0 || !isFinite(det)) continue;
                    // det > 0: the front (see nearestHit's backFace).
                    if (det > 0 ? cullFront : cullBack) continue;
                    const inv = 1.0 / det;
                    const sx = ox - ax, sy = oy - ay, sz = oz - az;
                    const u = (sx * px + sy * py + sz * pz) * inv;
                    if (u < -1e-9 || u > 1 + 1e-9) continue;
                    const qx = sy * e1z - sz * e1y, qy = sz * e1x - sx * e1z, qz = sx * e1y - sy * e1x;
                    const v = (dx * qx + dy * qy + dz * qz) * inv;
                    if (v < -1e-9 || u + v > 1 + 1e-9) continue;
                    const t = (e2x * qx + e2y * qy + e2z * qz) * inv;
                    if (t > tMin && t < best) {
                        best = t;
                        bestLeaf = i;
                        bu = u;
                        bv = v;
                        bdet = det;
                    }
                }
            } else {
                const tl = slabEntry(boxes, first * 6, ox, oy, oz, ix, iy, iz, tMin, best);
                const tr = slabEntry(boxes, second * 6, ox, oy, oz, ix, iy, iz, tMin, best);
                if (tl <= tr) {
                    if (tr != Infinity) { walk[sp] = second; walkT[sp++] = tr; }
                    if (tl != Infinity) { walk[sp] = first; walkT[sp++] = tl; }
                } else {
                    if (tl != Infinity) { walk[sp] = first; walkT[sp++] = tl; }
                    if (tr != Infinity) { walk[sp] = second; walkT[sp++] = tr; }
                }
            }
        }
        if (bestLeaf < 0) return false;
        hit.t = best;
        hit.tri = this.triOrder[bestLeaf];
        hit.u = bu;
        hit.v = bv;
        hit.backFace = bdet < 0;
        return true;
    }

    // Milestone 31: the triangles whose own box meets the box min..max
    // (touching counts), by their index in the input of the build, into
    // `out` from 0 (set in place, pushed past its end); returns how many.
    // In the tree's leaf order, not sorted. Allocates nothing once `out`
    // has grown (an interaction overlap test keeps one).
    queryBox(minX: f64, minY: f64, minZ: f64, maxX: f64, maxY: f64, maxZ: f64, out: Array<i32>): i32 {
        if (this.nodeCount == 0) return 0;
        if (!(minX <= maxX && minY <= maxY && minZ <= maxZ)) return 0;
        const boxes = this.boxes;
        const tris = this.tris;
        const na = this.a, nb = this.b;
        const walk = this.walk;
        let count = 0;
        let sp = 0;
        if (!boxMeets(boxes, 0, minX, minY, minZ, maxX, maxY, maxZ)) return 0;
        walk[sp++] = 0;
        while (sp > 0) {
            const node = walk[--sp];
            const first = na[node], second = nb[node];
            if (second <= 0) {
                const end = first - second;
                for (let i = first; i < end; i++) {
                    const o = i * 9;
                    const x0 = <f64>tris[o], x1 = <f64>tris[o + 3], x2 = <f64>tris[o + 6];
                    if (min<f64>(x0, min<f64>(x1, x2)) > maxX || max<f64>(x0, max<f64>(x1, x2)) < minX) continue;
                    const y0 = <f64>tris[o + 1], y1 = <f64>tris[o + 4], y2 = <f64>tris[o + 7];
                    if (min<f64>(y0, min<f64>(y1, y2)) > maxY || max<f64>(y0, max<f64>(y1, y2)) < minY) continue;
                    const z0 = <f64>tris[o + 2], z1 = <f64>tris[o + 5], z2 = <f64>tris[o + 8];
                    if (min<f64>(z0, min<f64>(z1, z2)) > maxZ || max<f64>(z0, max<f64>(z1, z2)) < minZ) continue;
                    const idx = this.triOrder[i];
                    if (count < out.length) out[count] = idx;
                    else out.push(idx);
                    count++;
                }
            } else {
                if (boxMeets(boxes, second * 6, minX, minY, minZ, maxX, maxY, maxZ)) walk[sp++] = second;
                if (boxMeets(boxes, first * 6, minX, minY, minZ, maxX, maxY, maxZ)) walk[sp++] = first;
            }
        }
        return count;
    }

    // Parameter `t` of the nearest intersection of `origin + t * dir` with
    // `tMin < t < tMax`, or +Infinity when the ray hits nothing. `dir` need
    // not be normalized. Computed in f64.
    nearest(origin: Vec3, dir: Vec3, tMin: f64 = 0, tMax: f64 = Infinity): f64 {
        if (this.nodeCount == 0) return Infinity;
        const ox = <f64>origin.x, oy = <f64>origin.y, oz = <f64>origin.z;
        const dx = <f64>dir.x, dy = <f64>dir.y, dz = <f64>dir.z;
        const ix = 1.0 / dx, iy = 1.0 / dy, iz = 1.0 / dz;
        let best = tMax;
        const stack: Array<i32> = [0];
        const boxes = this.boxes;
        const tris = this.tris;
        while (stack.length > 0) {
            const node = stack.pop();
            const bo = node * 6;
            // Slab test (NaN-safe: a NaN bound keeps the node).
            let t0 = tMin, t1 = best;
            let s = (<f64>boxes[bo] - ox) * ix, e = (<f64>boxes[bo + 3] - ox) * ix;
            if (s > e) { const q = s; s = e; e = q; }
            if (s > t0) t0 = s;
            if (e < t1) t1 = e;
            s = (<f64>boxes[bo + 1] - oy) * iy; e = (<f64>boxes[bo + 4] - oy) * iy;
            if (s > e) { const q = s; s = e; e = q; }
            if (s > t0) t0 = s;
            if (e < t1) t1 = e;
            s = (<f64>boxes[bo + 2] - oz) * iz; e = (<f64>boxes[bo + 5] - oz) * iz;
            if (s > e) { const q = s; s = e; e = q; }
            if (s > t0) t0 = s;
            if (e < t1) t1 = e;
            if (t0 > t1) continue;
            const na = this.a[node], nb = this.b[node];
            if (nb <= 0) {
                const end = na - nb;
                for (let i = na; i < end; i++) {
                    const t = hitTriangle(tris, i * 9, ox, oy, oz, dx, dy, dz);
                    if (t > tMin && t < best) best = t;
                }
            } else {
                stack.push(nb);
                stack.push(na);
            }
        }
        return best < tMax ? best : Infinity;
    }

    // The nearest hit of a world-space ray on this local-space BVH placed by
    // `model`. The ray is carried into local space with the inverse model
    // matrix; affine maps keep the ray parameter, so the result is `t` on the
    // world ray (+Infinity for no hit, or when `model` is singular).
    nearestWorld(model: Mat4, origin: Vec3, dir: Vec3, tMin: f64 = 0, tMax: f64 = Infinity): f64 {
        const det = model.determinant();
        if (det == 0 || !isFinite(det)) return Infinity;
        const inv = model.inverse();
        return this.nearest(inv.transformPoint3(origin), inv.transformVector3(dir), tMin, tMax);
    }
}

// Appends the corners (9 f32 per triangle) of the triangles in
// `indices[first..end]` whose flags have none of `skipFlags` (flags are per
// face, so the first corner decides).
export function appendTriangles(
    pos: Array<f32>, verts: Array<SurfaceVertex>, indices: Array<u32>, first: i32, end: i32, skipFlags: u32,
): void {
    const stop = end < indices.length ? end : indices.length;
    for (let i = first; i + 2 < stop; i += 3) {
        const v0 = verts[<i32>indices[i]];
        if ((v0.flags & skipFlags) != 0) continue;
        const v1 = verts[<i32>indices[i + 1]];
        const v2 = verts[<i32>indices[i + 2]];
        pos.push(v0.pos.x); pos.push(v0.pos.y); pos.push(v0.pos.z);
        pos.push(v1.pos.x); pos.push(v1.pos.y); pos.push(v1.pos.z);
        pos.push(v2.pos.x); pos.push(v2.pos.y); pos.push(v2.pos.z);
    }
}

// Where `o + t d` (inverse direction `i`) enters the box at `bo` of
// `boxes` within [tMin, tMax], or +Infinity when it misses it. NaN-safe as
// `nearest`'s slab test: a NaN bound keeps the box.
@inline
function slabEntry(boxes: Float32Array, bo: i32, ox: f64, oy: f64, oz: f64, ix: f64, iy: f64, iz: f64, tMin: f64, tMax: f64): f64 {
    let t0 = tMin, t1 = tMax;
    let s = (<f64>boxes[bo] - ox) * ix, e = (<f64>boxes[bo + 3] - ox) * ix;
    if (s > e) { const q = s; s = e; e = q; }
    if (s > t0) t0 = s;
    if (e < t1) t1 = e;
    s = (<f64>boxes[bo + 1] - oy) * iy; e = (<f64>boxes[bo + 4] - oy) * iy;
    if (s > e) { const q = s; s = e; e = q; }
    if (s > t0) t0 = s;
    if (e < t1) t1 = e;
    s = (<f64>boxes[bo + 2] - oz) * iz; e = (<f64>boxes[bo + 5] - oz) * iz;
    if (s > e) { const q = s; s = e; e = q; }
    if (s > t0) t0 = s;
    if (e < t1) t1 = e;
    return t0 > t1 ? Infinity : t0;
}

// Whether the box at `bo` of `boxes` meets min..max (touching counts).
@inline
function boxMeets(boxes: Float32Array, bo: i32, minX: f64, minY: f64, minZ: f64, maxX: f64, maxY: f64, maxZ: f64): bool {
    return <f64>boxes[bo] <= maxX && <f64>boxes[bo + 3] >= minX && <f64>boxes[bo + 1] <= maxY
        && <f64>boxes[bo + 4] >= minY && <f64>boxes[bo + 2] <= maxZ && <f64>boxes[bo + 5] >= minZ;
}

// The SAH bin of centroid coordinate `c` (the last bin holds the top).
function sahBin(c: f64, lo: f64, scale: f64): i32 {
    const k = <i32>((c - lo) * scale);
    return k < 0 ? 0 : k >= SAH_BINS ? SAH_BINS - 1 : k;
}

// Half the surface area of a box (the SAH needs only ratios).
function boxArea(x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64): f64 {
    const ex = x1 - x0, ey = y1 - y0, ez = z1 - z0;
    return ex * ey + ey * ez + ez * ex;
}

// Möller-Trumbore, two-sided. +Infinity for a miss or a parallel ray.
function hitTriangle(tris: Float32Array, o: i32, ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64): f64 {
    const ax = <f64>tris[o], ay = <f64>tris[o + 1], az = <f64>tris[o + 2];
    const e1x = <f64>tris[o + 3] - ax, e1y = <f64>tris[o + 4] - ay, e1z = <f64>tris[o + 5] - az;
    const e2x = <f64>tris[o + 6] - ax, e2y = <f64>tris[o + 7] - ay, e2z = <f64>tris[o + 8] - az;
    const px = dy * e2z - dz * e2y, py = dz * e2x - dx * e2z, pz = dx * e2y - dy * e2x;
    const det = e1x * px + e1y * py + e1z * pz;
    if (det == 0 || !isFinite(det)) return Infinity;
    const inv = 1.0 / det;
    const sx = ox - ax, sy = oy - ay, sz = oz - az;
    const u = (sx * px + sy * py + sz * pz) * inv;
    const eps = 1e-9;
    if (u < -eps || u > 1 + eps) return Infinity;
    const qx = sy * e1z - sz * e1y, qy = sz * e1x - sx * e1z, qz = sx * e1y - sy * e1x;
    const v = (dx * qx + dy * qy + dz * qz) * inv;
    if (v < -eps || u + v > 1 + eps) return Infinity;
    return (e2x * qx + e2y * qy + e2z * qz) * inv;
}
