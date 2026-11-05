// A scene's bake on its frame (milestone 19): buildSceneFrame (adapter.as)
// calls `applyLightmap` once every item is gathered and the lights are on
// the frame, in the lit and lightmap shadings, for a scene whose first
// LightmapGI has light_data. It
//   - sets RenderFrame.lightmap to the bake's images;
//   - gives each item that has an instance in the bake (by its node's path
//     from the root of the scene that declares the LightmapGI, its
//     `lightmapRoot`, and part: SceneFrame.itemNodes, and the item's index
//     among its node's items) whose source mesh still has the instance's
//     vertex and triangle counts and lightmapDigest, and whose world matrix
//     in that root's frame (`lightmapFrame`) is the instance's transform
//     (lightmapTransformMatches), the lightmapped mesh (the
//     source's vertices through the instance's xref, its indices, its
//     GpuMesh.lightmapUv; built once per instance and kept in the
//     SceneRenderCache) and DrawItem.lightmapLayer; an item whose bake no
//     longer matches keeps its mesh and is drawn in real time, with the
//     warning "lightmap of <node> is out of date (moved or changed since
//     the bake); drawn without it: bake again";
//   - gives every other drawn item whose node's gi_mode is not disabled
//     DrawItem.probeSh, probes.as probeShAt at the centre of its box, when
//     the bake has probes (they are in the root's frame too: the centre is
//     taken into it, and the light's directions out of it);
//   - warns once ("the bake of <gi> matches none of the scene's static
//     items: drawn in real time; bake again") when the bake has instances
//     but not one static item found its own, so that a bake made for
//     another tree is not dropped in silence;
// and nothing else: the lights carry their bakeMode already (lights.as).
//
// Because the bake is relative to the scene that declares the LightmapGI,
// a baked scene instanced in another (moved, turned, under any path) draws
// with its bake as it does on its own.
// A scene without a LightmapGI, or whose LightmapGI has no light_data,
// gets nothing here, so its frame is what it was before.
//
// Only a static item drawn once is lightmapped (gi_mode static, not a
// MultiMesh): a node made dynamic since the bake takes probe light.
//
// Planning the same tree again allocates nothing here: what each item slot
// matched, and whether its mesh still matched at its world matrix, is kept
// in the cache (cache.as LightmapMatch) and only worked out again when the
// node, the mesh or the matrix changed; the probe light goes into an array
// kept per item slot, and (milestone 67) is interpolated again only when
// the item's centre, the probes or the bake's frame changed: a search of
// every probe for every item at every plan was most of the demo's frame
// under rive's interpreter (about 8 of 22 ms at 1920 x 1080: its hall holds
// a thousand probe-lit items and the Baked lighting room's probes).
//
// Milestone 67b (docs/engine/RESOURCES.md, "CPU copies"): a run time lets
// go of a mesh's arrays a frame after its upload. What the bake reads of a
// source mesh is worked out in the plan that uploads it: its counts are
// kept (GpuMesh.vertexCount, indexLength), its digest too
// (render/lightmap/data.as lightmapDigest), and its lightmapped mesh is
// made then and shared through the bake's instance (LightmapInstance
// .sharedMesh), so another render cache drawing the item (a second
// Scene3D, the scene shown again) takes it rather than making it again
// from arrays that are gone. The tools keep every array and make one per
// cache, as before.

import { SceneTree } from "../tree/tree";
import { LightmapCounts, LightmapMatch, SceneRenderCache } from "./cache";
import { GpuMesh, MeshUploader } from "../../render/mesh";
import { RenderFrame } from "../../render/frame";
import { MAT4_IDENTITY, Mat4, Vec2, Vec3, Vec4 } from "../../base/vecmath";
import { SurfaceVertex } from "../../render/gpu/layouts";
import {
    GI_MODE_DISABLED, GI_MODE_STATIC, LightmapData, LightmapInstance, LightmapProbeSet, instanceKey, lightmapDigest,
    lightmapTransformMatches,
} from "../../render/lightmap/data";
import { probeShAt } from "../../render/lightmap/probes";
import { CPU_COPY_RELEASE, cpuCopyPolicy, noteCpuMiss } from "../resource/cpu_copy";
import { rotationOf, shTurn } from "../../render/lightmap/sh";
import { MODEL_TO_SCENE, SCENE_TO_MODEL } from "../space";
import { GeometryInstance3D, LightmapGI, SceneNode } from "../tree/node";

export function applyLightmap(
    tree: SceneTree, f: RenderFrame, itemNodes: Array<SceneNode>, cache: SceneRenderCache, uploader: MeshUploader?,
    warnings: Array<string>,
): LightmapCounts {
    const counts = cache.lightmapCounts;
    counts.lightmapped = 0;
    counts.probeLit = 0;
    // The tree's LightmapGI (SceneTree.lightmapGi), looked for once per tree.
    if (cache.lightmapTree !== tree) {
        cache.lightmapTree = tree;
        cache.lightmapGi = tree.lightmapGi();
    }
    const gi: LightmapGI? = cache.lightmapGi;
    if (gi == null) return counts;
    const res = gi.lightData;
    if (res == null) return counts;
    const d = res.data;
    if (d == null) return counts;
    const data = d as LightmapData;
    if (cache.lightmapKeysOf !== data) {
        cache.lightmapKeysOf = data;
        cache.lightmapKeys.clear();
        for (let i = 0; i < data.instances.length; i++) {
            const inst = data.instances[i];
            cache.lightmapKeys.set(instanceKey(inst.node, inst.part), inst);
        }
    }
    if (data.images.layers.length > 0) f.lightmap = data.images;
    const probes = data.probes;
    const hasProbes = probes.count > 0;
    // The frame the bake is relative to (exactly the identity for a scene
    // drawn as the root of its own tree with its root unmoved).
    const root = lightmapRoot(gi);
    const frame = lightmapFrame(root);
    const moved = !(frame == MAT4_IDENTITY);
    const toBake = moved ? frame.inverse() : MAT4_IDENTITY;
    const turn = rotationOf(frame);
    let statics = 0;
    const items = f.items;
    const n = min<i32>(items.length, itemNodes.length);
    let part = 0;
    for (let i = 0; i < n; i++) {
        const node = unchecked(itemNodes[i]);
        part = i > 0 && unchecked(itemNodes[i - 1]) === node ? part + 1 : 0;
        const isGeometry = node instanceof GeometryInstance3D;
        const gm = isGeometry ? (node as GeometryInstance3D).giMode : GI_MODE_DISABLED;
        if (gm == GI_MODE_DISABLED) continue;
        const item = unchecked(items[i]);
        const mesh = item.mesh;
        if (mesh == null) continue;
        const m = cache.lightmapMatch(i);
        // The item's source mesh: a frame given its bake already (applied
        // twice) draws the lightmapped mesh, whose source is the match's.
        let source: GpuMesh = mesh;
        if (m.drawn === mesh && m.source != null && m.data === data) source = m.source!;
        // (a skinned item is never baked, compiler/src/bake/bake.as: it moves
        // with its skeleton, so it takes probe light)
        if (gm == GI_MODE_STATIC && item.instances == null && item.skin == null) {
            statics++;
            match(m, data, node, root, part, source, item.world, toBake, cache);
        } else {
            m.node = null;
            m.instance = null;
            m.fresh = false;
        }
        m.source = source;
        const inst = m.instance;
        let g: GpuMesh? = null;
        if (inst != null && m.fresh) {
            g = cache.lightmapMesh(inst, source, uploader);
            if (g == null && !canLightmap(inst, source)) {
                // (milestone 67b: a source released before its lightmapped
                // mesh was made has nothing to make it from: drawn in real
                // time, a miss)
                noteCpuMiss("lightmap: a source mesh released before its lightmapped mesh was made");
            } else if (g == null) {
                const made = lightmappedMeshOf(source, inst);
                // (one shared and on the device already is not uploaded
                // again)
                cache.keepLightmapMesh(inst, source, made, made.gpu != null ? null : uploader);
                g = made;
            }
        }
        if (inst != null && g != null) {
            item.mesh = g;
            item.lightmapLayer = inst.layer;
            m.drawn = g;
            counts.lightmapped++;
            continue;
        }
        item.mesh = source;
        m.drawn = source;
        if (inst != null) {
            if (m.warning.length == 0) {
                m.warning = "lightmap of " + inst.node + " is out of date (moved or changed since the bake); "
                    + "drawn without it: bake again";
            }
            if (!warnings.includes(m.warning)) warnings.push(m.warning);
        }
        if (hasProbes) {
            const sh = cache.probeArray(i);
            const centre = item.bounds.center();
            const at = moved ? toBake.transformPoint3(centre) : centre;
            // (milestone 67: interpolated again only when the point, the
            // probes or the bake's frame changed: the same numbers)
            if (!keptSh(m, probes, at, moved, frame)) {
                probeShAt(probes, at, sh, 0);
                if (moved) shTurn(sh, 0, turn);
                keepSh(m, probes, at, moved, frame);
            }
            item.probeSh = sh;
            counts.probeLit++;
        }
    }
    if (counts.lightmapped == 0 && statics > 0 && data.instances.length > 0) {
        let stale = false;
        for (let i = 0; i < n && !stale; i++) if (cache.lightmapMatch(i).instance != null) stale = true;
        if (!stale) {
            if (cache.lightmapNoneGi !== gi) {
                cache.lightmapNoneGi = gi;
                cache.lightmapNoneSaid = "the bake of " + gi.path()
                    + " matches none of the scene's static items: drawn in real time; bake again";
            }
            const said = cache.lightmapNoneSaid;
            if (!warnings.includes(said)) warnings.push(said);
        }
    }
    return counts;
}

// Milestone 67: whether the probe light of `m`'s slot was last
// interpolated from `probes` at `at` (bit for bit) and, when the bake's
// root had moved (`moved`), turned out of `frame` (bit for bit): what
// probeShAt and shTurn would write again. Allocates nothing.
function keptSh(m: LightmapMatch, probes: LightmapProbeSet, at: Vec3, moved: bool, frame: Mat4): bool {
    if (m.shProbes !== probes || m.shMoved != moved) return false;
    if (m.shX != reinterpret<u32>(at.x) || m.shY != reinterpret<u32>(at.y) || m.shZ != reinterpret<u32>(at.z)) return false;
    return !moved || sameBits(m.shFrame, frame);
}

function keepSh(m: LightmapMatch, probes: LightmapProbeSet, at: Vec3, moved: bool, frame: Mat4): void {
    m.shProbes = probes;
    m.shX = reinterpret<u32>(at.x);
    m.shY = reinterpret<u32>(at.y);
    m.shZ = reinterpret<u32>(at.z);
    m.shMoved = moved;
    m.shFrame = frame;
}

// Whether `a` and `b` hold the same bits (a -0 and a 0, or two NaNs, are
// told apart as the numbers they would give are).
function sameBits(a: Mat4, b: Mat4): bool {
    return sameVec4(a.xAxis, b.xAxis) && sameVec4(a.yAxis, b.yAxis) && sameVec4(a.zAxis, b.zAxis)
        && sameVec4(a.wAxis, b.wAxis);
}

function sameVec4(a: Vec4, b: Vec4): bool {
    return reinterpret<u32>(a.x) == reinterpret<u32>(b.x) && reinterpret<u32>(a.y) == reinterpret<u32>(b.y)
        && reinterpret<u32>(a.z) == reinterpret<u32>(b.z) && reinterpret<u32>(a.w) == reinterpret<u32>(b.w);
}

// The root of the scene that declares `gi`: the node a bake's paths start
// from and whose frame its transforms and probes are in. The tree's root
// for a LightmapGI of the tree's own file; an instance's root for one an
// instanced scene declares (`owner`); the node itself when it is a root.
export function lightmapRoot(gi: SceneNode): SceneNode {
    const o = gi.owner;
    return o != null ? o : gi;
}

// The world matrix (frame world space, model to model) of `root`
// (lightmapRoot): what BakeInput.frame is when the bake is made, and what
// the bake is taken out of when it is drawn.
export function lightmapFrame(root: SceneNode): Mat4 {
    if (root.parent == null && root.local == MAT4_IDENTITY) return MAT4_IDENTITY;
    return SCENE_TO_MODEL * root.global() * MODEL_TO_SCENE;
}

// Whether `node` is `root` or below it.
function under(node: SceneNode, root: SceneNode): bool {
    for (let n: SceneNode? = node; n != null; n = n.parent) if (n === root) return true;
    return false;
}

// Brings `m` up to date for the item of `node`'s part `part` drawing
// `source` at `world`: its instance in `data` (by path from `root` and
// part, looked up when the node or the data changed) and whether the
// source still is what was baked, `world` taken into the bake's frame by
// `toBake` (worked out when the instance, the mesh or the matrix changed:
// the matrix changes when the frame does).
function match(
    m: LightmapMatch, data: LightmapData, node: SceneNode, root: SceneNode, part: i32, source: GpuMesh, world: Mat4,
    toBake: Mat4, cache: SceneRenderCache,
): void {
    let recheck = false;
    if (m.data !== data || m.node !== node || m.part != part) {
        m.data = data;
        m.node = node;
        m.part = part;
        // (a node outside the scene that declares the LightmapGI was not
        // baked by it)
        const key = under(node, root) ? instanceKey(node.pathFrom(root), part) : "";
        const inst = key.length > 0 && cache.lightmapKeys.has(key) ? cache.lightmapKeys.get(key) : null;
        if (inst !== m.instance) m.warning = "";
        m.instance = inst;
        recheck = true;
    }
    const inst = m.instance;
    if (inst == null) return;
    if (!recheck && m.source === source && m.world == world) return;
    m.source = source;
    m.world = world;
    // (milestone 67b: the counts as kept when the arrays are released)
    m.fresh = source.vertexCount() == inst.sourceVertices && source.indexLength() == inst.sourceTriangles * 3
        && inst.indices.length == source.indexLength() && lightmapTransformMatches(toBake * world, inst.transform)
        && lightmapDigest(source) == inst.digest;
}

// Milestone 67b: whether `inst`'s lightmapped mesh of `source` can be had:
// shared already, or `source` still holds its arrays.
function canLightmap(inst: LightmapInstance, source: GpuMesh): bool {
    return !source.cpuReleased || (inst.sharedFrom === source && inst.sharedMesh != null);
}

// Milestone 67b: `inst`'s lightmapped mesh of `source` (lightmappedMesh),
// in a run time that releases CPU copies made once and shared through the
// instance (see the header); made anew otherwise, as before.
export function lightmappedMeshOf(source: GpuMesh, inst: LightmapInstance): GpuMesh {
    if (cpuCopyPolicy() != CPU_COPY_RELEASE) return lightmappedMesh(source, inst);
    const had = inst.sharedMesh;
    if (had != null && inst.sharedFrom === source) return had;
    const g = lightmappedMesh(source, inst);
    inst.sharedMesh = g;
    inst.sharedFrom = source;
    return g;
}

// The mesh `inst` draws: `source`'s vertices through its xref (every
// attribute, and UV set 1 when the source has one), its indices (in the
// source's triangle order, so the source's material ranges hold), its
// lightmap coordinates.
export function lightmappedMesh(source: GpuMesh, inst: LightmapInstance): GpuMesh {
    const nv = inst.xref.length;
    const verts = new Array<SurfaceVertex>(nv);
    const lm = new Array<Vec2>(nv);
    const uv1src = source.uv1;
    const uv1: Array<Vec2>? = uv1src != null ? new Array<Vec2>(nv) : null;
    for (let k = 0; k < nv; k++) {
        const x = <i32>inst.xref[k];
        verts[k] = source.verts[x];
        lm[k] = Vec2(inst.uv[k * 2], inst.uv[k * 2 + 1]);
        if (uv1 != null) uv1[k] = uv1src![x];
    }
    const indices = new Array<u32>(inst.indices.length);
    for (let k = 0; k < inst.indices.length; k++) indices[k] = inst.indices[k];
    const g = GpuMesh.fromArrays(verts, indices, source.ranges.slice(0));
    g.uv1 = uv1;
    g.lightmapUv = lm;
    return g;
}
