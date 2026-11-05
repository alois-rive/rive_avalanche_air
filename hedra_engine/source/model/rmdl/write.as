// The .rmdl canonical writer: a scene and the document's head to the one
// text that holds them, deterministic and byte-stable (written, read and
// written again: the same bytes). docs/formats/RMDL.md "Canonical form" is
// the form.
//
// It writes the model's data form, structured: the data form's writer
// (../rmdlcmd/data/write.as sceneLines) gives the scene's records, each is
// split with the data form's own flag tables (words.as specsOf), and each
// record becomes its element by the schema (schema.as): positionals become
// attributes, flags properties, slot ids references by name or resource
// id. So the document holds exactly what the data form holds (a field at
// its default is left out where the data form leaves it out, -0 is kept),
// and reading it back replays the same records (read.as).
//
// The layout is .rscn's (../../textdoc/write.as spells the lines): the
// declaration; <rmdl format="1"[ uid]>; 2 spaces a level; one element a
// line; one blank line between non-empty sections (meta, ext_resource,
// sub_resource, scene, object, pose_clip, import); an element without
// content self-closes; a packed array of more than one group one group a
// line, 4 spaces deeper than its <property>.
//
// Milestone 61: a Material the head holds a shader for (doc.as
// RmdlShader, by the material's name) is written with its `shader` and its
// `shader_parameter/<name>` properties after its own, in the order they
// were read, the shader's file an ext_resource after the material's
// textures, a texture parameter's after it.

import { Result, StringBuilder } from "../../../base/util";
import { SceneryError } from "../../../scene/error";
import { quoteString } from "../../../scene/value_text";
import { MODEL_PATHS, extensionAccepted, resourcePathProblem } from "../../../scene/textdoc/check";
import { DocWriter, TextBuf, XML_DECLARATION_LINE, indentOf } from "../../textdoc/write";
import { Scene } from "../scene";
import { sceneLines } from "../rmdlcmd/data/write";
import { DataLine, Word, splitLine, recordOf } from "../rmdlcmd/data/line";
import { POSITIONALS, RECORDS, TEXTURE_SLOTS, specsOf, wordIndex } from "../rmdlcmd/data/words";
import { RmdlHead, RmdlShader } from "./doc";
import { E_RMDL_WRITE, RMDL_FORMAT, RMDL_ROOT } from "./format";
import {
    Kind, PER_LINE_FLAT, extExtensions, extExtensionsText, extTypeOf, PosRole, PropSpec, R_ARMATURE, R_ATTRIBUTE, R_BONE, R_CONSTRAINT, R_FCURVE,
    R_MATERIAL, R_MESH, R_MODIFIER, R_OBJECT, R_POSE_CLIP, R_SCENE, R_SELECTION_SET, R_SHAPEKEY, R_ACTION, R_VGROUP, ctorOf,
    recordSpec,
} from "./schema";

export const XML_DECLARATION = XML_DECLARATION_LINE;

// One record, split, and the records it holds (an action's F-curves, an
// object's vertex groups and modifiers, a mesh's shape keys, attributes and
// selection sets, an armature's bones, a bone's constraints).
class Rec {
    ri: i32;
    d: DataLine;
    children: Array<Rec> = [];
    // An object's mesh or armature record.
    data: Rec? = null;

    constructor(ri: i32, d: DataLine) {
        this.ri = ri;
        this.d = d;
    }

    // The positional `i` as a slot id.
    id(i: i32): u32 {
        return idOf(this.d.positionals[i].text());
    }
}

function idOf(t: string): u32 {
    return idIn(t, 0, t.length);
}

// The whole number t[a, b) (the data form's: digits only).
function idIn(t: string, a: i32, b: i32): u32 {
    let v: u32 = 0;
    for (let i = a; i < b; i++) v = v * 10 + <u32>(t.charCodeAt(i) - 48);
    return v;
}

// The writer's state: the records, the names references resolve to, the
// ext_resources, and the first problem.
class Writer {
    scene: Rec? = null;
    materials: Array<Rec> = [];
    actions: Array<Rec> = [];
    objects: Array<Rec> = [];
    clips: Array<Rec> = [];
    imports: Array<Rec> = [];
    // Object id -> name; the bone names of the armature being written.
    objectNames: Map<u32, string> = new Map<u32, string>();
    boneNames: Map<u32, string> = new Map<u32, string>();
    actionIds: Set<u32> = new Set<u32>();
    // ext_resources in order of first use: type, path, id; and the index of
    // each (type, path).
    extTypes: Array<string> = [];
    extPaths: Array<string> = [];
    extIds: Array<string> = [];
    extIndex: Map<string, i32> = new Map<string, i32>();
    error: string = "";
    // The data form's length: the document's is about twice it.
    size: i32 = 0;
    // Milestone 61: what the document holds besides the model (the
    // materials' shaders).
    head: RmdlHead = new RmdlHead();

    fail(message: string): void {
        if (this.error.length == 0) this.error = message;
    }

    // ---- the data form's lines, as records

    collect(lines: Array<string>): void {
        for (let i = 0; i < lines.length; i++) this.size += lines[i].length + 1;
        let action: Rec? = null;
        let object: Rec? = null;
        let bone: Rec? = null;
        for (let i = 0; i < lines.length; i++) {
            const text = lines[i];
            const ri = wordIndex(RECORDS, recordOf(text));
            if (ri < 0) {
                this.fail("the data form wrote a line this writer does not know: " + text);
                return;
            }
            const d = splitLine(text, POSITIONALS[ri], specsOf(ri));
            if (d.error.length > 0) {
                this.fail("the data form wrote a line that does not split (" + d.error + "): " + text);
                return;
            }
            const r = new Rec(ri, d);
            switch (ri) {
                case R_SCENE: this.scene = r; break;
                case R_MATERIAL: this.materials.push(r); break;
                case R_ACTION: {
                    this.actions.push(r);
                    this.actionIds.add(r.id(0));
                    action = r;
                    break;
                }
                case R_FCURVE: action!.children.push(r); break;
                case R_OBJECT: {
                    this.objects.push(r);
                    object = r;
                    this.objectNames.set(r.id(0), d.positionals[1].text());
                    break;
                }
                case R_VGROUP: case R_MODIFIER: object!.children.push(r); break;
                case R_MESH: case R_ARMATURE: object!.data = r; break;
                case R_SHAPEKEY: case R_ATTRIBUTE: case R_SELECTION_SET: object!.data!.children.push(r); break;
                case R_BONE: {
                    object!.data!.children.push(r);
                    bone = r;
                    break;
                }
                case R_CONSTRAINT: bone!.children.push(r); break;
                case R_POSE_CLIP: this.clips.push(r); break;
                default: this.imports.push(r); break;
            }
        }
    }

    // Object names, and each armature's bone names, must be unique:
    // references are by name.
    checkNames(): void {
        const seen = new Map<string, u32>();
        for (let i = 0; i < this.objects.length && this.error.length == 0; i++) {
            const o = this.objects[i];
            const name = o.d.positionals[1].text();
            if (seen.has(name)) {
                this.fail("objects " + seen.get(name).toString() + " and " + o.id(0).toString() + " are both named " + quoteString(name)
                    + ": a model document names its objects, so each name must be unique");
                return;
            }
            seen.set(name, o.id(0));
            const a = o.data;
            if (a == null || a.ri != R_ARMATURE) continue;
            const bones = new Map<string, u32>();
            for (let k = 0; k < a.children.length; k++) {
                const b = a.children[k];
                const bn = b.d.positionals[2].text();
                if (bones.has(bn)) {
                    this.fail("bones " + bones.get(bn).toString() + " and " + b.id(1).toString() + " of " + quoteString(name)
                        + " are both named " + quoteString(bn) + ": a model document names its bones, so each name must be unique");
                    return;
                }
                bones.set(bn, b.id(1));
            }
        }
    }

    // The ext_resources, in the order the document first names them: the
    // materials' (by material: its MaterialX file, then its textures in
    // slot order), the empties' instanced models (by object), then the
    // imports' sources.
    collectExts(): void {
        for (let i = 0; i < this.materials.length; i++) {
            const d = this.materials[i].d;
            const f = d.value("file");
            if (f != null) this.ext("Material", f.text());
            for (let s = 0; s < TEXTURE_SLOTS.length; s++) {
                const w = d.value(TEXTURE_SLOTS[s] + "-texture");
                if (w != null) this.ext("Texture2D", w.text());
            }
            // (milestone 61: its shader, then its texture parameters)
            const sh = this.shaderOf(this.materials[i]);
            if (sh != null) {
                this.ext("Shader", sh.path);
                for (let k = 0; k < sh.textures.length; k++) if (sh.textures[k].length > 0) this.ext("Texture2D", sh.textures[k]);
            }
        }
        for (let i = 0; i < this.objects.length; i++) {
            const w = this.objects[i].d.value("instance");
            if (w != null) this.ext("PackedScene", w.text());
        }
        for (let i = 0; i < this.imports.length; i++) this.ext("Model", this.imports[i].d.positionals[0].text());
    }

    private ext(type: string, path: string): void {
        const key = type + "\n" + path;
        if (this.extIndex.has(key)) return;
        const what = type == "Model" ? "a model import's source" : type == "Material" ? "a material's MaterialX file"
            : type == "PackedScene" ? "an instanced model" : type == "Shader" ? "a material's shader" : "a texture";
        const problem = resourcePathProblem(path, MODEL_PATHS);
        if (problem.length > 0) {
            this.fail(what + " cannot be written: " + problem);
            return;
        }
        const exts = extExtensions(type);
        if (exts.length > 0 && !extensionAccepted(exts, path)) {
            this.fail(what + " cannot be written: \"" + path + "\" is not " + extExtensionsText(type));
            return;
        }
        this.extIndex.set(key, this.extIds.length);
        this.extTypes.push(type);
        this.extPaths.push(path);
        this.extIds.push((this.extIds.length + 1).toString() + "_" + stemOf(path));
    }

    // Milestone 61: the shader the head holds for material record `r` (by
    // its name), or null.
    shaderOf(r: Rec): RmdlShader? {
        return this.head.shaderOf(r.d.positionals[1].text());
    }

    // Its `shader` and parameters, after its own properties (see the header).
    shaderProperties(w: DocWriter, r: Rec, depth: i32): void {
        const sh = this.shaderOf(r);
        if (sh == null) return;
        w.property("shader", "ExtResource(" + quoteString(this.extId("Shader", sh.path)) + ")", depth);
        for (let k = 0; k < sh.params.length; k++) {
            const tex = sh.textures[k];
            const v = tex.length > 0 ? "ExtResource(" + quoteString(this.extId("Texture2D", tex)) + ")" : sh.values[k];
            w.property("shader_parameter/" + sh.params[k], v, depth);
        }
    }

    extId(type: string, path: string): string {
        const key = type + "\n" + path;
        return this.extIndex.has(key) ? this.extIds[this.extIndex.get(key)] : "";
    }

    // ---- writing

    // The document, written in one pass into one buffer sized from the
    // data form's length (`size`).
    write(head: RmdlHead, size: i32): string {
        const w = new DocWriter(size * 2 + 4096);
        w.declaration();
        const rootAttrs: Array<string> = ["format", RMDL_FORMAT.toString()];
        const uid = head.uid;
        if (uid != null) {
            rootAttrs.push("uid");
            rootAttrs.push(uid);
        }
        // The sections that are not empty: blank lines go between them.
        const s = this.scene;
        // (built with push: the compiler misreads a bool array literal past
        // its first element, tools/check_repo.py's `bools`)
        const has = new Array<bool>();
        has.push(head.meta.length > 0);
        has.push(this.extIds.length > 0);
        has.push(this.materials.length + this.actions.length > 0 || this.anyData());
        has.push(s != null && this.hasBody(s));
        has.push(this.objects.length > 0);
        has.push(this.clips.length > 0);
        has.push(this.imports.length > 0);
        if (!has.includes(true)) {
            w.selfClosing(RMDL_ROOT, rootAttrs, 0);
            this.unwritable(w);
            return w.text();
        }
        w.open(RMDL_ROOT, rootAttrs, 0);
        let first = true;
        for (let i = 0; i < has.length; i++) {
            if (!has[i]) continue;
            if (!first) w.blank();
            first = false;
            switch (i) {
                case 0: {
                    for (let k = 0; k < head.meta.length; k++) w.selfClosing("meta", ["name", head.meta[k].name, "value", head.meta[k].value], 1);
                    break;
                }
                case 1: {
                    for (let k = 0; k < this.extIds.length; k++) {
                        const a = ["id", this.extIds[k], "type", this.extTypes[k], "path", this.extPaths[k]];
                        const extUid = head.extUid(this.extTypes[k], this.extPaths[k]);
                        if (extUid != null) {
                            a.push("uid");
                            a.push(extUid);
                        }
                        w.selfClosing("ext_resource", a, 1);
                    }
                    break;
                }
                case 2: {
                    for (let k = 0; k < this.materials.length; k++) this.element(w, this.materials[k], 1, "Material_" + k.toString());
                    for (let k = 0; k < this.actions.length; k++) {
                        this.element(w, this.actions[k], 1, "Action_" + this.actions[k].id(0).toString());
                    }
                    for (let k = 0; k < this.objects.length; k++) {
                        const o = this.objects[k];
                        const d = o.data;
                        if (d != null) this.element(w, d, 1, dataId(o));
                    }
                    break;
                }
                case 3: {
                    w.open("scene", [], 1);
                    this.properties(w, s!, 2);
                    w.close("scene", 1);
                    break;
                }
                default: {
                    const recs = i == 4 ? this.objects : i == 5 ? this.clips : this.imports;
                    for (let k = 0; k < recs.length; k++) this.element(w, recs[k], 1, "");
                    break;
                }
            }
        }
        w.close(RMDL_ROOT, 0);
        this.unwritable(w);
        return w.text();
    }

    // A name or path XML cannot hold (a control character, a lone
    // surrogate): the reader would refuse the document, so it is not
    // written. (A <property>'s String is quoted, \u0001, and always fits.)
    unwritable(w: DocWriter): void {
        if (w.bad.length > 0 && this.error.length == 0) this.fail(w.bad + ", which no XML document can hold");
    }

    anyData(): bool {
        for (let k = 0; k < this.objects.length; k++) if (this.objects[k].data != null) return true;
        return false;
    }

    // Whether a record's element holds a property (or, for an object, its
    // data): a positional written as a property, or a flag that is not an
    // attribute nor a count the document derives.
    hasBody(r: Rec): bool {
        const spec = recordSpec(r.ri);
        if (r.data != null) return true;
        for (let i = 0; i < spec.positionals.length; i++) if (spec.positionals[i].role == PosRole.Prop) return true;
        const flags = r.d.flags;
        for (let k = 0; k < flags.length; k++) {
            const p = spec.byFlag(flags[k]);
            if (p != null && !p.attr) return true;
        }
        return false;
    }

    // A record's element at `depth`: attributes, properties, children. `id`
    // is a sub_resource's id.
    element(w: DocWriter, r: Rec, depth: i32, id: string): void {
        const spec = recordSpec(r.ri);
        const attrs: Array<string> = [];
        if (spec.element == "sub_resource") {
            attrs.push("id");
            attrs.push(id);
            attrs.push("type");
            attrs.push(spec.subType);
        }
        for (let i = 0; i < spec.positionals.length; i++) {
            const ps = spec.positionals[i];
            if (ps.role != PosRole.Attr) continue;
            attrs.push(ps.name);
            attrs.push(r.d.positionals[i].text());
        }
        // The armature's bone names, for its bones' and its own references.
        if (r.ri == R_ARMATURE) this.bonesOf(r);
        for (let i = 0; i < spec.props.length; i++) {
            const p = spec.props[i];
            if (!p.attr) continue;
            const v = r.d.value(p.flag);
            if (v == null) continue;
            attrs.push(p.name);
            attrs.push(p.kind == Kind.ObjName ? this.objectName(v) : p.kind == Kind.BoneName ? this.boneName(v) : v.text());
        }
        if (!this.hasBody(r) && r.children.length == 0) {
            w.selfClosing(spec.element, attrs, depth);
            return;
        }
        w.open(spec.element, attrs, depth);
        this.properties(w, r, depth + 1);
        if (r.ri == R_MATERIAL) this.shaderProperties(w, r, depth + 1);
        for (let i = 0; i < r.children.length; i++) this.element(w, r.children[i], depth + 1, "");
        w.close(spec.element, depth);
    }

    // The bone names of an armature record.
    bonesOf(a: Rec): void {
        this.boneNames = new Map<u32, string>();
        for (let k = 0; k < a.children.length; k++) {
            const b = a.children[k];
            this.boneNames.set(b.id(1), b.d.positionals[2].text());
        }
    }

    objectName(v: Word): string {
        const id = idOf(v.text());
        if (!this.objectNames.has(id)) {
            this.fail("a reference to object " + id.toString() + ", which the scene does not hold");
            return "";
        }
        return this.objectNames.get(id);
    }

    boneName(v: Word): string {
        const id = idOf(v.text());
        if (!this.boneNames.has(id)) {
            this.fail("a reference to bone " + id.toString() + ", which the armature does not hold");
            return "";
        }
        return this.boneNames.get(id);
    }

    // The <property> lines of a record: the positionals a property holds
    // (a name, an import's source) first, then the flags in the order the
    // data form wrote them (its order is each kind's: an array modifier's
    // count before its merge threshold, a mirror's axis first), an object's
    // `data` before its first flag that the schema puts after it.
    properties(w: DocWriter, r: Rec, depth: i32): void {
        const spec = recordSpec(r.ri);
        for (let i = 0; i < spec.positionals.length; i++) {
            const ps = spec.positionals[i];
            if (ps.role != PosRole.Prop) continue;
            const t = r.d.positionals[i].text();
            if (ps.kind == Kind.Model) w.property(ps.name, "ExtResource(" + quoteString(this.extId("Model", t)) + ")", depth);
            else w.property(ps.name, quoteString(t), depth);
        }
        let dataAt = -1;
        for (let i = 0; i < spec.props.length; i++) if (spec.props[i].kind == Kind.Data) dataAt = i;
        let dataDone = dataAt < 0 || r.data == null;
        const flags = r.d.flags;
        for (let k = 0; k < flags.length; k++) {
            // A repeated flag is one property, written at its first.
            if (flags.indexOf(flags[k]) != k) continue;
            let at = -1;
            for (let i = 0; i < spec.props.length; i++) {
                if (spec.props[i].flag == flags[k]) {
                    at = i;
                    break;
                }
            }
            if (at < 0) continue;
            const p = spec.props[at];
            if (p.attr) continue;
            if (!dataDone && at > dataAt) {
                w.property("data", "SubResource(" + quoteString(dataId(r)) + ")", depth);
                dataDone = true;
            }
            this.property(w, r, p, depth);
        }
        if (!dataDone) w.property("data", "SubResource(" + quoteString(dataId(r)) + ")", depth);
    }

    property(w: DocWriter, r: Rec, p: PropSpec, depth: i32): void {
        const d = r.d;
        // A switch has no value: it is written as `true`.
        if (p.kind == Kind.Bool) {
            w.property(p.name, "true", depth);
            return;
        }
        const v = d.value(p.flag)!;
        switch (p.kind) {
            case Kind.Int: w.property(p.name, v.text(), depth); return;
            case Kind.Float: w.property(p.name, numText(v.text()), depth); return;
            case Kind.Bool: w.property(p.name, "true", depth); return;
            case Kind.Str: w.property(p.name, quoteString(v.text()), depth); return;
            case Kind.StrList: {
                const all = d.all(p.flag);
                const parts: Array<string> = [];
                for (let i = 0; i < all.length; i++) parts.push(quoteString(all[i].text()));
                w.property(p.name, "[" + parts.join(", ") + "]", depth);
                return;
            }
            case Kind.Dict: {
                // The data form says hidden (1); the document says visible.
                const names = d.all(p.flag, 0);
                const hides = d.all(p.flag, 1);
                const parts: Array<string> = [];
                for (let i = 0; i < names.length; i++) parts.push(quoteString(names[i].text()) + ": " + (hides[i].is("1") ? "false" : "true"));
                w.property(p.name, "{" + parts.join(", ") + "}", depth);
                return;
            }
            case Kind.ObjName: w.property(p.name, quoteString(this.objectName(v)), depth); return;
            case Kind.BoneName: w.property(p.name, quoteString(this.boneName(v)), depth); return;
            case Kind.Action: {
                if (v.is("none")) {
                    w.property(p.name, "null", depth);
                    return;
                }
                const id = idOf(v.text());
                if (!this.actionIds.has(id)) this.fail("a reference to action " + id.toString() + ", which the scene does not hold");
                w.property(p.name, "SubResource(\"Action_" + id.toString() + "\")", depth);
                return;
            }
            case Kind.Texture: case Kind.MaterialFile: case Kind.Scene: {
                w.property(p.name, "ExtResource(" + quoteString(this.extId(extTypeOf(p.kind), v.text())) + ")", depth);
                return;
            }
            case Kind.Materials: {
                const n = this.materials.length;
                const ids = numbersOf(v);
                const parts: Array<string> = [];
                for (let i = 0; i < ids.length; i++) {
                    const k = idOf(ids[i]);
                    // An empty slot (the kernel's u32::MAX) is `null`.
                    if (k == u32.MAX_VALUE) {
                        parts.push("null");
                        continue;
                    }
                    if (k >= <u32>n) this.fail("a material slot names material " + k.toString() + ", which the scene does not hold");
                    parts.push("SubResource(\"Material_" + k.toString() + "\")");
                }
                w.property(p.name, "[" + parts.join(", ") + "]", depth);
                return;
            }
            case Kind.Split3: {
                const nums = numbersOf(v);
                for (let t = 0; t < 3; t++) {
                    const a = nums[t * 3];
                    const b = nums[t * 3 + 1];
                    const c = nums[t * 3 + 2];
                    if (a + " " + b + " " + c == p.defaults[t]) continue;
                    w.property(p.names[t], "Vector3(" + numText(a) + ", " + numText(b) + ", " + numText(c) + ")", depth);
                }
                return;
            }
            case Kind.F32s: case Kind.V3s: case Kind.I32s: case Kind.Nums: {
                let kind = p.kind;
                let group = p.group;
                if (kind == Kind.Nums) {
                    // An attribute's values: the array its type holds.
                    const t = d.value("type");
                    if (t != null && t.is("vec3")) {
                        kind = Kind.V3s;
                        group = 3;
                    } else if (t != null && (t.is("int") || t.is("bool"))) kind = Kind.I32s;
                    else kind = Kind.F32s;
                }
                w.propertyStart(p.name, depth);
                packedInto(w.out, ctorOf(kind), v, group, p.variable, p.per, depth);
                w.propertyEnd();
                return;
            }
            default: {
                // The vectors and colours: one constructor of the flag's
                // numbers, on one line.
                w.propertyStart(p.name, depth);
                packedInto(w.out, ctorOf(p.kind), v, 1 << 30, false, 0, depth);
                w.propertyEnd();
                return;
            }
        }
    }
}

// A mesh's or an armature's sub_resource id: its object's slot.
function dataId(o: Rec): string {
    const d = o.data;
    if (d == null) return "";
    return (d.ri == R_MESH ? "Mesh_" : "Armature_") + o.id(0).toString();
}

// A number as the document writes it: the data form's text, but `nan` for
// its `NaN` (the document's literals are lowercase, as .rscn's).
function numText(t: string): string {
    return t == "NaN" ? "nan" : t;
}

// The numbers of a word, as written (separated by single spaces).
function numbersOf(v: Word): Array<string> {
    const out: Array<string> = [];
    const s = v.src;
    let i = v.s;
    while (i < v.e) {
        while (i < v.e && s.charCodeAt(i) == 0x20) i++;
        if (i >= v.e) break;
        const a = i;
        while (i < v.e && s.charCodeAt(i) != 0x20) i++;
        out.push(s.substring(a, i));
    }
    return out;
}

// The file name of a path without its extension, every character outside
// [A-Za-z0-9_-] replaced by `_`: the stem of a canonical ext_resource id
// (`textures/wood.png` -> `wood`).
export function stemOf(path: string): string {
    const slash = path.lastIndexOf("/");
    let base = path.substring(slash + 1);
    const dot = base.lastIndexOf(".");
    if (dot > 0) base = base.substring(0, dot);
    const out = new StringBuilder();
    let from = 0;
    for (let i = 0; i < base.length; i++) {
        const c = base.charCodeAt(i);
        const ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 45;
        if (ok) continue;
        out.push(base.substring(from, i)).push("_");
        // A surrogate pair is one character: one `_`.
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < base.length) i++;
        from = i + 1;
    }
    out.push(base.substring(from));
    return out.toString();
}

// A packed array's text (after `<property name="...">`, before
// `</property>`), written into `out`: `Ctor(` and its numbers, `, ` between
// them; more than one group (or element, for a variable group: a count `k`
// and `k * per` numbers) on lines of their own, indented 4 spaces deeper
// than the property at `depth`, a `,` ending every line but the last, `)`
// right after the last number. The numbers are the data form's, copied
// from its line as they stand (`NaN` written `nan`).
function packedInto(out: TextBuf, ctor: string, v: Word, group: i32, variable: bool, per: i32, depth: i32): void {
    const s = v.src;
    const end = v.e;
    const g = group > 0 ? group : PER_LINE_FLAT;
    // Wrapped when there is more than one group (or element).
    let wrap = false;
    {
        let n = 0;
        let i = v.s;
        let elements = 0;
        let left = 0;
        while (i < end && !wrap) {
            while (i < end && s.charCodeAt(i) == 0x20) i++;
            if (i >= end) break;
            const a = i;
            while (i < end && s.charCodeAt(i) != 0x20) i++;
            if (variable) {
                if (left == 0) {
                    elements++;
                    left = <i32>idIn(s, a, i) * per;
                } else left--;
                if (elements > 1) wrap = true;
            } else {
                n++;
                if (n > g) wrap = true;
            }
        }
    }
    const pad = indentOf(depth + 2);
    out.push(ctor).pushUnit(0x28);
    let i = v.s;
    let inLine = 0;
    let left = 0;
    let firstNum = true;
    while (i < end) {
        while (i < end && s.charCodeAt(i) == 0x20) i++;
        if (i >= end) break;
        const a = i;
        while (i < end && s.charCodeAt(i) != 0x20) i++;
        // Does this number start a new line?
        let fresh = false;
        if (variable) {
            if (left == 0) {
                fresh = true;
                left = <i32>idIn(s, a, i) * per;
            } else left--;
        } else {
            fresh = inLine == g || firstNum;
            if (fresh) inLine = 0;
            inLine++;
        }
        if (!firstNum) out.pushUnit(0x2C);
        if (wrap && fresh) out.pushUnit(0x0A).push(pad);
        else if (!firstNum) out.pushUnit(0x20);
        firstNum = false;
        if (s.charCodeAt(a) == 0x4E) out.push("nan");
        else out.pushRange(s, a, i);
    }
    out.pushUnit(0x29);
}

// The canonical text of `scene` under `head`: LF line ends, a final line
// feed. Fails (E_RMDL_WRITE) only on a scene the format cannot name: two
// objects (or two bones of an armature) with one name, a reference to a
// slot that holds nothing, a texture, MaterialX, instance or import path no
// document can hold (empty, with a backslash, res://, a directory), a file
// of the wrong kind (an import that is not glTF, a material file that is no
// .mtlx, an instance that is no model file), a name, path or metadata value holding a character XML cannot hold
// (a control character other than tab and line ends, U+FFFE, U+FFFF, a lone
// surrogate). The kernel clears a reference when it deletes the object and
// keeps names unique, so the others come from a hand-written data form (an
// .rmdlcmd of `data` lines); a control character can come from any name
// (a `rename`, a glTF's node names), and the document is not written.
export function writeRmdl(scene: Scene, head: RmdlHead): Result<string> {
    const wr = new Writer();
    wr.head = head;
    wr.collect(sceneLines(scene));
    if (wr.error.length == 0) wr.checkNames();
    if (wr.error.length == 0) wr.collectExts();
    let text = "";
    if (wr.error.length == 0) text = wr.write(head, wr.size);
    if (wr.error.length > 0) {
        return SceneryError.at(E_RMDL_WRITE, "model", 0, 0, "cannot write the model as an .rmdl: " + wr.error,
            "the document is not written: change what the message names (a model's data form, an .rmdlcmd, can hold it)").fail<string>();
    }
    return Result.okv<string>(text);
}
