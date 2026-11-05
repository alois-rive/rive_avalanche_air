// Derived from RVO2 (Apache-2.0), as Godot Engine 4.4 vendors it, and Godot 4.4 (MIT); see THIRD_PARTY_NOTICES.md.
//
// The agents' avoidance (milestone 63, docs/engine/NAVIGATION.md
// "Avoidance"): Godot 4.4's 2D avoidance, RVO2's ORCA (thirdparty/rvo2/
// rvo2_2d: Agent2D::computeNeighbors, computeNewVelocity, the three linear
// programs), on the ground plane (x, z), ported line for line in f32 with
// RVO2's order of operations, so that its numbers are RVO2's (the tests
// hold three hand cases to RVO2's own, compiled from Godot's copy).
//
// Who takes part, as Godot's map step (modules/navigation/nav_map.cpp) and
// its NavAgent and NavObstacle set them up:
//   - every NavigationAgent3D with avoidance_enabled and a 3D parent: its
//     parent's global position (y its elevation), radius, height,
//     neighbor_distance, max_neighbors, time_horizon_agents,
//     time_horizon_obstacles, max_speed, avoidance_layers, avoidance_mask
//     and avoidance_priority; the preferred velocity it was given and its
//     own velocity, the last step's new one (RVO2's velocity_);
//   - every NavigationObstacle3D with avoidance_enabled and a radius above
//     0, as an agent that avoids nothing (Godot's obstacle agent: no
//     neighbour, mask 0, priority 1) moving at its `velocity` (Hedra's:
//     Godot clamps it to its agent's default max_speed of 1 m/s), its
//     radius times its largest global scale, its height times its global y
//     scale; Godot also makes a point agent of an obstacle of radius 0,
//     which Hedra does not;
//   - every NavigationObstacle3D with avoidance_enabled and at least two
//     vertices, as RVO2's static obstacle: its outline's segments, each
//     vertex scaled by the global scale's size and turned by the global
//     rotation about Y (Godot's safe transform), then moved by its global
//     position, a segment from each vertex to the next (the last to the
//     first), each vertex convex when its neighbours turn left (RVO2's
//     leftOf >= 0; two vertices: both convex), at the obstacle's global
//     elevation and its height times its y scale. The winding is RVO2's:
//     an outline listed counter-clockwise on the (x, z) plane, x right and
//     z up (a square (-1, -1), (1, -1), (1, 1), (-1, 1)), keeps agents out;
//     the other way keeps them in. Godot 4.4 keeps the outline even with
//     avoidance_enabled off; Hedra leaves it out then.
//
// The rules of a neighbour, RVO2's as Godot changed them: an agent avoids
// another (or a radius obstacle) only when its avoidance_mask holds one of
// the other's avoidance_layers, when their spans [y, y + height] overlap,
// and when its own priority is not above the other's (Godot's rule: an
// agent leaves a lower-priority one to avoid it; equal or higher, it takes
// its usual half of the avoidance: Godot 4.4 has no weighting by priority,
// the lines doing it are commented out in its Agent2D), within
// neighbor_distance, the max_neighbors nearest (ties to the lower index,
// the agents' tree order then the obstacles'); an outline segment only
// when the mask holds the obstacle's layers, the spans overlap, the agent
// is on its outer side (RVO2's kd-tree test: strictly right of it) and
// within time_horizon_obstacles x max_speed + radius of it, nearest first
// (ties to the lower segment). RVO2's kd-trees are searched here in full,
// one candidate after another (the same neighbours; Godot's tree may split
// a segment it straddles in two, which gives the same constraint).
//
// Deterministic: every agent's new velocity is computed from a snapshot of
// every agent's and obstacle's numbers taken before the run (jobs.as rule
// 4), so the order agents are computed in does not matter (Godot's threads
// read velocities other agents of the step may have written already:
// Hedra's answer is that of RVO2's own simulator, which reads the last
// step's). The snapshot is one buffer of 32 bit words (the header, the
// agents' records, the segments'), which a lane reads as it is
// (AvoidanceJob, a LaneJob: render/lanes.as avoidanceLane), so a lane runs
// the same code on the same numbers and its velocities are bit for bit the
// main lane's. A velocity that comes out not finite (a time horizon of 0
// meeting an obstacle exactly at its end) is 0 (Hedra's: RVO2 would carry
// the NaN on).
//
// Memory: the buffer, the outputs and each worker's scratch (the ORCA
// lines and the neighbours) grow to the most a step needed and are kept,
// so a step allocates nothing once grown.

import { Mat4, Vec3, Vec4 } from "../../base/vecmath";
import {
    LANE_AVOIDANCE, LaneJob, LaneResult, LaneResultWriter, MAX_JOB_WORKERS, UnitClaims, jobs, unitBegin, unitEnd,
} from "../../base/jobs";
import { eulerYXZFromBasis, rotationOf, signedScale } from "../tree/xform";
import { NavigationAgent3D, NavigationObstacle3D } from "../tree/node";

// RVO2's RVO_EPSILON.
const RVO_EPSILON: f32 = 0.00001;
// Godot's least scale of an obstacle on an axis (maxf(0.001)).
const OBSTACLE_MIN_SCALE: f32 = 0.001;

// Agents a unit of the avoidance's job computes.
export const AVOIDANCE_GRAIN: i32 = 16;
// The fewest (agent, candidate neighbour) pairs a step tests for which the
// avoidance runs on lanes: below it a lane's start and the copies cost
// more than the agents save (docs/engine/JOBS.md, the measurements: on
// the stub runtime's pool, 24 agents (600 pairs) gained a sixth on one
// lane, 146 µs serial and 124 µs, unoptimised; optimised, 48 agents
// (2,352 pairs) went from 277 to 178 µs on two lanes, 128 agents from
// 1,289 to 483 µs on six). 2,048 pairs is about 45 agents with no
// obstacles: three units of 16, two of them a lane's.
export const AVOIDANCE_LANE_PAIRS: i32 = 2048;

// The snapshot's header (words).
const H_AGENTS = 0;
const H_NEIGHBOURS = 1;
const H_SEGMENTS = 2;
const H_STEP = 3;
const H_WORDS = 4;
// An agent's record (an agent computed, or a radius obstacle), in words.
const A_PX = 0;
const A_PZ = 1;
const A_ELEV = 2;
const A_HEIGHT = 3;
const A_RADIUS = 4;
const A_VX = 5;
const A_VZ = 6;
const A_PREFX = 7;
const A_PREFZ = 8;
const A_MAX_SPEED = 9;
const A_NEIGHBOR_DIST = 10;
const A_MAX_NEIGHBORS = 11; // int
const A_TIME_HORIZON = 12;
const A_TIME_HORIZON_OBST = 13;
const A_LAYERS = 14; // int
const A_MASK = 15; // int
const A_PRIORITY = 16;
const A_WORDS = 17;
// A segment's record (RVO2's Obstacle2D: its point, the next and previous
// of its outline, its unit direction, convexity, elevation, height and the
// obstacle's layers).
const S_PX = 0;
const S_PZ = 1;
const S_NEXT = 2; // int
const S_PREV = 3; // int
const S_DIRX = 4;
const S_DIRZ = 5;
const S_CONVEX = 6; // int
const S_ELEV = 7;
const S_HEIGHT = 8;
const S_LAYERS = 9; // int
const S_WORDS = 10;

@inline
function sqr(a: f32): f32 {
    return a * a;
}

@inline
function det(ax: f32, ay: f32, bx: f32, by: f32): f32 {
    return ax * by - ay * bx;
}

// What one agent's computation works in: its ORCA lines (point, then
// direction, four floats a line), the projected lines of the third linear
// program, its neighbours (distance squared, index), and the result.
export class AvoidScratch {
    lines: Float32Array = new Float32Array(0);
    proj: Float32Array = new Float32Array(0);
    nbDist: Float32Array = new Float32Array(0);
    nbIndex: Int32Array = new Int32Array(0);
    obDist: Float32Array = new Float32Array(0);
    obIndex: Int32Array = new Int32Array(0);
    // The linear programs' result (RVO2's `result` reference), and the
    // agent's last neighbours and lines (the first nbCount of nbIndex, the
    // first obCount of obIndex; `lineCount` lines, the obstacles' first).
    rx: f32 = 0;
    ry: f32 = 0;
    nbCount: i32 = 0;
    obCount: i32 = 0;
    lineCount: i32 = 0;

    // Room for `lines` lines, `neighbours` agent neighbours and `segments`
    // obstacle neighbours.
    ensure(lines: i32, neighbours: i32, segments: i32): void {
        if (this.lines.length < lines * 4) {
            this.lines = new Float32Array(lines * 4);
            this.proj = new Float32Array(lines * 4);
        }
        if (this.nbDist.length < neighbours) {
            this.nbDist = new Float32Array(neighbours);
            this.nbIndex = new Int32Array(neighbours);
        }
        if (this.obDist.length < segments) {
            this.obDist = new Float32Array(segments);
            this.obIndex = new Int32Array(segments);
        }
    }
}

export class AvoidanceWorld {
    // The snapshot (see the header): its words, as floats and as ints.
    words: ArrayBuffer = new ArrayBuffer(0);
    f: Float32Array = new Float32Array(0);
    w: Int32Array = new Int32Array(0);
    // Its bytes in use.
    bytes: i32 = 0;
    // The agents computed (the first records), with the radius obstacles
    // the records in all, and the outlines' segments.
    agents: i32 = 0;
    neighbours: i32 = 0;
    segments: i32 = 0;
    // Each computed agent's new velocity (x, z).
    out: Float32Array = new Float32Array(0);
    // The most lines and agent neighbours an agent of the snapshot may have.
    mostLines: i32 = 0;
    mostNeighbours: i32 = 0;
    private scratch: Array<AvoidScratch> = [];
    private job: AvoidanceJob? = null;

    agentAt(): i32 {
        return H_WORDS;
    }

    segmentAt(): i32 {
        return H_WORDS + this.neighbours * A_WORDS;
    }

    // The snapshot of `agents` (each with avoidance_enabled and a 3D
    // parent, in tree order) and `obstacles` (in tree order), before a run.
    prepare(agents: Array<NavigationAgent3D>, obstacles: Array<NavigationObstacle3D>): void {
        let radiusObstacles = 0;
        let segs = 0;
        for (let i = 0; i < obstacles.length; i++) {
            const o = unchecked(obstacles[i]);
            if (!o.avoidanceEnabled) continue;
            if (o.radius > 0) radiusObstacles++;
            const n = o.vertices.length / 3;
            if (n >= 2) segs += n;
        }
        const na = agents.length;
        const nn = na + radiusObstacles;
        const words = H_WORDS + nn * A_WORDS + segs * S_WORDS;
        this.reserve(words);
        this.agents = na;
        this.neighbours = nn;
        this.segments = segs;
        this.bytes = words * 4;
        const f = this.f;
        const w = this.w;
        unchecked(w[H_AGENTS] = na);
        unchecked(w[H_NEIGHBOURS] = nn);
        unchecked(w[H_SEGMENTS] = segs);
        let most = 0;
        let at = H_WORDS;
        for (let i = 0; i < na; i++) {
            const a = unchecked(agents[i]);
            const s = a.nav;
            const p = a.actorPosition();
            unchecked(f[at + A_PX] = p.x);
            unchecked(f[at + A_PZ] = p.z);
            unchecked(f[at + A_ELEV] = p.y);
            unchecked(f[at + A_HEIGHT] = a.height);
            unchecked(f[at + A_RADIUS] = a.radius);
            unchecked(f[at + A_VX] = s.avoidanceVelocity.x);
            unchecked(f[at + A_VZ] = s.avoidanceVelocity.z);
            unchecked(f[at + A_PREFX] = s.preferredVelocity.x);
            unchecked(f[at + A_PREFZ] = s.preferredVelocity.z);
            unchecked(f[at + A_MAX_SPEED] = a.maxSpeed);
            unchecked(f[at + A_NEIGHBOR_DIST] = a.neighborDistance);
            const m = a.maxNeighbors > 0 ? a.maxNeighbors : 0;
            if (m > most) most = m;
            unchecked(w[at + A_MAX_NEIGHBORS] = m);
            unchecked(f[at + A_TIME_HORIZON] = a.timeHorizonAgents);
            unchecked(f[at + A_TIME_HORIZON_OBST] = a.timeHorizonObstacles);
            unchecked(w[at + A_LAYERS] = <i32>a.avoidanceLayers);
            unchecked(w[at + A_MASK] = <i32>a.avoidanceMask);
            unchecked(f[at + A_PRIORITY] = a.avoidancePriority);
            at += A_WORDS;
        }
        let sat = H_WORDS + nn * A_WORDS;
        let seg = 0;
        for (let i = 0; i < obstacles.length; i++) {
            const o = unchecked(obstacles[i]);
            if (!o.avoidanceEnabled) continue;
            const g = o.global();
            const pos = g.wAxis.truncate();
            const sc = signedScale(g);
            const sx = absAtLeast(sc.x);
            const sy = absAtLeast(sc.y);
            const sz = absAtLeast(sc.z);
            if (o.radius > 0) {
                const big = sx > sy ? (sx > sz ? sx : sz) : (sy > sz ? sy : sz);
                unchecked(f[at + A_PX] = pos.x);
                unchecked(f[at + A_PZ] = pos.z);
                unchecked(f[at + A_ELEV] = pos.y);
                unchecked(f[at + A_HEIGHT] = o.height * sy);
                unchecked(f[at + A_RADIUS] = o.radius * big);
                unchecked(f[at + A_VX] = o.velocity.x);
                unchecked(f[at + A_VZ] = o.velocity.z);
                unchecked(f[at + A_PREFX] = o.velocity.x);
                unchecked(f[at + A_PREFZ] = o.velocity.z);
                unchecked(f[at + A_MAX_SPEED] = 0);
                unchecked(f[at + A_NEIGHBOR_DIST] = 0);
                unchecked(w[at + A_MAX_NEIGHBORS] = 0);
                unchecked(f[at + A_TIME_HORIZON] = 0);
                unchecked(f[at + A_TIME_HORIZON_OBST] = 0);
                unchecked(w[at + A_LAYERS] = <i32>o.avoidanceLayers);
                unchecked(w[at + A_MASK] = 0);
                unchecked(f[at + A_PRIORITY] = 1);
                at += A_WORDS;
            }
            const v = o.vertices;
            const n = v.length / 3;
            if (n < 2) continue;
            // (Godot's safe transform: the scale's size, then the turn
            // about Y, then the position)
            const yaw = eulerYXZFromBasis(rotationOf(g)).y;
            const c = Mathf.cos(yaw);
            const sn = Mathf.sin(yaw);
            const first = seg;
            for (let k = 0; k < n; k++) {
                const lx = unchecked(v[k * 3]) * sx;
                const lz = unchecked(v[k * 3 + 2]) * sz;
                // (R_y(yaw) * (x, 0, z): x' = x cos + z sin, z' = -x sin + z cos)
                const x = lx * c + lz * sn + pos.x;
                const z = -lx * sn + lz * c + pos.z;
                const r = sat + k * S_WORDS;
                unchecked(f[r + S_PX] = x);
                unchecked(f[r + S_PZ] = z);
                unchecked(w[r + S_NEXT] = first + (k + 1 < n ? k + 1 : 0));
                unchecked(w[r + S_PREV] = first + (k > 0 ? k - 1 : n - 1));
                unchecked(f[r + S_ELEV] = pos.y);
                unchecked(f[r + S_HEIGHT] = o.height * sy);
                unchecked(w[r + S_LAYERS] = <i32>o.avoidanceLayers);
            }
            for (let k = 0; k < n; k++) {
                const r = sat + k * S_WORDS;
                const nx = sat + (unchecked(w[r + S_NEXT]) - first) * S_WORDS;
                const px = sat + (unchecked(w[r + S_PREV]) - first) * S_WORDS;
                // (RVO2's normalize: times the length's inverse)
                const dx = unchecked(f[nx + S_PX]) - unchecked(f[r + S_PX]);
                const dz = unchecked(f[nx + S_PZ]) - unchecked(f[r + S_PZ]);
                const inv: f32 = 1.0 / Mathf.sqrt(dx * dx + dz * dz);
                unchecked(f[r + S_DIRX] = dx * inv);
                unchecked(f[r + S_DIRZ] = dz * inv);
                let convex = true;
                if (n > 2) {
                    // (leftOf(prev, this, next) = det(prev - next, this - prev))
                    const ax = unchecked(f[px + S_PX]) - unchecked(f[nx + S_PX]);
                    const az = unchecked(f[px + S_PZ]) - unchecked(f[nx + S_PZ]);
                    const bx = unchecked(f[r + S_PX]) - unchecked(f[px + S_PX]);
                    const bz = unchecked(f[r + S_PZ]) - unchecked(f[px + S_PZ]);
                    convex = det(ax, az, bx, bz) >= 0;
                }
                unchecked(w[r + S_CONVEX] = convex ? 1 : 0);
            }
            sat += n * S_WORDS;
            seg += n;
        }
        this.mostNeighbours = most;
        this.mostLines = most + segs;
        if (this.out.length < na * 2) this.out = new Float32Array(na * 2);
    }

    // The words for `words` of them at least (kept: grown only).
    private reserve(words: i32): void {
        if (this.f.length >= words) return;
        let n = this.f.length > 0 ? this.f.length : 256;
        while (n < words) n *= 2;
        this.words = new ArrayBuffer(n * 4);
        this.f = Float32Array.wrap(this.words);
        this.w = Int32Array.wrap(this.words);
    }

    // The snapshot of `words` (a lane's copy of what prepare wrote).
    static fromWords(words: ArrayBuffer): AvoidanceWorld {
        const a = new AvoidanceWorld();
        a.words = words;
        a.f = Float32Array.wrap(words);
        a.w = Int32Array.wrap(words);
        a.agents = unchecked(a.w[H_AGENTS]);
        a.neighbours = unchecked(a.w[H_NEIGHBOURS]);
        a.segments = unchecked(a.w[H_SEGMENTS]);
        a.bytes = (H_WORDS + a.neighbours * A_WORDS + a.segments * S_WORDS) * 4;
        let most = 0;
        for (let i = 0; i < a.agents; i++) {
            const m = unchecked(a.w[H_WORDS + i * A_WORDS + A_MAX_NEIGHBORS]);
            if (m > most) most = m;
        }
        a.mostNeighbours = most;
        a.mostLines = most + a.segments;
        a.out = new Float32Array(a.agents * 2);
        return a;
    }

    // A scratch big enough for this snapshot (a lane's own, or a test's).
    newScratch(): AvoidScratch {
        const s = new AvoidScratch();
        s.ensure(this.mostLines, this.mostNeighbours, this.segments);
        return s;
    }

    // Every agent's new velocity over a step of `seconds`, into `out`, as a
    // job on jobs() (AvoidanceJob: on lanes when it is worth them).
    computeInto(seconds: f64): void {
        unchecked(this.f[H_STEP] = <f32>seconds);
        if (this.agents == 0) return;
        const workers = jobs().workers();
        const need = workers < MAX_JOB_WORKERS ? workers : MAX_JOB_WORKERS;
        while (this.scratch.length < need) this.scratch.push(new AvoidScratch());
        for (let i = 0; i < need; i++) unchecked(this.scratch[i]).ensure(this.mostLines, this.mostNeighbours, this.segments);
        let job = this.job;
        if (job == null) {
            job = new AvoidanceJob(this);
            this.job = job;
        }
        jobs().run(job, this.agents, AVOIDANCE_GRAIN);
    }

    // The new velocity of computed agent `i`, as computeInto left it.
    velocityX(i: i32): f32 {
        return unchecked(this.out[i * 2]);
    }

    velocityZ(i: i32): f32 {
        return unchecked(this.out[i * 2 + 1]);
    }

    // Worker `worker`'s scratch (made by computeInto).
    scratchOf(worker: i32): AvoidScratch {
        return unchecked(this.scratch[worker < this.scratch.length ? worker : 0]);
    }

    // Agent `i`'s new velocity into `sc.rx`, `sc.ry` (RVO2's
    // computeNeighbors then computeNewVelocity; see the header).
    computeAgent(i: i32, sc: AvoidScratch): void {
        const f = this.f;
        const w = this.w;
        const at = H_WORDS + i * A_WORDS;
        const px = unchecked(f[at + A_PX]);
        const py = unchecked(f[at + A_PZ]);
        const elev = unchecked(f[at + A_ELEV]);
        const height = unchecked(f[at + A_HEIGHT]);
        const radius = unchecked(f[at + A_RADIUS]);
        const vx = unchecked(f[at + A_VX]);
        const vy = unchecked(f[at + A_VZ]);
        const maxSpeed = unchecked(f[at + A_MAX_SPEED]);
        const mask = unchecked(w[at + A_MASK]);
        const priority = unchecked(f[at + A_PRIORITY]);
        const maxNeighbors = unchecked(w[at + A_MAX_NEIGHBORS]);
        const timeHorizonObst = unchecked(f[at + A_TIME_HORIZON_OBST]);
        const sat = H_WORDS + this.neighbours * A_WORDS;

        // --- computeNeighbors: the obstacles' segments
        let obCount = 0;
        {
            const rangeSq = sqr(timeHorizonObst * maxSpeed + radius);
            const obDist = sc.obDist;
            const obIndex = sc.obIndex;
            for (let j = 0; j < this.segments; j++) {
                const r = sat + j * S_WORDS;
                const nr = sat + unchecked(w[r + S_NEXT]) * S_WORDS;
                if ((mask & unchecked(w[nr + S_LAYERS])) == 0) continue;
                const oe = unchecked(f[r + S_ELEV]);
                if (elev > oe + unchecked(f[r + S_HEIGHT]) || elev + height < oe) continue;
                const ax = unchecked(f[r + S_PX]);
                const ay = unchecked(f[r + S_PZ]);
                const bx = unchecked(f[nr + S_PX]);
                const by = unchecked(f[nr + S_PZ]);
                // (the kd-tree's test: leftOf(a, b, agent) = det(a - agent, b - a) < 0)
                const left = det(ax - px, ay - py, bx - ax, by - ay);
                if (!(left < 0)) continue;
                const d = distSqPointLineSegment(ax, ay, bx, by, px, py);
                if (!(d < rangeSq)) continue;
                let k = obCount;
                obCount++;
                while (k != 0 && d < unchecked(obDist[k - 1])) {
                    unchecked(obDist[k] = unchecked(obDist[k - 1]));
                    unchecked(obIndex[k] = unchecked(obIndex[k - 1]));
                    k--;
                }
                unchecked(obDist[k] = d);
                unchecked(obIndex[k] = j);
            }
        }
        // --- computeNeighbors: the agents
        let nbCount = 0;
        if (maxNeighbors > 0) {
            let rangeSq = sqr(unchecked(f[at + A_NEIGHBOR_DIST]));
            const nbDist = sc.nbDist;
            const nbIndex = sc.nbIndex;
            for (let k = 0; k < this.neighbours; k++) {
                if (k == i) continue;
                const o = H_WORDS + k * A_WORDS;
                if ((mask & unchecked(w[o + A_LAYERS])) == 0) continue;
                const oe = unchecked(f[o + A_ELEV]);
                if (elev > oe + unchecked(f[o + A_HEIGHT]) || elev + height < oe) continue;
                if (priority > unchecked(f[o + A_PRIORITY])) continue;
                const dx = px - unchecked(f[o + A_PX]);
                const dy = py - unchecked(f[o + A_PZ]);
                const distSq = dx * dx + dy * dy;
                if (distSq < rangeSq) {
                    if (nbCount < maxNeighbors) nbCount++;
                    let m = nbCount - 1;
                    while (m != 0 && distSq < unchecked(nbDist[m - 1])) {
                        unchecked(nbDist[m] = unchecked(nbDist[m - 1]));
                        unchecked(nbIndex[m] = unchecked(nbIndex[m - 1]));
                        m--;
                    }
                    unchecked(nbDist[m] = distSq);
                    unchecked(nbIndex[m] = k);
                    if (nbCount == maxNeighbors) rangeSq = unchecked(nbDist[nbCount - 1]);
                }
            }
        }

        // --- computeNewVelocity: the obstacles' ORCA lines
        const L = sc.lines;
        let lines = 0;
        const invTimeHorizonObst: f32 = <f32>1.0 / timeHorizonObst;
        const radiusSq = sqr(radius);
        for (let q = 0; q < obCount; q++) {
            let o1 = sat + unchecked(sc.obIndex[q]) * S_WORDS;
            let o2 = sat + unchecked(w[o1 + S_NEXT]) * S_WORDS;
            const r1x = unchecked(f[o1 + S_PX]) - px;
            const r1y = unchecked(f[o1 + S_PZ]) - py;
            const r2x = unchecked(f[o2 + S_PX]) - px;
            const r2y = unchecked(f[o2 + S_PZ]) - py;
            // (already covered by the lines made so far?)
            let covered = false;
            for (let j = 0; j < lines; j++) {
                const lpx = unchecked(L[j * 4]);
                const lpy = unchecked(L[j * 4 + 1]);
                const ldx = unchecked(L[j * 4 + 2]);
                const ldy = unchecked(L[j * 4 + 3]);
                if (det(invTimeHorizonObst * r1x - lpx, invTimeHorizonObst * r1y - lpy, ldx, ldy)
                    - invTimeHorizonObst * radius >= -RVO_EPSILON
                    && det(invTimeHorizonObst * r2x - lpx, invTimeHorizonObst * r2y - lpy, ldx, ldy)
                    - invTimeHorizonObst * radius >= -RVO_EPSILON) {
                    covered = true;
                    break;
                }
            }
            if (covered) continue;
            const distSq1 = r1x * r1x + r1y * r1y;
            const distSq2 = r2x * r2x + r2y * r2y;
            const ovx = unchecked(f[o2 + S_PX]) - unchecked(f[o1 + S_PX]);
            const ovy = unchecked(f[o2 + S_PZ]) - unchecked(f[o1 + S_PZ]);
            const s = (-r1x * ovx + -r1y * ovy) / (ovx * ovx + ovy * ovy);
            const lx = -r1x - s * ovx;
            const ly = -r1y - s * ovy;
            const distSqLine = lx * lx + ly * ly;
            const o1Convex = unchecked(w[o1 + S_CONVEX]) != 0;
            const o2Convex = unchecked(w[o2 + S_CONVEX]) != 0;
            if (s < 0 && distSq1 <= radiusSq) {
                // (collision with the left vertex; ignored if not convex)
                if (o1Convex) {
                    const inv: f32 = <f32>1.0 / Mathf.sqrt(r1y * r1y + r1x * r1x);
                    lines = putLine(L, lines, 0, 0, -r1y * inv, r1x * inv);
                }
                continue;
            } else if (s > 1 && distSq2 <= radiusSq) {
                // (collision with the right vertex; ignored if not convex or
                // if the next segment takes care of it)
                if (o2Convex && det(r2x, r2y, unchecked(f[o2 + S_DIRX]), unchecked(f[o2 + S_DIRZ])) >= 0) {
                    const inv: f32 = <f32>1.0 / Mathf.sqrt(r2y * r2y + r2x * r2x);
                    lines = putLine(L, lines, 0, 0, -r2y * inv, r2x * inv);
                }
                continue;
            } else if (s >= 0 && s < 1 && distSqLine <= radiusSq) {
                // (collision with the segment)
                lines = putLine(L, lines, 0, 0, -unchecked(f[o1 + S_DIRX]), -unchecked(f[o1 + S_DIRZ]));
                continue;
            }
            // (no collision: the legs; seen obliquely both come from one vertex)
            let llx: f32 = 0, lly: f32 = 0, rlx: f32 = 0, rly: f32 = 0;
            if (s < 0 && distSqLine <= radiusSq) {
                if (!o1Convex) continue;
                o2 = o1;
                const leg1 = Mathf.sqrt(distSq1 - radiusSq);
                const inv: f32 = <f32>1.0 / distSq1;
                llx = (r1x * leg1 - r1y * radius) * inv;
                lly = (r1x * radius + r1y * leg1) * inv;
                rlx = (r1x * leg1 + r1y * radius) * inv;
                rly = (-r1x * radius + r1y * leg1) * inv;
            } else if (s > 1 && distSqLine <= radiusSq) {
                if (!o2Convex) continue;
                o1 = o2;
                const leg2 = Mathf.sqrt(distSq2 - radiusSq);
                const inv: f32 = <f32>1.0 / distSq2;
                llx = (r2x * leg2 - r2y * radius) * inv;
                lly = (r2x * radius + r2y * leg2) * inv;
                rlx = (r2x * leg2 + r2y * radius) * inv;
                rly = (-r2x * radius + r2y * leg2) * inv;
            } else {
                if (o1Convex) {
                    const leg1 = Mathf.sqrt(distSq1 - radiusSq);
                    const inv: f32 = <f32>1.0 / distSq1;
                    llx = (r1x * leg1 - r1y * radius) * inv;
                    lly = (r1x * radius + r1y * leg1) * inv;
                } else {
                    llx = -unchecked(f[o1 + S_DIRX]);
                    lly = -unchecked(f[o1 + S_DIRZ]);
                }
                if (o2Convex) {
                    const leg2 = Mathf.sqrt(distSq2 - radiusSq);
                    const inv: f32 = <f32>1.0 / distSq2;
                    rlx = (r2x * leg2 + r2y * radius) * inv;
                    rly = (-r2x * radius + r2y * leg2) * inv;
                } else {
                    rlx = unchecked(f[o1 + S_DIRX]);
                    rly = unchecked(f[o1 + S_DIRZ]);
                }
            }
            // (legs never point into a neighbouring edge of a convex vertex)
            const c1 = unchecked(w[o1 + S_CONVEX]) != 0;
            const c2 = unchecked(w[o2 + S_CONVEX]) != 0;
            const ln = sat + unchecked(w[o1 + S_PREV]) * S_WORDS;
            let leftForeign = false;
            let rightForeign = false;
            if (c1 && det(llx, lly, -unchecked(f[ln + S_DIRX]), -unchecked(f[ln + S_DIRZ])) >= 0) {
                llx = -unchecked(f[ln + S_DIRX]);
                lly = -unchecked(f[ln + S_DIRZ]);
                leftForeign = true;
            }
            if (c2 && det(rlx, rly, unchecked(f[o2 + S_DIRX]), unchecked(f[o2 + S_DIRZ])) <= 0) {
                rlx = unchecked(f[o2 + S_DIRX]);
                rly = unchecked(f[o2 + S_DIRZ]);
                rightForeign = true;
            }
            // (the cut-off centres)
            const lcx = invTimeHorizonObst * (unchecked(f[o1 + S_PX]) - px);
            const lcy = invTimeHorizonObst * (unchecked(f[o1 + S_PZ]) - py);
            const rcx = invTimeHorizonObst * (unchecked(f[o2 + S_PX]) - px);
            const rcy = invTimeHorizonObst * (unchecked(f[o2 + S_PZ]) - py);
            const cvx = rcx - lcx;
            const cvy = rcy - lcy;
            const same = o1 == o2;
            const t: f32 = same ? <f32>0.5 : ((vx - lcx) * cvx + (vy - lcy) * cvy) / (cvx * cvx + cvy * cvy);
            const tLeft = (vx - lcx) * llx + (vy - lcy) * lly;
            const tRight = (vx - rcx) * rlx + (vy - rcy) * rly;
            if ((t < 0 && tLeft < 0) || (same && tLeft < 0 && tRight < 0)) {
                // (on the left cut-off circle)
                const wx = vx - lcx;
                const wy = vy - lcy;
                const inv: f32 = <f32>1.0 / Mathf.sqrt(wx * wx + wy * wy);
                const ux = wx * inv;
                const uy = wy * inv;
                lines = putLine(L, lines, lcx + radius * invTimeHorizonObst * ux, lcy + radius * invTimeHorizonObst * uy, uy, -ux);
                continue;
            } else if (t > 1 && tRight < 0) {
                // (on the right cut-off circle)
                const wx = vx - rcx;
                const wy = vy - rcy;
                const inv: f32 = <f32>1.0 / Mathf.sqrt(wx * wx + wy * wy);
                const ux = wx * inv;
                const uy = wy * inv;
                lines = putLine(L, lines, rcx + radius * invTimeHorizonObst * ux, rcy + radius * invTimeHorizonObst * uy, uy, -ux);
                continue;
            }
            // (on the left leg, the right leg or the cut-off line, the nearest)
            let distSqCutoff = <f32>Infinity;
            if (!(t < 0 || t > 1 || same)) {
                const ex = vx - (lcx + t * cvx);
                const ey = vy - (lcy + t * cvy);
                distSqCutoff = ex * ex + ey * ey;
            }
            let distSqLeft = <f32>Infinity;
            if (!(tLeft < 0)) {
                const ex = vx - (lcx + tLeft * llx);
                const ey = vy - (lcy + tLeft * lly);
                distSqLeft = ex * ex + ey * ey;
            }
            let distSqRight = <f32>Infinity;
            if (!(tRight < 0)) {
                const ex = vx - (rcx + tRight * rlx);
                const ey = vy - (rcy + tRight * rly);
                distSqRight = ex * ex + ey * ey;
            }
            if (distSqCutoff <= distSqLeft && distSqCutoff <= distSqRight) {
                const dx = -unchecked(f[o1 + S_DIRX]);
                const dy = -unchecked(f[o1 + S_DIRZ]);
                lines = putLine(L, lines, lcx + radius * invTimeHorizonObst * -dy, lcy + radius * invTimeHorizonObst * dx, dx, dy);
                continue;
            } else if (distSqLeft <= distSqRight) {
                if (leftForeign) continue;
                lines = putLine(L, lines, lcx + radius * invTimeHorizonObst * -lly, lcy + radius * invTimeHorizonObst * llx, llx, lly);
                continue;
            } else {
                if (rightForeign) continue;
                const dx = -rlx;
                const dy = -rly;
                lines = putLine(L, lines, rcx + radius * invTimeHorizonObst * -dy, rcy + radius * invTimeHorizonObst * dx, dx, dy);
                continue;
            }
        }
        const numObstLines = lines;

        // --- computeNewVelocity: the agents' ORCA lines
        const invTimeHorizon: f32 = <f32>1.0 / unchecked(f[at + A_TIME_HORIZON]);
        for (let q = 0; q < nbCount; q++) {
            const o = H_WORDS + unchecked(sc.nbIndex[q]) * A_WORDS;
            const rpx = unchecked(f[o + A_PX]) - px;
            const rpy = unchecked(f[o + A_PZ]) - py;
            const rvx = vx - unchecked(f[o + A_VX]);
            const rvy = vy - unchecked(f[o + A_VZ]);
            const distSq = rpx * rpx + rpy * rpy;
            const combinedRadius = radius + unchecked(f[o + A_RADIUS]);
            const combinedRadiusSq = sqr(combinedRadius);
            let ldx: f32 = 0, ldy: f32 = 0, ux: f32 = 0, uy: f32 = 0;
            if (distSq > combinedRadiusSq) {
                // (no collision)
                const wx = rvx - invTimeHorizon * rpx;
                const wy = rvy - invTimeHorizon * rpy;
                const wLengthSq = wx * wx + wy * wy;
                const dot1 = wx * rpx + wy * rpy;
                if (dot1 < 0 && sqr(dot1) > combinedRadiusSq * wLengthSq) {
                    // (on the cut-off circle)
                    const wLength = Mathf.sqrt(wLengthSq);
                    const inv: f32 = <f32>1.0 / wLength;
                    const unx = wx * inv;
                    const uny = wy * inv;
                    ldx = uny;
                    ldy = -unx;
                    const k = combinedRadius * invTimeHorizon - wLength;
                    ux = k * unx;
                    uy = k * uny;
                } else {
                    // (on the legs)
                    const leg = Mathf.sqrt(distSq - combinedRadiusSq);
                    const inv: f32 = <f32>1.0 / distSq;
                    if (det(rpx, rpy, wx, wy) > 0) {
                        ldx = (rpx * leg - rpy * combinedRadius) * inv;
                        ldy = (rpx * combinedRadius + rpy * leg) * inv;
                    } else {
                        ldx = -((rpx * leg + rpy * combinedRadius) * inv);
                        ldy = -((-rpx * combinedRadius + rpy * leg) * inv);
                    }
                    const dot2 = rvx * ldx + rvy * ldy;
                    ux = dot2 * ldx - rvx;
                    uy = dot2 * ldy - rvy;
                }
            } else {
                // (collision: the cut-off circle of the time step)
                const invTimeStep: f32 = <f32>1.0 / unchecked(f[H_STEP]);
                const wx = rvx - invTimeStep * rpx;
                const wy = rvy - invTimeStep * rpy;
                const wLength = Mathf.sqrt(wx * wx + wy * wy);
                const inv: f32 = <f32>1.0 / wLength;
                const unx = wx * inv;
                const uny = wy * inv;
                ldx = uny;
                ldy = -unx;
                const k = combinedRadius * invTimeStep - wLength;
                ux = k * unx;
                uy = k * uny;
            }
            lines = putLine(L, lines, vx + <f32>0.5 * ux, vy + <f32>0.5 * uy, ldx, ldy);
        }

        sc.nbCount = nbCount;
        sc.obCount = obCount;
        sc.lineCount = lines;
        const prefX = unchecked(f[at + A_PREFX]);
        const prefY = unchecked(f[at + A_PREFZ]);
        const fail = linearProgram2(L, lines, maxSpeed, prefX, prefY, false, sc);
        if (fail < lines) linearProgram3(L, lines, numObstLines, fail, maxSpeed, sc);
        if (!isFinite(sc.rx) || !isFinite(sc.ry)) {
            sc.rx = 0;
            sc.ry = 0;
        }
    }

    // Agents [begin, end) into `out` (a unit of the job on the main lane).
    computeRange(begin: i32, end: i32, sc: AvoidScratch): void {
        const out = this.out;
        for (let i = begin; i < end; i++) {
            this.computeAgent(i, sc);
            unchecked(out[i * 2] = sc.rx);
            unchecked(out[i * 2 + 1] = sc.ry);
        }
    }
}

// (|v| held to OBSTACLE_MIN_SCALE at least: Godot's abs().maxf(0.001))
@inline
function absAtLeast(v: f32): f32 {
    const a = Mathf.abs(v);
    return a > OBSTACLE_MIN_SCALE ? a : OBSTACLE_MIN_SCALE;
}

// The space an obstacle's outline is placed in, as prepare places it
// (Godot's safe transform): its global position, times its turn about Y,
// times its scale's size on each axis. The editor's gizmo draws and drags
// the outline in it.
export function obstacleFrame(o: NavigationObstacle3D): Mat4 {
    const g = o.global();
    const pos = g.wAxis.truncate();
    const sc = signedScale(g);
    const sx = absAtLeast(sc.x);
    const sy = absAtLeast(sc.y);
    const sz = absAtLeast(sc.z);
    const yaw = eulerYXZFromBasis(rotationOf(g)).y;
    const c = Mathf.cos(yaw);
    const sn = Mathf.sin(yaw);
    return Mat4(Vec4(c * sx, 0, -sn * sx, 0), Vec4(0, sy, 0, 0), Vec4(sn * sz, 0, c * sz, 0), Vec4(pos.x, pos.y, pos.z, 1));
}

// What an obstacle's radius is multiplied by (its scale's largest size,
// as prepare's).
export function obstacleRadiusScale(o: NavigationObstacle3D): f32 {
    const sc = signedScale(o.global());
    const sx = absAtLeast(sc.x);
    const sy = absAtLeast(sc.y);
    const sz = absAtLeast(sc.z);
    return sx > sy ? (sx > sz ? sx : sz) : (sy > sz ? sy : sz);
}

// RVO2's distSqPointLineSegment(a, b, c).
function distSqPointLineSegment(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32): f32 {
    const abx = bx - ax;
    const aby = by - ay;
    const r = ((cx - ax) * abx + (cy - ay) * aby) / (abx * abx + aby * aby);
    if (r < 0) {
        const x = cx - ax;
        const y = cy - ay;
        return x * x + y * y;
    } else if (r > 1) {
        const x = cx - bx;
        const y = cy - by;
        return x * x + y * y;
    }
    const x = cx - (ax + r * abx);
    const y = cy - (ay + r * aby);
    return x * x + y * y;
}

// Line `at` (point, direction) into `L`; the count after it.
@inline
function putLine(L: Float32Array, at: i32, px: f32, py: f32, dx: f32, dy: f32): i32 {
    const k = at * 4;
    unchecked(L[k] = px);
    unchecked(L[k + 1] = py);
    unchecked(L[k + 2] = dx);
    unchecked(L[k + 3] = dy);
    return at + 1;
}

// RVO2's linearProgram1: the best point of line `lineNo` within the speed
// circle and lines [0, lineNo), into sc.rx, sc.ry; false when none.
function linearProgram1(L: Float32Array, lineNo: i32, radius: f32, optX: f32, optY: f32, directionOpt: bool,
    sc: AvoidScratch): bool {
    const k = lineNo * 4;
    const px = unchecked(L[k]);
    const py = unchecked(L[k + 1]);
    const dx = unchecked(L[k + 2]);
    const dy = unchecked(L[k + 3]);
    const dotProduct = px * dx + py * dy;
    const discriminant = sqr(dotProduct) + sqr(radius) - (px * px + py * py);
    if (discriminant < 0) return false;
    const sqrtDiscriminant = Mathf.sqrt(discriminant);
    let tLeft = -dotProduct - sqrtDiscriminant;
    let tRight = -dotProduct + sqrtDiscriminant;
    for (let i = 0; i < lineNo; i++) {
        const j = i * 4;
        const ipx = unchecked(L[j]);
        const ipy = unchecked(L[j + 1]);
        const idx = unchecked(L[j + 2]);
        const idy = unchecked(L[j + 3]);
        const denominator = det(dx, dy, idx, idy);
        const numerator = det(idx, idy, px - ipx, py - ipy);
        if (Mathf.abs(denominator) <= RVO_EPSILON) {
            // (lines lineNo and i are (almost) parallel)
            if (numerator < 0) return false;
            continue;
        }
        const t = numerator / denominator;
        if (denominator >= 0) {
            // (line i bounds line lineNo on the right: std::min)
            tRight = t < tRight ? t : tRight;
        } else {
            // (on the left: std::max)
            tLeft = tLeft < t ? t : tLeft;
        }
        if (tLeft > tRight) return false;
    }
    if (directionOpt) {
        if (optX * dx + optY * dy > 0) {
            sc.rx = px + tRight * dx;
            sc.ry = py + tRight * dy;
        } else {
            sc.rx = px + tLeft * dx;
            sc.ry = py + tLeft * dy;
        }
    } else {
        const t = dx * (optX - px) + dy * (optY - py);
        if (t < tLeft) {
            sc.rx = px + tLeft * dx;
            sc.ry = py + tLeft * dy;
        } else if (t > tRight) {
            sc.rx = px + tRight * dx;
            sc.ry = py + tRight * dy;
        } else {
            sc.rx = px + t * dx;
            sc.ry = py + t * dy;
        }
    }
    return true;
}

// RVO2's linearProgram2 over the first `count` lines of `L`: the result in
// sc.rx, sc.ry; the line it failed at, or `count`.
function linearProgram2(L: Float32Array, count: i32, radius: f32, optX: f32, optY: f32, directionOpt: bool,
    sc: AvoidScratch): i32 {
    if (directionOpt) {
        sc.rx = optX * radius;
        sc.ry = optY * radius;
    } else if (optX * optX + optY * optY > sqr(radius)) {
        const inv: f32 = <f32>1.0 / Mathf.sqrt(optX * optX + optY * optY);
        sc.rx = optX * inv * radius;
        sc.ry = optY * inv * radius;
    } else {
        sc.rx = optX;
        sc.ry = optY;
    }
    for (let i = 0; i < count; i++) {
        const j = i * 4;
        if (det(unchecked(L[j + 2]), unchecked(L[j + 3]), unchecked(L[j]) - sc.rx, unchecked(L[j + 1]) - sc.ry) > 0) {
            const tx = sc.rx;
            const ty = sc.ry;
            if (!linearProgram1(L, i, radius, optX, optY, directionOpt, sc)) {
                sc.rx = tx;
                sc.ry = ty;
                return i;
            }
        }
    }
    return count;
}

// RVO2's linearProgram3: the least bad velocity once the lines from
// `beginLine` cannot all be kept (the obstacles' first `numObstLines`
// always are), in sc.rx, sc.ry.
function linearProgram3(L: Float32Array, count: i32, numObstLines: i32, beginLine: i32, radius: f32, sc: AvoidScratch): void {
    const P = sc.proj;
    let distance: f32 = 0;
    for (let i = beginLine; i < count; i++) {
        const k = i * 4;
        const ipx = unchecked(L[k]);
        const ipy = unchecked(L[k + 1]);
        const idx = unchecked(L[k + 2]);
        const idy = unchecked(L[k + 3]);
        if (det(idx, idy, ipx - sc.rx, ipy - sc.ry) > distance) {
            // (the result does not keep line i)
            let n = 0;
            for (; n < numObstLines; n++) {
                const s = n * 4;
                unchecked(P[s] = unchecked(L[s]));
                unchecked(P[s + 1] = unchecked(L[s + 1]));
                unchecked(P[s + 2] = unchecked(L[s + 2]));
                unchecked(P[s + 3] = unchecked(L[s + 3]));
            }
            for (let j = numObstLines; j < i; j++) {
                const m = j * 4;
                const jpx = unchecked(L[m]);
                const jpy = unchecked(L[m + 1]);
                const jdx = unchecked(L[m + 2]);
                const jdy = unchecked(L[m + 3]);
                let lpx: f32 = 0, lpy: f32 = 0;
                const determinant = det(idx, idy, jdx, jdy);
                if (Mathf.abs(determinant) <= RVO_EPSILON) {
                    // (lines i and j are parallel)
                    if (idx * jdx + idy * jdy > 0) continue;
                    lpx = <f32>0.5 * (ipx + jpx);
                    lpy = <f32>0.5 * (ipy + jpy);
                } else {
                    const q = det(jdx, jdy, ipx - jpx, ipy - jpy) / determinant;
                    lpx = ipx + q * idx;
                    lpy = ipy + q * idy;
                }
                const ddx = jdx - idx;
                const ddy = jdy - idy;
                const inv: f32 = <f32>1.0 / Mathf.sqrt(ddx * ddx + ddy * ddy);
                n = putLine(P, n, lpx, lpy, ddx * inv, ddy * inv);
            }
            const tx = sc.rx;
            const ty = sc.ry;
            if (linearProgram2(P, n, radius, -idy, idx, true, sc) < n) {
                // (in principle never: a float's error; the result is kept)
                sc.rx = tx;
                sc.ry = ty;
            }
            distance = det(idx, idy, ipx - sc.rx, ipy - sc.ry);
        }
    }
}

// The avoidance of a step as a job (units of AVOIDANCE_GRAIN agents), on
// lanes when the step tests enough pairs (AVOIDANCE_LANE_PAIRS): the lanes
// read the snapshot's words as they are and give back each unit's
// velocities, two floats an agent.
export class AvoidanceJob extends LaneJob {
    world: AvoidanceWorld;

    constructor(world: AvoidanceWorld) {
        super();
        this.world = world;
    }

    runUnit(unit: i32, begin: i32, end: i32, worker: i32): void {
        const wd = this.world;
        wd.computeRange(begin, end, wd.scratchOf(worker));
    }

    laneKind(): i32 {
        return LANE_AVOIDANCE;
    }

    worthLanes(count: i32, grain: i32): bool {
        return <i64>count * <i64>this.world.neighbours >= <i64>AVOIDANCE_LANE_PAIRS;
    }

    packLanes(count: i32, grain: i32, units: i32): i32 {
        return this.world.bytes;
    }

    laneWords(): ArrayBuffer {
        return this.world.words;
    }

    // A lane's unit: its agents' velocities (x, z each), in order.
    mergeLaneUnit(unit: i32, r: LaneResult, at: i32): void {
        const begin = unitBegin(unit, AVOIDANCE_GRAIN);
        const end = unitEnd(unit, this.world.agents, AVOIDANCE_GRAIN);
        const from = unchecked(r.unitFloats[at]);
        const out = this.world.out;
        const fl = r.floats;
        for (let i = begin; i < end; i++) {
            const k = from + (i - begin) * 2;
            unchecked(out[i * 2] = unchecked(fl[k]));
            unchecked(out[i * 2 + 1] = unchecked(fl[k + 1]));
        }
    }
}

// The avoidance's units on a lane (render/lanes.as avoidanceLane): from
// the snapshot's `words`, every unit it can claim of the run's `units`,
// computed as the main lane computes them; each unit's velocities as
// mergeLaneUnit reads them.
export function avoidanceLaneUnits(words: ArrayBuffer, claims: UnitClaims, count: i32, grain: i32, units: i32): LaneResult {
    const world = AvoidanceWorld.fromWords(words);
    const sc = world.newScratch();
    const out = new LaneResultWriter(units);
    while (true) {
        const u = claims.next();
        if (u < 0) break;
        const begin = unitBegin(u, grain);
        const end = unitEnd(u, count, grain);
        out.begin(u);
        const at = out.reserveFloats((end - begin) * 2);
        for (let i = begin; i < end; i++) {
            world.computeAgent(i, sc);
            const fl = out.floatArray();
            unchecked(fl[at + (i - begin) * 2] = sc.rx);
            unchecked(fl[at + (i - begin) * 2 + 1] = sc.ry);
        }
    }
    return out.result();
}

// Agent `i`'s new velocity on the ground plane, (x, 0, z), as the world's
// last computeInto left it.
export function avoidedVelocity(world: AvoidanceWorld, i: i32): Vec3 {
    return Vec3(world.velocityX(i), 0, world.velocityZ(i));
}
