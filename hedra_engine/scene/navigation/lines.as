// Godot's Debug > Visible Navigation as lines (milestone 63,
// docs/engine/NAVIGATION.md "Seeing it"): a map's polygons' edges (the
// free edges, the borders, brighter than the edges joined to a neighbour,
// each joined pair once), the edge connections between regions (each once,
// along the overlap that is their portal), the polygons of a disabled
// region in Godot's disabled colour, the links (an arc of
// NAV_LINK_SEGMENTS from start to end raised by a quarter of its length,
// with an arrow head at the end when one way), and each agent's current
// path (from its actor through the points it has still to reach, a point
// drawn at each; its custom colour and point size when debug_use_custom),
// each avoiding agent's and radius obstacle's circle and each outline
// obstacle's outline (at its foot and its top), in Godot's debug
// navigation colours, for `hedra render --navigation`, Play's --navigation
// and the editor's View › Navigation. Lines are in render space (the
// frame's: Z up, ../space.as), their colours linear, their widths in
// device pixels times `scale`, written in place into `out` from `at` as
// ../interaction/lines.as writes them, so a frame planned again allocates
// nothing; each returns the index after the last.
//
// Godot 4.4's colours are its project settings debug/shapes/navigation/*
// and debug/shapes/avoidance/* (servers/navigation_server_3d.cpp), with
// three differences: the free edges' colour is Hedra's (Godot draws every
// edge in geometry_edge_color, and the faces in random colours, which
// lines do not draw); the avoidance's colours are Godot's with their alpha
// at 1 (Godot's 0.25 and 0.5 are its filled discs' and faces', a line at
// them would hardly show); Godot draws an agent's path only while that
// agent's debug_enabled is on, Hedra's --navigation draws every agent's
// (the flag is kept, and the editor's View › Navigation follows it the
// same way: the whole debug view is the switch).

import { Vec3, Vec4 } from "../../base/vecmath";
import { lin } from "../../render/colors";
import { F_NO_PULL, LineInstance } from "../../render/gpu/layouts";
import { sceneToModel } from "../space";
import { SceneTree } from "../tree/tree";
import { NavigationAgent3D, NavigationObstacle3D, NavigationRegion3D, SceneNode } from "../tree/node";
import { inOwnWorld } from "../tree/viewports";
import { NAV_EDGE_CONNECTED, NAV_EDGE_FREE, NAV_EDGE_JOINED, NAV_CONN_MARGIN } from "./astar";
import { NavMap } from "./map";
import { obstacleFrame } from "./avoidance";

// Godot 4.4's debug navigation colours, sRGB with alpha (see the header):
// geometry_edge_color, geometry_edge_disabled_color, Hedra's free edges,
// edge_connection_color, link_connection_color,
// link_connection_disabled_color, agent_path_color, avoidance's
// agents_radius_color, obstacles_radius_color,
// obstacles_static_edge_pushout_color and _pushin_color.
export const NAV_EDGE_COLOR: Vec4 = Vec4(0.5, 1.0, 1.0, 1.0);
export const NAV_EDGE_DISABLED_COLOR: Vec4 = Vec4(0.5, 0.5, 0.5, 1.0);
export const NAV_FREE_EDGE_COLOR: Vec4 = Vec4(0.0, 1.0, 1.0, 1.0);
export const NAV_EDGE_CONNECTION_COLOR: Vec4 = Vec4(1.0, 0.0, 1.0, 1.0);
export const NAV_LINK_COLOR: Vec4 = Vec4(1.0, 0.5, 1.0, 1.0);
export const NAV_LINK_DISABLED_COLOR: Vec4 = Vec4(0.5, 0.5, 0.5, 1.0);
export const NAV_AGENT_PATH_COLOR: Vec4 = Vec4(1.0, 0.0, 0.0, 1.0);
export const NAV_AVOIDANCE_COLOR: Vec4 = Vec4(1.0, 1.0, 0.0, 1.0);
export const NAV_OBSTACLE_RADIUS_COLOR: Vec4 = Vec4(1.0, 0.5, 0.0, 1.0);
export const NAV_OBSTACLE_PUSHOUT_COLOR: Vec4 = Vec4(1.0, 1.0, 0.0, 1.0);
export const NAV_OBSTACLE_PUSHIN_COLOR: Vec4 = Vec4(1.0, 0.0, 0.0, 1.0);
// Line widths, in device pixels at a scale of 1, and Godot's
// agent_path_point_size (debug_path_custom_point_size's default).
export const NAV_EDGE_WIDTH: f32 = 1;
export const NAV_PATH_WIDTH: f32 = 2;
export const NAV_PATH_POINT_SIZE: f32 = 4;
// A link's arc, and a circle's segments.
export const NAV_LINK_SEGMENTS: i32 = 8;
export const NAV_CIRCLE_SEGMENTS: i32 = 24;
// An arrow head's sides, as a share of the link's length (at most
// NAV_ARROW_MAX metres).
const NAV_ARROW_SHARE: f32 = 0.15;
const NAV_ARROW_MAX: f32 = 0.4;

// What each kind drew, for the tools' answers and the tests: the map's
// lines (edges, edge connections, links' arcs and arrows) and the agents'
// (paths with their points, circles, outlines). Set by each call.
export class NavigationLinesDrawn {
    edges: i32 = 0;
    freeEdges: i32 = 0;
    disabledEdges: i32 = 0;
    edgeConnections: i32 = 0;
    links: i32 = 0;
    paths: i32 = 0;
    circles: i32 = 0;
    outlines: i32 = 0;
}

export const navigationLinesDrawn = new NavigationLinesDrawn();

// The colours, linear (lin runs powf: worked out once).
let cEdge: Vec4 = Vec4(0, 0, 0, 0);
let cDisabled: Vec4 = Vec4(0, 0, 0, 0);
let cFree: Vec4 = Vec4(0, 0, 0, 0);
let cConnection: Vec4 = Vec4(0, 0, 0, 0);
let cLink: Vec4 = Vec4(0, 0, 0, 0);
let cLinkDisabled: Vec4 = Vec4(0, 0, 0, 0);
let cPath: Vec4 = Vec4(0, 0, 0, 0);
let cAvoid: Vec4 = Vec4(0, 0, 0, 0);
let cObstacle: Vec4 = Vec4(0, 0, 0, 0);
let cPushout: Vec4 = Vec4(0, 0, 0, 0);
let cPushin: Vec4 = Vec4(0, 0, 0, 0);
let coloursReady = false;

function linear(c: Vec4): Vec4 {
    return lin(Vec3(c.x, c.y, c.z), c.w);
}

function ready(): void {
    if (coloursReady) return;
    cEdge = linear(NAV_EDGE_COLOR);
    cDisabled = linear(NAV_EDGE_DISABLED_COLOR);
    cFree = linear(NAV_FREE_EDGE_COLOR);
    cConnection = linear(NAV_EDGE_CONNECTION_COLOR);
    cLink = linear(NAV_LINK_COLOR);
    cLinkDisabled = linear(NAV_LINK_DISABLED_COLOR);
    cPath = linear(NAV_AGENT_PATH_COLOR);
    cAvoid = linear(NAV_AVOIDANCE_COLOR);
    cObstacle = linear(NAV_OBSTACLE_RADIUS_COLOR);
    cPushout = linear(NAV_OBSTACLE_PUSHOUT_COLOR);
    cPushin = linear(NAV_OBSTACLE_PUSHIN_COLOR);
    coloursReady = true;
}

// One line between two scene-space points.
function put(out: Array<LineInstance>, at: i32, ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64, c: Vec4,
    w: f32, flags: u32 = 0): i32 {
    const line = LineInstance(sceneToModel(Vec3(<f32>ax, <f32>ay, <f32>az)), sceneToModel(Vec3(<f32>bx, <f32>by,
        <f32>bz)), c, w, flags);
    if (at < out.length) unchecked(out[at] = line);
    else out.push(line);
    return at + 1;
}

// The map's polygons, edge connections and links (see the header).
export function navigationMapLinesInto(map: NavMap, scale: f32, out: Array<LineInstance>, at: i32): i32 {
    ready();
    const drawn = navigationLinesDrawn;
    drawn.edges = 0;
    drawn.freeEdges = 0;
    drawn.disabledEdges = 0;
    drawn.edgeConnections = 0;
    drawn.links = 0;
    let k = at;
    const w = NAV_EDGE_WIDTH * scale;
    const gr = map.graph;
    const px = gr.px, py = gr.py, pz = gr.pz;
    // The polygons' edges: a joined pair once (its twin left out).
    for (let p = 0; p < gr.polyCount; p++) {
        const a = unchecked(gr.cornerStart[p]), b = unchecked(gr.cornerStart[p + 1]);
        for (let c = a; c < b; c++) {
            const state = unchecked(gr.edgeState[c]);
            const free = state == NAV_EDGE_FREE || state == NAV_EDGE_CONNECTED;
            if (!free && state != NAV_EDGE_JOINED) continue;
            const n = c + 1 < b ? c + 1 : a;
            k = put(out, k, unchecked(px[c]), unchecked(py[c]), unchecked(pz[c]), unchecked(px[n]), unchecked(py[n]),
                unchecked(pz[n]), free ? cFree : cEdge, w);
            if (free) drawn.freeEdges++;
            else drawn.edges++;
        }
    }
    // A disabled region's polygons, in the disabled colour (the map holds
    // none of them: they are drawn from the mesh, placed as the map would).
    const rs = map.regions;
    for (let i = 0; i < rs.length; i++) {
        const r = unchecked(rs[i]);
        if (r.enabled) continue;
        k = disabledRegionInto(r, w, out, k);
    }
    // The edge connections, each once (from the lower polygon).
    for (let p = 0; p < gr.polyCount; p++) {
        const ca = unchecked(gr.connStart[p]), cb = unchecked(gr.connStart[p + 1]);
        for (let c = ca; c < cb; c++) {
            if (unchecked(gr.connKind[c]) != NAV_CONN_MARGIN || unchecked(gr.connTarget[c]) < p) continue;
            const o = c * 6;
            k = put(out, k, unchecked(gr.connPath[o]), unchecked(gr.connPath[o + 1]), unchecked(gr.connPath[o + 2]),
                unchecked(gr.connPath[o + 3]), unchecked(gr.connPath[o + 4]), unchecked(gr.connPath[o + 5]), cConnection,
                w);
            drawn.edgeConnections++;
        }
    }
    // The links: an arc, and an arrow head when one way.
    const ls = map.links;
    for (let i = 0; i < ls.length; i++) {
        const l = unchecked(ls[i]);
        const pts = map.linkPoints;
        const o = i * 6;
        const joined = l.enabled && unchecked(map.linkNode[i]) >= 0;
        k = linkInto(<f64>unchecked(pts[o]), <f64>unchecked(pts[o + 1]), <f64>unchecked(pts[o + 2]),
            <f64>unchecked(pts[o + 3]), <f64>unchecked(pts[o + 4]), <f64>unchecked(pts[o + 5]), !l.bidirectional,
            joined ? cLink : cLinkDisabled, w, out, k);
        drawn.links++;
    }
    return k;
}

// A disabled region's polygon edges (each edge of each polygon: a disabled
// region's corners are not joined).
function disabledRegionInto(r: NavigationRegion3D, w: f32, out: Array<LineInstance>, at: i32): i32 {
    const m = r.navigationMesh;
    if (m == null || !m.valid) return at;
    const g = r.global();
    const v = m.vertices;
    const starts = m.polygonStarts;
    const idx = m.polygonIndices;
    let k = at;
    for (let p = 0; p < m.polygonCount(); p++) {
        const a = unchecked(starts[p]), b = unchecked(starts[p + 1]);
        for (let c = a; c < b; c++) {
            const i0 = unchecked(idx[c]) * 3;
            const i1 = unchecked(idx[c + 1 < b ? c + 1 : a]) * 3;
            const p0 = g.transformPoint3(Vec3(unchecked(v[i0]), unchecked(v[i0 + 1]), unchecked(v[i0 + 2])));
            const p1 = g.transformPoint3(Vec3(unchecked(v[i1]), unchecked(v[i1 + 1]), unchecked(v[i1 + 2])));
            k = put(out, k, <f64>p0.x, <f64>p0.y, <f64>p0.z, <f64>p1.x, <f64>p1.y, <f64>p1.z, cDisabled, w);
            navigationLinesDrawn.disabledEdges++;
        }
    }
    return k;
}

// A link's arc from (sx, sy, sz) to (ex, ey, ez): a parabola through
// NAV_LINK_SEGMENTS segments whose middle stands a quarter of the link's
// length above the straight line, then two arrow sides at its end when
// `oneWay`.
function linkInto(sx: f64, sy: f64, sz: f64, ex: f64, ey: f64, ez: f64, oneWay: bool, c: Vec4, w: f32,
    out: Array<LineInstance>, at: i32): i32 {
    const dx = ex - sx, dy = ey - sy, dz = ez - sz;
    const len = Math.sqrt(dx * dx + dy * dy + dz * dz);
    const rise = len * 0.25;
    let k = at;
    let qx = sx, qy = sy, qz = sz;
    let lx = sx, ly = sy, lz = sz;
    for (let i = 1; i <= NAV_LINK_SEGMENTS; i++) {
        const t = <f64>i / <f64>NAV_LINK_SEGMENTS;
        const x = sx + dx * t, z = sz + dz * t;
        const y = sy + dy * t + rise * 4 * t * (1 - t);
        lx = qx;
        ly = qy;
        lz = qz;
        k = put(out, k, qx, qy, qz, x, y, z, c, w);
        qx = x;
        qy = y;
        qz = z;
    }
    if (!oneWay || len == 0) return k;
    // (back along the last segment, spread sideways on the ground plane)
    let bx = lx - ex, by = ly - ey, bz = lz - ez;
    const bl = Math.sqrt(bx * bx + by * by + bz * bz);
    if (bl == 0) return k;
    const head = Math.min(len * <f64>NAV_ARROW_SHARE, <f64>NAV_ARROW_MAX);
    bx = bx / bl * head;
    by = by / bl * head;
    bz = bz / bl * head;
    let sideX = -dz, sideZ = dx;
    const sl = Math.sqrt(sideX * sideX + sideZ * sideZ);
    if (sl > 0) {
        sideX = sideX / sl * head * 0.5;
        sideZ = sideZ / sl * head * 0.5;
    } else {
        // (a vertical link: the arrow spread along x)
        sideX = head * 0.5;
        sideZ = 0;
    }
    k = put(out, k, ex, ey, ez, ex + bx + sideX, ey + by, ez + bz + sideZ, c, w);
    k = put(out, k, ex, ey, ez, ex + bx - sideX, ey + by, ez + bz - sideZ, c, w);
    return k;
}

// A circle of radius r about (cx, cy, cz) on the ground plane.
function circleInto(cx: f64, cy: f64, cz: f64, r: f64, c: Vec4, w: f32, out: Array<LineInstance>, at: i32): i32 {
    let k = at;
    const step = 2.0 * Math.PI / <f64>NAV_CIRCLE_SEGMENTS;
    let x0 = cx + r, z0 = cz;
    for (let i = 1; i <= NAV_CIRCLE_SEGMENTS; i++) {
        // (the last point is the first exactly)
        const j = i % NAV_CIRCLE_SEGMENTS;
        const x1 = cx + Math.cos(<f64>j * step) * r, z1 = cz + Math.sin(<f64>j * step) * r;
        k = put(out, k, x0, cy, z0, x1, cy, z1, c, w);
        x0 = x1;
        z0 = z1;
    }
    return k;
}

// The nodes walked (kept: a frame drawn again allocates nothing).
const walked = new Array<SceneNode>();
const stack = new Array<SceneNode>();

// The tree's agents' paths and the avoidance's circles (agents with
// avoidance_enabled, radius obstacles) and outlines (outline obstacles
// with avoidance_enabled), as they stand, in the main world.
export function navigationAgentLinesInto(tree: SceneTree, scale: f32, out: Array<LineInstance>, at: i32): i32 {
    ready();
    const drawn = navigationLinesDrawn;
    drawn.paths = 0;
    drawn.circles = 0;
    drawn.outlines = 0;
    tree.walkInto(walked, stack);
    let k = at;
    const thin = NAV_EDGE_WIDTH * scale;
    for (let i = 0; i < walked.length; i++) {
        const n = unchecked(walked[i]);
        if (n.freed) continue;
        const isAgent = n instanceof NavigationAgent3D;
        const isObstacle = n instanceof NavigationObstacle3D;
        if (!isAgent && !isObstacle) continue;
        if (inOwnWorld(n)) continue;
        if (isAgent) {
            const a = n as NavigationAgent3D;
            const actor = a.actor();
            if (actor == null) continue;
            k = pathInto(a, actor.globalPosition, scale, out, k);
            if (a.avoidanceEnabled && a.radius > 0) {
                const p = actor.globalPosition;
                k = circleInto(<f64>p.x, <f64>p.y, <f64>p.z, <f64>a.radius, cAvoid, thin, out, k);
                drawn.circles++;
            }
            continue;
        }
        const o = n as NavigationObstacle3D;
        if (!o.avoidanceEnabled) continue;
        const g = o.global();
        const base = g.wAxis;
        if (o.radius > 0) {
            // (the radius times the largest global scale, as the avoidance
            // takes it)
            const sx = g.xAxis.truncate().length(), sy = g.yAxis.truncate().length(), sz = g.zAxis.truncate().length();
            const s = Mathf.max(sx, Mathf.max(sy, sz));
            k = circleInto(<f64>base.x, <f64>base.y, <f64>base.z, <f64>(o.radius * s), cObstacle, thin, out, k);
            drawn.circles++;
        }
        if (o.vertices.length >= 6) {
            k = outlineInto(o, thin, out, k);
            drawn.outlines++;
        }
    }
    return k;
}

// An agent's path from its actor through the points it has still to reach
// (raised by path_height_offset, as it follows them), a point at each.
function pathInto(a: NavigationAgent3D, from: Vec3, scale: f32, out: Array<LineInstance>, at: i32): i32 {
    const s = a.nav;
    const path = s.path;
    if (!s.hasPath || path.length == 0) return at;
    const custom = a.debugUseCustom;
    let c = cPath;
    if (custom) {
        const dc = a.debugPathCustomColor;
        c = lin(Vec3(dc.x, dc.y, dc.z), dc.w);
    }
    const w = NAV_PATH_WIDTH * scale;
    const point = (custom ? a.debugPathCustomPointSize : NAV_PATH_POINT_SIZE) * scale;
    const lift = <f64>a.pathHeightOffset;
    let k = at;
    let qx = <f64>from.x, qy = <f64>from.y, qz = <f64>from.z;
    const first = s.pathIndex < path.length ? max<i32>(s.pathIndex, 0) : path.length - 1;
    for (let j = first; j < path.length; j++) {
        const p = unchecked(path[j]);
        const x = <f64>p.x, y = <f64>p.y + lift, z = <f64>p.z;
        k = put(out, k, qx, qy, qz, x, y, z, c, w);
        k = put(out, k, x, y, z, x, y, z, c, point, F_NO_PULL);
        qx = x;
        qy = y;
        qz = z;
    }
    navigationLinesDrawn.paths++;
    return k;
}

// An outline obstacle's outline at its foot and its top (its height), and
// its corners' uprights, in Godot's push-out colour when it is listed
// counter-clockwise on the (x, z) plane (RVO2's winding: agents kept out),
// else the push-in colour. The vertices are placed as the avoidance places
// them, by Godot's safe transform (./avoidance.as obstacleFrame: the
// node's origin, its turn about Y alone and the sizes of its scale), on
// the ground plane through the origin (y ignored); an obstacle turned
// about X or Z is drawn where it avoids, not tipped over. That frame keeps
// the outline's winding, so the colour is the listed vertices'.
function outlineInto(o: NavigationObstacle3D, w: f32, out: Array<LineInstance>, at: i32): i32 {
    const g = obstacleFrame(o);
    const v = o.vertices;
    const n = v.length / 3;
    const y0 = <f64>g.wAxis.y;
    const ys = g.yAxis.truncate().length();
    const y1 = y0 + <f64>(o.height * ys);
    let area: f64 = 0;
    for (let i = 0; i < n; i++) {
        const j = (i + 1) % n;
        area += <f64>v[i * 3] * <f64>v[j * 3 + 2] - <f64>v[j * 3] * <f64>v[i * 3 + 2];
    }
    const c = area > 0 ? cPushout : cPushin;
    let k = at;
    for (let i = 0; i < n; i++) {
        const j = (i + 1) % n;
        const a = g.transformPoint3(Vec3(unchecked(v[i * 3]), 0, unchecked(v[i * 3 + 2])));
        const b = g.transformPoint3(Vec3(unchecked(v[j * 3]), 0, unchecked(v[j * 3 + 2])));
        k = put(out, k, <f64>a.x, y0, <f64>a.z, <f64>b.x, y0, <f64>b.z, c, w);
        if (y1 != y0) {
            k = put(out, k, <f64>a.x, y1, <f64>a.z, <f64>b.x, y1, <f64>b.z, c, w);
            k = put(out, k, <f64>a.x, y0, <f64>a.z, <f64>a.x, y1, <f64>a.z, c, w);
        }
    }
    return k;
}
