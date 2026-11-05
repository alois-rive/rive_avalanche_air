// The tools' clock for particles (milestone 35): what `hedra render
// --time`, `--animation` and `--state-machine`, `inspect --particles` and
// the editor's Animate mode draw, a scene's particles from their start,
// advanced in steps of PARTICLE_TOOL_STEP (Rive's 60 frames a second), the
// same steps a built project at 60 frames a second takes, so the picture
// is the one it shows at that time. Each emitter is restarted first (its
// preprocess run), then stepped; a hook may change the tree before each
// step (the CLI samples a timeline there, so a keyed `emitting` starts and
// stops the flow as it does in Play). A restart here does not count as
// the node's restart() (sim.as restartParticles: the seed is the one a
// host's first frame uses), so `render --time 2` shows what a host shows
// after 120 frames of 1/60 s.

import { SceneTree } from "../tree/tree";
import { CPUParticles3D, SceneNode } from "../tree/node";
import { PARTICLE_TOOL_MAX_TIME, PARTICLE_TOOL_STEP } from "./state";
import { advanceTreeParticles, ensureParticles, particleEmitters, restartParticles, toolsStart } from "./sim";

// Called before each step, with the time the step starts at (seconds from
// the scene's start) and its index. A hook that samples a timeline samples
// it at the step's end (t + PARTICLE_TOOL_STEP): a host's run time
// advances its timelines by the frame before it steps the particles.
export abstract class ParticleStepHook {
    abstract beforeStep(t: f64, step: i32): void;
}

// What a run came to: the emitters (CPUParticles3D nodes of the tree), the
// particles alive at its end over all of them, the steps taken and the
// time reached.
export class ParticleRun {
    emitters: i32 = 0;
    emitting: i32 = 0;
    alive: i32 = 0;
    steps: i32 = 0;
    time: f64 = 0;
}

// The steps `seconds` takes on the tools' clock (rounded to the nearest
// whole step, so 1.0 s is 60 steps), held to PARTICLE_TOOL_MAX_TIME so a
// far frame ends and the count fits an i32.
export function toolSteps(seconds: f64): i32 {
    if (!(seconds > 0)) return 0;
    const t = seconds < PARTICLE_TOOL_MAX_TIME ? seconds : PARTICLE_TOOL_MAX_TIME;
    return <i32>Math.round(t / PARTICLE_TOOL_STEP);
}

// `tree`'s particles restarted, then advanced `seconds` on the tools'
// clock (`hook`, when given, before each step). A tree without a
// CPUParticles3D is left as it is (and answers 0 emitters).
export function particlesAtTime(tree: SceneTree, seconds: f64, hook: ParticleStepHook? = null): ParticleRun {
    const walked = tree.walk();
    const emitters = new Array<CPUParticles3D>();
    const run = new ParticleRun();
    run.emitters = particleEmitters(walked, emitters);
    if (run.emitters == 0) return run;
    // (each run from the scene as it was before the particles wrote to it:
    // a second run on the same tree, the editor's scrub back, draws what
    // the first drew)
    for (let i = 0; i < emitters.length; i++) toolsStart(emitters[i]);
    // (the hook once more at time 0 before the restarts, so their
    // preprocess sees the scene as the first step does, as a host's first
    // frame does, whatever an earlier run left keyed)
    if (hook != null) hook.beforeStep(0, 0);
    for (let i = 0; i < emitters.length; i++) restartParticles(emitters[i]);
    const steps = toolSteps(seconds);
    for (let k = 0; k < steps; k++) {
        if (hook != null) hook.beforeStep(<f64>k * PARTICLE_TOOL_STEP, k);
        advanceTreeParticles(walked, PARTICLE_TOOL_STEP);
    }
    run.steps = steps;
    run.time = <f64>steps * PARTICLE_TOOL_STEP;
    countParticles(walked, run);
    return run;
}

// `steps` steps of PARTICLE_TOOL_STEP of every visible emitter of
// `walked`, from where they are (no restart: the editor's Animate mode
// steps on while its timeline plays); how many steps changed a particle.
// Allocates nothing once the states are made.
export function stepTreeParticles(walked: Array<SceneNode>, steps: i32): i32 {
    let changed = 0;
    for (let k = 0; k < steps; k++) {
        if (advanceTreeParticles(walked, PARTICLE_TOOL_STEP) > 0) changed++;
    }
    return changed;
}

// The emitters of `walked` and what they hold now, into `run`.
export function countParticles(walked: Array<SceneNode>, run: ParticleRun): void {
    run.emitters = 0;
    run.emitting = 0;
    run.alive = 0;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isParticles = n instanceof CPUParticles3D;
        if (!isParticles) continue;
        const p = n as CPUParticles3D;
        run.emitters++;
        if (p.emitting) run.emitting++;
        run.alive += ensureParticles(p).alive;
    }
}
