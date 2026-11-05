// What the readers of Hedra's XML documents share: the .rscn reader
// (../rscn/parse.as) and the .rmdl reader (engine/src/source/model/rmdl/
// elements.as) are written on this, so that both formats check their
// common shapes the same way, with the same codes, messages and positions
// (docs/formats/RSCN.md "Reading", docs/formats/RMDL.md "Errors"):
//
//   - the root element, its `format` (an integer from 1 to the newest this
//     build reads) and its `uid`;
//   - whitespace between elements, and nothing else (text-unexpected);
//   - a required attribute (attribute-missing), a type that is not empty;
//   - an <ext_resource id type path [uid]> and what it holds;
//   - a <property name="...">value</property> (propertyText): its name,
//     its value's text (Text and CDATA children, nothing else:
//     property-content), where the element and its value are, and any
//     other attribute. The value is NOT
//     parsed here: .rscn parses it as a Value (../value_text.as), .rmdl
//     hands numbers to the model's data form without making Values of them.
//
// A reader keeps the first problem (`err`) and every step returns false or
// null after it, as the .rscn reader always has.

import { XmlAttr, XmlDocument, XmlKind, XmlNode, XmlPos } from "../../base/xml";
import { SceneryError } from "../error";
import { ExtResourceDecl } from "../rscn/doc";

export function isSpace(c: i32): bool {
    return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
}

export function isBlank(s: string): bool {
    for (let k = 0; k < s.length; k++) if (!isSpace(s.charCodeAt(k))) return false;
    return true;
}

// The index of the first non-whitespace character, or -1.
export function firstNonSpace(s: string): i32 {
    for (let k = 0; k < s.length; k++) if (!isSpace(s.charCodeAt(k))) return k;
    return -1;
}

// A decimal integer ("-"? digits): its value, saturated at +-10^12 (enough
// to tell "does not fit in an i32" apart), or i64.MIN_VALUE when the text
// is not one.
export function decimalOf(s: string): i64 {
    let k = 0;
    let neg = false;
    if (s.length > 0 && s.charCodeAt(0) == 45) {
        neg = true;
        k = 1;
    }
    if (k >= s.length) return i64.MIN_VALUE;
    let v: i64 = 0;
    for (; k < s.length; k++) {
        const c = s.charCodeAt(k);
        if (c < 48 || c > 57) return i64.MIN_VALUE;
        if (v < 1000000000000) v = v * 10 + <i64>(c - 48);
    }
    return neg ? -v : v;
}

// A <property> read: its name, its value's text unparsed, and where things
// are. `text` is the concatenated Text and CDATA children (the one child's
// text as it stands when there is one: a megabyte of numbers is not copied);
// `first` the offset of its first non-whitespace character (`valuePos` is
// where that is in the source).
export class PropertyText {
    name: string = "";
    text: string = "";
    first: i32 = 0;
    // The <property> element itself (DocReader.positionIn maps an offset of
    // `text` back to the source through it).
    el: XmlNode;
    pos: XmlPos = new XmlPos();
    valuePos: XmlPos = new XmlPos();
    // Written as one CDATA section and nothing else.
    cdata: bool = false;
    // Attributes other than `name`, in source order.
    extraAttrs: Array<XmlAttr> = [];

    constructor(el: XmlNode) {
        this.el = el;
    }
}

// The root element's attributes once checked: the format (1 to the
// reader's newest), the uid when there is one, all its attributes in source
// order (`format` and `uid` among them).
export class RootInfo {
    format: i32 = 0;
    uid: string? = null;
    attrs: Array<XmlAttr> = [];
    formatAttr: XmlAttr? = null;
}

// The first problem of a document, and the checks every format makes.
export class DocReader {
    file: string;
    err: SceneryError? = null;

    constructor(file: string) {
        this.file = file;
    }

    fail(code: string, pos: XmlPos, message: string, hint: string? = null): bool {
        if (this.err == null) this.err = SceneryError.at(code, this.file, pos.line, pos.col, message, hint);
        return false;
    }

    // Whitespace is layout; any other text is a mistake worth stopping on
    // (a value written outside its <property>, say).
    blankText(t: XmlNode, where: string): bool {
        const k = firstNonSpace(t.text);
        if (k < 0) return true;
        return this.fail("text-unexpected", t.positionAt(k), "text inside " + where + ": only elements and comments belong there");
    }

    // The attribute, or a failure naming it.
    required(el: XmlNode, name: string): XmlAttr? {
        const a = el.attrNode(name);
        if (a == null) this.fail("attribute-missing", el.pos, "<" + el.name + "> has no " + name + " attribute");
        return a;
    }

    // A `type` attribute: required or not, never empty.
    typeOk(a: XmlAttr?, el: XmlNode): bool {
        if (a != null && a.value.length == 0) return this.fail("attribute-invalid", a.valuePos, "<" + el.name + "> type is empty");
        return true;
    }

    // An element that holds nothing in this format version: whatever a
    // newer format puts there (elements, comments, PIs) goes to `into`;
    // text other than whitespace, or CDATA, is refused.
    extraChildren(el: XmlNode, into: Array<XmlNode>): bool {
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind == XmlKind.Text) {
                if (!this.blankText(c, "<" + el.name + ">")) return false;
                continue;
            }
            if (c.kind == XmlKind.CData) {
                return this.fail("text-unexpected", c.pos, "a CDATA section inside <" + el.name + ">: only elements and comments belong there");
            }
            into.push(c);
        }
        return true;
    }

    // The root element: named `tag` (`what` says what a file of this kind
    // is, in "a scene file's root is <rscn>"), with a format from 1 to
    // `newest`. `missingHint` is format-missing's hint.
    root(x: XmlDocument, tag: string, what: string, newest: i32, missingHint: string): RootInfo? {
        const root = x.root;
        if (root.name != tag) {
            this.fail("root-element", root.pos, "the root element is <" + root.name + ">: " + what + "'s root is <" + tag + ">");
            return null;
        }
        const info = new RootInfo();
        for (let k = 0; k < root.attrs.length; k++) info.attrs.push(root.attrs[k]);
        const fmt = root.attrNode("format");
        if (fmt == null) {
            this.fail("format-missing", root.pos, "<" + tag + "> has no format attribute", missingHint);
            return null;
        }
        info.formatAttr = fmt;
        const f = decimalOf(fmt.value);
        if (f == i64.MIN_VALUE) {
            this.fail("attribute-invalid", fmt.valuePos, "format must be an integer, found \"" + fmt.value + "\"");
            return null;
        }
        if (f > <i64>newest) {
            this.fail("format-unsupported", fmt.valuePos, "format " + fmt.value + " is newer than this build reads",
                "this file needs a newer Hedra: this build reads format " + newest.toString());
            return null;
        }
        if (f < 1) {
            this.fail("attribute-invalid", fmt.valuePos, "format must be 1 or more, found " + fmt.value);
            return null;
        }
        info.format = <i32>f;
        info.uid = root.attr("uid");
        return info;
    }

    // `<ext_resource id="..." type="..." path="..."[ uid="..."]>`: the three
    // attributes required, the type not empty, every attribute kept (the
    // validators warn of unknown ones), children kept (none in format 1).
    extResource(el: XmlNode): ExtResourceDecl? {
        const id = this.required(el, "id");
        if (id == null) return null;
        const type = this.required(el, "type");
        if (type == null || !this.typeOk(type, el)) return null;
        const path = this.required(el, "path");
        if (path == null) return null;
        const d = new ExtResourceDecl(id.value, type.value, path.value);
        d.uid = el.attr("uid");
        d.pos = el.pos.clone();
        d.attrs = el.attrs;
        if (!this.extraChildren(el, d.extraChildren)) return null;
        return d;
    }

    // A <property>: its name (required) and its value's text. The value is
    // the text of the Text and CDATA children, which may alternate
    // (`1<![CDATA[.5]]>`): anything else inside is refused rather than
    // guessed around. An empty value is a value-syntax error.
    propertyText(el: XmlNode): PropertyText? {
        const name = this.required(el, "name");
        if (name == null) return null;
        // (One child, the usual case, is its text as it stands: a
        // MultiMesh buffer's is a megabyte, not to be copied again.)
        let text = el.children.length == 1 ? el.children[0].text : "";
        const single = el.children.length == 1;
        let cdatas = 0;
        let texts = 0;
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind == XmlKind.Text) {
                if (!single) text += c.text;
                if (!isBlank(c.text)) texts++;
            } else if (c.kind == XmlKind.CData) {
                if (!single) text += c.text;
                cdatas++;
            } else {
                const what = c.kind == XmlKind.Element ? "<" + c.name + ">" : c.kind == XmlKind.Comment ? "a comment" : "a processing instruction";
                this.fail("property-content", c.pos, "<property> holds a value only, found " + what);
                return null;
            }
        }
        const first = firstNonSpace(text);
        if (first < 0) {
            this.fail("value-syntax", el.pos, "empty value");
            return null;
        }
        const p = new PropertyText(el);
        p.name = name.value;
        p.text = text;
        p.first = first;
        p.pos = el.pos.clone();
        p.valuePos = this.positionIn(el, first);
        p.cdata = cdatas == 1 && texts == 0;
        for (let k = 0; k < el.attrs.length; k++) if (el.attrs[k].name != "name") p.extraAttrs.push(el.attrs[k]);
        return p;
    }

    // The source position of offset `offset` of the concatenated text of a
    // property's children: the child that holds it says where.
    positionIn(el: XmlNode, offset: i32): XmlPos {
        let from = 0;
        let last: XmlNode? = null;
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            const len = c.text.length;
            if (offset < from + len) return c.positionAt(offset - from);
            from += len;
            last = c;
        }
        if (last != null) return last.positionAt(last.text.length);
        return el.contentPos.clone();
    }
}
