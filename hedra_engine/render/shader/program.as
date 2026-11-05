// A custom shader as the renderer draws it: Godot's ShaderMaterial with WGSL
// in place of Godot's shading language (docs/engine/SHADERS.md). A shader
// file (`.wgsl`, an ext_resource of type Shader) is WGSL with Godot's
// declarations on top:
//
//   shader_type spatial;                     the only type: a surface's
//   render_mode unshaded, cull_disabled;     Godot's spatial render modes
//   group_uniforms Look;                     the Inspector's groups
//   uniform tint: vec4<f32> : source_color = vec4<f32>(1.0, 0.5, 0.2, 1.0);
//   uniform noise: texture_2d<f32> : filter_linear_mipmap, repeat_enable;
//   group_uniforms;
//   fn vertex() { ... }  fn fragment() { ... }  fn light() { ... }
//
// ./parse.as reads the declarations into a ShaderProgram (what follows),
// ./layout.as places the uniforms in the parameters' block, and the
// compiler (hedra_compiler/shader/compose.as) splices the code into the
// engine's surface template; the GPU side (../gpu/custom.as) draws with
// the module a ShaderModuleSource (./modules.as) gives for the program's
// key. Nothing here reads a file or knows a scene: the render tier never
// imports the scene tier.
//
// Normative for every part of the milestone: the names and numbers below
// are the format's (docs/formats/RSCN.md "Shaders"), the composer's and
// the GPU side's. Change one and all three change.

import { sha256Text } from "../../base/sha256";

// The extension of a shader file (classdb's Shader takes no other).
export const SHADER_EXTENSION = "wgsl";
// The folder of a Rive project where `hedra build` writes each composed
// shader, `hedra_shaders/<project>/<key>.wgsl` (rive compiles it with the
// library's shaders; the run time finds it by its asset name, the path
// without `.wgsl`). A reserved name, as `hedra_engine` is.
export const SHADERS_DIR = "hedra_shaders";
// How many hex digits of a shader's SHA-256 make its key.
export const SHADER_KEY_HEX: i32 = 16;

// The limits (WebGL 2: 16 texture units a stage, the template takes 7; a
// bind group holds bindings 0 to 7 in the pinned runtime, the parameters'
// block is binding 0 of group 2): a shader holds at most this many texture
// uniforms, and its textures and distinct samplers together take at most
// MAX_SHADER_SLOTS bindings (1 to 7).
export const MAX_SHADER_TEXTURES: i32 = 6;
export const MAX_SHADER_SLOTS: i32 = 7;
// At most this many uniforms, and a block of at most this many bytes
// (WebGL 2's uniform blocks hold 16 KB; the rest is the engine's).
export const MAX_SHADER_UNIFORMS: i32 = 64;
export const MAX_PARAM_BLOCK_BYTES: i32 = 4096;
// The smallest block (a shader without uniforms still binds one: WGSL has
// no empty struct).
export const MIN_PARAM_BLOCK_BYTES: i32 = 16;
// TIME wraps at this many seconds, as Godot's does by default
// (rendering/limits/time/time_rollover_secs).
export const SHADER_TIME_ROLLOVER: f64 = 3600;

// A uniform's type, as WGSL spells it (UNIFORM_TYPE_NAMES; the shorthand
// `vec4f` and `vec2i` is read too). Godot's matrices, arrays, uvec and
// samplers other than texture_2d are not in the format
// (shader-uniform-type-unsupported).
export enum UniformType {
    Float,
    Int,
    UInt,
    Bool,
    Vec2,
    Vec3,
    Vec4,
    IVec2,
    IVec3,
    IVec4,
    Texture2D,
}

// UniformType's names, in its order, as the file writes them.
export const UNIFORM_TYPE_NAMES: StaticArray<string> = [
    "f32", "i32", "u32", "bool", "vec2<f32>", "vec3<f32>", "vec4<f32>", "vec2<i32>", "vec3<i32>", "vec4<i32>",
    "texture_2d<f32>",
];

// How many numbers a value of `t` has (0 for a texture).
export function uniformComponents(t: UniformType): i32 {
    switch (t) {
        case UniformType.Vec2:
        case UniformType.IVec2: return 2;
        case UniformType.Vec3:
        case UniformType.IVec3: return 3;
        case UniformType.Vec4:
        case UniformType.IVec4: return 4;
        case UniformType.Texture2D: return 0;
        default: return 1;
    }
}

// Whether a value of `t` is whole numbers.
export function uniformIsInteger(t: UniformType): bool {
    return t == UniformType.Int || t == UniformType.UInt || t == UniformType.IVec2 || t == UniformType.IVec3
        || t == UniformType.IVec4;
}

// A uniform's hints (ShaderUniform.hints), Godot's.
export const HINT_SOURCE_COLOR: u32 = 1;      // vec3/vec4: an sRGB colour (Color in the file), linear in the shader; texture: sRGB texels
export const HINT_RANGE: u32 = 2;             // f32/i32: hint_range(min, max[, step]), the Inspector's slider
export const HINT_NORMAL: u32 = 4;            // texture: a normal map (hint_normal), flat when unset
export const HINT_DEFAULT_WHITE: u32 = 8;     // texture: white when unset (Godot's default for a texture)
export const HINT_DEFAULT_BLACK: u32 = 16;    // texture: black when unset
export const HINT_DEFAULT_TRANSPARENT: u32 = 32; // texture: transparent black when unset

// A texture's filter (Godot's filter_* hints, in this order; Godot's
// default for a texture uniform is filter_linear_mipmap).
export const FILTER_NEAREST: i32 = 0;
export const FILTER_LINEAR: i32 = 1;
export const FILTER_NEAREST_MIPMAP: i32 = 2;
export const FILTER_LINEAR_MIPMAP: i32 = 3;
export const FILTER_NEAREST_MIPMAP_ANISOTROPIC: i32 = 4;
export const FILTER_LINEAR_MIPMAP_ANISOTROPIC: i32 = 5;
export const FILTER_NAMES: StaticArray<string> = [
    "filter_nearest", "filter_linear", "filter_nearest_mipmap", "filter_linear_mipmap",
    "filter_nearest_mipmap_anisotropic", "filter_linear_mipmap_anisotropic",
];

// The sampler a texture uniform is read with: its filter and whether it
// repeats (repeat_enable, Godot's default, or repeat_disable: clamped).
// Textures of one kind share one sampler binding.
export function samplerKind(filter: i32, repeat: bool): i32 {
    return filter * 2 + (repeat ? 1 : 0);
}

// The WGSL name of the sampler of kind `kind`, which the composer declares
// and the user's code may name: SAMPLER_LINEAR_MIPMAP_REPEAT,
// SAMPLER_NEAREST_CLAMP, ...
export function samplerName(kind: i32): string {
    const f = kind >> 1;
    const filter = f >= 0 && f < FILTER_NAMES.length ? FILTER_NAMES[f].substring(7).toUpperCase() : "LINEAR_MIPMAP";
    return "SAMPLER_" + filter + ((kind & 1) != 0 ? "_REPEAT" : "_CLAMP");
}

// Godot's spatial render modes, as the program holds them.
export const BLEND_MIX: i32 = 0;
export const BLEND_ADD: i32 = 1;
export const BLEND_SUB: i32 = 2;
export const BLEND_MUL: i32 = 3;
export const BLEND_PREMUL_ALPHA: i32 = 4;
export const DEPTH_DRAW_OPAQUE: i32 = 0;
export const DEPTH_DRAW_ALWAYS: i32 = 1;
export const DEPTH_DRAW_NEVER: i32 = 2;
export const CULL_BACK: i32 = 0;
export const CULL_FRONT: i32 = 1;
export const CULL_DISABLED: i32 = 2;
export const DIFFUSE_LAMBERT: i32 = 0;
export const DIFFUSE_LAMBERT_WRAP: i32 = 1;
export const DIFFUSE_BURLEY: i32 = 2;
export const DIFFUSE_TOON: i32 = 3;
export const SPECULAR_SCHLICK_GGX: i32 = 0;
export const SPECULAR_TOON: i32 = 1;
export const SPECULAR_DISABLED: i32 = 2;

// Every render mode name Godot 4.4 has for spatial shaders, and whether
// Hedra draws it (RENDER_MODES_DRAWN, 1 drawn and 0 not: a bool array
// literal with true after its first element is read wrongly by the
// compiler); one Hedra does not draw is read with the warning
// shader-render-mode-unsupported and ignored.
export const RENDER_MODES: StaticArray<string> = [
    "blend_mix", "blend_add", "blend_sub", "blend_mul", "blend_premul_alpha",
    "depth_draw_opaque", "depth_draw_always", "depth_draw_never", "depth_prepass_alpha", "depth_test_disabled",
    "sss_mode_skin", "cull_back", "cull_front", "cull_disabled", "unshaded", "wireframe",
    "diffuse_lambert", "diffuse_lambert_wrap", "diffuse_burley", "diffuse_toon",
    "specular_schlick_ggx", "specular_toon", "specular_disabled",
    "skip_vertex_transform", "world_vertex_coords", "ensure_correct_normals", "shadows_disabled",
    "ambient_light_disabled", "shadow_to_opacity", "vertex_lighting", "particle_trails", "alpha_to_coverage",
    "alpha_to_coverage_and_one", "debug_shadow_splits", "fog_disabled",
];
export const RENDER_MODES_DRAWN: StaticArray<u8> = [
    1, 1, 1, 1, 1,
    1, 1, 1, 0, 1,
    0, 1, 1, 1, 1, 0,
    1, 1, 1, 1,
    1, 1, 1,
    1, 1, 1, 1,
    1, 0, 0, 0, 0,
    0, 0, 1,
];

// Godot's `varying` (a value vertex() writes and fragment() reads,
// interpolated): `varying name: type;` with type f32, vec2<f32>,
// vec3<f32> or vec4<f32> (shorthand too); each takes one of the
// template's MAX_SHADER_VARYINGS slots (CustomOut.hedra_v0 to _v3, a vec4
// each). Godot's `varying flat` and integer varyings are not in the format
// (shader-varying-unsupported).
export const MAX_SHADER_VARYINGS: i32 = 4;

export class ShaderVarying {
    name: string;
    type: UniformType;
    line: i32 = 0;
    col: i32 = 0;
    // Its slot (0 to MAX_SHADER_VARYINGS - 1), in the file's order.
    slot: i32 = 0;

    constructor(name: string, type: UniformType) {
        this.name = name;
        this.type = type;
    }
}

// The template's entry points (hedra_compiler's surface_custom.wgsl; the
// GPU side, ../gpu/custom.as, makes its pipelines with them): the vertex
// stage of a plain, an instanced and a skinned draw (UV set 1 at location
// 10 in each), and the fragment stage of the main pass, of the shadow and
// depth passes (run only when the shader discards or cuts out: otherwise
// those passes have no fragment stage), of the id pass (selection and
// picking in the tools) and of SSAO's normal-depth pass.
export const CUSTOM_VS = "vs_custom";
export const CUSTOM_VS_INSTANCED = "vs_custom_instanced";
export const CUSTOM_VS_SKINNED = "vs_custom_skinned";
export const CUSTOM_FS = "fs_custom";
export const CUSTOM_FS_DEPTH = "fs_custom_depth";
export const CUSTOM_FS_ID = "fs_custom_id";
export const CUSTOM_FS_NORMAL_DEPTH = "fs_custom_normal_depth";

// A problem the reader (./parse.as), the composer or the compiler found,
// at a place in the user's file (1-based; 0 when it has none).
export const SHADER_ERROR: i32 = 0;
export const SHADER_WARNING: i32 = 1;

export class ShaderDiagnostic {
    severity: i32;
    // RSCN.md's codes table: shader-syntax, shader-type-unsupported,
    // shader-render-mode-unknown, shader-render-mode-unsupported,
    // shader-uniform-type-unsupported, shader-uniform-hint-unknown,
    // shader-uniform-hint-unsupported, shader-uniform-default,
    // shader-uniform-duplicate, shader-uniform-shadowed,
    // shader-too-many-textures, shader-too-many-uniforms,
    // shader-block-too-large, shader-name-reserved, shader-name-glsl,
    // shader-stage-signature, shader-builtin-unsupported,
    // shader-compile (rive's own message), shader-compiler-missing.
    code: string;
    message: string;
    hint: string;
    line: i32;
    col: i32;

    constructor(severity: i32, code: string, message: string, hint: string, line: i32, col: i32) {
        this.severity = severity;
        this.code = code;
        this.message = message;
        this.hint = hint;
        this.line = line;
        this.col = col;
    }
}

// One uniform of a shader, as declared.
export class ShaderUniform {
    name: string;
    type: UniformType;
    // HINT_* bits.
    hints: u32 = 0;
    // hint_range's arguments (HINT_RANGE), and its step (0: none given).
    rangeMin: f64 = 0;
    rangeMax: f64 = 1;
    rangeStep: f64 = 0;
    // The default, as numbers (uniformComponents of them; a colour sRGB
    // straight alpha, as the file writes it; a bool 0 or 1), from `= ...`
    // or WGSL's zero value (a source_color vec4: opaque black, Godot's).
    def: StaticArray<f64> = new StaticArray<f64>(4);
    // The group_uniforms around it ("" none), and its subgroup
    // (`group_uniforms Look.Rim;`: group "Look", subgroup "Rim").
    group: string = "";
    subgroup: string = "";
    // Where its name is in the file (1-based).
    line: i32 = 0;
    col: i32 = 0;
    // Its place in the parameters' block (./layout.as; -1 for a texture),
    // and its size there in bytes.
    offset: i32 = -1;
    size: i32 = 0;
    // A texture's: its index among the shader's textures, its binding in
    // group 2, its filter (FILTER_*), whether it repeats, and the index of
    // its sampler among ShaderProgram.samplers; -1 for every other type.
    texture: i32 = -1;
    binding: i32 = -1;
    filter: i32 = FILTER_LINEAR_MIPMAP;
    repeat: bool = true;
    sampler: i32 = -1;

    constructor(name: string, type: UniformType) {
        this.name = name;
        this.type = type;
    }

    // A colour parameter: a source_color vec3 or vec4 (a Color in the file,
    // a BindKind.Color target).
    isColor(): bool {
        return (this.hints & HINT_SOURCE_COLOR) != 0 && (this.type == UniformType.Vec3 || this.type == UniformType.Vec4);
    }
}

// A shader file read: its declarations, what its code uses, its problems.
export class ShaderProgram {
    // The file as errors name it (the loader's display path).
    path: string = "";
    // The file's text, as it is.
    text: string = "";
    // shaderKey(text).
    key: string = "";
    // `shader_type`'s word ("" before it is read).
    shaderType: string = "";
    // The render modes as written, each once, in the file's order.
    renderModes: Array<string> = [];
    blend: i32 = BLEND_MIX;
    depthDraw: i32 = DEPTH_DRAW_OPAQUE;
    depthTest: bool = true;
    cull: i32 = CULL_BACK;
    unshaded: bool = false;
    diffuse: i32 = DIFFUSE_LAMBERT;
    specular: i32 = SPECULAR_SCHLICK_GGX;
    skipVertexTransform: bool = false;
    worldVertexCoords: bool = false;
    shadowsDisabled: bool = false;
    ambientLightDisabled: bool = false;
    fogDisabled: bool = false;
    // Which stage functions the file defines (fn vertex(), fn fragment(),
    // fn light(): no parameters, no result).
    hasVertex: bool = false;
    hasFragment: bool = false;
    hasLight: bool = false;
    // What the code reads or writes, told from its words (./parse.as):
    // ALPHA makes the material transparent (Godot's rule) unless
    // ALPHA_SCISSOR_THRESHOLD is written too, which makes it a cut-out;
    // `discard` (or a cut-out) makes the depth passes run fragment(); TIME
    // makes a view that shows it draw every frame.
    usesAlpha: bool = false;
    usesAlphaScissor: bool = false;
    usesDiscard: bool = false;
    usesTime: bool = false;
    usesScreenUv: bool = false;
    usesInstanceId: bool = false;
    usesInstanceCustom: bool = false;
    // POSITION written in vertex(): the clip position is the user's.
    usesPosition: bool = false;
    // The varyings, in the file's order.
    varyings: Array<ShaderVarying> = [];
    // The uniforms in the file's order, then the block they make
    // (./layout.as: blockSize at least MIN_PARAM_BLOCK_BYTES), the
    // textures' count and the sampler kinds (samplerKind) in binding order
    // (bindings 1 + textureCount onwards).
    uniforms: Array<ShaderUniform> = [];
    blockSize: i32 = MIN_PARAM_BLOCK_BYTES;
    textureCount: i32 = 0;
    samplers: Array<i32> = [];
    diagnostics: Array<ShaderDiagnostic> = [];

    // How many errors it has: a program with any is drawn with the
    // fallback material and never composed.
    errors(): i32 {
        let n = 0;
        for (let i = 0; i < this.diagnostics.length; i++) if (this.diagnostics[i].severity == SHADER_ERROR) n++;
        return n;
    }

    // The uniform `name`'s index, -1 when there is none.
    uniformIndex(name: string): i32 {
        for (let i = 0; i < this.uniforms.length; i++) if (this.uniforms[i].name == name) return i;
        return -1;
    }

    // Whether its pixels are blended (ALPHA without a scissor, or a blend
    // mode other than mix): drawn after the opaque ones, without writing
    // depth unless depth_draw_always.
    transparent(): bool {
        return (this.usesAlpha && !this.usesAlphaScissor) || this.blend != BLEND_MIX;
    }

    // Whether the depth passes (shadows, normal-depth, id) run fragment():
    // it discards, or cuts out.
    depthRunsFragment(): bool {
        return this.usesDiscard || this.usesAlphaScissor;
    }

    // Whether it casts shadows (Godot: shadows_disabled casts none; a
    // transparent material casts none, as a blended StandardMaterial3D).
    castsShadows(): bool {
        return !this.shadowsDisabled && !this.transparent();
    }
}

// The key of a shader's text: the first SHADER_KEY_HEX hex digits of the
// SHA-256 of its UTF-8 bytes. The composed file's name in a Rive project
// and the run time's lookup both come from it.
export function shaderKey(text: string): string {
    return sha256Text(text).substring(0, SHADER_KEY_HEX);
}

// The Rive asset name of the composed shader of key `key` for the Hedra
// project `project` (its path in the Rive project, "" for the Rive
// project's own folder): "hedra_shaders/world/0123456789abcdef".
export function shaderAssetName(project: string, key: string): string {
    return SHADERS_DIR + "/" + (project.length > 0 ? project + "/" : "") + key;
}

// Godot's spatial built-ins Hedra gives (the template, hedra_compiler's
// surface_custom.wgsl, declares each; docs/engine/SHADERS.md lists them
// with their types and spaces, Godot's: model space in vertex(), view
// space in fragment() and light()). Read anywhere: the constants and TIME;
// then the names each stage function may use (a name of another stage's
// list in a stage function is shader-builtin-stage; a helper function is
// not checked, as it may be called from any stage).
export const BUILTINS_GLOBAL: StaticArray<string> = ["TIME", "PI", "TAU", "E"];
export const BUILTINS_VERTEX: StaticArray<string> = [
    "VERTEX", "NORMAL", "TANGENT", "BINORMAL", "POSITION", "UV", "UV2", "COLOR", "INSTANCE_ID", "INSTANCE_CUSTOM",
    "VERTEX_ID", "MODEL_MATRIX", "MODEL_NORMAL_MATRIX", "VIEW_MATRIX", "INV_VIEW_MATRIX", "PROJECTION_MATRIX",
    "INV_PROJECTION_MATRIX", "MODELVIEW_MATRIX", "MODELVIEW_NORMAL_MATRIX", "VIEWPORT_SIZE", "NODE_POSITION_WORLD",
    "NODE_POSITION_VIEW", "CAMERA_POSITION_WORLD", "CAMERA_DIRECTION_WORLD",
];
export const BUILTINS_FRAGMENT: StaticArray<string> = [
    "VERTEX", "LIGHT_VERTEX", "FRAGCOORD", "FRONT_FACING", "NORMAL", "TANGENT", "BINORMAL", "VIEW", "NORMAL_MAP",
    "NORMAL_MAP_DEPTH", "UV", "UV2", "COLOR", "ALBEDO", "ALPHA", "ALPHA_SCISSOR_THRESHOLD", "PREMUL_ALPHA_FACTOR",
    "METALLIC", "SPECULAR", "ROUGHNESS", "RIM", "RIM_TINT", "BACKLIGHT", "AO", "AO_LIGHT_AFFECT", "EMISSION",
    "SCREEN_UV", "MODEL_MATRIX", "MODEL_NORMAL_MATRIX", "VIEW_MATRIX", "INV_VIEW_MATRIX", "PROJECTION_MATRIX",
    "INV_PROJECTION_MATRIX", "VIEWPORT_SIZE", "NODE_POSITION_WORLD", "NODE_POSITION_VIEW", "CAMERA_POSITION_WORLD",
    "CAMERA_DIRECTION_WORLD",
];
export const BUILTINS_LIGHT: StaticArray<string> = [
    "MODEL_MATRIX", "VIEW_MATRIX", "INV_VIEW_MATRIX", "PROJECTION_MATRIX", "INV_PROJECTION_MATRIX", "VIEWPORT_SIZE",
    "FRAGCOORD", "NORMAL", "UV", "UV2", "VIEW", "SPECULAR_AMOUNT", "LIGHT", "LIGHT_COLOR", "LIGHT_IS_DIRECTIONAL",
    "ATTENUATION", "ALBEDO", "BACKLIGHT", "METALLIC", "ROUGHNESS", "DIFFUSE_LIGHT", "SPECULAR_LIGHT", "ALPHA",
    "SCREEN_UV",
];
// Godot's built-ins Hedra does not give (shader-builtin-unsupported where
// the code names one): what needs a renderer feature Hedra has not (point
// sprites, stereo views, subsurface scattering, the depth and screen
// textures, per-pixel fog and sky output) or data its meshes do not carry
// (bone indices in the vertex stage, custom vertex data).
export const BUILTINS_UNSUPPORTED: StaticArray<string> = [
    "POINT_SIZE", "POINT_COORD", "BONE_INDICES", "BONE_WEIGHTS", "CUSTOM0", "CUSTOM1", "CUSTOM2", "CUSTOM3",
    "VIEW_INDEX", "VIEW_MONO_LEFT", "VIEW_RIGHT", "EYE_OFFSET", "MAIN_CAM_INV_VIEW_MATRIX", "CAMERA_VISIBLE_LAYERS",
    "CLEARCOAT", "CLEARCOAT_ROUGHNESS", "ANISOTROPY", "ANISOTROPY_FLOW", "SSS_STRENGTH", "SSS_TRANSMITTANCE_COLOR",
    "SSS_TRANSMITTANCE_DEPTH", "SSS_TRANSMITTANCE_BOOST", "DEPTH", "FOG", "RADIANCE", "IRRADIANCE",
    "ALPHA_HASH_SCALE", "ALPHA_ANTIALIASING_EDGE", "ALPHA_TEXTURE_COORDINATE", "EXPOSURE", "OUTPUT_IS_SRGB",
];
// Godot's uniform hints that need what Hedra has not (the screen, depth and
// normal-roughness textures, a roughness channel's detection, instance
// uniforms): shader-uniform-hint-unsupported.
export const HINTS_UNSUPPORTED: StaticArray<string> = [
    "hint_screen_texture", "hint_depth_texture", "hint_normal_roughness_texture", "hint_roughness_r",
    "hint_roughness_g", "hint_roughness_b", "hint_roughness_a", "hint_roughness_normal", "hint_roughness_gray",
    "hint_anisotropy", "instance_index", "hint_enum",
];
// The built-ins that are uniform values (the same for every vertex and
// pixel of a draw): the composer writes each use as the engine's uniform
// expression beside it, so that WGSL's uniformity analysis sees them as
// uniform (a texture may be sampled under a branch on TIME), and the
// template declares none of them. They are read only (Godot lets vertex()
// write PROJECTION_MATRIX; Hedra does not). Every other built-in is a
// module-scope `var<private>` of the template.
export const BUILTIN_REWRITES: StaticArray<string> = [
    "TIME", "VIEW_MATRIX", "PROJECTION_MATRIX", "CAMERA_POSITION_WORLD", "VIEWPORT_SIZE",
];
export const BUILTIN_REWRITE_EXPRS: StaticArray<string> = [
    "G.fparams.w", "G.view", "G.proj", "G.camera_pos.xyz", "G.viewport.xy",
];

// The prefix of every name the composer gives its own declarations: a
// user's top-level name may not start with it (shader-name-reserved).
export const RESERVED_PREFIX = "hedra_";
