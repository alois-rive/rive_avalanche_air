// The data form's writer: a scene as data lines, in the order and with the
// flags docs/formats/RMDLCMD.md "The data form" gives (read.as reads them
// back). Every field the codec (engine/src/source/model/io/codec.as) writes has a
// place here, so that replaying the lines encodes to the same bytes.
//
// A field equal to its default is left out, compared bit for bit (so `-0`
// is written where the default is 0); a bool is a switch, present when
// true; a list of numbers is one double-quoted word. Ids are the slots'
// own, holes kept, so references need no renumbering.

import { Vec3, Vec4, Quat, Mat4, MAT4_IDENTITY } from "../../../../base/vecmath";
import { cmpStr, stableSort } from "../../../../base/util";
import { quoteToken } from "../lex";
import { f32Text, sameF32 } from "./num";
import { Mesh, Vert, Edge, Face, Loop, SelectionSet } from "../../mesh/mod";
import { AttrLayer, AttrType, Domain } from "../../mesh/attr";
import { ShapeKey } from "../../mesh/shapekey";
import { Armature, Bone, NO_BONE, boneDisplayName } from "../../armature/mod";
import {
    Constraint, ConstraintKindTag, ConstraintTarget, constraintSpaceName, rotationMixName, trackAxisName,
    ConstraintKindIk, ConstraintKindCopyLocation, ConstraintKindCopyRotation, ConstraintKindCopyScale,
    ConstraintKindCopyTransforms, ConstraintKindLimitRotation, ConstraintKindLimitLocation, ConstraintKindTrackTo,
    ConstraintKindDampedTrack, ConstraintKindStretchTo, ConstraintKindChildOf,
} from "../../armature/constraints";
import { Action, ACTION_NONE } from "../../anim/mod";
import { FCurve, Extrapolation, extrapolationName } from "../../anim/fcurve";
import {
    Scene, Object, ObjectDataKind, Transform, TRANSFORM_IDENTITY, EmptyDisplay, ParentKindTag, Modifier,
    ModifierKindTag, ModifierKindMirror, ModifierKindSubsurf, ModifierKindArray, ModifierKindSolidify,
    ModifierKindBevel, ModifierKindWeld, ModifierKindEdgeSplit, ModifierKindArmature, ModifierKindTool,
    ModifierKindInstance, ModifierKindExt, Material, TextureRef, NO_OBJ, NO_VGROUP, sortedKeys, modeName, pivotName, orientationName,
    alphaModeName, lightKindName, emptyDisplayName,
} from "../../scene";
import {
    CAMERA_TYPES, PARENT_TYPES, MODIFIER_KINDS, TEXTURE_SLOTS, sceneDefaults, materialDefaults, cameraDefaults,
    lightDefaults, boneDefaults, shapeKeyDefaults, renderDefaults,
} from "./words";

// One line being written: words joined by single spaces.
class Line {
    parts: Array<string>;

    constructor(record: string) {
        this.parts = ["data", record];
    }

    // A positional or a flag's value, quoted as needed.
    str(s: string): Line {
        this.parts.push(quoteToken(s));
        return this;
    }

    // A word that never needs quoting (a number, an enum word).
    word(s: string): Line {
        this.parts.push(s);
        return this;
    }

    u32(v: u32): Line {
        this.parts.push(v.toString());
        return this;
    }

    flag(name: string): Line {
        this.parts.push("--" + name);
        return this;
    }

    flagStr(name: string, s: string): Line {
        return this.flag(name).str(s);
    }

    flagWord(name: string, s: string): Line {
        return this.flag(name).word(s);
    }

    flagU32(name: string, v: u32): Line {
        return this.flag(name).word(v.toString());
    }

    flagI32(name: string, v: i32): Line {
        return this.flag(name).word(v.toString());
    }

    flagU64(name: string, v: u64): Line {
        return this.flag(name).word(v.toString());
    }

    flagF32(name: string, v: f32): Line {
        return this.flag(name).word(f32Text(v));
    }

    // A switch, present when on.
    sw(name: string, on: bool): Line {
        if (on) this.flag(name);
        return this;
    }

    // A list of numbers as one quoted word.
    flagNums(name: string, nums: Array<string>): Line {
        return this.flag(name).word("\"" + nums.join(" ") + "\"");
    }

    text(): string {
        return this.parts.join(" ");
    }
}

// ------------------------------------------------------------ number lists

function pushF32(out: Array<string>, v: f32): void {
    out.push(f32Text(v));
}

function pushVec3(out: Array<string>, v: Vec3): void {
    out.push(f32Text(v.x));
    out.push(f32Text(v.y));
    out.push(f32Text(v.z));
}

function vec3Nums(v: Vec3): Array<string> {
    const out: Array<string> = [];
    pushVec3(out, v);
    return out;
}

function quatNums(q: Quat): Array<string> {
    return [f32Text(q.x), f32Text(q.y), f32Text(q.z), f32Text(q.w)];
}

function sameVec3(a: Vec3, b: Vec3): bool {
    return sameF32(a.x, b.x) && sameF32(a.y, b.y) && sameF32(a.z, b.z);
}

function sameQuat(a: Quat, b: Quat): bool {
    return sameF32(a.x, b.x) && sameF32(a.y, b.y) && sameF32(a.z, b.z) && sameF32(a.w, b.w);
}

function sameVec4(a: Vec4, b: Vec4): bool {
    return sameF32(a.x, b.x) && sameF32(a.y, b.y) && sameF32(a.z, b.z) && sameF32(a.w, b.w);
}

function sameMat4(a: Mat4, b: Mat4): bool {
    return sameVec4(a.xAxis, b.xAxis) && sameVec4(a.yAxis, b.yAxis) && sameVec4(a.zAxis, b.zAxis)
        && sameVec4(a.wAxis, b.wAxis);
}

function pushVec4(out: Array<string>, v: Vec4): void {
    out.push(f32Text(v.x));
    out.push(f32Text(v.y));
    out.push(f32Text(v.z));
    out.push(f32Text(v.w));
}

// Column major, as the codec writes it.
function mat4Nums(m: Mat4): Array<string> {
    const out: Array<string> = [];
    pushVec4(out, m.xAxis);
    pushVec4(out, m.yAxis);
    pushVec4(out, m.zAxis);
    pushVec4(out, m.wAxis);
    return out;
}

function sameF32s(a: Array<f32>, b: Array<f32>): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (!sameF32(a[i], b[i])) return false;
    return true;
}

function f32Nums(a: Array<f32>): Array<string> {
    const out: Array<string> = [];
    for (let i = 0; i < a.length; i++) out.push(f32Text(a[i]));
    return out;
}

function u32Nums(a: Array<u32>): Array<string> {
    const out: Array<string> = [];
    for (let i = 0; i < a.length; i++) out.push(a[i].toString());
    return out;
}

function bitNums(a: Array<bool>): Array<string> {
    const out: Array<string> = [];
    for (let i = 0; i < a.length; i++) out.push(a[i] ? "1" : "0");
    return out;
}

function allTrue(a: Array<bool>): bool {
    for (let i = 0; i < a.length; i++) if (!a[i]) return false;
    return true;
}

function anyTrue(a: Array<bool>): bool {
    for (let i = 0; i < a.length; i++) if (a[i]) return true;
    return false;
}

// The ids of a slot list's holes.
function holes<T>(slots: Array<T?>): Array<string> {
    const out: Array<string> = [];
    for (let i = 0; i < slots.length; i++) if (slots[i] == null) out.push(i.toString());
    return out;
}

// `--x N`, `--x-holes "..."` and `--x-live N` of a slot list: the slot
// count, the holes, and the codec's live count when it is not the number of
// present slots (it always is, for a scene Hedra made).
function slotFlags<T>(l: Line, name: string, holesName: string, slots: Array<T?>, live: u32): void {
    if (slots.length > 0) l.flagU32(name, <u32>slots.length);
    const h = holes<T>(slots);
    if (h.length > 0) l.flagNums(holesName, h);
    const present = <u32>(slots.length - h.length);
    if (live != present) l.flagU32(name + "-live", live);
}

// ------------------------------------------------------------ records

function sceneLine(s: Scene): string {
    const l = new Line("scene");
    slotFlags<Object>(l, "objects", "object-holes", s.objects.slots, s.objects.live);
    slotFlags<Action>(l, "actions", "action-holes", s.actions.slots, s.actions.live);
    const d = sceneDefaults();
    if (s.active != NO_OBJ) l.flagU32("active", s.active);
    if (s.mode != d.mode) l.flagWord("mode", modeName(s.mode));
    const sm = s.selectMode;
    if (sm.vert != d.selectMode.vert || sm.edge != d.selectMode.edge || sm.face != d.selectMode.face) {
        l.flagNums("select-mode", [sm.vert ? "1" : "0", sm.edge ? "1" : "0", sm.face ? "1" : "0"]);
    }
    if (!sameTransform(s.cursor, TRANSFORM_IDENTITY)) l.flagNums("cursor", transformNums(s.cursor));
    if (s.pivot != d.pivot) l.flagWord("pivot", pivotName(s.pivot));
    if (s.orientation != d.orientation) l.flagWord("orientation", orientationName(s.orientation));
    if (s.frame != d.frame) l.flagI32("frame", s.frame);
    if (s.frameRange.start != d.frameRange.start || s.frameRange.end != d.frameRange.end) {
        l.flagNums("frame-range", [s.frameRange.start.toString(), s.frameRange.end.toString()]);
    }
    if (!sameF32(s.fps, d.fps)) l.flagF32("fps", s.fps);
    if (s.frameStep != d.frameStep) l.flagI32("frame-step", s.frameStep);
    const r = s.renderDefaults;
    const rd = renderDefaults();
    if (r.size[0] != rd.size[0] || r.size[1] != rd.size[1]) l.flagNums("render-size", u32Nums(r.size));
    if (!sameF32s(r.background, rd.background)) l.flagNums("render-background", f32Nums(r.background));
    if (r.shading != rd.shading) l.flagStr("render-shading", r.shading);
    return l.text();
}

function sameTransform(a: Transform, b: Transform): bool {
    return sameVec3(a.location, b.location) && sameVec3(a.rotation, b.rotation) && sameVec3(a.scale, b.scale);
}

function transformNums(t: Transform): Array<string> {
    const out: Array<string> = [];
    pushVec3(out, t.location);
    pushVec3(out, t.rotation);
    pushVec3(out, t.scale);
    return out;
}

function textureFlags(l: Line, slot: string, t: TextureRef?): void {
    if (t == null) return;
    l.flagStr(slot + "-texture", t.path);
    const uv = t.uvLayer;
    if (uv != null) l.flagStr(slot + "-uv", uv);
}

function materialLine(index: i32, m: Material): string {
    const d = materialDefaults();
    const l = new Line("material").u32(<u32>index).str(m.name);
    const file = m.file;
    if (file != null) l.flagStr("file", file);
    if (!sameF32s(m.baseColor, d.baseColor)) l.flagNums("base-color", f32Nums(m.baseColor));
    if (!sameF32(m.metallic, d.metallic)) l.flagF32("metallic", m.metallic);
    if (!sameF32(m.roughness, d.roughness)) l.flagF32("roughness", m.roughness);
    if (!sameF32s(m.emission, d.emission)) l.flagNums("emission", f32Nums(m.emission));
    if (!sameF32(m.emissionStrength, d.emissionStrength)) l.flagF32("emission-strength", m.emissionStrength);
    if (!sameF32(m.alpha, d.alpha)) l.flagF32("alpha", m.alpha);
    if (m.alphaMode != d.alphaMode) l.flagWord("alpha-mode", alphaModeName(m.alphaMode));
    if (!sameF32(m.alphaCutoff, d.alphaCutoff)) l.flagF32("alpha-cutoff", m.alphaCutoff);
    l.sw("double-sided", m.doubleSided);
    const t = m.textures;
    textureFlags(l, TEXTURE_SLOTS[0], t.baseColor);
    textureFlags(l, TEXTURE_SLOTS[1], t.normal);
    textureFlags(l, TEXTURE_SLOTS[2], t.metallicRoughness);
    textureFlags(l, TEXTURE_SLOTS[3], t.emission);
    textureFlags(l, TEXTURE_SLOTS[4], t.occlusion);
    return l.text();
}

function fcurveLine(actionId: u32, c: FCurve): string {
    const l = new Line("fcurve").u32(actionId).str(c.dataPath).u32(c.arrayIndex);
    if (c.keyframes.length > 0) {
        const nums: Array<string> = [];
        for (let i = 0; i < c.keyframes.length; i++) {
            const k = c.keyframes[i];
            pushF32(nums, k.frame);
            pushF32(nums, k.value);
            nums.push((<u32>k.interpolation).toString());
            nums.push((<u32>k.easing).toString());
            pushF32(nums, k.handleLeft.x);
            pushF32(nums, k.handleLeft.y);
            pushF32(nums, k.handleRight.x);
            pushF32(nums, k.handleRight.y);
            nums.push((<u32>k.handleType).toString());
            pushF32(nums, k.back);
            pushF32(nums, k.amplitude);
            pushF32(nums, k.period);
        }
        l.flagNums("keys", nums);
    }
    if (c.extrapolation != Extrapolation.Constant) l.flagWord("extrapolation", extrapolationName(c.extrapolation));
    l.sw("mute", c.mute);
    return l.text();
}

function objectLine(id: u32, o: Object): string {
    const l = new Line("object").u32(id).str(o.name);
    const data = o.data;
    l.flagWord("type", data.typeName());
    if (!sameTransform(o.transform, TRANSFORM_IDENTITY)) l.flagNums("transform", transformNums(o.transform));
    const p = o.parent;
    if (p != null) {
        l.flagU32("parent", p.id);
        if (p.kind.tag != ParentKindTag.Object) l.flagWord("parent-type", PARENT_TYPES[<i32>p.kind.tag]);
        if (p.kind.tag == ParentKindTag.Bone) l.flagStr("parent-bone", p.kind.bone);
    }
    if (!sameMat4(o.parentInverse, MAT4_IDENTITY)) l.flagNums("parent-inverse", mat4Nums(o.parentInverse));
    l.sw("select", o.select);
    l.sw("hide", o.hide);
    l.sw("hide-render", o.hideRender);
    if (o.materialSlots.length > 0) l.flagNums("material-slots", u32Nums(o.materialSlots));
    if (o.activeVgroup != NO_VGROUP) l.flagU32("active-vgroup", o.activeVgroup);
    const a = o.animation;
    if (a != null) {
        if (a.action == ACTION_NONE) l.flagWord("animation", "none");
        else l.flagU32("animation", a.action);
    }
    switch (data.kind) {
        case ObjectDataKind.Camera: {
            const c = data.cameraData!;
            const d = cameraDefaults();
            if (c.kind != d.kind) l.flagWord("camera-type", CAMERA_TYPES[<i32>c.kind]);
            if (!sameF32(c.focalLengthMm, d.focalLengthMm)) l.flagF32("focal-length", c.focalLengthMm);
            if (!sameF32(c.orthoScale, d.orthoScale)) l.flagF32("ortho-scale", c.orthoScale);
            if (!sameF32(c.clipStart, d.clipStart)) l.flagF32("clip-start", c.clipStart);
            if (!sameF32(c.clipEnd, d.clipEnd)) l.flagF32("clip-end", c.clipEnd);
            break;
        }
        case ObjectDataKind.Light: {
            const g = data.lightData!;
            const d = lightDefaults();
            if (g.kind != d.kind) l.flagWord("light-type", lightKindName(g.kind));
            if (!sameVec3(g.color, d.color)) l.flagNums("color", vec3Nums(g.color));
            if (!sameF32(g.energy, d.energy)) l.flagF32("energy", g.energy);
            break;
        }
        case ObjectDataKind.Empty: {
            const e = data.emptyData!;
            if (e.display != EmptyDisplay.PlainAxes) l.flagWord("empty-display", emptyDisplayName(e.display));
            if (!sameF32(e.size, 0)) l.flagF32("empty-size", e.size);
            const instance = e.instance;
            if (instance != null) l.flagStr("instance", instance);
            break;
        }
        default: break;
    }
    return l.text();
}

function paramFlags(l: Line, name: string, m: Map<string, string>): void {
    const keys = sortedKeys(m);
    for (let i = 0; i < keys.length; i++) l.flagStr(name, keys[i] + "=" + m.get(keys[i]));
}

function optObj(l: Line, name: string, id: u32): void {
    if (id != NO_OBJ) l.flagU32(name, id);
}

function modifierLine(objId: u32, m: Modifier): string {
    const k = m.kind;
    const l = new Line("modifier").u32(objId).str(m.name).word(MODIFIER_KINDS[<i32>k.tag]);
    l.sw("disabled", !m.enabled);
    switch (k.tag) {
        case ModifierKindTag.Mirror: {
            const x = k as ModifierKindMirror;
            if (anyTrue(x.axis)) l.flagNums("axis", bitNums(x.axis));
            l.sw("clipping", x.clipping);
            l.sw("merge", x.merge);
            if (!sameF32(x.mergeThreshold, 0)) l.flagF32("merge-threshold", x.mergeThreshold);
            break;
        }
        case ModifierKindTag.Subsurf: {
            const x = k as ModifierKindSubsurf;
            if (x.levels != 0) l.flagU32("levels", x.levels);
            if (x.renderLevels != 0) l.flagU32("render-levels", x.renderLevels);
            break;
        }
        case ModifierKindTag.Array: {
            const x = k as ModifierKindArray;
            if (x.count != 0) l.flagU32("count", x.count);
            if (!sameVec3(x.relativeOffset, Vec3(0, 0, 0))) l.flagNums("relative-offset", vec3Nums(x.relativeOffset));
            if (!sameVec3(x.constantOffset, Vec3(0, 0, 0))) l.flagNums("constant-offset", vec3Nums(x.constantOffset));
            l.sw("merge", x.merge);
            if (!sameF32(x.mergeThreshold, 0)) l.flagF32("merge-threshold", x.mergeThreshold);
            break;
        }
        case ModifierKindTag.Solidify: {
            const x = k as ModifierKindSolidify;
            if (!sameF32(x.thickness, 0)) l.flagF32("thickness", x.thickness);
            if (!sameF32(x.offset, 0)) l.flagF32("offset", x.offset);
            l.sw("even", x.even);
            break;
        }
        case ModifierKindTag.Bevel: {
            const x = k as ModifierKindBevel;
            if (!sameF32(x.width, 0)) l.flagF32("width", x.width);
            if (x.segments != 0) l.flagU32("segments", x.segments);
            if (!sameF32(x.angleLimit, 0)) l.flagF32("angle-limit", x.angleLimit);
            break;
        }
        case ModifierKindTag.Triangulate: break;
        case ModifierKindTag.Weld: {
            const x = k as ModifierKindWeld;
            if (!sameF32(x.distance, 0)) l.flagF32("distance", x.distance);
            break;
        }
        case ModifierKindTag.EdgeSplit: {
            const x = k as ModifierKindEdgeSplit;
            if (!sameF32(x.angle, 0)) l.flagF32("angle", x.angle);
            break;
        }
        case ModifierKindTag.Armature: {
            const x = k as ModifierKindArmature;
            optObj(l, "object", x.object);
            l.sw("preserve-volume", x.preserveVolume);
            l.sw("use-vertex-groups", x.useVertexGroups);
            l.sw("use-envelopes", x.useEnvelopes);
            break;
        }
        case ModifierKindTag.Tool: {
            const x = k as ModifierKindTool;
            if (x.tool.length > 0) l.flagStr("tool", x.tool);
            paramFlags(l, "param", x.params);
            if (x.hash != 0) l.flagU64("hash", x.hash);
            break;
        }
        case ModifierKindTag.Instance: {
            const x = k as ModifierKindInstance;
            optObj(l, "object", x.object);
            if (!sameF32(x.scale, 0)) l.flagF32("scale", x.scale);
            const sa = x.scaleAttr;
            if (sa != null) l.flagStr("scale-attr", sa);
            l.sw("align", x.align);
            if (!sameVec3(x.rotation, Vec3(0, 0, 0))) l.flagNums("rotation", vec3Nums(x.rotation));
            const ra = x.rotationAttr;
            if (ra != null) l.flagStr("rotation-attr", ra);
            break;
        }
        default: {
            const x = k as ModifierKindExt;
            l.flagStr("ext-kind", x.kind);
            paramFlags(l, "prop", x.props);
            break;
        }
    }
    return l.text();
}

// Per-element lists hold one value per present slot, in id order; an
// optional one whose values are all 0 is left out (the reader fills zeros).
function meshLine(objId: u32, m: Mesh): string {
    const l = new Line("mesh").u32(objId);
    // Vertices.
    const vs = m.verts.slots;
    slotFlags<Vert>(l, "verts", "vert-holes", vs, m.verts.live);
    {
        const co: Array<string> = [];
        const flags: Array<string> = [];
        const groups: Array<string> = [];
        let anyFlag = false;
        let anyGroup = false;
        for (let i = 0; i < vs.length; i++) {
            const v = vs[i];
            if (v == null) continue;
            pushVec3(co, v.co);
            const f = (v.select ? 1 : 0) | (v.hide ? 2 : 0);
            if (f != 0) anyFlag = true;
            flags.push(f.toString());
            groups.push(v.groups.length.toString());
            if (v.groups.length > 0) anyGroup = true;
            for (let k = 0; k < v.groups.length; k++) {
                groups.push(v.groups[k].group.toString());
                groups.push(f32Text(v.groups[k].weight));
            }
        }
        if (co.length > 0) l.flagNums("co", co);
        if (anyFlag) l.flagNums("vert-flags", flags);
        if (anyGroup) l.flagNums("vert-groups", groups);
    }
    // Edges.
    const es = m.edges.slots;
    slotFlags<Edge>(l, "edges", "edge-holes", es, m.edges.live);
    {
        const ev: Array<string> = [];
        const flags: Array<string> = [];
        const crease: Array<string> = [];
        const bevel: Array<string> = [];
        let anyFlag = false;
        let anyCrease = false;
        let anyBevel = false;
        for (let i = 0; i < es.length; i++) {
            const e = es[i];
            if (e == null) continue;
            ev.push(e.v[0].toString());
            ev.push(e.v[1].toString());
            const f = (e.select ? 1 : 0) | (e.hide ? 2 : 0) | (e.seam ? 4 : 0) | (e.sharp ? 8 : 0);
            if (f != 0) anyFlag = true;
            flags.push(f.toString());
            if (!sameF32(e.crease, 0)) anyCrease = true;
            crease.push(f32Text(e.crease));
            if (!sameF32(e.bevelWeight, 0)) anyBevel = true;
            bevel.push(f32Text(e.bevelWeight));
        }
        if (ev.length > 0) l.flagNums("edge-verts", ev);
        if (anyFlag) l.flagNums("edge-flags", flags);
        if (anyCrease) l.flagNums("crease", crease);
        if (anyBevel) l.flagNums("bevel-weight", bevel);
    }
    // Faces.
    const fs = m.faces.slots;
    slotFlags<Face>(l, "faces", "face-holes", fs, m.faces.live);
    {
        const fl: Array<string> = [];
        const normals: Array<string> = [];
        const flags: Array<string> = [];
        const mats: Array<string> = [];
        let anyNormal = false;
        let anyFlag = false;
        let anyMat = false;
        for (let i = 0; i < fs.length; i++) {
            const f = fs[i];
            if (f == null) continue;
            fl.push(f.loopStart.toString());
            fl.push(f.loopLen.toString());
            if (!sameVec3(f.normal, Vec3(0, 0, 0))) anyNormal = true;
            pushVec3(normals, f.normal);
            const b = (f.smooth ? 1 : 0) | (f.select ? 2 : 0) | (f.hide ? 4 : 0);
            if (b != 0) anyFlag = true;
            flags.push(b.toString());
            if (f.materialIndex != 0) anyMat = true;
            mats.push(f.materialIndex.toString());
        }
        if (fl.length > 0) l.flagNums("face-loops", fl);
        if (anyNormal) l.flagNums("face-normals", normals);
        if (anyFlag) l.flagNums("face-flags", flags);
        if (anyMat) l.flagNums("face-materials", mats);
    }
    // Loops.
    const ls = m.loops.slots;
    slotFlags<Loop>(l, "loops", "loop-holes", ls, m.loops.live);
    {
        const refs: Array<string> = [];
        const uvs: Array<string> = [];
        const uvFlags: Array<string> = [];
        let anyUv = false;
        let anyUvFlag = false;
        for (let i = 0; i < ls.length; i++) {
            const lp = ls[i];
            if (lp == null) continue;
            refs.push(lp.vert.toString());
            refs.push(lp.edge.toString());
            refs.push(lp.face.toString());
            uvs.push(lp.uv.length.toString());
            if (lp.uv.length > 0) anyUv = true;
            for (let k = 0; k < lp.uv.length; k++) {
                uvs.push(f32Text(lp.uv[k].x));
                uvs.push(f32Text(lp.uv[k].y));
            }
            uvFlags.push(lp.uvFlags.length.toString());
            if (lp.uvFlags.length > 0) anyUvFlag = true;
            for (let k = 0; k < lp.uvFlags.length; k++) uvFlags.push(lp.uvFlags[k].toString());
        }
        if (refs.length > 0) l.flagNums("loop-refs", refs);
        if (anyUv) l.flagNums("loop-uvs", uvs);
        if (anyUvFlag) l.flagNums("loop-uv-flags", uvFlags);
    }
    for (let i = 0; i < m.uvLayers.length; i++) l.flagStr("uv-layer", m.uvLayers[i].name);
    if (m.activeUv != 0) l.flagU32("active-uv", m.activeUv);
    if (m.selectionHistory.length > 0) {
        const h: Array<string> = [];
        for (let i = 0; i < m.selectionHistory.length; i++) {
            h.push((<u32>m.selectionHistory[i].kind).toString());
            h.push(m.selectionHistory[i].id.toString());
        }
        l.flagNums("select-history", h);
    }
    if (m.activeShapeKey != 0) l.flagU32("active-shape-key", m.activeShapeKey);
    return l.text();
}

function shapeKeyLine(objId: u32, k: ShapeKey): string {
    const d = shapeKeyDefaults();
    const l = new Line("shapekey").u32(objId).str(k.name);
    if (!sameF32(k.value, d.value)) l.flagF32("value", k.value);
    if (!sameF32(k.sliderMin, d.sliderMin)) l.flagF32("slider-min", k.sliderMin);
    if (!sameF32(k.sliderMax, d.sliderMax)) l.flagF32("slider-max", k.sliderMax);
    if (k.relativeTo != d.relativeTo) l.flagU32("relative-to", k.relativeTo);
    l.sw("mute", k.mute);
    if (k.positions.length > 0) {
        const co: Array<string> = [];
        for (let i = 0; i < k.positions.length; i++) pushVec3(co, k.positions[i]);
        l.flagNums("co", co);
    }
    return l.text();
}

function attributeLine(objId: u32, a: AttrLayer): string {
    const l = new Line("attribute").u32(objId).str(a.name);
    if (a.domain != Domain.Point) l.flagWord("domain", Domain.name(a.domain));
    const d = a.data;
    if (d.kind != AttrType.Float) l.flagWord("type", AttrType.name(d.kind));
    const nums: Array<string> = [];
    switch (d.kind) {
        case AttrType.Float: {
            for (let i = 0; i < d.floats.length; i++) nums.push(f32Text(d.floats[i]));
            break;
        }
        case AttrType.Int: {
            for (let i = 0; i < d.ints.length; i++) nums.push(d.ints[i].toString());
            break;
        }
        case AttrType.Bool: {
            for (let i = 0; i < d.bools.length; i++) nums.push(d.bools[i] ? "1" : "0");
            break;
        }
        default: {
            for (let i = 0; i < d.vecs.length; i++) pushVec3(nums, d.vecs[i]);
            break;
        }
    }
    if (nums.length > 0) l.flagNums("values", nums);
    return l.text();
}

function selectionSetLine(objId: u32, name: string, s: SelectionSet): string {
    const l = new Line("selection-set").u32(objId).str(name);
    if (s.verts.length > 0) l.flagNums("verts", u32Nums(s.verts));
    if (s.edges.length > 0) l.flagNums("edges", u32Nums(s.edges));
    if (s.faces.length > 0) l.flagNums("faces", u32Nums(s.faces));
    return l.text();
}

function armatureLine(objId: u32, a: Armature): string {
    const l = new Line("armature").u32(objId);
    slotFlags<Bone>(l, "bones", "bone-holes", a.bones.slots, a.bones.live);
    if (a.active != NO_BONE) l.flagU32("active", a.active);
    if (a.display != 0) l.flagWord("display", boneDisplayName(a.display));
    for (let i = 0; i < a.collections.length; i++) {
        l.flagStr("collection", a.collections[i].name).word(a.collections[i].hide ? "1" : "0");
    }
    return l.text();
}

function boneLine(objId: u32, id: u32, b: Bone): string {
    const d = boneDefaults();
    const l = new Line("bone").u32(objId).u32(id).str(b.name);
    if (!sameVec3(b.head, d.head)) l.flagNums("head", vec3Nums(b.head));
    if (!sameVec3(b.tail, d.tail)) l.flagNums("tail", vec3Nums(b.tail));
    if (!sameF32(b.roll, d.roll)) l.flagF32("roll", b.roll);
    if (b.parent != NO_BONE) l.flagU32("parent", b.parent);
    l.sw("connected", b.connected);
    l.sw("deform", b.deform);
    l.sw("inherit-rotation", b.inheritRotation);
    l.sw("inherit-scale", b.inheritScale);
    if (!sameF32(b.envelopeDistance, d.envelopeDistance) || !sameF32(b.envelopeWeight, d.envelopeWeight)) {
        l.flagNums("envelope", [f32Text(b.envelopeDistance), f32Text(b.envelopeWeight)]);
    }
    if (!sameF32(b.headRadius, d.headRadius) || !sameF32(b.tailRadius, d.tailRadius)) {
        l.flagNums("radius", [f32Text(b.headRadius), f32Text(b.tailRadius)]);
    }
    for (let i = 0; i < b.collections.length; i++) l.flagStr("collection", b.collections[i]);
    l.sw("select", b.select);
    l.sw("select-head", b.selectHead);
    l.sw("select-tail", b.selectTail);
    l.sw("hide", b.hide);
    const p = b.pose;
    if (!sameVec3(p.location, Vec3(0, 0, 0))) l.flagNums("pose-location", vec3Nums(p.location));
    if (!sameQuat(p.rotation, Quat(0, 0, 0, 1))) l.flagNums("pose-rotation", quatNums(p.rotation));
    if (!sameVec3(p.scale, Vec3(1, 1, 1))) l.flagNums("pose-scale", vec3Nums(p.scale));
    l.sw("pose-select", p.select);
    l.sw("pose-hide", p.hide);
    return l.text();
}

// No --target: the target's object was deleted (cleared, as Blender's None).
function targetFlags(l: Line, t: ConstraintTarget): void {
    if (t.object == NO_OBJ) return;
    l.flagU32("target", t.object);
    const s = t.subtarget;
    if (s != null) l.flagStr("subtarget", s);
}

function axesFlag(l: Line, name: string, a: Array<bool>, dflt: bool): void {
    if (dflt ? !allTrue(a) : anyTrue(a)) l.flagNums(name, bitNums(a));
}

function minMaxFlags(l: Line, mn: Vec3, mx: Vec3): void {
    if (!sameVec3(mn, Vec3(0, 0, 0))) l.flagNums("min", vec3Nums(mn));
    if (!sameVec3(mx, Vec3(0, 0, 0))) l.flagNums("max", vec3Nums(mx));
}

function constraintLine(objId: u32, boneId: u32, c: Constraint): string {
    const k = c.kind;
    const l = new Line("constraint").u32(objId).u32(boneId).str(c.name).word(k.typeName());
    if (!sameF32(c.influence, 1)) l.flagF32("influence", c.influence);
    l.sw("disabled", !c.enabled);
    // The space a new constraint of the kind starts in is the default.
    const t = k.tag;
    const dflt = t == ConstraintKindTag.LimitRotation || t == ConstraintKindTag.LimitLocation ? 1 : 0;
    if (<i32>c.space != dflt) l.flagWord("space", constraintSpaceName(c.space));
    switch (t) {
        case ConstraintKindTag.Ik: {
            const x = k as ConstraintKindIk;
            targetFlags(l, x.target);
            const p = x.pole;
            if (p != null) {
                l.flagU32("pole", p.object);
                const s = p.subtarget;
                if (s != null) l.flagStr("pole-subtarget", s);
            }
            if (!sameF32(x.poleAngle, 0)) l.flagF32("pole-angle", x.poleAngle);
            if (x.chainLength != 0) l.flagU32("chain-length", x.chainLength);
            if (x.iterations != 0) l.flagU32("iterations", x.iterations);
            l.sw("use-tail", x.useTail);
            break;
        }
        case ConstraintKindTag.CopyLocation: {
            const x = k as ConstraintKindCopyLocation;
            targetFlags(l, x.target);
            axesFlag(l, "axes", x.axes, true);
            axesFlag(l, "invert", x.invert, false);
            l.sw("offset", x.offset);
            break;
        }
        case ConstraintKindTag.CopyRotation: {
            const x = k as ConstraintKindCopyRotation;
            targetFlags(l, x.target);
            axesFlag(l, "axes", x.axes, true);
            if (x.mix != 0) l.flagWord("mix", rotationMixName(x.mix));
            break;
        }
        case ConstraintKindTag.CopyScale: {
            const x = k as ConstraintKindCopyScale;
            targetFlags(l, x.target);
            axesFlag(l, "axes", x.axes, true);
            break;
        }
        case ConstraintKindTag.CopyTransforms: {
            const x = k as ConstraintKindCopyTransforms;
            targetFlags(l, x.target);
            if (x.mix != 0) l.flagWord("mix", rotationMixName(x.mix));
            break;
        }
        case ConstraintKindTag.LimitRotation: {
            const x = k as ConstraintKindLimitRotation;
            minMaxFlags(l, x.min, x.max);
            axesFlag(l, "axes", x.axes, true);
            break;
        }
        case ConstraintKindTag.LimitLocation: {
            const x = k as ConstraintKindLimitLocation;
            minMaxFlags(l, x.min, x.max);
            axesFlag(l, "use-min", x.useMin, false);
            axesFlag(l, "use-max", x.useMax, false);
            break;
        }
        case ConstraintKindTag.TrackTo: {
            const x = k as ConstraintKindTrackTo;
            targetFlags(l, x.target);
            if (x.track != 1) l.flagWord("track", trackAxisName(x.track));
            if (x.up != 1) l.flagWord("up", trackAxisName(x.up));
            break;
        }
        case ConstraintKindTag.DampedTrack: {
            const x = k as ConstraintKindDampedTrack;
            targetFlags(l, x.target);
            if (x.track != 1) l.flagWord("track", trackAxisName(x.track));
            break;
        }
        case ConstraintKindTag.StretchTo: {
            const x = k as ConstraintKindStretchTo;
            targetFlags(l, x.target);
            if (!sameF32(x.restLength, 0)) l.flagF32("rest-length", x.restLength);
            l.sw("volume", x.volume);
            break;
        }
        default: {
            const x = k as ConstraintKindChildOf;
            targetFlags(l, x.target);
            if (!sameMat4(x.inverse, MAT4_IDENTITY)) l.flagNums("inverse", mat4Nums(x.inverse));
            break;
        }
    }
    return l.text();
}

// ------------------------------------------------------------ the scene

// The lines of a scene, in RMDLCMD.md's order.
export function sceneLines(s: Scene): Array<string> {
    const out: Array<string> = [];
    out.push(sceneLine(s));
    for (let i = 0; i < s.materials.length; i++) out.push(materialLine(i, s.materials[i]));
    const acts = s.actions.slots;
    for (let i = 0; i < acts.length; i++) {
        const a = acts[i];
        if (a == null) continue;
        out.push(new Line("action").u32(<u32>i).str(a.name).text());
        for (let k = 0; k < a.fcurves.length; k++) out.push(fcurveLine(<u32>i, a.fcurves[k]));
    }
    const os = s.objects.slots;
    for (let i = 0; i < os.length; i++) {
        const o = os[i];
        if (o == null) continue;
        const id = <u32>i;
        out.push(objectLine(id, o));
        for (let k = 0; k < o.vertexGroups.length; k++) {
            const g = o.vertexGroups[k];
            out.push(new Line("vgroup").u32(id).str(g.name).sw("lock", g.lock).text());
        }
        for (let k = 0; k < o.modifiers.length; k++) out.push(modifierLine(id, o.modifiers[k]));
        const m = o.data.mesh();
        if (m != null) {
            out.push(meshLine(id, m));
            for (let k = 0; k < m.shapeKeys.length; k++) out.push(shapeKeyLine(id, m.shapeKeys[k]));
            for (let k = 0; k < m.attributes.length; k++) out.push(attributeLine(id, m.attributes[k]));
            // By name, as the codec writes them.
            const names = m.savedSelections.keys();
            stableSort<string>(names, cmpStr);
            for (let k = 0; k < names.length; k++) out.push(selectionSetLine(id, names[k], m.savedSelections.get(names[k])));
        }
        const a = o.data.armature();
        if (a != null) {
            out.push(armatureLine(id, a));
            const bs = a.bones.slots;
            for (let b = 0; b < bs.length; b++) {
                const bone = bs[b];
                if (bone == null) continue;
                out.push(boneLine(id, <u32>b, bone));
                const cs = bone.pose.constraints;
                for (let k = 0; k < cs.length; k++) out.push(constraintLine(id, <u32>b, cs[k]));
            }
        }
    }
    for (let i = 0; i < s.poseClipboard.length; i++) {
        const c = s.poseClipboard[i];
        const l = new Line("pose-clip").str(c.bone);
        if (!sameVec3(c.location, Vec3(0, 0, 0))) l.flagNums("location", vec3Nums(c.location));
        if (!sameQuat(c.rotation, Quat(0, 0, 0, 1))) l.flagNums("rotation", quatNums(c.rotation));
        if (!sameVec3(c.scale, Vec3(1, 1, 1))) l.flagNums("scale", vec3Nums(c.scale));
        out.push(l.text());
    }
    for (let i = 0; i < s.imports.length; i++) {
        const r = s.imports[i];
        const l = new Line("import").str(r.path);
        if (r.hash.length > 0) l.flagStr("hash", r.hash);
        if (r.bytes != 0) l.flagU64("bytes", r.bytes);
        for (let k = 0; k < r.objects.length; k++) l.flagStr("object", r.objects[k]);
        out.push(l.text());
    }
    return out;
}
