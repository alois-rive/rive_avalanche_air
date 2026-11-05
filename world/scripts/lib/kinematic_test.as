// The motion layer's units, copied from the kart sample's (its
// lib/kinematic_test.as, the cases of the parts kept here): `rive . --test`.
// The Pcg32 reference is O'Neill's own algorithm (seed 42, stream 54 gives
// the pcg32 demo's published 0xa15c02b7, 0x7b47f409, ...).
import { Tests } from "rive/test";
import { DrawnPose, FixedClock, Pcg32, approach, wrapAngle } from "./kinematic";
import { Q } from "./quat";

export class KinematicTests extends Tests {
    override run(): void {
        test("the fixed clock runs two 1/120 s ticks a 1/60 s frame, and keeps the remainder of others", (expect) => {
            const tick: f32 = <f32>(1.0 / 120.0);
            const a = new FixedClock(tick, 6);
            let total = 0;
            for (let i = 0; i < 600; i++) {
                const n = a.advance(<f32>(1.0 / 60.0));
                expect.that(n).is(2);
                total += n;
            }
            expect.that(total).is(1200);
            const b = new FixedClock(tick, 6);
            total = 0;
            for (let i = 0; i < 144; i++) {
                const n = b.advance(<f32>(1.0 / 144.0));
                expect.that(n <= 1).is(true);
                total += n;
            }
            expect.that(total).greaterThan(118);
            expect.that(total).lessThan(122);
            const d = new FixedClock(tick, 6);
            expect.that(d.advance(0.25)).is(6);
            expect.that(d.advance(<f32>(1.0 / 60.0))).is(2);
        });

        test("Pcg32 gives O'Neill's numbers", (expect) => {
            const demo = new Pcg32(42, 54);
            expect.that(demo.next()).is(0xa15c02b7);
            expect.that(demo.next()).is(0x7b47f409);
            expect.that(demo.next()).is(0xba1d3330);
            const q = new Pcg32(1, 0);
            let lo: f32 = 1;
            let hi: f32 = -1;
            for (let i = 0; i < 1000; i++) {
                const f = q.nextSigned();
                if (f < lo) lo = f;
                if (f > hi) hi = f;
            }
            expect.that(lo >= -1).is(true);
            expect.that(hi < 1).is(true);
        });

        test("angles wrap into (-pi, pi], approach stops at its target", (expect) => {
            expect.that(Mathf.abs(wrapAngle(7.0) - <f32>(7.0 - 6.28318530717959))).lessThan(1e-5);
            expect.that(Mathf.abs(wrapAngle(-3.2) - <f32>(-3.2 + 6.28318530717959))).lessThan(1e-5);
            expect.that(approach(0.9, 1, 0.5)).is(1);
            expect.that(approach(0.5, 0, 0.2)).is(0.3);
        });

        test("a drawn pose blends between its ticks and writes nothing at rest", (expect) => {
            const d = new DrawnPose();
            const q0 = new Q().setAxisAngle(0, 1, 0, 0);
            const q1 = new Q().setAxisAngle(0, 1, 0, 1);
            d.set(0.0, 0.0, 0.0, q0.x, q0.y, q0.z, q0.w);
            d.snap();
            d.set(2.0, 0.0, -4.0, q1.x, q1.y, q1.z, q1.w);
            expect.that(d.blend(0.5)).is(true);
            expect.that(Mathf.abs(d.ox - 1.0)).lessThan(1e-6);
            expect.that(Mathf.abs(d.oz + 2.0)).lessThan(1e-6);
            const mid = new Q().setAxisAngle(0, 1, 0, 0.5);
            expect.that(Mathf.abs(d.oqy - mid.y)).lessThan(1e-5);
            expect.that(Mathf.abs(d.oqw - mid.w)).lessThan(1e-5);
            expect.that(d.blend(0.5)).is(false);
        });

        test("quaternions turn about the body's and the world's axes", (expect) => {
            const q = new Q();
            // a quarter turn about the body's up: its nose (-Z) to the left (-X)
            q.turnLocal(0, 1, 0, 1.5707963);
            q.rotate(0, 0, -1);
            expect.that(Mathf.abs(q.rx + 1)).lessThan(1e-5);
            expect.that(Mathf.abs(q.rz)).lessThan(1e-5);
            // a back flip's first quarter about the body's +X: the nose up
            const f = new Q();
            f.turnLocal(1, 0, 0, 1.5707963);
            f.rotate(0, 0, -1);
            expect.that(Mathf.abs(f.ry - 1)).lessThan(1e-5);
            // upright on a slope falling down -Z, the nose down it
            const g = new Q();
            const s: f32 = 0.2588;
            const c: f32 = 0.9659;
            g.setOnGround(0, 0, c, -s);
            g.rotate(0, 1, 0);
            expect.that(Mathf.abs(g.ry - c)).lessThan(1e-4);
            g.rotate(0, 0, -1);
            expect.that(g.ry).lessThan(-0.25);
            expect.that(Mathf.abs(g.rx)).lessThan(1e-5);
        });
    }
}
