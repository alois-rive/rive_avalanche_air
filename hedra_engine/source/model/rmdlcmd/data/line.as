// One data line, split into its record word, positionals and flags without
// copying what it does not have to.
//
// The words are lex.as's (Hedra's tokenizer): whitespace separates, single
// and double quotes group, a backslash escapes in double quotes and bare
// words, `#` at the start of a word ends the line. A word is kept as a range
// of the line when it can be (a bare word without a backslash, or one quoted
// run without an escape: every array a writer writes), and decoded into a
// new string only otherwise (a name with a quote in it). An array's numbers
// are then read in place by num.as.
//
// A bare word that starts with `--` is a flag; a quoted one is a value, so a
// name such as "--x" (quoteToken quotes it) is never taken for one. How many
// values a flag takes is the record's to say (FlagSpec): 0 for a switch, 1,
// or 2 (an armature's `--collection <name> <0|1>`).

import { isUnicodeWhitespace } from "../../../../base/util";
import { NumScanner } from "./num";

const C_TAB: i32 = 0x09;
const C_LF: i32 = 0x0A;
const C_DQUOTE: i32 = 0x22;
const C_HASH: i32 = 0x23;
const C_SQUOTE: i32 = 0x27;
const C_BACKSLASH: i32 = 0x5C;
const C_MINUS: i32 = 0x2D;
const C_N: i32 = 0x6E;
const C_T: i32 = 0x74;

// One word: its text is src[s, e).
export class Word {
    src: string;
    s: i32;
    e: i32;
    // Quoted (wholly or in part): never a flag.
    quoted: bool;
    // Its numbers are separated by commas as well as whitespace, and may
    // span lines: a value read from an .rmdl document (`Vector3(0, 1, 2)`'s
    // inside, a packed array's), which the document's reader hands to the
    // replay as it stands (../../rmdl/elements.as). A data line's never is.
    commaList: bool = false;

    constructor(src: string, s: i32, e: i32, quoted: bool) {
        this.src = src;
        this.s = s;
        this.e = e;
        this.quoted = quoted;
    }

    text(): string {
        return this.s == 0 && this.e == this.src.length ? this.src : this.src.substring(this.s, this.e);
    }

    is(t: string): bool {
        const n = this.e - this.s;
        if (n != t.length) return false;
        for (let i = 0; i < n; i++) if (this.src.charCodeAt(this.s + i) != t.charCodeAt(i)) return false;
        return true;
    }

    isFlag(): bool {
        return !this.quoted && this.e - this.s > 2 && this.src.charCodeAt(this.s) == C_MINUS
            && this.src.charCodeAt(this.s + 1) == C_MINUS;
    }

    // The numbers inside it.
    numbers(): NumScanner {
        const n = new NumScanner(this.src, this.s, this.e);
        n.comma = this.commaList;
        return n;
    }
}

// What a record's flags are: their names, how many values each takes, and
// whether it may be given more than once (a list: `--uv-layer A --uv-layer B`).
export class FlagSpec {
    name: string;
    arity: i32;
    repeat: bool;

    constructor(name: string, arity: i32, repeat: bool) {
        this.name = name;
        this.arity = arity;
        this.repeat = repeat;
    }
}

// A switch, a flag with one value, one with two; a list flag.
export function sw(name: string): FlagSpec {
    return new FlagSpec(name, 0, false);
}
export function one(name: string): FlagSpec {
    return new FlagSpec(name, 1, false);
}
export function two(name: string): FlagSpec {
    return new FlagSpec(name, 2, false);
}
export function many(name: string, arity: i32): FlagSpec {
    return new FlagSpec(name, arity, true);
}

// A data line, split. `error` is set (and the rest partial) when the line
// does not split: an unterminated quote, an unknown or repeated flag, a
// missing value, the wrong number of positionals.
export class DataLine {
    record: string = "";
    positionals: Array<Word> = [];
    // Flags in the order given: names, and where each one's values start in
    // `values` (its arity says how many).
    flags: Array<string> = [];
    starts: Array<i32> = [];
    values: Array<Word> = [];
    error: string = "";
    // A bound on how many elements the record can describe, for the slot
    // counts it declares (every slot costs at least two characters of its
    // source): the line's length, or for a record read from a document the
    // document's. 0 until the replay sets it.
    size: i32 = 0;

    // The index of a flag's first occurrence, -1 when absent.
    find(name: string): i32 {
        for (let i = 0; i < this.flags.length; i++) if (this.flags[i] == name) return i;
        return -1;
    }

    has(name: string): bool {
        return this.find(name) >= 0;
    }

    // The k-th value of the flag's first occurrence; null when absent.
    value(name: string, k: i32 = 0): Word? {
        const i = this.find(name);
        if (i < 0) return null;
        return this.values[this.starts[i] + k];
    }

    // The k-th value of every occurrence, in order (a list flag).
    all(name: string, k: i32 = 0): Array<Word> {
        const out: Array<Word> = [];
        for (let i = 0; i < this.flags.length; i++) if (this.flags[i] == name) out.push(this.values[this.starts[i] + k]);
        return out;
    }
}

function unescape(c: i32): i32 {
    if (c == C_N) return C_LF;
    if (c == C_T) return C_TAB;
    return c;
}

// The words of a line, as lex.as tokenizeLine reads them, or null with
// `out.error` set.
function words(line: string, out: DataLine): Array<Word>? {
    const ws: Array<Word> = [];
    const n = line.length;
    let i = 0;
    while (i < n) {
        while (i < n && isUnicodeWhitespace(line.charCodeAt(i))) i++;
        if (i >= n) break;
        if (line.charCodeAt(i) == C_HASH) break;
        // The fast shapes first: one quoted run without an escape, or a
        // bare word without a quote or a backslash, ending at whitespace.
        const c0 = line.charCodeAt(i);
        if (c0 == C_DQUOTE || c0 == C_SQUOTE) {
            let k = i + 1;
            while (k < n) {
                const d = line.charCodeAt(k);
                if (d == c0 || (c0 == C_DQUOTE && d == C_BACKSLASH)) break;
                k++;
            }
            if (k < n && line.charCodeAt(k) == c0 && (k + 1 >= n || isUnicodeWhitespace(line.charCodeAt(k + 1)))) {
                ws.push(new Word(line, i + 1, k, true));
                i = k + 1;
                continue;
            }
        } else {
            let k = i;
            let plain = true;
            while (k < n) {
                const d = line.charCodeAt(k);
                if (isUnicodeWhitespace(d)) break;
                if (d == C_DQUOTE || d == C_SQUOTE || d == C_BACKSLASH) {
                    plain = false;
                    break;
                }
                k++;
            }
            if (plain) {
                ws.push(new Word(line, i, k, false));
                i = k;
                continue;
            }
        }
        // The general shape, unit by unit (tokenizeLine's loop for one word).
        const units: Array<i32> = [];
        let quoted = false;
        while (i < n) {
            const c = line.charCodeAt(i);
            if (isUnicodeWhitespace(c)) break;
            i++;
            if (c == C_SQUOTE) {
                quoted = true;
                let closed = false;
                while (i < n) {
                    const d = line.charCodeAt(i);
                    i++;
                    if (d == C_SQUOTE) {
                        closed = true;
                        break;
                    }
                    units.push(d);
                }
                if (!closed) {
                    out.error = "an unterminated quote";
                    return null;
                }
            } else if (c == C_DQUOTE) {
                quoted = true;
                let closed = false;
                while (i < n) {
                    const d = line.charCodeAt(i);
                    i++;
                    if (d == C_DQUOTE) {
                        closed = true;
                        break;
                    } else if (d == C_BACKSLASH) {
                        if (i < n) {
                            units.push(unescape(line.charCodeAt(i)));
                            i++;
                        } else {
                            out.error = "an unterminated quote";
                            return null;
                        }
                    } else {
                        units.push(d);
                    }
                }
                if (!closed) {
                    out.error = "an unterminated quote";
                    return null;
                }
            } else if (c == C_BACKSLASH) {
                if (i < n) {
                    units.push(unescape(line.charCodeAt(i)));
                    i++;
                }
            } else {
                units.push(c);
            }
        }
        const text = String.fromCharCodes(units);
        ws.push(new Word(text, 0, text.length, quoted));
    }
    return ws;
}

// Splits a data line: `data <record> <positionals>... --flag value...`.
// `positionals` is how many the record takes; `specs` its flags.
export function splitLine(line: string, positionals: i32, specs: Array<FlagSpec>): DataLine {
    const out = new DataLine();
    const ws = words(line, out);
    if (ws == null) return out;
    if (ws.length < 2) {
        out.error = "a data line names its record: `data <record> ...`";
        return out;
    }
    out.record = ws[1].text();
    let i = 2;
    while (i < ws.length && !ws[i].isFlag()) {
        out.positionals.push(ws[i]);
        i++;
    }
    if (out.positionals.length != positionals) {
        out.error = out.positionals.length < positionals
            ? "too few values before the flags (" + positionals.toString() + " expected, "
                + out.positionals.length.toString() + " given)"
            : "too many values before the flags (" + positionals.toString() + " expected, "
                + out.positionals.length.toString() + " given)";
        return out;
    }
    while (i < ws.length) {
        const w = ws[i];
        if (!w.isFlag()) {
            out.error = "`" + w.text() + "` is not a flag here (a value with no flag before it)";
            return out;
        }
        const name = w.src.substring(w.s + 2, w.e);
        let spec: FlagSpec? = null;
        for (let k = 0; k < specs.length; k++) {
            if (specs[k].name == name) {
                spec = specs[k];
                break;
            }
        }
        if (spec == null) {
            out.error = "unknown flag --" + name;
            return out;
        }
        if (!spec.repeat && out.has(name)) {
            out.error = "--" + name + " is given twice";
            return out;
        }
        i++;
        out.flags.push(name);
        out.starts.push(out.values.length);
        for (let k = 0; k < spec.arity; k++) {
            if (i >= ws.length || ws[i].isFlag()) {
                out.error = "--" + name + (spec.arity == 1 ? " needs a value" : " needs " + spec.arity.toString() + " values");
                return out;
            }
            out.values.push(ws[i]);
            i++;
        }
    }
    return out;
}

// The record word of a data line ("" when there is none), cheaply: what
// DataReplay dispatches on before it splits the line with that record's
// flags.
export function recordOf(line: string): string {
    const n = line.length;
    let i = 0;
    for (let w = 0; w < 2; w++) {
        while (i < n && isUnicodeWhitespace(line.charCodeAt(i))) i++;
        const a = i;
        while (i < n && !isUnicodeWhitespace(line.charCodeAt(i))) i++;
        if (w == 1) {
            const r = line.substring(a, i);
            for (let k = 0; k < r.length; k++) {
                const c = r.charCodeAt(k);
                if (c == C_DQUOTE || c == C_SQUOTE || c == C_BACKSLASH || c == C_HASH) return "";
            }
            return r;
        }
    }
    return "";
}
