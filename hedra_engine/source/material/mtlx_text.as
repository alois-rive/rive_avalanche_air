// Numbers as a MaterialX document writes them (milestone 14), for the
// reader (mtlx.as) and the writer (mtlx_write.as): the shortest decimal
// that reads back as the same f32 ("0.85", not "0.8500000238"), lists
// joined by ", ", and an angle in degrees chosen so that it reads back as
// the same f32 in radians (MaterialX's texture nodes rotate by degrees,
// glTF's KHR_texture_transform by radians).

import { displayF32, displayF64, fixedF64 } from "../../base/fmt";
import { parseF32, parseF64, parseI32 } from "../../base/parse";

// One number.
export function mtlxNumber(x: f32): string {
    return displayF32(x);
}

// A list of numbers, as MaterialX writes a color3 or a vector2: "1, 0.5, 0".
export function mtlxNumbers(a: Array<f32>): string {
    const out = new Array<string>();
    for (let k = 0; k < a.length; k++) out.push(displayF32(a[k]));
    return out.join(", ");
}

const DEG_PER_RAD: f64 = 180.0 / Math.PI;
const RAD_PER_DEG: f64 = Math.PI / 180.0;

// `rad` in degrees, the shortest text `radiansOf` reads back as `rad`
// exactly: the f32 of the degrees when that is enough ("90" for a quarter
// turn), else the f64's own digits, which always are.
export function mtlxDegrees(rad: f32): string {
    const deg = <f64>rad * DEG_PER_RAD;
    // The fewest decimals that read back (the reader parses the text as an
    // f64, so the check does too): "90", "17.90493", not the f64's 17
    // digits, which always do.
    for (let d = 0; d <= 12; d++) {
        const t = trimZeros(fixedF64(deg, d));
        if (radiansOf(parseDouble(t)) == rad) return t;
    }
    return displayF64(deg);
}

// "12.500" -> "12.5", "3.000" -> "3", "-0.000" -> "-0".
function trimZeros(t: string): string {
    if (t.indexOf(".") < 0) return t;
    let n = t.length;
    while (n > 0 && t.charCodeAt(n - 1) == 48) n--;
    if (n > 0 && t.charCodeAt(n - 1) == 46) n--;
    return t.substring(0, n);
}

// A rotation written in degrees, in radians as an f32.
export function radiansOf(deg: f64): f32 {
    return <f32>(deg * RAD_PER_DEG);
}

// The components of a MaterialX number list ("1, 0.5,0"): `count` f32s,
// each read once from its decimal text, or null when the text is not
// exactly that many numbers.
export function parseFloats(text: string, count: i32): Array<f32>? {
    const parts = text.split(",");
    if (parts.length != count) return null;
    const out = new Array<f32>();
    for (let k = 0; k < parts.length; k++) {
        const t = parts[k].trim();
        if (!plainNumber(t)) return null;
        const r = parseF32(t);
        // "1e39" reads as an f32 inf, which would be written back as "inf",
        // a text this reader refuses: out of range is not a number here
        if (!r.ok || !isFinite(r.value)) return null;
        out.push(r.value);
    }
    return out;
}

// One number read as an f64 (the degrees of a rotation), or NaN when the
// text is not one.
export function parseDouble(text: string): f64 {
    const t = text.trim();
    if (!plainNumber(t)) return NaN;
    const r = parseF64(t);
    return r.ok && isFinite(r.value) ? r.value : NaN;
}

// What parseInteger gives for a text that is not an integer.
export const NOT_AN_INTEGER: i64 = i64.MIN_VALUE;

// An integer ("2"), or NOT_AN_INTEGER.
export function parseInteger(text: string): i64 {
    const t = text.trim();
    if (t.length == 0) return NOT_AN_INTEGER;
    const r = parseI32(t);
    if (!r.ok) return NOT_AN_INTEGER;
    return <i64>r.value;
}

// A decimal number as MaterialX writes one: an optional sign, digits with
// at most one point, an optional exponent; no "inf" or "nan", which
// MaterialX has no words for.
function plainNumber(t: string): bool {
    const n = t.length;
    let k = 0;
    if (k < n && (t.charCodeAt(k) == 43 || t.charCodeAt(k) == 45)) k++;
    let digits = 0;
    let point = false;
    for (; k < n; k++) {
        const c = t.charCodeAt(k);
        if (c >= 48 && c <= 57) digits++;
        else if (c == 46 && !point) point = true;
        else break;
    }
    if (digits == 0) return false;
    if (k < n && (t.charCodeAt(k) == 101 || t.charCodeAt(k) == 69)) {
        k++;
        if (k < n && (t.charCodeAt(k) == 43 || t.charCodeAt(k) == 45)) k++;
        let e = 0;
        for (; k < n; k++) {
            const c = t.charCodeAt(k);
            if (c < 48 || c > 57) break;
            e++;
        }
        if (e == 0) return false;
    }
    return k == n;
}

// Two whole numbers in lo..hi written as a MaterialX vector2 ("1024, 512";
// "1024.0, 512" too, as a vector2 reads it), or null when the text is not
// two numbers, either is not whole or either is out of range (milestone 15:
// an artboard texture's rive_size).
export function parseWholePair(text: string, lo: i32, hi: i32): StaticArray<i32>? {
    const v = parseFloats(text, 2);
    if (v == null) return null;
    const out = new StaticArray<i32>(2);
    for (let k = 0; k < 2; k++) {
        const x = v[k];
        if (x != Mathf.floor(x) || x < <f32>lo || x > <f32>hi) return null;
        out[k] = <i32>x;
    }
    return out;
}
