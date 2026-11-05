// The tools' clock for navigation (milestone 63): what `hedra render
// --time`, `--state-machine`, `inspect --navmesh --time` and the editor's
// Animate mode show, a scene's agents from their start, stepped in steps of
// 1/60 s (Rive's 60 frames a second, the particles' clock's steps:
// ../particles/state.as PARTICLE_TOOL_STEP), the same steps a built project
// at 60 frames a second takes, so the picture is the one it shows at that
// time. A hook may change the tree before each step (the CLI samples a
// timeline or runs a state machine's frame there, so a bound
// target_position moves as it does in Play).
//
// Each run starts from the tree as loaded: every agent's fields read again
// from its properties (what the file, a binding or a key wrote: a target
// a hook or a script set in the last run is forgotten), its state as a new
// agent's (its target submitted when its file sets one, as Godot's setter
// does at load), its current_speed 0, and each actor put back where it was
// before the clock's first run on it (the clock keeps that transform on the
// agent's state, and the one its run left the actor at: an actor found
// elsewhere since was moved by someone else, an edit, and where it is now
// is its start). So `navigationAtTime(tree, 2)` twice gives the same
// positions, and 0 s leaves the tree as loaded (the map synced, nothing
// moved). The simulation of the last run is kept for the same tree and
// settings (the editor's scrubbing runs the clock again and again).

import { MAT4_IDENTITY, Mat4 } from "../../base/vecmath";
import { SceneTree } from "../tree/tree";
import { NavigationAgent3D } from "../tree/node";
import { PARTICLE_TOOL_STEP } from "../particles/state";
import { toolSteps } from "../particles/clock";
import { installAgentLogic } from "./agent";
import { NavigationSettings } from "./settings";
import { NavigationSim } from "./sim";

export abstract class NavigationStepHook {
    abstract beforeStep(t: f64, step: i32): void;
}

// What a run came to.
export class NavigationRun {
    agents: i32 = 0;
    moving: i32 = 0;
    reached: i32 = 0;
    steps: i32 = 0;
    time: f64 = 0;
    // The simulation it ran (its map, as of the last step).
    sim: NavigationSim? = null;
}

// The last run's simulation, its tree and its settings.
let lastSim: NavigationSim? = null;
let lastTree: SceneTree? = null;
const lastSettings = new NavigationSettings();
const DEFAULTS = new NavigationSettings();

// Whether two transforms are the same, number for number.
function sameTransform(a: Mat4, b: Mat4): bool {
    return a.xAxis.x == b.xAxis.x && a.xAxis.y == b.xAxis.y && a.xAxis.z == b.xAxis.z && a.xAxis.w == b.xAxis.w
        && a.yAxis.x == b.yAxis.x && a.yAxis.y == b.yAxis.y && a.yAxis.z == b.yAxis.z && a.yAxis.w == b.yAxis.w
        && a.zAxis.x == b.zAxis.x && a.zAxis.y == b.zAxis.y && a.zAxis.z == b.zAxis.z && a.zAxis.w == b.zAxis.w
        && a.wAxis.x == b.wAxis.x && a.wAxis.y == b.wAxis.y && a.wAxis.z == b.wAxis.z && a.wAxis.w == b.wAxis.w;
}

// `a` and its actor back to the start of a run (see the header).
function startAgent(a: NavigationAgent3D): void {
    const s = a.nav;
    const actor = a.actor();
    if (actor != null) {
        if (s.toolsActor === actor && sameTransform(actor.local, s.toolsEnd)) {
            actor.local = s.toolsStart;
        } else {
            s.toolsActor = actor;
            s.toolsStart = actor.local;
        }
        s.toolsEnd = MAT4_IDENTITY;
    }
    // (its state as a new agent's first, then its fields from its
    // properties again: a target a hook or a script set in the last run is
    // not the file's, and the file's target and velocity are submitted
    // again, as at load; the other way round, the restart would drop the
    // velocity just submitted)
    s.restart(a.getProp("target_position") != null);
    a.readFieldsAsLoaded();
    a.currentSpeed = 0;
}

// `tree`'s agents from their start, stepped `seconds` on the tools' clock
// (`hook`, when given, before each step), with the project's `settings`.
// A tree without a NavigationAgent3D is left as it is (0 agents).
export function navigationAtTime(tree: SceneTree, seconds: f64, settings: NavigationSettings? = null,
    hook: NavigationStepHook? = null): NavigationRun {
    const run = new NavigationRun();
    const walked = tree.walk();
    const agents = new Array<NavigationAgent3D>();
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isAgent = n instanceof NavigationAgent3D;
        if (isAgent) agents.push(n as NavigationAgent3D);
    }
    if (agents.length == 0) return run;
    const want = settings != null ? settings : DEFAULTS;
    let sim = lastSim;
    if (sim == null || lastTree !== tree || !lastSettings.equals(want)) {
        sim = new NavigationSim(want);
        lastSim = sim;
        lastTree = tree;
        lastSettings.copyFrom(want);
    } else {
        sim.reset();
    }
    // (after the reset, which restarts the last run's agents: the agents
    // started here keep the velocity their fields submit)
    for (let i = 0; i < agents.length; i++) startAgent(agents[i]);
    installAgentLogic();
    const steps = toolSteps(seconds);
    for (let k = 0; k < steps; k++) {
        if (hook != null) hook.beforeStep(<f64>k * PARTICLE_TOOL_STEP, k);
        sim.step(tree, PARTICLE_TOOL_STEP);
    }
    // (no step: the map synced and the agents counted all the same)
    if (steps == 0) sim.step(tree, 0);
    for (let i = 0; i < agents.length; i++) {
        const a = agents[i];
        const actor = a.actor();
        if (actor != null && a.nav.toolsActor === actor) a.nav.toolsEnd = actor.local;
    }
    const st = sim.stats;
    run.agents = st.agents;
    run.moving = st.moving;
    run.reached = st.reached;
    run.steps = steps;
    run.time = <f64>steps * PARTICLE_TOOL_STEP;
    run.sim = sim;
    return run;
}
