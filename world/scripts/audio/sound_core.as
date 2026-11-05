// The main lane's half of the sound (docs/AUDIO.md, sections 1 and 2): it
// starts the Spu once, publishes the knobs every frame from game_state's
// `game`, turns game.events into cues (and the announcer's lines), reads
// the meter back into game.audio, and restarts the processor if it fails
// (a few times). sound.as (the Sound node) and the audio lab run it.
import { Audio, AudioHandle } from "rive/audio";
import { Spu } from "./spu";
import { Announcer } from "./announcer";
import {
    CUE_BAIL, CUE_CHEER, CUE_CONFETTI, CUE_COUNT, CUE_CRASH, CUE_GATE, CUE_GRAB, CUE_GRADE, CUE_GRIND_END,
    CUE_GRIND_START, CUE_LAND, CUE_OLLIE, CUE_OLLIE_READY, CUE_PERFECT, CUE_RESTART, CUE_SPIN, CUE_START, CUE_TALLY_END,
    CUE_TALLY_TICK, CUE_UI_BACK, CUE_UI_MOVE, CUE_UI_SELECT, CueSender, Knobs, MUS_COUNTDOWN, MUS_FINISH,
    MUS_KICKERS, MUS_MEGA_AIR, MUS_MEGA_DROP, MUS_MEGA_RISER, MUS_RAILS, MUS_RESULTS, MUS_SPLIT, MUS_START,
    MUS_TITLE, MUS_WAIT, MUS_WARMUP, Meter, SpuInputs,
} from "./shared";
import {
    EVENT_RING, EV_BAIL, EV_BANK, EV_CONFETTI, EV_COUNT, EV_CRASH, EV_FINISH, EV_GATE, EV_GRAB, EV_GRADE,
    EV_GRIND_END, EV_GRIND_START, EV_LAND, EV_LINE, EV_MEGA_TAKEOFF, EV_OLLIE, EV_OLLIE_READY, EV_PERFECT, EV_RESTART, EV_SECTION,
    EV_SPIN_HALF, EV_START, EV_TALLY_END, EV_TALLY_TICK, EV_UI_BACK, EV_UI_MOVE, EV_UI_SELECT, GRIND_NONE, Game,
    PHASE_COUNTDOWN, PHASE_CRASH, PHASE_FINISH, PHASE_INITIALS, PHASE_QUICKSTART, PHASE_RESULTS, PHASE_RIDING,
    PHASE_TITLE,
} from "../game_state";

// where the mega-jump's in-run starts and the finish arch stands (COURSE.md)
export const S_MEGA: f32 = 1240;
export const S_ARCH: f32 = 1400;
export const S_COURSE: f32 = 1420;
const MAX_RESTARTS: i32 = 3;

export class SoundCore {
    inputs: SpuInputs = new SpuInputs();
    knobs: Knobs = new Knobs();
    meter: Meter = new Meter();
    out: CueSender;
    announcer: Announcer;
    handle: AudioHandle? = null;
    restarts: i32 = 0;
    cursor: i32 = 0;
    started: bool = false;
    failed: bool = false;

    // what the events told the music
    startPressed: bool = false;
    megaAir: bool = false;
    megaDropped: bool = false;
    restarting: bool = false;
    lastSection: i32 = 0;
    seed: u32 = 1;

    constructor() {
        this.out = new CueSender(this.inputs.cues);
        this.announcer = new Announcer(this.out);
    }

    start(g: Game): void {
        this.cursor = g.events.written;
        this.seed = g.seed;
        this.announcer.seed(g.seed);
        this.knobsFrom(g);
        this.inputs.knobs.publish(this.knobs);
        this.handle = Audio.start(() => new Spu(), this.inputs);
        this.started = true;
    }

    // every frame
    update(g: Game): void {
        if (!this.started) this.start(g);
        this.watch();
        this.events(g);
        this.knobsFrom(g);
        this.inputs.knobs.publish(this.knobs);
        const m = this.inputs.meter.latest();
        if (m != null) {
            const v = m.value;
            g.audio.beat = v.beat;
            g.audio.bar = v.bar;
            g.audio.speakingLine = v.speaking;
            g.audio.lineSeq = v.lineSeq;
            this.meter.beat = v.beat;
            this.meter.bar = v.bar;
            this.meter.speaking = v.speaking;
            this.meter.lineSeq = v.lineSeq;
            this.meter.musicState = v.musicState;
            this.meter.masterLevel = v.masterLevel;
            this.meter.voices = v.voices;
            this.meter.frames = v.frames;
            this.meter.speechPeak = v.speechPeak;
        }
        g.audio.failed = this.failed;
    }

    // a processor that failed is started again, a few times (Rive's threading guide)
    watch(): void {
        const h = this.handle;
        if (h == null) return;
        const why = h.failed;
        if (why == null) return;
        if (this.restarts >= MAX_RESTARTS) {
            this.failed = true;
            return;
        }
        console.warn("Spu failed, restarting: " + why);
        this.restarts++;
        h.release();
        this.handle = Audio.start(() => new Spu(), this.inputs);
    }

    // ---- the events -------------------------------------------------------------------

    events(g: Game): void {
        const ev = g.events;
        if (ev.written - this.cursor > EVENT_RING) this.cursor = ev.written - EVENT_RING;
        let bankValue: f32 = -1;
        let bankPraise = 0;
        let perfect = false;
        const out = this.out;
        const an = this.announcer;
        while (this.cursor < ev.written) {
            const i = this.cursor % EVENT_RING;
            this.cursor++;
            const kind = ev.kinds[i];
            const a = ev.a[i];
            const b = ev.b[i];
            if (kind == EV_OLLIE) out.send(CUE_OLLIE, a);
            else if (kind == EV_OLLIE_READY) out.send(CUE_OLLIE_READY);
            else if (kind == EV_LAND) {
                out.send(CUE_LAND, a, b);
                if (this.megaAir) {
                    this.megaAir = false;
                    this.megaDropped = true;
                }
            } else if (kind == EV_CRASH) {
                out.send(CUE_CRASH, a);
                an.crash();
                if (this.megaAir) {
                    this.megaAir = false;
                    this.megaDropped = true;
                }
            } else if (kind == EV_BAIL) {
                out.send(CUE_BAIL);
                an.bail();
                if (this.megaAir) {
                    this.megaAir = false;
                    this.megaDropped = true;
                }
            } else if (kind == EV_GRIND_START) out.send(CUE_GRIND_START, a);
            else if (kind == EV_GRIND_END) out.send(CUE_GRIND_END);
            else if (kind == EV_SPIN_HALF) out.send(CUE_SPIN, a, b);
            else if (kind == EV_GRAB) out.send(CUE_GRAB, a);
            else if (kind == EV_BANK) {
                bankValue = a;
                bankPraise = <i32>b;
            } else if (kind == EV_PERFECT) {
                out.send(CUE_PERFECT);
                perfect = true;
            } else if (kind == EV_COUNT) {
                out.send(CUE_COUNT, a);
                an.count(<i32>a);
                if (<i32>a == 0) this.restarting = false;
            } else if (kind == EV_FINISH) {
                out.send(CUE_CHEER, 1);
                an.finish();
            } else if (kind == EV_RESTART) {
                out.send(CUE_RESTART);
                this.megaAir = false;
                this.megaDropped = false;
                this.restarting = true;
                this.lastSection = 0;
            } else if (kind == EV_UI_MOVE) out.send(CUE_UI_MOVE);
            else if (kind == EV_UI_SELECT) out.send(CUE_UI_SELECT);
            else if (kind == EV_UI_BACK) out.send(CUE_UI_BACK);
            else if (kind == EV_TALLY_TICK) out.send(CUE_TALLY_TICK);
            else if (kind == EV_TALLY_END) out.send(CUE_TALLY_END);
            else if (kind == EV_GRADE) {
                out.send(CUE_GRADE, a);
                an.grade(<i32>a, b > 0.5);
            } else if (kind == EV_GATE) out.send(CUE_GATE);
            else if (kind == EV_CONFETTI) out.send(CUE_CONFETTI);
            else if (kind == EV_SECTION) {
                const s = <i32>a;
                if (s == 6 && this.lastSection != 6) an.finalJump();
                this.lastSection = s;
            } else if (kind == EV_LINE) an.line(a > 0.5);
            else if (kind == EV_MEGA_TAKEOFF) {
                this.megaAir = true;
            } else if (kind == EV_START) {
                out.send(CUE_START);
                an.title();
                this.startPressed = true;
            }
        }
        if (bankValue >= 0) {
            an.bank(bankValue, bankPraise, perfect, g.comboMult, g.trick);
        } else if (perfect) {
            an.perfect();
        }
    }

    // ---- the knobs ------------------------------------------------------------------------

    musicFor(g: Game): i32 {
        const ph = g.phase;
        const r = g.rider;
        if (ph == PHASE_TITLE) {
            this.megaAir = false;
            this.megaDropped = false;
            return this.startPressed ? MUS_START : MUS_TITLE;
        }
        this.startPressed = false;
        if (ph == PHASE_COUNTDOWN || ph == PHASE_QUICKSTART) {
            // a new run
            this.megaAir = false;
            this.megaDropped = false;
            return ph == PHASE_COUNTDOWN ? MUS_COUNTDOWN : MUS_WAIT;
        }
        if (ph == PHASE_RIDING || ph == PHASE_CRASH) {
            if (this.restarting) return MUS_WAIT;
            if (this.megaAir) return MUS_MEGA_AIR;
            if (this.megaDropped) return MUS_MEGA_DROP;
            if (r.s >= S_MEGA || r.section >= 6) return r.section >= 7 ? MUS_MEGA_DROP : MUS_MEGA_RISER;
            if (r.section == 5) return MUS_SPLIT;
            if (r.section == 4) return MUS_RAILS;
            if (r.section == 3) return MUS_KICKERS;
            return MUS_WARMUP;
        }
        if (ph == PHASE_FINISH) return MUS_FINISH;
        if (ph == PHASE_RESULTS || ph == PHASE_INITIALS) return MUS_RESULTS;
        return MUS_TITLE;
    }

    knobsFrom(g: Game): void {
        const k = this.knobs;
        const r = g.rider;
        const ph = g.phase;
        k.speed = r.speed;
        k.carve = r.carve;
        k.skid = r.skid;
        k.surface = r.surface;
        k.tuck = r.tuck;
        k.air = r.inAir ? 1 : 0;
        k.airTime = r.airTime;
        k.spinRate = r.spinRate;
        k.flipRate = r.flipRate;
        k.grind = r.grind;
        k.grindSpeed = r.grind != GRIND_NONE ? r.speed : 0;
        k.balance = r.balance;
        k.progress = Mathf.min(Mathf.max(r.s / S_COURSE, 0), 1);
        const riding = ph == PHASE_COUNTDOWN || ph == PHASE_QUICKSTART || ph == PHASE_RIDING
            || ph == PHASE_CRASH || ph == PHASE_FINISH;
        k.onCourse = riding && !r.tumbling ? 1 : 0;
        // the crowd: at the start gate and the finish arch
        let crowd: f32 = 0;
        if (ph == PHASE_COUNTDOWN || ph == PHASE_QUICKSTART || ph == PHASE_RIDING || ph == PHASE_CRASH) {
            crowd = Mathf.max(0, 1 - r.s / 70) * 0.45;
            crowd = Mathf.max(crowd, Mathf.max(0, 1 - Mathf.abs(r.s - S_ARCH) / 140) * 0.8);
        } else if (ph == PHASE_FINISH) crowd = 0.9;
        else if (ph == PHASE_RESULTS || ph == PHASE_INITIALS) crowd = 0.15;
        k.crowd = crowd;
        k.music = this.musicFor(g);
        const st = g.settings;
        k.paused = st.paused ? 1 : 0;
        k.musicVolume = st.musicVolume;
        k.sfxVolume = st.sfxVolume;
        k.voiceVolume = st.voiceVolume;
        k.mute = st.mute ? 1 : 0;
        k.seed = <f32>(this.seed & 0xffffff);
    }
}
