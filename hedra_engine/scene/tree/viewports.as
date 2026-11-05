// The SubViewports of a scene tree and the ViewportTextures that show them
// (milestone 34; docs/formats/RSCN.md "Viewports"): the viewport graph,
// which the scene adapter (../render/viewports.as) plans frames from, the
// warnings check, the compiler's budget check reads, and `inspect
// --viewports` prints. One walk of the tree; nothing here draws.
//
// Godot's rules, as this engine applies them:
// - A node belongs to the nearest SubViewport above it (viewportOf), and
//   is drawn in that viewport's world: the viewport's own when its
//   own_world_3d is on, else the world of the viewport it is in, up to the
//   main one (worldViewportOf: the nearest SubViewport above with a world
//   of its own, null for the main world). A scenario numbers each world:
//   SCENARIO_MAIN (0) for the main one, 1 + the SubViewport's index (in
//   tree order) for one with its own. So the nodes under a SubViewport that
//   shares its parent's world are drawn in the main view too, as Godot
//   draws them; those under one with its own world only in it.
// - A viewport looks through its current camera: the first Camera3D (tree
//   order) that belongs to it with `current` on, else the first Camera3D
//   that belongs to it (Godot makes the first camera that enters a viewport
//   current); none, and it draws nothing. The main view's camera is found
//   the same way among the cameras that belong to no SubViewport
//   (SceneTree.currentCamera).
// - A ViewportTexture shows the SubViewport its viewport_path names, from
//   the root of the scene that declares the texture: the tree's root when
//   the root scene declares it, else the first instance (tree order) of the
//   declaring scene. Declared in a scene instanced more than once, every
//   instance shows the first one's (Godot makes the texture local to each
//   instance: viewport-texture-shared says where we differ).
// - The textures a world shows are those its nodes' drawn materials hold
//   in any texture slot (a MeshInstance3D's material_override, else its
//   mesh's materials; a MultiMeshInstance3D's mesh's; a CPUParticles3D's
//   mesh's) and its Decals'
//   slots. A viewport draws after the viewports whose textures its world
//   shows (`order`: a depth-first walk in tree order, a loop cut where it
//   closes).
// - Budgets: the first MAX_VIEWPORTS SubViewports in tree order whose
//   depth is at most MAX_VIEWPORT_DEPTH are drawable; the others are not
//   drawn (the compiler's check says so: viewport-too-many,
//   viewport-too-deep).
// - A sky's panorama (WorldEnvironment -> Environment -> Sky ->
//   PanoramaSkyMaterial.panorama) is no slot of the graph: the renderer
//   reads a panorama's texels on the CPU once, so a ViewportTexture there
//   is never live and the sky draws black. panoramaViewportTextures lists
//   those, for the warnings only (viewport-texture-panorama), as
//   ./artboards.as panoramaArtboardTextures does for artboards.
//
// Hidden nodes count: a script may show them.

import { PBR_SLOT_COUNT } from "../../material/pbr";
import { MAX_VIEWPORTS, MAX_VIEWPORT_DEPTH, SCENARIO_MAIN } from "../../render/viewport";
import {
    ArrayMesh, Mesh, PanoramaSkyMaterial, StandardMaterial3D, Texture2D, ViewportTexture,
} from "../resource/types";
import { PrimitiveMesh } from "../resource/primitives";
import { viewportTextureDeclarer } from "../resource/viewport_texture";
import { DECAL_TEXTURES } from "../../render/decal";
import {
    CPUParticles3D, Camera3D, Decal, MeshInstance3D, MultiMeshInstance3D, SceneNode, SubViewport, WorldEnvironment,
} from "./node";
import { SceneTree } from "./tree";

// Why a ViewportTexture shows no SubViewport (ViewportGraph.problem).
export const VIEWPORT_TARGET_OK: i32 = 0;
// viewport_path is empty.
export const VIEWPORT_TARGET_NO_PATH: i32 = 1;
// viewport_path names no node (or the declaring scene is not in the tree).
export const VIEWPORT_TARGET_NOT_FOUND: i32 = 2;
// viewport_path names a node that is not a SubViewport.
export const VIEWPORT_TARGET_NOT_SUBVIEWPORT: i32 = 3;

// The nearest SubViewport above `n` (not `n` itself), or null: the main
// viewport.
export function viewportOf(n: SceneNode): SubViewport? {
    let p = n.parent;
    while (p != null) {
        const isViewport = p instanceof SubViewport;
        if (isViewport) return p as SubViewport;
        p = p.parent;
    }
    return null;
}

// The SubViewport whose world `n` is drawn in: the nearest above it with
// own_world_3d, or null for the main world. A SubViewport itself is in the
// world of the viewport it is in (this walks from its parent).
export function worldViewportOf(n: SceneNode): SubViewport? {
    let p = n.parent;
    while (p != null) {
        const isViewport = p instanceof SubViewport;
        if (isViewport && (p as SubViewport).ownWorld3d) return p as SubViewport;
        p = p.parent;
    }
    return null;
}

// Whether `n` is drawn in a world of its SubViewport's own (not the main
// one). Allocates nothing.
export function inOwnWorld(n: SceneNode): bool {
    return worldViewportOf(n) != null;
}

// 1 for a SubViewport under none, 2 for one under one, ...
export function viewportDepthOf(v: SubViewport): i32 {
    let d = 1;
    let p = v.parent;
    while (p != null) {
        const isViewport = p instanceof SubViewport;
        if (isViewport) d++;
        p = p.parent;
    }
    return d;
}

// The camera viewport `v` (null: the main viewport) looks through, among
// `walked` (a tree's walk): the first Camera3D belonging to it with
// `current`, else the first belonging to it, else null. Allocates nothing.
export function viewportCameraOf(walked: Array<SceneNode>, v: SubViewport?): Camera3D? {
    let first: Camera3D? = null;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isCamera = n instanceof Camera3D;
        if (!isCamera || viewportOf(n) !== v) continue;
        const c = n as Camera3D;
        if (c.current) return c;
        if (first == null) first = c;
    }
    return first;
}

// The textures node `n` shows, appended to `out` each once: its drawn
// materials' slots (see the header) and a Decal's. Every Texture2D, not
// only ViewportTextures (the caller picks).
export function nodeTexturesInto(n: SceneNode, out: Array<Texture2D>): void {
    const isMesh = n instanceof MeshInstance3D;
    const isMulti = n instanceof MultiMeshInstance3D;
    const isDecal = n instanceof Decal;
    const isParticles = n instanceof CPUParticles3D;
    if (isMesh) {
        const mi = n as MeshInstance3D;
        if (mi.materialOverride != null) fromMaterial(mi.materialOverride, out);
        else fromMesh(mi.mesh, out);
    } else if (isMulti) {
        const mm = (n as MultiMeshInstance3D).multimesh;
        if (mm != null) fromMesh(mm.mesh, out);
    } else if (isParticles) {
        // (milestone 35: its mesh's materials, as the adapter draws them)
        fromMesh((n as CPUParticles3D).mesh, out);
    } else if (isDecal) {
        const d = n as Decal;
        for (let k = 0; k < DECAL_TEXTURES; k++) {
            const t = d.textureAt(k);
            if (t != null && !out.includes(t)) out.push(t);
        }
    }
}

function fromMesh(mesh: Mesh?, out: Array<Texture2D>): void {
    if (mesh == null) return;
    const isPrimitive = mesh instanceof PrimitiveMesh;
    const isArray = mesh instanceof ArrayMesh;
    if (isPrimitive) {
        fromMaterial((mesh as PrimitiveMesh).material, out);
    } else if (isArray) {
        const surfaces = (mesh as ArrayMesh).surfaces;
        for (let k = 0; k < surfaces.length; k++) fromMaterial(surfaces[k].material, out);
    }
}

function fromMaterial(m: StandardMaterial3D?, out: Array<Texture2D>): void {
    if (m == null) return;
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const t = m.textureAt(slot);
        if (t != null && !out.includes(t)) out.push(t);
    }
}

// The ViewportTextures `tree`'s skies hold as their panorama (see the
// header), each once, in tree order; hidden WorldEnvironments count.
export function panoramaViewportTextures(tree: SceneTree): Array<ViewportTexture> {
    const out = new Array<ViewportTexture>();
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        const isEnv = n instanceof WorldEnvironment;
        if (!isEnv) continue;
        const env = (n as WorldEnvironment).environment;
        if (env == null) continue;
        const sky = env.sky;
        if (sky == null) continue;
        const m = sky.skyMaterial;
        if (m == null) continue;
        // (By name, as render/lights.as tells the two sky materials apart.)
        if (m.className() != "PanoramaSkyMaterial") continue;
        const t = (m as PanoramaSkyMaterial).panorama;
        if (t == null) continue;
        const isViewport = t instanceof ViewportTexture;
        if (!isViewport) continue;
        const v = t as ViewportTexture;
        if (!out.includes(v)) out.push(v);
    }
    return out;
}

// The roots of the instances of the scene file `abs` (an absolute path) in
// `walked`, in tree order: the tree's root when it is that scene or
// inherits it (a root with instance=, whose instancePaths name the base
// scenes), and every other node an instance of it is rooted at. The root
// is pushed once, whichever way it qualifies.
export function sceneRootsOf(tree: SceneTree, walked: Array<SceneNode>, abs: string): Array<SceneNode> {
    const out = new Array<SceneNode>();
    if (abs.length == 0) return out;
    const root = tree.root;
    if (tree.scenePath == abs || root.instancePaths.includes(abs)) out.push(root);
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        if (n === root) continue;
        if (n.instancePaths.includes(abs)) out.push(n);
    }
    return out;
}

export class ViewportGraph {
    // Every SubViewport, in tree order, and by viewport: its depth
    // (viewportDepthOf), the scenario it draws (the header), its camera,
    // whether its parent is visible (when_parent_visible), and whether it
    // is drawable (the budgets).
    viewports: Array<SubViewport> = [];
    depth: Array<i32> = [];
    scenario: Array<i32> = [];
    camera: Array<Camera3D?> = [];
    parentVisible: Array<bool> = [];
    drawable: Array<bool> = [];
    // Every ViewportTexture a node of the tree shows (nodeTexturesInto), in
    // tree order, each once; by texture: the index in `viewports` it shows
    // (-1 none), why none (VIEWPORT_TARGET_*), and whether its declaring
    // scene is instanced more than once (viewport-texture-shared).
    textures: Array<ViewportTexture> = [];
    target: Array<i32> = [];
    problem: Array<i32> = [];
    shared: Array<bool> = [];
    // By viewport: the viewports (bit = index in `viewports`, the first 32)
    // whose textures a node of its world shows; and the main world's.
    shows: Array<u32> = [];
    mainShows: u32 = 0;
    // The viewports in drawing order (indices into `viewports`, every one,
    // drawable or not): each after those its world shows, a loop cut where
    // it closes; ties in tree order.
    order: Array<i32> = [];

    // The index of `v` in `viewports`, or -1.
    indexOf(v: SubViewport): i32 {
        for (let i = 0; i < this.viewports.length; i++) if (this.viewports[i] === v) return i;
        return -1;
    }

    // The scenario `n` is drawn in (the header). Allocates nothing.
    scenarioOf(n: SceneNode): i32 {
        const w = worldViewportOf(n);
        if (w == null) return SCENARIO_MAIN;
        const k = this.indexOf(w);
        return k < 0 ? SCENARIO_MAIN : k + 1;
    }

    // The textures of `viewports[k]`: the indices in `textures` that show it.
    texturesOf(k: i32): Array<i32> {
        const out = new Array<i32>();
        for (let i = 0; i < this.target.length; i++) if (this.target[i] == k) out.push(i);
        return out;
    }
}

// The viewport graph of `tree` (the header). A tree without a SubViewport
// or a ViewportTexture gives an empty graph.
export function viewportGraph(tree: SceneTree): ViewportGraph {
    return viewportGraphOf(tree, tree.walk());
}

// viewportGraph over `walked`, the tree's walk the caller made already.
export function viewportGraphOf(tree: SceneTree, walked: Array<SceneNode>): ViewportGraph {
    const g = new ViewportGraph();
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isViewport = n instanceof SubViewport;
        if (isViewport) g.viewports.push(n as SubViewport);
    }
    let drawable = 0;
    for (let i = 0; i < g.viewports.length; i++) {
        const v = g.viewports[i];
        const d = viewportDepthOf(v);
        g.depth.push(d);
        g.camera.push(viewportCameraOf(walked, v));
        const p = v.parent;
        g.parentVisible.push(p == null || p.visibleInTree());
        const ok = d <= MAX_VIEWPORT_DEPTH && drawable < MAX_VIEWPORTS;
        if (ok) drawable++;
        g.drawable.push(ok);
        g.shows.push(0);
    }
    for (let i = 0; i < g.viewports.length; i++) {
        const v = g.viewports[i];
        g.scenario.push(v.ownWorld3d ? i + 1 : g.scenarioOf(v));
    }
    // The textures, and what each world shows.
    const shown = new Array<Texture2D>();
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        shown.length = 0;
        nodeTexturesInto(n, shown);
        if (shown.length == 0) continue;
        const scenario = g.scenarioOf(n);
        for (let k = 0; k < shown.length; k++) {
            const t = shown[k];
            const isViewportTexture = t instanceof ViewportTexture;
            if (!isViewportTexture) continue;
            const vt = t as ViewportTexture;
            let at = g.textures.indexOf(vt);
            if (at < 0) {
                at = g.textures.length;
                g.textures.push(vt);
                resolveInto(tree, walked, vt, g);
            }
            const target = g.target[at];
            if (target < 0 || target >= 32) continue;
            const bit = <u32>1 << <u32>target;
            if (scenario == SCENARIO_MAIN) {
                g.mainShows |= bit;
            } else {
                // every viewport drawing that scenario shows it
                for (let v = 0; v < g.scenario.length; v++) if (g.scenario[v] == scenario) g.shows[v] |= bit;
            }
        }
    }
    // A viewport sharing the main world shows what the main world shows.
    for (let v = 0; v < g.scenario.length; v++) if (g.scenario[v] == SCENARIO_MAIN) g.shows[v] |= g.mainShows;
    // The drawing order: depth first from each viewport in tree order, a
    // viewport after those it shows.
    const state = new Array<i32>(g.viewports.length);
    for (let i = 0; i < g.viewports.length; i++) visit(g, i, state);
    return g;
}

// Appends viewport `i` to g.order after those it shows (state: 0 not met,
// 1 being visited, 2 placed); a viewport being visited is a loop, cut there.
function visit(g: ViewportGraph, i: i32, state: Array<i32>): void {
    if (state[i] != 0) return;
    state[i] = 1;
    const shows = g.shows[i];
    for (let k = 0; k < g.viewports.length && k < 32; k++) {
        if ((shows & (<u32>1 << <u32>k)) != 0 && k != i) visit(g, k, state);
    }
    state[i] = 2;
    g.order.push(i);
}

// Finds the SubViewport `t` shows (the header) and records it in `g`.
function resolveInto(tree: SceneTree, walked: Array<SceneNode>, t: ViewportTexture, g: ViewportGraph): void {
    const roots = sceneRootsOf(tree, walked, viewportTextureDeclarer(t));
    g.shared.push(roots.length > 1);
    if (t.viewportPath.length == 0) {
        g.target.push(-1);
        g.problem.push(VIEWPORT_TARGET_NO_PATH);
        return;
    }
    const n = roots.length > 0 ? roots[0].getNode(t.viewportPath) : null;
    if (n == null) {
        g.target.push(-1);
        g.problem.push(VIEWPORT_TARGET_NOT_FOUND);
        return;
    }
    const isViewport = n instanceof SubViewport;
    if (!isViewport) {
        g.target.push(-1);
        g.problem.push(VIEWPORT_TARGET_NOT_SUBVIEWPORT);
        return;
    }
    const k = g.indexOf(n as SubViewport);
    g.target.push(k);
    g.problem.push(k < 0 ? VIEWPORT_TARGET_NOT_FOUND : VIEWPORT_TARGET_OK);
    if (k >= 0) {
        const v = n as SubViewport;
        t.width = v.width;
        t.height = v.height;
    }
}
