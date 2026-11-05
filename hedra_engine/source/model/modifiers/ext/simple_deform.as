// Simple Deform (Blender: Deform > Simple Deform): twist, bend, taper and
// stretch about an axis.
//
// Every mode maps a vertex's position along one axis to a factor in
// `0..=1` across the mesh's extent on that axis, then applies the mode's
// transform with that factor. Blender's Limits crop that range, so a twist
// can be confined to the middle of a column.
//
// `--axis` names the axis the deformation turns *about*. Twist, taper and
// stretch read the position along it; bend reads the position across it,
// because bending about Z is what wraps the X extent into an arc in the
// X-Y plane — the same arrangement Blender's modifier has.

import { Mat3, Vec3, VEC3_X, VEC3_Y, VEC3_Z } from "../../../../base/vecmath";
import { appleSincosf, appleCosf, appleSinf } from "../../../../base/libm";
import { Result, clampF32, maxF32 } from "../../../../base/util";
import { Mesh } from "../../mesh/mod";
import { ModifierEnv } from "../mod";
import { PropDef, PropKind, Props, prop } from "./props";
import { VERTEX_GROUP, INVERT_GROUP, weightField, weightAt } from "./common";

export const PROPS: Array<PropDef> = [
    prop(
        "mode",
        PropKind.Choice(["twist", "bend", "taper", "stretch"]),
        "twist",
        "which deformation to apply",
    ),
    prop(
        "angle",
        PropKind.Degrees(),
        "45",
        "in twist and bend modes, how far to turn over the deformed range",
    ),
    prop(
        "factor",
        PropKind.Float(),
        "0.5",
        "in taper and stretch modes, how much to narrow or lengthen",
    ),
    prop(
        "axis",
        PropKind.Axis(),
        "z",
        "the axis the deformation turns about; bend wraps the extent across it",
    ),
    prop(
        "limit-lower",
        PropKind.Range(0.0, 1.0),
        "0",
        "start of the deformed range, 0 to 1 of the extent it reads",
    ),
    prop(
        "limit-upper",
        PropKind.Range(0.0, 1.0),
        "1",
        "end of the deformed range, 0 to 1 of the extent it reads",
    ),
    VERTEX_GROUP,
    INVERT_GROUP,
];

const AXIS_NAMES: Array<string> = ["x", "y", "z"];

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const wf = weightField(mesh, p, env);
    const weights = wf.field;
    const invert = wf.invert;
    const warnings = weights.warnings.slice(0);
    const bounds = mesh.bounds();
    if (bounds == null) {
        return Result.okv<Array<string>>(warnings);
    }
    const min = bounds.lo;
    const max = bounds.hi;
    const axis = p.axis("axis");
    const mode = p.str("mode");
    // `axis` is the axis the deformation turns *about*. Twist, taper and
    // stretch read the position along it; bend reads the position across
    // it, because bending about Z is what wraps the X extent into an arc in
    // the X-Y plane. That is Blender's arrangement too — its bend takes the
    // first coordinate of the remapped frame, not the third.
    const bend = mode == "bend";
    const param = bend ? (axis + 1) % 3 : axis;
    const span = max.get(param) - min.get(param);
    if (span < <f32>1e-9) {
        warnings.push(
            "the mesh is flat along " + AXIS_NAMES[param] + ", so there is nothing to deform along it",
        );
        return Result.okv<Array<string>>(warnings);
    }
    const a0 = p.f32("limit-lower");
    const b0 = p.f32("limit-upper");
    const lower = a0 <= b0 ? a0 : b0;
    const upper = a0 <= b0 ? b0 : a0;
    const window = maxF32(upper - lower, <f32>1e-6);
    const angle = p.radians("angle");
    const factor = p.f32("factor");
    // Bend wraps the span into an arc of the given angle; the radius that
    // preserves the arc's length is span / angle.
    const radius: f32 = Mathf.abs(angle) > <f32>1e-6 ? span / angle : <f32>0.0;
    const centre = (min + max) * <f32>0.5;

    const ids = mesh.verts.ids();
    for (let k = 0; k < ids.length; k++) {
        const v = ids[k];
        const w = weightAt(weights, invert, v);
        if (w == <f32>0.0) continue;
        const co = mesh.verts.at(v).co;
        // Where along the parameter axis, as 0..1 of the deformed window.
        const along = (co.get(param) - min.get(param)) / span;
        const t = clampF32((along - lower) / window, 0.0, 1.0);
        let moved = co;
        if (mode == "twist") {
            const rot = rotationAbout(axis, angle * t * w);
            let local = co - centre;
            // The rotation must not move the point along the axis.
            const keep = local.get(axis);
            local.set(axis, 0.0);
            let out = rot.mulVec3(local);
            out.set(axis, keep);
            moved = centre + out;
        } else if (mode == "taper") {
            const scale: f32 = <f32>1.0 + factor * (t - <f32>0.5) * <f32>2.0 * w;
            let local = co - centre;
            for (let i = 0; i < 3; i++) {
                if (i != axis) local.set(i, local.get(i) * scale);
            }
            moved = centre + local;
        } else if (mode == "stretch") {
            // Longer along the axis, thinner across it, volume roughly
            // kept — Blender's stretch with a bulge of 1.
            const s: f32 = <f32>1.0 + factor * w;
            const cross: f32 = Mathf.abs(s) > <f32>1e-6
                ? <f32>1.0 / maxF32(Mathf.sqrt(s), <f32>1e-6)
                : <f32>1.0;
            let local = co - centre;
            for (let i = 0; i < 3; i++) {
                local.set(i, local.get(i) * (i == axis ? s : cross));
            }
            moved = centre + local;
        } else {
            // Bend: wrap the parameter axis onto a circle in the plane of
            // the two axes the deformation turns about. A point's distance
            // from the bend axis becomes its distance from the arc's centre,
            // so the outside of the curve stretches and the inside
            // compresses, as bending a bar does.
            if (Mathf.abs(radius) < <f32>1e-9) {
                moved = co;
            } else {
                const across = (axis + 2) % 3;
                const a: f32 = angle * (t - <f32>0.5) * w;
                const local = co - centre;
                const r: f32 = local.get(across) - radius;
                let out = local;
                // Separate sin and cos, not one sincos: the recorded
                // reference values come from Apple libm's `sinf` and `cosf`,
                // which appleSinf / appleCosf (and vecmath's sinf / cosf)
                // reproduce bit for bit.
                out.set(param, -r * appleSinf(a));
                out.set(across, r * appleCosf(a) + radius);
                moved = centre + out;
            }
        }
        mesh.verts.at(v).co = moved;
    }
    mesh.recalcNormals();
    mesh.touch();
    return Result.okv<Array<string>>(warnings);
}

// A rotation about X, Y or Z. Its sine and cosine come from one call to
// appleSincosf, which reproduces Apple libm's `__sincosf_stret` bit for bit
// (it is not correctly rounded, and the recorded reference values depend
// on it); vecmath's `Mat3.fromRotation*` use it too.
function rotationAbout(axis: i32, angle: f32): Mat3 {
    const sc = appleSincosf(angle);
    const sina = sc.s;
    const cosa = sc.c;
    switch (axis) {
        case 0: return Mat3.fromCols(VEC3_X, Vec3(0.0, cosa, sina), Vec3(0.0, -sina, cosa));
        case 1: return Mat3.fromCols(Vec3(cosa, 0.0, -sina), VEC3_Y, Vec3(sina, 0.0, cosa));
        default: return Mat3.fromCols(Vec3(cosa, sina, 0.0), Vec3(-sina, cosa, 0.0), VEC3_Z);
    }
}
