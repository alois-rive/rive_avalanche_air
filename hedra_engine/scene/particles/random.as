// The particles' random numbers (milestone 35): deterministic from a seed,
// so that the same scene simulated to the same time gives the same
// particles, byte for byte, in every tool and every host (goldens, built
// projects, the editor). Godot's CPUParticles3D draws from the global
// generator (or, with use_fixed_seed, a generator seeded once), so the
// pattern depends on what else drew; here every particle has a stream of
// its own, seeded at its emission from the emitter's seed, its index and
// its cycle, and every random value of its life comes from that stream in
// a fixed order (sim.as says which). The emission time's jitter uses
// Godot's own idhash of the cycle and index, as Godot's does.
//
// The generator is Godot's rand_from_seed (Park and Miller's minimal
// standard, as CPUParticles3D's), which gives 16 bits a draw; that is
// what the particles need and keeps the numbers Godot's. Allocates
// nothing.

// Godot's idhash (cpu_particles_3d.cpp): a 32-bit integer mix.
export function idhash(x: u32): u32 {
    let v = x;
    v = ((v >> 16) ^ v) * 0x45d9f3b;
    v = ((v >> 16) ^ v) * 0x45d9f3b;
    v = (v >> 16) ^ v;
    return v;
}

// The seed of particle `index`'s emission in cycle `cycle` of an emitter
// whose seed is `emitter`.
export function particleSeed(emitter: u32, index: i32, cycle: i32): u32 {
    const s = idhash(emitter ^ idhash(<u32>index * 0x9e3779b1 + <u32>cycle * 0x85ebca6b));
    return s == 0 ? 305420679 : s;
}

// The seed an emitter draws from: `seed` with use_fixed_seed; else made
// from the node's path in its tree (`path`, as SceneNode.pathFromRoot
// gives it), so two emitters of one scene differ; then the restarts so far
// mixed in, so each new emission differs (0 restarts: the first).
export function emitterSeed(fixed: bool, seed: i64, path: string, restarts: i32): u32 {
    return emitterSeedHashed(fixed, seed, fixed ? 0 : pathHash(path), restarts);
}

// emitterSeed with the path already hashed (pathHash): what the
// simulation calls, so that a restart builds no path string.
export function emitterSeedHashed(fixed: bool, seed: i64, hashedPath: u32, restarts: i32): u32 {
    let base: u32 = fixed ? <u32>seed : hashedPath;
    if (restarts > 0 && !fixed) base = idhash(base ^ idhash(<u32>restarts));
    return base;
}

// The seed an emission draws from: `base` (emitterSeed's) with the
// emissions begun again after the emitter stopped mixed in when
// use_fixed_seed is off, so a burst set off again after the last one ended
// differs from it, as Godot's does (0 emissions, or a fixed seed: `base`).
// The constant keeps an emission's mix apart from a restart's.
export function emissionSeed(base: u32, fixed: bool, emissions: i32): u32 {
    if (emissions <= 0 || fixed) return base;
    return idhash(base ^ idhash(<u32>emissions * 0x27d4eb2f + 0x165667b1));
}

// FNV-1a over the path's UTF-16 code units.
export function pathHash(path: string): u32 {
    let h: u32 = 2166136261;
    for (let i = 0; i < path.length; i++) {
        h ^= <u32>path.charCodeAt(i);
        h *= 16777619;
    }
    return h;
}

// One particle's stream (Godot's rand_from_seed, kept in `state`).
export class ParticleRandom {
    state: u32 = 305420679;

    seed(s: u32): void {
        this.state = s == 0 ? 305420679 : s;
    }

    // A number in 0 to 1, 1 included (Godot's: (seed % 65536) / 65535).
    next(): f32 {
        let s = <i32>this.state;
        if (s == 0) s = 305420679;
        const k = s / 127773;
        s = 16807 * (s - k * 127773) - 2836 * k;
        if (s < 0) s += 2147483647;
        this.state = <u32>s;
        return <f32>(<f64>(this.state % 65536) / 65535.0);
    }

    // A number between `lo` and `hi`.
    range(lo: f32, hi: f32): f32 {
        const t = this.next();
        return lo + (hi - lo) * t;
    }
}

// Godot's jitter of an emission's phase (randomness), from the cycle and
// the index: 0 to 1.
export function phaseJitter(cycle: i32, amount: i32, index: i32): f32 {
    const s = <u32>cycle * <u32>amount + <u32>index;
    return <f32>(<f64>(idhash(s) % 65536) / 65536.0);
}
