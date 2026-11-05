// The initials entry's keys (docs/RIVE.md, section 6; TRICKS.md, section
// 10): a Node on Main with a FocusData, focused by Main's Focus layer while
// the phase is 7 (initials). Up and down change the letter under the
// cursor, left and right move it, a typed letter or digit fills it and
// moves on, Backspace steps back, Enter (or the keypad's) confirms: the
// letters go to initialsIn as they change and initialsDoneSeq is bumped on
// the confirm (ui_state.as, shared with the pad).

import { Node, Context } from "rive/host";
import { KeyboardEvent } from "rive/events";
import { bindUi, initialsBack, initialsConfirm, initialsMove, initialsStep, initialsType, ui } from "./ui_state";
import { initialOfKey } from "./lines";

const K_ENTER: i32 = 257;
const K_KP_ENTER: i32 = 335;
const K_BACKSPACE: i32 = 259;
const K_RIGHT: i32 = 262;
const K_LEFT: i32 = 263;
const K_DOWN: i32 = 264;
const K_UP: i32 = 265;

export class Initials extends Node {
    override init(context: Context): bool {
        bindUi(context.viewModel());
        return true;
    }

    override keyboardEvent(e: KeyboardEvent): bool {
        if (!ui.bound || e.phase == "up") return false;
        const key = <i32>e.key;
        ui.device.set(0);
        if (key == K_UP) {
            initialsStep(1);
        } else if (key == K_DOWN) {
            initialsStep(-1);
        } else if (key == K_LEFT) {
            initialsMove(-1);
        } else if (key == K_RIGHT) {
            initialsMove(1);
        } else if (key == K_ENTER || key == K_KP_ENTER) {
            if (e.phase == "down") initialsConfirm();
        } else if (key == K_BACKSPACE) {
            initialsBack();
        } else {
            const c = initialOfKey(key);
            if (c < 0 || e.phase != "down") return false;
            initialsType(c);
        }
        return true;
    }
}
