// The unit renders (docs/AUDIO.md, section 12): the Spu run offline on the
// main lane, block by block, each instrument, each board layer at three
// speeds, each cue and the announcer alone; their length, peak, brightness,
// no NaN, no click; the music's tempo on the meter; determinism.
import { Expect, Tests } from "rive/test";
import { Spu } from "./spu";
import {
    CUE_BAIL, CUE_COUNT, CUE_CRASH, CUE_GATE, CUE_GRAB, CUE_GRADE, CUE_LAND, CUE_OLLIE, CUE_PERFECT, CUE_SAY,
    CUE_SPIN, CUE_TALLY_END, CUE_TALLY_TICK, CUE_TEST, CUE_UI_BACK, CUE_UI_MOVE, CUE_UI_SELECT, Cue, Knobs, Meter,
    MUS_RESULTS, MUS_SPLIT, MUS_TITLE, MUS_WARMUP, SpuInputs, CUE_GRIND_START, CUE_CONFETTI,
} from "./shared";

const RATE: f64 = 48000;
const FRAMES: i32 = 512;

// one offline render: a fresh Spu, its knobs, a cue at the start, `seconds` long
@editTime
class Render {
    inputs: SpuInputs = new SpuInputs();
    spu: Spu = new Spu();
    knobs: Knobs = new Knobs();
    out: StaticArray<f32> = new StaticArray<f32>(FRAMES * 2);
    peak: f32 = 0;
    sumSq: f64 = 0;
    n: i32 = 0;
    nan: i32 = 0;
    maxStep: f32 = 0;
    crossings: i32 = 0;
    prev: f32 = 0;
    frame: f64 = 0;
    meter: Meter = new Meter();
    hash: f64 = 0;

    constructor() {
        this.knobs.musicVolume = 0.8;
        this.knobs.sfxVolume = 0.9;
        this.knobs.voiceVolume = 1;
        this.inputs.knobs.publish(this.knobs);
        this.spu.init(RATE, FRAMES, 2, this.inputs);
    }

    cue(kind: i32, a: f32 = 0, b: f32 = 0, c: f32 = 0): void {
        const q = new Cue();
        q.kind = kind;
        q.a = a;
        q.b = b;
        q.c = c;
        this.inputs.cues.send(q);
    }

    publish(): void {
        this.inputs.knobs.publish(this.knobs);
    }

    run(seconds: f64): void {
        const blocks = <i32>(seconds * RATE / <f64>FRAMES);
        for (let b = 0; b < blocks; b++) {
            // the main lane publishes every frame (stale knobs read as a pause)
            this.inputs.knobs.publish(this.knobs);
            for (let i = 0; i < FRAMES * 2; i++) this.out[i] = 0;
            this.spu.process(this.out, FRAMES, this.frame);
            this.frame += <f64>FRAMES;
            for (let i = 0; i < FRAMES; i++) {
                const l = this.out[2 * i];
                if (isNaN(l) || !isFinite(l)) {
                    this.nan++;
                    continue;
                }
                const a = Mathf.abs(l);
                if (a > this.peak) this.peak = a;
                this.sumSq += <f64>(l * l);
                this.n++;
                const st = Mathf.abs(l - this.prev);
                if (st > this.maxStep) this.maxStep = st;
                if ((l >= 0) != (this.prev >= 0)) this.crossings++;
                this.prev = l;
                this.hash = this.hash * 1.0000001 + <f64>l;
            }
            const m = this.inputs.meter.latest();
            if (m != null) {
                this.meter.beat = m.value.beat;
                this.meter.bar = m.value.bar;
                this.meter.speaking = m.value.speaking;
                this.meter.lineSeq = m.value.lineSeq;
                this.meter.voices = m.value.voices;
            }
        }
    }

    peakDb(): f32 {
        return 20 * Mathf.log10(this.peak + 1e-9);
    }

    rmsDb(): f32 {
        return <f32>(10 * Math.log10(this.sumSq / <f64>max<i32>(this.n, 1) + 1e-18));
    }

    // zero crossings a second: a cheap brightness
    zcr(): f32 {
        return <f32>this.crossings / <f32>(<f64>this.n / RATE);
    }
}

@editTime
function expectSane(expect: Expect, r: Render, minDb: f32): void {
    expect.that(r.nan).is(0);
    expect.that(r.peakDb()).lessThan(-0.99);
    expect.that(r.peakDb()).greaterThan(minDb);
    // no click: no sample-to-sample jump of 0.6 (the bright sounds' steps are under it)
    expect.that(r.maxStep).lessThan(0.6);
}

export class AudioTests extends Tests {
    override run(): void {
        group("the processor", () => {
            test("is silent with nothing to play", (expect) => {
                const r = new Render();
                r.run(1.0);
                expect.that(r.nan).is(0);
                expect.that(r.peak).lessThan(0.0001);
            });
            test("renders the same samples twice", (expect) => {
                const a = new Render();
                a.cue(CUE_CRASH, 15);
                a.run(1.0);
                const b = new Render();
                b.cue(CUE_CRASH, 15);
                b.run(1.0);
                expect.that(a.hash).is(b.hash);
                expect.that(a.peak).greaterThan(0.01);
            });
        });

        group("the instruments", () => {
            for (let inst = 0; inst <= 12; inst++) {
                test("instrument " + inst.toString(), (expect) => {
                    const r = new Render();
                    r.knobs.music = 0;
                    r.publish();
                    r.cue(CUE_TEST, <f32>inst, inst == 7 ? 41 : (inst == 10 ? 77 : 0), 1);
                    r.run(inst == 11 ? 3.0 : 1.5);
                    expectSane(expect, r, -45);
                });
            }
            test("the hats are brighter than the kick", (expect) => {
                const k = new Render();
                k.cue(CUE_TEST, 0, 0, 1);
                k.run(0.5);
                const h = new Render();
                h.cue(CUE_TEST, 3, 0, 1);
                h.run(0.5);
                expect.that(h.zcr()).greaterThan(k.zcr() * 10);
            });
        });

        group("the board", () => {
            test("the glide grows with the speed", (expect) => {
                let last: f32 = -200;
                for (let k = 0; k < 3; k++) {
                    const r = new Render();
                    r.knobs.onCourse = 1;
                    r.knobs.speed = k == 0 ? 5 : (k == 1 ? 15 : 27);
                    r.publish();
                    r.run(1.0);
                    expectSane(expect, r, -60);
                    expect.that(r.rmsDb()).greaterThan(last + 3);
                    last = r.rmsDb();
                }
            });
            for (let layer = 0; layer < 8; layer++) {
                // carve, skid, powder, ice, air, rail, box, log
                const k = layer;
                test("the layer " + k.toString(), (expect) => {
                    const r = new Render();
                    r.knobs.onCourse = 1;
                    r.knobs.speed = 15;
                    r.knobs.carve = k == 0 ? 1 : 0;
                    r.knobs.skid = k == 1 ? 1 : 0;
                    r.knobs.surface = k == 2 ? 1 : (k == 3 ? 2 : 0);
                    r.knobs.air = k == 4 ? 1 : 0;
                    r.knobs.airTime = k == 4 ? 1.5 : 0;
                    r.knobs.grind = k == 5 ? 1 : (k == 6 ? 2 : (k == 7 ? 3 : 0));
                    r.knobs.grindSpeed = k >= 5 ? 12 : 0;
                    r.publish();
                    r.run(1.0);
                    expectSane(expect, r, -50);
                });
            }
            test("the rail rings brighter than the log", (expect) => {
                const a = new Render();
                a.knobs.onCourse = 1;
                a.knobs.speed = 12;
                a.knobs.grind = 1;
                a.knobs.grindSpeed = 12;
                a.publish();
                a.run(1.0);
                const b = new Render();
                b.knobs.onCourse = 1;
                b.knobs.speed = 12;
                b.knobs.grind = 3;
                b.knobs.grindSpeed = 12;
                b.publish();
                b.run(1.0);
                expect.that(a.zcr()).greaterThan(b.zcr() * 1.5);
            });
        });

        group("the cues", () => {
            const kinds: StaticArray<i32> = [
                CUE_OLLIE, CUE_LAND, CUE_PERFECT, CUE_CRASH, CUE_BAIL, CUE_GRAB, CUE_SPIN, CUE_GATE, CUE_GRIND_START,
                CUE_CONFETTI, CUE_UI_MOVE, CUE_UI_SELECT, CUE_UI_BACK, CUE_COUNT, CUE_TALLY_TICK, CUE_TALLY_END, CUE_GRADE,
            ];
            for (let i = 0; i < kinds.length; i++) {
                const kind = kinds[i];
                test("cue " + kind.toString(), (expect) => {
                    const r = new Render();
                    r.cue(kind, 6, 1);
                    r.run(1.2);
                    expectSane(expect, r, -50);
                });
            }
        });

        group("the announcer", () => {
            test("speaks a line and reports it", (expect) => {
                const r = new Render();
                r.cue(CUE_SAY, 6, 2);
                r.run(0.3);
                expect.that(r.meter.speaking).is(6);
                expect.that(r.meter.lineSeq).is(1);
                r.run(2.0);
                expect.that(r.meter.speaking).is(-1);
                expectSane(expect, r, -30);
            });
            test("a higher priority cuts in", (expect) => {
                const r = new Render();
                r.cue(CUE_SAY, 100, 2, 1234);
                r.run(0.2);
                r.cue(CUE_SAY, 12, 1);
                r.run(0.2);
                expect.that(r.meter.speaking).is(12);
                expect.that(r.meter.lineSeq).is(2);
            });
            test("a line waits, then is dropped after 1.2 s", (expect) => {
                const r = new Render();
                r.cue(CUE_SAY, 100, 2, <f32>(3 + 64 * 2 + 512 * 1));
                r.cue(CUE_SAY, 5, 3);
                r.run(0.2);
                expect.that(r.meter.speaking).is(100);
                r.run(3.0);
                // the trick name lasts about 1.7 s: "NICE!" waited past 1.2 s and was dropped
                expect.that(r.meter.lineSeq).is(1);
            });
        });

        group("the music", () => {
            test("plays at 170 BPM on its own clock", (expect) => {
                const r = new Render();
                r.knobs.music = MUS_WARMUP;
                r.publish();
                r.run(4.0);
                // 4 s at 170 BPM: 11.3 beats, the first on the first block
                expect.that(r.meter.beat).greaterThanOrEqual(11);
                expect.that(r.meter.beat).lessThanOrEqual(12);
                expectSane(expect, r, -30);
            });
            const states: StaticArray<i32> = [MUS_TITLE, MUS_SPLIT, MUS_RESULTS];
            for (let i = 0; i < states.length; i++) {
                const state = states[i];
                test("the state " + state.toString() + " renders", (expect) => {
                    const r = new Render();
                    r.knobs.music = state;
                    r.publish();
                    r.run(1.5);
                    expectSane(expect, r, -40);
                });
            }
        });
    }
}
