// How a running state machine reads its scene's data (docs/plans/
// RIVE_MODEL.md sections 3.3 and 3.4): each view model property the
// machine names (./machine.as SmPath: a condition's side, a 1D blend's
// number, a direct blend's weight, a fire action's trigger, an input's
// binding) resolved once against the data its instance is given
// (./data.as SmData), and read each frame without allocating.
//
// A path is looked for as a binding of the scene's file on the scene's
// root would be (../binding/binder.as contextCandidates): the innermost
// data context's candidate first ("left/open" for a door instanced with
// data_path "left"), then outwards to the root's ("open"), the first that
// names a property winning; a global's path (`global`) is the global's
// alone. What it found is kept, and looked for again only when the values
// the data answers are another object (a host bound another instance, a
// missing global turned up). A path that names nothing reads as no value:
// a condition on it fails, a blend reads 0, a fire action fires nothing
// (stateMachineDataDiagnostics, ./scene_machines.as, says why ahead of a
// run).
//
// A converter (`converter`) is built the first time its path resolves,
// from the scene's converters then the project's (../binding/converters.as
// buildNamedConverter), as a binding builds its own, and kept: an
// Interpolator keeps its ease between frames, and advances with the
// machine.
//
// Comparisons are Rive's (transition_viewmodel_condition.hpp's operations):
// numbers as f32 with every operator, equality with no tolerance; booleans,
// strings, colours and enums (by key) with equal and notEqual only (any
// other operator is false); two values of different kinds never compare.

import { VmKind } from "../riv/riv_info";
import { BoundValue, ViewModelValues, parseDataValue } from "../binding/values";
import { Converter, ConverterLookup, ConverterProblem, buildNamedConverter } from "../binding/converters";
import { contextCandidates } from "../binding/binder";
import { SceneNode } from "../tree/node";
import { ConditionOp } from "./decl";
import { SmPath } from "./machine";
import { SmData } from "./data";

// Where a PathRun stands.
export const PATH_UNRESOLVED: i32 = 0;
export const PATH_FOUND: i32 = 1;
export const PATH_MISSING: i32 = 2;

// One SmPath as one instance reads it.
export class PathRun {
    path: SmPath;
    // The paths tried, innermost context first (one for a global's).
    candidates: Array<string>;
    state: i32 = PATH_UNRESOLVED;
    // The values it resolved in, the candidate that names a property there,
    // and that property's kind.
    values: ViewModelValues? = null;
    resolved: string = "";
    kind: VmKind = VmKind.Other;
    // Its converter (null: none named, or it could not be built), the kind
    // it gives, and why it could not be built ("" when it was or none is
    // named).
    converter: Converter? = null;
    outKind: VmKind = VmKind.Other;
    converterError: string = "";
    private converterTried: bool = false;
    // The value read, and the converter's result (kept: a read allocates
    // nothing).
    raw: BoundValue = new BoundValue();
    out: BoundValue = new BoundValue();
    // A trigger's count at the end of the last advance (a trigger condition
    // passes on a count past it: fired since).
    triggerBase: i32 = 0;

    constructor(path: SmPath, sceneRoot: SceneNode, file: string) {
        this.path = path;
        if (path.global.length > 0 || path.path.length == 0) {
            this.candidates = [path.path];
        } else {
            this.candidates = contextCandidates(sceneRoot, file, path.path);
        }
    }

    // Resolves against `vm` (the scene's values, or the global's): the
    // first candidate that names a property. Builds the converter the first
    // time (from `lookup`).
    // Answers whether it now reads another property than before (other
    // values, another candidate, or found or lost): a trigger's count is
    // then counted afresh. A path resolved again to the same property of
    // the same values keeps its trigger's base, so firings already used
    // are not seen again.
    resolve(vm: ViewModelValues?, lookup: ConverterLookup?): bool {
        const wasValues = this.values;
        const wasResolved = this.resolved;
        const wasFound = this.state == PATH_FOUND;
        this.values = vm;
        this.resolved = "";
        this.kind = VmKind.Other;
        this.outKind = VmKind.Other;
        this.state = PATH_MISSING;
        if (vm == null) {
            this.triggerBase = 0;
            return wasFound;
        }
        for (let i = 0; i < this.candidates.length; i++) {
            const k = vm.kindOf(this.candidates[i]);
            if (k == VmKind.Other) continue;
            this.resolved = this.candidates[i];
            this.kind = k;
            this.state = PATH_FOUND;
            break;
        }
        const same = wasFound && this.state == PATH_FOUND && vm === wasValues && this.resolved == wasResolved;
        if (!same) {
            // (the first values read count every firing so far as this
            // frame's, as a trigger fired before the machine's first
            // advance is seen by it; other values found later count from
            // their count now: their old firings are not this machine's)
            const n = this.state == PATH_FOUND && this.kind == VmKind.Trigger && wasValues != null ? vm.triggerCount(this.resolved) : 0;
            this.triggerBase = n > 0 ? n : 0;
        }
        if (this.state != PATH_FOUND) return !same;
        this.resolveConverter(vm, lookup);
        return !same;
    }

    private resolveConverter(vm: ViewModelValues, lookup: ConverterLookup?): void {
        const name = this.path.converter;
        if (name.length > 0 && !this.converterTried) {
            this.converterTried = true;
            if (lookup != null) {
                const problem = new ConverterProblem();
                const c = buildNamedConverter(name, lookup, problem);
                if (c != null) c.setDirection(false);
                this.converter = c;
                if (c == null) this.converterError = problem.code.length > 0 ? problem.code : "binding-converter-unknown";
            } else {
                this.converterError = "binding-converter-unknown";
            }
        }
        const c = this.converter;
        if (c != null) {
            c.bind(vm);
            this.outKind = c.outputKind(this.kind);
        } else {
            this.outKind = name.length > 0 ? VmKind.Other : this.kind;
        }
    }

    // The value now, through the converter (null: unresolved, or a read
    // the values or the converter refused).
    read(): BoundValue? {
        if (this.state != PATH_FOUND) return null;
        const vm = this.values;
        if (vm == null || !vm.read(this.resolved, this.raw)) return null;
        const c = this.converter;
        if (c == null) return this.path.converter.length > 0 ? null : this.raw;
        return c.forward(this.raw, this.out) ? this.out : null;
    }

    // Milestone 47 (a listener's ListenerViewModelChange): writes `v` to
    // the property it resolved to (the values decide how a value of
    // another kind is taken: ViewModelValues.write); false when it is
    // unresolved or the values refuse it. The converter is the source's,
    // not this path's: a written value goes in as it is.
    write(v: BoundValue): bool {
        if (this.state != PATH_FOUND) return false;
        const vm = this.values;
        return vm != null && vm.write(this.resolved, v);
    }

    // A trigger's count now (-1: not a trigger, or not resolved).
    triggerCount(): i32 {
        if (this.state != PATH_FOUND || this.kind != VmKind.Trigger) return -1;
        const vm = this.values;
        return vm != null ? vm.triggerCount(this.resolved) : -1;
    }

    // Time passes for a time-based converter; whether its output moved.
    advance(seconds: f64): bool {
        const c = this.converter;
        return c != null && c.timed() && c.advance(seconds);
    }
}

// The values `p` reads in: the global's, or the scene's.
export function valuesFor(p: SmPath, data: SmData?): ViewModelValues? {
    if (data == null) return null;
    return p.global.length > 0 ? data.global(p.global) : data.values();
}

// A literal as a value of kind `kind` (an enum compared by its key: any
// text is taken); false when it does not read as that kind.
export function parseLiteral(kind: VmKind, text: string, out: BoundValue): bool {
    if (kind == VmKind.Enum) {
        out.setEnum(-1, text);
        return true;
    }
    if (kind != VmKind.Number && kind != VmKind.Boolean && kind != VmKind.Color && kind != VmKind.String) return false;
    const r = parseDataValue(kind, text, null);
    if (!r.ok) return false;
    out.copyFrom(r.value);
    return true;
}

// Rive's comparison of `a` and `b` by `op` (see the header).
export function compareValues(op: ConditionOp, a: BoundValue, b: BoundValue): bool {
    if (a.kind != b.kind) return false;
    const k = a.kind;
    if (k == VmKind.Number) return compareNumbers(op, <f32>a.number, <f32>b.number);
    let same: bool;
    if (k == VmKind.Boolean) same = a.boolean == b.boolean;
    else if (k == VmKind.Color) same = a.color == b.color;
    else if (k == VmKind.String || k == VmKind.Enum) same = a.text == b.text;
    else return false;
    if (op == ConditionOp.Equal) return same;
    if (op == ConditionOp.NotEqual) return !same;
    return false;
}

// Two numbers as Rive's f32s.
export function compareNumbers(op: ConditionOp, a: f32, b: f32): bool {
    switch (op) {
        case ConditionOp.Equal: return a == b;
        case ConditionOp.NotEqual: return a != b;
        case ConditionOp.LessThanOrEqual: return a <= b;
        case ConditionOp.LessThan: return a < b;
        case ConditionOp.GreaterThanOrEqual: return a >= b;
        case ConditionOp.GreaterThan: return a > b;
    }
    return false;
}

// Whether a property of kind `k` can be read by a comparison (a trigger is
// a condition of its own; a nested view model, a list or another kind
// never compares).
export function comparableKind(k: VmKind): bool {
    return k == VmKind.Number || k == VmKind.Boolean || k == VmKind.Color || k == VmKind.String || k == VmKind.Enum;
}
