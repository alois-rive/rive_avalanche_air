// The tricks' units (docs/TRICKS.md): `rive . --test`. Naming (both
// stances), values, the repeats' decay, combos and their multipliers,
// landing and pop factors, praise, the tally, grades, the table.
import { Tests } from "rive/test";
import {
    FLIP_BACK, FLIP_DOUBLE_BACK, FLIP_DOUBLE_FRONT, FLIP_FRONT, FLIP_NONE, GRAB_INDY, GRAB_MELON, GRAB_METHOD, GRAB_NONE,
    LAND_CLEAN, LAND_PERFECT, LAND_SKETCHY, PRAISE_BAIL, PRAISE_INSANE, PRAISE_NICE, PRAISE_NONE, PRAISE_RADICAL,
    PRAISE_SICK, PRAISE_SKETCHY, PRAISE_UNREAL, PRAISE_WIPEOUT, Table, game, packInitials,
} from "./game_state";
import {
    GRADE_A, GRADE_B, GRADE_C, GRADE_S, GRIND_NAME_5050, GRIND_NAME_BOARDSLIDE, Tricks, bigAirPoints, countFlip, countSpin,
    gradeFor, grabPoints, initialsOf, insertRow, praiseFor, rankOf, seedTable, spinDir, timeBonus,
} from "./tricks";

const TICK: f32 = <f32>(1.0 / 120.0);

// An air of `seconds`, the spin and flip reached linearly, a grab held
// from 0.1 s for `grabSeconds`.
function fly(t: Tricks, sw: bool, spin: f32, flip: f32, grab: i32, grabSeconds: f32, seconds: f32): void {
    t.takeoff(sw, false);
    const n = <i32>Mathf.round(seconds / TICK);
    for (let i = 1; i <= n; i++) {
        const k = <f32>i / <f32>n;
        const at = <f32>i * TICK;
        const g = at > 0.1 && at <= 0.1 + grabSeconds ? grab : GRAB_NONE;
        t.air(spin * k, flip * k, g, TICK);
    }
}

export class TricksTests extends Tests {
    override run(): void {
        test("spins count to the nearest half-turn within 45 degrees, else the one below", (expect) => {
            expect.that(countSpin(0)).is(0);
            expect.that(countSpin(134)).is(0);
            expect.that(countSpin(135)).is(180);
            expect.that(countSpin(690)).is(720);
            expect.that(countSpin(-690)).is(720);
            expect.that(countSpin(650)).is(540);
            expect.that(countSpin(1100)).is(1080);
            expect.that(countSpin(1600)).is(1440);
        });

        test("a spin to the left is frontside riding regular, backside riding switch", (expect) => {
            expect.that(spinDir(360, false)).is(1);
            expect.that(spinDir(-360, false)).is(2);
            expect.that(spinDir(360, true)).is(2);
            expect.that(spinDir(-360, true)).is(1);
            expect.that(spinDir(100, false)).is(0);
        });

        test("a flip from 300 degrees, two from 660", (expect) => {
            expect.that(countFlip(299)).is(FLIP_NONE);
            expect.that(countFlip(300)).is(FLIP_FRONT);
            expect.that(countFlip(-320)).is(FLIP_BACK);
            expect.that(countFlip(700)).is(FLIP_DOUBLE_FRONT);
            expect.that(countFlip(-660)).is(FLIP_DOUBLE_BACK);
        });

        test("grabs and big air are valued by TRICKS.md's table", (expect) => {
            expect.that(grabPoints(0.19)).is(0);
            expect.that(grabPoints(0.2)).is(200);
            expect.that(grabPoints(0.55)).is(425);
            expect.that(grabPoints(1.0)).is(800);
            expect.that(grabPoints(2.0)).is(1550);
            expect.that(grabPoints(3.5)).is(1550);
            expect.that(bigAirPoints(1.0)).is(0);
            expect.that(bigAirPoints(1.49)).is(0);
            expect.that(bigAirPoints(1.5)).is(200);
            expect.that(bigAirPoints(3.0)).is(800);
        });

        test("BACKSIDE 720 INDY is named and banked, x 1 alone", (expect) => {
            const t = new Tricks();
            t.reset();
            fly(t, false, -720, 0, GRAB_INDY, 1.0, 1.2);
            expect.that(game.trick.live).is(true);
            t.land(LAND_CLEAN);
            const tr = game.trick;
            expect.that(tr.spin).is(720);
            expect.that(tr.dir).is(2);
            expect.that(tr.grab1).is(GRAB_INDY);
            expect.that(tr.flip).is(FLIP_NONE);
            expect.that(tr.switchStance).is(false);
            expect.that(tr.live).is(false);
            // 1,050 + a grab held 1.0 s (800)
            expect.that(t.lastPoints).is(1850);
            expect.that(game.score).is(1850);
            expect.that(t.praise).is(PRAISE_NICE);
            expect.that(t.bankSeq).is(1);
        });

        test("SWITCH FRONTSIDE 540 and INDY TO MELON are named", (expect) => {
            const t = new Tricks();
            t.reset();
            fly(t, true, -540, 0, GRAB_NONE, 0, 1.0);
            t.land(LAND_CLEAN);
            expect.that(game.trick.switchStance).is(true);
            expect.that(game.trick.dir).is(1);
            expect.that(game.trick.spin).is(540);
            expect.that(t.lastPoints).is(675);
            // two grabs in one air
            t.takeoff(false, false);
            for (let i = 0; i < 40; i++) t.air(0, 0, GRAB_INDY, TICK);
            for (let i = 0; i < 40; i++) t.air(0, 0, GRAB_MELON, TICK);
            t.land(LAND_CLEAN);
            expect.that(game.trick.grab1).is(GRAB_INDY);
            expect.that(game.trick.grab2).is(GRAB_MELON);
        });

        test("the mega-jump's BACKFLIP 1080 MELON held 1.0 s with 3.0 s of air is worth 4,600", (expect) => {
            const t = new Tricks();
            t.reset();
            fly(t, false, -1080, -360, GRAB_MELON, 1.0, 3.0);
            t.land(LAND_CLEAN);
            expect.that(game.trick.flip).is(FLIP_BACK);
            expect.that(game.trick.spin).is(1080);
            expect.that(t.lastPoints).is(4600);
            expect.that(t.praise).is(PRAISE_SICK);
        });

        test("a name repeated decays: x 1, 0.75, 0.5, then 0.25", (expect) => {
            const t = new Tricks();
            t.reset();
            const want: StaticArray<f32> = [375, 281, 188, 94, 94];
            for (let i = 0; i < 5; i++) {
                fly(t, false, 360, 0, GRAB_NONE, 0, 0.8);
                t.land(LAND_CLEAN);
                expect.that(t.lastPoints).is(want[i]);
            }
            // another name is fresh
            fly(t, false, -360, 0, GRAB_NONE, 0, 0.8);
            t.land(LAND_CLEAN);
            expect.that(t.lastPoints).is(375);
        });

        test("a combo of an air, a grind and an air banks its sum x 3, x 1.25 perfect", (expect) => {
            const t = new Tricks();
            t.reset();
            fly(t, false, 360, 0, GRAB_NONE, 0, 0.8);
            t.catchRail(GRIND_NAME_5050, 0);
            for (let i = 0; i < 120; i++) t.grind(TICK);
            expect.that(game.comboMult).is(2);
            expect.that(game.comboActive).is(true);
            t.leaveRail();
            fly(t, false, 180, 0, GRAB_NONE, 0, 0.6);
            expect.that(t.count).is(2);
            t.land(LAND_PERFECT);
            // (375 + 450 + 150) x 3 x 1.25
            expect.that(t.lastPoints).is(3656);
            expect.that(t.praise).is(PRAISE_SICK);
            expect.that(t.perfects).is(1);
            expect.that(t.perfectSeq).is(1);
            expect.that(game.comboActive).is(false);
            // the tally's parts add up to it
            expect.that(t.tricksTotal + t.grindsTotal + t.comboBonus + t.landings).is(3656);
        });

        test("a boardslide on a kinked rail is worth x 1.25 x 1.5; grinds do not decay", (expect) => {
            const t = new Tricks();
            t.reset();
            for (let k = 0; k < 2; k++) {
                t.takeoff(false, false);
                t.catchRail(GRIND_NAME_BOARDSLIDE, 10);
                expect.that(game.trick.grind).is(12);
                for (let i = 0; i < 120; i++) t.grind(TICK);
                t.leaveRail();
                t.land(LAND_CLEAN);
                // (150 + 300) x 1.875
                expect.that(t.lastPoints).is(844);
            }
        });

        test("a sketchy landing halves the combo; a perfect pop adds a tenth", (expect) => {
            const t = new Tricks();
            t.reset();
            fly(t, false, 720, 0, GRAB_NONE, 0, 1.0);
            t.land(LAND_SKETCHY);
            expect.that(t.lastPoints).is(525);
            expect.that(t.praise).is(PRAISE_SKETCHY);
            t.takeoff(false, true);
            for (let i = 0; i < 120; i++) t.air(<f32>i * 6, 0, GRAB_NONE, TICK);
            t.land(LAND_CLEAN);
            // 720 (1,050; its first time: the other was named FS, this one too: decayed) ...
            expect.that(t.lastPoints).is(Mathf.round(788 * 1.1));
        });

        test("a crash loses the combo in progress, the bank keeps what was banked", (expect) => {
            const t = new Tricks();
            t.reset();
            fly(t, false, 180, 0, GRAB_NONE, 0, 0.6);
            t.land(LAND_CLEAN);
            const banked = game.score;
            fly(t, false, 1080, 0, GRAB_METHOD, 1.0, 2.0);
            t.lose(false, true);
            expect.that(game.score).is(banked);
            expect.that(game.comboActive).is(false);
            expect.that(t.crashes).is(1);
            expect.that(t.praise).is(PRAISE_WIPEOUT);
            t.takeoff(false, false);
            t.catchRail(GRIND_NAME_5050, 0);
            t.lose(true, false);
            expect.that(t.praise).is(PRAISE_BAIL);
            expect.that(t.bailSeq).is(1);
            expect.that(t.crashes).is(1);
        });

        test("praise words by the banked value", (expect) => {
            expect.that(praiseFor(999)).is(PRAISE_NONE);
            expect.that(praiseFor(1000)).is(PRAISE_NICE);
            expect.that(praiseFor(3000)).is(PRAISE_SICK);
            expect.that(praiseFor(6000)).is(PRAISE_RADICAL);
            expect.that(praiseFor(12000)).is(PRAISE_INSANE);
            expect.that(praiseFor(20000)).is(PRAISE_UNREAL);
        });

        test("the run's score is the banked combos and the time bonus; grades by it", (expect) => {
            expect.that(timeBonus(90)).is(2000);
            expect.that(timeBonus(100)).is(0);
            expect.that(timeBonus(120)).is(0);
            const t = new Tricks();
            t.reset();
            fly(t, false, 720, 0, GRAB_NONE, 0, 1.0);
            t.land(LAND_CLEAN);
            t.tally(88.5);
            expect.that(game.results.timeBonus).is(2300);
            expect.that(game.results.total).is(1050 + 2300);
            expect.that(game.results.grade).is(GRADE_C);
            expect.that(gradeFor(20000)).is(GRADE_B);
            expect.that(gradeFor(35000)).is(GRADE_A);
            expect.that(gradeFor(50000)).is(GRADE_S);
            expect.that(gradeFor(49999)).is(GRADE_A);
        });

        test("the table is seeded with ten fake riders, 45,000 down to 9,000, and takes a new score", (expect) => {
            const tb = new Table();
            seedTable(tb);
            expect.that(tb.scores[0]).is(45000);
            expect.that(tb.scores[9]).is(9000);
            expect.that(tb.tags[0]).is(initialsOf("AVA") * 8 + <f32>(2 * 2 + 1));
            expect.that(rankOf(tb, 50000)).is(1);
            expect.that(rankOf(tb, 30000)).is(5);
            expect.that(rankOf(tb, 9000)).is(0);
            expect.that(rankOf(tb, 9001)).is(10);
            insertRow(tb, 5, 30000, packInitials(1, 2, 3) * 8);
            expect.that(tb.scores[4]).is(30000);
            expect.that(tb.scores[5]).is(29000);
            expect.that(tb.scores[9]).is(13000);
            expect.that(initialsOf("AB1")).is(packInitials(1, 2, 28));
        });
    }
}
