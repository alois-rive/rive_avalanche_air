// The warnings of a scene's navigation regions, meshes and links
// (milestone 63; docs/formats/RSCN.md "Navigation", docs/engine/
// NAVIGATION.md): what render, the editor's Output panel, `inspect
// --check` and `build` report about them, each at the declaration of the
// node it is about (./warnings.as nodeWarning), appended by ./warnings.as
// sceneDiagnostics. A scene without navigation nodes has none, and reads
// no hedra.yaml for them (./navigation_settings.as says why).
//
// Godot's configuration warnings, their sentences as Godot writes them,
// and Hedra's, each with its code (RSCN.md's codes table lists them), in
// tree order, hidden nodes too (visibility changes nothing on a map):
//   - `navigation-mesh-missing`: a NavigationRegion3D without a
//     navigation_mesh (Godot's NavigationRegion3D
//     ::get_configuration_warnings sentence; Godot says it only of a
//     region visible in the tree, Hedra of every one: a hidden region
//     navigates all the same);
//   - `navigation-mesh-empty`: a mesh with no polygon (not baked: the hint
//     says `hedra bake --navmesh <scene>`);
//   - `navigation-mesh-invalid`: polygons that are not whole polygons of
//     the vertices (fewer than 3 corners or more than 32, an index out of
//     range, an item that is not a PackedInt32Array), or not convex: the
//     map takes none of the mesh's polygons (../../scene/navigation/map.as
//     navigationRegionUsable);
//   - `navigation-cell-size`: a mesh's cell_size or cell_height that is not
//     the map's (Godot's NavRegion3D synchronization error, said once a
//     region: "Attempted to update a navigation region with a navigation
//     mesh that uses a `cell_size` of 0.3 while assigned to a navigation
//     map set to a `cell_size` of 0.25"; the corners then do not meet on
//     the map's grid, and edges do not join where they should);
//   - `navigation-link-unconnected` (Hedra's): an enabled link one of whose
//     ends no polygon of the map lies within link_connection_radius of
//     (Godot joins a link's end to any polygon, whatever its layers, and
//     so does the map: the warning is the map's own answer);
//   - `navigation-settings` (Hedra's): a navigation/3d/* key of hedra.yaml
//     whose value is not a number above 0 (or true or false), at its line
//     of the file.

import { Diagnostic } from "../../scene/error";
import { displayF32 } from "../../base/fmt";
import { vfs } from "../../fs/vfs";
import { NavigationLink3D, NavigationRegion3D } from "../../scene/tree/node";
import { SceneTree } from "../../scene/tree/tree";
import { NAVMESH_MAX_POLYGON_CORNERS, NavigationMesh } from "../../scene/resource/navigation_mesh";
import { NavigationSettings, navigationSettingsFromText } from "../../scene/navigation/settings";
import { NavMap, navigationMeshConvex } from "../../scene/navigation/map";
import { nodeWarning } from "./warnings";
import { projectSettingsPath } from "./screen_settings";
import { settingWarning } from "./screen_warnings";
import { hasNavigation } from "./navigation_settings";

// Where the navigation's warnings point.
export const NAVIGATION_DOC = "docs/formats/RSCN.md \"Navigation\"";

export const NAVIGATION_MESH_MISSING_CODE = "navigation-mesh-missing";
export const NAVIGATION_MESH_EMPTY_CODE = "navigation-mesh-empty";
export const NAVIGATION_MESH_INVALID_CODE = "navigation-mesh-invalid";
export const NAVIGATION_CELL_SIZE_CODE = "navigation-cell-size";
export const NAVIGATION_LINK_UNCONNECTED_CODE = "navigation-link-unconnected";
export const NAVIGATION_SETTINGS_CODE = "navigation-settings";

// Godot's sentence (NavigationRegion3D::get_configuration_warnings).
export const NAVIGATION_MESH_MISSING_MESSAGE = "A NavigationMesh resource must be set or created for this node to work.";

const MISSING_HINT = "give it a NavigationMesh sub_resource and bake it: hedra bake --navmesh <scene>; see " + NAVIGATION_DOC;
const EMPTY_HINT = "bake it from the geometry under the region (hedra bake --navmesh <scene>, or the editor's Bake "
    + "NavigationMesh), or write its vertices and polygons by hand; see " + NAVIGATION_DOC;
const INVALID_HINT = "bake it again (hedra bake --navmesh <scene>), or make each polygon 3 to "
    + NAVMESH_MAX_POLYGON_CORNERS.toString() + " indices of its vertices, round a convex outline; see " + NAVIGATION_DOC;
const CELL_SIZE_HINT = "bake the mesh with the map's cell_size and cell_height, or set the map's to the mesh's in "
    + "hedra.yaml (navigation/3d/default_cell_size, navigation/3d/default_cell_height); see " + NAVIGATION_DOC;
const LINK_HINT = "move the end onto the navigation mesh, or raise navigation/3d/default_link_connection_radius in "
    + "hedra.yaml; see " + NAVIGATION_DOC;
const SETTINGS_HINT = "write a number above 0 (true or false for navigation/3d/use_edge_connections); the map keeps "
    + "Godot's default; see " + NAVIGATION_DOC;

// Why `m`'s polygons are not whole polygons of its vertices, or not
// convex ("" when they are both): the sentence's end after "has".
export function navigationMeshProblem(m: NavigationMesh): string {
    const p = m.polygonCount();
    const starts = m.polygonStarts;
    const idx = m.polygonIndices;
    const points = m.vertexCount();
    if (!m.valid) {
        // (an item that is not a PackedInt32Array leaves the mesh without
        // polygons: ../../scene/resource/navigation_mesh.as)
        if (p <= 0 || starts[0] != 0 || starts[p] != idx.length) {
            return "polygons that are not an Array of PackedInt32Array";
        }
        for (let k = 0; k < p; k++) {
            const n = starts[k + 1] - starts[k];
            if (n < 3 || n > NAVMESH_MAX_POLYGON_CORNERS) {
                return "a polygon (" + k.toString() + ") of " + n.toString() + (n == 1 ? " corner" : " corners")
                    + ", not 3 to " + NAVMESH_MAX_POLYGON_CORNERS.toString();
            }
        }
        for (let i = 0; i < idx.length; i++) {
            const c = idx[i];
            if (c < 0 || c >= points) {
                return "a polygon with an index past its " + points.toString() + (points == 1 ? " vertex" : " vertices");
            }
        }
        return "polygons that are not whole polygons of its vertices";
    }
    if (!navigationMeshConvex(m)) return "a polygon that is not convex";
    return "";
}

// Godot's is_equal_approx for the cell sizes it compares (CMP_EPSILON,
// relative past 1).
function sameSize(a: f32, b: f32): bool {
    if (a == b) return true;
    let tolerance = <f32>0.00001 * Mathf.abs(a);
    if (tolerance < <f32>0.00001) tolerance = <f32>0.00001;
    return Mathf.abs(a - b) < tolerance;
}

// The warnings of `tree`'s regions, meshes and links, in tree order (see
// the header); the settings' first, at their lines of hedra.yaml.
export function navigationDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    if (!hasNavigation(tree)) return out;
    const settings = new NavigationSettings();
    settingsDiagnostics(tree, settings, out);
    const walked = tree.walk();
    let links = 0;
    for (let i = 0; i < walked.length; i++) {
        const w = walked[i];
        const isLink = w instanceof NavigationLink3D;
        if (isLink) links++;
        const isRegion = w instanceof NavigationRegion3D;
        if (!isRegion) continue;
        const r = w as NavigationRegion3D;
        const m = r.navigationMesh;
        if (m == null) {
            out.push(nodeWarning(tree, r, NAVIGATION_MESH_MISSING_CODE, NAVIGATION_MESH_MISSING_MESSAGE, MISSING_HINT));
            continue;
        }
        const problem = navigationMeshProblem(m);
        if (problem.length > 0) {
            out.push(nodeWarning(tree, r, NAVIGATION_MESH_INVALID_CODE, "NavigationRegion3D " + r.path()
                + "'s NavigationMesh has " + problem + ": the map takes none of its polygons", INVALID_HINT));
        } else if (m.polygonCount() == 0) {
            out.push(nodeWarning(tree, r, NAVIGATION_MESH_EMPTY_CODE, "NavigationRegion3D " + r.path()
                + "'s NavigationMesh has no polygon: bake it (hedra bake --navmesh) or write its vertices and polygons",
                EMPTY_HINT));
        }
        // (Godot's two checks, each said once)
        if (!sameSize(m.cellSize, settings.cellSize)) {
            out.push(nodeWarning(tree, r, NAVIGATION_CELL_SIZE_CODE, cellMessage(r, "cell_size", m.cellSize,
                settings.cellSize), CELL_SIZE_HINT));
        }
        if (!sameSize(m.cellHeight, settings.cellHeight)) {
            out.push(nodeWarning(tree, r, NAVIGATION_CELL_SIZE_CODE, cellMessage(r, "cell_height", m.cellHeight,
                settings.cellHeight), CELL_SIZE_HINT));
        }
    }
    if (links > 0) linkDiagnostics(tree, settings, out);
    return out;
}

function cellMessage(r: NavigationRegion3D, field: string, mesh: f32, map: f32): string {
    return "NavigationRegion3D " + r.path() + "'s NavigationMesh uses a " + field + " of " + displayF32(mesh)
        + " while the navigation map is set to a " + field + " of " + displayF32(map)
        + ": its polygons' edges may not join their neighbours'";
}

// The project's settings into `settings`, and their warnings at their
// lines of hedra.yaml.
function settingsDiagnostics(tree: SceneTree, settings: NavigationSettings, out: Array<Diagnostic>): void {
    if (tree.scenePath.length == 0) return;
    const path = projectSettingsPath(tree.scenePath);
    if (path.length == 0) return;
    const text = vfs.readToString(path);
    if (!text.ok) return;
    const said = new Array<string>();
    navigationSettingsFromText(text.value, settings, said);
    const prefix = "hedra.yaml: ";
    for (let i = 0; i < said.length; i++) {
        const w = said[i];
        const rest = w.startsWith(prefix) ? w.substring(prefix.length) : w;
        const key = rest.substring(0, max<i32>(rest.indexOf(" is "), 0));
        out.push(settingWarning(tree, path, text.value, key, NAVIGATION_SETTINGS_CODE, w, SETTINGS_HINT));
    }
}

// Each enabled link with an end the map did not join (a map of the tree
// made here: the map's own answer, at the map's settings).
function linkDiagnostics(tree: SceneTree, settings: NavigationSettings, out: Array<Diagnostic>): void {
    const map = new NavMap(settings);
    map.sync(tree);
    const radius = displayF32(settings.linkConnectionRadius);
    for (let i = 0; i < map.links.length; i++) {
        const l = map.links[i];
        if (!l.enabled) continue;
        const start = map.linkJoined(i, true);
        const end = map.linkJoined(i, false);
        if (start && end) continue;
        const which = !start && !end ? "start_position and end_position have" : !start ? "start_position has" : "end_position has";
        out.push(nodeWarning(tree, l, NAVIGATION_LINK_UNCONNECTED_CODE, "NavigationLink3D " + l.path() + "'s " + which
            + " no polygon within " + radius + " m (the map's link_connection_radius): paths never take it", LINK_HINT));
    }
}
