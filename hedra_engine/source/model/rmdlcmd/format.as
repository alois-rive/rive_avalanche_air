// The .rmdlcmd model format: what every reader and writer of a model's
// command file agrees on. An .rmdlcmd is the sequence of Hedra commands
// that builds a model, one per line, in Hedra's script language (what the
// CLI's `run` reads), so a model's commands are diffed and read like any
// script, and replay into a model (an .rmdl, the model written down as a
// document: ../rmdl/, and ../formats.as for which file is which). The first
// line names the format version as a comment, so the CLI's `run x.rmdlcmd`
// still reads the file as a plain script:
//
//   # rmdlcmd 1
//   add mesh cube --size 2 --name Crate
//   ...
//
// docs/formats/RMDLCMD.md is the normative description: the header, the
// lines, the data form (engine/src/source/model/rmdlcmd/data/), the cache
// (cache.as).
//
// RmdlError is the one error every rmdlcmd module returns, so the CLI and
// the editor each word it in their own failures from the same code, file,
// line and hint.

import { ErrorValue, Result } from "../../../base/util";
import { CLI, EDITOR } from "../../../base/names";

// The format version this build reads and writes.
export const RMDLCMD_FORMAT: i32 = 1;
// The header line's prefix: the whole line is RMDLCMD_HEADER_PREFIX +
// version.
export const RMDLCMD_HEADER_PREFIX = "# rmdlcmd ";
// The first line of a command file before the format had its own
// extension: no header any more (checkHeader says how to write the new one).
export const OLD_HEADER_PREFIX = "# rmdl ";

// What a replay's result depends on besides the file's commands: bumped by
// hand whenever an operator, a modifier or the data form changes the scene a
// command line builds, so that a cache entry made by an older kernel is
// never taken for a newer one's (cache.as folds it into every key, with the
// scene schema).
export const RMDL_KERNEL: i32 = 2;

// The header line of a file in this build's format.
export function headerLine(): string {
    return RMDLCMD_HEADER_PREFIX + RMDLCMD_FORMAT.toString();
}

// The version a header line names, or -1 when the line is no header. A
// trailing CR and trailing spaces are allowed, nothing else: `# rmdlcmd 1`,
// `# rmdlcmd 12`.
export function headerVersion(line: string): i32 {
    return versionAfter(line, RMDLCMD_HEADER_PREFIX);
}

// The version `line` names after `prefix`, by headerVersion's rules, or -1.
function versionAfter(line: string, prefix: string): i32 {
    let end = line.length;
    while (end > 0) {
        const c = line.charCodeAt(end - 1);
        if (c != 13 && c != 32 && c != 9) break;
        end--;
    }
    const p = prefix.length;
    if (end <= p || line.substring(0, p) != prefix) return -1;
    let v: i32 = 0;
    for (let i = p; i < end; i++) {
        const c = line.charCodeAt(i);
        if (c < 48 || c > 57) return -1;
        // (a header naming a version past i32 is no header we could read)
        if (v > 100000000) return -1;
        v = v * 10 + (c - 48);
    }
    return v;
}

// The error codes, as answers and diagnostics name them.
// (the constants keep the names they had when the format was the .rmdl:
// every reader of a model names them)
export const E_HEADER = "rmdlcmd-header"; // no `# rmdlcmd N` first line
export const E_FORMAT_NEWER = "rmdlcmd-format-newer"; // N > RMDLCMD_FORMAT
export const E_SYNTAX = "rmdlcmd-syntax"; // a line that does not tokenize
export const E_DATA = "rmdlcmd-data"; // a data line that is malformed or inconsistent
export const E_DATA_MISPLACED = "rmdlcmd-data-misplaced"; // a data line after a command
export const E_COMMAND_NOT_ALLOWED = "rmdlcmd-command-not-allowed"; // render, export, run... in a model file
export const E_REPLAY = "rmdlcmd-replay"; // a command line failed when replayed
export const E_NEEDS_MODEL_COMMANDS = "model-needs-commands"; // a program without the command kernel (a built project): commands and no cache entry
export const E_CACHE = "rmdlcmd-cache"; // a cache entry that does not decode (never fatal to a load)

// One error of an .rmdlcmd: its code (above), the file as the caller shows it,
// the 1-based line (0: the file as a whole), the message and a hint.
export class RmdlError extends ErrorValue {
    code: string;
    file: string;
    line: i32;
    message: string;
    hint: string;

    constructor(code: string, file: string, line: i32, message: string, hint: string) {
        super();
        this.code = code;
        this.file = file;
        this.line = line;
        this.message = message;
        this.hint = hint;
    }

    // `lamp.rmdlcmd:12: <message>`, or `lamp.rmdlcmd: <message>` for line 0.
    toString(): string {
        return this.file + (this.line > 0 ? ":" + this.line.toString() : "") + ": " + this.message;
    }

    fail<T>(): Result<T> {
        return Result.failWith<T>(this);
    }
}

// The RmdlError behind a failed Result, or null when it carries another.
export function rmdlErrorOf<T>(r: Result<T>): RmdlError? {
    const c = r.cause;
    if (c == null) return null;
    const is = c instanceof RmdlError;
    if (is) return c as RmdlError;
    return null;
}

// The header's error for a file whose first line is `first`, or null when
// the header is good: missing, or naming a version newer than this build's.
// A first line `# rmdl 1` is the header command files had before the model
// document took the .rmdl extension: no header, with a hint that says so.
export function checkHeader(first: string, file: string): RmdlError? {
    const v = headerVersion(first);
    if (v < 0) {
        if (versionAfter(first, OLD_HEADER_PREFIX) >= 0) {
            return new RmdlError(E_HEADER, file, 1, "the first line is the old header `" + first.trim() + "`, not an .rmdlcmd header",
                "this is the old header: write `" + headerLine() + "` (an .rmdl is now the model's XML document: "
                + CLI + " model x.rmdlcmd --to x.rmdl writes it)");
        }
        return new RmdlError(E_HEADER, file, 1, "the first line is not an .rmdlcmd header",
            "an .rmdlcmd starts with the line `" + headerLine() + "`");
    }
    if (v > RMDLCMD_FORMAT) {
        return new RmdlError(E_FORMAT_NEWER, file, 1, "the file is .rmdlcmd format " + v.toString() + ", newer than this build's " + RMDLCMD_FORMAT.toString(),
            "use a newer " + CLI + " or " + EDITOR);
    }
    return null;
}
