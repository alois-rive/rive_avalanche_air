// The player's input (docs/SPEC.md, section 3; docs/RIDER.md, section 13):
// the keys held (the Scene3D forwards its key events to run.as's _input,
// which folds them in here) and the pad's state (written by the Rive side's
// pad script into the in-pins padX, padY and padButtons until gap E-PAD),
// made into one `Input` a tick. The autopilot (autopilot.as) writes the
// same struct, so the rider cannot tell a script from a player.
//
// Key codes are rive's, as the Scene3D forwards them (the kart's list).
import { InputEvent, InputKind } from "hedra_engine/script";
import { clampf } from "./lib/kinematic";

export const KEY_SPACE: i32 = 32;
export const KEY_0: i32 = 48;
export const KEY_9: i32 = 57;
export const KEY_A: i32 = 65;
export const KEY_D: i32 = 68;
export const KEY_J: i32 = 74;
export const KEY_K: i32 = 75;
export const KEY_L: i32 = 76;
export const KEY_R: i32 = 82;
export const KEY_S: i32 = 83;
export const KEY_W: i32 = 87;
export const KEY_Z: i32 = 90;
export const KEY_ESCAPE: i32 = 256;
export const KEY_ENTER: i32 = 257;
export const KEY_BACKSPACE: i32 = 259;
export const KEY_RIGHT: i32 = 262;
export const KEY_LEFT: i32 = 263;
export const KEY_DOWN: i32 = 264;
export const KEY_UP: i32 = 265;
export const KEY_KP_ENTER: i32 = 335;

// the pad's button bits (tools/pins.py, padButtons)
export const PAD_SOUTH: i32 = 1;
export const PAD_EAST: i32 = 2;
export const PAD_WEST: i32 = 4;
export const PAD_NORTH: i32 = 8;
export const PAD_START: i32 = 16;
export const PAD_SELECT: i32 = 32;
export const PAD_UP: i32 = 64;
export const PAD_DOWN: i32 = 128;
export const PAD_LEFT: i32 = 256;
export const PAD_RIGHT: i32 = 512;

// Input's grab bits: one per grab button (a chord of INDY and MELON is the
// Mute: SPEC.md, section 3)
export const GRAB_BIT_INDY: i32 = 1;    // J, west
export const GRAB_BIT_MELON: i32 = 2;   // K, east
export const GRAB_BIT_METHOD: i32 = 4;  // L, north

// keyboard bits held
const K_LEFT: i32 = 1;       // A
const K_RIGHT: i32 = 2;      // D
const K_ALEFT: i32 = 4;      // Left arrow
const K_ARIGHT: i32 = 8;     // Right arrow
const K_UP: i32 = 16;        // Up arrow
const K_DOWN: i32 = 32;      // Down arrow
const K_TUCK: i32 = 64;      // S
const K_CROUCH: i32 = 128;   // Space
const K_INDY: i32 = 256;     // J
const K_MELON: i32 = 512;    // K
const K_METHOD: i32 = 1024;  // L
const K_W: i32 = 2048;       // W (a front flip, as Up)

// The keyboard's steering eases from 0 to 1 in 0.12 s (SPEC.md, section 3).
const KEY_EASE: f32 = 8.33;
// The stick's tuck threshold.
const TUCK_STICK: f32 = -0.5;

// What the rider is asked, one tick.
export class Input {
    x: f32 = 0;          // -1 left .. +1 right: carve on the snow, spin in the air, balance on a rail
    y: f32 = 0;          // -1 down .. +1 up: a back flip, a front flip (in the air)
    tuck: bool = false;  // S, the stick below -0.5 (on the snow)
    crouch: bool = false;// Space, south: held to crouch, released to ollie
    grabs: i32 = 0;      // GRAB_BIT_*

    set(o: Input): void {
        this.x = o.x;
        this.y = o.y;
        this.tuck = o.tuck;
        this.crouch = o.crouch;
        this.grabs = o.grabs;
    }

    clear(): void {
        this.x = 0;
        this.y = 0;
        this.tuck = false;
        this.crouch = false;
        this.grabs = 0;
    }
}

// The keys and the pad, folded into an Input each tick.
export class Controls {
    held: i32 = 0;
    // the keyboard's eased steering
    private keyX: f32 = 0;
    // the pad (from the pins)
    padX: f32 = 0;
    padY: f32 = 0;
    padButtons: i32 = 0;
    private lastPadButtons: i32 = 0;
    // 0 keyboard, 1 pad: the last used
    device: i32 = 0;
    // one-shot presses since the driver last took them
    restartPressed: bool = false;
    confirmPressed: bool = false;   // Enter, Space (menus, the title, the initials)
    backPressed: bool = false;      // Escape, Select
    upPressed: bool = false;
    downPressed: bool = false;
    leftPressed: bool = false;
    rightPressed: bool = false;
    typed: i32 = 0;                 // a letter or digit typed (its key code), 0 none
    deletePressed: bool = false;

    // Folds one key event in; true when it was one of the game's keys.
    take(e: InputEvent): bool {
        if (!e.isKey()) return false;
        const k = e.kind;
        const key = e.key;
        if (k == InputKind.KeyRepeat) {
            const bit = this.bit(key);
            this.held |= bit;
            return bit != 0;
        }
        const down = k == InputKind.KeyDown;
        let used = false;
        if (down) {
            this.device = 0;
            if (key == KEY_R) {
                this.restartPressed = true;
                used = true;
            }
            if (key == KEY_ENTER || key == KEY_KP_ENTER || key == KEY_SPACE) {
                this.confirmPressed = true;
                used = true;
            }
            if (key == KEY_ESCAPE) {
                this.backPressed = true;
                used = true;
            }
            if (key == KEY_BACKSPACE) {
                this.deletePressed = true;
                used = true;
            }
            // (the menus' moves are the arrows: W A S D are letters there)
            if (key == KEY_UP) this.upPressed = true;
            if (key == KEY_DOWN) this.downPressed = true;
            if (key == KEY_LEFT) this.leftPressed = true;
            if (key == KEY_RIGHT) this.rightPressed = true;
            if ((key >= KEY_A && key <= KEY_Z) || (key >= KEY_0 && key <= KEY_9)) this.typed = key;
        }
        const bit = this.bit(key);
        if (bit != 0) {
            this.held = down ? (this.held | bit) : (this.held & ~bit);
            used = true;
        }
        return used;
    }

    private bit(key: i32): i32 {
        if (key == KEY_A) return K_LEFT;
        if (key == KEY_D) return K_RIGHT;
        if (key == KEY_LEFT) return K_ALEFT;
        if (key == KEY_RIGHT) return K_ARIGHT;
        if (key == KEY_UP) return K_UP;
        if (key == KEY_W) return K_W;
        if (key == KEY_DOWN) return K_DOWN;
        if (key == KEY_S) return K_TUCK;
        if (key == KEY_SPACE) return K_CROUCH;
        if (key == KEY_J) return K_INDY;
        if (key == KEY_K) return K_MELON;
        if (key == KEY_L) return K_METHOD;
        return 0;
    }

    // Presses a key by its code, as an event would (the tests' scripted keys).
    press(key: i32, down: bool): void {
        const bit = this.bit(key);
        this.held = down ? (this.held | bit) : (this.held & ~bit);
    }

    // The pad's state this frame (the pins); its presses become the same
    // one-shot presses as the keys'.
    setPad(x: f32, y: f32, buttons: i32): void {
        this.padX = clampf(x, -1, 1);
        this.padY = clampf(y, -1, 1);
        const pressed = buttons & ~this.lastPadButtons;
        this.lastPadButtons = buttons;
        this.padButtons = buttons;
        if (pressed != 0 || Mathf.abs(x) > 0.5 || Mathf.abs(y) > 0.5) this.device = 1;
        if ((pressed & PAD_START) != 0) this.restartPressed = true;
        if ((pressed & PAD_SOUTH) != 0) this.confirmPressed = true;
        if ((pressed & PAD_SELECT) != 0) this.backPressed = true;
        if ((pressed & PAD_UP) != 0) this.upPressed = true;
        if ((pressed & PAD_DOWN) != 0) this.downPressed = true;
        if ((pressed & PAD_LEFT) != 0) this.leftPressed = true;
        if ((pressed & PAD_RIGHT) != 0) this.rightPressed = true;
    }

    // One tick's input from the keys and the pad together.
    fill(out: Input, dt: f32): void {
        const h = this.held;
        // the keyboard's steering, eased; both directions cancel out
        let kx: f32 = 0;
        if ((h & (K_LEFT | K_ALEFT)) != 0) kx -= 1;
        if ((h & (K_RIGHT | K_ARIGHT)) != 0) kx += 1;
        const step = KEY_EASE * dt;
        if (kx == 0) this.keyX = 0;
        else if (this.keyX < kx) this.keyX = this.keyX + step < kx ? this.keyX + step : kx;
        else if (this.keyX > kx) this.keyX = this.keyX - step > kx ? this.keyX - step : kx;
        // the stick: its response squared beyond the pad script's dead zone
        let px = this.padX;
        px = px * Mathf.abs(px);
        const pb = this.padButtons;
        if ((pb & PAD_LEFT) != 0) px = -1;
        if ((pb & PAD_RIGHT) != 0) px = 1;
        let x = this.keyX + px;
        out.x = clampf(x, -1, 1);
        let ky: f32 = 0;
        if ((h & (K_UP | K_W)) != 0) ky += 1;
        if ((h & K_DOWN) != 0) ky -= 1;
        let py = this.padY;
        if ((pb & PAD_UP) != 0) py = 1;
        if ((pb & PAD_DOWN) != 0) py = -1;
        out.y = clampf(ky + py, -1, 1);
        out.tuck = (h & K_TUCK) != 0 || this.padY < TUCK_STICK;
        out.crouch = (h & K_CROUCH) != 0 || (pb & PAD_SOUTH) != 0;
        let g = 0;
        if ((h & K_INDY) != 0 || (pb & PAD_WEST) != 0) g |= GRAB_BIT_INDY;
        if ((h & K_MELON) != 0 || (pb & PAD_EAST) != 0) g |= GRAB_BIT_MELON;
        if ((h & K_METHOD) != 0 || (pb & PAD_NORTH) != 0) g |= GRAB_BIT_METHOD;
        out.grabs = g;
    }

    // The presses taken: the driver read them this frame.
    takePresses(): void {
        this.restartPressed = false;
        this.confirmPressed = false;
        this.backPressed = false;
        this.upPressed = false;
        this.downPressed = false;
        this.leftPressed = false;
        this.rightPressed = false;
        this.typed = 0;
        this.deletePressed = false;
    }

    // Nothing held (a phase change, the pause menu took the keys).
    clear(): void {
        this.held = 0;
        this.keyX = 0;
        this.takePresses();
    }
}
