// Godot's Shader and ShaderMaterial (milestone 61, docs/engine/SHADERS.md):
// a shader file read once per file (the loader's cache, as a texture is),
// and a material drawn with it, whose parameters are the shader's uniforms.
//
// ShaderMaterial extends StandardMaterial3D here, though Godot's derives
// from Material beside it (classdb has Godot's tree): every node, mesh and
// pass that takes a material takes it as it is, and its StandardMaterial3D
// fields are its fallback, drawn while its shader is not ready or cannot
// be (in a .rscn the defaults; a model's material in an .rmdl keeps its
// own settings there, RMDL.md section 5). Code that must tell the two
// apart tests `instanceof ShaderMaterial` first.
//
// A parameter is `shader_parameter/<name>` in the file: its value as
// written (a number, a bool, a vector, a Color for a source_color uniform,
// or a Texture2D for a texture uniform) is kept as declared, and mapped
// onto the shader's uniforms whenever the shader is set or read again
// (`remap`: the editor's live reload keeps every value whose uniform is
// still there). What the material draws is `params` (numbers by uniform
// index, ../../render/shader/layout.as) and `textures` (by texture index):
// a binding or a timeline writes `params` in place, allocating nothing.

import { Value, ValueKind } from "../value";
import { MaterialUv, Resource, StandardMaterial3D, Texture2D } from "./types";
import {
    SHADER_ERROR, ShaderDiagnostic, ShaderProgram, ShaderUniform, UniformType, shaderKey, uniformComponents, uniformIsInteger,
} from "../../render/shader/program";
import { ShaderParams, defaultParams } from "../../render/shader/layout";
import { parseShader } from "../../render/shader/parse";

export class Shader extends Resource {
    // The file's text, and what it declares (never null: a file that does
    // not read is a program with errors).
    text: string = "";
    program: ShaderProgram = new ShaderProgram();
    // Why the file could not be read ("" when it was: unreadableShader).
    unreadable: string = "";

    className(): string {
        return "Shader";
    }
}

// A Shader from a file's text (`display` as errors name it).
export function shaderOfText(text: string, display: string): Shader {
    const s = new Shader();
    s.text = text;
    s.program = parseShader(text, display);
    return s;
}

// A Shader of the file `display` that could not be read (`why`): no text,
// and a program with the one error file-read, so that its materials draw
// their fallback and say why, as for a shader that does not compile,
// rather than the whole scene failing. Its key is the reason's (no file
// text has it), so that the file read again, fixed, is a new program.
export function unreadableShader(display: string, why: string, hint: string): Shader {
    const s = new Shader();
    const p = new ShaderProgram();
    p.path = display;
    p.key = shaderKey("\u0000" + display + "\u0000" + why);
    // (the message without the path: every report puts it first)
    p.diagnostics.push(new ShaderDiagnostic(SHADER_ERROR, "file-read", "the file cannot be read: " + why, hint, 0, 0));
    s.program = p;
    s.unreadable = why;
    return s;
}

// What setting a parameter did.
export const PARAM_SET: i32 = 0;
// The shader has no uniform of that name (shader-parameter-unknown).
export const PARAM_UNKNOWN: i32 = 1;
// The value is not of the uniform's type (shader-parameter-type).
export const PARAM_TYPE: i32 = 2;
// No shader: kept, drawn once there is one.
export const PARAM_NO_SHADER: i32 = 3;

export class ShaderMaterial extends StandardMaterial3D {
    shader: Shader? = null;
    // The parameters as declared (`shader_parameter/<name>`), in the file's
    // order: their names, values and, for a texture's, the resource.
    declaredNames: Array<string> = [];
    declaredValues: Array<Value> = [];
    declaredTextures: Array<Texture2D?> = [];
    // What is drawn (`remap` fills them from the declarations).
    params: ShaderParams = new ShaderParams(0);
    textures: Array<Texture2D?> = [];
    // The declarations `remap` could not map (names, and PARAM_* each).
    problems: Array<string> = [];
    problemKinds: Array<i32> = [];
    // The program `params` and `textures` were last mapped for.
    private mapped: ShaderProgram? = null;

    className(): string {
        return "ShaderMaterial";
    }

    // The program drawn, or null without a shader.
    get program(): ShaderProgram? {
        const s = this.shader;
        return s != null ? s.program : null;
    }

    // Records `shader_parameter/<name>` = `v` (`tex` its texture when `v`
    // names one) and maps it at once when there is a shader.
    declare(name: string, v: Value, tex: Texture2D?): i32 {
        const at = this.declaredNames.indexOf(name);
        if (at >= 0) {
            this.declaredValues[at] = v;
            this.declaredTextures[at] = tex;
        } else {
            this.declaredNames.push(name);
            this.declaredValues.push(v);
            this.declaredTextures.push(tex);
        }
        const p = this.program;
        if (p == null) return PARAM_NO_SHADER;
        // (a shader assigned without setShader, or read again in place:
        // `params` is still sized for the program before, so map first,
        // which also applies this declaration)
        if (this.mapped !== p) {
            this.remap();
            return this.problems.indexOf(name) >= 0 ? this.problemKinds[this.problems.indexOf(name)] : PARAM_SET;
        }
        const k = this.apply(p, name, v, tex);
        const had = this.problems.indexOf(name);
        if (had >= 0) {
            this.problems.splice(had, 1);
            this.problemKinds.splice(had, 1);
        }
        if (k != PARAM_SET) {
            this.problems.push(name);
            this.problemKinds.push(k);
        }
        return k;
    }

    // Sets the shader (or none) and maps every declaration onto it.
    setShader(s: Shader?): void {
        this.shader = s;
        this.remap();
    }

    // Maps the declarations onto the current shader: a fresh params and
    // textures, every value whose uniform the shader has, the rest in
    // `problems`.
    remap(): void {
        this.problems.length = 0;
        this.problemKinds.length = 0;
        const p = this.program;
        this.mapped = p;
        if (p == null) {
            this.params = new ShaderParams(0);
            this.textures = [];
            return;
        }
        this.params = defaultParams(p);
        this.textures = [];
        for (let i = 0; i < p.textureCount; i++) this.textures.push(null);
        for (let i = 0; i < this.declaredNames.length; i++) {
            const k = this.apply(p, this.declaredNames[i], this.declaredValues[i], this.declaredTextures[i]);
            if (k != PARAM_SET) {
                this.problems.push(this.declaredNames[i]);
                this.problemKinds.push(k);
            }
        }
    }

    private apply(p: ShaderProgram, name: string, v: Value, tex: Texture2D?): i32 {
        const i = p.uniformIndex(name);
        if (i < 0) return PARAM_UNKNOWN;
        const u = p.uniforms[i];
        if (u.type == UniformType.Texture2D) {
            if (v.kind == ValueKind.Nil) {
                this.textures[u.texture] = null;
                return PARAM_SET;
            }
            if (tex == null) return PARAM_TYPE;
            this.textures[u.texture] = tex;
            return PARAM_SET;
        }
        if (!valueFits(u, v)) return PARAM_TYPE;
        const n = uniformComponents(u.type);
        if (n == 1) this.params.write(p, i, 0, v.kind == ValueKind.Bool ? (v.b ? 1 : 0) : v.asF64());
        else for (let c = 0; c < n; c++) this.params.write(p, i, c, c < v.n.length ? v.n[c] : 0);
        return PARAM_SET;
    }
}

// Whether a file's value `v` may set uniform `u`: a bool for a bool (a
// number too, 0 false); a number for a scalar (a whole one for an
// integer); a Color for a source_color vec3 or vec4, a Vector2, Vector3 or
// Vector4 of its size for a vector (a Vector2i or Vector3i for an
// integer's); never a resource (a texture's is the caller's).
export function valueFits(u: ShaderUniform, v: Value): bool {
    const k = v.kind;
    switch (u.type) {
        case UniformType.Bool: return k == ValueKind.Bool || v.isNumber();
        case UniformType.Float: return v.isNumber();
        case UniformType.Int:
        case UniformType.UInt: return k == ValueKind.Int || (k == ValueKind.Float && v.f == Math.floor(v.f));
        case UniformType.Vec2: return k == ValueKind.Vector2;
        case UniformType.Vec3: return u.isColor() ? k == ValueKind.Color : k == ValueKind.Vector3;
        case UniformType.Vec4: return u.isColor() ? k == ValueKind.Color : k == ValueKind.Vector4;
        case UniformType.IVec2: return k == ValueKind.Vector2i;
        case UniformType.IVec3: return k == ValueKind.Vector3i;
        case UniformType.IVec4: return k == ValueKind.Vector4;
        default: return false;
    }
}

// The value uniform `i` of `m` draws, as the file would write it (its
// default when the material does not set it): Value.float, .int, .bool,
// a Vector2/3/4, a Vector2i/3i, or a Color for a source_color one; Nil
// for a texture (its resource is m.textures[u.texture]).
export function shaderParamValue(m: ShaderMaterial, i: i32): Value {
    const p = m.program;
    if (p == null || i < 0 || i >= p.uniforms.length) return Value.nil();
    const u = p.uniforms[i];
    const n = uniformComponents(u.type);
    if (u.type == UniformType.Texture2D) return Value.nil();
    if (u.type == UniformType.Bool) return Value.bool(m.params.value(p, i, 0) != 0);
    if (n == 1) {
        const x = m.params.value(p, i, 0);
        return uniformIsInteger(u.type) ? Value.int(<i64>Math.round(x)) : Value.float(x);
    }
    const nums = new Array<f64>(n);
    for (let c = 0; c < n; c++) nums[c] = m.params.value(p, i, c);
    let kind = ValueKind.Vector4;
    if (u.isColor()) {
        kind = ValueKind.Color;
        if (n == 3) nums.push(1);
    } else if (u.type == UniformType.Vec2) kind = ValueKind.Vector2;
    else if (u.type == UniformType.Vec3) kind = ValueKind.Vector3;
    else if (u.type == UniformType.IVec2) kind = ValueKind.Vector2i;
    else if (u.type == UniformType.IVec3) kind = ValueKind.Vector3i;
    return Value.numbers(kind, nums);
}

// Milestone 61: a ShaderMaterial whose fallback is `src`'s
// settings (a model's Material in an .rmdl with a `shader`: RMDL.md section
// 5): every StandardMaterial3D field of `src` copied, textures and UV
// transforms included (the textures shared, the transforms copied), its
// name, file and id too. `src` is not changed (a MaterialX file's material
// is the loader's, shared by every model that names the file).
export function shaderMaterialFrom(src: StandardMaterial3D): ShaderMaterial {
    const m = new ShaderMaterial();
    copyMaterialInto(src, m);
    return m;
}

// Copies every StandardMaterial3D field of `src` into `dst` (see
// shaderMaterialFrom): the class's fields in its order (../resource/
// types.as), then its texture slots and their UV transforms.
export function copyMaterialInto(src: StandardMaterial3D, dst: StandardMaterial3D): void {
    dst.name = src.name;
    dst.file = src.file;
    dst.id = src.id;
    dst.albedoColor = src.albedoColor;
    dst.metallic = src.metallic;
    dst.roughness = src.roughness;
    dst.packedMetallicRoughness = src.packedMetallicRoughness;
    dst.emissionEnabled = src.emissionEnabled;
    dst.emission = src.emission;
    dst.emissionEnergy = src.emissionEnergy;
    dst.normalEnabled = src.normalEnabled;
    dst.normalScale = src.normalScale;
    dst.aoEnabled = src.aoEnabled;
    dst.transparency = src.transparency;
    dst.alphaScissorThreshold = src.alphaScissorThreshold;
    dst.cullMode = src.cullMode;
    dst.vertexColorUseAsAlbedo = src.vertexColorUseAsAlbedo;
    dst.vertexColorIsSrgb = src.vertexColorIsSrgb;
    dst.uv1Scale = src.uv1Scale;
    dst.uv1Offset = src.uv1Offset;
    dst.billboardMode = src.billboardMode;
    dst.billboardKeepScale = src.billboardKeepScale;
    dst.shadingMode = src.shadingMode;
    dst.aoStrength = src.aoStrength;
    dst.ior = src.ior;
    dst.specular = src.specular;
    dst.specularColor = src.specularColor;
    dst.clearcoatEnabled = src.clearcoatEnabled;
    dst.clearcoat = src.clearcoat;
    dst.clearcoatRoughness = src.clearcoatRoughness;
    dst.clearcoatNormalScale = src.clearcoatNormalScale;
    dst.anisotropyEnabled = src.anisotropyEnabled;
    dst.anisotropy = src.anisotropy;
    dst.anisotropyRotation = src.anisotropyRotation;
    dst.sheenColor = src.sheenColor;
    dst.sheenRoughness = src.sheenRoughness;
    dst.refractionEnabled = src.refractionEnabled;
    dst.refractionScale = src.refractionScale;
    dst.transmission = src.transmission;
    dst.thickness = src.thickness;
    dst.attenuationDistance = src.attenuationDistance;
    dst.attenuationColor = src.attenuationColor;
    dst.dispersion = src.dispersion;
    dst.iridescence = src.iridescence;
    dst.iridescenceIor = src.iridescenceIor;
    dst.iridescenceThicknessMinimum = src.iridescenceThicknessMinimum;
    dst.iridescenceThicknessMaximum = src.iridescenceThicknessMaximum;
    dst.backlightEnabled = src.backlightEnabled;
    dst.diffuseTransmission = src.diffuseTransmission;
    dst.backlight = src.backlight;
    dst.nextPass = src.nextPass;
    dst.renderPriority = src.renderPriority;
    for (let slot = 0; slot < 20; slot++) dst.setTextureAt(slot, src.textureAt(slot));
    const uvs = new Array<MaterialUv>();
    for (let i = 0; i < src.uvs.length; i++) {
        const a = src.uvs[i];
        const b = new MaterialUv();
        b.texcoord = a.texcoord;
        b.offset = a.offset;
        b.rotation = a.rotation;
        b.scale = a.scale;
        uvs.push(b);
    }
    dst.uvs = uvs;
}
