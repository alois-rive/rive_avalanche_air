// GPU layouts and constants: the GPU
// vertex / instance / uniform layouts (byte for byte what the WGSL reads),
// the element and texture flag bits, and the pure pieces of pipeline state
// (vertex attribute tables, depth state). Creating the pipelines themselves
// is `engine/src/render/gpu/pipelines.as`.
//
// Every small block here is a rasc value `struct` (plain data, copied on
// assignment; the big ones are classes, see Globals) and packs into an `ArrayBuffer` through a little-endian
// `DataView` (fields in declaration order, no padding: every field is 4-byte
// aligned, so the WGSL layouts have none either).

import { Vec2, Vec3, Vec4, Mat4, MAT4_IDENTITY, VEC4_ZERO } from "../../base/vecmath";
import { TextureFormat, VertexFormat, CompareFunction } from "rive/gpu_enums";

// The Rive GPU API has no sRGB color formats, so the main pass renders into
// `rgba16float` (linear blending and resolve, sRGB-encoded in a post pass)
// and falls back to `rgba8unorm` when the device lacks
// `colorBufferHalfFloat`.
export const COLOR_FORMAT: TextureFormat = TextureFormat.rgba16float;
export const COLOR_FORMAT_FALLBACK: TextureFormat = TextureFormat.rgba8unorm;
export const DEPTH_FORMAT: TextureFormat = TextureFormat.depth32float;
// There is no R32Uint target, so the object id is packed into an rgba8unorm
// target (24-bit index in rgb, selected/active bits in a).
export const ID_FORMAT: TextureFormat = TextureFormat.rgba8unorm;
// The id-depth format. Label occlusion uses a CPU ray cast
// (engine/src/render/raycast.as), so no pass needs it; kept for reference.
export const ID_DEPTH_FORMAT: TextureFormat = TextureFormat.r32float;
export const MSAA_SAMPLES: u32 = 4;

// Element flags (must match common.wgsl).
export const F_SELECTED: u32 = 1;
export const F_HIDDEN: u32 = 2;
export const F_SEAM: u32 = 4;
export const F_SHARP: u32 = 8;
export const F_MESH: u32 = 16;
export const F_FADE: u32 = 32;
export const F_NO_PULL: u32 = 64;

export const OV_SELECTION: u32 = 1;
export const OV_SEAMS: u32 = 2;
export const OV_SHARP: u32 = 4;

// The object carries the vertex group `--shading weights:<group>` shows;
// objects without it fall back to solid shading.
export const OBJ_HAS_WEIGHTS: u32 = 1;

// The object's world matrix mirrors (a negative determinant), which
// reverses its triangles' winding: the shaders then take the back of a
// triangle for its front (Hedra's mirrored nodes; Hedra never sets it).
export const OBJ_MIRRORED: u32 = 2;

// Milestone 19 (baked lighting). Outside the common block in the WGSL (the
// lines module never reads them), and set only for a frame with a bake
// (frame.as frameObjects), so every other item's bits are what they were.
//
// The item is lightmapped: ObjectUniform.extra.y is its layer of the
// frame's lightmap (group 0, binding 11), and the lightmap pipelines draw
// its diffuse light from it instead of from the ambient light and the
// lights whose LightUniform.info.z is LIGHT_BAKED_STATIC.
export const OBJ_LIGHTMAP: u32 = 4;
// The item takes its diffuse ambient light from the baked probes:
// ObjectUniform.gi holds their L1 SH at the item (shared/src/render/
// lightmap/sh.as; surface.wgsl `probe_light`).
export const OBJ_PROBE_GI: u32 = 8;

// Milestone 48 (GPU skinning; frame.as DrawItem.skin). Outside the common
// block in the WGSL too, and set only for a skinned item, so every other
// item's bits are what they were. The item is drawn with the skinned vertex
// entries (surface.wgsl's skinning block): its mesh as stored, each vertex
// moved by its four palette matrices (group 1, binding 1), its world the
// identity.
export const OBJ_SKINNED: u32 = 16;

// Hedra's emerge (frame.as DrawItem.emerge; not Godot's). Outside the common
// block in the WGSL too, and set only for an item still emerging, so every
// other item's bits are what they were: ObjectUniform.normal.xAxis.w (the
// normal matrix's fourth row, which the shader never reads: a normal moved
// through it keeps only xyz) holds how far it has emerged (0 to 1) and
// extra.w the fog's colour (sRGB bytes, red low), and surface.wgsl's
// `emerge_reveal` cuts and tints it. (decals.w is milestone 37's: the
// item's fog volumes.)
export const OBJ_EMERGE: u32 = 32;

// Hedra's fade (frame.as DrawItem.fade and fadeColor; not Godot's). Set
// only for a fading item, so every other item's bits are what they were:
// the fourth column of ObjectUniform.normal (which moves normals with a w
// of 0, so the shader never reads that column otherwise) holds the fade
// colour, linear, in xyz and how far in w, and surface.wgsl's `item_fade`
// draws the lit colour that far toward that colour, tone mapped.
export const OBJ_FADE: u32 = 64;

// Milestone 13: surface.wgsl's VsOut.flags bit an instanced draw sets for an
// instance whose transform mirrors (a negative determinant). The shader's
// "front" tests read it xor OBJ_MIRRORED. Outside the common block (the
// lines module never sees it), and above every element flag a mesh vertex
// carries (F_* stop at F_NO_PULL), so no vertex sets it by accident.
export const F_INSTANCE_MIRRORED: u32 = 128;

// Sentinel weight for vertices outside the shown group (Blender's "zero
// weights: active" black).
export const WEIGHT_NONE: f32 = -1.0;

// Texture presence bits in `MaterialUniform.flags.x` (must match surface.wgsl).
export const T_BASE: u32 = 1;
export const T_NORMAL: u32 = 2;
export const T_METALLIC_ROUGHNESS: u32 = 4;
export const T_EMISSION: u32 = 8;
export const T_OCCLUSION: u32 = 16;
// Milestone 13: `MaterialUniform.flags.w` bits (surface.wgsl's MAT_*): the
// base colour is multiplied by the vertex colour (a MultiMesh instance's;
// white for every other draw), which is sRGB and made linear first with
// MAT_VERTEX_COLOR_SRGB (Godot's vertex_color_use_as_albedo and
// vertex_color_is_srgb). 0 for every material before, whose pictures do not
// change.
export const MAT_VERTEX_COLOR: u32 = 1;
export const MAT_VERTEX_COLOR_SRGB: u32 = 2;
// Milestone 14, part 2 (glTF's whole material; docs/engine/SHADING.md):
// the material uses something today's shading does not draw (an
// extension, a texture transform or UV set 1, a normal scale or occlusion
// strength other than 1, metallic and roughness from different images), so
// the renderer draws it with the extended pipelines (surface.wgsl's
// `*_ext` entries), which read the rest of MaterialU. Clear, the material
// is drawn by exactly the code it was drawn by before, so every picture
// without such a material is byte for byte what it was.
export const MAT_EXT: u32 = 4;
// With MAT_EXT: KHR_materials_unlit (Godot's shading_mode unshaded).
export const MAT_UNLIT: u32 = 8;
// With MAT_EXT: roughness is read from its own layer of the extension
// array (its slot's MaterialExtUniform layer), not from t_mr's green.
export const MAT_ROUGHNESS_LAYER: u32 = 16;
// Milestone 26: the base colour (MAT_SRGB_BASE) or emission
// (MAT_SRGB_EMISSION) texture was uploaded as a block-compressed format
// (BC, ETC2, ASTC, or an imported rgba8 form), which the pinned runtime has
// no sRGB variant of: it is sampled as stored and surface.wgsl decodes the
// sRGB curve after sampling. Clear for a texture uploaded from its source,
// which is decoded before upload (rgba16float), as before.
export const MAT_SRGB_BASE: u32 = 32;
export const MAT_SRGB_EMISSION: u32 = 64;
// Number of texture bindings in the material group, in texture-slot order.
export const MATERIAL_TEXTURES: u32 = 5;

// Byte size of each layout.
export const GLOBALS_SIZE: u32 = 320;
// Milestone 19: 224 (176 before: `gi`, the probe light, appended).
// Milestone 33: 240 (`decals`, the item's decal list, appended). Milestone
// 59: 256 (`lights`, the item's light list, appended). The renderer's
// stride is 256 either way (gpu/renderer.as computeObjectStride).
export const OBJECT_UNIFORM_SIZE: u32 = 256;
export const SURFACE_VERTEX_SIZE: u32 = 56;
// The material block (surface.wgsl's MaterialU): MATERIAL_BASE_SIZE bytes
// read by every pipeline, then the extended path's MATERIAL_EXT_SIZE (each
// texture slot's transform, then the extensions' factors).
export const MATERIAL_UNIFORM_SIZE: u32 = 848;
export const MATERIAL_BASE_SIZE: u32 = 80;
export const MATERIAL_EXT_SIZE: u32 = 768;
// The texture slots the extended block has a transform for (glTF's 20:
// engine/src/material/pbr.as PbrSlot), and the factor vectors after them.
export const MATERIAL_EXT_SLOTS: i32 = 20;
export const MATERIAL_EXT_FACTORS: i32 = 8;
// The surface vertex's second texture coordinate (UV set 1) of the
// extended pipelines: one float2 per vertex in a vertex buffer of its own
// (UV1_ATTRS), so the surface vertex keeps its 56 bytes.
export const UV1_STRIDE: u32 = 8;
// Milestone 19: a lightmapped mesh's lightmap coordinates (GpuMesh
// .lightmapUv), one float2 per vertex in a vertex buffer of their own
// (LM_UV_ATTRS), read only by the lightmap pipelines.
export const LM_UV_STRIDE: u32 = 8;
// Milestone 48: a skinned mesh's palette slots and weights (GpuMesh
// .skinJoints, .skinWeights), SKIN_STRIDE bytes a vertex in a vertex buffer
// of their own (SKIN_ATTRS: the four slots as one u32, a byte each, then
// four f32 weights), read only by the skinned pipelines.
export const SKIN_STRIDE: u32 = 20;
// The palette (surface.wgsl's SkinU at group 1, binding 1): per joint the
// three rows of a 3 x 4 matrix (frame.as SKIN_FLOATS_PER_JOINT numbers),
// SKIN_UNIFORM_JOINTS of them. A uniform, as the Rive GPU API has no storage
// buffers, and 12,240 bytes, within the 16,384 bytes a uniform buffer may be
// on any device (GPUFeatures.maxUniformBufferSize's floor). The number of
// joints is Hedra's MAX_SKIN_JOINTS (a slot is one byte).
export const SKIN_UNIFORM_JOINTS: i32 = 255;
export const SKIN_JOINT_UNIFORM_SIZE: u32 = 48;
export const SKIN_UNIFORM_SIZE: u32 = 12240;
// The palette's binding in group 1, beside the object block (binding 0).
export const SKIN_BINDING: u32 = 1;
export const LINE_INSTANCE_SIZE: u32 = 48;
export const POINT_INSTANCE_SIZE: u32 = 48;
// The lit mode's block at group 0, binding 1 (surface.wgsl's LitU), and one
// light of it (LightU). Milestone 59: a header of LIT_HEADER_SIZE bytes (the
// 192 of before, then the pool's directional lights, LitUniform.dirs), then
// the frame's pool of LIT_UNIFORM_LIGHTS lights (light_pool.as
// MAX_FRAME_LIGHTS; the light tests check they agree, this file importing
// nothing of the renderer's): 208 + 64 x 80 = 5,328 bytes, a third of the
// 16 KB a WebGL 2 uniform block may hold. Each item names up to 8 of them
// (ObjectUniform.lights). The renderer uploads only the header and the
// pool's `count` lights (LitUniform.writeUsedAt): no item names a light
// past them.
export const LIGHT_UNIFORM_SIZE: u32 = 80;
export const LIT_HEADER_SIZE: u32 = 208;
export const LIT_UNIFORM_LIGHTS: i32 = 64;
export const LIT_UNIFORM_SIZE: u32 = 5328;
// LitUniform.counts.y bits (surface.wgsl's ENV_*): draw the sky gradient,
// and take the ambient light from it.
export const ENV_SKY: u32 = 1;
export const ENV_AMBIENT_SKY: u32 = 2;
// Milestone 12: lit() reads the screen-space ambient occlusion (group 0,
// binding 10) at its pixel; LitUniform.tone.z is ssao_light_affect and .w
// ssao_ao_channel_affect then (the direct light is darkened by their
// product, Godot 4.4's rule).
export const ENV_SSAO: u32 = 4;
// Milestone 12: lit() and the sky write their HDR colour unclamped (the
// lit block's tone map is then linear at exposure 1), for the glow to
// threshold and the post pass to tone map: surface.wgsl `lit_output`. Set
// by gpu/renderer.as for a frame whose post plan has `toneInPost`.
export const ENV_HDR: u32 = 8;
// Milestone 62 (../screen.as): the extended materials that refract
// (material.as materialRefracts) sample the screen texture (the object
// group's SCREEN_BINDING) instead of the environment; LitUniform.dirs.w is
// then the texture's mip count (0 otherwise, as the bit is). Set by
// gpu/renderer.as for a frame whose post plan has `refraction` and whose
// main pass is drawn in two (PostPlan.split), so that the texture holds
// the opaque picture by the time the glass is drawn.
export const ENV_SCREEN_REFRACTION: u32 = 16;

// Shadows (milestone 10). One depth32float atlas holds every shadow map of
// a view: SHADOW_ATLAS_SIZE square (smaller on a device that cannot hold
// it: shadow.as `shadowAtlasSize`), cut into SHADOW_ATLAS_GRID x
// SHADOW_ATLAS_GRID tiles of the same size. A directional light takes one
// tile per cascade (1, 2 or 4), a spot light one, an omni light six (a cube
// map's faces, +X -X +Y -Y +Z -Z of the frame's world space); a light that
// finds too few tiles left is drawn without its shadow, with a warning.
export const SHADOW_ATLAS_SIZE: u32 = 4096;
export const SHADOW_ATLAS_GRID: u32 = 4;
export const SHADOW_TILES: i32 = 16;
export const SHADOW_ATLAS_FORMAT: TextureFormat = TextureFormat.depth32float;
// The shadow block at group 0, binding 2 (surface.wgsl's ShadowU): a
// 16-byte header, one ShadowLightU per shadow slot (milestone 59: a
// shadowed light's LightUniform.info.w; SHADOW_UNIFORM_LIGHTS of them,
// light_pool.as MAX_SHADOW_LIGHTS: every shadowed light takes at least one
// of the SHADOW_TILES tiles), one ShadowTileU per atlas tile: 16 + 16 x 64
// + 16 x 96 = 2,576 bytes.
export const SHADOW_LIGHT_UNIFORM_SIZE: u32 = 64;
export const SHADOW_TILE_UNIFORM_SIZE: u32 = 96;
export const SHADOW_UNIFORM_LIGHTS: i32 = 16;
export const SHADOW_UNIFORM_SIZE: u32 = 2576;
// LightUniform.info.y: this light samples its shadow
// (ShadowU.lights[info.w]).
export const LIGHT_SHADOWED: u32 = 1;
// Milestone 19, LightUniform.info.z: the light's direct light is baked
// (frame.as LIGHT_BAKE_STATIC), so a lightmapped surface skips it; every
// other surface draws it in real time as before.
export const LIGHT_BAKED_STATIC: u32 = 1;

// The sky, image-based light and fog (milestone 11; sky.as `skyUniform`
// packs the block, surface.wgsl's SkyU at group 0, binding 5). A frame
// whose flags are 0 (no Sky resource, no fog: every frame before this
// milestone) reads none of it and draws as before.
//
// SkyUniform.flags.x bits (surface.wgsl's SKY_*):
// fs_sky draws the ProceduralSkyMaterial from the block;
export const SKY_DRAW_PROCEDURAL: u32 = 1;
// fs_sky draws the panorama (binding 7);
export const SKY_DRAW_PANORAMA: u32 = 2;
// the panorama is sampled bilinearly (else by nearest texel);
export const SKY_PANORAMA_FILTER: u32 = 4;
// the environment has a Sky: lit() takes its ambient light from the block
// (irradiance, radiance, flat) instead of milestone 4's code;
export const SKY_IBL: u32 = 8;
// with SKY_IBL, the diffuse ambient mixes towards the sky's irradiance;
export const SKY_AMBIENT_SKY: u32 = 16;
// with SKY_IBL, reflections sample the radiance map (binding 6)...
export const SKY_REFLECT_RADIANCE: u32 = 32;
// ...or there are none (neither bit: the flat ambient colour);
export const SKY_REFLECT_OFF: u32 = 64;
// fog in lit() and fs_sky, exponential or (with SKY_FOG_DEPTH) depth.
export const SKY_FOG: u32 = 128;
export const SKY_FOG_DEPTH: u32 = 256;
// The directional lights a procedural sky draws a sun for (Godot's
// LIGHT0..LIGHT3), and the irradiance's spherical harmonics (bands 0 to 2).
export const SKY_SUNS: i32 = 4;
export const SKY_SH_COEFFS: i32 = 9;
export const SKY_SUN_UNIFORM_SIZE: u32 = 32;
export const SKY_UNIFORM_SIZE: u32 = 528;
// The reflection map (a cube, `levels` mips of prefiltered radiance) and
// the panorama are rgba16float: rive has no rgb9e5 or float32 filtering
// guarantee, and half floats hold a sky's range (values above 65504, a sun
// in some HDRIs, are clamped to it on upload).
export const RADIANCE_FORMAT: TextureFormat = TextureFormat.rgba16float;
export const PANORAMA_FORMAT: TextureFormat = TextureFormat.rgba16float;

// Post-processing (milestone 12; post.as plans it and builds the blocks,
// shaders/render/post_effects.wgsl draws it). Every pass is a full-screen
// triangle of the post module, whose group 0 is one PostU block (binding
// 0), two source textures (1 `t_src`, 2 `t_aux`), the glow levels as the
// mips of one texture (3 `t_glow`: a group of the host holds at most 8
// sampled textures, so seven separate levels would not fit) and a linear
// clamp sampler (4); a pass binds 1 x 1 dummies where it reads nothing. A
// frame that plans no pass runs none and draws as before.
//
// PostUniform.flags.x bits (post_effects.wgsl's POST_*): fs_post exposes and
// tone maps (the main pass kept HDR colour because glow is on), adds the
// glow, applies the adjustments, then lays the overlay layer (t_aux: grid,
// edges, points and gizmos, drawn in their own pass) over the result;
// fs_glow_blur_h reads a level twice its size (every level after the
// first).
export const POST_TONEMAP: u32 = 1;
export const POST_GLOW: u32 = 2;
export const POST_ADJUST: u32 = 4;
export const POST_DOWNSAMPLE: u32 = 8;
export const POST_OVERLAY: u32 = 16;
// A transparent background: fs_post divides the resolve's premultiplied
// colour by alpha before anything else (the picture is straight alpha).
export const POST_STRAIGHT: u32 = 32;
// Milestone 67 (../quality.as ssaoHalfSize): fs_ssao traces at half the
// render size each side, and fs_ssao_blur blurs that occlusion back up to
// the render size along the surfaces (the passes' targets are then half
// and full; target_size stays the render size, the space both work in).
export const POST_SSAO_HALF: u32 = 64;
export const POST_UNIFORM_SIZE: u32 = 288;
// The view-space normal (rgb) and view depth (a; 0 where nothing is drawn)
// SSAO reads, drawn by the normal-depth pass at the render size.
export const NORMAL_DEPTH_FORMAT: TextureFormat = TextureFormat.rgba16float;
// The occlusion (r; 1 unoccluded), before and after its blur.
export const AO_FORMAT: TextureFormat = TextureFormat.rgba8unorm;
// The glow's bright pass and levels: HDR.
export const GLOW_FORMAT: TextureFormat = TextureFormat.rgba16float;
// Milestone 62 (../screen.as): the normal-depth pass's second target, the
// surface's F0 (rgb, linear) and perceptual roughness (a), cleared to
// (0, 0, 0, 1) (roughness 1: no reflection) where nothing is drawn; the
// screen texture (the opaque picture's copy, HDR, SCREEN_LEVELS_MAX mips at
// most); the reflections' target (rgb the reflection times its weights, a
// the weight the colour below loses: premultiplied over); the depth of
// field's half-size colour with its circle of confusion in a, its gather,
// and its composition at the render size (HDR, which glow and the final
// pass read).
export const SSR_SURFACE_FORMAT: TextureFormat = TextureFormat.rgba8unorm;
export const SCREEN_FORMAT: TextureFormat = TextureFormat.rgba16float;
export const SSR_FORMAT: TextureFormat = TextureFormat.rgba16float;
export const DOF_FORMAT: TextureFormat = TextureFormat.rgba16float;

// Reflection probes (milestone 20; engine/src/render/probe/data.as says how
// a frame reads them, gpu/probes.as fills the block and the atlas). The
// surface module's group 0 holds the probe block at binding 13
// (surface.wgsl's ProbeU: a 16-byte header and PROBE_UNIFORM_ENTRIES
// entries of ProbeEntryU), the atlas at 14 and its sampler at 15. A frame
// without probes writes a block of zeros (count 0), which the shader reads
// nothing past, and binds a 1 x 1 dummy atlas, so it draws as before.
export const PROBE_UNIFORM_SIZE: u32 = 1040;
export const PROBE_ENTRY_UNIFORM_SIZE: u32 = 128;
// The entries of the block: probe/data.as MAX_PROBES (the probe GPU test
// checks they agree; layouts.as imports nothing of the renderer's).
export const PROBE_UNIFORM_ENTRIES: i32 = 8;
// ProbeEntryUniform.info.x bits (surface.wgsl's PROBE_*): box-projected
// lookups, and an interior probe (its capture sees no sky).
export const PROBE_BOX: u32 = 1;
export const PROBE_INTERIOR: u32 = 2;
// The atlas every probe's cube lives in (6 faces across, a row per probe,
// a mip per level) and the live capture's passes draw: HDR.
export const PROBE_ATLAS_FORMAT: TextureFormat = TextureFormat.rgba16float;
// The live capture's prefilter block (probe.wgsl's FilterU, one per level
// filtered): a 16-byte header and two vec4s per GGX sample.
export const PROBE_FILTER_UNIFORM_SIZE: u32 = 1040;
export const PROBE_FILTER_SAMPLES: i32 = 32;

// Decals (milestone 33; engine/src/render/decal.as says how a frame
// carries them, render/decal_select.as which ones each item draws,
// gpu/decals.as fills the block and the atlas). Forward decals in Godot
// Mobile's way, within WebGL 2: the surface module's object group (group
// 1: groups 0, 2 and 3 have no binding left under 8, the bind slots every
// target takes) holds the decal block at binding 2 (surface.wgsl's
// DecalU: a 32-byte header and DECAL_UNIFORM_ENTRIES entries of
// DecalEntryU, the frame's pool), the atlas at 3 (a texture_2d_array, one
// layer a texture) and its sampler at 4; each item names up to
// MAX_OBJECT_DECALS entries of the pool in its ObjectUniform.decals. A frame without decals writes a
// block of zeros (count 0) and binds a 1 x 1 x 1 dummy atlas, and every
// item's list is empty, so it draws as before.
export const DECAL_UNIFORM_SIZE: u32 = 11296;
export const DECAL_ENTRY_UNIFORM_SIZE: u32 = 176;
// The entries of the block: render/decal.as MAX_FRAME_DECALS (the decal
// tests check they agree; layouts.as imports nothing of the renderer's).
export const DECAL_UNIFORM_ENTRIES: i32 = 64;
// Their bindings in the object group (surface.wgsl's Decal, t_decals and
// s_decals).
export const DECAL_BLOCK_BINDING: u32 = 2;
export const DECAL_ATLAS_BINDING: u32 = 3;
export const DECAL_SAMPLER_BINDING: u32 = 4;
// DecalEntryUniform.flags.x bits (surface.wgsl's DECAL_LIVE_*): that
// texture's layer is a live artboard's, drawn each frame into its level 0
// alone, so it is sampled at level 0.
export const DECAL_LIVE_ALBEDO: u32 = 1;
export const DECAL_LIVE_NORMAL: u32 = 2;
export const DECAL_LIVE_ORM: u32 = 4;
export const DECAL_LIVE_EMISSION: u32 = 8;
// The atlas: 8-bit, the colour layers (albedo, emission) holding
// sRGB-encoded colour, which the shader decodes (rive has no sRGB
// formats), the data layers (normal, orm) their values as they are.
export const DECAL_ATLAS_FORMAT: TextureFormat = TextureFormat.rgba8unorm;

// Fog volumes (milestone 37; engine/src/render/fog_volume.as says how a
// frame carries them and how a pixel integrates them, render/fog_select.as
// which ones each view and item draws, gpu/fog.as fills the block). The
// fog block is the object group's binding 5 (surface.wgsl's FogU: group 1,
// like the decals', the other groups having no binding left under 8): a
// FOG_HEADER_SIZE-byte header (counts, the phase, ambient inject, sky
// affect and length, the isotropic ambient light, the frame's up, then
// each Lit pool light's light_volumetric_fog_energy, four a vec4: 64 +
// 16 x 16 = 320 bytes) and FOG_UNIFORM_ENTRIES entries of
// FOG_ENTRY_UNIFORM_SIZE bytes (FogEntryU), the view's pool: 320 + 16 x 144
// = 2,624 bytes. Each item names up to 4 entries in ObjectUniform.decals.w.
// The energies come before the entries so that what the renderer uploads
// is one run from byte 0 (FogUniform.writeUsedAt: the header and the
// pool's entries). A frame without volumetric fog writes a header of
// zeros once and every item's word is 0, so it draws as before.
export const FOG_UNIFORM_SIZE: u32 = 2624;
export const FOG_HEADER_SIZE: u32 = 320;
export const FOG_ENTRY_UNIFORM_SIZE: u32 = 144;
// The entries of the block: render/fog_volume.as MAX_FRAME_FOG_VOLUMES
// (the fog tests check they agree; layouts.as imports nothing of the
// renderer's), and the light energies it holds (LIT_UNIFORM_LIGHTS).
export const FOG_UNIFORM_ENTRIES: i32 = 16;
// Its binding in the object group (surface.wgsl's Fog).
export const FOG_BLOCK_BINDING: u32 = 5;
// Milestone 62: the screen texture, the opaque picture's copy with its
// mips (SCREEN_FORMAT), at the object group's binding 6 (groups 0 and 3
// hold eight bindings each: surface.wgsl's `shared: screen` region), read
// behind ENV_SCREEN_REFRACTION alone; every object group binds the view's,
// or a 1 x 1 dummy in a view without one (gpu/renderer.as objectGroupWith).
export const SCREEN_BINDING: u32 = 6;

// ---------------------------------------------------------------- raw stores

// Little-endian stores into a DataView over the destination buffer.
function putF32(base: DataView, off: u32, v: f32): void { base.setFloat32(<i32>off, v, true); }
function putU32(base: DataView, off: u32, v: u32): void { base.setUint32(<i32>off, v, true); }
function putVec2(base: DataView, off: u32, v: Vec2): void { putF32(base, off, v.x); putF32(base, off + 4, v.y); }
function putVec3(base: DataView, off: u32, v: Vec3): void {
    putF32(base, off, v.x);
    putF32(base, off + 4, v.y);
    putF32(base, off + 8, v.z);
}
function putVec4(base: DataView, off: u32, v: Vec4): void {
    putF32(base, off, v.x);
    putF32(base, off + 4, v.y);
    putF32(base, off + 8, v.z);
    putF32(base, off + 12, v.w);
}
// `m.to_cols_array_2d()`: column-major, x axis first.
function putMat4(base: DataView, off: u32, m: Mat4): void {
    putVec4(base, off, m.xAxis);
    putVec4(base, off + 16, m.yAxis);
    putVec4(base, off + 32, m.zAxis);
    putVec4(base, off + 48, m.wAxis);
}

// Four u32s (a WGSL `vec4<u32>`).
export struct U32x4 {
    x: u32 = 0;
    y: u32 = 0;
    z: u32 = 0;
    w: u32 = 0;

    constructor(x: u32, y: u32, z: u32, w: u32) {
        this.x = x;
        this.y = y;
        this.z = z;
        this.w = w;
    }

    operator==(a: U32x4, b: U32x4): bool { return a.x == b.x && a.y == b.y && a.z == b.z && a.w == b.w; }
    readonly hash(): u32 { return this.x * 73856093 ^ this.y * 19349663 ^ this.z * 83492791 ^ this.w * 2654435761; }
    readonly get(i: i32): u32 {
        if (i == 0) return this.x;
        if (i == 1) return this.y;
        if (i == 2) return this.z;
        return this.w;
    }
    // Debug text: "[x, y, z, w]".
    readonly debug(): string { return `[${this.x}, ${this.y}, ${this.z}, ${this.w}]`; }
}

function putU32x4(base: DataView, off: u32, v: U32x4): void {
    putU32(base, off, v.x);
    putU32(base, off + 4, v.y);
    putU32(base, off + 8, v.z);
    putU32(base, off + 12, v.w);
}

// ---------------------------------------------------------------- uniforms

// Group 0 (320 bytes). A class rather than a value struct, like the
// blocks below it: flattened, its 80 floats and words would be a wasm
// function's parameters or results wherever one passes or returns it (and
// its own methods' `this`), past the 64 cells WAMR's ahead-of-time compiler
// takes (`rive game --aot`), which then leaves the whole module
// interpreted. It is filled in place instead (frame.as `frameGlobalsInto`,
// renderer.as `tileGlobalsInto`), in an instance its owner keeps (the
// renderer one per kind), so writing a frame's blocks still allocates
// nothing.
export class Globals {
    view: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
    proj: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
    viewProj: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
    cameraPos: Vec4 = Vec4(0, 0, 0, 0);
    viewport: Vec4 = Vec4(0, 0, 0, 0);
    wireColor: Vec4 = Vec4(0, 0, 0, 0);
    selectColor: Vec4 = Vec4(0, 0, 0, 0);
    activeColor: Vec4 = Vec4(0, 0, 0, 0);
    grid: Vec4 = Vec4(0, 0, 0, 0);
    params: U32x4 = U32x4(0, 0, 0, 0);
    fparams: Vec4 = Vec4(0, 0, 0, 0);

    // Every field of `g`, and returns this.
    copyFrom(g: Globals): Globals {
        this.view = g.view;
        this.proj = g.proj;
        this.viewProj = g.viewProj;
        this.cameraPos = g.cameraPos;
        this.viewport = g.viewport;
        this.wireColor = g.wireColor;
        this.selectColor = g.selectColor;
        this.activeColor = g.activeColor;
        this.grid = g.grid;
        this.params = g.params;
        this.fparams = g.fparams;
        return this;
    }

    // Writes the 320 bytes at byte `off` of `base`.
    writeAt(base: DataView, off: u32): void {
        putMat4(base, off, this.view);
        putMat4(base, off + 64, this.proj);
        putMat4(base, off + 128, this.viewProj);
        putVec4(base, off + 192, this.cameraPos);
        putVec4(base, off + 208, this.viewport);
        putVec4(base, off + 224, this.wireColor);
        putVec4(base, off + 240, this.selectColor);
        putVec4(base, off + 256, this.activeColor);
        putVec4(base, off + 272, this.grid);
        putU32x4(base, off + 288, this.params);
        putVec4(base, off + 304, this.fparams);
    }

    // The uniform buffer bytes.
    toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>GLOBALS_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// Group 1, one per object at a dynamic offset (OBJECT_UNIFORM_SIZE bytes).
// A class for Globals' reason (64 cells by value, and 66 with writeAt's
// arguments): frame.as `itemUniformInto` fills one in place, and the
// renderer writes every object of a frame through the one it keeps
// (frame.as `writeFrameObjects`).
export class ObjectUniform {
    model: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
    normal: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
    color: Vec4 = Vec4(0, 0, 0, 0);
    params: U32x4 = U32x4(0, 0, 0, 0);
    // `OBJ_*` bits, the lightmap layer (with OBJ_LIGHTMAP), the item's
    // layers in a frame with reflection probes (milestone 20), the colour
    // an emerging item's fog has (with OBJ_EMERGE: sRGB bytes, red low).
    // (With OBJ_EMERGE, normal.xAxis.w holds how far it has emerged; with
    // OBJ_FADE, the normal matrix's fourth column holds the fade: OBJ_EMERGE
    // and OBJ_FADE above.)
    extra: U32x4 = U32x4(0, 0, 0, 0);
    // Milestone 19, surface.wgsl's `gi: array<vec4<f32>, 3>`: the probe
    // light's L1 SH (with OBJ_PROBE_GI), red, green, blue, each c0 then c1
    // (engine/src/render/lightmap/sh.as's order). Three fields rather than
    // an array, so filling a uniform in place never allocates; zeros for
    // every item without probe light.
    gi0: Vec4 = Vec4(0, 0, 0, 0);
    gi1: Vec4 = Vec4(0, 0, 0, 0);
    gi2: Vec4 = Vec4(0, 0, 0, 0);
    // Milestone 33, surface.wgsl's `decals`: the item's decals, indices
    // into the frame's pool (DecalUniform's entries), a byte each, in the
    // order they paint: x holds the first four (the first in its low
    // byte), y the next four; z how many (at most MAX_OBJECT_DECALS); w
    // (milestone 37) the item's fog volumes (render/fog_select.as; the fog
    // block above: 0 without volumetric fog). Zeros for every item without
    // one.
    decals: U32x4 = U32x4(0, 0, 0, 0);
    // Milestone 59, surface.wgsl's `lights`: the item's lights, entries of
    // the frame's pool (LitUniform's lights), a byte each, in pool order: x
    // holds the first four (the first in its low byte), y the next four; z
    // how many (at most MAX_OBJECT_LIGHTS); w how many reach the item in
    // all, past the 8 too (the lights shading's colour). Zeros for every
    // item no renderer chose lights for.
    lights: U32x4 = U32x4(0, 0, 0, 0);

    // The world's slot (slot 0, for the grid, cursor and origins): the
    // identity, white, every word zero. Returns this.
    setWorld(): ObjectUniform {
        this.model = MAT4_IDENTITY;
        this.normal = MAT4_IDENTITY;
        this.color = Vec4(1, 1, 1, 1);
        this.params = U32x4(0, 0, 0, 0);
        this.extra = U32x4(0, 0, 0, 0);
        this.gi0 = VEC4_ZERO;
        this.gi1 = VEC4_ZERO;
        this.gi2 = VEC4_ZERO;
        this.decals = U32x4(0, 0, 0, 0);
        this.lights = U32x4(0, 0, 0, 0);
        return this;
    }

    writeAt(base: DataView, off: u32): void {
        putMat4(base, off, this.model);
        putMat4(base, off + 64, this.normal);
        putVec4(base, off + 128, this.color);
        putU32x4(base, off + 144, this.params);
        putU32x4(base, off + 160, this.extra);
        putVec4(base, off + 176, this.gi0);
        putVec4(base, off + 192, this.gi1);
        putVec4(base, off + 208, this.gi2);
        putU32x4(base, off + 224, this.decals);
        putU32x4(base, off + 240, this.lights);
    }

    toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>OBJECT_UNIFORM_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// Per-material uniform (group 2, binding 0). Must match `MaterialU` in
// surface.wgsl. Colors are linear.
export struct MaterialUniform {
    // Linear base color and alpha.
    baseColor: Vec4 = Vec4(0, 0, 0, 0);
    // Linear emission times strength; `w` is the alpha cutoff.
    emission: Vec4 = Vec4(0, 0, 0, 0);
    // metallic, roughness, (milestone 62) an extended material's
    // refraction_scale (0 for every other, whose bytes are what they were),
    // unused.
    factors: Vec4 = Vec4(0, 0, 0, 0);
    // Texture presence bits (`T_*`), alpha mode (0 opaque, 1 mask, 2
    // blend), double sided, MAT_VERTEX_COLOR* bits.
    flags: U32x4 = U32x4(0, 0, 0, 0);
    // Milestone 14: the texture coordinate's scale (xy) and offset (zw),
    // Godot's uv1_scale and uv1_offset, applied to every texture sample
    // after the flip (surface.wgsl `material_uv`). The default (1, 1, 0, 0)
    // is exact in floating point, so a material without them samples
    // where it did before.
    uv: Vec4 = Vec4(1, 1, 0, 0);

    constructor(baseColor: Vec4, emission: Vec4, factors: Vec4, flags: U32x4, uv: Vec4 = Vec4(1, 1, 0, 0)) {
        this.baseColor = baseColor;
        this.emission = emission;
        this.factors = factors;
        this.flags = flags;
        this.uv = uv;
    }

    readonly writeAt(base: DataView, off: u32): void {
        putVec4(base, off, this.baseColor);
        putVec4(base, off + 16, this.emission);
        putVec4(base, off + 32, this.factors);
        putU32x4(base, off + 48, this.flags);
        putVec4(base, off + 64, this.uv);
    }

    // The whole block (MATERIAL_UNIFORM_SIZE bytes), its extended part at
    // the identity (MaterialExtUniform's defaults): what a material without
    // MAT_EXT binds.
    readonly toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>MATERIAL_UNIFORM_SIZE);
        const dv = new DataView(buf, 0, buf.byteLength);
        this.writeAt(dv, 0);
        new MaterialExtUniform().writeAt(dv, MATERIAL_BASE_SIZE);
        return buf;
    }
}

// The extended part of the material block (milestone 14, part 2;
// MATERIAL_EXT_SIZE bytes at MATERIAL_BASE_SIZE; surface.wgsl's
// MaterialU.xf and .ext), read only by the extended pipelines (MAT_EXT).
// engine/src/render/material.as `materialExtUniform` fills it.
export class MaterialExtUniform {
    // By texture slot (PbrSlot), two rows each: the slot's coordinate is
    // (dot(row0.xy, uv) + row0.z, dot(row1.xy, uv) + row1.z) of UV set
    // row0.w (0 or 1), `uv` the flipped coordinate (tex_uv), i.e. glTF's
    // KHR_texture_transform with Godot's uv1 folded in for set 0. row1.w
    // says where the texture is: 0 none, else for slots 0 to 5 (bound at
    // bindings 1 to 5) 1, for the others its layer of the extension array
    // plus 1.
    xf: StaticArray<Vec4> = identityTransforms();
    // The extensions' factors (surface.wgsl's EXT_* comments name them);
    // colours linear.
    ext: StaticArray<Vec4> = defaultFactors();

    writeAt(base: DataView, off: u32): void {
        for (let i = 0; i < this.xf.length; i++) putVec4(base, off + <u32>i * 16, this.xf[i]);
        const at = off + <u32>(MATERIAL_EXT_SLOTS * 2) * 16;
        for (let i = 0; i < this.ext.length; i++) putVec4(base, at + <u32>i * 16, this.ext[i]);
    }
}

// Every slot's transform the identity, set 0, no texture.
function identityTransforms(): StaticArray<Vec4> {
    const a = new StaticArray<Vec4>(MATERIAL_EXT_SLOTS * 2);
    for (let i = 0; i < MATERIAL_EXT_SLOTS; i++) {
        a[i * 2] = Vec4(1, 0, 0, 0);
        a[i * 2 + 1] = Vec4(0, 1, 0, 0);
    }
    return a;
}

// glTF's defaults of every extension, as surface.wgsl reads them: specular
// colour 1 and factor 1, ior 1.5, attenuation colour 1, clearcoat normal
// scale 1, normal scale 1, iridescence ior 1.3 over 100 to 400 nm, the
// anisotropy direction (1, 0), occlusion strength 1, diffuse transmission
// colour 1.
function defaultFactors(): StaticArray<Vec4> {
    const a = new StaticArray<Vec4>(MATERIAL_EXT_FACTORS);
    a[0] = Vec4(1, 1, 1, 1);
    a[1] = Vec4(1.5, 0, 0, 0);
    a[2] = Vec4(1, 1, 1, 0);
    a[3] = Vec4(0, 0, 1, 1);
    a[4] = Vec4(0, 0, 0, 0);
    a[5] = Vec4(0, 1.3, 100, 400);
    a[6] = Vec4(0, 1, 0, 1);
    a[7] = Vec4(1, 1, 1, 0);
    return a;
}

// One light of the lit block (80 bytes; surface.wgsl's LightU).
export struct LightUniform {
    // Linear rgb * energy * pi; w unused.
    color: Vec4 = Vec4(0, 0, 0, 0);
    // xyz world position; w = 1 / range (0 for a directional light).
    position: Vec4 = Vec4(0, 0, 0, 0);
    // xyz unit direction of travel; w = the distance attenuation exponent.
    direction: Vec4 = Vec4(0, 0, 0, 0);
    // x cos(spot angle), y the spot angle attenuation exponent, z the
    // specular factor (light_specular); w unused.
    spot: Vec4 = Vec4(0, 0, 0, 0);
    // x the kind (LIGHT_*), y LIGHT_SHADOWED or 0, z LIGHT_BAKED_STATIC or
    // 0, w the light's shadow slot (its ShadowUniform.lights entry) when y
    // is LIGHT_SHADOWED, else 0.
    info: U32x4 = U32x4(0, 0, 0, 0);

    constructor(color: Vec4, position: Vec4, direction: Vec4, spot: Vec4, info: U32x4) {
        this.color = color;
        this.position = position;
        this.direction = direction;
        this.spot = spot;
        this.info = info;
    }

    readonly writeAt(base: DataView, off: u32): void {
        putVec4(base, off, this.color);
        putVec4(base, off + 16, this.position);
        putVec4(base, off + 32, this.direction);
        putVec4(base, off + 48, this.spot);
        putU32x4(base, off + 64, this.info);
    }

    readonly toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>LIGHT_UNIFORM_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// The lit mode's block (group 0, binding 1, LIT_UNIFORM_SIZE bytes;
// surface.wgsl's LitU). A class rather than a value struct, as it holds
// its lights in an array; `lights` beyond the count are written as zeros
// by writeAt, and not at all by writeUsedAt.
export class LitUniform {
    // x the pool's light count (<= LIT_UNIFORM_LIGHTS), y ENV_* bits, z the
    // tone map, w unused.
    counts: U32x4 = U32x4(0, 0, 0, 0);
    // rgb the flat ambient light, w the sky ambient's energy.
    ambient: Vec4 = Vec4(0, 0, 0, 0);
    // x exposure, y white; zw unused.
    tone: Vec4 = Vec4(1, 1, 0, 0);
    // The world's up, which the sky gradient is laid along.
    up: Vec4 = Vec4(0, 0, 1, 0);
    skyTop: Vec4 = Vec4(0, 0, 0, 0);
    skyHorizon: Vec4 = Vec4(0, 0, 0, 0);
    groundHorizon: Vec4 = Vec4(0, 0, 0, 0);
    groundBottom: Vec4 = Vec4(0, 0, 0, 0);
    // Clip to world: the sky pass's view rays.
    invViewProj: Mat4 = Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));
    // Milestone 59, surface.wgsl's `dirs`: the pool entries of its
    // directional lights (the fog's sun scatter reads them), a byte each in
    // pool order: x the first four (the first in its low byte), y the next
    // four; z how many (at most 8); w (milestone 62) the screen texture's
    // mip count with ENV_SCREEN_REFRACTION, else 0.
    dirs: U32x4 = U32x4(0, 0, 0, 0);
    // The pool, in its order: at most LIT_UNIFORM_LIGHTS.
    lights: Array<LightUniform> = [];

    // Writes the LIT_UNIFORM_SIZE bytes at byte `off` of `base`.
    writeAt(base: DataView, off: u32): void {
        const n = this.writeUsedAt(base, off);
        for (let at = n; at < LIT_UNIFORM_SIZE; at += 4) base.setUint32(off + at, 0, true);
    }

    // Writes the header and the first `counts.x` lights at byte `off` of
    // `base`, and returns their byte length (LIT_HEADER_SIZE + count x 80):
    // what the renderer uploads, as no item names a light past the count.
    // A frame of 8 lights writes 848 bytes, not 5,328.
    writeUsedAt(base: DataView, off: u32): u32 {
        putU32x4(base, off, this.counts);
        putVec4(base, off + 16, this.ambient);
        putVec4(base, off + 32, this.tone);
        putVec4(base, off + 48, this.up);
        putVec4(base, off + 64, this.skyTop);
        putVec4(base, off + 80, this.skyHorizon);
        putVec4(base, off + 96, this.groundHorizon);
        putVec4(base, off + 112, this.groundBottom);
        putMat4(base, off + 128, this.invViewProj);
        putU32x4(base, off + 192, this.dirs);
        const n = min<i32>(min<i32>(<i32>this.counts.x, this.lights.length), LIT_UNIFORM_LIGHTS);
        for (let i = 0; i < n; i++) {
            unchecked(this.lights[i]).writeAt(base, off + LIT_HEADER_SIZE + <u32>i * LIGHT_UNIFORM_SIZE);
        }
        return LIT_HEADER_SIZE + <u32>n * LIGHT_UNIFORM_SIZE;
    }

    // The uniform buffer bytes.
    toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>LIT_UNIFORM_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// One light's shadow as the shader reads it (64 bytes; surface.wgsl's
// ShadowLightU), at the light's shadow slot (milestone 59: its
// LightUniform.info.w; slots go to the shadowed lights in pool order).
// Zeros past the slots used (no light names them, and the shader never
// looks there).
export struct ShadowLightUniform {
    // x the depth bias and y the normal bias, in texels of the light's
    // tile (shadow.as), z the PCF radius in texels (shadow_blur), w the
    // opacity (shadow_opacity).
    params: Vec4 = Vec4(0, 0, 0, 0);
    // Directional: the far view distance of cascades 0..3 (a cascade past
    // the light's count repeats the last); unused otherwise.
    splits: Vec4 = Vec4(0, 0, 0, 0);
    // Directional: x the view distance where the shadow starts to fade, y
    // where it is gone (shadow_max_distance); zw unused.
    fade: Vec4 = Vec4(0, 0, 0, 0);
    // x the light's first tile, y its tile count (1..4 directional, 1 spot,
    // 6 omni), z its kind (LIGHT_*), w unused.
    info: U32x4 = U32x4(0, 0, 0, 0);

    constructor(params: Vec4, splits: Vec4, fade: Vec4, info: U32x4) {
        this.params = params;
        this.splits = splits;
        this.fade = fade;
        this.info = info;
    }

    readonly writeAt(base: DataView, off: u32): void {
        putVec4(base, off, this.params);
        putVec4(base, off + 16, this.splits);
        putVec4(base, off + 32, this.fade);
        putU32x4(base, off + 48, this.info);
    }
}

// One tile of the atlas (96 bytes; surface.wgsl's ShadowTileU): the
// light-space view-projection a shadow pass drew it with, where it is in the
// atlas, and the size of its texels in the world.
export struct ShadowTileUniform {
    // World to the tile's clip space (depth 0..1, the renderer's
    // convention).
    viewProj: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
    // The tile in atlas UV: x, y its top-left corner, z, w its size.
    rect: Vec4 = Vec4(0, 0, 0, 0);
    // A texel's world size at the receiver: x + y * (the receiver's
    // distance from the light). An orthographic tile has y = 0, a
    // perspective one x = 0. zw unused.
    texel: Vec4 = Vec4(0, 0, 0, 0);

    constructor(viewProj: Mat4, rect: Vec4, texel: Vec4) {
        this.viewProj = viewProj;
        this.rect = rect;
        this.texel = texel;
    }

    readonly writeAt(base: DataView, off: u32): void {
        putMat4(base, off, this.viewProj);
        putVec4(base, off + 64, this.rect);
        putVec4(base, off + 80, this.texel);
    }
}

// The shadow block (group 0, binding 2, SHADOW_UNIFORM_SIZE bytes;
// surface.wgsl's ShadowU).
// A class, as it holds arrays; entries past an array's length are written
// as zeros.
export class ShadowUniform {
    // x 1 / the atlas size in texels, y the atlas size, z the tiles used, w
    // unused.
    atlas: Vec4 = Vec4(0, 0, 0, 0);
    // At most SHADOW_UNIFORM_LIGHTS, by shadow slot.
    lights: Array<ShadowLightUniform> = [];
    // At most SHADOW_TILES, by tile index.
    tiles: Array<ShadowTileUniform> = [];

    writeAt(base: DataView, off: u32): void {
        putVec4(base, off, this.atlas);
        const noLight = ShadowLightUniform(VEC4_ZERO, VEC4_ZERO, VEC4_ZERO, U32x4(0, 0, 0, 0));
        for (let i = 0; i < SHADOW_UNIFORM_LIGHTS; i++) {
            const l = i < this.lights.length ? this.lights[i] : noLight;
            l.writeAt(base, off + 16 + <u32>i * SHADOW_LIGHT_UNIFORM_SIZE);
        }
        const tilesAt = off + 16 + <u32>SHADOW_UNIFORM_LIGHTS * SHADOW_LIGHT_UNIFORM_SIZE;
        const noTile = ShadowTileUniform(
            Mat4(VEC4_ZERO, VEC4_ZERO, VEC4_ZERO, VEC4_ZERO), VEC4_ZERO, VEC4_ZERO);
        for (let i = 0; i < SHADOW_TILES; i++) {
            const t = i < this.tiles.length ? this.tiles[i] : noTile;
            t.writeAt(base, tilesAt + <u32>i * SHADOW_TILE_UNIFORM_SIZE);
        }
    }

    // The uniform buffer bytes.
    toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>SHADOW_UNIFORM_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// One sun of a procedural sky (32 bytes; surface.wgsl's SunU): a
// directional light of the frame, as Godot's sky shader sees LIGHT0..3.
export struct SkySunUniform {
    // xyz the unit direction towards the light, in sky space; w the disc's
    // angular size in radians (light_angular_distance, Godot's LIGHTn_SIZE).
    direction: Vec4 = Vec4(0, 0, 0, 0);
    // Linear rgb times energy (no factor of pi: the lit block's colours
    // carry one, the sky's do not); w unused.
    color: Vec4 = Vec4(0, 0, 0, 0);

    constructor(direction: Vec4, color: Vec4) {
        this.direction = direction;
        this.color = color;
    }

    readonly writeAt(base: DataView, off: u32): void {
        putVec4(base, off, this.direction);
        putVec4(base, off + 16, this.color);
    }
}

// The sky block (group 0, binding 5, 528 bytes; surface.wgsl's SkyU). A
// class, as it holds arrays; entries past an array's length are zeros.
// Byte offsets: flags 0, toSky 16, skyTop 80, skyHorizon 96, groundBottom
// 112, groundHorizon 128, sun 144, ambient 160, ibl 176, fogColor 192, fog
// 208, fogDepth 224, fogOrigin 240, suns 256 (+32 each), sh 384 (+16 each).
export class SkyUniform {
    // x SKY_* bits, y the radiance map's mip levels, z the suns drawn
    // (<= SKY_SUNS), w unused.
    flags: U32x4 = U32x4(0, 0, 0, 0);
    // Frame world direction to sky space (SkyDesc.toSky).
    toSky: Mat4 = Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));
    // Procedural: linear colours; w sky_curve, the sky's energy,
    // ground_curve, the ground's energy.
    skyTop: Vec4 = Vec4(0, 0, 0, 0);
    skyHorizon: Vec4 = Vec4(0, 0, 0, 0);
    groundBottom: Vec4 = Vec4(0, 0, 0, 0);
    groundHorizon: Vec4 = Vec4(0, 0, 0, 0);
    // x sun_angle_max (radians), y sun_curve, z the material's
    // energy_multiplier, w background_energy_multiplier.
    sun: Vec4 = Vec4(0, 0, 0, 0);
    // rgb the flat ambient (linear, energy applied), w the sky's share of
    // the diffuse ambient (ambient_light_sky_contribution).
    ambient: Vec4 = Vec4(0, 0, 0, 0);
    // x ambient_light_energy (scales the irradiance and the radiance); yzw
    // unused.
    ibl: Vec4 = Vec4(0, 0, 0, 0);
    // rgb the fog's colour (linear, times fog_light_energy), w
    // fog_sun_scatter.
    fogColor: Vec4 = Vec4(0, 0, 0, 0);
    // x fog_density, y fog_sky_affect, z fog_height, w fog_height_density.
    fog: Vec4 = Vec4(0, 0, 0, 0);
    // x fog_depth_begin, y fog_depth_end, z fog_depth_curve, w
    // fog_aerial_perspective.
    fogDepth: Vec4 = Vec4(0, 0, 0, 0);
    // x in an orthographic view, the view depth fog is measured from (the
    // nearest drawn depth); y the camera's near and z far distance (aerial
    // perspective's mip); w 1 for an orthographic view.
    fogOrigin: Vec4 = Vec4(0, 0, 0, 0);
    // At most SKY_SUNS.
    suns: Array<SkySunUniform> = [];
    // SKY_SH_COEFFS rgb coefficients of the irradiance (cosine-convolved and
    // divided by pi: sky.as `shIrradiance`); w unused.
    sh: Array<Vec4> = [];

    writeAt(base: DataView, off: u32): void {
        putU32x4(base, off, this.flags);
        putMat4(base, off + 16, this.toSky);
        putVec4(base, off + 80, this.skyTop);
        putVec4(base, off + 96, this.skyHorizon);
        putVec4(base, off + 112, this.groundBottom);
        putVec4(base, off + 128, this.groundHorizon);
        putVec4(base, off + 144, this.sun);
        putVec4(base, off + 160, this.ambient);
        putVec4(base, off + 176, this.ibl);
        putVec4(base, off + 192, this.fogColor);
        putVec4(base, off + 208, this.fog);
        putVec4(base, off + 224, this.fogDepth);
        putVec4(base, off + 240, this.fogOrigin);
        const noSun = SkySunUniform(VEC4_ZERO, VEC4_ZERO);
        for (let i = 0; i < SKY_SUNS; i++) {
            const s = i < this.suns.length ? this.suns[i] : noSun;
            s.writeAt(base, off + 256 + <u32>i * SKY_SUN_UNIFORM_SIZE);
        }
        const shAt = off + 256 + <u32>SKY_SUNS * SKY_SUN_UNIFORM_SIZE;
        for (let i = 0; i < SKY_SH_COEFFS; i++) {
            putVec4(base, shAt + <u32>i * 16, i < this.sh.length ? this.sh[i] : VEC4_ZERO);
        }
    }

    // The uniform buffer bytes.
    toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>SKY_UNIFORM_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// The post block (288 bytes; post_effects.wgsl's PostU), one per post draw.
// Which fields a pass reads is post_effects.wgsl's (and post.as's) to say;
// the rest are zeros. Byte offsets: target 0, source 16, flags 32, tone 48,
// glow 64, levels 80 (levels 1-4) and 96 (5-7, w unused), bcs 112, ssao
// 128, ssao2 144, invProj 160, proj 224.
export class PostUniform {
    // x, y the target's size in texels; z, w their inverses.
    target: Vec4 = Vec4(0, 0, 0, 0);
    // x, y t_src's size in texels; z, w their inverses.
    source: Vec4 = Vec4(0, 0, 0, 0);
    // x POST_* bits, y the tone map (TONEMAP_*), z the glow's blend mode
    // (GLOW_BLEND_*), w the SSAA factor (the bright pass's block is 2 x it).
    flags: U32x4 = U32x4(0, 0, 0, 0);
    // x tonemap_exposure, y tonemap_white, z glow_mix, w glow_strength.
    tone: Vec4 = Vec4(0, 0, 0, 0);
    // x glow_hdr_threshold, y glow_hdr_scale, z glow_hdr_luminance_cap, w
    // glow_bloom.
    glow: Vec4 = Vec4(0, 0, 0, 0);
    // The weight of glow levels 1-4 and 5-7 (post.as `glowWeights`:
    // intensity and normalisation applied; 0 for a level not drawn).
    levelsLow: Vec4 = Vec4(0, 0, 0, 0);
    levelsHigh: Vec4 = Vec4(0, 0, 0, 0);
    // x adjustment_brightness, y _contrast, z _saturation; w unused.
    bcs: Vec4 = Vec4(0, 0, 0, 0);
    // x ssao_radius, y ssao_intensity, z ssao_power, w ssao_detail.
    ssao: Vec4 = Vec4(0, 0, 0, 0);
    // x ssao_horizon, y ssao_sharpness, z pixels per world unit at view
    // depth 1 (at any depth in an orthographic view), w 1 for an
    // orthographic view.
    ssao2: Vec4 = Vec4(0, 0, 0, 0);
    // Clip to view and view to clip (SSAO rebuilds view positions).
    invProj: Mat4 = Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));
    proj: Mat4 = Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));

    writeAt(base: DataView, off: u32): void {
        putVec4(base, off, this.target);
        putVec4(base, off + 16, this.source);
        putU32x4(base, off + 32, this.flags);
        putVec4(base, off + 48, this.tone);
        putVec4(base, off + 64, this.glow);
        putVec4(base, off + 80, this.levelsLow);
        putVec4(base, off + 96, this.levelsHigh);
        putVec4(base, off + 112, this.bcs);
        putVec4(base, off + 128, this.ssao);
        putVec4(base, off + 144, this.ssao2);
        putMat4(base, off + 160, this.invProj);
        putMat4(base, off + 224, this.proj);
    }

    // The uniform buffer bytes.
    toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>POST_UNIFORM_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// One probe of the frame as the shader reads it (128 bytes; surface.wgsl's
// ProbeEntryU). A class written in place, so filling a frame's block
// allocates nothing.
export class ProbeEntryUniform {
    // The frame's world to probe space (ReflectionProbeDesc.toLocal).
    toLocal: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
    // xyz half the box (probe space), w the blend distance.
    extents: Vec4 = Vec4(0, 0, 0, 0);
    // xyz the origin offset (probe space), w the intensity.
    offset: Vec4 = Vec4(0, 0, 0, 0);
    // rgb the ambient colour (linear, energy applied), w unused.
    ambient: Vec4 = Vec4(0, 0, 0, 0);
    // x PROBE_* bits, y the ambient mode (data.as PROBE_AMBIENT_*), z the
    // reflection mask, w the atlas row its cube is in.
    info: U32x4 = U32x4(0, 0, 0, 0);

    writeAt(base: DataView, off: u32): void {
        putMat4(base, off, this.toLocal);
        putVec4(base, off + 64, this.extents);
        putVec4(base, off + 80, this.offset);
        putVec4(base, off + 96, this.ambient);
        putU32x4(base, off + 112, this.info);
    }
}

// The probe block (group 0, binding 13, 1040 bytes; surface.wgsl's ProbeU).
// `entries` holds PROBE_UNIFORM_ENTRIES entries made once; those past
// `counts.x` are written as zeros, so a frame without probes writes 1040
// zeros.
export class ProbeUniform {
    // x the probes drawn, y the atlas's levels, z its face size at level
    // 0, w unused. All 0 without probes.
    counts: U32x4 = U32x4(0, 0, 0, 0);
    entries: Array<ProbeEntryUniform> = [];

    constructor() {
        for (let i = 0; i < PROBE_UNIFORM_ENTRIES; i++) this.entries.push(new ProbeEntryUniform());
    }

    writeAt(base: DataView, off: u32): void {
        putU32x4(base, off, this.counts);
        const n = min<i32>(<i32>this.counts.x, PROBE_UNIFORM_ENTRIES);
        for (let i = 0; i < PROBE_UNIFORM_ENTRIES; i++) {
            const at = off + 16 + <u32>i * PROBE_ENTRY_UNIFORM_SIZE;
            if (i < n) {
                this.entries[i].writeAt(base, at);
            } else {
                for (let k: u32 = 0; k < PROBE_ENTRY_UNIFORM_SIZE; k += 4) putU32(base, at + k, 0);
            }
        }
    }

    // The uniform buffer bytes.
    toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>PROBE_UNIFORM_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// Milestone 33: one decal of the frame's pool as the shader reads it (176
// bytes; surface.wgsl's DecalEntryU). A class written in place, so filling
// a frame's block allocates nothing. Positions and directions are in the
// frame's world space.
export class DecalEntryUniform {
    // The frame's world to the decal's space, Godot's: x and z from 0 to 1
    // across the box, y from -1 (its bottom) to 1 (its top); a point is
    // inside when all three are.
    toLocal: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
    // rgb the modulate colour (linear), a its alpha times the distance
    // fade.
    modulate: Vec4 = Vec4(0, 0, 0, 0);
    // upper_fade, lower_fade, normal_fade, albedo_mix.
    fades: Vec4 = Vec4(0, 0, 0, 0);
    // The box's unit axes. axisX.w: emission_energy times the distance
    // fade; axisY.w: the world size of one level-0 texel (the larger of
    // size.x and size.z over the atlas's layer size), which the shader
    // picks a level by; axisZ.w unused.
    axisX: Vec4 = Vec4(0, 0, 0, 0);
    axisY: Vec4 = Vec4(0, 0, 0, 0);
    axisZ: Vec4 = Vec4(0, 0, 0, 0);
    // The atlas layer + 1 of the albedo, normal, orm and emission textures
    // (0: none).
    layers: U32x4 = U32x4(0, 0, 0, 0);
    // x DECAL_LIVE_* bits; y, z, w unused.
    flags: U32x4 = U32x4(0, 0, 0, 0);

    writeAt(base: DataView, off: u32): void {
        putMat4(base, off, this.toLocal);
        putVec4(base, off + 64, this.modulate);
        putVec4(base, off + 80, this.fades);
        putVec4(base, off + 96, this.axisX);
        putVec4(base, off + 112, this.axisY);
        putVec4(base, off + 128, this.axisZ);
        putU32x4(base, off + 144, this.layers);
        putU32x4(base, off + 160, this.flags);
    }
}

// Milestone 33: the decal block (group 1, binding 2, 11296 bytes;
// surface.wgsl's DecalU). `entries` holds DECAL_UNIFORM_ENTRIES entries
// made once; those past `counts.x` are written as zeros, so a frame
// without decals writes 11296 zeros.
export class DecalUniform {
    // x the decals in the pool, y the atlas's levels; z, w unused. All 0
    // without decals.
    counts: U32x4 = U32x4(0, 0, 0, 0);
    // The level the shader samples a decal at (no derivatives: the loop
    // over an item's decals is not uniform control flow): x the world size
    // of a pixel at distance 1 from the eye (2 tan(fov / 2) over the
    // target's height in pixels) or, with y 1, the world size of a pixel
    // of an orthographic view; z, w unused.
    lod: Vec4 = Vec4(0, 0, 0, 0);
    entries: Array<DecalEntryUniform> = [];

    constructor() {
        for (let i = 0; i < DECAL_UNIFORM_ENTRIES; i++) this.entries.push(new DecalEntryUniform());
    }

    writeAt(base: DataView, off: u32): void {
        putU32x4(base, off, this.counts);
        putVec4(base, off + 16, this.lod);
        const n = min<i32>(<i32>this.counts.x, DECAL_UNIFORM_ENTRIES);
        for (let i = 0; i < DECAL_UNIFORM_ENTRIES; i++) {
            const at = off + 32 + <u32>i * DECAL_ENTRY_UNIFORM_SIZE;
            if (i < n) {
                this.entries[i].writeAt(base, at);
            } else {
                for (let k: u32 = 0; k < DECAL_ENTRY_UNIFORM_SIZE; k += 4) putU32(base, at + k, 0);
            }
        }
    }

    // `writeAt` of the header and the first counts.x entries alone; the
    // bytes written (32 + 176 a decal). The shader reads no entry past
    // the count (every item's list names the pool's), so the renderer
    // writes and uploads only these: a frame of 5 decals 912 bytes, not
    // 11,296.
    writeUsedAt(base: DataView, off: u32): u32 {
        putU32x4(base, off, this.counts);
        putVec4(base, off + 16, this.lod);
        const n = min<i32>(<i32>this.counts.x, DECAL_UNIFORM_ENTRIES);
        for (let i = 0; i < n; i++) this.entries[i].writeAt(base, off + 32 + <u32>i * DECAL_ENTRY_UNIFORM_SIZE);
        return 32 + <u32>n * DECAL_ENTRY_UNIFORM_SIZE;
    }

    // The uniform buffer bytes.
    toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>DECAL_UNIFORM_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// Milestone 37: one fog volume of the view's pool as the shader reads it
// (144 bytes; surface.wgsl's FogEntryU). A class written in place, so
// filling a view's block allocates nothing. Frame world space.
export class FogEntryUniform {
    // The frame's world to the node's own space (its scale included:
    // Godot's params.transform); the identity for the world shapes.
    toLocal: Mat4 = Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));
    // xyz Godot's size (node space), w the least of the three.
    size: Vec4 = Vec4(0, 0, 0, 0);
    // x density, y height_falloff, z edge_fade (0 for a world shape, which
    // has no edge), w the height of the node's origin along the frame's up.
    material: Vec4 = Vec4(0, 0, 0, 0);
    // rgb the linear albedo, w the shape (fog_volume.as FOG_SHAPE_*, as an
    // f32).
    albedo: Vec4 = Vec4(0, 0, 0, 0);
    // rgb the linear emission, w a world shape's length (metres from the
    // eye: volumetric_fog_length), 0 for the others.
    emission: Vec4 = Vec4(0, 0, 0, 0);
    // x, y its lights (entries of the lit block's pool, a byte each, the
    // first in x's low byte), z how many, w unused.
    lights: U32x4 = U32x4(0, 0, 0, 0);

    writeAt(base: DataView, off: u32): void {
        putMat4(base, off, this.toLocal);
        putVec4(base, off + 64, this.size);
        putVec4(base, off + 80, this.material);
        putVec4(base, off + 96, this.albedo);
        putVec4(base, off + 112, this.emission);
        putU32x4(base, off + 128, this.lights);
    }
}

// Milestone 37: the fog block (group 1, binding 5, FOG_UNIFORM_SIZE bytes;
// surface.wgsl's FogU). `entries` holds FOG_UNIFORM_ENTRIES entries made
// once; those past `counts.x` are written as zeros by writeAt, and not at
// all by writeUsedAt.
export class FogUniform {
    // x the pool's entries, y the sky's list (pool entries + 1, a byte
    // each, the first in the low byte), z how many it holds, w 1 when the
    // view draws fog. All 0 without volumetric fog.
    counts: U32x4 = U32x4(0, 0, 0, 0);
    // x the anisotropy (Henyey-Greenstein's g), y ambient_inject, z
    // sky_affect, w the length.
    params: Vec4 = Vec4(0, 0, 0, 0);
    // rgb the isotropic ambient light the fog takes in; w unused.
    ambient: Vec4 = Vec4(0, 0, 0, 0);
    // The frame's up (the lit block's), the height falloff's axis.
    up: Vec4 = Vec4(0, 0, 1, 0);
    // By lit block pool entry (LIT_UNIFORM_LIGHTS of them): the light's
    // light_volumetric_fog_energy.
    lightFog: StaticArray<f32> = new StaticArray<f32>(LIT_UNIFORM_LIGHTS);
    entries: Array<FogEntryUniform> = [];

    constructor() {
        for (let i = 0; i < FOG_UNIFORM_ENTRIES; i++) this.entries.push(new FogEntryUniform());
    }

    writeAt(base: DataView, off: u32): void {
        const n = this.writeUsedAt(base, off);
        for (let at = n; at < FOG_UNIFORM_SIZE; at += 4) putU32(base, off + at, 0);
    }

    // The header (with the light energies) and the first counts.x entries
    // at byte `off` of `base`; the bytes written (320 + 144 an entry): the
    // shader reads no entry past the count, so the renderer writes and
    // uploads only these (a view of 5 volumes 1,040 bytes, not 2,624).
    writeUsedAt(base: DataView, off: u32): u32 {
        putU32x4(base, off, this.counts);
        putVec4(base, off + 16, this.params);
        putVec4(base, off + 32, this.ambient);
        putVec4(base, off + 48, this.up);
        for (let i = 0; i < LIT_UNIFORM_LIGHTS; i++) putF32(base, off + 64 + <u32>i * 4, unchecked(this.lightFog[i]));
        const n = min<i32>(<i32>this.counts.x, FOG_UNIFORM_ENTRIES);
        for (let i = 0; i < n; i++) {
            unchecked(this.entries[i]).writeAt(base, off + FOG_HEADER_SIZE + <u32>i * FOG_ENTRY_UNIFORM_SIZE);
        }
        return FOG_HEADER_SIZE + <u32>n * FOG_ENTRY_UNIFORM_SIZE;
    }

    // The uniform buffer bytes.
    toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>FOG_UNIFORM_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// The live capture's prefilter block for one level (1040 bytes; probe.wgsl's
// FilterU): sky.as prefilter's samples for that level's roughness, worked
// out on the CPU (gpu/probes.as `probeFilterUniformInto`).
export class ProbeFilterUniform {
    // x 1 / the samples' weight sum (0: none, the level copies level 0),
    // y the samples used, z the level drawn, w the levels of the chain.
    info: Vec4 = Vec4(0, 0, 0, 0);
    // Per sample i: at 8i the offset from the normal (frame where N is +z)
    // and its first source level; at 8i + 4 the weights of that level and
    // the next, then two zeros. PROBE_FILTER_SAMPLES samples at most.
    samples: Float32Array = new Float32Array(PROBE_FILTER_SAMPLES * 8);

    writeAt(base: DataView, off: u32): void {
        putVec4(base, off, this.info);
        for (let i = 0; i < this.samples.length; i++) putF32(base, off + 16 + <u32>i * 4, this.samples[i]);
    }

    toBytes(): ArrayBuffer {
        const buf = new ArrayBuffer(<i32>PROBE_FILTER_UNIFORM_SIZE);
        this.writeAt(new DataView(buf, 0, buf.byteLength), 0);
        return buf;
    }
}

// ---------------------------------------------------------------- vertices

export struct SurfaceVertex {
    pos: Vec3 = Vec3(0, 0, 0);
    normal: Vec3 = Vec3(0, 0, 0);
    uv: Vec2 = Vec2(0, 0);
    flags: u32 = 0;
    // Tangent along +U with the bitangent sign in `w` (glTF convention).
    tangent: Vec4 = Vec4(0, 0, 0, 0);
    // Weight in the shown vertex group, WEIGHT_NONE when the vertex is not in it.
    weight: f32 = 0;

    constructor(pos: Vec3, normal: Vec3, uv: Vec2, flags: u32, tangent: Vec4, weight: f32) {
        this.pos = pos;
        this.normal = normal;
        this.uv = uv;
        this.flags = flags;
        this.tangent = tangent;
        this.weight = weight;
    }

    // The 14 u32 words of the vertex (its bit pattern).
    readonly word(i: i32): u32 {
        switch (i) {
            case 0: return reinterpret<u32>(this.pos.x);
            case 1: return reinterpret<u32>(this.pos.y);
            case 2: return reinterpret<u32>(this.pos.z);
            case 3: return reinterpret<u32>(this.normal.x);
            case 4: return reinterpret<u32>(this.normal.y);
            case 5: return reinterpret<u32>(this.normal.z);
            case 6: return reinterpret<u32>(this.uv.x);
            case 7: return reinterpret<u32>(this.uv.y);
            case 8: return this.flags;
            case 9: return reinterpret<u32>(this.tangent.x);
            case 10: return reinterpret<u32>(this.tangent.y);
            case 11: return reinterpret<u32>(this.tangent.z);
            case 12: return reinterpret<u32>(this.tangent.w);
            default: return reinterpret<u32>(this.weight);
        }
    }

    // Equality of the bit patterns (the vertex dedup key, so -0.0 != 0.0
    // and a NaN equals the same NaN).
    operator==(a: SurfaceVertex, b: SurfaceVertex): bool {
        return reinterpret<u32>(a.pos.x) == reinterpret<u32>(b.pos.x)
            && reinterpret<u32>(a.pos.y) == reinterpret<u32>(b.pos.y)
            && reinterpret<u32>(a.pos.z) == reinterpret<u32>(b.pos.z)
            && reinterpret<u32>(a.normal.x) == reinterpret<u32>(b.normal.x)
            && reinterpret<u32>(a.normal.y) == reinterpret<u32>(b.normal.y)
            && reinterpret<u32>(a.normal.z) == reinterpret<u32>(b.normal.z)
            && reinterpret<u32>(a.uv.x) == reinterpret<u32>(b.uv.x)
            && reinterpret<u32>(a.uv.y) == reinterpret<u32>(b.uv.y)
            && a.flags == b.flags
            && reinterpret<u32>(a.tangent.x) == reinterpret<u32>(b.tangent.x)
            && reinterpret<u32>(a.tangent.y) == reinterpret<u32>(b.tangent.y)
            && reinterpret<u32>(a.tangent.z) == reinterpret<u32>(b.tangent.z)
            && reinterpret<u32>(a.tangent.w) == reinterpret<u32>(b.tangent.w)
            && reinterpret<u32>(a.weight) == reinterpret<u32>(b.weight);
    }

    // FNV-1a style mix over the 14 words (only probed, never iterated).
    readonly hash(): u32 {
        let h: u32 = 2166136261;
        for (let i = 0; i < 14; i++) {
            h = (h ^ this.word(i)) * 16777619;
            h ^= h >> 15;
        }
        return h;
    }

    readonly writeAt(base: DataView, off: u32): void {
        putVec3(base, off, this.pos);
        putVec3(base, off + 12, this.normal);
        putVec2(base, off + 24, this.uv);
        putU32(base, off + 32, this.flags);
        putVec4(base, off + 36, this.tangent);
        putF32(base, off + 52, this.weight);
    }
}

export struct LineInstance {
    a: Vec3 = Vec3(0, 0, 0);
    b: Vec3 = Vec3(0, 0, 0);
    color: Vec4 = Vec4(0, 0, 0, 0);
    width: f32 = 0;
    flags: u32 = 0;

    constructor(a: Vec3, b: Vec3, color: Vec4, width: f32, flags: u32) {
        this.a = a;
        this.b = b;
        this.color = color;
        this.width = width;
        this.flags = flags;
    }

    readonly writeAt(base: DataView, off: u32): void {
        putVec3(base, off, this.a);
        putVec3(base, off + 12, this.b);
        putVec4(base, off + 24, this.color);
        putF32(base, off + 40, this.width);
        putU32(base, off + 44, this.flags);
    }
}

export struct PointInstance {
    pos: Vec3 = Vec3(0, 0, 0);
    size: f32 = 0;
    color: Vec4 = Vec4(0, 0, 0, 0);
    flags: u32 = 0;
    // `_pad: [u32; 3]` is always zero: written as zeros at bytes 36..48.

    constructor(pos: Vec3, size: f32, color: Vec4, flags: u32) {
        this.pos = pos;
        this.size = size;
        this.color = color;
        this.flags = flags;
    }

    readonly writeAt(base: DataView, off: u32): void {
        putVec3(base, off, this.pos);
        putF32(base, off + 12, this.size);
        putVec4(base, off + 16, this.color);
        putU32(base, off + 32, this.flags);
        putU32(base, off + 36, 0);
        putU32(base, off + 40, 0);
        putU32(base, off + 44, 0);
    }
}

// The vertex / index buffer bytes. `reuse` (optional): a buffer to write
// into when it has exactly the size needed (a GPUBuffer copies its bytes
// when it is made, so the same memory can be packed again for the next
// upload); otherwise a new one.
export function packSurfaceVertices(vs: Array<SurfaceVertex>, reuse: ArrayBuffer? = null): ArrayBuffer {
    const buf = sized(reuse, vs.length * <i32>SURFACE_VERTEX_SIZE);
    const base = new DataView(buf, 0, buf.byteLength);
    for (let i = 0; i < vs.length; i++) vs[i].writeAt(base, <u32>i * SURFACE_VERTEX_SIZE);
    return buf;
}

// Milestone 48: `vs` written over `view` (exactly their size), the bytes
// of a buffer a node's blended copy rewrites every time its weights move
// (mesh_cache.as updateVertices): the view is the caller's, kept, so a
// rewrite allocates nothing.
export function writeSurfaceVertices(vs: Array<SurfaceVertex>, view: DataView): void {
    for (let i = 0; i < vs.length; i++) unchecked(vs[i]).writeAt(view, <u32>i * SURFACE_VERTEX_SIZE);
}

// Milestone 48: `ls` written over `view` (writeSurfaceVertices' rule).
export function writeLineInstances(ls: Array<LineInstance>, view: DataView): void {
    for (let i = 0; i < ls.length; i++) unchecked(ls[i]).writeAt(view, <u32>i * LINE_INSTANCE_SIZE);
}

export function packLineInstances(ls: Array<LineInstance>, reuse: ArrayBuffer? = null): ArrayBuffer {
    const buf = sized(reuse, ls.length * <i32>LINE_INSTANCE_SIZE);
    const base = viewOf(buf);
    for (let i = 0; i < ls.length; i++) ls[i].writeAt(base, <u32>i * LINE_INSTANCE_SIZE);
    return buf;
}

export function packPointInstances(ps: Array<PointInstance>, reuse: ArrayBuffer? = null): ArrayBuffer {
    const buf = sized(reuse, ps.length * <i32>POINT_INSTANCE_SIZE);
    const base = viewOf(buf);
    for (let i = 0; i < ps.length; i++) ps[i].writeAt(base, <u32>i * POINT_INSTANCE_SIZE);
    return buf;
}

export function packU32s(xs: Array<u32>, reuse: ArrayBuffer? = null): ArrayBuffer {
    const buf = sized(reuse, xs.length * 4);
    const base = viewOf(buf);
    for (let i = 0; i < xs.length; i++) base.setUint32(i << 2, xs[i], true);
    return buf;
}

// Milestone 48: the skin vertex buffer of a mesh with `count` vertices
// (SKIN_STRIDE bytes each: the four slots as GpuMesh.skinJoints packs them,
// then the four weights), written into `reuse` when it is the right size.
// `joints` holds `count` words and `weights` 4 * `count` numbers (the
// uploader checks).
export function packSkinVertices(
    joints: Array<u32>, weights: Array<f32>, count: i32, reuse: ArrayBuffer? = null,
): ArrayBuffer {
    const buf = sized(reuse, count * <i32>SKIN_STRIDE);
    const base = viewOf(buf);
    for (let i = 0; i < count; i++) {
        const o = i * <i32>SKIN_STRIDE;
        base.setUint32(o, unchecked(joints[i]), true);
        const w = i * 4;
        base.setFloat32(o + 4, unchecked(weights[w]), true);
        base.setFloat32(o + 8, unchecked(weights[w + 1]), true);
        base.setFloat32(o + 12, unchecked(weights[w + 2]), true);
        base.setFloat32(o + 16, unchecked(weights[w + 3]), true);
    }
    return buf;
}

// Milestone 48: the first `joints` joints of a palette (frame.as DrawItem
// .skin, SKIN_FLOATS_PER_JOINT = 12 numbers a joint) as the skin uniform
// holds them, at byte 0 of `base`; the bytes written (48 a joint). Nothing
// is allocated.
export function writeSkinPalette(base: DataView, palette: Float32Array, joints: i32): u32 {
    const n = min<i32>(min<i32>(joints, SKIN_UNIFORM_JOINTS), palette.length / 12) * 12;
    for (let i = 0; i < n; i++) base.setFloat32(i << 2, unchecked(palette[i]), true);
    return <u32>n * 4;
}

// A DataView over the whole of `buf`: one of the last VIEWS_KEPT made when
// it was made over the same buffer, else a new one (kept in their place). A
// view packed again every frame into kept bytes (the editor's grid and
// gizmo lines while the camera moves) then allocates nothing, which matters
// under the stub runtime, which never frees.
const VIEWS_KEPT = 8;
const keptBuffers: Array<ArrayBuffer?> = new Array<ArrayBuffer?>(VIEWS_KEPT);
const keptViews: Array<DataView?> = new Array<DataView?>(VIEWS_KEPT);
let nextView: i32 = 0;

function viewOf(buf: ArrayBuffer): DataView {
    for (let i = 0; i < VIEWS_KEPT; i++) {
        const v = keptViews[i];
        if (keptBuffers[i] === buf && v != null && v.byteLength == buf.byteLength) return v;
    }
    const made = new DataView(buf, 0, buf.byteLength);
    keptBuffers[nextView] = buf;
    keptViews[nextView] = made;
    nextView = (nextView + 1) % VIEWS_KEPT;
    return made;
}

// `reuse` when it is `bytes` long, else a new buffer of that size. Every
// pack function writes every byte of its buffer, so reused bytes never leak
// through.
function sized(reuse: ArrayBuffer?, bytes: i32): ArrayBuffer {
    if (reuse != null && reuse.byteLength == bytes) return reuse;
    return new ArrayBuffer(bytes);
}

// ---------------------------------------------------------------- pipeline state (pure part)

// One vertex attribute (shader location, format, byte offset).
export class VertexAttr {
    location: u32;
    format: VertexFormat;
    offset: u32;

    constructor(location: u32, format: VertexFormat, offset: u32) {
        this.location = location;
        this.format = format;
        this.offset = offset;
    }
}

// Vertex attribute tables per pipeline (offsets are the running sums of the
// sizes).
export const SURFACE_ATTRS: Array<VertexAttr> = [
    new VertexAttr(0, VertexFormat.float3, 0),
    new VertexAttr(1, VertexFormat.float3, 12),
    new VertexAttr(2, VertexFormat.float2, 24),
    new VertexAttr(3, VertexFormat.uint32, 32),
    new VertexAttr(4, VertexFormat.float4, 36),
    new VertexAttr(5, VertexFormat.float1, 52),
];
export const LINE_ATTRS: Array<VertexAttr> = [
    new VertexAttr(0, VertexFormat.float3, 0),
    new VertexAttr(1, VertexFormat.float3, 12),
    new VertexAttr(2, VertexFormat.float4, 24),
    new VertexAttr(3, VertexFormat.float1, 40),
    new VertexAttr(4, VertexFormat.uint32, 44),
];
export const POINT_ATTRS: Array<VertexAttr> = [
    new VertexAttr(0, VertexFormat.float3, 0),
    new VertexAttr(1, VertexFormat.float1, 12),
    new VertexAttr(2, VertexFormat.float4, 16),
    new VertexAttr(3, VertexFormat.uint32, 32),
];

// Milestone 14, part 2: UV set 1 of the extended pipelines, a vertex
// buffer of its own (UV1_STRIDE bytes a vertex): the mesh's second UV
// layer, else a copy of the first (gpu/mesh_cache.as `uv1Buffer`), at
// location 10 (after the instance's 6 to 9).
export const UV1_ATTRS: Array<VertexAttr> = [new VertexAttr(10, VertexFormat.float2, 0)];

// Milestone 19: the lightmap coordinates of the lightmap pipelines, a
// vertex buffer of their own (LM_UV_STRIDE bytes a vertex; gpu/mesh_cache.as
// `lightmapUvBuffer`), at location 11 (after UV set 1's 10), in vertex
// buffer slot 2 (after the vertices and UV set 1).
export const LM_UV_ATTRS: Array<VertexAttr> = [new VertexAttr(11, VertexFormat.float2, 0)];

// Milestone 48: a skinned mesh's palette slots (one byte each, read as a
// vec4<u32>) and weights, a vertex buffer of their own (SKIN_STRIDE bytes a
// vertex; gpu/mesh_cache.as uploads it with the mesh), at locations 12 and
// 13 (after UV set 1's 10 and the lightmap's 11), in vertex buffer slot 1
// (pipelines.as SKIN_SLOT; a skinned item is never instanced).
export const SKIN_ATTRS: Array<VertexAttr> = [
    new VertexAttr(12, VertexFormat.uint8x4, 0),
    new VertexAttr(13, VertexFormat.float4, 4),
];

// Milestone 13: the per-instance buffer of an instanced draw (vertex buffer
// 1, stepped once per instance; engine/src/render/instances.as packs it,
// INSTANCE_STRIDE = 64 bytes an instance): the three rows of the instance's
// transform and its colour, surface.wgsl's InstIn at locations 6 to 9 (the
// surface vertex has 0 to 5).
export const INSTANCE_ATTRS: Array<VertexAttr> = [
    new VertexAttr(6, VertexFormat.float4, 0),
    new VertexAttr(7, VertexFormat.float4, 16),
    new VertexAttr(8, VertexFormat.float4, 32),
    new VertexAttr(9, VertexFormat.float4, 48),
];

// Milestone 61: the second per-instance stream of the custom shaders'
// instanced pipelines (vertex buffer 3 of gpu/custom.as, stepped once per
// instance; engine/src/render/instances.as packs it, INSTANCE_EXTRA_STRIDE
// = 32 bytes an instance): the MultiMesh's custom data (Godot's
// INSTANCE_CUSTOM) and the instance's index (INSTANCE_ID, a float), the
// template's HedraInstExtra at locations 14 and 15. No other pipeline
// reads it.
export const INSTANCE_EXTRA_ATTRS: Array<VertexAttr> = [
    new VertexAttr(14, VertexFormat.float4, 0),
    new VertexAttr(15, VertexFormat.float1, 16),
];

// Size in bytes of one attribute format.
export function vertexFormatSize(f: VertexFormat): u32 {
    switch (f) {
        case VertexFormat.float1: return 4;
        case VertexFormat.float2: return 8;
        case VertexFormat.float3: return 12;
        case VertexFormat.float4: return 16;
        case VertexFormat.uint16x4:
        case VertexFormat.sint16x4:
        case VertexFormat.float16x4: return 8;
        // uint32, the 8x4 (SKIN_ATTRS's uint8x4 too) and the 16x2 formats.
        default: return 4;
    }
}

// The depth-stencil state fields the pipelines set (format is always
// DEPTH_FORMAT, no stencil, no clamp).
export class DepthState {
    format: TextureFormat = DEPTH_FORMAT;
    write: bool;
    compare: CompareFunction;
    biasConstant: i32;
    biasSlopeScale: f32;

    constructor(write: bool, compare: CompareFunction, biasConstant: i32, biasSlopeScale: f32) {
        this.write = write;
        this.compare = compare;
        this.biasConstant = biasConstant;
        this.biasSlopeScale = biasSlopeScale;
    }
}

export function depthState(test: bool, write: bool, bias: i32): DepthState {
    return new DepthState(
        write,
        test ? CompareFunction.lessEqual : CompareFunction.always,
        bias,
        bias != 0 ? <f32>1.5 : <f32>0.0,
    );
}

// All-zero value structs, for callers that fill fields one by one.
// (A material's uv stays the identity (1, 1, 0, 0): zero would sample
// every texture at one texel.)
export function zeroMaterialUniform(): MaterialUniform {
    return MaterialUniform(VEC4_ZERO, VEC4_ZERO, VEC4_ZERO, U32x4(0, 0, 0, 0), Vec4(1, 1, 0, 0));
}
