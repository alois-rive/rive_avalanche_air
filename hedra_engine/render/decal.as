// Decals as a frame carries them (milestone 33; Godot's Decal): a box in
// the frame's world that projects up to four textures along its -Y axis
// onto the surfaces inside it. The renderer draws them forward, as
// Godot's Mobile renderer does, within what WebGL 2 allows (no storage
// buffers; uniform blocks of 16 KB): a frame's visible decals make a pool
// of at most MAX_FRAME_DECALS (the decal block, gpu/layouts.as
// DecalUniform), each item names the pool's entries that reach it, at most
// MAX_OBJECT_DECALS (its ObjectUniform.decals), and the surface shader
// paints them in that order over the material's values before lighting
// (surface.wgsl apply_decals). Their textures live in one atlas, a 2D
// array of DECAL_LAYER_SIZE layers (gpu/decals.as).
//
// A program fills RenderFrame.decals with what does not depend on the
// camera (DecalDesc, below: the scene adapter's ../scene/render/decals.as);
// the renderer chooses the pool and each item's list for the camera it
// draws from (decal_select.as prepareDecals), as cull.as culls, so a frame
// drawn again from another camera needs nothing new. A frame whose `decals`
// is empty (every frame of a scene without a Decal, every shading but lit)
// draws exactly as before.
//
// Godot's semantics: the box is the node's `size` along its axes (its
// scale applied, as Godot's transform is), Godot's decal space (x and z
// from 0 to 1 across the box, y from -1 to 1 bottom to top: DecalDesc
// .toLocal), the vertical fades and normal fade of its scene shader, the
// distance fade (smoothstep) on the CPU, the cull mask against the items'
// layers. Where this differs from Godot (docs/engine/DECALS.md says why):
// an item's decals paint in the scene's order (Godot sorts its clustered
// decals by distance to the camera), a texture is sampled at a level picked
// from the distance to the eye (Godot takes the derivatives), and every
// texture is resampled into a square layer.

import { MAT4_IDENTITY, Mat4, Vec3, Vec4 } from "../base/vecmath";
import { Bounds } from "./camera";

// The most decals a frame draws (the decal block's entries: gpu/layouts.as
// DECAL_UNIFORM_ENTRIES; the decal tests check they agree). Beyond it the
// ones nearest the camera are kept, and the statistics count the rest.
export const MAX_FRAME_DECALS: i32 = 64;
// The most decals one item draws (Godot Mobile's 8 per mesh instance);
// beyond it an item draws the first ones, in the scene's order.
export const MAX_OBJECT_DECALS: i32 = 8;

// The atlas: each texture a decal uses is resampled into one square layer
// of DECAL_LAYER_SIZE texels, with its DECAL_LEVELS levels (512 down to
// 1); at most DECAL_MAX_LAYERS layers (a texture past them is not drawn,
// with a warning).
export const DECAL_LAYER_SIZE: u32 = 512;
export const DECAL_LEVELS: u32 = 10;
export const DECAL_MAX_LAYERS: i32 = 16;

// A decal's texture slots (DecalDesc.textures, DecalEntryUniform.layers):
// Godot's texture_albedo, texture_normal, texture_orm and texture_emission.
export const DECAL_TEXTURE_ALBEDO: i32 = 0;
export const DECAL_TEXTURE_NORMAL: i32 = 1;
export const DECAL_TEXTURE_ORM: i32 = 2;
export const DECAL_TEXTURE_EMISSION: i32 = 3;
export const DECAL_TEXTURES: i32 = 4;

// Whether slot `slot` holds colour (sRGB-encoded: albedo, emission) rather
// than data (normal, orm).
export function decalSlotIsSrgb(slot: i32): bool {
    return slot == DECAL_TEXTURE_ALBEDO || slot == DECAL_TEXTURE_EMISSION;
}

// One decal of a frame, as its program planned it: everything that does
// not depend on the camera. A class filled in place (the scene adapter
// refreshes a frame's decals every frame a scene moves), so it allocates
// nothing once made.
export class DecalDesc {
    // The frame's world to Godot's decal space: x and z from 0 to 1 across
    // the box, y from -1 at its bottom to 1 at its top.
    toLocal: Mat4 = MAT4_IDENTITY;
    // The box's eight corners' bounds in the frame's world (the items it
    // may reach, the frustum test).
    bounds: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    // The node's origin in the frame's world (the distance fade's).
    origin: Vec3 = Vec3(0, 0, 0);
    // The box's unit axes in the frame's world (it projects along -axisY;
    // the normal map's x, y and z go along axisX, -axisZ and axisY: Godot's
    // decal_normal.xzy with its green flipped).
    axisX: Vec3 = Vec3(1, 0, 0);
    axisY: Vec3 = Vec3(0, 1, 0);
    axisZ: Vec3 = Vec3(0, 0, 1);
    // The box's size in the frame's world, the node's scale applied
    // (metres along axisX, axisY, axisZ).
    size: Vec3 = Vec3(2, 2, 2);
    // Linear rgb, straight alpha.
    modulate: Vec4 = Vec4(1, 1, 1, 1);
    emissionEnergy: f32 = 1;
    albedoMix: f32 = 1;
    normalFade: f32 = 0;
    upperFade: f32 = 0.3;
    lowerFade: f32 = 0.3;
    distanceFade: bool = false;
    fadeBegin: f32 = 40;
    fadeLength: f32 = 10;
    // The layers it paints (DrawItem.layers).
    cullMask: u32 = 1048575;
    // By DECAL_TEXTURE_*: the texture's path as the material binder reads
    // it (as MaterialDesc.textures: a file, or an ArtboardTexture's
    // `<declaring file>#artboard:<key>`, its image registered with the
    // frame's texture files), or null for none.
    textures: Array<string?> = [null, null, null, null];
    // The node's path, for warnings and the statistics (not drawn).
    label: string = "";
    // Whether the box has collapsed: a scale of 0 on an axis (the node's
    // or a parent's, as a timeline popping a decal in from nothing keys
    // it), or a transform that cannot be inverted. Its toLocal is then not
    // a number (an inverse of a singular matrix), which would paint every
    // pixel its bounds reach as NaN, black; it paints nothing, as Godot's
    // empty box does (prepareDecals leaves it out of the pool).
    empty: bool = false;
    // Milestone 34 (viewport.as): the world it paints in (its node's, as
    // DrawItem.scenario: a decal paints only the items of its own world),
    // and the viewports whose textures its slots show (ViewportDesc.bit
    // each). 0 and 0 in every scene without a SubViewport.
    scenario: i32 = 0;
    viewports: u32 = 0;
}

// What prepareDecals chose for one camera (decal_select.as), kept by the
// renderer from frame to frame: the pool, each entry's distance fade, and
// the counts the statistics give.
export class DecalPlan {
    // Indices into RenderFrame.decals, in the scene's order (the order an
    // item paints them), the first `count` of MAX_FRAME_DECALS.
    pool: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_DECALS);
    // By pool entry: the distance fade, 0 to 1 (1 without one).
    fade: StaticArray<f32> = new StaticArray<f32>(MAX_FRAME_DECALS);
    count: i32 = 0;
    // The frame's decals in the view (in the frustum, not faded out), and
    // those of them left out of the pool (beyond MAX_FRAME_DECALS).
    visible: i32 = 0;
    dropped: i32 = 0;
    // The items that draw at least one decal, and those that more than
    // MAX_OBJECT_DECALS reach (they draw the first ones).
    items: i32 = 0;
    overBudget: i32 = 0;
    // prepareDecals' scratch, kept from frame to frame (their storage is
    // reused: a warm frame allocates nothing): the candidates' indices
    // into RenderFrame.decals, their distances to the eye and their fades,
    // and the nearest MAX_FRAME_DECALS of them when there are more.
    candidates: Array<i32> = [];
    distances: Array<f32> = [];
    fades: Array<f32> = [];
    nearest: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_DECALS);
    // By pool entry: its box (min x, y, z, max x, y, z) and its cull mask,
    // flat, so that matching the items reads no struct.
    boxes: StaticArray<f32> = new StaticArray<f32>(MAX_FRAME_DECALS * 6);
    masks: StaticArray<u32> = new StaticArray<u32>(MAX_FRAME_DECALS);

    reset(): void {
        this.count = 0;
        this.visible = 0;
        this.dropped = 0;
        this.items = 0;
        this.overBudget = 0;
    }
}
