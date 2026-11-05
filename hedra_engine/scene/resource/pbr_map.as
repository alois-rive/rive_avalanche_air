// StandardMaterial3D <-> PbrMaterial (engine/src/material/pbr.as), the one
// place that maps Hedra's material onto glTF's (milestone 14): a glTF
// file's materials become StandardMaterial3D through standardFromPbr
// (model.as), an .mtlx file's through the same function, and a material is
// written to an .mtlx file through pbrFromStandard. The table of names is
// docs/formats/MATERIALS.md's.
//
// The rules, so that PbrMaterial -> StandardMaterial3D -> PbrMaterial gives
// the same PbrMaterial exactly (pbr_map_test.as):
// - A feature Godot switches on (emission_enabled, normal_enabled,
//   ao_enabled, clearcoat_enabled, anisotropy_enabled, refraction_enabled,
//   backlight_enabled) is on when the glTF material uses it: a factor off
//   its "none" value or a texture in one of its slots (PbrMaterial.has*).
// - Off, its primary factor goes to glTF as "none" (emission black,
//   clearcoat, transmission, anisotropy and diffuse transmission 0) and its
//   textures are left out; its other values go as they are. From glTF, an
//   unused feature's primary factor keeps StandardMaterial3D's default
//   (clearcoat 1, transmission 1, diffuse_transmission 1), as Godot's
//   would.
// - clearcoat_roughness is the one value whose defaults differ (Godot's
//   0.5, glTF's 0): with the clear coat off, each side's default stands
//   for the other's, so that a material that never had a clear coat
//   carries neither side's default into the other (an .mtlx file of a
//   Hedra material would otherwise write clearcoat_roughness 0.5, and
//   every material read from one would set clearcoat_roughness 0). The
//   one value lost is glTF's 0.5 on a material without a clear coat, which
//   draws nothing.
// - uv1_scale and uv1_offset (Godot's, every texture of UV set 0) are folded
//   into each set-0 texture's KHR_texture_transform: a texture sampled at
//   KHR(uv * s1 + o1) is sampled at KHR'(uv) with scale' = scale * s1 and
//   offset' = offset + R(rotation) (scale * o1), exactly the same
//   coordinate. Coming back, uv1 is the identity. z is dropped.
// - colours are sRGB on both sides: copied, never converted.
// - Milestone 15: an ArtboardTexture crosses as a PbrTexture whose path is
//   its RiveFile's (as the document wrote it) and whose `artboard` holds
//   the artboard, the state machine and the size (0 x 0 for the
//   artboard's own); back, PbrTextures.textureOfPbr makes an
//   ArtboardTexture of such a PbrTexture. One without a RiveFile leaves
//   its slot without a texture: there is no file to name.
// So StandardMaterial3D -> PbrMaterial -> StandardMaterial3D draws the same
// material, but a switched-off feature's values and uv1 do not come back.

import { Vec2, Vec4 } from "../../base/vecmath";
import {
    PBR_ALPHA_BLEND, PBR_ALPHA_MASK, PBR_ALPHA_OPAQUE, PBR_SLOT_COUNT, PbrArtboard, PbrMaterial, PbrSlot, PbrTexture,
} from "../../material/pbr";
import { MATERIAL_TEXTURE_PROPS } from "../classdb";
import {
    ARTBOARD_TEXTURE_MARK, ArtboardTexture, MaterialUv, RiveFile, StandardMaterial3D, Texture2D, ViewportTexture,
} from "./types";

// StandardMaterial3D's clearcoat_roughness default (classdb.as).
const GODOT_CLEARCOAT_ROUGHNESS: f32 = 0.5;

// How textures cross: a PbrTexture names an image (or a Rive file) by
// path, a StandardMaterial3D holds a Texture2D. The default writes a
// texture's display path (`file`, else `path`; an ArtboardTexture's: its
// RiveFile's) and makes a Texture2D that holds only the path (no image:
// what a document needs, not what a renderer draws), or an ArtboardTexture
// whose RiveFile holds only the path.
//
// pbrFromStandard asks pathOf for every texture; standardFromPbr asks
// textureOfPbr, whose default asks textureOf(path) for an image (so an
// implementation that knows images only, model.as's, overrides textureOf
// alone) and artboardTextureOf for a texture with an artboard.
export class PbrTextures {
    // The path a PbrTexture writes for `t`.
    pathOf(t: Texture2D): string {
        // (milestone 34: a ViewportTexture names a node of its scene, which
        // a material file cannot hold: its slot is left without a texture)
        const isViewport = t instanceof ViewportTexture;
        if (isViewport) return "";
        const isArtboard = t instanceof ArtboardTexture;
        if (isArtboard) {
            const f = (t as ArtboardTexture).rive;
            if (f != null) return f.file.length > 0 ? f.file : f.path;
            return "";
        }
        return t.file.length > 0 ? t.file : t.path;
    }

    // The texture a PbrTexture's `path` names, or null to leave the slot
    // empty (the loader's implementation reports why).
    textureOf(path: string): Texture2D? {
        const t = new Texture2D();
        t.path = path;
        t.file = path;
        return t;
    }

    // The texture of slot `slot` for `pt`: textureOf(pt.path) for an
    // image, artboardTextureOf for a texture drawn from an artboard.
    textureOfPbr(pt: PbrTexture, slot: i32): Texture2D? {
        const a = pt.artboard;
        if (a == null) return this.textureOf(pt.path);
        return this.artboardTextureOf(pt.path, a, slot);
    }

    // The texture of slot `slot` drawn from artboard `a` of the Rive file
    // at `path`: an ArtboardTexture whose RiveFile holds only the path
    // (not read), its own path the mark and the slot's property, as a
    // texture an .mtlx file declares is without the file's path
    // (artboard_texture.as artboardTexturePath).
    artboardTextureOf(path: string, a: PbrArtboard, slot: i32): Texture2D? {
        const f = new RiveFile();
        f.path = path;
        f.file = path;
        const t = new ArtboardTexture();
        t.rive = f;
        t.artboard = a.artboard;
        t.stateMachine = a.stateMachine;
        t.sizeX = a.width;
        t.sizeY = a.height;
        // (milestone 67: through the setter only when it changes, as a
        // scene's file does)
        if (a.updateMode != t.updateMode) t.updateMode = a.updateMode;
        t.updateFps = a.updateFps;
        t.path = ARTBOARD_TEXTURE_MARK + slotProperty(slot);
        return t;
    }
}

// The artboard of texture `t` as a PbrTexture carries it; null for an
// image.
function pbrArtboardOf(t: Texture2D): PbrArtboard? {
    const isArtboard = t instanceof ArtboardTexture;
    if (!isArtboard) return null;
    const at = t as ArtboardTexture;
    const a = new PbrArtboard(at.artboard);
    a.stateMachine = at.stateMachine;
    a.width = at.sizeX;
    a.height = at.sizeY;
    a.updateMode = at.updateMode;
    a.updateFps = at.updateFps;
    return a;
}

// The texture of slot `slot` is in use (its feature switched on).
export function slotEnabled(m: StandardMaterial3D, slot: i32): bool {
    switch (slot) {
        case PbrSlot.Normal: return m.normalEnabled;
        case PbrSlot.Occlusion: return m.aoEnabled;
        case PbrSlot.Emissive: return m.emissionEnabled;
        case PbrSlot.Clearcoat:
        case PbrSlot.ClearcoatRoughness:
        case PbrSlot.ClearcoatNormal: return m.clearcoatEnabled;
        case PbrSlot.Transmission: return m.refractionEnabled;
        case PbrSlot.Anisotropy: return m.anisotropyEnabled;
        case PbrSlot.DiffuseTransmission:
        case PbrSlot.DiffuseTransmissionColor: return m.backlightEnabled;
        default: return true;
    }
}

// `m` as glTF's material (the rules above).
export function pbrFromStandard(m: StandardMaterial3D, textures: PbrTextures = new PbrTextures()): PbrMaterial {
    const p = new PbrMaterial(m.name);
    const a = m.albedoColor;
    p.baseColor = [a.x, a.y, a.z, a.w];
    p.metallic = m.metallic;
    p.roughness = m.roughness;
    p.emissive = m.emissionEnabled ? rgb(m.emission) : [0, 0, 0];
    p.emissiveStrength = m.emissionEnergy;
    p.normalScale = m.normalScale;
    p.occlusionStrength = m.aoStrength;
    p.alphaMode = m.transparency == 1 ? PBR_ALPHA_BLEND : m.transparency == 2 ? PBR_ALPHA_MASK : PBR_ALPHA_OPAQUE;
    p.alphaCutoff = m.alphaScissorThreshold;
    p.doubleSided = m.cullMode == 2;
    p.cullFront = m.cullMode == 1;
    p.unlit = m.shadingMode == 0;
    p.ior = m.ior;
    p.specular = m.specular;
    p.specularColor = rgb(m.specularColor);
    p.transmission = m.refractionEnabled ? m.transmission : 0;
    p.thickness = m.thickness;
    p.attenuationDistance = m.attenuationDistance;
    p.attenuationColor = rgb(m.attenuationColor);
    p.clearcoat = m.clearcoatEnabled ? m.clearcoat : 0;
    p.clearcoatRoughness = !m.clearcoatEnabled && m.clearcoatRoughness == GODOT_CLEARCOAT_ROUGHNESS ? <f32>0 : m.clearcoatRoughness;
    p.clearcoatNormalScale = m.clearcoatNormalScale;
    p.sheenColor = rgb(m.sheenColor);
    p.sheenRoughness = m.sheenRoughness;
    p.iridescence = m.iridescence;
    p.iridescenceIor = m.iridescenceIor;
    p.iridescenceThicknessMinimum = m.iridescenceThicknessMinimum;
    p.iridescenceThicknessMaximum = m.iridescenceThicknessMaximum;
    p.anisotropyStrength = m.anisotropyEnabled ? m.anisotropy : 0;
    p.anisotropyRotation = m.anisotropyRotation;
    p.dispersion = m.dispersion;
    p.diffuseTransmission = m.backlightEnabled ? m.diffuseTransmission : 0;
    p.diffuseTransmissionColor = rgb(m.backlight);
    p.vertexColorUseAsAlbedo = m.vertexColorUseAsAlbedo;
    p.vertexColorIsSrgb = m.vertexColorIsSrgb;
    const s1x = <f32>m.uv1Scale.x, s1y = <f32>m.uv1Scale.y;
    const o1x = <f32>m.uv1Offset.x, o1y = <f32>m.uv1Offset.y;
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const t = m.textureAt(slot);
        if (t == null || !slotEnabled(m, slot)) continue;
        const uv = m.uvs[slot];
        const pt = new PbrTexture(textures.pathOf(t));
        pt.artboard = pbrArtboardOf(t);
        // An ArtboardTexture with no RiveFile (the editor's new one, before
        // its file is set) has no file to name: MaterialX cannot hold an
        // artboard without its .riv, so the slot is written without a
        // texture rather than as a file the reader refuses.
        if (pt.artboard != null && pt.path.length == 0) continue;
        // Nor a ViewportTexture, whose node a material file cannot name
        // (PbrTextures.pathOf gives none). The renderer's PathOnly names
        // its key, so an extension slot keeps it and draws what the
        // viewport-texture-extension warning says: transparent black.
        const isViewport = t instanceof ViewportTexture;
        if (isViewport && pt.path.length == 0) continue;
        pt.texCoord = uv.texcoord;
        pt.rotation = uv.rotation;
        if (uv.texcoord == 0) {
            // Fold uv1 in (see the header): exact when uv1 is the identity.
            const sx = <f32>uv.scale.x * s1x, sy = <f32>uv.scale.y * s1y;
            const vx = <f32>uv.scale.x * o1x, vy = <f32>uv.scale.y * o1y;
            let rx = vx, ry = vy;
            if (uv.rotation != 0) {
                const c = Mathf.cos(uv.rotation), s = Mathf.sin(uv.rotation);
                rx = c * vx + s * vy;
                ry = -s * vx + c * vy;
            }
            pt.scale = [sx, sy];
            pt.offset = [<f32>uv.offset.x + rx, <f32>uv.offset.y + ry];
        } else {
            pt.scale = [<f32>uv.scale.x, <f32>uv.scale.y];
            pt.offset = [<f32>uv.offset.x, <f32>uv.offset.y];
        }
        p.setTexture(slot, pt);
    }
    return p;
}

// glTF's material as a StandardMaterial3D (the rules above); `textures`
// makes each slot's Texture2D from its path.
export function standardFromPbr(p: PbrMaterial, textures: PbrTextures = new PbrTextures()): StandardMaterial3D {
    const m = new StandardMaterial3D();
    m.name = p.name;
    m.albedoColor = Vec4(p.baseColor[0], p.baseColor[1], p.baseColor[2], p.baseColor[3]);
    m.metallic = p.metallic;
    m.roughness = p.roughness;
    const e = p.emissive;
    m.emissionEnabled = e[0] != 0 || e[1] != 0 || e[2] != 0 || p.texture(PbrSlot.Emissive) != null;
    m.emission = Vec4(e[0], e[1], e[2], 1);
    m.emissionEnergy = p.emissiveStrength;
    m.normalEnabled = p.texture(PbrSlot.Normal) != null;
    m.normalScale = p.normalScale;
    m.aoEnabled = p.texture(PbrSlot.Occlusion) != null;
    m.aoStrength = p.occlusionStrength;
    m.transparency = p.alphaMode == PBR_ALPHA_BLEND ? 1 : p.alphaMode == PBR_ALPHA_MASK ? 2 : 0;
    m.alphaScissorThreshold = p.alphaCutoff;
    m.cullMode = p.doubleSided ? 2 : p.cullFront ? 1 : 0;
    m.shadingMode = p.unlit ? 0 : 1;
    m.ior = p.ior;
    m.specular = p.specular;
    m.specularColor = rgba(p.specularColor);
    m.refractionEnabled = p.hasTransmission();
    if (m.refractionEnabled) m.transmission = p.transmission;
    m.thickness = p.thickness;
    m.attenuationDistance = p.attenuationDistance;
    m.attenuationColor = rgba(p.attenuationColor);
    m.clearcoatEnabled = p.hasClearcoat();
    if (m.clearcoatEnabled) m.clearcoat = p.clearcoat;
    m.clearcoatRoughness = !m.clearcoatEnabled && p.clearcoatRoughness == 0 ? GODOT_CLEARCOAT_ROUGHNESS : p.clearcoatRoughness;
    m.clearcoatNormalScale = p.clearcoatNormalScale;
    m.sheenColor = rgba(p.sheenColor);
    m.sheenRoughness = p.sheenRoughness;
    m.iridescence = p.iridescence;
    m.iridescenceIor = p.iridescenceIor;
    m.iridescenceThicknessMinimum = p.iridescenceThicknessMinimum;
    m.iridescenceThicknessMaximum = p.iridescenceThicknessMaximum;
    m.anisotropyEnabled = p.hasAnisotropy();
    m.anisotropy = p.anisotropyStrength;
    m.anisotropyRotation = p.anisotropyRotation;
    m.dispersion = p.dispersion;
    m.backlightEnabled = p.hasDiffuseTransmission();
    if (m.backlightEnabled) m.diffuseTransmission = p.diffuseTransmission;
    m.backlight = rgba(p.diffuseTransmissionColor);
    m.vertexColorUseAsAlbedo = p.vertexColorUseAsAlbedo;
    m.vertexColorIsSrgb = p.vertexColorIsSrgb;
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const pt = p.texture(slot);
        if (pt == null) continue;
        m.setTextureAt(slot, textures.textureOfPbr(pt, slot));
        const uv = new MaterialUv();
        uv.texcoord = pt.texCoord;
        uv.offset = Vec2(pt.offset[0], pt.offset[1]);
        uv.rotation = pt.rotation;
        uv.scale = Vec2(pt.scale[0], pt.scale[1]);
        m.uvs[slot] = uv;
    }
    // A glTF metallic-roughness texture is one image: drawn as one when
    // both slots hold the same path with the same transform.
    const mt = p.texture(PbrSlot.Metallic);
    const rt = p.texture(PbrSlot.Roughness);
    m.packedMetallicRoughness = mt != null && rt != null && mt.equals(rt);
    return m;
}

// The StandardMaterial3D property a slot's texture is (classdb.as).
export function slotProperty(slot: i32): string {
    return MATERIAL_TEXTURE_PROPS[slot];
}

function rgb(c: Vec4): StaticArray<f32> {
    return [c.x, c.y, c.z];
}

function rgba(c: StaticArray<f32>): Vec4 {
    return Vec4(c[0], c[1], c[2], 1);
}
