// The diagnostics of a scene's custom shader materials (milestone 61;
// docs/engine/SHADERS.md, docs/formats/RSCN.md "Shaders"): what render,
// the editor's Output panel, `inspect --check`, `check` and `build` report
// about them, appended by ./warnings.as sceneDiagnostics. A scene without
// a ShaderMaterial has none.
//
// The materials are every one the tree draws (a MeshInstance3D's
// material_override and its mesh's materials, a MultiMesh's and a
// CPUParticles3D's mesh's, a model's surfaces'), and their next passes,
// each once, in tree order. Then, in this order:
//   - every diagnostic of each shader the materials use (the reader's,
//     render/shader/parse.as: errors and warnings with their codes), once
//     per shader file however many materials use it, at its line and
//     column in the .wgsl;
//   - `shader-material-empty` (warning): a ShaderMaterial without a
//     shader, which draws its fallback (its StandardMaterial3D settings:
//     a scene's are the defaults), at its <sub_resource>;
//   - `shader-parameter-unknown` (warning): a `shader_parameter/<name>`
//     the shader has no uniform for, and `shader-parameter-type`
//     (warning): a value that is not of its uniform's type (a Color for a
//     source_color uniform, a Vector3 for a vec3, a texture for a
//     texture...), each at its <property> (the sub_resource when the
//     declaration is not a scene's: a model's material); kept, and drawn
//     once the shader has such a uniform (the editor's live reload);
//   - `material-next-pass-deep` (warning): a material whose next passes
//     run deeper than the renderer draws (MAX_NEXT_PASS_HOPS: Godot has no
//     limit), or come back to a material of the chain, at the first
//     material of the chain.

import { Diagnostic, Severity } from "../../scene/error";
import { PackedScene, ArrayMesh, Mesh, StandardMaterial3D } from "../../scene/resource/types";
import { PrimitiveMesh } from "../../scene/resource/primitives";
import { PARAM_TYPE, PARAM_UNKNOWN, ShaderMaterial } from "../../scene/resource/shader";
import { CPUParticles3D, MeshInstance3D, MultiMeshInstance3D, SceneNode } from "../../scene/tree/node";
import { SceneTree } from "../../scene/tree/tree";
import { SHADER_ERROR, UNIFORM_TYPE_NAMES, UniformType } from "../../render/shader/program";
import { MAX_NEXT_PASS_HOPS } from "../../scene/binding/shader_target_names";
import { SHADER_PARAMETER_PREFIX } from "../../scene/classdb";

// Where the warnings point.
export const SHADERS_DOC = "docs/engine/SHADERS.md";

export const SHADER_MATERIAL_EMPTY_CODE = "shader-material-empty";
export const SHADER_PARAMETER_UNKNOWN_CODE = "shader-parameter-unknown";
export const SHADER_PARAMETER_TYPE_CODE = "shader-parameter-type";
export const MATERIAL_NEXT_PASS_DEEP_CODE = "material-next-pass-deep";

// Every material `tree` draws, each once in tree order (a material's next
// passes are not listed: shaderDiagnostics follows them).
export function drawnMaterials(tree: SceneTree): Array<StandardMaterial3D> {
    const out = new Array<StandardMaterial3D>();
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        const isMesh = n instanceof MeshInstance3D;
        const isMulti = n instanceof MultiMeshInstance3D;
        const isParticles = n instanceof CPUParticles3D;
        if (isMesh) {
            const mi = n as MeshInstance3D;
            push(out, mi.materialOverride);
            fromMesh(out, mi.mesh);
        } else if (isMulti) {
            const mm = (n as MultiMeshInstance3D).multimesh;
            if (mm != null) fromMesh(out, mm.mesh);
        } else if (isParticles) {
            fromMesh(out, (n as CPUParticles3D).mesh);
        }
    }
    return out;
}

function push(out: Array<StandardMaterial3D>, m: StandardMaterial3D?): void {
    if (m != null && !out.includes(m)) out.push(m);
}

function fromMesh(out: Array<StandardMaterial3D>, mesh: Mesh?): void {
    if (mesh == null) return;
    const isPrimitive = mesh instanceof PrimitiveMesh;
    const isArray = mesh instanceof ArrayMesh;
    if (isPrimitive) push(out, (mesh as PrimitiveMesh).material);
    else if (isArray) {
        const surfaces = (mesh as ArrayMesh).surfaces;
        for (let k = 0; k < surfaces.length; k++) push(out, surfaces[k].material);
    }
}

// Where a material, or one of its properties, is declared.
class Place {
    file: string = "";
    line: i32 = 0;
    col: i32 = 0;
}

// The <sub_resource> that declared `m` (its <property> `property` when
// given and found), in a scene the tree's loader read; else the file that
// declared it, without a line.
function placeOf(tree: SceneTree, m: StandardMaterial3D, property: string): Place {
    const out = new Place();
    out.file = m.file.length > 0 ? m.file : tree.loader.displayPath(tree.scenePath);
    if (m.id.length == 0) return out;
    const scenes = tree.loader.loaded();
    for (let k = 0; k < scenes.length; k++) {
        const r = scenes[k];
        const isScene = r instanceof PackedScene;
        if (!isScene) continue;
        const doc = (r as PackedScene).doc;
        if (doc == null || doc.file != m.file) continue;
        const decl = doc.findSub(m.id);
        if (decl == null) continue;
        out.line = decl.pos.line;
        out.col = decl.pos.col;
        if (property.length > 0) {
            const props = decl.properties();
            for (let i = 0; i < props.length; i++) {
                if (props[i].name != property) continue;
                out.line = props[i].pos.line;
                out.col = props[i].pos.col;
                break;
            }
        }
        break;
    }
    return out;
}

function warn(out: Array<Diagnostic>, at: Place, code: string, message: string, hint: string): void {
    out.push(new Diagnostic(Severity.Warning, code, at.file, at.line, at.col, message, hint));
}

// How a material is named in a message.
function named(m: StandardMaterial3D): string {
    if (m.id.length > 0) return m.className() + " \"" + m.id + "\"";
    if (m.name.length > 0) return m.className() + " '" + m.name + "'";
    return "a " + m.className();
}

// What a value of uniform type `t` (source_color `color`) is written as in
// the file.
function valueWords(t: UniformType, color: bool): string {
    switch (t) {
        case UniformType.Bool: return "true or false";
        case UniformType.Float: return "a number";
        case UniformType.Int: case UniformType.UInt: return "a whole number";
        case UniformType.Vec2: return "a Vector2";
        case UniformType.Vec3: return color ? "a Color" : "a Vector3";
        case UniformType.Vec4: return color ? "a Color" : "a Vector4";
        case UniformType.IVec2: return "a Vector2i";
        case UniformType.IVec3: return "a Vector3i";
        case UniformType.IVec4: return "a Vector4 of whole numbers";
        default: return "a texture (an ExtResource of a Texture2D, an ArtboardTexture or a ViewportTexture), or null";
    }
}

// The diagnostics of `tree`'s custom shader materials (see the header).
export function shaderDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const tops = drawnMaterials(tree);
    // Every material, next passes after the material that names them.
    const all = new Array<StandardMaterial3D>();
    for (let i = 0; i < tops.length; i++) {
        const top = tops[i];
        const chain = new Array<StandardMaterial3D>();
        chain.push(top);
        let m = top.nextPass;
        let deep = false;
        let loops = false;
        while (m != null) {
            if (chain.includes(m)) {
                loops = true;
                break;
            }
            chain.push(m);
            if (chain.length - 1 > MAX_NEXT_PASS_HOPS) {
                deep = true;
                break;
            }
            m = m.nextPass;
        }
        for (let k = 0; k < chain.length; k++) if (!all.includes(chain[k])) all.push(chain[k]);
        if (loops || deep) {
            warn(out, placeOf(tree, top, "next_pass"), MATERIAL_NEXT_PASS_DEEP_CODE,
                named(top) + (loops ? "'s next passes come back to a material of the chain: the passes past the loop are not drawn"
                    : "'s next passes run deeper than " + MAX_NEXT_PASS_HOPS.toString() + ": the passes past the fourth are not drawn"),
                "give at most " + MAX_NEXT_PASS_HOPS.toString() + " next passes in a chain, none naming a material before it; see "
                    + SHADERS_DOC);
        }
    }
    // The shaders' own, once per file.
    const said = new Array<string>();
    for (let i = 0; i < all.length; i++) {
        const isShader = all[i] instanceof ShaderMaterial;
        if (!isShader) continue;
        const p = (all[i] as ShaderMaterial).program;
        if (p == null || said.includes(p.path)) continue;
        said.push(p.path);
        for (let k = 0; k < p.diagnostics.length; k++) {
            const d = p.diagnostics[k];
            out.push(new Diagnostic(d.severity == SHADER_ERROR ? Severity.Error : Severity.Warning, d.code, p.path, d.line, d.col,
                d.message, d.hint.length > 0 ? d.hint : null));
        }
    }
    // The materials'.
    for (let i = 0; i < all.length; i++) {
        const isShader = all[i] instanceof ShaderMaterial;
        if (!isShader) continue;
        const m = all[i] as ShaderMaterial;
        const p = m.program;
        if (p == null) {
            warn(out, placeOf(tree, m, ""), SHADER_MATERIAL_EMPTY_CODE,
                named(m) + " has no shader: it draws its fallback (its StandardMaterial3D settings)",
                "set its shader to a .wgsl file (a Shader ext_resource); `hedra new <name>.wgsl` writes one; see " + SHADERS_DOC);
            continue;
        }
        for (let k = 0; k < m.problems.length; k++) {
            const name = m.problems[k];
            const kind = m.problemKinds[k];
            const at = placeOf(tree, m, SHADER_PARAMETER_PREFIX + name);
            if (kind == PARAM_UNKNOWN) {
                const names = new Array<string>();
                for (let u = 0; u < p.uniforms.length; u++) names.push(p.uniforms[u].name);
                warn(out, at, SHADER_PARAMETER_UNKNOWN_CODE,
                    named(m) + " sets shader_parameter/" + name + ", but its shader " + p.path + " has no uniform \"" + name
                        + "\": the value is kept, and not drawn",
                    names.length > 0 ? "its uniforms: " + names.join(", ") : "its shader declares no uniform");
            } else if (kind == PARAM_TYPE) {
                const u = p.uniforms[p.uniformIndex(name)];
                warn(out, at, SHADER_PARAMETER_TYPE_CODE,
                    named(m) + " sets shader_parameter/" + name + " to a value that is not its uniform's type ("
                        + UNIFORM_TYPE_NAMES[<i32>u.type] + (u.isColor() ? ", source_color" : "") + "): the uniform's default is drawn",
                    "write " + valueWords(u.type, u.isColor()) + "; see " + SHADERS_DOC);
            }
        }
    }
    return out;
}
