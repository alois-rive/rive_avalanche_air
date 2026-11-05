// The navigation feature of the run time (milestone 63, features.as
// FEATURE_NAVIGATION; docs/engine/NAVIGATION.md, docs/cli/BUILD.md section
// 18): each instance's navigation (../navigation/sim.as NavigationSim), its
// map put on the tree for scripts (SceneTree.world.navigationMap), stepped
// every frame by the frame's seconds in PHASE_SCRIPTS (installed after the
// scripts, the particles and the sounds, so a script that sets a target or
// a velocity is seen this frame, and before the interaction world's step,
// so areas see where the agents went), its signals emitted through the
// instance (connections, scripts, `signal:<name>` bindings: a view model
// trigger, which the host artboard's state machine turns into a Rive
// event). Its status part: `,"navigation":{"agents":N,"moving":M,
// "reached":R}` when the scene has agents (written when it changes). A
// scene without navigation nodes does not install it; idle, walking and
// avoiding allocate nothing.
//
// How:
//   - the map is synced when the simulation is made, before the scripts'
//     _ready (the instance attaches this feature right after the
//     interaction world), so that _ready's queries see the regions;
//   - the simulation is made for an instance whose tree holds one of the
//     four navigation nodes (a NavigationRegion3D, NavigationAgent3D,
//     NavigationObstacle3D or NavigationLink3D), when its tree is made or
//     when a script adds a subtree holding one; a scene with none keeps
//     the base map (it answers nothing) and costs a test a frame;
//   - the map's settings are the project's (its hedra.yaml's
//     navigation/3d/* lines, which the built project passes to
//     registerProject with the screen quality's: ./projects.as `settings`),
//     read once for the instance;
//   - the instance's seconds are already its speed's, and 0 while it does
//     not play: nothing moves then (Godot's physics does not step while
//     the tree is paused). The step's answer (an actor moved, a signal, an
//     output changed) is the frame's "changed";
//   - Play's --navigation (SceneInstance.debugNavigation), Godot's Debug >
//     Visible Navigation: each plan draws the map's lines and the agents'
//     (../navigation/lines.as) into the frame's world lines;
//   - writesData is false: the bindings feature writes the agents' bound
//     outputs (current_speed, distance_to_target, is_target_reached,
//     is_navigation_finished) and fires their signals' triggers.

import { FEATURE_NAVIGATION, Feature, InstanceFeature, PHASE_SCRIPTS } from "./features";
import { SceneInstance, SceneRuntime } from "./scene_runtime";
import { projectNamed } from "./projects";
import { SceneFrame } from "../render/adapter";
import {
    NavigationAgent3D, NavigationLink3D, NavigationObstacle3D, NavigationRegion3D, SceneNode,
} from "../tree/node";
import { NavigationSim } from "../navigation/sim";
import { NavigationSettings } from "../navigation/settings";
import { navigationAgentLinesInto, navigationMapLinesInto } from "../navigation/lines";
import { installAgentLogic } from "../navigation/agent";

export class NavigationFeature extends Feature {
    bit(): u32 {
        return FEATURE_NAVIGATION;
    }

    forInstance(inst: SceneInstance): InstanceFeature {
        return new NavigationPart();
    }
}

// Whether `root`'s subtree holds a navigation node.
export function holdsNavigation(root: SceneNode): bool {
    const isNav = root instanceof NavigationRegion3D || root instanceof NavigationAgent3D
        || root instanceof NavigationObstacle3D || root instanceof NavigationLink3D;
    if (isNav) return true;
    const c = root.children;
    for (let i = 0; i < c.length; i++) if (holdsNavigation(unchecked(c[i]))) return true;
    return false;
}

// The navigation settings of the project `inst` was loaded from (Godot's
// defaults for what it does not set, or for an instance of no project):
// the registered project's, parsed once for every instance of it.
function projectSettings(inst: SceneInstance): NavigationSettings? {
    const p = projectNamed(inst.runtime.shaderProject);
    return p != null ? p.navigationSettings() : null;
}

// One instance's navigation.
export class NavigationPart extends InstanceFeature {
    // Made once the tree holds a navigation node (null before: no cost).
    sim: NavigationSim? = null;
    // The status's counts as last written.
    private agents: i32 = 0;
    private moving: i32 = 0;
    private reached: i32 = 0;

    attach(inst: SceneInstance, root: SceneNode): void {
        if (this.sim != null || !holdsNavigation(root)) return;
        const sim = new NavigationSim(projectSettings(inst));
        this.sim = sim;
        inst.tree.world.navigationMap = sim.map;
        installAgentLogic();
        // (synced now, before the scripts' _ready: the instance attaches
        // the navigation before them, so a query in _ready answers from
        // the scene's regions rather than an empty map; the first step's
        // sync then finds nothing changed)
        sim.map.sync(inst.tree);
    }

    advance(inst: SceneInstance, seconds: f64, phase: i32): bool {
        if (phase != PHASE_SCRIPTS) return false;
        const sim = this.sim;
        if (sim == null) return false;
        const changed = sim.step(inst.tree, seconds);
        const st = sim.stats;
        this.agents = st.agents;
        this.moving = st.moving;
        this.reached = st.reached;
        return changed;
    }

    // Play's --navigation: the map's and the agents' lines.
    afterPlan(inst: SceneInstance, sf: SceneFrame): void {
        const sim = this.sim;
        if (!inst.debugNavigation || sim == null) return;
        const lines = sf.frame.worldLines;
        const at = navigationMapLinesInto(sim.map, 1, lines, lines.length);
        navigationAgentLinesInto(inst.tree, 1, lines, at);
    }

    status(inst: SceneInstance): string {
        if (this.sim == null || this.agents == 0) return "";
        return ",\"navigation\":{\"agents\":" + this.agents.toString() + ",\"moving\":" + this.moving.toString()
            + ",\"reached\":" + this.reached.toString() + "}";
    }

    stamp(inst: SceneInstance): i64 {
        if (this.sim == null || this.agents == 0) return 0;
        let m: i64 = this.agents;
        m = m * 1009 + this.moving;
        m = m * 1009 + this.reached;
        return m;
    }

    dispose(inst: SceneInstance): void {
        this.sim = null;
    }
}

// Adds the navigation feature to `rt` (newSceneRuntime(), and the module's
// generated features.as when the bundle's scenes use it).
export function installNavigationFeature(rt: SceneRuntime): void {
    rt.install(new NavigationFeature());
}
