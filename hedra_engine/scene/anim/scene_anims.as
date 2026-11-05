// A scene's timelines on its instanced nodes (milestone 45,
// docs/plans/RIVE_MODEL.md sections 3.2 and 5): each scene file instanced
// in a tree (the root scene, and every .rscn instanced in it) gets one
// SceneAnimations on its root node (SceneNode.animations), made by the
// instancer (../tree/instance.as, attachSceneAnimations) from the file's
// <LinearAnimation>s and <Event>s. A scene instanced twice has two, over
// its two subtrees, sharing the prepared animations. (An inherited scene,
// whose root is another scene's instance, has its own file's when it
// declares any, else keeps the instanced scene's.)
//
// apply() writes an animation instance's keys at its time onto the nodes,
// as Rive's KeyedObject/KeyedProperty::apply does (the key at or after
// the time found as closestFrameIndex finds it; before the first key the
// first holds, after the last the last; the leaving key's interpolation
// decides), through the bindings' generic setter (../binding/apply.as
// writeTarget, Rive's CoreRegistry::setDouble): a vector's component
// through the node's BindingPose (so Euler angles past 90 degrees
// survive), a material's field in place, a node property as an effective
// property. Each keyframe kind mixes as its Rive class does
// (keyframe_double.cpp and the others): a number by current * (1 - mix) +
// key * mix in f32, a colour channel by channel (colorLerp), a quaternion
// by slerp along the shortest arc; bools, strings, enums (Rive's Uint of
// a property that does not interpolate) and ints (Rive's KeyFrameInt
// holds) are written as the key says whatever the mix. A keyed property
// also bound one_way (the node's <binding> of that property, once or not)
// is not written: the bind wins, as in Rive, where binds apply after
// animation; a two_way or to_source one is written, and pushed back by the
// bindings.
//
// The keys' targets are resolved once per SceneAnimations, lazily, the
// first time an animation is applied (or asked about: targetNode,
// overridden): the node by path from the scene's root (through instances:
// "Hero/Arm"), the property by ../binding/targets.as findBindingTarget (an
// animatable one) or a family of ./decl.as. What does not resolve is
// warned once (KEYED_NODE_MISSING, KEYED_PROPERTY_UNKNOWN,
// KEYED_PROPERTY_MISMATCH) into the diagnostics the instancer had (the
// tree's loader's, which a tool prints), and onto `warnings`; its keys are
// kept and written back, and nothing is written there. A frame allocates
// nothing for a vector component, a quaternion, a colour or a material
// field once its node has a BindingPose (a node property's write makes its
// new Value, as a binding's does; an unchanged value is not written).
//
// A quaternion track's rotation is held per node (QuatState) and written
// to the node's matrix once its frame's animations are applied
// (flushQuaternions: apply and applyAnimationAtFrame call it; the run time
// calls it after its phase, having layered its animations with
// applyDeferred), so that three animations layered on a node make one
// matrix and one set of Euler angles rather than three.
//
// The tools (render, inspect, the editor) sample an animation at a frame
// with applyAnimationAtFrame; the run time (../runtime/
// feature_animation.as) advances instances and applies them.
//
// Milestone 48 (docs/plans/RIVE_MODEL.md section 3.7; RSCN.md,
// "Skeletons"): two more families. A Skeleton3D's `bones/<bone>:...`
// (FAMILY_BONE): a KeyFrameDouble on a component mixes into that component
// of the bone's pose as a number does; a KeyFrameQuaternion on
// `bones/<bone>:quaternion` slerps from the bone's rotation along the
// shortest arc, layered per bone as a node's quaternion is (BoneQuatState,
// one pending rotation a bone a frame); both are written with the
// skeleton's setBonePose* (its poseVersion moves only on a change), and
// the skeleton's BoneAttachment3Ds follow once the frame's keys are
// written (flushQuaternions). A MeshInstance3D's `blend_shapes/<name>`
// (FAMILY_BLEND_SHAPE): a KeyFrameDouble mixes into the weight
// (setBlendShapeValue); a one_way binding of it overrides it, as every
// property's. A model the scene instances adds its clips after the
// scene's own animations (attachSceneAnimations, ../skeleton/clips.as).
//
// Milestone 61: a ShaderMaterial's parameters (`material_override:
// shader_parameter/<name>`, a component by :x to :w, through mesh:material:
// and next passes too): the track's kind is resolved against the node's
// material when the targets are (../binding/shader_targets.as: a number or
// a component KeyFrameDouble, a source_color uniform KeyFrameColor, a bool
// KeyFrameBool); a material without the uniform is keyed-property-unknown
// with the reason, a key of another kind keyed-property-mismatch. The
// write goes into the material's params in place (no allocation a frame).

import { Result } from "../../base/util";
import { MAT4_NAN, Mat3, Mat4, Quat, Vec3 } from "../../base/vecmath";
import { Diagnostic, Diagnostics, SceneryError, Severity } from "../error";
import { RscnDoc } from "../rscn/doc";
import { VmKind } from "../riv/riv_info";
import {
    EVENT_PROPERTY_PREFIX, EventDecl, InterpolationType, KeyFrameKind, KeyedObjectDecl, KeyedPropertyDecl, LinearAnimationDecl,
    QUATERNION_PROPERTY, SIGNAL_PROPERTY_PREFIX,
} from "./decl";
import { KeyedTrack, LinearAnimation, prepareAnimation } from "./animation";
import { LinearAnimationInstance } from "./instance";
import { BindKind, BindingTarget, findBindingTarget, signalTargetName } from "../binding/targets";
import { BindingPose, readTarget, writeTarget } from "../binding/apply";
import { resolveShaderTarget, resolvedTarget } from "../binding/shader_targets";
import { BoundValue } from "../binding/values";
import { BindingMode } from "../binding/binding";
import { eulerYXZFromBasis, scaled, withBasis } from "../tree/xform";
import { MeshInstance3D, SceneNode, Skeleton3D } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { ModelResource } from "../resource/types";
import {
    BLEND_SHAPES_PREFIX, BLEND_SHAPE_UNKNOWN_CODE, BONES_PREFIX, BONE_FIELD_POSITION, BONE_FIELD_QUATERNION, BONE_UNKNOWN_CODE,
    blendShapeOf, parseBoneProperty,
} from "../skeleton/names";
import { ImportedClipSet } from "../skeleton/clips";

// The load warnings of a key whose target does not resolve on an instance
// (the keys are kept and written back; nothing is written there):
// keyed-node-missing (no node at that path from the scene's root),
// keyed-property-unknown (the node's class has no such animatable
// property, or the family names nothing: an event the scene does not
// declare, `event:` off the root), keyed-property-mismatch (the keyframe's
// kind is not the property's).
export const KEYED_NODE_MISSING = "keyed-node-missing";
export const KEYED_PROPERTY_UNKNOWN = "keyed-property-unknown";
export const KEYED_PROPERTY_MISMATCH = "keyed-property-mismatch";

// The error of a name no animation of the scene has.
export const ANIMATION_UNKNOWN = "animation-unknown";

// The transform components (TrackTarget.vector), as ../binding/apply.as
// vectorOf numbers them.
const TRANSFORM_POSITION: i32 = 0;
const TRANSFORM_ROTATION: i32 = 1;
const TRANSFORM_ROTATION_DEGREES: i32 = 2;
const TRANSFORM_SCALE: i32 = 3;

const DEG: f64 = Math.PI / 180;

// The transform component `p` names (-1 none).
function vectorOf(p: string): i32 {
    if (p == "position:x" || p == "position:y" || p == "position:z") return TRANSFORM_POSITION;
    if (p == "rotation:x" || p == "rotation:y" || p == "rotation:z") return TRANSFORM_ROTATION;
    if (p == "rotation_degrees:x" || p == "rotation_degrees:y" || p == "rotation_degrees:z") return TRANSFORM_ROTATION_DEGREES;
    if (p == "scale:x" || p == "scale:y" || p == "scale:z") return TRANSFORM_SCALE;
    return -1;
}

// What a keyed property writes (TrackTarget.family).
const FAMILY_NONE: i32 = 0;
const FAMILY_PROPERTY: i32 = 1;
const FAMILY_QUATERNION: i32 = 2;
const FAMILY_EVENT: i32 = 3;
const FAMILY_SIGNAL: i32 = 4;
// Milestone 48.
const FAMILY_BONE: i32 = 5;
const FAMILY_BLEND_SHAPE: i32 = 6;

// The pose field a bone track writes (TrackTarget.field).
const BONE_POSITION: i32 = 0;
const BONE_ROTATION: i32 = 1;
const BONE_SCALE: i32 = 2;

// One keyed property resolved on this scene's nodes.
export class TrackTarget {
    family: i32 = FAMILY_NONE;
    // FAMILY_PROPERTY: the binding target, and whether its write goes
    // through the node's BindingPose (a rotation or scale component).
    target: BindingTarget? = null;
    usesPose: bool = false;
    // A transform component (TRANSFORM_*, -1 none) and its axis (0 x, 1 y,
    // 2 z): read and written here as ../binding/apply.as does, without
    // telling the property apart by its name each frame.
    vector: i32 = -1;
    axis: i32 = 0;
    // Overridden by a one_way binding of the same property: not written.
    overridden: bool = false;
    // FAMILY_SIGNAL: the signal; FAMILY_EVENT: the event (null: undeclared,
    // which the resolution warned about).
    signal: string = "";
    event: EventDecl? = null;
    // The value read and the value written (kept: a frame makes none).
    read: BoundValue = new BoundValue();
    write: BoundValue = new BoundValue();
    // FAMILY_QUATERNION: its node's rotation state (one per node of the
    // scene, shared by the node's quaternion tracks of every animation).
    quat: QuatState? = null;
    // FAMILY_BONE: the skeleton, the bone's index, the pose field
    // (BONE_*), and for the rotation the bone's state (one per bone, shared
    // as `quat` is); the component is `axis`. FAMILY_BLEND_SHAPE: the mesh
    // and the blend shape's index.
    skeleton: Skeleton3D? = null;
    mesh: MeshInstance3D? = null;
    index: i32 = -1;
    field: i32 = BONE_POSITION;
    bone: BoneQuatState? = null;
}

// A bone's pose as its tracks leave it in a frame: as QuatState for a
// node, the rotation tracks of several animations slerp onto the pending
// rotation, and the components of its position and scale mix into pending
// vectors; the bone's pose is written once, by flushQuaternions, so that a
// frame that ends where the last did moves nothing (poseVersion included).
export class BoneQuatState {
    skeleton: Skeleton3D;
    index: i32;
    q: Quat = Quat(0, 0, 0, 1);
    pending: bool = false;
    position: Vec3 = Vec3(0, 0, 0);
    positionPending: bool = false;
    scale: Vec3 = Vec3(1, 1, 1);
    scalePending: bool = false;
    // In pendingBones this frame.
    queued: bool = false;

    constructor(skeleton: Skeleton3D, index: i32) {
        this.skeleton = skeleton;
        this.index = index;
    }

    // The rotation there now: the pending one, else the bone's.
    current(): Quat {
        return this.pending ? this.q : this.skeleton.getBonePoseRotation(this.index);
    }

    // The position (scale) there now.
    currentPosition(): Vec3 {
        return this.positionPending ? this.position : this.skeleton.getBonePosePosition(this.index);
    }

    currentScale(): Vec3 {
        return this.scalePending ? this.scale : this.skeleton.getBonePoseScale(this.index);
    }

    queue(): void {
        if (this.queued) return;
        this.queued = true;
        pendingBones.push(this);
    }

    flush(): void {
        this.queued = false;
        const sk = this.skeleton;
        const v = sk.poseVersion;
        if (this.pending) sk.setBonePoseRotation(this.index, this.q, false);
        if (this.positionPending) sk.setBonePosePosition(this.index, this.position, false);
        if (this.scalePending) sk.setBonePoseScale(this.index, this.scale, false);
        this.pending = false;
        this.positionPending = false;
        this.scalePending = false;
        if (sk.poseVersion != v) markSkeleton(sk);
    }
}

// A node's rotation as its quaternion tracks leave it. The tracks of
// several animations layered in one frame each slerp onto the last one's
// quaternion, held here (`pending`), and the node's matrix is written once,
// when the frame's animations are done (flushQuaternions): the values of
// writing it after each, one matrix, one set of Euler angles for the
// node's pose. `q` and `local` are what the last write left, so that an
// unchanged rotation is not written again and a mix reads it back without
// taking the matrix apart.
export class QuatState {
    node: SceneNode;
    pose: BindingPose? = null;
    q: Quat = Quat(0, 0, 0, 1);
    local: Mat4 = MAT4_NAN;
    written: bool = false;
    pending: bool = false;

    constructor(node: SceneNode) {
        this.node = node;
    }

    // The node's pose (kept while it is the node's), synced with its matrix.
    syncedPose(): BindingPose {
        const node = this.node;
        let pose = this.pose;
        if (pose == null || node.bindingPose !== pose) {
            pose = BindingPose.of(node);
            this.pose = pose;
        }
        pose.sync(node);
        return pose;
    }

    // The rotation there now: the pending one, the last one written while
    // the node's basis is still the one it left, else the basis with the
    // pose's scale divided out.
    current(): Quat {
        if (this.pending) return this.q;
        const node = this.node;
        if (this.written && Mat3.fromMat4(node.local) == Mat3.fromMat4(this.local)) return this.q;
        const pose = this.syncedPose();
        return Quat.fromMat3(unscaled(Mat3.fromMat4(node.local), pose.scale));
    }

    // Writes the pending rotation as the node's basis, the pose's scale
    // kept; the pose keeps its Euler angles (for a component keyed after)
    // and the matrix it left, so that BindingPose.of still finds it.
    flush(): void {
        if (!this.pending) return;
        this.pending = false;
        const node = this.node;
        const pose = this.syncedPose();
        const basis = Mat3.fromQuat(this.q);
        node.local = withBasis(node.local, scaled(basis, pose.scale));
        pose.rotation = eulerYXZFromBasis(basis);
        pose.local = node.local;
        this.local = node.local;
        this.written = true;
    }
}

// The rotations slerped and not yet written (see QuatState), the bones'
// (BoneQuatState), and the skeletons whose bones the frame changed, whose
// attachments follow once the frame's keys are all written.
const pendingQuats = new Array<QuatState>();
const pendingBones = new Array<BoneQuatState>();
const pendingSkeletons = new Array<Skeleton3D>();

// Writes every pending rotation (the animations of a frame are applied),
// then brings the BoneAttachment3Ds of the skeletons posed along:
// SceneAnimations.apply and applyAnimationAtFrame call it, and the run time
// after its animation phase.
export function flushQuaternions(): void {
    for (let i = 0; i < pendingQuats.length; i++) unchecked(pendingQuats[i]).flush();
    pendingQuats.length = 0;
    for (let i = 0; i < pendingBones.length; i++) unchecked(pendingBones[i]).flush();
    pendingBones.length = 0;
    for (let i = 0; i < pendingSkeletons.length; i++) {
        const sk = unchecked(pendingSkeletons[i]);
        sk.animPending = false;
        sk.syncAttachments();
    }
    pendingSkeletons.length = 0;
}

// `sk`'s bones changed this frame (its attachments follow at the flush).
function markSkeleton(sk: Skeleton3D): void {
    if (sk.animPending) return;
    sk.animPending = true;
    pendingSkeletons.push(sk);
}

// One animation's targets: per keyed object its node, per track its
// target.
class AnimTargets {
    nodes: Array<SceneNode?> = [];
    tracks: Array<Array<TrackTarget>> = [];
}

export class SceneAnimations {
    // The scene's root in the tree, and its file as errors name it.
    root: SceneNode;
    file: string;
    // As declared, and prepared (the same order).
    decls: Array<LinearAnimationDecl> = [];
    animations: Array<LinearAnimation> = [];
    events: Array<EventDecl> = [];
    // Milestone 48: per entry of `decls`, "" for the scene's own animation,
    // or the source of an imported clip (a model this scene instances:
    // "hero.glb", ../skeleton/clips.as), whose declaration is made at load
    // and never written to the file. The imported ones come after the
    // scene's own.
    importedSources: Array<string> = [];
    // The load warnings of this scene's keys (each once), also given to the
    // instancer's diagnostics (`diag`) when it had some.
    warnings: Diagnostics = new Diagnostics();
    diag: Diagnostics? = null;
    // How many keyed properties the last apply wrote, and how many it left
    // to a binding (applyAnimationAtFrame's sample).
    lastWritten: i32 = 0;
    lastOverridden: i32 = 0;
    // Per animation, its targets once resolved; per node keyed by
    // quaternion, its rotation state.
    private resolved: Array<AnimTargets?> = [];
    // (by the node's serial, never the node: see SceneNode.serial)
    private quatStates: Map<i32, QuatState> = new Map<i32, QuatState>();
    // Per skeleton keyed by bone rotations, each bone's state (made the
    // first time).
    private boneStates: Map<i32, Array<BoneQuatState?>> = new Map<i32, Array<BoneQuatState?>>();

    constructor(root: SceneNode, file: string) {
        this.root = root;
        this.file = file;
    }

    // The index of animation `name`, or -1.
    index(name: string): i32 {
        for (let i = 0; i < this.animations.length; i++) if (this.animations[i].name == name) return i;
        return -1;
    }

    animation(name: string): LinearAnimation? {
        const i = this.index(name);
        return i >= 0 ? this.animations[i] : null;
    }

    names(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.animations.length; i++) out.push(this.animations[i].name);
        return out;
    }

    // Milestone 48: whether animation `i` is an imported clip (read only).
    isImported(i: i32): bool {
        return i >= 0 && i < this.importedSources.length && this.importedSources[i].length > 0;
    }

    // How many of the animations are the scene's own (the first ones).
    ownCount(): i32 {
        let n = 0;
        while (n < this.decls.length && !this.isImported(n)) n++;
        return n;
    }

    event(name: string): EventDecl? {
        for (let i = 0; i < this.events.length; i++) if (this.events[i].name == name) return this.events[i];
        return null;
    }

    // The index of prepared animation `a` (an instance's), or -1.
    indexOf(a: LinearAnimation): i32 {
        for (let i = 0; i < this.animations.length; i++) if (this.animations[i] === a) return i;
        return -1;
    }

    // Writes `inst`'s keys at its time onto this scene's nodes in `tree`,
    // mixed by `mix`; returns whether a value changed (a new picture).
    apply(tree: SceneTree, inst: LinearAnimationInstance, mix: f32 = 1): bool {
        const changed = this.applyDeferred(tree, inst, mix);
        flushQuaternions();
        return changed;
    }

    // apply, its quaternions left pending for flushQuaternions (the run
    // time layers a frame's animations so, writing each node's rotation
    // once).
    applyDeferred(tree: SceneTree, inst: LinearAnimationInstance, mix: f32 = 1): bool {
        const ai = this.indexOf(inst.animation);
        if (ai < 0) return false;
        return this.applyAt(tree, ai, inst.animation.applyTime(inst.time), mix, inst.hints);
    }

    // Writes animation `ai`'s keys at `seconds` (quantized already), mixed
    // by `mix`; `hints`: the instance's last keys found (null: searched).
    applyAt(tree: SceneTree, ai: i32, seconds: f32, mix: f32, hints: StaticArray<i32>?): bool {
        const at = this.resolve(ai);
        const a = this.animations[ai];
        let changed = false;
        let written = 0;
        let overridden = 0;
        for (let o = 0; o < a.objects.length; o++) {
            const node = unchecked(at.nodes[o]);
            if (node == null) continue;
            const tracks = unchecked(a.objects[o]).tracks;
            const targets = unchecked(at.tracks[o]);
            // (a keyed object's position components are gathered and its
            // origin written once: the same values, one matrix made)
            let pos = Vec3(0, 0, 0);
            let posRead = false;
            let posMoved = false;
            for (let t = 0; t < tracks.length; t++) {
                const tt = unchecked(targets[t]);
                const fam = tt.family;
                if (fam != FAMILY_PROPERTY && fam != FAMILY_QUATERNION && fam != FAMILY_BONE && fam != FAMILY_BLEND_SHAPE) continue;
                if (tt.overridden) {
                    overridden++;
                    continue;
                }
                const track = unchecked(tracks[t]);
                if (track.length == 0) continue;
                let idx: i32;
                if (hints != null) {
                    idx = track.closestFrameIndexFrom(seconds, unchecked(hints[track.flat]));
                    unchecked(hints[track.flat] = idx);
                } else {
                    idx = track.closestFrameIndex(seconds, 0);
                }
                written++;
                if (tt.vector == TRANSFORM_POSITION && track.kind == KeyFrameKind.Double) {
                    if (!posRead) {
                        pos = node.local.wAxis.truncate();
                        posRead = true;
                    }
                    const cur = component(pos, tt.axis);
                    let v = doubleAt(track, idx, seconds);
                    if (mix != 1) v = cur * (<f32>1 - mix) + v * mix;
                    if (v != cur) {
                        pos = withComponent(pos, tt.axis, v);
                        posMoved = true;
                    }
                } else if (fam == FAMILY_QUATERNION) {
                    if (applyQuaternion(track, tt.quat as QuatState, idx, seconds, mix)) changed = true;
                } else if (fam == FAMILY_BONE) {
                    if (applyBone(track, tt, idx, seconds, mix)) changed = true;
                } else if (fam == FAMILY_BLEND_SHAPE) {
                    if (applyBlendShape(track, tt, idx, seconds, mix)) changed = true;
                } else if (applyProperty(tree, node, track, tt, idx, seconds, mix)) {
                    changed = true;
                }
            }
            if (posMoved) {
                // (the basis is untouched: a pose there still holds it, and
                // takes the new origin when it next syncs)
                const m = node.local;
                node.local = Mat4(m.xAxis, m.yAxis, m.zAxis, pos.extend(1));
                changed = true;
            }
        }
        this.lastWritten = written;
        this.lastOverridden = overridden;
        return changed;
    }

    // The node keyed object `objectIndex` of animation `animationIndex`
    // names, resolved once (null: not found; warned once).
    targetNode(animationIndex: i32, objectIndex: i32): SceneNode? {
        if (animationIndex < 0 || animationIndex >= this.animations.length) return null;
        const at = this.resolve(animationIndex);
        return objectIndex >= 0 && objectIndex < at.nodes.length ? at.nodes[objectIndex] : null;
    }

    // Track `trackIndex` of keyed object `objectIndex` of animation
    // `animationIndex`, resolved (null: no such track).
    trackTarget(animationIndex: i32, objectIndex: i32, trackIndex: i32): TrackTarget? {
        if (animationIndex < 0 || animationIndex >= this.animations.length) return null;
        const at = this.resolve(animationIndex);
        if (objectIndex < 0 || objectIndex >= at.tracks.length) return null;
        const ts = at.tracks[objectIndex];
        return trackIndex >= 0 && trackIndex < ts.length ? ts[trackIndex] : null;
    }

    // Whether track `trackIndex` of keyed object `objectIndex` of animation
    // `animationIndex` is overridden by a one_way or once binding of its
    // node (not written: the bind wins).
    overridden(animationIndex: i32, objectIndex: i32, trackIndex: i32): bool {
        const t = this.trackTarget(animationIndex, objectIndex, trackIndex);
        return t != null && t.overridden;
    }

    // Milestone 46 (the state machines' animation reset, ../sm/instance.as,
    // Rive's AnimationReset): what track `trackIndex` of keyed object
    // `objectIndex` of animation `animationIndex` holds for a reset: 1 a
    // number (a Double key of a node property or a transform component), 2
    // a colour, 0 nothing a reset keeps (Rive's keeps doubles and colours
    // alone; an overridden track is not written, so neither is its reset).
    resetKind(animationIndex: i32, objectIndex: i32, trackIndex: i32): i32 {
        const tt = this.trackTarget(animationIndex, objectIndex, trackIndex);
        if (tt == null || tt.family != FAMILY_PROPERTY || tt.overridden) return 0;
        const track = this.animations[animationIndex].objects[objectIndex].tracks[trackIndex];
        if (track.kind == KeyFrameKind.Double) return 1;
        if (track.kind == KeyFrameKind.Color) return 2;
        return 0;
    }

    // The value that track's property has now on its node (resetKind not
    // 0), into `out`; false when it cannot be read.
    readTrack(animationIndex: i32, objectIndex: i32, trackIndex: i32, out: BoundValue): bool {
        const tt = this.trackTarget(animationIndex, objectIndex, trackIndex);
        const node = this.targetNode(animationIndex, objectIndex);
        if (tt == null || node == null || tt.target == null) return false;
        if (tt.usesPose && pendingQuats.length > 0) flushQuaternions();
        return readTarget(node, tt.target as BindingTarget, out, tt.usesPose ? BindingPose.of(node) : null);
    }

    // The value of that track's first key (Rive's baseline of a blend
    // state's reset), into `out`; false for a track without keys.
    firstKey(animationIndex: i32, objectIndex: i32, trackIndex: i32, out: BoundValue): bool {
        const track = this.animations[animationIndex].objects[objectIndex].tracks[trackIndex];
        if (track.length == 0) return false;
        if (track.kind == KeyFrameKind.Color) out.setColor(unchecked(track.colors[0]));
        else out.setNumber(<f64>unchecked(track.values[0]));
        return true;
    }

    // Writes `v` to that track's property (as a key does at mix 1);
    // whether the value there changed. Allocates nothing for a transform
    // component or a material's field once the node has its BindingPose.
    writeTrack(tree: SceneTree, animationIndex: i32, objectIndex: i32, trackIndex: i32, v: BoundValue): bool {
        const tt = this.trackTarget(animationIndex, objectIndex, trackIndex);
        const node = this.targetNode(animationIndex, objectIndex);
        if (tt == null || node == null || tt.target == null) return false;
        if (tt.usesPose && pendingQuats.length > 0) flushQuaternions();
        const target = tt.target as BindingTarget;
        const pose = tt.usesPose ? BindingPose.of(node) : null;
        const cur = tt.read;
        if (readTarget(node, target, cur, pose) && cur.kind == v.kind) {
            if (v.kind == VmKind.Color ? cur.color == v.color : <f32>cur.number == <f32>v.number) return false;
        }
        return writeTarget(tree, node, target, v, pose);
    }

    // Resolves every animation's targets (the warnings of what does not
    // resolve are then all given).
    resolveAll(): void {
        for (let i = 0; i < this.animations.length; i++) this.resolve(i);
    }

    // Animation `ai`'s targets, resolved the first time asked.
    private resolve(ai: i32): AnimTargets {
        while (this.resolved.length < this.animations.length) this.resolved.push(null);
        const had = unchecked(this.resolved[ai]);
        if (had != null) return had;
        const at = new AnimTargets();
        const a = this.animations[ai];
        const d = this.decls[ai];
        for (let o = 0; o < a.objects.length; o++) {
            const obj = a.objects[o];
            const od = o < d.objects.length ? d.objects[o] : null;
            const node = obj.target == "." ? this.root : this.root.getNode(obj.target);
            at.nodes.push(node);
            const ts = new Array<TrackTarget>();
            if (node == null) {
                this.warn(KEYED_NODE_MISSING, od, null, "animation \"" + a.name + "\" keys \"" + obj.target
                    + "\", which is no node of the scene", "the keys are kept, and nothing is written there");
            }
            for (let t = 0; t < obj.tracks.length; t++) {
                const pd = od != null && t < od.properties.length ? od.properties[t] : null;
                ts.push(node != null ? this.resolveTrack(a, obj.target, node, obj.tracks[t], pd) : new TrackTarget());
            }
            at.tracks.push(ts);
        }
        this.resolved[ai] = at;
        return at;
    }

    private resolveTrack(a: LinearAnimation, path: string, node: SceneNode, track: KeyedTrack, pd: KeyedPropertyDecl?): TrackTarget {
        const tt = new TrackTarget();
        const p = track.property;
        const kind = track.kind;
        const where = "animation \"" + a.name + "\" keys " + p + " of \"" + path + "\"";
        if (kind == KeyFrameKind.Id) return tt;
        if (p.startsWith(EVENT_PROPERTY_PREFIX)) {
            const name = p.substring(EVENT_PROPERTY_PREFIX.length);
            const ev = this.event(name);
            if (node !== this.root || ev == null) {
                this.warn(KEYED_PROPERTY_UNKNOWN, null, pd, where + (ev == null ? ": the scene declares no Event \"" + name + "\""
                    : ": an event is keyed on the scene's root (\".\") only"), null);
                return tt;
            }
            if (kind != KeyFrameKind.Callback) return this.mismatch(tt, pd, where, "KeyFrameCallback");
            tt.family = FAMILY_EVENT;
            tt.event = ev;
            return tt;
        }
        if (p.startsWith(SIGNAL_PROPERTY_PREFIX)) {
            const name = signalTargetName(p);
            if (name.length == 0) {
                this.warn(KEYED_PROPERTY_UNKNOWN, null, pd, where + ": not a signal's name", null);
                return tt;
            }
            if (kind != KeyFrameKind.Callback) return this.mismatch(tt, pd, where, "KeyFrameCallback");
            tt.family = FAMILY_SIGNAL;
            tt.signal = name;
            return tt;
        }
        if (p.startsWith(BONES_PREFIX)) return this.resolveBone(tt, node, kind, p, where, pd);
        if (p.startsWith(BLEND_SHAPES_PREFIX)) return this.resolveBlendShape(tt, node, kind, p, where, pd);
        if (p == QUATERNION_PROPERTY) {
            if (!node.is3d) {
                this.warn(KEYED_PROPERTY_UNKNOWN, null, pd, where + ": a " + node.className + " has no rotation", null);
                return tt;
            }
            if (kind != KeyFrameKind.Quaternion) return this.mismatch(tt, pd, where, "KeyFrameQuaternion");
            tt.family = FAMILY_QUATERNION;
            tt.usesPose = true;
            tt.quat = this.quatStateOf(node);
            tt.overridden = oneWayBound(node, p);
            return tt;
        }
        const found = findBindingTarget(node.schemaClass(), p);
        if (found == null || found.output || !found.animates || found.kind == BindKind.Trigger) {
            this.warn(KEYED_PROPERTY_UNKNOWN, null, pd, where + ": a " + node.schemaClass() + " has no animatable " + p, null);
            return tt;
        }
        let target: BindingTarget = found;
        if (target.deferred) {
            const info = resolveShaderTarget(node, p);
            if (!info.ok) {
                this.warn(KEYED_PROPERTY_UNKNOWN, null, pd, where + ": " + info.reason, info.hint);
                return tt;
            }
            target = resolvedTarget(target, info);
        }
        const want = keyFrameOf(target.kind);
        if (!takes(target.kind, kind)) return this.mismatch(tt, pd, where, want);
        tt.family = FAMILY_PROPERTY;
        tt.target = target;
        tt.usesPose = p.startsWith("rotation") || p.startsWith("scale");
        if (node.is3d) {
            tt.vector = vectorOf(p);
            tt.axis = p.charCodeAt(p.length - 1) - 0x78;
        }
        tt.overridden = oneWayBound(node, p);
        return tt;
    }

    // A `bones/<bone>:...` track on `node`: a Skeleton3D's bone property
    // (keyed-property-unknown otherwise), naming one of its bones
    // (bone-unknown), keyed as its field takes it (keyed-property-mismatch:
    // KeyFrameQuaternion the rotation, KeyFrameDouble a component).
    private resolveBone(tt: TrackTarget, node: SceneNode, kind: KeyFrameKind, p: string, where: string,
        pd: KeyedPropertyDecl?): TrackTarget {
        const bp = parseBoneProperty(p);
        const isSkeleton = node instanceof Skeleton3D;
        if (!isSkeleton) {
            this.warn(KEYED_PROPERTY_UNKNOWN, null, pd, where + ": a " + node.className + " has no bones (a Skeleton3D has)", null);
            return tt;
        }
        if (bp == null || (bp.field != BONE_FIELD_QUATERNION && bp.axis < 0)) {
            this.warn(KEYED_PROPERTY_UNKNOWN, null, pd, where + ": a bone is keyed as bones/<bone>:position:x (y, z), "
                + "bones/<bone>:quaternion or bones/<bone>:scale:x (y, z)", null);
            return tt;
        }
        const sk = node as Skeleton3D;
        const b = sk.findBone(bp.bone);
        if (b < 0) {
            this.warn(BONE_UNKNOWN_CODE, null, pd, where + ": the skeleton has no bone \"" + bp.bone + "\"", boneNamesHint(sk));
            return tt;
        }
        const rotation = bp.field == BONE_FIELD_QUATERNION;
        if (rotation && kind != KeyFrameKind.Quaternion) return this.mismatch(tt, pd, where, "KeyFrameQuaternion");
        if (!rotation && kind != KeyFrameKind.Double) return this.mismatch(tt, pd, where, "KeyFrameDouble");
        tt.family = FAMILY_BONE;
        tt.skeleton = sk;
        tt.index = b;
        tt.field = rotation ? BONE_ROTATION : bp.field == BONE_FIELD_POSITION ? BONE_POSITION : BONE_SCALE;
        tt.axis = bp.axis;
        tt.bone = this.boneStateOf(sk, b);
        return tt;
    }

    // A `blend_shapes/<name>` track on `node`: a MeshInstance3D's
    // (keyed-property-unknown otherwise), naming one of its blend shapes
    // (blend-shape-unknown), keyed by KeyFrameDouble; overridden by a
    // one_way binding of the same property.
    private resolveBlendShape(tt: TrackTarget, node: SceneNode, kind: KeyFrameKind, p: string, where: string,
        pd: KeyedPropertyDecl?): TrackTarget {
        const shape = blendShapeOf(p);
        const isMesh = node instanceof MeshInstance3D;
        if (!isMesh || shape == null) {
            this.warn(KEYED_PROPERTY_UNKNOWN, null, pd, where + (isMesh ? ": a blend shape is keyed as blend_shapes/<name>"
                : ": a " + node.className + " has no blend shapes (a MeshInstance3D of a model's mesh has)"), null);
            return tt;
        }
        const mesh = node as MeshInstance3D;
        const i = mesh.findBlendShapeByName(shape);
        if (i < 0) {
            this.warn(BLEND_SHAPE_UNKNOWN_CODE, null, pd, where + ": the mesh has no blend shape \"" + shape + "\"", blendShapeNamesHint(mesh));
            return tt;
        }
        if (kind != KeyFrameKind.Double) return this.mismatch(tt, pd, where, "KeyFrameDouble");
        tt.family = FAMILY_BLEND_SHAPE;
        tt.mesh = mesh;
        tt.index = i;
        tt.overridden = oneWayBound(node, p);
        return tt;
    }

    // The rotation state of bone `b` of `sk` (one per bone, made the first
    // time).
    private boneStateOf(sk: Skeleton3D, b: i32): BoneQuatState {
        const m = this.boneStates;
        let states: Array<BoneQuatState?>;
        if (m.has(sk.serial)) {
            states = m.get(sk.serial);
        } else {
            states = new Array<BoneQuatState?>();
            m.set(sk.serial, states);
        }
        while (states.length <= b) states.push(null);
        const had = states[b];
        if (had != null) return had;
        const made = new BoneQuatState(sk, b);
        states[b] = made;
        return made;
    }

    // The rotation state of `node` (one per node, made the first time).
    private quatStateOf(node: SceneNode): QuatState {
        const m = this.quatStates;
        if (m.has(node.serial)) return m.get(node.serial);
        const made = new QuatState(node);
        m.set(node.serial, made);
        return made;
    }

    private mismatch(tt: TrackTarget, pd: KeyedPropertyDecl?, where: string, want: string): TrackTarget {
        this.warn(KEYED_PROPERTY_MISMATCH, null, pd, where + " with keys of the wrong kind (it takes " + want + ")", null);
        return tt;
    }

    // A load warning, once (at the keyed object's or property's place).
    private warn(code: string, od: KeyedObjectDecl?, pd: KeyedPropertyDecl?, message: string, hint: string?): void {
        let line = 0;
        let col = 0;
        if (pd != null) {
            line = pd.pos.line;
            col = pd.pos.col;
        } else if (od != null) {
            line = od.pos.line;
            col = od.pos.col;
        }
        const d = new Diagnostic(Severity.Warning, code, this.file, line, col, message, hint);
        if (has(this.warnings, d)) return;
        this.warnings.add(d);
        const out = this.diag;
        if (out != null && !has(out, d)) out.add(d);
    }
}

// The property a key of `property` writes, as one Inspector row shows it:
// a vector's component is its vector's ("position:x" is position,
// "mesh:size:y" mesh:size), and rotation_degrees, rotation and quaternion
// are all "rotation" (three spellings of the node's one rotation). The
// editor asks the same (editor/src/scene/anim/targets.as keyRowOf),
// so that a key the engine overrides is the one the editor refuses.
export function keyedRowOf(property: string): string {
    let base = property;
    const colon = property.lastIndexOf(":");
    if (colon > 0 && property.length - colon == 2) {
        const c = property.charCodeAt(colon + 1);
        // (x, y, z or w)
        if (c >= 0x77 && c <= 0x7A) base = property.substring(0, colon);
    }
    if (base == "rotation_degrees" || base == QUATERNION_PROPERTY) return "rotation";
    return base;
}

// Whether a one_way binding of `node` (a `once` one is stored as one_way)
// drives what a key of `property` writes: a binding of the same row
// (keyedRowOf), whichever component or spelling it names. Such a binding
// writes its property every frame after the animations (RIVE_MODEL.md
// 6.1), so the key would change nothing: its track is overridden.
export function oneWayBound(node: SceneNode, property: string): bool {
    const binds = node.bindings;
    if (binds.length == 0) return false;
    const row = keyedRowOf(property);
    for (let i = 0; i < binds.length; i++) {
        const b = binds[i];
        if (b.mode != BindingMode.OneWay) continue;
        if (b.property == property || keyedRowOf(b.property) == row) return true;
    }
    return false;
}

function has(list: Diagnostics, d: Diagnostic): bool {
    const items = list.items;
    for (let i = 0; i < items.length; i++) {
        const e = items[i];
        if (e.code == d.code && e.file == d.file && e.line == d.line && e.col == d.col && e.message == d.message) return true;
    }
    return false;
}

// The keyframe element a target kind takes (for the mismatch's words).
function keyFrameOf(k: BindKind): string {
    switch (k) {
        case BindKind.Boolean: return "KeyFrameBool";
        case BindKind.Color: return "KeyFrameColor";
        case BindKind.String: return "KeyFrameString";
        case BindKind.Enum: return "KeyFrameUint";
        default: return "KeyFrameDouble";
    }
}

// Whether keys of `kind` drive a target of kind `k` (section 2.3 of the
// format: a number takes Double, or Int for an int property).
function takes(k: BindKind, kind: KeyFrameKind): bool {
    switch (k) {
        case BindKind.Number: return kind == KeyFrameKind.Double || kind == KeyFrameKind.Int;
        case BindKind.Boolean: return kind == KeyFrameKind.Bool;
        case BindKind.Color: return kind == KeyFrameKind.Color;
        case BindKind.String: return kind == KeyFrameKind.String;
        case BindKind.Enum: return kind == KeyFrameKind.Uint;
        default: return false;
    }
}

// What KeyedProperty::apply picks at `seconds`, given idx =
// closestFrameIndex(seconds): the key applied as it is (`key` >= 0), or the
// segment from key `key` interpolated to the next (`interpolate`). Only a
// leaving key that holds is applied as it is; any other interpolates, with
// its interpolator when it has one whatever its interpolationType says (a
// linear key with a child: Rive's applyInterpolation uses the child; the
// validator warns of the mismatch), linearly when it has none.
class KeyChoice {
    key: i32 = 0;
    interpolate: bool = false;
}

const choice = new KeyChoice();

function choose(track: KeyedTrack, idx: i32, seconds: f32): KeyChoice {
    const n = track.length;
    choice.interpolate = false;
    if (idx == 0) {
        choice.key = 0;
    } else if (idx < n) {
        if (seconds == unchecked(track.seconds[idx])) {
            choice.key = idx;
        } else if (unchecked(track.interpolations[idx - 1]) == InterpolationType.Hold) {
            choice.key = idx - 1;
        } else {
            choice.key = idx - 1;
            choice.interpolate = true;
        }
    } else {
        choice.key = n - 1;
    }
    return choice;
}

// The segment's fraction at `seconds` from key `k` to the next (Rive's f).
function fractionAt(track: KeyedTrack, k: i32, seconds: f32): f32 {
    const s0 = unchecked(track.seconds[k]);
    return (seconds - s0) / (unchecked(track.seconds[k + 1]) - s0);
}

// Rive's colour lerp of one channel: lround(clamp(a (1 - mix) + b mix, 0,
// 255)) (half away from zero: the value is never negative here).
function lerpByte(a: u32, b: u32, mix: f32): u32 {
    let x: f32 = <f32>a * (<f32>1 - mix) + <f32>b * mix;
    if (x < 0) x = 0;
    if (x > 255) x = 255;
    return <u32>Math.floor(<f64>x + 0.5);
}

// Rive's colorLerp on ARGB.
export function colorLerp(from: u32, to: u32, mix: f32): u32 {
    return (lerpByte(from >> 24, to >> 24, mix) << 24) | (lerpByte((from >> 16) & 0xff, (to >> 16) & 0xff, mix) << 16)
        | (lerpByte((from >> 8) & 0xff, (to >> 8) & 0xff, mix) << 8) | lerpByte(from & 0xff, to & 0xff, mix);
}

// One keyed property of the property family at `seconds`, by its keyframe
// kind's Rive rule; whether the value written differs from the one there.
function applyProperty(tree: SceneTree, node: SceneNode, track: KeyedTrack, tt: TrackTarget, idx: i32, seconds: f32, mix: f32): bool {
    // (a rotation or scale goes through the node's pose: the rotations
    // pending are written first, so that it reads them)
    if (tt.usesPose && pendingQuats.length > 0) flushQuaternions();
    if (tt.vector >= 0 && track.kind == KeyFrameKind.Double) return applyComponent(node, track, tt, idx, seconds, mix);
    const target = tt.target as BindingTarget;
    const pose = tt.usesPose ? BindingPose.of(node) : null;
    const cur = tt.read;
    if (!readTarget(node, target, cur, pose)) return false;
    const c = choose(track, idx, seconds);
    const k = c.key;
    const out = tt.write;
    const kind = track.kind;
    if (kind == KeyFrameKind.Double) {
        let v: f32;
        if (c.interpolate) {
            const from = unchecked(track.values[k]);
            const to = unchecked(track.values[k + 1]);
            const f = fractionAt(track, k, seconds);
            const ip = unchecked(track.interpolators[k]);
            v = ip != null ? ip.transformValue(from, to, f) : from + (to - from) * f;
        } else {
            v = unchecked(track.values[k]);
        }
        if (mix != 1) {
            const mixi: f32 = <f32>1 - mix;
            v = <f32>cur.number * mixi + v * mix;
        }
        if (<f64>v == cur.number) return false;
        out.setNumber(<f64>v);
    } else if (kind == KeyFrameKind.Int) {
        // (Rive's KeyFrameInt holds, whatever the mix)
        const v = unchecked(track.values[k]);
        if (<f64>v == cur.number) return false;
        out.setNumber(<f64>v);
    } else if (kind == KeyFrameKind.Uint) {
        // (an enum: Rive's Uint of a property that does not interpolate
        // holds, whatever the mix)
        const v = <f64>unchecked(track.values[k]);
        if (v == cur.number) return false;
        out.setNumber(v);
    } else if (kind == KeyFrameKind.Bool) {
        const v = unchecked(track.values[k]) != 0;
        if (cur.kind == VmKind.Boolean && v == cur.boolean) return false;
        out.setBoolean(v);
    } else if (kind == KeyFrameKind.String) {
        const v = unchecked(track.texts[k]);
        if (v == cur.text) return false;
        out.setString(v);
    } else if (kind == KeyFrameKind.Color) {
        let v: u32;
        if (c.interpolate) {
            let f = fractionAt(track, k, seconds);
            const ip = unchecked(track.interpolators[k]);
            if (ip != null) f = ip.transform(f);
            v = colorLerp(unchecked(track.colors[k]), unchecked(track.colors[k + 1]), f);
        } else {
            v = unchecked(track.colors[k]);
        }
        if (mix != 1) v = colorLerp(cur.color, v, mix);
        if (v == cur.color) return false;
        out.setColor(v);
    } else {
        return false;
    }
    return writeTarget(tree, node, target, out, pose);
}

// A Double key's value at `seconds` (KeyFrameDouble's apply or
// applyInterpolation), before the mix.
function doubleAt(track: KeyedTrack, idx: i32, seconds: f32): f32 {
    const c = choose(track, idx, seconds);
    const k = c.key;
    if (!c.interpolate) return unchecked(track.values[k]);
    const from = unchecked(track.values[k]);
    const to = unchecked(track.values[k + 1]);
    const f = fractionAt(track, k, seconds);
    const ip = unchecked(track.interpolators[k]);
    return ip != null ? ip.transformValue(from, to, f) : from + (to - from) * f;
}

function component(v: Vec3, axis: i32): f32 {
    return axis == 0 ? v.x : axis == 1 ? v.y : v.z;
}

function withComponent(v: Vec3, axis: i32, x: f32): Vec3 {
    return axis == 0 ? Vec3(x, v.y, v.z) : axis == 1 ? Vec3(v.x, x, v.z) : Vec3(v.x, v.y, x);
}

// A Double key on a rotation or scale component: what readTarget and
// writeTarget do for it (through the node's BindingPose), mixed as
// KeyFrameDouble mixes. (A position component is applied by applyAt,
// which gathers a node's three.)
function applyComponent(node: SceneNode, track: KeyedTrack, tt: TrackTarget, idx: i32, seconds: f32, mix: f32): bool {
    let v = doubleAt(track, idx, seconds);
    const axis = tt.axis;
    const vec = tt.vector;
    const pose = BindingPose.of(node);
    pose.sync(node);
    let cur: f32;
    if (vec == TRANSFORM_SCALE) cur = component(pose.scale, axis);
    else if (vec == TRANSFORM_ROTATION) cur = component(pose.rotation, axis);
    else cur = <f32>(<f64>component(pose.rotation, axis) / DEG);
    if (mix != 1) v = cur * (<f32>1 - mix) + v * mix;
    if (v == cur) return false;
    if (vec == TRANSFORM_SCALE) pose.scale = withComponent(pose.scale, axis, v);
    else if (vec == TRANSFORM_ROTATION) pose.rotation = withComponent(pose.rotation, axis, v);
    else pose.rotation = withComponent(pose.rotation, axis, <f32>(<f64>v * DEG));
    pose.apply(node);
    return true;
}

// A quaternion key at `seconds`: slerped from the leaving key to the next
// by its eased fraction, then slerped from the node's rotation by `mix`;
// left pending in the node's state (written by flushQuaternions). Whether
// the rotation changed.
function applyQuaternion(track: KeyedTrack, st: QuatState, idx: i32, seconds: f32, mix: f32): bool {
    const c = choose(track, idx, seconds);
    const k = c.key;
    const v = track.values;
    // (the keys are unit quaternions: prepareAnimation normalised them)
    let q = Quat(unchecked(v[k * 4]), unchecked(v[k * 4 + 1]), unchecked(v[k * 4 + 2]), unchecked(v[k * 4 + 3]));
    if (c.interpolate) {
        const j = (k + 1) * 4;
        const to = Quat(unchecked(v[j]), unchecked(v[j + 1]), unchecked(v[j + 2]), unchecked(v[j + 3]));
        let f = fractionAt(track, k, seconds);
        const ip = unchecked(track.interpolators[k]);
        if (ip != null) f = ip.ease(f);
        q = q.slerp(to, f);
    }
    if (mix != 1) q = st.current().slerp(q, mix);
    if (!st.pending && st.written && q == st.q && Mat3.fromMat4(st.node.local) == Mat3.fromMat4(st.local)) return false;
    st.q = q;
    if (!st.pending) {
        st.pending = true;
        pendingQuats.push(st);
    }
    return true;
}

// A bone track (FAMILY_BONE) at `seconds`: a component mixed into the
// bone's pose as KeyFrameDouble mixes a number, written at once; the
// rotation slerped as a quaternion is and left pending in the bone's
// state. Whether the pose changed.
function applyBone(track: KeyedTrack, tt: TrackTarget, idx: i32, seconds: f32, mix: f32): bool {
    const st = tt.bone as BoneQuatState;
    if (tt.field == BONE_ROTATION) {
        const c = choose(track, idx, seconds);
        const k = c.key;
        const v = track.values;
        let q = Quat(unchecked(v[k * 4]), unchecked(v[k * 4 + 1]), unchecked(v[k * 4 + 2]), unchecked(v[k * 4 + 3]));
        if (c.interpolate) {
            const j = (k + 1) * 4;
            const to = Quat(unchecked(v[j]), unchecked(v[j + 1]), unchecked(v[j + 2]), unchecked(v[j + 3]));
            let f = fractionAt(track, k, seconds);
            const ip = unchecked(track.interpolators[k]);
            if (ip != null) f = ip.ease(f);
            q = q.slerp(to, f);
        }
        if (mix != 1) q = st.current().slerp(q, mix);
        if (!st.pending && q == st.skeleton.getBonePoseRotation(st.index)) return false;
        st.q = q;
        st.pending = true;
        st.queue();
        return true;
    }
    const position = tt.field == BONE_POSITION;
    const vec = position ? st.currentPosition() : st.currentScale();
    const cur = component(vec, tt.axis);
    let x = doubleAt(track, idx, seconds);
    if (mix != 1) x = cur * (<f32>1 - mix) + x * mix;
    const pendingNow = position ? st.positionPending : st.scalePending;
    if (x == cur && !pendingNow) return false;
    if (position) {
        st.position = withComponent(vec, tt.axis, x);
        st.positionPending = true;
    } else {
        st.scale = withComponent(vec, tt.axis, x);
        st.scalePending = true;
    }
    st.queue();
    return true;
}

// A blend shape track (FAMILY_BLEND_SHAPE) at `seconds`, mixed into the
// weight as KeyFrameDouble mixes a number. Whether the weight changed.
function applyBlendShape(track: KeyedTrack, tt: TrackTarget, idx: i32, seconds: f32, mix: f32): bool {
    const mesh = tt.mesh as MeshInstance3D;
    const i = tt.index;
    const cur = mesh.getBlendShapeValue(i);
    let x = doubleAt(track, idx, seconds);
    if (mix != 1) x = cur * (<f32>1 - mix) + x * mix;
    if (x == cur) return false;
    mesh.setBlendShapeValue(i, x);
    return true;
}

// The hint of a bone the skeleton does not have: its bones.
export function boneNamesHint(sk: Skeleton3D): string {
    if (sk.bones.length == 0) return "the skeleton has no bones";
    const names = new Array<string>();
    for (let i = 0; i < sk.bones.length; i++) names.push(sk.bones[i].name);
    return "its bones are " + names.join(", ");
}

// The hint of a blend shape the mesh does not have: its blend shapes.
export function blendShapeNamesHint(mesh: MeshInstance3D): string {
    if (mesh.blendShapeNames.length == 0) return "the mesh has no blend shapes";
    return "its blend shapes are " + mesh.blendShapeNames.join(", ");
}

// `b` with each column divided by its component of `s` (a zero one left
// as it is).
function unscaled(b: Mat3, s: Vec3): Mat3 {
    const x = s.x != 0 ? b.xAxis / s.x : b.xAxis;
    const y = s.y != 0 ? b.yAxis / s.y : b.yAxis;
    const z = s.z != 0 ? b.zAxis / s.z : b.zAxis;
    return Mat3(x, y, z);
}

// Milestone 48: a model a scene instances, whose clips the scene lists
// after its own animations: the instancing node's path from the scene's
// root ("." for a model that is the root), the model, and the source its
// clips are labelled with (the file's name, "hero.glb"; the node's path
// when two nodes of the scene instance files of one name).
export class ImportedModel {
    path: string;
    model: ModelResource;
    source: string;

    constructor(path: string, model: ModelResource, source: string) {
        this.path = path;
        this.model = model;
        this.source = source;
    }
}

// The instancer's call (../tree/instance.as): `doc`'s animations and
// events on `root`, the root of the scene the instancer just made from
// `doc` (`file` as errors name it), then the clips of the models `imported`
// lists (../skeleton/clips.as importedClipDecls; SceneAnimations
// .importedSources says which they are). Nothing for a scene that has
// none of these (root.animations stays as it was: null, or an inherited
// scene's instanced root's). The animations are prepared once per document
// and `prepared` (the instancer's, or the share its trees use: documents
// there do not change, nor the models the loader caches) keeps them; null
// prepares them each time. Targets are resolved lazily, on the first
// apply; the load warnings of what does not resolve go to `diag` (the
// loader's diagnostics, which the tree keeps) and to the scene's own
// `warnings`.
export function attachSceneAnimations(root: SceneNode, doc: RscnDoc, file: string, diag: Diagnostics,
    prepared: Map<RscnDoc, Array<LinearAnimation>>? = null, imported: Array<ImportedModel>? = null,
    clips: Map<RscnDoc, ImportedClipSet>? = null): void {
    const decls = doc.animations();
    const events = doc.events();
    const sources = new Array<string>();
    for (let i = 0; i < decls.length; i++) sources.push("");
    if (imported != null && imported.length > 0) {
        // (made once per document and its models, `clips` keeping them:
        // every instance shares the declarations, as it does the prepared
        // animations)
        const set = importedSet(doc, imported, clips);
        for (let i = 0; i < set.decls.length; i++) {
            decls.push(set.decls[i]);
            sources.push(set.sources[i]);
        }
    }
    if (decls.length == 0 && events.length == 0) return;
    const sa = new SceneAnimations(root, file);
    sa.decls = decls;
    sa.events = events;
    sa.importedSources = sources;
    sa.diag = diag;
    if (prepared != null && prepared.has(doc) && sameNames(prepared.get(doc), decls)) {
        sa.animations = prepared.get(doc);
    } else {
        const made = new Array<LinearAnimation>();
        for (let i = 0; i < decls.length; i++) made.push(prepareAnimation(decls[i]));
        sa.animations = made;
        if (prepared != null) prepared.set(doc, made);
    }
    root.animations = sa;
}

// Milestone 48: the clips of a model that is a tree's root (a model file
// loaded as a scene, or instanced by a script): its SceneAnimations, the
// clips labelled with `source` (the file's name) and keyed from ".".
// Nothing for a model without clips.
export function attachModelAnimations(root: SceneNode, model: ModelResource, source: string, file: string, diag: Diagnostics): void {
    if (model.clips.length == 0) return;
    const set = ImportedClipSet.make(["."], [model], [source]);
    const sa = new SceneAnimations(root, file);
    sa.decls = set.decls.slice(0);
    sa.importedSources = set.sources.slice(0);
    const decls = sa.decls;
    sa.diag = diag;
    const made = new Array<LinearAnimation>();
    for (let i = 0; i < decls.length; i++) made.push(prepareAnimation(decls[i]));
    sa.animations = made;
    root.animations = sa;
}

// The imported clips of `doc`'s models: `clips`'s when it was made from
// the same models at the same paths, else made (and kept there).
function importedSet(doc: RscnDoc, imported: Array<ImportedModel>, clips: Map<RscnDoc, ImportedClipSet>?): ImportedClipSet {
    const paths = new Array<string>();
    const models = new Array<ModelResource>();
    const labels = new Array<string>();
    for (let m = 0; m < imported.length; m++) {
        paths.push(imported[m].path);
        models.push(imported[m].model);
        labels.push(imported[m].source);
    }
    if (clips != null && clips.has(doc)) {
        const had = clips.get(doc);
        if (had.madeFrom(paths, models, labels)) return had;
    }
    const set = ImportedClipSet.make(paths, models, labels);
    if (clips != null) clips.set(doc, set);
    return set;
}

// Whether prepared animations are the declarations' (one each, by name).
function sameNames(made: Array<LinearAnimation>, decls: Array<LinearAnimationDecl>): bool {
    if (made.length != decls.length) return false;
    for (let i = 0; i < made.length; i++) if (made[i].name != decls[i].name) return false;
    return true;
}

// Every scene of `tree` that declares animations or events: the root's
// first, then the instanced scenes' in tree order.
export function sceneAnimationsOf(tree: SceneTree): Array<SceneAnimations> {
    const out = new Array<SceneAnimations>();
    collect(tree.root, out);
    return out;
}

function collect(n: SceneNode, out: Array<SceneAnimations>): void {
    const sa = n.animations;
    if (sa != null && sa.root === n) out.push(sa);
    for (let i = 0; i < n.children.length; i++) collect(n.children[i], out);
}

// The root scene's (null when it declares none).
export function rootSceneAnimations(tree: SceneTree): SceneAnimations? {
    return tree.root.animations;
}

// The scene that declared `node` (its owner chain's first root holding
// animations: `node` itself when it is a scene's root), or null.
export function sceneAnimationsFor(node: SceneNode): SceneAnimations? {
    const own = node.animations;
    if (own != null) return own;
    let o = node.owner;
    while (o != null) {
        const sa = o.animations;
        if (sa != null) return sa;
        o = o.owner;
    }
    return null;
}

// What applyAnimationAtFrame did.
export class AnimationSample {
    name: string;
    frame: f64;
    // frame / fps.
    seconds: f64;
    // The time the values were sampled at: `seconds`, or with quantize
    // the whole frame's (frame 22.5 of a 60 fps quantized animation is
    // sampled at 22 / 60 s).
    sampledSeconds: f64;
    // How many keyed properties were written, and how many were not because
    // a binding overrides them.
    written: i32 = 0;
    overridden: i32 = 0;

    constructor(name: string, frame: f64, seconds: f64) {
        this.name = name;
        this.frame = frame;
        this.seconds = seconds;
        this.sampledSeconds = seconds;
    }
}

// The hint of an unknown animation: the scene's names.
export function animationNamesHint(scene: SceneAnimations?): string {
    if (scene == null || scene.animations.length == 0) return "the scene has no animations";
    return "the scene's animations are " + scene.names().join(", ");
}

// The tools' sampling (render --animation --frame, inspect, the editor's
// playhead): applies the root scene's animation `name` (or `scene`'s) at
// `frame` (a frame of its fps; fractional allowed), mix 1, onto `tree`'s
// nodes, as Rive's LinearAnimation::apply(time) does with no instance
// (quantized when the animation quantizes; no loop: a frame past the last
// key holds it): callbacks fire nothing. An unknown name is
// ANIMATION_UNKNOWN, its hint listing the scene's animations.
export function applyAnimationAtFrame(tree: SceneTree, name: string, frame: f64, scene: SceneAnimations? = null): Result<AnimationSample> {
    const sa = scene != null ? scene : rootSceneAnimations(tree);
    const ai = sa != null ? sa.index(name) : -1;
    if (sa == null || ai < 0) {
        const file = sa != null ? sa.file : tree.root.sceneFile;
        return SceneryError.at(ANIMATION_UNKNOWN, file, 0, 0, "the scene has no animation \"" + name + "\"", animationNamesHint(sa))
            .fail<AnimationSample>();
    }
    const a = sa.animations[ai];
    const sample = new AnimationSample(name, frame, frame / <f64>a.fps);
    // The values are sampled as Rive samples them (applyTime: in f32, a
    // quantized animation's floor(seconds * fps) / fps), and the time told
    // is that one: for some whole frames, floor((k / fps) * fps) is k - 1
    // in f32 (63 at 60 fps, 53 at 25), so working the floor out in f64
    // would tell frame k's time beside frame k - 1's values. (The frame
    // sampled is whole: its time is told as that frame / fps in f64, not
    // as the f32's 0.36666667461395266.)
    const at = a.applyTime(<f32>frame / <f32>a.fps);
    if (a.quantize) sample.sampledSeconds = Math.round(<f64>at * <f64>a.fps) / <f64>a.fps;
    sa.applyAt(tree, ai, at, 1, null);
    flushQuaternions();
    sample.written = sa.lastWritten;
    sample.overridden = sa.lastOverridden;
    return Result.okv<AnimationSample>(sample);
}
