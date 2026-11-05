// The device side of custom shaders (Godot's ShaderMaterial in WGSL;
// docs/engine/SHADERS.md, ../shader/program.as): the pipelines a custom
// shader's module draws with, the material groups of the frames'
// ShaderMaterials, and what the renderer (./renderer.as) binds with them.
//
// A ShaderMaterial reaches the renderer as a MaterialDesc with `custom`
// (../custom_material.as): its fallback fields, its program, its
// parameters and its textures. Before a view draws, the renderer asks the
// frame's shader source (../shader/modules.as) for each such material's
// module; a material whose source answers null (compiling, failed, no
// source) is drawn with its fallback, the MaterialDesc's own fields, by
// the surface pipelines, exactly as a StandardMaterial3D of them.
//
// Per module (the GPUShaderModule a source answered, compared by
// identity: a module answered again is the same object) a CustomPipelines:
//   - its group layouts, read from the module (GPUBindGroupLayout
//     .fromShader, group 1's object block at a dynamic offset): the
//     template (hedra_compiler's surface_custom.wgsl) declares surface.wgsl's
//     groups 0, 1 and 3, but the binding maps number them alike across
//     modules on WGSL and SPIR-V only (MSL and HLSL shift group 3 with
//     group 2's resources, GLSL keeps what the module uses), so every
//     group a custom draw binds is made from its own module's layouts;
//   - its pipelines, made on first use, one at a time, by pass (main;
//     shadow, when the shader casts shadows, with no fragment stage unless
//     it discards or cuts out; id; normal-depth, when it is opaque) and
//     vertex kind (plain, instanced, skinned), with Godot's states for its
//     render modes (customBlend, customDepth) and the template's entry
//     points (CUSTOM_VS*, CUSTOM_FS*). The vertices at slot 0 and UV set 1
//     at location 10 in every draw (mesh_cache.as uv1Buffer); an instanced
//     draw's instances at slot 1, UV set 1 at 2 and the instance extra
//     stream (INSTANCE_EXTRA_ATTRS) at 3; a skinned draw's skin at 1 and UV
//     set 1 at 2 (pipelines.as SKIN_SLOT, SKIN_UV1_SLOT). A host that
//     refuses a pipeline draws that pass of the shader's materials with
//     their fallback, saying so once;
//   - the material groups of the frames' ShaderMaterials drawn with it
//     (CustomMaterialGroup, group 2): the parameters' block in a uniform
//     buffer, written again in place when the parameters' version moved (a
//     binding or a timeline wrote them: ../shader/layout.as writeParamBlock
//     into kept bytes, then one update, never a new buffer), the
//     textures by the shader's texture index (the binder's views, read as
//     MaterialBinder.texture reads a slot's: sRGB for a source_color
//     uniform; unset, a fallback by its hint: white, black, transparent or
//     a flat normal; a file that does not load, magenta for a colour and
//     the unset fallback for data), and one sampler per kind it uses
//     (CustomShared: made once per renderer and kept);
//   - the groups 0, 1 and 3 of each view it is drawn in (CustomViewGroups,
//     made by the renderer from the module's layouts and the view's own
//     buffers and views, and kept while those are the same).
// A CustomPipelines no frame used is released at the renderer's next
// beginFrame, with its groups (a shader edited on disk gives a new module:
// the old one's pipelines go once no frame draws them); a material group
// no frame used goes likewise.
//
// TIME (Godot's, frame.as RenderFrame.shaderTime) is in each view's custom
// globals: a copy of the view's Globals (customGlobals) whose fparams.w is
// TIME, as the composer rewrites TIME to G.fparams.w; the fallback target's
// sRGB flag, which surface.wgsl's target_color reads in fparams.w, moves to
// params.z's bit 1 (CUSTOM_ENCODE_SRGB, the template's HEDRA_ENCODE_SRGB),
// and the inverse projection (INV_PROJECTION_MATRIX) is written over the
// wire, select and active colours and the grid, which no custom entry
// point reads. Every other module binds the view's Globals as before, so
// a frame without a ShaderMaterial writes and binds exactly what it did.
//
// Allocation: made once (a new module, a new material, a new view slot)
// and kept; a frame of the same materials allocates nothing.

import {
    GPUBindGroup, GPUBindGroupLayout, GPUBindGroupSampler, GPUBindGroupTexture, GPUBindGroupUBO, GPUBlendState,
    GPUBuffer, GPUColorTargetDesc, GPUDepthStencilDesc, GPUPipeline, GPUPipelineDesc, GPUSampler, GPUShaderModule,
    GPUTextureView, GPUVertexAttribute, GPUVertexBufferLayout,
} from "rive/gpu";
import {
    BlendFactor, BlendOp, BufferUsage, CompareFunction, CullMode, FaceWinding, Filter, IndexFormat, PrimitiveTopology,
    TextureFormat, VertexStepMode, WrapMode,
} from "rive/gpu_enums";
import { Mat4, Vec4 } from "../../base/vecmath";
import { Image, Rgba } from "../image";
import { MaterialBinder, MaterialDesc } from "../material";
import { CustomMaterialDesc } from "../custom_material";
import {
    BLEND_ADD, BLEND_MUL, BLEND_PREMUL_ALPHA, BLEND_SUB, CUSTOM_FS, CUSTOM_FS_DEPTH, CUSTOM_FS_ID,
    CUSTOM_FS_NORMAL_DEPTH, CUSTOM_VS, CUSTOM_VS_INSTANCED, CUSTOM_VS_SKINNED, DEPTH_DRAW_ALWAYS, DEPTH_DRAW_NEVER,
    FILTER_LINEAR, FILTER_LINEAR_MIPMAP_ANISOTROPIC, FILTER_NEAREST, FILTER_NEAREST_MIPMAP,
    FILTER_NEAREST_MIPMAP_ANISOTROPIC, HINT_DEFAULT_BLACK, HINT_DEFAULT_TRANSPARENT, HINT_NORMAL, HINT_SOURCE_COLOR,
    MAX_PARAM_BLOCK_BYTES, ShaderProgram, ShaderUniform, UniformType,
} from "../shader/program";
import { ShaderParams, defaultParams, samplerBinding, writeParamBlock } from "../shader/layout";
import { INSTANCE_EXTRA_STRIDE, INSTANCE_STRIDE } from "../instances";
import {
    DepthState, Globals, ID_FORMAT, INSTANCE_ATTRS, INSTANCE_EXTRA_ATTRS, NORMAL_DEPTH_FORMAT, SHADOW_ATLAS_FORMAT,
    SSR_SURFACE_FORMAT,
    SKIN_ATTRS, SKIN_STRIDE, SURFACE_ATTRS, SURFACE_VERTEX_SIZE, U32x4, UV1_ATTRS, UV1_STRIDE, VertexAttr, depthState,
} from "./layouts";

// Globals.params.z's bit in a view's custom globals: the main target is
// the rgba8unorm fallback, whose sRGB encode the template's output does
// (its HEDRA_ENCODE_SRGB; surface.wgsl's target_color reads fparams.w,
// which holds TIME there).
export const CUSTOM_ENCODE_SRGB: u32 = 2;

// The passes a custom shader draws in, and the vertex kinds of its draws:
// a pipeline is made for each pair it is drawn with (customPipelineKey).
export const CUSTOM_PASS_MAIN: i32 = 0;
export const CUSTOM_PASS_SHADOW: i32 = 1;
export const CUSTOM_PASS_ID: i32 = 2;
export const CUSTOM_PASS_NORMAL_DEPTH: i32 = 3;
export const CUSTOM_PASSES: i32 = 4;
export const CUSTOM_PLAIN: i32 = 0;
export const CUSTOM_INSTANCED: i32 = 1;
export const CUSTOM_SKINNED: i32 = 2;
export const CUSTOM_KINDS: i32 = 3;

// The vertex buffer slots of a custom draw past the vertices (slot 0): UV
// set 1 of a plain draw at 1; an instanced draw's instances at 1, UV set 1
// at 2 and the extra stream at 3; a skinned draw's skin at 1 and UV set 1
// at 2.
export const CUSTOM_PLAIN_UV1_SLOT: u32 = 1;
export const CUSTOM_INSTANCES_SLOT: u32 = 1;
export const CUSTOM_INSTANCED_UV1_SLOT: u32 = 2;
export const CUSTOM_EXTRA_SLOT: u32 = 3;
export const CUSTOM_SKIN_SLOT: u32 = 1;
export const CUSTOM_SKINNED_UV1_SLOT: u32 = 2;

// What the renderer says, once, when the host refuses a custom shader's
// layouts or pipelines (its materials are then drawn with their fallback).
export const CUSTOM_PIPELINE_WARNING = "a custom shader is drawn with its fallback material: the host refused its pipelines";

// The index of the pipeline of pass `pass` and vertex kind `kind` among a
// module's (CustomPipelines.pipeline).
export function customPipelineKey(pass: i32, kind: i32): i32 {
    return pass * CUSTOM_KINDS + kind;
}

// Whether a custom shader draws in pass `pass` at all: the main and id
// passes always; the shadow pass when it casts shadows (Godot's
// shadows_disabled, and a transparent shader, cast none: program.as
// castsShadows); SSAO's normal-depth pass when it is opaque (a blended
// surface writes no depth there, as surface.wgsl's do not).
export function customDrawsIn(p: ShaderProgram, pass: i32): bool {
    if (pass == CUSTOM_PASS_SHADOW) return p.castsShadows();
    if (pass == CUSTOM_PASS_NORMAL_DEPTH) return !p.transparent();
    return true;
}

// The fragment entry of pass `pass` (null: a depth-only pipeline, the
// shadow pass of a shader that neither discards nor cuts out).
export function customFragmentEntry(p: ShaderProgram, pass: i32): string? {
    if (pass == CUSTOM_PASS_MAIN) return CUSTOM_FS;
    if (pass == CUSTOM_PASS_ID) return CUSTOM_FS_ID;
    if (pass == CUSTOM_PASS_NORMAL_DEPTH) return CUSTOM_FS_NORMAL_DEPTH;
    return p.depthRunsFragment() ? CUSTOM_FS_DEPTH : null;
}

// The vertex entry of vertex kind `kind`.
export function customVertexEntry(kind: i32): string {
    if (kind == CUSTOM_INSTANCED) return CUSTOM_VS_INSTANCED;
    if (kind == CUSTOM_SKINNED) return CUSTOM_VS_SKINNED;
    return CUSTOM_VS;
}

// Godot's blend state of the main pass for `p`'s blend mode (its
// blend_mode_to_blend_attachment): null for an opaque shader (the source
// written as it is); mix: src-alpha, one-minus-src-alpha (alpha one,
// one-minus-src-alpha); add: src-alpha, one (alpha too); sub: the
// reverse subtraction of src-alpha x src from the destination (alpha
// too); mul: dst-colour, zero (alpha dst-alpha, zero), the destination
// times the source; premul_alpha: one, one-minus-src-alpha.
export function customBlend(p: ShaderProgram): GPUBlendState? {
    if (!p.transparent()) return null;
    const b = new GPUBlendState();
    b.colorOp = BlendOp.add;
    b.alphaOp = BlendOp.add;
    switch (p.blend) {
        case BLEND_ADD:
            b.srcColor = BlendFactor.srcAlpha;
            b.dstColor = BlendFactor.one;
            b.srcAlpha = BlendFactor.srcAlpha;
            b.dstAlpha = BlendFactor.one;
            break;
        case BLEND_SUB:
            b.colorOp = BlendOp.reverseSubtract;
            b.alphaOp = BlendOp.reverseSubtract;
            b.srcColor = BlendFactor.srcAlpha;
            b.dstColor = BlendFactor.one;
            b.srcAlpha = BlendFactor.srcAlpha;
            b.dstAlpha = BlendFactor.one;
            break;
        case BLEND_MUL:
            b.srcColor = BlendFactor.dstColor;
            b.dstColor = BlendFactor.zero;
            b.srcAlpha = BlendFactor.dstAlpha;
            b.dstAlpha = BlendFactor.zero;
            break;
        case BLEND_PREMUL_ALPHA:
            b.srcColor = BlendFactor.one;
            b.dstColor = BlendFactor.oneMinusSrcAlpha;
            b.srcAlpha = BlendFactor.one;
            b.dstAlpha = BlendFactor.oneMinusSrcAlpha;
            break;
        default:
            b.srcColor = BlendFactor.srcAlpha;
            b.dstColor = BlendFactor.oneMinusSrcAlpha;
            b.srcAlpha = BlendFactor.one;
            b.dstAlpha = BlendFactor.oneMinusSrcAlpha;
    }
    return b;
}

// Godot's depth state of pass `pass` for `p` (its pipeline's
// depth_stencil_state): the test the surface pipelines' (lessEqual), or
// none with depth_test_disabled; the write with depth_draw_always, none
// with depth_draw_never, and with depth_draw_opaque (the default) when the
// shader is not transparent; the main and shadow passes with the surface
// pipelines' bias (2, slope 1.5), the id and normal-depth passes with none.
// The shadow and depth passes always test and write (a shadow is the
// nearest caster's).
export function customDepth(p: ShaderProgram, pass: i32): DepthState {
    if (pass == CUSTOM_PASS_SHADOW) {
        const s = depthState(true, true, 2);
        s.format = SHADOW_ATLAS_FORMAT;
        return s;
    }
    let write = !p.transparent();
    if (p.depthDraw == DEPTH_DRAW_ALWAYS) write = true;
    if (p.depthDraw == DEPTH_DRAW_NEVER) write = false;
    if (pass != CUSTOM_PASS_MAIN) {
        // (the id pass draws every surface depth-tested and written, as
        // surface.wgsl's fs_id does; normal-depth only the opaque ones)
        return depthState(p.depthTest, true, 0);
    }
    return depthState(p.depthTest, write, 2);
}

// Whether programs `a` and `b`, drawn with one module, draw with one set of
// pipelines: they are one text (the program's key). Two files, or two saves
// of one file, that differ only in what the composer blanks compose to the
// same text, so the same module: the render modes that are pipeline state
// (depth_draw_*, depth_test_disabled: customDepth's), the uniforms' hints
// (hint_default_white or _black, source_color: the material group's
// fallback textures and the block's packing) and defaults. Without this the
// second would draw with the first one's. (Blend, cull and the rest are
// HEDRA_* constants of the text: another module.)
export function sharesPipelines(a: ShaderProgram, b: ShaderProgram): bool {
    return a.key == b.key;
}

// A sampler kind's filters and wrap (Godot's: filter_nearest and
// filter_linear read level 0 alone; the _mipmap ones blend levels
// linearly, rendering/textures/default_filters/use_nearest_mipmap_filter
// being off; the _anisotropic ones at Godot's default level, 4x, which
// WebGPU takes with linear filters only, so a nearest anisotropic one is
// drawn as nearest_mipmap).
export class SamplerSpec {
    min: Filter = Filter.linear;
    mag: Filter = Filter.linear;
    mip: Filter = Filter.linear;
    wrap: WrapMode = WrapMode.repeat;
    anisotropy: u32 = 1;
    maxLod: f32 = 32;
}

export function samplerSpec(kind: i32): SamplerSpec {
    const s = new SamplerSpec();
    const filter = kind >> 1;
    s.wrap = (kind & 1) != 0 ? WrapMode.repeat : WrapMode.clampToEdge;
    const nearest = filter == FILTER_NEAREST || filter == FILTER_NEAREST_MIPMAP
        || filter == FILTER_NEAREST_MIPMAP_ANISOTROPIC;
    s.min = nearest ? Filter.nearest : Filter.linear;
    s.mag = s.min;
    s.mip = Filter.linear;
    if (filter == FILTER_NEAREST || filter == FILTER_LINEAR) s.maxLod = 0;
    if (filter == FILTER_LINEAR_MIPMAP_ANISOTROPIC) s.anisotropy = 4;
    return s;
}

// What an unset texture uniform draws (Godot's hint_default_*, a flat
// normal for hint_normal; white by default).
export const TEXTURE_WHITE: i32 = 0;
export const TEXTURE_BLACK: i32 = 1;
export const TEXTURE_TRANSPARENT: i32 = 2;
export const TEXTURE_NORMAL: i32 = 3;
export const TEXTURE_MAGENTA: i32 = 4;

export function textureFallback(u: ShaderUniform): i32 {
    if ((u.hints & HINT_NORMAL) != 0) return TEXTURE_NORMAL;
    if ((u.hints & HINT_DEFAULT_BLACK) != 0) return TEXTURE_BLACK;
    if ((u.hints & HINT_DEFAULT_TRANSPARENT) != 0) return TEXTURE_TRANSPARENT;
    return TEXTURE_WHITE;
}

// What a texture uniform whose file does not load draws: magenta for a
// colour (a broken path shows, as a base colour slot's), else the unset
// fallback (a data texture still reads).
export function textureFailed(u: ShaderUniform): i32 {
    return (u.hints & HINT_SOURCE_COLOR) != 0 ? TEXTURE_MAGENTA : textureFallback(u);
}

// A view's custom globals (see the header) from its Globals `g`: TIME in
// fparams.w, the fallback target's flag in params.z's bit 1, the inverse
// of `g`'s projection over the colours and the grid; the rest `g`'s.
// Written into `out` (not `g`), every field; returns `out`. (Globals is a
// class filled in place: layouts.as says why.)
export function customGlobalsInto(g: Globals, time: f32, encode: bool, out: Globals): Globals {
    const inv = g.proj.inverseOrZero();
    const p = g.params;
    out.copyFrom(g);
    out.wireColor = inv.xAxis;
    out.selectColor = inv.yAxis;
    out.activeColor = inv.zAxis;
    out.grid = inv.wAxis;
    out.params = U32x4(p.x, p.y, (p.z & ~CUSTOM_ENCODE_SRGB) | (encode ? CUSTOM_ENCODE_SRGB : 0), p.w);
    out.fparams = Vec4(g.fparams.x, g.fparams.y, g.fparams.z, time);
    return out;
}

// customGlobalsInto in a new block (for the tests).
export function customGlobals(g: Globals, time: f32, encode: bool): Globals {
    return customGlobalsInto(g, time, encode, new Globals());
}

// `customGlobals` of a shadow tile: the view's custom globals `c` with the
// tile's view-projection (renderer.as tileGlobalsInto's rule), written into
// `out` (returned).
export function customTileGlobalsInto(c: Globals, viewProj: Mat4, out: Globals): Globals {
    out.copyFrom(c);
    out.viewProj = viewProj;
    return out;
}

// customTileGlobalsInto in a new block (for the tests).
export function customTileGlobals(c: Globals, viewProj: Mat4): Globals {
    return customTileGlobalsInto(c, viewProj, new Globals());
}

// What every CustomPipelines of a renderer shares: the samplers by kind,
// the black and transparent fallback textures (the binder holds the
// white, the flat normal and the magenta), and the bytes a block is
// written into before its upload.
export class CustomShared {
    private samplers: Array<GPUSampler?> = [];
    private black: GPUTextureView? = null;
    private transparent: GPUTextureView? = null;
    block: ArrayBuffer = new ArrayBuffer(MAX_PARAM_BLOCK_BYTES);
    blockView: DataView;
    // How many samplers were made (tests see each kind made once).
    samplersMade: i32 = 0;

    constructor() {
        this.blockView = new DataView(this.block, 0, this.block.byteLength);
    }

    // The sampler of kind `kind` (samplerKind), made on first use.
    samplerFor(kind: i32): GPUSampler {
        while (this.samplers.length <= kind) this.samplers.push(null);
        const kept = this.samplers[kind];
        if (kept != null) return kept;
        const s = samplerSpec(kind);
        const made = new GPUSampler(s.min, s.mag, s.mip, s.wrap, s.wrap, <CompareFunction>0xFFFFFFFF, s.anisotropy, 0,
            s.maxLod);
        this.samplers[kind] = made;
        this.samplersMade++;
        return made;
    }

    // The view of fallback `which` (TEXTURE_*), the black and transparent
    // ones uploaded through `binder`'s backend on first use.
    fallback<G>(binder: MaterialBinder<GPUTextureView, G>, which: i32): GPUTextureView {
        if (which == TEXTURE_NORMAL) return binder.flatNormal;
        if (which == TEXTURE_MAGENTA) return binder.magenta;
        if (which == TEXTURE_BLACK) {
            let v = this.black;
            if (v == null) {
                v = binder.backend.upload("black", Image.new(1, 1, Rgba(0, 0, 0, 255)), false);
                this.black = v;
            }
            return v;
        }
        if (which == TEXTURE_TRANSPARENT) {
            let v = this.transparent;
            if (v == null) {
                v = binder.backend.upload("transparent", Image.new(1, 1, Rgba(0, 0, 0, 0)), false);
                this.transparent = v;
            }
            return v;
        }
        return binder.white;
    }
}

// One ShaderMaterial's group 2 with one module (see the header): the
// MaterialDesc it binds, the parameters and their version its block holds,
// the binder state its textures were read at.
export class CustomMaterialGroup {
    desc: MaterialDesc;
    params: ShaderParams;
    version: i32;
    buffer: GPUBuffer;
    // (null only for a group made without a device: the tests')
    group: GPUBindGroup?;
    liveGeneration: i32;
    baseDir: string;
    usedFrame: u32 = 0;
    // How many times the block was written (tests: a drag writes it once
    // a frame, an unmoving material never).
    writes: i32 = 0;
    // The material's values laid out for the module's program when that is
    // another text's (the last good module of a file being compiled again
    // or that failed: mapLastGoodParams), made once a group; null else.
    mapped: ShaderParams? = null;

    constructor(desc: MaterialDesc, params: ShaderParams, buffer: GPUBuffer, group: GPUBindGroup?, live: i32,
        baseDir: string) {
        this.desc = desc;
        this.params = params;
        this.version = params.version;
        this.buffer = buffer;
        this.group = group;
        this.liveGeneration = live;
        this.baseDir = baseDir;
    }
}

// Whether `g`'s block must be written again for `c` (its parameters were
// replaced, the shader's live reload, or written since: their version
// moved).
export function blockStale(g: CustomMaterialGroup, c: CustomMaterialDesc): bool {
    return g.params !== c.params || g.version != c.params.version;
}

// `g`'s block written again from `c`'s parameters: packed into the
// shared bytes (writeParamBlock: source_color linearised, integers
// rounded, bools 0 or 1) and uploaded into its own buffer, in place.
// Allocates nothing.
// `layout` is the program the module was made for (CustomPipelines
// .program), null for `c`'s own: when it is another text's, `c`'s values
// are packed into its block by name (mapLastGoodParams).
export function writeCustomBlock(g: CustomMaterialGroup, c: CustomMaterialDesc, shared: CustomShared,
    layout: ShaderProgram? = null): void {
    const own = layout == null || layout.key == c.program.key;
    const prog = own ? c.program : layout!;
    if (own) {
        writeParamBlock(prog, c.params, shared.blockView, 0);
    } else {
        let m = g.mapped;
        if (m == null || m.count != prog.uniforms.length) {
            m = defaultParams(prog);
            g.mapped = m;
        }
        mapLastGoodParams(prog, c, m);
        writeParamBlock(prog, m, shared.blockView, 0);
    }
    g.buffer.update(0, shared.block, <u32>max<i32>(prog.blockSize, 16));
    g.params = c.params;
    g.version = c.params.version;
    g.writes++;
}

// The index among `p`'s uniforms of the one named `name` of type `t`, or
// -1.
function uniformOfType(p: ShaderProgram, name: string, t: UniformType): i32 {
    for (let i = 0; i < p.uniforms.length; i++) {
        const u = unchecked(p.uniforms[i]);
        if (u.type == t && u.name == name) return i;
    }
    return -1;
}

// `c`'s values as `layout`'s parameters (into `out`, no allocation): each
// uniform of `layout` takes the value `c` draws for the uniform of its name
// and type in `c`'s program (set or its default), else its own default.
// The last good version of a shader stays on screen with the material's
// current values while its new text compiles, or after it failed.
export function mapLastGoodParams(layout: ShaderProgram, c: CustomMaterialDesc, out: ShaderParams): void {
    const from = c.program;
    for (let j = 0; j < layout.uniforms.length && j < out.count; j++) {
        const u = unchecked(layout.uniforms[j]);
        const i = u.type == UniformType.Texture2D ? -1 : uniformOfType(from, u.name, u.type);
        if (i < 0 || i >= c.params.count) {
            out.set[j] = 0;
            continue;
        }
        for (let k = 0; k < 4; k++) out.nums[j * 4 + k] = c.params.value(from, i, k);
        out.set[j] = 1;
    }
}

// The texture index in `c` of `layout`'s texture uniform `u` (the same
// name in `c`'s program), or -1.
function textureIndexOf(layout: ShaderProgram, u: ShaderUniform, c: CustomMaterialDesc): i32 {
    if (layout.key == c.program.key) return u.texture;
    const i = uniformOfType(c.program, u.name, UniformType.Texture2D);
    return i < 0 ? -1 : c.program.uniforms[i].texture;
}

// The groups 0, 1 and 3 of one view slot with one module (see the header;
// the renderer makes and refreshes them, gpu/renderer.as customView), and
// what each was made from, so a group is made again only when that
// changed.
export class CustomViewGroups {
    // The view slot's identity (ViewBuffers.customId).
    view: i32;
    // Group 0 of the main pass (the view's custom globals, its shadow map
    // and its ambient occlusion), of the id and normal-depth passes (the
    // dummy map and occlusion), and of each shadow tile.
    main: GPUBindGroup? = null;
    mainMap: GPUTextureView? = null;
    mainAo: GPUTextureView? = null;
    mainGlobals: GPUBuffer? = null;
    plain: GPUBindGroup? = null;
    plainGlobals: GPUBuffer? = null;
    tiles: Array<GPUBindGroup> = [];
    tileBuffers: Array<GPUBuffer> = [];
    // Group 1: the view's object block, and each skinned item's palette
    // (by the view's skin slot), as the view's own object groups.
    objects: GPUBindGroup? = null;
    objectsBuffer: GPUBuffer? = null;
    objectsDecals: u32 = 0;
    // Milestone 62: the view's screen texture `objects` binds
    // (ViewBuffers.screen; the skins' groups follow their sources).
    objectsScreen: GPUTextureView? = null;
    skins: Array<GPUBindGroup?> = [];
    skinSources: Array<GPUBindGroup?> = [];
    // Group 3: the view's environment group's views.
    env: GPUBindGroup? = null;
    envSource: GPUBindGroup? = null;

    constructor(view: i32) {
        this.view = view;
    }

    // Every group, appended to `out` (released by the caller once no
    // recorded pass binds them), and none kept.
    drop(out: Array<GPUBindGroup>): void {
        const m = this.main;
        if (m != null) out.push(m);
        const p = this.plain;
        if (p != null) out.push(p);
        for (let i = 0; i < this.tiles.length; i++) out.push(this.tiles[i]);
        const o = this.objects;
        if (o != null) out.push(o);
        for (let i = 0; i < this.skins.length; i++) {
            const s = this.skins[i];
            if (s != null) out.push(s);
        }
        const e = this.env;
        if (e != null) out.push(e);
        this.main = null;
        this.plain = null;
        this.tiles.length = 0;
        this.tileBuffers.length = 0;
        this.objects = null;
        this.skins.length = 0;
        this.skinSources.length = 0;
        this.env = null;
    }
}

function vertexLayout(stride: u32, step: VertexStepMode, attrs: Array<VertexAttr>): GPUVertexBufferLayout {
    const l = new GPUVertexBufferLayout();
    l.stride = stride;
    l.stepMode = step;
    const out = new Array<GPUVertexAttribute>();
    for (let i = 0; i < attrs.length; i++) {
        out.push(new GPUVertexAttribute(attrs[i].format, attrs[i].location, attrs[i].offset));
    }
    l.attributes = out;
    return l;
}

// The vertex buffers of vertex kind `kind` (the header's slots).
export function customVertexBuffers(kind: i32): Array<GPUVertexBufferLayout> {
    const vertex = vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS);
    const uv1 = vertexLayout(UV1_STRIDE, VertexStepMode.vertex, UV1_ATTRS);
    if (kind == CUSTOM_INSTANCED) {
        return [
            vertex, vertexLayout(INSTANCE_STRIDE, VertexStepMode.instance, INSTANCE_ATTRS), uv1,
            vertexLayout(INSTANCE_EXTRA_STRIDE, VertexStepMode.instance, INSTANCE_EXTRA_ATTRS),
        ];
    }
    if (kind == CUSTOM_SKINNED) return [vertex, vertexLayout(SKIN_STRIDE, VertexStepMode.vertex, SKIN_ATTRS), uv1];
    return [vertex, uv1];
}

// One custom shader module's layouts, pipelines and groups (see the
// header).
export class CustomPipelines {
    module: GPUShaderModule;
    // The program it was made for. Every program a source answers this
    // module for is the same composed text, but the composer blanks the
    // depth render modes (pipeline state), the uniforms' hints and their
    // defaults, which this set's pipelines, groups and block are made from
    // (sharesPipelines): the renderer keeps a set for each program text.
    program: ShaderProgram;
    colorFormat: TextureFormat;
    samples: u32;
    // Groups 0 to 3 of the module (null: the host refused it, and every
    // pass draws the fallback: `ok` false).
    layouts: Array<GPUBindGroupLayout?> = [null, null, null, null];
    ok: bool = false;
    private made: Array<GPUPipeline?> = [];
    private tried: Array<bool> = [];
    // Whether a pipeline was refused (the renderer says so once).
    refused: bool = false;
    // The renderer's frame this module was last drawn in (gpu/renderer.as
    // beginFrame releases it when it was not drawn in the frame before).
    usedFrame: u32 = 0;
    views: Array<CustomViewGroups> = [];
    materials: Array<CustomMaterialGroup> = [];
    // How many pipelines were made (tests: each made once).
    pipelinesMade: i32 = 0;

    constructor(module: GPUShaderModule, program: ShaderProgram, colorFormat: TextureFormat, samples: u32) {
        this.module = module;
        this.program = program;
        this.colorFormat = colorFormat;
        this.samples = samples;
        for (let i = 0; i < CUSTOM_PASSES * CUSTOM_KINDS; i++) {
            this.made.push(null);
            this.tried.push(false);
        }
        const g0 = GPUBindGroupLayout.fromShader(module, 0);
        const g1 = GPUBindGroupLayout.fromShader(module, 1, [0]);
        const g2 = GPUBindGroupLayout.fromShader(module, 2);
        const g3 = GPUBindGroupLayout.fromShader(module, 3);
        this.layouts[0] = g0;
        this.layouts[1] = g1;
        this.layouts[2] = g2;
        this.layouts[3] = g3;
        this.ok = g0 != null && g1 != null && g2 != null && g3 != null;
        if (!this.ok) this.refused = true;
    }

    layout(g: i32): GPUBindGroupLayout {
        return this.layouts[g]!;
    }

    // The pipeline of pass `pass` and vertex kind `kind`, made on the first
    // call; null when the shader does not draw in that pass, or the host
    // refused it (asked once).
    pipeline(pass: i32, kind: i32): GPUPipeline? {
        if (!this.ok || !customDrawsIn(this.program, pass)) return null;
        const k = customPipelineKey(pass, kind);
        if (this.tried[k]) return this.made[k];
        this.tried[k] = true;
        const p = this.make(pass, kind);
        if (p == null || p.handle == 0) {
            this.refused = true;
            return null;
        }
        this.made[k] = p;
        this.pipelinesMade++;
        return p;
    }

    private make(pass: i32, kind: i32): GPUPipeline? {
        const prog = this.program;
        const d = new GPUPipelineDesc();
        d.vertexModule = this.module;
        d.vertexEntryPoint = customVertexEntry(kind);
        const fs = customFragmentEntry(prog, pass);
        if (fs != null) {
            d.fragmentModule = this.module;
            d.fragmentEntryPoint = fs;
        } else {
            d.fragmentModule = null;
        }
        const targets = new Array<GPUColorTargetDesc>();
        let samples: u32 = 1;
        if (pass == CUSTOM_PASS_MAIN) {
            const t = new GPUColorTargetDesc();
            t.format = this.colorFormat;
            t.blend = customBlend(prog);
            targets.push(t);
            samples = this.samples;
        } else if (pass == CUSTOM_PASS_ID) {
            const t = new GPUColorTargetDesc();
            t.format = ID_FORMAT;
            t.blend = null;
            targets.push(t);
        } else if (pass == CUSTOM_PASS_NORMAL_DEPTH) {
            const t = new GPUColorTargetDesc();
            t.format = NORMAL_DEPTH_FORMAT;
            t.blend = null;
            targets.push(t);
            // (milestone 62: the pass's second target, the surface's F0 and
            // roughness, which the template's fs_custom_normal_depth writes)
            const t1 = new GPUColorTargetDesc();
            t1.format = SSR_SURFACE_FORMAT;
            t1.blend = null;
            targets.push(t1);
        }
        d.colorTargets = targets;
        d.vertexBuffers = customVertexBuffers(kind);
        d.bindGroupLayouts = this.layouts;
        d.topology = PrimitiveTopology.triangleList;
        d.indexFormat = IndexFormat.uint32;
        // (the side is told in the fragment stage, as the surface
        // pipelines tell it: no pipeline culls)
        d.cullMode = CullMode.none;
        d.winding = FaceWinding.counterClockwise;
        const ds = customDepth(prog, pass);
        const dd = new GPUDepthStencilDesc();
        dd.format = ds.format;
        dd.compare = ds.compare;
        dd.write = ds.write;
        dd.depthBias = ds.biasConstant;
        dd.depthBiasSlopeScale = ds.biasSlopeScale;
        dd.depthBiasClamp = 0.0;
        d.depthStencil = dd;
        d.sampleCount = samples;
        return new GPUPipeline(d);
    }

    // The group 2 of `desc` (whose `custom` is not null), made on first
    // use (`frame` its renderer's frame), its block written again when
    // stale; null when the host refused it.
    materialGroup<G>(
        desc: MaterialDesc, binder: MaterialBinder<GPUTextureView, G>, shared: CustomShared, baseDir: string,
        warnings: Array<string>, frame: u32, retired: Array<GPUBindGroup>, retiredBuffers: Array<GPUBuffer>,
    ): CustomMaterialGroup? {
        const c = desc.custom!;
        const live = binder.liveGeneration;
        for (let i = 0; i < this.materials.length; i++) {
            const g = unchecked(this.materials[i]);
            if (g.desc !== desc) continue;
            if (g.liveGeneration != live || g.baseDir != baseDir) {
                const old = g.group;
                if (old != null) retired.push(old);
                retiredBuffers.push(g.buffer);
                this.materials.splice(i, 1);
                break;
            }
            g.usedFrame = frame;
            if (blockStale(g, c)) writeCustomBlock(g, c, shared, this.program);
            return g;
        }
        // (the module's own program: the material's, or the last good text's
        // whose layout the module has, its values packed in by name)
        const prog = this.program;
        const size = <u32>max<i32>(prog.blockSize, 16);
        const buffer = new GPUBuffer(BufferUsage.uniform, size);
        const textures = new Array<GPUBindGroupTexture>();
        for (let i = 0; i < prog.uniforms.length; i++) {
            const u = prog.uniforms[i];
            if (u.type != UniformType.Texture2D || u.texture < 0) continue;
            const t = textureIndexOf(prog, u, c);
            const path = t >= 0 && t < c.textures.length ? c.textures[t] : null;
            let view: GPUTextureView;
            if (path == null) {
                view = shared.fallback<G>(binder, textureFallback(u));
            } else {
                const srgb = t < c.srgb.length && c.srgb[t];
                view = binder.texture(path, srgb, shared.fallback<G>(binder, textureFailed(u)), baseDir, warnings);
            }
            textures.push(new GPUBindGroupTexture(<u32>u.binding, view));
        }
        const samplers = new Array<GPUBindGroupSampler>();
        for (let k = 0; k < prog.samplers.length; k++) {
            samplers.push(new GPUBindGroupSampler(<u32>samplerBinding(prog, k), shared.samplerFor(prog.samplers[k])));
        }
        const group = new GPUBindGroup(this.layout(2), [new GPUBindGroupUBO(0, buffer)], textures, samplers);
        if (group.handle == 0 || buffer.handle == 0) {
            if (group.handle != 0) group.release();
            if (buffer.handle != 0) buffer.release();
            return null;
        }
        const made = new CustomMaterialGroup(desc, c.params, buffer, group, live, baseDir);
        made.usedFrame = frame;
        writeCustomBlock(made, c, shared, prog);
        this.materials.push(made);
        return made;
    }

    // The groups of view slot `view` (made empty on first use).
    viewOf(view: i32): CustomViewGroups {
        for (let i = 0; i < this.views.length; i++) {
            const v = unchecked(this.views[i]);
            if (v.view == view) return v;
        }
        const v = new CustomViewGroups(view);
        this.views.push(v);
        return v;
    }

    // The material groups no frame since `frame` used, released into the
    // caller's lists.
    sweep(frame: u32, retired: Array<GPUBindGroup>, retiredBuffers: Array<GPUBuffer>): void {
        for (let i = this.materials.length - 1; i >= 0; i--) {
            const g = unchecked(this.materials[i]);
            if (g.usedFrame >= frame) continue;
            const old = g.group;
            if (old != null) retired.push(old);
            retiredBuffers.push(g.buffer);
            this.materials.splice(i, 1);
        }
    }

    // Everything it holds handed to the caller's lists (its pipelines
    // released at once: no pass of the frame being recorded uses a module
    // no frame drew).
    release(retired: Array<GPUBindGroup>, retiredBuffers: Array<GPUBuffer>): void {
        for (let i = 0; i < this.views.length; i++) this.views[i].drop(retired);
        this.views.length = 0;
        for (let i = 0; i < this.materials.length; i++) {
            const old = this.materials[i].group;
            if (old != null) retired.push(old);
            retiredBuffers.push(this.materials[i].buffer);
        }
        this.materials.length = 0;
        for (let i = 0; i < this.made.length; i++) {
            const p = this.made[i];
            if (p != null) p.release();
            this.made[i] = null;
        }
        for (let g = 0; g < 4; g++) {
            const l = this.layouts[g];
            if (l != null) l.release();
            this.layouts[g] = null;
        }
        this.ok = false;
    }
}
