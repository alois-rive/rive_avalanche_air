// The warnings of a scene's navigation agents and obstacles (milestone 63;
// docs/formats/RSCN.md "Navigation", docs/engine/NAVIGATION.md "Agents"),
// appended by ./warnings.as sceneDiagnostics, each at the node's
// declaration, with its code:
//   - `navigation-agent-parent`: a NavigationAgent3D whose parent is not a
//     Node3D (Godot's "The NavigationAgent3D can be used only under a
//     Node3D inheriting parent node.");
//   - `navigation-3d-avoidance` (Hedra's): use_3d_avoidance on an agent or
//     an obstacle: kept, not applied (Hedra avoids on the ground plane);
//   - `navigation-obstacle-scale`: an obstacle under a negative or zero
//     scale, or one rotated other than about Y (Godot's two warnings, its
//     sentences, the scale's first when both apply);
//   - `navigation-agent-unmoved` (Hedra's): an agent with neither
//     drive_parent (true, or bound) nor a script on its parent or itself:
//     nothing moves it;
//   - `navigation-agent-no-map` (Hedra's): an agent in a scene with no
//     NavigationRegion3D that has polygons (its paths are empty).
// In tree order, an agent's in that order; nothing for a scene without
// agents or obstacles.

import { Diagnostic } from "../../scene/error";
import { eulerYXZFromBasis, rotationOf, signedScale } from "../../scene/tree/xform";
import { NavigationAgent3D, NavigationObstacle3D, NavigationRegion3D, SceneNode } from "../../scene/tree/node";
import { SceneTree } from "../../scene/tree/tree";
import { NAVIGATION_DOC } from "./navigation_warnings";
import { nodeWarning } from "./warnings";

export const NAVIGATION_AGENT_PARENT_CODE = "navigation-agent-parent";
export const NAVIGATION_3D_AVOIDANCE_CODE = "navigation-3d-avoidance";
export const NAVIGATION_OBSTACLE_SCALE_CODE = "navigation-obstacle-scale";
export const NAVIGATION_AGENT_UNMOVED_CODE = "navigation-agent-unmoved";
export const NAVIGATION_AGENT_NO_MAP_CODE = "navigation-agent-no-map";

// Godot's sentences (navigation_agent_3d.cpp, navigation_obstacle_3d.cpp
// get_configuration_warnings), word for word.
export const NAVIGATION_AGENT_PARENT_MESSAGE = "The NavigationAgent3D can be used only under a Node3D inheriting parent node.";
export const NAVIGATION_OBSTACLE_SCALE_MESSAGE = "NavigationObstacle3D does not support negative or zero scaling.";
export const NAVIGATION_OBSTACLE_ROTATION_MESSAGE = "NavigationObstacle3D only takes global rotation around the y-axis "
    + "into account. Rotations around the x-axis or z-axis might lead to unexpected results.";

// Godot's least scale on an axis an obstacle supports (its check's 0.001).
const OBSTACLE_SCALE_MIN: f32 = 0.001;
// The least turn about X or Z (radians) that counts as one: Godot tests
// for exactly 0; a basis turned about Y alone comes back from its Euler
// angles within a float's rounding of 0 on the other two.
const OBSTACLE_TILT_MIN: f32 = 1e-5;

// Whether a binding drives `a`'s drive_parent: a view model switches the
// walk on and off (a room whose agents walk only while it is shown), so a
// false in the file is not an agent nothing moves.
function bindsDriveParent(a: NavigationAgent3D): bool {
    for (let i = 0; i < a.bindings.length; i++) if (a.bindings[i].property == "drive_parent") return true;
    return false;
}

// Whether a region of `tree` has polygons the map would take.
function hasPolygons(all: Array<SceneNode>): bool {
    for (let i = 0; i < all.length; i++) {
        const n = all[i];
        const isRegion = n instanceof NavigationRegion3D;
        if (!isRegion) continue;
        const m = (n as NavigationRegion3D).navigationMesh;
        if (m != null && m.valid && m.polygonCount() > 0) return true;
    }
    return false;
}

// The warnings of `tree`'s agents and obstacles, in tree order.
export function navigationAgentDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const all = tree.walk();
    let polygons = -1;
    for (let i = 0; i < all.length; i++) {
        const n = all[i];
        const isAgent = n instanceof NavigationAgent3D;
        const isObstacle = n instanceof NavigationObstacle3D;
        if (isAgent) {
            const a = n as NavigationAgent3D;
            const actor = a.actor();
            if (actor == null) {
                out.push(nodeWarning(tree, a, NAVIGATION_AGENT_PARENT_CODE, NAVIGATION_AGENT_PARENT_MESSAGE,
                    "put the agent under the Node3D it steers (a character's root); see " + NAVIGATION_DOC));
            }
            if (a.use3dAvoidance) {
                out.push(nodeWarning(tree, a, NAVIGATION_3D_AVOIDANCE_CODE, "NavigationAgent3D " + a.path()
                    + "'s use_3d_avoidance is kept and not applied: agents avoid each other on the ground plane",
                    "set use_3d_avoidance to false: Hedra's avoidance is Godot's 2D avoidance; see " + NAVIGATION_DOC));
            }
            if (actor != null && !a.driveParent && !bindsDriveParent(a) && a.script == null && actor.script == null) {
                out.push(nodeWarning(tree, a, NAVIGATION_AGENT_UNMOVED_CODE, "NavigationAgent3D " + a.path()
                    + " has neither drive_parent nor a script on it or its parent: nothing moves " + actor.path()
                    + " along its path",
                    "set drive_parent to true for the agent to walk its parent, or give the parent a script that moves "
                    + "it towards getNextPathPosition(); see " + NAVIGATION_DOC));
            }
            if (polygons < 0) polygons = hasPolygons(all) ? 1 : 0;
            if (polygons == 0) {
                out.push(nodeWarning(tree, a, NAVIGATION_AGENT_NO_MAP_CODE, "NavigationAgent3D " + a.path()
                    + " finds no navigation mesh in the scene: its path is empty",
                    "add a NavigationRegion3D whose navigation_mesh has polygons (bake it with `hedra bake --navmesh "
                    + "<scene>`); see " + NAVIGATION_DOC));
            }
        } else if (isObstacle) {
            const o = n as NavigationObstacle3D;
            if (o.use3dAvoidance) {
                out.push(nodeWarning(tree, o, NAVIGATION_3D_AVOIDANCE_CODE, "NavigationObstacle3D " + o.path()
                    + "'s use_3d_avoidance is kept and not applied: agents avoid each other on the ground plane",
                    "set use_3d_avoidance to false: Hedra's avoidance is Godot's 2D avoidance; see " + NAVIGATION_DOC));
            }
            const g = o.global();
            const s = signedScale(g);
            if (s.x < OBSTACLE_SCALE_MIN || s.y < OBSTACLE_SCALE_MIN || s.z < OBSTACLE_SCALE_MIN) {
                out.push(nodeWarning(tree, o, NAVIGATION_OBSTACLE_SCALE_CODE, NAVIGATION_OBSTACLE_SCALE_MESSAGE,
                    "give " + o.path() + " and its parents a scale above 0 on every axis; see " + NAVIGATION_DOC));
            }
            const r = eulerYXZFromBasis(rotationOf(g));
            if (Mathf.abs(r.x) > OBSTACLE_TILT_MIN || Mathf.abs(r.z) > OBSTACLE_TILT_MIN) {
                out.push(nodeWarning(tree, o, NAVIGATION_OBSTACLE_SCALE_CODE, NAVIGATION_OBSTACLE_ROTATION_MESSAGE,
                    "turn " + o.path() + " and its parents about Y only: its outline and radius lie on the ground plane; see "
                    + NAVIGATION_DOC));
            }
        }
    }
    return out;
}
