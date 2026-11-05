// Fog volumes as a frame carries them (milestone 37; Godot's FogVolume and
// FogMaterial, and the Environment's volumetric fog): "volumetric-lite",
// drawn without froxels. Godot fills a 3D grid of froxels and ray-marches
// it; Hedra integrates each pixel's ray analytically over each volume's
// shape, in the surface shader, as the depth and height fog of milestone 11
// is (surface.wgsl `fog_volumes`, after `surface_fog`), within what WebGL 2
// allows (no compute, no 3D render targets, no storage buffers):
//
//   - a frame's volumes in the view make a pool of at most
//     MAX_FRAME_FOG_VOLUMES (the fog block, gpu/layouts.as FogUniform, the
//     object group's binding 5), the Environment's own volumetric fog
//     (VolumetricFogDesc, a world-wide volume within its `length`) its first
//     entry when its density is not 0;
//   - each item names the pool's entries its pixels may be seen through, at
//     most MAX_OBJECT_FOG_VOLUMES (ObjectUniform.decals.w, a byte each, the
//     entry plus 1), and the sky the entries the view's rays cross
//     (FogUniform.counts.y); a list that more entries meet carries
//     fog_select.as FOG_LIST_ALL, and each of its pixels then takes the
//     first MAX_OBJECT_FOG_VOLUMES entries its own ray crosses, in the
//     pool's order;
//   - each pool entry is lit by up to MAX_OBJECT_LIGHTS of the frame's
//     lights, chosen for its box as milestone 59 chooses an item's
//     (light_select.as assignBoxLights): the per-object lights.
//
// A program fills RenderFrame.volumetricFog and .fogVolumes with what does
// not depend on the camera (the scene adapter's ../scene/render/
// fog_volumes.as); the renderer chooses the pool, the lists and the
// entries' lights for the camera it draws from (fog_select.as
// prepareFogVolumes), as cull.as culls. A frame whose volumetric fog is off
// (every frame of a scene without it, every shading but lit) draws exactly
// as before: the volumes are carried, never drawn, as Godot draws a
// FogVolume only while volumetric_fog_enabled is on.
//
// The integration (normative; fog_select.as fogOpticalDepth is its CPU
// twin, which the tests hold the shader to). A pixel's ray starts at the
// eye (an orthographic view: the point of the camera's plane behind the
// pixel) and ends at the surface drawn, or for the sky at
// FOG_SKY_DISTANCE. For each volume it names:
//   1. the chord [t0, t1] of the ray inside the shape, in metres from the
//      ray's start, exact: the ray in the node's space (toLocal) against
//      Godot's shapes of `size` (h = size / 2): box |p| <= h; ellipsoid
//      |p / h| <= 1; cylinder along Y, radius min(h.x, h.z), |y| <= h.y;
//      cone along Y, its apex at y = h.y, its base of radius
//      min(h.x, h.z) at y = -h.y (Godot's SDF: volumetric_fog.glsl); world
//      (the Environment's own fog, and a FogVolume of shape world): [0,
//      volumetric_fog_length]; every chord clipped to [0, the ray's end]
//      and to volumetric_fog_length, as far as Godot's froxels reach (a
//      volume wholly past it is not in the pool: fog_select.as);
//   2. Godot's FogMaterial density at a point p (frame world) of it:
//        density * clamp(exp2(-height_falloff * (h(p) - h(origin))), 0, 1)
//                * pow(clamp(-2 * sdf(p) / min(size), 0, 1), edge_fade)
//      with h() the height along the frame's up and sdf Godot's signed
//      distance of the shape in the node's space (the edge term is 1 for
//      the world shape and for edge_fade 0);
//   3. its optical depth tau, the density's integral over the chord: the
//      closed form when edge_fade is 0 (the chord's length times density
//      without a height falloff, the exponential's integral with one,
//      split where the height crosses the origin's), else FOG_SAMPLES-point
//      Gauss-Legendre over each of the chord's two halves, split where the
//      height crosses the origin's (with a falloff) or in its middle (where
//      a symmetric shape's edge term has its kink);
//   4. its light, at FOG_SAMPLES Gauss-Legendre nodes of the whole chord
//      (the lights are the costly part): the scattered light
//        albedo * (sum over the entry's lights of colour * attenuation *
//        henyey_greenstein(dot(ray, towards the light), anisotropy) *
//        fog_energy + ambient * ambient_inject)
//      plus emission, each times clamp(density, 0, 1) as Godot's froxels
//      weigh them, integrated over the chord (Q);
//   5. the volumes together, order-independent: a volume of negative
//      density takes away the positive ones' optical depth only where its
//      chord overlaps theirs (each one's taken as spread evenly along its
//      chord, at most all of it there: Godot clamps a froxel's summed
//      density at 0), their light in proportion (fog_select.as
//      fogCombineDepths); then T = exp(-sum tau) and the scattered light
//      S = sum Q * (1 - T) / max(sum tau, 1e-5) (Godot's Beer's-law
//      integration of one froxel, the volumes taken as one medium along
//      the ray);
//   6. over the colour the depth and height fog left: c * T + S (Godot's
//      full blending of volumetric over depth fog), before the tone map;
//      the sky's by volumetric_fog_sky_affect.
// Where it differs from Godot (docs/engine/FOG.md says why): no froxels and
// no temporal reprojection (no flicker, no ghosting; a thin volume is never
// missed); the volumes along a ray are one medium (step 5), not marched
// front to back, so a lit volume behind a dark one is not dimmed by it
// beyond the transmittance, and a negative volume takes away what it
// overlaps as if each density were even along its chord; lights cast no
// shadows in the fog (no light shafts) and there is no GI inject; the
// ambient light is the average lit() gives a surface, isotropic;
// density_texture is not drawn (nor a ShaderMaterial's fog); each chord is
// lit at FOG_SAMPLES points; at most MAX_OBJECT_FOG_VOLUMES a pixel and
// MAX_FRAME_FOG_VOLUMES a frame; and they draw on every renderer (Godot's
// only in Forward+).

import { MAT4_IDENTITY, Mat4, Vec3 } from "../base/vecmath";
import { Bounds } from "./camera";

// The most fog volumes a frame draws (the fog block's entries:
// gpu/layouts.as FOG_UNIFORM_ENTRIES; the fog tests check they agree),
// the Environment's own volumetric fog counted. Beyond it the ones nearest
// the camera are kept, and the statistics count the rest.
export const MAX_FRAME_FOG_VOLUMES: i32 = 16;
// The most one pixel integrates (ObjectUniform.decals.w's four bytes):
// the Environment's fog first, then the volumes nearest the camera.
export const MAX_OBJECT_FOG_VOLUMES: i32 = 4;
// The Gauss-Legendre nodes along a chord (exact for a polynomial of degree
// 7 over it).
export const FOG_SAMPLES: i32 = 4;
// Where a sky pixel's ray ends (metres): past every bounded volume a scene
// draws; every chord ends at the fog's length before it.
export const FOG_SKY_DISTANCE: f32 = 1.0e6;
// Godot's density floor (FogMaterial: "values between -0.001 and 0.001
// act like 0").
export const FOG_DENSITY_EPSILON: f32 = 0.001;

// Godot's RenderingServer.FogVolumeShape (FogVolume.shape).
export const FOG_SHAPE_ELLIPSOID: i32 = 0;
export const FOG_SHAPE_CONE: i32 = 1;
export const FOG_SHAPE_CYLINDER: i32 = 2;
export const FOG_SHAPE_BOX: i32 = 3;
export const FOG_SHAPE_WORLD: i32 = 4;
export const FOG_SHAPE_NAMES: StaticArray<string> = ["ellipsoid", "cone", "cylinder", "box", "world"];

// FogPlan.entries: the pool entry that is the Environment's volumetric fog.
export const FOG_ENTRY_ENVIRONMENT: i32 = -1;

// The Environment's volumetric fog (Godot's volumetric_fog_*), for the
// frame's camera: what the fog block's header carries (the phase, the
// ambient, the sky's share) and, when `density` is not 0, the pool's first
// entry, a world-wide volume within `length` of the eye.
export class VolumetricFogDesc {
    // volumetric_fog_enabled: the FogVolumes are drawn only while it is on.
    enabled: bool = false;
    // Per metre, everywhere within `length`.
    density: f32 = 0.05;
    // Linear rgb.
    albedo: Vec3 = Vec3(1, 1, 1);
    // Linear rgb, times volumetric_fog_emission_energy.
    emission: Vec3 = Vec3(0, 0, 0);
    // Henyey-Greenstein's g, held to -0.9 .. 0.9 as Godot's inspector holds
    // it.
    anisotropy: f32 = 0.2;
    // Metres from the eye.
    length: f32 = 64;
    ambientInject: f32 = 0;
    skyAffect: f32 = 1;
}

// One FogVolume of a frame, as its program planned it: everything that does
// not depend on the camera. A class filled in place (the scene adapter
// refreshes a frame's volumes every frame a scene moves), so it allocates
// nothing once made.
export class FogVolumeDesc {
    shape: i32 = FOG_SHAPE_BOX;
    // The frame's world to the node's own space (Godot's params.transform:
    // the inverse of the node's global transform, its scale included), and
    // back.
    toLocal: Mat4 = MAT4_IDENTITY;
    world: Mat4 = MAT4_IDENTITY;
    // Godot's size, in the node's space (each at least 0).
    size: Vec3 = Vec3(2, 2, 2);
    // The node's origin in the frame's world (the height falloff's
    // reference: Godot's OBJECT_POSITION).
    origin: Vec3 = Vec3(0, 0, 0);
    // The shape's box in the frame's world (its corners through `world`);
    // none for the world shape, which reaches everything.
    bounds: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    hasBounds: bool = true;
    // Its FogMaterial's (Godot's default fog without one), Godot's clamps
    // applied: height_falloff and edge_fade at least 0. Colours linear.
    density: f32 = 1;
    albedo: Vec3 = Vec3(1, 1, 1);
    emission: Vec3 = Vec3(0, 0, 0);
    heightFalloff: f32 = 0;
    edgeFade: f32 = 0.1;
    // Its place among the frame's volumes, in the scene's order (ties).
    order: i32 = 0;
    // The node's path, for warnings and the statistics (not drawn).
    label: string = "";
    // Whether it draws nothing: a size of 0 on an axis, a density within
    // FOG_DENSITY_EPSILON of 0, a transform that cannot be inverted
    // (prepareFogVolumes leaves it out of the pool).
    empty: bool = false;
    // Milestone 34 (viewport.as): the world it is in (its node's, as
    // DrawItem.scenario). 0 in every scene without a SubViewport.
    scenario: i32 = 0;
}

// What prepareFogVolumes chose for one camera (fog_select.as), kept on the
// frame (RenderFrame.fogPlan) and refilled in place every time the renderer
// draws a view of it: a warm frame allocates nothing.
export class FogPlan {
    // By pool entry: an index into RenderFrame.fogVolumes, or
    // FOG_ENTRY_ENVIRONMENT; the first `count` of MAX_FRAME_FOG_VOLUMES.
    entries: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_FOG_VOLUMES);
    count: i32 = 0;
    // By pool entry: its lights, as an item's (DrawItem.lights0, lights1,
    // lightCount: entries of the frame's light pool, a byte each).
    lights0: StaticArray<u32> = new StaticArray<u32>(MAX_FRAME_FOG_VOLUMES);
    lights1: StaticArray<u32> = new StaticArray<u32>(MAX_FRAME_FOG_VOLUMES);
    lightCounts: StaticArray<u32> = new StaticArray<u32>(MAX_FRAME_FOG_VOLUMES);
    // The sky's list (FogUniform.sky: up to MAX_OBJECT_FOG_VOLUMES entries
    // plus 1, a byte each), and how many.
    sky: u32 = 0;
    skyCount: i32 = 0;
    // The volumes in the view (their box meets the view's frustum, the
    // world shape always), and those left out of the pool (past
    // MAX_FRAME_FOG_VOLUMES).
    inView: i32 = 0;
    dropped: i32 = 0;
    // The items seen through at least one, and those more than
    // MAX_OBJECT_FOG_VOLUMES reach (they integrate the first ones).
    items: i32 = 0;
    overBudget: i32 = 0;
    // The volumes in view left out of the pool (indices into
    // RenderFrame.fogVolumes, in the scene's order: `dropped` of them),
    // which the plan's warning names (fog_select.as fogPoolWarning).
    // Refilled in place by planFogPool (reset() leaves it): its capacity
    // grows to the most a frame dropped.
    droppedVolumes: Array<i32> = [];
    // By pool entry: the distance from the eye to the entry's box (0 for a
    // world shape and the Environment's fog), and the pool's entries in the
    // order the items and the sky take them (the Environment's first, then
    // the nearest, ties in pool order).
    distances: StaticArray<f32> = new StaticArray<f32>(MAX_FRAME_FOG_VOLUMES);
    ranked: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_FOG_VOLUMES);

    reset(): void {
        this.count = 0;
        this.sky = 0;
        this.skyCount = 0;
        this.inView = 0;
        this.dropped = 0;
        this.items = 0;
        this.overBudget = 0;
    }
}
