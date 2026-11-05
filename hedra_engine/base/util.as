// Shared foundation for every module: errors as values, panics, saturating
// numeric casts, rounding, min/max and comparators, a stable sort and array
// helpers, map lookup with a default, the splitmix64 PRNG, FNV-1a 64 hashing,
// Unicode-aware string helpers (trim, whitespace split, ASCII case) and a
// string builder. Number parsing lives in parse.as.
//
// See ENGINEERING.md for when to use each helper. Keep this module small:
// formatting lives in fmt.as, vector math in vecmath.as, JSON in json.as.

import { RtNative } from "rive/natives";

// ---------------------------------------------------------------------------
// panic

// The message of the most recent panic(). A trap does not reset module
// state, so the next test case (or the host) can still read it.
export let lastPanic: string = "";

// Forgets the last panic (a new run of the command in the same instance).
export function clearLastPanic(): void {
    lastPanic = "";
}

// What panic() calls just before it traps: the host session installs one
// that tells the host (`stderr` and `abort 101`, CONTRACT.md §13), because
// after the trap the program cannot say anything. It is called once: it is
// removed before it runs, so a panic inside it traps without calling it
// again.
export abstract class PanicHook {
    abstract onPanic(message: string): void;
}

let panicHook: PanicHook? = null;

// Installs `h` (null removes the hook).
export function setPanicHook(h: PanicHook?): void {
    panicHook = h;
}

unsafe function logToHost(message: string): void {
    RtNative.log(0, message);
}

// Aborts on a broken invariant or an impossible state: records the message,
// logs "panic: <msg>" to the host (stdout under `rive --test`, the runtime
// log in a CLI run), hands it to the panic hook if one is installed, then
// traps. It never returns.
export function panic(msg: string): void {
    lastPanic = msg;
    logToHost("panic: " + msg);
    const h = panicHook;
    if (h != null) {
        panicHook = null;
        h.onPanic(msg);
    }
    unreachable();
}

// panic() usable where a value of type T is expected:
// `return panicAs<Mesh>("dangling element id");`
export function panicAs<T>(msg: string): T {
    panic(msg);
    return unreachable();
}

// ---------------------------------------------------------------------------
// Result

// Base class for a typed error payload, e.g. CoreError. toString() is the
// user-visible message and becomes Result.err.
export abstract class ErrorValue {
    abstract toString(): string;
}

// A value or an error. `ok` says which side is set. On failure `err` holds
// the message and `cause` the typed error (null for plain string
// errors). `value` is left uninitialised on
// failure: never read it without checking `ok` (declared with `!`, since
// no constructor assigns it: rive 1.6's lint refuses a field that is not
// nullable, has no initialiser and is assigned by no constructor).
//
//   const r = parse(src);
//   if (!r.ok) return r.forward<Mesh>();      // propagate the error
//   const v = r.value;
export class Result<T> {
    ok: bool = false;
    value!: T;
    err: string = "";
    cause: ErrorValue? = null;

    static okv<T>(v: T): Result<T> {
        const r = new Result<T>();
        r.ok = true;
        r.value = v;
        return r;
    }

    // A failure with a plain message.
    static fail<T>(msg: string): Result<T> {
        const r = new Result<T>();
        r.err = msg;
        return r;
    }

    // Err with a typed error; err is its toString().
    static failWith<T>(e: ErrorValue): Result<T> {
        const r = new Result<T>();
        r.err = e.toString();
        r.cause = e;
        return r;
    }

    // Re-types a failed result for propagation. Panics on Ok.
    forward<U>(): Result<U> {
        if (this.ok) panic("Result.forward called on Ok");
        const r = new Result<U>();
        r.err = this.err;
        r.cause = this.cause;
        return r;
    }

    unwrap(): T {
        if (!this.ok) panic("called `Result::unwrap()` on an `Err` value: " + this.err);
        return this.value;
    }

    expect(msg: string): T {
        if (!this.ok) panic(msg + ": " + this.err);
        return this.value;
    }

    unwrapOr(dflt: T): T {
        return this.ok ? this.value : dflt;
    }
}

// ---------------------------------------------------------------------------
// Casts from floats: saturate at the target range, NaN -> 0.
// (A plain `<i32>x` traps on NaN or out-of-range values.)

export function f64ToI32(x: f64): i32 {
    if (isNaN(x)) return 0;
    if (x >= 2147483647.0) return i32.MAX_VALUE;
    if (x <= -2147483648.0) return i32.MIN_VALUE;
    return <i32>x;
}

export function f64ToU32(x: f64): u32 {
    if (!(x > 0.0)) return 0;
    if (x >= 4294967295.0) return u32.MAX_VALUE;
    return <u32>x;
}

export function f64ToI64(x: f64): i64 {
    if (isNaN(x)) return 0;
    if (x >= 9223372036854775807.0) return i64.MAX_VALUE; // 2^63
    if (x <= -9223372036854775808.0) return i64.MIN_VALUE;
    return <i64>x;
}

export function f64ToU64(x: f64): u64 {
    if (!(x > 0.0)) return 0;
    if (x >= 18446744073709551615.0) return u64.MAX_VALUE; // 2^64
    return <u64>x;
}

export function f64ToU8(x: f64): u8 {
    if (!(x > 0.0)) return 0;
    if (x >= 255.0) return 255;
    return <u8><i32>x;
}

export function f64ToU16(x: f64): u16 {
    if (!(x > 0.0)) return 0;
    if (x >= 65535.0) return 65535;
    return <u16><i32>x;
}

// f32 -> f64 is exact, so the f32 casts share the f64 saturation bounds.
export function f32ToI32(x: f32): i32 { return f64ToI32(<f64>x); }
export function f32ToU32(x: f32): u32 { return f64ToU32(<f64>x); }
export function f32ToI64(x: f32): i64 { return f64ToI64(<f64>x); }
export function f32ToU64(x: f32): u64 { return f64ToU64(<f64>x); }
export function f32ToU8(x: f32): u8 { return f64ToU8(<f64>x); }
export function f32ToU16(x: f32): u16 { return f64ToU16(<f64>x); }

// ---------------------------------------------------------------------------
// i64 to the 32-bit ranges: whether it fits, and saturated at the range.
//
// Each is a round trip (wrap to 32 bits, widen back, compare with the i64)
// and a sign test against 0, never an i64 compared with i32's or u32's
// bounds (`x < <i64>i32.MIN_VALUE`, `x > 4294967295`). Safari 26.6.2's
// JavaScriptCore (macOS, Apple silicon) ran the bounds form wrong in a
// whole Hedra module: Value.asI32, then written
//     if (this.i > <i64>i32.MAX_VALUE) return i32.MAX_VALUE;
//     if (this.i < <i64>i32.MIN_VALUE) return i32.MIN_VALUE;
// returned i32.MIN_VALUE for an Int of 1 whose asI64 was 1, so every enum
// property read through it (transparency, cull_mode, ...) was INT_MIN, and
// a game's particles drew opaque over its view. The module is valid:
// Chromium and Playwright's WebKit 26.6 ran it right, and a small module of
// the same two compares did not show it. The compiler emits the bounds form
// as `i32.const -2147483648; local.get; i64.const -2147483648; i64.lt_s;
// br_if` (a br_if carrying the i32 result), and the result was the one the
// compare gives with +2^31 in place of its constant: the i32 constant's 32
// bits, zero-extended. These forms compare an i64 only with itself and 0.
// Keep them so, and check an i64 against the 32-bit ranges only with them.

export function i64FitsI32(x: i64): bool {
    return <i64><i32>x == x;
}

export function i64FitsU32(x: i64): bool {
    return <i64><u32>x == x;
}

export function i64ToI32(x: i64): i32 {
    const w = <i32>x;
    if (<i64>w == x) return w;
    return x < 0 ? i32.MIN_VALUE : i32.MAX_VALUE;
}

export function i64ToU32(x: i64): u32 {
    const w = <u32>x;
    if (<i64>w == x) return w;
    return x < 0 ? 0 : u32.MAX_VALUE;
}

// ---------------------------------------------------------------------------
// Float rounding and sign. Math.round / Mathf.round are JS-style
// (-1.5 -> -1); Mathf.sign(0) is 0. Use these instead.

// Rounds half away from zero, keeps the sign of zero.
export function roundF32(x: f32): f32 {
    let t = Mathf.trunc(x);
    // x - trunc(x) is exact for every finite float.
    if (Mathf.abs(x - t) >= <f32>0.5) t += copysign<f32>(1.0, x);
    return t;
}

// roundF32 for f64.
export function roundF64(x: f64): f64 {
    let t = Math.trunc(x);
    if (Math.abs(x - t) >= 0.5) t += copysign<f64>(1.0, x);
    return t;
}

// Sign: 1.0 for +0.0 and positives, -1.0 for -0.0 and negatives, NaN for NaN.
export function signumF32(x: f32): f32 {
    if (isNaN(x)) return x;
    return copysign<f32>(1.0, x);
}

export function signumF64(x: f64): f64 {
    if (isNaN(x)) return x;
    return copysign<f64>(1.0, x);
}

// Min / max: when exactly one operand is NaN the other one is
// returned (Mathf.min/max return NaN). Identical to Mathf.* for non-NaN input.
export function minF32(a: f32, b: f32): f32 {
    if (isNaN(a)) return b;
    if (isNaN(b)) return a;
    return Mathf.min(a, b);
}
export function maxF32(a: f32, b: f32): f32 {
    if (isNaN(a)) return b;
    if (isNaN(b)) return a;
    return Mathf.max(a, b);
}
export function minF64(a: f64, b: f64): f64 {
    if (isNaN(a)) return b;
    if (isNaN(b)) return a;
    return Math.min(a, b);
}
export function maxF64(a: f64, b: f64): f64 {
    if (isNaN(a)) return b;
    if (isNaN(b)) return a;
    return Math.max(a, b);
}

// Clamp: NaN stays NaN. lo > hi or a NaN bound is not checked (modules
// that must panic on those define a local clampF32Checked).
export function clampF32(x: f32, lo: f32, hi: f32): f32 {
    let r = x;
    if (r < lo) r = lo;
    if (r > hi) r = hi;
    return r;
}
export function clampF64(x: f64, lo: f64, hi: f64): f64 {
    let r = x;
    if (r < lo) r = lo;
    if (r > hi) r = hi;
    return r;
}

// ---------------------------------------------------------------------------
// Comparators (for stableSort / Array.sort): negative, 0 or positive.

// Total order: -NaN < -inf < ... < -0.0 < +0.0 < ... < inf < NaN.
export function totalCmpF32(a: f32, b: f32): i32 {
    let l = reinterpret<i32>(a);
    let r = reinterpret<i32>(b);
    l ^= <i32>(<u32>(l >> 31) >>> 1);
    r ^= <i32>(<u32>(r >> 31) >>> 1);
    return l < r ? -1 : (l > r ? 1 : 0);
}
export function totalCmpF64(a: f64, b: f64): i32 {
    let l = reinterpret<i64>(a);
    let r = reinterpret<i64>(b);
    l ^= <i64>(<u64>(l >> 63) >>> 1);
    r ^= <i64>(<u64>(r >> 63) >>> 1);
    return l < r ? -1 : (l > r ? 1 : 0);
}

// Partial order with a fallback: NaN compares equal to everything, and
// -0.0 == +0.0. Check for NaN yourself where NaN must be an error.
export function partialCmpF32(a: f32, b: f32): i32 {
    return a < b ? -1 : (a > b ? 1 : 0);
}
export function partialCmpF64(a: f64, b: f64): i32 {
    return a < b ? -1 : (a > b ? 1 : 0);
}

// String order for sorted keys: byte-wise
// UTF-8 order, which is code point order. JS `<` and the default
// Array<string>.sort() compare UTF-16 units, which put U+E000..U+FFFF after
// astral characters (emoji); this does not.
export function cmpStr(a: string, b: string): i32 {
    const n = min(a.length, b.length);
    for (let i = 0; i < n; i++) {
        const x = a.charCodeAt(i);
        const y = b.charCodeAt(i);
        if (x == y) continue;
        // A surrogate (0xD800..0xDFFF) starts a code point above 0xFFFF, which
        // sorts after every BMP code point, including U+E000..U+FFFF.
        const xs = x >= 0xD800 && x <= 0xDFFF;
        const ys = y >= 0xD800 && y <= 0xDFFF;
        if (xs != ys) return xs ? 1 : -1;
        return x < y ? -1 : 1;
    }
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

// ---------------------------------------------------------------------------
// Collections

// Removes consecutive duplicates (`==`: content equality for
// strings and numbers, identity for classes without operator==) in place.
export function dedup<T>(a: Array<T>): void {
    const n = a.length;
    if (n < 2) return;
    let w = 1;
    for (let i = 1; i < n; i++) {
        if (a[i] != a[w - 1]) {
            a[w] = a[i];
            w++;
        }
    }
    a.length = w;
}

// Removes a[i] by moving the last element into its
// slot (O(1), changes order). Panics when i is out of bounds.
export function swapRemove<T>(a: Array<T>, i: i32): T {
    if (i < 0 || i >= a.length) panic("swap_remove index (is " + i.toString() + ") should be < len (is " + a.length.toString() + ")");
    const v = a[i];
    const last = a.length - 1;
    if (i != last) a[i] = a[last];
    a.length = last;
    return v;
}

// Stable sort in place (Array.sort is not stable). cmp < 0 puts x first.
// Merge sort: O(n log n) compares, equal elements keep their order.
export function stableSort<T>(a: Array<T>, cmp: (x: T, y: T) => i32): void {
    const n = a.length;
    if (n < 2) return;
    if (n <= 16) {
        for (let i = 1; i < n; i++) {
            const v = a[i];
            let j = i - 1;
            while (j >= 0 && cmp(a[j], v) > 0) {
                a[j + 1] = a[j];
                j--;
            }
            a[j + 1] = v;
        }
        return;
    }
    let src = a.slice(0);
    let dst = a.slice(0);
    for (let width = 1; width < n; width *= 2) {
        for (let lo = 0; lo < n; lo += 2 * width) {
            const mid = min(lo + width, n);
            const hi = min(lo + 2 * width, n);
            let i = lo;
            let j = mid;
            let k = lo;
            while (i < mid && j < hi) {
                if (cmp(src[j], src[i]) < 0) {
                    dst[k] = src[j];
                    j++;
                } else {
                    dst[k] = src[i];
                    i++;
                }
                k++;
            }
            while (i < mid) { dst[k] = src[i]; i++; k++; }
            while (j < hi) { dst[k] = src[j]; j++; k++; }
        }
        const t = src;
        src = dst;
        dst = t;
    }
    for (let i = 0; i < n; i++) a[i] = src[i];
}

// m.get(k) traps on a missing key; this returns dflt instead.
export function getOr<K, V>(m: Map<K, V>, k: K, dflt: V): V {
    return m.has(k) ? m.get(k) : dflt;
}

// ---------------------------------------------------------------------------
// Hashing and randomness (Math.random traps under rive).

// splitmix64 over `state` (Vigna's reference; seed 0 -> first 0xe220a8397b1dcdaf).
// The ops RNG (core/ops/mod.as) pre-adds the golden gamma to its seed.
export class SplitMix64 {
    state: u64;

    constructor(seed: u64) {
        this.state = seed;
    }

    nextU64(): u64 {
        this.state += 0x9E3779B97F4A7C15;
        let z = this.state;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    // Uniform in [0, 1) with 53 random bits.
    nextF64(): f64 {
        return <f64>(this.nextU64() >> 11) * (1.0 / 9007199254740992.0);
    }

    // Uniform in [0, 1) with 24 random bits: (nextU64() >> 40) / 2^24.
    nextF32(): f32 {
        return <f32>(this.nextU64() >> 40) / <f32>16777216.0;
    }
}

export const FNV64_OFFSET: u64 = 0xcbf29ce484222325;
// The standard FNV-1a 64 prime.
export const FNV64_PRIME: u64 = 0x100000001b3;
// The prime import records hash with:
// `0x1000_0000_01b3` has one hex digit more than the standard prime, and the
// hashes stored in .modeler files were made with it. Pass it to reproduce them.
export const FNV64_PRIME_MODELER: u64 = 0x1000000001b3;

// FNV-1a 64 over bytes. An import record's hash is
// `fnv1a64Bytes(b, FNV64_PRIME_MODELER)` written as 16 hex digits.
export function fnv1a64Bytes(bytes: Uint8Array, prime: u64 = FNV64_PRIME): u64 {
    let h = FNV64_OFFSET;
    for (let i = 0; i < bytes.length; i++) {
        h ^= <u64>bytes[i];
        h *= prime;
    }
    return h;
}

// FNV-1a 64 over the UTF-8 bytes of s,
// without allocating the encoded string. Lone surrogates hash as U+FFFD, as
// String.UTF8.encode would write them.
export function fnv1a64(s: string, prime: u64 = FNV64_PRIME): u64 {
    let h = FNV64_OFFSET;
    const n = s.length;
    for (let i = 0; i < n; i++) {
        let c = <u32>s.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n) {
            const d = <u32>s.charCodeAt(i + 1);
            if (d >= 0xDC00 && d <= 0xDFFF) {
                c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00);
                i++;
            } else {
                c = 0xFFFD;
            }
        } else if (c >= 0xD800 && c <= 0xDFFF) {
            c = 0xFFFD;
        }
        if (c < 0x80) {
            h = (h ^ <u64>c) * prime;
        } else if (c < 0x800) {
            h = (h ^ <u64>(0xC0 | (c >> 6))) * prime;
            h = (h ^ <u64>(0x80 | (c & 0x3F))) * prime;
        } else if (c < 0x10000) {
            h = (h ^ <u64>(0xE0 | (c >> 12))) * prime;
            h = (h ^ <u64>(0x80 | ((c >> 6) & 0x3F))) * prime;
            h = (h ^ <u64>(0x80 | (c & 0x3F))) * prime;
        } else {
            h = (h ^ <u64>(0xF0 | (c >> 18))) * prime;
            h = (h ^ <u64>(0x80 | ((c >> 12) & 0x3F))) * prime;
            h = (h ^ <u64>(0x80 | ((c >> 6) & 0x3F))) * prime;
            h = (h ^ <u64>(0x80 | (c & 0x3F))) * prime;
        }
    }
    return h;
}

// ---------------------------------------------------------------------------
// String helpers. AS `trim()` strips U+FEFF but not U+0085 (Unicode
// White_Space is the reverse), `toLowerCase()` also maps non-ASCII letters
// (and, in rive 1.5.1's std, maps 99 of them wrongly: `lowerCaseUnicode`),
// and `s.length` counts UTF-16 units; use these for user-visible text.

// `s.toLowerCase()` as rive 1.2's std gave it: the full Unicode mapping,
// final sigma included. Rive 1.5.1's std lowers 99 BMP code points wrongly
// (most Greek letters with a tonos, the Cyrillic small letters U+0450 to
// U+045F, the final sigma U+03C2, the Kelvin, Ohm and Angstrom signs, ...:
// "ας".toLowerCase() is "αҜ", so a case-blind comparison with "ΑΣ" fails);
// those come from LOWER_FIX_FROM / LOWER_FIX_TO, the rest from the std. The
// lowered string is the input unit for unit but for U+0130 (İ), which
// lowers to two units ("i̇"); anything else changing the length falls back
// to lowering code point by code point (losing only the final sigma's
// context).
//
// The pinned rive 1.6.0's std is fixed: it lowers every BMP code point as
// rive 1.2's did (all 65,536 compared under both CLIs), so the table puts
// back what the std already gives and the result is the std's. It stays
// because a vendored copy of this library may still be baked with rive
// 1.5.1, where the same text must lower the same way.
export function lowerCaseUnicode(s: string): string {
    const lower = s.toLowerCase();
    let fix = false;
    let expected = s.length;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c == 0x130) expected++;
        else if (c >= LOWER_FIX_MIN && c <= LOWER_FIX_MAX && lowerFixIndex(c) >= 0) fix = true;
    }
    if (!fix) return lower;
    let out = "";
    if (lower.length != expected) {
        for (let i = 0; i < s.length; ) {
            const cp = s.codePointAt(i);
            const n = cp > 0xFFFF ? 2 : 1;
            const k = cp <= 0xFFFF ? lowerFixIndex(cp) : -1;
            out += k >= 0 ? String.fromCharCode(<i32>unchecked(LOWER_FIX_TO[k])) : s.substring(i, i + n).toLowerCase();
            i += n;
        }
        return out;
    }
    let from = 0;
    let j = 0;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        const k = c >= LOWER_FIX_MIN && c <= LOWER_FIX_MAX ? lowerFixIndex(c) : -1;
        if (k >= 0) {
            out += lower.substring(from, j) + String.fromCharCode(<i32>unchecked(LOWER_FIX_TO[k]));
            j++;
            from = j;
        } else {
            j += c == 0x130 ? 2 : 1;
        }
    }
    return out + lower.substring(from);
}

// The code points rive 1.5.1's std lowers differently from rive 1.2's (whose
// mapping is Unicode's), in order, and what rive 1.2's gave for each (and
// rive 1.6.0's gives).
const LOWER_FIX_MIN: i32 = 0x268;
const LOWER_FIX_MAX: i32 = 0xA7C6;
const LOWER_FIX_FROM: StaticArray<u16> = [
    0x268, 0x272, 0x275, 0x287, 0x28A, 0x28B, 0x292, 0x345, 0x37F, 0x386, 0x388, 0x389, 0x38A,
    0x38C, 0x38E, 0x38F, 0x3AD, 0x3AE, 0x3AF, 0x3C2, 0x3CC, 0x3CD, 0x3CE, 0x3CF, 0x3D0, 0x3D5,
    0x3D6, 0x3D7, 0x3F1, 0x3F4, 0x3F5, 0x3F9, 0x450, 0x451, 0x452, 0x453, 0x454, 0x455, 0x456,
    0x457, 0x458, 0x459, 0x45A, 0x45B, 0x45C, 0x45D, 0x45E, 0x45F, 0x4C0, 0x1C81, 0x1C85, 0x1F76,
    0x1F77, 0x1F78, 0x1F79, 0x1F7A, 0x1F7B, 0x1F7C, 0x1F7D, 0x1FBA, 0x1FBB, 0x1FBC, 0x1FBE, 0x1FCC,
    0x1FDA, 0x1FDB, 0x1FEA, 0x1FEB, 0x1FEC, 0x1FF8, 0x1FF9, 0x1FFA, 0x1FFB, 0x1FFC, 0x2126, 0x212A,
    0x212B, 0x214E, 0x2C62, 0x2C63, 0x2C64, 0x2C6D, 0x2C6E, 0x2C6F, 0x2C70, 0x2C7E, 0x2C7F, 0xA77D,
    0xA78D, 0xA794, 0xA7AB, 0xA7AC, 0xA7AD, 0xA7B0, 0xA7B1, 0xA7B2, 0xA7C4, 0xA7C5, 0xA7C6
];
const LOWER_FIX_TO: StaticArray<u16> = [
    0x268, 0x272, 0x275, 0x287, 0x28A, 0x28B, 0x292, 0x345, 0x3F3, 0x3AC, 0x3AD, 0x3AE, 0x3AF,
    0x3CC, 0x3CD, 0x3CE, 0x3AD, 0x3AE, 0x3AF, 0x3C2, 0x3CC, 0x3CD, 0x3CE, 0x3D7, 0x3D0, 0x3D5,
    0x3D6, 0x3D7, 0x3F1, 0x3B8, 0x3F5, 0x3F2, 0x450, 0x451, 0x452, 0x453, 0x454, 0x455, 0x456,
    0x457, 0x458, 0x459, 0x45A, 0x45B, 0x45C, 0x45D, 0x45E, 0x45F, 0x4CF, 0x1C81, 0x1C85, 0x1F76,
    0x1F77, 0x1F78, 0x1F79, 0x1F7A, 0x1F7B, 0x1F7C, 0x1F7D, 0x1F70, 0x1F71, 0x1FB3, 0x1FBE, 0x1FC3,
    0x1F76, 0x1F77, 0x1F7A, 0x1F7B, 0x1FE5, 0x1F78, 0x1F79, 0x1F7C, 0x1F7D, 0x1FF3, 0x3C9, 0x6B,
    0xE5, 0x214E, 0x26B, 0x1D7D, 0x27D, 0x251, 0x271, 0x250, 0x252, 0x23F, 0x240, 0x1D79, 0x265,
    0xA794, 0x25C, 0x261, 0x26C, 0x29E, 0x287, 0x29D, 0xA794, 0x282, 0x1D8E
];

// The index of `c` in LOWER_FIX_FROM, or -1.
function lowerFixIndex(c: i32): i32 {
    let lo = 0;
    let hi = LOWER_FIX_FROM.length - 1;
    while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        const v = <i32>unchecked(LOWER_FIX_FROM[mid]);
        if (v == c) return mid;
        if (v < c) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

// Unicode White_Space.
export function isUnicodeWhitespace(c: i32): bool {
    return (c >= 0x09 && c <= 0x0D) || c == 0x20 || c == 0x85 || c == 0xA0 || c == 0x1680
        || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;
}

// Trims Unicode White_Space from both ends / the start / the end.
export function trimUnicode(s: string): string {
    let a = 0;
    let b = s.length;
    while (a < b && isUnicodeWhitespace(s.charCodeAt(a))) a++;
    while (b > a && isUnicodeWhitespace(s.charCodeAt(b - 1))) b--;
    return a == 0 && b == s.length ? s : s.substring(a, b);
}
export function trimStartUnicode(s: string): string {
    let a = 0;
    while (a < s.length && isUnicodeWhitespace(s.charCodeAt(a))) a++;
    return a == 0 ? s : s.substring(a);
}
export function trimEndUnicode(s: string): string {
    let b = s.length;
    while (b > 0 && isUnicodeWhitespace(s.charCodeAt(b - 1))) b--;
    return b == s.length ? s : s.substring(0, b);
}

// The non-empty runs between Unicode whitespace.
export function splitUnicodeWhitespace(s: string): Array<string> {
    const out: Array<string> = [];
    const n = s.length;
    let i = 0;
    while (i < n) {
        while (i < n && isUnicodeWhitespace(s.charCodeAt(i))) i++;
        const start = i;
        while (i < n && !isUnicodeWhitespace(s.charCodeAt(i))) i++;
        if (i > start) out.push(s.substring(start, i));
    }
    return out;
}

// ASCII case mapping (only A-Z / a-z change).
export function toAsciiLowercase(s: string): string {
    const n = s.length;
    let i = 0;
    while (i < n) {
        const c = s.charCodeAt(i);
        if (c >= 65 && c <= 90) break;
        i++;
    }
    if (i == n) return s;
    const parts: Array<string> = [s.substring(0, i)];
    for (; i < n; i++) {
        const c = s.charCodeAt(i);
        parts.push(String.fromCharCode(c >= 65 && c <= 90 ? c + 32 : c));
    }
    return parts.join("");
}
export function toAsciiUppercase(s: string): string {
    const n = s.length;
    let i = 0;
    while (i < n) {
        const c = s.charCodeAt(i);
        if (c >= 97 && c <= 122) break;
        i++;
    }
    if (i == n) return s;
    const parts: Array<string> = [s.substring(0, i)];
    for (; i < n; i++) {
        const c = s.charCodeAt(i);
        parts.push(String.fromCharCode(c >= 97 && c <= 122 ? c - 32 : c));
    }
    return parts.join("");
}

// The UTF-8 byte length (s.length counts UTF-16 units).
export function utf8Len(s: string): i32 {
    return String.UTF8.byteLength(s);
}

// ---------------------------------------------------------------------------
// String building. `s += x` in a loop is quadratic; collect parts and join once.

export class StringBuilder {
    parts: Array<string> = [];

    push(s: string): StringBuilder {
        this.parts.push(s);
        return this;
    }

    // Appends s and "\n".

    line(s: string): StringBuilder {
        this.parts.push(s);
        this.parts.push("\n");
        return this;
    }

    // Appends one UTF-16 code unit / code point.
    pushChar(code: i32): StringBuilder {
        this.parts.push(String.fromCodePoint(code));
        return this;
    }

    get isEmpty(): bool {
        for (let i = 0; i < this.parts.length; i++) {
            if (this.parts[i].length > 0) return false;
        }
        return true;
    }

    clear(): void {
        this.parts = [];
    }

    toString(): string {
        if (this.parts.length > 1) {
            const joined = this.parts.join("");
            this.parts = [joined];
        }
        return this.parts.length == 0 ? "" : this.parts[0];
    }
}
