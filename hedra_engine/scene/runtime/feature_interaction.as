// The interaction feature of the run time (milestone 31,
// features.as FEATURE_INTERACTION; docs/formats/RSCN.md "Interaction",
// docs/cli/BUILD.md section 19): each instance's interaction world
// (../interaction/world.as), put on the tree for scripts
// (SceneTree.world), and stepped every frame between the scripts and the
// bindings' push (PHASE_INTERACTION): the world synced to what moved, every
// enabled RayCast3D cast, each monitoring Area3D's overlaps compared with
// the last frame's (body_entered, body_exited, area_entered, area_exited,
// in Godot's order), the pointer's picking (mouse_entered, mouse_exited,
// input_event, from the pointer events `input` receives and from a still
// pointer over something that moved). Its signals go through
// SceneInstance.emitEvent with events of its own, so a frame allocates
// nothing; it asks for a new picture only when a signal was emitted (a
// handler may have changed something) or Play's --shapes draws what moved.
//
// The order within a step is Godot's: an area's lists are brought up to
// date before its signals, so a handler that reads
// get_overlapping_bodies() sees the body that entered; per area in tree
// order, body_exited, area_exited, body_entered, area_entered, each list
// in its own order (the lists keep the order things entered; what entered
// in one step, in tree order). What overlaps on the first step enters
// then, as in Godot's first physics step. An area that stops monitoring
// empties its lists, with the exits.
//
// Picking (Godot's physics picking, at once rather than at the next
// physics step): a pointer event that no script's _input handled casts the
// ray through the pointer, from the camera's near plane to its far
// distance, into every layer's pickable bodies and areas
// (input_ray_pickable); the nearest object is under the pointer. A change
// emits mouse_exited on the old one, then mouse_entered on the new one;
// then the object under it gets input_event (a move, a press or a
// release), with the Camera3D looked through (null for a view no camera
// node gives: Scene3D's turned view), the event, the point and normal hit
// and the shape's index. A press on an object with input_capture_on_drag
// captures the pointer: that object gets every move and the release
// wherever the pointer is (the point and normal where the ray meets it,
// else zero and shape -1), and the pointer's object does not change until
// the release. A pointer that leaves the picture emits mouse_exited. Each
// step casts the pointer's ray again, so a still pointer over something
// that moved enters and leaves it too.
//
// A scene without a collision object or a ray (Play's module carries every
// feature) keeps the status it had and costs a comparison a frame.
//
// Every project carries this module: Build vendors the whole library and
// Play's module holds every feature; a scene with no collision object,
// shape or ray does not install it.

import { Vec3 } from "../../base/vecmath";
import { jsonQuote } from "../../base/json";
import { Ray } from "../../render/ray";
import { InputEvent, InputKind } from "../script";
import { Value } from "../value";
import { Area3D, CollisionObject3D, SceneNode, treeNamesEpoch } from "../tree/node";
import { SceneFrame } from "../render/adapter";
import { ALL_LAYERS } from "../interaction/api";
import { InteractionWorld, WorldRayHit } from "../interaction/world";
import { debugLinesInto } from "../interaction/debug_draw";
import { FEATURE_INTERACTION, Feature, InstanceFeature, PHASE_INTERACTION } from "./features";
import { SignalEvent } from "./signals";
import { SceneInstance, SceneRuntime } from "./scene_runtime";

export class InteractionFeature extends Feature {
    bit(): u32 {
        return FEATURE_INTERACTION;
    }

    forInstance(inst: SceneInstance): InstanceFeature {
        return new InteractionPart();
    }
}

// What a collision object emits: its path from the instance's root (each
// event's `from`) and its three events, made once.
class ObjectSignals {
    node: CollisionObject3D;
    path: string = "";
    entered: SignalEvent;
    exited: SignalEvent;
    inputEvent: SignalEvent;

    constructor(node: CollisionObject3D) {
        this.node = node;
        const nil = Value.nil();
        this.entered = new SignalEvent("", "mouse_entered", nil);
        this.exited = new SignalEvent("", "mouse_exited", nil);
        this.inputEvent = new SignalEvent("", "input_event", nil);
    }
}

// What an area emits, and its scratch lists for a step.
class AreaSignals {
    area: Area3D;
    obj: ObjectSignals;
    bodyEntered: SignalEvent;
    bodyExited: SignalEvent;
    areaEntered: SignalEvent;
    areaExited: SignalEvent;

    constructor(area: Area3D, obj: ObjectSignals) {
        this.area = area;
        this.obj = obj;
        const nil = Value.nil();
        this.bodyEntered = new SignalEvent("", "body_entered", nil);
        this.bodyExited = new SignalEvent("", "body_exited", nil);
        this.areaEntered = new SignalEvent("", "area_entered", nil);
        this.areaExited = new SignalEvent("", "area_exited", nil);
    }
}

// One instance's interaction.
export class InteractionPart extends InstanceFeature {
    // Made when the instance's tree is attached.
    world: InteractionWorld? = null;
    // Per object and per area, in the world's order (as of `generation`),
    // and the rename epoch (node.as treeNamesEpoch) their paths were named
    // at.
    private objects: Array<ObjectSignals> = [];
    private areas: Array<AreaSignals> = [];
    private generation: i32 = -1;
    private namedAt: i32 = -1;
    // The object under the pointer, the one that captured it, and the
    // pointer's last place (picture pixels) while it is over the picture.
    hovered: CollisionObject3D? = null;
    private captured: CollisionObject3D? = null;
    private pointerIn: bool = false;
    private pointerX: f32 = 0;
    private pointerY: f32 = 0;
    // Kept for a step and for the pointer.
    private ray: Ray = new Ray(Vec3(0, 0, 0), Vec3(0, 0, 1));
    private pick: WorldRayHit = new WorldRayHit();
    private nowBodies: Array<SceneNode> = [];
    private nowAreas: Array<Area3D> = [];
    private goneBodies: Array<SceneNode> = [];
    private goneAreas: Array<Area3D> = [];
    private newBodies: Array<SceneNode> = [];
    private newAreas: Array<Area3D> = [];
    // A detach's exits, its own (a handler of a step's exit may remove a
    // node: the step's lists above must not be touched then), and the
    // signals waiting to be emitted: each an object's record, its event
    // and the node it names (null: none). A detach during a step or a
    // flush queues its exits here, emitted when the step ends; one outside
    // them emits at once. Kept, refilled.
    private detachBodies: Array<SceneNode> = [];
    private detachAreas: Array<Area3D> = [];
    private pendingObj: Array<ObjectSignals> = [];
    private pendingEvent: Array<SignalEvent> = [];
    private pendingNode: Array<SceneNode?> = [];
    private busy: bool = false;
    // The roots of the subtrees that left during the step (a handler
    // removed them): the world, synced at the step's start, still holds
    // them, so a later area must neither enter them nor be stepped itself
    // (it would report a body entering that never exits). Kept, refilled.
    private goneRoots: Array<SceneNode> = [];
    // The camera node looked through, as of the plan `cameraPlan`.
    private cameraNode: SceneNode? = null;
    private cameraPlan: i64 = -1;
    // Play's --shapes: the world's motion the last frame drew.
    private drawnMotion: i64 = -1;
    private drawnHover: CollisionObject3D? = null;

    attach(inst: SceneInstance, root: SceneNode): void {
        if (root === inst.tree.root) {
            const w = new InteractionWorld(inst.tree);
            this.world = w;
            inst.tree.world.directSpaceState = w;
        } else {
            // (made again only when the subtree holds a collision object,
            // shape or ray: a script spawning anything else allocates
            // nothing here)
            const w = this.world;
            if (w == null) return;
            if (w.stale()) w.rebuild();
        }
        this.records(inst);
    }

    // A subtree leaves (still linked): what it held leaves the areas that
    // overlapped it, with their exits (per area in tree order, bodies then
    // areas); its own areas are emptied silently; a hovered object of it
    // exits the pointer. The lists change at once; the exits are emitted at
    // once, or, when a handler of the step's own signals removed the
    // subtree, after the step's signals (Godot refuses a removal while its
    // areas report, and a deferred one reports after them).
    detach(inst: SceneInstance, root: SceneNode): void {
        const w = this.world;
        if (w == null) return;
        this.records(inst);
        const recs = this.areas;
        for (let i = 0; i < recs.length; i++) {
            const r = recs[i];
            const a = r.area;
            if (within(a, root)) {
                a.overlappingBodies.length = 0;
                a.overlappingAreas.length = 0;
                continue;
            }
            const gb = this.detachBodies;
            const ga = this.detachAreas;
            gb.length = 0;
            ga.length = 0;
            keepOutside(a.overlappingBodies, root, gb);
            keepOutsideAreas(a.overlappingAreas, root, ga);
            for (let k = 0; k < gb.length; k++) this.queue(r.obj, r.bodyExited, gb[k]);
            for (let k = 0; k < ga.length; k++) this.queue(r.obj, r.areaExited, ga[k]);
        }
        const h = this.hovered;
        if (h != null && within(h, root)) {
            this.hovered = null;
            const o = this.recordOf(h);
            if (o != null) this.queue(o, o.exited, null);
        }
        const c = this.captured;
        if (c != null && within(c, root)) this.captured = null;
        if (this.busy) this.goneRoots.push(root);
        else this.flush(inst);
    }

    private queue(o: ObjectSignals, ev: SignalEvent, node: SceneNode?): void {
        this.pendingObj.push(o);
        this.pendingEvent.push(ev);
        this.pendingNode.push(node);
    }

    // Emits the queued signals in order, with those their handlers queue;
    // whether there were any. Allocates nothing once the queue has grown.
    private flush(inst: SceneInstance): bool {
        const os = this.pendingObj;
        if (os.length == 0) return false;
        const was = this.busy;
        this.busy = true;
        const evs = this.pendingEvent;
        const ns = this.pendingNode;
        for (let i = 0; i < os.length; i++) {
            const n = ns[i];
            if (n != null) this.emitNode(inst, os[i], evs[i], n);
            else this.emitPlain(inst, os[i], evs[i]);
        }
        os.length = 0;
        evs.length = 0;
        ns.length = 0;
        this.busy = was;
        return true;
    }

    advance(inst: SceneInstance, seconds: f64, phase: i32): bool {
        if (phase != PHASE_INTERACTION || !inst.playing) return false;
        const w = this.world;
        if (w == null) return false;
        if (w.stale()) w.rebuild();
        if (w.objects.length == 0 && w.rays.length == 0) return false;
        this.records(inst);
        w.sync();
        let changed = false;
        // The rays, cast from where the scripts left them.
        const rays = w.rays;
        w.holdSync = true;
        for (let i = 0; i < rays.length; i++) {
            const r = unchecked(rays[i]);
            if (r.enabled) r.forceRaycastUpdate(w);
            // (a direct `enabled = false` write skips setEnabled: forget the
            // hit here too, as Godot's disabled ray reports none)
            else if (r.colliding) r.clearHit();
        }
        w.holdSync = false;
        // The areas, in tree order (a removal by one of their handlers
        // reports its exits after them).
        const recs = this.areas;
        this.busy = true;
        this.goneRoots.length = 0;
        for (let i = 0; i < recs.length; i++) if (this.stepArea(inst, unchecked(recs[i]))) changed = true;
        if (this.flush(inst)) changed = true;
        this.busy = false;
        this.goneRoots.length = 0;
        // (a handler may have removed a subtree: bring the world up to date
        // first, or the pointer's recast would hover the removed node again)
        if (w.stale()) {
            w.rebuild();
            this.records(inst);
        }
        // The pointer over whatever moved.
        if (this.pointerIn && this.captured == null && this.repick(inst)) changed = true;
        if (inst.debugShapes && (w.motion != this.drawnMotion || this.hovered !== this.drawnHover)) {
            this.drawnMotion = w.motion;
            this.drawnHover = this.hovered;
            changed = true;
        }
        return changed;
    }

    // One area's step (see the header); whether it emitted.
    private stepArea(inst: SceneInstance, r: AreaSignals): bool {
        // (null once a handler earlier in this step disposed the instance)
        const w = this.world;
        if (w == null) return false;
        const a = r.area;
        const gone = this.goneRoots;
        if (gone.length > 0 && withinAny(a, gone)) return false;
        const nb = this.nowBodies;
        const na = this.nowAreas;
        w.overlapsOf(a, nb, na);
        if (gone.length > 0) {
            dropWithin(nb, gone);
            dropWithinAreas(na, gone);
        }
        const gb = this.goneBodies;
        const ga = this.goneAreas;
        const eb = this.newBodies;
        const ea = this.newAreas;
        gb.length = 0;
        ga.length = 0;
        eb.length = 0;
        ea.length = 0;
        // Removed first, keeping the order of what stays; then the new ones
        // appended in tree order.
        const lb = a.overlappingBodies;
        let k = 0;
        for (let i = 0; i < lb.length; i++) {
            const n = unchecked(lb[i]);
            if (nb.includes(n)) lb[k++] = n;
            else gb.push(n);
        }
        lb.length = k;
        const la = a.overlappingAreas;
        k = 0;
        for (let i = 0; i < la.length; i++) {
            const n = unchecked(la[i]);
            if (na.includes(n)) la[k++] = n;
            else ga.push(n);
        }
        la.length = k;
        for (let i = 0; i < nb.length; i++) {
            const n = unchecked(nb[i]);
            if (!lb.includes(n)) {
                lb.push(n);
                eb.push(n);
            }
        }
        for (let i = 0; i < na.length; i++) {
            const n = unchecked(na[i]);
            if (!la.includes(n)) {
                la.push(n);
                ea.push(n);
            }
        }
        if (gb.length + ga.length + eb.length + ea.length == 0) return false;
        for (let i = 0; i < gb.length; i++) this.emitNode(inst, r.obj, r.bodyExited, unchecked(gb[i]));
        for (let i = 0; i < ga.length; i++) this.emitNode(inst, r.obj, r.areaExited, unchecked(ga[i]));
        for (let i = 0; i < eb.length; i++) this.emitNode(inst, r.obj, r.bodyEntered, unchecked(eb[i]));
        for (let i = 0; i < ea.length; i++) this.emitNode(inst, r.obj, r.areaEntered, unchecked(ea[i]));
        return true;
    }

    // A pointer event (see the header). Never handles it.
    input(inst: SceneInstance, e: InputEvent): bool {
        if (!e.isPointer() || e.handled) return false;
        // (the pointer's place is kept even with nothing to hover yet, so an
        // object spawned under a still pointer is entered on the next step)
        const exit = e.kind == InputKind.PointerExit;
        if (exit) this.pointerIn = false;
        else {
            this.pointerIn = true;
            this.pointerX = e.x;
            this.pointerY = e.y;
        }
        const w = this.world;
        if (w == null || (w.objects.length == 0 && this.hovered == null)) return false;
        if (exit) {
            this.setHover(inst, null);
            return false;
        }
        if (w.stale()) w.rebuild();
        this.records(inst);
        const c = this.captured;
        if (c != null) {
            // (the captured object hears the pointer wherever it is)
            const o = this.recordOf(c);
            const ray = this.ray;
            const h = this.pick;
            const hit = inst.pickRay(e.x, e.y, ray) && w.castRayOn(c, ray.origin, this.farPoint(inst), h);
            if (e.kind == InputKind.PointerUp) this.captured = null;
            if (o != null) this.emitInput(inst, o, e, hit ? h : null);
            if (this.captured == null) this.repick(inst);
            return false;
        }
        if (!this.repick(inst) && this.hovered == null) return false;
        const hv = this.hovered;
        if (hv == null) return false;
        const o = this.recordOf(hv);
        if (o == null) return false;
        if (e.kind == InputKind.PointerMove || e.kind == InputKind.PointerDown || e.kind == InputKind.PointerUp) {
            this.emitInput(inst, o, e, this.pick.entry != null ? this.pick : null);
        }
        if (e.kind == InputKind.PointerDown && hv.inputCaptureOnDrag) this.captured = hv;
        return false;
    }

    // Casts the pointer's ray (its last place) and moves the hover to what
    // it meets; whether the hover changed. `pick` keeps the hit.
    private repick(inst: SceneInstance): bool {
        // (null once a handler disposed the instance)
        const w = this.world;
        if (w == null) return false;
        const ray = this.ray;
        const h = this.pick;
        h.entry = null;
        let next: CollisionObject3D? = null;
        if (inst.pickRay(this.pointerX, this.pointerY, ray)
            && w.castRay(ray.origin, this.farPoint(inst), ALL_LAYERS, true, true, false, true, null, true, h)) {
            next = h.entry!.object;
        }
        return this.setHover(inst, next);
    }

    // The far end of the pointer's ray: the camera's far distance along it.
    private farPoint(inst: SceneInstance): Vec3 {
        const sf = inst.planFrame;
        const far = sf != null ? sf.frame.camera.far : <f32>4000;
        const r = this.ray;
        return r.origin + r.dir * far;
    }

    // Moves the hover to `next`: mouse_exited on the old object, then
    // mouse_entered on the new one; whether it changed.
    private setHover(inst: SceneInstance, next: CollisionObject3D?): bool {
        const was = this.hovered;
        if (was === next) return false;
        this.hovered = next;
        if (was != null) {
            const o = this.recordOf(was);
            if (o != null) this.emitPlain(inst, o, o.exited);
        }
        // (a handler may have moved the hover on already)
        if (next != null && this.hovered === next) {
            const o = this.recordOf(next);
            if (o != null) this.emitPlain(inst, o, o.entered);
        }
        return true;
    }

    // input_event on `o`'s object with Godot's arguments.
    private emitInput(inst: SceneInstance, o: ObjectSignals, e: InputEvent, h: WorldRayHit?): void {
        const ev = o.inputEvent;
        ev.from = o.path;
        ev.node = this.camera(inst);
        ev.input = e;
        if (h != null && h.entry != null) {
            ev.position = h.position;
            ev.normal = h.normal;
            ev.shapeIndex = h.entry!.index;
        } else {
            ev.position = Vec3(0, 0, 0);
            ev.normal = Vec3(0, 0, 0);
            ev.shapeIndex = -1;
        }
        inst.emitEvent(o.node, ev);
    }

    // The Camera3D the last picture looked through (null for the turned
    // view and for a view no camera node gives), found again after each
    // plan.
    private camera(inst: SceneInstance): SceneNode? {
        if (this.cameraPlan != inst.planned) {
            this.cameraPlan = inst.planned;
            const sf = inst.planFrame;
            this.cameraNode = sf != null && sf.camera.length > 0 ? inst.tree.getNode(sf.camera) : null;
        }
        return inst.getYaw() == 0 ? this.cameraNode : null;
    }

    private emitPlain(inst: SceneInstance, o: ObjectSignals, ev: SignalEvent): void {
        ev.from = o.path;
        inst.emitEvent(o.node, ev);
    }

    private emitNode(inst: SceneInstance, o: ObjectSignals, ev: SignalEvent, node: SceneNode): void {
        ev.from = o.path;
        ev.node = node;
        inst.emitEvent(o.node, ev);
    }

    // The record of an object (a scan: a handful, and only on a signal).
    private recordOf(n: CollisionObject3D): ObjectSignals? {
        const os = this.objects;
        for (let i = 0; i < os.length; i++) if (unchecked(os[i]).node === n) return unchecked(os[i]);
        return null;
    }

    // The records brought up to the world's last rebuild: an object's and
    // an area's are kept while it stays (its events are reused), and every
    // path is named again (a move changes them). A rename alone names the
    // paths again and keeps the records (a group changes neither: nothing
    // is allocated for it).
    private records(inst: SceneInstance): void {
        const w = this.world;
        if (w == null) return;
        if (this.generation == w.generation) {
            const names = treeNamesEpoch();
            if (this.namedAt == names) return;
            this.namedAt = names;
            const root = inst.tree.root;
            const os = this.objects;
            for (let i = 0; i < os.length; i++) os[i].path = os[i].node.pathFrom(root);
            return;
        }
        this.generation = w.generation;
        this.namedAt = treeNamesEpoch();
        const old = this.objects;
        const oldAreas = this.areas;
        const objects = new Array<ObjectSignals>();
        const areas = new Array<AreaSignals>();
        const root = inst.tree.root;
        for (let i = 0; i < w.objects.length; i++) {
            const n = w.objects[i];
            let r: ObjectSignals? = null;
            for (let k = 0; k < old.length; k++) {
                if (old[k].node === n) {
                    r = old[k];
                    break;
                }
            }
            if (r == null) r = new ObjectSignals(n);
            r.path = n.pathFrom(root);
            objects.push(r);
            const isArea = n instanceof Area3D;
            if (!isArea) continue;
            let ar: AreaSignals? = null;
            for (let k = 0; k < oldAreas.length; k++) {
                if (<CollisionObject3D>oldAreas[k].area === n) {
                    ar = oldAreas[k];
                    break;
                }
            }
            if (ar == null) ar = new AreaSignals(n as Area3D, r);
            areas.push(ar);
        }
        this.objects = objects;
        this.areas = areas;
        // (what left the world leaves the lists of the areas that stay; the
        // detach that took it out said so already, or it was never in)
        for (let i = 0; i < areas.length; i++) {
            const a = areas[i].area;
            dropMissing(a.overlappingBodies, w.objects);
            dropMissingAreas(a.overlappingAreas, w.objects);
        }
        const h = this.hovered;
        if (h != null && !w.objects.includes(h)) this.hovered = null;
        const c = this.captured;
        if (c != null && !w.objects.includes(c)) this.captured = null;
    }

    // Play's --shapes: the frame's collision shapes and rays.
    afterPlan(inst: SceneInstance, sf: SceneFrame): void {
        const w = this.world;
        if (!inst.debugShapes || w == null) return;
        const lines = sf.frame.worldLines;
        debugLinesInto(w, this.hovered, 1, lines, lines.length);
        this.drawnMotion = w.motion;
        this.drawnHover = this.hovered;
    }

    status(inst: SceneInstance): string {
        const w = this.world;
        if (w == null || (w.objects.length == 0 && w.rays.length == 0)) return "";
        const h = this.hovered;
        const hr = h != null ? this.recordOf(h) : null;
        return ",\"areas\":" + w.areas.length.toString()
            + ",\"bodies\":" + (w.objects.length - w.areas.length).toString()
            + ",\"rays\":" + w.rays.length.toString()
            + ",\"overlaps\":" + this.overlaps().toString()
            + ",\"hover\":" + jsonQuote(hr != null ? hr.path : "");
    }

    stamp(inst: SceneInstance): i64 {
        const w = this.world;
        if (w == null || (w.objects.length == 0 && w.rays.length == 0)) return 0;
        let m: i64 = w.areas.length;
        m = m * 1000003 + w.objects.length;
        m = m * 1000003 + w.rays.length;
        m = m * 1000003 + this.overlaps();
        const h = this.hovered;
        m = m * 1000003 + (h != null ? <i64>w.objects.indexOf(h) + 2 : 1);
        m = m * 1000003 + this.generation;
        m = m * 1000003 + this.namedAt;
        return m;
    }

    // The sum of the areas' list lengths.
    private overlaps(): i32 {
        let n = 0;
        const recs = this.areas;
        for (let i = 0; i < recs.length; i++) {
            const a = unchecked(recs[i]).area;
            n += a.overlappingBodies.length + a.overlappingAreas.length;
        }
        return n;
    }

    dispose(inst: SceneInstance): void {
        this.hovered = null;
        this.captured = null;
        this.world = null;
    }
}

// Whether `n` is `root` or under it.
function within(n: SceneNode, root: SceneNode): bool {
    let p: SceneNode? = n;
    while (p != null) {
        if (p === root) return true;
        p = p.parent;
    }
    return false;
}

// Drops from `list` (in place, keeping the order) the nodes under `root`,
// into `gone`.
// Whether `n` is in one of the subtrees whose roots are `roots`.
function withinAny(n: SceneNode, roots: Array<SceneNode>): bool {
    for (let i = 0; i < roots.length; i++) if (within(n, unchecked(roots[i]))) return true;
    return false;
}

// Drops from `list` what is in one of the subtrees whose roots are
// `roots`, keeping the order of the rest.
function dropWithin(list: Array<SceneNode>, roots: Array<SceneNode>): void {
    let k = 0;
    for (let i = 0; i < list.length; i++) {
        const n = unchecked(list[i]);
        if (!withinAny(n, roots)) list[k++] = n;
    }
    list.length = k;
}

function dropWithinAreas(list: Array<Area3D>, roots: Array<SceneNode>): void {
    let k = 0;
    for (let i = 0; i < list.length; i++) {
        const n = unchecked(list[i]);
        if (!withinAny(n, roots)) list[k++] = n;
    }
    list.length = k;
}

function keepOutside(list: Array<SceneNode>, root: SceneNode, gone: Array<SceneNode>): void {
    let k = 0;
    for (let i = 0; i < list.length; i++) {
        const n = list[i];
        if (within(n, root)) gone.push(n);
        else list[k++] = n;
    }
    list.length = k;
}

function keepOutsideAreas(list: Array<Area3D>, root: SceneNode, gone: Array<Area3D>): void {
    let k = 0;
    for (let i = 0; i < list.length; i++) {
        const n = list[i];
        if (within(n, root)) gone.push(n);
        else list[k++] = n;
    }
    list.length = k;
}

function dropMissing(list: Array<SceneNode>, objects: Array<CollisionObject3D>): void {
    let k = 0;
    for (let i = 0; i < list.length; i++) {
        const n = list[i];
        const isObject = n instanceof CollisionObject3D;
        if (isObject && objects.includes(n as CollisionObject3D)) list[k++] = n;
    }
    list.length = k;
}

function dropMissingAreas(list: Array<Area3D>, objects: Array<CollisionObject3D>): void {
    let k = 0;
    for (let i = 0; i < list.length; i++) {
        const n = list[i];
        if (objects.includes(n)) list[k++] = n;
    }
    list.length = k;
}

// Adds the interaction feature to `rt` (the module's generated features.as
// calls it when the bundle's scenes use it).
export function installInteractionFeature(rt: SceneRuntime): void {
    rt.install(new InteractionFeature());
}
