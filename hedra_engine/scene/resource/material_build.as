// A material document built into its material (milestone 14), apart from
// the material file's text (material_file.as, which re-exports all of
// this): the loader builds a material file it read through here, a
// built scene's asset container a material document it stored
// (../bundle/provider.as), and the scene editor an edited document. Kept
// apart so that the run time, which never reads a MaterialX file, does not
// carry the MaterialX reader and writer (mtlx_doc.as) in its module
// (docs/cli/BUILD.md section 18, "The run time").

import { Result } from "../../base/util";
import { SceneryError } from "../error";
import { classInfo } from "../classdb";
import { RscnDoc } from "../rscn/doc";
import { isMaterialClass, materialClassNames } from "../rscn/validate";
import { ArtboardTexture, Resource, StandardMaterial3D } from "./types";
import { artboardTexturePath, finishArtboardTexture } from "./artboard_texture";
import { slotProperty } from "./pbr_map";
import { PBR_SLOT_COUNT } from "../../material/pbr";
import { ResourceLoader } from "./loader";
import { buildSubResource, resolveResources, usedBy } from "./build";

// The hint of every material document that does not hold a material.
export const MATERIAL_HINT = "a material file is MaterialX holding one gltf_pbr material (docs/formats/MATERIALS.md)";

// The material of a material document (the file at `abs`: its relative paths
// resolve from there; "" for one built in code, whose relative paths start
// at the project root), its ext_resources loaded through `loader`. The
// document is not validated here (the caller did), but a document that
// holds no material fails: no <resource> (`resource-missing`), or one of a
// class that is no material (`resource-type-invalid`) or unknown
// (`resource-type-unknown`). The result's `path` is `abs` and `file`
// loader.displayPath(abs) (the document's own name for one built in code).
export function buildMaterialDoc(doc: RscnDoc, abs: string, loader: ResourceLoader): Result<StandardMaterial3D> {
    const file = doc.file;
    const decl = doc.resource();
    if (decl == null) {
        return SceneryError.at("resource-missing", file, doc.pos.line, doc.pos.col, "the material file has no <resource>", MATERIAL_HINT)
            .fail<StandardMaterial3D>();
    }
    const at = decl.attrPos("type");
    const classes = materialClassNames().join(", ");
    if (classInfo(decl.type) == null) {
        return SceneryError.at("resource-type-unknown", file, at.line, at.col,
            "unknown resource type \"" + decl.type + "\": the material cannot be drawn",
            "the material classes are " + classes).fail<StandardMaterial3D>();
    }
    if (!isMaterialClass(decl.type)) {
        return SceneryError.at("resource-type-invalid", file, at.line, at.col, decl.type + " is not a material a file can hold", MATERIAL_HINT)
            .fail<StandardMaterial3D>();
    }
    const res = resolveResources(doc, abs, loader);
    if (!res.ok) return res.forward<StandardMaterial3D>();
    const b = buildSubResource(decl, res.value);
    if (!b.ok) return b.forward<StandardMaterial3D>();
    const made = b.value;
    made.id = "";
    made.path = abs;
    made.file = abs.length > 0 ? loader.displayPath(abs) : file;
    const m = made as StandardMaterial3D;
    keyArtboardsBySlot(m, abs);
    return Result.okv<StandardMaterial3D>(m);
}

// Each ArtboardTexture of `m` (the material file at `abs`) finished again
// with the property of the first slot holding it as its key (the builder
// keyed it by its sub_resource id, which the file does not have: the
// document makes it up). A texture two slots share is finished once.
function keyArtboardsBySlot(m: StandardMaterial3D, abs: string): void {
    for (let s = 0; s < PBR_SLOT_COUNT; s++) {
        const t = m.textureAt(s);
        if (t == null) continue;
        const isArtboard = t instanceof ArtboardTexture;
        if (!isArtboard) continue;
        const a = t as ArtboardTexture;
        if (a.path != artboardTexturePath(abs, a.id)) continue;
        finishArtboardTexture(a, abs, slotProperty(s));
    }
}

// The sub_resource `id` of `doc` (the scene or material file at `docAbs`) built,
// with the ext_resources and earlier sub_resources it names (build.as
// resolveResources' rules, limited to what it names: build.as usedBy): the
// Inspector's preview of a scene's own material. Fails when `doc` declares
// no such sub_resource (`resource-undeclared`).
export function buildDocSubResource(doc: RscnDoc, docAbs: string, loader: ResourceLoader, id: string): Result<Resource> {
    const decl = doc.findSub(id);
    if (decl == null) {
        return SceneryError.at("resource-undeclared", doc.file, 0, 0, "no sub_resource with id \"" + id + "\"").fail<Resource>();
    }
    const only = usedBy(doc, decl);
    only.add(id);
    const res = resolveResources(doc, docAbs, loader, only);
    if (!res.ok) return res.forward<Resource>();
    const r = res.value.sub;
    if (!r.has(id)) {
        return SceneryError.at("resource-undeclared", doc.file, 0, 0, "no sub_resource with id \"" + id + "\"").fail<Resource>();
    }
    return Result.okv<Resource>(r.get(id));
}
