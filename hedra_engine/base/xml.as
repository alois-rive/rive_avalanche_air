// An XML 1.0 reader and writer for the scene format (.rscn,
// docs/formats/RSCN.md), small and strict: it keeps everything a round trip
// needs (comments, CDATA sections, processing instructions, the text between
// elements verbatim) and the position of everything it read, so that every
// error above it can name file:line:column.
//
// What it reads: UTF-8 (a BOM is skipped; bad UTF-8 is an error), the XML
// declaration, elements, attributes in single or double quotes, text,
// CDATA, comments and processing instructions; the five predefined
// entities and character references (&#N; &#xN;). Line ends are normalised
// first (\r\n and a lone \r become \n), as XML requires, and attribute
// values are normalised (a literal tab, newline or carriage return becomes a
// space; a character reference keeps its character). What it refuses: a
// DOCTYPE (no entity expansion, ever), undeclared entities, a second root,
// text outside the root, mismatched or unclosed tags, duplicate attributes,
// `<` in an attribute value, `--` in a comment and `]]>` in text.
// Namespaces are not interpreted: a colon is a name character.
//
// Positions are 1-based; a column counts Unicode code points from the start
// of its line (a tab counts one). Characters XML forbids (controls other
// than tab and newline, U+FFFE, U+FFFF, unpaired surrogates) are refused
// wherever they appear, so that nothing read can fail to be written back.

import { ErrorValue, Result, StringBuilder } from "./util";

// A position in the source: line and column, both 1-based (0 when unknown,
// for nodes built in code).
export class XmlPos {
    line: i32 = 0;
    col: i32 = 0;

    constructor(line: i32 = 0, col: i32 = 0) {
        this.line = line;
        this.col = col;
    }

    isKnown(): bool {
        return this.line > 0;
    }

    clone(): XmlPos {
        return new XmlPos(this.line, this.col);
    }
}

// The position of what was built in code rather than read: the default of
// every node's and attribute's positions, shared (a reader replaces each
// with its own, so a document read allocates none of them; nothing sets a
// position's fields in place). Never modify it.
const NO_POS: XmlPos = new XmlPos();

export enum XmlKind {
    Element,
    Text,
    CData,
    Comment,
    // A processing instruction other than the XML declaration.
    Pi,
}

export class XmlAttr {
    name: string = "";
    // The decoded, normalised value.
    value: string = "";
    // The value as written between its quotes (entities not decoded): what
    // `positionAt` walks. Empty for an attribute built in code.
    raw: string = "";
    // The attribute's name in the source.
    pos: XmlPos = NO_POS;
    // The first character after the opening quote.
    valuePos: XmlPos = NO_POS;

    constructor(name: string = "", value: string = "") {
        this.name = name;
        this.value = value;
    }

    // The source position of character `offset` (a UTF-16 index) of the
    // decoded `value`: an entity counts as the one character it decodes to
    // and lies where its `&` is. Past the end: the closing quote. For an
    // attribute built in code: valuePos.
    positionAt(offset: i32): XmlPos {
        if (!this.valuePos.isKnown()) return this.valuePos.clone();
        return walkSource(this.raw, this.valuePos, offset, true);
    }
}

export class XmlNode {
    kind: XmlKind = XmlKind.Element;
    // Element: its tag name. Pi: its target.
    name: string = "";
    // Text: the decoded text. CData, Comment, Pi: the content verbatim
    // (between `<![CDATA[` and `]]>`, `<!--` and `-->`, the target and `?>`,
    // leading space of a PI dropped).
    text: string = "";
    // Text: the source as written (entities not decoded). Empty otherwise.
    raw: string = "";
    // Element: attributes in source order.
    attrs: Array<XmlAttr> = [];
    // Element: its content in source order (whitespace text included).
    children: Array<XmlNode> = [];
    // Element: `<`; Text: its first character; CData, Comment, Pi: `<`.
    pos: XmlPos = NO_POS;
    // Text: == pos. CData: the first character after `<![CDATA[`. Element:
    // the first character after the start tag's `>` (for `<x/>`, the `/`).
    contentPos: XmlPos = NO_POS;
    // Element: the `<` of its end tag, or the `/` of `/>`.
    endPos: XmlPos = NO_POS;
    // Element: written `<x/>` in the source.
    selfClosing: bool = false;

    static element(name: string): XmlNode {
        const n = new XmlNode();
        n.kind = XmlKind.Element;
        n.name = name;
        return n;
    }

    static textNode(text: string): XmlNode {
        const n = new XmlNode();
        n.kind = XmlKind.Text;
        n.text = text;
        return n;
    }

    static cdata(text: string): XmlNode {
        const n = new XmlNode();
        n.kind = XmlKind.CData;
        n.text = text;
        return n;
    }

    static comment(text: string): XmlNode {
        const n = new XmlNode();
        n.kind = XmlKind.Comment;
        n.text = text;
        return n;
    }

    // The attribute's value, or null.
    attr(name: string): string? {
        const a = this.attrNode(name);
        return a != null ? a.value : null;
    }

    attrNode(name: string): XmlAttr? {
        for (let i = 0; i < this.attrs.length; i++) {
            if (this.attrs[i].name == name) return this.attrs[i];
        }
        return null;
    }

    // Sets an attribute, in place when it exists, else appended.
    setAttr(name: string, value: string): void {
        const a = this.attrNode(name);
        if (a != null) {
            a.value = value;
            a.raw = "";
            return;
        }
        this.attrs.push(new XmlAttr(name, value));
    }

    // The element children, in order.
    elements(): Array<XmlNode> {
        const out = new Array<XmlNode>();
        for (let i = 0; i < this.children.length; i++) {
            if (this.children[i].kind == XmlKind.Element) out.push(this.children[i]);
        }
        return out;
    }

    // The Text and CData children concatenated.
    textContent(): string {
        let s = "";
        for (let i = 0; i < this.children.length; i++) {
            const c = this.children[i];
            if (c.kind == XmlKind.Text || c.kind == XmlKind.CData) s += c.text;
        }
        return s;
    }

    // Text and CData: the source position of character `offset` (a UTF-16
    // index) of `text`, as XmlAttr.positionAt. Other kinds: pos.
    positionAt(offset: i32): XmlPos {
        if (!this.contentPos.isKnown()) return this.pos.clone();
        // Text walks what was written (entities count as the character they
        // stand for); a CDATA section's text is its source as it stands.
        if (this.kind == XmlKind.Text) return walkSource(this.raw, this.contentPos, offset, true);
        if (this.kind == XmlKind.CData) return walkSource(this.text, this.contentPos, offset, false);
        return this.pos.clone();
    }
}

// `<?xml version="1.0" encoding="UTF-8"?>`.
export class XmlDecl {
    version: string = "1.0";
    encoding: string? = null;
    standalone: string? = null;
}

export class XmlDocument {
    // The name errors give the source (a path as the caller shows it).
    file: string = "";
    decl: XmlDecl? = null;
    // Comments and processing instructions before and after the root
    // (whitespace between them is not kept).
    prolog: Array<XmlNode> = [];
    root: XmlNode = XmlNode.element("");
    epilog: Array<XmlNode> = [];
}

// A syntax error: `<file>:<line>:<col>: <message>`.
export class XmlError extends ErrorValue {
    file: string;
    pos: XmlPos;
    message: string;

    constructor(file: string, pos: XmlPos, message: string) {
        super();
        this.file = file;
        this.pos = pos;
        this.message = message;
    }

    toString(): string {
        return this.file + ":" + this.pos.line.toString() + ":" + this.pos.col.toString() + ": " + this.message;
    }

    fail<T>(): Result<T> {
        return Result.failWith<T>(this);
    }
}

export function xmlErrorOf<T>(r: Result<T>): XmlError? {
    if (r.ok) return null;
    const c = r.cause;
    if (c == null) return null;
    const isXml = c instanceof XmlError;
    if (isXml) return c as XmlError;
    return null;
}


// ---------------------------------------------------------------------------
// Characters

function isXmlSpace(c: i32): bool {
    return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
}

// XML Names, simplified the way the format needs: an ASCII letter, `_`, `:`
// or any non-ASCII character to start, then also digits, `-` and `.`.
function isNameStart(c: i32): bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 58 || c >= 0x80;
}

function isNameChar(c: i32): bool {
    return isNameStart(c) || (c >= 48 && c <= 57) || c == 45 || c == 46;
}

// The ASCII characters by class, for the reader's hot loops: CC_SPACE as
// isXmlSpace, CC_NAME as isNameChar (every character from 0x80 is a name
// character too).
const CC_SPACE: u8 = 1;
const CC_NAME: u8 = 2;
const CHAR_CLASS: StaticArray<u8> = charClasses();

function charClasses(): StaticArray<u8> {
    const t = new StaticArray<u8>(128);
    for (let c = 0; c < 128; c++) {
        let v: u8 = 0;
        if (isXmlSpace(c)) v |= CC_SPACE;
        if (isNameChar(c)) v |= CC_NAME;
        t[c] = v;
    }
    return t;
}

// Why `s` cannot stand in an XML 1.0 document, even escaped, or "" when it
// can: a C0 control other than tab, line feed and carriage return (no
// character reference may name one either), U+FFFE, U+FFFF or a lone
// surrogate. A writer checks a value with it before writing (the reader
// would refuse the document: checkChars).
export function xmlCharProblem(s: string): string {
    const n = s.length;
    for (let k = 0; k < n; k++) {
        const c = <i32>s.charCodeAt(k);
        if (c >= 0x20 && c < 0xD800) continue;
        if (c == 0x09 || c == 0x0A || c == 0x0D) continue;
        if (isHighSurrogate(c)) {
            const d = k + 1 < n ? <i32>s.charCodeAt(k + 1) : 0;
            if (d >= 0xDC00 && d <= 0xDFFF) {
                k++;
                continue;
            }
            return "an unpaired surrogate " + codePointName(c);
        }
        if (c >= 0xDC00 && c <= 0xDFFF) return "an unpaired surrogate " + codePointName(c);
        if (c >= 0xE000 && c <= 0xFFFD) continue;
        return "the character " + codePointName(c);
    }
    return "";
}

// XML 1.0's Char production: what a character reference may name.
function isXmlChar(cp: i32): bool {
    if (cp == 0x09 || cp == 0x0A || cp == 0x0D) return true;
    if (cp >= 0x20 && cp <= 0xD7FF) return true;
    if (cp >= 0xE000 && cp <= 0xFFFD) return true;
    return cp >= 0x10000 && cp <= 0x10FFFF;
}

function hexDigit(c: i32): i32 {
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 97 && c <= 102) return c - 87;
    if (c >= 65 && c <= 70) return c - 55;
    return -1;
}

// "U+0001" for messages.
function codePointName(cp: i32): string {
    let h = cp.toString(16).toUpperCase();
    while (h.length < 4) h = "0" + h;
    return "U+" + h;
}

// The code point a character reference's body (`#65`, `#x41`, without `&`
// and `;`) names; -1 when it is not a well-formed number. Values past
// U+10FFFF saturate at 0x110000 so that an absurd reference cannot overflow.
function charRefValue(body: string): i32 {
    if (body.length < 2 || body.charCodeAt(0) != 35) return -1;
    const hex = body.charCodeAt(1) == 120;
    const from = hex ? 2 : 1;
    if (from >= body.length) return -1;
    let v = 0;
    for (let k = from; k < body.length; k++) {
        const c = body.charCodeAt(k);
        const d = hex ? hexDigit(c) : (c >= 48 && c <= 57 ? c - 48 : -1);
        if (d < 0) return -1;
        v = v * (hex ? 16 : 10) + d;
        if (v > 0x10FFFF) v = 0x110000;
    }
    return v;
}

// How many UTF-16 units the entity `&body;` decodes to (1, or 2 for a
// character reference past the BMP).
function entityUnits(body: string): i32 {
    const cp = charRefValue(body);
    return cp > 0xFFFF ? 2 : 1;
}

// The position of decoded offset `offset` in `src`, a stretch of source that
// starts at `start` (XmlAttr.positionAt, XmlNode.positionAt). `entities`:
// `&...;` counts as the one character it decodes to.
function walkSource(src: string, start: XmlPos, offset: i32, entities: bool): XmlPos {
    let line = start.line;
    let col = start.col;
    let units = 0;
    let k = 0;
    const n = src.length;
    while (k < n) {
        const c = src.charCodeAt(k);
        let len = 1;
        let u = 1;
        let cols = 1;
        if (entities && c == 38) {
            const semi = src.indexOf(";", k);
            if (semi > k) {
                len = semi - k + 1;
                u = entityUnits(src.substring(k + 1, semi));
                cols = len;
            }
        } else if (c >= 0xD800 && c <= 0xDBFF && k + 1 < n) {
            len = 2;
            u = 2;
        }
        if (offset < units + u) return new XmlPos(line, col);
        units += u;
        if (c == 10) {
            line++;
            col = 1;
        } else {
            col += cols;
        }
        k += len;
    }
    return new XmlPos(line, col);
}

// ---------------------------------------------------------------------------
// Positions of a whole text

// Maps UTF-16 indices of the (normalised) source to line:col. Most lookups
// move forward through the text, so the last answer is kept and a lookup
// further along the same line continues from it rather than recounting the
// line (a long single-line file would otherwise cost a scan per node).
//
// The Reader fills `starts` in the pass that checks the characters
// (checkChars), so that the text is not walked once more for its line ends
// (milestone 13: a pass over a 2 MB scene is 20 ms), and notes whether it
// holds a surrogate pair at all: without one a column is the index less its
// line's start (plus one), found without walking the line.
class Locator {
    s: string;
    starts: Array<i32> = [0];
    // Every line start is in `starts`, and `plain` is known.
    complete: bool = false;
    // No surrogate pair in the text: every UTF-16 unit is a column.
    plain: bool = false;
    cIdx: i32 = 0;
    cLine: i32 = 1;
    cCol: i32 = 1;

    constructor(s: string, scan: bool = true) {
        this.s = s;
        if (scan) this.scan();
    }

    scan(): void {
        const s = this.s;
        const starts = new Array<i32>();
        starts.push(0);
        let plain = true;
        for (let k = 0; k < s.length; k++) {
            const c = s.charCodeAt(k);
            if (c == 10) starts.push(k + 1);
            else if (c >= 0xD800 && c <= 0xDFFF) plain = false;
        }
        this.starts = starts;
        this.plain = plain;
        this.complete = true;
    }

    at(idx: i32): XmlPos {
        if (!this.complete) this.scan();
        const s = this.s;
        if (idx > s.length) idx = s.length;
        if (this.plain) {
            const starts = this.starts;
            const count = starts.length;
            let lo = this.cLine - 1;
            if (idx < unchecked(starts[lo]) || (lo + 8 < count && unchecked(starts[lo + 8]) <= idx)) {
                lo = 0;
                let hi = count - 1;
                while (lo < hi) {
                    const mid = (lo + hi + 1) >> 1;
                    if (unchecked(starts[mid]) <= idx) lo = mid;
                    else hi = mid - 1;
                }
            } else {
                while (lo + 1 < count && unchecked(starts[lo + 1]) <= idx) lo++;
            }
            this.cLine = lo + 1;
            return new XmlPos(lo + 1, idx - unchecked(starts[lo]) + 1);
        }
        let line: i32;
        let col: i32;
        let from: i32;
        const nextStart = this.cLine < this.starts.length ? this.starts[this.cLine] : s.length + 1;
        if (idx >= this.cIdx && idx < nextStart) {
            line = this.cLine;
            col = this.cCol;
            from = this.cIdx;
        } else {
            let lo = 0;
            let hi = this.starts.length - 1;
            while (lo < hi) {
                const mid = (lo + hi + 1) >> 1;
                if (this.starts[mid] <= idx) lo = mid;
                else hi = mid - 1;
            }
            line = lo + 1;
            col = 1;
            from = this.starts[lo];
        }
        for (let k = from; k < idx; k++) {
            const c = s.charCodeAt(k);
            // The second half of a surrogate pair is the same code point.
            if (!(c >= 0xDC00 && c <= 0xDFFF && k > 0 && isHighSurrogate(s.charCodeAt(k - 1)))) col++;
        }
        this.cIdx = idx;
        this.cLine = line;
        this.cCol = col;
        return new XmlPos(line, col);
    }
}

function isHighSurrogate(c: i32): bool {
    return c >= 0xD800 && c <= 0xDBFF;
}

// \r\n and a lone \r become \n, before anything else reads the text (XML
// 1.0 section 2.11), so that a CRLF file reads, and reports lines, exactly
// as its LF twin.
function normaliseLineEnds(s: string): string {
    if (s.indexOf("\r") < 0) return s;
    const out = new StringBuilder();
    let from = 0;
    const n = s.length;
    for (let k = 0; k < n; k++) {
        if (s.charCodeAt(k) != 13) continue;
        out.push(s.substring(from, k));
        out.push("\n");
        if (k + 1 < n && s.charCodeAt(k + 1) == 10) k++;
        from = k + 1;
    }
    out.push(s.substring(from));
    return out.toString();
}

// ---------------------------------------------------------------------------
// The reader

class Reader {
    s: string;
    n: i32;
    i: i32 = 0;
    file: string;
    loc: Locator;
    err: XmlError? = null;
    // parseXmlHead: the element names the root's head holds; the first
    // child element of the root named otherwise ends the reading.
    head: Array<string>? = null;
    stopped: bool = false;
    // The text is a head cut out of a longer one (parseXmlHead): its end,
    // between two children of the root, ends the reading too.
    cutShort: bool = false;

    constructor(s: string, file: string) {
        this.s = s;
        this.n = s.length;
        this.file = file;
        // (checkChars fills its line starts)
        this.loc = new Locator(s, false);
    }

    pos(idx: i32): XmlPos {
        return this.loc.at(idx);
    }

    // Records the first error (the one reported) and returns false, so that
    // every step can `return this.fail(...)`.
    fail(idx: i32, message: string): bool {
        if (this.err == null) this.err = new XmlError(this.file, this.pos(idx), message);
        return false;
    }

    c(idx: i32): i32 {
        return idx < this.n ? <i32>this.s.charCodeAt(idx) : -1;
    }

    // Whether the text at `idx` starts with `lit`.
    has(idx: i32, lit: string): bool {
        if (idx + lit.length > this.n) return false;
        for (let k = 0; k < lit.length; k++) if (this.s.charCodeAt(idx + k) != lit.charCodeAt(k)) return false;
        return true;
    }

    // (skipSpace and readName run over most of a document, so they read
    // the text directly and test ASCII by table: a scene of 10,000 nodes
    // is 2 million characters.)
    skipSpace(): bool {
        const from = this.i;
        const s = this.s;
        const n = this.n;
        let k = from;
        while (k < n) {
            const c = <i32>s.charCodeAt(k);
            if (c >= 128 || (unchecked(CHAR_CLASS[c]) & CC_SPACE) == 0) break;
            k++;
        }
        this.i = k;
        return k > from;
    }

    readName(): string {
        const from = this.i;
        if (!isNameStart(this.c(from))) return "";
        const s = this.s;
        const n = this.n;
        let k = from + 1;
        while (k < n) {
            const c = <i32>s.charCodeAt(k);
            if (c < 128 && (unchecked(CHAR_CLASS[c]) & CC_NAME) == 0) break;
            k++;
        }
        this.i = k;
        return s.substring(from, k);
    }

    // Characters XML refuses anywhere in a document. One scan up front
    // keeps the checks out of every construct below; it notes the line
    // starts and whether a surrogate pair occurs for the Locator on the way.
    checkChars(): bool {
        const s = this.s;
        const starts = new Array<i32>();
        starts.push(0);
        let plain = true;
        for (let k = 0; k < this.n; k++) {
            const c = <i32>s.charCodeAt(k);
            if (c >= 0x20 && c < 0xD800) continue;
            if (c == 0x0A) {
                starts.push(k + 1);
                continue;
            }
            if (c == 0x09) continue;
            if (isHighSurrogate(c)) {
                const d = this.c(k + 1);
                if (d >= 0xDC00 && d <= 0xDFFF) {
                    plain = false;
                    k++;
                    continue;
                }
                return this.fail(k, "unpaired surrogate " + codePointName(c));
            }
            if (c >= 0xDC00 && c <= 0xDFFF) return this.fail(k, "unpaired surrogate " + codePointName(c));
            if (c >= 0xE000 && c <= 0xFFFD) continue;
            return this.fail(k, "character " + codePointName(c) + " is not allowed in XML");
        }
        const loc = this.loc;
        loc.starts = starts;
        loc.plain = plain;
        loc.complete = true;
        return true;
    }

    // Decodes entities in `raw`, which starts at index `base` of the source.
    // `attr`: attribute-value normalisation (a literal tab or newline is a
    // space). Null on error (recorded).
    decode(raw: string, base: i32, attr: bool): string? {
        if (raw.indexOf("&") < 0 && (!attr || (raw.indexOf("\t") < 0 && raw.indexOf("\n") < 0))) return raw;
        const out = new StringBuilder();
        const n = raw.length;
        let from = 0;
        for (let k = 0; k < n; k++) {
            const c = raw.charCodeAt(k);
            if (attr && (c == 9 || c == 10)) {
                out.push(raw.substring(from, k));
                out.push(" ");
                from = k + 1;
                continue;
            }
            if (c != 38) continue;
            out.push(raw.substring(from, k));
            // A character reference may carry any number of leading zeros
            // (charRefValue saturates), so it is scanned to its ';'; a named
            // entity is at most 4 characters, so a longer run is not one.
            const charRef = k + 1 < n && raw.charCodeAt(k + 1) == 35;
            let j = k + 1;
            while (j < n && (charRef || j - k < 40)) {
                const d = raw.charCodeAt(j);
                if (d == 59 || d == 38 || isXmlSpace(d)) break;
                j++;
            }
            if (j >= n || raw.charCodeAt(j) != 59) {
                this.fail(base + k, "'&' does not start an entity (write &amp; for a literal &)");
                return null;
            }
            const body = raw.substring(k + 1, j);
            if (body == "lt") out.push("<");
            else if (body == "gt") out.push(">");
            else if (body == "amp") out.push("&");
            else if (body == "quot") out.push("\"");
            else if (body == "apos") out.push("'");
            else if (body.length > 0 && body.charCodeAt(0) == 35) {
                const cp = charRefValue(body);
                if (cp < 0) {
                    this.fail(base + k, "invalid character reference &" + body + ";");
                    return null;
                }
                if (!isXmlChar(cp)) {
                    this.fail(base + k, "&" + body + "; is not an XML character");
                    return null;
                }
                out.push(String.fromCodePoint(cp));
            } else {
                this.fail(base + k, "unknown entity &" + body + ";");
                return null;
            }
            from = j + 1;
            k = j;
        }
        out.push(raw.substring(from));
        return out.toString();
    }

    document(): XmlDocument? {
        const doc = new XmlDocument();
        doc.file = this.file;
        if (!this.checkChars()) return null;
        if (this.has(0, "<?xml") && (isXmlSpace(this.c(5)) || this.c(5) == 63)) {
            const d = this.declaration();
            if (d == null) return null;
            doc.decl = d;
        }
        if (!this.misc(doc.prolog, false)) return null;
        const root = this.element();
        if (root == null) return null;
        doc.root = root;
        if (this.stopped) return doc;
        if (!this.misc(doc.epilog, true)) return null;
        return doc;
    }

    // `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>`: its
    // pseudo-attributes in that order, version required.
    declaration(): XmlDecl? {
        const d = new XmlDecl();
        this.i = 5;
        const names = ["version", "encoding", "standalone"];
        let next = 0;
        while (true) {
            const had = this.skipSpace();
            if (this.has(this.i, "?>")) {
                this.i += 2;
                break;
            }
            if (this.i >= this.n) {
                this.fail(0, "unterminated XML declaration");
                return null;
            }
            const at = this.i;
            const name = this.readName();
            if (name.length == 0 || !had) {
                this.fail(at, "expected a pseudo-attribute or '?>' in the XML declaration");
                return null;
            }
            let k = next;
            while (k < names.length && names[k] != name) k++;
            if (k >= names.length) {
                this.fail(at, "unexpected " + name + " in the XML declaration");
                return null;
            }
            if (next == 0 && k != 0) {
                this.fail(at, "the XML declaration starts with version");
                return null;
            }
            next = k + 1;
            this.skipSpace();
            if (this.c(this.i) != 61) {
                this.fail(this.i, "expected '=' after " + name);
                return null;
            }
            this.i++;
            this.skipSpace();
            const q = this.c(this.i);
            if (q != 34 && q != 39) {
                this.fail(this.i, "expected a quoted value for " + name);
                return null;
            }
            const vAt = this.i + 1;
            const end = this.s.indexOf(String.fromCharCode(q), vAt);
            if (end < 0) {
                this.fail(this.i, "unterminated value of " + name);
                return null;
            }
            const v = this.s.substring(vAt, end);
            this.i = end + 1;
            if (k == 0) {
                if (!(v.length >= 3 && v.startsWith("1.") && isDigits(v.substring(2)))) {
                    this.fail(vAt, "unsupported XML version \"" + v + "\"");
                    return null;
                }
                d.version = v;
            } else if (k == 1) {
                if (v.toLowerCase() != "utf-8") {
                    this.fail(vAt, "encoding \"" + v + "\" is not supported: the file must be UTF-8");
                    return null;
                }
                d.encoding = v;
            } else {
                if (v != "yes" && v != "no") {
                    this.fail(vAt, "standalone must be \"yes\" or \"no\", found \"" + v + "\"");
                    return null;
                }
                d.standalone = v;
            }
        }
        if (next == 0) {
            this.fail(0, "the XML declaration needs a version");
            return null;
        }
        return d;
    }

    // Comments, PIs and whitespace before (`after` false) or after the root.
    // Before: stops at the root's `<`. After: runs to the end.
    misc(into: Array<XmlNode>, after: bool): bool {
        while (true) {
            this.skipSpace();
            if (this.i >= this.n) {
                if (!after) return this.fail(this.n, "no root element");
                return true;
            }
            if (this.has(this.i, "<!--")) {
                const cm = this.comment();
                if (cm == null) return false;
                into.push(cm);
            } else if (this.has(this.i, "<?")) {
                const pi = this.pi();
                if (pi == null) return false;
                into.push(pi);
            } else if (this.has(this.i, "<!DOCTYPE")) {
                return this.fail(this.i, "DOCTYPE is not supported");
            } else if (this.c(this.i) == 60 && isNameStart(this.c(this.i + 1))) {
                if (!after) return true;
                const at = this.i;
                this.i++;
                return this.fail(at, "a second root element <" + this.readName() + ">: a document has one root");
            } else {
                return this.fail(this.i, "text outside the root element");
            }
        }
    }

    comment(): XmlNode? {
        const start = this.i;
        const from = start + 4;
        let k = from;
        while (true) {
            k = this.s.indexOf("--", k);
            if (k < 0) {
                this.fail(start, "unterminated comment");
                return null;
            }
            if (this.c(k + 2) == 62) break;
            this.fail(k, "'--' is not allowed inside a comment");
            return null;
        }
        const n = new XmlNode();
        n.kind = XmlKind.Comment;
        n.text = this.s.substring(from, k);
        n.pos = this.pos(start);
        this.i = k + 3;
        return n;
    }

    cdata(): XmlNode? {
        const start = this.i;
        const from = start + 9;
        const end = this.s.indexOf("]]>", from);
        if (end < 0) {
            this.fail(start, "unterminated CDATA section");
            return null;
        }
        const n = new XmlNode();
        n.kind = XmlKind.CData;
        n.text = this.s.substring(from, end);
        n.pos = this.pos(start);
        n.contentPos = this.pos(from);
        this.i = end + 3;
        return n;
    }

    pi(): XmlNode? {
        const start = this.i;
        this.i += 2;
        const target = this.readName();
        if (target.length == 0) {
            this.fail(this.i, "expected a processing instruction target after <?");
            return null;
        }
        if (target.toLowerCase() == "xml") {
            this.fail(start, "the XML declaration is allowed only at the very start of the document");
            return null;
        }
        const n = new XmlNode();
        n.kind = XmlKind.Pi;
        n.name = target;
        n.pos = this.pos(start);
        if (this.has(this.i, "?>")) {
            this.i += 2;
            return n;
        }
        if (!this.skipSpace()) {
            this.fail(this.i, "expected a space or '?>' after <?" + target);
            return null;
        }
        const end = this.s.indexOf("?>", this.i);
        if (end < 0) {
            this.fail(start, "unterminated processing instruction <?" + target);
            return null;
        }
        n.text = this.s.substring(this.i, end);
        this.i = end + 2;
        return n;
    }

    // Text up to the next `<`: one pass that also finds a `]]>` (refused)
    // and whether there is an entity to decode.
    text(): XmlNode? {
        const start = this.i;
        const s = this.s;
        const len = this.n;
        let end = start;
        let amp = false;
        let bad = -1;
        while (end < len) {
            const c = s.charCodeAt(end);
            if (c == 60) break;
            if (c == 38) amp = true;
            else if (c == 93 && bad < 0 && end + 2 < len && s.charCodeAt(end + 1) == 93 && s.charCodeAt(end + 2) == 62) bad = end;
            end++;
        }
        if (bad >= 0) {
            this.fail(bad, "']]>' is not allowed in text");
            return null;
        }
        const raw = s.substring(start, end);
        const t = amp ? this.decode(raw, start, false) : raw;
        if (t == null) return null;
        const n = new XmlNode();
        n.kind = XmlKind.Text;
        n.text = t;
        n.raw = raw;
        n.pos = this.pos(start);
        // (the same position: nothing changes a position in place)
        n.contentPos = n.pos;
        this.i = end;
        return n;
    }

    // `<name attr="v" ...>` or `<name .../>`, at `<`.
    startTag(): XmlNode? {
        const start = this.i;
        this.i++;
        const name = this.readName();
        if (name.length == 0) {
            this.fail(this.i, "expected an element name after '<'");
            return null;
        }
        const el = XmlNode.element(name);
        el.pos = this.pos(start);
        while (true) {
            const had = this.skipSpace();
            if (this.has(this.i, "/>")) {
                el.selfClosing = true;
                el.contentPos = this.pos(this.i);
                el.endPos = el.contentPos.clone();
                this.i += 2;
                return el;
            }
            if (this.c(this.i) == 62) {
                this.i++;
                el.contentPos = this.pos(this.i);
                return el;
            }
            if (this.i >= this.n) {
                this.fail(this.n, "unterminated start tag <" + name + ">");
                return null;
            }
            if (!isNameStart(this.c(this.i))) {
                this.fail(this.i, "expected an attribute name, '>' or '/>' in <" + name + ">");
                return null;
            }
            if (!had) {
                this.fail(this.i, "expected a space before the attribute");
                return null;
            }
            const at = this.i;
            const an = this.readName();
            this.skipSpace();
            if (this.c(this.i) != 61) {
                this.fail(this.i, "expected '=' after attribute " + an);
                return null;
            }
            this.i++;
            this.skipSpace();
            const q = this.c(this.i);
            if (q != 34 && q != 39) {
                this.fail(this.i, "expected a quoted value for attribute " + an);
                return null;
            }
            const vFrom = this.i + 1;
            let k = vFrom;
            // An entity, a tab or a newline: the value needs decoding.
            let special = false;
            const s = this.s;
            while (k < this.n) {
                const d = <i32>s.charCodeAt(k);
                if (d == q) break;
                if (d == 60) {
                    this.fail(k, "'<' is not allowed in an attribute value");
                    return null;
                }
                if (d == 38 || d == 9 || d == 10) special = true;
                k++;
            }
            if (k >= this.n) {
                this.fail(this.i, "unterminated value of attribute " + an);
                return null;
            }
            const raw = this.s.substring(vFrom, k);
            if (el.attrNode(an) != null) {
                this.fail(at, "duplicate attribute " + an);
                return null;
            }
            const v = special ? this.decode(raw, vFrom, true) : raw;
            if (v == null) return null;
            const a = new XmlAttr(an, v);
            a.raw = raw;
            a.pos = this.pos(at);
            a.valuePos = this.pos(vFrom);
            el.attrs.push(a);
            this.i = k + 1;
        }
    }

    // An element and everything in it, at its `<`. Iterative, with a stack
    // of open elements, so that a deep file cannot exhaust the call stack.
    element(): XmlNode? {
        const root = this.startTag();
        if (root == null) return null;
        if (root.selfClosing) return root;
        const open = new Array<XmlNode>();
        open.push(root);
        while (open.length > 0) {
            const cur = open[open.length - 1];
            if (this.i >= this.n && this.cutShort && open.length == 1) {
                this.stopped = true;
                return root;
            }
            if (this.i >= this.n) {
                this.fail(this.n, "unclosed element <" + cur.name + "> (opened at " + cur.pos.line.toString() + ":" + cur.pos.col.toString() + ")");
                return null;
            }
            let child: XmlNode? = null;
            // Text, the commonest child, is anything not at a `<`.
            if (this.c(this.i) != 60) {
                child = this.text();
                if (child == null) return null;
                cur.children.push(child);
                continue;
            }
            if (this.has(this.i, "</")) {
                const at = this.i;
                this.i += 2;
                const name = this.readName();
                if (name.length == 0) {
                    this.fail(this.i, "expected an element name after '</'");
                    return null;
                }
                if (name != cur.name) {
                    this.fail(at, "expected </" + cur.name + ">, found </" + name + ">");
                    return null;
                }
                this.skipSpace();
                if (this.c(this.i) != 62) {
                    this.fail(this.i, "expected '>' to end </" + name + ">");
                    return null;
                }
                this.i++;
                cur.endPos = this.pos(at);
                open.pop();
                continue;
            }
            if (this.has(this.i, "<!--")) child = this.comment();
            else if (this.has(this.i, "<![CDATA[")) child = this.cdata();
            else if (this.has(this.i, "<?")) child = this.pi();
            else if (this.has(this.i, "<!DOCTYPE")) {
                this.fail(this.i, "DOCTYPE is not supported");
                return null;
            } else if (this.has(this.i, "<!")) {
                this.fail(this.i, "expected a comment or CDATA section after '<!'");
                return null;
            } else if (this.c(this.i) == 60) {
                const head = this.head;
                if (head != null && open.length == 1) {
                    const at = this.i;
                    this.i++;
                    const name = this.readName();
                    this.i = at;
                    if (!head.includes(name)) {
                        this.stopped = true;
                        return root;
                    }
                }
                child = this.startTag();
                if (child != null) {
                    cur.children.push(child);
                    if (!child.selfClosing) open.push(child);
                    continue;
                }
            } else child = this.text();
            if (child == null) return null;
            cur.children.push(child);
        }
        return root;
    }
}

function isDigits(s: string): bool {
    if (s.length == 0) return false;
    for (let k = 0; k < s.length; k++) {
        const c = s.charCodeAt(k);
        if (c < 48 || c > 57) return false;
    }
    return true;
}

// The index of the first byte that is not well-formed UTF-8 (overlong
// forms, surrogates and code points past U+10FFFF included), or -1.
// Past the ASCII bytes of b[k..n): eight at a time, then one by one (most
// of a scene is ASCII).
unsafe function asciiRunEnd(b: Uint8Array, k: i32, n: i32): i32 {
    const base = b.dataStart;
    while (k + 8 <= n && (load<u64>(base + <usize>k) & 0x8080808080808080) == 0) k += 8;
    while (k < n && b[k] < 0x80) k++;
    return k;
}

function firstBadUtf8(b: Uint8Array, from: i32, to: i32 = -1): i32 {
    const n = to < 0 ? b.length : to;
    let k = from;
    while (k < n) {
        k = asciiRunEnd(b, k, n);
        if (k >= n) break;
        const c = <i32>b[k];
        if (c < 0x80) {
            k++;
            continue;
        }
        let need = 0;
        let lo = 0x80;
        let hi = 0xBF;
        if (c >= 0xC2 && c <= 0xDF) need = 1;
        else if (c == 0xE0) {
            need = 2;
            lo = 0xA0;
        } else if ((c >= 0xE1 && c <= 0xEC) || c == 0xEE || c == 0xEF) need = 2;
        else if (c == 0xED) {
            need = 2;
            hi = 0x9F;
        } else if (c == 0xF0) {
            need = 3;
            lo = 0x90;
        } else if (c >= 0xF1 && c <= 0xF3) need = 3;
        else if (c == 0xF4) {
            need = 3;
            hi = 0x8F;
        } else return k;
        if (k + need >= n) return k;
        for (let j = 1; j <= need; j++) {
            const d = <i32>b[k + j];
            const l = j == 1 ? lo : 0x80;
            const h = j == 1 ? hi : 0xBF;
            if (d < l || d > h) return k;
        }
        k += need + 1;
    }
    return -1;
}

function decodeUtf8(b: Uint8Array, from: i32, to: i32): string {
    if (to <= from) return "";
    return String.UTF8.decodeUnsafe(b.dataStart + <usize>from, <usize>(to - from));
}

// Parses a whole document from bytes (UTF-8). `file` names the source in
// errors.
export function parseXml(bytes: Uint8Array, file: string): Result<XmlDocument> {
    let from = 0;
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) from = 3;
    const bad = firstBadUtf8(bytes, from, bytes.length);
    if (bad >= 0) {
        // The position of the character the bad byte would have been: the
        // good text before it, read as the parser would have.
        const before = normaliseLineEnds(decodeUtf8(bytes, from, bad));
        const pos = new Locator(before).at(before.length);
        return new XmlError(file, pos, "invalid UTF-8").fail<XmlDocument>();
    }
    return parseNormalised(normaliseLineEnds(decodeUtf8(bytes, from, bytes.length)), file);
}

// Parses a whole document from a string (as parseXml after decoding).
export function parseXmlText(text: string, file: string): Result<XmlDocument> {
    const s = text.length > 0 && text.charCodeAt(0) == 0xFEFF ? text.substring(1) : text;
    return parseNormalised(normaliseLineEnds(s), file);
}

// The head of a document (bytes, as parseXml): the root's children up to
// the first element whose name `head` does not hold, which is not read, nor
// anything after it (the root is left without its end). For a reader that
// wants only what a document declares first, as Hedra's prefetcher wants
// only a scene's ext_resources: reading all of a 10,000-node scene for them
// took as long as loading it (milestone 13). What is read is checked as
// parseXml checks it; the characters of the whole text are too.
//
// Only the bytes up to the first `<` that starts an element named `stop`
// (any of them) are decoded and read, when the head then reads to its end
// between two children of the root: such a `<` inside a comment, say, makes
// that read fail, and the whole text is read instead.
export function parseXmlHead(bytes: Uint8Array, file: string, head: Array<string>, stop: Array<string>): Result<XmlDocument> {
    let from = 0;
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) from = 3;
    const cut = firstTagOf(bytes, from, stop);
    if (cut < bytes.length && firstBadUtf8(bytes, from, cut) < 0) {
        const r = new Reader(normaliseLineEnds(decodeUtf8(bytes, from, cut)), file);
        r.head = head;
        r.cutShort = true;
        const doc = r.document();
        if (r.err == null && doc != null && r.stopped) return Result.okv<XmlDocument>(doc);
    }
    const bad = firstBadUtf8(bytes, from, bytes.length);
    if (bad >= 0) {
        const before = normaliseLineEnds(decodeUtf8(bytes, from, bad));
        const pos = new Locator(before).at(before.length);
        return new XmlError(file, pos, "invalid UTF-8").fail<XmlDocument>();
    }
    return parseNormalised(normaliseLineEnds(decodeUtf8(bytes, from, bytes.length)), file, head);
}

// The index of the first `<` in `b` (from `from`) followed by one of the
// ASCII names in `names` and a character that cannot continue a name, or
// b.length.
function firstTagOf(b: Uint8Array, from: i32, names: Array<string>): i32 {
    const n = b.length;
    for (let k = from; k < n; k++) {
        if (b[k] != 60) continue;
        for (let j = 0; j < names.length; j++) {
            const name = names[j];
            const e = k + 1 + name.length;
            if (e >= n) continue;
            let same = true;
            for (let q = 0; q < name.length && same; q++) same = <i32>b[k + 1 + q] == <i32>name.charCodeAt(q);
            const after = <i32>b[e];
            if (same && (after >= 0x80 || (unchecked(CHAR_CLASS[after]) & CC_NAME) == 0)) return k;
        }
    }
    return n;
}

function parseNormalised(s: string, file: string, head: Array<string>? = null): Result<XmlDocument> {
    const r = new Reader(s, file);
    r.head = head;
    const doc = r.document();
    const e = r.err;
    if (e != null) return e.fail<XmlDocument>();
    if (doc == null) return new XmlError(file, new XmlPos(1, 1), "unreadable document").fail<XmlDocument>();
    return Result.okv<XmlDocument>(doc);
}

// ---------------------------------------------------------------------------
// The writer

// Text content: `&` `<` `>` as entities, `\r` as `&#13;` (so that it
// survives the reader's line-end normalisation).
export function escapeXmlText(s: string): string {
    return escapeWith(s, false);
}

// An attribute value for double quotes: `&` `<` `>` `"` as entities, and
// tab, newline and carriage return as `&#9;` `&#10;` `&#13;` (so that they
// survive attribute-value normalisation).
export function escapeXmlAttr(s: string): string {
    return escapeWith(s, true);
}

function escapeWith(s: string, attr: bool): string {
    let k = 0;
    const n = s.length;
    // The common case, nothing to escape, allocates nothing.
    for (; k < n; k++) if (escapeOf(s.charCodeAt(k), attr) != null) break;
    if (k == n) return s;
    const out = new StringBuilder();
    let from = 0;
    for (; k < n; k++) {
        const e = escapeOf(s.charCodeAt(k), attr);
        if (e == null) continue;
        out.push(s.substring(from, k));
        out.push(e);
        from = k + 1;
    }
    out.push(s.substring(from));
    return out.toString();
}

function escapeOf(c: i32, attr: bool): string? {
    switch (c) {
        case 38: return "&amp;";
        case 60: return "&lt;";
        case 62: return "&gt;";
        case 13: return "&#13;";
        case 34: return attr ? "&quot;" : null;
        case 9: return attr ? "&#9;" : null;
        case 10: return attr ? "&#10;" : null;
        default: return null;
    }
}

// One node and its subtree as XML, verbatim: text as its `raw` (else
// escaped `text`), attributes in order in double quotes (escaped values),
// an element without children as `<x/>`, comments, CDATA and PIs as they
// were. No indentation is added or removed. Iterative, with an explicit
// stack of open elements, as the reader's `element()` is: a file the reader
// accepts, however deep, must not exhaust the call stack when written back.
export function writeXmlNode(n: XmlNode, out: StringBuilder): void {
    if (writeXmlLeaf(n, out)) return;
    // The open elements, and for each the index of its next child.
    const open = new Array<XmlNode>();
    const next = new Array<i32>();
    if (openXmlElement(n, out)) {
        open.push(n);
        next.push(0);
    }
    while (open.length > 0) {
        const top = open.length - 1;
        const e = open[top];
        const k = next[top];
        if (k >= e.children.length) {
            out.push("</").push(e.name).push(">");
            open.pop();
            next.pop();
            continue;
        }
        next[top] = k + 1;
        const c = e.children[k];
        if (writeXmlLeaf(c, out)) continue;
        if (openXmlElement(c, out)) {
            open.push(c);
            next.push(0);
        }
    }
}

// Writes a node that is not an element; false (nothing written) for an
// element.
function writeXmlLeaf(n: XmlNode, out: StringBuilder): bool {
    switch (n.kind) {
        case XmlKind.Text:
            out.push(n.raw.length > 0 ? n.raw : escapeXmlText(n.text));
            return true;
        case XmlKind.CData:
            out.push("<![CDATA[").push(n.text).push("]]>");
            return true;
        case XmlKind.Comment:
            out.push("<!--").push(n.text).push("-->");
            return true;
        case XmlKind.Pi:
            out.push("<?").push(n.name);
            if (n.text.length > 0) out.push(" ").push(n.text);
            out.push("?>");
            return true;
        default:
            return false;
    }
}

// Writes an element's start tag (`<x .../>` when it has no children);
// whether it has children to write, then an end tag.
function openXmlElement(n: XmlNode, out: StringBuilder): bool {
    out.push("<").push(n.name);
    for (let k = 0; k < n.attrs.length; k++) {
        const a = n.attrs[k];
        out.push(" ").push(a.name).push("=\"").push(escapeXmlAttr(a.value)).push("\"");
    }
    if (n.children.length == 0) {
        out.push("/>");
        return false;
    }
    out.push(">");
    return true;
}

// A whole document: the declaration (when present), the prolog, the root
// and the epilog, each top-level item on its own line, "\n" at the end.
export function writeXml(doc: XmlDocument): string {
    const out = new StringBuilder();
    const d = doc.decl;
    if (d != null) {
        out.push("<?xml version=\"").push(escapeXmlAttr(d.version)).push("\"");
        const enc = d.encoding;
        if (enc != null) out.push(" encoding=\"").push(escapeXmlAttr(enc)).push("\"");
        const sa = d.standalone;
        if (sa != null) out.push(" standalone=\"").push(escapeXmlAttr(sa)).push("\"");
        out.push("?>\n");
    }
    for (let k = 0; k < doc.prolog.length; k++) {
        writeXmlNode(doc.prolog[k], out);
        out.push("\n");
    }
    writeXmlNode(doc.root, out);
    out.push("\n");
    for (let k = 0; k < doc.epilog.length; k++) {
        writeXmlNode(doc.epilog[k], out);
        out.push("\n");
    }
    return out.toString();
}
