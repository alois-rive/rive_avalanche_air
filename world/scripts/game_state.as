// The game's shared state: the contract between the world's scripts
// (docs/IMPLEMENTATION.md, "Contracts"). One module global, `game`, that
// every script of the run scene reads and the owners write:
//
//   run.as, rider.as, tricks.as (gameplay)  write game.rider, game.trick,
//                                           the phase, the score, the events
//   sound.as (audio)                        reads everything, writes game.audio
//   run.as                                  writes the pins from all of it
//
// Units: metres, seconds, radians; Y up; the course runs down -Z from the
// start gate at the origin, +X to the rider's right going down.
//
// Nothing here allocates after the module loads.

// ---- phases (docs/SPEC.md, section 2) --------------------------------------
export const PHASE_TITLE: i32 = 0;
export const PHASE_COUNTDOWN: i32 = 1;
export const PHASE_QUICKSTART: i32 = 2;
export const PHASE_RIDING: i32 = 3;
export const PHASE_CRASH: i32 = 4;
export const PHASE_FINISH: i32 = 5;
export const PHASE_RESULTS: i32 = 6;
export const PHASE_INITIALS: i32 = 7;

// ---- surfaces, grinds, grabs, flips, praise --------------------------------
export const SURF_GROOMED: i32 = 0;
export const SURF_POWDER: i32 = 1;
export const SURF_ICE: i32 = 2;
export const SURF_ROCK: i32 = 3;

export const GRIND_NONE: i32 = 0;
export const GRIND_RAIL: i32 = 1;
export const GRIND_BOX: i32 = 2;
export const GRIND_LOG: i32 = 3;

export const GRAB_NONE: i32 = 0;
export const GRAB_INDY: i32 = 1;
export const GRAB_MELON: i32 = 2;
export const GRAB_METHOD: i32 = 3;
export const GRAB_MUTE: i32 = 4;

export const FLIP_NONE: i32 = 0;
export const FLIP_FRONT: i32 = 1;
export const FLIP_BACK: i32 = 2;
export const FLIP_DOUBLE_FRONT: i32 = 3;
export const FLIP_DOUBLE_BACK: i32 = 4;

export const PRAISE_NONE: i32 = 0;
export const PRAISE_NICE: i32 = 1;
export const PRAISE_SICK: i32 = 2;
export const PRAISE_RADICAL: i32 = 3;
export const PRAISE_INSANE: i32 = 4;
export const PRAISE_UNREAL: i32 = 5;
export const PRAISE_SKETCHY: i32 = 6;
export const PRAISE_OUCH: i32 = 7;
export const PRAISE_WIPEOUT: i32 = 8;
export const PRAISE_BAIL: i32 = 9;

export const LAND_PERFECT: i32 = 0;
export const LAND_CLEAN: i32 = 1;
export const LAND_SKETCHY: i32 = 2;

// ---- events (a ring every consumer reads with its own cursor) ---------------
// Each event: a kind and two numbers. Consumers (sound.as, run.as's pins)
// keep their own read position, so the order the scripts run in does not
// matter and nothing is cleared.
export const EV_OLLIE: i32 = 1;        // a: pop speed (m/s)
export const EV_LAND: i32 = 2;         // a: impact (m/s), b: LAND_*
export const EV_CRASH: i32 = 3;        // a: speed before the crash
export const EV_BAIL: i32 = 4;
export const EV_GRIND_START: i32 = 5;  // a: GRIND_*
export const EV_GRIND_END: i32 = 6;
export const EV_SPIN_HALF: i32 = 7;    // a: +1 left, -1 right; b: flip (1) or spin (0)
export const EV_GRAB: i32 = 8;         // a: GRAB_*
export const EV_BANK: i32 = 9;         // a: banked value, b: PRAISE_* (game.trick holds the last trick)
export const EV_COUNT: i32 = 10;       // a: 3, 2, 1, 0 (GO), 10 (READY)
export const EV_FINISH: i32 = 11;
export const EV_RESTART: i32 = 12;
export const EV_UI_MOVE: i32 = 13;
export const EV_UI_SELECT: i32 = 14;
export const EV_UI_BACK: i32 = 15;
export const EV_TALLY_TICK: i32 = 16;
export const EV_TALLY_END: i32 = 17;
export const EV_GRADE: i32 = 18;       // a: 0 C .. 3 S; b: 1 when a new record
export const EV_GATE: i32 = 19;        // an arch passed
export const EV_CONFETTI: i32 = 20;
export const EV_PERFECT: i32 = 21;
export const EV_SECTION: i32 = 22;     // a: the section entered (1..7)
export const EV_LINE: i32 = 23;        // a: 1 the high line, 0 the low line, as the rider commits
export const EV_MEGA_TAKEOFF: i32 = 24;
export const EV_START: i32 = 25;       // the title's Start
export const EV_TRICK: i32 = 26;       // a trick completed inside a combo (game.trick holds it)
// (appended by the gameplay)
export const EV_RESPAWN: i32 = 27;     // the rider stands again after a crash (a: s), control 0.1 s later

export const EVENT_RING: i32 = 256;

export class EventRing {
    kinds: StaticArray<i32> = new StaticArray<i32>(EVENT_RING);
    a: StaticArray<f32> = new StaticArray<f32>(EVENT_RING);
    b: StaticArray<f32> = new StaticArray<f32>(EVENT_RING);
    // how many events were ever pushed; event n is at n % EVENT_RING
    written: i32 = 0;

    push(kind: i32, a: f32 = 0, b: f32 = 0): void {
        const i = this.written % EVENT_RING;
        this.kinds[i] = kind;
        this.a[i] = a;
        this.b[i] = b;
        this.written++;
    }
}

// ---- the rider, as everyone else sees it ------------------------------------
export class RiderState {
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;
    vx: f32 = 0;
    vy: f32 = 0;
    vz: f32 = 0;
    speed: f32 = 0;          // m/s
    heading: f32 = 0;        // radians; 0 faces -Z (down the course), positive turns left
    onGround: bool = true;
    inAir: bool = false;
    grind: i32 = GRIND_NONE;
    tumbling: bool = false;
    tuck: f32 = 0;           // 0..1
    crouch: f32 = 0;         // 0..1
    carve: f32 = 0;          // 0..1, lateral demand over the grip limit's scale
    skid: f32 = 0;           // 0..1
    lean: f32 = 0;           // -1 heel .. +1 toe, for the poses
    surface: i32 = SURF_GROOMED;
    airTime: f32 = 0;        // seconds since take-off
    spinRate: f32 = 0;       // degrees a second
    flipRate: f32 = 0;
    balance: f32 = 0;        // -1..1 on a rail
    grab: i32 = GRAB_NONE;
    switchStance: bool = false;
    s: f32 = 0;              // progress, metres along the main line
    section: i32 = 1;
    highLine: bool = false;
    finished: bool = false;
}

// ---- the trick being done or last done (docs/TRICKS.md, section 2) ----------
export class TrickName {
    spin: i32 = 0;           // degrees, a multiple of 180
    dir: i32 = 0;            // 0 none, 1 frontside, 2 backside
    flip: i32 = FLIP_NONE;
    grab1: i32 = GRAB_NONE;
    grab2: i32 = GRAB_NONE;
    switchStance: bool = false;
    grind: i32 = 0;          // 0 none, 1 50-50, 2 boardslide, 3 log slide; +10 kinked, +20 rainbow
    live: bool = false;
    points: f32 = 0;

    clear(): void {
        this.spin = 0;
        this.dir = 0;
        this.flip = FLIP_NONE;
        this.grab1 = GRAB_NONE;
        this.grab2 = GRAB_NONE;
        this.switchStance = false;
        this.grind = 0;
        this.live = false;
        this.points = 0;
    }
}

// ---- results and the table ---------------------------------------------------
export class Results {
    tricks: f32 = 0;
    grinds: f32 = 0;
    comboBonus: f32 = 0;
    landings: f32 = 0;
    timeBonus: f32 = 0;
    total: f32 = 0;
    bestCombo: f32 = 0;
    longestAir: f32 = 0;
    perfects: i32 = 0;
    crashes: i32 = 0;
    grade: i32 = -1;
    rank: i32 = 0;
}

export const TABLE_SIZE: i32 = 10;

// Initials: three characters, each 0..37 (0 space, 1..26 A..Z, 27..36 0..9,
// 37 "!"), packed as c0 * 4096 + c1 * 64 + c2 (exact in an f32).
export function packInitials(c0: i32, c1: i32, c2: i32): f32 {
    return <f32>(c0 * 4096 + c1 * 64 + c2);
}

// A table row's tag: the initials, the grade (0..3) and the line (0 low,
// 1 high): initials * 8 + grade * 2 + line (under 2^24: exact in an f32).
export function packTag(initials: f32, grade: i32, line: i32): f32 {
    return initials * 8 + <f32>(grade * 2 + line);
}

export class Table {
    scores: StaticArray<f32> = new StaticArray<f32>(TABLE_SIZE);
    tags: StaticArray<f32> = new StaticArray<f32>(TABLE_SIZE);
}

// ---- settings (from the pins) -----------------------------------------------
export class Settings {
    musicVolume: f32 = 0.8;
    sfxVolume: f32 = 0.9;
    voiceVolume: f32 = 1.0;
    mute: bool = false;
    reducedMotion: bool = false;
    landingAssist: bool = true;
    grindAssist: bool = false;
    ghost: bool = false;
    paused: bool = false;
    demo: bool = false;
    scheme: i32 = 0;
}

// ---- what the audio reports back (written by sound.as) ----------------------
export class AudioReport {
    beat: i32 = 0;
    bar: i32 = 0;
    speakingLine: i32 = -1;  // the announcer's current line id, -1 none
    lineSeq: i32 = 0;        // +1 per line spoken
    failed: bool = false;    // the processor could not start (a threadless web page)
}

export class Game {
    phase: i32 = PHASE_TITLE;
    seed: u32 = 1;
    time: f32 = 0;           // the run's clock, from GO
    score: f32 = 0;
    comboSum: f32 = 0;
    comboMult: i32 = 0;
    comboActive: bool = false;
    countdown: i32 = -1;
    rider: RiderState = new RiderState();
    trick: TrickName = new TrickName();
    events: EventRing = new EventRing();
    results: Results = new Results();
    table: Table = new Table();
    settings: Settings = new Settings();
    audio: AudioReport = new AudioReport();
}

export const game: Game = new Game();
