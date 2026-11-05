// The Spu (docs/AUDIO.md, sections 1 to 3): Avalanche Air's one audio
// processor. Every sound of the game is synthesised here, on the audio
// thread: the board (board.as), the one-shots and the interface (sfx.as)
// from a pool of 24 voices (voices.as), the music (sequencer.as), the
// announcer (formant.as), the crowd (crowd.as); mixed in buses with the
// announcer's duck, through the SPU-style reverb (reverb.as) and a soft-knee
// limiter at -1 dBFS. Everything renders at 22,050 Hz in blocks of 28
// samples and is interpolated up to the output rate with the SPU's 4-point
// Gaussian. Nothing is allocated in process; the clock is the sample count.
import { AudioProcessor } from "rive/audio";
import { BLOCK, CONTROL_RATE, Rng, SPU_RATE, smoothCoef } from "./dsp";
import { Bus, VoicePool } from "./voices";
import { Board } from "./board";
import { Crowd } from "./crowd";
import { Music } from "./sequencer";
import { Reverb } from "./reverb";
import { Speech } from "./formant";
import {
    countBeep, gradeStamp, restartWhoosh, sfxBail, sfxConfettiPops, sfxCrash, sfxGate, sfxGrab, sfxGrindEnd, sfxOllieReady,
    sfxGrindStart, sfxLand, sfxOllie, sfxPerfect, sfxSpin, startJingle, tallyEnd, tallyTick, uiBack, uiMove, uiSelect,
} from "./sfx";
import {
    CUE_BAIL, CUE_CHEER, CUE_CONFETTI, CUE_COUNT, CUE_CRASH, CUE_GATE, CUE_GRAB, CUE_GRADE, CUE_GRIND_END,
    CUE_GRIND_START, CUE_LAND, CUE_MUSIC_CRASH, CUE_OLLIE, CUE_OLLIE_READY, CUE_PERFECT, CUE_RESTART, CUE_SAY, CUE_SHUT_UP, CUE_SPIN,
    CUE_START, CUE_TALLY_END, CUE_TALLY_TICK, CUE_TEST, CUE_UI_BACK, CUE_UI_MOVE, CUE_UI_SELECT, Cue, Knobs, Meter,
    SpuInputs,
} from "./shared";

// The buses' levels: the mix of AUDIO.md, section 11 (calibrated by
// audio/analyze.py on the review renders).
const MUSIC_LEVEL: f32 = 0.33;
const SFX_LEVEL: f32 = 0.34;       // the board's layers and the crowd
const HIT_LEVEL: f32 = 0.85;       // the one-shots (the pool's effects)
const UI_LEVEL: f32 = 1.2;
const VOX_LEVEL: f32 = 0.75;
const REVERB_WET: f32 = 0.55;
const CEILING: f32 = 0.891;        // -1 dBFS
const KNEE: f32 = 0.6;

export class Spu extends AudioProcessor<SpuInputs> {
    inputs: SpuInputs? = null;
    knobs: Knobs = new Knobs();
    cue: Cue = new Cue();
    meter: Meter = new Meter();
    channels: i32 = 2;
    rate: f64 = 48000;

    pool: VoicePool = new VoicePool(24);
    board: Board = new Board();
    music: Music = new Music();
    speech: Speech = new Speech();
    crowd: Crowd = new Crowd();
    reverb: Reverb = new Reverb();
    rng: Rng = new Rng();
    seeded: bool = false;
    knobSeq: f64 = -1;
    staleFrames: f64 = 0;
    stale: bool = false;

    musicBus: Bus = new Bus();
    sfxBus: Bus = new Bus();
    hitBus: Bus = new Bus();
    uiBus: Bus = new Bus();
    voxBus: Bus = new Bus();
    mixL: StaticArray<f32> = new StaticArray<f32>(BLOCK);
    mixR: StaticArray<f32> = new StaticArray<f32>(BLOCK);
    send: StaticArray<f32> = new StaticArray<f32>(BLOCK);
    // the limiter's look-ahead: the block before, and the block ready to play
    prevL: StaticArray<f32> = new StaticArray<f32>(BLOCK);
    prevR: StaticArray<f32> = new StaticArray<f32>(BLOCK);
    readyL: StaticArray<f32> = new StaticArray<f32>(BLOCK);
    readyR: StaticArray<f32> = new StaticArray<f32>(BLOCK);
    readyIdx: i32 = BLOCK;
    limGain: f32 = 1;
    limNeedPrev: f32 = 1;
    limRelease: f32 = 0;

    // the Gaussian interpolation up to the output rate
    gauss: StaticArray<f32> = new StaticArray<f32>(256 * 4);
    hl0: f32 = 0;
    hl1: f32 = 0;
    hl2: f32 = 0;
    hl3: f32 = 0;
    hr0: f32 = 0;
    hr1: f32 = 0;
    hr2: f32 = 0;
    hr3: f32 = 0;
    pos: f64 = 0;
    step: f64 = 0.459375;

    // the mixer
    musicG: f32 = 0;
    sfxG: f32 = 0;
    hitG: f32 = 0;
    uiG: f32 = 0;
    voxG: f32 = 0;
    duckEnv: f32 = 0;
    kGain: f32 = 0;
    kDuckUp: f32 = 0;
    kDuckDown: f32 = 0;
    peakMusic: f32 = 0;
    peakMaster: f32 = 0;
    blocks: f64 = 0;

    override init(sampleRate: f64, maxFrames: i32, channels: i32, inputs: SpuInputs): void {
        this.inputs = inputs;
        this.channels = channels;
        this.rate = sampleRate > 0 ? sampleRate : 48000;
        this.step = <f64>SPU_RATE / this.rate;
        // the SPU's interpolation: 4 taps of a Gaussian (sigma 0.57 samples)
        for (let k = 0; k < 256; k++) {
            const f = <f32>k / 256;
            let sum: f32 = 0;
            for (let t = 0; t < 4; t++) {
                const d = <f32>(t - 1) - f;
                const w = Mathf.exp(-d * d / <f32>0.6498);
                this.gauss[k * 4 + t] = w;
                sum += w;
            }
            for (let t = 0; t < 4; t++) this.gauss[k * 4 + t] /= sum;
        }
        this.kGain = smoothCoef(0.02, CONTROL_RATE);
        this.kDuckUp = smoothCoef(0.02, CONTROL_RATE);
        this.kDuckDown = smoothCoef(0.3, CONTROL_RATE);
        this.limRelease = smoothCoef(0.15, CONTROL_RATE);
    }

    // ---- the cues ------------------------------------------------------------------

    handle(c: Cue): void {
        const k = c.kind;
        const p = this.pool;
        if (k == CUE_OLLIE) sfxOllie(p, c.a);
        else if (k == CUE_LAND) sfxLand(p, c.a, <i32>c.b);
        else if (k == CUE_PERFECT) sfxPerfect(p);
        else if (k == CUE_CRASH) {
            sfxCrash(p, this.rng, c.a);
            this.music.crashDuck();
        } else if (k == CUE_BAIL) sfxBail(p, this.rng);
        else if (k == CUE_GRIND_START) sfxGrindStart(p, <i32>c.a);
        else if (k == CUE_GRIND_END) sfxGrindEnd(p);
        else if (k == CUE_SPIN) sfxSpin(p, c.a, c.b > 0.5);
        else if (k == CUE_GRAB) sfxGrab(p);
        else if (k == CUE_OLLIE_READY) sfxOllieReady(p);
        else if (k == CUE_SAY) {
            const b = <i32>c.b;
            this.speech.say(<i32>c.a, b % 10, c.c, c.d, b >= 10);
        } else if (k == CUE_COUNT) {
            const n = <i32>c.a;
            countBeep(p, n == 10 ? 1 : n);
        } else if (k == CUE_UI_MOVE) uiMove(p);
        else if (k == CUE_UI_SELECT) uiSelect(p);
        else if (k == CUE_UI_BACK) uiBack(p);
        else if (k == CUE_TALLY_TICK) {
            // on the music's 16ths when it plays
            if (this.music.running) this.music.tick();
            else tallyTick(p);
        } else if (k == CUE_TALLY_END) tallyEnd(p);
        else if (k == CUE_GRADE) gradeStamp(p);
        else if (k == CUE_RESTART) {
            this.music.tapeStop();
            this.speech.shutUp();
            p.release(0);
            restartWhoosh(p);
        } else if (k == CUE_CONFETTI) {
            sfxConfettiPops(p, this.rng);
            this.crowd.cue(1);
        } else if (k == CUE_GATE) sfxGate(p);
        else if (k == CUE_CHEER) this.crowd.cue(c.a);
        else if (k == CUE_MUSIC_CRASH) this.music.crashDuck();
        else if (k == CUE_START) {
            startJingle(p);
            this.crowd.cue(0.6);
        } else if (k == CUE_SHUT_UP) this.speech.shutUp();
        else if (k == CUE_TEST) this.music.test(<i32>c.a, <i32>c.b, c.c);
    }

    // ---- one internal block -----------------------------------------------------------

    @unchecked
    renderBlock(): void {
        const k = this.knobs;
        if (!this.seeded) {
            const s: u32 = k.seed >= 1 && k.seed < 1e9 ? <u32>k.seed : 1;
            this.pool.seed = s;
            this.music.pool.seed = s + 1;
            this.rng.seed(s, 21);
            this.board.seed(s);
            this.seeded = true;
        }
        // knobs that stopped moving: the main lane is stopped (a paused Scene3D,
        // a hitch): the music as paused, the board and the crowd fading out
        const stale = this.stale;
        if (stale) {
            k.onCourse = 0;
            k.crowd = 0;
        }
        this.music.request(k.music);
        this.board.control(k);
        this.crowd.control(k.crowd, this.pool);
        this.speech.control();

        // the announcer's duck: the music -4 dB, the board -2 dB
        const speaking: f32 = this.speech.speaking ? 1 : 0;
        this.duckEnv += (speaking > this.duckEnv ? this.kDuckUp : this.kDuckDown) * (speaking - this.duckEnv);
        this.board.duck = 1 - 0.206 * this.duckEnv;
        const live: f32 = k.mute > 0.5 ? 0 : 1;
        // the first block starts at the settings' levels, then they glide (20 ms)
        const kg = this.blocks == 0 ? <f32>1 : this.kGain;
        this.musicG += kg * (k.musicVolume * live * MUSIC_LEVEL * (1 - 0.369 * this.duckEnv) - this.musicG);
        this.sfxG += kg * (k.sfxVolume * live * SFX_LEVEL - this.sfxG);
        this.hitG += kg * (k.sfxVolume * live * HIT_LEVEL - this.hitG);
        this.uiG += kg * (k.sfxVolume * live * UI_LEVEL - this.uiG);
        this.voxG += kg * (k.voiceVolume * live * VOX_LEVEL - this.voxG);

        const mb = this.musicBus;
        const sb = this.sfxBus;
        const hb = this.hitBus;
        const ub = this.uiBus;
        const vb = this.voxBus;
        mb.clear();
        sb.clear();
        hb.clear();
        ub.clear();
        vb.clear();
        this.music.render(mb, k.paused > 0.5 || stale);
        for (let t = 0; t < this.music.tickNow; t++) tallyTick(this.pool);
        this.board.render(sb);
        this.pool.render(hb, hb, ub);
        this.crowd.render(sb);
        this.speech.render(vb, 0.35);

        const mg = this.musicG;
        const sg = this.sfxG;
        const hg = this.hitG;
        const ug = this.uiG;
        const vg = this.voxG;
        const L = this.mixL;
        const R = this.mixR;
        const S = this.send;
        let pm: f32 = 0;
        for (let i = 0; i < BLOCK; i++) {
            const ml = mb.l[i] * mg;
            const mr = mb.r[i] * mg;
            L[i] = ml + sb.l[i] * sg + hb.l[i] * hg + ub.l[i] * ug + vb.l[i] * vg;
            R[i] = mr + sb.r[i] * sg + hb.r[i] * hg + ub.r[i] * ug + vb.r[i] * vg;
            S[i] = mb.send[i] * mg + sb.send[i] * sg + hb.send[i] * hg + ub.send[i] * ug + vb.send[i] * vg;
            const a = max<f32>(abs<f32>(ml), abs<f32>(mr));
            if (a > pm) pm = a;
        }
        this.reverb.process(S, L, R, REVERB_WET);
        if (pm > this.peakMusic) this.peakMusic = pm;

        // the limiter: a block of look-ahead, a soft knee to -1 dBFS
        let peak: f32 = 0;
        for (let i = 0; i < BLOCK; i++) {
            let a = abs<f32>(L[i]);
            if (!(a < 1e6)) {
                // a NaN or a blow-up: silence this block rather than fail
                L[i] = 0;
                R[i] = 0;
                a = 0;
            }
            const b = abs<f32>(R[i]);
            if (!(b < 1e6)) {
                L[i] = 0;
                R[i] = 0;
            } else if (b > a) a = b;
            if (a > peak) peak = a;
        }
        let need: f32 = 1;
        if (peak > KNEE) {
            const over = (peak - KNEE) / (CEILING - KNEE);
            const outPeak = KNEE + (CEILING - KNEE) * (1 - Mathf.exp(-over));
            need = outPeak / peak;
        }
        const target = min<f32>(need, this.limNeedPrev);
        const g0 = this.limGain;
        let g1: f32;
        if (target < g0) g1 = target;
        else g1 = min<f32>(g0 + (1 - g0) * this.limRelease, target);
        const pl = this.prevL;
        const pr = this.prevR;
        const rl = this.readyL;
        const rr = this.readyR;
        let pk: f32 = 0;
        for (let i = 0; i < BLOCK; i++) {
            const g = g0 + (g1 - g0) * (<f32>(i + 1) / <f32>BLOCK);
            let yl = pl[i] * g;
            let yr = pr[i] * g;
            if (yl > CEILING) yl = CEILING;
            if (yl < -CEILING) yl = -CEILING;
            if (yr > CEILING) yr = CEILING;
            if (yr < -CEILING) yr = -CEILING;
            rl[i] = yl;
            rr[i] = yr;
            pl[i] = L[i];
            pr[i] = R[i];
            const a = max<f32>(abs<f32>(yl), abs<f32>(yr));
            if (a > pk) pk = a;
        }
        this.limGain = g1;
        this.limNeedPrev = need;
        if (pk > this.peakMaster) this.peakMaster = pk;
        this.readyIdx = 0;
        this.blocks += 1;
    }

    // ---- the output --------------------------------------------------------------------

    @unchecked
    override process(out: StaticArray<f32>, frames: i32, startFrame: f64): void {
        const inputs = this.inputs!;
        inputs.knobs.latestInto(this.knobs);
        const seq = inputs.knobs.seq;
        if (seq != this.knobSeq) {
            this.knobSeq = seq;
            this.staleFrames = 0;
        } else {
            this.staleFrames += <f64>frames;
        }
        this.stale = this.staleFrames > 0.25 * this.rate;
        const cue = this.cue;
        while (inputs.cues.receiveInto(cue)) this.handle(cue);
        const ch = this.channels;
        const gt = this.gauss;
        let pos = this.pos;
        const step = this.step;
        for (let i = 0; i < frames; i++) {
            pos += step;
            while (pos >= 1) {
                pos -= 1;
                if (this.readyIdx >= BLOCK) this.renderBlock();
                const j = this.readyIdx;
                this.hl0 = this.hl1;
                this.hl1 = this.hl2;
                this.hl2 = this.hl3;
                this.hl3 = this.readyL[j];
                this.hr0 = this.hr1;
                this.hr1 = this.hr2;
                this.hr2 = this.hr3;
                this.hr3 = this.readyR[j];
                this.readyIdx = j + 1;
            }
            let ti = <i32>(pos * 256);
            if (ti > 255) ti = 255;
            if (ti < 0) ti = 0;
            const b = ti * 4;
            const w0 = gt[b];
            const w1 = gt[b + 1];
            const w2 = gt[b + 2];
            const w3 = gt[b + 3];
            const l = w0 * this.hl0 + w1 * this.hl1 + w2 * this.hl2 + w3 * this.hl3;
            const r = w0 * this.hr0 + w1 * this.hr1 + w2 * this.hr2 + w3 * this.hr3;
            const o = i * ch;
            if (ch == 1) {
                out[o] = 0.5 * (l + r);
            } else {
                out[o] = l;
                out[o + 1] = r;
            }
        }
        this.pos = pos;

        const m = this.meter;
        const mu = this.music;
        m.bar = mu.barCount;
        m.beat = mu.beatCount;
        m.step = mu.stepInBar;
        m.speaking = this.speech.current();
        m.lineSeq = this.speech.lineSeq;
        m.musicState = mu.state;
        m.musicLevel = this.peakMusic;
        m.masterLevel = this.peakMaster;
        m.voices = this.pool.sounding();
        m.frames += <f64>frames;
        m.speechPeak = this.speech.prePeak;
        this.speech.prePeak = 0;
        inputs.meter.publish(m);
        this.peakMusic = 0;
        this.peakMaster = 0;
    }
}
