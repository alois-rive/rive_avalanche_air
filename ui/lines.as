// The Rive side's words (docs/RIVE.md, section 4): what the 2D scripts
// compose the strings from, since a pin carries numbers only.
//
// - CAPTION_LINES: the announcer's line ids (captionLine, docs/AUDIO.md,
//   section 6). AUDIO's announcer uses the same ids: 0..24 below, 100 and
//   up a trick name spoken from the trick pins (the caption shows the
//   banner's name then).
// - the trick name, from the trick pins (docs/TRICKS.md, section 2);
// - the praise words (docs/TRICKS.md, section 6);
// - the high score table's initials and tags (world/scripts/game_state.as,
//   packInitials and packTag);
// - numbers with thousands separators ("2,450").
//
// A library: no protocol class. Strings are built only when an input
// changes (the callers compare first).

export const CAPTION_TRICK: i32 = 100;

export const CAPTION_LINES: StaticArray<string> = [
    "THREE!",        // 0
    "TWO!",          // 1
    "ONE!",          // 2
    "GO!",           // 3
    "READY...",      // 4
    "NICE!",         // 5
    "SICK!",         // 6
    "RADICAL!",      // 7
    "INSANE!",       // 8
    "UNREAL!",       // 9
    "PERFECT!",      // 10
    "SKETCHY...",    // 11
    "OUCH!",         // 12
    "WIPEOUT!",      // 13
    "BAIL!",         // 14
    "HIGH LINE!",    // 15
    "LOW LINE!",     // 16
    "FINAL JUMP!",   // 17
    "AWESOME!",      // 18
    "S RANK!",       // 19
    "A RANK!",       // 20
    "B RANK!",       // 21
    "C RANK!",       // 22
    "NEW RECORD!",   // 23
    "COMBO!",        // 24
    "YEAH!",         // 25 (the finish's alternate)
    "NASTY!",        // 26 (SICK's alternate: never the same praise twice in a row)
];

// praise id (pins.py `praise`) -> the word slammed on screen
export const PRAISE_WORDS: StaticArray<string> = [
    "", "NICE!", "SICK!", "RADICAL!", "INSANE!", "UNREAL!", "SKETCHY...", "OUCH!", "WIPEOUT!", "BAIL!",
];

export const GRAB_NAMES: StaticArray<string> = ["", "INDY", "MELON", "METHOD", "MUTE"];
export const FLIP_NAMES: StaticArray<string> = ["", "FRONT FLIP", "BACKFLIP", "DOUBLE FRONT FLIP", "DOUBLE BACKFLIP"];
export const GRIND_NAMES: StaticArray<string> = ["", "50-50", "BOARDSLIDE", "LOG SLIDE"];
export const GRADE_LETTERS: StaticArray<string> = ["C", "B", "A", "S"];
export const SCHEME_NAMES: StaticArray<string> = ["HOT PINK", "ACID", "BLAZE"];

// Initials characters: 0 space, 1..26 A..Z, 27..36 0..9, 37 "!".
export const INITIAL_COUNT: i32 = 38;

export function initialChar(c: i32): string {
    if (c >= 1 && c <= 26) return String.fromCharCode(64 + c);
    if (c >= 27 && c <= 36) return String.fromCharCode(48 + c - 27);
    if (c == 37) return "!";
    return " ";
}

// A key code (GLFW, as KeyboardEvent.key) -> an initials character, -1 none.
export function initialOfKey(key: i32): i32 {
    if (key >= 65 && key <= 90) return key - 64;
    if (key >= 48 && key <= 57) return key - 48 + 27;
    if (key >= 320 && key <= 329) return key - 320 + 27;
    if (key == 32) return 0;
    return -1;
}

export function unpackInitial(packed: i32, slot: i32): i32 {
    if (slot == 0) return (packed >> 12) & 63;
    if (slot == 1) return (packed >> 6) & 63;
    return packed & 63;
}

export function packInitials(c0: i32, c1: i32, c2: i32): i32 {
    return c0 * 4096 + c1 * 64 + c2;
}

export function initialsText(packed: i32): string {
    return initialChar(unpackInitial(packed, 0)) + initialChar(unpackInitial(packed, 1)) + initialChar(unpackInitial(packed, 2));
}

// "2,450"; negative numbers keep their sign.
export function commas(value: f64): string {
    let n = <i64>Math.round(value);
    let neg = n < 0;
    if (neg) n = -n;
    let s = n.toString();
    let out = "";
    let len = s.length;
    for (let i = 0; i < len; i++) {
        if (i > 0 && (len - i) % 3 == 0) out += ",";
        out += s.charAt(i);
    }
    return neg ? "-" + out : out;
}

// One decimal: "2.4".
export function oneDecimal(value: f64): string {
    let tenths = <i64>Math.round(value * 10);
    if (tenths < 0) tenths = 0;
    return (tenths / 10).toString() + "." + (tenths % 10).toString();
}

// The trick's name (docs/TRICKS.md, section 2):
// [SWITCH] [FRONTSIDE | BACKSIDE] [FLIP] [SPIN] [GRAB [TO GRAB]], or a grind:
// [KINKED | RAINBOW] 50-50 | BOARDSLIDE | LOG SLIDE.
export function trickName(spin: i32, dir: i32, flip: i32, grab1: i32, grab2: i32, isSwitch: bool, grind: i32): string {
    let parts = "";
    if (grind > 0) {
        let kind = grind % 10;
        let mod = grind / 10;
        if (mod == 1) parts = "KINKED ";
        else if (mod == 2) parts = "RAINBOW ";
        if (kind >= 1 && kind <= 3) return parts + GRIND_NAMES[kind];
        return parts + "GRIND";
    }
    if (isSwitch) parts = "SWITCH";
    if (spin >= 180) {
        if (dir == 1) parts = join(parts, "FRONTSIDE");
        else if (dir == 2) parts = join(parts, "BACKSIDE");
    }
    if (flip >= 1 && flip <= 4) parts = join(parts, FLIP_NAMES[flip]);
    if (spin >= 180) parts = join(parts, spin.toString());
    if (grab1 >= 1 && grab1 <= 4) {
        parts = join(parts, GRAB_NAMES[grab1]);
        if (grab2 >= 1 && grab2 <= 4 && grab2 != grab1) parts = join(parts, "TO " + GRAB_NAMES[grab2]);
    }
    if (parts.length == 0 || parts == "SWITCH") parts = join(parts, "AIR");
    return parts;
}

function join(a: string, b: string): string {
    return a.length == 0 ? b : a + " " + b;
}
