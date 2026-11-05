// Milestone 61 (docs/engine/SHADERS.md, "Binding and keying parameters"):
// the names of the shader parameter targets, told from the property string
// alone, as ./targets.as tells its table's (this file imports only
// classdb, so the validator may use it):
//
//   material_override:[next_pass:]*shader_parameter/<name>[:x|:y|:z|:w]
//   mesh:material:[next_pass:]*shader_parameter/<name>[:x|:y|:z|:w]
//
// A ShaderMaterial's parameter on the node's material_override or its
// mesh's material, or on a next pass of either (`next_pass:` once a pass,
// at most MAX_NEXT_PASS_HOPS), the whole uniform or one component of a
// vector's. Which kind it is (a number, a bool, a colour), and whether it
// is one at all, only the node's material tells: ./shader_targets.as
// resolves it when the scene is bound or its timelines instanced.

import { shaderParameterOf } from "../classdb";

export const MATERIAL_OVERRIDE_PREFIX = "material_override:";
export const MESH_MATERIAL_PREFIX = "mesh:material:";
export const NEXT_PASS_PREFIX = "next_pass:";

// The resource a shader target's material is (ShaderTargetName.holder).
export const SHADER_HOLDER_OVERRIDE: i32 = 0;
export const SHADER_HOLDER_MESH_MATERIAL: i32 = 1;

// How many next passes a target may follow: the depth the renderer draws
// (Godot has no limit; four is Hedra's budget, warned past it as
// material-next-pass-deep).
export const MAX_NEXT_PASS_HOPS: i32 = 4;

// A shader parameter target taken apart.
export class ShaderTargetName {
    holder: i32 = SHADER_HOLDER_OVERRIDE;
    // How many `next_pass:` it follows.
    hops: i32 = 0;
    // The uniform's name (the part after `shader_parameter/`).
    param: string = "";
    // The component (0 x, 1 y, 2 z, 3 w), -1 for the whole uniform.
    axis: i32 = -1;
}

// Whether `property` starts like a shader parameter target (a holder's
// prefix, then next passes, then `shader_parameter/`): what findBindingTarget
// asks before its table. A malformed one (no name, a bad component) is
// still one of these, and answers null from parseShaderTargetName.
export function isShaderTargetName(property: string): bool {
    let at = holderEnd(property);
    if (at < 0) return false;
    while (property.startsWith(NEXT_PASS_PREFIX, at)) at += NEXT_PASS_PREFIX.length;
    return property.startsWith("shader_parameter/", at);
}

// The index past a holder's prefix, -1 for none.
function holderEnd(property: string): i32 {
    if (property.startsWith(MATERIAL_OVERRIDE_PREFIX)) return MATERIAL_OVERRIDE_PREFIX.length;
    if (property.startsWith(MESH_MATERIAL_PREFIX)) return MESH_MATERIAL_PREFIX.length;
    return -1;
}

// The target `property` names, or null when it is not a well formed one
// (asked when a scene is checked or bound, never per frame).
export function parseShaderTargetName(property: string): ShaderTargetName? {
    const start = holderEnd(property);
    if (start < 0) return null;
    const out = new ShaderTargetName();
    out.holder = property.startsWith(MATERIAL_OVERRIDE_PREFIX) ? SHADER_HOLDER_OVERRIDE : SHADER_HOLDER_MESH_MATERIAL;
    let at = start;
    while (property.startsWith(NEXT_PASS_PREFIX, at)) {
        at += NEXT_PASS_PREFIX.length;
        out.hops++;
    }
    if (out.hops > MAX_NEXT_PASS_HOPS) return null;
    let rest = property.substring(at);
    const n = rest.length;
    if (n > 2 && rest.charCodeAt(n - 2) == 0x3a) {
        const c = rest.charCodeAt(n - 1);
        // (w, x, y, z: w is 3)
        if (c >= 0x77 && c <= 0x7a) {
            out.axis = c == 0x77 ? 3 : c - 0x78;
            rest = rest.substring(0, n - 2);
        }
    }
    const param = shaderParameterOf(rest);
    if (param == null) return null;
    out.param = param;
    return out;
}

// The property of a target: its holder's prefix, `hops` next passes, the
// parameter and its component ("" none, else "x" to "w").
export function shaderTargetProperty(holder: i32, hops: i32, param: string, component: string): string {
    let s = holder == SHADER_HOLDER_OVERRIDE ? MATERIAL_OVERRIDE_PREFIX : MESH_MATERIAL_PREFIX;
    for (let i = 0; i < hops; i++) s += NEXT_PASS_PREFIX;
    s += "shader_parameter/" + param;
    if (component.length > 0) s += ":" + component;
    return s;
}
