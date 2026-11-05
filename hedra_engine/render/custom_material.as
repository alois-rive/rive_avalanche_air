// A ShaderMaterial as a frame carries it (MaterialDesc.custom): its shader
// (./shader/program.as, read once per file), its parameters' values (the
// scene's ShaderMaterial owns them: a binding or a timeline writes them in
// place, and the GPU side packs the block again when their version moves),
// and its textures by the shader's texture index, as paths the material
// binder reads (MaterialDesc.textures' rule: a path as written, relative
// to the frame's baseDir, or a live view's path), or null where the
// material sets none (the uniform's hint_default_* is drawn, white unless
// it says otherwise, a flat normal for hint_normal).
//
// The rest of the MaterialDesc it hangs on is its fallback: what is drawn
// while the module is not ready, when it cannot be made, or by a pass the
// custom pipelines do not draw (the editor's matcap, normals and other
// shadings draw every material without it). The scene adapter fills it
// from the ShaderMaterial's own StandardMaterial3D fields (its defaults in
// a .rscn, a model material's own settings in an .rmdl) and sets
// alphaMode, doubleSided and renderPriority from the shader, so that
// culling, sorting and the shadow pass treat the item as the shader will
// draw it.

import { ShaderProgram } from "./shader/program";
import { ShaderParams } from "./shader/layout";

export class CustomMaterialDesc {
    program: ShaderProgram;
    params: ShaderParams;
    // By ShaderUniform.texture: a path, or null.
    textures: Array<string?> = [];
    // Each texture's samples in sRGB (its uniform's source_color): read as
    // a base colour texture is, decoded to linear on upload.
    srgb: Array<bool> = [];

    constructor(program: ShaderProgram, params: ShaderParams) {
        this.program = program;
        this.params = params;
        for (let i = 0; i < program.textureCount; i++) {
            this.textures.push(null);
            this.srgb.push(false);
        }
    }
}
