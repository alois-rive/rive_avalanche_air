// An .mtlx material file as the material document the rest of Hedra
// edits (milestone 14): an RscnDoc of kind DocKind.Material, its
// ext_resources the textures the file names and its <resource> a
// StandardMaterial3D with the properties that differ from classdb's
// defaults, so that the validator, the loader (material_file.as), the CLI
// and the editor's document operations, written for scene documents, serve
// MaterialX files unchanged. The road both ways:
//
//   .mtlx text --readMtlx--> PbrMaterial --standardFromPbr--> StandardMaterial3D
//              --(properties off their defaults)--> RscnDoc
//   RscnDoc --(properties, texture paths)--> StandardMaterial3D
//           --pbrFromStandard--> PbrMaterial --writeMtlx--> .mtlx text
//
// The document is made, not parsed: its positions are the .mtlx file's
// (MtlxRead.positions) so the validator's messages point into the file;
// texture ext_resource ids are "tex_<slot>" (PbrSlot) in slot order, one
// per path (a metallic-roughness texture is one ext_resource, as a glTF
// model's is one image), paths as the file wrote them. A float property's
// value is the f64 of the f32's shortest text, so `inspect` shows 0.85, not
// 0.8500000238. docs/formats/MATERIALS.md, "In Hedra", is the normative
// description.
//
// Milestone 15: a slot whose texture is drawn from a Rive artboard (its
// file a .riv with rive_artboard, MATERIALS.md "Artboard textures") is an
// ext_resource "tex_<slot>" of type RiveFile (one per path, as images) and
// a sub_resource "art_<slot>" of type ArtboardTexture (file, artboard,
// state_machine and size, the last two when the file sets them; one per
// distinct artboard texture, so a texture two slots share, as base colour
// and emission drawn from one artboard, is one instance), which the
// slot's property names: SubResource("art_<slot>"). Their positions are
// the file's (the `file` value, the rive_* attributes' values).
//
// Milestone 35: StandardMaterial3D's billboard_mode and billboard_keep_scale
// are the extras graph's (mtlx_defs.as MtlxBillboard), carried beside the
// PbrMaterial both ways (MtlxRead.billboard, writeMtlx's billboard).
// Milestone 62: so is its refraction_scale (the same carrier's
// refractionScale), written only off Godot's 0.05.
//
// Milestone 61: a ShaderMaterial is never a material document's: MaterialX
// holds no shader (../../../scene/rscn/validate.as isMaterialClass refuses
// one in a document, material_file.as materialFileProblem one to extract),
// and standardOfMaterialDoc builds a StandardMaterial3D only.

import { Result, f64ToI32 } from "../../../base/util";
import { displayF32 } from "../../../base/fmt";
import { parseF64 } from "../../../base/parse";
import { XmlAttr, XmlPos } from "../../../base/xml";
import { PBR_ARTBOARD_WHEN_VISIBLE, PBR_SLOT_COUNT, PbrArtboard, PbrMaterial, PbrTexture } from "../../../material/pbr";
import { MtlxProblem, MtlxRead, readMtlx, writeMtlx } from "../../material/mtlx";
import { MtlxBillboard } from "../../material/mtlx_defs";
import { Diagnostic, SceneryError, Severity } from "../../../scene/error";
import { MATERIAL_TEXTURE_PROPS, MATERIAL_UV_SUFFIXES, allProps } from "../../../scene/classdb";
import { Value, ValueKind } from "../../../scene/value";
import { BodyItem, DocKind, ExtResourceDecl, Property, RscnDoc, SubResourceDecl } from "../../../scene/rscn/doc";
import { DocResources, buildSubResource } from "../../../scene/resource/build";
import { pbrFromStandard, standardFromPbr } from "../../../scene/resource/pbr_map";
import { ArtboardTexture, Resource, RiveFile, StandardMaterial3D, Texture2D } from "../../../scene/resource/types";

// The class a material file's document holds.
const MATERIAL_CLASS = "StandardMaterial3D";

// readMtlx's error code as the library reports it: the same code, spelt
// out here so that RSCN.md's table of codes, which the CLI's docs test
// compares with the codes the library reports, lists every one; a code
// this build does not know (a newer reader's) is reported as mtlx-xml
// rather than as a code no document explains.
function sceneryCode(c: string): string {
    let code = "mtlx-xml";
    if (c == "mtlx-root") code = "mtlx-root";
    else if (c == "mtlx-version") code = "mtlx-version";
    else if (c == "mtlx-material-count") code = "mtlx-material-count";
    else if (c == "mtlx-shader") code = "mtlx-shader";
    else if (c == "mtlx-node-unsupported") code = "mtlx-node-unsupported";
    else if (c == "mtlx-input-unknown") code = "mtlx-input-unknown";
    else if (c == "mtlx-input-type") code = "mtlx-input-type";
    else if (c == "mtlx-value") code = "mtlx-value";
    else if (c == "mtlx-connection") code = "mtlx-connection";
    return code;
}

// A reader's warning as one of the document's (every warning the reader
// gives is mtlx-ignored).
function warningOf(p: MtlxProblem, file: string): Diagnostic {
    return new Diagnostic(Severity.Warning, "mtlx-ignored", file, p.line, p.col, p.message, p.hintText);
}

// The f32 `x` as the f64 its shortest text reads as: 0.85f32 is 0.85.
function f(x: f32): f64 {
    const r = parseF64(displayF32(x));
    return r.ok ? r.value : <f64>x;
}

function at(rd: MtlxRead, key: string): XmlPos {
    if (!rd.positions.has(key)) return new XmlPos(0, 0);
    const p = rd.positions.get(key);
    return new XmlPos(p[0], p[1]);
}

// The PbrMaterial field (MtlxRead.positions' key) a StandardMaterial3D
// property comes from; a switch, its feature's first field that the file
// set, else its texture's.
function positionKey(rd: MtlxRead, name: string): string {
    for (let s = 0; s < MATERIAL_TEXTURE_PROPS.length; s++) {
        const t = MATERIAL_TEXTURE_PROPS[s];
        if (name == t) return "textures[" + s.toString() + "]";
        for (let k = 0; k < MATERIAL_UV_SUFFIXES.length; k++) {
            if (name == t + MATERIAL_UV_SUFFIXES[k]) return "textures[" + s.toString() + "]";
        }
    }
    if (name == "resource_name") return "name";
    if (name == "albedo_color") return "baseColor";
    if (name == "emission" || name == "emission_enabled") return either(rd, "emissive", "textures[5]");
    if (name == "emission_energy_multiplier") return "emissiveStrength";
    if (name == "normal_enabled") return "textures[3]";
    if (name == "normal_scale") return "normalScale";
    if (name == "ao_enabled") return "textures[4]";
    if (name == "ao_strength") return "occlusionStrength";
    if (name == "transparency") return "alphaMode";
    if (name == "alpha_scissor_threshold") return "alphaCutoff";
    if (name == "cull_mode") return either(rd, "doubleSided", "cullFront");
    if (name == "vertex_color_use_as_albedo") return "vertexColorUseAsAlbedo";
    if (name == "vertex_color_is_srgb") return "vertexColorIsSrgb";
    if (name == "billboard_mode") return "billboardMode";
    if (name == "billboard_keep_scale") return "billboardKeepScale";
    if (name == "refraction_scale") return "refractionScale";
    if (name == "shading_mode") return "unlit";
    if (name == "specular_color") return "specularColor";
    if (name == "clearcoat_enabled") return either(rd, "clearcoat", "textures[6]");
    if (name == "clearcoat_roughness") return "clearcoatRoughness";
    if (name == "clearcoat_normal_scale") return "clearcoatNormalScale";
    if (name == "anisotropy_enabled" || name == "anisotropy") return either(rd, "anisotropyStrength", "textures[17]");
    if (name == "anisotropy_rotation") return "anisotropyRotation";
    if (name == "sheen_color") return "sheenColor";
    if (name == "sheen_roughness") return "sheenRoughness";
    if (name == "refraction_enabled") return either(rd, "transmission", "textures[13]");
    if (name == "attenuation_distance") return "attenuationDistance";
    if (name == "attenuation_color") return "attenuationColor";
    if (name == "iridescence_ior") return "iridescenceIor";
    if (name == "iridescence_thickness_minimum") return "iridescenceThicknessMinimum";
    if (name == "iridescence_thickness_maximum") return "iridescenceThicknessMaximum";
    if (name == "backlight_enabled" || name == "diffuse_transmission") return either(rd, "diffuseTransmission", "textures[18]");
    if (name == "backlight") return "diffuseTransmissionColor";
    return name;
}

function either(rd: MtlxRead, a: string, b: string): string {
    return rd.positions.has(a) ? a : b;
}

function vec2(x: f32, y: f32): Value {
    return Value.vector2(f(x), f(y));
}

function colour(r: f32, g: f32, b: f32, a: f32): Value {
    return Value.color(f(r), f(g), f(b), f(a));
}

// The value of StandardMaterial3D property `name` of `m`, its textures
// named by the ExtResource or SubResource values `refs` gives each slot;
// null for a property this function does not know (none: every property
// has one).
function propertyValue(m: StandardMaterial3D, name: string, refs: Array<Value>): Value? {
    for (let s = 0; s < MATERIAL_TEXTURE_PROPS.length; s++) {
        const t = MATERIAL_TEXTURE_PROPS[s];
        if (!name.startsWith(t)) continue;
        const uv = m.uvs[s];
        if (name == t) return m.textureAt(s) != null ? refs[s] : Value.nil();
        if (name == t + "_texcoord") return Value.int(uv.texcoord);
        if (name == t + "_offset") return vec2(uv.offset.x, uv.offset.y);
        if (name == t + "_rotation") return Value.float(f(uv.rotation));
        if (name == t + "_scale") return vec2(uv.scale.x, uv.scale.y);
    }
    if (name == "resource_name") return Value.str(m.name);
    if (name == "albedo_color") return colour(m.albedoColor.x, m.albedoColor.y, m.albedoColor.z, m.albedoColor.w);
    if (name == "metallic") return Value.float(f(m.metallic));
    if (name == "roughness") return Value.float(f(m.roughness));
    if (name == "emission_enabled") return Value.bool(m.emissionEnabled);
    if (name == "emission") return colour(m.emission.x, m.emission.y, m.emission.z, m.emission.w);
    if (name == "emission_energy_multiplier") return Value.float(f(m.emissionEnergy));
    if (name == "normal_enabled") return Value.bool(m.normalEnabled);
    if (name == "normal_scale") return Value.float(f(m.normalScale));
    if (name == "ao_enabled") return Value.bool(m.aoEnabled);
    if (name == "transparency") return Value.int(m.transparency);
    if (name == "alpha_scissor_threshold") return Value.float(f(m.alphaScissorThreshold));
    if (name == "cull_mode") return Value.int(m.cullMode);
    if (name == "vertex_color_use_as_albedo") return Value.bool(m.vertexColorUseAsAlbedo);
    if (name == "vertex_color_is_srgb") return Value.bool(m.vertexColorIsSrgb);
    if (name == "uv1_scale") return Value.vector3(f(m.uv1Scale.x), f(m.uv1Scale.y), f(m.uv1Scale.z));
    if (name == "uv1_offset") return Value.vector3(f(m.uv1Offset.x), f(m.uv1Offset.y), f(m.uv1Offset.z));
    if (name == "shading_mode") return Value.int(m.shadingMode);
    if (name == "ao_strength") return Value.float(f(m.aoStrength));
    if (name == "ior") return Value.float(f(m.ior));
    if (name == "specular") return Value.float(f(m.specular));
    if (name == "specular_color") return colour(m.specularColor.x, m.specularColor.y, m.specularColor.z, m.specularColor.w);
    if (name == "clearcoat_enabled") return Value.bool(m.clearcoatEnabled);
    if (name == "clearcoat") return Value.float(f(m.clearcoat));
    if (name == "clearcoat_roughness") return Value.float(f(m.clearcoatRoughness));
    if (name == "clearcoat_normal_scale") return Value.float(f(m.clearcoatNormalScale));
    if (name == "anisotropy_enabled") return Value.bool(m.anisotropyEnabled);
    if (name == "anisotropy") return Value.float(f(m.anisotropy));
    if (name == "anisotropy_rotation") return Value.float(f(m.anisotropyRotation));
    if (name == "sheen_color") return colour(m.sheenColor.x, m.sheenColor.y, m.sheenColor.z, m.sheenColor.w);
    if (name == "sheen_roughness") return Value.float(f(m.sheenRoughness));
    if (name == "refraction_enabled") return Value.bool(m.refractionEnabled);
    if (name == "transmission") return Value.float(f(m.transmission));
    if (name == "thickness") return Value.float(f(m.thickness));
    if (name == "attenuation_distance") return Value.float(f(m.attenuationDistance));
    if (name == "attenuation_color") {
        return colour(m.attenuationColor.x, m.attenuationColor.y, m.attenuationColor.z, m.attenuationColor.w);
    }
    if (name == "dispersion") return Value.float(f(m.dispersion));
    if (name == "iridescence") return Value.float(f(m.iridescence));
    if (name == "iridescence_ior") return Value.float(f(m.iridescenceIor));
    if (name == "iridescence_thickness_minimum") return Value.float(f(m.iridescenceThicknessMinimum));
    if (name == "iridescence_thickness_maximum") return Value.float(f(m.iridescenceThicknessMaximum));
    if (name == "backlight_enabled") return Value.bool(m.backlightEnabled);
    if (name == "diffuse_transmission") return Value.float(f(m.diffuseTransmission));
    if (name == "backlight") return colour(m.backlight.x, m.backlight.y, m.backlight.z, m.backlight.w);
    if (name == "billboard_mode") return Value.int(m.billboardMode);
    if (name == "billboard_keep_scale") return Value.bool(m.billboardKeepScale);
    if (name == "refraction_scale") return Value.float(f(m.refractionScale));
    return null;
}

// The material `p` (read from `rd`'s file, or made in code with `rd`
// null) as a material document named `file`.
export function materialDocOfPbr(p: PbrMaterial, file: string, rd: MtlxRead? = null): RscnDoc {
    const doc = new RscnDoc(file, DocKind.Material);
    const read = rd != null ? rd : new MtlxRead(p);
    doc.pos = at(read, "document");
    // One ext_resource per texture path (an image's Texture2D, a Rive
    // file's RiveFile), in slot order, then one ArtboardTexture
    // sub_resource per distinct artboard texture: what each slot names.
    const refs = new Array<Value>();
    const byPath = new Map<string, string>();
    const byArtboard = new Map<string, string>();
    const subs = new Array<SubResourceDecl>();
    const m = standardFromPbr(p);
    // (milestone 35: the billboard the file carries beside the PbrMaterial)
    m.billboardMode = read.billboard.mode;
    m.billboardKeepScale = read.billboard.keepScale;
    // (milestone 62: its refraction_scale, carried the same way)
    m.refractionScale = read.billboard.refractionScale;
    for (let s = 0; s < PBR_SLOT_COUNT; s++) {
        const t = p.texture(s);
        if (t == null) {
            refs.push(Value.nil());
            continue;
        }
        const a = t.artboard;
        const type = a != null ? "RiveFile" : "Texture2D";
        const where = at(read, "textures[" + s.toString() + "]");
        const pathKey = type + ":" + t.path;
        let ext = "";
        if (byPath.has(pathKey)) {
            ext = byPath.get(pathKey);
        } else {
            ext = "tex_" + s.toString();
            byPath.set(pathKey, ext);
            const decl = new ExtResourceDecl(ext, type, t.path);
            decl.pos = where;
            const pa = new XmlAttr("path", t.path);
            pa.pos = where;
            pa.valuePos = where;
            decl.attrs.push(pa);
            doc.addExtResource(decl);
        }
        if (a == null) {
            refs.push(Value.extResource(ext));
            continue;
        }
        const key = artboardKey(t, a);
        if (byArtboard.has(key)) {
            refs.push(Value.subResource(byArtboard.get(key)));
            continue;
        }
        const id = "art_" + s.toString();
        byArtboard.set(key, id);
        refs.push(Value.subResource(id));
        subs.push(artboardDecl(id, ext, a, read, s));
    }
    for (let k = 0; k < subs.length; k++) doc.addSubResource(subs[k]);
    const decl = new SubResourceDecl("", MATERIAL_CLASS);
    decl.pos = at(read, "material");
    const props = allProps(MATERIAL_CLASS);
    for (let k = 0; k < props.length; k++) {
        const info = props[k];
        const v = propertyValue(m, info.name, refs);
        if (v == null || v.equals(info.def)) continue;
        const prop = new Property(info.name, v);
        const where = at(read, positionKey(read, info.name));
        prop.pos = where;
        prop.valuePos = where;
        decl.items.push(BodyItem.ofProperty(prop));
    }
    doc.setResource(decl);
    return doc;
}

// What makes two slots' artboard textures one: the file, the artboard,
// the state machine and the size.
function artboardKey(t: PbrTexture, a: PbrArtboard): string {
    return t.path + "\n" + a.artboard + "\n" + a.stateMachine + "\n" + a.width.toString() + "x" + a.height.toString()
        + "\n" + a.updateMode.toString() + "@" + a.updateFps.toString();
}

// The ArtboardTexture sub_resource `id` of artboard `a` of the RiveFile
// ext_resource `ext` (slot `slot`'s first), its properties at the
// attributes' positions.
function artboardDecl(id: string, ext: string, a: PbrArtboard, read: MtlxRead, slot: i32): SubResourceDecl {
    const key = "textures[" + slot.toString() + "]";
    const d = new SubResourceDecl(id, "ArtboardTexture");
    const named = either(read, key + ".artboard", key);
    d.pos = at(read, named);
    artboardProp(d, "file", Value.extResource(ext), at(read, key));
    artboardProp(d, "artboard", Value.str(a.artboard), at(read, named));
    if (a.stateMachine.length > 0) artboardProp(d, "state_machine", Value.str(a.stateMachine), at(read, either(read, key + ".stateMachine", named)));
    if (a.width > 0 && a.height > 0) {
        artboardProp(d, "size", Value.numbers(ValueKind.Vector2i, [<f64>a.width, <f64>a.height]), at(read, either(read, key + ".size", named)));
    }
    // (milestone 67: when the file sets them)
    if (a.updateMode != PBR_ARTBOARD_WHEN_VISIBLE) {
        artboardProp(d, "render_target_update_mode", Value.int(a.updateMode), at(read, either(read, key + ".updateMode", named)));
    }
    if (a.updateFps > 0) {
        artboardProp(d, "update_fps", Value.float(<f64>a.updateFps), at(read, either(read, key + ".updateFps", named)));
    }
    return d;
}

function artboardProp(d: SubResourceDecl, name: string, v: Value, where: XmlPos): void {
    const prop = new Property(name, v);
    prop.pos = where;
    prop.valuePos = where;
    d.items.push(BodyItem.ofProperty(prop));
}

// The .mtlx file `file` (its display path; `text` its contents) as a
// material document. Errors: the reader's (mtlx.as MtlxProblem, as a
// SceneryError of the same code at file:line:col with its hint); the
// reader's warnings become the document's own (RscnDoc.warnings, which the
// validator reports with its own), and what they name is RscnDoc.dropped.
export function materialDocFromMtlx(text: string, file: string): Result<RscnDoc> {
    const r = readMtlx(text, file);
    if (!r.ok) {
        const c = r.cause;
        if (c != null && c instanceof MtlxProblem) {
            const p = c as MtlxProblem;
            return SceneryError.at(sceneryCode(p.code), file, p.line, p.col, p.message, p.hintText).fail<RscnDoc>();
        }
        return SceneryError.at("mtlx-xml", file, 0, 0, r.err).fail<RscnDoc>();
    }
    const rd = r.value;
    const doc = materialDocOfPbr(rd.material, file, rd);
    for (let k = 0; k < rd.warnings.length; k++) doc.warnings.push(warningOf(rd.warnings[k], file));
    doc.dropped = rd.dropped();
    return Result.okv<RscnDoc>(doc);
}

// The StandardMaterial3D a material document declares, built without
// loading anything: each Texture2D ext_resource is a Texture2D holding only
// its path, as written, each RiveFile one a RiveFile holding only its path
// (not read), and each ArtboardTexture sub_resource an ArtboardTexture of
// its properties (without its placeholder: nothing draws it). A property
// naming an id the document does not declare is left out (the caller
// validated the document; this only keeps a document edited in code from
// failing to write).
export function standardOfMaterialDoc(doc: RscnDoc): StandardMaterial3D {
    const res = new DocResources(doc);
    const exts = doc.extResources();
    for (let k = 0; k < exts.length; k++) {
        const type = exts[k].type;
        if (type == "Texture2D") {
            const t = new Texture2D();
            t.path = exts[k].path;
            t.file = exts[k].path;
            res.ext.set(exts[k].id, t);
        } else if (type == "RiveFile") {
            const f = new RiveFile();
            f.path = exts[k].path;
            f.file = exts[k].path;
            res.ext.set(exts[k].id, f);
        }
    }
    const subs = doc.subResources();
    for (let k = 0; k < subs.length; k++) {
        if (subs[k].type == "ArtboardTexture") res.sub.set(subs[k].id, artboardOfDecl(subs[k], res));
    }
    const decl = doc.resource();
    if (decl == null || decl.type != MATERIAL_CLASS) return new StandardMaterial3D();
    let use: SubResourceDecl = decl!;
    const props = use.properties();
    for (let k = 0; k < props.length; k++) {
        const v = props[k].value;
        if ((v.kind == ValueKind.ExtResource || v.kind == ValueKind.SubResource) && res.get(v) == null) {
            use = withoutUnresolved(use, res);
            break;
        }
    }
    const b = buildSubResource(use, res);
    if (!b.ok) return new StandardMaterial3D();
    const made: Resource = b.value;
    return made instanceof StandardMaterial3D ? made as StandardMaterial3D : new StandardMaterial3D();
}

// An ArtboardTexture sub_resource's fields (a value of the wrong kind
// passed over, as build.as does): what the writer needs of it.
function artboardOfDecl(d: SubResourceDecl, res: DocResources): ArtboardTexture {
    const t = new ArtboardTexture();
    t.id = d.id;
    const file = d.property("file");
    if (file != null) {
        const f = res.get(file.value);
        const isRive = f != null && f instanceof RiveFile;
        if (isRive) t.rive = f as RiveFile;
    }
    const name = d.property("artboard");
    if (name != null && name.value.kind == ValueKind.String) t.artboard = name.value.s;
    const sm = d.property("state_machine");
    if (sm != null && sm.value.kind == ValueKind.String) t.stateMachine = sm.value.s;
    const size = d.property("size");
    if (size != null && size.value.kind == ValueKind.Vector2i) {
        t.sizeX = f64ToI32(size.value.n[0]);
        t.sizeY = f64ToI32(size.value.n[1]);
    }
    const mode = d.property("render_target_update_mode");
    if (mode != null && mode.value.kind == ValueKind.Int && mode.value.asI32() != t.updateMode) t.updateMode = mode.value.asI32();
    const fps = d.property("update_fps");
    if (fps != null && fps.value.isNumber()) t.updateFps = fps.value.asF32();
    return t;
}

function withoutUnresolved(decl: SubResourceDecl, res: DocResources): SubResourceDecl {
    const out = new SubResourceDecl("", decl.type);
    const props = decl.properties();
    for (let k = 0; k < props.length; k++) {
        const v = props[k].value;
        if ((v.kind == ValueKind.ExtResource || v.kind == ValueKind.SubResource) && res.get(v) == null) continue;
        out.setProperty(props[k].name, v);
    }
    return out;
}

// A material document as canonical MaterialX text. The document is valid
// (the caller validated it); every StandardMaterial3D property has a place
// in the profile, but a feature switched off (clearcoat_enabled false, ...)
// writes none of its values, and uv1_scale and uv1_offset are folded into
// the textures' transforms (pbr_map.as): the file reads back as the
// material it draws. The material's name is resource_name made a MaterialX
// identifier (mtlx_write.as mtlxIdentifier).
export function mtlxFromMaterialDoc(doc: RscnDoc): string {
    const m = standardOfMaterialDoc(doc);
    // (milestone 35: the billboard, which a PbrMaterial has no field for)
    const bb = new MtlxBillboard();
    bb.mode = m.billboardMode;
    bb.keepScale = m.billboardKeepScale;
    bb.refractionScale = m.refractionScale;
    return writeMtlx(pbrFromStandard(m), bb);
}
