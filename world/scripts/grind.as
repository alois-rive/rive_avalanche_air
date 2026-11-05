// Grinds (docs/RIDER.md, section 7): the catch on a rail, a box or a log
// (course_api's curves, sampled every 0.25 m), the slide along it, the
// balance and the ways off it (its end, an ollie, a bail). rider.as owns
// one Grind and calls it each tick in the air, on the snow and on a rail.
import { LinePoint, RAIL_BOX, RAIL_KINKED, RAIL_LOG, RAIL_RAIL, RAIL_RAINBOW, railCount, railFlags, railKind, railPoint, railPointCount, railsNear } from "./course_api";
import { GRIND_BOX, GRIND_LOG, GRIND_RAIL } from "./game_state";
import { DEG, Pcg32, clampf } from "./lib/kinematic";
import { GRIND_NAME_5050, GRIND_NAME_BOARDSLIDE, GRIND_NAME_LOGSLIDE } from "./tricks";

const G: f32 = 9.81;
// the catch
const REACH_RAIL: f32 = 0.45;        // sideways, rails
const REACH_WIDE: f32 = 0.6;         // boxes and logs
const BELOW: f32 = 0.25;             // the board below the top
const ABOVE: f32 = 0.35;             // and above it
const CLIMB_MAX: f32 = 0.5;          // not climbing faster
const ANGLE_MAX: f32 = 50 * DEG;     // the velocity within this of the curve (either way)
const SNOW_REACH_UP: f32 = 1.1;      // from the snow, crouched: a top this far above the board
const SNOW_START: f32 = 2.5;         // and within this of the curve's start (m)
const MIN_SPEED: f32 = 4;
// the slide
const MU_BOX: f32 = 0.06;
const MU_RAIL: f32 = 0.08;
const MU_LOG: f32 = 0.12;
const DRAG: f32 = 0.0055;
// the balance
const WALK_BASE: f32 = 0.6;
const WALK_GROWTH: f32 = 0.25;
const INSTABILITY: f32 = 1.2;
const STICK: f32 = 2.2;
// leaving
export const END_POP: f32 = 1.5;
export const OLLIE_OFF: f32 = 3.5;

export const GRIND_ON: i32 = 0;
export const GRIND_END: i32 = 1;
export const GRIND_BAIL: i32 = 2;
export const GRIND_STOPPED: i32 = 3;

export class Grind {
    rail: i32 = -1;
    kind: i32 = 0;           // course_api RAIL_*
    flags: i32 = 0;
    name: i32 = 0;           // tricks' GRIND_NAME_*
    count: i32 = 0;          // its points
    u: f32 = 0;              // the place along it, in points (0 .. count - 1)
    dir: f32 = 1;            // +1 towards the last point, -1 towards the first
    speed: f32 = 0;
    // the board's yaw from the curve's direction at the catch (0 a 50-50,
    // about 90 degrees a boardslide), kept along it
    yawOffset: f32 = 0;
    balance: f32 = 0;
    private walk: f32 = 0;
    time: f32 = 0;
    // where the board is, and the direction of travel (unit)
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;
    tx: f32 = 0;
    ty: f32 = 0;
    tz: f32 = -1;
    assist: bool = false;
    rng: Pcg32 = new Pcg32(1, 3);
    private near: StaticArray<i32> = new StaticArray<i32>(8);
    private a: LinePoint = new LinePoint();
    private b: LinePoint = new LinePoint();

    seed(seed: u64): void {
        this.rng.seed(seed, 3);
    }

    // The game's kind (game_state GRIND_*).
    gameKind(): i32 {
        if (this.kind == RAIL_BOX) return GRIND_BOX;
        if (this.kind == RAIL_LOG) return GRIND_LOG;
        return GRIND_RAIL;
    }

    // Whether the board at (px, py, pz) moving (vx, vy, vz) catches a curve:
    // in the air, or on the snow with the crouch held near a curve's start.
    // `boardYaw` is the board's flat yaw (its long axis, either way). On a
    // catch, the grind is set up and true returned.
    tryCatch(px: f32, py: f32, pz: f32, vx: f32, vy: f32, vz: f32, onSnow: bool, crouched: bool, boardYaw: f32): bool {
        if (railCount() <= 0) return false;
        if (onSnow && !crouched) return false;
        if (!onSnow && vy > CLIMB_MAX) return false;
        const vh = Mathf.sqrt(vx * vx + vz * vz);
        if (vh < 1) return false;
        const n = railsNear(px, pz, 1.5, this.near);
        for (let k = 0; k < n; k++) {
            const r = this.near[k];
            const kind = railKind(r);
            const reach = kind == RAIL_RAIL ? REACH_RAIL : REACH_WIDE;
            const count = railPointCount(r);
            if (count < 2) continue;
            // the nearest segment in the plan view
            let best: f32 = 1e9;
            let bestU: f32 = -1;
            for (let i = 0; i < count - 1; i++) {
                railPoint(r, i, this.a);
                railPoint(r, i + 1, this.b);
                const sx = this.b.x - this.a.x;
                const sz = this.b.z - this.a.z;
                const l2 = sx * sx + sz * sz;
                let t: f32 = 0;
                if (l2 > 1e-8) t = clampf(((px - this.a.x) * sx + (pz - this.a.z) * sz) / l2, 0, 1);
                const cx = this.a.x + sx * t - px;
                const cz = this.a.z + sz * t - pz;
                const d2 = cx * cx + cz * cz;
                if (d2 < best) {
                    best = d2;
                    bestU = <f32>i + t;
                }
            }
            if (bestU < 0 || best > reach * reach) continue;
            // the top there, and the curve's direction
            const i0 = <i32>Mathf.floor(bestU) < count - 1 ? <i32>Mathf.floor(bestU) : count - 2;
            const f = bestU - <f32>i0;
            railPoint(r, i0, this.a);
            railPoint(r, i0 + 1, this.b);
            const topY = this.a.y + (this.b.y - this.a.y) * f;
            const dy = py - topY;
            if (onSnow) {
                // crouched on the snow, approaching its start: popped up on it
                if (dy < -SNOW_REACH_UP || dy > ABOVE) continue;
                const fromStart = bestU * 0.25;
                const fromEnd = (<f32>(count - 1) - bestU) * 0.25;
                if (fromStart > SNOW_START && fromEnd > SNOW_START) continue;
            } else if (dy < -BELOW || dy > ABOVE) continue;
            let cx = this.b.x - this.a.x;
            let cy = this.b.y - this.a.y;
            let cz = this.b.z - this.a.z;
            const cl = Mathf.sqrt(cx * cx + cy * cy + cz * cz);
            if (cl < 1e-6) continue;
            cx /= cl;
            cy /= cl;
            cz /= cl;
            const ch = Mathf.sqrt(cx * cx + cz * cz);
            if (ch < 1e-4) continue;
            const along = (vx * cx + vz * cz) / (vh * ch);
            const ang = Mathf.acos(clampf(Mathf.abs(along), 0, 1));
            if (ang > ANGLE_MAX) continue;
            // locked on
            this.rail = r;
            this.kind = kind;
            this.flags = railFlags(r);
            this.count = count;
            this.u = bestU;
            this.dir = along >= 0 ? 1 : -1;
            const v3 = vx * cx * this.dir + vy * cy * this.dir + vz * cz * this.dir;
            this.speed = v3 > MIN_SPEED ? v3 : MIN_SPEED;
            // the board's yaw from the travel direction
            const travelYaw = Mathf.atan2(-cx * this.dir, -cz * this.dir);
            let off = boardYaw - travelYaw;
            while (off > 1.5707963) off -= 3.14159265;
            while (off <= -1.5707963) off += 3.14159265;
            const a = Mathf.abs(off);
            if (kind == RAIL_LOG) this.name = GRIND_NAME_LOGSLIDE;
            else if (a <= 45 * DEG) this.name = GRIND_NAME_5050;
            else this.name = GRIND_NAME_BOARDSLIDE;
            // the drawn yaw snaps to the kind's: along it, or across it
            this.yawOffset = this.name == GRIND_NAME_BOARDSLIDE ? (off >= 0 ? <f32>1.5707963 : <f32>-1.5707963) : 0;
            this.balance = 0;
            this.walk = this.rng.nextSigned() * 0.3;
            this.time = 0;
            this.place();
            return true;
        }
        return false;
    }

    // The flags as game.trick.grind's: +10 kinked, +20 rainbow.
    nameFlags(): i32 {
        if ((this.flags & RAIL_KINKED) != 0) return 10;
        if ((this.flags & RAIL_RAINBOW) != 0) return 20;
        return 0;
    }

    // Where u is: the board on the top, the direction of travel.
    private place(): void {
        let i0 = <i32>Mathf.floor(this.u);
        if (i0 < 0) i0 = 0;
        if (i0 > this.count - 2) i0 = this.count - 2;
        const f = clampf(this.u - <f32>i0, 0, 1);
        railPoint(this.rail, i0, this.a);
        railPoint(this.rail, i0 + 1, this.b);
        this.x = this.a.x + (this.b.x - this.a.x) * f;
        this.y = this.a.y + (this.b.y - this.a.y) * f;
        this.z = this.a.z + (this.b.z - this.a.z) * f;
        let cx = (this.b.x - this.a.x) * this.dir;
        let cy = (this.b.y - this.a.y) * this.dir;
        let cz = (this.b.z - this.a.z) * this.dir;
        const cl = Mathf.sqrt(cx * cx + cy * cy + cz * cz);
        if (cl > 1e-6) {
            this.tx = cx / cl;
            this.ty = cy / cl;
            this.tz = cz / cl;
        }
    }

    // One tick on it: `stick` the input's x. GRIND_ON, or GRIND_END (past
    // its end), GRIND_BAIL (the balance lost), GRIND_STOPPED (no speed left).
    tick(stick: f32, dt: f32): i32 {
        this.time += dt;
        const mu = this.kind == RAIL_BOX ? MU_BOX : (this.kind == RAIL_LOG ? MU_LOG : MU_RAIL);
        const cosT = Mathf.sqrt(1 - this.ty * this.ty);
        const a = -G * this.ty - mu * G * cosT - DRAG * this.speed * this.speed;
        this.speed += a * dt;
        if (this.speed < 0.5) return GRIND_STOPPED;
        // along the curve (its points 0.25 m apart, measured on the segment)
        const segLen = this.segmentLength();
        this.u += this.dir * this.speed * dt / (segLen > 1e-4 ? segLen : <f32>0.25);
        if (this.u < 0 || this.u > <f32>(this.count - 1)) {
            this.u = clampf(this.u, 0, <f32>(this.count - 1));
            this.place();
            return GRIND_END;
        }
        this.place();
        // the balance: a seeded random walk growing with the time on it, an
        // instability, the stick against them (the assist halves the first two)
        const k: f32 = this.assist ? 0.5 : 1;
        const strength = (WALK_BASE + WALK_GROWTH * this.time) * k;
        this.walk += this.rng.nextSigned() * strength * 8 * dt;
        this.walk = clampf(this.walk, -strength, strength);
        const rate = this.walk + INSTABILITY * k * this.balance - STICK * stick;
        this.balance += rate * dt;
        if (this.balance >= 1 || this.balance <= -1) {
            this.balance = clampf(this.balance, -1, 1);
            return GRIND_BAIL;
        }
        return GRIND_ON;
    }

    private segmentLength(): f32 {
        let i0 = <i32>Mathf.floor(this.u);
        if (i0 < 0) i0 = 0;
        if (i0 > this.count - 2) i0 = this.count - 2;
        railPoint(this.rail, i0, this.a);
        railPoint(this.rail, i0 + 1, this.b);
        const dx = this.b.x - this.a.x;
        const dy = this.b.y - this.a.y;
        const dz = this.b.z - this.a.z;
        return Mathf.sqrt(dx * dx + dy * dy + dz * dz);
    }
}
