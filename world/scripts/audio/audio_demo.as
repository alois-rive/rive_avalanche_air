// Drivers for checking the sound without the gameplay (docs/AUDIO.md,
// section 12): they write `game` (the rider, the phase, the events) as the
// gameplay would.
//
// AudioDemo: a scripted session of about 70 s: the title, Start, the
//   countdown, carving at rising speed through the sections, ollies, spins,
//   grabs, perfect and sketchy landings, rail, box and log grinds, banks with
//   praise, a crash, the split, the mega-jump's riser, air and drop, the
//   finish, the tally, the grade, a restart with the quick start, a pause.
// AudioBank: every sound alone, in sequence, with its times logged
//   ("BANK name t0 t1"), for the review wavs (audio/review/) and the
//   degraded tier's bank (AUDIO.md, section 10).
import {
    EV_BAIL, EV_BANK, EV_CONFETTI, EV_COUNT, EV_CRASH, EV_FINISH, EV_GATE, EV_GRAB, EV_GRADE, EV_GRIND_END,
    EV_GRIND_START, EV_LAND, EV_LINE, EV_MEGA_TAKEOFF, EV_OLLIE, EV_PERFECT, EV_RESTART, EV_SECTION, EV_SPIN_HALF,
    EV_START, EV_TALLY_END, EV_TALLY_TICK, EV_UI_BACK, EV_UI_MOVE, EV_UI_SELECT, FLIP_BACK, FLIP_NONE, GRAB_INDY,
    GRAB_METHOD, GRAB_MELON, GRAB_NONE, GRIND_BOX, GRIND_LOG, GRIND_NONE, GRIND_RAIL, Game, LAND_CLEAN, LAND_PERFECT,
    LAND_SKETCHY, PHASE_COUNTDOWN, PHASE_CRASH, PHASE_FINISH, PHASE_QUICKSTART, PHASE_RESULTS, PHASE_RIDING,
    PHASE_TITLE, PRAISE_NICE, PRAISE_SICK, PRAISE_SKETCHY, PRAISE_UNREAL, SURF_GROOMED, SURF_ICE,
    SURF_POWDER,
} from "../game_state";
import { CUE_TEST, packTrick } from "./shared";
import { SoundCore } from "./sound_core";
import {
    INST_ARP, INST_CRASH, INST_GHOST, INST_HAT, INST_IMPACT, INST_KICK, INST_OPEN, INST_PAD, INST_REESE, INST_RIDE,
    INST_RISER, INST_SNARE, INST_STAB,
} from "./sequencer";

function smooth01(x: f32): f32 {
    const t = Mathf.min(Mathf.max(x, 0), 1);
    return t * t * (3 - 2 * t);
}

export class AudioDemo {
    t: f32 = 0;
    prev: f32 = -1;
    done: bool = false;

    cross(at: f32): bool {
        return this.prev < at && this.t >= at;
    }

    setTrick(g: Game, spin: i32, dir: i32, flip: i32, g1: i32, g2: i32, grind: i32): void {
        const k = g.trick;
        k.spin = spin;
        k.dir = dir;
        k.flip = flip;
        k.grab1 = g1;
        k.grab2 = g2;
        k.switchStance = false;
        k.grind = grind;
    }

    step(g: Game, dt: f32): void {
        this.prev = this.t;
        this.t += dt;
        const t = this.t;
        const r = g.rider;
        const ev = g.events;

        // ---- the title, Start, the countdown -------------------------------------
        if (t < 5.5) {
            g.phase = PHASE_TITLE;
            r.speed = 0;
        }
        if (this.cross(2.6) || this.cross(3.0) || this.cross(3.4)) ev.push(EV_UI_MOVE);
        if (this.cross(3.8)) ev.push(EV_UI_BACK);
        if (this.cross(4.5)) {
            ev.push(EV_UI_SELECT);
            ev.push(EV_START);
        }
        if (this.cross(5.5)) {
            g.phase = PHASE_COUNTDOWN;
            ev.push(EV_COUNT, 3);
        }
        if (this.cross(6.5)) ev.push(EV_COUNT, 2);
        if (this.cross(7.5)) ev.push(EV_COUNT, 1);
        if (this.cross(8.5)) {
            ev.push(EV_COUNT, 0);
            g.phase = PHASE_RIDING;
            r.section = 1;
        }

        // ---- riding: the speed, the carving, the sections -------------------------
        const riding = t >= 8.5 && t < 53;
        if (riding) {
            let speed: f32 = 0;
            if (t < 12.5) speed = 10 * smooth01((t - 8.5) / 4);
            else if (t < 26) speed = 10 + 7 * smooth01((t - 12.5) / 10);
            else if (t < 38) speed = 15 + 2 * Mathf.sin(t);
            else if (t < 43) speed = 20 + 2 * smooth01((t - 38) / 5);
            else if (t < 47.5) speed = 22 + 3 * smooth01((t - 43) / 4.5);
            else speed = 25 - 3 * smooth01((t - 50.5) / 2.5);
            r.speed = speed;
            r.carve = Mathf.max(0, Mathf.sin((t - 8.5) * 2.8)) * (t > 10 ? 0.9 : 0.3);
            r.skid = t > 15.5 && t < 16.3 ? <f32>0.9 : (t > 41 && t < 41.6 ? <f32>1 : <f32>0);
            r.tuck = t >= 43 && t < 47.5 ? <f32>1 : (t >= 38 && t < 43 ? <f32>0.6 : <f32>0);
            r.lean = r.carve;
            r.surface = t >= 23 && t < 26 ? SURF_POWDER : (t >= 26 && t < 28 ? SURF_ICE : SURF_GROOMED);
            r.s = (t - 8.5) * 31;
        }
        if (this.cross(12.5)) {
            r.section = 2;
            ev.push(EV_SECTION, 2);
        }

        // an ollie and a 360: a small bank, no praise
        if (this.cross(14.0)) {
            ev.push(EV_OLLIE, 5);
            r.inAir = true;
            r.onGround = false;
        }
        if (this.cross(14.3)) ev.push(EV_SPIN_HALF, 1, 0);
        if (this.cross(14.6)) ev.push(EV_SPIN_HALF, 1, 0);
        if (this.cross(14.9)) {
            r.inAir = false;
            r.onGround = true;
            this.setTrick(g, 360, 1, FLIP_NONE, GRAB_NONE, GRAB_NONE, 0);
            ev.push(EV_LAND, 5, <f32>LAND_CLEAN);
            ev.push(EV_BANK, 900, 0);
        }

        if (this.cross(18.0)) {
            r.section = 3;
            ev.push(EV_SECTION, 3);
        }
        // a kicker: a backside 720 indy, perfect: "BACKSIDE SEVEN-TWENTY INDY! PERFECT! SICK!"
        if (this.cross(19.0)) {
            ev.push(EV_OLLIE, 6);
            r.inAir = true;
            r.onGround = false;
        }
        if (this.cross(19.3) || this.cross(19.6) || this.cross(19.9) || this.cross(20.2)) ev.push(EV_SPIN_HALF, -1, 0);
        if (this.cross(19.4)) {
            ev.push(EV_GRAB, <f32>GRAB_INDY);
            r.grab = GRAB_INDY;
        }
        if (this.cross(20.6)) {
            r.inAir = false;
            r.onGround = true;
            r.grab = GRAB_NONE;
            this.setTrick(g, 720, 2, FLIP_NONE, GRAB_INDY, GRAB_NONE, 0);
            g.comboMult = 1;
            ev.push(EV_LAND, 7, <f32>LAND_PERFECT);
            ev.push(EV_PERFECT);
            ev.push(EV_BANK, 3200, <f32>PRAISE_SICK);
        }
        if (r.inAir) r.airTime += dt;
        else r.airTime = 0;

        // ---- the rail garden ---------------------------------------------------------
        if (this.cross(26.0)) {
            r.section = 4;
            ev.push(EV_SECTION, 4);
        }
        if (this.cross(27.0)) {
            ev.push(EV_OLLIE, 4);
            r.inAir = true;
        }
        if (this.cross(27.3)) {
            r.inAir = false;
            r.grind = GRIND_RAIL;
            ev.push(EV_GRIND_START, <f32>GRIND_RAIL);
        }
        if (t >= 27.3 && t < 29.1) r.balance = 0.6 * Mathf.sin((t - 27.3) * 4);
        if (this.cross(29.1)) {
            r.grind = GRIND_NONE;
            r.balance = 0;
            ev.push(EV_GRIND_END);
            r.inAir = true;
        }
        if (this.cross(29.6)) {
            r.inAir = false;
            this.setTrick(g, 0, 0, FLIP_NONE, GRAB_NONE, GRAB_NONE, 11);
            ev.push(EV_LAND, 4, <f32>LAND_SKETCHY);
            ev.push(EV_BANK, 1800, <f32>PRAISE_SKETCHY);
        }
        if (this.cross(31.0)) {
            r.grind = GRIND_BOX;
            ev.push(EV_GRIND_START, <f32>GRIND_BOX);
        }
        if (this.cross(32.2)) {
            r.grind = GRIND_NONE;
            ev.push(EV_GRIND_END);
            this.setTrick(g, 0, 0, FLIP_NONE, GRAB_NONE, GRAB_NONE, 2);
            ev.push(EV_LAND, 3, <f32>LAND_CLEAN);
            ev.push(EV_BANK, 1100, <f32>PRAISE_NICE);
        }
        if (this.cross(33.0)) {
            r.grind = GRIND_LOG;
            ev.push(EV_GRIND_START, <f32>GRIND_LOG);
        }
        if (this.cross(34.5)) {
            r.grind = GRIND_NONE;
            ev.push(EV_GRIND_END);
        }

        // ---- a crash -------------------------------------------------------------------
        if (this.cross(35.0)) {
            ev.push(EV_CRASH, 16);
            g.phase = PHASE_CRASH;
            r.tumbling = true;
        }
        if (t >= 35 && t < 37) r.speed = Mathf.max(0, 16 - (t - 35) * 12);
        if (this.cross(37.0)) {
            g.phase = PHASE_RIDING;
            r.tumbling = false;
        }

        // ---- the split ---------------------------------------------------------------------
        if (this.cross(38.0)) {
            r.section = 5;
            ev.push(EV_SECTION, 5);
        }
        if (this.cross(38.6)) {
            ev.push(EV_LINE, 1);
            r.highLine = true;
        }
        if (this.cross(40.2)) {
            ev.push(EV_OLLIE, 5);
            r.inAir = true;
        }
        if (this.cross(40.6)) ev.push(EV_SPIN_HALF, 1, 0);
        if (this.cross(41.0)) {
            r.inAir = false;
            ev.push(EV_BAIL);
        }

        // ---- the mega-jump --------------------------------------------------------------
        if (this.cross(43.0)) {
            r.section = 6;
            r.s = 1240;
            ev.push(EV_SECTION, 6);
        }
        if (this.cross(47.5)) {
            ev.push(EV_OLLIE, 7);
            ev.push(EV_MEGA_TAKEOFF);
            r.inAir = true;
        }
        if (t > 47.5 && t < 50.4) {
            const k = <i32>((t - 47.7) / 0.4);
            const kp = <i32>((this.prev - 47.7) / 0.4);
            if (t > 47.7 && k != kp && k < 7) ev.push(EV_SPIN_HALF, -1, k == 2 || k == 4 ? 1 : 0);
        }
        if (this.cross(48.1)) {
            ev.push(EV_GRAB, <f32>GRAB_METHOD);
            r.grab = GRAB_METHOD;
        }
        if (this.cross(50.5)) {
            r.inAir = false;
            r.grab = GRAB_NONE;
            this.setTrick(g, 1080, 2, FLIP_BACK, GRAB_METHOD, GRAB_NONE, 0);
            ev.push(EV_LAND, 9, <f32>LAND_PERFECT);
            ev.push(EV_PERFECT);
            ev.push(EV_BANK, 21000, <f32>PRAISE_UNREAL);
        }
        if (this.cross(51.0)) {
            r.section = 7;
            ev.push(EV_SECTION, 7);
        }
        if (t >= 51 && t < 53) r.s = 1375 + (t - 51) * 12.5;
        if (this.cross(52.9)) ev.push(EV_GATE);
        if (this.cross(53.0)) {
            ev.push(EV_FINISH);
            ev.push(EV_CONFETTI);
            g.phase = PHASE_FINISH;
        }
        if (t >= 53 && t < 55) r.speed = Mathf.max(0, 22 - (t - 53) * 11);

        // ---- the results ------------------------------------------------------------------
        if (this.cross(55.0)) {
            g.phase = PHASE_RESULTS;
            r.speed = 0;
        }
        if (t >= 55.6 && t < 57.0) {
            const k = <i32>((t - 55.6) / 0.09);
            const kp = <i32>((this.prev - 55.6) / 0.09);
            if (k != kp) ev.push(EV_TALLY_TICK);
        }
        if (this.cross(57.0)) ev.push(EV_TALLY_END);
        if (t >= 57.5 && t < 58.5) {
            const k = <i32>((t - 57.5) / 0.09);
            const kp = <i32>((this.prev - 57.5) / 0.09);
            if (k != kp) ev.push(EV_TALLY_TICK);
        }
        if (this.cross(58.5)) ev.push(EV_TALLY_END);
        if (this.cross(59.5)) ev.push(EV_GRADE, 3, 1);
        if (this.cross(62.5) || this.cross(62.9)) ev.push(EV_UI_MOVE);

        // ---- a restart, the quick start ------------------------------------------------------
        if (this.cross(64.0)) {
            ev.push(EV_RESTART);
            g.phase = PHASE_QUICKSTART;
            r.section = 1;
            r.s = 0;
            r.speed = 0;
        }
        if (this.cross(64.2)) ev.push(EV_COUNT, 10);
        if (this.cross(65.2)) {
            ev.push(EV_COUNT, 0);
            g.phase = PHASE_RIDING;
        }
        if (t >= 65.2) {
            r.speed = 10 * smooth01((t - 65.2) / 4);
            r.carve = Mathf.max(0, Mathf.sin((t - 65.2) * 2.8)) * 0.6;
            r.s = (t - 65.2) * 8;
        }
        // a pause
        g.settings.paused = t >= 68.0 && t < 70.0;
        if (this.cross(73.0)) this.done = true;
    }
}

// ---- the review bank -----------------------------------------------------------------------

export class AudioBank {
    t: f32 = 0;
    prev: f32 = -1;
    slot: f32 = 0;         // where the next item starts
    idx: i32 = 0;
    first: i32 = 0;        // the items played: first..last (the lab's bank range)
    last: i32 = 1000;
    phase: i32 = 0;        // which item is playing
    itemStart: f32 = 0;
    itemLen: f32 = 0;
    done: bool = false;

    // the items, in order: each [kind, arg, length]
    // kinds: 0 instrument, 1 cue (an event), 2 a line, 3 a trick name, 4 a board layer, 5 a music state
    kinds: StaticArray<i32> = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        3, 3, 3, 3, 3, 3,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    ];
    args: StaticArray<i32> = [
        INST_KICK, INST_SNARE, INST_GHOST, INST_HAT, INST_OPEN, INST_RIDE, INST_CRASH, INST_REESE, INST_STAB, INST_PAD,
        INST_ARP, INST_RISER, INST_IMPACT,
        EV_OLLIE, EV_LAND, 100 + EV_LAND, EV_PERFECT, EV_CRASH, EV_BAIL, EV_GRAB, EV_SPIN_HALF, EV_GATE,
        EV_GRIND_START, EV_GRIND_END, EV_CONFETTI, EV_UI_MOVE, EV_UI_SELECT, EV_UI_BACK, EV_COUNT, 100 + EV_COUNT,
        EV_TALLY_TICK, EV_TALLY_END, EV_GRADE,
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
        0, 1, 2, 3, 4, 5,
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
    ];

    itemLength(kind: i32, arg: i32): f32 {
        if (kind == 0) {
            if (arg == INST_RISER) return 7;
            if (arg == INST_PAD || arg == INST_REESE) return 4;
            if (arg == INST_ARP) return 4;
            if (arg == INST_CRASH || arg == INST_IMPACT) return 2.5;
            return 1.2;
        }
        if (kind == 1) {
            if (arg == EV_CRASH || arg == EV_CONFETTI || arg == EV_TALLY_END || arg == EV_GRADE) return 2.5;
            if (arg == EV_TALLY_TICK) return 1.6;
            return 1.0;
        }
        if (kind == 2) return 2.2;
        if (kind == 3) return 3.2;
        if (kind == 4) return 3.0;
        // music states
        if (arg == 0) return 9;      // title
        if (arg == 1) return 4;      // countdown
        if (arg == 7) return 4;      // air
        if (arg == 9) return 3;      // finish
        return 11.4;                 // 8 bars
    }

    name(kind: i32, arg: i32): string {
        return "k" + kind.toString() + "_" + arg.toString();
    }

    step(g: Game, core: SoundCore, dt: f32): void {
        this.prev = this.t;
        this.t += dt;
        const t = this.t;
        if (this.done) return;
        const r = g.rider;
        const ev = g.events;
        // the item playing: its continuous part
        if (this.idx > 0) {
            const kind = this.kinds[this.idx - 1];
            const arg = this.args[this.idx - 1];
            const u = t - this.itemStart;
            if (kind == 4) this.board(g, arg, u);
            if (kind == 0 && arg == INST_REESE && u > 2.0 && u - dt <= 2.0) core.out.send(CUE_TEST, <f32>INST_REESE, -1, 1);
            if (kind == 0 && arg == INST_PAD && u > 2.5 && u - dt <= 2.5) core.out.send(CUE_TEST, <f32>INST_PAD, 0, 0);
            if (kind == 0 && arg == INST_ARP) {
                const k = <i32>(u / 0.0882);
                const kp = <i32>((u - dt) / 0.0882);
                if (k != kp && k < 16) {
                    const notes: i32 = k % 8;
                    const n = 65 + (notes == 0 ? 0 : (notes == 1 ? 3 : (notes == 2 ? 7 : (notes == 3 ? 10 : (notes == 4 ? 12 : (notes == 5 ? 15 : (notes == 6 ? 19 : 22)))))));
                    core.out.send(CUE_TEST, <f32>INST_ARP, <f32>n, 1);
                }
            }
            if (kind == 1 && arg == EV_TALLY_TICK) {
                const k = <i32>(u / 0.09);
                const kp = <i32>((u - dt) / 0.09);
                if (k != kp && k < 12) ev.push(EV_TALLY_TICK);
            }
            if (kind == 5) this.music(g, arg, u, dt);
        }
        if (t < this.slot) return;
        // the next item
        if (this.idx > 0) {
            const kind = this.kinds[this.idx - 1];
            const arg = this.args[this.idx - 1];
            console.log("BANK " + this.name(kind, arg) + " " + this.itemStart.toString() + " " + t.toString());
        }
        this.quiet(g);
        if (this.idx < this.first) this.idx = this.first;
        if (this.idx >= this.kinds.length || this.idx > this.last) {
            this.done = true;
            console.log("BANK end " + t.toString());
            return;
        }
        const kind = this.kinds[this.idx];
        const arg = this.args[this.idx];
        this.idx++;
        this.itemStart = t;
        this.itemLen = this.itemLength(kind, arg);
        this.slot = t + this.itemLen + 0.4;
        if (kind == 0) g.settings.musicVolume = 0.8;
        if (kind == 0) {
            if (arg == INST_REESE) core.out.send(CUE_TEST, <f32>arg, 41, 1);
            else if (arg == INST_PAD) core.out.send(CUE_TEST, <f32>arg, 0, 1);
            else if (arg == INST_RISER) core.out.send(CUE_TEST, <f32>arg, 0, 1);
            else if (arg != INST_ARP) core.out.send(CUE_TEST, <f32>arg, 0, 1);
        } else if (kind == 1) {
            this.fire(g, arg);
        } else if (kind == 2) {
            core.announcer.say(arg, 2, false);
        } else if (kind == 3) {
            let p: f32 = 0;
            if (arg == 0) p = packTrick(720, 2, FLIP_NONE, GRAB_INDY, GRAB_NONE, false, 0);
            else if (arg == 1) p = packTrick(540, 1, FLIP_NONE, GRAB_NONE, GRAB_NONE, true, 0);
            else if (arg == 2) p = packTrick(0, 0, FLIP_BACK, GRAB_MELON, GRAB_NONE, false, 0);
            else if (arg == 3) p = packTrick(1080, 1, FLIP_BACK, GRAB_METHOD, 4, false, 0);
            else if (arg == 4) p = packTrick(0, 0, FLIP_NONE, GRAB_NONE, GRAB_NONE, false, 11);
            else p = packTrick(0, 0, FLIP_NONE, GRAB_NONE, GRAB_NONE, false, 23);
            core.announcer.say(100, 2, false, 0, p);
        }
    }

    fire(g: Game, arg: i32): void {
        const ev = g.events;
        if (arg == EV_LAND) ev.push(EV_LAND, 6, <f32>LAND_CLEAN);
        else if (arg == 100 + EV_LAND) ev.push(EV_LAND, 6, <f32>LAND_SKETCHY);
        else if (arg == EV_OLLIE) ev.push(EV_OLLIE, 5);
        else if (arg == EV_CRASH) ev.push(EV_CRASH, 15);
        else if (arg == EV_SPIN_HALF) ev.push(EV_SPIN_HALF, 1, 0);
        else if (arg == EV_GRIND_START) ev.push(EV_GRIND_START, <f32>GRIND_RAIL);
        else if (arg == EV_COUNT) ev.push(EV_COUNT, 3);
        else if (arg == 100 + EV_COUNT) ev.push(EV_COUNT, 0);
        else if (arg == EV_GRADE) ev.push(EV_GRADE, 3, 0);
        else if (arg == EV_TALLY_TICK) ev.push(EV_TALLY_TICK);
        else ev.push(arg);
    }

    // the board's layers: 0..2 the hiss at 5, 15, 27 m/s; 3 powder; 4 ice; 5 carve;
    // 6 skid; 7 wind in a tuck; 8 air; 9 rail; 10 box; 11 log; 12 rock
    board(g: Game, arg: i32, u: f32): void {
        const r = g.rider;
        g.phase = PHASE_RIDING;
        g.settings.musicVolume = 0;
        r.section = 2;
        r.s = 500;
        r.speed = arg == 0 ? 5 : (arg == 2 || arg == 7 ? 27 : 15);
        r.surface = arg == 3 ? SURF_POWDER : (arg == 4 ? SURF_ICE : (arg == 12 ? 3 : SURF_GROOMED));
        r.carve = arg == 5 ? 0.6 + 0.4 * Mathf.sin(u * 3) : 0;
        r.skid = arg == 6 ? 1 : 0;
        r.tuck = arg == 7 ? 1 : 0;
        r.inAir = arg == 8;
        r.airTime = arg == 8 ? u : 0;
        r.grind = arg == 9 ? GRIND_RAIL : (arg == 10 ? GRIND_BOX : (arg == 11 ? GRIND_LOG : GRIND_NONE));
        r.balance = arg == 9 ? 0.5 * Mathf.sin(u * 3) : 0;
        if (u > this.itemLen) r.speed = 0;
    }

    // the music's states: 0 title, 1 countdown, 2 warm-up, 3 kickers, 4 rails, 5 split,
    // 6 riser, 7 air, 8 drop, 9 finish, 10 results, 11 pause (the split, paused)
    music(g: Game, arg: i32, u: f32, dt: f32): void {
        const r = g.rider;
        r.speed = 0;
        g.settings.musicVolume = 0.8;
        g.settings.paused = arg == 11 && u > 2;
        if (arg == 0) g.phase = PHASE_TITLE;
        else if (arg == 1) g.phase = PHASE_COUNTDOWN;
        else if (arg == 9) g.phase = PHASE_FINISH;
        else if (arg == 10) g.phase = PHASE_RESULTS;
        else {
            g.phase = PHASE_RIDING;
            r.section = arg == 2 ? 2 : (arg == 3 ? 3 : (arg == 4 ? 4 : (arg == 5 || arg == 11 ? 5 : 6)));
            r.s = arg >= 6 && arg <= 8 ? 1250 : 500;
            if (arg == 7 && u <= dt) g.events.push(EV_MEGA_TAKEOFF);
            if (arg == 8 && u <= dt) {
                g.events.push(EV_MEGA_TAKEOFF);
                g.events.push(EV_LAND, 9, 0);
            }
        }
    }

    quiet(g: Game): void {
        const r = g.rider;
        r.speed = 0;
        r.carve = 0;
        r.skid = 0;
        r.tuck = 0;
        r.inAir = false;
        r.airTime = 0;
        r.grind = GRIND_NONE;
        r.balance = 0;
        r.surface = SURF_GROOMED;
        g.settings.paused = false;
        // between items: silence (the quick start's wait), away from the arches
        g.phase = PHASE_QUICKSTART;
        r.s = 500;
        g.settings.musicVolume = 0;
    }
}
