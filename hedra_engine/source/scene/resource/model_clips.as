// A model's animations as clips, read for a scene (docs/plans/RIVE_MODEL.md
// section 3.7; docs/formats/IMPORT.md, "Skins, blend shapes and
// animations"): what model.as hands the engine in ModelResource.clips, one
// ModelClip per glTF animation or per .rmdl (and .modeler) action, its
// tracks keyed in Rive's terms on the model's objects
// (engine/src/scene/skeleton/model_skin.as; engine/src/scene/skeleton/
// clips.as places them in a scene).
//
// Frames. A clip's key times snap to the first rate of CLIP_GRID_RATES on
// whose grid they all lie within 0.1 ms (clipGridFps); when none fits, the
// clip is exact: fps CLIP_EXACT_FPS, keys on the nearest millisecond.
//
// glTF (readGltfClips) is read from the document itself, so that the
// file's numbers are keyed as they are:
//
// - a joint's channels key its bone (`bones/<bone>:position:x`,
//   `bones/<bone>:quaternion`, `bones/<bone>:scale:x`), a node's its
//   object's `position:x`, `quaternion` and `scale:x`, a mesh's weights its
//   `blend_shapes/<name>`;
// - STEP holds; LINEAR is linear (a rotation's slerp, which glTF's is);
//   CUBICSPLINE translation, scale and weights become per segment the
//   cubic Bezier the Hermite tangents make, exactly: a CubicEaseInterpolator
//   normalised over the segment (x1 = 1/3, x2 = 2/3, so the time is linear
//   in the curve's parameter as glTF's is) when the value moves, else a
//   CubicValueInterpolator through the control values;
// - a CUBICSPLINE rotation is a cubic per component, normalised, which no
//   slerp reproduces: it is baked to one linear key a frame of the clip's
//   grid (60 a second for an exact clip), with the warning `clip-baked`.
//
// When a joint or node's place in the model is not its node's transform (a
// node between two joints folded into the bone, an object under a bone),
// its channels are evaluated as glTF's sampler does at each frame and
// baked, so the pose is still the file's at every frame.
//
// .rmdl and .modeler (readSceneClips) take their clips from the scene's
// actions, evaluated by the model kernel itself at every frame of the
// action's range (constraints, inherit flags and shape key sliders as
// Hedra draws them). A track that one F-curve gives exactly (a shape
// key's value; a location or scale component the bone's or object's rest
// only offsets) keeps that curve's keys and interpolation: constant holds,
// linear is linear, a Bezier segment (its handles corrected as Blender's
// correct_bezpart does) is the same normalised cubic, elastic is Rive's
// ElasticInterpolator, and an easing one cubic matches within
// CLIP_FIT_TOLERANCE is that cubic. Every candidate is checked against the
// kernel's value at every frame and against the curve inside each segment;
// what fails, and every bone or object rotation (Blender interpolates
// quaternions and Euler angles per component, which no slerp equals), is
// baked: one linear key a frame, the keys a straight line or a slerp gives
// back left out. Clip frame 0 is the action's first frame.

import { Mat4, Quat, Vec3, MAT4_IDENTITY } from "../../../base/vecmath";
import { displayF32 } from "../../../base/fmt";
import { parseF64 } from "../../../base/parse";
import { Root, Interpolation as GltfInterpolation, Property, unwrapChecked } from "../../io/gltf/doc";
import { ChannelReader, nodeTransform } from "../../io/gltf/reader";
import { mat4FromCols } from "../../io/gltf_to_model/import_skins";
import { GltfImportMap } from "../../io/gltf_to_model/gltf_import";
import { NO_OBJ, Scene } from "../../model/scene";
import { AnimData } from "../../model/anim/mod";
import { FCurve, Interpolation as BlendInterp, segment } from "../../model/anim/fcurve";
import { Channel, DataPath, DataPathKind } from "../../model/anim/path";
import { NO_BONE } from "../../model/armature/mod";
import { MODEL_TO_SCENE, modelMatrixToScene } from "../../../scene/space";
import { ModelResource } from "../../../scene/resource/types";
import {
    ELASTIC_EASE_IN, ELASTIC_EASE_IN_OUT, ELASTIC_EASE_OUT, InterpolationType, InterpolatorDecl, InterpolatorKind, KeyFrameDecl,
    KeyFrameKind, KeyedPropertyDecl,
} from "../../../scene/anim/decl";
import { Interpolator } from "../../../scene/anim/interp";
import {
    CLIP_BAKED, CLIP_BAKE_EXACT_FPS, CLIP_CHANNEL_UNSUPPORTED, CLIP_EXACT_FPS, CLIP_FIT_TOLERANCE, ModelClip, ModelClipTrack,
    ModelSkeleton, clipGridFps,
} from "../../../scene/skeleton/model_skin";
import { BONE_FIELD_POSITION, BONE_FIELD_QUATERNION, BONE_FIELD_SCALE, blendShapeProperty, boneProperty } from "../../../scene/skeleton/names";
import { ModelReading, gltfToScene, objectSceneLocal, poseOf } from "./model_skeleton";

const AXES: StaticArray<string> = ["x", "y", "z"];

// The largest difference, in the property's units, a key left out of a
// baked track may make from the line (or slerp) its neighbours give.
const BAKE_SIMPLIFY: f64 = 1e-6;

// A matrix within `eps` an entry of the identity.
function nearIdentity(m: Mat4, eps: f32): bool {
    const a = m.toColsArray();
    for (let i = 0; i < 16; i++) {
        const want: f32 = i % 5 == 0 ? 1 : 0;
        if (Mathf.abs(a[i] - want) > eps) return false;
    }
    return true;
}

// The frame of `seconds` on a clip of `fps` (an exact clip's milliseconds).
function frameOf(seconds: f64, fps: i32): i32 {
    return <i32>Math.round(seconds * <f64>fps);
}

// `x` as the shortest decimal of the f32 it is (the engine evaluates keys
// in f32: the same number, and a scene made from the clip by Make Editable
// writes 1.03 rather than 1.0299999713897705).
function tidy(x: f64): f64 {
    const f = <f32>x;
    if (f == 0) return 0;
    if (!isFinite(f)) return x;
    const r = parseF64(displayF32(f));
    return r.ok ? r.value : x;
}

// An interpolator's numbers made tidy.
function tidyInterpolator(ip: InterpolatorDecl): void {
    ip.x1 = tidy(ip.x1);
    ip.y1 = tidy(ip.y1);
    ip.x2 = tidy(ip.x2);
    ip.y2 = tidy(ip.y2);
    ip.amplitude = tidy(ip.amplitude);
    ip.period = tidy(ip.period);
}

function doubleKey(frame: i32, value: f64, interp: InterpolationType): KeyFrameDecl {
    const k = new KeyFrameDecl(KeyFrameKind.Double, frame);
    k.number = tidy(value);
    k.interpolation = interp;
    return k;
}

function quatKey(frame: i32, q: Quat, interp: InterpolationType): KeyFrameDecl {
    const k = new KeyFrameDecl(KeyFrameKind.Quaternion, frame);
    k.qx = tidy(<f64>q.x);
    k.qy = tidy(<f64>q.y);
    k.qz = tidy(<f64>q.z);
    k.qw = tidy(<f64>q.w);
    k.interpolation = interp;
    return k;
}

// Keys of one frame keep the later (two key times rounding to one frame).
function pushKey(keys: Array<KeyFrameDecl>, k: KeyFrameDecl): void {
    const ip = k.interpolator;
    if (ip != null) tidyInterpolator(ip);
    const n = keys.length;
    if (n > 0 && keys[n - 1].frame == k.frame) keys[n - 1] = k;
    else keys.push(k);
}

// The cubic segment from `v0` to `v1` whose Bezier control values are `p1`
// and `p2` (x at 1/3 and 2/3: time linear in the parameter), on key `k`:
// a normalised CubicEaseInterpolator when the value moves, else a
// CubicValueInterpolator through the values (both exact), linear when the
// controls sit on the line.
function setCubic(k: KeyFrameDecl, v0: f64, v1: f64, p1: f64, p2: f64): void {
    const d = v1 - v0;
    const scale = Math.max(1.0, Math.max(Math.abs(v0), Math.abs(v1)));
    if (Math.abs(p1 - (v0 + d / 3)) <= 1e-9 * scale && Math.abs(p2 - (v0 + 2 * d / 3)) <= 1e-9 * scale) {
        k.interpolation = InterpolationType.Linear;
        return;
    }
    if (Math.abs(d) > 1e-9 * scale) {
        const ip = new InterpolatorDecl(InterpolatorKind.CubicEase);
        ip.x1 = 1.0 / 3.0;
        ip.y1 = (p1 - v0) / d;
        ip.x2 = 2.0 / 3.0;
        ip.y2 = (p2 - v0) / d;
        k.interpolation = InterpolationType.Cubic;
        k.interpolator = ip;
    } else {
        const ip = new InterpolatorDecl(InterpolatorKind.CubicValue);
        ip.x1 = 1.0 / 3.0;
        ip.y1 = p1;
        ip.x2 = 2.0 / 3.0;
        ip.y2 = p2;
        k.interpolation = InterpolationType.CubicValue;
        k.interpolator = ip;
    }
}

// `values` (one per frame of `frames`) as linear keys, those a straight
// line between their neighbours gives back within BAKE_SIMPLIFY left out.
function bakedDoubles(frames: Array<i32>, values: Array<f64>): Array<KeyFrameDecl> {
    const keep = new Array<bool>(frames.length);
    for (let i = 0; i < frames.length; i++) keep[i] = true;
    let last = 0;
    for (let i = 1; i + 1 < frames.length; i++) {
        const f0 = <f64>frames[last];
        const f2 = <f64>frames[i + 1];
        const t = (<f64>frames[i] - f0) / (f2 - f0);
        const line = values[last] + (values[i + 1] - values[last]) * t;
        // (every key skipped since `last` must stay on the new line too)
        let fits = Math.abs(line - values[i]) <= BAKE_SIMPLIFY;
        for (let j = last + 1; j < i && fits; j++) {
            const tj = (<f64>frames[j] - f0) / (f2 - f0);
            if (Math.abs(values[last] + (values[i + 1] - values[last]) * tj - values[j]) > BAKE_SIMPLIFY) fits = false;
        }
        if (fits) keep[i] = false;
        else last = i;
    }
    const out = new Array<KeyFrameDecl>();
    for (let i = 0; i < frames.length; i++) if (keep[i]) out.push(doubleKey(frames[i], values[i], InterpolationType.Linear));
    if (out.length > 1 && allSame(values)) out.length = 1;
    return out;
}

function allSame(values: Array<f64>): bool {
    for (let i = 1; i < values.length; i++) if (Math.abs(values[i] - values[0]) > BAKE_SIMPLIFY) return false;
    return true;
}

function quatClose(a: Quat, b: Quat): bool {
    // (q and -q are one rotation)
    const s: f32 = a.dot(b) < 0 ? -1 : 1;
    return Math.abs(<f64>(a.x - b.x * s)) <= BAKE_SIMPLIFY * 4 && Math.abs(<f64>(a.y - b.y * s)) <= BAKE_SIMPLIFY * 4
        && Math.abs(<f64>(a.z - b.z * s)) <= BAKE_SIMPLIFY * 4 && Math.abs(<f64>(a.w - b.w * s)) <= BAKE_SIMPLIFY * 4;
}

// `qs` as linear quaternion keys (slerped), those a slerp between their
// neighbours gives back left out.
function bakedQuats(frames: Array<i32>, qs: Array<Quat>): Array<KeyFrameDecl> {
    const keep = new Array<bool>(frames.length);
    for (let i = 0; i < frames.length; i++) keep[i] = true;
    let last = 0;
    for (let i = 1; i + 1 < frames.length; i++) {
        const f0 = <f64>frames[last];
        const f2 = <f64>frames[i + 1];
        let fits = true;
        for (let j = last + 1; j <= i && fits; j++) {
            const t = <f32>((<f64>frames[j] - f0) / (f2 - f0));
            if (!quatClose(qs[last].slerp(qs[i + 1], t), qs[j])) fits = false;
        }
        if (fits) keep[i] = false;
        else last = i;
    }
    const out = new Array<KeyFrameDecl>();
    for (let i = 0; i < frames.length; i++) if (keep[i]) out.push(quatKey(frames[i], qs[i], InterpolationType.Linear));
    let same = true;
    for (let i = 1; i < qs.length && same; i++) if (!quatClose(qs[i], qs[0])) same = false;
    if (out.length > 1 && same) out.length = 1;
    return out;
}

function track(object: i32, property: string, keys: Array<KeyFrameDecl>): ModelClipTrack {
    const p = new KeyedPropertyDecl(property);
    p.keys = keys;
    return new ModelClipTrack(object, p);
}

// --- glTF ----------------------------------------------------------------------

const GLTF_STEP: i32 = 0;
const GLTF_LINEAR: i32 = 1;
const GLTF_CUBIC: i32 = 2;

// One channel of a glTF animation, read out: its key times (seconds), and
// per key its value and, for a cubic sampler, its in and out tangents
// (`comps` numbers each).
export class GltfChannel {
    node: i32 = -1;
    property: Property = Property.Translation;
    interp: i32 = GLTF_LINEAR;
    comps: i32 = 3;
    times: Array<f64> = [];
    values: Array<Array<f64>> = [];
    inTangents: Array<Array<f64>> = [];
    outTangents: Array<Array<f64>> = [];

    // The value glTF's sampler gives at `t` seconds (a rotation slerped, a
    // cubic one normalised; before the first key the first, after the last
    // the last).
    sample(t: f64): Array<f64> {
        const n = this.times.length;
        if (t <= this.times[0] || n == 1) return this.values[0].slice(0);
        if (t >= this.times[n - 1]) return this.values[n - 1].slice(0);
        let k = 0;
        while (k + 1 < n && this.times[k + 1] <= t) k++;
        if (this.times[k] == t || this.interp == GLTF_STEP) return this.values[k].slice(0);
        const t0 = this.times[k];
        const dt = this.times[k + 1] - t0;
        const s = (t - t0) / dt;
        const a = this.values[k];
        const b = this.values[k + 1];
        const out = new Array<f64>(this.comps);
        if (this.interp == GLTF_LINEAR) {
            if (this.property == Property.Rotation) {
                const q = Quat(<f32>a[0], <f32>a[1], <f32>a[2], <f32>a[3]).slerp(Quat(<f32>b[0], <f32>b[1], <f32>b[2], <f32>b[3]), <f32>s);
                out[0] = q.x;
                out[1] = q.y;
                out[2] = q.z;
                out[3] = q.w;
                return out;
            }
            for (let c = 0; c < this.comps; c++) out[c] = a[c] + (b[c] - a[c]) * s;
            return out;
        }
        const s2 = s * s;
        const s3 = s2 * s;
        const h00 = 2 * s3 - 3 * s2 + 1;
        const h10 = s3 - 2 * s2 + s;
        const h01 = -2 * s3 + 3 * s2;
        const h11 = s3 - s2;
        const m0 = this.outTangents[k];
        const m1 = this.inTangents[k + 1];
        for (let c = 0; c < this.comps; c++) out[c] = h00 * a[c] + h10 * dt * m0[c] + h01 * b[c] + h11 * dt * m1[c];
        if (this.property == Property.Rotation) {
            const len = Math.sqrt(out[0] * out[0] + out[1] * out[1] + out[2] * out[2] + out[3] * out[3]);
            if (len > 1e-12) for (let c = 0; c < 4; c++) out[c] /= len;
        }
        return out;
    }
}

// Channel `ci` of animation `ai`, read; null when it cannot be read.
export function readGltfChannel(doc: Root, buffers: Array<Uint8Array>, ai: i32, ci: i32): GltfChannel? {
    const anim = doc.animations[ai];
    const ch = anim.channels[ci];
    if (ch.sampler < 0 || ch.sampler >= anim.samplers.length) return null;
    const node = ch.target.node;
    if (node < 0 || node >= doc.nodes.length) return null;
    const reader = new ChannelReader(doc, ai, ci, buffers);
    const inputs = reader.readInputs();
    if (inputs == null || inputs.length == 0) return null;
    const outputs = reader.readOutputs();
    if (outputs == null) return null;
    const out = new GltfChannel();
    out.node = node;
    out.property = outputs.property;
    const gi = <GltfInterpolation>unwrapChecked(anim.samplers[ch.sampler].interpolation);
    out.interp = gi == GltfInterpolation.Step ? GLTF_STEP : gi == GltfInterpolation.CubicSpline ? GLTF_CUBIC : GLTF_LINEAR;
    const all = outputs.intoF32();
    const n = inputs.length;
    const perKey = out.interp == GLTF_CUBIC ? 3 : 1;
    let comps: i32;
    if (out.property == Property.MorphTargetWeights) {
        if (all.length % (n * perKey) != 0) return null;
        comps = all.length / (n * perKey);
    } else {
        comps = out.property == Property.Rotation ? 4 : 3;
    }
    if (comps <= 0 || all.length < n * perKey * comps) return null;
    out.comps = comps;
    for (let i = 0; i < n; i++) {
        out.times.push(<f64>inputs[i]);
        if (i > 0 && !(out.times[i] >= out.times[i - 1])) return null;
        for (let part = 0; part < perKey; part++) {
            const at = (i * perKey + part) * comps;
            const v = new Array<f64>(comps);
            for (let c = 0; c < comps; c++) v[c] = <f64>all[at + c];
            if (perKey == 1) out.values.push(v);
            else if (part == 0) out.inTangents.push(v);
            else if (part == 1) out.values.push(v);
            else out.outTangents.push(v);
        }
    }
    return out;
}

// How a node's channels land on the model: the object (a ModelObject
// index), the property prefix ("bones/Hips:" or ""), and `fix`, what the
// object's or bone's own transform is beside the node's (`fix * S(node)`;
// the identity when they are one, as for most files).
class GltfTarget {
    object: i32 = -1;
    bone: string = "";
    fix: Mat4 = MAT4_IDENTITY;
    direct: bool = true;
    // The node's own TRS at rest (glTF space), for the channels it lacks.
    t: Vec3 = Vec3(0, 0, 0);
    r: Quat = Quat(0, 0, 0, 1);
    s: Vec3 = Vec3(1, 1, 1);

    property(field: string, axis: i32): string {
        if (this.bone.length > 0) return boneProperty(this.bone, field, axis);
        return axis >= 0 ? field + ":" + AXES[axis] : field;
    }
}

// The scene-space rotation of the file-to-scene conjugation (its linear
// part), the same for every node of a file.
class GltfFrame {
    c: Mat4;
    qc: Quat;
    scale: f32;

    constructor(map: GltfImportMap) {
        this.c = MODEL_TO_SCENE * map.conv.inverse();
        this.qc = Quat.fromMat4(this.c).normalize();
        this.scale = map.scale;
    }

    // A translation (or its tangent) in scene space.
    translation(v: Array<f64>): Vec3 {
        return this.c.transformVector3(Vec3(<f32>v[0], <f32>v[1], <f32>v[2])) * this.scale;
    }

    rotation(v: Array<f64>): Quat {
        return this.qc * Quat(<f32>v[0], <f32>v[1], <f32>v[2], <f32>v[3]) * this.qc.inverse();
    }

    // A scale (or its tangent): the conjugation permutes the axes.
    scaleOf(v: Array<f64>): Vec3 {
        const x = this.c.transformVector3(Vec3(<f32>v[0], 0, 0));
        const y = this.c.transformVector3(Vec3(0, <f32>v[1], 0));
        const z = this.c.transformVector3(Vec3(0, 0, <f32>v[2]));
        const s = x + y + z;
        const sx = this.c.transformVector3(Vec3(1, 0, 0));
        const sy = this.c.transformVector3(Vec3(0, 1, 0));
        const sz = this.c.transformVector3(Vec3(0, 0, 1));
        // (signs of a signed permutation dropped: a scale's axis has none)
        const sign = sx + sy + sz;
        return Vec3(s.x * (sign.x < 0 ? -1 : 1), s.y * (sign.y < 0 ? -1 : 1), s.z * (sign.z < 0 ? -1 : 1));
    }
}

// Where node `ni`'s channels land: one target per skeleton the node is a
// joint of (skins sharing a hierarchy, one skin per mesh as many exporters
// write them, each make a Skeleton3D, and each must follow the clip), else
// its object's; empty (with the reason in `why`) when it lands nowhere.
function gltfTargets(r: ModelReading, m: ModelResource, map: GltfImportMap, ni: i32, why: Array<string>): Array<GltfTarget> {
    const out = new Array<GltfTarget>();
    const skins = map.skins.skins;
    let joint = false;
    for (let si = 0; si < skins.length; si++) {
        if (!skins[si].jointOfNode.has(ni)) continue;
        joint = true;
        const tg = gltfTarget(r, m, map, ni, si, skins[si].jointOfNode.get(ni), why);
        if (tg == null) continue;
        // (two skins made into one armature object: one track is enough)
        let seen = false;
        for (let k = 0; k < out.length; k++) if (out[k].object == tg.object) seen = true;
        if (!seen) out.push(tg);
    }
    if (!joint) {
        const tg = gltfTarget(r, m, map, ni, -1, -1, why);
        if (tg != null) out.push(tg);
    }
    return out;
}

// Where node `ni`'s channels land as joint `jointIndex` of skin `si` (-1:
// as a plain node), or null (with the reason in `why`).
function gltfTarget(r: ModelReading, m: ModelResource, map: GltfImportMap, ni: i32, si: i32, jointIndex: i32,
    why: Array<string>): GltfTarget? {
    const out = new GltfTarget();
    const d = nodeTransform(map.document.nodes[ni]).decomposed();
    out.t = Vec3(d.translation[0], d.translation[1], d.translation[2]);
    out.r = Quat(d.rotation[0], d.rotation[1], d.rotation[2], d.rotation[3]).normalize();
    out.s = Vec3(d.scale[0], d.scale[1], d.scale[2]);
    const nodeScene = gltfToScene(map, mat4FromCols(nodeTransform(map.document.nodes[ni]).matrix()));
    if (si >= 0) {
        if (si >= map.armObj.length || si >= map.boneNames.length || jointIndex >= map.boneNames[si].length) {
            why.push("its joint has no bone");
            return null;
        }
        const ai = r.index(map.armObj[si]);
        const sk = ai >= 0 ? m.objects[ai].skeleton : null;
        if (sk == null) {
            why.push("its skin has no skeleton");
            return null;
        }
        const name = map.boneNames[si][jointIndex];
        const b = (sk as ModelSkeleton).boneIndex(name);
        if (b < 0) {
            why.push("bone '" + name + "' is not in the skeleton");
            return null;
        }
        out.object = ai;
        out.bone = name;
        out.fix = (sk as ModelSkeleton).bones[b].rest.matrix() * nodeScene.inverse();
    } else if (map.objOfNode.has(ni)) {
        const id = map.objOfNode.get(ni);
        if (map.skinnedObjs.includes(id)) {
            // glTF ignores a skinned mesh node's transform.
            why.push("it is a skinned mesh's node, whose transform glTF ignores");
            return null;
        }
        const oi = r.index(id);
        if (oi < 0) {
            why.push("its node is no object of the model");
            return null;
        }
        out.object = oi;
        out.fix = m.objects[oi].local * nodeScene.inverse();
    } else {
        why.push("its node is no object of the model");
        return null;
    }
    out.direct = nearIdentity(out.fix, 1e-5);
    return out;
}

// The frames of a clip of `fps` (`duration` long) a baked channel is keyed
// on: every frame of a grid clip, a 60th of a second apart for an exact one,
// plus `times` (the channel's own keys).
function bakeFrames(fps: i32, duration: i32, times: Array<f64>): Array<i32> {
    const set = new Set<i32>();
    if (fps == CLIP_EXACT_FPS) {
        const n = <i32>Math.ceil(<f64>duration * <f64>CLIP_BAKE_EXACT_FPS / <f64>fps);
        for (let i = 0; i <= n; i++) set.add(min(duration, <i32>Math.round(<f64>i * <f64>fps / <f64>CLIP_BAKE_EXACT_FPS)));
    } else {
        for (let f = 0; f <= duration; f++) set.add(f);
    }
    for (let i = 0; i < times.length; i++) set.add(frameOf(times[i], fps));
    const out = set.values();
    out.sort((a: i32, b: i32): i32 => a - b);
    return out;
}

// A direct channel's tracks: one per component, its keys the file's.
function directTracks(ch: GltfChannel, tg: GltfTarget, frame: GltfFrame, fps: i32, out: Array<ModelClipTrack>): void {
    const n = ch.times.length;
    const field = ch.property == Property.Translation ? BONE_FIELD_POSITION : BONE_FIELD_SCALE;
    // Each key's value and tangents in scene space.
    const vals = new Array<Vec3>();
    const ins = new Array<Vec3>();
    const outs = new Array<Vec3>();
    for (let i = 0; i < n; i++) {
        if (ch.property == Property.Translation) {
            vals.push(frame.translation(ch.values[i]));
            if (ch.interp == GLTF_CUBIC) {
                ins.push(frame.translation(ch.inTangents[i]));
                outs.push(frame.translation(ch.outTangents[i]));
            }
        } else {
            vals.push(frame.scaleOf(ch.values[i]));
            if (ch.interp == GLTF_CUBIC) {
                ins.push(frame.scaleOf(ch.inTangents[i]));
                outs.push(frame.scaleOf(ch.outTangents[i]));
            }
        }
    }
    for (let axis = 0; axis < 3; axis++) {
        const keys = new Array<KeyFrameDecl>();
        for (let i = 0; i < n; i++) {
            const v = <f64>vals[i].get(axis);
            const k = doubleKey(frameOf(ch.times[i], fps), v, ch.interp == GLTF_STEP ? InterpolationType.Hold : InterpolationType.Linear);
            if (ch.interp == GLTF_CUBIC && i + 1 < n) {
                const dt = ch.times[i + 1] - ch.times[i];
                const v1 = <f64>vals[i + 1].get(axis);
                setCubic(k, v, v1, v + <f64>outs[i].get(axis) * dt / 3, v1 - <f64>ins[i + 1].get(axis) * dt / 3);
            }
            if (i + 1 == n) {
                k.interpolation = InterpolationType.Hold;
                k.interpolator = null;
            }
            pushKey(keys, k);
        }
        out.push(track(tg.object, tg.property(field, axis), keys));
    }
}

// A rotation channel kept as quaternion keys (STEP and LINEAR).
function directRotation(ch: GltfChannel, tg: GltfTarget, frame: GltfFrame, fps: i32, out: Array<ModelClipTrack>): void {
    const keys = new Array<KeyFrameDecl>();
    const n = ch.times.length;
    for (let i = 0; i < n; i++) {
        const interp = i + 1 == n || ch.interp == GLTF_STEP ? InterpolationType.Hold : InterpolationType.Linear;
        pushKey(keys, quatKey(frameOf(ch.times[i], fps), frame.rotation(ch.values[i]), interp));
    }
    out.push(track(tg.object, tg.property(BONE_FIELD_QUATERNION, -1), keys));
}

// A channel baked: glTF's sampler at each of `frames`, the node's other
// components at rest, through `fix`; the component the channel moves.
function bakedTracks(ch: GltfChannel, tg: GltfTarget, map: GltfImportMap, fps: i32, frames: Array<i32>, out: Array<ModelClipTrack>): void {
    const pos = new Array<Array<f64>>();
    const qs = new Array<Quat>();
    for (let a = 0; a < 3; a++) pos.push(new Array<f64>());
    for (let i = 0; i < frames.length; i++) {
        const v = ch.sample(<f64>frames[i] / <f64>fps);
        let t = tg.t;
        let q = tg.r;
        let s = tg.s;
        if (ch.property == Property.Translation) t = Vec3(<f32>v[0], <f32>v[1], <f32>v[2]);
        else if (ch.property == Property.Rotation) q = Quat(<f32>v[0], <f32>v[1], <f32>v[2], <f32>v[3]).normalize();
        else s = Vec3(<f32>v[0], <f32>v[1], <f32>v[2]);
        const pose = poseOf(tg.fix * gltfToScene(map, Mat4.fromScaleRotationTranslation(s, q, t)));
        if (ch.property == Property.Rotation) {
            // (the sign kept continuous, so that a slerp between two keys
            // takes the way the file's does)
            let pq = pose.rotation;
            if (qs.length > 0 && pq.dot(qs[qs.length - 1]) < 0) pq = -pq;
            qs.push(pq);
        } else {
            const vec = ch.property == Property.Translation ? pose.position : pose.scale;
            for (let a = 0; a < 3; a++) pos[a].push(<f64>vec.get(a));
        }
    }
    if (ch.property == Property.Rotation) {
        out.push(track(tg.object, tg.property(BONE_FIELD_QUATERNION, -1), bakedQuats(frames, qs)));
        return;
    }
    const field = ch.property == Property.Translation ? BONE_FIELD_POSITION : BONE_FIELD_SCALE;
    for (let a = 0; a < 3; a++) out.push(track(tg.object, tg.property(field, a), bakedDoubles(frames, pos[a])));
}

// A weights channel: one `blend_shapes/<name>` track per target the mesh
// object keeps.
function weightTracks(r: ModelReading, m: ModelResource, map: GltfImportMap, ch: GltfChannel, fps: i32, clip: string,
    warnings: Array<string>, out: Array<ModelClipTrack>): void {
    if (!map.objOfNode.has(ch.node)) {
        warnings.push(CLIP_CHANNEL_UNSUPPORTED + ": clip '" + clip + "': a weights channel targets a node that is no mesh; skipped");
        return;
    }
    const id = map.objOfNode.get(ch.node);
    const oi = r.index(id);
    const mesh = r.scene.objects.at(id).mesh();
    if (oi < 0 || mesh == null || mesh.shapeKeys.length < 2) {
        warnings.push(CLIP_CHANNEL_UNSUPPORTED + ": clip '" + clip + "': a weights channel targets a mesh without blend shapes; skipped");
        return;
    }
    const o = m.objects[oi];
    const n = ch.times.length;
    for (let w = 0; w < ch.comps; w++) {
        if (w + 1 >= mesh.shapeKeys.length) break;
        const name = mesh.shapeKeys[w + 1].name;
        if (!o.blendShapes.includes(name)) continue;
        const keys = new Array<KeyFrameDecl>();
        for (let i = 0; i < n; i++) {
            const v = ch.values[i][w];
            const k = doubleKey(frameOf(ch.times[i], fps), v, ch.interp == GLTF_STEP ? InterpolationType.Hold : InterpolationType.Linear);
            if (ch.interp == GLTF_CUBIC && i + 1 < n) {
                const dt = ch.times[i + 1] - ch.times[i];
                const v1 = ch.values[i + 1][w];
                setCubic(k, v, v1, v + ch.outTangents[i][w] * dt / 3, v1 - ch.inTangents[i + 1][w] * dt / 3);
            }
            if (i + 1 == n) {
                k.interpolation = InterpolationType.Hold;
                k.interpolator = null;
            }
            pushKey(keys, k);
        }
        out.push(track(oi, blendShapeProperty(name), keys));
    }
}

// Fills `m.clips` from the glTF document a model was read from (r.gltf):
// one clip per animation, in the file's order (see the header).
export function readGltfClips(r: ModelReading, m: ModelResource): void {
    const map = r.gltf as GltfImportMap;
    const doc = map.document;
    const frame = new GltfFrame(map);
    for (let ai = 0; ai < doc.animations.length; ai++) {
        const anim = doc.animations[ai];
        const an = anim.name;
        const name = an != null && an.length > 0 ? an : "Animation_" + ai.toString();
        const channels = new Array<GltfChannel>();
        const times = new Array<f64>();
        for (let ci = 0; ci < anim.channels.length; ci++) {
            const ch = readGltfChannel(doc, map.buffers, ai, ci);
            if (ch == null) {
                m.warnings.push(CLIP_CHANNEL_UNSUPPORTED + ": clip '" + name + "': channel " + ci.toString() + " cannot be read; skipped");
                continue;
            }
            channels.push(ch);
            for (let i = 0; i < ch.times.length; i++) times.push(ch.times[i]);
        }
        if (channels.length == 0) continue;
        const clip = new ModelClip();
        clip.name = name;
        clip.fps = clipGridFps(times);
        clip.exact = clip.fps == CLIP_EXACT_FPS;
        let last = 0;
        for (let i = 0; i < times.length; i++) last = max(last, frameOf(times[i], clip.fps));
        clip.duration = max(1, last);
        let baked = 0;
        const targets = new Map<i32, Array<GltfTarget>>();
        for (let c = 0; c < channels.length; c++) {
            const ch = channels[c];
            if (ch.property == Property.MorphTargetWeights) {
                weightTracks(r, m, map, ch, clip.fps, name, m.warnings, clip.tracks);
                continue;
            }
            if (!targets.has(ch.node)) {
                const why = new Array<string>();
                const tg = gltfTargets(r, m, map, ch.node, why);
                targets.set(ch.node, tg);
                if (tg.length == 0) {
                    m.warnings.push(CLIP_CHANNEL_UNSUPPORTED + ": clip '" + name + "': the channels of node " + ch.node.toString()
                        + " are skipped: " + (why.length > 0 ? why[0] : "it is no part of the model"));
                }
            }
            const tgs = targets.get(ch.node);
            if (tgs.length > 0 && tgs[0].direct && ch.property == Property.Rotation && ch.interp == GLTF_CUBIC) baked++;
            for (let t = 0; t < tgs.length; t++) {
                const tg = tgs[t];
                if (!tg.direct) {
                    bakedTracks(ch, tg, map, clip.fps, bakeFrames(clip.fps, clip.duration, ch.times), clip.tracks);
                    continue;
                }
                if (ch.property == Property.Rotation) {
                    if (ch.interp == GLTF_CUBIC) {
                        bakedTracks(ch, tg, map, clip.fps, bakeFrames(clip.fps, clip.duration, ch.times), clip.tracks);
                    } else {
                        directRotation(ch, tg, frame, clip.fps, clip.tracks);
                    }
                } else {
                    directTracks(ch, tg, frame, clip.fps, clip.tracks);
                }
            }
        }
        if (baked > 0) {
            const rate = clip.exact ? CLIP_BAKE_EXACT_FPS : clip.fps;
            m.warnings.push(CLIP_BAKED + ": clip '" + name + "': " + baked.toString() + " cubic spline rotation(s) baked to one key a frame at "
                + rate.toString() + " fps (a slerp cannot follow glTF's per-component spline)");
        }
        if (clip.tracks.length > 0) m.clips.push(clip);
    }
}

// --- .rmdl and .modeler: actions -------------------------------------------------

// One scalar the clip tracks: per frame its value, and the F-curves whose
// keys may stand for it (an affine image of one of them).
class SceneTrack {
    object: i32;
    property: string;
    values: Array<f64> = [];
    candidates: Array<FCurve> = [];
    // Whether its keys are one F-curve's (sceneTrackKeys), not baked.
    fromCurve: bool = false;

    constructor(object: i32, property: string) {
        this.object = object;
        this.property = property;
    }
}

class SceneQuatTrack {
    object: i32;
    property: string;
    values: Array<Quat> = [];

    constructor(object: i32, property: string) {
        this.object = object;
        this.property = property;
    }
}

// What an action keys on one object: its object channels, its bones (each
// with the channels keyed), its shape keys.
class KeyedOn {
    id: u32;
    index: i32;
    location: Array<FCurve> = [];
    rotation: bool = false;
    scale: Array<FCurve> = [];
    bones: Array<string> = [];
    boneLocation: Array<Array<FCurve>> = [];
    boneRotation: Array<bool> = [];
    boneScale: Array<Array<FCurve>> = [];
    shapeKeys: Array<string> = [];
    shapeCurves: Array<FCurve> = [];

    constructor(id: u32, index: i32) {
        this.id = id;
        this.index = index;
    }

    bone(name: string): i32 {
        let b = this.bones.indexOf(name);
        if (b >= 0) return b;
        this.bones.push(name);
        this.boneLocation.push([]);
        this.boneRotation.push(false);
        this.boneScale.push([]);
        return this.bones.length - 1;
    }
}

// Rive's value at fraction `t` of a segment from `v0` to `v1` keyed by `k`.
function riveSegment(k: KeyFrameDecl, v0: f64, v1: f64, t: f64): f64 {
    if (k.interpolation == InterpolationType.Hold) return v0;
    const ip = k.interpolator;
    if (ip == null) return v0 + (v1 - v0) * t;
    return <f64>new Interpolator(ip).transformValue(<f32>v0, <f32>v1, <f32>t);
}

// The interpolation of the segment from `a` to `b` of `fc` on key `k` as
// Rive keys it, mapped by `v -> scale * v + offset`; false when none
// matches within CLIP_FIT_TOLERANCE.
function segmentKey(k: KeyFrameDecl, a: i32, b: i32, fc: FCurve, scale: f64, offset: f64): bool {
    const ka = fc.keyframes[a];
    const kb = fc.keyframes[b];
    const v0 = <f64>ka.value * scale + offset;
    const v1 = <f64>kb.value * scale + offset;
    const ipo = ka.interpolation;
    if (ipo == BlendInterp.Constant) {
        k.interpolation = InterpolationType.Hold;
    } else if (ipo == BlendInterp.Linear) {
        k.interpolation = InterpolationType.Linear;
    } else if (ipo == BlendInterp.Bezier) {
        // correct_bezpart, as fcurve.as's segment applies it.
        const p1 = ka.point();
        let h1 = ka.handleRight;
        let h2 = kb.handleLeft;
        const p2 = kb.point();
        const d1 = p1 - h1;
        const d2 = p2 - h2;
        const len = p2.x - p1.x;
        const l1 = Mathf.abs(d1.x);
        const l2 = Mathf.abs(d2.x);
        if (l1 + l2 != 0 && l1 + l2 > len) {
            const fac = len / (l1 + l2);
            h1 = p1 - d1 * fac;
            h2 = p2 - d2 * fac;
        }
        const ip = new InterpolatorDecl(InterpolatorKind.CubicEase);
        ip.x1 = (<f64>h1.x - <f64>p1.x) / <f64>len;
        ip.x2 = (<f64>h2.x - <f64>p1.x) / <f64>len;
        const y1 = <f64>h1.y * scale + offset;
        const y2 = <f64>h2.y * scale + offset;
        const d = v1 - v0;
        if (Math.abs(d) > 1e-9) {
            ip.y1 = (y1 - v0) / d;
            ip.y2 = (y2 - v0) / d;
            k.interpolation = InterpolationType.Cubic;
        } else {
            ip.kind = InterpolatorKind.CubicValue;
            ip.y1 = y1;
            ip.y2 = y2;
            k.interpolation = InterpolationType.CubicValue;
        }
        k.interpolator = ip;
    } else if (ipo == BlendInterp.Elastic) {
        const ip = new InterpolatorDecl(InterpolatorKind.Elastic);
        const e = ka.easing;
        // (Blender's Auto is ease out for elastic)
        ip.easingValue = e == 1 ? ELASTIC_EASE_IN : e == 3 ? ELASTIC_EASE_IN_OUT : ELASTIC_EASE_OUT;
        // Blender's elastic is in the segment's own units: its period in
        // frames (0: 0.3 of the segment), its amplitude in the value's (0,
        // or under the change: the change itself). Rive's is normalised: a
        // period in parts of the segment, an amplitude in parts of the
        // change (easing.as against interp.as's ElasticEase). The fit check
        // below still decides (a falling segment with an amplitude over its
        // change shifts its phase the other way, and is baked).
        const span = <f64>kb.frame - <f64>ka.frame;
        const change = Math.abs(<f64>kb.value - <f64>ka.value);
        ip.period = ka.period == 0 || !(span > 0) ? 0.3 : <f64>ka.period / span;
        ip.amplitude = ka.amplitude == 0 || <f64>ka.amplitude < change || change == 0 ? 1.0 : <f64>ka.amplitude / change;
        k.interpolation = InterpolationType.Elastic;
        k.interpolator = ip;
    } else {
        // One cubic with x linear in time: y1 and y2 by least squares.
        fitCubic(k, fc, a, b, scale, offset);
    }
    return segmentFits(k, fc, a, b, scale, offset);
}

// Whether key `k` reproduces `fc` from key `a` to `b` within
// CLIP_FIT_TOLERANCE at 16 points inside the segment.
function segmentFits(k: KeyFrameDecl, fc: FCurve, a: i32, b: i32, scale: f64, offset: f64): bool {
    const ka = fc.keyframes[a];
    const kb = fc.keyframes[b];
    const v0 = <f64>ka.value * scale + offset;
    const v1 = <f64>kb.value * scale + offset;
    const span = <f64>kb.frame - <f64>ka.frame;
    for (let i = 1; i < 16; i++) {
        const t = <f64>i / 16;
        const want = <f64>segment(ka, kb, <f32>(<f64>ka.frame + span * t)) * scale + offset;
        // (a NaN, from a degenerate segment, never fits)
        if (!(Math.abs(riveSegment(k, v0, v1, t) - want) <= CLIP_FIT_TOLERANCE)) return false;
    }
    return true;
}

// The cubic (x1 = 1/3, x2 = 2/3) nearest an easing segment, by least
// squares over 32 points.
function fitCubic(k: KeyFrameDecl, fc: FCurve, a: i32, b: i32, scale: f64, offset: f64): void {
    const ka = fc.keyframes[a];
    const kb = fc.keyframes[b];
    const v0 = <f64>ka.value * scale + offset;
    const v1 = <f64>kb.value * scale + offset;
    const d = v1 - v0;
    if (Math.abs(d) <= 1e-9) {
        k.interpolation = InterpolationType.Linear;
        return;
    }
    const span = <f64>kb.frame - <f64>ka.frame;
    // y(t) = A t y1 + B t y2 + t^3, A = 3(1-t)^2, B = 3(1-t)t (t factored).
    let saa = 0.0, sab = 0.0, sbb = 0.0, sar = 0.0, sbr = 0.0;
    for (let i = 1; i < 32; i++) {
        const t = <f64>i / 32;
        const y = (<f64>segment(ka, kb, <f32>(<f64>ka.frame + span * t)) * scale + offset - v0) / d;
        const u = 1 - t;
        const ca = 3 * u * u * t;
        const cb = 3 * u * t * t;
        const rest = y - t * t * t;
        saa += ca * ca;
        sab += ca * cb;
        sbb += cb * cb;
        sar += ca * rest;
        sbr += cb * rest;
    }
    const det = saa * sbb - sab * sab;
    const ip = new InterpolatorDecl(InterpolatorKind.CubicEase);
    ip.x1 = 1.0 / 3.0;
    ip.x2 = 2.0 / 3.0;
    ip.y1 = det != 0 ? (sar * sbb - sbr * sab) / det : 1.0 / 3.0;
    ip.y2 = det != 0 ? (sbr * saa - sar * sab) / det : 2.0 / 3.0;
    k.interpolation = InterpolationType.Cubic;
    k.interpolator = ip;
}

// `fc`'s keys as a clip's (frame 0 = Blender frame `lo`), mapped by `v ->
// scale * v + offset`; null when a key is off the frame grid, outside the
// clip, or a segment matches no interpolator (the track is baked).
function fcurveKeys(fc: FCurve, lo: i32, duration: i32, scale: f64, offset: f64): Array<KeyFrameDecl>? {
    const n = fc.keyframes.length;
    if (n == 0) return null;
    const out = new Array<KeyFrameDecl>();
    for (let i = 0; i < n; i++) {
        const kf = fc.keyframes[i];
        const f = <f64>kf.frame - <f64>lo;
        const whole = Math.round(f);
        if (Math.abs(f - whole) > 1e-3 || whole < 0 || whole > <f64>duration) return null;
        const k = doubleKey(<i32>whole, <f64>kf.value * scale + offset, InterpolationType.Hold);
        if (i + 1 < n && !segmentKey(k, i, i + 1, fc, scale, offset)) return null;
        const ip = k.interpolator;
        if (ip != null) tidyInterpolator(ip);
        out.push(k);
    }
    return out;
}

// The keys of `t`: one F-curve's (an affine image of it the kernel's
// values follow at every frame), else baked.
function sceneTrackKeys(t: SceneTrack, lo: i32, frames: Array<i32>, duration: i32): Array<KeyFrameDecl> {
    for (let c = 0; c < t.candidates.length; c++) {
        const fc = t.candidates[c];
        if (fc.mute || fc.keyframes.length == 0) continue;
        // v = scale * fc + offset, from the first and the farthest value.
        const u = new Array<f64>(frames.length);
        for (let i = 0; i < frames.length; i++) u[i] = <f64>fc.evaluate(<f32>(lo + frames[i]));
        for (let s = 0; s < 2; s++) {
            const scale: f64 = s == 0 ? 1 : -1;
            const offset = t.values[0] - scale * u[0];
            let fits = true;
            for (let i = 0; i < frames.length && fits; i++) if (Math.abs(scale * u[i] + offset - t.values[i]) > 1e-5) fits = false;
            if (!fits) continue;
            const keys = fcurveKeys(fc, lo, duration, scale, offset);
            if (keys != null) {
                t.fromCurve = true;
                return keys;
            }
        }
    }
    return bakedDoubles(frames, t.values);
}

// Whether any of `fcurves` has something to play (not muted, with keys).
function playable(fcurves: Array<FCurve>): bool {
    for (let i = 0; i < fcurves.length; i++) if (!fcurves[i].mute && fcurves[i].keyframes.length > 0) return true;
    return false;
}

// The bones of an armature object, as the skeleton lists them, posed as
// `scene` holds them: each one's local pose in scene space (sceneSkeleton's
// rule, model_skeleton.as).
function boneLocal(scene: Scene, armId: u32, name: string): Mat4 {
    const arm = scene.objects.at(armId).armature();
    if (arm == null) return MAT4_IDENTITY;
    const id = arm.find(name);
    if (id == NO_BONE) return MAT4_IDENTITY;
    const ev = scene.poseEval(armId);
    const b = arm.bones.at(id);
    const pose = ev != null && <i32>id < ev.pose.length ? ev.pose[<i32>id] : b.restMatrix();
    if (b.parent != NO_BONE && arm.bones.get(b.parent) != null) {
        const ppose = ev != null && <i32>b.parent < ev.pose.length ? ev.pose[<i32>b.parent] : arm.bones.at(b.parent).restMatrix();
        return modelMatrixToScene(ppose.inverse() * pose);
    }
    return modelMatrixToScene(pose);
}

// Bone `name`'s global pose in its skeleton's space (scene space), from
// the bone locals of `scene`.
function boneGlobalOf(scene: Scene, armId: u32, sk: ModelSkeleton, name: string): Mat4 {
    let at = sk.boneIndex(name);
    let g = MAT4_IDENTITY;
    let guard = 0;
    while (at >= 0 && guard <= sk.bones.length) {
        g = boneLocal(scene, armId, sk.bones[at].name) * g;
        at = sk.bones[at].parent;
        guard++;
    }
    return g;
}

// Object `i`'s local transform in scene space as `scene` holds it (an
// object following a bone: relative to the bone).
function objectLocalAt(r: ModelReading, m: ModelResource, scene: Scene, i: i32): Mat4 {
    const o = m.objects[i];
    const id = r.order[i];
    if (o.parentBone.length > 0 && o.parent >= 0) {
        const armId = r.order[o.parent];
        const sk = m.objects[o.parent].skeleton;
        if (sk != null) {
            const g = objectSceneLocal(scene, armId, NO_OBJ, r.format) * boneGlobalOf(scene, armId, sk, o.parentBone);
            return g.inverse() * objectSceneLocal(scene, id, NO_OBJ, r.format);
        }
    }
    return objectSceneLocal(scene, id, o.parent >= 0 ? r.order[o.parent] : NO_OBJ, r.format);
}

// What action `aid` keys on object `id` (ModelObject `index`).
function keyedOn(scene: Scene, aid: u32, id: u32, index: i32): KeyedOn {
    const out = new KeyedOn(id, index);
    const action = scene.actions.at(aid);
    for (let f = 0; f < action.fcurves.length; f++) {
        const fc = action.fcurves[f];
        if (fc.mute || fc.keyframes.length == 0) continue;
        const dp = DataPath.parse(fc.dataPath);
        if (dp.kind == DataPathKind.Object) {
            if (dp.chan == Channel.Location) out.location.push(fc);
            else if (dp.chan == Channel.Scale) out.scale.push(fc);
            else out.rotation = true;
        } else if (dp.kind == DataPathKind.Bone) {
            const b = out.bone(dp.bone);
            if (dp.chan == Channel.Location) out.boneLocation[b].push(fc);
            else if (dp.chan == Channel.Scale) out.boneScale[b].push(fc);
            else out.boneRotation[b] = true;
        } else if (dp.kind == DataPathKind.ShapeKeyValue) {
            if (!out.shapeKeys.includes(dp.key)) {
                out.shapeKeys.push(dp.key);
                out.shapeCurves.push(fc);
            }
        }
    }
    return out;
}

// The armature object whose bones action `aid` keys (every bone it names),
// for an action no object uses; NO_OBJ for none.
function armatureFor(scene: Scene, r: ModelReading, aid: u32): u32 {
    const action = scene.actions.at(aid);
    const bones = new Array<string>();
    for (let f = 0; f < action.fcurves.length; f++) {
        const dp = DataPath.parse(action.fcurves[f].dataPath);
        if (dp.kind == DataPathKind.Bone || dp.kind == DataPathKind.ConstraintInfluence) bones.push(dp.bone);
    }
    if (bones.length == 0) return NO_OBJ;
    for (let i = 0; i < r.order.length; i++) {
        const arm = scene.objects.at(r.order[i]).armature();
        if (arm == null) continue;
        let all = true;
        for (let b = 0; b < bones.length && all; b++) if (arm.find(bones[b]) == NO_BONE) all = false;
        if (all) return r.order[i];
    }
    return NO_OBJ;
}

// Fills `m.clips` from the model scene's actions (an .rmdl's, a
// .modeler's): one clip per action, in the file's order (see the header).
export function readSceneClips(r: ModelReading, m: ModelResource): void {
    const scene = r.scene;
    const bound = scene.actions.idBound();
    const rate = Math.round(<f64>scene.fps);
    const fps = <i32>(rate >= 1 ? rate : 24);
    for (let aid: u32 = 0; aid < bound; aid++) {
        const action = scene.actions.get(aid);
        if (action == null) continue;
        const range = action.frameRange();
        // (an action with nothing to play, every curve muted or without
        // keys, is no clip, and nothing to warn of)
        if (range == null || !playable(action.fcurves)) continue;
        let users = scene.actionUsers(aid);
        if (users.length == 0) {
            const arm = armatureFor(scene, r, aid);
            if (arm == NO_OBJ) {
                m.warnings.push(CLIP_CHANNEL_UNSUPPORTED + ": action '" + action.name + "' animates no object of the model; skipped");
                continue;
            }
            users = [arm];
        }
        const lo = <i32>Math.floor(<f64>range.lo);
        const hi = <i32>Math.ceil(<f64>range.hi);
        const duration = max(1, hi - lo);
        // A copy in which only this action plays, on its users.
        const s = scene.clone();
        for (let id: u32 = 0; id < s.objects.idBound(); id++) {
            const o = s.objects.get(id);
            if (o == null) continue;
            if (users.includes(id)) o.animation = new AnimData(aid);
            else if (o.animation != null) o.animation = null;
        }
        const keyed = new Array<KeyedOn>();
        for (let u = 0; u < users.length; u++) {
            const index = r.index(users[u]);
            if (index >= 0) keyed.push(keyedOn(scene, aid, users[u], index));
        }
        // The tracks, filled frame by frame.
        const doubles = new Array<SceneTrack>();
        const quats = new Array<SceneQuatTrack>();
        // (per entry of `doubles` and `quats`, how to read it: see below)
        const dOwner = new Array<i32>();
        const dBone = new Array<string>();
        const dField = new Array<i32>();
        const dAxis = new Array<i32>();
        const qOwner = new Array<i32>();
        const qBone = new Array<string>();
        let unsupported = 0;
        for (let k = 0; k < keyed.length; k++) {
            const ko = keyed[k];
            const o = m.objects[ko.index];
            const sk = o.skeleton;
            for (let b = 0; b < ko.bones.length; b++) {
                const name = ko.bones[b];
                if (sk == null || sk.boneIndex(name) < 0) {
                    unsupported++;
                    continue;
                }
                for (let field = 0; field < 2; field++) {
                    const curves = field == 0 ? ko.boneLocation[b] : ko.boneScale[b];
                    if (curves.length == 0) continue;
                    for (let a = 0; a < 3; a++) {
                        const t = new SceneTrack(ko.index, boneProperty(name, field == 0 ? BONE_FIELD_POSITION : BONE_FIELD_SCALE, a));
                        t.candidates = curves;
                        doubles.push(t);
                        dOwner.push(k);
                        dBone.push(name);
                        dField.push(field);
                        dAxis.push(a);
                    }
                }
                if (ko.boneRotation[b]) {
                    quats.push(new SceneQuatTrack(ko.index, boneProperty(name, BONE_FIELD_QUATERNION)));
                    qOwner.push(k);
                    qBone.push(name);
                }
            }
            for (let field = 0; field < 2; field++) {
                const curves = field == 0 ? ko.location : ko.scale;
                if (curves.length == 0) continue;
                for (let a = 0; a < 3; a++) {
                    const t = new SceneTrack(ko.index, (field == 0 ? "position:" : "scale:") + AXES[a]);
                    t.candidates = curves;
                    doubles.push(t);
                    dOwner.push(k);
                    dBone.push("");
                    dField.push(field);
                    dAxis.push(a);
                }
            }
            if (ko.rotation) {
                quats.push(new SceneQuatTrack(ko.index, "quaternion"));
                qOwner.push(k);
                qBone.push("");
            }
            for (let sk2 = 0; sk2 < ko.shapeKeys.length; sk2++) {
                const key = ko.shapeKeys[sk2];
                if (!o.blendShapes.includes(key)) {
                    unsupported++;
                    continue;
                }
                const t = new SceneTrack(ko.index, blendShapeProperty(key));
                t.candidates = [ko.shapeCurves[sk2]];
                doubles.push(t);
                dOwner.push(k);
                dBone.push(key);
                dField.push(2);
                dAxis.push(0);
            }
        }
        if (doubles.length == 0 && quats.length == 0) {
            m.warnings.push(CLIP_CHANNEL_UNSUPPORTED + ": action '" + action.name + "' keys nothing a scene can play; skipped");
            continue;
        }
        const frames = new Array<i32>();
        for (let f = 0; f <= duration; f++) frames.push(f);
        for (let fi = 0; fi < frames.length; fi++) {
            s.applyFrame(<f32>(lo + frames[fi]));
            for (let d = 0; d < doubles.length; d++) {
                const ko = keyed[dOwner[d]];
                let v: f64 = 0;
                if (dField[d] == 2) {
                    const mesh = s.objects.at(ko.id).mesh();
                    if (mesh != null) {
                        for (let q = 0; q < mesh.shapeKeys.length; q++) {
                            if (mesh.shapeKeys[q].name == dBone[d]) v = mesh.shapeKeys[q].mute ? 0 : <f64>mesh.shapeKeys[q].clampedValue();
                        }
                    }
                } else {
                    const local = dBone[d].length > 0 ? boneLocal(s, ko.id, dBone[d]) : objectLocalAt(r, m, s, ko.index);
                    const pose = poseOf(local);
                    v = <f64>(dField[d] == 0 ? pose.position : pose.scale).get(dAxis[d]);
                }
                doubles[d].values.push(v);
            }
            for (let q = 0; q < quats.length; q++) {
                const ko = keyed[qOwner[q]];
                const local = qBone[q].length > 0 ? boneLocal(s, ko.id, qBone[q]) : objectLocalAt(r, m, s, ko.index);
                let rot = poseOf(local).rotation;
                const vs = quats[q].values;
                if (vs.length > 0 && rot.dot(vs[vs.length - 1]) < 0) rot = -rot;
                vs.push(rot);
            }
        }
        const clip = new ModelClip();
        clip.name = action.name;
        clip.fps = fps;
        clip.duration = duration;
        // (a rotation is always baked, exactly at every frame: the usual
        // road, so not warned of; a curve no interpolator follows is)
        let baked = 0;
        for (let d = 0; d < doubles.length; d++) {
            const t = doubles[d];
            const keys = sceneTrackKeys(t, lo, frames, duration);
            if (t.candidates.length > 0 && keys.length > 1 && !t.fromCurve) baked++;
            clip.tracks.push(track(t.object, t.property, keys));
        }
        for (let q = 0; q < quats.length; q++) {
            clip.tracks.push(track(quats[q].object, quats[q].property, bakedQuats(frames, quats[q].values)));
        }
        if (unsupported > 0) {
            m.warnings.push(CLIP_CHANNEL_UNSUPPORTED + ": action '" + action.name + "': " + unsupported.toString()
                + " channel(s) name a bone or shape key the model does not have; skipped");
        }
        if (baked > 0) {
            m.warnings.push(CLIP_BAKED + ": clip '" + action.name + "': " + baked.toString() + " curve(s) no interpolator follows baked to "
                + "one key a frame at " + fps.toString() + " fps");
        }
        m.clips.push(clip);
    }
}
