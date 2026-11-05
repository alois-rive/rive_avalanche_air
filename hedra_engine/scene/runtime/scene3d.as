// The Scene3D component's engine (milestone 39): what the library's
// layout script (hedra_engine/scene3d.as, class Scene3D extends Layout)
// hands everything to, so that a designer places a 3D scene on an
// artboard, sizes it with layout and drives it from state machines and
// data binding, with no code.
//
// It reads the view model bound to its artboard (Context.viewModel()),
// named Scene3D in the project's RML (docs/cli/BUILD.md section 8),
// on every advance, by these property names (any may be absent: then its
// default holds):
//
//   scene    string  the scene's bundle path ("" : the module's default
//                    scene)
//   camera   string  the Camera3D's node path ("" : the scene's current one)
//   playing  bool    scripts run and time passes (default true)
//   speed    number  a factor of time (default 1)
//   yaw      number  degrees the view turns about the vertical axis
//                    (SceneInstance.setYaw; default 0)
//   lodThreshold number  the pixels under which a mesh's generated level
//                    of detail is drawn (SceneInstance.setLodThreshold;
//                    default 1, Godot's mesh_lod_threshold; 0 draws every
//                    mesh whole), the layout's pixels whatever the render
//                    scale (as Godot's is the viewport's)
//   renderScale  number  milestone 67 (docs/engine/PERFORMANCE.md, "Render
//                    scale"): Godot's scaling_3d_scale, 0.25 to 2, over the
//                    project's rendering/scaling_3d/scale (0, the default:
//                    the project's)
//   scalingMode  string  Godot's scaling_3d_mode, bilinear or fsr, over the
//                    project's ("", the default: the project's; another
//                    name is the status's error, the project's mode drawn)
//   maxDensity   number  the 3D picture's pixels a point at most, over the
//                    project's rendering/scaling_3d/max_density (0, the
//                    default: the project's; negative: no cap)
//   maxPixels    number  the 3D picture's pixels at most, over the
//                    project's rendering/scaling_3d/max_pixels (0, the
//                    default: the project's; negative: no cap)
//   animation string the root scene's LinearAnimation played from its
//                    start ("" : none; default ""), as
//                    SceneInstance.playAnimation plays it; a change plays
//                    the new one from its start (or stops), a scene switch
//                    plays it in the new scene, and a name the scene does
//                    not have is the status's error
//   stateMachine string the root scene's state machine run ("": its
//                    default_state_machine, the first it declares unless
//                    that says otherwise; "-": none; default ""), as
//                    SceneInstance.playStateMachine runs it: set at a
//                    scene's load and on each change, from its start; a
//                    name the scene does not have is the status's error
//   data     view model (nested), optional: the instance the scene's
//                    <binding>s run against (SceneInstance.bind)
//   status   string  written: the instance's status line, whenever it says
//                    something new (`rive <project> --data-dump` shows it)
//   events   string  written (milestone 49): the names of the events the
//                    scene and every scene it instances fired since the
//                    last advance's (during it, and by the pointer between
//                    the two), oldest first, joined by "\n"; "" when none.
//                    Written only when it changes
//   loadBudget number milestone 67b (docs/engine/RESOURCES.md, "Loading"):
//                    the milliseconds an advance spends loading a scene at
//                    most, by the load's estimate (load_task.as): 0 (the
//                    default) the project's loading/frame_budget_msec (its
//                    `.web` one on the web runtime; 0 unless hedra.yaml
//                    says otherwise: the whole load in one advance), a
//                    negative number the whole load in one advance
//   progress number  written (milestone 67b): how far the scene's load is,
//                    0 to 1 (LoadTask.progress), only when it changes: 1
//                    once the scene shown is loaded
//   resources string written (milestone 67b): the run time's resources,
//                    {"count":N,"refs":R,"cpu":B,"gpu":B,"textures":T,
//                    "buffers":U,"fallbacks":F} (runtime_resources.as
//                    resourcesText), only when they change
//   resourceSummary string written (milestone 67b): the same, for a
//                    reader: "7 resources, 15 references\nCPU 42.2 KB, GPU
//                    47.4 KB" (and a third line "2 read from source" when
//                    any is a fallback; runtime_resources.as
//                    resourcesSummary), written with `resources`
//
// (`turn`, a boolean, is the example's state machine's alone: its Turning
// state's animation keys a hidden shape bound two way to `yaw`.)
//
// A change of `scene` disposes the instance and makes one of the new
// scene; the others apply to the instance there is. Every Scene3D of a
// module shares the module's SceneRuntime (scene_runtime.as
// sharedRuntime), loaded once from the bundle's blob, so they share their
// GPU meshes. An artboard texture's artboard arrives as the layout's input
// artboard_<i> (the project's RML wires them, docs/cli/BUILD.md
// section 8) and is handed over with `provideArtboard`.
//
// Reading the view model allocates nothing per frame: each property's
// handle is looked up once (Scene3DModel), numbers and booleans are read as
// they are, and a string is read into a kept buffer and compared with the
// last one's bytes, so a new string is made only when it changed. The
// status is written only when the instance's status says something new
// (SceneInstance.statusChanged), so an idle Scene3D allocates nothing.
//
// Signals: a script's signal reaches its connections as it is emitted; the
// instance's queue of them (SceneInstance.takeSignals, for code that runs
// an instance itself) has no reader here, so it is emptied on every
// advance, before the instance's: a signal can still be taken between an
// advance and the next, and the queue never holds more than one frame's.
// The same holds for the events its timelines fire (SceneInstance.
// takeEvents, dropEvents): they reach the scene's connections and bindings
// as `event_fired` when fired, and a looping one allocates nothing.
//
// Milestone 49 (docs/plans/RIVE_MODEL.md sections 3.6 and 7: the events
// reach a host that polls): `events`. The queue is read without being
// taken (SceneInstance.queuedEvent), its new entries told by the count of
// events the instance fired (eventsFired): those fired between two
// advances (a pointer listener's) are read before the queue is dropped,
// those fired during the advance after it. Their names are kept (the
// strings the instance has; nothing is copied) and compared with the last
// written, so an unchanged list writes nothing; one name is written as it
// is, and several joined once and kept with the names they were joined
// from (the last SCENE3D_JOINED_KEPT lists), so that a loop firing the
// same events again allocates nothing.
// An advance with no event after "" compares nothing and writes nothing.
//
// Off-screen (PLAN.md, milestone 39: the run time skips scenes
// that are off-screen): a Scene3D whose layout has no area (resized to 0
// wide or high), or that was drawn once and then asked for a draw on
// SCENE3D_OFFSCREEN_FRAMES advances in a row without getting one (scrolled
// away, hidden), leaves its instance still: no script processes, no
// binding is read, time stands still. The view model is still read, so a
// scene switch or a camera or yaw change still asks for a draw, and the
// first draw wakes it. A draw is only missed when one was asked for (an
// advance that returned true): a host that draws only on change and an
// idle scene never look off-screen. A view never drawn at all (a headless
// `rive --data-dump`, which draws nothing, or a host that hid it before
// its first draw) is taken for off-screen only after
// SCENE3D_UNDRAWN_FRAMES such advances (10 s at 60 a second), so that a
// dump of fewer frames still shows the scripts running and a view hidden
// from the start does not run for ever.
//
// Milestone 49 (docs/plans/RIVE_MODEL.md section 7): a scene that writes
// its data (SceneInstance.writesData: a two_way, to_source or signal
// binding, an Event's fire binding, a state machine with a
// ListenerViewModelChange or a StateMachineFireTrigger, a script, an
// artboard texture played bound to the scene's instance, whose 2D machine
// may write it) is never left still: what a 2D state machine reads of it
// must not depend on whether the 3D view is on screen, so off-screen it
// keeps advancing (the host draws nothing; `keptRunning` counts those
// advances, `skipped` only the ones left still). Nor is a scene that
// declares events while the view model has `events` (SceneInstance
// .firesEvents), which lists them. A scene that only reads stays as above.
//
// Milestone 41: the library's Scene3D (hedra_engine/scene3d.as) runs this view
// in its loading mode (initLoading): `scene` is a path in the Rive project
// ("world/courtyard.rscn"; "" the main scene of the only registered
// Hedra project), and each scene shown is loaded into a runtime of its
// own (the factory's: every feature installed) through SceneRuntime.load,
// from the source the view model's `source` names (auto, text, built;
// default auto). With `unbuiltLabel` (default true), a scene Auto drew
// from its text carries the label (label.as), and a scene that could not
// be drawn at all draws the label alone. A change of either reloads or
// relabels the scene; reading them allocates nothing while unchanged. A
// Scene3DView given its scenes by `init` (a module's shared runtime) is
// unchanged.
//
// Milestone 45: `animation` (above) is how a baked Rive project plays a
// scene's timeline with no state machine and no code; it is read as
// `scene` is, allocating nothing while it is unchanged.
//
// Milestone 46: `stateMachine` (above) is how a baked Rive project runs
// one of a scene's state machines with no code (the default one runs
// without it); read as `scene` is, allocating nothing while unchanged.
// `animation` keeps its meaning and plays over the machine (set
// `stateMachine` to "-" to play the timeline alone).
//
// Milestone 67: the four render-scale properties are read each advance as
// lodThreshold is (numbers as they are, the mode's string compared with
// the last one's bytes), so a timeline keying renderScale or a binding
// driving it costs no allocation; a new value plans the next frame again
// (SceneInstance.setRenderScale).
//
// Milestone 42: each advance hands the instance the layout's size
// (SceneInstance.setViewSize), so that the bindings' screen outputs
// (screen_position, screen_visible) are measured in the layout's points
// before any draw: a headless `rive --data-dump` draws nothing.
//
// Milestone 67b (docs/engine/RESOURCES.md, "Loading"): in the loading mode
// a scene is loaded by a LoadTask (load_task.as) stepped once an advance
// with the budget above, Godot's load_threaded_request on one thread. While
// it loads, the scene shown before (if any) keeps advancing and drawing as
// it was (the view model's camera, animation and the rest are applied to
// the new scene, not to it), and the advance asks for a draw, so that the
// host keeps advancing; once the new scene is ready the old instance is
// disposed (what both use stays loaded) and the new one advances in that
// same advance. With no scene before, nothing is drawn but the label a
// load that failed left alone. A budget of 0 is the load of before: one
// advance, the whole load. When the scene is ready one line goes to the
// log (`hedra: loaded world/study.rscn (built) in 412.3 ms over 31 frames,
// worst step 14.0 ms (the tree)`; one advance: `... in 412.3 ms`). `loadBudget` is
// read as a number (no allocation), `progress` written as one, and
// `resources` only when its mark changes, so an idle Scene3D still
// allocates nothing.

import { Context } from "rive/host";
import { Artboard } from "rive/artboard";
import { PropertyBoolean, PropertyNumber, PropertyString, ViewModel } from "rive/data";
import { Renderer as HostRenderer } from "rive/renderer";
import { abi } from "rive/bindings";
import { jsonQuote } from "../../base/json";
import { InputKind } from "../script";
import { RUNTIME_LOD_THRESHOLD, SceneInstance, SceneRuntime, sharedRuntime } from "./scene_runtime";
import { BlobFiles, FileSource, SceneLoad, SceneOptions, SceneSource, sceneSourceName, sceneSourceNamed } from "./sources";
import { registeredProjects } from "./projects";
import { LoadTask } from "./load_task";
import { projectOfScene, webTarget } from "./scene_runtime";
import { resourcesMark, resourcesSummary, resourcesText } from "./runtime_resources";
import { UnbuiltLabel, labelText } from "./label";
import { SCALING_3D_MODE_NAMES } from "../../render/quality";

// The view model's name and its properties' (see the header).
export const SCENE3D_VIEW_MODEL = "Scene3D";
export const SCENE3D_SCENE = "scene";
export const SCENE3D_CAMERA = "camera";
export const SCENE3D_PLAYING = "playing";
export const SCENE3D_SPEED = "speed";
export const SCENE3D_YAW = "yaw";
export const SCENE3D_LOD_THRESHOLD = "lodThreshold";
export const SCENE3D_DATA = "data";
export const SCENE3D_STATUS = "status";
// Milestone 41: the library's Scene3D's.
export const SCENE3D_SOURCE = "source";
export const SCENE3D_UNBUILT_LABEL = "unbuiltLabel";
// Milestone 45: the root scene's animation played.
export const SCENE3D_ANIMATION = "animation";
// Milestone 46: the root scene's state machine run.
export const SCENE3D_STATE_MACHINE = "stateMachine";
// Milestone 49: the events fired since the last advance (written).
export const SCENE3D_EVENTS = "events";
// Milestone 67: the 3D's render scale, mode and caps.
export const SCENE3D_RENDER_SCALE = "renderScale";
export const SCENE3D_SCALING_MODE = "scalingMode";
export const SCENE3D_MAX_DENSITY = "maxDensity";
export const SCENE3D_MAX_PIXELS = "maxPixels";
// Milestone 67b: the load's budget (read), its progress and the run
// time's resources (written).
export const SCENE3D_LOAD_BUDGET = "loadBudget";
export const SCENE3D_PROGRESS = "progress";
export const SCENE3D_RESOURCES = "resources";
export const SCENE3D_RESOURCE_SUMMARY = "resourceSummary";
// What `events` joins the names with.
export const SCENE3D_EVENTS_SEPARATOR = "\n";
// How many lists of several names `events` keeps joined (see the header):
// a loop whose frames fire a few different sets of events reuses them.
export const SCENE3D_JOINED_KEPT: i32 = 8;

// Makes the runtime a scene is loaded into (loading mode): every feature
// installed (hedra_engine/scene3d.as newSceneRuntime).
export type SceneRuntimeFactory = () => SceneRuntime;

// The advances in a row that asked for a draw and got none, after which a
// drawn Scene3D counts as off-screen (see the header): more than a host
// advancing a few times per draw could miss.
export const SCENE3D_OFFSCREEN_FRAMES: i32 = 10;
// The same for a Scene3D never drawn at all (see the header): long enough
// for a headless dump of the run time (the suites dump at most 120
// frames), short enough that a view hidden before its first draw stops.
export const SCENE3D_UNDRAWN_FRAMES: i32 = 600;

// What Scene3DView reads and writes, by name: the bound view model
// (RiveScene3DModel), or a test's fake. A string getter returns the same
// string while the value is unchanged.
export abstract class Scene3DModel {
    abstract scene(): string;
    abstract camera(): string;
    abstract playing(fallback: bool): bool;
    abstract speed(fallback: f64): f64;
    abstract yaw(fallback: f64): f64;
    // Milestone 26: `lodThreshold` (the default when absent).
    lodThreshold(fallback: f64): f64 {
        return fallback;
    }
    // The nested `data` view model, or null.
    abstract data(): ViewModel?;
    // Milestone 41: `source` ("" when absent) and `unbuiltLabel` (the
    // default when absent): the library's Scene3D's.
    source(): string {
        return "";
    }
    unbuiltLabel(fallback: bool): bool {
        return fallback;
    }
    // Milestone 45: `animation` ("" when absent).
    animation(): string {
        return "";
    }
    // Milestone 46: `stateMachine` ("" when absent).
    stateMachine(): string {
        return "";
    }
    // Milestone 67: `renderScale`, `maxDensity`, `maxPixels` (the default
    // when absent) and `scalingMode` ("" when absent).
    renderScale(fallback: f64): f64 {
        return fallback;
    }
    scalingMode(): string {
        return "";
    }
    maxDensity(fallback: f64): f64 {
        return fallback;
    }
    maxPixels(fallback: f64): f64 {
        return fallback;
    }
    // Whether there is a `status` to write.
    abstract hasStatus(): bool;
    abstract writeStatus(s: string): void;
    // Milestone 49: whether there is an `events` to write (false when
    // absent), and the write.
    hasEvents(): bool {
        return false;
    }
    writeEvents(s: string): void {}
    // Milestone 67b: `loadBudget` (the default when absent), and whether
    // there are a `progress` and a `resources` to write, and the writes.
    loadBudget(fallback: f64): f64 {
        return fallback;
    }
    hasProgress(): bool {
        return false;
    }
    writeProgress(v: f64): void {}
    hasResources(): bool {
        return false;
    }
    writeResources(s: string): void {}
    hasResourceSummary(): bool {
        return false;
    }
    writeResourceSummary(s: string): void {}
}

// A string property read without allocating while it is unchanged: its
// bytes into a kept buffer, compared with the last read's. The runtime hands
// a string over as UTF-16 code units (since rive 1.5.1), so `n` counts bytes
// of UTF-16.
class StringReader {
    prop: PropertyString?;
    private bytes: Uint8Array = new Uint8Array(64);
    private last: Uint8Array = new Uint8Array(64);
    private lastLength: i32 = -1;
    text: string = "";

    constructor(prop: PropertyString?) {
        this.prop = prop;
    }

    read(): string {
        const p = this.prop;
        if (p == null) return "";
        const h = p.handle;
        const n = <i32>abi.rive_data_string_get(h, 0, 0);
        if (n <= 0) {
            if (this.lastLength != 0) {
                this.lastLength = 0;
                this.text = "";
            }
            return this.text;
        }
        if (this.bytes.length < n) {
            this.bytes = new Uint8Array(n);
            this.last = new Uint8Array(n);
        }
        fillUnsafe(h, this.bytes, n);
        if (n == this.lastLength && same(this.bytes, this.last, n)) return this.text;
        for (let i = 0; i < n; i++) unchecked(this.last[i] = unchecked(this.bytes[i]));
        this.lastLength = n;
        this.text = String.UTF16.decode(this.bytes.buffer.slice(0, n));
        return this.text;
    }
}

unsafe function fillUnsafe(handle: u32, into: Uint8Array, n: i32): void {
    abi.rive_data_string_get(handle, into.dataStart, <u32>n);
}

function same(a: Uint8Array, b: Uint8Array, n: i32): bool {
    for (let i = 0; i < n; i++) if (unchecked(a[i]) != unchecked(b[i])) return false;
    return true;
}

// The Scene3D view model bound to the artboard.
export class RiveScene3DModel extends Scene3DModel {
    vm: ViewModel;
    private sceneReader: StringReader;
    private cameraReader: StringReader;
    private sourceReader: StringReader;
    private animationReader: StringReader;
    private stateMachineReader: StringReader;
    private scalingModeReader: StringReader;
    private renderScaleProp: PropertyNumber?;
    private maxDensityProp: PropertyNumber?;
    private maxPixelsProp: PropertyNumber?;
    private labelProp: PropertyBoolean?;
    private playingProp: PropertyBoolean?;
    private speedProp: PropertyNumber?;
    private yawProp: PropertyNumber?;
    private lodProp: PropertyNumber?;
    private statusProp: PropertyString?;
    private eventsProp: PropertyString?;
    private loadBudgetProp: PropertyNumber?;
    private progressProp: PropertyNumber?;
    private resourcesProp: PropertyString?;
    private summaryProp: PropertyString?;
    private dataVm: ViewModel? = null;
    private dataLooked: bool = false;

    constructor(vm: ViewModel) {
        super();
        this.vm = vm;
        this.sceneReader = new StringReader(vm.getString(SCENE3D_SCENE));
        this.cameraReader = new StringReader(vm.getString(SCENE3D_CAMERA));
        this.sourceReader = new StringReader(vm.getString(SCENE3D_SOURCE));
        this.animationReader = new StringReader(vm.getString(SCENE3D_ANIMATION));
        this.stateMachineReader = new StringReader(vm.getString(SCENE3D_STATE_MACHINE));
        this.scalingModeReader = new StringReader(vm.getString(SCENE3D_SCALING_MODE));
        this.renderScaleProp = vm.getNumber(SCENE3D_RENDER_SCALE);
        this.maxDensityProp = vm.getNumber(SCENE3D_MAX_DENSITY);
        this.maxPixelsProp = vm.getNumber(SCENE3D_MAX_PIXELS);
        this.labelProp = vm.getBoolean(SCENE3D_UNBUILT_LABEL);
        this.playingProp = vm.getBoolean(SCENE3D_PLAYING);
        this.speedProp = vm.getNumber(SCENE3D_SPEED);
        this.yawProp = vm.getNumber(SCENE3D_YAW);
        this.lodProp = vm.getNumber(SCENE3D_LOD_THRESHOLD);
        this.statusProp = vm.getString(SCENE3D_STATUS);
        this.eventsProp = vm.getString(SCENE3D_EVENTS);
        this.loadBudgetProp = vm.getNumber(SCENE3D_LOAD_BUDGET);
        this.progressProp = vm.getNumber(SCENE3D_PROGRESS);
        this.resourcesProp = vm.getString(SCENE3D_RESOURCES);
        this.summaryProp = vm.getString(SCENE3D_RESOURCE_SUMMARY);
    }

    scene(): string {
        return this.sceneReader.read();
    }

    camera(): string {
        return this.cameraReader.read();
    }

    source(): string {
        return this.sourceReader.read();
    }

    animation(): string {
        return this.animationReader.read();
    }

    stateMachine(): string {
        return this.stateMachineReader.read();
    }

    unbuiltLabel(fallback: bool): bool {
        const p = this.labelProp;
        return p != null ? p.value : fallback;
    }

    playing(fallback: bool): bool {
        const p = this.playingProp;
        return p != null ? p.value : fallback;
    }

    speed(fallback: f64): f64 {
        const p = this.speedProp;
        return p != null ? <f64>p.value : fallback;
    }

    yaw(fallback: f64): f64 {
        const p = this.yawProp;
        return p != null ? <f64>p.value : fallback;
    }

    lodThreshold(fallback: f64): f64 {
        const p = this.lodProp;
        return p != null ? <f64>p.value : fallback;
    }

    renderScale(fallback: f64): f64 {
        const p = this.renderScaleProp;
        return p != null ? <f64>p.value : fallback;
    }

    scalingMode(): string {
        return this.scalingModeReader.read();
    }

    maxDensity(fallback: f64): f64 {
        const p = this.maxDensityProp;
        return p != null ? <f64>p.value : fallback;
    }

    maxPixels(fallback: f64): f64 {
        const p = this.maxPixelsProp;
        return p != null ? <f64>p.value : fallback;
    }

    // (Looked up once: a view model's nested instance is fixed once bound.)
    data(): ViewModel? {
        if (!this.dataLooked) {
            this.dataLooked = true;
            const d = this.vm.getViewModel(SCENE3D_DATA);
            if (d != null) this.dataVm = d.value;
        }
        return this.dataVm;
    }

    hasStatus(): bool {
        return this.statusProp != null;
    }

    writeStatus(s: string): void {
        const p = this.statusProp;
        if (p != null) p.value = s;
    }

    hasEvents(): bool {
        return this.eventsProp != null;
    }

    // (the std hands the string's own UTF-16 to the host: nothing is
    // allocated)
    writeEvents(s: string): void {
        const p = this.eventsProp;
        if (p != null) p.value = s;
    }

    loadBudget(fallback: f64): f64 {
        const p = this.loadBudgetProp;
        return p != null ? <f64>p.value : fallback;
    }

    hasProgress(): bool {
        return this.progressProp != null;
    }

    writeProgress(v: f64): void {
        const p = this.progressProp;
        if (p != null) p.value = <f32>v;
    }

    hasResources(): bool {
        return this.resourcesProp != null;
    }

    writeResources(s: string): void {
        const p = this.resourcesProp;
        if (p != null) p.value = s;
    }

    hasResourceSummary(): bool {
        return this.summaryProp != null;
    }

    writeResourceSummary(s: string): void {
        const p = this.summaryProp;
        if (p != null) p.value = s;
    }
}

export class Scene3DView {
    // The scene shown when the view model's `scene` is empty or absent.
    defaultScene: string = "";
    // The artboard textures' sources, in the order of the layout's inputs
    // (artboard_0, artboard_1, ...).
    artboardSources: Array<string> = [];
    // The scenes' view model sources (which artboard binds the scene's
    // view model, feature_artboards.as artboardViewModelOf).
    artboardViewModel: Array<bool> = [];
    instance: SceneInstance? = null;
    runtime: SceneRuntime? = null;
    ctx: Context? = null;
    // The view model read (null until the host bound one; a test sets its
    // own with useModel).
    model: Scene3DModel? = null;
    // The layout's size in points and pixels per point (resize).
    width: f64 = 0;
    height: f64 = 0;
    scale: f64 = 1;
    // How many instances were made (a scene switch makes one).
    made: i32 = 0;
    // The bundle path of the instance's scene (or of the scene that failed
    // to instance), and the camera path applied to it.
    private shown: string = "";
    private failed: bool = false;
    private failureSaid: bool = false;
    private cameraApplied: string = "";
    // Milestone 45: the animation played in the instance shown (cleared
    // when another is made, so that it plays there too).
    private animationApplied: string = "";
    // Milestone 46: the state machine run in the instance shown ("" on a
    // new instance, which runs its default already).
    private stateMachineApplied: string = "";
    // Milestone 67: the scaling mode last said to be no mode (said once a
    // value).
    private modeRefused: string = "";
    private dataBound: bool = false;
    // Milestone 49: the instance was told no `data` comes (bind(null)).
    private dataNone: bool = false;
    // Milestone 49: whether the view model has `events` (the last
    // advance's): a scene that fires events then runs off-screen too.
    private eventsWanted: bool = false;
    private provided: Array<Artboard?> = [];
    private frames: i64 = 0;
    // Off-screen (see the header): whether the host resized and drew the
    // view at all, whether the last advance asked for a draw, and the
    // advances in a row that asked for one and did not get it.
    private sized: bool = false;
    private drawnOnce: bool = false;
    private asked: bool = false;
    private missed: i32 = 0;
    // The advances that left the instance still because it was off-screen.
    skipped: i64 = 0;
    // Milestone 49: the advances an off-screen instance ran because its
    // scene writes its data (see the header).
    keptRunning: i64 = 0;
    // Milestone 49, `events` (see the header): the names written last (the
    // instance's strings), those read since (pending), the instance's
    // eventsFired when the queue was last read, and the last lists of
    // several names joined (at most SCENE3D_JOINED_KEPT), with their texts;
    // the next one to replace once they are all used.
    private eventNames: Array<string> = [];
    private pendingNames: Array<string> = [];
    private eventsMark: i64 = 0;
    private joinedNames: Array<Array<string>> = [];
    private joinedTexts: Array<string> = [];
    private joinedNext: i32 = 0;
    // Milestone 41, the loading mode (see the header): on, the factory of
    // each scene's runtime, the files read (null: the context's blobs), the
    // source and label asked for, the last load, and the label drawn alone
    // when it made no instance.
    loading: bool = false;
    factory: SceneRuntimeFactory? = null;
    files: FileSource? = null;
    source: SceneSource = SceneSource.Auto;
    unbuiltLabel: bool = true;
    loaded: SceneLoad? = null;
    aloneLabel: UnbuiltLabel = new UnbuiltLabel();
    private sourceShown: SceneSource = SceneSource.Auto;
    private labelShown: bool = true;
    private defaultLooked: bool = false;
    // Milestone 67b (see the header): the load in progress (null: none),
    // the runtime it loads into, the label it was asked with, and the
    // budget of the scene's project (ms; 0 the whole load); the progress
    // and the resources' mark last written (-1 and false: none yet); the
    // last load's log line, and how many were said (tests).
    task: LoadTask? = null;
    private pendingRuntime: SceneRuntime? = null;
    private pendingLabel: bool = true;
    private projectBudget: f64 = 0;
    // The project's debug/print_resources (resource_settings.as): the
    // `resources` text logged whenever it changes.
    private printResources: bool = false;
    private progressWritten: f64 = -1;
    private resourcesWritten: bool = false;
    private resourcesMarkWritten: i64 = 0;
    loadLog: string = "";
    loadLogs: i32 = 0;

    // Takes the context and the runtime (the module's shared one, loaded
    // from its bundle blob; null: sharedRuntime()); false when there is no
    // runtime.
    init(ctx: Context, runtime: SceneRuntime?, defaultScene: string): bool {
        this.ctx = ctx;
        this.defaultScene = defaultScene;
        this.runtime = runtime != null ? runtime : sharedRuntime();
        return this.runtime != null;
    }

    // Milestone 41: the loading mode (see the header) on `ctx`, each scene's
    // runtime made by `factory`.
    initLoading(ctx: Context, factory: SceneRuntimeFactory): bool {
        this.ctx = ctx;
        this.loading = true;
        this.factory = factory;
        this.runtime = null;
        return true;
    }

    // The loading mode without a context (tests: no GPU, `files` read, the
    // view model `model`).
    initLoadingWith(files: FileSource, factory: SceneRuntimeFactory, model: Scene3DModel?): void {
        this.ctx = null;
        this.loading = true;
        this.factory = factory;
        this.files = files;
        this.runtime = null;
        this.model = model;
    }

    // init without a context (tests: no GPU, the view model `model`).
    initWith(runtime: SceneRuntime, defaultScene: string, model: Scene3DModel?): void {
        this.ctx = null;
        this.runtime = runtime;
        this.defaultScene = defaultScene;
        this.model = model;
    }

    // Reads the view model, advances the instance; whether the next draw
    // shows something new.
    advance(seconds: f64): bool {
        if (this.loading) return this.advanceLoading(seconds);
        const rt = this.runtime;
        if (rt == null) return false;
        this.frames++;
        const m = this.takeModel();
        const want = m != null ? m.scene() : "";
        const path = want.length > 0 ? want : this.defaultScene;
        if (path != this.shown || (this.instance == null && !this.failed)) this.switchTo(rt, path);
        return this.advanceShown(m, rt, seconds);
    }

    // Milestone 41: `advance` in the loading mode: the source and label
    // asked for, the scene (re)loaded when it, or its source, changed.
    private advanceLoading(seconds: f64): bool {
        this.frames++;
        const m = this.takeModel();
        const want = m != null ? m.scene() : "";
        if (want.length == 0 && !this.defaultLooked) {
            this.defaultLooked = true;
            if (this.defaultScene.length == 0) this.defaultScene = onlyMainScene();
        }
        const path = want.length > 0 ? want : this.defaultScene;
        this.source = m != null ? sceneSourceNamed(m.source()) : SceneSource.Auto;
        const label = m != null ? m.unbuiltLabel(true) : true;
        this.unbuiltLabel = label;
        let asked = false;
        if (path != this.shown || this.source != this.sourceShown || (this.instance == null && !this.failed && this.task == null)) {
            this.load(path);
            asked = true;
        } else if (label != this.labelShown) {
            this.relabel();
            asked = true;
        }
        // (milestone 67b: the load's steps for this advance, then the
        // scene before it while it is not ready)
        if (this.task != null) this.stepLoad(m);
        this.writeProgress(m);
        if (this.task != null) {
            const prev = this.instance;
            if (prev != null) this.runInstance(m, prev, seconds);
            this.writeResources(m);
            return true;
        }
        const rt = this.runtime;
        if (rt == null) {
            this.writeLoadFailure(m);
            this.writeResources(m);
            return asked;
        }
        const drawn = this.advanceShown(m, rt, seconds) || asked;
        this.writeResources(m);
        return drawn;
    }

    // Loads `path` into a new runtime from the source asked for: a load
    // task (milestone 67b) that stepLoad steps, the scene shown until then
    // kept; a load already in progress is given up (LoadTask.cancel: what
    // it decoded and nothing else holds is freed).
    private load(path: string): void {
        const was = this.task;
        if (was != null) was.cancel();
        this.task = null;
        this.pendingRuntime = null;
        this.shown = path;
        this.sourceShown = this.source;
        const make = this.factory;
        const rt = make != null ? make() : new SceneRuntime();
        if (this.artboardSources.length > 0) {
            rt.artboardSources = this.artboardSources;
            rt.artboardViewModel = this.artboardViewModel;
        }
        this.pendingRuntime = rt;
        this.pendingLabel = this.unbuiltLabel;
        const o = new SceneOptions();
        o.source = this.source;
        o.unbuiltLabel = this.unbuiltLabel;
        if (path.length == 0) {
            const got = new SceneLoad();
            got.errors.push("Scene3D: no scene to show (the view model's scene is empty and no single Hedra project with a "
                + "main scene is registered)");
            rt.fail(got.errors[0]);
            this.finishLoad(got, null);
            return;
        }
        const ctx = this.ctx;
        const given = this.files;
        let files: FileSource;
        if (given != null) files = given;
        else if (ctx != null) files = new BlobFiles(ctx);
        else files = new NoFiles();
        // (the project's budget, its `.web` one on the web runtime: read
        // once a load; the view model's loadBudget each advance)
        const project = projectOfScene(path, o.project);
        const settings = project != null ? project.resourceSettings(rt.webTag >= 0 ? rt.webTag == 1 : webTarget(ctx)) : null;
        this.projectBudget = settings != null ? settings.frameBudgetMsec : 0;
        this.printResources = settings != null && settings.printResources;
        this.task = new LoadTask(rt, files, path, o, ctx);
    }

    // Milestone 67b: the load's steps that fit this advance's budget (the
    // view model's loadBudget when above 0, the whole load when below,
    // else the project's), and the load finished once it is done.
    private stepLoad(m: Scene3DModel?): void {
        const t = this.task;
        if (t == null) return;
        const asked = m != null ? m.loadBudget(0) : 0;
        const budget = asked > 0 ? asked : (asked < 0 ? 0 : this.projectBudget);
        if (!t.step(budget)) return;
        const got = t.result;
        if (got != null) this.finishLoad(got, t);
    }

    // Milestone 67b: the load done: the scene shown before disposed (what
    // the new one shares with it stays loaded), the new instance shown
    // from now on (or the label alone, when there is none), the log's line
    // said.
    private finishLoad(got: SceneLoad, t: LoadTask?): void {
        const old = this.instance;
        if (old != null) old.dispose();
        this.instance = null;
        this.task = null;
        const rt = this.pendingRuntime;
        this.pendingRuntime = null;
        if (rt != null) this.runtime = rt;
        this.labelShown = this.pendingLabel;
        this.cameraApplied = "";
        this.animationApplied = "";
        this.stateMachineApplied = "";
        this.modeRefused = "";
        this.dataBound = false;
        this.dataNone = false;
        this.failureSaid = false;
        this.eventsMark = 0;
        this.pendingNames.length = 0;
        this.aloneLabel.setText("");
        this.loaded = got;
        const inst = got.instance;
        this.failed = inst == null;
        if (t != null && inst != null) {
            this.loadLog = t.logLine();
            this.loadLogs++;
            const ctx = this.ctx;
            if (ctx != null) ctx.log(this.loadLog);
        }
        if (inst == null) {
            if (got.label.length > 0) this.aloneLabel.setText(got.label);
            return;
        }
        this.made++;
        for (let i = 0; i < this.provided.length; i++) inst.provideArtboard(i, this.provided[i]);
        this.instance = inst;
    }

    // Milestone 67b: `progress` written when it changed (1 with no load
    // in progress), when the view model has it.
    private writeProgress(m: Scene3DModel?): void {
        if (m == null || !m.hasProgress()) return;
        const t = this.task;
        const p = t != null ? t.progress() : 1;
        if (p == this.progressWritten) return;
        this.progressWritten = p;
        m.writeProgress(p);
    }

    // Milestone 67b: `resources` written when its mark changed (once at
    // first), when the view model has it; logged then too when the
    // project's debug/print_resources asks ("hedra: resources {...} at
    // frame N"). Nothing changed, nothing is made.
    private writeResources(m: Scene3DModel?): void {
        const bound = m != null && m.hasResources();
        const summary = m != null && m.hasResourceSummary();
        if (!bound && !summary && !this.printResources) return;
        const mark = resourcesMark();
        if (this.resourcesWritten && mark == this.resourcesMarkWritten) return;
        this.resourcesWritten = true;
        this.resourcesMarkWritten = mark;
        if (summary) m!.writeResourceSummary(resourcesSummary());
        if (!bound && !this.printResources) return;
        const text = resourcesText();
        if (bound) m!.writeResources(text);
        const ctx = this.ctx;
        if (this.printResources && ctx != null) ctx.log("hedra: resources " + text + " at frame " + this.frames.toString());
    }

    // The label turned on or off (unbuiltLabel) over the scene shown.
    private relabel(): void {
        this.labelShown = this.unbuiltLabel;
        const got = this.loaded;
        if (got == null) return;
        const text = this.unbuiltLabel && got.reason.length > 0 ? labelText(got.reason, got.scenePath) : "";
        const inst = this.instance;
        if (inst != null) {
            // (the next draw presents the last picture with or without it:
            // advance asks for that draw)
            inst.setLabel(text);
        } else {
            this.aloneLabel.setText(text);
        }
    }

    // The status of a scene that did not load (written once per failure).
    private writeLoadFailure(m: Scene3DModel?): void {
        if (this.failureSaid || m == null || !m.hasStatus()) return;
        this.failureSaid = true;
        const got = this.loaded;
        const errs = new Array<string>();
        let extra = "";
        if (got != null) {
            for (let i = 0; i < got.errors.length; i++) errs.push(jsonQuote(got.errors[i]));
            extra = ",\"source\":" + jsonQuote(sceneSourceName(got.source))
                + (got.reason.length > 0 ? ",\"unbuilt\":" + jsonQuote(got.reason) : "");
        }
        m.writeStatus("{\"frames\":" + this.frames.toString() + ",\"time\":0,\"scene\":" + jsonQuote(this.shown) + extra
            + ",\"nodes\":0,\"scripts\":0,\"ready\":0,\"process\":0,\"drawn\":0,\"gpu\":false,\"errors\":["
            + errs.join(",") + "]}");
    }

    // The rest of `advance`, over the instance shown by `rt`.
    private advanceShown(m: Scene3DModel?, rt: SceneRuntime, seconds: f64): bool {
        const inst = this.instance;
        if (inst == null) {
            if (this.loading) this.writeLoadFailure(m);
            else this.writeFailure(m, rt);
            // (milestone 49: no scene fires anything)
            this.writeEventNames(m);
            return false;
        }
        if (m != null) this.applyModel(m, inst);
        return this.runInstance(m, inst, seconds);
    }

    // The view model applied to the instance shown (advanceShown; not to
    // a scene shown while another loads, milestone 67b).
    private applyModel(m: Scene3DModel, inst: SceneInstance): void {
        const cam = m.camera();
        if (cam != this.cameraApplied) {
            this.cameraApplied = cam;
            if (!inst.setCamera(cam)) inst.fail("camera \"" + cam + "\": no Camera3D at that path in " + this.shown);
        }
        inst.playing = m.playing(true);
        const speed = m.speed(1);
        inst.speed = isFinite(speed) ? speed : 1;
        inst.setYaw(m.yaw(0));
        inst.setLodThreshold(m.lodThreshold(<f64>RUNTIME_LOD_THRESHOLD));
        // (milestone 67: the render scale over the project's)
        inst.setRenderScale(m.renderScale(0), this.scalingModeOf(inst, m.scalingMode()), m.maxDensity(0), m.maxPixels(0));
        // (milestone 45: the same string while unchanged, so this
        // compares without allocating; "" on a new instance plays
        // nothing, and needs no call)
        // (milestone 46: likewise; "" on a new instance runs its
        // default, which it runs already)
        const machine = m.stateMachine();
        if (machine != this.stateMachineApplied) {
            this.stateMachineApplied = machine;
            inst.playStateMachine(machine);
        }
        const anim = m.animation();
        if (anim != this.animationApplied) {
            this.animationApplied = anim;
            inst.playAnimation(anim);
        }
        if (!this.dataBound) {
            const d = m.data();
            if (d != null) {
                this.dataBound = true;
                inst.bind(d);
            } else if (!this.dataNone) {
                // (milestone 49: the view model has no `data`, and
                // never will: said once, so that an artboard texture
                // that would share the scene's instance plays unbound
                // rather than wait for it)
                this.dataNone = true;
                inst.bind(null);
            }
        }
    }

    // The instance advanced (or left still off-screen), its status and
    // events written.
    private runInstance(m: Scene3DModel?, inst: SceneInstance, seconds: f64): bool {
        // (milestone 42: the layout's size, which the bindings' screen
        // outputs are measured in, known before any draw)
        if (this.sized) inst.setViewSize(this.width, this.height, this.scale);
        inst.dropSignals();
        // (milestone 49: the events fired since the last advance's, before
        // they are dropped)
        const events = m != null && m.hasEvents();
        this.eventsWanted = events;
        if (events) this.readEvents(inst);
        inst.dropEvents();
        if (this.asked && this.missed < SCENE3D_UNDRAWN_FRAMES) this.missed++;
        let drawn: bool;
        if (this.offScreen()) {
            this.skipped++;
            drawn = inst.pending();
        } else {
            if (this.hidden()) this.keptRunning++;
            drawn = inst.advance(seconds);
        }
        this.asked = drawn;
        if (m != null && m.hasStatus() && inst.statusChanged()) m.writeStatus(inst.status());
        if (events) {
            this.readEvents(inst);
            this.writeEventNames(m);
        } else {
            this.eventsMark = inst.eventsFired;
        }
        return drawn;
    }

    // Milestone 67: the scaling mode named `mode` (SCALING_3D_*), or -1 (the
    // project's) for "" and for a name that is none, which the status's
    // errors say once (while it stays the same). Allocates nothing for a
    // mode seen before.
    private scalingModeOf(inst: SceneInstance, mode: string): i32 {
        if (mode.length == 0) return -1;
        const named = scalingModeNamed(mode);
        if (named < 0 && mode != this.modeRefused) {
            this.modeRefused = mode;
            inst.fail("scalingMode \"" + mode + "\": not bilinear or fsr (the project's mode is drawn)");
        }
        return named;
    }

    // Milestone 49: the names of the events `inst` fired since the queue was
    // last read, onto pendingNames (the queue's newest entries: it may have
    // dropped its oldest when full).
    private readEvents(inst: SceneInstance): void {
        const fired = inst.eventsFired;
        const fresh = fired - this.eventsMark;
        this.eventsMark = fired;
        if (fresh <= 0) return;
        const q = inst.queuedEvents;
        const n = fresh < <i64>q ? <i32>fresh : q;
        for (let i = q - n; i < q; i++) this.pendingNames.push(inst.queuedEvent(i).name);
    }

    // Milestone 49: writes the names read (pendingNames) to `events` when
    // they are not the ones written last (see the header), and empties
    // them.
    private writeEventNames(m: Scene3DModel?): void {
        const now = this.pendingNames;
        const last = this.eventNames;
        if (sameNames(now, last)) {
            now.length = 0;
            return;
        }
        last.length = 0;
        for (let i = 0; i < now.length; i++) last.push(unchecked(now[i]));
        now.length = 0;
        if (m == null || !m.hasEvents()) return;
        let text = "";
        if (last.length == 1) text = unchecked(last[0]);
        else if (last.length > 1) text = this.joined(last);
        m.writeEvents(text);
    }

    // Milestone 49: `names` joined by SCENE3D_EVENTS_SEPARATOR, from the
    // lists kept when it is one of them; else joined and kept, in place of
    // the oldest once SCENE3D_JOINED_KEPT are.
    private joined(names: Array<string>): string {
        const lists = this.joinedNames;
        for (let i = 0; i < lists.length; i++) if (sameNames(names, unchecked(lists[i]))) return unchecked(this.joinedTexts[i]);
        const text = names.join(SCENE3D_EVENTS_SEPARATOR);
        let at = lists.length;
        if (at < SCENE3D_JOINED_KEPT) {
            lists.push(new Array<string>());
            this.joinedTexts.push("");
        } else {
            at = this.joinedNext;
            this.joinedNext = (at + 1) % SCENE3D_JOINED_KEPT;
        }
        const kept = unchecked(lists[at]);
        kept.length = 0;
        for (let i = 0; i < names.length; i++) kept.push(unchecked(names[i]));
        this.joinedTexts[at] = text;
        return text;
    }

    // Whether the instance is left still this advance (see the header):
    // off-screen (hidden), its scene does not write its data, and it fires
    // no events a view model with `events` would list.
    offScreen(): bool {
        if (!this.hidden()) return false;
        const inst = this.instance;
        if (inst == null) return true;
        // (milestone 36: nor one whose sounds play, which its clock ends
        // and loops: SceneInstance.keepsRunning)
        if (inst.writesData() || inst.keepsRunning) return false;
        return !(this.eventsWanted && inst.firesEvents());
    }

    // Milestone 49: whether the view is off-screen (see the header),
    // whatever its scene: its layout has no area, or the draws it asked
    // for did not come.
    hidden(): bool {
        if (this.sized && (this.width <= 0 || this.height <= 0)) return true;
        return this.missed >= (this.drawnOnce ? SCENE3D_OFFSCREEN_FRAMES : SCENE3D_UNDRAWN_FRAMES);
    }

    // The host drew the view (draw calls it; a test without a GPU calls it
    // where the draw would be): it is on screen.
    noteDrawn(): void {
        this.drawnOnce = true;
        this.asked = false;
        this.missed = 0;
    }

    // The bound view model, looked up until the host has bound one.
    private takeModel(): Scene3DModel? {
        const have = this.model;
        if (have != null) return have;
        const ctx = this.ctx;
        if (ctx == null) return null;
        const vm = ctx.viewModel();
        if (vm == null) return null;
        const m = new RiveScene3DModel(vm);
        this.model = m;
        return m;
    }

    // Disposes the instance and makes one of `path` (once per path when it
    // fails: its error is in the status).
    private switchTo(rt: SceneRuntime, path: string): void {
        const old = this.instance;
        if (old != null) old.dispose();
        this.instance = null;
        this.shown = path;
        this.cameraApplied = "";
        this.animationApplied = "";
        this.stateMachineApplied = "";
        this.modeRefused = "";
        this.dataBound = false;
        this.dataNone = false;
        this.failureSaid = false;
        this.eventsMark = 0;
        this.pendingNames.length = 0;
        rt.artboardSources = this.artboardSources;
        rt.artboardViewModel = this.artboardViewModel;
        const inst = path.length > 0 ? rt.instantiate(path, this.ctx) : null;
        if (path.length == 0) rt.fail("Scene3D: no scene to show (the view model's scene is empty and there is no default)");
        this.failed = inst == null;
        if (inst == null) return;
        this.made++;
        for (let i = 0; i < this.provided.length; i++) inst.provideArtboard(i, this.provided[i]);
        this.instance = inst;
    }

    // The status of a scene that did not instance: the runtime's errors
    // (written once per failure).
    private writeFailure(m: Scene3DModel?, rt: SceneRuntime): void {
        if (!this.failed || this.failureSaid || m == null || !m.hasStatus()) return;
        this.failureSaid = true;
        const errs = new Array<string>();
        for (let i = 0; i < rt.errors.length; i++) errs.push(jsonQuote(rt.errors[i]));
        m.writeStatus("{\"frames\":" + this.frames.toString() + ",\"time\":0,\"scene\":" + jsonQuote(this.shown)
            + ",\"nodes\":0,\"scripts\":0,\"ready\":0,\"process\":0,\"drawn\":0,\"gpu\":false,\"errors\":["
            + errs.join(",") + "]}");
    }

    draw(renderer: HostRenderer): void {
        this.noteDrawn();
        const inst = this.instance;
        if (inst != null) {
            inst.draw(renderer, this.width, this.height, this.scale);
            // The draw's own counts (the occlusion's, the culling's) are
            // known only now: a host that draws once after its last advance
            // (rive --screenshot --advance=N) would otherwise read the
            // counts of the frame before. Written only when they changed.
            const m = this.model;
            if (m != null && m.hasStatus() && inst.statusChanged()) m.writeStatus(inst.status());
        }
        // (milestone 41: nothing could be drawn, but the label says why)
        else if (this.loading) this.aloneLabel.draw(renderer, this.width, this.height, this.scale);
    }

    // The layout's size in points and the host's pixels per point.
    resize(width: f64, height: f64, scale: f64): void {
        this.sized = true;
        this.width = width;
        this.height = height;
        this.scale = scale > 0 && isFinite(scale) ? scale : 1;
    }

    pointer(kind: InputKind, x: f32, y: f32, id: i32): bool {
        const inst = this.instance;
        // A host can send a pointer before its first draw (rive --pointer
        // does): plan the view now so picking has a camera to cast from.
        // ensurePlan counts no picture. Milestone 50: and between two draws
        // (a headless host draws none), the pick camera follows the camera
        // node where it is now, which ensurePlan does once the plan is out
        // of date: a pointer after the player walked picks what is in front
        // of it now, not where it stood at the last plan.
        if (inst != null && this.sized) inst.ensurePlan(this.width, this.height, this.scale);
        return inst != null && inst.pointer(kind, x, y, id);
    }

    key(kind: InputKind, key: i32, shift: bool, control: bool, alt: bool, meta: bool): bool {
        const inst = this.instance;
        return inst != null && inst.key(kind, key, shift, control, alt, meta);
    }

    // The artboard of input artboard_<i> (null until the host set it).
    // Called every advance by the layout; nothing is done when it is the
    // one already given.
    provideArtboard(i: i32, artboard: Artboard?): void {
        if (i < 0 || artboard == null) return;
        while (this.provided.length <= i) this.provided.push(null);
        if (this.provided[i] === artboard) return;
        this.provided[i] = artboard;
        const inst = this.instance;
        if (inst != null) inst.provideArtboard(i, artboard);
    }

    dispose(): void {
        const inst = this.instance;
        if (inst != null) inst.dispose();
        this.instance = null;
        // (milestone 67b: a load in progress given up, what it decoded let
        // go of)
        const t = this.task;
        if (t != null) t.cancel();
        this.task = null;
        this.pendingRuntime = null;
    }
}

// Milestone 41: the main scene of the only registered Hedra project, as
// a path in the Rive project ("" when there is not exactly one, or it has
// none).
export function onlyMainScene(): string {
    const all = registeredProjects();
    if (all.length != 1) return "";
    const p = all[0];
    if (p.mainScene.length == 0) return "";
    return p.name.length > 0 ? p.name + "/" + p.mainScene : p.mainScene;
}

// Milestone 67: the scaling mode `name` names (Godot's names, as the
// project's rendering/scaling_3d/mode takes them), or -1.
export function scalingModeNamed(name: string): i32 {
    for (let i = 0; i < SCALING_3D_MODE_NAMES.length; i++) if (unchecked(SCALING_3D_MODE_NAMES[i]) == name) return i;
    return -1;
}

// Milestone 49: whether `a` and `b` hold the same names in the same order
// (compared by content: allocates nothing).
function sameNames(a: Array<string>, b: Array<string>): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (unchecked(a[i]) != unchecked(b[i])) return false;
    return true;
}

// No files (a loading view with neither files nor a context).
class NoFiles extends FileSource {
    read(path: string): Uint8Array? {
        return null;
    }
}
