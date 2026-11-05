// The rider's units (docs/TESTS.md; RIDER.md, sections 3 to 9): `rive .
// --test`. The laws are tested on their own (the slope's terminal speeds,
// the yaw rates, the ollie's pop and heights, the landing table); the
// whole rider on the course through course_api (the air's rotation and
// its stop, the crash's timing and the respawn's rules), which hold
// whatever the course's shape.
import { Tests } from "rive/test";
import { AIR_GRAVITY, LinePoint, lineSample } from "./course_api";
import { LAND_CLEAN, LAND_PERFECT, LAND_SKETCHY, game } from "./game_state";
import { Input } from "./input";
import { DEG } from "./lib/kinematic";
import {
    CONTROL_AT, CRASH_OTHER, LAND_CRASH, MODE_AIR, MODE_GROUND, MODE_TUMBLE, RESPAWN_AT, Rider, SPEED_CAP, judgeLanding, popSpeed,
    snowAccel, yawRateDeg,
} from "./rider";
import { Tricks } from "./tricks";

const TICK: f32 = <f32>(1.0 / 120.0);

// The speed a rider settles at on a plane of `deg` degrees, straight down
// it, from rest (60 s of ticks).
function terminal(deg: f32, mu: f32, tuck: f32): f32 {
    const ty = -Mathf.sin(deg * DEG);
    const ny = Mathf.cos(deg * DEG);
    let v: f32 = 0;
    for (let i = 0; i < 7200; i++) {
        v += snowAccel(v, ty, ny, mu, tuck, 0) * TICK;
        if (v > SPEED_CAP) v = SPEED_CAP;
        if (v < 0) v = 0;
    }
    return v;
}

export class RiderTests extends Tests {
    override run(): void {
        test("a 15 degree groomed slope settles at 20 m/s standing, under the 27 m/s cap tucked", (expect) => {
            const stand = terminal(15, 0.035, 0);
            expect.that(stand).greaterThan(19);
            expect.that(stand).lessThan(21);
            const tuck = terminal(15, 0.035, 1);
            expect.that(tuck).greaterThan(24.5);
            expect.that(tuck).lessThanOrEqual(27);
            // a steeper slope reaches the cap, never more
            expect.that(terminal(30, 0.035, 1)).is(SPEED_CAP);
            // powder is slower
            expect.that(terminal(15, 0.09, 0)).lessThan(stand - 2);
        });

        test("the yaw rate is 120 deg/s at 6 m/s, 50 at 27, x 0.6 in a full tuck", (expect) => {
            expect.that(yawRateDeg(4, 0)).is(120);
            expect.that(Mathf.abs(yawRateDeg(27, 0) - 50)).lessThan(0.01);
            expect.that(Mathf.abs(yawRateDeg(16.5, 0) - 85)).lessThan(0.01);
            expect.that(Mathf.abs(yawRateDeg(4, 1) - 72)).lessThan(0.01);
        });

        test("the ollie pops 3.8 m/s on a tap and 6.2 m/s fully charged: 0.56 and 1.48 m on the flat", (expect) => {
            expect.that(Mathf.abs(popSpeed(0) - 3.8)).lessThan(0.001);
            expect.that(Mathf.abs(popSpeed(0.2) - 5.0)).lessThan(0.001);
            expect.that(Mathf.abs(popSpeed(0.4) - 6.2)).lessThan(0.001);
            expect.that(Mathf.abs(popSpeed(1.0) - 6.2)).lessThan(0.001);
            const tap = popSpeed(0);
            const full = popSpeed(0.4);
            // apex v^2 / 2g at the air's gravity, 13 m/s^2
            expect.that(Mathf.abs(tap * tap / (2 * AIR_GRAVITY) - 0.555)).lessThan(0.01);
            expect.that(Mathf.abs(full * full / (2 * AIR_GRAVITY) - 1.478)).lessThan(0.01);
            // and the air it gives on the flat: 0.58 s and 0.95 s
            expect.that(Mathf.abs(2 * full / AIR_GRAVITY - 0.954)).lessThan(0.01);
        });

        test("landings are judged by RIDER.md's table, the impact lowering them", (expect) => {
            expect.that(judgeLanding(10 * DEG, 11 * DEG, 4)).is(LAND_PERFECT);
            expect.that(judgeLanding(13 * DEG, 5 * DEG, 4)).is(LAND_CLEAN);
            expect.that(judgeLanding(29 * DEG, 24 * DEG, 4)).is(LAND_CLEAN);
            expect.that(judgeLanding(45 * DEG, 10 * DEG, 4)).is(LAND_SKETCHY);
            expect.that(judgeLanding(5 * DEG, 39 * DEG, 4)).is(LAND_SKETCHY);
            expect.that(judgeLanding(55 * DEG, 5 * DEG, 4)).is(LAND_CRASH);
            expect.that(judgeLanding(5 * DEG, 45 * DEG, 4)).is(LAND_CRASH);
            // above 9 m/s one step lower; above 13 m/s a crash whatever the angles
            expect.that(judgeLanding(5 * DEG, 5 * DEG, 10)).is(LAND_CLEAN);
            expect.that(judgeLanding(20 * DEG, 5 * DEG, 10)).is(LAND_SKETCHY);
            expect.that(judgeLanding(40 * DEG, 5 * DEG, 10)).is(LAND_CRASH);
            expect.that(judgeLanding(0, 0, 13.5)).is(LAND_CRASH);
        });

        test("a spin held turns at up to 540 deg/s and stops about 40 degrees past its release", (expect) => {
            const tricks = new Tricks();
            const r = new Rider(tricks);
            tricks.reset();
            r.reset(1);
            r.placeAt(30, false, 12);
            // thrown high into the air, holding right for 0.5 s
            r.mode = MODE_AIR;
            r.vy = 20;
            r.y += 5;
            const inp = new Input();
            inp.x = 1;
            for (let i = 0; i < 60; i++) r.tick(inp, TICK);
            expect.that(r.mode).is(MODE_AIR);
            // a ramp of 0.15 s to full rate: 540 x 0.5 - 40.5
            expect.that(Mathf.abs(r.spinDeg + 229.5)).lessThan(6);
            const atRelease = r.spinDeg;
            inp.x = 0;
            for (let i = 0; i < 30; i++) r.tick(inp, TICK);
            const coast = Mathf.abs(r.spinDeg - atRelease);
            expect.that(coast).greaterThan(35);
            expect.that(coast).lessThan(46);
            expect.that(r.spinRate).is(0);
        });

        test("a crash respawns at 1.15 s on a safe point at least 5 m on, control back at 1.25 s", (expect) => {
            const tricks = new Tricks();
            const r = new Rider(tricks);
            tricks.reset();
            r.reset(1);
            r.placeAt(40, false, 14);
            const s0 = r.s;
            const inp = new Input();
            r.crash(CRASH_OTHER);
            expect.that(r.mode).is(MODE_TUMBLE);
            expect.that(tricks.crashes).is(1);
            let ticks = 0;
            let respawnTick = -1;
            let controlTick = -1;
            while (ticks < 400 && controlTick < 0) {
                r.tick(inp, TICK);
                ticks++;
                if (respawnTick < 0 && r.mode != MODE_TUMBLE) respawnTick = ticks;
                if (controlTick < 0 && r.hasControl()) controlTick = ticks;
            }
            // 1.15 s and 1.25 s at 120 ticks a second (the brief's 1.5 s)
            expect.that(Mathf.abs(<f32>respawnTick - RESPAWN_AT * 120)).lessThanOrEqual(1);
            expect.that(Mathf.abs(<f32>controlTick - CONTROL_AT * 120)).lessThanOrEqual(1);
            expect.that(r.mode).is(MODE_GROUND);
            expect.that(r.s).greaterThanOrEqual(s0 + 5);
            const lp = new LinePoint();
            lineSample(<i32>Mathf.round(r.s), false, lp);
            expect.that(r.V).greaterThanOrEqual(7.5);
            // the blink: through obstacles for a second after control
            expect.that(r.blinking()).is(true);
        });

        test("a rider at the gate with no input pushes off and rides down the line", (expect) => {
            const tricks = new Tricks();
            const r = new Rider(tricks);
            tricks.reset();
            r.reset(1);
            const inp = new Input();
            for (let i = 0; i < 600; i++) r.tick(inp, TICK);
            expect.that(r.s).greaterThan(5);
            expect.that(r.V).greaterThan(2);
            game.rider.speed = 0;
            r.publish();
            expect.that(game.rider.speed).greaterThan(2);
        });
    }
}
