// The optional parts of the run time: scripts, artboard textures,
// bindings and interaction. The core (scene_runtime.as and what it
// imports: the Hedra library, the renderer) never imports a feature
// module; each feature module (feature_<name>.as) imports the core and
// adds itself to a runtime through its `install<Name>Feature(rt)`.
// newSceneRuntime() (../../scene.as) installs every one, so a Rive project
// that vendors the library holds them all: a library shared by several
// scenes must hold what any of them uses (docs/cli/BUILD.md section
// 18). Each feature stays a module of its own all the same, which keeps
// the core free of it; section 19 says how one is added (its bit, name,
// root and installer in catalog.as, its installer in newSceneRuntime()).
//
// The constants are the run time's contract, kept in catalog.as (no
// imports, so the tools and the bundle writer read them without the run
// time) and re-exported here; the hooks are what the feature modules
// (feature_scripts.as, feature_artboards.as, feature_bindings.as)
// implement.

import { ViewModel } from "rive/data";
import { FrameRenderer } from "../../render/gpu/renderer";
import { InputEvent } from "../script";
import { SceneNode } from "../tree/node";
import { SceneFrame } from "../render/adapter";
import { SceneInstance } from "./scene_runtime";
import { SignalEvent } from "./signals";

export {
    CORE_ROOTS, FEATURE_ALL, FEATURE_ANIMATION, FEATURE_ARTBOARDS, FEATURE_BINDINGS, FEATURE_BITS, FEATURE_INSTALLERS,
    FEATURE_INTERACTION, FEATURE_NAMES, FEATURE_NAVIGATION, FEATURE_PARTICLES, FEATURE_ROOTS, FEATURE_SCRIPTS, FEATURE_AUDIO, featureBit,
    featureNameOfBit, featureNames,
} from "./catalog";
import { ScriptScene } from "../script/scene_api";
import { ViewModelValues } from "../binding/values";
import { EventDecl } from "../anim/decl";

// The phases of an advance, in order: a feature's `advance` is called once
// per phase, so the order stays the player's (engine/src/scene/player/
// player.as): the artboards, the bindings' pull, the scripts, the
// bindings' push. Milestone 31 puts the interaction world's step between
// the scripts and the push, as Godot's physics step follows the scripts'
// process: what the frame moved is detected (areas, rays, the pointer's
// picking) and its signals reach the scripts before the bindings push.
// Milestone 45 puts the timelines (PHASE_ANIMATION: the animation feature
// advances its playing instances and applies their keys) after the
// bindings' pull and before the scripts, Rive's step 4 of
// docs/plans/RIVE_MODEL.md section 5: scripts see the animated values and
// may override them; a property bound one_way is not keyed over (the bind
// wins, as in Rive), and a two_way or to_source one is pushed back after.
export const PHASE_ARTBOARDS: i32 = 0;
export const PHASE_PULL: i32 = 1;
export const PHASE_ANIMATION: i32 = 2;
export const PHASE_SCRIPTS: i32 = 3;
export const PHASE_INTERACTION: i32 = 4;
export const PHASE_PUSH: i32 = 5;
// Milestone 46: Rive's settle (docs/plans/RIVE_MODEL.md section 5, step 9):
// after the bindings pushed, the state machines try their transitions again
// with no time (a to_source binding or a script may have moved what a
// condition reads), at most sm/instance.as SETTLE_MAX times.
export const PHASE_SETTLE: i32 = 6;
export const PHASE_COUNT: i32 = 7;

// What one feature does for one instance. Every hook is optional.
export abstract class InstanceFeature {
    // The instance's tree is made (`root` its root), or a subtree was
    // added at run time (`root` the added node: a script instanced a
    // scene).
    attach(inst: SceneInstance, root: SceneNode): void {}

    // Milestone 27: the subtree at `root` is about to leave the tree (a
    // script removed or freed it; still linked).
    detach(inst: SceneInstance, root: SceneNode): void {}

    // One phase of an advance (PHASE_*); returns whether it changed what
    // the next draw shows.
    advance(inst: SceneInstance, seconds: f64, phase: i32): bool {
        return false;
    }

    // A pointer or key event; returns whether it was handled. (Milestone
    // 31: every feature hears a pointer event, the scripts' first, so that
    // the interaction feature sees whether a script's _input handled it;
    // key events reach the scripts only.)
    input(inst: SceneInstance, e: InputEvent): bool {
        return false;
    }

    // Milestone 31: a frame was planned (`sf`, new: the instance plans only
    // on change); the interaction feature adds its debug lines here.
    afterPlan(inst: SceneInstance, sf: SceneFrame): void {}

    // Milestone 31: `from` emitted `ev` (a script's emitSignal, a Timer's
    // timeout, an engine signal), after its connections were called: the
    // bindings feature fires the view model triggers bound to it.
    signalEmitted(inst: SceneInstance, from: SceneNode, ev: SignalEvent): void {}

    // Before the frame is rendered (artboards draw into their textures).
    beforeDraw(inst: SceneInstance, r: FrameRenderer): void {}

    // The view model instance the instance is bound to (null to unbind).
    bind(inst: SceneInstance, vm: ViewModel?): void {}

    // The view model instance the global `name` is (null: looked up in the
    // host's Context again), in place of what the Context has.
    bindGlobal(inst: SceneInstance, name: string, vm: ViewModel?): void {}

    // The feature's part of the status line: "" or `,"name":value` pairs
    // (SceneInstance.status puts them where the player's status had them).
    status(inst: SceneInstance): string {
        return "";
    }

    // Milestone 45 (the animation feature answers; the others keep these
    // defaults): plays the root scene's animation `name` from its start,
    // replacing what the last call played ("" stops it), and says whether
    // the scene has it (SceneInstance.playAnimation, the Scene3D's
    // `animation`); the scene `node` belongs to, for its script
    // (NodeScript.scene).
    playAnimation(inst: SceneInstance, name: string): bool {
        return false;
    }

    sceneOf(inst: SceneInstance, node: SceneNode): ScriptScene? {
        return null;
    }

    // Milestone 46 (the animation feature answers): runs the root scene's
    // state machine `name` ("" its default_state_machine, "-" none) from its
    // start in place of the one it ran, and says whether the scene has it
    // (SceneInstance.playStateMachine, the Scene3D's `stateMachine`).
    playStateMachine(inst: SceneInstance, name: string): bool {
        return false;
    }

    // Milestone 46 (the bindings feature answers): the view model instance
    // the instance is bound to, and the global view model `name` as its
    // bindings find it (the host's bound one, else the Context's), for the
    // state machines' conditions; null when it has none.
    boundValues(inst: SceneInstance): ViewModelValues? {
        return null;
    }

    globalValues(inst: SceneInstance, name: string): ViewModelValues? {
        return null;
    }

    // Milestone 47: whether the part wants pointer events picked
    // (SceneInstance.listenerHits picks only when a part does), appending
    // to `out` the nodes whose collision objects the pick casts (meshes are
    // always cast). The animation feature answers while a running machine
    // has a pointer listener, with their targets; the artboards feature
    // while the scene shows an artboard texture, with none.
    listenerGroups(inst: SceneInstance, out: Array<SceneNode>): bool {
        return false;
    }

    // Milestone 47: the scene whose root is `sceneRoot` fired its event
    // `name` (`decl` its declaration, null when it declares none), after
    // SceneInstance.fireEvent queued it: the animation feature fires the
    // event's `<binding property="fire">` triggers and has its machines'
    // event listeners hear it.
    eventFired(inst: SceneInstance, sceneRoot: SceneNode, name: string, decl: EventDecl?): void {}

    // Milestone 49: whether the part writes the scene's data (the view
    // model the instance is bound to, or a global) from what the scene
    // declares, asked once per instance once its tree is made
    // (SceneInstance.writesData): the bindings feature for a two_way,
    // to_source or signal binding, the animation feature for an Event's
    // fire binding or a state machine with a ListenerViewModelChange or a
    // StateMachineFireTrigger, the scripts feature for a script (a script
    // writes through two_way bindings and fires events). The Scene3D
    // component keeps such a scene running off-screen.
    writesData(inst: SceneInstance): bool {
        return false;
    }

    // Milestone 49: whether the part may fire the scene's events (the
    // animation feature: a scene declares an Event, or a machine fires
    // one), asked once per instance as writesData is: the Scene3D keeps
    // such a scene running off-screen while its view model has `events`.
    firesEvents(inst: SceneInstance): bool {
        return false;
    }

    // The instance goes.
    dispose(inst: SceneInstance): void {}

    // A number that changes whenever the feature's part of the status does
    // (SceneInstance.statusChanged, which must allocate nothing: the
    // status string is built only when this or the core's counts moved).
    stamp(inst: SceneInstance): i64 {
        return 0;
    }
}

// A feature a runtime has: its bit and a factory of its per-instance part.
export abstract class Feature {
    abstract bit(): u32;
    abstract forInstance(inst: SceneInstance): InstanceFeature;
}
