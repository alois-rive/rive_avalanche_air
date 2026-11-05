// The run time (milestone 39): what a Rive project's AnimaScript module
// runs in a Rive file, through the hedra_engine library. One SceneRuntime holds one loaded bundle
// (../bundle/read.as) and the scripts' registry; each `instantiate` makes a
// SceneInstance of one of its scenes, which a Layout (the Scene3D
// component, scene3d.as, or the project's own code) advances and draws:
//
//   const rt = new SceneRuntime();            // the module's newRuntime()
//   rt.loadBundle(Uint8Array.wrap(ctx.blob("courtyard")!), "courtyard");
//   const inst = rt.instantiate("courtyard.rscn", ctx)!;
//   ... advance(seconds) -> whether the next draw shows something new
//   ... draw(renderer, width, height, scale)
//   ... pointer(kind, x, y, id), key(...), bind(viewModel), node(path),
//       takeSignals()
//
// The tree is the Hedra library's (a loader with the bundle as its
// provider, ../bundle/provider.as, so nothing is parsed, replayed or
// imported); a scene instancing another, and a script's load() and
// instantiate(), resolve to the bundle's scenes the same way. Instances of
// one runtime share every decoded resource (the bundle's provider), every
// scene's sub_resources (one InstanceShare, ../tree/tree.as), and so every
// GPU mesh and texture: the runtime's one SceneRenderCache builds and
// uploads each mesh once, and its one TextureShare uploads each decoded
// texture once for every renderer.
// `instantiateTree` makes an instance of a tree loaded some other way (from
// files: the tests' seam, and Play's in milestone 27).
//
// The GPU: the runtime makes one FrameRenderer, the first time an instance
// is made with a Context, which compiles the pipelines once; the first
// instance draws with it and every later one with a sibling of it
// (FrameRenderer.sibling: the same device and pipelines, a canvas and
// per-frame state of its own). One renderer for all would make each
// instance's `beginFrame` release the targets and groups the others' last
// pictures live in, and present them all on one canvas, so an idle
// instance could not show its last picture again; a sibling costs its
// canvas, its 1x1 fallbacks and its material groups (the textures it
// binds are the runtime's TextureShare's, keyed by the bundle's decoded
// images, and the meshes the shared cache's: each uploaded once, whatever
// the number of instances). A disposed instance's
// sibling is kept and given to the next instance (releaseRenderer), as
// nothing frees a canvas: a Scene3D switching scenes costs no new one.
// docs/cli/BUILD.md
// section 18 ("The run time") records the choice.
//
// Drawing only on change: `advance` returns false, and `draw` presents the
// last picture without building or rendering a frame, unless something
// changed since the picture (the first frame, a resize, a script that
// processes, an input a script listens to, a bound value, a live artboard,
// a camera or yaw change, a node a script added, a signal, a node moved
// through a handle or `touch`). A Layout that is not drawn costs its
// advance only: frames are planned in `draw`. An idle advance and draw
// allocate nothing of the program's heap (tests/runtime/runtime_test.as
// counts it over 600 frames).
//
// Milestone 26: textures. A bundle stores a texture's processed forms
// (KTX2 of bc, etc2, astc, or rgba8) beside or instead of its source; the
// runtime chooses once, when it loads the bundle, from the device's
// families (rive/gpu gpuFeatures: render/gpu/materials.as deviceFamilies,
// none on a backend whose upload layout it does not recognise: Vulkan,
// WebGPU),
// which form each texture is read in: the first of bc, etc2 and astc the
// device takes and the texture has, else rgba8, else the source, else its
// first family, decoded on the CPU (bundle/decode.as TextureChoice). Only
// that form is inflated and parsed; the binder uploads it as it is. The
// status says the choice (`"textures":"bc"`). Levels of detail: a mesh's
// generated levels are drawn while their error, projected, stays under
// `lodThreshold` pixels (Godot's mesh_lod_threshold, 1.0 by default; the
// Scene3D view model's `lodThreshold`); the status says the triangles the
// last plan draws (`"triangles":5770`), as the CLI's `render` answers them.
//
// Milestone 27: Godot's scripting basics run here as in Play (the scripts
// feature's ScriptRuntime: timers, tweens, _process, queued frees, in that
// order each frame); a subtree a script removes or frees is let go of by
// every feature (`nodeRemoving`). The lines scripts print reach the
// instance whose scripts run, unless the program installed a PrintSink of
// its own (Play's game does): `printed` keeps the last MAX_PRINTED for
// `takePrinted`, and the status counts them all (`"printed"`, after
// "drawn", only once there is one, so a scene that prints nothing keeps
// the status it had).
//
// Milestone 28: Build and Play rewrite each print, printErr,
// pushError and pushWarning of a script to pass its file and line
// (compiler/src/play/print_sites.as). The status says where the last
// printed line came from, `"printed_at":"res://scripts/crate.as:21"` right
// after "printed", only when that line had a place (a scene printing
// nothing, or only without places, keeps the status it had). pushError
// and pushWarning are problems, not printed lines: the instance's errors
// gain "res://scripts/crate.as:9: <text>" and "res://scripts/crate.as:9:
// WARNING: <text>" (the text alone without a place), once each. The
// first MAX_ERRORS distinct errors are kept: past them, each error is only
// counted (the status's `"errors_more"`, after "errors", once there is
// one), so a script pushing a warning whose text changes every frame
// ("speed 3.2") neither grows the list for the instance's life nor makes
// the status anew each frame.
//
// Milestone 41 (docs/plans/BUILD.md section 6): the three sources. `load`
// (and loadText, loadBuilt, loadFrom) loads one scene of a Hedra project
// in a Rive project into this runtime and instances it: from its built
// form, build/hedra/<path>b, read through the FileSource (the declared
// `hedra:` blobs) as loadSceneFile reads a built .rscnb, or from its
// text, read through a read fallback of the vfs (../../host/vfs.as
// Vfs.setReadFallback) at /hedra/<project>, which asks the FileSource
// for every file the loader reads there, exactly as the editor loads the
// scene. Auto takes the built form when builtState says Current, else the
// text, with the reason (and, asked for, the label: label.as). A runtime
// holds one loaded scene (each scene's levels of detail and mounted files
// are its runtime's own, milestone 40's rule): a host loads each scene
// into a runtime of its own (the Scene3D component does).
//
// The project is the registered one (projects.as) the path is in; its
// script classes are the runtime's registry, keyed by each script's path
// in the project in both sources (projectKeys). A built scene's files are
// mounted at a bundle root of the project's own (bundleRootAt from
// BUILT_ROOT_SLOT per project), with a read fallback there too, so that a
// scene a script loads which the built file lacks is read from its
// declared text. A script's .as file is never declared (it is compiled,
// not read): the fallbacks answer one the project registers with a line
// naming its class.
//
// The status line (`status()`): the player's (../player/player.as), with
// "drawn" (the pictures made anew: planned and rendered, or planned only
// without a GPU; not the ones presented again) after "process", so that
// `rive <project> --data-dump` shows both that the scene runs and that an
// idle scene draws nothing new. `statusChanged` says whether anything in
// it but "frames" and "time" changed since the last `status()`, so that a
// writer (Scene3DView) rewrites it, and allocates, only then. Milestone
// 46: while the root scene runs a state machine, the animation feature's
// part adds "state_machine" and "states" (feature_animation.as), made again
// only when a state changed.
//
// Milestone 31: interaction (docs/formats/RSCN.md, "Interaction"). The
// interaction feature (feature_interaction.as) steps between the scripts
// and the bindings' push (features.as PHASE_INTERACTION): areas' overlaps,
// rays and the pointer's picking, whose signals it emits through
// `emitEvent` (an event of its own, filled again each time: nothing is
// allocated). Every feature hears a pointer event now, the scripts' first;
// `pickRay` is the pointer's ray through the last picture, in scene space;
// `debugShapes` (Play's --shapes) has the frame's collision shapes drawn.
// A scene without the feature has the status, the pictures and the costs
// it had.
//
// Milestone 47: listeners (docs/engine/STATE_MACHINES.md "Listeners").
// `listenerHits` picks a pointer event into what the last picture drew
// (../listen/pick.as: meshes by their triangles, and the collision objects
// the running machines' pointer listeners target), once per event however
// many parts read it: the animation feature's machines run their pointer
// listeners with it, the artboards feature forwards the event into the
// artboard texture under the pointer. An event the scene fires reaches
// every part (features.as eventFired): its fire bindings fire their view
// model triggers, and the machines' event listeners hear it. A scene
// without listeners and artboard textures picks nothing, and its status,
// pictures and costs are as they were.
//
// Milestone 61 (docs/engine/SHADERS.md, "The built form"): custom shader
// materials. Each instance's renderer draws them with the modules of its
// project's shader assets (./shader_assets.as AssetShaderModules: rive
// compiled what `hedra build` composed, found by the program's key), one
// source per project, kept by the runtime (shaderModulesFor); a program
// that installed a source of its own (the tools' shader service:
// render/shader/modules.as installShaderModules) keeps it. TIME is the
// scene's clock (`time`, played seconds times `speed`), wrapped at
// SHADER_TIME_ROLLOVER, written into each picture's frame
// (RenderFrame.shaderTime); while the last plan drew a material whose
// shader reads TIME, every frame that plays makes a new picture (without
// planning again). The status gains `"shaders":{"drawn":N,"fallback":M}`
// when the last picture drew a custom material (its draws with their own
// pipelines, and those drawn with their fallback), and its errors a
// warning once a shader file the Rive project holds no module of (edited
// after `hedra build`: unbuiltShaders); a scene without one has the
// status, the pictures and the costs it had.
//
// Milestone 62 (docs/engine/SCREEN_EFFECTS.md): the screen-space
// effects. Each instance draws with the quality its project's hedra.yaml
// sets (the registered project's: projects.as RegisteredProject
// .screenQuality, which `load*` hands its instances), the tools' quality
// for the same file. The status gains `"screen":{"ssr":B,"refraction":B,
// "dof":B}` when the last picture drew any of the three (the renderer's
// RenderStats: an Environment's reflections traced, its screen refraction
// with glass of the view's world drawn on the screen texture, the camera
// attributes' depth of field composed; without a GPU, what post.as
// planPostInto plans), written again only when one of them changes; a
// scene without them has the status, the pictures and the costs it had.
// When the host refuses one of them (the renderer's SCREEN_, SSR_ and
// DOF_PIPELINE_WARNING), its bit is false and the status's errors say
// why, once each, as "WARNING: ...".
//
// Milestone 67 (docs/engine/PERFORMANCE.md, "Render scale" and "Pictures
// that change"): each instance draws with the render quality its
// project's hedra.yaml sets (RegisteredProject.renderQuality, the `.web`
// lines over the others on the GL target: WebGL 2), which `load*` hands
// its instances as the screen quality, under the Scene3D's own render
// scale, scaling mode and caps (setRenderScale). The 3D picture's size is
// ../../render/scaling.as pictureSizeInto's: the layout's pixels at a
// scale of 1 inside the caps (every picture of before, presented as
// before), else smaller, presented stretched over the layout (Rive's
// bilinear image filter) or upscaled to the layout's pixels by FSR 1.0
// first (the frame's output size: ../../render/gpu/fsr.as). Scripts, the
// listeners and the bindings keep the layout's pixels: `pointer` hands
// scripts the layout's pixels as before, and the picking (`pickRay`,
// listenerHits) turns them into the picture's. The level-of-detail
// threshold stays in the layout's pixels, as Godot's mesh_lod_threshold
// is measured against the viewport's size whatever its scaling_3d_scale
// (renderer_viewport.cpp `_draw_3d`): the plan is given it in the
// picture's pixels. `texturesChanged` (a live artboard texture drawn
// again) makes a new picture without a plan, drawn with
// FrameRenderer.renderFrameReusing (REUSE_TEXTURES), which keeps what the
// textures cannot reach. The status gains `"picture":[W,H]` while the
// picture is not the layout's pixels, and `"variants":{"drawn":N,
// "ubershader":M,"pending":P}` while the last picture drew a specialised
// surface shader or waited for one (the renderer's VariantStats); a scene
// drawn at its layout's pixels without variants has the status it had.
//
// Milestone 67b (docs/engine/RESOURCES.md): the hooks (runtime_hooks.as)
// that manage a run time's resources, which newSceneRuntime adds: the
// remaps (remap.as), the one resource cache and its lifetimes
// (runtime_resources.as) and the CPU copies (../resource/cpu_copy.as). A
// runtime without hooks (the tests' `new SceneRuntime()`) loads, shares
// and draws as before; `loadProject` and `loadFiles` say what the load in
// progress reads, and `freshLoaders` makes instantiateFile give each
// instance a loader of its own (so that each holds its own references).
//
// Milestone 49 (docs/cli/BUILD.md section 8, "Off-screen"):
// `writesData` says whether the scene writes its data, the parts answering
// from what the scene declares (features.as InstanceFeature.writesData:
// a two_way, to_source or signal binding, an Event's fire binding, a
// state machine with a ListenerViewModelChange or a StateMachineFireTrigger,
// a script), worked out once per instance; the Scene3D component never
// leaves such a scene still off-screen. `queuedEvents` and `queuedEvent`
// read the events queue without taking it (the Scene3D's `events`).

import { Context } from "rive/host";
import { ViewModel } from "rive/data";
import { Artboard } from "rive/artboard";
import { Mat2D } from "rive/mat2d";
import { Renderer as HostRenderer } from "rive/renderer";
import { Result } from "../../base/util";
import { jsonQuote } from "../../base/json";
import { displayF64 } from "../../base/fmt";
import { Vec3 } from "../../base/vecmath";
import { Camera } from "../../render/camera";
import { RenderFrame } from "../../render/frame";
import { PostPlan, planPostInto } from "../../render/post";
import { ScreenQuality } from "../../render/screen";
import { RenderQuality, SCALING_3D_BILINEAR, SCALING_3D_FSR } from "../../render/quality";
import { PictureSize, pictureSizeInto } from "../../render/scaling";
import { abi } from "rive/bindings";
import { Jobs } from "rive/jobs";
import { Ray, pixelRayInto } from "../../render/ray";
import { modelToScene } from "../space";
import { MeshUploader } from "../../render/mesh";
import { AdapterChoice } from "../../render/gpu/device";
import { DOF_PIPELINE_WARNING } from "../../render/gpu/dof";
import { FrameRenderer, GpuImage, REUSE_TEXTURES, SCREEN_PIPELINE_WARNING } from "../../render/gpu/renderer";
import { SSR_PIPELINE_WARNING } from "../../render/gpu/ssr";
import { NoShaderModules, SHADER_UNAVAILABLE, ShaderModuleSource, installedShaderModules } from "../../render/shader/modules";
import { SHADER_TIME_ROLLOVER } from "../../render/shader/program";
import { AssetShaderModules } from "./shader_assets";
import { surfaceVariantsFor } from "./variant_assets";
import { SurfaceVariantSource } from "../../render/shader/variants";
import { RenderStats } from "../../render/cull";
import { GPUTextureView } from "rive/gpu";
import { TextureFamilies, TextureShare } from "../../render/material";
import { deviceFamilies } from "../../render/gpu/materials";
import { InputEvent, InputKind, PrintSink, ScriptRegistry, currentPrintSink, setPrintSink } from "../script";
import { Value } from "../value";
import { InstanceShare, SceneTree, SceneTreeHost, underSubViewport } from "../tree/tree";
import { Camera3D, NodeAddedListener, OccluderInstance3D, SceneNode, treeStructureEpoch } from "../tree/node";
import { loadSceneTree } from "../tree/instance";
import { ResourceLoader, findProjectRoot } from "../resource/loader";
import { SceneFrame, SceneRenderOptions, buildSceneFrame, refreshSceneFrame, retargetSceneFrame } from "../render/adapter";
import { SceneRenderCache } from "../render/cache";
import { cameraInto } from "../render/camera";
import { Bundle } from "../bundle/read";
import { sceneFileBundle } from "../bundle/scene_file";
import { BundleResources, bundleLoader, useBundleLods } from "../bundle/provider";
import { TextureChoice } from "../bundle/decode";
import {
    FEATURE_ANIMATION, FEATURE_ARTBOARDS, FEATURE_AUDIO, FEATURE_BINDINGS, FEATURE_INTERACTION, FEATURE_NAVIGATION, FEATURE_SCRIPTS,
    Feature,
    InstanceFeature, PHASE_COUNT, PHASE_PUSH, PHASE_SETTLE, featureNameOfBit,
} from "./features";
import { EVENT_FIRED_SIGNAL, FiredEvent, MAX_QUEUED_EVENTS } from "./events";
import { ListenerHits, ListenerPicker } from "../listen/pick";
import { InteractionWorld } from "../interaction/world";
import { EventDecl } from "../anim/decl";
import { ScriptScene } from "../script/scene_api";
import { OutputView } from "../binding/outputs";
import { ViewModelValues } from "../binding/values";
import { SignalEvent, SignalTarget } from "./signals";
import { BlobFiles, BuiltState, FileSource, REASON_INVALID, REASON_NO_SOURCE_READERS, REASON_NOT_BUILT, REASON_OTHER_MAJOR,
    REASON_OUT_OF_DATE, SceneLoad, SceneOptions, SceneSource, builtPathOf, sceneSourceName } from "./sources";
import { RegisteredProject, projectNamed, registeredProjects } from "./projects";
import { UnbuiltLabel, labelText } from "./label";
import { VfsReadFallback, vfs } from "../../fs/vfs";
import { sha256 } from "../../base/sha256";
import { HEDRA_ENGINE_MAJOR } from "../../version";
import { sceneProvenance } from "../rscnb/srcs";
import { RscnbVerifyScope, forgetVerifiedRscnb, rememberVerifiedRscnb } from "../rscnb/codec";
import { currentFileReaders } from "../resource/loader";
import { CLI } from "../../base/names";
import { ListenerPose, listenerFromLook, listenerFromNode } from "../audio/listener";
import { audioDeclaredMark, isAudioPath } from "../resource/audio_stream";
import { RuntimeHook } from "./runtime_hooks";

// The largest side of a picture, in pixels (the CLI's `render --size`'s and
// the player's limit: the largest texture every GPU the renderer supports
// holds).
export const MAX_PICTURE_SIDE: u32 = 8192;

// Godot's mesh_lod_threshold default: a level of detail is drawn while
// its error, projected, stays under one pixel. The run time's default
// (the tools draw level 0 unless asked).
export const RUNTIME_LOD_THRESHOLD: f32 = 1.0;

// Godot's CONNECT_ONE_SHOT (./signals.as), where milestone 39 put it.
export { CONNECT_ONE_SHOT } from "./signals";

// The vertical axis in render space (scene +Y; ../space.as SCENE_TO_MODEL
// turns it to +Z), about which `setYaw` turns the view.
const RENDER_UP: Vec3 = Vec3(0, 0, 1);

export class SceneRuntime {
    // Filled by the module's generated registerScripts, keyed by each
    // script's bundle path ("courtyard/scripts/spin.as").
    registry: ScriptRegistry = new ScriptRegistry();
    // Installed by the module's generated installFeatures (features.as).
    features: Array<Feature> = [];
    bundle: Bundle? = null;
    resources: BundleResources? = null;
    // What went wrong (loading the bundle, a scene, the GPU), once each.
    errors: Array<string> = [];
    // The artboard textures' sources and which bind the scene's view model
    // (feature_artboards.as artboardSourcesOf and artboardViewModelOf, which
    // Scene3DView hands over before it instances): what the artboards
    // feature of each instance plays (../player/artboards.as).
    artboardSources: Array<string> = [];
    artboardViewModel: Array<bool> = [];
    // What every instance shares: the scenes' sub_resources, and the GPU
    // meshes and texture images built from them (see the header).
    share: InstanceShare = new InstanceShare();
    cache: SceneRenderCache = new SceneRenderCache();
    // The GPU textures of the decoded images every renderer binds (the
    // first and its siblings: one device), each uploaded once.
    gpuTextures: TextureShare<GPUTextureView> = new TextureShare<GPUTextureView>();
    // The runtime's FrameRenderer (made with the first instance that has a
    // Context; null before, and without a GPU).
    renderer: FrameRenderer? = null;
    // Where planning uploads meshes when an instance has no renderer: null,
    // but for a test that counts the uploads.
    uploader: MeshUploader? = null;
    // Whether an instance draws with `renderer` itself (the others draw
    // with siblings).
    private primaryTaken: bool = false;
    // Siblings instances let go of (releaseRenderer), handed out again.
    private freeSiblings: Array<FrameRenderer> = [];
    private nextId: i64 = 0;
    // useFiles: the directory whose files stand in for a bundle ("": none),
    // and one loader per project root under it (so that instances share
    // what they load, as a bundle's provider shares it).
    private fileRoot: string = "";
    private loaders: Map<string, ResourceLoader> = new Map<string, ResourceLoader>();
    // Milestone 26: the device's block-compression families (null: asked
    // of the device when a bundle is loaded; a test sets its own first),
    // and the texture form chosen from them (see the header).
    families: TextureFamilies? = null;
    textureChoice: TextureChoice = TextureChoice.every();
    // Milestone 41: set by `load*` (see the header): scripts are found by
    // their path in the project, and the artboard sources are the tree's
    // when none were given (feature_artboards.as).
    projectKeys: bool = false;
    deriveArtboards: bool = false;
    // What `load*` loaded into this runtime ("built:<path>", "text:<root>",
    // "" for nothing), so that loading it again only instances it.
    private loadedKey: string = "";
    // Milestone 61: the Hedra project the instances made next draw the
    // custom shaders of (`load*` sets it: the project's path in the Rive
    // project; "" its root), and each project's source of modules.
    shaderProject: string = "";
    private shaderSources: Map<string, AssetShaderModules> = new Map<string, AssetShaderModules>();
    // Milestone 62: the screen-space effects' quality the instances made
    // next draw with (`load*` sets it from the scene's project's settings;
    // Godot's defaults otherwise).
    screenQuality: ScreenQuality = new ScreenQuality();
    // Milestone 67: the render quality the instances made next draw with
    // (`load*` sets it from the scene's project's settings, with their
    // `.web` lines where `web` says; the defaults otherwise), and whether
    // the `.web` feature tag applies: -1 from the runtime (webTarget: the
    // website's WebGL 2 runtime without script threads), 0 no, 1 yes (the
    // tests).
    renderQuality: RenderQuality = new RenderQuality();
    webTag: i32 = -1;
    // Milestone 67b (see the header): the hooks, in the order added; the
    // Hedra project and the files the load in progress reads ("" and null
    // outside load*); a loader per instance in instantiateFile.
    hooks: Array<RuntimeHook> = [];
    loadProject: string = "";
    loadFiles: FileSource? = null;
    // The root's own built file (a path in the Rive project) while its
    // text is loaded ("" otherwise): the remaps read a resource from it
    // first when it holds one, rather than open other built files
    // (remap.as RemapState.prefer).
    loadRootBuilt: string = "";
    freshLoaders: bool = false;
    // Milestone 67b: the resources load_task.as decoded ahead for a bundle,
    // which the next useBundle of that same Bundle takes instead of making
    // new ones (so what was decoded is not decoded again); null otherwise.
    preparedResources: BundleResources? = null;
    // Milestone 67b: this runtime's last built check and the files whose
    // CRC its load took (BuiltCheckMemo), so that a load over frames
    // (load_task.as) checks its file in its first step and loads it in a
    // later one without parsing it or taking its CRC again, whatever
    // another runtime (another Scene3D) loads in between.
    checkMemo: BuiltCheckMemo = new BuiltCheckMemo();

    // Milestone 67b: adds a hook (runtime_hooks.as), told `attached` at once.
    addHook(h: RuntimeHook): void {
        for (let i = 0; i < this.hooks.length; i++) if (this.hooks[i] === h) return;
        this.hooks.push(h);
        h.attached(this);
    }

    // Milestone 61: where an instance's renderer takes its custom shaders'
    // modules from (see the header): the program's own source when it
    // installed one (the tools), else the shader assets of `project` in
    // the Rive project behind `ctx`, one source per project.
    shaderModulesFor(ctx: Context?, project: string): ShaderModuleSource? {
        const installed = installedShaderModules();
        const none = installed instanceof NoShaderModules;
        if (!none) return null;
        if (this.shaderSources.has(project)) return this.shaderSources.get(project);
        const made = new AssetShaderModules(ctx, project);
        this.shaderSources.set(project, made);
        return made;
    }

    // Adds a feature (a second one with the same bit replaces the first).
    install(f: Feature): void {
        for (let i = 0; i < this.features.length; i++) {
            if (this.features[i].bit() == f.bit()) {
                this.features[i] = f;
                return;
            }
        }
        this.features.push(f);
    }

    // The bits of the installed features.
    installed(): u32 {
        let m: u32 = 0;
        for (let i = 0; i < this.features.length; i++) m |= this.features[i].bit();
        return m;
    }

    // Reads the bundle `bytes` (named `name` in errors); false, with the
    // reason in `errors`, when it is not a bundle this run time reads, or
    // its scenes use a feature this module was not built with.
    loadBundle(bytes: Uint8Array, name: string = "bundle"): bool {
        const b = Bundle.parse(bytes, name);
        if (!b.ok) {
            this.fail(b.err);
            return false;
        }
        return this.useBundle(b.value, name);
    }

    // Milestone 40: reads the self-contained scene `bytes` (a built
    // <scene>.rscnb, ../bundle/scene_file.as) as a bundle of that scene;
    // false, with the reason in `errors`, as loadBundle. The scene is then
    // `mainScene()`, which `instantiate` takes.
    loadSceneFile(bytes: Uint8Array, name: string = "scene"): bool {
        const b = sceneFileBundle(bytes, name);
        if (!b.ok) {
            this.fail(b.err);
            return false;
        }
        return this.useBundle(b.value, name);
    }

    // The scene a self-contained scene file holds (loadSceneFile), "" for a
    // bundle or none.
    mainScene(): string {
        const b = this.bundle;
        return b != null ? b.main : "";
    }

    // `loadBundle` of a bundle already parsed: refused when its scenes use
    // a feature that is not installed; else its resources are made and its
    // files mounted, and every earlier share is dropped.
    // (Milestone 41: `firstRoot`, the first bundleRootAt its files are
    // mounted at, BundleResources.firstRoot.)
    useBundle(b: Bundle, name: string = "bundle", firstRoot: i32 = 1): bool {
        const missing = b.features & ~this.installed();
        if (missing != 0) {
            this.fail(name + ": its scenes use " + missingNames(missing) + ", which this module was not built with"
                + " (build the project again with `" + CLI + " build`, which vendors the library for the scenes' features: "
                + "docs/cli/BUILD.md)");
            return false;
        }
        // (milestone 67b: the load task's, when it decoded this bundle ahead)
        const prepared = this.preparedResources;
        this.preparedResources = null;
        const taken = prepared != null && prepared.bundle === b;
        // (prepared for another bundle: what it mounted taken out)
        if (prepared != null && !taken) prepared.unmount();
        const res = taken ? prepared! : new BundleResources(b);
        res.firstRoot = firstRoot;
        // (chosen once, before any texture is read: see the header)
        let fam = this.families;
        if (fam == null) {
            fam = deviceFamilies();
            this.families = fam;
        }
        this.textureChoice = TextureChoice.forFamilies(fam);
        res.textureChoice = this.textureChoice;
        // (a damaged file is left unmounted and said in `errors`: as with
        // any other damaged entry, only what reads it fails)
        const m = res.mount();
        if (!m.ok) this.fail(m.err);
        // (its primitive meshes' levels of detail, this runtime's own:
        // provider.as useBundleLods)
        this.cache.lodSource = useBundleLods(res);
        this.bundle = b;
        this.resources = res;
        this.share = new InstanceShare();
        for (let i = 0; i < this.hooks.length; i++) this.hooks[i].bundleUsed(this, res);
        return true;
    }

    // Instances scenes from the files under `root` (absolute, no trailing
    // slash) instead of a bundle: `instantiate(p)` loads root + "/" + p as
    // the CLI's `render` loads a scene (each project root's loader kept and
    // shared). The tests' seam for everything a bundle would do, and
    // Play's (milestone 27). A bundle loaded later wins.
    useFiles(root: string): void {
        this.fileRoot = root;
        this.loaders.clear();
        this.share = new InstanceShare();
    }

    // The bundle's scenes, by bundle path.
    scenes(): Array<string> {
        const out = new Array<string>();
        const b = this.bundle;
        if (b != null) for (let i = 0; i < b.scenes.length; i++) out.push(b.scenes[i].path);
        return out;
    }

    // A new instance of the scene at bundle path `scenePath` (its scripts
    // attached and ready, its features attached), drawing on `ctx`'s GPU
    // (null: no GPU, as in tests); null, with the reason in `errors`,
    // when the scene is not in the bundle or does not load.
    instantiate(scenePath: string, ctx: Context? = null): SceneInstance? {
        const b = this.bundle;
        const res = this.resources;
        if ((b == null || res == null) && this.fileRoot.length > 0) return this.instantiateFile(scenePath, ctx);
        if (b == null || res == null) {
            this.fail("instantiate " + scenePath + ": no bundle is loaded");
            return null;
        }
        const sc = b.scene(scenePath);
        if (sc == null) {
            const have = this.scenes();
            this.fail("instantiate " + scenePath + ": the bundle has no such scene (it has "
                + (have.length > 0 ? have.join(", ") : "none") + ")");
            return null;
        }
        const bl = bundleLoader(res, sc);
        for (let i = 0; i < this.hooks.length; i++) this.hooks[i].loaderMade(this, bl, res);
        const t = loadSceneTree(sc.abs(), bl, this.share);
        if (!t.ok) {
            this.fail("instantiate " + scenePath + ": " + t.err);
            return null;
        }
        return this.instantiateTree(t.value, scenePath, ctx);
    }

    // `instantiate` from the files under `useFiles`'s root.
    private instantiateFile(scenePath: string, ctx: Context?): SceneInstance? {
        const abs = this.fileRoot + "/" + scenePath;
        const root = findProjectRoot(abs);
        let l: ResourceLoader;
        if (this.loaders.has(root) && !this.freshLoaders) {
            l = this.loaders.get(root);
        } else {
            l = new ResourceLoader(root);
            this.loaders.set(root, l);
        }
        for (let i = 0; i < this.hooks.length; i++) this.hooks[i].loaderMade(this, l, null);
        const t = loadSceneTree(abs, l, this.share);
        if (!t.ok) {
            this.fail("instantiate " + scenePath + ": " + t.err);
            return null;
        }
        return this.instantiateTree(t.value, scenePath, ctx);
    }

    // An instance of `tree` (loaded by the caller, from the bundle or from
    // files; best with `share` as its loadSceneTree's share, so that its
    // instances share meshes), named `scenePath` in its status.
    instantiateTree(tree: SceneTree, scenePath: string, ctx: Context? = null): SceneInstance {
        installInstanceSink();
        const inst = new SceneInstance(this, scenePath, tree);
        for (let i = 0; i < this.hooks.length; i++) this.hooks[i].instanceMade(this, inst);
        inst.setScreenQuality(this.screenQuality);
        inst.setRenderQuality(this.renderQuality);
        inst.start(ctx, this.nextId++);
        return inst;
    }

    // A renderer for a new instance on `ctx`'s GPU (see the header).
    rendererFor(ctx: Context): Result<FrameRenderer> {
        let primary = this.renderer;
        if (primary == null) {
            const r = FrameRenderer.create(ctx, new AdapterChoice());
            if (!r.ok) return r;
            primary = r.value;
            this.renderer = primary;
            this.cache.halfFloat = primary.halfFloat();
        }
        let out: FrameRenderer;
        if (!this.primaryTaken) {
            this.primaryTaken = true;
            out = primary;
        } else if (this.freeSiblings.length > 0) {
            // (one an instance let go of: a sibling has a GPU canvas and
            // targets of its own, which nothing frees, so a scene switch
            // reuses the last instance's rather than making another)
            out = this.freeSiblings.pop();
        } else {
            const s = primary.sibling();
            if (!s.ok) return s;
            out = s.value;
        }
        // Textures through the cache, which holds the images the bundle
        // decoded (and a glTF model's embedded ones, which are no file),
        // uploaded once for every renderer through the share.
        out.materials.files = this.cache.textures;
        out.materials.share = this.gpuTextures;
        // (a reused one's statistics are the last instance's picture's: the
        // new instance's status says nothing of them before its own)
        out.lastStats.reset();
        return Result.okv<FrameRenderer>(out);
    }

    // An instance let go of `r`: the primary is free again, and a sibling
    // goes to the pool rendererFor takes from first. So the siblings made
    // are as many as the instances ever drawing at once, however often a
    // Scene3D switches scenes.
    releaseRenderer(r: FrameRenderer): void {
        if (r === this.renderer) {
            this.primaryTaken = false;
            return;
        }
        for (let i = 0; i < this.freeSiblings.length; i++) if (this.freeSiblings[i] === r) return;
        this.freeSiblings.push(r);
    }

    // How many sibling renderers wait in the pool (tests).
    get freeRenderers(): i32 {
        return this.freeSiblings.length;
    }

    // Milestone 41: the three sources (sources.as; docs/plans/BUILD.md
    // section 6). `scenePath` is a path in the Rive project
    // ("world/courtyard.rscn") or a res:// path of `options.project`.

    // The scene through the blobs `ctx` declares: Auto, Text or Built as
    // `options.source` says.
    load(ctx: Context, scenePath: string, options: SceneOptions = new SceneOptions()): SceneLoad {
        return this.loadFrom(new BlobFiles(ctx), scenePath, options, ctx);
    }

    // The scene from its text, whatever is built.
    loadText(ctx: Context, scenePath: string, options: SceneOptions = new SceneOptions()): SceneLoad {
        const o = copyOptions(options);
        o.source = SceneSource.Text;
        return this.loadFrom(new BlobFiles(ctx), scenePath, o, ctx);
    }

    // The scene from its built form, or an error.
    loadBuilt(ctx: Context, scenePath: string, options: SceneOptions = new SceneOptions()): SceneLoad {
        const o = copyOptions(options);
        o.source = SceneSource.Built;
        return this.loadFrom(new BlobFiles(ctx), scenePath, o, ctx);
    }

    // The built form's state against the declared text.
    builtState(ctx: Context, scenePath: string, options: SceneOptions = new SceneOptions()): BuiltState {
        return this.builtStateFrom(new BlobFiles(ctx), scenePath, options);
    }

    // `load` over any FileSource (the tests' fake blobs; `ctx` null: no GPU).
    loadFrom(files: FileSource, scenePath: string, options: SceneOptions, ctx: Context?): SceneLoad {
        const out = new SceneLoad();
        const place = placeOf(scenePath, options.project);
        if (!place.ok) {
            this.loadFailed(out, place.err);
            return out;
        }
        const at = place.value;
        out.scenePath = at.rivePath;
        let source = options.source;
        let check: BuiltCheck? = null;
        if (source == SceneSource.Auto) {
            check = builtCheck(files, at, this.checkMemo);
            if (check.state == BuiltState.Current) {
                source = SceneSource.Built;
            } else {
                source = SceneSource.Text;
                out.reason = reasonOf(check);
            }
        }
        out.source = source;
        this.projectKeys = true;
        this.deriveArtboards = true;
        this.shaderProject = at.project.name;
        this.registry = at.project.scripts();
        // (milestone 62: the project's screen quality, its instances')
        this.screenQuality.copyFrom(at.project.screenQuality());
        // (milestone 67: and its render quality, the web's on WebGL 2)
        this.renderQuality.copyFrom(at.project.renderQuality(this.webTag >= 0 ? this.webTag == 1 : webTarget(ctx)));
        // (milestone 67b: what the hooks see of the load in progress)
        this.loadProject = at.project.name;
        this.loadFiles = files;
        this.loadRootBuilt = source == SceneSource.Text ? builtPathOf(at.rivePath) : "";
        let inst = source == SceneSource.Built ? this.instanceBuilt(files, at, check, ctx, out) : this.instanceText(files, at, ctx, out);
        this.loadRootBuilt = "";
        // (out of date, and the newer text does not load: the built form
        // still draws the scene as it was last built, under the label, and
        // the text's errors stay in `errors`, rather than the label alone)
        if (inst == null && check != null && check.state == BuiltState.Stale) {
            source = SceneSource.Built;
            out.source = source;
            const textErrors = out.errors.slice(0);
            inst = this.instanceBuilt(files, at, check, ctx, out);
            if (inst != null) for (let i = 0; i < textErrors.length; i++) inst.fail(textErrors[i]);
        }
        // (the text could not be drawn and the readers read no sources:
        // that is why, more than the built form's state)
        if (inst == null && source == SceneSource.Text && options.source == SceneSource.Auto
            && !currentFileReaders().readsSources()) {
            out.reason = REASON_NO_SOURCE_READERS;
        }
        this.loadProject = "";
        this.loadFiles = null;
        this.checkMemo.clear();
        if (out.reason.length > 0 && options.unbuiltLabel) out.label = labelText(out.reason, at.rivePath);
        out.instance = inst;
        if (inst != null) {
            inst.scenePath = at.rivePath;
            inst.sourceName = sceneSourceName(source);
            inst.unbuilt = out.reason;
            inst.setLabel(out.label);
        }
        return out;
    }

    // `builtState` over any FileSource.
    builtStateFrom(files: FileSource, scenePath: string, options: SceneOptions): BuiltState {
        const place = placeOf(scenePath, options.project);
        if (!place.ok) return BuiltState.Missing;
        const state = builtCheck(files, place.value, this.checkMemo).state;
        this.checkMemo.clear();
        return state;
    }

    // A load's error, in its errors and the runtime's.
    private loadFailed(out: SceneLoad, err: string): void {
        out.errors.push(err);
        this.fail(err);
    }

    // The built source: the scene file read and loaded (once), its scene
    // instanced.
    private instanceBuilt(files: FileSource, at: ScenePlace, had: BuiltCheck?, ctx: Context?, out: SceneLoad): SceneInstance? {
        const check = had != null ? had : builtCheck(files, at, this.checkMemo);
        const built = builtPathOf(at.rivePath);
        if (check.state == BuiltState.Missing) {
            this.loadFailed(out, "load " + at.rivePath + ": no built form: " + built + " is not declared (build the Hedra project with "
                + CLI + " build, which declares it in hedra.built.rml)");
            return null;
        }
        if (check.state == BuiltState.Invalid) {
            this.loadFailed(out, "load " + at.rivePath + ": " + check.why);
            return null;
        }
        if (check.state == BuiltState.OtherMajor) {
            this.loadFailed(out, "load " + at.rivePath + ": " + built + " was built for Hedra " + check.major.toString()
                + ".x and this library is " + HEDRA_ENGINE_MAJOR.toString() + ".x (build the project again with " + CLI + " build)");
            return null;
        }
        const b = check.bundle;
        if (b == null) return null;
        const key = "built:" + at.rivePath;
        if (this.loadedKey != key) {
            this.loadedKey = "";
            this.fileRoot = "";
            this.loaders.clear();
            const before = this.errors.length;
            if (!this.useBundle(b, built, builtRootSlot(at.project.name))) {
                for (let i = before; i < this.errors.length; i++) out.errors.push(this.errors[i]);
                if (out.errors.length == 0) out.errors.push("load " + at.rivePath + ": " + built + " did not load");
                return null;
            }
            this.loadedKey = key;
        }
        // (a scene the file lacks, from the project's declared text)
        installFallback(b.root, files, at.project);
        return this.instanceOf(this.mainScene(), ctx, out);
    }

    // The text source: the project's files through the vfs fallback, the
    // scene loaded as the tools load it.
    private instanceText(files: FileSource, at: ScenePlace, ctx: Context?, out: SceneLoad): SceneInstance? {
        const root = textRootOf(at.project.name);
        installFallback(root, files, at.project);
        const key = "text:" + root;
        if (this.loadedKey != key || this.bundle != null) {
            this.bundle = null;
            this.resources = null;
            this.useFiles(root);
            this.loadedKey = key;
        }
        return this.instanceOf(at.rel, ctx, out);
    }

    // `instantiate`, its new errors the load's.
    private instanceOf(path: string, ctx: Context?, out: SceneLoad): SceneInstance? {
        const before = this.errors.length;
        const inst = this.instantiate(path, ctx);
        for (let i = before; i < this.errors.length; i++) out.errors.push(this.errors[i]);
        if (inst == null && out.errors.length == 0) out.errors.push("load " + path + ": it did not load");
        return inst;
    }

    // An error once, however often it happens.
    fail(err: string): void {
        if (!this.errors.includes(err)) this.errors.push(err);
    }
}

// Milestone 41: where a scene of a Hedra project is (loadFrom).
class ScenePlace {
    project: RegisteredProject;
    // Its path in the project ("props/fountain.rscn") and in the Rive
    // project ("world/props/fountain.rscn").
    rel: string;
    rivePath: string;

    constructor(project: RegisteredProject, rel: string) {
        this.project = project;
        this.rel = rel;
        this.rivePath = project.name.length > 0 ? project.name + "/" + rel : rel;
    }
}

const RES = "res://";

// The project and paths of `scenePath` (docs/plans/BUILD.md section 6.3):
// the project named `project` when it is not ""; else the registered one
// whose name is the longest leading directories of the path; else the only
// one registered. A res:// path is a path in that project; any other is a
// path in the Rive project, less the project's directory.
function placeOf(scenePath: string, project: string): Result<ScenePlace> {
    const all = registeredProjects();
    const res = scenePath.startsWith(RES);
    let p: RegisteredProject? = null;
    if (project.length > 0) {
        p = projectNamed(project);
        if (p == null) {
            return Result.fail<ScenePlace>("load " + scenePath + ": no Hedra project \"" + project + "\" is registered (its "
                + "hedra_project.as, which " + CLI + " build writes, registers it: " + registeredText() + ")");
        }
    } else if (!res) {
        for (let i = 0; i < all.length; i++) {
            const name = all[i].name;
            if (name.length > 0 && !scenePath.startsWith(name + "/")) continue;
            if (name.length == 0 && all.length > 1) continue;
            const had = p;
            if (had == null || name.length > had.name.length) p = all[i];
        }
        // ("" holds every path of the Rive project, when no other does)
        if (p == null) p = projectNamed("");
    }
    if (p == null && all.length == 1) p = all[0];
    if (p == null) {
        return Result.fail<ScenePlace>("load " + scenePath + ": " + (all.length == 0
            ? "no Hedra project is registered (build the Hedra project with " + CLI + " build: its hedra_project.as registers it)"
            : "no Hedra project holds it (" + registeredText() + "; name one with SceneOptions.project)"));
    }
    const found = p!;
    let rel = scenePath;
    if (res) rel = scenePath.substring(RES.length);
    else if (found.name.length > 0 && scenePath.startsWith(found.name + "/")) rel = scenePath.substring(found.name.length + 1);
    if (rel.length == 0) rel = found.mainScene;
    if (rel.length == 0) return Result.fail<ScenePlace>("load " + scenePath + ": no scene named, and the project has no main scene");
    return Result.okv<ScenePlace>(new ScenePlace(found, rel));
}

// "the registered projects are \"world\", \"\"" (for errors).
function registeredText(): string {
    const all = registeredProjects();
    if (all.length == 0) return "none is registered";
    const names = new Array<string>();
    for (let i = 0; i < all.length; i++) names.push("\"" + all[i].name + "\"");
    return "the registered projects are " + names.join(", ");
}

// What builtCheck found: the state, and what it read.
class BuiltCheck {
    state: BuiltState = BuiltState.Missing;
    // The scene file, read (Current and Stale).
    bundle: Bundle? = null;
    // OtherMajor: the major it was built for; Invalid: why.
    major: i32 = 0;
    why: string = "";
}

// Milestone 67b: a runtime's last check, by the built file's path and
// bytes (the same object read again: load_task.as reads a built file once,
// checks it in its first step and loads it in a later one, through one
// FileSource that answers the same bytes), so that the file is parsed and
// its CRC taken once (`scope`: ../rscnb/codec.as). One a runtime, not one
// a module: two Scene3Ds loading over the same frames keep their own.
export class BuiltCheckMemo {
    path: string = "";
    bytes: Uint8Array? = null;
    check: BuiltCheck? = null;
    scope: RscnbVerifyScope = new RscnbVerifyScope();
    // The scene's text last hashed, and its SHA-256: the same bytes asked
    // again (a load over frames reads its text once: load_task.as
    // KeptFiles) are not hashed again (the demo's 135 KB hall.rscn: about
    // 16 ms under rive's interpreter).
    text: Uint8Array? = null;
    textSha: Uint8Array? = null;

    // Whether the last check found the built file out of date (the load
    // task draws such a scene from its text, as loadFrom does).
    stale(): bool {
        const c = this.check;
        return c != null && c.state == BuiltState.Stale;
    }

    // Lets go of the check and of the files whose CRC this load took
    // (loadFrom and builtStateFrom do once done, a load given up too, so
    // that nothing keeps a built file's bytes alive past its load).
    clear(): void {
        this.path = "";
        this.bytes = null;
        this.check = null;
        this.text = null;
        this.textSha = null;
        forgetVerifiedRscnb(this.scope);
    }
}

// The built form of `at` against its declared text (BuiltState's cases),
// through `memo` (null: checked anew, its CRC taken).
function builtCheck(files: FileSource, at: ScenePlace, memo: BuiltCheckMemo?): BuiltCheck {
    // (milestone 67b: the file's CRC taken once in the load: ../rscnb/codec.as)
    if (memo != null) rememberVerifiedRscnb(memo.scope);
    const path = builtPathOf(at.rivePath);
    const bytes = files.read(path);
    const kept = memo != null ? memo.check : null;
    if (kept != null && bytes != null && bytes === memo!.bytes && path == memo!.path) {
        // (the text may have been edited since: its SHA-256 is compared
        // again, the bundle kept)
        if (kept.bundle != null && (kept.state == BuiltState.Current || kept.state == BuiltState.Stale)) {
            const again = checkedAgainst(files, at, kept, bytes, memo);
            if (again != null) return again;
        }
    }
    const c = checkBytes(files, at, path, bytes, memo);
    if (memo != null) {
        memo.path = path;
        memo.bytes = bytes;
        memo.check = c;
    }
    return c;
}

// `kept` (the check of these very bytes) with the declared text compared
// again; null when the file has no SRCS (nothing to compare: check anew).
function checkedAgainst(files: FileSource, at: ScenePlace, kept: BuiltCheck, bytes: Uint8Array, memo: BuiltCheckMemo?): BuiltCheck? {
    const prov = sceneProvenance(bytes, builtPathOf(at.rivePath));
    if (!prov.ok) return null;
    const p = prov.value;
    if (p == null) return kept;
    const c = new BuiltCheck();
    c.bundle = kept.bundle;
    c.state = BuiltState.Current;
    const text = files.read(at.rivePath);
    if (text != null && !sameBytes(textSha(text, memo), p.textSha256)) c.state = BuiltState.Stale;
    return c;
}

// Milestone 67b: the SHA-256 of a scene's text `text`, through `memo`
// (the same bytes hashed once: BuiltCheckMemo.text).
function textSha(text: Uint8Array, memo: BuiltCheckMemo?): Uint8Array {
    if (memo != null) {
        const had = memo.textSha;
        if (had != null && memo.text === text) return had;
    }
    const h = sha256(text);
    if (memo != null) {
        memo.text = text;
        memo.textSha = h;
    }
    return h;
}

// Milestone 67b: the parsed built file of `scenePath` (its Bundle, as
// loadFrom would use it) when builtState says Current or Stale, else null:
// what load_task.as decodes ahead, entry by entry, before loadFrom
// instances the scene from the same object (kept until that loadFrom: the
// files must answer the same bytes object again, as BlobFiles does not, so
// the load task reads through a FileSource that keeps what it read), and
// checked through `rt`'s memo (BuiltCheckMemo) when given, so that its
// loadFrom finds this check and this Bundle whatever other runtimes load
// meanwhile; without one it is checked anew.
export function builtBundleFrom(files: FileSource, scenePath: string, options: SceneOptions, rt: SceneRuntime? = null): Bundle? {
    const place = placeOf(scenePath, options.project);
    if (!place.ok) return null;
    const c = builtCheck(files, place.value, rt != null ? rt.checkMemo : null);
    return c.state == BuiltState.Current || c.state == BuiltState.Stale ? c.bundle : null;
}

// Milestone 67b: the registered project `scenePath` is in (as loadFrom
// finds it), or null.
export function projectOfScene(scenePath: string, project: string): RegisteredProject? {
    const place = placeOf(scenePath, project);
    return place.ok ? place.value.project : null;
}

function checkBytes(files: FileSource, at: ScenePlace, path: string, bytes: Uint8Array?, memo: BuiltCheckMemo? = null): BuiltCheck {
    const c = new BuiltCheck();
    if (bytes == null || bytes.length == 0) return c;
    const prov = sceneProvenance(bytes, path);
    if (!prov.ok) {
        c.state = BuiltState.Invalid;
        c.why = prov.err;
        return c;
    }
    const p = prov.value;
    // (an .rscnb without SRCS: its major cannot be told, nor its
    // text checked; it is taken as it is, docs/plans/BUILD.md section 9)
    if (p != null && p.major != HEDRA_ENGINE_MAJOR) {
        c.state = BuiltState.OtherMajor;
        c.major = p.major;
        return c;
    }
    const b = sceneFileBundle(bytes, path);
    if (!b.ok) {
        c.state = BuiltState.Invalid;
        c.why = b.err;
        return c;
    }
    c.bundle = b.value;
    c.state = BuiltState.Current;
    if (p != null) {
        const text = files.read(at.rivePath);
        if (text != null && !sameBytes(textSha(text, memo), p.textSha256)) c.state = BuiltState.Stale;
    }
    return c;
}

function sameBytes(a: Uint8Array, b: Uint8Array): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
    return true;
}

// Auto's reason for a state other than Current.
function reasonOf(c: BuiltCheck): string {
    if (c.state == BuiltState.Stale) return REASON_OUT_OF_DATE;
    if (c.state == BuiltState.OtherMajor) return REASON_OTHER_MAJOR + c.major.toString();
    if (c.state == BuiltState.Invalid) return REASON_INVALID;
    return REASON_NOT_BUILT;
}

// Where the text source puts a project's files in the vfs: /hedra, and
// the project's directory below it (so that a path under it is the same
// path in the Rive project, whichever project's root answers it).
export const TEXT_ROOT = "/hedra";

export function textRootOf(project: string): string {
    return project.length > 0 ? TEXT_ROOT + "/" + project : TEXT_ROOT;
}

// The first bundle root of a project's built scenes: BUILT_ROOT_SLOT times
// one more than the project's place among those loaded so far (so two
// projects' scenes never share a root; a clash of files within one moves
// up by one, as a bundle's does).
export const BUILT_ROOT_SLOT: i32 = 1000;
let builtProjects: Array<string>? = null;

export function builtRootSlot(project: string): i32 {
    let l = builtProjects;
    if (l == null) {
        l = new Array<string>();
        builtProjects = l;
    }
    let i = l.indexOf(project);
    if (i < 0) {
        i = l.length;
        l.push(project);
    }
    return BUILT_ROOT_SLOT * (i + 1);
}

// The files of one Hedra project under a vfs root, read through a
// FileSource: a path under the root is the project's file of that path
// (its path in the Rive project asked for); the project's hedra.yaml is
// an empty one when it is not declared (so the root is the res:// root),
// and a script the project registers that is not declared (scripts are
// compiled, not read) is a line declaring its class.
export class ProjectFiles extends VfsReadFallback {
    files: FileSource;
    project: RegisteredProject;

    constructor(files: FileSource, project: RegisteredProject) {
        super();
        this.files = files;
        this.project = project;
    }

    read(rel: string): Uint8Array? {
        const name = this.project.name;
        const path = name.length > 0 ? name + "/" + rel : rel;
        const got = this.files.read(path);
        if (got != null) return got;
        // (milestone 36: a sound is a Rive AudioAsset, not a blob: the
        // loader is told so, ../resource/audio_stream.as)
        if (isAudioPath(rel) && this.files.hasAudio(path)) return audioDeclaredMark();
        if (rel == "hedra.yaml") return new Uint8Array(0);
        if (rel.endsWith(".as")) {
            const cls = this.project.scripts().find(rel);
            if (cls != null) {
                return Uint8Array.wrap(String.UTF8.encode("// " + rel + ", compiled into the Rive project\nexport class "
                    + cls.name + " extends NodeScript {}\n"));
            }
        }
        return null;
    }
}

// Installs `files`' fallback for `project` at `root`, unless one over the
// same files is there.
function installFallback(root: string, files: FileSource, project: RegisteredProject): void {
    const had = vfs.readFallback(root);
    const ours = had != null && had instanceof ProjectFiles;
    if (ours) {
        const pf = had as ProjectFiles;
        if (pf.project === project && pf.files.sameAs(files)) return;
    }
    vfs.setReadFallback(root, new ProjectFiles(files, project));
}

// A copy of `o` (the load functions never change their caller's options).
function copyOptions(o: SceneOptions): SceneOptions {
    const c = new SceneOptions();
    c.source = o.source;
    c.unbuiltLabel = o.unbuiltLabel;
    c.project = o.project;
    return c;
}

// "the feature \"x\"" or "the features \"x\" and \"y\"", for unknown bits
// "feature bit k".
function missingNames(mask: u32): string {
    const names = new Array<string>();
    for (let i = 0; i < 32; i++) {
        const bit = <u32>1 << <u32>i;
        if ((mask & bit) == 0) continue;
        const name = featureNameOfBit(i);
        names.push(name.length > 0 ? "\"" + name + "\"" : "feature bit " + i.toString());
    }
    const list = names.length == 1 ? names[0]
        : names.slice(0, names.length - 1).join(", ") + " and " + names[names.length - 1];
    return (names.length == 1 ? "the feature " : "the features ") + list;
}

// The tree's host: a script's signal or problem, to the instance.
class InstanceHost extends SceneTreeHost {
    inst: SceneInstance;

    constructor(inst: SceneInstance) {
        super();
        this.inst = inst;
    }

    emit(from: SceneNode, signal: string, value: Value): void {
        this.inst.emitFrom(from, signal, value);
    }

    emitEvent(from: SceneNode, ev: SignalEvent, quiet: bool = false): void {
        this.inst.emitEvent(from, ev, false, quiet);
    }

    problem(message: string): void {
        this.inst.fail(message);
    }

    // Milestone 45: the animation feature's answer (null without it).
    sceneOf(node: SceneNode): ScriptScene? {
        return this.inst.sceneOf(node);
    }
}

// The tree's added-node listener: a subtree a script added, to the
// instance.
class InstanceAdded extends NodeAddedListener {
    inst: SceneInstance;

    constructor(inst: SceneInstance) {
        super();
        this.inst = inst;
    }

    added(parent: SceneNode, child: SceneNode): void {
        this.inst.nodeAdded(child);
    }

    removing(parent: SceneNode, child: SceneNode): void {
        this.inst.nodeRemoving(child);
    }
}

// Milestone 27: the run time's PrintSink (../script.as print and
// printErr): a line goes to the instance whose scripts are running
// (SceneInstance.printed), or the last one that ran. Installed when an
// instance is made, unless the program installed its own first (the game
// program writes the lines to its output).
class InstancePrintSink extends PrintSink {
    line(text: string, error: bool): void {
        this.lineAt(text, error, "", 0);
    }

    // Milestone 28: the line with its place (see the header).
    lineAt(text: string, error: bool, file: string, line: i32): void {
        const inst = printingInstance;
        if (inst != null) inst.printAt(error ? "ERROR: " + text : text, file, line);
    }

    // Milestone 28: pushError and pushWarning, the instance's errors.
    problem(text: string, warning: bool, file: string, line: i32): void {
        const inst = printingInstance;
        if (inst == null) return;
        const place = file.length > 0 ? file + ":" + line.toString() + ": " : "";
        inst.fail(place + (warning ? "WARNING: " : "") + text);
    }
}

// The instance whose scripts run now (or ran last), and the one sink.
let printingInstance: SceneInstance? = null;
let instanceSink: InstancePrintSink? = null;

// Installs the run time's sink unless another one is (see above).
function installInstanceSink(): void {
    if (currentPrintSink() != null) return;
    let s = instanceSink;
    if (s == null) {
        s = new InstancePrintSink();
        instanceSink = s;
    }
    setPrintSink(s);
}

// How many printed lines an instance keeps for takePrinted (the oldest go
// first), and how many signals it keeps for takeSignals: a host that never
// takes them does not let them grow for the instance's life.
export const MAX_PRINTED: i32 = 1000;
export const MAX_QUEUED_SIGNALS: i32 = 1000;
// How many distinct errors an instance keeps (see the header).
export const MAX_ERRORS: i32 = 100;

export class SceneInstance {
    runtime: SceneRuntime;
    scenePath: string;
    tree: SceneTree;
    // Whether scripts run and time passes (Scene3D's `playing`), and how
    // fast (`speed`, a factor of the seconds given to advance).
    playing: bool = true;
    speed: f64 = 1;
    // The seconds the current frame gave advance, not times `speed` (0
    // while not playing): what the sounds move by, as the runtime plays
    // them at their own speed (feature_audio.as).
    frameSeconds: f64 = 0;
    // Pictures made anew (see the header): the status's "drawn".
    drawn: i64 = 0;
    // Frames advanced, and the seconds of play they added up to.
    frames: i64 = 0;
    time: f64 = 0;
    // What went wrong, one line each, once (a script's problems, a load()
    // that did not load, the GPU, the plan).
    errors: Array<string> = [];
    // The errors past MAX_ERRORS, each time one came (milestone 28).
    errorsMore: i64 = 0;
    // The context it draws on (null: no GPU), and its renderer.
    ctx: Context? = null;
    renderer: FrameRenderer? = null;
    // The artboards the host gave (Scene3DView.provideArtboard), by input
    // index: what the artboards feature plays.
    artboards: Array<Artboard?> = [];
    // Set by the scripts feature: where a <connection>'s signal is
    // delivered.
    signalTarget: SignalTarget? = null;
    // How many frames were planned (buildSceneFrame, or since milestone 50
    // the last plan refreshed in place), and how many views
    // only turned (retargeted): tests see that an idle frame plans nothing.
    planned: i64 = 0;
    // Milestone 50: how many of those plans were the last one refreshed in
    // place (refreshSceneFrame) rather than made anew.
    refreshed: i64 = 0;
    retargeted: i64 = 0;
    // Milestone 67: the pictures drawn reusing the last one's passes (the
    // live textures alone changed: texturesChanged).
    reused: i64 = 0;
    // The picture's size in pixels and the host's pixels per point (draw).
    width: u32 = 0;
    height: u32 = 0;
    scale: f64 = 1;
    // Milestone 67: the layout's size in points (the last draw's), which a
    // stretched picture is presented over.
    layoutWidth: f64 = 0;
    layoutHeight: f64 = 0;
    id: i64 = 0;
    // The tree's nodes as instanced, before any script ran (nodeAt), and
    // how many nodes it has now.
    private instanced: Array<SceneNode> = [];
    private nodeCount: i32 = 0;
    // The features' parts, in the runtime's order, and the three this file
    // asks for by bit (null when not installed).
    private parts: Array<InstanceFeature> = [];
    private scriptsPart: InstanceFeature? = null;
    private artboardsPart: InstanceFeature? = null;
    private bindingsPart: InstanceFeature? = null;
    private interactionPart: InstanceFeature? = null;
    // Milestone 45: the animation feature's part, and the events fired
    // (takeEvents).
    private animationPart: InstanceFeature? = null;
    // Milestone 36: the audio feature's part (its status).
    private audioPart: InstanceFeature? = null;
    // The navigation feature's part (its status: the agents' counts).
    private navigationPart: InstanceFeature? = null;
    private firedEvents: Array<FiredEvent> = [];
    private noEvents: Array<FiredEvent> = [];
    // The events dropped (dropEvents), for the next ones (a full queue's
    // oldest is reused in place); and the timelines' signals (event_fired, a
    // `signal:` key), each made once (emitKeyed): a looping animation that
    // fires them allocates nothing a loop once each has fired.
    private spareEvents: Array<FiredEvent> = [];
    private keyed: Array<KeyedEmission> = [];
    // Milestone 49: how many events the scene fired in all (fireEvent), so
    // that a reader of the queue knows which entries are new; and whether
    // the scene writes its data (writesData), once known.
    eventsFired: i64 = 0;
    private writesKnown: bool = false;
    private writes: bool = false;
    private firesKnown: bool = false;
    private fires: bool = false;
    // Milestone 31: Play's --shapes, Godot's Debug > Visible Collision
    // Shapes: the interaction feature draws every collision shape and ray
    // into each new frame (afterPlan). Set it before the first draw.
    debugShapes: bool = false;
    // Milestone 63: Play's --navigation, Godot's Debug > Visible
    // Navigation: the navigation feature draws the map, the links and the
    // agents' paths into each new frame (afterPlan). Set it before the
    // first draw.
    debugNavigation: bool = false;
    // Changes since the last picture: one the frame must be planned again
    // for, and a view that only turned (yaw: the plan is retargeted).
    private needsPlan: bool = true;
    private needsView: bool = false;
    // Milestone 61 (see the header): the last plan drew a custom material
    // whose shader reads TIME, and a frame that played wants a new picture
    // of it.
    private timeShaders: bool = false;
    private needsPicture: bool = false;
    // Milestone 67 (see the header): only the live textures' contents
    // changed since the last picture (texturesChanged), and the picture
    // now made is drawn reusing the rest of the last one.
    private needsTextures: bool = false;
    private reuseTextures: bool = false;
    // Milestone 67: the project's render quality (setRenderQuality), the
    // Scene3D's overrides of it (setRenderScale: 0, -1 and 0 the
    // project's), the quality drawn with (opts.renderQuality, made from
    // both in `wanted`), the level-of-detail threshold asked for in the
    // layout's pixels, and the picture's size (pictureSizeInto).
    private baseQuality: RenderQuality = new RenderQuality();
    private wantedQuality: RenderQuality = new RenderQuality();
    private scaleOverride: f64 = 0;
    private modeOverride: i32 = -1;
    private densityOverride: f64 = 0;
    private pixelsOverride: f64 = 0;
    private lodPixels: f32 = RUNTIME_LOD_THRESHOLD;
    picture: PictureSize = new PictureSize();
    // Where the renderer's custom shaders' modules come from (null: the
    // program's installed source).
    private shaderSource: ShaderModuleSource? = null;
    // Milestone 67: where the surface shader's variants come from (null:
    // the program's installed source, else none: ../../render/shader/
    // variants.as).
    private variantSource: SurfaceVariantSource? = null;
    // The shader files whose fallback this instance said why it draws
    // (once a path: unbuiltShaders).
    private shadersSaid: Array<string> = [];
    private planFailed: bool = false;
    // Milestone 31: the camera the pointer picks through when the plan is
    // out of date (pickOwn): the planned frame's Camera3D node (pickNode,
    // found at each plan) where it is now, turned by the yaw. Made once.
    private pickNode: Camera3D? = null;
    private pickCamera: Camera? = null;
    private pickOwn: bool = false;
    // The camera looked through: a node path, or null for the scene's
    // current one; the yaw in degrees.
    private cameraPath: string? = null;
    private yaw: f64 = 0;
    private opts: SceneRenderOptions = SceneInstance.runtimeOptions();
    private frame: SceneFrame? = null;
    // The plan's camera before the yaw, and the turned one (kept: a turn
    // allocates nothing).
    private baseCamera: Camera? = null;
    private turned: Camera? = null;
    private image: GpuImage? = null;
    // 1 / scale: the host's points per picture pixel, which `draw` scales
    // the presented picture by (Mat2D is a value class: made on the stack
    // each draw, allocating nothing).
    private presentScale: f32 = 1;
    private signals: Array<SignalEvent> = [];
    private noSignals: Array<SignalEvent> = [];
    // The queue's copies of engine events no longer queued, for the next
    // ones (emitEvent).
    private spareSignals: Array<SignalEvent> = [];
    // Milestone 27: the lines its scripts printed (print, printErr with
    // "ERROR: " before it, as Godot's output shows them), at most
    // MAX_PRINTED, and how many there were in all (the status's
    // "printed").
    printed: Array<string> = [];
    printedCount: i64 = 0;
    // Milestone 28: where the last printed line's call is (its script's
    // res:// path and line; "" and 0: not known), the status's
    // "printed_at".
    printedFile: string = "";
    printedLine: i32 = 0;
    private event: InputEvent = new InputEvent(InputKind.PointerMove);
    // Milestone 47: the hits of the last pointer event (listenerHits), and
    // the input's serial (each pointer event takes the next) they are of.
    private hits: ListenerHits = new ListenerHits();
    private hitsEvent: i64 = -1;
    private inputSerial: i64 = 0;
    // The picker (it keeps the skinned items' posed copies between picks)
    // and the groups the parts gave for the last pick, kept.
    private picker: ListenerPicker = new ListenerPicker();
    private hitGroups: Array<SceneNode> = [];
    // How many pointer events were picked (tests: one pick an event, however
    // many parts read it).
    listenerPicks: i64 = 0;
    private host: InstanceHost? = null;
    private listener: InstanceAdded? = null;
    private disposed: bool = false;
    // What the last status() said, as one number (statusChanged).
    private statusMark: i64 = -1;
    // Milestone 41: the source a `load` drew it from ("built", "text"; ""
    // for an instance made otherwise, whose status then says neither), why
    // Auto took the text ("" when it did not), and the label drawn over it
    // (null: none).
    sourceName: string = "";
    unbuilt: string = "";
    label: UnbuiltLabel? = null;
    // Milestone 42: the view the bindings' screen outputs project through
    // (../binding/outputs.as), set before each push when `wantsOutputView`
    // (the bindings feature sets it when a binding reads screen_position or
    // screen_visible): the camera looked through now, turned by the yaw, at
    // the host's size (setViewSize: the Scene3D layout's, known before any
    // draw) or the last prepared one.
    outputView: OutputView = new OutputView();
    wantsOutputView: bool = false;
    private viewWidth: f64 = 0;
    private viewHeight: f64 = 0;
    private viewScale: f64 = 1;
    private outputCamera: Camera? = null;
    private outputNode: Camera3D? = null;
    private outputPath: string? = null;
    private outputResolved: bool = false;
    // Milestone 36: the camera cameraListener turns (made once); the
    // scene's current Camera3D it hears from before anything is planned,
    // found again when the tree's structure moves (kept arrays: no
    // allocation a frame).
    private listenerCamera: Camera? = null;
    private fallbackEpoch: i32 = -1;
    private fallbackNode: Camera3D? = null;
    private fallbackWalked: Array<SceneNode> = [];
    private fallbackStack: Array<SceneNode> = [];
    // Milestone 37: whether the tree holds an OccluderInstance3D (the
    // status's "occlusion"), found again only when the tree's structure
    // moves, through the same kept arrays as fallbackCamera: a status
    // written each frame then walks nothing and allocates nothing more.
    private occluderEpoch: i32 = -1;
    private hasOccluder: bool = false;
    // Milestone 62: the plan the status's "screen" is read from without a
    // GPU (kept: planned again in place, allocating nothing), and the
    // renderer's refusals already said (bits: 1 the screen texture, 2 the
    // reflections, 4 the depth of field).
    private screenPlan: PostPlan = new PostPlan();
    private screenRefusals: i32 = 0;
    // Milestone 36: a part set this in the advance just made because the
    // scene must keep advancing although nothing it draws changed (the
    // audio feature, while a sound plays: its clock schedules the loops'
    // passes and ends the one-shots; milestone 67, the artboards feature,
    // while a live texture's redraw is held back by its update mode, its
    // rate or being out of view and its artboard still plays). The advance
    // answers true then, and the Scene3D does not leave the scene still
    // off-screen.
    keepsRunning: bool = false;

    constructor(runtime: SceneRuntime, scenePath: string, tree: SceneTree) {
        this.runtime = runtime;
        this.scenePath = scenePath;
        this.tree = tree;
    }

    // The run time's render options: the tools' defaults but the levels of
    // detail, drawn under RUNTIME_LOD_THRESHOLD. (A static method: the
    // linter does not see a function called from a field's initialiser.)
    static runtimeOptions(): SceneRenderOptions {
        const o = new SceneRenderOptions();
        o.lodThreshold = RUNTIME_LOD_THRESHOLD;
        return o;
    }

    // Milestone 26: a mesh's levels of detail are drawn while their error,
    // projected, stays under `px` pixels (0: level 0 always). A new value
    // plans the next frame again; the same one changes nothing.
    // Milestone 67: in the layout's pixels (see the header): the plan gets
    // it in the picture's, the same at a scale of 1.
    setLodThreshold(px: f64): void {
        const v = <f32>(isFinite(px) && px > 0 ? px : 0);
        if (v == this.lodPixels) return;
        this.lodPixels = v;
        this.applyLod();
    }

    getLodThreshold(): f64 {
        return <f64>this.lodPixels;
    }

    // The plan's threshold from the one asked for and the picture's scale
    // (exactly the one asked for at a scale of 1); a new one plans again.
    private applyLod(): void {
        const ps = this.picture.pickScale;
        const v = ps == 1 ? this.lodPixels : <f32>(<f64>this.lodPixels * <f64>ps);
        if (v == this.opts.lodThreshold) return;
        this.opts.lodThreshold = v;
        this.needsPlan = true;
    }

    // Milestone 67 (see the header): the render quality the instance draws
    // with: its project's (SceneRuntime.renderQuality), under the Scene3D's
    // overrides. Another one plans the next frame again; the same one
    // changes nothing.
    setRenderQuality(q: RenderQuality): void {
        if (q.equals(this.baseQuality)) return;
        this.baseQuality.copyFrom(q);
        this.applyQuality();
    }

    getRenderQuality(): RenderQuality {
        return this.opts.renderQuality;
    }

    // Milestone 67: the Scene3D's render scale (Godot's scaling_3d_scale;
    // 0 or less: the project's), scaling mode (SCALING_3D_*; -1: the
    // project's), density cap (0: the project's; negative: none) and pixel
    // cap (likewise), over the project's quality. Allocates nothing; the
    // same values change nothing.
    setRenderScale(scale: f64, mode: i32, maxDensity: f64, maxPixels: f64): void {
        const sc = isFinite(scale) && scale > 0 ? scale : 0;
        const md = isFinite(maxDensity) ? maxDensity : 0;
        const mp = isFinite(maxPixels) ? maxPixels : 0;
        const m = mode == SCALING_3D_BILINEAR || mode == SCALING_3D_FSR ? mode : -1;
        if (sc == this.scaleOverride && m == this.modeOverride && md == this.densityOverride && mp == this.pixelsOverride) return;
        this.scaleOverride = sc;
        this.modeOverride = m;
        this.densityOverride = md;
        this.pixelsOverride = mp;
        this.applyQuality();
    }

    // opts.renderQuality made again from the project's and the overrides;
    // when it changed, the next frame is planned again (the size, the
    // output size and the frame's quality follow it).
    private applyQuality(): void {
        const w = this.wantedQuality.copyFrom(this.baseQuality);
        if (this.scaleOverride > 0) w.scaling3dScale = <f32>this.scaleOverride;
        if (this.modeOverride >= 0) w.scaling3dMode = this.modeOverride;
        if (this.densityOverride > 0) w.maxDensity = <f32>this.densityOverride;
        else if (this.densityOverride < 0) w.maxDensity = 0;
        if (this.pixelsOverride > 0) w.maxPixels = this.pixelsOverride >= <f64>i32.MAX_VALUE ? i32.MAX_VALUE : <i32>Math.round(this.pixelsOverride);
        else if (this.pixelsOverride < 0) w.maxPixels = 0;
        if (w.equals(this.opts.renderQuality)) return;
        this.opts.renderQuality.copyFrom(w);
        this.needsPlan = true;
    }

    // Milestone 62: the screen-space effects' quality the instance draws
    // with (its project's: SceneRuntime.screenQuality). Another one plans
    // the next frame again; the same one changes nothing.
    setScreenQuality(q: ScreenQuality): void {
        if (q.equals(this.opts.screenQuality)) return;
        this.opts.screenQuality.copyFrom(q);
        this.needsPlan = true;
    }

    getScreenQuality(): ScreenQuality {
        return this.opts.screenQuality;
    }

    // Takes the tree (SceneRuntime.instantiateTree): the walk as
    // instanced, the tree's host and added-node listener, each feature's
    // part attached (the scripts' ready() runs here), then the renderer.
    start(ctx: Context?, id: i64): void {
        this.ctx = ctx;
        this.id = id;
        const tree = this.tree;
        this.instanced = tree.walk();
        this.nodeCount = this.instanced.length;
        const host = new InstanceHost(this);
        this.host = host;
        tree.host = host;
        if (tree.share == null) tree.share = this.runtime.share;
        const listener = new InstanceAdded(this);
        this.listener = listener;
        tree.onAdded = listener;
        const fs = this.runtime.features;
        for (let i = 0; i < fs.length; i++) {
            const part = fs[i].forInstance(this);
            this.parts.push(part);
            const bit = fs[i].bit();
            if (bit == FEATURE_SCRIPTS) this.scriptsPart = part;
            else if (bit == FEATURE_ARTBOARDS) this.artboardsPart = part;
            else if (bit == FEATURE_BINDINGS) this.bindingsPart = part;
            else if (bit == FEATURE_INTERACTION) this.interactionPart = part;
            else if (bit == FEATURE_ANIMATION) this.animationPart = part;
            else if (bit == FEATURE_AUDIO) this.audioPart = part;
            else if (bit == FEATURE_NAVIGATION) this.navigationPart = part;
        }
        printingInstance = this;
        // (milestone 31: the interaction world first, so that the scripts'
        // _ready already queries the scene's shapes, as in Godot, where the
        // space exists before any node is ready; the navigation map next,
        // synced, so that _ready's NavigationServer3D queries already
        // answer from the scene's regions)
        const first = this.interactionPart;
        const second = this.navigationPart;
        if (first != null) first.attach(this, tree.root);
        if (second != null) second.attach(this, tree.root);
        for (let i = 0; i < this.parts.length; i++) {
            const part = this.parts[i];
            if (part !== first && part !== second) part.attach(this, tree.root);
        }
        // The GPU last: a scene without one still plays its scripts, and
        // its status says why nothing is drawn.
        if (ctx != null) {
            const r = this.runtime.rendererFor(ctx);
            if (r.ok) this.renderer = r.value;
            else this.fail(r.err);
            this.shaderSource = this.runtime.shaderModulesFor(ctx, this.runtime.shaderProject);
            // (with the tree's volatile bits, which `hedra build` OR-ed into
            // the keys it wrote: variant_assets.as variantVolatileBits)
            this.variantSource = surfaceVariantsFor(ctx, this.runtime.shaderProject, tree);
        }
    }

    // The part of the feature `bit` (features.as FEATURE_*), or null when
    // the runtime does not have it.
    feature(bit: u32): InstanceFeature? {
        const fs = this.runtime.features;
        for (let i = 0; i < fs.length && i < this.parts.length; i++) if (fs[i].bit() == bit) return this.parts[i];
        return null;
    }

    // Runs one frame of `seconds`; returns whether the next draw renders a
    // new picture (see the header). The phases are the player's
    // (features.as PHASE_*); while not `playing`, time stands still: the
    // scripts are not called and the artboards advance by 0.
    advance(seconds: f64): bool {
        if (this.disposed) return false;
        // (milestone 67b: the hooks first, e.g. the GPU objects freed last
        // frame released)
        const hooks = this.runtime.hooks;
        for (let i = 0; i < hooks.length; i++) unchecked(hooks[i]).advanced(this);
        this.frames++;
        this.frameSeconds = this.playing && seconds > 0 && isFinite(seconds) ? seconds : 0;
        const dt = this.frameSeconds * this.speed;
        if (this.playing) this.time += dt;
        let changed = false;
        let settled = false;
        this.keepsRunning = false;
        const parts = this.parts;
        printingInstance = this;
        for (let phase = 0; phase < PHASE_COUNT; phase++) {
            // (milestone 42: the outputs' view, from where the frame left
            // the camera, before the bindings push)
            if (phase == PHASE_PUSH && this.wantsOutputView) this.updateOutputView();
            for (let i = 0; i < parts.length; i++) {
                if (unchecked(parts[i]).advance(this, dt, phase)) {
                    changed = true;
                    if (phase == PHASE_SETTLE) settled = true;
                }
            }
        }
        // A state machine that changed state in the settle applied its new
        // state's keys after the bindings pushed: they push once more, as
        // Rive's settle loop runs an update pass after each change, so that
        // a to_source binding shows the settled frame in that frame rather
        // than the next.
        if (settled) {
            if (this.wantsOutputView) this.updateOutputView();
            for (let i = 0; i < parts.length; i++) unchecked(parts[i]).advance(this, dt, PHASE_PUSH);
        }
        if (changed) this.needsPlan = true;
        // (milestone 61: a shader reading TIME draws every frame that plays)
        if (this.timeShaders && dt > 0) this.needsPicture = true;
        return this.pending() || this.keepsRunning;
    }

    // Whether the next draw makes a new picture.
    pending(): bool {
        return this.needsPlan || this.needsView || this.needsPicture || this.needsTextures || this.drawn == 0;
    }

    // Milestone 49 (see the header): whether the scene writes its data,
    // asked of every part once, the first time (the tree is whole by then:
    // only a script adds a scene later, and a script writes already).
    writesData(): bool {
        if (this.writesKnown) return this.writes;
        this.writesKnown = true;
        let w = false;
        for (let i = 0; i < this.parts.length && !w; i++) if (unchecked(this.parts[i]).writesData(this)) w = true;
        this.writes = w;
        return w;
    }

    // Milestone 49: whether the scene may fire events (a scene of the tree
    // declares one, or a machine fires one), asked of every part once as
    // writesData is. (A script may fire events too: it writes already.)
    firesEvents(): bool {
        if (this.firesKnown) return this.fires;
        this.firesKnown = true;
        let f = false;
        for (let i = 0; i < this.parts.length && !f; i++) if (unchecked(this.parts[i]).firesEvents(this)) f = true;
        this.fires = f;
        return f;
    }

    // Draws the scene into the layout's `width` x `height` points at
    // `scale` pixels a point (the picture is width * scale by height *
    // scale pixels, 1 to MAX_PICTURE_SIDE a side), through the current
    // camera: a new picture when something changed (`prepare`), else the
    // last one again.
    draw(renderer: HostRenderer, width: f64, height: f64, scale: f64 = 1): void {
        this.drawScene(renderer, width, height, scale);
        // (milestone 41: last, over the picture)
        const l = this.label;
        if (l != null && !this.disposed) l.draw(renderer, width, height, scale);
    }

    // Milestone 41: shows the label `text` over the scene ("" hides it).
    setLabel(text: string): void {
        if (text.length == 0) {
            const l = this.label;
            if (l != null) l.setText("");
            return;
        }
        let l = this.label;
        if (l == null) {
            l = new UnbuiltLabel();
            this.label = l;
        }
        l.setText(text);
    }

    private drawScene(renderer: HostRenderer, width: f64, height: f64, scale: f64): void {
        const fresh = this.prepare(width, height, scale);
        const r = this.renderer;
        if (r == null) return;
        if (fresh) this.render(r);
        const img = this.image;
        if (img == null) return;
        // (milestone 67: a picture of the layout's pixels, FSR's output
        // among them, at 1 / density with the nearest filter as before;
        // one smaller or larger stretched over the layout's points with the
        // bilinear filter)
        const p = this.picture;
        let k = this.presentScale;
        let ky = k;
        let smooth = false;
        if (img.width != p.viewWidth || img.height != p.viewHeight) {
            k = <f32>(<f64>img.width > 0 ? this.layoutWidth / <f64>img.width : 1);
            ky = <f32>(<f64>img.height > 0 ? this.layoutHeight / <f64>img.height : 1);
            smooth = true;
        }
        if (k == 1 && ky == 1) {
            r.present(img, renderer, smooth);
            return;
        }
        renderer.save();
        renderer.transform(Mat2D.withScaleAndTranslation(k, ky, 0, 0));
        r.present(img, renderer, smooth);
        renderer.restore();
    }

    // Milestone 67: the layout's size in points, its pixels a point, and
    // the picture's size for them under the quality drawn with (see the
    // header), taken; the size, the output size (FSR's) and the level of
    // detail's threshold changed plan the frame again. Allocates nothing.
    private takeSize(width: f64, height: f64, s: f64): void {
        this.layoutWidth = width;
        this.layoutHeight = height;
        const p = pictureSizeInto(width, height, s, this.opts.renderQuality, this.picture);
        if (p.width != this.width || p.height != this.height) {
            this.width = p.width;
            this.height = p.height;
            this.needsPlan = true;
        }
        if (s != this.scale) this.scale = s;
        // (1 / density for the picture of before, or FSR's of the layout's
        // pixels: drawScene stretches any other)
        this.presentScale = p.native() ? p.presentScale : <f32>(1 / s);
        const ow = p.fsr ? p.viewWidth : 0;
        const oh = p.fsr ? p.viewHeight : 0;
        const o = this.opts;
        if (ow != o.outputWidth || oh != o.outputHeight) {
            o.outputWidth = ow;
            o.outputHeight = oh;
            this.needsPlan = true;
        }
        this.applyLod();
    }

    // The planning half of `draw` (no GPU needed: the tests' seam): takes
    // the size, plans the frame again when something changed (or only
    // turns its camera, for a new yaw); returns whether a new picture is
    // to be rendered. An unchanged frame allocates nothing.
    prepare(width: f64, height: f64, scale: f64 = 1): bool {
        if (this.disposed) return false;
        const s = scale > 0 && isFinite(scale) ? scale : 1;
        this.takeSize(width, height, s);
        this.reuseTextures = false;
        if (this.needsPlan || (this.frame == null && !this.planFailed)) {
            this.needsPlan = false;
            this.needsView = false;
            this.needsPicture = false;
            this.needsTextures = false;
            // (A plan that failed is tried again only after a change: its
            // error is said once, and an idle frame stays free.)
            this.planFailed = !this.plan();
            if (this.planFailed) return false;
            this.drawn++;
            return true;
        }
        if (this.needsView) {
            this.needsView = false;
            this.needsPicture = false;
            this.needsTextures = false;
            this.turn();
            this.retargeted++;
            this.drawn++;
            return true;
        }
        if (this.needsPicture && this.frame != null) {
            this.needsPicture = false;
            this.needsTextures = false;
            this.drawn++;
            return true;
        }
        // (milestone 67: the textures alone, drawn reusing the rest)
        if (this.needsTextures && this.frame != null) {
            this.needsTextures = false;
            this.reuseTextures = true;
            this.drawn++;
            this.reused++;
            return true;
        }
        return false;
    }

    // Milestone 61: whether the frame `sf` draws a custom material whose
    // shader reads TIME (asked after each plan; a loop over the frame's
    // materials, no allocation).
    private readsTime(sf: SceneFrame): bool {
        const ms = sf.frame.materials;
        for (let i = 0; i < ms.length; i++) {
            const c = unchecked(ms[i]).custom;
            if (c != null && c.program.usesTime) return true;
        }
        return false;
    }

    // Builds the frame of the tree as it is now (the shared cache builds a
    // mesh it has not seen; the renderer's uploader, or the runtime's,
    // uploads it), then turns it by the yaw.
    private plan(): bool {
        const cache = this.runtime.cache;
        // The visibility ranges' state belongs to one view: another
        // instance's planned last.
        if (cache.rangeView != this.id) {
            cache.forgetRanges();
            cache.rangeView = this.id;
        }
        const opts = this.opts;
        opts.width = this.width;
        opts.height = this.height;
        opts.camera = this.cameraPath;
        const r = this.renderer;
        const uploader = r != null ? r.uploader : this.runtime.uploader;
        // Milestone 50: the last plan made again in place when the tree
        // still draws what it held (adapter.as refreshSceneFrame), which
        // allocates nothing; else a new plan. (Not with the debug shapes,
        // which a plan adds to.)
        const last = this.frame;
        if (last != null && !this.debugShapes && !this.debugNavigation
            && refreshSceneFrame(last, this.tree, opts, cache, uploader)) {
            if (last.materialsRefilled && r != null) r.materials.valuesGeneration++;
            this.timeShaders = this.readsTime(last);
            this.planned++;
            this.refreshed++;
            this.pickOwn = false;
            for (let i = 0; i < this.parts.length; i++) this.parts[i].afterPlan(this, last);
            const base = this.baseCamera;
            if (base != null) base.copyFrom(last.frame.camera);
            if (this.yaw != 0) this.turn();
            return true;
        }
        const sf = buildSceneFrame(this.tree, opts, cache, uploader);
        if (!sf.ok) {
            this.fail(sf.err);
            this.frame = null;
            return false;
        }
        const frame = sf.value;
        this.frame = frame;
        this.timeShaders = this.readsTime(frame);
        this.planned++;
        this.pickOwn = false;
        const camNode = frame.camera.length > 0 ? this.tree.getNode(frame.camera) : null;
        this.pickNode = camNode != null && camNode instanceof Camera3D ? camNode as Camera3D : null;
        for (let i = 0; i < this.parts.length; i++) this.parts[i].afterPlan(this, frame);
        let base = this.baseCamera;
        if (base == null) {
            base = frame.frame.camera.clone();
            this.baseCamera = base;
            this.turned = frame.frame.camera.clone();
        } else {
            base.copyFrom(frame.frame.camera);
        }
        if (this.yaw != 0) this.turn();
        return true;
    }

    // The pick camera (ensurePlan): the planned Camera3D node where it is
    // now (the framed default and a preset stay as planned), turned by the
    // yaw as `turn` turns the plan's. Allocates nothing once made.
    private followCamera(): void {
        const sf = this.frame;
        if (sf == null) return;
        let pc = this.pickCamera;
        if (pc == null) {
            pc = sf.frame.camera.clone();
            this.pickCamera = pc;
        }
        const base = this.baseCamera;
        const node = this.pickNode;
        const f = sf.frame;
        if (node != null) cameraInto(node, sf.bounds, <f32>f.width / <f32>max<u32>(f.height, 1), pc);
        else if (base != null) pc.copyFrom(base);
        else return;
        const angle = <f32>(this.yaw * Math.PI / 180);
        if (angle != 0) {
            const off = (pc.eye - pc.target).rotateAxis(RENDER_UP, angle);
            pc.eye = pc.target + off;
            pc.up = pc.up.rotateAxis(RENDER_UP, angle);
        }
        this.pickOwn = true;
    }

    // Milestone 42: the layout's size in points and the host's pixels per
    // point, as the host knows them before it draws (Scene3DView.resize):
    // what the outputs' view is sized by.
    setViewSize(width: f64, height: f64, scale: f64 = 1): void {
        this.viewWidth = width > 0 && isFinite(width) ? width : 0;
        this.viewHeight = height > 0 && isFinite(height) ? height : 0;
        this.viewScale = scale > 0 && isFinite(scale) ? scale : 1;
    }

    // Milestone 42: sets `outputView` from the camera looked through now
    // (the camera path's Camera3D, else the planned frame's, else the
    // framed default), turned by the yaw, at the view's size in points; a
    // view with no size, or a scene that could not be planned, leaves it
    // not valid. Plans the frame once when none was (a headless host that
    // never draws: `rive --data-dump`); allocates nothing after.
    private updateOutputView(): void {
        const v = this.outputView;
        const sized = this.viewWidth > 0 && this.viewHeight > 0;
        const s = sized ? this.viewScale : (this.scale > 0 ? this.scale : 1);
        // (unsized: the last picture's layout pixels, none before the first,
        // as before the render scale: `picture` starts at 1 x 1)
        const drawn = this.width > 0 && this.height > 0;
        const w = sized ? this.viewWidth : drawn ? <f64>this.picture.viewWidth / s : 0;
        const h = sized ? this.viewHeight : drawn ? <f64>this.picture.viewHeight / s : 0;
        if (!(w > 0 && h > 0)) {
            v.valid = false;
            return;
        }
        if (this.frame == null && !this.planFailed) this.ensurePlan(w, h, s);
        const sf = this.frame;
        const base = this.baseCamera;
        if (sf == null || base == null) {
            v.valid = false;
            return;
        }
        let cam = this.outputCamera;
        if (cam == null) {
            cam = base.clone();
            this.outputCamera = cam;
        }
        const node = this.outputCameraNode();
        if (node != null) cameraInto(node, sf.bounds, <f32>(w / h), cam);
        else cam.copyFrom(base);
        const angle = <f32>(this.yaw * Math.PI / 180);
        if (angle != 0) {
            const off = (cam.eye - cam.target).rotateAxis(RENDER_UP, angle);
            cam.eye = cam.target + off;
            cam.up = cam.up.rotateAxis(RENDER_UP, angle);
        }
        v.setCamera(cam, w, h);
    }

    // The Camera3D the outputs look through: the camera path's (looked up
    // again only when the path changed), else the one the last plan drew
    // through (null: the framed default).
    private outputCameraNode(): Camera3D? {
        const path = this.cameraPath;
        if (path == null) return this.pickNode;
        if (!this.outputResolved || this.outputPath !== path) {
            this.outputResolved = true;
            this.outputPath = path;
            const n = this.tree.getNode(path);
            this.outputNode = n != null && n instanceof Camera3D ? n as Camera3D : null;
        }
        const own = this.outputNode;
        return own != null ? own : this.pickNode;
    }

    // Milestone 36 (../audio/listener.as): the pose the scene's sounds are
    // heard from when no AudioListener3D is current: the camera it is seen
    // through now, turned by the yaw, as the outputs' view finds it, in the
    // scene's space; before anything is planned, that Camera3D's own
    // transform. False (and `out` not valid) when there is no camera yet.
    // Allocates nothing once its camera is made.
    cameraListener(out: ListenerPose): bool {
        const sf = this.frame;
        const base = this.baseCamera;
        const node = this.outputCameraNode();
        if (sf == null || base == null) {
            // (nothing planned yet, as in a host that has not drawn, or a
            // `rive --data-dump` that never draws: the Scene3D's camera,
            // else the scene's current Camera3D, which the first plan
            // would see the scene through)
            const cam = node != null ? node : this.fallbackCamera();
            if (cam == null) {
                out.valid = false;
                return false;
            }
            listenerFromNode(cam, out);
            return out.valid;
        }
        let cam = this.listenerCamera;
        if (cam == null) {
            cam = base.clone();
            this.listenerCamera = cam;
        }
        if (node != null) cameraInto(node, sf.bounds, 1, cam);
        else cam.copyFrom(base);
        const angle = <f32>(this.yaw * Math.PI / 180);
        if (angle != 0) {
            const off = (cam.eye - cam.target).rotateAxis(RENDER_UP, angle);
            cam.eye = cam.target + off;
            cam.up = cam.up.rotateAxis(RENDER_UP, angle);
        }
        listenerFromLook(modelToScene(cam.eye), modelToScene(cam.target), modelToScene(cam.up), out);
        out.node = node;
        return out.valid;
    }

    // The scene's current Camera3D as SceneTree.currentCamera finds it
    // (the first current one in tree order outside a SubViewport, else the
    // first), from a walk kept until the tree's structure moves.
    private fallbackCamera(): Camera3D? {
        const e = treeStructureEpoch();
        if (e == this.fallbackEpoch) return this.fallbackNode;
        this.fallbackEpoch = e;
        const all = this.fallbackWalked;
        this.tree.walkInto(all, this.fallbackStack);
        let first: Camera3D? = null;
        let found: Camera3D? = null;
        for (let i = 0; i < all.length && found == null; i++) {
            const n = unchecked(all[i]);
            const isCamera = n instanceof Camera3D;
            if (!isCamera || underSubViewport(n)) continue;
            const c = n as Camera3D;
            if (c.current) found = c;
            else if (first == null) first = c;
        }
        all.length = 0;
        this.fallbackNode = found != null ? found : first;
        return this.fallbackNode;
    }

    // Points the plan at its camera turned by the yaw about the vertical
    // axis through the point it looks at (allocates nothing).
    private turn(): void {
        const frame = this.frame;
        const base = this.baseCamera;
        const t = this.turned;
        if (frame == null || base == null || t == null) return;
        t.copyFrom(base);
        const angle = <f32>(this.yaw * Math.PI / 180);
        if (angle != 0) {
            const off = (base.eye - base.target).rotateAxis(RENDER_UP, angle);
            t.eye = base.target + off;
            t.up = base.up.rotateAxis(RENDER_UP, angle);
        }
        retargetSceneFrame(frame, t);
    }

    // The GPU half: renders the planned frame (the artboards drawn into
    // their textures first) and keeps the picture.
    private render(r: FrameRenderer): void {
        const sf = this.frame;
        if (sf == null) return;
        // Milestone 61 (see the header): the custom shaders' modules and
        // their TIME, the scene's clock.
        r.shaderModules = this.shaderSource;
        r.surfaceVariants = this.variantSource;
        sf.frame.shaderTime = <f32>(this.time % <f64>SHADER_TIME_ROLLOVER);
        r.beginFrame();
        for (let i = 0; i < this.parts.length; i++) this.parts[i].beforeDraw(this, r);
        this.runtime.cache.upload(sf.frame, r.uploader);
        this.runtime.cache.retireReplaced(r);
        const img = this.reuseTextures ? r.renderFrameReusing(sf.frame, REUSE_TEXTURES) : r.renderFrame(sf.frame);
        this.reuseTextures = false;
        this.screenRefused(r);
        r.clearWarnings();
        if (!img.ok) {
            this.fail(img.err);
            this.image = null;
            return;
        }
        this.image = img.value;
        this.unbuiltShaders(sf.frame);
    }

    // Milestone 62: the screen-space effects the host refused in the frame
    // just drawn (the renderer's warnings, about to be cleared), said in
    // the status's errors as a warning, once each (allocates nothing once
    // said, or when none was raised).
    private screenRefused(r: FrameRenderer): void {
        const ws = r.warnings;
        for (let i = 0; i < ws.length; i++) {
            const w = unchecked(ws[i]);
            const bit = w == SCREEN_PIPELINE_WARNING ? 1 : w == SSR_PIPELINE_WARNING ? 2 : w == DOF_PIPELINE_WARNING ? 4 : 0;
            if (bit == 0 || (this.screenRefusals & bit) != 0) continue;
            this.screenRefusals |= bit;
            this.fail("WARNING: " + w);
        }
    }

    // Milestone 61 (docs/engine/SHADERS.md, "The built form"): when the
    // picture drew a fallback, a warning once a shader file for each
    // custom material of `frame` whose module the Rive project does not
    // hold (the scene was edited and not built again): why, and that
    // `hedra build` makes it (AssetShaderModules.reasonOf). Only with the
    // project's own source: the tools say their shaders' errors themselves.
    // Allocates nothing once each path was said.
    private unbuiltShaders(frame: RenderFrame): void {
        const src = this.shaderSource;
        const rs = this.renderStats();
        if (src == null || rs == null || rs.shaderFallbacks == 0) return;
        const mats = frame.materials;
        for (let i = 0; i < mats.length; i++) {
            const c = unchecked(mats[i]).custom;
            if (c == null || this.shadersSaid.includes(c.program.path)) continue;
            if (src.stateOf(c.program) != SHADER_UNAVAILABLE) continue;
            this.shadersSaid.push(c.program.path);
            this.fail("WARNING: " + src.reasonOf(c.program));
        }
    }

    // A pointer event at (x, y) in the layout's points; scripts get it in
    // the picture's pixels. Whether a script handled it. (One event object
    // is reused: a pointer moving over the scene allocates nothing.)
    // Milestone 31: every feature hears it, the scripts first (Godot's
    // _input before the physics picking), so the interaction feature knows
    // whether a script handled it; a feature without an `input` costs a
    // call.
    pointer(kind: InputKind, x: f32, y: f32, id: i32): bool {
        if (this.disposed || this.parts.length == 0) return false;
        const s = <f32>this.scale;
        const e = this.reset(kind);
        e.x = x * s;
        e.y = y * s;
        e.pointer = id;
        this.inputSerial++;
        printingInstance = this;
        const scripts = this.scriptsPart;
        let handled = scripts != null && scripts.input(this, e);
        for (let i = 0; i < this.parts.length; i++) {
            const part = unchecked(this.parts[i]);
            if (part !== scripts && part.input(this, e)) handled = true;
        }
        return handled;
    }

    // Milestone 47: what the pointer event `e` (its kind, place and id, as
    // `pointer` set them) hits, for state machine listeners and for the
    // artboards shown in 3D (../listen/pick.as): picked once per event, the
    // first part that asks, then kept for the others (`hitsEvent` names the
    // event). Picked only when a part wants hits (features.as
    // listenerGroups: the animation part while a running machine has a
    // pointer listener, the artboards part while the scene shows an
    // artboard texture); otherwise, and for a pointer exit, nothing is hit
    // and the hits are not valid (an exit is due). The collision objects
    // cast are those of the parts' groups, in the tree's interaction world
    // (the interaction feature's SceneTree.world, brought up to the tree
    // first as its space queries are; none without the feature or without
    // groups); the camera is the picture's, or the planned camera node
    // where it is now when the plan is out of date (pickCamera, as
    // `pickRay`). Allocates nothing once warm.
    listenerHits(e: InputEvent): ListenerHits {
        const h = this.hits;
        if (this.hitsEvent == this.inputSerial) return h;
        this.hitsEvent = this.inputSerial;
        const groups = this.hitGroups;
        groups.length = 0;
        let wanted = false;
        for (let i = 0; i < this.parts.length; i++) {
            if (unchecked(this.parts[i]).listenerGroups(this, groups)) wanted = true;
        }
        if (!wanted || e.kind == InputKind.PointerExit || this.disposed) {
            h.clear();
            h.screenX = e.x;
            h.screenY = e.y;
            return h;
        }
        let world: InteractionWorld? = null;
        if (groups.length > 0) {
            const space = this.tree.world.directSpaceState;
            if (space instanceof InteractionWorld) {
                const w = space as InteractionWorld;
                if (!w.holdSync) w.update();
                if (w.objects.length > 0) world = w;
            }
        }
        this.listenerPicks++;
        const own = this.pickCamera;
        // (milestone 67: picked in the picture's pixels; the listeners read
        // the layout's, as scripts do)
        const p = this.picture;
        this.picker.pick(this.frame, e.x * p.pickScale, e.y * p.pickScaleY, world, groups, h,
            this.pickOwn && own != null ? own : null);
        h.screenX = e.x;
        h.screenY = e.y;
        return h;
    }

    // Milestone 31: plans the frame at `width` x `height` points and
    // `scale` when none was planned yet, so that a pointer event before the
    // first picture (a headless host: Play's --dump-frames between its
    // captures, `rive --pointer` before its screenshot) picks through the
    // view it will be drawn with. The next draw plans and renders as it
    // would have (no picture is counted). A frame already planned but out
    // of date (something changed since: a camera moved, a new yaw) is not
    // planned again, which allocates: the picking follows the planned
    // camera node where it is now instead (pickCamera, allocating
    // nothing), so a headless host that draws only some frames picks
    // through the moved camera. The host calls it before `pointer`.
    ensurePlan(width: f64, height: f64, scale: f64 = 1): void {
        if (this.disposed) return;
        if (this.frame != null) {
            if (this.needsPlan || this.needsView) this.followCamera();
            return;
        }
        const s = scale > 0 && isFinite(scale) ? scale : 1;
        this.takeSize(width, height, s);
        this.planFailed = !this.plan();
        this.needsPlan = true;
    }

    // Milestone 31: the ray through the point (x, y) of the last picture,
    // in the layout's pixels (as scripts get the pointer; milestone 67:
    // turned into the picture's by its scale), in scene space (Y up,
    // global), into `out`; false, leaving `out` as it was, before the first
    // plan. The camera is the picture's (its yaw included). Allocates
    // nothing.
    pickRay(x: f32, y: f32, out: Ray): bool {
        const sf = this.frame;
        if (sf == null) return false;
        const f = sf.frame;
        const own = this.pickCamera;
        const p = this.picture;
        pixelRayInto(this.pickOwn && own != null ? own : f.camera, f.width, f.height, x * p.pickScale, y * p.pickScaleY, out);
        out.origin = modelToScene(out.origin);
        out.dir = modelToScene(out.dir);
        return true;
    }

    // A key event; whether a script handled it.
    key(kind: InputKind, key: i32, shift: bool, control: bool, alt: bool, meta: bool): bool {
        const part = this.scriptsPart;
        if (part == null || this.disposed) return false;
        const e = this.reset(kind);
        e.key = key;
        e.shift = shift;
        e.control = control;
        e.alt = alt;
        e.meta = meta;
        printingInstance = this;
        return part.input(this, e);
    }

    private reset(kind: InputKind): InputEvent {
        const e = this.event;
        e.kind = kind;
        e.x = 0;
        e.y = 0;
        e.pointer = 0;
        e.key = 0;
        e.shift = false;
        e.control = false;
        e.alt = false;
        e.meta = false;
        e.handled = false;
        return e;
    }

    // Binds the scene's bindings (and the artboards that bind the scene's
    // view model) to `vm` (null unbinds): the view model whose paths the
    // scene's <binding>s name.
    bind(vm: ViewModel?): void {
        for (let i = 0; i < this.parts.length; i++) this.parts[i].bind(this, vm);
        this.touch();
    }

    // docs/plans/RIVE_MODEL.md section 5's name for bind: the scene's own
    // view model instance, as Rive's bindViewModelInstance binds an
    // artboard's.
    bindViewModel(vm: ViewModel?): void {
        this.bind(vm);
    }

    // The global view model `name` the scene's global="<name>" bindings
    // read and write is `vm` from now on, in place of the one the host's
    // Context has under that name (null: the Context's again). A host
    // shows a scene against data of its own this way, or a scene drawn
    // where no Context holds the global.
    bindGlobal(name: string, vm: ViewModel?): void {
        for (let i = 0; i < this.parts.length; i++) this.parts[i].bindGlobal(this, name, vm);
        this.touch();
    }

    // The node at `path` from the instance's root (SceneNode.getNode's
    // forms), or null.
    node(path: string): SceneNode? {
        return this.tree.getNode(path);
    }

    // The frame planned last (null before the first plan): what the
    // renderer binds (tests).
    get planFrame(): SceneFrame? {
        return this.frame;
    }

    // The node at `index` of the tree's walk as it was instanced (before
    // any script ran: the typed handles' numbering, fixed when instanced), or
    // null.
    nodeAt(index: i32): SceneNode? {
        return index >= 0 && index < this.instanced.length ? this.instanced[index] : null;
    }

    // Makes the Camera3D at `path` the one looked through ("" for the
    // scene's own current camera); false, changing nothing, when there is
    // no camera there.
    setCamera(path: string): bool {
        if (path.length == 0) {
            if (this.cameraPath != null) {
                this.cameraPath = null;
                this.needsPlan = true;
            }
            return true;
        }
        const n = this.tree.getNode(path);
        if (n == null || !(n instanceof Camera3D)) return false;
        const was = this.cameraPath;
        if (was == null || was != path) {
            this.cameraPath = path;
            this.needsPlan = true;
        }
        return true;
    }

    // The camera path set (null: the scene's current camera).
    camera(): string? {
        return this.cameraPath;
    }

    // Turns the view about the vertical axis through the point the camera
    // looks at, to `degrees` (Scene3D's `yaw`; counter-clockwise seen from
    // above, so the camera orbits the scene's centre of view).
    setYaw(degrees: f64): void {
        const d = isFinite(degrees) ? degrees : 0;
        if (d == this.yaw) return;
        this.yaw = d;
        this.needsView = true;
    }

    getYaw(): f64 {
        return this.yaw;
    }

    // Something changed outside the instance's knowledge (a handle moved a
    // node): the next draw renders.
    touch(): void {
        this.needsPlan = true;
    }

    // Milestone 67 (docs/engine/PERFORMANCE.md, "Pictures that change"):
    // only the contents of the frame's live textures changed (an artboard
    // texture drawn again, ../player/artboards.as): the next draw makes a
    // new picture of the frame as planned, without planning it again, drawn
    // with FrameRenderer.renderFrameReusing (REUSE_TEXTURES), which keeps
    // what the change cannot reach (a plan or a turn asked for meanwhile
    // draws in full instead).
    texturesChanged(): void {
        this.needsTextures = true;
    }

    // The signals emitted since the last call, in order (an empty list,
    // shared and not to be changed, when there were none). Each is the
    // caller's to keep: an engine signal's event is a copy of the one its
    // connections heard (that one is filled again by the next emission),
    // its arguments as they were. An input_event's `input` is the pointer
    // event as the host passes it, which the host may reuse.
    takeSignals(): Array<SignalEvent> {
        if (this.signals.length == 0) return this.noSignals;
        const out = this.signals;
        this.signals = [];
        return out;
    }

    // Forgets the signals not taken, keeping the list's storage, so that
    // a caller that never takes them (the Scene3D component: its
    // connections are delivered as they are emitted) does not let the
    // queue grow for the instance's life. Allocates nothing.
    dropSignals(): void {
        const q = this.signals;
        if (q.length == 0) return;
        for (let i = 0; i < q.length; i++) this.spare(unchecked(q[i]));
        q.length = 0;
    }

    // A queued event leaves the queue: a copy is kept for the next one.
    private spare(e: SignalEvent): void {
        if (!e.queuedCopy) return;
        e.node = null;
        e.input = null;
        this.spareSignals.push(e);
    }

    // How many signals wait for takeSignals.
    get queuedSignals(): i32 {
        return this.signals.length;
    }

    // Milestone 45 (docs/plans/RIVE_MODEL.md section 5): the events the
    // scene fired since the last call, oldest first (./events.as; at most
    // MAX_QUEUED_EVENTS kept). The same empty list, not to be changed, when
    // there were none.
    takeEvents(): Array<FiredEvent> {
        if (this.firedEvents.length == 0) return this.noEvents;
        const out = this.firedEvents;
        this.firedEvents = [];
        return out;
    }

    // Milestone 49: how many events wait for takeEvents, and the `i`th of
    // them (oldest first), left in the queue: the Scene3D component reads
    // their names into its view model's `events` this way, allocating
    // nothing, before it drops them.
    get queuedEvents(): i32 {
        return this.firedEvents.length;
    }

    queuedEvent(i: i32): FiredEvent {
        return this.firedEvents[i];
    }

    // Milestone 45: the scene whose root is `sceneRoot` fired its event
    // `name` (`decl`, null when it declares none), `delay` seconds before
    // the frame's end: queued for takeEvents, and the root emits
    // EVENT_FIRED_SIGNAL with the name, to its connections, scripts and
    // bindings as any signal. The animation feature's (a key, a script's
    // scene.fireEvent).
    fireEvent(sceneRoot: SceneNode, name: string, decl: EventDecl?, delay: f32): void {
        // (the root's event_fired first: its event, made once, carries the
        // scene's path, named again only when the tree's names or shape
        // changed, which the queued event takes too)
        const k = this.keyedEmission(sceneRoot, EVENT_FIRED_SIGNAL, name);
        const q = this.firedEvents;
        let e: FiredEvent;
        if (q.length >= MAX_QUEUED_EVENTS) e = q.shift();
        else if (this.spareEvents.length > 0) e = this.spareEvents.pop();
        else e = new FiredEvent("", "");
        e.scene = k.event.from;
        e.name = name;
        e.delay = delay;
        e.decl = decl;
        q.push(e);
        this.eventsFired++;
        this.emitEvent(sceneRoot, k.event);
        // (milestone 47: the event's fire bindings, and the machines' event
        // listeners; features.as eventFired)
        for (let i = 0; i < this.parts.length; i++) unchecked(this.parts[i]).eventFired(this, sceneRoot, name, decl);
    }

    // Milestone 45: forgets the events not taken, keeping them for the
    // next ones, so that a caller that never takes them (the Scene3D
    // component, as with dropSignals) does not let the queue grow, nor a
    // looping event allocate. Allocates nothing.
    dropEvents(): void {
        const q = this.firedEvents;
        if (q.length == 0) return;
        for (let i = 0; i < q.length; i++) {
            const e = unchecked(q[i]);
            e.decl = null;
            this.spareEvents.push(e);
        }
        q.length = 0;
    }

    // Milestone 45: a timeline's `signal:<name>` key crossed on `from`: the
    // node emits `signal` with no argument, as a script's emit does, its
    // event made once (emitKeyed).
    emitKeyed(from: SceneNode, signal: string): void {
        this.emitEvent(from, this.keyedEmission(from, signal, null).event);
    }

    // The event `from` emits `signal` with (`text`: its argument, a
    // string; null none), made the first time (a scan: a scene keys a
    // handful), its path named again when the tree's names or shape have
    // changed since.
    private keyedEmission(from: SceneNode, signal: string, text: string?): KeyedEmission {
        const list = this.keyed;
        let k: KeyedEmission? = null;
        for (let i = 0; i < list.length; i++) {
            const c = unchecked(list[i]);
            if (c.node === from && c.event.signal == signal && c.text == text) {
                k = c;
                break;
            }
        }
        if (k == null) {
            // (the emissions of nodes freed since go: a scene instanced
            // and freed again and again keeps no list of the dead)
            let w = 0;
            for (let i = 0; i < list.length; i++) {
                const c = unchecked(list[i]);
                if (!c.node.freed) list[w++] = c;
            }
            list.length = w;
            const made = new KeyedEmission(from, text, new SignalEvent(from.pathFrom(this.tree.root), signal,
                text != null ? Value.str(text) : Value.nil()));
            made.epoch = treeStructureEpoch();
            list.push(made);
            return made;
        }
        const epoch = treeStructureEpoch();
        if (k.epoch != epoch) {
            k.epoch = epoch;
            k.event.from = from.pathFrom(this.tree.root);
        }
        return k;
    }

    // Milestone 45: plays the root scene's animation `name` from its start
    // (replacing the one this played before; "" stops it), through the
    // animation feature; false when it has none of that name, or the
    // runtime has no animation feature. The Scene3D's `animation`.
    playAnimation(name: string): bool {
        const p = this.animationPart;
        return p != null ? p.playAnimation(this, name) : false;
    }

    // Milestone 45: the scene `node` belongs to, for its script
    // (NodeScript.scene), through the animation feature (null without it).
    sceneOf(node: SceneNode): ScriptScene? {
        const p = this.animationPart;
        return p != null ? p.sceneOf(this, node) : null;
    }

    // Milestone 46: runs the root scene's state machine `name` ("" its
    // default_state_machine, "-" none) from its start, in place of the one
    // running (the Scene3D's `stateMachine`); false for a name the scene
    // does not have (the status's error says so, once).
    playStateMachine(name: string): bool {
        const p = this.animationPart;
        if (p != null) return p.playStateMachine(this, name);
        // (no animation part: the scene has no machines, so "" and "-"
        // run none, as asked, and a name is one it does not have)
        if (name.length == 0 || name == "-") return true;
        this.fail("state machine \"" + name + "\" not found in " + this.scenePath);
        return false;
    }

    // Milestone 46: the view model instance the scene is bound to, and the
    // global `name` as the bindings find it (the state machines' data);
    // null when there is none.
    dataValues(): ViewModelValues? {
        for (let i = 0; i < this.parts.length; i++) {
            const v = this.parts[i].boundValues(this);
            if (v != null) return v;
        }
        return null;
    }

    globalValues(name: string): ViewModelValues? {
        for (let i = 0; i < this.parts.length; i++) {
            const v = this.parts[i].globalValues(this, name);
            if (v != null) return v;
        }
        return null;
    }

    // The artboard of input `index` (Scene3DView.provideArtboard), for the
    // artboards feature.
    provideArtboard(index: i32, a: Artboard?): void {
        if (index < 0) return;
        while (this.artboards.length <= index) this.artboards.push(null);
        if (a != null) this.artboards[index] = a;
    }

    // A script emitted `signal` from `from` (the tree's host): queued for
    // takeSignals, and delivered to each connection from that node for
    // that signal (a one-shot one then removed).
    emitFrom(from: SceneNode, signal: string, value: Value): void {
        this.emitEvent(from, new SignalEvent(from.pathFrom(this.tree.root), signal, value), true);
    }

    // Milestone 31: the same with the event made (an engine signal's, its
    // emitter's own: SceneTreeHost.emitEvent, filled again by its next
    // emission), so that emitting allocates nothing once the queue has
    // grown: the connections hear the event itself, the queue keeps a copy
    // (one area's body_entered twice in a frame queues the two bodies),
    // from the copies dropped before. Each feature hears it after its
    // connections were called (InstanceFeature.signalEmitted).
    // A `quiet` one touches the plan only when it reached a connection (a
    // handler may move what is drawn): SceneTreeHost.emitEvent.
    emitEvent(from: SceneNode, ev: SignalEvent, owned: bool = false, quiet: bool = false): void {
        const signal = ev.signal;
        // (a host that never takes them keeps the last MAX_QUEUED_SIGNALS)
        if (this.signals.length >= MAX_QUEUED_SIGNALS) this.spare(this.signals.shift());
        let q = ev;
        if (!owned) {
            const sp = this.spareSignals;
            q = sp.length > 0 ? sp.pop() : new SignalEvent("", "", Value.nil());
            q.queuedCopy = true;
            q.copyFrom(ev);
        }
        this.signals.push(q);
        // (taken first: a handler may connect or disconnect; tree.as)
        const tree = this.tree;
        const list = tree.emitting;
        const start = list.length;
        tree.takeConnections(from, signal);
        const end = list.length;
        const target = this.signalTarget;
        for (let i = start; i < end; i++) {
            const c = unchecked(list[i]);
            // (a target freed outside the live tree keeps its connections
            // until that tree's end of frame: it is skipped whichever comes
            // first; the others, a handler may have disconnected)
            if (c.to.freed || (i > start && !tree.stillConnected(c))) continue;
            if (target != null && !target.deliver(c.to, c.method, ev)) {
                this.fail("signal " + signal + " of " + ev.from + ": " + c.to.pathFrom(tree.root)
                    + " has no script to call " + c.method + " on");
            }
        }
        list.length = start;
        for (let i = 0; i < this.parts.length; i++) unchecked(this.parts[i]).signalEmitted(this, from, ev);
        if (!quiet || end > start) this.touch();
    }

    // A script added `child` under the tree (the tree's listener): the
    // features attach its subtree (its scripts are made ready), and the
    // next draw shows it.
    // A child added under a node leaving the tree (in an _exitTree) is
    // not in it: neither counted nor attached (the runtime's attachSubtree
    // refuses it alike), as nodeRemoving already took its parent's subtree
    // out of the count.
    nodeAdded(child: SceneNode): void {
        const p = child.parent;
        if (p != null && p.isLeavingTree()) return;
        this.nodeCount += subtreeSize(child);
        for (let i = 0; i < this.parts.length; i++) this.parts[i].attach(this, child);
        this.touch();
    }

    // Milestone 27: a script is removing `child` from the tree (still
    // linked): the features let go of its subtree (its scripts' _exitTree),
    // and the next draw shows it gone.
    nodeRemoving(child: SceneNode): void {
        this.nodeCount -= subtreeSize(child);
        for (let i = 0; i < this.parts.length; i++) this.parts[i].detach(this, child);
        this.touch();
    }

    // Milestone 27: one line a script printed (the run time's PrintSink),
    // kept for takePrinted (the oldest dropped past MAX_PRINTED).
    print(line: string): void {
        this.printAt(line, "", 0);
    }

    // Milestone 28: the same, with where the call is ("" and 0: not
    // known; see the header).
    printAt(line: string, file: string, at: i32): void {
        if (this.printed.length >= MAX_PRINTED) this.printed.shift();
        this.printed.push(line);
        this.printedCount++;
        this.printedFile = file;
        this.printedLine = file.length > 0 ? at : 0;
    }

    // The lines printed since the last call, in order (an empty list,
    // shared and not to be changed, when there were none).
    takePrinted(): Array<string> {
        if (this.printed.length == 0) return NO_LINES;
        const out = this.printed;
        this.printed = [];
        return out;
    }

    // An error once, however many frames repeat it; past MAX_ERRORS of
    // them, only counted (and not marked as a change of the status: it
    // says the count the next time it is written).
    fail(err: string): void {
        if (this.errors.includes(err)) return;
        if (this.errors.length < MAX_ERRORS) this.errors.push(err);
        else this.errorsMore++;
    }

    // The status line (see the header).
    status(): string {
        this.statusMark = this.mark();
        const errs = new Array<string>();
        for (let i = 0; i < this.errors.length; i++) errs.push(jsonQuote(this.errors[i]));
        const scripts = this.scriptsPart;
        const artboards = this.artboardsPart;
        const bindings = this.bindingsPart;
        const interaction = this.interactionPart;
        const animation = this.animationPart;
        const audio = this.audioPart;
        const navigation = this.navigationPart;
        return "{\"frames\":" + this.frames.toString()
            + ",\"time\":" + displayF64(Math.round(this.time * 1e6) / 1e6)
            + ",\"scene\":" + jsonQuote(this.scenePath)
            + (this.sourceName.length > 0 ? ",\"source\":" + jsonQuote(this.sourceName) : "")
            + (this.unbuilt.length > 0 ? ",\"unbuilt\":" + jsonQuote(this.unbuilt) : "")
            + ",\"nodes\":" + this.nodeCount.toString()
            + (scripts != null ? scripts.status(this) : ",\"scripts\":0,\"ready\":0,\"process\":0")
            + ",\"drawn\":" + this.drawn.toString()
            + (this.printedCount > 0 ? ",\"printed\":" + this.printedCount.toString() : "")
            + (this.printedFile.length > 0
                ? ",\"printed_at\":" + jsonQuote(this.printedFile + ":" + this.printedLine.toString()) : "")
            + (artboards != null ? artboards.status(this) : "")
            + (bindings != null ? bindings.status(this) : "")
            + (interaction != null ? interaction.status(this) : "")
            + (animation != null ? animation.status(this) : "")
            + (audio != null ? audio.status(this) : "")
            + (navigation != null ? navigation.status(this) : "")
            + this.occlusionStatus()
            + this.shadersStatus()
            + this.screenStatus()
            + this.pictureStatus()
            + this.variantsStatus()
            + this.hooksStatus()
            + ",\"gpu\":" + (this.renderer != null ? "true" : "false")
            + ",\"textures\":" + jsonQuote(this.runtime.textureChoice.name)
            + ",\"triangles\":" + this.triangles().toString()
            + ",\"errors\":[" + errs.join(",") + "]"
            + (this.errorsMore > 0 ? ",\"errors_more\":" + this.errorsMore.toString() : "") + "}";
    }

    // Milestone 67b: the hooks' members (runtime_hooks.as statusPart: the
    // resources', the remaps'); "" without hooks, whose status is as it was.
    private hooksStatus(): string {
        const hooks = this.runtime.hooks;
        if (hooks.length == 0) return "";
        let s = "";
        for (let i = 0; i < hooks.length; i++) s += hooks[i].statusPart(this);
        return s;
    }

    // Milestone 37: for a scene with an OccluderInstance3D (hidden ones
    // too: a binding shows them), the last picture's occluders of its world
    // and the items they hid (the renderer's RenderStats; 0 and 0 before a
    // picture or without a GPU), as `,"occlusion":{"occluders":N,
    // "occluded":N}`; "" for any other scene, whose status is as it was.
    private occlusionStatus(): string {
        if (!this.treeHasOccluder()) return "";
        const rs = this.renderStats();
        const occluders = rs != null ? rs.occluders : 0;
        const occluded = rs != null ? rs.culledOcclusion : 0;
        return ",\"occlusion\":{\"occluders\":" + occluders.toString() + ",\"occluded\":" + occluded.toString() + "}";
    }

    // Milestone 61: when the last picture drew a custom material (its
    // draws with their own pipelines, or with their fallback), how many
    // of each (the renderer's RenderStats), as `,"shaders":{"drawn":N,
    // "fallback":M}`; "" for any other picture, whose status is as it was.
    private shadersStatus(): string {
        const rs = this.renderStats();
        if (rs == null || rs.shaderDraws + rs.shaderFallbacks == 0) return "";
        return ",\"shaders\":{\"drawn\":" + rs.shaderDraws.toString() + ",\"fallback\":" + rs.shaderFallbacks.toString() + "}";
    }

    // Milestone 62: when the last picture drew a screen-space effect, which
    // (`,"screen":{"ssr":B,"refraction":B,"dof":B}`); "" for any other
    // picture, whose status is as it was.
    private screenStatus(): string {
        const bits = this.screenBits();
        if (bits == 0) return "";
        return ",\"screen\":{\"ssr\":" + ((bits & 1) != 0 ? "true" : "false")
            + ",\"refraction\":" + ((bits & 2) != 0 ? "true" : "false")
            + ",\"dof\":" + ((bits & 4) != 0 ? "true" : "false") + "}";
    }

    // Milestone 67: the 3D picture's pixels, `,"picture":[W,H]`, while
    // they are not the layout's (a render scale or a cap applies); "" at
    // the layout's pixels, whose status is as it was.
    private pictureStatus(): string {
        const p = this.picture;
        if (p.native()) return "";
        return ",\"picture\":[" + p.width.toString() + "," + p.height.toString() + "]";
    }

    // Milestone 67: the last picture's surface variants (the renderer's
    // VariantStats: its ranges drawn with a specialised shader, with the
    // ubershader, and waiting for a variant to compile), as
    // `,"variants":{"drawn":N,"ubershader":M,"pending":P}` while drawn or
    // pending are not 0; "" otherwise, whose status is as it was.
    private variantsStatus(): string {
        const r = this.renderer;
        if (r == null) return "";
        const v = r.variants.stats;
        if (v.drawn == 0 && v.pending == 0) return "";
        return ",\"variants\":{\"drawn\":" + v.drawn.toString() + ",\"ubershader\":" + v.uber.toString()
            + ",\"pending\":" + v.pending.toString() + "}";
    }

    // The screen-space effects the last picture drew, as bits (1 the
    // reflections, 2 the refraction, 4 the depth of field): with a GPU,
    // what the renderer drew (RenderStats ssrTraced, refracted, dofDrawn:
    // the plan less what the host refused), 0 before a picture; without
    // one, what post.as planPostInto plans (a plan-only instance's); 0
    // before a plan. Allocates nothing.
    private screenBits(): i32 {
        const r = this.renderer;
        if (r != null) {
            const st = r.lastStats;
            return (st.ssrTraced ? 1 : 0) | (st.refracted ? 2 : 0) | (st.dofDrawn ? 4 : 0);
        }
        const sf = this.frame;
        if (sf == null) return 0;
        const p = planPostInto(sf.frame, true, this.screenPlan);
        return (p.ssr ? 1 : 0) | (p.refraction ? 2 : 0) | (p.dof ? 4 : 0);
    }

    // Whether the tree holds an OccluderInstance3D, walked again only when
    // its structure moved (kept arrays: allocates nothing a frame).
    private treeHasOccluder(): bool {
        const e = treeStructureEpoch();
        if (e == this.occluderEpoch) return this.hasOccluder;
        this.occluderEpoch = e;
        const all = this.fallbackWalked;
        this.tree.walkInto(all, this.fallbackStack);
        let has = false;
        for (let i = 0; i < all.length && !has; i++) has = unchecked(all[i]) instanceof OccluderInstance3D;
        all.length = 0;
        this.hasOccluder = has;
        return has;
    }

    // Milestone 28 (the Monitors of a played game, host/src/play/remote):
    // the nodes in the tree now (the status's "nodes").
    get nodeTotal(): i32 {
        return this.nodeCount;
    }

    // Milestone 28: what the last picture's main pass drew (its draw calls,
    // mesh copies and triangles: the renderer's RenderStats, kept in place),
    // or null before a picture or without a GPU. Allocates nothing.
    renderStats(): RenderStats? {
        const r = this.renderer;
        return r != null ? r.lastStats : null;
    }

    // The triangles the last plan draws, each mesh at the level of detail
    // chosen for its camera (the status's "triangles"; 0 before a plan).
    private triangles(): i64 {
        const f = this.frame;
        return f != null ? f.triangles : 0;
    }

    // Whether the status says anything new but "frames" and "time" since
    // the last `status()` (allocates nothing).
    statusChanged(): bool {
        return this.mark() != this.statusMark;
    }

    // What the status says, but frames and time, as one number.
    private mark(): i64 {
        let m: i64 = this.nodeCount;
        m = m * 1000003 + this.drawn;
        m = m * 1000003 + this.triangles();
        m = m * 1000003 + this.errors.length;
        m = m * 1000003 + this.printedCount;
        m = m * 31 + (this.renderer != null ? 1 : 0);
        for (let i = 0; i < this.parts.length; i++) m = m * 1000003 + unchecked(this.parts[i]).stamp(this);
        // (milestone 37: the status's occlusion, 0 and 0 for a scene
        // without occluders, which adds nothing)
        const rs = this.renderStats();
        if (rs != null && (rs.occluders != 0 || rs.culledOcclusion != 0)) {
            m = m * 1000003 + rs.occluders;
            m = m * 1000003 + rs.culledOcclusion;
        }
        // (milestone 61: the status's shaders, nothing without them)
        if (rs != null && (rs.shaderDraws != 0 || rs.shaderFallbacks != 0)) {
            m = m * 1000003 + rs.shaderDraws;
            m = m * 1000003 + rs.shaderFallbacks;
        }
        // (milestone 62: the status's screen, nothing without the effects)
        const screen = this.screenBits();
        if (screen != 0) m = m * 31 + screen;
        // (milestone 67: the picture's size and the variants, nothing at
        // the layout's pixels without them)
        const p = this.picture;
        if (!p.native()) m = (m * 1000003 + p.width) * 1000003 + p.height;
        const r = this.renderer;
        if (r != null) {
            const v = r.variants.stats;
            if (v.drawn != 0 || v.pending != 0) m = ((m * 1000003 + v.drawn) * 1000003 + v.uber) * 1000003 + v.pending;
        }
        // (milestone 67b: the hooks' parts)
        const hooks = this.runtime.hooks;
        for (let i = 0; i < hooks.length; i++) m = m * 1000003 + unchecked(hooks[i]).statusMark(this);
        return m;
    }

    // Releases the instance's own resources (not the shared ones): its
    // features' parts, its renderer, the tree's watch.
    dispose(): void {
        if (this.disposed) return;
        this.disposed = true;
        for (let i = 0; i < this.parts.length; i++) this.parts[i].dispose(this);
        // (milestone 67b: the hooks let go of what the instance held)
        const hooks = this.runtime.hooks;
        for (let i = 0; i < hooks.length; i++) hooks[i].instanceDisposed(this.runtime, this);
        this.tree.onAdded = null;
        this.tree.host = null;
        const r = this.renderer;
        if (r != null) this.runtime.releaseRenderer(r);
        this.renderer = null;
        this.image = null;
        this.frame = null;
        this.signalTarget = null;
        if (printingInstance === this) printingInstance = null;
    }
}

// The empty list takePrinted answers (shared, never changed).
const NO_LINES: Array<string> = [];

// How many nodes the subtree at `n` holds (itself included).
function subtreeSize(n: SceneNode): i32 {
    let count = 1;
    for (let i = 0; i < n.children.length; i++) count += subtreeSize(n.children[i]);
    return count;
}

// Milestone 67: whether the `.web` feature tag applies to a runtime drawing
// on `ctx`'s GPU: the website's runtime, a browser build of rive drawing
// with WebGL 2 and running no script threads. A script sees no adapter
// string and no platform, so it is told by the two together: the shader
// target is GLSL (rive/gpu's target 1, render/gpu/device.as backendName
// "gl") and the job pool has no thread (rive/jobs Jobs.threads() 0, a
// browser build without threads). A native OpenGL or OpenGL ES host, which
// draws with GLSL too, runs script threads, so it draws with the plain
// lines, as a Metal, Vulkan or Direct3D one does. No Context: no.
export function webTarget(ctx: Context?): bool {
    return ctx != null && abi.rive_gpu_shader_target() == 1 && Jobs.threads() == 0;
}

// A size in pixels: rounded, 1 to MAX_PICTURE_SIDE.
export function pixels(x: f64): u32 {
    if (!(x >= 1)) return 1;
    if (x > <f64>MAX_PICTURE_SIDE) return MAX_PICTURE_SIDE;
    return <u32>Math.round(x);
}

// The runtime a module shares between its Scene3D components and its own
// code: one per module, made on first use (the module's generated entry
// sets it).
let shared: SceneRuntime? = null;

export function sharedRuntime(): SceneRuntime? {
    return shared;
}

export function setSharedRuntime(rt: SceneRuntime?): void {
    shared = rt;
}

// Milestone 45: one signal a timeline makes a node emit (a `signal:` key,
// or a scene root's event_fired with an event's name), its event kept for
// every emission after the first (SceneInstance.emitEvent hears and
// queues it as an engine signal's, Milestone 31). `epoch`: the tree's
// structure epoch its path was named at.
class KeyedEmission {
    node: SceneNode;
    text: string?;
    event: SignalEvent;
    epoch: i32 = 0;

    constructor(node: SceneNode, text: string?, event: SignalEvent) {
        this.node = node;
        this.text = text;
        this.event = event;
    }
}
