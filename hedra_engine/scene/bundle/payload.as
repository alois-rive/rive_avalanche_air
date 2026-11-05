// The payloads of the asset container's entries (milestone 39; format.as
// lays out the container, docs/cli/BUILD.md section 17 these): what both
// the writer (encode.as) and the reader (decode.as) agree on, so that the
// two halves of each layout sit side by side. Everything is little-endian
// and read through ../rscnb/bin.as BinReader, which never traps: a damaged
// payload is a `bundle-invalid` error at the bundle, never a crash.
//
// Each payload starts with its own u32 version (PAYLOAD_VERSION), so that a
// later milestone can grow one kind without a new container version. A
// string inside a payload is `u32 byte length, UTF-8 bytes` (writeStr),
// except in a Model, which holds a string table and a values table
// (../rscnb/values.as) for its objects' properties.
//
// A StandardMaterial3D inside a Model ("inline", the only form a model's
// materials take) is written field by field (writeMaterial / readMaterial,
// below): its scalars in the class's order, then its 20 texture slots
// (PbrSlot order, each a texture's bundle name or "" for none), then each
// slot's UV set and transform. A material file (.mtlx) is not stored this
// way but as a .rscnb material document (kind Material), which a binding or
// a node property can retarget field by field at run time.
//
// Milestone 61: a model's material that is a ShaderMaterial (an .rmdl
// Material with a `shader`) is material form 1 (MATERIAL_FORM_SHADER): the
// record above (its fallback), then the shader's bundle name (its Shader
// entry), u32 n and n parameters, each `str name, u8 kind, str text`: kind
// 0 a value as its text (../value_text.as printValue), kind 1 a texture by
// its bundle name. A model without one writes form 0 throughout, as
// before.
//
// Milestone 62: a StandardMaterial3D whose refraction_scale is not Godot's
// 0.05 (glTF has no field for it) is form 2 (MATERIAL_FORM_REFRACTION):
// form 0's record, then f32 refraction_scale. Never a ShaderMaterial
// (whose own code draws it); every other material is form 0 or 1 as
// before, so that every model built before writes the same bytes.

import { Mat4, Quat, Vec2, Vec3, Vec4 } from "../../base/vecmath";
import { BinReader } from "../rscnb/bin";
import { readKeyedProperties } from "../rscnb/anim";
import { ModelResource, StandardMaterial3D, Texture2D } from "../resource/types";
import { Shader } from "../resource/shader";
import { MorphTarget } from "../../render/mesh";
import {
    BonePose, MAX_SKIN_JOINTS, ModelBone, ModelClip, ModelClipTrack, ModelSkeleton, ModelSkin,
} from "../skeleton/model_skin";

// Every payload's first u32.
export const PAYLOAD_VERSION: u32 = 1;

// Milestone 26: a Mesh payload's version, 2 (version 1, a mesh without
// levels of detail or compression, is still read): its levels of detail
// and, with MESH_COMPRESSED, its vertices and indices compressed
// (docs/cli/BUILD.md section 17, meshes).
export const MESH_PAYLOAD_VERSION: u32 = 2;

// Milestone 48: a Mesh payload with a skin or blend shapes is version 3
// (MESH_SKIN, MESH_MORPHS: their blocks after the vertices and indices,
// never compressed, the vertex codec carrying neither); one without either
// is written as version 2 was, byte for byte. Versions 1 and 2 are still
// read.
export const MESH_PAYLOAD_VERSION_SKIN: u32 = 3;

// Milestone 48: a Model payload whose objects carry skeletons, skins, bone
// attachments or blend shapes, or which has clips, is version 2 (version
// 1's content, then each object's extension and the clips: writeModelRig);
// one without any is version 1 as before.
export const MODEL_PAYLOAD_VERSION_RIG: u32 = 2;

// A Model version 2 object's flags (its extension's u8).
export const RIG_SKELETON: u32 = 1;
export const RIG_SKIN: u32 = 2;
export const RIG_PARENT_BONE: u32 = 4;
export const RIG_BLEND_SHAPES: u32 = 8;
// A clip's flags.
export const CLIP_FLAG_EXACT: u32 = 1;
export const CLIP_FLAG_LOOP: u32 = 2;

// A Mesh's flags (its second u32).
// Built in model space (a model's object, through meshbuild), placed as
// SceneMesh.fromSource places it.
export const MESH_MODEL_SPACE: u32 = 1;
// The mesh has a second UV set (GpuMesh.uv1).
export const MESH_UV1: u32 = 2;
// Version 2: the vertex block is hedra_engine/meshproc/vertex_codec.as
// encodeVertices' bytes (quantised over bounds stored before it) and the
// index block encodeIndices' (every level's indices, level 0's first).
export const MESH_COMPRESSED: u32 = 4;
// Version 3: the skin block (vertexCount x u32 joints, four palette slots a
// byte each, then vertexCount x 4 f32 weights) and the blend shapes' block
// (u32 n, per target str name, u8 hasNormals, vertexCount x 3 f32 position
// deltas, and as many normal deltas when it has them), in that order after
// everything else.
export const MESH_SKIN: u32 = 8;
export const MESH_MORPHS: u32 = 16;

// Milestone 26: the kinds of a TextureFormat.Ktx2 payload's files, in the
// order they are stored (docs/cli/BUILD.md section 17, textures): the source PNG,
// then a KTX2 file of each family (hedra_engine/texture/format.as TextureForm's
// numbers), then the uncompressed rgba8 KTX2 of a texture imported as
// vram_uncompressed.
export const TEXTURE_KIND_SOURCE: u32 = 0;
export const TEXTURE_KIND_BC: u32 = 1;
export const TEXTURE_KIND_ETC2: u32 = 2;
export const TEXTURE_KIND_ASTC: u32 = 3;
export const TEXTURE_KIND_RGBA8: u32 = 4;
export const TEXTURE_KIND_COUNT: u32 = 5;
export const TEXTURE_KIND_NAMES: StaticArray<string> = ["source", "bc", "etc2", "astc", "rgba8"];

// A Ktx2 payload's table entry: 12 bytes ({u32 kind, u32 offset, u32
// size}); files start at multiples of this (offsets from the payload's
// start, which the bundle aligns to 16 too).
export const TEXTURE_TABLE_ENTRY_BYTES: i32 = 12;
export const TEXTURE_FILE_ALIGN: i32 = 16;

// The texture slots a material record holds (hedra_engine/material/pbr.as
// PBR_SLOT_COUNT; StandardMaterial3D.textureAt numbers them).
export const MATERIAL_SLOTS: i32 = 20;

// A lightmap layer's form in a Lightmap payload: the Radiance HDR file's
// bytes (what the .lmbake's sidecar holds; decodeHdr gives the texels back
// exactly), or the texels as f32 when an encoding would not give them back.
export const LAYER_HDR: u32 = 1;
export const LAYER_F32: u32 = 2;

// What writeStr wrote ("" and `r` failed when it does not fit).
export function readStr(r: BinReader): string {
    const n = r.count(1);
    return r.utf8(n);
}

export function readVec3(r: BinReader): Vec3 {
    const x = r.f32();
    const y = r.f32();
    const z = r.f32();
    return Vec3(x, y, z);
}

export function readVec4(r: BinReader): Vec4 {
    const x = r.f32();
    const y = r.f32();
    const z = r.f32();
    const ww = r.f32();
    return Vec4(x, y, z, ww);
}

function readVec2(r: BinReader): Vec2 {
    const x = r.f32();
    const y = r.f32();
    return Vec2(x, y);
}

export function readMat4(r: BinReader): Mat4 {
    const x = readVec4(r);
    const y = readVec4(r);
    const z = readVec4(r);
    const ww = readVec4(r);
    return Mat4(x, y, z, ww);
}

function readBool(r: BinReader): bool {
    const b = r.u8();
    if (b > 1) r.fail("a bool that is neither 0 nor 1");
    return b == 1;
}

// How a material record names a texture: its bundle name ("" for none),
// which the writer works out from the texture's path.
export abstract class TextureNames {
    abstract nameOf(t: Texture2D): string;

    // Milestone 61: the bundle name of a ShaderMaterial's shader ("" when
    // the writer names none: the material is then written as form 0, its
    // fallback alone).
    shaderName(s: Shader): string {
        return "";
    }
}

// Milestone 61: a model's material forms (the u32 before each record).
export const MATERIAL_FORM_INLINE: u32 = 0;
export const MATERIAL_FORM_SHADER: u32 = 1;
// Milestone 62: form 0's record and the material's refraction_scale.
export const MATERIAL_FORM_REFRACTION: u32 = 2;
// The refraction_scale a form 0 or 1 record means (Godot's default).
export const MATERIAL_REFRACTION_SCALE_DEFAULT: f32 = 0.05;
// A form 1 parameter's kind.
export const SHADER_PARAM_VALUE: u32 = 0;
export const SHADER_PARAM_TEXTURE: u32 = 1;

// The texture a material record names, which the reader decodes (once,
// shared by every material that names it); null when it cannot (the reader
// failed).
export abstract class TextureLookup {
    abstract textureOf(name: string): Texture2D?;

    // Milestone 61: the Shader entry `name` holds, or null (its material
    // then draws its fallback).
    shaderOf(name: string): Shader? {
        return null;
    }
}

// The material `writeMaterial` wrote (its textures through `textures`).
export function readMaterial(r: BinReader, textures: TextureLookup): StandardMaterial3D {
    const m = new StandardMaterial3D();
    m.name = readStr(r);
    m.id = readStr(r);
    m.albedoColor = readVec4(r);
    m.metallic = r.f32();
    m.roughness = r.f32();
    m.packedMetallicRoughness = readBool(r);
    m.emissionEnabled = readBool(r);
    m.emission = readVec4(r);
    m.emissionEnergy = r.f32();
    m.normalEnabled = readBool(r);
    m.normalScale = r.f32();
    m.aoEnabled = readBool(r);
    m.transparency = r.i32();
    m.alphaScissorThreshold = r.f32();
    m.cullMode = r.i32();
    m.vertexColorUseAsAlbedo = readBool(r);
    m.vertexColorIsSrgb = readBool(r);
    m.uv1Scale = readVec3(r);
    m.uv1Offset = readVec3(r);
    m.shadingMode = r.i32();
    m.aoStrength = r.f32();
    m.ior = r.f32();
    m.specular = r.f32();
    m.specularColor = readVec4(r);
    m.clearcoatEnabled = readBool(r);
    m.clearcoat = r.f32();
    m.clearcoatRoughness = r.f32();
    m.clearcoatNormalScale = r.f32();
    m.anisotropyEnabled = readBool(r);
    m.anisotropy = r.f32();
    m.anisotropyRotation = r.f32();
    m.sheenColor = readVec4(r);
    m.sheenRoughness = r.f32();
    m.refractionEnabled = readBool(r);
    m.transmission = r.f32();
    m.thickness = r.f32();
    m.attenuationDistance = r.f32();
    m.attenuationColor = readVec4(r);
    m.dispersion = r.f32();
    m.iridescence = r.f32();
    m.iridescenceIor = r.f32();
    m.iridescenceThicknessMinimum = r.f32();
    m.iridescenceThicknessMaximum = r.f32();
    m.backlightEnabled = readBool(r);
    m.diffuseTransmission = r.f32();
    m.backlight = readVec4(r);
    for (let s = 0; s < MATERIAL_SLOTS; s++) {
        const name = readStr(r);
        if (r.failed) break;
        if (name.length == 0) continue;
        const t = textures.textureOf(name);
        if (t == null) {
            r.fail("a material names the texture " + name + ", which the bundle does not hold");
            break;
        }
        m.setTextureAt(s, t);
    }
    for (let s = 0; s < MATERIAL_SLOTS; s++) {
        const uv = m.uvs[s];
        uv.texcoord = r.i32();
        uv.offset = readVec2(r);
        uv.rotation = r.f32();
        uv.scale = readVec2(r);
    }
    return m;
}

// --- milestone 48: skins, blend shapes, skeletons and clips -----------------

export class SkinBlock {
    joints: Array<u32> = [];
    weights: Array<f32> = [];
}

export function readSkinBlock(r: BinReader, vertexCount: i32): SkinBlock? {
    if (<i64>vertexCount * 20 > <i64>r.remaining()) {
        r.fail("its skin block is cut short");
        return null;
    }
    const out = new SkinBlock();
    out.joints = new Array<u32>(vertexCount);
    for (let i = 0; i < vertexCount; i++) unchecked(out.joints[i] = r.u32());
    out.weights = new Array<f32>(vertexCount * 4);
    for (let i = 0; i < vertexCount * 4; i++) {
        const x = r.f32();
        if (!r.failed && !(x >= 0 && x <= 1.0001)) {
            r.fail("a skin weight (" + x.toString() + ") is not from 0 to 1");
            return null;
        }
        unchecked(out.weights[i] = x);
    }
    return r.failed ? null : out;
}

export function readMorphBlock(r: BinReader, vertexCount: i32): Array<MorphTarget>? {
    const n = r.count(5 + vertexCount * 12);
    const out = new Array<MorphTarget>();
    for (let k = 0; k < n && !r.failed; k++) {
        const name = readStr(r);
        const flag = r.u8();
        if (!r.failed && flag > 1) r.fail("a blend shape's normals flag is " + flag.toString());
        if (r.failed) break;
        const need = <i64>vertexCount * 12 * (flag == 1 ? 2 : 1);
        if (need > <i64>r.remaining()) {
            r.fail("blend shape " + name + " is cut short");
            break;
        }
        const pos = new Array<f32>(vertexCount * 3);
        for (let i = 0; i < vertexCount * 3; i++) unchecked(pos[i] = r.f32());
        let normals: Array<f32>? = null;
        if (flag == 1) {
            const nn = new Array<f32>(vertexCount * 3);
            for (let i = 0; i < vertexCount * 3; i++) unchecked(nn[i] = r.f32());
            normals = nn;
        }
        out.push(new MorphTarget(name, pos, normals));
    }
    return r.failed ? null : out;
}

function readPose(r: BinReader): BonePose {
    const position = readVec3(r);
    const q = Quat(r.f32(), r.f32(), r.f32(), r.f32());
    const scale = readVec3(r);
    return new BonePose(position, q, scale);
}

// What writeModelRig wrote, onto `m`'s objects (read already); false with
// the reason in `r.why`.
export function readModelRig(r: BinReader, m: ModelResource): bool {
    const n = m.objects.length;
    for (let i = 0; i < n && !r.failed; i++) {
        const o = m.objects[i];
        const flags = r.u8();
        if (!r.failed && (flags & ~(RIG_SKELETON | RIG_SKIN | RIG_PARENT_BONE | RIG_BLEND_SHAPES)) != 0) {
            r.fail("object " + i.toString() + " has rig flags this version does not know");
            break;
        }
        if ((flags & RIG_SKELETON) != 0) {
            const sk = new ModelSkeleton();
            const nb = r.count(84);
            for (let b = 0; b < nb && !r.failed; b++) {
                const bone = new ModelBone();
                bone.name = readStr(r);
                bone.parent = r.i32();
                if (!r.failed && (bone.parent < -1 || bone.parent >= b)) r.fail("bone " + bone.name + "'s parent is not before it");
                bone.rest = readPose(r);
                bone.pose = readPose(r);
                sk.bones.push(bone);
            }
            o.skeleton = sk;
        }
        if ((flags & RIG_SKIN) != 0) {
            const skin = new ModelSkin();
            skin.skeleton = r.i32();
            const nj = r.count(68);
            if (!r.failed && nj > MAX_SKIN_JOINTS) r.fail("a skin of " + nj.toString() + " joints, more than " + MAX_SKIN_JOINTS.toString());
            for (let k = 0; k < nj && !r.failed; k++) skin.joints.push(r.i32());
            for (let k = 0; k < nj && !r.failed; k++) skin.inverseBinds.push(readMat4(r));
            o.skin = skin;
        }
        if ((flags & RIG_PARENT_BONE) != 0) o.parentBone = readStr(r);
        if ((flags & RIG_BLEND_SHAPES) != 0) {
            const ns = r.count(8);
            for (let k = 0; k < ns && !r.failed; k++) {
                o.blendShapes.push(readStr(r));
                o.blendShapeWeights.push(r.f32());
            }
        }
    }
    // (every skin names a skeleton object, every joint a bone of it)
    for (let i = 0; i < n && !r.failed; i++) {
        const skin = m.objects[i].skin;
        if (skin == null) continue;
        const at = skin.skeleton;
        const sk = at >= 0 && at < n ? m.objects[at].skeleton : null;
        if (sk == null) {
            r.fail("object " + i.toString() + "'s skin names no skeleton");
            break;
        }
        for (let k = 0; k < skin.joints.length; k++) {
            if (skin.joints[k] < 0 || skin.joints[k] >= sk.bones.length) {
                r.fail("object " + i.toString() + "'s skin names bone " + skin.joints[k].toString() + " of " + sk.bones.length.toString());
                break;
            }
        }
    }
    const nc = r.count(17);
    for (let c = 0; c < nc && !r.failed; c++) {
        const clip = new ModelClip();
        clip.name = readStr(r);
        clip.fps = r.i32();
        clip.duration = r.i32();
        if (!r.failed && (clip.fps < 1 || clip.duration < 0)) r.fail("clip " + clip.name + " has no frames to play");
        const flags = r.u8();
        if (!r.failed && (flags & ~(CLIP_FLAG_EXACT | CLIP_FLAG_LOOP)) != 0) r.fail("clip " + clip.name + " has flags this version does not know");
        clip.exact = (flags & CLIP_FLAG_EXACT) != 0;
        clip.loop = (flags & CLIP_FLAG_LOOP) != 0;
        const nt = r.count(4);
        const objects = new Array<i32>();
        for (let t = 0; t < nt && !r.failed; t++) {
            const o = r.i32();
            if (!r.failed && (o < 0 || o >= n)) r.fail("clip " + clip.name + " keys object " + o.toString() + " of " + n.toString());
            objects.push(o);
        }
        if (r.failed) break;
        const props = readKeyedProperties(r, "clip " + clip.name);
        if (props == null) break;
        if (props.length != objects.length) {
            r.fail("clip " + clip.name + " has " + props.length.toString() + " tracks for " + objects.length.toString() + " objects");
            break;
        }
        for (let t = 0; t < props.length; t++) clip.tracks.push(new ModelClipTrack(objects[t], props[t]));
        m.clips.push(clip);
    }
    return !r.failed;
}
