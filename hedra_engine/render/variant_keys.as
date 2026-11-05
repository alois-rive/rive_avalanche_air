// The keys of the surface shader's variants (./variant.as says what a key
// is; docs/engine/SHADING.md, "Specialised shaders"): pure functions of the
// values a draw's uniforms hold and of the frame it is drawn in, no GPU,
// so that the renderer (./gpu/variants.as), the tools and `hedra build`
// (hedra_compiler's build/variants.as, which plans a built scene's frames
// without a device) all find the same key for the same draw.
//
// A bit is set when a draw of the key may take the branch its constant
// guards; clear only when no draw of the key can (the branch's condition
// is false for every one of them), so that a variant draws what the
// ubershader draws, bit for bit:
//   - the material's bits are read from the very uniform the draw binds
//     (MaterialUniform, and MaterialExtUniform for an extended material):
//     a texture's T_* bit, the alpha mode, vertex colour, unlit, and each
//     glTF lobe whose factor is not 0 or less (a lobe's branch tests the
//     factor times its texture, at most the factor; NaN keeps the bit);
//   - the frame's are read from what the frame declares, not from what a
//     view's planning chose (a light, a decal, a shadowed light, fog,
//     volumetric fog, a probe, SSAO, the screen refraction): every view of
//     the frame, and every camera, gets the same bits, and what a view
//     leaves out is a branch its draws skip at run time as before;
//   - the item's: emerging, fading, the baked probes' light, and the faces'
//     flags (a mesh with hidden faces, or the edit object's selection).
// Every function allocates nothing.

import { DrawItem, RenderFrame, SHADE_LIT, SHADE_MATERIAL, SKY_NONE, emerging, fading } from "./frame";
import { PostPlan } from "./post";
import { SCREEN_REFRACTION } from "./screen";
import { ALPHA_BLEND, ALPHA_MASK } from "./material";
import { PbrSlot } from "../material/pbr";
import {
    F_HIDDEN, MAT_EXT, MAT_ROUGHNESS_LAYER, MAT_UNLIT, MAT_VERTEX_COLOR, MaterialExtUniform, MaterialUniform, T_BASE,
    T_EMISSION, T_METALLIC_ROUGHNESS, T_NORMAL, T_OCCLUSION,
} from "./gpu/layouts";
import {
    VB_D_AMBIENT_FLAT, VB_D_AMBIENT_GRADIENT, VB_D_AMBIENT_SHIFT, VB_D_AMBIENT_SKY, VB_D_DECALS, VB_D_EMERGE,
    VB_D_FACE_FLAGS, VB_D_FADE, VB_D_FOG, VB_D_FOG_VOLUMES, VB_D_LIGHTS, VB_D_LIT, VB_D_PROBES, VB_D_PROBE_GI,
    VB_D_SCREEN_REFRACTION, VB_D_SHADOWS, VB_D_SSAO, VB_M_ALPHA_BLEND, VB_M_ALPHA_MASK, VB_M_ANISOTROPY, VB_M_CLEARCOAT,
    VB_M_DIFFUSE_TRANSMISSION, VB_M_DISPERSION, VB_M_EXT, VB_M_EXT_LAYERS, VB_M_IRIDESCENCE, VB_M_ROUGHNESS_LAYER,
    VB_M_SHEEN, VB_M_TEX_BASE, VB_M_TEX_EMISSION, VB_M_TEX_MR, VB_M_TEX_NORMAL, VB_M_TEX_OCCLUSION, VB_M_TRANSMISSION,
    VB_M_UNLIT, VB_M_VERTEX_COLOR, VB_M_VOLUME,
} from "./variant";

// A factor's branch may be taken: it is not 0 or less (NaN included, as
// the shader's clamp of NaN is the target's own).
function maybe(v: f32): bool {
    return !(v <= 0);
}

// Where slot `s`'s texture is in an extended material's uniform (its
// ext_where): 0 for none.
function whereOf(ext: MaterialExtUniform, s: i32): f32 {
    return unchecked(ext.xf[s * 2 + 1]).w;
}

// The material part of a key (VB_M_*) for a draw that binds `u`, and `ext`
// for an extended material (null for every other: its extended entries
// are never drawn).
export function materialVariantBits(u: MaterialUniform, ext: MaterialExtUniform?): u32 {
    let bits: u32 = 0;
    const tex = u.flags.x;
    if ((tex & T_BASE) != 0) bits |= VB_M_TEX_BASE;
    if ((tex & T_NORMAL) != 0) bits |= VB_M_TEX_NORMAL;
    if ((tex & T_METALLIC_ROUGHNESS) != 0) bits |= VB_M_TEX_MR;
    if ((tex & T_EMISSION) != 0) bits |= VB_M_TEX_EMISSION;
    if ((tex & T_OCCLUSION) != 0) bits |= VB_M_TEX_OCCLUSION;
    const alpha = u.flags.y;
    if (alpha == ALPHA_MASK) bits |= VB_M_ALPHA_MASK;
    if (alpha == ALPHA_BLEND) bits |= VB_M_ALPHA_BLEND;
    const w = u.flags.w;
    if ((w & MAT_VERTEX_COLOR) != 0) bits |= VB_M_VERTEX_COLOR;
    if ((w & MAT_EXT) == 0 || ext == null) return bits;
    bits |= VB_M_EXT;
    if ((w & MAT_UNLIT) != 0) bits |= VB_M_UNLIT;
    if ((w & MAT_ROUGHNESS_LAYER) != 0) bits |= VB_M_ROUGHNESS_LAYER;
    // (the extended path's metallic and roughness reads, as the plain
    // path's metallic-roughness texture)
    if (whereOf(ext, PbrSlot.Metallic) > 0.5 || whereOf(ext, PbrSlot.Roughness) > 0.5) bits |= VB_M_TEX_MR;
    for (let s = <i32>PbrSlot.Clearcoat; s <= <i32>PbrSlot.DiffuseTransmissionColor; s++) {
        if (whereOf(ext, s) > 0.5) {
            bits |= VB_M_EXT_LAYERS;
            break;
        }
    }
    const e = ext.ext;
    const e1 = unchecked(e[1]);
    const e2 = unchecked(e[2]);
    const e4 = unchecked(e[4]);
    if (maybe(unchecked(e[3]).x)) bits |= VB_M_CLEARCOAT;
    if (maybe(e4.x) || maybe(e4.y) || maybe(e4.z)) bits |= VB_M_SHEEN;
    if (maybe(e1.y)) bits |= VB_M_TRANSMISSION;
    if (maybe(unchecked(e[5]).x)) bits |= VB_M_IRIDESCENCE;
    if (maybe(unchecked(e[6]).x)) bits |= VB_M_ANISOTROPY;
    if (maybe(unchecked(e[7]).w)) bits |= VB_M_DIFFUSE_TRANSMISSION;
    if (maybe(e1.w)) bits |= VB_M_VOLUME;
    if (maybe(e2.w)) bits |= VB_M_DISPERSION;
    return bits;
}

// Whether frame `f` draws in a shading its variants serve (the lit and the
// material shadings, with the materials bound): the others draw with the
// ubershader.
export function frameHasVariants(f: RenderFrame): bool {
    return f.materialMode && (f.shading == SHADE_LIT || f.shading == SHADE_MATERIAL);
}

// The frame-wide draw bits of frame `f` (VB_D_*, the vertex kind left 0):
// the lit shading's, from what the frame declares (see the header); the
// material shading has none of them (its draws read neither the lights nor
// the environment). `post` and `shadowed` (the view's post plan and shadow
// atlas, which the renderer passes) are not read: a view's plan is a
// subset of the frame's declarations, and reading them would give two
// views of one frame two keys.
export function frameVariantBits(f: RenderFrame, post: PostPlan? = null, shadowed: bool = false): u32 {
    if (f.shading != SHADE_LIT) return 0;
    let bits: u32 = VB_D_LIT;
    const lights = f.lights;
    if (lights.length > 0) {
        bits |= VB_D_LIGHTS;
        for (let i = 0; i < lights.length; i++) {
            if (unchecked(lights[i]).shadow) {
                bits |= VB_D_SHADOWS;
                break;
            }
        }
    }
    if (f.decals.length > 0) bits |= VB_D_DECALS;
    const e = f.environment;
    if (e.fog.enabled) bits |= VB_D_FOG;
    if (f.volumetricFog.enabled) bits |= VB_D_FOG_VOLUMES;
    const p = f.probes;
    if (p != null && p.list.length > 0) bits |= VB_D_PROBES;
    if (e.ssao.enabled) bits |= VB_D_SSAO;
    if (e.screenRefraction.enabled && (f.screenEffects & SCREEN_REFRACTION) != 0) bits |= VB_D_SCREEN_REFRACTION;
    // (the shader's order: a Sky's light (SKY_IBL: a lit frame with a Sky
    // has its image-based light, sky.as IblCache), else the gradient's,
    // else the flat colour)
    let ambient = VB_D_AMBIENT_FLAT;
    if (e.skyDesc.kind != SKY_NONE) ambient = VB_D_AMBIENT_SKY;
    else if (e.ambientFromSky) ambient = VB_D_AMBIENT_GRADIENT;
    return bits | (ambient << VB_D_AMBIENT_SHIFT);
}

// Whether `d`'s mesh has a face hidden in its model (F_HIDDEN on a vertex:
// the main pass discards it).
export function meshHidesFaces(d: DrawItem): bool {
    const g = d.mesh;
    if (g == null) return false;
    const verts = g.verts;
    for (let i = 0; i < verts.length; i++) if ((unchecked(verts[i]).flags & F_HIDDEN) != 0) return true;
    return false;
}

// The item's own draw bits (VB_D_*) in frame `f`, `hidden` whether its
// mesh hides faces (meshHidesFaces, or the uploaded mesh's own record):
// emerging (OBJ_EMERGE), fading and the baked probes' light (the lit
// shading's), and the faces' flags.
export function itemVariantBitsOf(f: RenderFrame, d: DrawItem, hidden: bool): u32 {
    let bits: u32 = 0;
    if (emerging(d)) bits |= VB_D_EMERGE;
    if (hidden || d.edit) bits |= VB_D_FACE_FLAGS;
    if (f.shading == SHADE_LIT) {
        if (fading(d)) bits |= VB_D_FADE;
        const sh = d.probeSh;
        if (sh != null && sh.length > 0) bits |= VB_D_PROBE_GI;
    }
    return bits;
}

// itemVariantBitsOf with the mesh's vertices looked at (the tools' and the
// build's planning; the renderer asks the uploaded mesh, which knows).
export function itemVariantBits(f: RenderFrame, d: DrawItem): u32 {
    return itemVariantBitsOf(f, d, meshHidesFaces(d));
}
