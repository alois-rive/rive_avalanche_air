// Milestone 61 (docs/engine/SHADERS.md, "Binding and keying parameters"):
// a shader parameter target (./shader_target_names.as) resolved against a
// node's material, which alone says what the target is. The binder
// (./binder.as) and the timelines (../anim/scene_anims.as) ask when they
// bind, the editor's bind popover and Data dock list a node's
// (shaderBindingTargetsOf).
//
// The kind a parameter drives, from its uniform (Godot's types):
//   - a bool: Boolean;
//   - a float or an integer: Number (an integer is rounded when drawn);
//   - a source_color vec3 or vec4, whole: Color (sRGB, straight alpha, as
//     every colour of the format; a vec3's alpha is ignored);
//   - one component of a vector (`:x` to `:w`, a colour's too): Number.
// Anything else is no target, with the reason and a hint the warnings
// give (binding-target-missing, keyed-property-unknown): a whole vector
// that is no colour ("bind a component"), a texture (a texture slot binds
// to nothing, as a StandardMaterial3D's), a uniform the shader lacks, a
// material that is no ShaderMaterial, a ShaderMaterial without a shader,
// no next pass where the target looks for one.

import { MeshInstance3D, SceneNode } from "../tree/node";
import { PrimitiveMesh } from "../resource/primitives";
import { StandardMaterial3D } from "../resource/types";
import { ShaderMaterial } from "../resource/shader";
import { UNIFORM_TYPE_NAMES, UniformType, uniformComponents } from "../../render/shader/program";
import { BindKind, BindingTarget, findBindingTarget } from "./targets";
import {
    MAX_NEXT_PASS_HOPS, SHADER_HOLDER_MESH_MATERIAL, SHADER_HOLDER_OVERRIDE, parseShaderTargetName, shaderTargetProperty,
} from "./shader_target_names";

// What resolving a target gave: its kind, or why it is none.
export class ShaderTargetInfo {
    ok: bool = false;
    kind: BindKind = BindKind.Number;
    reason: string = "";
    hint: string = "";
    // The material and the uniform's index (ok only).
    material: ShaderMaterial? = null;
    uniform: i32 = -1;
}

function fail(reason: string, hint: string): ShaderTargetInfo {
    const t = new ShaderTargetInfo();
    t.reason = reason;
    t.hint = hint;
    return t;
}

const COMPONENTS: StaticArray<string> = ["x", "y", "z", "w"];

// The material a holder of `node` holds (its material_override, or its
// primitive mesh's material), or null.
function holderMaterial(node: SceneNode, holder: i32): StandardMaterial3D? {
    const isMesh = node instanceof MeshInstance3D;
    if (!isMesh) return null;
    const m = node as MeshInstance3D;
    if (holder == SHADER_HOLDER_OVERRIDE) return m.materialOverride;
    const mesh = m.mesh;
    if (mesh == null) return null;
    const isPrimitive = mesh instanceof PrimitiveMesh;
    return isPrimitive ? (mesh as PrimitiveMesh).material : null;
}

// What the shader parameter target `property` is on `node` (see the
// header). Made anew each time: asked when a scene is bound, never per
// frame.
export function resolveShaderTarget(node: SceneNode, property: string): ShaderTargetInfo {
    const t = parseShaderTargetName(property);
    if (t == null) {
        return fail("it is no shader parameter target", "write material_override:shader_parameter/<name>, a component as "
            + "material_override:shader_parameter/<name>:x");
    }
    const holderWord = t.holder == SHADER_HOLDER_OVERRIDE ? "material_override" : "mesh's material";
    let m = holderMaterial(node, t.holder);
    if (m == null) {
        return fail("it has no " + holderWord,
            t.holder == SHADER_HOLDER_OVERRIDE ? "set its material_override to a ShaderMaterial sub_resource"
                : "give its primitive mesh a ShaderMaterial as its material, or bind material_override:shader_parameter/<name>");
    }
    for (let i = 0; i < t.hops; i++) {
        const next: StandardMaterial3D? = (m as StandardMaterial3D).nextPass;
        if (next == null) {
            return fail("its " + holderWord + (i > 0 ? "'s next pass" : "") + " has no next_pass",
                "set next_pass on the material to a ShaderMaterial, or bind fewer next_pass: steps");
        }
        m = next;
    }
    const mat = m as StandardMaterial3D;
    const isShader = mat instanceof ShaderMaterial;
    if (!isShader) {
        return fail("its " + holderWord + (t.hops > 0 ? "'s next pass" : "") + " is a " + mat.className() + ", not a ShaderMaterial",
            "a shader_parameter/ target binds a ShaderMaterial's uniform; a StandardMaterial3D's fields are "
                + "material_override:<property>");
    }
    const sm = mat as ShaderMaterial;
    const p = sm.program;
    if (p == null) {
        return fail("its ShaderMaterial has no shader", "set the material's shader to a .wgsl Shader ext_resource");
    }
    const i = p.uniformIndex(t.param);
    if (i < 0) {
        const names = new Array<string>();
        for (let k = 0; k < p.uniforms.length; k++) if (p.uniforms[k].type != UniformType.Texture2D) names.push(p.uniforms[k].name);
        return fail("its shader " + p.path + " has no uniform \"" + t.param + "\"",
            names.length > 0 ? "its uniforms: " + names.join(", ") : "the shader declares no uniform a binding can drive");
    }
    const u = p.uniforms[i];
    const n = uniformComponents(u.type);
    if (u.type == UniformType.Texture2D) {
        return fail("\"" + t.param + "\" is a texture uniform: a texture is neither bound nor keyed",
            "set the texture in the scene (shader_parameter/" + t.param + " = ExtResource(...)); bind a number, bool or colour uniform");
    }
    const out = new ShaderTargetInfo();
    out.ok = true;
    out.material = sm;
    out.uniform = i;
    if (t.axis >= 0) {
        if (n == 1) {
            return fail("\"" + t.param + "\" (" + uniformTypeWord(u.type) + ") has no component " + COMPONENTS[t.axis],
                "bind it whole: shader_parameter/" + t.param);
        }
        if (t.axis >= n) {
            return fail("\"" + t.param + "\" has " + n.toString() + " components: it has no " + COMPONENTS[t.axis],
                "bind one of " + componentList(n) + ": shader_parameter/" + t.param + ":x");
        }
        out.kind = BindKind.Number;
        return out;
    }
    if (u.type == UniformType.Bool) {
        out.kind = BindKind.Boolean;
        return out;
    }
    if (n == 1) {
        out.kind = BindKind.Number;
        return out;
    }
    if (u.isColor()) {
        out.kind = BindKind.Color;
        return out;
    }
    return fail("\"" + t.param + "\" is a whole " + uniformTypeWord(u.type) + " that is no colour: a binding or a key drives a number, a bool or a colour",
        "bind a component: shader_parameter/" + t.param + ":x");
}

// "x, y" to "x, y, z, w".
function componentList(n: i32): string {
    let s = "";
    for (let i = 0; i < n; i++) s += (i > 0 ? ", " : "") + COMPONENTS[i];
    return s;
}

// The uniform's type as WGSL spells it (what the user's file says).
function uniformTypeWord(t: UniformType): string {
    return UNIFORM_TYPE_NAMES[<i32>t];
}

// The target `t` (a deferred one, as findBindingTarget makes it) with the
// kind `info` resolved: a new target, no longer deferred.
export function resolvedTarget(t: BindingTarget, info: ShaderTargetInfo): BindingTarget {
    const b = new BindingTarget(t.property, info.kind, t.owner, t.doc);
    b.animates = t.animates;
    b.costly = t.costly;
    return b;
}

// The shader parameter targets `node` has now, resolved (for the editor's
// bind popover and Data dock: the family is not in the table): for its
// material_override and its primitive mesh's material, and each of their
// next passes (MAX_NEXT_PASS_HOPS at most) that is a ShaderMaterial with
// a shader, every uniform but a texture, a vector by its components and a
// source_color one whole, in the shader's order. Empty for any other node.
export function shaderBindingTargetsOf(node: SceneNode): Array<BindingTarget> {
    const out = new Array<BindingTarget>();
    for (let holder = SHADER_HOLDER_OVERRIDE; holder <= SHADER_HOLDER_MESH_MATERIAL; holder++) {
        let m = holderMaterial(node, holder);
        for (let hops = 0; hops <= MAX_NEXT_PASS_HOPS && m != null; hops++) {
            const mat = m as StandardMaterial3D;
            const isShader = mat instanceof ShaderMaterial;
            if (isShader) addTargets(out, mat as ShaderMaterial, holder, hops);
            m = mat.nextPass;
        }
    }
    return out;
}

function addTargets(out: Array<BindingTarget>, m: ShaderMaterial, holder: i32, hops: i32): void {
    const p = m.program;
    if (p == null) return;
    const where = (holder == SHADER_HOLDER_OVERRIDE ? "material_override" : "mesh's material") + (hops > 0 ? "'s next pass" : "");
    for (let i = 0; i < p.uniforms.length; i++) {
        const u = p.uniforms[i];
        if (u.type == UniformType.Texture2D) continue;
        const n = uniformComponents(u.type);
        const doc = "The uniform " + u.name + " of the " + where + "'s shader " + p.path + ".";
        if (u.type == UniformType.Bool || n == 1 || u.isColor()) {
            const kind = u.type == UniformType.Bool ? BindKind.Boolean : n == 1 ? BindKind.Number : BindKind.Color;
            const b = new BindingTarget(shaderTargetProperty(holder, hops, u.name, ""), kind, "MeshInstance3D", doc);
            b.animates = true;
            out.push(b);
            continue;
        }
        for (let c = 0; c < n; c++) {
            const b = new BindingTarget(shaderTargetProperty(holder, hops, u.name, COMPONENTS[c]), BindKind.Number, "MeshInstance3D",
                COMPONENTS[c] + ": " + doc);
            b.animates = true;
            out.push(b);
        }
    }
}

// The binding target `property` of `node` with its kind known: what
// findBindingTarget answers for the node's class, a shader parameter
// target (deferred there) resolved against the node's material, or null
// when there is none (a shader target that is none says why only through
// resolveShaderTarget). For the readers that take a node's property by its
// target name outside the binder and the timelines: the state machines'
// component conditions and the scripts' tweens. Made when they first look,
// never per frame.
export function nodeBindingTarget(node: SceneNode, property: string): BindingTarget? {
    const t = findBindingTarget(node.schemaClass(), property);
    if (t == null || !t.deferred) return t;
    const info = resolveShaderTarget(node, property);
    return info.ok ? resolvedTarget(t, info) : null;
}
