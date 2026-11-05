// MaterialX documents <-> PbrMaterial (milestone 14): the material file
// format of Hedra, the open standard of the Academy Software Foundation
// (https://materialx.org, specification 1.39) restricted to one profile:
// one material whose surface shader is MaterialX's own `gltf_pbr` node
// (libraries/bxdf/gltf_pbr.mtlx, ND_gltf_pbr_surfaceshader 2.0.1), the
// shading model of glTF 2.0, its textures read by the glTF texture nodes
// (gltf_colorimage, gltf_image, gltf_normalmap, gltf_anisotropy_image,
// gltf_iridescence_thickness) with stdlib `extract`, `normalmap`, `mix`,
// `texcoord` and `constant` where glTF needs them. What gltf_pbr has no
// input for (diffuse transmission, unlit, double sided, cull front, the
// vertex colour, the iridescence film's minimum without a texture, and
// milestone 35's billboard) is the
// outputs of one nodegraph, `hedra_extras`, which other MaterialX tools
// read as a valid graph nothing uses. docs/formats/MATERIALS.md is the
// normative description: every element and input this reader accepts, the
// canonical form the writer produces (mtlx_write.as), and the problems with
// their codes.
//
// Pure and shared: text in, a PbrMaterial out, and back; no file access,
// no Hedra. Errors and warnings carry the line and column of the
// element or attribute they are about (engine/src/base/xml.as positions).
//
// How a document is read: the XML parsed; the root checked; the one
// `surfacematerial` found and its `surfaceshader` followed to the
// `gltf_pbr` node; each of gltf_pbr's inputs read as a value, a `constant`,
// or the node it connects to, which must be the node glTF's table
// (MATERIALS.md) puts there, with the channel it says; then the extras
// graph. Whatever the material does not use (comments, UI attributes,
// looks, nodes nothing connects to) is read past with an `mtlx-ignored`
// warning, so a document another tool wrote reads as the same material as
// its canonical twin, and the CLI's `format` can tell that rewriting it would
// drop something.

import { ErrorValue, Result, toAsciiLowercase } from "../../base/util";
import { linearToSrgbValue } from "../../base/color";
import { XmlAttr, XmlDocument, XmlKind, XmlNode, XmlPos, parseXmlText, xmlErrorOf } from "../../base/xml";
import {
    PBR_ALPHA_OPAQUE, PBR_ARTBOARD_MODES, PBR_SLOT_COUNT, PbrArtboard, PbrMaterial, PbrSlot, PbrTexture,
} from "../../material/pbr";
import {
    EXTRAS_GRAPH, GLTF_PBR_INPUTS, IGNORED_ELEMENTS, MTLX_BILLBOARD_MAX, MTLX_DEFS_VERSION, MTLX_SLOTS, MtlxBillboard,
    MtlxInputDef, NODE_CATEGORIES, RIVE_SIZE_MAX, UNMODELLED_IMAGE_INPUTS, extraType, findInput, nodeInputs,
} from "./mtlx_defs";
import { NOT_AN_INTEGER, parseDouble, parseFloats, parseInteger, parseWholePair, radiansOf } from "./mtlx_text";
import { writeMtlxText } from "./mtlx_write";
import { CLI } from "../../base/names";

// The MaterialX version the writer writes and the newest the reader reads.
export const MTLX_VERSION = MTLX_DEFS_VERSION;

// The versions the reader reads: 1.38 has every node of the profile.
export const MTLX_READ_VERSIONS: Array<string> = ["1.38", "1.39"];

// Where every problem's hint sends a reader.
export const MTLX_DOC = "docs/formats/MATERIALS.md";

// A problem with a document: an error (the material cannot be read) or a
// warning (something is ignored; the material is read without it).
export class MtlxProblem extends ErrorValue {
    // A kebab-case code (MATERIALS.md "Problems": "mtlx-xml",
    // "mtlx-root", "mtlx-version", "mtlx-material-count", "mtlx-shader",
    // "mtlx-node-unsupported", "mtlx-input-unknown", "mtlx-input-type",
    // "mtlx-value", "mtlx-connection", and the warning "mtlx-ignored").
    code: string;
    message: string;
    hintText: string;
    // 1-based; 0 when the problem has no place (an empty document).
    line: i32;
    col: i32;
    isWarning: bool;
    // The document's name as the reader was given it.
    file: string = "";
    // A warning: what is ignored, as the CLI's `format` lists what rewriting
    // would drop: an attribute's name ("xpos"), or a kind of content
    // ("comment"), with its plural in `whats`.
    what: string = "";
    whats: string = "";

    constructor(code: string, message: string, hint: string, line: i32, col: i32, isWarning: bool) {
        super();
        this.code = code;
        this.message = message;
        this.hintText = hint;
        this.line = line;
        this.col = col;
        this.isWarning = isWarning;
    }

    // `<file>:<line>:<col>: <message>` (without a place when it has none).
    toString(): string {
        if (this.line <= 0) return this.file + ": " + this.message;
        return this.file + ":" + this.line.toString() + ":" + this.col.toString() + ": " + this.message;
    }
}

// What reading a document gives.
export class MtlxRead {
    material: PbrMaterial;
    // Milestone 35: the billboard the extras graph sets (a PbrMaterial has
    // no field for it: mtlx_defs.as MtlxBillboard).
    billboard: MtlxBillboard = new MtlxBillboard();
    // Everything ignored, in source order (mtlx-ignored).
    warnings: Array<MtlxProblem> = [];
    // Where each value came from, for the Hedra validator's positions:
    // keyed by PbrMaterial field name ("roughness", "baseColor", "name") or
    // "textures[<slot>]" for a texture, the position of the input that set
    // it (a texture's: its `file` value) as [line, col]; "document" is the
    // <materialx> element's, "material" the surfacematerial's. A texture
    // drawn from an artboard adds "textures[<slot>].artboard",
    // ".stateMachine" and ".size": its attributes' values (milestone 15).
    positions: Map<string, StaticArray<i32>> = new Map<string, StaticArray<i32>>();

    constructor(material: PbrMaterial) {
        this.material = material;
    }

    // What writing the material would drop ("2 comments, xpos"), "" when
    // nothing: the warnings' subjects, kinds counted, attributes named.
    dropped(): string {
        return droppedSummary(this.warnings);
    }
}

// The warnings' subjects as the CLI's `format` reports them: "2 comments,
// xpos, an unused node", in the order first met.
export function droppedSummary(warnings: Array<MtlxProblem>): string {
    const order = new Array<string>();
    const counts = new Map<string, i32>();
    const plurals = new Map<string, string>();
    for (let k = 0; k < warnings.length; k++) {
        const w = warnings[k];
        if (!w.isWarning || w.what.length == 0) continue;
        if (!counts.has(w.what)) {
            order.push(w.what);
            counts.set(w.what, 0);
            plurals.set(w.what, w.whats);
        }
        counts.set(w.what, counts.get(w.what) + 1);
    }
    const out = new Array<string>();
    for (let k = 0; k < order.length; k++) {
        const plural = plurals.get(order[k]);
        const n = counts.get(order[k]);
        // An attribute is named once, however often it occurs.
        if (plural.length == 0) out.push(order[k]);
        else out.push(n == 1 ? article(order[k]) : n.toString() + " " + plural);
    }
    return out.join(", ");
}

// The document `text` (`file` names it in problems) read under the
// profile. Fails with an MtlxProblem (Result.cause) when it is not XML, not
// a <materialx> document of version 1.38 or 1.39, does not hold exactly
// one `surfacematerial` whose `surfaceshader` is a `gltf_pbr` node, or
// holds a node, input or connection the profile does not draw.
export function readMtlx(text: string, file: string): Result<MtlxRead> {
    const r = new Reader(file);
    const read = r.read(text);
    const e = r.err;
    if (e != null || read == null) {
        const p = e != null ? e : r.problem("mtlx-xml", r.rootPos, "the document could not be read", MTLX_DOC);
        return Result.failWith<MtlxRead>(p);
    }
    return Result.okv<MtlxRead>(read);
}

// `m` as a canonical MaterialX document (MATERIALS.md "Canonical form"):
// what readMtlx reads back as `m` (pbrDiff empty: a name that is no
// MaterialX identifier excepted, which is written as one), the same text
// for the same material, written by the CLI's `format` and the editor.
// `billboard` (milestone 35) is what the material carries beside: none, as
// a PbrMaterial alone, writes no billboard.
export function writeMtlx(m: PbrMaterial, billboard: MtlxBillboard? = null): string {
    return writeMtlxText(m, billboard);
}

// --- the reader --------------------------------------------------------------

const NO_POS = new XmlPos(0, 0);

// The attributes a node of the profile may carry (besides UI_ATTRIBUTES,
// which are read past with a warning).
const NODE_ATTRS: Array<string> = ["name", "type", "nodedef", "version", "colorspace", "fileprefix"];
const INPUT_ATTRS: Array<string> = ["name", "type", "value", "nodename", "output", "colorspace", "uniform", "unit", "unittype"];
// What an image node's `file` input may carry besides (milestone 15): the
// Rive artboard a texture is drawn from, when the file is a .riv
// (MATERIALS.md, "Artboard textures"). MaterialX allows custom attributes;
// other tools read past them and find a file they cannot open.
// Milestone 67: and when a built project draws it again (the
// ArtboardTexture's render_target_update_mode by Godot's name, and its
// update_fps).
const RIVE_ATTRS: Array<string> = ["rive_artboard", "rive_state_machine", "rive_size", "rive_update_mode", "rive_update_fps"];
// Where the artboard attributes' problems send a reader.
const ARTBOARD_HINT_DOC = MTLX_DOC + ", \"Artboard textures\"";
// What <materialx> may carry.
const ROOT_ATTRS: Array<string> = ["version", "colorspace", "namespace", "fileprefix"];

// The colour spaces the reader converts from: sRGB-encoded (as Hedra
// keeps colours: copied) and linear Rec. 709 (MaterialX's default:
// encoded with linearToSrgbValue, as the glTF importer does).
const SRGB = "srgb_texture";
const LINEAR = "lin_rec709";

// The nodes of one scope: the document's top level or the extras graph.
class Scope {
    el: XmlNode;
    key: string;
    nodes: Map<string, XmlNode> = new Map<string, XmlNode>();
    order: Array<string> = [];

    constructor(el: XmlNode, key: string) {
        this.el = el;
        this.key = key;
    }
}

// An input of a node, as found: absent, a value (its numbers, or its text
// for a filename or a string), or a connection to a node of the scope.
class Src {
    present: bool = false;
    input: XmlNode? = null;
    // A value.
    isValue: bool = false;
    nums: Array<f32> = [];
    text: string = "";
    colorspace: string = "";
    // A connection.
    node: XmlNode? = null;
    output: string = "";
    // Where it is: the input element (the node's, for one absent).
    pos: XmlPos = NO_POS;
    valuePos: XmlPos = NO_POS;
}

// An image node as read: its inputs, and the texture it holds (null when
// it names no file).
class Image {
    node: XmlNode;
    inputs: Map<string, XmlNode>;
    texture: PbrTexture? = null;
    filePos: XmlPos = NO_POS;

    constructor(node: XmlNode, inputs: Map<string, XmlNode>) {
        this.node = node;
        this.inputs = inputs;
    }
}

function isSpace(s: string): bool {
    for (let k = 0; k < s.length; k++) {
        const c = s.charCodeAt(k);
        if (c != 32 && c != 9 && c != 10 && c != 13) return false;
    }
    return true;
}

function article(t: string): string {
    const c = t.length > 0 ? t.charCodeAt(0) : 0;
    const vowel = c == 97 || c == 101 || c == 105 || c == 111 || c == 117;
    return (vowel ? "an " : "a ") + t;
}

class Reader {
    file: string;
    err: MtlxProblem? = null;
    warnings: Array<MtlxProblem> = [];
    m: PbrMaterial = new PbrMaterial();
    read_: MtlxRead? = null;
    root: XmlNode = XmlNode.element("");
    rootPos: XmlPos = NO_POS;
    top: Scope = new Scope(XmlNode.element(""), "");
    graph: Scope? = null;
    // Nodes visited ("<scope>/<name>"), and image nodes read once.
    used: Set<string> = new Set<string>();
    images: Map<string, Image> = new Map<string, Image>();
    checked: Set<string> = new Set<string>();

    constructor(file: string) {
        this.file = file;
    }

    // --- problems

    problem(code: string, at: XmlPos, message: string, hint: string): MtlxProblem {
        const p = new MtlxProblem(code, message, hint, at.line, at.col, false);
        p.file = this.file;
        return p;
    }

    // Sets the error (the first one stays) and returns false.
    fail(code: string, at: XmlPos, message: string, hint: string): bool {
        if (this.err == null) this.err = this.problem(code, at, message, hint);
        return false;
    }

    ignore(at: XmlPos, what: string, whats: string, message: string): void {
        const p = new MtlxProblem("mtlx-ignored", message,
            "Hedra reads the material without it, and `" + CLI + " format` would drop it (" + MTLX_DOC + ", \"Profile\")",
            at.line, at.col, true);
        p.file = this.file;
        p.what = what;
        p.whats = whats;
        this.warnings.push(p);
    }

    position(key: string, at: XmlPos): void {
        const rd = this.read_;
        if (rd == null || !at.isKnown()) return;
        rd.positions.set(key, [at.line, at.col]);
    }

    // --- the document

    read(text: string): MtlxRead? {
        const parsed = parseXmlText(text, this.file);
        if (!parsed.ok) {
            const xe = xmlErrorOf<XmlDocument>(parsed);
            const at = xe != null ? xe.pos : NO_POS;
            const message = xe != null ? xe.message : parsed.err;
            this.fail("mtlx-xml", at, message, "a material file is an XML document: " + MTLX_DOC + " shows one");
            return null;
        }
        const doc = parsed.value;
        const rd = new MtlxRead(this.m);
        this.read_ = rd;
        for (let k = 0; k < doc.prolog.length; k++) this.outside(doc.prolog[k]);
        for (let k = 0; k < doc.epilog.length; k++) this.outside(doc.epilog[k]);
        const root = doc.root;
        this.root = root;
        this.rootPos = root.pos;
        this.position("document", root.pos);
        if (root.name != "materialx") {
            this.fail("mtlx-root", root.pos, "the root element is <" + root.name + ">: a MaterialX document's is <materialx>",
                "a material file is a MaterialX document (" + MTLX_DOC + ")");
            return null;
        }
        if (!this.checkRoot(root)) return null;
        this.top = new Scope(root, "");
        if (!this.collect(this.top, true)) return null;
        if (!this.material()) return null;
        if (!this.extras()) return null;
        this.unused(this.top);
        const g = this.graph;
        if (g != null) this.unused(g);
        // Warnings in source order (stable), as the validator lists its own.
        const w = this.warnings;
        for (let a = 1; a < w.length; a++) {
            const p = w[a];
            let b = a - 1;
            while (b >= 0 && (w[b].line > p.line || (w[b].line == p.line && w[b].col > p.col))) {
                w[b + 1] = w[b];
                b--;
            }
            w[b + 1] = p;
        }
        rd.warnings = w;
        return rd;
    }

    // A comment or processing instruction before or after the root.
    outside(n: XmlNode): void {
        if (n.kind == XmlKind.Comment) this.ignore(n.pos, "comment", "comments", "a comment: ignored");
        else this.ignore(n.pos, "processing instruction", "processing instructions", "a processing instruction: ignored");
    }

    checkRoot(root: XmlNode): bool {
        const v = root.attrNode("version");
        if (v == null) {
            return this.fail("mtlx-version", root.pos, "the <materialx> element has no version",
                "write version=\"" + MTLX_VERSION + "\" (this build reads " + MTLX_READ_VERSIONS.join(" and ") + ")");
        }
        if (!MTLX_READ_VERSIONS.includes(v.value)) {
            return this.fail("mtlx-version", v.valuePos, "MaterialX version \"" + v.value + "\" is not one this build reads",
                "this build reads MaterialX " + MTLX_READ_VERSIONS.join(" and ") + " (" + MTLX_DOC + ")");
        }
        for (let k = 0; k < root.attrs.length; k++) {
            const a = root.attrs[k];
            if (a.name == "namespace" && a.value.length > 0) {
                this.ignore(a.pos, a.name, "", "namespace \"" + a.value + "\": ignored (the material's names are read as they are)");
            } else if (!ROOT_ATTRS.includes(a.name)) {
                this.ignore(a.pos, a.name, "", "attribute \"" + a.name + "\" on <materialx>: ignored");
            }
        }
        return true;
    }

    // The element children of a scope's element, by name; what is not a
    // node is warned about (or, at the top level, kept for later: the
    // surfacematerial and the nodegraphs).
    collect(scope: Scope, top: bool): bool {
        const el = scope.el;
        for (let k = 0; k < el.children.length; k++) {
            const c = el.children[k];
            if (c.kind == XmlKind.Comment) {
                this.ignore(c.pos, "comment", "comments", "a comment: ignored");
                continue;
            }
            if (c.kind == XmlKind.Pi) {
                this.ignore(c.pos, "processing instruction", "processing instructions", "a processing instruction: ignored");
                continue;
            }
            if (c.kind != XmlKind.Element) {
                if (!isSpace(c.text)) this.ignore(c.pos, "piece of text", "pieces of text", "text between elements: ignored");
                continue;
            }
            if (IGNORED_ELEMENTS.includes(c.name)) {
                this.ignore(c.pos, "<" + c.name + ">", "<" + c.name + "> elements", "<" + c.name + "> is not part of a material: ignored");
                continue;
            }
            if (c.name == "output" && top) {
                this.ignore(c.pos, "unused output", "unused outputs", "an output of the document: ignored (a material's are its nodes)");
                continue;
            }
            const name = c.attr("name");
            if (name == null || name.length == 0) {
                if (c.name == "output") {
                    return this.fail("mtlx-input-unknown", c.pos, "an <output> without a name", "every output has a name (" + MTLX_DOC + ")");
                }
                this.ignore(c.pos, "unnamed element", "unnamed elements", "a <" + c.name + "> without a name: ignored");
                continue;
            }
            if (scope.nodes.has(name)) {
                const first = scope.nodes.get(name).pos;
                const a = c.attrNode("name") as XmlAttr;
                return this.fail("mtlx-connection", a.valuePos,
                    "a second element named \"" + name + "\" (the first is at " + first.line.toString() + ":" + first.col.toString() + ")",
                    "names are unique within a document or a nodegraph: rename one (" + MTLX_DOC + ")");
            }
            scope.nodes.set(name, c);
            scope.order.push(name);
        }
        return true;
    }

    // Nodes nothing used: warned about, not read.
    unused(scope: Scope): void {
        for (let k = 0; k < scope.order.length; k++) {
            const name = scope.order[k];
            const n = scope.nodes.get(name);
            if (this.used.has(scope.key + "/" + name)) continue;
            if (n.name == "surfacematerial" || (scope.key == "" && n.name == "nodegraph" && name == EXTRAS_GRAPH)) continue;
            if (n.name == "output") continue;
            if (n.name == "nodegraph") {
                this.ignore(n.pos, "unused nodegraph", "unused nodegraphs", "nodegraph \"" + name + "\" is not part of the material: ignored");
            } else {
                this.ignore(n.pos, "unused node", "unused nodes", "node \"" + name + "\" (" + n.name + ") is not connected to the material: ignored");
            }
        }
    }

    // --- the material and its shader

    material(): bool {
        let found: XmlNode? = null;
        for (let k = 0; k < this.top.order.length; k++) {
            const n = this.top.nodes.get(this.top.order[k]);
            if (n.name != "surfacematerial") continue;
            if (found != null) {
                return this.fail("mtlx-material-count", n.pos,
                    "a second surfacematerial (the first is at " + found.pos.line.toString() + ":" + found.pos.col.toString() + ")",
                    "a material file holds one material: put each in a file of its own (" + MTLX_DOC + ")");
            }
            found = n;
        }
        if (found == null) {
            return this.fail("mtlx-material-count", this.root.pos, "the document holds no surfacematerial",
                "a material file holds one <surfacematerial> whose surfaceshader is a gltf_pbr node (" + MTLX_DOC + ")");
        }
        const mat = found;
        this.used.add("/" + (mat.attr("name") as string));
        this.nodeAttrs(mat);
        const name = mat.attr("name") as string;
        this.m.name = name;
        this.position("name", (mat.attrNode("name") as XmlAttr).valuePos);
        this.position("material", mat.pos);
        let shaderInput: XmlNode? = null;
        for (let k = 0; k < mat.children.length; k++) {
            const c = mat.children[k];
            if (!this.childNotElement(c)) continue;
            if (c.name != "input") {
                this.ignore(c.pos, "<" + c.name + ">", "<" + c.name + "> elements", "<" + c.name + "> in a surfacematerial: ignored");
                continue;
            }
            const iname = c.attr("name");
            if (iname == "surfaceshader") {
                shaderInput = c;
            } else if (iname == "backsurfaceshader" || iname == "displacementshader" || iname == "volumeshader") {
                this.ignore(c.pos, iname as string, "", "input \"" + (iname as string) + "\": ignored (glTF has none)");
            } else {
                return this.fail("mtlx-input-unknown", c.pos, "surfacematerial has no input \"" + (iname != null ? iname : "") + "\"",
                    "its inputs are surfaceshader, backsurfaceshader, displacementshader and volumeshader (" + MTLX_DOC + ")");
            }
        }
        if (shaderInput == null) {
            return this.fail("mtlx-shader", mat.pos, "surfacematerial \"" + name + "\" has no surfaceshader input",
                "connect its surfaceshader to a gltf_pbr node: <input name=\"surfaceshader\" type=\"surfaceshader\" nodename=\"...\"/>");
        }
        const si = shaderInput;
        this.inputAttrs(si, false);
        const target = si.attr("nodename");
        if (target == null) {
            return this.fail("mtlx-shader", si.pos, "the surfaceshader input connects to no node",
                "give it nodename=\"<the gltf_pbr node>\" (" + MTLX_DOC + ")");
        }
        if (!this.top.nodes.has(target)) {
            return this.fail("mtlx-connection", (si.attrNode("nodename") as XmlAttr).valuePos, "nodename \"" + target + "\" names no node",
                "a nodename is the name of a node of the document (" + MTLX_DOC + ")");
        }
        const shader = this.top.nodes.get(target);
        if (shader.name != "gltf_pbr") {
            return this.fail("mtlx-shader", shader.pos, "the surface shader \"" + target + "\" is " + article(shader.name)
                + " node: Hedra reads gltf_pbr",
                "Hedra's materials are glTF's: use MaterialX's gltf_pbr shader (" + MTLX_DOC + ", \"Profile\")");
        }
        if (shader.attr("type") != "surfaceshader") {
            return this.fail("mtlx-shader", shader.pos, "gltf_pbr node \"" + target + "\" is not of type surfaceshader",
                "write type=\"surfaceshader\" on it");
        }
        this.used.add("/" + target);
        this.nodeAttrs(shader);
        return this.shader(shader);
    }

    // Whether `c` is an element; otherwise it is warned about (comments,
    // stray text) and false.
    childNotElement(c: XmlNode): bool {
        if (c.kind == XmlKind.Element) return true;
        if (c.kind == XmlKind.Comment) this.ignore(c.pos, "comment", "comments", "a comment: ignored");
        else if (c.kind == XmlKind.Pi) this.ignore(c.pos, "processing instruction", "processing instructions", "a processing instruction: ignored");
        else if (!isSpace(c.text)) this.ignore(c.pos, "piece of text", "pieces of text", "text inside an element: ignored");
        return false;
    }

    // A node's attributes, each warned about once per node.
    nodeAttrs(n: XmlNode): void {
        for (let k = 0; k < n.attrs.length; k++) {
            const a = n.attrs[k];
            if (NODE_ATTRS.includes(a.name)) continue;
            this.ignore(a.pos, a.name, "", "attribute \"" + a.name + "\" on <" + n.name + ">: ignored");
        }
    }

    // An input's attributes: a connection to an interface or another
    // nodegraph's output is a connection the profile does not follow.
    // `file`: the input is an image node's file, which may also carry
    // RIVE_ATTRS (read by image()).
    inputAttrs(c: XmlNode, file: bool): bool {
        for (let k = 0; k < c.attrs.length; k++) {
            const a = c.attrs[k];
            if (INPUT_ATTRS.includes(a.name)) continue;
            if (file && RIVE_ATTRS.includes(a.name)) continue;
            if (a.name == "interfacename" || a.name == "nodegraph" || a.name == "channels") {
                return this.fail("mtlx-connection", a.pos, "input \"" + (c.attr("name") as string) + "\" uses " + a.name
                    + ", which the profile does not follow",
                    "connect inputs to nodes of the same scope with nodename (and output) (" + MTLX_DOC + ")");
            }
            this.ignore(a.pos, a.name, "", "attribute \"" + a.name + "\" on an input: ignored");
        }
        return true;
    }

    // The inputs of node `n` (of definition `defs`), by name: an unknown
    // name, a wrong type or a name given twice is an error (null).
    inputsOf(n: XmlNode, defs: Array<MtlxInputDef>, what: string): Map<string, XmlNode>? {
        const out = new Map<string, XmlNode>();
        for (let k = 0; k < n.children.length; k++) {
            const c = n.children[k];
            if (!this.childNotElement(c)) continue;
            if (c.name != "input") {
                this.ignore(c.pos, "<" + c.name + ">", "<" + c.name + "> elements", "<" + c.name + "> in " + what + ": ignored");
                continue;
            }
            const name = c.attr("name");
            if (name == null) {
                this.fail("mtlx-input-unknown", c.pos, "an input without a name in " + what, "every input has a name (" + MTLX_DOC + ")");
                return null;
            }
            const def = findInput(defs, name);
            if (def == null) {
                const names = new Array<string>();
                for (let d = 0; d < defs.length; d++) names.push(defs[d].name);
                this.fail("mtlx-input-unknown", (c.attrNode("name") as XmlAttr).valuePos, what + " has no input \"" + name + "\"",
                    "its inputs are " + names.join(", ") + " (" + MTLX_DOC + ")");
                return null;
            }
            if (out.has(name)) {
                this.fail("mtlx-input-unknown", (c.attrNode("name") as XmlAttr).valuePos, "input \"" + name + "\" is given twice in " + what,
                    "give each input once");
                return null;
            }
            const t = c.attrNode("type");
            if (t == null || t.value != def.type) {
                const found = t != null ? "\"" + t.value + "\"" : "none";
                this.fail("mtlx-input-type", t != null ? t.valuePos : c.pos, "input \"" + name + "\" of " + what + " is of type " + def.type
                    + ", found " + found, "write type=\"" + def.type + "\" (" + MTLX_DOC + ")");
                return null;
            }
            if (!this.inputAttrs(c, def.type == "filename")) return null;
            out.set(name, c);
        }
        return out;
    }

    // Input `name` of a node (its definition `def`): absent, a value, or a
    // connection; a constant it connects to is its value. null on error.
    src(scope: Scope, owner: XmlNode, inputs: Map<string, XmlNode>, def: MtlxInputDef): Src? {
        const s = new Src();
        s.pos = owner.pos;
        if (!inputs.has(def.name)) return s;
        const c = inputs.get(def.name);
        s.present = true;
        s.input = c;
        s.pos = c.pos;
        const value = c.attrNode("value");
        const nodename = c.attrNode("nodename");
        if (value != null && nodename != null) {
            this.fail("mtlx-connection", nodename.pos, "input \"" + def.name + "\" has both a value and a nodename",
                "give an input a value or a connection, not both");
            return null;
        }
        if (value != null) {
            s.valuePos = value.valuePos;
            if (!this.parseValue(s, def.type, value.value, value.valuePos)) return null;
            s.colorspace = this.colorspaceOf(c, owner, scope);
            return s;
        }
        if (nodename == null) {
            // An input with neither: its default, as MaterialX reads it.
            s.present = false;
            return s;
        }
        const target = nodename.value;
        if (!scope.nodes.has(target)) {
            this.fail("mtlx-connection", nodename.valuePos, "nodename \"" + target + "\" names no node"
                + (scope.key.length > 0 ? " of nodegraph \"" + scope.key + "\"" : ""),
                "a nodename is the name of a node in the same scope (" + MTLX_DOC + ")");
            return null;
        }
        const node = scope.nodes.get(target);
        if (!NODE_CATEGORIES.includes(node.name)) {
            const why = node.name == "nodegraph" || node.name == "surfacematerial" || node.name == "output"
                ? "is " + article("<" + node.name + ">") + ", not a node"
                : "is " + article(node.name) + " node, which the profile does not read";
            this.fail("mtlx-node-unsupported", node.pos, "node \"" + target + "\" " + why,
                "a material's graph is gltf_pbr and glTF's texture nodes, with extract, normalmap, mix, texcoord and constant ("
                    + MTLX_DOC + ", \"Profile\")");
            return null;
        }
        this.visit(scope, node);
        const out = c.attr("output");
        if (node.name == "constant") {
            if (out != null) {
                this.fail("mtlx-connection", c.pos, "a constant has one output: input \"" + def.name + "\" names output \"" + out + "\"",
                    "leave the output out");
                return null;
            }
            const ct = node.attr("type");
            if (ct != def.type) {
                this.fail("mtlx-input-type", c.pos, "input \"" + def.name + "\" is of type " + def.type + ", and constant \"" + target
                    + "\" is of type " + (ct != null ? ct : "none"), "connect it to a constant of type " + def.type);
                return null;
            }
            const defs = nodeInputs("constant", def.type);
            if (defs == null) return null;
            const ins = this.inputsOf(node, defs, "constant \"" + target + "\"");
            if (ins == null) return null;
            const vd = defs[0];
            const inner = this.src(scope, node, ins, vd);
            if (inner == null) return null;
            if (inner.node != null) {
                this.fail("mtlx-connection", inner.pos, "constant \"" + target + "\" takes its value from a node",
                    "a constant's value is written in it");
                return null;
            }
            if (!inner.present) {
                this.parseValue(inner, vd.type, vd.def, node.pos);
                inner.colorspace = this.colorspaceOf(null, node, scope);
            }
            inner.present = true;
            inner.pos = c.pos;
            return inner;
        }
        s.node = node;
        s.output = out != null ? out : "";
        s.valuePos = nodename.valuePos;
        return s;
    }

    visit(scope: Scope, node: XmlNode): void {
        const key = scope.key + "/" + (node.attr("name") as string);
        if (this.used.has(key)) return;
        this.used.add(key);
        this.nodeAttrs(node);
    }

    parseValue(s: Src, type: string, text: string, at: XmlPos): bool {
        s.isValue = true;
        s.text = text;
        if (type == "filename" || type == "string") return true;
        if (type == "boolean") {
            const t = text.trim();
            if (t != "true" && t != "false") return this.fail("mtlx-value", at, "\"" + text + "\" is not a boolean", "write true or false");
            s.nums = [t == "true" ? 1 : 0];
            return true;
        }
        if (type == "integer") {
            const v = parseInteger(text);
            if (v == NOT_AN_INTEGER) return this.fail("mtlx-value", at, "\"" + text + "\" is not an integer", "write a whole number, as 1");
            s.nums = [<f32>v];
            return true;
        }
        let n = 1;
        if (type == "vector2") n = 2;
        else if (type == "color3" || type == "vector3") n = 3;
        else if (type == "color4" || type == "vector4") n = 4;
        const v = parseFloats(text, n);
        if (v == null) {
            return this.fail("mtlx-value", at, "\"" + text + "\" is not " + article(type) + " (" + n.toString() + (n == 1 ? " number" : " numbers") + ")",
                n == 1 ? "write a number, as 0.5" : "write " + n.toString() + " numbers separated by commas, as \"" + (n == 2 ? "1, 1" : n == 3 ? "1, 0.5, 0" : "1, 1, 1, 1") + "\"");
        }
        s.nums = v;
        return true;
    }

    // The colour space of a value: its own, else its node's, else its
    // scope's, else the document's, else MaterialX's default.
    colorspaceOf(input: XmlNode?, node: XmlNode, scope: Scope): string {
        if (input != null) {
            const a = input.attr("colorspace");
            if (a != null) return a;
        }
        const b = node.attr("colorspace");
        if (b != null) return b;
        if (scope.el !== this.root) {
            const c = scope.el.attr("colorspace");
            if (c != null) return c;
        }
        const d = this.root.attr("colorspace");
        return d != null ? d : LINEAR;
    }

    // A colour value as Hedra keeps colours, sRGB-encoded (alpha, a
    // fourth number, as it is); null on a colour space the reader does not
    // convert.
    colour(s: Src): Array<f32>? {
        const out = s.nums.slice(0);
        if (s.colorspace == SRGB) return out;
        if (s.colorspace != LINEAR) {
            this.fail("mtlx-value", s.pos, "colour space \"" + s.colorspace + "\" is not one this build converts",
                "write colours in srgb_texture or lin_rec709 (" + MTLX_DOC + ")");
            return null;
        }
        for (let k = 0; k < 3 && k < out.length; k++) out[k] = linearToSrgbValue(out[k]);
        return out;
    }

    // --- gltf_pbr

    shader(n: XmlNode): bool {
        const inputs = this.inputsOf(n, GLTF_PBR_INPUTS, "gltf_pbr");
        if (inputs == null) return false;
        const m = this.m;
        const scope = this.top;
        for (let k = 0; k < GLTF_PBR_INPUTS.length; k++) {
            const def = GLTF_PBR_INPUTS[k];
            const s = this.src(scope, n, inputs, def);
            if (s == null) return false;
            if (!this.pbrInput(scope, def, s)) return false;
        }
        // base_color's texture and alpha come from one gltf_colorimage.
        if (this.alphaLinked && !this.baseLinked) {
            return this.fail("mtlx-connection", this.alphaPos, "alpha comes from a gltf_colorimage and base_color does not",
                "glTF's alpha is the base colour texture's: connect base_color to the same node's outcolor (" + MTLX_DOC + ")");
        }
        // The other way round, glTF would draw alpha times the texture's,
        // MaterialX the value alone; the canonical file connects alpha, so
        // `format` would change what other tools draw. Opaque, alpha is
        // not drawn and either reading is the same picture.
        if (this.baseLinked && !this.alphaLinked && m.alphaMode != PBR_ALPHA_OPAQUE) {
            return this.fail("mtlx-connection", this.basePos, "base_color comes from a gltf_colorimage and alpha does not, "
                + "with alpha_mode " + m.alphaMode.toString(),
                "glTF's alpha is the base colour texture's times the factor: connect alpha to the same node's outa, the value "
                    + "as the alpha of the node's factor (" + MTLX_DOC + ")");
        }
        // glTF's anisotropy texture gives both strength and direction. A
        // strength left unconnected is gltf_pbr's 0, which glTF has as a
        // strength of 0 over the texture; a direction left unconnected is
        // the tangent's whatever the texture says, which glTF cannot have.
        if (this.anisoRotationLinked && !this.anisoStrengthLinked) m.anisotropyStrength = 0;
        if (this.anisoStrengthLinked && !this.anisoRotationLinked) {
            return this.fail("mtlx-connection", this.anisoPos, "anisotropy_strength comes from a gltf_anisotropy_image and "
                + "anisotropy_rotation does not", "glTF's anisotropy texture gives the direction too: connect anisotropy_rotation to "
                    + "the same node's anisotropy_rotation_out (" + MTLX_DOC + ")");
        }
        return true;
    }

    alphaLinked: bool = false;
    baseLinked: bool = false;
    alphaPos: XmlPos = NO_POS;
    basePos: XmlPos = NO_POS;
    baseNode: XmlNode? = null;
    anisoNode: XmlNode? = null;
    // Which of the two anisotropy inputs the gltf_anisotropy_image gives,
    // and where the first connection is.
    anisoStrengthLinked: bool = false;
    anisoRotationLinked: bool = false;
    anisoPos: XmlPos = NO_POS;
    // anisotropy_strength was given as a value (so rotation may not be a
    // texture's).
    anisoStrengthValue: bool = false;

    pbrInput(scope: Scope, def: MtlxInputDef, s: Src): bool {
        const m = this.m;
        const name = def.name;
        if (s.present) this.position(fieldOf(name), s.pos);
        if (s.node == null) {
            // A value (or absent: the nodedef's default, but for the two
            // inputs glTF reads otherwise).
            if (name == "normal" || name == "tangent" || name == "clearcoat_normal") {
                if (s.present) this.ignore(s.pos, "input \"" + name + "\" value", "", "a value for " + name + ": ignored (glTF's comes from a texture)");
                return true;
            }
            if (name == "occlusion") {
                if (s.present && s.nums[0] != 1) this.ignore(s.pos, "input \"occlusion\" value", "", "an occlusion value: ignored (glTF's comes from a texture)");
                return true;
            }
            if (name == "attenuation_distance") {
                if (s.present) m.attenuationDistance = s.nums[0];
                return true;
            }
            if (name == "iridescence_thickness") {
                // Absent: MaterialX's 100 when the film has a weight, else
                // glTF's 400 (it draws nothing either way).
                const film = m.iridescence != 0 || m.texture(PbrSlot.Iridescence) != null;
                m.iridescenceThicknessMaximum = s.present ? s.nums[0] : film ? <f32>100 : <f32>400;
                return true;
            }
            if (!s.present) this.parseValue(s, def.type, def.def, NO_POS);
            if (def.type == "color3") {
                if (!s.present) s.colorspace = SRGB;
                const c = this.colour(s);
                if (c == null) return false;
                if (name == "base_color") {
                    m.baseColor[0] = c[0];
                    m.baseColor[1] = c[1];
                    m.baseColor[2] = c[2];
                } else if (name == "specular_color") m.specularColor = [c[0], c[1], c[2]];
                else if (name == "sheen_color") m.sheenColor = [c[0], c[1], c[2]];
                else if (name == "emissive") m.emissive = [c[0], c[1], c[2]];
                else m.attenuationColor = [c[0], c[1], c[2]];
                return true;
            }
            if (name == "anisotropy_strength" || name == "anisotropy_rotation") {
                // With the texture, its node holds both; one given here as
                // well cannot be glTF's.
                if (this.anisoNode != null) return s.present ? this.anisoMismatch(s) : true;
                if (name == "anisotropy_strength" && s.present) this.anisoStrengthValue = true;
            }
            const v = s.nums[0];
            if (name == "alpha_mode") {
                if (v != 0 && v != 1 && v != 2) {
                    return this.fail("mtlx-value", s.valuePos, "alpha_mode " + (<i32>v).toString() + " is not one of glTF's",
                        "0 OPAQUE, 1 MASK, 2 BLEND");
                }
                m.alphaMode = <i32>v;
            } else if (name == "metallic") m.metallic = v;
            else if (name == "roughness") m.roughness = v;
            else if (name == "transmission") m.transmission = v;
            else if (name == "specular") m.specular = v;
            else if (name == "ior") m.ior = v;
            else if (name == "alpha") m.baseColor[3] = v;
            else if (name == "alpha_cutoff") m.alphaCutoff = v;
            else if (name == "iridescence") m.iridescence = v;
            else if (name == "iridescence_ior") m.iridescenceIor = v;
            else if (name == "sheen_roughness") m.sheenRoughness = v;
            else if (name == "clearcoat") m.clearcoat = v;
            else if (name == "clearcoat_roughness") m.clearcoatRoughness = v;
            else if (name == "emissive_strength") m.emissiveStrength = v;
            else if (name == "thickness") m.thickness = v;
            else if (name == "anisotropy_strength") m.anisotropyStrength = v;
            else if (name == "anisotropy_rotation") m.anisotropyRotation = v;
            else if (name == "dispersion") m.dispersion = v;
            return true;
        }
        // A connection: the node glTF's table puts there.
        const node = s.node as XmlNode;
        if (name == "base_color" || name == "alpha") return this.baseColorLink(scope, name, s, node);
        if (name == "anisotropy_strength" || name == "anisotropy_rotation") return this.anisoLink(scope, name, s, node);
        if (name == "normal" || name == "clearcoat_normal") {
            return this.normalLink(scope, name == "normal" ? PbrSlot.Normal : PbrSlot.ClearcoatNormal, s, node);
        }
        if (name == "occlusion") return this.occlusionLink(scope, s, node);
        if (name == "iridescence_thickness") return this.thicknessLink(scope, s, node);
        const slot = slotOfInput(name);
        if (slot < 0) {
            return this.fail("mtlx-connection", s.pos, "gltf_pbr's " + name + " is a value in glTF, not a texture",
                "write it as a value (" + MTLX_DOC + ")");
        }
        return this.slotLink(scope, slot, s, node);
    }

    // A slot read from an image's output, or from one channel of it through
    // an extract (MTLX_SLOTS says which), its factor the glTF factor.
    slotLink(scope: Scope, slot: i32, s: Src, node: XmlNode): bool {
        const d = MTLX_SLOTS[slot];
        const target = d.input.length > 0 ? "gltf_pbr's " + d.input : "extra " + d.extra;
        if (s.output.length > 0) {
            return this.fail("mtlx-connection", s.pos, target + " names output \"" + s.output + "\" of " + node.name + " \""
                + (node.attr("name") as string) + "\", which has one", "leave the output out");
        }
        let image = node;
        if (d.channel >= 0) {
            if (node.name != "extract") {
                return this.fail("mtlx-connection", s.valuePos, target + " is channel " + d.channel.toString() + " of a "
                    + d.type + " gltf_image, through an extract; found " + article(node.name) + " node",
                    "glTF reads " + target + " from one channel of its texture: " + MTLX_DOC + " has the table");
            }
            const from = this.extract(scope, node, d.type, d.channel, target);
            if (from == null) return false;
            image = from;
        } else if (node.name != d.category || node.attr("type") != d.type) {
            return this.fail("mtlx-connection", s.valuePos, target + " comes from " + article(d.category) + " of type " + d.type
                + "; found " + article(node.name) + " node of type " + (node.attr("type") != null ? node.attr("type") as string : "none"),
                "glTF's table (" + MTLX_DOC + ") says which node feeds each input");
        }
        const img = this.image(scope, image, slot);
        if (img == null) return false;
        const f = this.factor(scope, img, slot);
        if (f == null) return false;
        this.setFactor(slot, f, d.channel);
        return true;
    }

    // The image an extract takes channel `channel` of (a gltf_image of
    // type `type`), or null on error.
    extract(scope: Scope, x: XmlNode, type: string, channel: i32, target: string): XmlNode? {
        if (x.attr("type") != "float") {
            this.fail("mtlx-input-type", x.pos, "extract \"" + (x.attr("name") as string) + "\" is not of type float", "write type=\"float\"");
            return null;
        }
        const pre = new Map<string, XmlNode>();
        for (let k = 0; k < x.children.length; k++) {
            const c = x.children[k];
            if (c.kind == XmlKind.Element && c.name == "input" && c.attr("name") == "in") pre.set("in", c);
        }
        const inType = pre.has("in") ? (pre.get("in").attr("type") != null ? pre.get("in").attr("type") as string : "") : type;
        const defs = nodeInputs("extract", "float", inType == "color4" || inType == "vector3" ? inType : "color3");
        if (defs == null) return null;
        const ins = this.inputsOf(x, defs, "extract \"" + (x.attr("name") as string) + "\"");
        if (ins == null) return null;
        const idx = this.src(scope, x, ins, defs[1]);
        if (idx == null) return null;
        if (idx.node != null) {
            this.fail("mtlx-connection", idx.pos, "an extract's index comes from a node", "write the index as a value");
            return null;
        }
        const index = idx.present ? <i32>idx.nums[0] : 0;
        if (index != channel) {
            this.fail("mtlx-connection", idx.present ? idx.valuePos : x.pos, target + " is channel " + channel.toString()
                + " of its texture, and extract \"" + (x.attr("name") as string) + "\" takes channel " + index.toString(),
                "glTF's channels: " + MTLX_DOC + " has the table");
            return null;
        }
        const from = this.src(scope, x, ins, defs[0]);
        if (from == null) return null;
        const img = from.node;
        if (img == null || img.name != "gltf_image" || img.attr("type") != type) {
            const found = img != null ? article(img.name) + " node of type " + (img.attr("type") != null ? img.attr("type") as string : "none")
                : from.present ? "a value" : "nothing";
            this.fail("mtlx-connection", from.pos, "extract \"" + (x.attr("name") as string) + "\" for " + target + " reads "
                + found + ": glTF's channel comes from a gltf_image of type " + type, "connect its in to the texture's gltf_image");
            return null;
        }
        return img;
    }

    // An image node read for `slot` (once per node: a texture two slots
    // share is read once and given to both).
    image(scope: Scope, node: XmlNode, slot: i32): Image? {
        const key = scope.key + "/" + (node.attr("name") as string);
        if (this.images.has(key)) {
            const known = this.images.get(key);
            const t = known.texture;
            this.m.setTexture(slot, t != null ? t.clone() : null);
            if (t != null) this.position("textures[" + slot.toString() + "]", known.filePos);
            return known;
        }
        const type = node.attr("type");
        const defs = nodeInputs(node.name, type != null ? type : "");
        if (defs == null) {
            this.fail("mtlx-input-type", node.pos, node.name + " \"" + (node.attr("name") as string) + "\" of type "
                + (type != null ? type : "none") + " is not one the profile reads", "glTF's table (" + MTLX_DOC + ") gives each node's type");
            return null;
        }
        const ins = this.inputsOf(node, defs, node.name + " \"" + (node.attr("name") as string) + "\"");
        if (ins == null) return null;
        const img = new Image(node, ins);
        this.images.set(key, img);
        // The inputs glTF has no word for: at their defaults, or ignored.
        for (let k = 0; k < UNMODELLED_IMAGE_INPUTS.length; k++) {
            const name = UNMODELLED_IMAGE_INPUTS[k];
            const def = findInput(defs, name);
            if (def == null || !ins.has(name)) continue;
            const s = this.src(scope, node, ins, def);
            if (s == null) return null;
            if (s.node != null || (s.present && !sameValue(s, def))) {
                this.ignore(s.pos, "input \"" + name + "\"", "", "input \"" + name + "\" of " + node.name + ": ignored (glTF's sampler is not part of the format)");
            }
        }
        const file = this.src(scope, node, ins, defs[0]);
        if (file == null) return null;
        if (file.node != null) {
            this.fail("mtlx-connection", file.pos, "a texture's file comes from a node", "write the file as a value");
            return null;
        }
        const path = file.present ? file.text : "";
        const fileInput = file.input;
        const isRiv = isRivePath(path);
        if (fileInput != null && !isRiv) {
            // An artboard's attributes on an image would be dropped by
            // the CLI's `format`, and say the author meant a .riv.
            for (let k = 0; k < RIVE_ATTRS.length; k++) {
                const a = fileInput.attrNode(RIVE_ATTRS[k]);
                if (a == null) continue;
                this.fail("mtlx-value", a.pos, a.name + " on \"" + path + "\", which is not a Rive file",
                    "the artboard attributes go with a .riv file (" + ARTBOARD_HINT_DOC + ")");
                return null;
            }
        }
        if (path.length == 0) {
            // A texture node with no file is no texture (its factor stays).
            this.m.setTexture(slot, null);
            return img;
        }
        const t = new PbrTexture(this.prefixOf(node, scope) + path);
        img.filePos = file.valuePos;
        if (isRiv && !this.artboardOf(t, file, path, slot)) return null;
        // glTF decodes a colour texture as sRGB and a data texture (normals,
        // roughness...) as it is, whatever the file says; the canonical
        // file says so. A file saying otherwise draws differently in other
        // tools, so it is read as glTF does with a warning, which makes
        // `format` refuse rather than change it silently.
        const srgb = MTLX_SLOTS[slot].srgb;
        if (srgb != (file.colorspace == SRGB)) {
            const cs = file.colorspace.length > 0 ? file.colorspace : "none";
            this.ignore(file.pos, "texture colour space", "texture colour spaces", "texture \"" + path + "\" in colour space \""
                + cs + "\": read as " + (srgb ? "srgb_texture, as glTF reads a colour texture" : "linear, as glTF reads a data texture"));
        }
        // The UV set.
        const tc = findInput(defs, "texcoord") as MtlxInputDef;
        const uv = this.src(scope, node, ins, tc);
        if (uv == null) return null;
        const uvNode = uv.node;
        if (uvNode != null) {
            if (uvNode.name != "texcoord") {
                this.fail("mtlx-node-unsupported", uv.valuePos, "texcoord comes from " + article(uvNode.name) + " node",
                    "a texture's UV set is a texcoord node (<texcoord><input name=\"index\" .../></texcoord>)");
                return null;
            }
            const tdefs = nodeInputs("texcoord", "vector2") as Array<MtlxInputDef>;
            const tins = this.inputsOf(uvNode, tdefs, "texcoord \"" + (uvNode.attr("name") as string) + "\"");
            if (tins == null) return null;
            const index = this.src(scope, uvNode, tins, tdefs[0]);
            if (index == null) return null;
            if (index.node != null) {
                this.fail("mtlx-connection", index.pos, "a texcoord's index comes from a node", "write the index as a value");
                return null;
            }
            const set = index.present ? <i32>index.nums[0] : 0;
            if (set < 0) {
                this.fail("mtlx-value", index.valuePos, "UV set " + set.toString() + " is below 0", "glTF's sets are 0, 1, ...");
                return null;
            }
            t.texCoord = set;
        } else if (uv.present) {
            this.ignore(uv.pos, "input \"texcoord\" value", "", "a constant texture coordinate: ignored (glTF samples a UV set)");
        }
        // KHR_texture_transform.
        const sc = this.src(scope, node, ins, findInput(defs, "scale") as MtlxInputDef);
        const ro = this.src(scope, node, ins, findInput(defs, "rotate") as MtlxInputDef);
        const of = this.src(scope, node, ins, findInput(defs, "offset") as MtlxInputDef);
        if (sc == null || ro == null || of == null) return null;
        if (!this.valueOnly(sc) || !this.valueOnly(ro) || !this.valueOnly(of)) return null;
        if (sc.present) t.scale = [sc.nums[0], sc.nums[1]];
        if (of.present) t.offset = [of.nums[0], of.nums[1]];
        if (ro.present) {
            const deg = parseDouble(ro.text);
            const ri = ro.input as XmlNode;
            const unit = ri.attr("unit");
            if (unit == null || unit == "degree") t.rotation = radiansOf(deg);
            else if (unit == "radian") t.rotation = <f32>deg;
            else {
                this.fail("mtlx-value", (ri.attrNode("unit") as XmlAttr).valuePos, "rotate in \"" + unit + "\" is not converted",
                    "write rotate in degree (MaterialX's default) or radian");
                return null;
            }
        }
        img.texture = t;
        this.m.setTexture(slot, t);
        this.position("textures[" + slot.toString() + "]", file.valuePos);
        return img;
    }

    // The artboard of texture `t`, whose file (`file`, its text `path`)
    // is a .riv: rive_artboard required, rive_state_machine and rive_size
    // optional. Fails (false) with mtlx-value at the attribute.
    artboardOf(t: PbrTexture, file: Src, path: string, slot: i32): bool {
        const c = file.input as XmlNode;
        const name = c.attrNode("rive_artboard");
        if (name == null) {
            return this.fail("mtlx-value", file.valuePos, "a Rive file needs rive_artboard: \"" + path + "\" names no artboard",
                "name the artboard the texture is drawn from, as rive_artboard=\"Screen\" (" + ARTBOARD_HINT_DOC + ")");
        }
        // An empty rive_artboard is an ArtboardTexture whose artboard is
        // "", as a scene's may be: it draws as a placeholder, with the
        // warning artboard-unknown where the texture is checked (the
        // editor's new texture starts that way, and its Save As writes it).
        const a = new PbrArtboard(name.value);
        const sm = c.attrNode("rive_state_machine");
        if (sm != null) {
            if (sm.value.length == 0) {
                return this.fail("mtlx-value", sm.valuePos, "rive_state_machine is empty",
                    "name a state machine of the artboard, or leave the attribute out for its default one (" + ARTBOARD_HINT_DOC + ")");
            }
            a.stateMachine = sm.value;
        }
        const size = c.attrNode("rive_size");
        if (size != null) {
            const wh = parseWholePair(size.value, 1, RIVE_SIZE_MAX);
            if (wh == null) {
                return this.fail("mtlx-value", size.valuePos, "rive_size \"" + size.value + "\" is not a texture size",
                    "write two whole numbers from 1 to " + RIVE_SIZE_MAX.toString() + ", width then height, as \"1024, 512\"; "
                        + "leave it out for the artboard's own size (" + ARTBOARD_HINT_DOC + ")");
            }
            a.width = wh[0];
            a.height = wh[1];
        }
        // Milestone 67: Godot's name of the update mode, and the rate.
        const mode = c.attrNode("rive_update_mode");
        if (mode != null) {
            const m = PBR_ARTBOARD_MODES.indexOf(mode.value);
            if (m < 0) {
                return this.fail("mtlx-value", mode.valuePos, "rive_update_mode \"" + mode.value + "\" is not an update mode",
                    "write disabled, once, when_visible, when_parent_visible or always; leave it out for when_visible ("
                        + ARTBOARD_HINT_DOC + ")");
            }
            a.updateMode = m;
        }
        const fps = c.attrNode("rive_update_fps");
        if (fps != null) {
            const v = parseDouble(fps.value);
            if (!(v >= 0)) {
                return this.fail("mtlx-value", fps.valuePos, "rive_update_fps \"" + fps.value + "\" is not a rate",
                    "write a number of redraws a second, 0 or more (30, 15); leave it out for every change ("
                        + ARTBOARD_HINT_DOC + ")");
            }
            a.updateFps = <f32>v;
        }
        t.artboard = a;
        const key = "textures[" + slot.toString() + "]";
        this.position(key + ".artboard", name.valuePos);
        if (sm != null) this.position(key + ".stateMachine", sm.valuePos);
        if (size != null) this.position(key + ".size", size.valuePos);
        if (mode != null) this.position(key + ".updateMode", mode.valuePos);
        if (fps != null) this.position(key + ".updateFps", fps.valuePos);
        return true;
    }

    valueOnly(s: Src): bool {
        if (s.node == null) return true;
        return this.fail("mtlx-connection", s.pos, "a texture's transform comes from a node", "write scale, rotate and offset as values");
    }

    // The fileprefix in force for a node's file (the node's, its scope's,
    // the document's).
    prefixOf(node: XmlNode, scope: Scope): string {
        const a = node.attr("fileprefix");
        if (a != null) return a;
        if (scope.el !== this.root) {
            const b = scope.el.attr("fileprefix");
            if (b != null) return b;
        }
        const c = this.root.attr("fileprefix");
        return c != null ? c : "";
    }

    // An image node's factor (gltf_image's `factor`, gltf_colorimage's
    // `color`): its numbers, colours made sRGB for a colour slot; [] when
    // the node has none.
    factor(scope: Scope, img: Image, slot: i32): Array<f32>? {
        const node = img.node;
        const name = node.name == "gltf_colorimage" ? "color" : "factor";
        const type = node.attr("type");
        const defs = nodeInputs(node.name, type != null ? type : "") as Array<MtlxInputDef>;
        const def = findInput(defs, name);
        if (def == null) return [];
        const s = this.src(scope, node, img.inputs, def);
        if (s == null) return null;
        if (s.node != null) {
            this.fail("mtlx-connection", s.pos, "a texture's " + name + " comes from a node", "write it as a value");
            return null;
        }
        if (!s.present) {
            this.parseValue(s, def.type, def.def, NO_POS);
            return s.nums;
        }
        if (MTLX_SLOTS[slot].srgb) return this.colour(s);
        return s.nums;
    }

    // The glTF factor of `slot` from its image's factor (`channel` the one
    // read, -1 for a colour or a float image).
    setFactor(slot: i32, f: Array<f32>, channel: i32): void {
        if (f.length == 0) return;
        const m = this.m;
        const v = channel >= 0 ? f[channel] : f[0];
        switch (slot) {
            case PbrSlot.Metallic: m.metallic = v; break;
            case PbrSlot.Roughness: m.roughness = v; break;
            case PbrSlot.Emissive: m.emissive = [f[0], f[1], f[2]]; break;
            case PbrSlot.Clearcoat: m.clearcoat = v; break;
            case PbrSlot.ClearcoatRoughness: m.clearcoatRoughness = v; break;
            case PbrSlot.SheenColor: m.sheenColor = [f[0], f[1], f[2]]; break;
            case PbrSlot.SheenRoughness: m.sheenRoughness = v; break;
            case PbrSlot.Specular: m.specular = v; break;
            case PbrSlot.SpecularColor: m.specularColor = [f[0], f[1], f[2]]; break;
            case PbrSlot.Transmission: m.transmission = v; break;
            case PbrSlot.Thickness: m.thickness = v; break;
            case PbrSlot.Iridescence: m.iridescence = v; break;
            case PbrSlot.DiffuseTransmission: m.diffuseTransmission = v; break;
            case PbrSlot.DiffuseTransmissionColor: m.diffuseTransmissionColor = [f[0], f[1], f[2]]; break;
            default: break;
        }
    }

    // base_color (outcolor) and alpha (outa) from one gltf_colorimage.
    baseColorLink(scope: Scope, name: string, s: Src, node: XmlNode): bool {
        const want = name == "base_color" ? "outcolor" : "outa";
        if (node.name != "gltf_colorimage") {
            return this.fail("mtlx-connection", s.valuePos, "gltf_pbr's " + name + " comes from a gltf_colorimage's " + want
                + "; found " + article(node.name) + " node", "glTF's base colour texture is a gltf_colorimage (" + MTLX_DOC + ")");
        }
        if (s.output != want) {
            return this.fail("mtlx-connection", s.pos, "gltf_pbr's " + name + " takes output \"" + want + "\" of gltf_colorimage \""
                + (node.attr("name") as string) + "\", not " + (s.output.length > 0 ? "\"" + s.output + "\"" : "none"),
                "write output=\"" + want + "\"");
        }
        const prev = this.baseNode;
        if (prev != null && prev !== node) {
            return this.fail("mtlx-connection", s.valuePos, "base_color and alpha come from two gltf_colorimage nodes",
                "glTF's base colour and alpha are one texture: connect both to the same node");
        }
        this.baseNode = node;
        const img = this.image(scope, node, PbrSlot.BaseColor);
        if (img == null) return false;
        const f = this.factor(scope, img, PbrSlot.BaseColor);
        if (f == null) return false;
        const m = this.m;
        if (name == "base_color") {
            this.baseLinked = true;
            this.basePos = s.pos;
            m.baseColor[0] = f[0];
            m.baseColor[1] = f[1];
            m.baseColor[2] = f[2];
        } else {
            m.baseColor[3] = f[3];
            this.alphaLinked = true;
            this.alphaPos = s.pos;
        }
        return true;
    }

    // anisotropy_strength and anisotropy_rotation from one
    // gltf_anisotropy_image (its two outputs).
    anisoLink(scope: Scope, name: string, s: Src, node: XmlNode): bool {
        const want = name + "_out";
        if (node.name != "gltf_anisotropy_image") {
            return this.fail("mtlx-connection", s.valuePos, "gltf_pbr's " + name + " comes from a gltf_anisotropy_image; found "
                + article(node.name) + " node", "glTF's anisotropy texture is a gltf_anisotropy_image (" + MTLX_DOC + ")");
        }
        if (s.output != want) {
            return this.fail("mtlx-connection", s.pos, "gltf_pbr's " + name + " takes output \"" + want + "\" of \""
                + (node.attr("name") as string) + "\", not " + (s.output.length > 0 ? "\"" + s.output + "\"" : "none"),
                "write output=\"" + want + "\"");
        }
        const prev = this.anisoNode;
        if (prev != null && prev !== node) {
            return this.fail("mtlx-connection", s.valuePos, "anisotropy_strength and anisotropy_rotation come from two nodes",
                "glTF's anisotropy is one texture: connect both to the same gltf_anisotropy_image");
        }
        if (prev == null && name == "anisotropy_rotation" && this.anisoStrengthValue) {
            // Strength came first, as a value: one is a texture's, the
            // other not.
            return this.anisoMismatch(s);
        }
        this.anisoNode = node;
        if (name == "anisotropy_strength") this.anisoStrengthLinked = true;
        else this.anisoRotationLinked = true;
        if (prev != null) return true;
        this.anisoPos = s.pos;
        const img = this.image(scope, node, PbrSlot.Anisotropy);
        if (img == null) return false;
        const type = node.attr("type");
        const defs = nodeInputs(node.name, type != null ? type : "") as Array<MtlxInputDef>;
        const strength = this.src(scope, node, img.inputs, findInput(defs, "anisotropy_strength") as MtlxInputDef);
        const rotation = this.src(scope, node, img.inputs, findInput(defs, "anisotropy_rotation") as MtlxInputDef);
        if (strength == null || rotation == null) return false;
        if (!this.valueOnly(strength) || !this.valueOnly(rotation)) return false;
        this.m.anisotropyStrength = strength.present ? strength.nums[0] : 1;
        this.m.anisotropyRotation = rotation.present ? rotation.nums[0] : 0;
        return true;
    }

    anisoMismatch(s: Src): bool {
        return this.fail("mtlx-connection", s.pos, "one of anisotropy_strength and anisotropy_rotation comes from a "
            + "gltf_anisotropy_image and the other does not", "connect both to the node's two outputs, as glTF's texture holds both");
    }

    // normal (or clearcoat_normal): a gltf_normalmap, or a normalmap
    // scaling a gltf_image of type vector3.
    normalLink(scope: Scope, slot: i32, s: Src, node: XmlNode): bool {
        const d = MTLX_SLOTS[slot];
        let image = node;
        let scale: f32 = 1;
        if (node.name == "normalmap") {
            if (node.attr("type") != "vector3") {
                return this.fail("mtlx-input-type", node.pos, "normalmap \"" + (node.attr("name") as string) + "\" is not of type vector3",
                    "write type=\"vector3\"");
            }
            const defs = nodeInputs("normalmap", "vector3") as Array<MtlxInputDef>;
            const ins = this.inputsOf(node, defs, "normalmap \"" + (node.attr("name") as string) + "\"");
            if (ins == null) return false;
            for (let k = 2; k < 5; k++) {
                if (ins.has(defs[k].name)) {
                    return this.fail("mtlx-connection", ins.get(defs[k].name).pos, "the normalmap's " + defs[k].name
                        + " is set: glTF's normal map uses the surface's own", "leave normal, tangent and bitangent out");
                }
            }
            // MaterialX 1.38's space: tangent (its default, and glTF's) is
            // read, object space has no place in glTF's normal texture.
            const sp = this.src(scope, node, ins, defs[5]);
            if (sp == null) return false;
            if (sp.node != null) return this.fail("mtlx-connection", sp.pos, "a normal map's space comes from a node", "write it as a value");
            const space = sp.present ? sp.text.trim() : "tangent";
            if (space == "object") {
                return this.fail("mtlx-connection", sp.valuePos, "normalmap \"" + (node.attr("name") as string)
                    + "\" is in object space: glTF's normal texture is in tangent space", "bake the normals to tangent space, "
                    + "then write space=\"tangent\" or leave it out");
            }
            if (space != "tangent") {
                return this.fail("mtlx-value", sp.valuePos, "\"" + space + "\" is not a normalmap space", "write tangent or object");
            }
            const sc = this.src(scope, node, ins, defs[1]);
            if (sc == null) return false;
            if (sc.node != null) return this.fail("mtlx-connection", sc.pos, "a normal map's scale comes from a node", "write it as a value");
            scale = sc.present ? sc.nums[0] : 1;
            const from = this.src(scope, node, ins, defs[0]);
            if (from == null) return false;
            const img = from.node;
            if (img == null || img.name != "gltf_image" || img.attr("type") != "vector3") {
                return this.fail("mtlx-connection", from.pos, "normalmap \"" + (node.attr("name") as string)
                    + "\" reads its normals from a gltf_image of type vector3", "connect its in to the normal texture");
            }
            image = img;
        } else if (node.name != "gltf_normalmap") {
            return this.fail("mtlx-connection", s.valuePos, "gltf_pbr's " + d.input + " comes from a gltf_normalmap (or a normalmap of a "
                + "gltf_image); found " + article(node.name) + " node", "glTF's normal texture: " + MTLX_DOC + " has the table");
        }
        if (s.output.length > 0) {
            return this.fail("mtlx-connection", s.pos, "gltf_pbr's " + d.input + " names output \"" + s.output + "\", and its node has one",
                "leave the output out");
        }
        const img = this.image(scope, image, slot);
        if (img == null) return false;
        if (slot == PbrSlot.Normal) this.m.normalScale = scale;
        else this.m.clearcoatNormalScale = scale;
        return true;
    }

    // occlusion: a gltf_image float, or a mix that scales it by the
    // strength (bg 1, fg the image, mix the strength).
    occlusionLink(scope: Scope, s: Src, node: XmlNode): bool {
        let image = node;
        let strength: f32 = 1;
        if (node.name == "mix") {
            if (node.attr("type") != "float") {
                return this.fail("mtlx-input-type", node.pos, "mix \"" + (node.attr("name") as string) + "\" is not of type float",
                    "write type=\"float\"");
            }
            const defs = nodeInputs("mix", "float") as Array<MtlxInputDef>;
            const ins = this.inputsOf(node, defs, "mix \"" + (node.attr("name") as string) + "\"");
            if (ins == null) return false;
            const fg = this.src(scope, node, ins, defs[0]);
            const bg = this.src(scope, node, ins, defs[1]);
            const mx = this.src(scope, node, ins, defs[2]);
            if (fg == null || bg == null || mx == null) return false;
            const bgOne = bg.node == null && bg.present && bg.nums[0] == 1;
            const img = fg.node;
            if (!bgOne || mx.node != null || img == null) {
                return this.fail("mtlx-connection", node.pos, "occlusion's mix is the texture (fg) over 1 (bg) by the strength (mix)",
                    "glTF's occlusion strength: <mix> with fg the gltf_image, bg 1, mix the strength (" + MTLX_DOC + ")");
            }
            strength = mx.present ? mx.nums[0] : 0;
            image = img;
        }
        if (image.name != "gltf_image" || image.attr("type") != "float") {
            return this.fail("mtlx-connection", s.valuePos, "gltf_pbr's occlusion comes from a gltf_image of type float; found "
                + article(image.name) + " node", "glTF's occlusion texture: " + MTLX_DOC + " has the table");
        }
        const img = this.image(scope, image, PbrSlot.Occlusion);
        if (img == null) return false;
        this.m.occlusionStrength = strength;
        return true;
    }

    // iridescence_thickness from a gltf_iridescence_thickness (its film's
    // minimum and maximum).
    thicknessLink(scope: Scope, s: Src, node: XmlNode): bool {
        if (node.name != "gltf_iridescence_thickness" || node.attr("type") != "float") {
            return this.fail("mtlx-connection", s.valuePos, "gltf_pbr's iridescence_thickness comes from a gltf_iridescence_thickness; found "
                + article(node.name) + " node", "glTF's iridescence thickness texture: " + MTLX_DOC + " has the table");
        }
        const img = this.image(scope, node, PbrSlot.IridescenceThickness);
        if (img == null) return false;
        const defs = nodeInputs(node.name, "float") as Array<MtlxInputDef>;
        const lo = this.src(scope, node, img.inputs, findInput(defs, "thicknessMin") as MtlxInputDef);
        const hi = this.src(scope, node, img.inputs, findInput(defs, "thicknessMax") as MtlxInputDef);
        if (lo == null || hi == null) return false;
        if (!this.valueOnly(lo) || !this.valueOnly(hi)) return false;
        this.m.iridescenceThicknessMinimum = lo.present ? lo.nums[0] : 100;
        this.m.iridescenceThicknessMaximum = hi.present ? hi.nums[0] : 400;
        this.thicknessFromTexture = true;
        return true;
    }

    thicknessFromTexture: bool = false;

    // --- the extras graph

    extras(): bool {
        if (!this.top.nodes.has(EXTRAS_GRAPH)) return true;
        const g = this.top.nodes.get(EXTRAS_GRAPH);
        if (g.name != "nodegraph") {
            return this.fail("mtlx-node-unsupported", g.pos, "\"" + EXTRAS_GRAPH + "\" is " + article("<" + g.name + ">")
                + ": Hedra's extras are a nodegraph", "rename the element, or make it the nodegraph " + MTLX_DOC + " shows");
        }
        for (let k = 0; k < g.attrs.length; k++) {
            const a = g.attrs[k];
            if (a.name == "name" || a.name == "colorspace" || a.name == "fileprefix") continue;
            this.ignore(a.pos, a.name, "", "attribute \"" + a.name + "\" on <nodegraph>: ignored");
        }
        const scope = new Scope(g, EXTRAS_GRAPH);
        this.graph = scope;
        if (!this.collect(scope, false)) return false;
        const m = this.m;
        let cullFrontAt: XmlPos? = null;
        for (let k = 0; k < scope.order.length; k++) {
            const o = scope.nodes.get(scope.order[k]);
            if (o.name != "output") continue;
            const name = o.attr("name") as string;
            if (name == "cull_front") cullFrontAt = o.pos;
            const type = extraType(name);
            if (type.length == 0) {
                return this.fail("mtlx-input-unknown", (o.attrNode("name") as XmlAttr).valuePos, "hedra_extras has no output \"" + name + "\"",
                    "its outputs are double_sided, cull_front, unlit, iridescence_thickness_minimum, diffuse_transmission, "
                        + "diffuse_transmission_color, vertex_color_use_as_albedo, vertex_color_is_srgb, billboard_mode, "
                        + "billboard_keep_scale and refraction_scale (" + MTLX_DOC + ")");
            }
            const t = o.attrNode("type");
            if (t == null || t.value != type) {
                return this.fail("mtlx-input-type", t != null ? t.valuePos : o.pos, "output \"" + name + "\" is of type " + type + ", found "
                    + (t != null ? "\"" + t.value + "\"" : "none"), "write type=\"" + type + "\"");
            }
            for (let a = 0; a < o.attrs.length; a++) {
                const at = o.attrs[a];
                if (at.name == "name" || at.name == "type" || at.name == "nodename" || at.name == "value" || at.name == "colorspace") continue;
                if (at.name == "interfacename" || at.name == "nodegraph" || at.name == "output") {
                    return this.fail("mtlx-connection", at.pos, "output \"" + name + "\" uses " + at.name + ", which the profile does not follow",
                        "connect it to a node of the graph with nodename");
                }
                this.ignore(at.pos, at.name, "", "attribute \"" + at.name + "\" on an output: ignored");
            }
            // An output reads like an input of the graph: a value, a
            // constant, or (for the two textured extras) a node.
            const ins = new Map<string, XmlNode>();
            ins.set(name, o);
            const s = this.src(scope, g, ins, new MtlxInputDef(name, type, ""));
            if (s == null) return false;
            this.position(fieldOfExtra(name), o.pos);
            const node = s.node;
            if (node != null) {
                if (name == "diffuse_transmission") {
                    if (!this.slotLink(scope, PbrSlot.DiffuseTransmission, s, node)) return false;
                } else if (name == "diffuse_transmission_color") {
                    if (!this.slotLink(scope, PbrSlot.DiffuseTransmissionColor, s, node)) return false;
                } else {
                    return this.fail("mtlx-connection", s.valuePos, "extra " + name + " is a value: it comes from a constant",
                        "connect it to a <constant> (" + MTLX_DOC + ")");
                }
                continue;
            }
            if (!s.present) continue;
            const v = s.nums.length > 0 ? s.nums[0] : 0;
            if (name == "double_sided") m.doubleSided = v != 0;
            else if (name == "cull_front") m.cullFront = v != 0;
            else if (name == "unlit") m.unlit = v != 0;
            else if (name == "vertex_color_use_as_albedo") m.vertexColorUseAsAlbedo = v != 0;
            else if (name == "vertex_color_is_srgb") m.vertexColorIsSrgb = v != 0;
            else if (name == "billboard_mode") {
                // (milestone 35: Godot's BillboardMode, beside the PbrMaterial)
                const mode = <i32>v;
                if (mode < 0 || mode > MTLX_BILLBOARD_MAX) {
                    return this.fail("mtlx-value", s.valuePos, "billboard_mode " + mode.toString() + " is not 0 to "
                        + MTLX_BILLBOARD_MAX.toString(), "write 0 (disabled), 1 (enabled), 2 (fixed_y) or 3 (particles)");
                }
                const rd = this.read_;
                if (rd != null) rd.billboard.mode = mode;
            } else if (name == "billboard_keep_scale") {
                const rd = this.read_;
                if (rd != null) rd.billboard.keepScale = v != 0;
            } else if (name == "refraction_scale") {
                // (milestone 62: Godot's refraction_scale, beside the
                // PbrMaterial as the billboard is)
                const rd = this.read_;
                if (rd != null) rd.billboard.refractionScale = v;
            }
            else if (name == "diffuse_transmission") m.diffuseTransmission = v;
            else if (name == "iridescence_thickness_minimum") {
                // With a thickness texture, its node's thicknessMin is the
                // minimum (the writer writes this extra only without one).
                if (this.thicknessFromTexture) {
                    this.ignore(o.pos, "extra iridescence_thickness_minimum", "",
                        "iridescence_thickness_minimum: ignored (the gltf_iridescence_thickness node's thicknessMin is the minimum)");
                } else {
                    m.iridescenceThicknessMinimum = v;
                }
            } else {
                const c = this.colour(s);
                if (c == null) return false;
                m.diffuseTransmissionColor = [c[0], c[1], c[2]];
            }
        }
        // A double-sided material culls nothing, so cull_front says nothing
        // more (Godot's one cull_mode holds either): read past, and said, so
        // that CLI's `format` refuses rather than drops it silently.
        if (m.doubleSided && m.cullFront && cullFrontAt != null) {
            m.cullFront = false;
            this.ignore(cullFrontAt as XmlPos, "extra cull_front", "",
                "cull_front: ignored (double_sided is set, and a double-sided material culls no face)");
        }
        return true;
    }
}

// Whether a value input is at its definition's default (compared as
// numbers, so "0,1" is "0, 1").
// Whether a texture's file names a Rive file (.riv, any case): a texture
// drawn from one of its artboards (milestone 15).
export function isRivePath(path: string): bool {
    const n = path.length;
    return n >= 4 && toAsciiLowercase(path.substring(n - 4)) == ".riv";
}

function sameValue(s: Src, def: MtlxInputDef): bool {
    if (def.type == "string" || def.type == "filename") return s.text.trim() == def.def;
    const d = new Src();
    const r = new Reader("");
    if (!r.parseValue(d, def.type, def.def, NO_POS)) return false;
    if (d.nums.length != s.nums.length) return false;
    for (let k = 0; k < d.nums.length; k++) if (d.nums[k] != s.nums[k]) return false;
    return true;
}

// The slot whose texture feeds gltf_pbr input `name` through slotLink, or
// -1 (a value-only input, or one with a reader of its own).
function slotOfInput(name: string): i32 {
    for (let k = 0; k < PBR_SLOT_COUNT; k++) {
        const d = MTLX_SLOTS[k];
        if (d.input == name && d.category == "gltf_image") return k;
    }
    return -1;
}

// The PbrMaterial field a gltf_pbr input sets (MtlxRead.positions' key).
function fieldOf(input: string): string {
    if (input == "base_color" || input == "alpha") return "baseColor";
    if (input == "specular_color") return "specularColor";
    if (input == "ior") return "ior";
    if (input == "alpha_mode") return "alphaMode";
    if (input == "alpha_cutoff") return "alphaCutoff";
    if (input == "iridescence_ior") return "iridescenceIor";
    if (input == "iridescence_thickness") return "iridescenceThicknessMaximum";
    if (input == "sheen_color") return "sheenColor";
    if (input == "sheen_roughness") return "sheenRoughness";
    if (input == "clearcoat_roughness") return "clearcoatRoughness";
    if (input == "clearcoat_normal") return "clearcoatNormalScale";
    if (input == "normal") return "normalScale";
    if (input == "occlusion") return "occlusionStrength";
    if (input == "emissive_strength") return "emissiveStrength";
    if (input == "attenuation_distance") return "attenuationDistance";
    if (input == "attenuation_color") return "attenuationColor";
    if (input == "anisotropy_strength") return "anisotropyStrength";
    if (input == "anisotropy_rotation") return "anisotropyRotation";
    return input;
}

function fieldOfExtra(name: string): string {
    if (name == "double_sided") return "doubleSided";
    if (name == "cull_front") return "cullFront";
    if (name == "iridescence_thickness_minimum") return "iridescenceThicknessMinimum";
    if (name == "diffuse_transmission") return "diffuseTransmission";
    if (name == "diffuse_transmission_color") return "diffuseTransmissionColor";
    if (name == "vertex_color_use_as_albedo") return "vertexColorUseAsAlbedo";
    if (name == "vertex_color_is_srgb") return "vertexColorIsSrgb";
    if (name == "billboard_mode") return "billboardMode";
    if (name == "billboard_keep_scale") return "billboardKeepScale";
    if (name == "refraction_scale") return "refractionScale";
    return name;
}
