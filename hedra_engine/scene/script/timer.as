// Milestone 27: the timers of a live tree (docs/formats/RSCN.md, "Timer"
// and "Scripts"): the Timer nodes in it, and the SceneTreeTimers scripts
// make with SceneTree.createTimer, both ticked by the script runtime
// (../player/runtime.as) once a frame, first in the scripts phase (before
// the tweens and every script's _process: the order is the spec's, so a
// script reads this frame's timeouts in its _process).
//
// A Timer node follows Godot's Timer: each frame its time left drops by
// the frame's seconds; when it falls below 0 it emits `timeout` (through
// the tree's host, so the scene's <connection>s, SceneNode.connect and the
// instance's takeSignals all hear it), and starts over by adding its wait
// time (one shot: stops). A wait that passes several times in one frame
// fires once that frame, as Godot's process callback does; the time still
// owed fires on the next frames.
//
// A SceneTreeTimer is Godot's SceneTree.create_timer: one count down whose
// `timeout` goes to the script method connectTimeout names. They come from
// a pool and go back to it when they fire (one shot) or are cancelled, so a
// game that makes a timer now and then allocates none once the pool holds
// enough: keep no reference to one after it fired.

import { Value } from "../value";
import { SceneNode, TimerNode, enterScript, leaveScript } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { SignalEvent } from "../runtime/signals";

// What a SceneTreeTimer's timeout hands its method (one object for all:
// it says nothing but the signal's name).
const TIMEOUT_EVENT: SignalEvent = new SignalEvent("", "timeout", Value.nil());
// The argument of a Timer node's timeout (none).
const NO_VALUE: Value = Value.nil();

export class SceneTreeTimer {
    // The seconds left until it fires.
    timeLeft: f64 = 0;
    // Whether it fires once (Godot's are always one shot), or every
    // `period` seconds until cancelled.
    oneShot: bool = true;
    period: f64 = 0;
    private target: SceneNode? = null;
    private method: string = "";
    // Counting (false once it fired as a one shot, or was cancelled: it is
    // then back in the pool).
    active: bool = false;

    // Its timeout calls `method` of `target`'s script, as a connection's
    // signal(method, event) (one target: a second call replaces it).
    connectTimeout(target: SceneNode, method: string): void {
        this.target = target;
        this.method = method;
    }

    // Stops it; it goes back to the pool at the next tick.
    cancel(): void {
        this.active = false;
    }

    // (the pool's) Starts it over.
    reset(seconds: f64, oneShot: bool): void {
        this.timeLeft = seconds;
        this.period = seconds;
        this.oneShot = oneShot;
        this.target = null;
        this.method = "";
        this.active = true;
    }

    // (TimerSet) Delivers the timeout to the connected script; a problem
    // when the target has none. A timer whose target was freed stops (a
    // repeating one counted for ever, so the scene never went idle) and
    // returns false: nothing ran.
    fire(tree: SceneTree): bool {
        const t = this.target;
        if (t == null) return true;
        if (t.freed) {
            this.active = false;
            return false;
        }
        const s = t.scriptObject;
        if (s == null) {
            tree.problem("timer: " + t.path() + " has no script to call " + this.method + " on");
            return true;
        }
        const was = enterScript(t);
        s.signal(this.method, TIMEOUT_EVENT);
        leaveScript(was);
        return true;
    }
}

export class TimerSet {
    // The Timer nodes in the live tree, in the order they entered it.
    nodes: Array<TimerNode> = [];
    // The SceneTreeTimers counting, and those free to hand out again.
    running: Array<SceneTreeTimer> = [];
    pool: Array<SceneTreeTimer> = [];
    // How many timeouts there were (nodes and scene timers): tests.
    fired: i64 = 0;
    // The Timer nodes a frame ticks, copied first (advance); kept, so that
    // a frame allocates nothing.
    private frameNodes: Array<TimerNode> = [];

    // A Timer node entered the live tree.
    addNode(t: TimerNode): void {
        if (!this.nodes.includes(t)) this.nodes.push(t);
    }

    // ... left it (it stops counting, keeping its time left).
    removeNode(t: TimerNode): void {
        const i = this.nodes.indexOf(t);
        if (i >= 0) this.nodes.splice(i, 1);
    }

    // A counting SceneTreeTimer of `seconds` (from the pool when it has
    // one).
    create(seconds: f64, oneShot: bool): SceneTreeTimer {
        const t = this.pool.length > 0 ? this.pool.pop() : new SceneTreeTimer();
        t.reset(seconds > 0 ? seconds : 0, oneShot);
        this.running.push(t);
        return t;
    }

    // Whether anything counts (a Timer node started and not paused, or a
    // SceneTreeTimer): the run time has work each frame.
    busy(): bool {
        if (this.running.length > 0) return true;
        for (let i = 0; i < this.nodes.length; i++) {
            const t = unchecked(this.nodes[i]);
            if (!t.isStopped() && !t.paused) return true;
        }
        return false;
    }

    // One frame of `dt` seconds: the Timer nodes, then the SceneTreeTimers
    // made before this frame. Returns whether one fired. Allocates nothing
    // but what a timeout's listeners do.
    advance(tree: SceneTree, dt: f64): bool {
        let any = false;
        // (counted before the Timer nodes fire: a SceneTreeTimer a Timer's
        // timeout makes counts from the next frame, as in Godot)
        const m = this.running.length;
        // (copied first: a timeout's script may add or remove timers, and
        // removing one spliced `nodes` under the loop, so the next Timer
        // missed a frame; one removed this frame counts no more)
        const list = this.frameNodes;
        list.length = 0;
        for (let i = 0; i < this.nodes.length; i++) list.push(unchecked(this.nodes[i]));
        for (let i = 0; i < list.length; i++) {
            const t = unchecked(list[i]);
            if (t.liveTree !== tree) continue;
            if (t.isStopped() || t.paused) continue;
            t.timeLeft -= dt;
            if (t.timeLeft < 0) {
                if (t.oneShot) t.stop();
                else t.timeLeft += t.waitTime;
                this.fired++;
                any = true;
                tree.emitSignal(t, "timeout", NO_VALUE);
            }
        }
        list.length = 0;
        for (let i = 0; i < m && i < this.running.length; i++) {
            const t = unchecked(this.running[i]);
            if (!t.active) continue;
            t.timeLeft -= dt;
            if (t.timeLeft > 0) continue;
            if (t.oneShot) t.active = false;
            else t.timeLeft += t.period;
            if (!t.fire(tree)) continue;
            this.fired++;
            any = true;
        }
        this.recycle();
        return any;
    }

    // Moves the timers that are no longer counting to the pool (in place:
    // allocates nothing once the pool's storage is grown).
    private recycle(): void {
        const r = this.running;
        let k = 0;
        for (let i = 0; i < r.length; i++) {
            const t = unchecked(r[i]);
            if (t.active) {
                r[k++] = t;
            } else {
                this.pool.push(t);
            }
        }
        r.length = k;
    }
}
