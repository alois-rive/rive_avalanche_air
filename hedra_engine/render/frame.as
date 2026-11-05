// One frame to draw, flat: what `FrameRenderer.renderFrame` (gpu/renderer.as)
// needs and nothing about where it came from. A program turns its own scene
// into a `RenderFrame` (Hedra: engine/src/authoring/model_view/scene_adapter.as),
// so the renderer knows no scene, object or modifier type.
//
// Colours are linear unless a field says otherwise; sizes are in pixels
// before SSAA. `frameGlobals` and `frameObjects` build the two uniform
// blocks exactly as Hedra's `viewSetup` does, byte for byte (the frame
// test checks it; milestone 19 appended the probe light to the object
// block, zeros for every item without one, Hedra's included).

import { maxF32, minF32 } from "../base/util";
import { MAT4_IDENTITY, Mat4, Vec3, Vec4 } from "../base/vecmath";
import { Bounds, Camera } from "./camera";
import { Image, Rgba, srgbToLinear } from "./image";
import { FloatImage } from "./hdr";
import { GpuMesh, lodSphere, lodUsable } from "./mesh";
import { InstanceData } from "./instances";
import { MaterialDesc } from "./material";
import { LightmapImages } from "./lightmap/data";
import { SH_L1_FLOATS } from "./lightmap/sh";
import { ReflectionProbeSet } from "./probe/data";
import { itemProbeMask } from "./probe_select";
import { DecalDesc } from "./decal";
import { ViewportDesc } from "./viewport";
import { LightPlan } from "./light_pool";
import { FogPlan, FogVolumeDesc, VolumetricFogDesc } from "./fog_volume";
import { OccluderDesc } from "./occluder";
import { DofDesc, SCREEN_EFFECTS_ALL, ScreenQuality, ScreenRefractionDesc, SsrDesc } from "./screen";
import { RenderQuality } from "./quality";
import {
    Globals, LineInstance, OBJ_EMERGE, OBJ_HAS_WEIGHTS, OBJ_LIGHTMAP, OBJ_MIRRORED, OBJ_PROBE_GI, OBJ_SKINNED, OBJ_FADE,
    ObjectUniform, PointInstance, U32x4,
} from "./gpu/layouts";

// One object to draw: its ObjectUniform slot and values, and its mesh.
export class DrawItem {
    // ObjectUniform slot, 1-based (0 is the world).
    slot: u32 = 0;
    world: Mat4 = MAT4_IDENTITY;
    // Inverse-transpose of world's 3x3.
    normal: Mat4 = MAT4_IDENTITY;
    // Linear.
    color: Vec4 = Vec4(1, 1, 1, 1);
    selected: bool = false;
    active: bool = false;
    // Written by the id pass (Hedra: the slot).
    pickId: u32 = 0;
    // The edit-mode object.
    edit: bool = false;
    // OBJ_HAS_WEIGHTS: the surface carries a vertex group's weights.
    hasWeights: bool = false;
    // OBJ_MIRRORED: `world` has a negative determinant, so the winding of
    // its triangles is reversed.
    mirrored: bool = false;
    // null: nothing of this item is drawn from a mesh.
    mesh: GpuMesh? = null;
    // Per mesh.ranges[k]: an index into RenderFrame.materials, -1 the
    // default material.
    materials: Array<i64> = [];
    // Its wire edges (wire modes, the edges overlay, an edit cage).
    showEdges: bool = false;
    // Its vertices (the verts overlay, an edit cage).
    showPoints: bool = false;
    // Whether it casts shadows (CAST_SHADOW_*, Godot's
    // GeometryInstance3D.cast_shadow). Read only by a frame with a light
    // whose `shadow` is on, so Hedra, which never sets it, draws as
    // before. CAST_SHADOW_SHADOWS_ONLY items are left out of the main and
    // id passes (and of picking) and drawn only into shadow maps.
    castShadow: u32 = CAST_SHADOW_ON;
    // Milestone 13 (scale). Everything below is left at its default by
    // Hedra, whose frames draw as before.
    //
    // The box around everything the item draws, every instance included,
    // in the frame's world space, and whether it is known. An item without
    // one is never culled; with one, cull.as leaves it out of a pass whose
    // frustum it is wholly outside, which changes no pixel.
    bounds: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    hasBounds: bool = false;
    // GPU instancing (a MultiMeshInstance3D): the mesh drawn once per
    // instance, each placed by `world` times its own transform
    // (instances.as). null: drawn once, as before.
    instances: InstanceData? = null;
    // Godot's GeometryInstance3D visibility range (cull.as applies it):
    // the item is drawn while the distance from the eye to `rangeCenter`
    // (the centre of its node's box, frame world space) is within
    // [rangeBegin, rangeEnd], a limit of 0 meaning none, with the margins
    // as Godot's hysteresis (RenderFrame.rangeState) or, for the fade
    // modes, widening the range.
    rangeBegin: f32 = 0;
    rangeBeginMargin: f32 = 0;
    rangeEnd: f32 = 0;
    rangeEndMargin: f32 = 0;
    rangeFadeMode: u32 = RANGE_FADE_DISABLED;
    rangeCenter: Vec3 = Vec3(0, 0, 0);
    // Hedra's emerge (its node's GeometryInstance3D.emerge and
    // emergeColor, sRGB): below 1 the item comes out of a fog of that
    // colour (OBJ_EMERGE; surface.wgsl's `emerge_reveal`), and casts its
    // shadow through the masked shadow pipelines, which can cut it. 1 for
    // every item that never sets it, which draws as before.
    emerge: f32 = 1;
    emergeColor: Vec4 = Vec4(0, 0, 0, 1);
    // Hedra's fade (its node's GeometryInstance3D.fade, and fadeColor,
    // sRGB): the lit colour drawn `fade` of the way toward the fade colour
    // tone mapped, as a background of that colour is shown (OBJ_FADE;
    // surface.wgsl's `item_fade`). 0 for every item that never sets it,
    // which draws as before.
    fade: f32 = 0;
    fadeColor: Vec4 = Vec4(0, 0, 0, 1);
    // Milestone 16 (Godot's no_depth_test, an ArtboardSprite3D's): the
    // item is drawn after every other surface, blended, without the depth
    // test or write, so nothing hides it; the id pass draws it last the
    // same way (its outline shows over everything), and picking takes a
    // hit on it over any depth-tested item's (pick.as). An instanced item
    // ignores it. False for every item before, which draws as it did.
    noDepthTest: bool = false;
    // Milestone 61 (Godot's Material.next_pass): this item draws its mesh
    // again with its materials' next passes, after the item at this index
    // of RenderFrame.items (its owner, whose materials it follows), in the
    // main and shadow passes only (never the id pass: picking and the
    // selection's outline are the owner's). -1 for every other item.
    nextPassOf: i32 = -1;
    // Milestone 19 (baked lighting, Godot's LightmapGI). Both left at their
    // defaults by Hedra and by every scene without a LightmapGI, whose
    // items draw exactly as before.
    //
    // The layer of RenderFrame.lightmap this item's baked light is in (its
    // mesh then carries GpuMesh.lightmapUv, the coordinates in that layer),
    // or -1: not lightmapped. A lightmapped item's diffuse light comes from
    // the lightmap instead of the ambient light and of the lights whose
    // bakeMode is LIGHT_BAKE_STATIC (surface.wgsl's lightmap entry points).
    lightmapLayer: i32 = -1;
    // The baked light probes' light at the item (compiler/src/bake/lightmap/
    // sh.as: SH_L1_FLOATS numbers, the frame's world space), for an item
    // that is not lightmapped in a frame that has probes; null: the item
    // takes its ambient light from the environment, as before.
    probeSh: Float32Array? = null;
    // Milestone 20 (reflection probes, Godot's ReflectionProbe). Read only
    // in a frame whose `probes` is not null, so every other frame (every
    // frame of Hedra, and every scene without a ReflectionProbe) draws
    // exactly as before.
    //
    // Its visual layers (Godot's VisualInstance3D.layers, bit k layer k +
    // 1): a probe reflects in it when they meet the probe's reflectionMask,
    // and draws it into its capture when they meet its cullMask.
    layers: u32 = 1;
    // Whether a probe's capture draws it at all (an ArtboardSprite3D is
    // not: its texture is a live artboard the bake cannot read, so neither
    // capture draws it and the baked and live ones agree).
    captured: bool = true;
    // Milestone 26: the level of detail of `mesh` drawn (0: level 0, k:
    // mesh.lods[k - 1]), chosen for the frame's camera by chooseLods
    // (cull.as cullFrame runs it); 0 in every frame whose lodThreshold is
    // 0. Every pass draws the item at this level (the shadow and id passes
    // too, so its shadow and outline match what is drawn).
    lod: i32 = 0;
    // Milestone 48: GPU skinning (mesh.skinJoints and skinWeights set).
    // `skin` holds skinJointCount matrices of SKIN_FLOATS_PER_JOINT
    // numbers, the rows of a 3 x 4 matrix each (as an instance's
    // transform), mapping a vertex of the mesh as stored straight into the
    // frame's world space: for palette slot k, renderer-from-scene *
    // skeleton's global * bone joints[k]'s global * inverseBinds[k]. A
    // skinned item's `world` is the identity and `normal` too (the shaders
    // take the skinned normal from the blended matrix). `skinVersion` moves
    // whenever the numbers change, so the renderer uploads them only then.
    // Null, 0 and 0 for every other item, which draws as before.
    skin: Float32Array? = null;
    skinJointCount: i32 = 0;
    skinVersion: u32 = 0;
    // Milestone 33: the decals the item paints, set by the renderer for the
    // camera it draws from (decal_select.as prepareDecals, which reads the
    // item's `layers` and `bounds`): how many, and their indices into the
    // frame's pool, a byte each in painting order (decals0 the first four,
    // the first in its low byte; decals1 the next four), as
    // ObjectUniform.decals carries them. 0 in every frame without decals,
    // whose items draw as before.
    decalCount: u32 = 0;
    decals0: u32 = 0;
    decals1: u32 = 0;
    // Milestone 34 (viewport.as): the world it is drawn in (SCENARIO_MAIN,
    // or the scenario of the SubViewport with a world of its own its node
    // is under): a view draws only the items of its frame's scenario. And
    // the viewports whose textures its materials show in a slot the
    // renderer binds (bit ViewportDesc.bit each), which the schedule's
    // when_visible reads once it is drawn. Both 0 in every frame without a
    // SubViewport, whose items draw as before.
    scenario: i32 = 0;
    viewports: u32 = 0;
    // Milestone 67: the frame's artboard textures its materials show (a bit
    // each, by the texture's index in the scene's artboard textures,
    // ../scene/player/artboards.as; the first 32), which an
    // ArtboardTexture's when_visible reads once the frame is drawn
    // (FrameRenderer.artboardsDrawn). 0 in every frame without artboard
    // textures.
    artboards: u32 = 0;
    // Milestone 59 (lights per object; light_pool.as): the lights the item
    // draws, set by the renderer for the camera it draws from
    // (light_select.as assignItemLights, which reads the item's `bounds`):
    // how many (at most MAX_OBJECT_LIGHTS), and their entries in the
    // frame's pool, a byte each in pool order (lights0 the first four, the
    // first in its low byte; lights1 the next four), as
    // ObjectUniform.lights carries them; and how many lights reach it in
    // all, past the 8 too (the lights shading's colour, the statistics'
    // over budget). Zeros in every frame no renderer has chosen for, and in
    // every shading but lit and lights.
    lightCount: u32 = 0;
    lights0: u32 = 0;
    lights1: u32 = 0;
    lightsReached: u32 = 0;
    // Milestone 37 (fog volumes; fog_volume.as): the fog the item's pixels
    // are seen through, set by the renderer for the camera it draws from
    // (fog_volume.as prepareFogVolumes, which reads the item's `bounds`):
    // up to MAX_OBJECT_FOG_VOLUMES entries of the frame's fog pool, a byte
    // each, the entry plus 1 (0: none), the first in the low byte, as
    // ObjectUniform.decals.w carries them. 0 in every frame without
    // volumetric fog, whose items draw as before.
    fogVolumes: u32 = 0;
}

// Milestone 48: the numbers of one joint of DrawItem.skin.
export const SKIN_FLOATS_PER_JOINT: i32 = 12;

// DrawItem.rangeFadeMode, Godot's GeometryInstance3D.visibility_range_fade_mode.
// The fades are not drawn: self and dependencies draw the item over the
// whole widened range (cull.as says how).
export const RANGE_FADE_DISABLED: u32 = 0;
export const RANGE_FADE_SELF: u32 = 1;
export const RANGE_FADE_DEPENDENCIES: u32 = 2;

// Line instances drawn with one item's uniform slot.
export class ItemLines {
    slot: u32;
    lines: Array<LineInstance>;
    // Drawn after everything else, without the depth test.
    onTop: bool;

    constructor(slot: u32, lines: Array<LineInstance>, onTop: bool) {
        this.slot = slot;
        this.lines = lines;
        this.onTop = onTop;
    }
}

// Point instances drawn with one item's uniform slot.
export class ItemPoints {
    slot: u32;
    points: Array<PointInstance>;
    onTop: bool;

    constructor(slot: u32, points: Array<PointInstance>, onTop: bool) {
        this.slot = slot;
        this.points = points;
        this.onTop = onTop;
    }
}

// The shading modes of Globals.params.x a program without Hedra's
// `Shading` names (surface.wgsl's SHADE_*): Hedra's material mode, and the
// lit mode, which draws the same PBR materials under the frame's own lights
// and environment (milestone 4, Hedra).
export const SHADE_MATERIAL: u32 = 5;
export const SHADE_LIT: u32 = 8;
// Modeler's viewport shadings (its `Shading.modeId`), for Hedra's
// `--shading` (milestone 5): solid (also wire and wire-solid, which differ
// in what they draw, not in how a surface is shaded), matcap, normals,
// face orientation, a colour per object, and the UV checker.
export const SHADE_SOLID: u32 = 0;
export const SHADE_MATCAP: u32 = 1;
export const SHADE_NORMALS: u32 = 2;
export const SHADE_FACE_ORIENT: u32 = 3;
export const SHADE_RANDOM: u32 = 4;
export const SHADE_UV_CHECKER: u32 = 6;

// LightDesc.kind, as surface.wgsl's LIGHT_* numbers them.
export const LIGHT_DIRECTIONAL: u32 = 0;
export const LIGHT_OMNI: u32 = 1;
export const LIGHT_SPOT: u32 = 2;
// Milestone 19: the lightmap shading (`--shading lightmap`): a lightmapped
// item draws its baked light alone, on a white surface, through the
// environment's exposure and tone map; every other item draws as
// SHADE_SOLID does.
export const SHADE_LIGHTMAP: u32 = 9;
// Milestone 59: the lights shading (`--shading lights`): every surface
// studio-shaded in the colour of the number of lights reaching its item
// (DrawItem.lightsReached: 0 grey, 1 to 8 a ramp, more than 8 magenta),
// the frame's lights planned as for lit.
export const SHADE_LIGHT_COUNT: u32 = 10;

// LightDesc.bakeMode, Godot's Light3D.light_bake_mode numbers: not baked;
// baked whole (its direct light and shadows are in the lightmap, and it
// lights only items that are not lightmapped in real time); only its
// bounce baked (its direct light stays real-time everywhere).
export const LIGHT_BAKE_DISABLED: u32 = 0;
export const LIGHT_BAKE_STATIC: u32 = 1;
export const LIGHT_BAKE_DYNAMIC: u32 = 2;

// How the main pass draws an item of a frame with a bake (milestone 19;
// `lightmapDrawKind`; gpu/renderer.as draws it, light_select.as leaves
// the static lights out of a BAKED item's list): with the ordinary pipelines in real-time light, with
// the lightmap pipelines (its diffuse light from the lightmap, the static
// lights skipped), or with the ordinary pipelines and its probe light
// (OBJ_PROBE_GI: lit() reads it from the item's uniform).
export const LIGHTMAP_DRAW_REALTIME: i32 = 0;
export const LIGHTMAP_DRAW_BAKED: i32 = 1;
export const LIGHTMAP_DRAW_PROBES: i32 = 2;

// How the main pass draws item `d` of frame `f` (LIGHTMAP_DRAW_*). Pure: the
// renderer's choice, given that the device holds the frame's lightmap and
// made the lightmap pipelines (otherwise it draws a BAKED item in real
// time). BAKED needs the frame's lightmap, the item's layer, a mesh with
// lightmap coordinates, the lit or lightmap shading (the material mode a
// lit frame sets, its surfaces drawn), and an item drawn once with the
// depth test: an instanced item, or one the top pass draws (no_depth_test),
// is drawn in real time, and so is a skinned one (milestone 48: a bake
// holds one pose), and (milestone 61) one with a ShaderMaterial in the lit
// shading (custom pipelines have no lightmap variant: SHADERS.md). PROBES
// is an item with probe light; anything else is REALTIME, as every item of
// a frame without a bake.
export function lightmapDrawKind(f: RenderFrame, d: DrawItem): i32 {
    if (f.lightmap != null && d.lightmapLayer >= 0 && (f.shading == SHADE_LIT || f.shading == SHADE_LIGHTMAP)
        && f.materialMode && f.drawSurfaces && d.instances == null && !d.noDepthTest && d.skin == null
        && !(f.shading == SHADE_LIT && hasCustomMaterial(f, d))) {
        const g = d.mesh;
        if (g != null && g.lightmapUv != null) return LIGHTMAP_DRAW_BAKED;
    }
    if (d.probeSh != null && f.shading == SHADE_LIT) return LIGHTMAP_DRAW_PROBES;
    return LIGHTMAP_DRAW_REALTIME;
}

// Milestone 61: whether a range of `d` has a ShaderMaterial
// (MaterialDesc.custom). Allocates nothing.
export function hasCustomMaterial(f: RenderFrame, d: DrawItem): bool {
    const keys = d.materials;
    const mats = f.materials;
    for (let k = 0; k < keys.length; k++) {
        const key = unchecked(keys[k]);
        if (key >= 0 && key < <i64>mats.length && mats[<i32>key].custom != null) return true;
    }
    return false;
}

// DrawItem.castShadow, Godot's GeometryInstance3D.cast_shadow numbers. The
// renderer never culls faces, so ON and DOUBLE_SIDED draw the same shadow.
export const CAST_SHADOW_OFF: u32 = 0;
export const CAST_SHADOW_ON: u32 = 1;
export const CAST_SHADOW_DOUBLE_SIDED: u32 = 2;
export const CAST_SHADOW_SHADOWS_ONLY: u32 = 3;

// LightDesc.directionalShadowMode, Godot's DirectionalLight3D
// directional_shadow_mode: one cascade, two, or four.
export const SHADOW_ORTHOGONAL: u32 = 0;
export const SHADOW_PARALLEL_2_SPLITS: u32 = 1;
export const SHADOW_PARALLEL_4_SPLITS: u32 = 2;

// A light of the frame, drawn by the lit mode (SHADE_LIT) and ignored by
// every other. Positions and directions are in the frame's world space.
// The photometry is Godot 4's: a surface facing a directional light of
// energy 1 and white colour gets the irradiance that shows a white Lambert
// surface at its albedo (the shader multiplies by pi, as Godot does); omni
// and spot lights fall off with Godot's window and `attenuation` exponent,
// and a spot's cone with Godot's `spot_angle_attenuation`.
export class LightDesc {
    kind: u32 = LIGHT_DIRECTIONAL;
    // Linear RGB.
    color: Vec3 = Vec3(1, 1, 1);
    // Multiplies `color` (Godot's light_energy).
    energy: f32 = 1;
    // Multiplies the light's specular term (Godot's light_specular, whose
    // default is 0.5); the diffuse term keeps the whole light.
    specular: f32 = 0.5;
    // Omni and spot.
    position: Vec3 = Vec3(0, 0, 0);
    // Directional and spot: the unit direction the light travels (the
    // node's -Z).
    direction: Vec3 = Vec3(0, 0, -1);
    // Omni and spot: the distance where the light ends (Godot's omni_range,
    // spot_range), and the exponent of the distance falloff (omni_attenuation,
    // spot_attenuation).
    range: f32 = 5;
    attenuation: f32 = 1;
    // Spot: the cone's half angle in degrees (spot_angle) and the exponent
    // of its edge (spot_angle_attenuation).
    spotAngle: f32 = 45;
    spotAngleAttenuation: f32 = 1;
    // Shadows (milestone 10; Godot's Light3D shadow_* properties). Off by
    // default, and a frame whose lights all have it off draws exactly as it
    // did before shadows existed. The defaults are Light3D's; a program
    // sets each light class's own (Godot's SpotLight3D bias is 0.03, its
    // DirectionalLight3D normal bias 2).
    shadow: bool = false;
    // Moves the receiver towards the light, in texels of its shadow map
    // (shadow.as says the unit exactly).
    shadowBias: f32 = 0.1;
    // Moves the receiver along its normal, in texels of its shadow map.
    shadowNormalBias: f32 = 1;
    // The PCF kernel's radius in texels (0: one hardware-filtered tap).
    shadowBlur: f32 = 1;
    // 0: no shadow shows, 1: the full shadow.
    shadowOpacity: f32 = 1;
    // Directional only: the cascades (SHADOW_*), the split offsets as
    // fractions of `shadowMaxDistance` (Godot's directional_shadow_split_1,
    // _2, _3), the view distance the shadow reaches, and where it starts to
    // fade out, as a fraction of it (directional_shadow_fade_start).
    directionalShadowMode: u32 = SHADOW_PARALLEL_4_SPLITS;
    shadowSplits: Vec3 = Vec3(0.1, 0.2, 0.5);
    shadowMaxDistance: f32 = 100;
    shadowFadeStart: f32 = 0.8;
    // Directional only: the sun disc's angular size in degrees, as a sky
    // material draws it (Godot's light_angular_distance; milestone 11). 0,
    // the default, draws only the glow around it.
    angularDistance: f32 = 0;
    // Milestone 19 (baked lighting). Read by the baker
    // (compiler/src/bake/lightmap/baker.as) and, for `bakeMode`, by a
    // lightmapped item's shading; every other draw ignores them, so a
    // frame without a lightmap draws as before.
    //
    // LIGHT_BAKE_*: Godot's light_bake_mode (its default, dynamic).
    bakeMode: u32 = LIGHT_BAKE_DYNAMIC;
    // Omni and spot: the light's size in the frame's units (Godot's
    // light_size), which softens its baked shadows; 0 a point. A
    // directional light's softness is `angularDistance`.
    size: f32 = 0;
    // Multiplies the light's bounced light in the bake (Godot's
    // light_indirect_energy).
    indirectEnergy: f32 = 1;
    // Milestone 37: multiplies the light fog volumes and the volumetric fog
    // take from it (Godot's light_volumetric_fog_energy). Read only by a
    // frame whose volumetric fog is on (fog_volume.as).
    fogEnergy: f32 = 1;
}

// SkyDesc.kind (milestone 11): no Sky resource (the environment keeps the
// gradient and ambient of milestone 4, drawn exactly as before), Godot's
// ProceduralSkyMaterial, or its PanoramaSkyMaterial.
export const SKY_NONE: u32 = 0;
export const SKY_PROCEDURAL: u32 = 1;
export const SKY_PANORAMA: u32 = 2;

// A Sky resource and its material, as the lit mode draws it behind the
// scene and lights the scene with (image-based light: sky.as). Colours are
// linear. Directions are looked up in sky space, which is Godot's (Y up):
// `toSky` takes a direction of the frame's world to it, with the
// environment's sky_rotation already applied, so the renderer knows neither
// a program's space nor its rotations.
export class SkyDesc {
    kind: u32 = SKY_NONE;
    // Frame world direction to sky space (the w column is ignored).
    toSky: Mat4 = MAT4_IDENTITY;
    // ProceduralSkyMaterial: the gradient's four colours, its two curves,
    // the sky's and the ground's energy (sky_energy_multiplier,
    // ground_energy_multiplier), and the sun glow around each directional
    // light (sun_angle_max in degrees, sun_curve). Godot's defaults.
    skyTop: Vec3 = Vec3(0, 0, 0);
    skyHorizon: Vec3 = Vec3(0, 0, 0);
    skyCurve: f32 = 0.15;
    skyEnergy: f32 = 1;
    groundBottom: Vec3 = Vec3(0, 0, 0);
    groundHorizon: Vec3 = Vec3(0, 0, 0);
    groundCurve: f32 = 0.02;
    groundEnergy: f32 = 1;
    sunAngleMax: f32 = 30;
    sunCurve: f32 = 0.15;
    // Both materials' energy_multiplier.
    energy: f32 = 1;
    // PanoramaSkyMaterial: the equirectangular image (linear RGB; null
    // draws black), and whether it is sampled bilinearly (`filter`) or by
    // nearest texel.
    panorama: FloatImage? = null;
    filter: bool = true;
    // Sky.radiance_size in texels: the reflection map's face (sky.as
    // `radianceSize` clamps it to what the CPU prefilter builds).
    radianceSize: u32 = 256;
}

// FogDesc.mode, Godot's Environment.fog_mode.
export const FOG_EXPONENTIAL: u32 = 0;
export const FOG_DEPTH: u32 = 1;

// Godot's Environment fog (fog_*; milestone 11): depth fog, exponential or
// between two distances, and height fog below `height`, in the lit mode
// only. Off by default, and a frame without it draws as before. Distances
// are the frame world's units; `height` is along EnvironmentDesc.up.
export class FogDesc {
    enabled: bool = false;
    mode: u32 = FOG_EXPONENTIAL;
    // Linear fog_light_color times fog_light_energy.
    color: Vec3 = Vec3(0, 0, 0);
    sunScatter: f32 = 0;
    density: f32 = 0.01;
    aerialPerspective: f32 = 0;
    skyAffect: f32 = 1;
    height: f32 = 0;
    heightDensity: f32 = 0;
    depthCurve: f32 = 1;
    depthBegin: f32 = 10;
    depthEnd: f32 = 100;
}

// EnvironmentDesc.reflectedSource, Godot's Environment.reflected_light_source.
export const REFLECT_BACKGROUND: u32 = 0;
export const REFLECT_DISABLED: u32 = 1;
export const REFLECT_SKY: u32 = 2;

// EnvironmentDesc.tonemap, as surface.wgsl's TONEMAP_* numbers them (Godot's
// Environment.tonemap_mode; AgX is Godot 4.4's).
export const TONEMAP_LINEAR: u32 = 0;
export const TONEMAP_REINHARD: u32 = 1;
export const TONEMAP_FILMIC: u32 = 2;
export const TONEMAP_ACES: u32 = 3;
export const TONEMAP_AGX: u32 = 4;

// GlowDesc.blendMode, Godot's Environment.glow_blend_mode numbers.
export const GLOW_BLEND_ADDITIVE: u32 = 0;
export const GLOW_BLEND_SCREEN: u32 = 1;
export const GLOW_BLEND_SOFTLIGHT: u32 = 2;
export const GLOW_BLEND_REPLACE: u32 = 3;
export const GLOW_BLEND_MIX: u32 = 4;
// Godot's glow_levels/1 .. glow_levels/7: level k is the blur at 1 / 2^k of
// the picture's size.
export const GLOW_LEVELS: i32 = 7;

// Godot's Environment glow (glow_*; milestone 12), in the lit mode only.
// Off by default, and a frame without it draws as before. With it on, the
// main pass keeps its HDR colour and the post pass tone maps it (post.as
// says the order), as Godot's tonemap shader does.
export class GlowDesc {
    enabled: bool = false;
    // glow_levels/1 .. /7, as written (post.as `glowWeights` applies
    // `intensity` and `normalized`).
    levels: Array<f32> = [0, 0, 1, 0, 1, 0, 0];
    normalized: bool = false;
    intensity: f32 = 0.8;
    strength: f32 = 1;
    mix: f32 = 0.05;
    bloom: f32 = 0;
    blendMode: u32 = GLOW_BLEND_SOFTLIGHT;
    hdrThreshold: f32 = 1;
    hdrScale: f32 = 2;
    hdrLuminanceCap: f32 = 12;
}

// Godot's Environment screen-space ambient occlusion (ssao_*; milestone
// 12), in the lit mode only. Off by default. Distances are the frame
// world's units.
export class SsaoDesc {
    enabled: bool = false;
    radius: f32 = 1;
    intensity: f32 = 2;
    power: f32 = 1.5;
    detail: f32 = 0.5;
    horizon: f32 = 0.06;
    sharpness: f32 = 0.98;
    lightAffect: f32 = 0;
    aoChannelAffect: f32 = 0;
}

// Godot's Environment adjustments (adjustment_*; milestone 12): brightness,
// contrast and saturation of the tone-mapped sRGB picture, in the lit mode
// only. Off by default.
export class AdjustmentDesc {
    enabled: bool = false;
    brightness: f32 = 1;
    contrast: f32 = 1;
    saturation: f32 = 1;
}

// The lit mode's environment: the light every surface gets from all around,
// the sky gradient drawn behind the scene, and the tone mapping of the
// result. Colours are linear. Other modes ignore it; the clear colour is
// RenderFrame.background in every mode.
export class EnvironmentDesc {
    // Ambient light (colour times energy) when `ambientFromSky` is off.
    ambient: Vec3 = Vec3(0, 0, 0);
    // Draw the sky gradient behind the scene, over the clear colour.
    sky: bool = false;
    // The ambient light is the sky's: the gradient seen by the normal's
    // hemisphere, times `ambientEnergy` (Godot's ambient source
    // "background" under a procedural sky).
    ambientFromSky: bool = false;
    ambientEnergy: f32 = 1;
    // The gradient: zenith, horizon from above, horizon from below, nadir.
    skyTop: Vec3 = Vec3(0, 0, 0);
    skyHorizon: Vec3 = Vec3(0, 0, 0);
    groundHorizon: Vec3 = Vec3(0, 0, 0);
    groundBottom: Vec3 = Vec3(0, 0, 0);
    // The world's up direction, which the gradient is laid along (a
    // frame in Hedra's Z-up space, as Hedra's are: +Z).
    up: Vec3 = Vec3(0, 0, 1);
    tonemap: u32 = TONEMAP_LINEAR;
    // Multiplies the colour before tone mapping (tonemap_exposure), and the
    // white point of reinhard, filmic and aces (tonemap_white; linear and
    // agx ignore it, as Godot 4.4's do).
    exposure: f32 = 1;
    white: f32 = 1;
    // Milestone 11. With `skyDesc.kind` SKY_NONE (the default) and `fog`
    // off, nothing below is read and the frame draws as before.
    //
    // The Sky resource: drawn behind the scene when `sky` is set, and the
    // source of image-based light. With one, the ambient light is `ambient`
    // (flat, energy applied) or, when `ambientFromSky`, mixed towards the
    // sky's irradiance times `ambientEnergy` by `ambientSkyContribution`;
    // and reflections come from the sky's prefiltered radiance (by
    // `reflectedSource`: sky, or background under a drawn sky), the flat
    // `ambient` (background over a colour), or nothing (disabled).
    skyDesc: SkyDesc = new SkyDesc();
    // Multiplies the drawn background and the sky's light
    // (background_energy_multiplier).
    backgroundEnergy: f32 = 1;
    ambientSkyContribution: f32 = 1;
    reflectedSource: u32 = REFLECT_BACKGROUND;
    fog: FogDesc = new FogDesc();
    // Milestone 12: the post-processing, each off by default (a frame with
    // all three off draws as before; post.as `planPost` decides what runs).
    glow: GlowDesc = new GlowDesc();
    ssao: SsaoDesc = new SsaoDesc();
    adjustment: AdjustmentDesc = new AdjustmentDesc();
    // Milestone 62 (screen.as): Godot's screen-space reflections and
    // Hedra's switch of the screen-space refraction, both off by default
    // (a frame with both off, and no depth of field, draws as before;
    // post.as `planPost` decides what runs).
    ssr: SsrDesc = new SsrDesc();
    screenRefraction: ScreenRefractionDesc = new ScreenRefractionDesc();
    // With `hasPostBackground`, the clear colour (sRGB) before the tone
    // map, which the renderer clears to instead of RenderFrame.background
    // when the final pass tone maps (post.as PostPlan `toneInPost`: the
    // glow). RenderFrame.background stays tone mapped, so a frame whose
    // post passes cannot run is still drawn right.
    hasPostBackground: bool = false;
    postBackground: Vec4 = Vec4(0, 0, 0, 1);
}

export class RenderFrame {
    // Before SSAA.
    width: u32;
    height: u32;
    ssaa: u32 = 1;
    camera: Camera;
    // Globals.grid.w: how far the floor grid reaches.
    gridExtent: f32 = 0;
    // SHADE_* (Globals.params.x).
    shading: u32 = 0;
    // OV_SELECTION | OV_SEAMS | OV_SHARP.
    overlayFlags: u32 = 0;
    editMode: bool = false;
    matcap: u32 = 0;
    wireColor: Vec4 = Vec4(0, 0, 0, 1);
    selectColor: Vec4 = Vec4(0, 0, 0, 1);
    activeColor: Vec4 = Vec4(0, 0, 0, 1);
    checkerSize: f32 = 0.01;
    // sRGB, straight alpha: the clear colour.
    background: Vec4 = Vec4(0, 0, 0, 0);
    drawSurfaces: bool = true;
    // Per-range material bind groups, opaque ranges first, blended after.
    materialMode: bool = false;
    // The id pass and the selection outline in the post pass.
    outline: bool = false;
    outlineSelect: Rgba = Rgba(0, 0, 0, 0);
    outlineActive: Rgba = Rgba(0, 0, 0, 0);
    // In slot order (items[i].slot == i + 1).
    items: Array<DrawItem> = [];
    materials: Array<MaterialDesc> = [];
    // Where relative texture paths resolve.
    baseDir: string = "";
    // Slot 0, depth tested (the floor grid and axes).
    worldLines: Array<LineInstance> = [];
    // Slot 0, on top.
    topLines: Array<LineInstance> = [];
    topPoints: Array<PointInstance> = [];
    // Per item, in the order they draw.
    itemLines: Array<ItemLines> = [];
    itemPoints: Array<ItemPoints> = [];
    // width x height, composed over the picture (labels, the axis gizmo).
    overlay: Image? = null;
    // The lit mode's lights (every visible one of the frame's world; each view
    // draws a pool of at most MAX_FRAME_LIGHTS, each item at most
    // MAX_OBJECT_LIGHTS of them: light_select.as) and environment.
    // A lit frame sets `shading` to SHADE_LIT and `materialMode`, so its
    // ranges bind their materials as in Hedra's material mode.
    lights: Array<LightDesc> = [];
    environment: EnvironmentDesc = new EnvironmentDesc();
    // The box around every item that casts a shadow (castShadow not OFF),
    // in the frame's world space, and whether there is one. A directional
    // light's shadow volume is stretched to hold it, so a caster outside
    // the view still shades what is in it. Set by a program that draws
    // shadows (Hedra's adapter); ignored while no light has `shadow`.
    casterBounds: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    hasCasters: bool = false;
    // The box around every item in the picture, and whether there is one.
    // An orthographic view's eye can sit anywhere behind the scene (Camera
    // .frame moves it back as the picture narrows), so a directional
    // light's max distance and cascades are measured from this box's
    // nearest depth rather than from the eye (shadow.as `shadowOrigin`).
    // Set by Hedra's adapter; ignored while no light has `shadow`.
    drawBounds: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    hasDrawBounds: bool = false;
    // Milestone 13: whether each item was inside its visibility range the
    // last time this frame was culled (by item; cull.as reads and writes
    // it). Godot's hysteresis needs it: a frame drawn again (the preview
    // moving its camera over one plan) keeps it; Hedra's adapter starts a
    // new frame from the last one its render cache built
    // (SceneRenderCache.seedRanges), and a picture drawn alone starts
    // empty, which Godot's first frame also does.
    rangeState: Array<bool> = [];
    // Milestone 19: the baked light of the items whose lightmapLayer is 0
    // or more (the lit and lightmap shadings read it); null, as for every
    // frame without a LightmapGI: nothing is baked.
    lightmap: LightmapImages? = null;
    // Milestone 20: the reflection probes the lit mode reads reflections
    // (and, by their ambient mode, ambient light) from, at most MAX_PROBES,
    // in the order the scene declares them (compiler/src/bake/probe/
    // data.as); null, as for every frame without a ReflectionProbe:
    // reflections come from the sky (or the flat ambient) alone, as before.
    probes: ReflectionProbeSet? = null;
    // Milestone 26: Godot's mesh_lod_threshold, in pixels (before SSAA): an
    // item draws the coarsest level of detail of its mesh (GpuMesh.lods)
    // whose error, projected at the item's distance, stays under it
    // (chooseLods). 0, the default, draws level 0 alone, as before.
    lodThreshold: f32 = 0;
    // Milestone 33: the scene's visible decals, in the scene's order
    // (decal.as; the scene adapter's ../scene/render/decals.as fills them,
    // in the lit shading only). Empty, as for every frame before: no item
    // paints one, and the frame draws as before.
    decals: Array<DecalDesc> = [];
    // Milestone 34: the viewports the frame shows, in drawing order
    // (viewport.as; the scene adapter's ../scene/render/viewports.as fills
    // them, in the lit shading only), each a frame of its own drawn before
    // this one; the world this frame draws (its items' DrawItem.scenario);
    // and whether its background is transparent (a SubViewport's
    // transparent_bg: no sky, a clear of alpha 0). Empty, 0 and false for
    // every frame before, which draws as before.
    viewports: Array<ViewportDesc> = [];
    scenario: i32 = 0;
    transparent: bool = false;
    // Milestone 59: the lights chosen for the frame's camera (light_pool.as,
    // light_select.as): the pool, its directional entries and the counts,
    // refilled in place by the renderer for every view it draws of the
    // frame (planLightPool before the view's shadows, assignItemLights
    // before its object uniforms), and by the tools that count
    // (prepareLights). Empty until then.
    lightPlan: LightPlan = new LightPlan();
    // Milestone 37 (fog_volume.as): the Environment's volumetric fog, and
    // the scene's visible FogVolumes of the frame's world in the scene's
    // order (the scene adapter's ../scene/render/fog_volumes.as fills them,
    // in the lit shading only), drawn only while `volumetricFog.enabled`,
    // as Godot draws them; and the fog chosen for the frame's camera (the
    // pool, each item's list: refilled in place by the renderer for every
    // view, prepareFogVolumes). Off, empty and empty for every frame
    // before, which draws as before.
    volumetricFog: VolumetricFogDesc = new VolumetricFogDesc();
    fogVolumes: Array<FogVolumeDesc> = [];
    fogPlan: FogPlan = new FogPlan();
    // Milestone 37 (occlusion.as): the scene's visible occluders of the
    // frame's world (OccluderInstance3D nodes; the scene adapter's
    // ../scene/render/occluders.as fills them, in every shading that draws
    // surfaces), and whether culling uses them (`render --occlusion off`
    // and the tests turn it off). cull.as tests every item against them
    // after the frustum (CULL_OCCLUDED). Empty for every frame before,
    // which culls as before.
    occluders: Array<OccluderDesc> = [];
    occlusion: bool = true;
    // Milestone 61: Godot's TIME for the custom shaders of the frame, in
    // seconds, wrapped at shader/program.as SHADER_TIME_ROLLOVER (the
    // scene's clock in the run time, `render --time` in the tools, the
    // seconds since the tab opened in the editor). Written into the
    // fparams.w of the custom shaders' globals alone (gpu/custom.as
    // customGlobals: the surface and lines modules read their fparams.w
    // as the fallback target's flag), so it changes no other picture.
    shaderTime: f32 = 0;
    // Whether the occlusion buffer is coarser (half as wide) while this
    // frame's view moves from one drawing of it to the next (occlusion.as):
    // false keeps it at its whole width.
    occlusionMotion: bool = true;
    // Milestone 62 (screen.as): the depth of field of the frame's camera
    // (Godot's CameraAttributesPractical; off by default), the effects'
    // quality (the project's settings, the same for every view of a
    // frame) and the effects this view may draw (SCREEN_* bits: the
    // editor's View › Screen-Space Effects, render's --ssr,
    // --screen-refraction and --dof off). A frame whose environment and
    // camera turn none on draws as before whatever these say.
    dof: DofDesc = new DofDesc();
    screenQuality: ScreenQuality = new ScreenQuality();
    screenEffects: u32 = SCREEN_EFFECTS_ALL;
    // Milestone 67 (quality.as): the render quality (the project's
    // settings, the same for every view of a frame: MSAA, the colour
    // format, the prepass, the opaque sort, specialised shaders), and the
    // size the finished picture is upscaled to by FSR 1.0 (gpu/fsr.as; 0:
    // none, the picture presented as drawn: scaling.as).
    renderQuality: RenderQuality = new RenderQuality();
    outputWidth: u32 = 0;
    outputHeight: u32 = 0;

    constructor(width: u32, height: u32, camera: Camera) {
        this.width = width;
        this.height = height;
        this.camera = camera;
    }
}

// Milestone 26: each item's level of detail (DrawItem.lod) for the
// frame's camera and lodThreshold: 0 everywhere while the threshold is 0.
// Allocates nothing (the editors choose again on every frame the camera
// moves).
export function chooseLods(f: RenderFrame): void {
    const items = f.items;
    const t = f.lodThreshold;
    for (let i = 0; i < items.length; i++) {
        const d = unchecked(items[i]);
        d.lod = t > 0 ? itemLod(f, d, t) : 0;
    }
}

// The coarsest level of `d`'s mesh whose error, as a length (the error,
// relative to the mesh's bounding radius, times that radius times the
// item's largest axis scale), covers fewer than `threshold` pixels at the
// distance from the eye to the item's box (Camera.worldPerPixel); 0 when
// none does, or the item has no levels, no box, or the eye is in its box.
// A level the mesh's index buffer does not hold is passed over (lodUsable).
// An instanced item's scale is its own transform's, the instances' not
// counted, and its box holds every instance (Godot's MultiMesh takes its
// whole box's distance too).
export function itemLod(f: RenderFrame, d: DrawItem, threshold: f32): i32 {
    const g = d.mesh;
    if (g == null || !d.hasBounds) return 0;
    const ls = g.lods;
    if (ls == null || ls.length == 0) return 0;
    lodSphere(g);
    const w = d.world;
    const sx = w.xAxis.x * w.xAxis.x + w.xAxis.y * w.xAxis.y + w.xAxis.z * w.xAxis.z;
    const sy = w.yAxis.x * w.yAxis.x + w.yAxis.y * w.yAxis.y + w.yAxis.z * w.yAxis.z;
    const sz = w.zAxis.x * w.zAxis.x + w.zAxis.y * w.zAxis.y + w.zAxis.z * w.zAxis.z;
    const radius = g.lodRadius * Mathf.sqrt(maxF32(sx, maxF32(sy, sz)));
    if (!(radius > 0)) return 0;
    const e = f.camera.eye;
    const b = d.bounds;
    const dx = maxF32(maxF32(b.min.x - e.x, e.x - b.max.x), 0);
    const dy = maxF32(maxF32(b.min.y - e.y, e.y - b.max.y), 0);
    const dz = maxF32(maxF32(b.min.z - e.z, e.z - b.max.z), 0);
    const dist = Mathf.sqrt(dx * dx + dy * dy + dz * dz);
    if (!f.camera.isOrtho() && !(dist > 0)) return 0;
    const wpp = f.camera.worldPerPixel(dist, f.height);
    if (!(wpp > 0)) return 0;
    for (let k = ls.length; k >= 1; k--) {
        if (!lodUsable(g, k)) continue;
        if (unchecked(ls[k - 1]).error * radius / wpp < threshold) return k;
    }
    return 0;
}

// The Globals block of a frame. `encodeInShader`: the main target is the
// rgba8unorm fallback, where the fragment shaders encode to sRGB
// (`fparams.w` = 1; 0 otherwise). A new block; the renderer fills its own
// with `frameGlobalsInto`.
export function frameGlobals(f: RenderFrame, encodeInShader: bool): Globals {
    return frameGlobalsInto(f, encodeInShader, new Globals());
}

// frameGlobals(f, encodeInShader) written into `out`, every field; returns
// `out`.
export function frameGlobalsInto(f: RenderFrame, encodeInShader: bool, out: Globals): Globals {
    const ssaa = max<u32>(f.ssaa, 1);
    const pxW = f.width * ssaa;
    const pxH = f.height * ssaa;
    const aspect = <f32>f.width / <f32>f.height;
    const cam = f.camera;
    const viewM = cam.viewMatrix();
    const projM = cam.projectionMatrix(aspect);
    out.view = viewM;
    out.proj = projM;
    out.viewProj = projM * viewM;
    out.cameraPos = Vec4(cam.eye.x, cam.eye.y, cam.eye.z, cam.isOrtho() ? 1.0 : 0.0);
    out.viewport = Vec4(<f32>pxW, <f32>pxH, <f32>1.0 / <f32>pxW, <f32>1.0 / <f32>pxH);
    out.wireColor = f.wireColor;
    out.selectColor = f.selectColor;
    out.activeColor = f.activeColor;
    out.grid = Vec4(cam.target.x, cam.target.y, cam.target.z, f.gridExtent);
    out.params = U32x4(f.shading, f.overlayFlags, f.editMode ? 1 : 0, f.matcap);
    out.fparams = Vec4(0.0015, maxF32(f.checkerSize, 0.01), <f32>ssaa, encodeInShader ? 1.0 : 0.0);
    return out;
}

// Slot 0 (identity, white: the world, for the grid, cursor and origins),
// then one ObjectUniform per item.
export function frameObjects(f: RenderFrame): Array<ObjectUniform> {
    const out = new Array<ObjectUniform>();
    out.push(new ObjectUniform().setWorld());
    for (let i = 0; i < f.items.length; i++) {
        out.push(itemUniformInto(f, f.items[i], new ObjectUniform()));
    }
    return out;
}

// frameObjects(f) written straight into `dv` at `stride` bytes a slot (the
// bytes gpu/renderer.as `packObjectUniforms` makes of it, the gaps between
// slots left as they are), with no array and every slot filled into
// `scratch` in turn: the renderer writes every frame's objects with it into
// a buffer it keeps, through a uniform it keeps, so that nothing reaches
// the heap (milestone 13: the stub runtime never frees). Without `scratch`
// one is made. `dv` holds at least `f.items.length + 1` slots.
export function writeFrameObjects(
    f: RenderFrame, dv: DataView, stride: u32, used: Array<bool>? = null, scratch: ObjectUniform? = null,
): void {
    const u = scratch != null ? scratch! : new ObjectUniform();
    u.setWorld().writeAt(dv, 0);
    for (let i = 0; i < f.items.length; i++) {
        // (milestone 37: with `used`, cull.as CullResult.used, the blocks no
        // pass of the view reads are left as they were)
        if (used != null && !(i < used.length && unchecked(used[i]))) continue;
        itemUniformInto(f, f.items[i], u).writeAt(dv, <u32>(i + 1) * stride);
    }
}

// Item `d` is still emerging (Hedra's emerge below 1): it draws with
// OBJ_EMERGE and casts through the masked shadow pipelines.
export function emerging(d: DrawItem): bool {
    return d.emerge < 1;
}

// Item `d` is fading (Hedra's fade above 0): it draws with OBJ_FADE.
export function fading(d: DrawItem): bool {
    return d.fade > 0;
}

// A 0 to 1 colour channel as a byte, rounded.
function colorByte(c: f32): u32 {
    return <u32>Math.round(<f64>maxF32(0, minF32(c, 1)) * 255);
}

// The ObjectUniform of item `d` of frame `f`. Milestone 19: OBJ_LIGHTMAP
// and the layer in extra.y when the item is lightmapped in a frame that
// has a lightmap, OBJ_PROBE_GI and the probe light in `gi` when it has
// probe light; an item with neither (every item of a frame without a
// bake, and all of Hedra's) has its 176 bytes of before and 48 zeros.
// Milestone 20: in a frame with reflection probes, extra.z holds the item's
// probes (milestone 67, probe_select.as itemProbeMask: bit r for the
// frame's probe of atlas row r whose box meets the item's and whose
// reflection mask meets its layers; the shader weighs those alone, in the
// frame's order, the sums it made weighing every probe); 0 in every other
// frame, whose blocks are as before. Milestone 48:
// OBJ_SKINNED for an item with a skin (its world and normal are the
// identity); clear for every other item. Milestone 33: the item's decals
// (DrawItem.decalCount, decals0, decals1: zeros without any). Milestone 59:
// the item's lights (DrawItem.lights0, lights1, lightCount, lightsReached:
// zeros until the renderer chose them). Milestone 37: the item's fog
// volumes in decals.w (DrawItem.fogVolumes: 0 without volumetric fog).
// Hedra's emerge: OBJ_EMERGE for an item still emerging (DrawItem.emerge
// below 1), the fog's colour in extra.w (sRGB bytes, red low) and how far
// in the normal matrix's first column's w (normal.xAxis.w, an f32), which
// the shader never reads (a normal moved through it keeps only xyz); zeros
// for every other item, whose normal matrix is as before. Hedra's fade:
// OBJ_FADE for a fading item (`fading`), the fade colour (linear, each
// channel at least 0) and how far (at most 1) in the normal matrix's
// fourth column, which the shader never reads otherwise (a normal is moved
// with a w of 0); every other item's normal matrix is as before. Written
// into `out`, every field; returns `out`.
function itemUniformInto(f: RenderFrame, d: DrawItem, out: ObjectUniform): ObjectUniform {
    let bits: u32 = (d.hasWeights ? OBJ_HAS_WEIGHTS : 0) | (d.mirrored ? OBJ_MIRRORED : 0);
    if (d.skin != null && d.skinJointCount > 0) bits |= OBJ_SKINNED;
    let fog: u32 = 0;
    if (emerging(d)) {
        bits |= OBJ_EMERGE;
        fog = colorByte(d.emergeColor.x) | (colorByte(d.emergeColor.y) << 8) | (colorByte(d.emergeColor.z) << 16);
    }
    let layer: u32 = 0;
    if (d.lightmapLayer >= 0 && f.lightmap != null) {
        bits |= OBJ_LIGHTMAP;
        layer = <u32>d.lightmapLayer;
    }
    let gi0 = Vec4(0, 0, 0, 0);
    let gi1 = Vec4(0, 0, 0, 0);
    let gi2 = Vec4(0, 0, 0, 0);
    const sh = d.probeSh;
    if (sh != null && sh.length >= SH_L1_FLOATS) {
        bits |= OBJ_PROBE_GI;
        gi0 = Vec4(sh[0], sh[1], sh[2], sh[3]);
        gi1 = Vec4(sh[4], sh[5], sh[6], sh[7]);
        gi2 = Vec4(sh[8], sh[9], sh[10], sh[11]);
    }
    out.model = d.world;
    out.normal = d.normal;
    if (emerging(d) || fading(d)) {
        const n = d.normal;
        let x = n.xAxis;
        let w = n.wAxis;
        if (emerging(d)) x = Vec4(x.x, x.y, x.z, maxF32(d.emerge, 0));
        if (fading(d)) {
            bits |= OBJ_FADE;
            const k = d.fadeColor;
            w = Vec4(
                srgbToLinear(maxF32(k.x, 0)), srgbToLinear(maxF32(k.y, 0)), srgbToLinear(maxF32(k.z, 0)),
                minF32(d.fade, 1));
        }
        out.normal = Mat4(x, n.yAxis, n.zAxis, w);
    }
    out.color = d.color;
    out.params = U32x4(d.selected ? 1 : 0, d.active ? 1 : 0, d.pickId, d.edit ? 1 : 0);
    out.extra = U32x4(bits, layer, itemProbeMask(f.probes, d.layers, d.hasBounds, d.bounds), fog);
    out.gi0 = gi0;
    out.gi1 = gi1;
    out.gi2 = gi2;
    out.decals = U32x4(d.decals0, d.decals1, d.decalCount, d.fogVolumes);
    out.lights = U32x4(d.lights0, d.lights1, d.lightCount, d.lightsReached);
    return out;
}
