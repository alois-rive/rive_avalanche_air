// The course API's tests (`rive . --test`): the ground is the line's
// surface, the kickers fly their design flights onto their landings, every
// respawn point is safe, the rails are found near themselves, the
// progress search agrees with a fresh search, the sun follows its keys.
import { Tests } from "rive/test";
import {
    AIR_GRAVITY, COURSE_LENGTH, FEAT_KICKER, FEAT_MEGA, Feature, GroundHit, LinePoint, MERGE_S, Obstacle, SPLIT_S, Sun,
    feature, featureCount, ground, inFallZone, isHighSide, lineCount, lineSample, nearestSample, obstacle,
    obstaclesNear, railCount, railPoint, railPointCount, railsNear, respawnAt, sunAt,
} from "./course_api";
import { FOOT, FOOT_FEAT, FOOT_N } from "./course_data";

// Flies from the lip of the feature whose footprint is k (its frame in
// FOOT) at the design speed; returns the air time, or -1 with no landing;
// the impact into the slope is left in LAND[0].
const LAND = new StaticArray<f32>(2);

function fly(k: i32, f: Feature, hit: GroundHit): f32 {
    const b = k * 9;
    const ox = FOOT[b];
    const oz = FOOT[b + 1];
    const fx = FOOT[b + 2];
    const fz = FOOT[b + 3];
    ground(ox - fx * 0.05, oz - fz * 0.05, hit);
    let x = ox;
    let y = hit.y + 0.02;
    let z = oz;
    const th = f.lipAngle * Mathf.PI / 180;
    const vh = f.designSpeed * Mathf.cos(th);
    let vy = f.designSpeed * Mathf.sin(th);
    const dt: f32 = 1.0 / 240.0;
    let t: f32 = 0;
    while (t < 5) {
        x += fx * vh * dt;
        z += fz * vh * dt;
        vy -= AIR_GRAVITY * dt;
        y += vy * dt;
        t += dt;
        if (ground(x, z, hit) && y <= hit.y) {
            const vx = fx * vh;
            const vz = fz * vh;
            LAND[0] = -(vx * hit.nx + vy * hit.ny + vz * hit.nz);
            return t;
        }
    }
    return -1;
}

export class CourseTests extends Tests {
    override run(): void {
        test("the ground under every line sample is the sample's height", (expect) => {
            const p = new LinePoint();
            const hit = new GroundHit();
            for (let h = 0; h < 2; h++) {
                const high = h == 1;
                const n = lineCount(high);
                let worst: f32 = 0;
                for (let i = 0; i < n; i++) {
                    lineSample(i, high, p);
                    const on = ground(p.x, p.z, hit);
                    expect.that(on).is(true);
                    // in the air of a gap the line is the design flight, above the ground
                    if (p.y > hit.y + 0.05) {
                        expect.that(p.safe).is(false);
                        continue;
                    }
                    const d = Mathf.abs(hit.y - p.y);
                    if (d > worst) worst = d;
                }
                expect.that(worst).lessThan(0.02);
            }
        });

        test("each kicker flies its design speed onto its landing in its air time", (expect) => {
            const f = new Feature();
            const hit = new GroundHit();
            let kickers = 0;
            for (let k = 0; k < FOOT_N; k++) {
                feature(FOOT_FEAT[k], f);
                if (f.kind != FEAT_KICKER && f.kind != FEAT_MEGA) continue;
                kickers++;
                // the lip: the ground there says so, and rises at the lip's angle
                const b = k * 9;
                const ax = FOOT[b] - FOOT[b + 2] * 1.0;
                const az = FOOT[b + 1] - FOOT[b + 3] * 1.0;
                expect.that(ground(ax, az, hit)).is(true);
                expect.that(hit.lip).is(true);
                expect.that(hit.feature).is(FOOT_FEAT[k]);
                const y1 = hit.y;
                ground(FOOT[b] - FOOT[b + 2] * 2.5, FOOT[b + 1] - FOOT[b + 3] * 2.5, hit);
                const angle = Mathf.atan((y1 - hit.y) / 1.5) * 180 / Mathf.PI;
                // the main line's lips lie on a grid row (exact); the high
                // line's and the hip's cross the cells (their edge smeared over one)
                const exact = !f.high && Mathf.abs(FOOT[b + 2]) < 0.05;
                expect.that(Mathf.abs(angle - f.lipAngle)).lessThan(exact ? 1.0 : 6.0);
                const air = fly(k, f, hit);
                expect.that(air).greaterThan(0);
                expect.that(Mathf.abs(air - f.airTime)).lessThan(exact ? 0.12 : 0.4);
                expect.that(LAND[0]).lessThan(exact ? 9.5 : 12.0);
            }
            expect.that(kickers).greaterThan(10);
        });

        test("every respawn point is on the snow, outside the fall zones and clear of obstacles", (expect) => {
            const p = new LinePoint();
            const hit = new GroundHit();
            const ob = new Obstacle();
            const near = new StaticArray<i32>(16);
            for (let h = 0; h < 2; h++) {
                const high = h == 1;
                for (let s: f32 = 0; s < COURSE_LENGTH; s += 7) {
                    respawnAt(s, high, p);
                    expect.that(p.safe).is(true);
                    expect.that(p.s).greaterThanOrEqual(s);
                    expect.that(ground(p.x, p.z, hit)).is(true);
                    expect.that(Mathf.abs(hit.y - p.y)).lessThan(0.02);
                    expect.that(hit.surface).lessThan(2);
                    expect.that(hit.ny).greaterThan(0.85);
                    expect.that(inFallZone(p.x, p.y + 1, p.z)).is(false);
                    const n = obstaclesNear(p.x, p.z, 1.5, near);
                    for (let k = 0; k < n; k++) {
                        obstacle(near[k], ob);
                        // a respawn is clear of anything the rider would stand in
                        expect.that(p.y + 1.0 < ob.bottom || p.y > ob.top).is(true);
                    }
                }
            }
        });

        test("a rail is near its own points and not 20 m aside", (expect) => {
            const p = new LinePoint();
            const out = new StaticArray<i32>(8);
            for (let r = 0; r < railCount(); r++) {
                railPoint(r, railPointCount(r) / 2, p);
                let n = railsNear(p.x, p.z, 1.0, out);
                let found = false;
                for (let k = 0; k < n; k++) if (out[k] == r) found = true;
                expect.that(found).is(true);
                n = railsNear(p.x + 20 * p.tz, p.z - 20 * p.tx, 1.0, out);
                found = false;
                for (let k = 0; k < n; k++) if (out[k] == r) found = true;
                expect.that(found).is(false);
                expect.that(Mathf.abs(p.tx * p.tx + p.ty * p.ty + p.tz * p.tz - 1)).lessThan(0.001);
            }
        });

        test("the windowed progress search agrees with a fresh one along both lines", (expect) => {
            const p = new LinePoint();
            for (let h = 0; h < 2; h++) {
                const high = h == 1;
                let hint = -1;
                const n = lineCount(high);
                for (let i = 0; i < n; i += 3) {
                    lineSample(i, high, p);
                    const x = p.x + 2.0;
                    hint = nearestSample(x, p.z, hint, high);
                    expect.that(hint).is(nearestSample(x, p.z, -1, high));
                    expect.that(abs<i32>(hint - i)).lessThanOrEqual(1);
                }
            }
            // the split: the high line's points are on its side, the low line's not
            lineSample(<i32>SPLIT_S + 150, true, p);
            expect.that(isHighSide(p.x, p.z, p.s)).is(true);
            lineSample(<i32>SPLIT_S + 150, false, p);
            expect.that(isHighSide(p.x, p.z, p.s)).is(false);
            expect.that(MERGE_S).greaterThan(SPLIT_S);
        });

        test("the sun sinks and reddens down the course", (expect) => {
            const a = new Sun();
            const b = new Sun();
            sunAt(0, a);
            sunAt(COURSE_LENGTH, b);
            expect.that(a.dirY).greaterThan(b.dirY);
            expect.that(b.dirY).greaterThan(0);
            expect.that(a.fogEnd).greaterThan(b.fogEnd);
            expect.that(Mathf.abs(a.dirX * a.dirX + a.dirY * a.dirY + a.dirZ * a.dirZ - 1)).lessThan(0.001);
            expect.that(b.sunR).greaterThan(b.sunB);
            expect.that(featureCount()).greaterThan(30);
        });
    }
}
