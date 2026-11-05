// A scene's SubViewports on its frame (milestone 34;
// hedra_engine/render/viewport.as says what a frame carries, ../tree/
// viewports.as which viewports a tree has and what their textures show):
// buildSceneFrame (adapter.as) calls `applyViewports` in the lit shading,
// and refreshSceneFrame calls `refreshViewports` on each refresh in place.
// It
//   - gives every item its DrawItem.scenario (the world its node is drawn
//     in) and DrawItem.viewports (the viewports its materials show), and
//     every decal its DecalDesc.scenario and .viewports;
//   - fills RenderFrame.viewports with one ViewportDesc per SubViewport of
//     the graph, in its drawing order: the desc's frame through the
//     viewport's camera (cameraInto, at the viewport's aspect), at its size,
//     its transparent_bg (no sky, alpha 0 where nothing is drawn), the main
//     frame's items, materials, decals and lightmap; its texture paths and
//     their slots' forms (colour, data); its mode, parent's visibility,
//     depth and budgets;
//   - lights each desc's frame as its world is lit: a viewport drawing the
//     frame's own world (RenderFrame.scenario) shares the frame's lights,
//     environment, boxes and probes; one drawing another world (a world of
//     its own, or the main world seen from a frame of an own world: `render
//     --viewport`) gets that world's visible lights (every one, milestone
//     59: the renderer chooses the viewport's pool of up to 64 for its
//     camera; the preview sun when it has none, and the pool's warning,
//     planned for the viewport's camera, when more are in its view), its first WorldEnvironment (the
//     preview environment when none), the boxes around that world's items
//     for its camera and shadows, and the reflection probes only when that
//     world is the main one (the probes are the main world's);
//   - milestone 62: gives each desc's frame the screen-space effects the
//     main frame may draw and their quality (RenderFrame.screenEffects,
//     .screenQuality: the view's, the same for every view of a frame), and
//     the depth of field and exposure of the viewport's own camera's
//     attributes (./screen.as: its own, else its world's
//     WorldEnvironment's); a viewport of the frame's world whose camera
//     exposes otherwise than the frame's gets an environment of its own,
//     made from that world's Environment with its multiplier.
// It records each viewport in SceneFrame.viewports for the refresh, and
// returns how many. A scene without a SubViewport changes nothing: every
// item, decal and light as before, RenderFrame.viewports empty.
//
// Planning the same tree again allocates what a plan allocates; every
// refresh allocates nothing (the descs' frames refilled in place: their
// cameras from their camera nodes, the lights of another world and the
// boxes around its items, the main world's probes for a viewport of it,
// the modes, the backgrounds as transparent_bg says and the parents'
// visibility), and answers false (plan again) when
// the tree no longer has the viewports it was planned with, or a
// viewport's size, own_world_3d or camera node changed, or the lights
// shown in another world than the frame's, or that world's environment
// (written, swapped, another sky) did.

import { Vec3, Vec4 } from "../../base/vecmath";
import { Bounds } from "../../render/camera";
import { CAST_SHADOW_OFF, CAST_SHADOW_SHADOWS_ONLY, RenderFrame } from "../../render/frame";
import { planLightPool } from "../../render/light_select";
import { ReflectionProbeSet } from "../../render/probe/data";
import { SCENARIO_MAIN, ViewportDesc } from "../../render/viewport";
import { Environment, Sky, Texture2D, ViewportTexture } from "../resource/types";
import { Camera3D, Light3D, SceneNode, SubViewport, WorldEnvironment } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { artboardSlotsOf } from "../tree/artboards";
import { ViewportGraph, nodeTexturesInto, viewportCameraOf, viewportGraphOf, worldViewportOf } from "../tree/viewports";
import { cameraInto } from "./camera";
import { environmentDesc, exposeEnvironmentInto, lightDesc, lightDescInto, lightPoolWarning, previewSun } from "./lights";
import { cameraAttributesIn, dofDescInto, exposureMultiplierOf } from "./screen";
import { CameraAttributesPractical } from "../resource/camera_attributes";
import { volumetricFogInto } from "./fog_volumes";
import { VolumetricFogDesc } from "../../render/fog_volume";
import { SceneRenderCache } from "./cache";
import { SceneFrame } from "./adapter";

// One SubViewport of a planned frame: its node, its desc (one of
// RenderFrame.viewports), and what the refresh checks it against.
export class SceneViewport {
    node: SubViewport;
    desc: ViewportDesc;
    // The camera it looks through (null: it draws nothing).
    camera: Camera3D? = null;
    // The ViewportTextures that show it (desc.paths' textures, in order).
    textures: Array<ViewportTexture> = [];
    // The world it draws: its scenario, the SubViewport that owns that
    // world (null: the main one), and the node's own_world_3d as planned.
    scenario: i32 = SCENARIO_MAIN;
    world: SubViewport? = null;
    ownWorld: bool = false;
    // Whether that world is another than the frame's (RenderFrame.scenario):
    // then its lights and environment are its own, as planned (`lightNodes`
    // every visible light of that world, by its frame's light index;
    // `environment` null for the preview environment, with what it
    // was written to then), and `bounds` the box around its drawn items. A
    // viewport of the frame's world reads the frame's and leaves these
    // empty.
    other: bool = false;
    lightNodes: Array<Light3D> = [];
    environment: Environment? = null;
    environmentWrites: i32 = 0;
    environmentSky: Sky? = null;
    bounds: Bounds = Bounds(Vec3(-1, -1, -1), Vec3(1, 1, 1));
    // The background its world clears to, opaque (transparent_bg clears to
    // alpha 0 instead; the refresh follows a keyed transparent_bg).
    background: Vec4 = Vec4(0, 0, 0, 1);
    // Milestone 62: the camera attributes its camera draws with (null:
    // none), the exposure multiplier its environment was exposed with,
    // and, for a viewport of the frame's world, whether that environment
    // is its own (its camera exposes otherwise than the frame's: made
    // from `worldEnvironment`, that world's Environment) rather than the
    // frame's.
    attributes: CameraAttributesPractical? = null;
    exposureMultiplier: f32 = 1;
    ownEnvironment: bool = false;
    worldEnvironment: Environment? = null;

    constructor(node: SubViewport, desc: ViewportDesc) {
        this.node = node;
        this.desc = desc;
    }
}

// Plans the viewports of `tree` (its walk `walked`, which buildSceneFrame
// has made) on `sf` once its items, lights, environment, bake, probes and
// decals are in (see the header); returns how many it carries.
export function applyViewports(
    tree: SceneTree, walked: Array<SceneNode>, sf: SceneFrame, cache: SceneRenderCache, warnings: Array<string>,
): i32 {
    sf.viewports.length = 0;
    const f = sf.frame;
    f.viewports.length = 0;
    // (a scene without a SubViewport makes no graph: it draws as before)
    let any = false;
    for (let i = 0; i < walked.length && !any; i++) any = walked[i] instanceof SubViewport;
    if (!any) return 0;
    const g = viewportGraphOf(tree, walked);
    // (the main world's probes; a frame of another world draws none)
    const probes = f.probes;
    if (f.scenario != SCENARIO_MAIN) f.probes = null;
    // By viewport (graph index): its place in the drawing order.
    const at = new Array<i32>(g.viewports.length);
    for (let o = 0; o < g.order.length; o++) at[g.order[o]] = o;
    for (let o = 0; o < g.order.length; o++) {
        const k = g.order[o];
        const v = g.viewports[k];
        const d = new ViewportDesc();
        // (keyed by its tree too: a renderer shared by trees, the editor's
        // tabs or a Scene3D that changes scene, must not hand one tree's
        // pictures and schedule to another's SubViewport at the same path)
        d.path = v.path();
        d.key = tree.root.serial.toString() + ":" + d.path;
        d.label = v.name;
        d.depth = g.depth[k];
        d.drawable = g.drawable[k];
        d.bit = o < 32 ? <u32>1 << <u32>o : 0;
        const sv = new SceneViewport(v, d);
        sv.camera = g.camera[k];
        const scenario = g.scenario[k];
        sv.scenario = scenario;
        sv.world = scenario == SCENARIO_MAIN ? null : g.viewports[scenario - 1];
        sv.ownWorld = v.ownWorld3d;
        sv.other = scenario != f.scenario;
        const tex = g.texturesOf(k);
        for (let i = 0; i < tex.length; i++) {
            const t = g.textures[tex[i]];
            const slots = artboardSlotsOf(tree, t);
            sv.textures.push(t);
            d.paths.push(t.path);
            d.colour.push(slots.colour);
            d.data.push(slots.data);
        }
        setUpFrame(f, d, sv, sf, scenario == SCENARIO_MAIN ? probes : null, walked, warnings);
        f.viewports.push(d);
        sf.viewports.push(sv);
    }
    // Each item's and decal's world, and the viewports it shows.
    const shown = new Array<Texture2D>();
    const items = f.items;
    for (let i = 0; i < items.length && i < sf.itemNodes.length; i++) {
        const n = sf.itemNodes[i];
        items[i].scenario = g.scenarioOf(n);
        items[i].viewports = bitsOf(n, g, at, shown);
    }
    for (let i = 0; i < f.decals.length && i < sf.decalNodes.length; i++) {
        const n = sf.decalNodes[i];
        f.decals[i].scenario = g.scenarioOf(n);
        f.decals[i].viewports = bitsOf(n, g, at, shown);
    }
    // (milestone 37: each fog volume's and occluder's world)
    for (let i = 0; i < f.fogVolumes.length && i < sf.fogNodes.length; i++) {
        f.fogVolumes[i].scenario = g.scenarioOf(sf.fogNodes[i]);
    }
    for (let i = 0; i < f.occluders.length && i < sf.occluderNodes.length; i++) {
        f.occluders[i].scenario = g.scenarioOf(sf.occluderNodes[i]);
    }
    // The boxes of the other worlds (their items' scenarios now known),
    // then what changes from frame to frame; then (milestone 59), for a
    // viewport of another world, the pool of its lights for its camera, and
    // its warning when more are in its view than a frame draws (a viewport
    // of the frame's world shares the frame's lights and its warning).
    for (let i = 0; i < sf.viewports.length; i++) {
        const sv = sf.viewports[i];
        if (sv.other) worldBoundsInto(sv, f);
        const p = sv.node.parent;
        refill(sv, p == null || p.visibleInTree(), sf);
        if (!sv.other) continue;
        const c = sv.desc.frame;
        const said = lightPoolWarning(planLightPool(c, c.lightPlan), sv.lightNodes);
        if (said.length > 0) warnings.push("SubViewport " + sv.node.path() + "'s world: " + said);
    }
    return sf.viewports.length;
}

// The bits (ViewportDesc.bit) of the viewports node `n`'s textures show.
function bitsOf(n: SceneNode, g: ViewportGraph, at: Array<i32>, shown: Array<Texture2D>): u32 {
    shown.length = 0;
    nodeTexturesInto(n, shown);
    let bits: u32 = 0;
    for (let k = 0; k < shown.length; k++) {
        const t = shown[k];
        const isViewport = t instanceof ViewportTexture;
        if (!isViewport) continue;
        const ti = g.textures.indexOf(t as ViewportTexture);
        const target = ti >= 0 ? g.target[ti] : -1;
        if (target < 0) continue;
        const o = at[target];
        if (o < 32) bits |= <u32>1 << <u32>o;
    }
    return bits;
}

// The desc's frame (see the header), from the main frame `f`; `probes` the
// main world's for a viewport of the main world, else null.
function setUpFrame(
    f: RenderFrame, d: ViewportDesc, sv: SceneViewport, sf: SceneFrame, probes: ReflectionProbeSet?,
    walked: Array<SceneNode>, warnings: Array<string>,
): void {
    const c = d.frame;
    const v = sv.node;
    c.width = <u32>v.width;
    c.height = <u32>v.height;
    c.ssaa = 1;
    c.gridExtent = 0;
    c.shading = f.shading;
    c.overlayFlags = 0;
    c.editMode = false;
    c.matcap = 0;
    c.drawSurfaces = true;
    c.materialMode = f.materialMode;
    c.outline = false;
    c.items = f.items;
    c.materials = f.materials;
    c.baseDir = f.baseDir;
    c.overlay = null;
    c.lightmap = f.lightmap;
    c.probes = probes;
    c.lodThreshold = f.lodThreshold;
    c.decals = f.decals;
    // (milestone 37: the frame's fog volumes and occluders, each drawn in
    // its own world; the volumetric fog the world's environment's)
    c.fogVolumes = f.fogVolumes;
    c.occluders = f.occluders;
    c.occlusion = f.occlusion;
    c.scenario = sv.scenario;
    // (milestone 62: the main frame's mask and quality; the depth of field
    // and exposure of the viewport's own camera)
    c.screenEffects = f.screenEffects;
    c.screenQuality.copyFrom(f.screenQuality);
    c.renderQuality.copyFrom(f.renderQuality);
    const cam = sv.camera;
    const attrs = cam != null ? cameraAttributesIn(walked, cam) : null;
    sv.attributes = attrs;
    sv.exposureMultiplier = exposureMultiplierOf(attrs);
    dofDescInto(attrs, c.dof);
    if (sv.other) {
        worldInto(sv, c, walked, warnings);
    } else {
        c.lights = f.lights;
        c.volumetricFog = f.volumetricFog;
        c.casterBounds = f.casterBounds;
        c.hasCasters = f.hasCasters;
        c.drawBounds = f.drawBounds;
        c.hasDrawBounds = f.hasDrawBounds;
        if (sv.exposureMultiplier == sf.exposureMultiplier) {
            c.environment = f.environment;
            sv.background = sf.worldBackground;
        } else {
            // (its camera exposes otherwise: the world's Environment made
            // again with its multiplier, its warnings the frame's already)
            const env = environmentOfWorld(walked, sv.world);
            environmentDesc(env, c, [], sv.exposureMultiplier);
            sv.ownEnvironment = true;
            sv.worldEnvironment = env;
            sv.background = c.background;
        }
    }
}

// Milestone 62: the Environment of the first WorldEnvironment of `world`'s
// world (null: the main one) among `walked`, or null.
function environmentOfWorld(walked: Array<SceneNode>, world: SubViewport?): Environment? {
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isEnv = n instanceof WorldEnvironment;
        if (isEnv && worldViewportOf(n) === world) return (n as WorldEnvironment).environment;
    }
    return null;
}

// The lights and environment of `sv`'s world (another than the frame's)
// into its frame `c`, recorded on `sv` for the refresh.
function worldInto(sv: SceneViewport, c: RenderFrame, walked: Array<SceneNode>, warnings: Array<string>): void {
    const world = sv.world;
    c.lights = [];
    let env: Environment? = null;
    let found = false;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isLight = n instanceof Light3D;
        const isEnv = n instanceof WorldEnvironment;
        if (!isLight && !(isEnv && !found)) continue;
        if (worldViewportOf(n) !== world) continue;
        if (isEnv) {
            env = (n as WorldEnvironment).environment;
            found = true;
        } else if (n.visibleInTree()) {
            sv.lightNodes.push(n as Light3D);
            c.lights.push(lightDesc(n as Light3D));
        }
    }
    const shown = sv.lightNodes.length;
    if (shown == 0) c.lights.push(previewSun());
    environmentDesc(env, c, warnings, sv.exposureMultiplier);
    // (milestone 37: the world's own volumetric fog, made with the plan)
    c.volumetricFog = new VolumetricFogDesc();
    volumetricFogInto(env, c.volumetricFog);
    sv.environment = env;
    if (env != null) {
        sv.environmentWrites = env.writes;
        sv.environmentSky = env.sky;
    }
    sv.background = c.background;
}

// The boxes of `sv`'s world in its frame, from the frame `f`'s items of
// its scenario: around what is drawn (for its camera), and around what
// casts (for its shadows), as buildSceneFrame boxes the frame's own world.
// Allocates nothing.
function worldBoundsInto(sv: SceneViewport, f: RenderFrame): void {
    const c = sv.desc.frame;
    const items = f.items;
    let drawn = false;
    c.hasCasters = false;
    for (let i = 0; i < items.length; i++) {
        const item = unchecked(items[i]);
        if (item.scenario != sv.scenario || !item.hasBounds) continue;
        const b = item.bounds;
        if (item.castShadow != CAST_SHADOW_OFF) {
            c.casterBounds = c.hasCasters ? c.casterBounds.union(b) : b;
            c.hasCasters = true;
        }
        if (item.castShadow == CAST_SHADOW_SHADOWS_ONLY) continue;
        c.drawBounds = drawn ? c.drawBounds.union(b) : b;
        drawn = true;
    }
    c.hasDrawBounds = drawn;
    if (!drawn) c.drawBounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    sv.bounds = drawn ? c.drawBounds : Bounds(Vec3(-1, -1, -1), Vec3(1, 1, 1));
}

// The desc's values that change from frame to frame, in place: the mode
// (and its count of `once` writes), the parent's visibility, the
// background, the camera.
function refill(sv: SceneViewport, parentVisible: bool, sf: SceneFrame): void {
    const d = sv.desc;
    const v = sv.node;
    const c = d.frame;
    d.mode = v.updateMode;
    d.onceWrites = v.onceWrites;
    d.parentVisible = parentVisible;
    // (milestone 62: the view's mask and quality, which the editor's View
    // menu changes without a new plan)
    const f = sf.frame;
    c.screenEffects = f.screenEffects;
    c.screenQuality.copyFrom(f.screenQuality);
    c.renderQuality.copyFrom(f.renderQuality);
    c.transparent = v.transparentBg;
    c.background = v.transparentBg ? Vec4(0, 0, 0, 0) : sv.background;
    const cam = sv.camera;
    d.camera = cam != null;
    if (cam != null) cameraInto(cam, sv.other ? sv.bounds : sf.bounds, <f32>v.width / <f32>v.height, c.camera);
}

// Refills `sf`'s viewports in place from the tree as it is now (see the
// header), once the frame's own items, camera and lights are refreshed;
// false when the frame must be planned again. Allocates nothing.
export function refreshViewports(
    sf: SceneFrame, walked: Array<SceneNode>, cache: SceneRenderCache, warnings: Array<string>,
): bool {
    const vs = sf.viewports;
    // (the same SubViewports: sf.viewports holds them in drawing order)
    let count = 0;
    for (let i = 0; i < walked.length; i++) {
        const isViewport = walked[i] instanceof SubViewport;
        if (!isViewport) continue;
        let known = false;
        const w = walked[i];
        for (let k = 0; k < vs.length && !known; k++) {
            const node: SceneNode = vs[k].node;
            known = node === w;
        }
        if (!known) return false;
        count++;
    }
    if (count != vs.length) return false;
    const f = sf.frame;
    for (let i = 0; i < vs.length; i++) {
        const sv = vs[i];
        const v = sv.node;
        const c = sv.desc.frame;
        if (<u32>v.width != c.width || <u32>v.height != c.height || v.ownWorld3d != sv.ownWorld) return false;
        if (viewportCameraOf(walked, v) !== sv.camera) return false;
        // (milestone 62: the same camera attributes, their values as they
        // are now; an exposure that moves the viewport off or onto the
        // frame's environment plans again, one of its own is exposed again
        // in place)
        const cam = sv.camera;
        const attrs = cam != null ? cameraAttributesIn(walked, cam) : null;
        if (attrs !== sv.attributes) return false;
        dofDescInto(attrs, c.dof);
        const multiplier = exposureMultiplierOf(attrs);
        if (!sv.other && (multiplier != sf.exposureMultiplier) != sv.ownEnvironment) return false;
        if (multiplier != sv.exposureMultiplier) {
            if (sv.other || sv.ownEnvironment) {
                const env = sv.other ? sv.environment : sv.worldEnvironment;
                exposeEnvironmentInto(env, c, multiplier);
                if (env != null && env.backgroundMode != 2) sv.background = c.background;
            } else {
                // (the frame's own environment, shared: refreshSceneFrame
                // has exposed it already with tonemap_exposure, and
                // exposing it here again would write the bare multiplier
                // over that for the main picture as well)
                sv.background = sf.worldBackground;
            }
            sv.exposureMultiplier = multiplier;
        }
        if (sv.other) {
            if (!sameWorld(sv, walked)) return false;
            // (every light shown, as planned: milestone 59)
            const lights = sv.lightNodes;
            for (let k = 0; k < lights.length && k < c.lights.length; k++) {
                lightDescInto(unchecked(c.lights[k]), unchecked(lights[k]));
            }
            worldBoundsInto(sv, f);
        } else {
            // (the frame's boxes and probes, refreshed before: a probe
            // shown or hidden since the plan. The main world's probes, as
            // the frame's are still at this point; a frame of an own world
            // draws none)
            c.probes = sv.scenario == SCENARIO_MAIN ? f.probes : null;
            c.casterBounds = f.casterBounds;
            c.hasCasters = f.hasCasters;
            c.drawBounds = f.drawBounds;
            c.hasDrawBounds = f.hasDrawBounds;
        }
        const p = v.parent;
        refill(sv, p == null || p.visibleInTree(), sf);
    }
    return true;
}

// Whether `sv`'s world (another than the frame's) shows the lights it was
// planned with, in order, and the same environment, unwritten, with the
// same sky. Allocates nothing.
function sameWorld(sv: SceneViewport, walked: Array<SceneNode>): bool {
    const world = sv.world;
    const lights = sv.lightNodes;
    let shown = 0;
    let found = false;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isLight = n instanceof Light3D;
        const isEnv = n instanceof WorldEnvironment;
        if (!isLight && !(isEnv && !found)) continue;
        if (worldViewportOf(n) !== world) continue;
        if (isEnv) {
            found = true;
            const env = (n as WorldEnvironment).environment;
            if (env !== sv.environment) return false;
            if (env != null && (env.writes != sv.environmentWrites || env.sky !== sv.environmentSky)) return false;
        } else if (n.visibleInTree()) {
            if (shown >= lights.length || unchecked(lights[shown]) !== (n as Light3D)) return false;
            shown++;
        }
    }
    if (!found && sv.environment != null) return false;
    return shown == lights.length;
}
