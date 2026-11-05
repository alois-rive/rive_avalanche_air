// A CPUParticles3D's particles (milestone 35; docs/engine/PARTICLES.md):
// the state the simulation (sim.as) writes at each step and the packer
// (pack.as) reads to fill the instanced draw, kept on the node
// (CPUParticles3D.particles) from frame to frame. The arrays are made once
// for an amount (`capacity`) and reused, so a step and a pack allocate
// nothing; a new amount makes them again (and restarts the emitter, as
// Godot's set_amount does).
//
// Space: with local_coords a particle's position and velocity are in the
// node's own space, without it in the scene's (Y up), where they stay when
// the node moves; the packer takes them into the node's space, which the
// draw is placed by in both modes (Godot's _update_particle_data_buffer). Angles are radians, colours sRGB numbers with straight
// alpha as Godot's (they reach the instance colour as written).
//
// The contract between sim.as (package A writes every field below) and
// pack.as (package B reads them, and owns `instances` and `packed`).

import { InstanceData } from "../../render/instances";

// The most particles one emitter keeps (amount is clamped to it, and the
// engine warns: particles-amount); Godot has no cap.
export const MAX_PARTICLE_AMOUNT: i32 = 10000;
// The most particles a scene should have in all (the compiler warns past
// it: particles-too-many; they are still simulated).
export const PARTICLE_BUDGET: i32 = 20000;
// The shortest lifetime (Godot's range hint: 0.01).
export const MIN_PARTICLE_LIFETIME: f32 = 0.01;
// The tools' clock: `render --time`, `--animation`, `--state-machine`, the
// editor's Animate mode step at Rive's 60 frames a second.
export const PARTICLE_TOOL_STEP: f64 = 1.0 / 60.0;
// The latest time the tools' clock steps to (an hour: 216,000 steps), so
// a far frame or time ends; `--time` past it is an error, a timeline's
// frame past it draws the particles there.
export const PARTICLE_TOOL_MAX_TIME: f64 = 3600;
// A frame longer than this counts as this long (Godot's fixed_fps rule,
// here in both modes: a stalled host does not throw particles through
// walls); with fixed_fps 0 a frame is one step of its length (Godot's).
export const PARTICLE_MAX_DELTA: f64 = 0.1;
// preprocess steps at 1/fixed_fps, or this when fixed_fps is 0 (Godot's
// 1/30 s), ...
export const PARTICLE_PREPROCESS_STEP: f64 = 1.0 / 30.0;
// ... runs at most this many steps (two minutes at 30 a second).
export const PARTICLE_PREPROCESS_MAX_STEPS: i32 = 3600;
// emission_points_count's range.
export const MAX_EMISSION_POINTS: i32 = 65536;

// Godot's CPUParticles3D.DrawOrder (0 to 2), so a Godot scene's number
// means what it means there; then Hedra's own reverse_lifetime (3, the
// youngest first: GPUParticles3D's, which CPUParticles3D lacks), after
// Godot's values so none of them moves.
export const DRAW_ORDER_INDEX: i32 = 0;
export const DRAW_ORDER_LIFETIME: i32 = 1;
export const DRAW_ORDER_VIEW_DEPTH: i32 = 2;
export const DRAW_ORDER_REVERSE_LIFETIME: i32 = 3;

// Godot's CPUParticles3D.EmissionShape.
export const EMISSION_POINT: i32 = 0;
export const EMISSION_SPHERE: i32 = 1;
export const EMISSION_SPHERE_SURFACE: i32 = 2;
export const EMISSION_BOX: i32 = 3;
export const EMISSION_POINTS: i32 = 4;
export const EMISSION_DIRECTED_POINTS: i32 = 5;
export const EMISSION_RING: i32 = 6;

// StandardMaterial3D.billboard_mode (Godot's BaseMaterial3D.BillboardMode).
export const BILLBOARD_DISABLED: i32 = 0;
export const BILLBOARD_ENABLED: i32 = 1;
export const BILLBOARD_FIXED_Y: i32 = 2;
export const BILLBOARD_PARTICLES: i32 = 3;

export class ParticleState {
    // The particles the arrays hold: the node's amount, clamped to 1 ..
    // MAX_PARTICLE_AMOUNT.
    capacity: i32 = 0;

    // --- per particle (capacity each), Godot's Particle --------------------
    // 1 while it lives.
    active: StaticArray<u8> = new StaticArray<u8>(0);
    // Its age and its lifetime (lifetime shortened by lifetime_randomness),
    // seconds.
    time: StaticArray<f32> = new StaticArray<f32>(0);
    lifetime: StaticArray<f32> = new StaticArray<f32>(0);
    // Its position and velocity (see the header for the space).
    px: StaticArray<f32> = new StaticArray<f32>(0);
    py: StaticArray<f32> = new StaticArray<f32>(0);
    pz: StaticArray<f32> = new StaticArray<f32>(0);
    vx: StaticArray<f32> = new StaticArray<f32>(0);
    vy: StaticArray<f32> = new StaticArray<f32>(0);
    vz: StaticArray<f32> = new StaticArray<f32>(0);
    // Its angle (radians: a billboard's roll, particle_flag_rotate_y's
    // turn) and its scale on each axis (scale_amount times its curves).
    angle: StaticArray<f32> = new StaticArray<f32>(0);
    sx: StaticArray<f32> = new StaticArray<f32>(0);
    sy: StaticArray<f32> = new StaticArray<f32>(0);
    sz: StaticArray<f32> = new StaticArray<f32>(0);
    // Its colour now (color x its emission colour x the ramps x the hue
    // variation).
    r: StaticArray<f32> = new StaticArray<f32>(0);
    g: StaticArray<f32> = new StaticArray<f32>(0);
    b: StaticArray<f32> = new StaticArray<f32>(0);
    a: StaticArray<f32> = new StaticArray<f32>(0);
    // Its random stream's seed (random.as particleSeed), drawn at its
    // emission: every random value of its life comes from it.
    seed: StaticArray<u32> = new StaticArray<u32>(0);
    // Without local_coords, the emitter's rotation when it was emitted (a
    // unit quaternion, scene space: Godot's emission_xform x
    // p.transform, orthonormalised), its basis from then on; the identity
    // with local_coords.
    qx: StaticArray<f32> = new StaticArray<f32>(0);
    qy: StaticArray<f32> = new StaticArray<f32>(0);
    qz: StaticArray<f32> = new StaticArray<f32>(0);
    qw: StaticArray<f32> = new StaticArray<f32>(0);

    // --- the emitter ---------------------------------------------------------
    // How many live now (the instanced draw's count).
    alive: i32 = 0;
    // Godot's `time`: seconds into the current cycle (0 .. lifetime), and
    // the cycles begun since the last restart.
    cycleTime: f64 = 0;
    cycle: i32 = 0;
    // Seconds simulated since the last restart (preprocess included), and
    // the steps taken.
    elapsed: f64 = 0;
    steps: i64 = 0;
    // fixed_fps's leftover seconds, carried to the next advance.
    remainder: f64 = 0;
    // emitting as the last step saw it (an off-to-on write on a one_shot
    // emitter begins a new cycle at time 0, Godot 4's set_emitting), Godot's
    // `active` (the emitter has particles to simulate: set when emitting
    // turns on, cleared, with `finished`, once none is left), whether
    // preprocess has run since the restart, and the restarts so far (mixed
    // into the seed when use_fixed_seed is off, so each new emission
    // differs, deterministically).
    wasEmitting: bool = false;
    emitterActive: bool = false;
    preprocessed: bool = false;
    restarts: i32 = 0;
    // The emissions begun again since the last restart after the emitter
    // had stopped (its cycle set back to 0, so `cycle` alone would give the
    // same burst again; mixed into the seed when use_fixed_seed is off:
    // random.as emissionSeed), and the seed made from the node and the
    // restarts before they are mixed in (so mixing them in again reads no
    // path and allocates nothing).
    emissions: i32 = 0;
    baseSeed: u32 = 0;
    // The seed the emission draws from (random.as emitterSeed, then
    // emissionSeed).
    emitterSeed: u32 = 0;
    // A one_shot emission ended (its cycle done, emitting off, every
    // particle dead; Godot never emits `finished` without one_shot): the
    // run time emits `finished` once and clears it (feature_particles.as).
    finishedPending: bool = false;
    // The emission points in use (the node's, or computed from
    // emission_points_from: points.as), three numbers a point, with their
    // normals (empty: none) and colours (four numbers a point; empty: none).
    points: Array<f64> = [];
    normals: Array<f64> = [];
    colors: Array<f64> = [];
    pointsResolved: bool = false;
    // Moves at every step that changed a particle (the packer packs again
    // only when it moved, or the camera did).
    version: u32 = 0;

    // --- the draw (pack.as) ----------------------------------------------------
    // capacity x INSTANCE_STRIDE bytes, dynamic (render/instances.as); its
    // `count` the particles packed.
    instances: InstanceData = new InstanceData();
    // The `version` last packed, and what else the pack depended on (its
    // camera's stamp), so an unchanged frame packs nothing.
    packedVersion: u32 = 0xffffffff;
    packedStamp: u64 = 0;
    // The draw order's scratch (capacity each).
    order: StaticArray<i32> = new StaticArray<i32>(0);
    keys: StaticArray<f32> = new StaticArray<f32>(0);

    // Makes every per-particle array (and the draw's bytes) for `n`
    // particles, all dead. Allocates; called on the first step and when
    // the amount changes.
    resize(n: i32): void {
        const c = n < 1 ? 1 : (n > MAX_PARTICLE_AMOUNT ? MAX_PARTICLE_AMOUNT : n);
        this.capacity = c;
        this.active = new StaticArray<u8>(c);
        this.time = new StaticArray<f32>(c);
        this.lifetime = new StaticArray<f32>(c);
        this.px = new StaticArray<f32>(c);
        this.py = new StaticArray<f32>(c);
        this.pz = new StaticArray<f32>(c);
        this.vx = new StaticArray<f32>(c);
        this.vy = new StaticArray<f32>(c);
        this.vz = new StaticArray<f32>(c);
        this.angle = new StaticArray<f32>(c);
        this.sx = new StaticArray<f32>(c);
        this.sy = new StaticArray<f32>(c);
        this.sz = new StaticArray<f32>(c);
        this.r = new StaticArray<f32>(c);
        this.g = new StaticArray<f32>(c);
        this.b = new StaticArray<f32>(c);
        this.a = new StaticArray<f32>(c);
        this.seed = new StaticArray<u32>(c);
        this.qx = new StaticArray<f32>(c);
        this.qy = new StaticArray<f32>(c);
        this.qz = new StaticArray<f32>(c);
        this.qw = new StaticArray<f32>(c);
        for (let k = 0; k < c; k++) unchecked(this.qw[k] = 1);
        this.order = new StaticArray<i32>(c);
        // (every index, so a sorted draw order is right whatever order
        // packed first: pack.as sorts from the last pack's order)
        for (let k = 0; k < c; k++) unchecked(this.order[k] = k);
        this.keys = new StaticArray<f32>(c);
        this.alive = 0;
        const inst = this.instances;
        inst.dynamic = true;
        inst.hasColors = true;
        inst.count = 0;
        inst.bytes = new ArrayBuffer(c * 64);
        inst.version++;
        this.packedVersion = 0xffffffff;
        this.version++;
    }

    // --- the simulation's own (sim.as; added after the contract above) ---
    // Each particle's random draws that last its life (Godot's Particle's
    // angle_rand, scale_rand, hue_rot_rand, and the damping's and the
    // angular velocity's, which Godot draws again each step from the
    // particle's seed and which are the same each time, so drawn once
    // here), 0 to 1; and its tint, Godot's base_color (the emission point's
    // colour) times start_color_rand (the initial ramp's colour), which the
    // colour of every step is multiplied by.
    angleRand: StaticArray<f32> = new StaticArray<f32>(0);
    scaleRand: StaticArray<f32> = new StaticArray<f32>(0);
    hueRand: StaticArray<f32> = new StaticArray<f32>(0);
    dampRand: StaticArray<f32> = new StaticArray<f32>(0);
    angVelRand: StaticArray<f32> = new StaticArray<f32>(0);
    // The cosine and sine of each particle's hue turn (hue.as) while the
    // emitter has no hue_variation_curve, for the hue_variation_min and max
    // in hueMin and hueMax (a turn constant over the particle's life, so
    // its trigonometry is done once, and again for all if either changes).
    hueCos: StaticArray<f32> = new StaticArray<f32>(0);
    hueSin: StaticArray<f32> = new StaticArray<f32>(0);
    hueMin: f32 = 0;
    hueMax: f32 = 0;
    tr: StaticArray<f32> = new StaticArray<f32>(0);
    tg: StaticArray<f32> = new StaticArray<f32>(0);
    tb: StaticArray<f32> = new StaticArray<f32>(0);
    ta: StaticArray<f32> = new StaticArray<f32>(0);
    // The use_fixed_seed and seed emitterSeed was made from (a change makes
    // it again: sim.as), and whether it was made at all.
    seedFixed: bool = false;
    seedValue: i64 = 0;
    seedMade: bool = false;
    // random.as pathHash of the node's path, and the tree's structure
    // epoch it was hashed at (-1: never), so a restart() with
    // use_fixed_seed off reads the path again only after a rename or a
    // move, never building it per restart (the stub allocator never frees).
    pathSeed: u32 = 0;
    pathEpoch: i32 = -1;

    // The simulation's per-particle arrays for `capacity` (after resize;
    // sim.as ensureParticles calls both). Allocates.
    resizeSim(): void {
        const c = this.capacity;
        this.angleRand = new StaticArray<f32>(c);
        this.scaleRand = new StaticArray<f32>(c);
        this.hueRand = new StaticArray<f32>(c);
        this.dampRand = new StaticArray<f32>(c);
        this.angVelRand = new StaticArray<f32>(c);
        this.hueCos = new StaticArray<f32>(c);
        this.hueSin = new StaticArray<f32>(c);
        this.tr = new StaticArray<f32>(c);
        this.tg = new StaticArray<f32>(c);
        this.tb = new StaticArray<f32>(c);
        this.ta = new StaticArray<f32>(c);
    }
}
