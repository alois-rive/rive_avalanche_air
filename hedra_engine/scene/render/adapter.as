// A scene as a renderer frame: the scene tree (tree/) turned into the flat
// RenderFrame the shared renderer draws (engine/src/render/frame.as), as
// Hedra's scene_adapter.as does for a Hedra scene. The renderer then
// knows nothing of nodes or resources.
//
// Space: a scene is Y up (../space.as); the frame is drawn in the model's Z
// up, the space the shared renderer's cameras, framing and sky are written
// in, so every world matrix is SCENE_TO_MODEL * the node's global transform,
// and a .modeler model's mesh (built in model space, meshes.as) is placed
// with SCENE_TO_MODEL * global * MODEL_TO_SCENE, which for an unmoved model
// is Hedra's own world matrix exactly: the same model gives the same
// picture in both programs.
//
// What draws: every visible MeshInstance3D with a mesh, every mesh of every
// visible ModelInstance3D's model (ModelInstance3D.parts), and every visible
// MultiMeshInstance3D whose MultiMesh has a mesh and 3D transforms, and
// (milestone 16) every visible ArtboardSprite3D with a texture and a
// non-empty rectangle, as one quad item (sprites.as). The
// camera: the one `opts.camera` names (a node path), else the view
// `opts.view` names (views.as: a preset framing everything drawn, or a
// Camera3D by path), else the scene's current camera
// (SceneTree.currentCamera), else a camera framing everything drawn from
// Hedra's iso angle. Lights: every visible light (milestone 59: no cap; the
// renderer draws a pool of up to 64 a view, 8 an item, and the frame warns
// of the lights in view past 64). A scene without a light gets the preview
// sun, and one without a WorldEnvironment the preview environment, as
// Godot's editor does (SceneFrame.defaults says so). Every shading but lit
// draws Hedra's way (shading.as): no scene light, Hedra's background, its
// shader mode (but lightmap, which plans the lights and environment as lit
// does, and lights, which plans the lights alone).
//
// No grid, no overlay, and no outline unless `opts.selected` names a node:
// a scene's picture is the scene. Only visible nodes draw
// (SceneNode.visibleInTree), and only visible lights light.
//
// The preview (milestone 6) adds two things `render` never sets: a free
// camera (`opts.freeCamera`, the preview's navigation) drawn through instead
// of the view, and a selection (`opts.selected`) outlined in Hedra's
// colours by the renderer's id and outline passes. Every item records the
// node it was drawn for (SceneFrame.itemNodes), which is how a click on the
// picture finds a node (engine/src/authoring/render/pick.as). Materials are deduplicated by resource, so a material shared by
// many meshes is one frame material (materials.as has the mapping).
//
// Shadows (milestone 10): each item casts as its node's cast_shadow says
// (DrawItem.castShadow), the frame's casterBounds holds every item that
// casts, and an item drawn only into shadow maps (shadows_only) is left out
// of the box the default camera frames, as it is not in the picture. Which
// lights get a shadow is the shared renderer's rule (shadow.as
// allocateFrameShadows); the lit branch says which lights found no room. The
// preview sun casts no shadow.
//
// Scale (milestone 13): every item carries its box (DrawItem.bounds, every
// instance included), so the shared renderer can cull it (shared/render/
// cull.as), and its node's visibility range with the centre of the node's
// box (a model's parts share their node's). A MultiMeshInstance3D is one
// item drawn with GPU instancing: its MultiMesh's mesh, instances packed
// once by the cache (cache.as `instances`). The preview, moving its camera
// over one plan, calls `retargetSceneFrame` instead of planning again.
//
// Post-processing (milestone 12): the Environment's SSAO, glow and
// adjustments reach the frame through lights.as `environmentDesc`, in the
// lit mode only; what runs is the shared renderer's rule (post.as
// `planPost`), so the other shadings, and the selection outline drawn over
// the finished picture, are as before.
//
// Skeletons and blend shapes (milestone 48; skinning.as and morph.as say
// how): a MeshInstance3D whose blend shape weights are not all 0 draws its
// node's blended copy of the mesh; one with a skin and a Skeleton3D its
// `skeleton` path finds draws with its palette (DrawItem.skin, the renderer
// skinning it on the GPU), its world the identity and its box the palette's
// (cull.as skinnedBounds), blended first, skinned after. A ModelInstance3D's
// skinned parts draw with the palette of the model's file pose, placed by
// the node, and its parts' blend shapes at the file's weights. In the wire
// shadings, whose edges the line shader cannot skin, a skinned item is
// skinned on the CPU and drawn as it is. A skinned mesh whose skeleton is
// not found is drawn as any mesh, at its bind pose.
//
// Worlds (milestone 34; viewports.as and ../tree/viewports.as say how a
// SubViewport's world and its views are planned): a frame draws one world,
// RenderFrame.scenario: the main one, unless it is a SubViewport's view
// (`opts.viewport`: its camera, its world, its transparent_bg) or looks
// through a camera inside a SubViewport with a world of its own. Every item
// is in the frame, each with the scenario its node is drawn in, but only
// the frame's world's are in its boxes (what the default camera frames and
// the shadows fit), and only that world's visible lights (all of them) and
// first WorldEnvironment light it (the preview sun and environment when it
// has none). A scene without a SubViewport is the main world alone, as before.
//
// Particles (milestone 35; particles.as and ../particles/pack.as say how):
// every visible CPUParticles3D whose mesh has triangles is one instanced
// item of that mesh, its instances its particle state's dynamic
// InstanceData, packed in the node's space and placed by the node as a
// MultiMeshInstance3D's, kept with no particle alive so that a frame
// refreshes in place while they come and go (a new mesh or material plans
// again). Billboards and view_depth are packed for the frame's camera once
// it is chosen, and again by retargetSceneFrame. A scene without a
// CPUParticles3D plans, refreshes and draws exactly as before.

import { SCREEN_EFFECTS_ALL, ScreenQuality } from "../../render/screen";
import { RenderQuality } from "../../render/quality";
import { markArtboardItems } from "./artboard_bits";
import { Result, clampF32 } from "../../base/util";
import { displayF32 } from "../../base/fmt";
import { MAT4_IDENTITY, Mat4, Vec3, Vec4 } from "../../base/vecmath";
import { Bounds, Camera, ViewPreset } from "../../render/camera";
import { InstanceData } from "../../render/instances";
import {
    CAST_SHADOW_OFF, CAST_SHADOW_ON, CAST_SHADOW_SHADOWS_ONLY, DrawItem, EnvironmentDesc, LIGHT_SPOT,
    RANGE_FADE_DEPENDENCIES, RANGE_FADE_DISABLED, RenderFrame, SHADE_FACE_ORIENT, SHADE_LIGHT_COUNT, SHADE_LIGHTMAP,
    SHADE_LIT, SHADE_MATCAP, SHADE_MATERIAL, SHADE_NORMALS, SHADE_RANDOM, SHADE_SOLID, SHADE_UV_CHECKER, chooseLods,
} from "../../render/frame";
import { GpuMesh, MeshUploader, lodTriangles } from "../../render/mesh";
import { planPost } from "../../render/post";
import { MAX_SPOT_SHADOW_HALF_ANGLE, allocateFrameShadows, shadowTileCount, staticShadowsUnused } from "../../render/shadow";
import { planLightPool } from "../../render/light_select";
import { SHADOW_TILES } from "../../render/gpu/layouts";
import { rgbaBytes, srgbToLinear } from "../../render/image";
import { MODEL_TO_SCENE, SCENE_TO_MODEL } from "../space";
import { ArrayMesh, Environment, ModelResource, MultiMesh, Sky, StandardMaterial3D, Texture2D } from "../resource/types";
import {
    ArtboardSprite3D, CPUParticles3D, Camera3D, Decal, FogVolume, GeometryInstance3D, Light3D, MeshInstance3D, ModelInstance3D,
    MultiMeshInstance3D, OccluderInstance3D, SceneNode, SubViewport, WorldEnvironment,
} from "../tree/node";
import { SceneTree, underSubViewport } from "../tree/tree";
import { viewportCameraOf, worldViewportOf } from "../tree/viewports";
import { SceneryError } from "../error";
import { SceneMesh, SceneRenderCache } from "./cache";
import { materialDesc, materialDescStamp, materialLabel, materialShape, refillMaterialDesc, slotNames } from "./materials";
import { slotsOnSet } from "../../render/material";
import { PBR_SLOT_COUNT } from "../../material/pbr";
import { globalAffine } from "../listen/affine";
import { environmentDesc, exposeEnvironmentInto, lightDesc, lightDescInto, lightPoolWarning, previewSun } from "./lights";
import { cameraAttributesIn, dofDescInto, exposureMultiplierOf } from "./screen";
import { CameraAttributesPractical } from "../resource/camera_attributes";
import { MAX_FOV, MIN_FOV, cameraInto, cameraOf, findCamera, framedCamera } from "./camera";
import { MATCAP_CLAY, MATERIAL_BACKGROUND, UV_CHECKER_SIZE, hashColor, wireColour } from "./shading";
import { SceneView, SceneViewKind, presetCamera } from "./views";
import { SpriteItem, normalInto, orientSprites, spriteMaterial, spriteMaterialInto, spriteQuad } from "./sprites";
import { BILLBOARD_ENABLED, BILLBOARD_FIXED_Y, billboardRadius, mulMat4, spritePlacement, spriteRect } from "./billboard";
import { applyLightmap } from "./lightmap";
import { applyReflectionProbes } from "./probes";
import { applyDecals, decalItemLayers, refreshDecals } from "./decals";
import { applyFogVolumes, refreshFogVolumes } from "./fog_volumes";
import { fogPoolWarning, planFogPool } from "../../render/fog_select";
import { applyOccluders, refreshOccluders } from "./occluders";
import { SceneViewport, applyViewports, refreshViewports } from "./viewports";
import { SCENARIO_MAIN } from "../../render/viewport";
import { meshHasSkin } from "./skinning";
import { ParticleDraw, gatherParticles, orientParticles } from "./particles";
import { ParticleBox } from "../particles/pack";
import { ensureParticles } from "../particles/sim";
import { SHADER_TIME_ROLLOVER } from "../../render/shader/program";
import { ShaderMaterial } from "../resource/shader";

export { MATERIAL_BACKGROUND } from "./shading";

// How a frame shades its surfaces: `Lit`, the scene's own lights and
// environment (SHADE_LIT); every other one is a shading of Hedra's, drawn
// as the CLI's `render --shading <name> --overlay none` draws it: `Material`
// (its material mode, its studio rig and built-in environment), `Solid`
// (grey clay), `Wire` (the triangle edges alone), `WireSolid` (both),
// `Matcap` (Clay), `Normals`, `FaceOrient` (front faces blue, back faces
// red), `Random` (a colour per object, from its name) and `UvChecker`.
// Lit and Material come first, as milestone 4 numbered them.
export enum SceneShading {
    Lit,
    Material,
    Solid,
    Wire,
    WireSolid,
    Matcap,
    Normals,
    FaceOrient,
    Random,
    UvChecker,
    // Milestone 19: the baked light alone (SHADE_LIGHTMAP), the scene's
    // lights and environment planned as for lit.
    Lightmap,
    // Milestone 59: each surface in the colour of the number of lights
    // reaching it (SHADE_LIGHT_COUNT), the scene's lights planned as for lit.
    Lights,
}

export namespace SceneShading {
    // The shading a name selects (exactly), or -1.
    export function parse(s: string): i32 {
        // (Lights is the last)
        for (let i = 0; i <= <i32>SceneShading.Lights; i++) if (SceneShading.name(<SceneShading>i) == s) return i;
        return -1;
    }

    // Its name (commands.as SHADINGS lists the same, in the same order).
    export function name(s: SceneShading): string {
        switch (s) {
            case SceneShading.Lit: return "lit";
            case SceneShading.Material: return "material";
            case SceneShading.Solid: return "solid";
            case SceneShading.Wire: return "wire";
            case SceneShading.WireSolid: return "wire-solid";
            case SceneShading.Matcap: return "matcap";
            case SceneShading.Normals: return "normals";
            case SceneShading.FaceOrient: return "face-orient";
            case SceneShading.Random: return "random";
            case SceneShading.Lightmap: return "lightmap";
            case SceneShading.Lights: return "lights";
            default: return "uv-checker";
        }
    }

    // Every name, comma separated, for hints.
    export function names(): string {
        const out = new Array<string>();
        for (let i = 0; i <= <i32>SceneShading.Lights; i++) out.push(SceneShading.name(<SceneShading>i));
        return out.join(", ");
    }

    // The surface shader's mode (RenderFrame.shading): Hedra's
    // `Shading.modeId`, and SHADE_LIT for lit.
    export function modeId(s: SceneShading): u32 {
        switch (s) {
            case SceneShading.Lit: return SHADE_LIT;
            case SceneShading.Material: return SHADE_MATERIAL;
            case SceneShading.Matcap: return SHADE_MATCAP;
            case SceneShading.Normals: return SHADE_NORMALS;
            case SceneShading.FaceOrient: return SHADE_FACE_ORIENT;
            case SceneShading.Random: return SHADE_RANDOM;
            case SceneShading.UvChecker: return SHADE_UV_CHECKER;
            case SceneShading.Lightmap: return SHADE_LIGHTMAP;
            case SceneShading.Lights: return SHADE_LIGHT_COUNT;
            default: return SHADE_SOLID; // solid, wire, wire-solid
        }
    }

    // Whether the triangles are drawn (all but wire).
    export function drawsSurfaces(s: SceneShading): bool {
        return s != SceneShading.Wire;
    }

    // Whether every item's edges are drawn (wire and wire-solid).
    export function drawsEdges(s: SceneShading): bool {
        return s == SceneShading.Wire || s == SceneShading.WireSolid;
    }
}

export class SceneRenderOptions {
    // Pixels, before SSAA.
    width: u32 = 1024;
    height: u32 = 1024;
    ssaa: u32 = 1;
    // A camera node's path (relative to the root, or absolute, or %Unique:
    // SceneNode.getNode); null: `view` says.
    camera: string? = null;
    // The view when `camera` is null (views.as); the default is the
    // scene's: the current camera, else the framed default.
    view: SceneView = SceneView.scene();
    shading: SceneShading = SceneShading.Lit;
    // A camera in render space drawn through instead of `camera` and
    // `view` (the preview's navigation, editor/src/common/nav.as); null:
    // they say. The frame's view is then "free".
    freeCamera: Camera? = null;
    // The node outlined, by path from the root (SceneNode.getNode): its
    // items drawn active, its descendants' selected, in Hedra's
    // selection colours (the preview's selection). null, or a path that
    // names no node: no outline, as `render` draws.
    selected: string? = null;
    // Milestone 19: whether the scene's bake is drawn (lightmap.as), in the
    // lit and lightmap shadings. False draws every item with its own mesh
    // in real time, as a bake must see the scene (../bake/bake.as).
    lightmap: bool = true;
    // Milestone 25: a material every mesh item is drawn with instead of its
    // own (a MeshInstance3D's material_override and surfaces, a model's
    // materials, a MultiMesh's mesh's): Hedra's preview drawing a
    // model wholly in the material it edits (material_preview.as). null,
    // the default, draws each item's own, as before. Sprites keep theirs.
    overrideMaterial: StandardMaterial3D? = null;
    // Milestone 26: which form of each texture is drawn: TEXTURES_SOURCE
    // (the default: the files, as before), TEXTURES_IMPORTED (as the CLI's
    // `import` processed them, the first form the device takes) or a
    // hedra_engine/texture/format TextureForm (bc 1, etc2 2, astc 3: that form,
    // decoded on the CPU where the device does not take it). `render
    // --textures`, the editors' View › Imported Textures.
    textures: i32 = TEXTURES_SOURCE;
    // Milestone 26: a mesh's generated levels of detail are drawn while
    // their error, projected, stays under this many pixels (Godot's
    // mesh_lod_threshold); 0, the default, draws level 0 alone, as before.
    // Above 0, a mesh with no levels gets them once (meshes.as
    // provideLods: in the tools, the model's imported levels when current,
    // else generated), and SceneFrame.triangles counts the levels drawn.
    lodThreshold: f32 = 0;
    // Milestone 34: a SubViewport's path (as `camera`'s): the frame is that
    // viewport's view alone, as its texture holds it (its camera, its world,
    // its background; `width` and `height` as given: the caller sizes it,
    // the CLI's `render --viewport` at the viewport's size), the viewports
    // it shows drawn before it as for any frame. null, the default: the
    // scene's view. A path that names no SubViewport fails
    // (viewport-not-found, the hint listing the scene's SubViewports).
    viewport: string? = null;
    // Milestone 37: whether the frame culls with the scene's occluders
    // (occluders.as; `render --occlusion off` draws without, to compare).
    // True, the default: a scene without an OccluderInstance3D culls as
    // before either way.
    occlusion: bool = true;
    // Milestone 61: Godot's TIME of the custom shaders the frame draws, in
    // seconds (the scene's clock: the particles' too), wrapped at
    // SHADER_TIME_ROLLOVER into RenderFrame.shaderTime (`render --time`,
    // the run time's clock, the editor's view). 0, the default, draws
    // every other frame as before.
    time: f64 = 0;
    // Whether the occlusion buffer is coarser while the frame's view moves
    // (RenderFrame.occlusionMotion; a tool's one picture is always drawn
    // still, at the whole width).
    occlusionMotion: bool = true;
    // Milestone 62 (render/screen.as): the screen-space effects the frame
    // may draw when its scene turns them on (SCREEN_* bits: the editor's
    // View › Screen-Space Effects, render's --ssr, --screen-refraction and
    // --dof off), and their quality (the project's settings: hedra.yaml in
    // the tools, the registered project's at run time), copied into the
    // frame and its viewports' frames. The defaults, all and Godot's,
    // change no frame that turns none on.
    screenEffects: u32 = SCREEN_EFFECTS_ALL;
    screenQuality: ScreenQuality = new ScreenQuality();
    // Milestone 67 (../../render/quality.as): the render quality (the
    // project's settings in the tools and at run time, render's flags over
    // them), copied into the frame and its viewports' frames; the size FSR
    // 1.0 upscales the finished picture to (0: none).
    renderQuality: RenderQuality = new RenderQuality();
    outputWidth: u32 = 0;
    outputHeight: u32 = 0;
}

// Milestone 61: `seconds` as RenderFrame.shaderTime holds it: wrapped at
// SHADER_TIME_ROLLOVER (Godot's time_rollover_secs, 3600), 0 for a
// number that is not one.
export function shaderTimeOf(seconds: f64): f32 {
    if (!isFinite(seconds)) return 0;
    const r = SHADER_TIME_ROLLOVER;
    let w = seconds - Math.floor(seconds / r) * r;
    if (!(w >= 0 && w < r)) w = 0;
    return <f32>w;
}

// Milestone 61: points `sf`'s frame at TIME `seconds` (shaderTimeOf), for a
// frame drawn again with nothing else changed (the editor's every frame of
// a view whose custom shaders read TIME). Allocates nothing.
export function setSceneShaderTime(sf: SceneFrame, seconds: f64): void {
    sf.frame.shaderTime = shaderTimeOf(seconds);
}

// How deep a chain of next passes is followed (Godot follows every one;
// four is the renderer's budget, warned past it: the scene's
// material-next-pass-deep).
export const MAX_NEXT_PASSES: i32 = 4;

// SceneRenderOptions.textures besides the forms.
export const TEXTURES_SOURCE: i32 = -2;
export const TEXTURES_IMPORTED: i32 = -1;

// The outline colours of a selection: Hedra's (its scene_view.as
// SELECT_COLOR and ACTIVE_COLOR), sRGB.
export const SELECT_COLOR: Vec3 = Vec3(0.945, 0.345, 0.0);
export const ACTIVE_COLOR: Vec3 = Vec3(1.0, 0.627, 0.157);

export class SceneFrame {
    frame: RenderFrame;
    // The path of the camera looked through, from the root ("." for the
    // root itself); "" for the framed default and a preset.
    camera: string = "";
    // The view's label (views.as): "camera:<path>" through a camera, the
    // preset's name, "iso" for the framed default.
    view: string = "";
    // What was drawn: mesh items of the frame's own world (its scenario:
    // a SubViewport's world of its own is not counted), their triangles,
    // lights.
    meshes: i32 = 0;
    triangles: i64 = 0;
    lights: i32 = 0;
    // What the frame supplied because the scene had none, in this order:
    // "camera" (the framed default), "sun" (the preview sun),
    // "environment" (the preview environment).
    defaults: Array<string> = [];
    // What was left out or approximated ("70 lights in view: 6 are not
    // drawn (at most 64 a frame): ...", a texture setup the renderer cannot
    // draw).
    warnings: Array<string> = [];
    // Milestone 19: the items drawn from the scene's bake (their lightmap),
    // and those lit by its probes (lightmap.as); 0 without a bake.
    lightmapped: i32 = 0;
    probeLit: i32 = 0;
    // Milestone 20: the reflection probes the frame draws (probes.as); 0
    // without one.
    reflectionProbes: i32 = 0;
    // Milestone 33: the decals the frame carries (decals.as), their nodes
    // in the frame's order and their textures (DECAL_TEXTURES a node), for
    // the refresh; 0 and empty without one.
    decals: i32 = 0;
    decalNodes: Array<Decal> = [];
    decalTextures: Array<Texture2D?> = [];
    // Milestone 34: the SubViewports the frame shows (viewports.as), in
    // the frame's drawing order (RenderFrame.viewports, one each); empty
    // without one.
    viewports: Array<SceneViewport> = [];
    // Milestone 35: the CPUParticles3D nodes the frame draws (an item each,
    // in item order, a node with no mesh or that is hidden left out), the
    // items they are (f.items index, by node), and the particles drawn
    // over all of them (their InstanceData's counts); empty and 0 without
    // one (particles.as of the plan, ../particles/pack.as).
    particleNodes: Array<CPUParticles3D> = [];
    particleItems: Array<i32> = [];
    particles: i32 = 0;
    // What each of those items is packed from (particles.as), by node.
    particleDraws: Array<ParticleDraw> = [];
    // Milestone 37: the FogVolume nodes the frame carries (fog_volumes.as,
    // in the lit shading; RenderFrame.fogVolumes, one each, in order) and
    // the OccluderInstance3D nodes it culls with (occluders.as, in every
    // shading that draws surfaces; RenderFrame.occluders, one each, in
    // order), and how many; empty and 0 without one.
    fogNodes: Array<FogVolume> = [];
    fogVolumes: i32 = 0;
    occluderNodes: Array<OccluderInstance3D> = [];
    occluders: i32 = 0;
    // Milestone 34: the world the frame draws (RenderFrame.scenario's): the
    // SubViewport whose own world it is, null for the main one (a frame
    // through a camera of a world of its own, or `SceneRenderOptions.
    // viewport`'s); that SubViewport when the frame is its view
    // (`viewportNode`, as `planViewport` named it); and the background the
    // world clears to, opaque, before a transparent_bg makes it alpha 0.
    world: SubViewport? = null;
    viewportNode: SubViewport? = null;
    planViewport: string? = null;
    worldBackground: Vec4 = Vec4(0, 0, 0, 1);
    // Milestone 62 (screen.as): the camera attributes the frame draws with
    // (its camera's own, else its world's WorldEnvironment's; null: none),
    // and the exposure multiplier its environment was exposed with, which a
    // refresh in place follows (RenderFrame.dof refilled, the environment
    // exposed again when the multiplier moved).
    cameraAttributes: CameraAttributesPractical? = null;
    exposureMultiplier: f32 = 1;
    // The Camera3D the frame looks through (null: a free camera, a preset
    // view or the framed default), whatever the shading.
    viewCamera: Camera3D? = null;
    // The node each item was drawn for, by item (frame.items[i] is
    // itemNodes[i]'s; a model's parts are its ModelInstance3D's).
    itemNodes: Array<SceneNode> = [];
    // Render space: the box around each item as drawn (by item), and
    // around everything drawn (the unit box at the origin when nothing
    // is), which the default camera frames.
    itemBounds: Array<Bounds> = [];
    bounds: Bounds = Bounds(Vec3(-1, -1, -1), Vec3(1, 1, 1));
    // Milestone 16: the ArtboardSprite3D items, which depend on the camera
    // (sprites.as `orientSprites` turns them; empty for a frame without
    // sprites, which is as it was).
    sprites: Array<SpriteItem> = [];
    // Milestone 47 (../listen/pick.as): by item, the global transform its
    // node had when the frame was planned (scene space, 12 numbers each:
    // the columns x, y, z and the origin), so that a pointer between two
    // plans (a headless host draws no frame after the first) hits each item
    // where its node is now; and the materials by frame material key
    // (DrawItem.materials), so that a hit finds the ArtboardTexture its
    // surface shows.
    itemGlobals: Float64Array = new Float64Array(0);
    materialResources: Array<StandardMaterial3D> = [];
    // Milestone 50 (refreshSceneFrame): whether the frame may be refreshed
    // in place, and what that checks it against: the mesh each item was
    // gathered with (its node's blended copy, before a bake gives it its
    // lightmapped one), the camera node and lights it was planned with,
    // its environment and that environment's values then, each material's
    // shape (materialShape: its textures and switches), and the options
    // that change what a plan holds. (`lightNodes`, the lights by frame
    // index, is set by every plan of the lit, lightmap and lights
    // shadings: the pool's warning names them, milestone 59.)
    refreshable: bool = false;
    itemMeshes: Array<GpuMesh?> = [];
    cameraNode: Camera3D? = null;
    lightNodes: Array<Light3D> = [];
    environment: Environment? = null;
    environmentWrites: i32 = 0;
    environmentSky: Sky? = null;
    materialShapes: Array<i64> = [];
    materialTextures: Array<Texture2D?> = [];
    // Each material's numbers and colours as last written (materialDescStamp):
    // a refresh that changes none tells the renderer nothing.
    materialStamps: Int64Array = new Int64Array(0);
    planLod: f32 = 0;
    planLightmap: bool = true;
    planSsaa: u32 = 1;
    planTextures: i32 = TEXTURES_SOURCE;
    planCamera: string? = null;
    planView: SceneView? = null;
    // Set by each refresh: whether a material's numbers or colours changed
    // (the renderer then writes its kept groups' uniforms again:
    // MaterialBinder.valuesGeneration), and how many refreshes there were.
    materialsRefilled: bool = false;
    refreshes: i32 = 0;
    // The refresh's own lists and gatherer, made by the first refresh.
    walked: Array<SceneNode> = [];
    walkStack: Array<SceneNode> = [];
    refreshWarnings: Array<string> = [];
    gatherer: Gather? = null;
    // The root of the tree planned (null: a frame not planned from a
    // tree), so that the picker passes over an item whose node has left it
    // since.
    root: SceneNode? = null;
    // Milestone 61: the next passes' items (DrawItem.nextPassOf: after
    // every other item, `addNextPasses`), how many, and by each the item
    // whose node, mesh and place it draws again (its first owner); and by
    // material each one's next pass and shader textures as planned (a
    // refresh plans again when one changed: sameShape).
    nextPasses: i32 = 0;
    nextPassRoots: Array<i32> = [];
    materialNextPasses: Array<StandardMaterial3D?> = [];
    materialShaderTextures: Array<Array<Texture2D?>?> = [];

    constructor(frame: RenderFrame) {
        this.frame = frame;
    }
}

// The frame's materials while a frame is built: each resource once, its
// index the frame's material key.
class FrameMaterials {
    resources: Array<StandardMaterial3D> = [];
    // The keys whose UV set 1 warning was given (once per material).
    warnedSet1: Array<i64> = [];

    // Milestone 14, part 2: material `key` samples UV set 1 on a mesh with
    // one UV layer, which the renderer draws with set 0 (gpu/mesh_cache.as
    // `uv1Buffer`): says so, once per material.
    set1Missing(key: i64, f: RenderFrame, warnings: Array<string>): void {
        if (key < 0 || this.warnedSet1.includes(key)) return;
        const slots = slotsOnSet(f.materials[<i32>key], 1, false);
        if (slots.length == 0) return;
        this.warnedSet1.push(key);
        warnings.push("material '" + materialLabel(this.resources[<i32>key]) + "': " + slotNames(slots) + " "
            + (slots.length == 1 ? "samples" : "sample") + " UV set 1, which a mesh it is on does not have; "
            + "drawn with UV set 0");
    }

    // The key of `m` (-1 for none: the renderer's default material),
    // adding it to `f` on first use.
    key(m: StandardMaterial3D?, f: RenderFrame, cache: SceneRenderCache, warnings: Array<string>): i64 {
        if (m == null) return -1;
        for (let i = 0; i < this.resources.length; i++) if (this.resources[i] == m) return <i64>i;
        this.resources.push(m);
        f.materials.push(materialDesc(m, cache.textures, warnings));
        return <i64>(this.resources.length - 1);
    }
}

// The item colour Hedra gives an object (DrawItem.color: linear, its
// first material's base colour, else Hedra's 0.8 grey). The lit and
// material modes draw the materials instead; it is set so that a frame's
// items read as Hedra's do.
function itemColor(m: StandardMaterial3D?): Vec4 {
    if (m == null) return Vec4(srgbToLinear(0.8), srgbToLinear(0.8), srgbToLinear(0.8), 1.0);
    const c = m.albedoColor;
    return Vec4(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z), 1.0);
}

// DrawItem.castShadow of a node's items: its cast_shadow, a number out of
// range drawn as the nearest (CAST_SHADOW_OFF..CAST_SHADOW_SHADOWS_ONLY).
function castShadowOf(node: SceneNode): u32 {
    if (!(node instanceof GeometryInstance3D)) return CAST_SHADOW_ON;
    const c = (node as GeometryInstance3D).castShadow;
    return <u32>min<i32>(max<i32>(c, <i32>CAST_SHADOW_OFF), <i32>CAST_SHADOW_SHADOWS_ONLY);
}

// SceneNode.global(), number for number, through mulMat4.
function globalOf(n: SceneNode): Mat4 {
    const p = n.parent;
    if (p != null && p.is3d) return mulMat4(globalOf(p), n.local);
    return n.local;
}

// Milestone 47: SceneFrame.itemGlobals, each item's node's global
// transform now (the plan's), in scalar arithmetic as the interaction
// world's sync works it out, so that the picker compares like with like.
function recordItemGlobals(out: SceneFrame): void {
    const nodes = out.itemNodes;
    const g = new Float64Array(nodes.length * 12);
    const acc = new StaticArray<f64>(12);
    for (let i = 0; i < nodes.length; i++) {
        globalAffine(nodes[i], acc);
        for (let k = 0; k < 12; k++) g[i * 12 + k] = acc[k];
    }
    out.itemGlobals = g;
}

// The visibility range of a node's items (DrawItem.range*; the centre is
// set once every item is gathered, `rangeCentres`).
function rangeOf(node: SceneNode, item: DrawItem): void {
    if (!(node instanceof GeometryInstance3D)) return;
    const g = node as GeometryInstance3D;
    item.rangeBegin = g.rangeBegin;
    item.rangeBeginMargin = g.rangeBeginMargin;
    item.rangeEnd = g.rangeEnd;
    item.rangeEndMargin = g.rangeEndMargin;
    item.rangeFadeMode = <u32>min<i32>(max<i32>(g.rangeFadeMode, <i32>RANGE_FADE_DISABLED), <i32>RANGE_FADE_DEPENDENCIES);
}

// Milestone 61 (Godot's Material.next_pass): for each item of `f` drawn
// with a material that has a next pass, an item after every other drawing
// its mesh again with its materials' next passes (a range whose material
// has none: -1, not drawn), its `nextPassOf` the item it follows, placed,
// boxed, deformed and casting as its owner (copyNextPass); a next pass's
// own next pass is followed the same way, MAX_NEXT_PASSES deep (past it, a
// warning). Its pick id is 0 (the renderer leaves it out of the id pass:
// picking and the outline are its owner's). The items' nodes, boxes and
// meshes are their owners' (SceneFrame.itemNodes, itemBounds, itemMeshes:
// the bake, the probes and the decals treat them as their owners). How
// many there are.
function addNextPasses(f: RenderFrame, gather: Gather, out: SceneFrame): i32 {
    const items = f.items;
    const owners = items.length;
    const res = gather.materials.resources;
    const roots = out.nextPassRoots;
    roots.length = 0;
    let warned = false;
    for (let i = 0; i < owners; i++) {
        let from = i;
        for (let depth = 0; ; depth++) {
            const keys = items[from].materials;
            let any = false;
            for (let k = 0; k < keys.length; k++) {
                const key = keys[k];
                if (key >= 0 && res[<i32>key].nextPass != null) any = true;
            }
            if (!any) break;
            if (depth >= MAX_NEXT_PASSES) {
                if (!warned) {
                    warned = true;
                    out.warnings.push("material-next-pass-deep: next passes are drawn " + MAX_NEXT_PASSES.toString()
                        + " deep at most (Godot draws every one); the passes past them are not drawn");
                }
                break;
            }
            const owner = items[from];
            const item = new DrawItem();
            item.slot = <u32>items.length + 1;
            item.pickId = 0;
            item.nextPassOf = from;
            for (let k = 0; k < keys.length; k++) {
                const key = keys[k];
                const np = key >= 0 ? res[<i32>key].nextPass : null;
                item.materials.push(gather.materials.key(np, f, gather.cache, gather.warnings));
            }
            copyNextPass(item, owner);
            items.push(item);
            gather.nodes.push(gather.nodes[i]);
            gather.itemBounds.push(gather.itemBounds[i]);
            gather.meshes.push(gather.meshes[i]);
            roots.push(i);
            from = items.length - 1;
        }
    }
    return items.length - owners;
}

// A next pass's item drawn as its owner `o` is (addNextPasses): the same
// mesh, place, box, instances, skin, shadow, range, layers and colour.
function copyNextPass(d: DrawItem, o: DrawItem): void {
    d.scenario = o.scenario;
    d.world = o.world;
    d.normal = o.normal;
    d.color = o.color;
    d.mirrored = o.mirrored;
    d.mesh = o.mesh;
    d.instances = o.instances;
    d.castShadow = o.castShadow;
    d.bounds = o.bounds;
    d.hasBounds = o.hasBounds;
    d.rangeBegin = o.rangeBegin;
    d.rangeBeginMargin = o.rangeBeginMargin;
    d.rangeEnd = o.rangeEnd;
    d.rangeEndMargin = o.rangeEndMargin;
    d.rangeFadeMode = o.rangeFadeMode;
    d.rangeCenter = o.rangeCenter;
    d.skin = o.skin;
    d.skinJointCount = o.skinJointCount;
    d.skinVersion = o.skinVersion;
    d.layers = o.layers;
    d.captured = o.captured;
    d.noDepthTest = o.noDepthTest;
    d.emerge = o.emerge;
    d.emergeColor = o.emergeColor;
    d.fade = o.fade;
    d.fadeColor = o.fadeColor;
}

// Each next pass's item made again from its owner, now (a refresh, and
// after the plan's last change to the owners: their ranges' centres, the
// bake's meshes and probe light, the decals' layers, the selection).
function refreshNextPasses(f: RenderFrame, sf: SceneFrame): void {
    const items = f.items;
    const n = sf.nextPasses;
    const first = items.length - n;
    for (let j = 0; j < n; j++) {
        const d = items[first + j];
        const o = items[d.nextPassOf];
        copyNextPass(d, o);
        d.lightmapLayer = o.lightmapLayer;
        d.probeSh = o.probeSh;
        d.selected = o.selected;
        d.active = o.active;
        if (first + j < sf.itemBounds.length) sf.itemBounds[first + j] = sf.itemBounds[sf.nextPassRoots[j]];
    }
}

// Hedra's emerge of a node's items (DrawItem.emerge, emergeColor): its
// GeometryInstance3D's, clamped to 0..1; 1 (drawn as before) for any other node.
function emergeOf(node: SceneNode, item: DrawItem): void {
    if (!(node instanceof GeometryInstance3D)) {
        item.emerge = 1;
        return;
    }
    const g = node as GeometryInstance3D;
    item.emerge = g.emerge > 0 ? (g.emerge < 1 ? g.emerge : 1) : 0;
    item.emergeColor = g.emergeColor;
}

// Hedra's fade of a node's items (DrawItem.fade, fadeColor): its
// GeometryInstance3D's; 0 (drawn as before) for any other node.
function fadeOf(node: SceneNode, item: DrawItem): void {
    if (!(node instanceof GeometryInstance3D)) {
        item.fade = 0;
        item.fadeColor = Vec4(0, 0, 0, 1);
        return;
    }
    const g = node as GeometryInstance3D;
    item.fade = g.fade;
    item.fadeColor = g.fadeColor;
}

// Each item's rangeCenter: the centre of the box around every item of its
// node (a model's parts are measured as one, as Godot measures the node).
// A node's items are consecutive.
function rangeCentres(items: Array<DrawItem>, nodes: Array<SceneNode>, bounds: Array<Bounds>): void {
    let i = 0;
    while (i < items.length) {
        let j = i + 1;
        let b = bounds[i];
        while (j < items.length && nodes[j] === nodes[i]) {
            b = b.union(bounds[j]);
            j++;
        }
        const c = b.center();
        for (let k = i; k < j; k++) items[k].rangeCenter = c;
        i = j;
    }
}

// Milestone 48: what a node's skin and blend shapes make of one item
// (Gather.deform), filled in place: the mesh it draws, the box of that mesh
// in its own space (or, `inWorld`, in the frame's), and when skinned on the
// GPU its palette, joints and version; `identity` puts the item at the
// frame's origin (a skinned item, on the GPU or the CPU).
class Deform {
    mesh: GpuMesh? = null;
    local: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    inWorld: bool = false;
    identity: bool = false;
    skin: Float32Array? = null;
    joints: i32 = 0;
    version: u32 = 0;
}

// The object of part `part` of `model` (ModelInstance3D.parts: the
// part-th object with a mesh), or -1.
function partObject(model: ModelResource, part: i32): i32 {
    let k = 0;
    const objs = model.objects;
    for (let i = 0; i < objs.length; i++) {
        if (objs[i].mesh == null) continue;
        if (k == part) return i;
        k++;
    }
    return -1;
}

// Everything buildSceneFrame gathers while it walks the tree.
class Gather {
    f: RenderFrame;
    cache: SceneRenderCache;
    uploader: MeshUploader?;
    materials: FrameMaterials = new FrameMaterials();
    warnings: Array<string>;
    shading: SceneShading = SceneShading.Lit;
    bounds: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    hasBounds: bool = false;
    triangles: i64 = 0;
    // Milestone 26: SceneRenderOptions.lodThreshold (above 0: meshes get
    // their levels as they are added).
    lodThreshold: f32 = 0;
    // Milestone 48: `deform`'s answer, kept.
    private deformed: Deform = new Deform();
    // The node of each item added (SceneFrame.itemNodes), and its box.
    nodes: Array<SceneNode>;
    itemBounds: Array<Bounds>;
    // Milestone 50: the mesh each item was added with (SceneFrame.itemMeshes).
    meshes: Array<GpuMesh?> = [];
    // Milestone 34: the scenario of the node whose items are added next
    // (DrawItem.scenario): an item of another world than the frame's is in
    // neither box (the default camera frames the frame's world alone).
    scenario: i32 = 0;

    constructor(
        f: RenderFrame, cache: SceneRenderCache, uploader: MeshUploader?, warnings: Array<string>,
        nodes: Array<SceneNode>, itemBounds: Array<Bounds>,
    ) {
        this.f = f;
        this.cache = cache;
        this.uploader = uploader;
        this.warnings = warnings;
        this.nodes = nodes;
        this.itemBounds = itemBounds;
    }

    // One item: `mesh` placed by `global` (the node's, times the part's
    // own transform for a model part), its ranges' materials replaced by
    // `override` when there is one. `name` is what the random shading
    // colours it by: a model's object's name (as Hedra does), else the
    // node's. `node` is the node the item is drawn for.
    //
    // With `mm` (milestone 13), the item draws `mesh` once per instance of
    // the MultiMesh, each placed by its transform relative to the node:
    // `world` is then the node's alone, and a model's mesh is turned into
    // scene space by each instance (cache.as `instances`).
    //
    // Milestone 48: `part` is the part of a ModelInstance3D (-1 for any
    // other node), `nodeGlobal` the node's own global transform then (a
    // part's `global` has the part's place in the model too): the node's
    // skin and blend shapes may change what is drawn (`deform`).
    add(
        mesh: ArrayMesh, global: Mat4, override: StandardMaterial3D?, name: string, node: SceneNode,
        mm: MultiMesh? = null, part: i32 = -1, nodeGlobal: Mat4 = MAT4_IDENTITY,
    ): void {
        // (milestone 26: with a threshold, the levels come before the
        // mesh's first upload: cache.as `ready`)
        const e: SceneMesh = this.cache.entry(mesh, this.uploader, this.lodThreshold > 0);
        let g = e.gpu;
        if (g.indexCount == 0) return;
        const dv = mm == null ? this.deform(node, e, part, nodeGlobal) : null;
        if (dv != null) {
            const dm = dv.mesh;
            if (dm != null) g = dm;
        }
        const f = this.f;
        let inst: InstanceData? = null;
        if (mm != null) {
            inst = this.cache.instances(mm, e);
            if (inst.count == 0) return;
        }
        // A model's mesh is built in model space (Z up): it is turned into
        // scene space first, so that for an unmoved model the product is
        // Hedra's own world matrix (the conversions only permute and
        // negate). A primitive's triangles are in scene space already.
        let world = e.fromSource && inst == null ? SCENE_TO_MODEL * global * MODEL_TO_SCENE : mulMat4(SCENE_TO_MODEL, global);
        // (a skinned item: its palette places it, milestone 48)
        if (dv != null && dv.identity) world = MAT4_IDENTITY;
        const item = new DrawItem();
        item.scenario = this.scenario;
        item.instances = inst;
        item.slot = <u32>f.items.length + 1;
        item.pickId = item.slot;
        item.world = world;
        // The normal matrix (a plan of 10,000 items works it out 10,000
        // times: normalInto says how it stays Mat3's number for number).
        const det = normalInto(world, item);
        // A mirrored node (scale (-1, 1, 1)) turns its triangles over: the
        // shader must know, or it lights the inside (Godot flips the front
        // face of such an instance).
        item.mirrored = det < 0;
        item.mesh = g;
        let first: StandardMaterial3D? = null;
        const src = mesh.source;
        for (let k = 0; k < g.ranges.length; k++) {
            let m: StandardMaterial3D? = override;
            if (m == null) m = this.rangeMaterial(e, g.ranges[k].slot);
            if (k == 0) first = m;
            const key = this.materials.key(m, f, this.cache, this.warnings);
            item.materials.push(key);
            if (g.uv1 == null) this.materials.set1Missing(key, f, this.warnings);
        }
        // Modeler colours an object by its material slot 0 (milestone 39: a
        // prebuilt mesh carries that material, as it carries its object's
        // name, with no model to look it up in).
        const pre = mesh.prebuilt;
        if (override == null && e.fromSource && pre != null) {
            first = pre.colorMaterial;
        } else if (override == null && e.fromSource && src != null) {
            const from = src.model.source;
            if (from != null && from.objectName(src.objectId) != null) {
                const mi = from.materialIndex(src.objectId, 0);
                first = mi >= 0 && mi < <i64>src.model.materials.length ? src.model.materials[<i32>mi] : null;
            }
        }
        item.color = this.colorOf(first);
        if (this.shading == SceneShading.Random) {
            let objectName = name;
            if (e.fromSource && pre != null) {
                objectName = pre.objectName;
            } else if (e.fromSource && src != null) {
                const from = src.model.source;
                const known = from != null ? from.objectName(src.objectId) : null;
                if (known != null) objectName = known;
            }
            item.color = hashColor(objectName);
        }
        item.showEdges = SceneShading.drawsEdges(this.shading);
        item.castShadow = castShadowOf(node);
        rangeOf(node, item);
        emergeOf(node, item);
        fadeOf(node, item);
        if (dv != null) {
            item.skin = dv.skin;
            item.skinJointCount = dv.joints;
            item.skinVersion = dv.version;
        }
        f.items.push(item);
        this.nodes.push(node);
        this.meshes.push(g);
        const copies: i64 = inst != null ? <i64>inst.count : 1;
        if (item.scenario == f.scenario) this.triangles += <i64>(g.indexCount / 3) * copies;
        if (dv != null) {
            this.boxed(item, dv.inWorld ? dv.local : dv.local.transformed(world));
            return;
        }
        this.boxed(item, inst != null ? inst.local.transformed(world) : e.local.transformed(world));
    }

    // Milestone 50 (refreshSceneFrame): item `i` of the frame made again
    // in place for `mesh` placed by `global`, as `add` would make it, the
    // frame's materials and mesh being those it was planned with: 1 when
    // it was, 0 when `add` would have added no item (the item `i` is then
    // another node's), -1 when the item no longer fits (another mesh, a
    // material of another key, instances where there were none): the
    // frame must be planned again. Allocates nothing.
    update(
        i: i32, sf: SceneFrame, mesh: ArrayMesh, global: Mat4, override: StandardMaterial3D?, node: SceneNode,
        mm: MultiMesh? = null, part: i32 = -1, nodeGlobal: Mat4 = MAT4_IDENTITY,
    ): i32 {
        const e: SceneMesh = this.cache.entry(mesh, this.uploader, this.lodThreshold > 0);
        let g = e.gpu;
        if (g.indexCount == 0) return 0;
        const dv = mm == null ? this.deform(node, e, part, nodeGlobal) : null;
        if (dv != null) {
            const dm = dv.mesh;
            if (dm != null) g = dm;
        }
        const f = this.f;
        let inst: InstanceData? = null;
        if (mm != null) {
            inst = this.cache.instances(mm, e);
            if (inst.count == 0) return 0;
        }
        if (i >= f.items.length || sf.itemNodes[i] !== node || sf.itemMeshes[i] !== g) return -1;
        const item = f.items[i];
        if (item.instances !== inst) return -1;
        if (item.materials.length != g.ranges.length) return -1;
        let first: StandardMaterial3D? = null;
        const mats = sf.materialResources;
        for (let k = 0; k < g.ranges.length; k++) {
            let m: StandardMaterial3D? = override;
            if (m == null) m = this.rangeMaterial(e, g.ranges[k].slot);
            if (k == 0) first = m;
            const key = item.materials[k];
            if (m == null ? key != -1 : (key < 0 || mats[<i32>key] !== m)) return -1;
        }
        let world = e.fromSource && inst == null ? SCENE_TO_MODEL * global * MODEL_TO_SCENE : mulMat4(SCENE_TO_MODEL, global);
        if (dv != null && dv.identity) world = MAT4_IDENTITY;
        item.world = world;
        const det = normalInto(world, item);
        item.mirrored = det < 0;
        // (as a new item has them: the bake, applied again after the
        // items, gives each its lightmapped mesh, layer and probe light)
        item.mesh = g;
        item.lightmapLayer = -1;
        item.probeSh = null;
        const pre = mesh.prebuilt;
        const src = mesh.source;
        if (override == null && e.fromSource && pre != null) {
            first = pre.colorMaterial;
        } else if (override == null && e.fromSource && src != null) {
            const from = src.model.source;
            if (from != null && from.objectName(src.objectId) != null) {
                const mi = from.materialIndex(src.objectId, 0);
                first = mi >= 0 && mi < <i64>src.model.materials.length ? src.model.materials[<i32>mi] : null;
            }
        }
        item.color = this.colorOf(first);
        item.castShadow = castShadowOf(node);
        rangeOf(node, item);
        emergeOf(node, item);
        fadeOf(node, item);
        if (dv != null) {
            item.skin = dv.skin;
            item.skinJointCount = dv.joints;
            item.skinVersion = dv.version;
        } else {
            item.skin = null;
            item.skinJointCount = 0;
            item.skinVersion = 0;
        }
        const copies: i64 = inst != null ? <i64>inst.count : 1;
        if (item.scenario == f.scenario) this.triangles += <i64>(g.indexCount / 3) * copies;
        let b: Bounds;
        if (dv != null) b = dv.inWorld ? dv.local : dv.local.transformed(world);
        else b = inst != null ? inst.local.transformed(world) : e.local.transformed(world);
        this.reboxed(i, item, b);
        return 1;
    }

    // Milestone 50: starts a refresh's gathering (`update`).
    begin(): void {
        this.bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
        this.hasBounds = false;
        this.triangles = 0;
        this.colorKnown = false;
    }

    // Milestone 50: `boxed` for an item made again in place (`update`).
    private reboxed(i: i32, item: DrawItem, b: Bounds): void {
        const f = this.f;
        item.bounds = b;
        item.hasBounds = true;
        this.itemBounds[i] = b;
        // (milestone 34: another world's item is in neither box)
        if (item.scenario != f.scenario) return;
        if (item.castShadow != CAST_SHADOW_OFF) {
            f.casterBounds = f.hasCasters ? f.casterBounds.union(b) : b;
            f.hasCasters = true;
        }
        if (item.castShadow == CAST_SHADOW_SHADOWS_ONLY) return;
        this.bounds = this.hasBounds ? this.bounds.union(b) : b;
        this.hasBounds = true;
    }

    // Milestone 50: `addSprite` made again in place for item `i` and its
    // SpriteItem `si` (see `update`).
    updateSprite(i: i32, sf: SceneFrame, s: ArtboardSprite3D, global: Mat4, si: SpriteItem): i32 {
        const t = s.texture;
        if (t == null) return 0;
        const rect = spriteRect(t.width, t.height, s.pixelSize, s.centered, s.offset);
        if (!(rect.z > 0) || !(rect.w > 0)) return 0;
        const f = this.f;
        if (i >= f.items.length || sf.itemNodes[i] !== s || si.item != i || si.node !== s) return -1;
        const e: SceneMesh = this.cache.entry(spriteQuad(s.flipH, s.flipV), this.uploader);
        const g = e.gpu;
        if (sf.itemMeshes[i] !== g || si.mesh !== g) return -1;
        const item = f.items[i];
        if (item.materials.length != g.ranges.length || g.ranges.length == 0) return -1;
        const key = item.materials[0];
        if (key < 0) return -1;
        const m = sf.materialResources[<i32>key];
        if (m.albedoTexture !== t) return -1;
        const placement = spritePlacement(rect, s.axis);
        const world = mulMat4(SCENE_TO_MODEL, mulMat4(global, placement));
        item.world = world;
        item.mirrored = normalInto(world, item) < 0;
        item.color = this.shading == SceneShading.Random ? item.color : this.colorOf(m);
        const cast = castShadowOf(s);
        item.castShadow = cast;
        item.noDepthTest = s.noDepthTest;
        rangeOf(s, item);
        emergeOf(s, item);
        fadeOf(s, item);
        if (item.scenario == f.scenario) this.triangles += <i64>(g.indexCount / 3);
        let b: Bounds;
        if (s.billboard == BILLBOARD_ENABLED || s.billboard == BILLBOARD_FIXED_Y) {
            const o = global.wAxis;
            const c = Vec3(o.x, -o.z, o.y);
            const r = billboardRadius(global, placement);
            b = Bounds(c - Vec3(r, r, r), c + Vec3(r, r, r));
        } else {
            b = e.local.transformed(world);
        }
        this.reboxed(i, item, b);
        si.global = global;
        si.placement = placement;
        si.billboard = s.billboard;
        si.doubleSided = s.doubleSided;
        si.castShadow = cast;
        return 1;
    }

    // Milestone 48 (see the header): what `node`'s skin and blend shapes
    // make of the mesh `e` (part `part` of a ModelInstance3D placed by
    // `nodeGlobal`, or a MeshInstance3D's), or null when they change
    // nothing (no skin it can draw, no weight but 0): the item is then
    // drawn as before. The answer is kept (`deformed`); allocates nothing
    // once the node's palette and copies exist.
    private deform(node: SceneNode, e: SceneMesh, part: i32, nodeGlobal: Mat4): Deform? {
        const base = e.gpu;
        let weights: Array<f32>? = null;
        let weightsVersion: u32 = 0;
        let skinned = false;
        let model: ModelResource? = null;
        let object = -1;
        const isMesh = node instanceof MeshInstance3D;
        const isModel = node instanceof ModelInstance3D;
        if (isMesh) {
            const mi = node as MeshInstance3D;
            if (mi.blendShapeWeights.length > 0) weights = mi.blendShapeWeights;
            weightsVersion = mi.blendVersion;
            skinned = mi.skin != null;
        } else if (isModel && part >= 0) {
            model = (node as ModelInstance3D).model;
            if (model == null) return null;
            object = partObject(model, part);
            if (object < 0) return null;
            const o = model.objects[object];
            if (o.blendShapeWeights.length > 0) weights = o.blendShapeWeights;
            skinned = o.skin != null;
        } else {
            return null;
        }
        const morphs = base.morphs;
        const blends = weights != null && morphs != null;
        skinned = skinned && meshHasSkin(base);
        if (!blends && !skinned) return null;
        const cache = this.cache;
        const nd = cache.deformOf(node);
        const k = part >= 0 ? part : 0;
        const out = this.deformed;
        let g = base;
        let local = e.local;
        if (blends && weights != null) {
            const mc = nd.morph(k);
            g = mc.blended(base, weights, weightsVersion, this.uploader, cache.replaced);
            if (g !== base) local = mc.local;
        }
        out.mesh = g;
        out.local = local;
        out.inWorld = false;
        out.identity = false;
        out.skin = null;
        out.joints = 0;
        out.version = 0;
        if (skinned) {
            const st = nd.skin(k);
            let n = 0;
            if (isMesh) {
                n = st.update(node as MeshInstance3D, SCENE_TO_MODEL);
            } else if (model != null) {
                const rel = nd.filePose(k, model, object);
                if (rel != null) n = st.updateFixed(rel, mulMat4(SCENE_TO_MODEL, nodeGlobal));
            }
            if (n > 0) {
                out.identity = true;
                out.inWorld = true;
                if (SceneShading.drawsEdges(this.shading)) {
                    // (the wire shadings: skinned here, drawn as it is)
                    const cs = nd.cpu(k);
                    out.mesh = cs.skinned(g, st.palette, n, st.version, weightsVersion, this.uploader, cache.replaced);
                    out.local = cs.local;
                } else {
                    out.skin = st.palette;
                    out.joints = n;
                    out.version = st.version;
                    // (the box the GPU's vertices fill: the framing and
                    // culling of what is drawn)
                    out.local = st.bounds(g, local, g !== base ? weightsVersion : 0);
                }
            }
        }
        if (g === base && !out.identity) return null;
        return out;
    }

    // Gives the item just added its box `b`, and counts it in the
    // casters' box and in the box the default camera frames.
    private boxed(item: DrawItem, b: Bounds): void {
        const f = this.f;
        item.bounds = b;
        item.hasBounds = true;
        this.itemBounds.push(b);
        // (milestone 34: another world's item is in neither box)
        if (item.scenario != f.scenario) return;
        if (item.castShadow != CAST_SHADOW_OFF) {
            f.casterBounds = f.hasCasters ? f.casterBounds.union(b) : b;
            f.hasCasters = true;
        }
        // A shadows-only item is not in the picture: the default camera
        // frames what is drawn.
        if (item.castShadow == CAST_SHADOW_SHADOWS_ONLY) return;
        this.bounds = this.hasBounds ? this.bounds.union(b) : b;
        this.hasBounds = true;
    }

    // Milestone 16: an ArtboardSprite3D's item (sprites.as): the shared
    // quad placed on the sprite's rectangle, drawn with a material made
    // for the sprite, and its SpriteItem on `sprites`, which orientSprites
    // turns to the camera once the camera is chosen (until then the world
    // is the quad as placed, unturned). Nothing when the sprite has no
    // texture or an empty rectangle (../warnings.as says so).
    addSprite(s: ArtboardSprite3D, global: Mat4, sprites: Array<SpriteItem>): void {
        const t = s.texture;
        if (t == null) return;
        const rect = spriteRect(t.width, t.height, s.pixelSize, s.centered, s.offset);
        if (!(rect.z > 0) || !(rect.w > 0)) return;
        const placement = spritePlacement(rect, s.axis);
        const e: SceneMesh = this.cache.entry(spriteQuad(s.flipH, s.flipV), this.uploader);
        const g = e.gpu;
        const f = this.f;
        const world = mulMat4(SCENE_TO_MODEL, mulMat4(global, placement));
        const item = new DrawItem();
        item.scenario = this.scenario;
        item.slot = <u32>f.items.length + 1;
        item.pickId = item.slot;
        item.world = world;
        item.mirrored = normalInto(world, item) < 0;
        item.mesh = g;
        const m = spriteMaterial(s);
        for (let k = 0; k < g.ranges.length; k++) {
            const key = this.materials.key(m, f, this.cache, this.warnings);
            item.materials.push(key);
            if (g.uv1 == null) this.materials.set1Missing(key, f, this.warnings);
        }
        item.color = this.shading == SceneShading.Random ? hashColor(s.name) : this.colorOf(m);
        item.showEdges = SceneShading.drawsEdges(this.shading);
        item.castShadow = castShadowOf(s);
        item.noDepthTest = s.noDepthTest;
        rangeOf(s, item);
        emergeOf(s, item);
        fadeOf(s, item);
        f.items.push(item);
        this.nodes.push(s);
        this.meshes.push(g);
        if (item.scenario == f.scenario) this.triangles += <i64>(g.indexCount / 3);
        // A billboard turns with the camera: its box is that of the sphere
        // it turns in, about the node's origin, so that the box holds from
        // every camera (a retarget keeps it) and the default camera, chosen
        // before any turn, frames it.
        let b: Bounds;
        if (s.billboard == BILLBOARD_ENABLED || s.billboard == BILLBOARD_FIXED_Y) {
            const o = global.wAxis;
            const c = Vec3(o.x, -o.z, o.y); // scene to render space (../space.as sceneToModel)
            const r = billboardRadius(global, placement);
            b = Bounds(c - Vec3(r, r, r), c + Vec3(r, r, r));
        } else {
            b = e.local.transformed(world);
        }
        this.boxed(item, b);
        sprites.push(new SpriteItem(f.items.length - 1, s, global, placement, item.castShadow, g));
    }

    // Milestone 35: a CPUParticles3D's item (particles.as): its mesh drawn
    // once per living particle, the particles packed in the node's space
    // (ParticleState.instances), placed by the node as a MultiMesh is, its
    // materials the mesh's surfaces' (`override`: the material preview's),
    // recorded on `sf` (particleNodes, particleItems, particleDraws).
    // Nothing when the node has no mesh or its mesh no triangle.
    addParticles(p: CPUParticles3D, global: Mat4, override: StandardMaterial3D?, sf: SceneFrame): void {
        const mesh = p.mesh;
        if (mesh == null) return;
        const e: SceneMesh = this.cache.entry(mesh.arrays(), this.uploader, this.lodThreshold > 0);
        const g = e.gpu;
        if (g.indexCount == 0) return;
        const s = ensureParticles(p);
        const inst = s.instances;
        this.cache.keepParticles(inst);
        const f = this.f;
        const world = mulMat4(SCENE_TO_MODEL, global);
        const item = new DrawItem();
        item.scenario = this.scenario;
        item.instances = inst;
        item.slot = <u32>f.items.length + 1;
        item.pickId = item.slot;
        item.world = world;
        item.mirrored = normalInto(world, item) < 0;
        item.mesh = g;
        let first: StandardMaterial3D? = null;
        let own: StandardMaterial3D? = null;
        for (let k = 0; k < g.ranges.length; k++) {
            const mine = this.rangeMaterial(e, g.ranges[k].slot);
            let m: StandardMaterial3D? = override;
            if (m == null) m = mine;
            if (k == 0) {
                first = m;
                own = mine;
            }
            const key = this.materials.key(m, f, this.cache, this.warnings);
            item.materials.push(key);
            if (g.uv1 == null) this.materials.set1Missing(key, f, this.warnings);
        }
        item.color = this.shading == SceneShading.Random ? hashColor(p.name) : this.colorOf(first);
        item.showEdges = SceneShading.drawsEdges(this.shading);
        item.castShadow = castShadowOf(p);
        rangeOf(p, item);
        emergeOf(p, item);
        fadeOf(p, item);
        f.items.push(item);
        this.nodes.push(p);
        this.meshes.push(g);
        const at = f.items.length - 1;
        const d = new ParticleDraw(p, at, own);
        d.mesh = mesh;
        d.global = global;
        d.meshLocal = e.local;
        const n = gatherParticles(d, this.particleBox);
        if (item.scenario == f.scenario) this.triangles += <i64>(g.indexCount / 3) * <i64>n;
        this.boxed(item, this.particleBounds(world));
        sf.particleNodes.push(p);
        sf.particleItems.push(at);
        sf.particleDraws.push(d);
    }

    // Milestone 35: `addParticles` made again in place for item `i` and its
    // ParticleDraw `d` (see `update`: 1, 0 or -1). Allocates nothing.
    updateParticles(i: i32, sf: SceneFrame, p: CPUParticles3D, global: Mat4, d: ParticleDraw): i32 {
        const mesh = p.mesh;
        if (mesh == null) return 0;
        const e: SceneMesh = this.cache.entry(mesh.arrays(), this.uploader, this.lodThreshold > 0);
        const g = e.gpu;
        if (g.indexCount == 0) return 0;
        const f = this.f;
        if (i >= f.items.length || sf.itemNodes[i] !== p || sf.itemMeshes[i] !== g || d.node !== p || d.item != i) {
            return -1;
        }
        const s = ensureParticles(p);
        const item = f.items[i];
        if (item.instances !== s.instances || item.materials.length != g.ranges.length) return -1;
        let first: StandardMaterial3D? = null;
        let own: StandardMaterial3D? = null;
        const mats = sf.materialResources;
        for (let k = 0; k < g.ranges.length; k++) {
            const m = this.rangeMaterial(e, g.ranges[k].slot);
            if (k == 0) {
                first = m;
                own = m;
            }
            const key = item.materials[k];
            if (m == null ? key != -1 : (key < 0 || mats[<i32>key] !== m)) return -1;
        }
        this.cache.keepParticles(s.instances);
        const world = mulMat4(SCENE_TO_MODEL, global);
        item.world = world;
        item.mirrored = normalInto(world, item) < 0;
        item.mesh = g;
        item.lightmapLayer = -1;
        item.probeSh = null;
        item.color = this.colorOf(first);
        item.castShadow = castShadowOf(p);
        rangeOf(p, item);
        emergeOf(p, item);
        fadeOf(p, item);
        d.material = own;
        d.global = global;
        d.meshLocal = e.local;
        const n = gatherParticles(d, this.particleBox);
        if (item.scenario == f.scenario) this.triangles += <i64>(g.indexCount / 3) * <i64>n;
        this.reboxed(i, item, this.particleBounds(world));
        return 1;
    }

    // The kept box of the particles just gathered (particleBox), in the
    // frame's world (`world` the item's); a point at the node's origin when
    // none is alive.
    private particleBox: ParticleBox = new ParticleBox();

    private particleBounds(world: Mat4): Bounds {
        const pb = this.particleBox;
        if (pb.has) return pb.box.transformed(world);
        const o = world.wAxis.xyz();
        return Bounds(o, o);
    }

    // itemColor(m), worked out once per material in a row (three sRGB
    // curves an item add up over thousands of items sharing one).
    private colorMaterial: StandardMaterial3D? = null;
    private colorKnown: bool = false;
    private color: Vec4 = Vec4(0, 0, 0, 0);

    colorOf(m: StandardMaterial3D?): Vec4 {
        if (!this.colorKnown || this.colorMaterial !== m) {
            this.color = itemColor(m);
            this.colorMaterial = m;
            this.colorKnown = true;
        }
        return this.color;
    }

    // The material of a range of `e`: a model mesh's range names one of
    // the object's material slots, whose scene material is the model's
    // material of the same index; any other mesh's range k is surface k.
    rangeMaterial(e: SceneMesh, slot: u16): StandardMaterial3D? {
        // Milestone 39: a prebuilt mesh holds its slots' materials.
        const pre = e.mesh.prebuilt;
        if (pre != null) {
            const mats = pre.slotMaterials;
            return <i32>slot < mats.length ? mats[<i32>slot] : null;
        }
        const src = e.mesh.source;
        if (e.fromSource && src != null) {
            const from = src.model.source;
            if (from == null) return null;
            const mi = from.materialIndex(src.objectId, slot);
            return mi >= 0 && mi < <i64>src.model.materials.length ? src.model.materials[<i32>mi] : null;
        }
        const surfaces = e.mesh.surfaces;
        return <i32>slot < surfaces.length ? surfaces[<i32>slot].material : null;
    }
}

// One frame of `tree` as `opts` asks. Meshes come from `cache`, built on
// first use and uploaded through `uploader` (null: built on the CPU only,
// for a plan or a test; `cache.upload` uploads them later). Fails with a
// SceneryError when `opts.camera` names no node (code "camera-not-found")
// or a node that is not a Camera3D ("not-a-camera"), with a hint listing
// the scene's cameras. With `opts.freeCamera` no camera is looked up.
export function buildSceneFrame(
    tree: SceneTree, opts: SceneRenderOptions, cache: SceneRenderCache, uploader: MeshUploader?,
): Result<SceneFrame> {
    // The camera node first: a wrong --camera fails before any work.
    let camNode: Camera3D? = null;
    let preset: i32 = -1;
    const free = opts.freeCamera;
    let path = opts.camera;
    const view = opts.view;
    if (path == null && view.kind == SceneViewKind.Camera) path = view.camera;
    const all = tree.walk();
    // Milestone 34: a SubViewport's view (`opts.viewport`) looks through its
    // camera, and fails before any work when it has none.
    const vpath = opts.viewport;
    let viewNode: SubViewport? = null;
    if (vpath != null) {
        const r = findViewport(tree, all, vpath);
        if (!r.ok) return r.forward<SceneFrame>();
        viewNode = r.value;
    }
    if (free != null) {
        // (the free camera is the view: no node is looked through)
    } else if (viewNode != null) {
        camNode = viewportCameraOf(all, viewNode);
        if (camNode == null) {
            return SceneryError.at("viewport-no-camera", tree.root.sceneFile, 0, 0, "SubViewport " + viewNode.path()
                + " has no Camera3D: it draws nothing", "add a Camera3D under it; see " + VIEWPORTS_HINT_DOC)
                .fail<SceneFrame>();
        }
    } else if (path != null) {
        const r = findCamera(tree, path, tree.root.sceneFile);
        if (!r.ok) return r.forward<SceneFrame>();
        camNode = r.value;
    } else if (view.kind == SceneViewKind.Preset) {
        preset = view.preset;
    } else {
        camNode = tree.currentCamera();
    }

    const w = max<u32>(opts.width, 1);
    const h = max<u32>(opts.height, 1);
    const aspect = <f32>w / <f32>h;
    const unit = Bounds(Vec3(-1, -1, -1), Vec3(1, 1, 1));
    // The camera is set once the bounds are known.
    const f = new RenderFrame(w, h, framedCamera(unit, aspect));
    const out = new SceneFrame(f);
    out.root = tree.root;
    f.ssaa = max<u32>(opts.ssaa, 1);
    f.gridExtent = 0;
    f.outline = false;
    f.overlay = null;
    f.drawSurfaces = true;
    f.materialMode = true;

    // --- the world (milestone 34) ---------------------------------------
    // The frame draws one world (viewports.as): the main one, else the own
    // world of the SubViewport it is the view of, or of the camera it looks
    // through. A scene without a SubViewport is the main world's alone.
    const subs = new Array<SubViewport>();
    for (let i = 0; i < all.length; i++) {
        const isViewport = all[i] instanceof SubViewport;
        if (isViewport) subs.push(all[i] as SubViewport);
    }
    const worlds = subs.length > 0;
    let world: SubViewport? = null;
    if (viewNode != null) world = viewNode.ownWorld3d ? viewNode : worldViewportOf(viewNode);
    else if (camNode != null && worlds) world = worldViewportOf(camNode);
    f.scenario = world != null ? subs.indexOf(world) + 1 : SCENARIO_MAIN;
    out.world = world;
    out.viewportNode = viewNode;
    out.planViewport = vpath;

    // --- items ---------------------------------------------------------
    const gather = new Gather(f, cache, uploader, out.warnings, out.itemNodes, out.itemBounds);
    gather.shading = opts.shading;
    gather.lodThreshold = opts.lodThreshold;
    const every = opts.overrideMaterial;
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        const isMesh = n instanceof MeshInstance3D;
        const isModel = n instanceof ModelInstance3D;
        const isMulti = n instanceof MultiMeshInstance3D;
        const isSprite = n instanceof ArtboardSprite3D;
        const isParticles = n instanceof CPUParticles3D;
        if (!isMesh && !isModel && !isMulti && !isSprite && !isParticles) continue;
        if (!n.visibleInTree()) continue;
        if (worlds) {
            const own = worldViewportOf(n);
            gather.scenario = own != null ? subs.indexOf(own) + 1 : SCENARIO_MAIN;
        }
        const global = globalOf(n);
        if (isSprite) {
            gather.addSprite(n as ArtboardSprite3D, global, out.sprites);
        } else if (isParticles) {
            // (milestone 35: particles.as)
            gather.addParticles(n as CPUParticles3D, global, every, out);
        } else if (isMulti) {
            // Only 3D transforms are drawn (the validator warns of 2D too:
            // `multimesh-2d`); a drawn node's 2D MultiMesh is said once.
            const mm = (n as MultiMeshInstance3D).multimesh;
            if (mm != null && mm.transformFormat == 1) {
                const mesh = mm.mesh;
                if (mesh != null) gather.add(mesh.arrays(), global, every, n.name, n, mm);
            } else if (mm != null && mm.transformFormat == 0) {
                const said = "multimesh " + mm.id + ": transform_2d instances are not drawn";
                if (!out.warnings.includes(said)) out.warnings.push(said);
            }
        } else if (isMesh) {
            const mi = n as MeshInstance3D;
            const mesh = mi.mesh;
            if (mesh != null) gather.add(mesh.arrays(), global, every != null ? every : mi.materialOverride, n.name, n);
        } else {
            const parts = (n as ModelInstance3D).parts();
            for (let k = 0; k < parts.length; k++) {
                const p = parts[k];
                // (milestone 48: the part's index, for its skin and blend
                // shapes, and the node's own placement for its palette)
                if (p.visible) gather.add(p.mesh, global * p.local, every, n.name, n, null, k, global);
            }
        }
    }
    // Milestone 61: the next passes' items, after every other.
    out.nextPasses = addNextPasses(f, gather, out);
    f.shaderTime = shaderTimeOf(opts.time);
    f.screenEffects = opts.screenEffects;
    f.screenQuality.copyFrom(opts.screenQuality);
    f.renderQuality.copyFrom(opts.renderQuality);
    f.outputWidth = opts.outputWidth;
    f.outputHeight = opts.outputHeight;
    // What this view draws: its own world's items (another world's are
    // drawn by the viewports that show it, and counted by none here; nor
    // a next pass's, which draws its owner again).
    let ownItems = 0;
    for (let i = 0; i < f.items.length; i++) {
        if (f.items[i].scenario == f.scenario && f.items[i].nextPassOf < 0) ownItems++;
    }
    out.meshes = ownItems;
    out.triangles = gather.triangles;
    out.materialResources = gather.materials.resources;
    recordItemGlobals(out);
    rangeCentres(f.items, out.itemNodes, out.itemBounds);
    if (out.nextPasses > 0) refreshNextPasses(f, out);
    cache.seedRanges(f, out.itemNodes);

    // --- camera --------------------------------------------------------
    // Modeler frames an empty scene as a 2-unit box at the origin.
    const bounds = gather.hasBounds ? gather.bounds : unit;
    out.bounds = bounds;
    f.drawBounds = gather.bounds;
    f.hasDrawBounds = gather.hasBounds;
    if (free != null) {
        f.camera = free.clone();
        out.camera = "";
        out.view = "free";
    } else if (camNode != null) {
        f.camera = cameraOf(camNode, bounds, aspect);
        out.camera = camNode.path();
        out.viewCamera = camNode;
        out.view = viewNode != null ? "viewport:" + viewNode.path() : "camera:" + out.camera;
        if (camNode.projection != 1 && !(camNode.fov >= MIN_FOV && camNode.fov <= MAX_FOV)) {
            out.warnings.push("camera " + camNode.path() + ": fov " + displayF32(camNode.fov) + " is drawn as "
                + displayF32(clampF32(camNode.fov, MIN_FOV, MAX_FOV)) + " (a fov is 1 to 179 degrees)");
        }
    } else if (preset >= 0) {
        f.camera = presetCamera(<ViewPreset>preset, bounds, aspect);
        out.camera = "";
        out.view = ViewPreset.name(<ViewPreset>preset);
    } else {
        f.camera = framedCamera(bounds, aspect);
        out.camera = "";
        out.view = ViewPreset.name(ViewPreset.Iso);
        out.defaults.push("camera");
    }

    // Milestone 16: the sprites turned to the camera just chosen.
    orientSprites(f, out.sprites);
    // Milestone 35: the billboards and view_depth particles packed for it.
    if (out.particleDraws.length > 0) out.particles = orientParticles(f, out.particleDraws);


    // --- the selection ---------------------------------------------------
    outlineSelection(tree, opts.selected, f, out.itemNodes);

    // Milestone 37: the occluders the frame culls with (occluders.as), in
    // every shading that draws surfaces; a scene without one gets nothing.
    if (SceneShading.drawsSurfaces(opts.shading)) {
        out.occluders = applyOccluders(all, f, opts.occlusion, out.warnings, out.occluderNodes, subs);
        f.occlusionMotion = opts.occlusionMotion;
    }

    // --- shading, lights and environment ------------------------------
    // (milestone 19: the lightmap shading plans the lights and the
    // environment as lit does, for its exposure and tone map, and draws
    // the baked light alone: SHADE_LIGHTMAP)
    let planShown: Array<Light3D>? = null;
    let planEnv: Environment? = null;
    if (opts.shading == SceneShading.Lights) {
        // Milestone 59: the lights shading colours each surface by how many
        // of the frame's lights reach it (surface.wgsl SHADE_LIGHT_COUNT),
        // so the lights are planned as lit plans them (and their pool
        // warned of) and nothing else: no material, environment, bake,
        // probes, decals, viewports or shadows, on the other shadings'
        // background (MATERIAL_BACKGROUND).
        sceneLights(tree, f, out, worlds, world);
        f.shading = SHADE_LIGHT_COUNT;
        f.materialMode = false;
        f.background = MATERIAL_BACKGROUND;
        f.environment = new EnvironmentDesc();
        out.lights = f.lights.length;
    } else if (opts.shading == SceneShading.Lit || opts.shading == SceneShading.Lightmap) {
        f.shading = opts.shading == SceneShading.Lit ? SHADE_LIT : SHADE_LIGHTMAP;
        // (milestone 59: every visible light of the frame's world, and the
        // pool's warning when more are in view than a frame draws)
        const shown = sceneLights(tree, f, out, worlds, world);
        planShown = shown;
        // The shadows' warnings go here, but are written once the bake is
        // applied below: a static light whose shadow nothing reads (every
        // drawn item lightmapped) takes no tiles, as the planner decides.
        const shadowsAt = out.warnings.length;
        const we = world != null ? environmentIn(all, world) : tree.environment();
        const env = we != null ? we.environment : null;
        planEnv = env;
        // Milestone 62 (screen.as): the camera attributes of the frame's
        // camera (its own, else its world's WorldEnvironment's), its depth
        // of field and its exposure multiplier; none for a scene without
        // them, which draws as before.
        const attrs = cameraAttributesIn(all, camNode, world);
        out.cameraAttributes = attrs;
        out.exposureMultiplier = exposureMultiplierOf(attrs);
        dofDescInto(attrs, f.dof);
        environmentDesc(env, f, out.warnings, out.exposureMultiplier);
        if (env == null) out.defaults.push("environment");
        // (milestone 34: a SubViewport's view with transparent_bg clears to
        // alpha 0 and draws no sky)
        out.worldBackground = f.background;
        if (viewNode != null && viewNode.transparentBg) {
            f.transparent = true;
            f.background = Vec4(0, 0, 0, 0);
        }
        // POST_HALF_FLOAT_WARNING, when the environment asks for
        // post-processing the renderer's target cannot hold.
        const post = planPost(f, cache.halfFloat).warning;
        if (post.length > 0) out.warnings.push(post);
        out.lights = f.lights.length;
        // Milestone 19: the scene's bake, when it has one (lightmap.as).
        if (opts.lightmap) {
            const counts = applyLightmap(tree, f, out.itemNodes, cache, uploader, out.warnings);
            out.lightmapped = counts.lightmapped;
            out.probeLit = counts.probeLit;
        }
        // Milestone 20: the scene's reflection probes, in the lit shading
        // (probes.as); a scene without one gets nothing.
        if (f.shading == SHADE_LIT) {
            // Milestone 37: the volumetric fog and the fog volumes
            // (fog_volumes.as), before the viewports, which give each its
            // world; a scene without either gets nothing.
            out.fogVolumes = applyFogVolumes(all, env, f, out.warnings, out.fogNodes);
            out.reflectionProbes = applyReflectionProbes(tree, f, out.itemNodes, cache, out.warnings);
            // Milestone 33: the scene's decals (decals.as); a scene without
            // one gets nothing.
            out.decals = applyDecals(all, f, out.itemNodes, cache, out.warnings, out.decalNodes, out.decalTextures);
            // Milestone 34: the SubViewports the frame shows (viewports.as);
            // a scene without one gets nothing.
            applyViewports(tree, all, out, cache, out.warnings);
            // Milestone 67: the artboard textures each item shows
            // (artboard_bits.as; nothing in a scene without one).
            markArtboardItems(tree, all, out);
            // Milestone 37: the fog volumes the pool leaves out for this
            // camera, said by the plan as the lights pool's are (a warning
            // the GPU pass raised would reach no one); the editor says it
            // again for its own camera (view.as sayFogPool).
            if (f.volumetricFog.enabled && f.fogVolumes.length > 0) {
                planFogPool(f, f.fogPlan);
                const said = fogPoolWarning(f, f.fogPlan);
                if (said.length > 0) out.warnings.push(said);
            }
        }
        const after = out.warnings.slice(shadowsAt);
        out.warnings.length = shadowsAt;
        shadowWarnings(shown, f, out.warnings);
        for (let i = 0; i < after.length; i++) out.warnings.push(after[i]);
    } else {
        // Modeler's shadings: its own studio lighting (and, for material,
        // its built-in environment), on Hedra's default background, with
        // Hedra's defaults for what `render` lets one override (the
        // matcap, the wire colour, the checker's size). Material mode binds
        // the materials; the others shade every range alike.
        const s = opts.shading;
        f.shading = SceneShading.modeId(s);
        f.materialMode = s == SceneShading.Material;
        f.drawSurfaces = SceneShading.drawsSurfaces(s);
        f.background = MATERIAL_BACKGROUND;
        f.matcap = MATCAP_CLAY;
        f.wireColor = wireColour();
        f.checkerSize = UV_CHECKER_SIZE;
        out.lights = 0;
    }
    // An instanced item draws its surfaces only (a shading's edges and
    // points would need instanced lines), so a shading without surfaces
    // (wire) draws no MultiMesh: said once, rather than a picture that
    // silently lacks them.
    // (milestone 35: a CPUParticles3D's item, whose instances are dynamic,
    // says so in its own words)
    if (!f.drawSurfaces) {
        let multi = false;
        let particles = false;
        for (let i = 0; i < f.items.length; i++) {
            const inst = f.items[i].instances;
            if (inst == null) continue;
            if (inst.dynamic) particles = true;
            else multi = true;
        }
        if (multi) out.warnings.push(MULTIMESH_WIRE_WARNING);
        if (particles) out.warnings.push(PARTICLES_WIRE_WARNING);
    }
    // (milestone 61: the next passes take what the bake, the probes, the
    // decals and the selection gave their owners)
    if (out.nextPasses > 0) refreshNextPasses(f, out);
    // --- levels of detail (milestone 26) ------------------------------
    // Each item's level for this camera, and the triangles they draw (the
    // renderer chooses again as it culls, cull.as, for the camera it draws
    // from); a threshold of 0 leaves every item at level 0. Last, once a
    // lightmapped item has taken its own mesh (which has no levels).
    f.lodThreshold = opts.lodThreshold > 0 ? opts.lodThreshold : 0;
    if (f.lodThreshold > 0) {
        chooseLods(f);
        let tris: i64 = 0;
        for (let i = 0; i < f.items.length; i++) {
            const d = f.items[i];
            const g = d.mesh;
            if (g == null || d.scenario != f.scenario) continue;
            const inst = d.instances;
            tris += <i64>lodTriangles(g, d.lod) * (inst != null ? <i64>inst.count : 1);
        }
        out.triangles = tris;
    }
    // Milestone 50: what a refresh in place checks (refreshSceneFrame).
    if (opts.shading == SceneShading.Lit && free == null && opts.selected == null && camNode != null && every == null
        && planShown != null && planShown.length > 0 && planEnv != null) {
        out.refreshable = true;
        out.itemMeshes = gather.meshes;
        out.cameraNode = camNode;
        out.lightNodes = planShown;
        out.environment = planEnv;
        out.environmentWrites = planEnv.writes;
        out.environmentSky = planEnv.sky;
        const mats = out.materialResources;
        const shapes = new Array<i64>(mats.length);
        const textures = new Array<Texture2D?>(mats.length * PBR_SLOT_COUNT);
        const stamps = new Int64Array(mats.length);
        const nexts = new Array<StandardMaterial3D?>(mats.length);
        const shaderTextures = new Array<Array<Texture2D?>?>(mats.length);
        for (let i = 0; i < mats.length; i++) {
            shapes[i] = materialShape(mats[i]);
            for (let k = 0; k < PBR_SLOT_COUNT; k++) textures[i * PBR_SLOT_COUNT + k] = mats[i].textureAt(k);
            stamps[i] = materialDescStamp(f.materials[i]);
            // (milestone 61: its next pass, and a ShaderMaterial's textures)
            nexts[i] = mats[i].nextPass;
            shaderTextures[i] = mats[i] instanceof ShaderMaterial ? (mats[i] as ShaderMaterial).textures.slice(0) : null;
        }
        out.materialNextPasses = nexts;
        out.materialShaderTextures = shaderTextures;
        out.materialShapes = shapes;
        out.materialTextures = textures;
        out.materialStamps = stamps;
        out.planLod = opts.lodThreshold;
        out.planLightmap = opts.lightmap;
        out.planSsaa = opts.ssaa;
        out.planTextures = opts.textures;
        out.planCamera = path;
        out.planView = opts.view;
    }
    return Result.okv<SceneFrame>(out);
}

// Where the viewport errors' hints send a reader.
const VIEWPORTS_HINT_DOC = "docs/formats/RSCN.md \"Viewports\"";

// Milestone 34: the SubViewport `path` names (SceneNode.getNode), or a
// SceneryError `viewport-not-found` (no node, or one of another class)
// hinting at the scene's SubViewports.
function findViewport(tree: SceneTree, all: Array<SceneNode>, path: string): Result<SubViewport> {
    const n = tree.getNode(path);
    if (n != null) {
        const isViewport = n instanceof SubViewport;
        if (isViewport) return Result.okv<SubViewport>(n as SubViewport);
    }
    const paths = new Array<string>();
    for (let i = 0; i < all.length; i++) {
        const is = all[i] instanceof SubViewport;
        if (is) paths.push(all[i].path());
    }
    const message = n == null ? "no node '" + path + "'"
        : "'" + path + "' is " + ("AEIOU".includes(n.className.charAt(0)) ? "an " : "a ") + n.className
            + ", not a SubViewport";
    return SceneryError.at("viewport-not-found", tree.root.sceneFile, 0, 0, message, paths.length == 0
        ? "the scene has no SubViewport; see " + VIEWPORTS_HINT_DOC : "SubViewports: " + paths.join(", "))
        .fail<SubViewport>();
}

// Milestone 34: the first WorldEnvironment of `all` in the world of
// `world` (null: the main one), or null.
function environmentIn(all: Array<SceneNode>, world: SubViewport?): WorldEnvironment? {
    for (let i = 0; i < all.length; i++) {
        const n = all[i];
        const isEnv = n instanceof WorldEnvironment;
        if (isEnv && worldViewportOf(n) === world) return n as WorldEnvironment;
    }
    return null;
}

// The warning of a frame whose shading draws no surfaces, with a MultiMesh.
export const MULTIMESH_WIRE_WARNING = "multimesh instances are not drawn in the wire shading (an instanced mesh draws no edges)";
// Milestone 35: that of a frame whose shading draws no surfaces, with particles.
export const PARTICLES_WIRE_WARNING = "particles are not drawn in the wire shading (an instanced mesh draws no edges)";

// Points `sf` at `camera` (a copy, taken in place: nothing is allocated),
// for a frame drawn again from another camera with nothing else changed
// (milestone 13: the preview's every moving frame, instead of planning
// again). Everything else in a plan is the same from any camera (the
// items, their boxes, the lights, the warnings); what culling and the
// visibility ranges decide per camera, the renderer decides at each draw
// (hedra_engine/render/cull.as). The view label is left as it was. Milestone 16:
// the sprites, which do depend on the camera, are turned to it again
// (sprites.as `orientSprites`, which allocates nothing either); a program
// that puts a camera on a frame it built calls this rather than setting
// `frame.camera`, so they are.
export function retargetSceneFrame(sf: SceneFrame, camera: Camera): void {
    sf.frame.camera.copyFrom(camera);
    orientSprites(sf.frame, sf.sprites);
    // (milestone 35: billboards and view_depth particles packed for it,
    // particles.as)
    if (sf.particleDraws.length > 0) sf.particles = orientParticles(sf.frame, sf.particleDraws);
}

// Milestone 35: the particles of `sf` alone made again in place from their
// nodes as they are now (particles.as): each emitter's item's world and box
// as buildSceneFrame would set them, its particles packed (for the frame's
// camera where that matters), SceneFrame.particles. For a frame that
// refreshSceneFrame does not refresh (another shading than lit, a
// selection, the free camera, an override material: SceneFrame.refreshable
// false) whose tree changed only by its particles moving or its emitters
// moving (the editor's live playback): every other item, the frame's box,
// its camera and its lights are as planned. False (plan again) when an
// emitter's item no longer fits: the node hidden or out of the tree,
// another mesh or another particle state. A frame without an emitter
// answers true and changes nothing. Allocates nothing.
export function refreshSceneParticles(sf: SceneFrame): bool {
    const draws = sf.particleDraws;
    if (draws.length == 0) return true;
    const f = sf.frame;
    const root = sf.root;
    const box = refreshParticleBox;
    for (let k = 0; k < draws.length; k++) {
        const d = unchecked(draws[k]);
        const p = d.node;
        const i = d.item;
        if (!p.visibleInTree() || (root != null && p.treeRoot() !== root) || i >= f.items.length) return false;
        const mesh = p.mesh;
        const s = p.particles;
        const item = unchecked(f.items[i]);
        if (mesh == null || mesh !== d.mesh || s == null || item.instances !== s.instances) return false;
        const global = globalOf(p);
        const world = mulMat4(SCENE_TO_MODEL, global);
        item.world = world;
        item.mirrored = normalInto(world, item) < 0;
        d.global = global;
        gatherParticles(d, box);
        let b: Bounds;
        if (box.has) {
            b = box.box.transformed(world);
        } else {
            const o = world.wAxis.xyz();
            b = Bounds(o, o);
        }
        item.bounds = b;
        item.hasBounds = true;
        if (i < sf.itemBounds.length) sf.itemBounds[i] = b;
    }
    sf.particles = orientParticles(f, draws);
    // (milestone 61: an emitter's next pass follows it)
    if (sf.nextPasses > 0) refreshNextPasses(f, sf);
    return true;
}

const refreshParticleBox = new ParticleBox();

// Milestone 59: the lights of frame `f` (lit, lightmap and lights
// shadings): every visible light of the frame's world in tree order, no cap
// (the renderer chooses a pool of at most MAX_FRAME_LIGHTS of them for each
// view it draws, and up to 8 an item: light_select.as), recorded by frame
// index in `out.lightNodes`; the preview sun when there is none. Then the
// pool for the camera chosen (planLightPool into f.lightPlan, which the
// shadows' warnings read too) and its warning when more lights are in view
// than the pool holds. Returns the lights shown.
function sceneLights(
    tree: SceneTree, f: RenderFrame, out: SceneFrame, worlds: bool, world: SubViewport?,
): Array<Light3D> {
    const lights = tree.lights();
    const shown = new Array<Light3D>();
    // (milestone 34: the lights of the frame's world alone)
    for (let i = 0; i < lights.length; i++) {
        const l = lights[i];
        if (l.visibleInTree() && (!worlds || worldViewportOf(l) === world)) shown.push(l);
    }
    for (let i = 0; i < shown.length; i++) f.lights.push(lightDesc(shown[i]));
    out.lightNodes = shown;
    if (shown.length == 0) {
        f.lights.push(previewSun());
        out.defaults.push("sun");
    }
    const said = lightPoolWarning(planLightPool(f, f.lightPlan), shown);
    if (said.length > 0) out.warnings.push(said);
    return shown;
}

// The warnings of the frame's shadows: each light with shadow_enabled that
// found no room in the atlas (allocateFrameShadows serves the pool's
// lights by their importance to the view, f.lightPlan planned for its
// camera; "left" is what the lights served before it did not take), and
// each shadowed spot light whose cone is wider than its shadow's
// projection holds, in the frame's order. `shown` are the visible lights,
// the frame's lights by index.
function shadowWarnings(shown: Array<Light3D>, f: RenderFrame, warnings: Array<string>): void {
    const a = allocateFrameShadows(f, staticShadowsUnused(f));
    for (let i = 0; i < f.lights.length && i < shown.length; i++) {
        const d = f.lights[i];
        const k = a.dropped.indexOf(i);
        if (k >= 0) {
            const left = k < a.left.length ? a.left[k] : 0;
            warnings.push("light " + shown[i].path() + ": no room for its shadow in the shadow atlas ("
                + shadowTileCount(d).toString() + " tiles wanted, " + left.toString() + " of "
                + SHADOW_TILES.toString() + " left); drawn without a shadow");
        } else if (i < a.slot.length && a.slot[i] >= 0 && d.kind == LIGHT_SPOT
            && d.spotAngle > MAX_SPOT_SHADOW_HALF_ANGLE) {
            warnings.push("light " + shown[i].path() + ": its shadow covers a cone of "
                + displayF32(MAX_SPOT_SHADOW_HALF_ANGLE) + " degrees (spot_angle " + displayF32(d.spotAngle) + ")");
        }
    }
}

// Outlines the node `path` names (its items active, its descendants'
// selected), in Hedra's colours; nothing when `path` is null or names no
// node, or no item is the node's or under it.
function outlineSelection(tree: SceneTree, path: string?, f: RenderFrame, nodes: Array<SceneNode>): void {
    if (path == null) return;
    const sel = tree.getNode(path);
    if (sel == null) return;
    let any = false;
    for (let i = 0; i < f.items.length && i < nodes.length; i++) {
        const n = nodes[i];
        if (n === sel) {
            f.items[i].selected = true;
            f.items[i].active = true;
            any = true;
        } else if (isUnder(n, sel)) {
            f.items[i].selected = true;
            any = true;
        }
    }
    if (!any) return;
    f.outline = true;
    f.outlineSelect = rgbaBytes(Vec4(SELECT_COLOR.x, SELECT_COLOR.y, SELECT_COLOR.z, 1.0));
    f.outlineActive = rgbaBytes(Vec4(ACTIVE_COLOR.x, ACTIVE_COLOR.y, ACTIVE_COLOR.z, 1.0));
}

// Whether `n` is a descendant of `ancestor`.
function isUnder(n: SceneNode, ancestor: SceneNode): bool {
    let p = n.parent;
    while (p != null) {
        if (p === ancestor) return true;
        p = p.parent;
    }
    return false;
}

// Milestone 50: `sf`, planned by buildSceneFrame, made again in place from
// `tree` as it is now, when the tree still draws what `sf` was planned
// from (the same items of the same nodes, meshes and materials, the same
// camera node, lights and environment, the same options): every item's
// transform, box, skin and colour, the camera, the lights' places and
// values, the materials' numbers and colours (refillMaterialDesc), the
// sprites' turns, the picker's globals, the bake's and the probes' choices
// and the levels of detail, as buildSceneFrame would set them now. False
// (and `sf` half refreshed: plan again) when something it does not follow
// changed: a node shown or hidden, a mesh or a material swapped or given
// other textures or switches, a light shown or hidden, the environment
// written (Resource.writes) or swapped, another camera. Only the lit
// shading through a camera node, with no selection, free camera or
// override material, is refreshed (SceneFrame.refreshable). Allocates
// nothing once `cache`'s walk lists have grown to the tree, so that a
// scene moving every frame (a walking player, a playing machine) costs
// its frames nothing of the heap, and the renderer keeps the frame's
// material groups (FrameRenderer.bindMaterials keeps them while the
// materials array is the same one).
export function refreshSceneFrame(
    sf: SceneFrame, tree: SceneTree, opts: SceneRenderOptions, cache: SceneRenderCache, uploader: MeshUploader?,
): bool {
    sf.materialsRefilled = false;
    if (!sf.refreshable || sf.root !== tree.root) return false;
    const f = sf.frame;
    if (opts.shading != SceneShading.Lit || opts.freeCamera != null || opts.selected != null
        || opts.overrideMaterial != null) return false;
    if (max<u32>(opts.width, 1) != f.width || max<u32>(opts.height, 1) != f.height || opts.ssaa != sf.planSsaa
        || opts.lodThreshold != sf.planLod || opts.lightmap != sf.planLightmap || opts.textures != sf.planTextures
        || opts.view !== sf.planView) return false;
    // (the camera path as buildSceneFrame takes it: a Camera view's)
    let path = opts.camera;
    if (path == null && opts.view.kind == SceneViewKind.Camera) path = opts.view.camera;
    const planned = sf.planCamera;
    if ((path == null) != (planned == null)) return false;
    if (path != null && planned != null && path != planned) return false;
    // (milestone 34: the same SubViewport's view, or none)
    const vpath = opts.viewport;
    const vplanned = sf.planViewport;
    if ((vpath == null) != (vplanned == null)) return false;
    if (vpath != null && vplanned != null && vpath != vplanned) return false;
    const all = sf.walked;
    tree.walkInto(all, sf.walkStack);
    // The camera: the one the path named (still in the tree), else the
    // current one, found as SceneTree.currentCamera finds it; a
    // SubViewport's view, its camera now.
    const camNode = sf.cameraNode;
    if (camNode == null) return false;
    const viewNode = sf.viewportNode;
    if (viewNode != null) {
        if (viewNode.treeRoot() !== tree.root || viewportCameraOf(all, viewNode) !== camNode) return false;
    } else if (path == null) {
        let current: Camera3D? = null;
        let first: Camera3D? = null;
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            const isCamera = n instanceof Camera3D;
            // (milestone 34: a SubViewport's cameras are its own)
            if (!isCamera || underSubViewport(n)) continue;
            const c = n as Camera3D;
            if (c.current) {
                current = c;
                break;
            }
            if (first == null) first = c;
        }
        if ((current != null ? current : first) !== camNode) return false;
    } else if (camNode.treeRoot() !== tree.root) {
        return false;
    }
    // The environment: the same resource, unwritten, with the same sky (of
    // the frame's world: milestone 34).
    const worlds = sf.viewports.length > 0;
    const world = sf.world;
    let env: Environment? = null;
    for (let i = 0; i < all.length; i++) {
        const n = all[i];
        const isEnv = n instanceof WorldEnvironment;
        if (isEnv && (!worlds || worldViewportOf(n) === world)) {
            env = (n as WorldEnvironment).environment;
            break;
        }
    }
    if (env == null || env !== sf.environment || env.writes != sf.environmentWrites || env.sky !== sf.environmentSky) {
        return false;
    }
    // Milestone 62: the same camera attributes (another resource in the
    // camera's or the WorldEnvironment's slot plans again); their values,
    // which a binding, a timeline or a tween moves, are refilled below.
    const attrs = cameraAttributesIn(all, camNode, world);
    if (attrs !== sf.cameraAttributes) return false;
    // The lights: the same ones shown, in order.
    const lights = sf.lightNodes;
    let shown = 0;
    for (let i = 0; i < all.length; i++) {
        const n = all[i];
        const isLight = n instanceof Light3D;
        if (!isLight || !n.visibleInTree()) continue;
        if (worlds && worldViewportOf(n) !== world) continue;
        if (shown >= lights.length || lights[shown] !== (n as Light3D)) return false;
        shown++;
    }
    if (shown != lights.length) return false;
    // The sprites' materials, made from their nodes (spriteMaterial),
    // written again first; then the materials: the same textures and
    // switches.
    const items = f.items;
    const mats = sf.materialResources;
    for (let i = 0; i < sf.sprites.length; i++) {
        const si = sf.sprites[i];
        if (si.item >= items.length) return false;
        const keys = items[si.item].materials;
        if (keys.length == 0 || keys[0] < 0 || <i32>keys[0] >= mats.length) return false;
        const sm = mats[<i32>keys[0]];
        if (sm.albedoTexture !== si.node.texture) return false;
        spriteMaterialInto(sm, si.node);
    }
    for (let i = 0; i < mats.length; i++) if (!sameShape(mats[i], sf, i)) return false;
    // Milestone 33: the same decals shown, with the same textures, their
    // descs refilled in place (decals.as).
    if (!refreshDecals(f, sf.decalNodes, sf.decalTextures, all, cache, sf.refreshWarnings)) return false;
    // Milestone 37: the same fog volumes and occluders shown, refilled in
    // place (fog_volumes.as, occluders.as).
    if (!refreshFogVolumes(f, env, sf.fogNodes, all, sf.refreshWarnings)) return false;
    if (!refreshOccluders(f, sf.occluderNodes, all, sf.refreshWarnings)) return false;

    // --- items ---------------------------------------------------------
    const aspect = <f32>f.width / <f32>f.height;
    let gather = sf.gatherer;
    if (gather == null) {
        gather = new Gather(f, cache, uploader, sf.refreshWarnings, sf.itemNodes, sf.itemBounds);
        sf.gatherer = gather;
    }
    gather.uploader = uploader;
    gather.begin();
    gather.shading = opts.shading;
    gather.lodThreshold = opts.lodThreshold;
    f.hasCasters = false;
    let at = 0;
    let sprite = 0;
    let emitter = 0;
    const draws = sf.particleDraws;
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        const isMesh = n instanceof MeshInstance3D;
        const isModel = n instanceof ModelInstance3D;
        const isMulti = n instanceof MultiMeshInstance3D;
        const isSprite = n instanceof ArtboardSprite3D;
        const isParticles = n instanceof CPUParticles3D;
        if (!isMesh && !isModel && !isMulti && !isSprite && !isParticles) continue;
        if (!n.visibleInTree()) continue;
        const global = globalOf(n);
        let r = 0;
        if (isParticles) {
            // (milestone 35: an emitter that added nothing when planned
            // must add nothing now: updateParticles answers 0 or -1)
            const p = n as CPUParticles3D;
            if (emitter >= draws.length) {
                const mesh = p.mesh;
                if (mesh == null || cache.entry(mesh.arrays(), uploader, opts.lodThreshold > 0).gpu.indexCount == 0) continue;
                return false;
            }
            r = gather.updateParticles(at, sf, p, global, unchecked(draws[emitter]));
            if (r > 0) emitter++;
        } else if (isSprite) {
            if (sprite >= sf.sprites.length) {
                // (a sprite added nothing when planned: it must add nothing now)
                const s = n as ArtboardSprite3D;
                const t = s.texture;
                if (t == null) continue;
                const rect = spriteRect(t.width, t.height, s.pixelSize, s.centered, s.offset);
                if (!(rect.z > 0) || !(rect.w > 0)) continue;
                return false;
            }
            r = gather.updateSprite(at, sf, n as ArtboardSprite3D, global, sf.sprites[sprite]);
            if (r > 0) sprite++;
        } else if (isMulti) {
            const mm = (n as MultiMeshInstance3D).multimesh;
            if (mm != null && mm.transformFormat == 1) {
                const mesh = mm.mesh;
                if (mesh != null) r = gather.update(at, sf, mesh.arrays(), global, null, n, mm);
            }
        } else if (isMesh) {
            const mi = n as MeshInstance3D;
            const mesh = mi.mesh;
            if (mesh != null) r = gather.update(at, sf, mesh.arrays(), global, mi.materialOverride, n);
        } else {
            const parts = (n as ModelInstance3D).partsKept();
            for (let k = 0; k < parts.length; k++) {
                const p = parts[k];
                if (!p.visible) continue;
                const pr = gather.update(at, sf, p.mesh, global * p.local, null, n, null, k, global);
                if (pr < 0) return false;
                if (pr > 0) at++;
            }
            continue;
        }
        if (r < 0) return false;
        if (r > 0) at++;
    }
    // (milestone 61: the next passes' items after them, refreshed below)
    if (at + sf.nextPasses != f.items.length || sprite != sf.sprites.length || emitter != draws.length) return false;
    sf.triangles = gather.triangles;
    refreshItemGlobals(sf);
    rangeCentres(f.items, sf.itemNodes, sf.itemBounds);
    if (sf.nextPasses > 0) refreshNextPasses(f, sf);
    f.shaderTime = shaderTimeOf(opts.time);
    f.screenEffects = opts.screenEffects;
    f.screenQuality.copyFrom(opts.screenQuality);
    f.renderQuality.copyFrom(opts.renderQuality);
    f.outputWidth = opts.outputWidth;
    f.outputHeight = opts.outputHeight;

    // --- camera --------------------------------------------------------
    const bounds = gather.hasBounds ? gather.bounds : Bounds(Vec3(-1, -1, -1), Vec3(1, 1, 1));
    sf.bounds = bounds;
    f.drawBounds = gather.bounds;
    f.hasDrawBounds = gather.hasBounds;
    cameraInto(camNode, bounds, aspect, f.camera);
    orientSprites(f, sf.sprites);
    if (draws.length > 0) sf.particles = orientParticles(f, draws);
    // Milestone 62: the camera attributes' depth of field and exposure as
    // they are now (in place: nothing allocated).
    dofDescInto(attrs, f.dof);
    const multiplier = exposureMultiplierOf(attrs);
    if (multiplier != sf.exposureMultiplier) {
        exposeEnvironmentInto(env, f, multiplier);
        sf.exposureMultiplier = multiplier;
        // (a sky's clear colour is its horizon, which no exposure moves)
        if (env.backgroundMode != 2) sf.worldBackground = f.background;
    }

    // --- lights --------------------------------------------------------
    // (milestone 59: every one shown, as planned; the renderer chooses the
    // pool and the items' lists again at each draw from where they are now)
    for (let i = 0; i < lights.length && i < f.lights.length; i++) lightDescInto(f.lights[i], lights[i]);
    if (sf.planLightmap) {
        const counts = applyLightmap(tree, f, sf.itemNodes, cache, uploader, sf.refreshWarnings);
        sf.lightmapped = counts.lightmapped;
        sf.probeLit = counts.probeLit;
    }
    sf.reflectionProbes = applyReflectionProbes(tree, f, sf.itemNodes, cache, sf.refreshWarnings);
    // Milestone 33: the items' layers the decals' masks select, as a plan
    // sets them (decals.as).
    if (sf.decals > 0) decalItemLayers(f, sf.itemNodes);
    // Milestone 34: the same viewports, their frames refilled in place from
    // the items, camera and lights just refreshed (viewports.as); a frame
    // of another world than the main one draws no probe, and a
    // SubViewport's view follows its transparent_bg.
    if (!refreshViewports(sf, all, cache, sf.refreshWarnings)) return false;
    if (f.scenario != SCENARIO_MAIN) f.probes = null;
    if (viewNode != null) {
        f.transparent = viewNode.transparentBg;
        f.background = viewNode.transparentBg ? Vec4(0, 0, 0, 0) : sf.worldBackground;
    }
    // (milestone 61: the next passes take what the bake and the probes
    // gave their owners)
    if (sf.nextPasses > 0) refreshNextPasses(f, sf);
    sf.refreshWarnings.length = 0;

    // --- materials -----------------------------------------------------
    // (numbers and colours a binding, a timeline or a script changed: the
    // renderer writes the kept groups' uniforms again)
    let refilled = false;
    const stamps = sf.materialStamps;
    for (let i = 0; i < mats.length; i++) {
        const d = f.materials[i];
        refillMaterialDesc(d, mats[i]);
        const st = materialDescStamp(d);
        if (st != stamps[i]) {
            stamps[i] = st;
            refilled = true;
        }
    }
    sf.materialsRefilled = refilled;

    // --- levels of detail ----------------------------------------------
    if (f.lodThreshold > 0) {
        chooseLods(f);
        let tris: i64 = 0;
        for (let i = 0; i < f.items.length; i++) {
            const d = f.items[i];
            const g = d.mesh;
            if (g == null || d.scenario != f.scenario) continue;
            const inst = d.instances;
            tris += <i64>lodTriangles(g, d.lod) * (inst != null ? <i64>inst.count : 1);
        }
        sf.triangles = tris;
    }
    sf.refreshes++;
    return true;
}

// recordItemGlobals into the frame's own array (the same items).
function refreshItemGlobals(sf: SceneFrame): void {
    const nodes = sf.itemNodes;
    const g = sf.itemGlobals;
    if (g.length != nodes.length * 12) {
        recordItemGlobals(sf);
        return;
    }
    const acc = refreshAcc;
    for (let i = 0; i < nodes.length; i++) {
        globalAffine(nodes[i], acc);
        for (let k = 0; k < 12; k++) g[i * 12 + k] = acc[k];
    }
}

const refreshAcc = new StaticArray<f64>(12);

// Whether material `i` of `sf` has the switches and the textures (the very
// objects) it was planned with; milestone 61: its next pass, and a
// ShaderMaterial's textures too.
function sameShape(m: StandardMaterial3D, sf: SceneFrame, i: i32): bool {
    if (materialShape(m) != sf.materialShapes[i]) return false;
    const t = sf.materialTextures;
    for (let k = 0; k < PBR_SLOT_COUNT; k++) if (m.textureAt(k) !== t[i * PBR_SLOT_COUNT + k]) return false;
    if (i < sf.materialNextPasses.length && m.nextPass !== sf.materialNextPasses[i]) return false;
    const st = i < sf.materialShaderTextures.length ? sf.materialShaderTextures[i] : null;
    if (m instanceof ShaderMaterial) {
        const now = (m as ShaderMaterial).textures;
        if (st == null || st.length != now.length) return false;
        for (let k = 0; k < now.length; k++) if (now[k] !== st[k]) return false;
    } else if (st != null) {
        return false;
    }
    return true;
}
