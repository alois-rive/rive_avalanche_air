// Where the GPU modules of the surface shader's variants come from
// (../variant.as): a hook, as the custom shaders' modules are
// (./modules.as), because the run time and the tools get them in two ways.
//
//   - A Rive project: `hedra build` wrote each key a built scene reaches as
//     hedra_shaders/<project>/surface_<key>.wgsl and rive compiled it with
//     the library, so a module is `context.shader(variantAssetName(...))`
//     (the run time's AssetSurfaceVariants,
//     ../../scene/runtime/variant_assets.as); a key the project does not
//     hold is drawn with the ubershader.
//   - The tools: hedra_compiler's variant service writes the variant,
//     has the host bake it with the pinned rive CLI (the play profile's
//     `compile`), caches its RSTB under build/hedra/shaders/ and makes the
//     module with GPUShaderModule.fromRstb; the programs install it first
//     thing in their main (installSurfaceVariants). Until a key is ready
//     its draws use the ubershader (Godot's ubershader while a
//     specialised pipeline compiles).
//
// The renderer asks for a key's module every time a draw has that key (a
// map lookup by a u64: no allocation once asked); `generation` moves when
// a module becomes ready, so a renderer makes the key's pipelines and a
// window that draws lazily draws again.

import { GPUShaderModule } from "rive/gpu";

// What a source can say of a key (./modules.as's values).
export const VARIANT_READY: i32 = 0;
export const VARIANT_PENDING: i32 = 1;
export const VARIANT_FAILED: i32 = 2;
export const VARIANT_UNAVAILABLE: i32 = 3;

export abstract class SurfaceVariantSource {
    // Moved whenever a module became ready or was replaced.
    generation: i32 = 0;
    // The bits OR-ed into every key the renderer asks this source for
    // (../variant_keys.as, hedra_engine/scene/runtime/variant_assets.as
    // variantVolatileBits): the features a binding, a timeline, a state
    // machine or a script of the scene may turn on, whose code every
    // variant then keeps (a variant that keeps a feature's code draws its
    // absence exactly), so that the key of a draw does not move when they
    // do, and is the key `hedra build` wrote. 0 for the tools, which
    // compile whatever key a draw has.
    volatileBits: u64 = 0;

    // The volatile bits as the renderer reads them, once a key: a source
    // whose bits follow something else (the tools' scene) answers them.
    volatile(): u64 {
        return this.volatileBits;
    }

    // The module of `key` (../variant.as), or null while there is none
    // (the ubershader is drawn).
    abstract moduleOf(key: u64): GPUShaderModule?;

    // VARIANT_* for `key`.
    abstract stateOf(key: u64): i32;
}

// No variants: every draw is the ubershader's (the default, and a host
// with no GPU).
export class NoSurfaceVariants extends SurfaceVariantSource {
    moduleOf(key: u64): GPUShaderModule? {
        return null;
    }

    stateOf(key: u64): i32 {
        return VARIANT_UNAVAILABLE;
    }
}

let installed: SurfaceVariantSource? = null;

// The tools' source (null: none, the run time's per project).
export function installSurfaceVariants(s: SurfaceVariantSource?): void {
    installed = s;
}

export function installedSurfaceVariants(): SurfaceVariantSource? {
    return installed;
}
