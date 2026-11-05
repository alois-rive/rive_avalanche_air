// The convex hull of a set of points (milestone 31): what a
// ConvexPolygonShape3D is, for its rays, points and drawing (prepared.as
// keeps one per version of the shape), and what the editor's Create
// Collision Shape makes a single convex shape of (engine/src/scene/
// interaction/mesh_shapes.as). QuickHull, deterministic (the same points in
// the same order give the same hull, byte for byte), with a tolerance
// relative to the points' extent; points inside the hull or on its faces
// are left out of its vertices.
//
// How: exact duplicates and non-finite points are dropped first (the
// first of equal points is the one kept). The tolerance is HULL_TOLERANCE
// times the largest side of the points' box, but never below
// HULL_PRECISION times the largest coordinate (f32 rounding: a mesh's
// rotated faces are flat only to within it): a point within it of a face
// is on the face. The first simplex is the farthest
// pair of the six axis extremes, the point farthest from their line and
// the point farthest from that plane; fewer than four points out of one
// plane make a flat hull (below). Then QuickHull proper: every point
// outside a face (more than the tolerance) waits in that face's outside
// set; the first face to have been given points that still has some
// takes its farthest point, the faces that point sees or is within the
// tolerance of (walked from that face across shared edges) go, and the
// horizon's edges make a fan of new faces to it, none without area; the
// waiting points go to the new face they are farthest
// outside, or are inside and dropped. Last, adjacent
// triangles within the tolerance of one plane merge into one face (a
// cube has six faces, not twelve), and a vertex left in the middle of a
// face, or in the middle of an edge, is no vertex of the hull. The
// result is checked (closed, and convex at every edge); one that is not
// is built again with a larger tolerance (HULL_RETRY).
//
// Every choice breaks ties by the lower index, so the hull depends on the
// points and their order only. A build allocates (once per shape version:
// prepared.as); nothing here runs per frame.

// The tolerance, relative to the largest side of the points' box ...
export const HULL_TOLERANCE: f64 = 1e-9;
// ... and never below this much of the largest coordinate: eight f32
// rounding steps (2^-23 each), since a mesh's positions are f32 and a
// face that is not axis-aligned is flat only to within their rounding.
export const HULL_PRECISION: f64 = 8 * 1.1920928955078125e-7;
// A hull that fails its check is built again with a tolerance this many
// times larger, at most this many times (about 1e-6 of the coordinates,
// then 1e-5, 1e-4 and 1e-3). Of 12,000 turned f32 boxes, cylinders,
// spheres, cones and clouds of points on boxes' faces, 0.4% needed one
// retry (all of them clouds), one a third, none a fourth.
export const HULL_RETRY: f64 = 10;
export const HULL_RETRIES: i32 = 3;
// How far in front of a neighbour's plane a corner may be, in tolerances
// (checkHull).
const HULL_CHECK: f64 = 4;
// The most point-to-face distances checkHull measures beyond the faces'
// neighbours (about 20 ms in the test runner; a hull of 250 corners has
// about 500 faces).
const HULL_CHECK_BUDGET: f64 = 262144;
// The most a thin triangle's tolerance grows to, in tolerances
// (Builder.inPlane).
const HULL_MERGE: f64 = 16;
// The most rounds of merging faces that fold the wrong way (mergeFaces).
const HULL_ROUNDS: i32 = 16;

export class ConvexHull {
    // The hull's vertices, x, y, z each (a subset of the input points, in
    // the order of their first appearance in the input).
    points: Array<f64> = [];
    // Its faces' planes, outward: nx, ny, nz (unit), d each, a point p on
    // or inside the hull having n . p <= d.
    planes: Array<f64> = [];
    // Each face's vertex loop (indices into `points`' vertices, counter-
    // clockwise seen from outside): faceVerts[faceStart[f] ..
    // faceStart[f + 1]), faceStart having one entry more than the faces.
    faceStart: Array<i32> = [0];
    faceVerts: Array<i32> = [];
    // Its edges, pairs of vertex indices, each once: what is drawn.
    edges: Array<i32> = [];

    // Whether it has an inside (at least four points not in one plane). A
    // flat or degenerate set has no planes: it holds no point, and a ray
    // meets it nowhere; its edges still draw what it is.
    solid(): bool {
        return this.planes.length >= 16;
    }

    faceCount(): i32 {
        return this.faceStart.length - 1;
    }

    vertexCount(): i32 {
        return this.points.length / 3;
    }
}

// The working state of one build (the input's points by input index).
class Builder {
    p: Array<f64>;
    n: i64;
    tol: f64 = 0;
    // Triangles: corners, outward plane, alive, outside set (first and
    // last point), the walk's mark.
    fa: Array<i32> = [];
    fb: Array<i32> = [];
    fc: Array<i32> = [];
    nx: Array<f64> = [];
    ny: Array<f64> = [];
    nz: Array<f64> = [];
    nd: Array<f64> = [];
    // Its smallest height (twice its area over its longest side): how far
    // its plane can be trusted (mergeFaces).
    nh: Array<f64> = [];
    // Twice its area (its normal's weight in a merged face).
    na: Array<f64> = [];
    alive: Array<bool> = [];
    head: Array<i32> = [];
    tail: Array<i32> = [];
    mark: Array<i32> = [];
    // Per input point: the next point of its outside set (-1 ends it).
    next: Array<i32>;
    // Directed edge u -> v (u * n + v) to the alive triangle that has it.
    edgeOf: Map<i64, i32> = new Map<i64, i32>();
    // Faces that were given points, in that order (the next one to grow
    // is the first still alive with points).
    queue: Array<i32> = [];
    queueAt: i32 = 0;

    constructor(p: Array<f64>) {
        this.p = p;
        const n = p.length / 3;
        this.n = <i64>n;
        this.next = new Array<i32>(n);
        for (let i = 0; i < n; i++) this.next[i] = -1;
    }

    x(i: i32): f64 { return this.p[i * 3]; }
    y(i: i32): f64 { return this.p[i * 3 + 1]; }
    z(i: i32): f64 { return this.p[i * 3 + 2]; }

    key(u: i32, v: i32): i64 {
        return <i64>u * this.n + <i64>v;
    }

    // A new triangle a b c (its plane from the corners; counter-clockwise
    // seen from the side its normal points to).
    addFace(a: i32, b: i32, c: i32): i32 {
        const e1x = this.x(b) - this.x(a), e1y = this.y(b) - this.y(a), e1z = this.z(b) - this.z(a);
        const e2x = this.x(c) - this.x(a), e2y = this.y(c) - this.y(a), e2z = this.z(c) - this.z(a);
        let cx = e1y * e2z - e1z * e2y, cy = e1z * e2x - e1x * e2z, cz = e1x * e2y - e1y * e2x;
        const len = Math.sqrt(cx * cx + cy * cy + cz * cz);
        if (len > 0) {
            cx /= len;
            cy /= len;
            cz /= len;
        }
        const f = this.fa.length;
        this.fa.push(a);
        this.fb.push(b);
        this.fc.push(c);
        this.nx.push(cx);
        this.ny.push(cy);
        this.nz.push(cz);
        this.nd.push(cx * this.x(a) + cy * this.y(a) + cz * this.z(a));
        const e3x = this.x(c) - this.x(b), e3y = this.y(c) - this.y(b), e3z = this.z(c) - this.z(b);
        const longest = Math.sqrt(max<f64>(e1x * e1x + e1y * e1y + e1z * e1z,
            max<f64>(e2x * e2x + e2y * e2y + e2z * e2z, e3x * e3x + e3y * e3y + e3z * e3z)));
        this.nh.push(longest > 0 ? len / longest : 0);
        this.na.push(len);
        this.alive.push(true);
        this.head.push(-1);
        this.tail.push(-1);
        this.mark.push(0);
        this.edgeOf.set(this.key(a, b), f);
        this.edgeOf.set(this.key(b, c), f);
        this.edgeOf.set(this.key(c, a), f);
        return f;
    }

    // Removes a triangle and its edges (those another triangle has since
    // taken stay that triangle's).
    removeFace(f: i32): void {
        this.alive[f] = false;
        this.dropEdge(this.fa[f], this.fb[f], f);
        this.dropEdge(this.fb[f], this.fc[f], f);
        this.dropEdge(this.fc[f], this.fa[f], f);
    }

    private dropEdge(u: i32, v: i32, f: i32): void {
        const k = this.key(u, v);
        if (this.edgeOf.has(k) && this.edgeOf.get(k) == f) this.edgeOf.delete(k);
    }

    // The alive triangle across edge u -> v of a triangle (the one with
    // v -> u), or -1.
    across(u: i32, v: i32): i32 {
        const k = this.key(v, u);
        return this.edgeOf.has(k) ? this.edgeOf.get(k) : -1;
    }

    dist(f: i32, i: i32): f64 {
        return this.nx[f] * this.x(i) + this.ny[f] * this.y(i) + this.nz[f] * this.z(i) - this.nd[f];
    }

    // Whether point i is in the plane of triangle f. A thin triangle's
    // normal is only as good as its corners' precision (an eighth of the
    // tolerance: HULL_PRECISION) over its height, so the tolerance grows
    // with i's distance from the triangle over that height (the cap of a
    // turned f32 cylinder is a fan of thin triangles, and is one face).
    inPlane(f: i32, i: i32): bool {
        const a = this.fa[f];
        const dx = this.x(i) - this.x(a), dy = this.y(i) - this.y(a), dz = this.z(i) - this.z(a);
        const h = this.nh[f];
        const lever = h > 0 ? Math.sqrt(dx * dx + dy * dy + dz * dz) / h : 0;
        return Math.abs(this.dist(f, i)) <= this.tol * min<f64>(1 + lever * 0.125, HULL_MERGE);
    }

    // Puts point i in the outside set of the face (among `faces`) it is
    // farthest outside; false when it is outside none. Points come in
    // increasing index order, so each set stays in that order.
    assign(i: i32, faces: Array<i32>): bool {
        let best = -1;
        let bestD = this.tol;
        for (let k = 0; k < faces.length; k++) {
            const f = faces[k];
            if (!this.alive[f]) continue;
            const d = this.dist(f, i);
            if (d > bestD) {
                bestD = d;
                best = f;
            }
        }
        if (best < 0) return false;
        this.next[i] = -1;
        if (this.head[best] < 0) {
            this.head[best] = i;
            this.queue.push(best);
        } else {
            this.next[this.tail[best]] = i;
        }
        this.tail[best] = i;
        return true;
    }
}

// The convex hull of `points` (x, y, z each).
export function convexHull(points: Array<f64>): ConvexHull {
    const n = points.length / 3;
    // The distinct finite points, in input order (the first of equal ones).
    const sorted: Array<i32> = [];
    for (let i = 0; i < n; i++) {
        if (isFinite(points[i * 3]) && isFinite(points[i * 3 + 1]) && isFinite(points[i * 3 + 2])) sorted.push(i);
    }
    sorted.sort((a: i32, b: i32): i32 => {
        for (let k = 0; k < 3; k++) {
            const pa = points[a * 3 + k], pb = points[b * 3 + k];
            if (pa < pb) return -1;
            if (pa > pb) return 1;
        }
        return a - b;
    });
    const cand: Array<i32> = [];
    for (let k = 0; k < sorted.length; k++) {
        const i = sorted[k];
        if (k > 0) {
            const j = sorted[k - 1];
            if (points[i * 3] == points[j * 3] && points[i * 3 + 1] == points[j * 3 + 1]
                && points[i * 3 + 2] == points[j * 3 + 2]) continue;
        }
        cand.push(i);
    }
    cand.sort((a: i32, b: i32): i32 => a - b);
    if (cand.length == 0) return new ConvexHull();

    let mnx = Infinity, mny = Infinity, mnz = Infinity, mxx = -Infinity, mxy = -Infinity, mxz = -Infinity;
    let maxAbs: f64 = 0;
    for (let k = 0; k < cand.length; k++) {
        const o = cand[k] * 3;
        mnx = min<f64>(mnx, points[o]); mxx = max<f64>(mxx, points[o]);
        mny = min<f64>(mny, points[o + 1]); mxy = max<f64>(mxy, points[o + 1]);
        mnz = min<f64>(mnz, points[o + 2]); mxz = max<f64>(mxz, points[o + 2]);
        maxAbs = max<f64>(maxAbs, max<f64>(Math.abs(points[o]), max<f64>(Math.abs(points[o + 1]), Math.abs(points[o + 2]))));
    }
    const extent = max<f64>(mxx - mnx, max<f64>(mxy - mny, mxz - mnz));
    if (cand.length == 1 || extent == 0) {
        const out = new ConvexHull();
        emitVertices(out, points, [cand[0]]);
        return out;
    }
    // Mesh positions are f32: a rotated face's points are only within
    // f32 rounding of one plane, so the tolerance is never below that.
    // A hull that fails its check (below) is built again with a tolerance
    // HULL_RETRY times larger, up to HULL_RETRIES times; past that the
    // attempt that failed least is kept, and when none came out closed,
    // the first tolerance's triangles unmerged (each its own face).
    const first = max<f64>(HULL_TOLERANCE * extent, HULL_PRECISION * maxAbs);
    let tol = first;
    let best: ConvexHull? = null;
    let bestBad: f64 = Infinity;
    for (let attempt = 0; attempt <= HULL_RETRIES; attempt++) {
        const out = new ConvexHull();
        const bad = buildHull(out, points, cand, tol, true);
        if (bad <= 0) return out;
        if (best == null || bad < bestBad) {
            bestBad = bad;
            best = out;
        }
        tol *= HULL_RETRY;
    }
    if (bestBad == Infinity) {
        const out = new ConvexHull();
        if (buildHull(out, points, cand, first, false) < Infinity) return out;
    }
    return <ConvexHull>best;
}

// Builds the hull of `cand` (input indices, distinct, increasing) with
// tolerance `tol` into `out`, its coplanar triangles merged into faces
// unless `merge` is false; 0 when it passes its check (a flat or
// collinear set always does), otherwise how badly it failed (larger is
// worse, Infinity when it is not closed).
function buildHull(out: ConvexHull, points: Array<f64>, cand: Array<i32>, tol: f64, merge: bool): f64 {
    const b = new Builder(points);
    b.tol = tol;

    // The farthest pair of the axis extremes (first index on ties).
    const ext: Array<i32> = [cand[0], cand[0], cand[0], cand[0], cand[0], cand[0]];
    for (let k = 1; k < cand.length; k++) {
        const i = cand[k];
        for (let ax = 0; ax < 3; ax++) {
            const v = points[i * 3 + ax];
            if (v < points[ext[ax * 2] * 3 + ax]) ext[ax * 2] = i;
            if (v > points[ext[ax * 2 + 1] * 3 + ax]) ext[ax * 2 + 1] = i;
        }
    }
    let i0 = ext[0], i1 = ext[1];
    let far = dist2(points, i0, i1);
    for (let s = 0; s < 6; s++) {
        for (let t = s + 1; t < 6; t++) {
            const d = dist2(points, ext[s], ext[t]);
            if (d > far) {
                far = d;
                i0 = ext[s];
                i1 = ext[t];
            }
        }
    }
    if (i0 > i1) {
        const q = i0;
        i0 = i1;
        i1 = q;
    }
    // The point farthest from their line.
    const lx = b.x(i1) - b.x(i0), ly = b.y(i1) - b.y(i0), lz = b.z(i1) - b.z(i0);
    const ll = Math.sqrt(lx * lx + ly * ly + lz * lz);
    let i2 = -1;
    let lineFar = tol;
    for (let k = 0; k < cand.length; k++) {
        const i = cand[k];
        const qx = b.x(i) - b.x(i0), qy = b.y(i) - b.y(i0), qz = b.z(i) - b.z(i0);
        const cx = qy * lz - qz * ly, cy = qz * lx - qx * lz, cz = qx * ly - qy * lx;
        const d = Math.sqrt(cx * cx + cy * cy + cz * cz) / ll;
        if (d > lineFar) {
            lineFar = d;
            i2 = i;
        }
    }
    if (i2 < 0) {
        // Collinear: the segment between the two ends.
        const ends: Array<i32> = [i0, i1];
        emitVertices(out, points, ends);
        out.edges.push(0);
        out.edges.push(1);
        return 0;
    }
    // The point farthest from their plane.
    const e2x = b.x(i2) - b.x(i0), e2y = b.y(i2) - b.y(i0), e2z = b.z(i2) - b.z(i0);
    let pnx = ly * e2z - lz * e2y, pny = lz * e2x - lx * e2z, pnz = lx * e2y - ly * e2x;
    const pl = Math.sqrt(pnx * pnx + pny * pny + pnz * pnz);
    pnx /= pl;
    pny /= pl;
    pnz /= pl;
    const pd = pnx * b.x(i0) + pny * b.y(i0) + pnz * b.z(i0);
    let i3 = -1;
    let planeFar = tol;
    let side: f64 = 0;
    for (let k = 0; k < cand.length; k++) {
        const i = cand[k];
        const d = pnx * b.x(i) + pny * b.y(i) + pnz * b.z(i) - pd;
        if (Math.abs(d) > planeFar) {
            planeFar = Math.abs(d);
            i3 = i;
            side = d;
        }
    }
    if (i3 < 0) {
        flatHull(out, points, cand, i0, i1, pnx, pny, pnz, tol);
        return 0;
    }

    // The first tetrahedron, every face outward (i3 above the plane of
    // i0 i1 i2 means that face winds the other way).
    if (side > 0) {
        b.addFace(i0, i2, i1);
        b.addFace(i0, i1, i3);
        b.addFace(i1, i2, i3);
        b.addFace(i2, i0, i3);
    } else {
        b.addFace(i0, i1, i2);
        b.addFace(i1, i0, i3);
        b.addFace(i2, i1, i3);
        b.addFace(i0, i2, i3);
    }
    const first: Array<i32> = [0, 1, 2, 3];
    // The points found inside (checked against the finished hull).
    const dropped: Array<i32> = [];
    for (let k = 0; k < cand.length; k++) {
        const i = cand[k];
        if (i == i0 || i == i1 || i == i2 || i == i3) continue;
        if (!b.assign(i, first)) dropped.push(i);
    }

    const comp: Array<i32> = [];
    const horizonU: Array<i32> = [];
    const horizonV: Array<i32> = [];
    const made: Array<i32> = [];
    const orphans: Array<i32> = [];
    let stamp = 0;
    while (true) {
        // The first face given points that is alive and still has some.
        let f0 = -1;
        while (b.queueAt < b.queue.length) {
            const f = b.queue[b.queueAt++];
            if (b.alive[f] && b.head[f] >= 0) {
                f0 = f;
                break;
            }
        }
        if (f0 < 0) break;
        // Its farthest point (the lowest index on ties: the set is sorted).
        let apex = -1;
        let apexD = -Infinity;
        for (let at = b.head[f0]; at >= 0; at = b.next[at]) {
            const d = b.dist(f0, at);
            if (d > apexD) {
                apexD = d;
                apex = at;
            }
        }
        // The faces it sees, walked from f0 across shared edges, and the
        // horizon: the edges whose other face it does not see. A face the
        // apex is within the tolerance of counts as seen (it would
        // otherwise leave a sliver between it and the new faces), and so
        // does the face across a horizon edge whose new triangle would
        // have no area (the apex within the tolerance of the edge's line,
        // so within it of that face too): a near-zero cross product has
        // no trustworthy direction.
        stamp++;
        comp.length = 0;
        comp.push(f0);
        b.mark[f0] = stamp;
        let walked = 0;
        while (true) {
            for (; walked < comp.length; walked++) {
                const f = comp[walked];
                for (let e = 0; e < 3; e++) {
                    const u = e == 0 ? b.fa[f] : (e == 1 ? b.fb[f] : b.fc[f]);
                    const v = e == 0 ? b.fb[f] : (e == 1 ? b.fc[f] : b.fa[f]);
                    const g = b.across(u, v);
                    if (g >= 0 && b.mark[g] == stamp) continue;
                    if (g >= 0 && b.dist(g, apex) > -tol) {
                        b.mark[g] = stamp;
                        comp.push(g);
                    }
                }
            }
            // The horizon, once the region is known (an edge to a face
            // found later in the walk is no horizon).
            horizonU.length = 0;
            horizonV.length = 0;
            let grew = false;
            for (let c = 0; c < comp.length; c++) {
                const f = comp[c];
                for (let e = 0; e < 3; e++) {
                    const u = e == 0 ? b.fa[f] : (e == 1 ? b.fb[f] : b.fc[f]);
                    const v = e == 0 ? b.fb[f] : (e == 1 ? b.fc[f] : b.fa[f]);
                    const g = b.across(u, v);
                    if (g >= 0 && b.mark[g] == stamp) continue;
                    if (g >= 0 && lineDistance(b, u, v, apex) <= tol) {
                        b.mark[g] = stamp;
                        comp.push(g);
                        grew = true;
                        continue;
                    }
                    horizonU.push(u);
                    horizonV.push(v);
                }
            }
            if (!grew) break;
        }
        // The seen faces go, their points wait again.
        orphans.length = 0;
        for (let c = 0; c < comp.length; c++) {
            const f = comp[c];
            b.removeFace(f);
            for (let at = b.head[f]; at >= 0;) {
                const nx = b.next[at];
                if (at != apex) orphans.push(at);
                at = nx;
            }
            b.head[f] = -1;
            b.tail[f] = -1;
        }
        made.length = 0;
        for (let k = 0; k < horizonU.length; k++) {
            const f = b.addFace(horizonU[k], horizonV[k], apex);
            made.push(f);
        }
        // To the new face each is farthest outside; one outside none is
        // inside the grown hull (QuickHull's argument: the new faces close
        // the region the old ones saw).
        orphans.sort((p: i32, q: i32): i32 => p - q);
        for (let k = 0; k < orphans.length; k++) {
            if (!b.assign(orphans[k], made)) dropped.push(orphans[k]);
        }
    }
    if (!mergeFaces(out, b, merge)) return Infinity;
    return checkHull(out, points, dropped, tol);
}

function dist2(p: Array<f64>, i: i32, j: i32): f64 {
    const dx = p[i * 3] - p[j * 3], dy = p[i * 3 + 1] - p[j * 3 + 1], dz = p[i * 3 + 2] - p[j * 3 + 2];
    return dx * dx + dy * dy + dz * dz;
}

// `out.points` from input indices `keep`, put in input order (vertexIndex
// maps an input index to its vertex).
function emitVertices(out: ConvexHull, p: Array<f64>, keep: Array<i32>): void {
    const order = keep.slice(0);
    order.sort((a: i32, b: i32): i32 => a - b);
    for (let k = 0; k < order.length; k++) {
        out.points.push(p[order[k] * 3]);
        out.points.push(p[order[k] * 3 + 1]);
        out.points.push(p[order[k] * 3 + 2]);
    }
}

// The position of input index `i` among `keep` sorted (its vertex index).
function vertexIndex(sortedKeep: Array<i32>, i: i32): i32 {
    let lo = 0, hi = sortedKeep.length - 1;
    while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        const v = sortedKeep[mid];
        if (v == i) return mid;
        if (v < i) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

// A flat set: its outline in its plane (Andrew's monotone chain over the
// plane's coordinates), counter-clockwise about the normal n, with no
// faces and no planes; points within the tolerance of the outline's
// lines are on it, not corners.
function flatHull(out: ConvexHull, p: Array<f64>, cand: Array<i32>, i0: i32, i1: i32,
    nx: f64, ny: f64, nz: f64, tol: f64): void {
    let ux = p[i1 * 3] - p[i0 * 3], uy = p[i1 * 3 + 1] - p[i0 * 3 + 1], uz = p[i1 * 3 + 2] - p[i0 * 3 + 2];
    const ul = Math.sqrt(ux * ux + uy * uy + uz * uz);
    ux /= ul;
    uy /= ul;
    uz /= ul;
    const vx = ny * uz - nz * uy, vy = nz * ux - nx * uz, vz = nx * uy - ny * ux;
    const m = cand.length;
    const pu = new Array<f64>(m);
    const pv = new Array<f64>(m);
    const idx = new Array<i32>(m);
    for (let k = 0; k < m; k++) {
        const o = cand[k] * 3;
        pu[k] = p[o] * ux + p[o + 1] * uy + p[o + 2] * uz;
        pv[k] = p[o] * vx + p[o + 1] * vy + p[o + 2] * vz;
        idx[k] = k;
    }
    idx.sort((a: i32, b: i32): i32 => {
        if (pu[a] < pu[b]) return -1;
        if (pu[a] > pu[b]) return 1;
        if (pv[a] < pv[b]) return -1;
        if (pv[a] > pv[b]) return 1;
        return a - b;
    });
    // Whether c is left of a -> b by more than the tolerance.
    const chain: Array<i32> = [];
    for (let pass = 0; pass < 2; pass++) {
        const start = chain.length;
        for (let s = 0; s < m; s++) {
            const k = pass == 0 ? idx[s] : idx[m - 1 - s];
            while (chain.length >= start + 2) {
                const a = chain[chain.length - 2], c = chain[chain.length - 1];
                const abx = pu[c] - pu[a], aby = pv[c] - pv[a];
                const acx = pu[k] - pu[a], acy = pv[k] - pv[a];
                const len = Math.sqrt(acx * acx + acy * acy);
                const cross = abx * acy - aby * acx;
                // c stays a corner only when k turns left of a -> c by
                // more than the tolerance (distance of c from a -> k).
                if (len > 0 && cross / len > tol) break;
                chain.pop();
            }
            chain.push(k);
        }
        chain.pop();
    }
    const keep: Array<i32> = [];
    for (let k = 0; k < chain.length; k++) keep.push(cand[chain[k]]);
    const sortedKeep = keep.slice(0);
    sortedKeep.sort((a: i32, b: i32): i32 => a - b);
    emitVertices(out, p, keep);
    if (keep.length == 2) {
        out.edges.push(0);
        out.edges.push(1);
        return;
    }
    for (let k = 0; k < keep.length; k++) {
        out.edges.push(vertexIndex(sortedKeep, keep[k]));
        out.edges.push(vertexIndex(sortedKeep, keep[(k + 1) % keep.length]));
    }
}

// The alive triangles merged into faces (adjacent ones within the
// tolerance of each other's plane), each face's loop with no vertex in
// the middle of an edge, then the vertices, planes and edges; false when
// a face's boundary is not one closed loop (a broken build).
function mergeFaces(out: ConvexHull, b: Builder, merge: bool): bool {
    const tris: Array<i32> = [];
    for (let f = 0; f < b.fa.length; f++) if (b.alive[f]) tris.push(f);
    const t = tris.length;
    const n = <i64>(b.p.length / 3);
    // Directed edge u -> v to its triangle's place in `tris`.
    const edgeOf = new Map<i64, i32>();
    for (let k = 0; k < t; k++) {
        const f = tris[k];
        edgeOf.set(<i64>b.fa[f] * n + <i64>b.fb[f], k);
        edgeOf.set(<i64>b.fb[f] * n + <i64>b.fc[f], k);
        edgeOf.set(<i64>b.fc[f] * n + <i64>b.fa[f], k);
    }
    // Union-find over the triangles (the lower root wins: deterministic).
    const parent = new Array<i32>(t);
    for (let k = 0; k < t; k++) parent[k] = k;
    for (let k = 0; merge && k < t; k++) {
        const f = tris[k];
        for (let e = 0; e < 3; e++) {
            const u = e == 0 ? b.fa[f] : (e == 1 ? b.fb[f] : b.fc[f]);
            const v = e == 0 ? b.fb[f] : (e == 1 ? b.fc[f] : b.fa[f]);
            const key = <i64>v * n + <i64>u;
            if (!edgeOf.has(key)) continue;
            const j = edgeOf.get(key);
            if (j <= k) continue;
            const g = tris[j];
            if (b.nx[f] * b.nx[g] + b.ny[f] * b.ny[g] + b.nz[f] * b.nz[g] <= 0) continue;
            if (!b.inPlane(f, b.fa[g]) || !b.inPlane(f, b.fb[g]) || !b.inPlane(f, b.fc[g])) continue;
            if (!b.inPlane(g, b.fa[f]) || !b.inPlane(g, b.fb[f]) || !b.inPlane(g, b.fc[f])) continue;
            const rk = findRoot(parent, k), rj = findRoot(parent, j);
            if (rk < rj) parent[rj] = rk;
            else if (rj < rk) parent[rk] = rj;
        }
    }
    // Then groups that are not convex where they meet (a corner of one in
    // front of the other's plane by more than the tolerance) merge too, a
    // round at a time, each group's plane its triangles' area-weighted
    // normal through its outermost corner. Points within the tolerance of
    // a plane count as on it, so the hull of points that are not quite
    // coplanar can fold the wrong way by that much, and a thin triangle
    // along such a fold tilts by the tolerance over its height: merged
    // into its neighbour, it no longer cuts into the hull.
    const root = new Array<i32>(t);
    const gx = new Array<f64>(t), gy = new Array<f64>(t), gz = new Array<f64>(t), gd = new Array<f64>(t);
    for (let round = 0; merge && round < HULL_ROUNDS; round++) {
        for (let k = 0; k < t; k++) {
            root[k] = findRoot(parent, k);
            gx[k] = 0;
            gy[k] = 0;
            gz[k] = 0;
            gd[k] = -Infinity;
        }
        for (let k = 0; k < t; k++) {
            const f = tris[k], r = root[k];
            gx[r] += b.nx[f] * b.na[f];
            gy[r] += b.ny[f] * b.na[f];
            gz[r] += b.nz[f] * b.na[f];
        }
        for (let k = 0; k < t; k++) {
            if (root[k] != k) continue;
            const len = Math.sqrt(gx[k] * gx[k] + gy[k] * gy[k] + gz[k] * gz[k]);
            if (len > 0) {
                gx[k] /= len;
                gy[k] /= len;
                gz[k] /= len;
            }
        }
        for (let k = 0; k < t; k++) {
            const f = tris[k], r = root[k];
            gd[r] = max<f64>(gd[r], groupDist(b, gx[r], gy[r], gz[r], 0, f));
        }
        let merged = false;
        for (let k = 0; k < t; k++) {
            const f = tris[k];
            for (let e = 0; e < 3; e++) {
                const u = e == 0 ? b.fa[f] : (e == 1 ? b.fb[f] : b.fc[f]);
                const v = e == 0 ? b.fb[f] : (e == 1 ? b.fc[f] : b.fa[f]);
                const key = <i64>v * n + <i64>u;
                if (!edgeOf.has(key)) continue;
                const j = edgeOf.get(key);
                if (j <= k) continue;
                const rk = root[k], rj = root[j];
                if (rk == rj) continue;
                if (groupDist(b, gx[rk], gy[rk], gz[rk], gd[rk], tris[j]) <= b.tol
                    && groupDist(b, gx[rj], gy[rj], gz[rj], gd[rj], f) <= b.tol) continue;
                const pk = findRoot(parent, k), pj = findRoot(parent, j);
                if (pk < pj) parent[pj] = pk;
                else if (pj < pk) parent[pk] = pj;
                merged = true;
            }
        }
        if (!merged) break;
    }
    for (let k = 0; k < t; k++) root[k] = findRoot(parent, k);
    // Each group's boundary edges (those whose other side is another
    // group's), then chained into one loop of input indices.
    const groupFirst = new Array<i32>(t);
    const groupNext = new Array<i32>(t);
    for (let k = 0; k < t; k++) {
        groupFirst[k] = -1;
        groupNext[k] = -1;
    }
    for (let k = t - 1; k >= 0; k--) {
        groupNext[k] = groupFirst[root[k]];
        groupFirst[root[k]] = k;
    }
    const loopStart: Array<i32> = [0];
    const loopVerts: Array<i32> = [];
    // Each face's group (its root in `tris`).
    const loopRoot: Array<i32> = [];
    const eu: Array<i32> = [];
    const ev: Array<i32> = [];
    const used: Array<bool> = [];
    for (let r = 0; r < t; r++) {
        if (root[r] != r) continue;
        eu.length = 0;
        ev.length = 0;
        for (let k = groupFirst[r]; k >= 0; k = groupNext[k]) {
            const f = tris[k];
            for (let e = 0; e < 3; e++) {
                const u = e == 0 ? b.fa[f] : (e == 1 ? b.fb[f] : b.fc[f]);
                const v = e == 0 ? b.fb[f] : (e == 1 ? b.fc[f] : b.fa[f]);
                const key = <i64>v * n + <i64>u;
                if (edgeOf.has(key) && root[edgeOf.get(key)] == r) continue;
                eu.push(u);
                ev.push(v);
            }
        }
        if (eu.length < 3) return false;
        used.length = 0;
        for (let k = 0; k < eu.length; k++) used.push(false);
        const at = loopVerts.length;
        let e = 0;
        for (let steps = 0; steps < eu.length; steps++) {
            used[e] = true;
            loopVerts.push(eu[e]);
            let nextE = -1;
            for (let k = 0; k < eu.length; k++) {
                if (!used[k] && eu[k] == ev[e]) {
                    nextE = k;
                    break;
                }
            }
            if (nextE < 0) break;
            e = nextE;
        }
        if (loopVerts.length - at != eu.length || ev[e] != eu[0]) return false;
        // Vertices in the middle of an edge (within the tolerance of the
        // line through their neighbours) are no corners.
        let changed = true;
        while (changed && loopVerts.length - at > 3) {
            changed = false;
            const count = loopVerts.length - at;
            for (let k = 0; k < count; k++) {
                const prev = loopVerts[at + (k + count - 1) % count];
                const cur = loopVerts[at + k];
                const nxt = loopVerts[at + (k + 1) % count];
                if (lineDistance(b, prev, nxt, cur) <= b.tol) {
                    loopVerts.splice(at + k, 1);
                    changed = true;
                    break;
                }
            }
        }
        loopStart.push(loopVerts.length);
        loopRoot.push(r);
    }
    // The vertices: every input index a loop keeps, in input order.
    const keep: Array<i32> = [];
    const seen = new Set<i32>();
    for (let k = 0; k < loopVerts.length; k++) {
        if (seen.has(loopVerts[k])) continue;
        seen.add(loopVerts[k]);
        keep.push(loopVerts[k]);
    }
    keep.sort((x: i32, y: i32): i32 => x - y);
    emitVertices(out, b.p, keep);
    out.faceStart.length = 0;
    out.faceStart.push(0);
    for (let f = 0; f + 1 < loopStart.length; f++) {
        const s = loopStart[f], e = loopStart[f + 1];
        const count = e - s;
        // Starts at its lowest vertex.
        let low = 0;
        for (let k = 1; k < count; k++) if (loopVerts[s + k] < loopVerts[s + low]) low = k;
        let nx: f64 = 0, ny: f64 = 0, nz: f64 = 0;
        for (let k = 0; k < count; k++) {
            const i = loopVerts[s + (low + k) % count];
            const j = loopVerts[s + (low + k + 1) % count];
            out.faceVerts.push(vertexIndex(keep, i));
            // Newell's normal.
            nx += (b.y(i) - b.y(j)) * (b.z(i) + b.z(j));
            ny += (b.z(i) - b.z(j)) * (b.x(i) + b.x(j));
            nz += (b.x(i) - b.x(j)) * (b.y(i) + b.y(j));
            // Each edge once: the other face walks it the other way.
            if (i < j) {
                out.edges.push(vertexIndex(keep, i));
                out.edges.push(vertexIndex(keep, j));
            }
        }
        out.faceStart.push(out.faceVerts.length);
        const len = Math.sqrt(nx * nx + ny * ny + nz * nz);
        nx /= len;
        ny /= len;
        nz /= len;
        // Through its outermost corner, so every vertex is on or inside,
        // and so is every corner of its triangles (one in the middle of a
        // face is no vertex, but within the tolerance of its plane only).
        let d = -Infinity;
        for (let k = 0; k < count; k++) {
            const i = loopVerts[s + k];
            d = max<f64>(d, nx * b.x(i) + ny * b.y(i) + nz * b.z(i));
        }
        for (let k = groupFirst[loopRoot[f]]; k >= 0; k = groupNext[k]) {
            const g = tris[k];
            d = max<f64>(d, nx * b.x(b.fa[g]) + ny * b.y(b.fa[g]) + nz * b.z(b.fa[g]));
            d = max<f64>(d, nx * b.x(b.fb[g]) + ny * b.y(b.fb[g]) + nz * b.z(b.fb[g]));
            d = max<f64>(d, nx * b.x(b.fc[g]) + ny * b.y(b.fc[g]) + nz * b.z(b.fc[g]));
        }
        out.planes.push(nx);
        out.planes.push(ny);
        out.planes.push(nz);
        out.planes.push(d);
    }
    return out.faceCount() >= 4;
}

// How badly a solid hull fails to be one (0 when it is): every face's
// loop has at least three corners and a unit normal, every directed edge
// of a loop has its reverse in another loop (closed, each edge once, the
// shape of a sphere), the mean of its corners is behind every face, every
// face's neighbours' corners are behind its plane (within a few
// tolerances: merged faces' planes are fitted), and so are the points
// the build found inside (`dropped`, input indices). QuickHull drops a
// point outside none of a step's new faces, inside the grown hull with
// exact arithmetic; but a face the apex is only within the tolerance of
// goes too, so a step can cut into the hull a little, and a point dropped
// earlier can end up outside. Dropped points, then the corners, are
// checked against every face while that costs at most HULL_CHECK_BUDGET
// distances. The worst amount a point is in front, in tolerances, is the
// failure's size.
function checkHull(out: ConvexHull, input: Array<f64>, dropped: Array<i32>, tol: f64): f64 {
    const v = <i64>out.vertexCount();
    const p = out.points;
    // Directed edge a -> b to its face.
    const faceOf = new Map<i64, i32>();
    for (let f = 0; f < out.faceCount(); f++) {
        const s = out.faceStart[f], e = out.faceStart[f + 1];
        if (e - s < 3) return Infinity;
        const pl = f * 4;
        const nl = out.planes[pl] * out.planes[pl] + out.planes[pl + 1] * out.planes[pl + 1] + out.planes[pl + 2] * out.planes[pl + 2];
        if (!(Math.abs(nl - 1) < 1e-6)) return Infinity;
        for (let k = s; k < e; k++) {
            const key = <i64>out.faceVerts[k] * v + <i64>out.faceVerts[k + 1 < e ? k + 1 : s];
            if (faceOf.has(key)) return Infinity;
            faceOf.set(key, f);
        }
    }
    // One surface the shape of a sphere (V - E + F = 2), with the mean of
    // its corners behind every face (an inside).
    if (out.vertexCount() - faceOf.size / 2 + out.faceCount() != 2) return Infinity;
    let cx: f64 = 0, cy: f64 = 0, cz: f64 = 0;
    for (let i = 0; i < p.length; i += 3) {
        cx += p[i];
        cy += p[i + 1];
        cz += p[i + 2];
    }
    cx /= <f64>v;
    cy /= <f64>v;
    cz /= <f64>v;
    let worst: f64 = 0;
    for (let f = 0; f < out.faceCount(); f++) {
        const s = out.faceStart[f], e = out.faceStart[f + 1];
        const pl = f * 4;
        if (out.planes[pl] * cx + out.planes[pl + 1] * cy + out.planes[pl + 2] * cz - out.planes[pl + 3] >= 0) return Infinity;
        for (let k = s; k < e; k++) {
            const key = <i64>out.faceVerts[k + 1 < e ? k + 1 : s] * v + <i64>out.faceVerts[k];
            if (!faceOf.has(key)) return Infinity;
            const g = faceOf.get(key);
            for (let m = out.faceStart[g]; m < out.faceStart[g + 1]; m++) {
                const i = out.faceVerts[m] * 3;
                const d = out.planes[pl] * p[i] + out.planes[pl + 1] * p[i + 1] + out.planes[pl + 2] * p[i + 2] - out.planes[pl + 3];
                worst = max<f64>(worst, d);
            }
        }
    }
    // Then points against every face, within HULL_CHECK_BUDGET distances:
    // the dropped points first (every one, or an even spread of them),
    // then the corners.
    const faces = out.faceCount();
    let budget = HULL_CHECK_BUDGET / <f64>faces;
    const nd = dropped.length;
    const stride = <f64>nd <= budget ? 1 : <i32>Math.ceil(<f64>nd / budget);
    for (let k = 0; k < nd; k += stride) {
        worst = max<f64>(worst, farthestFront(out, input, dropped[k] * 3));
    }
    budget -= <f64>(nd / stride);
    if (<f64>v <= budget) {
        for (let i = 0; i < p.length; i += 3) worst = max<f64>(worst, farthestFront(out, p, i));
    }
    return worst > HULL_CHECK * tol ? worst / tol : 0;
}

// The farthest point p[o .. o + 3) is in front of a face of the hull.
function farthestFront(out: ConvexHull, p: Array<f64>, o: i32): f64 {
    const x = p[o], y = p[o + 1], z = p[o + 2];
    const pl = out.planes;
    let worst = -Infinity;
    for (let k = 0; k < pl.length; k += 4) worst = max<f64>(worst, pl[k] * x + pl[k + 1] * y + pl[k + 2] * z - pl[k + 3]);
    return worst;
}

// The farthest corner of triangle f in front of the plane n . p = d.
function groupDist(b: Builder, nx: f64, ny: f64, nz: f64, d: f64, f: i32): f64 {
    const a = b.fa[f], c = b.fb[f], e = b.fc[f];
    return max<f64>(nx * b.x(a) + ny * b.y(a) + nz * b.z(a),
        max<f64>(nx * b.x(c) + ny * b.y(c) + nz * b.z(c), nx * b.x(e) + ny * b.y(e) + nz * b.z(e))) - d;
}

function findRoot(parent: Array<i32>, k: i32): i32 {
    let r = k;
    while (parent[r] != r) r = parent[r];
    return r;
}

// The distance of point c from the line through a and b.
function lineDistance(b: Builder, a: i32, e: i32, c: i32): f64 {
    const lx = b.x(e) - b.x(a), ly = b.y(e) - b.y(a), lz = b.z(e) - b.z(a);
    const qx = b.x(c) - b.x(a), qy = b.y(c) - b.y(a), qz = b.z(c) - b.z(a);
    const cx = qy * lz - qz * ly, cy = qz * lx - qx * lz, cz = qx * ly - qy * lx;
    const ll = Math.sqrt(lx * lx + ly * ly + lz * lz);
    if (ll == 0) return Math.sqrt(qx * qx + qy * qy + qz * qz);
    return Math.sqrt(cx * cx + cy * cy + cz * cz) / ll;
}
