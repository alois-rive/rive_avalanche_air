// The surface shader of the renderer (src/render/**).
//
// The module is `common.wgsl` followed by the surface code. rive-cli
// compiles each .wgsl file on its own (no includes, no runtime WGSL), so the
// common block below is inlined into both shaders/render/surface.wgsl and
// shaders/render/lines.wgsl. THE TWO COPIES MUST STAY IDENTICAL (between the
// BEGIN/END common markers).

// ---- BEGIN common.wgsl ----
// Shared uniforms and helpers, prepended to every shader.

struct Globals {
    view: mat4x4<f32>,
    proj: mat4x4<f32>,
    view_proj: mat4x4<f32>,
    camera_pos: vec4<f32>,   // xyz eye, w = 1 for orthographic
    viewport: vec4<f32>,     // width, height, 1/width, 1/height
    wire_color: vec4<f32>,
    select_color: vec4<f32>,
    active_color: vec4<f32>,
    grid: vec4<f32>,         // xyz fade center, w = fade extent
    params: vec4<u32>,       // shading mode, overlay flags, edit mode, matcap id
    fparams: vec4<f32>,      // depth pull, checker cells per UV unit, pixel scale (ssaa), w: 1 on the
                             // fallback target (target_color); a custom shader's globals hold TIME
                             // there instead, their fallback flag in params.z's bit 1 (gpu/custom.as)
};

struct ObjectU {
    model: mat4x4<f32>,
    normal: mat4x4<f32>,
    color: vec4<f32>,        // linear base color (material / random)
    params: vec4<u32>,       // selected, active, id (1-based), is edit object
    extra: vec4<u32>,        // OBJ_* bits, lightmap layer (surface.wgsl's OBJ_LIGHTMAP), layers with probes (its Probe), unused
    gi: array<vec4<f32>, 3>, // probe light, L1 SH: r, g, b, each c0 then c1 (surface.wgsl's OBJ_PROBE_GI)
    decals: vec4<u32>,       // the item's decals: indices into surface.wgsl's Decal pool, a byte each (x the first four, y the next), z how many, w its fog volumes (surface.wgsl's Fog pool entries + 1, a byte each)
    lights: vec4<u32>,       // the item's lights: entries of surface.wgsl's Lit pool, a byte each (x the first four, y the next), z how many, w how many reach it in all
};

const OBJ_HAS_WEIGHTS: u32 = 1u;
const OBJ_MIRRORED: u32 = 2u;       // a mirroring world matrix: the winding is reversed

@group(0) @binding(0) var<uniform> G: Globals;
@group(1) @binding(0) var<uniform> O: ObjectU;

const SHADE_SOLID: u32 = 0u;
const SHADE_MATCAP: u32 = 1u;
const SHADE_NORMALS: u32 = 2u;
const SHADE_FACE_ORIENT: u32 = 3u;
const SHADE_RANDOM: u32 = 4u;
const SHADE_MATERIAL: u32 = 5u;
const SHADE_UV_CHECKER: u32 = 6u;
const SHADE_WEIGHTS: u32 = 7u;
// The lit mode (surface.wgsl's `lit`): material mode's PBR under the frame's
// own lights and environment (the LitU block, surface.wgsl only).
const SHADE_LIT: u32 = 8u;
// Milestone 19: the baked light alone (frame.as SHADE_LIGHTMAP).
const SHADE_LIGHTMAP: u32 = 9u;
// Milestone 59: each surface in the colour of the lights reaching its item
// (frame.as SHADE_LIGHT_COUNT; ObjectU.lights.w).
const SHADE_LIGHT_COUNT: u32 = 10u;

const OV_SELECTION: u32 = 1u;
const OV_SEAMS: u32 = 2u;
const OV_SHARP: u32 = 4u;

// Element flags shared by surface vertices, edge and point instances.
const F_SELECTED: u32 = 1u;
const F_HIDDEN: u32 = 2u;
const F_SEAM: u32 = 4u;
const F_SHARP: u32 = 8u;
const F_MESH: u32 = 16u;      // color is resolved from flags + uniforms
const F_FADE: u32 = 32u;      // fade with distance from the grid center
const F_NO_PULL: u32 = 64u;   // do not pull towards the camera

fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c / 12.92;
    let hi = pow((c + vec3<f32>(0.055)) / 1.055, vec3<f32>(2.4));
    return select(hi, lo, c <= vec3<f32>(0.04045));
}

// Color of a mesh edge or vertex from its flags and the current mode.
fn element_color(flags: u32, fallback: vec4<f32>) -> vec4<f32> {
    if ((flags & F_MESH) == 0u) {
        return fallback;
    }
    let overlays = G.params.y;
    let edit_object = O.params.w == 1u;
    if ((flags & F_SEAM) != 0u && (overlays & OV_SEAMS) != 0u) {
        return vec4<f32>(srgb_to_linear(vec3<f32>(0.86, 0.0, 0.0)), 1.0);
    }
    if ((flags & F_SHARP) != 0u && (overlays & OV_SHARP) != 0u) {
        return vec4<f32>(srgb_to_linear(vec3<f32>(0.0, 0.85, 0.9)), 1.0);
    }
    if ((overlays & OV_SELECTION) != 0u) {
        if (edit_object) {
            if ((flags & F_SELECTED) != 0u) {
                return G.select_color;
            }
            return G.wire_color;
        }
        if (O.params.x == 1u) {
            return select(G.select_color, G.active_color, O.params.y == 1u);
        }
    }
    return G.wire_color;
}

// View-space position, optionally pulled towards the eye so lines and
// points sit on top of the surfaces they belong to.
fn to_view(p: vec3<f32>, pull: f32) -> vec4<f32> {
    var v = G.view * O.model * vec4<f32>(p, 1.0);
    v.z = v.z * (1.0 - pull);
    return v;
}

// The main pass renders into rgba16float but must behave like an 8-bit sRGB
// target, which clamps every fragment output to [0, 1] before blending and
// resolve; clamp the same way. On the rgba8unorm fallback target
// (`fparams.w == 1`, no half-float render targets) the sRGB encode an sRGB
// target would do in hardware happens here instead, so blending runs in
// sRGB space there.
fn linear_to_srgb(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 12.92;
    let hi = 1.055 * pow(c, vec3<f32>(1.0 / 2.4)) - vec3<f32>(0.055);
    return select(hi, lo, c <= vec3<f32>(0.0031308));
}

fn target_color(c: vec4<f32>) -> vec4<f32> {
    let k = clamp(c, vec4<f32>(0.0), vec4<f32>(1.0));
    if (G.fparams.w > 0.5) {
        return vec4<f32>(linear_to_srgb(k.rgb), k.a);
    }
    return k;
}
// ---- END common.wgsl ----

// ---- BEGIN spec ----
// The features a draw may use, each a constant (docs/engine/SHADING.md,
// "Specialised shaders"; hedra_engine/render/variant.as names them by the
// bits of a variant's key). This file, the ubershader, sets every one true;
// a variant (`hedra build`'s hedra_shaders/<project>/surface_<key>.wgsl, or
// the tools' compile of the same text) is this file with the constants of
// the features its draws never use set false, which the backend's compiler
// folds away. Each constant only ever ANDs into a branch's condition (or
// stops a loop) whose condition is false for every draw of the key, so a
// variant draws what the ubershader draws, bit for bit. A guard is
// `select(false, <condition>, SPEC_X)` (an early exit's `select(true,
// <condition>, SPEC_X)`), not `SPEC_X && <condition>`: the WGSL front end
// writes every `&&` and `||` out as branches and a local of their own in
// each target, which made the ubershader's tables a sixth larger, where a
// select stays one expression (its condition has no side effect to skip),
// and rive's WGSL refuses a bool `&`. SPEC_MATERIAL_MODE
// and SPEC_OTHER_MODES are not bits: a variant is drawn in the lit or the
// material shading alone, the first false in a lit one, the second false in
// every one.
const SPEC_TEX_BASE: bool = true;
const SPEC_TEX_NORMAL: bool = true;
const SPEC_TEX_MR: bool = true;
const SPEC_TEX_EMISSION: bool = true;
const SPEC_TEX_OCCLUSION: bool = true;
const SPEC_VERTEX_COLOR: bool = true;
const SPEC_EXT: bool = true;
const SPEC_UNLIT: bool = true;
const SPEC_ALPHA_MASK: bool = true;
const SPEC_ALPHA_BLEND: bool = true;
const SPEC_CLEARCOAT: bool = true;
const SPEC_SHEEN: bool = true;
const SPEC_TRANSMISSION: bool = true;
const SPEC_IRIDESCENCE: bool = true;
const SPEC_ANISOTROPY: bool = true;
const SPEC_DIFFUSE_TRANSMISSION: bool = true;
const SPEC_VOLUME: bool = true;
const SPEC_DISPERSION: bool = true;
const SPEC_EXT_LAYERS: bool = true;
const SPEC_ROUGHNESS_LAYER: bool = true;
const SPEC_LIT: bool = true;
const SPEC_LIGHTS: bool = true;
const SPEC_SHADOWS: bool = true;
const SPEC_DECALS: bool = true;
const SPEC_FOG: bool = true;
const SPEC_FOG_VOLUMES: bool = true;
const SPEC_PROBES: bool = true;
const SPEC_PROBE_GI: bool = true;
const SPEC_SSAO: bool = true;
const SPEC_SCREEN_REFRACTION: bool = true;
const SPEC_EMERGE: bool = true;
const SPEC_FADE: bool = true;
const SPEC_FACE_FLAGS: bool = true;
const SPEC_AMBIENT_FLAT: bool = true;
const SPEC_AMBIENT_GRADIENT: bool = true;
const SPEC_AMBIENT_SKY: bool = true;
const SPEC_MATERIAL_MODE: bool = true;
const SPEC_OTHER_MODES: bool = true;
// ---- END spec ----

// Triangle surfaces: all shading modes in one fragment shader, plus the
// id/depth pass used for selection outlines and label occlusion.

struct MaterialU {
    base_color: vec4<f32>,   // linear rgb, alpha
    emission: vec4<f32>,     // linear rgb * strength, w = alpha cutoff
    factors: vec4<f32>,      // metallic, roughness, an extended material's refraction_scale (milestone 62), unused
    flags: vec4<u32>,        // texture bits, alpha mode, double sided, MAT_VERTEX_COLOR* bits
    uv: vec4<f32>,           // texture coordinate scale xy, offset zw (uv1_scale, uv1_offset)
    // Milestone 14, part 2: read only by the extended pipelines (MAT_EXT,
    // the `*_ext` entries at the end of this file). By texture slot s
    // (glTF's 20, engine/src/material/pbr.as PbrSlot), xf[2s] and xf[2s+1]:
    // the slot's coordinate transform (layouts.as MaterialExtUniform).
    xf: array<vec4<f32>, 40>,
    // The extensions' factors (EXT_* below name them).
    ext: array<vec4<f32>, 8>,
};

@group(2) @binding(0) var<uniform> M: MaterialU;
@group(2) @binding(1) var t_base: texture_2d<f32>;
@group(2) @binding(2) var t_normal: texture_2d<f32>;
@group(2) @binding(3) var t_mr: texture_2d<f32>;
@group(2) @binding(4) var t_emission: texture_2d<f32>;
@group(2) @binding(5) var t_occlusion: texture_2d<f32>;
@group(2) @binding(6) var s_mat: sampler;
// Milestone 14, part 2: the textures of the extension slots, one layer each
// (material.as `extArray`), rgba8 as the files hold them; one white layer
// for a material without MAT_EXT, which never reads it.
@group(2) @binding(7) var t_ext: texture_2d_array<f32>;

const T_BASE: u32 = 1u;
const T_NORMAL: u32 = 2u;
const T_METALLIC_ROUGHNESS: u32 = 4u;
const T_EMISSION: u32 = 8u;
const T_OCCLUSION: u32 = 16u;

// MaterialU.flags.w (milestone 13; layouts.as MAT_*): the base colour is
// multiplied by the vertex colour (VsOut.color: a MultiMesh instance's, white
// for every other draw), made linear first with the second bit (Godot's
// vertex_color_use_as_albedo and vertex_color_is_srgb).
const MAT_VERTEX_COLOR: u32 = 1u;
const MAT_VERTEX_COLOR_SRGB: u32 = 2u;
// MaterialU.flags.w (milestone 14, part 2; layouts.as MAT_*): the material
// is drawn by the extended pipelines, unlit, and its roughness is a layer
// of t_ext.
const MAT_EXT: u32 = 4u;
const MAT_UNLIT: u32 = 8u;
const MAT_ROUGHNESS_LAYER: u32 = 16u;
// MaterialU.flags.w (milestone 26; layouts.as MAT_SRGB_*): the base colour
// or emission texture is a block-compressed form, which the runtime has no
// sRGB format for: sampled as stored, its colour decoded here, exactly
// (the sRGB curve, as image.as srgbToLinear), after filtering.
const MAT_SRGB_BASE: u32 = 32u;
const MAT_SRGB_EMISSION: u32 = 64u;

const ALPHA_OPAQUE: u32 = 0u;
const ALPHA_MASK: u32 = 1u;
const ALPHA_BLEND: u32 = 2u;

const PI: f32 = 3.14159265;

// ---- BEGIN shared: lights ----
// The lit mode's lights and environment (engine/src/render/lit.as packs
// them from RenderFrame.lights and .environment). It sits at binding 1 of
// group 0, outside the common block, so the lines module's group 0 keeps
// one binding and its layout does not change. Every mode binds it; only
// SHADE_LIT reads it.
//
// Milestone 59 (lights per object; engine/src/render/light_pool.as): the
// block holds the view's pool of up to MAX_FRAME_LIGHTS lights, and each
// item names up to MAX_OBJECT_LIGHTS of them in ObjectU.lights
// (`object_light`), so a pixel sums at most 8 lights whatever the scene
// holds. The budgets are light_pool.as's (wgsl_common_test.py checks).
const MAX_FRAME_LIGHTS: u32 = 64u;
const MAX_OBJECT_LIGHTS: u32 = 8u;
const MAX_SHADOW_LIGHTS: u32 = 16u;
const MAX_POOL_DIRECTIONAL: u32 = 8u;
// The lights shading's colours by the number of lights reaching an item
// (ObjectU.lights.w): grey 0, a ramp from deep blue to orange for 1 to 8,
// magenta past 8 (light_pool.as LIGHT_COUNT_COLORS, sRGB over 255).
const LIGHT_COUNT_COLORS = array<vec3<f32>, 10>(
    vec3<f32>(0.352941, 0.352941, 0.352941), // 5a5a5a
    vec3<f32>(0.168627, 0.247059, 0.600000), // 2b3f99
    vec3<f32>(0.129412, 0.400000, 0.674510), // 2166ac
    vec3<f32>(0.101961, 0.623529, 0.721569), // 1a9fb8
    vec3<f32>(0.121569, 0.631373, 0.529412), // 1fa187
    vec3<f32>(0.301961, 0.733333, 0.352941), // 4dbb5a
    vec3<f32>(0.650980, 0.831373, 0.227451), // a6d43a
    vec3<f32>(0.949020, 0.784314, 0.058824), // f2c80f
    vec3<f32>(0.949020, 0.556863, 0.058824), // f28e0f
    vec3<f32>(0.878431, 0.129412, 0.541176), // e0218a
);
const LIGHT_DIRECTIONAL: u32 = 0u;
const LIGHT_OMNI: u32 = 1u;
const LIGHT_SPOT: u32 = 2u;
// Milestone 19: a light's light_bake_mode (frame.as LIGHT_BAKE_*).
const LIGHT_BAKE_DISABLED: u32 = 0u;
const LIGHT_BAKE_STATIC: u32 = 1u;
const LIGHT_BAKE_DYNAMIC: u32 = 2u;
const TONEMAP_LINEAR: u32 = 0u;
const TONEMAP_REINHARD: u32 = 1u;
const TONEMAP_FILMIC: u32 = 2u;
const TONEMAP_ACES: u32 = 3u;
const TONEMAP_AGX: u32 = 4u;
const ENV_SKY: u32 = 1u;          // draw the sky gradient (the sky pipeline)
const ENV_AMBIENT_SKY: u32 = 2u;  // ambient from the gradient
const ENV_SSAO: u32 = 4u;         // read t_ao (milestone 12); tone.z light affect, tone.w AO channel affect
const ENV_HDR: u32 = 8u;          // keep HDR colour for the post pass's glow and tone map (lit_output)
const ENV_SCREEN_REFRACTION: u32 = 16u; // refracting glass reads t_screen (milestone 62); dirs.w its mips

struct LightU {                   // 80 bytes
    color: vec4<f32>,             // linear rgb * energy * PI, w unused
    position: vec4<f32>,          // xyz world, w = 1 / range (0 for directional)
    direction: vec4<f32>,         // xyz unit direction of travel, w = attenuation
    spot: vec4<f32>,              // x cos(spot angle), y spot angle attenuation, z specular factor, w unused
    info: vec4<u32>,              // x kind, y LIGHT_SHADOWED or 0, z LIGHT_BAKED_STATIC or 0, w shadow slot (with y)
};

struct LitU {                     // 5328 bytes
    counts: vec4<u32>,            // x the pool's light count (<= 64), y ENV_* bits, z tonemap, w unused
    ambient: vec4<f32>,           // rgb ambient (flat), w ambient energy (sky ambient)
    tone: vec4<f32>,              // x exposure, y white, with ENV_SSAO z ssao_light_affect, w ssao_ao_channel_affect
    up: vec4<f32>,                // world up (the gradient's axis)
    sky_top: vec4<f32>,
    sky_horizon: vec4<f32>,
    ground_horizon: vec4<f32>,
    ground_bottom: vec4<f32>,
    inv_view_proj: mat4x4<f32>,   // clip to world, for the sky's view rays
    dirs: vec4<u32>,              // the pool's directional lights: entries a byte each (x the first four, y the next), z how many, w t_screen's mips (ENV_SCREEN_REFRACTION)
    lights: array<LightU, 64>,    // the pool (MAX_FRAME_LIGHTS)
};

@group(0) @binding(1) var<uniform> Lit: LitU;

// How many lights the item draws (ObjectU.lights.z, at most 8).
fn object_light_count() -> u32 {
    return min(O.lights.z, MAX_OBJECT_LIGHTS);
}

// The pool entry the item draws k-th (k < object_light_count()): a byte of
// ObjectU.lights' x (k < 4) or y, the first in the low byte.
fn object_light(k: u32) -> u32 {
    let word = select(O.lights.y, O.lights.x, k < 4u);
    return min((word >> ((k & 3u) * 8u)) & 0xffu, MAX_FRAME_LIGHTS - 1u);
}

// The lights shading's sRGB colour for the item: by how many of the pool's
// lights reach it (ObjectU.lights.w), past 8 the last. (A copy in a `var`,
// which every target indexes at run time.)
fn light_count_color() -> vec3<f32> {
    var colors = LIGHT_COUNT_COLORS;
    return colors[min(O.lights.w, 9u)];
}

// How many directional lights the pool lists (LitU.dirs.z, at most 8).
fn pool_sun_count() -> u32 {
    return min(Lit.dirs.z, MAX_POOL_DIRECTIONAL);
}

// The pool entry of the pool's k-th directional light (k <
// pool_sun_count()), by object_light's byte rule on LitU.dirs.
fn pool_sun(k: u32) -> u32 {
    let word = select(Lit.dirs.y, Lit.dirs.x, k < 4u);
    return min((word >> ((k & 3u) * 8u)) & 0xffu, MAX_FRAME_LIGHTS - 1u);
}

// Shadows (milestone 10; engine/src/render/shadow.as plans them, layouts.as
// packs the block). One depth32float atlas of SHADOW_TILES tiles holds
// every shadow map of the view; a light samples it only when its
// LightU.info.y is LIGHT_SHADOWED, so a frame without a shadowed light reads
// none of this (the renderer then binds a 1 x 1 dummy map and a zero block)
// and draws what it drew before shadows existed. Like the lit block, these
// bindings sit outside the common block: the lines module's group 0 is
// untouched.
const LIGHT_SHADOWED: u32 = 1u;   // LightU.info.y
const LIGHT_BAKED_STATIC: u32 = 1u; // LightU.info.z (milestone 19): its direct light is in the lightmap
const SHADOW_TILES: u32 = 16u;

struct ShadowLightU {             // 64 bytes (ShadowLightUniform)
    params: vec4<f32>,            // x bias (texels), y normal bias (texels), z PCF radius (texels), w opacity
    splits: vec4<f32>,            // directional: far view distance of cascades 0..3
    fade: vec4<f32>,              // directional: x fade start, y max distance (view distance)
    info: vec4<u32>,              // x first tile, y tile count, z kind, w unused
};

struct ShadowTileU {              // 96 bytes (ShadowTileUniform)
    view_proj: mat4x4<f32>,       // world to the tile's clip (depth 0..1)
    rect: vec4<f32>,              // atlas UV: x, y top-left, z, w size
    texel: vec4<f32>,             // world texel size at distance d from the light: x + y * d
};

struct ShadowU {                  // 2576 bytes (ShadowUniform)
    atlas: vec4<f32>,             // x 1 / atlas texels, y atlas texels, z tiles used, w unused
    lights: array<ShadowLightU, 16>, // by shadow slot (LightU.info.w; MAX_SHADOW_LIGHTS)
    tiles: array<ShadowTileU, 16>,
};

@group(0) @binding(2) var<uniform> Shadow: ShadowU;
@group(0) @binding(3) var t_shadow: texture_depth_2d;
@group(0) @binding(4) var s_shadow: sampler_comparison;

// The sky, its image-based light and fog (milestone 11; shared/src/render/
// sky.as `skyUniform` packs the block, gpu/environment.as uploads the
// maps). Every branch that reads them tests a SKY_* bit of Sky.flags.x
// first, and a frame without a Sky resource or fog has flags 0, so it reads
// none of this (the renderer then binds 1 x 1 black dummies) and draws what
// it drew before. Outside the common block, like the lit and shadow blocks:
// the lines module's group 0 is untouched.
const SKY_DRAW_PROCEDURAL: u32 = 1u;   // layouts.as SKY_*
const SKY_DRAW_PANORAMA: u32 = 2u;
const SKY_PANORAMA_FILTER: u32 = 4u;
const SKY_IBL: u32 = 8u;
const SKY_AMBIENT_SKY: u32 = 16u;
const SKY_REFLECT_RADIANCE: u32 = 32u;
const SKY_REFLECT_OFF: u32 = 64u;
const SKY_FOG: u32 = 128u;
const SKY_FOG_DEPTH: u32 = 256u;
const SKY_SUNS: u32 = 4u;

struct SunU {                 // 32 bytes (SkySunUniform)
    direction: vec4<f32>,     // xyz sky space, towards the light; w disc size (radians)
    color: vec4<f32>,         // linear rgb * energy (no pi)
};

struct SkyU {                 // 528 bytes (SkyUniform)
    flags: vec4<u32>,         // x SKY_* bits, y radiance mips, z suns, w unused
    to_sky: mat4x4<f32>,      // frame direction -> sky space
    sky_top: vec4<f32>,       // rgb, w sky_curve
    sky_horizon: vec4<f32>,   // rgb, w sky energy
    ground_bottom: vec4<f32>, // rgb, w ground_curve
    ground_horizon: vec4<f32>,// rgb, w ground energy
    sun: vec4<f32>,           // x sun_angle_max (rad), y sun_curve, z energy_multiplier, w background energy
    ambient: vec4<f32>,       // rgb flat ambient, w sky contribution
    ibl: vec4<f32>,           // x ambient_light_energy
    fog_color: vec4<f32>,     // rgb, w sun scatter
    fog: vec4<f32>,           // x density, y sky affect, z height, w height density
    fog_depth: vec4<f32>,     // x begin, y end, z curve, w aerial perspective
    fog_origin: vec4<f32>,    // x ortho start depth, y near, z far, w 1 if ortho
    suns: array<SunU, 4>,
    sh: array<vec4<f32>, 9>,
};

// The environment's maps, the lightmap's and the probes' atlas are group 3
// (the environment group: what the renderer remakes when one of them
// changes), the blocks and the per-pass textures group 0: a bind group
// holds slots 0 to 7 only (the pinned runtime refuses a binding above 7).
@group(0) @binding(5) var<uniform> Sky: SkyU;
@group(3) @binding(0) var t_radiance: texture_cube<f32>;
@group(3) @binding(1) var t_panorama: texture_2d<f32>;
@group(3) @binding(2) var s_radiance: sampler;   // linear, linear, mip linear, clamp
@group(3) @binding(3) var s_panorama: sampler;   // linear, linear, mip nearest, repeat U, clamp V

// Screen-space ambient occlusion (milestone 12; post_effects.wgsl draws it
// before the main pass, at the render size, so a fragment reads its own
// texel): r is 1 unoccluded. lit() reads it only with ENV_SSAO, so every
// other frame binds a 1 x 1 dummy and draws what it drew before. Outside
// the common block, like the bindings above.
@group(0) @binding(6) var t_ao: texture_2d<f32>;

// Baked lighting (milestone 19, Godot's LightmapGI; shared/src/render/
// lightmap/ bakes it, gpu/lightmap.as uploads it). A lightmapped item
// (OBJ_LIGHTMAP, drawn by the lightmap entry points at the end of this
// module) reads its diffuse light from layer ObjectU.extra.y of the
// lightmap, rgba16float, linear and clamped; an item lit by the baked
// probes (OBJ_PROBE_GI) reads its diffuse ambient light from ObjectU.gi
// (`probe_light`). Both bits are 0 for every item of a frame without a
// bake, which then reads none of this (the renderer binds a 1 x 1 x 1
// black dummy) and draws what it drew before. Outside the common block,
// like every binding above: the lines module's group 0 is untouched.
const OBJ_LIGHTMAP: u32 = 4u;     // ObjectU.extra.x: lightmapped, extra.y its layer
const OBJ_PROBE_GI: u32 = 8u;     // ObjectU.extra.x: diffuse ambient light from ObjectU.gi
@group(3) @binding(4) var t_lightmap: texture_2d_array<f32>;
@group(3) @binding(5) var s_lightmap: sampler;   // linear, linear, one level, clamp

// Reflection probes (milestone 20, Godot's ReflectionProbe;
// engine/src/render/probe/data.as says how a frame reads them, number for
// number, and gpu/probes.as fills the block and the atlas). The atlas holds
// every probe's prefiltered cube: six faces across, a row per probe, a mip
// per level, each level's faces PROBE_FACE_SIZE >> level texels square.
// Probe.counts.x is 0 in every frame without a probe, which then reads none
// of this (t_probes holds a 1 x 1 dummy) and draws what it drew before:
// lit() and the extended path test the count before anything else. Outside
// the common block, like every binding above.
const PROBE_BOX: u32 = 1u;          // ProbeEntryU.info.x bits
const PROBE_INTERIOR: u32 = 2u;
const MAX_PROBES: u32 = 8u;
const PROBE_AMBIENT_DISABLED: u32 = 0u;       // ProbeEntryU.info.y (data.as PROBE_AMBIENT_*)
const PROBE_AMBIENT_ENVIRONMENT: u32 = 1u;
const PROBE_AMBIENT_CONSTANT_COLOR: u32 = 2u;
struct ProbeEntryU {                // 128 bytes (ProbeEntryUniform)
    to_local: mat4x4<f32>,          // frame world -> probe space
    extents: vec4<f32>,             // xyz half size, w blend distance
    offset: vec4<f32>,              // xyz origin offset (probe space), w intensity
    ambient: vec4<f32>,             // rgb ambient colour (linear, energy applied), w unused
    info: vec4<u32>,                // x PROBE_* bits, y ambient mode, z reflection mask, w atlas row
};
struct ProbeU {                     // 1040 bytes (ProbeUniform)
    counts: vec4<u32>,              // x probes, y levels, z face size, w unused
    probes: array<ProbeEntryU, 8>,
};
@group(0) @binding(7) var<uniform> Probe: ProbeU;
@group(3) @binding(6) var t_probes: texture_2d<f32>;   // the atlas, rgba16float, PROBE_LEVELS mips
@group(3) @binding(7) var s_probes: sampler;           // linear, linear, mip nearest, clamp

// Decals (milestone 33, Godot's Decal; engine/src/render/decal.as says how
// a frame carries them, render/decal_select.as which ones each item paints,
// gpu/decals.as fills the block and the atlas). Forward, as Godot's Mobile
// renderer draws them: the frame's pool in Decal (at most
// MAX_FRAME_DECALS), each item's list of up to MAX_OBJECT_DECALS of them
// in ObjectU.decals, painted in that order over the material's values
// before lighting (apply_decals). Their textures are layers of one atlas
// (t_decals: DECAL_LAYER_SIZE texels square, a level chain each),
// colour layers sRGB-encoded (decoded here), data layers as they are.
// ObjectU.decals.z is 0 for every item of a frame without decals, which
// then reads none of this (t_decals holds a 1 x 1 dummy) and draws what it
// drew before. In the object group (group 1: the others have no binding
// left under 8, the bind slots every target takes), outside the common
// block (the lines module's object group has the object block alone).
const MAX_FRAME_DECALS: u32 = 64u;
const MAX_OBJECT_DECALS: u32 = 8u;
const DECAL_LIVE_ALBEDO: u32 = 1u;     // DecalEntryU.flags.x bits (layouts.as DECAL_LIVE_*): level 0 only
const DECAL_LIVE_NORMAL: u32 = 2u;
const DECAL_LIVE_ORM: u32 = 4u;
const DECAL_LIVE_EMISSION: u32 = 8u;
struct DecalEntryU {                // 176 bytes (DecalEntryUniform)
    to_local: mat4x4<f32>,          // frame world -> decal space: x, z 0..1 across the box, y -1..1 bottom to top
    modulate: vec4<f32>,            // rgb linear, a its alpha times the distance fade
    fades: vec4<f32>,               // upper_fade, lower_fade, normal_fade, albedo_mix
    axis_x: vec4<f32>,              // unit X axis (frame world), w emission_energy times the distance fade
    axis_y: vec4<f32>,              // unit Y axis (it projects along -Y), w the world size of a level-0 texel
    axis_z: vec4<f32>,              // unit Z axis, w unused
    layers: vec4<u32>,              // atlas layer + 1 of albedo, normal, orm, emission (0: none)
    flags: vec4<u32>,               // x DECAL_LIVE_* bits, yzw unused
};
struct DecalU {                     // 11296 bytes (DecalUniform)
    counts: vec4<u32>,              // x decals in the pool, y the atlas's levels, zw unused
    lod: vec4<f32>,                 // x world size of a pixel at distance 1 (or, with y 1, of an orthographic pixel), zw unused
    entries: array<DecalEntryU, 64>,
};
@group(1) @binding(2) var<uniform> Decal: DecalU;
@group(1) @binding(3) var t_decals: texture_2d_array<f32>;  // the atlas, rgba8unorm, DECAL_LEVELS mips
@group(1) @binding(4) var s_decals: sampler;                // linear, linear, mip linear, clamp

// What decals paint over (lit_with's material values, before lighting):
// the albedo, metallic, roughness, the occlusion, the shading normal
// (world space) and the emission.
struct DecalSurface {
    base: vec3<f32>,
    metallic: f32,
    roughness: f32,
    occlusion: f32,
    normal: vec3<f32>,
    emission: vec3<f32>,
};

// How many decals the item paints.
fn decal_count() -> u32 {
    return min(O.decals.z, MAX_OBJECT_DECALS);
}

// The pool entry the item paints k-th.
fn decal_entry(k: u32) -> u32 {
    let word = select(O.decals.y, O.decals.x, k < 4u);
    return (word >> ((k & 3u) * 8u)) & 0xffu;
}

// The level decal `e`'s layers are read at for a fragment at `world` (no
// derivatives: the loop over an item's decals is not uniform control
// flow): the world size of the fragment's pixel (Decal.lod: at its
// distance from the eye, or an orthographic view's) over the world size of
// a level-0 texel (axis_y.w), as a level of the layer's chain.
fn decal_level(e: DecalEntryU, world: vec3<f32>) -> f32 {
    let pixel = Decal.lod.x * select(length(world - G.camera_pos.xyz), 1.0, Decal.lod.y > 0.5);
    let top = f32(max(Decal.counts.y, 1u) - 1u);
    return clamp(log2(max(pixel / max(e.axis_y.w, 1e-6), 1.0)), 0.0, top);
}

// Layer `layer` (+ 1) of the atlas at `uv`: at `level`, or at level 0 for
// a live layer (`live`: its level 0 alone is drawn).
fn decal_texel(layer: u32, uv: vec2<f32>, level: f32, live: bool) -> vec4<f32> {
    return textureSampleLevel(t_decals, s_decals, uv, i32(layer - 1u), select(level, 0.0, live));
}

// The item's decals painted over `surf` at `world` (n_geo: the geometric
// normal, which normal_fade reads), in their order, Godot's way (its
// scene shader's decal loop): inside a decal's box, the vertical fade
// (pow(1 - |y|, upper or lower fade)) and the normal fade; the albedo
// (sRGB-decoded, times modulate, whose alpha holds the distance fade)
// mixed over the base by its alpha times albedo_mix; the normal map and
// the ORM map only with an albedo, mixed by its alpha (the normal's green
// flipped and its z rebuilt, along the box's axes: Godot's decal_normal
// .xzy); the emission added (sRGB-decoded, times modulate's colour and
// the energy, which holds the distance fade). Then roughness and metallic
// back in their ranges.
fn apply_decals(world: vec3<f32>, n_geo: vec3<f32>, surf: DecalSurface) -> DecalSurface {
    var out_s = surf;
    let count = decal_count();
    for (var k = 0u; k < count; k++) {
        let e = Decal.entries[min(decal_entry(k), MAX_FRAME_DECALS - 1u)];
        let uvw = (e.to_local * vec4<f32>(world, 1.0)).xyz;
        // Inside the box, asked so that a point that is not a number
        // (a collapsed box's, which the CPU leaves out of the pool
        // already) counts as outside: every comparison with NaN is false.
        if (!(all(uvw >= vec3<f32>(0.0, -1.0, 0.0)) && all(uvw <= vec3<f32>(1.0)))) {
            continue;
        }
        var fade = pow(1.0 - abs(uvw.y), select(e.fades.y, e.fades.x, uvw.y > 0.0));
        if (e.fades.z > 0.0) {
            fade *= smoothstep(e.fades.z, 1.0, dot(n_geo, e.axis_y.xyz) * 0.5 + 0.5);
        }
        let uv = uvw.xz;
        let level = decal_level(e, world);
        let live = e.flags.x;
        if (e.layers.x > 0u) {
            let t = decal_texel(e.layers.x, uv, level, (live & DECAL_LIVE_ALBEDO) != 0u);
            let a = vec4<f32>(srgb_to_linear(t.rgb), t.a) * e.modulate;
            let alpha = a.a * fade;
            out_s.base = mix(out_s.base, a.rgb, alpha * e.fades.w);
            if (e.layers.y > 0u) {
                let tn = decal_texel(e.layers.y, uv, level, (live & DECAL_LIVE_NORMAL) != 0u);
                let nx = tn.x * 2.0 - 1.0;
                let ny = 1.0 - tn.y * 2.0;
                let nz = sqrt(max(0.0, 1.0 - nx * nx - ny * ny));
                let dn = normalize(e.axis_x.xyz * nx + e.axis_y.xyz * nz + e.axis_z.xyz * ny);
                out_s.normal = normalize(mix(out_s.normal, dn, alpha));
            }
            if (e.layers.z > 0u) {
                let orm = decal_texel(e.layers.z, uv, level, (live & DECAL_LIVE_ORM) != 0u);
                out_s.occlusion = mix(out_s.occlusion, orm.r, alpha);
                out_s.roughness = mix(out_s.roughness, orm.g, alpha);
                out_s.metallic = mix(out_s.metallic, orm.b, alpha);
            }
        }
        if (e.layers.w > 0u) {
            let te = decal_texel(e.layers.w, uv, level, (live & DECAL_LIVE_EMISSION) != 0u);
            out_s.emission += srgb_to_linear(te.rgb) * e.modulate.rgb * e.axis_x.w * fade;
        }
    }
    out_s.roughness = clamp(out_s.roughness, 0.045, 1.0);
    out_s.metallic = clamp(out_s.metallic, 0.0, 1.0);
    return out_s;
}
// ---- END shared: lights ----

// ---- BEGIN shared: screen ----
// Milestone 62 (engine/src/render/screen.as; gpu/screen_chain.as makes it):
// the screen texture, the copy of the opaque picture of a frame whose main
// pass is drawn in two (post.as PostPlan `split`), rgba16float with
// Lit.dirs.w mips, at the object group's binding 6 (groups 0 and 3 are
// full), sampled with s_radiance. The extended materials that refract read
// it behind ENV_SCREEN_REFRACTION alone (ext_refracted); every other draw
// binds the view's or a 1 x 1 dummy and reads nothing.
@group(1) @binding(6) var t_screen: texture_2d<f32>;
// ---- END shared: screen ----

// ---- BEGIN shared: vertex_input ----
struct VsIn {
    @location(0) pos: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) flags: u32,
    @location(4) tangent: vec4<f32>,
    @location(5) weight: f32,
};
// ---- END shared: vertex_input ----

struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) world: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) @interpolate(flat) flags: u32,
    @location(4) tangent: vec4<f32>,
    @location(5) weight: f32,
    // The vertex colour (milestone 13): a MultiMesh instance's colour, white
    // for every other draw. Read only by a material with MAT_VERTEX_COLOR.
    @location(6) color: vec4<f32>,
};

@vertex
fn vs_surface(in: VsIn) -> VsOut {
    let world = O.model * vec4<f32>(in.pos, 1.0);
    var out: VsOut;
    out.clip = G.view_proj * world;
    out.world = world.xyz;
    out.normal = normalize((O.normal * vec4<f32>(in.normal, 0.0)).xyz);
    out.uv = in.uv;
    out.flags = in.flags;
    // A mirroring world matrix reverses cross(n, t), so the bitangent's
    // sign flips with it; otherwise a normal map's green channel would be
    // inverted on a node scaled (-1, 1, 1).
    let mirror = select(1.0, -1.0, (O.extra.x & OBJ_MIRRORED) != 0u);
    out.tangent = vec4<f32>(normalize((O.model * vec4<f32>(in.tangent.xyz, 0.0)).xyz), in.tangent.w * mirror);
    out.weight = in.weight;
    out.color = vec4<f32>(1.0);
    return out;
}

// ---- BEGIN shared: instance_input ----
// GPU instancing (milestone 13: a MultiMeshInstance3D; shared/src/render/
// instances.as packs the buffer, 64 bytes an instance, and layouts.as
// INSTANCE_ATTRS reads it): the rows of the instance's 3 x 4 transform (the
// basis's row r, then the origin's component r: Godot's MultiMesh buffer)
// and its colour, stepped once per instance in vertex buffer 1.
struct InstIn {
    @location(6) row0: vec4<f32>,
    @location(7) row1: vec4<f32>,
    @location(8) row2: vec4<f32>,
    @location(9) color: vec4<f32>,
};

// VsOut.flags: the instance's transform mirrors (a negative determinant),
// so the winding of its triangles is reversed on top of what OBJ_MIRRORED
// says of the item's (layouts.as F_INSTANCE_MIRRORED). No vertex of a mesh
// carries it: the element flags stop at F_NO_PULL (64).
const F_INSTANCE_MIRRORED: u32 = 128u;
// ---- END shared: instance_input ----

// vs_surface for one instance: the mesh point through the instance's
// transform into the item's space, then O.model as for one copy. The normal
// goes through the cofactor matrix of the instance's basis (its inverse
// transpose times the determinant), negated when the determinant is
// negative so the scale stays positive, then through O.normal; the tangent
// through the basis, then O.model.
@vertex
fn vs_surface_instanced(in: VsIn, inst: InstIn) -> VsOut {
    let p1 = vec4<f32>(in.pos, 1.0);
    let local = vec3<f32>(dot(inst.row0, p1), dot(inst.row1, p1), dot(inst.row2, p1));
    let world = O.model * vec4<f32>(local, 1.0);
    // The basis's columns (its X, Y and Z axes).
    let bx = vec3<f32>(inst.row0.x, inst.row1.x, inst.row2.x);
    let by = vec3<f32>(inst.row0.y, inst.row1.y, inst.row2.y);
    let bz = vec3<f32>(inst.row0.z, inst.row1.z, inst.row2.z);
    let det = dot(bx, cross(by, bz));
    let flip = det < 0.0;
    let cofactor = mat3x3<f32>(cross(by, bz), cross(bz, bx), cross(bx, by));
    let n_local = cofactor * in.normal * select(1.0, -1.0, flip);
    let t_local = mat3x3<f32>(bx, by, bz) * in.tangent.xyz;
    var out: VsOut;
    out.clip = G.view_proj * world;
    out.world = world.xyz;
    out.normal = normalize((O.normal * vec4<f32>(n_local, 0.0)).xyz);
    out.uv = in.uv;
    out.flags = in.flags | select(0u, F_INSTANCE_MIRRORED, flip);
    let mirror = select(1.0, -1.0, ((O.extra.x & OBJ_MIRRORED) != 0u) != flip);
    out.tangent = vec4<f32>(normalize((O.model * vec4<f32>(t_local, 0.0)).xyz), in.tangent.w * mirror);
    out.weight = in.weight;
    out.color = inst.color;
    return out;
}

// Whether the winding of the fragment's triangle is reversed: the item's
// world matrix mirrors, or (an instanced draw) its instance's transform does,
// but not both.
fn mirrored(in: VsOut) -> bool {
    return ((O.extra.x & OBJ_MIRRORED) != 0u) != ((in.flags & F_INSTANCE_MIRRORED) != 0u);
}

// Blender's weight ramp (display space, linearized): blue 0, cyan 0.25,
// green 0.5, yellow 0.75, red 1. Negative weights are the sentinel for
// vertices outside the group: the "zero weights: active" near-black.
// Mirrors `weightRamp` in engine/src/authoring/model_view/options.as.
fn weight_color(w: f32) -> vec3<f32> {
    if (w < 0.0) {
        return srgb_to_linear(vec3<f32>(0.0, 0.0, 0.08));
    }
    var stops = array<vec3<f32>, 5>(
        vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 1.0, 1.0), vec3<f32>(0.0, 1.0, 0.0),
        vec3<f32>(1.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0));
    let t = clamp(w, 0.0, 1.0) * 4.0;
    let i = min(i32(floor(t)), 3);
    let f = t - f32(i);
    return srgb_to_linear(mix(stops[i], stops[i + 1], f));
}

// Blender-workbench-like studio light: key from the upper left, cool fill
// from the right, a low back light, a small specular and a rim.
fn studio(n: vec3<f32>, base: vec3<f32>) -> vec3<f32> {
    let l1 = normalize(vec3<f32>(-0.45, 0.55, 0.70));
    let l2 = normalize(vec3<f32>(0.75, 0.15, 0.45));
    let l3 = normalize(vec3<f32>(0.10, -0.70, 0.35));
    let v = vec3<f32>(0.0, 0.0, 1.0);
    var c = base * 0.28;
    c += base * max(dot(n, l1), 0.0) * 0.85;
    c += base * max(dot(n, l2), 0.0) * 0.35 * vec3<f32>(0.90, 0.95, 1.05);
    c += base * max(dot(n, l3), 0.0) * 0.22;
    let h = normalize(l1 + v);
    c += vec3<f32>(1.0) * pow(max(dot(n, h), 0.0), 40.0) * 0.18;
    let rim = pow(1.0 - max(dot(n, v), 0.0), 3.0);
    c += base * rim * 0.25;
    return c;
}

fn matcap(n: vec3<f32>, id: u32) -> vec3<f32> {
    let v = vec3<f32>(0.0, 0.0, 1.0);
    if (id == 1u) {
        // Chrome: reflect into a sky/ground gradient with a bright horizon.
        let r = reflect(-v, n);
        let sky = mix(vec3<f32>(0.55, 0.62, 0.72), vec3<f32>(0.18, 0.30, 0.55), clamp(r.y, 0.0, 1.0));
        let ground = mix(vec3<f32>(0.40, 0.36, 0.32), vec3<f32>(0.08, 0.07, 0.06), clamp(-r.y, 0.0, 1.0));
        var c = select(ground, sky, r.y >= 0.0);
        c += vec3<f32>(0.6) * exp(-abs(r.y) * 12.0) * 0.7;
        let fres = pow(1.0 - max(dot(n, v), 0.0), 4.0);
        return c * 0.9 + vec3<f32>(fres * 0.25);
    }
    if (id == 2u) {
        // Skin: warm wrap lighting with a red rim.
        let base = srgb_to_linear(vec3<f32>(0.93, 0.74, 0.62));
        let l = normalize(vec3<f32>(-0.4, 0.6, 0.7));
        let wrap = pow(dot(n, l) * 0.5 + 0.5, 1.5);
        let rim = pow(1.0 - max(dot(n, v), 0.0), 3.0);
        return base * (0.25 + 0.75 * wrap) + vec3<f32>(0.45, 0.08, 0.05) * rim * 0.5
            + vec3<f32>(1.0) * pow(max(dot(n, normalize(l + v)), 0.0), 24.0) * 0.12;
    }
    // Clay (default): soft red-brown sphere lit from the upper left.
    let base = srgb_to_linear(vec3<f32>(0.80, 0.62, 0.52));
    let l = normalize(vec3<f32>(-0.4, 0.6, 0.7));
    let d = max(dot(n, l), 0.0);
    let spec = pow(max(dot(n, normalize(l + v)), 0.0), 30.0) * 0.3;
    return base * (0.22 + 0.78 * d) + vec3<f32>(spec);
}

// HSV to RGB (h in degrees, s and v 0..1).
fn hsv(h: f32, s: f32, v: f32) -> vec3<f32> {
    let k = (vec3<f32>(5.0, 3.0, 1.0) + vec3<f32>(h / 60.0)) % 6.0;
    let f = clamp(min(k, vec3<f32>(4.0) - k), vec3<f32>(0.0), vec3<f32>(1.0));
    return v * (vec3<f32>(1.0) - s * f);
}

// Blender-like UV checker: light/dark cells with a subtle per-cell hue so
// orientation and scale read, plus a dark line on the 0..1 tile borders.
fn checker(uv: vec2<f32>) -> vec3<f32> {
    let s = G.fparams.y;
    let cell = floor(uv * s);
    let ci = vec2<i32>(cell);
    let odd = (ci.x + ci.y) & 1;
    let k = (bitcast<u32>(ci.x) * 73856093u) ^ (bitcast<u32>(ci.y) * 19349663u);
    let hue = f32(k % 360u);
    let value = select(0.74, 0.40, odd == 1);
    var c = hsv(hue, 0.18, value);
    // A thin (about two pixel) dark line on the 0..1 tile borders.
    let tile = abs(fract(uv) - vec2<f32>(0.5));
    let w = fwidth(uv) * 1.0 + vec2<f32>(1e-4);
    let border = any(tile > vec2<f32>(0.5) - w);
    c = select(c, c * 0.35, border);
    return srgb_to_linear(c);
}

// ---------------------------------------------------------------- PBR

fn tex_uv(uv: vec2<f32>) -> vec2<f32> {
    // UV origin is bottom-left (Blender); image rows are stored top-first.
    return vec2<f32>(uv.x, 1.0 - uv.y);
}

struct Samples {
    base: vec4<f32>,
    normal: vec3<f32>,
    mr: vec4<f32>,
    emission: vec3<f32>,
    occlusion: f32,
};

// All texture reads happen here, in uniform control flow (the branches
// depend on the material uniform only) and before any discard.
// rive has no sRGB texture formats. Base color and emission textures (sRGB
// images) are uploaded as rgba16float holding the decoded linear values
// (src/render/gpu/materials.as), so the samples below are linear, as an
// sRGB texture's samples would be.
// Milestone 14: the material's own scale and offset (Godot's uv1_scale and
// uv1_offset) move every texture it samples. The default (1, 1, 0, 0) is
// exact, so a material without them samples where it did before.
fn material_uv(uv: vec2<f32>) -> vec2<f32> {
    return tex_uv(uv) * M.uv.xy + M.uv.zw;
}

// A base colour texel as linear colour: as sampled (an rgba16float upload
// holds linear values already), or sRGB-decoded for a compressed form
// (MAT_SRGB_BASE).
fn decoded_base(t: vec4<f32>) -> vec4<f32> {
    if ((M.flags.w & MAT_SRGB_BASE) != 0u) {
        return vec4<f32>(srgb_to_linear(t.rgb), t.a);
    }
    return t;
}

fn decoded_emission(t: vec3<f32>) -> vec3<f32> {
    if ((M.flags.w & MAT_SRGB_EMISSION) != 0u) {
        return srgb_to_linear(t);
    }
    return t;
}

fn sample_material(uv_in: vec2<f32>) -> Samples {
    let uv = material_uv(uv_in);
    var s: Samples;
    s.base = M.base_color;
    if (select(false, (M.flags.x & T_BASE) != 0u, SPEC_TEX_BASE)) {
        s.base *= decoded_base(textureSample(t_base, s_mat, uv));
    }
    s.normal = vec3<f32>(0.0, 0.0, 1.0);
    if (select(false, (M.flags.x & T_NORMAL) != 0u, SPEC_TEX_NORMAL)) {
        s.normal = normalize(textureSample(t_normal, s_mat, uv).xyz * 2.0 - vec3<f32>(1.0));
    }
    s.mr = vec4<f32>(1.0);
    if (select(false, (M.flags.x & T_METALLIC_ROUGHNESS) != 0u, SPEC_TEX_MR)) {
        s.mr = textureSample(t_mr, s_mat, uv);
    }
    s.emission = M.emission.rgb;
    if (select(false, (M.flags.x & T_EMISSION) != 0u, SPEC_TEX_EMISSION)) {
        s.emission *= decoded_emission(textureSample(t_emission, s_mat, uv).rgb);
    }
    s.occlusion = 1.0;
    if (select(false, (M.flags.x & T_OCCLUSION) != 0u, SPEC_TEX_OCCLUSION)) {
        s.occlusion = textureSample(t_occlusion, s_mat, uv).r;
    }
    return s;
}

// sample_material with the vertex colour applied to the base colour when
// the material asks for it (MAT_VERTEX_COLOR), as Godot's albedo takes
// COLOR; every other material's samples are sample_material's, untouched.
fn surface_samples(in: VsOut) -> Samples {
    var s = sample_material(in.uv);
    if (select(false, (M.flags.w & MAT_VERTEX_COLOR) != 0u, SPEC_VERTEX_COLOR)) {
        var c = in.color;
        if ((M.flags.w & MAT_VERTEX_COLOR_SRGB) != 0u) {
            c = vec4<f32>(srgb_to_linear(c.rgb), c.a);
        }
        s.base = s.base * c;
    }
    return s;
}

// ---- BEGIN shared: brdf ----
fn d_ggx(nh: f32, a2: f32) -> f32 {
    let d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

// Smith height-correlated visibility (already divided by 4 nl nv).
fn v_smith(nl: f32, nv: f32, a2: f32) -> f32 {
    let gv = nl * sqrt(nv * nv * (1.0 - a2) + a2);
    let g_l = nv * sqrt(nl * nl * (1.0 - a2) + a2);
    return 0.5 / max(gv + g_l, 1e-4);
}

fn f_schlick(f0: vec3<f32>, vh: f32) -> vec3<f32> {
    return f0 + (vec3<f32>(1.0) - f0) * pow(1.0 - vh, 5.0);
}
// ---- END shared: brdf ----

fn light(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, radiance: vec3<f32>,
         diffuse: vec3<f32>, f0: vec3<f32>, a2: f32) -> vec3<f32> {
    let nl = dot(n, l);
    if (nl <= 0.0) {
        return vec3<f32>(0.0);
    }
    let h = normalize(l + v);
    let nh = max(dot(n, h), 0.0);
    let vh = max(dot(v, h), 0.0);
    let nv = max(dot(n, v), 1e-4);
    let f = f_schlick(f0, vh);
    let spec = d_ggx(nh, a2) * v_smith(nl, nv, a2) * f;
    return ((vec3<f32>(1.0) - f) * diffuse / PI + spec) * radiance * nl;
}

// ---- BEGIN shared: light_specular ----
// light() with the specular term scaled by `specular` (Godot's
// light_specular), for the lit mode; material mode keeps light() as it is.
// The diffuse term is plain Lambert, not scaled by (1 - F) as in light():
// Godot's diffuse is, so a white surface square to a directional light of
// energy 1 shows its albedo (RSCN.md, Rendering) rather than 4% less.
fn light_specular(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, radiance: vec3<f32>,
                  diffuse: vec3<f32>, f0: vec3<f32>, a2: f32, specular: f32) -> vec3<f32> {
    let nl = dot(n, l);
    if (nl <= 0.0) {
        return vec3<f32>(0.0);
    }
    let h = normalize(l + v);
    let nh = max(dot(n, h), 0.0);
    let vh = max(dot(v, h), 0.0);
    let nv = max(dot(n, v), 1e-4);
    let f = f_schlick(f0, vh);
    let spec = d_ggx(nh, a2) * v_smith(nl, nv, a2) * f;
    return (diffuse / PI + spec * specular) * radiance * nl;
}
// ---- END shared: light_specular ----

// Built-in environment: a sky/ground gradient with a bright horizon band,
// indexed by the world-up component of a direction.
fn env(up: f32) -> vec3<f32> {
    let sky = vec3<f32>(0.48, 0.58, 0.78);
    let ground = vec3<f32>(0.26, 0.22, 0.18);
    var c = mix(ground, sky, clamp(up * 0.5 + 0.5, 0.0, 1.0));
    c += vec3<f32>(0.22, 0.21, 0.19) * exp(-abs(up) * 4.0);
    return c;
}

// glTF metallic-roughness shading under a fixed studio rig (view space,
// so it follows the camera like the workbench) and the environment above.
fn pbr(in: VsOut, front: bool, s: Samples) -> vec3<f32> {
    let metallic = clamp(M.factors.x * s.mr.b, 0.0, 1.0);
    let roughness = clamp(M.factors.y * s.mr.g, 0.045, 1.0);
    let a2 = roughness * roughness * roughness * roughness;
    let base = s.base.rgb;
    let diffuse = base * (1.0 - metallic);
    let f0 = mix(vec3<f32>(0.04), base, metallic);

    // Shading normal in view space, perturbed by the normal map.
    var n_w = select(-normalize(in.normal), normalize(in.normal), front);
    if (select(false, (M.flags.x & T_NORMAL) != 0u, SPEC_TEX_NORMAL)) {
        var t_w = in.tangent.xyz;
        t_w = normalize(t_w - n_w * dot(n_w, t_w));
        let b_w = cross(n_w, t_w) * in.tangent.w;
        n_w = normalize(t_w * s.normal.x + b_w * s.normal.y + n_w * s.normal.z);
    }
    let n = normalize((G.view * vec4<f32>(n_w, 0.0)).xyz);
    let pos_v = (G.view * vec4<f32>(in.world, 1.0)).xyz;
    let v = select(normalize(-pos_v), vec3<f32>(0.0, 0.0, 1.0), G.camera_pos.w > 0.5);
    let up = normalize((G.view * vec4<f32>(0.0, 0.0, 1.0, 0.0)).xyz);

    var c = vec3<f32>(0.0);
    c += light(n, v, normalize(vec3<f32>(-0.45, 0.55, 0.70)), vec3<f32>(1.0, 0.97, 0.92) * 2.6, diffuse, f0, a2);
    c += light(n, v, normalize(vec3<f32>(0.75, 0.15, 0.45)), vec3<f32>(0.85, 0.90, 1.0) * 0.9, diffuse, f0, a2);
    c += light(n, v, normalize(vec3<f32>(0.30, 0.55, -0.60)), vec3<f32>(1.0) * 1.3, diffuse, f0, a2);

    // Hemispherical ambient: diffuse from the normal, specular from the
    // reflection blurred by roughness and weighted by roughness-aware
    // Fresnel, both attenuated by occlusion.
    let nv = max(dot(n, v), 1e-4);
    let r = reflect(-v, n);
    let irradiance = env(dot(n, up)) * 0.8;
    let sharp = env(dot(r, up));
    let blurred = mix(sharp, env(0.0) * 0.85, roughness);
    let f_amb = f0 + (max(vec3<f32>(1.0 - roughness), f0) - f0) * pow(1.0 - nv, 5.0);
    let ambient = diffuse * irradiance + blurred * f_amb * (1.0 - 0.5 * roughness);
    c += ambient * s.occlusion;
    c += s.emission;
    return c;
}

// ---- BEGIN shared: lighting ----
// ---------------------------------------------------------------- lit mode

// Godot 4's ProceduralSkyMaterial with its default curves (sky_curve 0.15,
// ground_curve 0.02) and no sun disc: the gradient from the horizon to the
// zenith above, and to the nadir below, by the angle from `Lit.up`.
fn sky(dir: vec3<f32>) -> vec3<f32> {
    let a = acos(clamp(dot(normalize(dir), Lit.up.xyz), -1.0, 1.0));
    if (a <= PI * 0.5) {
        let c = 1.0 - a / (PI * 0.5);
        // pow of 0 is undefined in WGSL: straight up the base is kept
        // just above it (the result is 1 either way).
        let k = clamp(1.0 - pow(max(1.0 - c, 1e-6), 1.0 / 0.15), 0.0, 1.0);
        return mix(Lit.sky_horizon.rgb, Lit.sky_top.rgb, k);
    }
    let c = (a - PI * 0.5) / (PI * 0.5);
    let k = clamp(1.0 - pow(max(1.0 - c, 1e-6), 1.0 / 0.02), 0.0, 1.0);
    return mix(Lit.ground_horizon.rgb, Lit.ground_bottom.rgb, k);
}

// Godot 4's tone maps (tonemap_mode). Negative inputs are clamped as Godot
// does before its curves. The curves below are also post_effects.wgsl's,
// which tone maps after the glow (milestone 12): THE TWO COPIES MUST STAY
// IDENTICAL (between the BEGIN/END tone curves markers;
// engine/tools/wgsl_common_test.py checks). post.as `toneCurve` is their
// CPU reference.
// ---- BEGIN tone curves ----
fn filmic_curve(x: vec3<f32>) -> vec3<f32> {
    // Godot's tonemap_filmic: exposure bias 2 baked into A and B.
    let a = 0.22 * 4.0;
    let b = 0.30 * 2.0;
    let c = 0.10;
    let d = 0.20;
    let e = 0.01;
    let f = 0.30;
    return (x * (a * x + vec3<f32>(c * b)) + vec3<f32>(d * e)) / (x * (a * x + vec3<f32>(b)) + vec3<f32>(d * f))
        - vec3<f32>(e / f);
}

// Godot 4's tonemap_aces (Stephen Hill's fit of the ACES RRT and ODT, with
// an exposure bias of 1.8) of an exposed colour `c`, divided by the curve
// at `white` so that `white` maps to 1.
fn aces_curve(c: vec3<f32>, white: f32) -> vec3<f32> {
    let k = 1.8;
    let x = vec3<f32>(
        k * dot(vec3<f32>(0.59719, 0.35458, 0.04823), c),
        k * dot(vec3<f32>(0.07600, 0.90834, 0.01566), c),
        k * dot(vec3<f32>(0.02840, 0.13383, 0.83777), c));
    let t = (x * (x + vec3<f32>(0.0245786)) - vec3<f32>(0.000090537))
        / (x * (0.983729 * x + vec3<f32>(0.432951)) + vec3<f32>(0.238081));
    let o = vec3<f32>(
        dot(vec3<f32>(1.60475, -0.53108, -0.07367), t),
        dot(vec3<f32>(-0.10208, 1.10813, -0.00605), t),
        dot(vec3<f32>(-0.00327, -0.07276, 1.07602), t));
    let w = k * white;
    let wt = (w * (w + 0.0245786) - 0.000090537) / (w * (0.983729 * w + 0.432951) + 0.238081);
    return o / wt;
}

// Godot 4.4's tonemap_agx (an approximation of EaryChow's AgX, Blender's):
// the colour kept at 2e-10 at least (so the log below is finite), the
// combined sRGB to Rec. 2020 and AgX inset matrix, a log2 encoding between
// -12.4739311883324 and 4.02606881166759 stops (middle grey 0.18 at
// -10 .. +6.5 stops), the 6th-order fit of the AgX sigmoid, back to linear
// with a 2.4 power, then the combined outset and Rec. 2020 to sRGB matrix.
// It takes no white point, and may return negatives (clamped before the
// encode, as Godot's are). The matrices are Godot's GLSL mat3 literals, by
// columns in WGSL as in GLSL. pow of 0 is undefined in WGSL, so its base is
// kept at 1e-10 at least (1e-24 after the power: 0 in any target).
fn agx_curve(c: vec3<f32>) -> vec3<f32> {
    let inset = mat3x3<f32>(
        0.54490813676363087053, 0.14044005884001287035, 0.088827411851915368603,
        0.37377945959812267119, 0.75410959864013760045, 0.17887712465043811023,
        0.081384976686407536266, 0.10543358536857773485, 0.73224999956948382528);
    let outset = mat3x3<f32>(
        1.9645509602733325934, -0.29932243390911083839, -0.16436833806080403409,
        -0.85585845117807513559, 1.3264510741502356555, -0.23822464068860595117,
        -0.10886710826831608324, -0.027084020983874825605, 1.402665347143271889);
    let min_ev = -12.4739311883324;
    let max_ev = 4.02606881166759;
    var v = inset * max(c, vec3<f32>(2e-10));
    v = (clamp(log2(v), vec3<f32>(min_ev), vec3<f32>(max_ev)) - vec3<f32>(min_ev)) / (max_ev - min_ev);
    let x2 = v * v;
    let x4 = x2 * x2;
    let p = 0.021 * v + 4.0111 * x2 - 25.682 * x2 * v + 70.359 * x4 - 74.778 * x4 * v + 27.069 * x4 * x2;
    return outset * pow(max(p, vec3<f32>(1e-10)), vec3<f32>(2.4));
}
// ---- END tone curves ----

fn tonemap(c_in: vec3<f32>) -> vec3<f32> {
    let c = max(c_in * Lit.tone.x, vec3<f32>(0.0));
    let white = Lit.tone.y;
    let mode = Lit.counts.z;
    if (mode == TONEMAP_REINHARD) {
        return (white * c + c) / (c * white + vec3<f32>(white));
    }
    if (mode == TONEMAP_FILMIC) {
        return filmic_curve(c) / filmic_curve(vec3<f32>(white));
    }
    if (mode == TONEMAP_ACES) {
        return aces_curve(c, white);
    }
    if (mode == TONEMAP_AGX) {
        return agx_curve(c);
    }
    return c;
}

// ---------------------------------------------------------------- emerge

// Hedra's emerge (tree/node.as GeometryInstance3D.emerge; not Godot's): an
// item with OBJ_EMERGE is coming out of a fog, ObjectU.normal[0].w how
// far, 0 to 1 (the normal matrix's fourth row, which no normal moved
// through it reads: only xyz is kept), and ObjectU.extra.w the fog's colour
// (sRGB bytes, red low; ObjectU.decals.w is the item's fog volumes,
// milestone 37). Each point takes a threshold n, two octaves of value noise fixed
// in world space (EMERGE_SCALE cells a metre, so that neighbouring items
// share their wisps and nothing seems to move), its edge stippled by
// EMERGE_DITHER of a screen-space noise (interleaved gradient noise) so the
// cut reads soft; it shows once the item's emerge e passes n, first in the
// fog's colour, and clears to its own colour over EMERGE_EDGE more of e: its
// reveal is (e (1 + EMERGE_EDGE) - n) / EMERGE_EDGE, 0 or less not drawn
// (every pass discards it: the shadow, the SSAO's depth and the ids follow
// what is shown; the shadow pass has no pixel of the view, so its edge is
// not stippled), 1 or more clear, which every point is at e = 1. Every
// other item reads none of this.
const OBJ_EMERGE: u32 = 32u;      // ObjectU.extra.x: emerging, normal[0].w how far, extra.w the fog
const EMERGE_SCALE: f32 = 1.3;
const EMERGE_EDGE: f32 = 0.8;
const EMERGE_DITHER: f32 = 0.12;

// A number in 0..1 for a lattice point (Dave Hoskins' hash without sine).
fn emerge_hash(p: vec3<f32>) -> f32 {
    var q = fract(p * 0.1031);
    q += dot(q, q.zyx + vec3<f32>(31.32));
    return fract((q.x + q.y) * q.z);
}

// Value noise in 0..1, smooth between the lattice points.
fn emerge_noise(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (vec3<f32>(3.0) - 2.0 * f);
    let a = mix(
        mix(emerge_hash(i), emerge_hash(i + vec3<f32>(1.0, 0.0, 0.0)), u.x),
        mix(emerge_hash(i + vec3<f32>(0.0, 1.0, 0.0)), emerge_hash(i + vec3<f32>(1.0, 1.0, 0.0)), u.x), u.y);
    let b = mix(
        mix(emerge_hash(i + vec3<f32>(0.0, 0.0, 1.0)), emerge_hash(i + vec3<f32>(1.0, 0.0, 1.0)), u.x),
        mix(emerge_hash(i + vec3<f32>(0.0, 1.0, 1.0)), emerge_hash(i + vec3<f32>(1.0, 1.0, 1.0)), u.x), u.y);
    return mix(a, b, u.z);
}

// The reveal of the point at `world` (above), drawn at framebuffer pixel
// `pixel` (none: a negative x, the shadow pass): 1 for an item not emerging.
fn emerge_reveal(world: vec3<f32>, pixel: vec2<f32>) -> f32 {
    if (select(true, (O.extra.x & OBJ_EMERGE) == 0u, SPEC_EMERGE)) {
        return 1.0;
    }
    let e = O.normal[0].w;
    let w = world * EMERGE_SCALE;
    // (the octaves' sum crowds around 0.5: spread it over 0..1)
    var n = smoothstep(0.2, 0.8, emerge_noise(w) * 0.65 + emerge_noise(w * 2.7 + vec3<f32>(17.1)) * 0.35);
    if (pixel.x >= 0.0) {
        let ign = fract(52.9829189 * fract(dot(floor(pixel), vec2<f32>(0.06711056, 0.00583715))));
        n = clamp(n + (ign - 0.5) * EMERGE_DITHER, 0.0, 1.0);
    }
    return (e * (1.0 + EMERGE_EDGE) - n) / EMERGE_EDGE;
}

// The point's shown colour `c` (lit and tone mapped, as lit() returns it)
// under the fog it is clearing from, at reveal `r` (emerge_reveal, above 0).
fn emerge_tint(c: vec3<f32>, r: f32) -> vec3<f32> {
    if (select(true, (O.extra.x & OBJ_EMERGE) == 0u || r >= 1.0, SPEC_EMERGE)) {
        return c;
    }
    let fog = tonemap(srgb_to_linear(unpack4x8unorm(O.extra.w).rgb));
    return mix(fog, c, smoothstep(0.0, 1.0, r));
}

// ---------------------------------------------------------------- fade

// Hedra's fade (tree/node.as GeometryInstance3D.fade and fade_color; not
// Godot's): an item with OBJ_FADE has its shown colour `c` (lit, fogged,
// emission included, and tone mapped as lit() returns it) drawn
// ObjectU.normal[3].w (0 to 1) of the way toward the fade colour
// ObjectU.normal[3].rgb (linear) tone mapped the same way, which is how the
// clear colour of a background_color background is shown (lights.as
// environmentDesc: exposed and tone mapped here, or, in a frame whose post
// pass tone maps, both linear here and tone mapped there). At 1 the item is
// that background, pixel for pixel; the post (the glow, the adjustments, a
// game's grade) then treats both alike. That column is free: every normal
// is moved through ObjectU.normal with a w of 0. Every other item reads
// none of this.
const OBJ_FADE: u32 = 64u;        // ObjectU.extra.x: fading, ObjectU.normal[3] the colour and how far

fn item_fade(c: vec3<f32>) -> vec3<f32> {
    if (select(true, (O.extra.x & OBJ_FADE) == 0u, SPEC_FADE)) {
        return c;
    }
    let f = O.normal[3];
    return mix(c, tonemap(f.rgb), f.w);
}

// ---------------------------------------------------------------- sky

// A frame (render-space) direction in sky space: Godot's, Y up, with the
// environment's sky_rotation applied.
fn sky_dir(d: vec3<f32>) -> vec3<f32> {
    return normalize((Sky.to_sky * vec4<f32>(d, 0.0)).xyz);
}

// Godot's curve of the procedural sky: 0 at c = 0 rising to 1 at c = 1,
// the faster the smaller `curve` (kept at least 1e-4 by the block). pow of
// 0 is undefined in WGSL, so the base is kept just above it (the result is
// 1 there either way).
fn sky_curve(c: f32, curve: f32) -> f32 {
    return clamp(1.0 - pow(max(1.0 - c, 1e-6), 1.0 / curve), 0.0, 1.0);
}

// Godot 4.3's ProceduralSkyMaterial in sky-space direction `d` (unit): the
// gradient, each sun's disc and glow, times energy_multiplier (sky.as
// `proceduralSky`, which the tests check number by number).
fn procedural_sky(d: vec3<f32>) -> vec3<f32> {
    let v = acos(clamp(d.y, -1.0, 1.0));
    var sky = mix(Sky.sky_horizon.rgb, Sky.sky_top.rgb, sky_curve(1.0 - v / (PI * 0.5), Sky.sky_top.w))
        * Sky.sky_horizon.w;
    let suns = min(Sky.flags.z, SKY_SUNS);
    for (var i = 0u; i < suns; i++) {
        let sun = Sky.suns[i];
        let size = sun.direction.w;
        let a = acos(clamp(dot(sun.direction.xyz, d), -1.0, 1.0));
        if (a < size) {
            sky = sun.color.rgb;
        } else if (a < Sky.sun.x) {
            let c2 = (a - size) / (Sky.sun.x - size);
            sky = mix(sun.color.rgb, sky, sky_curve(c2, Sky.sun.y));
        }
    }
    let ground = mix(Sky.ground_horizon.rgb, Sky.ground_bottom.rgb,
        sky_curve((v - PI * 0.5) / (PI * 0.5), Sky.ground_bottom.w)) * Sky.ground_horizon.w;
    return select(ground, sky, d.y >= 0.0) * Sky.sun.z;
}

// The equirectangular panorama in sky-space direction `d` (unit), Godot's
// mapping (sky.as `panoramaUv`), times energy_multiplier: bilinear through
// the sampler (repeating across the seam, clamped at the poles), or the
// texel `d` falls in when the material's filter is off.
fn panorama(d: vec3<f32>) -> vec3<f32> {
    let uv = vec2<f32>(fract(atan2(d.x, -d.z) / (2.0 * PI)), acos(clamp(d.y, -1.0, 1.0)) / PI);
    if ((Sky.flags.x & SKY_PANORAMA_FILTER) != 0u) {
        return textureSampleLevel(t_panorama, s_panorama, uv, 0.0).rgb * Sky.sun.z;
    }
    let size = vec2<i32>(textureDimensions(t_panorama, 0));
    let x = ((i32(floor(uv.x * f32(size.x))) % size.x) + size.x) % size.x;
    let y = clamp(i32(floor(uv.y * f32(size.y))), 0, size.y - 1);
    return textureLoad(t_panorama, vec2<i32>(x, y), 0).rgb * Sky.sun.z;
}

// The sky's irradiance divided by pi at unit sky-space normal `n`, from the
// nine convolved harmonics in sky.as `shBasis`'s order. A sky with sharp
// contrasts rings a little below zero on its dark side; no light is
// negative, so that is clamped.
fn sh_irradiance(n: vec3<f32>) -> vec3<f32> {
    var c = Sky.sh[0].rgb * 0.282095;
    c += Sky.sh[1].rgb * (0.488603 * n.y);
    c += Sky.sh[2].rgb * (0.488603 * n.z);
    c += Sky.sh[3].rgb * (0.488603 * n.x);
    c += Sky.sh[4].rgb * (1.092548 * n.x * n.y);
    c += Sky.sh[5].rgb * (1.092548 * n.y * n.z);
    c += Sky.sh[6].rgb * (0.315392 * (3.0 * n.z * n.z - 1.0));
    c += Sky.sh[7].rgb * (1.092548 * n.x * n.z);
    c += Sky.sh[8].rgb * (0.546274 * (n.x * n.x - n.y * n.y));
    return max(c, vec3<f32>(0.0));
}

// The prefiltered radiance in sky-space direction `d` at perceptual
// `roughness`: mip r * (levels - 1) holds roughness r (sky.as's header). An
// explicit level, so the lookup is valid in non-uniform control flow.
fn radiance(d: vec3<f32>, roughness: f32) -> vec3<f32> {
    let top = f32(max(Sky.flags.y, 1u) - 1u);
    return textureSampleLevel(t_radiance, s_radiance, d, roughness * top).rgb;
}

// Godot's (Karis's) analytic environment BRDF: the scale (x) and bias (y)
// of F0 for image-based specular light (sky.as `envBrdfApprox`).
fn env_brdf_approx(roughness: f32, nv: f32) -> vec2<f32> {
    let r = roughness * vec4<f32>(-1.0, -0.0275, -0.572, 0.022) + vec4<f32>(1.0, 0.0425, 1.04, -0.04);
    let a004 = min(r.x * r.x, exp2(-9.28 * nv)) * r.x + r.y;
    return vec2<f32>(-1.04, 1.04) * a004 + r.zw;
}

// max(x, 0)^8, by multiplication (pow of 0 is undefined in WGSL).
fn pow8(x: f32) -> f32 {
    let x2 = max(x, 0.0) * max(x, 0.0);
    let x4 = x2 * x2;
    return x4 * x4;
}

// The fog's colour seen along `dir` (unit, from the eye): fog_light_color
// brightened towards each directional light by fog_sun_scatter (Godot adds
// the light's colour times energy; the lit block's colours carry a factor
// of pi, taken off here).
fn fog_sun_scatter(fc: vec3<f32>, dir: vec3<f32>) -> vec3<f32> {
    var c = fc;
    if (Sky.fog_color.w > 0.001) {
        // (milestone 59: the pool's directional lights, in its order)
        let count = pool_sun_count();
        for (var k = 0u; k < count; k++) {
            let i = pool_sun(k);
            if (Lit.lights[i].info.x == LIGHT_DIRECTIONAL) {
                c += (Lit.lights[i].color.rgb / PI) * pow8(dot(dir, -Lit.lights[i].direction.xyz))
                    * Sky.fog_color.w;
            }
        }
    }
    return c;
}

// Fog over the drawn sky in direction `dir` (unit): the fog colour, which
// aerial perspective moves towards the sky's own, covering the sky by
// fog_sky_affect.
fn sky_fog(c: vec3<f32>, dir: vec3<f32>) -> vec3<f32> {
    let fc = fog_sun_scatter(mix(Sky.fog_color.rgb, c, Sky.fog_depth.w), dir);
    return mix(c, fc, Sky.fog.y);
}

// Godot's depth and height fog over lit colour `c` at `world`, seen along
// `dir` (unit, from the eye; the view's forward in an orthographic view).
// An orthographic view measures the distance from the nearest drawn depth
// (Sky.fog_origin.x), so the picture's fog does not depend on where its
// camera stands.
fn surface_fog(c: vec3<f32>, world: vec3<f32>, dir: vec3<f32>) -> vec3<f32> {
    let depth = -(G.view * vec4<f32>(world, 1.0)).z;
    var dist = distance(world, G.camera_pos.xyz);
    if (Sky.fog_origin.w > 0.5) {
        dist = max(depth - Sky.fog_origin.x, 0.0);
    }
    var amount: f32;
    if ((Sky.flags.x & SKY_FOG_DEPTH) != 0u) {
        let z = smoothstep(Sky.fog_depth.x, Sky.fog_depth.y, dist);
        amount = select(0.0, pow(max(z, 1e-6), Sky.fog_depth.z), z > 0.0) * Sky.fog.x;
    } else {
        amount = 1.0 - exp(min(0.0, -dist * Sky.fog.x));
    }
    if (abs(Sky.fog.w) >= 1e-4) {
        let y = dot(world, Lit.up.xyz);
        amount = max(amount, 1.0 - exp(min(0.0, (y - Sky.fog.z) * Sky.fog.w)));
    }
    amount = clamp(amount, 0.0, 1.0);
    var fc = Sky.fog_color.rgb;
    if (select(false, (Sky.flags.x & SKY_IBL) != 0u && Sky.fog_depth.w > 0.0, SPEC_AMBIENT_SKY)) {
        // Godot's aerial perspective: the sky behind the point, blurrier
        // (a rougher mip) the nearer the point is.
        let t = clamp((depth - Sky.fog_origin.y) / max(Sky.fog_origin.z - Sky.fog_origin.y, 1e-6), 0.0, 1.0);
        let top = f32(max(Sky.flags.y, 2u) - 1u);
        let rough = mix(1.0 / top, 1.0, 1.0 - t);
        fc = mix(fc, radiance(sky_dir(dir), rough) * Sky.sun.w, Sky.fog_depth.w);
    }
    fc = fog_sun_scatter(fc, dir);
    return mix(c, fc, amount);
}

// ---------------------------------------------------------------- fog volumes

// Milestone 37: Godot's FogVolumes and the Environment's volumetric fog,
// "volumetric-lite" (engine/src/render/fog_volume.as holds the rules, the
// integration's six steps, normatively; render/fog_select.as chooses what
// each view draws and is the CPU twin of the arithmetic below). No
// froxels: each pixel's ray is integrated analytically over the shapes
// its item names (ObjectU.decals.w: up to MAX_OBJECT_FOG_VOLUMES entries
// of the view's pool, a byte each, the entry plus 1), after Godot's depth
// and height fog and before the tone map, as Godot's volumetric fog is
// blended over its depth fog (fog_volumes); the sky's pixels by the
// sky's list (FogU.counts.y, fs_sky's sky_fog_volumes). In the object
// group (group 1, binding 5; the others have no binding left under 8),
// outside the common block. An item of a frame without volumetric fog has
// the word 0 and the sky's count is 0: such a frame (every frame before)
// reads none of this and draws what it drew before.
//
// Every function of this block reads `Fog` (an entry by its index, not a
// copy passed in): rive's compilers write each entry point's own shader
// for GL and D3D with the functions of the module that use no binding the
// entry point lacks, so a function of pure arithmetic would be written
// into all 19 of them; these are written into the five that bind the fog
// block alone (fs_surface, its extended and lightmap variants, fs_sky),
// and every other entry point (the vertex stages, shadows, ids, normals
// and depth) is as it was before fog volumes. The code is kept short for
// those five: the Gauss-Legendre nodes are a loop, one chord and one
// distance function serve every shape, and each entry point calls the fog
// once (lit_with, ext_lit_finish, fs_sky).
//
// Where it differs from Godot: no froxels and no temporal reprojection
// (nothing flickers or ghosts, nothing thinner than a froxel is lost);
// the volumes along a ray are one medium (their optical depths and
// scattered light summed, then Beer's law once), a negative one taking
// away what it overlaps as if each density were even along its chord;
// at most MAX_OBJECT_FOG_VOLUMES a pixel, MAX_FRAME_FOG_VOLUMES a view;
// the lights cast no shadow in the fog (no light shafts), no GI inject;
// each chord is lit at FOG_SAMPLES points; the ambient light injected is
// isotropic (FogU.ambient: the average lit() gives a surface); and it
// draws on every renderer (Godot's only in Forward+).
const MAX_FRAME_FOG_VOLUMES: u32 = 16u;
const MAX_OBJECT_FOG_VOLUMES: u32 = 4u;
const FOG_SHAPE_ELLIPSOID: u32 = 0u;   // Godot's RenderingServer.FogVolumeShape (fog_volume.as FOG_SHAPE_*)
const FOG_SHAPE_CONE: u32 = 1u;
const FOG_SHAPE_CYLINDER: u32 = 2u;
const FOG_SHAPE_BOX: u32 = 3u;
const FOG_SHAPE_WORLD: u32 = 4u;
const FOG_SKY_DISTANCE: f32 = 1000000.0; // where a sky pixel's ray ends (fog_volume.as)
// A list's flag (ObjectU.decals.w, FogU.counts.y; fog_select.as
// FOG_LIST_ALL): more than MAX_OBJECT_FOG_VOLUMES entries meet it, so each
// pixel tests the whole pool and takes the ones its own ray crosses.
const FOG_LIST_ALL: u32 = 2147483648u;
// The 4-point Gauss-Legendre rule on [-1, 1] (fog_select.as FOG_GL_X,
// FOG_GL_W): the nodes -X0, -X1, X1, X0 of weights W0, W1, W1, W0.
const FOG_GL_X0: f32 = 0.8611363;
const FOG_GL_X1: f32 = 0.339981;
const FOG_GL_W0: f32 = 0.3478548;
const FOG_GL_W1: f32 = 0.6521452;
struct FogEntryU {                  // 144 bytes (FogEntryUniform)
    to_local: mat4x4<f32>,          // frame world -> the node's space (identity for the world shapes)
    size: vec4<f32>,                // xyz Godot's size (node space), w min(x, y, z)
    material: vec4<f32>,            // x density, y height_falloff, z edge_fade (0 for the world shapes), w the origin's height
    albedo: vec4<f32>,              // rgb linear, w the shape (FOG_SHAPE_*)
    emission: vec4<f32>,            // rgb linear, w the world shapes' length (0 for the others)
    lights: vec4<u32>,              // x, y its lights (entries of the Lit pool, a byte each), z how many, w unused
};
struct FogU {                       // 2624 bytes (FogUniform)
    counts: vec4<u32>,              // x entries in the pool, y the sky's list (entries + 1, a byte each), z how many, w 1 when drawn
    params: vec4<f32>,              // x anisotropy g, y ambient_inject, z sky_affect, w length
    ambient: vec4<f32>,             // rgb the isotropic ambient light, w unused
    up: vec4<f32>,                  // the frame's up (Lit.up): the height falloff's axis
    light_fog: array<vec4<f32>, 16>, // light_volumetric_fog_energy by Lit pool entry, four a vec4
    entries: array<FogEntryU, 16>,
};
@group(1) @binding(5) var<uniform> Fog: FogU;

// Step 1: the chord [x, y] of the ray (node-space start `o`, direction
// `d`, `t` in metres of the frame's world) inside pool entry `k`'s shape,
// within [0, t_end]; empty (y <= x) when it misses (fog_select.as
// fogChord, the same arithmetic). The slabs |o + t d| <= h cut it first (a
// d of 0 as 1e-12, so that the division stays finite on every target): y's
// for every shape, x's and z's too for the box. Godot's shapes of half
// size h: the box |p| <= h; the others solve a t^2 + 2 b t + c <= 0 within
// |y| <= h.y:
// the ellipsoid |p / h| <= 1, the cylinder x^2 + z^2 <= r^2 and the cone
// x^2 + z^2 <= (k (h.y - y))^2 (its apex at +h.y, its base of radius r at
// -h.y: k = r / (2 h.y)), r = min(h.x, h.z). Every chord ends at the
// entry's emission.w, volumetric_fog_length (as far as Godot's froxels
// reach): the world shape's is [0, min(t_end, length)].
fn fog_chord(k: u32, o: vec3<f32>, d: vec3<f32>, t_end_ray: f32) -> vec2<f32> {
    let shape = u32(Fog.entries[k].albedo.w);
    let t_end = min(Fog.entries[k].emission.w, t_end_ray);
    if (shape == FOG_SHAPE_WORLD) {
        return vec2<f32>(0.0, t_end);
    }
    let h = Fog.entries[k].size.xyz * 0.5;
    let dd = select(d, vec3<f32>(1e-12), abs(d) < vec3<f32>(1e-12));
    let sa = (-h - o) / dd;
    let sb = (h - o) / dd;
    let s_in = min(sa, sb);
    let s_out = max(sa, sb);
    var r = vec2<f32>(max(0.0, s_in.y), min(t_end, s_out.y));
    var a = 0.0;
    var b = 0.0;
    var c = -1.0;
    if (shape == FOG_SHAPE_BOX) {
        r = vec2<f32>(max(max(r.x, s_in.x), s_in.z), min(min(r.y, s_out.x), s_out.z));
    } else if (shape == FOG_SHAPE_ELLIPSOID) {
        a = dot(d / h, d / h);
        b = dot(o / h, d / h);
        c = dot(o / h, o / h) - 1.0;
    } else {
        let rad = min(h.x, h.z);
        let k = select(0.0, rad / (2.0 * h.y), shape == FOG_SHAPE_CONE);
        let w = h.y - o.y;
        a = d.x * d.x + d.z * d.z - k * k * d.y * d.y;
        b = o.x * d.x + o.z * d.z + k * k * w * d.y;
        c = o.x * o.x + o.z * o.z - select(rad * rad, k * k * w * w, shape == FOG_SHAPE_CONE);
    }
    let disc = b * b - a * c;
    if (abs(a) < 1e-12) {
        // (linear: 2 b t + c <= 0; the box's 0 t - 1 <= 0 everywhere)
        if (abs(b) < 1e-12) {
            r.y = select(r.y, -1.0, c > 0.0);
        } else if (b > 0.0) {
            r.y = min(r.y, -c / (2.0 * b));
        } else {
            r.x = max(r.x, -c / (2.0 * b));
        }
    } else if (disc < 0.0) {
        // (nowhere when a > 0, everywhere when a < 0)
        r.y = select(r.y, -1.0, a > 0.0);
    } else {
        let lo = min((-b - sqrt(disc)) / a, (-b + sqrt(disc)) / a);
        let hi = max((-b - sqrt(disc)) / a, (-b + sqrt(disc)) / a);
        if (a > 0.0) {
            r = vec2<f32>(max(r.x, lo), min(r.y, hi));
        } else if (r.x < min(r.y, lo)) {
            // ((-inf, lo] and [hi, inf): the slab holds one of them, the
            // cone's other nappe being above it)
            r.y = min(r.y, lo);
        } else {
            r.x = max(r.x, hi);
        }
    }
    return r;
}

// Step 2: Godot's FogMaterial density of pool entry `k` at frame-world
// `p` (node-space `lp`; fog_select.as fogDensityAt), its edge fade from
// Godot's signed distance of the shape (volumetric_fog.glsl; fog_select.as
// fogSdf) of half size h.
fn fog_density(k: u32, p: vec3<f32>, lp: vec3<f32>) -> f32 {
    let e = Fog.entries[k];
    var rho = e.material.x * min(exp2(-e.material.y * (dot(p, Fog.up.xyz) - e.material.w)), 1.0);
    if (e.material.z > 0.0) {
        let shape = u32(e.albedo.w);
        let h = e.size.xyz * 0.5;
        let rad = min(h.x, h.z);
        var sdf = 0.0;
        if (shape == FOG_SHAPE_ELLIPSOID) {
            let k0 = length(lp / h);
            sdf = k0 * (k0 - 1.0) / max(length(lp / (h * h)), 1e-12);
        } else if (shape == FOG_SHAPE_BOX) {
            let q = abs(lp) - h;
            sdf = length(max(q, vec3<f32>(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
        } else if (shape == FOG_SHAPE_CYLINDER) {
            let q = vec2<f32>(length(lp.xz) - rad, abs(lp.y) - h.y);
            sdf = min(max(q.x, q.y), 0.0) + length(max(q, vec2<f32>(0.0)));
        } else {
            let n = normalize(vec2<f32>(1.0 / max(0.001, rad * 0.5), 1.0 / max(0.001, h.y)));
            sdf = max(dot(n, vec2<f32>(length(lp.xz), lp.y - h.y)), -h.y - lp.y);
        }
        rho *= pow(clamp(-2.0 * sdf / e.size.w, 0.0, 1.0), e.material.z);
    }
    return rho;
}

// Step 3's closed form (no edge fade; fog_select.as fogFalloffDepth): the
// density over [t0, t1] with u = a + b t the height above the origin, the
// material's below u = 0, 2^(-hf u) of it above, that part anchored at its
// densest end: 2^(-hf u_min) L (1 - e^-x) / x, x = hf |b| L ln 2 (its
// series below 0.01).
fn fog_falloff_depth(k: u32, a: f32, b: f32, t0: f32, t1: f32) -> f32 {
    let m = Fog.entries[k].material;
    let hf = m.y;
    if (hf * b == 0.0) {
        return m.x * (t1 - t0) * min(exp2(-hf * a), 1.0);
    }
    let s = clamp(-a / b, t0, t1);
    let lo = select(t0, s, b > 0.0);
    let hi = select(s, t1, b > 0.0);
    let x = hf * abs(b) * (hi - lo) * 0.6931472;
    let g = select((1.0 - exp(-x)) / x, 1.0 - x * (0.5 - x * (1.0 / 6.0 - x / 24.0)), x < 0.01);
    let top = min(exp2(-hf * max(a + b * select(hi, lo, b > 0.0), 0.0)), 1.0);
    return m.x * ((t1 - t0) - (hi - lo) + top * (hi - lo) * g);
}

// The light entry `e` scatters towards the eye at frame-world `p` along
// the ray's unit direction `dir`: the ambient light times ambient_inject,
// and each of its lights (Lit's colour, which carries pi, times lit()'s
// attenuation, Godot's Henyey-Greenstein phase and the light's
// light_volumetric_fog_energy; no shadow).
fn fog_light(n: u32, p: vec3<f32>, dir: vec3<f32>) -> vec3<f32> {
    var sum = Fog.ambient.rgb * Fog.params.y;
    let g = Fog.params.x;
    let lights = Fog.entries[n].lights;
    for (var k = 0u; k < min(lights.z, MAX_OBJECT_LIGHTS); k++) {
        let i = min((select(lights.y, lights.x, k < 4u) >> ((k & 3u) * 8u)) & 0xffu, MAX_FRAME_LIGHTS - 1u);
        let li = Lit.lights[i];
        var l = -li.direction.xyz;
        var atten = 1.0;
        if (li.info.x != LIGHT_DIRECTIONAL) {
            let rel = li.position.xyz - p;
            l = rel / max(length(rel), 1e-6);
            atten = omni_attenuation(length(rel), li.position.w, li.direction.w);
            if (li.info.x == LIGHT_SPOT) {
                let rim = max(1e-4, (1.0 - max(dot(-l, li.direction.xyz), li.spot.x)) / max(1.0 - li.spot.x, 1e-6));
                atten *= 1.0 - pow(rim, li.spot.y);
            }
        }
        let q = 1.0 + g * g - 2.0 * g * dot(dir, l);
        sum += li.color.rgb * (atten * (1.0 - g * g) / (4.0 * PI * q * sqrt(q)) * Fog.light_fog[i >> 2u][i & 3u]);
    }
    return sum;
}

// Steps 2 to 4 for pool entry `k` over its chord `ch` (not empty) of the
// ray from `o` along unit `d` (frame world): rgb its scattered light Q (at
// the chord's FOG_SAMPLES Gauss-Legendre nodes, the nodes 0 to 3 below,
// each times clamp(rho, 0, 1): Godot's froxels weigh albedo and emission
// so), w its optical depth tau (the closed form, or with an edge fade the
// nodes 4 to 11: Gauss-Legendre over the chord's two halves, split where
// the height crosses the origin's, the falloff's kink, or in the middle, a
// symmetric shape's; fog_select.as fogOpticalDepth).
fn fog_entry(k: u32, o: vec3<f32>, d: vec3<f32>, ch: vec2<f32>) -> vec4<f32> {
    let e = Fog.entries[k];
    let lo = (e.to_local * vec4<f32>(o, 1.0)).xyz;
    let ld = (e.to_local * vec4<f32>(d, 0.0)).xyz;
    let a = dot(o, Fog.up.xyz) - e.material.w;
    let b = dot(d, Fog.up.xyz);
    let edge = e.material.z > 0.0;
    var split = (ch.x + ch.y) * 0.5;
    if (e.material.y > 0.0 && -a / b > ch.x && -a / b < ch.y) {
        split = -a / b;
    }
    var q = vec3<f32>(0.0);
    var tau = 0.0;
    for (var i = 0u; i < select(4u, 12u, edge); i++) {
        let j = i & 3u;
        let x = select(FOG_GL_X1, FOG_GL_X0, j == 0u || j == 3u);
        let w = select(FOG_GL_W1, FOG_GL_W0, j == 0u || j == 3u);
        let seg = select(select(vec2<f32>(split, ch.y), vec2<f32>(ch.x, split), i < 8u), ch, i < 4u);
        let half_len = (seg.y - seg.x) * 0.5;
        let t = (seg.x + seg.y) * 0.5 + half_len * select(x, -x, j < 2u);
        let p = o + d * t;
        let rho = fog_density(k, p, lo + ld * t);
        if (i < 4u) {
            q += (e.albedo.rgb * fog_light(k, p, d) + e.emission.rgb) * (w * half_len * clamp(rho, 0.0, 1.0));
        } else {
            tau += w * half_len * rho;
        }
    }
    if (!edge) {
        tau = fog_falloff_depth(k, a, b, ch.x, ch.y);
    }
    return vec4<f32>(q, tau);
}

// Steps 5 and 6 over colour `c`: the entries of `list` (bytes, entry + 1;
// with FOG_LIST_ALL the whole pool, each pixel taking the first
// MAX_OBJECT_FOG_VOLUMES its own ray crosses, in the pool's order) along the
// ray from `o` along unit `d` up to `t_end`, as one medium. A negative
// entry takes away the positive ones' optical depth (and light, in
// proportion) only where its chord overlaps theirs, each one's depth taken
// as spread evenly along its chord, at most all of it there (Godot clamps
// a froxel's summed density at 0; fog_select.as fogCombineDepths); then c
// T + S, T = exp(-sum tau), S = sum Q (1 - T) / sum tau.
fn fog_integrate(c: vec3<f32>, o: vec3<f32>, d: vec3<f32>, t_end: f32, list: u32) -> vec3<f32> {
    let all = list >= FOG_LIST_ALL;
    var at: array<u32, 4>;
    var chords: array<vec2<f32>, 4>;
    var m = 0u;
    for (var i = 0u; i < select(4u, min(Fog.counts.x, MAX_FRAME_FOG_VOLUMES), all); i++) {
        let byte = (list >> ((i & 3u) * 8u)) & 0x7fu;
        if (!all && byte == 0u) {
            break;
        }
        let k = select(min(byte, MAX_FRAME_FOG_VOLUMES) - 1u, i, all);
        let to_local = Fog.entries[k].to_local;
        let r = fog_chord(k, (to_local * vec4<f32>(o, 1.0)).xyz, (to_local * vec4<f32>(d, 0.0)).xyz, t_end);
        if (r.y > r.x) {
            at[m] = k;
            chords[m] = r;
            m++;
            if (m == MAX_OBJECT_FOG_VOLUMES) {
                break;
            }
        }
    }
    var parts: array<vec4<f32>, 4>;
    for (var i = 0u; i < m; i++) {
        parts[i] = fog_entry(at[i], o, d, chords[i]);
    }
    // (the share of chord i that chord n overlaps:
    // max(min(i.y, n.y) - max(i.x, n.x), 0) / max(i.y - i.x, 1e-6))
    for (var n = 0u; n < m; n++) {
        if (parts[n].w < 0.0) {
            var avail = 0.0;
            for (var i = 0u; i < m; i++) {
                let share = max(min(chords[i].y, chords[n].y) - max(chords[i].x, chords[n].x), 0.0)
                    / max(chords[i].y - chords[i].x, 1e-6);
                avail += max(parts[i].w, 0.0) * share;
            }
            let f = min(-parts[n].w / max(avail, 1e-12), 1.0);
            for (var i = 0u; i < m; i++) {
                if (parts[i].w > 0.0) {
                    let share = max(min(chords[i].y, chords[n].y) - max(chords[i].x, chords[n].x), 0.0)
                        / max(chords[i].y - chords[i].x, 1e-6);
                    parts[i] *= 1.0 - share * f;
                }
            }
        }
    }
    var q = vec3<f32>(0.0);
    var tau = 0.0;
    for (var i = 0u; i < m; i++) {
        if (parts[i].w > 0.0) {
            q += parts[i].rgb;
            tau += parts[i].w;
        }
    }
    let t = exp(-tau);
    return c * t + q * ((1.0 - t) / max(tau, 1e-5));
}

// The item's fog volumes (ObjectU.decals.w, `list`) over lit colour `c` at
// frame-world `world`, before the tone map. The pixel's ray starts at the
// eye, or in an orthographic view at the point of the camera's plane
// behind it (fog_select.as rayBoxOf).
fn fog_volumes(c: vec3<f32>, world: vec3<f32>, list: u32) -> vec3<f32> {
    let back = normalize(vec3<f32>(G.view[0].z, G.view[1].z, G.view[2].z));
    let o = select(G.camera_pos.xyz, world - back * (G.view * vec4<f32>(world, 1.0)).z, G.camera_pos.w > 0.5);
    let len = length(world - o);
    return select(c, fog_integrate(c, o, (world - o) / max(len, 1e-6), len, list), len > 0.0);
}

// The sky's fog volumes (FogU.counts.y) over sky colour `c` seen along unit
// `dir` from the pixel's near point `near_point`, by
// volumetric_fog_sky_affect.
fn sky_fog_volumes(c: vec3<f32>, near_point: vec3<f32>, dir: vec3<f32>) -> vec3<f32> {
    let back = normalize(vec3<f32>(G.view[0].z, G.view[1].z, G.view[2].z));
    let o = select(G.camera_pos.xyz, near_point - back * (G.view * vec4<f32>(near_point, 1.0)).z, G.camera_pos.w > 0.5);
    return mix(c, fog_integrate(c, o, dir, FOG_SKY_DISTANCE, Fog.counts.y), Fog.params.z);
}

// Godot's get_omni_attenuation: a window that reaches 0 at the range
// (`inv_range` = 1 / range), times distance to the power -attenuation.
fn omni_attenuation(d: f32, inv_range: f32, decay: f32) -> f32 {
    var nd = d * inv_range;
    nd *= nd;
    nd *= nd;
    nd = max(1.0 - nd, 0.0);
    nd *= nd;
    return nd * pow(max(d, 1e-4), -decay);
}

// How much of light `i` reaches `world` past its shadow casters: 1 lit, 0
// fully shadowed (before shadow_opacity). `n_geo` is the side-corrected
// geometric normal (a normal map would make the offset below follow the
// bumps and speckle the shadow), `l` the unit vector to the light. The
// light's tile: a directional light's first cascade that reaches the
// point's view depth (none past its max distance: lit), an omni light's
// cube face by the largest axis of the light-to-offset-point vector, a spot
// light's only tile. The receiver is moved towards the light and along its
// normal by the biases, in world texels of that tile at its distance
// (shadow.as's header), then compared with the map by a 3 x 3 kernel of
// hardware 2 x 2 comparisons (one tap at radius 0), kept inside the tile.
fn shadow_factor(i: u32, world: vec3<f32>, n_geo: vec3<f32>, l: vec3<f32>) -> f32 {
    let kind = Lit.lights[i].info.x;
    let light_pos = Lit.lights[i].position.xyz;
    // Milestone 59: `i` is the light's pool entry, its shadow is at its
    // slot (LightU.info.w).
    let slot = min(Lit.lights[i].info.w, MAX_SHADOW_LIGHTS - 1u);
    let params = Shadow.lights[slot].params;
    let first = Shadow.lights[slot].info.x;
    let count = max(Shadow.lights[slot].info.y, 1u);
    let view_depth = -(G.view * vec4<f32>(world, 1.0)).z;
    var part = 0u;
    if (kind == LIGHT_DIRECTIONAL) {
        if (view_depth > Shadow.lights[slot].fade.y) {
            return 1.0;
        }
        part = count - 1u;
        for (var c = 0u; c < count; c++) {
            if (view_depth <= Shadow.lights[slot].splits[c]) {
                part = c;
                break;
            }
        }
    }
    // An omni light's six faces share one texel size, so its first tile
    // gives the offset before the face is known.
    let texel = Shadow.tiles[min(first + min(part, count - 1u), SHADOW_TILES - 1u)].texel;
    let t = texel.x + texel.y * distance(world, light_pos);
    // A kernel wider than a texel reaches further across the receiver's
    // own surface, so the normal offset grows with it (by the radius, from
    // 1): a point lifted off a plane by h texels is clear of that plane for
    // every tap within h texels, whatever the light's angle.
    let p = world + n_geo * (params.y * max(params.z, 1.0) * t) + l * (params.x * t);
    if (kind == LIGHT_OMNI) {
        // The face is the offset point's: near a seam the offset can carry
        // it past the face `world` is on, whose tile is only 1.5 texels
        // wider than 90 degrees (and outside it the lookup reads lit).
        let d = p - light_pos;
        let a = abs(d);
        if (a.x >= a.y && a.x >= a.z) {
            part = select(1u, 0u, d.x >= 0.0);
        } else if (a.y >= a.z) {
            part = select(3u, 2u, d.y >= 0.0);
        } else {
            part = select(5u, 4u, d.z >= 0.0);
        }
    }
    let tile = min(first + min(part, count - 1u), SHADOW_TILES - 1u);
    let clip = Shadow.tiles[tile].view_proj * vec4<f32>(p, 1.0);
    if (clip.w <= 0.0) {
        return 1.0;
    }
    let ndc = clip.xyz / clip.w;
    if (abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0 || ndc.z > 1.0) {
        return 1.0;
    }
    let rect = Shadow.tiles[tile].rect;
    let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    let auv = rect.xy + uv * rect.zw;
    let texel_uv = Shadow.atlas.x;
    // Half a texel inside the tile, so the hardware's 2 x 2 footprint never
    // reads a neighbouring tile.
    let lo = rect.xy + vec2<f32>(0.5 * texel_uv);
    let hi = rect.xy + rect.zw - vec2<f32>(0.5 * texel_uv);
    var vis = 0.0;
    let r = params.z;
    if (r <= 0.0) {
        vis = textureSampleCompareLevel(t_shadow, s_shadow, clamp(auv, lo, hi), ndc.z);
    } else {
        let spread = r * texel_uv;
        for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
                let tap = clamp(auv + vec2<f32>(f32(dx), f32(dy)) * spread, lo, hi);
                vis += textureSampleCompareLevel(t_shadow, s_shadow, tap, ndc.z);
            }
        }
        vis = vis / 9.0;
    }
    if (kind == LIGHT_DIRECTIONAL) {
        let fade = Shadow.lights[slot].fade;
        vis = mix(vis, 1.0, smoothstep(fade.x, fade.y, view_depth));
    }
    return mix(1.0, vis, params.w);
}

// The baked probes' light at the item (milestone 19, OBJ_PROBE_GI): the
// diffuse light B arriving at world normal `n` from its L1 SH,
// engine/src/render/lightmap/sh.as's convention exactly, B = max(c0 +
// dot(c1, n), 0) a channel; lit() multiplies it by the diffuse colour where
// it would the ambient light.
fn probe_light(n: vec3<f32>) -> vec3<f32> {
    return max(vec3<f32>(O.gi[0].x + dot(O.gi[0].yzw, n),
                         O.gi[1].x + dot(O.gi[1].yzw, n),
                         O.gi[2].x + dot(O.gi[2].yzw, n)), vec3<f32>(0.0));
}

// The diffuse light that replaces the environment's diffuse ambient light
// at shading normal `n` (milestone 19), w 1 when there is one: the
// lightmap's (`baked`, `baked_light` its sample), else the probes' for an
// item with OBJ_PROBE_GI; w 0 otherwise (every item of a frame without a
// bake), and the ambient light is then exactly what it was.
fn gi_diffuse(n: vec3<f32>, baked: bool, baked_light: vec3<f32>) -> vec4<f32> {
    if (baked) {
        return vec4<f32>(baked_light, 1.0);
    }
    if (select(false, (O.extra.x & OBJ_PROBE_GI) != 0u, SPEC_PROBE_GI)) {
        return vec4<f32>(probe_light(n), 1.0);
    }
    return vec4<f32>(0.0);
}

// Where direction `d` (any length but 0) lands on a probe's cube: x the
// face (0..5), y u and z v (0..1); sky.as cubeFaceUv's selection and signs
// exactly (a tie goes to X, then Y).
fn probe_face_uv(d: vec3<f32>) -> vec3<f32> {
    let a = abs(d);
    var face: f32;
    var ma: f32;
    var sc: f32;
    var tc: f32;
    if (a.x >= a.y && a.x >= a.z) {
        ma = a.x;
        if (d.x >= 0.0) {
            face = 0.0; sc = -d.z; tc = -d.y;
        } else {
            face = 1.0; sc = d.z; tc = -d.y;
        }
    } else if (a.y >= a.z) {
        ma = a.y;
        if (d.y >= 0.0) {
            face = 2.0; sc = d.x; tc = d.z;
        } else {
            face = 3.0; sc = d.x; tc = -d.z;
        }
    } else {
        ma = a.z;
        if (d.z >= 0.0) {
            face = 4.0; sc = d.x; tc = -d.y;
        } else {
            face = 5.0; sc = -d.x; tc = -d.y;
        }
    }
    return vec3<f32>(face, (sc / ma + 1.0) * 0.5, (tc / ma + 1.0) * 0.5);
}

// Level `level` of atlas row `row` at `fuv` (probe_face_uv): bilinear inside
// the face, its uv clamped half a texel from the face's edges (sky.as
// CubeLevel.sampleFace), so a lookup never reads the next face or row. An
// explicit level, so the lookup is valid in non-uniform control flow.
fn probe_texel(row: u32, fuv: vec3<f32>, level: u32) -> vec3<f32> {
    let n = f32(max(Probe.counts.z >> level, 1u));
    let lo = 0.5 / n;
    let u = clamp(fuv.y, lo, 1.0 - lo);
    let v = clamp(fuv.z, lo, 1.0 - lo);
    let uv = vec2<f32>((fuv.x + u) / 6.0, (f32(row) + v) / f32(MAX_PROBES));
    return textureSampleLevel(t_probes, s_probes, uv, f32(level)).rgb;
}

// Row `row`'s cube along probe-space direction `d` at `lod`, trilinear
// between two levels (sky.as RadianceMap.sample).
fn probe_sample(row: u32, d: vec3<f32>, lod: f32) -> vec3<f32> {
    let levels = max(Probe.counts.y, 1u);
    let l = clamp(lod, 0.0, f32(levels - 1u));
    let m0 = u32(l);
    let t = l - f32(m0);
    let fuv = probe_face_uv(d);
    let a = probe_texel(row, fuv, m0);
    if (t <= 0.0 || m0 + 1u >= levels) {
        return a;
    }
    return a * (1.0 - t) + probe_texel(row, fuv, m0 + 1u) * t;
}

// data.as probeWeight: 0 outside the box; inside, the distance to its
// nearest face over the blend distance, at most 1 (1 everywhere with none).
fn probe_weight(p: ProbeEntryU, world: vec3<f32>) -> f32 {
    let l = (p.to_local * vec4<f32>(world, 1.0)).xyz;
    let e = p.extents.xyz;
    let d = min(e.x - abs(l.x), min(e.y - abs(l.y), e.z - abs(l.z)));
    if (d < 0.0) {
        return 0.0;
    }
    if (!(p.extents.w > 0.0)) {
        return 1.0;
    }
    return min(d / p.extents.w, 1.0);
}

// How far along `d` a ray from `o` leaves the slab -e..e (data.as
// exitDistance; a ray along it never leaves).
fn probe_exit(o: f32, d: f32, e: f32) -> f32 {
    if (d > 0.0) {
        return (e - o) / d;
    }
    if (d < 0.0) {
        return (-e - o) / d;
    }
    return 3.0e38;
}

// data.as probeLookup: the probe-space direction a ray from `world` along
// `dir` reads the cube along; box-projected (from the capture point to
// where the ray leaves the box) with PROBE_BOX.
fn probe_lookup(p: ProbeEntryU, world: vec3<f32>, dir: vec3<f32>) -> vec3<f32> {
    let d = (p.to_local * vec4<f32>(dir, 0.0)).xyz;
    if ((p.info.x & PROBE_BOX) == 0u) {
        return d;
    }
    let o = (p.to_local * vec4<f32>(world, 1.0)).xyz;
    let e = p.extents.xyz;
    let tx = probe_exit(o.x, d.x, e.x);
    let ty = probe_exit(o.y, d.y, e.y);
    let tz = probe_exit(o.z, d.z, e.z);
    let t = max(min(tx, min(ty, tz)), 0.0);
    return o + d * t - p.offset.xyz;
}

// The probes' reflections at `world` along the unit direction `r` for a
// surface of perceptual `roughness` whose item's probes are `probes`
// (ObjectU.extra.z: bit r for the frame's probe of atlas row r, set when its
// box meets the item's and its reflection mask the item's layers;
// render/probe_select.as): rgb the sum of each probe's sample times its
// intensity and weight, w the sum of the weights, both divided by that sum
// when it is above 1 (data.as's accumulation). The caller keeps 1 - w of
// the sky's specular light. A probe the item's mask leaves out has a weight
// of 0 at every point of the item (or does not reflect in it), so the sums
// are what they were when every probe was weighed, in the same order.
fn probe_reflection(world: vec3<f32>, r: vec3<f32>, roughness: f32, probes: u32) -> vec4<f32> {
    var acc = vec3<f32>(0.0);
    var w_sum = 0.0;
    let count = min(Probe.counts.x, MAX_PROBES);
    let lod = roughness * f32(max(Probe.counts.y, 1u) - 1u);
    for (var i = 0u; i < count; i++) {
        let p = Probe.probes[i];
        if (((probes >> p.info.w) & 1u) == 0u) {
            continue;
        }
        let w = probe_weight(p, world);
        if (w <= 0.0) {
            continue;
        }
        acc += probe_sample(p.info.w, probe_lookup(p, world, r), lod) * p.offset.w * w;
        w_sum += w;
    }
    if (w_sum > 1.0) {
        acc = acc / w_sum;
        w_sum = 1.0;
    }
    return vec4<f32>(acc, w_sum);
}

// The probes' ambient light at `world` for shading normal `n` (unit): per
// probe whose ambient mode is not disabled, its cube's last level along the
// normal in probe space (environment, no box projection) or its ambient
// colour (constant), times its weight; rgb the sum, w the weights' sum,
// normalised past 1 as the reflections are, over the item's `probes` (as
// probe_reflection's). The caller keeps 1 - w of the environment's diffuse
// ambient light.
fn probe_ambient(world: vec3<f32>, n: vec3<f32>, probes: u32) -> vec4<f32> {
    var acc = vec3<f32>(0.0);
    var w_sum = 0.0;
    let count = min(Probe.counts.x, MAX_PROBES);
    let last = max(Probe.counts.y, 1u) - 1u;
    for (var i = 0u; i < count; i++) {
        let p = Probe.probes[i];
        if (((probes >> p.info.w) & 1u) == 0u || p.info.y == PROBE_AMBIENT_DISABLED) {
            continue;
        }
        let w = probe_weight(p, world);
        if (w <= 0.0) {
            continue;
        }
        var c = p.ambient.rgb;
        if (p.info.y == PROBE_AMBIENT_ENVIRONMENT) {
            c = probe_texel(p.info.w, probe_face_uv((p.to_local * vec4<f32>(n, 0.0)).xyz), last);
        }
        acc += c * w;
        w_sum += w;
    }
    if (w_sum > 1.0) {
        acc = acc / w_sum;
        w_sum = 1.0;
    }
    return vec4<f32>(acc, w_sum);
}
// ---- END shared: lighting ----

// Material mode's PBR (pbr()'s material terms and the same light() BRDF)
// under the frame's own lights, in world space, and its environment's
// ambient light; then emission, exposure and the tone map. The light
// colours carry Godot's factor of pi (lit.as), so a white Lambert surface
// square to a directional light of energy 1 shows its albedo.
fn lit(in: VsOut, front: bool, s: Samples) -> vec3<f32> {
    return lit_with(in, front, s, false, vec3<f32>(0.0));
}

// lit() of a lightmapped surface (milestone 19) when `baked`, `baked_light`
// its lightmap sample: the lights whose direct light is baked
// (LIGHT_BAKED_STATIC) are skipped, and the diffuse ambient light is the
// sample (`gi_diffuse`); the specular ambient light, the other lights,
// SSAO, emission, fog and the tone map are lit()'s.
fn lit_with(in: VsOut, front: bool, s: Samples, baked: bool, baked_light: vec3<f32>) -> vec3<f32> {
    // The geometric normal, before the normal map: the shadow lookup's
    // offset follows it (shadow_factor).
    let n_geo = select(-normalize(in.normal), normalize(in.normal), front);
    var n_mat = n_geo;
    if (select(false, (M.flags.x & T_NORMAL) != 0u, SPEC_TEX_NORMAL)) {
        var t = in.tangent.xyz;
        t = normalize(t - n_mat * dot(n_mat, t));
        let b = cross(n_mat, t) * in.tangent.w;
        n_mat = normalize(t * s.normal.x + b * s.normal.y + n_mat * s.normal.z);
    }
    // Milestone 33: the item's decals over the material's values; an item
    // without one (every item of a frame without decals) keeps them as
    // they are.
    var surf = DecalSurface(s.base.rgb, clamp(M.factors.x * s.mr.b, 0.0, 1.0), clamp(M.factors.y * s.mr.g, 0.045, 1.0),
        s.occlusion, n_mat, s.emission);
    if (select(false, O.decals.z > 0u, SPEC_DECALS)) {
        surf = apply_decals(in.world, n_geo, surf);
    }
    let metallic = surf.metallic;
    let roughness = surf.roughness;
    let a2 = roughness * roughness * roughness * roughness;
    let base = surf.base;
    let diffuse = base * (1.0 - metallic);
    let f0 = mix(vec3<f32>(0.04), base, metallic);
    let n = surf.normal;
    // Towards the eye; an orthographic camera looks along one direction,
    // the inverse view's -Z (the third row of the view's rotation).
    let view_dir = vec3<f32>(G.view[0].z, G.view[1].z, G.view[2].z);
    let v = select(normalize(G.camera_pos.xyz - in.world), normalize(view_dir), G.camera_pos.w > 0.5);

    var c = vec3<f32>(0.0);
    // Milestone 59: the item's own lights (ObjectU.lights), entries of the
    // pool in its order.
    let count = object_light_count();
    for (var k = 0u; select(false, k < count, SPEC_LIGHTS); k++) {
        let i = object_light(k);
        let li = Lit.lights[i];
        if (baked && li.info.z == LIGHT_BAKED_STATIC) {
            continue;
        }
        let kind = li.info.x;
        var l: vec3<f32>;
        var atten = 1.0;
        if (kind == LIGHT_DIRECTIONAL) {
            l = -li.direction.xyz;
        } else {
            let rel = li.position.xyz - in.world;
            let d = length(rel);
            l = rel / max(d, 1e-6);
            atten = omni_attenuation(d, li.position.w, li.direction.w);
            if (kind == LIGHT_SPOT) {
                let cone = li.spot.x;
                let scos = max(dot(-l, li.direction.xyz), cone);
                let rim = max(1e-4, (1.0 - scos) / max(1.0 - cone, 1e-6));
                atten *= 1.0 - pow(rim, li.spot.y);
            }
        }
        if (atten > 0.0) {
            // An unshadowed light keeps its expression exactly as it was, so
            // scenes without shadows render bit for bit as before.
            var radiance = li.color.rgb * atten;
            if (select(false, li.info.y == LIGHT_SHADOWED, SPEC_SHADOWS)) {
                radiance = li.color.rgb * (atten * shadow_factor(i, in.world, n_geo, l));
            }
            c += light_specular(n, v, l, radiance, diffuse, f0, a2, li.spot.z);
        }
    }

    // Ambient: flat, or the sky seen by the normal's hemisphere (diffuse)
    // and along the reflection blurred towards the sky's average by
    // roughness (specular), weighted by pbr()'s roughness-aware Fresnel.
    // (Specialised shaders: only the Sky's branch, which reads no f_amb, is
    // a variant's to leave out. The gradient's and the flat colour's, and
    // their probes' branches, all read f_amb: a variant left with fewer of
    // them lets its compiler fold f_amb into the one left, rounding its
    // sum another way, which the twin pictures of the post sample showed
    // by 1 in a channel. Kept, f_amb is computed as the ubershader computes
    // it.)
    let nv = max(dot(n, v), 1e-4);
    let f_amb = f0 + (max(vec3<f32>(1.0 - roughness), f0) - f0) * pow(1.0 - nv, 5.0);
    // A bake's diffuse light (w 1) replaces the diffuse term of each
    // ambient below; without one each is exactly what it was.
    let gi = gi_diffuse(n, baked, baked_light);
    var ambient: vec3<f32>;
    if (select(false, (Sky.flags.x & SKY_IBL) != 0u, SPEC_AMBIENT_SKY)) {
        // A Sky resource (milestone 11): the diffuse ambient is the flat
        // colour mixed towards the sky's irradiance, the specular the
        // prefiltered radiance along the reflection (or the flat colour, or
        // nothing), weighted by Godot's environment BRDF. The sky's light
        // is scaled by ambient_light_energy and the background's energy
        // here, not in the map, so changing them never rebuilds it.
        let scale = Sky.ibl.x * Sky.sun.w;
        var diffuse_amb = Sky.ambient.rgb;
        if ((Sky.flags.x & SKY_AMBIENT_SKY) != 0u) {
            diffuse_amb = mix(Sky.ambient.rgb, sh_irradiance(sky_dir(n)) * scale, Sky.ambient.w);
        }
        if (gi.w > 0.0) {
            diffuse_amb = gi.rgb;
        }
        var spec_amb = Sky.ambient.rgb;
        if ((Sky.flags.x & SKY_REFLECT_RADIANCE) != 0u) {
            spec_amb = radiance(sky_dir(reflect(-v, n)), roughness) * scale;
        } else if ((Sky.flags.x & SKY_REFLECT_OFF) != 0u) {
            spec_amb = vec3<f32>(0.0);
        }
        let e = env_brdf_approx(roughness, nv);
        if (select(false, Probe.counts.x > 0u, SPEC_PROBES)) {
            // Milestone 20: the probes' light over the sky's (data.as's
            // accumulation); the diffuse part not where a bake gives it.
            // A branch of its own: the expression below stays as it was.
            let pr = probe_reflection(in.world, reflect(-v, n), roughness, O.extra.z);
            let spec = spec_amb * (1.0 - pr.w) + pr.rgb;
            var dif = diffuse_amb;
            if (gi.w <= 0.0) {
                let pa = probe_ambient(in.world, n, O.extra.z);
                dif = diffuse_amb * (1.0 - pa.w) + pa.rgb;
            }
            ambient = diffuse * dif + spec * (f0 * e.x + e.y * clamp(50.0 * f0.g, metallic, 1.0));
        } else {
            ambient = diffuse * diffuse_amb + spec_amb * (f0 * e.x + e.y * clamp(50.0 * f0.g, metallic, 1.0));
        }
    } else if ((Lit.counts.y & ENV_AMBIENT_SKY) != 0u) {
        let up = Lit.up.xyz;
        let sky_avg = (Lit.sky_top.rgb + Lit.sky_horizon.rgb) * 0.5;
        let ground_avg = (Lit.ground_horizon.rgb + Lit.ground_bottom.rgb) * 0.5;
        let irradiance = mix(ground_avg, sky_avg, clamp(dot(n, up) * 0.5 + 0.5, 0.0, 1.0));
        let blurred = mix(sky(reflect(-v, n)), sky_avg, roughness);
        if (Probe.counts.x > 0u) {
            // Milestone 20: the probes' light over the gradient's, as above.
            let pr = probe_reflection(in.world, reflect(-v, n), roughness, O.extra.z);
            let spec = blurred * Lit.ambient.w * (1.0 - pr.w) + pr.rgb;
            var dif = gi.rgb;
            if (gi.w <= 0.0) {
                let pa = probe_ambient(in.world, n, O.extra.z);
                dif = irradiance * Lit.ambient.w * (1.0 - pa.w) + pa.rgb;
            }
            ambient = diffuse * dif + spec * f_amb;
        } else if (gi.w > 0.0) {
            ambient = diffuse * gi.rgb + blurred * f_amb * Lit.ambient.w;
        } else {
            ambient = (diffuse * irradiance + blurred * f_amb) * Lit.ambient.w;
        }
    } else {
        // A flat ambient colour lights the specular term too, as Godot's
        // colour ambient does.
        if (Probe.counts.x > 0u) {
            // Milestone 20: the probes' light over the flat colour.
            let pr = probe_reflection(in.world, reflect(-v, n), roughness, O.extra.z);
            let spec = Lit.ambient.rgb * (1.0 - pr.w) + pr.rgb;
            var dif = gi.rgb;
            if (gi.w <= 0.0) {
                let pa = probe_ambient(in.world, n, O.extra.z);
                dif = Lit.ambient.rgb * (1.0 - pa.w) + pa.rgb;
            }
            ambient = diffuse * dif + spec * f_amb;
        } else if (gi.w > 0.0) {
            ambient = diffuse * gi.rgb + Lit.ambient.rgb * f_amb;
        } else {
            ambient = Lit.ambient.rgb * (diffuse + f_amb);
        }
    }
    if (select(false, (Lit.counts.y & ENV_SSAO) != 0u && M.flags.y != ALPHA_BLEND, SPEC_SSAO)) {
        // Godot 4.4's scene shader: the AO is the darker of the material's
        // and the SSAO, and it darkens the ambient light fully and the
        // direct light summed above by the material's ao_light_affect (0:
        // the schema has none) raised towards ssao_light_affect by
        // ssao_ao_channel_affect, so by their product (at the default
        // channel affect of 0, whatever ssao_light_affect is, not at all).
        // A blended surface wrote no normal or depth, so its texel holds
        // what lies behind it: it reads none.
        let ssao = textureLoad(t_ao, vec2<i32>(floor(in.clip.xy)), 0).r;
        c *= mix(1.0, min(ssao, surf.occlusion), Lit.tone.z * Lit.tone.w);
        c += ambient * min(surf.occlusion, ssao);
    } else {
        c += ambient * surf.occlusion;
    }
    c += surf.emission;
    if (select(false, (Sky.flags.x & SKY_FOG) != 0u, SPEC_FOG)) {
        c = surface_fog(c, in.world, -v);
    }
    // Milestone 37: the fog volumes the item is seen through, over the
    // depth fog (none in a frame without volumetric fog: the word is 0).
    if (select(false, O.decals.w != 0u, SPEC_FOG_VOLUMES)) {
        c = fog_volumes(c, in.world, O.decals.w);
    }
    return tonemap(c);
}

// What the lit mode writes into the main pass: target_color's clamp to
// 0..1, except in a frame whose glow must see the colour above 1 (ENV_HDR,
// set by gpu/renderer.as with post.as's `toneInPost`): lit() and the sky
// then leave the tone map to the post pass (the lit block's is linear at
// exposure 1), and the rgba16float target keeps the HDR colour, only its
// negatives dropped. That never happens on the rgba8unorm fallback target
// (post.as `planPost` plans nothing there).
fn lit_output(c: vec4<f32>) -> vec4<f32> {
    if ((Lit.counts.y & ENV_HDR) != 0u) {
        return vec4<f32>(max(c.rgb, vec3<f32>(0.0)), clamp(c.a, 0.0, 1.0));
    }
    return target_color(c);
}

// The lit mode's sky, drawn first in the main pass with no depth test:
// one full-screen triangle whose view rays come from the inverse
// view-projection.
struct SkyOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) ndc: vec2<f32>,
};

@vertex
fn vs_sky(@builtin(vertex_index) vi: u32) -> SkyOut {
    var pts = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    var out: SkyOut;
    // At the far plane (depth 1 of the 0..1 range).
    out.clip = vec4<f32>(pts[vi], 1.0, 1.0);
    out.ndc = pts[vi];
    return out;
}

@fragment
fn fs_sky(in: SkyOut) -> @location(0) vec4<f32> {
    let near = Lit.inv_view_proj * vec4<f32>(in.ndc, 0.0, 1.0);
    let far = Lit.inv_view_proj * vec4<f32>(in.ndc, 1.0, 1.0);
    let ray = far.xyz / far.w - near.xyz / near.w;
    let bits = Sky.flags.x;
    var c: vec3<f32>;
    if ((bits & (SKY_DRAW_PROCEDURAL | SKY_DRAW_PANORAMA)) != 0u) {
        // A Sky resource: its material, times background_energy_multiplier.
        let d = sky_dir(ray);
        if ((bits & SKY_DRAW_PROCEDURAL) != 0u) {
            c = procedural_sky(d);
        } else {
            c = panorama(d);
        }
        c = c * Sky.sun.w;
    } else {
        // Milestone 4's gradient.
        c = sky(ray);
    }
    if ((bits & SKY_FOG) != 0u) {
        c = sky_fog(c, normalize(ray));
    }
    // Milestone 37: the fog volumes the sky is seen through (none in a
    // frame without volumetric fog: the count is 0).
    if (Fog.counts.z != 0u) {
        c = sky_fog_volumes(c, near.xyz / near.w, normalize(ray));
    }
    return lit_output(vec4<f32>(tonemap(c), 1.0));
}

@fragment
fn fs_surface(in: VsOut, @builtin(front_facing) facing: bool) -> @location(0) vec4<f32> {
    // A mirroring world matrix (a negative determinant) reverses the
    // winding, so the outward side of such an object faces away from
    // front_facing; nothing is culled, so the side is told here (an
    // instance's own mirroring too: `mirrored`).
    let front = facing != mirrored(in);
    let samples = surface_samples(in);
    if (select(false, (in.flags & F_HIDDEN) != 0u, SPEC_FACE_FLAGS)) {
        discard;
    }
    let shown = emerge_reveal(in.world, in.clip.xy);
    if (select(false, shown <= 0.0, SPEC_EMERGE)) {
        discard;
    }
    let n_world = select(-normalize(in.normal), normalize(in.normal), front);
    let n_view = normalize((G.view * vec4<f32>(n_world, 0.0)).xyz);
    let mode = G.params.x;
    let grey = srgb_to_linear(vec3<f32>(0.8));
    var c: vec3<f32>;
    var alpha = 1.0;
    if (select(false, mode == SHADE_MATCAP, SPEC_OTHER_MODES)) {
        c = matcap(n_view, G.params.w);
    } else if (select(false, mode == SHADE_NORMALS, SPEC_OTHER_MODES)) {
        c = srgb_to_linear(n_world * 0.5 + vec3<f32>(0.5));
    } else if (select(false, mode == SHADE_FACE_ORIENT, SPEC_OTHER_MODES)) {
        let tint = select(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 0.25, 1.0), front);
        c = mix(studio(n_view, grey), srgb_to_linear(tint), 0.55);
    } else if (select(false, mode == SHADE_RANDOM, SPEC_OTHER_MODES)) {
        c = studio(n_view, O.color.rgb);
    } else if (select(false, mode == SHADE_MATERIAL, SPEC_MATERIAL_MODE)) {
        if (select(false, M.flags.y == ALPHA_MASK && samples.base.a < M.emission.w, SPEC_ALPHA_MASK)) {
            discard;
        }
        if (select(false, M.flags.y == ALPHA_BLEND, SPEC_ALPHA_BLEND)) {
            alpha = samples.base.a;
        }
        c = pbr(in, front, samples);
    } else if (select(false, mode == SHADE_LIT, SPEC_LIT)) {
        // Material mode's alpha handling, then the frame's own lights.
        if (select(false, M.flags.y == ALPHA_MASK && samples.base.a < M.emission.w, SPEC_ALPHA_MASK)) {
            discard;
        }
        if (select(false, M.flags.y == ALPHA_BLEND, SPEC_ALPHA_BLEND)) {
            alpha = samples.base.a;
        }
        c = lit(in, front, samples);
    } else if (select(false, mode == SHADE_UV_CHECKER, SPEC_OTHER_MODES)) {
        c = studio(n_view, checker(in.uv));
    } else if (select(false, mode == SHADE_WEIGHTS && (O.extra.x & OBJ_HAS_WEIGHTS) != 0u, SPEC_OTHER_MODES)) {
        c = studio(n_view, weight_color(in.weight));
    } else if (select(false, mode == SHADE_LIGHT_COUNT, SPEC_OTHER_MODES)) {
        // Milestone 59: the item in the colour of the lights reaching it
        // (no material: the frame's materialMode is off).
        c = studio(n_view, srgb_to_linear(light_count_color()));
    } else if (SPEC_OTHER_MODES) {
        c = studio(n_view, grey);
    }
    // Edit-mode face selection tint (Blender's translucent orange).
    if (select(false, O.params.w == 1u && (G.params.y & OV_SELECTION) != 0u && (in.flags & F_SELECTED) != 0u, SPEC_FACE_FLAGS)) {
        c = mix(c, srgb_to_linear(vec3<f32>(1.0, 0.635, 0.0)), 0.4);
    }
    if (select(false, mode == SHADE_LIT, SPEC_LIT)) {
        return lit_output(vec4<f32>(emerge_tint(item_fade(c), shown), alpha));
    }
    return target_color(vec4<f32>(c, alpha));
}

// The shadow pass's fragment stage for alpha-masked materials: a cut-out
// casts the shadow of its cut (and a hidden face none); every other caster
// draws with no fragment stage at all (pipelines.as `shadowDepth`).
@fragment
fn fs_shadow(in: VsOut) {
    let samples = surface_samples(in);
    if ((in.flags & F_HIDDEN) != 0u) {
        discard;
    }
    if (emerge_reveal(in.world, vec2<f32>(-1.0)) <= 0.0) {
        discard;
    }
    if (select(false, M.flags.y == ALPHA_MASK && samples.base.a < M.emission.w, SPEC_ALPHA_MASK)) {
        discard;
    }
}

// Object ids for outlines: rive has no integer render targets and no
// readback, so the id goes into one rgba8unorm target, the 24-bit uniform
// index in rgb (little endian, byte / 255, which quantizes exactly) and the
// object's selected (1) / active (2) bits in a, read by the outline pass
// (shaders/render/post_outline.wgsl). Labels are occluded by a CPU ray cast,
// not by a depth readback.
struct IdOut {
    @location(0) id: vec4<f32>,
};

@fragment
fn fs_id(in: VsOut) -> IdOut {
    let samples = surface_samples(in);
    if ((in.flags & F_HIDDEN) != 0u) {
        discard;
    }
    if (emerge_reveal(in.world, in.clip.xy) <= 0.0) {
        discard;
    }
    // Masked-out fragments have no id either, so outlines follow the cutout.
    let materials = G.params.x == SHADE_MATERIAL || G.params.x == SHADE_LIT;
    if (materials && M.flags.y == ALPHA_MASK && samples.base.a < M.emission.w) {
        discard;
    }
    let id = O.params.z;
    let bits = select(0u, 1u, O.params.x == 1u) | select(0u, 2u, O.params.y == 1u);
    var out: IdOut;
    out.id = vec4<f32>(
        f32(id & 255u), f32((id >> 8u) & 255u), f32((id >> 16u) & 255u), f32(bits)) / 255.0;
    return out;
}

// The normal-depth pass of SSAO (milestone 12; gpu/renderer.as draws it
// before the main pass, at the render size, one sample): the view-space
// normal, turned to the side facing the eye as fs_surface turns it, and
// the view depth, which is never 0 in front of the camera, so the target's
// clear value of 0 marks where nothing was drawn. Hidden faces and masked
// cut-outs leave no texel, as they leave no id (fs_id). Milestone 62: a
// second target (layouts.as SSR_SURFACE_FORMAT, cleared to (0, 0, 0, 1)),
// the surface's F0 (rgb, linear) and perceptual roughness (a), as lit()
// works them out before the decals, for the screen-space reflections; the
// first is what it was.
struct NormalDepthOut {
    @location(0) normal_depth: vec4<f32>,
    @location(1) surface: vec4<f32>,
};

@fragment
fn fs_normal_depth(in: VsOut, @builtin(front_facing) facing: bool) -> NormalDepthOut {
    let samples = surface_samples(in);
    if ((in.flags & F_HIDDEN) != 0u) {
        discard;
    }
    if (emerge_reveal(in.world, in.clip.xy) <= 0.0) {
        discard;
    }
    let materials = G.params.x == SHADE_MATERIAL || G.params.x == SHADE_LIT;
    if (materials && M.flags.y == ALPHA_MASK && samples.base.a < M.emission.w) {
        discard;
    }
    let front = facing != mirrored(in);
    let n_world = select(-normalize(in.normal), normalize(in.normal), front);
    let n_view = normalize((G.view * vec4<f32>(n_world, 0.0)).xyz);
    let metallic = clamp(M.factors.x * samples.mr.b, 0.0, 1.0);
    let roughness = clamp(M.factors.y * samples.mr.g, 0.045, 1.0);
    var out: NormalDepthOut;
    out.normal_depth = vec4<f32>(n_view, -(G.view * vec4<f32>(in.world, 1.0)).z);
    out.surface = vec4<f32>(mix(vec3<f32>(0.04), samples.base.rgb, metallic), roughness);
    return out;
}

// ================================================================ extended materials
//
// Milestone 14, part 2: glTF 2.0's whole material (docs/engine/SHADING.md
// is the description; engine/src/render/material.as fills the block). A
// material that uses anything the code above does not draw has MAT_EXT,
// and the renderer draws it with the extended pipelines, whose entries are
// below: the same vertex work plus UV set 1 (location 10, a vertex buffer
// of its own), and a fragment stage that reads MaterialU.xf and .ext and
// t_ext. Nothing above calls anything below, so a frame without such a
// material runs exactly the code it ran before.
//
// MaterialU.ext (layouts.as MaterialExtUniform; colours linear):
//   ext[0]  rgb specular colour, a specular            KHR_materials_specular
//   ext[1]  x ior, y transmission, z thickness,        KHR_materials_ior, _transmission,
//           w attenuation distance (0: none)           _volume
//   ext[2]  rgb attenuation colour, a dispersion       KHR_materials_volume, _dispersion
//   ext[3]  x clearcoat, y its roughness, z its normal KHR_materials_clearcoat;
//           scale, w the normal texture's scale        normalTexture.scale
//   ext[4]  rgb sheen colour, a sheen roughness        KHR_materials_sheen
//   ext[5]  x iridescence, y its ior, z, w its         KHR_materials_iridescence
//           thickness minimum and maximum (nm)
//   ext[6]  x anisotropy strength, yz the cosine and   KHR_materials_anisotropy;
//           sine of its rotation, w occlusion strength occlusionTexture.strength
//   ext[7]  rgb diffuse transmission colour, a         KHR_materials_diffuse_transmission
//           diffuse transmission
// MaterialU.xf: by slot s (PbrSlot), the transform rows xf[2s], xf[2s + 1]
// (`ext_uv`) and where the texture is (`ext_where`: 0 none; slots 0 to 5,
// bindings 1 to 5: 1; the others: their t_ext layer + 1).

// The extension slots (engine/src/material/pbr.as PbrSlot).
const SLOT_BASE: u32 = 0u;
const SLOT_METALLIC: u32 = 1u;
const SLOT_ROUGHNESS: u32 = 2u;
const SLOT_NORMAL: u32 = 3u;
const SLOT_OCCLUSION: u32 = 4u;
const SLOT_EMISSIVE: u32 = 5u;
const SLOT_CLEARCOAT: u32 = 6u;
const SLOT_CLEARCOAT_ROUGHNESS: u32 = 7u;
const SLOT_CLEARCOAT_NORMAL: u32 = 8u;
const SLOT_SHEEN_COLOR: u32 = 9u;
const SLOT_SHEEN_ROUGHNESS: u32 = 10u;
const SLOT_SPECULAR: u32 = 11u;
const SLOT_SPECULAR_COLOR: u32 = 12u;
const SLOT_TRANSMISSION: u32 = 13u;
const SLOT_THICKNESS: u32 = 14u;
const SLOT_IRIDESCENCE: u32 = 15u;
const SLOT_IRIDESCENCE_THICKNESS: u32 = 16u;
const SLOT_ANISOTROPY: u32 = 17u;
const SLOT_DIFFUSE_TRANSMISSION: u32 = 18u;
const SLOT_DIFFUSE_TRANSMISSION_COLOR: u32 = 19u;

// VsOut with UV set 1 (the mesh's second UV layer, else a copy of the first).
struct VsOutExt {
    @builtin(position) clip: vec4<f32>,
    @location(0) world: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) @interpolate(flat) flags: u32,
    @location(4) tangent: vec4<f32>,
    @location(5) weight: f32,
    @location(6) color: vec4<f32>,
    @location(7) uv1: vec2<f32>,
};

fn ext_vs_out(o: VsOut, uv1: vec2<f32>) -> VsOutExt {
    var e: VsOutExt;
    e.clip = o.clip;
    e.world = o.world;
    e.normal = o.normal;
    e.uv = o.uv;
    e.flags = o.flags;
    e.tangent = o.tangent;
    e.weight = o.weight;
    e.color = o.color;
    e.uv1 = uv1;
    return e;
}

fn ext_base_in(e: VsOutExt) -> VsOut {
    var o: VsOut;
    o.clip = e.clip;
    o.world = e.world;
    o.normal = e.normal;
    o.uv = e.uv;
    o.flags = e.flags;
    o.tangent = e.tangent;
    o.weight = e.weight;
    o.color = e.color;
    return o;
}

// vs_surface's body (an entry point cannot be called; tools/
// wgsl_common_test.py checks the two stay the same).
fn surface_vertex(in: VsIn) -> VsOut {
    let world = O.model * vec4<f32>(in.pos, 1.0);
    var out: VsOut;
    out.clip = G.view_proj * world;
    out.world = world.xyz;
    out.normal = normalize((O.normal * vec4<f32>(in.normal, 0.0)).xyz);
    out.uv = in.uv;
    out.flags = in.flags;
    // A mirroring world matrix reverses cross(n, t), so the bitangent's
    // sign flips with it; otherwise a normal map's green channel would be
    // inverted on a node scaled (-1, 1, 1).
    let mirror = select(1.0, -1.0, (O.extra.x & OBJ_MIRRORED) != 0u);
    out.tangent = vec4<f32>(normalize((O.model * vec4<f32>(in.tangent.xyz, 0.0)).xyz), in.tangent.w * mirror);
    out.weight = in.weight;
    out.color = vec4<f32>(1.0);
    return out;
}

// vs_surface_instanced's body (as surface_vertex is vs_surface's).
fn surface_vertex_instanced(in: VsIn, inst: InstIn) -> VsOut {
    let p1 = vec4<f32>(in.pos, 1.0);
    let local = vec3<f32>(dot(inst.row0, p1), dot(inst.row1, p1), dot(inst.row2, p1));
    let world = O.model * vec4<f32>(local, 1.0);
    // The basis's columns (its X, Y and Z axes).
    let bx = vec3<f32>(inst.row0.x, inst.row1.x, inst.row2.x);
    let by = vec3<f32>(inst.row0.y, inst.row1.y, inst.row2.y);
    let bz = vec3<f32>(inst.row0.z, inst.row1.z, inst.row2.z);
    let det = dot(bx, cross(by, bz));
    let flip = det < 0.0;
    let cofactor = mat3x3<f32>(cross(by, bz), cross(bz, bx), cross(bx, by));
    let n_local = cofactor * in.normal * select(1.0, -1.0, flip);
    let t_local = mat3x3<f32>(bx, by, bz) * in.tangent.xyz;
    var out: VsOut;
    out.clip = G.view_proj * world;
    out.world = world.xyz;
    out.normal = normalize((O.normal * vec4<f32>(n_local, 0.0)).xyz);
    out.uv = in.uv;
    out.flags = in.flags | select(0u, F_INSTANCE_MIRRORED, flip);
    let mirror = select(1.0, -1.0, ((O.extra.x & OBJ_MIRRORED) != 0u) != flip);
    out.tangent = vec4<f32>(normalize((O.model * vec4<f32>(t_local, 0.0)).xyz), in.tangent.w * mirror);
    out.weight = in.weight;
    out.color = inst.color;
    return out;
}

@vertex
fn vs_surface_ext(in: VsIn, @location(10) uv1: vec2<f32>) -> VsOutExt {
    return ext_vs_out(surface_vertex(in), uv1);
}

@vertex
fn vs_surface_ext_instanced(in: VsIn, inst: InstIn, @location(10) uv1: vec2<f32>) -> VsOutExt {
    return ext_vs_out(surface_vertex_instanced(in, inst), uv1);
}

// Slot `s`'s texture coordinate: its UV set (row0.w), the flipped
// coordinate through its KHR_texture_transform (with Godot's uv1 folded in
// for set 0: material.as `slotRows`).
fn ext_uv(s: u32, uv0: vec2<f32>, uv1: vec2<f32>) -> vec2<f32> {
    let r0 = M.xf[s * 2u];
    let r1 = M.xf[s * 2u + 1u];
    let uv = select(uv0, uv1, r0.w > 0.5);
    return vec2<f32>(dot(r0.xy, uv) + r0.z, dot(r1.xy, uv) + r1.z);
}

// Where slot `s`'s texture is (see the block's header): 0 for none.
fn ext_where(s: u32) -> f32 {
    return M.xf[s * 2u + 1u].w;
}

// Slot `s`'s layer of t_ext at its coordinate.
fn ext_layer(s: u32, uv0: vec2<f32>, uv1: vec2<f32>) -> vec4<f32> {
    return textureSample(t_ext, s_mat, ext_uv(s, uv0, uv1), i32(ext_where(s) + 0.5) - 1);
}

// A tangent-space normal from a texel, its x and y scaled (glTF's
// normalTexture.scale).
fn scaled_normal(texel: vec3<f32>, scale: f32) -> vec3<f32> {
    return normalize((texel * 2.0 - vec3<f32>(1.0)) * vec3<f32>(scale, scale, 1.0));
}

// Every input of the extended shading at a fragment: the factors times
// their textures (glTF's channels: pbr.as PbrSlot's comments).
struct ExtSamples {
    base: vec4<f32>,
    normal: vec3<f32>,
    metallic: f32,
    roughness: f32,
    emission: vec3<f32>,
    occlusion: f32,
    specular: f32,
    specular_color: vec3<f32>,
    transmission: f32,
    thickness: f32,
    clearcoat: f32,
    clearcoat_roughness: f32,
    clearcoat_normal: vec3<f32>,
    clearcoat_mapped: bool,
    sheen_color: vec3<f32>,
    sheen_roughness: f32,
    iridescence: f32,
    iridescence_thickness: f32,
    anisotropy: f32,
    anisotropy_dir: vec2<f32>,
    diffuse_transmission: f32,
    diffuse_transmission_color: vec3<f32>,
};

// All texture reads of the extended path, in uniform control flow (every
// branch depends on the material uniform) and before any discard, as
// sample_material's.
fn sample_ext(in: VsOutExt) -> ExtSamples {
    let uv0 = tex_uv(in.uv);
    let uv1 = tex_uv(in.uv1);
    var s: ExtSamples;
    s.base = M.base_color;
    if (select(false, (M.flags.x & T_BASE) != 0u, SPEC_TEX_BASE)) {
        s.base *= decoded_base(textureSample(t_base, s_mat, ext_uv(SLOT_BASE, uv0, uv1)));
    }
    if (select(false, (M.flags.w & MAT_VERTEX_COLOR) != 0u, SPEC_VERTEX_COLOR)) {
        var c = in.color;
        if ((M.flags.w & MAT_VERTEX_COLOR_SRGB) != 0u) {
            c = vec4<f32>(srgb_to_linear(c.rgb), c.a);
        }
        s.base = s.base * c;
    }
    s.normal = vec3<f32>(0.0, 0.0, 1.0);
    if (select(false, (M.flags.x & T_NORMAL) != 0u, SPEC_TEX_NORMAL)) {
        s.normal = scaled_normal(textureSample(t_normal, s_mat, ext_uv(SLOT_NORMAL, uv0, uv1)).xyz, M.ext[3].w);
    }
    s.metallic = M.factors.x;
    if (select(false, ext_where(SLOT_METALLIC) > 0.5, SPEC_TEX_MR)) {
        s.metallic *= textureSample(t_mr, s_mat, ext_uv(SLOT_METALLIC, uv0, uv1)).b;
    }
    s.roughness = M.factors.y;
    if (select(false, (M.flags.w & MAT_ROUGHNESS_LAYER) != 0u, SPEC_ROUGHNESS_LAYER)) {
        if (ext_where(SLOT_ROUGHNESS) > 0.5) {
            s.roughness *= ext_layer(SLOT_ROUGHNESS, uv0, uv1).g;
        }
    } else if (select(false, ext_where(SLOT_ROUGHNESS) > 0.5, SPEC_TEX_MR)) {
        s.roughness *= textureSample(t_mr, s_mat, ext_uv(SLOT_ROUGHNESS, uv0, uv1)).g;
    }
    s.emission = M.emission.rgb;
    if (select(false, (M.flags.x & T_EMISSION) != 0u, SPEC_TEX_EMISSION)) {
        s.emission *= decoded_emission(textureSample(t_emission, s_mat, ext_uv(SLOT_EMISSIVE, uv0, uv1)).rgb);
    }
    s.occlusion = 1.0;
    if (select(false, (M.flags.x & T_OCCLUSION) != 0u, SPEC_TEX_OCCLUSION)) {
        // glTF: 1 + strength * (texel - 1).
        let o = textureSample(t_occlusion, s_mat, ext_uv(SLOT_OCCLUSION, uv0, uv1)).r;
        s.occlusion = 1.0 + M.ext[6].w * (o - 1.0);
    }
    s.specular = M.ext[0].w;
    if (select(false, ext_where(SLOT_SPECULAR) > 0.5, SPEC_EXT_LAYERS)) {
        s.specular *= ext_layer(SLOT_SPECULAR, uv0, uv1).a;
    }
    s.specular_color = M.ext[0].rgb;
    if (select(false, ext_where(SLOT_SPECULAR_COLOR) > 0.5, SPEC_EXT_LAYERS)) {
        s.specular_color *= srgb_to_linear(ext_layer(SLOT_SPECULAR_COLOR, uv0, uv1).rgb);
    }
    s.transmission = M.ext[1].y;
    if (select(false, ext_where(SLOT_TRANSMISSION) > 0.5, SPEC_EXT_LAYERS)) {
        s.transmission *= ext_layer(SLOT_TRANSMISSION, uv0, uv1).r;
    }
    s.thickness = M.ext[1].z;
    if (select(false, ext_where(SLOT_THICKNESS) > 0.5, SPEC_EXT_LAYERS)) {
        s.thickness *= ext_layer(SLOT_THICKNESS, uv0, uv1).g;
    }
    s.clearcoat = M.ext[3].x;
    if (select(false, ext_where(SLOT_CLEARCOAT) > 0.5, SPEC_EXT_LAYERS)) {
        s.clearcoat *= ext_layer(SLOT_CLEARCOAT, uv0, uv1).r;
    }
    s.clearcoat_roughness = M.ext[3].y;
    if (select(false, ext_where(SLOT_CLEARCOAT_ROUGHNESS) > 0.5, SPEC_EXT_LAYERS)) {
        s.clearcoat_roughness *= ext_layer(SLOT_CLEARCOAT_ROUGHNESS, uv0, uv1).g;
    }
    s.clearcoat_normal = vec3<f32>(0.0, 0.0, 1.0);
    s.clearcoat_mapped = false;
    if (select(false, ext_where(SLOT_CLEARCOAT_NORMAL) > 0.5, SPEC_EXT_LAYERS)) {
        s.clearcoat_normal = scaled_normal(ext_layer(SLOT_CLEARCOAT_NORMAL, uv0, uv1).xyz, M.ext[3].z);
        s.clearcoat_mapped = true;
    }
    s.sheen_color = M.ext[4].rgb;
    if (select(false, ext_where(SLOT_SHEEN_COLOR) > 0.5, SPEC_EXT_LAYERS)) {
        s.sheen_color *= srgb_to_linear(ext_layer(SLOT_SHEEN_COLOR, uv0, uv1).rgb);
    }
    s.sheen_roughness = M.ext[4].w;
    if (select(false, ext_where(SLOT_SHEEN_ROUGHNESS) > 0.5, SPEC_EXT_LAYERS)) {
        s.sheen_roughness *= ext_layer(SLOT_SHEEN_ROUGHNESS, uv0, uv1).a;
    }
    s.iridescence = M.ext[5].x;
    if (select(false, ext_where(SLOT_IRIDESCENCE) > 0.5, SPEC_EXT_LAYERS)) {
        s.iridescence *= ext_layer(SLOT_IRIDESCENCE, uv0, uv1).r;
    }
    // glTF: the maximum without a texture.
    var thick = 1.0;
    if (select(false, ext_where(SLOT_IRIDESCENCE_THICKNESS) > 0.5, SPEC_EXT_LAYERS)) {
        thick = ext_layer(SLOT_IRIDESCENCE_THICKNESS, uv0, uv1).g;
    }
    s.iridescence_thickness = mix(M.ext[5].z, M.ext[5].w, thick);
    s.anisotropy = M.ext[6].x;
    s.anisotropy_dir = M.ext[6].yz;
    if (select(false, ext_where(SLOT_ANISOTROPY) > 0.5, SPEC_EXT_LAYERS)) {
        // RG the direction in tangent space ([0, 1] to [-1, 1]), rotated
        // by the rotation; B the strength.
        let a = ext_layer(SLOT_ANISOTROPY, uv0, uv1).rgb;
        let d = a.rg * 2.0 - vec2<f32>(1.0);
        let dn = select(vec2<f32>(1.0, 0.0), normalize(d), dot(d, d) > 1e-8);
        let c = M.ext[6].y;
        let sn = M.ext[6].z;
        s.anisotropy_dir = vec2<f32>(c * dn.x - sn * dn.y, sn * dn.x + c * dn.y);
        s.anisotropy *= a.b;
    }
    s.diffuse_transmission = M.ext[7].w;
    if (select(false, ext_where(SLOT_DIFFUSE_TRANSMISSION) > 0.5, SPEC_EXT_LAYERS)) {
        s.diffuse_transmission *= ext_layer(SLOT_DIFFUSE_TRANSMISSION, uv0, uv1).a;
    }
    s.diffuse_transmission_color = M.ext[7].rgb;
    if (select(false, ext_where(SLOT_DIFFUSE_TRANSMISSION_COLOR) > 0.5, SPEC_EXT_LAYERS)) {
        s.diffuse_transmission_color *= srgb_to_linear(ext_layer(SLOT_DIFFUSE_TRANSMISSION_COLOR, uv0, uv1).rgb);
    }
    return s;
}

// The cut-out of the extended path: the masked alpha below its cutoff.
fn ext_cut(s: ExtSamples) -> bool {
    return select(false, M.flags.y == ALPHA_MASK && s.base.a < M.emission.w, SPEC_ALPHA_MASK);
}

// ---------------------------------------------------------------- extended BRDF

fn max3(c: vec3<f32>) -> f32 {
    return max(c.r, max(c.g, c.b));
}

fn pow5(x: f32) -> f32 {
    let x2 = x * x;
    return x2 * x2 * x;
}

// Schlick's Fresnel with glTF's f90 (KHR_materials_specular).
fn f_schlick90(f0: vec3<f32>, f90: vec3<f32>, vh: f32) -> vec3<f32> {
    return f0 + (f90 - f0) * pow5(clamp(1.0 - vh, 0.0, 1.0));
}

// KHR_materials_anisotropy's distribution and visibility (Burley's
// anisotropic GGX), from the extension's text.
fn d_ggx_aniso(nh: f32, th: f32, bh: f32, at: f32, ab: f32) -> f32 {
    let a2 = at * ab;
    let f = vec3<f32>(ab * th, at * bh, a2 * nh);
    let w2 = a2 / dot(f, f);
    return a2 * w2 * w2 / PI;
}

fn v_ggx_aniso(nl: f32, nv: f32, bv: f32, tv: f32, tl: f32, bl: f32, at: f32, ab: f32) -> f32 {
    let gv = nl * length(vec3<f32>(at * tv, ab * bv, nv));
    let g_l = nv * length(vec3<f32>(at * tl, ab * bl, nl));
    return clamp(0.5 / max(gv + g_l, 1e-6), 0.0, 1.0);
}

// KHR_materials_sheen's Charlie distribution and visibility (Conty and
// Kulla's, as the extension gives them).
fn d_charlie(alpha_g: f32, nh: f32) -> f32 {
    let inv_r = 1.0 / alpha_g;
    let sin2h = max(1.0 - nh * nh, 0.0);
    return (2.0 + inv_r) * pow(max(sin2h, 1e-7), inv_r * 0.5) / (2.0 * PI);
}

fn charlie_l(x: f32, alpha_g: f32) -> f32 {
    let o = (1.0 - alpha_g) * (1.0 - alpha_g);
    let a = mix(21.5473, 25.3245, o);
    let b = mix(3.82987, 3.32435, o);
    let c = mix(0.19823, 0.16801, o);
    let d = mix(-1.97760, -1.27393, o);
    let e = mix(-4.32054, -4.85967, o);
    return a / (1.0 + b * pow(max(x, 1e-6), c)) + d * x + e;
}

fn lambda_sheen(cos_theta: f32, alpha_g: f32) -> f32 {
    if (abs(cos_theta) < 0.5) {
        return exp(charlie_l(cos_theta, alpha_g));
    }
    return exp(2.0 * charlie_l(0.5, alpha_g) - charlie_l(1.0 - cos_theta, alpha_g));
}

fn v_charlie(nl: f32, nv: f32, alpha_g: f32) -> f32 {
    return clamp(1.0 / ((1.0 + lambda_sheen(nv, alpha_g) + lambda_sheen(nl, alpha_g)) * (4.0 * nv * nl)), 0.0, 1.0);
}

// The directional albedo E(cos, sheen roughness) of that sheen lobe, for
// KHR_materials_sheen's albedo scaling: a 16 x 8 table (sqrt(cos) across
// 0..1, roughness across 0.07..1) integrated numerically by
// engine/tools/sheen_albedo.py, read bilinearly, at most 1.
fn sheen_albedo(nv: f32, roughness: f32) -> f32 {
    var t = array<f32, 128>(
        1.0000, 1.0000, 1.0000, 1.0000, 0.7217, 0.3370, 0.1291, 0.0382, 0.0080, 0.0011, 0.0001, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000,
        1.0000, 1.0000, 1.0000, 0.8770, 0.6879, 0.5180, 0.3738, 0.2565, 0.1657, 0.0991, 0.0537, 0.0254, 0.0100, 0.0029, 0.0005, 0.0000,
        0.8639, 0.8639, 0.8278, 0.7269, 0.6176, 0.5129, 0.4169, 0.3308, 0.2550, 0.1895, 0.1344, 0.0897, 0.0555, 0.0304, 0.0130, 0.0026,
        0.8025, 0.8025, 0.7788, 0.7039, 0.6193, 0.5365, 0.4586, 0.3864, 0.3199, 0.2589, 0.2035, 0.1541, 0.1123, 0.0765, 0.0459, 0.0201,
        0.8272, 0.8272, 0.8078, 0.7407, 0.6632, 0.5868, 0.5145, 0.4468, 0.3833, 0.3236, 0.2676, 0.2156, 0.1699, 0.1286, 0.0903, 0.0545,
        0.8880, 0.8880, 0.8693, 0.8021, 0.7242, 0.6476, 0.5753, 0.5075, 0.4436, 0.3831, 0.3255, 0.2713, 0.2229, 0.1786, 0.1365, 0.0960,
        0.9424, 0.9424, 0.9231, 0.8537, 0.7737, 0.6955, 0.6222, 0.5537, 0.4893, 0.4281, 0.3696, 0.3143, 0.2650, 0.2196, 0.1763, 0.1347,
        0.9409, 0.9409, 0.9222, 0.8547, 0.7771, 0.7017, 0.6312, 0.5655, 0.5038, 0.4452, 0.3891, 0.3359, 0.2886, 0.2451, 0.2036, 0.1638
    );
    let x = clamp(sqrt(clamp(nv, 0.0, 1.0)), 0.0, 1.0) * 15.0;
    let y = clamp((roughness - 0.07) / 0.93, 0.0, 1.0) * 7.0;
    let i = min(i32(floor(x)), 14);
    let j = min(i32(floor(y)), 6);
    let fx = x - f32(i);
    let fy = y - f32(j);
    let a = mix(t[j * 16 + i], t[j * 16 + i + 1], fx);
    let b = mix(t[(j + 1) * 16 + i], t[(j + 1) * 16 + i + 1], fx);
    return mix(a, b, fy);
}

// KHR_materials_iridescence: Belcour and Barla's thin-film Fresnel as the
// extension gives it (Schlick at both interfaces, the analytic spectral
// integration), seen at angle `cos1` from a medium of ior `outside`, a film
// of ior `film` and `thickness` nanometres over a base of reflectance `f0`.
fn iridescence_sensitivity(opd: f32, shift: vec3<f32>) -> vec3<f32> {
    let phase = 2.0 * PI * opd * 1.0e-9;
    let val = vec3<f32>(5.4856e-13, 4.4201e-13, 5.2481e-13);
    let pos = vec3<f32>(1.6810e+06, 1.7953e+06, 2.2084e+06);
    let vr = vec3<f32>(4.3278e+09, 9.3046e+09, 6.6121e+09);
    var xyz = val * sqrt(2.0 * PI * vr) * cos(pos * phase + shift) * exp(-phase * phase * vr);
    xyz.x += 9.7470e-14 * sqrt(2.0 * PI * 4.5282e+09) * cos(2.2399e+06 * phase + shift.x)
        * exp(-4.5282e+09 * phase * phase);
    xyz = xyz / 1.0685e-7;
    let xyz_to_rec709 = mat3x3<f32>(
        3.2404542, -0.9692660, 0.0556434,
        -1.5371385, 1.8760108, -0.2040259,
        -0.4985314, 0.0415560, 1.0572252);
    return xyz_to_rec709 * xyz;
}

fn ior_to_f0(transmitted: vec3<f32>, incident: f32) -> vec3<f32> {
    let r = (transmitted - vec3<f32>(incident)) / (transmitted + vec3<f32>(incident));
    return r * r;
}

fn eval_iridescence(outside: f32, film_in: f32, cos1: f32, thickness: f32, f0: vec3<f32>) -> vec3<f32> {
    // The film fades to the outside medium as it thins to nothing (the
    // Khronos sample viewer's smoothstep), so a thickness of 0 draws no
    // colour.
    let film = mix(outside, film_in, smoothstep(0.0, 0.03, thickness));
    let k = outside / film;
    let sin2sq = k * k * (1.0 - cos1 * cos1);
    let cos2sq = 1.0 - sin2sq;
    if (cos2sq < 0.0) {
        return vec3<f32>(1.0);
    }
    let cos2 = sqrt(cos2sq);
    let r0 = ior_to_f0(vec3<f32>(film), outside).x;
    let r12 = r0 + (1.0 - r0) * pow5(clamp(1.0 - cos1, 0.0, 1.0));
    let t121 = 1.0 - r12;
    let phi12 = select(0.0, PI, film < outside);
    let phi21 = PI - phi12;
    let sq = sqrt(min(f0 + vec3<f32>(0.0001), vec3<f32>(0.9999)));
    let base_ior = (vec3<f32>(1.0) + sq) / (vec3<f32>(1.0) - sq);
    let r1 = ior_to_f0(base_ior, film);
    let r23 = r1 + (vec3<f32>(1.0) - r1) * pow5(clamp(1.0 - cos2, 0.0, 1.0));
    let phi23 = select(vec3<f32>(0.0), vec3<f32>(PI), base_ior < vec3<f32>(film));
    let opd = 2.0 * film * thickness * cos2;
    let phi = vec3<f32>(phi21) + phi23;
    let r123 = clamp(r12 * r23, vec3<f32>(1e-5), vec3<f32>(0.9999));
    let r123s = sqrt(r123);
    let rs = t121 * t121 * r23 / (vec3<f32>(1.0) - r123);
    var i = vec3<f32>(r12) + rs;
    var cm = rs - vec3<f32>(t121);
    for (var m = 1; m <= 2; m++) {
        cm *= r123s;
        i += cm * 2.0 * iridescence_sensitivity(f32(m) * opd, f32(m) * phi);
    }
    return max(i, vec3<f32>(0.0));
}

// Everything the extended lobes share at one fragment, in world space.
struct ExtCtx {
    n: vec3<f32>,            // shading normal (normal map)
    n_geo: vec3<f32>,        // side-corrected geometric normal
    nc: vec3<f32>,           // clearcoat normal
    v: vec3<f32>,
    world: vec3<f32>,        // the fragment, frame world (the probes' lookups)
    nv: f32,
    base: vec3<f32>,
    diffuse: vec3<f32>,      // base * (1 - metallic)
    metallic: f32,
    roughness: f32,          // perceptual, at least 0.045 (as today's)
    alpha: f32,              // roughness^2
    a2: f32,                 // roughness^4
    f0: vec3<f32>,
    f90: vec3<f32>,
    iridescence: f32,
    irid_f: vec3<f32>,
    aniso: f32,
    aniso_t: vec3<f32>,
    aniso_b: vec3<f32>,
    clearcoat: f32,
    cc_roughness: f32,
    cc_a2: f32,
    sheen: vec3<f32>,
    sheen_alpha: f32,
    sheen_roughness: f32,
    dt: f32,
    dt_color: vec3<f32>,
    transmission: f32,
    trans_alpha: f32,        // KHR's transmission roughness: alpha * clamp(2 ior - 2, 0, 1)
    ior: f32,
    attenuation: vec3<f32>,  // KHR_materials_volume's transmittance through `thickness`
    thin: bool,              // thickness 0: the thin-walled case (no refraction)
    thickness: f32,          // the volume's thickness in the world (milestone 62: where the ray leaves it)
    frag: vec2<f32>,         // the fragment's position in pixels (milestone 62: its screen texel)
    dispersion: f32,
    occlusion: f32,          // the material's, decals painted (milestone 33)
    emission: vec3<f32>,     // likewise
};

// The view vector at `world`: towards the eye, or along the orthographic
// camera's axis (lit()'s).
fn ext_view(world: vec3<f32>) -> vec3<f32> {
    let view_dir = vec3<f32>(G.view[0].z, G.view[1].z, G.view[2].z);
    return select(normalize(G.camera_pos.xyz - world), normalize(view_dir), G.camera_pos.w > 0.5);
}

// The fragment's material for the lobes below: KHR_materials_ior and
// _specular's F0 and F90 (f0 = min(((ior-1)/(ior+1))^2 specular_colour, 1)
// specular for a dielectric, the base colour for a metal; at glTF's
// defaults today's 0.04 and 1), the normals and the extensions' terms.
// Milestone 33: with `decals` (the lit shading, an item that paints some),
// the item's decals over the base colour, metallic, roughness, occlusion,
// shading normal and emission first (apply_decals, as lit_with's), so
// that every term below reads what they painted.
fn ext_ctx(in: VsOutExt, front: bool, s: ExtSamples, decals: bool) -> ExtCtx {
    var e: ExtCtx;
    let n_geo = select(-normalize(in.normal), normalize(in.normal), front);
    var t = in.tangent.xyz;
    t = normalize(t - n_geo * dot(n_geo, t));
    let b = cross(n_geo, t) * in.tangent.w;
    e.n_geo = n_geo;
    e.n = n_geo;
    if (select(false, (M.flags.x & T_NORMAL) != 0u, SPEC_TEX_NORMAL)) {
        e.n = normalize(t * s.normal.x + b * s.normal.y + n_geo * s.normal.z);
    }
    // KHR_materials_clearcoat: the clearcoat's own normal map, else the
    // geometric normal (not the base's normal map).
    e.nc = n_geo;
    if (s.clearcoat_mapped) {
        e.nc = normalize(t * s.clearcoat_normal.x + b * s.clearcoat_normal.y + n_geo * s.clearcoat_normal.z);
    }
    var surf = DecalSurface(s.base.rgb, clamp(s.metallic, 0.0, 1.0), clamp(s.roughness, 0.045, 1.0), s.occlusion,
        e.n, s.emission);
    if (select(false, decals, SPEC_DECALS)) {
        surf = apply_decals(in.world, n_geo, surf);
    }
    e.n = surf.normal;
    e.occlusion = surf.occlusion;
    e.emission = surf.emission;
    e.v = ext_view(in.world);
    e.world = in.world;
    e.nv = max(dot(e.n, e.v), 1e-4);
    e.metallic = surf.metallic;
    e.roughness = surf.roughness;
    e.alpha = e.roughness * e.roughness;
    e.a2 = e.alpha * e.alpha;
    e.base = surf.base;
    e.diffuse = e.base * (1.0 - e.metallic);
    e.ior = max(M.ext[1].x, 1.0);
    let r = (e.ior - 1.0) / (e.ior + 1.0);
    let spec = max(s.specular, 0.0);
    let dielectric_f0 = min(vec3<f32>(r * r) * s.specular_color, vec3<f32>(1.0)) * spec;
    e.f0 = mix(dielectric_f0, e.base, e.metallic);
    e.f90 = mix(vec3<f32>(spec), vec3<f32>(1.0), e.metallic);
    e.iridescence = clamp(s.iridescence, 0.0, 1.0);
    e.irid_f = e.f0;
    if (select(false, e.iridescence > 0.0, SPEC_IRIDESCENCE)) {
        e.irid_f = eval_iridescence(1.0, M.ext[5].y, e.nv, s.iridescence_thickness, e.f0);
    }
    e.aniso = clamp(s.anisotropy, 0.0, 1.0);
    e.aniso_t = normalize(t * s.anisotropy_dir.x + b * s.anisotropy_dir.y);
    e.aniso_b = normalize(cross(n_geo, e.aniso_t));
    e.clearcoat = clamp(s.clearcoat, 0.0, 1.0);
    e.cc_roughness = clamp(s.clearcoat_roughness, 0.045, 1.0);
    let cca = e.cc_roughness * e.cc_roughness;
    e.cc_a2 = cca * cca;
    e.sheen = max(s.sheen_color, vec3<f32>(0.0));
    e.sheen_roughness = clamp(s.sheen_roughness, 0.07, 1.0);
    e.sheen_alpha = e.sheen_roughness * e.sheen_roughness;
    e.dt = clamp(s.diffuse_transmission, 0.0, 1.0);
    e.dt_color = max(s.diffuse_transmission_color, vec3<f32>(0.0));
    e.transmission = clamp(s.transmission, 0.0, 1.0);
    e.trans_alpha = max(e.alpha * clamp(e.ior * 2.0 - 2.0, 0.0, 1.0), 0.002);
    // KHR_materials_volume: thickness is in the mesh's space, so it scales
    // with the node (the mean of the world matrix's axis lengths; an
    // instance's own scale is left out); the transmittance through it is
    // attenuation_colour ^ (distance / attenuation_distance).
    let scale = (length(O.model[0].xyz) + length(O.model[1].xyz) + length(O.model[2].xyz)) / 3.0;
    let dist = max(s.thickness, 0.0) * scale;
    e.thin = dist <= 0.0;
    e.thickness = dist;
    e.frag = in.clip.xy;
    e.attenuation = vec3<f32>(1.0);
    if (select(false, M.ext[1].w > 0.0 && dist > 0.0, SPEC_VOLUME)) {
        e.attenuation = pow(max(M.ext[2].rgb, vec3<f32>(1e-6)), vec3<f32>(dist / M.ext[1].w));
    }
    e.dispersion = M.ext[2].a;
    return e;
}

// The base layer's specular Fresnel at `vh`: F0/F90 Schlick, mixed towards
// the thin film's by the iridescence (KHR_materials_iridescence).
fn ext_fresnel(e: ExtCtx, vh: f32) -> vec3<f32> {
    let f = f_schlick90(e.f0, e.f90, vh);
    return mix(f, e.irid_f, e.iridescence);
}

// One light's contribution (`radiance`, towards `l`). `godot` is the lit
// mode's base layer (light_specular: Lambert diffuse not lessened by the
// Fresnel, the specular times the light's `spec`); otherwise material
// mode's (light(): diffuse times 1 - F). On it, as KHR's layering says:
// diffuse transmission (Lambert from the back), specular transmission (the
// light seen through the surface, KHR's punctual transmission lobe),
// sheen (scaled base, plus Charlie), clearcoat (base times 1 - its Fresnel,
// plus its GGX lobe).
fn ext_light(e: ExtCtx, l: vec3<f32>, radiance: vec3<f32>, spec: f32, godot: bool) -> vec3<f32> {
    let nl_raw = dot(e.n, l);
    let nl = max(nl_raw, 0.0);
    let h = normalize(l + e.v);
    let nh = max(dot(e.n, h), 0.0);
    let vh = max(dot(e.v, h), 0.0);
    let nv = e.nv;
    // The specular lobe (GGX, or KHR_materials_anisotropy's) and the
    // Fresnel the diffuse lobe loses in material mode.
    var f = vec3<f32>(0.0);
    var specular = vec3<f32>(0.0);
    if (nl > 0.0) {
        f = ext_fresnel(e, vh);
        var dv: f32;
        if (select(false, e.aniso > 0.0, SPEC_ANISOTROPY)) {
            let at = mix(e.alpha, 1.0, e.aniso * e.aniso);
            let ab = e.alpha;
            dv = d_ggx_aniso(nh, dot(e.aniso_t, h), dot(e.aniso_b, h), at, ab)
                * v_ggx_aniso(nl, nv, dot(e.aniso_b, e.v), dot(e.aniso_t, e.v), dot(e.aniso_t, l), dot(e.aniso_b, l), at, ab);
        } else {
            dv = d_ggx(nh, e.a2) * v_smith(nl, nv, e.a2);
        }
        specular = f * dv * nl * select(1.0, spec, godot);
    }
    var diffuse = select((vec3<f32>(1.0) - f) * e.diffuse / PI, e.diffuse / PI, godot) * nl;
    // KHR_materials_diffuse_transmission: the diffuse lobe becomes
    // mix(Lambert(base colour), Lambert from the back(colour), factor).
    if (select(false, e.dt > 0.0, SPEC_DIFFUSE_TRANSMISSION)) {
        let back = e.dt_color * (1.0 - e.metallic) / PI * max(-dot(e.n_geo, l), 0.0);
        diffuse = mix(diffuse, back, e.dt);
    }
    // KHR_materials_transmission: the dielectric's diffuse lobe goes to the
    // light seen through the surface (the light mirrored to the viewer's
    // side, a GGX lobe at the transmission roughness, times the base colour
    // and 1 - F, attenuated by the volume; the sample viewer's punctual
    // transmission).
    if (select(false, e.transmission > 0.0, SPEC_TRANSMISSION)) {
        let lm = normalize(l + 2.0 * e.n * dot(-l, e.n));
        let ht = normalize(lm + e.v);
        let at2 = e.trans_alpha * e.trans_alpha;
        let ft = f_schlick90(e.f0, e.f90, clamp(dot(e.v, ht), 0.0, 1.0));
        let lobe = (vec3<f32>(1.0) - ft) * e.base * d_ggx(clamp(dot(e.n, ht), 0.0, 1.0), at2)
            * v_smith(clamp(dot(e.n, lm), 0.0, 1.0), nv, at2) * e.attenuation;
        let through = select(0.0, 1.0, nl_raw < 0.0) * (1.0 - e.metallic);
        diffuse = mix(diffuse, lobe * through, e.transmission);
    }
    let base = diffuse + specular;
    var c = base * radiance;
    // KHR_materials_sheen, with the albedo scaling by E(n.v) alone (the
    // extension's cheaper form).
    if (select(false, max3(e.sheen) > 0.0, SPEC_SHEEN)) {
        let scaling = 1.0 - max3(e.sheen) * sheen_albedo(nv, e.sheen_roughness);
        c *= scaling;
        if (nl > 0.0) {
            c += e.sheen * d_charlie(e.sheen_alpha, nh) * v_charlie(nl, nv, e.sheen_alpha) * nl * radiance;
        }
    }
    // KHR_materials_clearcoat: a GGX layer with its own normal and
    // roughness, F0 0.04, over the rest, which loses its Fresnel.
    if (select(false, e.clearcoat > 0.0, SPEC_CLEARCOAT)) {
        let ncv = max(dot(e.nc, e.v), 1e-4);
        let fc = f_schlick90(vec3<f32>(0.04), vec3<f32>(1.0), ncv).x;
        c *= 1.0 - e.clearcoat * fc;
        let ncl = dot(e.nc, l);
        if (ncl > 0.0) {
            let nch = max(dot(e.nc, h), 0.0);
            let fl = f_schlick90(vec3<f32>(0.04), vec3<f32>(1.0), vh).x;
            c += e.clearcoat * fl * d_ggx(nch, e.cc_a2) * v_smith(ncl, ncv, e.cc_a2) * ncl * radiance * select(1.0, spec, godot);
        }
    }
    return c;
}

// The environment the extended path lights with, by mode (the same as
// today's: material mode's built-in gradient, the lit mode's sky, sky
// gradient or flat ambient), world space.
// Diffuse: the irradiance seen by normal `n`.
fn ext_irradiance(n: vec3<f32>, lit_mode: bool) -> vec3<f32> {
    if (select(false, !lit_mode, SPEC_MATERIAL_MODE)) {
        return env(n.z) * 0.8;
    }
    if (select(false, (Sky.flags.x & SKY_IBL) != 0u, SPEC_AMBIENT_SKY)) {
        let scale = Sky.ibl.x * Sky.sun.w;
        if ((Sky.flags.x & SKY_AMBIENT_SKY) != 0u) {
            return mix(Sky.ambient.rgb, sh_irradiance(sky_dir(n)) * scale, Sky.ambient.w);
        }
        return Sky.ambient.rgb;
    }
    if (select(false, (Lit.counts.y & ENV_AMBIENT_SKY) != 0u, SPEC_AMBIENT_GRADIENT)) {
        let sky_avg = (Lit.sky_top.rgb + Lit.sky_horizon.rgb) * 0.5;
        let ground_avg = (Lit.ground_horizon.rgb + Lit.ground_bottom.rgb) * 0.5;
        return mix(ground_avg, sky_avg, clamp(dot(n, Lit.up.xyz) * 0.5 + 0.5, 0.0, 1.0)) * Lit.ambient.w;
    }
    return Lit.ambient.rgb;
}

// Specular: the radiance arriving along `dir` blurred by `roughness`.
fn ext_radiance(dir: vec3<f32>, roughness: f32, lit_mode: bool) -> vec3<f32> {
    if (select(false, !lit_mode, SPEC_MATERIAL_MODE)) {
        return mix(env(dir.z), env(0.0) * 0.85, roughness);
    }
    if (select(false, (Sky.flags.x & SKY_IBL) != 0u, SPEC_AMBIENT_SKY)) {
        let scale = Sky.ibl.x * Sky.sun.w;
        if ((Sky.flags.x & SKY_REFLECT_RADIANCE) != 0u) {
            return radiance(sky_dir(dir), roughness) * scale;
        }
        if ((Sky.flags.x & SKY_REFLECT_OFF) != 0u) {
            return vec3<f32>(0.0);
        }
        return Sky.ambient.rgb;
    }
    if (select(false, (Lit.counts.y & ENV_AMBIENT_SKY) != 0u, SPEC_AMBIENT_GRADIENT)) {
        let sky_avg = (Lit.sky_top.rgb + Lit.sky_horizon.rgb) * 0.5;
        return mix(sky(dir), sky_avg, roughness) * Lit.ambient.w;
    }
    return Lit.ambient.rgb;
}

// ext_radiance at the fragment of `e` with the reflection probes over it
// (milestone 20, data.as's accumulation) in a lit frame that has probes;
// exactly ext_radiance's light in every other frame. The reflections (the
// base layer's and the clearcoat's) read it; the light seen through a
// transmissive surface stays the environment's.
fn ext_probe_radiance(e: ExtCtx, dir: vec3<f32>, roughness: f32, lit_mode: bool) -> vec3<f32> {
    let sky_light = ext_radiance(dir, roughness, lit_mode);
    if (select(true, !lit_mode || Probe.counts.x == 0u, SPEC_PROBES)) {
        return sky_light;
    }
    let pr = probe_reflection(e.world, dir, roughness, O.extra.z);
    return sky_light * (1.0 - pr.w) + pr.rgb;
}

// The weight of the environment's specular light for reflectance f0/f90 at
// `roughness`: today's per mode (Godot's environment BRDF with a sky,
// pbr()'s and lit()'s roughness-aware Fresnel otherwise), with F90.
fn ext_env_weight(f0: vec3<f32>, f90: vec3<f32>, roughness: f32, nv: f32, metallic: f32, lit_mode: bool) -> vec3<f32> {
    if (select(false, lit_mode && (Sky.flags.x & SKY_IBL) != 0u, SPEC_AMBIENT_SKY)) {
        let e = env_brdf_approx(roughness, nv);
        return f0 * e.x + f90 * e.y * clamp(50.0 * f0.g, metallic, 1.0);
    }
    let f_amb = f0 + (max(f90 * (1.0 - roughness), f0) - f0) * pow5(1.0 - nv);
    if (select(false, !lit_mode, SPEC_MATERIAL_MODE)) {
        return f_amb * (1.0 - 0.5 * roughness);
    }
    return f_amb;
}

// Milestone 62: the screen texture's texel coordinates (0 to 1, y down the
// picture's rows) of the frame world's point `p` (its projection, as the
// fragment's own clip position is: SSAO's ndc rule turned around).
fn screen_uv_of(p: vec3<f32>) -> vec2<f32> {
    let c = G.view_proj * vec4<f32>(p, 1.0);
    let ndc = c.xy / select(1e-6, c.w, c.w > 1e-6);
    return vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
}

// Milestone 62: the opaque picture at `uv`, blurred to the level of
// transmission roughness `rough` (render/screen.as refractionLod: the
// Khronos sample viewer's log2(width) * rough, held to the texture's mips).
fn screen_texel(uv: vec2<f32>, rough: f32) -> vec3<f32> {
    let levels = f32(max(Lit.dirs.w, 1u));
    let lod = min(log2(max(G.viewport.x, 1.0)) * max(rough, 0.0), levels - 1.0);
    return textureSampleLevel(t_screen, s_radiance, uv, lod).rgb;
}

// Milestone 62: where the view ray, bent by `ior` at the surface, leaves a
// volume of the surface's thickness, on the screen (the Khronos sample
// viewer's getVolumeTransmissionRay, with the node's scale).
fn screen_exit_uv(e: ExtCtx, ior: f32) -> vec2<f32> {
    let dir = refract(-e.v, e.n, 1.0 / ior);
    return screen_uv_of(e.world + dir * e.thickness);
}

// Milestone 62: ext_refracted's radiance from the screen texture (the lit
// block's ENV_SCREEN_REFRACTION): what lies behind the glass in the opaque
// picture. A thin wall moves its own texel by Godot's refraction_scale
// along its view-space normal (render/screen.as thinRefractionOffset; the
// material block's factors.z); a volume samples where the bent ray leaves
// it, one exit a channel with dispersion. What it refracts is the opaque
// picture alone (glass behind glass is not in it), seen whatever lies
// between the glass and the eye (Godot's limits).
fn ext_screen_refracted(e: ExtCtx, rough: f32) -> vec3<f32> {
    if (e.thin) {
        let n_view = normalize((G.view * vec4<f32>(e.n, 0.0)).xyz);
        let offset = vec2<f32>(-n_view.x, n_view.y) * M.factors.z;
        return screen_texel(e.frag * G.viewport.zw + offset, rough) * e.attenuation;
    }
    if (select(false, e.dispersion > 0.0, SPEC_DISPERSION)) {
        let half_spread = (e.ior - 1.0) * 0.025 * e.dispersion;
        let r = screen_texel(screen_exit_uv(e, max(e.ior - half_spread, 1.0)), rough).r;
        let g = screen_texel(screen_exit_uv(e, e.ior), rough).g;
        let b = screen_texel(screen_exit_uv(e, e.ior + half_spread), rough).b;
        return vec3<f32>(r, g, b) * e.attenuation;
    }
    return screen_texel(screen_exit_uv(e, e.ior), rough) * e.attenuation;
}

// The environment seen through the surface (KHR_materials_transmission,
// _volume and _dispersion, approximated: there is no copy of the scene
// behind, so the environment is what refracts): along the view ray bent by
// the ior (straight through when thin-walled), per channel with dispersion
// (KHR_materials_dispersion's spread, ior +- (ior - 1) 0.025 dispersion),
// blurred by the transmission roughness, attenuated by the volume.
// Milestone 62: in a frame that refracts the screen (ENV_SCREEN_REFRACTION,
// the lit mode alone), the copy of the scene behind instead
// (ext_screen_refracted).
fn ext_refracted(e: ExtCtx, lit_mode: bool) -> vec3<f32> {
    let rough = sqrt(e.trans_alpha);
    if (select(false, lit_mode && (Lit.counts.y & ENV_SCREEN_REFRACTION) != 0u && Lit.dirs.w > 0u, SPEC_SCREEN_REFRACTION)) {
        return ext_screen_refracted(e, rough);
    }
    if (e.thin) {
        return ext_radiance(-e.v, rough, lit_mode) * e.attenuation;
    }
    if (select(false, e.dispersion > 0.0, SPEC_DISPERSION)) {
        let half_spread = (e.ior - 1.0) * 0.025 * e.dispersion;
        let iors = vec3<f32>(max(e.ior - half_spread, 1.0), e.ior, e.ior + half_spread);
        let rr = ext_radiance(refract(-e.v, e.n, 1.0 / iors.r), rough, lit_mode).r;
        let rg = ext_radiance(refract(-e.v, e.n, 1.0 / iors.g), rough, lit_mode).g;
        let rb = ext_radiance(refract(-e.v, e.n, 1.0 / iors.b), rough, lit_mode).b;
        return vec3<f32>(rr, rg, rb) * e.attenuation;
    }
    return ext_radiance(refract(-e.v, e.n, 1.0 / e.ior), rough, lit_mode) * e.attenuation;
}

// The environment's light on the extended material, layered as ext_light
// layers a light's (before occlusion). Milestone 19: `gi` with w 1 is a
// bake's diffuse light (gi_diffuse), which replaces the front's diffuse
// ambient light as in lit(); w 0 leaves everything as it was.
fn ext_ambient(e: ExtCtx, lit_mode: bool, gi: vec4<f32>) -> vec3<f32> {
    let nv = e.nv;
    var diffuse = e.diffuse * ext_irradiance(e.n, lit_mode);
    if (select(false, lit_mode && (Sky.flags.x & SKY_IBL) == 0u && (Lit.counts.y & ENV_AMBIENT_SKY) == 0u, SPEC_AMBIENT_FLAT)) {
        // A flat ambient colour: lit()'s ambient * (diffuse + f_amb).
        diffuse = Lit.ambient.rgb * e.diffuse;
    }
    if (select(false, lit_mode && Probe.counts.x > 0u && gi.w <= 0.0, SPEC_PROBES)) {
        // Milestone 20: the probes' ambient light over the environment's.
        let pa = probe_ambient(e.world, e.n, O.extra.z);
        diffuse = diffuse * (1.0 - pa.w) + e.diffuse * pa.rgb;
    }
    if (gi.w > 0.0) {
        diffuse = e.diffuse * gi.rgb;
    }
    if (select(false, e.dt > 0.0, SPEC_DIFFUSE_TRANSMISSION)) {
        diffuse = mix(diffuse, e.dt_color * (1.0 - e.metallic) * ext_irradiance(-e.n_geo, lit_mode), e.dt);
    }
    // The reflection: along the bent normal with anisotropy (the
    // extension's single-sample form), else the mirror direction.
    var r = reflect(-e.v, e.n);
    if (select(false, e.aniso > 0.0, SPEC_ANISOTROPY)) {
        var bent = normalize(cross(cross(e.aniso_b, e.v), e.aniso_b));
        let a = pow(1.0 - e.aniso * (1.0 - e.roughness), 4.0);
        bent = normalize(mix(bent, e.n, a));
        r = normalize(mix(reflect(-e.v, bent), bent, e.roughness * e.roughness));
    }
    let f0 = mix(e.f0, e.irid_f, e.iridescence);
    let f90 = mix(e.f90, vec3<f32>(1.0), e.iridescence);
    let spec_w = ext_env_weight(f0, f90, e.roughness, nv, e.metallic, lit_mode);
    let specular = ext_probe_radiance(e, r, e.roughness, lit_mode) * spec_w;
    if (select(false, e.transmission > 0.0, SPEC_TRANSMISSION)) {
        let through = (vec3<f32>(1.0) - spec_w) * e.base * ext_refracted(e, lit_mode) * (1.0 - e.metallic);
        diffuse = mix(diffuse, through, e.transmission);
    }
    var c = diffuse + specular;
    if (select(false, max3(e.sheen) > 0.0, SPEC_SHEEN)) {
        let ea = sheen_albedo(nv, e.sheen_roughness);
        c = c * (1.0 - max3(e.sheen) * ea) + e.sheen * ext_irradiance(e.n, lit_mode) * ea;
    }
    if (select(false, e.clearcoat > 0.0, SPEC_CLEARCOAT)) {
        let ncv = max(dot(e.nc, e.v), 1e-4);
        let fc = f_schlick90(vec3<f32>(0.04), vec3<f32>(1.0), ncv).x;
        let cw = ext_env_weight(vec3<f32>(0.04), vec3<f32>(1.0), e.cc_roughness, ncv, 0.0, lit_mode);
        c = c * (1.0 - e.clearcoat * fc) + e.clearcoat * ext_probe_radiance(e, reflect(-e.v, e.nc), e.cc_roughness, lit_mode) * cw;
    }
    return c;
}

// pbr() (material mode: the studio rig in view space, the built-in
// gradient) and lit() (the frame's lights and environment and SSAO; the
// fog and the tone map are ext_lit_finish's) for an extended material, in
// world space.
fn ext_shade(in: VsOutExt, front: bool, s: ExtSamples, lit_mode: bool) -> vec3<f32> {
    return ext_shade_with(in, front, s, lit_mode, false, vec3<f32>(0.0));
}

// ext_shade of a lightmapped surface (milestone 19) when `baked`, as lit_with
// is lit()'s: in the lit mode, the static lights skipped and the diffuse
// ambient light the lightmap's sample `baked_light`; and an item with probe
// light takes its diffuse ambient light from them, as in lit().
fn ext_shade_with(
    in: VsOutExt, front: bool, s: ExtSamples, lit_mode: bool, baked: bool, baked_light: vec3<f32>,
) -> vec3<f32> {
    // (decals in the lit shading only, as lit_with paints them; never in
    // the unlit branch below)
    let e = ext_ctx(in, front, s, select(false, lit_mode && O.decals.z > 0u, SPEC_DECALS));
    var c = vec3<f32>(0.0);
    if (select(false, !lit_mode, SPEC_MATERIAL_MODE)) {
        // pbr()'s rig is in view space: its directions to world space
        // (the view's rotation is orthonormal: its transpose inverts it).
        let to_world = transpose(mat3x3<f32>(G.view[0].xyz, G.view[1].xyz, G.view[2].xyz));
        c += ext_light(e, normalize(to_world * vec3<f32>(-0.45, 0.55, 0.70)), vec3<f32>(1.0, 0.97, 0.92) * 2.6, 1.0, false);
        c += ext_light(e, normalize(to_world * vec3<f32>(0.75, 0.15, 0.45)), vec3<f32>(0.85, 0.90, 1.0) * 0.9, 1.0, false);
        c += ext_light(e, normalize(to_world * vec3<f32>(0.30, 0.55, -0.60)), vec3<f32>(1.0) * 1.3, 1.0, false);
        c += ext_ambient(e, false, vec4<f32>(0.0)) * s.occlusion;
        c += s.emission;
        return c;
    }
    // (the item's own lights, as lit_with's)
    let count = object_light_count();
    for (var k = 0u; select(false, k < count, SPEC_LIGHTS); k++) {
        let i = object_light(k);
        let li = Lit.lights[i];
        if (baked && li.info.z == LIGHT_BAKED_STATIC) {
            continue;
        }
        let kind = li.info.x;
        var l: vec3<f32>;
        var atten = 1.0;
        if (kind == LIGHT_DIRECTIONAL) {
            l = -li.direction.xyz;
        } else {
            let rel = li.position.xyz - in.world;
            let d = length(rel);
            l = rel / max(d, 1e-6);
            atten = omni_attenuation(d, li.position.w, li.direction.w);
            if (kind == LIGHT_SPOT) {
                let cone = li.spot.x;
                let scos = max(dot(-l, li.direction.xyz), cone);
                let rim = max(1e-4, (1.0 - scos) / max(1.0 - cone, 1e-6));
                atten *= 1.0 - pow(rim, li.spot.y);
            }
        }
        if (atten > 0.0) {
            var rad = li.color.rgb * atten;
            if (select(false, li.info.y == LIGHT_SHADOWED, SPEC_SHADOWS)) {
                rad = li.color.rgb * (atten * shadow_factor(i, in.world, e.n_geo, l));
            }
            c += ext_light(e, l, rad, li.spot.z, true);
        }
    }
    let ambient = ext_ambient(e, true, gi_diffuse(e.n, baked, baked_light));
    if (select(false, (Lit.counts.y & ENV_SSAO) != 0u && M.flags.y != ALPHA_BLEND, SPEC_SSAO)) {
        let ssao = textureLoad(t_ao, vec2<i32>(floor(in.clip.xy)), 0).r;
        c *= mix(1.0, min(ssao, e.occlusion), Lit.tone.z * Lit.tone.w);
        c += ambient * min(e.occlusion, ssao);
    } else {
        c += ambient * e.occlusion;
    }
    c += e.emission;
    // (the fog and the tone map are the entry point's: ext_lit_finish)
    return c;
}

// The lit mode's end of an extended material's colour `c` at `world`
// (ext_shade_with's, or an unlit material's base colour): Godot's depth
// and height fog, milestone 37's fog volumes behind the item's word, and
// the tone map. One call an entry point (fs_surface_ext, fs_surface_ext_lm),
// so that each target writes the fog volumes' code once in it.
fn ext_lit_finish(c_in: vec3<f32>, world: vec3<f32>) -> vec3<f32> {
    var c = c_in;
    if (select(false, (Sky.flags.x & SKY_FOG) != 0u, SPEC_FOG)) {
        c = surface_fog(c, world, -ext_view(world));
    }
    if (select(false, O.decals.w != 0u, SPEC_FOG_VOLUMES)) {
        c = fog_volumes(c, world, O.decals.w);
    }
    return tonemap(c);
}

// fs_surface for an extended material (drawn only in the material, lit and
// lightmap modes): its alpha handling, then ext_shade, or the base colour
// alone when unlit (KHR_materials_unlit; the lit mode still fogs and tone
// maps it, as Godot's unshaded material is).
@fragment
fn fs_surface_ext(in: VsOutExt, @builtin(front_facing) facing: bool) -> @location(0) vec4<f32> {
    let front = facing != mirrored(ext_base_in(in));
    let s = sample_ext(in);
    if (select(false, (in.flags & F_HIDDEN) != 0u, SPEC_FACE_FLAGS)) {
        discard;
    }
    let shown = emerge_reveal(in.world, in.clip.xy);
    if (select(false, shown <= 0.0, SPEC_EMERGE)) {
        discard;
    }
    if (ext_cut(s)) {
        discard;
    }
    var alpha = 1.0;
    if (select(false, M.flags.y == ALPHA_BLEND, SPEC_ALPHA_BLEND)) {
        alpha = s.base.a;
    }
    let lit_mode = select(false, G.params.x == SHADE_LIT, SPEC_LIT);
    var c: vec3<f32>;
    if (select(false, G.params.x == SHADE_LIGHTMAP, SPEC_OTHER_MODES)) {
        // Milestone 19: the lightmap shading draws what is not lightmapped
        // as SHADE_SOLID (fs_surface's last branch).
        alpha = 1.0;
        let n_world = select(-normalize(in.normal), normalize(in.normal), front);
        c = studio(normalize((G.view * vec4<f32>(n_world, 0.0)).xyz), srgb_to_linear(vec3<f32>(0.8)));
    } else {
        if (select(false, (M.flags.w & MAT_UNLIT) != 0u, SPEC_UNLIT)) {
            c = s.base.rgb;
        } else {
            c = ext_shade(in, front, s, lit_mode);
        }
        if (select(false, lit_mode, SPEC_LIT)) {
            c = ext_lit_finish(c, in.world);
        }
    }
    if (select(false, O.params.w == 1u && (G.params.y & OV_SELECTION) != 0u && (in.flags & F_SELECTED) != 0u, SPEC_FACE_FLAGS)) {
        c = mix(c, srgb_to_linear(vec3<f32>(1.0, 0.635, 0.0)), 0.4);
    }
    if (select(false, lit_mode, SPEC_LIT)) {
        return lit_output(vec4<f32>(emerge_tint(item_fade(c), shown), alpha));
    }
    return target_color(vec4<f32>(c, alpha));
}

// fs_shadow, fs_id and fs_normal_depth for an extended material (drawn
// with these only when it is masked: the cut-out follows the base
// texture's own transform and UV set; milestone 62: and fs_normal_depth_ext
// for every extended range of a frame with the screen-space reflections,
// whose F0 is then its own: its ior, specular and metal).
@fragment
fn fs_shadow_ext(in: VsOutExt) {
    let s = sample_ext(in);
    if ((in.flags & F_HIDDEN) != 0u) {
        discard;
    }
    if (emerge_reveal(in.world, vec2<f32>(-1.0)) <= 0.0) {
        discard;
    }
    if (ext_cut(s)) {
        discard;
    }
}

@fragment
fn fs_id_ext(in: VsOutExt) -> IdOut {
    let s = sample_ext(in);
    if ((in.flags & F_HIDDEN) != 0u) {
        discard;
    }
    if (emerge_reveal(in.world, in.clip.xy) <= 0.0) {
        discard;
    }
    if (ext_cut(s)) {
        discard;
    }
    let id = O.params.z;
    let bits = select(0u, 1u, O.params.x == 1u) | select(0u, 2u, O.params.y == 1u);
    var out: IdOut;
    out.id = vec4<f32>(
        f32(id & 255u), f32((id >> 8u) & 255u), f32((id >> 16u) & 255u), f32(bits)) / 255.0;
    return out;
}

@fragment
fn fs_normal_depth_ext(in: VsOutExt, @builtin(front_facing) facing: bool) -> NormalDepthOut {
    let s = sample_ext(in);
    if ((in.flags & F_HIDDEN) != 0u) {
        discard;
    }
    if (emerge_reveal(in.world, in.clip.xy) <= 0.0) {
        discard;
    }
    if (ext_cut(s)) {
        discard;
    }
    let front = facing != mirrored(ext_base_in(in));
    let n_world = select(-normalize(in.normal), normalize(in.normal), front);
    let n_view = normalize((G.view * vec4<f32>(n_world, 0.0)).xyz);
    // (ext_ctx's F0 and roughness, without the decals, as fs_normal_depth's)
    let e = ext_ctx(in, front, s, false);
    var out: NormalDepthOut;
    out.normal_depth = vec4<f32>(n_view, -(G.view * vec4<f32>(in.world, 1.0)).z);
    out.surface = vec4<f32>(clamp(e.f0, vec3<f32>(0.0), vec3<f32>(1.0)), e.roughness);
    return out;
}

// ================================================================ lightmaps

// Baked lighting (milestone 19, Godot's LightmapGI). The lightmap pipelines
// (gpu/pipelines.as `lightmapPipelines`) draw an item with OBJ_LIGHTMAP in
// the main pass of the lit and lightmap modes: the surface vertex, UV set 1
// (location 10, as the extended pipelines read it) and the vertex's place
// in the item's lightmap layer (location 11, layouts.as LM_UV_ATTRS). Every
// other pass, and every other item, draws with the entries above, so
// nothing here is reached by a frame without a bake.

// VsOutExt plus the lightmap coordinate.
struct VsOutLm {
    @builtin(position) clip: vec4<f32>,
    @location(0) world: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) @interpolate(flat) flags: u32,
    @location(4) tangent: vec4<f32>,
    @location(5) weight: f32,
    @location(6) color: vec4<f32>,
    @location(7) uv1: vec2<f32>,
    @location(8) uv_lm: vec2<f32>,
};

@vertex
fn vs_surface_lm(in: VsIn, @location(10) uv1: vec2<f32>, @location(11) uv_lm: vec2<f32>) -> VsOutLm {
    let o = surface_vertex(in);
    var out: VsOutLm;
    out.clip = o.clip;
    out.world = o.world;
    out.normal = o.normal;
    out.uv = o.uv;
    out.flags = o.flags;
    out.tangent = o.tangent;
    out.weight = o.weight;
    out.color = o.color;
    out.uv1 = uv1;
    out.uv_lm = uv_lm;
    return out;
}

fn lm_ext_in(l: VsOutLm) -> VsOutExt {
    var e: VsOutExt;
    e.clip = l.clip;
    e.world = l.world;
    e.normal = l.normal;
    e.uv = l.uv;
    e.flags = l.flags;
    e.tangent = l.tangent;
    e.weight = l.weight;
    e.color = l.color;
    e.uv1 = l.uv1;
    return e;
}

// The baked light at the fragment: the item's layer (ObjectU.extra.y) at
// its lightmap coordinate, bilinear. An explicit level, so the lookup is
// valid in non-uniform control flow.
fn lightmap_light(uv_lm: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(t_lightmap, s_lightmap, uv_lm, i32(O.extra.y), 0.0).rgb;
}

// fs_surface of a lightmapped item with a plain material. The lightmap mode
// draws the baked light alone, as on a white surface, through the
// environment's exposure and tone map; the lit mode is fs_surface's, with
// lit_with's baked light.
@fragment
fn fs_surface_lm(in: VsOutLm, @builtin(front_facing) facing: bool) -> @location(0) vec4<f32> {
    let base = ext_base_in(lm_ext_in(in));
    let front = facing != mirrored(base);
    let samples = surface_samples(base);
    if (select(false, (in.flags & F_HIDDEN) != 0u, SPEC_FACE_FLAGS)) {
        discard;
    }
    let shown = emerge_reveal(in.world, in.clip.xy);
    if (select(false, shown <= 0.0, SPEC_EMERGE)) {
        discard;
    }
    let baked_light = lightmap_light(in.uv_lm);
    var c: vec3<f32>;
    var alpha = 1.0;
    if (select(false, G.params.x == SHADE_LIGHTMAP, SPEC_OTHER_MODES)) {
        c = tonemap(baked_light);
    } else {
        if (select(false, M.flags.y == ALPHA_MASK && samples.base.a < M.emission.w, SPEC_ALPHA_MASK)) {
            discard;
        }
        if (select(false, M.flags.y == ALPHA_BLEND, SPEC_ALPHA_BLEND)) {
            alpha = samples.base.a;
        }
        c = lit_with(base, front, samples, true, baked_light);
    }
    if (select(false, O.params.w == 1u && (G.params.y & OV_SELECTION) != 0u && (in.flags & F_SELECTED) != 0u, SPEC_FACE_FLAGS)) {
        c = mix(c, srgb_to_linear(vec3<f32>(1.0, 0.635, 0.0)), 0.4);
    }
    return lit_output(vec4<f32>(emerge_tint(item_fade(c), shown), alpha));
}

// fs_surface_ext of a lightmapped item with an extended material: the
// lightmap mode as fs_surface_lm; the lit mode fs_surface_ext's, with
// ext_shade_with's baked light (an unlit material is its base colour, as
// there).
@fragment
fn fs_surface_ext_lm(in: VsOutLm, @builtin(front_facing) facing: bool) -> @location(0) vec4<f32> {
    let ext = lm_ext_in(in);
    let front = facing != mirrored(ext_base_in(ext));
    let s = sample_ext(ext);
    if (select(false, (in.flags & F_HIDDEN) != 0u, SPEC_FACE_FLAGS)) {
        discard;
    }
    let shown = emerge_reveal(in.world, in.clip.xy);
    if (select(false, shown <= 0.0, SPEC_EMERGE)) {
        discard;
    }
    let baked_light = lightmap_light(in.uv_lm);
    var c: vec3<f32>;
    var alpha = 1.0;
    if (select(false, G.params.x == SHADE_LIGHTMAP, SPEC_OTHER_MODES)) {
        c = tonemap(baked_light);
    } else {
        if (ext_cut(s)) {
            discard;
        }
        if (select(false, M.flags.y == ALPHA_BLEND, SPEC_ALPHA_BLEND)) {
            alpha = s.base.a;
        }
        if (select(false, (M.flags.w & MAT_UNLIT) != 0u, SPEC_UNLIT)) {
            c = s.base.rgb;
        } else {
            c = ext_shade_with(ext, front, s, true, true, baked_light);
        }
        c = ext_lit_finish(c, in.world);
    }
    if (select(false, O.params.w == 1u && (G.params.y & OV_SELECTION) != 0u && (in.flags & F_SELECTED) != 0u, SPEC_FACE_FLAGS)) {
        c = mix(c, srgb_to_linear(vec3<f32>(1.0, 0.635, 0.0)), 0.4);
    }
    return lit_output(vec4<f32>(emerge_tint(item_fade(c), shown), alpha));
}

// ================================================================ skinning

// GPU linear blend skinning (Godot's Skeleton3D and skinned
// MeshInstance3D; docs/engine/ANIMATION.md, "Skeletons and imported
// clips"). A skinned item (OBJ_SKINNED) draws its mesh as the mesh stores it
// (the bind pose), each vertex moved by the weighted sum of four of the
// item's palette matrices: Skin.rows holds, per palette slot k, the three
// rows of a 3 x 4 matrix taking a point of the stored mesh straight into
// the frame's world space (renderer-from-scene * the skeleton's global *
// the bone's pose * its inverse bind), so O.model is the identity for such
// an item. The vertex's slots and weights are their own vertex buffer
// (layouts.as SKIN_ATTRS: locations 12 and 13, after UV set 1's 10 and the
// lightmap's 11, so a skinned item with an extended material still reads
// UV set 1). The palette is
// a uniform rather than a storage buffer, which the Rive GPU API does not
// have: 255 joints of 48 bytes (12,240 bytes) fit the 16,384 bytes every
// device offers. The pipelines that draw it (gpu/pipelines.as
// `skinnedOf`) are the plain, extended and top ones with these vertex
// entries; a lightmapped or instanced item is never skinned. Nothing above
// reaches this block, so every item that is not skinned draws exactly the
// code it drew before.

// ---- BEGIN shared: skin ----
const OBJ_SKINNED: u32 = 16u;       // ObjectU.extra.x: drawn with the skinned entries below
const SKIN_JOINTS: u32 = 255u;      // layouts.as SKIN_UNIFORM_JOINTS

struct SkinU {                      // 12240 bytes (layouts.as SKIN_UNIFORM_SIZE)
    rows: array<vec4<f32>, 765>,    // per joint k: rows 3k, 3k + 1, 3k + 2
};
@group(1) @binding(1) var<uniform> Skin: SkinU;

struct SkinIn {
    @location(12) joints: vec4<u32>,
    @location(13) weights: vec4<f32>,
};

// The blended matrix of a vertex, as its three rows.
struct SkinRows {
    r0: vec4<f32>,
    r1: vec4<f32>,
    r2: vec4<f32>,
};

// Row `r` of palette slot `k` (a slot past the palette reads its last).
fn skin_row(k: u32, r: u32) -> vec4<f32> {
    return Skin.rows[min(k, SKIN_JOINTS - 1u) * 3u + r];
}

fn skin_rows(s: SkinIn) -> SkinRows {
    let j = s.joints;
    let w = s.weights;
    var m: SkinRows;
    m.r0 = w.x * skin_row(j.x, 0u) + w.y * skin_row(j.y, 0u) + w.z * skin_row(j.z, 0u) + w.w * skin_row(j.w, 0u);
    m.r1 = w.x * skin_row(j.x, 1u) + w.y * skin_row(j.y, 1u) + w.z * skin_row(j.z, 1u) + w.w * skin_row(j.w, 1u);
    m.r2 = w.x * skin_row(j.x, 2u) + w.y * skin_row(j.y, 2u) + w.z * skin_row(j.z, 2u) + w.w * skin_row(j.w, 2u);
    return m;
}
// ---- END shared: skin ----

// vs_surface for a skinned vertex: the point through the blended matrix
// into the frame's world space; the normal through the cofactor of its
// 3 x 3 (its inverse transpose times the determinant, exact under a
// non-uniform scale too, and the matrix itself up to scale for a rotation
// and a uniform scale), negated when the determinant is negative so it
// keeps facing out, and the tangent through the 3 x 3, both normalised. A
// mirroring matrix sets F_INSTANCE_MIRRORED, which `mirrored` reads as for
// an instance (the item's own OBJ_MIRRORED is clear: its world is the
// identity).
fn skinned_vertex(in: VsIn, s: SkinIn) -> VsOut {
    let m = skin_rows(s);
    let p = vec4<f32>(in.pos, 1.0);
    let world = vec4<f32>(dot(m.r0, p), dot(m.r1, p), dot(m.r2, p), 1.0);
    // The 3 x 3's columns (its X, Y and Z axes).
    let bx = vec3<f32>(m.r0.x, m.r1.x, m.r2.x);
    let by = vec3<f32>(m.r0.y, m.r1.y, m.r2.y);
    let bz = vec3<f32>(m.r0.z, m.r1.z, m.r2.z);
    let det = dot(bx, cross(by, bz));
    let flip = det < 0.0;
    let cofactor = mat3x3<f32>(cross(by, bz), cross(bz, bx), cross(bx, by));
    let n = cofactor * in.normal * select(1.0, -1.0, flip);
    let t = mat3x3<f32>(bx, by, bz) * in.tangent.xyz;
    var out: VsOut;
    out.clip = G.view_proj * world;
    out.world = world.xyz;
    out.normal = normalize(n);
    out.uv = in.uv;
    out.flags = in.flags | select(0u, F_INSTANCE_MIRRORED, flip);
    let mirror = select(1.0, -1.0, ((O.extra.x & OBJ_MIRRORED) != 0u) != flip);
    out.tangent = vec4<f32>(normalize(t), in.tangent.w * mirror);
    out.weight = in.weight;
    out.color = vec4<f32>(1.0);
    return out;
}

// The skinned item's vertex entry of every pass that draws VsOut: the main
// pass (fs_surface), the shadow pass (no fragment stage, or fs_shadow), the
// id pass (fs_id) and SSAO's normal-depth pass (fs_normal_depth), with the
// skin's vertex buffer after the vertices (pipelines.as SKIN_SLOT).
@vertex
fn vs_surface_skinned(in: VsIn, s: SkinIn) -> VsOut {
    return skinned_vertex(in, s);
}

// The same for an extended material (fs_surface_ext, fs_id_ext,
// fs_normal_depth_ext, fs_shadow_ext), UV set 1 after the skin's buffer
// (pipelines.as SKIN_UV1_SLOT, where an instanced draw has it too).
@vertex
fn vs_surface_ext_skinned(in: VsIn, s: SkinIn, @location(10) uv1: vec2<f32>) -> VsOutExt {
    return ext_vs_out(skinned_vertex(in, s), uv1);
}
