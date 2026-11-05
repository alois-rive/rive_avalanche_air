// The SPU's voices (docs/AUDIO.md, section 3): a pool of one-shot voices,
// each an oscillator layer (sine, square, saw, triangle, metallic) with a
// pitch envelope and a noise layer (white, pink, brown) through a swept
// state-variable filter, each with an SPU-style envelope (linear attack, a
// hold, an exponential decay), rendered at 22,050 or 11,025 Hz (held), with
// optional ADPCM grit, panned into a bus with a reverb send. The 25th voice
// steals the quietest.
import { BLOCK, SPU_RATE, SPU_INV_RATE, Pink, Rng, Svf, adpcmGrit, decayMul, sinTurn } from "./dsp";

export const WAVE_NONE: i32 = 0;
export const WAVE_SINE: i32 = 1;
export const WAVE_SQUARE: i32 = 2;
export const WAVE_SAW: i32 = 3;
export const WAVE_TRI: i32 = 4;
export const WAVE_METAL: i32 = 5;

export const NOISE_NONE: i32 = 0;
export const NOISE_WHITE: i32 = 1;
export const NOISE_PINK: i32 = 2;
export const NOISE_BROWN: i32 = 3;

export const FILT_NONE: i32 = 0;
export const FILT_LP: i32 = 1;
export const FILT_HP: i32 = 2;
export const FILT_BP: i32 = 3;

export const BUS_MUSIC: i32 = 0;
export const BUS_SFX: i32 = 1;
export const BUS_UI: i32 = 2;

// The six square waves of the 808's cymbal, as ratios of the lowest.
const METAL_RATIO_0: f32 = 1.0;
const METAL_RATIO_1: f32 = 1.4471;
const METAL_RATIO_2: f32 = 1.6170;
const METAL_RATIO_3: f32 = 1.9265;
const METAL_RATIO_4: f32 = 2.5028;
const METAL_RATIO_5: f32 = 2.6637;

export class Bus {
    l: StaticArray<f32> = new StaticArray<f32>(BLOCK);
    r: StaticArray<f32> = new StaticArray<f32>(BLOCK);
    send: StaticArray<f32> = new StaticArray<f32>(BLOCK);

    clear(): void {
        for (let i = 0; i < BLOCK; i++) {
            unchecked(this.l[i] = 0);
            unchecked(this.r[i] = 0);
            unchecked(this.send[i] = 0);
        }
    }
}

export class Envelope {
    level: f32 = 0;
    stage: i32 = 3;     // 0 attack, 1 hold, 2 decay, 3 done
    atkInc: f32 = 1;
    hold: i32 = 0;
    mul: f32 = 0;

    // attack and hold in seconds, decay to -60 dB in seconds
    start(attack: f32, hold: f32, decay: f32): void {
        let a = attack;
        if (a < 0.002) a = 0.002;     // every envelope at least 2 ms (section 11)
        this.atkInc = SPU_INV_RATE / a;
        this.hold = <i32>(hold * SPU_RATE);
        this.mul = decayMul(decay < 0.004 ? 0.004 : decay, SPU_RATE);
        this.level = 0;
        this.stage = 0;
    }

    @inline
    tick(): f32 {
        const s = this.stage;
        if (s == 0) {
            this.level += this.atkInc;
            if (this.level >= 1) {
                this.level = 1;
                this.stage = 1;
            }
        } else if (s == 1) {
            this.hold--;
            if (this.hold <= 0) this.stage = 2;
        } else if (s == 2) {
            this.level *= this.mul;
            if (this.level < 0.0001) {
                this.level = 0;
                this.stage = 3;
            }
        }
        return this.level;
    }

    get done(): bool {
        return this.stage == 3;
    }
}

export class Voice {
    active: bool = false;
    bus: i32 = BUS_SFX;
    delay: i32 = 0;
    age: i32 = 0;
    tag: i32 = 0;             // who started it (a cue kind), for releases
    rng: Rng = new Rng();
    pink: Pink = new Pink();
    brown: f32 = 0;

    // the oscillator layer
    wave: i32 = WAVE_NONE;
    ph: f32 = 0;
    ph1: f32 = 0;
    ph2: f32 = 0;
    ph3: f32 = 0;
    ph4: f32 = 0;
    ph5: f32 = 0;
    freq: f32 = 440;
    freqEnd: f32 = 440;
    pitchMul: f32 = 1;
    pw: f32 = 0.5;
    vibRate: f32 = 0;
    vibDepth: f32 = 0;
    vibPh: f32 = 0;
    toneLevel: f32 = 0;
    toneEnv: Envelope = new Envelope();

    // the noise layer
    noise: i32 = NOISE_NONE;
    noiseLevel: f32 = 0;
    noiseEnv: Envelope = new Envelope();

    // the filter (on the noise, or on both layers when filterBoth)
    filt: i32 = FILT_NONE;
    filterBoth: bool = false;
    fc: f32 = 1000;
    fcEnd: f32 = 1000;
    fcMul: f32 = 1;
    q: f32 = 0.7;
    svf: Svf = new Svf();
    // a second band for metallic sounds (a resonance of the board's clatter)
    svf2: Svf = new Svf();
    fc2: f32 = 0;

    // the voice
    gain: f32 = 1;
    panL: f32 = 0.7071;
    panR: f32 = 0.7071;
    sendAmt: f32 = 0;
    grit: f32 = 0;
    gritPrev: f32 = 0;
    rateDiv: i32 = 1;
    held: f32 = 0;
    tmp: StaticArray<f32> = new StaticArray<f32>(BLOCK);

    loudness(): f32 {
        let a = this.toneEnv.level * this.toneLevel;
        const b = this.noiseEnv.level * this.noiseLevel;
        if (b > a) a = b;
        return a * this.gain;
    }

    reset(seed: u32, stream: u32): void {
        this.active = true;
        this.delay = 0;
        this.age = 0;
        this.tag = 0;
        this.rng.seed(seed, stream);
        this.pink.reset();
        this.brown = 0;
        this.wave = WAVE_NONE;
        this.ph = 0;
        this.ph1 = 0.13;
        this.ph2 = 0.37;
        this.ph3 = 0.59;
        this.ph4 = 0.71;
        this.ph5 = 0.89;
        this.pitchMul = 1;
        this.pw = 0.5;
        this.vibRate = 0;
        this.vibDepth = 0;
        this.vibPh = 0;
        this.toneLevel = 0;
        this.toneEnv.stage = 3;
        this.toneEnv.level = 0;
        this.noise = NOISE_NONE;
        this.noiseLevel = 0;
        this.noiseEnv.stage = 3;
        this.noiseEnv.level = 0;
        this.filt = FILT_NONE;
        this.filterBoth = false;
        this.fcMul = 1;
        this.fc2 = 0;
        this.svf.reset();
        this.svf2.reset();
        this.svf.fc = -1;
        this.svf2.fc = -1;
        this.gain = 1;
        this.panL = 0.7071;
        this.panR = 0.7071;
        this.sendAmt = 0;
        this.grit = 0;
        this.gritPrev = 0;
        this.rateDiv = 1;
        this.held = 0;
    }

    // The oscillator: from `f0` to `f1` Hz with a time constant `glide` s.
    tone(wave: i32, f0: f32, f1: f32, glide: f32, level: f32, attack: f32, hold: f32, decay: f32): Voice {
        this.wave = wave;
        this.freq = f0;
        this.freqEnd = f1;
        this.pitchMul = glide > 0 ? Mathf.exp(-SPU_INV_RATE / glide) : 0;
        this.toneLevel = level;
        this.toneEnv.start(attack, hold, decay);
        return this;
    }

    noiseLayer(kind: i32, level: f32, attack: f32, hold: f32, decay: f32): Voice {
        this.noise = kind;
        this.noiseLevel = level;
        this.noiseEnv.start(attack, hold, decay);
        return this;
    }

    // The filter: from `f0` to `f1` Hz with a time constant `sweep` s.
    filter(kind: i32, f0: f32, f1: f32, sweep: f32, q: f32, both: bool): Voice {
        this.filt = kind;
        this.fc = f0;
        this.fcEnd = f1;
        this.fcMul = sweep > 0 ? Mathf.exp(-1 / (sweep * SPU_RATE / <f32>BLOCK)) : 0;
        this.q = q;
        this.filterBoth = both;
        return this;
    }

    // pan -1 left .. +1 right
    out(gain: f32, pan: f32, send: f32, grit: f32): Voice {
        this.gain = gain;
        const p = (pan + 1) * 0.125;
        this.panL = sinTurn(p + 0.25);
        this.panR = sinTurn(p);
        this.sendAmt = send;
        this.grit = grit;
        return this;
    }

    vibrato(rate: f32, depth: f32): Voice {
        this.vibRate = rate * SPU_INV_RATE;
        this.vibDepth = depth;
        return this;
    }

    @unchecked
    render(bus: Bus): void {
        const n = BLOCK;
        let start = 0;
        if (this.delay > 0) {
            if (this.delay >= n) {
                this.delay -= n;
                return;
            }
            start = this.delay;
            this.delay = 0;
        }
        const tmp = this.tmp;
        for (let i = 0; i < start; i++) tmp[i] = 0;
        // the filter's coefficients once a block
        const filt = this.filt;
        if (filt != FILT_NONE) {
            this.fc = this.fcEnd + (this.fc - this.fcEnd) * this.fcMul;
            this.svf.set(this.fc, this.q);
            if (this.fc2 > 0) this.svf2.set(this.fc2, this.q);
        }
        const wave = this.wave;
        const noise = this.noise;
        const tl = this.toneLevel;
        const nl = this.noiseLevel;
        const both = this.filterBoth;
        const div = this.rateDiv;
        const fEnd = this.freqEnd;
        const pm = this.pitchMul;
        for (let i = start; i < n; i++) {
            if (div > 1 && ((this.age & 1) != 0)) {
                tmp[i] = this.held;
                this.age++;
                // keep the envelopes on the 22 kHz clock
                this.toneEnv.tick();
                this.noiseEnv.tick();
                continue;
            }
            let t: f32 = 0;
            if (wave != WAVE_NONE) {
                const te = this.toneEnv.tick();
                let f = this.freq;
                this.freq = fEnd + (f - fEnd) * pm;
                if (this.vibDepth > 0) {
                    this.vibPh += this.vibRate;
                    if (this.vibPh >= 1) this.vibPh -= 1;
                    f *= 1 + this.vibDepth * sinTurn(this.vibPh);
                }
                const dt = f * SPU_INV_RATE * <f32>div;
                let ph = this.ph + dt;
                ph -= floor<f32>(ph);
                this.ph = ph;
                let o: f32 = 0;
                if (wave == WAVE_SINE) o = sinTurn(ph);
                else if (wave == WAVE_SQUARE) o = ph < this.pw ? 0.7 : -0.7;
                else if (wave == WAVE_SAW) o = 2 * ph - 1;
                else if (wave == WAVE_TRI) o = ph < 0.5 ? 4 * ph - 1 : 3 - 4 * ph;
                else {
                    // metallic: six squares at the 808's inharmonic ratios
                    let p1 = this.ph1 + dt * METAL_RATIO_1; p1 -= floor<f32>(p1); this.ph1 = p1;
                    let p2 = this.ph2 + dt * METAL_RATIO_2; p2 -= floor<f32>(p2); this.ph2 = p2;
                    let p3 = this.ph3 + dt * METAL_RATIO_3; p3 -= floor<f32>(p3); this.ph3 = p3;
                    let p4 = this.ph4 + dt * METAL_RATIO_4; p4 -= floor<f32>(p4); this.ph4 = p4;
                    let p5 = this.ph5 + dt * METAL_RATIO_5; p5 -= floor<f32>(p5); this.ph5 = p5;
                    let m: i32 = (ph < 0.5 ? 1 : -1) + (p1 < 0.5 ? 1 : -1) + (p2 < 0.5 ? 1 : -1)
                        + (p3 < 0.5 ? 1 : -1) + (p4 < 0.5 ? 1 : -1) + (p5 < 0.5 ? 1 : -1);
                    o = <f32>m;
                    o *= 0.16 * METAL_RATIO_0;
                }
                t = o * te * tl;
            }
            let z: f32 = 0;
            if (noise != NOISE_NONE) {
                const ne = this.noiseEnv.tick();
                const w = this.rng.white();
                let s = w;
                if (noise == NOISE_PINK) s = this.pink.tick(w) * 2.5;
                else if (noise == NOISE_BROWN) {
                    this.brown = this.brown * 0.985 + w * 0.15;
                    s = this.brown * 1.6;
                }
                z = s * ne * nl;
            }
            let y: f32;
            if (filt == FILT_NONE) {
                y = t + z;
            } else {
                const x = both ? t + z : z;
                this.svf.tick(x);
                let fy: f32;
                if (filt == FILT_LP) fy = this.svf.lp;
                else if (filt == FILT_HP) fy = this.svf.hp;
                else fy = this.svf.bpn();
                if (this.fc2 > 0) {
                    this.svf2.tick(x);
                    fy += this.svf2.bpn();
                }
                y = both ? fy : t + fy;
            }
            this.held = y;
            tmp[i] = y;
            this.age++;
        }
        if (this.grit > 0) this.gritPrev = adpcmGrit(tmp, 0, n, this.grit, this.gritPrev);
        const g = this.gain;
        const gl = g * this.panL;
        const gr = g * this.panR;
        const gs = g * this.sendAmt;
        const bl = bus.l;
        const br = bus.r;
        const bs = bus.send;
        for (let i = 0; i < n; i++) {
            const y = tmp[i];
            bl[i] += y * gl;
            br[i] += y * gr;
            bs[i] += y * gs;
        }
        if ((wave == WAVE_NONE || this.toneEnv.done) && (noise == NOISE_NONE || this.noiseEnv.done)) {
            this.active = false;
        }
        if (this.age > 10 * 22050) this.active = false;
    }
}

export class VoicePool {
    voices: Array<Voice> = new Array<Voice>();
    count: i32 = 0;
    serial: u32 = 1;
    seed: u32 = 1;

    constructor(count: i32) {
        this.count = count;
        for (let i = 0; i < count; i++) this.voices.push(new Voice());
    }

    // A fresh voice: a free one, else the quietest (it is stolen).
    alloc(bus: i32): Voice {
        let best = 0;
        let bestLevel: f32 = 1e9;
        for (let i = 0; i < this.count; i++) {
            const v = unchecked(this.voices[i]);
            if (!v.active) {
                best = i;
                bestLevel = -1;
                break;
            }
            const l: f32 = v.delay > 0 ? <f32>1e6 : v.loudness();
            if (l < bestLevel) {
                bestLevel = l;
                best = i;
            }
        }
        const v = unchecked(this.voices[best]);
        this.serial++;
        v.reset(this.seed, this.serial);
        v.bus = bus;
        return v;
    }

    sounding(): i32 {
        let n = 0;
        for (let i = 0; i < this.count; i++) if (unchecked(this.voices[i]).active) n++;
        return n;
    }

    // the voices started by `tag` fade out fast
    release(tag: i32): void {
        for (let i = 0; i < this.count; i++) {
            const v = unchecked(this.voices[i]);
            if (v.active && v.tag == tag) {
                v.toneEnv.mul = decayMul(0.03, SPU_RATE);
                v.noiseEnv.mul = decayMul(0.03, SPU_RATE);
                v.toneEnv.stage = v.toneEnv.stage == 3 ? 3 : 2;
                v.noiseEnv.stage = v.noiseEnv.stage == 3 ? 3 : 2;
            }
        }
    }

    stopAll(): void {
        for (let i = 0; i < this.count; i++) unchecked(this.voices[i]).active = false;
    }

    render(music: Bus, sfx: Bus, ui: Bus): void {
        for (let i = 0; i < this.count; i++) {
            const v = unchecked(this.voices[i]);
            if (!v.active) continue;
            const b = v.bus;
            v.render(b == BUS_MUSIC ? music : (b == BUS_UI ? ui : sfx));
        }
    }
}
