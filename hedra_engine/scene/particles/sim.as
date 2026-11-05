// The particles' simulation (milestone 35; docs/engine/PARTICLES.md):
// Godot 4's CPUParticles3D::_update_internal and _particles_process, step
// for step, for the properties the format has (../classdb.as
// "CPUParticles3D"), from each particle's own random stream (random.as) so
// that the same scene advanced by the same frames gives the same particles
// in every tool and host.
//
// The clock (_update_internal): `advanceParticles(node, emitter, seconds)`
// takes one frame of the host's; a frame of 0 seconds or less does nothing
// at all (Godot steps 0.001 s with fixed_fps; a paused scene stays still
// here), a longer one than PARTICLE_MAX_DELTA counts as that long (Godot
// holds it only with fixed_fps; here in both modes, so a stalled host does
// not throw particles through walls). An emitter neither active nor
// emitting is reset (its cycle from the start) and goes no further. Then
// preprocess, once after a restart (or a reset): steps of 1/fixed_fps, or
// PARTICLE_PREPROCESS_STEP, at speed 1, while the seconds left are 0 or
// more (Godot 4.3's `todo >= 0`), at most PARTICLE_PREPROCESS_MAX_STEPS;
// then with fixed_fps n, steps of 1/n while the frame and the leftover
// (state.remainder, Godot's frame_remainder) hold one, else one step of
// the frame. Each step's seconds are times speed_scale (a step of 0
// seconds, speed_scale 0, would change nothing and is not taken).
//
// A step (_particles_process): the cycle's time moves on and wraps at
// lifetime (a new cycle: a one_shot emitter stops emitting there, the
// write made to the node's `emitting` value too, so a binding and the
// Inspector see it); each particle restarts when the cycle passes its
// restart time (i / amount, jittered by randomness through Godot's idhash
// of the cycle and index, times 1 - explosiveness; fract_delta moves it on
// by the part of the step after that time), or when its age times
// (1 - explosiveness) is past its lifetime, and is then emitted again
// (when emitting; else it dies); a living one past its lifetime dies; the
// others age and move (gravity, damping along the velocity, the angle and
// its angular velocity); then every particle reached gets its scale and
// colour for its age (`tv`, its age over its lifetime: every *_curve read
// with Curve.sampleBaked, absent 1) and moves by its velocity. An emitter
// whose cycle has begun, with no particle left to simulate, becomes
// inactive; a one_shot one then sets state.finishedPending once (Godot's
// `finished`; never without one_shot, as Godot's documentation says).
//
// Emission (Godot's restart branch), from the particle's stream seeded
// particleSeed(emitterSeed, index, cycle), in this order: angleRand,
// scaleRand, hueRotRand, the initial ramp's offset (only with a ramp), the
// spread's two angles, the initial velocity's, the lifetime's
// (1 - r x lifetime_randomness), the shape's (emit.as), then the damping's
// and the angular velocity's (Godot draws those two again every step from
// the particle's seed and gets the same numbers each time; drawn once
// here). Without local_coords the emitter's global transform places the
// position and turns (and scales) the velocity, as Godot's.
//
// `emitting` written true (a key, a binding, a script, the Inspector) on
// an emitter that was not emitting makes it active (Godot's set_emitting);
// a one_shot one begins a new cycle at time 0, so a burst goes off again
// even while the last one's particles fly (Godot 4.3's GPUParticles3D's
// rule; its CPUParticles3D waits for the cycle to come round). Written
// false: no particle is emitted again, the living live out. The node's
// restart() is taken at the next advance, before anything moves: every
// particle gone, the cycle from its start, preprocess again, the seed made
// again from the restarts so far (so with use_fixed_seed off each restart
// emits differently, deterministically). An emitter that stopped (emitting
// off, every particle dead: its cycle back at 0, Godot's reset) counts an
// emission, mixed into the seed with use_fixed_seed off, so a burst set off
// again after the last one ended differs too. A new amount makes the arrays
// again and starts over the same way, keeping the seed (Godot's
// set_amount). An invisible emitter is not advanced (Godot's
// is_visible_in_tree rule).
//
// Determinism: only ParticleRandom streams and the clock; trigonometry and
// powers from base/vecmath (software: the same bits on every host), sqrt
// (exact); no Math.random, no host time, no map iteration. Allocates
// nothing once the state is made (a restart reads the node's path when its
// seed comes from it; the emission points are computed once, points.as).

import { Mat4, Quat, Vec3, Vec4, cosf, sinf, toRadians } from "../../base/vecmath";
import { Value, ValueKind } from "../value";
import { Curve } from "../resource/curve";
import { CPUParticles3D, SceneNode, treeStructureEpoch } from "../tree/node";
import { Job, jobs } from "../../base/jobs";
import {
    EMISSION_BOX, EMISSION_DIRECTED_POINTS, EMISSION_POINTS, EMISSION_RING, EMISSION_SPHERE, EMISSION_SPHERE_SURFACE,
    MAX_PARTICLE_AMOUNT, PARTICLE_MAX_DELTA, PARTICLE_PREPROCESS_MAX_STEPS, PARTICLE_PREPROCESS_STEP, ParticleState,
} from "./state";
import { ParticleRandom, emissionSeed, emitterSeedHashed, particleSeed, pathHash, phaseJitter } from "./random";
import { alongNormal, boxPoint, pointIndex, ringPoint, spherePoint, sphereSurfacePoint, spreadDirection } from "./emit";
import { hueRotate, hueRotateBy } from "./hue";
import { pointsFromNode } from "./points";

const TAU: f64 = 6.28318530717958647692;
// Godot's CMP_EPSILON: the least scale on an axis, and is_equal_approx's
// tolerance about 0.
const CMP_EPSILON: f32 = 0.00001;

// The stream a particle's emission draws from (seeded per particle, so one
// is enough; made once).
// Each worker's random stream (jobs.as rule 3: a job's units draw in their
// worker's own), made before the first run it works in (EmitterJob.run);
// worker 0's from the start.
const rngs: Array<ParticleRandom> = [new ParticleRandom()];

function rngOf(worker: i32): ParticleRandom {
    return unchecked(rngs[worker]);
}

function clampAmount(n: i32): i32 {
    return n < 1 ? 1 : (n > MAX_PARTICLE_AMOUNT ? MAX_PARTICLE_AMOUNT : n);
}

// The seed the emission draws from, made again from the node's
// use_fixed_seed, seed, path (read only when the seed comes from it, and
// hashed again only when the tree's structure changed since: s.pathSeed),
// the restarts so far and the emissions begun again since.
function makeSeed(node: CPUParticles3D, s: ParticleState): void {
    const fixed = node.useFixedSeed;
    if (!fixed) {
        const epoch = treeStructureEpoch();
        if (s.pathEpoch != epoch) {
            s.pathSeed = pathHash(node.path());
            s.pathEpoch = epoch;
        }
    }
    s.baseSeed = emitterSeedHashed(fixed, node.seed, fixed ? 0 : s.pathSeed, s.restarts);
    s.emitterSeed = emissionSeed(s.baseSeed, fixed, s.emissions);
    s.seedFixed = fixed;
    s.seedValue = node.seed;
    s.seedMade = true;
}

// Every particle dead and its age 0, the cycle from its start, preprocess
// to run again; the emitter active when it emits.
function startOver(node: CPUParticles3D, s: ParticleState): void {
    const n = s.capacity;
    for (let i = 0; i < n; i++) {
        unchecked(s.active[i] = 0);
        unchecked(s.time[i] = 0);
        unchecked(s.lifetime[i] = 0);
    }
    s.alive = 0;
    s.cycleTime = 0;
    s.cycle = 0;
    s.emissions = 0;
    s.elapsed = 0;
    s.steps = 0;
    s.remainder = 0;
    s.preprocessed = false;
    s.finishedPending = false;
    s.wasEmitting = node.emitting;
    s.emitterActive = node.emitting;
    s.version++;
}

// The node's state, made (or made again for a new amount, which starts it
// over, keeping its seed: Godot's set_amount) before anything reads it.
// Allocates only then.
export function ensureParticles(node: CPUParticles3D): ParticleState {
    let s = node.particles;
    const n = clampAmount(node.amount);
    if (s == null) {
        s = new ParticleState();
        node.particles = s;
        s.resize(n);
        s.resizeSim();
        s.wasEmitting = node.emitting;
        s.emitterActive = node.emitting;
        makeSeed(node, s);
    } else if (s.capacity != n || s.angleRand.length != s.capacity) {
        s.resize(n);
        s.resizeSim();
        startOver(node, s);
        // (the seed kept, without the emissions startOver set back to 0)
        s.emitterSeed = s.baseSeed;
    }
    return s;
}

// Godot's restart(), at once: every particle gone, the cycle from its
// start, the seed made again (random.as emitterSeed with the restarts so
// far: the node's restart() counts one, through restartRequests; the
// tools' clock restarts without counting, so `render --time` emits what a
// host's first frames emit), the emission points computed again, and
// preprocess run now when the emitter is active and visible (Godot's
// restart updates at once), placed by the node's global transform.
export function restartParticles(node: CPUParticles3D): void {
    const s = ensureParticles(node);
    startOver(node, s);
    makeSeed(node, s);
    s.pointsResolved = false;
    if (s.emitterActive && node.visibleInTree()) preprocessNow(node, s, node.global());
}

// The tools' clock's start of a run (clock.as particlesAtTime), before its
// restart: the scene as it was before the particles wrote to it, so a run
// on a tree an earlier run left is the same run. `emitting` back to what
// the particles' writes replaced (a finished one_shot set it false, a
// restart() true), no restart() pending, and the restarts counted back to
// 0 (with use_fixed_seed off the seed comes from them: the editor's
// Restart then leaves Animate mode as `hedra render` draws it).
export function toolsStart(node: CPUParticles3D): void {
    node.restoreEmitting();
    node.restartRequests = 0;
    node.restartsKeepingSeed = 0;
    const s = node.particles;
    if (s != null) s.restarts = 0;
}

// The emission points from emission_points_from, once (points.as), when
// the shape emits from points and the node has none of its own.
function resolvePoints(node: CPUParticles3D, s: ParticleState): void {
    if (s.pointsResolved) return;
    const shape = node.emissionShape;
    if (shape != EMISSION_POINTS && shape != EMISSION_DIRECTED_POINTS) return;
    if (node.emissionPoints.length > 0) return;
    s.pointsResolved = true;
    if (node.emissionPointsFrom.length > 0) {
        pointsFromNode(node, s.points, s.normals);
    } else {
        s.points.length = 0;
        s.normals.length = 0;
    }
}

// preprocess (see the header); whether a particle changed.
function preprocessNow(node: CPUParticles3D, s: ParticleState, emitter: Mat4, worker: i32 = 0): bool {
    s.preprocessed = true;
    const pre = <f64>node.preprocess;
    if (!(pre > 0)) return false;
    resolvePoints(node, s);
    // (each step at speed_scale, as Godot's _particles_process scales its
    // delta: preprocess simulates preprocess x speed_scale seconds, in the
    // same count of steps; nothing at a speed of 0 or less, as a frame)
    const speed = <f64>node.speedScale;
    if (!(speed > 0)) return false;
    const ft = node.fixedFps > 0 ? 1.0 / <f64>node.fixedFps : PARTICLE_PREPROCESS_STEP;
    let todo = pre;
    let changed = false;
    for (let k = 0; todo >= 0 && k < PARTICLE_PREPROCESS_MAX_STEPS; k++) {
        if (step(node, s, emitter, ft * speed, worker)) changed = true;
        todo -= ft;
    }
    return changed;
}

// A one_shot emission's cycle ended: emitting off, on the node's field and
// its value (written in place once the node holds a written one: nothing
// allocated after the first).
function stopEmitting(node: CPUParticles3D, s: ParticleState): void {
    node.saveEmitting();
    node.emitting = false;
    s.wasEmitting = false;
    const v = node.writtenProp("emitting", ValueKind.Bool);
    if (v != null) v.b = false;
    else node.setWrittenProp("emitting", Value.bool(false));
    node.wroteEmitting();
}

// One frame of `seconds` for `node`, whose global transform (scene space,
// Y up) is `emitter`. Returns whether a particle changed (state.version
// moved). Allocates nothing once the state is made.
export function advanceParticles(node: CPUParticles3D, emitter: Mat4, seconds: f64, worker: i32 = 0): bool {
    if (!(seconds > 0) || !node.visibleInTree()) return false;
    const s = ensureParticles(node);
    let changed = false;
    if (node.restartRequests > 0) {
        // (a restart that keeps the seed does not count toward it)
        const kept = min<i32>(node.restartsKeepingSeed, node.restartRequests);
        const keepAll = kept == node.restartRequests;
        s.restarts += node.restartRequests - kept;
        node.restartRequests = 0;
        node.restartsKeepingSeed = 0;
        // (restart(true) alone keeps the seed it had, the emissions begun
        // again since included: startOver counts them back to 0)
        const emissions = s.emissions;
        startOver(node, s);
        if (keepAll) s.emissions = emissions;
        makeSeed(node, s);
        // (the emission points are kept: they are drawn from the restarts
        // before the first, so only the scene could change them, and a
        // script setting off bursts with restart() must not sample them,
        // allocating, each time; an edit or the tools' clock samples again)
        changed = true;
    }
    const fixed = node.useFixedSeed;
    if (!s.seedMade || fixed != s.seedFixed || (fixed && node.seed != s.seedValue)) makeSeed(node, s);
    const on = node.emitting;
    if (on && !s.wasEmitting) {
        s.emitterActive = true;
        // (a one_shot burst goes off again from the start of a cycle of
        // its own; one already at the start begins there)
        if (node.oneShot && (s.cycleTime != 0 || s.cycle != 0)) {
            s.cycle++;
            s.cycleTime = 0;
        }
    }
    s.wasEmitting = on;
    if (!s.emitterActive && !on) {
        // (an emission that ran is over: the next one, its cycle back at
        // 0, draws from a seed of its own, so it differs with
        // use_fixed_seed off, as Godot's; once, since the cycle is 0 after)
        if (s.cycleTime != 0 || s.cycle != 0) {
            s.emissions++;
            s.emitterSeed = emissionSeed(s.baseSeed, s.seedFixed, s.emissions);
        }
        s.cycleTime = 0;
        s.cycle = 0;
        s.remainder = 0;
        s.preprocessed = false;
        return changed;
    }
    resolvePoints(node, s);
    if (!s.preprocessed && preprocessNow(node, s, emitter, worker)) changed = true;
    const delta = seconds < PARTICLE_MAX_DELTA ? seconds : PARTICLE_MAX_DELTA;
    const speed = <f64>node.speedScale;
    if (node.fixedFps > 0) {
        const ft = 1.0 / <f64>node.fixedFps;
        let todo = s.remainder + delta;
        while (todo >= ft) {
            if (speed > 0 && step(node, s, emitter, ft * speed, worker)) changed = true;
            todo -= ft;
        }
        s.remainder = todo;
    } else if (speed > 0) {
        if (step(node, s, emitter, delta * speed, worker)) changed = true;
    }
    return changed;
}

// A curve at `tv`, 1 without one (Godot's tex_* = 1.0 defaults).
@inline
function curveAt(c: Curve?, tv: f32): f32 {
    return c != null ? c.sampleBaked(tv) : 1;
}

// Godot's Math::lerp.
@inline
function lerp(a: f32, b: f32, t: f32): f32 {
    return a + (b - a) * t;
}

// One _particles_process of `dt` seconds (speed_scale applied). Whether a
// particle changed (or the emitter went inactive).
function step(node: CPUParticles3D, s: ParticleState, emitter: Mat4, dt: f64, worker: i32): bool {
    const life = <f64>node.lifetime;
    const prev = s.cycleTime;
    let time = prev + dt;
    if (time > life) {
        time = time % life;
        s.cycle++;
        if (node.oneShot && s.cycle > 0) stopEmitting(node, s);
    }
    s.cycleTime = time;
    s.steps++;
    s.elapsed += dt;
    const emitting = node.emitting;
    const n = s.capacity;
    const systemPhase = time / life;
    const randomness = <f64>node.randomness;
    const keep = 1.0 - <f64>node.explosiveness;
    const fract = node.fractDelta;
    const world = !node.localCoords;
    const gravity = node.gravity;
    const dampMin = node.dampingMin;
    const dampMax = node.dampingMax;
    const dampCurve = node.dampingCurve;
    const angleMin = node.angleMin;
    const angleMax = node.angleMax;
    const angleCurve = node.angleCurve;
    const angVelMin = node.angularVelocityMin;
    const angVelMax = node.angularVelocityMax;
    const angVelCurve = node.angularVelocityCurve;
    const scaleMin = node.scaleAmountMin;
    const scaleMax = node.scaleAmountMax;
    const split = node.splitScale;
    const scaleCurve = node.scaleAmountCurve;
    const curveX = node.scaleCurveX;
    const curveY = node.scaleCurveY;
    const curveZ = node.scaleCurveZ;
    const color = node.color;
    const ramp = node.colorRamp;
    const hueMin = node.hueVariationMin;
    const hueMax = node.hueVariationMax;
    const hueCurve = node.hueVariationCurve;
    // (the kept turns are kept with a curve too, so a curve removed while
    // its particles live turns them by their own from the next step)
    huesKept(s, hueMin, hueMax);
    let should = false;
    let changed = false;
    let alive = 0;
    for (let i = 0; i < n; i++) {
        const was = unchecked(s.active[i]) != 0;
        if (!emitting && !was) continue;
        let local = dt;
        let phase = <f64>i / <f64>n;
        if (randomness > 0) {
            // (Godot's: the cycle before while the particle's phase is
            // still ahead of the system's)
            const c = phase >= systemPhase ? s.cycle - 1 : s.cycle;
            phase += randomness * <f64>phaseJitter(c, n, i) / <f64>n;
        }
        phase *= keep;
        const restartTime = phase * life;
        let restart = false;
        if (time > prev) {
            // (>= prev: a particle whose time is the cycle's start emits in
            // the first step)
            if (restartTime >= prev && restartTime < time) {
                restart = true;
                if (fract) local = time - restartTime;
            }
        } else if (local > 0) {
            if (restartTime >= prev) {
                restart = true;
                if (fract) local = life - restartTime + time;
            } else if (restartTime < time) {
                restart = true;
                if (fract) local = time - restartTime;
            }
        }
        let age = <f64>unchecked(s.time[i]);
        const span = <f64>unchecked(s.lifetime[i]);
        if (age * keep > span) restart = true;
        let tv: f32 = 0;
        if (restart) {
            if (!emitting) {
                if (was) changed = true;
                unchecked(s.active[i] = 0);
                continue;
            }
            spawn(node, s, i, emitter, world, worker);
        } else if (!was) {
            continue;
        } else if (age > span) {
            // (Godot's: dead now, and still counted toward the emitter
            // being active in this step)
            unchecked(s.active[i] = 0);
            should = true;
            changed = true;
            continue;
        } else {
            age += local;
            unchecked(s.time[i] = <f32>age);
            tv = span > 0 ? <f32>(age / span) : 1;
            const ld = <f32>local;
            let vx = unchecked(s.vx[i]) + gravity.x * ld;
            let vy = unchecked(s.vy[i]) + gravity.y * ld;
            let vz = unchecked(s.vz[i]) + gravity.z * ld;
            const texDamp = curveAt(dampCurve, tv);
            if (dampMax + texDamp > 0) {
                const damp = texDamp * lerp(dampMin, dampMax, unchecked(s.dampRand[i]));
                // (no damping leaves the velocity as it is; Godot
                // normalises and scales it back, the same to a rounding)
                if (damp != 0) {
                    const len = Mathf.sqrt(vx * vx + vy * vy + vz * vz);
                    const v = len - damp * ld;
                    if (v < 0 || len == 0) {
                        vx = 0;
                        vy = 0;
                        vz = 0;
                    } else {
                        const k = v / len;
                        vx *= k;
                        vy *= k;
                        vz *= k;
                    }
                }
            }
            unchecked(s.vx[i] = vx);
            unchecked(s.vy[i] = vy);
            unchecked(s.vz[i] = vz);
            const base = curveAt(angleCurve, tv) * lerp(angleMin, angleMax, unchecked(s.angleRand[i]));
            const turn = <f32>age * curveAt(angVelCurve, tv) * lerp(angVelMin, angVelMax, unchecked(s.angVelRand[i]));
            unchecked(s.angle[i] = toRadians(base + turn));
        }

        // The colour: (the ramp at tv, or white) x color, turned by the hue
        // variation (hue.as), x the tint (Godot's base_color x
        // start_color_rand).
        let cr = color.x;
        let cg = color.y;
        let cb = color.z;
        let ca = color.w;
        if (ramp != null) {
            const rc = ramp.sample(tv);
            cr *= rc.x;
            cg *= rc.y;
            cb *= rc.z;
            ca *= rc.w;
        }
        // (no hue curve counts 1, as GPUParticles3D's process material
        // reads it; Godot's CPUParticles3D counts 0, so that its
        // hue_variation does nothing without a curve; without one the
        // turn is the particle's own all its life: its cosine and sine
        // kept, see huesKept, at every emission whether a curve is set or
        // not)
        if (restart) keepHue(s, i);
        let rgb: Vec3;
        if (hueCurve != null) {
            const hue = <f32>(<f64>hueCurve.sampleBaked(tv) * TAU * <f64>lerp(hueMin, hueMax, unchecked(s.hueRand[i])));
            rgb = hueRotate(Vec3(cr, cg, cb), hue);
        } else {
            rgb = hueRotateBy(Vec3(cr, cg, cb), unchecked(s.hueCos[i]), unchecked(s.hueSin[i]));
        }
        unchecked(s.r[i] = rgb.x * unchecked(s.tr[i]));
        unchecked(s.g[i] = rgb.y * unchecked(s.tg[i]));
        unchecked(s.b[i] = rgb.z * unchecked(s.tb[i]));
        unchecked(s.a[i] = ca * unchecked(s.ta[i]));

        // The scale: its curves at tv x lerp(scale_amount_min, max), at
        // least CMP_EPSILON on each axis.
        let tx: f32 = 1;
        let ty: f32 = 1;
        let tz: f32 = 1;
        if (split) {
            tx = curveAt(curveX, tv);
            ty = curveAt(curveY, tv);
            tz = curveAt(curveZ, tv);
        } else if (scaleCurve != null) {
            tx = scaleCurve.sampleBaked(tv);
            ty = tx;
            tz = tx;
        }
        const amount = lerp(scaleMin, scaleMax, unchecked(s.scaleRand[i]));
        const sx = tx * amount;
        const sy = ty * amount;
        const sz = tz * amount;
        unchecked(s.sx[i] = sx < CMP_EPSILON ? CMP_EPSILON : sx);
        unchecked(s.sy[i] = sy < CMP_EPSILON ? CMP_EPSILON : sy);
        unchecked(s.sz[i] = sz < CMP_EPSILON ? CMP_EPSILON : sz);

        // It moves by its velocity over its part of the step.
        const ld = <f32>local;
        unchecked(s.px[i] = unchecked(s.px[i]) + unchecked(s.vx[i]) * ld);
        unchecked(s.py[i] = unchecked(s.py[i]) + unchecked(s.vy[i]) * ld);
        unchecked(s.pz[i] = unchecked(s.pz[i]) + unchecked(s.vz[i]) * ld);
        should = true;
        changed = true;
        alive++;
    }
    s.alive = alive;
    if (changed) s.version++;
    // Godot's: the cycle has begun (its time not about 0) and nothing is
    // left to simulate.
    if (Math.abs(time) >= <f64>CMP_EPSILON && s.emitterActive && !should) {
        s.emitterActive = false;
        if (node.oneShot) s.finishedPending = true;
        changed = true;
    }
    return changed;
}

// The cosine and sine of particle `i`'s hue turn without a curve:
// lerp(hue_variation_min, max, its draw) of a turn.
function keepHue(s: ParticleState, i: i32): void {
    const hue = <f32>(TAU * <f64>lerp(s.hueMin, s.hueMax, unchecked(s.hueRand[i])));
    unchecked(s.hueCos[i] = hue == 0 ? <f32>1 : cosf(hue));
    unchecked(s.hueSin[i] = hue == 0 ? <f32>0 : sinf(hue));
}

// The kept turns are for `min` and `max`: made again for every particle
// when either changed (a key or a binding moved one), so a turn is always
// the one Godot would work out this step. Allocates nothing.
function huesKept(s: ParticleState, min: f32, max: f32): void {
    if (s.hueMin == min && s.hueMax == max) return;
    s.hueMin = min;
    s.hueMax = max;
    for (let i = 0; i < s.capacity; i++) keepHue(s, i);
}

// Particle `i` emitted again (Godot's restart branch; the draws in the
// header's order). Its angle is its curve's at 0 times its angle; its
// colour and scale follow in the step.
// The rotation of the emitter's transform `emitter`, as Godot's
// Basis::orthonormalize leaves its basis (Gram-Schmidt from X, then Y),
// Z made from X and Y so a mirrored emitter turns rather than mirrors (a
// quaternion holds no reflection). The identity for a degenerate basis.
function emissionRotation(emitter: Mat4): Quat {
    const cx = emitter.xAxis.truncate();
    const cy = emitter.yAxis.truncate();
    const lx = cx.length();
    if (!(lx > DEGENERATE_AXIS)) return Quat(0, 0, 0, 1);
    const x = cx / lx;
    const yo = cy - x * x.dot(cy);
    const ly = yo.length();
    if (!(ly > DEGENERATE_AXIS)) return Quat(0, 0, 0, 1);
    const y = yo / ly;
    return Quat.fromRotationAxes(x, y, x.cross(y));
}
const DEGENERATE_AXIS: f32 = 1e-6;

function spawn(node: CPUParticles3D, s: ParticleState, i: i32, emitter: Mat4, world: bool, worker: i32): void {
    const seed = particleSeed(s.emitterSeed, i, s.cycle);
    const rng = rngOf(worker);
    rng.seed(seed);
    unchecked(s.seed[i] = seed);
    unchecked(s.active[i] = 1);
    const angleRand = rng.next();
    unchecked(s.angleRand[i] = angleRand);
    unchecked(s.scaleRand[i] = rng.next());
    unchecked(s.hueRand[i] = rng.next());
    let start = Vec4(1, 1, 1, 1);
    const initial = node.colorInitialRamp;
    if (initial != null) start = initial.sample(rng.next());
    let vel = spreadDirection(rng, node.direction, node.spread, node.flatness)
        * lerp(node.initialVelocityMin, node.initialVelocityMax, rng.next());
    const factor = 1 - rng.next() * node.lifetimeRandomness;
    unchecked(s.time[i] = 0);
    unchecked(s.lifetime[i] = node.lifetime * factor);
    unchecked(s.angle[i] = toRadians(curveAt(node.angleCurve, 0) * lerp(node.angleMin, node.angleMax, angleRand)));
    let pos = Vec3(0, 0, 0);
    let tint = start;
    const shape = node.emissionShape;
    if (shape == EMISSION_SPHERE) {
        pos = spherePoint(rng, node.emissionSphereRadius);
    } else if (shape == EMISSION_SPHERE_SURFACE) {
        pos = sphereSurfacePoint(rng, node.emissionSphereRadius);
    } else if (shape == EMISSION_BOX) {
        pos = boxPoint(rng, node.emissionBoxExtents);
    } else if (shape == EMISSION_POINTS || shape == EMISSION_DIRECTED_POINTS) {
        const own = node.emissionPoints.length > 0;
        const pts = own ? node.emissionPoints : s.points;
        const pc = pts.length / 3;
        if (pc > 0) {
            const k = pointIndex(rng, pc);
            pos = Vec3(<f32>unchecked(pts[k * 3]), <f32>unchecked(pts[k * 3 + 1]), <f32>unchecked(pts[k * 3 + 2]));
            const nrm = own ? node.emissionNormals : s.normals;
            // (Godot uses the normals and the colours only when there are
            // as many as points)
            if (shape == EMISSION_DIRECTED_POINTS && nrm.length == pts.length) {
                const nv = Vec3(<f32>unchecked(nrm[k * 3]), <f32>unchecked(nrm[k * 3 + 1]), <f32>unchecked(nrm[k * 3 + 2]));
                vel = alongNormal(nv, vel);
            }
            const cols = node.emissionColors;
            if (cols.length == pc * 4) {
                tint = Vec4(start.x * <f32>unchecked(cols[k * 4]), start.y * <f32>unchecked(cols[k * 4 + 1]),
                    start.z * <f32>unchecked(cols[k * 4 + 2]), start.w * <f32>unchecked(cols[k * 4 + 3]));
            }
        }
    } else if (shape == EMISSION_RING) {
        pos = ringPoint(rng, node.emissionRingAxis, node.emissionRingHeight, node.emissionRingRadius,
            node.emissionRingInnerRadius, node.emissionRingConeAngle);
    }
    unchecked(s.dampRand[i] = rng.next());
    unchecked(s.angVelRand[i] = rng.next());
    let q = Quat(0, 0, 0, 1);
    if (world) {
        vel = emitter.transformVector3(vel);
        pos = emitter.transformPoint3(pos);
        q = emissionRotation(emitter);
    }
    unchecked(s.qx[i] = q.x);
    unchecked(s.qy[i] = q.y);
    unchecked(s.qz[i] = q.z);
    unchecked(s.qw[i] = q.w);
    unchecked(s.px[i] = pos.x);
    unchecked(s.py[i] = pos.y);
    unchecked(s.pz[i] = pos.z);
    unchecked(s.vx[i] = vel.x);
    unchecked(s.vy[i] = vel.y);
    unchecked(s.vz[i] = vel.z);
    unchecked(s.tr[i] = tint.x);
    unchecked(s.tg[i] = tint.y);
    unchecked(s.tb[i] = tint.z);
    unchecked(s.ta[i] = tint.w);
}

// Every CPUParticles3D of `walked` (a tree's walk) that is visible in its
// tree, advanced `seconds`, each at its global transform. Returns how many
// changed. Allocates nothing once their states are made.
export function advanceTreeParticles(walked: Array<SceneNode>, seconds: f64): i32 {
    // (the emitters and their transforms first, from the tree, then
    // advanced as a job: an emitter a unit)
    const job = treeEmitters;
    job.clear();
    for (let i = 0; i < walked.length; i++) {
        const n = unchecked(walked[i]);
        const isParticles = n instanceof CPUParticles3D;
        if (!isParticles || !n.visibleInTree()) continue;
        job.add(n as CPUParticles3D, n.global(), i);
    }
    job.run(seconds);
    let changed = 0;
    for (let k = 0; k < job.count; k++) if (unchecked(job.changed[k])) changed++;
    return changed;
}

// Emitters advanced as a job (jobs.as): an emitter a unit, each at the
// transform it was given and in its worker's random stream, what it did in
// `changed`. Every emitter's particles are its own (its ParticleState and
// its node's `emitting`), so the job writes each one's alone. What a unit
// does not do: read the tree (the transforms and the visibility are taken
// before the run, in the tree's order) or emit `finished` (after it, in
// the emitters' order: runtime/feature_particles.as). Keeps its storage.
export class EmitterJob extends Job {
    emitters: Array<CPUParticles3D> = [];
    globals: Array<Mat4> = [];
    // Where each one came from (an index of the caller's).
    from: Array<i32> = [];
    changed: Array<bool> = [];
    count: i32 = 0;
    seconds: f64 = 0;

    clear(): void {
        this.count = 0;
    }

    add(node: CPUParticles3D, global: Mat4, from: i32): void {
        const k = this.count;
        if (k == this.emitters.length) {
            this.emitters.push(node);
            this.globals.push(global);
            this.from.push(from);
            this.changed.push(false);
        } else {
            unchecked(this.emitters[k] = node);
            unchecked(this.globals[k] = global);
            unchecked(this.from[k] = from);
        }
        this.count = k + 1;
    }

    // Each one advanced `seconds` (the arrays keep the last run's nodes
    // until the next run puts others in their places).
    run(seconds: f64): void {
        this.seconds = seconds;
        for (let k = 0; k < this.count; k++) unchecked(this.changed[k] = false);
        const ex = jobs();
        while (rngs.length < ex.workers()) rngs.push(new ParticleRandom());
        ex.run(this, this.count, 1);
    }

    runUnit(unit: i32, begin: i32, end: i32, worker: i32): void {
        for (let k = begin; k < end; k++) {
            const r = advanceParticles(unchecked(this.emitters[k]), unchecked(this.globals[k]), this.seconds, worker);
            unchecked(this.changed[k] = r);
        }
    }
}

const treeEmitters = new EmitterJob();

// The CPUParticles3D nodes of `walked`, in its order, into `out` (cleared
// first); their count.
export function particleEmitters(walked: Array<SceneNode>, out: Array<CPUParticles3D>): i32 {
    out.length = 0;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isParticles = n instanceof CPUParticles3D;
        if (isParticles) out.push(n as CPUParticles3D);
    }
    return out.length;
}
