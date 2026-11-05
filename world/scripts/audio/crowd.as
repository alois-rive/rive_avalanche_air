// The crowd (docs/AUDIO.md, section 8): a cheer made of 12 band-passed
// noise voices with slow random swells, and occasional whistles (sine glides
// 2 to 3 kHz, voices from the pool); its level by the distance to the arch
// (the `crowd` knob) and swelled by the cheer cues.
import { BLOCK, CONTROL_RATE, Rng, Svf, smoothCoef } from "./dsp";
import { BUS_SFX, Bus, VoicePool, WAVE_SINE } from "./voices";

const N: i32 = 12;

export class Crowd {
    rng: Rng = new Rng();
    filters: Array<Svf> = new Array<Svf>();
    level: StaticArray<f32> = new StaticArray<f32>(N);
    target: StaticArray<f32> = new StaticArray<f32>(N);
    timer: StaticArray<i32> = new StaticArray<i32>(N);
    pan: StaticArray<f32> = new StaticArray<f32>(N);
    base: f32 = 0;          // the knob, smoothed
    cheer: f32 = 0;         // the cue's swell
    cheerTarget: f32 = 0;
    cheerHold: i32 = 0;
    whistleTimer: i32 = 0;
    kBase: f32 = 0;
    kSwell: f32 = 0;
    kCheerUp: f32 = 0;
    kCheerDown: f32 = 0;

    constructor() {
        this.rng.seed(91, 7);
        // the crowd's "ahh": centres spread over the voice's formants
        const centres: StaticArray<f32> = [380, 520, 650, 780, 900, 1050, 1250, 1500, 1800, 2200, 2700, 3300];
        for (let i = 0; i < N; i++) {
            const f = new Svf();
            f.set(centres[i], 4);
            this.filters.push(f);
            this.level[i] = 0;
            this.target[i] = 0.5;
            this.timer[i] = 0;
            this.pan[i] = (<f32>(i % 4) - 1.5) / 1.5 * 0.8;
        }
        this.kBase = smoothCoef(0.3, CONTROL_RATE);
        this.kSwell = smoothCoef(0.35, CONTROL_RATE);
        this.kCheerUp = smoothCoef(0.15, CONTROL_RATE);
        this.kCheerDown = smoothCoef(1.2, CONTROL_RATE);
    }

    cue(strength: f32): void {
        if (strength > this.cheerTarget) this.cheerTarget = strength;
        this.cheerHold = <i32>(CONTROL_RATE * 2.2);
    }

    control(knob: f32, pool: VoicePool): void {
        this.base += this.kBase * (knob - this.base);
        if (this.cheerHold > 0) this.cheerHold--;
        else this.cheerTarget = 0;
        const k = this.cheerTarget > this.cheer ? this.kCheerUp : this.kCheerDown;
        this.cheer += k * (this.cheerTarget - this.cheer);
        for (let i = 0; i < N; i++) {
            if (this.timer[i] <= 0) {
                this.timer[i] = <i32>(CONTROL_RATE * (0.3 + 1.2 * this.rng.unit()));
                this.target[i] = 0.25 + 0.75 * this.rng.unit();
            }
            this.timer[i]--;
            this.level[i] += this.kSwell * (this.target[i] - this.level[i]);
        }
        // whistles while it cheers
        const amt = this.amount();
        if (amt > 0.15) {
            this.whistleTimer--;
            if (this.whistleTimer <= 0) {
                this.whistleTimer = <i32>(CONTROL_RATE * (0.4 + 1.6 * this.rng.unit()) / (0.3 + amt));
                const f0 = 2000 + 600 * this.rng.unit();
                const v = pool.alloc(BUS_SFX);
                v.tone(WAVE_SINE, f0, f0 + 700 + 300 * this.rng.unit(), 0.12, 1, 0.03, 0.15, 0.25);
                v.vibrato(7, 0.01);
                v.out(0.02 * amt, this.rng.white() * 0.8, 0.3, 0);
                v.tag = 99;
            }
        }
    }

    amount(): f32 {
        return min<f32>(this.base + this.cheer, 1.2);
    }

    @unchecked
    render(bus: Bus): void {
        const amt = this.amount();
        if (amt < 0.001) return;
        const g = amt * 0.55;
        const bl = bus.l;
        const br = bus.r;
        const bs = bus.send;
        for (let v = 0; v < N; v++) {
            const f = this.filters[v];
            const l = this.level[v] * g;
            const p = this.pan[v];
            const gl = l * (1 - p) * 0.5;
            const gr = l * (1 + p) * 0.5;
            for (let i = 0; i < BLOCK; i++) {
                f.tick(this.rng.white());
                const y = f.bpn();
                bl[i] += y * gl;
                br[i] += y * gr;
                bs[i] += y * l * 0.2;
            }
        }
    }
}
