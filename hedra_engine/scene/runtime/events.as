// The events a running scene fired (milestone 45, docs/plans/RIVE_MODEL.md
// section 3.6): a timeline's KeyFrameCallback on `event:<Name>`, or a
// script's `scene.fireEvent(name)`, fires the scene's <Event name>; the
// instance queues it (SceneInstance.takeEvents, for host code, with
// MAX_QUEUED_EVENTS at most; dropEvents forgets them, keeping the entries
// for the next ones) and its scene's root emits the signal
// `event_fired` with the event's name (EVENT_FIRED_SIGNAL), so that a
// <connection>, a script and a `signal:event_fired` binding hear it as any
// signal. Import-free but for the declaration, so that the core keeps it.

import { EventDecl } from "../anim/decl";

// The signal a scene's root emits for each event its scene fires: its
// value is the event's name.
export const EVENT_FIRED_SIGNAL = "event_fired";

// How many events an instance keeps for takeEvents before it drops the
// oldest (a host that never takes them costs a bounded queue).
export const MAX_QUEUED_EVENTS: i32 = 1000;

export class FiredEvent {
    // The path, from the instance's root, of the root of the scene that
    // fired it ("." the instance's own scene).
    scene: string;
    name: string;
    // How long ago in the frame it fired (Rive's reported event delay:
    // seconds between the key's time and the frame's end; 0 for a
    // script's).
    delay: f32 = 0;
    // The declaration: its custom properties (null for an event fired by a
    // name the scene does not declare, which never happens through a key).
    decl: EventDecl? = null;

    constructor(scene: string, name: string) {
        this.scene = scene;
        this.name = name;
    }
}
