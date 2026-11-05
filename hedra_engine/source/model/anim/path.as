// Blender data paths as F-curves address them: `location`,
// `rotation_euler`, `scale` on objects, `pose.bones["Spine"].<channel>`
// on pose bones, `pose.bones["X"].constraints["IK"].influence`,
// `key_blocks["Smile"].value` on shape keys.

// What a data path animates once the target is resolved.
export enum Channel {
    Location = 0,
    RotationEuler = 1,
    RotationQuaternion = 2,
    Scale = 3,
}

// "No channel" for channelParse / DataPath.channel().
export const CHANNEL_NONE: i32 = -1;

// The channel's data-path name.
export function channelName(c: Channel): string {
    switch (c) {
        case Channel.Location: return "location";
        case Channel.RotationEuler: return "rotation_euler";
        case Channel.RotationQuaternion: return "rotation_quaternion";
        default: return "scale";
    }
}

// The Channel named by `s`, or CHANNEL_NONE (-1).
export function channelParse(s: string): i32 {
    if (s == "location") return Channel.Location;
    if (s == "rotation_euler") return Channel.RotationEuler;
    if (s == "rotation_quaternion") return Channel.RotationQuaternion;
    if (s == "scale") return Channel.Scale;
    return CHANNEL_NONE;
}

// Number of array indices (W X Y Z for quaternions).
export function channelComponents(c: Channel): u32 {
    return c == Channel.RotationQuaternion ? 4 : 3;
}

export function channelIsRotation(c: Channel): bool {
    return c == Channel.RotationEuler || c == Channel.RotationQuaternion;
}

// Blender's component labels (`X Y Z`, quaternions `W X Y Z`).
export function channelComponentName(c: Channel, index: u32): string {
    if (c == Channel.RotationQuaternion) {
        if (index == 0) return "W";
        if (index == 1) return "X";
        if (index == 2) return "Y";
        if (index == 3) return "Z";
        return "?";
    }
    if (index == 0) return "X";
    if (index == 1) return "Y";
    if (index == 2) return "Z";
    return "?";
}

export enum DataPathKind {
    Object = 0,
    Bone = 1,
    ConstraintInfluence = 2,
    ShapeKeyValue = 3,
    Unknown = 4,
}

// `[<q>name<q>]tail` with q = `"` or `'` -> [name, tail].
function quoted(s: string): Array<string>? {
    if (!s.startsWith("[")) return null;
    const rest0 = s.substring(1);
    if (rest0.length == 0) return null;
    const q = rest0.charCodeAt(0);
    if (q != 0x22 && q != 0x27) return null;
    const rest = rest0.substring(1);
    const end = rest.indexOf(String.fromCharCode(q));
    if (end < 0) return null;
    const name = rest.substring(0, end);
    const after = rest.substring(end + 1);
    if (!after.startsWith("]")) return null;
    return [name, after.substring(1)];
}

// A parsed data path, as one tagged class. Fields used per kind:

// Object: chan; Bone: bone, chan; ConstraintInfluence: bone, constraint;
// ShapeKeyValue: key; Unknown: raw.
export class DataPath {
    kind: DataPathKind = DataPathKind.Unknown;
    chan: Channel = Channel.Location;
    bone: string = "";
    constraint: string = "";
    key: string = "";
    raw: string = "";

    // An object channel.
    static object(c: Channel): DataPath {
        const d = new DataPath();
        d.kind = DataPathKind.Object;
        d.chan = c;
        return d;
    }

    // A channel of the named pose bone.
    static boneOf(name: string, channel: Channel): DataPath {
        const d = new DataPath();
        d.kind = DataPathKind.Bone;
        d.bone = name;
        d.chan = channel;
        return d;
    }

    // The influence of a bone constraint.
    static constraintInfluence(bone: string, constraint: string): DataPath {
        const d = new DataPath();
        d.kind = DataPathKind.ConstraintInfluence;
        d.bone = bone;
        d.constraint = constraint;
        return d;
    }

    // The value of a shape key.
    static shapeKeyValue(key: string): DataPath {
        const d = new DataPath();
        d.kind = DataPathKind.ShapeKeyValue;
        d.key = key;
        return d;
    }

    // A path that is not understood, kept as its raw text.
    static unknown(raw: string): DataPath {
        const d = new DataPath();
        d.kind = DataPathKind.Unknown;
        d.raw = raw;
        return d;
    }

    static parse(path: string): DataPath {
        const ch = channelParse(path);
        if (ch != CHANNEL_NONE) {
            return DataPath.object(<Channel>ch);
        }
        if (path.startsWith("pose.bones")) {
            const q = quoted(path.substring(10));
            if (q != null && q[1].startsWith(".")) {
                const bone = q[0];
                const tail = q[1].substring(1);
                const c = channelParse(tail);
                if (c != CHANNEL_NONE) {
                    return DataPath.boneOf(bone, <Channel>c);
                }
                if (tail.startsWith("constraints")) {
                    const q2 = quoted(tail.substring(11));
                    if (q2 != null && q2[1] == ".influence") {
                        return DataPath.constraintInfluence(bone, q2[0]);
                    }
                }
            }
        }
        if (path.startsWith("key_blocks")) {
            const q = quoted(path.substring(10));
            if (q != null && q[1] == ".value") {
                return DataPath.shapeKeyValue(q[0]);
            }
        }
        return DataPath.unknown(path);
    }

    // The channel, or CHANNEL_NONE (-1).
    channel(): i32 {
        if (this.kind == DataPathKind.Object || this.kind == DataPathKind.Bone) return this.chan;
        return CHANNEL_NONE;
    }

    // Number of array indices the path has.
    components(): u32 {
        const c = this.channel();
        return c == CHANNEL_NONE ? 1 : channelComponents(<Channel>c);
    }

    // Values stored in radians that commands and dumps show in degrees.
    isAngle(): bool {
        return this.channel() == Channel.RotationEuler;
    }

    boneName(): string? {
        if (this.kind == DataPathKind.Bone || this.kind == DataPathKind.ConstraintInfluence) return this.bone;
        return null;
    }

    // Short Blender-like label: `X Location`, `Spine: W Quaternion Rotation`.
    label(index: u32): string {
        switch (this.kind) {
            case DataPathKind.Object: return chanLabel(this.chan, index);
            case DataPathKind.Bone: return this.bone + ": " + chanLabel(this.chan, index);
            case DataPathKind.ConstraintInfluence: return this.bone + ": " + this.constraint + " Influence";
            case DataPathKind.ShapeKeyValue: return this.key + " Value";
            default: return this.raw + "[" + index.toString() + "]";
        }
    }

    // The data path text.
    toString(): string {
        switch (this.kind) {
            case DataPathKind.Object: return channelName(this.chan);
            case DataPathKind.Bone: return "pose.bones[\"" + this.bone + "\"]." + channelName(this.chan);
            case DataPathKind.ConstraintInfluence:
                return "pose.bones[\"" + this.bone + "\"].constraints[\"" + this.constraint + "\"].influence";
            case DataPathKind.ShapeKeyValue: return "key_blocks[\"" + this.key + "\"].value";
            default: return this.raw;
        }
    }

    // PartialEq.
    equals(o: DataPath): bool {
        if (this.kind != o.kind) return false;
        switch (this.kind) {
            case DataPathKind.Object: return this.chan == o.chan;
            case DataPathKind.Bone: return this.bone == o.bone && this.chan == o.chan;
            case DataPathKind.ConstraintInfluence: return this.bone == o.bone && this.constraint == o.constraint;
            case DataPathKind.ShapeKeyValue: return this.key == o.key;
            default: return this.raw == o.raw;
        }
    }

    clone(): DataPath {
        const d = new DataPath();
        d.kind = this.kind;
        d.chan = this.chan;
        d.bone = this.bone;
        d.constraint = this.constraint;
        d.key = this.key;
        d.raw = this.raw;
        return d;
    }
}

function chanLabel(c: Channel, index: u32): string {
    let what: string;
    switch (c) {
        case Channel.Location: what = "Location"; break;
        case Channel.RotationEuler: what = "Euler Rotation"; break;
        case Channel.RotationQuaternion: what = "Quaternion Rotation"; break;
        default: what = "Scale"; break;
    }
    return channelComponentName(c, index) + " " + what;
}
