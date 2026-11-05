// The SPU-style room (docs/AUDIO.md, section 3): four parallel damped combs
// (37, 43, 49, 53 ms) and two all-passes (5.0 and 1.7 ms) at 22,050 Hz,
// feedback 0.78, a second, offset set for the right channel. The delay
// lines are powers of two indexed with masks.
import { BLOCK } from "./dsp";

const LINE: i32 = 2048;
const MASK: i32 = 2047;
const AP_LINE: i32 = 128;
const AP_MASK: i32 = 127;

export class Reverb {
    combs: StaticArray<f32> = new StaticArray<f32>(LINE * 8);
    damp: StaticArray<f32> = new StaticArray<f32>(8);
    lens: StaticArray<i32> = new StaticArray<i32>(8);
    aps: StaticArray<f32> = new StaticArray<f32>(AP_LINE * 4);
    apLens: StaticArray<i32> = new StaticArray<i32>(4);
    pos: i32 = 0;
    apPos: i32 = 0;
    feedback: f32 = 0.78;
    dampK: f32 = 0.35;
    // a 1-pole high-pass on the input: the SPU's reverb was thin in the lows
    hpState: f32 = 0;

    constructor() {
        // 37, 43, 49, 53 ms at 22,050 Hz; the right channel 23 samples longer
        this.lens[0] = 816;
        this.lens[1] = 948;
        this.lens[2] = 1080;
        this.lens[3] = 1169;
        this.lens[4] = 839;
        this.lens[5] = 971;
        this.lens[6] = 1103;
        this.lens[7] = 1192;
        this.apLens[0] = 110;   // 5.0 ms
        this.apLens[1] = 37;    // 1.7 ms
        this.apLens[2] = 113;
        this.apLens[3] = 41;
    }

    @unchecked
    process(input: StaticArray<f32>, outL: StaticArray<f32>, outR: StaticArray<f32>, wet: f32): void {
        const combs = this.combs;
        const damp = this.damp;
        const lens = this.lens;
        const aps = this.aps;
        const apl = this.apLens;
        const fb = this.feedback;
        const dk = this.dampK;
        let pos = this.pos;
        let apPos = this.apPos;
        let hp = this.hpState;
        for (let i = 0; i < BLOCK; i++) {
            const raw = input[i];
            hp += 0.06 * (raw - hp);
            const x = (raw - hp) * 0.25;
            let sl: f32 = 0;
            let sr: f32 = 0;
            for (let c = 0; c < 8; c++) {
                const base = c * LINE;
                const y = combs[base + ((pos - lens[c]) & MASK)];
                let d = damp[c];
                d = y + dk * (d - y);
                damp[c] = d;
                combs[base + (pos & MASK)] = x + fb * d;
                if (c < 4) sl += y;
                else sr += y;
            }
            // the all-passes, two per side
            for (let a = 0; a < 2; a++) {
                const base = a * AP_LINE;
                const del = aps[base + ((apPos - apl[a]) & AP_MASK)];
                const v = sl + 0.5 * del;
                aps[base + (apPos & AP_MASK)] = v;
                sl = del - 0.5 * v;
            }
            for (let a = 2; a < 4; a++) {
                const base = a * AP_LINE;
                const del = aps[base + ((apPos - apl[a]) & AP_MASK)];
                const v = sr + 0.5 * del;
                aps[base + (apPos & AP_MASK)] = v;
                sr = del - 0.5 * v;
            }
            outL[i] += sl * wet;
            outR[i] += sr * wet;
            pos = (pos + 1) & MASK;
            apPos = (apPos + 1) & AP_MASK;
        }
        this.pos = pos;
        this.apPos = apPos;
        this.hpState = hp;
    }

    clear(): void {
        for (let i = 0; i < LINE * 8; i++) unchecked(this.combs[i] = 0);
        for (let i = 0; i < AP_LINE * 4; i++) unchecked(this.aps[i] = 0);
        for (let i = 0; i < 8; i++) unchecked(this.damp[i] = 0);
    }
}
