// Rive's data converters in the engine (docs/plans/RIVE_MODEL.md section
// 3.4, "Converters in the engine"): a binding's `converter` names one, the
// scene's own top-level converter first, then its data source's (the Rive
// project's RML); milestone 17's `scale`, `offset` and `convert` read as
// an implicit converter beside it (./binder.as). Each is evaluated forward
// (in the binding's main direction) and in reverse (the other way: a
// two_way bind's write back), as the runtime's DataConverter::convert and
// reverseConvert are (rive-runtime src/data_bind/converters/*.cpp, ported
// type by type: numbers as Rive's f32s, every default and flag the
// runtime's).
//
// What the runtime does, and this follows (src/data_bind/context/
// context_value.hpp calculateUntypedDataValue): a bind applies its
// converter's `convert` in its main direction and `reverseConvert` the
// other way. So a to_source bind (the node drives the view model) runs
// `convert` from the node to the view model, and only a two_way bind's
// write back runs `reverseConvert`. The two System converters
// (SystemDegsToRads, SystemNormalizer) look at the bind's main direction
// alone: on a to-target bind both their convert and their reverseConvert
// apply the operation, on a to-source bind both apply its inverse. A
// converter without a reverse of its own gives its input back unchanged,
// as the runtime's base class does.
//
// A converter is built per binding, since a time-based one (Interpolator)
// and a Formula's random numbers keep their own state, and advanced in the
// data binds' phase (../runtime/feature_bindings.as, PHASE_PULL). Building
// reads the declaration once; converting allocates nothing for numbers,
// booleans and colours (a string converter makes its new string when its
// result changes).
//
// Not ported: `interpolatorId` naming an RML interpolator element (a
// scene's converter may hold a CubicEaseInterpolator child instead;
// without one a RangeMapper and an Interpolator ease linearly, as the
// runtime does when the id names nothing), NumberToList, ListToLength and
// EnumToUint (lists), and ScriptedDataConverter: building those is
// binding-converter-unsupported. A Formula's random numbers come from a
// fixed xorshift sequence, not the runtime's generator.

import { VmKind, vmKindName } from "../riv/riv_info";
import { DataConverterDecl, isKnownConverter } from "../data/model";
import { DataSource } from "../data/source";
import { BoundValue, ViewModelValues } from "./values";

export abstract class Converter {
    // The converter's name ("" for the implicit one).
    name: string = "";
    // Milestone 42 (added to the agreed interface): whether the binding's
    // main direction is to source (Rive's DataBindFlags::ToSource), which
    // the System converters convert the other way for; setDirection sets
    // it through a group.
    toSource: bool = false;

    // In the binding's main direction: `input` converted into `out`. False
    // when the input is of a kind it does not take.
    abstract forward(input: BoundValue, out: BoundValue): bool;

    // The other way (reverseConvert). The runtime's base class gives the
    // input back unchanged, and so does every converter here that has no
    // reverse of its own.
    reverse(input: BoundValue, out: BoundValue): bool {
        out.copyFrom(input);
        return true;
    }

    // The kind it gives for an input of kind `input`, VmKind.Other when it
    // takes none such: what the binder checks a binding's kinds with.
    abstract outputKind(input: VmKind): VmKind;

    // Time passes (Interpolator): true when its output changed, so the
    // binding is pulled again though its source did not change.
    advance(seconds: f64): bool {
        return false;
    }

    // The view model values an OperationViewModel reads its operand from
    // (null: unbound).
    bind(values: ViewModelValues?): void {}

    // Milestone 42 (added): sets the main direction (see toSource).
    setDirection(toSource: bool): void {
        this.toSource = toSource;
    }

    // Milestone 42 (added): whether advance can change the output (an
    // Interpolator, or a group holding one), so that the binder advances
    // only those.
    timed(): bool {
        return false;
    }
}

// Where a converter's name is looked up: the scene's own converters, then
// its data source's.
export class ConverterLookup {
    scene: Array<DataConverterDecl> = [];
    source: DataSource? = null;

    find(name: string): DataConverterDecl? {
        for (let i = 0; i < this.scene.length; i++) if (this.scene[i].name == name) return this.scene[i];
        const s = this.source;
        return s != null ? s.converter(name) : null;
    }

    // Milestone 42 (added): the scene's converters' names, for a
    // binding-converter-unknown hint.
    names(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.scene.length; i++) if (!out.includes(this.scene[i].name)) out.push(this.scene[i].name);
        return out;
    }
}

// Why a converter could not be built: a diagnostic's code
// (binding-converter-unknown, binding-converter-unsupported,
// binding-converter-invalid, binding-converter-cycle), message and hint.
export class ConverterProblem {
    code: string = "";
    message: string = "";
    hint: string = "";
}

// Where the warnings send the reader.
const CONVERTER_DOC = "docs/engine/DATA.md \"Converters\"";

// The converter `decl` declares, its group's members looked up in
// `lookup`; null with `problem` filled in when it cannot be built.
export function buildConverter(decl: DataConverterDecl, lookup: ConverterLookup, problem: ConverterProblem): Converter? {
    return buildIn(decl, lookup, problem, []);
}

// Milestone 42 (added): buildConverter of the converter called `name`
// (lookup.find), or null with binding-converter-unknown.
export function buildNamedConverter(name: string, lookup: ConverterLookup, problem: ConverterProblem): Converter? {
    const d = lookup.find(name);
    if (d == null) {
        unknown(name, lookup, problem);
        return null;
    }
    return buildConverter(d, lookup, problem);
}

function unknown(name: string, lookup: ConverterLookup, problem: ConverterProblem): void {
    problem.code = "binding-converter-unknown";
    problem.message = "no converter \"" + name + "\"";
    const names = lookup.names();
    const s = lookup.source;
    problem.hint = (names.length > 0 ? "the scene's own converters: " + names.join(", ") + "; " : "the scene declares no converter; ")
        + (s != null ? sourceConverters(s) : "the scene has no data source to look in")
        + "; see " + CONVERTER_DOC;
}

// What a data source's converters are, for the hint: their names, or that
// it has none.
function sourceConverters(s: DataSource): string {
    const names = s.converterNames();
    return names.length > 0 ? "the converters of " + s.label + ": " + names.join(", ") : s.label + " declares no converter";
}

function fail(problem: ConverterProblem, code: string, message: string, hint: string): Converter? {
    problem.code = code;
    problem.message = message;
    problem.hint = hint;
    return null;
}

// buildConverter, `stack` the groups being built (a group in it again is a
// cycle).
function buildIn(decl: DataConverterDecl, lookup: ConverterLookup, problem: ConverterProblem, stack: Array<string>): Converter? {
    const t = decl.type;
    const what = "converter \"" + decl.name + "\" (" + t + ")";
    if (!isKnownConverter(t)) {
        return fail(problem, "binding-converter-unsupported", what + ", which 3D does not evaluate",
            "3D evaluates " + supportedText() + "; lists, EnumToUint and scripted converters are not evaluated yet");
    }
    const bound = boundParameter(decl);
    if (bound.length > 0) {
        // (Rive binds a converter's parameters, as it binds any property;
        // 3D reads them as written, and a value that should follow the
        // view model but holds still would convert wrongly without a word)
        return fail(problem, "binding-converter-unsupported", what + " binds a parameter (<" + bound + ">), which 3D does not evaluate yet",
            "give the parameter a value in place of the bind, or work the value out in the view model; see " + CONVERTER_DOC);
    }
    const stray = strayChild(decl);
    if (stray.length > 0) {
        // (a child the type does not read would be dropped without a word:
        // a group item misspelt as RML's converterId leaves the group
        // empty, the identity, and hides a cycle)
        if (stray == "DataConverterGroupItem") {
            return fail(problem, "binding-converter-invalid", what + " holds a <DataConverterGroupItem> it cannot read",
                "a group's item is written <DataConverterGroupItem converter=\"<name>\"/>, the converter's name and nothing else "
                + "(not RML's converterId); see " + CONVERTER_DOC);
        }
        return fail(problem, "binding-converter-invalid", what + " holds <" + stray + ">, which it does not read",
            "RangeMapper and Interpolator take a CubicEaseInterpolator child, Formula its tokens, a group its "
            + "<DataConverterGroupItem converter=\"<name>\"/> items, other converters no child; see " + CONVERTER_DOC);
    }
    const r = new AttrReader(decl);
    let c: Converter? = null;
    if (t == "DataConverterGroup") {
        if (stack.includes(decl.name)) {
            return fail(problem, "binding-converter-cycle", "converter group \"" + decl.name + "\" holds itself (through "
                + stack.join(" > ") + " > " + decl.name + ")", "a group's items name other converters: remove the one that leads back");
        }
        stack.push(decl.name);
        const g = new GroupConverter();
        for (let i = 0; i < decl.items.length; i++) {
            const name = decl.items[i];
            const d = lookup.find(name);
            if (d == null) {
                unknown(name, lookup, problem);
                problem.message = what + " names " + problem.message;
                stack.pop();
                return null;
            }
            const item = buildIn(d, lookup, problem, stack);
            if (item == null) {
                stack.pop();
                return null;
            }
            g.items.push(item);
        }
        stack.pop();
        c = g;
    } else if (t == "DataConverterOperation" || t == "DataConverterOperationValue") {
        c = new OperationConverter(r.op("operationType", OP_ADD), r.num("operationValue", 1));
    } else if (t == "DataConverterSystemDegsToRads" || t == "DataConverterSystemNormalizer") {
        const o = new OperationConverter(r.op("operationType", OP_ADD), r.num("operationValue", 1));
        o.system = true;
        c = o;
    } else if (t == "DataConverterOperationViewModel") {
        const path = decl.attr("path");
        if (path == null || path.length == 0) {
            const ids = decl.attr("sourcePathIds");
            return fail(problem, "binding-converter-invalid",
                what + (ids != null ? " names its operand by ids (sourcePathIds), which 3D cannot follow" : " names no operand"),
                "name the view model number it reads with path=\"<property path>\"");
        }
        c = new OperationViewModelConverter(r.op("operationType", OP_ADD), path);
    } else if (t == "DataConverterRangeMapper") {
        const m = new RangeMapperConverter();
        m.minInput = r.num("minInput", 1);
        m.maxInput = r.num("maxInput", 1);
        m.minOutput = r.num("minOutput", 1);
        m.maxOutput = r.num("maxOutput", 1);
        m.flags = r.flags(RANGE_FLAG_NAMES);
        m.interpolationType = r.choice("interpolationType", INTERPOLATION_NAMES, 1);
        m.ease = r.ease();
        c = m;
    } else if (t == "DataConverterRounder") {
        c = new RounderConverter(r.uint("decimals", 0));
    } else if (t == "DataConverterToString") {
        const s = new ToStringConverter();
        s.flags = r.flags(TO_STRING_FLAG_NAMES);
        s.decimals = r.uint("decimals", 0);
        const f = decl.attr("colorFormat");
        s.colorFormat = f != null ? f : "";
        c = s;
    } else if (t == "DataConverterToNumber") {
        c = new ToNumberConverter();
    } else if (t == "DataConverterStringPad") {
        const p = new StringPadConverter();
        p.length = r.uint("length", 1);
        const text = decl.attr("text");
        p.text = text != null ? text : "";
        p.padType = r.choice("padType", PAD_NAMES, 0);
        c = p;
    } else if (t == "DataConverterStringTrim") {
        c = new StringTrimConverter(r.choice("trimType", TRIM_NAMES, 1));
    } else if (t == "DataConverterStringRemoveZeros") {
        c = new RemoveZerosConverter();
    } else if (t == "DataConverterBooleanNegate") {
        c = new NegateConverter();
    } else if (t == "DataConverterTrigger") {
        c = new TriggerConverter();
    } else if (t == "DataConverterInterpolator") {
        const ip = new InterpolatorConverter();
        ip.duration = r.num("duration", 1);
        // (read for its check: the runtime eases by the interpolator alone)
        r.choice("interpolationType", INTERPOLATION_NAMES, 1);
        ip.ease = r.ease();
        c = ip;
    } else if (t == "DataConverterFormula") {
        const f = new FormulaConverter();
        f.randomMode = r.choice("randomModeValue", RANDOM_NAMES, 0);
        r.formula(f);
        c = f;
    }
    if (r.problem.length > 0) {
        return fail(problem, "binding-converter-invalid", what + ": " + r.problem,
            "`rive schema " + t + "` lists its attributes and the values they take");
    }
    if (c == null) return fail(problem, "binding-converter-unsupported", what + ", which 3D does not evaluate", "");
    c.name = decl.name;
    return c;
}

// The element of a data bind (RML's DataBind or DataBindContext) among
// `decl`'s children, a formula token's included; "" when it binds none.
function boundParameter(decl: DataConverterDecl): string {
    const kids = decl.children;
    for (let i = 0; i < kids.length; i++) {
        const k = kids[i];
        if (k.type.startsWith("DataBind")) return k.type;
        const inner = boundParameter(k);
        if (inner.length > 0) return inner;
    }
    return "";
}

// The element of the first child of `decl` its type does not read, ""
// when none: a Formula reads its tokens (formula() checks them), a
// RangeMapper and an Interpolator their interpolator (ease() checks it),
// every other converter, a group included (its items are not children),
// none.
function strayChild(decl: DataConverterDecl): string {
    const t = decl.type;
    if (t == "DataConverterFormula") return "";
    const eases = t == "DataConverterRangeMapper" || t == "DataConverterInterpolator";
    const kids = decl.children;
    for (let i = 0; i < kids.length; i++) {
        const k = kids[i].type;
        if (eases && k.endsWith("Interpolator")) continue;
        return k;
    }
    return "";
}

function supportedText(): string {
    return "the DataConverter types Operation, OperationValue, OperationViewModel, SystemDegsToRads, SystemNormalizer, "
        + "RangeMapper, Rounder, ToString, ToNumber, StringPad, StringTrim, StringRemoveZeros, BooleanNegate, Trigger, "
        + "Interpolator, Formula and Group";
}

// --- attributes ----------------------------------------------------------------

const OP_ADD: i32 = 0;
const OP_SUBTRACT: i32 = 1;
const OP_MULTIPLY: i32 = 2;
const OP_DIVIDE: i32 = 3;

// rive's ArithmeticOperation names, by value.
const OP_NAMES: StaticArray<string> = [
    "add", "subtract", "multiply", "divide", "modulo", "squareRoot", "power", "exp", "log", "cosine", "sine", "tangent",
    "acosine", "asine", "atangent", "atangent2", "round", "floor", "ceil",
];
// FormulaTokenFunction's functionType names, by value.
const FUNCTION_NAMES: StaticArray<string> = [
    "min", "max", "round", "ceil", "floor", "sqrt", "pow", "exp", "log", "cosine", "sine", "tangent", "acosine", "asine",
    "atangent", "atangent2", "random",
];
const INTERPOLATION_NAMES: StaticArray<string> = ["hold", "linear", "cubic", "cubicValue", "elastic", "scripted"];
const TRIM_NAMES: StaticArray<string> = ["none", "start", "end", "all"];
const PAD_NAMES: StaticArray<string> = ["start", "end"];
const RANDOM_NAMES: StaticArray<string> = ["once", "always", "sourceChange"];
// The flag bits, by bit: RangeMapper's (DataConverterRangeMapperFlags) and
// ToString's (DataConverterToStringFlags).
const RANGE_FLAG_NAMES: StaticArray<string> = ["clampLower", "clampUpper", "modulo", "reverse"];
const TO_STRING_FLAG_NAMES: StaticArray<string> = ["round", "trailingZeros", "formatWithCommas"];

const RANGE_CLAMP_LOWER: u32 = 1;
const RANGE_CLAMP_UPPER: u32 = 2;
const RANGE_MODULO: u32 = 4;
const RANGE_REVERSE: u32 = 8;
const TO_STRING_ROUND: u32 = 1;
const TO_STRING_TRAILING_ZEROS: u32 = 2;
const TO_STRING_COMMAS: u32 = 4;

// Reads a declaration's attributes as RML writes them (a number, a uint,
// an enum by name or value, flag bits as `flags` or one attribute each);
// the first value one refuses is `problem`.
class AttrReader {
    decl: DataConverterDecl;
    problem: string = "";

    constructor(decl: DataConverterDecl) {
        this.decl = decl;
    }

    private refuse(name: string, text: string, what: string): void {
        if (this.problem.length == 0) this.problem = name + "=\"" + text + "\" is not " + what;
    }

    num(name: string, def: f32): f32 {
        const t = this.decl.attr(name);
        if (t == null) return def;
        const x = parseNumber(t);
        if (isNaN(x)) {
            this.refuse(name, t, "a number");
            return def;
        }
        return <f32>x;
    }

    uint(name: string, def: u32): u32 {
        const t = this.decl.attr(name);
        if (t == null) return def;
        const x = parseNumber(t);
        if (isNaN(x) || x < 0 || x != Math.floor(x) || x > 4294967295) {
            this.refuse(name, t, "a whole number of 0 or more");
            return def;
        }
        return <u32>x;
    }

    // An enum written by name or by value.
    choice(name: string, names: StaticArray<string>, def: i32): i32 {
        const t = this.decl.attr(name);
        if (t == null) return def;
        for (let i = 0; i < names.length; i++) if (names[i] == t) return i;
        const x = parseNumber(t);
        if (!isNaN(x) && x >= 0 && x == Math.floor(x) && x < <f64>names.length) return <i32>x;
        this.refuse(name, t, "one of " + names.join(", "));
        return def;
    }

    op(name: string, def: i32): i32 {
        return this.choice(name, OP_NAMES, def);
    }

    // `flags` (a uint), each named bit written as its own attribute
    // (`clampLower="true"`) setting or clearing its bit over it.
    flags(names: StaticArray<string>): u32 {
        let f = this.uint("flags", 0);
        for (let i = 0; i < names.length; i++) {
            const t = this.decl.attr(names[i]);
            if (t == null) continue;
            if (t == "true" || t == "1") f |= <u32>1 << <u32>i;
            else if (t == "false" || t == "0") f &= ~(<u32>1 << <u32>i);
            else this.refuse(names[i], t, "true or false");
        }
        return f;
    }

    // The CubicEaseInterpolator child (x1, y1, x2, y2), or null: linear.
    ease(): CubicEase? {
        const kids = this.decl.children;
        for (let i = 0; i < kids.length; i++) {
            const k = kids[i];
            if (k.type != "CubicEaseInterpolator") {
                if (k.type.endsWith("Interpolator") && this.problem.length == 0) {
                    this.problem = k.type + " is not evaluated in 3D (a CubicEaseInterpolator is)";
                }
                continue;
            }
            const r = new AttrReader(k);
            const e = new CubicEase(r.num("x1", 0.42), r.num("y1", 0), r.num("x2", 0.58), r.num("y2", 1));
            if (r.problem.length > 0 && this.problem.length == 0) this.problem = "CubicEaseInterpolator: " + r.problem;
            return e;
        }
        return null;
    }

    // A Formula's tokens: its children, in order.
    formula(f: FormulaConverter): void {
        const kids = this.decl.children;
        for (let i = 0; i < kids.length; i++) {
            const k = kids[i];
            const r = new AttrReader(k);
            const t = k.type;
            let kind = -1;
            let value: f32 = 0;
            if (t == "FormulaTokenInput") kind = TOKEN_INPUT;
            else if (t == "FormulaTokenValue") {
                kind = TOKEN_VALUE;
                value = r.num("operationValue", 1);
            } else if (t == "FormulaTokenOperation") {
                kind = TOKEN_OPERATION;
                value = <f32>r.op("operationType", 0);
            } else if (t == "FormulaTokenFunction") {
                kind = TOKEN_FUNCTION;
                value = <f32>r.choice("functionType", FUNCTION_NAMES, 0);
            } else if (t == "FormulaTokenParenthesisOpen") kind = TOKEN_OPEN;
            else if (t == "FormulaTokenParenthesisClose") kind = TOKEN_CLOSE;
            else if (t == "FormulaTokenArgumentSeparator") kind = TOKEN_SEPARATOR;
            else if (this.problem.length == 0) this.problem = "<" + t + "> is not a formula token";
            if (r.problem.length > 0 && this.problem.length == 0) this.problem = t + ": " + r.problem;
            if (kind >= 0) f.tokens.push(new FormulaToken(kind, value));
        }
        f.prepare();
    }
}

// A number as RML writes one ("0.5", "-2", "1e3"), NaN for anything else.
export function parseNumber(t: string): f64 {
    if (t.length == 0) return NaN;
    for (let i = 0; i < t.length; i++) {
        const c = t.charCodeAt(i);
        const ok = (c >= 0x30 && c <= 0x39) || c == 0x2e || c == 0x2d || c == 0x2b || c == 0x65 || c == 0x45;
        if (!ok) return NaN;
    }
    const x = parseFloat(t);
    return isFinite(x) ? x : NaN;
}

// --- arithmetic, in the runtime's floats -----------------------------------

// C's roundf: half away from zero.
export function roundF(x: f32): f32 {
    const t = Mathf.trunc(x);
    const d = x - t;
    if (d >= 0.5) return t + 1;
    if (d <= -0.5) return t - 1;
    return t;
}

// rive's math::positive_mod (Dart's %): never negative, the range's sign
// dropped.
export function positiveMod(value: f32, range: f32): f32 {
    const r = range < 0 ? -range : range;
    let v = fmodF(value, r);
    if (v < 0) v += r;
    return v;
}

// C's fmodf (the sign of x; NaN for a zero range).
function fmodF(x: f32, y: f32): f32 {
    return <f32>(<f64>x % <f64>y);
}

// One ArithmeticOperation of `input` with `value`, as
// DataConverterOperation::convertValue (the transcendental ones through
// C's double functions, as its unqualified calls are).
export function applyOp(op: i32, input: f32, value: f32): f32 {
    switch (op) {
        case 0: return input + value;
        case 1: return input - value;
        case 2: return input * value;
        case 3: return input / value;
        case 4: return positiveMod(input, value);
        case 5: return Mathf.sqrt(input);
        case 6: return Mathf.pow(input, value);
        case 7: return <f32>Math.exp(input);
        case 8: return <f32>Math.log(input);
        case 9: return <f32>Math.cos(input);
        case 10: return <f32>Math.sin(input);
        case 11: return <f32>Math.tan(input);
        case 12: return <f32>Math.acos(input);
        case 13: return <f32>Math.asin(input);
        case 14: return <f32>Math.atan(input);
        case 15: return <f32>Math.atan2(input, value);
        case 16: return roundF(input);
        case 17: return Mathf.floor(input);
        case 18: return Mathf.ceil(input);
        default: return value;
    }
}

// Its inverse, as DataConverterOperation::reverseConvertValue (modulo,
// atan2 and the roundings give the input back).
export function reverseOp(op: i32, input: f32, value: f32): f32 {
    switch (op) {
        case 0: return input - value;
        case 1: return input + value;
        case 2: return input / value;
        case 3: return input * value;
        case 5: return Mathf.pow(input, 2);
        case 6: return Mathf.pow(input, 1 / value);
        case 7: return <f32>Math.log(input);
        case 8: return <f32>Math.exp(input);
        case 9: return <f32>Math.acos(input);
        case 10: return <f32>Math.asin(input);
        case 11: return <f32>Math.atan(input);
        case 12: return <f32>Math.cos(input);
        case 13: return <f32>Math.sin(input);
        case 14: return <f32>Math.tan(input);
        default: return input;
    }
}

// --- the converters ------------------------------------------------------------

// What a number converter takes: a number (anything else gives the
// runtime's default 0, which the binder calls a kind it does not take).
function numberIn(k: VmKind): VmKind {
    return k == VmKind.Number ? VmKind.Number : VmKind.Other;
}

// OperationValue (and Operation), forward its operation, in reverse the
// inverse; the System pair (`system`) by the bind's main direction alone:
// the operation on a to-target bind, the inverse on a to-source one, both
// ways (see the header).
export class OperationConverter extends Converter {
    op: i32;
    value: f32;
    system: bool = false;

    constructor(op: i32, value: f32) {
        super();
        this.op = op;
        this.value = value;
    }

    forward(input: BoundValue, out: BoundValue): bool {
        return this.system && this.toSource ? this.inverse(input, out) : this.apply(input, out);
    }

    reverse(input: BoundValue, out: BoundValue): bool {
        if (this.system) return this.toSource ? this.inverse(input, out) : this.apply(input, out);
        return this.inverse(input, out);
    }

    // The right-hand side.
    protected operand(): f32 {
        return this.value;
    }

    protected apply(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.Number) {
            out.setNumber(0);
            return false;
        }
        out.setNumber(<f64>applyOp(this.op, <f32>input.number, this.operand()));
        return true;
    }

    // (reverseConvertValue leaves a non-number unconverted)
    protected inverse(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.Number) {
            out.setNumber(0);
            return false;
        }
        out.setNumber(<f64>reverseOp(this.op, <f32>input.number, this.operand()));
        return true;
    }

    outputKind(input: VmKind): VmKind {
        return numberIn(input);
    }
}

// OperationViewModel: the right-hand side is a view model number at
// `path`, read each time (0 while unbound or absent, as the runtime's).
export class OperationViewModelConverter extends OperationConverter {
    path: string;
    values: ViewModelValues? = null;
    private scratch: BoundValue = new BoundValue();

    constructor(op: i32, path: string) {
        super(op, 0);
        this.path = path;
    }

    bind(values: ViewModelValues?): void {
        this.values = values;
    }

    protected operand(): f32 {
        const v = this.values;
        if (v == null || !v.read(this.path, this.scratch) || this.scratch.kind != VmKind.Number) return 0;
        return <f32>this.scratch.number;
    }
}

// A cubic ease (CubicEaseInterpolator: x1, y1, x2, y2), solved as the
// runtime's CubicInterpolatorSolver: an 11-sample table, then Newton's
// method or bisection.
export class CubicEase {
    x1: f32;
    y1: f32;
    x2: f32;
    y2: f32;
    private values: StaticArray<f32> = new StaticArray<f32>(11);

    constructor(x1: f32, y1: f32, x2: f32, y2: f32) {
        this.x1 = x1;
        this.y1 = y1;
        this.x2 = x2;
        this.y2 = y2;
        for (let i = 0; i < 11; i++) this.values[i] = calcBezier(<f32>i * SAMPLE_STEP, x1, x2);
    }

    transform(f: f32): f32 {
        return calcBezier(this.getT(f), this.y1, this.y2);
    }

    private getT(x: f32): f32 {
        let start: f32 = 0;
        let current = 1;
        const last = 10;
        for (; current != last && this.values[current] <= x; ++current) start += SAMPLE_STEP;
        --current;
        const dist = (x - this.values[current]) / (this.values[current + 1] - this.values[current]);
        let guess = start + dist * SAMPLE_STEP;
        const slope = getSlope(guess, this.x1, this.x2);
        if (slope >= <f32>0.001) {
            for (let i = 0; i < 4; i++) {
                const s = getSlope(guess, this.x1, this.x2);
                if (s == 0) return guess;
                const cx = calcBezier(guess, this.x1, this.x2) - x;
                guess -= cx / s;
            }
            return guess;
        }
        if (slope == 0) return guess;
        let b = start + SAMPLE_STEP;
        let t: f32 = 0;
        let i = 0;
        do {
            t = start + (b - start) / 2;
            const cx = calcBezier(t, this.x1, this.x2) - x;
            if (cx > 0) b = t;
            else start = t;
            if (Mathf.abs(cx) <= <f32>0.0000001) break;
        } while (++i < 10);
        return t;
    }
}

const SAMPLE_STEP: f32 = 0.1;

function calcBezier(t: f32, a1: f32, a2: f32): f32 {
    return (((<f32>1 - <f32>3 * a2 + <f32>3 * a1) * t + (<f32>3 * a2 - <f32>6 * a1)) * t + (<f32>3 * a1)) * t;
}

function getSlope(t: f32, a1: f32, a2: f32): f32 {
    return <f32>3 * (<f32>1 - <f32>3 * a2 + <f32>3 * a1) * t * t + <f32>2 * (<f32>3 * a2 - <f32>6 * a1) * t + <f32>3 * a1;
}

// DataConverterRangeMapper: the input range onto the output range, with
// its flags (clamp lower and upper, wrap, reverse), an ease, or hold; in
// reverse the ranges swap.
export class RangeMapperConverter extends Converter {
    minInput: f32 = 1;
    maxInput: f32 = 1;
    minOutput: f32 = 1;
    maxOutput: f32 = 1;
    flags: u32 = 0;
    interpolationType: i32 = 1;
    ease: CubicEase? = null;

    forward(input: BoundValue, out: BoundValue): bool {
        return this.range(input, out, this.minInput, this.maxInput, this.minOutput, this.maxOutput);
    }

    reverse(input: BoundValue, out: BoundValue): bool {
        return this.range(input, out, this.minOutput, this.maxOutput, this.minInput, this.maxInput);
    }

    // DataConverterRangeMapper::calculateRange.
    private range(input: BoundValue, out: BoundValue, minIn: f32, maxIn: f32, minOut: f32, maxOut: f32): bool {
        if (input.kind != VmKind.Number) {
            out.setNumber(0);
            return false;
        }
        if (minOut == maxOut) {
            out.setNumber(<f64>minOut);
            return true;
        }
        const f = this.flags;
        let value = <f32>input.number;
        if (value < minIn && (f & RANGE_CLAMP_LOWER) != 0) value = minIn;
        else if (value > maxIn && (f & RANGE_CLAMP_UPPER) != 0) value = maxIn;
        if ((value < minIn || value > maxIn) && (f & RANGE_MODULO) != 0) {
            value = Mathf.abs(positiveMod(value, maxIn - minIn) + minIn);
        }
        let perc = (value - minIn) / (maxIn - minIn);
        if ((f & RANGE_REVERSE) != 0) perc = 1 - perc;
        const e = this.ease;
        if (e != null && perc > 0 && perc < 1) perc = e.transform(perc);
        else if (this.interpolationType == 0) perc = perc <= 0 ? <f32>0 : <f32>1;
        out.setNumber(<f64>(perc * maxOut + (1 - perc) * minOut));
        return true;
    }

    outputKind(input: VmKind): VmKind {
        return numberIn(input);
    }
}

// DataConverterRounder: to `decimals` places (round(x * 10^d) / 10^d, in
// floats).
export class RounderConverter extends Converter {
    decimals: u32;

    constructor(decimals: u32) {
        super();
        this.decimals = decimals;
    }

    forward(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.Number) {
            out.setNumber(0);
            return false;
        }
        const rounder = Mathf.pow(10, <f32>this.decimals);
        out.setNumber(<f64>(roundF(<f32>input.number * rounder) / rounder));
        return true;
    }

    outputKind(input: VmKind): VmKind {
        return numberIn(input);
    }
}

// DataConverterToString: a number as C's "%f" (or "%.<decimals>f" with
// `round`), its trailing zeros dropped with `trailingZeros`, commas with
// `formatWithCommas`; an enum its key; a colour by `colorFormat` (else the
// signed int it is); a boolean "1" or "0".
export class ToStringConverter extends Converter {
    flags: u32 = 0;
    decimals: u32 = 0;
    colorFormat: string = "";

    forward(input: BoundValue, out: BoundValue): bool {
        const k = input.kind;
        if (k == VmKind.Number) {
            const x = <f64><f32>input.number;
            let s = (this.flags & TO_STRING_ROUND) != 0 ? fixed(x, <i32>min<u32>(this.decimals, 20)) : fixed(x, 6);
            if ((this.flags & TO_STRING_TRAILING_ZEROS) != 0) s = removeZeros(s);
            if ((this.flags & TO_STRING_COMMAS) != 0) s = withCommas(s);
            setText(out, s);
        } else if (k == VmKind.Enum || k == VmKind.String) setText(out, input.text);
        else if (k == VmKind.Color) {
            setText(out, this.colorFormat.length > 0 ? formatColor(this.colorFormat, input.color) : (<i32>input.color).toString());
        } else if (k == VmKind.Boolean) setText(out, input.boolean ? "1" : "0");
        else if (k == VmKind.Trigger) setText(out, (<u32>input.number).toString());
        else {
            setText(out, "");
            return false;
        }
        return true;
    }

    outputKind(input: VmKind): VmKind {
        const ok = input == VmKind.Number || input == VmKind.Enum || input == VmKind.String || input == VmKind.Color
            || input == VmKind.Boolean || input == VmKind.Trigger;
        return ok ? VmKind.String : VmKind.Other;
    }
}

// Sets `out` to the string `s` (an unchanged string keeps the one held).
function setText(out: BoundValue, s: string): void {
    if (out.kind == VmKind.String && out.text == s) return;
    out.setString(s);
}

// `x` with `d` decimals, as C's "%.<d>f" (std::to_string is d = 6): the
// exact binary value's decimal digits, rounded at the last place half to
// even as libc does, so 2.5 at 0 decimals is "2" and 1/128 at 6 is
// "0.007812", the same text the 2D side shows. The fraction is held as
// m / 2^k with k at most 60 bits; a fraction with more bits (below about
// 1e-3 with a full mantissa) loses them, which shows only past the 18th
// decimal.
export function fixed(x: f64, d: i32): string {
    if (isNaN(x)) return "nan";
    if (!isFinite(x)) return x < 0 ? "-inf" : "inf";
    const neg = x < 0;
    const a = Math.abs(x);
    if (a >= 9.007199254740992e15) {
        // No fraction is left at 2^53: the integer digits as f64 prints
        // them, then zeros.
        let whole = a.toString();
        if (whole.indexOf("e") >= 0) whole = expandExponent(whole);
        const dot = whole.indexOf(".");
        if (dot >= 0) whole = whole.substring(0, dot);
        return (neg ? "-" : "") + whole + (d > 0 ? "." + "0".repeat(d) : "");
    }
    const floor = Math.floor(a);
    let whole = <u64>floor;
    // Doubling is exact, so the fraction's bits come out one at a time.
    let frac = a - floor;
    let k = 0;
    while (frac != Math.floor(frac) && k < 60) {
        frac *= 2;
        k++;
    }
    let m = <u64>frac;
    const mask: u64 = k == 0 ? 0 : (<u64>1 << <u64>k) - 1;
    const places = d > 0 ? d : 0;
    const digits = new Array<i32>(places);
    for (let i = 0; i < places; i++) {
        m *= 10;
        digits[i] = <i32>(m >> <u64>k);
        m &= mask;
    }
    // The rest decides the last place: above half up, exactly half to even.
    let up = false;
    if (k > 0) {
        const half: u64 = <u64>1 << <u64>(k - 1);
        const last = places > 0 ? <u64>digits[places - 1] : whole;
        up = m > half || (m == half && (last & 1) == 1);
    }
    if (up) {
        let i = places - 1;
        while (i >= 0 && digits[i] == 9) {
            digits[i] = 0;
            i--;
        }
        if (i >= 0) digits[i] = digits[i] + 1;
        else whole++;
    }
    let out = (neg ? "-" : "") + whole.toString();
    if (places > 0) {
        out += ".";
        for (let i = 0; i < places; i++) out += String.fromCharCode(0x30 + digits[i]);
    }
    return out;
}

// "1.5e+20" as "150000000000000000000".
function expandExponent(s: string): string {
    const e = s.indexOf("e");
    let mant = s.substring(0, e);
    const exp = I32.parseInt(s.substring(e + 1));
    const dot = mant.indexOf(".");
    let frac = 0;
    if (dot >= 0) {
        frac = mant.length - dot - 1;
        mant = mant.substring(0, dot) + mant.substring(dot + 1);
    }
    const zeros = exp - frac;
    return zeros >= 0 ? mant + "0".repeat(zeros) : mant;
}

// DataConverterStringRemoveZeros::removeZeros: a decimal's trailing zeros,
// then a trailing point.
export function removeZeros(s: string): string {
    if (!s.includes(".")) return s;
    let end = s.length;
    while (end > 0 && s.charCodeAt(end - 1) == 0x30) end--;
    let out = s.substring(0, end);
    if (out.indexOf(".") == out.length - 1) out = out.substring(0, out.length - 1);
    return out;
}

// DataConverterToString::formatWithCommas.
export function withCommas(num: string): string {
    const dot = num.indexOf(".");
    let intPart = dot >= 0 ? num.substring(0, dot) : num;
    const fracPart = dot >= 0 ? num.substring(dot) : "";
    let at = intPart.length - 3;
    while (at > 0 && isDigit(intPart.charCodeAt(at - 1))) {
        intPart = intPart.substring(0, at) + "," + intPart.substring(at);
        at -= 3;
    }
    return intPart + fracPart;
}

function isDigit(c: i32): bool {
    return c >= 0x30 && c <= 0x39;
}

function hex2(v: u32): string {
    const s = v.toString(16).toUpperCase();
    return s.length < 2 ? "0" + s : s;
}

// DataConverterToString::convertColor with a colorFormat: %r %g %b %a the
// channels, %R %G %B %A in hex, %h %l %s hue, lightness and saturation,
// %% a percent sign, \ escaping the next character.
export function formatColor(format: string, argb: u32): string {
    const a = (argb >> 24) & 0xff;
    const r = (argb >> 16) & 0xff;
    const g = (argb >> 8) & 0xff;
    const b = argb & 0xff;
    let out = "";
    let escaped = false;
    let marker = false;
    let hsl: StaticArray<i32>? = null;
    for (let i = 0; i < format.length; i++) {
        const c = format.charAt(i);
        if (escaped) {
            out += c;
            escaped = false;
        } else if (c == "\\") {
            if (marker) {
                out += "%";
                marker = false;
            }
            escaped = true;
        } else if (c == "%") {
            if (marker) out += "%";
            marker = true;
        } else if (marker) {
            if (c == "r") out += r.toString();
            else if (c == "g") out += g.toString();
            else if (c == "b") out += b.toString();
            else if (c == "a") out += a.toString();
            else if (c == "R") out += hex2(r);
            else if (c == "G") out += hex2(g);
            else if (c == "B") out += hex2(b);
            else if (c == "A") out += hex2(a);
            else if (c == "h" || c == "l" || c == "s") {
                if (hsl == null) hsl = hslOf(r, g, b);
                const v = hsl as StaticArray<i32>;
                out += (c == "h" ? v[0] : c == "l" ? v[1] : v[2]).toString();
            } else out += "%" + c;
            marker = false;
        } else out += c;
    }
    return out;
}

// _ColorConverter::calculateHSL: hue in degrees, lightness and saturation
// in percent, rounded.
function hslOf(ri: u32, gi: u32, bi: u32): StaticArray<i32> {
    const r = <f32>ri / 255;
    const g = <f32>gi / 255;
    const b = <f32>bi / 255;
    const mx = max<f32>(max<f32>(r, g), b);
    const mn = min<f32>(min<f32>(r, g), b);
    const delta = mx - mn;
    let hue: f32 = 0;
    if (delta != 0) {
        if (mx == r) hue = fmodF((g - b) / delta, 6);
        else if (mx == g) hue = (b - r) / delta + 2;
        else hue = (r - g) / delta + 4;
    }
    let h = <i32>roundF(hue * 60);
    if (h < 0) h += 360;
    const lum = (mx + mn) / 2;
    const sat = delta == 0 ? <f32>0 : delta / (1 - Mathf.abs(2 * lum - 1));
    const out = new StaticArray<i32>(3);
    out[0] = h;
    out[1] = <i32>roundF(lum * 100);
    out[2] = <i32>roundF(sat * 100);
    return out;
}

// DataConverterToNumber: a string by C's atof, an enum its index, a colour
// the signed int it is held in, a boolean 1 or 0.
export class ToNumberConverter extends Converter {
    forward(input: BoundValue, out: BoundValue): bool {
        const k = input.kind;
        if (k == VmKind.String) out.setNumber(<f64><f32>atof(input.text));
        else if (k == VmKind.Enum) out.setNumber(input.number);
        else if (k == VmKind.Number) out.setNumber(input.number);
        else if (k == VmKind.Color) out.setNumber(<f64><f32><i32>input.color);
        else if (k == VmKind.Boolean) out.setNumber(input.boolean ? 1 : 0);
        else {
            out.setNumber(0);
            return false;
        }
        return true;
    }

    outputKind(input: VmKind): VmKind {
        const ok = input == VmKind.String || input == VmKind.Enum || input == VmKind.Number || input == VmKind.Color
            || input == VmKind.Boolean;
        return ok ? VmKind.Number : VmKind.Other;
    }
}

// C's atof: leading space skipped, the longest decimal prefix read (0 when
// there is none), inf and nan as words, and hexadecimal ("0x1A", "0x1.8p1")
// as strtod reads it.
export function atof(s: string): f64 {
    let i = 0;
    const n = s.length;
    while (i < n && isSpace(s.charCodeAt(i))) i++;
    const start = i;
    if (i < n && (s.charCodeAt(i) == 0x2b || s.charCodeAt(i) == 0x2d)) i++;
    const word = s.substring(i, min<i32>(i + 3, n)).toLowerCase();
    const neg = start < n && s.charCodeAt(start) == 0x2d;
    if (word == "inf") return neg ? -Infinity : Infinity;
    if (word == "nan") return NaN;
    if (i + 2 < n && s.charCodeAt(i) == 0x30 && (s.charCodeAt(i + 1) | 0x20) == 0x78) {
        const hex = hexPrefix(s, i + 2);
        if (hex.length > 0) return neg ? -hex[0] : hex[0];
    }
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
    if (digits == 0) return 0;
    let end = i;
    if (i < n && (s.charCodeAt(i) == 0x65 || s.charCodeAt(i) == 0x45)) {
        let j = i + 1;
        if (j < n && (s.charCodeAt(j) == 0x2b || s.charCodeAt(j) == 0x2d)) j++;
        const at = j;
        while (j < n && isDigit(s.charCodeAt(j))) j++;
        if (j > at) end = j;
    }
    return parseFloat(s.substring(start, end));
}

// The value of the hexadecimal float at `i` (after "0x") as one element,
// or none when no hex digit follows.
function hexPrefix(s: string, i: i32): f64[] {
    const n = s.length;
    let value: f64 = 0;
    let scale: f64 = 1;
    let digits = 0;
    let seenDot = false;
    while (i < n) {
        const c = s.charCodeAt(i);
        const v = hexValue(c);
        if (v >= 0) {
            if (seenDot) {
                scale /= 16;
                value += <f64>v * scale;
            } else value = value * 16 + <f64>v;
            digits++;
        } else if (c == 0x2e && !seenDot) seenDot = true;
        else break;
        i++;
    }
    if (digits == 0) return [];
    if (i < n && (s.charCodeAt(i) | 0x20) == 0x70) {
        let j = i + 1;
        let expNeg = false;
        if (j < n && (s.charCodeAt(j) == 0x2b || s.charCodeAt(j) == 0x2d)) {
            expNeg = s.charCodeAt(j) == 0x2d;
            j++;
        }
        let e = 0;
        const at = j;
        while (j < n && isDigit(s.charCodeAt(j)) && e < 100000) {
            e = e * 10 + (s.charCodeAt(j) - 0x30);
            j++;
        }
        if (j > at) value *= Math.pow(2, <f64>(expNeg ? -e : e));
    }
    return [value];
}

function hexValue(c: i32): i32 {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    const l = c | 0x20;
    if (l >= 0x61 && l <= 0x66) return l - 0x61 + 10;
    return -1;
}

function isSpace(c: i32): bool {
    return c == 0x20 || (c >= 0x09 && c <= 0x0d);
}

// DataConverterStringPad: `text` repeated before (padType start) or after
// (end) a string shorter than `length`, up to it. Lengths are UTF-8 bytes,
// as the runtime's std::string counts them, so "é" is two long and pads
// the same on both sides (a cut through a character included).
export class StringPadConverter extends Converter {
    length: u32 = 1;
    text: string = "";
    padType: i32 = 0;

    forward(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.String) {
            setText(out, "");
            return false;
        }
        const value = input.text;
        const have = String.UTF8.byteLength(value);
        const want = <i32>this.length;
        const patLen = String.UTF8.byteLength(this.text);
        if (have >= want || patLen == 0) {
            setText(out, value);
            return true;
        }
        const pattern = Uint8Array.wrap(String.UTF8.encode(this.text));
        const body = Uint8Array.wrap(String.UTF8.encode(value));
        const padSize = want - have;
        const bytes = new Uint8Array(want);
        const padAt = this.padType == 1 ? have : 0;
        for (let i = 0; i < padSize; i++) bytes[padAt + i] = pattern[i % patLen];
        const bodyAt = this.padType == 1 ? 0 : padSize;
        for (let i = 0; i < have; i++) bytes[bodyAt + i] = body[i];
        setText(out, String.UTF8.decode(bytes.buffer));
        return true;
    }

    outputKind(input: VmKind): VmKind {
        return input == VmKind.String ? VmKind.String : VmKind.Other;
    }
}

// DataConverterStringTrim: white space off the start, the end or both.
export class StringTrimConverter extends Converter {
    trimType: i32;

    constructor(trimType: i32) {
        super();
        this.trimType = trimType;
    }

    forward(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.String) {
            setText(out, "");
            return false;
        }
        const s = input.text;
        let a = 0;
        let b = s.length;
        const t = this.trimType;
        if (t == 1 || t == 3) while (a < b && isSpace(s.charCodeAt(a))) a++;
        if (t == 2 || t == 3) while (b > a && isSpace(s.charCodeAt(b - 1))) b--;
        setText(out, a == 0 && b == s.length ? s : s.substring(a, b));
        return true;
    }

    outputKind(input: VmKind): VmKind {
        return input == VmKind.String ? VmKind.String : VmKind.Other;
    }
}

export class RemoveZerosConverter extends Converter {
    forward(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.String) {
            setText(out, "");
            return false;
        }
        setText(out, removeZeros(input.text));
        return true;
    }

    outputKind(input: VmKind): VmKind {
        return input == VmKind.String ? VmKind.String : VmKind.Other;
    }
}

// DataConverterBooleanNegate, both ways.
export class NegateConverter extends Converter {
    forward(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.Boolean) {
            out.setBoolean(false);
            return false;
        }
        out.setBoolean(!input.boolean);
        return true;
    }

    reverse(input: BoundValue, out: BoundValue): bool {
        return this.forward(input, out);
    }

    outputKind(input: VmKind): VmKind {
        return input == VmKind.Boolean ? VmKind.Boolean : VmKind.Other;
    }
}

// DataConverterTrigger: a whole number in, a trigger's count (it plus one)
// out.
export class TriggerConverter extends Converter {
    forward(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.Number && input.kind != VmKind.Trigger) {
            out.setTrigger(0);
            return false;
        }
        // The runtime takes an unsigned count; a negative, NaN or infinite
        // number counts as 0 here rather than trapping the conversion.
        const n = input.number;
        const count: u32 = n >= 0 && n < 4294967296.0 ? <u32>n : n >= 4294967296.0 && isFinite(n) ? 0xffffffff : 0;
        out.setTrigger(<f64>(count + 1));
        return true;
    }

    outputKind(input: VmKind): VmKind {
        return input == VmKind.Number || input == VmKind.Trigger ? VmKind.Trigger : VmKind.Other;
    }
}

// --- Interpolator --------------------------------------------------------------

// One animation of the advancer (InterpolatorAnimationData).
class InterpData {
    elapsed: f32 = 0;
    from: BoundValue = new BoundValue();
    to: BoundValue = new BoundValue();

    copy(o: InterpData): void {
        this.from.copyFrom(o.from);
        this.to.copyFrom(o.to);
        this.elapsed = o.elapsed;
    }

    interpolate(f: f32, store: BoundValue): void {
        lerpInto(this.from, this.to, f, store);
    }
}

// DataValueNumber::interpolate and DataValueColor's (colorLerp).
function lerpInto(from: BoundValue, to: BoundValue, f: f32, store: BoundValue): void {
    if (from.kind == VmKind.Color) {
        store.setColor(colorLerp(from.color, to.color, f));
        return;
    }
    const fi: f32 = 1 - f;
    store.setNumber(<f64>(<f32>to.number * f + <f32>from.number * fi));
}

function channelLerp(a: u32, b: u32, mix: f32): u32 {
    const x = <f32>a * (1 - mix) + <f32>b * mix;
    return <u32>roundF(max<f32>(0, min<f32>(255, x)));
}

// rive's colorLerp: each channel mixed, rounded and clamped to 0..255.
export function colorLerp(from: u32, to: u32, mix: f32): u32 {
    return (channelLerp((from >> 24) & 0xff, (to >> 24) & 0xff, mix) << 24)
        | (channelLerp((from >> 16) & 0xff, (to >> 16) & 0xff, mix) << 16)
        | (channelLerp((from >> 8) & 0xff, (to >> 8) & 0xff, mix) << 8)
        | channelLerp(from & 0xff, to & 0xff, mix);
}

// A number or a colour compared as DataValue::compare does (exactly).
function sameValue(a: BoundValue, b: BoundValue): bool {
    if (a.kind != b.kind) return false;
    return a.kind == VmKind.Color ? a.color == b.color : a.number == b.number;
}

// DataConverterInterpolator and its InterpolatorAdvancer: the output eases
// from where it is to each new input over `duration` seconds; a new input
// while it eases starts a second animation that smooths from the first.
// Until two advances with time have passed, the output jumps to the input
// (the runtime's first run).
export class InterpolatorConverter extends Converter {
    duration: f32 = 1;
    ease: CubicEase? = null;
    private initialized: bool = false;
    private advanceCount: i32 = 0;
    private a: InterpData = new InterpData();
    private b: InterpData = new InterpData();
    private smoothing: bool = false;
    private current: BoundValue = new BoundValue();

    timed(): bool {
        return true;
    }

    private data(): InterpData {
        return this.smoothing ? this.b : this.a;
    }

    private eased(f: f32): f32 {
        const e = this.ease;
        return e != null ? e.transform(f) : f;
    }

    private resetValues(input: BoundValue): void {
        const d = this.data();
        d.from.copyFrom(input);
        d.to.copyFrom(input);
        this.current.copyFrom(input);
    }

    private updateValues(input: BoundValue): void {
        let d = this.data();
        if (sameValue(input, d.to)) return;
        if (d.elapsed != 0) {
            if (this.smoothing) this.a.copy(this.b);
            this.smoothing = true;
        } else {
            this.smoothing = false;
        }
        d = this.data();
        d.from.copyFrom(this.current);
        d.to.copyFrom(input);
        d.elapsed = 0;
    }

    forward(input: BoundValue, out: BoundValue): bool {
        const k = input.kind;
        if (this.duration == 0 && this.initialized) {
            this.resetValues(input);
            this.smoothing = false;
            this.a.elapsed = 0;
            this.b.elapsed = 0;
            out.copyFrom(input);
            return true;
        }
        if (k != VmKind.Number && k != VmKind.Color) {
            out.copyFrom(input);
            return true;
        }
        if (!this.initialized) {
            this.initialized = true;
            this.resetValues(input);
        }
        if (this.advanceCount < 2) this.resetValues(input);
        else this.updateValues(input);
        out.copyFrom(this.current);
        return true;
    }

    reverse(input: BoundValue, out: BoundValue): bool {
        return this.forward(input, out);
    }

    // InterpolatorAdvancer::advance: true while its output moved (the
    // runtime marks the bind dirty then).
    advance(seconds: f64): bool {
        const dt = <f32>seconds;
        if (this.advanceCount < 2 && dt > 0) this.advanceCount++;
        if (!this.initialized) return false;
        const d = this.data();
        if (sameValue(d.to, this.current) || dt == 0) return false;
        const prev = d.elapsed;
        this.advanceData(dt);
        return prev < this.duration;
    }

    // InterpolatorAdvancer::advanceAnimationData.
    private advanceData(dt: f32): void {
        const d = this.data();
        const dur = this.duration;
        if (this.smoothing) {
            let f = min<f32>(1, dur > 0 ? this.a.elapsed / dur : 1);
            f = this.eased(f);
            this.a.interpolate(f, this.b.from);
            if (f == 1) {
                this.a.copy(this.b);
                this.smoothing = false;
            } else {
                this.a.elapsed += dt;
            }
        }
        if (d.elapsed >= dur) {
            this.current.copyFrom(d.to);
            if (this.smoothing) {
                this.smoothing = false;
                this.a.copy(this.b);
                this.a.elapsed = 0;
                this.b.elapsed = 0;
            } else {
                this.a.elapsed = 0;
            }
            return;
        }
        d.elapsed += dt;
        let f = min<f32>(1, dur > 0 ? d.elapsed / dur : 1);
        f = this.eased(f);
        d.interpolate(f, this.current);
    }

    outputKind(input: VmKind): VmKind {
        return input;
    }
}

// --- Formula -------------------------------------------------------------------

const TOKEN_INPUT = 0;
const TOKEN_VALUE = 1;
const TOKEN_OPERATION = 2;
const TOKEN_FUNCTION = 3;
const TOKEN_OPEN = 4;
const TOKEN_CLOSE = 5;
const TOKEN_SEPARATOR = 6;

class FormulaToken {
    kind: i32;
    // A value's number; an operation's or a function's type.
    value: f32;
    // A function's (or an open parenthesis's) argument count.
    args: i32 = 0;

    constructor(kind: i32, value: f32) {
        this.kind = kind;
        this.value = value;
    }
}

// DataConverterFormula: its tokens put in reverse Polish order once
// (calculateFormula's shunting yard), then evaluated on a kept stack; in
// reverse, the same formula (the runtime's).
export class FormulaConverter extends Converter {
    tokens: Array<FormulaToken> = [];
    randomMode: i32 = 0;
    private queue: Array<FormulaToken> = [];
    private stack: Array<f32> = [];
    private args: Array<f32> = [];
    private randoms: Array<f32> = [];
    private seed: u32 = 0x9e3779b9;

    private precedence(t: FormulaToken): i32 {
        if (t.kind == TOKEN_OPEN || t.kind == TOKEN_CLOSE || t.kind == TOKEN_FUNCTION) return 1;
        if (t.kind == TOKEN_OPERATION) {
            const op = <i32>t.value;
            if (op == OP_ADD || op == OP_SUBTRACT) return 2;
            if (op == OP_MULTIPLY || op == OP_DIVIDE) return 3;
        }
        return 0;
    }

    // DataConverterFormula::calculateFormula.
    prepare(): void {
        const ops = new Array<FormulaToken>();
        const q = this.queue;
        const ts = this.tokens;
        for (let i = 0; i < ts.length; i++) {
            const t = ts[i];
            if (t.kind == TOKEN_VALUE || t.kind == TOKEN_INPUT) q.push(t);
            else if (t.kind == TOKEN_OPERATION) {
                while (ops.length > 0 && ops[ops.length - 1].kind != TOKEN_OPEN
                    && this.precedence(ops[ops.length - 1]) >= this.precedence(t)) q.push(ops.pop());
                ops.push(t);
            } else if (t.kind == TOKEN_OPEN || t.kind == TOKEN_FUNCTION) {
                const next = i == ts.length - 1 ? null : ts[i + 1];
                t.args = next != null && next.kind == TOKEN_CLOSE ? 0 : 1;
                ops.push(t);
            } else if (t.kind == TOKEN_CLOSE) {
                while (ops.length > 0 && ops[ops.length - 1].kind != TOKEN_OPEN && ops[ops.length - 1].kind != TOKEN_FUNCTION) {
                    q.push(ops.pop());
                }
                if (ops.length > 0) {
                    const opening = ops.pop();
                    if (opening.kind == TOKEN_FUNCTION) q.push(opening);
                }
            } else if (t.kind == TOKEN_SEPARATOR && ops.length > 0) {
                for (let k = ops.length - 1; k >= 0; k--) {
                    const c = ops[k];
                    if (c.kind == TOKEN_OPEN || c.kind == TOKEN_FUNCTION) {
                        c.args++;
                        break;
                    }
                }
                while (ops.length > 0 && ops[ops.length - 1].kind != TOKEN_OPEN && ops[ops.length - 1].kind != TOKEN_FUNCTION) {
                    q.push(ops.pop());
                }
            }
        }
        while (ops.length > 0) {
            const op = ops.pop();
            if (op.kind != TOKEN_OPEN) q.push(op);
        }
    }

    // RandomMode once (kept per index) or sourceChange (dropped after each
    // conversion); always (a new one each time).
    private random(index: i32): f32 {
        if (this.randomMode == 1) return this.next();
        while (this.randoms.length <= index) this.randoms.push(this.next());
        return this.randoms[index];
    }

    // xorshift32, in [0, 1).
    private next(): f32 {
        let x = this.seed;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        this.seed = x;
        return <f32>(<f64>(x >> 8) / 16777216.0);
    }

    // DataConverterFormula::applyOperation (only + - * / and modulo).
    private operation(left: f32, right: f32, op: i32): f32 {
        if (op == 0) return left + right;
        if (op == 1) return left - right;
        if (op == 2) return left * right;
        if (op == 3) return left / right;
        if (op == 4) return positiveMod(left, right);
        return 0;
    }

    // DataConverterFormula::applyFunction: its `total` arguments popped,
    // so args[n - 1] is the first written.
    private call(fn: i32, total: i32): f32 {
        const a = this.args;
        a.length = 0;
        const st = this.stack;
        for (let i = 0; i < total; i++) if (st.length > 0) a.push(st.pop());
        const n = a.length;
        switch (fn) {
            case 0:
            case 1: {
                if (n == 0) return 0;
                let v = a[0];
                for (let i = 1; i < n; i++) if (fn == 0 ? a[i] < v : a[i] > v) v = a[i];
                return v;
            }
            case 2: return n > 0 ? roundF(a[n - 1]) : 0;
            case 3: return n > 0 ? Mathf.ceil(a[n - 1]) : 0;
            case 4: return n > 0 ? Mathf.floor(a[n - 1]) : 0;
            case 5: return n > 0 ? Mathf.sqrt(a[n - 1]) : 0;
            case 6: return n > 1 ? Mathf.pow(a[n - 1], a[n - 2]) : 0;
            case 7: return n > 0 ? <f32>Math.exp(a[n - 1]) : 0;
            case 8: return n > 0 ? <f32>Math.log(a[n - 1]) : 0;
            case 9: return n > 0 ? <f32>Math.cos(a[n - 1]) : 0;
            case 10: return n > 0 ? <f32>Math.sin(a[n - 1]) : 0;
            case 11: return n > 0 ? <f32>Math.tan(a[n - 1]) : 0;
            case 12: return n > 0 ? <f32>Math.acos(a[n - 1]) : 0;
            case 13: return n > 0 ? <f32>Math.asin(a[n - 1]) : 0;
            case 14: return n > 0 ? <f32>Math.atan(a[n - 1]) : 0;
            case 15: return n > 1 ? <f32>Math.atan2(a[n - 1], a[n - 2]) : 0;
            case 16: {
                // (the runtime counts its random index from 0 in each call)
                const r = this.random(0);
                let lo: f32 = 0;
                let hi: f32 = 1;
                if (n == 1) hi = a[n - 1];
                else if (n > 1) {
                    lo = a[n - 1];
                    hi = a[n - 2];
                }
                return lo + (hi - lo) * r;
            }
            default: return 0;
        }
    }

    forward(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.Number) {
            out.setNumber(0);
            return false;
        }
        const x = <f32>input.number;
        let result = x;
        const st = this.stack;
        st.length = 0;
        const q = this.queue;
        for (let i = 0; i < q.length; i++) {
            const t = q[i];
            if (t.kind == TOKEN_OPERATION) {
                if (st.length > 1) {
                    const right = st.pop();
                    const left = st.pop();
                    st.push(this.operation(left, right, <i32>t.value));
                }
            } else if (t.kind == TOKEN_FUNCTION) st.push(this.call(<i32>t.value, t.args));
            else if (t.kind == TOKEN_INPUT) st.push(x);
            else if (t.kind == TOKEN_VALUE) st.push(t.value);
        }
        if (st.length == 1) result = st.pop();
        if (this.randomMode == 2) this.randoms.length = 0;
        out.setNumber(<f64>result);
        return true;
    }

    reverse(input: BoundValue, out: BoundValue): bool {
        return this.forward(input, out);
    }

    outputKind(input: VmKind): VmKind {
        return numberIn(input);
    }
}

// --- Group ---------------------------------------------------------------------

// DataConverterGroup: its items in order forward, in reverse order back.
export class GroupConverter extends Converter {
    items: Array<Converter> = [];
    private a: BoundValue = new BoundValue();
    private b: BoundValue = new BoundValue();

    forward(input: BoundValue, out: BoundValue): bool {
        const n = this.items.length;
        if (n == 0) {
            out.copyFrom(input);
            return true;
        }
        let from = input;
        let ok = true;
        for (let i = 0; i < n; i++) {
            const to = i == n - 1 ? out : (i % 2 == 0 ? this.a : this.b);
            if (!this.items[i].forward(from, to)) ok = false;
            from = to;
        }
        return ok;
    }

    reverse(input: BoundValue, out: BoundValue): bool {
        const n = this.items.length;
        if (n == 0) {
            out.copyFrom(input);
            return true;
        }
        let from = input;
        let ok = true;
        for (let i = n - 1; i >= 0; i--) {
            const to = i == 0 ? out : ((n - 1 - i) % 2 == 0 ? this.a : this.b);
            if (!this.items[i].reverse(from, to)) ok = false;
            from = to;
        }
        return ok;
    }

    outputKind(input: VmKind): VmKind {
        let k = input;
        for (let i = 0; i < this.items.length; i++) k = this.items[i].outputKind(k);
        return k;
    }

    advance(seconds: f64): bool {
        let changed = false;
        for (let i = 0; i < this.items.length; i++) if (this.items[i].advance(seconds)) changed = true;
        return changed;
    }

    bind(values: ViewModelValues?): void {
        for (let i = 0; i < this.items.length; i++) this.items[i].bind(values);
    }

    setDirection(toSource: bool): void {
        this.toSource = toSource;
        for (let i = 0; i < this.items.length; i++) this.items[i].setDirection(toSource);
    }

    timed(): bool {
        for (let i = 0; i < this.items.length; i++) if (this.items[i].timed()) return true;
        return false;
    }
}

// --- milestone 17's sugar ------------------------------------------------------

// node = convert(source * scale + offset), convert the identity or degrees
// to radians, in f64 as milestone 17 computed it (a binding written before
// converters keeps its numbers bit for bit); reverse is its inverse
// (source = (unconvert(node) - offset) / scale; `node` itself for scale 0).
export class ImplicitConverter extends Converter {
    scale: f64;
    offset: f64;
    degreesToRadians: bool;

    constructor(scale: f64, offset: f64, degreesToRadians: bool) {
        super();
        this.scale = scale;
        this.offset = offset;
        this.degreesToRadians = degreesToRadians;
    }

    forward(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.Number) return false;
        const x = input.number * this.scale + this.offset;
        out.setNumber(this.degreesToRadians ? x * Math.PI / 180 : x);
        return true;
    }

    reverse(input: BoundValue, out: BoundValue): bool {
        if (input.kind != VmKind.Number) return false;
        const x = this.degreesToRadians ? input.number * 180 / Math.PI : input.number;
        out.setNumber(this.scale != 0 ? (x - this.offset) / this.scale : x);
        return true;
    }

    outputKind(input: VmKind): VmKind {
        return numberIn(input);
    }
}

// Milestone 17's sugar as a converter: node = convert(source * scale +
// offset); null when it is the identity (scale 1, offset 0, no convert).
export function implicitConverter(scale: f64, offset: f64, degreesToRadians: bool): Converter? {
    if (scale == 1 && offset == 0 && !degreesToRadians) return null;
    return new ImplicitConverter(scale, offset, degreesToRadians);
}

// "a number", "an enum": a kind for messages.
export function kindText(k: VmKind): string {
    const n = vmKindName(k);
    const c = n.charCodeAt(0);
    return (c == 0x61 || c == 0x65 || c == 0x69 || c == 0x6f || c == 0x75 ? "an " : "a ") + n;
}
