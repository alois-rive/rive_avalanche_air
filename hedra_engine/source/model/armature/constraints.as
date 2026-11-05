// Pose-bone constraint data. The evaluation is in pose.as (one function per
// kind) and the IK solver in ik.as.
//
// ConstraintKind is an abstract class with one subclass per kind
// (ConstraintKindIk, ConstraintKindCopyLocation, ...) and a `tag` getter
// returning ConstraintKindTag (variant order = the postcard variant index):
//
//   switch (c.kind.tag) { case ConstraintKindTag.Ik: { const k = c.kind as ConstraintKindIk; .. } }
//
// Field order is the file format. Per-axis flags are an Array<bool> of
// length 3, copied by `create` and `clone` so they are never shared; build
// one with `bool3(x, y, z)`, never with a literal (rasc drops every element
// of a bool array literal but the first). Values are classes: `clone()`
// wherever a copy is meant; `equals()` compares field by field.
//
// Enum helpers are free functions (`constraintSpaceParse`,
// `trackAxisName`, ...); the parse functions return -1 for an unknown name.

import { Vec3, Mat4, VEC3_X, VEC3_Y, VEC3_Z, VEC3_NEG_X, VEC3_NEG_Y, VEC3_NEG_Z, MAT4_IDENTITY } from "../../../base/vecmath";
import { toAsciiLowercase } from "../../../base/util";

// An object, optionally a bone of it (when the object is an armature).
export class ConstraintTarget {
    // ObjId (scene).
    object: u32 = 0;
    subtarget: string? = null;

    constructor(object: u32 = 0, subtarget: string? = null) {
        this.object = object;
        this.subtarget = subtarget;
    }

    clone(): ConstraintTarget {
        return new ConstraintTarget(this.object, this.subtarget);
    }

    equals(o: ConstraintTarget): bool {
        if (this.object != o.object) return false;
        const a = this.subtarget;
        const b = o.subtarget;
        if (a == null) return b == null;
        if (b == null) return false;
        return a == b;
    }
}

// The space a constraint reads / writes in. `World` is the armature's
// pose space (Blender's default for copy/track constraints), `Local` the
// bone's own channel (Blender's default for limit constraints).
export enum ConstraintSpace {
    World = 0,
    Local = 1,
}

// Parses a ConstraintSpace name; -1 when unknown.
export function constraintSpaceParse(s: string): i32 {
    const l = toAsciiLowercase(s);
    if (l == "world" || l == "pose" || l == "armature") return ConstraintSpace.World;
    if (l == "local") return ConstraintSpace.Local;
    return -1;
}

export function constraintSpaceName(s: ConstraintSpace): string {
    return s == ConstraintSpace.World ? "world" : "local";
}

export enum RotationMix {
    Replace = 0,
    // Target rotation applied before the owner's (Blender "Before Original").
    Before = 1,
    // After the owner's ("After Original").
    After = 2,
}

// Parses a RotationMix name; -1 when unknown.
export function rotationMixParse(s: string): i32 {
    const l = toAsciiLowercase(s);
    if (l == "replace") return RotationMix.Replace;
    if (l == "before" || l == "before-original") return RotationMix.Before;
    if (l == "after" || l == "after-original" || l == "add") return RotationMix.After;
    return -1;
}

export function rotationMixName(m: RotationMix): string {
    switch (m) {
        case RotationMix.Replace: return "replace";
        case RotationMix.Before: return "before";
        default: return "after";
    }
}

// Default: Y (Blender's default for bones, the bone axis).
export enum TrackAxis {
    X = 0,
    Y = 1,
    Z = 2,
    NegX = 3,
    NegY = 4,
    NegZ = 5,
}

// Parses a TrackAxis name; -1 when unknown.
export function trackAxisParse(s: string): i32 {
    const l = toAsciiLowercase(s);
    if (l == "x" || l == "+x" || l == "track_x") return TrackAxis.X;
    if (l == "y" || l == "+y" || l == "track_y") return TrackAxis.Y;
    if (l == "z" || l == "+z" || l == "track_z") return TrackAxis.Z;
    if (l == "-x" || l == "track_negative_x") return TrackAxis.NegX;
    if (l == "-y" || l == "track_negative_y") return TrackAxis.NegY;
    if (l == "-z" || l == "track_negative_z") return TrackAxis.NegZ;
    return -1;
}

export function trackAxisName(a: TrackAxis): string {
    switch (a) {
        case TrackAxis.X: return "x";
        case TrackAxis.Y: return "y";
        case TrackAxis.Z: return "z";
        case TrackAxis.NegX: return "-x";
        case TrackAxis.NegY: return "-y";
        default: return "-z";
    }
}

export function trackAxisVector(a: TrackAxis): Vec3 {
    switch (a) {
        case TrackAxis.X: return VEC3_X;
        case TrackAxis.Y: return VEC3_Y;
        case TrackAxis.Z: return VEC3_Z;
        case TrackAxis.NegX: return VEC3_NEG_X;
        case TrackAxis.NegY: return VEC3_NEG_Y;
        default: return VEC3_NEG_Z;
    }
}

// Variant index of ConstraintKind (postcard order).
export enum ConstraintKindTag {
    Ik = 0,
    CopyLocation = 1,
    CopyRotation = 2,
    CopyScale = 3,
    CopyTransforms = 4,
    LimitRotation = 5,
    LimitLocation = 6,
    TrackTo = 7,
    DampedTrack = 8,
    StretchTo = 9,
    ChildOf = 10,
}

function boolsEq(a: Array<bool>, b: Array<bool>): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
    return true;
}

// `[x, y, z]` for a `[bool; 3]` field. Never write an Array<bool> /
// StaticArray<bool> literal: rasc 1.1.0 stores only element 0 of it
// (`[true, true, true]` reads back as [true, false, false]), so build the
// array with push.
export function bool3(x: bool, y: bool, z: bool): Array<bool> {
    const out: Array<bool> = [];
    out.push(x);
    out.push(y);
    out.push(z);
    return out;
}

// A copy of a per-axis flag array (`create` and `clone` never share the
// caller's array).
function bools3(a: Array<bool>): Array<bool> {
    const out: Array<bool> = [];
    for (let i = 0; i < a.length; i++) out.push(a[i]);
    return out;
}

export abstract class ConstraintKind {
    abstract get tag(): ConstraintKindTag;
    abstract clone(): ConstraintKind;
    abstract equals(o: ConstraintKind): bool;

    typeName(): string {
        switch (this.tag) {
            case ConstraintKindTag.Ik: return "ik";
            case ConstraintKindTag.CopyLocation: return "copy-location";
            case ConstraintKindTag.CopyRotation: return "copy-rotation";
            case ConstraintKindTag.CopyScale: return "copy-scale";
            case ConstraintKindTag.CopyTransforms: return "copy-transforms";
            case ConstraintKindTag.LimitRotation: return "limit-rotation";
            case ConstraintKindTag.LimitLocation: return "limit-location";
            case ConstraintKindTag.TrackTo: return "track-to";
            case ConstraintKindTag.DampedTrack: return "damped-track";
            case ConstraintKindTag.StretchTo: return "stretch-to";
            default: return "child-of";
        }
    }

    // Blender's default constraint name for the type.
    defaultName(): string {
        switch (this.tag) {
            case ConstraintKindTag.Ik: return "IK";
            case ConstraintKindTag.CopyLocation: return "Copy Location";
            case ConstraintKindTag.CopyRotation: return "Copy Rotation";
            case ConstraintKindTag.CopyScale: return "Copy Scale";
            case ConstraintKindTag.CopyTransforms: return "Copy Transforms";
            case ConstraintKindTag.LimitRotation: return "Limit Rotation";
            case ConstraintKindTag.LimitLocation: return "Limit Location";
            case ConstraintKindTag.TrackTo: return "Track To";
            case ConstraintKindTag.DampedTrack: return "Damped Track";
            case ConstraintKindTag.StretchTo: return "Stretch To";
            default: return "Child Of";
        }
    }

    // The target, or null for the Limit* kinds. The returned object is the
    // constraint's own (named getTarget because the variants have a
    // `target` field): mutate it in place.
    getTarget(): ConstraintTarget? {
        return null;
    }

    // Every object this constraint reads (target and pole).
    referencedObjects(): Array<u32> {
        const out: Array<u32> = [];
        const t = this.getTarget();
        if (t != null) out.push(t.object);
        if (this.tag == ConstraintKindTag.Ik) {
            const p = (this as ConstraintKindIk).pole;
            if (p != null) out.push(p.object);
        }
        return out;
    }
}

export class ConstraintKindIk extends ConstraintKind {
    target: ConstraintTarget = new ConstraintTarget();
    pole: ConstraintTarget? = null;
    // Radians.
    poleAngle: f32 = 0;
    // 0 = the whole chain to the root.
    chainLength: u32 = 0;
    iterations: u32 = 0;
    // Reach the target with the tail (Blender's default) or the head.
    useTail: bool = false;

    get tag(): ConstraintKindTag { return ConstraintKindTag.Ik; }
    override getTarget(): ConstraintTarget? { return this.target; }

    static create(target: ConstraintTarget, pole: ConstraintTarget?, poleAngle: f32, chainLength: u32, iterations: u32, useTail: bool): ConstraintKindIk {
        const k = new ConstraintKindIk();
        k.target = target;
        k.pole = pole;
        k.poleAngle = poleAngle;
        k.chainLength = chainLength;
        k.iterations = iterations;
        k.useTail = useTail;
        return k;
    }

    clone(): ConstraintKind {
        const p = this.pole;
        return ConstraintKindIk.create(this.target.clone(), p != null ? p.clone() : null, this.poleAngle, this.chainLength, this.iterations, this.useTail);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.Ik) return false;
        const k = o as ConstraintKindIk;
        const a = this.pole;
        const b = k.pole;
        let poleEq = false;
        if (a == null) poleEq = b == null;
        else if (b != null) poleEq = a.equals(b);
        return this.target.equals(k.target) && poleEq && this.poleAngle == k.poleAngle
            && this.chainLength == k.chainLength && this.iterations == k.iterations && this.useTail == k.useTail;
    }
}

export class ConstraintKindCopyLocation extends ConstraintKind {
    target: ConstraintTarget = new ConstraintTarget();
    axes: Array<bool> = bool3(true, true, true);
    invert: Array<bool> = bool3(false, false, false);
    offset: bool = false;

    get tag(): ConstraintKindTag { return ConstraintKindTag.CopyLocation; }
    override getTarget(): ConstraintTarget? { return this.target; }

    static create(target: ConstraintTarget, axes: Array<bool>, invert: Array<bool>, offset: bool): ConstraintKindCopyLocation {
        const k = new ConstraintKindCopyLocation();
        k.target = target;
        k.axes = bools3(axes);
        k.invert = bools3(invert);
        k.offset = offset;
        return k;
    }

    clone(): ConstraintKind {
        return ConstraintKindCopyLocation.create(this.target.clone(), this.axes, this.invert, this.offset);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.CopyLocation) return false;
        const k = o as ConstraintKindCopyLocation;
        return this.target.equals(k.target) && boolsEq(this.axes, k.axes) && boolsEq(this.invert, k.invert) && this.offset == k.offset;
    }
}

export class ConstraintKindCopyRotation extends ConstraintKind {
    target: ConstraintTarget = new ConstraintTarget();
    axes: Array<bool> = bool3(true, true, true);
    mix: RotationMix = RotationMix.Replace;

    get tag(): ConstraintKindTag { return ConstraintKindTag.CopyRotation; }
    override getTarget(): ConstraintTarget? { return this.target; }

    static create(target: ConstraintTarget, axes: Array<bool>, mix: RotationMix): ConstraintKindCopyRotation {
        const k = new ConstraintKindCopyRotation();
        k.target = target;
        k.axes = bools3(axes);
        k.mix = mix;
        return k;
    }

    clone(): ConstraintKind {
        return ConstraintKindCopyRotation.create(this.target.clone(), this.axes, this.mix);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.CopyRotation) return false;
        const k = o as ConstraintKindCopyRotation;
        return this.target.equals(k.target) && boolsEq(this.axes, k.axes) && this.mix == k.mix;
    }
}

export class ConstraintKindCopyScale extends ConstraintKind {
    target: ConstraintTarget = new ConstraintTarget();
    axes: Array<bool> = bool3(true, true, true);

    get tag(): ConstraintKindTag { return ConstraintKindTag.CopyScale; }
    override getTarget(): ConstraintTarget? { return this.target; }

    static create(target: ConstraintTarget, axes: Array<bool>): ConstraintKindCopyScale {
        const k = new ConstraintKindCopyScale();
        k.target = target;
        k.axes = bools3(axes);
        return k;
    }

    clone(): ConstraintKind {
        return ConstraintKindCopyScale.create(this.target.clone(), this.axes);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.CopyScale) return false;
        const k = o as ConstraintKindCopyScale;
        return this.target.equals(k.target) && boolsEq(this.axes, k.axes);
    }
}

export class ConstraintKindCopyTransforms extends ConstraintKind {
    target: ConstraintTarget = new ConstraintTarget();
    mix: RotationMix = RotationMix.Replace;

    get tag(): ConstraintKindTag { return ConstraintKindTag.CopyTransforms; }
    override getTarget(): ConstraintTarget? { return this.target; }

    static create(target: ConstraintTarget, mix: RotationMix): ConstraintKindCopyTransforms {
        const k = new ConstraintKindCopyTransforms();
        k.target = target;
        k.mix = mix;
        return k;
    }

    clone(): ConstraintKind {
        return ConstraintKindCopyTransforms.create(this.target.clone(), this.mix);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.CopyTransforms) return false;
        const k = o as ConstraintKindCopyTransforms;
        return this.target.equals(k.target) && this.mix == k.mix;
    }
}

export class ConstraintKindLimitRotation extends ConstraintKind {
    // Radians, per axis.
    min: Vec3 = Vec3(0, 0, 0);
    max: Vec3 = Vec3(0, 0, 0);
    axes: Array<bool> = bool3(true, true, true);

    get tag(): ConstraintKindTag { return ConstraintKindTag.LimitRotation; }

    static create(min: Vec3, max: Vec3, axes: Array<bool>): ConstraintKindLimitRotation {
        const k = new ConstraintKindLimitRotation();
        k.min = min;
        k.max = max;
        k.axes = bools3(axes);
        return k;
    }

    clone(): ConstraintKind {
        return ConstraintKindLimitRotation.create(this.min, this.max, this.axes);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.LimitRotation) return false;
        const k = o as ConstraintKindLimitRotation;
        return this.min == k.min && this.max == k.max && boolsEq(this.axes, k.axes);
    }
}

export class ConstraintKindLimitLocation extends ConstraintKind {
    min: Vec3 = Vec3(0, 0, 0);
    max: Vec3 = Vec3(0, 0, 0);
    useMin: Array<bool> = bool3(false, false, false);
    useMax: Array<bool> = bool3(false, false, false);

    get tag(): ConstraintKindTag { return ConstraintKindTag.LimitLocation; }

    static create(min: Vec3, max: Vec3, useMin: Array<bool>, useMax: Array<bool>): ConstraintKindLimitLocation {
        const k = new ConstraintKindLimitLocation();
        k.min = min;
        k.max = max;
        k.useMin = bools3(useMin);
        k.useMax = bools3(useMax);
        return k;
    }

    clone(): ConstraintKind {
        return ConstraintKindLimitLocation.create(this.min, this.max, this.useMin, this.useMax);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.LimitLocation) return false;
        const k = o as ConstraintKindLimitLocation;
        return this.min == k.min && this.max == k.max && boolsEq(this.useMin, k.useMin) && boolsEq(this.useMax, k.useMax);
    }
}

export class ConstraintKindTrackTo extends ConstraintKind {
    target: ConstraintTarget = new ConstraintTarget();
    track: TrackAxis = TrackAxis.Y;
    up: TrackAxis = TrackAxis.Y;

    get tag(): ConstraintKindTag { return ConstraintKindTag.TrackTo; }
    override getTarget(): ConstraintTarget? { return this.target; }

    static create(target: ConstraintTarget, track: TrackAxis, up: TrackAxis): ConstraintKindTrackTo {
        const k = new ConstraintKindTrackTo();
        k.target = target;
        k.track = track;
        k.up = up;
        return k;
    }

    clone(): ConstraintKind {
        return ConstraintKindTrackTo.create(this.target.clone(), this.track, this.up);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.TrackTo) return false;
        const k = o as ConstraintKindTrackTo;
        return this.target.equals(k.target) && this.track == k.track && this.up == k.up;
    }
}

export class ConstraintKindDampedTrack extends ConstraintKind {
    target: ConstraintTarget = new ConstraintTarget();
    track: TrackAxis = TrackAxis.Y;

    get tag(): ConstraintKindTag { return ConstraintKindTag.DampedTrack; }
    override getTarget(): ConstraintTarget? { return this.target; }

    static create(target: ConstraintTarget, track: TrackAxis): ConstraintKindDampedTrack {
        const k = new ConstraintKindDampedTrack();
        k.target = target;
        k.track = track;
        return k;
    }

    clone(): ConstraintKind {
        return ConstraintKindDampedTrack.create(this.target.clone(), this.track);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.DampedTrack) return false;
        const k = o as ConstraintKindDampedTrack;
        return this.target.equals(k.target) && this.track == k.track;
    }
}

export class ConstraintKindStretchTo extends ConstraintKind {
    target: ConstraintTarget = new ConstraintTarget();
    // 0 = measured when first evaluated (Blender's "reset").
    restLength: f32 = 0;
    volume: bool = false;

    get tag(): ConstraintKindTag { return ConstraintKindTag.StretchTo; }
    override getTarget(): ConstraintTarget? { return this.target; }

    static create(target: ConstraintTarget, restLength: f32, volume: bool): ConstraintKindStretchTo {
        const k = new ConstraintKindStretchTo();
        k.target = target;
        k.restLength = restLength;
        k.volume = volume;
        return k;
    }

    clone(): ConstraintKind {
        return ConstraintKindStretchTo.create(this.target.clone(), this.restLength, this.volume);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.StretchTo) return false;
        const k = o as ConstraintKindStretchTo;
        return this.target.equals(k.target) && this.restLength == k.restLength && this.volume == k.volume;
    }
}

export class ConstraintKindChildOf extends ConstraintKind {
    target: ConstraintTarget = new ConstraintTarget();
    inverse: Mat4 = MAT4_IDENTITY;

    get tag(): ConstraintKindTag { return ConstraintKindTag.ChildOf; }
    override getTarget(): ConstraintTarget? { return this.target; }

    static create(target: ConstraintTarget, inverse: Mat4): ConstraintKindChildOf {
        const k = new ConstraintKindChildOf();
        k.target = target;
        k.inverse = inverse;
        return k;
    }

    clone(): ConstraintKind {
        return ConstraintKindChildOf.create(this.target.clone(), this.inverse);
    }

    equals(o: ConstraintKind): bool {
        if (o.tag != ConstraintKindTag.ChildOf) return false;
        const k = o as ConstraintKindChildOf;
        return this.target.equals(k.target) && this.inverse == k.inverse;
    }
}

export class Constraint {
    name: string;
    kind: ConstraintKind;
    // 0..1, blends the constrained result with the unconstrained pose.
    influence: f32 = 1.0;
    enabled: bool = true;
    space: ConstraintSpace = ConstraintSpace.World;

    // The default name, full influence,

    // enabled, Local space for the Limit* kinds and World otherwise.
    constructor(kind: ConstraintKind) {
        const t = kind.tag;
        this.space = t == ConstraintKindTag.LimitRotation || t == ConstraintKindTag.LimitLocation
            ? ConstraintSpace.Local
            : ConstraintSpace.World;
        this.name = kind.defaultName();
        this.kind = kind;
        this.influence = 1.0;
        this.enabled = true;
    }

    clone(): Constraint {
        const c = new Constraint(this.kind.clone());
        c.name = this.name;
        c.influence = this.influence;
        c.enabled = this.enabled;
        c.space = this.space;
        return c;
    }

    equals(o: Constraint): bool {
        return this.name == o.name && this.kind.equals(o.kind) && this.influence == o.influence
            && this.enabled == o.enabled && this.space == o.space;
    }
}

// Constraint type names accepted by `constraint add`.
export const TYPES: Array<string> = [
    "ik",
    "copy-location",
    "copy-rotation",
    "copy-scale",
    "copy-transforms",
    "limit-rotation",
    "limit-location",
    "track-to",
    "damped-track",
    "stretch-to",
    "child-of",
];
