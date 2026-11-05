// glTF skins on import. Every skin becomes an
// armature object with one bone per joint. Bone rest poses come from the
// inverse bind matrices (head = bind position, tail = the child joint's head,
// roll from the bind Z axis), the pose channels from the joint nodes' current
// transforms, so the file's pose is reproduced by `Scene.poseEval`.
//
// A bone's rest frame (its Y axis from head to tail, Blender's rule) is not
// the joint's own frame when the joint's axes do not run along the bone (a
// file whose joints keep the axes of their parent, as most game exports
// do). The armature modifier moves a vertex by `pose * rest^-1`, and glTF
// by `joint global * inverse bind`; the two agree when a bone is posed at
// `joint global * bind^-1 * rest`, the joint's frame carried over to the
// bone's. At the file's rest pose that is the rest itself (an identity
// channel), where posing at the joint's frame itself turned such a bone by
// the angle between the two frames and drew the mesh splayed. A skin whose
// joints' frames are the bones' (what Hedra's own export writes) needs no
// carrying over, and its channels are computed exactly as they always were.
// The carrying over is asked for by ImportOpts.carryJointFrames (a scene's
// model load); Hedra's own import keeps the reference importer's
// channels, which its goldens record.
//
// When the root joints hang under one node that is neither a joint nor a
// mesh (the armature node Blender and Hedra export), that node becomes the
// armature object; otherwise the armature sits at the scene root.
//
// Node indices are i32 (engine/src/source/io/gltf/doc.as); -1 is no node.

import { Mat4, Vec3, MAT4_IDENTITY, VEC3_ZERO, VEC3_ONE, VEC3_Z, VEC3_NAN, QUAT_IDENTITY } from "../../../base/vecmath";
import { Armature, Bone, NO_BONE, rollToVector } from "../../model/armature/mod";
import { Root } from "../gltf/doc";
import { nodeTransform, readInverseBindMatrices } from "../gltf/reader";

// A Mat4 from a node's column-major 16-float matrix.
export function mat4FromCols(m: StaticArray<f32>): Mat4 {
    const a: Array<f32> = new Array<f32>(16);
    for (let i = 0; i < 16; i++) a[i] = m[i];
    return Mat4.fromColsArray(a);
}

// Parents and global (glTF space) matrices of every node in the file.
export class NodeGraph {
    // -1 = None.
    parent: Array<i32> = [];
    global: Array<Mat4> = [];

    // NodeGraph::new
    static create(doc: Root): NodeGraph {
        const n = doc.nodes.length;
        const parent = new Array<i32>(n);
        for (let i = 0; i < n; i++) parent[i] = -1;
        for (let i = 0; i < n; i++) {
            const ch = doc.nodes[i].children;
            if (ch == null) continue;
            for (let k = 0; k < ch.length; k++) parent[ch[k]] = i;
        }
        const local: Array<Mat4> = [];
        for (let i = 0; i < n; i++) local.push(mat4FromCols(nodeTransform(doc.nodes[i]).matrix()));
        const global: Array<Mat4> = [];
        for (let i = 0; i < n; i++) global.push(MAT4_IDENTITY);
        const done = new Array<bool>(n);
        for (let i = 0; i < n; i++) done[i] = false;
        for (let i = 0; i < n; i++) resolve(i, parent, local, global, done);
        const g = new NodeGraph();
        g.parent = parent;
        g.global = global;
        return g;
    }
}

// A recursive resolve with a `depth > 100_000` guard, unrolled: the chain of calls that would recurse (stopping at a resolved
// node, the depth guard or a root) is collected first, then each call's
// assignment runs in unwinding order. A cycle repeats nodes in the chain,
// exactly as the recursion re-enters them.
function resolve(i: i32, parent: Array<i32>, local: Array<Mat4>, global: Array<Mat4>, done: Array<bool>): void {
    const chain: Array<i32> = [];
    let cur = i;
    let depth = 0;
    while (true) {
        if (done[cur] || depth > 100000) break;
        chain.push(cur);
        const p = parent[cur];
        if (p < 0) break;
        cur = p;
        depth++;
    }
    for (let k = chain.length - 1; k >= 0; k--) {
        const x = chain[k];
        const p = parent[x];
        if (p >= 0) global[x] = global[p] * local[x];
        else global[x] = local[x];
        done[x] = true;
    }
}

export class SkinInfo {
    name: string = "";
    // Joint node indices in `JOINTS_0` order.
    joints: Array<i32> = [];
    // Joint node -> joint index (the last listing wins).
    jointOfNode: Map<i32, i32> = new Map<i32, i32>();
    // glTF space, one per joint (identity when the file has none).
    inverseBind: Array<Mat4> = [];
    // The node that becomes the armature object, if one qualifies (-1 = None).
    armNode: i32 = -1;
    // Set by buildArmature: each joint's bind matrix in the armature
    // object's space (the inverse of its inverse bind matrix), and whether
    // some joint's frame differs from its bone's rest frame, so that its
    // pose is carried over (see the header; import_anim.as's bone channels
    // follow the same rule).
    armBind: Array<Mat4> = [];
    corrected: bool = false;
}

// `SkinSet::joint_of`'s `(skin, joint)`.
export class SkinJoint {
    skin: i32;
    joint: i32;
    constructor(skin: i32, joint: i32) {
        this.skin = skin;
        this.joint = joint;
    }
}

export class SkinSet {
    skins: Array<SkinInfo> = [];
    jointNodes: Set<i32> = new Set<i32>();
    adopted: Map<i32, i32> = new Map<i32, i32>();

    // SkinSet::new
    static create(doc: Root, buffers: Array<Uint8Array>, graph: NodeGraph): SkinSet {
        const skins: Array<SkinInfo> = [];
        const jointNodes = new Set<i32>();
        const adopted = new Map<i32, i32>();
        for (let si = 0; si < doc.skins.length; si++) {
            const skin = doc.skins[si];
            const info = new SkinInfo();
            const joints: Array<i32> = [];
            for (let k = 0; k < skin.joints.length; k++) joints.push(skin.joints[k]);
            for (let j = 0; j < joints.length; j++) info.jointOfNode.set(joints[j], j);
            const ibm = readInverseBindMatrices(doc, si, buffers);
            const inverseBind: Array<Mat4> = [];
            if (ibm != null) {
                const count = ibm.length / 16;
                for (let k = 0; k < count; k++) inverseBind.push(Mat4.fromF32Array(ibm, k * 16));
            }
            // `resize(joints.len(), IDENTITY)`
            if (inverseBind.length > joints.length) inverseBind.length = joints.length;
            while (inverseBind.length < joints.length) inverseBind.push(MAT4_IDENTITY);
            for (let k = 0; k < joints.length; k++) jointNodes.add(joints[k]);
            const name = skin.name;
            info.name = name != null ? name : "Armature";
            info.joints = joints;
            info.inverseBind = inverseBind;
            info.armNode = -1;
            skins.push(info);
        }
        // A node parenting every root joint of a skin stands in for the
        // armature object when nothing else claims it.
        const hasMesh = new Set<i32>();
        for (let i = 0; i < doc.nodes.length; i++) {
            const n = doc.nodes[i];
            if (n.mesh >= 0 || n.camera >= 0) hasMesh.add(i);
        }
        for (let si = 0; si < skins.length; si++) {
            const skin = skins[si];
            // A set of parent indices; -1 stands for no parent.
            const parents = new Set<i32>();
            for (let k = 0; k < skin.joints.length; k++) {
                const p = graph.parent[skin.joints[k]];
                if (!(p >= 0 && skin.jointOfNode.has(p))) parents.add(p);
            }
            if (parents.size != 1) continue;
            const p = parents.values()[0];
            if (p < 0) continue;
            if (jointNodes.has(p) || hasMesh.has(p) || adopted.has(p)) continue;
            adopted.set(p, si);
            skin.armNode = p;
        }
        const s = new SkinSet();
        s.skins = skins;
        s.jointNodes = jointNodes;
        s.adopted = adopted;
        return s;
    }

    isJoint(node: i32): bool {
        return this.jointNodes.has(node);
    }

    // The skin whose armature object this node becomes (-1 = None).
    adoptedSkin(node: i32): i32 {
        return this.adopted.has(node) ? this.adopted.get(node) : -1;
    }

    // The skin (and joint index) a joint node belongs to; the first skin
    // listing it when several share the node. null = None.
    jointOf(node: i32): SkinJoint? {
        for (let si = 0; si < this.skins.length; si++) {
            const s = this.skins[si];
            if (s.jointOfNode.has(node)) return new SkinJoint(si, s.jointOfNode.get(node));
        }
        return null;
    }
}

// The node-to-scene transform of gltf_import: undo the exporter's frame change, then
// apply the unit scale to the translation only (mesh data is scaled directly).
export class ToScene {
    conv: Mat4;
    convInv: Mat4;
    scale: f32;
    constructor(conv: Mat4, convInv: Mat4, scale: f32) {
        this.conv = conv;
        this.convInv = convInv;
        this.scale = scale;
    }
    apply(m: Mat4): Mat4 {
        let local = this.convInv * m * this.conv;
        local.wAxis = (local.wAxis.truncate() * this.scale).extend(1.0);
        return local;
    }
}

// The transform buildArmature applies to each matrix, the one the importer
// passes: `invWorld * toScene(m)`. A concrete class rather than
// an abstract one: rasc 1.1.0 miscompiles a virtual call whose signature
// holds a struct (the module then fails to load with "type mismatch: expect
// f32 but got other").
export class ToArm {
    invWorld: Mat4;
    toScene: ToScene;
    constructor(invWorld: Mat4, toScene: ToScene) {
        this.invWorld = invWorld;
        this.toScene = toScene;
    }
    apply(m: Mat4): Mat4 {
        return this.invWorld * this.toScene.apply(m);
    }
}

// Fill `arm` with one bone per joint and pose it like the file. `toArm`
// takes a glTF-space matrix to the armature object's local space (axis
// conversion, unit scale, the armature's world inverse). Returns the bone
// names in joint order.
export function buildArmature(arm: Armature, doc: Root, skin: SkinInfo, graph: NodeGraph, toArm: ToArm,
    carry: bool = false): Array<string> {
    const n = skin.joints.length;
    const bind: Array<Mat4> = [];
    for (let j = 0; j < n; j++) bind.push(toArm.apply(skin.inverseBind[j].inverse()));
    skin.armBind = bind;
    const target: Array<Mat4> = [];
    for (let j = 0; j < n; j++) target.push(toArm.apply(graph.global[skin.joints[j]]));
    const parent: Array<i32> = [];
    for (let j = 0; j < n; j++) {
        const p = graph.parent[skin.joints[j]];
        parent.push(p >= 0 && skin.jointOfNode.has(p) ? skin.jointOfNode.get(p) : -1);
    }
    const children: Array<Array<i32>> = [];
    for (let j = 0; j < n; j++) children.push([]);
    for (let j = 0; j < n; j++) {
        const p = parent[j];
        if (p >= 0) children[p].push(j);
    }
    // Parents first: depth within the skin, then joint order. The keys are
    // distinct, so `sort_unstable` has one answer.
    const order: Array<i32> = [];
    const depthOf: Array<i32> = [];
    for (let j = 0; j < n; j++) {
        let d = 0;
        let x = j;
        while (parent[x] >= 0) {
            d += 1;
            x = parent[x];
            if (d > n) break;
        }
        depthOf.push(d);
        order.push(j);
    }
    order.sort((a: i32, b: i32): i32 => {
        if (depthOf[a] != depthOf[b]) return depthOf[a] < depthOf[b] ? -1 : 1;
        return a < b ? -1 : (a > b ? 1 : 0);
    });

    const ids: Array<u32> = [];
    const names: Array<string> = [];
    for (let j = 0; j < n; j++) {
        ids.push(NO_BONE);
        names.push("");
    }
    for (let oi = 0; oi < order.length; oi++) {
        const j = order[oi];
        const head = bind[j].wAxis.truncate();
        let parentBone: Bone? = null;
        if (parent[j] >= 0 && ids[parent[j]] != NO_BONE) parentBone = arm.bones.at(ids[parent[j]]).clone();
        const heads: Array<Vec3> = [];
        const ch = children[j];
        for (let k = 0; k < ch.length; k++) heads.push(bind[ch[k]].wAxis.truncate());
        let tail = VEC3_NAN;
        if (heads.length > 0) tail = Vec3.sum(heads) / <f32>heads.length;
        if (!tail.isFinite() || tail.distance(head) < <f32>1e-6) {
            let len: f32 = 0.2;
            if (parentBone != null) {
                const l = parentBone.length();
                if (l > <f32>1e-6) len = l;
            }
            const dir = bind[j].yAxis.truncate().normalizeOr(VEC3_Z);
            tail = head + dir * len;
        }
        const nodeName = doc.nodes[skin.joints[j]].name;
        const name = arm.uniqueName(nodeName != null ? nodeName : "Bone");
        const bone = Bone.create(name, head, tail);
        bone.roll = rollToVector(head, tail, bind[j].zAxis.truncate(), false);
        bone.parent = parent[j] >= 0 ? ids[parent[j]] : NO_BONE;
        bone.connected = parentBone != null && parentBone.tail.distance(head) < <f32>1e-4;
        const id = arm.bones.push(bone);
        ids[j] = id;
        names[j] = name;
    }
    // Whether some joint's frame is not its bone's rest frame (the header);
    // only asked for when the caller carries frames over
    // (ImportOpts.carryJointFrames: Hedra's own import keeps the reference
    // importer's channels).
    for (let oi = 0; carry && oi < order.length && !skin.corrected; oi++) {
        const j = order[oi];
        if (ids[j] == NO_BONE) continue;
        if (!isIdentity(bind[j].inverse() * arm.bones.at(ids[j]).restMatrix())) skin.corrected = true;
    }
    // Pose channels: `pose = parent_pose * parent_rest^-1 * rest * basis`
    // (roots: `pose = rest * basis`), the parent's pose being what the
    // channel will actually produce (connected bones drop their location).
    const effective: Array<Mat4> = [];
    for (let j = 0; j < n; j++) effective.push(MAT4_IDENTITY);
    for (let oi = 0; oi < order.length; oi++) {
        const j = order[oi];
        const id = ids[j];
        if (id == NO_BONE) continue;
        const rest = arm.bones.at(id).restMatrix();
        let space: Mat4;
        const p = parent[j];
        if (p >= 0 && ids[p] != NO_BONE) {
            space = effective[p] * arm.bones.at(ids[p]).restMatrix().inverse() * rest;
        } else {
            space = rest;
        }
        const basis = space.inverse() * target[j];
        const srt = basis.toScaleRotationTranslation();
        const s = srt.scale;
        const bone = arm.bones.at(id);
        let t = srt.translation;
        if (bone.connected) t = VEC3_ZERO;
        const r = srt.rotation.normalize();
        if (!t.absDiffEq(VEC3_ZERO, <f32>1e-5)
            || !r.absDiffEq(QUAT_IDENTITY, <f32>1e-5)
            || !s.absDiffEq(VEC3_ONE, <f32>1e-5)) {
            bone.pose.location = t;
            bone.pose.rotation = r;
            bone.pose.scale = s;
        }
        effective[j] = space * bone.pose.basis(bone.connected);
    }
    if (arm.active == NO_BONE) {
        arm.active = order.length > 0 ? ids[order[0]] : NO_BONE;
    }
    if (skin.corrected) {
        // Some joint's frame is not its bone's: every channel again, each
        // bone posed at its joint's frame carried over (see the header).
        for (let oi = 0; oi < order.length; oi++) {
            const j = order[oi];
            const id = ids[j];
            if (id == NO_BONE) continue;
            arm.bones.at(id).pose.clear();
        }
        for (let oi = 0; oi < order.length; oi++) {
            const j = order[oi];
            const id = ids[j];
            if (id == NO_BONE) continue;
            const bone = arm.bones.at(id);
            const rest = bone.restMatrix();
            let space: Mat4;
            const p = parent[j];
            if (p >= 0 && ids[p] != NO_BONE) {
                space = effective[p] * arm.bones.at(ids[p]).restMatrix().inverse() * rest;
            } else {
                space = rest;
            }
            const posed = target[j] * bind[j].inverse() * rest;
            const srt = (space.inverse() * posed).toScaleRotationTranslation();
            let t = srt.translation;
            if (bone.connected) t = VEC3_ZERO;
            const r = srt.rotation.normalize();
            const sc = srt.scale;
            if (!t.absDiffEq(VEC3_ZERO, <f32>1e-5) || !r.absDiffEq(QUAT_IDENTITY, <f32>1e-5) || !sc.absDiffEq(VEC3_ONE, <f32>1e-5)) {
                bone.pose.location = t;
                bone.pose.rotation = r;
                bone.pose.scale = sc;
            }
            effective[j] = space * bone.pose.basis(bone.connected);
        }
    }
    arm.touch();
    return names;
}

// Whether `m` is the identity within 1e-5 an entry: a joint frame that
// matches its bone's to the precision the importer keeps a pose channel at.
function isIdentity(m: Mat4): bool {
    const a = m.toColsArray();
    for (let i = 0; i < 16; i++) {
        const want: f32 = i % 5 == 0 ? 1 : 0;
        if (Mathf.abs(a[i] - want) > <f32>1e-5) return false;
    }
    return true;
}
