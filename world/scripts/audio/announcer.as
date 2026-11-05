// The announcer's choices (docs/AUDIO.md, section 6), on the main lane:
// which line answers which event, at which priority (1 highest); the
// processor (formant.as) speaks them one at a time, a higher priority
// cutting, a line waiting over 1.2 s dropped (but not the ones chained to
// the line before them: a trick name, "PERFECT!", the praise).
import {
    CUE_SAY, CueSender, LINE_AWESOME, LINE_A_RANK, LINE_BAIL, LINE_B_RANK, LINE_COMBO, LINE_C_RANK, LINE_FINAL_JUMP,
    LINE_GNARLY, LINE_GO, LINE_HIGH_LINE, LINE_INSANE, LINE_LOW_LINE, LINE_NASTY, LINE_NEW_RECORD, LINE_NICE,
    LINE_ONE, LINE_OUCH, LINE_PERFECT, LINE_RADICAL, LINE_READY, LINE_SICK, LINE_SKETCHY, LINE_SWEET, LINE_S_RANK,
    LINE_THREE, LINE_TITLE, LINE_TRICK, LINE_TWO, LINE_UNREAL, LINE_WIPEOUT, LINE_YEAH, packTrick,
} from "./shared";
import {
    PRAISE_BAIL, PRAISE_INSANE, PRAISE_NICE, PRAISE_OUCH, PRAISE_RADICAL, PRAISE_SICK, PRAISE_SKETCHY, PRAISE_UNREAL,
    PRAISE_WIPEOUT, TrickName,
} from "../game_state";

export const PRIO_COUNT: i32 = 1;
export const PRIO_CRASH: i32 = 1;
export const PRIO_GRADE: i32 = 1;
export const PRIO_TRICK: i32 = 2;
export const PRIO_SMALL: i32 = 3;
export const PRIO_LINE: i32 = 3;

// the value from which a banked combo's trick name is spoken (AUDIO.md, section 6)
export const SPEAK_TRICK_FROM: f32 = 1500;

export class Announcer {
    out: CueSender;
    lastPraise: i32 = -1;
    lastFinish: i32 = -1;
    rng: u32 = 12345;

    constructor(out: CueSender) {
        this.out = out;
    }

    seed(s: u32): void {
        this.rng = s * 2654435761 + 1;
    }

    rand(): u32 {
        this.rng = this.rng * 1664525 + 1013904223;
        return this.rng >> 16;
    }

    say(line: i32, prio: i32, chained: bool, delay: f32 = 0, trick: f32 = 0): void {
        this.out.send(CUE_SAY, <f32>line, <f32>(prio + (chained ? 10 : 0)), trick, delay);
    }

    count(n: i32): void {
        let line = LINE_GO;
        if (n == 3) line = LINE_THREE;
        else if (n == 2) line = LINE_TWO;
        else if (n == 1) line = LINE_ONE;
        else if (n == 10) line = LINE_READY;
        this.say(line, PRIO_COUNT, false);
    }

    // the praise word of a tier, never the same twice in a row
    praiseLine(praise: i32): i32 {
        let a = -1;
        let b = -1;
        if (praise == PRAISE_NICE) { a = LINE_NICE; b = LINE_SWEET; }
        else if (praise == PRAISE_SICK) { a = LINE_SICK; b = LINE_NASTY; }
        else if (praise == PRAISE_RADICAL) { a = LINE_RADICAL; b = LINE_GNARLY; }
        else if (praise == PRAISE_INSANE) { a = LINE_INSANE; b = LINE_INSANE; }
        else if (praise == PRAISE_UNREAL) { a = LINE_UNREAL; b = LINE_UNREAL; }
        else if (praise == PRAISE_SKETCHY) return LINE_SKETCHY;
        else if (praise == PRAISE_OUCH) return LINE_OUCH;
        else if (praise == PRAISE_WIPEOUT) return LINE_WIPEOUT;
        else if (praise == PRAISE_BAIL) return LINE_BAIL;
        if (a < 0) return -1;
        const line = this.lastPraise == a ? b : a;
        this.lastPraise = line;
        return line;
    }

    // A combo banked (the frame's events gathered): its trick name from 1,500,
    // "PERFECT!" when the landing was, then the praise word.
    bank(value: f32, praise: i32, perfect: bool, comboCount: i32, trick: TrickName): void {
        let chained = false;
        const big = value >= SPEAK_TRICK_FROM;
        if (big) {
            if (comboCount >= 4) {
                this.say(LINE_COMBO, PRIO_TRICK, false);
            } else {
                const t = packTrick(trick.spin, trick.dir, trick.flip, trick.grab1, trick.grab2, trick.switchStance, trick.grind);
                this.say(LINE_TRICK, PRIO_TRICK, false, 0, t);
            }
            chained = true;
        }
        if (perfect) {
            this.say(LINE_PERFECT, PRIO_TRICK, chained);
            chained = true;
        }
        const line = this.praiseLine(praise);
        if (line >= 0) this.say(line, big || perfect ? PRIO_TRICK : PRIO_SMALL, chained);
    }

    perfect(): void {
        this.say(LINE_PERFECT, PRIO_TRICK, false);
    }

    crash(): void {
        this.say((this.rand() & 1) == 0 ? LINE_OUCH : LINE_WIPEOUT, PRIO_CRASH, false);
    }

    bail(): void {
        this.say(LINE_BAIL, PRIO_TRICK, false);
    }

    line(high: bool): void {
        this.say(high ? LINE_HIGH_LINE : LINE_LOW_LINE, PRIO_LINE, false);
    }

    finalJump(): void {
        this.say(LINE_FINAL_JUMP, PRIO_TRICK, false);
    }

    finish(): void {
        const line = this.lastFinish == LINE_AWESOME ? LINE_YEAH : LINE_AWESOME;
        this.lastFinish = line;
        this.say(line, PRIO_TRICK, false);
    }

    // the grade after its stamp, "NEW RECORD!" after it when the score enters the table
    grade(grade: i32, record: bool): void {
        let line = LINE_C_RANK;
        if (grade >= 3) line = LINE_S_RANK;
        else if (grade == 2) line = LINE_A_RANK;
        else if (grade == 1) line = LINE_B_RANK;
        this.say(line, PRIO_GRADE, false, 0.45);
        if (record) this.say(LINE_NEW_RECORD, PRIO_GRADE, true);
    }

    title(): void {
        this.say(LINE_TITLE, PRIO_TRICK, false, 0.25);
    }
}
