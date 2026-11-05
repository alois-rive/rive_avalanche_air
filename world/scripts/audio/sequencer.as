// The music (docs/AUDIO.md, section 5): "Ice Breaker (170)", played from
// music_data.as on the processor's own sample clock. The states follow the
// run, every change on the next bar (the next beat or at once for the
// urgent ones). The music's own post chain: the state's low-pass (the
// title's filtered intro, the mega-jump's hang, the pause, the crash), the
// crash duck, the restart's tape-stop.
import { BLOCK, CONTROL_RATE, SPU_INV_RATE, SPU_RATE, Svf, smoothCoef } from "./dsp";
import {
    BUS_MUSIC, Bus, FILT_BP, FILT_HP, FILT_LP, NOISE_PINK, NOISE_WHITE, VoicePool, WAVE_METAL, WAVE_SINE, WAVE_TRI,
} from "./voices";
import { Arp, Pad, Reese, Riser, Stabs } from "./instruments";
import {
    MUS_COUNTDOWN, MUS_FINISH, MUS_KICKERS, MUS_MEGA_AIR, MUS_MEGA_DROP, MUS_MEGA_RISER, MUS_RAILS,
    MUS_RESULTS, MUS_SILENT, MUS_SPLIT, MUS_START, MUS_TITLE, MUS_WAIT, MUS_WARMUP,
} from "./shared";
import {
    CHORD_NOTES, FX_CRASH, FX_IMPACT, PAT, SEC_AIR, SEC_BARS, SEC_BASS, SEC_COUNT, SEC_DROP, SEC_FINISH,
    SEC_INTRO, SEC_KICKERS, SEC_LOOP, SEC_PAD, SEC_RAILS, SEC_RESULTS, SEC_RISER, SEC_ROWS, SEC_SPLIT, SEC_START,
    SEC_WARMUP, SWING, TEMPO,
} from "./music_data";

const Q_BEAT: i32 = 1;
const Q_BAR: i32 = 2;

const TAPE: i32 = 8192;
const TAPE_MASK: i32 = 8191;

// The test instruments (CUE_TEST, a): the review bank and the unit renders.
export const INST_KICK: i32 = 0;
export const INST_SNARE: i32 = 1;
export const INST_GHOST: i32 = 2;
export const INST_HAT: i32 = 3;
export const INST_OPEN: i32 = 4;
export const INST_RIDE: i32 = 5;
export const INST_CRASH: i32 = 6;
export const INST_REESE: i32 = 7;
export const INST_STAB: i32 = 8;
export const INST_PAD: i32 = 9;
export const INST_ARP: i32 = 10;
export const INST_RISER: i32 = 11;
export const INST_IMPACT: i32 = 12;

export class Music {
    pool: VoicePool = new VoicePool(32);
    reese: Reese = new Reese();
    stabs: Stabs = new Stabs();
    pad: Pad = new Pad();
    arp: Arp = new Arp();
    riser: Riser = new Riser();
    bus: Bus = new Bus();
    sub: StaticArray<f32> = new StaticArray<f32>(BLOCK);

    // the state
    requested: i32 = MUS_SILENT;
    state: i32 = MUS_SILENT;
    pending: i32 = -1;
    pendingQ: i32 = Q_BAR;
    section: i32 = -1;
    running: bool = false;

    // the clock (internal samples)
    clock: f64 = 0;
    stepLen: f64 = 0;
    swingOff: f64 = 0;
    gridTime: f64 = 0;
    stepInBar: i32 = 0;
    barInSection: i32 = 0;
    phraseBar: i32 = 0;
    chord: i32 = 0;
    barCount: i32 = 0;
    beatCount: i32 = 0;
    ticks: i32 = 0;           // tally ticks waiting for their 16th
    tickNow: i32 = 0;         // played this block (the mixer reads it)
    tickOffset: i32 = 0;

    // the post chain
    cut: f32 = 16000;         // the low-pass, smoothed in octaves
    logCut: f32 = 14;
    stateCut: f32 = 16000;
    pausedK: f32 = 0;
    pausedAmt: f32 = 0;
    crashT: i32 = 0;
    crashAmt: f32 = 0;
    kCut: f32 = 0;
    kCutSlow: f32 = 0;
    kAmt: f32 = 0;
    lpL1: Svf = new Svf();
    lpL2: Svf = new Svf();
    lpR1: Svf = new Svf();
    lpR2: Svf = new Svf();
    tapeL: StaticArray<f32> = new StaticArray<f32>(TAPE);
    tapeR: StaticArray<f32> = new StaticArray<f32>(TAPE);
    tapeW: i32 = 0;
    tapeRead: f64 = 0;
    tapeRate: f32 = 1;
    tapeStopping: bool = false;
    tapeMuted: bool = false;
    gain: f32 = 1;
    seed: u32 = 1;
    level: f32 = 0;

    constructor() {
        this.stepLen = <f64>SPU_RATE * 60.0 / (<f64>TEMPO * 4.0);
        this.swingOff = (<f64>SWING - 0.5) * 2.0 * this.stepLen;
        this.kCut = smoothCoef(0.06, CONTROL_RATE);
        this.kCutSlow = smoothCoef(0.25, CONTROL_RATE);
        this.kAmt = smoothCoef(0.05, CONTROL_RATE);
        this.pad.chord(CHORD_NOTES, 0);
    }

    // ---- the states ------------------------------------------------------------

    sectionFor(state: i32): i32 {
        if (state == MUS_TITLE || state == MUS_START) return SEC_INTRO;
        if (state == MUS_COUNTDOWN) return SEC_COUNT;
        if (state == MUS_WARMUP) return SEC_WARMUP;
        if (state == MUS_KICKERS) return SEC_KICKERS;
        if (state == MUS_RAILS) return SEC_RAILS;
        if (state == MUS_SPLIT) return SEC_SPLIT;
        if (state == MUS_MEGA_RISER) return SEC_RISER;
        if (state == MUS_MEGA_AIR) return SEC_AIR;
        if (state == MUS_MEGA_DROP) return SEC_DROP;
        if (state == MUS_FINISH) return SEC_FINISH;
        if (state == MUS_RESULTS) return SEC_RESULTS;
        return -1;
    }

    // The main lane's wish (the `music` knob), acted on when it changes.
    request(want: i32): void {
        if (want == this.requested) return;
        const from = this.requested;
        this.requested = want;
        if (want == MUS_SILENT || want == MUS_WAIT) {
            this.enter(want, true, false);
            return;
        }
        if (want == MUS_START) {
            // the filter opens over two beats; the intro goes on
            if (this.state == MUS_TITLE) {
                this.state = MUS_START;
                return;
            }
            this.enter(MUS_TITLE, true, true);
            this.state = MUS_START;
            return;
        }
        if (!this.running) {
            this.enter(want, true, true);
            return;
        }
        if (want == MUS_COUNTDOWN || want == MUS_FINISH || want == MUS_MEGA_DROP) {
            this.enter(want, true, true);
            return;
        }
        if (want == MUS_WARMUP && (from == MUS_COUNTDOWN || from == MUS_WAIT || from == MUS_TITLE
            || from == MUS_START || from == MUS_SILENT || from == MUS_RESULTS || from == MUS_FINISH)) {
            // GO: the drop lands on GO
            this.enter(want, true, true);
            return;
        }
        if (want == MUS_MEGA_AIR) {
            this.pending = want;
            this.pendingQ = Q_BEAT;
            return;
        }
        this.pending = want;
        this.pendingQ = Q_BAR;
    }

    // Enter a state now. `reset` puts the next step at this block.
    enter(state: i32, reset: bool, fresh: bool): void {
        const prev = this.state;
        this.state = state;
        this.pending = -1;
        const sec = this.sectionFor(state);
        if (reset) {
            this.gridTime = this.clock;
            this.stepInBar = 0;
            this.phraseBar = 0;
        }
        this.tapeStopping = false;
        this.tapeMuted = false;
        this.tapeRate = 1;
        if (sec < 0) {
            this.section = -1;
            this.running = false;
            this.reese.noteOff();
            this.pad.want = 0;
            this.riser.stop();
            return;
        }
        this.section = sec;
        this.running = true;
        const bars = unchecked(SEC_BARS[sec]);
        this.barInSection = fresh ? 0 : this.phraseBar % bars;
        this.pad.want = unchecked(SEC_PAD[sec]);
        const bass = unchecked(SEC_BASS[sec]);
        this.reese.reeseWant = (bass & 2) != 0 ? 1 : 0;
        this.reese.subWant = (bass & 1) != 0 ? 1 : 0;
        if (bass == 0) this.reese.noteOff();
        this.applyChord();

        if (state == MUS_COUNTDOWN) {
            this.riser.start(3.0, 0);
        } else if (state == MUS_MEGA_RISER) {
            this.riser.start(<f32>(this.stepLen * 64.0) * SPU_INV_RATE, 0);
        } else if (state == MUS_MEGA_AIR) {
            this.riser.holdTop();
        } else {
            this.riser.stop();
        }
        if (state == MUS_WARMUP && prev != MUS_KICKERS && prev != MUS_RAILS && prev != MUS_SPLIT && prev != MUS_MEGA_RISER) {
            // GO: an impact (the section's first bar brings its crash)
            this.impact(0, 0.7);
        }
        if (state == MUS_MEGA_DROP) this.impact(0, 1);
        if (state == MUS_FINISH) {
            this.impact(0, 1);
            this.drum(6, 3, 0);
        }
        if (state == MUS_FINISH) this.reese.noteOff();
    }

    // The restart: a tape-stop, then silence until GO.
    tapeStop(): void {
        this.tapeStopping = true;
        this.tapeRate = 1;
        this.tapeRead = <f64>this.tapeW;
        this.requested = MUS_WAIT;
        this.state = MUS_WAIT;
        this.section = -1;
        this.running = false;
        this.pending = -1;
        this.reese.noteOff();
        this.pad.want = 0;
        this.riser.stop();
    }

    crashDuck(): void {
        this.crashT = <i32>(1.2 * CONTROL_RATE);
    }

    tick(): void {
        if (this.running) this.ticks++;
    }

    applyChord(): void {
        if (this.section < 0) return;
        const row = (unchecked(SEC_START[this.section]) + this.barInSection) * 6;
        const c = unchecked(SEC_ROWS[row + 4]);
        if (c != this.chord) {
            this.chord = c;
        }
        this.pad.chord(CHORD_NOTES, c * 5);
    }

    // ---- the instruments ------------------------------------------------------

    drum(kind: i32, vel: i32, offset: i32): void {
        const v = <f32>vel / 3;
        const p = this.pool;
        if (kind == 0) {
            // kick: a sine sweeping 160 to 45 Hz in 60 ms, 180 ms decay, a click
            const k = p.alloc(BUS_MUSIC).tone(WAVE_SINE, 170, 48, 0.022, 1, 0.002, 0.03, 0.24)
                .noiseLayer(NOISE_WHITE, 0.5, 0.002, 0.0, 0.012).filter(FILT_HP, 2500, 2500, 0, 0.7, false)
                .out(1.05 * v, 0, 0.02, 0.15);
            k.delay = offset;
            this.reese.pumpHit = v;
        } else if (kind == 1 || kind == 2) {
            // snare: noise band-passed at 1.8 kHz and a 190 Hz triangle; the ghost at -14 dB, 70 ms
            const ghost = kind == 2;
            const g = ghost ? 0.2 * (0.6 + 0.4 * v) : v;
            const s = p.alloc(BUS_MUSIC).tone(WAVE_TRI, 230, 185, 0.01, 0.9, 0.002, 0.01, ghost ? 0.05 : 0.09)
                .noiseLayer(NOISE_WHITE, 1, 0.002, ghost ? 0.005 : 0.012, ghost ? 0.09 : 0.24)
                .filter(FILT_BP, 2400, 1800, 0.03, 0.75, false).out(1.0 * g, 0.05, ghost ? 0.05 : 0.14, 0.4);
            s.delay = offset;
            if (!ghost) {
                // the snap on top
                const sn = p.alloc(BUS_MUSIC).noiseLayer(NOISE_WHITE, 1, 0.002, 0.0, 0.06)
                    .filter(FILT_HP, 5000, 5000, 0, 0.7, false).out(0.5 * g, 0.05, 0.1, 0.4);
                sn.delay = offset;
            }
        } else if (kind == 3 || kind == 4) {
            // hats: noise high-passed at 7 kHz, closed 30 ms, open 140 ms
            const open = kind == 4;
            const h = p.alloc(BUS_MUSIC).noiseLayer(NOISE_WHITE, 1, 0.002, open ? 0.03 : 0.0, open ? 0.3 : 0.045)
                .filter(FILT_HP, 7000, 7000, 0, 0.8, false).out(0.65 * (0.35 + 0.65 * v), 0.25, 0.04, 0.5);
            h.delay = offset;
            if (!open) this.pool.release(4);    // a closed hat chokes the open one
            h.tag = open ? 4 : 3;
        } else if (kind == 5) {
            // ride: metallic noise through a high-pass, 0.6 s
            const r = p.alloc(BUS_MUSIC).tone(WAVE_METAL, 470, 470, 0, 1, 0.002, 0.0, 0.6)
                .noiseLayer(NOISE_WHITE, 0.25, 0.002, 0.0, 0.2)
                .filter(FILT_HP, 4500, 4500, 0, 0.7, true).out(0.22 * v, -0.3, 0.08, 0.3);
            r.delay = offset;
        } else {
            // crash: 1.8 s
            const c = p.alloc(BUS_MUSIC).tone(WAVE_METAL, 380, 380, 0, 0.8, 0.002, 0.0, 1.8)
                .noiseLayer(NOISE_WHITE, 0.7, 0.002, 0.02, 1.4)
                .filter(FILT_HP, 3800, 3000, 0.5, 0.7, true).out(0.3 * v, -0.2, 0.25, 0.3);
            c.delay = offset;
        }
    }

    // a low boom (a 50 Hz sine, 1.2 s) and a noise burst
    impact(offset: i32, g: f32): void {
        const b = this.pool.alloc(BUS_MUSIC).tone(WAVE_SINE, 95, 46, 0.09, 1, 0.002, 0.08, 1.4).out(0.95 * g, 0, 0.1, 0);
        b.delay = offset;
        const n = this.pool.alloc(BUS_MUSIC).noiseLayer(NOISE_PINK, 1, 0.002, 0.03, 0.7)
            .filter(FILT_LP, 4000, 180, 0.2, 0.7, false).out(0.55 * g, 0, 0.45, 0.3);
        n.delay = offset;
    }

    // a reversed-noise swell over `samples`, ending on the impact
    swell(samples: i32, offset: i32): void {
        const s = <f32>samples * SPU_INV_RATE;
        const v = this.pool.alloc(BUS_MUSIC).noiseLayer(NOISE_WHITE, 1, s, 0.0, 0.03)
            .filter(FILT_BP, 600, 5000, s * 0.5, 1.2, false).out(0.35, 0, 0.4, 0);
        v.delay = offset;
    }

    // ---- the sequencer ------------------------------------------------------------

    onStep(offset: i32): void {
        const s = this.stepInBar;
        if (s == 0) {
            if (this.pending >= 0 && this.pendingQ <= Q_BAR) {
                this.enter(this.pending, false, this.pending == MUS_MEGA_RISER || this.pending == MUS_RESULTS
                    || this.pending == MUS_TITLE || this.pending == MUS_MEGA_AIR);
            }
            this.barCount++;
            this.applyChord();
        } else if ((s & 3) == 0 && this.pending >= 0 && this.pendingQ == Q_BEAT) {
            this.enter(this.pending, false, true);
            this.stepInBar = 0;
            this.barCount++;
            this.applyChord();
        }
        if ((this.stepInBar & 3) == 0) this.beatCount++;
        if (this.ticks > 0) {
            this.ticks--;
            this.tickNow++;
            this.tickOffset = offset;
        }
        if (this.section < 0) return;
        const step = this.stepInBar;
        const row = (unchecked(SEC_START[this.section]) + this.barInSection) * 6;
        // the bar's effects: a crash, an impact
        if (step == 0) {
            const fx = unchecked(SEC_ROWS[row + 5]);
            if ((fx & FX_CRASH) != 0) this.drum(6, 2, offset);
            if ((fx & FX_IMPACT) != 0) this.impact(offset, 0.8);
        }
        // a beat ahead of an impact: its swell
        if (step == 12) {
            const next = this.nextRow();
            if (next >= 0 && (unchecked(SEC_ROWS[next + 5]) & FX_IMPACT) != 0) {
                this.swell(<i32>(this.stepLen * 4), offset);
            }
        }
        // drums
        const dOff = unchecked(SEC_ROWS[row]);
        if (dOff >= 0) {
            const bits = unchecked(PAT[dOff + step]);
            if (bits != 0) {
                for (let k = 0; k < 7; k++) {
                    const vel = (bits >> (2 * k)) & 3;
                    if (vel != 0) this.drum(k, vel, offset);
                }
            }
        }
        // bass
        const bOff = unchecked(SEC_ROWS[row + 1]);
        if (bOff >= 0 && unchecked(SEC_BASS[this.section]) != 0) {
            const n = unchecked(PAT[bOff + step]);
            if (n > 0) this.reese.noteOn(n & 255, n >= 256);
            else if (n < 0) this.reese.noteOff();
        }
        // stabs
        const sOff = unchecked(SEC_ROWS[row + 2]);
        if (sOff >= 0) {
            const v = unchecked(PAT[sOff + step]);
            if (v > 0) this.stabs.trigger(CHORD_NOTES, this.chord * 5, v == 3 ? 1 : 0.8);
        }
        // the arp
        const aOff = unchecked(SEC_ROWS[row + 3]);
        if (aOff >= 0) {
            const v = unchecked(PAT[aOff + step]);
            if (v > 0) {
                const idx = v - 1;
                const note = unchecked(CHORD_NOTES[this.chord * 5 + idx % 5]) + 12 * (1 + idx / 5);
                this.arp.note(note, (step & 3) == 0 ? 1 : 0.75);
            }
        }
    }

    nextRow(): i32 {
        if (this.section < 0) return -1;
        let sec = this.section;
        let bar = this.barInSection + 1;
        if (this.pending >= 0 && this.pendingQ == Q_BAR) {
            sec = this.sectionFor(this.pending);
            if (sec < 0) return -1;
            bar = 0;
        }
        const bars = unchecked(SEC_BARS[sec]);
        if (bar >= bars) bar = unchecked(SEC_LOOP[sec]);
        return (unchecked(SEC_START[sec]) + bar) * 6;
    }

    advanceStep(): void {
        this.gridTime += this.stepLen;
        this.stepInBar++;
        if (this.stepInBar >= 16) {
            this.stepInBar = 0;
            this.phraseBar++;
            if (this.section >= 0) {
                this.barInSection++;
                const bars = unchecked(SEC_BARS[this.section]);
                if (this.barInSection >= bars) {
                    if (this.state == MUS_FINISH) {
                        // the one-bar stop is over: the results
                        this.enter(MUS_RESULTS, false, true);
                        this.barInSection = 0;
                    } else {
                        this.barInSection = unchecked(SEC_LOOP[this.section]);
                    }
                }
            }
        }
    }

    // ---- one block ------------------------------------------------------------------

    control(paused: bool): void {
        // the low-pass: the state's, the pause's, the crash's
        let c: f32 = 16000;
        const st = this.state;
        if (st == MUS_TITLE) c = 500;
        else if (st == MUS_MEGA_AIR) c = 900;
        this.stateCut = c;
        this.pausedAmt += this.kAmt * ((paused ? 1 : 0) - this.pausedAmt);
        if (this.crashT > 0) this.crashT--;
        this.crashAmt += this.kAmt * ((this.crashT > 0 ? 1 : 0) - this.crashAmt);
        if (paused) c = min<f32>(c, 400);
        if (this.crashT > 0) c = min<f32>(c, 1200);
        const target = Mathf.log2(c);
        const k = st == MUS_START || st == MUS_TITLE ? this.kCutSlow : this.kCut;
        this.logCut += k * (target - this.logCut);
        this.cut = Mathf.pow(2, this.logCut);
    }

    @unchecked
    render(out: Bus, paused: bool): void {
        this.control(paused);
        this.tickNow = 0;
        // the steps that start in this block
        const end = this.clock + <f64>BLOCK;
        if (this.running) {
            while (true) {
                const t = this.gridTime + ((this.stepInBar & 1) != 0 ? this.swingOff : 0);
                if (t >= end) break;
                let off = <i32>(t - this.clock);
                if (off < 0) off = 0;
                this.onStep(off);
                this.advanceStep();
                if (!this.running) break;
            }
        }
        const bus = this.bus;
        bus.clear();
        const sub = this.sub;
        for (let i = 0; i < BLOCK; i++) sub[i] = 0;
        this.pool.render(bus, bus, bus);
        this.reese.render(bus, sub);
        this.stabs.render(bus);
        this.pad.render(bus);
        this.arp.render(bus);
        this.riser.render(bus);
        this.clock = end;

        // the reese's cut-off: by the section and an LFO over the bar
        const barPhase = (<f32>this.stepInBar + <f32>((end - this.gridTime) / this.stepLen)) / 16;
        let base: f32 = 600;
        const sec = this.section;
        if (sec == SEC_WARMUP) base = 520;
        else if (sec == SEC_KICKERS) base = 700;
        else if (sec == SEC_RAILS) base = 820;
        else if (sec == SEC_SPLIT) base = 1000;
        else if (sec == SEC_DROP) base = 1250;
        else if (sec == SEC_RISER) base = 600 + 700 * this.riser.p;
        const lfo = 0.5 - 0.5 * Mathf.cos(6.2831853 * barPhase);
        this.reese.cutoff = base * (0.55 + 0.9 * lfo);

        // ---- the post chain: the low-pass, the gains, the tape --------------------
        const cut = this.cut;
        const filtered = cut < 12000;
        if (filtered) {
            const fr = Mathf.round(cut);
            this.lpL1.set(fr, 0.75);
            this.lpL2.set(fr, 1.0);
            this.lpR1.set(fr, 0.75);
            this.lpR2.set(fr, 1.0);
        }
        const g = this.gain * (1 - 0.684 * this.pausedAmt) * (1 - 0.5 * this.crashAmt);
        const bl = bus.l;
        const br = bus.r;
        const bs = bus.send;
        const ol = out.l;
        const or = out.r;
        const os = out.send;
        const tl = this.tapeL;
        const tr = this.tapeR;
        let peak: f32 = 0;
        for (let i = 0; i < BLOCK; i++) {
            let l = bl[i];
            let r = br[i];
            if (filtered) {
                this.lpL1.tick(l);
                this.lpL2.tick(this.lpL1.lp);
                l = this.lpL2.lp;
                this.lpR1.tick(r);
                this.lpR2.tick(this.lpR1.lp);
                r = this.lpR2.lp;
            }
            const s = sub[i];
            l = (l + s) * g;
            r = (r + s) * g;
            const w = this.tapeW;
            tl[w] = l;
            tr[w] = r;
            this.tapeW = (w + 1) & TAPE_MASK;
            if (this.tapeStopping || this.tapeMuted) {
                if (this.tapeMuted) {
                    l = 0;
                    r = 0;
                } else {
                    // everything pitched down to nothing over 0.3 s
                    const rp = this.tapeRead;
                    const ip = <i32>Math.floor(rp);
                    const fr = <f32>(rp - <f64>ip);
                    const a = ip & TAPE_MASK;
                    const b = (ip + 1) & TAPE_MASK;
                    const rate = this.tapeRate;
                    l = (tl[a] + (tl[b] - tl[a]) * fr) * rate;
                    r = (tr[a] + (tr[b] - tr[a]) * fr) * rate;
                    this.tapeRead = rp + <f64>rate;
                    this.tapeRate = rate - SPU_INV_RATE / 0.3;
                    if (this.tapeRate <= 0) {
                        this.tapeRate = 0;
                        this.tapeStopping = false;
                        this.tapeMuted = true;
                    }
                }
            }
            ol[i] += l;
            or[i] += r;
            os[i] += bs[i] * g;
            const a = abs<f32>(l);
            if (a > peak) peak = a;
        }
        this.level = peak;
    }

    // the review bank and the tests: one instrument alone
    test(inst: i32, note: i32, vel: f32): void {
        if (inst <= INST_CRASH) {
            this.drum(inst, <i32>(vel * 3), 0);
        } else if (inst == INST_REESE) {
            this.reese.reeseWant = 1;
            this.reese.subWant = 1;
            this.reese.reeseOn = 1;
            this.reese.subOn = 1;
            if (note > 0) this.reese.noteOn(note, false);
            else this.reese.noteOff();
            this.reese.cutoff = 900;
        } else if (inst == INST_STAB) {
            this.stabs.trigger(CHORD_NOTES, 0, vel);
        } else if (inst == INST_PAD) {
            this.pad.want = vel;
            this.pad.chord(CHORD_NOTES, 0);
        } else if (inst == INST_ARP) {
            this.arp.note(note, vel);
        } else if (inst == INST_RISER) {
            if (vel > 0) this.riser.start(<f32>(this.stepLen * 64.0) * SPU_INV_RATE, 0);
            else this.riser.stop();
        } else if (inst == INST_IMPACT) {
            this.impact(0, vel);
        }
    }

    stopAll(): void {
        this.pool.stopAll();
        this.reese.noteOff();
        this.pad.want = 0;
        this.riser.stop();
    }
}
