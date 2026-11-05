// Rendering one frame (frame.as `RenderFrame`) on the GPU, plus the
// renderer's device state (creation, object uniforms, transient buffers,
// warnings). What to draw is decided by the program that builds the frame
// (Hedra: engine/src/authoring/model_view/scene_adapter.as); this module only
// draws it.
//
// One frame is four passes, all recorded inside the host's `draw` (the only
// place a render pass may begin), after a fifth when the frame draws
// shadows, and with more when it draws post-processing (milestone 12,
// post.as `planPost`; SSAO before the main pass, glow and the final pass
// after it):
//
//   P0 shadow   only when shadow.as `planShadows` plans a tile: every
//               caster into each tile of the depth32float shadow atlas, one
//               depth-only pass with a viewport per tile. Without a tile
//               no such pass runs and the main pass binds a 1 x 1 dummy
//               map, so the frame's passes and pictures are what they were
//               before shadows existed (Hedra never plans one). (A
//               renderer's first frame also runs an empty pass that clears
//               that dummy map once.)
//   SSAO        only with the plan's `ssao`: the normal-depth pass (every
//               surface but shadows-only items and alpha-blended ranges,
//               surface.wgsl `fs_normal_depth`, NORMAL_DEPTH_FORMAT at px
//               size, one sample), then fs_ssao and fs_ssao_blur
//               (post_effects.wgsl, AO_FORMAT at px size). The main pass
//               binds the blurred occlusion at group 0, binding 6; every
//               other frame binds the 1 x 1 dummy there.
//   P1 main     the main pass, in a fixed draw order: MSAA
//               color (rgba16float, see layouts.as) resolved into `resolve`,
//               MSAA depth32float; a lit frame with a sky draws it first.
//               With glow, lit() and the sky keep their HDR colour
//               (ENV_HDR) for the passes below to tone map.
//   overlay     only with the final pass and a line or point to draw: the
//               main pass then ends after the surfaces, keeping its depth,
//               and the grid, edges, points and gizmos are drawn into a
//               transparent layer of their own (same samples, same depth
//               test), which fs_post lays over the finished picture, so no
//               post effect touches them.
//   glow        only with the plan's `glow`: fs_glow_bright from the
//               resolve into level 1 (half the picture's size before
//               SSAA), then per level 1 .. `glowLevels` fs_glow_blur_h and
//               fs_glow_blur_v (GLOW_FORMAT; level k at 1 / 2^k, mip
//               k - 1 of one chain, so fs_post binds one texture).
//   final       only with glow or adjustments: fs_post from the resolve,
//               the levels and the overlay layer into `graded`, sRGB
//               values in rgba8unorm at px size.
//   P2 id       the id pass, only for the selection outline: object
//               index + selected/active bits into one rgba8unorm target.
//   P3 outline  the selection outline (Hedra's scene_view.as `outline`
//               is its CPU reference) + the sRGB encode, into rgba8unorm
//               bytes at px size (shaders/render/post_outline.wgsl); it
//               reads `graded` with the encode off when the final pass ran,
//               so the outline is drawn over the finished picture.
//   P4 compose  the SSAA downsample (`Image.downsample`) + the frame's
//               overlay (labels and axis gizmo, which the CPU draws into a
//               transparent image) blended over the view with
//               `Image.blend`'s integer math (post_compose.wgsl).
//
// There is no readback, so the view's result stays on the GPU as a
// `GpuImage` (rgba8unorm, straight-alpha sRGB bytes, the layout of a CPU
// `Image`). `sheet` tiles views like composite.as `sheet`, and `present`
// puts an image on the host canvas for the host's capture. Label occlusion
// uses a CPU ray cast (Hedra's `RayCastProbe`) in place of the id-depth
// readback.
//
// Buffers: rive may execute a frame's passes after every `GPUBuffer.update`
// of that frame has landed, so a buffer that a recorded pass reads is never
// rewritten in the same frame: each view of a frame gets its own globals and
// object buffers (a `ViewBuffers` slot; `beginFrame` recycles them). (A host
// frame can hold many views: `renderFrame` is one view.) The shadow pass
// draws each tile with the view's Globals but the tile's view-projection,
// so each tile has its own Globals buffer in the slot, too.
//
// The sky (milestone 11): a lit frame whose environment has a Sky resource
// gets its image-based light from `ibl` (sky.as `IblCache`: built on the
// CPU once per sky, kept while the sky is unchanged) and `environment`
// uploads it (gpu/environment.as, again only for a new plan), bound at
// group 0, bindings 6 to 9; each view's sky block (binding 5) is written
// every frame from sky.as `skyUniform`. A frame without a Sky or fog builds
// nothing, uploads nothing and writes a block of zeros, which the shader
// never reads past its flags: its pictures are what they were before.
//
// Scale (milestone 13). Each view first asks cull.as `cullFrame` which items
// each pass draws (`cull`), and every pass draws exactly those: the main,
// id, normal-depth and overlay passes an item whose `main` is CULL_DRAWN,
// shadow tile t an item whose `casters` has bit t. Culling leaves out only
// what lies wholly outside a pass's frustum, where the GPU clipped every
// triangle anyway, so no picture changes (`cullingEnabled` false culls
// nothing by frustum, for the test that proves it); `lastStats` is what the
// GPU was given, and `drawCountError` checks that the calls made are the
// draws it counts. An item with `instances` (a MultiMeshInstance3D, or
// milestone 35's CPUParticles3D, whose dynamic instances are written again
// when they move) is one instanced draw of its mesh (gpu/instances.as
// uploads its instance buffer on first use; pipelines.as
// `instancedPipelines` are made on the first frame that draws one). And a
// frame drawn again (the editor's viewport moving its camera over one plan: SceneRenderer.present of the same frame) allocates
// nothing on the heap, which the stub runtime never frees: the uniform
// blocks are written into kept bytes, the object uniforms into a kept
// buffer, the render targets are pooled per view (`slotTarget`, as
// `postPool`), the material groups kept while the frame's materials are the
// same array (`bindMaterials`), the passes' descriptors, attachments and
// wrapper kept, the post, outline, compose and present groups kept while
// their views are the same, and bind groups set through the host binding
// with a kept offset word (`bindGroup`, `bindGroupAt`: GPURenderPass's
// setBindGroup packs its offsets into a new buffer every call).
//
// Post-processing (milestone 12): a frame that plans no pass (every frame
// of Hedra, and every scene that turns nothing on) runs none, writes the
// lit block it wrote before and binds the dummy at binding 6, so its
// passes and pictures are what they were before. The post targets are
// pooled per view from frame to frame (`postPool`, `postChain`), since
// making about 15 targets a frame cost as much as drawing into them; one
// replaced by a new size is released at the next `beginFrame`. The post
// pipelines are made on the first frame that plans a pass (pipelines.as
// `postPipelines`).
//
// A second picture (milestone 14: Hedra's material preview beside its
// viewport) is drawn by a `sibling`: a FrameRenderer on the same device and
// pipelines with its own canvas and per-frame state, so each renderer's
// `beginFrame` releases only its own frame's things and each `redraw`s its
// own canvas.
//
// No depth test (milestone 16, Godot's no_depth_test): an item with
// DrawItem.noDepthTest (top_pass.as `isTopItem`: not instanced, with a mesh)
// is left out of the main pass's surface loops and drawn after the blended
// ones, in slot order, every range whatever its blend mode, alpha-blended
// and without the depth test or write (pipelines.as `topPipelines`, the ext
// one for an extended material); the id pass draws it last the same way,
// so its outline shows over everything, and the normal-depth pass leaves it
// out (it occludes nothing). The shadow pass draws it as any caster. The
// pipelines are made on the first frame with such an item; a host that
// refuses them draws it depth-tested, as before, and the renderer says so
// once. A frame without one (every frame of Hedra) asks for nothing and
// draws what it drew before.
//
// Baked lighting (milestone 19, Godot's LightmapGI): a frame with a
// `lightmap` has its layers uploaded once per LightmapImages object
// (gpu/lightmap.as) and bound at group 3, bindings 4 and 5 (a 1 x 1 x 1
// black dummy in every other frame, which nothing reads). In the main pass,
// an item `lightmapDrawKind` says is lightmapped is drawn with the
// lightmap pipelines (pipelines.as `lightmapPipelines`, made on the first
// frame with one): its mesh's lightmap coordinates bound at LM_UV_SLOT and
// UV set 1 at LM_UV1_SLOT, surface.wgsl's `vs_surface_lm` and
// `fs_surface_lm` / `fs_surface_ext_lm`, which take its diffuse light from
// the lightmap and skip the static lights. Every other pass draws it as any
// item. An item with probe light (OBJ_PROBE_GI) needs no pipeline of its
// own: lit() reads its uniform. A host that refuses the texture or the
// pipelines draws those items in real-time light, saying so. A frame
// without a lightmap asks for nothing and draws what it drew before.
//
// Reflection probes (milestone 20, Godot's ReflectionProbe): a lit frame
// with `probes` has them on the GPU through gpu/probes.as (`probes`): the
// atlas bound at group 3, binding 6 (a 1 x 1 dummy in every other frame,
// which nothing reads), its sampler at 7, and each view's probe block at
// group 0, binding 7 (zeros, count 0, in a frame without probes, which the shader reads
// nothing past). Before the first view of a host frame draws, the probes
// the schedule names are uploaded (a baked cube, once per object) or
// captured live (`captureProbe`): six views of the scene from the probe,
// each drawn by `captureView` with this renderer's own passes (the
// shadow pass when the probe enables shadows, then the sky and the
// surfaces, `drawSurfaces`, into an N x N HDR target, ENV_HDR: no tone
// map), its own uniform slots (`captureSlots`, so a capture never rewrites
// a buffer a view recorded earlier reads), then probe.wgsl's passes into
// the atlas. A capture draws no probe, no overlay, line, point, outline or
// post pass. A frame without probes asks for nothing, writes the block of
// zeros it wrote before and draws what it drew before.
//
// Skinning (milestone 48, Godot's Skeleton3D): an item with DrawItem.skin
// whose mesh carries a skin (mesh_cache.as `hasSkin`, its slots and weights
// uploaded with it) is drawn in every pass with the skinned counterpart of
// the pipeline it would have used (pipelines.as `skinnedOf`, made on first
// use), the skin's vertex buffer at SKIN_SLOT and, for an extended material,
// UV set 1 at SKIN_UV1_SLOT. Its palette is a uniform at group 1, binding 1:
// each view keeps one buffer and one object group per skinned item it draws
// (`uploadSkins`, the n-th skinned item the n-th, kept from frame to frame),
// and writes the palette only when the item's skin array or skinVersion
// differs from what the buffer holds, so an unmoving skeleton uploads
// nothing and allocates nothing. Every other object group binds one dummy
// palette, which nothing reads. A host that refuses a skinned pipeline draws
// the item unskinned (its bind-pose mesh with the identity for a world: at
// the frame's origin) and casts no shadow from it, saying so once. A frame without a skinned item
// (every frame of Hedra) draws what it drew before.
//
// Viewports (milestone 34, Godot's SubViewport; viewport.as and
// gpu/viewports.as): before the main view of a frame with viewports, the
// ones the schedule picks are drawn (`viewportPasses`), each its frame
// (RenderFrame.viewports[k].frame: its camera, size, world, lights,
// environment and background) through `drawView`, the very passes the main
// view runs, into a uniform slot of its own (`viewportSlots`, one per index
// of the frame's viewports, kept apart from the main views' `slots` and
// with post targets of their own, so no slot's pooled targets change size
// from frame to frame), its shadows planned into a plan of its own
// (`viewportShadowPlan`), its sky's light from the main pair (`ibl`,
// `environment`) or, for a world lit by another sky, a pair of its own
// (GpuViewports.ownIbl), which its slot's environment group binds; then
// its picture is blitted into its live targets and bound wherever its
// textures are named (GpuViewports.finish). Each view draws only the items
// and decals of its frame's world (cull.as, decal_select.as), paints the
// decals its own camera chooses (gpu/decals.as `prepare` for it, the live
// layers not blitted again; the main camera's prepared again after), and
// one with a transparent background (RenderFrame.transparent) draws no sky
// and clears to (0, 0, 0, 0). A view whose frame has no probes (a world of
// its own) writes the zero probe block. `lastStats`, `madeDraws` and the
// other counts are the main view's: it draws last. Every view, and every
// face of a probe's live capture, reports what it drew of the viewports'
// textures (GpuViewports.noteUsed), which the schedule's when_visible
// reads at the next frame. A frame without viewports runs none of this and
// draws what it drew before.
//
// Lights per object (milestone 59; light_pool.as, light_select.as): every
// view chooses its own pool of up to 64 of the frame's lights (the main
// view and each viewport `planLightPool` for its camera, each face of a
// probe's capture `planLightPoolAround` the probe's origin) before its
// shadows are planned, which serve that pool's lights by importance; right
// before its object uniforms are written it gives each item its list of up
// to 8 pool entries (`lightItems`: in the lit and lights shadings; in every
// other the lists are emptied, so the object blocks keep their zeros). The
// lit block then holds the pool and is uploaded only as far as its count
// (`uploadLit`). The lights shading (SHADE_LIGHT_COUNT) plans the pool and
// the lists, and runs no shadow, sky, post or decal pass (they are the lit
// mode's). A scene of 8 lights or fewer draws exactly as it did when the
// whole frame's first 8 lights lit every item.
//
// Fog volumes (milestone 37; fog_volume.as, fog_select.as, gpu/fog.as):
// every view (the main one and each viewport) chooses its own fog for its
// camera right after its items' lights (prepareFogVolumes: the pool, each
// item's list in its object block's decals.w, the sky's, each entry's
// lights from the view's light pool) and writes its fog block (the object
// group's FOG_BLOCK_BINDING) once its sky block is known (the ambient
// light the fog takes in is the sky's); a probe's capture draws none (its
// items' lists emptied, the zero block). A view without volumetric fog
// writes the block's counts as zeros once and its items' words are 0, so
// it draws as before.
//
// Custom shaders (milestone 61, Godot's ShaderMaterial in WGSL;
// gpu/custom.as says how they are drawn): before a view draws, the
// frame's shader source (FrameRenderer.shaderModules, else the installed
// one: render/shader/modules.as) is asked for the module of each
// ShaderMaterial of the frame (MaterialDesc.custom), in the lit shading
// alone (`prepareCustom`); a material with one is drawn by its module's
// pipelines (gpu/custom.as CustomPipelines) in the main, shadow, id and
// normal-depth passes, in the same loops as every other range, binding its
// module's groups 0, 1 and 3 made from the view's own buffers
// (`customView`) and its material group; one without (its module
// compiling, failed or with no source, or another shading) is drawn with
// its fallback, the MaterialDesc's own fields, exactly as a
// StandardMaterial3D of them, and counted (RenderStats.shaderFallbacks,
// shaderPending). Each view drawing a custom range writes its custom
// globals (TIME: RenderFrame.shaderTime, gpu/custom.as customGlobals) and
// each shadow tile's. Blended ranges are drawn in a stable order of their
// material's render_priority, lower first (Godot's), when a frame has one
// that is not 0 (`drawBlended`); otherwise in item order, as before. A
// next pass's item (DrawItem.nextPassOf, Godot's Material.next_pass: the
// scene adapter puts it after every other) is drawn in the main and shadow
// passes, its ranges without a next pass left out, and never in the id and
// normal-depth passes (the owner's outline and occlusion are its own). A
// frame without a ShaderMaterial, a next pass or a render priority asks
// for nothing, writes nothing more and draws what it drew before.
//
// Screen-space effects (milestone 62; ../screen.as, post.as's header,
// docs/engine/SCREEN_EFFECTS.md): a lit frame whose environment turns on
// the reflections (Godot's ssr_enabled) or the screen refraction (with a
// material that refracts), or whose camera blurs (Godot's
// CameraAttributesPractical), plans them (post.as planPostInto), and the
// view draws, in Godot's order:
//   - the normal-depth pass (the plan's `prepass`), now into two targets
//     whatever the frame plans (pipelines.as normalDepthTargets: the
//     second is the surface's F0 and roughness, layouts.as
//     SSR_SURFACE_FORMAT), every range with its own material; with the
//     refraction, the ranges that refract (rangeRefracts) left out;
//   - with the plan's `split`, the main pass in two halves on the same
//     MSAA targets: A (cleared, the sky, `drawSurfaces`'
//     PHASE_OPAQUE: the opaque and masked ranges but those that refract),
//     its colour resolved (and its samples discarded, B writing them again
//     from the screen texture: gpu/screen_chain.as `expand`; stored only
//     on a host that refuses the expand's pipeline) and its depth stored
//     when B draws a surface that tests it (lateTestsDepth); the
//     screen texture from A's resolve (gpu/screen_chain.as: a copy and its
//     mips, which every object group of the view binds at SCREEN_BINDING,
//     `ViewBuffers.screen`; a 1 x 1 dummy in every other view); the
//     reflections traced (gpu/ssr.as `trace`, from the normal-depth pass's
//     two targets and the screen texture: ScreenInputs); then B (its
//     samples written from the screen texture's level 0, or loaded; its
//     depth loaded, or cleared when nothing in it tests the depth: the
//     reflections laid over the colour, `merge`, then PHASE_LATE: the
//     ranges that refract, which read the screen texture behind the lit
//     block's ENV_SCREEN_REFRACTION, the blended ranges and the top pass),
//     resolved again; lines and points go to the overlay layer pass, as
//     with any final pass;
//   - the depth of field from the resolve (gpu/dof.as `draw`), whose
//     composition is what the glow and the final pass then read;
//   - the final pass (the tone map moves there, as with glow: the plan's
//     `toneInPost`).
// A host that refuses the screen texture draws the view in one pass with
// SCREEN_PIPELINE_WARNING (post.as dropSplit: no reflections, the glass
// refracting the environment); `splitScreen` false draws the same plan in
// one pass but for what reads the screen texture, for the tests that prove
// the halves draw the one pass's bytes. A frame that
// turns none of them on plans none of it, binds the dummy and draws what it
// drew before (the normal-depth pass's first target included).

// Rendering performance (milestone 67; docs/engine/PERFORMANCE.md, Godot's
// renderers): each view draws its main pass with the pipelines of its
// frame's quality (render/quality.as: Godot's msaa_3d and the Mobile
// renderer's 32-bit HDR target; `setFor`, one set by format and samples,
// Pipelines.retarget, made once and kept; a transparent view and a probe's
// capture keep rgba16float, the capture the renderer's own samples). In a
// material shading the opaque ranges are gathered into an order (gpu/
// order.as: Godot's sort_by_key, `rendering/shading/sort_opaque`) and, on
// an adapter Godot's disable_for_vendors does not name, drawn first into
// the main pass's depth by the depth prepass (gpu/prepass.as, `hedra
// prepass`), which the main pass loads; with both off the item loops draw
// as before. A frame whose live textures alone changed is drawn again
// keeping its culling, shadows, normal-depth pass and SSAO
// (renderFrameReusing; the normal-depth and SSAO targets are the slot's
// own, KeptTarget, so the post pool is taken as when they are drawn), and
// a picture presented again with nothing drawn since is drawn from the
// canvas with no pass (`present`). Defaults draw every picture of before
// but where two opaque surfaces tie and the sort reorders them.

import { SHADER_PENDING, ShaderModuleSource, installedShaderModules } from "../shader/modules";
import { SHADER_TIME_ROLLOVER, ShaderProgram } from "../shader/program";
import {
    CUSTOM_EXTRA_SLOT, CUSTOM_INSTANCED, CUSTOM_INSTANCED_UV1_SLOT, CUSTOM_INSTANCES_SLOT, CUSTOM_PASS_ID,
    CUSTOM_PASS_MAIN, CUSTOM_PASS_NORMAL_DEPTH, CUSTOM_PASS_SHADOW, CUSTOM_PIPELINE_WARNING, CUSTOM_PLAIN,
    CUSTOM_PLAIN_UV1_SLOT, CUSTOM_SKIN_SLOT, CUSTOM_SKINNED, CUSTOM_SKINNED_UV1_SLOT, CustomMaterialGroup,
    CustomPipelines, CustomShared, CustomViewGroups, customGlobalsInto, customTileGlobalsInto, sharesPipelines,
} from "./custom";
import { Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { BlendMode } from "rive/paint";
import { ImageFilter, ImageSampler, ImageWrap } from "rive/image";
import {
    GPUBindGroup, GPUBindGroupLayout, GPUBindGroupSampler, GPUBindGroupTexture, GPUBindGroupUBO, GPUBuffer,
    GPUColorAttachment,
    GPUPassDesc, GPUPipeline, GPURenderPass, GPUSampler, GPUShaderModule, GPUTexture, GPUTextureDesc, GPUTextureView,
    GPUTextureViewDesc,
} from "rive/gpu";
import { BufferUsage, IndexFormat, LoadOp, StoreOp, TextureAspect, TextureFormat } from "rive/gpu_enums";
import { abi } from "rive/bindings";
import { Result, clampF32 } from "../../base/util";
import { linearToSrgb as baseLinearToSrgb } from "../../base/color";
import { Mat4, Vec4 } from "../../base/vecmath";
import { LABEL_BG, LABEL_FG, labelScale, layout } from "../composite";
import { drawLabel } from "../font";
import { Image, Rgba, rgbaBytes, srgbToLinear } from "../image";
import {
    ALPHA_BLEND, ALPHA_MASK, MaterialBinder, MaterialDesc, TEX_BASE, TEX_COUNT, TEX_METALLIC_ROUGHNESS,
    VfsTextureFiles, extLayersInto, materialExtUniformInto, materialIsExt, materialRefracts, materialUniform,
    texKey, textureBitsOf,
} from "../material";
import { PBR_SLOT_COUNT } from "../../material/pbr";
import { GpuMesh, lodCount, lodFirst, lodRangeCount, lodRangeFirst } from "../mesh";
import { InstanceData } from "../instances";
import {
    DrawItem, LIGHTMAP_DRAW_BAKED, RenderFrame, SHADE_LIGHT_COUNT, SHADE_LIT, emerging, frameGlobalsInto,
    lightmapDrawKind, writeFrameObjects,
} from "../frame";
import { litUniformInto } from "../lit";
import { clearFrameFog, prepareFogVolumes } from "../fog_select";
import { assignItemLights, clearItemLights, planLightPool, planLightPoolAround } from "../light_select";
import {
    PostPlan, dropSplit, glowBlurUniformInto, glowBrightUniformInto, glowLevelSide, planPostInto,
    postFinalUniformInto, ssaoUniformInto,
} from "../post";
import { ShadowPlan, planShadowsInto, shadowAtlasSize as atlasSideFor } from "../shadow";
import {
    CULL_DRAWN, CullResult, RenderStats, castsRange, cullFrame, mainRangeDraws, rangeDrawn, shadowDrawsOf,
} from "../cull";
import { isTopItem } from "../top_pass";
import { IblCache, IblPlan, skyUniformInto } from "../sky";
import { ReflectionProbeDesc } from "../probe/data";
import { AdapterChoice, AdapterSummary, Gpu } from "./device";
import { RenderError } from "../errors";
import {
    AO_FORMAT, COLOR_FORMAT, COLOR_FORMAT_FALLBACK, DEPTH_FORMAT, GLOBALS_SIZE, GLOW_FORMAT, Globals, ID_FORMAT,
    LIT_UNIFORM_SIZE, LitUniform, MATERIAL_BASE_SIZE, MATERIAL_UNIFORM_SIZE, MSAA_SAMPLES, NORMAL_DEPTH_FORMAT, OBJECT_UNIFORM_SIZE,
    ObjectUniform, POST_OVERLAY, POST_UNIFORM_SIZE, PROBE_UNIFORM_SIZE, PostUniform, SHADOW_ATLAS_FORMAT, SHADOW_UNIFORM_SIZE, SKY_UNIFORM_SIZE,
    MaterialExtUniform, SkyUniform, U32x4, LineInstance, PointInstance, packLineInstances, packPointInstances,
    SKIN_BINDING, SKIN_UNIFORM_SIZE, writeSkinPalette, DECAL_ATLAS_BINDING, DECAL_BLOCK_BINDING, DECAL_SAMPLER_BINDING,
    DECAL_UNIFORM_SIZE, FOG_BLOCK_BINDING, FOG_UNIFORM_SIZE, SCREEN_BINDING, SSR_SURFACE_FORMAT, SHADOW_TILES,
} from "./layouts";
import { GpuDecals } from "./decals";
import { GpuFog } from "./fog";
import { GpuDof } from "./dof";
import { GpuSsr } from "./ssr";
import { ScreenInputs } from "./screen_inputs";
import { GpuScreenChain, SCREEN_PIPELINE_WARNING } from "./screen_chain";
import { GpuViewports } from "./viewports";
import { GpuEnvironment } from "./environment";
import { GpuMaterialBackend, levelBytes } from "./materials";
import { GpuMeshUploader, buffersOf, hasSkin, lightmapUvBuffer, skinBuffer, uv1Buffer } from "./mesh_cache";
import { GpuLightmap } from "./lightmap";
import { uploadRegion } from "./upload";
import { SurfaceVariants, variantKindOf } from "./variants";
import { FsrUpscaler } from "./fsr";
import { CASTER_MASKED, CASTER_PLAIN, CASTER_VOLATILE, ShadowTileCache, shadowClearPipeline, tileBits } from "./shadow_cache";
import { SurfaceVariantSource, installedSurfaceVariants } from "../shader/variants";
import { OpaqueOrder, ORDER_PINNED, keySeq } from "./order";
import { lateRange, prepassWanted, rangeInDepthPrepass } from "./prepass";
import { RENDERING_MOBILE, RenderQuality, SCALING_3D_BILINEAR } from "../quality";
import { PROBE_UPDATE_ALWAYS } from "../probe/data";
import {
    GpuProbes, PROBE_ACTION_CAPTURE, PROBE_ACTION_UPLOAD, PROBE_ATLAS_WARNING, PROBE_HALF_FLOAT_WARNING,
    leaveOutUncaptured,
} from "./probes";
import {
    GpuInstanceBuffer, takeInstanceBuffer, instanceBuffer, instanceExtraBuffer, takeInstanceExtraBuffer,
} from "./instances";
import {
    EXT_INSTANCED_UV1_SLOT, EXT_PIPELINE_WARNING, EXT_PLAIN_UV1_SLOT, ExtPipelineSet, ExtPipelines,
    INSTANCING_PIPELINE_WARNING, InstancedPipelines, LIGHTMAP_PIPELINE_WARNING, LM_UV1_SLOT, LM_UV_SLOT,
    LightmapPipelines, POST_FORMAT, POST_PIPELINE_WARNING, PROBE_PIPELINE_WARNING, Pipelines, PostPipelines,
    ProbePipelines, SHADOW_PIPELINE_WARNING, SKIN_PIPELINE_WARNING, SKIN_SLOT, ShadowPipelines,
    TOP_PIPELINE_WARNING, TopPipelines,
} from "./pipelines";

// The minimum uniform buffer offset alignment is not in GPUFeatures; 256 is
// the WebGPU default limit.
export const MIN_UNIFORM_OFFSET_ALIGNMENT: u32 = 256;

// Milestone 62: what the renderer's warnings say when the host refuses the
// screen texture (gpu/screen_chain.as): the view is drawn unsplit, without
// reflections, its glass refracting the environment.
export { SCREEN_PIPELINE_WARNING };

// Milestone 62: the phases of the main pass `drawSurfaces` draws (see
// FrameRenderer.drawSurfaces): the whole pass (every frame but a split
// one, a probe's capture), the first half of a split one (the opaque and
// masked ranges but those that refract), and its second half (those that
// refract, then the blended ones and the top pass).
// Milestone 67: what FrameRenderer.renderFrameReusing may keep of the
// last drawing of the same frame (none: renderFrame).
export const REUSE_NONE: i32 = 0;
export const REUSE_TEXTURES: i32 = 1;

export const PHASE_ALL: i32 = 0;
export const PHASE_OPAQUE: i32 = 1;
export const PHASE_LATE: i32 = 2;

// Milestone 62: whether range material `key` of frame `f` is drawn in the
// second half of the main pass of plan `plan`, sampling the screen texture
// (post.as PostPlan `refraction`): an opaque or masked material that
// refracts (material.as materialRefracts). A blended one that refracts is
// drawn with the blended ranges, which the second half draws anyway; every
// range of a frame without the refraction is drawn as before. Frame-pure
// (no GPU), for the tests.
export function rangeRefracts(f: RenderFrame, plan: PostPlan, key: i64): bool {
    if (!plan.refraction || key < 0 || key >= <i64>f.materials.length) return false;
    const m = unchecked(f.materials[<i32>key]);
    return materialRefracts(m) && m.alphaMode != ALPHA_BLEND;
}

// Milestone 62: whether the main pass's phase `phase` of plan `plan` draws
// range material `key` of frame `f` (FrameRenderer.drawSurfaces): every
// range in PHASE_ALL; in a split frame's halves, each range in one of them,
// PHASE_OPAQUE the opaque and masked ones but those that refract,
// PHASE_LATE those and the blended ones. Frame-pure, for the tests.
export function rangeInPhase(f: RenderFrame, plan: PostPlan, key: i64, phase: i32): bool {
    if (phase == PHASE_ALL) return true;
    const late = blends(f, key) || rangeRefracts(f, plan, key);
    return phase == PHASE_LATE ? late : !late;
}

// Milestone 62: whether the normal-depth pass of plan `plan` draws range
// material `key` of frame `f` (FrameRenderer.normalDepthPass): not a
// blended one, nor one that refracts. Frame-pure, for the tests.
export function rangeInPrepass(f: RenderFrame, plan: PostPlan, key: i64): bool {
    return !blends(f, key) && !rangeRefracts(f, plan, key);
}

// Milestone 62: whether the second half of a split main pass of plan
// `plan` draws a surface that tests the depth: a range the culling `main`
// leaves drawn that refracts or blends, or an item of the top pass (which
// draws over the depth it does not test, and leaves it as it found it, but
// is counted here so that a frame keeps what it drew before). A frame not
// in a material mode answers true (it is never split). Without one, the
// second half needs only its colour: the first half then stores no depth
// for it. Frame-pure, for the tests.
export function lateTestsDepth(f: RenderFrame, plan: PostPlan, main: Array<u8>): bool {
    if (!f.materialMode) return true;
    const items = f.items;
    for (let i = 0; i < items.length; i++) {
        if (i >= main.length || unchecked(main[i]) != CULL_DRAWN) continue;
        const d = unchecked(items[i]);
        const g = d.mesh;
        if (g == null) continue;
        if (isTopItem(d)) return true;
        for (let k = 0; k < g.ranges.length; k++) {
            if (!rangeDrawn(d, k)) continue;
            const key: i64 = k < d.materials.length ? unchecked(d.materials[k]) : -1;
            if (blends(f, key) || rangeRefracts(f, plan, key)) return true;
        }
    }
    return false;
}

// Milestone 67: whether a pass a picture drawn again keeps
// (FrameRenderer.renderFrameReusing) reads a live texture of material `m`
// (`live` its bindings' live textures, bit TEX_*; `ext` drawn by the
// extended pipelines; `normalDepth` the view draws the normal-depth pass):
// an alpha-masked material's cut-out (the shadow pass, the normal-depth
// pass), and in the normal-depth pass the F0 and roughness it writes for
// the reflections, which read the base colour on a metallic surface
// (mix(0.04, base, metallic) is 0.04 at metallic 0 whatever the base) and
// the metallic-roughness texture; an extended material's reads more, so
// any of its live textures counts. A blended range is in neither pass.
// Material-pure, for the tests.
export function liveReadByKeptPass(m: MaterialDesc, live: u32, ext: bool, normalDepth: bool): bool {
    if (live == 0) return false;
    if (m.alphaMode == ALPHA_MASK) return true;
    if (!normalDepth || m.alphaMode == ALPHA_BLEND) return false;
    if (ext || (live & (<u32>1 << <u32>TEX_METALLIC_ROUGHNESS)) != 0) return true;
    return (live & (<u32>1 << <u32>TEX_BASE)) != 0 && m.metallic != 0;
}

// Milestone 67: whether frame `f` has a reflection probe captured live
// every frame (ReflectionProbe update_mode always without a baked cube),
// which a picture drawn again (FrameRenderer.renderFrameReusing) could not
// keep. Frame-pure.
export function probesLive(f: RenderFrame): bool {
    const set = f.probes;
    if (set == null) return false;
    const list = set.list;
    for (let i = 0; i < list.length; i++) {
        const p = unchecked(list[i]);
        if (p.cube == null && p.updateMode == PROBE_UPDATE_ALWAYS) return true;
    }
    return false;
}

// A finished image on the GPU: rgba8unorm texels holding straight-alpha
// sRGB bytes, top row first (the layout of a CPU `Image`). Valid until
// the next `FrameRenderer.beginFrame`.
export class GpuImage {
    texture: GPUTexture;
    view: GPUTextureView;
    width: u32;
    height: u32;

    constructor(texture: GPUTexture, view: GPUTextureView, width: u32, height: u32) {
        this.texture = texture;
        this.view = view;
        this.width = width;
        this.height = height;
    }
}

// One `(String, Image)` tile of `FrameRenderer.sheet` (composite::SheetTile).
export class GpuSheetTile {
    label: string;
    image: GpuImage;

    constructor(label: string, image: GpuImage) {
        this.label = label;
        this.image = image;
    }
}

// The smallest power of two >= n (1 for 0).
export function nextPowerOfTwo(n: u32): u32 {
    if (n <= 1) return 1;
    return <u32>1 << (32 - <u32>clz<u32>(n - 1));
}

// The object uniform stride: `OBJECT_UNIFORM_SIZE` rounded up to the
// uniform offset alignment (at least 16).
export function computeObjectStride(align: u32): u32 {
    const a = max<u32>(align, 16);
    return (OBJECT_UNIFORM_SIZE + a - 1) / a * a;
}

// The object buffer capacity for `needed` uniforms: a power of two, at
// least 16.
export function objectCapacity(needed: u32): u32 {
    return max<u32>(nextPowerOfTwo(max<u32>(needed, 1)), 16);
}

// The bytes `upload_objects` writes: each uniform at `i * stride`, zeros
// between. (The renderer itself writes frame.as `writeFrameObjects` into a
// buffer it keeps; the frame test checks the two agree.)
export function packObjectUniforms(uniforms: Array<ObjectUniform>, stride: u32): ArrayBuffer {
    const needed = max<i32>(uniforms.length, 1);
    const bytes = new ArrayBuffer(<i32>stride * needed);
    const dv = new DataView(bytes, 0, bytes.byteLength);
    for (let i = 0; i < uniforms.length; i++) {
        uniforms[i].writeAt(dv, <u32>i * stride);
    }
    return bytes;
}

// sRGB encode of a linear value (the store of an Rgba8UnormSrgb target;
// the formula of `linear_to_srgb` in the shaders). Used for the clear color
// of the rgba8unorm fallback target.
export function linearToSrgb(c: f32): f32 {
    return baseLinearToSrgb(c);
}

// The frame's material `key` exists and alpha-blends.
function blends(f: RenderFrame, key: i64): bool {
    return key >= 0 && f.materials[<i32>key].alphaMode == ALPHA_BLEND;
}

// The frame's material `key` exists and is alpha-masked (a cut-out).
function masks(f: RenderFrame, key: i64): bool {
    return key >= 0 && f.materials[<i32>key].alphaMode == ALPHA_MASK;
}

// How the main pass draws an item of a frame with a bake (LIGHTMAP_DRAW_*,
// `lightmapDrawKind`) lives in frame.as, where the light selection reads
// it too (a lightmapped item draws no static light); the renderer's tests
// import it from here.
export { LIGHTMAP_DRAW_BAKED, LIGHTMAP_DRAW_PROBES, LIGHTMAP_DRAW_REALTIME, lightmapDrawKind } from "../frame";

// What the renderer says when it cannot make the atlas a plan asks for.
export const SHADOW_ATLAS_WARNING = "shadows are not drawn: the host rejected the shadow atlas";

// Milestone 59: each item of `f` its light list for the view `f` is drawn
// from (light_select.as assignItemLights, from the pool `f.lightPlan`
// holds) in the lit and lights shadings, which read it; in every other
// shading the lists are emptied, so the object blocks' bytes are zeros
// there as they were before lights per object. `bakedLight` false: the
// frame's lightmapped items are drawn in real-time light (the device does
// not hold the lightmap, or the host refused its pipelines), so the static
// lights reach them as any item. With `used` (cull.as
// CullResult.shaded), only the items the main pass shades are matched.
export function lightItems(f: RenderFrame, bakedLight: bool = true, used: Array<bool>? = null): void {
    if (f.shading == SHADE_LIT || f.shading == SHADE_LIGHT_COUNT) {
        assignItemLights(f, f.lightPlan, bakedLight, used);
        return;
    }
    const items = f.items;
    for (let i = 0; i < items.length; i++) clearItemLights(unchecked(items[i]));
}

// Milestone 61: RenderFrame.shaderTime as the custom globals hold it,
// wrapped at SHADER_TIME_ROLLOVER (a frame's producer wraps it already;
// this keeps a hand-made frame's in range too).
export function wrapShaderTime(t: f32): f32 {
    const r = <f32>SHADER_TIME_ROLLOVER;
    if (t >= 0 && t < r) return t;
    if (!isFinite(t)) return 0;
    const w = t - Mathf.floor(t / r) * r;
    return w >= 0 && w < r ? w : 0;
}

// Milestone 61: the main pass's blended ranges of `f` in the order
// FrameRenderer.drawBlended draws them: by their material's
// render_priority, lower first, ties in item then range order (a stable
// order: a frame whose priorities are all 0 is in item order, today's),
// into `items` and `ranges` (`keys` the priorities), of the items `main`
// draws (cull.as CULL_DRAWN), but those of the top pass (`top`: the frame
// has it) and a next pass's ranges without one. Allocates nothing once the
// lists have held as many ranges.
export function orderBlendedRanges(
    f: RenderFrame, main: Array<u8>, top: bool, items: Array<i32>, ranges: Array<i32>, keys: Array<i32>,
): void {
    items.length = 0;
    ranges.length = 0;
    keys.length = 0;
    const list = f.items;
    for (let i = 0; i < list.length; i++) {
        if (i >= main.length || unchecked(main[i]) != CULL_DRAWN) continue;
        const d = unchecked(list[i]);
        const g = d.mesh;
        if (g == null || (top && isTopItem(d))) continue;
        for (let k = 0; k < g.ranges.length; k++) {
            const key = k < d.materials.length ? unchecked(d.materials[k]) : -1;
            if (!blends(f, key) || !rangeDrawn(d, k)) continue;
            const pr = f.materials[<i32>key].renderPriority;
            // (inserted after every range of its priority or lower)
            let at = items.length;
            while (at > 0 && unchecked(keys[at - 1]) > pr) at--;
            items.push(0);
            ranges.push(0);
            keys.push(0);
            for (let j = items.length - 1; j > at; j--) {
                unchecked(items[j] = items[j - 1]);
                unchecked(ranges[j] = ranges[j - 1]);
                unchecked(keys[j] = keys[j - 1]);
            }
            unchecked(items[at] = i);
            unchecked(ranges[at] = k);
            unchecked(keys[at] = pr);
        }
    }
}

// Milestone 61: the main pass's ranges drawn with a ShaderMaterial, into
// `s` (RenderStats.shaderDraws: with its module, `custom[key]` set;
// .shaderFallbacks: with its fallback, of which .shaderPending while its
// module compiles, `pending[key]`), over the items `main` draws (but the
// top pass's, `top`, which draws every material with the surface
// pipelines, so their custom ranges are fallbacks) and their drawn ranges.
export function countCustomRanges(
    f: RenderFrame, main: Array<u8>, custom: Array<CustomPipelines?>, pending: Array<bool>, top: bool, s: RenderStats,
): void {
    s.shaderDraws = 0;
    s.shaderFallbacks = 0;
    s.shaderPending = 0;
    if (!f.materialMode || !f.drawSurfaces) return;
    const list = f.items;
    const mats = f.materials;
    for (let i = 0; i < list.length; i++) {
        if (i >= main.length || unchecked(main[i]) != CULL_DRAWN) continue;
        const d = unchecked(list[i]);
        const g = d.mesh;
        if (g == null) continue;
        const onTop = top && isTopItem(d);
        for (let k = 0; k < g.ranges.length; k++) {
            const key = k < d.materials.length ? unchecked(d.materials[k]) : -1;
            if (key < 0 || key >= <i64>mats.length || !rangeDrawn(d, k) || mats[<i32>key].custom == null) continue;
            const ready = !onTop && <i32>key < custom.length && unchecked(custom[<i32>key]) != null;
            if (ready) {
                s.shaderDraws++;
            } else {
                s.shaderFallbacks++;
                if (<i32>key < pending.length && unchecked(pending[<i32>key])) s.shaderPending++;
            }
        }
    }
}

// The view's Globals `g` with the shadow tile's view-projection, written
// into `out` (returned): what the shadow pass draws a tile with
// (vs_surface reads only view_proj).
export function tileGlobalsInto(g: Globals, viewProj: Mat4, out: Globals): Globals {
    out.copyFrom(g);
    out.viewProj = viewProj;
    return out;
}

// The `OutlineU` block of post_outline.wgsl (48 bytes). `straight` is set
// for a transparent background whose resolve the pass reads: it divides the
// premultiplied colour by alpha.
export function outlineUniform(
    want: bool, r: u32, encode: bool, select: Rgba, active: Rgba, straight: bool = false,
): ArrayBuffer {
    const buf = new ArrayBuffer(48);
    writeOutlineUniform(new DataView(buf, 0, 48), want, r, encode, select, active, straight);
    return buf;
}

// `outlineUniform` written at the start of `dv` (no allocation).
export function writeOutlineUniform(
    dv: DataView, want: bool, r: u32, encode: bool, select: Rgba, active: Rgba, straight: bool = false,
): void {
    dv.setUint32(0, want ? 1 : 0, true);
    dv.setUint32(4, r, true);
    dv.setUint32(8, encode ? 1 : 0, true);
    dv.setUint32(12, straight ? 1 : 0, true);
    for (let k = 0; k < 4; k++) {
        dv.setFloat32(16 + k * 4, <f32>select.get(k) / <f32>255.0, true);
        dv.setFloat32(32 + k * 4, <f32>active.get(k) / <f32>255.0, true);
    }
}

// The `ComposeU` block of post_compose.wgsl (32 bytes). `premultiply` is set
// only by `present` (the host draws canvas images as premultiplied alpha);
// `weighted` by a transparent frame's downsample (colour averaged by alpha,
// so straight-alpha edges keep their colour).
export function composeUniform(
    x: i32, y: i32, w: u32, h: u32, factor: u32, hasOverlay: bool, premultiply: bool = false, weighted: bool = false,
): ArrayBuffer {
    const buf = new ArrayBuffer(32);
    writeComposeUniform(new DataView(buf, 0, 32), x, y, w, h, factor, hasOverlay, premultiply, weighted);
    return buf;
}

// `composeUniform` written at the start of `dv` (no allocation).
export function writeComposeUniform(
    dv: DataView, x: i32, y: i32, w: u32, h: u32, factor: u32, hasOverlay: bool, premultiply: bool,
    weighted: bool = false,
): void {
    dv.setInt32(0, x, true);
    dv.setInt32(4, y, true);
    dv.setInt32(8, <i32>w, true);
    dv.setInt32(12, <i32>h, true);
    dv.setUint32(16, max<u32>(factor, 1), true);
    dv.setUint32(20, hasOverlay ? 1 : 0, true);
    dv.setUint32(24, premultiply ? 1 : 0, true);
    dv.setUint32(28, weighted ? 1 : 0, true);
}

// The transparent overlay images of the last few sizes drawn, reused (and
// cleared) instead of allocated for every view: the stub runtime
// (rive.yaml) never frees, and a 1920 x 1080 overlay is 8 MB, which a
// viewport re-planning on every camera move would otherwise add each time.
// A texture upload copies the bytes, so one image serves every overlay of a
// frame in turn. Only the last OVERLAY_SIZES sizes are kept (a window being
// resized goes through many).
const OVERLAY_SIZES = 4;
let overlayImages: Array<Image> = [];

export function overlayImage(width: u32, height: u32): Image {
    const cache = overlayImages;
    for (let i = 0; i < cache.length; i++) {
        const img = cache[i];
        if (img.width == width && img.height == height) {
            img.data.fill(0);
            if (i != cache.length - 1) {
                // most recently used last
                cache.splice(i, 1);
                cache.push(img);
            }
            return img;
        }
    }
    const img = Image.new(width, height, Rgba(0, 0, 0, 0));
    if (cache.length >= OVERLAY_SIZES) cache.shift();
    cache.push(img);
    return img;
}

// A texture holding `img`'s bytes (rgba8unorm, one level). When the image
// owns its whole buffer (it always does, from `Image.new`) the buffer is
// uploaded as is, with no copy.
export function uploadRgba8(img: Image): GPUTexture {
    const d = new GPUTextureDesc();
    d.width = img.width;
    d.height = img.height;
    d.format = TextureFormat.rgba8unorm;
    d.numMipmaps = 1;
    d.sampleCount = 1;
    d.renderTarget = false;
    const t = new GPUTexture(d);
    writeRgba8(t, img);
    return t;
}

// `img`'s texels written into `t`, a texture of its size (uploadRgba8's, or
// one kept to be written again: FrameRenderer.keptOverlay), through the
// renderer's one upload region (gpu/upload.as).
function writeRgba8(t: GPUTexture, img: Image): void {
    const region = uploadRegion(img.width, img.height, 0, 0);
    const d8 = img.data;
    if (d8.byteOffset == 0 && d8.buffer.byteLength == <i32>(img.width * img.height * 4)) {
        t.upload(region, d8.buffer);
    } else {
        t.upload(region, levelBytes(img, false));
    }
}

// A depth32float texture `size` texels square that a pass draws into and a
// shader samples: the shadow atlas, or the 1 x 1 dummy map.
function depthTexture(size: u32): GPUTexture {
    const d = new GPUTextureDesc();
    d.width = size;
    d.height = size;
    d.format = SHADOW_ATLAS_FORMAT;
    d.sampleCount = 1;
    d.renderTarget = true;
    d.numMipmaps = 1;
    return new GPUTexture(d);
}

// The view a `texture_depth_2d` binding samples: the depth aspect only (an
// identity on depth32float, and the shape the runtime's own shadow-sampler
// tests use).
function sampledDepthView(t: GPUTexture): GPUTextureView {
    const d = new GPUTextureViewDesc();
    d.aspect = TextureAspect.depthOnly;
    return t.view(d);
}

// Clear a rect of `img` to transparent (clipped), where a sheet tile's blit
// replaced whatever earlier tiles had drawn.
export function clearRect(img: Image, x: i32, y: i32, w: i32, h: i32): void {
    const x0 = max<i32>(x, 0);
    const y0 = max<i32>(y, 0);
    const x1 = min<i32>(x + w, <i32>img.width);
    const y1 = min<i32>(y + h, <i32>img.height);
    for (let yy = y0; yy < y1; yy++) {
        for (let xx = x0; xx < x1; xx++) {
            img.put(xx, yy, Rgba(0, 0, 0, 0));
        }
    }
}

// What composite.as `sheet` draws over tile i after its blit: the separators
// on its left and top edges (not on the sheet border) and its label.
export function sheetDecorations(img: Image, x: i32, y: i32, tw: u32, th: u32, label: string): void {
    const sep = Rgba(90, 90, 90, 255);
    if (x > 0) {
        img.fillRect(x, y, 1, <i32>th, sep);
    }
    if (y > 0) {
        img.fillRect(x, y, <i32>tw, 1, sep);
    }
    const s = labelScale(th);
    drawLabel(img, x + 6 * <i32>s, y + 6 * <i32>s, label, s, LABEL_FG, LABEL_BG);
}

// ---------------------------------------------------------------- host calls

// GPURenderPass.setBindGroup packs its dynamic offsets into a new
// ArrayBuffer on every call, and its default `[]` is a new array on every
// call: a frame sets thousands of groups, and the stub runtime never frees.
// These go to the host binding directly, the one offset through a word
// kept for the renderer's life.
const offsetWord = new ArrayBuffer(4);

// `pass.setBindGroup(index, g)`, allocating nothing.
function bindGroup(pass: GPURenderPass, index: u32, g: GPUBindGroup): void {
    abi.rive_gpu_pass_set_bind_group(pass.handle, index, g.handle, 0, 0);
}

// `pass.setBindGroup(index, g, [offset])`, allocating nothing.
function bindGroupAt(pass: GPURenderPass, index: u32, g: GPUBindGroup, offset: u32): void {
    storeOffset(offset);
    abi.rive_gpu_pass_set_bind_group(pass.handle, index, g.handle, offsetAddress(), 4);
}

unsafe function offsetAddress(): usize {
    return changetype<usize>(offsetWord);
}

unsafe function storeOffset(offset: u32): void {
    store<u32>(changetype<usize>(offsetWord), offset);
}

// ---------------------------------------------------------------- per view

// One render target a view keeps from frame to frame (FrameRenderer
// `slotTarget`).
export class PooledTarget {
    texture: GPUTexture;
    view: GPUTextureView;
    width: u32;
    height: u32;
    format: TextureFormat;
    samples: u32;

    constructor(texture: GPUTexture, view: GPUTextureView, width: u32, height: u32, format: TextureFormat, samples: u32) {
        this.texture = texture;
        this.view = view;
        this.width = width;
        this.height = height;
        this.format = format;
        this.samples = samples;
    }
}

// Milestone 67: one render target a view keeps by name rather than by its
// place among the targets it asks for (FrameRenderer `keptTarget`): the
// normal-depth pass's three and SSAO's two (ViewBuffers.nd*, ao*), so that
// a picture drawn again without those passes (renderFrameReusing) finds
// them as the last drawing left them and takes the same post targets after.
export class KeptTarget {
    target: PooledTarget? = null;
}

// Milestone 67 (quality.as): the sets of pipelines a renderer and its
// siblings draw their main passes with, one by colour format and MSAA
// samples (Pipelines.retarget of the first set, the renderer's
// `pipelines`), made on the first frame that asks for one and kept, and
// the (samples | format << 8) the host refused (never asked again).
export class PipelineSets {
    list: Array<Pipelines> = [];
    refused: Array<u32> = [];
}

// One post draw of a view (FrameRenderer `postGroup`): its PostU block,
// written every frame, and its group, kept while it binds the same views.
class PostDraw {
    buffer: GPUBuffer;
    group: GPUBindGroup? = null;
    src: GPUTextureView? = null;
    aux: GPUTextureView? = null;
    glow: GPUTextureView? = null;

    constructor(buffer: GPUBuffer) {
        this.buffer = buffer;
    }
}

// Globals and object uniforms of one view, with a bind group per shader
// module (pipelines.as). The surface module's group 0 also holds the lit
// block (binding 1, surface.wgsl's LitU), the shadow bindings (2 the
// ShadowU block, 3 the shadow map, 4 its comparison sampler), the sky
// block (5), the ambient occlusion (6: the 1 x 1 dummy in every cached
// group; a frame with SSAO binds `aoGroup`) and the probe block (7), which
// the lines module does not declare; its group 3 (`envBg`) the radiance
// cube, the panorama and their samplers (0 to 3), the lightmap's layers and
// sampler (4, 5) and the probes' atlas and sampler (6, 7). Milestone 13:
// everything else a view draws with is kept here too, from frame to frame
// (see the header).
export class ViewBuffers {
    globals: GPUBuffer;
    lit: GPUBuffer;
    shadow: GPUBuffer;
    sky: GPUBuffer;
    // Milestone 20: the probe block (binding 7), zeros until a frame with
    // probes writes it, and whether it holds anything but zeros now.
    probe: GPUBuffer;
    probeWritten: bool = false;
    // Milestone 33: the decal block (the object group's binding 2), zeros
    // until a frame with decals writes it, and whether it holds anything
    // but zeros now.
    decal: GPUBuffer;
    decalWritten: bool = false;
    // Milestone 37: the fog block (the object group's binding 5), zeros
    // until a view with fog writes it, and whether its counts are anything
    // but zeros now.
    fog: GPUBuffer;
    fogWritten: bool = false;
    // The GpuDecals.generation the object groups (`objectsBg` and the skin
    // slots') were made with: their atlas (bindings 3 and 4) changes with
    // it, and they are made again (FrameRenderer.uploadObjects).
    decalGeneration: u32 = 0;
    // Milestone 62: the screen texture the object groups bind at
    // SCREEN_BINDING (the slot's GpuScreenChain view in a split frame, else
    // the renderer's 1 x 1 dummy), and the one `objectsBg` was made with
    // (FrameRenderer.uploadObjects makes it again when they differ).
    screen: GPUTextureView;
    objectsScreen: GPUTextureView? = null;
    // The GpuEnvironment.generation this slot's environment group was made
    // with: when the environment's maps change, the group holding the old
    // views is remade (FrameRenderer.refreshGroups).
    envGeneration: u32;
    // Milestone 34: the environment that group binds (the renderer's, or a
    // viewport's own: FrameRenderer.refreshGroups remakes the group for
    // another), and, for a viewport's slot, its own post targets
    // (FrameRenderer.postChain), kept apart from the main views' pool.
    env: GpuEnvironment;
    ownPosts: bool = false;
    posts: Array<PostTarget> = [];
    // The GpuLightmap.generation likewise (milestone 19: its layers at
    // group 3, binding 4).
    lmGeneration: u32;
    // The GpuProbes.generation likewise (milestone 20: the atlas at
    // group 3, binding 6).
    probeGeneration: u32;
    // Group 0 with the dummy shadow map: every frame without shadows, the
    // id pass, and the sky.
    globalsBg: GPUBindGroup;
    // Group 3, the environment group (`envGroup`): the environment's maps,
    // the lightmap's layers and the probes' atlas, with their samplers;
    // bound with every group 0 of the surface module, remade when one of
    // them changes (`FrameRenderer.refreshGroups`).
    envBg: GPUBindGroup;
    lineGlobalsBg: GPUBindGroup;
    // Group 0 with the atlas (`atlasView`), for the main pass of a frame
    // with shadows; made on the first such frame of this slot, remade when
    // the atlas is.
    globalsShadowBg: GPUBindGroup? = null;
    atlasView: GPUTextureView? = null;
    // Group 0 of the main pass of a frame with SSAO: the shadow map
    // `aoMap` and the blurred occlusion `aoView`, of environment
    // `aoGeneration`; remade when one of them changes.
    aoGroup: GPUBindGroup? = null;
    aoMap: GPUTextureView? = null;
    aoView: GPUTextureView? = null;
    // Per shadow tile drawn by this slot: a Globals buffer (the view's with
    // the tile's view-projection) and its group 0 (with the dummy map: a
    // pass must not sample the texture it draws into). Grown on demand,
    // kept with the slot.
    tileGlobals: Array<GPUBuffer> = [];
    tileGroups: Array<GPUBindGroup> = [];
    // The object uniforms (null until uploaded), their bind groups and
    // capacity.
    objects: GPUBuffer? = null;
    objectsBg: GPUBindGroup? = null;
    lineObjectsBg: GPUBindGroup? = null;
    cap: u32 = 0;
    // Milestone 48: the skinned items' palettes (`FrameRenderer.uploadSkins`):
    // one per skinned item drawn, the n-th skinned item of a frame in the
    // n-th, kept from frame to frame; and by item slot, the one that item
    // draws with (null: not skinned).
    skins: Array<SkinSlot> = [];
    skinBySlot: Array<SkinSlot?> = [];
    // The render targets (`FrameRenderer.slotTarget`), in the order the
    // view asks for them, and how many the view being drawn has taken.
    targets: Array<PooledTarget> = [];
    targetCursor: i32 = 0;
    // The post draws (`FrameRenderer.postGroup`), and how many the view
    // being drawn has made.
    postDraws: Array<PostDraw> = [];
    postDrawCursor: i32 = 0;
    // The outline pass's block (written every frame) and its group, kept
    // while it reads the same two views.
    outline: GPUBuffer;
    outlineBg: GPUBindGroup? = null;
    outlineSrc: GPUTextureView? = null;
    outlineIds: GPUTextureView? = null;
    // The compose pass's likewise (its source and overlay).
    compose: GPUBuffer;
    composeBg: GPUBindGroup? = null;
    composeSrc: GPUTextureView? = null;
    composeOverlay: GPUTextureView? = null;
    // The view's picture and the answer `renderFrame` returns, reused.
    image: GpuImage? = null;
    result: Result<GpuImage>? = null;
    // The frame's world lines, top lines and top points (milestone 13),
    // written into the same buffers every frame (`FrameRenderer.keptLines`).
    worldLines: KeptVertices = new KeptVertices();
    // The frame's overlay image, kept (`FrameRenderer.keptOverlay`).
    overlay: GpuImage? = null;
    topLines: KeptVertices = new KeptVertices();
    topPoints: KeptVertices = new KeptVertices();
    // Each item's own lines and points (an empty's axes, a camera's
    // frustum; milestone 24), kept the same way: the n-th item that has
    // lines this frame writes into the n-th kept buffer, and the draw
    // records that name them are kept too. A model editor's frame of a
    // model with an empty and a camera made both anew every frame, about
    // 1 KB of an orbit's frame.
    itemLines: Array<KeptVertices> = [];
    itemPoints: Array<KeptVertices> = [];
    itemLineDraws: Array<InstanceBuffer> = [];
    itemPointDraws: Array<InstanceBuffer> = [];
    // Milestone 61 (gpu/custom.as): the slot's identity among a renderer's
    // (CustomViewGroups.view), and the custom globals of its view and of
    // each of its shadow tiles, made the first time the slot draws a
    // custom range and written every frame it draws one.
    customId: i32 = 0;
    customGlobals: GPUBuffer? = null;
    customTiles: Array<GPUBuffer> = [];
    // Milestone 67: the normal-depth pass's two colour targets and its
    // depth, and SSAO's raw and blurred occlusion (see KeptTarget).
    ndNormal: KeptTarget = new KeptTarget();
    ndSurface: KeptTarget = new KeptTarget();
    ndDepth: KeptTarget = new KeptTarget();
    aoRaw: KeptTarget = new KeptTarget();
    aoBlur: KeptTarget = new KeptTarget();

    constructor(
        p: Pipelines, dummyDepth: GPUTextureView, compare: GPUSampler, env: GpuEnvironment, lm: GpuLightmap,
        dummyAo: GPUTextureView, probes: GpuProbes, screen: GPUTextureView,
    ) {
        this.screen = screen;
        this.globals = new GPUBuffer(BufferUsage.uniform, GLOBALS_SIZE);
        this.lit = new GPUBuffer(BufferUsage.uniform, LIT_UNIFORM_SIZE);
        // Zeros until a frame with shadows writes it: no light is marked
        // shadowed then, so the shader never reads it.
        this.shadow = new GPUBuffer(
            BufferUsage.uniform, SHADOW_UNIFORM_SIZE, new ArrayBuffer(<i32>SHADOW_UNIFORM_SIZE));
        // Zeros (flags 0) until a frame writes it.
        this.sky = new GPUBuffer(BufferUsage.uniform, SKY_UNIFORM_SIZE, new ArrayBuffer(<i32>SKY_UNIFORM_SIZE));
        // Zeros (count 0) until a frame with probes writes it.
        this.probe = new GPUBuffer(BufferUsage.uniform, PROBE_UNIFORM_SIZE, new ArrayBuffer(<i32>PROBE_UNIFORM_SIZE));
        // Zeros (count 0) until a frame with decals writes it.
        this.decal = new GPUBuffer(BufferUsage.uniform, DECAL_UNIFORM_SIZE, new ArrayBuffer(<i32>DECAL_UNIFORM_SIZE));
        // Zeros (counts 0) until a view with fog writes it.
        this.fog = new GPUBuffer(BufferUsage.uniform, FOG_UNIFORM_SIZE, new ArrayBuffer(<i32>FOG_UNIFORM_SIZE));
        this.outline = new GPUBuffer(BufferUsage.uniform, OUTLINE_UNIFORM_SIZE);
        this.compose = new GPUBuffer(BufferUsage.uniform, COMPOSE_UNIFORM_SIZE);
        this.envGeneration = env.generation;
        this.env = env;
        this.lmGeneration = lm.generation;
        this.probeGeneration = probes.generation;
        this.globalsBg = globalsGroup(
            p, this.globals, this.lit, this.shadow, this.sky, this.probe, dummyDepth, compare, dummyAo);
        this.envBg = envGroup(p, env, lm, probes);
        this.lineGlobalsBg = new GPUBindGroup(p.lineGlobalsLayout, [new GPUBindGroupUBO(0, this.globals)]);
    }
}

// A vertex buffer a view writes one kind of overlay geometry into every
// frame (milestone 13): packed into the same bytes and written into the
// same device buffer while it holds them, so a frame with the same lines
// as the last (the editor's grid, every frame of an orbit) allocates
// nothing for them. The stub allocator never frees, and the editor's grid
// packed into a new buffer was about 73 KB a frame.
export class KeptVertices {
    bytes: ArrayBuffer? = null;
    buffer: GPUBuffer? = null;
}

// The outline and compose blocks' sizes (post_outline.wgsl's OutlineU,
// post_compose.wgsl's ComposeU).
const OUTLINE_UNIFORM_SIZE: u32 = 48;
const COMPOSE_UNIFORM_SIZE: u32 = 32;

// Group 0 of the surface module (slots 0 to 7): Globals, the lit, shadow
// and sky blocks, a shadow map and the comparison sampler, an ambient
// occlusion texture (the dummy but in the main pass of a frame with SSAO)
// and the probe block.
function globalsGroup(
    p: Pipelines, globals: GPUBuffer, lit: GPUBuffer, shadow: GPUBuffer, sky: GPUBuffer, probe: GPUBuffer,
    map: GPUTextureView, compare: GPUSampler, ao: GPUTextureView,
): GPUBindGroup {
    return globalsGroupWith(p.globalsLayout, globals, lit, shadow, sky, probe, map, compare, ao);
}

// `globalsGroup` for `layout` (milestone 61: a custom shader module's
// group 0, gpu/custom.as).
function globalsGroupWith(
    layout: GPUBindGroupLayout, globals: GPUBuffer, lit: GPUBuffer, shadow: GPUBuffer, sky: GPUBuffer,
    probe: GPUBuffer, map: GPUTextureView, compare: GPUSampler, ao: GPUTextureView,
): GPUBindGroup {
    return new GPUBindGroup(
        layout,
        [
            new GPUBindGroupUBO(0, globals), new GPUBindGroupUBO(1, lit), new GPUBindGroupUBO(2, shadow),
            new GPUBindGroupUBO(5, sky), new GPUBindGroupUBO(7, probe),
        ],
        [new GPUBindGroupTexture(3, map), new GPUBindGroupTexture(6, ao)],
        [new GPUBindGroupSampler(4, compare)],
    );
}

// Group 3 of the surface module, the environment group (slots 0 to 7): the
// environment's radiance cube and panorama and their samplers, the
// lightmap's layers and sampler (the dummy until a frame brings a
// lightmap), and the probes' atlas and its sampler (the dummy until a frame
// brings probes).
function envGroup(p: Pipelines, env: GpuEnvironment, lm: GpuLightmap, probes: GpuProbes): GPUBindGroup {
    return envGroupWith(p.envLayout, env, lm, probes);
}

// `envGroup` for `layout` (milestone 61: a custom shader module's group 3).
function envGroupWith(layout: GPUBindGroupLayout, env: GpuEnvironment, lm: GpuLightmap, probes: GpuProbes): GPUBindGroup {
    return new GPUBindGroup(
        layout,
        [],
        [
            new GPUBindGroupTexture(0, env.radianceView), new GPUBindGroupTexture(1, env.panoramaView),
            new GPUBindGroupTexture(4, lm.view), new GPUBindGroupTexture(6, probes.view),
        ],
        [
            new GPUBindGroupSampler(2, env.radianceSampler), new GPUBindGroupSampler(3, env.panoramaSampler),
            new GPUBindGroupSampler(5, lm.sampler), new GPUBindGroupSampler(7, probes.sampler),
        ],
    );
}

// Milestone 48: one skinned item's palette in a view (ViewBuffers.skins):
// its uniform buffer, the object group binding it beside the view's object
// block (made again when that buffer is replaced), and what the buffer holds
// (the palette array, its version and joint count), so it is written only
// when they change.
export class SkinSlot {
    buffer: GPUBuffer;
    group: GPUBindGroup? = null;
    objects: GPUBuffer? = null;
    data: Float32Array? = null;
    version: u32 = 0;
    count: i32 = 0;
    // The item's skin vertex buffer this frame.
    vertices: GPUBuffer? = null;
    // Milestone 33: the GpuDecals.generation `group` was made with.
    decalGeneration: u32 = 0;
    // Milestone 62: the screen texture `group` binds (ViewBuffers.screen).
    screen: GPUTextureView? = null;
    // Milestone 61: its index among its view's (ViewBuffers.skins), which
    // a custom module's object groups are kept by (CustomViewGroups.skins).
    index: i32 = 0;

    constructor(buffer: GPUBuffer) {
        this.buffer = buffer;
    }
}

// Pipeline and group bookkeeping inside the main and id passes: groups 0
// and 2 are rebound whenever the pipeline changes (each module has its own
// group layouts), group 1 before every draw. The renderer keeps one and
// `reset`s it for each pass.
export class PassState {
    pass: GPURenderPass;
    vb: ViewBuffers;
    stride: u32;
    material: GPUBindGroup;
    surfaceModule: bool = true;
    // The surface module's group 0: the view's `globalsBg`, or its
    // `globalsShadowBg` in the main pass of a frame with shadows.
    globals: GPUBindGroup;
    // The pipeline bound last (null before the first).
    current: GPUPipeline? = null;
    // Milestone 48: the item being drawn (`item`), when it is skinned: its
    // palette slot and object slot; and whether the pipeline bound is the
    // skinned counterpart of the one asked for (`useSurface`), so that its
    // object group and skin buffer are bound with it (`object`). `refused`
    // is set when a skinned item had to be drawn with a plain pipeline.
    skin: SkinSlot? = null;
    skinItem: u32 = 0;
    skinning: bool = false;
    refused: bool = false;
    pipelines: Pipelines? = null;

    constructor(pass: GPURenderPass, vb: ViewBuffers, stride: u32, material: GPUBindGroup) {
        this.pass = pass;
        this.vb = vb;
        this.stride = stride;
        this.material = material;
        this.globals = vb.globalsBg;
    }

    // Milestone 48: starts the draws of item `d` (every item loop calls it
    // first): skinned when the view gave its slot a palette.
    item(d: DrawItem): void {
        const by = this.vb.skinBySlot;
        const slot = d.slot;
        this.skin = <i32>slot < by.length ? unchecked(by[<i32>slot]) : null;
        this.skinItem = slot;
    }

    // The state of a new pass, as the constructor makes it.
    reset(pass: GPURenderPass, vb: ViewBuffers, stride: u32, material: GPUBindGroup): void {
        this.pass = pass;
        this.vb = vb;
        this.stride = stride;
        this.material = material;
        this.surfaceModule = true;
        this.globals = vb.globalsBg;
        this.current = null;
        this.skin = null;
        this.skinItem = 0;
        this.skinning = false;
    }

    surfacePipeline(p: GPUPipeline): void {
        this.pass.setPipeline(p);
        this.current = p;
        this.surfaceModule = true;
        this.skinning = false;
        bindGroup(this.pass, 0, this.globals);
        bindGroup(this.pass, 2, this.material);
        bindGroup(this.pass, 3, this.vb.envBg);
    }

    // `surfacePipeline(p)` unless `p` is the pipeline bound (an instanced
    // item switches to its instanced pipeline and the next plain item
    // back; a frame without one never switches). For a skinned item
    // (milestone 48) `p`'s skinned counterpart, when the host made it.
    useSurface(p: GPUPipeline): void {
        const s = this.skin;
        const pl = this.pipelines;
        if (s != null && pl != null) {
            const sp = pl.skinnedOf(p);
            if (sp != null) {
                if (this.current !== sp) this.surfacePipeline(sp);
                this.skinning = true;
                return;
            }
            this.refused = true;
        }
        if (this.current !== p) this.surfacePipeline(p);
        this.skinning = false;
    }

    // Whether `useSurface(p)` would leave the pass as it is: the pipeline
    // it binds for the item being drawn (`p`'s skinned counterpart for a
    // skinned item, `p` for any other) is bound, skinning as the item
    // does. A loop that keeps the bound pipeline from one item to the next
    // (the main pass's opaque ranges in their order) asks this rather than
    // comparing `current` with `p`: a skinned item after a plain one of the
    // same material finds `p` itself bound, and drawn with it would be its
    // bind pose at the frame's origin (its world is the identity).
    surfaceBound(p: GPUPipeline): bool {
        const s = this.skin;
        const pl = this.pipelines;
        if (s != null && pl != null) {
            const sp = pl.skinnedOf(p);
            // (a refused counterpart: bound through useSurface, which says so)
            return sp != null && this.current === sp && this.skinning;
        }
        return this.current === p && !this.skinning;
    }

    // Milestone 67: `p`, a surface variant's pipeline already of the draw's
    // vertex kind (gpu/variants.as: a skinned draw's is its skinned one, so
    // no counterpart is looked up), bound as `surfacePipeline` binds; the
    // skinned item's own group and skin buffer with it when `skinned`.
    useVariant(p: GPUPipeline, skinned: bool): void {
        if (this.current !== p) this.surfacePipeline(p);
        this.skinning = skinned;
    }

    linePipeline(p: GPUPipeline): void {
        this.pass.setPipeline(p);
        this.current = p;
        this.surfaceModule = false;
        bindGroup(this.pass, 0, this.vb.lineGlobalsBg);
    }

    // `set_bind_group(1, obj_buf_bg, &[index * stride])`. A skinned item's
    // own group under a skinned pipeline (milestone 48), with its skin
    // buffer.
    object(index: u32): void {
        const s = this.skin;
        if (this.surfaceModule && this.skinning && s != null && index == this.skinItem) {
            const g = s.group;
            const v = s.vertices;
            if (g != null && v != null) {
                bindGroupAt(this.pass, 1, g, index * this.stride);
                this.pass.setVertexBuffer(SKIN_SLOT, v);
                return;
            }
        }
        const bg = this.surfaceModule ? this.vb.objectsBg : this.vb.lineObjectsBg;
        if (bg == null) return;
        bindGroupAt(this.pass, 1, bg, index * this.stride);
    }

    // Whether UV set 1 of the draw being made goes after a second buffer
    // (an instanced draw's instances, a skinned one's skin: SKIN_UV1_SLOT,
    // EXT_INSTANCED_UV1_SLOT) rather than after the vertices.
    uv1After(instanced: bool): bool {
        return instanced || this.skinning;
    }

    // `set_bind_group(2, bg, &[])`.
    setMaterial(bg: GPUBindGroup): void {
        this.material = bg;
        bindGroup(this.pass, 2, bg);
    }
}

// One kept post-processing target (FrameRenderer `postTarget`).
// A glow chain has one mip per level; `levels` holds a view of each mip
// alone (the target its level is drawn into and the source of the next;
// `view` itself when there is one mip), and `view` spans them all (what
// fs_post samples).
class PostTarget {
    texture: GPUTexture;
    view: GPUTextureView;
    width: u32;
    height: u32;
    format: TextureFormat;
    mips: u32;
    levels: Array<GPUTextureView>;

    constructor(
        texture: GPUTexture, view: GPUTextureView, width: u32, height: u32, format: TextureFormat, mips: u32,
        levels: Array<GPUTextureView>,
    ) {
        this.texture = texture;
        this.view = view;
        this.width = width;
        this.height = height;
        this.format = format;
        this.mips = mips;
        this.levels = levels;
    }
}

// Transient instances: uniform slot, instance buffer, count, on top.
export class InstanceBuffer {
    index: u32;
    buffer: GPUBuffer;
    count: u32;
    onTop: bool;

    constructor(index: u32, buffer: GPUBuffer, count: u32, onTop: bool) {
        this.index = index;
        this.buffer = buffer;
        this.count = count;
        this.onTop = onTop;
    }
}

// The n-th of `kept`'s draw records, set to (index, buffer, count, onTop):
// made the first time a view has that many, then reused.
function keptDraw(kept: Array<InstanceBuffer>, n: i32, index: u32, buffer: GPUBuffer, count: u32,
    onTop: bool): InstanceBuffer {
    if (n == kept.length) {
        kept.push(new InstanceBuffer(index, buffer, count, onTop));
        return kept[n];
    }
    const d = kept[n];
    d.index = index;
    d.buffer = buffer;
    d.count = count;
    d.onTop = onTop;
    return d;
}

// A picture `present` put on the canvas, and the compose group that does
// it (FrameRenderer `presentGroup`): kept while the same image is presented.
class PresentEntry {
    view: GPUTextureView;
    width: u32;
    height: u32;
    buffer: GPUBuffer;
    group: GPUBindGroup;

    constructor(view: GPUTextureView, width: u32, height: u32, buffer: GPUBuffer, group: GPUBindGroup) {
        this.view = view;
        this.width = width;
        this.height = height;
        this.buffer = buffer;
        this.group = group;
    }
}

// How many presented pictures keep their groups (a viewport presents one
// image, a sheet a new one every frame).
const PRESENT_KEPT = 4;

// The draws an item makes in the main pass (cull.as `countDrawn`'s rule).
function mainDraws(f: RenderFrame, d: DrawItem): i32 {
    return mainRangeDraws(f, d);
}

// The draws an item makes in one shadow tile (cull.as's and `shadowPass`'s
// rule: in the material mode, every range that does not blend).
function shadowDraws(f: RenderFrame, d: DrawItem): i32 {
    return shadowDrawsOf(f, d);
}

// The renderer's device state: device, pipelines, mesh uploader,
// materials, per-view uniform buffers, warnings. The meshes a frame draws
// are the program's (it caches them and hands retired ones to `retire`).
export class FrameRenderer {
    gpu: Gpu;
    pipelines: Pipelines;
    uploader: GpuMeshUploader = new GpuMeshUploader();
    objectStride: u32;
    materials: MaterialBinder<GPUTextureView, GPUBindGroup>;
    // Raised by `renderFrame` (texture problems); drained by `takeWarnings`.
    warnings: Array<string> = [];
    // The image-based light of the last sky drawn (sky.as), and its maps on
    // the GPU (see the header).
    ibl: IblCache = new IblCache();
    environment: GpuEnvironment;
    // Milestone 19: the frame's lightmap on the GPU (see the header).
    lightmap: GpuLightmap;
    // Milestone 20: the frame's reflection probes on the GPU (see the
    // header).
    probes: GpuProbes;
    // Milestone 33: the decals' atlas and block (gpu/decals.as).
    decals: GpuDecals;
    // Milestone 37: the fog block's bytes (gpu/fog.as).
    fog: GpuFog = new GpuFog();
    // Milestone 34: the viewports' targets and schedule (gpu/viewports.as).
    viewports: GpuViewports;
    // Milestone 62: the screen-space reflections' and the depth of field's
    // passes (gpu/ssr.as, gpu/dof.as), and what a view hands them (filled
    // in place for each view: gpu/screen_inputs.as).
    ssr: GpuSsr = new GpuSsr();
    dof: GpuDof = new GpuDof();
    screenInputs: ScreenInputs = new ScreenInputs();
    // Milestone 62: the screen texture of each view slot (gpu/screen_chain.as);
    // `splitScreen` false draws a view whose plan splits its main pass in
    // one, its plan otherwise the same (the tone map in the final pass, the
    // normal-depth pass), but nothing drawn that reads the screen texture
    // (no reflections, no screen refraction), for the tests that prove the
    // two halves draw the one pass's bytes.
    screenChain: GpuScreenChain = new GpuScreenChain();
    splitScreen: bool = true;
    // Milestone 13: false culls nothing by frustum (cullFrame's `frustum`
    // false: every item is drawn into the main pass and every shadow tile;
    // visibility ranges still apply). Pictures are the
    // same either way; the CLI's `render` turns it off with HEDRA_NO_CULL=1,
    // for the test that proves it.
    cullingEnabled: bool = true;
    // What cull.as decided for the frame being drawn (kept, so culling
    // allocates nothing from frame to frame), and the statistics of the
    // last frame drawn (SceneRenderer.stats; Hedra's preview window
    // showed them in its statistics line until milestone 23 retired it).
    private cull: CullResult = new CullResult();
    lastStats: RenderStats = new RenderStats();
    // The surface draw calls the last frame's main pass and shadow pass
    // made, and those `lastStats` counts that could not be made (an item
    // without buffers, an instanced one without its pipelines):
    // `drawCountError`.
    madeDraws: i32 = 0;
    madeShadowDraws: i32 = 0;
    private missedDraws: i32 = 0;
    private missedShadowDraws: i32 = 0;
    // Milestone 67 (gpu/shadow_cache.as, docs/engine/PERFORMANCE.md
    // "Shadows kept"): false draws every shadow tile every frame, as before
    // (the pictures are the same either way; for the A/B and the tests).
    // The caches, by RenderFrame (the least recently used one is taken for
    // a new frame), the cache whose drawing each tile of the atlas holds
    // (null: none's), the tile clear's pipeline (made on the first pass that
    // keeps a tile; null when refused), and a serial of the passes.
    shadowCaching: bool = true;
    private shadowCaches: Array<ShadowTileCache> = [];
    private atlasOwner: Array<ShadowTileCache?> = [];
    private clearTile: GPUPipeline? = null;
    private clearTileTried: bool = false;
    private shadowSerial: i64 = 0;
    // Moves whenever a material group is made or remade or the materials'
    // values are written again (bindMaterials): what a masked caster's
    // shadow reads (gpu/shadow_cache.as CASTER_MASKED).
    materialEpoch: i32 = 0;
    // Per-view uniform buffers (see the header), and what the views of
    // the current frame created, released at the next `beginFrame`.
    private slots: Array<ViewBuffers> = [];
    private slot: i32 = 0;
    // Milestone 20: the uniform slots of the live captures' views, six a
    // probe captured in this host frame, and how many it has taken (kept
    // apart from `slots`, whose targets keep the main views' sizes).
    private captureSlots: Array<ViewBuffers> = [];
    private captureSlot: i32 = 0;
    // Milestone 34: the viewports' views' slots, one per index of the
    // frame's viewports (see the header), their shadow plan, and the zero
    // probe block a view without probes writes.
    private viewportSlots: Array<ViewBuffers> = [];
    private viewportShadowPlan: ShadowPlan = new ShadowPlan();
    private zeroProbe: ArrayBuffer = new ArrayBuffer(<i32>PROBE_UNIFORM_SIZE);
    private frameTextures: Array<GPUTexture> = [];
    // The views of those textures: a view holds its texture, so an
    // unreleased one would keep the target's GPU memory alive for good.
    private frameViews: Array<GPUTextureView> = [];
    private frameBuffers: Array<GPUBuffer> = [];
    private frameGroups: Array<GPUBindGroup> = [];
    // The post-processing targets kept between frames (`postTarget`), and
    // how many the view being drawn has taken.
    private postPool: Array<PostTarget> = [];
    private postCursor: i32 = 0;
    // The pool the view being drawn takes them from: `postPool`, or a
    // viewport's slot's own (ViewBuffers.posts).
    private activePosts: Array<PostTarget> = [];
    // The block each post draw fills (post.as `*Into`) and `postGroup`
    // writes out at once, so a frame with post-processing allocates none.
    private postU: PostUniform = new PostUniform();
    // 1x1 transparent texture bound where a post pass has no input.
    private dummy: GpuImage;
    // 1x1 depth map bound where no shadow atlas may be (see the header),
    // its sampled view, and whether the empty pass that clears it has run
    // (a pass may only begin inside the host's `draw`, so the first frame
    // does it).
    private dummyDepth: GPUTexture;
    private dummyDepthTarget: GPUTextureView;
    private dummyDepthView: GPUTextureView;
    private dummyDepthCleared: bool = false;
    // The atlas's side on this device (shadow.as `shadowAtlasSize`; 0: the
    // device draws no shadow).
    shadowAtlasSize: u32;
    // The shadow atlas, made on the first frame that plans a tile and kept
    // (64 MiB at 4096 x 4096): the texture, the view the shadow pass draws
    // into, and the depth-only view the lit shader samples.
    private atlas: GPUTexture? = null;
    private atlasTarget: GPUTextureView? = null;
    private atlasSampled: GPUTextureView? = null;
    // The device side of `materials` when it is a GpuMaterialBackend: the
    // material groups a frame made are released at the next `beginFrame`,
    // but those `bindMaterials` keeps.
    private materialBackend: GpuMaterialBackend?;
    // The material groups of `boundMaterials` (a frame's materials array,
    // by identity, with its base directory), by material index, and the
    // warnings binding them raised; the groups and their uniform buffers
    // are released when the frame's materials change (`bindMaterials`).
    private boundMaterials: Array<MaterialDesc>? = null;
    private boundBaseDir: string = "";
    // The materials' liveGeneration the groups were made at (see there).
    private boundLive: i32 = -1;
    // The materials' valuesGeneration the uniforms were written at, and by
    // material index the uniform buffer of its group (null until bound, or
    // when the backend is not the GPU's).
    private boundValues: i32 = -1;
    private boundBuffers: Array<GPUBuffer?> = [];
    private boundGroups: Array<GPUBindGroup?> = [];
    private boundWarnings: Array<string> = [];
    private ownedGroups: Array<GPUBindGroup> = [];
    private ownedBuffers: Array<GPUBuffer> = [];
    // Milestone 14, part 2: by material index of `boundMaterials`, whether
    // it is drawn by the extended pipelines (material.as materialIsExt),
    // and those pipelines for the frame being drawn (null when it has no
    // such material, or the host rejected them).
    private boundExt: Array<bool> = [];
    private frameExt: ExtPipelines? = null;
    // The top pipelines when the frame draws an item without the depth
    // test (`topping`), else null; and whether TOP_PIPELINE_WARNING was
    // said (it is said once, not every frame).
    private frameTop: TopPipelines? = null;
    private topWarned: bool = false;
    // Milestone 19: the lightmap pipelines when the frame draws a
    // lightmapped item with them (`lightmapping`), else null.
    private frameLightmap: LightmapPipelines? = null;
    // The plans the frame's blocks are made from, filled in place.
    private shadowPlan: ShadowPlan = new ShadowPlan();
    private postPlan: PostPlan = new PostPlan();
    private litBlock: LitUniform = new LitUniform();
    private skyBlock: SkyUniform = new SkyUniform();
    // The view's Globals, a shadow tile's, and the object uniform every
    // slot of a frame is written through (layouts.as says why they are
    // classes), filled in place.
    private globalsBlock: Globals = new Globals();
    private tileBlock: Globals = new Globals();
    private objectBlock: ObjectUniform = new ObjectUniform();
    // Milestone 61: a view's custom globals and a shadow tile's
    // (gpu/custom.as customGlobalsInto), filled in place the same way.
    private customBlock: Globals = new Globals();
    private customTileBlock: Globals = new Globals();
    // Bytes the uniform blocks are written into before each upload (an
    // upload copies them), and the views that write them: as many as the
    // largest block written through them, the lit one (milestone 59: 5,328
    // bytes, of which a view uploads the header and its pool's lights).
    private blockBytes: ArrayBuffer = new ArrayBuffer(<i32>max<u32>(LIT_UNIFORM_SIZE, SHADOW_UNIFORM_SIZE));
    private blockView: DataView;
    // The extended material block and its texture layers, filled in place
    // when a kept group's uniform is written again (rewriteMaterials).
    private extBlock: MaterialExtUniform = new MaterialExtUniform();
    private extLayerScratch: StaticArray<i32> = new StaticArray<i32>(PBR_SLOT_COUNT);
    private objectBytes: ArrayBuffer = new ArrayBuffer(0);
    private objectView: DataView;
    // The sky block of a frame that is not lit (a SkyUniform as made: flags
    // 0, so the shader reads nothing of it).
    private idleSky: ArrayBuffer;
    // The overlay's line and point buffers of the view being drawn.
    private lineBufs: Array<InstanceBuffer> = [];
    private pointBufs: Array<InstanceBuffer> = [];
    // The one pass state, pass wrapper, pass descriptors and colour
    // attachments every view draws with (passes are recorded one at a
    // time).
    private ps: PassState? = null;
    // Milestone 61: where the modules of the frame's custom shaders come
    // from (render/shader/modules.as): the run time sets its Rive
    // project's (AssetShaderModules); null asks installedShaderModules(),
    // the tools' shader service once their program installed it.
    shaderModules: ShaderModuleSource? = null;
    // Milestone 67: the surface shader's variants (gpu/variants.as: their
    // keys' pipelines and the last view's counts), where their modules
    // come from (the frame's source, else the installed one:
    // ../shader/variants.as), and FSR 1.0's upscale (gpu/fsr.as).
    variants: SurfaceVariants = new SurfaceVariants();
    // Milestone 67: the artboard textures the views drawn since the last
    // beginFrame showed (an OR of their drawn items' DrawItem.artboards),
    // which an ArtboardTexture's when_visible reads
    // (../../scene/player/artboards.as).
    artboardsDrawn: u32 = 0;
    surfaceVariants: SurfaceVariantSource? = null;
    fsr: FsrUpscaler = new FsrUpscaler();
    private upImage: GpuImage? = null;
    private upResult: Result<GpuImage>? = null;
    // Milestone 67 (quality.as, docs/engine/PERFORMANCE.md): the pipeline
    // sets by colour format and samples (shared with the siblings), the set
    // the view being drawn uses (`pipelines` itself unless the frame's
    // quality asks for another MSAA count or the Mobile target), and the
    // set the surface variants' pipelines were made for (`variants` is
    // released when the main view's set changes).
    private sets: PipelineSets = new PipelineSets();
    private active: Pipelines;
    private variantsSet: Pipelines? = null;
    // Milestone 67 (order.as, prepass.as): the view's opaque ranges in their
    // order, whether drawSurfaces draws them from it (`ordered`), and by
    // place in the order whether the depth prepass drew a range, with the
    // ubershader (1) or its variant (2), 0 not.
    private order: OpaqueOrder = new OpaqueOrder();
    private ordered: bool = false;
    private prepassed: Array<u8> = [];
    private prepassable: i32 = 0;
    // Milestone 67 (renderFrameReusing): what the last full drawing of a
    // main view left that a picture drawn again may keep, and whether it
    // may: the frame, the count of views drawn (`viewSerial`, every view,
    // capture face and viewport included) after it, its slot, its size, its
    // globals' bytes and quality, the shadow plan it was drawn with and the
    // shadow draws it made, and whether anything it drew reads a live
    // texture where a kept pass would have to read it again (`reuseBlocked`).
    private viewSerial: u32 = 0;
    private reuseFrame: RenderFrame? = null;
    private reuseSerial: u32 = 0;
    private reuseSlot: i32 = -1;
    private reuseWidth: u32 = 0;
    private reuseHeight: u32 = 0;
    private reuseSsaa: u32 = 0;
    private reuseGlobals: ArrayBuffer = new ArrayBuffer(<i32>GLOBALS_SIZE);
    private reuseGlobalsView: DataView;
    private reuseScratch: ArrayBuffer = new ArrayBuffer(<i32>GLOBALS_SIZE);
    private reuseScratchView: DataView;
    private reuseGlobalsBlock: Globals = new Globals();
    private reuseQuality: RenderQuality = new RenderQuality();
    private reusePlan: ShadowPlan? = null;
    private reuseShadowDraws: i32 = 0;
    private reuseMissedShadowDraws: i32 = 0;
    private reuseBlocked: bool = true;
    // Whether the view being drawn keeps its culling, shadows, normal-depth
    // pass and SSAO (drawView's `reuse`), and how many pictures were drawn
    // so since the renderer was made (tests and the statistics).
    private reusing: bool = false;
    reusedFrames: i32 = 0;
    // Milestone 67: by material index of `boundMaterials`, which of the
    // five bindings' textures (bit TEX_*) are live views (the binder's
    // `live`: an artboard texture, a viewport's picture), worked out when
    // the groups are made (renderFrameReusing reads them).
    private boundLiveMask: Array<u32> = [];
    // Milestone 61 (gpu/custom.as, see the header): what every custom
    // module shares, the modules' pipelines and groups, the frame serial
    // they are kept by, and by material index of the frame being drawn the
    // module's (null: drawn with its fallback), its material group, and
    // whether its module is being compiled; whether the view draws a
    // custom range, whether a material has a render priority, and the
    // blended ranges' order (`drawBlended`).
    private customShared: CustomShared = new CustomShared();
    private customs: Array<CustomPipelines> = [];
    private frameSerial: u32 = 1;
    private customOf: Array<CustomPipelines?> = [];
    private customGroupOf: Array<CustomMaterialGroup?> = [];
    private customPendingOf: Array<bool> = [];
    private frameCustom: bool = false;
    private framePriority: bool = false;
    private customWarned: bool = false;
    private nextSlotId: i32 = 1;
    // The views of the main pass's shadow map and occlusion (its custom
    // group 0 binds them), and of each shadow tile being drawn.
    private customMap: GPUTextureView? = null;
    private customAo: GPUTextureView? = null;
    private blendItems: Array<i32> = [];
    private blendRanges: Array<i32> = [];
    private blendKeys: Array<i32> = [];
    private customRetired: Array<GPUBindGroup> = [];
    private customRetiredBuffers: Array<GPUBuffer> = [];
    // How many draws the last view made with custom pipelines in its main
    // pass (tests; RenderStats.shaderDraws is the main view's).
    customDraws: i32 = 0;
    private passWrapper: GPURenderPass = new GPURenderPass(0);
    private shadowDesc: GPUPassDesc = new GPUPassDesc();
    private mainColor: GPUColorAttachment = new GPUColorAttachment();
    private mainDesc: GPUPassDesc = new GPUPassDesc();
    private overlayColor: GPUColorAttachment = new GPUColorAttachment();
    private overlayDesc: GPUPassDesc = new GPUPassDesc();
    private idColor: GPUColorAttachment = new GPUColorAttachment();
    private idDesc: GPUPassDesc = new GPUPassDesc();
    private ndColor: GPUColorAttachment = new GPUColorAttachment();
    private ndSurface: GPUColorAttachment = new GPUColorAttachment();
    private ndDesc: GPUPassDesc = new GPUPassDesc();
    // Milestone 62: the main pass's second half (its own kept descriptor
    // and attachment), the normal-depth pass's two views of the view being
    // drawn (null without the plan's prepass), its plan (what drawSurfaces
    // splits the ranges by), and how many ranges the second half drew that
    // refract.
    private mainColorB: GPUColorAttachment = new GPUColorAttachment();
    // Milestone 67: the depth prepass's descriptor (depth alone).
    private prepassDesc: GPUPassDesc = new GPUPassDesc();
    private mainDescB: GPUPassDesc = new GPUPassDesc();
    private ndView: GPUTextureView? = null;
    private ndSurfaceView: GPUTextureView? = null;
    private framePost: PostPlan = new PostPlan();
    private refractionDrawCount: i32 = 0;
    private postColor: GPUColorAttachment = new GPUColorAttachment();
    private postDesc: GPUPassDesc = new GPUPassDesc();
    // The groups `present` draws the last few pictures with.
    private presented: Array<PresentEntry> = [];
    // Milestone 67: the picture `present` put on the canvas last, at the
    // count of views drawn then (`viewSerial`), and how many presents found
    // it there (tests).
    private presentedView: GPUTextureView? = null;
    private presentedWidth: u32 = 0;
    private presentedHeight: u32 = 0;
    private presentedSerial: u32 = 0;
    presentsKept: i32 = 0;
    // Milestone 48: the palette every object group but a skinned item's
    // binds (zeros; nothing reads it), the bytes a palette is written into
    // before its upload, whether SKIN_PIPELINE_WARNING was said, and how
    // many palettes were uploaded (tests see an unmoving skeleton upload
    // none).
    private dummySkin: GPUBuffer;
    private skinBytes: ArrayBuffer = new ArrayBuffer(<i32>SKIN_UNIFORM_SIZE);
    private skinView: DataView;
    private skinWarned: bool = false;
    private shadowSkinRefused: bool = false;
    skinUploads: i32 = 0;

    constructor(
        gpu: Gpu, pipelines: Pipelines, materials: MaterialBinder<GPUTextureView, GPUBindGroup>,
        materialBackend: GpuMaterialBackend? = null,
    ) {
        this.gpu = gpu;
        this.pipelines = pipelines;
        this.active = pipelines;
        this.materials = materials;
        this.materialBackend = materialBackend;
        this.objectStride = computeObjectStride(MIN_UNIFORM_OFFSET_ALIGNMENT);
        const t = uploadRgba8(Image.new(1, 1, Rgba(0, 0, 0, 0)));
        this.dummy = new GpuImage(t, t.view(), 1, 1);
        this.dummyDepth = depthTexture(1);
        this.dummyDepthTarget = this.dummyDepth.view();
        this.dummyDepthView = sampledDepthView(this.dummyDepth);
        // (Imported under another name: the field shadows the function.)
        this.shadowAtlasSize = atlasSideFor(gpu.maxTextureSize());
        this.environment = new GpuEnvironment();
        this.lightmap = new GpuLightmap();
        this.probes = new GpuProbes();
        this.decals = new GpuDecals();
        this.viewports = new GpuViewports();
        this.activePosts = this.postPool;
        this.blockView = new DataView(this.blockBytes, 0, this.blockBytes.byteLength);
        this.reuseGlobalsView = new DataView(this.reuseGlobals, 0, this.reuseGlobals.byteLength);
        this.reuseScratchView = new DataView(this.reuseScratch, 0, this.reuseScratch.byteLength);
        this.objectView = new DataView(this.objectBytes, 0, 0);
        this.dummySkin = new GPUBuffer(BufferUsage.uniform, SKIN_UNIFORM_SIZE, new ArrayBuffer(<i32>SKIN_UNIFORM_SIZE));
        this.skinView = new DataView(this.skinBytes, 0, this.skinBytes.byteLength);
        this.idleSky = new SkyUniform().toBytes();
        this.shadowDesc.color = [];
        this.prepassDesc.color = [];
        this.mainDesc.color = [this.mainColor];
        this.overlayDesc.color = [this.overlayColor];
        this.idDesc.color = [this.idColor];
        this.ndDesc.color = [this.ndColor, this.ndSurface];
        this.mainDescB.color = [this.mainColorB];
        this.postDesc.color = [this.postColor];
    }

    // The device and pipelines for `choice`. `forceFallbackTarget` (for tests)
    // renders into the rgba8unorm fallback target even when the device has
    // half-float render targets.
    static create(ctx: Context, choice: AdapterChoice, forceFallbackTarget: bool = false): Result<FrameRenderer> {
        const g = Gpu.create(ctx, choice);
        if (!g.ok) return g.forward<FrameRenderer>();
        const gpu = g.value;
        const f = gpu.features;
        const colorFormat = f.colorBufferHalfFloat && !forceFallbackTarget ? COLOR_FORMAT : COLOR_FORMAT_FALLBACK;
        const samples = min<u32>(MSAA_SAMPLES, max<u32>(f.maxSamples, 1));
        const p = Pipelines.create(ctx, colorFormat, samples);
        if (!p.ok) return p.forward<FrameRenderer>();
        const pipelines = p.value;
        const backend = new GpuMaterialBackend(pipelines.materialLayout);
        const materials = new MaterialBinder<GPUTextureView, GPUBindGroup>(backend, new VfsTextureFiles());
        // The default material's group lives as long as the renderer.
        backend.keepCreated();
        return Result.okv<FrameRenderer>(new FrameRenderer(gpu, pipelines, materials, backend));
    }

    // Milestone 14: a renderer on the same device, with the same pipelines,
    // and a GPU canvas, material binder and per-frame state of its own
    // (SceneRenderer's material preview). Each renderer's `beginFrame`
    // releases only what that renderer made, and each presents on its own
    // canvas, so the two may both draw in one host draw, in either order,
    // and each `redraw` its own last picture. Textures are uploaded once per
    // renderer (a viewport's few), unless its binder is given a
    // TextureShare (material.as: the run time's, milestone 39);
    // the 1x1 fallbacks and dummies are its own. Call outside or inside the host's draw: making a canvas records
    // no pass.
    sibling(): Result<FrameRenderer> {
        const g = this.gpu;
        const canvas = g.ctx.gpuCanvas(1, 1);
        if (canvas == null) {
            return RenderError.device(g.info.name + " (" + g.info.backend + "): no second GPU canvas").fail<FrameRenderer>();
        }
        const gpu = new Gpu(g.ctx, canvas, g.features, g.info);
        const backend = new GpuMaterialBackend(this.pipelines.materialLayout);
        const materials = new MaterialBinder<GPUTextureView, GPUBindGroup>(backend, new VfsTextureFiles());
        backend.keepCreated();
        const f = new FrameRenderer(gpu, this.pipelines, materials, backend);
        f.cullingEnabled = this.cullingEnabled;
        // (milestone 67: the other formats' and sample counts' pipelines too)
        f.sets = this.sets;
        return Result.okv<FrameRenderer>(f);
    }

    adapter(): AdapterSummary {
        return this.gpu.info;
    }

    // The main target holds HDR colour (rgba16float), so post-processing
    // can be drawn (post.as `planPost`); false on the rgba8unorm fallback.
    halfFloat(): bool {
        return this.pipelines.colorFormat == COLOR_FORMAT;
    }

    // Milestone 67 (quality.as, docs/engine/PERFORMANCE.md "Targets and
    // formats"): the pipeline set a view of `f` draws its main pass with:
    // f.renderQuality's MSAA samples (Godot's msaa_3d), clamped to the
    // device's, into rgba16float, or with the Mobile rendering method into
    // r11g11b10float (32 bits a sample: no alpha, 6 and 5 bits of mantissa),
    // where the device renders and blends it and the view has no
    // transparency to keep (a transparent or translucent background keeps
    // rgba16float). `pipelines` itself for the defaults (4 x, rgba16float:
    // every picture of before) and on the rgba8unorm fallback target, which
    // keeps its own format. Another set is made once (Pipelines.retarget)
    // and kept; one the host refuses falls back to rgba16float at those
    // samples, then to `pipelines`. Allocates nothing for a set made.
    private setFor(f: RenderFrame): Pipelines {
        const base = this.pipelines;
        const q = f.renderQuality;
        const feats = this.gpu.features;
        const most = feats.known ? max<u32>(feats.maxSamples, 1) : base.samples;
        const samples = min<u32>(q.samples(), most);
        let format = base.colorFormat;
        if (format == COLOR_FORMAT && q.renderingMethod == RENDERING_MOBILE && !this.keepsAlpha(f)
            && this.compactRenders()) format = TextureFormat.r11g11b10float;
        if (format == base.colorFormat && samples == base.samples) return base;
        const made = this.setOf(format, samples);
        if (made != null) return made;
        if (format != base.colorFormat) {
            if (samples == base.samples) return base;
            const half = this.setOf(base.colorFormat, samples);
            if (half != null) return half;
        }
        return base;
    }

    // The set of `format` and `samples` (made on first use; null when the
    // host refused it).
    private setOf(format: TextureFormat, samples: u32): Pipelines? {
        const sets = this.sets;
        const list = sets.list;
        for (let i = 0; i < list.length; i++) {
            const p = unchecked(list[i]);
            if (p.colorFormat == format && p.samples == samples) return p;
        }
        const key = samples | (<u32>format << 8);
        if (sets.refused.includes(key)) return null;
        const p = this.pipelines.retarget(format, samples);
        if (p == null) {
            sets.refused.push(key);
            return null;
        }
        list.push(p);
        return p;
    }

    // Whether a view of `f` keeps its alpha (a transparent background, a
    // translucent one: its picture's alpha is what it shows through).
    private keepsAlpha(f: RenderFrame): bool {
        if (f.transparent || f.background.w < 1) return true;
        const env = f.environment;
        return env.hasPostBackground && env.postBackground.w < 1;
    }

    // Whether the device renders into r11g11b10float and blends it: WebGL 2
    // only with EXT_color_buffer_float (GPUFeatures.colorBufferFloat);
    // Metal, Vulkan, Direct3D and WebGPU always (the host refusing the
    // pipelines all the same falls back: setFor).
    private compactRenders(): bool {
        return this.gpu.info.backend != "gl" || this.gpu.features.colorBufferFloat;
    }

    // The pipelines the view being drawn uses (setFor), for the tests.
    activePipelines(): Pipelines {
        return this.active;
    }

    // Warnings raised by `renderFrame` since the last call (missing or
    // unsupported textures), deduplicated in order of first occurrence.
    takeWarnings(): Array<string> {
        const out = new Array<string>();
        const ws = this.warnings;
        this.warnings = [];
        for (let i = 0; i < ws.length; i++) {
            if (!out.includes(ws[i])) out.push(ws[i]);
        }
        return out;
    }

    // Drops the warnings raised since the last call, allocating nothing (a
    // caller that reports none: SceneRenderer.present).
    clearWarnings(): void {
        this.warnings.length = 0;
    }

    // "" when the last frame's main and shadow passes made the draw calls
    // `lastStats` counts (those it could not make included: see
    // `madeDraws`), else what differs. A check on the renderer itself:
    // Hedra's `present` fails with it.
    drawCountError(): string {
        const s = this.lastStats;
        if (this.madeDraws + this.missedDraws == s.draws
            && this.madeShadowDraws + this.missedShadowDraws == s.shadowDraws) return "";
        return "the renderer made " + this.madeDraws.toString() + " draws (" + this.missedDraws.toString()
            + " not drawable) and " + this.madeShadowDraws.toString() + " shadow draws ("
            + this.missedShadowDraws.toString() + " not drawable) where culling counted " + s.draws.toString()
            + " and " + s.shadowDraws.toString();
    }

    // Call at the start of every host `draw` that renders: recycles the
    // per-view uniform buffers and releases what the previous frame made and
    // dropped (targets, transient buffers, material groups, mesh buffers the
    // cache replaced). Images from
    // earlier frames are invalid afterwards.
    beginFrame(): void {
        this.slot = 0;
        this.captureSlot = 0;
        this.artboardsDrawn = 0;
        this.probes.beginFrame();
        this.decals.beginFrame();
        this.viewports.beginFrame();
        this.ssr.beginFrame();
        this.dof.beginFrame();
        this.screenChain.beginFrame();
        const mb = this.materialBackend;
        if (mb != null) mb.releaseCreated();
        for (let i = 0; i < this.frameGroups.length; i++) this.frameGroups[i].release();
        for (let i = 0; i < this.frameViews.length; i++) this.frameViews[i].release();
        for (let i = 0; i < this.frameTextures.length; i++) this.frameTextures[i].release();
        for (let i = 0; i < this.frameBuffers.length; i++) this.frameBuffers[i].release();
        // (emptied in place: the lists keep their storage from frame to frame)
        this.frameGroups.length = 0;
        this.frameViews.length = 0;
        this.frameTextures.length = 0;
        this.frameBuffers.length = 0;
        this.environment.releaseRetired();
        this.lightmap.releaseRetired();
        this.sweepCustom();
    }

    // Milestone 61 (gpu/custom.as): the next frame's serial; the custom
    // modules no frame drew since the one before released with their
    // groups, and the material groups no frame bound since then (a frame
    // replanned with new MaterialDescs, a shader edited on disk). Nothing
    // for a renderer that never drew a custom range.
    private sweepCustom(): void {
        const serial = this.frameSerial;
        this.frameSerial = serial + 1;
        const retired = this.customRetired;
        const buffers = this.customRetiredBuffers;
        for (let i = 0; i < retired.length; i++) retired[i].release();
        for (let i = 0; i < buffers.length; i++) buffers[i].release();
        retired.length = 0;
        buffers.length = 0;
        const cs = this.customs;
        for (let i = cs.length - 1; i >= 0; i--) {
            const c = unchecked(cs[i]);
            if (c.usedFrame >= serial) {
                c.sweep(serial, retired, buffers);
                continue;
            }
            c.release(retired, buffers);
            cs.splice(i, 1);
        }
    }

    // A view of one of this frame's textures, released with it at the next
    // `beginFrame`.
    private viewOf(t: GPUTexture): GPUTextureView {
        const v = t.view();
        this.frameViews.push(v);
        return v;
    }

    private nextSlot(): ViewBuffers {
        if (this.slot >= this.slots.length) {
            this.slots.push(this.newSlot());
        }
        const vb = this.slots[this.slot];
        this.slot++;
        this.refreshGroups(vb, this.environment);
        vb.targetCursor = 0;
        vb.postDrawCursor = 0;
        return vb;
    }

    // A new uniform slot (a view's, or a capture view's).
    private newSlot(): ViewBuffers {
        const vb = new ViewBuffers(
            this.pipelines, this.dummyDepthView, this.pipelines.compareSampler(), this.environment, this.lightmap,
            this.dummy.view, this.probes, this.dummy.view);
        vb.customId = this.nextSlotId++;
        return vb;
    }

    // The next capture view's slot (see the header), its groups current.
    private nextCaptureSlot(): ViewBuffers {
        if (this.captureSlot >= this.captureSlots.length) this.captureSlots.push(this.newSlot());
        const vb = this.captureSlots[this.captureSlot];
        this.captureSlot++;
        this.refreshGroups(vb, this.environment);
        return vb;
    }

    // Milestone 34: the slot of viewport `k`'s view (see the header), made
    // the first time a frame has that many, its cursors reset as
    // `nextSlot`'s; its environment group is made current by `drawView`.
    private nextViewportSlot(k: i32): ViewBuffers {
        while (this.viewportSlots.length <= k) {
            const vb = this.newSlot();
            vb.ownPosts = true;
            this.viewportSlots.push(vb);
        }
        const vb = this.viewportSlots[k];
        vb.targetCursor = 0;
        vb.postDrawCursor = 0;
        return vb;
    }

    // The slot's environment group (group 3) holds the environment's views,
    // the lightmap's and the probes' atlas: when those changed (a new sky's
    // maps, a new bake, the atlas made), remake it. The old group is
    // released at the next `beginFrame`, once the views of earlier frames
    // that bound it are recorded. Group 0 holds none of them. `env` is the
    // environment the view is lit by (the renderer's, or a viewport's own:
    // milestone 34).
    private refreshGroups(vb: ViewBuffers, env: GpuEnvironment): void {
        const lm = this.lightmap;
        const pr = this.probes;
        if (vb.env === env && vb.envGeneration == env.generation && vb.lmGeneration == lm.generation
            && vb.probeGeneration == pr.generation) return;
        vb.env = env;
        vb.envGeneration = env.generation;
        vb.lmGeneration = lm.generation;
        vb.probeGeneration = pr.generation;
        this.frameGroups.push(vb.envBg);
        vb.envBg = envGroup(this.pipelines, env, lm, pr);
    }

    // Milestone 59: the lit block of `f` (lit.as litUniformInto, from the
    // pool `f.lightPlan` holds and the slots of `shadows`, null: none)
    // into the kept bytes, and uploads its header and the pool's lights
    // alone: 848 bytes for a frame of 8 lights, 5,328 for 64.
    private uploadLit(vb: ViewBuffers, f: RenderFrame, shadows: ShadowPlan?, post: PostPlan): void {
        const n = litUniformInto(f, shadows, post, this.litBlock).writeUsedAt(this.blockView, 0);
        vb.lit.update(0, this.blockBytes, n);
    }

    // Milestone 67: whether slot `vb`'s object buffer and group hold the
    // blocks of `f` as its last drawing wrote them (renderFrameReusing: the
    // same items, the same decals' atlas and screen texture bound).
    private objectsKept(vb: ViewBuffers, f: RenderFrame): bool {
        return vb.objects != null && vb.objectsBg != null && vb.cap >= <u32>(f.items.length + 1)
            && vb.decalGeneration == this.decals.generation && vb.objectsScreen === vb.screen;
    }

    // Writes the object uniforms of `f` (frame.as writeFrameObjects) at
    // `objectStride` into the kept bytes and uploads them, growing the
    // buffer when it is too small.
    private uploadObjects(vb: ViewBuffers, f: RenderFrame): void {
        const needed = <u32>(f.items.length + 1);
        const stride = this.objectStride;
        const grow = vb.objects == null || vb.cap < needed;
        if (grow) {
            const cap = objectCapacity(needed);
            const old = vb.objects;
            if (old != null) this.frameBuffers.push(old);
            const oldBg = vb.objectsBg;
            if (oldBg != null) this.frameGroups.push(oldBg);
            const oldLineBg = vb.lineObjectsBg;
            if (oldLineBg != null) this.frameGroups.push(oldLineBg);
            const buffer = new GPUBuffer(BufferUsage.uniform, stride * cap);
            vb.objects = buffer;
            vb.objectsBg = this.objectGroup(buffer, this.dummySkin, vb);
            vb.lineObjectsBg = new GPUBindGroup(
                this.pipelines.lineObjectLayout, [new GPUBindGroupUBO(0, buffer, 0, OBJECT_UNIFORM_SIZE)]);
            vb.cap = cap;
            vb.decalGeneration = this.decals.generation;
            vb.objectsScreen = vb.screen;
        } else if (vb.decalGeneration != this.decals.generation || vb.objectsScreen !== vb.screen) {
            // Milestone 33: the decals' atlas changed (gpu/decals.as): the
            // object group binds the new one. Milestone 62: likewise the
            // view's screen texture.
            const objects0 = vb.objects;
            const oldBg = vb.objectsBg;
            if (oldBg != null) this.frameGroups.push(oldBg);
            if (objects0 != null) vb.objectsBg = this.objectGroup(objects0, this.dummySkin, vb);
            vb.decalGeneration = this.decals.generation;
            vb.objectsScreen = vb.screen;
        }
        const bytes = <i32>(needed * stride);
        if (this.objectBytes.byteLength < bytes) {
            // Zeros: the gaps between slots stay zero, as packObjectUniforms
            // leaves them.
            this.objectBytes = new ArrayBuffer(<i32>(objectCapacity(needed) * stride));
            this.objectView = new DataView(this.objectBytes, 0, this.objectBytes.byteLength);
        }
        // (milestone 37: the blocks of the items a pass of the view reads,
        // cull.as CullResult.used, after the view's culling)
        writeFrameObjects(f, this.objectView, stride, this.cull.used, this.objectBlock);
        const objects = vb.objects;
        if (objects != null) {
            objects.update(0, this.objectBytes, <u32>bytes);
            this.uploadSkins(vb, f, objects);
        }
    }

    // Milestone 48 (see the header): each skinned item of `f` its palette
    // slot in `vb` (vb.skinBySlot), the slot's group made again when the
    // object buffer was replaced, and its palette written only when the
    // item's skin array, joint count or skinVersion differ from what the
    // buffer holds. A view is drawn once a frame, so no pass recorded
    // earlier in the frame reads what this overwrites. Allocates nothing
    // once the view has held as many skinned items.
    private uploadSkins(vb: ViewBuffers, f: RenderFrame, objects: GPUBuffer): void {
        const items = f.items;
        const by = vb.skinBySlot;
        const slots = items.length + 1;
        if (by.length < slots) by.length = slots;
        for (let i = 0; i < by.length; i++) unchecked(by[i] = null);
        let n = 0;
        for (let i = 0; i < items.length; i++) {
            const d = unchecked(items[i]);
            const skin = d.skin;
            const g = d.mesh;
            if (skin == null || d.skinJointCount <= 0 || g == null || d.instances != null || !hasSkin(g)) continue;
            const vertices = skinBuffer(g);
            if (vertices == null || <i32>d.slot >= by.length) continue;
            if (n == vb.skins.length) {
                const made = new SkinSlot(new GPUBuffer(BufferUsage.uniform, SKIN_UNIFORM_SIZE));
                made.index = n;
                vb.skins.push(made);
            }
            const s = unchecked(vb.skins[n]);
            n++;
            const old = s.group;
            if (old == null || s.objects !== objects || s.decalGeneration != this.decals.generation
                || s.screen !== vb.screen) {
                if (old != null) this.frameGroups.push(old);
                s.group = this.objectGroup(objects, s.buffer, vb);
                s.objects = objects;
                s.decalGeneration = this.decals.generation;
                s.screen = vb.screen;
            }
            if (s.data !== skin || s.version != d.skinVersion || s.count != d.skinJointCount) {
                const bytes = writeSkinPalette(this.skinView, skin, d.skinJointCount);
                if (bytes > 0) s.buffer.update(0, this.skinBytes, bytes);
                s.data = skin;
                s.version = d.skinVersion;
                s.count = d.skinJointCount;
                this.skinUploads++;
            }
            s.vertices = vertices;
            unchecked(by[<i32>d.slot] = s);
        }
    }

    // The object group (group 1 of the surface module): the object block
    // at a dynamic offset (binding 0), a palette (SKIN_BINDING: the dummy,
    // or a skinned item's), (milestone 33) the view's decal block and the
    // decals' atlas and its sampler (bindings 2, 3 and 4), (milestone 37)
    // the view's fog block (binding 5) and (milestone 62) its screen texture
    // (SCREEN_BINDING: ViewBuffers.screen).
    private objectGroup(objects: GPUBuffer, palette: GPUBuffer, vb: ViewBuffers): GPUBindGroup {
        return this.objectGroupWith(this.pipelines.objectLayout, objects, palette, vb);
    }

    // `objectGroup` for `layout` (milestone 61: a custom shader module's
    // group 1).
    private objectGroupWith(layout: GPUBindGroupLayout, objects: GPUBuffer, palette: GPUBuffer, vb: ViewBuffers): GPUBindGroup {
        const dc = this.decals;
        return new GPUBindGroup(
            layout,
            [
                new GPUBindGroupUBO(0, objects, 0, OBJECT_UNIFORM_SIZE),
                new GPUBindGroupUBO(SKIN_BINDING, palette, 0, SKIN_UNIFORM_SIZE),
                new GPUBindGroupUBO(DECAL_BLOCK_BINDING, vb.decal, 0, DECAL_UNIFORM_SIZE),
                new GPUBindGroupUBO(FOG_BLOCK_BINDING, vb.fog, 0, FOG_UNIFORM_SIZE),
            ],
            [new GPUBindGroupTexture(DECAL_ATLAS_BINDING, dc.view), new GPUBindGroupTexture(SCREEN_BINDING, vb.screen)],
            [new GPUBindGroupSampler(DECAL_SAMPLER_BINDING, dc.sampler)],
        );
    }

    // SKIN_PIPELINE_WARNING, once, when a pass had to draw a skinned item
    // with a plain pipeline.
    private skinRefused(ps: PassState): void {
        if (!ps.refused && !this.shadowSkinRefused) return;
        ps.refused = false;
        this.shadowSkinRefused = false;
        if (this.skinWarned) return;
        this.skinWarned = true;
        this.warnings.push(SKIN_PIPELINE_WARNING);
    }

    // `ls` packed into `k`'s bytes (new ones only when the count changed)
    // and written into its buffer (a new one only when it is too small, the
    // old released at the next `beginFrame`). A view is drawn once a frame
    // (its globals are written the same way), so no pass recorded earlier
    // in the frame reads what this overwrites.
    private keptLines(k: KeptVertices, ls: Array<LineInstance>): GPUBuffer {
        const bytes = packLineInstances(ls, k.bytes);
        k.bytes = bytes;
        return this.keptUpload(k, bytes);
    }

    private keptPoints(k: KeptVertices, ps: Array<PointInstance>): GPUBuffer {
        const bytes = packPointInstances(ps, k.bytes);
        k.bytes = bytes;
        return this.keptUpload(k, bytes);
    }

    private keptUpload(k: KeptVertices, bytes: ArrayBuffer): GPUBuffer {
        const n = <u32>bytes.byteLength;
        const b = k.buffer;
        if (b != null && b.size >= n) {
            b.update(0, bytes, n);
            return b;
        }
        if (b != null) this.frameBuffers.push(b);
        const made = new GPUBuffer(BufferUsage.vertex, n, bytes);
        k.buffer = made;
        return made;
    }

    private target(width: u32, height: u32, format: TextureFormat, samples: u32): GPUTexture {
        const t = new GPUTexture(targetDesc(width, height, format, samples));
        this.frameTextures.push(t);
        return t;
    }

    // The next render target of view `vb` (see the header), kept from frame
    // to frame: the n-th target a view asks for is the n-th of its last
    // frame's when the size, format and samples are the same (a viewport's
    // frames all are), else a new one replacing it, the old released at
    // the next `beginFrame`. Each target a view takes is its own, so the
    // picture it returns (its last) stays valid for the rest of the frame.
    private slotTarget(vb: ViewBuffers, width: u32, height: u32, format: TextureFormat, samples: u32): PooledTarget {
        const i = vb.targetCursor;
        vb.targetCursor++;
        if (i < vb.targets.length) {
            const t = vb.targets[i];
            if (t.width == width && t.height == height && t.format == format && t.samples == samples) return t;
            this.frameViews.push(t.view);
            this.frameTextures.push(t.texture);
        }
        const texture = new GPUTexture(targetDesc(width, height, format, samples));
        const made = new PooledTarget(texture, texture.view(), width, height, format, samples);
        if (i < vb.targets.length) vb.targets[i] = made;
        else vb.targets.push(made);
        return made;
    }

    // Milestone 67: the target `k` holds, kept while its size, format and
    // samples are the same, else a new one replacing it (the old released
    // at the next `beginFrame`), as slotTarget's rule.
    private keptTarget(k: KeptTarget, width: u32, height: u32, format: TextureFormat, samples: u32): PooledTarget {
        const t = k.target;
        if (t != null) {
            if (t.width == width && t.height == height && t.format == format && t.samples == samples) return t;
            this.frameViews.push(t.view);
            this.frameTextures.push(t.texture);
        }
        const texture = new GPUTexture(targetDesc(width, height, format, samples));
        const made = new PooledTarget(texture, texture.view(), width, height, format, samples);
        k.target = made;
        return made;
    }

    private group(g: GPUBindGroup): GPUBindGroup {
        this.frameGroups.push(g);
        return g;
    }

    // A cached mesh the program's cache dropped or replaced: its buffers are
    // released at the next `beginFrame` (views recorded earlier in this frame
    // may still draw them).
    retire(mesh: GpuMesh): void {
        const b = buffersOf(mesh);
        if (b == null) return;
        const bufs: Array<GPUBuffer?> = [b.tris, b.indices, b.edges, b.points, b.uv1, b.lightmapUv, b.skin];
        for (let i = 0; i < bufs.length; i++) {
            const x = bufs[i];
            if (x != null) this.frameBuffers.push(x);
        }
        b.skin = null;
        b.uv1 = null;
        b.lightmapUv = null;
        b.tris = null;
        b.indices = null;
        b.edges = null;
        b.points = null;
    }

    // Instances the program's cache dropped (Hedra's cache.as
    // `goneInstances`, handed over by SceneRenderer.sweep): their buffer is
    // released at the next `beginFrame`, as `retire`'s are.
    retireInstances(d: InstanceData): void {
        const b = takeInstanceBuffer(d);
        if (b != null) this.frameBuffers.push(b);
        // (milestone 61: its extra stream, when a custom draw uploaded it)
        const e = takeInstanceExtraBuffer(d);
        if (e != null) this.frameBuffers.push(e);
    }

    // The first frame clears the dummy depth map with an empty pass (the
    // constructor runs outside `draw`, where no pass may begin), so it is
    // never sampled uninitialised (the shader samples it for no light, but
    // a backend may still read it).
    private clearDummyDepth(): void {
        if (this.dummyDepthCleared) return;
        this.dummyDepthCleared = true;
        const desc = new GPUPassDesc();
        desc.color = [];
        desc.depthView = this.dummyDepthTarget;
        desc.depthLoadOp = LoadOp.clear;
        desc.depthStoreOp = StoreOp.store;
        desc.depthClearValue = 1.0;
        this.gpu.canvas.beginRenderPass(desc, this.passWrapper).finish();
    }

    // The atlas of `size` texels square, made on first use and kept; a plan
    // of another size (only a test's) replaces it, the old one released at
    // the next `beginFrame` (views recorded earlier in this frame may still
    // sample it). False when the host rejects it.
    private ensureAtlas(size: u32): bool {
        if (size == 0) return false;
        const old = this.atlas;
        if (old != null && old.width == size) return true;
        if (old != null) {
            const ot = this.atlasTarget;
            if (ot != null) this.frameViews.push(ot);
            const os = this.atlasSampled;
            if (os != null) this.frameViews.push(os);
            this.frameTextures.push(old);
            this.atlas = null;
            this.atlasTarget = null;
            this.atlasSampled = null;
        }
        const t = depthTexture(size);
        if (t.handle == 0) return false;
        const target = t.view();
        const sampled = sampledDepthView(t);
        if (target.handle == 0 || sampled.handle == 0) {
            if (target.handle != 0) target.release();
            if (sampled.handle != 0) sampled.release();
            t.release();
            return false;
        }
        this.atlas = t;
        this.atlasTarget = target;
        this.atlasSampled = sampled;
        return true;
    }

    // Group 0 of the view's main pass in a frame with shadows: the atlas at
    // binding 3. Kept in the slot while the atlas is the same.
    private shadowGlobals(vb: ViewBuffers, atlas: GPUTextureView, compare: GPUSampler): GPUBindGroup {
        const cached = vb.globalsShadowBg;
        if (cached != null && vb.atlasView === atlas) return cached;
        if (cached != null) this.frameGroups.push(cached);
        const bg = globalsGroup(
            this.pipelines, vb.globals, vb.lit, vb.shadow, vb.sky, vb.probe, atlas, compare, this.dummy.view);
        vb.globalsShadowBg = bg;
        vb.atlasView = atlas;
        return bg;
    }

    // Group 0 of the view's main pass in a frame with SSAO: the shadow map
    // `map` (the dummy without shadows) and the blurred occlusion `ao`.
    // Kept in the slot while both are the same.
    private aoGlobals(vb: ViewBuffers, map: GPUTextureView, ao: GPUTextureView): GPUBindGroup {
        const cached = vb.aoGroup;
        if (cached != null && vb.aoMap === map && vb.aoView === ao) return cached;
        if (cached != null) this.frameGroups.push(cached);
        const bg = globalsGroup(
            this.pipelines, vb.globals, vb.lit, vb.shadow, vb.sky, vb.probe, map, this.pipelines.compareSampler(), ao);
        vb.aoGroup = bg;
        vb.aoMap = map;
        vb.aoView = ao;
        return bg;
    }

    // Binds a group for every material the frame's items use, kept from
    // frame to frame while `f.materials` is the same array of the same
    // length (a viewport moving its camera over one plan) with the same base
    // directory and the same live views (MaterialBinder.liveGeneration); a new
    // one releases the old groups at the next `beginFrame` (views recorded
    // earlier in this frame may still bind them). The warnings binding
    // raised are raised again with every frame, as when each frame bound
    // its own.
    private bindMaterials(f: RenderFrame): void {
        const mats = f.materials;
        const liveGen = this.materials.liveGeneration;
        if (this.boundMaterials !== mats || this.boundGroups.length != mats.length || this.boundBaseDir != f.baseDir
            || this.boundLive != liveGen) {
            for (let i = 0; i < this.ownedGroups.length; i++) this.frameGroups.push(this.ownedGroups[i]);
            for (let i = 0; i < this.ownedBuffers.length; i++) this.frameBuffers.push(this.ownedBuffers[i]);
            this.ownedGroups.length = 0;
            this.ownedBuffers.length = 0;
            this.boundGroups.length = 0;
            this.boundBuffers.length = 0;
            this.boundExt.length = 0;
            this.boundLiveMask.length = 0;
            for (let i = 0; i < mats.length; i++) {
                this.boundGroups.push(null);
                this.boundBuffers.push(null);
                this.boundExt.push(materialIsExt(mats[i]));
                this.boundLiveMask.push(this.liveMaskOf(mats[i]));
            }
            this.boundWarnings.length = 0;
            this.boundMaterials = mats;
            this.boundBaseDir = f.baseDir;
            this.boundLive = liveGen;
            this.boundValues = this.materials.valuesGeneration;
            this.materialEpoch++;
        } else if (this.boundValues != this.materials.valuesGeneration) {
            this.rewriteMaterials(f);
            this.materialEpoch++;
        }
        const groups = this.boundGroups;
        let made = false;
        const items = f.items;
        for (let i = 0; i < items.length; i++) {
            const d = items[i];
            const g = d.mesh;
            if (g == null) continue;
            for (let k = 0; k < g.ranges.length; k++) {
                const key = d.materials[k];
                if (key < 0 || groups[<i32>key] != null) continue;
                groups[<i32>key] = this.materials.bind(mats[<i32>key], f.baseDir, this.boundWarnings);
                const lb = this.materialBackend;
                if (lb != null) this.boundBuffers[<i32>key] = lb.lastBuffer;
                made = true;
            }
        }
        const mb = this.materialBackend;
        if (made) this.materialEpoch++;
        if (made && mb != null) mb.takeCreated(this.ownedGroups, this.ownedBuffers);
        for (let i = 0; i < this.boundWarnings.length; i++) this.warnings.push(this.boundWarnings[i]);
    }

    // Milestone 67: which of the five bindings' textures of `m` are live
    // views (bit TEX_*: the binder's `live`, looked up as `texture` does, by
    // the path as the material gives it in either colour form). Builds keys,
    // so it is asked only when the material groups are made again.
    private liveMaskOf(m: MaterialDesc): u32 {
        const live = this.materials.live;
        if (live.size == 0) return 0;
        let bits: u32 = 0;
        const tex = m.textures;
        for (let t = 0; t < TEX_COUNT && t < tex.length; t++) {
            const path = tex[t];
            if (path == null) continue;
            if (live.has(texKey(path, true)) || live.has(texKey(path, false))) bits |= <u32>1 << <u32>t;
        }
        return bits;
    }

    // Milestone 25: the numbers and colours of the kept groups' materials
    // changed in place (MaterialBinder.valuesGeneration): each bound
    // group's uniform is written again into its own buffer, through the
    // kept block bytes, allocating nothing. A material drawn by the
    // extended pipelines has its extended block written too, after the base
    // one, from kept objects (every buffer is MATERIAL_UNIFORM_SIZE bytes:
    // GpuMaterialBackend.group). Only a material that became or stopped
    // being one has its groups made again (its pipeline and its bindings
    // change: the extension array is bound only for it).
    private rewriteMaterials(f: RenderFrame): void {
        const mats = f.materials;
        this.boundValues = this.materials.valuesGeneration;
        let remake = false;
        for (let i = 0; i < mats.length && !remake; i++) {
            if (this.boundGroups[i] == null) continue;
            if (this.boundExt[i] != materialIsExt(mats[i]) || this.boundBuffers[i] == null) remake = true;
        }
        if (remake) {
            // As a new materials array would: the groups go at the next
            // beginFrame and are made again below.
            for (let i = 0; i < this.ownedGroups.length; i++) this.frameGroups.push(this.ownedGroups[i]);
            for (let i = 0; i < this.ownedBuffers.length; i++) this.frameBuffers.push(this.ownedBuffers[i]);
            this.ownedGroups.length = 0;
            this.ownedBuffers.length = 0;
            for (let i = 0; i < mats.length; i++) {
                this.boundGroups[i] = null;
                this.boundBuffers[i] = null;
                this.boundExt[i] = materialIsExt(mats[i]);
            }
            this.boundWarnings.length = 0;
            return;
        }
        for (let i = 0; i < mats.length; i++) {
            const buf = this.boundBuffers[i];
            if (this.boundGroups[i] == null || buf == null) continue;
            const m = mats[i];
            const bits = textureBitsOf(m);
            materialUniform(m, bits).writeAt(this.blockView, 0);
            if (!this.boundExt[i]) {
                buf.update(0, this.blockBytes, MATERIAL_BASE_SIZE);
                continue;
            }
            // A drag changes no texture (that bumps liveGeneration or makes
            // a new materials array), so the layers are those bound.
            materialExtUniformInto(m, bits, extLayersInto(m, this.extLayerScratch), this.extBlock)
                .writeAt(this.blockView, MATERIAL_BASE_SIZE);
            buf.update(0, this.blockBytes, MATERIAL_UNIFORM_SIZE);
        }
    }

    // Milestone 61 (see the header): each material of `f` its custom
    // module's pipelines and its material group, or null to draw its
    // fallback, for the view about to draw (`frameCustom`: it draws one);
    // and whether any material has a render priority (`framePriority`).
    // In the lit shading alone: every other shading draws the fallback, as
    // it ignores every material. Allocates nothing once the frame's
    // materials and modules have been seen.
    private prepareCustom(f: RenderFrame): void {
        const mats = f.materials;
        const n = mats.length;
        const of = this.customOf;
        const groups = this.customGroupOf;
        const pending = this.customPendingOf;
        if (of.length < n) {
            of.length = n;
            groups.length = n;
            pending.length = n;
        }
        this.frameCustom = false;
        let priority = false;
        const lit = f.shading == SHADE_LIT && f.materialMode && f.drawSurfaces;
        let source: ShaderModuleSource? = null;
        for (let i = 0; i < n; i++) {
            const m = unchecked(mats[i]);
            if (m.renderPriority != 0) priority = true;
            unchecked(of[i] = null);
            unchecked(groups[i] = null);
            unchecked(pending[i] = false);
            const c = m.custom;
            if (c == null || !lit) continue;
            if (source == null) {
                const s = this.shaderModules;
                source = s != null ? s : installedShaderModules();
            }
            const module = source.moduleOf(c.program);
            if (module == null) {
                unchecked(pending[i] = source.stateOf(c.program) == SHADER_PENDING);
                continue;
            }
            // (the last good module of a file being compiled again has the
            // last good text's layout: ShaderModuleSource.programOf)
            const cp = this.customPipelinesOf(module, source.programOf(c.program));
            if (!cp.ok) {
                this.customRefused(cp);
                continue;
            }
            cp.usedFrame = this.frameSerial;
            const g = cp.materialGroup<GPUBindGroup>(m, this.materials, this.customShared, f.baseDir, this.warnings,
                this.frameSerial, this.customRetired, this.customRetiredBuffers);
            if (g == null) {
                cp.refused = true;
                this.customRefused(cp);
                continue;
            }
            unchecked(of[i] = cp);
            unchecked(groups[i] = g);
            this.frameCustom = true;
        }
        this.framePriority = priority;
    }

    // The pipelines of `module` drawing `program` (made the first time a
    // frame draws them): one set a module and program text (custom.as
    // sharesPipelines).
    private customPipelinesOf(module: GPUShaderModule, program: ShaderProgram): CustomPipelines {
        const cs = this.customs;
        for (let i = 0; i < cs.length; i++) {
            const c = unchecked(cs[i]);
            // (milestone 67: and of the view's colour format and samples)
            if (c.module === module && sharesPipelines(c.program, program) && c.colorFormat == this.active.colorFormat
                && c.samples == this.active.samples) return c;
        }
        const pl = this.active;
        const made = new CustomPipelines(module, program, pl.colorFormat, pl.samples);
        made.usedFrame = this.frameSerial;
        cs.push(made);
        return made;
    }

    // CUSTOM_PIPELINE_WARNING, once a renderer, for a module the host
    // refused (its materials draw their fallback).
    private customRefused(cp: CustomPipelines): void {
        if (!cp.refused || this.customWarned) return;
        this.customWarned = true;
        this.warnings.push(CUSTOM_PIPELINE_WARNING);
    }

    // Whether range `key` of next pass's item `d` is a ShaderMaterial with
    // no module ready (compiling, failed, not built, or a shading other than
    // lit): it is drawn in no pass. Its fallback is a plain white
    // StandardMaterial3D on the owner's own mesh at the owner's depth, which
    // `lessEqual` lets through, so it would paint the owner over; the owner
    // alone is the better picture until the shader is ready.
    private nextPassWithout(f: RenderFrame, d: DrawItem, key: i64): bool {
        if (d.nextPassOf < 0 || key < 0 || key >= <i64>f.materials.length) return false;
        return f.materials[<i32>key].custom != null && this.customFor(key) == null;
    }

    // The custom module of the frame's material `key` (null: its fallback
    // is drawn, or it is no ShaderMaterial).
    private customFor(key: i64): CustomPipelines? {
        if (key < 0 || <i32>key >= this.customOf.length) return null;
        return unchecked(this.customOf[<i32>key]);
    }

    // The view's custom globals (gpu/custom.as customGlobals) written into
    // its kept buffer, made on the slot's first view with a custom range.
    private writeCustomGlobals(vb: ViewBuffers, g: Globals, f: RenderFrame, encode: bool): void {
        if (!this.frameCustom) return;
        let b = vb.customGlobals;
        if (b == null) {
            b = new GPUBuffer(BufferUsage.uniform, GLOBALS_SIZE);
            vb.customGlobals = b;
        }
        customGlobalsInto(g, wrapShaderTime(f.shaderTime), encode, this.customBlock).writeAt(this.blockView, 0);
        b.update(0, this.blockBytes, GLOBALS_SIZE);
    }

    // `cp`'s groups of view `vb`, its object and environment groups made
    // again when the view's object buffer, decal atlas or environment group
    // changed (the old ones released at the next beginFrame).
    private customView(cp: CustomPipelines, vb: ViewBuffers): CustomViewGroups {
        const cv = cp.viewOf(vb.customId);
        const objects = vb.objects;
        if (objects != null && (cv.objectsBuffer !== objects || cv.objectsDecals != this.decals.generation
            || cv.objects == null || cv.objectsScreen !== vb.screen)) {
            const old = cv.objects;
            if (old != null) this.frameGroups.push(old);
            cv.objects = this.objectGroupWith(cp.layout(1), objects, this.dummySkin, vb);
            cv.objectsBuffer = objects;
            cv.objectsDecals = this.decals.generation;
            cv.objectsScreen = vb.screen;
        }
        if (cv.env == null || cv.envSource !== vb.envBg) {
            const old = cv.env;
            if (old != null) this.frameGroups.push(old);
            cv.env = envGroupWith(cp.layout(3), vb.env, this.lightmap, this.probes);
            cv.envSource = vb.envBg;
        }
        return cv;
    }

    // `cp`'s group 1 for skinned item palette `s` of view `vb` (made again
    // when the view's own skinned group of it was).
    private customSkinGroup(cp: CustomPipelines, cv: CustomViewGroups, vb: ViewBuffers, s: SkinSlot): GPUBindGroup? {
        const objects = vb.objects;
        const source = s.group;
        if (objects == null || source == null) return null;
        const i = s.index;
        while (cv.skins.length <= i) {
            cv.skins.push(null);
            cv.skinSources.push(null);
        }
        const kept = cv.skins[i];
        if (kept != null && cv.skinSources[i] === source) return kept;
        if (kept != null) this.frameGroups.push(kept);
        const made = this.objectGroupWith(cp.layout(1), objects, s.buffer, vb);
        cv.skins[i] = made;
        cv.skinSources[i] = source;
        return made;
    }

    // `cp`'s group 0 of pass `which` in view `vb` (CUSTOM_PASS_*; `tile`
    // the shadow tile): the view's custom globals with the main pass's map
    // and occlusion, with the dummies (id, normal-depth), or the tile's
    // custom globals with the dummies.
    private customGlobalsGroup(cp: CustomPipelines, cv: CustomViewGroups, vb: ViewBuffers, which: i32, tile: i32): GPUBindGroup? {
        const compare = this.pipelines.compareSampler();
        if (which == CUSTOM_PASS_SHADOW) {
            if (tile < 0 || tile >= vb.customTiles.length) return null;
            const buf = vb.customTiles[tile];
            while (cv.tiles.length <= tile) {
                cv.tiles.push(globalsGroupWith(cp.layout(0), vb.customTiles[cv.tiles.length], vb.lit, vb.shadow, vb.sky,
                    vb.probe, this.dummyDepthView, compare, this.dummy.view));
                cv.tileBuffers.push(vb.customTiles[cv.tileBuffers.length]);
            }
            if (cv.tileBuffers[tile] !== buf) {
                this.frameGroups.push(cv.tiles[tile]);
                cv.tiles[tile] = globalsGroupWith(cp.layout(0), buf, vb.lit, vb.shadow, vb.sky, vb.probe, this.dummyDepthView,
                    compare, this.dummy.view);
                cv.tileBuffers[tile] = buf;
            }
            return cv.tiles[tile];
        }
        const globals = vb.customGlobals;
        if (globals == null) return null;
        if (which == CUSTOM_PASS_MAIN) {
            let map = this.customMap;
            if (map == null) map = this.dummyDepthView;
            let ao = this.customAo;
            if (ao == null) ao = this.dummy.view;
            const kept = cv.main;
            if (kept != null && cv.mainMap === map && cv.mainAo === ao && cv.mainGlobals === globals) return kept;
            if (kept != null) this.frameGroups.push(kept);
            const made = globalsGroupWith(cp.layout(0), globals, vb.lit, vb.shadow, vb.sky, vb.probe, map, compare, ao);
            cv.main = made;
            cv.mainMap = map;
            cv.mainAo = ao;
            cv.mainGlobals = globals;
            return made;
        }
        const plain = cv.plain;
        if (plain != null && cv.plainGlobals === globals) return plain;
        if (plain != null) this.frameGroups.push(plain);
        const made = globalsGroupWith(cp.layout(0), globals, vb.lit, vb.shadow, vb.sky, vb.probe, this.dummyDepthView,
            compare, this.dummy.view);
        cv.plain = made;
        cv.plainGlobals = globals;
        return made;
    }

    // Draws range `k` of item `d` with the frame's custom material `key`
    // in pass `which` (CUSTOM_PASS_*; `tile` the shadow tile) of view `vb`,
    // binding everything it reads: its module's pipeline for the item's
    // vertex kind, groups 0 to 3, the vertices, UV set 1, the instances and
    // their extra stream or the skin. The pipeline drawn with, or null when
    // it was not drawn (the shader does not draw in that pass: nothing is
    // drawn; a pipeline or buffer refused: the caller draws the fallback,
    // for the main pass).
    private customDraw(
        pass: GPURenderPass, which: i32, key: i64, d: DrawItem, k: i32, vb: ViewBuffers, ip: InstancedPipelines?,
        tile: i32 = -1,
    ): GPUPipeline? {
        const cp = this.customFor(key);
        const mg = key >= 0 && <i32>key < this.customGroupOf.length ? this.customGroupOf[<i32>key] : null;
        const g = d.mesh;
        if (cp == null || mg == null || g == null) return null;
        const b = buffersOf(g);
        const tris = b != null ? b.tris : null;
        const ib = b != null ? b.indices : null;
        if (tris == null || ib == null) return null;
        const inst = d.instances;
        let kind = CUSTOM_PLAIN;
        let skin: SkinSlot? = null;
        if (inst != null) {
            kind = CUSTOM_INSTANCED;
        } else if (<i32>d.slot < vb.skinBySlot.length) {
            skin = vb.skinBySlot[<i32>d.slot];
            if (skin != null) kind = CUSTOM_SKINNED;
        }
        const pipe = cp.pipeline(which, kind);
        if (pipe == null) {
            this.customRefused(cp);
            return null;
        }
        const uv1 = uv1Buffer(g);
        if (uv1 == null) return null;
        let ibuf: GPUBuffer? = null;
        let extra: GPUBuffer? = null;
        if (inst != null) {
            ibuf = ip != null ? instanceGpu(inst) : null;
            extra = instanceExtraBuffer(inst, this.frameBuffers);
            if (ibuf == null || extra == null) return null;
        }
        const cv = this.customView(cp, vb);
        const g0 = this.customGlobalsGroup(cp, cv, vb, which, tile);
        const g1 = skin != null ? this.customSkinGroup(cp, cv, vb, skin) : cv.objects;
        const g3 = cv.env;
        if (g0 == null || g1 == null || g3 == null) return null;
        if (skin != null && skin.vertices == null) return null;
        pass.setPipeline(pipe);
        bindGroup(pass, 0, g0);
        bindGroupAt(pass, 1, g1, d.slot * this.objectStride);
        const mgg = mg.group;
        if (mgg == null) return null;
        bindGroup(pass, 2, mgg);
        bindGroup(pass, 3, g3);
        pass.setVertexBuffer(0, tris);
        if (kind == CUSTOM_INSTANCED && ibuf != null && extra != null) {
            pass.setVertexBuffer(CUSTOM_INSTANCES_SLOT, ibuf);
            pass.setVertexBuffer(CUSTOM_INSTANCED_UV1_SLOT, uv1);
            pass.setVertexBuffer(CUSTOM_EXTRA_SLOT, extra);
        } else if (kind == CUSTOM_SKINNED && skin != null) {
            const sv = skin.vertices;
            if (sv != null) pass.setVertexBuffer(CUSTOM_SKIN_SLOT, sv);
            pass.setVertexBuffer(CUSTOM_SKINNED_UV1_SLOT, uv1);
        } else {
            pass.setVertexBuffer(CUSTOM_PLAIN_UV1_SLOT, uv1);
        }
        pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
        const copies: u32 = inst != null ? inst.count : 1;
        pass.drawIndexed(lodRangeCount(g, d.lod, k), copies, lodRangeFirst(g, d.lod, k));
        return pipe;
    }

    // The extended pipelines when the frame (in a material mode) draws a
    // material that needs them, made on the first such frame; null when it
    // draws none, or the host rejected them (those materials are then drawn
    // by the plain pipelines, with a warning).
    private extending(f: RenderFrame): ExtPipelines? {
        if (!f.materialMode) return null;
        const items = f.items;
        const cull = this.cull;
        let any = false;
        for (let i = 0; i < items.length && !any; i++) {
            const d = items[i];
            if (d.mesh == null || (cull.main[i] != CULL_DRAWN && cull.casters[i] == 0)) continue;
            for (let k = 0; k < d.materials.length; k++) {
                if (this.isExt(d.materials[k])) {
                    any = true;
                    break;
                }
            }
        }
        if (!any) return null;
        const ep = this.active.extPipelines();
        if (ep == null) this.warnings.push(EXT_PIPELINE_WARNING);
        return ep;
    }

    // The top pipelines when the frame draws an item without the depth test
    // (top_pass.as `isTopItem`) in its main or id pass, made on the first
    // such frame; null when it draws none, or the host refused them (those
    // items are then drawn with the depth test, and the renderer says so
    // once).
    private topping(f: RenderFrame): TopPipelines? {
        if (!f.drawSurfaces && !f.outline) return null;
        const items = f.items;
        const main = this.cull.main;
        let any = false;
        for (let i = 0; i < items.length; i++) {
            if (main[i] == CULL_DRAWN && isTopItem(items[i])) {
                any = true;
                break;
            }
        }
        if (!any) return null;
        const tp = this.active.topPipelines();
        if (tp == null && !this.topWarned) {
            this.topWarned = true;
            this.warnings.push(TOP_PIPELINE_WARNING);
        }
        return tp;
    }

    // Whether item `d` is drawn by this frame's top pass rather than with
    // the other surfaces.
    private onTop(d: DrawItem): bool {
        return this.frameTop != null && isTopItem(d);
    }

    // The main pass's top pass (see the header): the frame's items without
    // the depth test, in slot order, after every other surface; in a
    // material mode every range with its material, an extended one with the
    // ext top pipeline. Counts its draws as the surface loops do.
    private drawTop(f: RenderFrame, ps: PassState, tp: TopPipelines): void {
        const items = f.items;
        const main = this.cull.main;
        const pass = ps.pass;
        for (let i = 0; i < items.length; i++) {
            if (main[i] != CULL_DRAWN) continue;
            const d = items[i];
            if (!isTopItem(d)) continue;
            ps.item(d);
            const g = d.mesh;
            if (g == null) continue;
            const b = buffersOf(g);
            const tris = b != null ? b.tris : null;
            const ib = b != null ? b.indices : null;
            if (tris == null || ib == null) {
                this.missedDraws += mainDraws(f, d);
                continue;
            }
            if (!f.materialMode) {
                ps.useSurface(tp.surface);
                ps.object(d.slot);
                pass.setVertexBuffer(0, tris);
                pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                pass.drawIndexed(lodCount(g, d.lod), 1, lodFirst(g, d.lod));
                this.madeDraws++;
                continue;
            }
            let bound = false;
            for (let k = 0; k < g.ranges.length; k++) {
                const key = d.materials[k];
                const ext = this.extSet(key, false) != null;
                const want = ext ? tp.surfaceExt : tp.surface;
                if (!bound || ps.current !== want) {
                    ps.useSurface(want);
                    ps.object(d.slot);
                    pass.setVertexBuffer(0, tris);
                    pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                    bound = true;
                }
                if (ext && !this.bindUv1(pass, g, ps.uv1After(false))) continue;
                ps.setMaterial(this.groupOf(key));
                pass.drawIndexed(lodRangeCount(g, d.lod, k), 1, lodRangeFirst(g, d.lod, k));
                this.madeDraws++;
            }
        }
    }

    // The id pass's top pass: the same items drawn last, so their ids
    // cover every other item's (an alpha-masked range with its material,
    // an extended masked one with the ext id pipeline, as the id pass draws
    // them).
    private drawTopIds(f: RenderFrame, ps: PassState, tp: TopPipelines): void {
        const items = f.items;
        const main = this.cull.main;
        const pass = ps.pass;
        const defaultGroup = this.materials.defaultGroup;
        for (let i = 0; i < items.length; i++) {
            if (main[i] != CULL_DRAWN) continue;
            const d = items[i];
            if (!isTopItem(d)) continue;
            ps.item(d);
            const g = d.mesh;
            if (g == null) continue;
            const b = buffersOf(g);
            if (b == null) continue;
            const tris = b.tris;
            const ib = b.indices;
            if (tris == null || ib == null) continue;
            if (!f.materialMode) {
                ps.useSurface(tp.surfaceId);
                ps.object(d.slot);
                pass.setVertexBuffer(0, tris);
                pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                pass.drawIndexed(lodCount(g, d.lod), 1, lodFirst(g, d.lod));
                continue;
            }
            let bound = false;
            for (let k = 0; k < g.ranges.length; k++) {
                const key = d.materials[k];
                const ext = masks(f, key) && this.extSet(key, false) != null;
                const want = ext ? tp.surfaceIdExt : tp.surfaceId;
                if (!bound || ps.current !== want) {
                    ps.useSurface(want);
                    ps.object(d.slot);
                    pass.setVertexBuffer(0, tris);
                    pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                    bound = true;
                }
                if (ext && !this.bindUv1(pass, g, ps.uv1After(false))) continue;
                ps.setMaterial(this.groupOf(key));
                pass.drawIndexed(lodRangeCount(g, d.lod, k), 1, lodRangeFirst(g, d.lod, k));
            }
        }
        ps.setMaterial(defaultGroup);
    }

    // The frame's lightmap handed to the GPU (gpu/lightmap.as uploads a new
    // one, and keeps it while the frames hand it the same), and its warning.
    private uploadLightmap(f: RenderFrame): void {
        const lm = this.lightmap;
        lm.update(f.lightmap);
        const w = lm.takeWarning();
        if (w.length > 0) this.warnings.push(w);
    }

    // The lightmap pipelines when the frame's main pass draws an item with
    // them (`bakedDraw`), made on the first such frame; null when it draws
    // none, the device does not hold the frame's lightmap, or the host
    // refused the pipelines (those items are then drawn in real-time light,
    // with a warning).
    private lightmapping(f: RenderFrame): LightmapPipelines? {
        if (f.lightmap == null || !this.lightmap.holds(f.lightmap)) return null;
        const items = f.items;
        const main = this.cull.main;
        let any = false;
        for (let i = 0; i < items.length; i++) {
            const d = items[i];
            if (main[i] == CULL_DRAWN && !this.onTop(d) && lightmapDrawKind(f, d) == LIGHTMAP_DRAW_BAKED) {
                any = true;
                break;
            }
        }
        if (!any) return null;
        const lp = this.active.lightmapPipelines();
        if (lp == null) this.warnings.push(LIGHTMAP_PIPELINE_WARNING);
        return lp;
    }

    // The lightmap pipelines when the main pass draws item `d` with them:
    // the frame has them (`lightmapping`), the item is BAKED
    // (`lightmapDrawKind`) and its two coordinate buffers are up; else null
    // (drawn as any item).
    private bakedDraw(f: RenderFrame, d: DrawItem): LightmapPipelines? {
        const lp = this.frameLightmap;
        if (lp == null || lightmapDrawKind(f, d) != LIGHTMAP_DRAW_BAKED) return null;
        const g = d.mesh;
        if (g == null || lightmapUvBuffer(g) == null || uv1Buffer(g) == null) return null;
        return lp;
    }

    // Binds the lightmap draw's two coordinate buffers of `g` (bakedDraw
    // made sure both are up).
    private bindLightmapUvs(pass: GPURenderPass, g: GpuMesh): void {
        const uv1 = uv1Buffer(g);
        const lm = lightmapUvBuffer(g);
        if (uv1 != null) pass.setVertexBuffer(LM_UV1_SLOT, uv1);
        if (lm != null) pass.setVertexBuffer(LM_UV_SLOT, lm);
    }

    // Whether the frame's material `key` is drawn by the extended pipelines.
    private isExt(key: i64): bool {
        return key >= 0 && <i32>key < this.boundExt.length && this.boundExt[<i32>key];
    }

    // The extended pipeline set for an item (instanced or not) whose range
    // has material `key`, or null for the plain pipelines.
    private extSet(key: i64, instanced: bool): ExtPipelineSet? {
        const ep = this.frameExt;
        if (ep == null || !this.isExt(key)) return null;
        return instanced ? ep.instanced : ep.plain;
    }

    // Binds UV set 1 of `g` for an extended draw (at the slot after the
    // vertices, or, with `after`, after the instances or a skin's buffer:
    // EXT_INSTANCED_UV1_SLOT, which is pipelines.as SKIN_UV1_SLOT too);
    // false when it has none to bind.
    private bindUv1(pass: GPURenderPass, g: GpuMesh, after: bool): bool {
        const buf = uv1Buffer(g);
        if (buf == null) return false;
        pass.setVertexBuffer(after ? EXT_INSTANCED_UV1_SLOT : EXT_PLAIN_UV1_SLOT, buf);
        return true;
    }

    // The group of the frame's material `key` (-1: the default material).
    private groupOf(key: i64): GPUBindGroup {
        if (key < 0) return this.materials.defaultGroup;
        const g = this.boundGroups[<i32>key];
        return g != null ? g : this.materials.defaultGroup;
    }

    // The instanced pipelines when an item the frame draws is instanced
    // (made on the first such frame), with each such item's instances
    // uploaded (gpu/instances.as); null when no item is, or the host
    // rejected them (the frame is then drawn without its instanced items,
    // with a warning).
    private instancing(f: RenderFrame): InstancedPipelines? {
        const items = f.items;
        const cull = this.cull;
        let any = false;
        for (let i = 0; i < items.length; i++) {
            if (items[i].instances != null && (cull.main[i] == CULL_DRAWN || cull.casters[i] != 0)) {
                any = true;
                break;
            }
        }
        if (!any) return null;
        const ip = this.active.instancedPipelines();
        if (ip == null) {
            this.warnings.push(INSTANCING_PIPELINE_WARNING);
            return null;
        }
        for (let i = 0; i < items.length; i++) {
            const inst = items[i].instances;
            // (milestone 35: a dynamic data's buffer written when its
            // version moved, made again for a new length, the old one
            // released with the frame's: gpu/instances.as)
            if (inst != null && (cull.main[i] == CULL_DRAWN || cull.casters[i] != 0)) instanceBuffer(inst, this.frameBuffers);
        }
        return ip;
    }

    // Culls `f` for its main pass and the tiles of `plan` into `cull`
    // (cull.as), by frustum only while `cullingEnabled` is on, and keeps
    // its statistics.
    private runCull(f: RenderFrame, plan: ShadowPlan): void {
        cullFrame(f, plan, this.cull, this.cullingEnabled);
        this.lastStats.copyFrom(this.cull.stats);
    }

    // The renderer's one pass state, reset for a new pass.
    private passState(pass: GPURenderPass, vb: ViewBuffers, material: GPUBindGroup): PassState {
        let ps = this.ps;
        if (ps == null) {
            ps = new PassState(pass, vb, this.objectStride, material);
            this.ps = ps;
        } else {
            this.skinRefused(ps);
            ps.reset(pass, vb, this.objectStride, material);
        }
        // (milestone 67: the view's set, whose skinned counterparts it binds)
        ps.pipelines = this.active;
        return ps;
    }

    // P0: every caster of `plan`'s tiles (bit t of cull.as's `casters`:
    // an item with a mesh, `castShadow` not OFF, in range, and not wholly
    // outside the tile) into its tile, one depth-only pass over the atlas
    // (cleared to 1, the far plane). Per tile the viewport and scissor are
    // the tile and group 0 is the tile's Globals. Per material range, as the
    // main pass draws them: blended ranges cast nothing (their shadow would
    // be as solid as an opaque one's); masked ones draw with `fs_shadow`
    // and their material, so the cut-out lets the light through; the rest
    // need no fragment stage, and bind the default material to complete the
    // layout. A mesh with faces hidden in its .modeler model draws every
    // range through `fs_shadow`, which discards those faces as the main
    // pass does (a hidden face casts nothing). An instanced caster draws
    // every instance, with the instanced shadow pipelines (`ip`). The
    // world's Globals are `g`.
    private shadowPass(
        f: RenderFrame, plan: ShadowPlan, vb: ViewBuffers, sp: ShadowPipelines, g: Globals,
        ip: InstancedPipelines?, atlas: GPUTextureView,
    ): void {
        const tiles = plan.tiles;
        while (vb.tileGlobals.length < tiles.length) {
            const buf = new GPUBuffer(BufferUsage.uniform, GLOBALS_SIZE);
            vb.tileGlobals.push(buf);
            vb.tileGroups.push(
                globalsGroup(this.pipelines, buf, vb.lit, vb.shadow, vb.sky, vb.probe, this.dummyDepthView,
                    sp.compareSampler, this.dummy.view));
        }
        for (let i = 0; i < tiles.length; i++) {
            tileGlobalsInto(g, tiles[i].viewProj, this.tileBlock).writeAt(this.blockView, 0);
            vb.tileGlobals[i].update(0, this.blockBytes, GLOBALS_SIZE);
        }
        // Milestone 61: each tile's custom globals, for a view that draws a
        // custom range (gpu/custom.as customTileGlobals).
        if (this.frameCustom) {
            while (vb.customTiles.length < tiles.length) vb.customTiles.push(new GPUBuffer(BufferUsage.uniform, GLOBALS_SIZE));
            const cg = customGlobalsInto(g, wrapShaderTime(f.shaderTime), (g.fparams.w > 0.5), this.customBlock);
            for (let i = 0; i < tiles.length; i++) {
                customTileGlobalsInto(cg, tiles[i].viewProj, this.customTileBlock).writeAt(this.blockView, 0);
                vb.customTiles[i].update(0, this.blockBytes, GLOBALS_SIZE);
            }
        }
        const items = f.items;
        const casters = this.cull.casters;
        const objects = vb.objectsBg;
        const materialMode = f.materialMode;
        const defaultGroup = this.materials.defaultGroup;
        const stride = this.objectStride;

        // Milestone 67 (gpu/shadow_cache.as): the tiles drawn again; every
        // other keeps what it holds, its draws counted as made then. Without
        // the tile clear, a pass that must draw one draws them all.
        const cache = this.shadowCacheFor(f);
        const allTiles = tileBits(tiles.length);
        let draw = this.shadowTilesToDraw(f, plan, vb, sp, atlas, cache) & allTiles;
        const clearTile = draw != 0 && draw != allTiles ? this.tileClear() : null;
        if (draw != 0 && clearTile == null) draw = allTiles;
        const partial = draw != allTiles;
        let kept = 0;
        for (let ti = 0; ti < tiles.length; ti++) {
            if ((draw & (<u32>1 << <u32>ti)) != 0) continue;
            this.madeShadowDraws += unchecked(cache.made[ti]);
            this.missedShadowDraws += unchecked(cache.missed[ti]);
            kept++;
        }
        this.lastStats.shadowTilesDrawn = tiles.length - kept;
        this.lastStats.shadowTilesKept = kept;
        if (draw == 0) return;

        const desc = this.shadowDesc;
        desc.label = "hedra shadow";
        desc.depthView = atlas;
        desc.depthLoadOp = partial ? LoadOp.load : LoadOp.clear;
        desc.depthStoreOp = StoreOp.store;
        desc.depthClearValue = 1.0;
        const pass = this.gpu.canvas.beginRenderPass(desc, this.passWrapper);
        for (let ti = 0; ti < tiles.length; ti++) {
            const t = tiles[ti];
            const bit = <u32>1 << <u32>ti;
            if ((draw & bit) == 0) continue;
            const made0 = this.madeShadowDraws;
            const missed0 = this.missedShadowDraws;
            // (a pass that keeps other tiles loads the atlas: the tile is
            // cleared to the far plane first, as the pass's clear would)
            if (partial && clearTile != null) {
                pass.setPipeline(clearTile);
                pass.setViewport(<f32>t.x, <f32>t.y, <f32>t.size, <f32>t.size);
                pass.setScissor(t.x, t.y, t.size, t.size);
                pass.draw(3);
            }
            // Phase 0 the opaque ranges (no fragment stage), phase 1 the
            // masked ones and those of meshes with hidden faces: one
            // pipeline change per phase and tile (and per switch between
            // plain and instanced casters).
            for (let phase = 0; phase < 2; phase++) {
                const masked = phase == 1;
                let bound: GPUPipeline? = null;
                for (let i = 0; i < items.length; i++) {
                    if ((casters[i] & bit) == 0) continue;
                    const d = items[i];
                    const m = d.mesh;
                    if (m == null) continue;
                    const b = buffersOf(m);
                    const tris = b != null ? b.tris : null;
                    const ib = b != null ? b.indices : null;
                    const inst = d.instances;
                    const ibuf = inst != null && ip != null ? instanceGpu(inst) : null;
                    if (b == null || tris == null || ib == null || (inst != null && ibuf == null)) {
                        // Counted once, in the phase that would draw its
                        // first range.
                        if (phase == 0) this.missedShadowDraws += shadowDraws(f, d);
                        continue;
                    }
                    const copies: u32 = inst != null ? inst.count : 1;
                    let meshBound = false;
                    // Milestone 48: a skinned caster's palette and skin
                    // buffer (uploadSkins), drawn with the skinned
                    // counterparts of the pipelines below. Whether the
                    // object group and slot 1 hold the skinned bindings is
                    // kept per range (`boundSkinned`), so a range drawn the
                    // other way binds them again.
                    const sk = inst == null && <i32>d.slot < vb.skinBySlot.length ? vb.skinBySlot[<i32>d.slot] : null;
                    let boundSkinned = false;
                    const ranges = materialMode ? m.ranges.length : 1;
                    // (Hedra's emerge: an item coming out of its fog is cut
                    // by `fs_shadow` as its pixels are)
                    const cut = b.hiddenFaces || emerging(d);
                    for (let k = 0; k < ranges; k++) {
                        let first: u32 = lodFirst(m, d.lod);
                        let count: u32 = lodCount(m, d.lod);
                        let group = defaultGroup;
                        if (materialMode) {
                            const key = d.materials[k];
                            // (milestone 61: blended, a next pass's range
                            // without one, a shader casting none)
                            if (!castsRange(f, d, k)) continue;
                            // (culling counted it: drawCountError)
                            if (this.nextPassWithout(f, d, key)) {
                                this.missedShadowDraws++;
                                continue;
                            }
                            // A ShaderMaterial whose module is ready casts
                            // with it, in the second phase (its pipeline
                            // runs its fragment stage when it cuts out).
                            if (this.customFor(key) != null) {
                                if (!masked) continue;
                                if (bound == null) {
                                    pass.setViewport(<f32>t.x, <f32>t.y, <f32>t.size, <f32>t.size);
                                    pass.setScissor(t.x, t.y, t.size, t.size);
                                }
                                const drawn = this.customDraw(pass, CUSTOM_PASS_SHADOW, key, d, k, vb, ip, ti);
                                if (drawn != null) {
                                    bound = drawn;
                                    meshBound = false;
                                    this.madeShadowDraws++;
                                } else {
                                    this.missedShadowDraws++;
                                }
                                continue;
                            }
                            if ((cut || masks(f, key)) != masked) continue;
                            if (masked) group = this.groupOf(key);
                            first = lodRangeFirst(m, d.lod, k);
                            count = lodRangeCount(m, d.lod, k);
                        } else if (cut != masked) {
                            continue;
                        }
                        let want: GPUPipeline = masked ? sp.masked : sp.depth;
                        if (inst != null && ip != null) want = masked ? ip.shadowMasked : ip.shadowDepth;
                        // A masked extended material cuts out where its own
                        // texture transform and UV set say.
                        const es = materialMode && masked ? this.extSet(d.materials[k], inst != null) : null;
                        if (es != null) want = es.shadowMasked;
                        let skinned = false;
                        if (sk != null) {
                            const skw = this.active.skinnedOf(want);
                            if (skw == null || sk.group == null || sk.vertices == null) {
                                // (no skinned pipeline: the caster's mesh
                                // is at its bind pose in model space, with
                                // the identity for a world, so its shadow
                                // would fall where nothing is drawn; it
                                // casts none)
                                this.shadowSkinRefused = true;
                                continue;
                            }
                            want = skw;
                            skinned = true;
                        }
                        if (es != null && !this.bindUv1(pass, m, inst != null || skinned)) continue;
                        if (bound !== want) {
                            pass.setPipeline(want);
                            if (bound == null) {
                                pass.setViewport(<f32>t.x, <f32>t.y, <f32>t.size, <f32>t.size);
                                pass.setScissor(t.x, t.y, t.size, t.size);
                            }
                            bindGroup(pass, 0, vb.tileGroups[ti]);
                            bindGroup(pass, 2, defaultGroup);
                            bindGroup(pass, 3, vb.envBg);
                            bound = want;
                        }
                        if (!meshBound || boundSkinned != skinned) {
                            const skg = sk != null && skinned ? sk.group : null;
                            const skv = sk != null && skinned ? sk.vertices : null;
                            if (skg != null && skv != null) {
                                bindGroupAt(pass, 1, skg, d.slot * stride);
                                pass.setVertexBuffer(SKIN_SLOT, skv);
                            } else if (objects != null) {
                                bindGroupAt(pass, 1, objects, d.slot * stride);
                            }
                            if (!meshBound) {
                                pass.setVertexBuffer(0, tris);
                                if (ibuf != null) pass.setVertexBuffer(1, ibuf);
                                pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                            }
                            meshBound = true;
                            boundSkinned = skinned;
                        }
                        if (masked) bindGroup(pass, 2, group);
                        pass.drawIndexed(count, copies, first);
                        this.madeShadowDraws++;
                    }
                }
            }
            cache.drew(ti, t.viewProj, this.madeShadowDraws - made0, this.missedShadowDraws - missed0);
            this.ownTile(ti, cache);
        }
        pass.finish();
        // (the whole atlas cleared: the tiles past the plan's hold nothing)
        if (!partial) for (let ti = tiles.length; ti < SHADOW_TILES; ti++) this.ownTile(ti, null);
    }

    // Milestone 67 (gpu/shadow_cache.as): the shadow cache of frame `f`,
    // the least recently used one (or a new one, up to four) made its own
    // when none is.
    private shadowCacheFor(f: RenderFrame): ShadowTileCache {
        this.shadowSerial++;
        const caches = this.shadowCaches;
        let pick: ShadowTileCache? = null;
        for (let i = 0; i < caches.length; i++) {
            const c = unchecked(caches[i]);
            if (c.frame === f) {
                c.used = this.shadowSerial;
                return c;
            }
            if (pick == null || c.used < pick.used) pick = c;
        }
        if (caches.length < 4 || pick == null) {
            pick = new ShadowTileCache();
            caches.push(pick);
        }
        pick.reset(f);
        pick.used = this.shadowSerial;
        return pick;
    }

    // Tile `t` of the atlas now holds `c`'s drawing (null: none's); the
    // cache it held before forgets it.
    private ownTile(t: i32, c: ShadowTileCache?): void {
        const owners = this.atlasOwner;
        while (owners.length < SHADOW_TILES) owners.push(null);
        const was = unchecked(owners[t]);
        if (was != null && was !== c) was.forget(t);
        unchecked(owners[t] = c);
    }

    // The tile clear's pipeline (made once; null when the host refuses it).
    private tileClear(): GPUPipeline? {
        if (!this.clearTileTried) {
            this.clearTileTried = true;
            this.clearTile = shadowClearPipeline(this.gpu.ctx);
        }
        return this.clearTile;
    }

    // Milestone 67 (gpu/shadow_cache.as): the tiles of `plan` whose
    // drawing `c` does not hold as it would be drawn now (their bits), with
    // `c`'s records made current: every tile when the atlas, the pipelines
    // or the shading changed, or with `shadowCaching` off; else each tile
    // another view drew into since, whose view-projection moved, or which
    // a caster entered, left, changed in or is volatile in. One loop over
    // the frame's items; allocates nothing once `c` has grown to them.
    private shadowTilesToDraw(
        f: RenderFrame, plan: ShadowPlan, vb: ViewBuffers, sp: ShadowPipelines, atlas: GPUTextureView,
        c: ShadowTileCache,
    ): u32 {
        const tiles = plan.tiles;
        const items = f.items;
        const n = items.length;
        const all = tileBits(tiles.length);
        let dirty: u32 = c.begin(atlas, sp, f.materialMode, n) || !this.shadowCaching ? all : 0;
        const owners = this.atlasOwner;
        for (let t = 0; t < tiles.length; t++) {
            const owned = t < owners.length && unchecked(owners[t]) === c;
            if (!owned || !c.tileKept(t, unchecked(tiles[t]).viewProj)) dirty |= <u32>1 << <u32>t;
        }
        const casters = this.cull.casters;
        const m = max<i32>(n, c.count);
        for (let i = 0; i < m; i++) {
            if (i >= n) {
                dirty |= c.gone(i);
                continue;
            }
            const now = unchecked(casters[i]);
            if (now == 0 && !c.had(i)) continue;
            const d = unchecked(items[i]);
            const g = d.mesh;
            const kind = now != 0 ? this.casterKind(f, d, vb) : CASTER_PLAIN;
            const inst = d.instances;
            dirty |= c.item(i, now, d, kind, kind == CASTER_MASKED ? this.materialEpoch : -1,
                g != null ? g.gpu : null, inst != null ? inst.gpu : null);
        }
        c.count = n;
        return dirty;
    }

    // How caster `d`'s depth may change (gpu/shadow_cache.as CASTER_*): as
    // `shadowPass` draws it, a range through `fs_shadow` is masked, and a
    // skinned or emerging item, a mesh rewritten in place, a ShaderMaterial
    // range, or a masked range showing a live texture, volatile.
    private casterKind(f: RenderFrame, d: DrawItem, vb: ViewBuffers): u8 {
        const m = d.mesh;
        if (m == null) return CASTER_PLAIN;
        if (emerging(d) || m.deforms || d.skin != null) return CASTER_VOLATILE;
        if (d.instances == null && <i32>d.slot < vb.skinBySlot.length && vb.skinBySlot[<i32>d.slot] != null) {
            return CASTER_VOLATILE;
        }
        const b = buffersOf(m);
        let masked = b != null && b.hiddenFaces;
        if (!f.materialMode) return masked ? CASTER_MASKED : CASTER_PLAIN;
        const live = this.boundLiveMask;
        for (let k = 0; k < m.ranges.length && k < d.materials.length; k++) {
            if (!castsRange(f, d, k)) continue;
            const key = unchecked(d.materials[k]);
            if (this.customFor(key) != null) return CASTER_VOLATILE;
            if (!masked && !masks(f, key)) continue;
            masked = true;
            if (key >= 0 && <i32>key < live.length && unchecked(live[<i32>key]) != 0) return CASTER_VOLATILE;
        }
        return masked ? CASTER_MASKED : CASTER_PLAIN;
    }

    // Draw one frame at `f.width` x `f.height` pixels (before SSAA) and
    // finish it: the shadow pass when a light of the frame has a shadow
    // (shadow.as `planShadows`), the SSAO passes when its environment
    // turns SSAO on (post.as `planPost`), the main MSAA pass, the glow and
    // final passes when it turns glow or adjustments on, the id pass when
    // `f.outline`, the outline + sRGB pass, then the downsample with
    // `f.overlay`. Must run inside the host's `draw`. The program has
    // already failed a frame the device cannot hold (`gpu.maxTextureSize`)
    // and uploaded its meshes.
    // Milestone 59: the frame's pool of lights for its camera first
    // (light_select.as planLightPool), which the shadows are given out from.
    renderFrame(f: RenderFrame): Result<GpuImage> {
        planLightPool(f, f.lightPlan);
        return this.renderFramePlanned(f, planShadowsInto(f, this.shadowAtlasSize, this.shadowPlan));
    }

    // `renderFrame` with the shadows of `plan` rather than the frame's own
    // (tests draw a plan built by hand). A plan without a tile draws no
    // shadow and runs no shadow pass: the frame's passes and bytes are what
    // they were before shadows existed. The frame's pool of lights is
    // planned again (a caller with a hand plan may not have: planning is
    // idempotent, and cheap).
    renderFramePlanned(f: RenderFrame, plan: ShadowPlan): Result<GpuImage> {
        planLightPool(f, f.lightPlan);
        this.clearDummyDepth();
        // Milestone 33: the frame's decals for its camera first
        // (gpu/decals.as): each item's list, which its uniform carries, the
        // atlas, which the object groups bind (uploadObjects remakes them
        // when it changed), its layers' blits, and the block. Before the
        // probes' captures, which paint the main view's decals.
        this.decals.prepare(f, this.materials, this.gpu, this.warnings);
        // The reflection probes' uploads and live captures first (milestone
        // 20; nothing for a frame without probes): their passes run before
        // this view's, and the counts below are this view's alone.
        this.probePasses(f);
        // Milestone 34: the viewports the frame shows (gpu/viewports.as),
        // drawn before this view, which samples their pictures; nothing for
        // a frame without (every frame before), but the release of those a
        // frame before held.
        if (f.viewports.length > 0) this.viewportPasses(f);
        else if (this.viewports.active()) this.viewports.keepLive(f, this.materials);
        const slot = this.slot;
        const img = this.drawView(f, plan, this.nextSlot(), this.ibl, this.environment);
        this.noteReusable(f, plan, slot);
        return this.finishPicture(f, img);
    }

    // Milestone 67 (gpu/fsr.as): the finished picture brought to the
    // frame's output size (scaling.as) when it asks for another size than
    // it was drawn at: upscaled by FSR 1.0 or the tools' bilinear stretch,
    // and, for a render scale above 1 (Godot allows up to 2), brought down
    // by the bilinear stretch whatever the mode, since EASU only upscales
    // (Godot falls back to bilinear above 1 too); presented as drawn when
    // the sizes are the same.
    private finishPicture(f: RenderFrame, img: Result<GpuImage>): Result<GpuImage> {
        if (!img.ok || f.outputWidth == 0 || f.outputHeight == 0) return img;
        const pic = img.value;
        if (f.outputWidth == pic.width && f.outputHeight == pic.height) return img;
        const q = f.renderQuality;
        const down = f.outputWidth < pic.width || f.outputHeight < pic.height;
        const mode = down ? SCALING_3D_BILINEAR : q.scaling3dMode;
        const up = this.fsr.upscale(this.gpu, pic.view, pic.width, pic.height, f.outputWidth, f.outputHeight,
            mode, q.fsrSharpness, this.warnings);
        if (up == null) return img;
        // (the answer is kept and made again only when the upscaler's
        // target changes: an upscaled frame allocates nothing once warm)
        let out = this.upImage;
        if (out == null || out.view !== up.view) {
            out = new GpuImage(up.texture, up.view, up.width, up.height);
            this.upImage = out;
            this.upResult = Result.okv<GpuImage>(out);
        } else {
            out.texture = up.texture;
            out.width = up.width;
            out.height = up.height;
        }
        return this.upResult!;
    }

    // Milestone 67 (docs/engine/PERFORMANCE.md, "Pictures that change"):
    // `f`, planned before and unchanged since but for the contents of its
    // live textures (an artboard texture drawn again), drawn again. With
    // REUSE_TEXTURES, when `f` is the frame this renderer's last view drew
    // as a main view (renderFrame), no view, viewport or probe face was
    // drawn since, and its size, camera, quality and materials are the
    // same, the picture keeps what reads no live texture's colour from that
    // drawing: the culling, the lights', decals' and fog volumes' choices,
    // the object blocks, the shadow atlas, the normal-depth pass and SSAO,
    // the probes' atlas and the decals' layers; and draws again the main
    // pass (the prepass, the sky, the surfaces and, in a split frame, both
    // halves with the screen texture and the reflections between them),
    // the depth of field, glow, the final, id, outline and compose passes.
    // It draws in full (renderFrame) whatever it cannot prove the same:
    // another frame or view drawn since; a viewport, a probe captured every
    // frame or one still to capture, a decal's live layer, a ShaderMaterial
    // (TIME), or a live texture that a kept pass reads (an alpha-masked
    // material's cut-out in the shadows and the normal-depth pass, the F0
    // and roughness the normal-depth pass writes for the reflections: a
    // live base colour on a metallic surface, a live metallic-roughness
    // texture, an extended material). The picture is renderFrame's, to the
    // byte. REUSE_NONE is renderFrame.
    renderFrameReusing(f: RenderFrame, reuse: i32): Result<GpuImage> {
        if (reuse != REUSE_TEXTURES || !this.canReuse(f)) return this.renderFrame(f);
        this.clearDummyDepth();
        // (no decal blit, no probe upload or capture, no viewport: what the
        // last drawing left holds; the counts are this picture's)
        const gp = this.probes;
        gp.captures = 0;
        gp.uploads = 0;
        if (this.viewports.active()) this.viewports.keepLive(f, this.materials);
        const slot = this.slot;
        const plan = this.reusePlan!;
        const img = this.drawView(f, plan, this.nextSlot(), this.ibl, this.environment, true);
        this.reusedFrames++;
        this.reuseSerial = this.viewSerial;
        this.reuseSlot = slot;
        return this.finishPicture(f, img);
    }

    // Whether renderFrameReusing may keep what the last drawing of `f` left
    // (see there). Allocates nothing.
    private canReuse(f: RenderFrame): bool {
        if (this.reuseFrame !== f || this.reuseBlocked || this.reusePlan == null) return false;
        if (this.viewSerial != this.reuseSerial || this.slot != this.reuseSlot) return false;
        if (f.width != this.reuseWidth || f.height != this.reuseHeight || max<u32>(f.ssaa, 1) != this.reuseSsaa) return false;
        if (!this.reuseQuality.equals(f.renderQuality) || f.viewports.length > 0) return false;
        if (f.materialMode && (this.boundMaterials !== f.materials || this.boundLive != this.materials.liveGeneration
            || this.boundValues != this.materials.valuesGeneration)) return false;
        if (probesLive(f)) return false;
        // (the camera and every other number of the view's globals)
        const encode = this.pipelines.colorFormat != COLOR_FORMAT;
        frameGlobalsInto(f, encode, this.reuseGlobalsBlock).writeAt(this.reuseScratchView, 0);
        const a = this.reuseGlobalsView;
        const b = this.reuseScratchView;
        for (let i = 0; i < <i32>GLOBALS_SIZE; i += 4) {
            if (a.getUint32(i, true) != b.getUint32(i, true)) return false;
        }
        return true;
    }

    // After a main view of `f` drawn in full with `plan` into slot `slot`:
    // what a picture drawn again may keep (renderFrameReusing), and whether
    // it may at all.
    private noteReusable(f: RenderFrame, plan: ShadowPlan, slot: i32): void {
        this.reuseFrame = f;
        this.reuseSerial = this.viewSerial;
        this.reuseSlot = slot;
        this.reuseWidth = f.width;
        this.reuseHeight = f.height;
        this.reuseSsaa = max<u32>(f.ssaa, 1);
        this.reuseQuality.copyFrom(f.renderQuality);
        this.reusePlan = plan;
        this.reuseShadowDraws = this.madeShadowDraws;
        this.reuseMissedShadowDraws = this.missedShadowDraws;
        // (the bytes of the view's globals, made again from the frame: the
        // ones drawView uploaded)
        const encode = this.pipelines.colorFormat != COLOR_FORMAT;
        frameGlobalsInto(f, encode, this.reuseGlobalsBlock).writeAt(this.reuseGlobalsView, 0);
        this.reuseBlocked = this.reuseBlockedBy(f);
    }

    // Whether what the last main view drew of `f` (the culling `cull`, its
    // plan `framePost`) reads a live texture in a pass a picture drawn again
    // would keep, or draws anything such a picture cannot keep (see
    // renderFrameReusing).
    private reuseBlockedBy(f: RenderFrame): bool {
        if (f.viewports.length > 0 || this.frameCustom || this.decals.liveLayers > 0) return true;
        if (f.probes != null && this.probes.captures > 0) return true;
        if (!f.materialMode) return false;
        const masks = this.boundLiveMask;
        if (masks.length == 0) return false;
        const post = this.framePost;
        const mats = f.materials;
        const items = f.items;
        const cull = this.cull;
        for (let i = 0; i < items.length; i++) {
            const d = unchecked(items[i]);
            const g = d.mesh;
            if (g == null || i >= cull.main.length) continue;
            if (unchecked(cull.main[i]) != CULL_DRAWN && unchecked(cull.casters[i]) == 0) continue;
            for (let k = 0; k < g.ranges.length && k < d.materials.length; k++) {
                const key = unchecked(d.materials[k]);
                if (key < 0 || <i32>key >= masks.length || <i32>key >= mats.length) continue;
                const live = unchecked(masks[<i32>key]);
                if (live != 0 && liveReadByKeptPass(unchecked(mats[<i32>key]), live, this.isExt(key), post.prepass)) {
                    return true;
                }
            }
        }
        return false;
    }

    // The source of the surface variants' modules a frame draws with.
    // Milestone 67: none for a view drawn with another pipeline set than the
    // one the variants' pipelines were made for (a probe's capture, a
    // transparent viewport of a frame drawn into the Mobile target), which
    // then draws with the ubershader.
    private variantSource(): SurfaceVariantSource? {
        if (this.active !== this.variantsSet) return null;
        const s = this.surfaceVariants;
        return s != null ? s : installedSurfaceVariants();
    }

    // One view of `f` with the shadows of `plan` into slot `vb`, lit by
    // the sky's light of `iblCache` uploaded into `maps` (the main pair,
    // or a viewport's own: milestone 34): the passes renderFrame's header
    // lists, from the culling to the picture.
    // Milestone 67: with `reuse` (renderFrameReusing, which checked that it
    // may), the culling, the items' lights and fog, the object blocks, the
    // shadow pass, the normal-depth pass and SSAO are kept from the last
    // drawing of this view.
    private drawView(
        f: RenderFrame, plan: ShadowPlan, vb: ViewBuffers, iblCache: IblCache, maps: GpuEnvironment,
        reuse: bool = false,
    ): Result<GpuImage> {
        this.viewSerial++;
        // Milestone 67 (quality.as): the view's pipelines, by its frame's
        // MSAA and target format; the variants' pipelines are those of the
        // main views' set (made again when it changes).
        const set = this.setFor(f);
        this.active = set;
        if (!vb.ownPosts && this.variantsSet !== set) {
            if (this.variantsSet != null) this.variants.release();
            this.variantsSet = set;
        }
        this.reusing = reuse;
        if (!reuse) this.runCull(f, plan);
        const cull = this.cull;
        // Milestone 67: the artboard textures this view draws.
        {
            const its = f.items;
            const drawn = cull.main;
            let shown: u32 = 0;
            for (let i = 0; i < its.length && i < drawn.length; i++) {
                if (unchecked(drawn[i]) == CULL_DRAWN) shown |= unchecked(its[i]).artboards;
            }
            this.artboardsDrawn |= shown;
        }
        // Milestone 34: what this view draws of the viewports' textures,
        // for the schedule's when_visible at the next frame.
        const gv = this.viewports;
        if (gv.active()) gv.noteUsed(f, cull.main, this.decals.plan);
        this.madeDraws = 0;
        this.customDraws = 0;
        this.madeShadowDraws = 0;
        this.missedDraws = 0;
        this.missedShadowDraws = 0;
        this.postCursor = 0;
        this.activePosts = vb.ownPosts ? vb.posts : this.postPool;
        const width = f.width;
        const height = f.height;
        const ssaa = max<u32>(f.ssaa, 1);
        const pxW = width * ssaa;
        const pxH = height * ssaa;
        const items = f.items;
        // The sky's light first: a new sky's maps change the views the
        // slot's groups bind (refreshGroups remakes them).
        const ibl = this.skyLightOf(f, iblCache, maps);
        // Likewise the lightmap's layers (milestone 19).
        this.uploadLightmap(f);
        this.refreshGroups(vb, maps);
        // --- no depth test (milestone 16) and baked lighting (19) ---------
        // Before the lights are chosen: whether the main pass draws the
        // lightmapped items with their baked light is known only once the
        // lightmap pipelines have been tried (a host that refuses them has
        // those items drawn in real-time light, the static lights in their
        // lists), and an item of the top pass is never drawn lightmapped.
        this.frameTop = this.topping(f);
        this.frameLightmap = this.lightmapping(f);
        // Milestone 59: each item's lights for this view, right before the
        // object uniforms carry them (a probe's capture or a viewport may
        // have given the same items theirs since).
        // Milestone 37: for the items the main pass shades alone
        // (cull.shaded: a shadow tile reads an item's transform, not its
        // lights or fog), so that what the culling leaves out, an occluded
        // item above all, costs nothing past its test.
        // (milestone 67: kept by a picture drawn again, as the culling)
        if (!reuse) lightItems(f, this.frameLightmap != null, cull.shaded);
        // Milestone 37: each item's fog volumes for this view (the pool's
        // entries take their lights from the view's light pool), which the
        // object uniforms carry too; the block is written below, with the
        // sky's.
        if (!reuse) prepareFogVolumes(f, f.fogPlan, cull.shaded);
        // Milestone 62: whether the view's main pass is drawn in two (its
        // plan's `split`; the plan is made again below, with its warning),
        // and so the screen texture its object groups bind: the slot's,
        // made now (gpu/screen_chain.as), or the dummy. A host that refuses
        // it draws the view unsplit (SCREEN_PIPELINE_WARNING), as does
        // `splitScreen` false (the tests' reference).
        let screenView = this.dummy.view;
        let splitOk = false;
        // (the refraction only for glass this view's main pass draws:
        // post.as frameRefracts with the culling)
        const early = planPostInto(f, this.halfFloat(), this.postPlan, cull.main);
        if (early.split && this.splitScreen) {
            const sv = this.screenChain.prepare(this.gpu, vb.customId, pxW, pxH, early.screenLevels, this.warnings);
            if (sv != null) {
                screenView = sv;
                splitOk = true;
            }
        }
        vb.screen = screenView;
        // (milestone 67: a picture drawn again keeps the blocks the slot
        // holds, when they were made for the same screen texture and decals)
        if (!reuse || !this.objectsKept(vb, f)) this.uploadObjects(vb, f);
        // (a view without probes, a world of its own's, draws none of the
        // main world's)
        if (f.probes != null) this.writeProbeBlock(vb);
        else this.writeZeroProbeBlock(vb);
        this.writeDecalBlock(vb);
        const materialMode = f.materialMode;

        // --- materials ---------------------------------------------------
        // One bind group per material the frame uses (kept while its
        // materials are the same); other modes bind the default material so
        // the surface layout is always complete.
        if (materialMode) this.bindMaterials(f);
        // Milestone 61: each ShaderMaterial's module, or its fallback, and
        // the main pass's custom draws and fallbacks (the statistics: the
        // main view's, which draws last).
        this.prepareCustom(f);
        if (f.shading == SHADE_LIT) {
            countCustomRanges(f, cull.main, this.customOf, this.customPendingOf, this.frameTop != null, this.lastStats);
        }

        // --- instancing --------------------------------------------------
        const ip = this.instancing(f);
        // --- extended materials (milestone 14, part 2) --------------------
        this.frameExt = this.extending(f);

        // --- shadows -----------------------------------------------------
        // A host that rejects the shadow pipelines or the atlas draws the
        // frame without shadows, and says so.
        let shadows: ShadowPipelines? = null;
        let atlas: GPUTextureView? = null;
        if (plan.any()) {
            shadows = this.pipelines.shadowPipelines();
            if (shadows == null) {
                this.warnings.push(SHADOW_PIPELINE_WARNING);
            } else if (!this.ensureAtlas(plan.atlasSize)) {
                this.warnings.push(SHADOW_ATLAS_WARNING);
                shadows = null;
            } else {
                atlas = this.atlasTarget;
            }
        }

        // --- post-processing ---------------------------------------------
        // What the environment turns on (nothing outside the lit mode, and
        // nothing on the rgba8unorm fallback target, which holds no HDR
        // colour: `planPost` says so). A host that rejects the pipelines
        // draws the frame without, and says so too.
        let post = planPostInto(f, this.halfFloat(), this.postPlan, cull.main);
        if (post.warning.length > 0) this.warnings.push(post.warning);
        let pp: PostPipelines? = null;
        if (post.any()) {
            pp = this.pipelines.postPipelines();
            if (pp == null) {
                this.warnings.push(POST_PIPELINE_WARNING);
                post = new PostPlan();
            }
        }
        // (milestone 62: the screen texture refused above: drawn without
        // what reads it; or the tests' reference, `splitScreen` false: the
        // same plan in one pass, the tone map still in the final pass)
        if (post.split && !splitOk) {
            if (this.splitScreen) {
                dropSplit(post);
            } else {
                post.split = false;
                post.refraction = false;
                post.screenLevels = 0;
            }
        }
        this.framePost = post;

        // --- globals -----------------------------------------------------
        // Each block is written into the kept bytes, which the upload
        // copies.
        const encodeInShader = this.pipelines.colorFormat != COLOR_FORMAT;
        const globals = frameGlobalsInto(f, encodeInShader, this.globalsBlock);
        globals.writeAt(this.blockView, 0);
        vb.globals.update(0, this.blockBytes, GLOBALS_SIZE);
        // (milestone 61: TIME and the rest, for a view with a custom range)
        this.writeCustomGlobals(vb, globals, f, encodeInShader);
        // Written for every frame, lit or not: the other modes never read
        // it, so their pictures do not change, and the bind group is always
        // complete. Without shadows no light is marked shadowed and the
        // shadow block is not written (the shader then never reads it).
        // An empty post plan leaves the lit block's bytes as they were.
        // Milestone 59: only the header and the pool's lights are uploaded
        // (no item names a light past them).
        if (shadows != null) {
            this.uploadLit(vb, f, plan, post);
            plan.uniform.writeAt(this.blockView, 0);
            vb.shadow.update(0, this.blockBytes, SHADOW_UNIFORM_SIZE);
        } else {
            this.uploadLit(vb, f, null, post);
        }
        // Flags 0 for a frame that is not lit, or has no Sky and no fog: the
        // shader then reads nothing of the sky's bindings.
        if (f.shading == SHADE_LIT) {
            skyUniformInto(f, ibl, this.skyBlock).writeAt(this.blockView, 0);
            vb.sky.update(0, this.blockBytes, SKY_UNIFORM_SIZE);
        } else {
            vb.sky.update(0, this.idleSky);
        }
        this.writeFogBlock(vb, f, f.shading == SHADE_LIT ? this.skyBlock : null);

        // --- overlay geometry (world space, slot 0; per item) --------------
        const worldLinesBuf = f.worldLines.length > 0 ? this.keptLines(vb.worldLines, f.worldLines) : null;
        const topLinesBuf = f.topLines.length > 0 ? this.keptLines(vb.topLines, f.topLines) : null;
        const topPointsBuf = f.topPoints.length > 0 ? this.keptPoints(vb.topPoints, f.topPoints) : null;
        const objectLineBufs = this.lineBufs;
        objectLineBufs.length = 0;
        for (let i = 0; i < f.itemLines.length; i++) {
            const l = f.itemLines[i];
            if (l.lines.length == 0) continue;
            const n = objectLineBufs.length;
            if (n == vb.itemLines.length) vb.itemLines.push(new KeptVertices());
            const b = this.keptLines(vb.itemLines[n], l.lines);
            objectLineBufs.push(keptDraw(vb.itemLineDraws, n, l.slot, b, <u32>l.lines.length, l.onTop));
        }
        const objectPointBufs = this.pointBufs;
        objectPointBufs.length = 0;
        for (let i = 0; i < f.itemPoints.length; i++) {
            const p = f.itemPoints[i];
            if (p.points.length == 0) continue;
            const n = objectPointBufs.length;
            if (n == vb.itemPoints.length) vb.itemPoints.push(new KeptVertices());
            const b = this.keptPoints(vb.itemPoints[n], p.points);
            objectPointBufs.push(keptDraw(vb.itemPointDraws, n, p.slot, b, <u32>p.points.length, p.onTop));
        }

        // --- textures ----------------------------------------------------
        const pl = this.active;
        const samples = pl.samples;
        const colorFormat = pl.colorFormat;
        const resolveView = this.slotTarget(vb, pxW, pxH, colorFormat, 1).view;
        const depthView = this.slotTarget(vb, pxW, pxH, DEPTH_FORMAT, samples).view;
        // With the tone map moved to the final pass (the glow), the clear
        // colour must be the one it has not tone mapped yet, when the frame
        // carries one; a frame whose post passes do not run after all (the
        // fallback target, rejected pipelines) keeps its tone-mapped one.
        const env = f.environment;
        const bg = post.toneInPost && env.hasPostBackground ? env.postBackground : f.background;
        // Milestone 34: a transparent background (a SubViewport's
        // transparent_bg) clears to (0, 0, 0, 0) and draws no sky.
        const transparent = f.transparent;
        const lr: f32 = transparent ? 0 : srgbToLinear(bg.x);
        const lg: f32 = transparent ? 0 : srgbToLinear(bg.y);
        const lb: f32 = transparent ? 0 : srgbToLinear(bg.z);
        const la: f32 = transparent ? 0 : clampF32(bg.w, 0.0, 1.0);

        const drawSurfaces = f.drawSurfaces;
        const outlineOn = f.outline;
        const main = cull.main;
        const defaultGroup = this.materials.defaultGroup;

        // --- P0: shadow pass (only with shadows) ---------------------------
        let mainGlobals = vb.globalsBg;
        let mainMap = this.dummyDepthView;
        const sampled = this.atlasSampled;
        if (shadows != null && atlas != null && sampled != null) {
            // (milestone 67: a picture drawn again keeps the atlas: no view
            // drew into it since)
            if (!reuse) {
                this.shadowPass(f, plan, vb, shadows, globals, ip, atlas);
            } else {
                this.madeShadowDraws = this.reuseShadowDraws;
                this.missedShadowDraws = this.reuseMissedShadowDraws;
            }
            mainGlobals = this.shadowGlobals(vb, sampled, shadows.compareSampler);
            mainMap = sampled;
        } else {
            // (a host that rejected the shadow pipelines or the atlas: the
            // pass culling counted is not drawn at all)
            this.missedShadowDraws = cull.stats.shadowDraws;
        }

        // --- SSAO (only with the plan's ssao) -----------------------------
        // The main pass's group 0 is then the slot's SSAO group, the blurred
        // occlusion at binding 10 (the slot's other groups keep the dummy).
        // Milestone 62: the normal-depth pass is the plan's `prepass` (SSAO,
        // the reflections or the depth of field), SSAO's passes after it.
        const ssaoPipelines = pp;
        this.customMap = mainMap;
        this.customAo = null;
        this.ndView = null;
        this.ndSurfaceView = null;
        if (post.prepass && ssaoPipelines != null) {
            // (milestone 67: a picture drawn again keeps the slot's targets
            // of both, as the last drawing left them)
            const ndKept = vb.ndNormal.target;
            const surfaceKept = vb.ndSurface.target;
            if (reuse && ndKept != null && surfaceKept != null) {
                this.ndView = ndKept.view;
                this.ndSurfaceView = surfaceKept.view;
            } else {
                this.normalDepthPass(f, vb, ssaoPipelines, ip, pxW, pxH, post);
            }
            const nd = this.ndView;
            if (post.ssao && nd != null) {
                const aoKept = vb.aoBlur.target;
                const ao = reuse && aoKept != null ? aoKept.view : this.ssaoPasses(f, vb, ssaoPipelines, pxW, pxH, nd);
                mainGlobals = this.aoGlobals(vb, mainMap, ao);
                this.customAo = ao;
            }
        }

        // Milestone 67 (gpu/variants.as): the view's frame-wide variant bits.
        this.variants.beginView(f, post, shadows != null);

        // Milestone 67 (order.as, prepass.as): the opaque ranges in their
        // order (with rendering/shading/sort_opaque, or for the depth
        // prepass, which draws them in it), then the prepass into the main
        // pass's depth, which the main pass loads. Neither runs outside a
        // material shading, nor with both off: the item loops draw as
        // before.
        const q = f.renderQuality;
        const surfacesMode = f.drawSurfaces && f.materialMode;
        const wantPrepass = surfacesMode && prepassWanted(q, this.gpu.info.vendor);
        this.ordered = surfacesMode && (q.sortOpaque || wantPrepass);
        if (this.ordered) this.gatherOpaque(f, vb, post, ip, wantPrepass, q.sortOpaque);
        let prepassDraws = 0;
        if (wantPrepass && this.prepassable > 0) {
            prepassDraws = this.depthPrepass(f, vb, ip, depthView, mainGlobals);
        }

        // --- P1: main pass -----------------------------------------------
        // Milestone 62: with the plan's `split`, its first half (A). Its
        // MSAA colour is resolved and discarded, as the one pass's, when
        // the second (B) can begin by writing the screen texture's level 0
        // (A's resolve) to every sample (gpu/screen_chain.as `expand`),
        // else stored for B to load; its depth is stored only when B draws
        // a surface that tests it (lateTestsDepth) or the overlay pass
        // reads it. (Storing and loading the samples was most of the
        // split's cost: SCREEN_EFFECTS.md, "Costs".) When B would draw
        // nothing but the reflections' merge (no surface that tests the
        // depth, no overlay), there is no B: the merge is a pass of its own
        // over A's resolve (gpu/ssr.as mergeOver), and A stores neither its
        // samples nor its depth.
        const split = post.split;
        const expand = split && samples > 1 && this.screenChain.canExpand(this.gpu, samples, colorFormat);
        // With the final pass, the overlay (grid, edges, points, gizmos)
        // gets a pass of its own (see below), depth-tested against the main
        // pass's depth, which is then kept.
        const finalPipelines = pp;
        const finalPass = post.final() && finalPipelines != null;
        const withOverlay = this.hasOverlay(f, objectLineBufs, objectPointBufs);
        const overlaySplit = finalPass && withOverlay;
        const lateTests = split && lateTestsDepth(f, post, main);
        const mergeAlone = split && post.ssr && finalPass && !withOverlay && !lateTests;
        const color = this.mainColor;
        let msaaView: GPUTextureView? = null;
        if (samples > 1) {
            msaaView = this.slotTarget(vb, pxW, pxH, colorFormat, samples).view;
            color.view = msaaView;
            color.resolveTarget = resolveView;
            color.storeOp = split && !expand && !mergeAlone ? StoreOp.store : StoreOp.discard;
        } else {
            color.view = resolveView;
            color.resolveTarget = null;
            color.storeOp = StoreOp.store;
        }
        color.loadOp = LoadOp.clear;
        if (encodeInShader) {
            color.clearR = linearToSrgb(lr);
            color.clearG = linearToSrgb(lg);
            color.clearB = linearToSrgb(lb);
        } else {
            color.clearR = lr;
            color.clearG = lg;
            color.clearB = lb;
        }
        color.clearA = la;
        const lateDepth = split && !mergeAlone && (!expand || lateTests);
        const mainDesc = this.mainDesc;
        mainDesc.label = split ? "hedra main (opaque)" : "hedra main";
        mainDesc.depthView = depthView;
        // (milestone 67: the prepass's depth, when it drew)
        mainDesc.depthLoadOp = prepassDraws > 0 ? LoadOp.load : LoadOp.clear;
        mainDesc.depthStoreOp = overlaySplit || lateDepth ? StoreOp.store : StoreOp.discard;
        mainDesc.depthClearValue = 1.0;
        const canvas = this.gpu.canvas;
        const ps = this.passState(canvas.beginRenderPass(mainDesc, this.passWrapper), vb, defaultGroup);
        ps.globals = mainGlobals;
        const pass = ps.pass;
        // The lit mode's sky, behind everything: no depth test or write, so
        // the surfaces drawn next cover it.
        // It reads group 0 only; groups 1 and 2 are bound as for a surface
        // (the world's slot, the default material) to complete the layout.
        if (f.shading == SHADE_LIT && f.environment.sky && !transparent) {
            ps.surfacePipeline(pl.sky);
            ps.object(0);
            pass.draw(3);
        }
        this.refractionDrawCount = 0;
        let screenPasses = 0;
        let ssrTraced = false;
        let refracted = false;
        const inp = this.screenInputs;
        inp.clear();
        inp.slot = vb.customId;
        inp.pxW = pxW;
        inp.pxH = pxH;
        inp.samples = samples;
        inp.mergeAlone = mergeAlone;
        inp.normalDepth = this.ndView;
        inp.surface = this.ndSurfaceView;
        if (!split) {
            this.drawSurfaces(f, ps, ip);
        } else {
            this.drawSurfaces(f, ps, ip, PHASE_OPAQUE);
            pass.finish();
            // Milestone 62: the screen texture from A's resolved colour,
            // the reflections traced from it, then B on A's samples and
            // depth: the reflections laid over the colour, the ranges that
            // refract (reading the screen texture), the blended ones and
            // the top pass, resolved again at its end.
            const sv = this.screenChain.draw(
                this.gpu, vb.customId, resolveView, pxW, pxH, post.screenLevels, this.warnings);
            screenPasses += this.screenChain.lastPasses;
            inp.screen = sv;
            inp.screenLevels = sv != null ? post.screenLevels : 0;
            // (milestone 67: the merge draws into the view's colour format)
            this.ssr.colorFormat = colorFormat;
            const traced = post.ssr && sv != null && this.ssr.trace(this.gpu, f, post, inp, this.warnings);
            if (traced) screenPasses += this.ssr.lastPasses;
            ssrTraced = traced;
            refracted = post.refraction && sv != null;
        }
        // (`pass` is finished here when the merge drew alone)
        const open = !split || !mergeAlone;
        if (split && mergeAlone) {
            if (ssrTraced && this.ssr.mergeOver(this.gpu, vb.customId, resolveView)) screenPasses++;
        } else if (split) {
            const cb = this.mainColorB;
            cb.view = msaaView != null ? msaaView : resolveView;
            cb.resolveTarget = msaaView != null ? resolveView : null;
            // (with the expand every sample is written first: the clear
            // only spares the host a load)
            cb.loadOp = expand ? LoadOp.clear : LoadOp.load;
            cb.clearR = 0;
            cb.clearG = 0;
            cb.clearB = 0;
            cb.clearA = 0;
            cb.storeOp = msaaView != null ? StoreOp.discard : StoreOp.store;
            const descB = this.mainDescB;
            descB.label = "hedra main (late)";
            descB.depthView = depthView;
            descB.depthLoadOp = overlaySplit || lateDepth ? LoadOp.load : LoadOp.clear;
            descB.depthClearValue = 1.0;
            descB.depthStoreOp = overlaySplit ? StoreOp.store : StoreOp.discard;
            // (the same wrapper: `pass` is the new pass from here on)
            this.passState(canvas.beginRenderPass(descB, this.passWrapper), vb, defaultGroup);
            ps.globals = mainGlobals;
            screenPasses++;
            if (expand) {
                this.screenChain.expand(this.gpu, pass, vb.customId, samples, colorFormat);
                // (the expand bound its own pipeline and group)
                ps.current = null;
            }
            if (ssrTraced) {
                this.ssr.merge(pass, vb.customId);
                // (the merge bound its own pipeline and groups)
                ps.current = null;
            }
            this.drawSurfaces(f, ps, ip, PHASE_LATE);
        }
        // The overlay pass, with the final pass: the lines and points below
        // write colour already final (linear 0..1, lines.wgsl target_color),
        // which the final pass must neither expose, tone map, grade nor let
        // glow. So they are drawn into a transparent layer of their own
        // (premultiplied by the blend, over a clear of 0) that fs_post lays
        // over the finished picture, where the main pass would have blended
        // them over its colour.
        let overlayView: GPUTextureView? = null;
        if (overlaySplit) {
            pass.finish();
            const layerView = this.slotTarget(vb, pxW, pxH, colorFormat, 1).view;
            const oc = this.overlayColor;
            if (samples > 1) {
                oc.view = this.slotTarget(vb, pxW, pxH, colorFormat, samples).view;
                oc.resolveTarget = layerView;
                oc.storeOp = StoreOp.discard;
            } else {
                oc.view = layerView;
                oc.resolveTarget = null;
                oc.storeOp = StoreOp.store;
            }
            oc.loadOp = LoadOp.clear;
            oc.clearR = 0;
            oc.clearG = 0;
            oc.clearB = 0;
            oc.clearA = 0;
            const overlayDesc = this.overlayDesc;
            overlayDesc.label = "hedra overlay";
            overlayDesc.depthView = depthView;
            overlayDesc.depthLoadOp = LoadOp.load;
            overlayDesc.depthStoreOp = StoreOp.discard;
            // (the same wrapper: `pass` is the new pass from here on)
            this.passState(canvas.beginRenderPass(overlayDesc, this.passWrapper), vb, defaultGroup);
            ps.globals = mainGlobals;
            overlayView = layerView;
        }
        if (open) {
            // Grid and floor axes.
            ps.linePipeline(pl.lines);
            if (worldLinesBuf != null) {
                ps.object(0);
                pass.setVertexBuffer(0, worldLinesBuf);
                pass.draw(6, <u32>f.worldLines.length);
            }
            // Mesh edges: wire-solid / edges overlay / edit cage. (An instanced
            // item has none: its copies' edges would need instanced lines.)
            ps.linePipeline(drawSurfaces ? pl.lines : pl.linesTop);
            for (let i = 0; i < items.length; i++) {
                if (main[i] != CULL_DRAWN) continue;
                const d = items[i];
                if (!d.showEdges || d.instances != null) continue;
                const g = d.mesh;
                if (g == null) continue;
                const b = buffersOf(g);
                if (b == null) continue;
                const edges = b.edges;
                if (edges != null) {
                    ps.object(d.slot);
                    pass.setVertexBuffer(0, edges);
                    pass.draw(6, g.edgeCount);
                }
            }
            // Extras, face normals and depth-tested bones.
            ps.linePipeline(pl.lines);
            for (let i = 0; i < objectLineBufs.length; i++) {
                const l = objectLineBufs[i];
                if (l.onTop) continue;
                ps.object(l.index);
                pass.setVertexBuffer(0, l.buffer);
                pass.draw(6, l.count);
            }
            ps.linePipeline(pl.points);
            for (let i = 0; i < objectPointBufs.length; i++) {
                const p = objectPointBufs[i];
                if (p.onTop) continue;
                ps.object(p.index);
                pass.setVertexBuffer(0, p.buffer);
                pass.draw(6, p.count);
            }
            // Vertices.
            ps.linePipeline(pl.points);
            for (let i = 0; i < items.length; i++) {
                if (main[i] != CULL_DRAWN) continue;
                const d = items[i];
                if (!d.showPoints || d.instances != null) continue;
                const g = d.mesh;
                if (g == null) continue;
                const b = buffersOf(g);
                if (b == null) continue;
                const points = b.points;
                if (points != null) {
                    ps.object(d.slot);
                    pass.setVertexBuffer(0, points);
                    pass.draw(6, g.pointCount);
                }
            }
            // On top: bones in edit / pose mode or x-ray, cursor, origins.
            ps.linePipeline(pl.linesTop);
            for (let i = 0; i < objectLineBufs.length; i++) {
                const l = objectLineBufs[i];
                if (!l.onTop) continue;
                ps.object(l.index);
                pass.setVertexBuffer(0, l.buffer);
                pass.draw(6, l.count);
            }
            if (topLinesBuf != null) {
                ps.object(0);
                pass.setVertexBuffer(0, topLinesBuf);
                pass.draw(6, <u32>f.topLines.length);
            }
            ps.linePipeline(pl.pointsTop);
            for (let i = 0; i < objectPointBufs.length; i++) {
                const p = objectPointBufs[i];
                if (!p.onTop) continue;
                ps.object(p.index);
                pass.setVertexBuffer(0, p.buffer);
                pass.draw(6, p.count);
            }
            if (topPointsBuf != null) {
                ps.object(0);
                pass.setVertexBuffer(0, topPointsBuf);
                pass.draw(6, <u32>f.topPoints.length);
            }
            pass.finish();
        }

        // --- depth of field (milestone 62: only with the plan's dof) -------
        // Its composition, when drawn, is what glow and the final pass read.
        let sceneView = resolveView;
        let dofDrawn = false;
        if (post.dof) {
            inp.colour = resolveView;
            const dv = this.dof.draw(this.gpu, f, post, inp, this.warnings);
            if (dv != null) {
                sceneView = dv;
                screenPasses += 3;
                dofDrawn = true;
            }
        }
        const st = this.lastStats;
        st.refractionDraws = this.refractionDrawCount;
        st.screenPasses = screenPasses;
        st.ssrTraced = ssrTraced;
        st.refracted = refracted;
        st.dofDrawn = dofDrawn;
        st.samples = <i32>samples;
        st.compactTarget = colorFormat == TextureFormat.r11g11b10float;
        st.sorted = this.ordered && q.sortOpaque;
        st.prepass = prepassDraws > 0;
        st.prepassDraws = prepassDraws;
        st.reused = reuse;
        this.ordered = false;

        // --- glow and the final pass (only with glow or adjustments) -------
        // The outline pass then reads the finished picture, already sRGB.
        let outlineSrc = resolveView;
        let encodeOutline = !encodeInShader;
        // A transparent clear leaves premultiplied colour: whichever pass
        // reads the resolve first makes it straight (fs_post or fs_outline).
        let straightOutline = transparent;
        if (finalPass && finalPipelines != null) {
            outlineSrc = this.finalPasses(f, vb, post, finalPipelines, sceneView, overlayView, pxW, pxH);
            encodeOutline = false;
            straightOutline = false;
        }

        // --- P2: id pass (outline only; labels use the CPU ray cast) -------
        let idView: GPUTextureView = this.dummy.view;
        if (outlineOn) {
            idView = this.slotTarget(vb, pxW, pxH, ID_FORMAT, 1).view;
            const idDepthView = this.slotTarget(vb, pxW, pxH, DEPTH_FORMAT, 1).view;
            const ic = this.idColor;
            ic.view = idView;
            ic.resolveTarget = null;
            ic.loadOp = LoadOp.clear;
            ic.storeOp = StoreOp.store;
            ic.clearR = 0;
            ic.clearG = 0;
            ic.clearB = 0;
            ic.clearA = 0;
            const idDesc = this.idDesc;
            idDesc.label = "hedra id";
            idDesc.depthView = idDepthView;
            idDesc.depthLoadOp = LoadOp.clear;
            idDesc.depthStoreOp = StoreOp.discard;
            idDesc.depthClearValue = 1.0;
            const ips = this.passState(canvas.beginRenderPass(idDesc, this.passWrapper), vb, defaultGroup);
            const ipass = ips.pass;
            ips.surfacePipeline(pl.surfaceId);
            for (let i = 0; i < items.length; i++) {
                if (main[i] != CULL_DRAWN) continue;
                const d = items[i];
                const g = d.mesh;
                // (milestone 61: a next pass leaves no id: the outline is
                // its owner's)
                if (g == null || this.onTop(d) || d.nextPassOf >= 0) continue;
                ips.item(d);
                const b = buffersOf(g);
                if (b == null) continue;
                const tris = b.tris;
                const ib = b.indices;
                if (tris == null || ib == null) continue;
                const inst = d.instances;
                let copies: u32 = 1;
                if (inst != null) {
                    const ibuf = ip != null ? instanceGpu(inst) : null;
                    if (ip == null || ibuf == null) continue;
                    ips.useSurface(ip.surfaceId);
                    ipass.setVertexBuffer(1, ibuf);
                    copies = inst.count;
                } else {
                    ips.useSurface(pl.surfaceId);
                }
                ips.object(d.slot);
                ipass.setVertexBuffer(0, tris);
                ipass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                if (!materialMode) {
                    ipass.drawIndexed(lodCount(g, d.lod), copies, lodFirst(g, d.lod));
                    continue;
                }
                // Per material so alpha-masked cutouts leave no id (an
                // extended one's with its own pipeline, whose cut-out
                // follows its texture transform).
                for (let k = 0; k < g.ranges.length; k++) {
                    const key = d.materials[k];
                    // Milestone 61: a ShaderMaterial whose module is ready
                    // leaves its id where it draws (its cut-out and side).
                    if (this.customFor(key) != null) {
                        const drawn = this.customDraw(ipass, CUSTOM_PASS_ID, key, d, k, vb, ip);
                        if (drawn != null) {
                            ips.current = drawn;
                            continue;
                        }
                    }
                    const es = masks(f, key) ? this.extSet(key, inst != null) : null;
                    let want: GPUPipeline = pl.surfaceId;
                    if (inst != null && ip != null) want = ip.surfaceId;
                    if (es != null) want = es.surfaceId;
                    if (ips.current !== want) {
                        ips.useSurface(want);
                        ips.object(d.slot);
                        ipass.setVertexBuffer(0, tris);
                        if (inst != null && ip != null) {
                            const ibuf = instanceGpu(inst);
                            if (ibuf != null) ipass.setVertexBuffer(1, ibuf);
                        }
                        ipass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                    }
                    if (es != null && !this.bindUv1(ipass, g, ips.uv1After(inst != null))) continue;
                    ips.setMaterial(this.groupOf(key));
                    ipass.drawIndexed(lodRangeCount(g, d.lod, k), copies, lodRangeFirst(g, d.lod, k));
                }
            }
            const idTop = this.frameTop;
            if (idTop != null) this.drawTopIds(f, ips, idTop);
            ipass.finish();
        }

        // --- P3: outline + sRGB encode (scene_view.as `outline`) -----------
        const encodedView = this.slotTarget(vb, pxW, pxH, POST_FORMAT, 1).view;
        writeOutlineUniform(
            this.blockView, outlineOn, ssaa / 2, encodeOutline, f.outlineSelect, f.outlineActive, straightOutline);
        vb.outline.update(0, this.blockBytes, OUTLINE_UNIFORM_SIZE);
        let obg = vb.outlineBg;
        if (obg == null || vb.outlineSrc !== outlineSrc || vb.outlineIds !== idView) {
            if (obg != null) this.frameGroups.push(obg);
            obg = new GPUBindGroup(
                pl.outlineLayout,
                [new GPUBindGroupUBO(0, vb.outline)],
                [new GPUBindGroupTexture(1, outlineSrc), new GPUBindGroupTexture(2, idView)],
            );
            vb.outlineBg = obg;
            vb.outlineSrc = outlineSrc;
            vb.outlineIds = idView;
        }
        this.postPass(encodedView, pl.outline, obg, "hedra outline");

        // --- P4: downsample + the overlay (labels and axis gizmo) ----------
        let overlay: GpuImage? = null;
        const ovImg = f.overlay;
        if (ovImg != null) overlay = this.keptOverlay(vb, ovImg);
        const out = this.slotTarget(vb, width, height, POST_FORMAT, 1);
        const ovView = overlay != null ? overlay.view : this.dummy.view;
        // A transparent frame's texels are straight alpha: a plain box
        // average pulls a partly covered texel toward the empty (0, 0, 0, 0)
        // ones beside it and darkens every edge, so its SSAA downsample
        // averages colour by alpha (a copy at factor 1 needs nothing).
        writeComposeUniform(this.blockView, 0, 0, width, height, ssaa, overlay != null, false, transparent && ssaa > 1);
        vb.compose.update(0, this.blockBytes, COMPOSE_UNIFORM_SIZE);
        let cbg = vb.composeBg;
        if (cbg == null || vb.composeSrc !== encodedView || vb.composeOverlay !== ovView) {
            if (cbg != null) this.frameGroups.push(cbg);
            cbg = new GPUBindGroup(
                pl.composeLayout,
                [new GPUBindGroupUBO(0, vb.compose)],
                [new GPUBindGroupTexture(1, encodedView), new GPUBindGroupTexture(2, ovView)],
            );
            vb.composeBg = cbg;
            vb.composeSrc = encodedView;
            vb.composeOverlay = ovView;
        }
        this.fullScreen(out.view, false, true, 0, 0, 0, 0, pl.compose, cbg, "hedra compose");
        // Milestone 48: a skinned item a pass drew unskinned.
        const lastPs = this.ps;
        if (lastPs != null) this.skinRefused(lastPs);
        let img = vb.image;
        if (img == null) {
            img = new GpuImage(out.texture, out.view, width, height);
            vb.image = img;
        } else {
            img.texture = out.texture;
            img.view = out.view;
            img.width = width;
            img.height = height;
        }
        let result = vb.result;
        if (result == null) {
            result = Result.okv<GpuImage>(img);
            vb.result = result;
        }
        return result;
    }

    // The main pass's surfaces (and a capture view's): one draw per
    // object, or per material range (opaque and masked first, blended after
    // with depth writes off); an instanced item draws every instance with
    // each. The top pass after them. Milestone 62: `phase` PHASE_ALL draws
    // all of it (every frame whose main pass is drawn in one); a split one
    // draws PHASE_OPAQUE in its first half (the opaque and masked ranges
    // but those that refract: rangeRefracts) and PHASE_LATE in its second
    // (those that refract, in item order, with the opaque pipelines, then
    // the blended ranges and the top pass as PHASE_ALL draws them), so that
    // every range is drawn once, in the order a frame without the effects
    // draws it but for the glass.
    private drawSurfaces(f: RenderFrame, ps: PassState, ip: InstancedPipelines?, phase: i32 = PHASE_ALL): void {
        const items = f.items;
        const main = this.cull.main;
        const pl = this.active;
        const pass = ps.pass;
        const defaultGroup = this.materials.defaultGroup;
        const drawSurfaces = f.drawSurfaces;
        const materialMode = f.materialMode;
        if (drawSurfaces && !materialMode) {
            if (phase != PHASE_LATE) {
                ps.surfacePipeline(pl.surface);
                for (let i = 0; i < items.length; i++) {
                    if (main[i] != CULL_DRAWN) continue;
                    const d = items[i];
                    const g = d.mesh;
                    if (g == null || this.onTop(d)) continue;
                    ps.item(d);
                    const b = buffersOf(g);
                    const tris = b != null ? b.tris : null;
                    const ib = b != null ? b.indices : null;
                    const inst = d.instances;
                    const ibuf = inst != null && ip != null ? instanceGpu(inst) : null;
                    if (tris == null || ib == null || (inst != null && ibuf == null)) {
                        this.missedDraws += mainDraws(f, d);
                        continue;
                    }
                    let copies: u32 = 1;
                    if (inst != null && ip != null && ibuf != null) {
                        ps.useSurface(ip.surface);
                        pass.setVertexBuffer(1, ibuf);
                        copies = inst.count;
                    } else {
                        ps.useSurface(pl.surface);
                    }
                    ps.object(d.slot);
                    pass.setVertexBuffer(0, tris);
                    pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                    pass.drawIndexed(lodCount(g, d.lod), copies, lodFirst(g, d.lod));
                    this.madeDraws++;
                }
            }
            const tp = this.frameTop;
            if (tp != null && phase != PHASE_OPAQUE) this.drawTop(f, ps, tp);
        } else if (drawSurfaces) {
            const vb = ps.vb;
            // (milestone 62: the ranges that refract are told apart only in
            // a split frame's halves)
            const plan = this.framePost;
            const refraction = plan.refraction && phase != PHASE_ALL;
            for (let bp = 0; bp < 2; bp++) {
                const blendPass = bp == 1;
                if (blendPass && phase == PHASE_OPAQUE) break;
                // (the second half's first loop draws the ranges that refract
                // alone: none without the refraction)
                const late = !blendPass && phase == PHASE_LATE;
                if (late && !refraction) continue;
                // (milestone 61: the blended ranges in their material's
                // render_priority order, when a frame has one but 0)
                if (blendPass && this.framePriority) {
                    this.drawBlended(f, ps, ip);
                    continue;
                }
                const plain = blendPass ? pl.surfaceBlend : pl.surface;
                ps.surfacePipeline(plain);
                // Milestone 67 (order.as, prepass.as): the opaque ranges in
                // the view's order, when drawView gathered it.
                if (!blendPass && !late && this.ordered) {
                    this.drawOpaqueOrdered(f, ps, ip);
                    continue;
                }
                for (let i = 0; i < items.length; i++) {
                    if (main[i] != CULL_DRAWN) continue;
                    const d = items[i];
                    const g = d.mesh;
                    if (g == null || this.onTop(d)) continue;
                    if (late && !this.itemRefracts(f, d)) continue;
                    ps.item(d);
                    const b = buffersOf(g);
                    const tris = b != null ? b.tris : null;
                    const ib = b != null ? b.indices : null;
                    const inst = d.instances;
                    const ibuf = inst != null && ip != null ? instanceGpu(inst) : null;
                    if (tris == null || ib == null || (inst != null && ibuf == null)) {
                        // (counted once: by the first loop of the whole
                        // pass, or of its first half)
                        if (!blendPass && phase != PHASE_LATE) this.missedDraws += mainDraws(f, d);
                        continue;
                    }
                    // A lightmapped item (milestone 19) draws every range
                    // with the lightmap pipelines, its lightmap coordinates
                    // and UV set 1 bound after the vertices.
                    const lm = this.bakedDraw(f, d);
                    let copies: u32 = 1;
                    if (inst != null && ip != null && ibuf != null) {
                        ps.useSurface(blendPass ? ip.surfaceBlend : ip.surface);
                        pass.setVertexBuffer(1, ibuf);
                        copies = inst.count;
                    } else {
                        ps.useSurface(plain);
                    }
                    ps.object(d.slot);
                    pass.setVertexBuffer(0, tris);
                    pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                    for (let k = 0; k < g.ranges.length; k++) {
                        const key = d.materials[k];
                        if (blends(f, key) != blendPass || !rangeDrawn(d, k)) continue;
                        // (milestone 62: the first half leaves out the ranges
                        // that refract, the second draws them alone)
                        if (refraction && !blendPass && !rangeInPhase(f, plan, key, phase)) continue;
                        // Milestone 61: a ShaderMaterial whose module is
                        // ready draws with it; else its fallback, below
                        // (but a next pass's: see nextPassWithout; culling
                        // counted it, so it is a draw not made:
                        // drawCountError).
                        if (this.nextPassWithout(f, d, key)) {
                            this.missedDraws++;
                            continue;
                        }
                        if (this.customFor(key) != null) {
                            const drawn = this.customDraw(pass, CUSTOM_PASS_MAIN, key, d, k, vb, ip);
                            if (drawn != null) {
                                ps.current = drawn;
                                this.madeDraws++;
                                this.customDraws++;
                                continue;
                            }
                            if (d.nextPassOf >= 0) {
                                this.missedDraws++;
                                continue;
                            }
                        }
                        // An extended material switches to its pipeline
                        // (and the next plain range back): a frame without
                        // one never switches.
                        const instanced = inst != null && ip != null && ibuf != null;
                        const es = this.extSet(key, instanced);
                        let want: GPUPipeline = blendPass ? pl.surfaceBlend : pl.surface;
                        if (instanced && ip != null) want = blendPass ? ip.surfaceBlend : ip.surface;
                        if (es != null) want = blendPass ? es.surfaceBlend : es.surface;
                        if (lm != null) want = lm.pick(blendPass, this.isExt(key));
                        // Milestone 67: the range's pipeline, its specialised
                        // variant's when ready (useRangePipeline); the item's
                        // buffers bound again with a new one.
                        if (this.useRangePipeline(f, ps, d, key, want, instanced, lm != null, blendPass, false)) {
                            ps.object(d.slot);
                            pass.setVertexBuffer(0, tris);
                            if (instanced && ibuf != null) pass.setVertexBuffer(1, ibuf);
                            pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                        }
                        if (lm != null) {
                            this.bindLightmapUvs(pass, g);
                        } else if (es != null && !this.bindUv1(pass, g, ps.uv1After(instanced))) {
                            continue;
                        }
                        ps.setMaterial(this.groupOf(key));
                        pass.drawIndexed(lodRangeCount(g, d.lod, k), copies, lodRangeFirst(g, d.lod, k));
                        this.madeDraws++;
                        if (late) this.refractionDrawCount++;
                    }
                }
            }
            const tp = this.frameTop;
            if (tp != null && phase != PHASE_OPAQUE) this.drawTop(f, ps, tp);
            ps.setMaterial(defaultGroup);
        }
    }

    // Milestone 67: binds the main pass's pipeline for range material `key`
    // of item `d` (`want`, the ubershader's, of the draw's kind: instanced,
    // lightmapped `baked`, blended `blend`), or its specialised variant's
    // when its key's module is ready and `uber` is not set (a range the
    // depth prepass drew with the ubershader: its main pass draws with the
    // same module); true when the pipeline bound changed (its item's
    // buffers are then bound again).
    private useRangePipeline(
        f: RenderFrame, ps: PassState, d: DrawItem, key: i64, want: GPUPipeline, instanced: bool, baked: bool, blend: bool,
        uber: bool,
    ): bool {
        // Milestone 67 (gpu/variants.as; these lines are the
        // specialisation's): the range's specialised variant of `want`,
        // when its key's module is ready (null: `want`, the ubershader's,
        // as before).
        const skinnedDraw = ps.skin != null;
        const vp = uber ? null : this.variants.pick(this.active, this.variantSource(), this.materials, f, d, key,
            variantKindOf(instanced, skinnedDraw, baked), this.isExt(key), blend);
        if (vp != null) {
            if (ps.current === vp) return false;
            ps.useVariant(vp, skinnedDraw);
            return true;
        }
        // (the item's own pipeline for `want`: a skinned item's is its
        // skinned counterpart, which a plain item's `want` bound before it
        // is not)
        if (ps.surfaceBound(want)) return false;
        ps.useSurface(want);
        return true;
    }

    // Milestone 67 (order.as, prepass.as): the opaque ranges the main
    // pass's first loop draws in this view (in one pass, or in a split
    // frame's first half: every opaque and masked range but those that
    // refract), each with the class of its pipeline (opaqueClass), its
    // material and its item's depth along the view, into `order`, sorted
    // when `sorted` (else kept in item and range order, today's); a next
    // pass's pinned after every other, in item order (it draws its owner's
    // surface again, which it must follow). With `prepass`, each range the
    // depth prepass may draw is marked in `prepassed` (rangeInDepthPrepass).
    // An item without its buffers is counted as the loop counts it (not
    // drawable: drawCountError). Allocates nothing once the order has held
    // as many ranges.
    private gatherOpaque(
        f: RenderFrame, vb: ViewBuffers, post: PostPlan, ip: InstancedPipelines?, prepass: bool, sorted: bool,
    ): void {
        const order = this.order;
        order.clear();
        const items = f.items;
        const main = this.cull.main;
        const phase = post.split ? PHASE_OPAQUE : PHASE_ALL;
        const refraction = post.refraction && phase != PHASE_ALL;
        const cam = f.camera;
        const eye = cam.eye;
        let fx = cam.target.x - eye.x;
        let fy = cam.target.y - eye.y;
        let fz = cam.target.z - eye.z;
        const len = Mathf.sqrt(fx * fx + fy * fy + fz * fz);
        if (len > 0) {
            fx /= len;
            fy /= len;
            fz /= len;
        }
        const flags = this.prepassed;
        this.prepassable = 0;
        for (let i = 0; i < items.length; i++) {
            if (i >= main.length || unchecked(main[i]) != CULL_DRAWN) continue;
            const d = unchecked(items[i]);
            const g = d.mesh;
            if (g == null || this.onTop(d)) continue;
            const b = buffersOf(g);
            const tris = b != null ? b.tris : null;
            const ib = b != null ? b.indices : null;
            const inst = d.instances;
            const ibuf = inst != null && ip != null ? instanceGpu(inst) : null;
            if (b == null || tris == null || ib == null || (inst != null && ibuf == null)) {
                this.missedDraws += mainDraws(f, d);
                continue;
            }
            let depth: f32 = NaN;
            if (d.hasBounds) {
                const bb = d.bounds;
                const cx = (bb.min.x + bb.max.x) * 0.5 - eye.x;
                const cy = (bb.min.y + bb.max.y) * 0.5 - eye.y;
                const cz = (bb.min.z + bb.max.z) * 0.5 - eye.z;
                depth = cx * fx + cy * fy + cz * fz;
            }
            const instanced = inst != null && ip != null && ibuf != null;
            const baked = this.bakedDraw(f, d) != null;
            const skins = vb.skinBySlot;
            const skinned = inst == null && <i32>d.slot < skins.length && unchecked(skins[<i32>d.slot]) != null;
            for (let k = 0; k < g.ranges.length; k++) {
                const key = d.materials[k];
                if (blends(f, key) || !rangeDrawn(d, k)) continue;
                if (refraction && !rangeInPhase(f, post, key, phase)) continue;
                const pipeline = d.nextPassOf >= 0 ? ORDER_PINNED : this.opaqueClass(key, instanced, baked, skinned);
                if (!order.add(i, k, depth, pipeline, key)) continue;
                const n = order.count - 1;
                if (n == flags.length) flags.push(0);
                // (a skinned item is left to the main pass: Metal compiles
                // the skinned vertex entry of a pipeline with no fragment
                // stage into positions a rounding apart from the full
                // pipeline's, measured on the skeleton sample: 2.4 % of its
                // pixels lost the depth test)
                const eligible = prepass && !skinned
                    && rangeInDepthPrepass(f, d, k, key, b.hiddenFaces, this.customFor(key) != null, lateRange(f, post, key));
                unchecked(flags[n] = eligible ? 1 : 0);
                if (eligible) this.prepassable++;
            }
        }
        order.sort(prepass, sorted);
    }

    // Milestone 67: the class of the pipeline range material `key` of an
    // item draws with in the main pass, for the opaque order's key
    // (order.as: ORDER_PIPELINE_BITS bits): a ShaderMaterial's module (64
    // up, by its place among the renderer's), else the ubershader's entries
    // by vertex kind and extended material (1 to 8).
    private opaqueClass(key: i64, instanced: bool, baked: bool, skinned: bool): u32 {
        const cp = this.customFor(key);
        if (cp != null) {
            const at = this.customs.indexOf(cp);
            return 64 + <u32>(max<i32>(at, 0) & 63);
        }
        return 1 + variantKindOf(instanced, skinned, baked) * 2 + (this.isExt(key) ? 1 : 0);
    }

    // Milestone 67 (prepass.as): the depth prepass of the view (pass label
    // `hedra prepass`) into `depth`, the main pass's depth target, cleared
    // first: the ranges of `order` gatherOpaque marked, in its order, each
    // through the depth pipeline of the module its main pass draws with
    // (its variant's, gpu/variants.as pickDepth, else the ubershader's,
    // Pipelines.prepassPipeline) and the same vertex entry and buffers;
    // `prepassed` then says, by place in the order, which were drawn and
    // with which module (1 the ubershader, 2 the variant; 0 left to the
    // main pass alone). Group 0 is `globals`, the main pass's. The draws
    // made.
    private depthPrepass(
        f: RenderFrame, vb: ViewBuffers, ip: InstancedPipelines?, depth: GPUTextureView, globals: GPUBindGroup,
    ): i32 {
        const order = this.order;
        const flags = this.prepassed;
        const pl = this.active;
        const items = f.items;
        const desc = this.prepassDesc;
        desc.label = "hedra prepass";
        desc.depthView = depth;
        desc.depthLoadOp = LoadOp.clear;
        desc.depthStoreOp = StoreOp.store;
        desc.depthClearValue = 1.0;
        const ps = this.passState(this.gpu.canvas.beginRenderPass(desc, this.passWrapper), vb, this.materials.defaultGroup);
        ps.globals = globals;
        const pass = ps.pass;
        const source = this.variantSource();
        let drawn = 0;
        let boundItem = -1;
        let started = -1;
        for (let n = 0; n < order.count; n++) {
            const seq = keySeq(unchecked(order.keys[n]));
            if (unchecked(flags[seq]) == 0) continue;
            unchecked(flags[seq] = 0);
            const i = unchecked(order.items[seq]);
            const k = unchecked(order.ranges[seq]);
            const d = unchecked(items[i]);
            const g = d.mesh!;
            const b = buffersOf(g)!;
            const tris = b.tris!;
            const ib = b.indices!;
            const inst = d.instances;
            const ibuf = inst != null && ip != null ? instanceGpu(inst) : null;
            const instanced = inst != null && ip != null && ibuf != null;
            if (started != i) {
                ps.item(d);
                started = i;
            }
            const key = d.materials[k];
            const lm = this.bakedDraw(f, d);
            const es = this.extSet(key, instanced);
            const skinnedDraw = ps.skin != null;
            // (the main pass's pipeline, whose skinned counterpart must be
            // there: an item the host would draw unskinned is left to it)
            let want: GPUPipeline = pl.surface;
            if (instanced && ip != null) want = ip.surface;
            if (es != null) want = es.surface;
            if (lm != null) want = lm.pick(false, this.isExt(key));
            if (skinnedDraw && pl.skinnedOf(want) == null) continue;
            const kind = variantKindOf(instanced, skinnedDraw, lm != null);
            // (a lightmapped range's variant entry is the main pass's, whose
            // fragment entry the material's extension chooses: the same
            // flag as useRangePipeline's, so that the pipelines the prepass
            // makes first are those the main pass then binds)
            const ext = lm != null ? this.isExt(key) : es != null;
            let p = this.variants.pickDepth(pl, source, this.materials, f, d, key, kind, ext);
            const byVariant = p != null;
            if (p == null) p = pl.prepassPipeline(kind, ext);
            if (p == null) continue;
            let changed = false;
            if (ps.current !== p) {
                ps.useVariant(p, skinnedDraw);
                changed = true;
            }
            if (changed || boundItem != i) {
                ps.object(d.slot);
                pass.setVertexBuffer(0, tris);
                if (instanced && ibuf != null) pass.setVertexBuffer(1, ibuf);
                pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                boundItem = i;
            }
            if (lm != null) {
                this.bindLightmapUvs(pass, g);
            } else if (ext && !this.bindUv1(pass, g, ps.uv1After(instanced))) {
                continue;
            }
            ps.setMaterial(this.groupOf(key));
            pass.drawIndexed(lodRangeCount(g, d.lod, k), inst != null ? inst.count : 1, lodRangeFirst(g, d.lod, k));
            unchecked(flags[seq] = byVariant ? 2 : 1);
            drawn++;
        }
        pass.finish();
        return drawn;
    }

    // Milestone 67 (order.as): the opaque ranges of `order` in its order,
    // each drawn as the main pass's first loop draws it (a ShaderMaterial's
    // with its module, a next pass's without one left out, the extended,
    // instanced, lightmapped and skinned ones with their pipelines and
    // buffers), its item's object block and buffers bound when the item or
    // the pipeline changes. A range the prepass drew with the ubershader is
    // drawn with it again (useRangePipeline's `uber`).
    private drawOpaqueOrdered(f: RenderFrame, ps: PassState, ip: InstancedPipelines?): void {
        const order = this.order;
        const flags = this.prepassed;
        const items = f.items;
        const pl = this.active;
        const pass = ps.pass;
        const vb = ps.vb;
        let boundItem = -1;
        let started = -1;
        for (let n = 0; n < order.count; n++) {
            const seq = keySeq(unchecked(order.keys[n]));
            const i = unchecked(order.items[seq]);
            const k = unchecked(order.ranges[seq]);
            const d = unchecked(items[i]);
            const g = d.mesh!;
            const b = buffersOf(g)!;
            const tris = b.tris!;
            const ib = b.indices!;
            const inst = d.instances;
            const ibuf = inst != null && ip != null ? instanceGpu(inst) : null;
            if (started != i) {
                ps.item(d);
                started = i;
            }
            const key = d.materials[k];
            if (this.nextPassWithout(f, d, key)) {
                this.missedDraws++;
                continue;
            }
            if (this.customFor(key) != null) {
                const drawn = this.customDraw(pass, CUSTOM_PASS_MAIN, key, d, k, vb, ip);
                if (drawn != null) {
                    ps.current = drawn;
                    boundItem = -1;
                    this.madeDraws++;
                    this.customDraws++;
                    continue;
                }
                if (d.nextPassOf >= 0) {
                    this.missedDraws++;
                    continue;
                }
            }
            const instanced = inst != null && ip != null && ibuf != null;
            const lm = this.bakedDraw(f, d);
            const es = this.extSet(key, instanced);
            let want: GPUPipeline = pl.surface;
            if (instanced && ip != null) want = ip.surface;
            if (es != null) want = es.surface;
            if (lm != null) want = lm.pick(false, this.isExt(key));
            const uber = seq < flags.length && unchecked(flags[seq]) == 1;
            if (this.useRangePipeline(f, ps, d, key, want, instanced, lm != null, false, uber) || boundItem != i) {
                ps.object(d.slot);
                pass.setVertexBuffer(0, tris);
                if (instanced && ibuf != null) pass.setVertexBuffer(1, ibuf);
                pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                boundItem = i;
            }
            if (lm != null) {
                this.bindLightmapUvs(pass, g);
            } else if (es != null && !this.bindUv1(pass, g, ps.uv1After(instanced))) {
                continue;
            }
            ps.setMaterial(this.groupOf(key));
            const copies: u32 = instanced && inst != null ? inst.count : 1;
            pass.drawIndexed(lodRangeCount(g, d.lod, k), copies, lodRangeFirst(g, d.lod, k));
            this.madeDraws++;
        }
    }

    // Milestone 62: whether item `d` has a range that refracts the screen
    // (rangeRefracts) to draw in the view being drawn.
    private itemRefracts(f: RenderFrame, d: DrawItem): bool {
        const g = d.mesh;
        if (g == null) return false;
        const plan = this.framePost;
        for (let k = 0; k < g.ranges.length; k++) {
            if (rangeDrawn(d, k) && rangeRefracts(f, plan, d.materials[k])) return true;
        }
        return false;
    }

    // Milestone 61: the main pass's blended ranges in a stable order of
    // their material's render_priority, lower first (Godot's: a higher one
    // is drawn over), ties in item and range order (today's): each range
    // drawn alone, binding what it reads. Allocates nothing once the lists
    // have held as many ranges.
    private drawBlended(f: RenderFrame, ps: PassState, ip: InstancedPipelines?): void {
        const items = f.items;
        const order = this.blendItems;
        const ranges = this.blendRanges;
        orderBlendedRanges(f, this.cull.main, this.frameTop != null, order, ranges, this.blendKeys);
        const pl = this.active;
        const pass = ps.pass;
        ps.surfacePipeline(pl.surfaceBlend);
        for (let n = 0; n < order.length; n++) {
            const i = unchecked(order[n]);
            const k = unchecked(ranges[n]);
            const d = items[i];
            const g = d.mesh!;
            ps.item(d);
            const key = d.materials[k];
            const b = buffersOf(g);
            const tris = b != null ? b.tris : null;
            const ib = b != null ? b.indices : null;
            const inst = d.instances;
            const ibuf = inst != null && ip != null ? instanceGpu(inst) : null;
            // (counted missed by the opaque phase's loop)
            if (tris == null || ib == null || (inst != null && ibuf == null)) continue;
            if (this.nextPassWithout(f, d, key)) {
                this.missedDraws++;
                continue;
            }
            if (this.customFor(key) != null) {
                const drawn = this.customDraw(pass, CUSTOM_PASS_MAIN, key, d, k, ps.vb, ip);
                if (drawn != null) {
                    ps.current = drawn;
                    this.madeDraws++;
                    this.customDraws++;
                    continue;
                }
                if (d.nextPassOf >= 0) {
                    this.missedDraws++;
                    continue;
                }
            }
            const instanced = inst != null && ip != null && ibuf != null;
            const es = this.extSet(key, instanced);
            const lm = this.bakedDraw(f, d);
            let want: GPUPipeline = pl.surfaceBlend;
            if (instanced && ip != null) want = ip.surfaceBlend;
            if (es != null) want = es.surfaceBlend;
            if (lm != null) want = lm.pick(true, this.isExt(key));
            ps.useSurface(want);
            ps.object(d.slot);
            pass.setVertexBuffer(0, tris);
            if (instanced && ibuf != null) pass.setVertexBuffer(1, ibuf);
            pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
            if (lm != null) {
                this.bindLightmapUvs(pass, g);
            } else if (es != null && !this.bindUv1(pass, g, ps.uv1After(instanced))) {
                continue;
            }
            ps.setMaterial(this.groupOf(key));
            pass.drawIndexed(lodRangeCount(g, d.lod, k), instanced && inst != null ? inst.count : 1, lodRangeFirst(g, d.lod, k));
            this.madeDraws++;
        }
    }

    // The frame's reflection probes (milestone 20, see the header): the
    // schedule's uploads and live captures, then the frame's probe block
    // (`writeProbeBlock` writes it into the view's slot). A frame without
    // probes (or outside the lit shading) does nothing but leave the block
    // at zeros. A device without half-float targets, or a host that refuses
    // the pipelines or the atlas, draws the frame without its probes and
    // says so.
    private probePasses(f: RenderFrame): void {
        const gp = this.probes;
        const s = gp.schedule;
        gp.captures = 0;
        gp.uploads = 0;
        const n = s.plan(f);
        const set = f.probes;
        if (n == 0 || set == null) {
            gp.clearUniform();
            return;
        }
        let pp: ProbePipelines? = null;
        if (!this.halfFloat()) {
            this.warnings.push(PROBE_HALF_FLOAT_WARNING);
        } else {
            pp = this.pipelines.probePipelines();
            if (pp == null) {
                this.warnings.push(PROBE_PIPELINE_WARNING);
            } else if (!gp.ensureAtlas()) {
                this.warnings.push(PROBE_ATLAS_WARNING);
                pp = null;
            }
        }
        if (pp == null) {
            s.forget();
            gp.clearUniform();
            return;
        }
        const canvas = this.gpu.canvas;
        for (let r = 0; r < n; r++) {
            const a = s.actions[r];
            const p = set.list[r];
            if (a == PROBE_ACTION_UPLOAD) {
                if (!gp.upload(r, p.cube, pp, canvas)) s.failed(r);
            } else if (a == PROBE_ACTION_CAPTURE) {
                if (!this.captureProbe(f, p, r, pp)) s.failed(r);
            }
        }
        gp.fillUniform(set);
    }

    // The frame's probe block into the view's slot: written when the frame
    // has probes, and zeros written once when the slot held a block and the
    // frame has none (a slot that never held one keeps its zeros, written
    // by no frame of Hedra).
    private writeProbeBlock(vb: ViewBuffers): void {
        const u = this.probes.uniform;
        if (u.counts.x == 0 && !vb.probeWritten) return;
        u.writeAt(this.blockView, 0);
        vb.probe.update(0, this.blockBytes, PROBE_UNIFORM_SIZE);
        vb.probeWritten = u.counts.x != 0;
    }

    // Milestone 34: the zero probe block into the view's slot, for a view
    // whose frame has no probes (a world of its own draws none of the main
    // world's), written once when the slot held a block.
    private writeZeroProbeBlock(vb: ViewBuffers): void {
        if (!vb.probeWritten) return;
        vb.probe.update(0, this.zeroProbe, PROBE_UNIFORM_SIZE);
        vb.probeWritten = false;
    }

    // Milestone 33: the frame's decal block into the view's slot, as
    // writeProbeBlock writes the probes': written when the frame has
    // decals, its header and its pool's entries alone (the shader reads
    // none past the count: DecalUniform.writeUsedAt), and a zero header
    // written once when the slot held a block and the frame has none.
    private writeDecalBlock(vb: ViewBuffers): void {
        const gd = this.decals;
        const u = gd.uniform;
        if (u.counts.x == 0 && !vb.decalWritten) return;
        const bytes = u.writeUsedAt(gd.bytesView, 0);
        vb.decal.update(0, gd.bytes, bytes);
        vb.decalWritten = u.counts.x != 0;
    }

    // Milestone 37: the view's fog block into its slot (gpu/fog.as): the
    // header and the pool's entries alone when the view draws fog (the
    // shader reads no entry past the count: FogUniform.writeUsedAt), and
    // counts of zeros written once when the slot held a block and the view
    // has none.
    private writeFogBlock(vb: ViewBuffers, f: RenderFrame, sky: SkyUniform?): void {
        const gf = this.fog;
        const bytes = gf.write(f, sky);
        if (bytes == 0) {
            this.writeZeroFogBlock(vb);
            return;
        }
        vb.fog.update(0, gf.bytes, bytes);
        vb.fogWritten = true;
    }

    private writeZeroFogBlock(vb: ViewBuffers): void {
        if (!vb.fogWritten) return;
        vb.fog.update(0, this.fog.zero, 16);
        vb.fogWritten = false;
    }

    // Milestone 34: the viewports of `f` the schedule picks, each drawn as a
    // view of its own into its viewport slot and finished into its targets
    // (gpu/viewports.as's header, and this file's), in the frame's drawing
    // order; then the main camera's decals prepared again, as the views
    // left the items' lists theirs, and the decal layers of the pictures
    // drawn copied again (GpuDecals.liveChanged), so that a decal shows
    // this frame's picture as a material does. A viewport drawn already in
    // this host frame (a second view of the frame: a sheet's tile) is not
    // drawn again. Allocates nothing once each viewport has drawn.
    private viewportPasses(f: RenderFrame): void {
        const gv = this.viewports;
        const binder = this.materials;
        gv.keepLive(f, binder);
        const s = gv.schedule;
        const n = s.plan(f);
        let drew = false;
        for (let c = 0; c < n; c++) {
            const k = unchecked(s.chosen[c]);
            const d = f.viewports[k];
            if (!d.camera || !d.drawable || gv.drewThisFrame(k)) continue;
            const vf = d.frame;
            this.decals.prepare(vf, binder, this.gpu, this.warnings, false);
            const own = gv.ownIbl(k, f);
            const maps = gv.ownEnvironment(k);
            // (milestone 59: its own camera's pool of lights, which its
            // shadows are given out from)
            planLightPool(vf, vf.lightPlan);
            const plan = planShadowsInto(vf, this.shadowAtlasSize, this.viewportShadowPlan);
            const r = own != null && maps != null
                ? this.drawView(vf, plan, this.nextViewportSlot(k), own, maps)
                : this.drawView(vf, plan, this.nextViewportSlot(k), this.ibl, this.environment);
            const img = r.value;
            if (gv.finish(d, img.view, img.width, img.height, this.gpu, binder, this.warnings)) {
                // (a decal's layer of its picture was copied before it
                // drew: copied again by the next prepare, the next
                // viewport's or the main camera's below)
                const held = gv.at(k);
                if (held != null && f.decals.length > 0) this.decals.liveChanged(held.keys);
            }
            s.drew(k);
            drew = true;
        }
        gv.countLive();
        if (drew && f.decals.length > 0) this.decals.prepare(f, binder, this.gpu, this.warnings, false);
    }

    // A live capture of probe `p` of frame `f` into atlas row `row` (see
    // the header): six views, each placed into the scratch chain, then the
    // chain halved and prefiltered into the row. False when the host
    // refused the capture's targets.
    private captureProbe(f: RenderFrame, p: ReflectionProbeDesc, row: i32, pp: ProbePipelines): bool {
        const gp = this.probes;
        if (!gp.ensureCaptureTargets(pp, this.pipelines.samples)) return false;
        const canvas = this.gpu.canvas;
        const cf = gp.capture;
        cf.setUp(f, p);
        for (let face = 0; face < 6; face++) {
            cf.face(p, face);
            this.captureView(cf.frame, p, this.nextCaptureSlot());
            gp.place(face, pp, canvas);
        }
        gp.finish(row, pp, canvas);
        return true;
    }

    // One view of a live capture: the capture frame `c` (gpu/probes.as
    // ProbeCaptureFrame, the main frame's items) drawn as renderFrame draws
    // a lit frame's main pass, with only the items probe `p` captures, its
    // shadows when it enables them, and lit() keeping HDR colour (the post
    // plan's toneInPost: ENV_HDR, linear at exposure 1), into the capture's
    // picture; no overlay, line, point, id, outline, post or compose pass.
    // Milestone 59: the capture's pool of lights is the one seen every way
    // from the probe's origin (light_select.as planLightPoolAround: no
    // frustum, the nearest kept past 64), and the main frame's items, which
    // the capture shares, take their lists from it until the main view
    // gives them its own (drawView).
    private captureView(c: RenderFrame, p: ReflectionProbeDesc, vb: ViewBuffers): void {
        const gp = this.probes;
        // Milestone 67: a view drawn since (renderFrameReusing), drawn with
        // the renderer's own pipelines (the capture's targets are
        // rgba16float at its samples, whatever the frame's quality), in
        // item order with no prepass.
        this.viewSerial++;
        this.active = this.pipelines;
        this.ordered = false;
        planLightPoolAround(c, c.camera.eye, c.lightPlan);
        const plan = planShadowsInto(c, this.shadowAtlasSize, gp.shadowPlan);
        this.runCull(c, plan);
        leaveOutUncaptured(p, c.items, this.cull);
        // (a viewport's texture the capture shows is used, as a view's:
        // a when_visible viewport seen only in a reflection keeps drawing)
        const gv = this.viewports;
        if (gv.active()) gv.noteUsed(c, this.cull.main, this.decals.plan);
        const ibl = this.skyLight(c);
        this.uploadLightmap(c);
        this.refreshGroups(vb, this.environment);
        // (the top and lightmap pipelines tried first: drawView says why)
        this.frameTop = this.topping(c);
        this.frameLightmap = this.lightmapping(c);
        lightItems(c, this.frameLightmap != null, this.cull.shaded);
        // (milestone 37: a capture draws no fog, so its items, which the
        // main view's share, are seen through none until the main view
        // chooses theirs)
        clearFrameFog(c);
        this.uploadObjects(vb, c);
        // (the capture's items paint the main view's decals: the same
        // lists and block)
        this.writeDecalBlock(vb);
        this.writeZeroFogBlock(vb);
        if (c.materialMode) this.bindMaterials(c);
        this.prepareCustom(c);
        const ip = this.instancing(c);
        this.frameExt = this.extending(c);
        let shadows: ShadowPipelines? = null;
        let atlas: GPUTextureView? = null;
        if (plan.any()) {
            shadows = this.pipelines.shadowPipelines();
            if (shadows == null) {
                this.warnings.push(SHADOW_PIPELINE_WARNING);
            } else if (!this.ensureAtlas(plan.atlasSize)) {
                this.warnings.push(SHADOW_ATLAS_WARNING);
                shadows = null;
            } else {
                atlas = this.atlasTarget;
            }
        }
        const globals = frameGlobalsInto(c, false, this.globalsBlock);
        globals.writeAt(this.blockView, 0);
        vb.globals.update(0, this.blockBytes, GLOBALS_SIZE);
        this.writeCustomGlobals(vb, globals, c, false);
        if (shadows != null) {
            this.uploadLit(vb, c, plan, gp.capturePost);
            plan.uniform.writeAt(this.blockView, 0);
            vb.shadow.update(0, this.blockBytes, SHADOW_UNIFORM_SIZE);
        } else {
            this.uploadLit(vb, c, null, gp.capturePost);
        }
        skyUniformInto(c, ibl, this.skyBlock).writeAt(this.blockView, 0);
        vb.sky.update(0, this.blockBytes, SKY_UNIFORM_SIZE);
        let globalsBg = vb.globalsBg;
        const sampled = this.atlasSampled;
        this.customMap = null;
        this.customAo = null;
        if (shadows != null && atlas != null && sampled != null) {
            this.shadowPass(c, plan, vb, shadows, globals, ip, atlas);
            globalsBg = this.shadowGlobals(vb, sampled, shadows.compareSampler);
            this.customMap = sampled;
        }
        const color = this.mainColor;
        gp.captureColor(color);
        const desc = this.mainDesc;
        desc.label = "hedra probe capture";
        desc.depthView = gp.captureDepth();
        desc.depthLoadOp = LoadOp.clear;
        desc.depthStoreOp = StoreOp.discard;
        desc.depthClearValue = 1.0;
        const ps = this.passState(
            this.gpu.canvas.beginRenderPass(desc, this.passWrapper), vb, this.materials.defaultGroup);
        ps.globals = globalsBg;
        if (c.environment.sky) {
            ps.surfacePipeline(this.pipelines.sky);
            ps.object(0);
            ps.pass.draw(3);
        }
        this.drawSurfaces(c, ps, ip);
        ps.pass.finish();
    }

    // The frame draws a line or a point in the main pass (grid, edges,
    // extras, vertices, cursor): with the final pass, they then need the
    // overlay pass. A frame without (every CLI's `render` picture) keeps
    // one main pass.
    private hasOverlay(f: RenderFrame, lines: Array<InstanceBuffer>, points: Array<InstanceBuffer>): bool {
        if (f.worldLines.length > 0 || f.topLines.length > 0 || f.topPoints.length > 0) return true;
        if (lines.length > 0 || points.length > 0) return true;
        const main = this.cull.main;
        for (let i = 0; i < f.items.length; i++) {
            const d = f.items[i];
            if (main[i] != CULL_DRAWN || d.instances != null) continue;
            if (d.showEdges || d.showPoints) return true;
        }
        return false;
    }

    // The normal-depth pass (see the header) at the render size `pxW` x
    // `pxH`, for SSAO, the reflections and the depth of field (the plan's
    // `prepass`): over the main pass's items (shadows-only and culled ones
    // left out) as the main pass draws their ranges, but blended ranges left
    // out (they write no depth there either) and, milestone 62, with the
    // plan's `refraction`, the ranges that refract (rangeRefracts: they are
    // drawn after the screen texture is made, so nothing reflects them).
    // Two targets (pipelines.as normalDepthTargets): the view-space normal
    // and depth, and the surface's F0 and roughness, so every range binds
    // its own material (before milestone 62 only a masked one did: only a
    // cut-out needed its textures), and with the reflections an extended
    // one draws with the extended entry (fs_normal_depth_ext: its own F0;
    // without them, only a masked one, as before: the first target is the
    // same either way). Its views are `ndView` and `ndSurfaceView`.
    private normalDepthPass(
        f: RenderFrame, vb: ViewBuffers, pp: PostPipelines, ip: InstancedPipelines?, pxW: u32, pxH: u32, post: PostPlan,
    ): void {
        // (milestone 67: the slot's own targets, not the post pool's, so that
        // a picture drawn again finds them: KeptTarget)
        const ndView = this.keptTarget(vb.ndNormal, pxW, pxH, NORMAL_DEPTH_FORMAT, 1).view;
        const surfaceView = this.keptTarget(vb.ndSurface, pxW, pxH, SSR_SURFACE_FORMAT, 1).view;
        this.ndView = ndView;
        this.ndSurfaceView = surfaceView;
        const c = this.ndColor;
        c.view = ndView;
        c.resolveTarget = null;
        c.loadOp = LoadOp.clear;
        c.storeOp = StoreOp.store;
        c.clearR = 0;
        c.clearG = 0;
        c.clearB = 0;
        c.clearA = 0;
        // (roughness 1 where nothing is drawn: nothing to reflect)
        const sc = this.ndSurface;
        sc.view = surfaceView;
        sc.resolveTarget = null;
        sc.loadOp = LoadOp.clear;
        sc.storeOp = StoreOp.store;
        sc.clearR = 0;
        sc.clearG = 0;
        sc.clearB = 0;
        sc.clearA = 1;
        const desc = this.ndDesc;
        desc.label = "hedra normal-depth";
        desc.depthView = this.keptTarget(vb.ndDepth, pxW, pxH, DEPTH_FORMAT, 1).view;
        desc.depthLoadOp = LoadOp.clear;
        desc.depthStoreOp = StoreOp.discard;
        desc.depthClearValue = 1.0;
        const defaultGroup = this.materials.defaultGroup;
        const ps = this.passState(this.gpu.canvas.beginRenderPass(desc, this.passWrapper), vb, defaultGroup);
        const pass = ps.pass;
        const items = f.items;
        const main = this.cull.main;
        const extF0 = post.ssr;
        if (f.drawSurfaces) {
            ps.surfacePipeline(pp.normalDepth);
            for (let i = 0; i < items.length; i++) {
                if (main[i] != CULL_DRAWN) continue;
                const d = items[i];
                const g = d.mesh;
                // (an item without the depth test occludes nothing; nor,
                // milestone 61, a next pass: its owner's surface is the one)
                if (g == null || this.onTop(d) || d.nextPassOf >= 0) continue;
                ps.item(d);
                const b = buffersOf(g);
                if (b == null) continue;
                const tris = b.tris;
                const ib = b.indices;
                if (tris == null || ib == null) continue;
                const inst = d.instances;
                let copies: u32 = 1;
                if (inst != null) {
                    const ibuf = ip != null ? instanceGpu(inst) : null;
                    if (ip == null || ibuf == null) continue;
                    ps.useSurface(ip.normalDepth);
                    pass.setVertexBuffer(1, ibuf);
                    copies = inst.count;
                } else {
                    ps.useSurface(pp.normalDepth);
                }
                ps.object(d.slot);
                pass.setVertexBuffer(0, tris);
                pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                if (!f.materialMode) {
                    pass.drawIndexed(lodCount(g, d.lod), copies, lodFirst(g, d.lod));
                    continue;
                }
                for (let k = 0; k < g.ranges.length; k++) {
                    const key = d.materials[k];
                    if (!rangeInPrepass(f, post, key)) continue;
                    // (milestone 61: a ready ShaderMaterial's own normal and
                    // cut-out)
                    if (this.customFor(key) != null) {
                        const drawn = this.customDraw(pass, CUSTOM_PASS_NORMAL_DEPTH, key, d, k, vb, ip);
                        if (drawn != null) {
                            ps.current = drawn;
                            continue;
                        }
                    }
                    const es = masks(f, key) || (extF0 && this.isExt(key)) ? this.extSet(key, inst != null) : null;
                    let want: GPUPipeline = pp.normalDepth;
                    if (inst != null && ip != null) want = ip.normalDepth;
                    if (es != null) want = es.normalDepth;
                    if (ps.current !== want) {
                        ps.useSurface(want);
                        ps.object(d.slot);
                        pass.setVertexBuffer(0, tris);
                        if (inst != null && ip != null) {
                            const ibuf = instanceGpu(inst);
                            if (ibuf != null) pass.setVertexBuffer(1, ibuf);
                        }
                        pass.setIndexBuffer(ib, <u32>IndexFormat.uint32);
                    }
                    if (es != null && !this.bindUv1(pass, g, ps.uv1After(inst != null))) continue;
                    ps.setMaterial(this.groupOf(key));
                    pass.drawIndexed(lodRangeCount(g, d.lod, k), copies, lodRangeFirst(g, d.lod, k));
                }
            }
        }
        pass.finish();
    }

    // The SSAO passes (see the header) at the render size `pxW` x `pxH`,
    // after the normal-depth pass (`normalDepthPass`, whose first target is
    // `nd`): fs_ssao and fs_ssao_blur. The blurred occlusion's view.
    // Milestone 67: with the quality's ssao/half_size, fs_ssao traces at
    // half the size each side (rounded up) and fs_ssao_blur brings it back
    // to the render size (post_effects.wgsl POST_SSAO_HALF).
    private ssaoPasses(f: RenderFrame, vb: ViewBuffers, pp: PostPipelines, pxW: u32, pxH: u32, nd: GPUTextureView,
    ): GPUTextureView {
        const u = ssaoUniformInto(f, this.postU);
        const half = f.renderQuality.ssaoHalfSize;
        // (milestone 67: the slot's own targets, as the normal-depth pass's)
        const raw = this.keptTarget(vb.aoRaw, half ? (pxW + 1) >> 1 : pxW, half ? (pxH + 1) >> 1 : pxH, AO_FORMAT, 1).view;
        this.postPass(raw, pp.ssao, this.postGroup(vb, pp, u, nd, this.dummy.view, this.dummy.view), "hedra ssao");
        const blurred = this.keptTarget(vb.aoBlur, pxW, pxH, AO_FORMAT, 1).view;
        this.postPass(blurred, pp.ssaoBlur, this.postGroup(vb, pp, u, raw, nd, this.dummy.view), "hedra ssao blur");
        return blurred;
    }

    // The glow (with the plan's `glow`) and the final pass (see the
    // header), from the main pass's `resolve` and the overlay pass's layer
    // (null when the frame draws no line or point): the view of `graded`,
    // the finished picture as sRGB values at the render size `pxW` x `pxH`.
    private finalPasses(
        f: RenderFrame, vb: ViewBuffers, post: PostPlan, pp: PostPipelines, resolve: GPUTextureView,
        overlay: GPUTextureView?, pxW: u32, pxH: u32,
    ): GPUTextureView {
        // Without glow fs_post samples the 1 x 1 dummy, times weights of 0.
        let glow = this.dummy.view;
        if (post.glow) {
            const oneW = glowLevelSide(f.width, 1);
            const oneH = glowLevelSide(f.height, 1);
            const bright = this.postTarget(oneW, oneH, GLOW_FORMAT);
            this.postPass(
                bright, pp.glowBright,
                this.postGroup(vb, pp, glowBrightUniformInto(f, this.postU), resolve, this.dummy.view,
                    this.dummy.view), "hedra glow bright");
            // The levels are the mips of one texture (as Godot keeps them),
            // so fs_post binds one texture however many levels are drawn: a
            // group of the host holds at most 8 sampled textures. Level 1
            // blurs the bright pass; each later level the one before it,
            // halved by its horizontal pass.
            const chain = this.postChain(oneW, oneH, GLOW_FORMAT, <u32>post.glowLevels);
            let above = bright;
            for (let k = 1; k <= post.glowLevels; k++) {
                const across = this.postTarget(glowLevelSide(f.width, k), glowLevelSide(f.height, k), GLOW_FORMAT);
                this.postPass(
                    across, pp.glowBlurH,
                    this.postGroup(vb, pp, glowBlurUniformInto(f, k, false, this.postU), above, this.dummy.view,
                        this.dummy.view), "hedra glow blur");
                const down = chain.levels[k - 1];
                this.postPass(
                    down, pp.glowBlurV,
                    this.postGroup(vb, pp, glowBlurUniformInto(f, k, true, this.postU), across, this.dummy.view,
                        this.dummy.view), "hedra glow blur");
                above = down;
            }
            glow = chain.view;
        }
        const graded = this.postTarget(pxW, pxH, POST_FORMAT);
        const u = postFinalUniformInto(f, post, this.postU);
        let layer = this.dummy.view;
        if (overlay != null) {
            u.flags = U32x4(u.flags.x | POST_OVERLAY, u.flags.y, u.flags.z, u.flags.w);
            layer = overlay;
        }
        this.postPass(graded, pp.final, this.postGroup(vb, pp, u, resolve, layer, glow), "hedra final");
        return graded;
    }

    // The next post target of this view (a view of a one-sample render
    // target), kept from frame to frame: the n-th target a view asks for
    // is the n-th of the last view's when its size and format are the same
    // (a viewport's frames all are), else a new one replacing it, the old
    // released at the next `beginFrame`. Making a dozen targets every frame
    // cost about as much as drawing into them. Reusing one is safe: the
    // passes of later views and frames run after the passes recorded
    // before them, and no post target outlives its view (the picture the
    // view returns is not one).
    private postTarget(width: u32, height: u32, format: TextureFormat): GPUTextureView {
        return this.postChain(width, height, format, 1).view;
    }

    // `postTarget` with `mips` levels (a glow chain: glowLevelSize's sizes
    // are the mip sizes of level 1's).
    private postChain(width: u32, height: u32, format: TextureFormat, mips: u32): PostTarget {
        const pool = this.activePosts;
        const i = this.postCursor;
        this.postCursor++;
        if (i < pool.length) {
            const t = pool[i];
            if (t.width == width && t.height == height && t.format == format && t.mips == mips) return t;
            this.frameViews.push(t.view);
            if (t.mips > 1) {
                for (let k = 0; k < t.levels.length; k++) this.frameViews.push(t.levels[k]);
            }
            this.frameTextures.push(t.texture);
        }
        const d = new GPUTextureDesc();
        d.width = width;
        d.height = height;
        d.format = format;
        d.sampleCount = 1;
        d.renderTarget = true;
        d.numMipmaps = mips;
        const texture = new GPUTexture(d);
        const view = texture.view();
        const levels = new Array<GPUTextureView>();
        if (mips == 1) levels.push(view);
        else {
            for (let m: u32 = 0; m < mips; m++) {
                const vd = new GPUTextureViewDesc();
                vd.baseMipLevel = m;
                vd.mipCount = 1;
                levels.push(texture.view(vd));
            }
        }
        const t = new PostTarget(texture, view, width, height, format, mips, levels);
        if (i < pool.length) pool[i] = t;
        else pool.push(t);
        return t;
    }

    // Group 0 of one post draw of view `vb`: block `u`, `src`, `aux` and
    // `glow` (the glow chain, every level a mip) at bindings 1 to 3, the
    // linear sampler at 4. Three textures: a group of the host holds at
    // most 8 sampled textures (tools' wgsl_common_test checks every
    // module). The n-th post draw of a view writes its block into the
    // view's n-th kept buffer (a view's draws each read their own, and the
    // next frame's writes land after this frame's passes) and keeps its
    // group while it binds the same views.
    private postGroup(
        vb: ViewBuffers, pp: PostPipelines, u: PostUniform, src: GPUTextureView, aux: GPUTextureView,
        glow: GPUTextureView,
    ): GPUBindGroup {
        const i = vb.postDrawCursor;
        vb.postDrawCursor++;
        if (i >= vb.postDraws.length) vb.postDraws.push(new PostDraw(new GPUBuffer(BufferUsage.uniform, POST_UNIFORM_SIZE)));
        const d = vb.postDraws[i];
        u.writeAt(this.blockView, 0);
        d.buffer.update(0, this.blockBytes, POST_UNIFORM_SIZE);
        const kept = d.group;
        if (kept != null && d.src === src && d.aux === aux && d.glow === glow) return kept;
        if (kept != null) this.frameGroups.push(kept);
        const textures = [
            new GPUBindGroupTexture(1, src), new GPUBindGroupTexture(2, aux), new GPUBindGroupTexture(3, glow),
        ];
        const g = new GPUBindGroup(
            pp.layout, [new GPUBindGroupUBO(0, d.buffer)], textures, [new GPUBindGroupSampler(4, pp.sampler)],
        );
        d.group = g;
        d.src = src;
        d.aux = aux;
        d.glow = glow;
        return g;
    }

    // The image-based light of a lit frame's sky (null for another mode, or
    // without a Sky), built only when the sky changed and uploaded only when
    // the plan is new; a map the host refused is a warning.
    private skyLight(f: RenderFrame): IblPlan? {
        return this.skyLightOf(f, this.ibl, this.environment);
    }

    // `skyLight` from the pair `ibl` and `env` (milestone 34: a viewport's
    // own, or the main one).
    private skyLightOf(f: RenderFrame, ibl: IblCache, env: GpuEnvironment): IblPlan? {
        if (f.shading != SHADE_LIT) return null;
        const plan = ibl.get(f.environment, this.gpu.maxTextureSize());
        env.update(plan);
        const w = env.takeWarning();
        if (w.length > 0) this.warnings.push(w);
        return plan;
    }

    // One full-screen post draw into `target` (cleared to 0 first).
    private postPass(target: GPUTextureView, pipeline: GPUPipeline, bg: GPUBindGroup, label: string = "hedra post"): void {
        this.fullScreen(target, false, false, 0, 0, 0, 0, pipeline, bg, label);
    }

    // One full-screen draw of `pipeline` with group 0 `bg` into `target`
    // (the canvas when `toCanvas`), cleared first to (r, g, b, a) when
    // `clearWith`, else to 0, through the kept descriptor.
    private fullScreen(
        target: GPUTextureView, toCanvas: bool, clearWith: bool, r: f32, g: f32, b: f32, a: f32,
        pipeline: GPUPipeline, bg: GPUBindGroup, label: string = "hedra post",
    ): void {
        const pass = this.beginFullScreen(target, toCanvas, clearWith, r, g, b, a, label);
        pass.setPipeline(pipeline);
        bindGroup(pass, 0, bg);
        pass.draw(3);
        pass.finish();
    }

    // The pass of `fullScreen`, begun.
    private beginFullScreen(
        target: GPUTextureView, toCanvas: bool, clearWith: bool, r: f32, g: f32, b: f32, a: f32,
        label: string = "hedra post",
    ): GPURenderPass {
        const c = this.postColor;
        c.view = toCanvas ? null : target;
        c.resolveTarget = null;
        c.loadOp = LoadOp.clear;
        c.storeOp = StoreOp.store;
        c.clearR = clearWith ? r : 0;
        c.clearG = clearWith ? g : 0;
        c.clearB = clearWith ? b : 0;
        c.clearA = clearWith ? a : 0;
        const desc = this.postDesc;
        desc.label = label;
        desc.depthView = null;
        return this.gpu.canvas.beginRenderPass(desc, this.passWrapper);
    }

    // The bind group of one compose draw: `src` downsampled by `factor`
    // into the rect at (x, y), `overlay` (rect sized) blended over it. Its
    // block and the group are this frame's (a sheet's tiles).
    private composeGroup(src: GPUTextureView, factor: u32, x: i32, y: i32, w: u32, h: u32, overlay: GpuImage?): GPUBindGroup {
        const u = composeUniform(x, y, w, h, factor, overlay != null);
        const buf = new GPUBuffer(BufferUsage.uniform, <u32>u.byteLength, u, true);
        this.frameBuffers.push(buf);
        const ovView = overlay != null ? overlay.view : this.dummy.view;
        return this.group(new GPUBindGroup(
            this.pipelines.composeLayout,
            [new GPUBindGroupUBO(0, buf)],
            [new GPUBindGroupTexture(1, src), new GPUBindGroupTexture(2, ovView)],
        ));
    }

    // A CPU image as a GPU image (rgba8unorm bytes, no mips), e.g. the
    // `render uv` picture or an overlay.
    // A frame's overlay image on the GPU: written into the texture view
    // `vb` kept from its last frame when the size is the same (the editor's
    // every frame has one, and a new texture, view and compose group each
    // frame were never freed), else a new one, the old released at the next
    // `beginFrame`. A view is drawn once a frame, so no pass recorded
    // earlier in the frame samples what this overwrites.
    private keptOverlay(vb: ViewBuffers, img: Image): GpuImage {
        const kept = vb.overlay;
        if (kept != null && kept.width == img.width && kept.height == img.height) {
            writeRgba8(kept.texture, img);
            return kept;
        }
        if (kept != null) {
            this.frameViews.push(kept.view);
            this.frameTextures.push(kept.texture);
        }
        const t = uploadRgba8(img);
        const made = new GpuImage(t, t.view(), img.width, img.height);
        vb.overlay = made;
        return made;
    }

    uploadImage(img: Image): GpuImage {
        const t = uploadRgba8(img);
        this.frameTextures.push(t);
        return new GpuImage(t, this.viewOf(t), img.width, img.height);
    }

    // composite.as `sheet` on GPU images: fill with `rgbaBytes(background)`,
    // then per tile a blit at its cell, separators and the tile label. The
    // separators and labels are drawn on the CPU into a transparent overlay
    // (each tile's cell cleared first, as its blit overwrote what earlier
    // tiles drew there) that is blended over the tiled image.
    sheet(tiles: Array<GpuSheetTile>, width: u32, height: u32, background: Vec4): GpuImage {
        // (milestone 67: a picture drawn: `present` copies the next one)
        this.viewSerial++;
        const l = layout(tiles.length, width, height);
        const fill = rgbaBytes(background);
        const base = this.target(width, height, POST_FORMAT, 1);
        const baseView = this.viewOf(base);
        const overlayImg = overlayImage(width, height);
        const groups = new Array<GPUBindGroup>();
        for (let i = 0; i < tiles.length; i++) {
            const t = tiles[i];
            const x = <i32>((<u32>i % l.cols) * l.tileW);
            const y = <i32>((<u32>i / l.cols) * l.tileH);
            // `out.blit(t.image, x, y)`, clipped to the sheet.
            const w = <i32>min<u32>(t.image.width, width > <u32>x ? width - <u32>x : 0);
            const h = <i32>min<u32>(t.image.height, height > <u32>y ? height - <u32>y : 0);
            if (w > 0 && h > 0) {
                groups.push(this.composeGroup(t.image.view, 1, x, y, <u32>w, <u32>h, null));
                clearRect(overlayImg, x, y, w, h);
            }
            sheetDecorations(overlayImg, x, y, l.tileW, l.tileH, t.label);
        }
        const pass = this.beginFullScreen(baseView, false, true,
            <f32>fill.r / <f32>255.0, <f32>fill.g / <f32>255.0, <f32>fill.b / <f32>255.0, <f32>fill.a / <f32>255.0);
        for (let i = 0; i < groups.length; i++) {
            pass.setPipeline(this.pipelines.compose);
            bindGroup(pass, 0, groups[i]);
            pass.draw(3);
        }
        pass.finish();
        const overlay = this.uploadImage(overlayImg);
        const out = this.target(width, height, POST_FORMAT, 1);
        const outView = this.viewOf(out);
        this.fullScreen(outView, false, true, 0, 0, 0, 0, this.pipelines.compose,
            this.composeGroup(baseView, 1, 0, 0, width, height, overlay));
        return new GpuImage(out, outView, width, height);
    }

    // Put `img` on the host canvas 1:1 (resized to the image) and draw the
    // canvas onto the artboard with a nearest sampler, for the host's capture.
    // The host draws a canvas image as premultiplied alpha, so the straight
    // bytes are premultiplied on the way (a no-op where alpha is 255); what
    // the capture shows is then the rendered PNG over the artboard background.
    // Milestone 67: `smooth` draws the canvas with a linear filter, for a
    // picture drawn smaller than its layout's pixels and stretched over them
    // (scaling.as, Godot's bilinear scaling_3d_mode); 1:1 keeps the nearest
    // filter, so a picture of before is presented to the byte.
    // Milestone 67 (docs/engine/PERFORMANCE.md, "The present copy"): the
    // picture presented last, presented again with nothing drawn since (no
    // view, no sheet: the run time's every frame at rest), is on the canvas
    // already: drawn again with no pass (`redraw`), the same bytes, sparing
    // the copy (0.17 ms of GPU at 1920 x 1080 every frame).
    present(img: GpuImage, renderer: Renderer, smooth: bool = false): void {
        const canvas = this.gpu.canvas;
        if (this.presentedView === img.view && this.presentedWidth == img.width && this.presentedHeight == img.height
            && this.presentedSerial == this.viewSerial) {
            this.presentsKept++;
            this.redraw(renderer, smooth);
            return;
        }
        this.presentedView = img.view;
        this.presentedWidth = img.width;
        this.presentedHeight = img.height;
        this.presentedSerial = this.viewSerial;
        canvas.resize(img.width, img.height);
        const fmt = <TextureFormat>canvas.format;
        const found = this.pipelines.composeFor(fmt);
        const pipeline = found != null ? found : this.pipelines.compose;
        this.fullScreen(canvas.colorView(), true, true, 0, 0, 0, 0, pipeline, this.presentGroup(img), "hedra present");
        this.redraw(renderer, smooth);
    }

    // The compose group `present` draws `img` with: its block depends only
    // on the image's size, so the group of an image presented again (a
    // view's kept picture: the viewport's every frame) is kept, the last
    // PRESENT_KEPT of them; one pushed out is released at the next
    // `beginFrame`.
    private presentGroup(img: GpuImage): GPUBindGroup {
        const kept = this.presented;
        for (let i = 0; i < kept.length; i++) {
            const e = kept[i];
            if (e.view === img.view && e.width == img.width && e.height == img.height) return e.group;
        }
        const u = composeUniform(0, 0, img.width, img.height, 1, false, true);
        const buf = new GPUBuffer(BufferUsage.uniform, <u32>u.byteLength, u, true);
        const g = new GPUBindGroup(
            this.pipelines.composeLayout,
            [new GPUBindGroupUBO(0, buf)],
            [new GPUBindGroupTexture(1, img.view), new GPUBindGroupTexture(2, this.dummy.view)],
        );
        if (kept.length >= PRESENT_KEPT) {
            const old = kept.shift();
            this.frameGroups.push(old.group);
            this.frameBuffers.push(old.buffer);
        }
        kept.push(new PresentEntry(img.view, img.width, img.height, buf, g));
        return g;
    }

    // Draw what the last `present` put on the canvas again, with no render
    // pass and no allocation: a window repainting a frame whose image did
    // not change.
    redraw(renderer: Renderer, smooth: bool = false): void {
        renderer.drawImage(
            this.gpu.canvas.image,
            ImageSampler(ImageWrap.clamp, ImageWrap.clamp, smooth ? ImageFilter.bilinear : ImageFilter.nearest),
            BlendMode.srcOver, 1,
        );
    }
}

// The descriptor of a render target of this size, format and sample count
// (one level).
function targetDesc(width: u32, height: u32, format: TextureFormat, samples: u32): GPUTextureDesc {
    const d = new GPUTextureDesc();
    d.width = width;
    d.height = height;
    d.format = format;
    d.sampleCount = samples;
    d.renderTarget = true;
    d.numMipmaps = 1;
    return d;
}

// The uploaded instance buffer of `inst` (gpu/instances.as), null before
// its upload (the frame's `instancing` uploads what it draws).
function instanceGpu(inst: InstanceData): GPUBuffer? {
    const g = inst.gpu;
    if (g == null) return null;
    return (g as GpuInstanceBuffer).buffer;
}
