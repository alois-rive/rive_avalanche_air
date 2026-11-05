// Pipeline creation: the bind group
// layouts and the render pipelines, on `std/rive/gpu.as`. (The struct
// layouts, flag constants, attribute tables and `depthState` are in
// ./layouts.as.)
//
// Constraints of the host API:
// - Shaders are build-time assets fetched by name (`shaders/render/surface`,
//   `shaders/render/lines`); both carry an inlined copy of common.wgsl.
// - Bind group layouts are derived from a shader, and native binding slots
//   are numbered per module, so groups 0 and 1 have one layout per module
//   (`globalsLayout` / `objectLayout` for surfaces, `lineGlobalsLayout` /
//   `lineObjectLayout` for lines and points) rather than one layout shared
//   by both pipeline layouts. The views bind the matching group.
// - `COLOR_FORMAT` is the main target format the view renders into:
//   rgba16float, or rgba8unorm when the device has no half-float targets
//   (layouts.as). `ID_FORMAT` is one rgba8unorm target (no R32Uint /
//   R32Float pair).
// - Two post pipelines finish a view without readback:
//   `outline` (post_outline.wgsl: selection outline + sRGB encode) and
//   `compose` (post_compose.wgsl: SSAA downsample, overlay blend, blits).
// - The shadow pass's pipelines (milestone 10) are made on first use by
//   `shadowPipelines`, not by `create`: a program that never draws a shadow
//   (Hedra) never asks for them, and a host that rejects them still runs
//   everything else, drawing no shadow. The comparison sampler the lit
//   shader reads the atlas with is also made on first use
//   (`compareSampler`), but by every renderer: group 0 of the surface module
//   declares it, so every globals group binds it, shadow or not.
// - Group 0 of the surface module holds bindings 0 to 7: Globals, the lit
//   block, the shadow block, map and sampler (milestone 10), the sky block
//   (milestone 11), the ambient occlusion (milestone 12) and the probe
//   block (milestone 20). Group 3, the environment group, holds what the
//   renderer remakes when it changes: the radiance cube, the panorama and
//   their two samplers (gpu/environment.as owns them), the lightmap layers
//   and their sampler (milestone 19, gpu/lightmap.as) and the probes' atlas
//   and its sampler (gpu/probes.as). A bind group holds slots 0 to 7 only
//   (the pinned runtime refuses a binding above 7), so they could not all
//   stay in group 0. `globalsLayout` and `envLayout` are read from the
//   shader, so they have every binding the module declares, and the
//   renderer's groups bind them all; every surface pipeline takes the four
//   (`surfaceLayouts`).
// - The post-processing pipelines (milestone 12: the normal-depth pass of
//   the surface module, and the post module's SSAO, glow and final
//   passes) are made on first use by `postPipelines`, as the shadow ones
//   are: Hedra never plans a post pass, so it never asks, and a host
//   that rejects them draws the frame without post-processing, saying so.
//   The post module itself is fetched by `create` (null when the project
//   has none, which draws no post-processing either).
// - The instanced pipelines (milestone 13: a MultiMeshInstance3D drawn
//   with GPU instancing) are made on first use by `instancedPipelines`, as
//   the shadow and post ones are: the instanced variants of the surface,
//   blended surface, id, normal-depth and both shadow pipelines, the same
//   fragment entries with `vs_surface_instanced` and a second vertex
//   buffer of INSTANCE_STRIDE bytes an instance (layouts.as INSTANCE_ATTRS,
//   locations 6 to 9). Modeler never draws an instance, so it never asks;
//   a host that rejects them draws the frame without its instanced items,
//   saying so (INSTANCING_PIPELINE_WARNING).
// - The extended pipelines (milestone 14, part 2: a material with MAT_EXT,
//   glTF's whole material) are made on first use by `extPipelines`, as the
//   instanced ones are: the surface, blended surface, id, normal-depth and
//   masked shadow pipelines, plain and instanced, with the `*_ext` entries
//   of surface.wgsl and UV set 1 as one more vertex buffer (UV1_STRIDE
//   bytes a vertex, layouts.as UV1_ATTRS, location 10): at slot 1 after
//   the vertices, at slot 2 after the instances. Modeler never draws such a
//   material, so it never asks; a host that rejects them draws those
//   materials with the plain pipelines (today's shading), saying so
//   (EXT_PIPELINE_WARNING).
// - The top pipelines (milestone 16: Godot's no_depth_test, an item with
//   DrawItem.noDepthTest, top_pass.as `isTopItem`) are made on first use by
//   `topPipelines`, as the ext ones are: the surface and id pipelines,
//   plain and with the `_ext` entries, alpha-blended (the id ones not) and
//   with `depthState(false, false, 0)`, so the item is drawn over
//   everything the main and id passes drew before it. Modeler never sets
//   the flag, so it never asks; a host that rejects them draws those items
//   with the depth test, as any other surface, saying so once
//   (TOP_PIPELINE_WARNING).
// - The lightmap pipelines (milestone 19: an item lightmapped by a bake,
//   frame.as DrawItem.lightmapLayer) are made on first use by
//   `lightmapPipelines`, as the ext ones are: the surface and blended
//   surface pipelines, plain and with the `_ext` fragment entry, all with
//   `vs_surface_lm` and three vertex buffers: the vertices at slot 0, UV
//   set 1 at LM_UV1_SLOT (as the ext pipelines read it, location 10) and
//   the lightmap coordinates at LM_UV_SLOT (LM_UV_STRIDE bytes a vertex,
//   layouts.as LM_UV_ATTRS, location 11). Only the main pass draws with
//   them; the shadow, id, normal-depth and top passes draw a lightmapped
//   item with the ordinary pipelines (its mesh has the same triangles). A
//   program without a bake (Hedra) never asks; a host that refuses them
//   draws those items with the ordinary pipelines, in real-time light,
//   saying so (LIGHTMAP_PIPELINE_WARNING).
// - The reflection probes (milestone 20): their block is group 0's binding
//   7, their atlas and its sampler group 3's bindings 6 and 7 (gpu/probes.as
//   owns the atlas and the sampler). Like every binding before, the layouts
//   have them from the shader and the renderer's groups bind them all.
// - The reflection probes' pipelines (milestone 20: probe.wgsl's place,
//   downsample, copy and prefilter passes, each a full-screen triangle
//   into PROBE_ATLAS_FORMAT, one sample, no depth) are made on first use by
//   `probePipelines`, as the post ones are; the probe module is fetched by
//   `create` (null when the project has none). Modeler never draws a probe,
//   so it never asks; a host that refuses them draws the frame without its
//   probes, saying so (PROBE_PIPELINE_WARNING).
// - Group 1 of the surface module also holds binding 1 (milestone 48): a
//   skinned item's palette (surface.wgsl's SkinU, layouts.as
//   SKIN_UNIFORM_SIZE). `objectLayout` has it from the shader, as group 0's
//   later bindings came, and every object group binds it: the renderer's
//   shared groups a dummy palette nothing reads, a skinned item's group its
//   own (gpu/renderer.as).
// - The skinned pipelines (milestone 48: an item with DrawItem.skin) are
//   made on first use, one at a time, by `skinnedOf`: each is the plain,
//   extended or top surface, id, normal-depth or shadow pipeline it is the
//   counterpart of, with `vs_surface_skinned` (or `vs_surface_ext_skinned`)
//   and the skin's vertex buffer at SKIN_SLOT (SKIN_STRIDE bytes a vertex,
//   layouts.as SKIN_ATTRS, locations 12 and 13), UV set 1 after it for an
//   extended material (SKIN_UV1_SLOT). Neither the instanced nor the
//   lightmap pipelines have one: a skinned item is neither. Modeler never
//   skins, so it never asks; a host that refuses one draws those items
//   unskinned, saying so (SKIN_PIPELINE_WARNING): the mesh as stored, at
//   its bind pose, with the identity for a world (a skinned item's), so at
//   the frame's origin rather than where its skeleton puts it; it casts no
//   shadow.
// - Group 1 of the surface module holds the decals' block, atlas and
//   sampler at bindings 2 to 4 (milestone 33) and the fog block at 5
//   (milestone 37: surface.wgsl's FogU, layouts.as FOG_BLOCK_BINDING);
//   `objectLayout` has them from the shader, and every object group binds
//   them (gpu/renderer.as `objectGroup`). The lines module's object group
//   is the object block alone. No pipeline is added for the fog: it is
//   integrated in the surface pipelines' own fragment entries, behind the
//   item's fog word (and in fs_sky behind the block's sky count).

import { Context } from "rive/host";
import {
    GPUBindGroupLayout, GPUBlendState, GPUColorTargetDesc, GPUDepthStencilDesc, GPUPipeline, GPUPipelineDesc,
    GPUSampler, GPUShaderModule, GPUVertexAttribute, GPUVertexBufferLayout,
} from "rive/gpu";
import {
    BlendFactor, BlendOp, CompareFunction, CullMode, FaceWinding, Filter, IndexFormat, PrimitiveTopology,
    TextureFormat, VertexStepMode, WrapMode,
} from "rive/gpu_enums";
import { Result } from "../../base/util";
import { RenderError } from "../errors";
import {
    AO_FORMAT, DepthState, GLOW_FORMAT, ID_FORMAT, INSTANCE_ATTRS, LINE_ATTRS, LINE_INSTANCE_SIZE, LM_UV_ATTRS,
    LM_UV_STRIDE, NORMAL_DEPTH_FORMAT, POINT_ATTRS, POINT_INSTANCE_SIZE, PROBE_ATLAS_FORMAT, SHADOW_ATLAS_FORMAT,
    SKIN_ATTRS, SKIN_STRIDE, SSR_SURFACE_FORMAT, SURFACE_ATTRS, SURFACE_VERTEX_SIZE, UV1_ATTRS, UV1_STRIDE, VertexAttr,
    depthState,
} from "./layouts";
import { INSTANCE_STRIDE } from "../instances";
import { VB_D_VERTEX_INSTANCED, VB_D_VERTEX_LIGHTMAP, VB_D_VERTEX_SKINNED } from "../variant";

// Shader asset names (the .wgsl paths without extension).
export const SURFACE_SHADER = "shaders/render/surface";
export const LINES_SHADER = "shaders/render/lines";
export const OUTLINE_SHADER = "shaders/render/post_outline";
export const COMPOSE_SHADER = "shaders/render/post_compose";
export const POST_SHADER = "shaders/render/post_effects";
export const PROBE_SHADER = "shaders/render/probe";

// Milestone 39: the directory the shader assets sit under in the project
// that bakes the renderer, which their asset names start with (rive names
// a .wgsl by its project path without the extension). "hedra_engine/" in
// every program of this repository, which stages the engine's shaders with
// the engine (HEDRA.md section 7: the package's assets); a Rive project
// sets its vendored directory (newSceneRuntime) before the first
// FrameRenderer is made.
let shaderRoot: string = "hedra_engine/";

export function setShaderRoot(root: string): void {
    shaderRoot = root;
}

export function shaderRootOf(): string {
    return shaderRoot;
}

// The asset name of the shader `name` (one of the *_SHADER constants).
export function shaderAsset(name: string): string {
    return shaderRoot + name;
}

// The lit mode's sky (surface.wgsl): a full-screen triangle drawn first in
// the main pass.
export const SKY_VERTEX_ENTRY = "vs_sky";
export const SKY_FRAGMENT_ENTRY = "fs_sky";

// The surface module's vertex entry of an instanced draw (surface.wgsl).
export const INSTANCED_VERTEX_ENTRY = "vs_surface_instanced";

// What FrameRenderer.warnings says when the host cannot draw instances (the
// frame is then drawn without its instanced items).
export const INSTANCING_PIPELINE_WARNING = "instanced meshes are not drawn: the host rejected their pipelines";

// The format every post pass writes (the canvas format).
export const POST_FORMAT: TextureFormat = TextureFormat.rgba8unorm;

// The shadow pass's fragment entry for alpha-masked casters (surface.wgsl).
export const SHADOW_FRAGMENT_ENTRY = "fs_shadow";

// What FrameRenderer.warnings says when the host cannot draw shadows.
export const SHADOW_PIPELINE_WARNING = "shadows are not drawn: the host rejected the shadow pipeline";

// What FrameRenderer.warnings says when the host cannot draw
// post-processing (the frame is then drawn without it).
export const POST_PIPELINE_WARNING = "post-processing is not drawn: the host rejected its pipelines";

// The post-processing pipelines (see the header; post.as plans the passes,
// gpu/renderer.as runs them).
export class PostPipelines {
    // Group 0 of the post module: every post draw binds all 5 bindings.
    layout: GPUBindGroupLayout;
    // The surface module's `fs_normal_depth` with the surface layouts, into
    // the two targets of normalDepthTargets (milestone 62: one before,
    // NORMAL_DEPTH_FORMAT), one sample, depth tested and written
    // with no bias (nothing is drawn over it).
    normalDepth: GPUPipeline;
    // Full-screen post draws: SSAO and its blur into AO_FORMAT, the glow's
    // bright pass and blurs into GLOW_FORMAT, the final pass into
    // POST_FORMAT.
    ssao: GPUPipeline;
    ssaoBlur: GPUPipeline;
    glowBright: GPUPipeline;
    glowBlurH: GPUPipeline;
    glowBlurV: GPUPipeline;
    final: GPUPipeline;
    // Binding 4: linear, mip nearest, clamped to the edge (the glow's
    // bilinear taps).
    sampler: GPUSampler;

    constructor(
        layout: GPUBindGroupLayout, normalDepth: GPUPipeline, ssao: GPUPipeline, ssaoBlur: GPUPipeline,
        glowBright: GPUPipeline, glowBlurH: GPUPipeline, glowBlurV: GPUPipeline, final: GPUPipeline, sampler: GPUSampler,
    ) {
        this.layout = layout;
        this.normalDepth = normalDepth;
        this.ssao = ssao;
        this.ssaoBlur = ssaoBlur;
        this.glowBright = glowBright;
        this.glowBlurH = glowBlurH;
        this.glowBlurV = glowBlurV;
        this.final = final;
        this.sampler = sampler;
    }
}

// The shadow pass's pipelines (see the header): both draw the surface
// vertices with `vs_surface` into the depth32float atlas alone (no colour
// target, one sample), with the surface pipelines' depth bias (a constant
// of 2 and a slope of 1.5), which pushes the stored depth away from the
// light a little on steep faces, where the receiver's own bias is weakest.
export class ShadowPipelines {
    // Opaque casters: no fragment stage at all.
    depth: GPUPipeline;
    // Alpha-masked casters: `fs_shadow` discards the cut-out.
    masked: GPUPipeline;
    // The lit shader's comparison sampler (the same object as
    // `Pipelines.compareSampler()`).
    compareSampler: GPUSampler;

    constructor(depth: GPUPipeline, masked: GPUPipeline, compareSampler: GPUSampler) {
        this.depth = depth;
        this.masked = masked;
        this.compareSampler = compareSampler;
    }
}

// The instanced variants of the surface pipelines (see the header): each
// is its plain counterpart's (same fragment entry, targets, depth state and
// samples) with `vs_surface_instanced` and the instance buffer at slot 1.
export class InstancedPipelines {
    surface: GPUPipeline;
    surfaceBlend: GPUPipeline;
    surfaceId: GPUPipeline;
    // PostPipelines.normalDepth's.
    normalDepth: GPUPipeline;
    // ShadowPipelines.depth's and .masked's.
    shadowDepth: GPUPipeline;
    shadowMasked: GPUPipeline;

    constructor(
        surface: GPUPipeline, surfaceBlend: GPUPipeline, surfaceId: GPUPipeline, normalDepth: GPUPipeline,
        shadowDepth: GPUPipeline, shadowMasked: GPUPipeline,
    ) {
        this.surface = surface;
        this.surfaceBlend = surfaceBlend;
        this.surfaceId = surfaceId;
        this.normalDepth = normalDepth;
        this.shadowDepth = shadowDepth;
        this.shadowMasked = shadowMasked;
    }
}

// The surface module's entries of the extended pipelines (surface.wgsl).
export const EXT_VERTEX_ENTRY = "vs_surface_ext";
export const EXT_INSTANCED_VERTEX_ENTRY = "vs_surface_ext_instanced";

// What FrameRenderer.warnings says when the host cannot draw extended
// materials (they are then drawn by the plain pipelines).
export const EXT_PIPELINE_WARNING =
    "glTF material extensions are not drawn: the host rejected their pipelines (drawn with the core material)";

// The extended pipelines (see the header): `plain` for items drawn once,
// `instanced` for instanced ones; each the counterpart of the pipeline of
// the same name with the `_ext` entries.
export class ExtPipelineSet {
    surface: GPUPipeline;
    surfaceBlend: GPUPipeline;
    surfaceId: GPUPipeline;
    normalDepth: GPUPipeline;
    shadowMasked: GPUPipeline;

    constructor(
        surface: GPUPipeline, surfaceBlend: GPUPipeline, surfaceId: GPUPipeline, normalDepth: GPUPipeline,
        shadowMasked: GPUPipeline,
    ) {
        this.surface = surface;
        this.surfaceBlend = surfaceBlend;
        this.surfaceId = surfaceId;
        this.normalDepth = normalDepth;
        this.shadowMasked = shadowMasked;
    }
}

// The vertex buffer slot UV set 1 binds at, plain and instanced.
export const EXT_PLAIN_UV1_SLOT: u32 = 1;
export const EXT_INSTANCED_UV1_SLOT: u32 = 2;

export class ExtPipelines {
    plain: ExtPipelineSet;
    instanced: ExtPipelineSet;

    constructor(plain: ExtPipelineSet, instanced: ExtPipelineSet) {
        this.plain = plain;
        this.instanced = instanced;
    }
}

// What FrameRenderer.warnings says (once) when the host cannot draw items
// without the depth test (they are then drawn with it).
export const TOP_PIPELINE_WARNING =
    "items with no_depth_test are drawn with the depth test: the host refused the pipelines without it";

// The top pipelines (see the header): each is the plain or extended
// surface or id pipeline of the same name with no depth test or write and
// no depth bias (nothing is drawn against it), the surfaces alpha-blended
// whatever their material's blend mode (Godot draws a no_depth_test
// material in its transparent pass). The ext ones take UV set 1 at
// EXT_PLAIN_UV1_SLOT, as ExtPipelines.plain's do.
export class TopPipelines {
    surface: GPUPipeline;
    surfaceExt: GPUPipeline;
    surfaceId: GPUPipeline;
    surfaceIdExt: GPUPipeline;

    constructor(surface: GPUPipeline, surfaceExt: GPUPipeline, surfaceId: GPUPipeline, surfaceIdExt: GPUPipeline) {
        this.surface = surface;
        this.surfaceExt = surfaceExt;
        this.surfaceId = surfaceId;
        this.surfaceIdExt = surfaceIdExt;
    }
}

// The surface module's entries of the lightmap pipelines (surface.wgsl).
export const LIGHTMAP_VERTEX_ENTRY = "vs_surface_lm";
export const LIGHTMAP_FRAGMENT_ENTRY = "fs_surface_lm";
export const LIGHTMAP_EXT_FRAGMENT_ENTRY = "fs_surface_ext_lm";

// The vertex buffer slots of a lightmap draw: UV set 1, then the lightmap
// coordinates (the vertices are at 0).
export const LM_UV1_SLOT: u32 = 1;
export const LM_UV_SLOT: u32 = 2;

// What FrameRenderer.warnings says when the host cannot draw lightmapped
// items with their lightmap (they are then drawn in real-time light).
export const LIGHTMAP_PIPELINE_WARNING =
    "lightmapped items are drawn with real-time light: the device refused the lightmap pipelines";

// The lightmap pipelines (see the header): each the main pass pipeline of
// the same name (opaque or blended, plain or extended material) drawing a
// lightmapped item's diffuse light from its lightmap.
export class LightmapPipelines {
    surface: GPUPipeline;
    surfaceBlend: GPUPipeline;
    surfaceExt: GPUPipeline;
    surfaceBlendExt: GPUPipeline;

    constructor(surface: GPUPipeline, surfaceBlend: GPUPipeline, surfaceExt: GPUPipeline, surfaceBlendExt: GPUPipeline) {
        this.surface = surface;
        this.surfaceBlend = surfaceBlend;
        this.surfaceExt = surfaceExt;
        this.surfaceBlendExt = surfaceBlendExt;
    }

    // The pipeline of a range: blended or not, extended material or not.
    pick(blend: bool, ext: bool): GPUPipeline {
        if (ext) return blend ? this.surfaceBlendExt : this.surfaceExt;
        return blend ? this.surfaceBlend : this.surface;
    }
}

// The surface module's vertex entries of the skinned pipelines
// (surface.wgsl's skinning block), and the vertex buffer slots of a skinned
// draw: the skin's slots and weights after the vertices, then UV set 1 for
// an extended material (where an instanced draw has it).
export const SKIN_VERTEX_ENTRY = "vs_surface_skinned";
export const SKIN_EXT_VERTEX_ENTRY = "vs_surface_ext_skinned";
export const SKIN_SLOT: u32 = 1;
export const SKIN_UV1_SLOT: u32 = 2;

// What FrameRenderer.warnings says (once) when the host cannot draw a
// skinned item (it is then drawn unskinned: its mesh as stored, at the bind
// pose, placed by the identity, a skinned item's world).
export const SKIN_PIPELINE_WARNING =
    "skinned meshes are drawn unposed at the scene's origin: the host rejected the skinned pipelines";

// probe.wgsl's entries (see the header).
export const PROBE_VERTEX_ENTRY = "vs_probe";
export const PROBE_PLACE_ENTRY = "fs_probe_place";
export const PROBE_DOWN_ENTRY = "fs_probe_down";
export const PROBE_COPY_ENTRY = "fs_probe_copy";
export const PROBE_FILTER_ENTRY = "fs_probe_filter";

// What FrameRenderer.warnings says when the host cannot draw the probes'
// passes (the frame is then drawn without its probes).
export const PROBE_PIPELINE_WARNING = "reflection probes are not drawn: the host rejected their pipelines";

// The reflection probes' passes (see the header; gpu/probes.as runs them).
export class ProbePipelines {
    // Group 0 of the probe module: FilterU at 0, the source texture at 1.
    layout: GPUBindGroupLayout;
    place: GPUPipeline;
    down: GPUPipeline;
    copy: GPUPipeline;
    filter: GPUPipeline;

    constructor(layout: GPUBindGroupLayout, place: GPUPipeline, down: GPUPipeline, copy: GPUPipeline, filter: GPUPipeline) {
        this.layout = layout;
        this.place = place;
        this.down = down;
        this.copy = copy;
        this.filter = filter;
    }
}

// Standard alpha blending: color src-alpha / one-minus-src-alpha, alpha
// one / one-minus-src-alpha.
export function alphaBlending(): GPUBlendState {
    const b = new GPUBlendState();
    b.srcColor = BlendFactor.srcAlpha;
    b.dstColor = BlendFactor.oneMinusSrcAlpha;
    b.colorOp = BlendOp.add;
    b.srcAlpha = BlendFactor.one;
    b.dstAlpha = BlendFactor.oneMinusSrcAlpha;
    b.alphaOp = BlendOp.add;
    return b;
}

// The normal-depth pass's two targets (milestone 62: always both, so its
// pipelines are the same whatever the frame plans): NORMAL_DEPTH_FORMAT,
// the view-space normal and depth SSAO and the reflections read, and
// SSR_SURFACE_FORMAT, the surface's F0 and roughness (surface.wgsl's
// NormalDepthOut), which only the reflections read.
function normalDepthTargets(): Array<GPUColorTargetDesc> {
    return [colorTarget(NORMAL_DEPTH_FORMAT, null), colorTarget(SSR_SURFACE_FORMAT, null)];
}

// A color target; `blend == null` disables blending (the source is written
// unchanged).
function colorTarget(format: TextureFormat, blend: GPUBlendState?): GPUColorTargetDesc {
    const t = new GPUColorTargetDesc();
    t.format = format;
    t.blend = blend;
    return t;
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

function depthDesc(d: DepthState): GPUDepthStencilDesc {
    const ds = new GPUDepthStencilDesc();
    ds.format = d.format;
    ds.compare = d.compare;
    ds.write = d.write;
    ds.depthBias = d.biasConstant;
    ds.depthBiasSlopeScale = d.biasSlopeScale;
    ds.depthBiasClamp = 0.0;
    return ds;
}

// Milestone 67: what every set of a renderer's pipelines (Pipelines and
// the sets `retarget` makes from it) shares, as it draws into no main pass
// target: the shadow, post-processing and probe pipelines once asked for
// (null when the host refused one: never asked again) and the comparison
// sampler.
class SharedPipelines {
    shadow: ShadowPipelines? = null;
    shadowTried: bool = false;
    compare: GPUSampler? = null;
    post: PostPipelines? = null;
    postTried: bool = false;
    probe: ProbePipelines? = null;
    probeTried: bool = false;
}

// The render pipelines and the layouts their bind groups are made from.
export class Pipelines {
    surfaceModule: GPUShaderModule;
    linesModule: GPUShaderModule;
    outlineModule: GPUShaderModule;
    composeModule: GPUShaderModule;
    // Group 0 / 1 / 2 of the surface module.
    globalsLayout: GPUBindGroupLayout;
    objectLayout: GPUBindGroupLayout;
    // Group 2: material uniform, five textures, one sampler.
    materialLayout: GPUBindGroupLayout;
    // Group 3: the environment's maps, the lightmap's and the probes' atlas
    // (see the header).
    envLayout: GPUBindGroupLayout;
    // Group 0 / 1 of the lines module (see the header).
    lineGlobalsLayout: GPUBindGroupLayout;
    lineObjectLayout: GPUBindGroupLayout;
    // Group 0 of the post passes.
    outlineLayout: GPUBindGroupLayout;
    composeLayout: GPUBindGroupLayout;
    surface: GPUPipeline;
    // Alpha-blended surfaces (glTF `BLEND`): drawn after the opaque ones
    // with depth writes off.
    surfaceBlend: GPUPipeline;
    surfaceId: GPUPipeline;
    // Depth-tested lines (mesh edges, grid, extras).
    lines: GPUPipeline;
    // Lines drawn on top of everything (wire mode, cursor).
    linesTop: GPUPipeline;
    points: GPUPipeline;
    pointsTop: GPUPipeline;
    // Post passes that finish a view on the GPU.
    outline: GPUPipeline;
    compose: GPUPipeline;
    // The lit mode's sky gradient: no vertex buffers, no depth test or
    // write, the main pass's MSAA count; the surface layouts.
    sky: GPUPipeline;
    // The main pass color format and sample count these were built for.
    colorFormat: TextureFormat;
    samples: u32;
    // `compose` for a host canvas whose format is not POST_FORMAT (built on
    // first use by `composeFor`).
    private composeCanvas: GPUPipeline? = null;
    private composeCanvasFormat: TextureFormat = POST_FORMAT;
    // The shadow pipelines, once asked for, and the comparison sampler: in
    // `shared` (milestone 67: one for every set `retarget` makes from
    // these, as they draw into no main pass target).
    private shared: SharedPipelines = new SharedPipelines();
    // The post module (null when the project has none) and its pipelines,
    // once asked for (`postTried`): null when the host rejected one, and
    // then never asked again.
    postModule: GPUShaderModule? = null;
    // The instanced pipelines, once asked for (`instancedTried`): null when
    // the host rejected one, and then never asked again.
    private instanced: InstancedPipelines? = null;
    private instancedTried: bool = false;
    // The extended pipelines, once asked for (`extTried`): null when the
    // host rejected one, and then never asked again.
    private ext: ExtPipelines? = null;
    private extTried: bool = false;
    // The top pipelines, once asked for (`topTried`): null when the host
    // rejected one, and then never asked again.
    private top: TopPipelines? = null;
    private topTried: bool = false;
    // The lightmap pipelines, once asked for (`lightmapTried`): null when
    // the host rejected one, and then never asked again.
    private lightmap: LightmapPipelines? = null;
    private lightmapTried: bool = false;
    // The probe module (null when the project has none) and its pipelines,
    // once asked for (`probeTried`): null when the host rejected one, and
    // then never asked again.
    probeModule: GPUShaderModule? = null;
    // The four group layouts of every surface module pipeline, in group
    // order (globals, object, material, environment).
    surfaceLayouts(): Array<GPUBindGroupLayout?> {
        return [this.globalsLayout, this.objectLayout, this.materialLayout, this.envLayout];
    }

    // Milestone 48: the skinned counterparts made so far (`skinnedOf`), by
    // the pipeline they stand for (null: the host refused it, or it has
    // none), looked up by identity.
    private skinBase: Array<GPUPipeline> = [];
    private skinMade: Array<GPUPipeline?> = [];
    // Milestone 67: the ubershader's depth prepass pipelines made so far
    // (`prepassPipeline`), by vertex kind and ext, and whether each was
    // asked for.
    private prepassMade: Array<GPUPipeline?> = [];
    private prepassTried: Array<bool> = [];

    constructor(
        surfaceModule: GPUShaderModule, linesModule: GPUShaderModule, outlineModule: GPUShaderModule,
        composeModule: GPUShaderModule, globalsLayout: GPUBindGroupLayout, objectLayout: GPUBindGroupLayout,
        materialLayout: GPUBindGroupLayout, envLayout: GPUBindGroupLayout, lineGlobalsLayout: GPUBindGroupLayout,
        lineObjectLayout: GPUBindGroupLayout, outlineLayout: GPUBindGroupLayout, composeLayout: GPUBindGroupLayout, surface: GPUPipeline,
        surfaceBlend: GPUPipeline, surfaceId: GPUPipeline, lines: GPUPipeline, linesTop: GPUPipeline,
        points: GPUPipeline, pointsTop: GPUPipeline, outline: GPUPipeline, compose: GPUPipeline, sky: GPUPipeline,
        colorFormat: TextureFormat, samples: u32,
    ) {
        this.surfaceModule = surfaceModule;
        this.linesModule = linesModule;
        this.outlineModule = outlineModule;
        this.composeModule = composeModule;
        this.globalsLayout = globalsLayout;
        this.objectLayout = objectLayout;
        this.materialLayout = materialLayout;
        this.envLayout = envLayout;
        this.lineGlobalsLayout = lineGlobalsLayout;
        this.lineObjectLayout = lineObjectLayout;
        this.outlineLayout = outlineLayout;
        this.composeLayout = composeLayout;
        this.surface = surface;
        this.surfaceBlend = surfaceBlend;
        this.surfaceId = surfaceId;
        this.lines = lines;
        this.linesTop = linesTop;
        this.points = points;
        this.pointsTop = pointsTop;
        this.outline = outline;
        this.compose = compose;
        this.sky = sky;
        this.colorFormat = colorFormat;
        this.samples = samples;
    }

    // The compose pipeline for a target of `format`: `compose` itself for
    // POST_FORMAT (the canvas format on every host tried), else one built
    // for that format (null when the host rejects it).
    composeFor(format: TextureFormat): GPUPipeline? {
        if (format == POST_FORMAT) return this.compose;
        const cached = this.composeCanvas;
        if (cached != null && this.composeCanvasFormat == format) return cached;
        const p = postPipeline(this.composeModule, this.composeLayout, "fs_compose", format);
        if (p.handle == 0) return null;
        this.composeCanvas = p;
        this.composeCanvasFormat = format;
        return p;
    }

    // The sampler group 0's binding 4 holds (surface.wgsl `s_shadow`):
    // linear filtering, so each comparison is a 2 x 2 PCF in hardware, and
    // `lessEqual` against the receiver's depth, clamped at the atlas edge.
    // Made on first use and kept.
    compareSampler(): GPUSampler {
        const cached = this.shared.compare;
        if (cached != null) return cached;
        const s = new GPUSampler(
            Filter.linear, Filter.linear, Filter.nearest, WrapMode.clampToEdge, WrapMode.clampToEdge,
            CompareFunction.lessEqual,
        );
        this.shared.compare = s;
        return s;
    }

    // The shadow pass's pipelines, made on the first call; null when the
    // host rejects either (the caller then draws no shadow and says so).
    shadowPipelines(): ShadowPipelines? {
        if (this.shared.shadowTried) return this.shared.shadow;
        this.shared.shadowTried = true;
        const layouts = this.surfaceLayouts();
        const buffers = [vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS)];
        const depth = shadowPipeline(this.surfaceModule, "vs_surface", null, layouts, buffers);
        if (depth.handle == 0) return null;
        const masked = shadowPipeline(this.surfaceModule, "vs_surface", SHADOW_FRAGMENT_ENTRY, layouts, buffers);
        if (masked.handle == 0) {
            depth.release();
            return null;
        }
        const sampler = this.compareSampler();
        if (sampler.handle == 0) {
            depth.release();
            masked.release();
            return null;
        }
        const p = new ShadowPipelines(depth, masked, sampler);
        this.shared.shadow = p;
        return p;
    }

    // The post-processing pipelines, made on the first call; null when the
    // project has no post module or the host rejects any of them (the
    // caller then draws no post-processing and says so).
    postPipelines(): PostPipelines? {
        if (this.shared.postTried) return this.shared.post;
        this.shared.postTried = true;
        const mod = this.postModule;
        if (mod == null) return null;
        const layout = GPUBindGroupLayout.fromShader(mod, 0);
        if (layout == null) return null;
        const made = new Array<GPUPipeline>();
        const surfaceLayouts = this.surfaceLayouts();
        const buffers = [vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS)];
        made.push(make("normal-depth", surfaceLayouts, this.surfaceModule, "vs_surface", "fs_normal_depth", buffers,
            normalDepthTargets(), depthState(true, true, 0), 1, true));
        const entries = ["fs_ssao", "fs_ssao_blur", "fs_glow_bright", "fs_glow_blur_h", "fs_glow_blur_v", "fs_post"];
        const formats: Array<TextureFormat> = [AO_FORMAT, AO_FORMAT, GLOW_FORMAT, GLOW_FORMAT, GLOW_FORMAT, POST_FORMAT];
        for (let i = 0; i < entries.length; i++) {
            if (made[made.length - 1].handle == 0) break;
            made.push(postPipeline(mod, layout, entries[i], formats[i]));
        }
        const sampler = new GPUSampler(
            Filter.linear, Filter.linear, Filter.nearest, WrapMode.clampToEdge, WrapMode.clampToEdge);
        let ok = made.length == entries.length + 1 && sampler.handle != 0;
        for (let i = 0; i < made.length; i++) {
            if (made[i].handle == 0) ok = false;
        }
        if (!ok) {
            for (let i = 0; i < made.length; i++) {
                if (made[i].handle != 0) made[i].release();
            }
            if (sampler.handle != 0) sampler.release();
            return null;
        }
        const p = new PostPipelines(layout, made[0], made[1], made[2], made[3], made[4], made[5], made[6], sampler);
        this.shared.post = p;
        return p;
    }

    // The instanced pipelines (see the header), made on the first call;
    // null when the host rejects any of them (the caller then draws no
    // instanced item and says so).
    instancedPipelines(): InstancedPipelines? {
        if (this.instancedTried) return this.instanced;
        this.instancedTried = true;
        const mod = this.surfaceModule;
        const layouts = this.surfaceLayouts();
        const buffers = [
            vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS),
            vertexLayout(INSTANCE_STRIDE, VertexStepMode.instance, INSTANCE_ATTRS),
        ];
        const vs = INSTANCED_VERTEX_ENTRY;
        const made = new Array<GPUPipeline>();
        made.push(make("surface-instanced", layouts, mod, vs, "fs_surface", buffers,
            [colorTarget(this.colorFormat, null)], depthState(true, true, 2), this.samples, true));
        made.push(make("surface-blend-instanced", layouts, mod, vs, "fs_surface", buffers,
            [colorTarget(this.colorFormat, alphaBlending())], depthState(true, false, 2), this.samples, true));
        made.push(make("surface-id-instanced", layouts, mod, vs, "fs_id", buffers, [colorTarget(ID_FORMAT, null)],
            depthState(true, true, 0), 1, true));
        made.push(make("normal-depth-instanced", layouts, mod, vs, "fs_normal_depth", buffers,
            normalDepthTargets(), depthState(true, true, 0), 1, true));
        made.push(shadowPipeline(mod, vs, null, layouts, buffers));
        made.push(shadowPipeline(mod, vs, SHADOW_FRAGMENT_ENTRY, layouts, buffers));
        let ok = true;
        for (let i = 0; i < made.length; i++) {
            if (made[i].handle == 0) ok = false;
        }
        if (!ok) {
            for (let i = 0; i < made.length; i++) {
                if (made[i].handle != 0) made[i].release();
            }
            return null;
        }
        const p = new InstancedPipelines(made[0], made[1], made[2], made[3], made[4], made[5]);
        this.instanced = p;
        return p;
    }

    // The extended pipelines (see the header), made on the first call; null
    // when the host rejects any of them (the caller then draws those
    // materials with the plain pipelines and says so).
    extPipelines(): ExtPipelines? {
        if (this.extTried) return this.ext;
        this.extTried = true;
        const mod = this.surfaceModule;
        const layouts = this.surfaceLayouts();
        const vertex = vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS);
        const uv1 = vertexLayout(UV1_STRIDE, VertexStepMode.vertex, UV1_ATTRS);
        const plainBuffers = [vertex, uv1];
        const instBuffers = [vertex, vertexLayout(INSTANCE_STRIDE, VertexStepMode.instance, INSTANCE_ATTRS), uv1];
        const made = new Array<GPUPipeline>();
        for (let k = 0; k < 2; k++) {
            const vs = k == 0 ? EXT_VERTEX_ENTRY : EXT_INSTANCED_VERTEX_ENTRY;
            const buffers = k == 0 ? plainBuffers : instBuffers;
            made.push(make("surface-ext", layouts, mod, vs, "fs_surface_ext", buffers,
                [colorTarget(this.colorFormat, null)], depthState(true, true, 2), this.samples, true));
            made.push(make("surface-blend-ext", layouts, mod, vs, "fs_surface_ext", buffers,
                [colorTarget(this.colorFormat, alphaBlending())], depthState(true, false, 2), this.samples, true));
            made.push(make("surface-id-ext", layouts, mod, vs, "fs_id_ext", buffers, [colorTarget(ID_FORMAT, null)],
                depthState(true, true, 0), 1, true));
            made.push(make("normal-depth-ext", layouts, mod, vs, "fs_normal_depth_ext", buffers,
                normalDepthTargets(), depthState(true, true, 0), 1, true));
            made.push(shadowPipeline(mod, vs, "fs_shadow_ext", layouts, buffers));
        }
        let ok = true;
        for (let i = 0; i < made.length; i++) {
            if (made[i].handle == 0) ok = false;
        }
        if (!ok) {
            for (let i = 0; i < made.length; i++) {
                if (made[i].handle != 0) made[i].release();
            }
            return null;
        }
        const p = new ExtPipelines(
            new ExtPipelineSet(made[0], made[1], made[2], made[3], made[4]),
            new ExtPipelineSet(made[5], made[6], made[7], made[8], made[9]),
        );
        this.ext = p;
        return p;
    }

    // The top pipelines (see the header), made on the first call; null
    // when the host rejects any of them (the caller then draws those items
    // with the depth test and says so).
    topPipelines(): TopPipelines? {
        if (this.topTried) return this.top;
        this.topTried = true;
        const mod = this.surfaceModule;
        const layouts = this.surfaceLayouts();
        const vertex = vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS);
        const plainBuffers = [vertex];
        const extBuffers = [vertex, vertexLayout(UV1_STRIDE, VertexStepMode.vertex, UV1_ATTRS)];
        const none = depthState(false, false, 0);
        const made = new Array<GPUPipeline>();
        made.push(make("surface-top", layouts, mod, "vs_surface", "fs_surface", plainBuffers,
            [colorTarget(this.colorFormat, alphaBlending())], none, this.samples, true));
        made.push(make("surface-top-ext", layouts, mod, EXT_VERTEX_ENTRY, "fs_surface_ext", extBuffers,
            [colorTarget(this.colorFormat, alphaBlending())], none, this.samples, true));
        made.push(make("surface-id-top", layouts, mod, "vs_surface", "fs_id", plainBuffers,
            [colorTarget(ID_FORMAT, null)], none, 1, true));
        made.push(make("surface-id-top-ext", layouts, mod, EXT_VERTEX_ENTRY, "fs_id_ext", extBuffers,
            [colorTarget(ID_FORMAT, null)], none, 1, true));
        let ok = true;
        for (let i = 0; i < made.length; i++) {
            if (made[i].handle == 0) ok = false;
        }
        if (!ok) {
            for (let i = 0; i < made.length; i++) {
                if (made[i].handle != 0) made[i].release();
            }
            return null;
        }
        const p = new TopPipelines(made[0], made[1], made[2], made[3]);
        this.top = p;
        return p;
    }

    // The lightmap pipelines (see the header), made on the first call;
    // null when the host rejects any of them (the caller then draws
    // lightmapped items with the ordinary pipelines and says so).
    lightmapPipelines(): LightmapPipelines? {
        if (this.lightmapTried) return this.lightmap;
        this.lightmapTried = true;
        const mod = this.surfaceModule;
        const layouts = this.surfaceLayouts();
        const buffers = [
            vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS),
            vertexLayout(UV1_STRIDE, VertexStepMode.vertex, UV1_ATTRS),
            vertexLayout(LM_UV_STRIDE, VertexStepMode.vertex, LM_UV_ATTRS),
        ];
        const vs = LIGHTMAP_VERTEX_ENTRY;
        const opaque = [colorTarget(this.colorFormat, null)];
        const blended = [colorTarget(this.colorFormat, alphaBlending())];
        const made = new Array<GPUPipeline>();
        made.push(make("surface-lm", layouts, mod, vs, LIGHTMAP_FRAGMENT_ENTRY, buffers, opaque,
            depthState(true, true, 2), this.samples, true));
        made.push(make("surface-blend-lm", layouts, mod, vs, LIGHTMAP_FRAGMENT_ENTRY, buffers, blended,
            depthState(true, false, 2), this.samples, true));
        made.push(make("surface-ext-lm", layouts, mod, vs, LIGHTMAP_EXT_FRAGMENT_ENTRY, buffers, opaque,
            depthState(true, true, 2), this.samples, true));
        made.push(make("surface-blend-ext-lm", layouts, mod, vs, LIGHTMAP_EXT_FRAGMENT_ENTRY, buffers, blended,
            depthState(true, false, 2), this.samples, true));
        let ok = true;
        for (let i = 0; i < made.length; i++) {
            if (made[i].handle == 0) ok = false;
        }
        if (!ok) {
            for (let i = 0; i < made.length; i++) {
                if (made[i].handle != 0) made[i].release();
            }
            return null;
        }
        const p = new LightmapPipelines(made[0], made[1], made[2], made[3]);
        this.lightmap = p;
        return p;
    }

    // The main pass's surface pipeline drawn with `module`, the ubershader
    // (surfaceModule) or one of its variants (../variant.as; the
    // specialisation's gpu/variants.as asks), for the vertex kind `kind`
    // (VB_D_VERTEX_*), the extended entries when `ext`, alpha-blended when
    // `blend`: the very desc of the ordinary pipeline of that kind (its
    // entry points, vertex buffers, target, depth state and samples) with
    // that module, and the layouts `layouts` (null: the ubershader's, which a
    // variant shares when its entry points bind what the ubershader's bind).
    // Made on every call: the caller keeps it. A pipeline whose handle is 0
    // is one the host refused.
    surfacePipelineOf(
        module: GPUShaderModule, kind: u32, ext: bool, blend: bool, layouts: Array<GPUBindGroupLayout?>? = null,
    ): GPUPipeline {
        const groups = layouts != null ? layouts : this.surfaceLayouts();
        const vertex = vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS);
        const uv1 = vertexLayout(UV1_STRIDE, VertexStepMode.vertex, UV1_ATTRS);
        let vs = ext ? EXT_VERTEX_ENTRY : "vs_surface";
        let fs = ext ? "fs_surface_ext" : "fs_surface";
        let buffers: Array<GPUVertexBufferLayout> = ext ? [vertex, uv1] : [vertex];
        if (kind == VB_D_VERTEX_INSTANCED) {
            const inst = vertexLayout(INSTANCE_STRIDE, VertexStepMode.instance, INSTANCE_ATTRS);
            vs = ext ? EXT_INSTANCED_VERTEX_ENTRY : INSTANCED_VERTEX_ENTRY;
            buffers = ext ? [vertex, inst, uv1] : [vertex, inst];
        } else if (kind == VB_D_VERTEX_SKINNED) {
            const skin = vertexLayout(SKIN_STRIDE, VertexStepMode.vertex, SKIN_ATTRS);
            vs = ext ? SKIN_EXT_VERTEX_ENTRY : SKIN_VERTEX_ENTRY;
            buffers = ext ? [vertex, skin, uv1] : [vertex, skin];
        } else if (kind == VB_D_VERTEX_LIGHTMAP) {
            vs = LIGHTMAP_VERTEX_ENTRY;
            fs = ext ? LIGHTMAP_EXT_FRAGMENT_ENTRY : LIGHTMAP_FRAGMENT_ENTRY;
            buffers = [vertex, uv1, vertexLayout(LM_UV_STRIDE, VertexStepMode.vertex, LM_UV_ATTRS)];
        }
        const target = [colorTarget(this.colorFormat, blend ? alphaBlending() : null)];
        return make("surface-of", groups, module, vs, fs, buffers, target, depthState(true, !blend, 2), this.samples, true);
    }

    // Milestone 67 (prepass.as): the ubershader's depth prepass pipeline of
    // vertex kind `kind` (VB_D_VERTEX_*), the extended entries' vertex
    // stage when `ext`: depthPipelineOf(surfaceModule, ...), made on the
    // first call and kept (null when the host refused it: asked once, and
    // the draws it would have served are left to the main pass alone).
    // Looking one up allocates nothing.
    prepassPipeline(kind: u32, ext: bool): GPUPipeline? {
        const i = <i32>((kind & 3) * 2 + (ext ? 1 : 0));
        const made = this.prepassMade;
        if (made.length == 0) {
            for (let k = 0; k < 8; k++) {
                made.push(null);
                this.prepassTried.push(false);
            }
        }
        if (unchecked(this.prepassTried[i])) return unchecked(made[i]);
        unchecked(this.prepassTried[i] = true);
        const p = this.depthPipelineOf(this.surfaceModule, kind & 3, ext);
        unchecked(made[i] = p.handle != 0 ? p : null);
        return unchecked(made[i]);
    }

    // Milestone 67 (quality.as): these pipelines for the main pass's colour
    // format `colorFormat` and `samples` MSAA samples (Godot's msaa_3d and
    // its Mobile renderer's 32-bit HDR target): the modules, the layouts
    // (so every bind group made for one set serves the other), the id,
    // outline and compose pipelines and the shadow, post-processing and
    // probe sets (which draw into no main pass target) shared, and the
    // pipelines that draw into the main pass's targets made again: the
    // surfaces, the lines, the points and the sky now, the instanced,
    // extended, top, lightmap, skinned and prepass ones on first use, as
    // the first set makes them. Null when the host refuses one.
    retarget(colorFormat: TextureFormat, samples: u32): Pipelines? {
        const surfaceLayouts = this.surfaceLayouts();
        const lineLayouts: Array<GPUBindGroupLayout?> = [this.lineGlobalsLayout, this.lineObjectLayout];
        const surfaceBuffers = [vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS)];
        const lineBuffers = [vertexLayout(LINE_INSTANCE_SIZE, VertexStepMode.instance, LINE_ATTRS)];
        const pointBuffers = [vertexLayout(POINT_INSTANCE_SIZE, VertexStepMode.instance, POINT_ATTRS)];
        const opaque = [colorTarget(colorFormat, null)];
        const blended = [colorTarget(colorFormat, alphaBlending())];
        const sm = this.surfaceModule;
        const lm = this.linesModule;
        const made = new Array<GPUPipeline>();
        made.push(make("surface", surfaceLayouts, sm, "vs_surface", "fs_surface", surfaceBuffers, opaque,
            depthState(true, true, 2), samples, true));
        made.push(make("surface-blend", surfaceLayouts, sm, "vs_surface", "fs_surface", surfaceBuffers, blended,
            depthState(true, false, 2), samples, true));
        made.push(make("lines", lineLayouts, lm, "vs_line", "fs_line", lineBuffers, blended, depthState(true, false, 0),
            samples, false));
        made.push(make("lines-top", lineLayouts, lm, "vs_line", "fs_line", lineBuffers, blended,
            depthState(false, false, 0), samples, false));
        made.push(make("points", lineLayouts, lm, "vs_point", "fs_point", pointBuffers, blended,
            depthState(true, false, 0), samples, false));
        made.push(make("points-top", lineLayouts, lm, "vs_point", "fs_point", pointBuffers, blended,
            depthState(false, false, 0), samples, false));
        made.push(make("sky", surfaceLayouts, sm, SKY_VERTEX_ENTRY, SKY_FRAGMENT_ENTRY, [], opaque,
            depthState(false, false, 0), samples, false));
        let ok = true;
        for (let i = 0; i < made.length; i++) {
            if (made[i].handle == 0) ok = false;
        }
        if (!ok) {
            for (let i = 0; i < made.length; i++) {
                if (made[i].handle != 0) made[i].release();
            }
            return null;
        }
        const p = new Pipelines(
            sm, lm, this.outlineModule, this.composeModule, this.globalsLayout, this.objectLayout, this.materialLayout,
            this.envLayout, this.lineGlobalsLayout, this.lineObjectLayout, this.outlineLayout, this.composeLayout,
            made[0], made[1], this.surfaceId, made[2], made[3], made[4], made[5], this.outline, this.compose, made[6],
            colorFormat, samples,
        );
        p.postModule = this.postModule;
        p.probeModule = this.probeModule;
        // (the sets that draw into no main pass target: one object for
        // every set, so a group made for one serves the others, and a
        // refusal is remembered by all)
        p.shared = this.shared;
        p.composeCanvas = this.composeCanvas;
        p.composeCanvasFormat = this.composeCanvasFormat;
        return p;
    }

    // The depth prepass's pipeline of `module` for the vertex kind `kind`
    // (and the extended entries' vertex stage when `ext`): surfacePipelineOf's
    // vertex stage, buffers, depth state (written, lessEqual, the surfaces'
    // bias) and samples, with no colour target and no fragment stage, so
    // that the main pass drawn after it with the same module finds the very
    // depths it wrote. Made on every call: the caller keeps it.
    depthPipelineOf(
        module: GPUShaderModule, kind: u32, ext: bool, layouts: Array<GPUBindGroupLayout?>? = null,
    ): GPUPipeline {
        const groups = layouts != null ? layouts : this.surfaceLayouts();
        const vertex = vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS);
        const uv1 = vertexLayout(UV1_STRIDE, VertexStepMode.vertex, UV1_ATTRS);
        let vs = ext ? EXT_VERTEX_ENTRY : "vs_surface";
        let buffers: Array<GPUVertexBufferLayout> = ext ? [vertex, uv1] : [vertex];
        if (kind == VB_D_VERTEX_INSTANCED) {
            const inst = vertexLayout(INSTANCE_STRIDE, VertexStepMode.instance, INSTANCE_ATTRS);
            vs = ext ? EXT_INSTANCED_VERTEX_ENTRY : INSTANCED_VERTEX_ENTRY;
            buffers = ext ? [vertex, inst, uv1] : [vertex, inst];
        } else if (kind == VB_D_VERTEX_SKINNED) {
            const skin = vertexLayout(SKIN_STRIDE, VertexStepMode.vertex, SKIN_ATTRS);
            vs = ext ? SKIN_EXT_VERTEX_ENTRY : SKIN_VERTEX_ENTRY;
            buffers = ext ? [vertex, skin, uv1] : [vertex, skin];
        } else if (kind == VB_D_VERTEX_LIGHTMAP) {
            vs = LIGHTMAP_VERTEX_ENTRY;
            buffers = [vertex, uv1, vertexLayout(LM_UV_STRIDE, VertexStepMode.vertex, LM_UV_ATTRS)];
        }
        const d = new GPUPipelineDesc();
        d.vertexModule = module;
        d.vertexEntryPoint = vs;
        d.fragmentModule = null;
        d.colorTargets = [];
        d.vertexBuffers = buffers;
        d.bindGroupLayouts = groups;
        d.topology = PrimitiveTopology.triangleList;
        d.indexFormat = IndexFormat.uint32;
        d.cullMode = CullMode.none;
        d.winding = FaceWinding.counterClockwise;
        d.depthStencil = depthDesc(depthState(true, true, 2));
        d.sampleCount = this.samples;
        return new GPUPipeline(d);
    }

    // Milestone 48: the skinned counterpart of surface pipeline `p` (see
    // the header): made on the first call for `p`, then kept; null when `p`
    // has none (an instanced or lightmap pipeline, the sky) or the host
    // refused it (asked once: the caller draws the item unskinned, its
    // bind-pose mesh placed by the identity, and says so). Looking one up allocates nothing.
    skinnedOf(p: GPUPipeline): GPUPipeline? {
        const base = this.skinBase;
        for (let i = 0; i < base.length; i++) {
            if (unchecked(base[i]) === p) return unchecked(this.skinMade[i]);
        }
        const made = this.makeSkinned(p);
        base.push(p);
        this.skinMade.push(made);
        return made;
    }

    // How many skinned pipelines exist (tests see them made once).
    get skinnedCount(): i32 {
        let n = 0;
        for (let i = 0; i < this.skinMade.length; i++) if (this.skinMade[i] != null) n++;
        return n;
    }

    private makeSkinned(p: GPUPipeline): GPUPipeline? {
        const mod = this.surfaceModule;
        const layouts = this.surfaceLayouts();
        const vertex = vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS);
        const skin = vertexLayout(SKIN_STRIDE, VertexStepMode.vertex, SKIN_ATTRS);
        const plain = [vertex, skin];
        const ext = [vertex, skin, vertexLayout(UV1_STRIDE, VertexStepMode.vertex, UV1_ATTRS)];
        const vs = SKIN_VERTEX_ENTRY;
        const evs = SKIN_EXT_VERTEX_ENTRY;
        const opaque = [colorTarget(this.colorFormat, null)];
        const blended = [colorTarget(this.colorFormat, alphaBlending())];
        const ids = [colorTarget(ID_FORMAT, null)];
        const nd = normalDepthTargets();
        const none = depthState(false, false, 0);
        let made: GPUPipeline? = null;
        if (p === this.surface) {
            made = make("surface-skinned", layouts, mod, vs, "fs_surface", plain, opaque, depthState(true, true, 2),
                this.samples, true);
        } else if (p === this.surfaceBlend) {
            made = make("surface-blend-skinned", layouts, mod, vs, "fs_surface", plain, blended,
                depthState(true, false, 2), this.samples, true);
        } else if (p === this.surfaceId) {
            made = make("surface-id-skinned", layouts, mod, vs, "fs_id", plain, ids, depthState(true, true, 0), 1, true);
        }
        const post = this.shared.post;
        if (made == null && post != null && p === post.normalDepth) {
            made = make("normal-depth-skinned", layouts, mod, vs, "fs_normal_depth", plain, nd, depthState(true, true, 0),
                1, true);
        }
        const shadow = this.shared.shadow;
        if (made == null && shadow != null) {
            if (p === shadow.depth) made = shadowPipeline(mod, vs, null, layouts, plain);
            else if (p === shadow.masked) made = shadowPipeline(mod, vs, SHADOW_FRAGMENT_ENTRY, layouts, plain);
        }
        const ep = this.ext;
        if (made == null && ep != null) {
            const e = ep.plain;
            if (p === e.surface) {
                made = make("surface-ext-skinned", layouts, mod, evs, "fs_surface_ext", ext, opaque,
                    depthState(true, true, 2), this.samples, true);
            } else if (p === e.surfaceBlend) {
                made = make("surface-blend-ext-skinned", layouts, mod, evs, "fs_surface_ext", ext, blended,
                    depthState(true, false, 2), this.samples, true);
            } else if (p === e.surfaceId) {
                made = make("surface-id-ext-skinned", layouts, mod, evs, "fs_id_ext", ext, ids, depthState(true, true, 0),
                    1, true);
            } else if (p === e.normalDepth) {
                made = make("normal-depth-ext-skinned", layouts, mod, evs, "fs_normal_depth_ext", ext, nd,
                    depthState(true, true, 0), 1, true);
            } else if (p === e.shadowMasked) {
                made = shadowPipeline(mod, evs, "fs_shadow_ext", layouts, ext);
            }
        }
        const tp = this.top;
        if (made == null && tp != null) {
            const top = [colorTarget(this.colorFormat, alphaBlending())];
            if (p === tp.surface) {
                made = make("surface-top-skinned", layouts, mod, vs, "fs_surface", plain, top, none, this.samples, true);
            } else if (p === tp.surfaceExt) {
                made = make("surface-top-ext-skinned", layouts, mod, evs, "fs_surface_ext", ext, top, none, this.samples,
                    true);
            } else if (p === tp.surfaceId) {
                made = make("surface-id-top-skinned", layouts, mod, vs, "fs_id", plain, ids, none, 1, true);
            } else if (p === tp.surfaceIdExt) {
                made = make("surface-id-top-ext-skinned", layouts, mod, evs, "fs_id_ext", ext, ids, none, 1, true);
            }
        }
        if (made == null) return null;
        if (made.handle == 0) return null;
        return made;
    }

    // The reflection probes' pipelines (see the header), made on the first
    // call; null when the project has no probe module or the host rejects
    // any of them (the caller then draws no probe and says so).
    probePipelines(): ProbePipelines? {
        if (this.shared.probeTried) return this.shared.probe;
        this.shared.probeTried = true;
        const mod = this.probeModule;
        if (mod == null) return null;
        const layout = GPUBindGroupLayout.fromShader(mod, 0);
        if (layout == null) return null;
        const entries = [PROBE_PLACE_ENTRY, PROBE_DOWN_ENTRY, PROBE_COPY_ENTRY, PROBE_FILTER_ENTRY];
        const made = new Array<GPUPipeline>();
        for (let i = 0; i < entries.length; i++) {
            made.push(fullScreenPipeline(mod, layout, PROBE_VERTEX_ENTRY, entries[i], PROBE_ATLAS_FORMAT));
        }
        let ok = true;
        for (let i = 0; i < made.length; i++) {
            if (made[i].handle == 0) ok = false;
        }
        if (!ok) {
            for (let i = 0; i < made.length; i++) {
                if (made[i].handle != 0) made[i].release();
            }
            return null;
        }
        const p = new ProbePipelines(layout, made[0], made[1], made[2], made[3]);
        this.shared.probe = p;
        return p;
    }

    // Every pipeline. `colorFormat` is the main target format
    // (COLOR_FORMAT or its fallback), `samples` the MSAA count (MSAA_SAMPLES
    // clamped to the device). Fails with a Device error naming what the host
    // rejected.
    static create(ctx: Context, colorFormat: TextureFormat, samples: u32): Result<Pipelines> {
        const surfaceMod = ctx.shader(shaderAsset(SURFACE_SHADER));
        if (surfaceMod == null) return missingShader<Pipelines>(shaderAsset(SURFACE_SHADER));
        const linesMod = ctx.shader(shaderAsset(LINES_SHADER));
        if (linesMod == null) return missingShader<Pipelines>(shaderAsset(LINES_SHADER));
        const outlineMod = ctx.shader(shaderAsset(OUTLINE_SHADER));
        if (outlineMod == null) return missingShader<Pipelines>(shaderAsset(OUTLINE_SHADER));
        const composeMod = ctx.shader(shaderAsset(COMPOSE_SHADER));
        if (composeMod == null) return missingShader<Pipelines>(shaderAsset(COMPOSE_SHADER));

        const globalsLayout = GPUBindGroupLayout.fromShader(surfaceMod, 0);
        if (globalsLayout == null) return layoutError<Pipelines>("globals");
        const objectLayout = GPUBindGroupLayout.fromShader(surfaceMod, 1, [0]);
        if (objectLayout == null) return layoutError<Pipelines>("object");
        const materialLayout = GPUBindGroupLayout.fromShader(surfaceMod, 2);
        if (materialLayout == null) return layoutError<Pipelines>("material");
        const envLayout = GPUBindGroupLayout.fromShader(surfaceMod, 3);
        if (envLayout == null) return layoutError<Pipelines>("environment");
        const lineGlobalsLayout = GPUBindGroupLayout.fromShader(linesMod, 0);
        if (lineGlobalsLayout == null) return layoutError<Pipelines>("globals");
        const lineObjectLayout = GPUBindGroupLayout.fromShader(linesMod, 1, [0]);
        if (lineObjectLayout == null) return layoutError<Pipelines>("object");
        const outlineLayout = GPUBindGroupLayout.fromShader(outlineMod, 0);
        if (outlineLayout == null) return layoutError<Pipelines>("outline");
        const composeLayout = GPUBindGroupLayout.fromShader(composeMod, 0);
        if (composeLayout == null) return layoutError<Pipelines>("compose");

        // Lines never touch materials; a shorter layout keeps their draws
        // valid without binding group 2 (groups 0 and 1 stay compatible).
        const surfaceLayouts: Array<GPUBindGroupLayout?> = [globalsLayout, objectLayout, materialLayout, envLayout];
        const lineLayouts: Array<GPUBindGroupLayout?> = [lineGlobalsLayout, lineObjectLayout];

        const surfaceBuffers = [vertexLayout(SURFACE_VERTEX_SIZE, VertexStepMode.vertex, SURFACE_ATTRS)];
        const lineBuffers = [vertexLayout(LINE_INSTANCE_SIZE, VertexStepMode.instance, LINE_ATTRS)];
        const pointBuffers = [vertexLayout(POINT_INSTANCE_SIZE, VertexStepMode.instance, POINT_ATTRS)];
        const opaque = [colorTarget(colorFormat, null)];
        const blended = [colorTarget(colorFormat, alphaBlending())];
        const idTargets = [colorTarget(ID_FORMAT, null)];

        // Surfaces get a polygon offset so edges drawn afterwards win.
        const surface = make("surface", surfaceLayouts, surfaceMod, "vs_surface", "fs_surface", surfaceBuffers, opaque,
            depthState(true, true, 2), samples, true);
        if (surface.handle == 0) return pipelineError<Pipelines>("surface");
        const surfaceBlend = make("surface-blend", surfaceLayouts, surfaceMod, "vs_surface", "fs_surface", surfaceBuffers,
            blended, depthState(true, false, 2), samples, true);
        if (surfaceBlend.handle == 0) return pipelineError<Pipelines>("surface-blend");
        const surfaceId = make("surface-id", surfaceLayouts, surfaceMod, "vs_surface", "fs_id", surfaceBuffers, idTargets,
            depthState(true, true, 0), 1, true);
        if (surfaceId.handle == 0) return pipelineError<Pipelines>("surface-id");
        const lines = make("lines", lineLayouts, linesMod, "vs_line", "fs_line", lineBuffers, blended,
            depthState(true, false, 0), samples, false);
        if (lines.handle == 0) return pipelineError<Pipelines>("lines");
        const linesTop = make("lines-top", lineLayouts, linesMod, "vs_line", "fs_line", lineBuffers, blended,
            depthState(false, false, 0), samples, false);
        if (linesTop.handle == 0) return pipelineError<Pipelines>("lines-top");
        const points = make("points", lineLayouts, linesMod, "vs_point", "fs_point", pointBuffers, blended,
            depthState(true, false, 0), samples, false);
        if (points.handle == 0) return pipelineError<Pipelines>("points");
        const pointsTop = make("points-top", lineLayouts, linesMod, "vs_point", "fs_point", pointBuffers, blended,
            depthState(false, false, 0), samples, false);
        if (pointsTop.handle == 0) return pipelineError<Pipelines>("points-top");

        const outline = postPipeline(outlineMod, outlineLayout, "fs_outline", POST_FORMAT);
        if (outline.handle == 0) return pipelineError<Pipelines>("outline");
        const compose = postPipeline(composeMod, composeLayout, "fs_compose", POST_FORMAT);
        if (compose.handle == 0) return pipelineError<Pipelines>("compose");
        // The sky reads groups 0 and 3 only, but the native host checks every
        // group the module declares against the pipeline layout, so it takes
        // the surface layouts (and the draw binds all four groups).
        const sky = make("sky", surfaceLayouts, surfaceMod, SKY_VERTEX_ENTRY, SKY_FRAGMENT_ENTRY, [], opaque,
            depthState(false, false, 0), samples, false);
        if (sky.handle == 0) return pipelineError<Pipelines>("sky");

        const made = new Pipelines(
            surfaceMod, linesMod, outlineMod, composeMod, globalsLayout, objectLayout, materialLayout, envLayout,
            lineGlobalsLayout, lineObjectLayout, outlineLayout, composeLayout, surface, surfaceBlend, surfaceId,
            lines, linesTop, points, pointsTop, outline, compose, sky, colorFormat, samples,
        );
        // Fetched, not compiled into pipelines: those wait for the first
        // frame that plans a post pass (see the header).
        made.postModule = ctx.shader(shaderAsset(POST_SHADER));
        made.probeModule = ctx.shader(shaderAsset(PROBE_SHADER));
        return Result.okv<Pipelines>(made);
    }
}

// One render pipeline: triangle lists, no culling, counter-clockwise front
// faces, the given depth state and sample count. `_label` names the pipeline
// for readers only (the host API takes no label).
function make(
    _label: string,
    layouts: Array<GPUBindGroupLayout?>,
    module: GPUShaderModule,
    vs: string,
    fs: string,
    buffers: Array<GPUVertexBufferLayout>,
    targets: Array<GPUColorTargetDesc>,
    depth: DepthState,
    samples: u32,
    indexed: bool,
): GPUPipeline {
    const d = new GPUPipelineDesc();
    d.vertexModule = module;
    d.vertexEntryPoint = vs;
    d.fragmentModule = module;
    d.fragmentEntryPoint = fs;
    d.colorTargets = targets;
    d.vertexBuffers = buffers;
    d.bindGroupLayouts = layouts;
    d.topology = PrimitiveTopology.triangleList;
    // The surfaces draw with a u32 index buffer (uint32 at
    // setIndexBuffer); the host wants the format on the pipeline too.
    d.indexFormat = indexed ? IndexFormat.uint32 : IndexFormat.none;
    d.cullMode = CullMode.none;
    d.winding = FaceWinding.counterClockwise;
    d.depthStencil = depthDesc(depth);
    d.sampleCount = samples;
    return new GPUPipeline(d);
}

// A shadow pass pipeline: vertex entry `vs` (`vs_surface`, or the instanced
// one with its two buffers), the fragment entry `fs` (null: a
// depth-only pipeline with no fragment stage), no colour target, the
// atlas's depth format with the surface pipelines' test and bias, one
// sample, faces never culled (the main pass culls none either, so a
// single-sided plane casts from both sides, as it is drawn).
function shadowPipeline(
    module: GPUShaderModule, vs: string, fs: string?, layouts: Array<GPUBindGroupLayout?>,
    buffers: Array<GPUVertexBufferLayout>,
): GPUPipeline {
    const d = new GPUPipelineDesc();
    d.vertexModule = module;
    d.vertexEntryPoint = vs;
    if (fs != null) {
        d.fragmentModule = module;
        d.fragmentEntryPoint = fs;
    } else {
        d.fragmentModule = null;
    }
    d.colorTargets = [];
    d.vertexBuffers = buffers;
    d.bindGroupLayouts = layouts;
    d.topology = PrimitiveTopology.triangleList;
    d.indexFormat = IndexFormat.uint32;
    d.cullMode = CullMode.none;
    d.winding = FaceWinding.counterClockwise;
    const ds = depthState(true, true, 2);
    ds.format = SHADOW_ATLAS_FORMAT;
    d.depthStencil = depthDesc(ds);
    d.sampleCount = 1;
    return new GPUPipeline(d);
}

// A full-screen-triangle pass writing `format`, no depth, no blending.
function postPipeline(module: GPUShaderModule, layout: GPUBindGroupLayout, fs: string, format: TextureFormat): GPUPipeline {
    return fullScreenPipeline(module, layout, "vs_full", fs, format);
}

// `postPipeline` with the vertex entry `vs` (the probe module's is its own;
// milestone 62's screen texture's too, gpu/screen_chain.as).
export function fullScreenPipeline(
    module: GPUShaderModule, layout: GPUBindGroupLayout, vs: string, fs: string, format: TextureFormat,
): GPUPipeline {
    const d = new GPUPipelineDesc();
    d.vertexModule = module;
    d.vertexEntryPoint = vs;
    d.fragmentModule = module;
    d.fragmentEntryPoint = fs;
    d.colorTargets = [colorTarget(format, null)];
    d.vertexBuffers = [];
    const layouts: Array<GPUBindGroupLayout?> = [layout];
    d.bindGroupLayouts = layouts;
    d.topology = PrimitiveTopology.triangleList;
    d.cullMode = CullMode.none;
    d.depthStencil = null;
    d.sampleCount = 1;
    return new GPUPipeline(d);
}

function missingShader<T>(name: string): Result<T> {
    return RenderError.device("shader asset '" + name + "' not found (is shaders/render/ in the project?)").fail<T>();
}

function layoutError<T>(name: string): Result<T> {
    return RenderError.device("the host rejected the " + name + " bind group layout").fail<T>();
}

function pipelineError<T>(name: string): Result<T> {
    return RenderError.device("the host rejected the " + name + " pipeline").fail<T>();
}
