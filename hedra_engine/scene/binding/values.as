// Milestone 17: the values a scene's bindings read and write
// (docs/formats/RSCN.md, "Bindings"). ViewModelValues is the seam: the
// binder (./binder.as) reads and writes a view model through it, whoever
// holds the view model:
//
// - MemoryViewModel: the tools' (the CLI's `render`, the preview), a
//   ViewModelSchema's values in memory, set by hand with `--data
//   <path>=<value>` and the preview's keys;
// - ../player/view_model.as RiveViewModelValues: a built project's, the
//   instance bound to the scene's artboard, through rive/data.
//
// Values cross as a BoundValue: a number, a boolean, a colour (ARGB, sRGB
// with straight alpha, as Rive holds it), and since milestone 42 a string
// and an enum (its value's key and index), the kinds a binding takes.
//
// Milestone 31: a signal binding fires a trigger instead (./binder.as
// SignalBinding): ViewModelValues.trigger looks the trigger at a path up
// once, when the binding is bound, and the TriggerSink it answers fires it
// as often as the node emits the signal, allocating nothing.
//
// Milestone 42 (docs/plans/RIVE_MODEL.md section 3.4): GlobalValues answers
// a global view model's values by name, so that a binding written
// `global="Theme"` reads and writes that instance: MemoryGlobals in the
// tools (./scene_data.as SceneData.globals), RiveGlobals at run time
// (../runtime/feature_bindings.as, over Context.globalViewModel).

import { Result } from "../../base/util";
import { VmKind, vmKindName } from "../riv/riv_info";
import { ViewModelSchema } from "./schema";

// One value of a number, boolean, color, string or enum view model
// property (and, from a DataConverterTrigger, a trigger's count).
export class BoundValue {
    kind: VmKind = VmKind.Number;
    // A number; an enum's index (-1: its key is not one of the enum's); a
    // trigger's count.
    number: f64 = 0;
    boolean: bool = false;
    // ARGB.
    color: u32 = 0;
    // A string; an enum's key.
    text: string = "";

    static ofNumber(x: f64): BoundValue {
        const v = new BoundValue();
        v.setNumber(x);
        return v;
    }

    static ofBoolean(b: bool): BoundValue {
        const v = new BoundValue();
        v.setBoolean(b);
        return v;
    }

    static ofColor(argb: u32): BoundValue {
        const v = new BoundValue();
        v.setColor(argb);
        return v;
    }

    static ofString(s: string): BoundValue {
        const v = new BoundValue();
        v.setString(s);
        return v;
    }

    static ofEnum(index: i32, key: string): BoundValue {
        const v = new BoundValue();
        v.setEnum(index, key);
        return v;
    }

    setNumber(x: f64): void {
        this.kind = VmKind.Number;
        this.number = x;
    }

    setBoolean(b: bool): void {
        this.kind = VmKind.Boolean;
        this.boolean = b;
    }

    setColor(argb: u32): void {
        this.kind = VmKind.Color;
        this.color = argb;
    }

    // (the string is kept, not copied: strings are immutable)
    setString(s: string): void {
        this.kind = VmKind.String;
        this.text = s;
    }

    // An enum's value: its index among the enum's keys (-1 when unknown)
    // and its key.
    setEnum(index: i32, key: string): void {
        this.kind = VmKind.Enum;
        this.number = <f64>index;
        this.text = key;
    }

    // A trigger's count (DataConverterTrigger's output).
    setTrigger(count: f64): void {
        this.kind = VmKind.Trigger;
        this.number = count;
    }

    copyFrom(o: BoundValue): void {
        this.kind = o.kind;
        this.number = o.number;
        this.boolean = o.boolean;
        this.color = o.color;
        this.text = o.text;
    }

    // Equal kinds and values; numbers within `tolerance` of each other,
    // relative to the larger (a value read back from a node's transform is
    // not bit for bit the one written: ./binder.as).
    // Strings and enums compare by their text (an enum by its key), which
    // allocates nothing.
    equals(o: BoundValue, tolerance: f64 = 0): bool {
        if (this.kind != o.kind) return false;
        if (this.kind == VmKind.Boolean) return this.boolean == o.boolean;
        if (this.kind == VmKind.Color) return this.color == o.color;
        if (this.kind == VmKind.String || this.kind == VmKind.Enum) return this.text == o.text;
        const a = this.number;
        const b = o.number;
        if (a == b) return true;
        const scale = max<f64>(1, max<f64>(Math.abs(a), Math.abs(b)));
        return Math.abs(a - b) <= tolerance * scale;
    }
}

// A view model trigger, looked up: fire() fires it (Rive's
// PropertyTrigger.fire, in a built project).
export abstract class TriggerSink {
    abstract fire(): void;
}

// A trigger of a MemoryViewModel: it counts its firings (nothing listens
// to it: the tools never fire a trigger, and a test reads the count).
export class MemoryTrigger extends TriggerSink {
    path: string;
    fired: i32 = 0;

    constructor(path: string) {
        super();
        this.path = path;
    }

    fire(): void {
        this.fired++;
    }
}

// A view model the binder reads and writes, by path ("angle",
// "lamp/level": ./schema.as's paths, `--data`'s).
export abstract class ViewModelValues {
    // The trigger at `path`, or null when there is none (no property there,
    // or one of another kind). Called once a signal binding, when the view
    // model is bound; a view model that holds no triggers answers null.
    trigger(path: string): TriggerSink? {
        return null;
    }

    // The kind of the property at `path`; VmKind.Other when there is none.
    abstract kindOf(path: string): VmKind;

    // Reads a number, boolean, color, string or enum property into `out`;
    // false (and `out` unchanged) for any other kind or no property.
    abstract read(path: string, out: BoundValue): bool;

    // Writes a number, boolean, color, string or enum property (`v` of the
    // property's kind; a number written to a boolean is true when not 0, a
    // number to an enum is its index, a string to an enum its key); false
    // when there is no such property of those kinds, or the value is one
    // its kind refuses.
    abstract write(path: string, v: BoundValue): bool;

    // Milestone 46: how many times the trigger at `path` has fired since
    // these values were made (a state machine's trigger condition compares
    // it with the count it last saw, as Rive's trigger comparator does), or
    // -1 when `path` names no trigger or the values cannot tell.
    triggerCount(path: string): i32 {
        return -1;
    }

    // The keys of the enum at `path`, in order; null when it is no enum.
    // (Looked up when a binding is bound, never per frame.)
    enumKeys(path: string): Array<string>? {
        return null;
    }
}

// Milestone 42: the global view models a binding may name (`global=`), by
// name: null when there is no such global, or it is not there yet (a live
// global is looked up lazily: ../runtime/feature_bindings.as RiveGlobals).
export abstract class GlobalValues {
    abstract global(name: string): ViewModelValues?;
}

// A view model in memory: a schema's fields and their values, starting
// from the schema's instance (the tools'). The schema itself is left as it
// was read: the values live here, one per field, so that the preview can
// keep what was set by hand across a reload (by path) and the schema still
// says what the file holds.
export class MemoryViewModel extends ViewModelValues {
    schema: ViewModelSchema;
    // Bumped by every write that changes a value, so that a viewer knows
    // when to redraw.
    version: u32 = 0;
    // By field index: the value of each number, boolean, color, string and
    // enum field (another kind's entry is unused).
    values: Array<BoundValue> = [];
    // Field index by path.
    private index: Map<string, i32> = new Map<string, i32>();
    // The triggers handed out, by path (one each, so that every binding of
    // a path counts on the same one).
    private triggers: Map<string, MemoryTrigger> = new Map<string, MemoryTrigger>();

    constructor(schema: ViewModelSchema) {
        super();
        this.schema = schema;
        for (let i = 0; i < schema.fields.length; i++) {
            const f = schema.fields[i];
            const v = new BoundValue();
            if (f.kind == VmKind.Boolean) v.setBoolean(f.boolean);
            else if (f.kind == VmKind.Color) v.setColor(f.color);
            else if (f.kind == VmKind.String) v.setString(f.text);
            else if (f.kind == VmKind.Enum) v.setEnum(enumIndex(f.enumValues, f.text), f.text);
            else v.setNumber(f.number);
            this.values.push(v);
            // (The first of two fields with one path wins, as field() does.)
            if (!this.index.has(f.path)) this.index.set(f.path, i);
        }
    }

    // The field index of `path`, -1 when there is none.
    private at(path: string): i32 {
        return this.index.has(path) ? this.index.get(path) : -1;
    }

    kindOf(path: string): VmKind {
        const i = this.at(path);
        return i >= 0 ? this.schema.fields[i].kind : VmKind.Other;
    }

    enumKeys(path: string): Array<string>? {
        const i = this.at(path);
        if (i < 0 || this.schema.fields[i].kind != VmKind.Enum) return null;
        return this.schema.fields[i].enumValues;
    }

    trigger(path: string): TriggerSink? {
        return this.memoryTrigger(path);
    }

    // The trigger at `path` (a field of kind Trigger), the same one every
    // time, or null.
    memoryTrigger(path: string): MemoryTrigger? {
        if (this.triggers.has(path)) return this.triggers.get(path);
        const i = this.at(path);
        if (i < 0 || this.schema.fields[i].kind != VmKind.Trigger) return null;
        const t = new MemoryTrigger(path);
        this.triggers.set(path, t);
        return t;
    }

    // Milestone 46: firedCount for a trigger, -1 for any other path.
    triggerCount(path: string): i32 {
        return this.kindOf(path) == VmKind.Trigger ? this.firedCount(path) : -1;
    }

    // How many times the trigger at `path` was fired (0 for a path that
    // names no trigger, or one never looked up).
    firedCount(path: string): i32 {
        return this.triggers.has(path) ? this.triggers.get(path).fired : 0;
    }

    read(path: string, out: BoundValue): bool {
        const i = this.at(path);
        if (i < 0 || !bindableKind(this.schema.fields[i].kind)) return false;
        out.copyFrom(this.values[i]);
        return true;
    }

    write(path: string, v: BoundValue): bool {
        const i = this.at(path);
        if (i < 0) return false;
        const f = this.schema.fields[i];
        const have = this.values[i];
        if (!writeInto(f.kind, f.enumValues, have, v)) return false;
        if (writeChanged()) this.version++;
        return true;
    }

    // Sets the property at `path` from text, by `--data`'s rules
    // (parseDataValue); a trigger is fired, whatever the text. Fails,
    // changing nothing, on a path the view model lacks or a value its kind
    // refuses; the error is `--data <path>: <why>`, as the tools print it.
    set(path: string, text: string): Result<bool> {
        return this.setAs(path, text, path);
    }

    // set, the error naming the path as `shown` (`global/Theme/accent`
    // for a global's `accent`: ./scene_data.as).
    setAs(path: string, text: string, shown: string): Result<bool> {
        const i = this.at(path);
        if (i < 0) {
            const paths = this.schema.bindablePaths();
            return Result.fail<bool>("--data " + shown + ": the view model " + this.schema.name
                + " has no property at \"" + path + "\" (it has: "
                + (paths.length > 0 ? paths.join(", ") : "none that a binding takes") + ")");
        }
        const f = this.schema.fields[i];
        if (f.kind == VmKind.Trigger) {
            const t = this.memoryTrigger(path);
            if (t != null) t.fire();
            this.version++;
            return Result.okv<bool>(true);
        }
        const v = parseDataValue(f.kind, text, f.enumValues);
        if (!v.ok) return Result.fail<bool>("--data " + shown + ": " + v.err);
        this.write(path, v.value);
        return Result.okv<bool>(true);
    }
}

// Whether the last writeInto changed the value (a module flag rather than
// a second result: writeInto runs on every push, and allocates nothing).
let changedFlag: bool = false;

// Whether the last writeInto changed the value it wrote into.
export function writeChanged(): bool {
    return changedFlag;
}

// Writes `v` into `have`, a value of a property of kind `kind` (`keys` an
// enum's keys), by ViewModelValues.write's rules; false when the kind
// refuses it. changedFlag says whether `have` changed.
export function writeInto(kind: VmKind, keys: Array<string>, have: BoundValue, v: BoundValue): bool {
    changedFlag = false;
    if (kind == VmKind.Number) {
        let x: f64 = 0;
        if (v.kind == VmKind.Number || v.kind == VmKind.Enum) x = v.number;
        else if (v.kind == VmKind.Boolean) x = v.boolean ? 1.0 : 0.0;
        else return false;
        if (have.kind != VmKind.Number || have.number != x) {
            have.setNumber(x);
            changedFlag = true;
        }
        return true;
    }
    if (kind == VmKind.Boolean) {
        let b = false;
        if (v.kind == VmKind.Number) b = v.number != 0;
        else if (v.kind == VmKind.Boolean) b = v.boolean;
        else return false;
        if (have.kind != VmKind.Boolean || have.boolean != b) {
            have.setBoolean(b);
            changedFlag = true;
        }
        return true;
    }
    if (kind == VmKind.Color) {
        if (v.kind != VmKind.Color) return false;
        if (have.kind != VmKind.Color || have.color != v.color) {
            have.setColor(v.color);
            changedFlag = true;
        }
        return true;
    }
    if (kind == VmKind.String) {
        if (v.kind != VmKind.String && v.kind != VmKind.Enum) return false;
        if (have.kind != VmKind.String || have.text != v.text) {
            have.setString(v.text);
            changedFlag = true;
        }
        return true;
    }
    if (kind == VmKind.Enum) {
        let index = -1;
        if (v.kind == VmKind.Enum || v.kind == VmKind.String) index = enumIndex(keys, v.text);
        else if (v.kind == VmKind.Number) {
            const n = v.number;
            index = n >= 0 && n < <f64>keys.length && n == Math.floor(n) ? <i32>n : -1;
        } else return false;
        // A key the enum lacks changes nothing (Rive's enum_set ignores it).
        if (index < 0) return false;
        if (have.kind != VmKind.Enum || <i32>have.number != index) {
            have.setEnum(index, keys[index]);
            changedFlag = true;
        }
        return true;
    }
    return false;
}

// The index of `key` among `keys`, -1 when it is none of them.
export function enumIndex(keys: Array<string>, key: string): i32 {
    for (let i = 0; i < keys.length; i++) if (keys[i] == key) return i;
    return -1;
}

// Milestone 42: the tools' globals, by name (./scene_data.as
// SceneData.globals: each global view model's default instance in memory).
export class MemoryGlobals extends GlobalValues {
    globals: Array<MemoryViewModel>;

    constructor(globals: Array<MemoryViewModel>) {
        super();
        this.globals = globals;
    }

    global(name: string): ViewModelValues? {
        for (let i = 0; i < this.globals.length; i++) if (this.globals[i].schema.name == name) return this.globals[i];
        return null;
    }
}

// Whether a view model property of kind `k` holds a BoundValue: a number,
// a boolean, a color, a string or an enum.
export function bindableKind(k: VmKind): bool {
    return k == VmKind.Number || k == VmKind.Boolean || k == VmKind.Color || k == VmKind.String || k == VmKind.Enum;
}

// One `--data <path>=<value>`.
export class DataAssignment {
    path: string;
    text: string;

    constructor(path: string, text: string) {
        this.path = path;
        this.text = text;
    }
}

// `<path>=<value>` (the first `=` splits); fails on text without one or
// with an empty path.
export function parseDataArg(arg: string): Result<DataAssignment> {
    const at = arg.indexOf("=");
    if (at <= 0) return Result.fail<DataAssignment>("--data takes <path>=<value>, found \"" + arg + "\"");
    return Result.okv<DataAssignment>(new DataAssignment(arg.substring(0, at), arg.substring(at + 1)));
}

// A value of kind `kind` from text, as `rive --data` reads one (rive's
// docs/data.md, "The --data path"): a number, a whole number or a decimal
// with nothing after it; a boolean, true, false, 1 or 0; a color, 8 hex
// digits of ARGB or 6 of RGB taken as opaque, no prefix; a string, any
// text; an enum, one of its keys (`keys`). Other kinds are refused:
// bindings take only these five (a trigger is fired, not set:
// MemoryViewModel.set).
export function parseDataValue(kind: VmKind, text: string, keys: Array<string>? = null): Result<BoundValue> {
    if (kind == VmKind.Number) {
        if (!isDecimal(text)) return Result.fail<BoundValue>("\"" + text + "\" is not a number");
        // A Rive number is an f32: "1e400" (infinity as an f64) and "1e39"
        // (infinity once stored) are refused rather than bound as inf.
        const x = parseFloat(text);
        if (!(Math.abs(x) <= <f64>f32.MAX_VALUE)) return Result.fail<BoundValue>("\"" + text + "\" is not a finite number (a Rive number is at most 3.4e38 in size)");
        return Result.okv<BoundValue>(BoundValue.ofNumber(x));
    }
    if (kind == VmKind.Boolean) {
        if (text == "true" || text == "1") return Result.okv<BoundValue>(BoundValue.ofBoolean(true));
        if (text == "false" || text == "0") return Result.okv<BoundValue>(BoundValue.ofBoolean(false));
        return Result.fail<BoundValue>("\"" + text + "\" is not a boolean (true, false, 1 or 0)");
    }
    if (kind == VmKind.Color) {
        const c = parseHexColor(text);
        if (c < 0) return Result.fail<BoundValue>("\"" + text + "\" is not a color (8 hex digits of ARGB, or 6 of RGB)");
        return Result.okv<BoundValue>(BoundValue.ofColor(<u32>c));
    }
    if (kind == VmKind.String) return Result.okv<BoundValue>(BoundValue.ofString(text));
    if (kind == VmKind.Enum) {
        const ks = keys != null ? keys : new Array<string>();
        const i = enumIndex(ks, text);
        if (i < 0) return Result.fail<BoundValue>("\"" + text + "\" is not one of: " + (ks.length > 0 ? ks.join(", ") : "(no keys)"));
        return Result.okv<BoundValue>(BoundValue.ofEnum(i, text));
    }
    const name = vmKindName(kind);
    const what = kind == VmKind.Other ? "a property of another kind" : (name.startsWith("e") ? "an " : "a ") + name + " property";
    return Result.fail<BoundValue>(what + " cannot be set: bindings take a number, a boolean, a color, a string or an enum");
}

// A whole number or a decimal, signed, with an exponent or not, and
// nothing before or after it: "12", "-0.5", ".5", "3.", "1e3". Not "inf",
// "nan", hex, or a number with spaces or trailing junk ("12px").
function isDecimal(s: string): bool {
    const n = s.length;
    let i = 0;
    if (i < n && (s.charCodeAt(i) == 0x2d || s.charCodeAt(i) == 0x2b)) i++;
    let digits = 0;
    while (i < n && isDigit(s.charCodeAt(i))) {
        i++;
        digits++;
    }
    if (i < n && s.charCodeAt(i) == 0x2e) {
        i++;
        while (i < n && isDigit(s.charCodeAt(i))) {
            i++;
            digits++;
        }
    }
    if (digits == 0) return false;
    if (i < n && (s.charCodeAt(i) == 0x65 || s.charCodeAt(i) == 0x45)) {
        i++;
        if (i < n && (s.charCodeAt(i) == 0x2d || s.charCodeAt(i) == 0x2b)) i++;
        let exp = 0;
        while (i < n && isDigit(s.charCodeAt(i))) {
            i++;
            exp++;
        }
        if (exp == 0) return false;
    }
    return i == n;
}

function isDigit(c: i32): bool {
    return c >= 0x30 && c <= 0x39;
}

function hexDigit(c: i32): i32 {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    return -1;
}

// 8 hex digits as ARGB, or 6 as RGB with alpha FF; -1 for anything else
// (a prefix such as # or 0x, another length, a non-hex digit).
function parseHexColor(s: string): i64 {
    if (s.length != 8 && s.length != 6) return -1;
    let v: i64 = 0;
    for (let i = 0; i < s.length; i++) {
        const d = hexDigit(s.charCodeAt(i));
        if (d < 0) return -1;
        v = (v << 4) | <i64>d;
    }
    if (s.length == 6) v |= 0xFF000000;
    return v;
}
