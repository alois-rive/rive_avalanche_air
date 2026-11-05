// Pointer events played into a scene's listeners by runStateMachine
// (./scene_machines.as): what a tool, or a test, hands in. Plain data the
// runtime only reads; it never parses one. The tools' `--pointer` grammar
// and its parser are the authoring side's (./pointer_script.as, whose
// PointerScript extends PointerInput), so the runner depends on this data
// alone and not on a command-line grammar.

import { InputKind } from "../script";

// One pointer event: after `frame` frames have been advanced.
export class PointerStep {
    frame: i32;
    kind: InputKind;
    x: f32;
    y: f32;
    pointerId: i32 = 0;

    constructor(frame: i32, kind: InputKind, x: f32, y: f32) {
        this.frame = frame;
        this.kind = kind;
        this.x = x;
        this.y = y;
    }
}

// The steps, in order (frames never decrease), and the picture they are in
// (its size, 0 for the runner's default; the camera node's path, null or ""
// the scene's current one, as SceneRenderOptions.camera's null is).
// `camera` is nullable because a caller hands it a SceneRenderOptions'
// camera as it is: since rive 1.6 a null stored into a non-nullable field
// traps at the store, where 1.5.1 stored it and the runner's check below
// caught it.
export class PointerInput {
    steps: Array<PointerStep> = [];
    width: u32 = 0;
    height: u32 = 0;
    camera: string? = null;

    // The frame of the last step (-1 for none).
    lastFrame(): i32 {
        return this.steps.length > 0 ? this.steps[this.steps.length - 1].frame : -1;
    }
}
