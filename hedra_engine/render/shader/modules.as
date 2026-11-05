// Where the GPU module of a custom shader comes from: a hook, as the file
// readers are (../../scene/resource/loader.as installFileReaders), because
// the run time and the tools get it in two different ways.
//
//   - A Rive project: rive compiled each composed shader with the library's
//     (`hedra build` wrote it at shaderAssetName(project, key) + ".wgsl"),
//     so the module is `context.shader(<asset name>)` (the run time's
//     AssetShaderModules, ../../scene/runtime/shader_assets.as).
//   - The tools (the CLI and the editor): nothing was baked, so the compiler's
//     service (hedra_compiler/shader/service.as) composes the shader, has
//     the host bake it with the pinned rive CLI (the play profile's
//     `compile`), reads the compiled bytes back from the baked file and
//     makes the module with GPUShaderModule.fromRstb; each program installs
//     it first thing in its main (installShaderModules).
//
// The renderer asks for a program's module every time it draws one (a map
// lookup: no allocation once ready). A source answers null while the module
// is not ready, saying why through `stateOf`, and bumps `generation` when
// a module becomes ready or changes (a shader edited on disk), so a
// renderer that keeps pipelines makes them again and a window that draws
// lazily draws again. A shader that failed keeps its last good module in
// the tools (the editor's rule: the last good version stays on screen).

import { GPUShaderModule } from "rive/gpu";
import { ShaderProgram } from "./program";

// What a source can say of a program's module.
export const SHADER_READY: i32 = 0;
// Being compiled: the fallback is drawn meanwhile (or the last good one).
export const SHADER_PENDING: i32 = 1;
// It did not compile: the fallback (or the last good one) is drawn, its
// errors in ShaderModuleSource.diagnosticsOf.
export const SHADER_FAILED: i32 = 2;
// No source can make it here (a Rive project that was not built after the
// shader changed, a host without the play profile, no source installed).
export const SHADER_UNAVAILABLE: i32 = 3;

export abstract class ShaderModuleSource {
    // Moved whenever a module became ready or was replaced.
    generation: i32 = 0;

    // The module of `p` to draw with: the current one, else the last good
    // one, else null (the fallback material is drawn).
    abstract moduleOf(p: ShaderProgram): GPUShaderModule?;

    // SHADER_* for `p` (what moduleOf's answer means).
    abstract stateOf(p: ShaderProgram): i32;

    // One line for the statistics and the warnings: why `p` is not drawn
    // ("" when it is).
    abstract reasonOf(p: ShaderProgram): string;

    // The program whose layout moduleOf(p)'s module was made for: `p`
    // itself, but for the last good module of a file whose new text is
    // being compiled or failed, which is the last good text's (its block,
    // textures and samplers are where that text put them: the renderer
    // packs the material's values into them by name).
    programOf(p: ShaderProgram): ShaderProgram {
        return p;
    }
}

// The source that has none: every custom material draws its fallback.
export class NoShaderModules extends ShaderModuleSource {
    moduleOf(p: ShaderProgram): GPUShaderModule? {
        return null;
    }

    stateOf(p: ShaderProgram): i32 {
        return SHADER_UNAVAILABLE;
    }

    reasonOf(p: ShaderProgram): string {
        return "custom shaders are not drawn here: no shader source is installed";
    }
}

let installed: ShaderModuleSource? = null;

// Installs the source every renderer without one of its own asks
// (FrameRenderer.shaderModules); the tools' programs call it at start.
export function installShaderModules(s: ShaderModuleSource): void {
    installed = s;
}

// The installed source (a NoShaderModules until one is installed).
export function installedShaderModules(): ShaderModuleSource {
    let s = installed;
    if (s == null) {
        s = new NoShaderModules();
        installed = s;
    }
    return s;
}
