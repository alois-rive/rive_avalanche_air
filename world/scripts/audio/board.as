// The board's voice (docs/AUDIO.md, section 4): continuous layers driven by
// the knobs, smoothed over 20 ms: the glide hiss, the edge carve, the skid
// scrape, the wind, the air's whoosh, the rail grind and the log slide, and
// a low rumble under them for the board's weight.
import { BLOCK, CONTROL_RATE, SPU_INV_RATE, Pink, Rng, Svf, adpcmGrit, sinTurn, smoothCoef } from "./dsp";
import { Bus } from "./voices";
import { Knobs } from "./shared";

const GRIND_RAIL: i32 = 1;
const GRIND_BOX: i32 = 2;
const GRIND_LOG: i32 = 3;

export class Board {
    rng: Rng = new Rng();
    rngR: Rng = new Rng();
    pinkL: Pink = new Pink();
    pinkR: Pink = new Pink();
    brown: f32 = 0;
    brown2: f32 = 0;

    // smoothed knobs
    speed: f32 = 0;
    carve: f32 = 0;
    skid: f32 = 0;
    tuck: f32 = 0;
    air: f32 = 0;          // 40 ms
    airTime: f32 = 0;
    onCourse: f32 = 0;
    grindSpeed: f32 = 0;
    balance: f32 = 0;
    wGroomed: f32 = 1;
    wPowder: f32 = 0;
    wIce: f32 = 0;
    wRock: f32 = 0;
    wRail: f32 = 0;        // the grind kinds, 30 ms
    wBox: f32 = 0;
    wLog: f32 = 0;
    duck: f32 = 1;         // the announcer's duck, from the mixer

    k20: f32 = 0;
    k40: f32 = 0;
    k30: f32 = 0;
    k200: f32 = 0;

    // the layers
    hiss: Svf = new Svf();
    hissLp: Svf = new Svf();
    shimmer: Svf = new Svf();
    rumble: Svf = new Svf();
    edge: Svf = new Svf();
    edgePh: f32 = 0;
    edgeRate: f32 = 18;
    edgeAmp: f32 = 1;
    scrape: Svf = new Svf();
    scrapeFc: f32 = 4000;
    scrapePrev: f32 = 0;
    windL: Svf = new Svf();
    windR: Svf = new Svf();
    whoosh: Svf = new Svf();
    swellPh: f32 = 0;
    res0: Svf = new Svf();
    res1: Svf = new Svf();
    res2: Svf = new Svf();
    res3: Svf = new Svf();
    squealPh: f32 = 0;
    vibPh: f32 = 0;
    wobblePh: f32 = 0;
    logLp: Svf = new Svf();
    knockDist: f32 = 0;
    knockEnv: f32 = 0;
    knockPh: f32 = 0;
    knockF: f32 = 180;
    tmp: StaticArray<f32> = new StaticArray<f32>(BLOCK);
    tmp2: StaticArray<f32> = new StaticArray<f32>(BLOCK);

    constructor() {
        this.rng.seed(17, 3);
        this.rngR.seed(29, 5);
        this.k20 = smoothCoef(0.02, CONTROL_RATE);
        this.k40 = smoothCoef(0.04, CONTROL_RATE);
        this.k30 = smoothCoef(0.03, CONTROL_RATE);
        this.k200 = smoothCoef(0.2, CONTROL_RATE);
        this.rumble.set(160, 0.7);
        this.shimmer.set(6000, 2);
        this.logLp.set(900, 0.8);
    }

    seed(s: u32): void {
        this.rng.seed(s, 3);
        this.rngR.seed(s, 5);
    }

    // once a block: the knobs, smoothed
    control(k: Knobs): void {
        const k20 = this.k20;
        this.speed += k20 * (k.speed - this.speed);
        this.carve += k20 * (k.carve - this.carve);
        this.skid += k20 * (k.skid - this.skid);
        this.tuck += k20 * (k.tuck - this.tuck);
        this.airTime = k.airTime;
        this.grindSpeed += k20 * (k.grindSpeed - this.grindSpeed);
        this.balance += k20 * (k.balance - this.balance);
        this.onCourse += this.k40 * (k.onCourse - this.onCourse);
        const air: f32 = k.air > 0.5 && k.grind == 0 ? 1 : 0;
        this.air += this.k40 * (air - this.air);
        const s = k.surface;
        this.wGroomed += k20 * ((s == 0 ? 1 : 0) - this.wGroomed);
        this.wPowder += k20 * ((s == 1 ? 1 : 0) - this.wPowder);
        this.wIce += k20 * ((s == 2 ? 1 : 0) - this.wIce);
        this.wRock += k20 * ((s == 3 ? 1 : 0) - this.wRock);
        const g = k.grind;
        this.wRail += this.k30 * ((g == GRIND_RAIL ? 1 : 0) - this.wRail);
        this.wBox += this.k30 * ((g == GRIND_BOX ? 1 : 0) - this.wBox);
        this.wLog += this.k30 * ((g == GRIND_LOG ? 1 : 0) - this.wLog);
    }

    @unchecked
    render(bus: Bus): void {
        const course = this.onCourse;
        if (course < 0.0005) return;
        const sp = this.speed;
        const spN = min<f32>(max<f32>(sp, 0) / 27, 1.3);
        const ground = (1 - this.air) * (1 - max<f32>(this.wRail + this.wBox + this.wLog, 0)) * course;
        const duck = this.duck;
        const tmp = this.tmp;
        const tmp2 = this.tmp2;
        const bl = bus.l;
        const br = bus.r;
        const bs = bus.send;
        for (let i = 0; i < BLOCK; i++) {
            tmp[i] = 0;
            tmp2[i] = 0;
        }

        // ---- the glide hiss and the rumble ----------------------------------
        let hissGain: f32 = 0;
        if (sp > 1) hissGain = 0.55 * Mathf.pow(min<f32>((sp - 1) / 26, 1.2), 0.8);
        hissGain *= ground;
        if (hissGain > 0.0005) {
            const surf = this.wGroomed + this.wPowder * 0.6 + this.wIce * 1.4 + this.wRock * 1.1;
            const q = this.wGroomed * 0.7 + this.wPowder * 0.7 + this.wIce * 1.5 + this.wRock * 1.0;
            this.hiss.set(Mathf.round((900 + 2600 * spN) * surf), Mathf.round(q * 20) / 20);
            const lpF = 11000 - 8500 * this.wPowder;
            this.hissLp.set(Mathf.round(lpF / 50) * 50, 0.7);
            const sh = this.wIce * 0.35;
            const rumbleG = 0.9 * (0.4 + this.wPowder);
            const rough = this.wRock;
            for (let i = 0; i < BLOCK; i++) {
                const w = this.rng.white();
                this.hiss.tick(w);
                let y = this.hiss.bpn();
                this.hissLp.tick(y);
                y = this.hissLp.lp;
                if (sh > 0.001) {
                    this.shimmer.tick(w);
                    y += this.shimmer.bpn() * sh;
                }
                this.brown = this.brown * 0.99 + w * 0.1;
                this.rumble.tick(this.brown);
                y += this.rumble.lp * rumbleG;
                if (rough > 0.01) {
                    // rocks under the base: random ticks
                    if (this.rng.unit() < 0.004 * rough * spN) y += (this.rng.white()) * 2.5 * rough;
                }
                tmp[i] = y * hissGain;
            }
        }

        // ---- the edge carve -------------------------------------------------
        const carveGain = this.carve * (0.25 + 0.75 * min<f32>(spN, 1)) * ground * 0.75;
        if (carveGain > 0.0005) {
            this.edge.set(3200, 2);
            for (let i = 0; i < BLOCK; i++) {
                this.edgePh += this.edgeRate * SPU_INV_RATE;
                if (this.edgePh >= 1) {
                    this.edgePh -= 1;
                    // a seeded jitter: each chatter cycle its own rate and strength
                    this.edgeRate = 14 + 8 * this.rng.unit();
                    this.edgeAmp = 0.6 + 0.4 * this.rng.unit();
                }
                const am = 0.35 + 0.65 * this.edgeAmp * (0.5 + 0.5 * sinTurn(this.edgePh));
                this.edge.tick(this.rng.white());
                tmp[i] += this.edge.bpn() * am * carveGain;
            }
        }

        // ---- the skid scrape (with grit 0.6) -------------------------------
        const skidGain = (this.skid * (0.3 + 0.7 * min<f32>(spN, 1)) + this.wRock * 0.15 * spN) * ground;
        if (skidGain > 0.0005) {
            this.scrapeFc += (3500 + 1000 * this.rng.unit() - this.scrapeFc) * 0.05;
            this.scrape.set(Mathf.round(this.scrapeFc / 25) * 25, 1.2);
            for (let i = 0; i < BLOCK; i++) {
                const w = this.rng.white();
                this.brown2 = this.brown2 * 0.985 + w * 0.15;
                this.scrape.tick(w);
                tmp2[i] = (this.brown2 * 0.6 + this.scrape.bpn() * 0.5) * skidGain;
            }
            this.scrapePrev = adpcmGrit(tmp2, 0, BLOCK, 0.6, this.scrapePrev);
            for (let i = 0; i < BLOCK; i++) tmp[i] += tmp2[i];
        }

        // ---- the air's whoosh ----------------------------------------------
        const airAmt = this.air * course;
        let whooshGain: f32 = 0;
        if (airAmt > 0.001) {
            this.swellPh += 0.5 * <f32>BLOCK * SPU_INV_RATE;
            if (this.swellPh >= 1) this.swellPh -= 1;
            const grow = min<f32>(this.airTime / 1.2, 1);
            whooshGain = airAmt * grow * (0.6 + 0.4 * sinTurn(this.swellPh)) * (0.3 + 0.7 * min<f32>(spN, 1)) * 0.5;
            this.whoosh.set(Mathf.round(450 + 250 * sinTurn(this.swellPh * 0.5)), 0.9);
        }
        if (whooshGain > 0.0005) {
            for (let i = 0; i < BLOCK; i++) {
                this.whoosh.tick(this.rngR.white());
                tmp[i] += this.whoosh.bpn() * whooshGain;
            }
        }

        // ---- the rail grind, the box ---------------------------------------
        const metal = (this.wRail + this.wBox) * course;
        if (metal > 0.001) {
            const gs = min<f32>(this.grindSpeed / 15, 1.3);
            const gain = metal * (0.25 + 0.75 * gs) * 0.55;
            const bright = 0.4 + 0.6 * gs;
            this.wobblePh += 5.5 * <f32>BLOCK * SPU_INV_RATE;
            if (this.wobblePh >= 1) this.wobblePh -= 1;
            const bal = this.balance;
            const wob = 1 + 0.02 * bal * sinTurn(this.wobblePh);
            const rail = this.wRail / max<f32>(this.wRail + this.wBox, 0.001);
            // rail: 523, 1371, 2887, 4102 Hz (Q 30); box: 220, 517, 863, 1300
            const f0 = (523 * rail + 220 * (1 - rail)) * wob;
            const f1 = (1371 * rail + 517 * (1 - rail)) * wob;
            const f2 = (2887 * rail + 863 * (1 - rail)) * wob;
            const f3 = (4102 * rail + 1300 * (1 - rail)) * wob;
            this.res0.set(Mathf.round(f0), 30);
            this.res1.set(Mathf.round(f1), 30);
            this.res2.set(Mathf.round(f2), 30);
            this.res3.set(Mathf.round(f3), 30);
            const squeal = rail * 0.05 * (0.5 + 0.8 * abs<f32>(bal)) * gs;
            const wobAmp = 1 - 0.35 * abs<f32>(bal) * (0.5 + 0.5 * sinTurn(this.wobblePh * 2));
            for (let i = 0; i < BLOCK; i++) {
                const w = this.rng.white();
                this.res0.tick(w);
                this.res1.tick(w);
                this.res2.tick(w);
                this.res3.tick(w);
                let y = this.res0.bpn() * 1.0 + this.res1.bpn() * 1.1 + (this.res2.bpn() * 1.2 + this.res3.bpn()) * bright;
                y *= 3.2;
                this.vibPh += 6 * SPU_INV_RATE;
                if (this.vibPh >= 1) this.vibPh -= 1;
                this.squealPh += 3100 * (1 + 0.01 * sinTurn(this.vibPh)) * SPU_INV_RATE;
                if (this.squealPh >= 1) this.squealPh -= 1;
                y += sinTurn(this.squealPh) * squeal / max<f32>(gain, 0.05);
                tmp[i] += y * gain * wobAmp;
            }
        }

        // ---- the log slide --------------------------------------------------
        const wood = this.wLog * course;
        if (wood > 0.001) {
            const gs = min<f32>(this.grindSpeed / 12, 1.3);
            const gain = wood * (0.3 + 0.7 * gs) * 0.5;
            // a knock every 0.4 m of travel: the bark's bumps
            this.knockDist += this.grindSpeed * <f32>BLOCK * SPU_INV_RATE;
            if (this.knockDist >= 0.4) {
                this.knockDist -= 0.4;
                this.knockEnv = 0.7 + 0.3 * this.rng.unit();
                this.knockF = 165 + 30 * this.rng.unit();
                this.knockPh = 0;
            }
            const kmul: f32 = 0.9919;   // 25 ms to -60 dB at 22 kHz... a short knock
            for (let i = 0; i < BLOCK; i++) {
                this.logLp.tick(this.rng.white());
                let y = this.logLp.lp * 1.6;
                if (this.knockEnv > 0.0005) {
                    this.knockPh += this.knockF * SPU_INV_RATE;
                    if (this.knockPh >= 1) this.knockPh -= 1;
                    y += sinTurn(this.knockPh) * this.knockEnv * 1.2;
                    this.knockEnv *= kmul;
                }
                tmp[i] += y * gain;
            }
        }

        // ---- into the bus (mono), and the wind in stereo -------------------
        const g = duck;
        for (let i = 0; i < BLOCK; i++) {
            const y = tmp[i] * g;
            bl[i] += y;
            br[i] += y;
            bs[i] += y * 0.08;
        }
        let windGain = 0.3 * spN * spN * (1 + this.tuck) * course;
        if (windGain > 0.0005) {
            const fc = (300 + 1500 * min<f32>(sp / 30, 1)) * (1 + 0.4 * this.air);
            this.windL.set(Mathf.round(fc / 10) * 10, 0.9);
            this.windR.set(Mathf.round(fc * 1.07 / 10) * 10, 0.9);
            windGain *= g;
            for (let i = 0; i < BLOCK; i++) {
                this.windL.tick(this.pinkL.tick(this.rng.white()));
                this.windR.tick(this.pinkR.tick(this.rngR.white()));
                bl[i] += this.windL.lp * windGain;
                br[i] += this.windR.lp * windGain;
            }
        }
    }
}
