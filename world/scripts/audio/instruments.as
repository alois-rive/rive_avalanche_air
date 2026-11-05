// The music's tonal instruments (docs/AUDIO.md, section 5): the reese bass
// and its sub, the chord stabs, the pad, the arp with its dotted-8th delay,
// the riser. Each renders a block at the SPU's rate into the music's buses.
// The drums, the impact and the swells are voices of the music's pool
// (sequencer.as).
import { BLOCK, CONTROL_RATE, SPU_INV_RATE, SPU_RATE, Rng, Saw, Svf, decayMul, midiToHz, polyBlep, sinTurn, smoothCoef, softClip } from "./dsp";
import { Bus } from "./voices";

const CENT9: f32 = 1.0052124;     // 2^(9/1200)
const CENT7: f32 = 1.0040515;     // 2^(7/1200)

// ---- the reese: two saws detuned +-9 cents, a 24 dB low-pass, a sub ----------
export class Reese {
    s1: Saw = new Saw();
    s2: Saw = new Saw();
    s3: Saw = new Saw();
    subPh: f32 = 0;
    freq: f32 = 87.3;
    target: f32 = 87.3;
    glide: f32 = 1;
    gate: bool = false;
    env: f32 = 0;
    atk: f32 = 0;
    rel: f32 = 0;
    lp1: Svf = new Svf();
    lp2: Svf = new Svf();
    cutoff: f32 = 600;
    reeseOn: f32 = 0;      // smoothed section flags
    subOn: f32 = 0;
    reeseWant: f32 = 0;
    subWant: f32 = 0;
    kFlag: f32 = 0;
    gain: f32 = 0.5;
    subGain: f32 = 0.33;
    pump: f32 = 0;
    pumpHit: f32 = 0;
    pumpMul: f32 = 0;
    duckPrev: f32 = 1;

    constructor() {
        this.pumpMul = Mathf.exp(-<f32>BLOCK / (0.08 * SPU_RATE));
        this.atk = SPU_INV_RATE / 0.004;
        this.rel = decayMul(0.06, SPU_RATE);
        this.kFlag = smoothCoef(0.05, CONTROL_RATE);
        this.s2.ph = 0.37;
        this.s3.ph = 0.71;
    }

    noteOn(note: i32, glide: bool): void {
        this.target = midiToHz(<f32>note);
        if (!glide || !this.gate) {
            this.freq = this.target;
            this.glide = 0;
        } else {
            this.glide = Mathf.exp(-<f32>BLOCK / (0.035 * SPU_RATE));
        }
        this.gate = true;
    }

    noteOff(): void {
        this.gate = false;
    }

    @unchecked
    render(bus: Bus, sub: StaticArray<f32>): void {
        this.reeseOn += this.kFlag * (this.reeseWant - this.reeseOn);
        this.subOn += this.kFlag * (this.subWant - this.subOn);
        if (this.env < 0.00005 && !this.gate) return;
        this.freq = this.target + (this.freq - this.target) * this.glide;
        const f = this.freq;
        this.s1.dt = f * CENT9 * SPU_INV_RATE;
        this.s2.dt = f / CENT9 * SPU_INV_RATE;
        this.s3.dt = f * 2.002 * SPU_INV_RATE;
        const sdt = f * 0.5 * SPU_INV_RATE;
        this.lp1.set(Mathf.round(this.cutoff), 1.1);
        this.lp2.set(Mathf.round(this.cutoff * 1.05), 0.75);
        // the kick pumps the bass (a side-chain duck: 3 ms down, 80 ms back),
        // its gain ramped across the block
        if (this.pumpHit > 0) {
            this.pump += 0.6 * (this.pumpHit - this.pump);
            if (this.pump >= this.pumpHit * 0.9) this.pumpHit = 0;
        } else {
            this.pump *= this.pumpMul;
        }
        const d0 = this.duckPrev;
        const d1 = 1 - 0.45 * this.pump;
        this.duckPrev = d1;
        const dStep = (d1 - d0) / <f32>BLOCK;
        let duck = d0;
        const rg = this.reeseOn * this.gain;
        const sg = this.subOn * this.subGain;
        const bl = bus.l;
        const br = bus.r;
        for (let i = 0; i < BLOCK; i++) {
            if (this.gate) {
                if (this.env < 1) {
                    this.env += this.atk;
                    if (this.env > 1) this.env = 1;
                }
            } else {
                this.env *= this.rel;
            }
            duck += dStep;
            const e = this.env * duck;
            const a = this.s1.tick();
            const b = this.s2.tick();
            const c = this.s3.tick();
            let x = softClip((a + b + 0.3 * c) * 0.9);
            this.lp1.tick(x);
            this.lp2.tick(this.lp1.lp);
            const y = this.lp2.lp * e * rg;
            bl[i] += y;
            br[i] += y;
            this.subPh += sdt;
            if (this.subPh >= 1) this.subPh -= 1;
            sub[i] += sinTurn(this.subPh) * e * sg;
        }
    }
}

// ---- the stabs: a minor-9th chord of saws through a resonant low-pass ------------
export class Stabs {
    saws: Array<Saw> = new Array<Saw>();
    env: f32 = 0;
    mul: f32 = 0;
    atk: f32 = 0;
    attacking: bool = false;
    lpL: Svf = new Svf();
    lpR: Svf = new Svf();
    fc: f32 = 4000;
    fcMul: f32 = 0;
    vel: f32 = 1;
    gain: f32 = 0.2;

    constructor() {
        for (let i = 0; i < 5; i++) {
            const s = new Saw();
            s.ph = <f32>i * 0.21;
            this.saws.push(s);
        }
        this.mul = decayMul(0.22, SPU_RATE);
        this.atk = SPU_INV_RATE / 0.002;
        this.fcMul = Mathf.exp(-<f32>BLOCK / (0.05 * SPU_RATE));
    }

    trigger(notes: StaticArray<i32>, base: i32, vel: f32): void {
        for (let i = 0; i < 5; i++) {
            this.saws[i].dt = midiToHz(<f32>(notes[base + i] + 12)) * SPU_INV_RATE;
        }
        this.vel = vel;
        this.attacking = true;
        this.fc = 5200 * vel;
    }

    @unchecked
    render(bus: Bus): void {
        if (this.env < 0.0001 && !this.attacking) return;
        this.fc = 650 + (this.fc - 650) * this.fcMul;
        const fcr = Mathf.round(this.fc / 20) * 20;
        this.lpL.set(fcr, 2.6);
        this.lpR.set(fcr, 2.6);
        const g = this.gain * this.vel;
        const s0 = this.saws[0];
        const s1 = this.saws[1];
        const s2 = this.saws[2];
        const s3 = this.saws[3];
        const s4 = this.saws[4];
        const bl = bus.l;
        const br = bus.r;
        const bs = bus.send;
        for (let i = 0; i < BLOCK; i++) {
            if (this.attacking) {
                this.env += this.atk;
                if (this.env >= 1) {
                    this.env = 1;
                    this.attacking = false;
                }
            } else {
                this.env *= this.mul;
            }
            const a = s0.tick();
            const b = s1.tick();
            const c = s2.tick();
            const d = s3.tick();
            const e = s4.tick();
            this.lpL.tick(a + c * 0.8 + e);
            this.lpR.tick(b + c * 0.8 + d);
            const yl = this.lpL.lp * this.env * g;
            const yr = this.lpR.lp * this.env * g;
            bl[i] += yl;
            br[i] += yr;
            bs[i] += (yl + yr) * 0.3;
        }
    }
}

// ---- the pad: four notes of the chord, two detuned saws each, slow, low-passed ----
export class Pad {
    saws: Array<Saw> = new Array<Saw>();
    hz: StaticArray<f32> = new StaticArray<f32>(4);
    level: f32 = 0;
    want: f32 = 0;
    kUp: f32 = 0;
    kDown: f32 = 0;
    lpL: Svf = new Svf();
    lpR: Svf = new Svf();
    lfo: f32 = 0;
    gain: f32 = 0.12;

    constructor() {
        for (let i = 0; i < 8; i++) {
            const s = new Saw();
            s.ph = <f32>((i * 37) % 100) / 100;
            this.saws.push(s);
        }
        this.kUp = smoothCoef(0.6, CONTROL_RATE);
        this.kDown = smoothCoef(0.9, CONTROL_RATE);
        for (let i = 0; i < 4; i++) this.hz[i] = 220;
    }

    chord(notes: StaticArray<i32>, base: i32): void {
        // the chord's 1st, 3rd, 4th and 5th notes: an open voicing
        this.hz[0] = midiToHz(<f32>notes[base]);
        this.hz[1] = midiToHz(<f32>notes[base + 2]);
        this.hz[2] = midiToHz(<f32>notes[base + 3]);
        this.hz[3] = midiToHz(<f32>notes[base + 4]);
    }

    @unchecked
    render(bus: Bus): void {
        this.level += (this.want > this.level ? this.kUp : this.kDown) * (this.want - this.level);
        if (this.level < 0.0005) return;
        for (let i = 0; i < 4; i++) {
            const f = this.hz[i] * SPU_INV_RATE;
            const a = this.saws[2 * i];
            const b = this.saws[2 * i + 1];
            // glide to the new chord
            const ta = f * CENT7;
            const tb = f / CENT7;
            a.dt += 0.08 * (ta - a.dt);
            b.dt += 0.08 * (tb - b.dt);
        }
        this.lfo += 0.11 * <f32>BLOCK * SPU_INV_RATE;
        if (this.lfo >= 1) this.lfo -= 1;
        const fc = Mathf.round(1300 + 500 * sinTurn(this.lfo));
        this.lpL.set(fc, 0.9);
        this.lpR.set(fc * 1.04, 0.9);
        const g = this.level * this.gain;
        const bl = bus.l;
        const br = bus.r;
        const bs = bus.send;
        const s0 = this.saws[0];
        const s1 = this.saws[1];
        const s2 = this.saws[2];
        const s3 = this.saws[3];
        const s4 = this.saws[4];
        const s5 = this.saws[5];
        const s6 = this.saws[6];
        const s7 = this.saws[7];
        for (let i = 0; i < BLOCK; i++) {
            const l = s0.tick() + s2.tick() + s4.tick() + s6.tick();
            const r = s1.tick() + s3.tick() + s5.tick() + s7.tick();
            this.lpL.tick(l);
            this.lpR.tick(r);
            const yl = this.lpL.lp * g;
            const yr = this.lpR.lp * g;
            bl[i] += yl;
            br[i] += yr;
            bs[i] += (yl + yr) * 0.4;
        }
    }
}

// ---- the arp: a square lead in 16ths, a dotted-8th ping-pong delay ---------------
const DL: i32 = 16384;
const DL_MASK: i32 = 16383;

export class Arp {
    ph: f32 = 0;
    dt: f32 = 0;
    env: f32 = 0;
    mul: f32 = 0;
    atk: f32 = 0;
    attacking: bool = false;
    vel: f32 = 1;
    lp: Svf = new Svf();
    delay: StaticArray<f32> = new StaticArray<f32>(DL);
    pos: i32 = 0;
    delaySamples: i32 = 5837;     // a dotted 8th at 170 BPM
    gain: f32 = 0.11;
    wet: f32 = 0.45;
    tail: i32 = 0;

    constructor() {
        this.mul = decayMul(0.2, SPU_RATE);
        this.atk = SPU_INV_RATE / 0.002;
        this.lp.set(3800, 0.8);
    }

    note(midi: i32, vel: f32): void {
        this.dt = midiToHz(<f32>midi) * SPU_INV_RATE;
        this.vel = vel;
        this.attacking = true;
        this.tail = <i32>(SPU_RATE * 2.5);
    }

    @unchecked
    render(bus: Bus): void {
        if (this.tail <= 0) return;
        this.tail -= BLOCK;
        const g = this.gain * this.vel;
        const d = this.delay;
        const D = this.delaySamples;
        const bl = bus.l;
        const br = bus.r;
        const bs = bus.send;
        let pos = this.pos;
        for (let i = 0; i < BLOCK; i++) {
            if (this.attacking) {
                this.env += this.atk;
                if (this.env >= 1) {
                    this.env = 1;
                    this.attacking = false;
                }
            } else {
                this.env *= this.mul;
            }
            const dt = this.dt;
            let ph = this.ph + dt;
            if (ph >= 1) ph -= 1;
            this.ph = ph;
            // a band-limited pulse, width 0.35
            let ph2 = ph + 0.65;
            if (ph2 >= 1) ph2 -= 1;
            const sq = (2 * ph - 1 - polyBlep(ph, dt)) - (2 * ph2 - 1 - polyBlep(ph2, dt));
            this.lp.tick(sq);
            const dry = this.lp.lp * this.env * g;
            // ping-pong: the first echo right, the second left
            const e1 = d[(pos - D) & DL_MASK];
            const e2 = d[(pos - 2 * D) & DL_MASK];
            d[pos & DL_MASK] = dry + e2 * 0.42;
            bl[i] += dry + e2 * this.wet;
            br[i] += dry + e1 * this.wet;
            bs[i] += dry * 0.25;
            pos = (pos + 1) & DL_MASK;
        }
        this.pos = pos;
    }
}

// ---- the riser: noise and a saw sweeping up, the high-pass opening ---------------
export class Riser {
    active: bool = false;
    hold: bool = false;
    p: f32 = 0;
    inc: f32 = 0;
    fade: f32 = 1;
    stopping: bool = false;
    saw: Saw = new Saw();
    saw2: Saw = new Saw();
    hp: Svf = new Svf();
    bp: Svf = new Svf();
    rng: Rng = new Rng();
    trem: f32 = 0;
    gain: f32 = 0.22;

    constructor() {
        this.rng.seed(4242, 11);
    }

    start(seconds: f32, from: f32): void {
        this.active = true;
        this.stopping = false;
        this.hold = false;
        this.fade = 1;
        this.p = from;
        this.inc = <f32>BLOCK / (seconds * SPU_RATE);
    }

    // stay at the top until stopped (the mega-jump's hang)
    holdTop(): void {
        if (!this.active) this.start(0.5, 0.85);
        this.hold = true;
    }

    stop(): void {
        if (this.active) this.stopping = true;
    }

    @unchecked
    render(bus: Bus): void {
        if (!this.active) return;
        this.p += this.inc;
        if (this.p >= 1) {
            this.p = 1;
            if (!this.hold) this.stopping = true;
        }
        if (this.stopping) {
            this.fade -= <f32>BLOCK / (0.04 * SPU_RATE);
            if (this.fade <= 0) {
                this.active = false;
                this.fade = 0;
                return;
            }
        }
        const p = this.p;
        // 110 Hz to 1,760 Hz, the high-pass from 300 Hz to 6 kHz
        const f = 110 * Mathf.pow(2, 4 * p);
        this.saw.dt = f * SPU_INV_RATE;
        this.saw2.dt = f * 1.5 * SPU_INV_RATE;
        this.hp.set(Mathf.round(300 * Mathf.pow(2, 4.3 * p)), 0.9);
        this.bp.set(Mathf.round(f * 2), 3);
        this.trem += (this.hold && p >= 1 ? 9 : 0) * <f32>BLOCK * SPU_INV_RATE;
        if (this.trem >= 1) this.trem -= 1;
        const tr = this.hold && p >= 1 ? 0.75 + 0.25 * sinTurn(this.trem) : 1;
        const g = this.gain * (0.04 + 0.96 * p * p) * this.fade * tr;
        const bl = bus.l;
        const br = bus.r;
        const bs = bus.send;
        for (let i = 0; i < BLOCK; i++) {
            const w = this.rng.white();
            this.hp.tick(w);
            const s = this.saw.tick() * 0.5 + this.saw2.tick() * 0.3;
            this.bp.tick(s);
            const y = (this.hp.hp * 0.9 + this.bp.bpn() * 0.8 + s * 0.15) * g;
            bl[i] += y;
            br[i] += y;
            bs[i] += y * 0.3;
        }
    }
}
