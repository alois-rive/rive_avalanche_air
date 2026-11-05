// Signals of the run time (milestone 39): a script emits one
// (NodeScript.emitSignal), the instance delivers it to the connections
// its scene declares (`<connection signal from to method>`: the target
// node's script receives NodeScript.signal(method, event), a virtual
// method, so no reflection is needed), and the host code that made the
// instance reads every signal of the frame (SceneInstance.takeSignals),
// as Godot's signals reach both scripts and the engine's user.
//
// Milestone 31: the engine emits its nodes' own signals here too (an
// Area3D's body_entered, a collision object's input_event and
// mouse_entered: ../interaction/), with Godot's arguments in the event's
// fields (`node`, `input`, `position`, `normal`, `shapeIndex`; RSCN.md,
// "Interaction" lists them per signal). Such an event is its emitter's
// own, filled again by its next emission so that emitting allocates
// nothing: a script or a host that keeps one past the frame copies what it
// needs.
//
// A <connection>'s `flags` follow Godot's: CONNECT_ONE_SHOT (4) removes it
// after it fires once; a deferred one (1) is delivered at once, as every
// other (there is no idle time to defer it to).

import { Vec3 } from "../../base/vecmath";
import { Value } from "../value";
import { SceneNode } from "../tree/node";
import { InputEvent } from "../script";

// Godot's CONNECT_ONE_SHOT: the connection is removed after it fires once
// (a <connection>'s flags, SceneNode.connect's).
export const CONNECT_ONE_SHOT: i32 = 4;

export class SignalEvent {
    // The emitting node's path from the instance's root ("." for the
    // root).
    from: string;
    signal: string;
    // One argument (Nil when none).
    value: Value;
    // Milestone 31, an engine signal's arguments (Godot's): the body of
    // body_entered/body_exited, the area of area_entered/area_exited, the
    // camera of input_event (null for a view no Camera3D node gives: the
    // Scene3D's turned view, the editor's); input_event's event, its point
    // (global, scene space) and normal there, and the index of the shape
    // (its CollisionShape3D among the object's shapes). Unused, null, zero
    // and -1.
    node: SceneNode? = null;
    input: InputEvent? = null;
    position: Vec3 = Vec3(0, 0, 0);
    normal: Vec3 = Vec3(0, 0, 0);
    shapeIndex: i32 = -1;
    // Milestone 31: a copy the instance's queue made of an engine event
    // (SceneInstance.emitEvent), reused once dropped.
    queuedCopy: bool = false;

    constructor(from: string, signal: string, value: Value) {
        this.from = from;
        this.signal = signal;
        this.value = value;
    }

    // Takes every field of `o` but queuedCopy.
    copyFrom(o: SignalEvent): void {
        this.from = o.from;
        this.signal = o.signal;
        this.value = o.value;
        this.node = o.node;
        this.input = o.input;
        this.position = o.position;
        this.normal = o.normal;
        this.shapeIndex = o.shapeIndex;
    }
}

// Where an instance delivers a connection's signal: the scripts feature
// (feature_scripts.as), which calls the target node's script's
// `signal(method, event)`. Kept apart from the core so that a module
// without scripts carries none of the script runtime.
export abstract class SignalTarget {
    // Calls `method` on `to`'s script with `event`; false when `to` has no
    // script.
    abstract deliver(to: SceneNode, method: string, event: SignalEvent): bool;
}
