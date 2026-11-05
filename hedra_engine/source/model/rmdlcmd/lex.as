// The lexical rules of an .rmdlcmd line, which are Hedra's script language's
// (engine/src/commands/lang/tokenizer.as): whitespace separates tokens,
// single and double quotes group, a backslash escapes inside double quotes
// and in bare words (`\n` and `\t` stand for a line feed and a tab), and `#`
// starts a comment when it begins a token. One command per line.
//
// Shared so that Hedra reads a model file's words exactly as Hedra does
// without Hedra's parser. tokenizeLine must give the same tokens as
// Hedra's `tokenize` for every line (tests/rmdl/lex_test.as holds the two
// to each other); quoteToken is Hedra's `quote` with a line feed and a tab
// escaped too, so a quoted token never breaks the one-line rule.
//
// A data line's long arrays are not tokenized here: data/ reads their
// numbers in place, without a token per character (the stub runtime never
// frees what a token array took).

import { Result, isUnicodeWhitespace } from "../../../base/util";

const C_TAB: i32 = 0x09;
const C_LF: i32 = 0x0A;
const C_DQUOTE: i32 = 0x22;
const C_HASH: i32 = 0x23;
const C_SQUOTE: i32 = 0x27;
const C_BACKSLASH: i32 = 0x5C;
const C_N: i32 = 0x6E;
const C_T: i32 = 0x74;

function unescape(c: i32): i32 {
    if (c == C_N) return C_LF;
    if (c == C_T) return C_TAB;
    return c;
}

// The tokens of one line ([] for a blank or comment line). Fails on an
// unterminated quote, with Hedra's message: `unterminated quote in: <line>`.
export function tokenizeLine(line: string): Result<Array<string>> {
    const tokens: Array<string> = [];
    let units: Array<i32> = [];
    let inToken = false;
    const n = line.length;
    let i = 0;
    while (i < n) {
        const c = line.charCodeAt(i);
        i++;
        if (isUnicodeWhitespace(c)) {
            if (inToken) {
                tokens.push(String.fromCharCodes(units));
                units = [];
                inToken = false;
            }
        } else if (c == C_HASH && !inToken) {
            break;
        } else if (c == C_SQUOTE) {
            inToken = true;
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
            if (!closed) return Result.fail<Array<string>>("unterminated quote in: " + line);
        } else if (c == C_DQUOTE) {
            inToken = true;
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
                        return Result.fail<Array<string>>("unterminated quote in: " + line);
                    }
                } else {
                    units.push(d);
                }
            }
            if (!closed) return Result.fail<Array<string>>("unterminated quote in: " + line);
        } else if (c == C_BACKSLASH) {
            inToken = true;
            if (i < n) {
                units.push(unescape(line.charCodeAt(i)));
                i++;
            }
        } else {
            inToken = true;
            units.push(c);
        }
    }
    if (inToken) tokens.push(String.fromCharCodes(units));
    return Result.okv<Array<string>>(tokens);
}

// Where each token of a line lies in it, as [start, end) pairs of UTF-16
// offsets over the token's text as written (its quotes and escapes
// included): what replaceToken needs to change one token and keep the rest
// of the line as it was. Same rules as tokenizeLine; [] for an unterminated
// quote, which tokenizeLine refuses.
export function tokenSpans(line: string): Array<i32> {
    const spans: Array<i32> = [];
    const n = line.length;
    let start = -1;
    let i = 0;
    while (i < n) {
        const c = line.charCodeAt(i);
        if (isUnicodeWhitespace(c)) {
            if (start >= 0) {
                spans.push(start);
                spans.push(i);
                start = -1;
            }
            i++;
            continue;
        }
        if (c == C_HASH && start < 0) break;
        if (start < 0) start = i;
        i++;
        if (c == C_SQUOTE || c == C_DQUOTE) {
            let closed = false;
            while (i < n) {
                const d = line.charCodeAt(i);
                i++;
                if (d == c) {
                    closed = true;
                    break;
                }
                if (c == C_DQUOTE && d == C_BACKSLASH) i++;
            }
            if (!closed || i > n) return [];
        } else if (c == C_BACKSLASH) {
            if (i < n) i++;
        }
    }
    if (start >= 0) {
        spans.push(start);
        spans.push(n);
    }
    return spans;
}

// The line with its token `index` (as tokenizeLine counts them) written
// `token` (quoteToken), every other character kept as it was: so a flag
// stays bare and a quoted name stays quoted, which re-joining every token
// through quoteToken would not keep (it quotes a bare `--flag`, and the
// data reader takes a quoted word for a value). The line itself when it
// has no such token.
export function replaceToken(line: string, index: i32, token: string): string {
    const spans = tokenSpans(line);
    if (index < 0 || index * 2 + 1 >= spans.length) return line;
    return line.substring(0, spans[index * 2]) + quoteToken(token) + line.substring(spans[index * 2 + 1]);
}

// Whether a line holds no command: blank, or a comment (its first token
// would start with `#`).
export function isBlankOrComment(line: string): bool {
    const n = line.length;
    for (let i = 0; i < n; i++) {
        const c = line.charCodeAt(i);
        if (isUnicodeWhitespace(c)) continue;
        return c == C_HASH;
    }
    return true;
}

// The first word of a line (the command's first token as a bare word: no
// quote or escape is looked into), "" for a blank or comment line. Cheap:
// what a reader dispatches on before it tokenizes, or instead (a data line).
export function firstWord(line: string): string {
    const n = line.length;
    let a = 0;
    while (a < n && isUnicodeWhitespace(line.charCodeAt(a))) a++;
    if (a >= n || line.charCodeAt(a) == C_HASH) return "";
    let b = a;
    while (b < n && !isUnicodeWhitespace(line.charCodeAt(b))) b++;
    return line.substring(a, b);
}

// A token as text that tokenizeLine gives back verbatim: bare when it can
// be, else double-quoted with `"` and `\` escaped, and a line feed and a tab
// written `\n` and `\t`. A token starting with `--` is quoted too, so that
// a name is never read as a flag (a negative number stays bare).
export function quoteToken(token: string): string {
    const n = token.length;
    let needs = n == 0 || (n >= 2 && token.charCodeAt(0) == 0x2D && token.charCodeAt(1) == 0x2D);
    for (let i = 0; i < n && !needs; i++) {
        const c = token.charCodeAt(i);
        if (isUnicodeWhitespace(c) || c == C_DQUOTE || c == C_SQUOTE || c == C_HASH || c == C_BACKSLASH) needs = true;
    }
    if (!needs) return token;
    const parts: Array<string> = ["\""];
    let start = 0;
    for (let i = 0; i < n; i++) {
        const c = token.charCodeAt(i);
        if (c == C_DQUOTE || c == C_BACKSLASH || c == C_LF || c == C_TAB) {
            parts.push(token.substring(start, i));
            parts.push(c == C_LF ? "\\n" : c == C_TAB ? "\\t" : c == C_DQUOTE ? "\\\"" : "\\\\");
            start = i + 1;
        }
    }
    parts.push(token.substring(start));
    parts.push("\"");
    return parts.join("");
}

// Tokens joined into one line, each quoted as needed.
export function joinTokens(tokens: Array<string>): string {
    const parts = new Array<string>(tokens.length);
    for (let i = 0; i < tokens.length; i++) parts[i] = quoteToken(tokens[i]);
    return parts.join(" ");
}
