// The data form's reader: data lines replayed into a scene that encodes to
// the bytes the written scene did. Each record builds what the codec's
// reader (engine/src/source/model/io/codec.as readScene) builds from the same
// fields: the same constructors, the same SlotVec.fromSlots with the holes
// kept and the live count given, the same defaults for what a line leaves
// out (words.as).
//
// The scene line comes first and declares the object and action slots, so
// every id a later line names is checked against them where it is read. A
// line may only name what an earlier line defined (a vertex group's object,
// a fcurve's action, a bone's armature), as the writer's order guarantees.
// What no single line can check, Replay.finish does: every declared slot
// filled, a mesh object given its mesh and an armature its bones.
//
// Errors are E_DATA at the line, with the record's form as the hint. Long
// number lists are read in place (num.as NumScanner), straight into the
// elements they build: nothing is kept per number but the number.

import { Vec2, Vec3, Vec4, Quat, Mat4, MAT4_IDENTITY } from "../../../../base/vecmath";
import { SlotVec } from "../../../../base/slot";
import { Result } from "../../../../base/util";
import { RmdlError, E_DATA } from "../format";
import { DataLine, Word, splitLine, recordOf } from "./line";
import { NumScanner } from "./num";
import {
    RECORDS, POSITIONALS, CAMERA_TYPES, PARENT_TYPES, MODIFIER_KINDS, TEXTURE_SLOTS, formHint, specsOf, wordIndex,
    sceneDefaults, materialDefaults, cameraDefaults, lightDefaults, boneDefaults, shapeKeyDefaults, renderDefaults,
} from "./words";
import { Mesh, Vert, Edge, Face, Loop, UvLayer, SelectionSet, ElemKind, ElemRef, GroupWeight } from "../../mesh/mod";
import { AttrLayer, AttrData, AttrType, Domain, DOMAINS } from "../../mesh/attr";
import { ShapeKey } from "../../mesh/shapekey";
import { SelectMode } from "../../mesh/select_mode";
import { Armature, Bone, BoneCollection, BoneDisplay, NO_BONE } from "../../armature/mod";
import {
    Constraint, ConstraintKind, ConstraintKindTag, ConstraintTarget, ConstraintSpace, RotationMix, TrackAxis,
    ConstraintKindIk, ConstraintKindCopyLocation, ConstraintKindCopyRotation, ConstraintKindCopyScale,
    ConstraintKindCopyTransforms, ConstraintKindLimitRotation, ConstraintKindLimitLocation, ConstraintKindTrackTo,
    ConstraintKindDampedTrack, ConstraintKindStretchTo, ConstraintKindChildOf, bool3, TYPES as CONSTRAINT_KINDS,
} from "../../armature/constraints";
import { Action, AnimData, ACTION_NONE } from "../../anim/mod";
import { FCurve, Keyframe, Interpolation, Easing, HandleType, Extrapolation } from "../../anim/fcurve";
import { PoseClip } from "../../armature/pose_clip";
import {
    Scene, Object, ObjectData, ObjectDataKind, Transform, Camera, CameraKind, Light, LightKind, Empty, EmptyDisplay,
    Parent, ParentKind, ParentKindTag, Modifier, ModifierKind, ModifierKindMirror, ModifierKindSubsurf,
    ModifierKindArray, ModifierKindSolidify, ModifierKindBevel, ModifierKindTriangulate, ModifierKindWeld,
    ModifierKindEdgeSplit, ModifierKindArmature, ModifierKindTool, ModifierKindInstance, ModifierKindExt, VertexGroup,
    Mode, Pivot, Orientation, AlphaMode, Material, MaterialTextures, TextureRef, RenderDefaults, ImportRecord,
    FrameRangeI32, NO_OBJ, NO_VGROUP,
} from "../../scene";

// The words of the scene's enums, in variant order (the scene's name
// functions write them).
const MODES: Array<string> = ["object", "edit", "pose", "weight"];
const PIVOTS: Array<string> = ["median", "individual", "cursor", "active", "bounding-box"];
const ORIENTATIONS: Array<string> = ["global", "local", "normal", "view"];
const ALPHA_MODES: Array<string> = ["opaque", "mask", "blend"];
const OBJECT_TYPES: Array<string> = ["mesh", "armature", "camera", "light", "empty"];
const LIGHT_TYPES: Array<string> = ["point", "sun", "spot", "area"];
const EMPTY_DISPLAYS: Array<string> = ["plain-axes", "arrows", "cube"];
const EXTRAPOLATIONS: Array<string> = ["constant", "linear", "cyclic"];
const ATTR_TYPES: Array<string> = ["float", "int", "bool", "vec3"];
const BONE_DISPLAYS: Array<string> = ["octahedral", "stick"];
const SPACES: Array<string> = ["world", "local"];
const MIXES: Array<string> = ["replace", "before", "after"];
const TRACK_AXES: Array<string> = ["x", "y", "z", "-x", "-y", "-z"];

// ------------------------------------------------------------ the kinds' flags

const CAMERA_FLAGS: Array<string> = ["camera-type", "focal-length", "ortho-scale", "clip-start", "clip-end"];
const LIGHT_FLAGS: Array<string> = ["light-type", "color", "energy"];
const EMPTY_FLAGS: Array<string> = ["empty-display", "empty-size", "instance"];

// The flags each modifier kind takes (by ModifierKindTag), besides --disabled.
const MODIFIER_FLAGS: Array<Array<string>> = [
    ["axis", "clipping", "merge", "merge-threshold"],
    ["levels", "render-levels"],
    ["count", "relative-offset", "constant-offset", "merge", "merge-threshold"],
    ["thickness", "offset", "even"],
    ["width", "segments", "angle-limit"],
    [],
    ["distance"],
    ["angle"],
    ["object", "preserve-volume", "use-vertex-groups", "use-envelopes"],
    ["tool", "param", "hash"],
    ["object", "scale", "scale-attr", "align", "rotation", "rotation-attr"],
    ["ext-kind", "prop"],
];

// The flags each constraint kind takes (by ConstraintKindTag), besides
// --influence, --disabled and --space.
const CONSTRAINT_FLAGS: Array<Array<string>> = [
    ["target", "subtarget", "pole", "pole-subtarget", "pole-angle", "chain-length", "iterations", "use-tail"],
    ["target", "subtarget", "axes", "invert", "offset"],
    ["target", "subtarget", "axes", "mix"],
    ["target", "subtarget", "axes"],
    ["target", "subtarget", "mix"],
    ["min", "max", "axes"],
    ["min", "max", "use-min", "use-max"],
    ["target", "subtarget", "track", "up"],
    ["target", "subtarget", "track"],
    ["target", "subtarget", "rest-length", "volume"],
    ["target", "subtarget", "inverse"],
];

// ------------------------------------------------------------ one line's values

// Reads a split line's values, keeping the first error (`failed`, `message`,
// and `flag`, the flag it is about or "") so that a record reads every field
// and checks once.
//
// Messages name a flag as a data line spells it (`--co`), or, for a record
// read from an .rmdl document, as the document's property (`names`: the
// flag's property, else the flag in snake case: `co`, `edge_verts`).
class Values {
    d: DataLine;
    // A bound on how many elements the record can describe (DataLine.size).
    size: i32;
    failed: bool = false;
    message: string = "";
    flag: string = "";
    names: Map<string, string>? = null;

    constructor(d: DataLine, size: i32) {
        this.d = d;
        this.size = size;
    }

    fail(message: string, flag: string = ""): void {
        if (!this.failed) {
            this.failed = true;
            this.message = message;
            this.flag = flag;
        }
    }

    // A flag's name in a message.
    f(name: string): string {
        const m = this.names;
        if (m == null) return "--" + name;
        return m.has(name) ? m.get(name) : name.replaceAll("-", "_");
    }

    has(name: string): bool {
        return this.d.has(name);
    }

    // A scanner's error, as this flag's.
    check(name: string, s: NumScanner): void {
        if (s.failed) this.fail(this.f(name) + ": " + s.error, name);
        else if (!s.atEnd()) this.fail(this.f(name) + " holds more numbers than it should", name);
    }

    // ---- positionals

    posText(i: i32): string {
        return this.d.positionals[i].text();
    }

    posU32(i: i32, what: string): u32 {
        const s = this.d.positionals[i].numbers();
        const v = s.nextU32();
        if (s.failed || !s.atEnd()) {
            this.fail("the " + what + " `" + this.posText(i) + "` is not a whole number");
            return 0;
        }
        return v;
    }

    // ---- one-value flags

    word(name: string): Word? {
        return this.d.value(name);
    }

    str(name: string, dflt: string): string {
        const w = this.d.value(name);
        return w != null ? w.text() : dflt;
    }

    optStr(name: string): string? {
        const w = this.d.value(name);
        return w != null ? w.text() : null;
    }

    f32(name: string, dflt: f32): f32 {
        const w = this.d.value(name);
        if (w == null) return dflt;
        const s = w.numbers();
        const v = s.nextF32();
        this.check(name, s);
        return v;
    }

    u32(name: string, dflt: u32): u32 {
        const w = this.d.value(name);
        if (w == null) return dflt;
        const s = w.numbers();
        const v = s.nextU32();
        this.check(name, s);
        return v;
    }

    i32(name: string, dflt: i32): i32 {
        const w = this.d.value(name);
        if (w == null) return dflt;
        const s = w.numbers();
        const v = s.nextI32();
        this.check(name, s);
        return v;
    }

    u64(name: string, dflt: u64): u64 {
        const w = this.d.value(name);
        if (w == null) return dflt;
        const s = w.numbers();
        const v = s.nextU64();
        this.check(name, s);
        return v;
    }

    // An id below `bound`, or `none` for the word `none` (or when absent).
    id(name: string, bound: u32, none: u32, what: string): u32 {
        const w = this.d.value(name);
        if (w == null || w.is("none")) return none;
        const s = w.numbers();
        const v = s.nextU32();
        this.check(name, s);
        if (!this.failed && v >= bound) {
            this.fail(this.f(name) + " " + v.toString() + " is out of range: " + rangeText(bound, what), name);
        }
        return v;
    }

    // One of `words`, as its index; `dflt` when absent.
    choice(name: string, words: Array<string>, dflt: i32): i32 {
        const w = this.d.value(name);
        if (w == null) return dflt;
        for (let i = 0; i < words.length; i++) if (w.is(words[i])) return i;
        this.fail(this.f(name) + " takes " + words.join(", ") + ", not `" + w.text() + "`", name);
        return dflt;
    }

    // ---- number lists

    // A scanner over a flag's list, which must hold exactly `n` numbers;
    // null when the flag is absent.
    list(name: string, n: i32, what: string): NumScanner? {
        const w = this.d.value(name);
        if (w == null) return null;
        const s = w.numbers();
        const got = s.count();
        if (got != n) {
            this.fail(this.f(name) + " holds " + got.toString() + " numbers, " + n.toString() + " expected (" + what + ")", name);
            return null;
        }
        return s;
    }

    // A scanner over a flag's list of any length; null when absent.
    anyList(name: string): NumScanner? {
        const w = this.d.value(name);
        if (w == null) return null;
        return w.numbers();
    }

    f32s(name: string, dflt: Array<f32>): Array<f32> {
        const n = dflt.length;
        const s = this.list(name, n, n.toString() + " numbers");
        if (s == null) return dflt.slice(0);
        const out: Array<f32> = [];
        for (let i = 0; i < n; i++) out.push(s.nextF32());
        this.check(name, s);
        return out;
    }

    vec3(name: string, dflt: Vec3): Vec3 {
        const s = this.list(name, 3, "x y z");
        if (s == null) return dflt;
        const x = s.nextF32();
        const y = s.nextF32();
        const z = s.nextF32();
        this.check(name, s);
        return Vec3(x, y, z);
    }

    quat(name: string, dflt: Quat): Quat {
        const s = this.list(name, 4, "x y z w");
        if (s == null) return dflt;
        const x = s.nextF32();
        const y = s.nextF32();
        const z = s.nextF32();
        const w = s.nextF32();
        this.check(name, s);
        return Quat(x, y, z, w);
    }

    // Three 0/1 flags, as a fresh bool3.
    bits3(name: string, dx: bool, dy: bool, dz: bool): Array<bool> {
        const s = this.list(name, 3, "x y z, each 0 or 1");
        if (s == null) return bool3(dx, dy, dz);
        const x = s.nextBit();
        const y = s.nextBit();
        const z = s.nextBit();
        this.check(name, s);
        return bool3(x, y, z);
    }

    // 16 numbers, column major; identity when absent.
    mat4(name: string): Mat4 {
        const s = this.list(name, 16, "a 4x4 matrix, column major");
        if (s == null) return MAT4_IDENTITY;
        const a = Vec4(s.nextF32(), s.nextF32(), s.nextF32(), s.nextF32());
        const b = Vec4(s.nextF32(), s.nextF32(), s.nextF32(), s.nextF32());
        const c = Vec4(s.nextF32(), s.nextF32(), s.nextF32(), s.nextF32());
        const d = Vec4(s.nextF32(), s.nextF32(), s.nextF32(), s.nextF32());
        this.check(name, s);
        return Mat4(a, b, c, d);
    }

    u32s(name: string): Array<u32> {
        const s = this.anyList(name);
        const out: Array<u32> = [];
        if (s == null) return out;
        const n = s.count();
        for (let i = 0; i < n; i++) out.push(s.nextU32());
        this.check(name, s);
        return out;
    }

    // A slot count: at most `max`, so that a garbled count is an error and
    // not an allocation of gigabytes.
    slots(name: string, max: u32): u32 {
        const n = this.u32(name, 0);
        if (n > max) this.fail(this.f(name) + " " + n.toString() + " is more slots than the data form allows here (" + max.toString() + ")", name);
        return this.failed ? 0 : n;
    }

    // A slot list's holes: ascending ids below `n`.
    holes(name: string, n: u32): Array<u32> {
        const h = this.u32s(name);
        for (let i = 0; i < h.length && !this.failed; i++) {
            if (h[i] >= n) this.fail(this.f(name) + " names " + h[i].toString() + ", past the " + n.toString() + " slots", name);
            else if (i > 0 && h[i] <= h[i - 1]) this.fail(this.f(name) + " is not in ascending order", name);
        }
        return h;
    }

    // Only the flags in `allowed` (or `common`) are given; `what` names the
    // kind for the message.
    only(allowed: Array<string>, common: Array<string>, what: string): void {
        const fs = this.d.flags;
        for (let i = 0; i < fs.length && !this.failed; i++) {
            if (wordIndex(allowed, fs[i]) < 0 && wordIndex(common, fs[i]) < 0) this.fail(this.f(fs[i]) + " is not a flag of " + what, fs[i]);
        }
    }
}

function rangeText(bound: u32, what: string): string {
    return bound == 0 ? "there are no " + what : what + " run from 0 to " + (bound - 1).toString();
}

// ------------------------------------------------------------ the replay

// The most object, action or bone slots a scene line or an armature line may
// declare: far past any model (a slot is an id ever handed out), and a
// bound on what a garbled count can make the reader allocate.
const MAX_SLOTS: u32 = 1 << 24;

// An armature being read: its slots, and the line that filled each.
class ArmState {
    line: i32;
    arm: Armature;
    slots: Array<Bone?>;
    holes: Array<u32>;
    boneLines: Array<i32>;

    constructor(line: i32, arm: Armature, slots: Array<Bone?>, holes: Array<u32>) {
        this.line = line;
        this.arm = arm;
        this.slots = slots;
        this.holes = holes;
        this.boneLines = new Array<i32>(slots.length);
    }
}

function isHole(holes: Array<u32>, id: u32): bool {
    // Holes are ascending: a binary search.
    let lo = 0;
    let hi = holes.length;
    while (lo < hi) {
        const mid = (lo + hi) >> 1;
        const h = holes[mid];
        if (h == id) return true;
        if (h < id) lo = mid + 1;
        else hi = mid;
    }
    return false;
}

// "A -> B -> A" when bone `start`'s parents come back to it, else "" (as
// Replay.objectLoop for objects; every parent is known to name a bone).
function boneLoop(slots: Array<Bone?>, start: u32): string {
    const names: Array<string> = [slots[<i32>start]!.name];
    let at = start;
    for (let step = 0; step < slots.length; step++) {
        const b = slots[<i32>at];
        if (b == null || b.parent == NO_BONE || b.parent >= <u32>slots.length) return "";
        at = b.parent;
        const next = slots[<i32>at];
        if (next == null) return "";
        names.push(next.name);
        if (at == start) return names.join(" -> ");
    }
    return "";
}

// The state of a data-form replay (mod.as DataReplay is its face).
export class Replay {
    file: string;
    scene: Scene? = null;
    sceneLine: i32 = 0;
    finished: bool = false;
    // Objects: the slots (shared with scene.objects), the holes, the line
    // that defined each, and the line of each mesh object's `data mesh`.
    objSlots: Array<Object?> = [];
    objHoles: Array<u32> = [];
    objLines: Array<i32> = [];
    meshLines: Array<i32> = [];
    arms: Map<u32, ArmState> = new Map<u32, ArmState>();
    actSlots: Array<Action?> = [];
    actHoles: Array<u32> = [];
    actLines: Array<i32> = [];
    // Records read from an .rmdl document (../../rmdl/elements.as) rather
    // than data lines: messages name each flag by `names` (the document's
    // property names of the record being applied, set before each
    // applySplit; Values.f) and carry neither the `data <record>: ` prefix
    // nor the record's form as a hint (a document has no data lines).
    document: bool = false;
    names: Map<string, string>? = null;
    // After a failure: the flag it is about ("" for none), so that a
    // document's reader can point at that property's value.
    failedFlag: string = "";

    constructor(file: string) {
        this.file = file;
    }

    private error<T>(line: i32, record: string, message: string): Result<T> {
        if (this.document) return new RmdlError(E_DATA, this.file, line, message, "").fail<T>();
        const r = record.length > 0 ? "data " + record + ": " : "";
        return new RmdlError(E_DATA, this.file, line, r + message, formHint(record)).fail<T>();
    }

    apply(text: string, line: i32): Result<bool> {
        if (this.finished) return this.error<bool>(line, "", "a data line after the data form was finished");
        const record = recordOf(text);
        const ri = wordIndex(RECORDS, record);
        if (ri < 0) {
            return this.error<bool>(line, "", record.length > 0 ? "unknown data record `" + record + "`" : "a data line names no record");
        }
        if (ri == 0) {
            if (this.scene != null) {
                return this.error<bool>(line, record, "a second data scene (the first is at line " + this.sceneLine.toString() + ")");
            }
        } else if (this.scene == null) {
            return this.error<bool>(line, record, "the data form starts with `data scene`");
        }
        const d = splitLine(text, POSITIONALS[ri], specsOf(ri));
        if (d.error.length > 0) return this.error<bool>(line, record, d.error);
        d.size = text.length;
        return this.applySplit(ri, d, line, 0);
    }

    // A record already split (`ri` its index in RECORDS): what apply does
    // once it has split a line, and what an .rmdl document's reader calls
    // with the records it builds from its elements (their words are the
    // document's text, their numbers read in comma mode). `line` is where
    // errors say it is; `col` is the caller's (an RmdlError has no column:
    // the document's reader keeps its own positions). The scene record
    // must come first, as for apply.
    applySplit(ri: i32, d: DataLine, line: i32, col: i32): Result<bool> {
        this.failedFlag = "";
        const record = ri >= 0 && ri < RECORDS.length ? RECORDS[ri] : "";
        if (this.finished) return this.error<bool>(line, "", "a data line after the data form was finished");
        if (record.length == 0) return this.error<bool>(line, "", "a data line names no record");
        if (ri == 0) {
            if (this.scene != null) {
                return this.error<bool>(line, record, "a second data scene (the first is at line " + this.sceneLine.toString() + ")");
            }
        } else if (this.scene == null) {
            return this.error<bool>(line, record, "the data form starts with `data scene`");
        }
        const v = new Values(d, d.size > 0 ? d.size : 0);
        v.names = this.names;
        switch (ri) {
            case 0: this.readScene(v, line); break;
            case 1: this.readMaterial(v); break;
            case 2: this.readAction(v, line); break;
            case 3: this.readFCurve(v); break;
            case 4: this.readObject(v, line); break;
            case 5: this.readVgroup(v); break;
            case 6: this.readModifier(v); break;
            case 7: this.readMesh(v, line); break;
            case 8: this.readShapeKey(v); break;
            case 9: this.readAttribute(v); break;
            case 10: this.readSelectionSet(v); break;
            case 11: this.readArmature(v, line); break;
            case 12: this.readBone(v, line); break;
            case 13: this.readConstraint(v); break;
            case 14: this.readPoseClip(v); break;
            default: this.readImport(v); break;
        }
        if (v.failed) {
            this.failedFlag = v.flag;
            return this.error<bool>(line, record, v.message);
        }
        return Result.okv<bool>(true);
    }

    finish(): Result<Scene> {
        if (this.finished) return this.error<Scene>(0, "", "the data form was already finished");
        this.finished = true;
        const s = this.scene;
        if (s == null) return this.error<Scene>(0, "", "no data scene line: the data form starts with `data scene`");
        for (let i = 0; i < this.objSlots.length; i++) {
            const id = <u32>i;
            if (isHole(this.objHoles, id)) continue;
            const o = this.objSlots[i];
            if (o == null) {
                return this.error<Scene>(this.sceneLine, "scene", "object " + id.toString() + " is declared (--objects "
                    + this.objSlots.length.toString() + ") but no `data object " + id.toString() + "` line defines it");
            }
            const ol = this.objLines[i];
            if (o.data.kind == ObjectDataKind.Mesh && o.data.meshData == null) {
                return this.error<Scene>(ol, "object", "object " + id.toString() + " is a mesh but no `data mesh "
                    + id.toString() + "` line gives its mesh");
            }
            if (o.data.kind == ObjectDataKind.Armature) {
                if (!this.arms.has(id)) {
                    return this.error<Scene>(ol, "object", "object " + id.toString() + " is an armature but no `data armature "
                        + id.toString() + "` line gives its bones");
                }
                const st = this.arms.get(id);
                for (let b = 0; b < st.slots.length; b++) {
                    if (st.slots[b] == null && !isHole(st.holes, <u32>b)) {
                        return this.error<Scene>(st.line, "armature", "bone " + b.toString() + " of object " + id.toString()
                            + " is declared but no `data bone " + id.toString() + " " + b.toString() + "` line defines it");
                    }
                }
            }
            if (o.activeVgroup != NO_VGROUP && o.activeVgroup >= <u32>o.vertexGroups.length) {
                this.failedFlag = "active-vgroup";
                return this.error<Scene>(ol, "object", (this.document ? "active_vertex_group " : "--active-vgroup ")
                    + o.activeVgroup.toString() + " is out of range: the object has "
                    + o.vertexGroups.length.toString() + " vertex groups");
            }
        }
        // Parents last, once every object and bone is known: a parent that
        // is a hole, or a chain that comes back to where it started, would
        // make every walk up the tree (world matrices, export, the
        // outliner) loop for ever. Each walk is at most as long as there
        // are slots.
        for (let i = 0; i < this.objSlots.length; i++) {
            const o = this.objSlots[i];
            if (o == null || o.parent == null) continue;
            const p = o.parent!.id;
            if (p >= <u32>this.objSlots.length || this.objSlots[<i32>p] == null) {
                this.failedFlag = "parent";
                return this.error<Scene>(this.objLines[i], "object", "the parent of object \"" + o.name + "\" ("
                    + p.toString() + ") is not an object: its slot is empty");
            }
            const loop = this.objectLoop(<u32>i);
            if (loop.length > 0) {
                this.failedFlag = "parent";
                return this.error<Scene>(this.objLines[i], "object", "object \"" + o.name + "\" is its own ancestor (" + loop + ")");
            }
        }
        const armIds = this.arms.keys();
        for (let a = 0; a < armIds.length; a++) {
            const st = this.arms.get(armIds[a]);
            for (let b = 0; b < st.slots.length; b++) {
                const bone = st.slots[b];
                if (bone == null || bone.parent == NO_BONE) continue;
                if (bone.parent >= <u32>st.slots.length || st.slots[<i32>bone.parent] == null) {
                    this.failedFlag = "parent";
                    return this.error<Scene>(st.boneLines[b], "bone", "the parent of bone \"" + bone.name + "\" ("
                        + bone.parent.toString() + ") is not a bone: its slot is empty");
                }
                const loop = boneLoop(st.slots, <u32>b);
                if (loop.length > 0) {
                    this.failedFlag = "parent";
                    return this.error<Scene>(st.boneLines[b], "bone", "bone \"" + bone.name + "\" is its own ancestor (" + loop + ")");
                }
            }
        }
        for (let i = 0; i < this.actSlots.length; i++) {
            if (this.actSlots[i] == null && !isHole(this.actHoles, <u32>i)) {
                return this.error<Scene>(this.sceneLine, "scene", "action " + i.toString() + " is declared (--actions "
                    + this.actSlots.length.toString() + ") but no `data action " + i.toString() + "` line defines it");
            }
        }
        s.afterLoad();
        return Result.okv<Scene>(s);
    }

    // "A -> B -> A" when object `start`'s parents come back to it, else "".
    // Called once every parent is known to name an object.
    private objectLoop(start: u32): string {
        const names: Array<string> = [this.objSlots[<i32>start]!.name];
        let at = start;
        for (let step = 0; step < this.objSlots.length; step++) {
            const o = this.objSlots[<i32>at];
            if (o == null || o.parent == null) return "";
            at = o.parent!.id;
            if (at >= <u32>this.objSlots.length) return "";
            const next = this.objSlots[<i32>at];
            if (next == null) return "";
            names.push(next.name);
            if (at == start) return names.join(" -> ");
        }
        // A loop further up that does not pass through `start`: its own
        // objects report it.
        return "";
    }

    // ---- lookups shared by the records

    private objectBound(): u32 {
        return <u32>this.objSlots.length;
    }

    // The object a line names by its first positional, which must have been
    // defined by an earlier `data object` line.
    private objectAt(v: Values, i: i32): Object? {
        const id = v.posU32(i, "object id");
        if (v.failed) return null;
        if (id >= this.objectBound() || this.objSlots[<i32>id] == null) {
            v.fail("object " + id.toString() + " is not defined by an earlier `data object` line");
            return null;
        }
        return this.objSlots[<i32>id];
    }

    // The object's mesh, from its `data mesh` line.
    private meshAt(v: Values, i: i32): Mesh? {
        const o = this.objectAt(v, i);
        if (o == null) return null;
        const m = o.data.meshData;
        if (o.data.kind != ObjectDataKind.Mesh || m == null) {
            v.fail("object " + this.posId(v, i) + " has no mesh: a mesh object's `data mesh` line comes first");
            return null;
        }
        return m;
    }

    private posId(v: Values, i: i32): string {
        return v.posText(i);
    }

    // ---- records

    private readScene(v: Values, line: i32): void {
        const s = new Scene();
        const d = sceneDefaults();
        const nObj = v.slots("objects", MAX_SLOTS);
        const objHoles = v.holes("object-holes", nObj);
        const nAct = v.slots("actions", MAX_SLOTS);
        const actHoles = v.holes("action-holes", nAct);
        if (v.failed) return;
        const objLive = v.u32("objects-live", nObj - <u32>objHoles.length);
        const actLive = v.u32("actions-live", nAct - <u32>actHoles.length);
        s.active = v.id("active", nObj, NO_OBJ, "object ids");
        s.mode = <Mode>v.choice("mode", MODES, <i32>d.mode);
        const sm = v.list("select-mode", 3, "vert edge face, each 0 or 1");
        if (sm != null) {
            const a = sm.nextBit();
            const b = sm.nextBit();
            const c = sm.nextBit();
            v.check("select-mode", sm);
            s.selectMode = SelectMode(a, b, c);
        }
        s.cursor = this.transform(v, "cursor");
        s.pivot = <Pivot>v.choice("pivot", PIVOTS, <i32>d.pivot);
        s.orientation = <Orientation>v.choice("orientation", ORIENTATIONS, <i32>d.orientation);
        s.frame = v.i32("frame", d.frame);
        const fr = v.list("frame-range", 2, "start end");
        if (fr != null) {
            const a = fr.nextI32();
            const b = fr.nextI32();
            v.check("frame-range", fr);
            s.frameRange = FrameRangeI32(a, b);
        }
        s.fps = v.f32("fps", d.fps);
        s.frameStep = v.i32("frame-step", d.frameStep);
        const rd = new RenderDefaults();
        const dr = renderDefaults();
        const rs = v.list("render-size", 2, "width height");
        if (rs != null) {
            const w = rs.nextU32();
            const h = rs.nextU32();
            v.check("render-size", rs);
            const size: Array<u32> = [];
            size.push(w);
            size.push(h);
            rd.size = size;
        }
        rd.background = v.f32s("render-background", dr.background);
        rd.shading = v.str("render-shading", dr.shading);
        s.renderDefaults = rd;
        if (v.failed) return;
        this.objSlots = new Array<Object?>(<i32>nObj);
        this.objHoles = objHoles;
        this.objLines = new Array<i32>(<i32>nObj);
        this.meshLines = new Array<i32>(<i32>nObj);
        this.actSlots = new Array<Action?>(<i32>nAct);
        this.actHoles = actHoles;
        this.actLines = new Array<i32>(<i32>nAct);
        s.objects = SlotVec.fromSlots<Object>(this.objSlots, objLive);
        s.actions = SlotVec.fromSlots<Action>(this.actSlots, actLive);
        this.scene = s;
        this.sceneLine = line;
    }

    private transform(v: Values, name: string): Transform {
        const t = v.list(name, 9, "location, rotation and scale, 3 numbers each");
        if (t == null) return Transform(Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1));
        const l = Vec3(t.nextF32(), t.nextF32(), t.nextF32());
        const r = Vec3(t.nextF32(), t.nextF32(), t.nextF32());
        const sc = Vec3(t.nextF32(), t.nextF32(), t.nextF32());
        v.check(name, t);
        return Transform(l, r, sc);
    }

    private readMaterial(v: Values): void {
        const s = this.scene!;
        const index = v.posU32(0, "material index");
        if (v.failed) return;
        if (index != <u32>s.materials.length) {
            v.fail("material " + index.toString() + " is out of order: the next material is "
                + s.materials.length.toString() + " (materials are numbered from 0, each once)");
            return;
        }
        const d = materialDefaults();
        const m = new Material();
        m.name = v.posText(1);
        m.file = v.optStr("file");
        if (m.file != null && m.file!.length == 0) v.fail(v.f("file") + " names no file", "file");
        m.baseColor = v.f32s("base-color", d.baseColor);
        m.metallic = v.f32("metallic", d.metallic);
        m.roughness = v.f32("roughness", d.roughness);
        m.emission = v.f32s("emission", d.emission);
        m.emissionStrength = v.f32("emission-strength", d.emissionStrength);
        m.alpha = v.f32("alpha", d.alpha);
        m.alphaMode = <AlphaMode>v.choice("alpha-mode", ALPHA_MODES, <i32>d.alphaMode);
        m.alphaCutoff = v.f32("alpha-cutoff", d.alphaCutoff);
        m.doubleSided = v.has("double-sided");
        const t = new MaterialTextures();
        t.baseColor = this.texture(v, 0);
        t.normal = this.texture(v, 1);
        t.metallicRoughness = this.texture(v, 2);
        t.emission = this.texture(v, 3);
        t.occlusion = this.texture(v, 4);
        m.textures = t;
        if (v.failed) return;
        s.materials.push(m);
    }

    private texture(v: Values, slot: i32): TextureRef? {
        const name = TEXTURE_SLOTS[slot];
        const path = v.optStr(name + "-texture");
        const uv = v.optStr(name + "-uv");
        if (path == null) {
            if (uv != null) v.fail(v.f(name + "-uv") + " without " + v.f(name + "-texture"), name + "-uv");
            return null;
        }
        return new TextureRef(path, uv);
    }

    private readAction(v: Values, line: i32): void {
        const id = v.posU32(0, "action id");
        if (v.failed) return;
        if (id >= <u32>this.actSlots.length || isHole(this.actHoles, id)) {
            v.fail("action " + id.toString() + " is not a declared slot ("
                + (id >= <u32>this.actSlots.length ? rangeText(<u32>this.actSlots.length, "action ids") : "it is one of --action-holes") + ")");
            return;
        }
        if (this.actSlots[<i32>id] != null) {
            v.fail("action " + id.toString() + " is defined twice (first at line " + this.actLines[<i32>id].toString() + ")");
            return;
        }
        this.actSlots[<i32>id] = new Action(v.posText(1));
        this.actLines[<i32>id] = line;
    }

    private readFCurve(v: Values): void {
        const id = v.posU32(0, "action id");
        const index = v.posU32(2, "array index");
        if (v.failed) return;
        if (id >= <u32>this.actSlots.length || this.actSlots[<i32>id] == null) {
            v.fail("action " + id.toString() + " is not defined by an earlier `data action` line");
            return;
        }
        const a = this.actSlots[<i32>id]!;
        const c = new FCurve(v.posText(1), index);
        const ks = v.anyList("keys");
        if (ks != null) {
            const n = ks.count();
            if (n % 12 != 0) {
                v.fail(v.f("keys") + " holds " + n.toString() + " numbers, not a multiple of 12 (frame value interpolation easing "
                    + "left-x left-y right-x right-y handle-type back amplitude period, a key)");
                return;
            }
            for (let k = 0; k < n / 12; k++) {
                const frame = ks.nextF32();
                const value = ks.nextF32();
                const key = new Keyframe(frame, value);
                key.interpolation = <Interpolation>this.variant(v, ks, 13, "interpolation");
                key.easing = <Easing>this.variant(v, ks, 4, "easing");
                const hlx = ks.nextF32();
                const hly = ks.nextF32();
                key.handleLeft = Vec2(hlx, hly);
                const hrx = ks.nextF32();
                const hry = ks.nextF32();
                key.handleRight = Vec2(hrx, hry);
                key.handleType = <HandleType>this.variant(v, ks, 5, "handle type");
                key.back = ks.nextF32();
                key.amplitude = ks.nextF32();
                key.period = ks.nextF32();
                c.keyframes.push(key);
            }
            v.check("keys", ks);
        }
        c.extrapolation = <Extrapolation>v.choice("extrapolation", EXTRAPOLATIONS, 0);
        c.mute = v.has("mute");
        if (v.failed) return;
        a.fcurves.push(c);
    }

    // A variant index inside a number list, below `n`.
    private variant(v: Values, s: NumScanner, n: u32, what: string): u32 {
        const x = s.nextU32();
        if (!s.failed && x >= n) v.fail("a key's " + what + " is " + x.toString() + ", past the last variant (" + (n - 1).toString() + ")", "keys");
        return x;
    }

    private readObject(v: Values, line: i32): void {
        const id = v.posU32(0, "object id");
        if (v.failed) return;
        const bound = this.objectBound();
        if (id >= bound || isHole(this.objHoles, id)) {
            v.fail("object " + id.toString() + " is not a declared slot ("
                + (id >= bound ? rangeText(bound, "object ids") : "it is one of --object-holes") + ")");
            return;
        }
        if (this.objSlots[<i32>id] != null) {
            v.fail("object " + id.toString() + " is defined twice (first at line " + this.objLines[<i32>id].toString() + ")");
            return;
        }
        if (!v.has("type")) {
            v.fail(v.f("type") + " is required (mesh, armature, camera, light or empty)", "type");
            return;
        }
        const type = v.choice("type", OBJECT_TYPES, 0);
        if (v.failed) return;
        // Flags of another type's data are an error, not ignored.
        if (type != ObjectDataKind.Camera) this.none(v, CAMERA_FLAGS, OBJECT_TYPES[type]);
        if (type != ObjectDataKind.Light) this.none(v, LIGHT_FLAGS, OBJECT_TYPES[type]);
        if (type != ObjectDataKind.Empty) this.none(v, EMPTY_FLAGS, OBJECT_TYPES[type]);
        let data: ObjectData;
        switch (type) {
            case ObjectDataKind.Camera: {
                const d = cameraDefaults();
                const c = new Camera();
                c.kind = <CameraKind>v.choice("camera-type", CAMERA_TYPES, <i32>d.kind);
                c.focalLengthMm = v.f32("focal-length", d.focalLengthMm);
                c.orthoScale = v.f32("ortho-scale", d.orthoScale);
                c.clipStart = v.f32("clip-start", d.clipStart);
                c.clipEnd = v.f32("clip-end", d.clipEnd);
                data = ObjectData.fromCamera(c);
                break;
            }
            case ObjectDataKind.Light: {
                const d = lightDefaults();
                const l = new Light();
                l.kind = <LightKind>v.choice("light-type", LIGHT_TYPES, <i32>d.kind);
                l.color = v.vec3("color", d.color);
                l.energy = v.f32("energy", d.energy);
                data = ObjectData.fromLight(l);
                break;
            }
            case ObjectDataKind.Empty: {
                const display = <EmptyDisplay>v.choice("empty-display", EMPTY_DISPLAYS, 0);
                const size = v.f32("empty-size", 0);
                const instance = v.optStr("instance");
                if (instance != null && instance.length == 0) v.fail(v.f("instance") + " names no file", "instance");
                data = ObjectData.fromEmpty(new Empty(display, size, instance));
                break;
            }
            default: {
                // The mesh or armature comes with its own line.
                data = new ObjectData();
                data.kind = <ObjectDataKind>type;
                break;
            }
        }
        const o = new Object(v.posText(1), data);
        o.transform = this.transform(v, "transform");
        if (v.has("parent")) {
            const p = v.id("parent", bound, NO_OBJ, "object ids");
            const pt = v.choice("parent-type", PARENT_TYPES, 0);
            let kind: ParentKind;
            if (pt == ParentKindTag.Bone) kind = ParentKind.boneOf(v.str("parent-bone", ""));
            else if (pt == ParentKindTag.Armature) kind = ParentKind.armature();
            else kind = ParentKind.object();
            if (pt != ParentKindTag.Bone && v.has("parent-bone")) v.fail(v.f("parent-bone") + " needs " + v.f("parent-type") + " bone", "parent-bone");
            o.parent = new Parent(p, kind);
        } else if (v.has("parent-type") || v.has("parent-bone")) {
            v.fail(v.f("parent-type") + " and " + v.f("parent-bone") + " need " + v.f("parent"), v.has("parent-type") ? "parent-type" : "parent-bone");
        }
        o.parentInverse = v.mat4("parent-inverse");
        o.select = v.has("select");
        o.hide = v.has("hide");
        o.hideRender = v.has("hide-render");
        o.materialSlots = v.u32s("material-slots");
        o.activeVgroup = v.id("active-vgroup", u32.MAX_VALUE, NO_VGROUP, "vertex groups");
        if (v.has("animation")) o.animation = new AnimData(v.id("animation", <u32>this.actSlots.length, ACTION_NONE, "action ids"));
        if (v.failed) return;
        this.objSlots[<i32>id] = o;
        this.objLines[<i32>id] = line;
    }

    private none(v: Values, flags: Array<string>, type: string): void {
        for (let i = 0; i < flags.length; i++) {
            if (v.has(flags[i])) {
                v.fail(v.f(flags[i]) + " is not a flag of " + (type == "armature" || type == "empty" ? "an " : "a ") + type + " object", flags[i]);
                return;
            }
        }
    }

    private readVgroup(v: Values): void {
        const o = this.objectAt(v, 0);
        if (o == null) return;
        o.vertexGroups.push(new VertexGroup(v.posText(1), v.has("lock")));
    }

    private params(v: Values, name: string): Map<string, string> {
        const m = new Map<string, string>();
        const ws = v.d.all(name);
        for (let i = 0; i < ws.length; i++) {
            const t = ws[i].text();
            const eq = t.indexOf("=");
            if (eq < 0) {
                v.fail(v.f(name) + " `" + t + "` is not key=value", name);
                return m;
            }
            const k = t.substring(0, eq);
            if (m.has(k)) {
                v.fail(v.f(name) + " gives `" + k + "` twice", name);
                return m;
            }
            m.set(k, t.substring(eq + 1));
        }
        return m;
    }

    private readModifier(v: Values): void {
        const o = this.objectAt(v, 0);
        if (o == null) return;
        const kw = v.d.positionals[2];
        const tag = wordIndex(MODIFIER_KINDS, kw.text());
        if (tag < 0) {
            v.fail("unknown modifier kind `" + kw.text() + "` (" + MODIFIER_KINDS.join(", ") + ")");
            return;
        }
        v.only(MODIFIER_FLAGS[tag], ["disabled"], "a " + MODIFIER_KINDS[tag] + " modifier");
        if (v.failed) return;
        const bound = this.objectBound();
        let k: ModifierKind;
        switch (tag) {
            case 0: {
                const axis = v.bits3("axis", false, false, false);
                k = ModifierKindMirror.create(axis, v.has("clipping"), v.has("merge"), v.f32("merge-threshold", 0));
                break;
            }
            case 1: k = ModifierKindSubsurf.create(v.u32("levels", 0), v.u32("render-levels", 0)); break;
            case 2: {
                const count = v.u32("count", 0);
                const rel = v.vec3("relative-offset", Vec3(0, 0, 0));
                const cons = v.vec3("constant-offset", Vec3(0, 0, 0));
                k = ModifierKindArray.create(count, rel, cons, v.has("merge"), v.f32("merge-threshold", 0));
                break;
            }
            case 3: k = ModifierKindSolidify.create(v.f32("thickness", 0), v.f32("offset", 0), v.has("even")); break;
            case 4: {
                const width = v.f32("width", 0);
                const segments = v.u32("segments", 0);
                k = ModifierKindBevel.create(width, segments, v.f32("angle-limit", 0));
                break;
            }
            case 5: k = ModifierKindTriangulate.create(); break;
            case 6: k = ModifierKindWeld.create(v.f32("distance", 0)); break;
            case 7: k = ModifierKindEdgeSplit.create(v.f32("angle", 0)); break;
            case 8: {
                const obj = v.id("object", bound, NO_OBJ, "object ids");
                k = ModifierKindArmature.create(obj, v.has("preserve-volume"), v.has("use-vertex-groups"), v.has("use-envelopes"));
                break;
            }
            case 9: {
                const tool = v.str("tool", "");
                const params = this.params(v, "param");
                k = ModifierKindTool.create(tool, params, v.u64("hash", 0));
                break;
            }
            case 10: {
                const obj = v.id("object", bound, NO_OBJ, "object ids");
                const scale = v.f32("scale", 0);
                const scaleAttr = v.optStr("scale-attr");
                const align = v.has("align");
                const rotation = v.vec3("rotation", Vec3(0, 0, 0));
                k = ModifierKindInstance.create(obj, scale, scaleAttr, align, rotation, v.optStr("rotation-attr"));
                break;
            }
            default: {
                if (!v.has("ext-kind")) {
                    v.fail(v.f("ext-kind") + " is required for an ext modifier", "ext-kind");
                    return;
                }
                k = ModifierKindExt.create(v.str("ext-kind", ""), this.params(v, "prop"));
                break;
            }
        }
        if (v.failed) return;
        o.modifiers.push(new Modifier(v.posText(1), k, !v.has("disabled")));
    }

    private readMesh(v: Values, line: i32): void {
        const objId = v.posU32(0, "object id");
        const o = this.objectAt(v, 0);
        if (o == null) return;
        if (o.data.kind != ObjectDataKind.Mesh) {
            v.fail("object " + objId.toString() + " is " + (o.data.kind == ObjectDataKind.Armature || o.data.kind == ObjectDataKind.Empty ? "an " : "a ")
                + o.data.typeName() + ", not a mesh");
            return;
        }
        if (o.data.meshData != null) {
            v.fail("object " + objId.toString() + " has its mesh already (line " + this.meshLines[<i32>objId].toString() + ")");
            return;
        }
        const m = readMeshFields(v);
        if (m == null || v.failed) return;
        o.data.meshData = m;
        this.meshLines[<i32>objId] = line;
    }

    private readShapeKey(v: Values): void {
        const m = this.meshAt(v, 0);
        if (m == null) return;
        const d = shapeKeyDefaults();
        const k = new ShapeKey();
        k.name = v.posText(1);
        k.value = v.f32("value", d.value);
        k.sliderMin = v.f32("slider-min", d.sliderMin);
        k.sliderMax = v.f32("slider-max", d.sliderMax);
        k.relativeTo = v.u32("relative-to", d.relativeTo);
        k.mute = v.has("mute");
        const co = v.anyList("co");
        if (co != null) {
            const n = co.count();
            if (n % 3 != 0) {
                v.fail(v.f("co") + " holds " + n.toString() + " numbers, not a multiple of 3 (x y z a vertex)", "co");
                return;
            }
            const ps: Array<Vec3> = [];
            for (let i = 0; i < n / 3; i++) {
                const x = co.nextF32();
                const y = co.nextF32();
                const z = co.nextF32();
                ps.push(Vec3(x, y, z));
            }
            v.check("co", co);
            k.positions = ps;
        }
        if (v.failed) return;
        m.shapeKeys.push(k);
    }

    private readAttribute(v: Values): void {
        const m = this.meshAt(v, 0);
        if (m == null) return;
        const a = new AttrLayer();
        a.name = v.posText(1);
        a.domain = <Domain>v.choice("domain", DOMAINS, 0);
        const d = new AttrData();
        d.kind = <AttrType>v.choice("type", ATTR_TYPES, 0);
        const s = v.anyList("values");
        if (s != null && !v.failed) {
            const n = s.count();
            switch (d.kind) {
                case AttrType.Float: {
                    for (let i = 0; i < n; i++) d.floats.push(s.nextF32());
                    break;
                }
                case AttrType.Int: {
                    for (let i = 0; i < n; i++) d.ints.push(s.nextI32());
                    break;
                }
                case AttrType.Bool: {
                    for (let i = 0; i < n; i++) d.bools.push(s.nextBit());
                    break;
                }
                default: {
                    if (n % 3 != 0) {
                        v.fail(v.f("values") + " holds " + n.toString() + " numbers, not a multiple of 3 (x y z a vec3)", "values");
                        return;
                    }
                    for (let i = 0; i < n / 3; i++) {
                        const x = s.nextF32();
                        const y = s.nextF32();
                        const z = s.nextF32();
                        d.vecs.push(Vec3(x, y, z));
                    }
                    break;
                }
            }
            v.check("values", s);
        }
        a.data = d;
        if (v.failed) return;
        m.attributes.push(a);
    }

    private readSelectionSet(v: Values): void {
        const m = this.meshAt(v, 0);
        if (m == null) return;
        const name = v.posText(1);
        if (m.savedSelections.has(name)) {
            v.fail("selection set `" + name + "` is defined twice for object " + v.posText(0));
            return;
        }
        const s = new SelectionSet();
        s.verts = v.u32s("verts");
        s.edges = v.u32s("edges");
        s.faces = v.u32s("faces");
        if (v.failed) return;
        m.savedSelections.set(name, s);
    }

    private readArmature(v: Values, line: i32): void {
        const objId = v.posU32(0, "object id");
        const o = this.objectAt(v, 0);
        if (o == null) return;
        if (o.data.kind != ObjectDataKind.Armature) {
            v.fail("object " + objId.toString() + " is " + (o.data.kind == ObjectDataKind.Empty ? "an " : "a ") + o.data.typeName()
                + ", not an armature");
            return;
        }
        if (this.arms.has(objId)) {
            v.fail("object " + objId.toString() + " has its armature already (line " + this.arms.get(objId).line.toString() + ")");
            return;
        }
        const n = v.slots("bones", MAX_SLOTS);
        const holes = v.holes("bone-holes", n);
        if (v.failed) return;
        const live = v.u32("bones-live", n - <u32>holes.length);
        const a = new Armature(false);
        const slots = new Array<Bone?>(<i32>n);
        a.bones = SlotVec.fromSlots<Bone>(slots, live);
        a.active = v.id("active", n, NO_BONE, "bone ids");
        a.display = <BoneDisplay>v.choice("display", BONE_DISPLAYS, 0);
        const names = v.d.all("collection", 0);
        const hides = v.d.all("collection", 1);
        for (let i = 0; i < names.length; i++) {
            const h = hides[i];
            if (!h.is("0") && !h.is("1")) {
                v.fail(v.f("collection") + " " + names[i].text() + " takes 0 or 1 (hidden) after the name, not `" + h.text() + "`", "collection");
                return;
            }
            a.collections.push(new BoneCollection(names[i].text(), h.is("1")));
        }
        if (v.failed) return;
        o.data.armatureData = a;
        this.arms.set(objId, new ArmState(line, a, slots, holes));
    }

    // The armature state a bone or constraint line names (object, bone id).
    private armAt(v: Values): ArmState? {
        const objId = v.posU32(0, "object id");
        const o = this.objectAt(v, 0);
        if (o == null) return null;
        if (!this.arms.has(objId)) {
            v.fail("object " + objId.toString() + " has no armature: its `data armature` line comes first");
            return null;
        }
        return this.arms.get(objId);
    }

    private readBone(v: Values, line: i32): void {
        const st = this.armAt(v);
        if (st == null) return;
        const id = v.posU32(1, "bone id");
        if (v.failed) return;
        const n = <u32>st.slots.length;
        if (id >= n || isHole(st.holes, id)) {
            v.fail("bone " + id.toString() + " is not a declared slot ("
                + (id >= n ? rangeText(n, "bone ids") : "it is one of --bone-holes") + ")");
            return;
        }
        if (st.slots[<i32>id] != null) {
            v.fail("bone " + id.toString() + " is defined twice (first at line " + st.boneLines[<i32>id].toString() + ")");
            return;
        }
        const d = boneDefaults();
        const b = new Bone();
        b.name = v.posText(2);
        b.head = v.vec3("head", d.head);
        b.tail = v.vec3("tail", d.tail);
        b.roll = v.f32("roll", d.roll);
        b.parent = v.id("parent", n, NO_BONE, "bone ids");
        b.connected = v.has("connected");
        b.deform = v.has("deform");
        b.inheritRotation = v.has("inherit-rotation");
        b.inheritScale = v.has("inherit-scale");
        const env = v.list("envelope", 2, "distance weight");
        if (env != null) {
            b.envelopeDistance = env.nextF32();
            b.envelopeWeight = env.nextF32();
            v.check("envelope", env);
        } else {
            b.envelopeDistance = d.envelopeDistance;
            b.envelopeWeight = d.envelopeWeight;
        }
        const rad = v.list("radius", 2, "head tail");
        if (rad != null) {
            b.headRadius = rad.nextF32();
            b.tailRadius = rad.nextF32();
            v.check("radius", rad);
        } else {
            b.headRadius = d.headRadius;
            b.tailRadius = d.tailRadius;
        }
        const cs = v.d.all("collection");
        const cols: Array<string> = [];
        for (let i = 0; i < cs.length; i++) cols.push(cs[i].text());
        b.collections = cols;
        b.select = v.has("select");
        b.selectHead = v.has("select-head");
        b.selectTail = v.has("select-tail");
        b.hide = v.has("hide");
        b.pose.location = v.vec3("pose-location", Vec3(0, 0, 0));
        b.pose.rotation = v.quat("pose-rotation", Quat(0, 0, 0, 1));
        b.pose.scale = v.vec3("pose-scale", Vec3(1, 1, 1));
        b.pose.select = v.has("pose-select");
        b.pose.hide = v.has("pose-hide");
        if (v.failed) return;
        st.slots[<i32>id] = b;
        st.boneLines[<i32>id] = line;
    }

    private target(v: Values, name: string, sub: string): ConstraintTarget {
        const o = v.id(name, this.objectBound(), NO_OBJ, "object ids");
        return new ConstraintTarget(o, v.optStr(sub));
    }

    private readConstraint(v: Values): void {
        const st = this.armAt(v);
        if (st == null) return;
        const boneId = v.posU32(1, "bone id");
        if (v.failed) return;
        if (boneId >= <u32>st.slots.length || st.slots[<i32>boneId] == null) {
            v.fail("bone " + boneId.toString() + " is not defined by an earlier `data bone` line");
            return;
        }
        const bone = st.slots[<i32>boneId]!;
        const kw = v.d.positionals[3];
        const tag = wordIndex(CONSTRAINT_KINDS, kw.text());
        if (tag < 0) {
            v.fail("unknown constraint kind `" + kw.text() + "` (" + CONSTRAINT_KINDS.join(", ") + ")");
            return;
        }
        v.only(CONSTRAINT_FLAGS[tag], ["influence", "disabled", "space"], "a " + CONSTRAINT_KINDS[tag] + " constraint");
        if (v.failed) return;
        // No target is a target cleared when its object was deleted
        // (Blender's None): the constraint stays and does nothing.
        if (v.has("subtarget") && !v.has("target")) v.fail(v.f("subtarget") + " needs " + v.f("target"), "subtarget");
        if (v.has("pole-subtarget") && !v.has("pole")) v.fail(v.f("pole-subtarget") + " needs " + v.f("pole"), "pole-subtarget");
        let k: ConstraintKind;
        switch (tag) {
            case ConstraintKindTag.Ik: {
                const t = this.target(v, "target", "subtarget");
                const pole = v.has("pole") ? this.target(v, "pole", "pole-subtarget") : null;
                const angle = v.f32("pole-angle", 0);
                const chain = v.u32("chain-length", 0);
                const iters = v.u32("iterations", 0);
                k = ConstraintKindIk.create(t, pole, angle, chain, iters, v.has("use-tail"));
                break;
            }
            case ConstraintKindTag.CopyLocation: {
                const t = this.target(v, "target", "subtarget");
                const axes = v.bits3("axes", true, true, true);
                const invert = v.bits3("invert", false, false, false);
                k = ConstraintKindCopyLocation.create(t, axes, invert, v.has("offset"));
                break;
            }
            case ConstraintKindTag.CopyRotation: {
                const t = this.target(v, "target", "subtarget");
                const axes = v.bits3("axes", true, true, true);
                k = ConstraintKindCopyRotation.create(t, axes, <RotationMix>v.choice("mix", MIXES, 0));
                break;
            }
            case ConstraintKindTag.CopyScale: {
                const t = this.target(v, "target", "subtarget");
                k = ConstraintKindCopyScale.create(t, v.bits3("axes", true, true, true));
                break;
            }
            case ConstraintKindTag.CopyTransforms: {
                const t = this.target(v, "target", "subtarget");
                k = ConstraintKindCopyTransforms.create(t, <RotationMix>v.choice("mix", MIXES, 0));
                break;
            }
            case ConstraintKindTag.LimitRotation: {
                const mn = v.vec3("min", Vec3(0, 0, 0));
                const mx = v.vec3("max", Vec3(0, 0, 0));
                k = ConstraintKindLimitRotation.create(mn, mx, v.bits3("axes", true, true, true));
                break;
            }
            case ConstraintKindTag.LimitLocation: {
                const mn = v.vec3("min", Vec3(0, 0, 0));
                const mx = v.vec3("max", Vec3(0, 0, 0));
                const useMin = v.bits3("use-min", false, false, false);
                k = ConstraintKindLimitLocation.create(mn, mx, useMin, v.bits3("use-max", false, false, false));
                break;
            }
            case ConstraintKindTag.TrackTo: {
                const t = this.target(v, "target", "subtarget");
                const track = <TrackAxis>v.choice("track", TRACK_AXES, 1);
                k = ConstraintKindTrackTo.create(t, track, <TrackAxis>v.choice("up", TRACK_AXES, 1));
                break;
            }
            case ConstraintKindTag.DampedTrack: {
                const t = this.target(v, "target", "subtarget");
                k = ConstraintKindDampedTrack.create(t, <TrackAxis>v.choice("track", TRACK_AXES, 1));
                break;
            }
            case ConstraintKindTag.StretchTo: {
                const t = this.target(v, "target", "subtarget");
                k = ConstraintKindStretchTo.create(t, v.f32("rest-length", 0), v.has("volume"));
                break;
            }
            default: {
                const t = this.target(v, "target", "subtarget");
                k = ConstraintKindChildOf.create(t, v.mat4("inverse"));
                break;
            }
        }
        // A new constraint has its kind's default name and space.
        const c = new Constraint(k);
        c.name = v.posText(2);
        c.influence = v.f32("influence", 1);
        c.enabled = !v.has("disabled");
        c.space = <ConstraintSpace>v.choice("space", SPACES, <i32>c.space);
        if (v.failed) return;
        bone.pose.constraints.push(c);
    }

    private readPoseClip(v: Values): void {
        const loc = v.vec3("location", Vec3(0, 0, 0));
        const rot = v.quat("rotation", Quat(0, 0, 0, 1));
        const scale = v.vec3("scale", Vec3(1, 1, 1));
        if (v.failed) return;
        this.scene!.poseClipboard.push(new PoseClip(v.posText(0), loc, rot, scale));
    }

    private readImport(v: Values): void {
        const hash = v.str("hash", "");
        const bytes = v.u64("bytes", 0);
        const ws = v.d.all("object");
        const objects: Array<string> = [];
        for (let i = 0; i < ws.length; i++) objects.push(ws[i].text());
        if (v.failed) return;
        this.scene!.imports.push(new ImportRecord(v.posText(0), hash, bytes, objects));
    }
}

// ------------------------------------------------------------ data mesh

// The slots of one element list: `n` slots, the ascending `holes`, and the
// present count; `next()` walks the present ids in order.
class SlotWalk {
    n: u32;
    holes: Array<u32>;
    present: i32;
    private id: u32 = 0;
    private h: i32 = 0;

    constructor(n: u32, holes: Array<u32>) {
        this.n = n;
        this.holes = holes;
        this.present = <i32>n - holes.length;
    }

    // The next present id (call it `present` times).
    next(): u32 {
        while (this.h < this.holes.length && this.holes[this.h] == this.id) {
            this.h++;
            this.id++;
        }
        const id = this.id;
        this.id++;
        return id;
    }
}

function walkOf(v: Values, count: string, holes: string): SlotWalk {
    // Every slot is a hole or an element, and each takes at least two
    // characters of the line (a number and a space) in its list.
    const n = v.slots(count, <u32>v.size);
    return new SlotWalk(n, v.holes(holes, n));
}

// A required per-element list (`per` numbers each), or an error when the
// elements exist and the list does not.
function required(v: Values, name: string, w: SlotWalk, per: i32, what: string): NumScanner? {
    if (w.present == 0) {
        if (v.has(name)) v.list(name, 0, "there are no " + what);
        return null;
    }
    if (!v.has(name)) {
        v.fail(v.f(name) + " is required: " + w.present.toString() + " " + what + " are present", name);
        return null;
    }
    return v.list(name, per * w.present, per.toString() + " for each of " + w.present.toString() + " " + what);
}

// An optional per-element list: null when absent (its values are all 0).
function optional(v: Values, name: string, w: SlotWalk, per: i32, what: string): NumScanner? {
    return v.list(name, per * w.present, per.toString() + " for each of " + w.present.toString() + " " + what);
}

function flagBits(v: Values, name: string, s: NumScanner?, max: u32): u32 {
    if (s == null) return 0;
    const f = s.nextU32();
    if (!s.failed && f > max) v.fail(v.f(name) + " holds " + f.toString() + ", past its bits (at most " + max.toString() + ")", name);
    return f;
}

// The live count: the codec's, when it is given, else the present count.
function liveOf(v: Values, name: string, w: SlotWalk): u32 {
    return v.u32(name, <u32>w.present);
}

// The mesh of a `data mesh` line, or null with v's error set.
function readMeshFields(v: Values): Mesh? {
    const vw = walkOf(v, "verts", "vert-holes");
    const ew = walkOf(v, "edges", "edge-holes");
    const fw = walkOf(v, "faces", "face-holes");
    const lw = walkOf(v, "loops", "loop-holes");
    if (v.failed) return null;
    const m = new Mesh();

    // Vertices.
    {
        const co = required(v, "co", vw, 3, "vertices");
        const flags = optional(v, "vert-flags", vw, 1, "vertices");
        const groups = v.anyList("vert-groups");
        if (v.failed) return null;
        const slots = new Array<Vert?>(<i32>vw.n);
        for (let i = 0; i < vw.present; i++) {
            const id = vw.next();
            const vert = new Vert();
            if (co != null) {
                const x = co.nextF32();
                const y = co.nextF32();
                const z = co.nextF32();
                vert.co = Vec3(x, y, z);
            }
            const f = flagBits(v, "vert-flags", flags, 3);
            vert.select = (f & 1) != 0;
            vert.hide = (f & 2) != 0;
            if (groups != null) {
                const k = groups.nextU32();
                for (let g = 0; g < <i32>k && !groups.failed; g++) {
                    const gi = groups.nextU32();
                    const wt = groups.nextF32();
                    vert.groups.push(GroupWeight.new(gi, wt));
                }
            }
            slots[<i32>id] = vert;
        }
        if (co != null) v.check("co", co);
        if (flags != null) v.check("vert-flags", flags);
        if (groups != null) v.check("vert-groups", groups);
        if (v.failed) return null;
        m.verts = SlotVec.fromSlots<Vert>(slots, liveOf(v, "verts-live", vw));
    }

    // Edges.
    {
        const ev = required(v, "edge-verts", ew, 2, "edges");
        const flags = optional(v, "edge-flags", ew, 1, "edges");
        const crease = optional(v, "crease", ew, 1, "edges");
        const bevel = optional(v, "bevel-weight", ew, 1, "edges");
        if (v.failed) return null;
        const slots = new Array<Edge?>(<i32>ew.n);
        for (let i = 0; i < ew.present && !v.failed; i++) {
            const id = ew.next();
            const e = new Edge();
            if (ev != null) {
                const a = ev.nextU32();
                const b = ev.nextU32();
                if (!ev.failed && (a >= vw.n || b >= vw.n)) {
                    v.fail(v.f("edge-verts") + ": edge " + id.toString() + " names vertex " + (a >= vw.n ? a : b).toString()
                        + ", past the " + vw.n.toString() + " vertex slots");
                }
                e.setV(a, b);
            }
            const f = flagBits(v, "edge-flags", flags, 15);
            e.select = (f & 1) != 0;
            e.hide = (f & 2) != 0;
            e.seam = (f & 4) != 0;
            e.sharp = (f & 8) != 0;
            if (crease != null) e.crease = crease.nextF32();
            if (bevel != null) e.bevelWeight = bevel.nextF32();
            slots[<i32>id] = e;
        }
        if (ev != null) v.check("edge-verts", ev);
        if (flags != null) v.check("edge-flags", flags);
        if (crease != null) v.check("crease", crease);
        if (bevel != null) v.check("bevel-weight", bevel);
        if (v.failed) return null;
        m.edges = SlotVec.fromSlots<Edge>(slots, liveOf(v, "edges-live", ew));
    }

    // Faces.
    const faceSlots = new Array<Face?>(<i32>fw.n);
    {
        const fl = required(v, "face-loops", fw, 2, "faces");
        const normals = optional(v, "face-normals", fw, 3, "faces");
        const flags = optional(v, "face-flags", fw, 1, "faces");
        const mats = optional(v, "face-materials", fw, 1, "faces");
        if (v.failed) return null;
        for (let i = 0; i < fw.present; i++) {
            const id = fw.next();
            const f = new Face();
            if (fl != null) {
                f.loopStart = fl.nextU32();
                f.loopLen = fl.nextU32();
            }
            if (normals != null) {
                const x = normals.nextF32();
                const y = normals.nextF32();
                const z = normals.nextF32();
                f.normal = Vec3(x, y, z);
            }
            const b = flagBits(v, "face-flags", flags, 7);
            f.smooth = (b & 1) != 0;
            f.select = (b & 2) != 0;
            f.hide = (b & 4) != 0;
            if (mats != null) {
                const mi = mats.nextU32();
                if (!mats.failed && mi > 0xFFFF) v.fail(v.f("face-materials") + " holds " + mi.toString() + ", past 65535", "face-materials");
                f.materialIndex = <u16>mi;
            }
            faceSlots[<i32>id] = f;
        }
        if (fl != null) v.check("face-loops", fl);
        if (normals != null) v.check("face-normals", normals);
        if (flags != null) v.check("face-flags", flags);
        if (mats != null) v.check("face-materials", mats);
        if (v.failed) return null;
        m.faces = SlotVec.fromSlots<Face>(faceSlots, liveOf(v, "faces-live", fw));
    }

    // Loops.
    {
        const refs = required(v, "loop-refs", lw, 3, "loops");
        const uvs = v.anyList("loop-uvs");
        const uvFlags = v.anyList("loop-uv-flags");
        if (v.failed) return null;
        const slots = new Array<Loop?>(<i32>lw.n);
        for (let i = 0; i < lw.present && !v.failed; i++) {
            const id = lw.next();
            const l = new Loop();
            if (refs != null) {
                l.vert = refs.nextU32();
                l.edge = refs.nextU32();
                l.face = refs.nextU32();
                if (!refs.failed && (l.vert >= vw.n || l.edge >= ew.n || l.face >= fw.n)) {
                    v.fail(v.f("loop-refs") + ": loop " + id.toString() + " names "
                        + (l.vert >= vw.n ? "vertex " + l.vert.toString() + ", past the " + vw.n.toString() + " vertex slots"
                            : l.edge >= ew.n ? "edge " + l.edge.toString() + ", past the " + ew.n.toString() + " edge slots"
                                : "face " + l.face.toString() + ", past the " + fw.n.toString() + " face slots"));
                }
            }
            if (uvs != null) {
                const k = uvs.nextU32();
                for (let u = 0; u < <i32>k && !uvs.failed; u++) {
                    const x = uvs.nextF32();
                    const y = uvs.nextF32();
                    l.uv.push(Vec2(x, y));
                }
            }
            if (uvFlags != null) {
                const k = uvFlags.nextU32();
                for (let u = 0; u < <i32>k && !uvFlags.failed; u++) {
                    const f = uvFlags.nextU32();
                    if (!uvFlags.failed && f > 255) v.fail(v.f("loop-uv-flags") + " holds " + f.toString() + ", past 255", "loop-uv-flags");
                    l.uvFlags.push(<u8>f);
                }
            }
            slots[<i32>id] = l;
        }
        if (refs != null) v.check("loop-refs", refs);
        if (uvs != null) v.check("loop-uvs", uvs);
        if (uvFlags != null) v.check("loop-uv-flags", uvFlags);
        if (v.failed) return null;
        m.loops = SlotVec.fromSlots<Loop>(slots, liveOf(v, "loops-live", lw));
        // A face's loops must be there: the mesh's lookups walk them.
        for (let i = 0; i < faceSlots.length; i++) {
            const f = faceSlots[i];
            if (f == null) continue;
            const end = <u64>f.loopStart + <u64>f.loopLen;
            if (end > <u64>lw.n) {
                v.fail(v.f("face-loops") + ": face " + i.toString() + " runs to loop " + (end - 1).toString() + ", past the "
                    + lw.n.toString() + " loop slots");
                return null;
            }
            for (let k = f.loopStart; k < f.loopStart + f.loopLen; k++) {
                if (slots[<i32>k] == null) {
                    v.fail(v.f("face-loops") + ": face " + i.toString() + " uses loop " + k.toString() + ", one of " + v.f("loop-holes"), "face-loops");
                    return null;
                }
            }
        }
    }

    const layers = v.d.all("uv-layer");
    for (let i = 0; i < layers.length; i++) m.uvLayers.push(UvLayer.new(layers[i].text()));
    m.activeUv = v.u32("active-uv", 0);
    const h = v.anyList("select-history");
    if (h != null) {
        const n = h.count();
        if (n % 2 != 0) {
            v.fail(v.f("select-history") + " holds " + n.toString() + " numbers, not pairs (kind id: 0 vert, 1 edge, 2 face)", "select-history");
            return null;
        }
        for (let i = 0; i < n / 2; i++) {
            const k = h.nextU32();
            const id = h.nextU32();
            if (!h.failed && k > 2) v.fail(v.f("select-history") + ": kind " + k.toString() + " is not 0 (vert), 1 (edge) or 2 (face)", "select-history");
            m.selectionHistory.push(ElemRef.new(<ElemKind>k, id));
        }
        v.check("select-history", h);
    }
    m.activeShapeKey = v.u32("active-shape-key", 0);
    if (v.failed) return null;
    return m;
}

// The files a data line names: a `data material` line's MaterialX file,
// then its textures in slot order; a `data object` line's instanced model;
// [] for any other line, or one that does not split.
export function materialTexturePaths(text: string): Array<string> {
    const out: Array<string> = [];
    const record = recordOf(text);
    if (record == "object") {
        // An empty's instanced model.
        const d = splitLine(text, POSITIONALS[4], specsOf(4));
        const w = d.error.length == 0 ? d.value("instance") : null;
        if (w != null) out.push(w.text());
        return out;
    }
    if (record != "material") return out;
    const d = splitLine(text, POSITIONALS[1], specsOf(1));
    if (d.error.length > 0) return out;
    // The MaterialX file first, as a load reads it before the textures.
    const f = d.value("file");
    if (f != null) out.push(f.text());
    for (let i = 0; i < TEXTURE_SLOTS.length; i++) {
        const w = d.value(TEXTURE_SLOTS[i] + "-texture");
        if (w != null) out.push(w.text());
    }
    return out;
}
