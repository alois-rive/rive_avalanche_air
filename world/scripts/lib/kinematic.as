// The motion layer's basics, copied from the kart sample's
// (rive_modeler/samples/kart/world/scripts/lib/kinematic.as, docs/
// KINEMATICS.md) without its Box3D world: Avalanche Air's rider collides
// with the course through course_api.as (the snow's height, the obstacles'
// cylinders, the rails' curves), so only the fixed clock, the seeded
// random numbers, the angles and the drawn pose are needed here
// (docs/RIDER.md, section 1).
//
// Numbers are f32 in a fixed order: the same seed and inputs give the same
// bits natively and on the web. Nothing here allocates after construction.

// --- the fixed clock (KINEMATICS.md, section 2) -----------------------

export class FixedClock {
    readonly tick: f32;
    readonly maxTicks: i32;
    readonly clamp: f32;
    acc: f32 = 0;
    private lastAlpha: f32 = 0;

    // A tick of `tick` seconds, at most `maxTicks` a frame (past them the
    // time is dropped: a stall slows the game rather than spiralling), a
    // frame counted as at most `clamp` seconds.
    constructor(tick: f32, maxTicks: i32, clamp: f32 = 0.1) {
        this.tick = tick;
        this.maxTicks = maxTicks;
        this.clamp = clamp;
    }

    // How many ticks this frame runs; alpha() is then the fraction of a
    // tick left over, for drawing between the last two.
    advance(delta: f32): i32 {
        let d = delta;
        if (d > this.clamp) d = this.clamp;
        if (d < 0) d = 0;
        this.acc += d;
        let n = 0;
        // (a hair under a tick counts as one: 1/60 s is two 1/120 s ticks
        // to the last bit, and f32 sums of them must not drop one)
        const eps: f32 = this.tick * <f32>1e-4;
        while (this.acc + eps >= this.tick && n < this.maxTicks) {
            this.acc -= this.tick;
            n++;
        }
        if (this.acc + eps >= this.tick) this.acc = 0;
        if (this.acc < 0) this.acc = 0;
        this.lastAlpha = this.acc / this.tick;
        return n;
    }

    alpha(): f32 {
        return this.lastAlpha;
    }

    reset(): void {
        this.acc = 0;
        this.lastAlpha = 0;
    }
}

// --- seeded random numbers (KINEMATICS.md, section 3) -----------------

// O'Neill's PCG-XSH-RR: 64-bit state, 32-bit output, one stream a use
// (the grind's wobble, the tumble, the spray), so adding one changes no
// other's numbers.
export class Pcg32 {
    state: u64 = 0;
    inc: u64 = 1;

    constructor(seed: u64, stream: u64) {
        this.seed(seed, stream);
    }

    seed(seed: u64, stream: u64): void {
        this.state = 0;
        this.inc = (stream << 1) | 1;
        this.next();
        this.state += seed;
        this.next();
    }

    next(): u32 {
        const old = this.state;
        this.state = old * 6364136223846793005 + this.inc;
        const xorshifted = <u32>(((old >> 18) ^ old) >> 27);
        const rot = <u32>(old >> 59);
        return (xorshifted >> rot) | (xorshifted << ((-rot) & 31));
    }

    // [0, 1) with 24 bits: (next() >>> 8) * 2^-24.
    nextF32(): f32 {
        return <f32>(this.next() >>> 8) * <f32>5.9604644775390625e-8;
    }

    // [-1, 1).
    nextSigned(): f32 {
        return this.nextF32() * 2 - 1;
    }
}

// --- angles and small helpers -------------------------------------------

export const PI_F: f32 = 3.14159265358979;
export const TWO_PI_F: f32 = 6.28318530717959;
export const DEG: f32 = 0.0174532925199433;   // radians a degree
export const RAD: f32 = 57.2957795130823;     // degrees a radian

// An angle into (-pi, pi].
export function wrapAngle(a: f32): f32 {
    let x = a;
    while (x > PI_F) x -= TWO_PI_F;
    while (x <= -PI_F) x += TWO_PI_F;
    return x;
}

export function clampf(v: f32, lo: f32, hi: f32): f32 {
    return v < lo ? lo : (v > hi ? hi : v);
}

// `v` moved towards `target` by at most `step`.
export function approach(v: f32, target: f32, step: f32): f32 {
    if (v < target) return v + step < target ? v + step : target;
    return v - step > target ? v - step : target;
}

export function lerpf(a: f32, b: f32, t: f32): f32 {
    return a + (b - a) * t;
}

export function signf(v: f32): f32 {
    return v > 0 ? <f32>1 : (v < 0 ? <f32>-1 : <f32>0);
}

// --- the drawn pose (KINEMATICS.md, section 5) ---------------------------

// A body's previous and current tick's pose (position and rotation), the
// node written once a frame between them by the clock's alpha.
export class DrawnPose {
    px: f32 = 0;
    py: f32 = 0;
    pz: f32 = 0;
    pqx: f32 = 0;
    pqy: f32 = 0;
    pqz: f32 = 0;
    pqw: f32 = 1;
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;
    qx: f32 = 0;
    qy: f32 = 0;
    qz: f32 = 0;
    qw: f32 = 1;
    // what blend() drew last
    ox: f32 = 0;
    oy: f32 = 0;
    oz: f32 = 0;
    oqx: f32 = 0;
    oqy: f32 = 0;
    oqz: f32 = 0;
    oqw: f32 = 1;

    // The tick's pose becomes the previous one.
    keep(): void {
        this.px = this.x;
        this.py = this.y;
        this.pz = this.z;
        this.pqx = this.qx;
        this.pqy = this.qy;
        this.pqz = this.qz;
        this.pqw = this.qw;
    }

    set(x: f32, y: f32, z: f32, qx: f32, qy: f32, qz: f32, qw: f32): void {
        this.x = x;
        this.y = y;
        this.z = z;
        this.qx = qx;
        this.qy = qy;
        this.qz = qz;
        this.qw = qw;
    }

    // Both poses the same (a respawn, the first frame): nothing to blend.
    snap(): void {
        this.keep();
    }

    // The pose drawn at `alpha` between the previous tick's and this one's,
    // into ox.. and oqx..: the position lerped, the rotation slerped the
    // short way round. True when it differs from what was drawn last.
    blend(alpha: f32): bool {
        const a = alpha < 0 ? <f32>0 : (alpha > 1 ? <f32>1 : alpha);
        const x = this.px + (this.x - this.px) * a;
        const y = this.py + (this.y - this.py) * a;
        const z = this.pz + (this.z - this.pz) * a;
        let bx = this.qx;
        let by = this.qy;
        let bz = this.qz;
        let bw = this.qw;
        let d = this.pqx * bx + this.pqy * by + this.pqz * bz + this.pqw * bw;
        if (d < 0) {
            bx = -bx;
            by = -by;
            bz = -bz;
            bw = -bw;
            d = -d;
        }
        let ka: f32 = 1 - a;
        let kb: f32 = a;
        if (d < 0.9995) {
            const th = Mathf.acos(d);
            const s = Mathf.sin(th);
            ka = Mathf.sin((1 - a) * th) / s;
            kb = Mathf.sin(a * th) / s;
        }
        let qx = this.pqx * ka + bx * kb;
        let qy = this.pqy * ka + by * kb;
        let qz = this.pqz * ka + bz * kb;
        let qw = this.pqw * ka + bw * kb;
        const n = Mathf.sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
        if (n > 0) {
            qx /= n;
            qy /= n;
            qz /= n;
            qw /= n;
        }
        const changed = x != this.ox || y != this.oy || z != this.oz || qx != this.oqx || qy != this.oqy ||
            qz != this.oqz || qw != this.oqw;
        this.ox = x;
        this.oy = y;
        this.oz = z;
        this.oqx = qx;
        this.oqy = qy;
        this.oqz = qz;
        this.oqw = qw;
        return changed;
    }
}
