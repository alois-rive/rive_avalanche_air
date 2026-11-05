// The 2D scripts' shared handles on the view models (docs/RIVE.md, section 2):
// `Game` (the main artboard's), its `data` (GameData, the pins: the world's
// side) and its `ui` (Ui, the Rive side's own: strings composed from the
// pins, the grid's scale, the menus' selections). One module global, `ui`,
// bound once by whichever script initialises first (text.as, pad.as,
// initials.as, fit.as all call bindUi); the actions the keys and the pad
// share (the initials entry, the menus' commands) are here so the keyboard
// and the pad do exactly the same thing.
//
// A library: no protocol class.

import { PropertyBoolean, PropertyNumber, PropertyString, PropertyTrigger, ViewModel } from "rive/data";
import { INITIAL_COUNT, initialChar, packInitials, unpackInitial } from "./lines";

export class NumberProp {
    p: PropertyNumber? = null;

    get v(): f64 {
        const p = this.p;
        return p != null ? p.value : 0;
    }

    set(v: f64): void {
        const p = this.p;
        if (p != null && p.value != v) p.value = v;
    }

    bump(): void {
        const p = this.p;
        if (p != null) p.value = p.value + 1;
    }
}

export class BoolProp {
    p: PropertyBoolean? = null;

    get v(): bool {
        const p = this.p;
        return p != null ? p.value : false;
    }

    set(v: bool): void {
        const p = this.p;
        if (p != null && p.value != v) p.value = v;
    }
}

export class StringProp {
    p: PropertyString? = null;
    last: string = "\u0001";

    set(v: string): void {
        if (v == this.last) return;
        this.last = v;
        const p = this.p;
        if (p != null) p.value = v;
    }
}

export class TriggerProp {
    p: PropertyTrigger? = null;

    fire(): void {
        const p = this.p;
        if (p != null) p.fire();
    }
}

export function num(vm: ViewModel?, name: string): NumberProp {
    const out = new NumberProp();
    if (vm != null) out.p = vm.getNumber(name);
    return out;
}

export function bool_(vm: ViewModel?, name: string): BoolProp {
    const out = new BoolProp();
    if (vm != null) out.p = vm.getBoolean(name);
    return out;
}

export function str(vm: ViewModel?, name: string): StringProp {
    const out = new StringProp();
    if (vm != null) out.p = vm.getString(name);
    return out;
}

export function trig(vm: ViewModel?, name: string): TriggerProp {
    const out = new TriggerProp();
    if (vm != null) out.p = vm.getTrigger(name);
    return out;
}

// Pause menu rows (make_rml.py PAUSE_ITEMS: the same order)
export const PAUSE_ROWS: i32 = 11;

export class Ui {
    bound: bool = false;
    game: ViewModel? = null;
    data: ViewModel? = null;
    view: ViewModel? = null;

    // data (GameData) used by the actions
    phase: NumberProp = new NumberProp();
    paused: BoolProp = new BoolProp();
    demo: BoolProp = new BoolProp();
    startSeq: NumberProp = new NumberProp();
    restartSeq: NumberProp = new NumberProp();
    scheme: NumberProp = new NumberProp();
    uiMoveSeq: NumberProp = new NumberProp();
    uiSelectSeq: NumberProp = new NumberProp();
    uiBackSeq: NumberProp = new NumberProp();
    initialsIn: NumberProp = new NumberProp();
    initialsDoneSeq: NumberProp = new NumberProp();
    initialsCode: NumberProp = new NumberProp();
    device: NumberProp = new NumberProp();

    // ui (Ui)
    pauseSel: NumberProp = new NumberProp();
    pauseGo: TriggerProp = new TriggerProp();
    pauseLeft: TriggerProp = new TriggerProp();
    pauseRight: TriggerProp = new TriggerProp();
    pauseBack: TriggerProp = new TriggerProp();
    ini0: NumberProp = new NumberProp();
    ini1: NumberProp = new NumberProp();
    ini2: NumberProp = new NumberProp();
    iniCursor: NumberProp = new NumberProp();
    iniDone: BoolProp = new BoolProp();
    iniText0: StringProp = new StringProp();
    iniText1: StringProp = new StringProp();
    iniText2: StringProp = new StringProp();
    iniEntered: bool = false;   // the entry was seeded for this visit of the initials phase
}

export const ui: Ui = new Ui();

export function bindUi(game: ViewModel?): void {
    if (ui.bound || game == null) return;
    const dp = game.getViewModel("data");
    const up = game.getViewModel("ui");
    if (dp == null || up == null) return;
    const d = dp.value;
    const u = up.value;
    ui.game = game;
    ui.data = d;
    ui.view = u;
    ui.phase = num(d, "phase");
    ui.paused = bool_(d, "paused");
    ui.demo = bool_(d, "demo");
    ui.startSeq = num(d, "startSeq");
    ui.restartSeq = num(d, "restartSeq");
    ui.scheme = num(d, "scheme");
    ui.uiMoveSeq = num(d, "uiMoveSeq");
    ui.uiSelectSeq = num(d, "uiSelectSeq");
    ui.uiBackSeq = num(d, "uiBackSeq");
    ui.initialsIn = num(d, "initialsIn");
    ui.initialsDoneSeq = num(d, "initialsDoneSeq");
    ui.initialsCode = num(d, "initialsCode");
    ui.device = num(d, "device");
    ui.pauseSel = num(u, "pauseSel");
    ui.pauseGo = trig(u, "pauseGo");
    ui.pauseLeft = trig(u, "pauseLeft");
    ui.pauseRight = trig(u, "pauseRight");
    ui.pauseBack = trig(u, "pauseBack");
    ui.ini0 = num(u, "ini0");
    ui.ini1 = num(u, "ini1");
    ui.ini2 = num(u, "ini2");
    ui.iniCursor = num(u, "iniCursor");
    ui.iniDone = bool_(u, "iniDone");
    ui.iniText0 = str(u, "iniText0");
    ui.iniText1 = str(u, "iniText1");
    ui.iniText2 = str(u, "iniText2");
    ui.bound = true;
}

// ---- the initials entry (docs/RIVE.md, section 6) --------------------------

function slot(i: i32): NumberProp {
    return i == 0 ? ui.ini0 : (i == 1 ? ui.ini1 : ui.ini2);
}

function publishInitials(): void {
    const c0 = <i32>ui.ini0.v;
    const c1 = <i32>ui.ini1.v;
    const c2 = <i32>ui.ini2.v;
    ui.iniText0.set(initialChar(c0));
    ui.iniText1.set(initialChar(c1));
    ui.iniText2.set(initialChar(c2));
    ui.initialsIn.set(<f64>packInitials(c0, c1, c2));
}

// Called every frame by text.as: seeds the entry on entering the phase (the
// world's initialsCode: the session's last initials, else "AAA").
export function initialsTick(): void {
    const inPhase = <i32>ui.phase.v == 7;
    if (inPhase && !ui.iniEntered) {
        ui.iniEntered = true;
        const code = <i32>ui.initialsCode.v;
        let c0 = 1;
        let c1 = 1;
        let c2 = 1;
        if (code > 0) {
            c0 = unpackInitial(code, 0);
            c1 = unpackInitial(code, 1);
            c2 = unpackInitial(code, 2);
        }
        ui.ini0.set(c0);
        ui.ini1.set(c1);
        ui.ini2.set(c2);
        ui.iniCursor.set(0);
        ui.iniDone.set(false);
        publishInitials();
    } else if (!inPhase && ui.iniEntered) {
        ui.iniEntered = false;
    }
    if (inPhase) publishInitials();
}

export function initialsActive(): bool {
    return <i32>ui.phase.v == 7 && !ui.iniDone.v && !ui.paused.v && !ui.demo.v;
}

export function initialsStep(delta: i32): void {
    if (!initialsActive()) return;
    const s = slot(<i32>ui.iniCursor.v);
    let c = (<i32>s.v + delta) % INITIAL_COUNT;
    if (c < 0) c += INITIAL_COUNT;
    s.set(c);
    publishInitials();
    ui.uiMoveSeq.bump();
}

export function initialsMove(delta: i32): void {
    if (!initialsActive()) return;
    let c = <i32>ui.iniCursor.v + delta;
    if (c < 0) c = 0;
    if (c > 2) c = 2;
    ui.iniCursor.set(c);
    ui.uiMoveSeq.bump();
}

export function initialsType(ch: i32): void {
    if (!initialsActive()) return;
    const cur = <i32>ui.iniCursor.v;
    slot(cur).set(ch);
    publishInitials();
    if (cur < 2) ui.iniCursor.set(cur + 1);
    ui.uiMoveSeq.bump();
}

export function initialsConfirm(): void {
    if (!initialsActive()) return;
    publishInitials();
    ui.iniDone.set(true);
    ui.initialsDoneSeq.bump();
    ui.uiSelectSeq.bump();
}

export function initialsBack(): void {
    if (!initialsActive()) return;
    const cur = <i32>ui.iniCursor.v;
    if (cur > 0) ui.iniCursor.set(cur - 1);
    ui.uiBackSeq.bump();
}

// ---- the menus' commands, for the pad (the keys do the same through the
// main machine's listeners: make_rml.py) -------------------------------------

export function pauseToggle(): void {
    const p = <i32>ui.phase.v;
    if (ui.paused.v) {
        // (Main's Pause Act layer: closes the controls card, else resumes)
        ui.pauseBack.fire();
    } else if (p >= 1 && p <= 6) {
        ui.pauseSel.set(0);
        ui.paused.set(true);
        ui.uiSelectSeq.bump();
    }
}

export function pauseMove(delta: i32): void {
    let s = (<i32>ui.pauseSel.v + delta) % PAUSE_ROWS;
    if (s < 0) s += PAUSE_ROWS;
    ui.pauseSel.set(s);
    ui.uiMoveSeq.bump();
}
