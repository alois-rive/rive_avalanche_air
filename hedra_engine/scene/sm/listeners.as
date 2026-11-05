// A state machine's listeners, prepared and running (milestone 47;
// docs/plans/RIVE_MODEL.md section 3.5; docs/engine/STATE_MACHINES.md
// "Listeners"): the port of rive-runtime's ListenerGroup and the pointer
// half of StateMachineInstance (src/listener_group.cpp processEvent, reset
// and releaseEvent; src/animation/state_machine_instance.cpp
// updateListeners, dragStart, dragEnd and applyEvents; listener_*.cpp for
// the actions) to hits found in 3D (../listen/pick.as).
//
// Per listener and per pointer (LISTENER_MAX_POINTERS ids, a fixed pool:
// a pointer id takes a slot on its first event and gives it back on its
// exit or when the machine restarts; a new pointer finding every slot held
// takes the least recently heard one's, whose pointer exits first): hovered and hovered before, the
// click phase (out, down, clicked), whether it has dragged since its down,
// its previous screen position, its last hit. Each pointer event, as
// Rive's updateListeners: every listener's state for that pointer is reset
// (hovered moves to hovered before; a clicked phase back to out); every
// listener's hover is found first (its target, or a node under it, among
// the event's hits: nearest first, up to the first opaque one, so a target
// behind an opaque hit is not hovered: Rive's canHit); then each listener
// runs ListenerGroup::processEvent, in Rive's order: Rive walks its hit
// components in draw order, topmost first, each running its listeners in
// file order, so here the listeners whose target the event hits go first,
// by that hit, nearest first (file order among the listeners of one hit),
// then the others (an exit, a drag or a click elsewhere) in file order:
// when two write the same property on one event, the farther one's write
// is the one left, as the lower shape's is in Rive. A down while hovered
// starts a click, an up while hovered after it completes it (`click`
// performs), a down or an up elsewhere cancels it; a hover change performs
// `enter` or `exit`; the event's own type performs while hovered (down, up,
// move); a move while the click phase is down performs `drag` wherever the
// pointer is. A pointer exit (or a pointer outside the picture) unhovers
// everything (exits perform), then the pointer's state is released.
//
// Drags, as Rive's: the first drag move of a pointer performs the
// `dragStart` listeners whose target is hovered then (Rive's
// StateMachineInstance::dragStart, which the drag listener calls before its
// own changes); the release after a drag performs the `dragEnd` listeners
// hovered then, then the `move` listeners hovered then (Rive's dragEnd ends
// with a pointerMove), before the release's own click or up listeners. Only
// a `drag` listener starts a drag, as in Rive: a machine with dragStart
// listeners alone never performs them. A pointer exit during a drag drops
// it, as Rive's releaseEvent does: nothing is hovered on an exit, so no
// `dragEnd` (nor `move`) listener performs, and the pointer's next press
// starts afresh. One thing differs from Rive, on purpose: a drag's start
// and end are performed once per event for the pointer (Rive calls them
// again for each drag listener of the machine, re-entering its pointer
// pass, whose resets then swallow the enters and exits of the listeners
// after).
//
// What a performance reads of the pointer (PointerInput): the listener's
// own hit (its nearest hit on its target); off its target (a drag, an
// exit, an up elsewhere), the ray meeting the plane through its last hit
// with the last hit's normal (0 when it was never hit); the screen
// position; the move since the listener's previous event for that pointer
// (zero on the event that hovers it first, as Rive resets its previous
// position then). An event or view model listener reads 0 for each.
//
// Actions, in order, at once (Rive performs them when the pointer event
// arrives; their view model writes reach the data at once and the machine
// reads them at its next advance): a view model write (a literal, another
// property through a converter, a pointer input; a trigger is fired), a
// machine input changed (bool set or toggled, number set, trigger fired), a
// scene event fired (to the instance's SmEventSink, as a timeline's), the
// target node moved to the pointer (ListenerAlignTarget, in 3D: onto the
// hit surface, or along the plane through the node facing the camera;
// keeping the offset it was grabbed at, the event that hovered its
// listener's target or pressed on it, with preserveOffset; its rotation and
// scale untouched). A performance marks the instance changed, so that its
// next advance says so (Rive's markNeedsAdvance, whatever the actions did);
// `changed` says, for a host that draws only what moved (the editor),
// whether an action actually changed something: a value written that
// differs, an input that moved, a trigger or an event fired, a node moved.
//
// Event listeners hear the events their scope fired (their target node's
// scene and the scenes under it; with no target, the machine's own scene
// and those under it), queued as they fire (a fixed ring of
// EVENT_RING_SIZE: more in one frame are dropped and counted) and performed
// at the start of the next advance (Rive's applyEvents); view model
// listeners perform at the start of each advance when their property
// changed since the last (a trigger: fired since), the first advance after
// the data was resolved again recording the value without performing.
//
// Memory: everything is made with the instance; a pointer event, an event
// heard and an advance allocate nothing once the data is resolved, each
// literal read and each converter built (the fired log for the tools and
// the editor allocates its entries while `logging`, which the run time
// leaves off).

import { SceneNode } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { EventDecl } from "../anim/decl";
import { SceneAnimations } from "../anim/scene_anims";
import { InputKind } from "../script";
import { LISTENER_MAX_HITS, ListenerHit, ListenerHits } from "../listen/pick";
import { affine, apX, apY, apZ, globalAffine, invertAffine } from "../listen/affine";
import { Vec3 } from "../../base/vecmath";
import { VmKind } from "../riv/riv_info";
import { BoundValue } from "../binding/values";
import { Converter, ConverterProblem, buildNamedConverter } from "../binding/converters";
import {
    BOOL_CHANGE_FALSE, BOOL_CHANGE_NAMES, BOOL_CHANGE_TOGGLE, BOOL_CHANGE_TRUE, InputKind as SmInputKind, LISTENER_MAX_POINTERS,
    LISTENER_TYPE_NAMES, ListenerActionDecl, ListenerActionKind, ListenerDecl, ListenerType, PointerInput, StateMachineDecl,
    isPointerListenerType, pointerInputOf,
} from "./decl";
import { SmPath, StateMachine } from "./machine";
import { PATH_FOUND, PathRun, parseLiteral } from "./resolve";
import { StateMachineInstance } from "./instance";

// The events a machine's listeners can hear between two advances (more
// are dropped: ListenerRun.takeDropped says how many).
export const EVENT_RING_SIZE: i32 = 32;

// Rive's GestureClickPhase (listener_group.hpp; `disabled` is Rive's
// drag-capture state, which 3D never enters).
const PHASE_OUT: u8 = 0;
const PHASE_DOWN: u8 = 1;
const PHASE_CLICKED: u8 = 2;

// One action, prepared: the property written (`path`) and the property
// read (`from`) as the machine's paths (StateMachine.paths: resolved by
// the instance against its data, as conditions' are), the machine input
// (`input`, an index; -1 none) or the pointer input (`pointerInput`,
// PointerInput's number; -1 none), the literal as written, the event and
// its declaration, the align target's path and flags.
export class SmListenerAction {
    kind: ListenerActionKind;
    decl: ListenerActionDecl;
    // Its index among its machine's listener actions (an instance keeps
    // its state for it by this).
    id: i32 = -1;
    path: SmPath? = null;
    from: SmPath? = null;
    input: i32 = -1;
    pointerInput: i32 = -1;
    value: string = "";
    hasValue: bool = false;
    // A ListenerViewModelChange's converter for a literal or a pointer
    // input ("" none; a `fromPath`'s is on its SmPath).
    converter: string = "";
    boolValue: i32 = 0;
    number: f32 = 0;
    event: string = "";
    eventDecl: EventDecl? = null;
    target: string = "";
    surface: bool = false;
    preserveOffset: bool = false;

    constructor(decl: ListenerActionDecl) {
        this.decl = decl;
        this.kind = decl.kind;
    }
}

// One listener, prepared: its type, its target's path (resolved to a node
// by the instance), its event or property, its actions.
export class SmListener {
    name: string;
    type: ListenerType;
    decl: ListenerDecl;
    target: string = "";
    event: string = "";
    path: SmPath? = null;
    actions: Array<SmListenerAction> = [];

    constructor(decl: ListenerDecl) {
        this.decl = decl;
        this.name = decl.name;
        this.type = decl.type;
        this.target = decl.target;
        this.event = decl.event;
    }
}

// Prepares `d`'s listeners into `m.listeners` (their paths added to
// m.paths; events found among `scene`'s: null, a scene without timelines,
// finds none and fires by name): called by prepareStateMachine.
export function prepareListeners(m: StateMachine, d: StateMachineDecl, scene: SceneAnimations? = null): void {
    let actionId = 0;
    for (let i = 0; i < d.listeners.length; i++) {
        const ld = d.listeners[i];
        const l = new SmListener(ld);
        if (ld.type == ListenerType.ViewModel && ld.path.length > 0) l.path = m.path(new SmPath(ld.path, ld.global, ""));
        for (let k = 0; k < ld.actions.length; k++) {
            const ad = ld.actions[k];
            const a = new SmListenerAction(ad);
            a.id = actionId++;
            switch (ad.kind) {
                case ListenerActionKind.ViewModelChange: {
                    if (ad.path.length > 0) a.path = m.path(new SmPath(ad.path, ad.global, ""));
                    if (ad.fromPath.length > 0) {
                        // (the converter is the source's: the value read goes
                        // through it before it is written)
                        a.from = m.path(new SmPath(ad.fromPath, ad.fromGlobal, ad.converter));
                    } else {
                        a.converter = ad.converter;
                        if (ad.input.length > 0) a.pointerInput = pointerInputOf(ad.input);
                        else if (ad.hasValue) {
                            a.hasValue = true;
                            a.value = ad.value;
                        }
                    }
                    break;
                }
                case ListenerActionKind.BoolChange: {
                    a.input = m.inputOfKind(ad.input, SmInputKind.Bool);
                    let b = BOOL_CHANGE_TRUE;
                    for (let n = 0; n < BOOL_CHANGE_NAMES.length; n++) if (BOOL_CHANGE_NAMES[n] == ad.value) b = n;
                    // (RML's numbers, should a declaration keep them)
                    if (ad.value == "0") b = BOOL_CHANGE_FALSE;
                    else if (ad.value == "1") b = BOOL_CHANGE_TRUE;
                    else if (ad.value == "2") b = BOOL_CHANGE_TOGGLE;
                    a.boolValue = b;
                    break;
                }
                case ListenerActionKind.NumberChange: {
                    a.input = m.inputOfKind(ad.input, SmInputKind.Number);
                    const x = parseFloat(ad.value);
                    a.number = isFinite(x) ? <f32>x : 0;
                    break;
                }
                case ListenerActionKind.TriggerChange:
                    a.input = m.inputOfKind(ad.input, SmInputKind.Trigger);
                    break;
                case ListenerActionKind.FireEvent:
                    a.event = ad.event;
                    a.eventDecl = scene != null ? scene.event(ad.event) : null;
                    break;
                default:
                    a.target = ad.target;
                    a.surface = ad.surface;
                    a.preserveOffset = ad.preserveOffset;
                    break;
            }
            l.actions.push(a);
        }
        m.listeners.push(l);
    }
}

// The number of actions of `m`'s listeners (their ids run 0 to it).
function actionCount(m: StateMachine): i32 {
    let n = 0;
    for (let i = 0; i < m.listeners.length; i++) n += m.listeners[i].actions.length;
    return n;
}

// What the tools and the editor log of a listener that performed: the
// frame (the tools'; -1 elsewhere), the scene it belongs to (its root's
// path from the tree's root, "." the root scene), the machine, the
// listener and the type it performed for, the node hit ("" none) and where.
export class ListenerFiring {
    frame: i32 = -1;
    scene: string = ".";
    machine: string = "";
    listener: string = "";
    type: string = "";
    node: string = "";
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;

    // "Knock click on Door" (the Output's and the dump's line).
    describe(): string {
        return this.listener + " " + this.type + (this.node.length > 0 ? " on " + this.node : "");
    }
}

// How the tools, the editor's dock and its dump name a listener: "Knock:
// click on Door", "Aim: drag on Floor", "Heard: event Creak", "Pressed:
// viewModel button/pressed" (a global's path "global/Theme/dark").
export function describeListener(d: ListenerDecl): string {
    const type = <i32>d.type < LISTENER_TYPE_NAMES.length ? LISTENER_TYPE_NAMES[<i32>d.type] : "?";
    let what = "";
    if (d.type == ListenerType.Event) what = d.event.length > 0 ? " " + d.event : "";
    else if (d.type == ListenerType.ViewModel) what = d.path.length > 0 ? " " + globalPath(d.global, d.path) : "";
    else what = d.target.length > 0 ? " on " + d.target : "";
    return d.name + ": " + type + what;
}

// How they name an action: "set open from open through Not", "set aim/x to
// hitX", "set count to 1", "fire ping" (a view model trigger), "toggle
// lit", "set lit to true", "set speed to 3", "fire knock" (an input),
// "fire event Creak", "align Cursor on the surface", "align Cursor
// keeping its offset" (plane, preserveOffset).
export function describeListenerAction(a: ListenerActionDecl): string {
    switch (a.kind) {
        case ListenerActionKind.ViewModelChange: {
            const to = globalPath(a.global, a.path);
            const through = a.converter.length > 0 ? " through " + a.converter : "";
            if (a.fromPath.length > 0) return "set " + to + " from " + globalPath(a.fromGlobal, a.fromPath) + through;
            if (a.input.length > 0) return "set " + to + " to " + a.input + through;
            if (a.hasValue) return "set " + to + " to " + a.value + through;
            return "fire " + to;
        }
        case ListenerActionKind.BoolChange:
            return a.value == "toggle" ? "toggle " + a.input : "set " + a.input + " to " + a.value;
        case ListenerActionKind.NumberChange:
            return "set " + a.input + " to " + a.value;
        case ListenerActionKind.TriggerChange:
            return "fire " + a.input;
        case ListenerActionKind.FireEvent:
            return "fire event " + a.event;
        default: {
            const how = a.surface ? " on the surface" : "";
            return "align " + a.target + how + (a.preserveOffset ? " keeping its offset" : "");
        }
    }
}

function globalPath(global: string, path: string): string {
    return global.length > 0 ? "global/" + global + "/" + path : path;
}

// One action as an instance runs it: its literal read as its property's
// kind (once that is known), its converter (built the first time), the
// node it aligns and the offset it was grabbed at, per pointer slot.
class ActionRun {
    literalKind: VmKind = VmKind.Other;
    literalOk: bool = false;
    literal: BoundValue = new BoundValue();
    converterTried: bool = false;
    converter: Converter? = null;
    targetLooked: bool = false;
    target: SceneNode? = null;
    // Per pointer slot: the offset (scene space) from the gesture's first
    // point to the node's origin (preserveOffset).
    offX: StaticArray<f64> = new StaticArray<f64>(LISTENER_MAX_POINTERS);
    offY: StaticArray<f64> = new StaticArray<f64>(LISTENER_MAX_POINTERS);
    offZ: StaticArray<f64> = new StaticArray<f64>(LISTENER_MAX_POINTERS);
}

// One running machine's listeners (see the header). Made by the
// StateMachineInstance with it (`owner`, set at once).
export class ListenerRun {
    machine: StateMachine;
    tree: SceneTree;
    sceneRoot: SceneNode;
    owner: StateMachineInstance? = null;
    // What performed since the last takeFired (kept and emptied in place;
    // filled only while `logging`: the tools and the editor turn it on),
    // each with `frame` (the tools set it before each step and advance).
    fired: Array<ListenerFiring> = [];
    logging: bool = false;
    frame: i32 = -1;
    // Events heard past the ring's room since the last takeDropped.
    dropped: i32 = 0;
    // Whether an action changed something since the host last cleared it
    // (see the header): unlike the instance's needsAdvance, a performance
    // that writes the value already there leaves it false.
    changed: bool = false;
    // False: a `move` or `drag` performance is logged only the first time
    // in its gesture (a move listener's hover, a drag listener's press), so that a host saying each one (the editor's Output)
    // allocates nothing while the pointer keeps moving.
    logRepeats: bool = true;
    // Which listeners performed since the host last asked (performedSince),
    // logged or not, and whether any did.
    private performedFlags: StaticArray<bool>;
    private anyPerformed: bool = false;
    private spare: Array<ListenerFiring> = [];
    private hasPointer: bool = false;
    private hasEvent: bool = false;
    // The pointer ids holding a slot (-1 free), when each was last heard
    // (a count of events) and where (the picture's pixels).
    private slotIds: StaticArray<i32> = new StaticArray<i32>(LISTENER_MAX_POINTERS);
    private slotHeard: StaticArray<i64> = new StaticArray<i64>(LISTENER_MAX_POINTERS);
    private slotX: StaticArray<f32> = new StaticArray<f32>(LISTENER_MAX_POINTERS);
    private slotY: StaticArray<f32> = new StaticArray<f32>(LISTENER_MAX_POINTERS);
    private heard: i64 = 0;
    // What an evicted pointer's exit is picked as (nothing hit).
    private noHits: ListenerHits = new ListenerHits();
    // Per listener and slot (listener * LISTENER_MAX_POINTERS + slot).
    private hovered: StaticArray<bool>;
    private prevHovered: StaticArray<bool>;
    private phase: StaticArray<u8>;
    private hasDragged: StaticArray<bool>;
    private prevX: StaticArray<f32>;
    private prevY: StaticArray<f32>;
    private hitIndex: StaticArray<i32>;
    private hasLast: StaticArray<bool>;
    // A move or drag already logged in its gesture (logRepeats false).
    private quiet: StaticArray<bool>;
    // The listeners in the order the event under way runs them (see the
    // header), by index.
    private order: StaticArray<i32>;
    // The last hit (scene space): point, normal, UV, 8 numbers each.
    private last: StaticArray<f64>;
    // The listeners' targets, found from the scene's root once.
    private targetsLooked: bool = false;
    private targetNodes: Array<SceneNode?> = [];
    private actionRuns: Array<ActionRun> = [];
    // The event ring (roots and names), its first entry and its length.
    private ringRoots: Array<SceneNode?> = [];
    private ringNames: Array<string> = [];
    private ringHead: i32 = 0;
    private ringCount: i32 = 0;
    // View model listeners: the value (or trigger count) last seen, and
    // the resolve it was seen under (-1: none yet).
    private vmLast: Array<BoundValue> = [];
    private vmCount: StaticArray<i32>;
    private vmEpoch: StaticArray<i32>;
    // The performance under way: its pointer inputs (scene space), its hit.
    private inPointer: bool = false;
    private inX: f64 = 0;
    private inY: f64 = 0;
    private inZ: f64 = 0;
    private inNX: f64 = 0;
    private inNY: f64 = 0;
    private inNZ: f64 = 0;
    private inU: f64 = 0;
    private inV: f64 = 0;
    private inSX: f64 = 0;
    private inSY: f64 = 0;
    private inDX: f64 = 0;
    private inDY: f64 = 0;
    private inHit: ListenerHit? = null;
    private hits: ListenerHits? = null;
    // Where an align puts its node (scene space).
    private alignX: f64 = 0;
    private alignY: f64 = 0;
    private alignZ: f64 = 0;
    private scratch: BoundValue = new BoundValue();
    private before: BoundValue = new BoundValue();
    private converted: BoundValue = new BoundValue();
    private nodeGlobal: StaticArray<f64> = affine();
    private parentInv: StaticArray<f64> = affine();

    constructor(machine: StateMachine, sceneRoot: SceneNode, tree: SceneTree) {
        this.machine = machine;
        this.sceneRoot = sceneRoot;
        this.tree = tree;
        const n = machine.listeners.length;
        const slots = n * LISTENER_MAX_POINTERS;
        this.hovered = new StaticArray<bool>(slots);
        this.prevHovered = new StaticArray<bool>(slots);
        this.phase = new StaticArray<u8>(slots);
        this.hasDragged = new StaticArray<bool>(slots);
        this.prevX = new StaticArray<f32>(slots);
        this.prevY = new StaticArray<f32>(slots);
        this.hitIndex = new StaticArray<i32>(slots);
        this.hasLast = new StaticArray<bool>(slots);
        this.quiet = new StaticArray<bool>(slots);
        this.order = new StaticArray<i32>(n);
        this.performedFlags = new StaticArray<bool>(n);
        this.last = new StaticArray<f64>(slots * 8);
        this.vmCount = new StaticArray<i32>(n);
        this.vmEpoch = new StaticArray<i32>(n);
        for (let i = 0; i < n; i++) {
            const l = machine.listeners[i];
            if (isPointerListenerType(l.type)) this.hasPointer = true;
            if (l.type == ListenerType.Event) this.hasEvent = true;
            this.targetNodes.push(null);
            this.vmLast.push(new BoundValue());
            this.vmEpoch[i] = -1;
        }
        const na = actionCount(machine);
        for (let i = 0; i < na; i++) this.actionRuns.push(new ActionRun());
        for (let i = 0; i < EVENT_RING_SIZE; i++) {
            this.ringRoots.push(null);
            this.ringNames.push("");
        }
        for (let s = 0; s < LISTENER_MAX_POINTERS; s++) this.slotIds[s] = -1;
    }

    // Whether any listener hears the pointer.
    hasPointerListeners(): bool {
        return this.hasPointer;
    }

    // Appends the nodes the pointer listeners target (resolved from the
    // scene's root, each once) to `out`: what the picker casts collision
    // objects against. Allocates nothing once `out` has grown.
    targets(out: Array<SceneNode>): void {
        this.lookTargets();
        const ls = this.machine.listeners;
        for (let i = 0; i < ls.length; i++) {
            if (!isPointerListenerType(unchecked(ls[i]).type)) continue;
            const n = unchecked(this.targetNodes[i]);
            if (n == null) continue;
            let seen = false;
            for (let k = 0; k < out.length; k++) {
                if (unchecked(out[k]) === n) {
                    seen = true;
                    break;
                }
            }
            if (!seen) out.push(n);
        }
    }

    // The listeners' targets, looked up the first time and again when one
    // went (a node freed). "." is the scene's root; "" none (an event
    // listener without a target: its machine's scene).
    private lookTargets(): void {
        if (this.targetsLooked) {
            let stale = false;
            for (let i = 0; i < this.targetNodes.length; i++) {
                const n = unchecked(this.targetNodes[i]);
                if (n != null && n.freed) stale = true;
            }
            if (!stale) return;
        }
        this.targetsLooked = true;
        const ls = this.machine.listeners;
        for (let i = 0; i < ls.length; i++) {
            const path = unchecked(ls[i]).target;
            this.targetNodes[i] = path.length == 0 ? null : (path == "." ? this.sceneRoot : this.sceneRoot.getNode(path));
        }
    }

    // --- the pointer ---------------------------------------------------

    // One pointer event (`kind`, pointer `pointerId`) and what it hit:
    // Rive's updateListeners (see the header). Whether a listener performed.
    pointer(kind: InputKind, pointerId: i32, hits: ListenerHits): bool {
        if (!this.hasPointer) return false;
        if (kind != InputKind.PointerDown && kind != InputKind.PointerMove && kind != InputKind.PointerUp
            && kind != InputKind.PointerExit) return false;
        const exit = kind == InputKind.PointerExit;
        const s = this.slotOf(pointerId, !exit);
        if (s < 0) return false;
        unchecked(this.slotHeard[s] = ++this.heard);
        unchecked(this.slotX[s] = hits.screenX);
        unchecked(this.slotY[s] = hits.screenY);
        const owner = this.owner;
        if (owner != null) owner.prepare();
        this.lookTargets();
        const type = kind == InputKind.PointerDown ? ListenerType.Down : kind == InputKind.PointerUp ? ListenerType.Up
            : exit ? ListenerType.Exit : ListenerType.Move;
        this.hits = hits;
        const ls = this.machine.listeners;
        const n = ls.length;
        const x = hits.screenX;
        const y = hits.screenY;
        // Rive's reset, then prepareEvent: each listener's hover for this
        // event (none on an exit, or outside the picture).
        for (let i = 0; i < n; i++) {
            const k = i * LISTENER_MAX_POINTERS + s;
            unchecked(this.prevHovered[k] = this.hovered[k]);
            if (unchecked(this.phase[k]) == PHASE_CLICKED) unchecked(this.phase[k] = PHASE_OUT);
            const l = unchecked(ls[i]);
            let at = -1;
            if (!exit && hits.valid && isPointerListenerType(l.type)) {
                const t = unchecked(this.targetNodes[i]);
                if (t != null) at = hits.hitUnder(t);
            }
            unchecked(this.hitIndex[k] = at);
            unchecked(this.hovered[k] = at >= 0);
            if (at >= 0) this.recordHit(k, unchecked(hits.hits[at]));
        }
        this.sortByHit(s);
        let performed = false;
        let dragStarted = false;
        let dragEnded = false;
        for (let j = 0; j < n; j++) {
            const i = unchecked(this.order[j]);
            const l = unchecked(ls[i]);
            if (!isPointerListenerType(l.type)) continue;
            const k = i * LISTENER_MAX_POINTERS + s;
            const prevPhase = unchecked(this.phase[k]);
            const isHovered = unchecked(this.hovered[k]);
            const hoverChange = unchecked(this.prevHovered[k]) != isHovered;
            // (a new gesture, whose first move or drag is logged again: a
            // drag's is a press, a move's a hover)
            if (l.type == ListenerType.Drag ? type != ListenerType.Move : hoverChange) unchecked(this.quiet[k] = false);
            if (hoverChange && isHovered) {
                // (no jump: the move is counted from here)
                unchecked(this.prevX[k] = x);
                unchecked(this.prevY[k] = y);
            }
            if (isHovered && (hoverChange || type == ListenerType.Down)) this.grab(i, s);
            // The click's two phases.
            let phase = prevPhase;
            if (isHovered) {
                if (type == ListenerType.Down) phase = PHASE_DOWN;
                else if (type == ListenerType.Up && phase == PHASE_DOWN) phase = PHASE_CLICKED;
            } else if (type == ListenerType.Down || type == ListenerType.Up || exit) {
                phase = PHASE_OUT;
            }
            unchecked(this.phase[k] = phase);
            if (prevPhase == PHASE_DOWN && phase != PHASE_DOWN && unchecked(this.hasDragged[k])) {
                unchecked(this.hasDragged[k] = false);
                if (!dragEnded) {
                    dragEnded = true;
                    if (this.performAll(ListenerType.DragEnd, s, x, y)) performed = true;
                    if (this.performAll(ListenerType.Move, s, x, y)) performed = true;
                }
            }
            let matched = -1;
            if (hoverChange) {
                if (isHovered && l.type == ListenerType.Enter) matched = <i32>ListenerType.Enter;
                else if (!isHovered && l.type == ListenerType.Exit) matched = <i32>ListenerType.Exit;
            }
            if (phase == PHASE_CLICKED && l.type == ListenerType.Click) matched = <i32>ListenerType.Click;
            else if (isHovered && l.type == type) matched = <i32>type;
            if (phase == PHASE_DOWN && l.type == ListenerType.Drag && type == ListenerType.Move) {
                matched = <i32>ListenerType.Drag;
                if (!unchecked(this.hasDragged[k])) {
                    unchecked(this.hasDragged[k] = true);
                    if (!dragStarted) {
                        dragStarted = true;
                        if (this.performAll(ListenerType.DragStart, s, x, y)) performed = true;
                    }
                }
            }
            if (matched >= 0) {
                this.perform(i, s, <ListenerType>matched, x, y);
                performed = true;
            }
            unchecked(this.prevX[k] = x);
            unchecked(this.prevY[k] = y);
        }
        // Rive's releaseEvent: the pointer is gone.
        if (exit) this.release(s);
        this.hits = null;
        return performed;
    }

    // A release of pointer `pointerId` that something before the listeners
    // handled (a script's `_input`): its press ends without a click, a drag
    // or a dragEnd performing, its hovers kept, so that later moves with
    // the button up are not taken for a drag. Allocates nothing.
    cancelPress(pointerId: i32): void {
        const s = this.slotOf(pointerId, false);
        if (s < 0) return;
        const n = this.machine.listeners.length;
        for (let i = 0; i < n; i++) {
            const k = i * LISTENER_MAX_POINTERS + s;
            unchecked(this.phase[k] = PHASE_OUT);
            unchecked(this.hasDragged[k] = false);
        }
    }

    // The slot of pointer `id` (one taken when `take`: a free one, else the
    // least recently heard pointer's, after its exit), -1 none.
    private slotOf(id: i32, take: bool): i32 {
        for (let s = 0; s < LISTENER_MAX_POINTERS; s++) if (unchecked(this.slotIds[s]) == id) return s;
        if (!take) return -1;
        let oldest = 0;
        for (let s = 0; s < LISTENER_MAX_POINTERS; s++) {
            if (unchecked(this.slotIds[s]) < 0) {
                unchecked(this.slotIds[s] = id);
                this.clearSlot(s);
                return s;
            }
            if (unchecked(this.slotHeard[s]) < unchecked(this.slotHeard[oldest])) oldest = s;
        }
        // (every slot held: that pointer leaves where it was last heard,
        // its hovers ending and its drag with them, as its own exit would)
        const none = this.noHits;
        none.clear();
        none.screenX = unchecked(this.slotX[oldest]);
        none.screenY = unchecked(this.slotY[oldest]);
        this.pointer(InputKind.PointerExit, unchecked(this.slotIds[oldest]), none);
        unchecked(this.slotIds[oldest] = id);
        this.clearSlot(oldest);
        return oldest;
    }

    private clearSlot(s: i32): void {
        const n = this.machine.listeners.length;
        for (let i = 0; i < n; i++) {
            const k = i * LISTENER_MAX_POINTERS + s;
            unchecked(this.hovered[k] = false);
            unchecked(this.prevHovered[k] = false);
            unchecked(this.phase[k] = PHASE_OUT);
            unchecked(this.hasDragged[k] = false);
            unchecked(this.prevX[k] = 0);
            unchecked(this.prevY[k] = 0);
            unchecked(this.hitIndex[k] = -1);
            unchecked(this.hasLast[k] = false);
            unchecked(this.quiet[k] = false);
        }
    }

    private release(s: i32): void {
        this.clearSlot(s);
        unchecked(this.slotIds[s] = -1);
    }

    // Keeps the hit as the listener's last (the plane a later event off its
    // target is read on).
    private recordHit(k: i32, h: ListenerHit): void {
        const o = k * 8;
        const last = this.last;
        unchecked(last[o] = <f64>h.point.x);
        unchecked(last[o + 1] = <f64>h.point.y);
        unchecked(last[o + 2] = <f64>h.point.z);
        unchecked(last[o + 3] = <f64>h.normal.x);
        unchecked(last[o + 4] = <f64>h.normal.y);
        unchecked(last[o + 5] = <f64>h.normal.z);
        unchecked(last[o + 6] = <f64>h.u);
        unchecked(last[o + 7] = <f64>h.v);
        unchecked(this.hasLast[k] = true);
    }

    // `order` for slot s (see the header): the listeners hovered by their
    // hit's index, those not after them, file order otherwise (an insertion
    // sort, stable; a machine has few listeners). Allocates nothing.
    private sortByHit(s: i32): void {
        const order = this.order;
        const n = order.length;
        for (let j = 0; j < n; j++) {
            const key = this.hitKey(j, s);
            let at = j;
            while (at > 0 && this.hitKey(unchecked(order[at - 1]), s) > key) {
                unchecked(order[at] = order[at - 1]);
                at--;
            }
            unchecked(order[at] = j);
        }
    }

    // Where listener i's hit for slot s puts it in `order`: its hit's index,
    // past every hit when it is not hovered.
    private hitKey(i: i32, s: i32): i32 {
        const at = unchecked(this.hitIndex[i * LISTENER_MAX_POINTERS + s]);
        return at >= 0 ? at : LISTENER_MAX_HITS;
    }

    // Every pointer listener of `type` hovered for slot `s` performs, in
    // `order` (a drag's start and end, the move after its end).
    private performAll(type: ListenerType, s: i32, x: f32, y: f32): bool {
        const ls = this.machine.listeners;
        let any = false;
        for (let j = 0; j < ls.length; j++) {
            const i = unchecked(this.order[j]);
            if (unchecked(ls[i]).type != type) continue;
            if (!unchecked(this.hovered[i * LISTENER_MAX_POINTERS + s])) continue;
            this.perform(i, s, type, x, y);
            any = true;
        }
        return any;
    }

    // The pointer inputs of listener i for slot s (see the header).
    private readInputs(i: i32, s: i32, x: f32, y: f32): void {
        const k = i * LISTENER_MAX_POINTERS + s;
        const hits = this.hits;
        this.inPointer = true;
        this.inSX = <f64>x;
        this.inSY = <f64>y;
        this.inDX = <f64>x - <f64>unchecked(this.prevX[k]);
        this.inDY = <f64>y - <f64>unchecked(this.prevY[k]);
        this.inHit = null;
        const at = unchecked(this.hitIndex[k]);
        if (hits != null && at >= 0 && at < hits.count) this.inHit = unchecked(hits.hits[at]);
        if (!unchecked(this.hasLast[k])) {
            this.inX = 0;
            this.inY = 0;
            this.inZ = 0;
            this.inNX = 0;
            this.inNY = 0;
            this.inNZ = 0;
            this.inU = 0;
            this.inV = 0;
            return;
        }
        const o = k * 8;
        const last = this.last;
        this.inX = unchecked(last[o]);
        this.inY = unchecked(last[o + 1]);
        this.inZ = unchecked(last[o + 2]);
        this.inNX = unchecked(last[o + 3]);
        this.inNY = unchecked(last[o + 4]);
        this.inNZ = unchecked(last[o + 5]);
        this.inU = unchecked(last[o + 6]);
        this.inV = unchecked(last[o + 7]);
        if (at >= 0 || hits == null || !hits.valid) return;
        // Off its target: the ray on the plane of its last hit.
        this.onPlane(hits, this.inX, this.inY, this.inZ, this.inNX, this.inNY, this.inNZ);
    }

    // Sets the input point to where the event's ray meets the plane through
    // (px, py, pz) with normal n; false (the point as it was) when the ray
    // runs along the plane or meets it behind its origin.
    private onPlane(hits: ListenerHits, px: f64, py: f64, pz: f64, nx: f64, ny: f64, nz: f64): bool {
        const o = hits.rayOrigin;
        const d = hits.rayDir;
        const denom = <f64>d.x * nx + <f64>d.y * ny + <f64>d.z * nz;
        if (Math.abs(denom) < 1e-12) return false;
        const t = ((px - <f64>o.x) * nx + (py - <f64>o.y) * ny + (pz - <f64>o.z) * nz) / denom;
        if (!(t >= 0) || !isFinite(t)) return false;
        this.inX = <f64>o.x + <f64>d.x * t;
        this.inY = <f64>o.y + <f64>d.y * t;
        this.inZ = <f64>o.z + <f64>d.z * t;
        return true;
    }

    // Pointer input `p` of the performance under way.
    private pointerValue(p: i32): f64 {
        if (!this.inPointer) return 0;
        switch (p) {
            case PointerInput.HitX: return this.inX;
            case PointerInput.HitY: return this.inY;
            case PointerInput.HitZ: return this.inZ;
            case PointerInput.HitNormalX: return this.inNX;
            case PointerInput.HitNormalY: return this.inNY;
            case PointerInput.HitNormalZ: return this.inNZ;
            case PointerInput.HitU: return this.inU;
            case PointerInput.HitV: return this.inV;
            case PointerInput.ScreenX: return this.inSX;
            case PointerInput.ScreenY: return this.inSY;
            case PointerInput.DeltaX: return this.inDX;
            case PointerInput.DeltaY: return this.inDY;
        }
        return 0;
    }

    // The gesture's first point for listener i (it is hovered, or pressed):
    // each of its preserveOffset aligns keeps the offset from that point to
    // its node's origin.
    private grab(i: i32, s: i32): void {
        const l = unchecked(this.machine.listeners[i]);
        let needs = false;
        for (let a = 0; a < l.actions.length; a++) {
            const act = unchecked(l.actions[a]);
            if (act.kind == ListenerActionKind.AlignTarget && act.preserveOffset) needs = true;
        }
        const hits = this.hits;
        if (!needs || hits == null) return;
        this.readInputs(i, s, hits.screenX, hits.screenY);
        for (let a = 0; a < l.actions.length; a++) {
            const act = unchecked(l.actions[a]);
            if (act.kind != ListenerActionKind.AlignTarget || !act.preserveOffset) continue;
            const run = unchecked(this.actionRuns[act.id]);
            const node = this.alignNode(act, run);
            if (node == null) continue;
            const g = this.nodeGlobal;
            globalAffine(node, g);
            if (!this.alignPoint(act, g)) continue;
            unchecked(run.offX[s] = unchecked(g[9]) - this.alignX);
            unchecked(run.offY[s] = unchecked(g[10]) - this.alignY);
            unchecked(run.offZ[s] = unchecked(g[11]) - this.alignZ);
        }
        this.inPointer = false;
        this.inHit = null;
    }

    // --- performing ------------------------------------------------------

    // Listener i performs (for `type`), its pointer inputs read for slot s
    // at (x, y) (s -1: no pointer, every input 0).
    private perform(i: i32, s: i32, type: ListenerType, x: f32, y: f32): void {
        const l = unchecked(this.machine.listeners[i]);
        if (s >= 0) {
            this.readInputs(i, s, x, y);
        } else {
            this.inPointer = false;
            this.inHit = null;
        }
        for (let a = 0; a < l.actions.length; a++) this.act(unchecked(l.actions[a]), s);
        const owner = this.owner;
        if (owner != null) owner.needsAdvance = true;
        unchecked(this.performedFlags[i] = true);
        this.anyPerformed = true;
        if (this.logging && (this.logRepeats || !this.repeated(i, s, type))) this.log(l, type);
        this.inPointer = false;
        this.inHit = null;
    }

    // Whether a move or drag performance of listener i for slot s was
    // logged already in its gesture (marking it logged when not).
    private repeated(i: i32, s: i32, type: ListenerType): bool {
        if (s < 0 || (type != ListenerType.Move && type != ListenerType.Drag)) return false;
        const k = i * LISTENER_MAX_POINTERS + s;
        if (unchecked(this.quiet[k])) return true;
        unchecked(this.quiet[k] = true);
        return false;
    }

    // Whether listener i performed since the last call (cleared). Allocates
    // nothing.
    performedSince(i: i32): bool {
        if (!this.anyPerformed || i < 0 || i >= this.performedFlags.length) return false;
        const was = unchecked(this.performedFlags[i]);
        unchecked(this.performedFlags[i] = false);
        return was;
    }

    // Whether any listener performed since the flags were last cleared
    // (clearPerformed, after asking performedSince of each).
    hasPerformed(): bool {
        return this.anyPerformed;
    }

    clearPerformed(): void {
        for (let i = 0; i < this.performedFlags.length; i++) unchecked(this.performedFlags[i] = false);
        this.anyPerformed = false;
    }

    private log(l: SmListener, type: ListenerType): void {
        const f = new ListenerFiring();
        f.frame = this.frame;
        f.scene = this.sceneRoot.path();
        f.machine = this.machine.name;
        f.listener = l.name;
        f.type = LISTENER_TYPE_NAMES[<i32>type];
        const h = this.inHit;
        const node = h != null ? h.node : null;
        f.node = node != null ? node.path() : "";
        if (this.inPointer) {
            f.x = this.inX;
            f.y = this.inY;
            f.z = this.inZ;
        }
        this.fired.push(f);
    }

    private act(a: SmListenerAction, s: i32): void {
        const owner = this.owner;
        if (owner == null) return;
        switch (a.kind) {
            case ListenerActionKind.ViewModelChange:
                this.viewModelChange(owner, a);
                return;
            case ListenerActionKind.BoolChange: {
                if (a.input < 0) return;
                const was = owner.inputBool(a.input);
                const b = a.boolValue == BOOL_CHANGE_TOGGLE ? !was : a.boolValue == BOOL_CHANGE_TRUE;
                owner.setInputBool(a.input, b);
                if (owner.inputBool(a.input) != was) this.changed = true;
                return;
            }
            case ListenerActionKind.NumberChange: {
                if (a.input < 0) return;
                const was = owner.inputNumber(a.input);
                owner.setInputNumber(a.input, <f64>a.number);
                if (owner.inputNumber(a.input) != was) this.changed = true;
                return;
            }
            case ListenerActionKind.TriggerChange:
                if (a.input >= 0) {
                    owner.fireInput(a.input);
                    this.changed = true;
                }
                return;
            case ListenerActionKind.FireEvent: {
                const sink = owner.events;
                if (sink != null && a.event.length > 0) {
                    sink.fireEvent(this.sceneRoot, a.event, a.eventDecl, 0);
                    this.changed = true;
                }
                return;
            }
            default:
                this.align(a, s);
        }
    }

    private viewModelChange(owner: StateMachineInstance, a: SmListenerAction): void {
        const p = a.path;
        if (p == null) return;
        const pr = owner.pathRun(p.id);
        if (pr.state != PATH_FOUND) return;
        if (pr.kind == VmKind.Trigger) {
            // (a trigger is fired, whatever source is given, as Rive's)
            const sink = owner.events;
            if (sink != null) {
                sink.fireTrigger(this.sceneRoot, pr.resolved, p.global);
                this.changed = true;
            }
            return;
        }
        const run = unchecked(this.actionRuns[a.id]);
        let v: BoundValue? = null;
        const from = a.from;
        if (from != null) {
            v = owner.pathRun(from.id).read();
        } else if (a.pointerInput >= 0) {
            const x = this.scratch;
            x.setNumber(this.pointerValue(a.pointerInput));
            v = this.convert(owner, a, run, x, pr);
        } else if (a.hasValue) {
            const want = a.converter.length > 0 ? literalKindOf(a.value) : pr.kind;
            if (run.literalKind != want) {
                run.literalKind = want;
                run.literalOk = parseLiteral(want, a.value, run.literal);
            }
            if (run.literalOk) v = this.convert(owner, a, run, run.literal, pr);
        }
        if (v == null) return;
        // (`changed` only when the value there differs afterwards)
        const before = this.before;
        const had = pr.read();
        if (had != null) before.copyFrom(had);
        if (!pr.write(v)) return;
        const now = pr.read();
        if (had == null || now == null || !before.equals(now)) this.changed = true;
    }

    // `x` through the action's converter (none: as it is; one that could
    // not be built: nothing, as a binding with an unknown converter).
    private convert(owner: StateMachineInstance, a: SmListenerAction, run: ActionRun, x: BoundValue, pr: PathRun): BoundValue? {
        if (a.converter.length == 0) return x;
        if (!run.converterTried) {
            run.converterTried = true;
            const c = buildNamedConverter(a.converter, owner.scene.converterLookup(this.tree), new ConverterProblem());
            if (c != null) c.setDirection(false);
            run.converter = c;
        }
        const c = run.converter;
        if (c == null) return null;
        c.bind(pr.values);
        return c.forward(x, this.converted) ? this.converted : null;
    }

    // --- ListenerAlignTarget (see the header) ----------------------------

    private alignNode(a: SmListenerAction, run: ActionRun): SceneNode? {
        const had = run.target;
        if (run.targetLooked && (had == null || !had.freed)) return had;
        run.targetLooked = true;
        const path = a.target;
        const n = path.length == 0 ? null : (path == "." ? this.sceneRoot : this.sceneRoot.getNode(path));
        run.target = n;
        return n;
    }

    // Where the aligned node's origin goes for the performance under way
    // (alignX/Y/Z): on the surface, the listener's hit (or its plane's
    // point); else the ray on the plane through the node's origin (`g`, its
    // global transform) facing the camera. False without a pointer.
    private alignPoint(a: SmListenerAction, g: StaticArray<f64>): bool {
        const hits = this.hits;
        if (!this.inPointer || hits == null || !hits.valid) return false;
        if (a.surface) {
            if (this.inHit == null && !this.hasPlane()) return false;
            this.alignX = this.inX;
            this.alignY = this.inY;
            this.alignZ = this.inZ;
            return true;
        }
        const sx = this.inX, sy = this.inY, sz = this.inZ;
        const ok = this.onPlane(hits, unchecked(g[9]), unchecked(g[10]), unchecked(g[11]), <f64>hits.viewDir.x,
            <f64>hits.viewDir.y, <f64>hits.viewDir.z);
        this.alignX = this.inX;
        this.alignY = this.inY;
        this.alignZ = this.inZ;
        this.inX = sx;
        this.inY = sy;
        this.inZ = sz;
        return ok;
    }

    // Whether the performance under way has a point off its target (its
    // last hit's plane): a normal was recorded.
    private hasPlane(): bool {
        return this.inNX != 0 || this.inNY != 0 || this.inNZ != 0;
    }

    private align(a: SmListenerAction, s: i32): void {
        if (s < 0) return;
        const run = unchecked(this.actionRuns[a.id]);
        const node = this.alignNode(a, run);
        if (node == null) return;
        const g = this.nodeGlobal;
        globalAffine(node, g);
        if (!this.alignPoint(a, g)) return;
        let px = this.alignX, py = this.alignY, pz = this.alignZ;
        if (a.preserveOffset) {
            px += unchecked(run.offX[s]);
            py += unchecked(run.offY[s]);
            pz += unchecked(run.offZ[s]);
        }
        // The point in the parent's space (its global transform inverted).
        const parent = node.parent;
        let lx = px, ly = py, lz = pz;
        if (parent != null && parent.is3d) {
            globalAffine(parent, g);
            const inv = this.parentInv;
            if (!invertAffine(g, inv)) return;
            lx = apX(inv, px, py, pz);
            ly = apY(inv, px, py, pz);
            lz = apZ(inv, px, py, pz);
        }
        const was = node.position;
        node.setPosition(Vec3(<f32>lx, <f32>ly, <f32>lz));
        const now = node.position;
        if (was.x != now.x || was.y != now.y || was.z != now.z) this.changed = true;
    }

    // --- events and view model changes ----------------------------------

    // The scene whose root is `sceneRoot` (this machine's or one under it)
    // fired its event `name`: heard by the event listeners at the next
    // advance. Allocates nothing.
    eventFired(sceneRoot: SceneNode, name: string): void {
        if (!this.hasEvent) return;
        let wanted = false;
        const ls = this.machine.listeners;
        for (let i = 0; i < ls.length; i++) {
            const l = unchecked(ls[i]);
            if (l.type == ListenerType.Event && l.event == name) wanted = true;
        }
        if (!wanted) return;
        if (this.ringCount >= EVENT_RING_SIZE) {
            this.dropped++;
            return;
        }
        const at = (this.ringHead + this.ringCount) % EVENT_RING_SIZE;
        this.ringRoots[at] = sceneRoot;
        this.ringNames[at] = name;
        this.ringCount++;
    }

    // The events heard past the ring's room since the last call.
    takeDropped(): i32 {
        const n = this.dropped;
        this.dropped = 0;
        return n;
    }

    // At the start of each advance: the event listeners for the events
    // heard, the view model listeners for their properties' changes.
    // Whether one performed.
    advance(): bool {
        let performed = false;
        const ls = this.machine.listeners;
        if (this.hasEvent && this.ringCount > 0) {
            this.lookTargets();
            // (only the events heard before: one a listener fires now is
            // the next advance's)
            const n = this.ringCount;
            for (let e = 0; e < n; e++) {
                const at = this.ringHead;
                const root = unchecked(this.ringRoots[at]);
                const name = unchecked(this.ringNames[at]);
                this.ringRoots[at] = null;
                this.ringHead = (this.ringHead + 1) % EVENT_RING_SIZE;
                this.ringCount--;
                if (root == null) continue;
                for (let i = 0; i < ls.length; i++) {
                    const l = unchecked(ls[i]);
                    if (l.type != ListenerType.Event || l.event != name) continue;
                    if (!this.hears(i, root)) continue;
                    this.perform(i, -1, ListenerType.Event, 0, 0);
                    performed = true;
                }
            }
        }
        const owner = this.owner;
        if (owner == null) return performed;
        for (let i = 0; i < ls.length; i++) {
            const l = unchecked(ls[i]);
            const p = l.path;
            if (l.type != ListenerType.ViewModel || p == null) continue;
            if (this.viewModelChanged(owner, i, owner.pathRun(p.id))) {
                this.perform(i, -1, ListenerType.ViewModel, 0, 0);
                performed = true;
            }
        }
        return performed;
    }

    // Whether event listener i hears an event of the scene rooted at
    // `root`: its target's scene or one under it (none: this machine's).
    private hears(i: i32, root: SceneNode): bool {
        const scope: SceneNode? = unchecked(this.machine.listeners[i]).target.length == 0 ? this.sceneRoot
            : unchecked(this.targetNodes[i]);
        if (scope == null) return false;
        let n: SceneNode? = root;
        while (n != null) {
            if (n === scope) return true;
            n = n.parent;
        }
        return false;
    }

    // Whether view model listener i's property changed since it last
    // looked (the first look after the data was resolved again records it).
    private viewModelChanged(owner: StateMachineInstance, i: i32, pr: PathRun): bool {
        const fresh = unchecked(this.vmEpoch[i]) != owner.resolveEpoch;
        unchecked(this.vmEpoch[i] = owner.resolveEpoch);
        if (pr.state != PATH_FOUND) return false;
        if (pr.kind == VmKind.Trigger) {
            const n = pr.triggerCount();
            const was = unchecked(this.vmCount[i]);
            unchecked(this.vmCount[i] = n);
            return !fresh && n > was;
        }
        const v = pr.read();
        if (v == null) return false;
        const last = unchecked(this.vmLast[i]);
        const same = !fresh && last.kind == v.kind && last.equals(v);
        if (!same) last.copyFrom(v);
        return !fresh && !same;
    }

    // Back to the start (the machine restarted): every pointer released,
    // nothing heard, the view model listeners' values read afresh.
    reset(): void {
        for (let s = 0; s < LISTENER_MAX_POINTERS; s++) this.release(s);
        for (let i = 0; i < EVENT_RING_SIZE; i++) this.ringRoots[i] = null;
        this.ringHead = 0;
        this.ringCount = 0;
        for (let i = 0; i < this.vmEpoch.length; i++) this.vmEpoch[i] = -1;
    }

    // The performances logged since the last call (the kept list handed
    // out, a spare emptied and kept in its place: the caller reads it
    // before the next call).
    takeFired(): Array<ListenerFiring> {
        const out = this.fired;
        const spare = this.spare;
        spare.length = 0;
        this.fired = spare;
        this.spare = out;
        return out;
    }
}

// The kind a literal reads as before a converter takes it (it is written
// as the converter's output): a boolean, a number, else a string.
function literalKindOf(text: string): VmKind {
    if (text == "true" || text == "false") return VmKind.Boolean;
    const x = parseFloat(text);
    if (text.length > 0 && isFinite(x)) return VmKind.Number;
    return VmKind.String;
}
