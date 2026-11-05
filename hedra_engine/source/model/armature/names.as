// Blender's side-name rules
// (`BLI_string_flip_side_name`): `.L` <-> `.R` and friends, with a trailing
// `.001` number kept in place.
//
// Names are sliced by UTF-16 index at ASCII separators, so non-ASCII
// characters are never split.

import { toAsciiLowercase } from "../../../base/util";

// Flip the side of a name: `UpperArm.L` -> `UpperArm.R`, `L_Hand` ->
// `R_Hand`, `Left.Leg.001` -> `Right.Leg.001`. Names without a side
// marker come back unchanged.
export function flipSideName(name: string): string {
    const stem = splitNumberStem(name);
    const number = name.substring(stem.length);
    let flipped = flipSuffix(stem);
    if (flipped == null) flipped = flipPrefix(stem);
    if (flipped != null) return flipped + number;
    return name;
}

// True when the name carries a left or right marker.
export function hasSide(name: string): bool {
    return flipSideName(name) != name;
}

// `Name.001` -> `Name` (the number part is the rest of the string, `.001`).
function splitNumberStem(name: string): string {
    const i = name.lastIndexOf(".");
    if (i >= 0) {
        const tail = name.substring(i + 1);
        if (tail.length > 0 && allAsciiDigits(tail)) return name.substring(0, i);
    }
    return name;
}

function allAsciiDigits(s: string): bool {
    for (let k = 0; k < s.length; k++) {
        const c = s.charCodeAt(k);
        if (c < 48 || c > 57) return false;
    }
    return true;
}

const SEPARATORS: Array<string> = [".", "_", "-", " "];

// null = not a side word.
function flipWord(w: string): string? {
    if (w == "L") return "R";
    if (w == "R") return "L";
    if (w == "l") return "r";
    if (w == "r") return "l";
    if (w == "Left") return "Right";
    if (w == "Right") return "Left";
    if (w == "left") return "right";
    if (w == "right") return "left";
    if (w == "LEFT") return "RIGHT";
    if (w == "RIGHT") return "LEFT";
    return null;
}

const GLUED_WORDS: Array<string> = ["Left", "Right", "left", "right"];
const GLUED_OTHERS: Array<string> = ["Right", "Left", "right", "left"];

function flipSuffix(stem: string): string? {
    for (let s = 0; s < SEPARATORS.length; s++) {
        const sep = SEPARATORS[s];
        const i = stem.lastIndexOf(sep);
        if (i > 0) {
            const f = flipWord(stem.substring(i + 1));
            if (f != null) return stem.substring(0, i) + sep + f;
        }
    }
    for (let k = 0; k < GLUED_WORDS.length; k++) {
        const word = GLUED_WORDS[k];
        if (stem.endsWith(word)) {
            const base = stem.substring(0, stem.length - word.length);
            if (base.length > 0) return base + GLUED_OTHERS[k];
        }
    }
    return null;
}

function flipPrefix(stem: string): string? {
    for (let s = 0; s < SEPARATORS.length; s++) {
        const sep = SEPARATORS[s];
        const i = stem.indexOf(sep);
        if (i > 0 && i + 1 < stem.length) {
            const f = flipWord(stem.substring(0, i));
            if (f != null) return f + sep + stem.substring(i + 1);
        }
    }
    for (let k = 0; k < GLUED_WORDS.length; k++) {
        const word = GLUED_WORDS[k];
        if (stem.startsWith(word)) {
            const rest = stem.substring(word.length);
            if (rest.length > 0) return GLUED_OTHERS[k] + rest;
        }
    }
    return null;
}

// What sideOf returns.
export enum Side {
    None = -1,
    Right = 0,
    Left = 1,
}

// Which side a name is on, by its marker: Side.Left, Side.Right or Side.None.

export function sideOf(name: string): Side {
    const stem = splitNumberStem(name);
    const lower = toAsciiLowercase(stem);
    for (let s = 0; s < SEPARATORS.length; s++) {
        const sep = SEPARATORS[s];
        const r = lower.lastIndexOf(sep);
        if (r >= 0) {
            const w = lower.substring(r + 1);
            if (w == "l" || w == "left") return Side.Left;
            if (w == "r" || w == "right") return Side.Right;
        }
        const f = lower.indexOf(sep);
        if (f >= 0) {
            const w = lower.substring(0, f);
            if (w == "l" || w == "left") return Side.Left;
            if (w == "r" || w == "right") return Side.Right;
        }
    }
    if (lower.endsWith("left") || lower.startsWith("left")) return Side.Left;
    if (lower.endsWith("right") || lower.startsWith("right")) return Side.Right;
    return Side.None;
}

// Blender's "AutoName Left/Right": append `.L` or `.R` by the sign of a
// coordinate, replacing an existing marker.
export function autoSideName(name: string, left: bool): string {
    const stem = splitNumberStem(name);
    const number = name.substring(stem.length);
    const base = stripSide(stem);
    return base + "." + (left ? "L" : "R") + number;
}

function stripSide(stem: string): string {
    for (let s = 0; s < SEPARATORS.length; s++) {
        const sep = SEPARATORS[s];
        const i = stem.lastIndexOf(sep);
        if (i > 0 && flipWord(stem.substring(i + 1)) != null) {
            return stem.substring(0, i);
        }
    }
    return stem;
}
