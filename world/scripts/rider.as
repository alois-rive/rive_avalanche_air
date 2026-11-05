// The rider: the arcade board model of docs/RIDER.md, sections 2 to 6, 8
// and 9, ticked at 120 Hz by run.as. It decides the velocity; the course
// (course_api.as) answers where the snow is (ground()), the obstacles'
// cylinders, the rails (grind.as) and the zones.
//
// State in brief:
// - on the snow: the speed V along the travel direction `psi` (a flat
//   yaw) in the ground's plane, the board's `heading` (its flat yaw, the
//   travel direction it is steered to), the grip pulling psi to the
//   heading (a skid beyond 1.3 g), the stance;
// - in the air: the 3D velocity, ballistic at AIR_GRAVITY, the body's
//   orientation `q` integrated from the spin and flip rates, the flight
//   solved ahead to its landing each tick;
// - grinding: grind.as; tumbling: tumble.as, then the respawn.
//
// Angles: yaw 0 faces -Z, positive turns left (game_state); `x` input
// +1 right. A spin's degrees are positive to the left; a flip's positive
// is a front flip. The body's nose is its local -Z, its up +Y; a regular
// rider faces its local +X (the toe edge); riding switch the nose trails.
//
// The rider calls tricks.as as things happen and pushes game.events.
// Nothing allocates per tick.
import {
    AIR_GRAVITY, FINISH_S, GroundHit, LinePoint, MEGA_LIP_S, MERGE_S, Obstacle, SPLIT_S, ground, inFallZone,
    isHighSide, lineCount, lineSample, nearestSample, obstacle, obstaclesNear, respawnAt,
} from "./course_api";
import {
    EV_BAIL, EV_CRASH, EV_GATE, EV_GRAB, EV_GRIND_END, EV_GRIND_START, EV_LAND, EV_LINE, EV_MEGA_TAKEOFF, EV_OLLIE,
    EV_RESPAWN, EV_SECTION, EV_SPIN_HALF, GRAB_INDY, GRAB_MELON, GRAB_METHOD, GRAB_MUTE, GRAB_NONE, GRIND_NONE, LAND_CLEAN,
    LAND_PERFECT, LAND_SKETCHY, SURF_ICE, SURF_POWDER, SURF_ROCK, game,
} from "./game_state";
import { END_POP, GRIND_BAIL, GRIND_END, GRIND_ON, GRIND_STOPPED, Grind, OLLIE_OFF } from "./grind";
import { GRAB_BIT_INDY, GRAB_BIT_MELON, GRAB_BIT_METHOD, Input } from "./input";
import { DEG, PI_F, RAD, approach, clampf, wrapAngle } from "./lib/kinematic";
import { Q, angleBetween } from "./lib/quat";
import { Tricks } from "./tricks";
import { Tumble } from "./tumble";

export const MODE_GROUND: i32 = 0;
export const MODE_AIR: i32 = 1;
export const MODE_GRIND: i32 = 2;
export const MODE_TUMBLE: i32 = 3;

export const LAND_CRASH: i32 = 3;

const G: f32 = 9.81;
// on the snow (section 3)
export const K_STAND: f32 = 0.0055;
export const K_TUCK: f32 = 0.0028;
export const SOFT_CAP: f32 = 25;
export const SPEED_CAP: f32 = 27;
const CARVE_COST: f32 = 0.6;
const MU_GROOMED: f32 = 0.035;
const MU_POWDER: f32 = 0.09;
const MU_ICE: f32 = 0.015;
const POWDER_SINK: f32 = 0.15;
const YAW_SLOW: f32 = 120;          // deg/s at 6 m/s or less
const YAW_FAST: f32 = 50;           // deg/s at 27 m/s
const GRIP_RATE: f32 = 10;
const GRIP_G: f32 = 1.3;
const SKID_FRICTION: f32 = 0.25;
const SKATE_SPEED: f32 = 1;
const SKATE_PUSH: f32 = 1.5;
const SKATE_TURN: f32 = 60 * DEG;
const TUCK_IN: f32 = 4;             // /s (0.25 s)
const TUCK_OUT: f32 = 6.67;         // /s (0.15 s)
const CROUCH_IN: f32 = 6.67;
const REVERT_ANGLE: f32 = 120 * DEG;
const NORMAL_EASE: f32 = 20;        // /s: the drawn ground plane
// the ollie (section 4)
const CHARGE_MAX: f32 = 0.4;
const POP_TAP: f32 = 3.0;
const POP_FULL: f32 = 2.0;
const POP_COOLDOWN: f32 = 0.25;
const PERFECT_WINDOW: f32 = 0.12;
const PERFECT_BONUS: f32 = 1.0;
const PREWIND: f32 = 180;           // deg/s
// the air (section 5)
const AIR_DRAG: f32 = 0.0015;
const DRIFT: f32 = 0.5;
const SPIN_MAX: f32 = 540;
const FLIP_MAX: f32 = 420;
const RAMP_TIME: f32 = 0.15;
const GRAB_RATE_FACTOR: f32 = 0.85;
const GRAB_BLEND: f32 = 8.33;       // /s (0.12 s)
const GRAB_RELEASE: f32 = 0.15;     // s before the solved landing
const SOLVE_STEP: f32 = 0.05;
const SOLVE_MAX: f32 = 4.5;
const LEVEL_RATE: f32 = 150 * DEG;  // the body eased to the landing when not flipping
const LEVEL_LIMIT: f32 = 75 * DEG;
// landing (section 6)
const PERFECT_YAW: f32 = 12 * DEG;
const PERFECT_TILT: f32 = 12 * DEG;
const CLEAN_YAW: f32 = 30 * DEG;
const CLEAN_TILT: f32 = 25 * DEG;
const SKETCHY_YAW: f32 = 50 * DEG;
const SKETCHY_TILT: f32 = 40 * DEG;
const HARD_IMPACT: f32 = 9;
const CRASH_IMPACT: f32 = 13;
const PERFECT_BOOST: f32 = 2.5;
const ASSIST_TIME: f32 = 0.2;
const ASSIST_YAW: f32 = 25 * DEG;
const ASSIST_TILT: f32 = 20 * DEG;
const ASSIST_RATE: f32 = 60 * DEG;
const WOBBLE_TIME: f32 = 0.5;
const ABSORB_TIME: f32 = 0.35;
// obstacles (section 8)
const BODY_RADIUS: f32 = 0.3;
const BODY_HEIGHT: f32 = 1.6;
const CRASH_INTO: f32 = 6;
const CRASH_ROCK: f32 = 8;
const GLANCE_KEEP: f32 = 0.8;
// the crash (section 9)
export const RESPAWN_AT: f32 = 1.15;
export const CONTROL_AT: f32 = 1.25;
export const BLINK_TIME: f32 = 1.0;
const RESPAWN_MIN_SPEED: f32 = 8;
const STUMBLE_TIME: f32 = 0.6;

// ---- the model's laws, pure (rider_test.as holds them to RIDER.md's numbers) ----

// The yaw rate at full lock (deg/s): 120 at 6 m/s or less, falling linearly
// to 50 at 27 m/s; x 0.6 in a full tuck (section 3).
export function yawRateDeg(V: f32, tuck: f32): f32 {
    let omega = YAW_SLOW;
    if (V > 6) omega = YAW_SLOW - (V - 6) / (SPEED_CAP - 6) * (YAW_SLOW - YAW_FAST);
    if (omega < YAW_FAST) omega = YAW_FAST;
    return omega * (1 - 0.4 * tuck);
}

// The drag coefficient (/m): standing to tucked, doubled by 27 m/s from 25.
export function dragK(V: f32, tuck: f32): f32 {
    let k = K_STAND + (K_TUCK - K_STAND) * tuck;
    if (V > SOFT_CAP) k *= 1 + (V - SOFT_CAP) / (SPEED_CAP - SOFT_CAP);
    return k;
}

// The acceleration along the snow (section 3): gravity along the travel
// (`ty` its unit direction's y), the snow's friction (`ny` the normal's y),
// the drag and the carve's cost: a = g sin(theta) cos(phi) - mu g cos(theta) - k v^2 - c |steer|.
export function snowAccel(V: f32, ty: f32, ny: f32, mu: f32, tuck: f32, steer: f32): f32 {
    let a = -G * ty;
    a -= mu * G * ny;
    a -= dragK(V, tuck) * V * V;
    a -= CARVE_COST * Mathf.abs(steer);
    return a;
}

// The ollie's pop (m/s) from the crouch's charge (s): a tap 3.0, full (0.4 s) 5.0.
export function popSpeed(charge: f32): f32 {
    return POP_TAP + POP_FULL * clampf(charge / CHARGE_MAX, 0, 1);
}

// A landing's quality (section 6): LAND_PERFECT, LAND_CLEAN, LAND_SKETCHY
// or LAND_CRASH from the yaw and tilt errors (radians) and the impact (m/s).
export function judgeLanding(yawErr: f32, tilt: f32, impact: f32): i32 {
    let quality = LAND_CRASH;
    if (yawErr <= PERFECT_YAW && tilt <= PERFECT_TILT) quality = LAND_PERFECT;
    else if (yawErr <= CLEAN_YAW && tilt <= CLEAN_TILT) quality = LAND_CLEAN;
    else if (yawErr <= SKETCHY_YAW && tilt <= SKETCHY_TILT) quality = LAND_SKETCHY;
    if (impact > HARD_IMPACT && quality < LAND_CRASH) quality++;
    if (impact > CRASH_IMPACT) quality = LAND_CRASH;
    return quality;
}

export class Rider {
    mode: i32 = MODE_GROUND;
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;
    vx: f32 = 0;
    vy: f32 = 0;
    vz: f32 = 0;
    // on the snow
    V: f32 = 0;
    psi: f32 = 0;
    heading: f32 = 0;
    switchStance: bool = false;
    nx: f32 = 0;          // the physics' ground normal
    ny: f32 = 1;
    nz: f32 = 0;
    dnx: f32 = 0;         // the drawn one, eased
    dny: f32 = 1;
    dnz: f32 = 0;
    surface: i32 = 0;
    onLip: bool = false;
    feature: i32 = -1;
    skid: f32 = 0;
    carve: f32 = 0;
    edge: f32 = 0;        // the drawn edge angle (radians, + into a right turn)
    tuck: f32 = 0;
    crouch: f32 = 0;
    charge: f32 = 0;
    crouching: bool = false;
    cooldown: f32 = 0;
    pendingPop: f32 = 0;
    pendingAge: f32 = 0;
    private gapTicks: i32 = 0;
    // the body
    q: Q = new Q();
    // the air
    airTime: f32 = 0;
    spinRate: f32 = 0;
    flipRate: f32 = 0;
    spinDeg: f32 = 0;
    flipDeg: f32 = 0;
    private halfSpins: i32 = 0;
    private halfFlips: i32 = 0;
    flipAxis: f32 = 1;
    yLatched: bool = false;
    grab: i32 = GRAB_NONE;
    grabBlend: f32 = 0;
    perfectPop: bool = false;
    landT: f32 = 0;
    landX: f32 = 0;
    landY: f32 = 0;
    landZ: f32 = 0;
    landNx: f32 = 0;
    landNy: f32 = 1;
    landNz: f32 = 0;
    // timers for the poses and the rules
    wobble: f32 = 0;
    absorb: f32 = 0;
    absorbImpact: f32 = 0;
    stumble: f32 = 0;
    blink: f32 = 0;
    crashTime: f32 = 0;
    crashSpeed: f32 = 0;
    respawned: bool = false;
    lastLand: i32 = -1;
    // progress
    lineIndex: i32 = -1;
    lineYaw: f32 = 0;      // the line's flat direction here
    s: f32 = 0;
    section: i32 = 1;
    highLine: bool = false;
    lineCommitted: bool = false;
    lineTaken: i32 = 0;    // 1 high, 0 low (the results)
    // parts
    grind: Grind = new Grind();
    tumble: Tumble = new Tumble();
    tricks: Tricks;
    landingAssist: bool = true;
    private hit: GroundHit = new GroundHit();
    private probe: GroundHit = new GroundHit();
    private lp: LinePoint = new LinePoint();
    private obs: Obstacle = new Obstacle();
    private near: StaticArray<i32> = new StaticArray<i32>(16);
    private sx: f32 = 0;
    private sy: f32 = 0;
    private sz: f32 = 0;

    constructor(tricks: Tricks) {
        this.tricks = tricks;
    }

    seed(seed: u64): void {
        this.grind.seed(seed);
        this.tumble.seed(seed);
    }

    // ---- placing -----------------------------------------------------------------

    // Standing still on the line at `s` (the start gate: 0), facing down it.
    placeAt(s: f32, high: bool, speed: f32): void {
        let i = <i32>Mathf.round(s);
        const n = lineCount(high) - 1;
        if (i < 0) i = 0;
        if (i > n) i = n;
        lineSample(i, high, this.lp);
        this.placeOn(this.lp, speed);
        this.lineIndex = i;
    }

    // On the line point `p`, facing down its tangent at `speed`.
    placeOn(p: LinePoint, speed: f32): void {
        this.mode = MODE_GROUND;
        this.x = p.x;
        this.z = p.z;
        const h = this.hit;
        ground(p.x, p.z, h);
        this.y = h.y;
        this.nx = h.nx;
        this.ny = h.ny;
        this.nz = h.nz;
        this.dnx = h.nx;
        this.dny = h.ny;
        this.dnz = h.nz;
        this.surface = h.surface;
        this.heading = Mathf.atan2(-p.tx, -p.tz);
        this.lineYaw = this.heading;
        this.psi = this.heading;
        this.V = speed;
        this.switchStance = false;
        this.skid = 0;
        this.carve = 0;
        this.edge = 0;
        this.tuck = 0;
        this.crouch = 0;
        this.charge = 0;
        this.crouching = false;
        this.cooldown = 0;
        this.pendingPop = 0;
        this.gapTicks = 0;
        this.airTime = 0;
        this.spinRate = 0;
        this.flipRate = 0;
        this.grab = GRAB_NONE;
        this.grabBlend = 0;
        this.wobble = 0;
        this.absorb = 0;
        this.stumble = 0;
        this.s = p.s;
        this.section = p.section;
        this.highLine = p.high;
        this.updateVelocity();
        this.q.setOnGround(this.heading, h.nx, h.ny, h.nz);
    }

    // A new run: at the gate, everything cleared.
    reset(seed: u64): void {
        this.seed(seed);
        this.placeAt(0, false, 0);
        this.blink = 0;
        this.crashTime = 0;
        this.respawned = false;
        this.lineCommitted = false;
        this.lineTaken = 0;
        this.lastLand = -1;
    }

    // Whether the input reaches the rider (not tumbling, not respawning, not stumbling).
    hasControl(): bool {
        if (this.mode == MODE_TUMBLE) return false;
        if (this.respawned && this.crashTime < CONTROL_AT) return false;
        return this.stumble <= 0;
    }

    // ---- the tick -------------------------------------------------------------

    tick(inp: Input, dt: f32): void {
        this.grind.age(dt);
        if (this.cooldown > 0) this.cooldown -= dt;
        if (this.wobble > 0) this.wobble -= dt;
        if (this.absorb > 0) this.absorb -= dt;
        if (this.blink > 0) this.blink -= dt;
        const control = this.hasControl();
        if (this.stumble > 0) this.stumble -= dt;
        if (this.mode == MODE_TUMBLE) {
            this.tickTumble(dt);
        } else {
            if (this.respawned) {
                this.crashTime += dt;
                if (this.crashTime >= CONTROL_AT + BLINK_TIME) this.respawned = false;
            }
            if (this.mode == MODE_GROUND) this.tickGround(inp, control, dt);
            else if (this.mode == MODE_AIR) this.tickAir(inp, control, dt);
            else if (this.mode == MODE_GRIND) this.tickGrind(inp, control, dt);
        }
        if (this.mode != MODE_TUMBLE) this.progress();
    }

    // ---- on the snow ----------------------------------------------------------

    private tickGround(inp: Input, control: bool, dt: f32): void {
        const h = this.hit;
        const on = ground(this.x, this.z, h);
        if (!on) {
            this.toAir(false);
            return;
        }
        this.nx = h.nx;
        this.ny = h.ny;
        this.nz = h.nz;
        this.surface = h.surface;
        this.onLip = h.lip;
        this.feature = h.feature;
        let mu = MU_GROOMED;
        let grip: f32 = 1;
        let yawMul: f32 = 1;
        let sink: f32 = 0;
        if (h.surface == SURF_POWDER) {
            mu = MU_POWDER;
            grip = 0.8;
            yawMul = 0.7;
            sink = POWDER_SINK;
        } else if (h.surface == SURF_ICE) {
            mu = MU_ICE;
            grip = 0.5;
        }
        // the crouch and the tuck
        const wasCrouching = this.crouching;
        this.crouching = control && inp.crouch;
        if (this.crouching) {
            this.crouch = approach(this.crouch, 1, CROUCH_IN * dt);
            this.charge = this.charge + dt < CHARGE_MAX ? this.charge + dt : CHARGE_MAX;
        } else {
            this.crouch = approach(this.crouch, 0, CROUCH_IN * dt);
        }
        const tuckOn = control && inp.tuck && !this.crouching && this.stumble <= 0;
        this.tuck = approach(this.tuck, tuckOn ? 1 : 0, (tuckOn ? TUCK_IN : TUCK_OUT) * dt);
        // steering
        const steer = control ? inp.x : <f32>0;
        const omega = yawRateDeg(this.V, this.tuck) * yawMul;
        const yawRate = steer * omega * DEG;      // rad/s, + to the right
        this.heading = wrapAngle(this.heading - yawRate * dt);
        // the downhill direction in the plane, flat
        const gx = this.ny * this.nx;
        const gz = this.ny * this.nz;
        const gl = Mathf.sqrt(gx * gx + gz * gz);
        // skating below 1 m/s: pushed down the fall line, the board eased to it
        if (this.V < SKATE_SPEED && gl > 0.01) {
            const down = Mathf.atan2(-gx / gl, -gz / gl);
            const d = wrapAngle(down - this.heading);
            const step = SKATE_TURN * dt;
            this.heading = wrapAngle(this.heading + (d > step ? step : (d < -step ? -step : d)));
            this.psi = this.heading;
            this.V += SKATE_PUSH * dt;
        }
        // a revert: the board turned past 120 degrees from the fall line
        // (the line's: a kicker's ramp falls backwards)
        if (this.V > 1.5) {
            if (Mathf.abs(wrapAngle(this.heading - this.lineYaw)) > REVERT_ANGLE) {
                this.heading = wrapAngle(this.heading + PI_F);
                this.psi = wrapAngle(this.psi + PI_F);
                this.V *= 0.5;
                this.switchStance = !this.switchStance;
            }
        }
        // the travel direction in the plane
        this.planeDir(this.psi);
        const tx = this.sx;
        const ty = this.sy;
        const tz = this.sz;
        // gravity along it, friction, drag, the carve's cost
        let a = snowAccel(this.V, ty, this.ny, mu, this.tuck, steer);
        // the grip: psi pulled to the heading, capped at 1.3 g
        const beta = wrapAngle(this.psi - this.heading);
        const ab = Mathf.abs(beta);
        const cap = GRIP_G * G * grip / (this.V > 1 ? this.V : <f32>1);
        let turn = GRIP_RATE * grip * ab;
        let capped = false;
        if (turn > cap) {
            turn = cap;
            capped = true;
        }
        let step = turn * dt;
        if (step > ab) step = ab;
        this.psi = wrapAngle(this.psi - (beta > 0 ? step : -step));
        // a skid: what the grip could not turn slides, scrubbing speed
        const left = Mathf.abs(wrapAngle(this.psi - this.heading));
        const skidTarget: f32 = capped ? clampf(left / (35 * DEG), 0, 1) : 0;
        this.skid = approach(this.skid, skidTarget, 6 * dt);
        a -= SKID_FRICTION * G * Mathf.sin(left < 1.5707963 ? left : <f32>1.5707963);
        // the slide never holds more than 80 degrees: the travel follows
        if (left > 80 * DEG) this.psi = wrapAngle(this.heading + (wrapAngle(this.psi - this.heading) > 0 ? 80 * DEG : -80 * DEG));
        this.V += a * dt;
        if (this.V < 0) this.V = 0;
        if (this.V > SPEED_CAP) this.V = SPEED_CAP;
        // carve: the lateral demand on the grip's scale; the drawn edge angle
        const demand = this.V * yawRate;
        this.carve = clampf(Mathf.abs(demand) / (GRIP_G * G), 0, 1);
        let edge = Mathf.atan(demand / G);
        if (edge > 55 * DEG) edge = 55 * DEG;
        if (edge < -55 * DEG) edge = -55 * DEG;
        this.edge = edge;
        // move along the plane
        this.planeDir(this.psi);
        const vx = this.V * this.sx;
        const vy = this.V * this.sy;
        const vz = this.V * this.sz;
        const ox = this.x;
        const oy = this.y;
        const oz = this.z;
        this.x += vx * dt;
        this.z += vz * dt;
        // the snow under the new place: still on it, or off into the air
        const onNew = ground(this.x, this.z, h);
        const yb = oy + vy * dt - 0.5 * G * dt * dt;
        const floor = h.y - sink;
        const gap = yb - floor;
        let leave = !onNew || gap > 0.02;
        if (!leave && gap > 0.0005) {
            this.gapTicks++;
            if (this.gapTicks >= 2) leave = true;
        } else {
            this.gapTicks = 0;
        }
        this.vx = vx;
        this.vy = vy;
        this.vz = vz;
        // the crouch released: an ollie (on a lip, held to the lip's edge)
        const released = wasCrouching && !this.crouching && control;
        if (released && this.cooldown <= 0) {
            const pop = popSpeed(this.charge);
            this.charge = 0;
            if (this.onLip || h.lip) {
                this.pendingPop = pop;
                this.pendingAge = 0;
            } else if (!leave) {
                this.y = floor;
                this.ollie(pop, inp.x, false);
                return;
            }
        }
        if (!this.crouching && !released) this.charge = 0;
        if (this.pendingPop > 0) this.pendingAge += dt;
        if (leave) {
            this.y = yb;
            const lipped = this.onLip || this.pendingPop > 0;
            if (this.pendingPop > 0) {
                // the pop held to the lip's edge: perfect within 0.12 s
                const perfect = this.pendingAge <= PERFECT_WINDOW;
                const pop = this.pendingPop + (perfect ? PERFECT_BONUS : 0);
                this.pendingPop = 0;
                this.vx += pop * this.nx;
                this.vy += pop * this.ny;
                this.vz += pop * this.nz;
                this.cooldown = POP_COOLDOWN;
                game.events.push(EV_OLLIE, pop, perfect ? 1 : 0);
                this.toAir(perfect);
                this.prewind(inp.x);
            } else {
                this.toAir(false);
            }
            if (lipped && MEGA_LIP_S > 0 && Mathf.abs(this.s - MEGA_LIP_S) < 12) game.events.push(EV_MEGA_TAKEOFF);
            return;
        }
        this.y = floor;
        // a pop pending on a lip that ended without leaving: an ollie now
        if (this.pendingPop > 0 && !h.lip && !this.onLip) {
            const pop = this.pendingPop;
            this.pendingPop = 0;
            this.ollie(pop, inp.x, false);
            return;
        }
        this.onLip = h.lip;
        this.nx = h.nx;
        this.ny = h.ny;
        this.nz = h.nz;
        this.easeNormal(dt);
        // a rail caught from the snow (crouched, at its start)
        if (control && this.grind.tryCatch(this.x, this.y, this.z, this.vx, this.vy, this.vz, true, this.crouching, this.boardYaw())) {
            this.toGrind();
            return;
        }
        this.collide(ox, oz);
        if (this.mode == MODE_GROUND && inFallZone(this.x, this.y, this.z)) this.crash(false);
        if (this.mode == MODE_GROUND) this.q.setOnGround(this.heading + (this.switchStance ? PI_F : 0), this.dnx, this.dny, this.dnz);
    }

    // The unit direction in the ground's plane whose flat yaw is `yaw`, into sx, sy, sz.
    private planeDir(yaw: f32): void {
        let fx = -Mathf.sin(yaw);
        let fy: f32 = 0;
        let fz = -Mathf.cos(yaw);
        const d = fx * this.nx + fz * this.nz;
        fx -= d * this.nx;
        fy -= d * this.ny;
        fz -= d * this.nz;
        const l = Mathf.sqrt(fx * fx + fy * fy + fz * fz);
        if (l > 1e-6) {
            this.sx = fx / l;
            this.sy = fy / l;
            this.sz = fz / l;
        } else {
            this.sx = 0;
            this.sy = 0;
            this.sz = -1;
        }
    }

    private updateVelocity(): void {
        this.planeDir(this.psi);
        this.vx = this.V * this.sx;
        this.vy = this.V * this.sy;
        this.vz = this.V * this.sz;
    }

    // The drawn plane eased towards the four probes' (nose, tail, toe and
    // heel edges: 0.75 m and 0.25 m apart) at 20 /s.
    private easeNormal(dt: f32): void {
        const fx = -Mathf.sin(this.heading);
        const fz = -Mathf.cos(this.heading);
        const p = this.probe;
        let ok = true;
        ok = ground(this.x + fx * 0.375, this.z + fz * 0.375, p) && ok;
        const ny0 = p.y;
        ok = ground(this.x - fx * 0.375, this.z - fz * 0.375, p) && ok;
        const ny1 = p.y;
        ok = ground(this.x + fz * -0.125, this.z - fx * -0.125, p) && ok;
        const nr = p.y;
        ok = ground(this.x - fz * -0.125, this.z + fx * -0.125, p) && ok;
        const nl = p.y;
        let tnx = this.nx;
        let tny = this.ny;
        let tnz = this.nz;
        if (ok) {
            // along: (fx*0.75, ny0-ny1, fz*0.75); across (right): (-fz*0.25, nr-nl, fx*0.25)
            const ax = fx * 0.75;
            const ay = ny0 - ny1;
            const az = fz * 0.75;
            const bx = -fz * 0.25;
            const by = nr - nl;
            const bz = fx * 0.25;
            // n = across x along (up)
            let cx = by * az - bz * ay;
            let cy = bz * ax - bx * az;
            let cz = bx * ay - by * ax;
            const l = Mathf.sqrt(cx * cx + cy * cy + cz * cz);
            if (l > 1e-6 && cy / l > 0.3) {
                tnx = cx / l;
                tny = cy / l;
                tnz = cz / l;
            }
        }
        const k = clampf(NORMAL_EASE * dt, 0, 1);
        this.dnx += (tnx - this.dnx) * k;
        this.dny += (tny - this.dny) * k;
        this.dnz += (tnz - this.dnz) * k;
        const l = Mathf.sqrt(this.dnx * this.dnx + this.dny * this.dny + this.dnz * this.dnz);
        this.dnx /= l;
        this.dny /= l;
        this.dnz /= l;
    }

    // The board's flat yaw (its nose).
    boardYaw(): f32 {
        this.q.rotate(0, 0, -1);
        return Mathf.atan2(-this.q.rx, -this.q.rz);
    }

    // An ollie of `pop` m/s along the ground's normal.
    private ollie(pop: f32, x: f32, perfect: bool): void {
        this.vx += pop * this.nx;
        this.vy += pop * this.ny;
        this.vz += pop * this.nz;
        this.cooldown = POP_COOLDOWN;
        game.events.push(EV_OLLIE, pop, perfect ? 1 : 0);
        this.toAir(perfect);
        this.prewind(x);
    }

    // A spin direction held as the board leaves: a 180 deg/s head start.
    private prewind(x: f32): void {
        if (x > 0.5) this.spinRate = -PREWIND;
        else if (x < -0.5) this.spinRate = PREWIND;
    }

    // ---- in the air -----------------------------------------------------------

    private toAir(perfect: bool): void {
        this.mode = MODE_AIR;
        this.airTime = 0;
        this.spinRate = 0;
        this.flipRate = 0;
        this.spinDeg = 0;
        this.flipDeg = 0;
        this.halfSpins = 0;
        this.halfFlips = 0;
        this.flipAxis = this.switchStance ? -1 : 1;
        this.yLatched = true;
        this.perfectPop = perfect;
        this.pendingPop = 0;
        this.onLip = false;
        this.gapTicks = 0;
        this.tuck = 0;
        this.tricks.takeoff(this.switchStance, perfect);
        this.solveFlight();
    }

    private tickAir(inp: Input, control: bool, dt: f32): void {
        this.airTime += dt;
        // ballistic, a light horizontal drag, a little drift from the stick
        this.vy -= AIR_GRAVITY * dt;
        const vh = Mathf.sqrt(this.vx * this.vx + this.vz * this.vz);
        if (vh > 0.1) {
            const dv = AIR_DRAG * vh * vh * dt;
            const k = vh > dv ? (vh - dv) / vh : <f32>0;
            this.vx *= k;
            this.vz *= k;
            if (control) {
                // right of the flight
                const rx = -this.vz / vh;
                const rz = this.vx / vh;
                this.vx += rx * DRIFT * inp.x * dt;
                this.vz += rz * DRIFT * inp.x * dt;
            }
        }
        const ox = this.x;
        const oz = this.z;
        this.x += this.vx * dt;
        this.y += this.vy * dt;
        this.z += this.vz * dt;
        this.crouch = approach(this.crouch, 0, CROUCH_IN * dt);
        this.crouching = control && inp.crouch;
        // the grab
        let want = GRAB_NONE;
        if (control) {
            const g = inp.grabs;
            if ((g & (GRAB_BIT_INDY | GRAB_BIT_MELON)) == (GRAB_BIT_INDY | GRAB_BIT_MELON)) want = GRAB_MUTE;
            else if ((g & GRAB_BIT_INDY) != 0) want = GRAB_INDY;
            else if ((g & GRAB_BIT_MELON) != 0) want = GRAB_MELON;
            else if ((g & GRAB_BIT_METHOD) != 0) want = GRAB_METHOD;
        }
        if (this.landT < GRAB_RELEASE) want = GRAB_NONE;
        if (want != GRAB_NONE && want != this.grab) {
            game.events.push(EV_GRAB, <f32>want, 0);
            this.grab = want;
        } else if (want == GRAB_NONE && this.grabBlend <= 0) {
            this.grab = GRAB_NONE;
        }
        this.grabBlend = approach(this.grabBlend, want != GRAB_NONE ? 1 : 0, GRAB_BLEND * dt);
        const heldGrab = want;
        // the rotation: rates ramped to the stick's in 0.15 s
        const rk: f32 = heldGrab != GRAB_NONE ? GRAB_RATE_FACTOR : 1;
        const sx = control ? inp.x : <f32>0;
        let sy = control ? inp.y : <f32>0;
        if (this.yLatched) {
            if (Mathf.abs(sy) < 0.3) this.yLatched = false;
            sy = 0;
        }
        const spinTarget = -sx * SPIN_MAX * rk;
        const flipTarget = sy * FLIP_MAX * rk;
        this.spinRate = approach(this.spinRate, spinTarget, SPIN_MAX / RAMP_TIME * dt);
        this.flipRate = approach(this.flipRate, flipTarget, FLIP_MAX / RAMP_TIME * dt);
        if (this.spinRate != 0) this.q.turnLocal(0, 1, 0, this.spinRate * DEG * dt);
        if (this.flipRate != 0) this.q.turnLocal(1, 0, 0, -this.flipAxis * this.flipRate * DEG * dt);
        this.spinDeg += this.spinRate * dt;
        this.flipDeg += this.flipRate * dt;
        const hs = <i32>(Mathf.abs(this.spinDeg) / 180);
        if (hs > this.halfSpins) {
            this.halfSpins = hs;
            game.events.push(EV_SPIN_HALF, this.spinDeg > 0 ? 1 : -1, 0);
        }
        const hf = <i32>(Mathf.abs(this.flipDeg) / 180);
        if (hf > this.halfFlips) {
            this.halfFlips = hf;
            game.events.push(EV_SPIN_HALF, this.flipDeg > 0 ? 1 : -1, 1);
        }
        this.tricks.air(this.spinDeg, this.flipDeg, this.grabBlend > 0.5 ? this.grab : GRAB_NONE, dt);
        // the flight ahead, the body eased to its landing, the assist
        this.solveFlight();
        if (Mathf.abs(sy) < 0.3 && Mathf.abs(this.flipRate) < 30) this.level(dt);
        if (this.landingAssist && this.landT <= ASSIST_TIME) this.assist(dt);
        // a rail
        if (this.grind.tryCatch(this.x, this.y, this.z, this.vx, this.vy, this.vz, false, false, this.boardYaw())) {
            this.toGrind();
            return;
        }
        // the snow
        const h = this.hit;
        if (ground(this.x, this.z, h)) {
            let floor = h.y;
            if (h.surface == SURF_POWDER) floor -= POWDER_SINK;
            const vn = this.vx * h.nx + this.vy * h.ny + this.vz * h.nz;
            if (this.y <= floor && vn < 0) {
                this.y = floor;
                this.landOn(h, -vn);
                return;
            }
        }
        this.collide(ox, oz);
        if (this.mode == MODE_AIR && inFallZone(this.x, this.y, this.z)) this.crash(false);
    }

    // The flight solved ahead to its landing (0.05 s steps against the
    // course's ground): landT, the landing point and its normal.
    solveFlight(): void {
        let px = this.x;
        let py = this.y;
        let pz = this.z;
        let vy = this.vy;
        const p = this.probe;
        let t: f32 = 0;
        let lastY = py;
        let lastGap: f32 = 1;
        this.landT = SOLVE_MAX;
        this.landX = px + this.vx * SOLVE_MAX;
        this.landZ = pz + this.vz * SOLVE_MAX;
        this.landY = py - 50;
        this.landNx = 0;
        this.landNy = 1;
        this.landNz = 0;
        while (t < SOLVE_MAX) {
            const nx = px + this.vx * SOLVE_STEP;
            const nz = pz + this.vz * SOLVE_STEP;
            const ny = py + vy * SOLVE_STEP - 0.5 * AIR_GRAVITY * SOLVE_STEP * SOLVE_STEP;
            vy -= AIR_GRAVITY * SOLVE_STEP;
            t += SOLVE_STEP;
            if (ground(nx, nz, p)) {
                const gap = ny - p.y;
                if (gap <= 0) {
                    // between the last step and this one
                    const f = lastGap > 0 ? lastGap / (lastGap - gap) : <f32>1;
                    this.landT = t - SOLVE_STEP + SOLVE_STEP * f;
                    this.landX = px + (nx - px) * f;
                    this.landZ = pz + (nz - pz) * f;
                    this.landY = lastY + (ny - lastY) * f;
                    this.landNx = p.nx;
                    this.landNy = p.ny;
                    this.landNz = p.nz;
                    return;
                }
                lastGap = gap;
            }
            px = nx;
            py = ny;
            pz = nz;
            lastY = ny;
        }
    }

    // Not flipping: the body's up eased towards the landing's normal, its
    // spin kept (a turn about the axis between the two).
    private level(dt: f32): void {
        const q = this.q;
        q.rotate(0, 1, 0);
        const ux = q.rx;
        const uy = q.ry;
        const uz = q.rz;
        const err = angleBetween(ux, uy, uz, this.landNx, this.landNy, this.landNz);
        if (err < 1e-3 || err > LEVEL_LIMIT) return;
        let ax = uy * this.landNz - uz * this.landNy;
        let ay = uz * this.landNx - ux * this.landNz;
        let az = ux * this.landNy - uy * this.landNx;
        const al = Mathf.sqrt(ax * ax + ay * ay + az * az);
        if (al < 1e-5) return;
        const left = this.landT > 0.05 ? this.landT : <f32>0.05;
        let rate = err / left;
        if (rate > LEVEL_RATE) rate = LEVEL_RATE;
        let step = rate * dt;
        if (step > err) step = err;
        q.turnWorld(ax / al, ay / al, az / al, step);
    }

    // The landing assist (section 6): in the last 0.2 s, a yaw within 25
    // degrees of the nearest half-turn and a tilt within 20 degrees eased
    // home at up to 60 deg/s. The trick's count is untouched.
    private assist(dt: f32): void {
        const q = this.q;
        const nx = this.landNx;
        const ny = this.landNy;
        const nz = this.landNz;
        // the tilt
        q.rotate(0, 1, 0);
        const ux = q.rx;
        const uy = q.ry;
        const uz = q.rz;
        const tilt = angleBetween(ux, uy, uz, nx, ny, nz);
        if (tilt > 1e-3 && tilt <= ASSIST_TILT) {
            let ax = uy * nz - uz * ny;
            let ay = uz * nx - ux * nz;
            let az = ux * ny - uy * nx;
            const al = Mathf.sqrt(ax * ax + ay * ay + az * az);
            if (al > 1e-5) {
                const step = ASSIST_RATE * dt < tilt ? ASSIST_RATE * dt : tilt;
                q.turnWorld(ax / al, ay / al, az / al, step);
            }
        }
        // the yaw: the board's axis to the velocity along the landing, either way
        const e = this.yawError(nx, ny, nz);
        if (Mathf.abs(e) > 1e-3 && Mathf.abs(e) <= ASSIST_YAW) {
            const step = ASSIST_RATE * dt < Mathf.abs(e) ? ASSIST_RATE * dt : Mathf.abs(e);
            q.turnWorld(nx, ny, nz, e > 0 ? -step : step);
        }
    }

    // The signed angle (radians, within +-90 degrees) from the velocity
    // along the plane of normal n to the board's axis (either way round),
    // about n.
    private yawError(nx: f32, ny: f32, nz: f32): f32 {
        const q = this.q;
        q.rotate(0, 0, -1);
        let ax = q.rx;
        let ay = q.ry;
        let az = q.rz;
        let d = ax * nx + ay * ny + az * nz;
        ax -= d * nx;
        ay -= d * ny;
        az -= d * nz;
        const al = Mathf.sqrt(ax * ax + ay * ay + az * az);
        let tx = this.vx;
        let ty = this.vy;
        let tz = this.vz;
        d = tx * nx + ty * ny + tz * nz;
        tx -= d * nx;
        ty -= d * ny;
        tz -= d * nz;
        const tl = Mathf.sqrt(tx * tx + ty * ty + tz * tz);
        if (al < 1e-5 || tl < 1e-5) return 0;
        ax /= al;
        ay /= al;
        az /= al;
        tx /= tl;
        ty /= tl;
        tz /= tl;
        let c = ax * tx + ay * ty + az * tz;
        // n . (t x a): positive when the axis is to the left of the travel
        let s = nx * (ty * az - tz * ay) + ny * (tz * ax - tx * az) + nz * (tx * ay - ty * ax);
        if (c < 0) {
            c = -c;
            s = -s;
        }
        return Mathf.atan2(s, c);
    }

    // Touching the snow again: judged (section 6), then riding or crashing.
    private landOn(h: GroundHit, impact: f32): void {
        const nx = h.nx;
        const ny = h.ny;
        const nz = h.nz;
        this.nx = nx;
        this.ny = ny;
        this.nz = nz;
        const yawErr = Mathf.abs(this.yawError(nx, ny, nz));
        this.q.rotate(0, 1, 0);
        const tilt = angleBetween(this.q.rx, this.q.ry, this.q.rz, nx, ny, nz);
        const quality = judgeLanding(yawErr, tilt, impact);
        this.lastLand = quality;
        if (quality != LAND_CRASH) game.events.push(EV_LAND, impact, <f32>quality);
        if (quality == LAND_CRASH) {
            this.crash(false);
            return;
        }
        // the velocity onto the slope and the board's axis
        let tx = this.vx;
        let ty = this.vy;
        let tz = this.vz;
        const d = tx * nx + ty * ny + tz * nz;
        tx -= d * nx;
        ty -= d * ny;
        tz -= d * nz;
        const vg = Mathf.sqrt(tx * tx + ty * ty + tz * tz);
        this.q.rotate(0, 0, -1);
        const nose = this.q.rx * tx + this.q.ry * ty + this.q.rz * tz;
        // the nose trailing: riding switch
        this.switchStance = nose < 0;
        let V = vg * Mathf.cos(yawErr);
        if (quality == LAND_PERFECT) V += PERFECT_BOOST;
        else if (quality == LAND_CLEAN) V *= 0.97;
        else V *= 0.7;
        if (V > SPEED_CAP) V = SPEED_CAP;
        this.V = V;
        if (vg > 0.1) this.psi = Mathf.atan2(-tx / vg, -tz / vg);
        // the board's axis along the travel
        const by = this.boardYaw();
        this.heading = this.switchStance ? wrapAngle(by + PI_F) : by;
        this.psi = this.heading;
        this.mode = MODE_GROUND;
        this.airTime = 0;
        this.spinRate = 0;
        this.flipRate = 0;
        this.grab = GRAB_NONE;
        this.grabBlend = 0;
        this.absorb = ABSORB_TIME;
        this.absorbImpact = impact;
        if (quality == LAND_SKETCHY) this.wobble = WOBBLE_TIME;
        this.updateVelocity();
        this.dnx = nx;
        this.dny = ny;
        this.dnz = nz;
        this.q.setOnGround(this.heading + (this.switchStance ? PI_F : 0), nx, ny, nz);
        this.tricks.land(quality);
    }

    // ---- on a rail --------------------------------------------------------------

    private toGrind(): void {
        const wasAir = this.mode == MODE_AIR;
        this.mode = MODE_GRIND;
        this.pendingPop = 0;
        this.spinRate = 0;
        this.flipRate = 0;
        this.grab = GRAB_NONE;
        this.grabBlend = 0;
        this.crouch = 0;
        this.tuck = 0;
        const g = this.grind;
        this.x = g.x;
        this.y = g.y;
        this.z = g.z;
        this.V = g.speed;
        if (!wasAir) this.tricks.takeoff(this.switchStance, false);
        this.tricks.catchRail(g.name, g.nameFlags());
        game.events.push(EV_GRIND_START, <f32>g.gameKind(), 0);
        this.grindPose();
    }

    private tickGrind(inp: Input, control: bool, dt: f32): void {
        const g = this.grind;
        const wasCrouching = this.crouching;
        this.crouching = control && inp.crouch;
        this.crouch = approach(this.crouch, this.crouching ? 1 : 0, CROUCH_IN * dt);
        const r = g.tick(control ? inp.x : 0, dt);
        this.x = g.x;
        this.y = g.y;
        this.z = g.z;
        this.V = g.speed;
        this.vx = g.tx * g.speed;
        this.vy = g.ty * g.speed;
        this.vz = g.tz * g.speed;
        this.tricks.grind(dt);
        this.grindPose();
        if (r == GRIND_BAIL) {
            this.bail();
            return;
        }
        if (r == GRIND_END || r == GRIND_STOPPED) {
            this.leaveRail(END_POP, inp.x);
            return;
        }
        // an ollie off it
        if (wasCrouching && !this.crouching && control) {
            this.leaveRail(OLLIE_OFF, inp.x);
        }
    }

    private grindPose(): void {
        const g = this.grind;
        const travel = Mathf.atan2(-g.tx, -g.tz);
        const yaw = travel + g.yawOffset;
        this.heading = travel;
        this.psi = travel;
        this.q.setOnGround(yaw + (this.switchStance && g.yawOffset == 0 ? PI_F : 0), 0, 1, 0);
        // the balance rolls the body
        this.q.turnLocal(0, 0, 1, -g.balance * 0.35);
    }

    private leaveRail(pop: f32, x: f32): void {
        this.grind.left();
        this.tricks.leaveRail();
        game.events.push(EV_GRIND_END, <f32>this.grind.gameKind(), 0);
        this.vy += pop;
        this.y += 0.05;
        this.mode = MODE_AIR;
        // the body back along the travel for the flight
        this.q.setOnGround(this.heading + (this.switchStance ? PI_F : 0), 0, 1, 0);
        this.toAir(false);
        this.cooldown = POP_COOLDOWN;
        if (pop > END_POP) {
            game.events.push(EV_OLLIE, pop, 0);
            this.prewind(x);
        }
    }

    // The balance lost: off the side it fell to, a stumble on the snow.
    private bail(): void {
        const g = this.grind;
        g.left();
        this.tricks.lose(true, false);
        game.events.push(EV_BAIL, g.balance, 0);
        game.events.push(EV_GRIND_END, <f32>g.gameKind(), 1);
        // to the side of the fall (right of the travel for a positive balance)
        const rx = -g.tz;
        const rz = g.tx;
        const rl = Mathf.sqrt(rx * rx + rz * rz);
        const side: f32 = g.balance > 0 ? 0.9 : -0.9;
        if (rl > 1e-4) {
            this.x += rx / rl * side;
            this.z += rz / rl * side;
        }
        const h = this.hit;
        ground(this.x, this.z, h);
        this.y = h.y;
        this.nx = h.nx;
        this.ny = h.ny;
        this.nz = h.nz;
        this.mode = MODE_GROUND;
        this.V = g.speed * 0.5;
        this.psi = this.heading;
        this.stumble = STUMBLE_TIME;
        this.wobble = STUMBLE_TIME;
        this.updateVelocity();
        this.q.setOnGround(this.heading + (this.switchStance ? PI_F : 0), h.nx, h.ny, h.nz);
    }

    // ---- obstacles (section 8) ---------------------------------------------------

    private collide(ox: f32, oz: f32): void {
        if (this.respawned && this.crashTime < CONTROL_AT + BLINK_TIME) return;
        const n = obstaclesNear(this.x, this.z, 1.5, this.near);
        for (let i = 0; i < n; i++) {
            const o = this.obs;
            obstacle(this.near[i], o);
            if (this.y + BODY_HEIGHT < o.bottom || this.y > o.top) continue;
            let dx = this.x - o.x;
            let dz = this.z - o.z;
            const reach = o.radius + BODY_RADIUS;
            const d2 = dx * dx + dz * dz;
            if (d2 >= reach * reach) continue;
            let d = Mathf.sqrt(d2);
            if (d < 1e-4) {
                dx = this.x - ox;
                dz = this.z - oz;
                d = Mathf.sqrt(dx * dx + dz * dz);
                if (d < 1e-4) {
                    dx = 1;
                    d = 1;
                }
            }
            const ux = dx / d;
            const uz = dz / d;
            const into = -(this.vx * ux + this.vz * uz);
            const limit = o.rock ? CRASH_ROCK : CRASH_INTO;
            if (into > limit) {
                this.crash(false);
                return;
            }
            // glancing off: pushed out, the part into it lost, the rest x 0.8
            this.x = o.x + ux * reach;
            this.z = o.z + uz * reach;
            if (into > 0) {
                this.vx += into * ux;
                this.vz += into * uz;
            }
            this.vx *= GLANCE_KEEP;
            this.vz *= GLANCE_KEEP;
            if (this.mode == MODE_GROUND) {
                const vh = Mathf.sqrt(this.vx * this.vx + this.vz * this.vz);
                this.V = vh;
                if (vh > 0.1) this.psi = Mathf.atan2(-this.vx / vh, -this.vz / vh);
            }
        }
    }

    // ---- the crash and the respawn (section 9) ------------------------------------

    crash(fall: bool): void {
        const speed = Mathf.sqrt(this.vx * this.vx + this.vy * this.vy + this.vz * this.vz);
        this.crashSpeed = this.mode == MODE_GROUND ? this.V : Mathf.sqrt(this.vx * this.vx + this.vz * this.vz);
        this.tricks.lose(false, speed > 14);
        game.events.push(EV_CRASH, speed, 0);
        if (this.mode == MODE_GRIND) game.events.push(EV_GRIND_END, <f32>this.grind.gameKind(), 1);
        this.tumble.start(this.x, this.y, this.z, this.vx, this.vy, this.vz, this.q);
        this.mode = MODE_TUMBLE;
        this.crashTime = 0;
        this.respawned = false;
        this.grab = GRAB_NONE;
        this.grabBlend = 0;
        this.spinRate = 0;
        this.flipRate = 0;
        this.tuck = 0;
        this.crouch = 0;
        this.pendingPop = 0;
    }

    private tickTumble(dt: f32): void {
        this.crashTime += dt;
        const t = this.tumble;
        t.tick(dt);
        this.x = t.x;
        this.y = t.y;
        this.z = t.z;
        this.vx = t.vx;
        this.vy = t.vy;
        this.vz = t.vz;
        this.q.copy(t.q);
        if (this.crashTime >= RESPAWN_AT) this.respawn();
    }

    // At the first safe metre at or after the crash's progress (+5 m),
    // facing down the line, at the larger of 8 m/s and half the speed.
    respawn(): void {
        respawnAt(this.s, this.highLine, this.lp);
        const speed = this.crashSpeed * 0.5 > RESPAWN_MIN_SPEED ? this.crashSpeed * 0.5 : RESPAWN_MIN_SPEED;
        const keep = this.crashTime;
        this.placeOn(this.lp, speed);
        this.lineIndex = <i32>Mathf.round(this.lp.s);
        this.crashTime = keep;
        this.respawned = true;
        this.blink = CONTROL_AT + BLINK_TIME - keep;
        game.events.push(EV_RESPAWN, this.s, 0);
    }

    // Whether the respawn's blink is on (its 1-bit transparency).
    blinking(): bool {
        return this.respawned && this.crashTime >= RESPAWN_AT;
    }

    // ---- progress -----------------------------------------------------------------

    private progress(): void {
        const i = nearestSample(this.x, this.z, this.lineIndex, this.highLine);
        if (i < 0) return;
        this.lineIndex = i;
        lineSample(i, this.highLine, this.lp);
        this.lineYaw = Mathf.atan2(-this.lp.tx, -this.lp.tz);
        const s = this.lp.s;
        this.s = s;
        if (this.lp.section != this.section) {
            this.section = this.lp.section;
            game.events.push(EV_SECTION, <f32>this.section, 0);
        }
        // the split: the line committed to a few metres past it
        if (SPLIT_S > 0 && !this.lineCommitted && s > SPLIT_S + 5 && s < MERGE_S) {
            this.lineCommitted = true;
            this.highLine = isHighSide(this.x, this.z, s);
            this.lineTaken = this.highLine ? 1 : 0;
            game.events.push(EV_LINE, this.highLine ? 1 : 0, 0);
            game.events.push(EV_GATE, <f32>SPLIT_S, 0);
            this.lineIndex = -1;
        }
        if (this.highLine && MERGE_S > 0 && s > MERGE_S) {
            this.highLine = false;
            this.lineIndex = -1;
        }
    }

    finished(): bool {
        return this.s >= FINISH_S && this.mode != MODE_TUMBLE;
    }

    // ---- what everyone else sees ---------------------------------------------------

    publish(): void {
        const r = game.rider;
        r.x = this.x;
        r.y = this.y;
        r.z = this.z;
        r.vx = this.vx;
        r.vy = this.vy;
        r.vz = this.vz;
        r.speed = this.mode == MODE_GROUND || this.mode == MODE_GRIND ? this.V : Mathf.sqrt(this.vx * this.vx + this.vy * this.vy + this.vz * this.vz);
        r.heading = this.heading;
        r.onGround = this.mode == MODE_GROUND;
        r.inAir = this.mode == MODE_AIR;
        r.grind = this.mode == MODE_GRIND ? this.grind.gameKind() : GRIND_NONE;
        r.tumbling = this.mode == MODE_TUMBLE;
        r.tuck = this.tuck;
        r.crouch = this.crouch;
        r.carve = this.mode == MODE_GROUND ? this.carve : 0;
        r.skid = this.mode == MODE_GROUND ? this.skid : 0;
        // -1 heel .. +1 toe: a right turn is on the toes for a regular rider riding forward
        const lean = clampf(this.edge / (55 * DEG), -1, 1);
        r.lean = this.mode == MODE_GROUND ? (this.switchStance ? -lean : lean) : 0;
        r.surface = this.surface;
        r.airTime = this.mode == MODE_AIR ? this.airTime : 0;
        r.spinRate = this.spinRate;
        r.flipRate = this.flipRate;
        r.balance = this.mode == MODE_GRIND ? this.grind.balance : 0;
        r.grab = this.grabBlend > 0.5 ? this.grab : GRAB_NONE;
        r.switchStance = this.switchStance;
        r.s = this.s;
        r.section = this.section;
        r.highLine = this.highLine;
    }
}

// RAD is re-exported for the view's use
export const RAD_PER_DEG: f32 = DEG;
export const DEG_PER_RAD: f32 = RAD;
