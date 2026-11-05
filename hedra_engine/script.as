// hedra_engine/script: the node script API (milestone 41, docs/plans/BUILD.md
// section 4.2). A node's script imports it by this root-relative path in a
// Rive project (the vendored hedra_engine/ at the project's root), in Play's
// project and in the tools alike:
//
//   import { NodeScript, Vec3, print } from "hedra_engine/script";
//
//   export class Spin extends NodeScript {
//       speed: f32 = 0.5;
//       override _process(delta: f32): void {
//           this.node.rotateY(this.speed * delta);
//       }
//   }
//
// A public module: what it exports is the library's promise to scripts (a
// name that leaves bumps the library's major, version.as), while the
// engine's inner paths may move. It is today's NodeScript API, the
// engine's engine/src/scene/script.as, re-exported whole: NodeScript, SceneNode and
// the Node3D API, InputEvent and InputKind, PackedSceneRef, SignalEvent,
// Value, Vec2, Vec3, Vec4, Quat, Timer, Tween, EaseType, TransitionType,
// print, printErr, pushError, pushWarning, the scene's timelines and
// state machines a script reaches through NodeScript.scene (ScriptScene,
// ScriptAnimation, milestone 45; ScriptStateMachine and ScriptInput,
// milestone 46), and the registry types the generated hedra_project.as
// uses (ScriptRegistry, ScriptFactory, ScriptSetter).
export * from "./scene/script";

// The value kinds a generated registry's setters test (hedra_project.as).
export { ValueKind } from "./scene/value";
