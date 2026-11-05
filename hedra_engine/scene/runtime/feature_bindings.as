// The bindings feature of the run time (milestone 39,
// features.as FEATURE_BINDINGS): each instance's <binding>s (../binding/
// binder.as SceneBindings), run against the view model instance it is
// bound to (SceneInstance.bind; the Scene3D component binds its view
// model's nested `data`), as the player runs them: pulled before the
// scripts (view model to nodes: a value that changed makes a new
// picture), pushed after them (two_way bindings: what a script moved,
// back to the view model).
//
// Milestone 31: signal bindings (`signal:<name>`, ../binding/binder.as
// SignalBinding). Their triggers are looked up once, when the view model
// is bound (PropertyTrigger handles, through nested view models as a
// path's other properties are), and each signal a node emits (a script's
// emitSignal, a Timer's timeout, an engine signal such as mouse_entered:
// SceneInstance.emitEvent, after the signal's connections) holds a firing
// of the triggers bound to that node and signal, which the artboards phase
// of the next advance fires before the artboard textures advance (the
// bindings feature goes before the artboards feature: installBindings-
// Feature), so that their state machines see it before the host resets it
// at the end of the frame (../binding/binder.as says why). A Rive state
// machine listening to such a trigger may fire a Rive event
// (StateMachineFireEvent), so a click on an area reaches the host as an
// event without code. Neither holding nor firing allocates.
//
// Milestone 42 (docs/plans/RIVE_MODEL.md section 5; the spec's 0.1 and
// 5.6): the bindings are collected live (SceneBindings.collectLive: a
// built scene has no schema; each path is chosen among its data contexts'
// candidates in the live values, once), their converters looked up in the
// scene's own, then a built scene's project converters (RscnDoc
// .projectConverters), then the project's data when the scene came from
// its text (../data/source.as dataSourceOf, the provider the library
// installs). Each phase:
//
//   PHASE_ARTBOARDS  held triggers fire; the globals still missing are
//                    looked up (RiveGlobals);
//   PHASE_PULL       time-based converters advance, then the pull
//                    (one_way, two_way, once);
//   PHASE_PUSH       two_way and to_source, the outputs through the view
//                    the instance set before it (SceneInstance
//                    .outputView: its camera, its yaw, its size).
//
// Globals (`global="Theme"`): Context.globalViewModel(name) answers null
// until the host has bound data (the experiment of docs/milestones/M42.md:
// null in init, the global from the first advance on), so each global a
// binding names is looked up at each advance until found. Each attempt
// makes a ViewModel wrapper, so after GLOBAL_LOOKUP_ADVANCES advances
// without it the lookup stops and the status's errors say `global view
// model "X" not found`, once. The status gains "globals": how many of the
// globals the bindings name were found (only when they name any); and
// "rebuilds": how many costly writes (a built-in mesh made again, a
// material's pipeline field) the last frame's pull made, only when a
// binding writes a costly property (RIVE_MODEL.md section 3.1).

import { Context } from "rive/host";
import { PropertyTrigger, ViewModel } from "rive/data";
import { SceneNode } from "../tree/node";
import { SceneBindings, converterLookupOf } from "../binding/binder";
import { BindingMode } from "../binding/binding";
import { SIGNAL_TARGET_PREFIX } from "../binding/targets";
import { ConverterLookup } from "../binding/converters";
import { GlobalValues, TriggerSink, ViewModelValues } from "../binding/values";
import { DataSource, dataSourceOf } from "../data/source";
import { RiveViewModelValues } from "../player/view_model";
import { FEATURE_ARTBOARDS, FEATURE_BINDINGS, Feature, InstanceFeature, PHASE_ARTBOARDS, PHASE_PULL, PHASE_PUSH } from "./features";
import { SceneInstance, SceneRuntime } from "./scene_runtime";
import { SignalEvent } from "./signals";
import { GLOBAL_LOOKUP_ADVANCES } from "../sm/data";

// The advances a missing global is looked up on before the lookup stops
// (see the header): one second at 60 a second (../sm/data.as holds it, for
// the state machines' globals too).
export { GLOBAL_LOOKUP_ADVANCES };

export class BindingsFeature extends Feature {
    bit(): u32 {
        return FEATURE_BINDINGS;
    }

    forInstance(inst: SceneInstance): InstanceFeature {
        return new BindingsPart();
    }
}

// Where a global view model is looked up, one attempt at a time: the
// host's Context (ContextGlobals), or a test's.
export abstract class GlobalLookup {
    abstract find(name: string): ViewModelValues?;
}

// The host's globals: Context.globalViewModel (which makes a ViewModel
// wrapper per call, found or not).
export class ContextGlobals extends GlobalLookup {
    ctx: Context;

    constructor(ctx: Context) {
        super();
        this.ctx = ctx;
    }

    find(name: string): ViewModelValues? {
        const vm = this.ctx.globalViewModel(name);
        return vm != null ? new RiveTriggerValues(vm) : null;
    }
}

// The globals a host bound by name (SceneInstance.bindGlobal) before the
// lookup it wraps (the Context's, or a test's; none: only the bound ones).
export class BoundGlobals extends GlobalLookup {
    names: Array<string> = [];
    values: Array<ViewModelValues> = [];
    fallback: GlobalLookup?;

    constructor(fallback: GlobalLookup?) {
        super();
        this.fallback = fallback;
    }

    // Binds `name` to `v` (null: the fallback's again).
    set(name: string, v: ViewModelValues?): void {
        const i = this.names.indexOf(name);
        if (v == null) {
            if (i >= 0) {
                this.names.splice(i, 1);
                this.values.splice(i, 1);
            }
            return;
        }
        if (i >= 0) this.values[i] = v;
        else {
            this.names.push(name);
            this.values.push(v);
        }
    }

    find(name: string): ViewModelValues? {
        const i = this.names.indexOf(name);
        if (i >= 0) return this.values[i];
        const f = this.fallback;
        return f != null ? f.find(name) : null;
    }
}

// The live globals the bindings name (see the header): each found is kept;
// lookUp tries the missing ones, until GLOBAL_LOOKUP_ADVANCES rounds have
// gone by.
export class RiveGlobals extends GlobalValues {
    lookup: GlobalLookup;
    names: Array<string>;
    found: Array<ViewModelValues?> = [];
    // Lookup rounds made, and whether they stopped.
    rounds: i32 = 0;
    stopped: bool = false;

    constructor(lookup: GlobalLookup, names: Array<string>) {
        super();
        this.lookup = lookup;
        this.names = names;
        for (let i = 0; i < names.length; i++) this.found.push(null);
    }

    global(name: string): ViewModelValues? {
        for (let i = 0; i < this.names.length; i++) if (this.names[i] == name) return this.found[i];
        return null;
    }

    // How many were found.
    foundCount(): i32 {
        let n = 0;
        for (let i = 0; i < this.found.length; i++) if (this.found[i] != null) n++;
        return n;
    }

    // Whether any is still looked for.
    pending(): bool {
        return !this.stopped && this.foundCount() < this.names.length;
    }

    // One round: each missing global looked up; returns how many were
    // found now. Nothing once every one is found or the rounds stopped.
    lookUp(): i32 {
        if (!this.pending()) return 0;
        let n = 0;
        for (let i = 0; i < this.names.length; i++) {
            if (this.found[i] != null) continue;
            const v = this.lookup.find(this.names[i]);
            if (v == null) continue;
            this.found[i] = v;
            n++;
        }
        this.rounds++;
        if (this.rounds >= GLOBAL_LOOKUP_ADVANCES && this.foundCount() < this.names.length) this.stopped = true;
        return n;
    }

    // The names never found (once the rounds stopped).
    missing(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.names.length; i++) if (this.found[i] == null) out.push(this.names[i]);
        return out;
    }
}

// One instance's bindings.
export class BindingsPart extends InstanceFeature {
    // Null when no node of the tree declares a binding (the status then has
    // no "bindings").
    bindings: SceneBindings? = null;
    // The values bound (SceneInstance.bind: the host's view model; a test
    // sets a MemoryViewModel).
    values: ViewModelValues? = null;
    // Milestone 42: the globals the bindings name (null when none), and
    // where they are looked up (the instance's Context, or a test's:
    // useGlobals).
    globals: RiveGlobals? = null;
    globalLookup: GlobalLookup? = null;
    // The globals a host bound by name (bindGlobal), over globalLookup.
    boundGlobals: BoundGlobals? = null;

    // Whether the whole tree was attached (the instance's start): until
    // then a subtree a script adds in ready() is left to that attach.
    private started: bool = false;
    private lookup: ConverterLookup? = null;
    // Milestone 42 (docs/plans/RIVE_MODEL.md section 3.1): whether a
    // binding writes a costly property, and how many costly writes the
    // last frame's pull made: the status's "rebuilds", said only by a
    // scene that has such a binding.
    private costly: bool = false;
    frameRebuilds: i64 = 0;

    attach(inst: SceneInstance, root: SceneNode): void {
        if (root === inst.tree.root) {
            this.started = true;
            if (declaresBindings(root)) this.install(inst, SceneBindings.collectLive(inst.tree, this.lookupOf(inst)));
            return;
        }
        // A subtree a script added later (from process(), input() or a
        // signal handler): its bindings join the tree's, collected again,
        // and the bindings already pulled keep what they last applied, so
        // that only the new ones write their nodes on the next pull.
        if (!this.started || !declaresBindings(root)) return;
        const old = this.bindings;
        const b = SceneBindings.collectLive(inst.tree, this.lookupOf(inst));
        if (old != null) keepApplied(old, b);
        this.install(inst, b);
    }

    // The converters' lookup (looked up once per instance).
    private lookupOf(inst: SceneInstance): ConverterLookup {
        const have = this.lookup;
        if (have != null) return have;
        const s = dataSourceOf(inst.tree);
        const source: DataSource? = s.ok ? s.value : null;
        const made = converterLookupOf(inst.tree, source);
        this.lookup = made;
        return made;
    }

    // Takes `b` as the instance's bindings: the globals they name looked
    // up from here on, the output view the instance keeps, the values
    // bound.
    private install(inst: SceneInstance, b: SceneBindings): void {
        this.bindings = b;
        this.costly = b.writesCostly();
        const names = b.globalNames();
        const old = this.globals;
        if (names.length > 0) {
            let l = this.globalLookup;
            if (l == null) {
                const ctx = inst.ctx;
                if (ctx != null) {
                    l = new ContextGlobals(ctx);
                    this.globalLookup = l;
                }
            }
            if (l != null && (old == null || old.names.join("\n") != names.join("\n"))) {
                const g = new RiveGlobals(l, names);
                // (the globals found before are kept)
                if (old != null) for (let i = 0; i < names.length; i++) g.found[i] = old.global(names[i]);
                this.globals = g;
            }
        }
        b.setOutputView(inst.outputView);
        for (let i = 0; i < b.bindings.length; i++) {
            const p = b.bindings[i].spec.property;
            if (p.startsWith("screen_")) inst.wantsOutputView = true;
        }
        b.bindData(this.values, this.globals);
    }

    // Milestone 42: looks globals up in `lookup` rather than the
    // instance's Context (a test's; set before the instance starts, or
    // rebinds now).
    useGlobals(inst: SceneInstance, lookup: GlobalLookup?): void {
        // (a lookup other than the bound globals' becomes what they wrap)
        const bound = this.boundGlobals;
        if (bound != null && lookup !== bound) {
            bound.fallback = lookup;
            lookup = bound;
        }
        this.globalLookup = lookup;
        this.globals = null;
        const b = this.bindings;
        if (b != null) this.install(inst, b);
    }

    bind(inst: SceneInstance, vm: ViewModel?): void {
        const values: ViewModelValues? = vm != null ? new RiveTriggerValues(vm) : null;
        this.bindValues(values);
    }

    // SceneInstance.bindGlobal: `name` found in the host's binding first;
    // the globals are looked up afresh (a bound one at once, on the next
    // advance), so the lookup's rounds start again for the others.
    bindGlobal(inst: SceneInstance, name: string, vm: ViewModel?): void {
        this.bindGlobalValues(inst, name, vm != null ? new RiveTriggerValues(vm) : null);
    }

    // bindGlobal with values of any kind (a test's MemoryViewModel).
    bindGlobalValues(inst: SceneInstance, name: string, values: ViewModelValues?): void {
        let bound = this.boundGlobals;
        if (bound == null) {
            let fallback = this.globalLookup;
            if (fallback == null && inst.ctx != null) fallback = new ContextGlobals(inst.ctx!);
            bound = new BoundGlobals(fallback);
            this.boundGlobals = bound;
        }
        bound.set(name, values);
        this.useGlobals(inst, bound);
        // (bound now, not on the next advance's lookup round)
        const g = this.globals;
        const b = this.bindings;
        if (g != null && b != null && g.lookUp() > 0) b.bindData(this.values, g);
    }

    // Binds `values` (null: none): what bind does with a live view model,
    // and a test with a MemoryViewModel. The signal bindings' triggers are
    // looked up in it here, once.
    bindValues(values: ViewModelValues?): void {
        this.values = values;
        const b = this.bindings;
        if (b != null) b.bindData(values, this.globals);
    }

    // A node emitted a signal: a firing of the triggers bound to it is held
    // for the next advance.
    signalEmitted(inst: SceneInstance, from: SceneNode, ev: SignalEvent): void {
        const b = this.bindings;
        if (b == null || b.signals.length == 0) return;
        b.fire(from, ev.signal);
    }

    advance(inst: SceneInstance, seconds: f64, phase: i32): bool {
        const b = this.bindings;
        if (b == null) return false;
        if (phase == PHASE_ARTBOARDS) {
            this.lookUpGlobals(inst, b);
            b.fireHeld();
            return false;
        }
        if (this.values == null && this.globals == null) {
            if (phase == PHASE_PULL) this.frameRebuilds = 0;
            return false;
        }
        // (values a test set in place rather than through bindValues)
        if (b.root !== this.values) b.bindData(this.values, this.globals);
        if (phase == PHASE_PULL) {
            const moved = b.advanceConverters(seconds);
            const before = b.rebuilds;
            const pulled = b.pullBound() > 0;
            this.frameRebuilds = b.rebuilds - before;
            this.say(inst, b);
            return pulled || moved;
        }
        if (phase == PHASE_PUSH) {
            b.pushBound();
            this.say(inst, b);
        }
        return false;
    }

    // The globals' lookup round (see the header): a global found binds
    // its bindings; the lookup's end says each one never found, once.
    private lookUpGlobals(inst: SceneInstance, b: SceneBindings): void {
        const g = this.globals;
        if (g == null || !g.pending()) return;
        if (g.lookUp() > 0) b.bindData(this.values, g);
        if (!g.stopped) return;
        const missing = g.missing();
        for (let i = 0; i < missing.length; i++) inst.fail("global view model \"" + missing[i] + "\" not found");
    }

    // The bindings' run-time problems, into the status's errors.
    private say(inst: SceneInstance, b: SceneBindings): void {
        if (b.problems.length == 0) return;
        const p = b.takeProblems();
        for (let i = 0; i < p.length; i++) inst.fail(p[i]);
    }

    // Milestone 46: the values bound, for the state machines' conditions.
    boundValues(inst: SceneInstance): ViewModelValues? {
        return this.values;
    }

    // Milestone 46: the global `name` for the state machines: the one the
    // bindings found, else one attempt of the lookup they use (the host's
    // bound globals, the Context's; a Context's lookup makes a wrapper per
    // attempt: the state machines keep what they found, and stop asking
    // after GLOBAL_LOOKUP_ADVANCES advances).
    globalValues(inst: SceneInstance, name: string): ViewModelValues? {
        const g = this.globals;
        if (g != null) {
            const v = g.global(name);
            if (v != null) return v;
        }
        const bound = this.boundGlobals;
        if (bound != null) return bound.find(name);
        const l = this.globalLookup;
        if (l != null) return l.find(name);
        const ctx = inst.ctx;
        return ctx != null ? new ContextGlobals(ctx).find(name) : null;
    }

    // (signal bindings count with the others)
    status(inst: SceneInstance): string {
        const b = this.bindings;
        if (b == null) return "";
        const g = this.globals;
        return ",\"bindings\":" + (b.bindings.length + b.signals.length).toString()
            + (g != null ? ",\"globals\":" + g.foundCount().toString() : "")
            + (this.costly ? ",\"rebuilds\":" + this.frameRebuilds.toString() : "");
    }

    stamp(inst: SceneInstance): i64 {
        const b = this.bindings;
        if (b == null) return 0;
        const g = this.globals;
        return ((<i64>(b.bindings.length + b.signals.length) + 1) * 1009 + (g != null ? <i64>g.foundCount() + 1 : 0)) * 1000003
            + (this.costly ? this.frameRebuilds + 1 : 0);
    }

    dispose(inst: SceneInstance): void {
        this.bindValues(null);
    }

    // Milestone 49 (features.as): whether a node of the tree declares a
    // binding that writes the data: two_way, to_source, or a signal
    // binding (it fires a trigger).
    writesData(inst: SceneInstance): bool {
        return declaresWrites(inst.tree.root);
    }
}

// Milestone 49: whether `root` or a node under it declares a binding that
// writes its data (BindingsPart.writesData). Iterative: a deep tree must
// not exhaust the stack.
export function declaresWrites(root: SceneNode): bool {
    const stack = new Array<SceneNode>();
    stack.push(root);
    while (stack.length > 0) {
        const n = stack.pop();
        for (let i = 0; i < n.bindings.length; i++) {
            const spec = n.bindings[i];
            if (spec.path.length == 0) continue;
            if (spec.mode == BindingMode.TwoWay || spec.mode == BindingMode.ToSource) return true;
            if (spec.property.startsWith(SIGNAL_TARGET_PREFIX)) return true;
        }
        for (let i = 0; i < n.children.length; i++) stack.push(n.children[i]);
    }
    return false;
}

// Whether `node` or a node under it declares a binding.
function declaresBindings(node: SceneNode): bool {
    if (node.bindings.length > 0) return true;
    for (let i = 0; i < node.children.length; i++) if (declaresBindings(node.children[i])) return true;
    return false;
}

// Carries what each binding of `from` last applied (and each signal
// binding's held firings) over to the same binding (its node and spec) in
// `to`, collected again after a subtree was added: its values, its pose,
// whether it let go (once), the values it is bound to, and its converters
// (an Interpolator mid-ease).
function keepApplied(from: SceneBindings, to: SceneBindings): void {
    for (let i = 0; i < to.bindings.length; i++) {
        const nb = to.bindings[i];
        for (let j = 0; j < from.bindings.length; j++) {
            const ob = from.bindings[j];
            if (ob.node !== nb.node || ob.spec !== nb.spec) continue;
            nb.lastSource.copyFrom(ob.lastSource);
            nb.lastNode.copyFrom(ob.lastNode);
            nb.primed = ob.primed;
            nb.pose = ob.pose;
            nb.done = ob.done;
            nb.forced = ob.forced;
            // The values it was bound to: bindData, which install() calls
            // next, applies a binding again (a `once` one too) only when
            // they differ, and a subtree added must not count as that.
            nb.values = ob.values;
            nb.said = ob.said;
            nb.converter = ob.converter;
            nb.implicit = ob.implicit;
            break;
        }
    }
    to.rebuilds = from.rebuilds;
    // Milestone 31: the signal bindings' firings held (a signal emitted in
    // the frame the subtree came) and counts.
    to.held = 0;
    for (let i = 0; i < to.signals.length; i++) {
        const ns = to.signals[i];
        for (let j = 0; j < from.signals.length; j++) {
            const os = from.signals[j];
            if (os.node !== ns.node || os.spec !== ns.spec) continue;
            ns.held = os.held;
            ns.fired = os.fired;
            to.held += os.held;
            break;
        }
    }
}

// A built project's view model (RiveViewModelValues) whose triggers signal
// bindings fire: a path's trigger is looked up (PropertyTrigger, through
// nested view models) when a binding is bound.
class RiveTriggerValues extends RiveViewModelValues {
    constructor(vm: ViewModel) {
        super(vm);
    }

    trigger(path: string): TriggerSink? {
        const p = triggerAt(this.vm, path);
        return p != null ? new RiveTrigger(p) : null;
    }
}

// A view model's trigger, fired by a signal binding.
class RiveTrigger extends TriggerSink {
    property: PropertyTrigger;

    constructor(property: PropertyTrigger) {
        super();
        this.property = property;
    }

    fire(): void {
        this.property.fire();
    }
}

// The trigger `path` names in `vm` (each segment but the last a nested
// view model), or null.
function triggerAt(vm: ViewModel, path: string): PropertyTrigger? {
    if (path.length == 0) return null;
    const parts = path.split("/");
    let at = vm;
    for (let i = 0; i < parts.length - 1; i++) {
        if (parts[i].length == 0) return null;
        const nested = at.getViewModel(parts[i]);
        if (nested == null) return null;
        at = nested.value;
    }
    const name = parts[parts.length - 1];
    return name.length > 0 ? at.getTrigger(name) : null;
}

// Adds the bindings feature to `rt` (the module's generated features.as
// calls it when a scene declares a binding or names a view model), before
// the artboards feature when that is installed already, so that each
// instance's bindings part runs the artboards phase first (the held
// triggers fire before the artboard textures advance; the status names
// each part, so its order is unchanged).
export function installBindingsFeature(rt: SceneRuntime): void {
    rt.install(new BindingsFeature());
    const fs = rt.features;
    let artboards = -1;
    let bindings = -1;
    for (let i = 0; i < fs.length; i++) {
        const bit = fs[i].bit();
        if (bit == FEATURE_ARTBOARDS && artboards < 0) artboards = i;
        else if (bit == FEATURE_BINDINGS) bindings = i;
    }
    if (artboards < 0 || bindings < artboards) return;
    // (bindings > artboards: each feature from artboards on moves one up)
    const f = fs[bindings];
    for (let i = bindings; i > artboards; i--) fs[i] = fs[i - 1];
    fs[artboards] = f;
}
