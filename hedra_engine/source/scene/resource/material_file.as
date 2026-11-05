// Materials that stand on their own (milestone 14): a material file named
// by an ext_resource of type Material. The format is MaterialX (.mtlx,
// docs/formats/MATERIALS.md: one gltf_pbr material), read into a material
// document (mtlx_doc.as). The loader reads one through here
// (ResourceLoader.load("Material", abs)): the file is read as an RscnDoc of
// kind DocKind.Material (parseMaterialFile) and validated
// (../rscn/validate.as validateMaterialDoc; its warnings, the reader's
// mtlx-ignored among them, go to the loader's diagnostics, its
// first error fails the load), its ext_resources are loaded through the
// same loader (a texture named by a path relative to the file resolves from
// the file's directory, as any file's does), and its <resource> is built as
// a sub_resource of its class would be (build.as buildSubResource), so a
// StandardMaterial3D read from a material file is the object a sub_resource
// of the same properties gives, with `path` the file's absolute path and
// `file` its display path.
//
// Milestone 15: a slot drawn from a Rive artboard is, in the document, a
// RiveFile ext_resource and an ArtboardTexture sub_resource (mtlx_doc.as):
// the RiveFile loads through the same loader (its path resolved as a
// texture's is; a file that cannot be read fails the material as a
// missing image does, with the same code at the same place), and the
// texture is finished with its slot's property as its key, so that its
// path is "<file>#artboard:albedo_texture" (artboard_texture.as
// artboardTexturePath), whatever its sub_resource's id.
//
// The scene editor (editor/src/scene/edit) edits material documents and
// builds the material again from the edited document (buildMaterialDoc)
// without the file being read; it builds a scene's sub_resource material for
// its preview the same way (buildDocSubResource). Milestone 39: those two
// live in material_build.as (re-exported here), which the run
// time builds its bundle's materials with without this file's MaterialX.

import { Result, toAsciiLowercase } from "../../../base/util";
import { vfs } from "../../../fs/vfs";
import { SceneryError } from "../../../scene/error";
import { DocKind, RscnDoc, SubResourceDecl } from "../../../scene/rscn/doc";
import { validateMaterialDoc } from "../../../scene/rscn/validate";
import { Resource } from "../../../scene/resource/types";
import { ResourceLoader } from "../../../scene/resource/loader";
import { FILE_READ_HINT } from "../../../scene/resource/model_hints";
import { buildMaterialDoc } from "../../../scene/resource/material_build";
import { materialDocFromMtlx, mtlxFromMaterialDoc } from "./mtlx_doc";
// (built apart, so that the run time carries no MaterialX reader)
export { MATERIAL_HINT, buildDocSubResource, buildMaterialDoc } from "../../../scene/resource/material_build";

// The material file format is MaterialX (docs/formats/MATERIALS.md), read
// into a material document (mtlx_doc.as), so everything below and every
// caller works on RscnDoc as a scene's code does. The functions below are
// where a material file's text is read and written: every caller (the
// loader, inspect, format, render, prefetch, the editor) goes through them.

// The extension of a material file, lower case, without the dot.
export const MATERIAL_FILE_EXTENSION = "mtlx";

// `path` names a material file (by its extension, any case).
export function isMaterialFilePath(path: string): bool {
    const n = path.length;
    return n >= 5 && toAsciiLowercase(path.substring(n - 5)) == ".mtlx";
}

// The material file `file` (how errors name it) read as a material
// document; not validated (validateMaterialDoc does).
export function parseMaterialFile(bytes: Uint8Array, file: string): Result<RscnDoc> {
    return materialDocFromMtlx(String.UTF8.decode(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)), file);
}

// What a prefetch or a closure needs of a material file: its
// ext_resources (the textures it names). An .mtlx is read whole (it is
// small, and its textures are inside its nodes).
export function parseMaterialFileHead(bytes: Uint8Array, file: string): Result<RscnDoc> {
    return parseMaterialFile(bytes, file);
}

// parseMaterialFile of text.
export function parseMaterialFileText(text: string, file: string): Result<RscnDoc> {
    return materialDocFromMtlx(text, file);
}

// A material document as its file's canonical text (the CLI's `format` and
// the editor's saves). A document holding no StandardMaterial3D (milestone
// 61: a ShaderMaterial, which materialFileProblem refuses first) writes the
// default material.
export function writeMaterialFile(doc: RscnDoc): string {
    return mtlxFromMaterialDoc(doc);
}

// Milestone 61: the code of a material that cannot be a material file: a
// ShaderMaterial (its shader is a .wgsl file a scene names, and its
// parameters are that shader's uniforms: MaterialX's gltf_pbr has neither).
export const MATERIAL_FILE_SHADER_CODE = "material-file-shader";

// Why a material of class `type` declared in `file` cannot be written as a
// material file (Extract Material to File, `hedra convert`), or null when
// it can: what every writer of a material file asks first.
export function materialFileProblem(type: string, file: string): SceneryError? {
    if (type == "ShaderMaterial") {
        return SceneryError.at(MATERIAL_FILE_SHADER_CODE, file, 0, 0,
            "a ShaderMaterial cannot be a material file: MaterialX holds a gltf_pbr material, not a shader and its parameters",
            "keep it in the scene (its shader is the .wgsl file it names), or make its fallback a material file and set that on "
                + "the meshes that need no shader");
    }
    return null;
}

// The class a new material holds, and the only concrete Material of format 1.
export const MATERIAL_DEFAULT_TYPE = "StandardMaterial3D";

// The material file at `abs` (`display` its display path) read, validated and
// built: what ResourceLoader.load("Material", abs) caches. Errors: the
// file cannot be read (`file-read`), does not parse (the reader's codes),
// is invalid (the validator's first error), or its resource is of a type
// this version does not build (`resource-type-unknown` becomes an error
// here: a material that cannot be drawn cannot be used). The validator's
// warnings go to the loader's diagnostics, as a scene's do.
export function readMaterialFile(loader: ResourceLoader, abs: string, display: string): Result<Resource> {
    const bytes = vfs.read(abs);
    if (!bytes.ok) {
        return SceneryError.at("file-read", display, 0, 0, "cannot read " + display + ": " + bytes.err, FILE_READ_HINT).fail<Resource>();
    }
    const parsed = parseMaterialFile(bytes.value, display);
    if (!parsed.ok) return parsed.forward<Resource>();
    const doc = parsed.value;
    const found = validateMaterialDoc(doc);
    // The warning that stops a load here is the error below, not a warning
    // as well.
    for (let i = 0; i < found.items.length; i++) {
        if (found.items[i].code != "resource-type-unknown") loader.diagnostics.add(found.items[i]);
    }
    const first = found.firstError();
    if (first != null) return first.toError().fail<Resource>();
    const m = buildMaterialDoc(doc, abs, loader);
    if (!m.ok) return m.forward<Resource>();
    return Result.okv<Resource>(m.value);
}

// A new material document (`file` how errors name it) holding one empty
// <resource type="`type`">: what the editor's Save As writes before it
// copies a material's properties in.
export function newMaterialDoc(file: string, type: string = MATERIAL_DEFAULT_TYPE): RscnDoc {
    const doc = new RscnDoc(file, DocKind.Material);
    doc.setResource(new SubResourceDecl("", type));
    return doc;
}
