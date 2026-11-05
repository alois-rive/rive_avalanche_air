// Tricks, scoring and grades (docs/TRICKS.md): the detector that names
// what an air or a grind held, its value with the repeats' decay, the
// combo with its multiplier, the landing and the pop, the praise word, the
// run's tally for the results, the grade and the high score table. The
// rider (rider.as, grind.as) calls in as things happen; this writes
// game.trick, the combo's fields of `game`, game.score and game.results,
// and pushes EV_TRICK, EV_BANK, EV_PERFECT.
//
// Conventions: a spin's degrees are signed, positive to the left
// (counter-clockwise seen from above, as game.rider.heading); a flip's
// positive is a front flip. The rider is regular (left foot forward).
//
// Nothing allocates after construction.
import {
    EV_BANK, EV_PERFECT, EV_TRICK, FLIP_BACK, FLIP_DOUBLE_BACK, FLIP_DOUBLE_FRONT, FLIP_FRONT, FLIP_NONE, GRAB_MELON,
    GRAB_METHOD, GRAB_MUTE, GRAB_INDY, GRAB_NONE, LAND_CLEAN, LAND_PERFECT, LAND_SKETCHY, PRAISE_BAIL, PRAISE_INSANE,
    PRAISE_NICE, PRAISE_NONE, PRAISE_OUCH, PRAISE_RADICAL, PRAISE_SICK, PRAISE_SKETCHY, PRAISE_UNREAL, PRAISE_WIPEOUT,
    TABLE_SIZE, Table, game, packInitials, packTag,
} from "./game_state";

// ---- values (TRICKS.md, section 3) ------------------------------------------
// a spin's points by half-turns (0, 180, ... 1440)
export const SPIN_POINTS: StaticArray<f32> = [0, 150, 375, 675, 1050, 1500, 2100, 2850, 3750];
export const FLIP_POINTS: f32 = 900;
export const DOUBLE_FLIP_POINTS: f32 = 2250;
export const GRAB_BASE: f32 = 200;        // at 0.2 s held
export const GRAB_STEP: f32 = 75;         // each 0.1 s more
export const GRAB_MIN: f32 = 0.2;
export const GRAB_MAX: f32 = 2.0;
export const BIG_AIR_STEP: f32 = 200;     // each 0.5 s beyond 1.0 s
export const GRIND_CATCH: f32 = 150;
export const GRIND_RATE: f32 = 300;       // a second
export const BOARDSLIDE_FACTOR: f32 = 1.25;
export const SPECIAL_RAIL_FACTOR: f32 = 1.5;
export const MAX_MULT: i32 = 10;
export const PERFECT_FACTOR: f32 = 1.25;
export const SKETCHY_FACTOR: f32 = 0.5;
export const POP_FACTOR: f32 = 1.1;
export const DECAY: StaticArray<f32> = [1.0, 0.75, 0.5, 0.25];

// grades (TRICKS.md, section 8)
export const GRADE_C: i32 = 0;
export const GRADE_B: i32 = 1;
export const GRADE_A: i32 = 2;
export const GRADE_S: i32 = 3;
export const GRADE_B_SCORE: f32 = 20000;
export const GRADE_A_SCORE: f32 = 35000;
export const GRADE_S_SCORE: f32 = 50000;

// the grind's names (game.trick.grind): 1 50-50, 2 boardslide, 3 log slide; +10 kinked, +20 rainbow
export const GRIND_NAME_5050: i32 = 1;
export const GRIND_NAME_BOARDSLIDE: i32 = 2;
export const GRIND_NAME_LOGSLIDE: i32 = 3;

// ---- naming (TRICKS.md, section 2) ---------------------------------------------

// A spin's counted degrees from the rotation since take-off: the nearest
// half-turn when within 45 degrees of it, else the half-turn below; under
// 135 degrees none.
export function countSpin(deg: f32): i32 {
    const a = Mathf.abs(deg);
    if (a < 135) return 0;
    const near = <i32>Mathf.round(a / 180);
    let n = Mathf.abs(a - <f32>near * 180) <= 45 ? near : <i32>Mathf.floor(a / 180);
    if (n > 8) n = 8;
    return n * 180;
}

// 0 none, 1 frontside, 2 backside: a spin to the left (positive) is
// frontside for a regular rider riding forward, mirrored riding switch.
export function spinDir(deg: f32, switchStance: bool): i32 {
    if (countSpin(deg) == 0) return 0;
    const left = deg > 0;
    return left != switchStance ? 1 : 2;
}

// FLIP_*: one flip from 300 degrees, two from 660 (positive: front).
export function countFlip(deg: f32): i32 {
    const a = Mathf.abs(deg);
    if (a >= 660) return deg > 0 ? FLIP_DOUBLE_FRONT : FLIP_DOUBLE_BACK;
    if (a >= 300) return deg > 0 ? FLIP_FRONT : FLIP_BACK;
    return FLIP_NONE;
}

// A grab's points for its seconds held (0 under 0.2 s).
export function grabPoints(t: f32): f32 {
    if (t < GRAB_MIN) return 0;
    const held = t > GRAB_MAX ? GRAB_MAX : t;
    const steps = Mathf.floor((held - GRAB_MIN) / 0.1 + 1e-4);
    return GRAB_BASE + GRAB_STEP * steps;
}

export function bigAirPoints(air: f32): f32 {
    if (air <= 1.0) return 0;
    return BIG_AIR_STEP * Mathf.floor((air - 1.0) / 0.5 + 1e-4);
}

export function flipPoints(flip: i32): f32 {
    if (flip == FLIP_FRONT || flip == FLIP_BACK) return FLIP_POINTS;
    if (flip == FLIP_DOUBLE_FRONT || flip == FLIP_DOUBLE_BACK) return DOUBLE_FLIP_POINTS;
    return 0;
}

// The name's key, for the repeats' decay: every part of the name.
export function nameKey(spin: i32, dir: i32, flip: i32, grab1: i32, grab2: i32, sw: bool): i32 {
    return spin / 180 + 9 * dir + 27 * flip + 135 * grab1 + 675 * grab2 + (sw ? 3375 : 0);
}

export function praiseFor(banked: f32): i32 {
    if (banked >= 20000) return PRAISE_UNREAL;
    if (banked >= 12000) return PRAISE_INSANE;
    if (banked >= 6000) return PRAISE_RADICAL;
    if (banked >= 3000) return PRAISE_SICK;
    if (banked >= 1000) return PRAISE_NICE;
    return PRAISE_NONE;
}

export function gradeFor(score: f32): i32 {
    if (score >= GRADE_S_SCORE) return GRADE_S;
    if (score >= GRADE_A_SCORE) return GRADE_A;
    if (score >= GRADE_B_SCORE) return GRADE_B;
    return GRADE_C;
}

export function timeBonus(seconds: f32): f32 {
    if (seconds >= 100) return 0;
    return Mathf.round(200 * (100 - seconds));
}

// ---- the air in progress -----------------------------------------------------------
const MAX_REPEATS: i32 = 96;

export class Tricks {
    // the air
    inAir: bool = false;
    airSwitch: bool = false;
    spinDeg: f32 = 0;
    flipDeg: f32 = 0;
    airTime: f32 = 0;
    grabTime: StaticArray<f32> = new StaticArray<f32>(5);   // seconds held per grab, this air
    grabA: i32 = GRAB_NONE;     // the first grab held 0.2 s
    grabB: i32 = GRAB_NONE;     // the second
    // the grind
    grinding: bool = false;
    grindName: i32 = 0;         // 1..3 (+10 kinked, +20 rainbow)
    grindTime: f32 = 0;
    grindFactor: f32 = 1;
    // the combo
    count: i32 = 0;
    sum: f32 = 0;               // its tricks' values (decayed)
    sumAir: f32 = 0;
    sumGrind: f32 = 0;
    pop: bool = false;          // a perfect pop at its first take-off
    started: bool = false;      // a take-off since the last touch of the snow
    // the repeats of each name this run
    private keys: StaticArray<i32> = new StaticArray<i32>(MAX_REPEATS);
    private counts: StaticArray<i32> = new StaticArray<i32>(MAX_REPEATS);
    private nkeys: i32 = 0;
    // the run's tally
    tricksTotal: f32 = 0;
    grindsTotal: f32 = 0;
    comboBonus: f32 = 0;
    landings: f32 = 0;
    banked: f32 = 0;
    bestCombo: f32 = 0;
    bestComboCount: i32 = 0;
    longestAir: f32 = 0;
    perfects: i32 = 0;
    crashes: i32 = 0;
    tricksDone: i32 = 0;
    // pins' counters (RIVE.md, section 2)
    trickSeq: i32 = 0;
    bankSeq: i32 = 0;
    perfectSeq: i32 = 0;
    crashSeq: i32 = 0;
    bailSeq: i32 = 0;
    praise: i32 = PRAISE_NONE;
    lastPoints: f32 = 0;

    // A new run: everything cleared.
    reset(): void {
        this.inAir = false;
        this.grinding = false;
        this.clearAir();
        this.clearCombo();
        this.nkeys = 0;
        this.tricksTotal = 0;
        this.grindsTotal = 0;
        this.comboBonus = 0;
        this.landings = 0;
        this.banked = 0;
        this.bestCombo = 0;
        this.bestComboCount = 0;
        this.longestAir = 0;
        this.perfects = 0;
        this.crashes = 0;
        this.tricksDone = 0;
        this.praise = PRAISE_NONE;
        this.lastPoints = 0;
        game.trick.clear();
        this.publish();
    }

    private clearAir(): void {
        this.spinDeg = 0;
        this.flipDeg = 0;
        this.airTime = 0;
        for (let i = 0; i < 5; i++) this.grabTime[i] = 0;
        this.grabA = GRAB_NONE;
        this.grabB = GRAB_NONE;
    }

    private clearCombo(): void {
        this.count = 0;
        this.sum = 0;
        this.sumAir = 0;
        this.sumGrind = 0;
        this.pop = false;
        this.started = false;
    }

    // ---- the rider's calls ----------------------------------------------------

    // Leaving the snow or a rail into the air.
    takeoff(switchStance: bool, perfectPop: bool): void {
        if (!this.started) {
            this.started = true;
            this.pop = perfectPop;
        }
        this.inAir = true;
        this.airSwitch = switchStance;
        this.clearAir();
        this.live();
    }

    // Each tick in the air: the rotation since take-off (degrees, signed),
    // the grab held now and the tick.
    air(spinDeg: f32, flipDeg: f32, grab: i32, dt: f32): void {
        if (!this.inAir) return;
        this.spinDeg = spinDeg;
        this.flipDeg = flipDeg;
        this.airTime += dt;
        if (grab > 0 && grab < 5) {
            this.grabTime[grab] += dt;
            if (this.grabTime[grab] >= GRAB_MIN) {
                if (this.grabA == GRAB_NONE) this.grabA = grab;
                else if (this.grabA != grab && this.grabB == GRAB_NONE) this.grabB = grab;
            }
        }
        this.live();
    }

    // The air's value (decayed by the name's repeats when `count` is set,
    // which records it) and its name into game.trick.
    private finishAir(record: bool): f32 {
        const t = game.trick;
        const spin = countSpin(this.spinDeg);
        const dir = spinDir(this.spinDeg, this.airSwitch);
        const flip = countFlip(this.flipDeg);
        let value = SPIN_POINTS[spin / 180] + flipPoints(flip) + bigAirPoints(this.airTime);
        if (this.grabA != GRAB_NONE) value += grabPoints(this.grabTime[this.grabA]);
        if (this.grabB != GRAB_NONE) value += grabPoints(this.grabTime[this.grabB]);
        t.spin = spin;
        t.dir = dir;
        t.flip = flip;
        t.grab1 = this.grabA;
        t.grab2 = this.grabB;
        t.switchStance = this.airSwitch;
        t.grind = 0;
        if (value <= 0) return 0;
        const key = nameKey(spin, dir, flip, this.grabA, this.grabB, this.airSwitch);
        let k = 0;
        for (; k < this.nkeys; k++) if (this.keys[k] == key) break;
        let times = 0;
        if (k < this.nkeys) times = this.counts[k];
        const decay = DECAY[times < 3 ? times : 3];
        if (record) {
            if (k < this.nkeys) this.counts[k]++;
            else if (this.nkeys < MAX_REPEATS) {
                this.keys[this.nkeys] = key;
                this.counts[this.nkeys] = 1;
                this.nkeys++;
            }
        }
        return Mathf.round(value * decay);
    }

    // An air ended (on the snow or on a rail): its trick joins the combo.
    private endAir(): void {
        if (!this.inAir) return;
        this.inAir = false;
        if (this.airTime > this.longestAir) this.longestAir = this.airTime;
        const v = this.finishAir(true);
        if (v > 0) {
            this.count++;
            this.sum += v;
            this.sumAir += v;
            this.tricksDone++;
            this.trickSeq++;
            this.lastPoints = v;
            game.trick.points = v;
            game.trick.live = false;
            game.events.push(EV_TRICK, v, 0);
        }
    }

    // Landed on the snow with LAND_* quality: the combo banks.
    land(quality: i32): void {
        this.endAir();
        this.endGrind(false);
        this.bank(quality);
    }

    // Caught a rail (from the air or the snow): `name` 1..3, `flags` +10
    // kinked, +20 rainbow (game.trick.grind's numbering).
    catchRail(name: i32, flags: i32): void {
        this.endAir();
        if (!this.started) {
            this.started = true;
            this.pop = false;
        }
        this.grinding = true;
        this.grindName = name + flags;
        this.grindTime = 0;
        let f: f32 = name == GRIND_NAME_BOARDSLIDE ? BOARDSLIDE_FACTOR : 1;
        if (flags != 0) f *= SPECIAL_RAIL_FACTOR;
        this.grindFactor = f;
        const t = game.trick;
        t.clear();
        t.grind = this.grindName;
        t.live = true;
        t.points = Mathf.round(GRIND_CATCH * f);
        this.publish();
    }

    grind(dt: f32): void {
        if (!this.grinding) return;
        this.grindTime += dt;
        game.trick.points = Mathf.round((GRIND_CATCH + GRIND_RATE * this.grindTime) * this.grindFactor);
        this.publish();
    }

    // Left the rail (its end, an ollie off): the grind joins the combo.
    leaveRail(): void {
        this.endGrind(true);
    }

    private endGrind(count: bool): void {
        if (!this.grinding) return;
        this.grinding = false;
        if (!count) return;
        const v = Mathf.round((GRIND_CATCH + GRIND_RATE * this.grindTime) * this.grindFactor);
        this.count++;
        this.sum += v;
        this.sumGrind += v;
        this.tricksDone++;
        this.trickSeq++;
        this.lastPoints = v;
        const t = game.trick;
        t.clear();
        t.grind = this.grindName;
        t.points = v;
        game.events.push(EV_TRICK, v, 1);
        this.publish();
    }

    // The combo banks with the landing's quality.
    private bank(quality: i32): void {
        if (this.count == 0) {
            this.clearCombo();
            this.publish();
            return;
        }
        const mult = <f32>(this.count < MAX_MULT ? this.count : MAX_MULT);
        const base = this.sum;
        const afterMult = base * mult;
        let land: f32 = 1;
        if (quality == LAND_PERFECT) land = PERFECT_FACTOR;
        else if (quality == LAND_SKETCHY) land = SKETCHY_FACTOR;
        const afterLand = afterMult * land;
        const pop: f32 = this.pop ? POP_FACTOR : 1;
        const total = Mathf.round(afterLand * pop);
        const landDelta = Mathf.round(afterLand - afterMult);
        this.tricksTotal += this.sumAir;
        this.grindsTotal += this.sumGrind;
        this.landings += landDelta;
        this.comboBonus += total - this.sumAir - this.sumGrind - landDelta;
        this.banked += total;
        if (total > this.bestCombo) {
            this.bestCombo = total;
            this.bestComboCount = this.count;
        }
        let praise = quality == LAND_SKETCHY ? PRAISE_SKETCHY : praiseFor(total);
        if (quality == LAND_PERFECT) {
            this.perfects++;
            this.perfectSeq++;
            game.events.push(EV_PERFECT, total, 0);
        }
        this.praise = praise;
        this.lastPoints = total;
        this.bankSeq++;
        const t = game.trick;
        t.live = false;
        t.points = total;
        game.events.push(EV_BANK, total, <f32>praise);
        this.clearCombo();
        this.publish();
    }

    // A crash (`wipeout`: the big one) or a bail: the combo is lost.
    lose(bail: bool, wipeout: bool): void {
        this.inAir = false;
        this.grinding = false;
        this.clearCombo();
        if (bail) {
            this.bailSeq++;
            this.praise = PRAISE_BAIL;
        } else {
            this.crashes++;
            this.crashSeq++;
            this.praise = wipeout ? PRAISE_WIPEOUT : PRAISE_OUCH;
        }
        game.trick.live = false;
        this.publish();
    }

    // The growing name of the air in progress (the banner).
    private live(): void {
        const t = game.trick;
        // the spin in completed half-turns, the flips completed, the grabs held
        const half = <i32>Mathf.floor(Mathf.abs(this.spinDeg) / 180);
        t.spin = (half > 8 ? 8 : half) * 180;
        t.dir = t.spin > 0 ? ((this.spinDeg > 0) != this.airSwitch ? 1 : 2) : 0;
        t.flip = countFlip(this.flipDeg);
        t.grab1 = this.grabA;
        t.grab2 = this.grabB;
        t.switchStance = this.airSwitch;
        t.grind = 0;
        const any = t.spin > 0 || t.flip != FLIP_NONE || this.grabA != GRAB_NONE;
        t.live = any;
        if (any) {
            let v = SPIN_POINTS[t.spin / 180] + flipPoints(t.flip) + bigAirPoints(this.airTime);
            if (this.grabA != GRAB_NONE) v += grabPoints(this.grabTime[this.grabA]);
            if (this.grabB != GRAB_NONE) v += grabPoints(this.grabTime[this.grabB]);
            t.points = v;
        }
        this.publish();
    }

    // The combo's fields of `game`.
    publish(): void {
        const live = this.inAir && game.trick.live;
        const n = this.count + (live || this.grinding ? 1 : 0);
        game.comboMult = n < MAX_MULT ? n : MAX_MULT;
        let s = this.sum;
        if (this.grinding || live) s += game.trick.points;
        game.comboSum = s;
        game.comboActive = n > 0;
        game.score = this.banked;
    }

    // ---- the results ------------------------------------------------------------------

    // The tally at the finish, with the run's time.
    tally(seconds: f32): void {
        const r = game.results;
        r.tricks = this.tricksTotal;
        r.grinds = this.grindsTotal;
        r.comboBonus = this.comboBonus;
        r.landings = this.landings;
        r.timeBonus = timeBonus(seconds);
        r.total = this.banked + r.timeBonus;
        r.bestCombo = this.bestCombo;
        r.longestAir = Mathf.round(this.longestAir * 100) / 100;
        r.perfects = this.perfects;
        r.crashes = this.crashes;
        r.grade = gradeFor(r.total);
        r.rank = 0;
        game.score = r.total;
    }
}

// ---- the high score table (TRICKS.md, section 10) ---------------------------------

// letter codes: 0 space, 1..26 A..Z, 27..36 0..9, 37 "!"
export function letterCode(c: i32): i32 {
    if (c >= 65 && c <= 90) return c - 64;
    if (c >= 97 && c <= 122) return c - 96;
    if (c >= 48 && c <= 57) return c - 48 + 27;
    if (c == 33) return 37;
    return 0;
}

const SEED_NAMES: StaticArray<string> = ["AVA", "RAD", "ZAP", "SKY", "MAX", "JET", "NEO", "ICE", "OLY", "BOB"];

export function initialsOf(name: string): f32 {
    return packInitials(letterCode(name.charCodeAt(0)), letterCode(name.charCodeAt(1)), letterCode(name.charCodeAt(2)));
}

// Ten fake riders from 45,000 down to 9,000, so the first runs beat someone.
export function seedTable(t: Table): void {
    for (let i = 0; i < TABLE_SIZE; i++) {
        const score = <f32>(45000 - 4000 * i);
        t.scores[i] = score;
        t.tags[i] = packTag(initialsOf(SEED_NAMES[i]), gradeFor(score), i % 2 == 0 ? 1 : 0);
    }
}

// The place (1..10) a score would take, 0 when it does not enter.
export function rankOf(t: Table, score: f32): i32 {
    for (let i = 0; i < TABLE_SIZE; i++) if (score > t.scores[i]) return i + 1;
    return 0;
}

// Inserts the row at `rank` (1..10), the rows below moved down.
export function insertRow(t: Table, rank: i32, score: f32, tag: f32): void {
    if (rank < 1 || rank > TABLE_SIZE) return;
    for (let i = TABLE_SIZE - 1; i >= rank; i--) {
        t.scores[i] = t.scores[i - 1];
        t.tags[i] = t.tags[i - 1];
    }
    t.scores[rank - 1] = score;
    t.tags[rank - 1] = tag;
}
