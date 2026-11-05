// The one-shots (docs/AUDIO.md, sections 4 and 8): each a voice, or a few,
// from the pool. Levels are relative to the effects bus (the mixer scales
// it by the settings).
import { Rng, SPU_RATE } from "./dsp";
import {
    BUS_SFX, BUS_UI, FILT_BP, FILT_HP, FILT_LP, NOISE_BROWN, NOISE_PINK, NOISE_WHITE,
    VoicePool, WAVE_METAL, WAVE_SAW, WAVE_SINE, WAVE_SQUARE, WAVE_TRI,
} from "./voices";

const LAND_SKETCHY: i32 = 2;

function ms(x: f32): i32 {
    return <i32>(x * 0.001 * SPU_RATE);
}

export function sfxOllie(p: VoicePool, pop: f32): void {
    const g = 0.6 + 0.4 * min<f32>(pop / 6, 1);
    // the snap: high-passed noise above 2 kHz, 15 ms
    p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.002, 0.004, 0.015)
        .filter(FILT_HP, 2200, 2200, 0, 0.7, false).out(0.55 * g, 0, 0.1, 0.35);
    // the thud: 110 Hz dropping to 70 Hz, 80 ms
    p.alloc(BUS_SFX).tone(WAVE_SINE, 110, 70, 0.03, 1, 0.002, 0.01, 0.09).out(0.75 * g, 0, 0.05, 0.2);
}

export function sfxLand(p: VoicePool, impact: f32, quality: i32): void {
    const g = 0.45 + 0.55 * min<f32>(impact / 9, 1.2);
    // the crunch: noise low-passed at 2.5 kHz, 120 ms
    p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.003, 0.015, 0.14)
        .filter(FILT_LP, 2500, 1400, 0.08, 0.8, false).out(0.65 * g, 0, 0.12, 0.35);
    // the thump: a 70 Hz sine, 90 ms
    p.alloc(BUS_SFX).tone(WAVE_SINE, 95, 62, 0.02, 1, 0.002, 0.02, 0.11).out(0.95 * g, 0, 0.05, 0.15);
    if (quality == LAND_SKETCHY) {
        const v = p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.003, 0.01, 0.09)
            .filter(FILT_LP, 2000, 1200, 0.05, 0.8, false).out(0.4 * g, 0.2, 0.1, 0.4);
        v.delay = ms(80);
    }
}

export function sfxPerfect(p: VoicePool): void {
    // the "shing": 2,637 and 3,951 Hz, 200 ms, the reverb's send up
    p.alloc(BUS_SFX).tone(WAVE_SINE, 2637, 2637, 0, 1, 0.002, 0.02, 0.35).out(0.16, -0.2, 0.7, 0);
    p.alloc(BUS_SFX).tone(WAVE_SINE, 3951, 3951, 0, 1, 0.002, 0.02, 0.3).out(0.12, 0.2, 0.7, 0);
    p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.002, 0.0, 0.08)
        .filter(FILT_HP, 6000, 6000, 0, 0.7, false).out(0.08, 0, 0.5, 0);
}

export function sfxCrash(p: VoicePool, rng: Rng, speed: f32): void {
    const g = 0.6 + 0.4 * min<f32>(speed / 20, 1);
    // three thumps 90 to 160 ms apart
    let t: i32 = 0;
    for (let i = 0; i < 3; i++) {
        const v = p.alloc(BUS_SFX).tone(WAVE_SINE, 90 - 8 * <f32>i, 55, 0.03, 1, 0.002, 0.02, 0.15)
            .noiseLayer(NOISE_WHITE, 0.6, 0.002, 0.01, 0.1);
        v.filter(FILT_LP, 1800, 900, 0.05, 0.7, false).out(0.9 * g * (1 - 0.15 * <f32>i), 0.3 * rng.white(), 0.1, 0.35);
        v.delay = t;
        t += ms(90 + 70 * rng.unit());
    }
    // the snow poof: noise with a falling low-pass, 0.6 s
    p.alloc(BUS_SFX).noiseLayer(NOISE_PINK, 1, 0.01, 0.05, 0.6)
        .filter(FILT_LP, 5000, 300, 0.25, 0.7, false).out(0.75 * g, 0, 0.25, 0.3);
    // the board's clatter: a damped burst of the rail's resonators
    const c = p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.002, 0.01, 0.25)
        .filter(FILT_BP, 1371, 1371, 0, 12, false).out(0.7 * g, -0.3, 0.2, 0.35);
    c.fc2 = 2887;
    c.delay = ms(60);
}

export function sfxBail(p: VoicePool, rng: Rng): void {
    p.alloc(BUS_SFX).tone(WAVE_SINE, 85, 55, 0.03, 1, 0.002, 0.02, 0.15).out(0.8, 0, 0.1, 0.3);
    const v = p.alloc(BUS_SFX).noiseLayer(NOISE_BROWN, 1, 0.01, 0.15, 0.3)
        .filter(FILT_BP, 3800, 2500, 0.2, 1.2, false).out(0.55, 0.2 * rng.white(), 0.1, 0.6);
    v.delay = ms(40);
}

export function sfxOllieReady(p: VoicePool): void {
    // the board loaded: a short wooden creak as it flexes, and a soft ting
    p.alloc(BUS_SFX).tone(WAVE_SAW, 170, 240, 0.05, 1, 0.004, 0.02, 0.06)
        .filter(FILT_LP, 900, 900, 0, 0.7, false).out(0.22, 0, 0.05, 0.2);
    p.alloc(BUS_SFX).tone(WAVE_SINE, 2093, 2093, 0, 1, 0.002, 0.02, 0.12).out(0.09, 0, 0.4, 0);
}

export function sfxGrab(p: VoicePool): void {
    // a cloth rustle: noise band-passed at 1.2 kHz, 60 ms
    p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.008, 0.02, 0.06)
        .filter(FILT_BP, 1200, 1500, 0.04, 1.5, false).out(0.35, 0, 0.05, 0.3);
}

export function sfxSpin(p: VoicePool, dir: f32, flip: bool): void {
    // a band-passed swell, 200 ms, panned by the direction
    const f: f32 = flip ? 700 : 1100;
    const v = p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.1, 0.0, 0.12)
        .filter(FILT_BP, f, f * 1.6, 0.08, 1.4, false).out(0.42, dir * 0.6, 0.1, 0.2);
    v.rateDiv = 2;
}

export function sfxGate(p: VoicePool): void {
    // a doppler-like swoosh: a band-pass sweeping 2 kHz down to 400 Hz, 0.4 s
    const v = p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.12, 0.05, 0.3)
        .filter(FILT_BP, 2000, 400, 0.13, 2, false).out(0.5, 0, 0.15, 0.2);
    v.rateDiv = 2;
}

export function sfxGrindStart(p: VoicePool, kind: i32): void {
    if (kind == 3) {
        // wood: a knock
        p.alloc(BUS_SFX).tone(WAVE_SINE, 210, 160, 0.01, 1, 0.002, 0.01, 0.08)
            .noiseLayer(NOISE_WHITE, 0.4, 0.002, 0.005, 0.03).filter(FILT_LP, 1200, 1200, 0, 0.7, false)
            .out(0.8, 0, 0.1, 0.3);
        return;
    }
    // metal: a clank
    const f: f32 = kind == 2 ? 520 : 1371;
    const v = p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.002, 0.005, 0.3)
        .filter(FILT_BP, f, f, 0, 25, false).out(1.0, 0, 0.25, 0.35);
    v.fc2 = kind == 2 ? 860 : 2887;
    p.alloc(BUS_SFX).tone(WAVE_SINE, 120, 80, 0.02, 1, 0.002, 0.01, 0.07).out(0.5, 0, 0.05, 0.2);
}

export function sfxGrindEnd(p: VoicePool): void {
    p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.002, 0.0, 0.05)
        .filter(FILT_BP, 2600, 2600, 0, 3, false).out(0.3, 0, 0.1, 0.35);
}

export function sfxConfettiPops(p: VoicePool, rng: Rng): void {
    for (let i = 0; i < 2; i++) {
        const v = p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.002, 0.004, 0.03)
            .filter(FILT_BP, 900 + 400 * rng.unit(), 600, 0.02, 0.8, false)
            .out(0.7, i == 0 ? -0.5 : 0.5, 0.3, 0.35);
        v.delay = ms(<f32>i * (70 + 40 * rng.unit()));
    }
}

// ---- the interface (section 8) ---------------------------------------------

export function uiMove(p: VoicePool): void {
    p.alloc(BUS_UI).tone(WAVE_SQUARE, 1320, 1320, 0, 1, 0.002, 0.03, 0.03).out(0.35, 0, 0.05, 0);
}

export function uiSelect(p: VoicePool): void {
    p.alloc(BUS_UI).tone(WAVE_SQUARE, 1760, 1760, 0, 1, 0.002, 0.03, 0.03).out(0.22, 0, 0.08, 0);
    const v = p.alloc(BUS_UI).tone(WAVE_SQUARE, 2640, 2640, 0, 1, 0.002, 0.03, 0.04).out(0.22, 0, 0.08, 0);
    v.delay = ms(40);
}

export function uiBack(p: VoicePool): void {
    p.alloc(BUS_UI).tone(WAVE_SQUARE, 660, 440, 0.04, 1, 0.002, 0.04, 0.04).out(0.3, 0, 0.05, 0);
}

export function countBeep(p: VoicePool, n: i32): void {
    if (n == 0) {
        p.alloc(BUS_UI).tone(WAVE_SQUARE, 1760, 1760, 0, 1, 0.002, 0.3, 0.12).out(0.3, 0, 0.25, 0);
    } else {
        p.alloc(BUS_UI).tone(WAVE_SQUARE, 880, 880, 0, 1, 0.002, 0.09, 0.05).out(0.3, 0, 0.2, 0);
    }
}

export function tallyTick(p: VoicePool): void {
    // a cash register's key: a click and a 2 kHz tick
    p.alloc(BUS_UI).noiseLayer(NOISE_WHITE, 1, 0.002, 0.002, 0.008)
        .filter(FILT_HP, 3000, 3000, 0, 0.7, false).out(0.25, 0, 0, 0.4);
    p.alloc(BUS_UI).tone(WAVE_SQUARE, 2000, 2000, 0, 1, 0.002, 0.008, 0.02).out(0.12, 0, 0.05, 0.3);
}

export function tallyEnd(p: VoicePool): void {
    // "ka-ching": a bell (2,093, 2,637, 3,136 Hz) with a fast decay and a slow tail
    const f0: f32 = 2093;
    const f1: f32 = 2637;
    const f2: f32 = 3136;
    p.alloc(BUS_UI).tone(WAVE_SINE, f0, f0, 0, 1, 0.002, 0.0, 0.25).out(0.12, -0.2, 0.4, 0);
    p.alloc(BUS_UI).tone(WAVE_SINE, f1, f1, 0, 1, 0.002, 0.0, 0.2).out(0.11, 0, 0.4, 0);
    p.alloc(BUS_UI).tone(WAVE_SINE, f2, f2, 0, 1, 0.002, 0.0, 0.18).out(0.1, 0.2, 0.4, 0);
    p.alloc(BUS_UI).tone(WAVE_SINE, f0, f0, 0, 1, 0.002, 0.0, 1.6).out(0.06, -0.1, 0.4, 0);
    p.alloc(BUS_UI).tone(WAVE_SINE, f1, f1, 0, 1, 0.002, 0.0, 1.4).out(0.05, 0.1, 0.4, 0);
    // the rattle: a drawer of coins
    p.alloc(BUS_UI).noiseLayer(NOISE_WHITE, 1, 0.002, 0.05, 0.15)
        .filter(FILT_BP, 5000, 4000, 0.1, 2, false).out(0.25, 0, 0.2, 0.5);
    const k = p.alloc(BUS_UI).noiseLayer(NOISE_WHITE, 1, 0.002, 0.002, 0.01)
        .filter(FILT_HP, 3000, 3000, 0, 0.7, false).out(0.3, 0, 0, 0.4);
    k.delay = 0;
}

export function gradeStamp(p: VoicePool): void {
    // a boom (55 Hz, 0.5 s), a noise burst, the reverb's send high
    p.alloc(BUS_UI).tone(WAVE_SINE, 80, 55, 0.04, 1, 0.002, 0.05, 0.6).out(1.0, 0, 0.3, 0);
    p.alloc(BUS_UI).noiseLayer(NOISE_WHITE, 1, 0.002, 0.01, 0.2)
        .filter(FILT_LP, 6000, 800, 0.08, 0.7, false).out(0.6, 0, 0.8, 0.35);
    p.alloc(BUS_UI).tone(WAVE_TRI, 180, 120, 0.05, 1, 0.002, 0.01, 0.12).out(0.4, 0, 0.3, 0.3);
}

export function startJingle(p: VoicePool): void {
    // Start pressed: an upward three-blip
    for (let i = 0; i < 3; i++) {
        const f: f32 = i == 0 ? 880 : (i == 1 ? 1320 : 1760);
        const v = p.alloc(BUS_UI).tone(WAVE_SQUARE, f, f, 0, 1, 0.002, 0.04, 0.06).out(0.2, 0, 0.15, 0);
        v.delay = ms(<f32>i * 60);
    }
}

export function restartWhoosh(p: VoicePool): void {
    const v = p.alloc(BUS_SFX).noiseLayer(NOISE_WHITE, 1, 0.05, 0.05, 0.2)
        .filter(FILT_BP, 600, 3000, 0.1, 1.5, false).out(0.35, 0, 0.2, 0);
    v.rateDiv = 2;
}

// a metallic clank (the 808's cymbal squares, high-passed): the board's edge on a rail
export function sfxClank(p: VoicePool): void {
    p.alloc(BUS_SFX).tone(WAVE_METAL, 420, 420, 0, 1, 0.002, 0.0, 0.2)
        .filter(FILT_HP, 3000, 3000, 0, 0.7, true).out(0.2, 0, 0.2, 0.3);
}
