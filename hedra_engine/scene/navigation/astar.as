// Derived from Godot Engine 4.4 (MIT); see THIRD_PARTY_NOTICES.md.
//
// The navigation map's graph and its search (docs/engine/NAVIGATION.md
// "Paths"): the polygons a map holds and the ways between them, laid out in
// typed arrays (./map.as builds them at a rebuild), and Godot 4.4's A* over
// them (modules/navigation/3d/nav_mesh_queries_3d.cpp
// _query_task_build_path_corridor), run in a NavQueryScratch so that any
// number of queries, one a job worker, run on one map at once.
//
// The graph. Nodes [0, polyCount) are the regions' polygons, in the map's
// order (regions in tree order, each one's polygons in its mesh's order);
// nodes [polyCount, nodeCount) are the links joined at both ends, each a
// thin polygon of four corners (start, start, end, end), as Godot's link
// polygons are. Each node has an owner (its NavigationRegion3D or
// NavigationLink3D), whose layers, enter_cost and travel_cost it takes.
// A connection from node a to node b is a way across: its pathway (the
// shared edge, the sub-segment of an edge connection, or a link's end
// point) and the edge of b it enters by (-1 for a link's), Godot's
// gd::Edge::Connection.
//
// A connection's kind (NavGraph.connKind): across an edge two polygons
// share, across the overlap of two free edges within the map's
// edge_connection_margin (Godot's edge connection), or into or out of a
// link.
export const NAV_CONN_EDGE: u8 = 0;
export const NAV_CONN_MARGIN: u8 = 1;
export const NAV_CONN_LINK: u8 = 2;

// A polygon edge's state (NavGraph.edgeState, by its first corner): free (a
// border), joined to a neighbour's (the first of the pair, and its twin:
// the debug lines draw the pair once), or free but joined across by an edge
// connection.
export const NAV_EDGE_FREE: u8 = 0;
export const NAV_EDGE_JOINED: u8 = 1;
export const NAV_EDGE_CONNECTED: u8 = 2;
export const NAV_EDGE_JOINED_TWIN: u8 = 3;

// The search, Godot's with three differences (recorded in NAVIGATION.md
// "Where Hedra differs"):
//   - entries and costs are Godot's: a polygon is entered at the point of
//     the pathway nearest the entry of the polygon it is entered from, the
//     cost of the step is the distance between the two entries times the
//     travel_cost of the polygon left; Godot adds a region's enter_cost to
//     the steps out of the first polygon popped from that region (so the
//     last region entered, the target's, is never charged); Hedra adds the
//     owner's enter_cost to the step that enters a polygon of another owner,
//     the target's region and a link included, so a path's cost is the same
//     whichever order the search pops its polygons in;
//   - the heuristic is the straight distance to the end point times the
//     lowest travel_cost of the map (Godot multiplies by the entered
//     polygon's own, which overestimates where a cheaper region lies
//     between: the path found is then not always the cheapest);
//   - the open list's ties go to the lower total cost, then the lower
//     heuristic (Godot's order), then the lower node index (Godot leaves
//     them to its heap): every executor finds the same path.
// As in Godot there is no closed list: a polygon reached again more cheaply
// is opened again. When the open list runs out before the end polygon is
// reached, Godot searches again towards the polygon popped whose entry was
// nearest the target; Hedra takes, among every polygon the search reached
// (the full search already holds the cheapest way to each), the one whose
// closest point to the target is nearest (ties to the lower index), and
// ends the path at that point, without searching again.
//
// Memory: the scratch's arrays are sized to the map (grown at a rebuild,
// or by a query in a scratch made for a smaller map); "visited" is a stamp
// per node against a generation counter, so a query never clears an array
// by a loop; the open list is a binary heap written out here (no closure,
// no Array.sort). A query allocates nothing once its scratch has grown.

import { SceneNode } from "../tree/node";
import { NavigationQueryScratch } from "./api";
import { NavGrid, closestOnTriangle, grownF64, grownI32, keptF64, keptI32 } from "./grid";

// A node's corners are read as (x, y, z) from the graph's px, py, pz.
export class NavGraph {
    polyCount: i32 = 0;
    nodeCount: i32 = 0;
    // Node k's corners are [cornerStart[k], cornerStart[k + 1]).
    cornerStart: Int32Array = new Int32Array(1);
    px: Float64Array = new Float64Array(0);
    py: Float64Array = new Float64Array(0);
    pz: Float64Array = new Float64Array(0);
    // By node: its owner (an index into owners).
    nodeOwner: Int32Array = new Int32Array(0);
    // The owners: the regions taken (in the map's order), then the links
    // joined; their costs and layers as of the rebuild.
    owners: Array<SceneNode> = [];
    ownerCount: i32 = 0;
    ownerTravel: Float64Array = new Float64Array(0);
    ownerEnter: Float64Array = new Float64Array(0);
    ownerLayers: Uint32Array = new Uint32Array(0);
    ownerIsLink: Uint8Array = new Uint8Array(0);
    // CSR by source node: connection c goes to connTarget[c], entering it
    // by its edge connEdge[c] (-1: a link's way), along the pathway
    // connPath[c * 6 .. c * 6 + 6) (start x, y, z, end x, y, z).
    connStart: Int32Array = new Int32Array(1);
    connTarget: Int32Array = new Int32Array(0);
    connEdge: Int32Array = new Int32Array(0);
    connPath: Float64Array = new Float64Array(0);
    // By connection: its kind (NAV_CONN_*).
    connKind: Uint8Array = new Uint8Array(0);
    connCount: i32 = 0;
    // The lowest travel_cost of the owners (the heuristic's factor).
    minTravel: f64 = 1;
    // By polygon: its box (min x, y, z, max x, y, z), its area (m²), its
    // up (the unit normal facing +Y), its island.
    polyBox: Float64Array = new Float64Array(0);
    polyArea: Float64Array = new Float64Array(0);
    polyUp: Float64Array = new Float64Array(0);
    polyIsland: Int32Array = new Int32Array(0);
    // By polygon corner (the edge from that corner to the next): its state
    // (NAV_EDGE_*).
    edgeState: Uint8Array = new Uint8Array(0);
    grid: NavGrid = new NavGrid();

    // The owner node of `node`.
    ownerOf(node: i32): SceneNode {
        return unchecked(this.owners[unchecked(this.nodeOwner[node])]);
    }

    isLink(node: i32): bool {
        return node >= this.polyCount;
    }
}

// What a query works in (see the header): one per job worker.
export class NavQueryScratch extends NavigationQueryScratch {
    // What it is sized for.
    nodes: i32 = 0;
    // By node, valid where stamp == gen: the cost so far, the heuristic,
    // the node entered from (-1: the start) and by which of this node's
    // edges, the pathway crossed (6 numbers) and the entry point (3).
    g: Float64Array = new Float64Array(0);
    h: Float64Array = new Float64Array(0);
    // (g + h, kept for the open list's comparisons)
    f: Float64Array = new Float64Array(0);
    back: Int32Array = new Int32Array(0);
    backEdge: Int32Array = new Int32Array(0);
    backPath: Float64Array = new Float64Array(0);
    entry: Float64Array = new Float64Array(0);
    stamp: Int32Array = new Int32Array(0);
    gen: i32 = 0;
    // The open list: a binary heap of nodes, and each node's place in it
    // (-1: not in it; valid where stamp == gen).
    heap: Int32Array = new Int32Array(0);
    heapPos: Int32Array = new Int32Array(0);
    heapLen: i32 = 0;
    // The closest-polygon search's own stamps (a polygon in several cells
    // is tested once).
    polyStamp: Int32Array = new Int32Array(0);
    polyGen: i32 = 0;
    // A geometry answer (./grid.as writes 3 to 6 numbers).
    tmp: StaticArray<f64> = new StaticArray<f64>(8);
    // The last closest-polygon answer: the point and its squared distance.
    cpX: f64 = 0;
    cpY: f64 = 0;
    cpZ: f64 = 0;
    cpD2: f64 = 0;
    found: ClosestFound = new ClosestFound();
    // The path's begin and end points (the end moved to the nearest
    // reachable point when the target's polygon was not reached).
    bx: f64 = 0;
    by: f64 = 0;
    bz: f64 = 0;
    ex: f64 = 0;
    ey: f64 = 0;
    ez: f64 = 0;
    // Whether the last search reached the end polygon, and how many nodes
    // it popped.
    reached: bool = false;
    searched: i32 = 0;
    // The points being made (./funnel.as): x, y, z and the node each lies
    // on, `count` of them; and the simplification's kept indices.
    ptX: Float64Array = new Float64Array(0);
    ptNode: Int32Array = new Int32Array(0);
    count: i32 = 0;
    keep: Int32Array = new Int32Array(0);
    keepCount: i32 = 0;

    // Grown to a graph of `nodes` nodes (at most 2 x nodes + 4 path points).
    ensure(nodes: i32): void {
        if (nodes <= this.nodes) return;
        const n = nodes;
        this.g = grownF64(this.g, n);
        this.h = grownF64(this.h, n);
        this.f = grownF64(this.f, n);
        this.back = grownI32(this.back, n);
        this.backEdge = grownI32(this.backEdge, n);
        this.backPath = grownF64(this.backPath, n * 6);
        this.entry = grownF64(this.entry, n * 3);
        const old = this.stamp;
        this.stamp = grownI32(this.stamp, n);
        if (this.stamp !== old) this.gen = 0;
        this.heap = grownI32(this.heap, n);
        this.heapPos = grownI32(this.heapPos, n);
        const oldPoly = this.polyStamp;
        this.polyStamp = grownI32(this.polyStamp, n);
        if (this.polyStamp !== oldPoly) this.polyGen = 0;
        const points = n * 2 + 4;
        this.ptX = grownF64(this.ptX, points * 3);
        this.ptNode = grownI32(this.ptNode, points);
        this.keep = grownI32(this.keep, points);
        this.nodes = n;
    }

    // A new generation of stamps (a pass over the array only when the
    // counter wraps, once in 2^31 queries).
    nextGen(): void {
        if (this.gen == i32.MAX_VALUE) {
            this.stamp.fill(0);
            this.gen = 0;
        }
        this.gen++;
    }

    nextPolyGen(): void {
        if (this.polyGen == i32.MAX_VALUE) {
            this.polyStamp.fill(0);
            this.polyGen = 0;
        }
        this.polyGen++;
    }

    // Appends a path point lying on `node`.
    push(x: f64, y: f64, z: f64, node: i32): void {
        const k = this.count;
        if (k >= this.ptNode.length) {
            // (never for a path of the map's own corridor, 2 x nodes + 4
            // points at most; kept safe all the same)
            this.ptX = keptF64(this.ptX, (k + 1) * 6, k * 3);
            this.ptNode = keptI32(this.ptNode, (k + 1) * 2, k);
            this.keep = grownI32(this.keep, (k + 1) * 2);
        }
        unchecked(this.ptX[k * 3] = x);
        unchecked(this.ptX[k * 3 + 1] = y);
        unchecked(this.ptX[k * 3 + 2] = z);
        unchecked(this.ptNode[k] = node);
        this.count = k + 1;
    }

    lastX(): f64 {
        return unchecked(this.ptX[(this.count - 1) * 3]);
    }

    lastY(): f64 {
        return unchecked(this.ptX[(this.count - 1) * 3 + 1]);
    }

    lastZ(): f64 {
        return unchecked(this.ptX[(this.count - 1) * 3 + 2]);
    }

    // The points in the other order (Godot's path_reverse).
    reverse(): void {
        let i = 0;
        let j = this.count - 1;
        const p = this.ptX;
        const nd = this.ptNode;
        while (i < j) {
            for (let c = 0; c < 3; c++) {
                const t = unchecked(p[i * 3 + c]);
                unchecked(p[i * 3 + c] = p[j * 3 + c]);
                unchecked(p[j * 3 + c] = t);
            }
            const t = unchecked(nd[i]);
            unchecked(nd[i] = nd[j]);
            unchecked(nd[j] = t);
            i++;
            j--;
        }
    }
}

// The point of polygon (or link node) `k` nearest (x, y, z), into s.cpX/Y/Z;
// returns its squared distance (the fan of triangles from its first corner,
// as Godot's Face3 loops; the first of equal triangles wins).
export function closestOnPolygon(gr: NavGraph, k: i32, x: f64, y: f64, z: f64, s: NavQueryScratch): f64 {
    const a = unchecked(gr.cornerStart[k]);
    const b = unchecked(gr.cornerStart[k + 1]);
    const px = gr.px, py = gr.py, pz = gr.pz;
    const t = s.tmp;
    let best = Infinity;
    const ax = unchecked(px[a]), ay = unchecked(py[a]), az = unchecked(pz[a]);
    for (let i = a + 2; i < b; i++) {
        const d = closestOnTriangle(x, y, z, ax, ay, az, unchecked(px[i - 1]), unchecked(py[i - 1]), unchecked(pz[i - 1]),
            unchecked(px[i]), unchecked(py[i]), unchecked(pz[i]), t);
        if (d < best) {
            best = d;
            s.cpX = unchecked(t[0]);
            s.cpY = unchecked(t[1]);
            s.cpZ = unchecked(t[2]);
        }
    }
    s.cpD2 = best;
    return best;
}

// The squared distance from (x, y, z) to polygon k's box.
function boxDistance2(gr: NavGraph, k: i32, x: f64, y: f64, z: f64): f64 {
    const b = gr.polyBox;
    const o = k * 6;
    let d: f64 = 0;
    const lx = unchecked(b[o]), ly = unchecked(b[o + 1]), lz = unchecked(b[o + 2]);
    const hx = unchecked(b[o + 3]), hy = unchecked(b[o + 4]), hz = unchecked(b[o + 5]);
    if (x < lx) d += (lx - x) * (lx - x);
    else if (x > hx) d += (x - hx) * (x - hx);
    if (y < ly) d += (ly - y) * (ly - y);
    else if (y > hy) d += (y - hy) * (y - hy);
    if (z < lz) d += (lz - z) * (lz - z);
    else if (z > hz) d += (z - hz) * (z - hz);
    return d;
}

// The polygon of `layers` (an owner's layers meeting them) nearest
// (x, y, z), by its closest point, ties to the lower index, within
// sqrt(maxD2) (strictly nearer: Godot's link radius), or -1; its point is
// left in s.cpX/Y/Z and its squared distance in s.cpD2. Walks the grid's
// rings outwards from the point's cell and stops once a ring lies farther
// than the best found. Allocates nothing.
export function closestPolygonIn(gr: NavGraph, s: NavQueryScratch, x: f64, y: f64, z: f64, layers: u32,
    maxD2: f64 = Infinity): i32 {
    const grid = gr.grid;
    const w = grid.width;
    const d = grid.depth;
    s.cpD2 = Infinity;
    if (w == 0 || gr.polyCount == 0) return -1;
    // (a point that is not finite, from a converter or a zero-scaled
    // parent, is near no polygon)
    if (!isFinite(x) || !isFinite(y) || !isFinite(z)) return -1;
    s.ensure(gr.nodeCount);
    s.nextPolyGen();
    const cx = grid.rawCol(x);
    const cz = grid.rawRow(z);
    const cell = grid.cell;
    // (the ring that first meets the grid, and the last one that does)
    const toX = cx < 0 ? -cx : cx >= w ? cx - (w - 1) : 0;
    const toZ = cz < 0 ? -cz : cz >= d ? cz - (d - 1) : 0;
    const first = max<i32>(toX, toZ);
    const last = max<i32>(max<i32>(abs<i32>(cx), abs<i32>(cx - (w - 1))), max<i32>(abs<i32>(cz), abs<i32>(cz - (d - 1))));
    const found = s.found;
    found.best = -1;
    found.d2 = maxD2;
    for (let r = first; r <= last; r++) {
        if (r >= 2) {
            const near = <f64>(r - 1) * cell;
            if (near * near > found.d2) break;
        }
        const z0 = max<i32>(cz - r, 0), z1 = min<i32>(cz + r, d - 1);
        for (let row = z0; row <= z1; row++) {
            if (row == cz - r || row == cz + r) {
                // (the ring's top and bottom rows, whole)
                const c0 = max<i32>(cx - r, 0), c1 = min<i32>(cx + r, w - 1);
                for (let col = c0; col <= c1; col++) scanCell(gr, s, row * w + col, x, y, z, layers, found);
            } else {
                // (its inner rows: the two side cells)
                if (cx - r >= 0 && cx - r < w) scanCell(gr, s, row * w + cx - r, x, y, z, layers, found);
                if (cx + r >= 0 && cx + r < w) scanCell(gr, s, row * w + cx + r, x, y, z, layers, found);
            }
        }
    }
    if (found.best < 0) {
        s.cpD2 = Infinity;
        return -1;
    }
    s.cpX = found.x;
    s.cpY = found.y;
    s.cpZ = found.z;
    s.cpD2 = found.d2;
    return found.best;
}

// The closest-polygon search's best so far (one a scratch: kept there so
// a search allocates nothing).
export class ClosestFound {
    best: i32 = -1;
    d2: f64 = Infinity;
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
}

// The polygons of grid cell `c` tested against `found`.
function scanCell(gr: NavGraph, s: NavQueryScratch, c: i32, x: f64, y: f64, z: f64, layers: u32, found: ClosestFound): void {
    const grid = gr.grid;
    const items = grid.items;
    const stamps = s.polyStamp;
    const pg = s.polyGen;
    const ia = unchecked(grid.starts[c]), ib = unchecked(grid.starts[c + 1]);
    for (let i = ia; i < ib; i++) {
        const k = unchecked(items[i]);
        if (unchecked(stamps[k]) == pg) continue;
        unchecked(stamps[k] = pg);
        if ((unchecked(gr.ownerLayers[unchecked(gr.nodeOwner[k])]) & layers) == 0) continue;
        const best = found.best;
        const bd = boxDistance2(gr, k, x, y, z);
        if (bd > found.d2 || (bd == found.d2 && (best < 0 || k > best))) continue;
        const dk = closestOnPolygon(gr, k, x, y, z, s);
        if (dk < found.d2 || (dk == found.d2 && best >= 0 && k < best)) {
            found.best = k;
            found.d2 = dk;
            found.x = s.cpX;
            found.y = s.cpY;
            found.z = s.cpZ;
        }
    }
}

// --- the open list

function heapLess(s: NavQueryScratch, a: i32, b: i32): bool {
    const fa = unchecked(s.f[a]);
    const fb = unchecked(s.f[b]);
    if (fa != fb) return fa < fb;
    const ha = unchecked(s.h[a]);
    const hb = unchecked(s.h[b]);
    if (ha != hb) return ha < hb;
    return a < b;
}

function heapSet(s: NavQueryScratch, at: i32, node: i32): void {
    unchecked(s.heap[at] = node);
    unchecked(s.heapPos[node] = at);
}

function siftUp(s: NavQueryScratch, at: i32): void {
    const heap = s.heap;
    const node = unchecked(heap[at]);
    let i = at;
    while (i > 0) {
        const parent = (i - 1) >> 1;
        const p = unchecked(heap[parent]);
        if (!heapLess(s, node, p)) break;
        heapSet(s, i, p);
        i = parent;
    }
    heapSet(s, i, node);
}

function siftDown(s: NavQueryScratch, at: i32): void {
    const heap = s.heap;
    const n = s.heapLen;
    const node = unchecked(heap[at]);
    let i = at;
    while (true) {
        const l = i * 2 + 1;
        if (l >= n) break;
        let c = l;
        const r = l + 1;
        if (r < n && heapLess(s, unchecked(heap[r]), unchecked(heap[l]))) c = r;
        const child = unchecked(heap[c]);
        if (!heapLess(s, child, node)) break;
        heapSet(s, i, child);
        i = c;
    }
    heapSet(s, i, node);
}

function heapPush(s: NavQueryScratch, node: i32): void {
    const at = s.heapLen;
    s.heapLen = at + 1;
    heapSet(s, at, node);
    siftUp(s, at);
}

function heapPop(s: NavQueryScratch): i32 {
    const heap = s.heap;
    const top = unchecked(heap[0]);
    unchecked(s.heapPos[top] = -1);
    const n = s.heapLen - 1;
    s.heapLen = n;
    if (n > 0) {
        heapSet(s, 0, unchecked(heap[n]));
        siftDown(s, 0);
    }
    return top;
}

// Node `k` first met in this search: unreached.
function touch(s: NavQueryScratch, k: i32): void {
    if (unchecked(s.stamp[k]) == s.gen) return;
    unchecked(s.stamp[k] = s.gen);
    unchecked(s.g[k] = Infinity);
    unchecked(s.h[k] = 0);
    unchecked(s.back[k] = -1);
    unchecked(s.backEdge[k] = -1);
    unchecked(s.heapPos[k] = -1);
}

// Godot's A* (see the header) from polygon `begin` (at s.bx/by/bz) to
// polygon `end` (at s.ex/ey/ez) over the nodes whose owners' layers meet
// `layers`, towards the target (tx, ty, tz) for the unreachable case.
// Returns the node the path ends on: `end` (s.reached), or the reached
// polygon nearest the target (s.ex/ey/ez moved to its closest point). The
// way back is s.back from it. `begin` != `end`.
export function searchPolygons(gr: NavGraph, s: NavQueryScratch, begin: i32, end: i32, layers: u32, tx: f64, ty: f64,
    tz: f64): i32 {
    s.ensure(gr.nodeCount);
    s.nextGen();
    s.heapLen = 0;
    s.searched = 0;
    s.reached = false;
    const minTravel = gr.minTravel;
    const ex = s.ex, ey = s.ey, ez = s.ez;
    touch(s, begin);
    unchecked(s.g[begin] = 0);
    {
        const dx = s.bx - ex, dy = s.by - ey, dz = s.bz - ez;
        unchecked(s.h[begin] = Math.sqrt(dx * dx + dy * dy + dz * dz) * minTravel);
        unchecked(s.f[begin] = s.h[begin]);
    }
    const bp = begin * 6;
    unchecked(s.backPath[bp] = s.bx);
    unchecked(s.backPath[bp + 1] = s.by);
    unchecked(s.backPath[bp + 2] = s.bz);
    unchecked(s.backPath[bp + 3] = s.bx);
    unchecked(s.backPath[bp + 4] = s.by);
    unchecked(s.backPath[bp + 5] = s.bz);
    unchecked(s.entry[begin * 3] = s.bx);
    unchecked(s.entry[begin * 3 + 1] = s.by);
    unchecked(s.entry[begin * 3 + 2] = s.bz);
    const owners = gr.nodeOwner;
    const ownerLayers = gr.ownerLayers;
    const ownerTravel = gr.ownerTravel;
    const ownerEnter = gr.ownerEnter;
    const connStart = gr.connStart;
    const connTarget = gr.connTarget;
    const connEdge = gr.connEdge;
    const connPath = gr.connPath;
    let cur = begin;
    while (true) {
        s.searched++;
        if (cur == end) {
            s.reached = true;
            return end;
        }
        const ownCur = unchecked(owners[cur]);
        const travel = unchecked(ownerTravel[ownCur]);
        const gCur = unchecked(s.g[cur]);
        const qx = unchecked(s.entry[cur * 3]);
        const qy = unchecked(s.entry[cur * 3 + 1]);
        const qz = unchecked(s.entry[cur * 3 + 2]);
        const ca = unchecked(connStart[cur]);
        const cb = unchecked(connStart[cur + 1]);
        const from = unchecked(s.back[cur]);
        for (let c = ca; c < cb; c++) {
            const nb = unchecked(connTarget[c]);
            // (the way back to the polygon `cur` was entered from never
            // lowers its cost: every step costs 0 or more)
            if (nb == from) continue;
            const ownNb = unchecked(owners[nb]);
            if ((unchecked(ownerLayers[ownNb]) & layers) == 0) continue;
            const o = c * 6;
            const p0x = unchecked(connPath[o]), p0y = unchecked(connPath[o + 1]), p0z = unchecked(connPath[o + 2]);
            const p1x = unchecked(connPath[o + 3]), p1y = unchecked(connPath[o + 4]), p1z = unchecked(connPath[o + 5]);
            // (Godot's get_closest_point_to_segment, written out: the
            // search's inner loop)
            const sx = p1x - p0x, sy = p1y - p0y, sz = p1z - p0z;
            const l2 = sx * sx + sy * sy + sz * sz;
            let nx = p0x, ny = p0y, nz = p0z;
            if (l2 >= 1e-20) {
                const u = ((qx - p0x) * sx + (qy - p0y) * sy + (qz - p0z) * sz) / l2;
                if (u >= 1) {
                    nx = p1x;
                    ny = p1y;
                    nz = p1z;
                } else if (u > 0) {
                    nx = p0x + sx * u;
                    ny = p0y + sy * u;
                    nz = p0z + sz * u;
                }
            }
            const ddx = nx - qx, ddy = ny - qy, ddz = nz - qz;
            let cost = gCur + Math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz) * travel;
            if (ownNb != ownCur) cost += unchecked(ownerEnter[ownNb]);
            touch(s, nb);
            if (cost < unchecked(s.g[nb])) {
                unchecked(s.g[nb] = cost);
                const hx = nx - ex, hy = ny - ey, hz = nz - ez;
                const hn = Math.sqrt(hx * hx + hy * hy + hz * hz) * minTravel;
                unchecked(s.h[nb] = hn);
                unchecked(s.f[nb] = cost + hn);
                unchecked(s.back[nb] = cur);
                unchecked(s.backEdge[nb] = unchecked(connEdge[c]));
                const q = nb * 6;
                unchecked(s.backPath[q] = p0x);
                unchecked(s.backPath[q + 1] = p0y);
                unchecked(s.backPath[q + 2] = p0z);
                unchecked(s.backPath[q + 3] = p1x);
                unchecked(s.backPath[q + 4] = p1y);
                unchecked(s.backPath[q + 5] = p1z);
                unchecked(s.entry[nb * 3] = nx);
                unchecked(s.entry[nb * 3 + 1] = ny);
                unchecked(s.entry[nb * 3 + 2] = nz);
                const at = unchecked(s.heapPos[nb]);
                if (at >= 0) siftUp(s, at);
                else heapPush(s, nb);
            }
        }
        if (s.heapLen == 0) break;
        cur = heapPop(s);
    }
    // The end polygon was not reached: the reached polygon nearest the
    // target (see the header).
    let best = begin;
    let bestD2 = closestOnPolygon(gr, begin, tx, ty, tz, s);
    let bx = s.cpX, by = s.cpY, bz = s.cpZ;
    const polys = gr.polyCount;
    const stamp = s.stamp;
    const gen = s.gen;
    for (let k = 0; k < polys; k++) {
        if (k == begin || unchecked(stamp[k]) != gen || unchecked(s.g[k]) == Infinity) continue;
        const dk = closestOnPolygon(gr, k, tx, ty, tz, s);
        if (dk < bestD2 || (dk == bestD2 && k < best)) {
            best = k;
            bestD2 = dk;
            bx = s.cpX;
            by = s.cpY;
            bz = s.cpZ;
        }
    }
    s.ex = bx;
    s.ey = by;
    s.ez = bz;
    return best;
}
