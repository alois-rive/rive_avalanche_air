// The NodeScript API: what a node's script (an .as file named by a node's
// `script` property, docs/formats/RSCN.md "Scripts") extends, and how a
// project that CLI's `build` writes knows its script classes.
//
// A script is one class that extends NodeScript:
//
//   import { NodeScript } from "hedra_engine/script";
//
//   export class Spin extends NodeScript {
//       speed: f32 = 0.5;                       // exported: the .rscn may set it
//       override process(delta: f32): void {
//           this.node.rotateY(this.speed * delta);
//       }
//   }
//
// The library's public `hedra_engine/script.as` re-exports this module, so
// scripts import "hedra_engine/script" and never a path of this repository. The CLI
// renders scenes without running scripts; the player of a built project
// (player/runtime.as) runs them:
//
// - before the first frame, one instance per node that has a script (a
//   script resource used by three nodes makes three instances), in tree
//   order; each gets `node` and `tree`, then its exported properties from
//   the node's properties in the .rscn (see ScriptSetter), then `ready()`
//   is called on every instance, children before their parent, as Godot
//   calls `_ready`;
// - every frame, `process(delta)` on every instance in tree order, `delta`
//   the seconds since the frame before;
// - on pointer and key input, `input(event)` on every instance in reverse
//   tree order (the last drawn first, as Godot's `_input`), until one sets
//   `event.handled`.
//
// A script's exported properties are its public instance fields whose
// declared type is one of f32, f64, i32, i64, u32, bool, string, Vec2, Vec3,
// Vec4 (build/script_scan.as in the program finds them); the CLI's `build`
// generates their setter. There is no reflection in AnimaScript, so the
// registry below carries, for each script file, a factory and that setter.
// The properties offered are the node's that its class does not have
// (classdb.as); one the setter refuses is a problem of the runtime.
//
// A script moves its node through SceneNode's Node3D API (tree/node.as):
// `position`, `rotation`, `scale` and `globalPosition` read, and
// `setPosition`, `setRotation`, `setScale`, `rotate`, `rotateX/Y/Z`,
// `rotateObjectLocal` and `translate` write, with Godot's semantics. The
// setters are methods because the pinned compiler refuses an assignment
// through an accessor of a vector (`node.position = v` is error E3001).
//
// Milestone 39 (the run time, runtime/scene_runtime.as) adds what
// a Godot script does with scenes and signals:
//
//   const crate = this.load("res://crate.rscn");   // or preload(), Godot's other name
//   const n = crate!.instantiate();                // a new subtree, or null
//   n!.name = "Crate2";
//   this.node.addChild(n!);                        // its scripts attach; the next frame draws it
//   this.emitSignal("hit", Value.float(2));         // to the scene's <connection>s and the host
//   override signal(method: string, event: SignalEvent): void { ... }   // a connection's target
//
// `load` resolves a res:// path, or one relative to the scene file that
// declared the script's node, through the tree's loader: in a Rive project
// the built scene's assets (decoded once, shared by every instance), in a test the
// files. A path that does not load is null, and the instance's errors say
// why. A signal reaches each <connection> whose `from` is the emitting node
// and whose `signal` is the one emitted: the `to` node's script gets
// `signal(method, event)` (AnimaScript has no reflection, so one
// virtual method takes every connection and switches on `method`), and
// the instance's host code reads every signal of the frame
// (SceneInstance.takeSignals).
//
// Milestone 27 adds Godot's scripting basics, which run in Play and in an
// export alike (docs/formats/RSCN.md, "Scripts", is the reference):
//
// - the lifecycle under Godot's names: `_enterTree()` each time the node
//   enters the live tree (parents before their children), `_ready()` once,
//   the first time (children before their parent), `_process(delta)`,
//   `_input(event)`, and `_exitTree()` when it leaves (children first, the
//   last child first, as Godot). The names before milestone 27, `ready`,
//   `process` and `input`, are what the runtime calls; NodeScript's own
//   call the new ones, so a script overrides either name;
// - groups (SceneNode.addToGroup, SceneTree.getNodesInGroup, callGroup,
//   whose target is the script's `call(method, arg)`), signals connected
//   from code (SceneNode.connect), removeChild and queueFree;
// - Timer nodes and SceneTreeTimers (script/timer.as), Tweens
//   (script/tween.as), print() and printErr() (below).
//
// Each frame the runtime runs the timers, then the tweens, then every
// script's _process, then frees what queueFree asked for.
//
// Milestone 67b (docs/engine/RESOURCES.md, "Lifetimes"): in a run time, what
// a script loads is held apart from its instance, as Godot's Ref<Resource>
// holds it: the scene `load` returned is held until the script says it is
// done with it (`PackedSceneRef.release()`: Godot's `scene = null`, which
// AnimaScript, without reference counts, cannot see), and each subtree
// `instantiate` made holds what it draws until it is freed (queueFree); when
// neither holds a resource and the instance does not use it, it is freed
// from the run time's cache, its GPU objects with it. Whatever is still
// held goes when the instance does. The tools hold nothing. A path loaded
// again before it is released is the same load (the same PackedSceneRef,
// as Godot's load() returns the cached resource), so a spawner that loads
// its scene every frame holds it once; its release() lets go of that one
// load, for every script that loaded the path, and an instantiate after it
// loads the scene again. A node taken out of an instanced subtree keeps
// what the subtree holds until it is freed too (../tree/node.as
// removeChild).

import { Value } from "./value";
import { SceneNode } from "./tree/node";
import { SceneLoadRef, SceneTree } from "./tree/tree";
import { PackedScene } from "./resource/types";
import { ResourceHolder } from "./resource/cache";
import { instantiate as instantiateScene } from "./tree/instance";
import { SignalEvent } from "./runtime/signals";
import { Tween } from "./script/tween";
import { World3D } from "./interaction/api";
import { ScriptScene } from "./script/scene_api";
import { panicAs } from "../base/util";

// What scripts may use without importing a repository path.
export { Vec2, Vec3, Vec4, Quat, Mat3, Mat4 } from "../base/vecmath";
export { SceneNode, TimerNode } from "./tree/node";
export { SceneTree } from "./tree/tree";
export { Value } from "./value";
export { CONNECT_ONE_SHOT, SignalEvent } from "./runtime/signals";
// Milestone 27: Godot's names for the timer and tween classes.
export { TimerNode as Timer } from "./tree/node";
export { SceneTreeTimer } from "./script/timer";
export { EaseType, PropertyTweener, TransitionType, Tween } from "./script/tween";
// Milestone 31: interaction (RSCN.md, "Interaction"): the nodes, and the
// space scripts query.
export { Area3D, CollisionObject3D, CollisionShape3D, RayCast3D, StaticBody3D } from "./tree/node";
// Milestone 32: paths (RSCN.md, "Paths"): the nodes and the curve.
export { Path3D, PathFollow3D } from "./tree/node";
export { Curve3D } from "./path/curve3d";
export { ROTATION_NONE, ROTATION_ORIENTED, ROTATION_XY, ROTATION_XYZ, ROTATION_Y } from "./path/follow";
export {
    ALL_LAYERS, PhysicsDirectSpaceState3D, PhysicsPointQueryParameters3D, PhysicsPointResult, PhysicsRayQueryParameters3D,
    PhysicsRayResult, World3D,
} from "./interaction/api";
// Milestone 45: the scene's timelines (NodeScript.scene).
// (milestone 46: its state machines, NodeScript.scene.stateMachine)
export { ScriptAnimation, ScriptInput, ScriptScene, ScriptStateMachine } from "./script/scene_api";
// Milestone 48: skeletons (their bones' poses, Godot's Skeleton3D API),
// the nodes that follow a bone, and a mesh's blend shapes
// (MeshInstance3D's getBlendShapeValue, setBlendShapeValue, ...).
export { Bone3D, BoneAttachment3D, MeshInstance3D, Skeleton3D } from "./tree/node";
// Milestone 34: cameras and viewports (RSCN.md, "Viewports"): a script
// that moves a SubViewport's camera (a mirror's, a security camera's), or
// sets its updateMode (Godot's UpdateMode numbers; each write of
// UPDATE_ONCE takes one more picture).
export { Camera3D, SubViewport } from "./tree/node";
export {
    UPDATE_ALWAYS, UPDATE_DISABLED, UPDATE_ONCE, UPDATE_WHEN_PARENT_VISIBLE, UPDATE_WHEN_VISIBLE,
} from "../render/viewport";
// Milestone 35: particles (RSCN.md, "Particles"): a script that restarts an
// emitter (CPUParticles3D.restart(), Godot's) or reads its fields; its
// `finished` reaches connections and scripts as any signal.
export { CPUParticles3D } from "./tree/node";
// Godot's CPUParticles3D.EmissionShape and DrawOrder numbers, for a script
// that sets emissionShape or drawOrder (as each write of a field, read by
// the next step).
export {
    DRAW_ORDER_INDEX, DRAW_ORDER_LIFETIME, DRAW_ORDER_REVERSE_LIFETIME, DRAW_ORDER_VIEW_DEPTH, EMISSION_BOX,
    EMISSION_DIRECTED_POINTS, EMISSION_POINT, EMISSION_POINTS, EMISSION_RING, EMISSION_SPHERE, EMISSION_SPHERE_SURFACE,
} from "./particles/state";
// Milestone 36: spatial audio (RSCN.md, "Audio"): a script that plays,
// stops or seeks a player (Godot's play(from), stop(), seek(),
// get_playback_position() as getPlaybackPosition(), has_stream_playback()
// as hasStreamPlayback()), or makes a listener current (makeCurrent(),
// clearCurrent(), isCurrent()); a player's `finished` reaches connections
// and scripts as any signal.
export { AudioListener3D, AudioStreamPlayer3D } from "./tree/node";
export {
    ATTENUATION_DISABLED, ATTENUATION_INVERSE, ATTENUATION_INVERSE_SQUARE, ATTENUATION_LOGARITHMIC,
} from "./audio/attenuation";
// Godot's AudioStreamWAV.LoopMode numbers (AudioStream.loopMode).
export {
    AUDIO_LOOP_BACKWARD, AUDIO_LOOP_DISABLED, AUDIO_LOOP_FORWARD, AUDIO_LOOP_PINGPONG, AudioStream,
} from "./resource/audio_stream";
// Milestone 63: navigation (RSCN.md, "Navigation"; docs/engine/
// NAVIGATION.md): the nodes (an agent's Godot methods:
// getNextPathPosition(), isNavigationFinished(), distanceToTarget(), ...),
// the mesh, and Godot's NavigationServer3D map queries with their path
// query objects, the map reached as getWorld3D().navigationMap.
export { NavigationAgent3D, NavigationLink3D, NavigationObstacle3D, NavigationRegion3D } from "./tree/node";
export { NavigationMesh } from "./resource/navigation_mesh";
export {
    ALL_NAVIGATION_LAYERS, NavigationMap, NavigationPathQueryParameters3D, NavigationPathQueryResult3D, NavigationServer3D,
    PATHFINDING_ALGORITHM_ASTAR, PATH_METADATA_INCLUDE_ALL, PATH_METADATA_INCLUDE_NONE, PATH_METADATA_INCLUDE_OWNERS,
    PATH_METADATA_INCLUDE_RIDS, PATH_METADATA_INCLUDE_TYPES, PATH_POSTPROCESSING_CORRIDORFUNNEL, PATH_POSTPROCESSING_EDGECENTERED,
    PATH_POSTPROCESSING_NONE, PATH_SEGMENT_TYPE_LINK, PATH_SEGMENT_TYPE_REGION,
} from "./navigation/api";

// The kind of an input event.
export enum InputKind {
    PointerDown,
    PointerMove,
    PointerUp,
    PointerExit,
    KeyDown,
    KeyRepeat,
    KeyUp,
}

// One pointer or key event, as the player's Layout received it.
export class InputEvent {
    kind: InputKind;
    // Pointer events: the position in the picture, in pixels from its top
    // left corner, and the pointer's id (0 for a mouse).
    x: f32 = 0;
    y: f32 = 0;
    pointer: i32 = 0;
    // Key events: the key code rive reports (KeyboardEvent.key) and the
    // modifiers held.
    key: i32 = 0;
    shift: bool = false;
    control: bool = false;
    alt: bool = false;
    meta: bool = false;
    // Set by a script to stop the event reaching the scripts after it.
    handled: bool = false;

    constructor(kind: InputKind) {
        this.kind = kind;
    }

    static pointerEvent(kind: InputKind, x: f32, y: f32, pointer: i32): InputEvent {
        const e = new InputEvent(kind);
        e.x = x;
        e.y = y;
        e.pointer = pointer;
        return e;
    }

    static keyEvent(kind: InputKind, key: i32, shift: bool, control: bool, alt: bool, meta: bool): InputEvent {
        const e = new InputEvent(kind);
        e.key = key;
        e.shift = shift;
        e.control = control;
        e.alt = alt;
        e.meta = meta;
        return e;
    }

    isPointer(): bool {
        return this.kind <= InputKind.PointerExit;
    }

    isKey(): bool {
        return this.kind >= InputKind.KeyDown;
    }
}

// Milestone 39: a scene a script loaded (NodeScript.load), which it
// instances as often as it likes, as Godot's PackedScene.
export class PackedSceneRef extends SceneLoadRef {
    // How the scene is named: its res:// path (the loader's displayPath).
    path: string;
    // Its absolute path in the run time's file system.
    abs: string;
    scene: PackedScene;
    // The tree whose loader loaded it: what its instances share resources
    // with, and whose connections gain theirs.
    tree: SceneTree;
    // Milestone 67b (see the header): what the load holds in the run time's
    // cache (null in the tools), until `release`.
    holder: ResourceHolder? = null;
    released: bool = false;

    constructor(path: string, abs: string, scene: PackedScene, tree: SceneTree, holder: ResourceHolder? = null) {
        super();
        this.path = path;
        this.abs = abs;
        this.scene = scene;
        this.tree = tree;
        this.holder = holder;
    }

    // Milestone 67b: the script is done with the scene (Godot's `scene =
    // null`): what only this load held is freed once no subtree made from
    // it holds it either. An instantiate after it loads the scene again.
    release(): void {
        if (this.released) return;
        this.released = true;
        const h = this.holder;
        this.holder = null;
        if (h != null) h.close();
    }

    // A new subtree of the scene (its root named as the scene's root, not
    // yet in any tree: add it with SceneNode.addChild), or null, with the
    // reason in the instance's errors, when it does not instance. Its
    // <connection>s join the tree's.
    instantiate(): SceneNode? {
        const t = this.tree;
        const l = t.loader;
        if (this.released) {
            // (released: loaded again, held again, as a new load would be)
            const scope = l.beginScope();
            const again = l.loadScene(this.abs);
            if (scope != null) l.endScope();
            if (!again.ok) {
                if (scope != null) scope.close();
                const host = t.host;
                if (host != null) host.problem("instantiate " + this.path + ": " + again.err);
                return null;
            }
            this.scene = again.value;
            this.holder = scope;
            this.released = false;
        }
        // (milestone 67b: the subtree holds what it draws, and the scene
        // itself, until it is freed: see the header)
        const scope = l.beginScope();
        const r = instantiateScene(this.scene, l, t.share);
        if (scope != null) l.endScope();
        if (!r.ok) {
            if (scope != null) scope.close();
            const host = t.host;
            if (host != null) host.problem("instantiate " + this.path + ": " + r.err);
            return null;
        }
        const sub = r.value;
        if (scope != null) {
            const e = scope.cache.entryOf(this.scene);
            if (e != null && !e.freed) scope.hold(e);
            sub.root.heldResources = scope;
        }
        for (let i = 0; i < sub.connections.length; i++) t.connections.push(sub.connections[i]);
        // (freed before it is added, its connections go all the same)
        sub.root.lastTree = t;
        return sub.root;
    }
}

// The base of every node script. `node` and `tree` are set by the runtime
// before anything else is called; reading them earlier (in a constructor
// or a field initialiser) traps.
export abstract class NodeScript {
    attachedNode: SceneNode? = null;
    attachedTree: SceneTree? = null;
    // Milestone 39: set when NodeScript's own process() or input() ran,
    // which means the class does not override it: the run time
    // then stops calling it, so that a scene whose scripts only act in
    // ready() is idle (draws nothing new and allocates nothing per frame).
    // A script that overrides one and calls super's sets it too, and loses
    // the calls: call neither.
    processIdle: bool = false;
    inputIdle: bool = false;
    // Milestone 27: Godot's set_process(false): the runtime calls _process
    // no more until setProcess(true), so a script that has finished moving
    // its node (the game sample's crate, once landed) lets the scene go
    // idle and stop redrawing.
    processOff: bool = false;

    // Godot's set_process: whether _process is called each frame (it is
    // until a script turns it off).
    setProcess(enable: bool): void {
        this.processOff = !enable;
        // (on again: a class with its own _process is called; one without
        // marks itself idle again on the next call)
        if (enable) this.processIdle = false;
    }

    // Godot's is_processing.
    isProcessing(): bool {
        return !this.processOff;
    }

    // The node the script is attached to (set once the script is attached,
    // after its constructor: reading it there stops the program, saying so).
    get node(): SceneNode {
        const n = this.attachedNode;
        if (n == null) return panicAs<SceneNode>("a script's node is set once it is attached: read it from _ready on");
        return n;
    }

    // The scene tree the node is in (likewise).
    get tree(): SceneTree {
        const t = this.attachedTree;
        if (t == null) return panicAs<SceneTree>("a script's tree is set once it is attached: read it from _ready on");
        return t;
    }

    // Milestone 45 (docs/plans/RIVE_MODEL.md section 5): the scene that
    // declared the script's node (its .rscn: the root scene or an instanced
    // one), whose animations the script plays (script/scene_api.as); null
    // where no run time plays the tree (the tools).
    get scene(): ScriptScene? {
        const t = this.attachedTree;
        const n = this.attachedNode;
        if (t == null || n == null) return null;
        const h = t.host;
        return h != null ? h.sceneOf(n) : null;
    }

    // Milestone 27: whether _ready ran (it runs once, however often the
    // node enters the tree).
    isReady: bool = false;

    // Each time the node enters the live tree (at the start, or added under
    // a node in it), parents before their children; the exported
    // properties are set by then.
    _enterTree(): void {}

    // Once, the first time the node enters the tree, after its children's.
    _ready(): void {}

    // Every frame, in tree order; `delta` is the seconds since the frame
    // before (0 for the first). NodeScript's own marks the script idle (see
    // processIdle).
    _process(delta: f32): void {
        this.processIdle = true;
    }

    // For each pointer and key event, last in tree order first; set
    // `event.handled` to stop it.
    _input(event: InputEvent): void {
        this.inputIdle = true;
    }

    // When the node leaves the tree (removeChild, queueFree), after its
    // children's.
    _exitTree(): void {}

    // The names before milestone 27, which the runtime calls: each calls
    // the new one, so a script overrides whichever it likes.
    ready(): void {
        this._ready();
    }

    process(delta: f32): void {
        this._process(delta);
    }

    input(event: InputEvent): void {
        this._input(event);
    }

    // What SceneTree.callGroup, a tween's callback and its finish call:
    // `method` with `arg` (Nil when none). There is no reflection in
    // AnimaScript, so a script that is called this way overrides call()
    // and switches on `method`; NodeScript's own says the method is not
    // there.
    call(method: string, arg: Value): Value {
        scriptProblem(this, "no method " + method);
        return Value.nil();
    }

    // A tween bound to this node: it dies when the node leaves the tree.
    createTween(): Tween {
        return this.tree.createTween().bindNode(this.node);
    }

    // Milestone 31: Godot's get_world_3d(): the world of the scene's tree,
    // whose directSpaceState answers intersectRay and intersectPoint.
    getWorld3D(): World3D {
        return this.tree.world;
    }

    // The node a path names from this script's node (SceneNode.getNode:
    // relative, absolute or %Unique), or null.
    getNode(path: string): SceneNode? {
        return this.node.getNode(path);
    }

    // Milestone 39: the scene at `path` (res://, or relative to the scene
    // file that declared this script's node), loaded through the tree's
    // loader; null when it does not load (the instance's errors say why).
    load(path: string): PackedSceneRef? {
        const tree = this.tree;
        const l = tree.loader;
        const r = l.resolve(path, sceneFileOf(this.node, tree));
        if (!r.ok) {
            scriptProblem(this, "load(\"" + path + "\"): " + r.err);
            return null;
        }
        // (milestone 67b: a path loaded and not released is that load
        // again, as Godot's load() returns the cached resource: a spawner
        // loading its scene every frame takes no new holder, and nothing
        // grows)
        let loads = tree.scriptLoads;
        if (loads != null && loads.has(r.value)) {
            const had = loads.get(r.value) as PackedSceneRef;
            if (!had.released) return had;
            loads.delete(r.value);
        }
        // (milestone 67b: held by the load until it is released: see the
        // header)
        const scope = l.beginScope();
        const ps = l.loadScene(r.value);
        if (scope != null) l.endScope();
        if (!ps.ok) {
            if (scope != null) scope.close();
            scriptProblem(this, "load(\"" + path + "\"): " + ps.err);
            return null;
        }
        const ref = new PackedSceneRef(l.displayPath(r.value), r.value, ps.value, tree, scope);
        if (loads == null) {
            loads = new Map<string, SceneLoadRef>();
            tree.scriptLoads = loads;
        }
        loads.set(r.value, ref);
        return ref;
    }

    // `load`, by Godot's other name (the scene is loaded when called: there
    // is no compile-time preload).
    preload(path: string): PackedSceneRef? {
        return this.load(path);
    }

    // Emits `signal` from this script's node (see the header); nothing
    // happens outside the run time.
    emitSignal(signal: string, value: Value = Value.nil()): void {
        const host = this.tree.host;
        if (host != null) host.emit(this.node, signal, value);
    }

    // A <connection> whose `to` is this script's node fired: `method` is
    // its method, `event` says who emitted what.
    signal(method: string, event: SignalEvent): void {}
}

// Says `message` about `s`'s node to the tree's host (a module function,
// not a method, so that no script's own member can clash with it).
function scriptProblem(s: NodeScript, message: string): void {
    const host = s.tree.host;
    if (host != null) host.problem(s.node.path() + ": " + message);
}

// The absolute path of the scene file that declared `n` (its display path
// back through the loader: a res:// path, or a path outside the project as
// it is), "" when it is not known (relative paths then start at the
// project root).
function sceneFileOf(n: SceneNode, tree: SceneTree): string {
    const f = n.sceneFile;
    if (f.length == 0) return "";
    if (f.startsWith("res://")) {
        const r = tree.loader.resolve(f, "");
        return r.ok ? r.value : "";
    }
    return f.startsWith("/") ? f : "";
}

// Milestone 27: Godot's print() and printerr(), for scripts. A line goes
// to the installed PrintSink: the game program's (host/src/play: the
// game's stdout and stderr, which a Play started from the editor shows in
// its Output panel), the run time's (SceneInstance's printed
// lines), or nowhere when none is installed (the tools run no script).
//
// Milestone 28: each call may say where it is, `file` (the script's res://
// path) and `line` (from 1). A script never passes them: Build and Play
// rewrite each call of print, printErr,
// pushError and pushWarning in a script to a function of its own that
// passes them (compiler/src/play/print_sites.as), so the editor's Output
// and Debugger show a script's line with its file and line, as Godot's
// do. "" and 0: not known. Godot's push_error() and push_warning() come
// with it: a problem, not a printed line (the Debugger's Errors tab; a
// Scene3D's status "errors").
export abstract class PrintSink {
    // One line a script printed; `error`: printerr's.
    abstract line(text: string, error: bool): void;

    // The same, with where the call is ("" and 0: not known). A sink that
    // shows places overrides it; by default the place is dropped.
    lineAt(text: string, error: bool, file: string, line: i32): void {
        this.line(text, error);
    }

    // A pushError (`warning` false) or a pushWarning, with where it is. By
    // default a printed error line, "ERROR: " or "WARNING: " before it, as
    // Godot's output shows them.
    problem(text: string, warning: bool, file: string, line: i32): void {
        this.lineAt((warning ? "WARNING: " : "ERROR: ") + text, true, file, line);
    }
}

let printSink: PrintSink? = null;

// Installs `s` (null: lines go nowhere).
export function setPrintSink(s: PrintSink?): void {
    printSink = s;
}

// The sink installed, or null.
export function currentPrintSink(): PrintSink? {
    return printSink;
}

// Prints `text` as one line (Godot's print).
export function print(text: string, file: string = "", line: i32 = 0): void {
    const s = printSink;
    if (s != null) s.lineAt(text, false, file, line);
}

// Prints `text` as one error line (Godot's printerr).
export function printErr(text: string, file: string = "", line: i32 = 0): void {
    const s = printSink;
    if (s != null) s.lineAt(text, true, file, line);
}

// Milestone 28: Godot's push_error(): reports a problem (the Debugger's
// Errors tab in Play; the instance's errors in a Rive project).
export function pushError(text: string, file: string = "", line: i32 = 0): void {
    const s = printSink;
    if (s != null) s.problem(text, false, file, line);
}

// Milestone 28: Godot's push_warning().
export function pushWarning(text: string, file: string = "", line: i32 = 0): void {
    const s = printSink;
    if (s != null) s.problem(text, true, file, line);
}

// Makes a new instance of one script class (generated:
// `function make_0(): NodeScript { return new Spin(); }`).
export type ScriptFactory = () => NodeScript;

// Sets the exported property `name` of a script from its .rscn value;
// returns false when the class exports no such property, or when the value
// cannot be converted to the property's type (generated per class by
// the CLI's `build`).
export type ScriptSetter = (script: NodeScript, name: string, value: Value) => bool;

// One script file's class, as a built project registers it.
export class ScriptClass {
    // The script's display path, `res://scripts/spin.as` (the loader's
    // displayPath of the Script resource): the key the runtime finds the
    // class of a node's script by.
    path: string;
    // The class name (`class <name> extends NodeScript`).
    name: string;
    make: ScriptFactory;
    set: ScriptSetter;

    constructor(path: string, name: string, make: ScriptFactory, set: ScriptSetter) {
        this.path = path;
        this.name = name;
        this.make = make;
        this.set = set;
    }
}

// The script classes a built project holds (its generated src/scripts.as
// adds them before the scene loads).
export class ScriptRegistry {
    classes: Array<ScriptClass> = [];

    // Registers the class of the script file `path` (a res:// display
    // path); a second registration of the same path replaces the first.
    add(path: string, name: string, make: ScriptFactory, set: ScriptSetter): void {
        const c = new ScriptClass(path, name, make, set);
        for (let i = 0; i < this.classes.length; i++) {
            if (this.classes[i].path == path) {
                this.classes[i] = c;
                return;
            }
        }
        this.classes.push(c);
    }

    // The class registered for `path`, or null.
    find(path: string): ScriptClass? {
        for (let i = 0; i < this.classes.length; i++) if (this.classes[i].path == path) return this.classes[i];
        return null;
    }
}
