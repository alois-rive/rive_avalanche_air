// The script runtime of a built project: the NodeScript instances of a
// loaded scene tree, and the calls the player makes on them (../script.as
// states the order: instances in tree order, exported properties, ready()
// children first, process() in tree order, input() in reverse tree order
// until handled). It needs no GPU, so the program's Tests suites drive it
// directly (editor/program/tests/player/).
//
// A node whose script has no registered class, or a script that fails (an
// abort traps the whole module, so "fails" means what the
// runtime can see: a missing class, a property the class does not export
// or cannot take) is reported in `problems` and left out; the scene still
// plays.
//
// The exported properties a node's script receives are the node's
// properties that its class does not have (classdb.as): a scene file sets
// `speed = 2.0` on the node, the validator warns that Node3D has no
// `speed` (inspect --check drops the warning when the script exports it),
// and the runtime hands it to the class's generated setter before ready().

//
// Milestone 39: the run time (../runtime/feature_scripts.as) uses
// this runtime with three switches. `bundleKeys` finds a script's class by
// its bundle path ("courtyard/scripts/spin.as", the module's registry keys,
// unique across the projects of one Rive project) rather than its res:// path;
// `skipIdle` stops calling a script's process() or input() once NodeScript's
// own ran (the class does not override it), so a scene whose scripts act
// only in ready() is idle; and `attachSubtree` attaches the scripts of a
// subtree a script added at run time. The player sets none of them.
//
// Milestone 27: Godot's lifecycle (../script.as). `attach` makes the
// instances (exported properties set), calls _enterTree on every node of
// the tree, parents first, then _ready, children first; a subtree added
// under a node of the live tree later gets the same (`attachSubtree`), and
// one removed gets _exitTree, children first, the last child first, as
// Godot (`detachSubtree`): its instances leave the list, so nothing is
// called on them afterwards. `process` runs a frame in the spec's order:
// the tree's timers, its tweens, every script's _process, then the frees
// queueFree asked for. A runtime that plays a tree no instance plays (the
// player, the tests) is the tree's host and listener itself: signals go
// to the connections' scripts, problems to `problems`.

import { findProp } from "../classdb";
import { bundlePathOf } from "../bundle/format";
import { Value, valueKindName } from "../value";
import { SceneTree, SceneTreeHost } from "../tree/tree";
import { NodeAddedListener, SceneNode, TimerNode, enterScript, leaveScript, markFreed } from "../tree/node";
import { InputEvent, NodeScript, ScriptRegistry, ScriptSetter } from "../script";
import { SignalEvent } from "../runtime/signals";

// One script instance and the node it is attached to.
export class ScriptInstance {
    node: SceneNode;
    script: NodeScript;
    // The script's display path (res://...) and class name.
    path: string;
    className: string;

    constructor(node: SceneNode, script: NodeScript, path: string, className: string) {
        this.node = node;
        this.script = script;
        this.path = path;
        this.className = className;
    }
}

// The host of a tree that no run-time instance plays: a script's signal
// goes to the tree's connections, a problem to the runtime's.
class LocalHost extends SceneTreeHost {
    rt: ScriptRuntime;

    constructor(rt: ScriptRuntime) {
        super();
        this.rt = rt;
    }

    emit(from: SceneNode, signal: string, value: Value): void {
        this.rt.deliver(from, signal, value);
    }

    problem(message: string): void {
        this.rt.problems.push(message);
    }
}

// ... and its listener: a subtree added or removed at run time.
class LocalListener extends NodeAddedListener {
    rt: ScriptRuntime;

    constructor(rt: ScriptRuntime) {
        super();
        this.rt = rt;
    }

    added(parent: SceneNode, child: SceneNode): void {
        this.rt.attachSubtree(child);
    }

    removing(parent: SceneNode, child: SceneNode): void {
        this.rt.detachSubtree(child);
    }
}

export class ScriptRuntime {
    registry: ScriptRegistry;
    tree: SceneTree? = null;
    // In tree order; only those of nodes in the tree.
    instances: Array<ScriptInstance> = [];
    // What could not be attached or set, one line each
    // ("Planter: res://scripts/spin.as has no registered class").
    problems: Array<string> = [];
    // How many times ready() and process() ran, summed over the instances
    // (the player's status reports them; tests check them).
    readyCalls: i32 = 0;
    processCalls: i64 = 0;
    // Milestone 27: how many times _enterTree and _exitTree ran, and how
    // many nodes queueFree freed (tests).
    enterCalls: i32 = 0;
    exitCalls: i32 = 0;
    freedNodes: i32 = 0;
    // Milestone 39 (see the header).
    bundleKeys: bool = false;
    // Milestone 41: a class is found by the script's path in its Hedra
    // project ("scripts/spin.as": a generated hedra_project.as's keys),
    // a res:// path losing its "res://" (after bundleKeys, which gives a
    // built scene's the same form), so that one registry serves a scene
    // drawn from its text and from its built form (hedra_engine/scene).
    projectKeys: bool = false;
    skipIdle: bool = false;
    // The instances a frame calls, copied first (a script may add or remove
    // nodes meanwhile); kept, so that a frame allocates nothing.
    private frameList: Array<ScriptInstance> = [];
    private inputList: Array<ScriptInstance> = [];
    // The host and listener this runtime installed (see the header).
    private ownHost: LocalHost? = null;
    private ownListener: LocalListener? = null;

    constructor(registry: ScriptRegistry) {
        this.registry = registry;
    }

    // Makes one instance per node with a script, in tree order, sets
    // `node`, `tree` and the exported properties from the node's
    // properties, then calls _enterTree on every node, parents first, and
    // ready() (_ready), children first. Returns the number of instances.
    attach(tree: SceneTree): i32 {
        this.tree = tree;
        if (tree.host == null) {
            const h = new LocalHost(this);
            this.ownHost = h;
            tree.host = h;
        }
        if (tree.onAdded == null) {
            const l = new LocalListener(this);
            this.ownListener = l;
            tree.onAdded = l;
        }
        this.adoptAll(tree.root, tree);
        this.enter(tree.root, tree);
        this.readyAll(tree.root, tree);
        return this.instances.length;
    }

    // Milestone 39: attaches the scripts of the subtree at `root`, which a
    // script added under a node of the live tree (the run time's
    // SceneInstance.nodeAdded, or this runtime's own listener): instances
    // made in tree order, merged into `instances` at their places in the
    // tree's order, their exported properties set; then _enterTree,
    // parents first, and ready(), children first, for the nodes that were
    // never ready. A node removed earlier and added again keeps its
    // script's instance. A subtree added under a node that is leaving the
    // tree (a script adding a child in its _exitTree) is not entered: it
    // would stay live outside the tree. Returns how many instances it added.
    attachSubtree(root: SceneNode): i32 {
        const tree = this.tree;
        if (tree == null || root.liveTree === tree) return 0;
        const p = root.parent;
        if (p == null || p.liveTree !== tree || p.isLeavingTree()) return 0;
        const before = this.instances.length;
        this.adoptAll(root, tree);
        const made = this.instances.length - before;
        // Back into tree order: the tree's walk, each node matched to its
        // instance (only when a subtree with scripts is added).
        if (made > 0) this.reorder(tree);
        this.enter(root, tree);
        this.readyAll(root, tree);
        return made;
    }

    // Milestone 27: the subtree at `root` is about to leave the live tree
    // (removeChild, queueFree; still linked): _exitTree on each of its
    // nodes, children first (the last child first), its Timers and its
    // bound tweens stopped, and its instances out of the list.
    detachSubtree(root: SceneNode): void {
        const tree = this.tree;
        // (one already leaving: a script removing it in its _exitTree)
        if (tree == null || root.liveTree !== tree || root.exiting) return;
        this.exit(root, tree);
        const list = this.instances;
        let k = 0;
        for (let i = 0; i < list.length; i++) {
            const inst = unchecked(list[i]);
            if (inst.node.liveTree === tree) list[k++] = inst;
        }
        list.length = k;
    }

    // An instance for each node of the subtree at `n` that has a script and
    // none in the list yet, in pre-order (the list's order for a whole
    // tree).
    private adoptAll(n: SceneNode, tree: SceneTree): void {
        if (n.freed) return;
        if (n.script != null && this.instanceOf(n) == null) {
            const inst = this.make(n, tree);
            if (inst != null) this.instances.push(inst);
        }
        for (let i = 0; i < n.children.length; i++) this.adoptAll(n.children[i], tree);
    }

    // _enterTree on `n` then on its children (the children read live: one
    // a script added meanwhile is entered once).
    private enter(n: SceneNode, tree: SceneTree): void {
        if (n.liveTree === tree || n.freed) return;
        n.liveTree = tree;
        const isTimer = n instanceof TimerNode;
        if (isTimer) tree.timers().addNode(n as TimerNode);
        const s = n.scriptObject;
        if (s != null) {
            s.attachedTree = tree;
            const was = enterScript(n);
            s._enterTree();
            leaveScript(was);
            this.enterCalls++;
        }
        for (let i = 0; i < n.children.length; i++) this.enter(n.children[i], tree);
    }

    // ready() on the children of `n`, then on `n`, for each never ready; a
    // Timer with autostart starts then (Godot starts it on ready).
    private readyAll(n: SceneNode, tree: SceneTree): void {
        for (let i = 0; i < n.children.length; i++) this.readyAll(n.children[i], tree);
        if (n.liveTree !== tree) return;
        const isTimer = n instanceof TimerNode;
        if (isTimer) {
            const t = n as TimerNode;
            if (!t.readied) {
                t.readied = true;
                if (t.autostart && !t.start()) tree.problem(n.path() + ": Timer: wait_time must be more than 0");
            }
        }
        const s = n.scriptObject;
        if (s == null || s.isReady) return;
        // (set first: a ready() that re-enters the runtime is not run twice)
        s.isReady = true;
        const was = enterScript(n);
        s.ready();
        leaveScript(was);
        this.readyCalls++;
    }

    // _exitTree on the children of `n` (the last first), then on `n`, which
    // then is outside the tree.
    // While it runs, `n` is marked exiting, so that a script removing it
    // (or an ancestor being exited) does not run the exit again.
    private exit(n: SceneNode, tree: SceneTree): void {
        const was = n.exiting;
        n.exiting = true;
        for (let i = n.children.length - 1; i >= 0; i--) {
            if (i < n.children.length) this.exit(n.children[i], tree);
        }
        if (n.liveTree !== tree) {
            n.exiting = was;
            return;
        }
        const s = n.scriptObject;
        if (s != null) {
            const running = enterScript(n);
            s._exitTree();
            leaveScript(running);
            this.exitCalls++;
        }
        const isTimer = n instanceof TimerNode;
        if (isTimer) tree.timers().removeNode(n as TimerNode);
        const tw = tree.tweenSet;
        if (tw != null) tw.killBoundTo(n);
        n.liveTree = null;
        n.lastTree = tree;
        n.exiting = was;
    }

    // The instance list in the tree's order (after a subtree was added).
    private reorder(tree: SceneTree): void {
        const all = tree.walk();
        const ordered = new Array<ScriptInstance>();
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            if (n.scriptObject == null) continue;
            for (let k = 0; k < this.instances.length; k++) {
                if (this.instances[k].node === n) {
                    ordered.push(this.instances[k]);
                    break;
                }
            }
        }
        this.instances = ordered;
    }

    // The instance of `n`'s script (exported properties set), or null when
    // it has none or its class is not registered (a problem). A node that
    // was in the tree before keeps its script's object.
    private make(n: SceneNode, tree: SceneTree): ScriptInstance? {
        const script = n.script;
        if (script == null) return null;
        const path = tree.loader.displayPath(script.path);
        let key = path;
        if (this.bundleKeys) {
            const b = bundlePathOf(script.path);
            if (b != null) key = b;
        }
        if (this.projectKeys && key.startsWith("res://")) key = key.substring(6);
        const cls = this.registry.find(key);
        if (cls == null) {
            this.problems.push(n.path() + ": " + key + " has no registered class");
            return null;
        }
        const kept = n.scriptObject;
        if (kept != null) return new ScriptInstance(n, kept, path, cls.name);
        const s = cls.make();
        s.attachedNode = n;
        s.attachedTree = tree;
        n.scriptObject = s;
        this.setExports(n, s, path, cls.set);
        return new ScriptInstance(n, s, path, cls.name);
    }

    // Offers `s` every property of `n` that the node's class does not
    // have. A type this format version does not know offers what Node3D
    // does not have, as the validator checks it against Node3D.
    private setExports(n: SceneNode, s: NodeScript, path: string, set: ScriptSetter): void {
        const schema = n.schemaClass();
        for (let i = 0; i < n.propNames.length; i++) {
            const name = n.propNames[i];
            if (findProp(schema, name) != null) continue;
            const v = n.propValues[i];
            if (!set(s, name, v)) {
                this.problems.push(n.path() + ": " + path + " cannot take property " + name + " (" + valueKindName(v.kind) + ")");
            }
        }
    }

    // One frame of `delta` seconds, in the spec's order: the tree's timers,
    // its tweens, process(delta) on every instance in tree order, then the
    // frees queueFree asked for. With `skipIdle`, a script whose process()
    // is NodeScript's own is called once, then no more (and not counted).
    // Returns whether anything ran that may change the picture: a script's
    // process, a timeout, a tween, a free. Allocates nothing of its own.
    process(delta: f32): bool {
        const tree = this.tree;
        if (tree == null) return false;
        const dt = <f64>delta;
        let changed = false;
        const timers = tree.timerSet;
        if (timers != null && timers.advance(tree, dt)) changed = true;
        const tweens = tree.tweenSet;
        if (tweens != null && tweens.advance(dt)) changed = true;
        const list = this.frameList;
        list.length = 0;
        for (let i = 0; i < this.instances.length; i++) list.push(unchecked(this.instances[i]));
        for (let i = 0; i < list.length; i++) {
            const inst = unchecked(list[i]);
            // (one a script removed this frame is called no more)
            if (inst.node.liveTree !== tree) continue;
            const s = inst.script;
            if (s.processOff || (this.skipIdle && s.processIdle)) continue;
            const was = enterScript(inst.node);
            s.process(delta);
            leaveScript(was);
            this.processCalls++;
            changed = true;
        }
        list.length = 0;
        if (this.flushFrees(tree)) changed = true;
        return changed;
    }

    // Frees what queueFree asked for this frame: each node leaves the tree
    // (removeChild: _exitTree), is marked freed, and the connections from
    // or to a freed node go. Whether any went.
    private flushFrees(tree: SceneTree): bool {
        const q = tree.freeQueue;
        if (q.length == 0) return false;
        // (by index: an _exitTree may queue more)
        for (let i = 0; i < q.length; i++) {
            const n = q[i];
            if (n.freed) continue;
            const p = n.parent;
            if (n === tree.root) {
                tree.problem(n.path() + ": queueFree: the scene's root cannot be freed");
                n.queued = false;
                continue;
            }
            // (a script may have removed it already: it is freed all the same)
            if (p != null) p.removeChild(n);
            markFreed(n);
            this.freedNodes++;
        }
        q.length = 0;
        const cs = tree.connections;
        let k = 0;
        for (let i = 0; i < cs.length; i++) {
            const c = cs[i];
            if (!c.from.freed && !c.to.freed) cs[k++] = c;
        }
        cs.length = k;
        return true;
    }

    // input(event) on every instance, last in tree order first, until one
    // sets `event.handled`. Returns whether one did. With `skipIdle`, as
    // `process`.
    input(event: InputEvent): bool {
        const tree = this.tree;
        const list = this.inputList;
        list.length = 0;
        for (let i = 0; i < this.instances.length; i++) list.push(unchecked(this.instances[i]));
        for (let i = list.length - 1; i >= 0; i--) {
            if (event.handled) break;
            const inst = unchecked(list[i]);
            if (inst.node.liveTree !== tree) continue;
            const s = inst.script;
            if (this.skipIdle && s.inputIdle) continue;
            const was = enterScript(inst.node);
            s.input(event);
            leaveScript(was);
        }
        list.length = 0;
        return event.handled;
    }

    // Milestone 39: how many instances process() still calls (with
    // `skipIdle`, those whose class overrides it, or not yet called; never
    // one setProcess(false) turned off).
    processing(): i32 {
        let n = 0;
        for (let i = 0; i < this.instances.length; i++) {
            const s = this.instances[i].script;
            if (!s.processOff && (!this.skipIdle || !s.processIdle)) n++;
        }
        return n;
    }

    // Milestone 27: whether a frame has work: a script that processes, a
    // timer or tween that runs, a node waiting to be freed.
    active(): bool {
        if (this.processing() > 0) return true;
        const tree = this.tree;
        return tree != null && (tree.clocksBusy() || tree.freeQueue.length > 0);
    }

    // Milestone 39: how many instances input() still reaches (as
    // `processing`).
    listening(): i32 {
        let n = 0;
        for (let i = 0; i < this.instances.length; i++) {
            if (!this.skipIdle || !this.instances[i].script.inputIdle) n++;
        }
        return n;
    }

    // Milestone 39: the instance attached to `n`, or null.
    instanceOf(n: SceneNode): ScriptInstance? {
        for (let i = 0; i < this.instances.length; i++) if (this.instances[i].node === n) return this.instances[i];
        return null;
    }

    // Milestone 27 (LocalHost): `from` emitted `signal`: each connection
    // from it for that signal calls its target's script's
    // signal(method, event) (a one-shot one is removed first). The event is
    // made only when a connection takes it.
    deliver(from: SceneNode, signal: string, value: Value): void {
        const tree = this.tree;
        if (tree == null) return;
        // (taken first: a handler may connect or disconnect; tree.as)
        const list = tree.emitting;
        const start = list.length;
        tree.takeConnections(from, signal);
        const end = list.length;
        let ev: SignalEvent? = null;
        for (let i = start; i < end; i++) {
            const c = unchecked(list[i]);
            // (a target freed outside the live tree keeps its connections
            // until that tree's end of frame: it is skipped whichever comes
            // first; the others, a handler may have disconnected)
            if (c.to.freed || (i > start && !tree.stillConnected(c))) continue;
            let e = ev;
            if (e == null) {
                e = new SignalEvent(from.pathFrom(tree.root), signal, value);
                ev = e;
            }
            const s = c.to.scriptObject;
            if (s == null) {
                this.problems.push("signal " + signal + " of " + e.from + ": " + c.to.pathFrom(tree.root)
                    + " has no script to call " + c.method + " on");
                continue;
            }
            const was = enterScript(c.to);
            s.signal(c.method, e);
            leaveScript(was);
        }
        list.length = start;
    }

    // Lets go of the tree: the host and listener this runtime installed are
    // removed (a test that makes many runtimes leaves no watch behind).
    dispose(): void {
        const tree = this.tree;
        if (tree == null) return;
        if (this.ownListener != null) tree.onAdded = null;
        if (this.ownHost != null) tree.host = null;
        this.ownListener = null;
        this.ownHost = null;
    }
}
