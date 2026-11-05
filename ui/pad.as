// The pad until E-PAD (docs/RIVE.md, section 4; SPEC.md, section 3): a 2D
// Node on Main that hears Rive's gamepad events and
//
// - writes the pad's state for the world's inbound pins: padX, padY (the
//   left stick, its 0.15 radial dead zone applied and the rest rescaled to
//   0..1, Y up positive) and padButtons (tools/pins.py's bits: 1 south,
//   2 east, 4 west, 8 north, 16 start, 32 select, 64 up, 128 down, 256 left,
//   512 right), and `device` = 1 (the glyphs follow the last device);
// - drives the menus by pad, doing what the keys' listeners do: the title
//   (left / right the scheme, south / start startSeq), the run (start
//   restartSeq, select pause), the results (south / start restartSeq,
//   select pause), the pause menu (up / down, left / right, south, east /
//   select / start resume) and the initials entry (ui_state.as).
//
// The stick also moves the menus: a push past 0.5 is one d-pad press.
// Nothing reaches the world or the menus in demo mode.

import { Node, Context } from "rive/host";
import { GamepadEvent } from "rive/events";
import {
    NumberProp, bindUi, initialsBack, initialsConfirm, initialsMove, initialsStep, num, pauseMove, pauseToggle, ui,
} from "./ui_state";

const DEAD: f64 = 0.15;
const FLICK: f64 = 0.5;

const B_SOUTH: i32 = 1;
const B_EAST: i32 = 2;
const B_WEST: i32 = 4;
const B_NORTH: i32 = 8;
const B_START: i32 = 16;
const B_SELECT: i32 = 32;
const B_UP: i32 = 64;
const B_DOWN: i32 = 128;
const B_LEFT: i32 = 256;
const B_RIGHT: i32 = 512;

export class Pad extends Node {
    padX: NumberProp = new NumberProp();
    padY: NumberProp = new NumberProp();
    padButtons: NumberProp = new NumberProp();
    buttons: i32 = 0;      // the last bitmask (d-pad and stick flicks included, for the menus' edges)
    stickDir: i32 = 0;     // the stick's last flick as a d-pad bit, 0 centred

    override init(context: Context): bool {
        bindUi(context.viewModel());
        this.padX = num(ui.data, "padX");
        this.padY = num(ui.data, "padY");
        this.padButtons = num(ui.data, "padButtons");
        return true;
    }

    override gamepadEvent(e: GamepadEvent): bool {
        if (!ui.bound) return false;
        if (ui.demo.v) {
            this.padX.set(0);
            this.padY.set(0);
            this.padButtons.set(0);
            return false;
        }
        // the left stick, radial dead zone
        let x = <f64>e.axis(0);
        let y = -<f64>e.axis(1);
        const mag = Math.sqrt(x * x + y * y);
        if (mag < DEAD) {
            x = 0;
            y = 0;
        } else {
            const k = Math.min((mag - DEAD) / (1 - DEAD), 1) / mag;
            x *= k;
            y *= k;
        }
        this.padX.set(Math.round(x * 1000) / 1000);
        this.padY.set(Math.round(y * 1000) / 1000);
        let b = 0;
        if (e.buttonPressed(0)) b |= B_SOUTH;
        if (e.buttonPressed(1)) b |= B_EAST;
        if (e.buttonPressed(2)) b |= B_WEST;
        if (e.buttonPressed(3)) b |= B_NORTH;
        if (e.buttonPressed(9)) b |= B_START;
        if (e.buttonPressed(8)) b |= B_SELECT;
        if (e.buttonPressed(12)) b |= B_UP;
        if (e.buttonPressed(13)) b |= B_DOWN;
        if (e.buttonPressed(14)) b |= B_LEFT;
        if (e.buttonPressed(15)) b |= B_RIGHT;
        this.padButtons.set(<f64>b);
        ui.device.set(1);
        // the stick as a d-pad for the menus: one press per flick
        let dir = 0;
        const raw = Math.sqrt(<f64>e.axis(0) * <f64>e.axis(0) + <f64>e.axis(1) * <f64>e.axis(1));
        if (raw > FLICK) {
            const ax = <f64>e.axis(0);
            const ay = -<f64>e.axis(1);
            if (Math.abs(ax) > Math.abs(ay)) dir = ax > 0 ? B_RIGHT : B_LEFT;
            else dir = ay > 0 ? B_UP : B_DOWN;
        }
        const menuBits = b | dir;
        const pressed = menuBits & ~(this.buttons | this.stickDir);
        this.buttons = b;
        this.stickDir = dir;
        if (pressed != 0) this.menus(pressed);
        return true;
    }

    menus(pressed: i32): void {
        const phase = <i32>ui.phase.v;
        if (ui.paused.v) {
            if ((pressed & B_UP) != 0) pauseMove(-1);
            if ((pressed & B_DOWN) != 0) pauseMove(1);
            if ((pressed & B_LEFT) != 0) ui.pauseLeft.fire();
            if ((pressed & B_RIGHT) != 0) ui.pauseRight.fire();
            if ((pressed & B_SOUTH) != 0) ui.pauseGo.fire();
            if ((pressed & (B_EAST | B_SELECT | B_START)) != 0) pauseToggle();
            return;
        }
        if (phase == 0) {
            if ((pressed & B_LEFT) != 0) {
                ui.scheme.set((ui.scheme.v + 2) % 3);
                ui.uiMoveSeq.bump();
            }
            if ((pressed & B_RIGHT) != 0) {
                ui.scheme.set((ui.scheme.v + 1) % 3);
                ui.uiMoveSeq.bump();
            }
            if ((pressed & (B_SOUTH | B_START)) != 0) {
                ui.startSeq.bump();
                ui.uiSelectSeq.bump();
            }
            return;
        }
        if (phase == 7) {
            if ((pressed & B_UP) != 0) initialsStep(1);
            if ((pressed & B_DOWN) != 0) initialsStep(-1);
            if ((pressed & B_LEFT) != 0) initialsMove(-1);
            if ((pressed & B_RIGHT) != 0) initialsMove(1);
            if ((pressed & (B_SOUTH | B_START)) != 0) initialsConfirm();
            if ((pressed & B_EAST) != 0) initialsBack();
            return;
        }
        if (phase == 6) {
            if ((pressed & (B_SOUTH | B_START)) != 0) {
                ui.restartSeq.bump();
                ui.uiSelectSeq.bump();
            }
            if ((pressed & B_SELECT) != 0) pauseToggle();
            return;
        }
        if (phase >= 1 && phase <= 5) {
            if ((pressed & B_START) != 0) ui.restartSeq.bump();
            if ((pressed & B_SELECT) != 0) pauseToggle();
        }
    }
}
