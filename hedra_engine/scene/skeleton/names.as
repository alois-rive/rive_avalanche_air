// The names that reach a skeleton's bones, a mesh's blend shapes and a
// model's clips from a scene (docs/plans/RIVE_MODEL.md sections 3.1 and
// 3.7; docs/formats/RSCN.md, "Skeletons"), shared by the reader, the
// validator, the timelines, the bindings, the tools and the editor so that
// all of them split a name the same way:
//
//   bones/<bone>:position         a bone's pose (Vector3, on a Skeleton3D)
//   bones/<bone>:position:x       one component of it (keyed as a number)
//   bones/<bone>:quaternion       its rotation (Quaternion; keyed whole, as
//                                 KeyFrameQuaternion)
//   bones/<bone>:scale[:x|:y|:z]  its scale
//   blend_shapes/<name>           a blend shape's weight (float, on a
//                                 MeshInstance3D: Godot's name)
//   <clip> (<source>)             an imported clip in a scene's list of
//                                 animations: "Walk (hero.glb)"
//
// A bone's name may hold ':' and '/' (glTF's "mixamorig:Hips"), so a bone
// property is read from its right: an optional axis, then the field, and
// the rest is the bone.

export const BONES_PREFIX = "bones/";

// The load warnings about them (docs/formats/RSCN.md, "Errors and
// warnings"; the value or key is kept and written back): a bone property,
// key or bone_name naming no bone of the skeleton; a blend shape property
// or key naming no blend shape of the mesh; a BoneAttachment3D whose parent
// is no Skeleton3D; a skinned MeshInstance3D whose `skeleton` finds none.
export const BONE_UNKNOWN_CODE = "bone-unknown";
export const BLEND_SHAPE_UNKNOWN_CODE = "blend-shape-unknown";
export const BONE_ATTACHMENT_PARENT_CODE = "bone-attachment-parent";
export const SKELETON_MISSING_CODE = "skeleton-missing";
export const BLEND_SHAPES_PREFIX = "blend_shapes/";

export const BONE_FIELD_POSITION = "position";
export const BONE_FIELD_QUATERNION = "quaternion";
export const BONE_FIELD_SCALE = "scale";

// A bone property split (parseBoneProperty).
export class BoneProperty {
    bone: string;
    // BONE_FIELD_*.
    field: string;
    // -1 the whole value, 0 x, 1 y, 2 z (never set for the quaternion).
    axis: i32;

    constructor(bone: string, field: string, axis: i32) {
        this.bone = bone;
        this.field = field;
        this.axis = axis;
    }
}

const AXES: StaticArray<string> = ["x", "y", "z"];

// "bones/<bone>:<field>" and, with an axis 0 to 2, ":x", ":y" or ":z" after.
export function boneProperty(bone: string, field: string, axis: i32 = -1): string {
    const base = BONES_PREFIX + bone + ":" + field;
    return axis >= 0 && axis < 3 ? base + ":" + AXES[axis] : base;
}

// `p` split, or null when it is no bone property: no "bones/" prefix, an
// empty bone, a field other than the three, an axis on the quaternion.
export function parseBoneProperty(p: string): BoneProperty? {
    if (!p.startsWith(BONES_PREFIX)) return null;
    let rest = p.substring(BONES_PREFIX.length);
    let axis = -1;
    for (let a = 0; a < 3; a++) {
        const suffix = ":" + AXES[a];
        if (rest.endsWith(suffix)) {
            axis = a;
            rest = rest.substring(0, rest.length - suffix.length);
            break;
        }
    }
    const colon = rest.lastIndexOf(":");
    if (colon <= 0) return null;
    const field = rest.substring(colon + 1);
    if (field != BONE_FIELD_POSITION && field != BONE_FIELD_QUATERNION && field != BONE_FIELD_SCALE) return null;
    if (field == BONE_FIELD_QUATERNION && axis >= 0) return null;
    return new BoneProperty(rest.substring(0, colon), field, axis);
}

export function isBoneProperty(p: string): bool {
    return parseBoneProperty(p) != null;
}

// "blend_shapes/<name>".
export function blendShapeProperty(name: string): string {
    return BLEND_SHAPES_PREFIX + name;
}

// The blend shape `p` names, or null when it names none.
export function blendShapeOf(p: string): string? {
    if (!p.startsWith(BLEND_SHAPES_PREFIX) || p.length == BLEND_SHAPES_PREFIX.length) return null;
    return p.substring(BLEND_SHAPES_PREFIX.length);
}

// An imported clip's name in a scene: "<clip> (<source>)", the source
// being the model file's name ("hero.glb"), or the instancing node's path
// when two nodes of the scene instance the same file.
export function importedClipLabel(clip: string, source: string): string {
    return clip + " (" + source + ")";
}

// The clip and the source of a label importedClipLabel made (the last
// " (" splits them), or null for a name that is not one.
export function splitImportedClipLabel(label: string): Array<string>? {
    if (!label.endsWith(")")) return null;
    const open = label.lastIndexOf(" (");
    if (open <= 0) return null;
    const source = label.substring(open + 2, label.length - 1);
    if (source.length == 0) return null;
    return [label.substring(0, open), source];
}
