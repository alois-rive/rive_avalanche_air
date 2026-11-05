// A glTF material, whole, as a PbrMaterial (engine/src/material/pbr.as):
// the core metallic-roughness model with normalTexture.scale and
// occlusionTexture.strength, each texture's texCoord and
// KHR_texture_transform, and every material extension Khronos has
// published (milestone 14). The importer (gltf_import.as) calls it for each
// material when ImportOpts.pbr is on; Hedra never sets it, so Hedra's
// import reads exactly what it read before.
//
// The extensions come from the material's `extensions` JSON, which the
// reader keeps whole for every extension it has no type for
// (Extensions.others, engine/src/source/io/gltf/doc.as); only
// KHR_materials_emissive_strength has a type there. A value of the wrong
// type, or a texture index past the file's textures, is a warning and the
// default is kept: a viewer draws such a file as well as it can, and so does
// this.
//
// Colours become sRGB with linearToSrgbValue (glTF's factors are linear,
// PbrMaterial's sRGB; alpha stays linear), the same conversion the core
// importer applies, so a colour reads the same through either.
//
// Checked against the Khronos registry (github.com/KhronosGroup/glTF,
// extensions/README.md) on 2026-10-01: the ratified material extensions are
// anisotropy, clearcoat, dispersion, emissive_strength, ior, iridescence,
// sheen, specular, transmission, unlit, variants and volume; variants
// switches whole materials and carries no property, so it is not read.
// diffuse_transmission is a release candidate there, read because its
// definition is final in all but name.

import { Result } from "../../../base/util";
import { linearToSrgbValue } from "../../../base/color";
import { JsonMap, JsonValue } from "../../../base/json";
import {
    PBR_ALPHA_BLEND, PBR_ALPHA_MASK, PBR_ALPHA_OPAQUE, PbrMaterial, PbrSlot, PbrTexture,
} from "../../../material/pbr";
import {
    Root, Material as GltfMaterial, AlphaMode as GltfAlphaMode, Extensions,
} from "../gltf/doc";

// The extensions a reader of PbrMaterial understands: a file that requires
// one of them is read when the import is asked for PbrMaterials (Hedra
// passes this list as ImportOpts.extensions).
export const PBR_EXTENSIONS: Array<string> = [
    "KHR_materials_emissive_strength",
    "KHR_materials_ior",
    "KHR_materials_specular",
    "KHR_materials_transmission",
    "KHR_materials_volume",
    "KHR_materials_clearcoat",
    "KHR_materials_sheen",
    "KHR_materials_iridescence",
    "KHR_materials_anisotropy",
    "KHR_materials_dispersion",
    "KHR_materials_diffuse_transmission",
    "KHR_materials_unlit",
    "KHR_texture_transform",
];

// How a texture index of the file becomes a PbrTexture path: the importer
// resolves it as it resolves the core textures (a file next to the glTF,
// or an embedded image through its ImageSink), so both carry one path.
export abstract class PbrImages {
    // The path for texture `texture` (already known to be in range), or
    // null when its image could not be read (the importer has warned).
    abstract pathOf(texture: i32, material: string, warnings: Array<string>): Result<string?>;
}

// Reads one material; `name` is the name the scene gave it (unique).
class Reader {
    document: Root;
    images: PbrImages;
    name: string;
    warnings: Array<string>;
    // The first image the importer could not keep (its ImageSink failed).
    failed: Result<string?>? = null;

    constructor(document: Root, images: PbrImages, name: string, warnings: Array<string>) {
        this.document = document;
        this.images = images;
        this.name = name;
        this.warnings = warnings;
    }

    warn(where: string, what: string): void {
        this.warnings.push("material '" + this.name + "': " + where + " " + what);
    }

    // A number of `obj`, or `def` when absent (or not a number: warned).
    num(obj: JsonMap, key: string, def: f32, where: string): f32 {
        const v = obj.get(key);
        if (v == null) return def;
        if (!v.isNumber()) {
            this.warn(where + "." + key, "is not a number; the default is kept");
            return def;
        }
        return <f32>v.asF64();
    }

    // A list of `n` numbers, or `def`.
    nums(obj: JsonMap, key: string, def: StaticArray<f32>, where: string): StaticArray<f32> {
        const v = obj.get(key);
        if (v == null) return def;
        const a = v.asArray();
        let ok = a != null && a.length == def.length;
        if (a != null && ok) {
            for (let i = 0; i < a.length; i++) if (!a[i].isNumber()) ok = false;
        }
        if (a == null || !ok) {
            this.warn(where + "." + key, "is not a list of " + def.length.toString() + " numbers; the default is kept");
            return def;
        }
        const out = new StaticArray<f32>(def.length);
        for (let i = 0; i < a.length; i++) out[i] = <f32>a[i].asF64();
        return out;
    }

    // A linear colour factor as sRGB.
    colour(obj: JsonMap, key: string, def: StaticArray<f32>, where: string): StaticArray<f32> {
        const c = this.nums(obj, key, def, where);
        return [linearToSrgbValue(c[0]), linearToSrgbValue(c[1]), linearToSrgbValue(c[2])];
    }

    // An extension's object, or null when the material has none (or it
    // is not an object: warned).
    ext(others: JsonMap?, name: string): JsonMap? {
        if (others == null) return null;
        const v = others.get(name);
        if (v == null) return null;
        const o = v.asObject();
        if (o == null) this.warn(name, "is not an object; ignored");
        return o;
    }

    // A texture: its path, the texCoord and KHR_texture_transform of the
    // texture info. null when the index is out of range or the image could
    // not be read.
    texture(index: i64, texCoord: i64, extensions: JsonMap?, where: string): PbrTexture? {
        if (index < 0 || index >= <i64>this.document.textures.length) {
            this.warn(where, "names texture " + index.toString() + " of " + this.document.textures.length.toString() + "; left out");
            return null;
        }
        const p = this.images.pathOf(<i32>index, this.name, this.warnings);
        if (!p.ok) {
            if (this.failed == null) this.failed = p;
            return null;
        }
        const path = p.value;
        if (path == null) return null;
        const t = new PbrTexture(path);
        t.texCoord = <i32>texCoord;
        const tt = this.ext(extensions, "KHR_texture_transform");
        if (tt != null) {
            const at = where + ".KHR_texture_transform";
            t.offset = this.nums(tt, "offset", [0, 0], at);
            t.rotation = this.num(tt, "rotation", 0, at);
            t.scale = this.nums(tt, "scale", [1, 1], at);
            // The transform's own texCoord overrides the texture info's.
            const tc = tt.get("texCoord");
            if (tc != null) {
                if (tc.isU64()) t.texCoord = <i32>tc.asU64();
                else this.warn(at + ".texCoord", "is not a set number; the texture info's is kept");
            }
        }
        return t;
    }

    // A texture info written in an extension's JSON (`{index, texCoord,
    // extensions}`; a normal texture's `scale` is read by its caller). null
    // when absent.
    jsonTexture(obj: JsonMap, key: string, where: string): PbrTexture? {
        const v = obj.get(key);
        if (v == null) return null;
        const at = where + "." + key;
        const info = v.asObject();
        const index = info != null ? info.get("index") : null;
        if (info == null || index == null || !index.isU64()) {
            this.warn(at, "is not a texture info with an index; left out");
            return null;
        }
        let texCoord: i64 = 0;
        const tc = info.get("texCoord");
        if (tc != null) {
            if (tc.isU64()) texCoord = <i64>tc.asU64();
            else this.warn(at + ".texCoord", "is not a set number; set 0 is used");
        }
        const e = info.get("extensions");
        return this.texture(<i64>index.asU64(), texCoord, e != null ? e.asObject() : null, at);
    }

    // A texture info of the core material (typed by the reader).
    coreTexture(index: i32, texCoord: u32, extensions: Extensions?, where: string): PbrTexture? {
        return this.texture(<i64>index, <i64>texCoord, extensions != null ? extensions.others : null, where);
    }
}

function setTex(m: PbrMaterial, slot: i32, t: PbrTexture?): void {
    if (t != null) m.setTexture(slot, t);
}

// glTF material `m` (of `document`) as a PbrMaterial named `name`.
// Warnings (bad values, textures that are not there) go to `warnings`; an
// error is an image the importer could not keep (its ImageSink failed).
export function pbrFromGltf(document: Root, m: GltfMaterial, name: string, images: PbrImages, warnings: Array<string>): Result<PbrMaterial> {
    const r = new Reader(document, images, name, warnings);
    const p = new PbrMaterial(name);
    const pbr = m.pbrMetallicRoughness;
    const f = pbr.baseColorFactor;
    p.baseColor = [linearToSrgbValue(f[0]), linearToSrgbValue(f[1]), linearToSrgbValue(f[2]), f[3]];
    p.metallic = pbr.metallicFactor;
    p.roughness = pbr.roughnessFactor;
    const ef = m.emissiveFactor;
    p.emissive = [linearToSrgbValue(ef[0]), linearToSrgbValue(ef[1]), linearToSrgbValue(ef[2])];
    p.alphaMode = m.alphaMode == GltfAlphaMode.Blend ? PBR_ALPHA_BLEND : m.alphaMode == GltfAlphaMode.Mask ? PBR_ALPHA_MASK : PBR_ALPHA_OPAQUE;
    p.alphaCutoff = isNaN(m.alphaCutoff) ? <f32>0.5 : m.alphaCutoff;
    p.doubleSided = m.doubleSided;

    // The core textures, in the order the core importer resolves them, so
    // that an image is named the same whichever asked for it first.
    const bc = pbr.baseColorTexture;
    if (bc != null) setTex(p, PbrSlot.BaseColor, r.coreTexture(bc.index, bc.texCoord, bc.extensions, "baseColorTexture"));
    const nt = m.normalTexture;
    if (nt != null) {
        setTex(p, PbrSlot.Normal, r.coreTexture(nt.index, nt.texCoord, nt.extensions, "normalTexture"));
        p.normalScale = nt.scale;
    }
    const mr = pbr.metallicRoughnessTexture;
    if (mr != null) {
        // One image, two slots (pbr.as): metallic is its blue channel,
        // roughness its green.
        const t = r.coreTexture(mr.index, mr.texCoord, mr.extensions, "metallicRoughnessTexture");
        if (t != null) {
            p.setTexture(PbrSlot.Metallic, t);
            p.setTexture(PbrSlot.Roughness, t.clone());
        }
    }
    const et = m.emissiveTexture;
    if (et != null) setTex(p, PbrSlot.Emissive, r.coreTexture(et.index, et.texCoord, et.extensions, "emissiveTexture"));
    const ot = m.occlusionTexture;
    if (ot != null) {
        setTex(p, PbrSlot.Occlusion, r.coreTexture(ot.index, ot.texCoord, ot.extensions, "occlusionTexture"));
        p.occlusionStrength = ot.strength;
    }

    const exts = m.extensions;
    const others: JsonMap? = exts != null ? exts.others : null;
    if (exts != null) {
        const es = exts.emissiveStrength;
        if (es != null) p.emissiveStrength = es.emissiveStrength;
    }
    if (others != null && others.get("KHR_materials_unlit") != null) p.unlit = true;

    let e = r.ext(others, "KHR_materials_ior");
    if (e != null) p.ior = r.num(e, "ior", 1.5, "KHR_materials_ior");

    e = r.ext(others, "KHR_materials_specular");
    if (e != null) {
        const at = "KHR_materials_specular";
        p.specular = r.num(e, "specularFactor", 1, at);
        setTex(p, PbrSlot.Specular, r.jsonTexture(e, "specularTexture", at));
        p.specularColor = r.colour(e, "specularColorFactor", [1, 1, 1], at);
        setTex(p, PbrSlot.SpecularColor, r.jsonTexture(e, "specularColorTexture", at));
    }

    e = r.ext(others, "KHR_materials_transmission");
    if (e != null) {
        const at = "KHR_materials_transmission";
        p.transmission = r.num(e, "transmissionFactor", 0, at);
        setTex(p, PbrSlot.Transmission, r.jsonTexture(e, "transmissionTexture", at));
    }

    e = r.ext(others, "KHR_materials_volume");
    if (e != null) {
        const at = "KHR_materials_volume";
        p.thickness = r.num(e, "thicknessFactor", 0, at);
        setTex(p, PbrSlot.Thickness, r.jsonTexture(e, "thicknessTexture", at));
        // Absent is glTF's +infinity, which PbrMaterial writes as 0.
        p.attenuationDistance = r.num(e, "attenuationDistance", 0, at);
        p.attenuationColor = r.colour(e, "attenuationColor", [1, 1, 1], at);
    }

    e = r.ext(others, "KHR_materials_clearcoat");
    if (e != null) {
        const at = "KHR_materials_clearcoat";
        p.clearcoat = r.num(e, "clearcoatFactor", 0, at);
        setTex(p, PbrSlot.Clearcoat, r.jsonTexture(e, "clearcoatTexture", at));
        p.clearcoatRoughness = r.num(e, "clearcoatRoughnessFactor", 0, at);
        setTex(p, PbrSlot.ClearcoatRoughness, r.jsonTexture(e, "clearcoatRoughnessTexture", at));
        const cn = r.jsonTexture(e, "clearcoatNormalTexture", at);
        if (cn != null) {
            p.setTexture(PbrSlot.ClearcoatNormal, cn);
            const info = (e.get("clearcoatNormalTexture") as JsonValue).asObject() as JsonMap;
            p.clearcoatNormalScale = r.num(info, "scale", 1, at + ".clearcoatNormalTexture");
        }
    }

    e = r.ext(others, "KHR_materials_sheen");
    if (e != null) {
        const at = "KHR_materials_sheen";
        p.sheenColor = r.colour(e, "sheenColorFactor", [0, 0, 0], at);
        setTex(p, PbrSlot.SheenColor, r.jsonTexture(e, "sheenColorTexture", at));
        p.sheenRoughness = r.num(e, "sheenRoughnessFactor", 0, at);
        setTex(p, PbrSlot.SheenRoughness, r.jsonTexture(e, "sheenRoughnessTexture", at));
    }

    e = r.ext(others, "KHR_materials_iridescence");
    if (e != null) {
        const at = "KHR_materials_iridescence";
        p.iridescence = r.num(e, "iridescenceFactor", 0, at);
        setTex(p, PbrSlot.Iridescence, r.jsonTexture(e, "iridescenceTexture", at));
        p.iridescenceIor = r.num(e, "iridescenceIor", 1.3, at);
        p.iridescenceThicknessMinimum = r.num(e, "iridescenceThicknessMinimum", 100, at);
        p.iridescenceThicknessMaximum = r.num(e, "iridescenceThicknessMaximum", 400, at);
        setTex(p, PbrSlot.IridescenceThickness, r.jsonTexture(e, "iridescenceThicknessTexture", at));
    }

    e = r.ext(others, "KHR_materials_anisotropy");
    if (e != null) {
        const at = "KHR_materials_anisotropy";
        p.anisotropyStrength = r.num(e, "anisotropyStrength", 0, at);
        p.anisotropyRotation = r.num(e, "anisotropyRotation", 0, at);
        setTex(p, PbrSlot.Anisotropy, r.jsonTexture(e, "anisotropyTexture", at));
    }

    e = r.ext(others, "KHR_materials_dispersion");
    if (e != null) p.dispersion = r.num(e, "dispersion", 0, "KHR_materials_dispersion");

    e = r.ext(others, "KHR_materials_diffuse_transmission");
    if (e != null) {
        const at = "KHR_materials_diffuse_transmission";
        p.diffuseTransmission = r.num(e, "diffuseTransmissionFactor", 0, at);
        setTex(p, PbrSlot.DiffuseTransmission, r.jsonTexture(e, "diffuseTransmissionTexture", at));
        p.diffuseTransmissionColor = r.colour(e, "diffuseTransmissionColorFactor", [1, 1, 1], at);
        setTex(p, PbrSlot.DiffuseTransmissionColor, r.jsonTexture(e, "diffuseTransmissionColorTexture", at));
    }

    const failed = r.failed;
    if (failed != null) return failed.forward<PbrMaterial>();
    return Result.okv<PbrMaterial>(p);
}
