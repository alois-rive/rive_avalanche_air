// A tree's state machines run as one (docs/plans/RIVE_MODEL.md sections
// 3.3 and 5): the root scene's machine, and each instanced scene's (Rive's
// nested artboards, each running its own NestedStateMachine, or a
// NestedSimpleAnimation in its place), the way the run time
// (../runtime/feature_animation.as) and the tools (./scene_machines.as
// runStateMachine) both run them.
//
// One slot per scene root of the tree that declares machines or whose
// instancing node plays an animation (instance_animation): the tree's root
// runs its default_state_machine ("" the first machine, "-" none; the
// Scene3D's stateMachine or a script may replace it); an instancing node
// runs its instance_state_machine ("" the instanced scene's own default,
// "-" none) or, when instance_animation is set, that animation of the
// instanced scene instead, looping by its loop mode, scrubbed to
// instance_animation_time (0 to 1 of its duration) when that is not
// negative. An instanced scene runs at its instancing node's
// instance_speed and holds while instance_paused: the three are read every
// frame (they animate and bind), allocating nothing.
//
// The slots run in tree order (the root's first, a parent scene's before
// its children's, as Rive's nested artboards advance after their host's
// machine); the instancing animations after every machine. A subtree added
// at run time adds its slots at the end; one removed takes its slots away.
// A slot's machines' instances are made the first time each runs, and kept
// (a script's input and the machine run are one object).
//
// The machines the tree runs from its load enter their states with no
// time passing at the runner's first advance, then advance by that
// frame's time, so that `n` frames show `n` frames of their states'
// animations. A Rive host does the same for its own machines: its first
// frame, when it loads the file, is an advance of 0 (`rive --advance=N`
// shows N frames of animation), and Rive gives a scripted component no
// advance of 0 (ScriptedDrawable's advanceComponent), so the Scene3D's
// first advance is the host's second frame. Without this a 3D machine
// plays one frame behind a 2D one beside it. The tools run machines the
// same way, so that `--frame N` shows what the built project shows after
// N frames. A machine started later (the Scene3D's stateMachine changed,
// a script's play(), a subtree added) starts as a host's new machine
// does: its first advance enters its states and takes that frame.

import { SceneNode } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { ValueKind } from "../value";
import { CallbackSink, LinearAnimationInstance } from "../anim/instance";
import { SceneAnimations, flushQuaternions } from "../anim/scene_anims";
import { OutputView } from "../binding/outputs";
import {
    ANIMATION_PROPERTY, ANIMATION_TIME_PROPERTY, IS_PAUSED_PROPERTY, NO_STATE_MACHINE, SPEED_PROPERTY, STATE_MACHINE_PROPERTY,
} from "./decl";
import { SmData } from "./data";
import { SmEventSink, StateMachineInstance } from "./instance";
import { SceneMachines, stateMachineNamesHint } from "./scene_machines";
import { InputKind } from "../script";
import { ListenerHits } from "../listen/pick";
import { EVENT_RING_SIZE } from "./listeners";

// A string property of `node` (`fallback` when unset or not a string; a
// StringName reads as its text, as the tools read it).
export function propString(node: SceneNode, name: string, fallback: string): string {
    const v = node.getProp(name);
    return v != null && (v.kind == ValueKind.String || v.kind == ValueKind.StringName) ? v.s : fallback;
}

// A number property (`fallback` when unset or not a number).
export function propNumber(node: SceneNode, name: string, fallback: f64): f64 {
    const v = node.getProp(name);
    return v != null && v.isNumber() ? v.asF64() : fallback;
}

// A boolean property.
export function propBool(node: SceneNode, name: string, fallback: bool): bool {
    const v = node.getProp(name);
    return v != null && v.kind == ValueKind.Bool ? v.b : fallback;
}

// One scene root's run: its machines (by index, made the first time each
// runs) and the one running, or the instancing animation it plays.
export class MachineSlot {
    root: SceneNode;
    isRoot: bool;
    scene: SceneMachines?;
    instances: Array<StateMachineInstance?> = [];
    // The machine running (an index into scene.machines), -1 none.
    running: i32 = -1;
    // The instancing animation (instance_animation): its scene's
    // animations, its index there (-1 none) and its instance.
    animations: SceneAnimations? = null;
    animation: i32 = -1;
    player: LinearAnimationInstance? = null;
    // The fraction it was last scrubbed to (instance_animation_time; NaN
    // none yet).
    scrubbed: f64 = NaN;
    // Whether the machine running needs no advance of 0 before its next
    // (see the header): false only for one the tree runs from its load,
    // until the runner's first advance.
    entered: bool = false;

    constructor(root: SceneNode, isRoot: bool, scene: SceneMachines?) {
        this.root = root;
        this.isRoot = isRoot;
        this.scene = scene;
        if (scene != null) for (let i = 0; i < scene.machines.length; i++) this.instances.push(null);
    }

    // The machine running's instance, or null.
    get current(): StateMachineInstance? {
        return this.running >= 0 ? this.instances[this.running] : null;
    }
}

// Where an instancing animation's callback keys go: the scene's events and
// nodes' signals, to the runner's sink.
class SlotCallbacks extends CallbackSink {
    runner: MachineRunner;
    slot: MachineSlot? = null;

    constructor(runner: MachineRunner) {
        super();
        this.runner = runner;
    }

    callback(objectIndex: i32, trackIndex: i32, delaySeconds: f32): void {
        const s = this.slot;
        const sink = this.runner.events;
        if (s == null || sink == null) return;
        const sa = s.animations;
        if (sa == null) return;
        const t = sa.trackTarget(s.animation, objectIndex, trackIndex);
        if (t == null) return;
        const ev = t.event;
        if (ev != null) {
            sink.fireEvent(sa.root, ev.name, ev, delaySeconds);
            return;
        }
        if (t.signal.length == 0) return;
        const node = sa.targetNode(s.animation, objectIndex);
        if (node != null) sink.emitKeyed(node, t.signal);
    }
}

export class MachineRunner {
    tree: SceneTree;
    // What every machine reads and fires into, and what a component
    // condition on a screen output projects through.
    data: SmData? = null;
    events: SmEventSink? = null;
    view: OutputView? = null;
    // The root scene's machine in place of its default_state_machine (the
    // Scene3D's stateMachine, a test's), or null.
    rootChoice: string? = null;
    slots: Array<MachineSlot> = [];
    // What the slots made could not run (an instancing node naming a
    // machine or an animation its scene lacks), each once, for the run
    // time's errors.
    problems: Array<string> = [];
    private callbacks: SlotCallbacks;
    // Whether the runner has advanced (see the header).
    private advanced: bool = false;
    // Milestone 47: an event listener's ring overflowed (said once).
    private saidDropped: bool = false;

    constructor(tree: SceneTree) {
        this.tree = tree;
        this.callbacks = new SlotCallbacks(this);
    }

    // The slots of the subtree at `top` (the tree's root: every slot),
    // appended in tree order.
    build(top: SceneNode): void {
        this.collect(top);
    }

    // One slot alone: scene root `root` running its machine `choice` (the
    // tools' sample of a given scene).
    buildOne(root: SceneNode, choice: string): void {
        const own = root.machines;
        const sm = own != null && own.root === root ? own : null;
        const slot = new MachineSlot(root, true, sm);
        this.slots.push(slot);
        if (sm != null) this.run(slot, sm.choose(choice));
    }

    private collect(n: SceneNode): void {
        if (n.freed) return;
        if (this.slotFor(n) == null) this.makeSlot(n);
        for (let i = 0; i < n.children.length; i++) this.collect(n.children[i]);
    }

    private makeSlot(n: SceneNode): void {
        const isRoot = n === this.tree.root;
        if (!isRoot && n.instancePath.length == 0) return;
        const own = n.machines;
        const sm = own != null && own.root === n ? own : null;
        const anim = isRoot ? "" : propString(n, ANIMATION_PROPERTY, "");
        if (sm == null && anim.length == 0) return;
        const slot = new MachineSlot(n, isRoot, sm);
        this.slots.push(slot);
        if (anim.length > 0) {
            const sa = n.animations;
            const anims = sa != null && sa.root === n ? sa : null;
            const ai = anims != null ? anims.index(anim) : -1;
            if (anims == null || ai < 0) {
                this.problems.push("\"" + n.name + "\" plays animation \"" + anim + "\", which " + n.sceneFile + " does not have");
                return;
            }
            slot.animations = anims;
            slot.animation = ai;
            slot.player = new LinearAnimationInstance(anims.animations[ai]);
            return;
        }
        if (sm == null) return;
        let choice: string;
        if (isRoot) {
            const rc = this.rootChoice;
            choice = rc != null ? rc : sm.defaultChoice();
        } else {
            choice = propString(n, STATE_MACHINE_PROPERTY, "");
            if (choice.length == 0) choice = sm.defaultChoice();
        }
        const mi = sm.choose(choice);
        if (mi < 0 && choice != NO_STATE_MACHINE && !(choice.length == 0 && sm.machines.length == 0)) {
            this.problems.push("state machine \"" + choice + "\" not found in " + sm.file + " (" + stateMachineNamesHint(sm) + ")");
        }
        this.run(slot, mi);
    }

    // The slots of the subtree at `top` go (it leaves the tree).
    remove(top: SceneNode): void {
        let k = 0;
        for (let i = 0; i < this.slots.length; i++) {
            const s = this.slots[i];
            if (!isWithin(s.root, top)) this.slots[k++] = s;
        }
        this.slots.length = k;
    }

    // The slot of scene root `root`, or null.
    slotFor(root: SceneNode): MachineSlot? {
        for (let i = 0; i < this.slots.length; i++) if (this.slots[i].root === root) return this.slots[i];
        return null;
    }

    // The root scene's slot, or null.
    rootSlot(): MachineSlot? {
        return this.slotFor(this.tree.root);
    }

    // The machine instance scene root `root` runs now, or null.
    instanceFor(root: SceneNode): StateMachineInstance? {
        const s = this.slotFor(root);
        return s != null ? s.current : null;
    }

    // Machine `mi` of the slot's scene, made the first time (its data, its
    // sink and its view the runner's).
    instanceOf(slot: MachineSlot, mi: i32): StateMachineInstance {
        const had = slot.instances[mi];
        if (had != null) return had;
        const sm = slot.scene as SceneMachines;
        const inst = new StateMachineInstance(sm.machines[mi], sm, this.tree);
        inst.data = this.data;
        inst.events = this.events;
        inst.view = this.view;
        slot.instances[mi] = inst;
        return inst;
    }

    // The slot runs machine `mi` (-1: none) from its start.
    run(slot: MachineSlot, mi: i32): void {
        const sm = slot.scene;
        if (sm == null || mi < 0 || mi >= sm.machines.length) {
            slot.running = -1;
            return;
        }
        const inst = this.instanceOf(slot, mi);
        inst.reset();
        slot.running = mi;
        slot.entered = this.advanced;
    }

    // The root scene runs `choice` ("" its default_state_machine, "-"
    // none): false when its scene has no such machine (the one running
    // then keeps running).
    playRoot(choice: string): bool {
        const slot = this.rootSlot();
        if (slot == null) {
            // (a scene that declares no machines runs none, whatever "" or
            // "-" ask)
            return choice.length == 0 || choice == NO_STATE_MACHINE;
        }
        const sm = slot.scene;
        if (sm == null) return choice.length == 0 || choice == NO_STATE_MACHINE;
        const c = choice.length == 0 ? sm.defaultChoice() : choice;
        const mi = sm.choose(c);
        if (mi < 0 && c != NO_STATE_MACHINE && !(c.length == 0 && sm.machines.length == 0)) return false;
        this.rootChoice = choice;
        this.run(slot, mi);
        return true;
    }

    // One frame of `seconds`: each slot's machine, in tree order, then the
    // instancing animations; whether a value written changed or a state
    // changed.
    advance(seconds: f32): bool {
        let changed = false;
        const slots = this.slots;
        for (let i = 0; i < slots.length; i++) {
            const s = unchecked(slots[i]);
            const inst = s.current;
            if (inst == null) continue;
            if (!s.isRoot) {
                inst.speed = <f32>propNumber(s.root, SPEED_PROPERTY, 1);
                inst.paused = propBool(s.root, IS_PAUSED_PROPERTY, false);
            }
            // (one the tree runs from its load enters its states with no
            // time first, as a Rive host's first frame does: see the header)
            if (!s.entered) {
                s.entered = true;
                if (inst.advance(0)) changed = true;
            }
            if (inst.advance(seconds)) changed = true;
        }
        this.advanced = true;
        let played = false;
        for (let i = 0; i < slots.length; i++) {
            const s = unchecked(slots[i]);
            const player = s.player;
            if (player == null) continue;
            if (this.advanceAnimation(s, player, seconds)) changed = true;
            played = true;
        }
        if (played) flushQuaternions();
        return changed;
    }

    // An instancing animation's frame: scrubbed to instance_animation_time
    // when that is 0 to 1 (a change of it applied), else advanced by the
    // seconds times instance_speed unless instance_paused.
    private advanceAnimation(s: MachineSlot, player: LinearAnimationInstance, seconds: f32): bool {
        const sa = s.animations;
        if (sa == null) return false;
        const t = propNumber(s.root, ANIMATION_TIME_PROPERTY, -1);
        if (t >= 0 && t <= 1) {
            if (t == s.scrubbed) return false;
            s.scrubbed = t;
            player.setTimePercentage(<f32>t);
            return sa.applyDeferred(this.tree, player, 1);
        }
        s.scrubbed = NaN;
        if (propBool(s.root, IS_PAUSED_PROPERTY, false)) return false;
        const speed = <f32>propNumber(s.root, SPEED_PROPERTY, 1);
        const cb = this.callbacks;
        cb.slot = s;
        player.advance(seconds * speed, this.events != null ? cb : null);
        cb.slot = null;
        return sa.applyDeferred(this.tree, player, 1);
    }

    // Each running machine settles (Rive's settle loop); whether a state
    // changed.
    settle(): bool {
        let changed = false;
        for (let i = 0; i < this.slots.length; i++) {
            const inst = unchecked(this.slots[i]).current;
            if (inst != null && inst.settle()) changed = true;
        }
        return changed;
    }

    // Milestone 47 (./listeners.as): the nodes the running machines'
    // pointer listeners target, appended to `out` (emptied first): what the
    // picker casts collision objects against (../listen/pick.as). Allocates
    // nothing once `out` has grown.
    listenerTargets(out: Array<SceneNode>): void {
        out.length = 0;
        const slots = this.slots;
        for (let i = 0; i < slots.length; i++) {
            const inst = unchecked(slots[i]).current;
            if (inst != null) inst.listeners.targets(out);
        }
    }

    // Whether a running machine has a pointer listener (a pointer event is
    // picked only then).
    hasPointerListeners(): bool {
        const slots = this.slots;
        for (let i = 0; i < slots.length; i++) {
            const inst = unchecked(slots[i]).current;
            if (inst != null && inst.listeners.hasPointerListeners()) return true;
        }
        return false;
    }

    // A pointer event and what it hit, to every running machine's
    // listeners: the scenes that hold the nearest hit's node first, the
    // innermost first (the scene that owns it, then the scenes above it:
    // Rive's HitNestedArtboard hands a hit to the nested artboard's machine
    // before its host's own listeners see it, which 3D finds the other way
    // round), then the rest, deepest first (the slots in reverse tree
    // order). Every machine hears every event, so that its exits and drags
    // see the pointer leave. Whether a listener performed. Allocates
    // nothing.
    pointer(kind: InputKind, pointerId: i32, hits: ListenerHits): bool {
        const slots = this.slots;
        const hitNode = hits.count > 0 ? unchecked(hits.hits[0]).node : null;
        let performed = false;
        for (let pass = 0; pass < 2; pass++) {
            for (let i = slots.length - 1; i >= 0; i--) {
                const s = unchecked(slots[i]);
                const inst = s.current;
                if (inst == null || !inst.listeners.hasPointerListeners()) continue;
                const holds = hitNode != null && isWithin(hitNode, s.root);
                if (holds != (pass == 0)) continue;
                if (inst.listeners.pointer(kind, pointerId, hits)) performed = true;
            }
        }
        return performed;
    }

    // A release of pointer `pointerId` handled before the listeners: every
    // running machine's press for it ends (ListenerRun.cancelPress).
    cancelPress(pointerId: i32): void {
        const slots = this.slots;
        for (let i = 0; i < slots.length; i++) {
            const inst = unchecked(slots[i]).current;
            if (inst != null && inst.listeners.hasPointerListeners()) inst.listeners.cancelPress(pointerId);
        }
    }

    // The scene whose root is `sceneRoot` fired its event `name`: heard by
    // the event listeners of its machine and of the machines of the scenes
    // above it at their next advance. Allocates nothing (events past a
    // machine's ring are dropped, said once in `problems`).
    eventFired(sceneRoot: SceneNode, name: string): void {
        const slots = this.slots;
        for (let i = 0; i < slots.length; i++) {
            const s = unchecked(slots[i]);
            const inst = s.current;
            if (inst == null || !isWithin(sceneRoot, s.root)) continue;
            const ls = inst.listeners;
            ls.eventFired(sceneRoot, name);
            if (ls.dropped > 0 && !this.saidDropped) {
                this.saidDropped = true;
                ls.takeDropped();
                this.problems.push("state machine \"" + inst.machine.name + "\" of " + s.root.sceneFile + " heard more than "
                    + EVENT_RING_SIZE.toString() + " events in one frame: the event listeners hear the first "
                    + EVENT_RING_SIZE.toString());
            }
        }
    }

    // The problems made since the last call, as warnings at their scene
    // (the tools print them).
    takeProblems(): Array<string> {
        const out = this.problems;
        this.problems = [];
        return out;
    }
}

// Whether `n` is `root` or below it.
function isWithin(n: SceneNode, root: SceneNode): bool {
    let at: SceneNode? = n;
    while (at != null) {
        if (at === root) return true;
        at = at.parent;
    }
    return false;
}
