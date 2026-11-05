// A scene's occluders on its frame (milestone 37; hedra_engine/render/
// occluder.as says what a frame carries, render/occlusion.as how the
// culling uses them): buildSceneFrame (adapter.as) calls `applyOccluders`
// once every item is gathered, in every shading that draws surfaces, and
// refreshSceneFrame calls `refreshOccluders` on each refresh in place. It
//   - fills RenderFrame.occluders with one OccluderDesc per visible
//     OccluderInstance3D of the tree (tree order, every world) whose
//     occluder has triangles, with `occluderDescInto`, and records their
//     nodes in `nodes`, for the refresh;
//   - gives each one its world here, numbered as the items are (`subs`,
//     every SubViewport in tree order: 0 the main world, else the index of
//     its own-world SubViewport plus one), because only the lit shading
//     plans the viewports (viewports.as, which sets the same numbers) and
//     an occluder of another world must never cull the main world's items
//     in the other shadings;
//   - sets RenderFrame.occlusion from the options (`render --occlusion
//     off`, a test's switch);
//   - while it culls, warns once (OCCLUSION_TRIANGLES_WARNING) when the
//     occluders of one world pass the OCCLUSION_MAX_TRIANGLES a frame
//     rasterises.
// It returns how many occluders the frame carries. A scene without an
// OccluderInstance3D leaves RenderFrame.occluders empty and culls as
// before.
//
// `occluderDescInto` (also the editor's gizmo and `inspect --occluders`),
// in the frame's space (Z up: SCENE_TO_MODEL * the node's global
// transform, as every item's world): the occluder's mesh
// (./occluder_shapes.as occluderMeshOf, the arrays shared, never copied),
// `world` that transform, `bounds` the box of the mesh's points through
// it, the occluder's version, and `closed` for a box or a sphere. An OccluderInstance3D without an occluder, or
// whose occluder has no triangle, is left out (the warnings say why).
//
// Planning the same tree again allocates what a plan allocates; every
// refresh allocates nothing.

import { Mat4, Vec3 } from "../../base/vecmath";
import { RenderFrame } from "../../render/frame";
import { Bounds } from "../../render/camera";
import { OccluderDesc } from "../../render/occluder";
import { SCENE_TO_MODEL } from "../space";
import { BoxOccluder3D, SphereOccluder3D } from "../resource/occluders";
import { OccluderInstance3D, SceneNode, SubViewport } from "../tree/node";
import { worldViewportOf } from "../tree/viewports";
import { SCENARIO_MAIN } from "../../render/viewport";
import { OCCLUSION_MAX_TRIANGLES, OCCLUSION_TRIANGLES_WARNING } from "../../render/occlusion";
import { occluderMeshOf } from "./occluder_shapes";

// Plans the occluders of `walked` (the tree's walk, which buildSceneFrame
// has made already) on `f`, culling with them when `occlusion` (see the
// header); returns how many.
export function applyOccluders(
    walked: Array<SceneNode>, f: RenderFrame, occlusion: bool, warnings: Array<string>, nodes: Array<OccluderInstance3D>,
    subs: Array<SubViewport>,
): i32 {
    nodes.length = 0;
    f.occlusion = occlusion;
    for (let i = 0; i < walked.length; i++) {
        const w = walked[i];
        const isOccluder = w instanceof OccluderInstance3D;
        if (!isOccluder || !w.visibleInTree()) continue;
        const n = w as OccluderInstance3D;
        const d = new OccluderDesc();
        if (!occluderDescInto(n, d)) continue;
        const own = subs.length > 0 ? worldViewportOf(n) : null;
        d.scenario = own != null ? subs.indexOf(own) + 1 : SCENARIO_MAIN;
        d.label = n.path();
        d.order = nodes.length;
        f.occluders.push(d);
        nodes.push(n);
    }
    // The occluders of a world past the triangles a frame rasterises are
    // left out of its culling (occlusion.as OcclusionBuffer.prepare, in the
    // scene's order): said by the plan, once, as check's
    // occluder-too-many-triangles says it of the source.
    if (occlusion && passesTriangleCap(f.occluders, subs.length + 1)) warnings.push(OCCLUSION_TRIANGLES_WARNING);
    return nodes.length;
}

// Whether the occluders of any one of `worlds` worlds (SCENARIO_MAIN and
// each SubViewport's of its own, by scenario) hold more than
// OCCLUSION_MAX_TRIANGLES triangles.
function passesTriangleCap(occ: Array<OccluderDesc>, worlds: i32): bool {
    const sums = new Array<i64>(worlds);
    for (let i = 0; i < occ.length; i++) {
        const o = occ[i];
        const s = o.scenario;
        if (s < 0 || s >= worlds) continue;
        sums[s] += o.indices.length / 3;
        if (sums[s] > OCCLUSION_MAX_TRIANGLES) return true;
    }
    return false;
}

// Refreshes `f`'s occluders in place for a refresh of the frame
// (adapter.as refreshSceneFrame): false when the visible
// OccluderInstance3Ds of `walked` with triangles are not `nodes`, in order
// (the frame must be planned again); else every desc refilled from its node
// and true. Allocates nothing (an occluder whose shape changed makes its
// mesh again: occluder_shapes.as).
export function refreshOccluders(
    f: RenderFrame, nodes: Array<OccluderInstance3D>, walked: Array<SceneNode>, warnings: Array<string>,
): bool {
    let k = 0;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isOccluder = n instanceof OccluderInstance3D;
        if (!isOccluder || !n.visibleInTree()) continue;
        const o = n as OccluderInstance3D;
        if (!hasTriangles(o)) continue;
        if (k >= nodes.length || nodes[k] !== o) return false;
        k++;
    }
    if (k != nodes.length || f.occluders.length != nodes.length) return false;
    for (let i = 0; i < nodes.length; i++) occluderDescInto(nodes[i], f.occluders[i]);
    return true;
}

// Whether `n`'s occluder has triangles to occlude with.
function hasTriangles(n: OccluderInstance3D): bool {
    const o = n.occluder;
    return o != null && occluderMeshOf(o).indices.length >= 3;
}

// `n`'s desc as a frame culls with it (see the header), into `out`, in
// place, but its label and order (the plan's); false when it has no
// triangle. Allocates nothing once its mesh is made.
export function occluderDescInto(n: OccluderInstance3D, out: OccluderDesc): bool {
    const o = n.occluder;
    if (o == null) return false;
    const m = occluderMeshOf(o);
    if (m.indices.length < 3) return false;
    const g = SCENE_TO_MODEL * n.global();
    // (the same points through the same transform: the same box, kept)
    const same = out.hasBounds && out.vertices === m.vertices && out.version == o.version && out.world == g;
    out.vertices = m.vertices;
    out.indices = m.indices;
    out.world = g;
    out.version = o.version;
    // (Godot's box and sphere close their volumes, turned outwards)
    out.closed = o instanceof BoxOccluder3D || o instanceof SphereOccluder3D;
    if (!same) out.bounds = pointsBounds(m.vertices, g);
    out.hasBounds = true;
    return true;
}

// The box of `points` (x, y, z each) through `g`.
function pointsBounds(points: Float32Array, g: Mat4): Bounds {
    let mnx = f32.MAX_VALUE, mny = f32.MAX_VALUE, mnz = f32.MAX_VALUE;
    let mxx = -f32.MAX_VALUE, mxy = -f32.MAX_VALUE, mxz = -f32.MAX_VALUE;
    const n = points.length / 3;
    for (let i = 0; i < n; i++) {
        const p = g.transformPoint3(Vec3(unchecked(points[i * 3]), unchecked(points[i * 3 + 1]), unchecked(points[i * 3 + 2])));
        mnx = Mathf.min(mnx, p.x);
        mny = Mathf.min(mny, p.y);
        mnz = Mathf.min(mnz, p.z);
        mxx = Mathf.max(mxx, p.x);
        mxy = Mathf.max(mxy, p.y);
        mxz = Mathf.max(mxz, p.z);
    }
    return Bounds(Vec3(mnx, mny, mnz), Vec3(mxx, mxy, mxz));
}
