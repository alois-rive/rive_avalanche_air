// The binary encoding of every persisted core type, over postcard: each
// type has a writer and a reader that follow its field order and the
// postcard rules in ./postcard.as.
//
// One layout, the current schema's (../file.as SCHEMA_VERSION): the scene
// envelope holds a replay cache entry and the undo ring a snapshot, both
// written and read by the same build, so no older layout is read.
//
// Schema 2 ends the scene with a tail, the files it names besides its
// textures (writeFileRefs): written only when there is one, so a scene
// that names none encodes to the very bytes schema 1 gave it, and a body
// ends where its imports do.
//
// Optional u32 fields are sentinels in memory (NO_OBJ, NO_BONE, NO_VGROUP,
// ACTION_NONE, all u32.MAX_VALUE): "none" is written for the sentinel, and a
// decoded present u32.MAX_VALUE cannot be told apart from "none".
//
// Decoded meshes and armatures have their unsaved fields at their defaults
// (lookups empty, revision 0). `file.decode` and the undo ring call
// `Scene.afterLoad()` to rebuild them.

import { Vec2, Vec3, Vec4, Quat, Mat4 } from "../../../base/vecmath";
import { SlotVec } from "../../../base/slot";
import { stableSort, cmpStr } from "../../../base/util";
import { PostcardWriter, PostcardReader, PostcardError } from "./postcard";
import {
    Mesh, Vert, Edge, Face, Loop, UvLayer, SelectionSet, ElemKind, ElemRef, GroupWeight,
} from "../mesh/mod";
import { AttrLayer, AttrData, AttrType, Domain } from "../mesh/attr";
import { ShapeKey } from "../mesh/shapekey";
import { SelectMode } from "../mesh/select_mode";
import { Armature, Bone, PoseBone, BoneCollection, BoneDisplay, NO_BONE } from "../armature/mod";
import {
    Constraint, ConstraintKind, ConstraintKindTag, ConstraintTarget, ConstraintSpace, RotationMix, TrackAxis,
    ConstraintKindIk, ConstraintKindCopyLocation, ConstraintKindCopyRotation, ConstraintKindCopyScale,
    ConstraintKindCopyTransforms, ConstraintKindLimitRotation, ConstraintKindLimitLocation, ConstraintKindTrackTo,
    ConstraintKindDampedTrack, ConstraintKindStretchTo, ConstraintKindChildOf, bool3,
} from "../armature/constraints";
import { Action, AnimData, ACTION_NONE } from "../anim/mod";
import { FCurve, Keyframe, Interpolation, Easing, HandleType, Extrapolation } from "../anim/fcurve";
import { PoseClip } from "../armature/pose_clip";
import {
    Scene, Object, ObjectData, ObjectDataKind, Transform, Camera, CameraKind, Light, LightKind, Empty, EmptyDisplay,
    Parent, ParentKind, ParentKindTag, Modifier, ModifierKind, ModifierKindTag, ModifierKindMirror,
    ModifierKindSubsurf, ModifierKindArray, ModifierKindSolidify, ModifierKindBevel, ModifierKindTriangulate,
    ModifierKindWeld, ModifierKindEdgeSplit, ModifierKindArmature, ModifierKindTool, ModifierKindInstance,
    ModifierKindExt, VertexGroup, Mode, Pivot, Orientation, AlphaMode, Material, MaterialTextures, TextureRef,
    RenderDefaults, ImportRecord, FrameRangeI32, NO_OBJ, NO_VGROUP, sortedKeys,
} from "../scene";

// The keys of a map in byte order.
function btreeKeys<V>(m: Map<string, V>): Array<string> {
    const keys = m.keys();
    stableSort<string>(keys, cmpStr);
    return keys;
}

// ---------------------------------------------------------------------------
// Vector types and small helpers

function writeVec2(w: PostcardWriter, v: Vec2): void {
    w.f32(v.x);
    w.f32(v.y);
}

function readVec2(r: PostcardReader): Vec2 {
    const x = r.f32();
    const y = r.f32();
    return Vec2(x, y);
}

function writeVec3(w: PostcardWriter, v: Vec3): void {
    w.f32(v.x);
    w.f32(v.y);
    w.f32(v.z);
}

function readVec3(r: PostcardReader): Vec3 {
    const x = r.f32();
    const y = r.f32();
    const z = r.f32();
    return Vec3(x, y, z);
}

function writeQuat(w: PostcardWriter, q: Quat): void {
    w.f32(q.x);
    w.f32(q.y);
    w.f32(q.z);
    w.f32(q.w);
}

function readQuat(r: PostcardReader): Quat {
    const x = r.f32();
    const y = r.f32();
    const z = r.f32();
    const ww = r.f32();
    return Quat(x, y, z, ww);
}

function writeVec4(w: PostcardWriter, v: Vec4): void {
    w.f32(v.x);
    w.f32(v.y);
    w.f32(v.z);
    w.f32(v.w);
}

function readVec4(r: PostcardReader): Vec4 {
    const x = r.f32();
    const y = r.f32();
    const z = r.f32();
    const ww = r.f32();
    return Vec4(x, y, z, ww);
}

// Mat4: 16 f32, column major.
function writeMat4(w: PostcardWriter, m: Mat4): void {
    writeVec4(w, m.xAxis);
    writeVec4(w, m.yAxis);
    writeVec4(w, m.zAxis);
    writeVec4(w, m.wAxis);
}

function readMat4(r: PostcardReader): Mat4 {
    const a = readVec4(r);
    const b = readVec4(r);
    const c = readVec4(r);
    const d = readVec4(r);
    return Mat4(a, b, c, d);
}

function writeBool3(w: PostcardWriter, a: Array<bool>): void {
    w.bool(a[0]);
    w.bool(a[1]);
    w.bool(a[2]);
}

function readBool3(r: PostcardReader): Array<bool> {
    const x = r.bool();
    const y = r.bool();
    const z = r.bool();
    return bool3(x, y, z);
}

// An optional u32 held as a u32 sentinel.
function writeOptU32(w: PostcardWriter, v: u32, none: u32): void {
    if (v == none) {
        w.none();
    } else {
        w.some();
        w.varU32(v);
    }
}

function readOptU32(r: PostcardReader, none: u32): u32 {
    if (!r.option()) return none;
    return r.varU32();
}

function writeOptStr(w: PostcardWriter, s: string?): void {
    if (s == null) {
        w.none();
    } else {
        w.some();
        w.str(s);
    }
}

function readOptStr(r: PostcardReader): string? {
    if (!r.option()) return null;
    return r.str();
}

function writeU32s(w: PostcardWriter, a: Array<u32>): void {
    w.seqLen(a.length);
    for (let i = 0; i < a.length; i++) w.varU32(a[i]);
}

function readU32s(r: PostcardReader): Array<u32> {
    const n = r.seqLen();
    const out: Array<u32> = [];
    for (let i: u64 = 0; i < n && !r.failed; i++) out.push(r.varU32());
    return out;
}

function writeStrs(w: PostcardWriter, a: Array<string>): void {
    w.seqLen(a.length);
    for (let i = 0; i < a.length; i++) w.str(a[i]);
}

function readStrs(r: PostcardReader): Array<string> {
    const n = r.seqLen();
    const out: Array<string> = [];
    for (let i: u64 = 0; i < n && !r.failed; i++) out.push(r.str());
    return out;
}

function writeVec3s(w: PostcardWriter, a: Array<Vec3>): void {
    w.seqLen(a.length);
    for (let i = 0; i < a.length; i++) writeVec3(w, a[i]);
}

function readVec3s(r: PostcardReader): Array<Vec3> {
    const n = r.seqLen();
    const out: Array<Vec3> = [];
    for (let i: u64 = 0; i < n && !r.failed; i++) out.push(readVec3(r));
    return out;
}

// A string map: count, then key/value in byte order of the keys.
function writeStrMap(w: PostcardWriter, m: Map<string, string>): void {
    const keys = sortedKeys(m);
    w.seqLen(keys.length);
    for (let i = 0; i < keys.length; i++) {
        w.str(keys[i]);
        w.str(m.get(keys[i]));
    }
}

function readStrMap(r: PostcardReader): Map<string, string> {
    const n = r.seqLen();
    const m = new Map<string, string>();
    for (let i: u64 = 0; i < n && !r.failed; i++) {
        const k = r.str();
        const v = r.str();
        if (!r.failed) m.set(k, v);
    }
    return m;
}

// ---------------------------------------------------------------------------
// Mesh

function writeVert(w: PostcardWriter, v: Vert): void {
    writeVec3(w, v.co);
    w.bool(v.select);
    w.bool(v.hide);
    w.seqLen(v.groups.length);
    for (let i = 0; i < v.groups.length; i++) {
        w.varU32(v.groups[i].group);
        w.f32(v.groups[i].weight);
    }
}

function readVert(r: PostcardReader): Vert {
    const v = new Vert();
    v.co = readVec3(r);
    v.select = r.bool();
    v.hide = r.bool();
    const n = r.seqLen();
    for (let i: u64 = 0; i < n && !r.failed; i++) {
        const g = r.varU32();
        const wt = r.f32();
        v.groups.push(GroupWeight.new(g, wt));
    }
    return v;
}

function writeEdge(w: PostcardWriter, e: Edge): void {
    w.varU32(e.v[0]);
    w.varU32(e.v[1]);
    w.bool(e.select);
    w.bool(e.hide);
    w.bool(e.seam);
    w.bool(e.sharp);
    w.f32(e.crease);
    w.f32(e.bevelWeight);
}

function readEdge(r: PostcardReader): Edge {
    const e = new Edge();
    const a = r.varU32();
    const b = r.varU32();
    e.setV(a, b);
    e.select = r.bool();
    e.hide = r.bool();
    e.seam = r.bool();
    e.sharp = r.bool();
    e.crease = r.f32();
    e.bevelWeight = r.f32();
    return e;
}

function writeFace(w: PostcardWriter, f: Face): void {
    w.varU32(f.loopStart);
    w.varU32(f.loopLen);
    writeVec3(w, f.normal);
    w.bool(f.smooth);
    w.varU16(f.materialIndex);
    w.bool(f.select);
    w.bool(f.hide);
}

function readFace(r: PostcardReader): Face {
    const f = new Face();
    f.loopStart = r.varU32();
    f.loopLen = r.varU32();
    f.normal = readVec3(r);
    f.smooth = r.bool();
    f.materialIndex = r.varU16();
    f.select = r.bool();
    f.hide = r.bool();
    return f;
}

function writeLoop(w: PostcardWriter, l: Loop): void {
    w.varU32(l.vert);
    w.varU32(l.edge);
    w.varU32(l.face);
    w.seqLen(l.uv.length);
    for (let i = 0; i < l.uv.length; i++) writeVec2(w, l.uv[i]);
    w.seqLen(l.uvFlags.length);
    for (let i = 0; i < l.uvFlags.length; i++) w.u8(l.uvFlags[i]);
}

function readLoop(r: PostcardReader): Loop {
    const l = new Loop();
    l.vert = r.varU32();
    l.edge = r.varU32();
    l.face = r.varU32();
    const n = r.seqLen();
    for (let i: u64 = 0; i < n && !r.failed; i++) l.uv.push(readVec2(r));
    const m = r.seqLen();
    for (let i: u64 = 0; i < m && !r.failed; i++) l.uvFlags.push(r.u8());
    return l;
}

function writeSelectionSet(w: PostcardWriter, s: SelectionSet): void {
    writeU32s(w, s.verts);
    writeU32s(w, s.edges);
    writeU32s(w, s.faces);
}

function readSelectionSet(r: PostcardReader): SelectionSet {
    const s = new SelectionSet();
    s.verts = readU32s(r);
    s.edges = readU32s(r);
    s.faces = readU32s(r);
    return s;
}

function writeShapeKey(w: PostcardWriter, k: ShapeKey): void {
    w.str(k.name);
    w.f32(k.value);
    w.f32(k.sliderMin);
    w.f32(k.sliderMax);
    w.varU32(k.relativeTo);
    w.bool(k.mute);
    writeVec3s(w, k.positions);
}

function readShapeKey(r: PostcardReader): ShapeKey {
    const k = new ShapeKey();
    k.name = r.str();
    k.value = r.f32();
    k.sliderMin = r.f32();
    k.sliderMax = r.f32();
    k.relativeTo = r.varU32();
    k.mute = r.bool();
    k.positions = readVec3s(r);
    return k;
}

function writeAttrLayer(w: PostcardWriter, a: AttrLayer): void {
    w.str(a.name);
    w.variant(<u32>a.domain);
    const d = a.data;
    w.variant(<u32>d.kind);
    switch (d.kind) {
        case AttrType.Float: {
            w.seqLen(d.floats.length);
            for (let i = 0; i < d.floats.length; i++) w.f32(d.floats[i]);
            break;
        }
        case AttrType.Int: {
            w.seqLen(d.ints.length);
            for (let i = 0; i < d.ints.length; i++) w.i32(d.ints[i]);
            break;
        }
        case AttrType.Bool: {
            w.seqLen(d.bools.length);
            for (let i = 0; i < d.bools.length; i++) w.bool(d.bools[i]);
            break;
        }
        default: {
            writeVec3s(w, d.vecs);
            break;
        }
    }
}

function readAttrLayer(r: PostcardReader): AttrLayer {
    const a = new AttrLayer();
    a.name = r.str();
    a.domain = <Domain>r.variant(4);
    const d = new AttrData();
    d.kind = <AttrType>r.variant(4);
    if (!r.failed) {
        const n = r.seqLen();
        switch (d.kind) {
            case AttrType.Float: {
                for (let i: u64 = 0; i < n && !r.failed; i++) d.floats.push(r.f32());
                break;
            }
            case AttrType.Int: {
                for (let i: u64 = 0; i < n && !r.failed; i++) d.ints.push(r.i32());
                break;
            }
            case AttrType.Bool: {
                for (let i: u64 = 0; i < n && !r.failed; i++) d.bools.push(r.bool());
                break;
            }
            default: {
                for (let i: u64 = 0; i < n && !r.failed; i++) d.vecs.push(readVec3(r));
                break;
            }
        }
    }
    a.data = d;
    return a;
}

export function writeMesh(w: PostcardWriter, m: Mesh): void {
    const vs = m.verts.slots;
    w.seqLen(vs.length);
    for (let i = 0; i < vs.length; i++) {
        const v = vs[i];
        if (v == null) w.none();
        else { w.some(); writeVert(w, v); }
    }
    w.varU32(m.verts.live);
    const es = m.edges.slots;
    w.seqLen(es.length);
    for (let i = 0; i < es.length; i++) {
        const e = es[i];
        if (e == null) w.none();
        else { w.some(); writeEdge(w, e); }
    }
    w.varU32(m.edges.live);
    const fs = m.faces.slots;
    w.seqLen(fs.length);
    for (let i = 0; i < fs.length; i++) {
        const f = fs[i];
        if (f == null) w.none();
        else { w.some(); writeFace(w, f); }
    }
    w.varU32(m.faces.live);
    const ls = m.loops.slots;
    w.seqLen(ls.length);
    for (let i = 0; i < ls.length; i++) {
        const l = ls[i];
        if (l == null) w.none();
        else { w.some(); writeLoop(w, l); }
    }
    w.varU32(m.loops.live);
    w.seqLen(m.uvLayers.length);
    for (let i = 0; i < m.uvLayers.length; i++) w.str(m.uvLayers[i].name);
    w.varU32(m.activeUv);
    w.seqLen(m.selectionHistory.length);
    for (let i = 0; i < m.selectionHistory.length; i++) {
        w.variant(<u32>m.selectionHistory[i].kind);
        w.varU32(m.selectionHistory[i].id);
    }
    const names = btreeKeys<SelectionSet>(m.savedSelections);
    w.seqLen(names.length);
    for (let i = 0; i < names.length; i++) {
        w.str(names[i]);
        writeSelectionSet(w, m.savedSelections.get(names[i]));
    }
    w.seqLen(m.shapeKeys.length);
    for (let i = 0; i < m.shapeKeys.length; i++) writeShapeKey(w, m.shapeKeys[i]);
    w.varU32(m.activeShapeKey);
    w.seqLen(m.attributes.length);
    for (let i = 0; i < m.attributes.length; i++) writeAttrLayer(w, m.attributes[i]);
}

export function readMesh(r: PostcardReader): Mesh {
    const m = new Mesh();
    {
        const n = r.seqLen();
        const slots: Array<Vert?> = [];
        for (let i: u64 = 0; i < n && !r.failed; i++) slots.push(r.option() ? readVert(r) : null);
        m.verts = SlotVec.fromSlots<Vert>(slots, r.varU32());
    }
    {
        const n = r.seqLen();
        const slots: Array<Edge?> = [];
        for (let i: u64 = 0; i < n && !r.failed; i++) slots.push(r.option() ? readEdge(r) : null);
        m.edges = SlotVec.fromSlots<Edge>(slots, r.varU32());
    }
    {
        const n = r.seqLen();
        const slots: Array<Face?> = [];
        for (let i: u64 = 0; i < n && !r.failed; i++) slots.push(r.option() ? readFace(r) : null);
        m.faces = SlotVec.fromSlots<Face>(slots, r.varU32());
    }
    {
        const n = r.seqLen();
        const slots: Array<Loop?> = [];
        for (let i: u64 = 0; i < n && !r.failed; i++) slots.push(r.option() ? readLoop(r) : null);
        m.loops = SlotVec.fromSlots<Loop>(slots, r.varU32());
    }
    {
        const n = r.seqLen();
        for (let i: u64 = 0; i < n && !r.failed; i++) m.uvLayers.push(UvLayer.new(r.str()));
    }
    m.activeUv = r.varU32();
    {
        const n = r.seqLen();
        for (let i: u64 = 0; i < n && !r.failed; i++) {
            const k = <ElemKind>r.variant(3);
            const id = r.varU32();
            m.selectionHistory.push(ElemRef.new(k, id));
        }
    }
    {
        const n = r.seqLen();
        for (let i: u64 = 0; i < n && !r.failed; i++) {
            const name = r.str();
            const s = readSelectionSet(r);
            if (!r.failed) m.savedSelections.set(name, s);
        }
    }
    {
        const n = r.seqLen();
        for (let i: u64 = 0; i < n && !r.failed; i++) m.shapeKeys.push(readShapeKey(r));
    }
    m.activeShapeKey = r.varU32();
    {
        const n = r.seqLen();
        for (let i: u64 = 0; i < n && !r.failed; i++) m.attributes.push(readAttrLayer(r));
    }
    return m;
}

// ---------------------------------------------------------------------------
// Armature

function writeTarget(w: PostcardWriter, t: ConstraintTarget): void {
    w.varU32(t.object);
    writeOptStr(w, t.subtarget);
}

function readTarget(r: PostcardReader): ConstraintTarget {
    const o = r.varU32();
    const s = readOptStr(r);
    return new ConstraintTarget(o, s);
}

function writeConstraintKind(w: PostcardWriter, k: ConstraintKind): void {
    w.variant(<u32>k.tag);
    switch (k.tag) {
        case ConstraintKindTag.Ik: {
            const c = k as ConstraintKindIk;
            writeTarget(w, c.target);
            const p = c.pole;
            if (p == null) w.none();
            else { w.some(); writeTarget(w, p); }
            w.f32(c.poleAngle);
            w.varU32(c.chainLength);
            w.varU32(c.iterations);
            w.bool(c.useTail);
            break;
        }
        case ConstraintKindTag.CopyLocation: {
            const c = k as ConstraintKindCopyLocation;
            writeTarget(w, c.target);
            writeBool3(w, c.axes);
            writeBool3(w, c.invert);
            w.bool(c.offset);
            break;
        }
        case ConstraintKindTag.CopyRotation: {
            const c = k as ConstraintKindCopyRotation;
            writeTarget(w, c.target);
            writeBool3(w, c.axes);
            w.variant(<u32>c.mix);
            break;
        }
        case ConstraintKindTag.CopyScale: {
            const c = k as ConstraintKindCopyScale;
            writeTarget(w, c.target);
            writeBool3(w, c.axes);
            break;
        }
        case ConstraintKindTag.CopyTransforms: {
            const c = k as ConstraintKindCopyTransforms;
            writeTarget(w, c.target);
            w.variant(<u32>c.mix);
            break;
        }
        case ConstraintKindTag.LimitRotation: {
            const c = k as ConstraintKindLimitRotation;
            writeVec3(w, c.min);
            writeVec3(w, c.max);
            writeBool3(w, c.axes);
            break;
        }
        case ConstraintKindTag.LimitLocation: {
            const c = k as ConstraintKindLimitLocation;
            writeVec3(w, c.min);
            writeVec3(w, c.max);
            writeBool3(w, c.useMin);
            writeBool3(w, c.useMax);
            break;
        }
        case ConstraintKindTag.TrackTo: {
            const c = k as ConstraintKindTrackTo;
            writeTarget(w, c.target);
            w.variant(<u32>c.track);
            w.variant(<u32>c.up);
            break;
        }
        case ConstraintKindTag.DampedTrack: {
            const c = k as ConstraintKindDampedTrack;
            writeTarget(w, c.target);
            w.variant(<u32>c.track);
            break;
        }
        case ConstraintKindTag.StretchTo: {
            const c = k as ConstraintKindStretchTo;
            writeTarget(w, c.target);
            w.f32(c.restLength);
            w.bool(c.volume);
            break;
        }
        default: {
            const c = k as ConstraintKindChildOf;
            writeTarget(w, c.target);
            writeMat4(w, c.inverse);
            break;
        }
    }
}

function readConstraintKind(r: PostcardReader): ConstraintKind {
    const tag = r.variant(11);
    switch (tag) {
        case ConstraintKindTag.Ik: {
            const t = readTarget(r);
            const pole = r.option() ? readTarget(r) : null;
            const angle = r.f32();
            const chain = r.varU32();
            const iters = r.varU32();
            const tail = r.bool();
            return ConstraintKindIk.create(t, pole, angle, chain, iters, tail);
        }
        case ConstraintKindTag.CopyLocation: {
            const t = readTarget(r);
            const axes = readBool3(r);
            const invert = readBool3(r);
            const offset = r.bool();
            return ConstraintKindCopyLocation.create(t, axes, invert, offset);
        }
        case ConstraintKindTag.CopyRotation: {
            const t = readTarget(r);
            const axes = readBool3(r);
            const mix = <RotationMix>r.variant(3);
            return ConstraintKindCopyRotation.create(t, axes, mix);
        }
        case ConstraintKindTag.CopyScale: {
            const t = readTarget(r);
            const axes = readBool3(r);
            return ConstraintKindCopyScale.create(t, axes);
        }
        case ConstraintKindTag.CopyTransforms: {
            const t = readTarget(r);
            const mix = <RotationMix>r.variant(3);
            return ConstraintKindCopyTransforms.create(t, mix);
        }
        case ConstraintKindTag.LimitRotation: {
            const mn = readVec3(r);
            const mx = readVec3(r);
            const axes = readBool3(r);
            return ConstraintKindLimitRotation.create(mn, mx, axes);
        }
        case ConstraintKindTag.LimitLocation: {
            const mn = readVec3(r);
            const mx = readVec3(r);
            const useMin = readBool3(r);
            const useMax = readBool3(r);
            return ConstraintKindLimitLocation.create(mn, mx, useMin, useMax);
        }
        case ConstraintKindTag.TrackTo: {
            const t = readTarget(r);
            const track = <TrackAxis>r.variant(6);
            const up = <TrackAxis>r.variant(6);
            return ConstraintKindTrackTo.create(t, track, up);
        }
        case ConstraintKindTag.DampedTrack: {
            const t = readTarget(r);
            const track = <TrackAxis>r.variant(6);
            return ConstraintKindDampedTrack.create(t, track);
        }
        case ConstraintKindTag.StretchTo: {
            const t = readTarget(r);
            const rest = r.f32();
            const volume = r.bool();
            return ConstraintKindStretchTo.create(t, rest, volume);
        }
        default: {
            const t = readTarget(r);
            const inv = readMat4(r);
            return ConstraintKindChildOf.create(t, inv);
        }
    }
}

function writeConstraint(w: PostcardWriter, c: Constraint): void {
    w.str(c.name);
    writeConstraintKind(w, c.kind);
    w.f32(c.influence);
    w.bool(c.enabled);
    w.variant(<u32>c.space);
}

function readConstraint(r: PostcardReader): Constraint {
    const name = r.str();
    const kind = readConstraintKind(r);
    const c = new Constraint(kind);
    c.name = name;
    c.influence = r.f32();
    c.enabled = r.bool();
    c.space = <ConstraintSpace>r.variant(2);
    return c;
}

function writePoseBone(w: PostcardWriter, p: PoseBone): void {
    writeVec3(w, p.location);
    writeQuat(w, p.rotation);
    writeVec3(w, p.scale);
    w.seqLen(p.constraints.length);
    for (let i = 0; i < p.constraints.length; i++) writeConstraint(w, p.constraints[i]);
    w.bool(p.select);
    w.bool(p.hide);
}

function readPoseBone(r: PostcardReader): PoseBone {
    const p = new PoseBone();
    p.location = readVec3(r);
    p.rotation = readQuat(r);
    p.scale = readVec3(r);
    const n = r.seqLen();
    for (let i: u64 = 0; i < n && !r.failed; i++) p.constraints.push(readConstraint(r));
    p.select = r.bool();
    p.hide = r.bool();
    return p;
}

function writeBone(w: PostcardWriter, b: Bone): void {
    w.str(b.name);
    writeVec3(w, b.head);
    writeVec3(w, b.tail);
    w.f32(b.roll);
    writeOptU32(w, b.parent, NO_BONE);
    w.bool(b.connected);
    w.bool(b.deform);
    w.bool(b.inheritRotation);
    w.bool(b.inheritScale);
    w.f32(b.envelopeDistance);
    w.f32(b.envelopeWeight);
    w.f32(b.headRadius);
    w.f32(b.tailRadius);
    writeStrs(w, b.collections);
    w.bool(b.select);
    w.bool(b.selectHead);
    w.bool(b.selectTail);
    w.bool(b.hide);
    writePoseBone(w, b.pose);
}

function readBone(r: PostcardReader): Bone {
    const b = new Bone();
    b.name = r.str();
    b.head = readVec3(r);
    b.tail = readVec3(r);
    b.roll = r.f32();
    b.parent = readOptU32(r, NO_BONE);
    b.connected = r.bool();
    b.deform = r.bool();
    b.inheritRotation = r.bool();
    b.inheritScale = r.bool();
    b.envelopeDistance = r.f32();
    b.envelopeWeight = r.f32();
    b.headRadius = r.f32();
    b.tailRadius = r.f32();
    b.collections = readStrs(r);
    b.select = r.bool();
    b.selectHead = r.bool();
    b.selectTail = r.bool();
    b.hide = r.bool();
    b.pose = readPoseBone(r);
    return b;
}

export function writeArmature(w: PostcardWriter, a: Armature): void {
    const bs = a.bones.slots;
    w.seqLen(bs.length);
    for (let i = 0; i < bs.length; i++) {
        const b = bs[i];
        if (b == null) w.none();
        else { w.some(); writeBone(w, b); }
    }
    w.varU32(a.bones.live);
    writeOptU32(w, a.active, NO_BONE);
    w.variant(<u32>a.display);
    w.seqLen(a.collections.length);
    for (let i = 0; i < a.collections.length; i++) {
        w.str(a.collections[i].name);
        w.bool(a.collections[i].hide);
    }
}

export function readArmature(r: PostcardReader): Armature {
    // The revision is not saved: it stays 0 until afterLoad.

    const a = new Armature(false);
    const n = r.seqLen();
    const slots: Array<Bone?> = [];
    for (let i: u64 = 0; i < n && !r.failed; i++) slots.push(r.option() ? readBone(r) : null);
    a.bones = SlotVec.fromSlots<Bone>(slots, r.varU32());
    a.active = readOptU32(r, NO_BONE);
    a.display = <BoneDisplay>r.variant(2);
    const m = r.seqLen();
    for (let i: u64 = 0; i < m && !r.failed; i++) {
        const name = r.str();
        const hide = r.bool();
        a.collections.push(new BoneCollection(name, hide));
    }
    return a;
}

// ---------------------------------------------------------------------------
// Animation

function writeKeyframe(w: PostcardWriter, k: Keyframe): void {
    w.f32(k.frame);
    w.f32(k.value);
    w.variant(<u32>k.interpolation);
    w.variant(<u32>k.easing);
    writeVec2(w, k.handleLeft);
    writeVec2(w, k.handleRight);
    w.variant(<u32>k.handleType);
    w.f32(k.back);
    w.f32(k.amplitude);
    w.f32(k.period);
}

function readKeyframe(r: PostcardReader): Keyframe {
    const frame = r.f32();
    const value = r.f32();
    const k = new Keyframe(frame, value);
    k.interpolation = <Interpolation>r.variant(13);
    k.easing = <Easing>r.variant(4);
    k.handleLeft = readVec2(r);
    k.handleRight = readVec2(r);
    k.handleType = <HandleType>r.variant(5);
    k.back = r.f32();
    k.amplitude = r.f32();
    k.period = r.f32();
    return k;
}

function writeFCurve(w: PostcardWriter, c: FCurve): void {
    w.str(c.dataPath);
    w.varU32(c.arrayIndex);
    w.seqLen(c.keyframes.length);
    for (let i = 0; i < c.keyframes.length; i++) writeKeyframe(w, c.keyframes[i]);
    w.variant(<u32>c.extrapolation);
    w.bool(c.mute);
}

function readFCurve(r: PostcardReader): FCurve {
    const path = r.str();
    const index = r.varU32();
    const c = new FCurve(path, index);
    const n = r.seqLen();
    for (let i: u64 = 0; i < n && !r.failed; i++) c.keyframes.push(readKeyframe(r));
    c.extrapolation = <Extrapolation>r.variant(3);
    c.mute = r.bool();
    return c;
}

export function writeAction(w: PostcardWriter, a: Action): void {
    w.str(a.name);
    w.seqLen(a.fcurves.length);
    for (let i = 0; i < a.fcurves.length; i++) writeFCurve(w, a.fcurves[i]);
}

export function readAction(r: PostcardReader): Action {
    const a = new Action(r.str());
    const n = r.seqLen();
    for (let i: u64 = 0; i < n && !r.failed; i++) a.fcurves.push(readFCurve(r));
    return a;
}

// ---------------------------------------------------------------------------
// Scene types

function writeTransform(w: PostcardWriter, t: Transform): void {
    writeVec3(w, t.location);
    writeVec3(w, t.rotation);
    writeVec3(w, t.scale);
}

function readTransform(r: PostcardReader): Transform {
    const l = readVec3(r);
    const rot = readVec3(r);
    const s = readVec3(r);
    return Transform(l, rot, s);
}

function writeObjectData(w: PostcardWriter, d: ObjectData): void {
    w.variant(<u32>d.kind);
    switch (d.kind) {
        case ObjectDataKind.Mesh: {
            writeMesh(w, d.meshData!);
            break;
        }
        case ObjectDataKind.Armature: {
            writeArmature(w, d.armatureData!);
            break;
        }
        case ObjectDataKind.Camera: {
            const c = d.cameraData!;
            w.variant(<u32>c.kind);
            w.f32(c.focalLengthMm);
            w.f32(c.orthoScale);
            w.f32(c.clipStart);
            w.f32(c.clipEnd);
            break;
        }
        case ObjectDataKind.Light: {
            const l = d.lightData!;
            w.variant(<u32>l.kind);
            writeVec3(w, l.color);
            w.f32(l.energy);
            break;
        }
        default: {
            const e = d.emptyData!;
            w.variant(<u32>e.display);
            w.f32(e.size);
            break;
        }
    }
}

function readObjectData(r: PostcardReader): ObjectData {
    const kind = r.variant(5);
    switch (kind) {
        case ObjectDataKind.Mesh: return ObjectData.fromMesh(readMesh(r));
        case ObjectDataKind.Armature: return ObjectData.fromArmature(readArmature(r));
        case ObjectDataKind.Camera: {
            const c = new Camera();
            c.kind = <CameraKind>r.variant(2);
            c.focalLengthMm = r.f32();
            c.orthoScale = r.f32();
            c.clipStart = r.f32();
            c.clipEnd = r.f32();
            return ObjectData.fromCamera(c);
        }
        case ObjectDataKind.Light: {
            const l = new Light();
            l.kind = <LightKind>r.variant(4);
            l.color = readVec3(r);
            l.energy = r.f32();
            return ObjectData.fromLight(l);
        }
        default: {
            const display = <EmptyDisplay>r.variant(3);
            const size = r.f32();
            return ObjectData.fromEmpty(new Empty(display, size));
        }
    }
}

function writeModifierKind(w: PostcardWriter, k: ModifierKind): void {
    w.variant(<u32>k.tag);
    switch (k.tag) {
        case ModifierKindTag.Mirror: {
            const m = k as ModifierKindMirror;
            writeBool3(w, m.axis);
            w.bool(m.clipping);
            w.bool(m.merge);
            w.f32(m.mergeThreshold);
            break;
        }
        case ModifierKindTag.Subsurf: {
            const m = k as ModifierKindSubsurf;
            w.varU32(m.levels);
            w.varU32(m.renderLevels);
            break;
        }
        case ModifierKindTag.Array: {
            const m = k as ModifierKindArray;
            w.varU32(m.count);
            writeVec3(w, m.relativeOffset);
            writeVec3(w, m.constantOffset);
            w.bool(m.merge);
            w.f32(m.mergeThreshold);
            break;
        }
        case ModifierKindTag.Solidify: {
            const m = k as ModifierKindSolidify;
            w.f32(m.thickness);
            w.f32(m.offset);
            w.bool(m.even);
            break;
        }
        case ModifierKindTag.Bevel: {
            const m = k as ModifierKindBevel;
            w.f32(m.width);
            w.varU32(m.segments);
            w.f32(m.angleLimit);
            break;
        }
        case ModifierKindTag.Triangulate: break;
        case ModifierKindTag.Weld: {
            w.f32((k as ModifierKindWeld).distance);
            break;
        }
        case ModifierKindTag.EdgeSplit: {
            w.f32((k as ModifierKindEdgeSplit).angle);
            break;
        }
        case ModifierKindTag.Armature: {
            const m = k as ModifierKindArmature;
            writeOptU32(w, m.object, NO_OBJ);
            w.bool(m.preserveVolume);
            w.bool(m.useVertexGroups);
            w.bool(m.useEnvelopes);
            break;
        }
        case ModifierKindTag.Tool: {
            const m = k as ModifierKindTool;
            w.str(m.tool);
            writeStrMap(w, m.params);
            w.varU64(m.hash);
            break;
        }
        case ModifierKindTag.Instance: {
            const m = k as ModifierKindInstance;
            writeOptU32(w, m.object, NO_OBJ);
            w.f32(m.scale);
            writeOptStr(w, m.scaleAttr);
            w.bool(m.align);
            writeVec3(w, m.rotation);
            writeOptStr(w, m.rotationAttr);
            break;
        }
        default: {
            const m = k as ModifierKindExt;
            w.str(m.kind);
            writeStrMap(w, m.props);
            break;
        }
    }
}

function readModifierKind(r: PostcardReader): ModifierKind {
    const tag = r.variant(12);
    switch (tag) {
        case ModifierKindTag.Mirror: {
            const axis = readBool3(r);
            const clipping = r.bool();
            const merge = r.bool();
            const threshold = r.f32();
            return ModifierKindMirror.create(axis, clipping, merge, threshold);
        }
        case ModifierKindTag.Subsurf: {
            const levels = r.varU32();
            const render = r.varU32();
            return ModifierKindSubsurf.create(levels, render);
        }
        case ModifierKindTag.Array: {
            const count = r.varU32();
            const rel = readVec3(r);
            const cons = readVec3(r);
            const merge = r.bool();
            const threshold = r.f32();
            return ModifierKindArray.create(count, rel, cons, merge, threshold);
        }
        case ModifierKindTag.Solidify: {
            const thickness = r.f32();
            const offset = r.f32();
            const even = r.bool();
            return ModifierKindSolidify.create(thickness, offset, even);
        }
        case ModifierKindTag.Bevel: {
            const width = r.f32();
            const segments = r.varU32();
            const limit = r.f32();
            return ModifierKindBevel.create(width, segments, limit);
        }
        case ModifierKindTag.Triangulate: return ModifierKindTriangulate.create();
        case ModifierKindTag.Weld: return ModifierKindWeld.create(r.f32());
        case ModifierKindTag.EdgeSplit: return ModifierKindEdgeSplit.create(r.f32());
        case ModifierKindTag.Armature: {
            const object = readOptU32(r, NO_OBJ);
            const preserve = r.bool();
            const useVg = r.bool();
            const useEnv = r.bool();
            return ModifierKindArmature.create(object, preserve, useVg, useEnv);
        }
        case ModifierKindTag.Tool: {
            const tool = r.str();
            const params = readStrMap(r);
            const hash = r.varU64();
            return ModifierKindTool.create(tool, params, hash);
        }
        case ModifierKindTag.Instance: {
            const object = readOptU32(r, NO_OBJ);
            const scale = r.f32();
            const scaleAttr = readOptStr(r);
            const align = r.bool();
            const rotation = readVec3(r);
            const rotationAttr = readOptStr(r);
            return ModifierKindInstance.create(object, scale, scaleAttr, align, rotation, rotationAttr);
        }
        default: {
            const kind = r.str();
            const props = readStrMap(r);
            return ModifierKindExt.create(kind, props);
        }
    }
}

function writeObject(w: PostcardWriter, o: Object): void {
    w.str(o.name);
    writeObjectData(w, o.data);
    writeTransform(w, o.transform);
    const p = o.parent;
    if (p == null) {
        w.none();
    } else {
        w.some();
        w.varU32(p.id);
        w.variant(<u32>p.kind.tag);
        if (p.kind.tag == ParentKindTag.Bone) w.str(p.kind.bone);
    }
    writeMat4(w, o.parentInverse);
    w.bool(o.select);
    w.bool(o.hide);
    w.bool(o.hideRender);
    writeU32s(w, o.materialSlots);
    w.seqLen(o.modifiers.length);
    for (let i = 0; i < o.modifiers.length; i++) {
        const m = o.modifiers[i];
        w.str(m.name);
        writeModifierKind(w, m.kind);
        w.bool(m.enabled);
    }
    w.seqLen(o.vertexGroups.length);
    for (let i = 0; i < o.vertexGroups.length; i++) {
        w.str(o.vertexGroups[i].name);
        w.bool(o.vertexGroups[i].lock);
    }
    writeOptU32(w, o.activeVgroup, NO_VGROUP);
    const a = o.animation;
    if (a == null) {
        w.none();
    } else {
        w.some();
        writeOptU32(w, a.action, ACTION_NONE);
    }
}

function readObject(r: PostcardReader): Object {
    const name = r.str();
    const data = readObjectData(r);
    const o = new Object(name, data);
    o.transform = readTransform(r);
    if (r.option()) {
        const id = r.varU32();
        const tag = r.variant(3);
        let kind: ParentKind;
        if (tag == ParentKindTag.Bone) kind = ParentKind.boneOf(r.str());
        else if (tag == ParentKindTag.Armature) kind = ParentKind.armature();
        else kind = ParentKind.object();
        o.parent = new Parent(id, kind);
    }
    o.parentInverse = readMat4(r);
    o.select = r.bool();
    o.hide = r.bool();
    o.hideRender = r.bool();
    o.materialSlots = readU32s(r);
    const n = r.seqLen();
    for (let i: u64 = 0; i < n && !r.failed; i++) {
        const mname = r.str();
        const kind = readModifierKind(r);
        const enabled = r.bool();
        o.modifiers.push(new Modifier(mname, kind, enabled));
    }
    const g = r.seqLen();
    for (let i: u64 = 0; i < g && !r.failed; i++) {
        const gname = r.str();
        const lock = r.bool();
        o.vertexGroups.push(new VertexGroup(gname, lock));
    }
    o.activeVgroup = readOptU32(r, NO_VGROUP);
    if (r.option()) o.animation = new AnimData(readOptU32(r, ACTION_NONE));
    return o;
}

function writeTextureRef(w: PostcardWriter, t: TextureRef?): void {
    if (t == null) {
        w.none();
    } else {
        w.some();
        w.str(t.path);
        writeOptStr(w, t.uvLayer);
    }
}

function readTextureRef(r: PostcardReader): TextureRef? {
    if (!r.option()) return null;
    const path = r.str();
    const uv = readOptStr(r);
    return new TextureRef(path, uv);
}

function writeMaterial(w: PostcardWriter, m: Material): void {
    w.str(m.name);
    for (let i = 0; i < 3; i++) w.f32(m.baseColor[i]);
    w.f32(m.metallic);
    w.f32(m.roughness);
    for (let i = 0; i < 3; i++) w.f32(m.emission[i]);
    w.f32(m.emissionStrength);
    w.f32(m.alpha);
    w.variant(<u32>m.alphaMode);
    w.f32(m.alphaCutoff);
    w.bool(m.doubleSided);
    const t = m.textures;
    writeTextureRef(w, t.baseColor);
    writeTextureRef(w, t.normal);
    writeTextureRef(w, t.metallicRoughness);
    writeTextureRef(w, t.emission);
    writeTextureRef(w, t.occlusion);
}

function readF32s(r: PostcardReader, n: i32): Array<f32> {
    const out: Array<f32> = [];
    for (let i = 0; i < n; i++) out.push(r.f32());
    return out;
}

function readMaterial(r: PostcardReader): Material {
    const m = new Material();
    m.name = r.str();
    m.baseColor = readF32s(r, 3);
    m.metallic = r.f32();
    m.roughness = r.f32();
    m.emission = readF32s(r, 3);
    m.emissionStrength = r.f32();
    m.alpha = r.f32();
    m.alphaMode = <AlphaMode>r.variant(3);
    m.alphaCutoff = r.f32();
    m.doubleSided = r.bool();
    const t = new MaterialTextures();
    t.baseColor = readTextureRef(r);
    t.normal = readTextureRef(r);
    t.metallicRoughness = readTextureRef(r);
    t.emission = readTextureRef(r);
    t.occlusion = readTextureRef(r);
    m.textures = t;
    return m;
}

// ---------------------------------------------------------------------------
// Scene

// Serialize a scene body (no file header).
export function writeScene(w: PostcardWriter, s: Scene): void {
    const os = s.objects.slots;
    w.seqLen(os.length);
    for (let i = 0; i < os.length; i++) {
        const o = os[i];
        if (o == null) w.none();
        else { w.some(); writeObject(w, o); }
    }
    w.varU32(s.objects.live);
    writeOptU32(w, s.active, NO_OBJ);
    w.variant(<u32>s.mode);
    w.bool(s.selectMode.vert);
    w.bool(s.selectMode.edge);
    w.bool(s.selectMode.face);
    writeTransform(w, s.cursor);
    w.variant(<u32>s.pivot);
    w.variant(<u32>s.orientation);
    w.i32(s.frame);
    w.i32(s.frameRange.start);
    w.i32(s.frameRange.end);
    w.f32(s.fps);
    w.i32(s.frameStep);
    w.seqLen(s.materials.length);
    for (let i = 0; i < s.materials.length; i++) writeMaterial(w, s.materials[i]);
    const acts = s.actions.slots;
    w.seqLen(acts.length);
    for (let i = 0; i < acts.length; i++) {
        const a = acts[i];
        if (a == null) w.none();
        else { w.some(); writeAction(w, a); }
    }
    w.varU32(s.actions.live);
    const rd = s.renderDefaults;
    w.varU32(rd.size[0]);
    w.varU32(rd.size[1]);
    for (let i = 0; i < 4; i++) w.f32(rd.background[i]);
    w.str(rd.shading);
    w.seqLen(s.poseClipboard.length);
    for (let i = 0; i < s.poseClipboard.length; i++) {
        const c = s.poseClipboard[i];
        w.str(c.bone);
        writeVec3(w, c.location);
        writeQuat(w, c.rotation);
        writeVec3(w, c.scale);
    }
    w.seqLen(s.imports.length);
    for (let i = 0; i < s.imports.length; i++) {
        const rec = s.imports[i];
        w.str(rec.path);
        w.str(rec.hash);
        w.varU64(rec.bytes);
        writeStrs(w, rec.objects);
    }
    writeFileRefs(w, s);
}

// The tail: the materials that are MaterialX files (index, path), then the
// empties that instance a model (object slot, path), each in order. Left
// out when both are empty, and then only then: a tail of two empty lists is
// no encoding a writer makes, which readFileRefs refuses, so every body
// reads back to its own bytes.
function writeFileRefs(w: PostcardWriter, s: Scene): void {
    const mats = new Array<u32>();
    for (let i = 0; i < s.materials.length; i++) if (s.materials[i].file != null) mats.push(<u32>i);
    const empties = new Array<u32>();
    const os = s.objects.slots;
    for (let i = 0; i < os.length; i++) {
        const o = os[i];
        if (o == null || o.data.kind != ObjectDataKind.Empty) continue;
        if (o.data.emptyData!.instance != null) empties.push(<u32>i);
    }
    if (mats.length == 0 && empties.length == 0) return;
    w.seqLen(mats.length);
    for (let i = 0; i < mats.length; i++) {
        w.varU32(mats[i]);
        w.str(s.materials[<i32>mats[i]].file!);
    }
    w.seqLen(empties.length);
    for (let i = 0; i < empties.length; i++) {
        w.varU32(empties[i]);
        w.str(os[<i32>empties[i]]!.data.emptyData!.instance!);
    }
}

// The tail, when the body goes on after its imports. An index that is no
// material, a slot that is no empty, one named twice or out of order, an
// empty tail or bytes after it are DeserializeBadEncoding: none is what a
// writer makes.
function readFileRefs(r: PostcardReader, s: Scene): void {
    if (r.failed || r.remaining() == 0) return;
    let last: i64 = -1;
    const nm = r.seqLen();
    for (let i: u64 = 0; i < nm && !r.failed; i++) {
        const k = r.varU32();
        const path = r.str();
        if (r.failed) return;
        if (<i64>k <= last || k >= <u32>s.materials.length) {
            r.fail(PostcardError.DeserializeBadEncoding);
            return;
        }
        last = <i64>k;
        s.materials[<i32>k].file = path;
    }
    last = -1;
    const ne = r.seqLen();
    for (let i: u64 = 0; i < ne && !r.failed; i++) {
        const k = r.varU32();
        const path = r.str();
        if (r.failed) return;
        const o = k < <u32>s.objects.slots.length ? s.objects.slots[<i32>k] : null;
        if (<i64>k <= last || o == null || o.data.kind != ObjectDataKind.Empty) {
            r.fail(PostcardError.DeserializeBadEncoding);
            return;
        }
        last = <i64>k;
        o.data.emptyData!.instance = path;
    }
    if (!r.failed && ((nm == 0 && ne == 0) || r.remaining() > 0)) r.fail(PostcardError.DeserializeBadEncoding);
}

// Deserialize a scene body. Check `r.failed`
// afterwards: on failure the returned scene is partial and must be dropped.
export function readScene(r: PostcardReader): Scene {
    const s = new Scene();
    {
        const n = r.seqLen();
        const slots: Array<Object?> = [];
        for (let i: u64 = 0; i < n && !r.failed; i++) slots.push(r.option() ? readObject(r) : null);
        s.objects = SlotVec.fromSlots<Object>(slots, r.varU32());
    }
    s.active = readOptU32(r, NO_OBJ);
    s.mode = <Mode>r.variant(4);
    const sv = r.bool();
    const se = r.bool();
    const sf = r.bool();
    s.selectMode = SelectMode(sv, se, sf);
    s.cursor = readTransform(r);
    s.pivot = <Pivot>r.variant(5);
    s.orientation = <Orientation>r.variant(4);
    s.frame = r.i32();
    const start = r.i32();
    const end = r.i32();
    s.frameRange = FrameRangeI32(start, end);
    s.fps = r.f32();
    s.frameStep = r.i32();
    {
        const n = r.seqLen();
        for (let i: u64 = 0; i < n && !r.failed; i++) s.materials.push(readMaterial(r));
    }
    {
        const n = r.seqLen();
        const slots: Array<Action?> = [];
        for (let i: u64 = 0; i < n && !r.failed; i++) slots.push(r.option() ? readAction(r) : null);
        s.actions = SlotVec.fromSlots<Action>(slots, r.varU32());
    }
    {
        const rd = new RenderDefaults();
        const w0 = r.varU32();
        const h0 = r.varU32();
        const size: Array<u32> = [];
        size.push(w0);
        size.push(h0);
        rd.size = size;
        rd.background = readF32s(r, 4);
        rd.shading = r.str();
        s.renderDefaults = rd;
    }
    {
        const n = r.seqLen();
        for (let i: u64 = 0; i < n && !r.failed; i++) {
            const bone = r.str();
            const loc = readVec3(r);
            const rot = readQuat(r);
            const scale = readVec3(r);
            s.poseClipboard.push(new PoseClip(bone, loc, rot, scale));
        }
    }
    {
        const n = r.seqLen();
        for (let i: u64 = 0; i < n && !r.failed; i++) {
            const path = r.str();
            const hash = r.str();
            const bytes = r.varU64();
            const objects = readStrs(r);
            s.imports.push(new ImportRecord(path, hash, bytes, objects));
        }
    }
    readFileRefs(r, s);
    return s;
}

// The scene in postcard encoding: the scene body, without the file header.
export function encodeSceneBody(s: Scene): Uint8Array {
    const w = new PostcardWriter();
    writeScene(w, s);
    return w.finish();
}
