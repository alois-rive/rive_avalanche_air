// The surface shader's variants (docs/engine/PERFORMANCE.md,
// "Specialised shaders"): Godot's StandardMaterial3D writes its shader
// from the features it enables and Forward+ specialises its pipelines,
// keeping an ubershader for the time a specialised one compiles; Hedra
// keeps every feature of shaders/render/surface.wgsl behind a module
// constant (SPEC_<name>, true in the file itself, the ubershader), and a
// variant is the same file with the constants of the features its draws
// never use set false, so the backend's compiler drops their code.
//
// A variant's key is what a draw uses, read from the very values its
// uniforms hold (so that the branch a false constant removes is one the
// draw would not have taken: specialisation is exact, every picture the
// same):
//   - the low 32 bits, the material's (VB_M_*: its textures, alpha mode,
//     vertex colour, unlit, glTF's lobes with a factor above 0), from its
//     MaterialUniform and MaterialExtUniform (material.as keeps them per
//     material key);
//   - the high 32 bits, the draw's (VB_D_*: its vertex kind, the shading
//     mode, the frame's lights, shadows, decals, fogs, probes, SSAO, screen
//     refraction and ambient, the item's emerge, fade, probe light and
//     faces' flags).
// A frame-wide bit is set for every draw of a frame that has the feature
// (an item without a decal in a frame with decals keeps the guarded
// branch, which it skips at run time as before): few keys, and every key
// a built scene can reach is known to the compiler from the scene alone.
//
// `hedra build` writes each key a built scene reaches (its default state,
// and the states its bindings and timelines reach) as a shader asset
// rive compiles for every backend (variantAssetName); the run time draws
// a key it has with its variant and any other with the ubershader; the
// tools compile a key on first use, as they do a custom shader
// (../shader/variants.as). Shading modes other than lit and material, and
// the passes other than the main pass (shadow, id, normal-depth), always
// draw with the ubershader.
//
// The key functions are variant_keys.as's; ./gpu/variants.as picks a
// draw's pipeline by them, ../scene/runtime/variant_assets.as finds a
// Rive project's modules, and hedra_compiler's build/variants.as writes
// the text and plans the keys a built scene reaches.

// The key of the ubershader itself (no variant).
export const VARIANT_UBER: u64 = 0xFFFFFFFFFFFFFFFF;

// The material's bits (the key's low 32).
export const VB_M_TEX_BASE: u32 = 1 << 0;
export const VB_M_TEX_NORMAL: u32 = 1 << 1;
export const VB_M_TEX_MR: u32 = 1 << 2;
export const VB_M_TEX_EMISSION: u32 = 1 << 3;
export const VB_M_TEX_OCCLUSION: u32 = 1 << 4;
export const VB_M_VERTEX_COLOR: u32 = 1 << 5;
export const VB_M_EXT: u32 = 1 << 6;
export const VB_M_UNLIT: u32 = 1 << 7;
export const VB_M_ALPHA_MASK: u32 = 1 << 8;
export const VB_M_ALPHA_BLEND: u32 = 1 << 9;
export const VB_M_CLEARCOAT: u32 = 1 << 10;
export const VB_M_SHEEN: u32 = 1 << 11;
export const VB_M_TRANSMISSION: u32 = 1 << 12;
export const VB_M_IRIDESCENCE: u32 = 1 << 13;
export const VB_M_ANISOTROPY: u32 = 1 << 14;
export const VB_M_DIFFUSE_TRANSMISSION: u32 = 1 << 15;
export const VB_M_VOLUME: u32 = 1 << 16;
export const VB_M_DISPERSION: u32 = 1 << 17;
export const VB_M_EXT_LAYERS: u32 = 1 << 18;
export const VB_M_ROUGHNESS_LAYER: u32 = 1 << 19;

// The draw's bits (the key's high 32). The vertex kind is a choice of
// entry points, not a feature: two bits, VB_D_VERTEX_*.
export const VB_D_VERTEX_MASK: u32 = 3;
export const VB_D_VERTEX_PLAIN: u32 = 0;
export const VB_D_VERTEX_INSTANCED: u32 = 1;
export const VB_D_VERTEX_SKINNED: u32 = 2;
export const VB_D_VERTEX_LIGHTMAP: u32 = 3;
export const VB_D_LIT: u32 = 1 << 2;
export const VB_D_LIGHTS: u32 = 1 << 3;
export const VB_D_SHADOWS: u32 = 1 << 4;
export const VB_D_DECALS: u32 = 1 << 5;
export const VB_D_FOG: u32 = 1 << 6;
export const VB_D_FOG_VOLUMES: u32 = 1 << 7;
export const VB_D_PROBES: u32 = 1 << 8;
export const VB_D_PROBE_GI: u32 = 1 << 9;
export const VB_D_SSAO: u32 = 1 << 10;
export const VB_D_SCREEN_REFRACTION: u32 = 1 << 11;
// The ambient light's kind, two bits: a flat colour, the gradient, a Sky,
// or any of the three (the ubershader's code for all three: the kind a
// binding or a timeline may change, variant_keys.as; VARIANT_UBER's).
export const VB_D_AMBIENT_SHIFT: u32 = 12;
export const VB_D_AMBIENT_MASK: u32 = 3 << 12;
export const VB_D_AMBIENT_FLAT: u32 = 0;
export const VB_D_AMBIENT_GRADIENT: u32 = 1;
export const VB_D_AMBIENT_SKY: u32 = 2;
export const VB_D_AMBIENT_ANY: u32 = 3;
export const VB_D_EMERGE: u32 = 1 << 14;
export const VB_D_FADE: u32 = 1 << 15;
export const VB_D_FACE_FLAGS: u32 = 1 << 16;

// The WGSL constants of the bits, by bit (index 0 to 31 the material's,
// 32 to 63 the draw's; "" for a bit that is not a constant: the vertex
// kind and the ambient's choice, and the bits not used). surface.wgsl
// declares each as `const SPEC_<NAME>: bool = true;` in its spec block.
export const VARIANT_BIT_NAMES: StaticArray<string> = [
    "SPEC_TEX_BASE", "SPEC_TEX_NORMAL", "SPEC_TEX_MR", "SPEC_TEX_EMISSION", "SPEC_TEX_OCCLUSION",
    "SPEC_VERTEX_COLOR", "SPEC_EXT", "SPEC_UNLIT", "SPEC_ALPHA_MASK", "SPEC_ALPHA_BLEND",
    "SPEC_CLEARCOAT", "SPEC_SHEEN", "SPEC_TRANSMISSION", "SPEC_IRIDESCENCE", "SPEC_ANISOTROPY",
    "SPEC_DIFFUSE_TRANSMISSION", "SPEC_VOLUME", "SPEC_DISPERSION", "SPEC_EXT_LAYERS", "SPEC_ROUGHNESS_LAYER",
    "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "SPEC_LIT", "SPEC_LIGHTS", "SPEC_SHADOWS", "SPEC_DECALS", "SPEC_FOG", "SPEC_FOG_VOLUMES",
    "SPEC_PROBES", "SPEC_PROBE_GI", "SPEC_SSAO", "SPEC_SCREEN_REFRACTION", "", "", "SPEC_EMERGE", "SPEC_FADE",
    "SPEC_FACE_FLAGS", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
];

// The constants of the spec block that are not bits (after the bits'):
// the ambient light's three, of which the key's two bits keep one (or, with
// VB_D_AMBIENT_ANY, all three), and the shading modes' two, a variant being
// drawn only in the lit or the material shading: SPEC_MATERIAL_MODE is true
// in a variant of the material shading (VB_D_LIT clear), SPEC_OTHER_MODES
// in none.
export const VARIANT_SPEC_EXTRA: StaticArray<string> = [
    "SPEC_AMBIENT_FLAT", "SPEC_AMBIENT_GRADIENT", "SPEC_AMBIENT_SKY", "SPEC_MATERIAL_MODE", "SPEC_OTHER_MODES",
];

// The bits a key's material part may hold, and its draw part (the vertex
// kind and the ambient's field included); the rest are 0 in every key.
export const VB_M_ALL: u32 = (1 << 20) - 1;
export const VB_D_ALL: u32 = (1 << 17) - 1;

// The value key `key` gives the spec block's constant `name` (one of the
// VARIANT_BIT_NAMES or VARIANT_SPEC_EXTRA): true keeps the feature's code.
// Every constant is true for VARIANT_UBER.
export function variantSpecValue(key: u64, name: string): bool {
    if (key == VARIANT_UBER) return true;
    const draw = variantDrawBits(key);
    const ambient = (draw & VB_D_AMBIENT_MASK) >> VB_D_AMBIENT_SHIFT;
    if (name == "SPEC_AMBIENT_FLAT") return ambient == VB_D_AMBIENT_FLAT || ambient == VB_D_AMBIENT_ANY;
    if (name == "SPEC_AMBIENT_GRADIENT") return ambient == VB_D_AMBIENT_GRADIENT || ambient == VB_D_AMBIENT_ANY;
    if (name == "SPEC_AMBIENT_SKY") return ambient == VB_D_AMBIENT_SKY || ambient == VB_D_AMBIENT_ANY;
    if (name == "SPEC_MATERIAL_MODE") return (draw & VB_D_LIT) == 0;
    if (name == "SPEC_OTHER_MODES") return false;
    for (let i = 0; i < VARIANT_BIT_NAMES.length; i++) {
        if (unchecked(VARIANT_BIT_NAMES[i]) == name) return ((key >> <u64>i) & 1) != 0;
    }
    return true;
}

// The names of the features key `key` keeps (its set bits' SPEC_ names, in
// bit order, then the ambient light's kind and the shading), for `inspect
// --variants` and the tools' messages: "SPEC_TEX_BASE SPEC_LIT ... sky".
export function variantFeatureNames(key: u64): Array<string> {
    const out = new Array<string>();
    if (key == VARIANT_UBER) {
        out.push("ubershader");
        return out;
    }
    for (let i = 0; i < VARIANT_BIT_NAMES.length; i++) {
        const n = unchecked(VARIANT_BIT_NAMES[i]);
        if (n.length > 0 && ((key >> <u64>i) & 1) != 0) out.push(n);
    }
    const draw = variantDrawBits(key);
    const kinds: StaticArray<string> = ["plain", "instanced", "skinned", "lightmap"];
    out.push("vertex:" + kinds[<i32>(draw & VB_D_VERTEX_MASK)]);
    if ((draw & VB_D_LIT) != 0) {
        const ambients: StaticArray<string> = ["flat", "gradient", "sky", "any"];
        out.push("ambient:" + ambients[<i32>((draw & VB_D_AMBIENT_MASK) >> VB_D_AMBIENT_SHIFT)]);
    } else {
        out.push("shading:material");
    }
    return out;
}

// The asset name's stem: hedra_shaders/<project>/surface_<16 hex digits>.
export const SURFACE_VARIANT_PREFIX: string = "surface_";

// A key: the draw's bits over the material's.
export function variantKey(materialBits: u32, drawBits: u32): u64 {
    return (<u64>drawBits << 32) | <u64>materialBits;
}

export function variantMaterialBits(key: u64): u32 {
    return <u32>(key & 0xFFFFFFFF);
}

export function variantDrawBits(key: u64): u32 {
    return <u32>(key >> 32);
}

export function variantVertexKind(key: u64): u32 {
    return variantDrawBits(key) & VB_D_VERTEX_MASK;
}

// The key as 16 lower-case hex digits (the asset name's, the cache's).
export function variantKeyHex(key: u64): string {
    const digits = "0123456789abcdef";
    let s = "";
    for (let i = 15; i >= 0; i--) {
        const n = <i32>((key >> (<u64>i * 4)) & 0xF);
        s += digits.charAt(n);
    }
    return s;
}

// The Rive asset name of variant `key` in the Hedra project `project` (its
// path in the Rive project, "" at its root), as custom shaders' are
// (../shader/program.as shaderAssetName): "hedra_shaders/world/surface_...".
export function variantAssetName(project: string, key: u64): string {
    return "hedra_shaders/" + (project.length > 0 ? project + "/" : "") + SURFACE_VARIANT_PREFIX + variantKeyHex(key);
}
