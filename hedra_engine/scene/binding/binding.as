// Milestone 17: a binding, read (docs/formats/RSCN.md, "Bindings"). A
// node's `<binding>` (../rscn/doc.as BindingDecl, its attributes as
// written) becomes a BindingSpec here: the node property it binds (a
// target of ./targets.as), the view model path it reads, the direction and
// the conversion of a number on its way:
//
//   node = convert(source * scale + offset)          (pull: view model to node)
//   source = (unconvert(node) - offset) / scale       (push, two_way only)
//
// with convert the identity, or degrees_to_radians (x * PI / 180). The
// validator (../rscn/validate.as) reports what is wrong with a declaration
// by the codes RSCN.md lists (binding-*); a declaration that validates
// reads here without a problem.
//
// readBindingDecl is the validator's reader of a <binding>'s own
// attributes; parseBindingDecl its strict form for the code that applies
// one.
//
// Milestone 42 (docs/plans/RIVE_MODEL.md section 3.4, "The bind"):
// `mode="to_source"` (the node drives the view model: a property the
// scene moves, or an output, which only such a binding may name), `once`
// (applied once, when bound), `global` (the path starts in that global
// view model) and `converter` (a converter by name, run after scale,
// offset and convert). This file reads and checks them; ./converters.as
// and ./binder.as give them their meaning.
//
// Milestone 31: a `signal:<name>` binding (./targets.as) fires a view
// model trigger when the node emits <name>: nothing flows back, so it is
// one_way only (two_way and to_source are binding-signal-mode), and there
// is no number to convert (scale, offset and convert are
// binding-conversion; a converter or once, binding-signal-converter). All
// are told here, from the property alone, so that an override's binding
// is refused as a typed node's is.

import { BindingDecl } from "../rscn/doc";
import { VmKind } from "../riv/riv_info";
import { BindKind, isOutputTarget, isSignalTarget } from "./targets";
import { ValueKind } from "../value";
import { parseValueText } from "../value_text";

export enum BindingMode {
    // The view model drives the node (the default).
    OneWay,
    // Both: the view model drives the node, and a change made to the node
    // in the scene (a script's) is written back to the view model.
    TwoWay,
    // Milestone 42 (docs/plans/RIVE_MODEL.md section 3.4): the node drives
    // the view model and is never driven (an output, or a property the
    // scene moves). Appended, so that no value moves.
    ToSource,
}

// The `mode` attribute's words, by BindingMode.
export const BINDING_MODE_NAMES: StaticArray<string> = ["one_way", "two_way", "to_source"];

export enum BindingConvert {
    None,
    // The view model holds degrees, the node radians (`rotation:y`).
    DegreesToRadians,
}

// The `convert` attribute's words, by BindingConvert.
export const BINDING_CONVERT_NAMES: StaticArray<string> = ["none", "degrees_to_radians"];

// A binding as it applies: what <binding> says, typed, and where it was
// written (for warnings about it).
export class BindingSpec {
    property: string;
    // "" in an override: removes the binding inherited for `property`.
    path: string;
    mode: BindingMode = BindingMode.OneWay;
    scale: f64 = 1;
    offset: f64 = 0;
    convert: BindingConvert = BindingConvert.None;
    // Milestone 42 (RIVE_MODEL.md section 3.4, "The bind"): applied once,
    // when the binding is bound, then let go (Rive's Once flag).
    once: bool = false;
    // The global view model the path starts in ("" : the scene's data
    // context), by name: `global="Theme" path="accent"`.
    global: string = "";
    // The converter by name ("" : none): the scene's own, else its data
    // source's. With scale, offset or convert written too, it runs after
    // them.
    converter: string = "";
    // The declaring file as errors name it, and the <binding>'s position.
    file: string = "";
    line: i32 = 0;
    col: i32 = 0;

    constructor(property: string, path: string) {
        this.property = property;
        this.path = path;
    }

    // Whether a number passes through unchanged (scale 1, offset 0, no
    // convert): what a non-number target requires.
    isIdentity(): bool {
        return this.scale == 1 && this.offset == 0 && this.convert == BindingConvert.None;
    }

    // Milestone 42: whether the binding writes the node (one_way, two_way,
    // once) and whether it writes the view model (two_way, to_source).
    drivesNode(): bool {
        return this.mode != BindingMode.ToSource;
    }

    drivesSource(): bool {
        return this.mode == BindingMode.TwoWay || this.mode == BindingMode.ToSource;
    }
}

// Why parseBindingDecl refused a declaration: the validator's code, the
// attribute at fault ("" for the element), the message and a hint.
export class BindingProblem {
    code: string = "";
    attr: string = "";
    message: string = "";
    hint: string = "";
}

// The hints of the problems below, shared with the validator.
export const BINDING_PATH_HINT = "a path names a property of the scene's view model, with / through nested view models, "
    + "such as \"angle\" or \"lamp/level\"";
export const BINDING_MODE_HINT = "one_way (the default) drives the node from the view model; "
    + "two_way also writes a change made to the node back to it; to_source only writes the node's value to it";
export const BINDING_CONVERT_HINT = "degrees_to_radians turns the view model's degrees into a node's radians (rotation:y); "
    + "none (the default) passes the number on as it is";
export const BINDING_NUMBER_HINT = "scale and offset are numbers, such as 2 or -0.5: node = source * scale + offset";
export const BINDING_SCALE_HINT = "with scale 0 every source gives the node the same value, so none can be written back: "
    + "give scale another value, or make the binding one_way";
export const BINDING_SIGNAL_MODE_HINT = "a signal binding fires a view model trigger when the node emits the signal; "
    + "nothing is written back, so it is one_way (leave mode out)";
// Milestone 42.
export const BINDING_ONCE_HINT = "once=\"true\" applies the binding once, when it is bound, then lets go; "
    + "leave it out (false) to keep the binding applied";
export const BINDING_ONCE_MODE_HINT = "once goes with one_way (the view model drives the node once) "
    + "or to_source (the node writes the view model once); a two_way binding keeps both in step, so it is never once";
export const BINDING_OUTPUT_MODE_HINT = "an output (global_position, screen_position, screen_visible, listener_volume_db, listener_pan, "
    + "current_speed, distance_to_target, is_target_reached, is_navigation_finished) is computed: "
    + "write mode=\"to_source\" so that the node's value is written into the view model";
export const BINDING_GLOBAL_HINT = "global names a global view model of the scene's data, such as \"Theme\" "
    + "(letters, digits, _ and spaces, not starting with a digit): the path starts in it";
export const BINDING_CONVERTER_HINT = "converter names a converter: one the scene declares (a top-level DataConverter element) "
    + "or one of its data source; leave it out for none";
export const BINDING_SIGNAL_CONVERTER_HINT = "a signal binding fires a trigger each time the node emits the signal: "
    + "nothing is converted or let go, so remove converter and once";

// Whether `name` is a global view model's name as `global` takes it:
// [A-Za-z_][A-Za-z0-9_ ]* (Rive's names may hold spaces).
export function isGlobalName(name: string): bool {
    if (name.length == 0) return false;
    for (let i = 0; i < name.length; i++) {
        const c = name.charCodeAt(i);
        const letter = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
        const rest = (c >= 0x30 && c <= 0x39) || c == 0x20;
        if (!letter && !(rest && i > 0)) return false;
    }
    return true;
}

// The value of `once` ("" absent, "true", "false"): 1 true, 0 false or
// absent, -1 anything else.
export function bindingOnceOf(once: string): i32 {
    if (once.length == 0 || once == "false") return 0;
    return once == "true" ? 1 : -1;
}
export const BINDING_SIGNAL_CONVERSION_HINT = "a signal binding fires a trigger, which holds no number: "
    + "remove scale, offset and convert";

// Why a non-empty view model path names nothing (a leading or trailing /,
// an empty segment), or "" when it is well formed. An empty path is the
// caller's to judge: an override's removal, else an error.
export function vmPathProblem(path: string): string {
    if (path.length == 0) return "";
    if (path.startsWith("/")) return "it starts with \"/\" (paths are relative to the scene's view model)";
    if (path.endsWith("/")) return "it ends with \"/\"";
    if (path.includes("//")) return "it has an empty segment";
    return "";
}

// The BindingMode `mode` names ("" is the default, one_way), or -1.
export function bindingModeOf(mode: string): i32 {
    if (mode.length == 0) return <i32>BindingMode.OneWay;
    for (let i = 0; i < BINDING_MODE_NAMES.length; i++) if (BINDING_MODE_NAMES[i] == mode) return i;
    return -1;
}

// The BindingConvert `convert` names ("" is the default, none), or -1.
export function bindingConvertOf(convert: string): i32 {
    if (convert.length == 0) return <i32>BindingConvert.None;
    for (let i = 0; i < BINDING_CONVERT_NAMES.length; i++) if (BINDING_CONVERT_NAMES[i] == convert) return i;
    return -1;
}

// The number a `scale` or `offset` attribute holds, written as a number
// of the format is (an int or a float: "2", "-0.5", "1e3"), or NaN when it
// is not one or is not finite (inf and nan are refused: no view model
// number converts through them). `def` for "", the attribute's absence.
export function bindingNumberOf(text: string, def: f64): f64 {
    if (text.length == 0) return def;
    const p = parseValueText(text);
    if (!p.ok) return NaN;
    const v = p.value;
    let x: f64 = NaN;
    if (v.kind == ValueKind.Int) x = <f64>v.i;
    else if (v.kind == ValueKind.Float) x = v.f;
    return isFinite(x) ? x : NaN;
}

// Appends a problem (named so that cli/tests/scene/test_docs.py finds
// its code on the line, as it finds every reporter's).
function fail(problems: Array<BindingProblem>, code: string, attr: string, message: string, hint: string): void {
    const p = new BindingProblem();
    p.code = code;
    p.attr = attr;
    p.message = message;
    p.hint = hint;
    problems.push(p);
}

// The spec of `d` declared in `file`, every problem of its own attributes
// appended to `problems` (in attribute order: path, mode, once, global,
// converter, scale, offset, convert; then once with two_way, an output
// that is not to_source and the scale that cannot be undone, or for a
// signal binding its mode, conversions, converter and once:
// readSignalDecl): what can be told without the node's class. An attribute at fault reads as its default, so the spec is always
// whole. An empty path is no problem here (an override's removal); the
// validator refuses it on a typed node, and checks the property against
// the node's class.
export function readBindingDecl(d: BindingDecl, file: string, problems: Array<BindingProblem>): BindingSpec {
    const s = new BindingSpec(d.property, d.path);
    s.file = file;
    s.line = d.pos.line;
    s.col = d.pos.col;
    const why = vmPathProblem(d.path);
    if (why.length > 0) {
        fail(problems, "binding-path", "path", "path \"" + d.path + "\" names no view model property: " + why,
            BINDING_PATH_HINT);
    }
    const mode = bindingModeOf(d.mode);
    if (mode < 0) {
        fail(problems, "binding-mode", "mode", "mode \"" + d.mode + "\" is not one_way, two_way or to_source", BINDING_MODE_HINT);
    } else {
        s.mode = <BindingMode>mode;
    }
    const once = bindingOnceOf(d.once);
    if (once < 0) {
        fail(problems, "binding-once", "once", "once \"" + d.once + "\" is not true or false", BINDING_ONCE_HINT);
    } else {
        s.once = once == 1;
    }
    if (d.has("global")) {
        if (!isGlobalName(d.global)) {
            const what = d.global.length == 0 ? "global is empty" : "global \"" + d.global + "\" is not a view model's name";
            fail(problems, "binding-global", "global", what, BINDING_GLOBAL_HINT);
        } else {
            s.global = d.global;
        }
    }
    if (d.has("converter") && d.converter.length == 0) {
        fail(problems, "binding-converter-name", "converter", "converter is empty", BINDING_CONVERTER_HINT);
    }
    s.converter = d.converter;
    const scale = bindingNumberOf(d.scale, 1);
    if (isNaN(scale)) {
        fail(problems, "binding-number", "scale", "scale \"" + d.scale + "\" is not a finite number", BINDING_NUMBER_HINT);
    } else {
        s.scale = scale;
    }
    const offset = bindingNumberOf(d.offset, 0);
    if (isNaN(offset)) {
        fail(problems, "binding-number", "offset", "offset \"" + d.offset + "\" is not a finite number", BINDING_NUMBER_HINT);
    } else {
        s.offset = offset;
    }
    const convert = bindingConvertOf(d.convert);
    if (convert < 0) {
        fail(problems, "binding-convert", "convert", "convert \"" + d.convert + "\" is not none or degrees_to_radians",
            BINDING_CONVERT_HINT);
    } else {
        s.convert = <BindingConvert>convert;
    }
    if (isSignalTarget(d.property)) {
        readSignalDecl(d, problems);
        return s;
    }
    if (once == 1 && mode == <i32>BindingMode.TwoWay) {
        fail(problems, "binding-once-mode", "once", "a two_way binding cannot be once: it keeps the node and the view model in step",
            BINDING_ONCE_MODE_HINT);
    }
    if (mode >= 0 && mode != <i32>BindingMode.ToSource && isOutputTarget(d.property)) {
        fail(problems, "binding-output-mode", "mode", d.property + " is an output: it is read, never written, so its binding is to_source, not "
            + BINDING_MODE_NAMES[mode], BINDING_OUTPUT_MODE_HINT);
    }
    if ((mode == <i32>BindingMode.TwoWay || mode == <i32>BindingMode.ToSource) && !isNaN(scale) && scale == 0) {
        fail(problems, "binding-scale", "scale", "a " + BINDING_MODE_NAMES[mode] + " binding with scale 0 cannot write the node back to the view model",
            BINDING_SCALE_HINT);
    }
    return s;
}

// The problems of a signal binding's own attributes (see the header): a
// two_way or to_source mode, then each conversion attribute written, then
// a converter and once, at the attribute.
function readSignalDecl(d: BindingDecl, problems: Array<BindingProblem>): void {
    const mode = bindingModeOf(d.mode);
    if (mode == <i32>BindingMode.TwoWay || mode == <i32>BindingMode.ToSource) {
        fail(problems, "binding-signal-mode", "mode", d.property + " binds a signal: it is one_way, not " + BINDING_MODE_NAMES[mode],
            BINDING_SIGNAL_MODE_HINT);
    }
    const attrs = ["scale", "offset", "convert"];
    const values = [d.scale, d.offset, d.convert];
    for (let k = 0; k < attrs.length; k++) {
        if (values[k].length == 0) continue;
        fail(problems, "binding-conversion", attrs[k], d.property + " binds a signal to a trigger: it takes no " + attrs[k],
            BINDING_SIGNAL_CONVERSION_HINT);
    }
    const extras = ["converter", "once"];
    for (let k = 0; k < extras.length; k++) {
        if (!d.has(extras[k])) continue;
        fail(problems, "binding-signal-converter", extras[k], d.property + " binds a signal to a trigger: it takes no " + extras[k],
            BINDING_SIGNAL_CONVERTER_HINT);
    }
}

// The spec of `d` declared in `file`, or null with `problem` filled in
// (the first of readBindingDecl's problems): the strict reader, for code
// that applies a declaration the validator may not have seen.
export function parseBindingDecl(d: BindingDecl, file: string, problem: BindingProblem): BindingSpec? {
    const problems = new Array<BindingProblem>();
    const s = readBindingDecl(d, file, problems);
    if (problems.length == 0) return s;
    const first = problems[0];
    problem.code = first.code;
    problem.attr = first.attr;
    problem.message = first.message;
    problem.hint = first.hint;
    return null;
}

// The segments of a view model path ("lamp/level" is ["lamp", "level"]),
// or null for one that names nothing: empty, or with an empty segment.
export function splitVmPath(path: string): Array<string>? {
    if (path.length == 0) return null;
    const parts = path.split("/");
    for (let i = 0; i < parts.length; i++) if (parts[i].length == 0) return null;
    return parts;
}

// Whether a view model property of kind `vm` may drive a target of kind
// `target` (with no converter between them): a number a Number, a boolean
// or a number (non-zero is true) a Boolean, a color a Color; a Trigger
// target (a signal) fires a trigger; milestone 42: a string a String, an
// enum (matched by key) or a number (the index) an Enum.
export function bindable(vm: VmKind, target: BindKind): bool {
    if (target == BindKind.Number) return vm == VmKind.Number;
    if (target == BindKind.Boolean) return vm == VmKind.Boolean || vm == VmKind.Number;
    if (target == BindKind.Trigger) return vm == VmKind.Trigger;
    if (target == BindKind.String) return vm == VmKind.String;
    if (target == BindKind.Enum) return vm == VmKind.Enum || vm == VmKind.Number;
    return vm == VmKind.Color;
}

// The node's number for the view model's `source` (pull).
export function toNodeNumber(s: BindingSpec, source: f64): f64 {
    const x = source * s.scale + s.offset;
    return s.convert == BindingConvert.DegreesToRadians ? x * Math.PI / 180 : x;
}

// The view model's number for the node's `value` (push); `value` itself
// when the scale is 0 (the validator refuses that for two_way).
export function toSourceNumber(s: BindingSpec, value: f64): f64 {
    const x = s.convert == BindingConvert.DegreesToRadians ? value * 180 / Math.PI : value;
    return s.scale != 0 ? (x - s.offset) / s.scale : x;
}
