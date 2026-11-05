// The Hedra library's errors and diagnostics. Everything that can be wrong
// with a scene names where: `<file>:<line>:<col>: <message>`, the file as the
// loader shows it (`res://scenes/main.rscn` inside the project, the absolute
// path outside it), line and column 1-based (a column counts Unicode code
// points). A problem found while loading something another file referred to
// carries the chain of references that led to it, innermost first:
//
//   res://props/tree.rscn:12:5: parent "Trunk/Leaf" not found
//     required by res://main.rscn:7:3: instance of res://props/tree.rscn
//
// `code` is a stable kebab-case identifier (docs/formats/RSCN.md, "Errors",
// lists them all): tools and tests match on it, people read the message.
// `hint`, when there is one, says what to do; the command line prints it on a
// line of its own, as Hedra does.
//
// An error stops a load (Result.failWith(SceneryError)); a warning (an
// unknown element, type or property kept for a newer tool) does not, and is
// collected as a Diagnostic, which the CLI's `inspect --check` will list.

import { ErrorValue, Result } from "../base/util";

export enum Severity {
    Error,
    Warning,
}

export function severityName(s: Severity): string {
    return s == Severity.Error ? "error" : "warning";
}

// `<file>:<line>:<col>`, `<file>` alone when the line is unknown (0).
export function whereText(file: string, line: i32, col: i32): string {
    if (line <= 0) return file;
    return file + ":" + line.toString() + ":" + col.toString();
}

// A reference that led to the problem: where it is, and what it asked for.
export class TraceEntry {
    file: string;
    line: i32;
    col: i32;
    what: string;

    constructor(file: string, line: i32, col: i32, what: string) {
        this.file = file;
        this.line = line;
        this.col = col;
        this.what = what;
    }

    toString(): string {
        return whereText(this.file, this.line, this.col) + ": " + this.what;
    }
}

export class SceneryError extends ErrorValue {
    code: string;
    file: string;
    line: i32;
    col: i32;
    message: string;
    hint: string? = null;
    // Outer references, innermost first (see the header).
    trace: Array<TraceEntry> = [];

    constructor(code: string, file: string, line: i32, col: i32, message: string, hint: string? = null) {
        super();
        this.code = code;
        this.file = file;
        this.line = line;
        this.col = col;
        this.message = message;
        this.hint = hint;
    }

    static at(code: string, file: string, line: i32, col: i32, message: string, hint: string? = null): SceneryError {
        return new SceneryError(code, file, line, col, message, hint);
    }

    // Adds the reference that led here (outermost last); returns this.
    within(file: string, line: i32, col: i32, what: string): SceneryError {
        this.trace.push(new TraceEntry(file, line, col, what));
        return this;
    }

    where(): string {
        return whereText(this.file, this.line, this.col);
    }

    // The first line (`<where>: <message>`) and a "  required by" line per
    // trace entry. The hint is not part of it: the caller prints it.
    toString(): string {
        let s = this.where() + ": " + this.message;
        for (let i = 0; i < this.trace.length; i++) s += "\n  required by " + this.trace[i].toString();
        return s;
    }

    fail<T>(): Result<T> {
        return Result.failWith<T>(this);
    }

    toDiagnostic(): Diagnostic {
        const d = new Diagnostic(Severity.Error, this.code, this.file, this.line, this.col, this.message, this.hint);
        for (let i = 0; i < this.trace.length; i++) d.trace.push(this.trace[i]);
        return d;
    }
}

// The SceneryError behind a failed Result, or null (it succeeded, or failed
// with something else).
export function sceneryErrorOf<T>(r: Result<T>): SceneryError? {
    if (r.ok) return null;
    const c = r.cause;
    if (c == null) return null;
    const isScenery = c instanceof SceneryError;
    if (isScenery) return c as SceneryError;
    return null;
}

// A problem found without stopping: `<where>: <severity>: <message>`.
export class Diagnostic {
    severity: Severity;
    code: string;
    file: string;
    line: i32;
    col: i32;
    message: string;
    hint: string?;
    trace: Array<TraceEntry> = [];

    constructor(severity: Severity, code: string, file: string, line: i32, col: i32, message: string, hint: string? = null) {
        this.severity = severity;
        this.code = code;
        this.file = file;
        this.line = line;
        this.col = col;
        this.message = message;
        this.hint = hint;
    }

    toString(): string {
        let s = whereText(this.file, this.line, this.col) + ": " + severityName(this.severity) + ": " + this.message;
        for (let i = 0; i < this.trace.length; i++) s += "\n  required by " + this.trace[i].toString();
        return s;
    }

    // The error this diagnostic stands for (for a Result).
    toError(): SceneryError {
        const e = new SceneryError(this.code, this.file, this.line, this.col, this.message, this.hint);
        for (let i = 0; i < this.trace.length; i++) e.trace.push(this.trace[i]);
        return e;
    }
}

// Diagnostics in the order they were found.
export class Diagnostics {
    items: Array<Diagnostic> = [];

    add(d: Diagnostic): void {
        this.items.push(d);
    }

    error(code: string, file: string, line: i32, col: i32, message: string, hint: string? = null): void {
        this.items.push(new Diagnostic(Severity.Error, code, file, line, col, message, hint));
    }

    warning(code: string, file: string, line: i32, col: i32, message: string, hint: string? = null): void {
        this.items.push(new Diagnostic(Severity.Warning, code, file, line, col, message, hint));
    }

    addAll(o: Diagnostics): void {
        for (let i = 0; i < o.items.length; i++) this.items.push(o.items[i]);
    }

    count(s: Severity): i32 {
        let n = 0;
        for (let i = 0; i < this.items.length; i++) if (this.items[i].severity == s) n++;
        return n;
    }

    hasErrors(): bool {
        return this.count(Severity.Error) > 0;
    }

    // The first error, or null.
    firstError(): Diagnostic? {
        for (let i = 0; i < this.items.length; i++) if (this.items[i].severity == Severity.Error) return this.items[i];
        return null;
    }

    // Every diagnostic's toString, one per line ("" when there is none).
    toString(): string {
        const lines = new Array<string>();
        for (let i = 0; i < this.items.length; i++) lines.push(this.items[i].toString());
        return lines.join("\n");
    }
}
