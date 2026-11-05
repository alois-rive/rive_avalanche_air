// The announcer's voice (docs/AUDIO.md, section 6): a source-filter formant
// synthesiser. A Rosenberg glottal pulse (jitter, shimmer, aspiration) into
// five formant resonators in cascade, frication through a parallel band;
// the phonemes' targets from voice_data.as, smoothed into 25 to 40 ms
// transitions; prosody for a shout; then the PA (a 250 Hz to 4 kHz band, a
// tanh drive, a 90 ms slapback, the reverb's send). The line queue lives
// here too: one line at a time, a higher priority cuts, a line waiting
// over 1.2 s is dropped.
import { BLOCK, CONTROL_RATE, SPU_INV_RATE, SPU_RATE, Reso, Rng, Svf, smoothCoef, softClip } from "./dsp";
import { Bus } from "./voices";
import { LINE_TRICK } from "./shared";
import {
    K_AFFR_U, K_AFFR_V, K_ASP, K_DIPH, K_GLIDE, K_NASAL, K_SIL, K_STOP_U, K_STOP_V, K_VOWEL,
    LINE_COUNT, LINE_LEN, LINE_SHOUT, LINE_START, LINE_WORDS, PH_AMP, PH_BW, PH_DUR, PH_FORM, PH_KIND, PH_SIL,
    W_BACKFLIP, W_BACKSIDE, W_BOARDSLIDE, W_DOUBLE, W_FIFTYFIFTY, W_FLIP, W_FRONT, W_FRONTSIDE, W_INDY, W_KINKED,
    W_LOG, W_MELON, W_METHOD, W_MUTE, W_N180, W_RAINBOW, W_SLIDE, W_SWITCH, W_TO, WORD_LEN, WORD_PH, WORD_START,
} from "./voice_data";

const MAX_SEG: i32 = 128;
const MAX_WORDS: i32 = 16;
const QUEUE: i32 = 6;
const SLAP: i32 = 2048;
const SLAP_MASK: i32 = 2047;

export class Speech {
    // the queue
    qLine: StaticArray<i32> = new StaticArray<i32>(QUEUE);
    qPrio: StaticArray<i32> = new StaticArray<i32>(QUEUE);
    qTrick: StaticArray<f32> = new StaticArray<f32>(QUEUE);
    qDelay: StaticArray<i32> = new StaticArray<i32>(QUEUE);
    qAge: StaticArray<i32> = new StaticArray<i32>(QUEUE);
    qChained: StaticArray<i32> = new StaticArray<i32>(QUEUE);
    qCount: i32 = 0;

    // the line being spoken
    speaking: bool = false;
    line: i32 = -1;
    prio: i32 = 9;
    lineSeq: i32 = 0;
    cutting: bool = false;
    words: StaticArray<i32> = new StaticArray<i32>(MAX_WORDS);
    nWords: i32 = 0;

    // the schedule
    segPh: StaticArray<i32> = new StaticArray<i32>(MAX_SEG);
    segDur: StaticArray<i32> = new StaticArray<i32>(MAX_SEG);
    segF0: StaticArray<f32> = new StaticArray<f32>(MAX_SEG);
    segAmp: StaticArray<f32> = new StaticArray<f32>(MAX_SEG);
    nSeg: i32 = 0;
    seg: i32 = 0;
    segPos: i32 = 0;

    // the synthesiser's state, smoothed
    f1: f32 = 500;
    f2: f32 = 1500;
    f3: f32 = 2500;
    b1: f32 = 80;
    b2: f32 = 100;
    b3: f32 = 150;
    av: f32 = 0;
    af: f32 = 0;
    ah: f32 = 0;
    ff: f32 = 3000;
    fq: f32 = 1;
    amp: f32 = 0;
    f0: f32 = 200;
    kForm: f32 = 0;
    kAmp: f32 = 0;
    kF0: f32 = 0;
    shout: bool = false;
    f0Base: f32 = 190;

    ph: f32 = 0;
    jit: f32 = 1;
    shim: f32 = 1;
    flowPrev: f32 = 0;
    r1: Reso = new Reso();
    r2: Reso = new Reso();
    r3: Reso = new Reso();
    r4: Reso = new Reso();
    r5: Reso = new Reso();
    fric: Svf = new Svf();
    rng: Rng = new Rng();
    tilt: f32 = 0;

    // the PA
    hp: Svf = new Svf();
    lp: Svf = new Svf();
    slap: StaticArray<f32> = new StaticArray<f32>(SLAP);
    slapPos: i32 = 0;
    slapLen: i32 = 1985;          // 90 ms
    tail: i32 = 0;
    gain: f32 = 1;
    level: f32 = 0;
    preGain: f32 = 0.04;   // into the PA's drive: the loudest vowels at about 0.45, x 3
    prePeak: f32 = 0;
    agcEnv: f32 = 0;
    agc: f32 = 1;
    tmp: StaticArray<f32> = new StaticArray<f32>(BLOCK);

    constructor() {
        this.kForm = smoothCoef(0.011, CONTROL_RATE);
        this.kAmp = smoothCoef(0.004, CONTROL_RATE);
        this.kF0 = smoothCoef(0.035, CONTROL_RATE);
        this.rng.seed(777, 13);
        this.hp.set(250, 0.7);
        this.lp.set(4000, 0.7);
        this.r4.set(3400, 260);
        this.r5.set(3950, 300);
    }

    // ---- the queue -------------------------------------------------------------------

    // prio: 1 highest. chained: queued right after the line before it (never expires).
    say(line: i32, prio: i32, trick: f32, delay: f32, chained: bool): void {
        if (line < 0) return;
        const d = <i32>(delay * SPU_RATE);
        if (!this.speaking && this.qCount == 0 && d <= 0) {
            this.start(line, prio, trick);
            return;
        }
        if (this.speaking && prio < this.prio && !chained && d <= 0) {
            // a higher priority cuts what is being said
            this.qCount = 0;
            this.start(line, prio, trick);
            return;
        }
        if (this.qCount >= QUEUE) return;
        const i = this.qCount;
        this.qLine[i] = line;
        this.qPrio[i] = prio;
        this.qTrick[i] = trick;
        this.qDelay[i] = d;
        this.qAge[i] = 0;
        this.qChained[i] = chained ? 1 : 0;
        this.qCount++;
    }

    shutUp(): void {
        this.qCount = 0;
        if (this.speaking) this.cutting = true;
    }

    popQueue(): void {
        for (let i = 1; i < this.qCount; i++) {
            this.qLine[i - 1] = this.qLine[i];
            this.qPrio[i - 1] = this.qPrio[i];
            this.qTrick[i - 1] = this.qTrick[i];
            this.qDelay[i - 1] = this.qDelay[i];
            this.qAge[i - 1] = this.qAge[i];
            this.qChained[i - 1] = this.qChained[i];
        }
        this.qCount--;
    }

    control(): void {
        // the queue ages; a line waiting over 1.2 s is dropped
        for (let i = 0; i < this.qCount; i++) {
            if (this.qDelay[i] > 0) this.qDelay[i] -= BLOCK;
            else this.qAge[i] += BLOCK;
        }
        let i = 0;
        while (i < this.qCount) {
            if (this.qChained[i] == 0 && this.qAge[i] > <i32>(1.2 * SPU_RATE)) {
                for (let j = i + 1; j < this.qCount; j++) {
                    this.qLine[j - 1] = this.qLine[j];
                    this.qPrio[j - 1] = this.qPrio[j];
                    this.qTrick[j - 1] = this.qTrick[j];
                    this.qDelay[j - 1] = this.qDelay[j];
                    this.qAge[j - 1] = this.qAge[j];
                    this.qChained[j - 1] = this.qChained[j];
                }
                this.qCount--;
            } else {
                i++;
            }
        }
        if (!this.speaking && this.qCount > 0 && this.qDelay[0] <= 0) {
            const line = this.qLine[0];
            const prio = this.qPrio[0];
            const trick = this.qTrick[0];
            this.popQueue();
            // the chained lines behind it keep their place
            this.start(line, prio, trick);
        }
    }

    // ---- the schedule ------------------------------------------------------------------

    addWord(w: i32): void {
        if (this.nWords < MAX_WORDS) {
            this.words[this.nWords] = w;
            this.nWords++;
        }
    }

    trickWords(packed: f32): void {
        const v = <i32>packed;
        const spin = v & 15;
        const dir = (v >> 4) & 3;
        const flip = (v >> 6) & 7;
        const g1 = (v >> 9) & 7;
        const g2 = (v >> 12) & 7;
        const sw = (v >> 15) & 1;
        const grind = (v >> 16) & 31;
        if (grind > 0 && spin == 0 && flip == 0 && g1 == 0) {
            const mod = grind / 10;
            const kind = grind % 10;
            if (mod == 1) this.addWord(W_KINKED);
            if (mod == 2) this.addWord(W_RAINBOW);
            if (kind == 1) this.addWord(W_FIFTYFIFTY);
            else if (kind == 2) this.addWord(W_BOARDSLIDE);
            else if (kind == 3) {
                this.addWord(W_LOG);
                this.addWord(W_SLIDE);
            }
            return;
        }
        if (sw != 0) this.addWord(W_SWITCH);
        if (spin > 0 && dir == 1) this.addWord(W_FRONTSIDE);
        if (spin > 0 && dir == 2) this.addWord(W_BACKSIDE);
        if (flip == 1) {
            this.addWord(W_FRONT);
            this.addWord(W_FLIP);
        } else if (flip == 2) {
            this.addWord(W_BACKFLIP);
        } else if (flip == 3) {
            this.addWord(W_DOUBLE);
            this.addWord(W_FRONT);
            this.addWord(W_FLIP);
        } else if (flip == 4) {
            this.addWord(W_DOUBLE);
            this.addWord(W_BACKFLIP);
        }
        if (spin > 0) this.addWord(W_N180 + min<i32>(spin, 8) - 1);
        if (g1 > 0) this.addWord(this.grabWord(g1));
        if (g2 > 0) {
            this.addWord(W_TO);
            this.addWord(this.grabWord(g2));
        }
    }

    grabWord(g: i32): i32 {
        if (g == 1) return W_INDY;
        if (g == 2) return W_MELON;
        if (g == 3) return W_METHOD;
        return W_MUTE;
    }

    pushSeg(ph: i32, durMs: f32, f0: f32, amp: f32): void {
        if (this.nSeg >= MAX_SEG) return;
        const i = this.nSeg;
        this.segPh[i] = ph;
        this.segDur[i] = max<i32>(<i32>(durMs * 0.001 * SPU_RATE), BLOCK);
        this.segF0[i] = f0;
        this.segAmp[i] = amp;
        this.nSeg++;
    }

    start(line: i32, prio: i32, trick: f32): void {
        this.nWords = 0;
        let shout = true;
        if (line == LINE_TRICK) {
            this.trickWords(trick);
        } else if (line >= 0 && line < LINE_COUNT) {
            const s = LINE_START[line];
            const n = LINE_LEN[line];
            for (let k = 0; k < n; k++) this.addWord(LINE_WORDS[s + k]);
            shout = LINE_SHOUT[line] != 0;
        }
        if (this.nWords == 0) return;
        this.shout = shout;
        this.line = line;
        this.prio = prio;
        this.lineSeq++;
        this.speaking = true;
        this.cutting = false;
        this.build();
        this.seg = 0;
        this.segPos = 0;
    }

    // the phonemes of the words, with durations and the pitch contour
    build(): void {
        this.nSeg = 0;
        const shout = this.shout;
        const tempo: f32 = shout ? 0.97 : 0.95;
        // where the phrase's last primary stress is, in phonemes
        let total = 0;
        let lastStress = 0;
        for (let w = 0; w < this.nWords; w++) {
            const wi = this.words[w];
            const s = WORD_START[wi];
            const n = WORD_LEN[wi];
            for (let k = 0; k < n; k++) {
                const code = WORD_PH[s + k];
                if (((code >> 8) & 3) == 1) lastStress = total;
                total++;
            }
        }
        this.pushSeg(PH_SIL, 25, 1, 0);
        let idx = 0;
        for (let w = 0; w < this.nWords; w++) {
            const wi = this.words[w];
            const s = WORD_START[wi];
            const n = WORD_LEN[wi];
            for (let k = 0; k < n; k++) {
                const code = WORD_PH[s + k];
                const ph = code & 255;
                const stress = (code >> 8) & 3;
                const over = code >> 10;
                const kind = PH_KIND[ph];
                let dur = over > 0 ? <f32>over : PH_DUR[ph];
                let f0: f32 = 1;
                let amp: f32 = 1;
                const vowel = kind == K_VOWEL || kind == K_DIPH;
                if (vowel) {
                    if (stress == 1) {
                        dur *= shout ? 1.45 : 1.3;
                        f0 = 1.25;
                    } else if (stress == 2) {
                        dur *= 1.1;
                        f0 = 1.1;
                        amp = 0.92;
                    } else {
                        dur *= 0.85;
                        amp = 0.78;
                    }
                }
                // the phrase rises to its last stress, then falls sharply
                let contour: f32;
                if (idx <= lastStress) contour = 1 + 0.12 * <f32>idx / max<f32>(<f32>lastStress, 1);
                else contour = 1.12 - 0.4 * <f32>(idx - lastStress) / max<f32>(<f32>(total - lastStress), 1);
                if (idx == total - 1 && vowel) dur *= 1.25;
                this.pushSeg(ph, dur * tempo, f0 * contour, amp);
                idx++;
            }
            if (w < this.nWords - 1) this.pushSeg(PH_SIL, 18, 1, 0);
        }
        this.pushSeg(PH_SIL, 70, 0.8, 0);
        this.f0Base = shout ? 190 * 1.4 : 175;
    }

    // ---- synthesis ------------------------------------------------------------------

    // the targets of segment `i` at `u` (0..1 through it)
    @unchecked
    targets(): void {
        const i = this.seg;
        const ph = this.segPh[i];
        const kind = PH_KIND[ph];
        const u = <f32>this.segPos / <f32>this.segDur[i];
        // the next segment's phoneme: aspiration and releases take its formants
        let next = ph;
        for (let j = i + 1; j < this.nSeg; j++) {
            const pk = PH_KIND[this.segPh[j]];
            if (pk != K_SIL) {
                next = this.segPh[j];
                break;
            }
        }
        let fph = ph;
        if (kind == K_ASP || kind == K_SIL) fph = next;
        const fb = fph * 6;
        let tf1 = PH_FORM[fb];
        let tf2 = PH_FORM[fb + 1];
        let tf3 = PH_FORM[fb + 2];
        if (PH_KIND[fph] == K_DIPH) {
            tf1 += (PH_FORM[fb + 3] - tf1) * u;
            tf2 += (PH_FORM[fb + 4] - tf2) * u;
            tf3 += (PH_FORM[fb + 5] - tf3) * u;
        }
        const bb = fph * 3;
        let tb1 = PH_BW[bb];
        let tb2 = PH_BW[bb + 1];
        let tb3 = PH_BW[bb + 2];
        const ab = ph * 5;
        let av = PH_AMP[ab];
        let af = PH_AMP[ab + 1];
        let ah = PH_AMP[ab + 2];
        const ff = PH_AMP[ab + 3];
        const fq = PH_AMP[ab + 4];
        if (kind == K_STOP_U) {
            if (u < 0.55) {
                af = 0;
                ah = 0;
            } else if (u < 0.68) {
                ah = 0;
            } else {
                af *= 0.25;
                // the aspiration takes the next vowel's formants
                const nb = next * 6;
                tf1 = PH_FORM[nb];
                tf2 = PH_FORM[nb + 1];
                tf3 = PH_FORM[nb + 2];
            }
        } else if (kind == K_STOP_V) {
            if (u < 0.6) {
                af = 0;
            } else if (u < 0.72) {
                av = 0.3;
            } else {
                af = 0;
                av = 0.6;
            }
        } else if (kind == K_AFFR_U) {
            if (u < 0.35) af = 0;
        } else if (kind == K_AFFR_V) {
            if (u < 0.3) {
                af = 0;
                av = 0.15;
            }
        }
        const amp = this.segAmp[i];
        if (kind == K_SIL) {
            av = 0;
            af = 0;
            ah = 0;
        }
        // a shout opens the jaw: F1 up
        const s1: f32 = this.shout ? 1.1 : 1.0;
        const kf = this.kForm;
        const ka = this.kAmp;
        this.f1 += kf * (tf1 * s1 - this.f1);
        this.f2 += kf * (tf2 - this.f2);
        this.f3 += kf * (tf3 - this.f3);
        this.b1 += kf * (tb1 - this.b1);
        this.b2 += kf * (tb2 - this.b2);
        this.b3 += kf * (tb3 - this.b3);
        const glideAmp: f32 = kind == K_GLIDE || kind == K_NASAL ? 1 : amp;
        this.av += ka * (av * (kind == K_SIL ? 0 : glideAmp) - this.av);
        this.af += ka * (af - this.af);
        this.ah += ka * (ah - this.ah);
        this.ff = ff > 0 ? ff : this.ff;
        this.fq = fq;
        const f0t = this.f0Base * this.segF0[i];
        this.f0 += this.kF0 * (f0t - this.f0);
    }

    @unchecked
    render(bus: Bus, send: f32): void {
        if (!this.speaking && this.tail <= 0) return;
        const tmp = this.tmp;
        if (this.speaking) {
            this.targets();
            this.r1.set(this.f1, this.b1);
            this.r2.set(this.f2, this.b2);
            this.r3.set(this.f3, this.b3);
            this.fric.set(this.ff, this.fq);
            const sh: f32 = this.shout ? 1.0 : 0.8;
            // the open quotient: a pressed shout (short) or a plain voice
            const tp: f32 = this.shout ? 0.36 : 0.42;
            const tn: f32 = this.shout ? 0.12 : 0.16;
            const invTp = 1 / tp;
            const invTn = 1 / tn;
            const av = this.av;
            const af = this.af;
            const ah = this.ah;
            let fade: f32 = 1;
            for (let i = 0; i < BLOCK; i++) {
                // the glottal pulse (Rosenberg), its derivative the excitation
                let ph = this.ph + this.f0 * this.jit * SPU_INV_RATE;
                if (ph >= 1) {
                    ph -= 1;
                    this.jit = 1 + 0.01 * this.rng.white();
                    this.shim = 1 + 0.04 * this.rng.white();
                }
                this.ph = ph;
                let flow: f32 = 0;
                if (ph < tp) {
                    // the opening: a smooth rise (0.5 - 0.5 cos, as a cubic)
                    const x = ph * invTp;
                    flow = x * x * (3 - 2 * x);
                } else if (ph < tp + tn) {
                    const x = (ph - tp) * invTn;
                    flow = 1 - x * x;
                }
                const exc = (flow - this.flowPrev) * 10 * av * this.shim;
                this.flowPrev = flow;
                const noise = this.rng.white();
                // aspiration, and breath under the voice while the glottis is open
                const asp = noise * (ah * 0.9 + av * 0.06 * flow);
                let y = this.r1.tick(exc + asp);
                y = this.r2.tick(y);
                y = this.r3.tick(y);
                y = this.r4.tick(y);
                y = this.r5.tick(y);
                // a gentle tilt: a shout is bright
                this.tilt += 0.5 * (y - this.tilt);
                y = y + (y - this.tilt) * 0.6;
                this.fric.tick(noise);
                // the frication, parallel to the cascade, at the voice's level (the
                // cascade's resonances lift the voiced part by about 20 dB)
                y += this.fric.bpn() * af * 4.0;
                tmp[i] = y * sh;
            }
            if (this.cutting) {
                // cut: a 10 ms fade
                for (let i = 0; i < BLOCK; i++) {
                    fade = 1 - <f32>i / <f32>BLOCK;
                    tmp[i] *= fade;
                }
            }
            // the schedule moves on
            this.segPos += BLOCK;
            if (this.segPos >= this.segDur[this.seg]) {
                this.segPos = 0;
                this.seg++;
                if (this.seg >= this.nSeg) this.finish();
            }
            if (this.cutting) this.finish();
            this.tail = <i32>(0.35 * SPU_RATE);
        } else {
            for (let i = 0; i < BLOCK; i++) tmp[i] = 0;
            this.tail -= BLOCK;
        }
        // the PA: a band, a drive, a slapback
        const bl = bus.l;
        const br = bus.r;
        const bs = bus.send;
        const sl = this.slap;
        const g = this.gain;
        let pos = this.slapPos;
        const D = this.slapLen;
        let peak: f32 = 0;
        let pre = this.prePeak;
        const pg = this.preGain;
        let env = this.agcEnv;
        let agc = this.agc;
        for (let i = 0; i < BLOCK; i++) {
            this.hp.tick(tmp[i] * pg);
            this.lp.tick(this.hp.hp);
            const x = this.lp.lp;
            const ax = abs<f32>(x);
            if (ax > pre) pre = ax;
            // a shouting voice is level: an automatic gain (5 ms in, 120 ms out) before the drive
            env = ax > env ? env + 0.04 * (ax - env) : env * 0.99962;
            const want = min<f32>(0.42 / (env + 0.002), 6);
            agc += 0.01 * (want - agc);
            const d = softClip(x * agc * 3) * 0.55;
            const echo = sl[(pos - D) & SLAP_MASK];
            sl[pos & SLAP_MASK] = d;
            const y = (d + echo * 0.25) * g;
            bl[i] += y;
            br[i] += y;
            bs[i] += y * send;
            pos = (pos + 1) & SLAP_MASK;
            const a = abs<f32>(y);
            if (a > peak) peak = a;
        }
        this.slapPos = pos;
        this.level = peak;
        this.prePeak = pre;
        this.agcEnv = env;
        this.agc = agc;
    }

    finish(): void {
        this.speaking = false;
        this.cutting = false;
        this.line = -1;
        this.prio = 9;
        this.av = 0;
        this.af = 0;
        this.ah = 0;
    }

    // the line being spoken, -1 none
    current(): i32 {
        return this.speaking ? this.line : -1;
    }
}
