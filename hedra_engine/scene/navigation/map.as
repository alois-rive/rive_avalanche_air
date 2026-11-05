// Derived from Godot Engine 4.4 (MIT); see THIRD_PARTY_NOTICES.md.
//
// The navigation map of a scene tree (milestone 63, docs/engine/
// NAVIGATION.md "The map"): Godot's NavMap. Every enabled
// NavigationRegion3D's polygons in the main world (not a SubViewport's own
// world, as the interaction world leaves them), placed by the region's
// global transform, their corners joined on the grid of the settings'
// cell_size and cell_height (times merge_rasterizer_cell_scale), so that
// polygons sharing an edge are neighbours; free edges of different regions
// within edge_connection_margin joined (use_edge_connections, the region's
// and the map's); each enabled NavigationLink3D's ends joined to the
// nearest polygon within link_connection_radius. Rebuilt by `sync` only
// when a region's fields, mesh version or global transform, a link's
// fields or transform, or the set of regions and links changed: then the
// iteration id moves, and every agent asks for a new path. A sync that
// found nothing changed allocates nothing.
//
// Queries (./api.as NavigationMap's): A* over the polygons (./astar.as:
// Godot's costs: the distance between entry points times the region's
// travel_cost, plus enter_cost on entering another region, a link's own
// costs), the path to an unreachable target ending at the reachable point
// nearest it, then the post-processing (./funnel.as) and the
// simplification; closest points over a grid of the polygons' boxes
// (./grid.as). Every query runs in a scratch (./astar.as NavQueryScratch:
// one per job worker), allocates nothing once its arrays have grown, and
// gives the same answer on every executor. The last answers of getPath are
// cached by (origin, target, layers, optimize) for the current iteration.
//
// Godot 4.4's rules (modules/navigation/3d/nav_map_builder_3d.cpp,
// nav_region.cpp, nav_mesh_queries_3d.cpp), and where Hedra differs:
//   - a corner's key is floor(position / merge cell) on each axis, the
//     merge cell (cell_size, cell_height, cell_size) x
//     merge_rasterizer_cell_scale (at least 0.001); an edge's key is its two
//     corners' keys in order, so either winding joins the same; an edge key
//     met by more than two edges joins the first two (the map's order:
//     Godot's is its hash order), and Godot's error there is not repeated;
//   - an edge connection joins a free edge of one region to a free edge of
//     another whose ends lie within edge_connection_margin of it, along
//     the overlap of the two, both ways (Godot's formulas); free edges are
//     taken in the order of their keys (Godot's hash order), which changes
//     only the order of a polygon's connections;
//   - a link's ends join the nearest point of any polygon of the map within
//     link_connection_radius (strictly), whatever the polygon's layers:
//     Godot's (a query then crosses the link only when its layers meet the
//     link's and the polygons' beyond it);
//   - a region that is disabled, whose mesh is not valid or has a polygon
//     that is not convex adds no polygon at all (Godot keeps a disabled
//     region's polygons for the closest-point queries; a non-convex polygon
//     is Godot's undefined case);
//   - the closest-point queries' normal is the polygon's unit normal facing
//     +Y (Godot's is the unnormalised cross product of its first corners);
//   - getRandomPoint draws from the map's own xorshift32 stream, seeded
//     0x9E3779B9 at every rebuild (Godot's from the engine's random), so a
//     scene's random points are the same on every run.
//
// Memory: a rebuild reuses the map's arrays (they grow to the largest map
// it held, never shrink); the region and link lists are found again only
// when the tree's structure moved (treeStructureEpoch), by a walk into
// kept arrays.

import { Mat4, Vec3 } from "../../base/vecmath";
import { SceneTree } from "../tree/tree";
import { NavigationLink3D, NavigationRegion3D, SceneNode, treeStructureEpoch } from "../tree/node";
import { inOwnWorld } from "../tree/viewports";
import { NavigationMesh } from "../resource/navigation_mesh";
import {
    ALL_NAVIGATION_LAYERS, NavigationMap, NavigationPathQueryParameters3D, NavigationPathQueryResult3D,
    NavigationQueryScratch, PATH_METADATA_INCLUDE_NONE, PATH_METADATA_INCLUDE_OWNERS, PATH_METADATA_INCLUDE_RIDS,
    PATH_METADATA_INCLUDE_TYPES, PATH_POSTPROCESSING_CORRIDORFUNNEL, PATH_POSTPROCESSING_EDGECENTERED,
    PATH_POSTPROCESSING_NONE, PATH_SEGMENT_TYPE_LINK, PATH_SEGMENT_TYPE_REGION,
} from "./api";
import { NavigationSettings } from "./settings";
import {
    NAV_CONN_EDGE, NAV_CONN_LINK, NAV_CONN_MARGIN, NAV_EDGE_CONNECTED, NAV_EDGE_JOINED, NAV_EDGE_JOINED_TWIN, NavGraph,
    NavQueryScratch, closestPolygonIn, searchPolygons,
} from "./astar";
import { corridorFunnelInto, edgeCenteredInto, entriesInto, simplifyPathInto } from "./funnel";
import {
    closestBetweenSegments, closestOnTriangle, grownF64, grownI32, grownU32, grownU8, keptF64, keptI32, keptU8,
    segmentMeetsTriangle,
} from "./grid";

// How many answers of getPath the map keeps (a round robin).
export const NAV_PATH_CACHE_SIZE: i32 = 16;

// The seed of the map's random points (the golden ratio's 32 bits).
export const NAV_RANDOM_SEED: u32 = 0x9E3779B9;

// What a map holds as of its last sync (`hedra inspect --navmesh`, the
// editor's statistics, the run time's status).
export class NavMapStats {
    regions: i32 = 0;
    polygons: i32 = 0;
    vertices: i32 = 0;
    // Polygon edges: joined to a neighbour, free (a border), and the free
    // edges joined across regions by edge_connection_margin.
    edges: i32 = 0;
    mergedEdges: i32 = 0;
    freeEdges: i32 = 0;
    edgeConnections: i32 = 0;
    // Links: every enabled one, and those with both ends joined.
    links: i32 = 0;
    linksConnected: i32 = 0;
    // Groups of polygons joined to each other (by edges and links).
    islands: i32 = 0;
    // The polygons' area, square metres.
    area: f64 = 0;

    reset(): void {
        this.regions = 0;
        this.polygons = 0;
        this.vertices = 0;
        this.edges = 0;
        this.mergedEdges = 0;
        this.freeEdges = 0;
        this.edgeConnections = 0;
        this.links = 0;
        this.linksConnected = 0;
        this.islands = 0;
        this.area = 0;
    }
}

// One region as the map sees it (NavMap.regionStats): whether the map took
// its polygons, and its mesh's polygons, vertices, area and box in scene
// space (the box only when it has a polygon), and whether every polygon is
// convex.
export class NavRegionStats {
    taken: bool = false;
    polygons: i32 = 0;
    vertices: i32 = 0;
    area: f64 = 0;
    hasBounds: bool = false;
    min: Vec3 = Vec3(0, 0, 0);
    max: Vec3 = Vec3(0, 0, 0);
    convex: bool = true;
}

// A kept getPath answer.
class PathCacheEntry {
    iteration: i32 = -1;
    ox: u32 = 0;
    oy: u32 = 0;
    oz: u32 = 0;
    tx: u32 = 0;
    ty: u32 = 0;
    tz: u32 = 0;
    layers: u32 = 0;
    optimize: bool = false;
    path: Array<Vec3> = [];
}

// The fields kept per region (enabled, layers, enter, travel, edge
// connections, mesh version, mesh valid, 12 numbers of the global
// transform) and per link (enabled, bidirectional, layers, enter, travel,
// global start and end).
const REGION_KEEP: i32 = 19;
const LINK_KEEP: i32 = 11;

// Whether two kept numbers are the same (NaN the same as NaN, so that a
// transform gone NaN does not rebuild the map each frame).
function same(a: f64, b: f64): bool {
    return a == b || (isNaN(a) && isNaN(b));
}

// `keep[at]` set to `v`; whether it was another number.
function keepNumber(keep: Float64Array, at: i32, v: f64): bool {
    const was = unchecked(keep[at]);
    if (same(was, v)) return false;
    unchecked(keep[at] = v);
    return true;
}

function dist2(ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64): f64 {
    const dx = ax - bx, dy = ay - by, dz = az - bz;
    return dx * dx + dy * dy + dz * dz;
}

// Vertex `i` of `v` through `g`.
function placed(g: Mat4, v: Float32Array, i: i32): Vec3 {
    return g.transformPoint3(Vec3(v[i * 3], v[i * 3 + 1], v[i * 3 + 2]));
}

// The f32 bits of a number, for the cache's exact keys.
function bits(v: f32): u32 {
    return reinterpret<u32>(v);
}

// Whether every polygon of `m` is convex (in its own space: a transform
// keeps convexity), either winding, collinear corners allowed.
export function navigationMeshConvex(m: NavigationMesh): bool {
    const p = m.polygonCount();
    const v = m.vertices;
    const starts = m.polygonStarts;
    const idx = m.polygonIndices;
    if (!m.valid) return true;
    for (let k = 0; k < p; k++) {
        const a = unchecked(starts[k]);
        const n = unchecked(starts[k + 1]) - a;
        if (n <= 3) continue;
        // (Newell's normal, then every turn against it)
        let nx: f64 = 0, ny: f64 = 0, nz: f64 = 0;
        for (let i = 0; i < n; i++) {
            const c = unchecked(idx[a + i]) * 3;
            const d = unchecked(idx[a + (i + 1) % n]) * 3;
            const cx = <f64>unchecked(v[c]), cy = <f64>unchecked(v[c + 1]), cz = <f64>unchecked(v[c + 2]);
            const dx = <f64>unchecked(v[d]), dy = <f64>unchecked(v[d + 1]), dz = <f64>unchecked(v[d + 2]);
            nx += (cy - dy) * (cz + dz);
            ny += (cz - dz) * (cx + dx);
            nz += (cx - dx) * (cy + dy);
        }
        const nl = Math.sqrt(nx * nx + ny * ny + nz * nz);
        for (let i = 0; i < n; i++) {
            const c0 = unchecked(idx[a + i]) * 3;
            const c1 = unchecked(idx[a + (i + 1) % n]) * 3;
            const c2 = unchecked(idx[a + (i + 2) % n]) * 3;
            const e1x = <f64>v[c1] - <f64>v[c0], e1y = <f64>v[c1 + 1] - <f64>v[c0 + 1], e1z = <f64>v[c1 + 2] - <f64>v[c0 + 2];
            const e2x = <f64>v[c2] - <f64>v[c1], e2y = <f64>v[c2 + 1] - <f64>v[c1 + 1], e2z = <f64>v[c2 + 2] - <f64>v[c1 + 2];
            const tx = e1y * e2z - e1z * e2y;
            const ty = e1z * e2x - e1x * e2z;
            const tz = e1x * e2y - e1y * e2x;
            const turn = tx * nx + ty * ny + tz * nz;
            const scale = Math.sqrt((e1x * e1x + e1y * e1y + e1z * e1z) * (e2x * e2x + e2y * e2y + e2z * e2z)) * nl;
            if (turn < -1e-6 * scale) return false;
        }
    }
    return true;
}

// Whether `region`'s polygons can be part of a map: enabled, a valid mesh
// with a polygon, every polygon convex.
export function navigationRegionUsable(region: NavigationRegion3D): bool {
    const m = region.navigationMesh;
    if (!region.enabled || m == null || !m.valid || m.polygonCount() == 0) return false;
    return navigationMeshConvex(m);
}

// The most a merge key may be: a corner whose floor(p / cell) passes it
// would not convert to an i32 (the conversion traps).
const KEY_LIMIT: f32 = 2147483520;

// Whether every corner of `region`'s polygons, placed, is finite and keys
// within the i32 range: a NaN (a zero-scaled parent, a converter's) or a
// coordinate as large as 1e12 leaves the region out of the map, as an
// unusable one, instead of trapping.
function regionPlaceable(region: NavigationRegion3D, mcx: f32, mcy: f32): bool {
    const m = region.navigationMesh!;
    const g = region.global();
    const v = m.vertices;
    const n = m.vertexCount();
    for (let i = 0; i < n; i++) {
        const w = placed(g, v, i);
        if (!isFinite(w.x) || !isFinite(w.y) || !isFinite(w.z)) return false;
        if (Mathf.abs(w.x / mcx) >= KEY_LIMIT || Mathf.abs(w.y / mcy) >= KEY_LIMIT
            || Mathf.abs(w.z / mcx) >= KEY_LIMIT) return false;
    }
    return true;
}

export class NavMap extends NavigationMap {
    settings: NavigationSettings = new NavigationSettings();
    // The graph as of the last rebuild (./astar.as).
    graph: NavGraph = new NavGraph();
    // The regions and links of the main world, in tree order, and whether
    // each region's polygons were taken.
    regions: Array<NavigationRegion3D> = [];
    links: Array<NavigationLink3D> = [];
    regionTaken: Uint8Array = new Uint8Array(0);
    // By region: its first polygon in the graph (-1: none taken).
    regionFirst: Int32Array = new Int32Array(0);
    // By link: the polygons its start and end joined (-1: none), the points
    // joined (6 numbers; the link's own end where none joined), its node
    // in the graph (-1: not joined at both ends, or disabled).
    linkStartPoly: Int32Array = new Int32Array(0);
    linkEndPoly: Int32Array = new Int32Array(0);
    linkPoints: Float64Array = new Float64Array(0);
    linkNode: Int32Array = new Int32Array(0);
    // Counters for the tools and the tests: getPath's searches and the
    // answers it gave from its cache, and the nodes the last getPath or
    // queryPath popped (0 for an answer from the cache).
    pathSearches: i32 = 0;
    pathCacheHits: i32 = 0;
    lastSearched: i32 = 0;
    // Rebuilds so far.
    rebuilds: i32 = 0;

    private iteration: i32 = 0;
    private stat: NavMapStats = new NavMapStats();
    private scratch: NavQueryScratch = new NavQueryScratch();
    private tree: SceneTree? = null;
    private epoch: i32 = -1;
    private walked: Array<SceneNode> = [];
    private stack: Array<SceneNode> = [];
    private foundRegions: Array<NavigationRegion3D> = [];
    private foundLinks: Array<NavigationLink3D> = [];
    private regionKeep: Float64Array = new Float64Array(0);
    private regionMeshes: Array<NavigationMesh?> = [];
    private linkKeep: Float64Array = new Float64Array(0);
    private cache: Array<PathCacheEntry> = [];
    private cacheNext: i32 = 0;
    private params: NavigationPathQueryParameters3D = new NavigationPathQueryParameters3D();
    private result: NavigationPathQueryResult3D = new NavigationPathQueryResult3D();
    private rng: u32 = NAV_RANDOM_SEED;
    // A rebuild's working arrays: corner keys (3 a corner), the corner's
    // polygon, edge keys (6 an edge), the edges' order and the merge
    // sort's buffer, the free edges, and the connections before they are
    // sorted by source (source, target, edge, pathway).
    private keys: Int32Array = new Int32Array(0);
    private cornerPoly: Int32Array = new Int32Array(0);
    private edgeKeys: Int32Array = new Int32Array(0);
    private order: Int32Array = new Int32Array(0);
    private orderTmp: Int32Array = new Int32Array(0);
    private free: Int32Array = new Int32Array(0);
    private freeCount: i32 = 0;
    private tSrc: Int32Array = new Int32Array(0);
    private tTgt: Int32Array = new Int32Array(0);
    private tEdge: Int32Array = new Int32Array(0);
    private tPath: Float64Array = new Float64Array(0);
    private tKind: Uint8Array = new Uint8Array(0);
    private tCount: i32 = 0;
    private parent: Int32Array = new Int32Array(0);
    private tmp: StaticArray<f64> = new StaticArray<f64>(8);

    constructor(settings: NavigationSettings? = null) {
        super();
        if (settings != null) this.settings.copyFrom(settings);
        for (let i = 0; i < NAV_PATH_CACHE_SIZE; i++) this.cache.push(new PathCacheEntry());
    }

    iterationId(): i32 {
        return this.iteration;
    }

    cellSize(): f32 {
        return this.settings.cellSize;
    }

    cellHeight(): f32 {
        return this.settings.cellHeight;
    }

    edgeConnectionMargin(): f32 {
        return this.settings.edgeConnectionMargin;
    }

    linkConnectionRadius(): f32 {
        return this.settings.linkConnectionRadius;
    }

    useEdgeConnections(): bool {
        return this.settings.useEdgeConnections;
    }

    // Brings the map up to `tree` (see the header); whether it changed (the
    // iteration id moved). The first sync always builds (iteration 1).
    sync(tree: SceneTree): bool {
        let changed = this.iteration == 0;
        const epoch = treeStructureEpoch();
        if (tree !== this.tree || epoch != this.epoch) {
            this.tree = tree;
            this.epoch = epoch;
            if (this.collect(tree)) changed = true;
        }
        if (this.compareRegions()) changed = true;
        if (this.compareLinks()) changed = true;
        if (!changed) return false;
        this.rebuild();
        this.iteration++;
        this.rebuilds++;
        this.rng = NAV_RANDOM_SEED;
        return true;
    }

    // The regions and links of the tree found again; whether the lists
    // changed.
    private collect(tree: SceneTree): bool {
        tree.walkInto(this.walked, this.stack);
        const fr = this.foundRegions;
        const fl = this.foundLinks;
        fr.length = 0;
        fl.length = 0;
        const w = this.walked;
        for (let i = 0; i < w.length; i++) {
            const n = unchecked(w[i]);
            if (n.freed) continue;
            const isRegion = n instanceof NavigationRegion3D;
            const isLink = n instanceof NavigationLink3D;
            if (!isRegion && !isLink) continue;
            if (inOwnWorld(n)) continue;
            if (isRegion) fr.push(n as NavigationRegion3D);
            else fl.push(n as NavigationLink3D);
        }
        let differ = fr.length != this.regions.length || fl.length != this.links.length;
        for (let i = 0; !differ && i < fr.length; i++) if (unchecked(fr[i]) !== unchecked(this.regions[i])) differ = true;
        for (let i = 0; !differ && i < fl.length; i++) if (unchecked(fl[i]) !== unchecked(this.links[i])) differ = true;
        if (!differ) return false;
        this.regions.length = 0;
        for (let i = 0; i < fr.length; i++) this.regions.push(unchecked(fr[i]));
        this.links.length = 0;
        for (let i = 0; i < fl.length; i++) this.links.push(unchecked(fl[i]));
        this.regionKeep = grownF64(this.regionKeep, fr.length * REGION_KEEP);
        this.linkKeep = grownF64(this.linkKeep, fl.length * LINK_KEEP);
        this.regionMeshes.length = 0;
        for (let i = 0; i < fr.length; i++) this.regionMeshes.push(null);
        this.regionTaken = grownU8(this.regionTaken, fr.length);
        this.regionFirst = grownI32(this.regionFirst, fr.length);
        this.linkStartPoly = grownI32(this.linkStartPoly, fl.length);
        this.linkEndPoly = grownI32(this.linkEndPoly, fl.length);
        this.linkPoints = grownF64(this.linkPoints, fl.length * 6);
        this.linkNode = grownI32(this.linkNode, fl.length);
        return true;
    }

    // Every region's kept fields compared and written; whether one moved.
    private compareRegions(): bool {
        let changed = false;
        const rs = this.regions;
        const keep = this.regionKeep;
        for (let i = 0; i < rs.length; i++) {
            const r = unchecked(rs[i]);
            const m = r.navigationMesh;
            if (m !== unchecked(this.regionMeshes[i])) {
                unchecked(this.regionMeshes[i] = m);
                changed = true;
            }
            const o = i * REGION_KEEP;
            if (keepNumber(keep, o, r.enabled ? 1 : 0)) changed = true;
            if (keepNumber(keep, o + 1, <f64>r.navigationLayers)) changed = true;
            if (keepNumber(keep, o + 2, <f64>r.enterCost)) changed = true;
            if (keepNumber(keep, o + 3, <f64>r.travelCost)) changed = true;
            if (keepNumber(keep, o + 4, r.useEdgeConnections ? 1 : 0)) changed = true;
            if (keepNumber(keep, o + 5, m != null ? <f64>m.version : -1)) changed = true;
            if (keepNumber(keep, o + 6, m != null && m.valid ? 1 : 0)) changed = true;
            const g = r.global();
            if (keepNumber(keep, o + 7, <f64>g.xAxis.x)) changed = true;
            if (keepNumber(keep, o + 8, <f64>g.xAxis.y)) changed = true;
            if (keepNumber(keep, o + 9, <f64>g.xAxis.z)) changed = true;
            if (keepNumber(keep, o + 10, <f64>g.yAxis.x)) changed = true;
            if (keepNumber(keep, o + 11, <f64>g.yAxis.y)) changed = true;
            if (keepNumber(keep, o + 12, <f64>g.yAxis.z)) changed = true;
            if (keepNumber(keep, o + 13, <f64>g.zAxis.x)) changed = true;
            if (keepNumber(keep, o + 14, <f64>g.zAxis.y)) changed = true;
            if (keepNumber(keep, o + 15, <f64>g.zAxis.z)) changed = true;
            if (keepNumber(keep, o + 16, <f64>g.wAxis.x)) changed = true;
            if (keepNumber(keep, o + 17, <f64>g.wAxis.y)) changed = true;
            if (keepNumber(keep, o + 18, <f64>g.wAxis.z)) changed = true;
        }
        return changed;
    }

    private compareLinks(): bool {
        let changed = false;
        const ls = this.links;
        const keep = this.linkKeep;
        for (let i = 0; i < ls.length; i++) {
            const l = unchecked(ls[i]);
            const o = i * LINK_KEEP;
            if (keepNumber(keep, o, l.enabled ? 1 : 0)) changed = true;
            if (keepNumber(keep, o + 1, l.bidirectional ? 1 : 0)) changed = true;
            if (keepNumber(keep, o + 2, <f64>l.navigationLayers)) changed = true;
            if (keepNumber(keep, o + 3, <f64>l.enterCost)) changed = true;
            if (keepNumber(keep, o + 4, <f64>l.travelCost)) changed = true;
            const g = l.global();
            const s = g.transformPoint3(l.startPosition);
            const e = g.transformPoint3(l.endPosition);
            if (keepNumber(keep, o + 5, <f64>s.x)) changed = true;
            if (keepNumber(keep, o + 6, <f64>s.y)) changed = true;
            if (keepNumber(keep, o + 7, <f64>s.z)) changed = true;
            if (keepNumber(keep, o + 8, <f64>e.x)) changed = true;
            if (keepNumber(keep, o + 9, <f64>e.y)) changed = true;
            if (keepNumber(keep, o + 10, <f64>e.z)) changed = true;
        }
        return changed;
    }

    // --- the rebuild

    private rebuild(): void {
        const gr = this.graph;
        const st = this.stat;
        st.reset();
        const settings = this.settings;
        const scale = settings.mergeRasterizerCellScale > <f32>0.001 ? settings.mergeRasterizerCellScale : <f32>0.001;
        const mcx: f32 = settings.cellSize * scale;
        const mcy: f32 = settings.cellHeight * scale;
        const rs = this.regions;
        const ls = this.links;
        // (how much: polygons and corners of the regions taken, links)
        let polys = 0;
        let corners = 0;
        let taken = 0;
        for (let i = 0; i < rs.length; i++) {
            const r = unchecked(rs[i]);
            const use = navigationRegionUsable(r) && regionPlaceable(r, mcx, mcy);
            unchecked(this.regionTaken[i] = use ? 1 : 0);
            unchecked(this.regionFirst[i] = -1);
            if (!use) continue;
            const m = r.navigationMesh!;
            taken++;
            polys += m.polygonCount();
            corners += m.polygonIndices.length;
        }
        const maxNodes = polys + ls.length;
        const maxCorners = corners + ls.length * 4;
        gr.cornerStart = grownI32(gr.cornerStart, maxNodes + 1);
        gr.px = grownF64(gr.px, maxCorners);
        gr.py = grownF64(gr.py, maxCorners);
        gr.pz = grownF64(gr.pz, maxCorners);
        gr.nodeOwner = grownI32(gr.nodeOwner, maxNodes);
        const maxOwners = taken + ls.length;
        gr.ownerTravel = grownF64(gr.ownerTravel, maxOwners);
        gr.ownerEnter = grownF64(gr.ownerEnter, maxOwners);
        gr.ownerLayers = grownU32(gr.ownerLayers, maxOwners);
        gr.ownerIsLink = grownU8(gr.ownerIsLink, maxOwners);
        gr.owners.length = 0;
        gr.ownerCount = 0;
        gr.polyBox = grownF64(gr.polyBox, polys * 6);
        gr.polyArea = grownF64(gr.polyArea, polys);
        gr.polyUp = grownF64(gr.polyUp, polys * 3);
        gr.polyIsland = grownI32(gr.polyIsland, polys);
        gr.edgeState = grownU8(gr.edgeState, corners);
        this.keys = grownI32(this.keys, corners * 3);
        this.cornerPoly = grownI32(this.cornerPoly, corners);
        // 1. the polygons, placed
        let k = 0;
        let c = 0;
        unchecked(gr.cornerStart[0] = 0);
        for (let i = 0; i < rs.length; i++) {
            if (unchecked(this.regionTaken[i]) == 0) continue;
            const r = unchecked(rs[i]);
            const m = r.navigationMesh!;
            const owner = this.addOwner(r, <f64>r.travelCost, <f64>r.enterCost, r.navigationLayers, false);
            unchecked(this.regionFirst[i] = k);
            st.regions++;
            st.vertices += m.vertexCount();
            const g = r.global();
            const v = m.vertices;
            const starts = m.polygonStarts;
            const idx = m.polygonIndices;
            const pc = m.polygonCount();
            for (let p = 0; p < pc; p++) {
                const a = unchecked(starts[p]);
                const b = unchecked(starts[p + 1]);
                const first = c;
                for (let j = a; j < b; j++) {
                    const w = placed(g, v, unchecked(idx[j]));
                    unchecked(gr.px[c] = <f64>w.x);
                    unchecked(gr.py[c] = <f64>w.y);
                    unchecked(gr.pz[c] = <f64>w.z);
                    // (Godot's PointKey: floor of the position over the merge cell, in f32)
                    unchecked(this.keys[c * 3] = <i32>Mathf.floor(w.x / mcx));
                    unchecked(this.keys[c * 3 + 1] = <i32>Mathf.floor(w.y / mcy));
                    unchecked(this.keys[c * 3 + 2] = <i32>Mathf.floor(w.z / mcx));
                    unchecked(this.cornerPoly[c] = k);
                    unchecked(gr.edgeState[c] = 0);
                    c++;
                }
                unchecked(gr.nodeOwner[k] = owner);
                this.placePolygon(k, first, c);
                st.area += unchecked(gr.polyArea[k]);
                k++;
                unchecked(gr.cornerStart[k] = c);
            }
        }
        gr.polyCount = k;
        gr.nodeCount = k;
        st.polygons = k;
        this.tCount = 0;
        // 2. edges joined on their keys
        this.joinEdges(c);
        // 3. edge connections
        if (settings.useEdgeConnections) this.connectFreeEdges();
        // 4. the grid, then the links
        gr.grid.build(gr.polyBox, k, <f64>settings.cellSize * 4);
        this.scratch.ensure(maxNodes);
        this.joinLinks(c);
        // 5. connections by source, islands
        this.sortConnections();
        this.findIslands();
        let minTravel = Infinity;
        for (let o = 0; o < gr.ownerCount; o++) minTravel = Math.min(minTravel, unchecked(gr.ownerTravel[o]));
        gr.minTravel = minTravel == Infinity ? 1 : minTravel;
        this.scratch.ensure(gr.nodeCount);
    }

    private addOwner(n: SceneNode, travel: f64, enter: f64, layers: u32, link: bool): i32 {
        const gr = this.graph;
        const o = gr.ownerCount;
        gr.owners.push(n);
        unchecked(gr.ownerTravel[o] = travel);
        unchecked(gr.ownerEnter[o] = enter);
        unchecked(gr.ownerLayers[o] = layers);
        unchecked(gr.ownerIsLink[o] = link ? 1 : 0);
        gr.ownerCount = o + 1;
        return o;
    }

    // Polygon k's box, area (its fan's triangles, Godot's surface_area) and
    // up (Newell's normal, unit, facing +Y) from its corners [a, b).
    private placePolygon(k: i32, a: i32, b: i32): void {
        const gr = this.graph;
        let lx = Infinity, ly = Infinity, lz = Infinity, hx = -Infinity, hy = -Infinity, hz = -Infinity;
        let nx: f64 = 0, ny: f64 = 0, nz: f64 = 0;
        for (let i = a; i < b; i++) {
            const x = unchecked(gr.px[i]), y = unchecked(gr.py[i]), z = unchecked(gr.pz[i]);
            if (x < lx) lx = x;
            if (y < ly) ly = y;
            if (z < lz) lz = z;
            if (x > hx) hx = x;
            if (y > hy) hy = y;
            if (z > hz) hz = z;
            const j = i + 1 < b ? i + 1 : a;
            const x2 = unchecked(gr.px[j]), y2 = unchecked(gr.py[j]), z2 = unchecked(gr.pz[j]);
            nx += (y - y2) * (z + z2);
            ny += (z - z2) * (x + x2);
            nz += (x - x2) * (y + y2);
        }
        const o = k * 6;
        unchecked(gr.polyBox[o] = lx);
        unchecked(gr.polyBox[o + 1] = ly);
        unchecked(gr.polyBox[o + 2] = lz);
        unchecked(gr.polyBox[o + 3] = hx);
        unchecked(gr.polyBox[o + 4] = hy);
        unchecked(gr.polyBox[o + 5] = hz);
        let area: f64 = 0;
        const ax = unchecked(gr.px[a]), ay = unchecked(gr.py[a]), az = unchecked(gr.pz[a]);
        for (let i = a + 2; i < b; i++) {
            const ux = unchecked(gr.px[i - 1]) - ax, uy = unchecked(gr.py[i - 1]) - ay, uz = unchecked(gr.pz[i - 1]) - az;
            const vx = unchecked(gr.px[i]) - ax, vy = unchecked(gr.py[i]) - ay, vz = unchecked(gr.pz[i]) - az;
            const cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx;
            area += Math.sqrt(cx * cx + cy * cy + cz * cz) * 0.5;
        }
        unchecked(gr.polyArea[k] = area);
        let len = Math.sqrt(nx * nx + ny * ny + nz * nz);
        if (len > 0) {
            if (ny < 0) len = -len;
            nx /= len;
            ny /= len;
            nz /= len;
        } else {
            nx = 0;
            ny = 1;
            nz = 0;
        }
        unchecked(gr.polyUp[k * 3] = nx);
        unchecked(gr.polyUp[k * 3 + 1] = ny);
        unchecked(gr.polyUp[k * 3 + 2] = nz);
    }

    // A connection of `kind` (NAV_CONN_*), before the connections are
    // sorted by source.
    private addConnection(src: i32, tgt: i32, edge: i32, kind: u8, sx: f64, sy: f64, sz: f64, ex: f64, ey: f64,
        ez: f64): void {
        const n = this.tCount;
        if (n >= this.tSrc.length) {
            const cap = max<i32>(64, n * 2);
            this.tSrc = keptI32(this.tSrc, cap, n);
            this.tTgt = keptI32(this.tTgt, cap, n);
            this.tEdge = keptI32(this.tEdge, cap, n);
            this.tPath = keptF64(this.tPath, cap * 6, n * 6);
            this.tKind = keptU8(this.tKind, cap, n);
        }
        unchecked(this.tSrc[n] = src);
        unchecked(this.tTgt[n] = tgt);
        unchecked(this.tEdge[n] = edge);
        unchecked(this.tKind[n] = kind);
        const o = n * 6;
        unchecked(this.tPath[o] = sx);
        unchecked(this.tPath[o + 1] = sy);
        unchecked(this.tPath[o + 2] = sz);
        unchecked(this.tPath[o + 3] = ex);
        unchecked(this.tPath[o + 4] = ey);
        unchecked(this.tPath[o + 5] = ez);
        this.tCount = n + 1;
    }

    // The corner after corner `c` in its polygon.
    private nextCorner(c: i32): i32 {
        const gr = this.graph;
        const k = unchecked(this.cornerPoly[c]);
        const n = c + 1;
        return n < unchecked(gr.cornerStart[k + 1]) ? n : unchecked(gr.cornerStart[k]);
    }

    // Edge e's keys in order (the lower corner key first): Godot's EdgeKey.
    private edgeKeysOf(e: i32): void {
        const keys = this.keys;
        const n = this.nextCorner(e);
        const ax = unchecked(keys[e * 3]), ay = unchecked(keys[e * 3 + 1]), az = unchecked(keys[e * 3 + 2]);
        const bx = unchecked(keys[n * 3]), by = unchecked(keys[n * 3 + 1]), bz = unchecked(keys[n * 3 + 2]);
        const aFirst = ax < bx || (ax == bx && (ay < by || (ay == by && az <= bz)));
        const o = e * 6;
        const ek = this.edgeKeys;
        unchecked(ek[o] = aFirst ? ax : bx);
        unchecked(ek[o + 1] = aFirst ? ay : by);
        unchecked(ek[o + 2] = aFirst ? az : bz);
        unchecked(ek[o + 3] = aFirst ? bx : ax);
        unchecked(ek[o + 4] = aFirst ? by : ay);
        unchecked(ek[o + 5] = aFirst ? bz : az);
    }

    // Edge a before edge b: by their keys, then their index (a total order).
    private edgeBefore(a: i32, b: i32): bool {
        const ek = this.edgeKeys;
        const oa = a * 6;
        const ob = b * 6;
        for (let i = 0; i < 6; i++) {
            const x = unchecked(ek[oa + i]);
            const y = unchecked(ek[ob + i]);
            if (x != y) return x < y;
        }
        return a < b;
    }

    private sameEdgeKey(a: i32, b: i32): bool {
        const ek = this.edgeKeys;
        const oa = a * 6;
        const ob = b * 6;
        for (let i = 0; i < 6; i++) if (unchecked(ek[oa + i]) != unchecked(ek[ob + i])) return false;
        return true;
    }

    // The edges sorted by key (a bottom-up merge sort into kept buffers),
    // then each key's first two edges joined (Godot's
    // _build_step_find_edge_connection_pairs and _merge_edge_connection_pairs).
    private joinEdges(edges: i32): void {
        const gr = this.graph;
        const st = this.stat;
        this.edgeKeys = grownI32(this.edgeKeys, edges * 6);
        this.order = grownI32(this.order, edges);
        this.orderTmp = grownI32(this.orderTmp, edges);
        this.free = grownI32(this.free, edges);
        for (let e = 0; e < edges; e++) {
            this.edgeKeysOf(e);
            unchecked(this.order[e] = e);
        }
        let src = this.order;
        let dst = this.orderTmp;
        for (let width = 1; width < edges; width *= 2) {
            for (let lo = 0; lo < edges; lo += width * 2) {
                const mid = min<i32>(lo + width, edges);
                const hi = min<i32>(lo + width * 2, edges);
                let i = lo, j = mid, o = lo;
                while (i < mid && j < hi) {
                    if (this.edgeBefore(unchecked(src[j]), unchecked(src[i]))) unchecked(dst[o++] = src[j++]);
                    else unchecked(dst[o++] = src[i++]);
                }
                while (i < mid) unchecked(dst[o++] = src[i++]);
                while (j < hi) unchecked(dst[o++] = src[j++]);
            }
            const t = src;
            src = dst;
            dst = t;
        }
        this.order = src;
        this.orderTmp = dst;
        const order = this.order;
        let freeCount = 0;
        let i = 0;
        while (i < edges) {
            let j = i + 1;
            while (j < edges && this.sameEdgeKey(unchecked(order[i]), unchecked(order[j]))) j++;
            st.edges++;
            const e1 = unchecked(order[i]);
            if (j - i >= 2) {
                const e2 = unchecked(order[i + 1]);
                const p1 = unchecked(this.cornerPoly[e1]);
                const p2 = unchecked(this.cornerPoly[e2]);
                st.mergedEdges++;
                // (the second drawn by its neighbour: the debug lines draw a
                // joined edge once)
                unchecked(gr.edgeState[e1] = NAV_EDGE_JOINED);
                unchecked(gr.edgeState[e2] = NAV_EDGE_JOINED_TWIN);
                if (p1 != p2) {
                    const n1 = this.nextCorner(e1);
                    const n2 = this.nextCorner(e2);
                    // (each way along the other's edge, as Godot's connections hold it)
                    this.addConnection(p1, p2, e2 - unchecked(gr.cornerStart[p2]), NAV_CONN_EDGE, unchecked(gr.px[e2]),
                        unchecked(gr.py[e2]), unchecked(gr.pz[e2]), unchecked(gr.px[n2]), unchecked(gr.py[n2]),
                        unchecked(gr.pz[n2]));
                    this.addConnection(p2, p1, e1 - unchecked(gr.cornerStart[p1]), NAV_CONN_EDGE, unchecked(gr.px[e1]),
                        unchecked(gr.py[e1]), unchecked(gr.pz[e1]), unchecked(gr.px[n1]), unchecked(gr.py[n1]),
                        unchecked(gr.pz[n1]));
                }
            } else {
                st.freeEdges++;
                const owner = gr.ownerOf(unchecked(this.cornerPoly[e1])) as NavigationRegion3D;
                if (owner.useEdgeConnections) unchecked(this.free[freeCount++] = e1);
            }
            i = j;
        }
        this.freeCount = freeCount;
    }

    // Godot's _build_step_edge_connection_margin_connections: each free edge
    // joined to the free edges of other regions lying within the margin of
    // it, along their overlap (a box test first, which changes no answer).
    private connectFreeEdges(): void {
        const gr = this.graph;
        const st = this.stat;
        const margin = <f64>this.settings.edgeConnectionMargin;
        const margin2 = margin * margin;
        const free = this.free;
        const n = this.freeCount;
        const px = gr.px, py = gr.py, pz = gr.pz;
        for (let i = 0; i < n; i++) {
            const e = unchecked(free[i]);
            const pe = unchecked(this.cornerPoly[e]);
            const oe = unchecked(gr.nodeOwner[pe]);
            const en = this.nextCorner(e);
            const p1x = unchecked(px[e]), p1y = unchecked(py[e]), p1z = unchecked(pz[e]);
            const p2x = unchecked(px[en]), p2y = unchecked(py[en]), p2z = unchecked(pz[en]);
            const vx = p2x - p1x, vy = p2y - p1y, vz = p2z - p1z;
            const len2 = vx * vx + vy * vy + vz * vz;
            if (len2 == 0) continue;
            const lx = Math.min(p1x, p2x) - margin, hx = Math.max(p1x, p2x) + margin;
            const ly = Math.min(p1y, p2y) - margin, hy = Math.max(p1y, p2y) + margin;
            const lz = Math.min(p1z, p2z) - margin, hz = Math.max(p1z, p2z) + margin;
            for (let j = 0; j < n; j++) {
                if (i == j) continue;
                const f = unchecked(free[j]);
                const pf = unchecked(this.cornerPoly[f]);
                if (unchecked(gr.nodeOwner[pf]) == oe) continue;
                const fn = this.nextCorner(f);
                const o1x = unchecked(px[f]), o1y = unchecked(py[f]), o1z = unchecked(pz[f]);
                const o2x = unchecked(px[fn]), o2y = unchecked(py[fn]), o2z = unchecked(pz[fn]);
                if (Math.max(o1x, o2x) < lx || Math.min(o1x, o2x) > hx || Math.max(o1y, o2y) < ly || Math.min(o1y, o2y) > hy
                    || Math.max(o1z, o2z) < lz || Math.min(o1z, o2z) > hz) continue;
                const r1 = (vx * (o1x - p1x) + vy * (o1y - p1y) + vz * (o1z - p1z)) / len2;
                const r2 = (vx * (o2x - p1x) + vy * (o2y - p1y) + vz * (o2z - p1z)) / len2;
                if ((r1 < 0 && r2 < 0) || (r1 > 1 && r2 > 1)) continue;
                const c1 = r1 < 0 ? 0 : r1 > 1 ? 1 : r1;
                const s1x = vx * c1 + p1x, s1y = vy * c1 + p1y, s1z = vz * c1 + p1z;
                let q1x = o1x, q1y = o1y, q1z = o1z;
                if (!(r1 >= 0 && r1 <= 1)) {
                    const t = (1 - r1) / (r2 - r1);
                    q1x = o1x + (o2x - o1x) * t;
                    q1y = o1y + (o2y - o1y) * t;
                    q1z = o1z + (o2z - o1z) * t;
                }
                if (dist2(q1x, q1y, q1z, s1x, s1y, s1z) > margin2) continue;
                const c2 = r2 < 0 ? 0 : r2 > 1 ? 1 : r2;
                const s2x = vx * c2 + p1x, s2y = vy * c2 + p1y, s2z = vz * c2 + p1z;
                let q2x = o2x, q2y = o2y, q2z = o2z;
                if (!(r2 >= 0 && r2 <= 1)) {
                    const t = (0 - r1) / (r2 - r1);
                    q2x = o1x + (o2x - o1x) * t;
                    q2y = o1y + (o2y - o1y) * t;
                    q2z = o1z + (o2z - o1z) * t;
                }
                if (dist2(q2x, q2y, q2z, s2x, s2y, s2z) > margin2) continue;
                this.addConnection(pe, pf, f - unchecked(gr.cornerStart[pf]), NAV_CONN_MARGIN, (s1x + q1x) * 0.5,
                    (s1y + q1y) * 0.5, (s1z + q1z) * 0.5, (s2x + q2x) * 0.5, (s2y + q2y) * 0.5, (s2z + q2z) * 0.5);
                unchecked(gr.edgeState[e] = NAV_EDGE_CONNECTED);
                st.edgeConnections++;
            }
        }
    }

    // Godot's _build_step_navlink_connections: each enabled link's ends
    // joined to the nearest polygon within link_connection_radius; a link
    // joined at both ends becomes a node of four corners, with its ways in
    // and out (back too when bidirectional).
    private joinLinks(corners: i32): void {
        const gr = this.graph;
        const st = this.stat;
        const ls = this.links;
        const radius = <f64>this.settings.linkConnectionRadius;
        const r2 = radius * radius;
        const s = this.scratch;
        let node = gr.polyCount;
        let c = corners;
        for (let i = 0; i < ls.length; i++) {
            const l = unchecked(ls[i]);
            unchecked(this.linkStartPoly[i] = -1);
            unchecked(this.linkEndPoly[i] = -1);
            unchecked(this.linkNode[i] = -1);
            const g = l.global();
            const a = g.transformPoint3(l.startPosition);
            const b = g.transformPoint3(l.endPosition);
            const o = i * 6;
            unchecked(this.linkPoints[o] = <f64>a.x);
            unchecked(this.linkPoints[o + 1] = <f64>a.y);
            unchecked(this.linkPoints[o + 2] = <f64>a.z);
            unchecked(this.linkPoints[o + 3] = <f64>b.x);
            unchecked(this.linkPoints[o + 4] = <f64>b.y);
            unchecked(this.linkPoints[o + 5] = <f64>b.z);
            if (!l.enabled) continue;
            st.links++;
            const sp = closestPolygonIn(gr, s, <f64>a.x, <f64>a.y, <f64>a.z, ALL_NAVIGATION_LAYERS, r2);
            const sx = s.cpX, sy = s.cpY, sz = s.cpZ;
            const ep = closestPolygonIn(gr, s, <f64>b.x, <f64>b.y, <f64>b.z, ALL_NAVIGATION_LAYERS, r2);
            const ex = s.cpX, ey = s.cpY, ez = s.cpZ;
            unchecked(this.linkStartPoly[i] = sp);
            unchecked(this.linkEndPoly[i] = ep);
            if (sp >= 0) {
                unchecked(this.linkPoints[o] = sx);
                unchecked(this.linkPoints[o + 1] = sy);
                unchecked(this.linkPoints[o + 2] = sz);
            }
            if (ep >= 0) {
                unchecked(this.linkPoints[o + 3] = ex);
                unchecked(this.linkPoints[o + 4] = ey);
                unchecked(this.linkPoints[o + 5] = ez);
            }
            if (sp < 0 || ep < 0) continue;
            st.linksConnected++;
            const owner = this.addOwner(l, <f64>l.travelCost, <f64>l.enterCost, l.navigationLayers, true);
            unchecked(this.linkNode[i] = node);
            unchecked(gr.nodeOwner[node] = owner);
            for (let k = 0; k < 2; k++) {
                unchecked(gr.px[c] = sx);
                unchecked(gr.py[c] = sy);
                unchecked(gr.pz[c] = sz);
                c++;
            }
            for (let k = 0; k < 2; k++) {
                unchecked(gr.px[c] = ex);
                unchecked(gr.py[c] = ey);
                unchecked(gr.pz[c] = ez);
                c++;
            }
            unchecked(gr.cornerStart[node + 1] = c);
            this.addConnection(sp, node, -1, NAV_CONN_LINK, sx, sy, sz, sx, sy, sz);
            this.addConnection(node, ep, -1, NAV_CONN_LINK, ex, ey, ez, ex, ey, ez);
            if (l.bidirectional) {
                this.addConnection(ep, node, -1, NAV_CONN_LINK, ex, ey, ez, ex, ey, ez);
                this.addConnection(node, sp, -1, NAV_CONN_LINK, sx, sy, sz, sx, sy, sz);
            }
            node++;
        }
        gr.nodeCount = node;
    }

    // The connections into the graph's CSR arrays by source, in the order
    // they were made (a stable counting sort).
    private sortConnections(): void {
        const gr = this.graph;
        const n = gr.nodeCount;
        const count = this.tCount;
        gr.connStart = grownI32(gr.connStart, n + 1);
        gr.connTarget = grownI32(gr.connTarget, count);
        gr.connEdge = grownI32(gr.connEdge, count);
        gr.connPath = grownF64(gr.connPath, count * 6);
        gr.connKind = grownU8(gr.connKind, count);
        const starts = gr.connStart;
        for (let i = 0; i <= n; i++) unchecked(starts[i] = 0);
        for (let i = 0; i < count; i++) unchecked(starts[this.tSrc[i] + 1] += 1);
        for (let i = 0; i < n; i++) unchecked(starts[i + 1] += starts[i]);
        // (the union find's array, free until findIslands, as each source's cursor)
        this.parent = grownI32(this.parent, n);
        const cursor = this.parent;
        for (let i = 0; i < n; i++) unchecked(cursor[i] = starts[i]);
        for (let i = 0; i < count; i++) {
            const src = unchecked(this.tSrc[i]);
            const at = unchecked(cursor[src]);
            unchecked(cursor[src] = at + 1);
            unchecked(gr.connTarget[at] = this.tTgt[i]);
            unchecked(gr.connEdge[at] = this.tEdge[i]);
            unchecked(gr.connKind[at] = this.tKind[i]);
            for (let k = 0; k < 6; k++) unchecked(gr.connPath[at * 6 + k] = this.tPath[i * 6 + k]);
        }
        gr.connCount = count;
    }

    private root(a: i32): i32 {
        const parent = this.parent;
        let r = a;
        while (unchecked(parent[r]) != r) r = unchecked(parent[r]);
        // (the path pointed at the root on the way back)
        let x = a;
        while (unchecked(parent[x]) != r) {
            const next = unchecked(parent[x]);
            unchecked(parent[x] = r);
            x = next;
        }
        return r;
    }

    // Islands: the polygons joined by any connection, either way (a union
    // find over the graph), numbered by their first polygon.
    private findIslands(): void {
        const gr = this.graph;
        const n = gr.nodeCount;
        this.parent = grownI32(this.parent, n);
        const parent = this.parent;
        for (let i = 0; i < n; i++) unchecked(parent[i] = i);
        for (let a = 0; a < n; a++) {
            const ca = unchecked(gr.connStart[a]), cb = unchecked(gr.connStart[a + 1]);
            for (let c = ca; c < cb; c++) {
                const ra = this.root(a);
                const rb = this.root(unchecked(gr.connTarget[c]));
                if (ra == rb) continue;
                // (the lower index the root: the islands are numbered in the polygons' order)
                if (ra < rb) unchecked(parent[rb] = ra);
                else unchecked(parent[ra] = rb);
            }
        }
        let islands = 0;
        const polys = gr.polyCount;
        for (let k = 0; k < polys; k++) {
            const r = this.root(k);
            if (r == k) {
                unchecked(gr.polyIsland[k] = islands);
                islands++;
            } else {
                unchecked(gr.polyIsland[k] = gr.polyIsland[r]);
            }
        }
        this.stat.islands = islands;
    }

    // --- what it holds

    // What it holds as of the last sync (the map's own object).
    stats(): NavMapStats {
        return this.stat;
    }

    polygonCount(): i32 {
        return this.graph.polyCount;
    }

    // Polygon k's corners (global, scene space) into `out` (its length set);
    // their count.
    polygonCorners(k: i32, out: Array<Vec3>): i32 {
        const gr = this.graph;
        out.length = 0;
        if (k < 0 || k >= gr.polyCount) return 0;
        const a = unchecked(gr.cornerStart[k]), b = unchecked(gr.cornerStart[k + 1]);
        for (let i = a; i < b; i++) out.push(Vec3(<f32>gr.px[i], <f32>gr.py[i], <f32>gr.pz[i]));
        return b - a;
    }

    // The region polygon k belongs to.
    polygonOwner(k: i32): NavigationRegion3D {
        return this.graph.ownerOf(k) as NavigationRegion3D;
    }

    // The links of the main world (enabled or not).
    linkCount(): i32 {
        return this.links.length;
    }

    // Whether link i's start (`start`) or end joined a polygon.
    linkJoined(i: i32, start: bool): bool {
        if (i < 0 || i >= this.links.length) return false;
        return (start ? unchecked(this.linkStartPoly[i]) : unchecked(this.linkEndPoly[i])) >= 0;
    }

    // The index of `region` among the map's regions (-1: not in the main
    // world, or the map never synced with it).
    regionIndex(region: NavigationRegion3D): i32 {
        for (let i = 0; i < this.regions.length; i++) if (unchecked(this.regions[i]) === region) return i;
        return -1;
    }

    linkIndex(link: NavigationLink3D): i32 {
        for (let i = 0; i < this.links.length; i++) if (unchecked(this.links[i]) === link) return i;
        return -1;
    }

    // `region` as the map sees it (its mesh placed by its global transform
    // now), into `out`; returns `out`. For answers, not a frame loop.
    regionStats(region: NavigationRegion3D, out: NavRegionStats): NavRegionStats {
        const i = this.regionIndex(region);
        out.taken = i >= 0 && unchecked(this.regionTaken[i]) != 0;
        out.polygons = 0;
        out.vertices = 0;
        out.area = 0;
        out.hasBounds = false;
        out.convex = true;
        const m = region.navigationMesh;
        if (m == null) return out;
        out.polygons = m.polygonCount();
        out.vertices = m.vertexCount();
        out.convex = navigationMeshConvex(m);
        if (!m.valid || out.polygons == 0) return out;
        const g = region.global();
        let lo = Vec3(f32.MAX_VALUE, f32.MAX_VALUE, f32.MAX_VALUE);
        let hi = Vec3(-f32.MAX_VALUE, -f32.MAX_VALUE, -f32.MAX_VALUE);
        const v = m.vertices;
        const idx = m.polygonIndices;
        const starts = m.polygonStarts;
        let area: f64 = 0;
        for (let p = 0; p < out.polygons; p++) {
            const a = unchecked(starts[p]);
            const b = unchecked(starts[p + 1]);
            const c0 = placed(g, v, unchecked(idx[a]));
            for (let j = a; j < b; j++) {
                const w = placed(g, v, unchecked(idx[j]));
                lo = Vec3(Mathf.min(lo.x, w.x), Mathf.min(lo.y, w.y), Mathf.min(lo.z, w.z));
                hi = Vec3(Mathf.max(hi.x, w.x), Mathf.max(hi.y, w.y), Mathf.max(hi.z, w.z));
                if (j >= a + 2) {
                    const w1 = placed(g, v, unchecked(idx[j - 1]));
                    area += <f64>(w1 - c0).cross(w - c0).length() * 0.5;
                }
            }
        }
        out.area = area;
        out.hasBounds = true;
        out.min = lo;
        out.max = hi;
        return out;
    }

    // The polygon holding the point of the map nearest `to` (-1: none), for
    // the editor's and the CLI's answers; the point is the own scratch's
    // cpX/Y/Z.
    closestPolygon(to: Vec3): i32 {
        return closestPolygonIn(this.graph, this.scratch, <f64>to.x, <f64>to.y, <f64>to.z, ALL_NAVIGATION_LAYERS);
    }

    // --- queries

    newScratch(): NavigationQueryScratch {
        const s = new NavQueryScratch();
        s.ensure(this.graph.nodeCount);
        return s;
    }

    // The map's own scratch (the main lane's: getPath, queryPath and the
    // closest-point queries run in it).
    ownScratch(): NavQueryScratch {
        return this.scratch;
    }

    queryPath(p: NavigationPathQueryParameters3D, r: NavigationPathQueryResult3D): void {
        this.queryPathIn(this.scratch, p, r);
    }

    queryPathIn(scratch: NavigationQueryScratch, p: NavigationPathQueryParameters3D, r: NavigationPathQueryResult3D): void {
        r.reset();
        const isOwn = scratch instanceof NavQueryScratch;
        const s = isOwn ? scratch as NavQueryScratch : this.scratch;
        const gr = this.graph;
        s.ensure(gr.nodeCount);
        s.searched = 0;
        this.lastSearched = 0;
        const layers = p.navigationLayers;
        const sp = p.startPosition;
        const tp = p.targetPosition;
        const sx = <f64>sp.x, sy = <f64>sp.y, sz = <f64>sp.z;
        const tx = <f64>tp.x, ty = <f64>tp.y, tz = <f64>tp.z;
        // (Godot's _query_task_find_start_end_positions)
        const begin = closestPolygonIn(gr, s, sx, sy, sz, layers);
        if (begin < 0) return;
        s.bx = s.cpX;
        s.by = s.cpY;
        s.bz = s.cpZ;
        const end = closestPolygonIn(gr, s, tx, ty, tz, layers);
        if (end < 0) return;
        s.ex = s.cpX;
        s.ey = s.cpY;
        s.ez = s.cpZ;
        const endD2 = s.cpD2;
        let reached = true;
        if (begin == end) {
            s.count = 0;
            s.push(s.bx, s.by, s.bz, begin);
            s.push(s.ex, s.ey, s.ez, end);
        } else {
            const last = searchPolygons(gr, s, begin, end, layers, tx, ty, tz);
            reached = s.reached;
            if (last == begin) {
                // (the start polygon's own point nearest the target: Godot's
                // two points, no post-processing)
                s.count = 0;
                s.push(s.bx, s.by, s.bz, begin);
                s.push(s.ex, s.ey, s.ez, begin);
            } else {
                const how = p.pathPostprocessing;
                if (how == PATH_POSTPROCESSING_EDGECENTERED) edgeCenteredInto(gr, s, last, begin);
                else if (how == PATH_POSTPROCESSING_NONE) entriesInto(gr, s, last, begin);
                else corridorFunnelInto(gr, s, last, begin);
                s.reverse();
                if (p.simplifyPath) simplifyPathInto(s, <f64>p.simplifyEpsilon);
            }
        }
        // (the target's own polygon may be one of another layer's, nearer
        // the target than any of the query's: then the query's nearest is
        // not the target's, and the target is out of reach, as section 5.3
        // of NAVIGATION.md says; looked for only when the target is off the
        // query's polygons)
        if (reached && layers != ALL_NAVIGATION_LAYERS && endD2 > 1e-6
            && closestPolygonIn(gr, s, tx, ty, tz, ALL_NAVIGATION_LAYERS, endD2) >= 0) {
            reached = false;
        }
        this.lastSearched = s.searched;
        this.writeResult(s, p.metadataFlags, r);
        r.reachedTarget = reached;
        r.searched = s.searched;
    }

    // The scratch's points into `r`, with the metadata the flags ask for:
    // the point's type, its owner node (Godot's RID: the node is the API
    // here) and the owner's serial (Godot's ObjectID).
    private writeResult(s: NavQueryScratch, flags: i32, r: NavigationPathQueryResult3D): void {
        const gr = this.graph;
        const types = (flags & PATH_METADATA_INCLUDE_TYPES) != 0;
        const rids = (flags & PATH_METADATA_INCLUDE_RIDS) != 0;
        const owners = (flags & PATH_METADATA_INCLUDE_OWNERS) != 0;
        let length: f64 = 0;
        const p = s.ptX;
        for (let i = 0; i < s.count; i++) {
            const x = unchecked(p[i * 3]), y = unchecked(p[i * 3 + 1]), z = unchecked(p[i * 3 + 2]);
            r.path.push(Vec3(<f32>x, <f32>y, <f32>z));
            if (i > 0) length += Math.sqrt(dist2(x, y, z, unchecked(p[i * 3 - 3]), unchecked(p[i * 3 - 2]), unchecked(p[i * 3 - 1])));
            const node = unchecked(s.ptNode[i]);
            if (types) r.pathTypes.push(gr.isLink(node) ? PATH_SEGMENT_TYPE_LINK : PATH_SEGMENT_TYPE_REGION);
            // (the owner nodes stand for both Godot's RIDs and the objects its
            // owner ids name: the owners flag alone fills them too, so that an
            // agent's waypoint_reached has its node as Godot's has)
            if (rids || owners) r.pathOwners.push(gr.ownerOf(node));
            if (owners) r.pathOwnerIds.push(<i64>gr.ownerOf(node).serial);
        }
        r.pathLength = <f32>length;
    }

    getPath(origin: Vec3, target: Vec3, optimize: bool, navigationLayers: u32 = 1): Array<Vec3> {
        const it = this.iteration;
        const ox = bits(origin.x), oy = bits(origin.y), oz = bits(origin.z);
        const tx = bits(target.x), ty = bits(target.y), tz = bits(target.z);
        const cache = this.cache;
        for (let i = 0; i < NAV_PATH_CACHE_SIZE; i++) {
            const e = unchecked(cache[i]);
            if (e.iteration == it && e.ox == ox && e.oy == oy && e.oz == oz && e.tx == tx && e.ty == ty && e.tz == tz
                && e.layers == navigationLayers && e.optimize == optimize) {
                this.pathCacheHits++;
                this.lastSearched = 0;
                return e.path;
            }
        }
        const q = this.params;
        q.startPosition = origin;
        q.targetPosition = target;
        q.navigationLayers = navigationLayers;
        q.pathPostprocessing = optimize ? PATH_POSTPROCESSING_CORRIDORFUNNEL : PATH_POSTPROCESSING_EDGECENTERED;
        q.metadataFlags = PATH_METADATA_INCLUDE_NONE;
        q.simplifyPath = false;
        const r = this.result;
        this.queryPathIn(this.scratch, q, r);
        this.pathSearches++;
        const e = unchecked(cache[this.cacheNext]);
        this.cacheNext = (this.cacheNext + 1) % NAV_PATH_CACHE_SIZE;
        e.iteration = it;
        e.ox = ox;
        e.oy = oy;
        e.oz = oz;
        e.tx = tx;
        e.ty = ty;
        e.tz = tz;
        e.layers = navigationLayers;
        e.optimize = optimize;
        const path = e.path;
        path.length = 0;
        for (let i = 0; i < r.path.length; i++) path.push(unchecked(r.path[i]));
        return path;
    }

    getClosestPoint(to: Vec3): Vec3 {
        const k = this.closestPolygon(to);
        if (k < 0) return Vec3(0, 0, 0);
        const s = this.scratch;
        return Vec3(<f32>s.cpX, <f32>s.cpY, <f32>s.cpZ);
    }

    getClosestPointNormal(to: Vec3): Vec3 {
        const k = this.closestPolygon(to);
        if (k < 0) return Vec3(0, 0, 0);
        const up = this.graph.polyUp;
        return Vec3(<f32>up[k * 3], <f32>up[k * 3 + 1], <f32>up[k * 3 + 2]);
    }

    getClosestPointOwner(to: Vec3): SceneNode? {
        const k = this.closestPolygon(to);
        if (k < 0) return null;
        return this.graph.ownerOf(k);
    }

    // Godot's map_iteration_get_closest_point_to_segment, rule for rule:
    // each polygon's triangles met by the segment give the meeting point
    // nearest `start`; until one is met (and without useCollision), the
    // triangles' points nearest either end and the edges' points nearest
    // the segment compete by distance. With useCollision and no polygon
    // met, Godot answers (0, 0, 0), and so does this.
    getClosestPointToSegment(start: Vec3, end: Vec3, useCollision: bool = false): Vec3 {
        const gr = this.graph;
        const fx = <f64>start.x, fy = <f64>start.y, fz = <f64>start.z;
        const tx = <f64>end.x, ty = <f64>end.y, tz = <f64>end.z;
        let collide = useCollision;
        let bx: f64 = 0, by: f64 = 0, bz: f64 = 0;
        let best = Infinity;
        const t = this.tmp;
        const px = gr.px, py = gr.py, pz = gr.pz;
        for (let k = 0; k < gr.polyCount; k++) {
            const a = unchecked(gr.cornerStart[k]), b = unchecked(gr.cornerStart[k + 1]);
            const ax = unchecked(px[a]), ay = unchecked(py[a]), az = unchecked(pz[a]);
            for (let i = a + 2; i < b; i++) {
                const b1x = unchecked(px[i - 1]), b1y = unchecked(py[i - 1]), b1z = unchecked(pz[i - 1]);
                const c1x = unchecked(px[i]), c1y = unchecked(py[i]), c1z = unchecked(pz[i]);
                if (segmentMeetsTriangle(fx, fy, fz, tx, ty, tz, ax, ay, az, b1x, b1y, b1z, c1x, c1y, c1z, t)) {
                    const ix = unchecked(t[0]), iy = unchecked(t[1]), iz = unchecked(t[2]);
                    const d = Math.sqrt(dist2(fx, fy, fz, ix, iy, iz));
                    if (!collide || best > d) {
                        bx = ix;
                        by = iy;
                        bz = iz;
                        best = d;
                    }
                    collide = true;
                } else if (!collide) {
                    const df = Math.sqrt(closestOnTriangle(fx, fy, fz, ax, ay, az, b1x, b1y, b1z, c1x, c1y, c1z, t));
                    if (best > df) {
                        best = df;
                        bx = unchecked(t[0]);
                        by = unchecked(t[1]);
                        bz = unchecked(t[2]);
                    }
                    const dt = Math.sqrt(closestOnTriangle(tx, ty, tz, ax, ay, az, b1x, b1y, b1z, c1x, c1y, c1z, t));
                    if (best > dt) {
                        best = dt;
                        bx = unchecked(t[0]);
                        by = unchecked(t[1]);
                        bz = unchecked(t[2]);
                    }
                }
            }
            if (!collide) {
                for (let i = a; i < b; i++) {
                    const j = i + 1 < b ? i + 1 : a;
                    const d = Math.sqrt(closestBetweenSegments(fx, fy, fz, tx, ty, tz, unchecked(px[i]), unchecked(py[i]),
                        unchecked(pz[i]), unchecked(px[j]), unchecked(py[j]), unchecked(pz[j]), t));
                    if (d < best) {
                        best = d;
                        bx = unchecked(t[3]);
                        by = unchecked(t[4]);
                        bz = unchecked(t[5]);
                    }
                }
            }
        }
        return Vec3(<f32>bx, <f32>by, <f32>bz);
    }

    // The map's stream: xorshift32, a number in [0, 1) from its top 24 bits.
    private random(): f64 {
        let x = this.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        this.rng = x;
        return <f64>(x >> 8) * (1.0 / 16777216.0);
    }

    // Godot's Math::random(from, to) for whole numbers: from to `to`, both
    // included.
    private randomInt(from: i32, to: i32): i32 {
        const n = to - from + 1;
        if (n <= 1) return from;
        const k = <i32>Math.floor(this.random() * <f64>n);
        return from + (k >= n ? n - 1 : k);
    }

    // Whether owner o is a region of `layers`.
    private regionOfLayers(o: i32, layers: u32): bool {
        const gr = this.graph;
        return unchecked(gr.ownerIsLink[o]) == 0 && (unchecked(gr.ownerLayers[o]) & layers) != 0;
    }

    // Godot's map_get_random_point: a region of the layers (by area when
    // `uniformly`, else any one), a polygon of it (the same), a triangle of
    // its fan (the same), then Face3::get_random_point_inside; on the map's
    // own stream (see the header).
    getRandomPoint(navigationLayers: u32, uniformly: bool): Vec3 {
        const gr = this.graph;
        let regions = 0;
        let total: f64 = 0;
        for (let o = 0; o < gr.ownerCount; o++) {
            if (!this.regionOfLayers(o, navigationLayers)) continue;
            regions++;
            total += this.ownerArea(o);
        }
        if (regions == 0) return Vec3(0, 0, 0);
        let owner = -1;
        if (uniformly) {
            if (total == 0) return Vec3(0, 0, 0);
            const at = this.random() * total;
            let acc: f64 = 0;
            for (let o = 0; o < gr.ownerCount; o++) {
                if (!this.regionOfLayers(o, navigationLayers)) continue;
                const a = this.ownerArea(o);
                if (a == 0) continue;
                // (Godot's find_closest: the last start at or below the draw)
                if (acc <= at || owner < 0) owner = o;
                acc += a;
                if (acc > at) break;
            }
        } else {
            let pick = this.randomInt(0, regions - 1);
            for (let o = 0; o < gr.ownerCount; o++) {
                if (!this.regionOfLayers(o, navigationLayers)) continue;
                if (pick == 0) {
                    owner = o;
                    break;
                }
                pick--;
            }
        }
        if (owner < 0) return Vec3(0, 0, 0);
        // (an owner's polygons are consecutive in the graph)
        let first = -1;
        let last = -1;
        for (let k = 0; k < gr.polyCount; k++) {
            if (unchecked(gr.nodeOwner[k]) != owner) continue;
            if (first < 0) first = k;
            last = k;
        }
        if (first < 0) return Vec3(0, 0, 0);
        let poly = -1;
        if (uniformly) {
            let sum: f64 = 0;
            for (let k = first; k <= last; k++) sum += unchecked(gr.polyArea[k]);
            if (sum == 0) return Vec3(0, 0, 0);
            const at = this.random() * sum;
            let acc: f64 = 0;
            for (let k = first; k <= last; k++) {
                const a = unchecked(gr.polyArea[k]);
                if (a == 0) continue;
                if (acc <= at || poly < 0) poly = k;
                acc += a;
                if (acc > at) break;
            }
        } else {
            poly = this.randomInt(first, last);
        }
        if (poly < 0) return Vec3(0, 0, 0);
        const a = unchecked(gr.cornerStart[poly]), b = unchecked(gr.cornerStart[poly + 1]);
        let face = -1;
        if (uniformly) {
            let sum: f64 = 0;
            for (let i = a + 2; i < b; i++) sum += this.faceArea(a, i);
            if (sum == 0) return Vec3(0, 0, 0);
            const at = this.random() * sum;
            let acc: f64 = 0;
            for (let i = a + 2; i < b; i++) {
                const fa = this.faceArea(a, i);
                if (fa == 0) continue;
                if (acc <= at || face < 0) face = i;
                acc += fa;
                if (acc > at) break;
            }
        } else {
            face = a + this.randomInt(2, b - a - 1);
        }
        if (face < 0) return Vec3(0, 0, 0);
        // (Godot's Face3::get_random_point_inside)
        let ra = this.random();
        let rb = this.random();
        if (ra > rb) {
            const t = ra;
            ra = rb;
            rb = t;
        }
        const px = gr.px, py = gr.py, pz = gr.pz;
        const x = unchecked(px[a]) * ra + unchecked(px[face - 1]) * (rb - ra) + unchecked(px[face]) * (1 - rb);
        const y = unchecked(py[a]) * ra + unchecked(py[face - 1]) * (rb - ra) + unchecked(py[face]) * (1 - rb);
        const z = unchecked(pz[a]) * ra + unchecked(pz[face - 1]) * (rb - ra) + unchecked(pz[face]) * (1 - rb);
        return Vec3(<f32>x, <f32>y, <f32>z);
    }

    private ownerArea(o: i32): f64 {
        const gr = this.graph;
        let sum: f64 = 0;
        for (let k = 0; k < gr.polyCount; k++) if (unchecked(gr.nodeOwner[k]) == o) sum += unchecked(gr.polyArea[k]);
        return sum;
    }

    // The area of the fan triangle (a, i - 1, i).
    private faceArea(a: i32, i: i32): f64 {
        const gr = this.graph;
        const px = gr.px, py = gr.py, pz = gr.pz;
        const ux = unchecked(px[i - 1]) - unchecked(px[a]), uy = unchecked(py[i - 1]) - unchecked(py[a]);
        const uz = unchecked(pz[i - 1]) - unchecked(pz[a]);
        const vx = unchecked(px[i]) - unchecked(px[a]), vy = unchecked(py[i]) - unchecked(py[a]);
        const vz = unchecked(pz[i]) - unchecked(pz[a]);
        const cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx;
        return Math.sqrt(cx * cx + cy * cy + cz * cz) * 0.5;
    }
}
