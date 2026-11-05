// Numbers of the data form, written and read in place.
//
// Writing: an f32 is displayF32 (the shortest decimal that reads back to
// the same f32, never an exponent, `-0` kept, `NaN`, `inf`, `-inf`), an
// integer is decimal.
//
// Reading: a NumScanner walks a range of a line (an array token's inside,
// or a one-number value) and hands out one number per call, parsed from the
// line's characters where they are: no substring, no token, no Result per
// number. The stub runtime never frees, so a mesh line of a million numbers
// read through parseF32 (which builds big integers for every number) would
// cost hundreds of bytes a number for nothing.
//
// An f32 is exact all the same. The common case, at most 19 significant
// digits and a decimal exponent within 22, is Clinger's fast path: the
// digits are an exact f64 integer below 2^53 and 10^k (k <= 22) is an exact
// f64, so one f64 multiply or divide is the correctly rounded f64 of the
// decimal; rounding that f64 to f32 is then the correctly rounded f32
// unless the f64 sits exactly on a midpoint between two f32s (double
// rounding), or outside the f32 normal range. Those, and every other
// spelling (an exponent, `NaN`, `inf`, a long tail of digits), go to
// parseF32 on a substring: exact, and rare in what a writer writes.

import { parseF32, parseU64 } from "../../../../base/parse";
import { displayF32 } from "../../../../base/fmt";
import { i64FitsI32 } from "../../../../base/util";

const C_SPACE: i32 = 0x20;
const C_TAB: i32 = 0x09;
const C_MINUS: i32 = 0x2D;
const C_PLUS: i32 = 0x2B;
const C_DOT: i32 = 0x2E;
const C_0: i32 = 0x30;
const C_9: i32 = 0x39;

// 10^0 .. 10^22, each exact in an f64.
const POW10: StaticArray<f64> = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
];

// 2^53: the integers below it are exact in an f64.
const EXACT_F64: u64 = 9007199254740992;

// An f32 as the data form writes it.
export function f32Text(x: f32): string {
    return displayF32(x);
}

// Whether two f32s are the same bits: the writer leaves a field out only
// when it is bit for bit the default, so `-0` and a NaN payload never
// pass for `0` or the default NaN.
export function sameF32(a: f32, b: f32): bool {
    return reinterpret<u32>(a) == reinterpret<u32>(b);
}

const C_LF: i32 = 0x0A;
const C_CR: i32 = 0x0D;
const C_COMMA: i32 = 0x2C;

function isSep(c: i32): bool {
    return c == C_SPACE || c == C_TAB;
}

// A separator of comma mode: a comma or any XML whitespace.
function isCommaSep(c: i32): bool {
    return c == C_SPACE || c == C_TAB || c == C_COMMA || c == C_LF || c == C_CR;
}

// Reads the numbers of `src[start, end)`, separated by spaces or tabs, or
// in comma mode (`comma`, an .rmdl document's values: `0.5, -0, nan`) by
// commas, spaces, tabs and line ends. `nan`, `inf` and `-inf` read as
// parseF32 reads them in either mode.
// Each next*() reads one; a malformed or missing number sets `failed` and
// `error` (the first failure wins) and returns 0. `count()` says how many
// numbers the range holds, without parsing them, so a reader can check a
// length before it allocates.
export class NumScanner {
    src: string;
    pos: i32;
    end: i32;
    failed: bool = false;
    error: string = "";
    // Commas and line ends separate too (see the class's header).
    comma: bool = false;

    constructor(src: string, start: i32, end: i32) {
        this.src = src;
        this.pos = start;
        this.end = end;
    }

    private sep(c: i32): bool {
        return this.comma ? isCommaSep(c) : isSep(c);
    }

    // How many numbers are left.
    count(): i32 {
        let n = 0;
        let i = this.pos;
        const e = this.end;
        const s = this.src;
        while (i < e) {
            while (i < e && this.sep(s.charCodeAt(i))) i++;
            if (i >= e) break;
            n++;
            while (i < e && !this.sep(s.charCodeAt(i))) i++;
        }
        return n;
    }

    // Whether only separators are left.
    atEnd(): bool {
        let i = this.pos;
        while (i < this.end && this.sep(this.src.charCodeAt(i))) i++;
        return i >= this.end;
    }

    private fail(message: string): void {
        if (!this.failed) {
            this.failed = true;
            this.error = message;
        }
    }

    // The next word's range, [a, b) in this.a / this.b; false at the end.
    private a: i32 = 0;
    private b: i32 = 0;

    private word(): bool {
        let i = this.pos;
        const e = this.end;
        const s = this.src;
        while (i < e && this.sep(s.charCodeAt(i))) i++;
        if (i >= e) {
            this.pos = i;
            this.fail("too few numbers");
            return false;
        }
        const a = i;
        while (i < e && !this.sep(s.charCodeAt(i))) i++;
        this.a = a;
        this.b = i;
        this.pos = i;
        return true;
    }

    private bad(what: string): void {
        this.fail("`" + this.src.substring(this.a, this.b) + "` is not " + what);
    }

    nextF32(): f32 {
        if (this.failed || !this.word()) return 0;
        const s = this.src;
        const a = this.a;
        const b = this.b;
        let i = a;
        let neg = false;
        const c0 = s.charCodeAt(i);
        if (c0 == C_MINUS || c0 == C_PLUS) {
            neg = c0 == C_MINUS;
            i++;
        }
        let m: u64 = 0;
        let sig = 0; // significant digits taken into m
        let exp10 = 0; // m * 10^exp10 is the value
        let digits = 0;
        let fast = true;
        while (i < b) {
            const c = s.charCodeAt(i);
            if (c < C_0 || c > C_9) break;
            digits++;
            if (sig > 0 || c != C_0) {
                if (sig < 19) {
                    m = m * 10 + <u64>(c - C_0);
                    sig++;
                } else {
                    fast = false;
                }
            }
            i++;
        }
        if (i < b && s.charCodeAt(i) == C_DOT) {
            i++;
            while (i < b) {
                const c = s.charCodeAt(i);
                if (c < C_0 || c > C_9) break;
                digits++;
                if (sig > 0 || c != C_0) {
                    if (sig < 19) {
                        m = m * 10 + <u64>(c - C_0);
                        sig++;
                        exp10--;
                    } else {
                        fast = false;
                    }
                } else {
                    exp10--;
                }
                i++;
            }
        }
        if (i != b || digits == 0) fast = false;
        if (fast) {
            if (m == 0) {
                const z: f32 = 0;
                return neg ? -z : z;
            }
            if (m < EXACT_F64 && exp10 >= -22 && exp10 <= 22) {
                let d = <f64>m;
                d = exp10 < 0 ? d / POW10[-exp10] : d * POW10[exp10];
                const bits = reinterpret<u64>(d);
                const e = <i32>((bits >> 52) & 0x7FF) - 1023;
                // Inside the f32 normal range and not on an f32 midpoint
                // (the 29 bits an f32 drops are exactly 1000...0).
                if (e >= -126 && e <= 127 && (bits & 0x1FFFFFFF) != 0x10000000) {
                    const f = <f32>d;
                    return neg ? -f : f;
                }
            }
        }
        const r = parseF32(s.substring(a, b));
        if (!r.ok) {
            this.bad("a number");
            return 0;
        }
        return r.value;
    }

    // A non-negative integer below 2^32.
    nextU32(): u32 {
        if (this.failed || !this.word()) return 0;
        const s = this.src;
        let v: u64 = 0;
        for (let i = this.a; i < this.b; i++) {
            const c = s.charCodeAt(i);
            if (c < C_0 || c > C_9) {
                this.bad("a whole number");
                return 0;
            }
            v = v * 10 + <u64>(c - C_0);
            if (v > <u64>u32.MAX_VALUE) {
                this.bad("a whole number below 2^32");
                return 0;
            }
        }
        return <u32>v;
    }

    // An integer in i32's range.
    nextI32(): i32 {
        if (this.failed || !this.word()) return 0;
        const s = this.src;
        let i = this.a;
        let neg = false;
        const c0 = s.charCodeAt(i);
        if (c0 == C_MINUS || c0 == C_PLUS) {
            neg = c0 == C_MINUS;
            i++;
        }
        if (i >= this.b) {
            this.bad("an integer");
            return 0;
        }
        let v: i64 = 0;
        for (; i < this.b; i++) {
            const c = s.charCodeAt(i);
            if (c < C_0 || c > C_9) {
                this.bad("an integer");
                return 0;
            }
            v = v * 10 + <i64>(c - C_0);
            if (!i64FitsI32(neg ? -v : v)) {
                this.bad("an integer in 32 bits");
                return 0;
            }
        }
        return <i32>(neg ? -v : v);
    }

    // A non-negative integer below 2^64.
    nextU64(): u64 {
        if (this.failed || !this.word()) return 0;
        const r = parseU64(this.src.substring(this.a, this.b));
        if (!r.ok) {
            this.bad("a whole number below 2^64");
            return 0;
        }
        return r.value;
    }

    // 0 or 1, as a bool.
    nextBit(): bool {
        const v = this.nextU32();
        if (this.failed) return false;
        if (v > 1) {
            this.bad("0 or 1");
            return false;
        }
        return v == 1;
    }
}
