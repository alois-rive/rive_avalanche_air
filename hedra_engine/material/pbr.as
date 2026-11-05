// A material as glTF 2.0 defines it, whole (milestone 14): the core
// metallic-roughness model and every ratified KHR_materials_* extension,
// with each texture's UV set and KHR_texture_transform. It is the meeting
// point of the three roads a material travels, so that each is written once:
//
//   glTF file  --shared/src/io/import (ImportOpts.pbr)-->  PbrMaterial
//   .mtlx file <--engine/src/source/material/mtlx.as-->            PbrMaterial
//   Hedra's StandardMaterial3D <resource/pbr_map.as--> PbrMaterial
//
// docs/formats/MATERIALS.md is the normative description (the MaterialX
// profile and the table glTF <-> StandardMaterial3D <-> MaterialX).
//
// Two departures from glTF's own layout, both so that a Hedra material
// survives the road there and back:
// - metallic and roughness are two texture slots (glTF has one
//   metallicRoughnessTexture). A glTF import fills both with the same
//   texture; the channels stay glTF's (metallic blue, roughness green), so a
//   material whose two slots hold the same texture is glTF's exactly.
// - colours are sRGB-encoded, as Hedra's and Hedra's colours are (alpha
//   is linear): glTF's linear factors are converted once, on import
//   (linearToSrgbValue), and MaterialX files say so per colour
//   (colorspace="srgb_texture"), so no colour is converted on the way
//   between a scene and its .mtlx files.
//
// Shared code: nothing here knows a program or the Hedra library.

// The texture slots, in this order everywhere (StandardMaterial3D's
// texture properties: classdb.as MATERIAL_TEXTURE_PROPS; the MaterialX
// node names: mtlx.as). The comment is the glTF texture and the channels
// read from it.
export enum PbrSlot {
    BaseColor = 0,             // baseColorTexture: RGB (sRGB), A alpha
    Metallic = 1,              // metallicRoughnessTexture: B
    Roughness = 2,             // metallicRoughnessTexture: G
    Normal = 3,                // normalTexture: RGB tangent-space normal
    Occlusion = 4,             // occlusionTexture: R
    Emissive = 5,              // emissiveTexture: RGB (sRGB)
    Clearcoat = 6,             // KHR_materials_clearcoat clearcoatTexture: R
    ClearcoatRoughness = 7,    // clearcoatRoughnessTexture: G
    ClearcoatNormal = 8,       // clearcoatNormalTexture: RGB
    SheenColor = 9,            // KHR_materials_sheen sheenColorTexture: RGB (sRGB)
    SheenRoughness = 10,       // sheenRoughnessTexture: A
    Specular = 11,             // KHR_materials_specular specularTexture: A
    SpecularColor = 12,        // specularColorTexture: RGB (sRGB)
    Transmission = 13,         // KHR_materials_transmission transmissionTexture: R
    Thickness = 14,            // KHR_materials_volume thicknessTexture: G
    Iridescence = 15,          // KHR_materials_iridescence iridescenceTexture: R
    IridescenceThickness = 16, // iridescenceThicknessTexture: G
    Anisotropy = 17,           // KHR_materials_anisotropy anisotropyTexture: RG direction, B strength
    DiffuseTransmission = 18,  // KHR_materials_diffuse_transmission diffuseTransmissionTexture: A
    DiffuseTransmissionColor = 19, // diffuseTransmissionColorTexture: RGB (sRGB)
}

// How many slots a material has.
export const PBR_SLOT_COUNT: i32 = 20;

// glTF's alpha modes (PbrMaterial.alphaMode).
export const PBR_ALPHA_OPAQUE: i32 = 0;
export const PBR_ALPHA_MASK: i32 = 1;
export const PBR_ALPHA_BLEND: i32 = 2;

// Whether the slot's colour channels are sRGB-encoded (glTF says which).
export function pbrSlotIsSrgb(slot: i32): bool {
    return slot == PbrSlot.BaseColor || slot == PbrSlot.Emissive || slot == PbrSlot.SheenColor
        || slot == PbrSlot.SpecularColor || slot == PbrSlot.DiffuseTransmissionColor;
}

// Milestone 15: the artboard a texture is drawn from, when its `path`
// names a Rive file (.riv) rather than an image: the artboard's name, the
// state machine an instance runs ("" for the artboard's default one) and
// the texture's size in pixels (0 x 0 for the artboard's own). MaterialX
// carries it as attributes of the image node's `file` input
// (docs/formats/MATERIALS.md, "Artboard textures"); glTF never has one.
// Milestone 67: also when a built project draws it again, the
// ArtboardTexture's render_target_update_mode (Godot's SubViewport numbers,
// PBR_ARTBOARD_WHEN_VISIBLE the default) and update_fps (0: no cap).
export const PBR_ARTBOARD_WHEN_VISIBLE: i32 = 2;
// Godot's names of the modes, by number (the MaterialX attribute's values).
export const PBR_ARTBOARD_MODES: StaticArray<string> = ["disabled", "once", "when_visible", "when_parent_visible", "always"];

export class PbrArtboard {
    artboard: string = "";
    stateMachine: string = "";
    width: i32 = 0;
    height: i32 = 0;
    updateMode: i32 = PBR_ARTBOARD_WHEN_VISIBLE;
    updateFps: f32 = 0;

    constructor(artboard: string = "") {
        this.artboard = artboard;
    }

    clone(): PbrArtboard {
        const a = new PbrArtboard(this.artboard);
        a.stateMachine = this.stateMachine;
        a.width = this.width;
        a.height = this.height;
        a.updateMode = this.updateMode;
        a.updateFps = this.updateFps;
        return a;
    }

    equals(o: PbrArtboard): bool {
        return this.artboard == o.artboard && this.stateMachine == o.stateMachine && this.width == o.width
            && this.height == o.height && this.updateMode == o.updateMode && this.updateFps == o.updateFps;
    }
}

// One texture of a material: the image, the UV set it samples
// (glTF's texCoord, or KHR_texture_transform's texCoord when it has one) and
// KHR_texture_transform's offset, rotation (radians, counter-clockwise as
// glTF has it) and scale, defaults the identity.
export class PbrTexture {
    // As the material wrote it: relative to the file that names it, a
    // `res://` path, or (a glTF file's embedded image) the importer's key.
    path: string = "";
    texCoord: i32 = 0;
    offset: StaticArray<f32> = [0, 0];
    rotation: f32 = 0;
    scale: StaticArray<f32> = [1, 1];
    // Milestone 15: set when `path` names a Rive file whose artboard the
    // texture is drawn from (PbrArtboard); null for an image.
    artboard: PbrArtboard? = null;

    constructor(path: string = "") {
        this.path = path;
    }

    // The transform is the identity (glTF writes no KHR_texture_transform).
    isIdentity(): bool {
        return this.offset[0] == 0 && this.offset[1] == 0 && this.rotation == 0 && this.scale[0] == 1 && this.scale[1] == 1;
    }

    clone(): PbrTexture {
        const t = new PbrTexture(this.path);
        t.texCoord = this.texCoord;
        t.offset = [this.offset[0], this.offset[1]];
        t.rotation = this.rotation;
        t.scale = [this.scale[0], this.scale[1]];
        const a = this.artboard;
        if (a != null) t.artboard = a.clone();
        return t;
    }

    equals(o: PbrTexture): bool {
        const a = this.artboard;
        const b = o.artboard;
        const sameArtboard = a == null ? b == null : b != null && a.equals(b);
        return this.path == o.path && this.texCoord == o.texCoord && this.offset[0] == o.offset[0]
            && this.offset[1] == o.offset[1] && this.rotation == o.rotation && this.scale[0] == o.scale[0]
            && this.scale[1] == o.scale[1] && sameArtboard;
    }
}

// A material, glTF's defaults (a material with no extension is exactly
// glTF's core material). Each extension's block is "absent" at its
// defaults: a writer leaves out an extension whose values are all defaults
// and that has no texture (hasClearcoat() and the like say which).
export class PbrMaterial {
    name: string = "";

    // Core (glTF 2.0).
    baseColor: StaticArray<f32> = [1, 1, 1, 1]; // sRGB rgb, linear alpha
    metallic: f32 = 1;
    roughness: f32 = 1;
    emissive: StaticArray<f32> = [0, 0, 0]; // sRGB
    normalScale: f32 = 1;
    occlusionStrength: f32 = 1;
    alphaMode: i32 = PBR_ALPHA_OPAQUE;
    alphaCutoff: f32 = 0.5;
    doubleSided: bool = false;

    // KHR_materials_emissive_strength.
    emissiveStrength: f32 = 1;
    // KHR_materials_unlit.
    unlit: bool = false;
    // KHR_materials_ior.
    ior: f32 = 1.5;
    // KHR_materials_specular.
    specular: f32 = 1;
    specularColor: StaticArray<f32> = [1, 1, 1]; // sRGB
    // KHR_materials_transmission.
    transmission: f32 = 0;
    // KHR_materials_volume. attenuationDistance 0 stands for glTF's
    // default, +infinity (glTF requires a distance above 0, so 0 is free).
    thickness: f32 = 0;
    attenuationDistance: f32 = 0;
    attenuationColor: StaticArray<f32> = [1, 1, 1]; // sRGB
    // KHR_materials_clearcoat.
    clearcoat: f32 = 0;
    clearcoatRoughness: f32 = 0;
    clearcoatNormalScale: f32 = 1;
    // KHR_materials_sheen.
    sheenColor: StaticArray<f32> = [0, 0, 0]; // sRGB
    sheenRoughness: f32 = 0;
    // KHR_materials_iridescence.
    iridescence: f32 = 0;
    iridescenceIor: f32 = 1.3;
    iridescenceThicknessMinimum: f32 = 100;
    iridescenceThicknessMaximum: f32 = 400;
    // KHR_materials_anisotropy (rotation in radians).
    anisotropyStrength: f32 = 0;
    anisotropyRotation: f32 = 0;
    // KHR_materials_dispersion.
    dispersion: f32 = 0;
    // KHR_materials_diffuse_transmission.
    diffuseTransmission: f32 = 0;
    diffuseTransmissionColor: StaticArray<f32> = [1, 1, 1]; // sRGB

    // By PbrSlot; null for no texture.
    textures: Array<PbrTexture?> = emptySlots();

    // What Hedra's StandardMaterial3D has and glTF has not, carried so a
    // material read from and written to an .mtlx file keeps it (glTF
    // writers ignore it): Godot's cull_mode front (glTF culls the back or
    // nothing), and the vertex colour's two switches (milestone 13).
    cullFront: bool = false;
    vertexColorUseAsAlbedo: bool = false;
    vertexColorIsSrgb: bool = false;

    constructor(name: string = "") {
        this.name = name;
    }

    texture(slot: i32): PbrTexture? {
        return this.textures[slot];
    }

    setTexture(slot: i32, t: PbrTexture?): void {
        this.textures[slot] = t;
    }

    // Each extension is in use: a value off its default, or a texture.
    hasEmissiveStrength(): bool { return this.emissiveStrength != 1; }
    hasIor(): bool { return this.ior != 1.5; }
    hasSpecular(): bool {
        return this.specular != 1 || !rgbIs(this.specularColor, 1) || this.has(PbrSlot.Specular) || this.has(PbrSlot.SpecularColor);
    }
    hasTransmission(): bool { return this.transmission != 0 || this.has(PbrSlot.Transmission); }
    hasVolume(): bool {
        return this.thickness != 0 || this.attenuationDistance != 0 || !rgbIs(this.attenuationColor, 1) || this.has(PbrSlot.Thickness);
    }
    hasClearcoat(): bool {
        return this.clearcoat != 0 || this.has(PbrSlot.Clearcoat) || this.has(PbrSlot.ClearcoatRoughness)
            || this.has(PbrSlot.ClearcoatNormal);
    }
    hasSheen(): bool {
        return !rgbIs(this.sheenColor, 0) || this.sheenRoughness != 0 || this.has(PbrSlot.SheenColor) || this.has(PbrSlot.SheenRoughness);
    }
    hasIridescence(): bool {
        return this.iridescence != 0 || this.has(PbrSlot.Iridescence) || this.has(PbrSlot.IridescenceThickness);
    }
    hasAnisotropy(): bool { return this.anisotropyStrength != 0 || this.has(PbrSlot.Anisotropy); }
    hasDispersion(): bool { return this.dispersion != 0; }
    hasDiffuseTransmission(): bool {
        return this.diffuseTransmission != 0 || this.has(PbrSlot.DiffuseTransmission) || this.has(PbrSlot.DiffuseTransmissionColor);
    }

    private has(slot: i32): bool {
        return this.textures[slot] != null;
    }

    clone(): PbrMaterial {
        const m = new PbrMaterial(this.name);
        m.baseColor = copy4(this.baseColor);
        m.metallic = this.metallic;
        m.roughness = this.roughness;
        m.emissive = copy3(this.emissive);
        m.normalScale = this.normalScale;
        m.occlusionStrength = this.occlusionStrength;
        m.alphaMode = this.alphaMode;
        m.alphaCutoff = this.alphaCutoff;
        m.doubleSided = this.doubleSided;
        m.emissiveStrength = this.emissiveStrength;
        m.unlit = this.unlit;
        m.ior = this.ior;
        m.specular = this.specular;
        m.specularColor = copy3(this.specularColor);
        m.transmission = this.transmission;
        m.thickness = this.thickness;
        m.attenuationDistance = this.attenuationDistance;
        m.attenuationColor = copy3(this.attenuationColor);
        m.clearcoat = this.clearcoat;
        m.clearcoatRoughness = this.clearcoatRoughness;
        m.clearcoatNormalScale = this.clearcoatNormalScale;
        m.sheenColor = copy3(this.sheenColor);
        m.sheenRoughness = this.sheenRoughness;
        m.iridescence = this.iridescence;
        m.iridescenceIor = this.iridescenceIor;
        m.iridescenceThicknessMinimum = this.iridescenceThicknessMinimum;
        m.iridescenceThicknessMaximum = this.iridescenceThicknessMaximum;
        m.anisotropyStrength = this.anisotropyStrength;
        m.anisotropyRotation = this.anisotropyRotation;
        m.dispersion = this.dispersion;
        m.diffuseTransmission = this.diffuseTransmission;
        m.diffuseTransmissionColor = copy3(this.diffuseTransmissionColor);
        for (let i = 0; i < PBR_SLOT_COUNT; i++) {
            const t = this.textures[i];
            m.textures[i] = t != null ? t.clone() : null;
        }
        m.cullFront = this.cullFront;
        m.vertexColorUseAsAlbedo = this.vertexColorUseAsAlbedo;
        m.vertexColorIsSrgb = this.vertexColorIsSrgb;
        return m;
    }

    // Every field equal, exactly (the round-trip tests' measure; a test
    // that crosses a colour conversion compares with pbrDiff instead).
    equals(o: PbrMaterial): bool {
        return pbrDiff(this, o, 0).length == 0;
    }
}

// The fields of `a` and `b` further apart than `eps`, as
// "name: a != b" lines (empty when they agree): what a round-trip test
// prints when it fails. Texture paths, UV sets and booleans compare exactly.
export function pbrDiff(a: PbrMaterial, b: PbrMaterial, eps: f32): Array<string> {
    const out: Array<string> = [];
    if (a.name != b.name) out.push("name: " + a.name + " != " + b.name);
    nums(out, "baseColor", a.baseColor, b.baseColor, eps);
    num(out, "metallic", a.metallic, b.metallic, eps);
    num(out, "roughness", a.roughness, b.roughness, eps);
    nums(out, "emissive", a.emissive, b.emissive, eps);
    num(out, "normalScale", a.normalScale, b.normalScale, eps);
    num(out, "occlusionStrength", a.occlusionStrength, b.occlusionStrength, eps);
    if (a.alphaMode != b.alphaMode) out.push("alphaMode: " + a.alphaMode.toString() + " != " + b.alphaMode.toString());
    num(out, "alphaCutoff", a.alphaCutoff, b.alphaCutoff, eps);
    flag(out, "doubleSided", a.doubleSided, b.doubleSided);
    num(out, "emissiveStrength", a.emissiveStrength, b.emissiveStrength, eps);
    flag(out, "unlit", a.unlit, b.unlit);
    num(out, "ior", a.ior, b.ior, eps);
    num(out, "specular", a.specular, b.specular, eps);
    nums(out, "specularColor", a.specularColor, b.specularColor, eps);
    num(out, "transmission", a.transmission, b.transmission, eps);
    num(out, "thickness", a.thickness, b.thickness, eps);
    num(out, "attenuationDistance", a.attenuationDistance, b.attenuationDistance, eps);
    nums(out, "attenuationColor", a.attenuationColor, b.attenuationColor, eps);
    num(out, "clearcoat", a.clearcoat, b.clearcoat, eps);
    num(out, "clearcoatRoughness", a.clearcoatRoughness, b.clearcoatRoughness, eps);
    num(out, "clearcoatNormalScale", a.clearcoatNormalScale, b.clearcoatNormalScale, eps);
    nums(out, "sheenColor", a.sheenColor, b.sheenColor, eps);
    num(out, "sheenRoughness", a.sheenRoughness, b.sheenRoughness, eps);
    num(out, "iridescence", a.iridescence, b.iridescence, eps);
    num(out, "iridescenceIor", a.iridescenceIor, b.iridescenceIor, eps);
    num(out, "iridescenceThicknessMinimum", a.iridescenceThicknessMinimum, b.iridescenceThicknessMinimum, eps);
    num(out, "iridescenceThicknessMaximum", a.iridescenceThicknessMaximum, b.iridescenceThicknessMaximum, eps);
    num(out, "anisotropyStrength", a.anisotropyStrength, b.anisotropyStrength, eps);
    num(out, "anisotropyRotation", a.anisotropyRotation, b.anisotropyRotation, eps);
    num(out, "dispersion", a.dispersion, b.dispersion, eps);
    num(out, "diffuseTransmission", a.diffuseTransmission, b.diffuseTransmission, eps);
    nums(out, "diffuseTransmissionColor", a.diffuseTransmissionColor, b.diffuseTransmissionColor, eps);
    for (let i = 0; i < PBR_SLOT_COUNT; i++) {
        const ta = a.textures[i];
        const tb = b.textures[i];
        const at = "textures[" + i.toString() + "]";
        if (ta == null || tb == null) {
            if (ta != null || tb != null) out.push(at + ": " + (ta != null ? ta.path : "none") + " != " + (tb != null ? tb.path : "none"));
            continue;
        }
        if (ta.path != tb.path) out.push(at + ".path: " + ta.path + " != " + tb.path);
        if (ta.texCoord != tb.texCoord) out.push(at + ".texCoord: " + ta.texCoord.toString() + " != " + tb.texCoord.toString());
        nums2(out, at + ".offset", ta.offset, tb.offset, eps);
        num(out, at + ".rotation", ta.rotation, tb.rotation, eps);
        nums2(out, at + ".scale", ta.scale, tb.scale, eps);
        artboardDiff(out, at + ".artboard", ta.artboard, tb.artboard);
    }
    flag(out, "cullFront", a.cullFront, b.cullFront);
    flag(out, "vertexColorUseAsAlbedo", a.vertexColorUseAsAlbedo, b.vertexColorUseAsAlbedo);
    flag(out, "vertexColorIsSrgb", a.vertexColorIsSrgb, b.vertexColorIsSrgb);
    return out;
}

// The artboard of a texture compares exactly (names and whole pixels).
function artboardDiff(out: Array<string>, at: string, a: PbrArtboard?, b: PbrArtboard?): void {
    if (a == null || b == null) {
        if (a != null || b != null) out.push(at + ": " + artboardText(a) + " != " + artboardText(b));
        return;
    }
    if (a.artboard != b.artboard) out.push(at + ".artboard: " + a.artboard + " != " + b.artboard);
    if (a.stateMachine != b.stateMachine) out.push(at + ".stateMachine: " + a.stateMachine + " != " + b.stateMachine);
    if (a.width != b.width || a.height != b.height) {
        out.push(at + ".size: " + a.width.toString() + "x" + a.height.toString() + " != " + b.width.toString() + "x" + b.height.toString());
    }
}

function artboardText(a: PbrArtboard?): string {
    return a != null ? a.artboard : "none";
}

function emptySlots(): Array<PbrTexture?> {
    const a = new Array<PbrTexture?>(PBR_SLOT_COUNT);
    for (let i = 0; i < PBR_SLOT_COUNT; i++) a[i] = null;
    return a;
}

function rgbIs(c: StaticArray<f32>, v: f32): bool {
    return c[0] == v && c[1] == v && c[2] == v;
}

function copy3(c: StaticArray<f32>): StaticArray<f32> {
    return [c[0], c[1], c[2]];
}

function copy4(c: StaticArray<f32>): StaticArray<f32> {
    return [c[0], c[1], c[2], c[3]];
}

function num(out: Array<string>, name: string, a: f32, b: f32, eps: f32): void {
    const d = a > b ? a - b : b - a;
    if (d > eps || isNaN(a) != isNaN(b)) out.push(name + ": " + a.toString() + " != " + b.toString());
}

function nums(out: Array<string>, name: string, a: StaticArray<f32>, b: StaticArray<f32>, eps: f32): void {
    for (let i = 0; i < a.length; i++) num(out, name + "[" + i.toString() + "]", a[i], b[i], eps);
}

function nums2(out: Array<string>, name: string, a: StaticArray<f32>, b: StaticArray<f32>, eps: f32): void {
    num(out, name + "[0]", a[0], b[0], eps);
    num(out, name + "[1]", a[1], b[1], eps);
}

function flag(out: Array<string>, name: string, a: bool, b: bool): void {
    if (a != b) out.push(name + ": " + (a ? "true" : "false") + " != " + (b ? "true" : "false"));
}
