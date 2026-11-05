// glTF animations and morph targets on import.
//
// Morph targets become shape keys: the Basis holds the mesh as it was
// read, target `i` becomes a key named from the mesh's
// `extras.targetNames[i]` (Blender / three.js convention) or `Key_<i>`,
// and the mesh or node `weights` become the key values.
//
// Animations become actions, one per animated object: a glTF animation
// may drive several nodes, and an action belongs to one object, so the
// channels are grouped by object and the actions all take the animation's
// name, made unique the Blender way (`Walk`, `Walk.001`). Node
// translation / rotation / scale channels become `location`,
// `rotation_quaternion` and `scale` curves; channels on a joint node
// become `pose.bones["X"].*` curves holding the pose basis the joint
// transform implies, extracted the same way `import_skins` extracts the
// static pose (a joint whose frame is not its bone's is carried over as
// import_skins.as says); `weights` channels become `key_blocks["K"].value`
// curves.
// Times in seconds become frames through the scene's fps.
//
// `STEP` becomes Constant, `LINEAR` Linear and `CUBICSPLINE` Bezier. The
// Bezier handles are placed a third of the neighbouring gap away along
// the glTF tangent (the usual Hermite-to-Bezier conversion; the curve
// shape between keys is an approximation either way). On pose bone
// channels the tangents are dropped and the keys get Blender's
// auto-clamped handles instead, because a joint transform is remapped
// into the bone's basis non-linearly and the tangent would not survive
// the change.
//
// Optional object lookups use `Map.has`; glTF node / skin / joint indices
// are the i32s of engine/src/source/io/gltf/doc.as.

import { Mat3, Mat4, Quat, Vec2, Vec3, MAT4_IDENTITY, QUAT_IDENTITY } from "../../../base/vecmath";
import { minF32, maxF32, roundF32, panic } from "../../../base/util";
import { parseJson } from "../../../base/json";
import { Scene } from "../../model/scene";
import { Action, AnimData } from "../../model/anim/mod";
import { HandleType, Interpolation } from "../../model/anim/fcurve";
import { Mesh } from "../../model/mesh/mod";
import { ShapeKey, BASIS_NAME } from "../../model/mesh/shapekey";
import { NO_BONE } from "../../model/armature/mod";
import {
    Root, Mesh as GltfMesh, Property, Interpolation as GltfInterpolation, unwrapChecked,
} from "../gltf/doc";
import { ChannelReader, nodeTransform } from "../gltf/reader";
import { SkinInfo, SkinSet, ToScene } from "./import_skins";
import { VertPositions } from "./gltf_import";

// Shape key names of a glTF mesh: `extras.targetNames` when it has them.
export function targetNames(mesh: GltfMesh, count: i32): Array<string> {
    const named: Array<string> = [];
    const extras = mesh.extras;
    if (extras != null) {
        const v = parseJson(extras);
        if (v.ok) {
            const names = v.value.get("targetNames");
            if (names != null) {
                const arr = names.asArray();
                if (arr != null) {
                    for (let i = 0; i < arr.length; i++) {
                        const s = arr[i].asStr();
                        named.push(s != null ? s : "");
                    }
                }
            }
        }
    }
    const out: Array<string> = [];
    for (let i = 0; i < count; i++) {
        if (i < named.length && named[i].length > 0) out.push(named[i]);
        else out.push("Key_" + i.toString());
    }
    return out;
}

// Add the Basis plus one key per morph target. `targets[i]` holds the
// absolute positions (already in Hedra space) of the vertices the
// target moves.
export function addShapeKeys(mesh: Mesh, names: Array<string>, targets: Array<VertPositions>, weights: Array<f32>?): void {
    if (targets.length == 0) return;
    mesh.shapeKeyAdd(BASIS_NAME, false);
    for (let i = 0; i < targets.length; i++) {
        const moved = targets[i];
        const positions = mesh.shapeKeys[0].positions.slice(0);
        for (let k = 0; k < moved.ids.length; k++) {
            const v = moved.ids[k];
            if (<i64>v < <i64>positions.length) positions[<i32>v] = moved.cos[k];
        }
        const name = i < names.length
            ? mesh.uniqueShapeKeyName(names[i])
            : mesh.uniqueShapeKeyName("Key_" + i.toString());
        const key = ShapeKey.new(name, positions);
        let value: f32 = 0.0;
        if (weights != null && i < weights.length) value = weights[i];
        key.value = value;
        // glTF weights are not bound to 0..1; widen the slider rather than
        // clamp the value away.
        key.sliderMin = minF32(key.sliderMin, key.value);
        key.sliderMax = maxF32(key.sliderMax, key.value);
        mesh.shapeKeys.push(key);
    }
    mesh.touch();
}

// What the node walk learned, so a channel can find its object or bone.
export class AnimScene {
    // glTF node -> imported object.
    objOfNode: Map<i32, u32>;
    skins: SkinSet;
    // Armature object per skin index.
    armObj: Array<u32>;
    // Bone names in joint order, per skin.
    boneNames: Array<Array<string>>;
    // Mesh objects whose node transform the importer dropped.
    skinned: Array<u32>;

    constructor(objOfNode: Map<i32, u32>, skins: SkinSet, armObj: Array<u32>, boneNames: Array<Array<string>>, skinned: Array<u32>) {
        this.objOfNode = objOfNode;
        this.skins = skins;
        this.armObj = armObj;
        this.boneNames = boneNames;
        this.skinned = skinned;
    }
}

// The debug name of an animation target Property.
export function propertyDebug(p: Property): string {
    if (p == Property.Translation) return "Translation";
    if (p == Property.Rotation) return "Rotation";
    if (p == Property.Scale) return "Scale";
    return "MorphTargetWeights";
}

// One key of one channel, already in Hedra space.
class Key {
    frame: f32;
    value: Array<f32>;
    // glTF tangents (value units per second), when the sampler is cubic
    // and the mapping into Hedra space was linear (null = None).
    inTangent: Array<f32>?;
    outTangent: Array<f32>?;
    constructor(frame: f32, value: Array<f32>, inTangent: Array<f32>?, outTangent: Array<f32>?) {
        this.frame = frame;
        this.value = value;
        this.inTangent = inTangent;
        this.outTangent = outTangent;
    }
}

// A channel's sampler, read out in full.
class Samples {
    frames: Float32Array;
    cubic: bool;
    interpolation: Interpolation;
    // One entry per accessor element: `3 * frames` of them when cubic.
    elements: Array<Float32Array>;

    constructor(frames: Float32Array, cubic: bool, interpolation: Interpolation, elements: Array<Float32Array>) {
        this.frames = frames;
        this.cubic = cubic;
        this.interpolation = interpolation;
        this.elements = elements;
    }

    value(i: i32): Float32Array {
        return this.elements[this.cubic ? 3 * i + 1 : i];
    }

    // `tangents(i)`: (in, out) when cubic; callers check `cubic` first.
    inTangent(i: i32): Float32Array {
        return this.elements[3 * i];
    }

    outTangent(i: i32): Float32Array {
        return this.elements[3 * i + 2];
    }
}

// Splits a flat array into `comps`-wide elements (`chunks(comps)`, views).
function chunks(all: Float32Array, comps: i32): Array<Float32Array> {
    if (comps == 0) panic("chunk size must be non-zero");
    const out: Array<Float32Array> = [];
    for (let at = 0; at < all.length; at += comps) {
        out.push(all.subarray(at, min(at + comps, all.length)));
    }
    return out;
}

function readSamples(doc: Root, anim: i32, channel: i32, buffers: Array<Uint8Array>, fps: f32): Samples? {
    const reader = new ChannelReader(doc, anim, channel, buffers);
    // Times are seconds; rounding keeps a 24 fps export on whole frames
    // instead of 1.0000001.
    const inputs = reader.readInputs();
    if (inputs == null) return null;
    const frames = new Float32Array(inputs.length);
    for (let i = 0; i < inputs.length; i++) {
        frames[i] = roundF32(inputs[i] * fps * <f32>1000.0) / <f32>1000.0;
    }
    const a = doc.animations[anim];
    const sampler = a.samplers[a.channels[channel].sampler];
    const interp = <GltfInterpolation>unwrapChecked(sampler.interpolation);
    const cubic = interp == GltfInterpolation.CubicSpline;
    const outputs = reader.readOutputs();
    if (outputs == null) return null;
    let elements: Array<Float32Array>;
    const all = outputs.intoF32();
    if (outputs.property == Property.MorphTargetWeights) {
        const perKey = frames.length * (cubic ? 3 : 1);
        if (perKey == 0 || all.length % perKey != 0) {
            return null;
        }
        elements = chunks(all, all.length / perKey);
    } else {
        elements = chunks(all, outputs.read.comps);
    }
    // A cubic sampler stores an in-tangent, the value and an out-tangent
    // per key; a short output accessor means the file is malformed.
    if (frames.length == 0 || elements.length < frames.length * (cubic ? 3 : 1)) {
        return null;
    }
    let interpolation = Interpolation.Bezier;
    if (interp == GltfInterpolation.Step) interpolation = Interpolation.Constant;
    else if (interp == GltfInterpolation.Linear) interpolation = Interpolation.Linear;
    return new Samples(frames, cubic, interpolation, elements);
}

// `(ObjId, Action)` of `per_owner`.
class OwnedAction {
    owner: u32;
    action: Action;
    constructor(owner: u32, action: Action) {
        this.owner = owner;
        this.action = action;
    }
}

// A curve's data path and array index.
class PathIndex {
    path: string;
    index: u32;
    constructor(path: string, index: u32) {
        this.path = path;
        this.index = index;
    }
}

// The object channels' value map: every one of
// these maps is linear, so the glTF tangents can go through it unchanged.
class ObjectConvert {
    property: Property;
    conv: Mat4;
    convInv: Mat4;
    scale: f32;
    constructor(property: Property, conv: Mat4, convInv: Mat4, scale: f32) {
        this.property = property;
        this.conv = conv;
        this.convInv = convInv;
        this.scale = scale;
    }

    apply(v: Float32Array): Array<f32> {
        if (this.property == Property.Translation) {
            const t = this.convInv.transformVector3(Vec3(v[0], v[1], v[2])) * this.scale;
            return [t.x, t.y, t.z];
        }
        if (this.property == Property.Rotation) {
            const qc = Quat.fromMat4(this.conv);
            const q = qc.inverse() * Quat.fromXyzw(v[0], v[1], v[2], v[3]) * qc;
            return [q.w, q.x, q.y, q.z];
        }
        const s = permutedScale(this.conv, Vec3(v[0], v[1], v[2]));
        return [s.x, s.y, s.z];
    }
}

function copyOf(v: Float32Array): Array<f32> {
    const out: Array<f32> = [];
    for (let i = 0; i < v.length; i++) out.push(v[i]);
    return out;
}

// Read every animation into actions. Returns the number of actions made.
export function importAnimations(
    scene: Scene, doc: Root, buffers: Array<Uint8Array>, conv: Mat4, scale: f32, map: AnimScene, warnings: Array<string>,
): i32 {
    const fps: f32 = scene.fps > <f32>1e-3 ? scene.fps : <f32>24.0;
    const convInv = conv.inverse();
    // The conjugation that takes a glTF matrix back to Hedra space, with
    // the unit scale on the translation (see `gltf_import::to_scene`).
    const toScene = new ToScene(conv, convInv, scale);
    let made = 0;
    for (let ai = 0; ai < doc.animations.length; ai++) {
        const anim = doc.animations[ai];
        const an = anim.name;
        const name = an != null ? an : "Action";
        const perOwner: Array<OwnedAction> = [];
        for (let ci = 0; ci < anim.channels.length; ci++) {
            const target = anim.channels[ci].target;
            const ni = target.node;
            if (ni < 0 || ni >= doc.nodes.length) panic("called `Option::unwrap()` on a `None` value");
            const property = <Property>unwrapChecked(target.path);
            const s = readSamples(doc, ai, ci, buffers, fps);
            if (s == null) {
                warnings.push("'" + name + "': a " + propertyDebug(property) + " channel could not be read; skipped");
                continue;
            }
            const joint = map.skins.jointOf(ni);
            let owner: u32;
            let paths: Array<PathIndex>;
            let keys: Array<Key>;
            if (property == Property.MorphTargetWeights) {
                if (!map.objOfNode.has(ni)) {
                    warnings.push("'" + name + "': a weights channel targets a node that is not an object; skipped");
                    continue;
                }
                const obj = map.objOfNode.get(ni);
                const names: Array<string> = [];
                const m = scene.objects.at(obj).mesh();
                if (m != null) {
                    for (let k = 1; k < m.shapeKeys.length; k++) names.push(m.shapeKeys[k].name);
                }
                if (names.length == 0) {
                    warnings.push("'" + name + "': '" + scene.objects.at(obj).name + "' has no shape keys for its weights channel; skipped");
                    continue;
                }
                paths = [];
                for (let k = 0; k < names.length; k++) paths.push(new PathIndex("key_blocks[\"" + names[k] + "\"].value", 0));
                keys = linearKeysCopy(s, paths.length);
                owner = obj;
            } else if (joint != null) {
                const si = joint.skin;
                const j = joint.joint;
                if (si >= map.armObj.length) continue;
                const armId = map.armObj[si];
                if (si >= map.boneNames.length || j >= map.boneNames[si].length) continue;
                const bone = map.boneNames[si][j];
                const bs = boneSpace(scene, armId, bone, doc, ni, map.skins.skins[si], j, map.boneNames[si]);
                if (bs == null) continue;
                paths = bonePaths(bone, property);
                keys = [];
                for (let i = 0; i < s.frames.length; i++) {
                    const local = localWith(bs, property, s.value(i));
                    // Tangents are dropped here: see the module doc.
                    const m = bs.carried ? bs.pre * toScene.apply(local) * bs.post : bs.pre * toScene.apply(local);
                    keys.push(new Key(s.frames[i], basisComponent(m, property), null, null));
                }
                owner = armId;
            } else {
                if (!map.objOfNode.has(ni)) {
                    warnings.push("'" + name + "': a " + propertyDebug(property) + " channel targets a node that is not an object; skipped");
                    continue;
                }
                const obj = map.objOfNode.get(ni);
                if (map.skinned.includes(obj)) {
                    warnings.push(
                        "'" + name + "': '" + scene.objects.at(obj).name + "' is a skinned mesh, whose node transform glTF ignores; its "
                        + propertyDebug(property) + " channel was skipped",
                    );
                    continue;
                }
                paths = objectPaths(property);
                keys = linearKeys(s, paths.length, new ObjectConvert(property, conv, convInv, scale));
                owner = obj;
            }
            let entry: Action? = null;
            for (let k = 0; k < perOwner.length; k++) {
                if (perOwner[k].owner == owner) {
                    entry = perOwner[k].action;
                    break;
                }
            }
            if (entry == null) {
                const act = new Action(name);
                perOwner.push(new OwnedAction(owner, act));
                entry = act;
            }
            emit(entry, paths, keys, s.interpolation, fps);
        }
        for (let k = 0; k < perOwner.length; k++) {
            const owner = perOwner[k].owner;
            const action = perOwner[k].action;
            action.prune();
            if (action.fcurves.length == 0) {
                continue;
            }
            action.name = scene.uniqueActionName(name);
            const assigned = action.name;
            const id = scene.actions.push(action);
            made++;
            const obj = scene.objects.at(owner);
            const cur = obj.animation;
            if (cur != null && cur.hasAction()) {
                warnings.push("'" + obj.name + "' is driven by more than one animation; '" + assigned + "' was imported but not assigned");
            } else {
                obj.animation = new AnimData(id);
            }
        }
    }
    return made;
}

// Linear keys with each value copied as is.
function linearKeysCopy(s: Samples, components: i32): Array<Key> {
    const out: Array<Key> = [];
    for (let i = 0; i < s.frames.length; i++) {
        const value = copyOf(s.value(i));
        let inT: Array<f32>? = null;
        let outT: Array<f32>? = null;
        if (s.cubic) {
            inT = copyOf(s.inTangent(i));
            outT = copyOf(s.outTangent(i));
        }
        out.push(new Key(s.frames[i], value.slice(0, min(components, value.length)), inT, outT));
    }
    return out;
}

// Keys of a channel whose value map is linear, tangents included.
function linearKeys(s: Samples, components: i32, convert: ObjectConvert): Array<Key> {
    const out: Array<Key> = [];
    for (let i = 0; i < s.frames.length; i++) {
        const value = convert.apply(s.value(i));
        let inT: Array<f32>? = null;
        let outT: Array<f32>? = null;
        if (s.cubic) {
            inT = convert.apply(s.inTangent(i));
            outT = convert.apply(s.outTangent(i));
        }
        out.push(new Key(s.frames[i], value.slice(0, min(components, value.length)), inT, outT));
    }
    return out;
}

function channelOf(property: Property): string {
    if (property == Property.Translation) return "location";
    if (property == Property.Rotation) return "rotation_quaternion";
    return "scale";
}

function componentsOf(property: Property): u32 {
    return property == Property.Rotation ? 4 : 3;
}

function objectPaths(property: Property): Array<PathIndex> {
    const path = channelOf(property);
    const n = componentsOf(property);
    const out: Array<PathIndex> = [];
    for (let i: u32 = 0; i < n; i++) out.push(new PathIndex(path, i));
    return out;
}

function bonePaths(bone: string, property: Property): Array<PathIndex> {
    const channel = channelOf(property);
    const n = componentsOf(property);
    const out: Array<PathIndex> = [];
    for (let i: u32 = 0; i < n; i++) out.push(new PathIndex("pose.bones[\"" + bone + "\"]." + channel, i));
    return out;
}

// `(Mat4, (Vec3, Quat, Vec3))` of bone_space, and the matrix a carried-over
// joint's basis ends with.
class BoneSpace {
    pre: Mat4;
    t: Vec3;
    r: Quat;
    s: Vec3;
    // The skin carries joint frames over (SkinInfo.corrected): the basis is
    // `pre * local * post`.
    carried: bool = false;
    post: Mat4 = MAT4_IDENTITY;
    constructor(pre: Mat4, t: Vec3, r: Quat, s: Vec3) {
        this.pre = pre;
        this.t = t;
        this.r = r;
        this.s = s;
    }
}

// `rest^-1 * parent_rest`, the matrix that turns a joint's local node
// transform into the bone's pose basis, plus the node's static TRS the
// animated component is dropped into. For a skin whose joint frames are
// carried over (import_skins.as), the basis of a joint posed at `local` is
// `rest^-1 * parent_bind * local * bind^-1 * rest`: the parent's bind
// stands for its rest, and the joint's frame is carried over to its bone's.
function boneSpace(scene: Scene, armId: u32, bone: string, doc: Root, node: i32, skin: SkinInfo, joint: i32,
    names: Array<string>): BoneSpace? {
    const arm = scene.objects.at(armId).armature();
    if (arm == null) return null;
    const id = arm.find(bone);
    if (id == NO_BONE) return null;
    const b = arm.bones.at(id);
    const rest = b.restMatrix();
    let parent = MAT4_IDENTITY;
    const carried = skin.corrected && joint < skin.armBind.length;
    if (b.parent != NO_BONE) {
        parent = arm.bones.at(b.parent).restMatrix();
        if (carried) {
            const pj = names.indexOf(arm.bones.at(b.parent).name);
            if (pj >= 0 && pj < skin.armBind.length) parent = skin.armBind[pj];
        }
    }
    const d = nodeTransform(doc.nodes[node]).decomposed();
    const out = new BoneSpace(
        rest.inverse() * parent,
        Vec3(d.translation[0], d.translation[1], d.translation[2]),
        Quat.fromXyzw(d.rotation[0], d.rotation[1], d.rotation[2], d.rotation[3]).normalize(),
        Vec3(d.scale[0], d.scale[1], d.scale[2]),
    );
    if (carried) {
        out.carried = true;
        out.post = skin.armBind[joint].inverse() * rest;
    }
    return out;
}

// The node's local matrix with one component replaced by a sample.
function localWith(base: BoneSpace, property: Property, v: Float32Array): Mat4 {
    let t = base.t;
    let r = base.r;
    let s = base.s;
    if (property == Property.Translation) {
        t = Vec3(v[0], v[1], v[2]);
    } else if (property == Property.Rotation) {
        r = Quat.fromXyzw(v[0], v[1], v[2], v[3]);
        r = r.lengthSquared() > <f32>1e-12 ? r.normalize() : QUAT_IDENTITY;
    } else {
        s = Vec3(v[0], v[1], v[2]);
    }
    return Mat4.fromScaleRotationTranslation(s, r, t);
}

// The pose channel the property writes, out of a bone basis matrix.
function basisComponent(basis: Mat4, property: Property): Array<f32> {
    const srt = basis.toScaleRotationTranslation();
    if (property == Property.Translation) {
        const t = srt.translation;
        return [t.x, t.y, t.z];
    }
    if (property == Property.Rotation) {
        const r = srt.rotation.normalize();
        return [r.w, r.x, r.y, r.z];
    }
    const s = srt.scale;
    return [s.x, s.y, s.z];
}

// A scale vector through the axis conversion: the conversion is a signed
// permutation, so this only reorders the components (and is linear, which
// a component-wise `abs` would not be).
export function permutedScale(conv: Mat4, s: Vec3): Vec3 {
    const c = Mat3.fromMat4(conv);
    const m = c.inverse() * Mat3.fromDiagonal(s) * c;
    return Vec3(m.xAxis.x, m.yAxis.y, m.zAxis.z);
}

// Write one channel's keys into the action's curves.
function emit(action: Action, paths: Array<PathIndex>, keys: Array<Key>, interp: Interpolation, fps: f32): void {
    for (let comp = 0; comp < paths.length; comp++) {
        const fc = action.ensure(paths[comp].path, paths[comp].index);
        for (let k = 0; k < keys.length; k++) {
            const key = keys[k];
            if (comp < key.value.length) {
                fc.insert(key.frame, key.value[comp]);
            }
        }
        // Interpolation and handles after every insert: inserting
        // recalculates the auto handles of the neighbours.
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i];
            const pos = fc.keyAt(k.frame);
            if (pos < 0) continue;
            if (comp >= k.value.length) continue;
            const value = k.value[comp];
            const kf = fc.keyframes[pos];
            kf.interpolation = interp;
            const ta = k.inTangent;
            const tb = k.outTangent;
            if (ta == null || tb == null) continue;
            if (comp >= ta.length || comp >= tb.length) continue;
            const a = ta[comp];
            const b = tb[comp];
            // Hermite to Bezier: the handle sits a third of the segment
            // away, along the tangent (per second, hence the fps).
            const prev = maxF32(i > 0 ? k.frame - keys[i - 1].frame : <f32>1.0, <f32>1e-3) / <f32>3.0;
            const next = maxF32(i + 1 < keys.length ? keys[i + 1].frame - k.frame : <f32>1.0, <f32>1e-3) / <f32>3.0;
            kf.handleType = HandleType.Free;
            kf.handleLeft = Vec2(k.frame - prev, value - a / fps * prev);
            kf.handleRight = Vec2(k.frame + next, value + b / fps * next);
        }
    }
}
