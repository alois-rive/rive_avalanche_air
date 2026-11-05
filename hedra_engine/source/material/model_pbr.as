// The shared model's Material (engine/src/source/model/scene.as: what a .modeler
// file holds, and what Hedra's glTF import fills) as a PbrMaterial, so
// that Hedra builds a .modeler model's materials on the road a glTF
// model's take (engine/src/source/scene/resource/model.as: PbrMaterial ->
// standardFromPbr).
//
// The model's Material is glTF's core material without the per-texture
// details: no normal scale or occlusion strength (both glTF's default, 1),
// no texture transform, and one metallic-roughness image, which fills both
// the Metallic and Roughness slots as a glTF import does. Its colours are
// sRGB already (scene.as), as PbrMaterial's are: copied.
//
// A texture's UV layer is left at set 0. The model names a layer
// (TextureRef.uvLayer), not a set: which set a name is depends on the
// mesh, and the shared renderer draws a model's mesh through the layer its
// textures name (engine/src/source/render/meshbuild.as textureLayer), as Hedra
// does, so set 0 of the drawn mesh is already that layer.

import { AlphaMode, Material, TextureRef } from "../model/scene";
import { isAbsolute, normalizeAbs } from "../../fs/path";
import {
    PBR_ALPHA_BLEND, PBR_ALPHA_MASK, PBR_ALPHA_OPAQUE, PbrMaterial, PbrSlot, PbrTexture,
} from "../../material/pbr";

function texture(ref: TextureRef?): PbrTexture? {
    return ref != null ? new PbrTexture(ref.path) : null;
}

// `m` as glTF's material (the header's rules).
export function pbrFromModelMaterial(m: Material): PbrMaterial {
    const p = new PbrMaterial(m.name);
    const bc = m.baseColor;
    p.baseColor = [bc[0], bc[1], bc[2], m.alpha];
    p.metallic = m.metallic;
    p.roughness = m.roughness;
    const e = m.emission;
    p.emissive = [e[0], e[1], e[2]];
    p.emissiveStrength = m.emissionStrength;
    p.alphaMode = m.alphaMode == AlphaMode.Blend ? PBR_ALPHA_BLEND : m.alphaMode == AlphaMode.Mask ? PBR_ALPHA_MASK : PBR_ALPHA_OPAQUE;
    p.alphaCutoff = m.alphaCutoff;
    p.doubleSided = m.doubleSided;
    const tx = m.textures;
    p.setTexture(PbrSlot.BaseColor, texture(tx.baseColor));
    const mr = texture(tx.metallicRoughness);
    if (mr != null) {
        p.setTexture(PbrSlot.Metallic, mr);
        p.setTexture(PbrSlot.Roughness, mr.clone());
    }
    p.setTexture(PbrSlot.Normal, texture(tx.normal));
    p.setTexture(PbrSlot.Occlusion, texture(tx.occlusion));
    p.setTexture(PbrSlot.Emissive, texture(tx.emission));
    return p;
}

// The other way: a material read from a MaterialX file (a model's material
// whose `file` names one: ../model/compose.as) as the shared model's
// Material, which the model renderer and the glTF export draw. What the
// model's Material has no field for (glTF's extensions, a texture's
// transform and set, the normal scale) is left out; a slot drawn from a
// Rive artboard is left empty (the model renderer draws images). A material
// file names its images relative to itself: a relative path is joined to
// `dir`, the file's directory (absolute, so the result is too); an
// absolute or res:// path is kept.
export function modelMaterialFromPbr(p: PbrMaterial, name: string, dir: string): Material {
    const m = Material.new(name);
    m.baseColor = [p.baseColor[0], p.baseColor[1], p.baseColor[2]];
    m.alpha = p.baseColor[3];
    m.metallic = p.metallic;
    m.roughness = p.roughness;
    m.emission = [p.emissive[0], p.emissive[1], p.emissive[2]];
    m.emissionStrength = p.emissiveStrength;
    m.alphaMode = p.alphaMode == PBR_ALPHA_BLEND ? AlphaMode.Blend : p.alphaMode == PBR_ALPHA_MASK ? AlphaMode.Mask : AlphaMode.Opaque;
    m.alphaCutoff = p.alphaCutoff;
    m.doubleSided = p.doubleSided;
    const t = m.textures;
    t.baseColor = modelTexture(p.texture(PbrSlot.BaseColor), dir);
    // glTF's one metallic-roughness image fills both slots.
    let mr = modelTexture(p.texture(PbrSlot.Metallic), dir);
    if (mr == null) mr = modelTexture(p.texture(PbrSlot.Roughness), dir);
    t.metallicRoughness = mr;
    t.normal = modelTexture(p.texture(PbrSlot.Normal), dir);
    t.occlusion = modelTexture(p.texture(PbrSlot.Occlusion), dir);
    t.emission = modelTexture(p.texture(PbrSlot.Emissive), dir);
    return m;
}

// A path a file at `dir` names, made absolute when it is relative.
export function besideFile(dir: string, path: string): string {
    if (path.length == 0 || isAbsolute(path) || path.startsWith("res://")) return path;
    return normalizeAbs(dir + "/" + path);
}

function modelTexture(t: PbrTexture?, dir: string): TextureRef? {
    if (t == null || t.artboard != null || t.path.length == 0) return null;
    return new TextureRef(besideFile(dir, t.path));
}
