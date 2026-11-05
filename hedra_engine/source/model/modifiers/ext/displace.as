// Displace (Blender: Properties > Modifiers > Deform > Displace).
//
// Blender drives this from a texture. There are no textures here, but
// there are named float attributes computed from an expression, which
// occupy the same slot: `attribute add height point float --value "..."`
// then `modifier add displace --attribute height`. With no attribute the
// value is 1 everywhere, so a bare Displace moves every vertex by
// `(1 - midlevel) * strength`, exactly as Blender's does with no texture.

import { Vec3, VEC3_ZERO, VEC3_X, VEC3_Y, VEC3_Z } from "../../../../base/vecmath";
import { Result } from "../../../../base/util";
import { Mesh, ElemKind } from "../../mesh/mod";
import { AttrValueKind } from "../../mesh/attr";
import { ModifierEnv } from "../mod";
import { PropDef, PropKind, Props, prop } from "./props";
import { VERTEX_GROUP, INVERT_GROUP, weightField, weightAt } from "./common";

export const PROPS: Array<PropDef> = [
    prop(
        "direction",
        PropKind.Choice(["x", "y", "z", "normal", "custom"]),
        "normal",
        "displace along this axis, the vertex normal, or `custom` for --custom-direction",
    ),
    prop(
        "strength",
        PropKind.Float(),
        "1",
        "how far a value of 1 moves a vertex",
    ),
    prop(
        "midlevel",
        PropKind.Float(),
        "0.5",
        "the value that does not move; below it vertices move inward",
    ),
    prop(
        "attribute",
        PropKind.Name(),
        "none",
        "a point attribute read as the displacement value (Blender's texture slot)",
    ),
    prop(
        "custom-direction",
        PropKind.Vec3(),
        "0 0 1",
        "the direction used when --direction is custom",
    ),
    VERTEX_GROUP,
    INVERT_GROUP,
];

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const wf = weightField(mesh, p, env);
    const weights = wf.field;
    const invert = wf.invert;
    const warnings = weights.warnings.slice(0);

    // The value field: an attribute if one is named, 1 everywhere if not.
    const attr = p.optStr("attribute");
    if (attr != null && mesh.attr(attr) == null) {
        warnings.push(
            "no attribute '" + attr + "'; displacing by a constant 1 instead " +
                "(`attribute list` shows this mesh's)",
        );
    }
    const bound = <i32>mesh.verts.idBound();
    const values = new Array<f32>(bound);
    for (let i = 0; i < bound; i++) values[i] = 1.0;
    if (attr != null && mesh.attr(attr) != null) {
        const ids0 = mesh.verts.ids();
        for (let i = 0; i < ids0.length; i++) {
            const id = ids0[i];
            const a = mesh.attrValue(attr, ElemKind.Vert, id);
            let x: f32 = 0.0;
            if (a != null) {
                if (a.kind == AttrValueKind.Vec3) x = a.v.length();
                else x = <f32>a.asF64();
            }
            values[<i32>id] = x;
        }
    }

    const strength = p.f32("strength");
    const midlevel = p.f32("midlevel");
    const direction = p.str("direction");
    // Normals are read before anything moves, so every vertex is displaced
    // along the surface as it was — the same order Blender evaluates in.
    const dirIds = mesh.verts.ids();
    const dirs: Array<Vec3> = [];
    for (let i = 0; i < dirIds.length; i++) {
        const v = dirIds[i];
        let d = VEC3_ZERO;
        if (direction == "x") d = VEC3_X;
        else if (direction == "y") d = VEC3_Y;
        else if (direction == "z") d = VEC3_Z;
        else if (direction == "custom") d = p.vec3("custom-direction").normalizeOrZero();
        else d = mesh.vertNormal(v);
        dirs.push(d);
    }

    let moved = 0;
    for (let i = 0; i < dirIds.length; i++) {
        const v = dirIds[i];
        const dir = dirs[i];
        const w = weightAt(weights, invert, v);
        if (w == <f32>0.0 || dir == VEC3_ZERO) continue;
        const amount = (values[<i32>v] - midlevel) * strength * w;
        if (amount == <f32>0.0) continue;
        const vert = mesh.verts.at(v);
        vert.co = vert.co + dir * amount;
        moved += 1;
    }
    if (moved > 0) {
        mesh.recalcNormals();
        mesh.touch();
    }
    return Result.okv<Array<string>>(warnings);
}
