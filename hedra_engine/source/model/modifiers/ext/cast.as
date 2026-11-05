// Cast (Blender: Deform > Cast): blend every vertex towards where it would
// sit on a sphere, a cylinder or a cuboid of the same size.

import { Vec3, VEC3_ZERO } from "../../../../base/vecmath";
import { Result } from "../../../../base/util";
import { Mesh } from "../../mesh/mod";
import { ModifierEnv } from "../mod";
import { PropDef, PropKind, Props, prop } from "./props";
import { VERTEX_GROUP, INVERT_GROUP, weightField, weightAt } from "./common";

export const PROPS: Array<PropDef> = [
    prop(
        "shape",
        PropKind.Choice(["sphere", "cylinder", "cuboid"]),
        "sphere",
        "the shape to cast towards",
    ),
    prop(
        "factor",
        PropKind.Float(),
        "0.5",
        "0 leaves the mesh alone, 1 lands every vertex on the shape",
    ),
    prop(
        "radius",
        PropKind.Float(),
        "0",
        "only vertices within this distance of the centre are cast (0 = all of them)",
    ),
    prop(
        "size",
        PropKind.Float(),
        "0",
        "size of the target shape (0 = the mesh's own average radius)",
    ),
    prop(
        "axis",
        PropKind.Axes(),
        "x,y,z",
        "restrict the movement to these axes",
    ),
    prop(
        "use-transform",
        PropKind.Bool(),
        "false",
        "cast about the object's origin instead of the mesh's own centre",
    ),
    VERTEX_GROUP,
    INVERT_GROUP,
];

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const wf = weightField(mesh, p, env);
    const weights = wf.field;
    const invert = wf.invert;
    const warnings = weights.warnings.slice(0);
    if (mesh.verts.isEmpty()) {
        return Result.okv<Array<string>>(warnings);
    }
    const centre = p.bool("use-transform") ? VEC3_ZERO : mesh.median();
    // Blender's "Size = 0 means use the mesh's own radius": the mean
    // distance from the centre, which keeps a cast at factor 1 the same
    // scale as what went in.
    let size = p.f32("size");
    if (size <= <f32>0.0) {
        // The sum starts from -0.0, so an empty sum is -0.0.
        let sum: f32 = -0.0;
        const ids0 = mesh.verts.ids();
        for (let i = 0; i < ids0.length; i++) sum += (mesh.verts.at(ids0[i]).co - centre).length();
        size = sum / <f32>mesh.verts.len();
    }
    if (size <= <f32>0.0) {
        return Result.okv<Array<string>>(warnings);
    }
    const factor = p.f32("factor");
    const radius = p.f32("radius");
    const axes = p.axes("axis");
    const mask = Vec3(
        axes[0] ? <f32>1.0 : <f32>0.0,
        axes[1] ? <f32>1.0 : <f32>0.0,
        axes[2] ? <f32>1.0 : <f32>0.0,
    );
    const shape = p.str("shape");

    const ids = mesh.verts.ids();
    for (let i = 0; i < ids.length; i++) {
        const v = ids[i];
        const w = weightAt(weights, invert, v);
        if (w == <f32>0.0) continue;
        const local = mesh.verts.at(v).co - centre;
        if (radius > <f32>0.0 && local.length() > radius) continue;
        let target = VEC3_ZERO;
        if (shape == "cylinder") {
            // Round in x and y, left alone along z: Blender's cylinder is
            // the sphere projection with the axis component dropped.
            const flat = Vec3(local.x, local.y, 0.0);
            const len = flat.length();
            if (len < <f32>1e-9) continue;
            target = flat / len * size + Vec3(0.0, 0.0, local.z);
        } else if (shape == "cuboid") {
            const m = local.abs().maxElement();
            if (m < <f32>1e-9) continue;
            target = local / m * size;
        } else {
            const len = local.length();
            if (len < <f32>1e-9) continue;
            target = local / len * size;
        }
        const delta = (target - local) * factor * w;
        const vert = mesh.verts.at(v);
        vert.co = vert.co + delta.mul(mask);
    }
    mesh.recalcNormals();
    mesh.touch();
    return Result.okv<Array<string>>(warnings);
}
