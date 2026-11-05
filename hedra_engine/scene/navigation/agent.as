// Derived from Godot Engine 4.4 (MIT); see THIRD_PARTY_NOTICES.md.
//
// How a NavigationAgent3D follows its path (milestone 63,
// docs/engine/NAVIGATION.md "Agents"): Godot 4.4's
// NavigationAgent3D::_update_navigation (scene/3d/navigation_agent_3d.cpp)
// and the checks around it, over the agent's kept state (./agent_state.as),
// installed for the node's methods (installAgentLogic: the run time's
// navigation feature and the tools' clock install it) and run by the
// step (./sim.as) for every agent in tree order.
//
// An update, as Godot's:
//   - nothing without a 3D parent (the actor), nor before a target was
//     submitted (Godot's target_position_submitted: the file's
//     target_position, a binding or a key that changed it, a script's
//     setTargetPosition), nor after the navigation finished (until a new
//     target);
//   - a new path when one was asked for (a target set, other navigation
//     layers: Godot's _request_repath), when the map's iteration moved
//     since the path was found (Godot's agent_is_map_changed), when the
//     path is empty (an unreachable map is asked again each update, as
//     Godot's is), or when the actor is path_max_distance or more from the
//     segment it is on (from the point before path_index to the one at it,
//     both lowered by path_height_offset, in 3D: Godot's check, done only
//     once path_index is past 0). Hedra asks again too when the agent's
//     path_postprocessing, path_metadata_flags, simplify_path or
//     simplify_epsilon differ from those the path was found with (Godot
//     sends them with the next query only). The query starts at the
//     actor's global position (Godot's: not lowered by the offset) and
//     goes to target_position over the agent's navigation_layers;
//   - then, the target within target_desired_distance of the actor: the
//     waypoints within path_desired_distance passed, target_reached, and
//     navigation_finished; else the waypoints passed and, the last one
//     passed while the target is not reachable (the path's end is farther
//     than target_desired_distance from it), navigation_finished. Each
//     signal is owed once (the state's flags), emitted at the step's end
//     (./sim.as), so a script's own call of getNextPathPosition during its
//     frame leaves them for the step.
//   - Godot's distances: a waypoint is passed when the actor is nearer
//     than path_desired_distance to it lowered by path_height_offset (3D),
//     the target when nearer than target_desired_distance (3D, the target
//     not lowered); getNextPathPosition answers the path point at
//     path_index lowered by path_height_offset (the actor's own position
//     when the path is empty).
//
// The path queries of a step are one job (./sim.as PathQueryJob); this
// module splits the update into what the job needs (needsPath, fillQuery,
// takePath, follow), and runs them in turn for a call outside the step.
//
// drive_parent (Hedra's): the velocity the agent wants of itself
// (driveVelocity), towards the path point it heads for (aimIndex: its next
// one, or past the points Godot's funnel puts on a straight way only to
// mark an edge crossed, to the corner beyond) at max_speed on the ground
// plane (in 3D while it crosses a link, so a ladder climbs), slowing
// within twice target_desired_distance of the path's end so that it
// arrives rather than overshoots, 0 once finished. The waypoints and their
// signals stay Godot's, but for the crossing points it heads past: one of
// those is reached when the actor comes within path_desired_distance of
// it, as Godot's, or once the actor is beyond it along the straight way
// (its place on the line from the point before to the point after lies
// past the crossing's). An actor the avoidance pushed off the line misses
// a crossing by more than path_desired_distance; kept on it, the agent
// would reach the corner still at the crossing behind, aim at the corner
// for ever and circle it (never path_max_distance off the old segment, so
// never asking again).

import { Vec3 } from "../../base/vecmath";
import { NavigationAgent3D, SceneNode } from "../tree/node";
import {
    NavigationMap, NavigationPathQueryParameters3D, NavigationPathQueryResult3D, PATH_METADATA_INCLUDE_OWNERS,
    PATH_METADATA_INCLUDE_TYPES, PATH_SEGMENT_TYPE_LINK,
} from "./api";
import { NavAgentLogic, NavAgentState, installNavAgentLogic } from "./agent_state";

// The map of an agent outside a live tree before any step told the logic
// one (answers nothing).
const NO_MAP = new NavigationMap();

// Below this horizontal speed (m/s) an agent is still: no turn, no move.
const STILL_SPEED: f32 = 1e-5;

export class GodotAgentLogic extends NavAgentLogic {
    // The map a tree outside the run time is navigated on (the step's: the
    // tools' trees are not live, so a node cannot find it itself).
    map: NavigationMap = NO_MAP;
    // A call outside the step queries here (the main lane's own).
    private params: NavigationPathQueryParameters3D = new NavigationPathQueryParameters3D();
    private result: NavigationPathQueryResult3D = new NavigationPathQueryResult3D();
    // Path queries run by update() outside the step (the tests').
    queries: i32 = 0;

    // The map `a` is navigated on: its live tree's, else the step's.
    mapFor(a: NavigationAgent3D): NavigationMap {
        const t = a.liveTree;
        return t != null ? t.world.navigationMap : this.map;
    }

    update(agent: SceneNode, s: NavAgentState): void {
        const isAgent = agent instanceof NavigationAgent3D;
        if (!isAgent) return;
        const a = agent as NavigationAgent3D;
        const map = this.mapFor(a);
        if (this.needsPath(a, s, map)) {
            this.fillQuery(a, map, this.params);
            map.queryPath(this.params, this.result);
            this.queries++;
            this.takePath(a, s, this.result, map.iterationId());
        }
        this.follow(a, s);
    }

    targetReachable(agent: SceneNode, s: NavAgentState): bool {
        this.update(agent, s);
        const isAgent = agent instanceof NavigationAgent3D;
        if (!isAgent) return false;
        return reachableNow(agent as NavigationAgent3D, s);
    }

    // Godot's reload_path (see the header).
    needsPath(a: NavigationAgent3D, s: NavAgentState, map: NavigationMap): bool {
        const actor = a.actor();
        if (actor == null || !s.targetSubmitted) return false;
        if (s.repathRequested) return true;
        if (map.iterationId() != s.pathIteration) return true;
        if (s.path.length == 0) return true;
        if (a.pathPostprocessing != s.pathPostprocessing || queryFlags(a) != s.pathMetadataFlags
            || a.simplifyPath != s.pathSimplify || a.simplifyEpsilon != s.pathSimplifyEpsilon) {
            return true;
        }
        const i = s.pathIndex;
        if (i > 0 && i < s.path.length) {
            const off = a.pathHeightOffset;
            const p0 = unchecked(s.path[i - 1]);
            const p1 = unchecked(s.path[i]);
            const origin = actor.globalPosition;
            const c = closestOnSegment(origin, Vec3(p0.x, p0.y - off, p0.z), Vec3(p1.x, p1.y - off, p1.z));
            if (origin.distance(c) >= a.pathMaxDistance) return true;
        }
        return false;
    }

    // The query an agent asks (Godot's navigation_query): from its actor to
    // its target, with its layers, post-processing, metadata and
    // simplification. A drive_parent agent always asks for the types too,
    // whatever its path_metadata_flags: its move needs them to know when
    // it crosses a link (crossingLink, aimIndex); the waypoints' signals
    // still report by the agent's own flags (advanceWaypoints).
    fillQuery(a: NavigationAgent3D, map: NavigationMap, p: NavigationPathQueryParameters3D): void {
        p.map = map;
        p.startPosition = a.actorPosition();
        p.targetPosition = a.targetPosition;
        p.navigationLayers = a.navigationLayers;
        p.pathfindingAlgorithm = a.pathfindingAlgorithm;
        p.pathPostprocessing = a.pathPostprocessing;
        p.metadataFlags = queryFlags(a);
        p.simplifyPath = a.simplifyPath;
        p.simplifyEpsilon = a.simplifyEpsilon;
    }

    // A query's answer `r`, found at map iteration `iteration`, becomes the
    // agent's path (copied in place), as Godot's reload: the navigation
    // not finished, the last waypoint not reached, path_index 0,
    // path_changed owed.
    takePath(a: NavigationAgent3D, s: NavAgentState, r: NavigationPathQueryResult3D, iteration: i32): void {
        const n = r.path.length;
        const tn = r.pathTypes.length < n ? r.pathTypes.length : n;
        const on = r.pathOwners.length < n ? r.pathOwners.length : n;
        s.sizePath(n, tn, on);
        const path = s.path;
        for (let i = 0; i < n; i++) unchecked(path[i] = unchecked(r.path[i]));
        for (let i = 0; i < tn; i++) unchecked(s.pathTypes[i] = unchecked(r.pathTypes[i]));
        for (let i = 0; i < on; i++) unchecked(s.pathOwners[i] = unchecked(r.pathOwners[i]));
        s.hasPath = n > 0;
        s.pathIteration = iteration;
        s.pathTarget = a.targetPosition;
        s.pathLayers = a.navigationLayers;
        s.pathPostprocessing = a.pathPostprocessing;
        s.pathMetadataFlags = queryFlags(a);
        s.pathSimplify = a.simplifyPath;
        s.pathSimplifyEpsilon = a.simplifyEpsilon;
        s.reachable = r.reachedTarget;
        if (n > 0) {
            const last = unchecked(path[n - 1]);
            s.finalPosition = Vec3(last.x, last.y - a.pathHeightOffset, last.z);
        } else {
            s.finalPosition = Vec3(0, 0, 0);
        }
        s.navigationFinished = false;
        s.lastWaypointReached = false;
        s.pathIndex = 0;
        s.pathChangedPending = true;
        s.repathRequested = false;
    }

    // The rest of Godot's update, after the path (see the header).
    follow(a: NavigationAgent3D, s: NavAgentState): void {
        const actor = a.actor();
        if (actor == null) {
            s.nextPosition = Vec3(0, 0, 0);
            s.distanceToTarget = 0;
            return;
        }
        const origin = actor.globalPosition;
        if (s.targetSubmitted && s.path.length > 0 && !s.navigationFinished) {
            if (origin.distance(a.targetPosition) < a.targetDesiredDistance) {
                advanceWaypoints(a, s, origin);
                s.targetReached = true;
                s.targetReachedPending = true;
                finishNavigation(a, s);
            } else {
                advanceWaypoints(a, s, origin);
                if (s.lastWaypointReached && !reachableNow(a, s)) finishNavigation(a, s);
            }
        }
        nextOf(a, s, origin);
    }
}

// The metadata flags `a`'s query asks for: its path_metadata_flags, and
// the types for a drive_parent agent (see fillQuery).
function queryFlags(a: NavigationAgent3D): i32 {
    return a.driveParent ? a.pathMetadataFlags | PATH_METADATA_INCLUDE_TYPES : a.pathMetadataFlags;
}

// Godot's _is_target_reachable: the path's end (lowered by the offset; the
// origin for an empty path, as Godot's Vector3()) within
// target_desired_distance of the target.
function reachableNow(a: NavigationAgent3D, s: NavAgentState): bool {
    return a.targetDesiredDistance >= s.finalPosition.distance(a.targetPosition);
}

// The next path position and the distance to the target, from `origin`.
export function nextOf(a: NavigationAgent3D, s: NavAgentState, origin: Vec3): void {
    const n = s.path.length;
    if (n == 0) {
        s.nextPosition = origin;
    } else {
        const i = s.pathIndex < n ? s.pathIndex : n - 1;
        const p = unchecked(s.path[i]);
        s.nextPosition = Vec3(p.x, p.y - a.pathHeightOffset, p.z);
    }
    s.distanceToTarget = origin.distance(a.targetPosition);
}

// Godot's _advance_waypoints: past every waypoint within
// path_desired_distance, each owed a waypoint_reached (and a link_reached
// when it lies on a link), up to the last.
// For drive_parent, a crossing point it heads past is passed beyond it
// too (see the header).
function advanceWaypoints(a: NavigationAgent3D, s: NavAgentState, origin: Vec3): void {
    if (s.lastWaypointReached) return;
    const path = s.path;
    const off = a.pathHeightOffset;
    const flags = a.pathMetadataFlags;
    // (the crossings run from path_index up to the aim, which passing them
    // does not move)
    const aim = a.driveParent ? aimIndex(s) : 0;
    while (true) {
        const i = s.pathIndex;
        const p = unchecked(path[i]);
        if (!(origin.distance(Vec3(p.x, p.y - off, p.z)) < a.pathDesiredDistance)
            && !(i < aim && beyondCrossing(s, i, off, origin))) break;
        // (Godot's details: the point as the path holds it, its type when
        // the flags include types, its owner when they include owners)
        const typed = (flags & PATH_METADATA_INCLUDE_TYPES) != 0 && i < s.pathTypes.length;
        const onLink = typed && unchecked(s.pathTypes[i]) == PATH_SEGMENT_TYPE_LINK;
        const owned = (flags & PATH_METADATA_INCLUDE_OWNERS) != 0 && i < s.pathOwners.length;
        s.oweWaypoint(p, i, onLink, owned ? unchecked(s.pathOwners[i]) : null);
        if (i == path.length - 1) {
            s.lastWaypointReached = true;
            break;
        }
        s.pathIndex = i + 1;
    }
}

// Whether `origin` lies past the crossing point `j` (0 < j < the path's
// last) along the straight way it is on: its place on the segment from the
// point before to the point after, all lowered by `off`, at or beyond the
// crossing's.
function beyondCrossing(s: NavAgentState, j: i32, off: f32, origin: Vec3): bool {
    const p0 = unchecked(s.path[j - 1]);
    const pj = unchecked(s.path[j]);
    const p1 = unchecked(s.path[j + 1]);
    const ax = p1.x - p0.x;
    const ay = p1.y - p0.y;
    const az = p1.z - p0.z;
    const at = (origin.x - p0.x) * ax + (origin.y + off - p0.y) * ay + (origin.z - p0.z) * az;
    const cross = (pj.x - p0.x) * ax + (pj.y - p0.y) * ay + (pj.z - p0.z) * az;
    return at >= cross;
}

// Godot's _transition_to_navigation_finished: finished, the target no
// longer submitted, navigation_finished owed, and an avoiding agent's
// velocities on the avoidance's side put to 0.
function finishNavigation(a: NavigationAgent3D, s: NavAgentState): void {
    s.navigationFinished = true;
    s.targetSubmitted = false;
    s.finishedPending = true;
    if (a.avoidanceEnabled) {
        s.preferredVelocity = Vec3(0, 0, 0);
        s.avoidanceVelocity = Vec3(0, 0, 0);
        s.storedYVelocity = 0;
    }
}

// Whether the agent is crossing a link: the point before its next one lies
// on a link (the path's metadata typed it so).
export function crossingLink(s: NavAgentState): bool {
    const i = s.pathIndex;
    return i > 0 && i - 1 < s.pathTypes.length && unchecked(s.pathTypes[i - 1]) == PATH_SEGMENT_TYPE_LINK
        && i < s.path.length;
}

// The velocity drive_parent gives the agent (see the header), from its
// actor at `origin`.
export function driveVelocity(a: NavigationAgent3D, s: NavAgentState, origin: Vec3): Vec3 {
    if (!s.targetSubmitted || s.navigationFinished || s.path.length == 0 || !(a.maxSpeed > 0)) return Vec3(0, 0, 0);
    const aim = aimIndex(s);
    const ap = unchecked(s.path[aim]);
    const next = Vec3(ap.x, ap.y - a.pathHeightOffset, ap.z);
    const link = crossingLink(s);
    const dx = next.x - origin.x;
    const dy = link ? next.y - origin.y : 0;
    const dz = next.z - origin.z;
    const len = Mathf.sqrt(dx * dx + dy * dy + dz * dz);
    if (!(len > STILL_SPEED)) return Vec3(0, 0, 0);
    let speed = a.maxSpeed;
    // (slowing to arrive: within twice target_desired_distance of the
    // path's end, the speed in proportion to what is left)
    const f = s.finalPosition;
    const fx = f.x - origin.x;
    const fz = f.z - origin.z;
    const left = Mathf.sqrt(fx * fx + fz * fz);
    const slow = a.targetDesiredDistance * 2;
    if (slow > 0 && left < slow && aim == s.path.length - 1) speed = speed * (left / slow);
    const k = speed / len;
    return Vec3(dx * k, dy * k, dz * k);
}

// How far (m) a path point may lie off the straight line through its
// neighbours and still be one Godot's corridor funnel put there only to
// mark a polygon edge crossed (its _clip_path: a point on the straight way
// between two corners, for the metadata).
const ON_LINE: f32 = 0.001;

// The path point drive_parent heads for: the next one (path_index), or
// past it the first that is not on the straight line from the point before
// it to the point after it (a crossing point _clip_path added, which a
// waypoint check still passes as Godot's). Heading for the corner beyond
// rather than the crossing goes the same way along the path, but an agent
// the avoidance pushed off it heads back to the corner, not to the
// crossing: a crossing under an obstacle the mesh was not baked around (a
// radius obstacle standing on the way) would otherwise hold it against the
// obstacle for ever, every velocity it wants pointing at its centre.
// Link points and the points before and after a link are never passed so.
export function aimIndex(s: NavAgentState): i32 {
    const path = s.path;
    const n = path.length;
    let j = s.pathIndex < n ? s.pathIndex : n - 1;
    const types = s.pathTypes;
    const typed = types.length == n;
    while (j > 0 && j < n - 1) {
        if (typed && (unchecked(types[j - 1]) == PATH_SEGMENT_TYPE_LINK || unchecked(types[j]) == PATH_SEGMENT_TYPE_LINK)) break;
        const p = unchecked(path[j]);
        const c = closestOnSegment(p, unchecked(path[j - 1]), unchecked(path[j + 1]));
        if (!(p.distance(c) <= ON_LINE)) break;
        j++;
    }
    return j;
}

// The point of the segment [a, b] nearest `p` (Godot's
// Geometry3D::get_closest_point_to_segment).
export function closestOnSegment(p: Vec3, a: Vec3, b: Vec3): Vec3 {
    const ab = b - a;
    const l2 = ab.dot(ab);
    if (!(l2 > 0)) return a;
    const d = (p - a).dot(ab) / l2;
    if (d <= 0) return a;
    if (d >= 1) return b;
    return a + ab * d;
}

const logic = new GodotAgentLogic();

// Installs Godot's agent logic for the node's methods (the run time's
// navigation feature, the tools' clock) and answers it.
export function installAgentLogic(): GodotAgentLogic {
    installNavAgentLogic(logic);
    return logic;
}

// The installed-or-not logic object (the step tells it its map).
export function agentLogic(): GodotAgentLogic {
    return logic;
}
