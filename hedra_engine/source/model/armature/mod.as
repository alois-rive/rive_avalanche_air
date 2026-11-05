// Armature data. Bones in slot storage with
// stable ids, edit state (selection, active bone), pose channels with
// constraints, bone collections and the rest / pose matrix math with
// Blender's conventions (a bone's local Y axis runs head -> tail, `roll`
// turns about it).
//
// Pose evaluation lives in pose.as, constraints in constraints.as, the IK
// solver in ik.as, `.L` / `.R` name handling in names.as.
//
// Conventions:
//   * An optional bone id (Bone.parent, Armature.active, find()) is a u32
//     with the sentinel NO_BONE (u32.MAX_VALUE) for "none".
//   * Bone, PoseBone, BoneCollection, Armature are classes: call clone()
//     wherever a copy is meant; `equals()` compares field by field
//     (Armature has none).
//   * `Bone.create(name, head, tail)` makes a bone with Blender's defaults;
//     `new Bone()` is the all-default bone. `new Armature()` stamps a fresh
//     revision.
//   * Field order is the postcard file format.

import { Vec3, Mat3, Mat4, Quat, VEC3_ZERO, VEC3_ONE, VEC3_Y, VEC3_Z, VEC3_NEG_X, VEC3_NEG_Y, VEC3_MIN, VEC3_MAX, QUAT_IDENTITY, atan2f } from "../../../base/vecmath";
import { SlotVec } from "../../../base/slot";
import { toAsciiLowercase, stableSort, cmpStr, signumF32, maxF32 } from "../../../base/util";
import { zeroPad } from "../../../base/fmt";
import { editDistance } from "../scene";
import { Constraint } from "./constraints";
import { PoseEval, TargetFn, restEval as poseRestEval, evaluatePose as poseEvaluatePose } from "./pose";

export {
    Constraint, ConstraintKind, ConstraintKindTag, ConstraintSpace, ConstraintTarget, RotationMix, TrackAxis,
} from "./constraints";
export { PoseEval } from "./pose";

// BoneId = u32.
export type BoneId = u32;

// "No bone".
export const NO_BONE: u32 = u32.MAX_VALUE;

const F32_PI: f32 = 3.14159265358979323846;
const F32_FRAC_PI_2: f32 = 1.57079632679489661923;

// Per-bone pose channel. The rotation is a quaternion internally; the
// command boundary speaks Euler XYZ degrees.
export class PoseBone {
    location: Vec3 = Vec3(0, 0, 0);
    rotation: Quat = Quat(0, 0, 0, 1);
    scale: Vec3 = Vec3(1, 1, 1);
    constraints: Array<Constraint> = [];
    select: bool = false;
    hide: bool = false;

    // Local (bone space) matrix of the channel. Connected bones ignore
    // their location like Blender (the head is tied to the parent's tail).
    basis(connected: bool): Mat4 {
        const loc = connected ? VEC3_ZERO : this.location;
        return Mat4.fromScaleRotationTranslation(this.scale, this.rotation.normalize(), loc);
    }

    isIdentity(): bool {
        return this.location == VEC3_ZERO && this.rotation == QUAT_IDENTITY && this.scale == VEC3_ONE;
    }

    clear(): void {
        this.location = VEC3_ZERO;
        this.rotation = QUAT_IDENTITY;
        this.scale = VEC3_ONE;
    }

    clone(): PoseBone {
        const p = new PoseBone();
        p.location = this.location;
        p.rotation = this.rotation;
        p.scale = this.scale;
        const cs: Array<Constraint> = [];
        for (let i = 0; i < this.constraints.length; i++) cs.push(this.constraints[i].clone());
        p.constraints = cs;
        p.select = this.select;
        p.hide = this.hide;
        return p;
    }

    equals(o: PoseBone): bool {
        if (!(this.location == o.location && this.rotation == o.rotation && this.scale == o.scale)) return false;
        if (this.constraints.length != o.constraints.length) return false;
        for (let i = 0; i < this.constraints.length; i++) {
            if (!this.constraints[i].equals(o.constraints[i])) return false;
        }
        return this.select == o.select && this.hide == o.hide;
    }
}

export class Bone {
    name: string = "Bone";
    // Armature space.
    head: Vec3 = Vec3(0, 0, 0);
    tail: Vec3 = Vec3(0, 0, 1);
    // Radians, about the head -> tail axis.
    roll: f32 = 0;
    // NO_BONE = none.
    parent: u32 = NO_BONE;
    // Head tied to the parent's tail (Blender's "Connected").
    connected: bool = false;
    deform: bool = true;
    inheritRotation: bool = true;
    inheritScale: bool = true;
    // Envelope falloff distance outside the head/tail radii.
    envelopeDistance: f32 = 0.25;
    envelopeWeight: f32 = 1.0;
    headRadius: f32 = 0.1;
    tailRadius: f32 = 0.05;
    // Names of the bone collections this bone belongs to.
    collections: Array<string> = [];
    // Edit-mode selection: whole bone, head, tail.
    select: bool = false;
    selectHead: bool = false;
    selectTail: bool = false;
    hide: bool = false;
    pose: PoseBone = new PoseBone();

    // A bone with Blender's defaults for a freshly added
    // bone of this size (radii scale with the length).
    static create(name: string, head: Vec3, tail: Vec3): Bone {
        const len = (tail - head).length();
        const b = new Bone();
        b.name = name;
        b.head = head;
        b.tail = tail;
        b.headRadius = maxF32(len * <f32>0.1, <f32>1e-4);
        b.tailRadius = maxF32(len * <f32>0.05, <f32>1e-4);
        b.envelopeDistance = maxF32(len * <f32>0.25, <f32>1e-4);
        return b;
    }

    length(): f32 {
        return (this.tail - this.head).length();
    }

    direction(): Vec3 {
        return (this.tail - this.head).normalizeOrZero();
    }

    // Rest orientation in armature space (columns X, Y = head -> tail, Z).
    restRotation(): Mat3 {
        return vecRollToMat3(this.tail - this.head, this.roll);
    }

    // Blender's `matrix_local`: rest pose in armature space.
    restMatrix(): Mat4 {
        const m = Mat4.fromMat3(this.restRotation());
        return Mat4.fromTranslation(this.head) * m;
    }

    // Whole-bone selection flag consistent with head/tail flags.
    setSelect(on: bool): void {
        this.select = on;
        this.selectHead = on;
        this.selectTail = on;
    }

    anySelected(): bool {
        return this.select || this.selectHead || this.selectTail;
    }

    clone(): Bone {
        const b = new Bone();
        b.name = this.name;
        b.head = this.head;
        b.tail = this.tail;
        b.roll = this.roll;
        b.parent = this.parent;
        b.connected = this.connected;
        b.deform = this.deform;
        b.inheritRotation = this.inheritRotation;
        b.inheritScale = this.inheritScale;
        b.envelopeDistance = this.envelopeDistance;
        b.envelopeWeight = this.envelopeWeight;
        b.headRadius = this.headRadius;
        b.tailRadius = this.tailRadius;
        b.collections = this.collections.slice(0);
        b.select = this.select;
        b.selectHead = this.selectHead;
        b.selectTail = this.selectTail;
        b.hide = this.hide;
        b.pose = this.pose.clone();
        return b;
    }

    equals(o: Bone): bool {
        if (this.collections.length != o.collections.length) return false;
        for (let i = 0; i < this.collections.length; i++) {
            if (this.collections[i] != o.collections[i]) return false;
        }
        return this.name == o.name && this.head == o.head && this.tail == o.tail && this.roll == o.roll
            && this.parent == o.parent && this.connected == o.connected && this.deform == o.deform
            && this.inheritRotation == o.inheritRotation && this.inheritScale == o.inheritScale
            && this.envelopeDistance == o.envelopeDistance && this.envelopeWeight == o.envelopeWeight
            && this.headRadius == o.headRadius && this.tailRadius == o.tailRadius
            && this.select == o.select && this.selectHead == o.selectHead && this.selectTail == o.selectTail
            && this.hide == o.hide && this.pose.equals(o.pose);
    }
}

// Default: Octahedral.
export enum BoneDisplay {
    Octahedral = 0,
    Stick = 1,
}

// Parses a BoneDisplay name; -1 when unknown.
export function boneDisplayParse(s: string): i32 {
    const l = toAsciiLowercase(s);
    if (l == "octahedral" || l == "octahedron" || l == "octa") return BoneDisplay.Octahedral;
    if (l == "stick" || l == "sticks") return BoneDisplay.Stick;
    return -1;
}

export function boneDisplayName(d: BoneDisplay): string {
    return d == BoneDisplay.Octahedral ? "octahedral" : "stick";
}

export class BoneCollection {
    name: string = "";
    hide: bool = false;

    constructor(name: string = "", hide: bool = false) {
        this.name = name;
        this.hide = hide;
    }

    clone(): BoneCollection {
        return new BoneCollection(this.name, this.hide);
    }

    equals(o: BoneCollection): bool {
        return this.name == o.name && this.hide == o.hide;
    }
}

// Process-global revision counter (separate from the mesh counter).
let NEXT_REVISION: u64 = 1;

function freshRevision(): u64 {
    const r = NEXT_REVISION;
    NEXT_REVISION += 1;
    return r;
}

// Extent of the rest skeleton.
export class BoneBounds {
    lo: Vec3;
    hi: Vec3;
    constructor(lo: Vec3, hi: Vec3) {
        this.lo = lo;
        this.hi = hi;
    }
}

export class Armature {
    bones: SlotVec<Bone> = new SlotVec<Bone>();
    // Active bone (edit and pose mode); NO_BONE = none.
    active: u32 = NO_BONE;
    display: BoneDisplay = BoneDisplay.Octahedral;
    collections: Array<BoneCollection> = [];
    // Process-unique stamp, bumped by every mutation (see `Mesh.revision`);
    // render and modifier caches key on it. Not serialized.
    revision: u64 = 0;

    // Stamps a fresh revision. `stamp = false` leaves the revision at 0
    // without drawing from the counter (clone() copies the source's revision
    // instead; a decoder calls afterLoad(), since the revision is not saved).
    constructor(stamp: bool = true) {
        if (stamp) this.revision = freshRevision();
    }

    // Blender's new armature: one bone "Bone" from the origin to +Z.
    static withDefaultBone(): Armature {
        const a = new Armature();
        const bone = Bone.create("Bone", VEC3_ZERO, VEC3_Z);
        bone.setSelect(true);
        const id = a.bones.push(bone);
        a.active = id;
        return a;
    }

    // Deep copy, the revision included (no counter draw).
    clone(): Armature {
        const a = new Armature(false);
        a.bones = this.bones.map<Bone>((b: Bone): Bone => b.clone());
        a.active = this.active;
        a.display = this.display;
        const cs: Array<BoneCollection> = [];
        for (let i = 0; i < this.collections.length; i++) cs.push(this.collections[i].clone());
        a.collections = cs;
        a.revision = this.revision;
        return a;
    }

    touch(): void {
        this.revision = freshRevision();
    }

    afterLoad(): void {
        this.touch();
    }

    // First bone (in id order) with this name, or NO_BONE.
    find(name: string): u32 {
        const n = this.bones.idBound();
        for (let id: u32 = 0; id < n; id++) {
            const b = this.bones.get(id);
            if (b != null && b.name == name) return id;
        }
        return NO_BONE;
    }

    nameOf(id: u32): string {
        const b = this.bones.get(id);
        return b != null ? b.name : "";
    }

    // "did you mean" hint for a missing bone name.
    nameHint(name: string): string {
        const bs = this.bones.values();
        const names: Array<string> = [];
        for (let i = 0; i < bs.length; i++) names.push(bs[i].name);
        if (names.length == 0) {
            return "the armature has no bones; `bone add <name> --head x y z --tail x y z` adds one";
        }
        const scored: Array<ScoredName> = [];
        for (let i = 0; i < names.length; i++) scored.push(new ScoredName(editDistance(names[i], name), names[i]));
        stableSort<ScoredName>(scored, (x: ScoredName, y: ScoredName): i32 => {
            if (x.dist != y.dist) return x.dist < y.dist ? -1 : 1;
            return cmpStr(x.name, y.name);
        });
        if (scored[0].dist <= 3) {
            return "did you mean '" + scored[0].name + "'? `bone list` shows all bones";
        }
        const shown: Array<string> = [];
        for (let i = 0; i < names.length && i < 10; i++) shown.push(names[i]);
        stableSort<string>(shown, cmpStr);
        const more = names.length > 10 ? ", ..." : "";
        return "bones: " + shown.join(", ") + more;
    }

    // Blender-style unique bone naming (`Bone`, `Bone.001`, ...).
    uniqueName(base: string): string {
        if (this.find(base) == NO_BONE) return base;
        let stem = base;
        const i = base.lastIndexOf(".");
        if (i >= 0) {
            const tail = base.substring(i + 1);
            if (tail.length == 3 && isAsciiDigits(tail)) stem = base.substring(0, i);
        }
        for (let n = 1; n < 10000; n++) {
            const candidate = stem + "." + zeroPad(n, 3);
            if (this.find(candidate) == NO_BONE) return candidate;
        }
        return stem + "." + this.bones.idBound().toString();
    }

    children(parent: u32): Array<u32> {
        const out: Array<u32> = [];
        const n = this.bones.idBound();
        for (let id: u32 = 0; id < n; id++) {
            const b = this.bones.get(id);
            if (b != null && b.parent != NO_BONE && b.parent == parent) out.push(id);
        }
        return out;
    }

    // Every descendant, depth first in id order.
    descendants(root: u32): Array<u32> {
        const out: Array<u32> = [];
        const stack = this.children(root);
        stack.reverse();
        while (stack.length > 0) {
            const b = stack.pop();
            out.push(b);
            const kids = this.children(b);
            kids.reverse();
            for (let i = 0; i < kids.length; i++) stack.push(kids[i]);
        }
        return out;
    }

    isAncestor(ancestor: u32, of: u32): bool {
        let cur = this.parentOf(of);
        let guard = 0;
        while (cur != NO_BONE) {
            if (cur == ancestor) return true;
            guard += 1;
            if (guard > 100000) break;
            cur = this.parentOf(cur);
        }
        return false;
    }

    // `bones.get(id).and_then(|b| b.parent)`.
    private parentOf(id: u32): u32 {
        const b = this.bones.get(id);
        return b != null ? b.parent : NO_BONE;
    }

    // Number of parents above a bone.
    depth(id: u32): i32 {
        let d = 0;
        let cur = this.parentOf(id);
        while (cur != NO_BONE) {
            d += 1;
            if (d > 100000) break;
            cur = this.parentOf(cur);
        }
        return d;
    }

    // Bone ids with parents before children (then by id), the order every
    // evaluation and dump uses.
    hierarchyOrder(): Array<u32> {
        const ids = this.bones.ids();
        const keyed: Array<DepthId> = [];
        for (let i = 0; i < ids.length; i++) keyed.push(new DepthId(this.depth(ids[i]), ids[i]));
        stableSort<DepthId>(keyed, (a: DepthId, b: DepthId): i32 => {
            if (a.depth != b.depth) return a.depth < b.depth ? -1 : 1;
            if (a.id != b.id) return a.id < b.id ? -1 : 1;
            return 0;
        });
        const out: Array<u32> = [];
        for (let i = 0; i < keyed.length; i++) out.push(keyed[i].id);
        return out;
    }

    // Deform bones in hierarchy order (the joints of a glTF skin).
    deformBones(): Array<u32> {
        const order = this.hierarchyOrder();
        const out: Array<u32> = [];
        for (let i = 0; i < order.length; i++) {
            if (this.bones.at(order[i]).deform) out.push(order[i]);
        }
        return out;
    }

    // Remove a bone; children are re-parented to its parent (Blender's
    // delete keeps the chain apart, `dissolve` merges; both come here
    // after the caller decided what to do with the geometry).
    removeBone(id: u32): Bone? {
        const bone = this.bones.get(id);
        if (bone == null) return null;
        const parent = bone.parent;
        const kids = this.children(id);
        for (let i = 0; i < kids.length; i++) {
            const c = this.bones.at(kids[i]);
            c.parent = parent;
            if (parent == NO_BONE) c.connected = false;
        }
        if (this.active != NO_BONE && this.active == id) this.active = NO_BONE;
        this.touch();
        return this.bones.remove(id);
    }

    // Ids of the bones selected in edit mode (any of the three flags).
    editSelected(): Array<u32> {
        const out: Array<u32> = [];
        const n = this.bones.idBound();
        for (let id: u32 = 0; id < n; id++) {
            const b = this.bones.get(id);
            if (b != null && b.anySelected() && !b.hide) out.push(id);
        }
        return out;
    }

    // Ids of the bones selected in pose mode.
    poseSelected(): Array<u32> {
        const out: Array<u32> = [];
        const n = this.bones.idBound();
        for (let id: u32 = 0; id < n; id++) {
            const b = this.bones.get(id);
            if (b != null && b.pose.select && !b.hide && !b.pose.hide) out.push(id);
        }
        return out;
    }

    // Roughly the extent of the rest skeleton, for framing (null when there is none).
    bounds(): BoneBounds? {
        let lo = VEC3_MAX;
        let hi = VEC3_MIN;
        const n = this.bones.idBound();
        for (let id: u32 = 0; id < n; id++) {
            const b = this.bones.get(id);
            if (b == null) continue;
            lo = lo.min(b.head).min(b.tail);
            hi = hi.max(b.head).max(b.tail);
        }
        return lo.x <= hi.x ? new BoneBounds(lo, hi) : null;
    }

    // Move the connected children's heads onto a bone's new tail after the
    // tail moved. Like Blender, only the shared point moves: a child's tail
    // stays where it is (its length changes).
    snapConnectedChildren(id: u32): void {
        const tail = this.bones.at(id).tail;
        const kids = this.children(id);
        for (let i = 0; i < kids.length; i++) {
            const c = this.bones.at(kids[i]);
            if (c.connected) c.head = tail;
        }
    }

    // Snap a connected bone's head onto its parent's tail.
    snapToParent(id: u32): void {
        const b = this.bones.at(id);
        const p = b.parent;
        if (p != NO_BONE && b.connected) {
            const tail = this.bones.at(p).tail;
            b.head = tail;
        }
    }

    // === pose evaluation: delegates to pose.as.

    // Rest matrices only (edit mode display, inverse bind matrices).
    restEval(): PoseEval {
        return poseRestEval(this);
    }

    // Full pose: channels, constraints, IK. `selfId` (NO_OBJ = none) lets
    // constraints target bones of this armature; `targets` resolves the rest.
    evaluatePose(selfId: u32, targets: TargetFn): PoseEval {
        return poseEvaluatePose(this, selfId, targets);
    }
}

class ScoredName {
    dist: i32;
    name: string;
    constructor(dist: i32, name: string) {
        this.dist = dist;
        this.name = name;
    }
}

class DepthId {
    depth: i32;
    id: u32;
    constructor(depth: i32, id: u32) {
        this.depth = depth;
        this.id = id;
    }
}

function isAsciiDigits(s: string): bool {
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 48 || c > 57) return false;
    }
    return true;
}

// Blender's `vec_roll_to_mat3`: the rotation whose Y axis is `vec`, built
// from the shortest arc that takes +Y to `vec`, then rolled about `vec`.
export function vecRollToMat3(vec: Vec3, roll: f32): Mat3 {
    const len = vec.length();
    const nor = len < <f32>1e-12 ? VEC3_Y : vec / len;
    const THETA_SAFE: f32 = 1.0e-5;
    const THETA_CRITICAL: f32 = 1.0e-9;
    const theta = <f32>1.0 + nor.y;
    let b: Mat3;
    if (theta > THETA_SAFE || ((nor.x != 0 || nor.z != 0) && theta > THETA_CRITICAL)) {
        let xx: f32;
        let zz: f32;
        let xz: f32;
        if (theta > THETA_SAFE) {
            xx = <f32>1.0 - nor.x * nor.x / theta;
            zz = <f32>1.0 - nor.z * nor.z / theta;
            xz = -nor.x * nor.z / theta;
        } else {
            // Nearly -Y: Blender's series expansion keeps the matrix
            // orthonormal where 1/theta would blow up.
            const z2 = nor.z * nor.z;
            const x2 = nor.x * nor.x;
            const s = x2 + z2;
            if (s < <f32>1e-30) {
                xx = 1.0;
                zz = 1.0;
                xz = 0.0;
            } else {
                xx = <f32>1.0 - <f32>2.0 * x2 / s;
                zz = <f32>1.0 - <f32>2.0 * z2 / s;
                xz = <f32>-2.0 * nor.x * nor.z / s;
            }
        }
        b = Mat3.fromCols(
            Vec3(xx, -nor.x, xz),
            Vec3(nor.x, nor.y, nor.z),
            Vec3(xz, -nor.z, zz),
        );
    } else {
        // Exactly -Y: a half turn about X.
        b = Mat3.fromCols(VEC3_NEG_X, VEC3_NEG_Y, VEC3_Z);
    }
    return Mat3.fromAxisAngle(nor, roll) * b;
}

// What mat3ToVecRoll returns: the bone vector and its roll.

export class VecRoll {
    nor: Vec3;
    roll: f32;
    constructor(nor: Vec3, roll: f32) {
        this.nor = nor;
        this.roll = roll;
    }
}

// Blender's `mat3_to_vec_roll`: the roll that reproduces `mat`'s X/Z axes
// given its Y axis (the matrix must be a rotation).
export function mat3ToVecRoll(mat: Mat3): VecRoll {
    const nor = mat.yAxis;
    const noRoll = vecRollToMat3(nor, 0.0);
    // Rotation about nor taking no_roll's Z axis to mat's Z axis.
    const z0 = noRoll.zAxis;
    const z1 = mat.zAxis;
    const roll = signedAngle(z0, z1, nor.normalizeOrZero());
    return new VecRoll(nor, roll);
}

// Signed angle from `a` to `b` about `axis` (all unit vectors).
export function signedAngle(a: Vec3, b: Vec3, axis: Vec3): f32 {
    const cross = a.cross(b);
    const s = cross.dot(axis);
    const c = a.dot(b);
    return atan2f(s, c);
}

// Blender's `ED_armature_ebone_roll_to_vector`: the roll that turns the
// bone's Z axis as close as possible to `align`.
export function rollToVector(head: Vec3, tail: Vec3, align: Vec3, axisOnly: bool): f32 {
    const nor = (tail - head).normalizeOrZero();
    if (nor == VEC3_ZERO) return 0.0;
    const mat = vecRollToMat3(nor, 0.0);
    const proj = align - nor * align.dot(nor);
    if (proj.lengthSquared() < <f32>1e-12) return 0.0;
    const vec = proj.normalize();
    let roll = signedAngle(mat.zAxis, vec, nor);
    if (axisOnly && Mathf.abs(roll) > F32_FRAC_PI_2) {
        roll -= F32_PI * signumF32(roll);
    }
    return roll;
}

// Shortest-arc rotation taking `from` to `to` (both non-zero), robust to
// the antiparallel case.
export function rotationBetween(from: Vec3, to: Vec3): Quat {
    const a = from.normalizeOrZero();
    const b = to.normalizeOrZero();
    if (a == VEC3_ZERO || b == VEC3_ZERO) return QUAT_IDENTITY;
    return Quat.fromRotationArc(a, b);
}
