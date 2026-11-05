// The autopilot (docs/RIDER.md, section 10): a rider driven by a script
// through the same Input the keys and the pad fill, for the tests, the
// title's attract, the demo and the reference run.
//
// - Steering: pure pursuit of a point on its line 12 m ahead (6 m in the
//   rail garden), offset to the next feature's place; on a rail's
//   approach, of the rail's own line.
// - Speed: a tuck where the next feature's design speed asks for it, a
//   wider carve (a weave) where it is too fast.
// - Tricks: from the reference script (reference_run.as) by the feature's
//   s, else its own choice: the biggest spin the solved air allows, and a
//   grab; spins and flips released early enough to stop on a half-turn.
// - Rails: crouched into the start (the catch from the snow), the balance
//   held with the stick.
import {
    FEAT_DROP, FEAT_GAP, FEAT_KICKER, FEAT_MEGA, FEAT_RAIL, FEAT_ROLLER, Feature, LinePoint, MERGE_S, SPLIT_S,
    feature, featureCount, lineCount, lineSample, nearestSample, railPoint, railPointCount,
} from "./course_api";
import { GRAB_INDY, GRAB_MELON, GRAB_METHOD, GRAB_MUTE, GRAB_NONE } from "./game_state";
import { GRAB_BIT_INDY, GRAB_BIT_MELON, GRAB_BIT_METHOD, Input } from "./input";
import { clampf, wrapAngle } from "./lib/kinematic";
import { REF_FLIP, REF_GRAB, REF_GRIND, REF_HIGH, REF_MATCH, REF_S, REF_SPIN } from "./reference_run";
import { MODE_AIR, MODE_GRIND, MODE_GROUND, Rider } from "./rider";

const MAX_FEATURES: i32 = 96;
const LOOK: f32 = 12;
const LOOK_GARDEN: f32 = 6;
const SPIN_RATE: f32 = 540;
const FLIP_RATE: f32 = 420;
const SPIN_COAST: f32 = 41;     // degrees a spin goes on after its release (0.15 s ramp)
const FLIP_COAST: f32 = 32;
const CRUISE: f32 = 18;          // between features
const DESIGN_MARGIN: f32 = 2.5;  // under a jump's design speed (the grid's lips launch steeper than drawn)
const RAIL_MARGIN: f32 = 1;
const BRAKE_SWING: f32 = 0.6;    // s each way of a speed check
const RAIL_TOO_FAST: f32 = 6;    // over a rail's design speed by this: not ridden
const RAIL_SIDESTEP: f32 = 5;
const KICKER_TOO_FAST: f32 = 3.5;
const KICKER_SIDESTEP: f32 = 8;
const ROLLER_FAST: f32 = 5;      // over the next jump's speed by this: no ollie off a roller    // under a jump's design speed (its lip launches a little steeper)
const ROLLER_SPEED: f32 = 14;

export class Autopilot {
    high: bool = true;
    // use the reference script (else its own choices only)
    reference: bool = true;
    // a feature's tricks done at most this big (the attract keeps it tidy)
    private fs: StaticArray<f32> = new StaticArray<f32>(MAX_FEATURES);
    private fend: StaticArray<f32> = new StaticArray<f32>(MAX_FEATURES);
    private fx: StaticArray<f32> = new StaticArray<f32>(MAX_FEATURES);
    private fkind: StaticArray<i32> = new StaticArray<i32>(MAX_FEATURES);
    private fspeed: StaticArray<f32> = new StaticArray<f32>(MAX_FEATURES);
    private frail: StaticArray<i32> = new StaticArray<i32>(MAX_FEATURES);
    private fspin: StaticArray<i32> = new StaticArray<i32>(MAX_FEATURES);
    private fflip: StaticArray<i32> = new StaticArray<i32>(MAX_FEATURES);
    private fgrab: StaticArray<i32> = new StaticArray<i32>(MAX_FEATURES);
    private fgrind: StaticArray<bool> = new StaticArray<bool>(MAX_FEATURES);
    private count: i32 = 0;
    private index: i32 = -1;
    private hint: i32 = -1;
    private lastMode: i32 = MODE_GROUND;
    // the air's plan
    private spinTarget: f32 = 0;
    private flipTarget: f32 = 0;
    private grab: i32 = GRAB_NONE;
    private planned: bool = false;
    private weave: f32 = 0;
    private weaveAmp: f32 = 0;
    private side: i32 = 1;
    private skipped: i32 = -1;
    private brakeTime: f32 = 0;
    braking: bool = false;
    dbgTarget: f32 = 0;
    dbgCross: f32 = 0;
    private np: LinePoint = new LinePoint();
    private crouching: bool = false;
    private lp: LinePoint = new LinePoint();
    private rp: LinePoint = new LinePoint();
    private f: Feature = new Feature();
    private alternate: bool = false;

    // The features of the chosen line, in order of s, with their tricks.
    setup(high: bool): void {
        this.high = high;
        this.count = 0;
        this.index = -1;
        const n = featureCount();
        for (let i = 0; i < n && this.count < MAX_FEATURES; i++) {
            feature(i, this.f);
            const f = this.f;
            const inSplit = SPLIT_S > 0 && f.s > SPLIT_S && f.s < MERGE_S;
            if (inSplit && f.high != high) continue;
            let k = this.count;
            // insertion by s
            while (k > 0 && this.fs[k - 1] > f.s) {
                this.copyRow(k - 1, k);
                k--;
            }
            this.fs[k] = f.s;
            this.fx[k] = f.x;
            this.fkind[k] = f.kind;
            this.fspeed[k] = f.designSpeed;
            this.frail[k] = f.rail;
            this.fend[k] = f.s;
            if (f.kind == FEAT_RAIL && f.rail >= 0) this.fend[k] = f.s + <f32>(railPointCount(f.rail) - 1) * 0.25;
            this.plan(k, f, high);
            this.count++;
        }
    }

    private copyRow(a: i32, b: i32): void {
        this.fs[b] = this.fs[a];
        this.fend[b] = this.fend[a];
        this.fx[b] = this.fx[a];
        this.fkind[b] = this.fkind[a];
        this.fspeed[b] = this.fspeed[a];
        this.frail[b] = this.frail[a];
        this.fspin[b] = this.fspin[a];
        this.fflip[b] = this.fflip[a];
        this.fgrab[b] = this.fgrab[a];
        this.fgrind[b] = this.fgrind[a];
    }

    // The feature's tricks: the reference's row near its s, else a choice.
    private plan(k: i32, f: Feature, high: bool): void {
        let row = -1;
        if (this.reference) {
            let best: f32 = REF_MATCH;
            for (let r = 0; r < REF_S.length; r++) {
                const inSplit = SPLIT_S > 0 && REF_S[r] > SPLIT_S && REF_S[r] < MERGE_S;
                if (inSplit && (REF_HIGH[r] == 1) != high) continue;
                const d = Mathf.abs(REF_S[r] - f.s);
                if (d < best) {
                    best = d;
                    row = r;
                }
            }
        }
        this.alternate = !this.alternate;
        if (row >= 0) {
            this.fspin[k] = REF_SPIN[row];
            this.fflip[k] = REF_FLIP[row];
            this.fgrab[k] = REF_GRAB[row];
            this.fgrind[k] = REF_GRIND[row] != 0;
            return;
        }
        const sign = this.alternate ? 1 : -1;
        if (f.kind == FEAT_RAIL) {
            this.fspin[k] = 0;
            this.fflip[k] = 0;
            this.fgrab[k] = GRAB_NONE;
            // the garden's centre lane, a rail on its own elsewhere
            this.fgrind[k] = Mathf.abs(f.x) < 3 || f.s < 640 || f.s > 900;
        } else if (f.kind == FEAT_ROLLER) {
            this.fspin[k] = 180 * sign;
            this.fflip[k] = 0;
            this.fgrab[k] = GRAB_NONE;
            this.fgrind[k] = false;
        } else if (f.kind == FEAT_MEGA) {
            this.fspin[k] = -1080;
            this.fflip[k] = -360;
            this.fgrab[k] = GRAB_MELON;
            this.fgrind[k] = false;
        } else {
            // as big as the air allows (cut to the solved flight at take-off)
            this.fspin[k] = 1440 * sign;
            this.fflip[k] = 0;
            this.fgrab[k] = this.alternate ? GRAB_INDY : GRAB_MELON;
            this.fgrind[k] = false;
        }
    }

    reset(): void {
        this.index = -1;
        this.hint = -1;
        this.planned = false;
        this.lastMode = MODE_GROUND;
        this.crouching = false;
        this.weave = 0;
        this.weaveAmp = 0;
    }

    // The next feature not yet passed, from the rider's s (a rail it does
    // not grind, another lane's, is no target).
    private next(s: f32): i32 {
        for (let i = 0; i < this.count; i++) {
            if (this.fkind[i] == FEAT_RAIL && !this.fgrind[i]) continue;
            if (this.fend[i] > s - 1) return i;
        }
        return -1;
    }

    // The first feature from i on that asks for a speed (a jump, a rail it
    // grinds), or -1.
    private nextPaced(i: i32): i32 {
        for (let k = i; k < this.count; k++) {
            if (this.fspeed[k] <= 0) continue;
            if (this.fkind[k] == FEAT_RAIL && !this.fgrind[k]) continue;
            return k;
        }
        return -1;
    }

    // A rail not ridden, on the way (within 3 m of the line's offset) in the
    // next 40 m, or -1.
    private railInTheWay(s: f32): i32 {
        for (let k = 0; k < this.count; k++) {
            if (this.fkind[k] != FEAT_RAIL || this.fgrind[k]) continue;
            const d = this.fs[k] - s;
            if (d > 40 || this.fend[k] < s - 1) continue;
            if (Mathf.abs(this.fx[k]) < 3) return k;
        }
        return -1;
    }

    // One tick's input for the rider.
    drive(r: Rider, out: Input, dt: f32): void {
        out.clear();
        const mode = r.mode;
        if (mode == MODE_AIR) {
            if (this.lastMode != MODE_AIR) this.takeoff(r);
            this.air(r, out);
        } else if (mode == MODE_GRIND) {
            // the balance against its drift; the crouch held (its release is
            // an ollie off) until the last metre, popping off the end
            const g = r.grind;
            out.x = clampf(1.6 * g.balance, -1, 1);
            const left = (g.dir > 0 ? <f32>(g.count - 1) - g.u : g.u) * 0.25;
            out.crouch = left > 0.9;
            this.planned = false;
        } else if (mode == MODE_GROUND) {
            this.ground(r, out, dt);
            this.planned = false;
        }
        this.lastMode = mode;
    }

    private ground(r: Rider, out: Input, dt: f32): void {
        const s = r.s;
        const i = this.next(s);
        this.index = i;
        // where it aims: the line ahead, offset to the next feature
        const garden = r.section == 4;
        // the look-ahead grows with speed (a short one weaves at speed)
        const minLook = garden ? LOOK_GARDEN : LOOK;
        const look = r.V * 0.8 > minLook ? r.V * 0.8 : minLook;
        const idx = nearestSample(r.x, r.z, this.hint, this.high);
        this.hint = idx;
        let ahead = idx + <i32>look;
        const last = lineCount(this.high) - 1;
        if (ahead > last) ahead = last;
        if (ahead < 0) ahead = 0;
        lineSample(ahead, this.high, this.lp);
        const p = this.lp;
        let offset: f32 = 0;
        let target: f32 = CRUISE;
        let tx = p.x;
        let tz = p.z;
        let crouch = false;
        let release = false;
        let near = false;
        let d: f32 = 1e9;
        if (i >= 0) {
            d = this.fs[i] - s;
            const kind = this.fkind[i];
            // lined up on it from 70 m, straight for the last 25 m
            if (d < 70) offset = this.fx[i] * clampf((70 - d) / 45, 0, 1);
            // the speed: the next jump's or rail's design speed (a roller takes
            // what comes; a drop is easy), from 180 m before it
            const j = this.nextPaced(i);
            if (j >= 0 && this.fs[j] - s < 180) {
                const kj = this.fkind[j];
                // (a gap and the mega-jump need their full speed: short lands on a roof, a knuckle)
                target = this.fspeed[j] - (kj == FEAT_MEGA || kj == FEAT_GAP ? 0 : (kj == FEAT_RAIL ? RAIL_MARGIN : DESIGN_MARGIN));
                const dj = this.fs[j] - s;
                // the carving stops 12 m before it, 8 m before a roller in between
                near = dj < 12 || (kind == FEAT_ROLLER && d < 8);
            } else {
                near = kind == FEAT_ROLLER && d < 8;
            }
            // a rail of the line it does not ride (the garden's centre lane
            // before the lane it takes): passed beside it, off its approach ramp
            const pass = this.railInTheWay(s);
            if (pass >= 0) offset = this.fx[pass] + (this.fx[pass] > 0 ? -RAIL_SIDESTEP : RAIL_SIDESTEP);
            const tooFast = this.skipped == i || (kind == FEAT_RAIL && r.V > this.fspeed[i] + RAIL_TOO_FAST) ||
                (kind == FEAT_KICKER && this.fspeed[i] > 0 && r.V > this.fspeed[i] + KICKER_TOO_FAST && d < 30);
            if (tooFast && d < 40) {
                // too fast for it: beside it, not over it (a crash costs more than a trick)
                const step = kind == FEAT_RAIL ? RAIL_SIDESTEP : KICKER_SIDESTEP;
                offset = this.fx[i] + (this.fx[i] > 0 ? -step : step);
                this.skipped = i;
            } else if (kind == FEAT_RAIL && this.fgrind[i] && this.frail[i] >= 0 && d < 45) {
                // the rail's own line, from its start
                railPoint(this.frail[i], 0, this.rp);
                const sx = this.rp.x;
                const sz = this.rp.z;
                railPoint(this.frail[i], railPointCount(this.frail[i]) - 1, this.rp);
                let dx = this.rp.x - sx;
                let dz = this.rp.z - sz;
                const dl = Mathf.sqrt(dx * dx + dz * dz);
                if (dl > 0.01) {
                    dx /= dl;
                    dz /= dl;
                }
                // the point on its line `look` ahead of the rider's projection
                const along = (r.x - sx) * dx + (r.z - sz) * dz;
                // a shorter look on the approach: lined up by its start
                const railLook = r.V * 0.55 > 5 ? r.V * 0.55 : <f32>5;
                const at = along + railLook;
                tx = sx + dx * at;
                tz = sz + dz * at;
                offset = 0;
                if (d < 3.5 && d > -2) crouch = true;
            } else if (kind == FEAT_ROLLER && r.V < target + ROLLER_FAST) {
                // (much too fast: ridden over on the snow, carving speed off)
                if (d < 5 && d > 0.3) crouch = true;
                if (d <= 0.3 && d > -2) release = true;
            }
            // (a kicker, a gap, the mega-jump and a drop are ridden off as they
            // come, at their design speed: every jump works without an ollie,
            // and a pop on top of the design flight overshoots its landing)
        }
        const v = r.V;
        const weave: f32 = 0;
        // right of the line
        const rx = -p.tz;
        const rz = p.tx;
        const rl = Mathf.sqrt(rx * rx + rz * rz);
        if (rl > 1e-4 && offset + weave != 0) {
            tx += rx / rl * (offset + weave);
            tz += rz / rl * (offset + weave);
        }
        let want = Mathf.atan2(-(tx - r.x), -(tz - r.z));
        // too fast, and room before the next feature: carving wide across the
        // slope (no brake: RIDER.md section 3), turning back at the piste's
        // sides; lined up again for the last 25 m
        const demand = v - target;
        lineSample(this.hint, this.high, this.np);
        const n = this.np;
        const nrx = -n.tz;
        const nrz = n.tx;
        const nl = Mathf.sqrt(nrx * nrx + nrz * nrz);
        const cross = nl > 1e-4 ? ((r.x - n.x) * nrx + (r.z - n.z) * nrz) / nl : <f32>0;
        const brake = demand > 0.8 && !near && !crouch && Mathf.abs(cross - offset) < 8;
        this.dbgTarget = target;
        this.dbgCross = cross;
        if (brake) {
            // carving hard, one way then the other, round the way it wants to
            // go: every tick at full lock costs speed (RIDER.md section 3: no
            // brake, carving slows), and the swings skid a little more
            const e = wrapAngle(r.heading - want);
            const phi = clampf(demand * 0.08, 0.2, 0.4);
            if (this.side > 0 && e < -phi) this.side = -1;
            else if (this.side < 0 && e > phi) this.side = 1;
            out.x = <f32>this.side;
        } else {
            this.brakeTime = 0;
            // against the travel (the board leads it in a carve), and its turning
            const err = wrapAngle(want - r.psi);
            const lag = wrapAngle(r.heading - r.psi);
            out.x = clampf(-err * 2.0 + lag * 1.5, -1, 1);
        }
        out.tuck = !crouch && v < target - 0.3 && d > 4;
        this.braking = brake;
        if (crouch && !release) {
            out.crouch = true;
            this.crouching = true;
        } else {
            out.crouch = false;
            this.crouching = false;
        }
    }

    // At the take-off: the plan cut to the solved flight.
    private takeoff(r: Rider): void {
        const i = this.index >= 0 && this.index < this.count && Mathf.abs(this.fs[this.index] - r.s) < 12 ? this.index : -1;
        const T = r.landT;
        this.spinTarget = 0;
        this.flipTarget = 0;
        this.grab = GRAB_NONE;
        this.planned = true;
        if (i < 0 || T < 0.45) return;
        const want = <f32>this.fspin[i];
        const k: f32 = T > 0.55 && this.fgrab[i] != GRAB_NONE ? 0.85 : 1;
        if (want != 0) {
            // what fits, with a margin: the solved flight is a forecast
            const reach = SPIN_RATE * k * (T - 0.3) + SPIN_COAST * k;
            let halves = Mathf.floor(reach / 180);
            const wantHalves = Mathf.abs(want) / 180;
            if (halves > wantHalves) halves = wantHalves;
            this.spinTarget = halves * 180 * (want > 0 ? 1 : -1);
        }
        const flip = <f32>this.fflip[i];
        if (flip != 0) {
            const reach = FLIP_RATE * k * (T - 0.45) + FLIP_COAST * k;
            if (reach >= 430) this.flipTarget = flip > 0 ? 360 : -360;
        }
        if (T > 0.55) this.grab = this.fgrab[i];
    }

    private air(r: Rider, out: Input): void {
        // crouched over a rail's start: caught off its approach
        const ri = this.index;
        if (ri >= 0 && ri < this.count && this.fkind[ri] == FEAT_RAIL && this.fgrind[ri]) {
            const dr = this.fs[ri] - r.s;
            if (dr < 4 && dr > -3) out.crouch = true;
        }
        if (!this.planned) return;
        // the flight's forecast shortened: a spin cut to the half-turn it can reach
        if (this.spinTarget != 0) {
            const k: f32 = r.grab != GRAB_NONE ? 0.85 : 1;
            const rate = Mathf.abs(r.spinRate);
            const left = r.landT - 0.2;
            const reach = Mathf.abs(r.spinDeg) + rate * rate / (2 * SPIN_RATE / 0.15) +
                (left > 0 ? SPIN_RATE * k * left : <f32>0);
            const most = Mathf.floor(reach / 180) * 180;
            const least = Mathf.ceil((Mathf.abs(r.spinDeg) + rate * rate / (2 * SPIN_RATE / 0.15) - 20) / 180) * 180;
            let cap = most > least ? most : least;
            if (Mathf.abs(this.spinTarget) > cap) this.spinTarget = cap * (this.spinTarget > 0 ? 1 : -1);
        }
        // released when what the rate still turns, ramping down, reaches the target
        const spin = this.spinTarget;
        if (spin == 0 || Mathf.abs(r.spinDeg) >= Mathf.abs(spin) - 1) {
            // the board's axis (either way) to the travel, for the landing
            const by = r.boardYaw();
            const ty = Mathf.atan2(-r.vx, -r.vz);
            let e = wrapAngle(by - ty);
            if (e > 1.5707963) e -= 3.1415927;
            if (e < -1.5707963) e += 3.1415927;
            const deg = e * 57.29578;
            if (Mathf.abs(deg) > 8 && r.landT > 0.12) out.x = clampf(deg / 20, -1, 1);
        }
        const sr = r.spinRate;
        const spinCoast = sr * sr / (2 * SPIN_RATE / 0.15) + 2;
        if (spin != 0 && Mathf.abs(spin) - Mathf.abs(r.spinDeg) > spinCoast) out.x = spin > 0 ? -1 : 1;
        const flip = this.flipTarget;
        const fr = r.flipRate;
        const flipCoast = fr * fr / (2 * FLIP_RATE / 0.15) + 2;
        if (flip != 0 && Mathf.abs(flip) - Mathf.abs(r.flipDeg) > flipCoast && !r.yLatched) out.y = flip > 0 ? 1 : -1;
        if (flip != 0 && r.yLatched) out.y = 0;
        if (this.grab != GRAB_NONE && r.airTime > 0.08 && r.landT > 0.25) {
            if (this.grab == GRAB_INDY) out.grabs = GRAB_BIT_INDY;
            else if (this.grab == GRAB_MELON) out.grabs = GRAB_BIT_MELON;
            else if (this.grab == GRAB_METHOD) out.grabs = GRAB_BIT_METHOD;
            else if (this.grab == GRAB_MUTE) out.grabs = GRAB_BIT_INDY | GRAB_BIT_MELON;
        }
    }
}
