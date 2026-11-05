// A scene's materials as the renderer draws them: StandardMaterial3D to
// MaterialDesc (hedra_engine/render/material.as), decision 3 of milestone 4.
// Both hold colours sRGB with straight alpha, so the colours are copied; the
// renderer's alpha modes and texture slots are glTF's, which a model's
// materials came from, so a model's material round-trips to what Hedra
// draws. What the renderer cannot draw is left out with a warning rather
// than drawn wrong. Milestone 14's second part adds glTF's whole material
// (docs/engine/SHADING.md): every StandardMaterial3D property is drawn.
//
// Milestone 61 (Godot's ShaderMaterial, docs/engine/SHADERS.md): a
// ShaderMaterial's MaterialDesc is its StandardMaterial3D fields (its
// fallback: drawn while its shader is not ready, or cannot be) with
// `custom` (render/custom_material.as): its program, its parameters (the
// material's own ShaderParams, which a binding or a timeline writes in
// place, so the renderer writes its block again by the next picture) and
// its textures by the shader's texture index, as paths the binder reads
// (`texturePath`, as a slot's: an ArtboardTexture's or ViewportTexture's
// live path too), sRGB for a source_color uniform; its alpha mode from
// the shader (blended when transparent, a cut-out when it writes
// ALPHA_SCISSOR_THRESHOLD, else opaque) and its sides from its cull mode,
// so that culling, sorting and the shadow pass treat it as the shader
// draws it. A ShaderMaterial without a shader, or whose shader has errors,
// has no `custom`: its fallback alone. Every material's render_priority
// (Godot's Material.render_priority) is MaterialDesc.renderPriority.

import { Image } from "../../render/image";
import { CustomMaterialDesc } from "../../render/custom_material";
import { CULL_BACK, HINT_SOURCE_COLOR, UniformType } from "../../render/shader/program";
import { ShaderMaterial } from "../resource/shader";
import {
    ALPHA_BLEND, ALPHA_MASK, ALPHA_OPAQUE, MaterialDesc, TEX_BASE, TEX_EMISSION, TEX_METALLIC_ROUGHNESS, TEX_NORMAL,
    TEX_OCCLUSION, slotDrawn, slotsOnSet,
} from "../../render/material";
import { PBR_SLOT_COUNT, PbrSlot } from "../../material/pbr";
import { Resource, StandardMaterial3D, Texture2D } from "../resource/types";
import { PbrTextures, pbrFromStandard, slotProperty } from "../resource/pbr_map";
import { SceneTextureFiles } from "./cache";

// How warnings name a resource (a material, a sky): its resource_name, else
// the sub_resource id it was declared with, else the file it came from.
export function resourceLabel(r: Resource): string {
    if (r.name.length > 0) return r.name;
    if (r.id.length > 0) return r.id;
    return r.path;
}

// How warnings name a material (resourceLabel).
export function materialLabel(m: StandardMaterial3D): string {
    return resourceLabel(m);
}

// The path the binder reads a texture by, with its image registered in
// `textures` so that the binder decodes nothing again, and draws the images
// a glTF file embeds, which are no file (their path is
// `<model path>#<image>`). null for no texture, or one with no path. A
// Radiance HDR image (a panorama's, milestone 11) is left out with a
// warning: the binder would refuse it too, but the scene renderer does not
// pass the GPU pass's warnings on, and the surface would draw magenta.
//
// Milestone 26: a bundle's texture's processed forms (Texture2D.compressed)
// are registered too, under the same path.
//
// Milestone 15: an ArtboardTexture is drawn by the same road in every slot,
// the extension slots too: its `image` is its placeholder (a labelled
// checker, ../render/artboard_placeholder.as) and its `path` its identity
// (`<declaring file>#artboard:<key>`), under which a built project's
// player gives the binder the live view of the five bound slots
// (MaterialBinder.setLive). The extension slots are composed on the CPU
// into one array texture (MaterialBinder.extArray), so there the
// placeholder stays, in built projects too (MATERIALS.md, "Artboard
// textures").
//
// Milestone 67b: how the slot samples it (`srgb`: colour; `cpu`: an
// extension slot, composed on the CPU) is said to the texture before it is
// bound (Texture2D.noteSampled, keepCpu), so that a run time that releases
// CPU copies after upload keeps what a later upload or the CPU still reads.
function texturePath(t: Texture2D?, slot: string, label: string, textures: SceneTextureFiles,
    warnings: Array<string>, srgb: bool, cpu: bool = false): string? {
    if (t == null || t.path.length == 0) return null;
    if (cpu) t.keepCpu();
    else t.noteSampled(srgb);
    const img: Image? = t.image;
    // Milestone 26: a texture from a bundle may hold processed forms (the
    // run time's chosen one, or every one the bundle has in the tools),
    // drawn as SceneTextureFiles' mode says; without a source they are
    // the picture.
    const forms = t.compressed;
    if (forms != null && forms.length > 0) textures.addCompressed(t.path, forms);
    if (img == null && t.hdr != null) {
        const shown = t.file.length > 0 ? t.file : t.path;
        warnings.push("material '" + label + "': " + slot + " " + shown
            + " is a Radiance HDR image; material textures are PNG only, so it is not drawn");
        return null;
    }
    if (img != null) textures.add(t.path, img);
    return t.path;
}

// `m` as the renderer draws it (see the header); what cannot be drawn goes
// to `warnings`, once per call (the adapter calls it once per material).
//
// Milestone 14, part 2: the rest of glTF's material comes through
// pbrFromStandard (pbr_map.as), so the renderer sees what an .mtlx file or
// a glTF export of the material would hold: Godot's switches off give the
// feature's "none" and leave its textures out. Each texture's UV set and
// KHR_texture_transform go to MaterialDesc.slotUv as the material holds
// them (the renderer folds uv1 into set 0's itself, as it always moved
// set 0 by uv1). A material that uses none of it is the MaterialDesc it
// was, and draws the picture it drew.
export function materialDesc(m: StandardMaterial3D, textures: SceneTextureFiles, warnings: Array<string>): MaterialDesc {
    const d = new MaterialDesc();
    const label = materialLabel(m);
    const a = m.albedoColor;
    d.baseColor = [a.x, a.y, a.z];
    d.alpha = a.w;
    d.metallic = m.metallic;
    d.roughness = m.roughness;
    if (m.emissionEnabled) {
        d.emission = [m.emission.x, m.emission.y, m.emission.z];
    } else {
        d.emission = [0, 0, 0];
    }
    d.emissionStrength = m.emissionEnergy;
    d.alphaMode = m.transparency == 1 ? ALPHA_BLEND : m.transparency == 2 ? ALPHA_MASK : ALPHA_OPAQUE;
    d.alphaCutoff = m.alphaScissorThreshold;
    // The renderer never culls (as in Hedra): cull_mode only says whether
    // the back face is lit as a front one.
    d.doubleSided = m.cullMode == 2;
    // Milestone 13: a MultiMesh instance's colour multiplies the albedo.
    d.vertexColorAsAlbedo = m.vertexColorUseAsAlbedo;
    d.vertexColorIsSrgb = m.vertexColorIsSrgb;
    // Milestone 14: Godot's UV1 group moves every texture; z is kept in the
    // file but a surface's texture coordinates have two.
    d.uvScale = [<f32>m.uv1Scale.x, <f32>m.uv1Scale.y];
    d.uvOffset = [<f32>m.uv1Offset.x, <f32>m.uv1Offset.y];

    d.textures[TEX_BASE] = texturePath(m.albedoTexture, "albedo_texture", label, textures, warnings, true);
    if (m.emissionEnabled) d.textures[TEX_EMISSION] = texturePath(m.emissionTexture, "emission_texture", label, textures, warnings, true);
    if (m.normalEnabled) d.textures[TEX_NORMAL] = texturePath(m.normalTexture, "normal_texture", label, textures, warnings, false);
    if (m.aoEnabled) d.textures[TEX_OCCLUSION] = texturePath(m.aoTexture, "ao_texture", label, textures, warnings, false);

    // Metallic and roughness: one image packed as glTF packs it (blue
    // metallic, green roughness) is today's one lookup; two images, or one
    // of them alone, are drawn by the extended path (each from its own
    // image: MaterialDesc.metallicFromMr, roughnessFromMr, and the
    // roughness's own layer).
    const mt = m.metallicTexture;
    const rt = m.roughnessTexture;
    if (mt != null && rt != null && (m.packedMetallicRoughness || mt == rt)) {
        d.textures[TEX_METALLIC_ROUGHNESS] = texturePath(mt, "metallic_texture", label, textures, warnings, false);
    } else if (mt != null) {
        d.textures[TEX_METALLIC_ROUGHNESS] = texturePath(mt, "metallic_texture", label, textures, warnings, false);
        d.roughnessFromMr = false;
        if (rt != null) d.extTextures[PbrSlot.Roughness] = texturePath(rt, "roughness_texture", label, textures, warnings, false, true);
    } else if (rt != null) {
        d.textures[TEX_METALLIC_ROUGHNESS] = texturePath(rt, "roughness_texture", label, textures, warnings, false);
        d.metallicFromMr = false;
    }

    // glTF's whole material, through pbr_map.as (its rules: the gates).
    const p = pbrFromStandard(m, new PathOnly());
    d.normalScale = p.normalScale;
    d.occlusionStrength = p.occlusionStrength;
    d.unlit = p.unlit;
    d.ior = p.ior;
    d.specular = p.specular;
    d.specularColor = rgb(p.specularColor);
    d.transmission = p.transmission;
    d.thickness = p.thickness;
    // (milestone 62: Godot's refraction_scale, which glTF has no field for;
    // read only by a frame that refracts the screen)
    d.refractionScale = m.refractionScale;
    d.attenuationDistance = p.attenuationDistance;
    d.attenuationColor = rgb(p.attenuationColor);
    d.dispersion = p.dispersion;
    d.clearcoat = p.clearcoat;
    d.clearcoatRoughness = p.clearcoatRoughness;
    d.clearcoatNormalScale = p.clearcoatNormalScale;
    d.sheenColor = rgb(p.sheenColor);
    d.sheenRoughness = p.sheenRoughness;
    d.iridescence = p.iridescence;
    d.iridescenceIor = p.iridescenceIor;
    d.iridescenceThicknessMinimum = p.iridescenceThicknessMinimum;
    d.iridescenceThicknessMaximum = p.iridescenceThicknessMaximum;
    d.anisotropyStrength = p.anisotropyStrength;
    d.anisotropyRotation = p.anisotropyRotation;
    d.diffuseTransmission = p.diffuseTransmission;
    d.diffuseTransmissionColor = rgb(p.diffuseTransmissionColor);
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        // The material's own transform (pbrFromStandard's folds uv1 in;
        // the renderer does that itself).
        const uv = m.uvs[slot];
        const t = d.slotUv[slot];
        t.texCoord = uv.texcoord;
        t.offset = [<f32>uv.offset.x, <f32>uv.offset.y];
        t.rotation = uv.rotation;
        t.scale = [<f32>uv.scale.x, <f32>uv.scale.y];
        if (slot < 6 || p.texture(slot) == null) continue;
        d.extTextures[slot] = texturePath(m.textureAt(slot), slotProperty(slot), label, textures, warnings, false, true);
    }
    foldSharedTransform(d);
    const above = slotsOnSet(d, 1, true);
    if (above.length > 0) {
        warnings.push("material '" + label + "': " + slotNames(above) + " "
            + (above.length == 1 ? "samples a UV set" : "sample UV sets") + " above 1; drawn with UV set 0");
    }
    // Milestone 61: Godot's render_priority, and a ShaderMaterial's shader
    // (see the header).
    d.renderPriority = renderPriorityOf(m);
    if (m instanceof ShaderMaterial) customInto(d, m as ShaderMaterial, label, textures, warnings);
    return d;
}

// Godot's Material.render_priority, within RENDER_PRIORITY_MIN and _MAX
// (-128 to 127; the loader clamps it already).
function renderPriorityOf(m: StandardMaterial3D): i32 {
    return min<i32>(max<i32>(m.renderPriority, -128), 127);
}

// `d.custom` of ShaderMaterial `m` (the header), and the alpha mode and
// sides its shader draws with; none without a shader (its fallback alone
// is drawn). A program with errors keeps its part: no source makes a
// module of it, so it draws its fallback (counted as one), but the tools'
// keep the file's last good module, which an edit that broke the shader
// leaves on screen (render/shader/modules.as programOf).
function customInto(d: MaterialDesc, m: ShaderMaterial, label: string, textures: SceneTextureFiles,
    warnings: Array<string>): void {
    const p = m.program;
    if (p == null) return;
    const c = new CustomMaterialDesc(p, m.params);
    for (let i = 0; i < p.uniforms.length; i++) {
        const u = p.uniforms[i];
        if (u.type != UniformType.Texture2D || u.texture < 0 || u.texture >= c.textures.length) continue;
        const tex = u.texture < m.textures.length ? m.textures[u.texture] : null;
        c.srgb[u.texture] = (u.hints & HINT_SOURCE_COLOR) != 0;
        c.textures[u.texture] = texturePath(tex, "shader_parameter/" + u.name, label, textures, warnings, c.srgb[u.texture]);
    }
    d.custom = c;
    // (a program with errors draws as its fallback does, opaque or blended
    // by the material's own fields: its render modes are not to be trusted)
    if (p.errors() == 0) customModes(d, c);
}

// The alpha mode and sides of a MaterialDesc with `custom` `c`, from its
// shader (the header's rule).
function customModes(d: MaterialDesc, c: CustomMaterialDesc): void {
    const p = c.program;
    d.alphaMode = p.transparent() ? ALPHA_BLEND : p.usesAlphaScissor ? ALPHA_MASK : ALPHA_OPAQUE;
    d.doubleSided = p.cull != CULL_BACK;
}

// A transform every drawn texture of UV set 0 shares, without rotation,
// moved back into uvScale/uvOffset while uv1 is the identity: today's
// coordinate exactly (KHR_texture_transform without rotation is
// uv * scale + offset, Godot's uv1), so a material read from an .mtlx file,
// where uv1 comes as each texture's transform (pbr_map.as), draws through
// the pipeline and the picture the same material in a scene's sub_resource,
// with uv1_scale, draws. The extended pipelines fold uv1 into set 0 the
// same way, so the move changes nothing there either.
function foldSharedTransform(d: MaterialDesc): void {
    if (d.uvScale[0] != 1 || d.uvScale[1] != 1 || d.uvOffset[0] != 0 || d.uvOffset[1] != 0) return;
    let first = -1;
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        if (!slotDrawn(d, slot)) continue;
        const t = d.slotUv[slot];
        if (t.texCoord != 0) continue;
        if (t.rotation != 0) return;
        if (first < 0) {
            first = slot;
            continue;
        }
        const f = d.slotUv[first];
        if (t.offset[0] != f.offset[0] || t.offset[1] != f.offset[1] || t.scale[0] != f.scale[0] || t.scale[1] != f.scale[1]) return;
    }
    if (first < 0 || d.slotUv[first].isIdentity()) return;
    const f = d.slotUv[first];
    d.uvScale = [f.scale[0], f.scale[1]];
    d.uvOffset = [f.offset[0], f.offset[1]];
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const t = d.slotUv[slot];
        if (!slotDrawn(d, slot) || t.texCoord != 0) continue;
        t.offset = [0, 0];
        t.scale = [1, 1];
    }
}

// Milestone 25: `d`, made by materialDesc from `m`, made again in place
// from `m`'s numbers and colours after they changed (Hedra's preview
// while a colour or a number is dragged: MaterialDoc.liveParts sets the
// material's fields, and the planned frame's MaterialDesc follows here),
// allocating nothing: the stub allocator never frees, and a drag refreshes
// every frame. Every field materialDesc sets from a number, a colour or a
// texture's transform is set as materialDesc would set it (the same rules
// of pbrFromStandard, written out field by field), the shared transform
// folded again (foldSharedTransformInPlace). What it does not follow: the
// textures (which slot holds which image) and the switches that gate them
// (emission_enabled and the like decide which textures are drawn), which
// a step builds a new material for, and the preview plans again. So `d`
// equals materialDesc(m)'s field for field whenever `m`'s textures and
// switches are those `d` was made with.
export function refillMaterialDesc(d: MaterialDesc, m: StandardMaterial3D): void {
    const a = m.albedoColor;
    d.baseColor[0] = a.x;
    d.baseColor[1] = a.y;
    d.baseColor[2] = a.z;
    d.alpha = a.w;
    d.metallic = m.metallic;
    d.roughness = m.roughness;
    const on = m.emissionEnabled;
    d.emission[0] = on ? m.emission.x : 0;
    d.emission[1] = on ? m.emission.y : 0;
    d.emission[2] = on ? m.emission.z : 0;
    d.emissionStrength = m.emissionEnergy;
    d.alphaMode = m.transparency == 1 ? ALPHA_BLEND : m.transparency == 2 ? ALPHA_MASK : ALPHA_OPAQUE;
    d.alphaCutoff = m.alphaScissorThreshold;
    d.doubleSided = m.cullMode == 2;
    d.vertexColorAsAlbedo = m.vertexColorUseAsAlbedo;
    d.vertexColorIsSrgb = m.vertexColorIsSrgb;
    d.uvScale[0] = <f32>m.uv1Scale.x;
    d.uvScale[1] = <f32>m.uv1Scale.y;
    d.uvOffset[0] = <f32>m.uv1Offset.x;
    d.uvOffset[1] = <f32>m.uv1Offset.y;
    // pbrFromStandard's rules (pbr_map.as), number by number.
    d.normalScale = m.normalScale;
    d.occlusionStrength = m.aoStrength;
    d.unlit = m.shadingMode == 0;
    d.ior = m.ior;
    d.specular = m.specular;
    rgbInto(d.specularColor, m.specularColor.x, m.specularColor.y, m.specularColor.z);
    d.transmission = m.refractionEnabled ? m.transmission : 0;
    d.thickness = m.thickness;
    d.refractionScale = m.refractionScale;
    d.attenuationDistance = m.attenuationDistance;
    rgbInto(d.attenuationColor, m.attenuationColor.x, m.attenuationColor.y, m.attenuationColor.z);
    d.dispersion = m.dispersion;
    d.clearcoat = m.clearcoatEnabled ? m.clearcoat : 0;
    d.clearcoatRoughness = !m.clearcoatEnabled && m.clearcoatRoughness == GODOT_CLEARCOAT_ROUGHNESS
        ? <f32>0 : m.clearcoatRoughness;
    d.clearcoatNormalScale = m.clearcoatNormalScale;
    rgbInto(d.sheenColor, m.sheenColor.x, m.sheenColor.y, m.sheenColor.z);
    d.sheenRoughness = m.sheenRoughness;
    d.iridescence = m.iridescence;
    d.iridescenceIor = m.iridescenceIor;
    d.iridescenceThicknessMinimum = m.iridescenceThicknessMinimum;
    d.iridescenceThicknessMaximum = m.iridescenceThicknessMaximum;
    d.anisotropyStrength = m.anisotropyEnabled ? m.anisotropy : 0;
    d.anisotropyRotation = m.anisotropyRotation;
    d.diffuseTransmission = m.backlightEnabled ? m.diffuseTransmission : 0;
    rgbInto(d.diffuseTransmissionColor, m.backlight.x, m.backlight.y, m.backlight.z);
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const uv = m.uvs[slot];
        const t = d.slotUv[slot];
        t.texCoord = uv.texcoord;
        t.offset[0] = <f32>uv.offset.x;
        t.offset[1] = <f32>uv.offset.y;
        t.rotation = uv.rotation;
        t.scale[0] = <f32>uv.scale.x;
        t.scale[1] = <f32>uv.scale.y;
    }
    foldSharedTransformInPlace(d);
    // Milestone 61: the render priority, and a ShaderMaterial's parameters
    // (its ShaderParams, which a live reload replaces: the same program,
    // materialShape says) and the modes its shader draws with.
    d.renderPriority = renderPriorityOf(m);
    const c = d.custom;
    if (c != null && m instanceof ShaderMaterial) {
        c.params = (m as ShaderMaterial).params;
        if (c.program.errors() == 0) customModes(d, c);
    }
}

// pbr_map.as's clearcoat_roughness of a material without clearcoat: Godot's
// default, which glTF's material writes as 0 (pbrFromStandard).
const GODOT_CLEARCOAT_ROUGHNESS: f32 = 0.5;

function rgbInto(out: Array<f32>, r: f32, g: f32, b: f32): void {
    out[0] = r;
    out[1] = g;
    out[2] = b;
}

// foldSharedTransform, writing into `d`'s own arrays rather than new ones:
// the same decision and the same numbers.
function foldSharedTransformInPlace(d: MaterialDesc): void {
    if (d.uvScale[0] != 1 || d.uvScale[1] != 1 || d.uvOffset[0] != 0 || d.uvOffset[1] != 0) return;
    let first = -1;
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        if (!slotDrawn(d, slot)) continue;
        const t = d.slotUv[slot];
        if (t.texCoord != 0) continue;
        if (t.rotation != 0) return;
        if (first < 0) {
            first = slot;
            continue;
        }
        const f = d.slotUv[first];
        if (t.offset[0] != f.offset[0] || t.offset[1] != f.offset[1] || t.scale[0] != f.scale[0] || t.scale[1] != f.scale[1]) return;
    }
    if (first < 0 || d.slotUv[first].isIdentity()) return;
    const f = d.slotUv[first];
    const sx = f.scale[0];
    const sy = f.scale[1];
    const ox = f.offset[0];
    const oy = f.offset[1];
    d.uvScale[0] = sx;
    d.uvScale[1] = sy;
    d.uvOffset[0] = ox;
    d.uvOffset[1] = oy;
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const t = d.slotUv[slot];
        if (!slotDrawn(d, slot) || t.texCoord != 0) continue;
        t.offset[0] = 0;
        t.offset[1] = 0;
        t.scale[0] = 1;
        t.scale[1] = 1;
    }
}

// The slots' property names, comma separated.
export function slotNames(slots: Array<i32>): string {
    const out: Array<string> = [];
    for (let i = 0; i < slots.length; i++) out.push(slotProperty(slots[i]));
    return out.join(", ");
}

// pbrFromStandard's textures by their path alone: materialDesc reads the
// slots' Texture2D itself (texturePath), and only asks which are drawn.
// (An ArtboardTexture's path too, not its Rive file's: two textures of one
// artboard are two textures.)
class PathOnly extends PbrTextures {
    pathOf(t: Texture2D): string {
        return t.path;
    }
}

function rgb(c: StaticArray<f32>): Array<f32> {
    return [c[0], c[1], c[2]];
}

// Milestone 50: the switches of `m` refillMaterialDesc does not follow, as
// one number (its textures, the other thing it does not follow, are
// compared one by one: adapter.as sameShape). A frame refreshed in place
// (adapter.as refreshSceneFrame) refills its materials' numbers and colours
// while every material's switches and textures are the ones it was planned
// with, and plans again when one changed.
export function materialShape(m: StandardMaterial3D): i64 {
    let bits: i64 = 0;
    if (m.packedMetallicRoughness) bits |= 1;
    if (m.emissionEnabled) bits |= 2;
    if (m.normalEnabled) bits |= 4;
    if (m.aoEnabled) bits |= 8;
    if (m.vertexColorUseAsAlbedo) bits |= 16;
    if (m.vertexColorIsSrgb) bits |= 32;
    if (m.clearcoatEnabled) bits |= 64;
    if (m.anisotropyEnabled) bits |= 128;
    if (m.refractionEnabled) bits |= 256;
    if (m.backlightEnabled) bits |= 512;
    bits |= <i64>(m.transparency & 0xff) << 10;
    bits |= <i64>(m.cullMode & 0xff) << 18;
    bits |= <i64>(m.shadingMode & 0xff) << 26;
    // Milestone 61: a ShaderMaterial's shader (its program's key: another
    // file, or the file edited, plans again; its textures and next pass
    // are compared by the adapter, adapter.as sameShape).
    if (m instanceof ShaderMaterial) {
        const p = (m as ShaderMaterial).program;
        bits |= <i64>1 << 34;
        if (p != null) {
            bits |= <i64>(keyHash(p.key) & 0x3fffffff) << 35;
            if (p.errors() > 0) bits |= <i64>1 << 33;
        }
    }
    return bits;
}

// A string's FNV-1a (30 bits are kept: materialShape's).
function keyHash(s: string): u32 {
    let h: u32 = 2166136261;
    for (let i = 0; i < s.length; i++) h = (h ^ <u32>s.charCodeAt(i)) * 16777619;
    return h;
}

// Milestone 50: the numbers and colours of `d` refillMaterialDesc writes,
// as one number (FNV-1a over their bits): a refresh tells the renderer to
// write its kept groups' uniforms again only when it changed.
export function materialDescStamp(d: MaterialDesc): i64 {
    let h: u64 = 14695981039346656037;
    h = stampF(h, d.baseColor[0]);
    h = stampF(h, d.baseColor[1]);
    h = stampF(h, d.baseColor[2]);
    h = stampF(h, d.alpha);
    h = stampF(h, d.metallic);
    h = stampF(h, d.roughness);
    h = stampF(h, d.emission[0]);
    h = stampF(h, d.emission[1]);
    h = stampF(h, d.emission[2]);
    h = stampF(h, d.emissionStrength);
    h = stampU(h, <u32>d.alphaMode);
    h = stampF(h, d.alphaCutoff);
    h = stampU(h, d.doubleSided ? 1 : 0);
    h = stampU(h, d.vertexColorAsAlbedo ? 1 : 0);
    h = stampU(h, d.vertexColorIsSrgb ? 1 : 0);
    h = stampF(h, d.uvScale[0]);
    h = stampF(h, d.uvScale[1]);
    h = stampF(h, d.uvOffset[0]);
    h = stampF(h, d.uvOffset[1]);
    h = stampF(h, d.normalScale);
    h = stampF(h, d.occlusionStrength);
    h = stampU(h, d.unlit ? 1 : 0);
    h = stampF(h, d.ior);
    h = stampF(h, d.specular);
    for (let i = 0; i < 3; i++) h = stampF(h, d.specularColor[i]);
    h = stampF(h, d.transmission);
    h = stampF(h, d.thickness);
    h = stampF(h, d.refractionScale);
    h = stampF(h, d.attenuationDistance);
    for (let i = 0; i < 3; i++) h = stampF(h, d.attenuationColor[i]);
    h = stampF(h, d.dispersion);
    h = stampF(h, d.clearcoat);
    h = stampF(h, d.clearcoatRoughness);
    h = stampF(h, d.clearcoatNormalScale);
    for (let i = 0; i < 3; i++) h = stampF(h, d.sheenColor[i]);
    h = stampF(h, d.sheenRoughness);
    h = stampF(h, d.iridescence);
    h = stampF(h, d.iridescenceIor);
    h = stampF(h, d.iridescenceThicknessMinimum);
    h = stampF(h, d.iridescenceThicknessMaximum);
    h = stampF(h, d.anisotropyStrength);
    h = stampF(h, d.anisotropyRotation);
    h = stampF(h, d.diffuseTransmission);
    for (let i = 0; i < 3; i++) h = stampF(h, d.diffuseTransmissionColor[i]);
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const t = d.slotUv[slot];
        h = stampU(h, <u32>t.texCoord);
        h = stampF(h, t.offset[0]);
        h = stampF(h, t.offset[1]);
        h = stampF(h, t.rotation);
        h = stampF(h, t.scale[0]);
        h = stampF(h, t.scale[1]);
    }
    // Milestone 61: the render priority, and a ShaderMaterial's parameters
    // (their version moves with every write: the renderer writes the block
    // again itself, by the version; this tells a refresh something moved).
    h = stampU(h, <u32>d.renderPriority);
    const c = d.custom;
    if (c != null) {
        h = stampU(h, <u32>c.params.version);
        h = stampU(h, <u32>c.params.count);
    }
    return <i64>h;
}

function stampU(h: u64, v: u32): u64 {
    return (h ^ <u64>v) * 1099511628211;
}

function stampF(h: u64, v: f32): u64 {
    return stampU(h, reinterpret<u32>(v));
}
