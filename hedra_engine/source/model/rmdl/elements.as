// The .rmdl structural reader: an XML document (base/xml.as) to the model's
// data-form records (../rmdlcmd/data), each with where it was written.
//
// It checks what the document's shape says (docs/formats/RMDL.md "File
// structure" to "References by name"): the root and its format, the
// sections and their order, the elements each section holds and their
// attributes, every <property> (known to its element, given once, of the
// right kind, a literal that parses), ids and paths, references to
// resources and by name. It collects every problem (`errors`, `warnings`)
// rather than stopping at the first, so that `check` can list them all;
// the reader (read.as) stops at the first in source order.
//
// Then it builds the records the data form's replay takes (read.as feeds
// them to Replay.applySplit), in the data form's order: the scene (its
// object and action counts derived from the elements and the holes), the
// materials by order, the actions with their F-curves, each object with its
// vertex groups, its modifiers, then its mesh (shape keys, attributes,
// selection sets) or its armature (bones, each with its constraints), the
// pose clips, the imports. Names become slot ids again, resources the
// indices and paths the data form holds. Numbers are not read here: each
// value is handed over as a range of the document's text (a Word in comma
// mode), and the data form reads it in place, exactly as it reads its own
// lines, so a 50,000-vertex mesh costs its numbers and nothing per number.

import { XmlAttr, XmlDocument, XmlKind, XmlNode, XmlPos } from "../../../base/xml";
import { Diagnostic, Severity } from "../../../scene/error";
import { Value, ValueKind } from "../../../scene/value";
import { parseValueText, printValue } from "../../../scene/value_text";
import { SHADER_PARAMETER_PREFIX, shaderParameterOf } from "../../../scene/classdb";
import { ExtResourceDecl } from "../../../scene/rscn/doc";
import { DocReader, PropertyText, firstNonSpace, isBlank, isSpace } from "../../../scene/textdoc/read";
import { ID_HINT, MODEL_PATHS, extensionAccepted, idProblem, isAbsolutePath, resourcePathProblem } from "../../../scene/textdoc/check";
import { editDistance } from "../scene";
import { DataLine, Word } from "../rmdlcmd/data/line";
import { NumScanner } from "../rmdlcmd/data/num";
import { RECORDS } from "../rmdlcmd/data/words";
import { RmdlHead, RmdlMeta, RmdlShader } from "./doc";
import {
    E_RMDL_INVALID, E_RMDL_NAME_DUPLICATE, E_RMDL_NAME_MISSING, E_RMDL_RESOURCE_SHARED, E_RMDL_RESOURCE_TYPE, RMDL_FORMAT,
    RMDL_ROOT, W_RMDL_RESOURCE_UNUSED,
} from "./format";
import {
    EXT_TYPES, Kind, PosRole, PropSpec, RecordSpec, extExtensions, extExtensionsText, extTypeOf, R_ACTION, R_ARMATURE, R_ATTRIBUTE, R_BONE, R_CONSTRAINT, R_FCURVE,
    R_IMPORT, R_MATERIAL, R_MESH, R_MODIFIER, R_OBJECT, R_POSE_CLIP, R_SCENE, R_SELECTION_SET, R_SHAPEKEY, R_VGROUP,
    componentsOf, ctorOf, isIntKind, kindName, recordSpec,
} from "./schema";

// The hint of what a reader ignores and a rewrite drops.
export const DROPPED_HINT = "it is ignored, and a rewrite (`hedra format`) drops it";
// path-invalid's hint for a model.
export const MODEL_PATH_HINT = "a model's paths are its directory's: relative to the .rmdl (with /), or absolute";

// The sections of <rmdl>, in their order.
const SECTIONS: Array<string> = ["meta", "ext_resource", "sub_resource", "scene", "object", "pose_clip", "import"];
const S_META: i32 = 0;
const S_EXT: i32 = 1;
const S_SUB: i32 = 2;
const S_SCENE: i32 = 3;
const S_OBJECT: i32 = 4;
const S_CLIP: i32 = 5;
// <import> is the last section (6): nothing comes after it to check.

const OBJECT_TYPES: Array<string> = ["mesh", "armature", "camera", "light", "empty"];

// One record built from an element: the data form's split line, the element
// it came from, and where each flag's value is (for the replay's errors).
export class RecordAt {
    ri: i32;
    d: DataLine;
    el: XmlNode;
    flagPos: Map<string, XmlPos> = new Map<string, XmlPos>();

    constructor(ri: i32, el: XmlNode) {
        this.ri = ri;
        this.el = el;
        this.d = new DataLine();
        this.d.record = RECORDS[ri];
    }

    // Where an error about `flag` points: its value, else the element.
    at(flag: string): XmlPos {
        if (flag.length > 0 && this.flagPos.has(flag)) return this.flagPos.get(flag);
        return this.el.pos;
    }

    positional(w: Word): void {
        this.d.positionals.push(w);
    }

    flag(name: string, values: Array<Word>, at: XmlPos): void {
        this.d.flags.push(name);
        this.d.starts.push(this.d.values.length);
        for (let i = 0; i < values.length; i++) this.d.values.push(values[i]);
        if (!this.flagPos.has(name)) this.flagPos.set(name, at);
    }
}

// What reading the elements gave.
export class Elements {
    head: RmdlHead = new RmdlHead();
    records: Array<RecordAt> = [];
    errors: Array<Diagnostic> = [];
    warnings: Array<Diagnostic> = [];
    // Comments and processing instructions read (a rewrite drops them).
    dropped: i32 = 0;
    // The ext_resources declared, in order.
    exts: Array<ExtResourceDecl> = [];
}

// A word of text that is its own: a name, an id, a joined list.
function own(s: string, quoted: bool): Word {
    return new Word(s, 0, s.length, quoted);
}

// A range of the document's text holding numbers.
function nums(src: string, a: i32, b: i32): Word {
    const w = new Word(src, a, b, false);
    w.commaList = true;
    return w;
}

function isDigit(c: i32): bool {
    return c >= 48 && c <= 57;
}

function isWordStart(c: i32): bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
}

function isWordChar(c: i32): bool {
    return isWordStart(c) || isDigit(c);
}

function at(s: string, i: i32): i32 {
    return i < s.length ? <i32>s.charCodeAt(i) : -1;
}

function hasWord(s: string, i: i32, w: string): bool {
    if (i + w.length > s.length) return false;
    for (let j = 0; j < w.length; j++) if (s.charCodeAt(i + j) != w.charCodeAt(j)) return false;
    return !isWordChar(at(s, i + w.length));
}

// The end of the number token at `i` (`-`? digits [. digits] [exponent],
// `.5`, `inf`, `-inf`, `nan`), or -1 when there is none.
function numberEnd(s: string, i: i32): i32 {
    let k = i;
    const c0 = at(s, k);
    if (c0 == 45 || c0 == 43) k++;
    if (hasWord(s, k, "inf")) return k + 3;
    if (k == i && hasWord(s, k, "nan")) return k + 3;
    let digits = 0;
    while (isDigit(at(s, k))) {
        k++;
        digits++;
    }
    if (at(s, k) == 46) {
        k++;
        while (isDigit(at(s, k))) {
            k++;
            digits++;
        }
    }
    if (digits == 0) return -1;
    const e = at(s, k);
    if (e == 101 || e == 69) {
        let j = k + 1;
        if (at(s, j) == 43 || at(s, j) == 45) j++;
        if (!isDigit(at(s, j))) return -1;
        while (isDigit(at(s, j))) j++;
        k = j;
    }
    if (isWordChar(at(s, k)) || at(s, k) == 46) return -1;
    return k;
}

// Whether s[a, b) is an integer: `-`? digits.
function isIntToken(s: string, a: i32, b: i32): bool {
    let k = a;
    if (k < b && (s.charCodeAt(k) == 45 || s.charCodeAt(k) == 43)) k++;
    if (k >= b) return false;
    for (; k < b; k++) if (!isDigit(s.charCodeAt(k))) return false;
    return true;
}

// What a literal is, from its first characters.
enum LitKind {
    Int,
    Float,
    Bool,
    Null,
    Str,
    Array,
    Dict,
    Ctor,
    Bad,
}

class Lit {
    kind: LitKind = LitKind.Bad;
    // A constructor's name and the index of its `(`.
    name: string = "";
    open: i32 = 0;
    // A number's or a word's end.
    end: i32 = 0;
    // Bad: what is wrong, at `end`.
    message: string = "";
}

function foundOf(s: string, k: i32): string {
    if (k >= s.length) return "the end of the text";
    return "'" + String.fromCodePoint(s.codePointAt(k)) + "'";
}

function classify(s: string, i: i32): Lit {
    const l = new Lit();
    const c = at(s, i);
    if (c == 34) l.kind = LitKind.Str;
    else if (c == 91) l.kind = LitKind.Array;
    else if (c == 123) l.kind = LitKind.Dict;
    else if (c == 45 || c == 43 || c == 46 || isDigit(c) || hasWord(s, i, "inf") || hasWord(s, i, "nan")) {
        const e = numberEnd(s, i);
        if (e < 0) {
            let k = i + 1;
            while (isWordChar(at(s, k)) || at(s, k) == 46) k++;
            l.message = "invalid number '" + s.substring(i, k) + "'";
            l.end = i;
            return l;
        }
        l.end = e;
        l.kind = isIntToken(s, i, e) ? LitKind.Int : LitKind.Float;
    } else if (isWordStart(c)) {
        let k = i;
        while (isWordChar(at(s, k))) k++;
        const w = s.substring(i, k);
        l.end = k;
        if (w == "true" || w == "false") l.kind = LitKind.Bool;
        else if (w == "null") l.kind = LitKind.Null;
        else {
            let j = k;
            while (isSpace(at(s, j))) j++;
            if (at(s, j) != 40) {
                l.message = "unknown word '" + w + "'";
                l.end = i;
                return l;
            }
            l.kind = LitKind.Ctor;
            l.name = w;
            l.open = j;
        }
    } else {
        l.message = "expected a value, found " + foundOf(s, i);
        l.end = i;
    }
    return l;
}

function litName(l: Lit): string {
    switch (l.kind) {
        case LitKind.Int: return "int";
        case LitKind.Float: return "float";
        case LitKind.Bool: return "bool";
        case LitKind.Null: return "null";
        case LitKind.Str: return "String";
        case LitKind.Array: return "Array";
        case LitKind.Dict: return "Dictionary";
        default: return l.name;
    }
}

// "a float", "an int", "an Array of String".
function withArticle(t: string): string {
    return (t.length > 0 && "AEIOUaeiou".includes(t.charAt(0)) ? "an " : "a ") + t;
}

// A constructor's numbers scanned: the range inside its parentheses, how
// many, or the first problem (an offset and a message).
class CtorScan {
    a: i32 = 0;
    b: i32 = 0;
    count: i32 = 0;
    errAt: i32 = -1;
    message: string = "";
}

// Scans `Name( n, n, ... )` from its `(` to the end of the text: numbers
// separated by commas (any whitespace, line ends included, around them),
// integers only when `ints`, nothing after the `)` but whitespace.
function scanCtor(s: string, name: string, open: i32, ints: bool): CtorScan {
    const r = new CtorScan();
    let i = open + 1;
    r.a = i;
    while (isSpace(at(s, i))) i++;
    if (at(s, i) == 41) {
        r.b = i;
        i++;
    } else {
        while (true) {
            while (isSpace(at(s, i))) i++;
            const e = numberEnd(s, i);
            if (e < 0) {
                r.errAt = i;
                const c = at(s, i);
                if (c == 45 || c == 46 || isDigit(c)) {
                    let k = i + 1;
                    while (isWordChar(at(s, k)) || at(s, k) == 46) k++;
                    r.message = "invalid number '" + s.substring(i, k) + "'";
                } else r.message = name + " takes numbers, found " + foundOf(s, i);
                return r;
            }
            if (ints && !isIntToken(s, i, e)) {
                r.errAt = i;
                r.message = name + " takes integers, found " + s.substring(i, e);
                return r;
            }
            r.count++;
            i = e;
            while (isSpace(at(s, i))) i++;
            const c = at(s, i);
            if (c == 44) {
                i++;
                continue;
            }
            if (c == 41) {
                r.b = i;
                i++;
                break;
            }
            r.errAt = i;
            r.message = "expected ',' or ')' in " + name + "(...), found " + foundOf(s, i);
            return r;
        }
    }
    while (isSpace(at(s, i))) i++;
    if (i < s.length) {
        r.errAt = i;
        r.message = "unexpected text after the value";
    }
    return r;
}

// An element's content: its properties (in order, and by name), the child
// elements it knows, in order.
class Body {
    el: XmlNode;
    props: Array<PropertyText> = [];
    byName: Map<string, PropertyText> = new Map<string, PropertyText>();
    children: Array<XmlNode> = [];
    // The names of the properties a record took (the others are unknown).
    used: Set<string> = new Set<string>();

    constructor(el: XmlNode) {
        this.el = el;
    }

    get(name: string): PropertyText? {
        if (!this.byName.has(name)) return null;
        this.used.add(name);
        return this.byName.get(name);
    }
}

// A sub_resource read: its id, type and content.
class SubIn {
    id: string;
    type: string;
    body: Body;
    // Material: its index; Action: its slot; Mesh, Armature: the object
    // that names it (-1 until one does).
    slot: i32 = -1;
    user: i32 = -1;

    constructor(id: string, type: string, body: Body) {
        this.id = id;
        this.type = type;
        this.body = body;
    }
}

// An <object> read.
class ObjIn {
    el: XmlNode;
    name: string;
    nameAttr: XmlAttr;
    body: Body;
    slot: u32 = 0;
    data: SubIn? = null;

    constructor(el: XmlNode, name: string, nameAttr: XmlAttr, body: Body) {
        this.el = el;
        this.name = name;
        this.nameAttr = nameAttr;
        this.body = body;
    }
}

// The elements' reader.
export class ElementReader extends DocReader {
    out: Elements = new Elements();
    size: i32;
    // The declared ids (ext_resources and sub_resources) and where.
    ids: Map<string, XmlPos> = new Map<string, XmlPos>();
    exts: Map<string, ExtResourceDecl> = new Map<string, ExtResourceDecl>();
    // ext_resources of a type this version reads.
    extKnown: Set<string> = new Set<string>();
    // ext_resources a property names.
    extUsed: Set<string> = new Set<string>();
    subs: Map<string, SubIn> = new Map<string, SubIn>();
    materials: Array<SubIn> = [];
    actions: Array<SubIn> = [];
    datas: Array<SubIn> = [];
    scene: Body? = null;
    objects: Array<ObjIn> = [];
    clips: Array<Body> = [];
    imports: Array<Body> = [];
    objectSlots: Map<string, u32> = new Map<string, u32>();
    objectNames: Array<string> = [];
    // The bones of the armature being built: name -> slot.
    bones: Map<string, u32> = new Map<string, u32>();

    constructor(file: string, size: i32) {
        super(file);
        this.size = size;
    }

    // ---- diagnostics

    error(code: string, pos: XmlPos, message: string, hint: string? = null): void {
        this.out.errors.push(new Diagnostic(Severity.Error, code, this.file, pos.line, pos.col, message, hint));
    }

    warning(code: string, pos: XmlPos, message: string, hint: string? = null): void {
        this.out.warnings.push(new Diagnostic(Severity.Warning, code, this.file, pos.line, pos.col, message, hint));
    }

    // Moves the DocReader's failure, if any, to the errors; whether there
    // was one.
    take(): bool {
        const e = this.err;
        if (e == null) return false;
        this.out.errors.push(e.toDiagnostic());
        this.err = null;
        return true;
    }

    unknownAttrs(el: XmlNode, known: Array<string>): void {
        for (let i = 0; i < el.attrs.length; i++) {
            const a = el.attrs[i];
            if (known.includes(a.name)) continue;
            this.warning("attribute-unknown", a.pos.isKnown() ? a.pos : a.valuePos, "unknown attribute \"" + a.name + "\" on <" + el.name + ">",
                DROPPED_HINT);
        }
    }

    // ---- the document

    read(x: XmlDocument): Elements {
        for (let k = 0; k < x.prolog.length; k++) this.out.dropped++;
        for (let k = 0; k < x.epilog.length; k++) this.out.dropped++;
        const info = this.root(x, RMDL_ROOT, "a model file", RMDL_FORMAT, "write format=\"1\" on <rmdl>");
        if (info == null) {
            this.take();
            return this.out;
        }
        const root = x.root;
        this.out.head.uid = info.uid;
        this.unknownAttrs(root, ["format", "uid"]);
        let highest = -1;
        for (let k = 0; k < root.children.length; k++) {
            const c = root.children[k];
            if (c.kind == XmlKind.Text) {
                if (!this.blankText(c, "<rmdl>")) this.take();
                continue;
            }
            if (c.kind == XmlKind.CData) {
                this.error("text-unexpected", c.pos, "a CDATA section inside <rmdl>: only elements and comments belong there");
                continue;
            }
            if (c.kind != XmlKind.Element) {
                this.out.dropped++;
                continue;
            }
            const section = SECTIONS.indexOf(c.name);
            if (section < 0) {
                this.warning("element-unknown", c.pos, "unknown element <" + c.name + ">", DROPPED_HINT);
                continue;
            }
            if (section < highest) {
                this.error("element-order", c.pos, c.name + " after " + withArticle(SECTIONS[highest])
                    + ": elements come in the order " + SECTIONS.join(", "));
            } else highest = section;
            switch (section) {
                case S_META: this.meta(c); break;
                case S_EXT: this.ext(c); break;
                case S_SUB: this.sub(c); break;
                case S_SCENE: {
                    const first = this.scene;
                    if (first != null) {
                        this.error(E_RMDL_INVALID, c.pos, "a second <scene> (the first is at line " + first.el.pos.line.toString() + ")",
                            "a document has one <scene>");
                        break;
                    }
                    this.unknownAttrs(c, []);
                    this.scene = this.body(c, []);
                    break;
                }
                case S_OBJECT: this.object(c); break;
                case S_CLIP: {
                    this.unknownAttrs(c, ["bone"]);
                    this.clips.push(this.body(c, []));
                    break;
                }
                default: {
                    this.unknownAttrs(c, []);
                    this.imports.push(this.body(c, []));
                    break;
                }
            }
        }
        this.resolve();
        return this.out;
    }

    // `<meta name="..." value="..."/>`.
    meta(el: XmlNode): void {
        const name = this.required(el, "name");
        const value = this.required(el, "value");
        this.take();
        this.unknownAttrs(el, ["name", "value"]);
        for (let j = 0; j < el.children.length; j++) {
            const g = el.children[j];
            if (g.kind == XmlKind.Text && isBlank(g.text)) continue;
            const where = g.kind == XmlKind.Text ? g.positionAt(firstNonSpace(g.text)) : g.pos;
            this.error("property-content", where, "<meta> has no content: write it <meta name=\"...\" value=\"...\"/>");
            break;
        }
        if (name == null || value == null) return;
        const head = this.out.head;
        for (let i = 0; i < head.meta.length; i++) {
            if (head.meta[i].name == name.value) {
                this.error(E_RMDL_INVALID, name.valuePos, "meta \"" + name.value + "\" is given twice", "a name is given once");
                return;
            }
        }
        head.meta.push(new RmdlMeta(name.value, value.value));
    }

    // An id: well formed, and not declared before.
    checkId(id: string, p: XmlPos, kind: string): bool {
        const bad = idProblem(id, kind);
        if (bad.length > 0) {
            this.error("id-invalid", p, bad, ID_HINT);
            return false;
        }
        if (this.ids.has(id)) {
            const first = this.ids.get(id);
            this.error("id-duplicate", p, "id \"" + id + "\" is already used" + (first.line > 0 ? " (first at line " + first.line.toString() + ")" : ""),
                "ids are unique across ext_resources and sub_resources");
            return false;
        }
        this.ids.set(id, p);
        return true;
    }

    ext(el: XmlNode): void {
        const d = this.extResource(el);
        if (d == null) {
            this.take();
            return;
        }
        this.unknownAttrs(el, ["id", "type", "path", "uid"]);
        for (let i = 0; i < d.extraChildren.length; i++) {
            const c = d.extraChildren[i];
            if (c.kind == XmlKind.Element) this.warning("element-unknown", c.pos, "unknown element <" + c.name + "> in <ext_resource>", DROPPED_HINT);
            else this.out.dropped++;
        }
        if (!this.checkId(d.id, d.attrPos("id"), "ext_resource")) return;
        this.exts.set(d.id, d);
        this.out.exts.push(d);
        const known = EXT_TYPES.includes(d.type);
        if (!known) {
            this.warning("ext-type-unknown", d.attrPos("type"), "unknown ext_resource type \"" + d.type + "\"",
                "a model's ext_resources are Texture2D, Material, PackedScene, Model and Shader; " + DROPPED_HINT);
            return;
        }
        const problem = resourcePathProblem(d.path, MODEL_PATHS);
        if (problem.length > 0) {
            this.error("path-invalid", d.attrPos("path"), problem, MODEL_PATH_HINT);
            return;
        }
        const exts = extExtensions(d.type);
        if (exts.length > 0 && !extensionAccepted(exts, d.path)) {
            this.error("ext-type-extension", d.attrPos("path"), withArticle(d.type) + " is " + extExtensionsText(d.type) + ", not \"" + d.path + "\"");
            return;
        }
        if (isAbsolutePath(d.path)) {
            this.warning("path-absolute", d.attrPos("path"), "\"" + d.path + "\" is an absolute path: it ties the model to this machine",
                "name the file relative to the .rmdl");
        }
        this.extKnown.add(d.id);
        // Kept, not interpreted, as .rscn keeps it: the writer gives it back
        // to the ext_resource of this type and path.
        const uid = d.uid;
        if (uid != null) this.out.head.setExtUid(d.type, d.path, uid);
    }

    sub(el: XmlNode): void {
        const id = this.required(el, "id");
        if (id == null) {
            this.take();
            return;
        }
        const type = this.required(el, "type");
        if (type == null || !this.typeOk(type, el)) {
            this.take();
            return;
        }
        this.unknownAttrs(el, ["id", "type"]);
        const t = type.value;
        let known: Array<string> = [];
        if (t == "Action") known = ["fcurve"];
        else if (t == "Mesh") known = ["shape_key", "attribute", "selection_set"];
        else if (t == "Armature") known = ["bone"];
        else if (t != "Material") {
            // Kept by id, so that a reference to it says what it is.
            if (this.checkId(id.value, id.valuePos, "sub_resource")) this.subs.set(id.value, new SubIn(id.value, t, new Body(el)));
            this.warning("sub-type-unknown", type.valuePos, "unknown sub_resource type \"" + t + "\"",
                "a model's sub_resources are Material, Action, Mesh and Armature; " + DROPPED_HINT);
            return;
        }
        const body = this.body(el, known);
        if (!this.checkId(id.value, id.valuePos, "sub_resource")) return;
        const s = new SubIn(id.value, t, body);
        this.subs.set(id.value, s);
        if (t == "Material") {
            s.slot = this.materials.length;
            this.materials.push(s);
        } else if (t == "Action") this.actions.push(s);
        else this.datas.push(s);
    }

    object(el: XmlNode): void {
        const name = this.required(el, "name");
        const type = this.required(el, "type");
        if (name == null || type == null) {
            this.take();
            return;
        }
        if (!this.typeOk(type, el)) {
            this.take();
            return;
        }
        this.unknownAttrs(el, ["name", "type", "parent"]);
        const body = this.body(el, ["vertex_group", "modifier"]);
        this.objects.push(new ObjIn(el, name.value, name, body));
    }

    // An element's content: properties (each read, given once), the child
    // elements in `known`, blank text and comments; anything else is a
    // problem (text) or unknown (other elements).
    body(el: XmlNode, known: Array<string>): Body {
        const b = new Body(el);
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind == XmlKind.Text) {
                if (!this.blankText(c, "<" + el.name + ">")) this.take();
                continue;
            }
            if (c.kind == XmlKind.CData) {
                this.error("text-unexpected", c.pos, "a CDATA section inside <" + el.name + ">: only elements and comments belong there");
                continue;
            }
            if (c.kind != XmlKind.Element) {
                this.out.dropped++;
                continue;
            }
            if (c.name == "property") {
                const p = this.propertyText(c);
                if (p == null) {
                    this.take();
                    continue;
                }
                for (let i = 0; i < p.extraAttrs.length; i++) {
                    const a = p.extraAttrs[i];
                    this.warning("attribute-unknown", a.pos, "unknown attribute \"" + a.name + "\" on <property>", DROPPED_HINT);
                }
                if (b.byName.has(p.name)) {
                    const q = b.byName.get(p.name);
                    this.error("property-duplicate", p.pos, "property \"" + p.name + "\" is set twice (first at line " + q.pos.line.toString() + ")",
                        "keep one of them");
                    continue;
                }
                b.props.push(p);
                b.byName.set(p.name, p);
                continue;
            }
            if (known.includes(c.name)) {
                b.children.push(c);
                continue;
            }
            this.warning("element-unknown", c.pos, "unknown element <" + c.name + "> in <" + el.name + ">", DROPPED_HINT);
        }
        return b;
    }

    // ---- references

    // The closest of `names` to `name`, for a hint ("" when none is close).
    closest(name: string, names: Array<string>): string {
        let best = "";
        let bestD = i32.MAX_VALUE;
        for (let i = 0; i < names.length; i++) {
            const d = editDistance(name, names[i]);
            if (d < bestD) {
                bestD = d;
                best = names[i];
            }
        }
        if (best.length == 0 || bestD > max(2, name.length / 2)) return "";
        return best;
    }

    // An object's slot by name, as a word, or null (rmdl-name-missing).
    objectRef(name: string, p: XmlPos, what: string): Word? {
        if (this.objectSlots.has(name)) return own(this.objectSlots.get(name).toString(), false);
        const c = this.closest(name, this.objectNames);
        this.error(E_RMDL_NAME_MISSING, p, what + " names \"" + name + "\": no object is named so",
            c.length > 0 ? "did you mean \"" + c + "\"?" : this.objectNames.length == 0 ? "the document has no objects" : null);
        return null;
    }

    boneRef(name: string, p: XmlPos, what: string): Word? {
        if (this.bones.has(name)) return own(this.bones.get(name).toString(), false);
        const names = this.bones.keys();
        const c = this.closest(name, names);
        this.error(E_RMDL_NAME_MISSING, p, what + " names \"" + name + "\": no bone of this armature is named so",
            c.length > 0 ? "did you mean \"" + c + "\"?" : null);
        return null;
    }

    // The sub_resource a value names (SubResource("id")), or null after an
    // error. `want` is the type it must be.
    subRef(v: Value, p: XmlPos, prop: string, want: string): SubIn? {
        if (v.kind != ValueKind.SubResource) {
            this.error("property-type", p, prop + " is " + withArticle("SubResource (" + withArticle(want) + ")") + ", found " + v.kindName());
            return null;
        }
        if (!this.subs.has(v.s)) {
            this.undeclared("sub_resource", v.s, p);
            return null;
        }
        const s = this.subs.get(v.s);
        if (s.type != want) {
            this.error(E_RMDL_RESOURCE_TYPE, p, prop + " names SubResource(\"" + v.s + "\"), " + withArticle(s.type) + ": it takes "
                + withArticle(want));
            return null;
        }
        return s;
    }

    extRef(v: Value, p: XmlPos, prop: string, want: string): ExtResourceDecl? {
        if (v.kind != ValueKind.ExtResource) {
            this.error("property-type", p, prop + " is " + withArticle("ExtResource (" + withArticle(want) + ")") + ", found " + v.kindName());
            return null;
        }
        if (!this.exts.has(v.s)) {
            this.undeclared("ext_resource", v.s, p);
            return null;
        }
        const d = this.exts.get(v.s);
        this.extUsed.add(v.s);
        if (d.type != want) {
            this.error(E_RMDL_RESOURCE_TYPE, p, prop + " names ExtResource(\"" + v.s + "\"), " + withArticle(d.type) + ": it takes "
                + withArticle(want));
            return null;
        }
        if (!this.extKnown.has(v.s)) return null;
        return d;
    }

    undeclared(kind: string, id: string, p: XmlPos): void {
        const other = kind == "sub_resource" ? "ext_resource" : "sub_resource";
        const otherIs = kind == "sub_resource" ? this.exts.has(id) : this.subs.has(id);
        if (otherIs) {
            this.error("resource-undeclared", p, "no " + kind + " with id \"" + id + "\" (\"" + id + "\" is " + withArticle(other) + ")",
                "write " + (other == "ext_resource" ? "ExtResource" : "SubResource") + "(\"" + id + "\")");
        } else {
            this.error("resource-undeclared", p, "no " + kind + " with id \"" + id + "\"", "declare it with <" + kind + " id=\"" + id + "\" .../>");
        }
    }

    // ---- values

    // The property's value as a Value (strings, arrays, dictionaries,
    // resources), or null after a value-syntax error.
    value(t: PropertyText): Value? {
        const pv = parseValueText(t.text);
        if (!pv.ok) {
            this.error("value-syntax", this.positionIn(t.el, pv.errOffset), pv.errMessage, pv.errHint);
            return null;
        }
        return pv.value;
    }

    typeError(t: PropertyText, k: Kind, found: string): void {
        this.error("property-type", t.valuePos, t.name + " is " + withArticle(kindName(k)) + ", found " + found);
    }

    // The words of a property for its flag (one occurrence: Values for a
    // repeated flag are its occurrences, see addProp), or null after an
    // error.
    addProp(r: RecordAt, spec: RecordSpec, p: PropSpec, t: PropertyText, b: Body): void {
        const s = t.text;
        const lit = classify(s, t.first);
        if (lit.kind == LitKind.Bad) {
            this.error("value-syntax", this.positionIn(t.el, lit.end), lit.message);
            return;
        }
        const pos = t.valuePos;
        switch (p.kind) {
            case Kind.Int: case Kind.Float: {
                if (lit.kind != LitKind.Int && (p.kind == Kind.Int || lit.kind != LitKind.Float)) {
                    this.typeError(t, p.kind, litName(lit));
                    return;
                }
                if (!this.endsAt(t, lit.end)) return;
                r.flag(p.flag, [nums(s, t.first, lit.end)], pos);
                return;
            }
            case Kind.Bool: {
                if (lit.kind != LitKind.Bool) {
                    this.typeError(t, p.kind, litName(lit));
                    return;
                }
                if (!this.endsAt(t, lit.end)) return;
                if (s.charCodeAt(t.first) == 116) r.flag(p.flag, [], pos);
                return;
            }
            case Kind.Str: case Kind.ObjName: case Kind.BoneName: {
                if (lit.kind != LitKind.Str) {
                    this.typeError(t, p.kind, litName(lit));
                    return;
                }
                const v = this.value(t);
                if (v == null) return;
                if (p.kind == Kind.Str) r.flag(p.flag, [own(v.s, true)], pos);
                else {
                    const w = p.kind == Kind.ObjName ? this.objectRef(v.s, pos, t.name) : this.boneRef(v.s, pos, t.name);
                    if (w != null) r.flag(p.flag, [w], pos);
                }
                return;
            }
            case Kind.StrList: {
                if (lit.kind != LitKind.Array) {
                    this.typeError(t, p.kind, litName(lit));
                    return;
                }
                const v = this.value(t);
                if (v == null) return;
                for (let i = 0; i < v.items.length; i++) {
                    if (v.items[i].kind != ValueKind.String) {
                        this.typeError(t, p.kind, "an Array holding " + withArticle(v.items[i].kindName()));
                        return;
                    }
                }
                for (let i = 0; i < v.items.length; i++) r.flag(p.flag, [own(v.items[i].s, true)], pos);
                return;
            }
            case Kind.Dict: {
                if (lit.kind != LitKind.Dict) {
                    this.typeError(t, p.kind, litName(lit));
                    return;
                }
                const v = this.value(t);
                if (v == null) return;
                for (let i = 0; i < v.keys.length; i++) {
                    if (v.keys[i].kind != ValueKind.String || i >= v.items.length || v.items[i].kind != ValueKind.Bool) {
                        this.error("property-type", pos, t.name + " maps names to true or false (visible), as {\"Deform\": true}");
                        return;
                    }
                }
                for (let i = 0; i < v.keys.length; i++) {
                    r.flag(p.flag, [own(v.keys[i].s, true), own(v.items[i].b ? "0" : "1", false)], pos);
                }
                return;
            }
            case Kind.Action: {
                if (lit.kind == LitKind.Null) {
                    if (!this.endsAt(t, lit.end)) return;
                    r.flag(p.flag, [own("none", false)], pos);
                    return;
                }
                if (lit.kind != LitKind.Ctor || lit.name != "SubResource") {
                    this.typeError(t, p.kind, litName(lit));
                    return;
                }
                const v = this.value(t);
                if (v == null) return;
                const a = this.subRef(v, pos, t.name, "Action");
                if (a != null) r.flag(p.flag, [own(a.slot.toString(), false)], pos);
                return;
            }
            case Kind.Texture: case Kind.MaterialFile: case Kind.Scene: {
                if (lit.kind != LitKind.Ctor || lit.name != "ExtResource") {
                    this.typeError(t, p.kind, litName(lit));
                    return;
                }
                const v = this.value(t);
                if (v == null) return;
                const d = this.extRef(v, pos, t.name, extTypeOf(p.kind));
                if (d != null) r.flag(p.flag, [own(d.path, true)], pos);
                return;
            }
            case Kind.Materials: {
                if (lit.kind != LitKind.Array) {
                    this.typeError(t, p.kind, litName(lit));
                    return;
                }
                const v = this.value(t);
                if (v == null) return;
                const ids: Array<string> = [];
                for (let i = 0; i < v.items.length; i++) {
                    // `null`: an empty slot (the kernel's u32::MAX).
                    if (v.items[i].kind == ValueKind.Nil) {
                        ids.push(u32.MAX_VALUE.toString());
                        continue;
                    }
                    const m = this.subRef(v.items[i], pos, t.name, "Material");
                    if (m == null) return;
                    ids.push(m.slot.toString());
                }
                r.flag(p.flag, [own(ids.join(" "), false)], pos);
                return;
            }
            case Kind.F32s: case Kind.V3s: case Kind.I32s: case Kind.Nums: {
                const ok = p.kind == Kind.Nums
                    ? lit.kind == LitKind.Ctor && (lit.name == "PackedFloat32Array" || lit.name == "PackedInt32Array" || lit.name == "PackedVector3Array")
                    : lit.kind == LitKind.Ctor && lit.name == ctorOf(p.kind);
                if (!ok) {
                    if (p.kind == Kind.Nums) {
                        this.error("property-type", pos, t.name + " is a PackedFloat32Array, PackedInt32Array or PackedVector3Array, found "
                            + litName(lit));
                    } else this.typeError(t, p.kind, litName(lit));
                    return;
                }
                const c = scanCtor(s, lit.name, lit.open, lit.name == "PackedInt32Array");
                if (c.errAt >= 0) {
                    this.error("value-syntax", this.positionIn(t.el, c.errAt), c.message);
                    return;
                }
                if (lit.name == "PackedVector3Array" && c.count % 3 != 0) {
                    this.error("value-syntax", pos, "PackedVector3Array takes three numbers a point, found " + c.count.toString()
                        + " number" + (c.count == 1 ? "" : "s"), "write x, y, z for each point, all flat in one list");
                    return;
                }
                r.flag(p.flag, [nums(s, c.a, c.b)], pos);
                return;
            }
            case Kind.Split3: {
                // Handled by the record (three properties, one flag).
                return;
            }
            default: {
                // The vectors and colours.
                const ctor = ctorOf(p.kind);
                if (lit.kind != LitKind.Ctor || lit.name != ctor) {
                    this.typeError(t, p.kind, litName(lit));
                    return;
                }
                const c = scanCtor(s, ctor, lit.open, isIntKind(p.kind));
                if (c.errAt >= 0) {
                    this.error("value-syntax", this.positionIn(t.el, c.errAt), c.message);
                    return;
                }
                const want = componentsOf(p.kind);
                if (c.count != want) {
                    const what = p.kind == Kind.Color3 ? " here (r, g, b)" : p.kind == Kind.Color4 ? " here (r, g, b, a)" : "";
                    this.error("value-syntax", pos, ctor + " takes " + want.toString() + " numbers" + what + ", found " + c.count.toString());
                    return;
                }
                r.flag(p.flag, [nums(s, c.a, c.b)], pos);
                return;
            }
        }
    }

    // Nothing but whitespace after a value that ends at `end`.
    endsAt(t: PropertyText, end: i32): bool {
        let i = end;
        while (isSpace(at(t.text, i))) i++;
        if (i < t.text.length) {
            this.error("value-syntax", this.positionIn(t.el, i), "unexpected text after the value");
            return false;
        }
        return true;
    }

    // A Vector3 property of a Split3, its numbers' range or null.
    split3Part(t: PropertyText): Word? {
        const s = t.text;
        const lit = classify(s, t.first);
        if (lit.kind == LitKind.Bad) {
            this.error("value-syntax", this.positionIn(t.el, lit.end), lit.message);
            return null;
        }
        if (lit.kind != LitKind.Ctor || lit.name != "Vector3") {
            this.typeError(t, Kind.Vec3, litName(lit));
            return null;
        }
        const c = scanCtor(s, "Vector3", lit.open, false);
        if (c.errAt >= 0) {
            this.error("value-syntax", this.positionIn(t.el, c.errAt), c.message);
            return null;
        }
        if (c.count != 3) {
            this.error("value-syntax", t.valuePos, "Vector3 takes 3 numbers, found " + c.count.toString());
            return null;
        }
        return nums(s, c.a, c.b);
    }

    // A record's properties, by its spec: each one known is turned into its
    // flag; the others are property-unknown. `skip` names properties the
    // caller reads itself.
    props(r: RecordAt, spec: RecordSpec, b: Body, what: string): void {
        for (let i = 0; i < spec.positionals.length; i++) {
            if (spec.positionals[i].role == PosRole.Prop) b.used.add(spec.positionals[i].name);
        }
        for (let i = 0; i < spec.props.length; i++) {
            const p = spec.props[i];
            if (p.attr) continue;
            if (p.kind == Kind.Data) {
                b.used.add("data");
                continue;
            }
            if (p.kind == Kind.Split3) {
                const parts: Array<string> = [];
                let any = false;
                let first: XmlPos? = null;
                let bad = false;
                for (let k = 0; k < 3; k++) {
                    const t = b.get(p.names[k]);
                    if (t == null) {
                        parts.push(p.defaults[k].replaceAll(" ", ", "));
                        continue;
                    }
                    any = true;
                    if (first == null) first = t.valuePos;
                    const w = this.split3Part(t);
                    if (w == null) bad = true;
                    else parts.push(w.text());
                }
                if (any && !bad) {
                    const joined = parts.join(", ");
                    r.flag(p.flag, [nums(joined, 0, joined.length)], first!);
                }
                continue;
            }
            const t = b.get(p.name);
            if (t == null) continue;
            this.addProp(r, spec, p, t, b);
        }
        for (let i = 0; i < b.props.length; i++) {
            const t = b.props[i];
            if (b.used.has(t.name)) continue;
            this.warning("property-unknown", t.pos, what + " has no property \"" + t.name + "\"", DROPPED_HINT);
        }
    }

    // A positional property (a material's or an action's name, an import's
    // source), required.
    requiredProp(b: Body, name: string, what: string): PropertyText? {
        const t = b.get(name);
        if (t == null) this.error(E_RMDL_INVALID, b.el.pos, what + " has no " + name + " property", "write <property name=\"" + name + "\">...</property>");
        return t;
    }

    stringProp(t: PropertyText): Word? {
        const lit = classify(t.text, t.first);
        if (lit.kind != LitKind.Str) {
            if (lit.kind == LitKind.Bad) this.error("value-syntax", this.positionIn(t.el, lit.end), lit.message);
            else this.typeError(t, Kind.Str, litName(lit));
            return null;
        }
        const v = this.value(t);
        if (v == null) return null;
        return own(v.s, true);
    }

    // An attribute's value as a positional (required: attribute-missing).
    attrWord(r: RecordAt, el: XmlNode, name: string, flagName: string): bool {
        const a = this.required(el, name);
        if (a == null) {
            this.take();
            return false;
        }
        r.positional(own(a.value, true));
        if (flagName.length > 0) r.flagPos.set(flagName, a.valuePos);
        return true;
    }

    // ---- the records

    // Slots for `n` elements around `holes`: the ids in order.
    slotsOf(n: i32, holes: Array<u32>): Array<u32> {
        const hs = new Set<u32>();
        for (let i = 0; i < holes.length; i++) hs.add(holes[i]);
        const out: Array<u32> = [];
        let id: u32 = 0;
        for (let i = 0; i < n; i++) {
            while (hs.has(id)) id++;
            out.push(id);
            id++;
        }
        return out;
    }

    // The ids of a holes property (read leniently: the data form checks it).
    holesOf(b: Body?, name: string): Array<u32> {
        const out: Array<u32> = [];
        if (b == null || !b.byName.has(name)) return out;
        const t = b.byName.get(name);
        const lit = classify(t.text, t.first);
        if (lit.kind != LitKind.Ctor || lit.name != "PackedInt32Array") return out;
        const c = scanCtor(t.text, lit.name, lit.open, true);
        if (c.errAt >= 0) return out;
        const sc = new NumScanner(t.text, c.a, c.b);
        sc.comma = true;
        for (let i = 0; i < c.count; i++) {
            const v = sc.nextU32();
            if (sc.failed) break;
            out.push(v);
        }
        return out;
    }

    resolve(): void {
        // Objects: slots, names.
        const objHoles = this.holesOf(this.scene, "object_holes");
        const objSlots = this.slotsOf(this.objects.length, objHoles);
        const firstOf = new Map<string, XmlAttr>();
        for (let i = 0; i < this.objects.length; i++) {
            const o = this.objects[i];
            o.slot = objSlots[i];
            if (firstOf.has(o.name)) {
                this.error(E_RMDL_NAME_DUPLICATE, o.nameAttr.valuePos, "two objects are named \"" + o.name + "\" (the first at line "
                    + firstOf.get(o.name).valuePos.line.toString() + ")", "references name objects: give each its own name");
                continue;
            }
            firstOf.set(o.name, o.nameAttr);
            this.objectSlots.set(o.name, o.slot);
            this.objectNames.push(o.name);
        }
        // Actions: slots.
        const actHoles = this.holesOf(this.scene, "action_holes");
        const actSlots = this.slotsOf(this.actions.length, actHoles);
        for (let i = 0; i < this.actions.length; i++) this.actions[i].slot = <i32>actSlots[i];
        // Each object's data.
        for (let i = 0; i < this.objects.length; i++) this.objectData(this.objects[i]);
        for (let i = 0; i < this.datas.length; i++) {
            const d = this.datas[i];
            if (d.user < 0) {
                this.warning(W_RMDL_RESOURCE_UNUSED, d.body.el.pos, "no object names " + withArticle(d.type) + " \"" + d.id + "\"", DROPPED_HINT);
            }
        }

        // The records, in the data form's order.
        this.sceneRecord(objHoles, actHoles);
        for (let i = 0; i < this.materials.length; i++) this.materialRecord(this.materials[i]);
        for (let i = 0; i < this.actions.length; i++) this.actionRecord(this.actions[i]);
        for (let i = 0; i < this.objects.length; i++) this.objectRecords(this.objects[i]);
        for (let i = 0; i < this.clips.length; i++) {
            const b = this.clips[i];
            const r = new RecordAt(R_POSE_CLIP, b.el);
            this.attrWord(r, b.el, "bone", "");
            this.props(r, recordSpec(R_POSE_CLIP), b, "<pose_clip>");
            this.out.records.push(r);
        }
        for (let i = 0; i < this.imports.length; i++) this.importRecord(this.imports[i]);
        // A file no property names is not the model's: a rewrite drops it.
        for (let i = 0; i < this.out.exts.length; i++) {
            const d = this.out.exts[i];
            if (!this.extKnown.has(d.id) || this.extUsed.has(d.id)) continue;
            this.warning(W_RMDL_RESOURCE_UNUSED, d.pos, "no property names " + withArticle(d.type) + " \"" + d.id + "\" (\"" + d.path + "\")",
                DROPPED_HINT);
        }
    }

    // An object's `data`: its Mesh or Armature, named by it alone.
    objectData(o: ObjIn): void {
        const type = o.el.attr("type")!;
        const needs = type == "mesh" ? "Mesh" : type == "armature" ? "Armature" : "";
        const t = o.body.byName.has("data") ? o.body.byName.get("data") : null;
        if (t == null) {
            if (needs.length > 0) {
                this.error(E_RMDL_INVALID, o.el.pos, "a " + type + " object needs its " + needs + ": it has no data property",
                    "write <property name=\"data\">SubResource(\"" + needs + "_" + o.slot.toString() + "\")</property>, naming its <sub_resource>");
            }
            return;
        }
        if (needs.length == 0) {
            this.error(E_RMDL_INVALID, t.pos, (OBJECT_TYPES.includes(type) ? withArticle(type) : "this") + " object has no data property",
                "only mesh and armature objects name a Mesh or an Armature");
            return;
        }
        const lit = classify(t.text, t.first);
        if (lit.kind != LitKind.Ctor || lit.name != "SubResource") {
            if (lit.kind == LitKind.Bad) this.error("value-syntax", this.positionIn(t.el, lit.end), lit.message);
            else this.typeError(t, Kind.Data, litName(lit));
            return;
        }
        const v = this.value(t);
        if (v == null) return;
        const s = this.subRef(v, t.valuePos, "data", needs);
        if (s == null) return;
        if (s.user >= 0) {
            this.error(E_RMDL_RESOURCE_SHARED, t.valuePos, needs + " \"" + s.id + "\" is the data of two objects (the first is \""
                + this.objects[s.user].name + "\")", "each object owns its " + needs + ": give this one a copy");
            return;
        }
        s.user = this.objects.indexOf(o);
        o.data = s;
    }

    sceneRecord(objHoles: Array<u32>, actHoles: Array<u32>): void {
        const b = this.scene;
        const el = b != null ? b.el : XmlNode.element("scene");
        const r = new RecordAt(R_SCENE, el);
        const nObj = this.objects.length + objHoles.length;
        const nAct = this.actions.length + actHoles.length;
        if (nObj > 0) r.flag("objects", [own(nObj.toString(), false)], el.pos);
        if (nAct > 0) r.flag("actions", [own(nAct.toString(), false)], el.pos);
        if (b != null) this.props(r, recordSpec(R_SCENE), b, "<scene>");
        this.out.records.push(r);
    }

    materialRecord(m: SubIn): void {
        const r = new RecordAt(R_MATERIAL, m.body.el);
        r.positional(own(m.slot.toString(), false));
        const t = this.requiredProp(m.body, "name", "a Material");
        const w = t != null ? this.stringProp(t) : null;
        r.positional(w != null ? w : own("", true));
        this.shaderProps(m.body, w != null ? w.text() : "");
        this.props(r, recordSpec(R_MATERIAL), m.body, "a Material");
        this.out.records.push(r);
    }

    // Milestone 61: a Material's `shader` (ExtResource of a Shader, a .wgsl
    // file) and its `shader_parameter/<name>` properties, which no data-form
    // record holds: kept in the head by the material's name (doc.as
    // RmdlShader), each value as its canonical text, a texture's as its
    // file. A parameter without a shader, a value no uniform can take and
    // two materials of one name with shaders are rmdl-invalid; a parameter
    // whose name is no identifier is property-unknown, as any.
    shaderProps(b: Body, material: string): void {
        const params = new Array<PropertyText>();
        for (let i = 0; i < b.props.length; i++) {
            const p = b.props[i];
            if (!p.name.startsWith(SHADER_PARAMETER_PREFIX) || shaderParameterOf(p.name) == null) continue;
            b.used.add(p.name);
            params.push(p);
        }
        const t = b.get("shader");
        if (t == null) {
            if (params.length > 0) {
                this.error(E_RMDL_INVALID, params[0].pos, "a Material sets " + params[0].name + " but has no shader",
                    "write <property name=\"shader\">ExtResource(\"...\")</property>, naming a Shader ext_resource (a .wgsl file)");
            }
            return;
        }
        const v = this.value(t);
        if (v == null) return;
        const d = this.extRef(v, t.valuePos, "shader", "Shader");
        if (d == null) return;
        if (this.out.head.shaderOf(material) != null) {
            this.error(E_RMDL_INVALID, t.valuePos, "two materials named \"" + material + "\" have a shader",
                "a material's shader is kept by its name: give each its own name");
            return;
        }
        const entry = new RmdlShader(material, d.path);
        for (let i = 0; i < params.length; i++) {
            const pt = params[i];
            const pv = this.value(pt);
            if (pv == null) continue;
            const k = pv.kind;
            if (k == ValueKind.ExtResource) {
                const tex = this.extRef(pv, pt.valuePos, pt.name, "Texture2D");
                if (tex == null) continue;
                entry.params.push(pt.name.substring(SHADER_PARAMETER_PREFIX.length));
                entry.values.push("");
                entry.textures.push(tex.path);
                continue;
            }
            const fits = k == ValueKind.Nil || k == ValueKind.Bool || k == ValueKind.Int || k == ValueKind.Float
                || k == ValueKind.Vector2 || k == ValueKind.Vector2i || k == ValueKind.Vector3 || k == ValueKind.Vector3i
                || k == ValueKind.Vector4 || k == ValueKind.Color;
            if (!fits) {
                this.error("property-type", pt.valuePos, pt.name + " is a number, a bool, a vector, a Color, a texture "
                    + "(ExtResource of a Texture2D) or null, found " + pv.kindName());
                continue;
            }
            entry.params.push(pt.name.substring(SHADER_PARAMETER_PREFIX.length));
            entry.values.push(printValue(pv));
            entry.textures.push("");
        }
        this.out.head.shaders.push(entry);
    }

    actionRecord(a: SubIn): void {
        const r = new RecordAt(R_ACTION, a.body.el);
        const id = own(a.slot.toString(), false);
        r.positional(id);
        const t = this.requiredProp(a.body, "name", "an Action");
        const w = t != null ? this.stringProp(t) : null;
        r.positional(w != null ? w : own("", true));
        this.props(r, recordSpec(R_ACTION), a.body, "an Action");
        this.out.records.push(r);
        for (let i = 0; i < a.body.children.length; i++) {
            const el = a.body.children[i];
            const f = new RecordAt(R_FCURVE, el);
            f.positional(id);
            if (!this.attrWord(f, el, "data_path", "")) continue;
            if (!this.attrWord(f, el, "index", "")) continue;
            this.unknownAttrs(el, ["data_path", "index"]);
            this.props(f, recordSpec(R_FCURVE), this.body(el, []), "<fcurve>");
            this.out.records.push(f);
        }
    }

    objectRecords(o: ObjIn): void {
        const r = new RecordAt(R_OBJECT, o.el);
        const id = own(o.slot.toString(), false);
        r.positional(id);
        r.positional(own(o.name, true));
        const type = o.el.attrNode("type")!;
        r.flag("type", [own(type.value, false)], type.valuePos);
        const parent = o.el.attrNode("parent");
        if (parent != null) {
            const w = this.objectRef(parent.value, parent.valuePos, "parent");
            if (w != null) r.flag("parent", [w], parent.valuePos);
        }
        this.props(r, recordSpec(R_OBJECT), o.body, "<object>");
        this.out.records.push(r);
        // Vertex groups first, then modifiers (the data form's order).
        for (let pass = 0; pass < 2; pass++) {
            for (let i = 0; i < o.body.children.length; i++) {
                const el = o.body.children[i];
                const vg = el.name == "vertex_group";
                if (vg != (pass == 0)) continue;
                const ri = vg ? R_VGROUP : R_MODIFIER;
                const c = new RecordAt(ri, el);
                c.positional(id);
                if (!this.attrWord(c, el, "name", "")) continue;
                if (!vg && !this.attrWord(c, el, "type", "")) continue;
                if (!vg) c.d.positionals[2].quoted = false;
                this.unknownAttrs(el, vg ? ["name"] : ["name", "type"]);
                this.props(c, recordSpec(ri), this.body(el, []), "<" + el.name + ">");
                this.out.records.push(c);
            }
        }
        const d = o.data;
        if (d == null) return;
        if (d.type == "Mesh") this.meshRecords(o, d, id);
        else this.armatureRecords(o, d, id);
    }

    meshRecords(o: ObjIn, m: SubIn, id: Word): void {
        const r = new RecordAt(R_MESH, m.body.el);
        r.positional(id);
        this.props(r, recordSpec(R_MESH), m.body, "a Mesh");
        this.out.records.push(r);
        // Shape keys, attributes, selection sets (the data form's order).
        const kinds = ["shape_key", "attribute", "selection_set"];
        const ris = [R_SHAPEKEY, R_ATTRIBUTE, R_SELECTION_SET];
        for (let k = 0; k < 3; k++) {
            for (let i = 0; i < m.body.children.length; i++) {
                const el = m.body.children[i];
                if (el.name != kinds[k]) continue;
                const c = new RecordAt(ris[k], el);
                c.positional(id);
                if (!this.attrWord(c, el, "name", "")) continue;
                this.unknownAttrs(el, ["name"]);
                this.props(c, recordSpec(ris[k]), this.body(el, []), "<" + el.name + ">");
                this.out.records.push(c);
            }
        }
    }

    armatureRecords(o: ObjIn, a: SubIn, id: Word): void {
        // The bones' slots and names first: references name them.
        const boneHoles = this.holesOf(a.body, "bone_holes");
        const slots = this.slotsOf(a.body.children.length, boneHoles);
        this.bones = new Map<string, u32>();
        const firstAt = new Map<string, XmlAttr>();
        for (let i = 0; i < a.body.children.length; i++) {
            const el = a.body.children[i];
            const n = el.attrNode("name");
            if (n == null) continue;
            if (firstAt.has(n.value)) {
                this.error(E_RMDL_NAME_DUPLICATE, n.valuePos, "two bones of this armature are named \"" + n.value + "\" (the first at line "
                    + firstAt.get(n.value).valuePos.line.toString() + ")", "references name bones: give each its own name");
                continue;
            }
            firstAt.set(n.value, n);
            this.bones.set(n.value, slots[i]);
        }
        const r = new RecordAt(R_ARMATURE, a.body.el);
        r.positional(id);
        const n = a.body.children.length + boneHoles.length;
        if (n > 0) r.flag("bones", [own(n.toString(), false)], a.body.el.pos);
        this.props(r, recordSpec(R_ARMATURE), a.body, "an Armature");
        this.out.records.push(r);
        for (let i = 0; i < a.body.children.length; i++) {
            const el = a.body.children[i];
            const bone = new RecordAt(R_BONE, el);
            const boneId = own(slots[i].toString(), false);
            bone.positional(id);
            bone.positional(boneId);
            if (!this.attrWord(bone, el, "name", "")) continue;
            this.unknownAttrs(el, ["name", "parent"]);
            const parent = el.attrNode("parent");
            if (parent != null) {
                const w = this.boneRef(parent.value, parent.valuePos, "parent");
                if (w != null) bone.flag("parent", [w], parent.valuePos);
            }
            const body = this.body(el, ["constraint"]);
            this.props(bone, recordSpec(R_BONE), body, "<bone>");
            this.out.records.push(bone);
            for (let k = 0; k < body.children.length; k++) {
                const cel = body.children[k];
                const c = new RecordAt(R_CONSTRAINT, cel);
                c.positional(id);
                c.positional(boneId);
                if (!this.attrWord(c, cel, "name", "")) continue;
                if (!this.attrWord(c, cel, "type", "")) continue;
                c.d.positionals[3].quoted = false;
                this.unknownAttrs(cel, ["name", "type"]);
                this.props(c, recordSpec(R_CONSTRAINT), this.body(cel, []), "<constraint>");
                this.out.records.push(c);
            }
        }
    }

    importRecord(b: Body): void {
        const r = new RecordAt(R_IMPORT, b.el);
        const t = this.requiredProp(b, "source", "an <import>");
        let w: Word? = null;
        if (t != null) {
            const lit = classify(t.text, t.first);
            if (lit.kind != LitKind.Ctor || lit.name != "ExtResource") {
                if (lit.kind == LitKind.Bad) this.error("value-syntax", this.positionIn(t.el, lit.end), lit.message);
                else this.typeError(t, Kind.Model, litName(lit));
            } else {
                const v = this.value(t);
                if (v != null) {
                    const d = this.extRef(v, t.valuePos, "source", "Model");
                    if (d != null) w = own(d.path, true);
                }
            }
        }
        r.positional(w != null ? w : own("", true));
        this.props(r, recordSpec(R_IMPORT), b, "an <import>");
        this.out.records.push(r);
    }
}

// Sorts diagnostics by position, stably (a handful of items each).
export function sortByPosition(a: Array<Diagnostic>): void {
    for (let i = 1; i < a.length; i++) {
        const d = a[i];
        let j = i - 1;
        while (j >= 0 && (a[j].line > d.line || (a[j].line == d.line && a[j].col > d.col))) {
            a[j + 1] = a[j];
            j--;
        }
        a[j + 1] = d;
    }
}

// The elements of a parsed document. `size` bounds the slot counts the
// records may declare (the document's length: every slot costs at least two
// of its characters).
export function readElements(x: XmlDocument, file: string, size: i32): Elements {
    const r = new ElementReader(file, size);
    const out = r.read(x);
    for (let i = 0; i < out.records.length; i++) out.records[i].d.size = size;
    sortByPosition(out.errors);
    sortByPosition(out.warnings);
    return out;
}
