// Where a Rive project's surface shader variants come from at run time
// (docs/engine/SHADING.md, "Specialised shaders";
// ../../render/shader/variants.as): `hedra build` wrote each key a built
// scene reaches as hedra_shaders/<project>/surface_<key>.wgsl, rive
// compiled it with the library for every backend, and the module is the
// shader asset of that name (../../render/variant.as variantAssetName),
// which `Context.shader` gives. One source per project a runtime draws,
// each key looked up once, the first time a draw has it, and kept (a later
// frame asks a map by u64: no allocation); a key the project does not hold
// is kept as a miss and drawn with the ubershader.
//
// The keys a draw has at run time are the keys the build planned when both
// OR in the same volatile bits (variantVolatileBits: the features a
// binding, a timeline, a state machine or a script of the scene may turn
// on): each scene instance draws through a ScopedSurfaceVariants of its
// own, its project's source seen with its tree's bits.

import { Context } from "rive/host";
import { GPUShaderModule } from "rive/gpu";
import {
    SurfaceVariantSource, VARIANT_READY, VARIANT_UNAVAILABLE, installedSurfaceVariants,
} from "../../render/shader/variants";
import {
    VARIANT_UBER, VB_D_AMBIENT_ANY, VB_D_AMBIENT_SHIFT, VB_D_DECALS, VB_D_EMERGE, VB_D_FADE, VB_D_FOG, VB_D_FOG_VOLUMES,
    VB_D_LIGHTS, VB_D_PROBES, VB_D_SCREEN_REFRACTION, VB_D_SHADOWS, VB_D_SSAO, VB_M_ALPHA_BLEND, VB_M_ALPHA_MASK,
    VB_M_ANISOTROPY, VB_M_CLEARCOAT, VB_M_DIFFUSE_TRANSMISSION, VB_M_DISPERSION, VB_M_EXT_LAYERS, VB_M_IRIDESCENCE,
    VB_M_SHEEN, VB_M_TEX_BASE, VB_M_TEX_EMISSION, VB_M_TEX_MR, VB_M_TEX_NORMAL, VB_M_TEX_OCCLUSION, VB_M_TRANSMISSION,
    VB_M_UNLIT, VB_M_VERTEX_COLOR, VB_M_VOLUME, variantAssetName,
} from "../../render/variant";
import { SceneTree } from "../tree/tree";
import { SceneNode } from "../tree/node";
import { isA } from "../classdb";
import { SceneRenderOptions } from "../render/adapter";
import { sceneAnimationsOf } from "../anim/scene_anims";

// The draw bits of the features a script may turn on: every frame-wide
// one (a light, its shadow, a decal, a fog, volumetric fog, a probe, SSAO,
// the screen refraction, any ambient light) and an item's emerge and fade.
// A script does not change a material's mode or a mesh's faces through a
// property a scene declares (a material it makes is a new key, drawn with
// the ubershader until a build holds it).
export const SCRIPT_VOLATILE_DRAW: u32 = VB_D_LIGHTS | VB_D_SHADOWS | VB_D_DECALS | VB_D_FOG | VB_D_FOG_VOLUMES
    | VB_D_PROBES | VB_D_SSAO | VB_D_SCREEN_REFRACTION | (VB_D_AMBIENT_ANY << VB_D_AMBIENT_SHIFT) | VB_D_EMERGE | VB_D_FADE;

// Draw bits as a key's high 32.
function drawBits(b: u32): u64 {
    return <u64>b << 32;
}

// The material bits a target property of a StandardMaterial3D may turn on
// (`p`, Godot's name: "clearcoat", "transparency"); 0 for one that turns
// no branch on (a colour, a lobe's roughness, a texture's scale).
export function materialPropertyVolatile(p: string): u32 {
    if (p == "transparency" || p == "alpha_scissor_threshold") return VB_M_ALPHA_MASK | VB_M_ALPHA_BLEND;
    if (p == "vertex_color_use_as_albedo") return VB_M_VERTEX_COLOR;
    if (p == "shading_mode") return VB_M_UNLIT;
    if (p == "normal_enabled" || p == "normal_texture") return VB_M_TEX_NORMAL;
    if (p == "ao_enabled" || p == "ao_texture") return VB_M_TEX_OCCLUSION;
    if (p == "emission_enabled" || p == "emission_texture") return VB_M_TEX_EMISSION;
    if (p == "albedo_texture") return VB_M_TEX_BASE;
    if (p == "metallic_texture" || p == "roughness_texture") return VB_M_TEX_MR;
    const layer = p.endsWith("_texture") ? VB_M_EXT_LAYERS : 0;
    if (p.startsWith("clearcoat")) return VB_M_CLEARCOAT | layer;
    if (p.startsWith("anisotropy")) return VB_M_ANISOTROPY | layer;
    if (p.startsWith("sheen")) return VB_M_SHEEN | layer;
    if (p.startsWith("iridescence")) return VB_M_IRIDESCENCE | layer;
    if (p == "refraction_enabled" || p == "refraction_scale" || p == "transmission" || p == "refraction_texture") {
        return VB_M_TRANSMISSION | layer;
    }
    if (p.startsWith("thickness") || p.startsWith("attenuation")) return VB_M_VOLUME | layer;
    if (p == "dispersion") return VB_M_DISPERSION;
    if (p.startsWith("backlight") || p.startsWith("diffuse_transmission")) return VB_M_DIFFUSE_TRANSMISSION | layer;
    if (p.startsWith("specular")) return layer;
    return 0;
}

// The draw bits an Environment property may turn on ("ssao_enabled": SSAO;
// "background_mode", "sky", "ambient_light_source": any ambient light).
export function environmentPropertyVolatile(p: string): u32 {
    if (p == "ssao_enabled") return VB_D_SSAO;
    if (p == "fog_enabled") return VB_D_FOG;
    if (p == "volumetric_fog_enabled") return VB_D_FOG_VOLUMES;
    if (p == "screen_refraction_enabled") return VB_D_SCREEN_REFRACTION;
    if (p == "background_mode" || p == "sky" || p == "ambient_light_source" || p == "reflected_light_source") {
        return VB_D_AMBIENT_ANY << VB_D_AMBIENT_SHIFT;
    }
    return 0;
}

// The draw bits of the features `n` and the nodes under it are (a light and
// its shadow, a decal, a fog volume, a probe, an environment), which its
// `visible` shows and hides.
function subtreeFeatures(n: SceneNode): u32 {
    let bits: u32 = 0;
    const c = n.className;
    if (isA(c, "Light3D")) bits |= VB_D_LIGHTS | VB_D_SHADOWS;
    else if (isA(c, "Decal")) bits |= VB_D_DECALS;
    else if (isA(c, "FogVolume")) bits |= VB_D_FOG_VOLUMES;
    else if (isA(c, "ReflectionProbe")) bits |= VB_D_PROBES;
    else if (isA(c, "WorldEnvironment")) {
        bits |= VB_D_FOG | VB_D_FOG_VOLUMES | VB_D_SSAO | VB_D_SCREEN_REFRACTION | (VB_D_AMBIENT_ANY << VB_D_AMBIENT_SHIFT);
    }
    for (let i = 0; i < n.children.length; i++) bits |= subtreeFeatures(n.children[i]);
    return bits;
}

// The key bits target `property` of node `n` (a binding's, or a timeline
// track's: "visible", "emerge", "material_override:clearcoat",
// "environment:ssao_enabled") may turn on. A target that turns on nothing
// a key holds is 0 (a transform, a colour, a sound's volume); a target
// this misses is never wrong, only slower: its feature's draws, once on,
// have a key no build planned and draw with the ubershader.
export function targetVolatile(n: SceneNode?, property: string): u64 {
    if (n == null) return 0;
    const c = n.className;
    const parts = property.split(":");
    const head = parts[0];
    if (parts.length == 1) {
        if (head == "visible") return drawBits(subtreeFeatures(n));
        if (head == "emerge" && isA(c, "GeometryInstance3D")) return drawBits(VB_D_EMERGE);
        if (head == "fade" && isA(c, "GeometryInstance3D")) return drawBits(VB_D_FADE);
        if (head == "shadow_enabled" && isA(c, "Light3D")) return drawBits(VB_D_SHADOWS);
        return 0;
    }
    if (head == "environment" && isA(c, "WorldEnvironment")) return drawBits(environmentPropertyVolatile(parts[1]));
    if (!isA(c, "GeometryInstance3D")) return 0;
    // (a material's property: the segment after its last material_override,
    // material or next_pass one, a component after it left out)
    let at = -1;
    for (let i = 0; i < parts.length - 1; i++) {
        const s = parts[i];
        if (s == "material_override" || s == "material" || s == "next_pass" || s.startsWith("surface_material_override")) {
            at = i;
        }
    }
    if (at < 0) return 0;
    const p = parts[at + 1];
    if (p.startsWith("shader_parameter/")) return 0;
    return <u64>materialPropertyVolatile(p);
}

// The bits a binding, a timeline, a state machine (the timelines its
// states play) or a script of `tree` may turn on (../../render/
// variant_keys.as; SurfaceVariantSource.volatileBits): OR-ed into every key
// the scene's draws have, at build and at run time alike. `opts` is the
// frame's (the run time's when null). A scene with a node script takes
// every bit a script may turn on (SCRIPT_VOLATILE_DRAW).
export function variantVolatileBits(tree: SceneTree, opts: SceneRenderOptions? = null): u64 {
    let out: u64 = 0;
    const all = tree.walk();
    let scripted = false;
    for (let i = 0; i < all.length; i++) {
        const n = all[i];
        if (n.script != null) scripted = true;
        const bs = n.bindings;
        for (let k = 0; k < bs.length; k++) {
            const b = bs[k];
            if (b.path.length == 0 || !b.drivesNode()) continue;
            out |= targetVolatile(n, b.property);
        }
    }
    const scenes = sceneAnimationsOf(tree);
    for (let s = 0; s < scenes.length; s++) {
        const sa = scenes[s];
        const anims = sa.animations;
        for (let a = 0; a < anims.length; a++) {
            const objs = anims[a].objects;
            for (let o = 0; o < objs.length; o++) {
                const obj = objs[o];
                const node = obj.target == "." ? sa.root : sa.root.getNode(obj.target);
                for (let t = 0; t < obj.tracks.length; t++) out |= targetVolatile(node, obj.tracks[t].property);
            }
        }
    }
    if (scripted) out |= drawBits(SCRIPT_VOLATILE_DRAW);
    return out;
}

// A project's variants, from its Rive project's shader assets.
export class AssetSurfaceVariants extends SurfaceVariantSource {
    ctx: Context?;
    // The Hedra project's path in the Rive project ("" at its root).
    project: string;
    // By key: the module, or null when the project has none.
    private modules: Map<u64, GPUShaderModule?> = new Map<u64, GPUShaderModule?>();

    constructor(ctx: Context?, project: string) {
        super();
        this.ctx = ctx;
        this.project = project;
    }

    moduleOf(key: u64): GPUShaderModule? {
        if (this.modules.has(key)) return this.modules.get(key);
        let m: GPUShaderModule? = null;
        const ctx = this.ctx;
        if (ctx != null && key != VARIANT_UBER) m = ctx.shader(variantAssetName(this.project, key));
        this.modules.set(key, m);
        if (m != null) this.generation++;
        return m;
    }

    stateOf(key: u64): i32 {
        return this.moduleOf(key) != null ? VARIANT_READY : VARIANT_UNAVAILABLE;
    }
}

// One scene instance's view of its project's variants: the project's
// modules, with the instance's tree's volatile bits.
export class ScopedSurfaceVariants extends SurfaceVariantSource {
    source: SurfaceVariantSource;

    constructor(source: SurfaceVariantSource, volatileBits: u64) {
        super();
        this.source = source;
        this.volatileBits = volatileBits;
    }

    moduleOf(key: u64): GPUShaderModule? {
        const m = this.source.moduleOf(key);
        this.generation = this.source.generation;
        return m;
    }

    stateOf(key: u64): i32 {
        return this.source.stateOf(key);
    }
}

const sources: Map<string, AssetSurfaceVariants> = new Map<string, AssetSurfaceVariants>();

// The source of the variants of the Hedra project `project` (its path in
// the Rive project) in the Rive project behind `ctx`, one per project and
// kept, seen through `tree`'s volatile bits when it is given (a scene
// instance's own: SceneInstance passes its tree); null when the tools
// installed their own source (installSurfaceVariants), which the renderer
// then takes.
export function surfaceVariantsFor(ctx: Context?, project: string, tree: SceneTree? = null,
    opts: SceneRenderOptions? = null): SurfaceVariantSource? {
    if (installedSurfaceVariants() != null) return null;
    let s: AssetSurfaceVariants;
    if (sources.has(project) && sources.get(project).ctx === ctx) {
        s = sources.get(project);
    } else {
        s = new AssetSurfaceVariants(ctx, project);
        sources.set(project, s);
    }
    if (tree == null) return s;
    return new ScopedSurfaceVariants(s, variantVolatileBits(tree, opts));
}
