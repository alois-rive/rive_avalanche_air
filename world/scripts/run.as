// The run's driver (docs/SPEC.md, section 2; RIDER.md, sections 1, 9, 10
// and 13; TRICKS.md), on run.rscn's root: the fixed 120 Hz clock, the
// phases (title and its attract, countdown, quick start, riding, crash,
// finish, results with the tally, initials), the input (keys from the
// Scene3D's _input, the pad from the in-pins, or the autopilot), the
// rider and its scoring, the drawn rider and the cameras' view, and every
// pin of tools/pins.py: the `out` pins written from `game` when they
// change (a number in the pin node's position.x, a boolean in its
// visible), the `in` pins read each frame (commands are counters: a new
// value is the command, the kart's pattern).
//
// Keys work alone too (SPEC.md, section 14, case 9): at the title Enter or
// Space starts, R restarts during a run, the finish or the results, and
// the initials are entered with the arrows, typed letters and Enter, so a
// keyboard completes every screen even before the Rive side's menus.
//
// Exported for the tests and the tools: `printEvery` prints the rider's
// state every that many frames.
//
// Nothing allocates per frame once the first frame has run.
import { InputEvent, NodeScript, SceneNode, ScriptScene, Vec3, print } from "hedra_engine/script";
import { FINISH_S, LinePoint, featureCount, feature, Feature, FEAT_KICKER, lineSample } from "./course_api";
import {
    EV_CONFETTI, EV_COUNT, EV_FINISH, EV_GATE, EV_GRADE, EV_RESTART, EV_START, EV_TALLY_END, EV_TALLY_TICK,
    EV_UI_BACK, EV_UI_MOVE, EV_UI_SELECT, PHASE_COUNTDOWN, PHASE_CRASH, PHASE_FINISH, PHASE_INITIALS,
    PHASE_QUICKSTART, PHASE_RESULTS, PHASE_RIDING, PHASE_TITLE, TABLE_SIZE, game, packInitials, packTag,
} from "./game_state";
import { Autopilot } from "./autopilot";
import { Controls, Input } from "./input";
import { DrawnPose, FixedClock } from "./lib/kinematic";
import { RiderView } from "./lib/rider_view";
import { CAM_CHASE, CAM_CRASH, CAM_FINISH, CAM_GATE, CAM_TITLE, view } from "./lib/view";
import {
    PIN_AUTOPILOT, PIN_BAIL_SEQ, PIN_BALANCE, PIN_BANK_SEQ, PIN_BEAT, PIN_CAPTION_LINE, PIN_CAPTION_SEQ,
    PIN_COMBO_ACTIVE, PIN_COMBO_MULT, PIN_COMBO_SUM, PIN_COUNT, PIN_COUNTDOWN, PIN_CRASH_SEQ, PIN_DEMO, PIN_DEVICE,
    PIN_GHOST, PIN_GHOST_DELTA, PIN_GRINDING, PIN_GRIND_ASSIST, PIN_HS1_SCORE, PIN_HS1_TAG, PIN_INITIALS_CODE,
    PIN_INITIALS_CURSOR, PIN_INITIALS_DONE_SEQ, PIN_INITIALS_IN, PIN_IS_BOOL, PIN_LANDING_ASSIST, PIN_LINE_HIGH,
    PIN_MUSIC_VOLUME, PIN_MUTE, PIN_PAD_BUTTONS, PIN_PAD_X, PIN_PAD_Y, PIN_PATHS, PIN_PAUSED, PIN_PERFECT_SEQ,
    PIN_PHASE, PIN_PRAISE, PIN_PROGRESS, PIN_QUIT_SEQ, PIN_REDUCED_MOTION, PIN_RESTART_SEQ, PIN_RES_BEST_COMBO,
    PIN_RES_COMBO_BONUS, PIN_RES_CRASHES, PIN_RES_GRADE, PIN_RES_GRINDS, PIN_RES_LANDINGS, PIN_RES_LONGEST_AIR,
    PIN_RES_PERFECTS, PIN_RES_RANK, PIN_RES_STEP, PIN_RES_TIME_BONUS, PIN_RES_TOTAL, PIN_RES_TRICKS, PIN_SCHEME,
    PIN_SCORE, PIN_SECTION, PIN_SEED, PIN_SFX_VOLUME, PIN_SPEED_KMH, PIN_START_SEQ, PIN_TIME, PIN_TRICK_DIR,
    PIN_TRICK_FLIP, PIN_TRICK_GRAB1, PIN_TRICK_GRAB2, PIN_TRICK_GRIND, PIN_TRICK_LIVE, PIN_TRICK_POINTS,
    PIN_TRICK_SEQ, PIN_TRICK_SPIN, PIN_TRICK_SWITCH, PIN_UI_BACK_SEQ, PIN_UI_MOVE_SEQ, PIN_UI_SELECT_SEQ,
    PIN_VOICE_VOLUME,
} from "./pins_data";
import { MODE_AIR, MODE_GRIND, MODE_TUMBLE, RESPAWN_AT, Rider } from "./rider";
import { Tricks, insertRow, rankOf, seedTable } from "./tricks";

const TICK: f32 = <f32>(1.0 / 120.0);
const COUNT_STEP: f32 = 1.0;          // 3, 2, 1, GO a second apart
const QUICK_GO: f32 = 1.0;            // READY ... GO
const GO_SHOWN: f32 = 0.6;            // GO stays this long
const FINISH_TIME: f32 = 2.0;
const TALLY_LINES: i32 = 5;           // tricks, grinds, combo bonus, landings, time bonus
const TALLY_GAP: f32 = 0.35;
const TALLY_COUNT: f32 = 0.5;         // each line counts up in this
const TALLY_TICK: f32 = <f32>(60.0 / 170.0 / 4.0);   // a 16th at 170 BPM
const STAMP_DELAY: f32 = 0.5;
const INITIALS_DELAY: f32 = 1.2;
const DEMO_LOOP: f32 = 30;
const ATTRACT_MAX: f32 = 120;
const RESTART_DEBOUNCE: i32 = 12;     // frames a key restart ignores the view model's echo
const LETTERS: i32 = 38;
const STUCK_TIME: f32 = 8;
const PUSH_OFF: f32 = 5;              // m/s out of the start gate at GO            // seconds without 3 m of progress: stood again further on

export class Run extends NodeScript {
    printEvery: i32 = 0;

    private began: bool = false;
    private frame: i32 = 0;
    private clock: FixedClock = new FixedClock(TICK, 6);
    private controls: Controls = new Controls();
    private inp: Input = new Input();
    private tricks: Tricks = new Tricks();
    private rider: Rider;
    private pilot: Autopilot = new Autopilot();
    private drawn: DrawnPose = new DrawnPose();
    private riderView: RiderView = new RiderView();
    private anchor: SceneNode? = null;
    private pins: Array<SceneNode?> = [];
    private lp: LinePoint = new LinePoint();
    // the phase
    private phase: i32 = PHASE_TITLE;
    private phaseTime: f32 = 0;
    private countShown: i32 = -1;
    private goTime: f32 = -1;
    private piloted: bool = false;      // the autopilot drives the player's rider
    private demo: bool = false;
    private demoStart: f32 = 0;
    // the commands last seen
    private seenStart: f32 = 0;
    private seenRestart: f32 = 0;
    private seenQuit: f32 = 0;
    private seenDone: f32 = 0;
    private seenInitials: f32 = 0;
    private seenMove: f32 = 0;
    private seenSelect: f32 = 0;
    private seenBack: f32 = 0;
    private keyRestartFrame: i32 = -100;
    private stuckBest: f32 = 0;
    private stuckTime: f32 = 0;
    // the results
    private resStep: i32 = 0;
    private resShown: StaticArray<f32> = new StaticArray<f32>(TALLY_LINES + 1);
    private tallyNext: f32 = 0;
    private stamped: bool = false;
    private entered: bool = false;
    private stampTime: f32 = 0;
    private tallyEnd: bool = false;
    private initials: StaticArray<i32> = [1, 1, 1];
    private cursor: i32 = 0;
    private lastInitials: StaticArray<i32> = [1, 1, 1];
    // restart timing (the press to the first tick with input: TESTS.md, case 5)
    private restartFrame: i32 = -1;
    lastRestartFrames: i32 = -1;

    constructor() {
        super();
        this.rider = new Rider(this.tricks);
    }

    override _ready(): void {
        for (let i = 0; i < PIN_COUNT; i++) this.pins.push(this.getNode(PIN_PATHS[i]));
        this.anchor = this.getNode("LowRes/RiderAnchor");
        const root = this.getNode("LowRes/Rider");
        let scene: ScriptScene? = null;
        if (root != null) {
            const body = root.getNode("Body");
            const host = this.tree.host;
            if (host != null && body != null) scene = host.sceneOf(body);
        }
        this.riderView.bind(root, scene);
        seedTable(game.table);
    }

    // The first frame: the view model's settings decide how the session
    // starts (the autopilot or the demo from the first frame start a run at
    // once; otherwise the title's attract).
    private begin(): void {
        this.began = true;
        // (the commands' counters start at the view model's defaults, 0: a
        // count already set on the first frame, as `--data` sets it, is a
        // command)
        this.readSettings();
        this.demo = this.flag(PIN_DEMO);
        const auto = <i32>this.num(PIN_AUTOPILOT);
        if (this.demo) {
            this.startDemo();
        } else if (auto > 0) {
            this.piloted = true;
            this.newRun(false);
            this.go();
        } else {
            this.toTitle();
        }
    }

    override _input(e: InputEvent): void {
        if (this.demo) return;
        if (this.controls.take(e)) e.handled = true;
    }

    override _process(delta: f32): void {
        if (!this.began) this.begin();
        this.rider.log = this.printEvery > 0;
        this.tricks.log = this.printEvery > 0;
        this.frame++;
        this.readSettings();
        this.commands();
        const paused = game.settings.paused;
        if (!paused) {
            const n = this.clock.advance(delta);
            for (let i = 0; i < n; i++) this.tick();
        }
        this.draw(paused ? 0 : delta);
        this.writePins();
        this.controls.takePresses();
        if (this.printEvery > 0 && this.frame % this.printEvery == 0) this.printState();
    }

    // ---- settings and commands ------------------------------------------------------

    private readSettings(): void {
        const s = game.settings;
        s.musicVolume = this.num(PIN_MUSIC_VOLUME);
        s.sfxVolume = this.num(PIN_SFX_VOLUME);
        s.voiceVolume = this.num(PIN_VOICE_VOLUME);
        s.mute = this.flag(PIN_MUTE);
        s.reducedMotion = this.flag(PIN_REDUCED_MOTION);
        s.landingAssist = this.flag(PIN_LANDING_ASSIST);
        s.grindAssist = this.flag(PIN_GRIND_ASSIST);
        s.ghost = this.flag(PIN_GHOST);
        s.paused = this.flag(PIN_PAUSED);
        s.demo = this.demo;
        const sc = <i32>this.num(PIN_SCHEME);
        s.scheme = sc < 0 ? 0 : (sc > 2 ? 2 : sc);
        this.rider.landingAssist = s.landingAssist;
        this.rider.grind.assist = s.grindAssist;
        view.reducedMotion = s.reducedMotion;
        if (!this.demo) this.controls.setPad(this.num(PIN_PAD_X), this.num(PIN_PAD_Y), <i32>this.num(PIN_PAD_BUTTONS));
    }

    private commands(): void {
        const c = this.controls;
        // the menus' sounds, relayed to the audio as events
        const move = this.num(PIN_UI_MOVE_SEQ);
        if (move != this.seenMove) {
            this.seenMove = move;
            game.events.push(EV_UI_MOVE);
        }
        const select = this.num(PIN_UI_SELECT_SEQ);
        if (select != this.seenSelect) {
            this.seenSelect = select;
            game.events.push(EV_UI_SELECT);
        }
        const back = this.num(PIN_UI_BACK_SEQ);
        if (back != this.seenBack) {
            this.seenBack = back;
            game.events.push(EV_UI_BACK);
        }
        if (this.demo) return;
        const quit = this.num(PIN_QUIT_SEQ);
        if (quit != this.seenQuit) {
            this.seenQuit = quit;
            this.toTitle();
            return;
        }
        const start = this.num(PIN_START_SEQ);
        const startCmd = start != this.seenStart;
        this.seenStart = start;
        const restart = this.num(PIN_RESTART_SEQ);
        let restartCmd = restart != this.seenRestart;
        this.seenRestart = restart;
        // a key's restart, and the view model's echo of the same press
        if (restartCmd && this.frame - this.keyRestartFrame < RESTART_DEBOUNCE) restartCmd = false;
        const p = this.phase;
        if (p == PHASE_TITLE) {
            if (startCmd || restartCmd || c.confirmPressed || c.restartPressed) {
                game.events.push(EV_START);
                this.newRun(true);
            }
            return;
        }
        if (p == PHASE_INITIALS) {
            this.initialsInput();
            return;
        }
        if (c.restartPressed) {
            this.keyRestartFrame = this.frame;
            restartCmd = true;
        }
        // Start, or Enter once the grade is stamped, rides again from the results
        if (p == PHASE_RESULTS && (startCmd || (c.confirmPressed && this.stamped))) restartCmd = true;
        if (restartCmd) this.restart();
    }

    // ---- phases --------------------------------------------------------------------

    private setPhase(p: i32): void {
        this.phase = p;
        this.phaseTime = 0;
        game.phase = p;
    }

    private toTitle(): void {
        this.setPhase(PHASE_TITLE);
        this.piloted = false;
        this.newRunState(game.seed);
        this.pilot.reference = true;
        this.pilot.setup(true);
        this.pilot.reset();
        game.countdown = -1;
        this.countShown = -1;
        view.cut = true;
    }

    private startDemo(): void {
        this.piloted = true;
        // the kicker section onwards (the first kicker, 40 m before it)
        let s: f32 = 0;
        const f = new Feature();
        for (let i = 0; i < featureCount(); i++) {
            feature(i, f);
            if (f.kind == FEAT_KICKER) {
                s = f.s - 40;
                break;
            }
        }
        this.demoStart = s < 0 ? 0 : s;
        this.demoLoop();
    }

    private demoLoop(): void {
        this.newRunState(1);
        this.pilot.reference = true;
        this.pilot.setup(true);
        this.rider.placeAt(this.demoStart, false, 14);
        this.drawn.set(this.rider.x, this.rider.y, this.rider.z, this.rider.q.x, this.rider.q.y, this.rider.q.z, this.rider.q.w);
        this.drawn.snap();
        this.setPhase(PHASE_RIDING);
        game.countdown = -1;
        view.cut = true;
    }

    // Everything of a run cleared, the rider at the gate (nothing reloaded).
    private newRunState(seed: u32): void {
        game.seed = seed;
        game.time = 0;
        this.stuckBest = 0;
        this.stuckTime = 0;
        this.tricks.reset();
        this.rider.reset(<u64>seed);
        this.pilot.reset();
        this.controls.clear();
        this.inp.clear();
        this.clock.reset();
        this.drawn.set(this.rider.x, this.rider.y, this.rider.z, this.rider.q.x, this.rider.q.y, this.rider.q.z, this.rider.q.w);
        this.drawn.snap();
        this.riderView.snap();
        this.riderView.celebrate = false;
        this.goTime = -1;
        this.resStep = 0;
        this.stamped = false;
        this.tallyEnd = false;
        const r = game.results;
        r.tricks = 0;
        r.grinds = 0;
        r.comboBonus = 0;
        r.landings = 0;
        r.timeBonus = 0;
        r.total = 0;
        r.bestCombo = 0;
        r.longestAir = 0;
        r.perfects = 0;
        r.crashes = 0;
        r.grade = -1;
        r.rank = 0;
        for (let i = 0; i <= TALLY_LINES; i++) this.resShown[i] = 0;
        this.rider.publish();
        view.cut = true;
    }

    // A new run from the title (`countdown`: 3, 2, 1, GO) or a restart
    // (the quick start: READY, GO).
    private newRun(countdown: bool): void {
        const sd = <i32>this.num(PIN_SEED);
        this.newRunState(<u32>(sd > 0 ? sd : 1));
        const auto = <i32>this.num(PIN_AUTOPILOT);
        if (auto > 0) {
            this.piloted = true;
            this.pilot.reference = true;
            this.pilot.setup(auto == 2);
        } else {
            this.piloted = false;
        }
        this.countShown = -1;
        if (countdown) {
            this.setPhase(PHASE_COUNTDOWN);
        } else {
            this.setPhase(PHASE_QUICKSTART);
        }
    }

    private restart(): void {
        game.events.push(EV_RESTART);
        this.restartFrame = this.frame;
        this.newRun(false);
    }

    // GO: the clock runs, the rider is the player's.
    private go(): void {
        this.setPhase(PHASE_RIDING);
        game.countdown = 0;
        this.goTime = 0;
        game.events.push(EV_COUNT, 0);
        game.events.push(EV_GATE, 0);
        if (this.rider.s < 1) this.rider.pushOff(PUSH_OFF);
        if (this.piloted) {
            const auto = <i32>this.num(PIN_AUTOPILOT);
            this.pilot.setup(auto != 1);
        }
    }

    // ---- the tick ----------------------------------------------------------------------

    private tick(): void {
        const dt = TICK;
        this.phaseTime += dt;
        const p = this.phase;
        const r = this.rider;
        this.drawn.keep();
        if (p == PHASE_TITLE) {
            // the attract: the autopilot rides the reference run, and again
            this.pilot.drive(r, this.inp, dt);
            r.tick(this.inp, dt);
            if (r.finished() || this.phaseTime > ATTRACT_MAX) {
                const t = this.phaseTime;
                this.toTitle();
                this.phaseTime = t;
            }
        } else if (p == PHASE_COUNTDOWN) {
            const n = 3 - <i32>Mathf.floor(this.phaseTime / COUNT_STEP);
            if (n <= 0) this.go();
            else if (n != this.countShown) {
                this.countShown = n;
                game.countdown = n;
                game.events.push(EV_COUNT, <f32>n);
            }
        } else if (p == PHASE_QUICKSTART) {
            if (this.countShown != 10) {
                this.countShown = 10;
                game.countdown = 10;
                game.events.push(EV_COUNT, 10);
            }
            if (this.phaseTime >= QUICK_GO) this.go();
        } else if (p == PHASE_RIDING || p == PHASE_CRASH) {
            this.riding(dt);
        } else if (p == PHASE_FINISH) {
            // coasting to a stop past the arch
            this.inp.clear();
            r.tick(this.inp, dt);
            if (r.mode == 0) {
                r.V = r.V > 6 * dt ? r.V - 6 * dt : 0;
            }
            if (this.phaseTime >= FINISH_TIME) this.toResults();
        } else if (p == PHASE_RESULTS) {
            this.tally(dt);
        }
        if (this.goTime >= 0) {
            this.goTime += dt;
            if (this.goTime >= GO_SHOWN && game.countdown == 0) {
                game.countdown = -1;
                this.goTime = -1;
            }
        }
        r.publish();
        game.rider.finished = p == PHASE_FINISH || p == PHASE_RESULTS || p == PHASE_INITIALS;
        this.drawn.set(r.x, r.y, r.z, r.q.x, r.q.y, r.q.z, r.q.w);
        if (this.restartFrame >= 0 && p == PHASE_RIDING && r.hasControl()) {
            this.lastRestartFrames = this.frame - this.restartFrame;
            this.restartFrame = -1;
        }
    }

    private riding(dt: f32): void {
        const r = this.rider;
        game.time += dt;
        if (this.piloted || this.demo) this.pilot.drive(r, this.inp, dt);
        else this.controls.fill(this.inp, dt);
        const wasTumbling = r.mode == MODE_TUMBLE;
        r.tick(this.inp, dt);
        // never stuck: no progress for STUCK_TIME with control, stood again further on
        if (r.bestS > this.stuckBest + 3) {
            this.stuckBest = r.bestS;
            this.stuckTime = 0;
        } else if (r.hasControl()) {
            this.stuckTime += dt;
        }
        if (this.stuckTime > STUCK_TIME && !r.finished()) {
            this.stuckTime = 0;
            r.rescue();
            this.stuckBest = r.bestS;
        }
        if ((wasTumbling && r.mode != MODE_TUMBLE) || r.respawned && r.crashTime == RESPAWN_AT) {
            // the respawn: the cameras cut, the drawn pose snaps
            view.cut = true;
            this.drawn.set(r.x, r.y, r.z, r.q.x, r.q.y, r.q.z, r.q.w);
            this.drawn.snap();
            this.riderView.snap();
        }
        const crashing = r.mode == MODE_TUMBLE || !r.hasControl() && r.respawned;
        const want = crashing ? PHASE_CRASH : PHASE_RIDING;
        if (want != this.phase) {
            this.phase = want;
            game.phase = want;
        }
        if (this.demo) {
            if (this.phaseTime >= DEMO_LOOP || r.finished()) this.demoLoop();
            return;
        }
        if (r.finished()) this.toFinish();
    }

    private toFinish(): void {
        this.setPhase(PHASE_FINISH);
        this.tricks.tally(game.time);
        game.events.push(EV_GATE, <f32>FINISH_S);
        game.events.push(EV_FINISH, game.time);
        game.events.push(EV_CONFETTI);
        this.riderView.celebrate = true;
    }

    private toResults(): void {
        this.setPhase(PHASE_RESULTS);
        const res = game.results;
        res.rank = rankOf(game.table, res.total);
        this.resStep = 0;
        this.tallyNext = TALLY_GAP;
        this.stamped = false;
        this.tallyEnd = false;
        this.entered = false;
        for (let i = 0; i <= TALLY_LINES; i++) this.resShown[i] = 0;
    }

    // The tally: each line in turn counts up (a tick on the music's 16ths),
    // then the total, then the grade stamped; a score in the table then
    // asks for the initials.
    private tally(dt: f32): void {
        const res = game.results;
        const t = this.phaseTime;
        if (this.resStep < TALLY_LINES) {
            if (t >= this.tallyNext) {
                const line = this.resStep;
                const target = this.lineValue(line);
                const start = this.tallyNext;
                const k = (t - start) / TALLY_COUNT;
                const before = this.resShown[line];
                this.resShown[line] = k >= 1 ? target : Mathf.round(target * k);
                if (this.resStep == line && this.resShown[line] == target && k >= 1) {
                    this.resStep = line + 1;
                    this.tallyNext = t + TALLY_GAP;
                }
                // the counting's tick
                const ticks = <i32>Mathf.floor((t - start) / TALLY_TICK);
                const prev = <i32>Mathf.floor((t - dt - start) / TALLY_TICK);
                if (ticks != prev && before != target) game.events.push(EV_TALLY_TICK, <f32>line);
            }
        } else if (this.resStep == TALLY_LINES) {
            if (t >= this.tallyNext) {
                this.resStep = TALLY_LINES + 1;
                this.resShown[TALLY_LINES] = res.total;
                this.stampTime = t + STAMP_DELAY;
                if (!this.tallyEnd) {
                    this.tallyEnd = true;
                    game.events.push(EV_TALLY_END, res.total);
                }
            }
        } else if (!this.stamped) {
            if (t >= this.stampTime) {
                this.stamped = true;
                this.resStep = TALLY_LINES + 2;
                game.events.push(EV_GRADE, <f32>res.grade, res.rank == 1 ? 1 : 0);
            }
        } else if (this.entered) {
            // the prompts: waiting for Start
        } else if (res.rank > 0 && t >= this.stampTime + INITIALS_DELAY && !this.piloted) {
            this.toInitials();
        } else if (res.rank > 0 && this.piloted && t >= this.stampTime + INITIALS_DELAY) {
            // the autopilot's runs sign as "CPU"
            this.initials[0] = 3;
            this.initials[1] = 16;
            this.initials[2] = 21;
            this.enterRow();
        }
    }

    private lineValue(line: i32): f32 {
        const r = game.results;
        if (line == 0) return r.tricks;
        if (line == 1) return r.grinds;
        if (line == 2) return r.comboBonus;
        if (line == 3) return r.landings;
        return r.timeBonus;
    }

    // ---- initials ----------------------------------------------------------------------

    private toInitials(): void {
        this.setPhase(PHASE_INITIALS);
        for (let i = 0; i < 3; i++) this.initials[i] = this.lastInitials[i];
        this.cursor = 0;
        this.seenInitials = this.num(PIN_INITIALS_IN);
        this.seenDone = this.num(PIN_INITIALS_DONE_SEQ);
    }

    private initialsInput(): void {
        const c = this.controls;
        // the Rive side's entry, when it writes one
        const vin = this.num(PIN_INITIALS_IN);
        if (vin != this.seenInitials) {
            this.seenInitials = vin;
            const v = <i32>vin;
            this.initials[0] = (v >> 12) & 63;
            this.initials[1] = (v >> 6) & 63;
            this.initials[2] = v & 63;
        }
        const done = this.num(PIN_INITIALS_DONE_SEQ);
        if (done != this.seenDone) {
            this.seenDone = done;
            this.enterRow();
            return;
        }
        // the keys
        const i = this.cursor;
        if (c.upPressed) {
            this.initials[i] = (this.initials[i] + 1) % LETTERS;
            game.events.push(EV_UI_MOVE);
        }
        if (c.downPressed) {
            this.initials[i] = (this.initials[i] + LETTERS - 1) % LETTERS;
            game.events.push(EV_UI_MOVE);
        }
        if (c.leftPressed && this.cursor > 0) {
            this.cursor--;
            game.events.push(EV_UI_MOVE);
        }
        if (c.rightPressed && this.cursor < 2) {
            this.cursor++;
            game.events.push(EV_UI_MOVE);
        }
        if (c.typed != 0) {
            const k = c.typed;
            let code = 0;
            if (k >= 65 && k <= 90) code = k - 64;
            else if (k >= 48 && k <= 57) code = k - 48 + 27;
            // (the arrows' letters, W A S D, move the cursor too: a typed W
            // or S changes nothing else)
            this.initials[i] = code;
            if (this.cursor < 2) this.cursor++;
            game.events.push(EV_UI_MOVE);
        }
        if (c.deletePressed && this.cursor > 0) this.cursor--;
        if (c.confirmPressed) {
            game.events.push(EV_UI_SELECT);
            if (this.cursor < 2) this.cursor++;
            else this.enterRow();
        }
    }

    private enterRow(): void {
        const res = game.results;
        const code = packInitials(this.initials[0], this.initials[1], this.initials[2]);
        if (res.rank > 0) {
            insertRow(game.table, res.rank, res.total, packTag(code, res.grade, this.rider.lineTaken));
            if (!this.piloted) for (let i = 0; i < 3; i++) this.lastInitials[i] = this.initials[i];
        }
        this.setPhase(PHASE_RESULTS);
        // the tally stays done: the prompts (the rank kept: the table's new row)
        this.resStep = TALLY_LINES + 2;
        this.stamped = true;
        this.tallyEnd = true;
        this.entered = true;
    }

    // ---- drawing ---------------------------------------------------------------------

    private draw(delta: f32): void {
        const r = this.rider;
        const d = this.drawn;
        d.blend(this.clock.alpha());
        this.riderView.draw(r, d, delta, game.settings.scheme);
        const a = this.anchor;
        if (a != null) a.setPosition(Vec3(d.ox, d.oy + 1.2, d.oz));
        // the cameras' view
        const p = this.phase;
        view.x = d.ox;
        view.y = d.oy;
        view.z = d.oz;
        view.travel = r.mode == MODE_AIR ? Mathf.atan2(-r.vx, -r.vz) : r.heading;
        if (r.mode == MODE_AIR && Mathf.abs(r.vx) + Mathf.abs(r.vz) < 0.5) view.travel = r.heading;
        view.speed = r.V;
        view.tuck = r.tuck;
        view.inAir = r.mode == MODE_AIR;
        view.airTime = r.airTime;
        view.grinding = r.mode == MODE_GRIND;
        view.landX = r.landX;
        view.landY = r.landY;
        view.landZ = r.landZ;
        view.landT = r.landT;
        view.phaseTime = this.phaseTime;
        let mode = CAM_CHASE;
        if (p == PHASE_TITLE) mode = CAM_TITLE;
        else if (p == PHASE_COUNTDOWN) mode = CAM_GATE;
        else if (r.mode == MODE_TUMBLE) mode = CAM_CRASH;
        else if (p == PHASE_FINISH || p == PHASE_RESULTS || p == PHASE_INITIALS) mode = CAM_FINISH;
        view.mode = mode;
        if (mode == CAM_FINISH) {
            let i = <i32>FINISH_S;
            lineSample(i, false, this.lp);
            view.finishX = this.lp.x;
            view.finishY = this.lp.y;
            view.finishZ = this.lp.z;
            view.finishYaw = Mathf.atan2(-this.lp.tx, -this.lp.tz);
        }
    }

    // ---- the pins ----------------------------------------------------------------------

    private num(i: i32): f32 {
        const n = this.pins[i];
        return n != null ? n.position.x : 0;
    }

    private flag(i: i32): bool {
        const n = this.pins[i];
        return n != null && n.visible;
    }

    private setNum(i: i32, v: f32): void {
        const n = this.pins[i];
        if (n != null && n.position.x != v) n.setPosition(Vec3(v, 0, 0));
    }

    private setFlag(i: i32, b: bool): void {
        const n = this.pins[i];
        if (n != null && n.visible != b) n.visible = b;
    }

    private writePins(): void {
        const t = game.trick;
        const r = game.rider;
        const res = game.results;
        this.setNum(PIN_PHASE, <f32>game.phase);
        this.setNum(PIN_SCORE, game.score);
        this.setNum(PIN_COMBO_SUM, game.comboSum);
        this.setNum(PIN_COMBO_MULT, <f32>game.comboMult);
        this.setFlag(PIN_COMBO_ACTIVE, game.comboActive);
        this.setNum(PIN_TRICK_SPIN, <f32>t.spin);
        this.setNum(PIN_TRICK_DIR, <f32>t.dir);
        this.setNum(PIN_TRICK_FLIP, <f32>t.flip);
        this.setNum(PIN_TRICK_GRAB1, <f32>t.grab1);
        this.setNum(PIN_TRICK_GRAB2, <f32>t.grab2);
        this.setFlag(PIN_TRICK_SWITCH, t.switchStance);
        this.setNum(PIN_TRICK_GRIND, <f32>t.grind);
        this.setFlag(PIN_TRICK_LIVE, t.live);
        this.setNum(PIN_TRICK_POINTS, t.points);
        this.setNum(PIN_TRICK_SEQ, <f32>this.tricks.trickSeq);
        this.setNum(PIN_BANK_SEQ, <f32>this.tricks.bankSeq);
        this.setNum(PIN_PERFECT_SEQ, <f32>this.tricks.perfectSeq);
        this.setNum(PIN_CRASH_SEQ, <f32>this.tricks.crashSeq);
        this.setNum(PIN_BAIL_SEQ, <f32>this.tricks.bailSeq);
        this.setNum(PIN_PRAISE, <f32>this.tricks.praise);
        this.setNum(PIN_TIME, Mathf.round(game.time * 100) / 100);
        this.setNum(PIN_COUNTDOWN, <f32>game.countdown);
        let progress = r.s / FINISH_S;
        if (progress < 0) progress = 0;
        if (progress > 1) progress = 1;
        this.setNum(PIN_PROGRESS, Mathf.round(progress * 1000) / 1000);
        this.setNum(PIN_SECTION, <f32>r.section);
        this.setNum(PIN_SPEED_KMH, Mathf.round(r.speed * 3.6));
        this.setNum(PIN_BALANCE, Mathf.round(r.balance * 100) / 100);
        this.setFlag(PIN_GRINDING, r.grind != 0);
        this.setFlag(PIN_LINE_HIGH, r.highLine);
        const results = this.phase == PHASE_RESULTS || this.phase == PHASE_INITIALS;
        this.setNum(PIN_RES_TRICKS, results ? this.resShown[0] : 0);
        this.setNum(PIN_RES_GRINDS, results ? this.resShown[1] : 0);
        this.setNum(PIN_RES_COMBO_BONUS, results ? this.resShown[2] : 0);
        this.setNum(PIN_RES_LANDINGS, results ? this.resShown[3] : 0);
        this.setNum(PIN_RES_TIME_BONUS, results ? this.resShown[4] : 0);
        this.setNum(PIN_RES_TOTAL, results ? this.resShown[5] : 0);
        this.setNum(PIN_RES_BEST_COMBO, res.bestCombo);
        this.setNum(PIN_RES_LONGEST_AIR, res.longestAir);
        this.setNum(PIN_RES_PERFECTS, <f32>res.perfects);
        this.setNum(PIN_RES_CRASHES, <f32>res.crashes);
        this.setNum(PIN_RES_STEP, results ? <f32>this.resStep : 0);
        this.setNum(PIN_RES_GRADE, results && this.stamped ? <f32>res.grade : -1);
        this.setNum(PIN_RES_RANK, <f32>res.rank);
        this.setNum(PIN_INITIALS_CODE, packInitials(this.initials[0], this.initials[1], this.initials[2]));
        this.setNum(PIN_INITIALS_CURSOR, <f32>this.cursor);
        for (let i = 0; i < TABLE_SIZE; i++) {
            this.setNum(PIN_HS1_SCORE + i, game.table.scores[i]);
            this.setNum(PIN_HS1_TAG + i, game.table.tags[i]);
        }
        const a = game.audio;
        this.setNum(PIN_CAPTION_LINE, <f32>a.speakingLine);
        this.setNum(PIN_CAPTION_SEQ, <f32>a.lineSeq);
        this.setNum(PIN_BEAT, <f32>a.beat);
        this.setNum(PIN_DEVICE, <f32>this.controls.device);
        this.setNum(PIN_GHOST_DELTA, 0);
    }

    private printState(): void {
        const r = this.rider;
        console.log("frame " + this.frame.toString() + " phase " + game.phase.toString() + " s " + r.s.toString() +
            " x " + r.x.toString() + " y " + r.y.toString() + " v " + r.V.toString() + " mode " + r.mode.toString() +
            " score " + game.score.toString() + " land " + r.lastLand.toString() + " high " + (r.highLine ? "1" : "0") +
            " t " + game.time.toString() + " brake " + (this.pilot.braking ? "1" : "0") + " target " + this.pilot.dbgTarget.toString() + " cross " + this.pilot.dbgCross.toString() + " steer " + this.inp.x.toString());
    }
}

