// What a NavigationAgent3D keeps between frames (milestone 63,
// docs/engine/NAVIGATION.md "Agents"): its current path (the map's answer,
// copied into storage of its own), where it is along it, what it asked for
// and at which map iteration, the velocities of the last avoidance step,
// and Godot's flags (target reached, navigation finished). The node holds
// one (../tree/node.as NavigationAgent3D.nav); the agents' logic
// (./agent.as) reads and writes it; the node's Godot methods answer from it
// after asking the logic to bring it up to date, as Godot's
// get_next_path_position() updates the agent's navigation first.
//
// The logic is installed, not imported (installNavAgentLogic), so that the
// node's module stays free of the map and the search: the run time's
// navigation feature and the tools' clock (./clock.as) install it, and a
// tree no one installed it for answers as an agent with no path does (its
// parent's position, navigation finished).
//
// Memory: the arrays keep their storage (the path's grown by powers of
// two: sizePath); a path found again overwrites the last one in place, and
// the waypoints owed to the step's signals are
// listed in arrays emptied (not dropped) once emitted, so following,
// re-pathing and avoiding allocate nothing once an agent's path has grown
// to its longest.

import { MAT4_IDENTITY, Mat4, Vec3 } from "../../base/vecmath";
import { SceneNode } from "../tree/node";

// The path points an agent has room for once it has a path (and the
// step's answer to its query, ./sim.as AgentSlot): a crowd's paths, each
// a point longer than its last now and then, would otherwise grow their
// arrays in a step long after the start. 64 points (1.3 KB the path's
// arrays, 1.8 KB the answer's) hold every path of a room of a few hundred
// polygons; a longer one doubles them once.
export const NAV_AGENT_PATH_ROOM = 64;

export class NavAgentState {
    // The current path (global, scene space) and, one an item, each point's
    // type (PATH_SEGMENT_TYPE_*) and owner (a NavigationRegion3D or a
    // NavigationLink3D; null when the metadata flags leave owners out).
    path: Array<Vec3> = [];
    pathTypes: Array<i32> = [];
    pathOwners: Array<SceneNode?> = [];
    // The next point to reach (Godot's navigation_path_index).
    pathIndex: i32 = 0;
    // Whether the path holds a point, and the map iteration, target, layers
    // and query settings it was found for: another of any asks again.
    hasPath: bool = false;
    pathIteration: i32 = -1;
    pathTarget: Vec3 = Vec3(0, 0, 0);
    pathLayers: u32 = 1;
    pathPostprocessing: i32 = 0;
    pathMetadataFlags: i32 = 7;
    pathSimplify: bool = false;
    pathSimplifyEpsilon: f32 = 0;
    // The path's end (Godot's get_final_position, its height offset taken
    // off), and whether it was the target itself (false: the nearest
    // reachable point).
    finalPosition: Vec3 = Vec3(0, 0, 0);
    reachable: bool = false;
    // Godot's flags: the target was reached (target_reached emitted), the
    // navigation is finished (navigation_finished emitted).
    targetReached: bool = false;
    navigationFinished: bool = true;
    // Godot's target_position_submitted: a target was set (the file, a
    // binding or a key that changed it, a script's setTargetPosition) and
    // the navigation has not finished since; the agent asks for paths only
    // then. Godot's _request_repath: the next update asks for a new path
    // (a new target, other navigation layers). Godot's
    // last_waypoint_reached: the path's last point was passed.
    targetSubmitted: bool = false;
    repathRequested: bool = false;
    lastWaypointReached: bool = false;
    // The next path position as of the last update (Godot's
    // get_next_path_position), and the distance to the target (the output
    // distance_to_target).
    nextPosition: Vec3 = Vec3(0, 0, 0);
    distanceToTarget: f32 = 0;
    // The velocity the agent wants (Godot's `velocity`, or drive_parent's
    // own), and the safe velocity the avoidance answered (with its y
    // Godot's stored one), or the same velocity without avoidance;
    // `velocitySubmitted`: set since the last step.
    desiredVelocity: Vec3 = Vec3(0, 0, 0);
    safeVelocity: Vec3 = Vec3(0, 0, 0);
    velocitySubmitted: bool = false;
    // The avoidance's side of the agent (Godot's RVO agent): the preferred
    // velocity it was last given (on the ground plane), its own velocity
    // (the last step's new one, or what setVelocityForced put in), and the
    // y Godot keeps aside while it avoids on the plane (keep_y_velocity).
    preferredVelocity: Vec3 = Vec3(0, 0, 0);
    avoidanceVelocity: Vec3 = Vec3(0, 0, 0);
    storedYVelocity: f32 = 0;
    // Signals owed at the end of the step (Godot emits them from the
    // agent's update): path_changed, each waypoint passed (in order: its
    // point, its index in the path, whether it lies on a link, its owner),
    // target_reached, navigation_finished. `waypointPending` and
    // `linkPending` are the last waypoint's and link point's index (-1 none).
    pathChangedPending: bool = false;
    waypointPending: i32 = -1;
    linkPending: i32 = -1;
    pendingWaypoints: Array<Vec3> = [];
    pendingWaypointIndex: Array<i32> = [];
    pendingWaypointLink: Array<bool> = [];
    pendingWaypointOwner: Array<SceneNode?> = [];
    targetReachedPending: bool = false;
    finishedPending: bool = false;
    // The actor's global position at the end of the last step (current_speed
    // is the horizontal distance from it over the step's seconds), and
    // whether it was taken.
    lastActorPosition: Vec3 = Vec3(0, 0, 0);
    hasLastPosition: bool = false;
    // The tools' clock (./clock.as): the actor its start was taken of, its
    // local transform before the clock's first run, and what the last run
    // left it at, so that a later run starts from the start again unless
    // something else moved the actor since (an edit: that is the start).
    toolsActor: SceneNode? = null;
    toolsStart: Mat4 = MAT4_IDENTITY;
    toolsEnd: Mat4 = MAT4_IDENTITY;

    // The most points the three path arrays have had room for (sizePath).
    private pathRoom: i32 = 0;

    // The three path arrays at `n` points, `types` and `owners` of them
    // (0 when the query's metadata flags leave them out). Their room is
    // NAV_AGENT_PATH_ROOM points from the first path, doubled when a path
    // is longer than it, and kept when one is shorter: an array whose
    // length is set grows to exactly that length, so following paths a
    // point longer each time would allocate again and again.
    sizePath(n: i32, types: i32, owners: i32): void {
        if (n > this.pathRoom) {
            let room = this.pathRoom > 0 ? this.pathRoom : NAV_AGENT_PATH_ROOM;
            while (room < n) room *= 2;
            this.path.length = room;
            this.pathTypes.length = room;
            this.pathOwners.length = room;
            this.pathRoom = room;
        }
        this.path.length = n;
        this.pathTypes.length = types;
        this.pathOwners.length = owners;
    }

    // Forgets the path (a scene loaded again, the agent left the tree).
    clearPath(): void {
        this.path.length = 0;
        this.pathTypes.length = 0;
        this.pathOwners.length = 0;
        this.pathIndex = 0;
        this.hasPath = false;
        this.pathIteration = -1;
        this.reachable = false;
        this.targetReached = false;
        this.navigationFinished = true;
        this.lastWaypointReached = false;
        this.repathRequested = false;
        this.clearPending();
    }

    // Godot's _request_repath (a target set, other layers): the target is
    // submitted, not reached, and the next update asks for a new path,
    // which lowers navigation_finished (Godot lowers it here already and
    // empties the path; every answer of the node's comes after an update,
    // which replaces both, so the flag is left to it: a tree no logic was
    // installed for still says it is finished).
    requestRepath(): void {
        this.targetReached = false;
        this.targetSubmitted = true;
        this.repathRequested = true;
    }

    // Every signal owed, dropped (their storage kept).
    clearPending(): void {
        this.pathChangedPending = false;
        this.waypointPending = -1;
        this.linkPending = -1;
        this.pendingWaypoints.length = 0;
        this.pendingWaypointIndex.length = 0;
        this.pendingWaypointLink.length = 0;
        this.pendingWaypointOwner.length = 0;
        this.targetReachedPending = false;
        this.finishedPending = false;
    }

    // Back to an agent that never ran (the tools' clock's start), its
    // storage kept: no path, a target submitted when `submitted` (the
    // file set one), every velocity 0.
    restart(submitted: bool): void {
        this.clearPath();
        this.targetSubmitted = submitted;
        this.repathRequested = submitted;
        this.pathTarget = Vec3(0, 0, 0);
        this.finalPosition = Vec3(0, 0, 0);
        this.nextPosition = Vec3(0, 0, 0);
        this.distanceToTarget = 0;
        this.desiredVelocity = Vec3(0, 0, 0);
        this.safeVelocity = Vec3(0, 0, 0);
        this.velocitySubmitted = false;
        this.preferredVelocity = Vec3(0, 0, 0);
        this.avoidanceVelocity = Vec3(0, 0, 0);
        this.storedYVelocity = 0;
        this.hasLastPosition = false;
    }

    // A waypoint passed, owed to the step's signals.
    oweWaypoint(point: Vec3, index: i32, onLink: bool, owner: SceneNode?): void {
        this.pendingWaypoints.push(point);
        this.pendingWaypointIndex.push(index);
        this.pendingWaypointLink.push(onLink);
        this.pendingWaypointOwner.push(owner);
        this.waypointPending = index;
        if (onLink) this.linkPending = index;
    }
}

// What brings an agent up to date (./agent.as implements it: Godot's
// NavigationAgent3D::_update_navigation and the checks around it). `agent`
// is a NavigationAgent3D (typed as a node here, so that this module does
// not import the node classes' module, which imports it).
export abstract class NavAgentLogic {
    // Asks for a new path when it needs one (none yet, another target or
    // layers, another map iteration, the parent strayed past
    // path_max_distance), then moves pathIndex past the waypoints within
    // path_desired_distance and checks the target (Godot's order); fills
    // `s.nextPosition` and `s.distanceToTarget`.
    abstract update(agent: SceneNode, s: NavAgentState): void;

    // Godot's is_target_reachable(): whether the path's end is within
    // target_desired_distance of the target (after an update, as Godot's).
    abstract targetReachable(agent: SceneNode, s: NavAgentState): bool;
}

let installed: NavAgentLogic? = null;

// The logic agents are brought up to date with (null: none installed).
export function navAgentLogic(): NavAgentLogic? {
    return installed;
}

// Installs it (the navigation feature, the tools' clock); the same object
// again does nothing.
export function installNavAgentLogic(l: NavAgentLogic): void {
    installed = l;
}
