// Milestone 42: the properties of a node's resources a binding drives
// (docs/plans/RIVE_MODEL.md section 3.1, "Sub-properties of resources"):
// a StandardMaterial3D's (material_override:<p>, mesh:material:<p>), an
// Environment's (environment:<p>), a PrimitiveMesh's (mesh:<p>) and,
// milestone 37, a FogVolume's FogMaterial's (material:<p>), read
// and written by their .rscn names, typed, in place: no Value is made, so
// a frame that writes them allocates nothing.
//
// A resource is shared: a material that three nodes use changes for all
// three (Godot's rule, and milestone 17's). Changing a primitive mesh's
// geometry is `costly` (../classdb.as PropInfo.costly): the mesh's
// triangles are generated again (PrimitiveMesh.invalidate, so the render
// cache, keyed by the generated ArrayMesh, builds a new GPU mesh), and the
// write answers FIELD_REBUILT so that the binder counts it. A material's
// fields are read by the renderer each plan, so a changed one, even one
// that picks another pipeline (transparency, cull_mode), is drawn by the
// next picture.
//
// The field holder (FieldIO) carries one value of each kind; a vector's
// component and a colour's bytes are the caller's (../binding/apply.as).
//
// Milestone 61: a ShaderMaterial's fields are its shader's uniforms,
// `shader_parameter/<name>` (../resource/shader.as), read from and written
// to its `params` in place (ShaderParams.write: the uniform found by
// comparing its name with the field's tail, no substring made): a bool
// F_BOOL, a float F_NUMBER, an integer F_INT, a vector F_VEC2, F_VEC3 or
// F_VEC4 (an integer vector's components as numbers, rounded when drawn),
// a source_color vec3 or vec4 F_COLOR (sRGB with straight alpha, as every
// colour of the format; a vec3's alpha reads 1 and is not written). A
// texture uniform, a name the shader lacks and every StandardMaterial3D
// name (albedo_color, ...) are F_NONE: Godot's ShaderMaterial has no
// albedo, and its fallback fields are not its properties. Its
// render_priority (Godot's Material's) is F_INT, as a StandardMaterial3D's.

import { Vec2, Vec3, Vec4 } from "../../base/vecmath";
import { Environment, Resource, StandardMaterial3D } from "../resource/types";
import { ShaderMaterial } from "../resource/shader";
import { ShaderProgram, UniformType } from "../../render/shader/program";
import { BoxMesh, CylinderMesh, PlaneMesh, PrimitiveMesh, SphereMesh } from "../resource/primitives";
import { MATERIAL_TEXTURE_PROPS, MATERIAL_UV_SUFFIXES } from "../classdb";
import { FogMaterial } from "../resource/fog_material";
import { CameraAttributesPractical } from "../resource/camera_attributes";

// What a field holds (the answer of the accessors below; F_NONE: no such
// field).
export const F_NONE: i32 = -1;
export const F_NUMBER: i32 = 0;
export const F_INT: i32 = 1;
export const F_BOOL: i32 = 2;
export const F_COLOR: i32 = 3;
export const F_VEC2: i32 = 4;
export const F_VEC3: i32 = 5;
// Milestone 61: a ShaderMaterial's vec4 (or ivec4) uniform.
export const F_VEC4: i32 = 6;

// What a write did.
export const FIELD_MISSING: i32 = 0;
export const FIELD_SET: i32 = 1;
// A primitive mesh's geometry changed: its triangles are made again.
export const FIELD_REBUILT: i32 = 2;

// One field's value, of the kind the accessor answered.
export class FieldIO {
    f: f64 = 0;
    i: i32 = 0;
    b: bool = false;
    c: Vec4 = Vec4(0, 0, 0, 0);
    v2: Vec2 = Vec2(0, 0);
    v3: Vec3 = Vec3(0, 0, 0);
    v4: Vec4 = Vec4(0, 0, 0, 0);
}

// Reads (`w` false) or writes (`w` true) the field `n` of `r` through `io`;
// the field's kind, F_NONE when `r` has no such field.
export function resourceField(r: Resource, n: string, io: FieldIO, w: bool): i32 {
    // (milestone 61: before StandardMaterial3D, which it derives from here)
    const isShader = r instanceof ShaderMaterial;
    if (isShader) return shaderField(r as ShaderMaterial, n, io, w);
    const isMaterial = r instanceof StandardMaterial3D;
    if (isMaterial) return materialField(r as StandardMaterial3D, n, io, w);
    const isEnvironment = r instanceof Environment;
    if (isEnvironment) return environmentField(r as Environment, n, io, w);
    const isPrimitive = r instanceof PrimitiveMesh;
    if (isPrimitive) return primitiveField(r as PrimitiveMesh, n, io, w);
    // Milestone 37: a FogVolume's FogMaterial (material:<p>).
    const isFog = r instanceof FogMaterial;
    if (isFog) return fogMaterialField(r as FogMaterial, n, io, w);
    // Milestone 62: a camera's (attributes:<p>) or a WorldEnvironment's
    // (camera_attributes:<p>) CameraAttributesPractical.
    const isAttributes = r instanceof CameraAttributesPractical;
    if (isAttributes) return cameraAttributesField(r as CameraAttributesPractical, n, io, w);
    return F_NONE;
}

// Milestone 62: a CameraAttributesPractical's drawn fields (the ones that
// take flags: ../classdb.as; ../resource/camera_attributes.as reads the
// same names from a file).
export function cameraAttributesField(a: CameraAttributesPractical, n: string, io: FieldIO, w: bool): i32 {
    if (n == "exposure_multiplier") {
        if (w) a.exposureMultiplier = <f32>io.f;
        else io.f = <f64>a.exposureMultiplier;
        return F_NUMBER;
    }
    if (n == "dof_blur_far_enabled") {
        if (w) a.dofBlurFarEnabled = io.b;
        else io.b = a.dofBlurFarEnabled;
        return F_BOOL;
    }
    if (n == "dof_blur_far_distance") {
        if (w) a.dofBlurFarDistance = <f32>io.f;
        else io.f = <f64>a.dofBlurFarDistance;
        return F_NUMBER;
    }
    if (n == "dof_blur_far_transition") {
        if (w) a.dofBlurFarTransition = <f32>io.f;
        else io.f = <f64>a.dofBlurFarTransition;
        return F_NUMBER;
    }
    if (n == "dof_blur_near_enabled") {
        if (w) a.dofBlurNearEnabled = io.b;
        else io.b = a.dofBlurNearEnabled;
        return F_BOOL;
    }
    if (n == "dof_blur_near_distance") {
        if (w) a.dofBlurNearDistance = <f32>io.f;
        else io.f = <f64>a.dofBlurNearDistance;
        return F_NUMBER;
    }
    if (n == "dof_blur_near_transition") {
        if (w) a.dofBlurNearTransition = <f32>io.f;
        else io.f = <f64>a.dofBlurNearTransition;
        return F_NUMBER;
    }
    if (n == "dof_blur_amount") {
        if (w) a.dofBlurAmount = <f32>io.f;
        else io.f = <f64>a.dofBlurAmount;
        return F_NUMBER;
    }
    return F_NONE;
}

// Milestone 37: a FogMaterial's fields (../resource/build.as reads the same
// names), as the file has them (sRGB colours; the clamps are the frame's:
// ../render/fog_volumes.as).
export function fogMaterialField(e: FogMaterial, n: string, io: FieldIO, w: bool): i32 {
    if (n == "density") {
        if (w) e.density = <f32>io.f;
        else io.f = <f64>e.density;
        return F_NUMBER;
    }
    if (n == "albedo") {
        if (w) e.albedo = io.c;
        else io.c = e.albedo;
        return F_COLOR;
    }
    if (n == "emission") {
        if (w) e.emission = io.c;
        else io.c = e.emission;
        return F_COLOR;
    }
    if (n == "height_falloff") {
        if (w) e.heightFalloff = <f32>io.f;
        else io.f = <f64>e.heightFalloff;
        return F_NUMBER;
    }
    if (n == "edge_fade") {
        if (w) e.edgeFade = <f32>io.f;
        else io.f = <f64>e.edgeFade;
        return F_NUMBER;
    }
    return F_NONE;
}

// What a ShaderMaterial's parameter's field starts with.
const SHADER_FIELD_PREFIX = "shader_parameter/";

// The index of the uniform of `p` that the field `n`
// (`shader_parameter/<name>`) names, or -1: compared in place, so that a
// frame writing a parameter allocates nothing.
export function shaderFieldUniform(p: ShaderProgram, n: string): i32 {
    const start = SHADER_FIELD_PREFIX.length;
    if (!n.startsWith(SHADER_FIELD_PREFIX)) return -1;
    const len = n.length - start;
    const us = p.uniforms;
    for (let i = 0; i < us.length; i++) {
        const name = unchecked(us[i]).name;
        if (name.length != len) continue;
        let same = true;
        for (let k = 0; k < len && same; k++) same = name.charCodeAt(k) == n.charCodeAt(start + k);
        if (same) return i;
    }
    return -1;
}

// Milestone 61: Godot's Material.render_priority, every material's (a
// StandardMaterial3D's and a ShaderMaterial's): an int, clamped to Godot's
// -128 to 127 as the file's is (../resource/build.as). The renderer reads
// it each plan, so a keyed or bound priority orders the next picture.
function priorityField(m: StandardMaterial3D, io: FieldIO, w: bool): i32 {
    if (w) m.renderPriority = io.i < -128 ? -128 : io.i > 127 ? 127 : io.i;
    else io.i = m.renderPriority;
    return F_INT;
}

// Milestone 61: a ShaderMaterial's `shader_parameter/<name>` (see the
// header), in its `params`, and its render_priority.
export function shaderField(m: ShaderMaterial, n: string, io: FieldIO, w: bool): i32 {
    if (n == "render_priority") return priorityField(m, io, w);
    const p = m.program;
    if (p == null) return F_NONE;
    const i = shaderFieldUniform(p, n);
    if (i < 0) return F_NONE;
    const u = unchecked(p.uniforms[i]);
    const v = m.params;
    switch (u.type) {
        case UniformType.Bool:
            if (w) v.write(p, i, 0, io.b ? 1 : 0);
            else io.b = v.value(p, i, 0) != 0;
            return F_BOOL;
        case UniformType.Float:
            if (w) v.write(p, i, 0, io.f);
            else io.f = v.value(p, i, 0);
            return F_NUMBER;
        case UniformType.Int:
        case UniformType.UInt:
            if (w) v.write(p, i, 0, <f64>io.i);
            else io.i = <i32>Math.round(v.value(p, i, 0));
            return F_INT;
        case UniformType.Vec2:
        case UniformType.IVec2:
            if (w) {
                v.write(p, i, 0, <f64>io.v2.x);
                v.write(p, i, 1, <f64>io.v2.y);
            } else io.v2 = Vec2(<f32>v.value(p, i, 0), <f32>v.value(p, i, 1));
            return F_VEC2;
        case UniformType.Vec3:
        case UniformType.IVec3:
            if (u.isColor()) {
                if (w) {
                    v.write(p, i, 0, <f64>io.c.x);
                    v.write(p, i, 1, <f64>io.c.y);
                    v.write(p, i, 2, <f64>io.c.z);
                } else io.c = Vec4(<f32>v.value(p, i, 0), <f32>v.value(p, i, 1), <f32>v.value(p, i, 2), 1);
                return F_COLOR;
            }
            if (w) {
                v.write(p, i, 0, <f64>io.v3.x);
                v.write(p, i, 1, <f64>io.v3.y);
                v.write(p, i, 2, <f64>io.v3.z);
            } else io.v3 = Vec3(<f32>v.value(p, i, 0), <f32>v.value(p, i, 1), <f32>v.value(p, i, 2));
            return F_VEC3;
        case UniformType.Vec4:
        case UniformType.IVec4: {
            const color = u.isColor();
            if (w) {
                const x = color ? io.c : io.v4;
                v.write(p, i, 0, <f64>x.x);
                v.write(p, i, 1, <f64>x.y);
                v.write(p, i, 2, <f64>x.z);
                v.write(p, i, 3, <f64>x.w);
            } else {
                const x = Vec4(<f32>v.value(p, i, 0), <f32>v.value(p, i, 1), <f32>v.value(p, i, 2), <f32>v.value(p, i, 3));
                if (color) io.c = x;
                else io.v4 = x;
            }
            return color ? F_COLOR : F_VEC4;
        }
        default:
            return F_NONE;
    }
}

// Whether `r` is a primitive mesh, whose fields are costly to write.
export function rebuildsOnWrite(r: Resource): bool {
    const isPrimitive = r instanceof PrimitiveMesh;
    return isPrimitive;
}

// Writes the field and makes a primitive mesh's triangles again: what the
// write did (FIELD_MISSING when there is no such field).
export function writeResourceField(r: Resource, n: string, io: FieldIO): i32 {
    if (resourceField(r, n, io, true) == F_NONE) return FIELD_MISSING;
    r.writes++;
    if (!rebuildsOnWrite(r)) return FIELD_SET;
    (r as PrimitiveMesh).invalidate();
    return FIELD_REBUILT;
}

// StandardMaterial3D's fields (../resource/build.as reads the same names),
// then each texture slot's `_offset`, `_rotation`, `_scale` and
// `_texcoord`.
export function materialField(m: StandardMaterial3D, n: string, io: FieldIO, w: bool): i32 {
    if (n == "render_priority") return priorityField(m, io, w);
    if (n == "albedo_color") {
        if (w) m.albedoColor = io.c;
        else io.c = m.albedoColor;
        return F_COLOR;
    }
    if (n == "metallic") {
        if (w) m.metallic = <f32>io.f;
        else io.f = <f64>m.metallic;
        return F_NUMBER;
    }
    if (n == "roughness") {
        if (w) m.roughness = <f32>io.f;
        else io.f = <f64>m.roughness;
        return F_NUMBER;
    }
    if (n == "emission_enabled") {
        if (w) m.emissionEnabled = io.b;
        else io.b = m.emissionEnabled;
        return F_BOOL;
    }
    if (n == "emission") {
        if (w) m.emission = io.c;
        else io.c = m.emission;
        return F_COLOR;
    }
    if (n == "emission_energy_multiplier") {
        if (w) m.emissionEnergy = <f32>io.f;
        else io.f = <f64>m.emissionEnergy;
        return F_NUMBER;
    }
    if (n == "normal_enabled") {
        if (w) m.normalEnabled = io.b;
        else io.b = m.normalEnabled;
        return F_BOOL;
    }
    if (n == "normal_scale") {
        if (w) m.normalScale = <f32>io.f;
        else io.f = <f64>m.normalScale;
        return F_NUMBER;
    }
    if (n == "ao_enabled") {
        if (w) m.aoEnabled = io.b;
        else io.b = m.aoEnabled;
        return F_BOOL;
    }
    if (n == "transparency") {
        if (w) m.transparency = io.i;
        else io.i = m.transparency;
        return F_INT;
    }
    if (n == "alpha_scissor_threshold") {
        if (w) m.alphaScissorThreshold = <f32>io.f;
        else io.f = <f64>m.alphaScissorThreshold;
        return F_NUMBER;
    }
    if (n == "cull_mode") {
        if (w) m.cullMode = io.i;
        else io.i = m.cullMode;
        return F_INT;
    }
    if (n == "vertex_color_use_as_albedo") {
        if (w) m.vertexColorUseAsAlbedo = io.b;
        else io.b = m.vertexColorUseAsAlbedo;
        return F_BOOL;
    }
    if (n == "vertex_color_is_srgb") {
        if (w) m.vertexColorIsSrgb = io.b;
        else io.b = m.vertexColorIsSrgb;
        return F_BOOL;
    }
    if (n == "uv1_scale") {
        if (w) m.uv1Scale = io.v3;
        else io.v3 = m.uv1Scale;
        return F_VEC3;
    }
    if (n == "uv1_offset") {
        if (w) m.uv1Offset = io.v3;
        else io.v3 = m.uv1Offset;
        return F_VEC3;
    }
    if (n == "shading_mode") {
        if (w) m.shadingMode = io.i;
        else io.i = m.shadingMode;
        return F_INT;
    }
    // Milestone 35: Godot's billboard (drawn on a CPUParticles3D's mesh).
    if (n == "billboard_mode") {
        if (w) m.billboardMode = io.i;
        else io.i = m.billboardMode;
        return F_INT;
    }
    if (n == "billboard_keep_scale") {
        if (w) m.billboardKeepScale = io.b;
        else io.b = m.billboardKeepScale;
        return F_BOOL;
    }
    if (n == "ao_strength") {
        if (w) m.aoStrength = <f32>io.f;
        else io.f = <f64>m.aoStrength;
        return F_NUMBER;
    }
    if (n == "ior") {
        if (w) m.ior = <f32>io.f;
        else io.f = <f64>m.ior;
        return F_NUMBER;
    }
    if (n == "specular") {
        if (w) m.specular = <f32>io.f;
        else io.f = <f64>m.specular;
        return F_NUMBER;
    }
    if (n == "specular_color") {
        if (w) m.specularColor = io.c;
        else io.c = m.specularColor;
        return F_COLOR;
    }
    if (n == "clearcoat_enabled") {
        if (w) m.clearcoatEnabled = io.b;
        else io.b = m.clearcoatEnabled;
        return F_BOOL;
    }
    if (n == "clearcoat") {
        if (w) m.clearcoat = <f32>io.f;
        else io.f = <f64>m.clearcoat;
        return F_NUMBER;
    }
    if (n == "clearcoat_roughness") {
        if (w) m.clearcoatRoughness = <f32>io.f;
        else io.f = <f64>m.clearcoatRoughness;
        return F_NUMBER;
    }
    if (n == "clearcoat_normal_scale") {
        if (w) m.clearcoatNormalScale = <f32>io.f;
        else io.f = <f64>m.clearcoatNormalScale;
        return F_NUMBER;
    }
    if (n == "anisotropy_enabled") {
        if (w) m.anisotropyEnabled = io.b;
        else io.b = m.anisotropyEnabled;
        return F_BOOL;
    }
    if (n == "anisotropy") {
        if (w) m.anisotropy = <f32>io.f;
        else io.f = <f64>m.anisotropy;
        return F_NUMBER;
    }
    if (n == "anisotropy_rotation") {
        if (w) m.anisotropyRotation = <f32>io.f;
        else io.f = <f64>m.anisotropyRotation;
        return F_NUMBER;
    }
    if (n == "sheen_color") {
        if (w) m.sheenColor = io.c;
        else io.c = m.sheenColor;
        return F_COLOR;
    }
    if (n == "sheen_roughness") {
        if (w) m.sheenRoughness = <f32>io.f;
        else io.f = <f64>m.sheenRoughness;
        return F_NUMBER;
    }
    if (n == "refraction_enabled") {
        if (w) m.refractionEnabled = io.b;
        else io.b = m.refractionEnabled;
        return F_BOOL;
    }
    if (n == "refraction_scale") {
        if (w) m.refractionScale = <f32>io.f;
        else io.f = <f64>m.refractionScale;
        return F_NUMBER;
    }
    if (n == "transmission") {
        if (w) m.transmission = <f32>io.f;
        else io.f = <f64>m.transmission;
        return F_NUMBER;
    }
    if (n == "thickness") {
        if (w) m.thickness = <f32>io.f;
        else io.f = <f64>m.thickness;
        return F_NUMBER;
    }
    if (n == "attenuation_distance") {
        if (w) m.attenuationDistance = <f32>io.f;
        else io.f = <f64>m.attenuationDistance;
        return F_NUMBER;
    }
    if (n == "attenuation_color") {
        if (w) m.attenuationColor = io.c;
        else io.c = m.attenuationColor;
        return F_COLOR;
    }
    if (n == "dispersion") {
        if (w) m.dispersion = <f32>io.f;
        else io.f = <f64>m.dispersion;
        return F_NUMBER;
    }
    if (n == "iridescence") {
        if (w) m.iridescence = <f32>io.f;
        else io.f = <f64>m.iridescence;
        return F_NUMBER;
    }
    if (n == "iridescence_ior") {
        if (w) m.iridescenceIor = <f32>io.f;
        else io.f = <f64>m.iridescenceIor;
        return F_NUMBER;
    }
    if (n == "iridescence_thickness_minimum") {
        if (w) m.iridescenceThicknessMinimum = <f32>io.f;
        else io.f = <f64>m.iridescenceThicknessMinimum;
        return F_NUMBER;
    }
    if (n == "iridescence_thickness_maximum") {
        if (w) m.iridescenceThicknessMaximum = <f32>io.f;
        else io.f = <f64>m.iridescenceThicknessMaximum;
        return F_NUMBER;
    }
    if (n == "backlight_enabled") {
        if (w) m.backlightEnabled = io.b;
        else io.b = m.backlightEnabled;
        return F_BOOL;
    }
    if (n == "diffuse_transmission") {
        if (w) m.diffuseTransmission = <f32>io.f;
        else io.f = <f64>m.diffuseTransmission;
        return F_NUMBER;
    }
    if (n == "backlight") {
        if (w) m.backlight = io.c;
        else io.c = m.backlight;
        return F_COLOR;
    }
    return materialUvField(m, n, io, w);
}

function materialUvField(m: StandardMaterial3D, n: string, io: FieldIO, w: bool): i32 {
    for (let k = 0; k < MATERIAL_UV_SUFFIXES.length; k++) {
        const suffix = MATERIAL_UV_SUFFIXES[k];
        if (!n.endsWith(suffix)) continue;
        const base = n.length - suffix.length;
        for (let slot = 0; slot < MATERIAL_TEXTURE_PROPS.length; slot++) {
            const t = MATERIAL_TEXTURE_PROPS[slot];
            // (compared in place: no substring is made)
            if (t.length != base || !n.startsWith(t)) continue;
            const uv = m.uvs[slot];
            if (k == 0) {
                if (w) uv.texcoord = io.i;
                else io.i = uv.texcoord;
                return F_INT;
            }
            if (k == 1) {
                if (w) uv.offset = io.v2;
                else io.v2 = uv.offset;
                return F_VEC2;
            }
            if (k == 2) {
                if (w) uv.rotation = <f32>io.f;
                else io.f = <f64>uv.rotation;
                return F_NUMBER;
            }
            if (w) uv.scale = io.v2;
            else io.v2 = uv.scale;
            return F_VEC2;
        }
    }
    return F_NONE;
}

// Environment's fields, glow_levels/1 to /7 among them.
export function environmentField(e: Environment, n: string, io: FieldIO, w: bool): i32 {
    if (n == "background_mode") {
        if (w) e.backgroundMode = io.i;
        else io.i = e.backgroundMode;
        return F_INT;
    }
    if (n == "background_color") {
        if (w) e.backgroundColor = io.c;
        else io.c = e.backgroundColor;
        return F_COLOR;
    }
    if (n == "background_energy_multiplier") {
        if (w) e.backgroundEnergy = <f32>io.f;
        else io.f = <f64>e.backgroundEnergy;
        return F_NUMBER;
    }
    if (n == "sky_rotation") {
        if (w) e.skyRotation = io.v3;
        else io.v3 = e.skyRotation;
        return F_VEC3;
    }
    if (n == "ambient_light_source") {
        if (w) e.ambientLightSource = io.i;
        else io.i = e.ambientLightSource;
        return F_INT;
    }
    if (n == "ambient_light_color") {
        if (w) e.ambientLightColor = io.c;
        else io.c = e.ambientLightColor;
        return F_COLOR;
    }
    if (n == "ambient_light_sky_contribution") {
        if (w) e.ambientLightSkyContribution = <f32>io.f;
        else io.f = <f64>e.ambientLightSkyContribution;
        return F_NUMBER;
    }
    if (n == "ambient_light_energy") {
        if (w) e.ambientLightEnergy = <f32>io.f;
        else io.f = <f64>e.ambientLightEnergy;
        return F_NUMBER;
    }
    if (n == "reflected_light_source") {
        if (w) e.reflectedLightSource = io.i;
        else io.i = e.reflectedLightSource;
        return F_INT;
    }
    if (n == "sky_top_color") {
        if (w) e.skyTopColor = io.c;
        else io.c = e.skyTopColor;
        return F_COLOR;
    }
    if (n == "sky_horizon_color") {
        if (w) e.skyHorizonColor = io.c;
        else io.c = e.skyHorizonColor;
        return F_COLOR;
    }
    if (n == "ground_bottom_color") {
        if (w) e.groundBottomColor = io.c;
        else io.c = e.groundBottomColor;
        return F_COLOR;
    }
    if (n == "ground_horizon_color") {
        if (w) e.groundHorizonColor = io.c;
        else io.c = e.groundHorizonColor;
        return F_COLOR;
    }
    if (n == "tonemap_mode") {
        if (w) e.tonemapMode = io.i;
        else io.i = e.tonemapMode;
        return F_INT;
    }
    if (n == "tonemap_exposure") {
        if (w) e.tonemapExposure = <f32>io.f;
        else io.f = <f64>e.tonemapExposure;
        return F_NUMBER;
    }
    if (n == "tonemap_white") {
        if (w) e.tonemapWhite = <f32>io.f;
        else io.f = <f64>e.tonemapWhite;
        return F_NUMBER;
    }
    // Milestone 62.
    if (n == "ssr_enabled") {
        if (w) e.ssrEnabled = io.b;
        else io.b = e.ssrEnabled;
        return F_BOOL;
    }
    if (n == "ssr_max_steps") {
        if (w) e.ssrMaxSteps = io.i;
        else io.i = e.ssrMaxSteps;
        return F_INT;
    }
    if (n == "ssr_fade_in") {
        if (w) e.ssrFadeIn = <f32>io.f;
        else io.f = <f64>e.ssrFadeIn;
        return F_NUMBER;
    }
    if (n == "ssr_fade_out") {
        if (w) e.ssrFadeOut = <f32>io.f;
        else io.f = <f64>e.ssrFadeOut;
        return F_NUMBER;
    }
    if (n == "ssr_depth_tolerance") {
        if (w) e.ssrDepthTolerance = <f32>io.f;
        else io.f = <f64>e.ssrDepthTolerance;
        return F_NUMBER;
    }
    if (n == "screen_refraction_enabled") {
        if (w) e.screenRefractionEnabled = io.b;
        else io.b = e.screenRefractionEnabled;
        return F_BOOL;
    }
    if (n == "ssao_enabled") {
        if (w) e.ssaoEnabled = io.b;
        else io.b = e.ssaoEnabled;
        return F_BOOL;
    }
    if (n == "ssao_radius") {
        if (w) e.ssaoRadius = <f32>io.f;
        else io.f = <f64>e.ssaoRadius;
        return F_NUMBER;
    }
    if (n == "ssao_intensity") {
        if (w) e.ssaoIntensity = <f32>io.f;
        else io.f = <f64>e.ssaoIntensity;
        return F_NUMBER;
    }
    if (n == "ssao_power") {
        if (w) e.ssaoPower = <f32>io.f;
        else io.f = <f64>e.ssaoPower;
        return F_NUMBER;
    }
    if (n == "ssao_detail") {
        if (w) e.ssaoDetail = <f32>io.f;
        else io.f = <f64>e.ssaoDetail;
        return F_NUMBER;
    }
    if (n == "ssao_horizon") {
        if (w) e.ssaoHorizon = <f32>io.f;
        else io.f = <f64>e.ssaoHorizon;
        return F_NUMBER;
    }
    if (n == "ssao_sharpness") {
        if (w) e.ssaoSharpness = <f32>io.f;
        else io.f = <f64>e.ssaoSharpness;
        return F_NUMBER;
    }
    if (n == "ssao_light_affect") {
        if (w) e.ssaoLightAffect = <f32>io.f;
        else io.f = <f64>e.ssaoLightAffect;
        return F_NUMBER;
    }
    if (n == "ssao_ao_channel_affect") {
        if (w) e.ssaoAoChannelAffect = <f32>io.f;
        else io.f = <f64>e.ssaoAoChannelAffect;
        return F_NUMBER;
    }
    if (n == "glow_enabled") {
        if (w) e.glowEnabled = io.b;
        else io.b = e.glowEnabled;
        return F_BOOL;
    }
    if (n == "glow_normalized") {
        if (w) e.glowNormalized = io.b;
        else io.b = e.glowNormalized;
        return F_BOOL;
    }
    if (n == "glow_intensity") {
        if (w) e.glowIntensity = <f32>io.f;
        else io.f = <f64>e.glowIntensity;
        return F_NUMBER;
    }
    if (n == "glow_strength") {
        if (w) e.glowStrength = <f32>io.f;
        else io.f = <f64>e.glowStrength;
        return F_NUMBER;
    }
    if (n == "glow_mix") {
        if (w) e.glowMix = <f32>io.f;
        else io.f = <f64>e.glowMix;
        return F_NUMBER;
    }
    if (n == "glow_bloom") {
        if (w) e.glowBloom = <f32>io.f;
        else io.f = <f64>e.glowBloom;
        return F_NUMBER;
    }
    if (n == "glow_blend_mode") {
        if (w) e.glowBlendMode = io.i;
        else io.i = e.glowBlendMode;
        return F_INT;
    }
    if (n == "glow_hdr_threshold") {
        if (w) e.glowHdrThreshold = <f32>io.f;
        else io.f = <f64>e.glowHdrThreshold;
        return F_NUMBER;
    }
    if (n == "glow_hdr_scale") {
        if (w) e.glowHdrScale = <f32>io.f;
        else io.f = <f64>e.glowHdrScale;
        return F_NUMBER;
    }
    if (n == "glow_hdr_luminance_cap") {
        if (w) e.glowHdrLuminanceCap = <f32>io.f;
        else io.f = <f64>e.glowHdrLuminanceCap;
        return F_NUMBER;
    }
    if (n == "fog_enabled") {
        if (w) e.fogEnabled = io.b;
        else io.b = e.fogEnabled;
        return F_BOOL;
    }
    if (n == "fog_mode") {
        if (w) e.fogMode = io.i;
        else io.i = e.fogMode;
        return F_INT;
    }
    if (n == "fog_light_color") {
        if (w) e.fogLightColor = io.c;
        else io.c = e.fogLightColor;
        return F_COLOR;
    }
    if (n == "fog_light_energy") {
        if (w) e.fogLightEnergy = <f32>io.f;
        else io.f = <f64>e.fogLightEnergy;
        return F_NUMBER;
    }
    if (n == "fog_sun_scatter") {
        if (w) e.fogSunScatter = <f32>io.f;
        else io.f = <f64>e.fogSunScatter;
        return F_NUMBER;
    }
    if (n == "fog_density") {
        if (w) e.fogDensity = <f32>io.f;
        else io.f = <f64>e.fogDensity;
        return F_NUMBER;
    }
    if (n == "fog_aerial_perspective") {
        if (w) e.fogAerialPerspective = <f32>io.f;
        else io.f = <f64>e.fogAerialPerspective;
        return F_NUMBER;
    }
    if (n == "fog_sky_affect") {
        if (w) e.fogSkyAffect = <f32>io.f;
        else io.f = <f64>e.fogSkyAffect;
        return F_NUMBER;
    }
    if (n == "fog_height") {
        if (w) e.fogHeight = <f32>io.f;
        else io.f = <f64>e.fogHeight;
        return F_NUMBER;
    }
    if (n == "fog_height_density") {
        if (w) e.fogHeightDensity = <f32>io.f;
        else io.f = <f64>e.fogHeightDensity;
        return F_NUMBER;
    }
    if (n == "fog_depth_curve") {
        if (w) e.fogDepthCurve = <f32>io.f;
        else io.f = <f64>e.fogDepthCurve;
        return F_NUMBER;
    }
    if (n == "fog_depth_begin") {
        if (w) e.fogDepthBegin = <f32>io.f;
        else io.f = <f64>e.fogDepthBegin;
        return F_NUMBER;
    }
    if (n == "fog_depth_end") {
        if (w) e.fogDepthEnd = <f32>io.f;
        else io.f = <f64>e.fogDepthEnd;
        return F_NUMBER;
    }
    // Milestone 37: the volumetric fog.
    if (n == "volumetric_fog_enabled") {
        if (w) e.volumetricFogEnabled = io.b;
        else io.b = e.volumetricFogEnabled;
        return F_BOOL;
    }
    if (n == "volumetric_fog_density") {
        if (w) e.volumetricFogDensity = <f32>io.f;
        else io.f = <f64>e.volumetricFogDensity;
        return F_NUMBER;
    }
    if (n == "volumetric_fog_albedo") {
        if (w) e.volumetricFogAlbedo = io.c;
        else io.c = e.volumetricFogAlbedo;
        return F_COLOR;
    }
    if (n == "volumetric_fog_emission") {
        if (w) e.volumetricFogEmission = io.c;
        else io.c = e.volumetricFogEmission;
        return F_COLOR;
    }
    if (n == "volumetric_fog_emission_energy") {
        if (w) e.volumetricFogEmissionEnergy = <f32>io.f;
        else io.f = <f64>e.volumetricFogEmissionEnergy;
        return F_NUMBER;
    }
    if (n == "volumetric_fog_anisotropy") {
        if (w) e.volumetricFogAnisotropy = <f32>io.f;
        else io.f = <f64>e.volumetricFogAnisotropy;
        return F_NUMBER;
    }
    if (n == "volumetric_fog_length") {
        if (w) e.volumetricFogLength = <f32>io.f;
        else io.f = <f64>e.volumetricFogLength;
        return F_NUMBER;
    }
    if (n == "volumetric_fog_ambient_inject") {
        if (w) e.volumetricFogAmbientInject = <f32>io.f;
        else io.f = <f64>e.volumetricFogAmbientInject;
        return F_NUMBER;
    }
    if (n == "volumetric_fog_sky_affect") {
        if (w) e.volumetricFogSkyAffect = <f32>io.f;
        else io.f = <f64>e.volumetricFogSkyAffect;
        return F_NUMBER;
    }
    if (n == "adjustment_enabled") {
        if (w) e.adjustmentEnabled = io.b;
        else io.b = e.adjustmentEnabled;
        return F_BOOL;
    }
    if (n == "adjustment_brightness") {
        if (w) e.adjustmentBrightness = <f32>io.f;
        else io.f = <f64>e.adjustmentBrightness;
        return F_NUMBER;
    }
    if (n == "adjustment_contrast") {
        if (w) e.adjustmentContrast = <f32>io.f;
        else io.f = <f64>e.adjustmentContrast;
        return F_NUMBER;
    }
    if (n == "adjustment_saturation") {
        if (w) e.adjustmentSaturation = <f32>io.f;
        else io.f = <f64>e.adjustmentSaturation;
        return F_NUMBER;
    }
    if (n.length == 13 && n.startsWith("glow_levels/")) {
        const k = n.charCodeAt(12) - 48;
        if (k < 1 || k > e.glowLevels.length) return F_NONE;
        if (w) e.glowLevels[k - 1] = <f32>io.f;
        else io.f = <f64>e.glowLevels[k - 1];
        return F_NUMBER;
    }
    return F_NONE;
}

// The primitive meshes' fields (../resource/primitives.as
// setPrimitiveField's names).
export function primitiveField(made: PrimitiveMesh, n: string, io: FieldIO, w: bool): i32 {
    const isBox = made instanceof BoxMesh;
    const isSphere = made instanceof SphereMesh;
    const isCylinder = made instanceof CylinderMesh;
    const isPlane = made instanceof PlaneMesh;
    if (isBox) {
        const b = made as BoxMesh;
        if (n == "size") {
            if (w) b.size = io.v3;
            else io.v3 = b.size;
            return F_VEC3;
        }
        if (n == "subdivide_width") {
            if (w) b.subdivideWidth = io.i;
            else io.i = b.subdivideWidth;
            return F_INT;
        }
        if (n == "subdivide_height") {
            if (w) b.subdivideHeight = io.i;
            else io.i = b.subdivideHeight;
            return F_INT;
        }
        if (n == "subdivide_depth") {
            if (w) b.subdivideDepth = io.i;
            else io.i = b.subdivideDepth;
            return F_INT;
        }
    } else if (isSphere) {
        const s = made as SphereMesh;
        if (n == "radius") {
            if (w) s.radius = <f32>io.f;
            else io.f = <f64>s.radius;
            return F_NUMBER;
        }
        if (n == "height") {
            if (w) s.height = <f32>io.f;
            else io.f = <f64>s.height;
            return F_NUMBER;
        }
        if (n == "radial_segments") {
            if (w) s.radialSegments = io.i;
            else io.i = s.radialSegments;
            return F_INT;
        }
        if (n == "rings") {
            if (w) s.rings = io.i;
            else io.i = s.rings;
            return F_INT;
        }
        if (n == "is_hemisphere") {
            if (w) s.isHemisphere = io.b;
            else io.b = s.isHemisphere;
            return F_BOOL;
        }
    } else if (isCylinder) {
        const c = made as CylinderMesh;
        if (n == "top_radius") {
            if (w) c.topRadius = <f32>io.f;
            else io.f = <f64>c.topRadius;
            return F_NUMBER;
        }
        if (n == "bottom_radius") {
            if (w) c.bottomRadius = <f32>io.f;
            else io.f = <f64>c.bottomRadius;
            return F_NUMBER;
        }
        if (n == "height") {
            if (w) c.height = <f32>io.f;
            else io.f = <f64>c.height;
            return F_NUMBER;
        }
        if (n == "radial_segments") {
            if (w) c.radialSegments = io.i;
            else io.i = c.radialSegments;
            return F_INT;
        }
        if (n == "rings") {
            if (w) c.rings = io.i;
            else io.i = c.rings;
            return F_INT;
        }
        if (n == "cap_top") {
            if (w) c.capTop = io.b;
            else io.b = c.capTop;
            return F_BOOL;
        }
        if (n == "cap_bottom") {
            if (w) c.capBottom = io.b;
            else io.b = c.capBottom;
            return F_BOOL;
        }
    } else if (isPlane) {
        const p = made as PlaneMesh;
        if (n == "size") {
            if (w) p.size = io.v2;
            else io.v2 = p.size;
            return F_VEC2;
        }
        if (n == "subdivide_width") {
            if (w) p.subdivideWidth = io.i;
            else io.i = p.subdivideWidth;
            return F_INT;
        }
        if (n == "subdivide_depth") {
            if (w) p.subdivideDepth = io.i;
            else io.i = p.subdivideDepth;
            return F_INT;
        }
        if (n == "center_offset") {
            if (w) p.centerOffset = io.v3;
            else io.v3 = p.centerOffset;
            return F_VEC3;
        }
        if (n == "orientation") {
            if (w) p.orientation = io.i;
            else io.i = p.orientation;
            return F_INT;
        }
    }
    return F_NONE;
}
