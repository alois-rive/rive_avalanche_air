// Smooth and Smooth (Laplacian) — Blender ships them as two modifiers
// whose only real difference is the weighting, so they are one type here
// with a `mode`, the way `decimate` carries its three modes.
//
// `simple` averages a vertex with its neighbours and moves a fraction of
// the way there, per repeat. `laplacian` weights the neighbours by the
// cotangents of the angles opposite the shared edge, which moves points
// along the surface instead of shrinking it, and can put the volume back
// afterwards.

import { Vec3, VEC3_ZERO, VEC3_ONE } from "../../../../base/vecmath";
import { Result, clampF32 } from "../../../../base/util";
import { Mesh, Bounds, VertId, NO_ID } from "../../mesh/mod";
import { ModifierEnv } from "../mod";
import { PropDef, PropKind, Props, prop } from "./props";
import { VERTEX_GROUP, INVERT_GROUP, weightField, weightAt } from "./common";

export const PROPS: Array<PropDef> = [
    prop(
        "mode",
        PropKind.Choice(["simple", "laplacian"]),
        "simple",
        "simple averages neighbours, laplacian weights them by cotangent and keeps the shape",
    ),
    prop(
        "factor",
        PropKind.Float(),
        "0.5",
        "in simple mode, how far towards the neighbour average each repeat moves a vertex",
    ),
    prop(
        "lambda",
        PropKind.Float(),
        "0.01",
        "in laplacian mode, the step size (Blender's lambda_factor)",
    ),
    prop(
        "lambda-border",
        PropKind.Float(),
        "0.01",
        "in laplacian mode, the step size on boundary edges",
    ),
    prop(
        "repeat",
        PropKind.IntRange(0, 200),
        "1",
        "how many smoothing passes to run",
    ),
    prop(
        "axis",
        PropKind.Axes(),
        "x,y,z",
        "restrict the movement to these axes",
    ),
    prop(
        "preserve-volume",
        PropKind.Bool(),
        "true",
        "in laplacian mode, rescale afterwards so the shape does not shrink",
    ),
    VERTEX_GROUP,
    INVERT_GROUP,
];

// The moves of one smoothing step: vertex ids and their deltas, as two
// parallel arrays.
export class Step {
    verts: Array<VertId> = [];
    deltas: Array<Vec3> = [];
}

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const wf = weightField(mesh, p, env);
    const weights = wf.field;
    const invert = wf.invert;
    const warnings = weights.warnings.slice(0);
    const repeat = p.u32("repeat");
    if (repeat == 0 || mesh.verts.isEmpty()) {
        return Result.okv<Array<string>>(warnings);
    }
    const axes = p.axes("axis");
    const mask = Vec3(
        axes[0] ? <f32>1.0 : <f32>0.0,
        axes[1] ? <f32>1.0 : <f32>0.0,
        axes[2] ? <f32>1.0 : <f32>0.0,
    );
    if (mask == VEC3_ZERO) {
        return Result.okv<Array<string>>(warnings);
    }
    const laplacian = p.str("mode") == "laplacian";
    let before: Bounds? = null;
    if (laplacian) {
        const b = mesh.bounds();
        if (b != null && p.bool("preserve-volume")) before = b;
    }

    for (let pass: u32 = 0; pass < repeat; pass++) {
        const targets = laplacian
            ? cotangentStep(mesh, p.f32("lambda"), p.f32("lambda-border"))
            : umbrellaStep(mesh, p.f32("factor"));
        for (let i = 0; i < targets.verts.length; i++) {
            const v = targets.verts[i];
            const delta = targets.deltas[i];
            const w = weightAt(weights, invert, v);
            if (w == <f32>0.0) continue;
            const vert = mesh.verts.at(v);
            vert.co = vert.co + (delta * w).mul(mask);
        }
    }

    // Laplacian smoothing shrinks a closed shape a little every pass;
    // Blender's "Preserve Volume" scales it back about its centre, which is
    // what this does with the bounding box it measured first.
    if (before != null) {
        const after = mesh.bounds();
        if (after != null) {
            const min0 = before.lo;
            const max0 = before.hi;
            const min1 = after.lo;
            const max1 = after.hi;
            const size0 = max0 - min0;
            const size1 = max1 - min1;
            const scale = Vec3(
                ratio(size0.x, size1.x),
                ratio(size0.y, size1.y),
                ratio(size0.z, size1.z),
            );
            const centre = (min1 + max1) * <f32>0.5;
            if ((scale - VEC3_ONE).abs().maxElement() > <f32>1e-6) {
                const ids = mesh.verts.ids();
                for (let i = 0; i < ids.length; i++) {
                    const vert = mesh.verts.at(ids[i]);
                    const co = vert.co;
                    vert.co = centre + (co - centre).mul(scale);
                }
            }
        }
    }

    mesh.recalcNormals();
    mesh.touch();
    return Result.okv<Array<string>>(warnings);
}

function ratio(before: f32, after: f32): f32 {
    if (Mathf.abs(after) < <f32>1e-9) return 1.0;
    return before / after;
}

// The plain umbrella operator: move a fraction of the way to the mean of
// the connected vertices.
export function umbrellaStep(mesh: Mesh, factor: f32): Step {
    const out = new Step();
    const ids = mesh.verts.ids();
    for (let i = 0; i < ids.length; i++) {
        const v = ids[i];
        const neighbors = mesh.vertNeighbors(v);
        if (neighbors.length == 0) continue;
        let sum = VEC3_ZERO;
        for (let j = 0; j < neighbors.length; j++) sum = sum + mesh.verts.at(neighbors[j]).co;
        const mean = sum / <f32>neighbors.length;
        out.verts.push(v);
        out.deltas.push((mean - mesh.verts.at(v).co) * factor);
    }
    return out;
}

// The cotangent-weighted operator. For each edge the weight is
// `cot(alpha) + cot(beta)`, the angles opposite it in the two faces that
// share it; a boundary edge has one and takes the border step size.
export function cotangentStep(mesh: Mesh, lambda: f32, lambdaBorder: f32): Step {
    const out = new Step();
    const ids = mesh.verts.ids();
    for (let i = 0; i < ids.length; i++) {
        const v = ids[i];
        const co = mesh.verts.at(v).co;
        let sum = VEC3_ZERO;
        let total: f32 = 0.0;
        let border = false;
        const es = mesh.vertEdges(v);
        for (let j = 0; j < es.length; j++) {
            const e = es[j];
            const other = mesh.edges.at(e).other(v);
            if (other == NO_ID) continue;
            const faces = mesh.edgeFaces(e);
            if (faces.length < 2) border = true;
            let w: f32 = 0.0;
            for (let k = 0; k < faces.length; k++) {
                // The corner of `f` that is neither end of the edge.
                const fv = mesh.faceVerts(faces[k]);
                for (let q = 0; q < fv.length; q++) {
                    const o = fv[q];
                    if (o == v || o == other) continue;
                    w += cotangent(mesh.verts.at(o).co, co, mesh.verts.at(other).co);
                }
            }
            // Uniform weights where there is no face to measure, so a
            // wire edge still pulls.
            if (faces.length == 0) w = 1.0;
            // A very obtuse corner gives a large negative cotangent,
            // which flips the step outward and blows the mesh apart.
            // Blender clamps the same way.
            w = clampF32(w, 0.0, 1e4);
            sum = sum + (mesh.verts.at(other).co - co) * w;
            total += w;
        }
        if (total <= <f32>1e-12) continue;
        const step = border ? lambdaBorder : lambda;
        out.verts.push(v);
        out.deltas.push(sum / total * step);
    }
    return out;
}

// `cot` of the angle at `apex` in the triangle `apex, a, b`.
export function cotangent(apex: Vec3, a: Vec3, b: Vec3): f32 {
    const u = a - apex;
    const v = b - apex;
    const cross = u.cross(v).length();
    if (cross < <f32>1e-12) return 0.0;
    return u.dot(v) / cross;
}
