// What a node script reaches its scene's timelines through (milestone 45,
// docs/plans/RIVE_MODEL.md section 5): `this.scene` (NodeScript, ../script.as)
// is the scene that declared the script's node (its .rscn, the root scene
// or an instanced one), and `scene.animation(name)` one of its
// LinearAnimations, with the API of Rive's script Animation (rive's
// luau/api/artboards.md: advance, setTime, setTimeFrames,
// setTimePercentage, duration) and Godot's verbs over it (play, stop):
//
//   const open = this.scene!.animation("Open");
//   if (open != null) open.play();             // the engine advances it each frame
//   // or by hand, each frame:  open!.advance(delta);
//
// Abstract, so that the core (../tree/tree.as SceneTreeHost.sceneOf,
// ../script.as) names them without carrying the animation feature, which
// implements them (../runtime/feature_animation.as). The tools' trees have
// no scene for scripts (null).
//
// Milestone 46 (docs/plans/RIVE_MODEL.md section 5): the scene's state
// machines, `scene.stateMachine(name)` (ScriptStateMachine: its inputs,
// its current states), and `scene.bindViewModel(vm)` and
// `scene.bindGlobal(name, vm)`, which bind the running instance's data as
// SceneInstance's do:
//
//   const main = this.scene!.stateMachine("Main");
//   const speed = main != null ? main.input("speed") : null;
//   if (speed != null) speed.setNumber(2);
//
// The members milestone 46 added have bodies here (none, false, nothing),
// so that an implementation written before them still compiles.

import { ViewModel } from "rive/data";

// One animation of a scene, for a script. `name` and `duration` (seconds:
// Rive's Animation.duration, the work area's when it is enabled) are set by
// the implementation; `mix` (0 to 1, default 1) is how strongly a played or
// advanced animation writes over the values there (Rive's mix: current * (1
// - mix) + value * mix).
export abstract class ScriptAnimation {
    name: string = "";
    duration: f32 = 0;
    mix: f32 = 1;

    // Advances by `seconds` (scaled by the animation's speed, looped by its
    // loopValue, as Rive's LinearAnimationInstance) and applies the keys
    // there; false once a oneShot animation has reached its end (and, as
    // Rive's, for a step of no time).
    abstract advance(seconds: f32): bool;
    // Moves the playhead (seconds, frames at the animation's fps, or a
    // fraction 0 to 1 of the duration) and applies the keys there.
    abstract setTime(seconds: f32): void;
    abstract setTimeFrames(frames: f32): void;
    abstract setTimePercentage(fraction: f32): void;
    // The playhead, in seconds.
    abstract time(): f32;
    // Godot's verbs: the engine advances a played animation every frame (in
    // the order play() was called), until stop() or, for a oneShot, its
    // end; play() on a finished oneShot starts it again from the start.
    abstract play(): void;
    abstract stop(): void;
    abstract isPlaying(): bool;
}

// Milestone 46: one input of a state machine (Rive's StateMachineNumber,
// StateMachineBool, StateMachineTrigger): `kind` 0 a number, 1 a boolean,
// 2 a trigger (../sm/decl.as InputKind).
export abstract class ScriptInput {
    name: string = "";
    kind: i32 = 0;

    abstract number(): f64;
    abstract setNumber(v: f64): void;
    abstract boolean(): bool;
    abstract setBoolean(b: bool): void;
    // Fires a trigger input (its conditions see it on the next advance).
    abstract fire(): void;
}

// Milestone 46: one state machine of a scene, for a script: the one the
// scene runs (its default_state_machine, or its instancing node's
// state_machine) or another, which play() runs in its place.
export abstract class ScriptStateMachine {
    name: string = "";

    // The input `name` (the same object on every call), or null.
    abstract input(name: string): ScriptInput?;
    // "Layer/State" for each layer, in order (makes strings: not for every
    // frame).
    abstract currentStates(): Array<string>;
    // Whether the scene runs this machine; play() runs it from its start in
    // place of the one it ran, stop() runs none.
    abstract isPlaying(): bool;
    abstract play(): void;
    abstract stop(): void;
}

// The scene a script's node belongs to.
export abstract class ScriptScene {
    // The scene's animation `name` (the same object on every call), or null.
    abstract animation(name: string): ScriptAnimation?;
    // The names of its animations, in file order.
    abstract animationNames(): Array<string>;
    // Fires the scene's Event `name` (as a timeline's KeyFrameCallback on
    // `event:<name>` would); false when the scene declares none of that
    // name.
    abstract fireEvent(name: string): bool;

    // Milestone 46: the scene's state machine `name` (the same object on
    // every call), or null; the names of its machines, in file order.
    stateMachine(name: string): ScriptStateMachine? {
        return null;
    }

    stateMachineNames(): Array<string> {
        return [];
    }

    // Milestone 46: binds the running instance's data, as
    // SceneInstance.bindViewModel and bindGlobal do (null unbinds, or goes
    // back to the host Context's global).
    bindViewModel(vm: ViewModel?): void {}

    bindGlobal(name: string, vm: ViewModel?): void {}
}
