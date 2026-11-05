// The parameters' block of a custom shader (group 2, binding 0 of the
// custom pipelines: the composer's `HedraParams` struct, which it declares
// with the uniforms in the file's order), and the material's values that
// fill it.
//
// The layout is WGSL's for the uniform address space, computed here once
// and by the WGSL compiler from the composed struct, so the two agree by
// construction (the composer writes the members in this order, and
// layoutUniforms is the rule's one implementation on the CPU):
//   f32, i32, u32, and a bool (stored as u32: WGSL has no bool in a
//   uniform block): align 4, size 4; vec2: align 8, size 8; vec3: align
//   16, size 12; vec4: align 16, size 16; each member at the next multiple
//   of its alignment; the struct's size rounded up to 16, at least
//   MIN_PARAM_BLOCK_BYTES (a shader without uniforms has one member,
//   `hedra_unused: vec4<f32>`).
// Textures take no room in the block: each its binding in group 2, from 1
// in the file's order, then one binding per distinct sampler kind, in the
// order the textures first use them.
//
// What the block holds: a number as the file's (an int rounded); a bool 1
// or 0; a source_color vec3 or vec4 linearised from sRGB per channel (its
// alpha kept), as Godot passes a source_color uniform. A parameter the
// material does not set holds the uniform's default. Writing allocates
// nothing: the binding and the timelines write ShaderParams in place, and
// the GPU side packs the block into a buffer it keeps.

import { srgbToLinear } from "../../base/color";
import {
    HINT_SOURCE_COLOR, MIN_PARAM_BLOCK_BYTES, ShaderProgram, ShaderUniform, UniformType, samplerKind,
    uniformComponents,
} from "./program";

// The alignment and the size in the block of a value of `t` (0, 0 for a
// texture).
export function uniformAlign(t: UniformType): i32 {
    switch (t) {
        case UniformType.Vec2:
        case UniformType.IVec2: return 8;
        case UniformType.Vec3:
        case UniformType.IVec3:
        case UniformType.Vec4:
        case UniformType.IVec4: return 16;
        case UniformType.Texture2D: return 0;
        default: return 4;
    }
}

export function uniformSize(t: UniformType): i32 {
    const n = uniformComponents(t);
    return n * 4;
}

// Places every uniform of `p`: offsets and sizes in the block, the
// textures' indices and bindings, the sampler kinds and each texture's
// sampler index; sets blockSize, textureCount and samplers. Run by the
// reader once the declarations are read; the limits are the reader's to
// report (a program over them is still laid out).
export function layoutUniforms(p: ShaderProgram): void {
    let at = 0;
    let textures = 0;
    p.samplers.length = 0;
    for (let i = 0; i < p.uniforms.length; i++) {
        const u = p.uniforms[i];
        if (u.type == UniformType.Texture2D) {
            u.offset = -1;
            u.size = 0;
            u.texture = textures;
            u.binding = 1 + textures;
            textures++;
            continue;
        }
        const a = uniformAlign(u.type);
        at = (at + a - 1) / a * a;
        u.offset = at;
        u.size = uniformSize(u.type);
        u.texture = -1;
        u.binding = -1;
        u.sampler = -1;
        at += u.size;
    }
    let size = (at + 15) / 16 * 16;
    if (size < MIN_PARAM_BLOCK_BYTES) size = MIN_PARAM_BLOCK_BYTES;
    p.blockSize = size;
    p.textureCount = textures;
    for (let i = 0; i < p.uniforms.length; i++) {
        const u = p.uniforms[i];
        if (u.type != UniformType.Texture2D) continue;
        const kind = samplerKind(u.filter, u.repeat);
        let k = p.samplers.indexOf(kind);
        if (k < 0) {
            k = p.samplers.length;
            p.samplers.push(kind);
        }
        u.sampler = k;
    }
}

// The group-2 binding of sampler `k` of `p` (after its textures).
export function samplerBinding(p: ShaderProgram, k: i32): i32 {
    return 1 + p.textureCount + k;
}

// How many group-2 bindings past the block `p` takes (textures and
// samplers): at most MAX_SHADER_SLOTS.
export function slotCount(p: ShaderProgram): i32 {
    return p.textureCount + p.samplers.length;
}

// A material's values of a shader's parameters, by uniform index: four
// numbers each (uniformComponents of them used), whether the material
// sets it (else the uniform's default is drawn and the Inspector shows
// it), and, for a texture, nothing here (the material holds its texture:
// ../custom_material.as and the scene's ShaderMaterial).
export class ShaderParams {
    nums: Float64Array;
    set: Uint8Array;
    // Bumped by every write (./layout.as callers and the binding's): the
    // GPU side writes the block again when it moved.
    version: i32 = 0;

    constructor(count: i32) {
        this.nums = new Float64Array(count * 4);
        this.set = new Uint8Array(count);
    }

    get count(): i32 {
        return this.set.length;
    }

    // Component `c` of parameter `i` as drawn: the material's when set,
    // else the default of `p`'s uniform.
    value(p: ShaderProgram, i: i32, c: i32): f64 {
        if (this.set[i] != 0) return this.nums[i * 4 + c];
        return p.uniforms[i].def[c];
    }

    // Sets component `c` of parameter `i` of `p` (marks it set, its other
    // components taking the default first; no allocation).
    write(p: ShaderProgram, i: i32, c: i32, x: f64): void {
        if (this.set[i] == 0) this.materialise(p, i);
        this.nums[i * 4 + c] = x;
        this.version++;
    }

    // Copies the default of every component of parameter `i` of `p` in,
    // then marks it set (a binding writing one component of an unset
    // vector keeps the others' defaults).
    materialise(p: ShaderProgram, i: i32): void {
        if (this.set[i] != 0) return;
        for (let c = 0; c < 4; c++) this.nums[i * 4 + c] = p.uniforms[i].def[c];
        this.set[i] = 1;
        this.version++;
    }

    // Forgets parameter `i`'s value: the default is drawn again.
    unset(i: i32): void {
        if (this.set[i] == 0) return;
        this.set[i] = 0;
        this.version++;
    }
}

// The values of `p`'s parameters, none set (every one its default).
export function defaultParams(p: ShaderProgram): ShaderParams {
    return new ShaderParams(p.uniforms.length);
}

// Packs `v`'s parameters of `p` into the block at byte `at` of `out`
// (p.blockSize bytes, the rest zero): the rule of this file's header.
export function writeParamBlock(p: ShaderProgram, v: ShaderParams, out: DataView, at: i32 = 0): void {
    for (let b = 0; b < p.blockSize; b += 4) out.setUint32(at + b, 0, true);
    for (let i = 0; i < p.uniforms.length && i < v.count; i++) {
        const u = p.uniforms[i];
        if (u.offset < 0) continue;
        writeUniform(u, p, v, i, out, at + u.offset);
    }
}

function writeUniform(u: ShaderUniform, p: ShaderProgram, v: ShaderParams, i: i32, out: DataView, o: i32): void {
    const n = uniformComponents(u.type);
    const color = (u.hints & HINT_SOURCE_COLOR) != 0 && (u.type == UniformType.Vec3 || u.type == UniformType.Vec4);
    for (let c = 0; c < n; c++) {
        const x = v.value(p, i, c);
        const b = o + c * 4;
        switch (u.type) {
            case UniformType.Int:
            case UniformType.IVec2:
            case UniformType.IVec3:
            case UniformType.IVec4:
                out.setInt32(b, <i32>Math.round(x), true);
                break;
            case UniformType.UInt:
                out.setUint32(b, x <= 0 ? 0 : <u32>Math.round(x), true);
                break;
            case UniformType.Bool:
                out.setUint32(b, x != 0 ? 1 : 0, true);
                break;
            default: {
                const f = <f32>x;
                out.setFloat32(b, color && c < 3 ? srgbToLinear(f) : f, true);
            }
        }
    }
}
