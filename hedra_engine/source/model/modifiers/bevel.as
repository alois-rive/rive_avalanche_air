// The Bevel modifier, bevel every manifold
// edge whose face angle exceeds the angle limit (Blender's "Angle" limit
// method).

import { Result } from "../../../base/util";
import { Mesh, EdgeId } from "../mesh/mod";
import { BevelOpts, bevelEdges } from "../ops/bevel";

// Returns the operator's warnings; Err (the operator's error text) when the
// bevel operator refused.
export function bevel(mesh: Mesh, width: f32, segments: u32, angleLimit: f32): Result<Array<string>> {
    const edges: Array<EdgeId> = [];
    const eb = mesh.edges.idBound();
    for (let e: u32 = 0; e < eb; e++) {
        if (!mesh.edges.contains(e)) continue;
        // edgeFaceAngle is NaN without two faces, and NaN > x is false.
        const a = mesh.edgeFaceAngle(e);
        if (a > angleLimit) edges.push(e);
    }
    if (edges.length == 0 || width <= 0) return Result.okv<Array<string>>([]);
    const opts = new BevelOpts();
    opts.width = width;
    opts.segments = segments > 1 ? segments : 1;
    const r = bevelEdges(mesh, edges, opts);
    if (!r.ok) return Result.fail<Array<string>>(r.err);
    return Result.okv<Array<string>>(r.value.warnings);
}
