// One tree's navigation, stepped (milestone 63, docs/engine/NAVIGATION.md
// "A frame"): what the run time's navigation feature
// (../runtime/feature_navigation.as) and the tools' clock (./clock.as) run
// each step, in Godot's order:
//
//   1. the map synced to the tree (./map.as NavMap.sync);
//   2. each agent in tree order brought up to date (./agent.as: a new path
//      when it needs one, the waypoints within path_desired_distance passed,
//      the target checked), the path queries of the step run as one job
//      (each agent's own result, a scratch per worker);
//   3. the velocity each agent wants: its `velocity` (set by a script or a
//      binding), or with drive_parent towards its next path position at
//      max_speed;
//   4. the avoidance (./avoidance.as, RVO2 on the ground plane) for the
//      agents with avoidance_enabled, against each other and the
//      obstacles, as a job (on Rive's script threads in a built project
//      when there are enough agents: ../../render/lanes.as);
//   5. velocity_computed emitted for every agent the avoidance computed,
//      in tree order (the safe velocity: see below, Godot emits it only
//      for agents with avoidance_enabled);
//   6. drive_parent agents' parents moved by the safe velocity times the
//      step, held to the map's polygons, and turned towards their motion by
//      drive_turn_speed; current_speed written;
//   7. the signals owed (path_changed, waypoint_reached, link_reached,
//      target_reached, navigation_finished) emitted in tree order.
//
// Signals go through the tree (SceneTree.emitEvent: the run time delivers
// them to connections, scripts and `signal:<name>` bindings; the tools'
// trees drop them), each with an event of the agent's own, so a step
// allocates nothing.
//
// What each step does, in detail (Godot 4.4's NavigationAgent3D, its
// server's agent and its map's step; where Hedra differs it says so):
//   - step 3: an agent's velocity reaches the avoidance as Godot's
//     internal physics process sends it: once set (a script's
//     setVelocity, a write of `velocity`), with a target or without (an
//     agent that only avoids), on the ground plane, its y kept
//     aside when keep_y_velocity (Godot's stored_y_velocity) and given back
//     on the safe velocity; the avoidance's preferred velocity is the last
//     one sent (Godot's server keeps it), 0 once the navigation finished.
//     drive_parent sends its own each step (./agent.as driveVelocity),
//     turned a thousandth of a radian to its right (keepRight below: what
//     keeps RVO2 from stalling on an exactly symmetric way);
//   - step 5: Godot 4.4 emits velocity_computed only for agents with
//     avoidance_enabled (their avoidance callback), each physics frame,
//     whether or not a velocity was set: so does Hedra (an agent without
//     avoidance emits none: its velocity is its own). Its argument is the
//     safe velocity (the avoidance's new velocity held to max_speed,
//     Godot's limit_length, its y the stored one), the event's `position`;
//   - step 6 (Hedra's drive_parent): the actor moves by its safe velocity
//     (its velocity without avoidance) times the step on the ground plane,
//     no farther than the path point it heads for (a fast agent lands on
//     a corner rather than going over it), then is held to the map: its x and z the map's closest point's when
//     it left the polygons, its y the closest point's lowered by
//     path_height_offset; while it crosses a link it moves along the link
//     in 3D instead (a jump, a ladder), unheld. It turns about Y towards
//     its motion (Godot's forward is -Z) by drive_turn_speed degrees a
//     second at most (0: never). Position and rotation are written through
//     the Node3D API scripts use (the local transform, in place). A
//     binding or a key of the actor's position writes after the step, and
//     wins;
//   - current_speed, for every agent with an actor: the horizontal
//     distance its actor went since the last step over the time it took
//     (whoever moved it: drive_parent, a script, a timeline): the step's
//     seconds with drive_parent (the step is at most NAV_MAX_STEP, and
//     drive_parent moved it by that), else the frame's; 0 at the
//     first step. distance_to_target: from the actor where the step left
//     it;
//   - step 7: waypoint_reached and link_reached carry Godot's details as
//     the event's fields (AnimaScript has no Dictionary): `position` the
//     waypoint as the path holds it, `shapeIndex` its index in the path,
//     `node` its owner (the region or the link; null without the owners
//     metadata flag).
//
// Memory: the agents, their slots (the query's parameters and result, the
// six events) and the job's lists are made again only when the tree's
// structure changes; the arrays keep their storage; a step allocates
// nothing once the paths have grown to their longest.

import { MAT4_IDENTITY, Mat3, Mat4, Vec3 } from "../../base/vecmath";
import { Job, MAX_JOB_WORKERS, jobs } from "../../base/jobs";
import { Value } from "../value";
import { NavigationAgent3D, NavigationObstacle3D, SceneNode, treeStructureEpoch } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { inOwnWorld } from "../tree/viewports";
import { SignalEvent } from "../runtime/signals";
import { NavigationMap, NavigationPathQueryParameters3D, NavigationPathQueryResult3D, NavigationQueryScratch } from "./api";
import { NAV_AGENT_PATH_ROOM, NavAgentState } from "./agent_state";
import { aimIndex, crossingLink, driveVelocity, installAgentLogic } from "./agent";
import { AvoidanceWorld } from "./avoidance";
import { NavMap } from "./map";
import { NavGraph } from "./astar";
import { NavigationSettings } from "./settings";

// What one step came to (the status's counts, the tools' answers).
export class NavigationStepStats {
    agents: i32 = 0;
    // Agents with a path they are following, and those whose target is
    // reached.
    moving: i32 = 0;
    reached: i32 = 0;
    avoiding: i32 = 0;
    obstacles: i32 = 0;
    // Path queries run this step, and those answered from an agent's kept
    // path or the map's cache.
    queries: i32 = 0;
    cached: i32 = 0;
    signals: i32 = 0;

    reset(): void {
        this.agents = 0;
        this.moving = 0;
        this.reached = 0;
        this.avoiding = 0;
        this.obstacles = 0;
        this.queries = 0;
        this.cached = 0;
        this.signals = 0;
    }
}

// The least horizontal distance (m) between a held actor and the map's
// closest point for which the actor is taken back onto the polygons: under
// it the actor is on them (the closest point is itself, give or take the
// floats).
const HOLD_EPSILON: f32 = 1e-4;
const DEG_TO_RAD: f32 = <f32>(Math.PI / 180.0);
const PI: f32 = <f32>Math.PI;
const TWO_PI: f32 = <f32>(Math.PI * 2.0);

// How far (radians) drive_parent turns the velocity an avoiding agent
// wants to its right before the avoidance sees it (Hedra's). RVO2 cannot
// choose a side when the way is exactly symmetric (an agent heading
// straight for the centre of a radius obstacle, two agents mirror images
// of each other about it): each is slowed along its own line and stops
// against the obstacle. RVO2's own examples perturb the preferred
// velocities by a hair for that (its Blocks example: 0.0001 m/s, at
// random); Hedra turns them, the same way for every agent and step, so
// that the run stays deterministic and agents that meet pass on the
// right. 0.001 rad moves an agent 1 mm sideways a metre: nothing a
// picture shows, enough to fall off the balance. A script's velocity is
// left as it is (Godot's).
const KEEP_RIGHT_COS: f32 = <f32>Math.cos(0.001);
const KEEP_RIGHT_SIN: f32 = <f32>Math.sin(0.001);

// (x, 0, z) turned 0.001 rad about Y to its right (Godot's -Z forward,
// +X its right).
function keepRight(x: f32, z: f32): Vec3 {
    return Vec3(x * KEEP_RIGHT_COS - z * KEEP_RIGHT_SIN, 0, z * KEEP_RIGHT_COS + x * KEEP_RIGHT_SIN);
}

// `r`'s arrays given room for `n` points (their storage kept, emptied): the
// map fills them by pushing (see agent_state.as NAV_AGENT_PATH_ROOM).
function reserveResult(r: NavigationPathQueryResult3D, n: i32): void {
    for (let i = r.path.length; i < n; i++) r.path.push(Vec3(0, 0, 0));
    for (let i = r.pathTypes.length; i < n; i++) r.pathTypes.push(0);
    for (let i = r.pathOwners.length; i < n; i++) r.pathOwners.push(null);
    for (let i = r.pathOwnerIds.length; i < n; i++) r.pathOwnerIds.push(0);
    r.reset();
}

// Whether `m` is the identity, number for number.
function isIdentity(m: Mat4): bool {
    return m.xAxis.x == 1 && m.xAxis.y == 0 && m.xAxis.z == 0 && m.yAxis.x == 0 && m.yAxis.y == 1 && m.yAxis.z == 0
        && m.zAxis.x == 0 && m.zAxis.y == 0 && m.zAxis.z == 1 && m.wAxis.x == 0 && m.wAxis.y == 0 && m.wAxis.z == 0;
}

// The y polygonYAt found (a module global: the step runs on the main
// lane alone).
let heldY: f64 = 0;

// Whether (x, z) lies over polygon `k` of `gr` seen from above (its
// corners in either winding, convex; a centimetre's hundredth given at
// its edges).
function onPolygon(gr: NavGraph, k: i32, x: f32, z: f32): bool {
    const a = unchecked(gr.cornerStart[k]);
    const b = unchecked(gr.cornerStart[k + 1]);
    const px = gr.px;
    const pz = gr.pz;
    let pos = false;
    let neg = false;
    const fx = <f64>x;
    const fz = <f64>z;
    for (let c = a; c < b; c++) {
        const n = c + 1 < b ? c + 1 : a;
        const ex = unchecked(px[n]) - unchecked(px[c]);
        const ez = unchecked(pz[n]) - unchecked(pz[c]);
        const cross = ex * (fz - unchecked(pz[c])) - ez * (fx - unchecked(px[c]));
        // (the cross product over the edge's length: the distance off its
        // line, signed by the side)
        const len = Math.sqrt(ex * ex + ez * ez);
        if (len == 0) continue;
        const side = cross / len;
        if (side > HOLD_EPSILON) pos = true;
        else if (side < -HOLD_EPSILON) neg = true;
        if (pos && neg) return false;
    }
    return true;
}

// The height of polygon `k`'s plane (its up through its first corner) at
// (x, z) into heldY; false for a polygon standing too steeply for one.
function polygonYAt(gr: NavGraph, k: i32, x: f32, z: f32): bool {
    const up = gr.polyUp;
    const ux = unchecked(up[k * 3]);
    const uy = unchecked(up[k * 3 + 1]);
    const uz = unchecked(up[k * 3 + 2]);
    if (!(uy > 0.05)) return false;
    const c = unchecked(gr.cornerStart[k]);
    heldY = unchecked(gr.py[c]) - (ux * (<f64>x - unchecked(gr.px[c])) + uz * (<f64>z - unchecked(gr.pz[c]))) / uy;
    return true;
}

// What the step keeps of one agent: the query it asks and its answer (its
// own, so the job's units write only their own), and its six events.
// The longest a step may be, in seconds: Godot's physics steps the
// navigation 60 times a second and at most 8 times a frame (0.133 s); the
// particles' cap (PARTICLE_MAX_DELTA) is the same 0.1 s.
export const NAV_MAX_STEP: f64 = 0.1;

export class AgentSlot {
    agent: NavigationAgent3D;
    params: NavigationPathQueryParameters3D = new NavigationPathQueryParameters3D();
    result: NavigationPathQueryResult3D = new NavigationPathQueryResult3D();
    // The map polygon drive_parent last held the actor to, and the map's
    // iteration it is of (-1: none).
    holdPolygon: i32 = -1;
    holdIteration: i32 = -1;
    velocityComputed: SignalEvent;
    // The safe velocity velocity_computed last carried (a change of the
    // scene only when it is another).
    lastSafeVelocity: Vec3 = Vec3(0, 0, 0);
    safeEmitted: bool = false;
    pathChanged: SignalEvent;
    waypointReached: SignalEvent;
    linkReached: SignalEvent;
    targetReached: SignalEvent;
    navigationFinished: SignalEvent;

    // What the step kept, forgotten (the slot as a new one's: its storage
    // and its events kept).
    restart(): void {
        this.holdPolygon = -1;
        this.holdIteration = -1;
        this.lastSafeVelocity = Vec3(0, 0, 0);
        this.safeEmitted = false;
    }

    constructor(agent: NavigationAgent3D, from: string) {
        this.agent = agent;
        reserveResult(this.result, NAV_AGENT_PATH_ROOM);
        this.velocityComputed = new SignalEvent(from, "velocity_computed", Value.nil());
        this.pathChanged = new SignalEvent(from, "path_changed", Value.nil());
        this.waypointReached = new SignalEvent(from, "waypoint_reached", Value.nil());
        this.linkReached = new SignalEvent(from, "link_reached", Value.nil());
        this.targetReached = new SignalEvent(from, "target_reached", Value.nil());
        this.navigationFinished = new SignalEvent(from, "navigation_finished", Value.nil());
    }
}

// The step's path queries as one job: a unit an agent, each in its
// worker's scratch, each writing its own agent's result (never on lanes:
// the map would have to cross to them).
export class PathQueryJob extends Job {
    map: NavigationMap = new NavigationMap();
    slots: Array<AgentSlot> = [];
    need: Array<i32> = [];
    scratch: Array<NavigationQueryScratch> = [];
    // The map and polygon count the scratch was made for.
    private scratchMap: NavigationMap? = null;
    private scratchPolygons: i32 = -1;

    // A scratch a worker for `map` (made again when the map grew past what
    // they were made for, or for another map: before the run, never in it).
    prepare(map: NavMap): void {
        const lanes = jobs().startsLanes();
        let workers = lanes ? 1 : jobs().workers();
        if (workers > MAX_JOB_WORKERS) workers = MAX_JOB_WORKERS;
        const polygons = map.stats().polygons;
        if (this.scratchMap !== map || polygons > this.scratchPolygons) {
            this.scratch.length = 0;
            this.scratchMap = map;
            this.scratchPolygons = polygons;
        }
        while (this.scratch.length < workers) this.scratch.push(map.newScratch());
        this.map = map;
    }

    runUnit(unit: i32, begin: i32, end: i32, worker: i32): void {
        const map = this.map;
        const sc = unchecked(this.scratch[worker < this.scratch.length ? worker : 0]);
        for (let i = begin; i < end; i++) {
            const slot = unchecked(this.slots[unchecked(this.need[i])]);
            map.queryPathIn(sc, slot.params, slot.result);
        }
    }
}

export class NavigationSim {
    map: NavMap;
    stats: NavigationStepStats = new NavigationStepStats();
    // The tree's agents and obstacles (the main world's, in tree order) as
    // of the last structure change, and the agents' slots.
    agents: Array<NavigationAgent3D> = [];
    obstacles: Array<NavigationObstacle3D> = [];
    slots: Array<AgentSlot> = [];
    // The avoidance's snapshot and job.
    avoidance: AvoidanceWorld = new AvoidanceWorld();
    private queryJob: PathQueryJob = new PathQueryJob();
    private avoiding: Array<NavigationAgent3D> = [];
    private avoidingSlot: Array<i32> = [];
    private walked: Array<SceneNode> = [];
    private stack: Array<SceneNode> = [];
    private oldSlots: Array<AgentSlot> = [];
    private epoch: i32 = -1;
    private tree: SceneTree? = null;

    constructor(settings: NavigationSettings? = null) {
        this.map = new NavMap(settings);
    }

    // One step of `seconds` over `tree` (see the header); whether anything
    // a frame draws or a binding reads changed.
    step(tree: SceneTree, seconds: f64): bool {
        const st = this.stats;
        st.reset();
        this.find(tree);
        const map = this.map;
        map.sync(tree);
        const logic = installAgentLogic();
        logic.map = map;
        const agents = this.agents;
        const slots = this.slots;
        const n = agents.length;
        st.agents = n;
        st.obstacles = this.obstacles.length;
        if (!(seconds > 0) || n == 0) {
            this.count();
            return false;
        }
        // (a frame longer than NAV_MAX_STEP counts as that long: a stalled
        // host, or the first frame after a scene that went idle, whose
        // length is the whole wait, would otherwise throw the walkers
        // metres in one step, past their waypoints and through the
        // avoidance)
        const step = seconds < NAV_MAX_STEP ? seconds : NAV_MAX_STEP;
        const dt = <f32>step;
        let changed = false;

        // 2. the paths: the queries of the step as one job, then each agent
        // in tree order
        const job = this.queryJob;
        const need = job.need;
        need.length = 0;
        for (let i = 0; i < n; i++) {
            const a = unchecked(agents[i]);
            const s = a.nav;
            if (logic.needsPath(a, s, map)) {
                logic.fillQuery(a, map, unchecked(slots[i]).params);
                need.push(i);
            } else if (s.targetSubmitted && s.path.length > 0) {
                st.cached++;
            }
        }
        if (need.length > 0) {
            job.slots = slots;
            job.prepare(map);
            jobs().run(job, need.length, 1);
            const iteration = map.iterationId();
            for (let k = 0; k < need.length; k++) {
                const i = unchecked(need[k]);
                const a = unchecked(agents[i]);
                logic.takePath(a, a.nav, unchecked(slots[i]).result, iteration);
            }
            st.queries = need.length;
        }
        for (let i = 0; i < n; i++) {
            const a = unchecked(agents[i]);
            logic.follow(a, a.nav);
        }

        // 3. the velocities wanted, and what reaches the avoidance
        const avoiding = this.avoiding;
        const avoidingSlot = this.avoidingSlot;
        avoiding.length = 0;
        avoidingSlot.length = 0;
        for (let i = 0; i < n; i++) {
            const a = unchecked(agents[i]);
            const s = a.nav;
            const actor = a.actor();
            if (actor == null) continue;
            if (a.driveParent) {
                s.desiredVelocity = driveVelocity(a, s, actor.globalPosition);
                s.velocitySubmitted = true;
            }
            if (a.avoidanceEnabled) {
                if (s.velocitySubmitted) {
                    const v = s.desiredVelocity;
                    if (a.keepYVelocity) s.storedYVelocity = v.y;
                    s.preferredVelocity = a.driveParent ? keepRight(v.x, v.z) : Vec3(v.x, 0, v.z);
                }
                avoiding.push(a);
                avoidingSlot.push(i);
            } else {
                s.safeVelocity = s.desiredVelocity;
            }
            s.velocitySubmitted = false;
        }
        st.avoiding = avoiding.length;

        // 4. the avoidance
        if (avoiding.length > 0) {
            const world = this.avoidance;
            world.prepare(avoiding, this.obstacles);
            world.computeInto(step);
            for (let k = 0; k < avoiding.length; k++) {
                const a = unchecked(avoiding[k]);
                const s = a.nav;
                let x = world.velocityX(k);
                let z = world.velocityZ(k);
                s.avoidanceVelocity = Vec3(x, 0, z);
                // (Godot's limit_length to max_speed: divided by the length,
                // times the speed)
                const l = Mathf.sqrt(x * x + z * z);
                const m = a.maxSpeed;
                if (l > 0 && m < l) {
                    x = x / l * m;
                    z = z / l * m;
                }
                s.safeVelocity = Vec3(x, s.storedYVelocity, z);
            }
        }

        // 5. velocity_computed, in tree order
        for (let k = 0; k < avoiding.length; k++) {
            const a = unchecked(avoiding[k]);
            if (a.freed) continue;
            const slot = unchecked(slots[unchecked(avoidingSlot[k])]);
            const ev = slot.velocityComputed;
            const v = a.nav.safeVelocity;
            ev.position = v;
            // (emitted each step, as Godot's, but quietly, and a change only
            // when the velocity is another: a crowd that stopped lets the
            // scene go idle)
            tree.emitEvent(a, ev, true);
            st.signals++;
            const was = slot.lastSafeVelocity;
            if (!slot.safeEmitted || v.x != was.x || v.y != was.y || v.z != was.z) {
                slot.lastSafeVelocity = v;
                slot.safeEmitted = true;
                changed = true;
            }
        }

        // 6. drive_parent's moves, current_speed and distance_to_target
        const hold = map.stats().polygons > 0;
        for (let i = 0; i < n; i++) {
            const a = unchecked(agents[i]);
            if (a.freed) continue;
            const s = a.nav;
            const actor = a.actor();
            if (actor == null) {
                if (a.currentSpeed != 0) changed = true;
                a.currentSpeed = 0;
                s.distanceToTarget = 0;
                continue;
            }
            if (a.driveParent && this.drive(a, s, unchecked(slots[i]), actor, dt, hold)) changed = true;
            const p = actor.globalPosition;
            let speed: f32 = 0;
            if (s.hasLastPosition) {
                const dx = p.x - s.lastActorPosition.x;
                const dz = p.z - s.lastActorPosition.z;
                // (over the time the move took: drive_parent's over the
                // step, which it moved by; anyone else's, a script's or a
                // timeline's, over the whole frame, which may be longer
                // than NAV_MAX_STEP)
                speed = Mathf.sqrt(dx * dx + dz * dz) / (a.driveParent ? dt : <f32>seconds);
            }
            s.lastActorPosition = p;
            s.hasLastPosition = true;
            if (speed != a.currentSpeed) changed = true;
            a.currentSpeed = speed;
            const d = p.distance(a.targetPosition);
            if (d != s.distanceToTarget) changed = true;
            s.distanceToTarget = d;
        }

        // 7. the signals owed, in tree order
        for (let i = 0; i < n; i++) {
            const a = unchecked(agents[i]);
            if (a.freed) continue;
            if (this.emitOwed(tree, a, unchecked(slots[i]))) changed = true;
        }
        this.count();
        return changed;
    }

    // Forgets every agent's state (a tree loaded again): each starts again
    // as loaded, its target submitted when its file set one.
    // The slots are kept, each as a new one's, for find() to take again
    // (the tools' clock resets on every run: the editor's scrubbing would
    // otherwise make a slot, about 3 KB, for every agent each time).
    reset(): void {
        for (let i = 0; i < this.agents.length; i++) {
            const a = unchecked(this.agents[i]);
            a.nav.restart(a.getProp("target_position") != null);
            a.currentSpeed = 0;
        }
        for (let i = 0; i < this.slots.length; i++) unchecked(this.slots[i]).restart();
        this.agents.length = 0;
        this.obstacles.length = 0;
        this.epoch = -1;
        this.tree = null;
    }

    // The slot of `a` (null when the last search did not find it).
    slotOf(a: NavigationAgent3D): AgentSlot? {
        for (let i = 0; i < this.agents.length; i++) if (unchecked(this.agents[i]) === a) return unchecked(this.slots[i]);
        return null;
    }

    // The status's counts and the tools' (moving, reached) into stats.
    private count(): void {
        const st = this.stats;
        let moving = 0;
        let reached = 0;
        for (let i = 0; i < this.agents.length; i++) {
            const s = unchecked(this.agents[i]).nav;
            if (s.targetSubmitted && !s.navigationFinished && s.path.length > 0) moving++;
            if (s.targetReached) reached++;
        }
        st.moving = moving;
        st.reached = reached;
    }

    // The agents and obstacles of `tree`, again when its structure moved
    // (or another tree).
    private find(tree: SceneTree): void {
        const e = treeStructureEpoch();
        if (e == this.epoch && this.tree === tree) return;
        this.epoch = e;
        this.tree = tree;
        tree.walkInto(this.walked, this.stack);
        const old = this.oldSlots;
        old.length = 0;
        for (let i = 0; i < this.slots.length; i++) old.push(unchecked(this.slots[i]));
        this.agents.length = 0;
        this.obstacles.length = 0;
        this.slots.length = 0;
        const walked = this.walked;
        for (let i = 0; i < walked.length; i++) {
            const nd = unchecked(walked[i]);
            const isAgent = nd instanceof NavigationAgent3D;
            const isObstacle = nd instanceof NavigationObstacle3D;
            if (!isAgent && !isObstacle) continue;
            if (inOwnWorld(nd)) continue;
            if (isObstacle) {
                this.obstacles.push(nd as NavigationObstacle3D);
                continue;
            }
            const a = nd as NavigationAgent3D;
            this.agents.push(a);
            let slot: AgentSlot? = null;
            for (let k = 0; k < old.length; k++) {
                if (unchecked(old[k]).agent === a) {
                    slot = unchecked(old[k]);
                    break;
                }
            }
            this.slots.push(slot != null ? slot : new AgentSlot(a, a.pathFrom(tree.root)));
        }
        old.length = 0;
    }

    // drive_parent's move of `actor` over `dt` (see the header); whether
    // it moved or turned.
    private drive(a: NavigationAgent3D, s: NavAgentState, slot: AgentSlot, actor: SceneNode, dt: f32, hold: bool): bool {
        const g = actor.globalPosition;
        const link = crossingLink(s);
        const v = a.avoidanceEnabled ? s.safeVelocity : s.desiredVelocity;
        let dx = v.x * dt;
        let dz = v.z * dt;
        let dy: f32 = link ? s.desiredVelocity.y * dt : 0;
        if (dx == 0 && dz == 0 && dy == 0) return false;
        // (no farther than the point it heads for: its speed at most the
        // distance left over the step. A step longer than
        // path_desired_distance would otherwise go over a corner, aim back
        // at it and go over it again, for ever)
        if (s.targetSubmitted && !s.navigationFinished && s.path.length > 0) {
            const ap = unchecked(s.path[aimIndex(s)]);
            const ax = ap.x - g.x;
            const ay: f32 = link ? ap.y - a.pathHeightOffset - g.y : 0;
            const az = ap.z - g.z;
            const left = Mathf.sqrt(ax * ax + ay * ay + az * az);
            const l = Mathf.sqrt(dx * dx + dy * dy + dz * dz);
            if (l > left) {
                const k = left / l;
                dx = dx * k;
                dy = dy * k;
                dz = dz * k;
            }
        }
        let nx = g.x + dx;
        let ny = g.y + dy;
        let nz = g.z + dz;
        if (hold && !link) {
            const gr = this.map.graph;
            const k = slot.holdPolygon;
            if (slot.holdIteration == this.map.iterationId() && k >= 0 && k < gr.polyCount && onPolygon(gr, k, nx, nz)
                && polygonYAt(gr, k, nx, nz)) {
                // (still over the polygon it was on: dropped onto it)
                ny = <f32>heldY - a.pathHeightOffset;
            } else {
                let c: Vec3;
                // (asked from where the actor stands in the mesh's height:
                // a baked mesh floats above its floor, at the cell's top,
                // and path_height_offset brings the actor down to it, so
                // the actor's own height would find the floor's polygon
                // under the foot of a ramp rather than the ramp's)
                const my = ny + a.pathHeightOffset;
                if (gr.polyCount > 0) {
                    const at = this.map.closestPolygon(Vec3(nx, my, nz));
                    const sc = this.map.ownScratch();
                    c = at >= 0 ? Vec3(<f32>sc.cpX, <f32>sc.cpY, <f32>sc.cpZ) : Vec3(nx, ny, nz);
                    slot.holdPolygon = at;
                    slot.holdIteration = this.map.iterationId();
                } else {
                    // (a map of another kind: its own closest point)
                    c = this.map.getClosestPoint(Vec3(nx, my, nz));
                }
                const hx = c.x - nx;
                const hz = c.z - nz;
                if (hx * hx + hz * hz > HOLD_EPSILON * HOLD_EPSILON) {
                    nx = c.x;
                    nz = c.z;
                }
                ny = c.y - a.pathHeightOffset;
            }
        }
        const p = actor.parent;
        // (the parent's space: none to go into under the scene's root, or
        // under any node placed at the origin unturned, the usual case)
        const pg = p != null && p.is3d ? p.global() : MAT4_IDENTITY;
        const placed = !isIdentity(pg);
        const inv = placed ? pg.inverse() : MAT4_IDENTITY;
        const target = Vec3(nx, ny, nz);
        actor.setPosition(placed ? inv.transformPoint3(target) : target);
        // (the turn, towards the motion seen in the parent's space)
        const turn = a.driveTurnSpeed;
        const mx = nx - g.x;
        const mz = nz - g.z;
        if (turn != 0 && mx * mx + mz * mz > 1e-12) {
            const d = placed ? inv.transformVector3(Vec3(mx, 0, mz)) : Vec3(mx, 0, mz);
            const want = Mathf.atan2(-d.x, -d.z);
            const m = actor.local;
            // (the yaw of a basis Godot's YXZ order turns: its Z axis's
            // heading, one atan2; a mirrored basis through its Euler angles)
            const mirrored = Mat3.fromMat4(m).determinant() < 0;
            const yaw = mirrored ? actor.rotation.y : Mathf.atan2(m.zAxis.x, m.zAxis.z);
            let delta = want - yaw;
            delta = delta - TWO_PI * Mathf.floor((delta + PI) / TWO_PI);
            const most = Mathf.abs(turn) * DEG_TO_RAD * dt;
            if (delta > most) delta = most;
            else if (delta < -most) delta = -most;
            if (delta != 0) {
                // (about the parent's Y, the turn's alone: Godot's rotate_y)
                if (mirrored) {
                    const r = actor.rotation;
                    actor.setRotation(Vec3(r.x, r.y + delta, r.z));
                } else {
                    actor.rotateY(delta);
                }
            }
        }
        return true;
    }

    // The signals `a` owes (see the header), emitted; whether there were.
    private emitOwed(tree: SceneTree, a: NavigationAgent3D, slot: AgentSlot): bool {
        const s = a.nav;
        let any = false;
        const st = this.stats;
        if (s.pathChangedPending) {
            s.pathChangedPending = false;
            tree.emitEvent(a, slot.pathChanged);
            st.signals++;
            any = true;
        }
        const points = s.pendingWaypoints;
        if (points.length > 0) {
            for (let k = 0; k < points.length; k++) {
                const ev = slot.waypointReached;
                ev.position = unchecked(points[k]);
                ev.shapeIndex = unchecked(s.pendingWaypointIndex[k]);
                ev.node = unchecked(s.pendingWaypointOwner[k]);
                tree.emitEvent(a, ev);
                st.signals++;
                if (unchecked(s.pendingWaypointLink[k])) {
                    const lv = slot.linkReached;
                    lv.position = ev.position;
                    lv.shapeIndex = ev.shapeIndex;
                    lv.node = ev.node;
                    tree.emitEvent(a, lv);
                    st.signals++;
                }
            }
            points.length = 0;
            s.pendingWaypointIndex.length = 0;
            s.pendingWaypointLink.length = 0;
            s.pendingWaypointOwner.length = 0;
            s.waypointPending = -1;
            s.linkPending = -1;
            any = true;
        }
        if (s.targetReachedPending) {
            s.targetReachedPending = false;
            tree.emitEvent(a, slot.targetReached);
            st.signals++;
            any = true;
        }
        if (s.finishedPending) {
            s.finishedPending = false;
            tree.emitEvent(a, slot.navigationFinished);
            st.signals++;
            any = true;
        }
        return any;
    }
}
