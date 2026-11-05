// An .rmdlcmd file as text: its header and its entries, kept line for line so
// that a file read and written back is the same bytes (LF line endings, a
// final line feed), and so that Hedra can append a command, or take the
// last one away on undo, without touching anything else a person wrote.
//
// An entry is one step of the model: one command line, or a block that one
// step expanded to (a user tool's body, written between `# <call> {` and
// `# }`, as the command log always wrote it), with the comment lines that
// belong to it:
//
//   # rmdlcmd 1                    header
//                                  preamble (the lines before the first lead)
//   # The seat: one slat.          lead of entry 0 (comments right above it)
//   add mesh cube --name Seat      entry 0
//                                  tail of entry 0 (up to the next lead)
//   # greeble --density 0.5 {      entry 1, a block: open
//   inset 0.1                        its commands
//   extrude 0.05
//   # }                              close
//
// Between two commands, the lines up to and including the last blank line
// are the earlier entry's tail; the comment lines after it, right above the
// next command, are that command's lead. Undo takes an entry away with its
// lead and its tail, so the file reads as if the step had never been there.
//
// Nothing here knows what a command means: Hedra replays the lines
// (engine/src/commands/replay.as), data/ reads data lines, Hedra
// loads through load.as.

import { Result } from "../../../base/util";
import { RMDLCMD_FORMAT, RmdlError, E_DATA_MISPLACED, checkHeader, headerLine, headerVersion } from "./format";
import { firstWord, isBlankOrComment } from "./lex";

// The word every data line starts with (data/mod.as).
export const DATA_WORD = "data";

// One step of the model.
export class RmdlEntry {
    // The comment lines right above it, verbatim (no line ending).
    lead: Array<string> = [];
    // A block's opening comment, `# <label> {`; null for a plain command.
    open: string? = null;
    // The command lines, verbatim: one for a plain command.
    commands: Array<string> = [];
    // A block's closing comment, `# }`; null for a plain command.
    close: string? = null;
    // The lines after it up to the next entry's lead: blank lines and the
    // comments a blank line separates from the next command.
    tail: Array<string> = [];
    // The 1-based line of each command line in the file it was read from
    // (0 for an entry added in memory).
    lines: Array<i32> = [];
    // Whether `append` put a blank line above it (at the end of the tail
    // before, or of the preamble), for dropSeparator. (Read from a file,
    // the line is the file's own: false.)
    sepAdded: bool = false;

    static command(line: string): RmdlEntry {
        const e = new RmdlEntry();
        e.commands.push(line);
        e.lines.push(0);
        return e;
    }

    // A step that expanded to several lines (a user tool): `label` is what
    // was called, as the open comment shows it.
    static block(label: string, body: Array<string>): RmdlEntry {
        const e = new RmdlEntry();
        e.open = "# " + label + " {";
        e.close = "# }";
        for (let i = 0; i < body.length; i++) {
            e.commands.push(body[i]);
            e.lines.push(0);
        }
        return e;
    }

    // A data line (data/mod.as): a plain entry whose command starts with
    // the word `data`.
    isData(): bool {
        return this.open == null && this.commands.length == 1 && firstWord(this.commands[0]) == DATA_WORD;
    }

    // What the step was: the block's label, or the command line.
    label(): string {
        const o = this.open;
        if (o != null) return blockLabel(o);
        return this.commands.length > 0 ? this.commands[0] : "";
    }
}

// `# greeble --density 0.5 {` -> `greeble --density 0.5`; "" when the
// line opens no block.
export function blockLabel(line: string): string {
    const t = trimEnd(line);
    if (!t.startsWith("# ") || !t.endsWith(" {") || t.length < 5) return "";
    return t.substring(2, t.length - 2);
}

function isBlockOpen(line: string): bool {
    return blockLabel(line).length > 0;
}

function isBlockClose(line: string): bool {
    return trimEnd(line) == "# }";
}

function isBlank(line: string): bool {
    for (let i = 0; i < line.length; i++) {
        const c = line.charCodeAt(i);
        if (c != 32 && c != 9) return false;
    }
    return true;
}

function trimEnd(s: string): string {
    let e = s.length;
    while (e > 0) {
        const c = s.charCodeAt(e - 1);
        if (c != 32 && c != 9 && c != 13) break;
        e--;
    }
    return e == s.length ? s : s.substring(0, e);
}

// Splits the lines between two commands (or after the header) at the last
// blank line: [up to and including it] go to the earlier tail (or the
// preamble), [after it] are the next lead.
function splitGap(gap: Array<string>, before: Array<string>, lead: Array<string>): void {
    let last = -1;
    for (let i = 0; i < gap.length; i++) if (isBlank(gap[i])) last = i;
    for (let i = 0; i <= last; i++) before.push(gap[i]);
    for (let i = last + 1; i < gap.length; i++) lead.push(gap[i]);
}

export class RmdlDoc {
    // The format version the header names.
    version: i32 = RMDLCMD_FORMAT;
    // The header line, verbatim.
    header: string = headerLine();
    // The lines between the header and the first entry's lead.
    preamble: Array<string> = [];
    entries: Array<RmdlEntry> = [];
    // The lines after the last entry, when there is none (a file of only
    // comments): with entries, they are the last entry's tail.
    trailer: Array<string> = [];

    // A new model: the header alone.
    static empty(): RmdlDoc {
        return new RmdlDoc();
    }

    // Reads a file's text. CR before LF is dropped and a UTF-8 BOM skipped;
    // the header must be the first line (format.as checkHeader). `file` is
    // how errors name it.
    static parse(text: string, file: string): Result<RmdlDoc> {
        let src = text;
        if (src.length > 0 && src.charCodeAt(0) == 0xFEFF) src = src.substring(1);
        const raw = src.split("\n");
        // A final line feed leaves one empty string behind: no line.
        if (raw.length > 0 && raw[raw.length - 1].length == 0) raw.pop();
        // (CRs dropped in place: a second array of the lines is heap the
        // stub runtime never gives back)
        const lines = raw;
        for (let i = 0; i < raw.length; i++) {
            const l = raw[i];
            if (l.length > 0 && l.charCodeAt(l.length - 1) == 13) lines[i] = l.substring(0, l.length - 1);
        }
        const first = lines.length > 0 ? lines[0] : "";
        const bad = checkHeader(first, file);
        if (bad != null) return bad.fail<RmdlDoc>();
        const doc = new RmdlDoc();
        doc.version = headerVersion(first);
        doc.header = first;
        // The comment and blank lines since the last command: one array,
        // emptied after each command takes its lines (placeGap copies them),
        // not one an entry.
        const gap: Array<string> = [];
        let i = 1;
        while (i < lines.length) {
            const l = lines[i];
            if (isBlockOpen(l)) {
                // A block runs to its `# }` over command lines only; an
                // open line without one is a comment like any other.
                let end = -1;
                for (let k = i + 1; k < lines.length; k++) {
                    if (isBlockClose(lines[k])) {
                        end = k;
                        break;
                    }
                    if (isBlankOrComment(lines[k])) break;
                }
                if (end > i + 1) {
                    const e = new RmdlEntry();
                    doc.placeGap(gap, e);
                    gap.length = 0;
                    e.open = l;
                    for (let k = i + 1; k < end; k++) {
                        e.commands.push(lines[k]);
                        e.lines.push(k + 1);
                    }
                    e.close = lines[end];
                    doc.entries.push(e);
                    i = end + 1;
                    continue;
                }
            }
            if (isBlankOrComment(l)) {
                gap.push(l);
                i++;
                continue;
            }
            const e = new RmdlEntry();
            doc.placeGap(gap, e);
            gap.length = 0;
            e.commands.push(l);
            e.lines.push(i + 1);
            doc.entries.push(e);
            i++;
        }
        if (doc.entries.length > 0) {
            const t = doc.entries[doc.entries.length - 1].tail;
            for (let k = 0; k < gap.length; k++) t.push(gap[k]);
        } else {
            for (let k = 0; k < gap.length; k++) doc.trailer.push(gap[k]);
        }
        return Result.okv<RmdlDoc>(doc);
    }

    private placeGap(gap: Array<string>, next: RmdlEntry): void {
        const before = this.entries.length > 0 ? this.entries[this.entries.length - 1].tail : this.preamble;
        splitGap(gap, before, next.lead);
    }

    // The file's text: every line with a line feed, the same bytes the file
    // was read from when it had LF endings and a final line feed.
    text(): string {
        const out: Array<string> = [this.header, "\n"];
        pushLines(out, this.preamble);
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i];
            pushLines(out, e.lead);
            const o = e.open;
            if (o != null) {
                out.push(o);
                out.push("\n");
            }
            pushLines(out, e.commands);
            const c = e.close;
            if (c != null) {
                out.push(c);
                out.push("\n");
            }
            pushLines(out, e.tail);
        }
        pushLines(out, this.trailer);
        return out.join("");
    }

    entryCount(): i32 {
        return this.entries.length;
    }

    // Every command line of the first `n` entries (all when n < 0), in order.
    commandLines(n: i32 = -1): Array<string> {
        const m = n < 0 || n > this.entries.length ? this.entries.length : n;
        const out: Array<string> = [];
        for (let i = 0; i < m; i++) {
            const c = this.entries[i].commands;
            for (let k = 0; k < c.length; k++) out.push(c[k]);
        }
        return out;
    }

    // What the cache key of the first `n` entries hashes (cache.as): their
    // command lines, each followed by a line feed. Comments are not in it,
    // so editing one keeps the cache.
    prefixText(n: i32): string {
        const lines = this.commandLines(n);
        const out: Array<string> = [];
        for (let i = 0; i < lines.length; i++) {
            out.push(lines[i]);
            out.push("\n");
        }
        return out.join("");
    }

    // How many entries at the start are data lines (the data form's block).
    dataEntries(): i32 {
        let n = 0;
        while (n < this.entries.length && this.entries[n].isData()) n++;
        return n;
    }

    // Whether every entry is a data line: a file Hedra replays without
    // Hedra (load.as).
    isDataOnly(): bool {
        return this.dataEntries() == this.entries.length;
    }

    // A data line after a command is an error: the data form is a snapshot
    // the commands build on, so it comes first (RMDLCMD.md, "The data form").
    checkDataPlacement(file: string): RmdlError? {
        const n = this.dataEntries();
        for (let i = n; i < this.entries.length; i++) {
            const e = this.entries[i];
            for (let k = 0; k < e.commands.length; k++) {
                if (firstWord(e.commands[k]) == DATA_WORD) {
                    return new RmdlError(E_DATA_MISPLACED, file, e.lines[k], "a data line after a command",
                        "data lines come first in a model file, before any command");
                }
            }
        }
        return null;
    }

    // Adds a step at the end. A trailer (comments in a file with no entry
    // yet) becomes the preamble, so it stays above the first command. When
    // the line above the new step is a comment, a blank line goes between
    // them: without it the file would read back with that comment as the
    // new step's lead, and an undo in a later process would take it away
    // with the step (the blank line stays after an undo; the step
    // remembers it was added, `sepAdded`, for dropSeparator).
    append(e: RmdlEntry): void {
        if (this.entries.length == 0 && this.trailer.length > 0) {
            for (let i = 0; i < this.trailer.length; i++) this.preamble.push(this.trailer[i]);
            this.trailer = [];
        }
        const before = this.entries.length > 0 ? this.entries[this.entries.length - 1].tail : this.preamble;
        e.sepAdded = false;
        if (before.length > 0 && !isBlank(before[before.length - 1])) {
            before.push("");
            e.sepAdded = true;
        }
        this.entries.push(e);
    }

    // Takes the last step away, with its lead and tail (undo); null when
    // there is none. The blank line `append` added stays (`sepAdded` says
    // it was added): the file is then the same whether the undo runs in
    // this process or a later one, which reads that line as the file's own.
    pop(): RmdlEntry? {
        if (this.entries.length == 0) return null;
        return this.entries.pop();
    }

    // Keeps the first `n` entries and returns the ones taken away, in order.
    truncate(n: i32): Array<RmdlEntry> {
        const out: Array<RmdlEntry> = [];
        if (n < 0) n = 0;
        while (this.entries.length > n) out.unshift(this.entries.pop());
        return out;
    }

    // Takes away the blank line `append` put above `e` when it was added
    // (`e` just taken out by `pop`): for a program that undoes its own
    // step in the same process and gives the file back byte for byte (the
    // model editor). True when one was taken.
    dropSeparator(e: RmdlEntry): bool {
        if (!e.sepAdded) return false;
        const before = this.entries.length > 0 ? this.entries[this.entries.length - 1].tail : this.preamble;
        if (before.length == 0 || !isBlank(before[before.length - 1])) return false;
        before.pop();
        return true;
    }
}

function pushLines(out: Array<string>, lines: Array<string>): void {
    for (let i = 0; i < lines.length; i++) {
        out.push(lines[i]);
        out.push("\n");
    }
}
