// The warnings of a scene's occluders (milestone 37; docs/formats/RSCN.md
// "Occlusion culling", docs/engine/OCCLUSION.md): what render, the editor's
// Output panel, `inspect --check` and `build` report about them, each at
// the declaration of the node it is about (./warnings.as nodeWarning),
// appended by ./warnings.as sceneDiagnostics. A scene without an
// OccluderInstance3D has none.
//
// Godot's configuration warnings (OccluderInstance3D
// ::get_configuration_warnings), their sentences as Godot writes them, for
// every OccluderInstance3D, hidden ones too (a hidden one is shown by a
// key or a binding, as the samples' are), in tree order:
//   - `occluder-missing`: no occluder;
//   - `occluder-bake-mask`: bake_mask 0 (a bake would make nothing);
//   - `occluder-empty`: an ArrayOccluder3D of fewer than 3 indices (an
//     empty one, or one whose .occ could not be read: occluder-data-invalid
//     says why at the file), a PolygonOccluder3D of fewer than 3 points;
//   - `occluder-polygon`: a polygon of 3 points or more that gives no
//     triangle (its edges cross, or it has no area), Godot's error;
//   - `occluder-invalid` (Hedra's): an ArrayOccluder3D whose indices are
//     not whole triangles of its vertices (Godot fails on it when it draws
//     its debug lines; Hedra says so before).
// Godot's warning about the project setting that turns occlusion culling
// off has no counterpart: Hedra culls with every scene's occluders (`render
// --occlusion off` and an OccluderInstance3D's `visible` turn it off).

import { Diagnostic } from "../../scene/error";
import { ArrayOccluder3D, PolygonOccluder3D, arrayOccluderValid } from "../../scene/resource/occluders";
import { occluderMeshOf } from "../../scene/render/occluder_shapes";
import { OccluderInstance3D } from "../../scene/tree/node";
import { SceneTree } from "../../scene/tree/tree";
import { nodeWarning } from "./warnings";

// Where the occluders' warnings point.
export const OCCLUSION_DOC = "docs/formats/RSCN.md \"Occlusion culling\"";

export const OCCLUDER_MISSING_CODE = "occluder-missing";
export const OCCLUDER_BAKE_MASK_CODE = "occluder-bake-mask";
export const OCCLUDER_EMPTY_CODE = "occluder-empty";
export const OCCLUDER_POLYGON_CODE = "occluder-polygon";
export const OCCLUDER_INVALID_CODE = "occluder-invalid";

// Godot's sentences.
const MISSING_MESSAGE = "No occluder mesh is defined in the Occluder property, so no occlusion culling will be "
    + "performed using this OccluderInstance3D.";
const BAKE_MASK_MESSAGE = "The Bake Mask has no bits enabled, which means baking will not produce any occluder "
    + "meshes for this OccluderInstance3D.";
const ARRAY_EMPTY_MESSAGE = "The occluder mesh has less than 3 vertices, so no occlusion culling will be performed "
    + "using this OccluderInstance3D.";
const POLYGON_EMPTY_MESSAGE = "The polygon occluder has less than 3 vertices, so no occlusion culling will be "
    + "performed using this OccluderInstance3D.";
const POLYGON_MESSAGE = "Failed to triangulate PolygonOccluder3D. Make sure the polygon doesn't have any "
    + "intersecting edges.";

const MISSING_HINT = "set occluder to a BoxOccluder3D, SphereOccluder3D, QuadOccluder3D or PolygonOccluder3D, "
    + "or bake one: hedra bake --occluders <scene>; see " + OCCLUSION_DOC;
const BAKE_MASK_HINT = "enable at least one bit in bake_mask (the visual layers a bake reads); see " + OCCLUSION_DOC;
const ARRAY_EMPTY_HINT = "bake the occluder again (hedra bake --occluders <scene>), or give the ArrayOccluder3D "
    + "vertices and indices; see " + OCCLUSION_DOC;
const POLYGON_EMPTY_HINT = "give the PolygonOccluder3D's polygon at least 3 points; see " + OCCLUSION_DOC;
const POLYGON_HINT = "list the polygon's points in order round its outline, so that no two edges cross; see "
    + OCCLUSION_DOC;
const INVALID_HINT = "bake the occluder again (hedra bake --occluders <scene>), or make its indices three a "
    + "triangle, each below its vertex count; see " + OCCLUSION_DOC;

// The warnings of `tree`'s occluders (see the header), in tree order.
export function occluderDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const walked = tree.walk();
    for (let i = 0; i < walked.length; i++) {
        const w = walked[i];
        const isOccluder = w instanceof OccluderInstance3D;
        if (!isOccluder) continue;
        const n = w as OccluderInstance3D;
        if (n.bakeMask == 0) out.push(nodeWarning(tree, n, OCCLUDER_BAKE_MASK_CODE, BAKE_MASK_MESSAGE, BAKE_MASK_HINT));
        const o = n.occluder;
        if (o == null) {
            out.push(nodeWarning(tree, n, OCCLUDER_MISSING_CODE, MISSING_MESSAGE, MISSING_HINT));
            continue;
        }
        const isArray = o instanceof ArrayOccluder3D;
        if (isArray) {
            const a = o as ArrayOccluder3D;
            if (a.indices.length < 3) {
                out.push(nodeWarning(tree, n, OCCLUDER_EMPTY_CODE, ARRAY_EMPTY_MESSAGE, ARRAY_EMPTY_HINT));
            } else if (!a.valid || !arrayOccluderValid(a.vertices.length / 3, a.indices)) {
                const points = a.vertices.length / 3;
                const why = a.indices.length % 3 != 0
                    ? " has " + a.indices.length.toString() + " indices, not whole triangles"
                    : " has an index past its " + points.toString() + (points == 1 ? " vertex" : " vertices");
                out.push(nodeWarning(tree, n, OCCLUDER_INVALID_CODE, "OccluderInstance3D " + n.path()
                    + "'s ArrayOccluder3D" + why + ": it occludes nothing", INVALID_HINT));
            }
            continue;
        }
        const isPolygon = o instanceof PolygonOccluder3D;
        if (isPolygon) {
            const p = o as PolygonOccluder3D;
            if (p.polygon.length / 2 < 3) {
                out.push(nodeWarning(tree, n, OCCLUDER_EMPTY_CODE, POLYGON_EMPTY_MESSAGE, POLYGON_EMPTY_HINT));
            } else if (occluderMeshOf(p).indices.length < 3) {
                out.push(nodeWarning(tree, n, OCCLUDER_POLYGON_CODE, POLYGON_MESSAGE, POLYGON_HINT));
            }
        }
    }
    return out;
}
