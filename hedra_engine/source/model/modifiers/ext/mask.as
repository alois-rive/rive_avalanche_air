// Mask (Blender: Generate > Mask): keep only the faces whose vertices are
// in a vertex group, and throw the rest away.
//
// Blender's second mode masks by an armature's bones. That needs a pose to
// read, which a stack has only when it is evaluated with scene context, so
// `armature` mode resolves each bone to the vertex group of the same name
// — which is how the weights got there in the first place.

import { Result, maxF32 } from "../../../../base/util";
import { Mesh, FaceId, VertId } from "../../mesh/mod";
import { ModifierEnv } from "../mod";
import { NO_VGROUP } from "../../scene";
import { Armature } from "../../armature/mod";
import { PropDef, PropKind, Props, prop } from "./props";
import { owner } from "./common";

export const PROPS: Array<PropDef> = [
    prop(
        "mode",
        PropKind.Choice(["vertex-group", "armature"]),
        "vertex-group",
        "mask by one vertex group, or by every group named after a bone of an armature",
    ),
    prop(
        "vertex-group",
        PropKind.Name(),
        "none",
        "in vertex-group mode, the group to keep",
    ),
    prop(
        "armature",
        PropKind.Name(),
        "none",
        "in armature mode, the armature whose bones name the groups to keep",
    ),
    prop(
        "threshold",
        PropKind.Range(0.0, 1.0),
        "0.5",
        "a vertex counts as masked when its weight reaches this",
    ),
    prop(
        "invert",
        PropKind.Bool(),
        "false",
        "keep what would otherwise be removed",
    ),
    prop(
        "smooth",
        PropKind.Bool(),
        "false",
        "ignored, because a smooth transition needs interpolated geometry",
    ),
];

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const warnings: Array<string> = [];
    if (p.bool("smooth")) {
        warnings.push(
            "--smooth is not implemented: faces are kept or dropped whole, never interpolated",
        );
    }
    const object = owner(env);
    const armatureMode = p.str("mode") == "armature";

    // The group indices whose weight keeps a vertex.
    const groups: Array<u32> = [];
    if (armatureMode) {
        const name = p.optStr("armature");
        if (name == null) {
            return Result.fail<Array<string>>("armature mode needs `modifier set <name> armature <object>`");
        }
        const scene = env.scene;
        if (scene == null || object == null) {
            return Result.fail<Array<string>>("armature mode needs the scene (evaluated without context)");
        }
        // The first object with the
        // name decides, even when it is not an armature.
        let arm: Armature? = null;
        const oids = scene.objects.ids();
        for (let i = 0; i < oids.length; i++) {
            const o = scene.objects.at(oids[i]);
            if (o.name == name) {
                arm = o.armature();
                break;
            }
        }
        if (arm == null) {
            return Result.fail<Array<string>>("'" + name + "' is not an armature object");
        }
        const bones = arm.bones.values();
        for (let i = 0; i < bones.length; i++) {
            const gi = object.vgroupIndex(bones[i].name);
            if (gi != NO_VGROUP) groups.push(gi);
        }
        if (groups.length == 0) {
            warnings.push("no vertex group is named after a bone of '" + name + "'; nothing is masked");
        }
    } else {
        const name = p.optStr("vertex-group");
        if (name == null) {
            return Result.fail<Array<string>>(
                "mask needs a vertex group (`modifier set <name> vertex-group <group>`)",
            );
        }
        const gi = object != null ? object.vgroupIndex(name) : NO_VGROUP;
        if (gi != NO_VGROUP) {
            groups.push(gi);
        } else if (object != null) {
            return Result.fail<Array<string>>("no vertex group '" + name + "'");
        } else {
            return Result.fail<Array<string>>(
                "a mask modifier needs the object's vertex groups (evaluated without context)",
            );
        }
    }

    const threshold = p.f32("threshold");
    const invert = p.bool("invert");

    // A face survives when every one of its corners does, which is what
    // Blender's Mask does with a hard (unsmoothed) transition.
    const drop: Array<FaceId> = [];
    const fids = mesh.faces.ids();
    for (let i = 0; i < fids.length; i++) {
        const f = fids[i];
        const fv = mesh.faceVerts(f);
        let all = true;
        for (let j = 0; j < fv.length; j++) {
            if (!masked(mesh, fv[j], groups, threshold, invert)) {
                all = false;
                break;
            }
        }
        if (!all) drop.push(f);
    }
    if (drop.length == 0) {
        return Result.okv<Array<string>>(warnings);
    }
    mesh.deleteFacesCleanup(drop);
    // Vertices that were only held by removed faces go with them, as
    // Blender's Mask leaves no loose points behind.
    mesh.deleteLooseVerts();
    mesh.touch();
    return Result.okv<Array<string>>(warnings);
}

function masked(mesh: Mesh, v: VertId, groups: Array<u32>, threshold: f32, invert: bool): bool {
    const gs = mesh.verts.at(v).groups;
    let w: f32 = 0.0;
    for (let i = 0; i < gs.length; i++) {
        if (groups.includes(gs[i].group)) w = maxF32(w, gs[i].weight);
    }
    return (w >= threshold) != invert;
}
