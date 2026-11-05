// A model's skeletons, skins and bone attachments, read for a scene
// (docs/plans/RIVE_MODEL.md section 3.7; docs/formats/IMPORT.md, "Skins,
// blend shapes and animations"): what model.as hands the engine in
// ModelObject.skeleton, .skin and .parentBone (engine/src/scene/
// skeleton/model_skin.as says what each holds and in which space), and the
// plan of each skinned or morphed mesh that the mesh cache builds from
// (MeshPlan, model_source.as).
//
// Two roads, as the formats hold their bones:
//
// - A glTF file's skeletons are its skins' joints, read from the document
//   (readGltfSkeletons): bones are the joint nodes in the skin's order
//   (parents first), posed as the nodes are, and each inverse bind matrix
//   is the file's. A bone's pose is exactly the node's transform, so a clip
//   keys it with the file's own numbers (model_clips.as) and glTF's sampler
//   is reproduced to the float.
// - An .rmdl's (and a .modeler's) are its armature objects' bones
//   (readSceneSkeletons): the rest relative to the parent bone, the pose the
//   file holds (the kernel's evaluated pose, so constraints and the inherit
//   flags are in it), and inverse binds from the bones' rest.
//
// Both take their weights from the model scene's own evaluation: the mesh
// with every modifier but the armature's applied (the bind mesh), its vertex
// groups carried through the stack, each vertex's influences found as the
// armature modifier finds them (groups named after deform bones, else the
// bones' envelopes at rest), then the four largest kept and made to sum 1,
// as the GPU skins (D6 of the plan). A glTF file's mesh holds its JOINTS_0
// and WEIGHTS_0 as those groups (the importer's), so the two roads share
// this part.
//
// Spaces. Bones and objects are in scene space (Y up); a mesh as the cache
// stores it is in model space (Z up), so an inverse bind takes a model-space
// point: for an .rmdl, C * rest^-1 * armWorld^-1 * meshWorld (C =
// MODEL_TO_SCENE, the worlds the kernel's), for glTF S(inverseBind) * C
// with S the file-to-scene conjugation the importer and model.as apply to
// every node. Then skeletonGlobal * boneGlobal * inverseBind * p is where
// the file draws p, bone by bone.

import { Mat4, Vec4, MAT4_IDENTITY } from "../../../base/vecmath";
import { Mesh } from "../../model/mesh/mod";
import { Armature, NO_BONE } from "../../model/armature/mod";
import { envelopeFactor } from "../../model/modifiers/armature";
import {
    Modifier, ModifierKindArmature, ModifierKindTag, NO_OBJ, NO_VGROUP, ObjectDataKind, ParentKindTag, Scene,
} from "../../model/scene";
import { GltfImportMap } from "../../io/gltf_to_model/gltf_import";
import { MODEL_TO_SCENE, SCENE_TO_MODEL, modelMatrixToScene } from "../../../scene/space";
import { ModelFormat, ModelResource } from "../../../scene/resource/types";
import {
    BonePose, MAX_SKIN_JOINTS, ModelBone, ModelSkeleton, ModelSkin, SKIN_INFLUENCES, SKIN_JOINTS_LIMIT, SKIN_MODIFIER_ORDER,
    SKIN_PRESERVE_VOLUME, SKIN_WEIGHTS_LOST,
} from "../../../scene/skeleton/model_skin";
import { MorphPlan, evaluateWithout, readMorphs } from "./model_morphs";

// What model.as knows of a model being read: the scene, how it was read,
// which scene object each ModelObject is (and back), the glTF document when
// the model is one, and where the plans for the mesh cache go.
export class ModelReading {
    scene: Scene;
    format: ModelFormat;
    // ModelObject index -> scene object id, and back.
    order: Array<u32>;
    indexOf: Map<u32, i32> = new Map<u32, i32>();
    gltf: GltfImportMap?;
    plans: Map<u32, MeshPlan> = new Map<u32, MeshPlan>();
    // Each ModelObject's global transform in scene space, as its local
    // transforms compose (before any is changed here).
    globals: Array<Mat4> = [];

    constructor(scene: Scene, format: ModelFormat, order: Array<u32>, gltf: GltfImportMap?) {
        this.scene = scene;
        this.format = format;
        this.order = order;
        this.gltf = gltf;
        for (let i = 0; i < order.length; i++) this.indexOf.set(order[i], i);
    }

    // The ModelObject index of scene object `id`, -1 for none.
    index(id: u32): i32 {
        return this.indexOf.has(id) ? this.indexOf.get(id) : -1;
    }
}

// How the mesh cache builds a skinned or morphed object's GpuMesh
// (model_source.as KernelMeshCache): from `bind`, the mesh with its
// modifiers applied but the armature's, each built vertex then taking its
// mesh vertex's skin and shape key offsets. Per mesh vertex id (as `bind`
// numbers them): `joints` four palette slots packed one byte each, little
// endian, and `weights` four weights summing to 1 (null: not skinned).
export class MeshPlan {
    objectId: u32;
    bind: Mesh;
    joints: Array<u32>? = null;
    weights: Array<f32>? = null;
    morphs: MorphPlan? = null;

    constructor(objectId: u32, bind: Mesh) {
        this.objectId = objectId;
        this.bind = bind;
    }
}

// Whether an object's node keeps the object's own axes: cameras and lights
// of a .modeler file, which aim along their own -Z in both conventions
// (../space.as). A glTF camera or light is not an exception: the importer
// converted its node by conjugation like any other (it aims along its
// node's -Z in the file, and Hedra reads that as is), so converting it
// back the same way gives the file's own transform, as Godot shows it.
// Keeping its axes would turn it a quarter turn about X.
export function keepsAxes(kind: ObjectDataKind, format: ModelFormat): bool {
    return format == ModelFormat.Modeler && (kind == ObjectDataKind.Camera || kind == ObjectDataKind.Light);
}

// Object `id`'s transform relative to its parent's node (`parent`, NO_OBJ
// at the top) in scene space, as the object stands in `scene` (model.as;
// a clip baking an object's channels asks it again at each frame):
// local = S(parent)^-1 * S(o), with S = C W C^-1 (conjugated) or C W (a
// .modeler file's cameras and lights); C = MODEL_TO_SCENE. With L the local
// model matrix, the four cases reduce to exact products (in a glTF file
// only the first applies).
export function objectSceneLocal(scene: Scene, id: u32, parent: u32, format: ModelFormat): Mat4 {
    const obj = scene.objects.at(id);
    const kind = obj.data.kind;
    if (parent == NO_OBJ) {
        const w = scene.worldMatrix(id);
        return keepsAxes(kind, format) ? MODEL_TO_SCENE * w : modelMatrixToScene(w);
    }
    const l = obj.parentInverse * obj.transform.matrix();
    const parentKeeps = keepsAxes(scene.objects.at(parent).data.kind, format);
    if (!parentKeeps) return keepsAxes(kind, format) ? MODEL_TO_SCENE * l : modelMatrixToScene(l);
    return keepsAxes(kind, format) ? l : l * SCENE_TO_MODEL;
}

// The global transform of every ModelObject of `m` in scene space.
export function objectGlobals(m: ModelResource): Array<Mat4> {
    const out = new Array<Mat4>();
    for (let i = 0; i < m.objects.length; i++) {
        const o = m.objects[i];
        out.push(o.parent >= 0 && o.parent < i ? out[o.parent] * o.local : o.local);
    }
    return out;
}

// A transform as a bone's pose (T * R * S).
export function poseOf(m: Mat4): BonePose {
    const srt = m.toScaleRotationTranslation();
    return new BonePose(srt.translation, srt.rotation.normalize(), srt.scale);
}

// The global transform of bone `b` of `sk` in its skeleton's space, at
// the rest (`rest`) or the file's pose.
export function boneGlobal(sk: ModelSkeleton, b: i32, rest: bool): Mat4 {
    let m = MAT4_IDENTITY;
    let at = b;
    let guard = 0;
    while (at >= 0 && at < sk.bones.length && guard <= sk.bones.length) {
        const bone = sk.bones[at];
        m = (rest ? bone.rest : bone.pose).matrix() * m;
        at = bone.parent;
        guard++;
    }
    return m;
}

// --- bones in parents-first order --------------------------------------------

// `count` items whose parents are `parent[i]` (-1 none), in `order` (their
// own order) except that a parent always comes before its children: an
// item is placed once its parent is (a cycle is broken where it closes).
function parentsFirst(parent: Array<i32>): Array<i32> {
    const n = parent.length;
    const placed = new Array<bool>(n);
    for (let i = 0; i < n; i++) placed[i] = false;
    const out = new Array<i32>();
    const chain = new Array<i32>();
    for (let i = 0; i < n; i++) {
        if (placed[i]) continue;
        chain.length = 0;
        let at = i;
        while (at >= 0 && !placed[at] && !chain.includes(at)) {
            chain.push(at);
            at = parent[at];
        }
        for (let k = chain.length - 1; k >= 0; k--) {
            placed[chain[k]] = true;
            out.push(chain[k]);
        }
    }
    return out;
}

// --- .rmdl and .modeler: armature objects ---------------------------------------

// The bones of armature object `armId`, parents first (by id otherwise),
// each relative to its parent (or to the armature object) in scene space:
// the rest from the rest matrices, the pose from the kernel's evaluated pose
// (the file's channels, constraints and IK applied, as Hedra draws it).
// `ids` receives each bone's armature bone id.
function sceneSkeleton(scene: Scene, armId: u32, arm: Armature, ids: Array<u32>): ModelSkeleton {
    const all = new Array<u32>();
    const bound = arm.bones.idBound();
    for (let id: u32 = 0; id < bound; id++) if (arm.bones.get(id) != null) all.push(id);
    const parentIdx = new Array<i32>();
    for (let i = 0; i < all.length; i++) {
        const p = arm.bones.at(all[i]).parent;
        parentIdx.push(p == NO_BONE ? -1 : all.indexOf(p));
    }
    const order = parentsFirst(parentIdx);
    const ev = scene.poseEval(armId);
    const sk = new ModelSkeleton();
    for (let k = 0; k < order.length; k++) {
        const id = all[order[k]];
        const b = arm.bones.at(id);
        ids.push(id);
        const out = new ModelBone();
        out.name = b.name;
        const p = parentIdx[order[k]];
        out.parent = p >= 0 ? order.indexOf(p) : -1;
        const rest = b.restMatrix();
        const pose = ev != null && <i32>id < ev.pose.length ? ev.pose[<i32>id] : rest;
        if (b.parent != NO_BONE && arm.bones.get(b.parent) != null) {
            const prest = arm.bones.at(b.parent).restMatrix();
            const ppose = ev != null && <i32>b.parent < ev.pose.length ? ev.pose[<i32>b.parent] : prest;
            out.rest = poseOf(modelMatrixToScene(prest.inverse() * rest));
            out.pose = poseOf(modelMatrixToScene(ppose.inverse() * pose));
        } else {
            out.rest = poseOf(modelMatrixToScene(rest));
            out.pose = poseOf(modelMatrixToScene(pose));
        }
        sk.bones.push(out);
    }
    return sk;
}

// Fills `m`'s skeletons, skins, bone attachments and blend shapes from the
// model scene (an .rmdl's, a .modeler's; a glTF file's when its document was
// not kept), and the mesh plans in `r`.
export function readSceneSkeletons(r: ModelReading, m: ModelResource): void {
    const scene = r.scene;
    r.globals = objectGlobals(m);
    // Armature objects become skeletons.
    const boneIds = new Map<i32, Array<u32>>();
    for (let i = 0; i < r.order.length; i++) {
        const obj = scene.objects.at(r.order[i]);
        const arm = obj.armature();
        if (arm == null) continue;
        const ids = new Array<u32>();
        m.objects[i].skeleton = sceneSkeleton(scene, r.order[i], arm, ids);
        boneIds.set(i, ids);
    }
    attachToBones(r, m);
    for (let i = 0; i < r.order.length; i++) {
        const id = r.order[i];
        const obj = scene.objects.at(id);
        if (obj.data.kind != ObjectDataKind.Mesh || m.objects[i].mesh == null) continue;
        readMeshPlan(r, m, i, id, false);
    }
}

// --- glTF: skins read from the document ---------------------------------------

// The scene-space transform of a glTF matrix `g` (a node's, global or
// local): what the importer and model.as make of a node's transform, the
// frame change by conjugation and the unit scale on the translation.
export function gltfToScene(map: GltfImportMap, g: Mat4): Mat4 {
    const c = MODEL_TO_SCENE * map.conv.inverse();
    let m = g;
    m.wAxis = Vec4(g.wAxis.x * map.scale, g.wAxis.y * map.scale, g.wAxis.z * map.scale, g.wAxis.w);
    return c * m * c.inverse();
}

// The skeleton of glTF skin `si`: its joints, parents first (the file's
// order where it already is), each posed at its node's transform relative
// to its parent joint (nodes between two joints folded into the child), a
// root joint relative to the armature object (global `armGlobal`). Rest
// and pose are the same: the file's pose. `joints` receives each bone's
// joint index.
function gltfSkeleton(map: GltfImportMap, si: i32, armGlobal: Mat4, joints: Array<i32>): ModelSkeleton {
    const skin = map.skins.skins[si];
    const names = map.boneNames[si];
    const n = skin.joints.length;
    const parentIdx = new Array<i32>();
    for (let j = 0; j < n; j++) {
        // The nearest ancestor that is a joint of this skin.
        let p = map.graph.parent[skin.joints[j]];
        let guard = 0;
        while (p >= 0 && !skin.jointOfNode.has(p) && guard < 100000) {
            p = map.graph.parent[p];
            guard++;
        }
        parentIdx.push(p >= 0 && skin.jointOfNode.has(p) ? skin.jointOfNode.get(p) : -1);
    }
    const order = parentsFirst(parentIdx);
    const sk = new ModelSkeleton();
    const armInv = armGlobal.inverse();
    for (let k = 0; k < order.length; k++) {
        const j = order[k];
        joints.push(j);
        const b = new ModelBone();
        b.name = j < names.length ? names[j] : "Bone";
        const p = parentIdx[j];
        b.parent = p >= 0 ? order.indexOf(p) : -1;
        const g = gltfToScene(map, map.graph.global[skin.joints[j]]);
        const local = p >= 0 ? gltfToScene(map, map.graph.global[skin.joints[p]]).inverse() * g : armInv * g;
        b.rest = poseOf(local);
        b.pose = b.rest.clone();
        sk.bones.push(b);
    }
    return sk;
}

// Fills `m`'s skeletons, skins, bone attachments and blend shapes from a
// glTF file's document (r.gltf), and the mesh plans in `r`.
export function readGltfSkeletons(r: ModelReading, m: ModelResource): void {
    const map = r.gltf as GltfImportMap;
    r.globals = objectGlobals(m);
    const jointsOf = new Map<i32, Array<i32>>();
    for (let si = 0; si < map.armObj.length; si++) {
        const ai = r.index(map.armObj[si]);
        if (ai < 0) continue;
        const joints = new Array<i32>();
        m.objects[ai].skeleton = gltfSkeleton(map, si, r.globals[ai], joints);
        jointsOf.set(si, joints);
    }
    attachToBones(r, m);
    for (let i = 0; i < r.order.length; i++) {
        const id = r.order[i];
        const obj = r.scene.objects.at(id);
        if (obj.data.kind != ObjectDataKind.Mesh || m.objects[i].mesh == null) continue;
        readMeshPlan(r, m, i, id, true);
    }
}

// --- bone attachments -----------------------------------------------------------

// Objects parented to a bone (an .rmdl's `--parent-type bone`, a glTF node
// under a joint) name it, their transform made relative to the bone's
// global pose, so that where the file places them is where they are at its
// pose.
function attachToBones(r: ModelReading, m: ModelResource): void {
    for (let i = 0; i < r.order.length; i++) {
        const obj = r.scene.objects.at(r.order[i]);
        const p = obj.parent;
        if (p == null || p.kind.tag != ParentKindTag.Bone) continue;
        const o = m.objects[i];
        if (o.parent < 0) continue;
        const sk = m.objects[o.parent].skeleton;
        if (sk == null) continue;
        const b = sk.boneIndex(p.kind.bone);
        if (b < 0) continue;
        o.parentBone = p.kind.bone;
        o.local = (r.globals[o.parent] * boneGlobal(sk, b, false)).inverse() * r.globals[i];
    }
}

// --- skins ------------------------------------------------------------------------

// The first enabled armature modifier of `mods` with an armature object,
// its index; -1 for none.
function armatureModifier(mods: Array<Modifier>): i32 {
    for (let i = 0; i < mods.length; i++) {
        const md = mods[i];
        if (!md.enabled || md.kind.tag != ModifierKindTag.Armature) continue;
        if ((md.kind as ModifierKindArmature).object != NO_OBJ) return i;
    }
    return -1;
}

// One vertex's influences, kept to the four largest (ties: the earlier
// bone) and made to sum to 1.
class Influences {
    bones: Array<i32> = [];
    weights: Array<f32> = [];

    add(bone: i32, w: f32): void {
        for (let k = 0; k < this.bones.length; k++) {
            if (this.bones[k] == bone) {
                this.weights[k] += w;
                return;
            }
        }
        this.bones.push(bone);
        this.weights.push(w);
    }

    clear(): void {
        this.bones.length = 0;
        this.weights.length = 0;
    }

    // The four largest, in decreasing weight, made to sum to 1; false when
    // none weighs anything.
    finish(): bool {
        const n = this.bones.length;
        // (a selection: a handful of influences)
        for (let a = 0; a < n; a++) {
            let best = a;
            for (let b = a + 1; b < n; b++) if (this.weights[b] > this.weights[best]) best = b;
            if (best != a) {
                const tb = this.bones[a];
                this.bones[a] = this.bones[best];
                this.bones[best] = tb;
                const tw = this.weights[a];
                this.weights[a] = this.weights[best];
                this.weights[best] = tw;
            }
        }
        if (n > SKIN_INFLUENCES) {
            this.bones.length = SKIN_INFLUENCES;
            this.weights.length = SKIN_INFLUENCES;
        }
        let total: f64 = 0;
        for (let k = 0; k < this.weights.length; k++) total += <f64>this.weights[k];
        if (!(total > 1e-12)) return false;
        for (let k = 0; k < this.weights.length; k++) this.weights[k] = <f32>(<f64>this.weights[k] / total);
        return true;
    }
}

// Object `i` (scene object `id`, a mesh): its skin, when an armature
// modifier deforms it, and its blend shapes, when its mesh has shape keys;
// with either, the plan its GpuMesh is built from.
function readMeshPlan(r: ModelReading, m: ModelResource, i: i32, id: u32, gltf: bool): void {
    const scene = r.scene;
    const obj = scene.objects.at(id);
    const base = obj.mesh();
    if (base == null) return;
    const o = m.objects[i];
    const mods = obj.modifiers;
    const at = armatureModifier(mods);
    let skinned = at >= 0;
    let armIndex = -1;
    let armId: u32 = NO_OBJ;
    if (skinned) {
        armId = (mods[at].kind as ModifierKindArmature).object;
        armIndex = r.index(armId);
        const arm = scene.objects.get(armId);
        if (armIndex < 0 || arm == null || arm.armature() == null || m.objects[armIndex].skeleton == null
            // (an armature with no bones skins nothing: the mesh is drawn as
            // its modifiers leave it)
            || (m.objects[armIndex].skeleton as ModelSkeleton).bones.length == 0) skinned = false;
    }
    const morphing = base.shapeKeys.length > 1;
    if (!skinned && !morphing) return;
    // The bind mesh: every modifier but the armature's, on the basis (the
    // shape keys are blended by the renderer, from the plan's offsets).
    const basis = base.shapeKeys.length > 0 ? withBasis(base) : base;
    const bind = evaluateWithout(scene, id, basis, mods, skinned ? at : -1);
    const plan = new MeshPlan(id, bind);
    if (skinned) {
        const k = mods[at].kind as ModifierKindArmature;
        let later = 0;
        for (let x = at + 1; x < mods.length; x++) if (mods[x].enabled) later++;
        if (k.preserveVolume) {
            m.warnings.push(SKIN_PRESERVE_VOLUME + ": mesh '" + obj.name + "' preserves volume, which is drawn as linear blend skinning");
        }
        const skin = readSkin(r, m, id, armId, armIndex, k, bind, plan, gltf);
        if (skin == null) {
            // Drawn as the file poses it: the whole stack, the armature's
            // deform in it.
            plan.bind = evaluateWithout(scene, id, basis, mods, -1);
        } else {
            if (later > 0) {
                m.warnings.push(SKIN_MODIFIER_ORDER + ": mesh '" + obj.name + "' has " + later.toString()
                    + " modifier(s) after its armature's, applied to the mesh at bind time before it is skinned");
            }
            o.skin = skin;
        }
    }
    if (morphing) {
        const mp = readMorphs(scene, gltf ? r.gltf : null, m, id, base, mods, skinned && o.skin != null ? at : -1, plan.bind);
        if (mp != null) {
            plan.morphs = mp;
            o.blendShapes = mp.names.slice(0);
            o.blendShapeWeights = mp.weights.slice(0);
        }
    }
    if (o.skin != null || plan.morphs != null) {
        // Skinned without the armature's deform: built from `bind`. Morphed
        // only: likewise (the shape keys no longer mixed into it).
        r.plans.set(id, plan);
    }
}

// `base` with its basis key's positions as its coordinates (what object
// mode shows with every key at 0).
function withBasis(base: Mesh): Mesh {
    const out = base.clone();
    const ps = base.shapeKeys[0].positions;
    const bound = out.verts.idBound();
    for (let v: u32 = 0; v < bound; v++) {
        const vert = out.verts.get(v);
        if (vert != null && <i32>v < ps.length) vert.co = ps[<i32>v];
    }
    out.recalcNormals();
    out.touch();
    return out;
}

// The skin of object `i` deformed by armature object `armId` (ModelObject
// `armIndex`), its weights per vertex of `bind` into `plan`; null, with
// the warning saying why, when it cannot be skinned (no weights left
// through the stack, more joints than a palette holds).
function readSkin(r: ModelReading, m: ModelResource, id: u32, armId: u32, armIndex: i32, k: ModifierKindArmature,
    bind: Mesh, plan: MeshPlan, gltf: bool): ModelSkin? {
    const scene = r.scene;
    const obj = scene.objects.at(id);
    const arm = scene.objects.at(armId).armature() as Armature;
    const sk = m.objects[armIndex].skeleton as ModelSkeleton;
    if (sk.bones.length == 0) return null;
    // The deform bones in id order, as the armature modifier takes them,
    // each with its vertex group and its bone in the skeleton.
    const groupOf = new Array<u32>();
    const boneOf = new Array<i32>();
    const restOf = new Array<Mat4>();
    const bound = arm.bones.idBound();
    const deformIds = new Array<u32>();
    for (let b: u32 = 0; b < bound; b++) {
        const bone = arm.bones.get(b);
        if (bone == null || !bone.deform) continue;
        deformIds.push(b);
        groupOf.push(obj.vgroupIndex(bone.name));
        boneOf.push(sk.boneIndex(bone.name));
        restOf.push(bone.restMatrix());
    }
    // Weights lost on the way through the stack: groups on the mesh that the
    // bind mesh no longer has.
    if (k.useVertexGroups && !k.useEnvelopes && hasGroups(obj.mesh() as Mesh) && !hasGroups(bind)) {
        m.warnings.push(SKIN_WEIGHTS_LOST + ": mesh '" + obj.name + "' loses its vertex groups in its modifiers; it is drawn as the file poses it, unskinned");
        return null;
    }
    const toArm = scene.worldMatrix(armId).inverse() * scene.worldMatrix(id);
    const vb = bind.verts.idBound();
    const per = new Array<Influences>(<i32>vb);
    const used = new Array<bool>(sk.bones.length);
    for (let b = 0; b < sk.bones.length; b++) used[b] = false;
    const inf = new Influences();
    let unweighted = 0;
    for (let v: u32 = 0; v < vb; v++) {
        const vert = bind.verts.get(v);
        if (vert == null) continue;
        inf.clear();
        if (k.useVertexGroups) {
            for (let d = 0; d < deformIds.length; d++) {
                const g = groupOf[d];
                if (g == NO_VGROUP || boneOf[d] < 0) continue;
                for (let q = 0; q < vert.groups.length; q++) {
                    if (vert.groups[q].group == g) {
                        if (vert.groups[q].weight > <f32>0) inf.add(boneOf[d], vert.groups[q].weight);
                        break;
                    }
                }
            }
        }
        if (inf.bones.length == 0 && k.useEnvelopes) {
            // Envelopes depend on the rest pose only: folded in here.
            const p = toArm.transformPoint3(vert.co);
            for (let d = 0; d < deformIds.length; d++) {
                if (boneOf[d] < 0) continue;
                const bone = arm.bones.at(deformIds[d]);
                const f = envelopeFactor(p, bone.head, bone.tail, bone.headRadius, bone.tailRadius, bone.envelopeDistance) * bone.envelopeWeight;
                if (f > <f32>0) inf.add(boneOf[d], f);
            }
        }
        const one = new Influences();
        if (inf.finish()) {
            for (let q = 0; q < inf.bones.length; q++) {
                one.bones.push(inf.bones[q]);
                one.weights.push(inf.weights[q]);
                used[inf.bones[q]] = true;
            }
        } else {
            // A vertex no bone moves stays where the file has it at rest:
            // it follows the skeleton's first bone, the nearest a palette
            // of bones comes to "not deformed" (docs/formats/IMPORT.md).
            unweighted++;
            one.bones.push(0);
            one.weights.push(1);
            used[0] = true;
        }
        per[<i32>v] = one;
    }
    // The palette: the bones used, in skeleton order.
    const slotOf = new Array<i32>(sk.bones.length);
    const joints = new Array<i32>();
    for (let b = 0; b < sk.bones.length; b++) {
        slotOf[b] = -1;
        if (!used[b]) continue;
        slotOf[b] = joints.length;
        joints.push(b);
    }
    if (joints.length > MAX_SKIN_JOINTS) {
        m.warnings.push(SKIN_JOINTS_LIMIT + ": mesh '" + obj.name + "' uses " + joints.length.toString() + " bones, more than "
            + MAX_SKIN_JOINTS.toString() + ": it is drawn unskinned");
        return null;
    }
    const pj = new Array<u32>(<i32>vb);
    const pw = new Array<f32>(<i32>vb * SKIN_INFLUENCES);
    for (let v = 0; v < <i32>vb; v++) {
        pj[v] = 0;
        for (let q = 0; q < SKIN_INFLUENCES; q++) pw[v * SKIN_INFLUENCES + q] = 0;
        if (bind.verts.get(<u32>v) == null) continue;
        const one = per[v];
        let packed: u32 = 0;
        for (let q = 0; q < one.bones.length; q++) {
            packed |= (<u32>slotOf[one.bones[q]] & 0xff) << (<u32>q * 8);
            pw[v * SKIN_INFLUENCES + q] = one.weights[q];
        }
        pj[v] = packed;
    }
    plan.joints = pj;
    plan.weights = pw;
    const skin = new ModelSkin();
    skin.skeleton = armIndex;
    skin.joints = joints;
    if (gltf) {
        gltfInverseBinds(r, armId, sk, skin);
    } else {
        // C * rest^-1 * armWorld^-1 * meshWorld (the header).
        const toArmScene = scene.worldMatrix(armId).inverse() * scene.worldMatrix(id);
        for (let q = 0; q < joints.length; q++) {
            const name = sk.bones[joints[q]].name;
            const bid = arm.find(name);
            const rest = bid != NO_BONE ? arm.bones.at(bid).restMatrix() : MAT4_IDENTITY;
            skin.inverseBinds.push(MODEL_TO_SCENE * rest.inverse() * toArmScene);
        }
    }
    if (unweighted > 0) {
        m.warnings.push(SKIN_WEIGHTS_LOST + ": mesh '" + obj.name + "' has " + unweighted.toString()
            + " vertices no bone weighs; they follow bone '" + sk.bones[0].name + "'");
    }
    return skin;
}

// Whether any vertex of `mesh` is in a vertex group.
function hasGroups(mesh: Mesh): bool {
    const vb = mesh.verts.idBound();
    for (let v: u32 = 0; v < vb; v++) {
        const vert = mesh.verts.get(v);
        if (vert != null && vert.groups.length > 0) return true;
    }
    return false;
}

// A glTF skin's inverse binds: the file's, for the joint each palette slot
// names, as S(inverseBind) * C (the header), so that its bind pose is the
// file's whatever pose its nodes hold.
function gltfInverseBinds(r: ModelReading, armId: u32, sk: ModelSkeleton, skin: ModelSkin): void {
    const map = r.gltf as GltfImportMap;
    let si = -1;
    for (let s = 0; s < map.armObj.length; s++) if (map.armObj[s] == armId) si = s;
    const names = si >= 0 ? map.boneNames[si] : new Array<string>();
    for (let q = 0; q < skin.joints.length; q++) {
        const j = names.indexOf(sk.bones[skin.joints[q]].name);
        const ibm = si >= 0 && j >= 0 && j < map.skins.skins[si].inverseBind.length ? map.skins.skins[si].inverseBind[j] : MAT4_IDENTITY;
        skin.inverseBinds.push(gltfToScene(map, ibm) * MODEL_TO_SCENE);
    }
}
