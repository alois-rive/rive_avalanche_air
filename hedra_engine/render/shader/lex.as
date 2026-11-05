// WGSL's words, as the shader reader (./parse.as) and the composer
// (hedra_compiler/shader/compose.as) see a shader file: identifiers,
// numbers and punctuation, with each one's place (1-based line and column,
// a column counting UTF-16 code units from the line's start, which is the
// byte column for ASCII text, rive's). Comments (`//` to the line's end,
// `/* */`, nested as WGSL nests them) and white space are skipped. A word
// this does not know (a character outside ASCII outside a comment) is a
// TOK_OTHER of one character, which the reader reports.
//
// The words are kept in parallel arrays, not objects: a shader of a few
// thousand words is read on every load and every edit in the editor.

export const TOK_IDENT: i32 = 0;
export const TOK_NUMBER: i32 = 1;
export const TOK_PUNCT: i32 = 2;
export const TOK_OTHER: i32 = 3;

export class WgslTokens {
    text: string;
    kinds: Array<i32> = [];
    // [start, end) in `text`, by UTF-16 index.
    starts: Array<i32> = [];
    ends: Array<i32> = [];
    lines: Array<i32> = [];
    cols: Array<i32> = [];
    // The block comments, each [start, end) in `text` (the outermost of a
    // nest; one never closed ends at the text's end): the composer blanks
    // them, because rive's WGSL reader does not read `/* */`.
    commentStarts: Array<i32> = [];
    commentEnds: Array<i32> = [];
    // A block comment never closed: where it started (0 when none).
    openCommentLine: i32 = 0;
    openCommentCol: i32 = 0;

    constructor(text: string) {
        this.text = text;
    }

    get count(): i32 {
        return this.kinds.length;
    }

    // Token `i`'s text; "" past either end, so that a file which stops
    // partway through a statement (half a line saved during live reload)
    // reads as a syntax error, never an index out of range.
    word(i: i32): string {
        if (i < 0 || i >= this.kinds.length) return "";
        return this.text.substring(this.starts[i], this.ends[i]);
    }

    // Token `i`'s kind; -1 (no kind) past either end, for the same reason:
    // every look-ahead of the reader goes through this.
    kindAt(i: i32): i32 {
        return i >= 0 && i < this.kinds.length ? this.kinds[i] : -1;
    }

    // Whether token `i` is the identifier or the punctuation `w` (compared
    // in place: no string is made).
    is(i: i32, w: string): bool {
        if (i < 0 || i >= this.kinds.length) return false;
        const s = this.starts[i];
        const n = this.ends[i] - s;
        if (n != w.length) return false;
        for (let k = 0; k < n; k++) if (this.text.charCodeAt(s + k) != w.charCodeAt(k)) return false;
        return true;
    }

    // Appends a word (tokenizeWgsl's).
    add(kind: i32, start: i32, end: i32, line: i32, col: i32): void {
        this.kinds.push(kind);
        this.starts.push(start);
        this.ends.push(end);
        this.lines.push(line);
        this.cols.push(col);
    }
}

function isIdentStart(c: i32): bool {
    return (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
}

function isIdentPart(c: i32): bool {
    return isIdentStart(c) || (c >= 0x30 && c <= 0x39);
}

function isDigit(c: i32): bool {
    return c >= 0x30 && c <= 0x39;
}

function isHexDigit(c: i32): bool {
    return isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
}

// The words of `text`.
export function tokenizeWgsl(text: string): WgslTokens {
    const t = new WgslTokens(text);
    const n = text.length;
    let i = 0;
    let line = 1;
    let lineStart = 0;
    while (i < n) {
        const c = text.charCodeAt(i);
        if (c == 0x0a) {
            i++;
            line++;
            lineStart = i;
            continue;
        }
        if (c == 0x20 || c == 0x09 || c == 0x0d || c == 0x0b || c == 0x0c) {
            i++;
            continue;
        }
        if (c == 0x2f && i + 1 < n && text.charCodeAt(i + 1) == 0x2f) {
            while (i < n && text.charCodeAt(i) != 0x0a) i++;
            continue;
        }
        if (c == 0x2f && i + 1 < n && text.charCodeAt(i + 1) == 0x2a) {
            const startLine = line;
            const startCol = i - lineStart + 1;
            t.commentStarts.push(i);
            let depth = 1;
            i += 2;
            while (i < n && depth > 0) {
                const d = text.charCodeAt(i);
                if (d == 0x0a) {
                    i++;
                    line++;
                    lineStart = i;
                } else if (d == 0x2f && i + 1 < n && text.charCodeAt(i + 1) == 0x2a) {
                    depth++;
                    i += 2;
                } else if (d == 0x2a && i + 1 < n && text.charCodeAt(i + 1) == 0x2f) {
                    depth--;
                    i += 2;
                } else {
                    i++;
                }
            }
            t.commentEnds.push(i);
            if (depth > 0) {
                t.openCommentLine = startLine;
                t.openCommentCol = startCol;
            }
            continue;
        }
        const col = i - lineStart + 1;
        if (isIdentStart(c)) {
            const s = i;
            while (i < n && isIdentPart(text.charCodeAt(i))) i++;
            t.add(TOK_IDENT, s, i, line, col);
            continue;
        }
        if (isDigit(c) || (c == 0x2e && i + 1 < n && isDigit(text.charCodeAt(i + 1)))) {
            const s = i;
            if (c == 0x30 && i + 1 < n && (text.charCodeAt(i + 1) == 0x78 || text.charCodeAt(i + 1) == 0x58)) {
                // A hexadecimal number, its fraction and its binary exponent.
                i += 2;
                while (i < n && (isHexDigit(text.charCodeAt(i)) || text.charCodeAt(i) == 0x2e)) i++;
                if (i < n && (text.charCodeAt(i) == 0x70 || text.charCodeAt(i) == 0x50)) {
                    i++;
                    if (i < n && (text.charCodeAt(i) == 0x2b || text.charCodeAt(i) == 0x2d)) i++;
                    while (i < n && isDigit(text.charCodeAt(i))) i++;
                }
            } else {
                while (i < n && (isDigit(text.charCodeAt(i)) || text.charCodeAt(i) == 0x2e)) i++;
                if (i < n && (text.charCodeAt(i) == 0x65 || text.charCodeAt(i) == 0x45)) {
                    i++;
                    if (i < n && (text.charCodeAt(i) == 0x2b || text.charCodeAt(i) == 0x2d)) i++;
                    while (i < n && isDigit(text.charCodeAt(i))) i++;
                }
            }
            // The suffix: f, h, i or u.
            if (i < n) {
                const d = text.charCodeAt(i);
                if (d == 0x66 || d == 0x68 || d == 0x69 || d == 0x75) i++;
            }
            t.add(TOK_NUMBER, s, i, line, col);
            continue;
        }
        if (c < 0x80) {
            t.add(TOK_PUNCT, i, i + 1, line, col);
            i++;
            continue;
        }
        t.add(TOK_OTHER, i, i + 1, line, col);
        i++;
    }
    return t;
}
