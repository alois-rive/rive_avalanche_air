// The scripts feature of the run time (milestone 39,
// features.as FEATURE_SCRIPTS): each instance's NodeScripts, run by the
// player's ScriptRuntime (../player/runtime.as) with the run time's switches:
// classes found by bundle path (the module's generated registry's keys),
// process() and input() no longer called on a script that does not
// override them (so a scene whose scripts act only in ready() is idle),
// and the subtree a script adds at run time attached when it is added
// (SceneInstance.nodeAdded). Signals of the scene's <connection>s reach
// the target node's script here (SignalTarget).
//
// Every project carries this module and the script runtime (Build vendors
// the whole library); a scene that attaches no script does not
// install it.

import { InputEvent } from "../script";
import { SceneNode, enterScript, leaveScript } from "../tree/node";
import { ScriptRuntime } from "../player/runtime";
import { FEATURE_SCRIPTS, Feature, InstanceFeature, PHASE_SCRIPTS } from "./features";
import { SignalEvent, SignalTarget } from "./signals";
import { SceneInstance, SceneRuntime } from "./scene_runtime";

export class ScriptsFeature extends Feature {
    bit(): u32 {
        return FEATURE_SCRIPTS;
    }

    forInstance(inst: SceneInstance): InstanceFeature {
        return new ScriptsPart(inst);
    }
}

// Calls a connection's method on the target node's script.
class ScriptSignals extends SignalTarget {
    part: ScriptsPart;

    constructor(part: ScriptsPart) {
        super();
        this.part = part;
    }

    deliver(to: SceneNode, method: string, event: SignalEvent): bool {
        // (milestone 27: the node's script object, kept on it, so that a
        // signal finds it without a scan)
        const s = to.scriptObject;
        if (s == null) return false;
        // (milestone 28: a problem it pushes names `to`)
        const was = enterScript(to);
        s.signal(method, event);
        leaveScript(was);
        return true;
    }
}

// One instance's scripts.
export class ScriptsPart extends InstanceFeature {
    runtime: ScriptRuntime;
    // How many of the runtime's problems are in the instance's errors.
    private said: i32 = 0;

    constructor(inst: SceneInstance) {
        super();
        const rt = new ScriptRuntime(inst.runtime.registry);
        rt.bundleKeys = true;
        // (milestone 41: a scene loaded through hedra_engine/scene's load)
        rt.projectKeys = inst.runtime.projectKeys;
        rt.skipIdle = true;
        this.runtime = rt;
        inst.signalTarget = new ScriptSignals(this);
    }

    // The tree's scripts (made ready), or those of a subtree a script
    // added.
    attach(inst: SceneInstance, root: SceneNode): void {
        if (root === inst.tree.root) this.runtime.attach(inst.tree);
        else this.runtime.attachSubtree(root);
        this.takeProblems(inst);
    }

    // Milestone 27: a subtree is about to leave the tree (removeChild,
    // queueFree): its scripts' _exitTree, and their instances go.
    detach(inst: SceneInstance, root: SceneNode): void {
        this.runtime.detachSubtree(root);
        this.takeProblems(inst);
    }

    // A frame of the scripts (the timers, the tweens, every script that
    // still processes, the frees): the next draw shows something new when
    // anything ran. A scene with none of those is idle and costs nothing.
    advance(inst: SceneInstance, seconds: f64, phase: i32): bool {
        if (phase != PHASE_SCRIPTS || !inst.playing) return false;
        const rt = this.runtime;
        if (!rt.active()) return false;
        const changed = rt.process(<f32>seconds);
        this.takeProblems(inst);
        return changed;
    }

    // An event for the scripts that listen (none: nothing is drawn anew,
    // so a pointer moving over a scene without a listening script costs
    // nothing).
    input(inst: SceneInstance, e: InputEvent): bool {
        const rt = this.runtime;
        if (rt.listening() == 0) return false;
        const handled = rt.input(e);
        inst.touch();
        return handled;
    }

    status(inst: SceneInstance): string {
        const rt = this.runtime;
        return ",\"scripts\":" + rt.instances.length.toString()
            + ",\"ready\":" + rt.readyCalls.toString()
            + ",\"process\":" + rt.processCalls.toString();
    }

    // Milestone 49 (features.as): a scene running a script writes its data
    // (through its two_way bindings, and the events it fires).
    writesData(inst: SceneInstance): bool {
        return this.runtime.instances.length > 0;
    }

    stamp(inst: SceneInstance): i64 {
        const rt = this.runtime;
        return (<i64>rt.instances.length * 1000003 + <i64>rt.readyCalls) * 1000003 + rt.processCalls;
    }

    dispose(inst: SceneInstance): void {
        inst.signalTarget = null;
        this.runtime.dispose();
    }

    // The runtime's problems not yet in the instance's errors.
    private takeProblems(inst: SceneInstance): void {
        const ps = this.runtime.problems;
        for (let i = this.said; i < ps.length; i++) inst.fail(ps[i]);
        this.said = ps.length;
    }
}

// Adds the scripts feature to `rt` (the module's generated features.as
// calls it when the bundle's scenes attach scripts).
export function installScriptsFeature(rt: SceneRuntime): void {
    rt.install(new ScriptsFeature());
}
