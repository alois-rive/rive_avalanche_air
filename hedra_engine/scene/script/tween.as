// Milestone 27: Godot's Tween (docs/formats/RSCN.md, "Scripts"): a script
// makes one with createTween() (bound to its node: it dies when the node
// leaves the tree) or SceneTree.createTween(), and appends steps:
//
//   const t = this.createTween();
//   t.tweenProperty(crate, "position", Value.vector3(0, 0, 0), 0.6)
//       .from(Value.vector3(0, 3, 0)).setTrans(TransitionType.Bounce).setEase(EaseType.Out);
//   t.parallel().tweenProperty(crate, "scale", Value.vector3(1, 1, 1), 0.6);
//   t.tweenCallback(this.node, "landed");         // the script's call("landed", nil)
//   t.connectFinished(this.node, "done");         // likewise, once it all finished
//
// The semantics are Godot 4's Tween.step: tweeners run in steps, one after
// the other (setParallel, parallel() and chain() put tweeners in the same
// step); time left over when a step ends goes on to the next within the
// frame; setLoops(n) runs the steps n times (0: for ever); setSpeedScale
// scales the frame's seconds; pause/play/stop/kill as Godot's. A property
// tweener captures its start value when it starts (after its delay), unless
// from() or fromCurrent() gave one; asRelative() adds the value to it.
//
// Properties are the binding targets (../binding/targets.as: what a
// <binding> drives, set by ../binding/apply.as, so a tween moves what a
// binding moves by the same code): a number target ("position:y",
// "light_energy", "scale" as a uniform scale, ...) takes an int or float,
// a boolean one (visible, current) a bool, an enum one
// (render_target_update_mode) an int, its index, a colour one a Color;
// and the whole vectors position, rotation, rotation_degrees and scale
// take a Vector3, written as their three components. Numbers, vectors and
// colours interpolate component-wise; a bool and an enum switch at the
// end. Any other name, or a value of another kind, is a problem of the
// instance ("Crate: tween: no property size") and the tweener does
// nothing.
//
// The tree's TweenSet steps the tweens in the scripts phase, after the
// timers and before every script's _process. A running tween allocates
// nothing a frame (a typed property, light_energy say, makes its new Value
// as a binding's write does; a transform target makes none). A finished or
// killed tween's tweeners go back to a pool that the next tweens take from;
// the Tween itself is a new small object per createTween, so that a script
// that keeps one after it finished can never reach another node's tween
// through it (kill() on it does nothing).

import { MAT4_NAN, Vec4 } from "../../base/vecmath";
import { Value, ValueKind } from "../value";
import { SceneNode, enterScript, leaveScript } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { BindKind, BindingTarget, findBindingTarget } from "../binding/targets";
import { nodeBindingTarget } from "../binding/shader_targets";
import { BindingPose, readTarget, readTargetColor, writeTarget, writeTargetColor } from "../binding/apply";
import { BoundValue } from "../binding/values";
import { EaseType, TransitionType, interpolate } from "./easing";

export { EaseType, TransitionType } from "./easing";

// What a tweener does.
const KIND_PROPERTY: i32 = 0;
const KIND_INTERVAL: i32 = 1;
const KIND_CALLBACK: i32 = 2;

// The value a property tweener moves.
const VALUE_NUMBER: i32 = 0;
const VALUE_BOOL: i32 = 1;
const VALUE_COLOR: i32 = 2;
const VALUE_VECTOR: i32 = 3;
// An int enum (a SubViewport's render_target_update_mode, ...): its index,
// switched at the end as a bool.
const VALUE_ENUM: i32 = 4;

// A tweener's trans and ease before it starts: the tween's then.
const UNSET: i32 = -1;

// The argument a callback gets (none).
const NO_VALUE: Value = Value.nil();

// One step of a tween: a property it moves, an interval it waits or a
// method it calls (Godot's PropertyTweener, IntervalTweener and
// CallbackTweener in one class, so that one pool serves all three).
export class PropertyTweener {
    tween: Tween? = null;
    kind: i32 = KIND_PROPERTY;
    // Which of the tween's steps it is in.
    step: i32 = 0;
    duration: f64 = 0;
    delay: f64 = 0;
    elapsed: f64 = 0;
    finished: bool = false;
    // Inert: its property was not found; it ends at once.
    inert: bool = false;
    trans: i32 = UNSET;
    ease: i32 = UNSET;
    // The property tweener's node, value kind and targets (a vector's
    // three components, else t0 alone).
    node: SceneNode? = null;
    valueKind: i32 = VALUE_NUMBER;
    t0: BindingTarget? = null;
    t1: BindingTarget? = null;
    t2: BindingTarget? = null;
    // The value it goes to (or by, relative), where it starts, and how far
    // it goes, component by component; `fixedStart`: from() or
    // fromCurrent() set the start.
    to: StaticArray<f64> = new StaticArray<f64>(4);
    start: StaticArray<f64> = new StaticArray<f64>(4);
    delta: StaticArray<f64> = new StaticArray<f64>(4);
    fixedStart: bool = false;
    relative: bool = false;
    captured: bool = false;
    // The callback tweener's target and method.
    method: string = "";
    // A view model value and a pose, kept for the writes (a frame
    // allocates nothing for them; ../binding/apply.as BindingPose).
    private bound: BoundValue = new BoundValue();
    private pose: BindingPose = new BindingPose();

    // Starts from `v` (of the property's kind) instead of the value when
    // the tweener starts.
    from(v: Value): PropertyTweener {
        if (this.kind != KIND_PROPERTY || this.inert) return this;
        if (!this.valueOf(v, this.start)) {
            this.problem("tween: from(" + v.kindName() + ") does not fit " + this.propertyName());
            return this;
        }
        this.fixedStart = true;
        return this;
    }

    // Starts from the value the property has now, rather than when the
    // tweener starts.
    fromCurrent(): PropertyTweener {
        if (this.kind != KIND_PROPERTY || this.inert) return this;
        this.read(this.start);
        this.fixedStart = true;
        return this;
    }

    // The value given is added to the start value.
    asRelative(): PropertyTweener {
        this.relative = true;
        return this;
    }

    setTrans(t: TransitionType): PropertyTweener {
        this.trans = <i32>t;
        return this;
    }

    setEase(e: EaseType): PropertyTweener {
        this.ease = <i32>e;
        return this;
    }

    // Waits `seconds` before it starts (a property tweener captures its
    // start value then).
    setDelay(seconds: f64): PropertyTweener {
        this.delay = seconds > 0 ? seconds : 0;
        return this;
    }

    // (the pool's) Forgets everything.
    clear(): void {
        this.tween = null;
        this.kind = KIND_PROPERTY;
        this.step = 0;
        this.duration = 0;
        this.delay = 0;
        this.elapsed = 0;
        this.finished = false;
        this.inert = false;
        this.trans = UNSET;
        this.ease = UNSET;
        this.node = null;
        this.valueKind = VALUE_NUMBER;
        this.t0 = null;
        this.t1 = null;
        this.t2 = null;
        this.fixedStart = false;
        this.relative = false;
        this.captured = false;
        this.method = "";
    }

    // Sets up a property tweener of `node`'s `property` to `to`; a problem
    // (and an inert tweener) when the node has no such target, or `to` is
    // not of its kind.
    setProperty(node: SceneNode, property: string, to: Value, duration: f64): void {
        this.kind = KIND_PROPERTY;
        this.node = node;
        this.duration = duration > 0 ? duration : 0;
        const cls = node.schemaClass();
        if (to.kind == ValueKind.Vector3 && isVector(property)) {
            this.valueKind = VALUE_VECTOR;
            this.t0 = findBindingTarget(cls, property + ":x");
            this.t1 = findBindingTarget(cls, property + ":y");
            this.t2 = findBindingTarget(cls, property + ":z");
        } else {
            // A signal ("signal:<name>") is a binding target with no value
            // to tween: the tweener refuses it as an unknown property.
            // (a shader parameter of its kind: the node's material says)
            const found = nodeBindingTarget(node, property);
            const t = found != null && found.kind == BindKind.Trigger ? null : found;
            this.t0 = t;
            if (t != null) {
                const k = t.kind;
                this.valueKind = k == BindKind.Number ? VALUE_NUMBER : k == BindKind.Boolean ? VALUE_BOOL
                    : k == BindKind.Enum ? VALUE_ENUM : VALUE_COLOR;
            }
        }
        this.method = property;
        const probe = new StaticArray<f64>(4);
        if (this.t0 == null || !this.read(probe)) {
            this.inert = true;
            this.problem("tween: no property " + property);
            return;
        }
        if (!this.valueOf(to, this.to)) {
            this.inert = true;
            this.problem("tween: " + property + " does not take " + to.kindName());
        }
    }

    // The property's name (setProperty keeps it in `method`).
    private propertyName(): string {
        return this.method;
    }

    // The components of `v` into `out`, when `v` is of the property's
    // kind.
    private valueOf(v: Value, out: StaticArray<f64>): bool {
        const k = this.valueKind;
        if (k == VALUE_NUMBER) {
            if (!v.isNumber()) return false;
            out[0] = v.asF64();
            return true;
        }
        if (k == VALUE_BOOL) {
            if (v.kind != ValueKind.Bool) return false;
            out[0] = v.b ? 1 : 0;
            return true;
        }
        if (k == VALUE_ENUM) {
            // (an index: a whole number; one the enum lacks is refused
            // when written, as a binding's)
            if (!v.isNumber()) return false;
            const x = v.asF64();
            if (x != Math.floor(x)) return false;
            out[0] = x;
            return true;
        }
        const n = k == VALUE_COLOR ? 4 : 3;
        if (k == VALUE_COLOR && v.kind != ValueKind.Color) return false;
        if (k == VALUE_VECTOR && v.kind != ValueKind.Vector3) return false;
        for (let i = 0; i < n; i++) out[i] = i < v.n.length ? v.n[i] : 0;
        return true;
    }

    // Reads the property now into `out`; false when the node has nothing
    // there.
    private read(out: StaticArray<f64>): bool {
        const node = this.node;
        const t0 = this.t0;
        if (node == null || t0 == null) return false;
        const k = this.valueKind;
        if (k == VALUE_COLOR) {
            const c = readTargetColor(node, t0);
            if (!isFinite(c.x)) return false;
            out[0] = <f64>c.x;
            out[1] = <f64>c.y;
            out[2] = <f64>c.z;
            out[3] = <f64>c.w;
            return true;
        }
        const b = this.bound;
        if (!readTarget(node, t0, b, this.pose)) return false;
        // (an enum reads as its index in `number`)
        out[0] = k == VALUE_BOOL ? (b.boolean ? 1 : 0) : b.number;
        if (k != VALUE_VECTOR) return true;
        const t1 = this.t1;
        const t2 = this.t2;
        if (t1 == null || t2 == null || !readTarget(node, t1, b, this.pose)) return false;
        out[1] = b.number;
        if (!readTarget(node, t2, b, this.pose)) return false;
        out[2] = b.number;
        return true;
    }

    // Writes the value at `time` seconds (of `duration`) to the property.
    private write(time: f64): void {
        const node = this.node;
        const tw = this.tween;
        const t0 = this.t0;
        if (node == null || tw == null || t0 == null) return;
        const tree = tw.tree;
        const trans = <TransitionType>(this.trans == UNSET ? <i32>tw.trans : this.trans);
        const ease = <EaseType>(this.ease == UNSET ? <i32>tw.ease : this.ease);
        const d = this.duration;
        const end = time >= d;
        const k = this.valueKind;
        const b = this.bound;
        if (k == VALUE_BOOL) {
            // (a bool switches at the end)
            b.setBoolean(end ? this.start[0] + this.delta[0] != 0 : this.start[0] != 0);
            writeTarget(tree, node, t0, b, this.pose);
            return;
        }
        if (k == VALUE_ENUM) {
            // (an enum switches at the end, as a bool; written only when it
            // changes, since writing UPDATE_ONCE again takes one more
            // picture)
            const want = end ? this.start[0] + this.delta[0] : this.start[0];
            if (readTarget(node, t0, b, this.pose) && b.number == want) return;
            b.setNumber(want);
            writeTarget(tree, node, t0, b, this.pose);
            return;
        }
        const x = end ? this.start[0] + this.delta[0] : interpolate(trans, ease, time, this.start[0], this.delta[0], d);
        if (k == VALUE_NUMBER) {
            b.setNumber(x);
            writeTarget(tree, node, t0, b, this.pose);
            return;
        }
        const y = end ? this.start[1] + this.delta[1] : interpolate(trans, ease, time, this.start[1], this.delta[1], d);
        const z = end ? this.start[2] + this.delta[2] : interpolate(trans, ease, time, this.start[2], this.delta[2], d);
        if (k == VALUE_COLOR) {
            const w = end ? this.start[3] + this.delta[3] : interpolate(trans, ease, time, this.start[3], this.delta[3], d);
            writeTargetColor(tree, node, t0, Vec4(<f32>x, <f32>y, <f32>z, <f32>w));
            return;
        }
        const t1 = this.t1;
        const t2 = this.t2;
        if (t1 == null || t2 == null) return;
        b.setNumber(x);
        writeTarget(tree, node, t0, b, this.pose);
        b.setNumber(y);
        writeTarget(tree, node, t1, b, this.pose);
        b.setNumber(z);
        writeTarget(tree, node, t2, b, this.pose);
    }

    // The tweener's step begins (again, on a loop).
    begin(): void {
        this.elapsed = 0;
        this.finished = false;
        this.captured = false;
        // (the pose reads the node's matrix afresh: a script may have
        // turned it since)
        this.pose.local = MAT4_NAN;
    }

    // Godot's Tweener.step: takes `delta` seconds; returns whether it is
    // still running, and leaves in `left[0]` the seconds it did not use
    // (0 while it runs).
    advance(delta: f64, left: StaticArray<f64>): bool {
        if (this.finished) {
            left[0] = delta;
            return false;
        }
        this.elapsed += delta;
        if (this.kind == KIND_INTERVAL) {
            if (this.elapsed < this.duration) {
                left[0] = 0;
                return true;
            }
            this.finished = true;
            left[0] = this.elapsed - this.duration;
            return false;
        }
        if (this.elapsed < this.delay) {
            left[0] = 0;
            return true;
        }
        if (this.kind == KIND_CALLBACK) {
            this.finished = true;
            left[0] = this.elapsed - this.delay;
            this.callBack();
            return false;
        }
        const node = this.node;
        if (this.inert || node == null || node.freed) {
            // (Godot aborts a tweener whose object was freed)
            this.finished = true;
            left[0] = this.elapsed - this.delay;
            return false;
        }
        if (!this.captured) this.capture();
        const time = this.elapsed - this.delay;
        if (time < this.duration) {
            this.write(time);
            left[0] = 0;
            return true;
        }
        this.write(this.duration);
        this.finished = true;
        left[0] = time - this.duration;
        return false;
    }

    // Takes the start value (unless from() gave one) and the distance to
    // go.
    private capture(): void {
        this.captured = true;
        if (!this.fixedStart) this.read(this.start);
        const n = this.valueKind == VALUE_COLOR ? 4 : this.valueKind == VALUE_VECTOR ? 3 : 1;
        for (let i = 0; i < n; i++) {
            if (this.valueKind == VALUE_BOOL) {
                // (relative or not, a bool goes to the value given)
                this.delta[i] = this.to[i] - this.start[i];
            } else {
                const fin = this.relative ? this.start[i] + this.to[i] : this.to[i];
                this.delta[i] = fin - this.start[i];
            }
        }
    }

    private callBack(): void {
        const target = this.node;
        const tw = this.tween;
        if (target == null || target.freed || tw == null) return;
        const s = target.scriptObject;
        if (s == null) {
            tw.tree.problem(target.path() + ": tween: no script to call " + this.method + " on");
            return;
        }
        const was = enterScript(target);
        s.call(this.method, NO_VALUE);
        leaveScript(was);
    }

    private problem(message: string): void {
        const tw = this.tween;
        const node = this.node;
        if (tw != null) tw.tree.problem((node != null ? node.path() + ": " : "") + message);
    }

    // (Tween) Sets up an interval of `seconds`.
    setInterval(seconds: f64): void {
        this.kind = KIND_INTERVAL;
        this.duration = seconds > 0 ? seconds : 0;
    }

    // (Tween) Sets up a call of `method` on `target`'s script.
    setCallback(target: SceneNode, method: string): void {
        this.kind = KIND_CALLBACK;
        this.node = target;
        this.method = method;
    }
}

// Whether `p` names a whole vector a Vector3 tweens.
function isVector(p: string): bool {
    return p == "position" || p == "rotation" || p == "rotation_degrees" || p == "scale";
}

export class Tween {
    tree: SceneTree;
    home: TweenSet;
    // Every tweener, in the order appended; each knows its step.
    tweeners: Array<PropertyTweener> = [];
    steps: i32 = 0;
    current: i32 = 0;
    loops: i32 = 1;
    loopsDone: i32 = 0;
    speed: f64 = 1;
    trans: TransitionType = TransitionType.Linear;
    ease: EaseType = EaseType.InOut;
    // The node it is bound to (createTween of a script: it dies when the
    // node leaves the tree, and waits while the node is not in one).
    bound: SceneNode? = null;
    private parallelAll: bool = false;
    private joinNext: bool = false;
    private chainNext: bool = false;
    private running: bool = true;
    private started: bool = false;
    dead: bool = false;
    private finishedTarget: SceneNode? = null;
    private finishedMethod: string = "";
    // Whether the last loop took no time (two in a row: an endless loop).
    private idleLoop: bool = false;
    private left: StaticArray<f64> = new StaticArray<f64>(1);

    constructor(tree: SceneTree, home: TweenSet) {
        this.tree = tree;
        this.home = home;
    }

    // Moves `node`'s `property` to `to` over `duration` seconds (see the
    // header for what may be tweened).
    tweenProperty(node: SceneNode, property: string, to: Value, duration: f64): PropertyTweener {
        const tw = this.append();
        tw.setProperty(node, property, to, duration);
        return tw;
    }

    // Waits `seconds`.
    tweenInterval(seconds: f64): Tween {
        this.append().setInterval(seconds);
        return this;
    }

    // Calls `method` of `target`'s script (its call(method, nil)).
    tweenCallback(target: SceneNode, method: string): Tween {
        this.append().setCallback(target, method);
        return this;
    }

    // Every tweener appended from now on runs with the one before (true),
    // or after it (false).
    setParallel(on: bool = true): Tween {
        this.parallelAll = on;
        return this;
    }

    // The next tweener runs with the one before.
    parallel(): Tween {
        this.joinNext = true;
        return this;
    }

    // The next tweener runs after the one before, even with setParallel.
    chain(): Tween {
        this.chainNext = true;
        return this;
    }

    // Runs the steps `n` times (0: for ever).
    setLoops(n: i32 = 0): Tween {
        this.loops = n;
        return this;
    }

    // The transition and ease of the tweeners that set none.
    setTrans(t: TransitionType): Tween {
        this.trans = t;
        return this;
    }

    setEase(e: EaseType): Tween {
        this.ease = e;
        return this;
    }

    // Scales the seconds the tween takes each frame.
    setSpeedScale(s: f64): Tween {
        this.speed = s;
        return this;
    }

    // Binds it to `node` (as a script's createTween does).
    bindNode(node: SceneNode): Tween {
        this.bound = node;
        return this;
    }

    // When the tween finished: calls `method` of `target`'s script.
    connectFinished(target: SceneNode, method: string): Tween {
        this.finishedTarget = target;
        this.finishedMethod = method;
        return this;
    }

    play(): void {
        if (!this.dead) this.running = true;
    }

    pause(): void {
        this.running = false;
    }

    // Stops it and goes back to its start: play() runs it from the
    // beginning (Godot's stop()).
    stop(): void {
        this.running = false;
        this.started = false;
    }

    // Ends it for good; its tweeners go back to the pool.
    kill(): void {
        this.dead = true;
        this.running = false;
    }

    isRunning(): bool {
        return this.running && !this.dead;
    }

    isValid(): bool {
        return !this.dead;
    }

    // A new tweener in the right step.
    private append(): PropertyTweener {
        const tw = this.home.takeTweener();
        tw.tween = this;
        const join = !this.chainNext && (this.parallelAll || this.joinNext) && this.steps > 0;
        if (join) {
            tw.step = this.steps - 1;
        } else {
            tw.step = this.steps;
            this.steps++;
        }
        this.joinNext = false;
        this.chainNext = false;
        if (!this.dead) this.tweeners.push(tw);
        return tw;
    }

    // Begins step `s`'s tweeners.
    private begin(s: i32): void {
        for (let i = 0; i < this.tweeners.length; i++) {
            const tw = unchecked(this.tweeners[i]);
            if (tw.step == s) tw.begin();
        }
    }

    // Godot's Tween.step: one frame of `dt` seconds; returns whether a
    // tweener ran (something may have moved).
    advance(dt: f64): bool {
        if (this.dead || !this.running) return false;
        const b = this.bound;
        if (b != null) {
            if (b.freed) {
                this.kill();
                return false;
            }
            // (bound to a node outside the tree: it waits)
            if (b.liveTree == null) return false;
        }
        if (this.steps == 0) {
            this.tree.problem("tween: started with nothing to do");
            this.kill();
            return false;
        }
        if (!this.started) {
            this.started = true;
            this.current = 0;
            this.loopsDone = 0;
            this.idleLoop = false;
            this.begin(0);
        }
        let rem = dt * this.speed;
        const loopStart = rem;
        let ran = false;
        const left = this.left;
        while (rem > 0 && this.running && !this.dead) {
            let stepLeft = rem;
            let active = false;
            for (let i = 0; i < this.tweeners.length; i++) {
                const tw = unchecked(this.tweeners[i]);
                if (tw.step != this.current) continue;
                ran = true;
                if (tw.advance(rem, left)) active = true;
                if (left[0] < stepLeft) stepLeft = left[0];
            }
            rem = stepLeft;
            if (active) continue;
            this.current++;
            if (this.current < this.steps) {
                this.begin(this.current);
                continue;
            }
            this.loopsDone++;
            if (this.loops > 0 && this.loopsDone >= this.loops) {
                this.finish();
                break;
            }
            // Another loop; two that take no time in a row would loop for
            // ever within the frame (Godot's "infinite loop detected").
            if (this.loops <= 0 && rem == loopStart) {
                if (this.idleLoop) {
                    this.tree.problem("tween: an endless loop (every step takes no time): killed");
                    this.kill();
                    break;
                }
                this.idleLoop = true;
            } else {
                this.idleLoop = false;
            }
            this.current = 0;
            this.begin(0);
        }
        return ran;
    }

    private finish(): void {
        this.running = false;
        this.dead = true;
        const t = this.finishedTarget;
        if (t == null || t.freed) return;
        const s = t.scriptObject;
        if (s == null) {
            this.tree.problem(t.path() + ": tween: no script to call " + this.finishedMethod + " on");
            return;
        }
        const was = enterScript(t);
        s.call(this.finishedMethod, NO_VALUE);
        leaveScript(was);
    }

    // (TweenSet) Gives the tweeners back.
    release(): void {
        for (let i = 0; i < this.tweeners.length; i++) this.home.giveTweener(unchecked(this.tweeners[i]));
        this.tweeners.length = 0;
        this.steps = 0;
    }
}

// The tweens of a live tree and the pool of their tweeners.
export class TweenSet {
    tree: SceneTree;
    tweens: Array<Tween> = [];
    private pool: Array<PropertyTweener> = [];
    // How many tweeners were ever made (the pool's tests).
    made: i32 = 0;

    constructor(tree: SceneTree) {
        this.tree = tree;
    }

    create(): Tween {
        const t = new Tween(this.tree, this);
        this.tweens.push(t);
        return t;
    }

    takeTweener(): PropertyTweener {
        if (this.pool.length > 0) return this.pool.pop();
        this.made++;
        return new PropertyTweener();
    }

    giveTweener(tw: PropertyTweener): void {
        tw.clear();
        this.pool.push(tw);
    }

    // How many tweeners wait in the pool.
    get pooled(): i32 {
        return this.pool.length;
    }

    // Whether a tween runs (the run time has work each frame).
    busy(): bool {
        for (let i = 0; i < this.tweens.length; i++) if (unchecked(this.tweens[i]).isRunning()) return true;
        return false;
    }

    // Kills every tween bound to `n` (it left the tree).
    killBoundTo(n: SceneNode): void {
        for (let i = 0; i < this.tweens.length; i++) {
            const t = unchecked(this.tweens[i]);
            if (t.bound === n) t.kill();
        }
    }

    // One frame: every tween made before it, in the order made; then the
    // dead ones go (their tweeners to the pool). Whether one ran.
    advance(dt: f64): bool {
        let any = false;
        const n = this.tweens.length;
        for (let i = 0; i < n && i < this.tweens.length; i++) if (unchecked(this.tweens[i]).advance(dt)) any = true;
        const ts = this.tweens;
        let k = 0;
        for (let i = 0; i < ts.length; i++) {
            const t = unchecked(ts[i]);
            if (t.dead) t.release();
            else ts[k++] = t;
        }
        ts.length = k;
        return any;
    }
}
