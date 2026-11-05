// Milestone 61 (docs/engine/SHADERS.md, "The built form"): where a Rive
// project's custom shaders' modules come from at run time. `hedra build`
// wrote each composed shader of a Hedra project into the Rive project as
// hedra_shaders/<project>/<key>.wgsl (the program's key: the user file's
// text), rive compiled it with the library for every backend, and the
// module is the shader asset of that name (render/shader/program.as
// shaderAssetName), which `Context.shader` gives.
//
// One source per project a runtime draws (SceneRuntime.shaderModulesFor):
// each program's module is looked up once, the first time it is drawn, and
// kept (a later frame asks a map: no allocation). A shader the Rive
// project does not hold (the scene was edited and not built again, or
// drawn from its text while the shader is new) draws its fallback, its
// state SHADER_UNAVAILABLE with the reason; a host without a GPU context
// has none at all.

import { Context } from "rive/host";
import { GPUShaderModule } from "rive/gpu";
import { CLI } from "../../base/names";
import { ShaderProgram, shaderAssetName } from "../../render/shader/program";
import { SHADER_READY, SHADER_UNAVAILABLE, ShaderModuleSource } from "../../render/shader/modules";

export class AssetShaderModules extends ShaderModuleSource {
    ctx: Context?;
    // The Hedra project's path in the Rive project ("" at its root).
    project: string;
    // By program key: the module, or null when the project has none.
    private modules: Map<string, GPUShaderModule?> = new Map<string, GPUShaderModule?>();

    constructor(ctx: Context?, project: string) {
        super();
        this.ctx = ctx;
        this.project = project;
    }

    // The asset name `p`'s module is compiled as.
    assetName(p: ShaderProgram): string {
        return shaderAssetName(this.project, p.key);
    }

    moduleOf(p: ShaderProgram): GPUShaderModule? {
        const key = p.key;
        if (this.modules.has(key)) return this.modules.get(key);
        let m: GPUShaderModule? = null;
        const ctx = this.ctx;
        // (a program with errors was never composed: `hedra build` refuses
        // it, so no asset of its key can be there)
        if (ctx != null && p.errors() == 0) m = ctx.shader(this.assetName(p));
        this.modules.set(key, m);
        if (m != null) this.generation++;
        return m;
    }

    stateOf(p: ShaderProgram): i32 {
        return this.moduleOf(p) != null ? SHADER_READY : SHADER_UNAVAILABLE;
    }

    reasonOf(p: ShaderProgram): string {
        if (this.moduleOf(p) != null) return "";
        if (this.ctx == null) return p.path + " is not drawn: there is no GPU here";
        if (p.errors() > 0) return p.path + " has errors: fix them and run `" + CLI + " build`";
        return p.path + " was not built into this Rive project: run `" + CLI + " build`";
    }

    // How many programs were looked up (tests).
    get lookedUp(): i32 {
        return this.modules.size;
    }
}
