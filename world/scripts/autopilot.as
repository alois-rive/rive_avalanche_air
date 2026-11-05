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
    private lastMode: i32 = MODE_GROUND;
    // the air's plan
    private spinTarget: f32 = 0;
    private flipTarget: f32 = 0;
    private grab: i32 = GRAB_NONE;
    private planned: bool = false;
    private weave: f32 = 0;
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
            this.fgrind[k] = REF_GRIND[row] != 0 || f.kind == FEAT_RAIL;
            return;
        }
        const sign = this.alternate ? 1 : -1;
        if (f.kind == FEAT_RAIL) {
            this.fspin[k] = 0;
            this.fflip[k] = 0;
            this.fgrab[k] = GRAB_NONE;
            this.fgrind[k] = true;
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
        this.planned = false;
        this.lastMode = MODE_GROUND;
        this.crouching = false;
        this.weave = 0;
    }

    // The next feature not yet passed, from the rider's s.
    private next(s: f32): i32 {
        for (let i = 0; i < this.count; i++) if (this.fend[i] > s - 1) return i;
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
            // the balance against its drift
            out.x = clampf(1.6 * r.grind.balance, -1, 1);
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
        const idx = nearestSample(r.x, r.z, -1, this.high);
        let ahead = idx + <i32>look;
        const last = lineCount(this.high) - 1;
        if (ahead > last) ahead = last;
        if (ahead < 0) ahead = 0;
        lineSample(ahead, this.high, this.lp);
        const p = this.lp;
        let offset: f32 = 0;
        let target: f32 = 22;
        let tx = p.x;
        let tz = p.z;
        let crouch = false;
        let release = false;
        if (i >= 0) {
            const d = this.fs[i] - s;
            if (d < 60) offset = this.fx[i];
            if (d < 140) target = this.fspeed[i] > 0 ? this.fspeed[i] : target;
            const kind = this.fkind[i];
            if (kind == FEAT_RAIL && this.fgrind[i] && this.frail[i] >= 0 && d < 30) {
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
            } else if (kind == FEAT_ROLLER) {
                if (d < 5 && d > 0.3) crouch = true;
                if (d <= 0.3 && d > -2) release = true;
            } else if (kind == FEAT_KICKER || kind == FEAT_MEGA || kind == FEAT_GAP || kind == FEAT_DROP) {
                if (d < 5 && d > -1) crouch = !r.onLip && d > 0.15;
                if (r.onLip || (d <= 0.15 && d > -1)) release = true;
            }
        }
        // too fast: a weave to scrub speed; too slow: a tuck
        const v = r.V;
        if (v > target + 2 && !crouch) this.weave += dt * 1.6;
        else this.weave *= 1 - dt;
        const weave = v > target + 2 ? Mathf.sin(this.weave * 2.2) * clampf((v - target - 2) * 1.5, 0, 5) : <f32>0;
        // right of the line
        const rx = -p.tz;
        const rz = p.tx;
        const rl = Mathf.sqrt(rx * rx + rz * rz);
        if (rl > 1e-4 && offset + weave != 0) {
            tx += rx / rl * (offset + weave);
            tz += rz / rl * (offset + weave);
        }
        const want = Mathf.atan2(-(tx - r.x), -(tz - r.z));
        // against the travel (the board leads it in a carve), and its turning
        const err = wrapAngle(want - r.psi);
        const lag = wrapAngle(r.heading - r.psi);
        out.x = clampf(-err * 2.0 + lag * 1.5, -1, 1);
        out.tuck = !crouch && v < target - 0.5;
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
        if (want != 0) {
            const reach = SPIN_RATE * (T - 0.28) + SPIN_COAST;
            let halves = Mathf.floor(reach / 180);
            const wantHalves = Mathf.abs(want) / 180;
            if (halves > wantHalves) halves = wantHalves;
            this.spinTarget = halves * 180 * (want > 0 ? 1 : -1);
        }
        const flip = <f32>this.fflip[i];
        if (flip != 0) {
            const reach = FLIP_RATE * (T - 0.3) + FLIP_COAST;
            if (reach >= 360) this.flipTarget = flip > 0 ? 360 : -360;
        }
        if (T > 0.55) this.grab = this.fgrab[i];
    }

    private air(r: Rider, out: Input): void {
        if (!this.planned) return;
        const spin = this.spinTarget;
        if (spin != 0 && Mathf.abs(spin) - Mathf.abs(r.spinDeg) > SPIN_COAST) out.x = spin > 0 ? -1 : 1;
        const flip = this.flipTarget;
        if (flip != 0 && Mathf.abs(flip) - Mathf.abs(r.flipDeg) > FLIP_COAST && !r.yLatched) out.y = flip > 0 ? 1 : -1;
        if (flip != 0 && r.yLatched) out.y = 0;
        if (this.grab != GRAB_NONE && r.airTime > 0.08 && r.landT > 0.25) {
            if (this.grab == GRAB_INDY) out.grabs = GRAB_BIT_INDY;
            else if (this.grab == GRAB_MELON) out.grabs = GRAB_BIT_MELON;
            else if (this.grab == GRAB_METHOD) out.grabs = GRAB_BIT_METHOD;
            else if (this.grab == GRAB_MUTE) out.grabs = GRAB_BIT_INDY | GRAB_BIT_MELON;
        }
    }
}
