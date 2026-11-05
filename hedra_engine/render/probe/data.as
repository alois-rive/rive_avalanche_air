// Reflection probes (milestone 20, Godot's ReflectionProbe): the data every
// part of them agrees on. Hedra puts a scene's probes on a frame
// (RenderFrame.probes: engine/src/scene/render/probes.as); a probe whose
// update mode is `once` is captured by the CLI's `bake` on the CPU
// (capture.as) and read back from its .rprobe file
// (engine/src/scene/probe/rprobe.as, docs/formats/RSCN.md
// "ReflectionProbeData"); one without a bake, or whose mode is `always`,
// is captured by the renderer with the GPU (gpu/probes.as); either way the
// lit shader reads its filtered cube (surface.wgsl's probe block, group 0,
// binding 7, and the atlas and its sampler, group 3, bindings 6 and 7).
//
// Nothing here knows a scene. Conventions every part shares:
//
// - Probe space is the probe node's own axes as scene space has them: +Y
//   up, metres, its origin the node's. Only the node's rotation and
//   position place it (`toWorld` is rigid): its scale is not used, and
//   `extents` alone sizes the box, which is centred on the origin.
// - A probe's cube is in probe space, with sky.as's conventions: faces +X,
//   -X, +Y, -Y, +Z, -Z, rows top first (sky.as cubeDir and cubeFaceUv),
//   PROBE_FACE_SIZE texels a face at level 0 and PROBE_LEVELS levels down
//   to 4, level m prefiltered for perceptual roughness m / (PROBE_LEVELS -
//   1) by sky.as prefilterCube: a material reads it as it reads the sky's
//   map, by its roughness.
// - A capture holds linear radiance before exposure and the tone map (the
//   capture's environment is `captureEnvironmentInto`'s), as a sky's map
//   does, so the frame that reads it applies its own exposure once.
// - No probe is drawn inside a capture (neither capture reads probes:
//   their reflections come from the sky alone), so a capture never depends
//   on another, or on itself.
//
// How a frame reads its probes (surface.wgsl follows `probeWeight`,
// `probeLookup` and the accumulation below, number for number):
//   for each probe of the frame, in order, whose reflectionMask meets the
//   item's layers and whose weight w at the point is above 0:
//     reflections: acc += sample(lookup, roughness) * intensity * w;
//                  accW += w
//     ambient (ambientMode not disabled): amb += (environment: the cube's
//                  last level along the normal in probe space; constant:
//                  ambientColor) * w; ambW += w
//   each sum is divided by its weight when the weight is above 1 (and the
//   weight is then 1); then the sky's specular light becomes
//   specSky * (1 - accW) + acc, and the diffuse ambient light
//   diffuseAmb * (1 - ambW) + amb (but on a lightmapped surface, whose
//   diffuse light is its lightmap's, and an item with probe light from a
//   LightmapGI, whose diffuse light is the probes' SH).

import { MAT4_IDENTITY, Mat4, Vec3 } from "../../base/vecmath";
import { Camera, Projection } from "../camera";
import {
    AdjustmentDesc, DrawItem, EnvironmentDesc, FogDesc, GlowDesc, REFLECT_DISABLED, SkyDesc, SsaoDesc,
    TONEMAP_LINEAR,
} from "../frame";
import { RadianceMap, cubeDir, radianceLevels } from "../sky";

// ReflectionProbe.update_mode, Godot's numbers: captured once (by the CLI's
// `bake`, into its .rprobe; without one, by the renderer on the first frame
// that draws it), or again on every frame drawn (within
// PROBE_LIVE_PER_FRAME).
export const PROBE_UPDATE_ONCE: i32 = 0;
export const PROBE_UPDATE_ALWAYS: i32 = 1;

// ReflectionProbe.ambient_mode, Godot's numbers.
export const PROBE_AMBIENT_DISABLED: i32 = 0;
export const PROBE_AMBIENT_ENVIRONMENT: i32 = 1;
export const PROBE_AMBIENT_CONSTANT_COLOR: i32 = 2;

// A capture's face, in texels on a side, baked and live alike (Godot's
// reflection atlas is 256 by default; 128 is the largest sky map the CPU
// prefilter builds, RADIANCE_MAX_SIZE, and keeps a bake to seconds).
export const PROBE_FACE_SIZE: u32 = 128;
// Its levels: 128, 64, 32, 16, 8, 4 (sky.as radianceLevels(128)).
export const PROBE_LEVELS: u32 = 6;

// The most probes a frame draws (the shader's block); a scene's further
// ones are left out, in tree order, with a warning.
export const MAX_PROBES: i32 = 8;

// The most live captures the renderer makes in one frame drawn (each is six
// views of the scene): the `always` probes take turns, round robin. A
// `once` probe without a bake is captured on the first frame that draws it
// whatever this says, so a single picture (the CLI's `render`) has every
// probe captured.
export const PROBE_LIVE_PER_FRAME: i32 = 1;

// The CPU capture's rays a texel: a fixed 2 x 2 pattern (capture.as), as
// the GPU's 4 MSAA samples smooth its edges.
export const PROBE_SUPERSAMPLES: i32 = 4;

// A capture's near plane, metres; its far plane is `probeFar`.
export const PROBE_NEAR: f32 = 0.01;

// Godot's default cull_mask and reflection_mask: all 20 layers.
export const PROBE_ALL_LAYERS: u32 = 0xfffff;

// One probe of a frame. Everything is in the frame's world space but what
// says probe space (the header).
export class ReflectionProbeDesc {
    // Who it is (Hedra: the node's path from the tree's root): the
    // renderer keeps one atlas row, and one live capture, per key.
    key: string = "";
    // Whose probe it is (Hedra: the root scene's absolute path): with
    // `key`, what a row is kept for, so that one renderer drawing two
    // scenes (the editor's tabs) never draws a probe from the capture of
    // another scene's probe at the same path.
    scene: string = "";
    // Probe space to the frame's world, rigid; `toLocal` its inverse.
    toWorld: Mat4 = MAT4_IDENTITY;
    toLocal: Mat4 = MAT4_IDENTITY;
    // Half the box (Godot's size / 2), probe space.
    extents: Vec3 = Vec3(10, 10, 10);
    // Where it captures from (Godot's origin_offset), probe space.
    originOffset: Vec3 = Vec3(0, 0, 0);
    updateMode: i32 = PROBE_UPDATE_ONCE;
    // Multiplies its reflections (not its ambient light, as Godot's).
    intensity: f32 = 1;
    // How far inside the box, from its faces, the probe fades in (metres;
    // 0: none, full weight up to the faces).
    blendDistance: f32 = 1;
    // The capture's far plane (0: `probeFar` takes the box's diagonal).
    maxDistance: f32 = 0;
    // Box-projected (parallax-corrected) lookups.
    boxProjection: bool = false;
    // Indoors: the capture sees no sky and gets no light from the
    // environment (captureEnvironmentInto).
    interior: bool = false;
    // The capture draws the lights' shadows (Godot's enable_shadows, off
    // by default: a capture is drawn without them).
    enableShadows: bool = false;
    ambientMode: i32 = PROBE_AMBIENT_ENVIRONMENT;
    // ambient_color, linear, times ambient_color_energy.
    ambientColor: Vec3 = Vec3(0, 0, 0);
    // Which items it captures (DrawItem.layers) and which it reflects in.
    cullMask: u32 = PROBE_ALL_LAYERS;
    reflectionMask: u32 = PROBE_ALL_LAYERS;
    // Its baked capture (a ReflectionProbeData): PROBE_LEVELS levels of
    // PROBE_FACE_SIZE, prefiltered. null: the renderer captures it live
    // (update mode always, or once without a bake). The renderer uploads a
    // baked cube once per RadianceMap object (by identity), so a program
    // hands the same object while the bake is the same.
    cube: RadianceMap? = null;

    // Where it captures from, the frame's world space.
    capturePoint(): Vec3 {
        return this.toWorld.transformPoint3(this.originOffset);
    }
}

// What a frame's probes are: the probes (at most MAX_PROBES) and the colour
// a capture sees where it sees neither a surface nor a sky.
export class ReflectionProbeSet {
    list: Array<ReflectionProbeDesc> = [];
    // The colour the main view is cleared to behind the scene when its
    // environment draws no sky (a colour background, or none), linear,
    // before exposure and the tone map (Hedra: the Environment's
    // background colour times its energy; the default clear colour
    // otherwise). A capture's background where its environment draws no
    // sky; ignored by an interior probe, whose background is black.
    clear: Vec3 = Vec3(0, 0, 0);
}

// The far plane of `p`'s capture: max_distance, or (0) the box's diagonal,
// Godot's automatic distance; never nearer than ten times PROBE_NEAR.
export function probeFar(p: ReflectionProbeDesc): f32 {
    const far = p.maxDistance > 0 ? p.maxDistance : p.extents.length() * 2;
    return Mathf.max(far, PROBE_NEAR * 10);
}

// Face `face`'s direction (its centre) and its picture's up, probe space
// (sky.as cubeDir: the up of a face is towards its row 0).
export function probeFaceForward(face: i32): Vec3 {
    return cubeDir(face, 0.5, 0.5);
}

export function probeFaceUp(face: i32): Vec3 {
    switch (face) {
        case 2: return Vec3(0, 0, -1);
        case 3: return Vec3(0, 0, 1);
        default: return Vec3(0, 1, 0);
    }
}

// The camera the renderer captures face `face` of `p` with, into `out`
// (nothing allocated): from the capture point along the face's direction,
// its up the face's, 90 degrees on a square picture, PROBE_NEAR to
// probeFar. Its picture is the face mirrored left to right (a camera's
// right is forward x up; a cube face's, as sky.as lays it out, is the
// other way: a cube is seen from inside), so the texel at column x of the
// picture is column PROBE_FACE_SIZE - 1 - x of the face.
export function probeFaceCamera(p: ReflectionProbeDesc, face: i32, out: Camera): void {
    const eye = p.capturePoint();
    const forward = p.toWorld.transformVector3(probeFaceForward(face));
    const up = p.toWorld.transformVector3(probeFaceUp(face));
    out.eye = eye;
    out.target = eye + forward;
    out.up = up;
    out.projection = Projection.perspective(90);
    out.near = PROBE_NEAR;
    out.far = probeFar(p);
}

// Whether `p`'s capture draws item `d`.
export function capturesItem(p: ReflectionProbeDesc, d: DrawItem): bool {
    return d.captured && (d.layers & p.cullMask) != 0;
}

// Whether `p` reflects in item `d` (the shader reads ObjectU.extra.z).
export function reflectsIn(p: ReflectionProbeDesc, d: DrawItem): bool {
    return (d.layers & p.reflectionMask) != 0;
}

// The weight of `p` at `world` (a point of the frame's world): 0 outside
// the box; inside, the distance to its nearest face over blendDistance,
// at most 1 (1 everywhere inside when blendDistance is 0).
export function probeWeight(p: ReflectionProbeDesc, world: Vec3): f32 {
    const l = p.toLocal.transformPoint3(world);
    const e = p.extents;
    const d = Mathf.min(e.x - Mathf.abs(l.x), Mathf.min(e.y - Mathf.abs(l.y), e.z - Mathf.abs(l.z)));
    if (d < 0) return 0;
    if (!(p.blendDistance > 0)) return 1;
    return Mathf.min(d / p.blendDistance, 1);
}

// The direction, probe space, along which `p`'s cube is read for a ray
// from `world` along `dir` (unit, the frame's world): with box projection,
// from the capture point to where the ray leaves the box (the point taken
// to lie inside it); without, the ray's own direction. Not normalised.
export function probeLookup(p: ReflectionProbeDesc, world: Vec3, dir: Vec3): Vec3 {
    const d = p.toLocal.transformVector3(dir);
    if (!p.boxProjection) return d;
    const o = p.toLocal.transformPoint3(world);
    const e = p.extents;
    const tx = exitDistance(o.x, d.x, e.x);
    const ty = exitDistance(o.y, d.y, e.y);
    const tz = exitDistance(o.z, d.z, e.z);
    const t = Mathf.max(Mathf.min(tx, Mathf.min(ty, tz)), 0);
    return o + d * t - p.originOffset;
}

// How far along `d` a ray from `o` leaves the slab -e..e (+Infinity when
// it runs along it).
function exitDistance(o: f32, d: f32, e: f32): f32 {
    if (d > 0) return (e - o) / d;
    if (d < 0) return (-e - o) / d;
    return Infinity;
}

// The lod a material of perceptual `roughness` reads a probe's cube at.
export function probeLod(roughness: f32): f32 {
    return roughness * <f32>(PROBE_LEVELS - 1);
}

// Shared "off" settings for a capture's environment (never changed).
const NO_FOG = new FogDesc();
const NO_GLOW = new GlowDesc();
const NO_SSAO = new SsaoDesc();
const NO_ADJUSTMENT = new AdjustmentDesc();
const NO_SKY = new SkyDesc();

// The environment a capture of `p` is drawn under, from the frame's `e`,
// into `out` (nothing allocated; `out` shares e's sky): `e` with no fog, no
// post-processing and the linear tone map at exposure 1 (a capture holds
// light, the frame that reads it tone maps it); and for an interior probe,
// no sky and no light from the environment: no background (black), no
// image-based light, and a flat ambient light of ambientColor when the
// ambient mode is constant_color, else none, reflecting nothing.
export function captureEnvironmentInto(e: EnvironmentDesc, p: ReflectionProbeDesc, out: EnvironmentDesc): void {
    out.ambient = e.ambient;
    out.sky = e.sky;
    out.ambientFromSky = e.ambientFromSky;
    out.ambientEnergy = e.ambientEnergy;
    out.skyTop = e.skyTop;
    out.skyHorizon = e.skyHorizon;
    out.groundHorizon = e.groundHorizon;
    out.groundBottom = e.groundBottom;
    out.up = e.up;
    out.tonemap = TONEMAP_LINEAR;
    out.exposure = 1;
    out.white = 1;
    out.skyDesc = e.skyDesc;
    out.backgroundEnergy = e.backgroundEnergy;
    out.ambientSkyContribution = e.ambientSkyContribution;
    out.reflectedSource = e.reflectedSource;
    out.fog = NO_FOG;
    out.glow = NO_GLOW;
    out.ssao = NO_SSAO;
    out.adjustment = NO_ADJUSTMENT;
    out.hasPostBackground = false;
    out.postBackground = e.postBackground;
    if (p.interior) {
        out.sky = false;
        out.skyDesc = NO_SKY;
        out.ambientFromSky = false;
        out.ambientEnergy = 1;
        out.ambient = p.ambientMode == PROBE_AMBIENT_CONSTANT_COLOR ? p.ambientColor : Vec3(0, 0, 0);
        out.reflectedSource = REFLECT_DISABLED;
    }
}

// Whether `levels` is a capture as a probe holds one: PROBE_LEVELS levels,
// level m PROBE_FACE_SIZE >> m texels a face (what the renderer uploads,
// and what an .rprobe must hold).
export function isProbeCube(cube: RadianceMap): bool {
    if (<u32>cube.levels.length != PROBE_LEVELS) return false;
    if (radianceLevels(PROBE_FACE_SIZE) != PROBE_LEVELS) return false;
    for (let m = 0; m < cube.levels.length; m++) {
        if (cube.levels[m].size != PROBE_FACE_SIZE >> <u32>m) return false;
    }
    return true;
}
