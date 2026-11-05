// What a model file says about skeletons, skins, blend shapes and
// animation clips, in the engine's terms (docs/plans/RIVE_MODEL.md section
// 3.7; docs/engine/ANIMATION.md, "Skeletons and imported clips"): the
// readers (engine/src/source/scene/resource/model.as, for glTF
// and .rmdl) fill it, a built scene's Model payload carries it
// (../bundle/payload.as), and the scene tree turns it into Skeleton3D
// bones, MeshInstance3D skins and blend shapes (../tree/model_nodes.as) and
// into read-only LinearAnimations (./clips.as). Plain data, no behaviour
// but lookups.
//
// Spaces. A bone's pose is local: relative to its parent bone, or to the
// skeleton node for a root bone, in scene space (Y up, metres), composed
// as T(position) * R(rotation) * S(scale), as Godot 4's Skeleton3D holds
// it. A skin's inverse bind matrix k maps a point of the mesh as its
// GpuMesh stores it (a model's meshes are in model space, Z up:
// ../render/meshes.as) into the space of bone joints[k] at bind time, so
// the point drawn is skeletonGlobal * boneGlobal(joints[k]) *
// inverseBinds[k] * p, weighted over the vertex's four joints
// (GpuMesh.skinJoints, skinWeights in ../../render/mesh.as).

import { Mat4, Quat, Vec3, QUAT_IDENTITY } from "../../base/vecmath";
import { KeyedPropertyDecl } from "../anim/decl";

// The most bones one skin's palette holds: a vertex names its joints by
// palette slot in one byte, and the palette's uniform (48 bytes a joint,
// ../../render/gpu/layouts.as) fits the smallest uniform buffer a device
// may offer (16,384 bytes). A mesh whose skin needs more is drawn
// unskinned, with the warning SKIN_JOINTS_LIMIT.
export const MAX_SKIN_JOINTS: i32 = 255;

// The frame rate an imported clip keeps when no common rate fits its key
// times (RIVE_MODEL.md section 3.7: exact times, `fps` 1000, `quantize`
// false), and the rates tried first, in order: the first on whose grid
// every key time lies within CLIP_GRID_TOLERANCE seconds is the clip's.
export const CLIP_EXACT_FPS: i32 = 1000;
export const CLIP_GRID_RATES: StaticArray<i32> = [24, 25, 30, 48, 50, 60, 120, 240];
export const CLIP_GRID_TOLERANCE: f64 = 0.0001;

// The words a model's load warnings about these start with
// (ModelResource.warnings, which a scene's load reports as model-warning:
// "skin-joints-limit: mesh 'Body' uses 300 bones, more than 255: it is
// drawn unskinned").
export const SKIN_JOINTS_LIMIT = "skin-joints-limit";
export const CLIP_CHANNEL_UNSUPPORTED = "clip-channel-unsupported";
export const CLIP_BAKED = "clip-baked";
// A modifier before the armature's drops the vertex groups (the mesh is
// drawn unskinned, as the file poses it); an armature modifier that
// preserves volume (drawn with linear blend skinning); modifiers after the
// armature's (applied to the mesh at bind time, before skinning).
export const SKIN_WEIGHTS_LOST = "skin-weights-lost";
export const SKIN_PRESERVE_VOLUME = "skin-preserve-volume";
export const SKIN_MODIFIER_ORDER = "skin-modifier-order";

// The influences a vertex keeps (GpuMesh.skinJoints holds four slots).
export const SKIN_INFLUENCES: i32 = 4;

// The rate an exact clip's baked channels are sampled at (a rotation
// glTF interpolates as a cubic spline, which no slerp reproduces: one key a
// frame of this rate), and the largest difference, in the property's own
// units, an interpolator may make from the curve it stands for before the
// curve is baked instead (sampled on the clip's frames, linear between).
export const CLIP_BAKE_EXACT_FPS: i32 = 60;
export const CLIP_FIT_TOLERANCE: f64 = 0.0001;

// A bone's local transform.
export class BonePose {
    position: Vec3 = Vec3(0, 0, 0);
    rotation: Quat = QUAT_IDENTITY;
    scale: Vec3 = Vec3(1, 1, 1);

    constructor(position: Vec3 = Vec3(0, 0, 0), rotation: Quat = QUAT_IDENTITY, scale: Vec3 = Vec3(1, 1, 1)) {
        this.position = position;
        this.rotation = rotation;
        this.scale = scale;
    }

    clone(): BonePose {
        return new BonePose(this.position, this.rotation, this.scale);
    }

    // T(position) * R(rotation) * S(scale).
    matrix(): Mat4 {
        return Mat4.fromScaleRotationTranslation(this.scale, this.rotation, this.position);
    }
}

export class ModelBone {
    // Unique within its skeleton; may hold any character (glTF's
    // "mixamorig:Hips" included): ./names.as reads a bone property's field
    // from the right.
    name: string = "";
    // Index of the parent bone in ModelSkeleton.bones (parents first), -1
    // for a root bone.
    parent: i32 = -1;
    // The rest pose (Blender's rest, glTF's joint node as the file sets it)
    // and the pose the file holds (Blender's pose, the same as the rest for
    // glTF): Skeleton3D starts at `pose`; "Reset Pose" goes back to `rest`.
    rest: BonePose = new BonePose();
    pose: BonePose = new BonePose();
}

// The bones of an armature object (ModelObject.skeleton): the object
// becomes a Skeleton3D.
export class ModelSkeleton {
    bones: Array<ModelBone> = [];

    // The index of the bone named `name`, -1 for none.
    boneIndex(name: string): i32 {
        for (let i = 0; i < this.bones.length; i++) if (this.bones[i].name == name) return i;
        return -1;
    }
}

// How a mesh object follows a skeleton (ModelObject.skin): its GpuMesh's
// skinJoints name palette slots k, each bone joints[k] of the skeleton of
// object `skeleton`, with inverseBinds[k] (see the header).
export class ModelSkin {
    // Index in ModelResource.objects of the armature object (its
    // ModelObject.skeleton is set).
    skeleton: i32 = -1;
    joints: Array<i32> = [];
    inverseBinds: Array<Mat4> = [];
}

// One keyed property of an imported clip: a property of object `object`
// (an index in ModelResource.objects), named as a scene keys it
// ("bones/Hips:quaternion", "bones/Hips:position:y", "position:x",
// "blend_shapes/Smile": ./names.as), with its keys in Rive's form at the
// clip's fps.
export class ModelClipTrack {
    object: i32;
    keys: KeyedPropertyDecl;

    constructor(object: i32, keys: KeyedPropertyDecl) {
        this.object = object;
        this.keys = keys;
    }
}

// An animation of a model (a glTF animation, an .rmdl's action): a
// LinearAnimation once it is placed in a scene (./clips.as). Keys sit on
// whole frames of `fps`; `exact` says the times fitted no common rate and
// are kept to the millisecond (fps CLIP_EXACT_FPS, quantize false), which
// the tools show in frames at the scene's display rate.
export class ModelClip {
    name: string = "";
    fps: i32 = 30;
    // The last frame (Rive's duration, in frames of `fps`).
    duration: i32 = 0;
    exact: bool = false;
    // Loop by default, as a model's clip usually is played (a oneShot is
    // chosen in the scene by Make Editable).
    loop: bool = true;
    tracks: Array<ModelClipTrack> = [];
}

// The grid a clip's key times fit (CLIP_GRID_RATES, within
// CLIP_GRID_TOLERANCE), or CLIP_EXACT_FPS when none does. `times` in
// seconds.
export function clipGridFps(times: Array<f64>): i32 {
    for (let r = 0; r < CLIP_GRID_RATES.length; r++) {
        const fps = <f64>CLIP_GRID_RATES[r];
        let fits = true;
        for (let i = 0; i < times.length && fits; i++) {
            const f = times[i] * fps;
            if (Math.abs(f - Math.round(f)) / fps > CLIP_GRID_TOLERANCE) fits = false;
        }
        if (fits) return CLIP_GRID_RATES[r];
    }
    return CLIP_EXACT_FPS;
}
