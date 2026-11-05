// What crosses between the main lane (sound.as, sound_core.as) and the
// Spu processor (spu.as): the knobs (a Snapshot, every frame), the cues (a
// Ring, as things happen) and the meter (a Snapshot, every block).
// docs/AUDIO.md, section 2.
import { Ring, Snapshot } from "rive/shared";

// ---- the music's states (docs/AUDIO.md, section 5) --------------------------
export const MUS_SILENT: i32 = 0;
export const MUS_TITLE: i32 = 1;
export const MUS_START: i32 = 2;
export const MUS_COUNTDOWN: i32 = 3;
export const MUS_WARMUP: i32 = 4;
export const MUS_KICKERS: i32 = 5;
export const MUS_RAILS: i32 = 6;
export const MUS_SPLIT: i32 = 7;
export const MUS_MEGA_RISER: i32 = 8;
export const MUS_MEGA_AIR: i32 = 9;
export const MUS_MEGA_DROP: i32 = 10;
export const MUS_FINISH: i32 = 11;
export const MUS_RESULTS: i32 = 12;
export const MUS_WAIT: i32 = 13;      // after a restart's tape-stop, until GO

// ---- cues -------------------------------------------------------------------
export const CUE_OLLIE: i32 = 1;        // a: pop speed
export const CUE_LAND: i32 = 2;         // a: impact (m/s), b: LAND_*
export const CUE_PERFECT: i32 = 3;
export const CUE_CRASH: i32 = 4;        // a: speed
export const CUE_BAIL: i32 = 5;
export const CUE_GRIND_START: i32 = 6;  // a: GRIND_*
export const CUE_GRIND_END: i32 = 7;
export const CUE_SPIN: i32 = 8;         // a: +1 left, -1 right; b: 1 flip
export const CUE_GRAB: i32 = 9;
export const CUE_SAY: i32 = 10;         // a: line id, b: priority, c: packed trick, d: delay (s)
export const CUE_COUNT: i32 = 11;       // a: 3, 2, 1, 0 GO, 10 READY
export const CUE_UI_MOVE: i32 = 12;
export const CUE_UI_SELECT: i32 = 13;
export const CUE_UI_BACK: i32 = 14;
export const CUE_TALLY_TICK: i32 = 15;
export const CUE_TALLY_END: i32 = 16;
export const CUE_GRADE: i32 = 17;       // a: grade
export const CUE_RESTART: i32 = 18;
export const CUE_CONFETTI: i32 = 19;
export const CUE_GATE: i32 = 20;
export const CUE_CHEER: i32 = 21;       // a: strength 0..1
export const CUE_MUSIC_CRASH: i32 = 22; // the crash duck
export const CUE_START: i32 = 23;       // the title's Start
export const CUE_SHUT_UP: i32 = 24;     // the announcer stops and forgets its queue
export const CUE_TEST: i32 = 25;        // a: instrument id (tests and the review bank), b: note, c: velocity
export const CUE_OLLIE_READY: i32 = 26; // the ollie's crouch fully loaded

// ---- the announcer's lines (the captions' ids: RIVE.md, section 5) -----------
export const LINE_THREE: i32 = 0;
export const LINE_TWO: i32 = 1;
export const LINE_ONE: i32 = 2;
export const LINE_GO: i32 = 3;
export const LINE_READY: i32 = 4;
export const LINE_NICE: i32 = 5;
export const LINE_SICK: i32 = 6;
export const LINE_RADICAL: i32 = 7;
export const LINE_INSANE: i32 = 8;
export const LINE_UNREAL: i32 = 9;
export const LINE_PERFECT: i32 = 10;
export const LINE_SKETCHY: i32 = 11;
export const LINE_OUCH: i32 = 12;
export const LINE_WIPEOUT: i32 = 13;
export const LINE_BAIL: i32 = 14;
export const LINE_HIGH_LINE: i32 = 15;
export const LINE_LOW_LINE: i32 = 16;
export const LINE_FINAL_JUMP: i32 = 17;
export const LINE_AWESOME: i32 = 18;
export const LINE_S_RANK: i32 = 19;
export const LINE_A_RANK: i32 = 20;
export const LINE_B_RANK: i32 = 21;
export const LINE_C_RANK: i32 = 22;
export const LINE_NEW_RECORD: i32 = 23;
export const LINE_COMBO: i32 = 24;
// the alternates (never the same praise twice in a row: AUDIO.md, section 6)
export const LINE_YEAH: i32 = 25;
export const LINE_SWEET: i32 = 26;
export const LINE_NASTY: i32 = 27;
export const LINE_GNARLY: i32 = 28;
export const LINE_BIG_AIR: i32 = 29;
export const LINE_TITLE: i32 = 30;      // "AVALANCHE AIR!" (the title's Start)
export const LINE_FIXED_COUNT: i32 = 31;
export const LINE_TRICK: i32 = 100;     // the trick name, from the packed trick

// A trick packed in an f32 (exact under 2^24): spin / 180 (0..15), dir
// (0..3), flip (0..7), grab1 (0..7), grab2 (0..7), switch (0..1), grind (0..31).
export function packTrick(spin: i32, dir: i32, flip: i32, g1: i32, g2: i32, sw: bool, grind: i32): f32 {
    let v: i32 = (spin / 180) & 15;
    v |= (dir & 3) << 4;
    v |= (flip & 7) << 6;
    v |= (g1 & 7) << 9;
    v |= (g2 & 7) << 12;
    v |= (sw ? 1 : 0) << 15;
    v |= (grind & 31) << 16;
    return <f32>v;
}

export class Cue {
    kind: i32 = 0;
    a: f32 = 0;
    b: f32 = 0;
    c: f32 = 0;
    d: f32 = 0;
}

export class Knobs {
    speed: f32 = 0;         // m/s
    carve: f32 = 0;         // 0..1
    skid: f32 = 0;          // 0..1
    surface: i32 = 0;       // SURF_*
    tuck: f32 = 0;          // 0..1
    air: f32 = 0;           // 0 or 1
    airTime: f32 = 0;       // s
    spinRate: f32 = 0;      // degrees a second
    flipRate: f32 = 0;
    grind: i32 = 0;         // GRIND_*
    grindSpeed: f32 = 0;    // m/s
    balance: f32 = 0;       // -1..1
    progress: f32 = 0;      // 0..1
    onCourse: f32 = 0;      // 1 while the board's layers play
    crowd: f32 = 0;         // 0..1, the crowd's level by the distance to an arch
    music: i32 = 0;         // MUS_*
    paused: f32 = 0;        // 0 or 1
    musicVolume: f32 = 0.8;
    sfxVolume: f32 = 0.9;
    voiceVolume: f32 = 1.0;
    mute: f32 = 0;          // 0 or 1
    seed: f32 = 1;          // the run's seed
}

export class Meter {
    bar: i32 = 0;           // bars played since the processor started
    beat: i32 = 0;          // beats played since the processor started
    step: i32 = 0;          // the 16th in the bar, 0..15
    speaking: i32 = -1;     // the line being spoken, -1 none
    lineSeq: i32 = 0;       // +1 per line started
    musicState: i32 = 0;    // the state the music plays now
    musicLevel: f32 = 0;    // peak of the music bus over the block
    masterLevel: f32 = 0;   // peak of the output over the block
    voices: i32 = 0;        // pooled voices sounding
    frames: f64 = 0;        // output frames rendered
    speechPeak: f32 = 0;    // the voice's peak before the PA (for tuning)
}

export class SpuInputs {
    knobs: Snapshot<Knobs> = Snapshot.create<Knobs>(1024);
    cues: Ring<Cue> = Ring.create<Cue>(8192);
    meter: Snapshot<Meter> = Snapshot.create<Meter>(512);
}

// The main lane's side of the cue ring: one scratch cue, no allocation.
export class CueSender {
    ring: Ring<Cue>;
    scratch: Cue = new Cue();
    dropped: i32 = 0;

    constructor(ring: Ring<Cue>) {
        this.ring = ring;
    }

    send(kind: i32, a: f32 = 0, b: f32 = 0, c: f32 = 0, d: f32 = 0): void {
        const q = this.scratch;
        q.kind = kind;
        q.a = a;
        q.b = b;
        q.c = c;
        q.d = d;
        if (!this.ring.send(q)) this.dropped++;
    }
}
