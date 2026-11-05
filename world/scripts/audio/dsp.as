// The DSP pieces every part of the Spu shares: the polynomial sine, the
// seeded noise, the state-variable filter, the resonator, the soft clip,
// smoothing. Nothing here allocates after construction. docs/AUDIO.md,
// sections 3 and 13.

// The SPU's internal rate: every voice, the board, the music, the voice and
// the reverb render at it; the output is interpolated up from it.
export const SPU_RATE: f32 = 22050;
export const SPU_INV_RATE: f32 = 1.0 / 22050.0;
// One internal block: 28 samples, one ADPCM block, 1.27 ms, the control rate.
export const BLOCK: i32 = 28;
export const CONTROL_RATE: f32 = 22050.0 / 28.0;

// A sine of a phase in turns (1 is a whole cycle), within 7.4e-7 of
// Math.sin for about a quarter of its cost (Rive's threading guide).
// @ts-ignore
@inline
export function sinTurn(turns: f32): f32 {
    let x = turns - floor<f32>(turns + 0.5);
    let a = abs<f32>(x);
    x = copysign<f32>(min<f32>(a, 0.5 - a), x);
    let x2 = x * x;
    return x * (6.28316402 + x2 * (-41.3371429 + x2 * (81.3407669 + x2 * -70.9933929)));
}

// A soft clip: tanh within 2 % up to |x| = 3, then flat.
// @ts-ignore
@inline
export function softClip(x: f32): f32 {
    if (x > 3) return 1;
    if (x < -3) return -1;
    const x2 = x * x;
    return x * (27 + x2) / (27 + 9 * x2);
}

// The one-pole coefficient for a time constant `seconds` at `rate`.
export function smoothCoef(seconds: f32, rate: f32): f32 {
    if (seconds <= 0) return 1;
    return 1 - Mathf.exp(-1 / (seconds * rate));
}

// The per-sample multiplier that decays by 60 dB in `seconds` at `rate`.
export function decayMul(seconds: f32, rate: f32): f32 {
    if (seconds <= 0) return 0;
    return Mathf.exp(-6.9077553 / (seconds * rate));
}

export function dbToGain(db: f32): f32 {
    return Mathf.pow(10, db / 20);
}

export function midiToHz(note: f32): f32 {
    return 440 * Mathf.pow(2, (note - 69) / 12);
}

// PCG32 (O'Neill), seeded per voice by the cue that started it and the run's
// seed: deterministic noise (AUDIO.md, section 9).
export class Rng {
    state: u64 = 0x853c49e6748fea9b;
    inc: u64 = 0xda3e39cb94b95bdb;

    seed(s: u32, stream: u32): void {
        this.state = 0;
        this.inc = ((<u64>stream) << 1) | 1;
        this.next();
        this.state += <u64>s * 0x9E3779B97F4A7C15 + 0x2545F4914F6CDD1D;
        this.next();
    }

    @inline
    next(): u32 {
        const old = this.state;
        this.state = old * 6364136223846793005 + this.inc;
        const xs = <u32>(((old >> 18) ^ old) >> 27);
        const rot = <u32>(old >> 59);
        return (xs >> rot) | (xs << ((0 - rot) & 31));
    }

    // -1..1
    @inline
    white(): f32 {
        return <f32>(<i32>this.next()) * 4.656612873e-10;
    }

    // 0..1
    @inline
    unit(): f32 {
        return <f32>(this.next() >> 8) * 5.9604645e-8;
    }
}

// Pink noise: Paul Kellet's economy filter over white noise.
export class Pink {
    b0: f32 = 0;
    b1: f32 = 0;
    b2: f32 = 0;

    @inline
    tick(w: f32): f32 {
        this.b0 = 0.99765 * this.b0 + w * 0.0990460;
        this.b1 = 0.96300 * this.b1 + w * 0.2965164;
        this.b2 = 0.57000 * this.b2 + w * 1.0526913;
        return (this.b0 + this.b1 + this.b2 + w * 0.1848) * 0.25;
    }

    reset(): void {
        this.b0 = 0;
        this.b1 = 0;
        this.b2 = 0;
    }
}

// The topology-preserving state-variable filter (Zavalishin): low-, band-
// and high-pass from one state, stable under fast modulation. Set the
// coefficients with `set` (it calls tan, so once a block at most).
export class Svf {
    ic1: f32 = 0;
    ic2: f32 = 0;
    a1: f32 = 1;
    a2: f32 = 0;
    a3: f32 = 0;
    k: f32 = 1.4;
    lp: f32 = 0;
    bp: f32 = 0;
    hp: f32 = 0;
    fc: f32 = -1;
    q: f32 = -1;

    set(fc: f32, q: f32): void {
        if (fc == this.fc && q == this.q) return;
        this.fc = fc;
        this.q = q;
        let f = fc;
        if (!(f > 10)) f = 10;
        if (f > 0.47 * SPU_RATE) f = 0.47 * SPU_RATE;
        let qq = q;
        if (!(qq > 0.3)) qq = 0.3;
        const g = Mathf.tan(3.14159265 * f * SPU_INV_RATE);
        this.k = 1 / qq;
        this.a1 = 1 / (1 + g * (g + this.k));
        this.a2 = g * this.a1;
        this.a3 = g * this.a2;
    }

    @inline
    tick(x: f32): void {
        const v3 = x - this.ic2;
        const v1 = this.a1 * this.ic1 + this.a2 * v3;
        const v2 = this.ic2 + this.a2 * this.ic1 + this.a3 * v3;
        this.ic1 = 2 * v1 - this.ic1;
        this.ic2 = 2 * v2 - this.ic2;
        this.lp = v2;
        this.bp = v1;
        this.hp = x - this.k * v1 - v2;
    }

    // the band-pass normalised to unity at its centre
    @inline
    bpn(): f32 {
        return this.k * this.bp;
    }

    reset(): void {
        this.ic1 = 0;
        this.ic2 = 0;
        this.lp = 0;
        this.bp = 0;
        this.hp = 0;
    }
}

// A two-pole resonator (Klatt's): unity gain at DC for the cascade.
export class Reso {
    a: f32 = 1;
    b: f32 = 0;
    c: f32 = 0;
    y1: f32 = 0;
    y2: f32 = 0;

    set(f: f32, bw: f32): void {
        let ff = f;
        if (!(ff > 20)) ff = 20;
        if (ff > 0.45 * SPU_RATE) ff = 0.45 * SPU_RATE;
        const r = Mathf.exp(-3.14159265 * bw * SPU_INV_RATE);
        this.c = -r * r;
        this.b = 2 * r * Mathf.cos(6.2831853 * ff * SPU_INV_RATE);
        this.a = 1 - this.b - this.c;
    }

    @inline
    tick(x: f32): f32 {
        const y = this.a * x + this.b * this.y1 + this.c * this.y2;
        this.y2 = this.y1;
        this.y1 = y;
        return y;
    }

    reset(): void {
        this.y1 = 0;
        this.y2 = 0;
    }
}

// The PolyBLEP correction for a saw or square edge at phase t (turns),
// step dt (turns a sample).
// @ts-ignore
@inline
export function polyBlep(t: f32, dt: f32): f32 {
    if (t < dt) {
        const x = t / dt;
        return x + x - x * x - 1;
    }
    if (t > 1 - dt) {
        const x = (t - 1) / dt;
        return x * x + x + x + 1;
    }
    return 0;
}

// A band-limited saw, -1..1, its phase in turns.
export class Saw {
    ph: f32 = 0;
    dt: f32 = 0;

    @inline
    tick(): f32 {
        const t = this.ph;
        let s = 2 * t - 1 - polyBlep(t, this.dt);
        this.ph = t + this.dt;
        if (this.ph >= 1) this.ph -= 1;
        return s;
    }
}

// ADPCM grit (AUDIO.md, section 3): re-quantises a block of 28 samples to 4
// bits with a block shift and the SPU's first-order predictor, as the
// PlayStation's sample format did, mixed in by `amount`. `prev` is the
// previous decoded sample, returned updated.
export function adpcmGrit(buf: StaticArray<f32>, off: i32, n: i32, amount: f32, prev: f32): f32 {
    if (amount <= 0) return buf[off + n - 1];
    // pick the predictor (none or first order) with the smaller residual
    let m0: f32 = 0;
    let m1: f32 = 0;
    let p = prev;
    for (let i = 0; i < n; i++) {
        const x = unchecked(buf[off + i]);
        const r0 = abs<f32>(x);
        const r1 = abs<f32>(x - 0.9375 * p);
        if (r0 > m0) m0 = r0;
        if (r1 > m1) m1 = r1;
        p = x;
    }
    const k: f32 = m1 < m0 ? 0.9375 : 0;
    const m = m1 < m0 ? m1 : m0;
    if (!(m > 1e-7)) return prev;
    // the shift: the power-of-two step that fits the block in -8..7
    let step: f32 = 1.0 / 32768.0;
    while (step * 7 < m && step < 4) step *= 2;
    let d = prev;
    const inv = 1 / step;
    for (let i = 0; i < n; i++) {
        const x = unchecked(buf[off + i]);
        let q = Mathf.round((x - k * d) * inv);
        if (q > 7) q = 7;
        if (q < -8) q = -8;
        d = k * d + q * step;
        unchecked(buf[off + i] = x + amount * (d - x));
    }
    return d;
}
