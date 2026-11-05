// A loaded scene: the root node of its instanced tree, the loader that
// holds its resources, its signal connections and what loading it found
// without failing. instance.as builds one (loadSceneTree, instantiate); the
// renderer (milestone 4) draws one, and the CLI's `inspect` prints one
// (dump.as).

import { Diagnostics } from "../error";
import { ResourceLoader } from "../resource/loader";
import { Value } from "../value";
import { DocResources } from "../resource/build";
import { PackedScene } from "../resource/types";
import {
    Camera3D, Decal, Light3D, LightmapGI, NodeAddedListener, ReflectionProbe, SceneNode, SubViewport, WorldEnvironment,
    addedListenerOf, enterScript, leaveScript, treeStructureEpoch, unwatchAdded, watchAdded,
} from "./node";
import { SceneTreeTimer, TimerSet } from "../script/timer";
import { Tween, TweenSet } from "../script/tween";
import { CONNECT_ONE_SHOT, SignalEvent } from "../runtime/signals";
import { World3D } from "../interaction/api";
import { ScriptScene } from "../script/scene_api";
import { RscnDoc } from "../rscn/doc";
import { LinearAnimation } from "../anim/animation";
import { StateMachine } from "../sm/machine";
import { ImportedClipSet } from "../skeleton/clips";

// A `<connection>` of a scene file, with its ends found: `from`'s `signal`
// calls `to`'s `method`. Each instanced scene's connections are resolved
// relative to that scene's root.
export class Connection {
    signal: string;
    from: SceneNode;
    to: SceneNode;
    method: string;
    flags: i32 = 0;
    // Where the <connection> is.
    file: string = "";
    line: i32 = 0;
    col: i32 = 0;

    constructor(signal: string, from: SceneNode, to: SceneNode, method: string) {
        this.signal = signal;
        this.from = from;
        this.to = to;
        this.method = method;
    }
}

// Milestone 39: what a tree played by the run time
// (../runtime/scene_runtime.as) answers to for its scripts: a signal a
// script emitted (NodeScript.emitSignal), and a problem a script's call ran
// into (a load() that did not load). The tools' trees have none.
export abstract class SceneTreeHost {
    // `from`'s script emitted `signal` with `value`.
    emit(from: SceneNode, signal: string, value: Value): void {}

    // Milestone 31: the engine emitted `ev` from `from` (an Area3D's
    // body_entered, a collision object's input_event): `ev` is the
    // emitter's own, kept and filled again by its next emission (so that
    // emitting allocates nothing), its `from` already the path of `from`.
    // A `quiet` one (a signal emitted every step whatever happens, such as
    // velocity_computed) does not by itself ask for a new picture: only the
    // handlers it reached do.
    emitEvent(from: SceneNode, ev: SignalEvent, quiet: bool = false): void {}

    // One line of what went wrong, for the instance's errors.
    problem(message: string): void {}

    // Milestone 45: the scene `node` belongs to, for its script's
    // NodeScript.scene (the run time's animation feature answers; the
    // tools' trees have none).
    sceneOf(node: SceneNode): ScriptScene? {
        return null;
    }
}

// Milestone 39: the resources several trees share. The instancer resolves
// each scene's sub_resources once per tree; trees instanced with one share
// (the run time's instances, and the scenes its scripts instance
// at run time) resolve each PackedScene's once for all of them, so two
// instances of a scene draw the same mesh and material objects, built and
// uploaded once, as Godot's instances share a PackedScene's sub-resources.
//
// Milestone 45: each scene document's animations, compiled once for every
// tree of the share (../anim/scene_anims.as attachSceneAnimations; the run
// time's documents never change once loaded); milestone 46: and its state
// machines (../sm/scene_machines.as attachSceneMachines).
//
// Milestone 67b: what a script's load() handed out (../script.as
// PackedSceneRef extends it), kept by the tree by path so that loading a
// path again returns the same load, as Godot's load() returns the cached
// resource: one holder however often a spawner loads it.
export class SceneLoadRef {}

// Milestone 67b (docs/engine/RESOURCES.md, "Lifetimes"): a run time's
// share is the module's one (every Scene3D's runtime instances with it:
// ../runtime/runtime_resources.as), so it must let go of a scene the
// resource cache freed (`forget`), or it would keep every scene ever shown
// and what its documents name.
export class InstanceShare {
    resources: Map<PackedScene, DocResources> = new Map<PackedScene, DocResources>();
    animations: Map<RscnDoc, Array<LinearAnimation>> = new Map<RscnDoc, Array<LinearAnimation>>();
    machines: Map<RscnDoc, Array<StateMachine>> = new Map<RscnDoc, Array<StateMachine>>();
    // Milestone 48: each document's imported clips, made once (the same).
    clips: Map<RscnDoc, ImportedClipSet> = new Map<RscnDoc, ImportedClipSet>();

    // Milestone 67b: drops `p` and its document from every map (no tree
    // of `p` is left: the cache freed it); the resources its document's
    // were resolved to, or null when it was never instanced with this
    // share.
    forget(p: PackedScene): DocResources? {
        let res: DocResources? = null;
        if (this.resources.has(p)) {
            res = this.resources.get(p);
            this.resources.delete(p);
        }
        const doc = p.doc;
        if (doc != null) {
            if (this.animations.has(doc)) this.animations.delete(doc);
            if (this.machines.has(doc)) this.machines.delete(doc);
            if (this.clips.has(doc)) this.clips.delete(doc);
        }
        return res;
    }
}

// A group no node is in (shared, never changed).
const NO_NODES: Array<SceneNode> = [];

export class SceneTree {
    root: SceneNode;
    loader: ResourceLoader;
    // The absolute path of the root scene ("" for one built in code).
    scenePath: string = "";
    // In the order they were resolved: an instanced scene's before those of
    // the scene that instances it.
    connections: Array<Connection> = [];
    // The loader's (the same object): warnings found while loading every
    // file of the scene.
    diagnostics: Diagnostics;

    // Milestone 39: the run time's side of the tree (null for the tools'),
    // and the share its scenes were instanced with (scripts' load() and
    // instantiate() instance with it too; null: each tree its own).
    host: SceneTreeHost? = null;
    share: InstanceShare? = null;

    // Milestone 31: Godot's World3D, whose directSpaceState scripts query
    // (../interaction/api.as). It answers nothing until the run time's
    // interaction feature puts its world's space in.
    world: World3D = new World3D();

    // Milestone 27, made when a live tree first needs them (the tools'
    // trees never do): its timers and tweens (../script/), the nodes
    // queueFree asked to go at the end of the frame, and the group index
    // (each group's nodes in tree order, built again only after a node
    // gained or lost a child or a group: treeStructureEpoch).
    timerSet: TimerSet? = null;
    tweenSet: TweenSet? = null;
    freeQueue: Array<SceneNode> = [];
    // The connections the emissions under way call (takeConnections): a
    // stack, each emission's above those of the one whose handler made
    // it. Kept, so that emitting allocates nothing once it has grown.
    emitting: Array<Connection> = [];
    // Milestone 67b: the scenes its scripts loaded and have not released,
    // by absolute path (NodeScript.load); made on the first load.
    scriptLoads: Map<string, SceneLoadRef>? = null;
    private groupIndex: Map<string, Array<SceneNode>>? = null;
    private groupEpoch: i32 = -1;

    constructor(root: SceneNode, loader: ResourceLoader) {
        this.root = root;
        this.loader = loader;
        this.diagnostics = loader.diagnostics;
    }

    // Milestone 39: who hears of a node added under the root at run time
    // (node.as watchAdded; null: no one, as for every tool's tree). Set it
    // to null before the tree is dropped, or the watch keeps it alive.
    get onAdded(): NodeAddedListener? {
        return addedListenerOf(this.root);
    }

    set onAdded(l: NodeAddedListener?) {
        if (l == null) unwatchAdded(this.root);
        else watchAdded(this.root, l);
    }

    // Milestone 27: pushes onto `emitting` the connections an emission of
    // `from`'s `signal` calls, in connection order, removing each one-shot
    // one from `connections` as it is taken (Godot's CONNECT_ONE_SHOT).
    // The caller delivers to emitting[start..] (start: its length before),
    // then sets its length back to start. Walking `connections` itself
    // while scripts run skipped the connection after one a handler
    // disconnected (Godot's fire-once pattern), and called one a handler
    // connected in the same emission, which Godot does not.
    takeConnections(from: SceneNode, signal: string): void {
        const cs = this.connections;
        const into = this.emitting;
        let k = 0;
        for (let i = 0; i < cs.length; i++) {
            const c = unchecked(cs[i]);
            if (c.from === from && c.signal == signal) {
                into.push(c);
                if ((c.flags & CONNECT_ONE_SHOT) != 0) continue;
            }
            cs[k++] = c;
        }
        cs.length = k;
    }

    // Whether a connection takeConnections took is still to be called: a
    // handler before it in the same emission may have disconnected it or
    // freed its target (Godot skips those too). A one-shot one was taken
    // out of `connections` already, so it always is.
    stillConnected(c: Connection): bool {
        if (c.to.freed) return false;
        return (c.flags & CONNECT_ONE_SHOT) != 0 || this.connections.includes(c);
    }

    // The node a path names from the root (node.as, paths.as).
    getNode(path: string): SceneNode? {
        return this.root.getNode(path);
    }

    // Every node, pre-order, children in order.
    walk(): Array<SceneNode> {
        const out = new Array<SceneNode>();
        const stack = new Array<SceneNode>();
        stack.push(this.root);
        while (stack.length > 0) {
            const n = stack.pop();
            out.push(n);
            for (let i = n.children.length - 1; i >= 0; i--) stack.push(n.children[i]);
        }
        return out;
    }

    // Milestone 50: `walk` into `out`, with `stack` for the walk, both
    // emptied first: allocates nothing once they have grown to the tree.
    walkInto(out: Array<SceneNode>, stack: Array<SceneNode>): void {
        out.length = 0;
        stack.length = 0;
        stack.push(this.root);
        while (stack.length > 0) {
            const n = stack.pop();
            out.push(n);
            for (let i = n.children.length - 1; i >= 0; i--) stack.push(n.children[i]);
        }
    }

    count(): i32 {
        return this.walk().length;
    }

    // The nodes in a group, in tree order.
    nodesInGroup(group: string): Array<SceneNode> {
        const out = new Array<SceneNode>();
        const all = this.walk();
        for (let i = 0; i < all.length; i++) if (all[i].groups.includes(group)) out.push(all[i]);
        return out;
    }

    // --- Milestone 27: the live tree's API for scripts (Godot's SceneTree).

    // The nodes in `group`, in tree order (a new array: the caller's to
    // change). In a live tree the index answers; in another tree a walk.
    getNodesInGroup(group: string): Array<SceneNode> {
        return this.groupMembers(group).slice(0);
    }

    // The first node in `group` in tree order, or null.
    getFirstNodeInGroup(group: string): SceneNode? {
        const m = this.groupMembers(group);
        return m.length > 0 ? m[0] : null;
    }

    // Calls `method` with `arg` on the script of each node in `group`, in
    // tree order (each script's call(method, arg)); returns how many
    // scripts were called. A node without a script is passed over.
    callGroup(group: string, method: string, arg: Value = Value.nil()): i32 {
        const m = this.groupMembers(group);
        let n = 0;
        // (the index's own array, never changed in place: a call that adds
        // or frees nodes makes the next query build a new one)
        for (let i = 0; i < m.length; i++) {
            const node = unchecked(m[i]);
            const s = node.scriptObject;
            if (s == null || node.freed) continue;
            const was = enterScript(node);
            s.call(method, arg);
            leaveScript(was);
            n++;
        }
        return n;
    }

    // A SceneTreeTimer counting `seconds` (one shot: it fires once; else
    // every `seconds` until cancelled). It counts while the scene plays.
    createTimer(seconds: f64, oneShot: bool = true): SceneTreeTimer {
        return this.timers().create(seconds, oneShot);
    }

    // A tween bound to no node (NodeScript.createTween binds its node's).
    createTween(): Tween {
        return this.tweens().create();
    }

    // The tree's timers (made on first use).
    timers(): TimerSet {
        let t = this.timerSet;
        if (t == null) {
            t = new TimerSet();
            this.timerSet = t;
        }
        return t;
    }

    // The tree's tweens (made on first use).
    tweens(): TweenSet {
        let t = this.tweenSet;
        if (t == null) {
            t = new TweenSet(this);
            this.tweenSet = t;
        }
        return t;
    }

    // Whether timers or tweens have work each frame (without making them).
    clocksBusy(): bool {
        const a = this.timerSet;
        const b = this.tweenSet;
        return (a != null && a.busy()) || (b != null && b.busy());
    }

    // (SceneNode.queueFree) `n` goes at the end of the frame.
    queueFree(n: SceneNode): void {
        this.freeQueue.push(n);
    }

    // `from` emits `signal` (a Timer's timeout): through the host, which
    // delivers it to the connections; nowhere without one.
    emitSignal(from: SceneNode, signal: string, value: Value): void {
        const host = this.host;
        if (host != null) host.emit(from, signal, value);
    }

    // Milestone 31: an engine signal (SceneTreeHost.emitEvent).
    emitEvent(from: SceneNode, ev: SignalEvent, quiet: bool = false): void {
        const host = this.host;
        if (host != null) host.emitEvent(from, ev, quiet);
    }

    // One line of what went wrong in a script's call, to the host.
    problem(message: string): void {
        const host = this.host;
        if (host != null) host.problem(message);
    }

    // The nodes of `group` in tree order: the live tree's index (built
    // again only after a change), or a walk of another tree.
    private groupMembers(group: string): Array<SceneNode> {
        if (this.root.liveTree !== this) return this.nodesInGroup(group);
        let index = this.groupIndex;
        const epoch = treeStructureEpoch();
        if (index == null || this.groupEpoch != epoch) {
            index = new Map<string, Array<SceneNode>>();
            const all = this.walk();
            for (let i = 0; i < all.length; i++) {
                const n = all[i];
                for (let g = 0; g < n.groups.length; g++) {
                    const name = n.groups[g];
                    if (!index.has(name)) index.set(name, new Array<SceneNode>());
                    index.get(name).push(n);
                }
            }
            this.groupIndex = index;
            this.groupEpoch = epoch;
        }
        return index.has(group) ? index.get(group) : NO_NODES;
    }

    // The camera the scene is seen through: the first (in tree order) with
    // `current`, else the first camera, else null. Milestone 34: a camera
    // under a SubViewport is that viewport's (viewports.as
    // viewportCameraOf), never the scene's.
    currentCamera(): Camera3D? {
        const all = this.walk();
        let first: Camera3D? = null;
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            const isCamera = n instanceof Camera3D;
            if (!isCamera || underSubViewport(n)) continue;
            const c = n as Camera3D;
            if (c.current) return c;
            if (first == null) first = c;
        }
        return first;
    }

    // Milestone 34: every SubViewport, in tree order (viewports.as has the
    // graph of them and their textures).
    subViewports(): Array<SubViewport> {
        const all = this.walk();
        const out = new Array<SubViewport>();
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            const isViewport = n instanceof SubViewport;
            if (isViewport) out.push(n as SubViewport);
        }
        return out;
    }

    // The first WorldEnvironment in tree order of the main world (milestone
    // 34: not under a SubViewport with a world of its own, whose
    // environment is that world's: ../render/viewports.as), or null.
    environment(): WorldEnvironment? {
        const all = this.walk();
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            const isEnvironment = n instanceof WorldEnvironment;
            if (isEnvironment && !inAWorldOfItsOwn(n)) return n as WorldEnvironment;
        }
        return null;
    }

    // Milestone 19: the LightmapGI the tree bakes and draws with, or null:
    // the first in tree order of those declared by the scene nearest the
    // root (fewest `owner` steps up), so the tree's own file's before an
    // instanced scene's. A scene draws with one bake; ../warnings.as says
    // when there are more.
    lightmapGi(): LightmapGI? {
        // The scene nearest the root wins: a scene that instances a baked
        // one and declares a LightmapGI of its own bakes and draws its own
        // (whose bake covers the instanced scene's geometry too).
        const all = this.walk();
        let best: LightmapGI? = null;
        let bestDepth = i32.MAX_VALUE;
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            const isGi = n instanceof LightmapGI;
            if (!isGi) continue;
            let depth = 0;
            for (let o = n.owner; o != null; o = o.owner) depth++;
            if (depth < bestDepth) {
                best = n as LightmapGI;
                bestDepth = depth;
            }
        }
        return best;
    }

    // Milestone 20: every ReflectionProbe of the tree, in tree order (the
    // order a frame draws them in and the CLI's `bake` captures them in),
    // whether visible or not.
    reflectionProbes(): Array<ReflectionProbe> {
        const all = this.walk();
        const out = new Array<ReflectionProbe>();
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            const isProbe = n instanceof ReflectionProbe;
            if (isProbe) out.push(n as ReflectionProbe);
        }
        return out;
    }

    // Milestone 33: every Decal of the tree, in tree order (the order a
    // frame draws them in: a later decal paints over an earlier one),
    // whether visible or not.
    decals(): Array<Decal> {
        const all = this.walk();
        const out = new Array<Decal>();
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            const isDecal = n instanceof Decal;
            if (isDecal) out.push(n as Decal);
        }
        return out;
    }

    // Every light, in tree order.
    lights(): Array<Light3D> {
        const out = new Array<Light3D>();
        const all = this.walk();
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            const isLight = n instanceof Light3D;
            if (isLight) out.push(n as Light3D);
        }
        return out;
    }
}

// Milestone 34: whether a SubViewport with own_world_3d is above `n` (as
// ../tree/viewports.as inOwnWorld, which this module cannot import).
function inAWorldOfItsOwn(n: SceneNode): bool {
    let p = n.parent;
    while (p != null) {
        const isViewport = p instanceof SubViewport;
        if (isViewport && (p as SubViewport).ownWorld3d) return true;
        p = p.parent;
    }
    return false;
}

// Milestone 34: whether a SubViewport is above `n` (its cameras are the
// viewport's). Allocates nothing.
export function underSubViewport(n: SceneNode): bool {
    let p = n.parent;
    while (p != null) {
        const isViewport = p instanceof SubViewport;
        if (isViewport) return true;
        p = p.parent;
    }
    return false;
}
