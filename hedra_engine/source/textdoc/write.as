// The canonical writers' mechanics, shared by the .rscn writer
// (../scene/rscn_write.as) and the .rmdl writer (../model/rmdl/write.as):
// the declaration line, an element per line indented 2 spaces a level,
// attributes in double quotes escaped as base/xml.as escapes them
// (`&amp; &lt; &gt; &quot;`, and `&#9; &#10; &#13;` so that a tab or a line
// end survives attribute-value normalisation), text escaped (`&amp; &lt;
// &gt;`, `&#13;`), a `\n` after every line and nothing trailing.
//
// What each format writes, and in which order, is its own; this is only
// how a line is spelled, so that both formats spell it the same way.
//
// A DocWriter writes into one growing buffer of UTF-16 units (TextBuf), not
// into a list of strings joined at the end: a model's document is mostly
// numbers, and the stub runtime never frees, so a string per number (or per
// line, joined, then joined again) cost several times the document. The
// buffer is sized from an estimate and turned into the text once.

import { StringBuilder } from "../../base/util";
import { escapeXmlAttr, escapeXmlText, xmlCharProblem } from "../../base/xml";
import { quoteString } from "../../scene/value_text";

// The declaration every canonical document starts with.
export const XML_DECLARATION_LINE = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";

// ` name="value"`, the value escaped for double quotes.
export function pushAttr(out: StringBuilder, name: string, value: string): void {
    out.push(" ").push(name).push("=\"").push(escapeXmlAttr(value)).push("\"");
}

// The indentation of `depth` levels (2 spaces each), from a small table:
// a document of 100,000 lines makes no string for its indentation.
const INDENTS: Array<string> = ["", "  ", "    ", "      ", "        ", "          ", "            ", "              "];

export function indentOf(depth: i32): string {
    if (depth < INDENTS.length) return INDENTS[depth];
    return " ".repeat(depth * 2);
}

// A growing buffer of UTF-16 code units.
export class TextBuf {
    private buf: Uint16Array;
    len: i32 = 0;

    constructor(capacity: i32 = 1024) {
        this.buf = new Uint16Array(max(capacity, 64));
    }

    private reserve(extra: i32): void {
        const need = this.len + extra;
        if (need <= this.buf.length) return;
        let cap = this.buf.length * 2;
        while (cap < need) cap *= 2;
        const nb = new Uint16Array(cap);
        copyUnits(nb.dataStart, this.buf.dataStart, this.len);
        this.buf = nb;
    }

    push(s: string): TextBuf {
        return this.pushRange(s, 0, s.length);
    }

    // s[a, b).
    pushRange(s: string, a: i32, b: i32): TextBuf {
        const n = b - a;
        if (n <= 0) return this;
        this.reserve(n);
        copyString(this.buf.dataStart + (<usize>this.len << 1), s, a, n);
        this.len += n;
        return this;
    }

    // One UTF-16 code unit.
    pushUnit(c: i32): TextBuf {
        this.reserve(1);
        this.buf[this.len] = <u16>c;
        this.len++;
        return this;
    }

    toString(): string {
        return decodeUnits(this.buf.dataStart, this.len);
    }
}

// The memory work, apart (the runtime's rule: only `unsafe` functions touch
// memory directly).
unsafe function copyUnits(dst: usize, src: usize, units: i32): void {
    memory.copy(dst, src, <usize>units << 1);
}

unsafe function copyString(dst: usize, s: string, from: i32, units: i32): void {
    memory.copy(dst, changetype<usize>(s) + (<usize>from << 1), <usize>units << 1);
}

unsafe function decodeUnits(src: usize, units: i32): string {
    return String.UTF16.decodeUnsafe(src, <usize>units << 1);
}

// A document being written: lines pushed one at a time.
export class DocWriter {
    out: TextBuf;
    // The first attribute value no XML document can hold (a control
    // character, a lone surrogate), as `<tag> name "value" holds ...`, or
    // "": written anyway, so a writer that cares fails on it after writing.
    bad: string = "";
    private tag: string = "";

    // `capacity`: the text's expected length, in UTF-16 units.
    constructor(capacity: i32 = 1024) {
        this.out = new TextBuf(capacity);
    }

    // The declaration line.
    declaration(): DocWriter {
        this.out.push(XML_DECLARATION_LINE).pushUnit(0x0A);
        return this;
    }

    // ` name="value"`, escaped.
    attr(name: string, value: string): DocWriter {
        if (this.bad.length == 0) {
            const p = xmlCharProblem(value);
            if (p.length > 0) this.bad = "<" + this.tag + "> " + name + " " + quoteString(value) + " holds " + p;
        }
        this.out.pushUnit(0x20).push(name).push("=\"").push(escapeXmlAttr(value)).pushUnit(0x22);
        return this;
    }

    // `<tag a="1" b="2"` at `depth`, attributes from name/value pairs
    // (`attrs[2k]` the name, `attrs[2k + 1]` the value); the caller ends the
    // tag with `end` or `endEmpty`.
    start(tag: string, attrs: Array<string>, depth: i32): DocWriter {
        this.out.push(indentOf(depth)).pushUnit(0x3C).push(tag);
        this.tag = tag;
        for (let k = 0; k + 1 < attrs.length; k += 2) this.attr(attrs[k], attrs[k + 1]);
        return this;
    }

    // `>` and a line end: content follows.
    end(): DocWriter {
        this.out.push(">\n");
        return this;
    }

    // `/>` and a line end: the element holds nothing.
    endEmpty(): DocWriter {
        this.out.push("/>\n");
        return this;
    }

    // A start tag on its own line.
    open(tag: string, attrs: Array<string>, depth: i32): DocWriter {
        return this.start(tag, attrs, depth).end();
    }

    // An element without content.
    selfClosing(tag: string, attrs: Array<string>, depth: i32): DocWriter {
        return this.start(tag, attrs, depth).endEmpty();
    }

    // An end tag on its own line.
    close(tag: string, depth: i32): DocWriter {
        this.out.push(indentOf(depth)).push("</").push(tag).push(">\n");
        return this;
    }

    // `<property name="n">value</property>`: `value` is the value's text,
    // escaped here (or written in one CDATA section when `cdata` and it holds
    // no "]]>").
    property(name: string, value: string, depth: i32, cdata: bool = false): DocWriter {
        this.propertyStart(name, depth);
        if (cdata && value.indexOf("]]>") < 0) this.out.push("<![CDATA[").push(value).push("]]>");
        else this.out.push(escapeXmlText(value));
        return this.propertyEnd();
    }

    // `<property name="n">` without a line end: the caller writes the value
    // (escaped, or needing no escape) into `out`, then `propertyEnd`.
    propertyStart(name: string, depth: i32): DocWriter {
        this.out.push(indentOf(depth)).push("<property");
        this.tag = "property";
        this.attr("name", name);
        this.out.pushUnit(0x3E);
        return this;
    }

    propertyEnd(): DocWriter {
        this.out.push("</property>\n");
        return this;
    }

    // Text written as it is (already escaped, or needing no escape).
    raw(s: string): DocWriter {
        this.out.push(s);
        return this;
    }

    // An empty line (between sections).
    blank(): DocWriter {
        this.out.pushUnit(0x0A);
        return this;
    }

    // `<!--text-->` at `depth` (the text must not hold "--").
    comment(text: string, depth: i32): DocWriter {
        this.out.push(indentOf(depth)).push("<!--").push(text).push("-->\n");
        return this;
    }

    text(): string {
        return this.out.toString();
    }
}
