// Derived from Ryu (Apache-2.0 OR BSL-1.0); see THIRD_PARTY_NOTICES.md
//
// Deterministic number and string formatting for user-visible text.
//
// Never format a user-visible float with f64.toString()/f32.toString(): those
// differ in the last digit, in exponents and in -0 from the formats below.
//
//   displayF64(x) / displayF32(x)     shortest digits, never an exponent ("100", "0.00000015")
//   debugF64(x)   / debugF32(x)       at least one fraction digit, exponent when huge or tiny
//   fixedF64(x, N) / fixedF32(x, N)   exact decimal, round-half-even
//   expF64(x)     / expF32(x)         "1e16", "1.5e-7"
//   jsonF64(x)    / jsonF32(x)        JSON numbers: "1e+16", "null" for non-finite
//   zeroPad(n, 3)                     sign-aware, i64 ("-07")
//   hexU64(n) / hexU64(n, 16)         lower-case hex; upper = true for upper case
//   alignRight(s, 5) / alignLeft(s, 14) / alignCenter
//                                     width counts chars (code points)
//   debugStr(s) / debugChar(codePoint)  quoted and escaped
//   debugStruct / debugTuple / debugList / debugSome / DEBUG_NONE
//                                     `Name { a: 1 }`, `Name(a, b)`, `[a, b]` …
//
// The shortest round-trip digits use Ryu (d2s + f2s, full tables). The JSON
// layout breaks ties at an exact midpoint between two shortest candidates to
// even; the display/debug/exp layouts round them up. A flag switches that one
// rule. tests/core/base_fmt_test.as checks ~15k recorded values.
// The layouts differ: display never uses an exponent; JSON writes "1e+16";
// debug and exp write "1e16". fixedF64 is computed exactly with a small bignum.

// ---------------------------------------------------------------------------
// 128-bit helpers (u64 halves)

// High 64 bits of the 128-bit product a * b.
function umulh(a: u64, b: u64): u64 {
    const aLo = a & 0xFFFFFFFF;
    const aHi = a >> 32;
    const bLo = b & 0xFFFFFFFF;
    const bHi = b >> 32;
    const p0 = aLo * bLo;
    const p1 = aLo * bHi;
    const p2 = aHi * bLo;
    const p3 = aHi * bHi;
    const mid = (p0 >> 32) + (p1 & 0xFFFFFFFF) + (p2 & 0xFFFFFFFF);
    return p3 + (p1 >> 32) + (p2 >> 32) + (mid >> 32);
}

// ryu d2s_intrinsics::mul_shift_64: ((m * mul) >> j) as u64 with mul = hi:lo, j >= 64.
function mulShift64(m: u64, mulLo: u64, mulHi: u64, j: u32): u64 {
    const b0Hi = umulh(m, mulLo);
    const b2Lo = m * mulHi;
    const b2Hi = umulh(m, mulHi);
    const sumLo = b2Lo + b0Hi;
    const sumHi = b2Hi + (sumLo < b2Lo ? <u64>1 : <u64>0);
    const s = j - 64;
    if (s == 0) return sumLo;
    if (s < 64) return (sumLo >> <u64>s) | (sumHi << <u64>(64 - s));
    return sumHi >> <u64>(s - 64);
}

// ---------------------------------------------------------------------------
// ryu common

function pow5bits(e: i32): i32 {
    return <i32>(((<u32>e * 1217359) >> 19) + 1);
}

function log10Pow2(e: i32): u32 {
    return (<u32>e * 78913) >> 18;
}

function log10Pow5(e: i32): u32 {
    return (<u32>e * 732923) >> 20;
}

// ---------------------------------------------------------------------------
// ryu d2s

const DOUBLE_MANTISSA_BITS: u32 = 52;
const DOUBLE_BIAS: i32 = 1023;
const DOUBLE_POW5_INV_BITCOUNT: i32 = 125;
const DOUBLE_POW5_BITCOUNT: i32 = 125;
const FLOAT_MANTISSA_BITS: u32 = 23;
const FLOAT_BIAS: i32 = 127;
const FLOAT_POW5_INV_BITCOUNT: i32 = DOUBLE_POW5_INV_BITCOUNT - 64;
const FLOAT_POW5_BITCOUNT: i32 = DOUBLE_POW5_BITCOUNT - 64;

function pow5Factor(value: u64): u32 {
    const M_INV_5: u64 = 0xCCCCCCCCCCCCCCCD; // 5 * M_INV_5 == 1 (mod 2^64)
    const N_DIV_5: u64 = 0x3333333333333333; // 2^64 / 5
    let count: u32 = 0;
    let v = value;
    while (true) {
        v = v * M_INV_5;
        if (v > N_DIV_5) break;
        count++;
    }
    return count;
}

function multipleOfPowerOf5(value: u64, p: u32): bool {
    return pow5Factor(value) >= p;
}

function multipleOfPowerOf2(value: u64, p: u32): bool {
    return (value & ((<u64>1 << <u64>p) - 1)) == 0;
}

// Output of d2d/f2d: the shortest decimal mantissa * 10^exponent.
let decMantissa: u64 = 0;
let decExponent: i32 = 0;

// ryu d2s::d2d. Result in decMantissa / decExponent.
// tiesEven = true rounds an exact midpoint between two shortest candidates to
// even (the JSON layout); false rounds it up (display/debug/exp): 2^-25 is
// 2.9802322387695313e-8 with false, 2.9802322387695312e-8 with true.
function d2d(ieeeMantissa: u64, ieeeExponent: u32, tiesEven: bool): void {
    let e2: i32;
    let m2: u64;
    if (ieeeExponent == 0) {
        e2 = 1 - DOUBLE_BIAS - <i32>DOUBLE_MANTISSA_BITS - 2;
        m2 = ieeeMantissa;
    } else {
        e2 = <i32>ieeeExponent - DOUBLE_BIAS - <i32>DOUBLE_MANTISSA_BITS - 2;
        m2 = (<u64>1 << <u64>DOUBLE_MANTISSA_BITS) | ieeeMantissa;
    }
    const even = (m2 & 1) == 0;
    const acceptBounds = even;

    const mv: u64 = 4 * m2;
    const mmShift: u32 = (ieeeMantissa != 0 || ieeeExponent <= 1) ? 1 : 0;

    let vr: u64;
    let vp: u64;
    let vm: u64;
    let e10: i32;
    let vmIsTrailingZeros = false;
    let vrIsTrailingZeros = false;
    if (e2 >= 0) {
        const q: u32 = log10Pow2(e2) - (e2 > 3 ? 1 : 0);
        e10 = <i32>q;
        const k = DOUBLE_POW5_INV_BITCOUNT + pow5bits(<i32>q) - 1;
        const i = -e2 + <i32>q + k;
        const lo = DOUBLE_POW5_INV_SPLIT[<i32>q * 2];
        const hi = DOUBLE_POW5_INV_SPLIT[<i32>q * 2 + 1];
        vr = mulShift64(4 * m2, lo, hi, <u32>i);
        vp = mulShift64(4 * m2 + 2, lo, hi, <u32>i);
        vm = mulShift64(4 * m2 - 1 - <u64>mmShift, lo, hi, <u32>i);
        if (q <= 21) {
            const mvMod5 = <u32>mv - 5 * <u32>(mv / 5);
            if (mvMod5 == 0) {
                vrIsTrailingZeros = multipleOfPowerOf5(mv, q);
            } else if (acceptBounds) {
                vmIsTrailingZeros = multipleOfPowerOf5(mv - 1 - <u64>mmShift, q);
            } else {
                vp -= multipleOfPowerOf5(mv + 2, q) ? 1 : 0;
            }
        }
    } else {
        const q: u32 = log10Pow5(-e2) - (-e2 > 1 ? 1 : 0);
        e10 = <i32>q + e2;
        const i = -e2 - <i32>q;
        const k = pow5bits(i) - DOUBLE_POW5_BITCOUNT;
        const j = <i32>q - k;
        const lo = DOUBLE_POW5_SPLIT[i * 2];
        const hi = DOUBLE_POW5_SPLIT[i * 2 + 1];
        vr = mulShift64(4 * m2, lo, hi, <u32>j);
        vp = mulShift64(4 * m2 + 2, lo, hi, <u32>j);
        vm = mulShift64(4 * m2 - 1 - <u64>mmShift, lo, hi, <u32>j);
        if (q <= 1) {
            vrIsTrailingZeros = true;
            if (acceptBounds) {
                vmIsTrailingZeros = mmShift == 1;
            } else {
                vp -= 1;
            }
        } else if (q < 63) {
            vrIsTrailingZeros = multipleOfPowerOf2(mv, q);
        }
    }

    let removed: i32 = 0;
    let lastRemovedDigit: u32 = 0;
    let output: u64;
    if (vmIsTrailingZeros || vrIsTrailingZeros) {
        while (true) {
            const vpDiv10 = vp / 10;
            const vmDiv10 = vm / 10;
            if (vpDiv10 <= vmDiv10) break;
            const vmMod10 = <u32>vm - 10 * <u32>vmDiv10;
            const vrDiv10 = vr / 10;
            const vrMod10 = <u32>vr - 10 * <u32>vrDiv10;
            vmIsTrailingZeros = vmIsTrailingZeros && vmMod10 == 0;
            vrIsTrailingZeros = vrIsTrailingZeros && lastRemovedDigit == 0;
            lastRemovedDigit = vrMod10;
            vr = vrDiv10;
            vp = vpDiv10;
            vm = vmDiv10;
            removed++;
        }
        if (vmIsTrailingZeros) {
            while (true) {
                const vmDiv10 = vm / 10;
                const vmMod10 = <u32>vm - 10 * <u32>vmDiv10;
                if (vmMod10 != 0) break;
                const vpDiv10 = vp / 10;
                const vrDiv10 = vr / 10;
                const vrMod10 = <u32>vr - 10 * <u32>vrDiv10;
                vrIsTrailingZeros = vrIsTrailingZeros && lastRemovedDigit == 0;
                lastRemovedDigit = vrMod10;
                vr = vrDiv10;
                vp = vpDiv10;
                vm = vmDiv10;
                removed++;
            }
        }
        if (tiesEven && vrIsTrailingZeros && lastRemovedDigit == 5 && vr % 2 == 0) {
            lastRemovedDigit = 4;
        }
        const up = (vr == vm && (!acceptBounds || !vmIsTrailingZeros)) || lastRemovedDigit >= 5;
        output = vr + (up ? 1 : 0);
    } else {
        let roundUp = false;
        const vpDiv100 = vp / 100;
        const vmDiv100 = vm / 100;
        if (vpDiv100 > vmDiv100) {
            const vrDiv100 = vr / 100;
            const vrMod100 = <u32>vr - 100 * <u32>vrDiv100;
            roundUp = vrMod100 >= 50;
            vr = vrDiv100;
            vp = vpDiv100;
            vm = vmDiv100;
            removed += 2;
        }
        while (true) {
            const vpDiv10 = vp / 10;
            const vmDiv10 = vm / 10;
            if (vpDiv10 <= vmDiv10) break;
            const vrDiv10 = vr / 10;
            const vrMod10 = <u32>vr - 10 * <u32>vrDiv10;
            roundUp = vrMod10 >= 5;
            vr = vrDiv10;
            vp = vpDiv10;
            vm = vmDiv10;
            removed++;
        }
        output = vr + ((vr == vm || roundUp) ? 1 : 0);
    }
    decExponent = e10 + removed;
    decMantissa = output;
}

// ---------------------------------------------------------------------------
// ryu f2s

function pow5Factor32(value: u32): u32 {
    let count: u32 = 0;
    let v = value;
    while (true) {
        const q = v / 5;
        const r = v % 5;
        if (r != 0) break;
        v = q;
        count++;
    }
    return count;
}

function multipleOfPowerOf5_32(value: u32, p: u32): bool {
    return pow5Factor32(value) >= p;
}

function multipleOfPowerOf2_32(value: u32, p: u32): bool {
    return (value & ((<u32>1 << p) - 1)) == 0;
}

function mulShift32(m: u32, factor: u64, shift: i32): u32 {
    const factorLo = factor & 0xFFFFFFFF;
    const factorHi = factor >> 32;
    const bits0 = <u64>m * factorLo;
    const bits1 = <u64>m * factorHi;
    const sum = (bits0 >> 32) + bits1;
    return <u32>(sum >> <u64>(shift - 32));
}

function mulPow5InvDivPow2(m: u32, q: u32, j: i32): u32 {
    return mulShift32(m, DOUBLE_POW5_INV_SPLIT[<i32>q * 2 + 1] + 1, j);
}

function mulPow5DivPow2(m: u32, i: u32, j: i32): u32 {
    return mulShift32(m, DOUBLE_POW5_SPLIT[<i32>i * 2 + 1], j);
}

// ryu f2s::f2d. Result in decMantissa / decExponent. tiesEven: see d2d.
function f2d(ieeeMantissa: u32, ieeeExponent: u32, tiesEven: bool): void {
    let e2: i32;
    let m2: u32;
    if (ieeeExponent == 0) {
        e2 = 1 - FLOAT_BIAS - <i32>FLOAT_MANTISSA_BITS - 2;
        m2 = ieeeMantissa;
    } else {
        e2 = <i32>ieeeExponent - FLOAT_BIAS - <i32>FLOAT_MANTISSA_BITS - 2;
        m2 = (<u32>1 << FLOAT_MANTISSA_BITS) | ieeeMantissa;
    }
    const even = (m2 & 1) == 0;
    const acceptBounds = even;

    const mv: u32 = 4 * m2;
    const mp: u32 = 4 * m2 + 2;
    const mmShift: u32 = (ieeeMantissa != 0 || ieeeExponent <= 1) ? 1 : 0;
    const mm: u32 = 4 * m2 - 1 - mmShift;

    let vr: u32;
    let vp: u32;
    let vm: u32;
    let e10: i32;
    let vmIsTrailingZeros = false;
    let vrIsTrailingZeros = false;
    let lastRemovedDigit: u32 = 0;
    if (e2 >= 0) {
        const q = log10Pow2(e2);
        e10 = <i32>q;
        const k = FLOAT_POW5_INV_BITCOUNT + pow5bits(<i32>q) - 1;
        const i = -e2 + <i32>q + k;
        vr = mulPow5InvDivPow2(mv, q, i);
        vp = mulPow5InvDivPow2(mp, q, i);
        vm = mulPow5InvDivPow2(mm, q, i);
        if (q != 0 && (vp - 1) / 10 <= vm / 10) {
            const l = FLOAT_POW5_INV_BITCOUNT + pow5bits(<i32>q - 1) - 1;
            lastRemovedDigit = mulPow5InvDivPow2(mv, q - 1, -e2 + <i32>q - 1 + l) % 10;
        }
        if (q <= 9) {
            if (mv % 5 == 0) {
                vrIsTrailingZeros = multipleOfPowerOf5_32(mv, q);
            } else if (acceptBounds) {
                vmIsTrailingZeros = multipleOfPowerOf5_32(mm, q);
            } else {
                vp -= multipleOfPowerOf5_32(mp, q) ? 1 : 0;
            }
        }
    } else {
        const q = log10Pow5(-e2);
        e10 = <i32>q + e2;
        const i = -e2 - <i32>q;
        const k = pow5bits(i) - FLOAT_POW5_BITCOUNT;
        let j = <i32>q - k;
        vr = mulPow5DivPow2(mv, <u32>i, j);
        vp = mulPow5DivPow2(mp, <u32>i, j);
        vm = mulPow5DivPow2(mm, <u32>i, j);
        if (q != 0 && (vp - 1) / 10 <= vm / 10) {
            j = <i32>q - 1 - (pow5bits(i + 1) - FLOAT_POW5_BITCOUNT);
            lastRemovedDigit = mulPow5DivPow2(mv, <u32>(i + 1), j) % 10;
        }
        if (q <= 1) {
            vrIsTrailingZeros = true;
            if (acceptBounds) {
                vmIsTrailingZeros = mmShift == 1;
            } else {
                vp -= 1;
            }
        } else if (q < 31) {
            vrIsTrailingZeros = multipleOfPowerOf2_32(mv, q - 1);
        }
    }

    let removed: i32 = 0;
    let output: u32;
    if (vmIsTrailingZeros || vrIsTrailingZeros) {
        while (vp / 10 > vm / 10) {
            vmIsTrailingZeros = vmIsTrailingZeros && vm - (vm / 10) * 10 == 0;
            vrIsTrailingZeros = vrIsTrailingZeros && lastRemovedDigit == 0;
            lastRemovedDigit = vr % 10;
            vr /= 10;
            vp /= 10;
            vm /= 10;
            removed++;
        }
        if (vmIsTrailingZeros) {
            while (vm % 10 == 0) {
                vrIsTrailingZeros = vrIsTrailingZeros && lastRemovedDigit == 0;
                lastRemovedDigit = vr % 10;
                vr /= 10;
                vm /= 10;
                removed++;
            }
        }
        if (tiesEven && vrIsTrailingZeros && lastRemovedDigit == 5 && vr % 2 == 0) {
            lastRemovedDigit = 4;
        }
        const up = (vr == vm && (!acceptBounds || !vmIsTrailingZeros)) || lastRemovedDigit >= 5;
        output = vr + (up ? 1 : 0);
    } else {
        while (vp / 10 > vm / 10) {
            lastRemovedDigit = vr % 10;
            vr /= 10;
            vp /= 10;
            vm /= 10;
            removed++;
        }
        output = vr + ((vr == vm || lastRemovedDigit >= 5) ? 1 : 0);
    }
    decExponent = e10 + removed;
    decMantissa = <u64>output;
}

// ---------------------------------------------------------------------------
// Shortest digits (shared by the JSON and the display/debug layouts)

// Digits of the last shortestF64/F32 call, without trailing zeros, and the
// decimal exponent: value = 0.<digits> * 10^shortExp.
let shortDigits: string = "";
let shortExp: i32 = 0;

function setShortest(): void {
    const ds = decMantissa.toString();
    let end = ds.length;
    while (end > 1 && ds.charCodeAt(end - 1) == 48) end--;
    shortDigits = end == ds.length ? ds : ds.substring(0, end);
    shortExp = ds.length + decExponent;
}

// Requires x finite and non-zero. tiesEven: true for JSON, false for display/debug/exp.
function shortestF64(x: f64, tiesEven: bool): void {
    const bits = reinterpret<u64>(x);
    const mant = bits & ((<u64>1 << 52) - 1);
    const exp = <u32>((bits >> 52) & 0x7FF);
    d2d(mant, exp, tiesEven);
    setShortest();
}

// Requires x finite and non-zero. tiesEven: true for JSON, false for display/debug/exp.
function shortestF32(x: f32, tiesEven: bool): void {
    const bits = reinterpret<u32>(x);
    const mant = bits & ((<u32>1 << 23) - 1);
    const exp = (bits >> 23) & 0xFF;
    f2d(mant, exp, tiesEven);
    setShortest();
}

function zeros(n: i32): string {
    return n <= 0 ? "" : "0".repeat(n);
}

// ---------------------------------------------------------------------------
// JSON float text

// The JSON layout on the digits of the last shortest call: plain decimal when
// the first digit's decimal exponent is in [minExp, maxExp] ("1e15" -> "1000000000000000.0",
// "0.0001"), else scientific with an explicit exponent sign ("1e+16", "1.5e-7").
function layoutDecimal(neg: bool, minExp: i32, maxExp: i32): string {
    const ds = shortDigits;
    const length = ds.length;
    const e = shortExp - 1; // decimal exponent of the first digit
    let s: string;
    if (e >= minExp && e <= maxExp) {
        if (length - 1 <= e) {
            s = ds + zeros(e + 1 - length) + ".0";
        } else if (e >= 0) {
            s = ds.substring(0, e + 1) + "." + ds.substring(e + 1);
        } else {
            s = "0." + zeros(-e - 1) + ds;
        }
    } else {
        s = length == 1 ? ds : ds.substring(0, 1) + "." + ds.substring(1);
        s += e >= 0 ? "e+" + e.toString() : "e-" + (-e).toString();
    }
    return neg ? "-" + s : s;
}

// The JSON text for an f64 (a Value number, or a
// serialized f64 field): "0.0", "-0.0", "1.5", "1e+16", "1.5e-7", "null"
// for NaN and infinities.
export function jsonF64(x: f64): string {
    if (!isFinite(x)) return "null";
    const neg = (reinterpret<u64>(x) >> 63) != 0;
    if (x == 0) return neg ? "-0.0" : "0.0";
    shortestF64(x, true);
    return layoutDecimal(neg, -5, 15);
}

// The JSON text for a serialized f32 field (f32 digits: 1.1f32 -> "1.1").
export function jsonF32(x: f32): string {
    if (!isFinite(x)) return "null";
    const neg = (reinterpret<u32>(x) >> 31) != 0;
    if (x == 0) return neg ? "-0.0" : "0.0";
    shortestF32(x, true);
    return layoutDecimal(neg, -6, 12);
}

// ---------------------------------------------------------------------------
// Display / debug / exp layouts for floats

// Plain decimal text of (shortDigits, exp), padded to fracDigits fraction digits.
function digitsToDecStr(buf: string, exp: i32, fracDigits: i32): string {
    const len = buf.length;
    if (exp <= 0) {
        const minusExp = -exp;
        let s = "0." + zeros(minusExp) + buf;
        if (fracDigits > len && fracDigits - len > minusExp) {
            s += zeros(fracDigits - len - minusExp);
        }
        return s;
    }
    if (exp < len) {
        let s = buf.substring(0, exp) + "." + buf.substring(exp);
        if (fracDigits > len - exp) s += zeros(fracDigits - (len - exp));
        return s;
    }
    let s = buf + zeros(exp - len);
    if (fracDigits > 0) s += "." + zeros(fracDigits);
    return s;
}

// Exponent text of (shortDigits, exp) with a lower-case `e`.
function digitsToExpStr(buf: string, exp: i32): string {
    let s = buf.substring(0, 1);
    if (buf.length > 1) s += "." + buf.substring(1);
    const e = exp - 1;
    return s + "e" + e.toString();
}

function nonFinite(x: f64): string {
    if (isNaN(x)) return "NaN";
    return x > 0 ? "inf" : "-inf";
}

function signOf64(x: f64): string {
    return (reinterpret<u64>(x) >> 63) != 0 ? "-" : "";
}

function signOf32(x: f32): string {
    return (reinterpret<u32>(x) >> 31) != 0 ? "-" : "";
}

// Display text for f64: shortest round-trip digits, never an
// exponent (1e21 prints 22 digits, 1.5e-7 prints 0.00000015), no ".0" on
// integers ("100"), "-0" for negative zero, "NaN", "inf", "-inf".
export function displayF64(x: f64): string {
    if (!isFinite(x)) return nonFinite(x);
    if (x == 0) return signOf64(x) + "0";
    shortestF64(x, false);
    return signOf64(x) + digitsToDecStr(shortDigits, shortExp, 0);
}

// Display text for f32 (shortest f32 digits: 0.1f32 prints "0.1").
export function displayF32(x: f32): string {
    if (!isFinite(x)) return nonFinite(<f64>x);
    if (x == 0) return signOf32(x) + "0";
    shortestF32(x, false);
    return signOf32(x) + digitsToDecStr(shortDigits, shortExp, 0);
}

// Debug text for f64: like display but with at least one
// fractional digit ("1.0", "-0.0"), and exponent form ("1e16", "1.5e-5")
// when |x| >= 1e16 or 0 < |x| < 1e-4.
export function debugF64(x: f64): string {
    if (isNaN(x)) return "NaN";
    const a = Math.abs(x);
    if ((a != 0 && a < 1e-4) || a >= 1e16) return expF64(x);
    if (x == 0) return signOf64(x) + "0.0";
    shortestF64(x, false);
    return signOf64(x) + digitsToDecStr(shortDigits, shortExp, 1);
}

// Debug text for f32 (thresholds compared in f32).
export function debugF32(x: f32): string {
    if (isNaN(x)) return "NaN";
    const a = Mathf.abs(x);
    if ((a != 0 && a < <f32>1e-4) || a >= <f32>1e16) return expF32(x);
    if (x == 0) return signOf32(x) + "0.0";
    shortestF32(x, false);
    return signOf32(x) + digitsToDecStr(shortDigits, shortExp, 1);
}

// Exponent text for f64: "1e16", "1.5e-7", "0e0", "-0e0".
export function expF64(x: f64): string {
    if (!isFinite(x)) return nonFinite(x);
    if (x == 0) return signOf64(x) + "0e0";
    shortestF64(x, false);
    return signOf64(x) + digitsToExpStr(shortDigits, shortExp);
}

// Exponent text for f32.
export function expF32(x: f32): string {
    if (!isFinite(x)) return nonFinite(<f64>x);
    if (x == 0) return signOf32(x) + "0e0";
    shortestF32(x, false);
    return signOf32(x) + digitsToExpStr(shortDigits, shortExp);
}

// ---------------------------------------------------------------------------
// fixedF64: exact decimal expansion with round-half-to-even

// Little-endian base-2^32 scratch bignum, reused across calls (no garbage
// under the stub runtime).
let bigBuf = new Uint32Array(64);
let bigLen: i32 = 0;

function bigEnsure(limbs: i32): void {
    if (bigBuf.length < limbs) {
        const n = new Uint32Array(limbs * 2);
        n.set(bigBuf.subarray(0, bigLen));
        bigBuf = n;
    }
}

function bigSet(m: u64): void {
    bigEnsure(2);
    bigBuf[0] = <u32>(m & 0xFFFFFFFF);
    bigBuf[1] = <u32>(m >> 32);
    bigLen = bigBuf[1] != 0 ? 2 : (bigBuf[0] != 0 ? 1 : 0);
}

function bigMulSmall(k: u32): void {
    let carry: u64 = 0;
    for (let i = 0; i < bigLen; i++) {
        const t = <u64>bigBuf[i] * <u64>k + carry;
        bigBuf[i] = <u32>(t & 0xFFFFFFFF);
        carry = t >> 32;
    }
    if (carry != 0) {
        bigEnsure(bigLen + 1);
        bigBuf[bigLen] = <u32>carry;
        bigLen++;
    }
}

function bigShl(s: i32): void {
    if (bigLen == 0) return;
    const words = s >> 5;
    const bits = s & 31;
    bigEnsure(bigLen + words + 1);
    bigBuf[bigLen + words] = 0;
    for (let i = bigLen - 1; i >= 0; i--) {
        const v = bigBuf[i];
        if (bits != 0) bigBuf[i + words + 1] |= v >>> (32 - bits);
        bigBuf[i + words] = bits != 0 ? v << bits : v;
    }
    for (let i = 0; i < words; i++) bigBuf[i] = 0;
    bigLen = bigLen + words + 1;
    while (bigLen > 0 && bigBuf[bigLen - 1] == 0) bigLen--;
}

function bigBit(i: i32): bool {
    const w = i >> 5;
    if (w >= bigLen) return false;
    return ((bigBuf[w] >>> (i & 31)) & 1) != 0;
}

// True if any of bits 0..n-1 is set.
function bigAnyBelow(n: i32): bool {
    const full = n >> 5;
    for (let i = 0; i < full && i < bigLen; i++) {
        if (bigBuf[i] != 0) return true;
    }
    const rem = n & 31;
    if (rem != 0 && full < bigLen) {
        if ((bigBuf[full] & ((<u32>1 << rem) - 1)) != 0) return true;
    }
    return false;
}

function bigShr(s: i32): void {
    const words = s >> 5;
    const bits = s & 31;
    if (words >= bigLen) {
        bigLen = 0;
        return;
    }
    const n = bigLen - words;
    for (let i = 0; i < n; i++) {
        let v = bigBuf[i + words] >>> bits;
        if (bits != 0 && i + words + 1 < bigLen) v |= bigBuf[i + words + 1] << (32 - bits);
        bigBuf[i] = v;
    }
    bigLen = n;
    while (bigLen > 0 && bigBuf[bigLen - 1] == 0) bigLen--;
}

function bigAddOne(): void {
    for (let i = 0; i < bigLen; i++) {
        bigBuf[i] = bigBuf[i] + 1;
        if (bigBuf[i] != 0) return;
    }
    bigEnsure(bigLen + 1);
    bigBuf[bigLen] = 1;
    bigLen++;
}

// Decimal text of the scratch bignum (destroys it).
function bigToDecimal(): string {
    if (bigLen == 0) return "0";
    const chunks: Array<u32> = [];
    while (bigLen > 0) {
        let rem: u64 = 0;
        for (let i = bigLen - 1; i >= 0; i--) {
            const cur = (rem << 32) | <u64>bigBuf[i];
            bigBuf[i] = <u32>(cur / 1000000000);
            rem = cur % 1000000000;
        }
        while (bigLen > 0 && bigBuf[bigLen - 1] == 0) bigLen--;
        chunks.push(<u32>rem);
    }
    const parts: Array<string> = [];
    parts.push(chunks[chunks.length - 1].toString());
    for (let i = chunks.length - 2; i >= 0; i--) {
        parts.push(chunks[i].toString().padStart(9, "0"));
    }
    return parts.join("");
}

// round_half_even(m * 2^e * 10^prec) in decimal, m > 0.
function exactScaledDigits(m: u64, e: i32, prec: i32): string {
    bigSet(m);
    if (e >= 0) {
        bigShl(e);
        return bigToDecimal() + zeros(prec);
    }
    let p = prec;
    while (p >= 9) {
        bigMulSmall(1000000000);
        p -= 9;
    }
    let tail: u32 = 1;
    for (let i = 0; i < p; i++) tail *= 10;
    if (tail != 1) bigMulSmall(tail);
    const s = -e;
    const half = bigBit(s - 1);
    const below = half ? bigAnyBelow(s - 1) : false;
    bigShr(s);
    if (half && (below || bigBit(0))) bigAddOne();
    return bigToDecimal();
}

function fixedFromParts(sign: string, m: u64, e: i32, prec: i32): string {
    const p = prec < 0 ? 0 : prec;
    if (m == 0) return sign + (p > 0 ? "0." + zeros(p) : "0");
    const d = exactScaledDigits(m, e, p);
    if (p == 0) return sign + d;
    if (d.length <= p) return sign + "0." + zeros(p - d.length) + d;
    return sign + d.substring(0, d.length - p) + "." + d.substring(d.length - p);
}

// Fixed-point text for f64: the exact binary value rounded to N
// decimals, ties to even (0.125 -> "0.12", 0.375 -> "0.38", 2.5 -> "2" at N=0).
// Negative values keep their sign even when they round to zero ("-0.0000").
export function fixedF64(x: f64, prec: i32): string {
    if (!isFinite(x)) return nonFinite(x);
    const bits = reinterpret<u64>(x);
    const mant = bits & ((<u64>1 << 52) - 1);
    const exp = <i32>((bits >> 52) & 0x7FF);
    if (exp == 0) return fixedFromParts(signOf64(x), mant, -1074, prec);
    return fixedFromParts(signOf64(x), mant | (<u64>1 << 52), exp - 1075, prec);
}

// Fixed-point text for f32 (the same exact value as the f64 widening).
export function fixedF32(x: f32, prec: i32): string {
    return fixedF64(<f64>x, prec);
}

// ---------------------------------------------------------------------------
// Integers, alignment

// Decimal text of any signed integer (i64::MIN included).
export function displayI64(v: i64): string {
    if (v < 0) return "-" + (<u64>0 - <u64>v).toString();
    return (<u64>v).toString();
}

// Zero padded to W chars, sign first ("-07").
export function zeroPad(v: i64, width: i32): string {
    if (v < 0) {
        // i64::MIN has no positive counterpart; its digits come from the u64 view.
        const digits = (<u64>0 - <u64>v).toString();
        // padStart traps on a negative length, so clamp (width 0 or 1 on -7 is "-7").
        return "-" + digits.padStart(width > 1 ? width - 1 : 0, "0");
    }
    return (<u64>v).toString().padStart(width > 0 ? width : 0, "0");
}

// zeroPad for u64 values above i64::MAX.
export function zeroPadU64(v: u64, width: i32): string {
    return v.toString().padStart(width > 0 ? width : 0, "0");
}

const HEX_LOWER = "0123456789abcdef";
const HEX_UPPER = "0123456789ABCDEF";

// Hex digits of a u64, zero padded to `width` (cast signed values to u64
// first to get their two's-complement hex).
export function hexU64(v: u64, width: i32 = 0, upper: bool = false): string {
    const digits = upper ? HEX_UPPER : HEX_LOWER;
    const parts: Array<string> = [];
    let n = v;
    do {
        parts.push(digits.charAt(<i32>(n & 15)));
        n = n >> 4;
    } while (n != 0);
    while (parts.length < width) parts.push("0");
    parts.reverse();
    return parts.join("");
}

// Number of chars (Unicode scalar values) in s, which is what widths count.
export function charCount(s: string): i32 {
    let n = 0;
    const len = s.length;
    for (let i = 0; i < len; i++) {
        const c = s.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            const d = s.charCodeAt(i + 1);
            if (d >= 0xDC00 && d <= 0xDFFF) i++;
        }
        n++;
    }
    return n;
}

// Pads on the left with spaces to W chars.
export function alignRight(s: string, width: i32): string {
    const n = charCount(s);
    return n >= width ? s : " ".repeat(width - n) + s;
}

// Pads on the right with spaces to W chars.
export function alignLeft(s: string, width: i32): string {
    const n = charCount(s);
    return n >= width ? s : s + " ".repeat(width - n);
}

// Centres, the odd space going to the right.
export function alignCenter(s: string, width: i32): string {
    const n = charCount(s);
    if (n >= width) return s;
    const pad = width - n;
    const left = pad / 2;
    return " ".repeat(left) + s + " ".repeat(pad - left);
}

// ---------------------------------------------------------------------------
// Debug for str / char

function isDebugEscaped(cp: u32): bool {
    // binary search over inclusive ranges
    let lo = 0;
    let hi = DEBUG_ESCAPE_RANGES.length / 2 - 1;
    while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        const a = DEBUG_ESCAPE_RANGES[mid * 2];
        const b = DEBUG_ESCAPE_RANGES[mid * 2 + 1];
        if (cp < a) {
            hi = mid - 1;
        } else if (cp > b) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

function hexLower(cp: u32): string {
    return hexU64(<u64>cp);
}

// The escape of one code point inside a Debug-formatted str (quote = '"') or
// char (quote = '\''), or "" when it is written as is.
function debugEscape(cp: u32, isChar: bool): string {
    switch (cp) {
        case 0: return "\\0";
        case 9: return "\\t";
        case 10: return "\\n";
        case 13: return "\\r";
        case 92: return "\\\\";
        case 34: return isChar ? "" : "\\\"";
        case 39: return isChar ? "\\'" : "";
        default: break;
    }
    if (cp < 0x20 || cp == 0x7F) return "\\u{" + hexLower(cp) + "}";
    if (cp < 0x80) return "";
    // lone surrogates are not valid text; escape them visibly
    if ((cp >= 0xD800 && cp <= 0xDFFF) || isDebugEscaped(cp)) return "\\u{" + hexLower(cp) + "}";
    return "";
}

// Debug text for a string: double quotes, `\"` `\\` `\n` `\r`
// `\t` `\0`, and \u{..} for other control, non-printable and
// grapheme-extending chars ("e\u{301}"). `'` is not escaped.
export function debugStr(s: string): string {
    const parts: Array<string> = ["\""];
    const len = s.length;
    let runStart = 0;
    let i = 0;
    while (i < len) {
        let cp = <u32>s.charCodeAt(i);
        let w = 1;
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len) {
            const d = <u32>s.charCodeAt(i + 1);
            if (d >= 0xDC00 && d <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (d - 0xDC00);
                w = 2;
            }
        }
        const e = debugEscape(cp, false);
        if (e.length > 0) {
            if (i > runStart) parts.push(s.substring(runStart, i));
            parts.push(e);
            runStart = i + w;
        }
        i += w;
    }
    if (runStart < len) parts.push(s.substring(runStart));
    parts.push("\"");
    return parts.join("");
}

// Debug text for a char given as a code point: 'a', '\'', '"', '\u{301}'.
export function debugChar(cp: u32): string {
    const e = debugEscape(cp, true);
    return "'" + (e.length > 0 ? e : String.fromCodePoint(<i32>cp)) + "'";
}

// ---------------------------------------------------------------------------
// Debug building blocks (single-line only)

// `Name { a: 1, b: 2.0 }`; `Name` for a struct without fields. Values are
// already Debug-formatted.
export function debugStruct(name: string, fields: Array<string>, values: Array<string>): string {
    if (fields.length == 0) return name;
    const parts: Array<string> = [];
    for (let i = 0; i < fields.length; i++) parts.push(fields[i] + ": " + values[i]);
    return name + " { " + parts.join(", ") + " }";
}

// `Name(a, b)` (tuple struct / tuple variant); `(a, b)` for a bare tuple
// (name ""), and `(a,)` for a one-element bare tuple.
export function debugTuple(name: string, values: Array<string>): string {
    if (name.length > 0 && values.length == 0) return name;
    if (name.length == 0 && values.length == 1) return "(" + values[0] + ",)";
    return name + "(" + values.join(", ") + ")";
}

// `[a, b, c]` for a slice/Vec, from Debug-formatted items.
export function debugList(values: Array<string>): string {
    return "[" + values.join(", ") + "]";
}

// `{a, b}` for a set; `{k: v}` for a map: pass "k: v" items.
export function debugSet(values: Array<string>): string {
    return "{" + values.join(", ") + "}";
}

// `Some(x)` around a debug-formatted x; DEBUG_NONE is `None`.
export function debugSome(value: string): string {
    return "Some(" + value + ")";
}
export const DEBUG_NONE = "None";

// Debug of a slice of f32 / f64: "[1.0, 0.5]".
export function debugF32List(xs: Array<f32>): string {
    const parts: Array<string> = [];
    for (let i = 0; i < xs.length; i++) parts.push(debugF32(xs[i]));
    return debugList(parts);
}
export function debugF64List(xs: Array<f64>): string {
    const parts: Array<string> = [];
    for (let i = 0; i < xs.length; i++) parts.push(debugF64(xs[i]));
    return debugList(parts);
}

// Debug of a slice of strings: `["a", "b"]`.
export function debugStrList(xs: Array<string>): string {
    const parts: Array<string> = [];
    for (let i = 0; i < xs.length; i++) parts.push(debugStr(xs[i]));
    return debugList(parts);
}

// ---------------------------------------------------------------------------
// Tables. Generated: Ryu's full d2s table, and the debugStr escape set
// (every char >= U+0080 that is non-printable or grapheme-extending; the set
// is context-free and the same for debugChar).

// 342 (lo, hi) pairs, flattened: entry i is [2*i] = lo, [2*i+1] = hi.
const DOUBLE_POW5_INV_SPLIT: StaticArray<u64> = [
    0x0000000000000001, 0x2000000000000000,
    0x999999999999999a, 0x1999999999999999,
    0x47ae147ae147ae15, 0x147ae147ae147ae1,
    0x6c8b4395810624de, 0x10624dd2f1a9fbe7,
    0x7a786c226809d496, 0x1a36e2eb1c432ca5,
    0x61f9f01b866e43ab, 0x14f8b588e368f084,
    0xb4c7f34938583622, 0x10c6f7a0b5ed8d36,
    0x87a6520ec08d236a, 0x1ad7f29abcaf4857,
    0x9fb841a566d74f88, 0x15798ee2308c39df,
    0xe62d01511f12a607, 0x112e0be826d694b2,
    0xd6ae6881cb5109a4, 0x1b7cdfd9d7bdbab7,
    0xdef1ed34a2a73aea, 0x15fd7fe17964955f,
    0x7f27f0f6e885c8bb, 0x119799812dea1119,
    0x650cb4be40d60df8, 0x1c25c268497681c2,
    0xea70909833de7193, 0x16849b86a12b9b01,
    0x21f3a6e0297ec143, 0x1203af9ee756159b,
    0x6985d7cd0f313537, 0x1cd2b297d889bc2b,
    0x2137dfd73f5a90f9, 0x170ef54646d49689,
    0xe75fe645cc4873fa, 0x12725dd1d243aba0,
    0xa5663d3c7a0d865d, 0x1d83c94fb6d2ac34,
    0x511e976394d79eb1, 0x179ca10c9242235d,
    0xda7edf82dd794bc1, 0x12e3b40a0e9b4f7d,
    0x2a6498d1625bac68, 0x1e392010175ee596,
    0xeeb6e0a781e2f053, 0x182db34012b25144,
    0x58924d52ce4f26a9, 0x1357c299a88ea76a,
    0x27507bb7b07ea441, 0x1ef2d0f5da7dd8aa,
    0x52a6c95fc0655034, 0x18c240c4aecb13bb,
    0x0eebd44c99eaa690, 0x13ce9a36f23c0fc9,
    0xb17953adc3110a80, 0x1fb0f6be50601941,
    0xc12ddc8b02740867, 0x195a5efea6b34767,
    0x3424b06f3529a052, 0x14484bfeebc29f86,
    0x901d59f290ee19db, 0x1039d66589687f9e,
    0x4cfbc31db4b0295f, 0x19f623d5a8a73297,
    0x3d9635b15d59bab2, 0x14c4e977ba1f5bac,
    0x97ab5e277de16228, 0x109d8792fb4c4956,
    0xf2abc9d8c9689d0d, 0x1a95a5b7f87a0ef0,
    0x5bbca17a3aba173e, 0x154484932d2e725a,
    0xafca1ac82efb45cb, 0x11039d428a8b8eae,
    0xb2dcf7a6b1920945, 0x1b38fb9daa78e44a,
    0xf57d92ebc141a104, 0x15c72fb1552d836e,
    0xc46475896767b403, 0x116c262777579c58,
    0x6d6d88dbd8a5ecd2, 0x1be03d0bf225c6f4,
    0x8abe071646eb23db, 0x164cfda3281e38c3,
    0x6efe6c11d255b649, 0x11d7314f534b609c,
    0xb197134fb6ef8a0e, 0x1c8b821885456760,
    0x27ac0f72f8bfa1a5, 0x16d601ad376ab91a,
    0xb95672c260994e1e, 0x1244ce242c5560e1,
    0xf5571e03cdc21695, 0x1d3ae36d13bbce35,
    0x2aac18030b01abab, 0x17624f8a762fd82b,
    0xbbbce0026f348956, 0x12b50c6ec4f31355,
    0x92c7ccd0b1eda889, 0x1dee7a4ad4b81eef,
    0xdbd30a408e57ba07, 0x17f1fb6f10934bf2,
    0x7ca8d50071dfc806, 0x1327fc58da0f6ff5,
    0xfaa7bb33e9660cd6, 0x1ea6608e29b24cbb,
    0x9552fc298784d711, 0x18851a0b548ea3c9,
    0xaaa8c9bad2d0ac0e, 0x139dae6f76d88307,
    0xdddadc5e1e1aace3, 0x1f62b0b257c0d1a5,
    0x7e48b04b4b488a4f, 0x191bc08eac9a4151,
    0xcb6d59d5d5d3a1d9, 0x141633a556e1cdda,
    0x3c577b1177dc817b, 0x1011c2eaabe7d7e2,
    0xc6f25e825960cf2a, 0x19b604aaaca62636,
    0x6bf518684780a5bb, 0x14919d5556eb51c5,
    0x232a79ed06008496, 0x10747ddddf22a7d1,
    0xd1dd8fe1a3340756, 0x1a53fc9631d10c81,
    0xa7e4731ae8f66c45, 0x150ffd44f4a73d34,
    0x531d28e253f8569e, 0x10d9976a5d52975d,
    0xeb61db03b98d5762, 0x1af5bf109550f22e,
    0xbc4e48cfc7a445e8, 0x159165a6ddda5b58,
    0x6371d3d96c836b20, 0x11411e1f17e1e2ad,
    0x9f1c8628ad9f11cd, 0x1b9b6364f3030448,
    0xe5b06b53be18db0b, 0x1615e91d8f359d06,
    0xeaf3890fcb4715a2, 0x11ab20e472914a6b,
    0x44b8db4c7871bc37, 0x1c45016d841baa46,
    0x03c715d6c6c1635f, 0x169d9abe03495505,
    0x3638de456bcde919, 0x1217aefe69077737,
    0x56c163a2461641c1, 0x1cf2b1970e725858,
    0xdf011c81d1ab67ce, 0x17288e1271f51379,
    0x7f3416ce4155eca5, 0x1286d80ec190dc61,
    0x6520247d3556476e, 0x1da48ce468e7c702,
    0xea801d30f7783925, 0x17b6d71d20b96c01,
    0xbb99b0f3f92cfa84, 0x12f8ac174d612334,
    0x5f5c4e532847f739, 0x1e5aacf215683854,
    0x7f7d0b75b9d32c2e, 0x18488a5b44536043,
    0x9930d5f7c7dc2358, 0x136d3b7c36a919cf,
    0x8eb4898c72f9d226, 0x1f152bf9f10e8fb2,
    0x722a07a38f2e41b8, 0x18ddbcc7f40ba628,
    0xc1bb394fa5be9afa, 0x13e497065cd61e86,
    0x9c5ec2190930f7f6, 0x1fd424d6faf030d7,
    0x49e56814075a5ff8, 0x197683df2f268d79,
    0x6e51201005e1e660, 0x145ecfe5bf520ac7,
    0xf1da800cd181851a, 0x104bd984990e6f05,
    0x4fc400148268d4f5, 0x1a12f5a0f4e3e4d6,
    0xd96999aa01ed772b, 0x14dbf7b3f71cb711,
    0xadee1488018ac5bc, 0x10aff95cc5b09274,
    0x497ceda668de092c, 0x1ab328946f80ea54,
    0x3aca57b853e4d424, 0x155c2076bf9a5510,
    0x623b7960431d7683, 0x1116805effaeaa73,
    0x9d2bf566d1c8bd9e, 0x1b5733cb32b110b8,
    0x7dbcc452416d647f, 0x15df5ca28ef40d60,
    0xcafd69db678ab6cc, 0x117f7d4ed8c33de6,
    0xab2f0fc572778adf, 0x1bff2ee48e052fd7,
    0x88f273045b92d580, 0x1665bf1d3e6a8cac,
    0xd3f528d049424466, 0x11eaff4a98553d56,
    0xb988414d4203a0a3, 0x1cab3210f3bb9557,
    0x6139cdd76802e6e9, 0x16ef5b40c2fc7779,
    0xe761717920025254, 0x125915cd68c9f92d,
    0xa568b58e999d5086, 0x1d5b561574765b7c,
    0x5120913ee14aa6d2, 0x177c44ddf6c515fd,
    0xa74d40ff1aa21f0e, 0x12c9d0b1923744ca,
    0x0baece64f769cb4a, 0x1e0fb44f50586e11,
    0x3c8bd850c5ee3c3b, 0x180c903f7379f1a7,
    0xca0979da37f1c9c9, 0x133d4032c2c7f485,
    0xa9a8c2f6bfe942db, 0x1ec866b79e0cba6f,
    0x2153cf2bccba9be3, 0x18a0522c7e709526,
    0x1aa9728970954982, 0x13b374f06526ddb8,
    0xf775840f1a88759d, 0x1f8587e7083e2f8c,
    0x5f9136727ba05e17, 0x19379fec0698260a,
    0x1940f85b9619e4df, 0x142c7ff0054684d5,
    0xe100c6afab47ea4c, 0x1023998cd1053710,
    0xce67a44c453fdd47, 0x19d28f47b4d524e7,
    0xd852e9d69dccb106, 0x14a8729fc3ddb71f,
    0x79dbee454b0a2738, 0x1086c219697e2c19,
    0x295fe3a211a9d859, 0x1a71368f0f30468f,
    0xbab31c81a7bb137a, 0x15275ed8d8f36ba5,
    0x6228e39aec95a92f, 0x10ec4be0ad8f8951,
    0x9d0e38f7e0ef7517, 0x1b13ac9aaf4c0ee8,
    0xb0d82d931a592a79, 0x15a956e225d67253,
    0x8d79be0f4847552e, 0x11544581b7dec1dc,
    0x158f967eda0bbb7c, 0x1bba08cf8c979c94,
    0x77a611ff14d62f97, 0x162e6d72d6dfb076,
    0xf951a7ff43de8c79, 0x11bebdf578b2f391,
    0xc21c3ffed2fdad8e, 0x1c6463225ab7ec1c,
    0x01b0333242648ad8, 0x16b6b5b5155ff017,
    0x0159c28e9b83a246, 0x122bc490dde659ac,
    0xcef604175f3903a3, 0x1d12d41afca3c2ac,
    0x725e69ac4c2d9c83, 0x17424348ca1c9bbd,
    0xf5185489d68ae39c, 0x129b69070816e2fd,
    0xee8d540fbdab05c6, 0x1dc574d80cf16b2f,
    0xbed77672fe226b05, 0x17d12a4670c1228c,
    0xff12c528cb4ebc04, 0x130dbb6b8d674ed6,
    0xcb513b74787df9a0, 0x1e7c5f127bd87e24,
    0x090dc929f9fe614d, 0x18637f41fcad31b7,
    0xa0d7d42194cb810a, 0x1382cc34ca2427c5,
    0x67bfb9cf5478ce77, 0x1f37ad21436d0c6f,
    0x1fcc94a5dd2d71f9, 0x18f9574dcf8a7059,
    0x7fd6dd517dbdf4c7, 0x13faac3e3fa1f37a,
    0xffbe2ee8c92fee0b, 0x1ff779fd329cb8c3,
    0x6631bf20a0f324d6, 0x1992c7fdc216fa36,
    0xb827cc1a1a5c1d78, 0x14756ccb01abfb5e,
    0x935309ae7b7ce460, 0x105df0a267bcc918,
    0x1eeb42b0c594a099, 0x1a2fe76a3f9474f4,
    0xe58902270476e6e1, 0x14f31f8832dd2a5c,
    0xb7a0ce859d2bebe7, 0x10c27fa028b0eeb0,
    0x59014a6f61dfdfd8, 0x1ad0cc33744e4ab4,
    0xe0cdd525e7e64cad, 0x1573d68f903ea229,
    0x4d7177518651d6f1, 0x11297872d9cbb4ee,
    0x7be8bee8d6e957e8, 0x1b758d848fac54b0,
    0xfcba3253df211320, 0x15f7a46a0c89dd59,
    0x63c8284318e74280, 0x1192e9ee706e4aae,
    0x060d0d3827d86a66, 0x1c1e43171a4a1117,
    0x6b3da42cecad21eb, 0x167e9c127b6e7412,
    0x88fe1cf0bd574e56, 0x11fee341fc585cdb,
    0x419694b462254a23, 0x1ccb0536608d615f,
    0x67abaa29e81dd4e9, 0x1708d0f84d3de77f,
    0xb95621bb2017dd87, 0x126d73f9d764b932,
    0xc223692b668c95a5, 0x1d7becc2f23ac1ea,
    0xce82ba891ed6de1d, 0x179657025b6234bb,
    0xa53562074bdf1818, 0x12deac01e2b4f6fc,
    0x3b889cd87964f359, 0x1e3113363787f194,
    0xfc6d4a46c783f5e1, 0x18274291c6065adc,
    0x30576e9f06032b1a, 0x13529ba7d19eaf17,
    0x1a257dcb3cd1de90, 0x1eea92a61c311825,
    0x481dfe3c30a7e540, 0x18bba884e35a79b7,
    0xd34b31c9c0865100, 0x13c9539d82aec7c5,
    0x5211e942cda3b4cd, 0x1fa885c8d117a609,
    0x74db21023e1c90a4, 0x19539e3a40dfb807,
    0xf715b401cb4a0d50, 0x1442e4fb67196005,
    0xf8de299b09080aa7, 0x103583fc527ab337,
    0x8e304291a80cddd7, 0x19ef3993b72ab859,
    0x3e8d020e200a4b13, 0x14bf6142f8eef9e1,
    0x653d9b3e80083c0f, 0x10991a9bfa58c7e7,
    0x6ec8f864000d2ce4, 0x1a8e90f9908e0ca5,
    0x8bd3f9e999a423ea, 0x153eda614071a3b7,
    0x3ca994bae1501cbb, 0x10ff151a99f482f9,
    0xc775bac49bb3612b, 0x1b31bb5dc320d18e,
    0xd2c4956a16291a89, 0x15c162b168e70e0b,
    0xdbd0778811ba7ba1, 0x11678227871f3e6f,
    0x2c80bf401c5d929b, 0x1bd8d03f3e9863e6,
    0xbd33cc3349e47549, 0x16470cff6546b651,
    0xca8fd68f6e505dd4, 0x11d270cc51055ea7,
    0x4419574be3b3c953, 0x1c83e7ad4e6efdd9,
    0x0347790982f63aa9, 0x16cfec8aa52597e1,
    0xcf6c60d468c4fbba, 0x123ff06eea847980,
    0xe57a34870e07f92a, 0x1d331a4b10d3f59a,
    0x512e906c0b399422, 0x175c1508da432ae2,
    0xda8ba6bcd5c7a9b5, 0x12b010d3e1cf5581,
    0x90df712e22d90f87, 0x1de6815302e5559c,
    0xda4c5a8b4f140c6c, 0x17eb9aa8cf1dde16,
    0xaea37ba2a5a9a38a, 0x1322e220a5b17e78,
    0x7dd25f6aa2a905a9, 0x1e9e369aa2b59727,
    0x97db7f888220d154, 0x187e92154ef7ac1f,
    0x797c6606ce80a777, 0x139874ddd8c6234c,
    0x8f2d700ae4010bf1, 0x1f5a549627a36bad,
    0x0c2459a25000d65a, 0x191510781fb5efbe,
    0x701d1481d99a4515, 0x1410d9f9b2f7f2fe,
    0xc017439b147b6a77, 0x100d7b2e28c65bfe,
    0xccf205c4ed9243f2, 0x19af2b7d0e0a2cca,
    0x0a5b37d0be0e9cc2, 0x148c22ca71a1bd6f,
    0x0848f973cb3ee3ce, 0x10701bd527b4978c,
    0xda0e5bec78649fb0, 0x1a4cf9550c5425ac,
    0x7b3eaff060507fc0, 0x150a6110d6a9b7bd,
    0x95cbbff380406633, 0x10d51a73deee2c97,
    0xefac665266cd7052, 0x1aee90b964b04758,
    0x2623850eb8a459db, 0x158ba6fab6f36c47,
    0x1e82d0d893b6ae49, 0x113c85955f29236c,
    0xfd9e1af41f8ab075, 0x1b9408eefea838ac,
    0x97b1af29b2d559f7, 0x16100725988693bd,
    0xac8e25baf5777b2c, 0x11a66c1e139edc97,
    0x7a7d092b2258c513, 0x1c3d79c9b8fe2dbf,
    0x61fda0ef4ead6a76, 0x169794a160cb57cc,
    0xe7fe1a590bbdeec5, 0x1212dd4de7091309,
    0xa6635d5b45fcb13a, 0x1ceafbafd80e84dc,
    0x851c4aaf6b308dc8, 0x172262f3133ed0b0,
    0xd0e36ef2bc26d7d4, 0x1281e8c275cbda26,
    0xb49f17eac6a48c86, 0x1d9ca79d894629d7,
    0x2a18dfef0550706b, 0x17b08617a104ee46,
    0x54e0b3259dd9f389, 0x12f39e794d9d8b6b,
    0x87cdeb6f62f65274, 0x1e5297287c2f4578,
    0xd30b22bf825ea85d, 0x18421286c9bf6ac6,
    0x0f3c1bcc684bb9e4, 0x13680ed23aff889f,
    0x18602c7a4079296d, 0x1f0ce4839198da98,
    0x46b356c833942124, 0x18d71d360e13e213,
    0x388f78a029434db6, 0x13df4a91a4dcb4dc,
    0x5a7f2766a86baf8a, 0x1fcbaa82a1612160,
    0x153285ebb9efbfa2, 0x196fbb9bb44db44d,
    0xaa8ed189618c994e, 0x145962e2f6a4903d,
    0xeed8a7a11ad6e10c, 0x1047824f2bb6d9ca,
    0x7e27729b5e249b45, 0x1a0c03b1df8af611,
    0xfe85f549181d4904, 0x14d6695b193bf80d,
    0xcb9e5dd4134aa0d0, 0x10ab877c142ff9a4,
    0xdf63c9535211014d, 0x1aac0bf9b9e65c3a,
    0x191ca10f74da6771, 0x15566ffafb1eb02f,
    0xadb080d92a4852c1, 0x1111f32f2f4bc025,
    0x15e7348eaa0d5134, 0x1b4feb7eb212cd09,
    0xab1f5d3eee710dc4, 0x15d98932280f0a6d,
    0xbc1917658b8da49d, 0x117ad428200c0857,
    0x2cf4f23c127c3a94, 0x1bf7b9d9cce00d59,
    0xf0c3f4fcdb969543, 0x165fc7e170b33de0,
    0x5a365d9716121103, 0x11e6398126f5cb1a,
    0x9056fc24f01ce804, 0x1ca38f350b22de90,
    0xd9df301d8ce3ecd0, 0x16e93f5da2824ba6,
    0xe17f59b13d8323da, 0x125432b14ecea2eb,
    0x68cbc2b52f38395c, 0x1d53844ee47dd179,
    0x53d6355dbf602de3, 0x177603725064a794,
    0xa9782ab165e68b1c, 0x12c4cf8ea6b6ec76,
    0x0f26aab56fd744fa, 0x1e07b27dd78b13f1,
    0x3f52222abfdf6a62, 0x18062864ac6f4327,
    0x65db4e88997f884e, 0x1338205089f29c1f,
    0x6fc54a7428cc0d4a, 0x1ec033b40fea9365,
    0x596aa1f68709a43b, 0x1899c2f673220f84,
    0xadeee7f86c07b696, 0x13ae3591f5b4d936,
    0x497e3ff3e00c5756, 0x1f7d228322baf524,
    0xd464fff64cd6ac45, 0x1930e868e89590e9,
    0x4383fff83d7889d1, 0x14272053ed4473ee,
    0xcf9cccc69793a174, 0x101f4d0ff1038ff1,
    0x7f6147a425b90252, 0x19cbae7fe805b31c,
    0xcc4dd2e9b7c7350f, 0x14a2f1ffecd15c16,
    0x3d0b0f215fd290d9, 0x10825b3323dab012,
    0x61ab4b689950e7c1, 0x1a6a2b85062ab350,
    0x4e22a2ba1440b967, 0x1521bc6a6b555c40,
    0x0b4ee894dd009453, 0x10e7c9eebc4449cd,
    0x1217da87c800ed51, 0x1b0c764ac6d3a948,
    0xdb46486ca000bdda, 0x15a391d56bdc876c,
    0x490506bd4ccd64af, 0x114fa7ddefe39f8a,
    0xa8080ac87ae23ab1, 0x1bb2a62fe638ff43,
    0x5339a239fbe82ef4, 0x162884f31e93ff69,
    0x75c7b4fb2fecf25d, 0x11ba03f5b20fff87,
    0x22d92191e647ea2e, 0x1c5cd322b67fff3f,
    0xb57a8141850654f2, 0x16b0a8e891ffff65,
    0xc4620101373843f5, 0x1226ed86db3332b7,
    0x3a366801f1f39fee, 0x1d0b15a491eb8459,
    0xfb5eb99b27f6198b, 0x173c115074bc69e0,
    0x2f7efae2865e7ad6, 0x129674405d6387e7,
    0xe597f7d0d6fd9156, 0x1dbd86cd6238d971,
    0x8479930d78cadaab, 0x17cad23de82d7ac1,
    0xd06142712d6f1556, 0x1308a831868ac89a,
    0x4d686a4eaf182222, 0x1e74404f3daada91,
    0xa453883ef279b4e8, 0x185d003f6488aeda,
    0xe9dc6cff28615d87, 0x137d99cc506d58ae,
    0xa960ae650d6895a4, 0x1f2f5c7a1a488de4,
    0xbab3beb73ded4483, 0x18f2b061aea07183,
    0x2ef6322c318a9d36, 0x13f559e7bee6c136,
    0xe4bd1d13827761f0, 0x1feef63f97d79b89,
    0x83ca7da9352c4e5a, 0x198bf832dfdfafa1,
    0x9ca1fe20f756a515, 0x146ff9c24cb2f2e7,
    0x4a1b31b3f9121daa, 0x1059949b708f28b9,
    0x435eb5ecc1b695dd, 0x1a28edc580e50df5,
    0x35e55e57015ede4a, 0x14ed8b04671da4c4,
    0xc4b77eac0118b1d5, 0x10be08d0527e1d69,
    0xa12597799b5ab622, 0x1ac9a7b3b7302f0f,
    0x4db7ac6149155e81, 0x156e1fc2f8f358d9,
    0xd7c6238107444b9b, 0x1124e63593f5e0ad,
    0x593d059b3ed3ac2b, 0x1b6e3d2286563449,
    0xe0fd9e15cbdc89bc, 0x15f1ca820511c36d,
    0xb3fe18116fe3a163, 0x118e3b9b37416924,
    0x866359b57fd29bd1, 0x1c16c5c525357507,
    0xd1e91491330ee30e, 0x16789e3750f790d2,
    0x74ba76da8f3f1c0b, 0x11fa182c40c60d75,
    0xedf72490e531c678, 0x1cc359e067a348bb,
    0x8b2c1d40b75b052d, 0x1702ae4d1fb5d3c9,
    0x6f567dcd5f7c0424, 0x12688b70e62b0fd4,
    0x7ef0c94898c66d06, 0x1d74124e3d11b2ed,
    0x98c0a106e09ebd9f, 0x17900ea4fda7c257,
    0x470080d24d4bcae6, 0x12d9a550caec9b79,
    0xd800ce1d487944a2, 0x1e29088144adc58e,
    0x1333d8176d2dd082, 0x1820d39a9d57d13f,
    0xa8f646792424a6ce, 0x134d76154aaca765,
    0x74bd3d8ea03aa47d, 0x1ee25688777aa56f,
    0x5d64313ee6955064, 0x18b51206c5fbb78c,
    0x4ab68dcbebaaa6b7, 0x13c40e6bd1962c70,
    0x1124161312aaa457, 0x1fa01712e8f0471a,
    0xda8344dc0eeee9df, 0x194cdf4253f36c14,
    0xe2029d7cd8bf2180, 0x143d7f6843292343,
    0x4e687dfd7a328133, 0x103132b9cf541c36,
    0x4a40c9959050ceb8, 0x19e851294bb9c6bd,
    0x0833d477a6a70bc6, 0x14b9da876fc7d231,
    0xa02976c61eec096b, 0x1094aed2bfd30e8d,
    0x004257a364acdbdf, 0x1a877e1dffb81749,
    0xcd01dfb5ea23e319, 0x153931b1996012a0,
    0x70ce4c91881cb5ae, 0x10fa8e27ade6754d,
    0x1ae3adb5a69455e2, 0x1b2a7d0c4970bbaf,
    0x7be957c4854377e8, 0x15bb973d078d62f2,
    0xc987796a0435f987, 0x1162df64060ab58e,
    0x75a58f1006bcc271, 0x1bd1656cd67788e4,
    0xf7b7a5a66bca3527, 0x16411df0ab92d3e9,
    0x5fc61e1ebca1c41f, 0x11cdb18d560f0fee,
    0xffa363646102d365, 0x1c7c4f4889b1b316,
    0x32e91c504d9bdc51, 0x16c9d906d48e28df,
    0x8f20e37371497d0e, 0x123b140576d820b2,
    0x7e9b0585820f2e7c, 0x1d2b533bf159cdea,
    0xcbaf379e01a5beca, 0x1755dc2ff447d7ee,
    0x0958f94b348498a1, 0x12ab168cc36cacbf,
];

// 326 (lo, hi) pairs, flattened: entry i is [2*i] = lo, [2*i+1] = hi.
const DOUBLE_POW5_SPLIT: StaticArray<u64> = [
    0x0000000000000000, 0x1000000000000000,
    0x0000000000000000, 0x1400000000000000,
    0x0000000000000000, 0x1900000000000000,
    0x0000000000000000, 0x1f40000000000000,
    0x0000000000000000, 0x1388000000000000,
    0x0000000000000000, 0x186a000000000000,
    0x0000000000000000, 0x1e84800000000000,
    0x0000000000000000, 0x1312d00000000000,
    0x0000000000000000, 0x17d7840000000000,
    0x0000000000000000, 0x1dcd650000000000,
    0x0000000000000000, 0x12a05f2000000000,
    0x0000000000000000, 0x174876e800000000,
    0x0000000000000000, 0x1d1a94a200000000,
    0x0000000000000000, 0x12309ce540000000,
    0x0000000000000000, 0x16bcc41e90000000,
    0x0000000000000000, 0x1c6bf52634000000,
    0x0000000000000000, 0x11c37937e0800000,
    0x0000000000000000, 0x16345785d8a00000,
    0x0000000000000000, 0x1bc16d674ec80000,
    0x0000000000000000, 0x1158e460913d0000,
    0x0000000000000000, 0x15af1d78b58c4000,
    0x0000000000000000, 0x1b1ae4d6e2ef5000,
    0x0000000000000000, 0x10f0cf064dd59200,
    0x0000000000000000, 0x152d02c7e14af680,
    0x0000000000000000, 0x1a784379d99db420,
    0x0000000000000000, 0x108b2a2c28029094,
    0x0000000000000000, 0x14adf4b7320334b9,
    0x4000000000000000, 0x19d971e4fe8401e7,
    0x8800000000000000, 0x1027e72f1f128130,
    0xaa00000000000000, 0x1431e0fae6d7217c,
    0xd480000000000000, 0x193e5939a08ce9db,
    0xc9a0000000000000, 0x1f8def8808b02452,
    0xbe04000000000000, 0x13b8b5b5056e16b3,
    0xad85000000000000, 0x18a6e32246c99c60,
    0xd8e6400000000000, 0x1ed09bead87c0378,
    0x878fe80000000000, 0x13426172c74d822b,
    0x6973e20000000000, 0x1812f9cf7920e2b6,
    0x03d0da8000000000, 0x1e17b84357691b64,
    0x8262889000000000, 0x12ced32a16a1b11e,
    0x22fb2ab400000000, 0x178287f49c4a1d66,
    0xabb9f56100000000, 0x1d6329f1c35ca4bf,
    0xcb54395ca0000000, 0x125dfa371a19e6f7,
    0xbe2947b3c8000000, 0x16f578c4e0a060b5,
    0x2db399a0ba000000, 0x1cb2d6f618c878e3,
    0xfc90400474400000, 0x11efc659cf7d4b8d,
    0x7bb4500591500000, 0x166bb7f0435c9e71,
    0xdaa16406f5a40000, 0x1c06a5ec5433c60d,
    0xa8a4de8459868000, 0x118427b3b4a05bc8,
    0xd2ce16256fe82000, 0x15e531a0a1c872ba,
    0x87819baecbe22800, 0x1b5e7e08ca3a8f69,
    0xf4b1014d3f6d5900, 0x111b0ec57e6499a1,
    0x71dd41a08f48af40, 0x1561d276ddfdc00a,
    0x0e549208b31adb10, 0x1aba4714957d300d,
    0x28f4db456ff0c8ea, 0x10b46c6cdd6e3e08,
    0x33321216cbecfb24, 0x14e1878814c9cd8a,
    0xbffe969c7ee839ed, 0x1a19e96a19fc40ec,
    0xf7ff1e21cf512434, 0x105031e2503da893,
    0xf5fee5aa43256d41, 0x14643e5ae44d12b8,
    0x337e9f14d3eec892, 0x197d4df19d605767,
    0x005e46da08ea7ab6, 0x1fdca16e04b86d41,
    0xa03aec4845928cb2, 0x13e9e4e4c2f34448,
    0xc849a75a56f72fde, 0x18e45e1df3b0155a,
    0x7a5c1130ecb4fbd6, 0x1f1d75a5709c1ab1,
    0xec798abe93f11d65, 0x13726987666190ae,
    0xa797ed6e38ed64bf, 0x184f03e93ff9f4da,
    0x517de8c9c728bdef, 0x1e62c4e38ff87211,
    0xd2eeb17e1c7976b5, 0x12fdbb0e39fb474a,
    0x87aa5ddda397d462, 0x17bd29d1c87a191d,
    0xe994f5550c7dc97b, 0x1dac74463a989f64,
    0x11fd195527ce9ded, 0x128bc8abe49f639f,
    0xd67c5faa71c24568, 0x172ebad6ddc73c86,
    0x8c1b77950e32d6c2, 0x1cfa698c95390ba8,
    0x57912abd28dfc639, 0x121c81f7dd43a749,
    0xad75756c7317b7c8, 0x16a3a275d494911b,
    0x98d2d2c78fdda5ba, 0x1c4c8b1349b9b562,
    0x9f83c3bcb9ea8794, 0x11afd6ec0e14115d,
    0x0764b4abe8652979, 0x161bcca7119915b5,
    0x493de1d6e27e73d7, 0x1ba2bfd0d5ff5b22,
    0x6dc6ad264d8f0866, 0x1145b7e285bf98f5,
    0xc938586fe0f2ca80, 0x159725db272f7f32,
    0x7b866e8bd92f7d20, 0x1afcef51f0fb5eff,
    0xad34051767bdae34, 0x10de1593369d1b5f,
    0x9881065d41ad19c1, 0x15159af804446237,
    0x7ea147f492186032, 0x1a5b01b605557ac5,
    0x6f24ccf8db4f3c1f, 0x1078e111c3556cbb,
    0x4aee003712230b27, 0x14971956342ac7ea,
    0xdda98044d6abcdf0, 0x19bcdfabc13579e4,
    0x0a89f02b062b60b6, 0x10160bcb58c16c2f,
    0xcd2c6c35c7b638e4, 0x141b8ebe2ef1c73a,
    0x8077874339a3c71d, 0x1922726dbaae3909,
    0xe0956914080cb8e4, 0x1f6b0f092959c74b,
    0x6c5d61ac8507f38e, 0x13a2e965b9d81c8f,
    0x4774ba17a649f072, 0x188ba3bf284e23b3,
    0x1951e89d8fdc6c8f, 0x1eae8caef261aca0,
    0x0fd3316279e9c3d9, 0x132d17ed577d0be4,
    0x13c7fdbb186434cf, 0x17f85de8ad5c4edd,
    0x58b9fd29de7d4203, 0x1df67562d8b36294,
    0xb7743e3a2b0e4942, 0x12ba095dc7701d9c,
    0xe5514dc8b5d1db92, 0x17688bb5394c2503,
    0xdea5a13ae3465277, 0x1d42aea2879f2e44,
    0x0b2784c4ce0bf38a, 0x1249ad2594c37ceb,
    0xcdf165f6018ef06d, 0x16dc186ef9f45c25,
    0x416dbf7381f2ac88, 0x1c931e8ab871732f,
    0x88e497a83137abd5, 0x11dbf316b346e7fd,
    0xeb1dbd923d8596ca, 0x1652efdc6018a1fc,
    0x25e52cf6cce6fc7d, 0x1be7abd3781eca7c,
    0x97af3c1a40105dce, 0x1170cb642b133e8d,
    0xfd9b0b20d0147542, 0x15ccfe3d35d80e30,
    0x3d01cde904199292, 0x1b403dcc834e11bd,
    0x462120b1a28ffb9b, 0x1108269fd210cb16,
    0xd7a968de0b33fa82, 0x154a3047c694fddb,
    0xcd93c3158e00f923, 0x1a9cbc59b83a3d52,
    0xc07c59ed78c09bb6, 0x10a1f5b813246653,
    0xb09b7068d6f0c2a3, 0x14ca732617ed7fe8,
    0xdcc24c830cacf34c, 0x19fd0fef9de8dfe2,
    0xc9f96fd1e7ec180f, 0x103e29f5c2b18bed,
    0x3c77cbc661e71e13, 0x144db473335deee9,
    0x8b95beb7fa60e598, 0x1961219000356aa3,
    0x6e7b2e65f8f91efe, 0x1fb969f40042c54c,
    0xc50cfcffbb9bb35f, 0x13d3e2388029bb4f,
    0xb6503c3faa82a037, 0x18c8dac6a0342a23,
    0xa3e44b4f95234844, 0x1efb1178484134ac,
    0xe66eaf11bd360d2b, 0x135ceaeb2d28c0eb,
    0xe00a5ad62c839075, 0x183425a5f872f126,
    0x980cf18bb7a47493, 0x1e412f0f768fad70,
    0x5f0816f752c6c8dc, 0x12e8bd69aa19cc66,
    0xf6ca1cb527787b13, 0x17a2ecc414a03f7f,
    0xf47ca3e2715699d7, 0x1d8ba7f519c84f5f,
    0xf8cde66d86d62026, 0x127748f9301d319b,
    0xf7016008e88ba830, 0x17151b377c247e02,
    0xb4c1b80b22ae923c, 0x1cda62055b2d9d83,
    0x50f91306f5ad1b65, 0x12087d4358fc8272,
    0xe53757c8b318623f, 0x168a9c942f3ba30e,
    0x9e852dbadfde7acf, 0x1c2d43b93b0a8bd2,
    0xa3133c94cbeb0cc1, 0x119c4a53c4e69763,
    0x8bd80bb9fee5cff1, 0x16035ce8b6203d3c,
    0xaece0ea87e9f43ee, 0x1b843422e3a84c8b,
    0x4d40c9294f238a75, 0x1132a095ce492fd7,
    0x2090fb73a2ec6d12, 0x157f48bb41db7bcd,
    0x68b53a508ba78856, 0x1adf1aea12525ac0,
    0x417144725748b536, 0x10cb70d24b7378b8,
    0x51cd958eed1ae283, 0x14fe4d06de5056e6,
    0xe640faf2a8619b24, 0x1a3de04895e46c9f,
    0xefe89cd7a93d00f7, 0x1066ac2d5daec3e3,
    0xebe2c40d938c4134, 0x14805738b51a74dc,
    0x26db7510f86f5181, 0x19a06d06e2611214,
    0x9849292a9b4592f1, 0x100444244d7cab4c,
    0xbe5b73754216f7ad, 0x1405552d60dbd61f,
    0xadf25052929cb598, 0x1906aa78b912cba7,
    0x996ee4673743e2ff, 0x1f485516e7577e91,
    0xffe54ec0828a6ddf, 0x138d352e5096af1a,
    0xbfdea270a32d0957, 0x18708279e4bc5ae1,
    0x2fd64b0ccbf84bad, 0x1e8ca3185deb719a,
    0x5de5eee7ff7b2f4c, 0x1317e5ef3ab32700,
    0x755f6aa1ff59fb1f, 0x17dddf6b095ff0c0,
    0x92b7454a7f3079e7, 0x1dd55745cbb7ecf0,
    0x5bb28b4e8f7e4c30, 0x12a5568b9f52f416,
    0xf29f2e22335ddf3c, 0x174eac2e8727b11b,
    0xef46f9aac035570b, 0x1d22573a28f19d62,
    0xd58c5c0ab8215667, 0x123576845997025d,
    0x4aef730d6629ac01, 0x16c2d4256ffcc2f5,
    0x9dab4fd0bfb41701, 0x1c73892ecbfbf3b2,
    0xa28b11e277d08e60, 0x11c835bd3f7d784f,
    0x8b2dd65b15c4b1f9, 0x163a432c8f5cd663,
    0x6df94bf1db35de77, 0x1bc8d3f7b3340bfc,
    0xc4bbcf772901ab0a, 0x115d847ad000877d,
    0x35eac354f34215cd, 0x15b4e5998400a95d,
    0x8365742a30129b40, 0x1b221effe500d3b4,
    0xd21f689a5e0ba108, 0x10f5535fef208450,
    0x06a742c0f58e894a, 0x1532a837eae8a565,
    0x4851137132f22b9d, 0x1a7f5245e5a2cebe,
    0xed32ac26bfd75b42, 0x108f936baf85c136,
    0xa87f57306fcd3212, 0x14b378469b673184,
    0xd29f2cfc8bc07e97, 0x19e056584240fde5,
    0xa3a37c1dd7584f1e, 0x102c35f729689eaf,
    0x8c8c5b254d2e62e6, 0x14374374f3c2c65b,
    0x6faf71eea079fb9f, 0x1945145230b377f2,
    0x0b9b4e6a48987a87, 0x1f965966bce055ef,
    0x674111026d5f4c94, 0x13bdf7e0360c35b5,
    0xc111554308b71fba, 0x18ad75d8438f4322,
    0x7155aa93cae4e7a8, 0x1ed8d34e547313eb,
    0x26d58a9c5ecf10c9, 0x13478410f4c7ec73,
    0xf08aed437682d4fb, 0x1819651531f9e78f,
    0xecada89454238a3a, 0x1e1fbe5a7e786173,
    0x73ec895cb4963664, 0x12d3d6f88f0b3ce8,
    0x90e7abb3e1bbc3fd, 0x1788ccb6b2ce0c22,
    0x352196a0da2ab4fd, 0x1d6affe45f818f2b,
    0x0134fe24885ab11e, 0x1262dfeebbb0f97b,
    0xc1823dadaa715d65, 0x16fb97ea6a9d37d9,
    0x31e2cd19150db4bf, 0x1cba7de5054485d0,
    0x1f2dc02fad2890f7, 0x11f48eaf234ad3a2,
    0xa6f9303b9872b535, 0x1671b25aec1d888a,
    0x50b77c4a7e8f6282, 0x1c0e1ef1a724eaad,
    0x5272adae8f199d91, 0x1188d357087712ac,
    0x670f591a32e004f6, 0x15eb082cca94d757,
    0x40d32f60bf980633, 0x1b65ca37fd3a0d2d,
    0x4883fd9c77bf03e0, 0x111f9e62fe44483c,
    0x5aa4fd0395aec4d8, 0x156785fbbdd55a4b,
    0x314e3c447b1a760e, 0x1ac1677aad4ab0de,
    0xded0e5aaccf089c9, 0x10b8e0acac4eae8a,
    0x96851f15802cac3b, 0x14e718d7d7625a2d,
    0xfc2666dae037d74a, 0x1a20df0dcd3af0b8,
    0x9d980048cc22e68e, 0x10548b68a044d673,
    0x84fe005aff2ba032, 0x1469ae42c8560c10,
    0xa63d8071bef6883e, 0x198419d37a6b8f14,
    0xcfcce08e2eb42a4e, 0x1fe52048590672d9,
    0x21e00c58dd309a70, 0x13ef342d37a407c8,
    0x2a580f6f147cc10d, 0x18eb0138858d09ba,
    0xb4ee134ad99bf150, 0x1f25c186a6f04c28,
    0x7114cc0ec80176d2, 0x137798f428562f99,
    0xcd59ff127a01d486, 0x18557f31326bbb7f,
    0xc0b07ed7188249a8, 0x1e6adefd7f06aa5f,
    0xd86e4f466f516e09, 0x1302cb5e6f642a7b,
    0xce89e3180b25c98b, 0x17c37e360b3d351a,
    0x822c5bde0def3bee, 0x1db45dc38e0c8261,
    0xf15bb96ac8b58575, 0x1290ba9a38c7d17c,
    0x2db2a7c57ae2e6d2, 0x1734e940c6f9c5dc,
    0x391f51b6d99ba086, 0x1d022390f8b83753,
    0x03b3931248014454, 0x1221563a9b732294,
    0x04a077d6da019569, 0x16a9abc9424feb39,
    0x45c895cc9081fac3, 0x1c5416bb92e3e607,
    0x8b9d5d9fda513cba, 0x11b48e353bce6fc4,
    0xae84b507d0e58be8, 0x1621b1c28ac20bb5,
    0x1a25e249c51eeee3, 0x1baa1e332d728ea3,
    0xf057ad6e1b33554d, 0x114a52dffc679925,
    0x6c6d98c9a2002aa1, 0x159ce797fb817f6f,
    0x4788fefc0a803549, 0x1b04217dfa61df4b,
    0x0cb59f5d8690214e, 0x10e294eebc7d2b8f,
    0xcfe30734e83429a1, 0x151b3a2a6b9c7672,
    0x83dbc9022241340a, 0x1a6208b50683940f,
    0xb2695da15568c086, 0x107d457124123c89,
    0x1f03b509aac2f0a7, 0x149c96cd6d16cbac,
    0x26c4a24c1573acd1, 0x19c3bc80c85c7e97,
    0x783ae56f8d684c03, 0x101a55d07d39cf1e,
    0x16499ecb70c25f03, 0x1420eb449c8842e6,
    0x9bdc067e4cf2f6c4, 0x19292615c3aa539f,
    0x82d3081de02fb476, 0x1f736f9b3494e887,
    0xb1c3e512ac1dd0c9, 0x13a825c100dd1154,
    0xde34de57572544fc, 0x18922f31411455a9,
    0x55c215ed2cee963b, 0x1eb6bafd91596b14,
    0xb5994db43c151de5, 0x133234de7ad7e2ec,
    0xe2ffa1214b1a655e, 0x17fec216198ddba7,
    0xdbbf89699de0feb6, 0x1dfe729b9ff15291,
    0x2957b5e202ac9f31, 0x12bf07a143f6d39b,
    0xf3ada35a8357c6fe, 0x176ec98994f48881,
    0x70990c31242db8bd, 0x1d4a7bebfa31aaa2,
    0x865fa79eb69c9376, 0x124e8d737c5f0aa5,
    0xe7f791866443b854, 0x16e230d05b76cd4e,
    0xa1f575e7fd54a669, 0x1c9abd04725480a2,
    0xa53969b0fe54e801, 0x11e0b622c774d065,
    0x0e87c41d3dea2202, 0x1658e3ab7952047f,
    0xd229b5248d64aa82, 0x1bef1c9657a6859e,
    0x435a1136d85eea91, 0x117571ddf6c81383,
    0x143095848e76a536, 0x15d2ce55747a1864,
    0x193cbae5b2144e83, 0x1b4781ead1989e7d,
    0x2fc5f4cf8f4cb112, 0x110cb132c2ff630e,
    0xbbb77203731fdd56, 0x154fdd7f73bf3bd1,
    0x2aa54e844fe7d4ac, 0x1aa3d4df50af0ac6,
    0xdaa75112b1f0e4eb, 0x10a6650b926d66bb,
    0xd15125575e6d1e26, 0x14cffe4e7708c06a,
    0x85a56ead360865b0, 0x1a03fde214caf085,
    0x7387652c41c53f8e, 0x10427ead4cfed653,
    0x50693e7752368f71, 0x14531e58a03e8be8,
    0x64838e1526c4334e, 0x1967e5eec84e2ee2,
    0xfda4719a70754022, 0x1fc1df6a7a61ba9a,
    0xde86c70086494815, 0x13d92ba28c7d14a0,
    0x162878c0a7db9a1a, 0x18cf768b2f9c59c9,
    0x5bb296f0d1d280a1, 0x1f03542dfb83703b,
    0x194f9e5683239064, 0x1362149cbd322625,
    0x5fa385ec23ec747e, 0x183a99c3ec7eafae,
    0xf78c67672ce7919d, 0x1e494034e79e5b99,
    0x3ab7c0a07c10bb02, 0x12edc82110c2f940,
    0x4965b0c89b14e9c3, 0x17a93a2954f3b790,
    0x5bbf1cfac1da2433, 0x1d9388b3aa30a574,
    0xb957721cb92856a0, 0x127c35704a5e6768,
    0xe7ad4ea3e7726c48, 0x171b42cc5cf60142,
    0xa198a24ce14f075a, 0x1ce2137f74338193,
    0x44ff65700cd16498, 0x120d4c2fa8a030fc,
    0x563f3ecc1005bdbe, 0x16909f3b92c83d3b,
    0x2bcf0e7f14072d2e, 0x1c34c70a777a4c8a,
    0x5b61690f6c847c3d, 0x11a0fc668aac6fd6,
    0xf239c35347a59b4c, 0x16093b802d578bcb,
    0xeec83428198f021f, 0x1b8b8a6038ad6ebe,
    0x553d20990ff96153, 0x1137367c236c6537,
    0x2a8c68bf53f7b9a8, 0x1585041b2c477e85,
    0x752f82ef28f5a812, 0x1ae64521f7595e26,
    0x093db1d57999890b, 0x10cfeb353a97dad8,
    0x0b8d1e4ad7ffeb4e, 0x1503e602893dd18e,
    0x8e7065dd8dffe622, 0x1a44df832b8d45f1,
    0xf9063faa78bfefd5, 0x106b0bb1fb384bb6,
    0xb747cf9516efebca, 0x1485ce9e7a065ea4,
    0xe519c37a5cabe6bd, 0x19a742461887f64d,
    0xaf301a2c79eb7036, 0x1008896bcf54f9f0,
    0xdafc20b798664c43, 0x140aabc6c32a386c,
    0x11bb28e57e7fdf54, 0x190d56b873f4c688,
    0x1629f31ede1fd72a, 0x1f50ac6690f1f82a,
    0x4dda37f34ad3e67a, 0x13926bc01a973b1a,
    0xe150c5f01d88e019, 0x187706b0213d09e0,
    0x19a4f76c24eb181f, 0x1e94c85c298c4c59,
    0xb0071aa39712ef13, 0x131cfd3999f7afb7,
    0x9c08e14c7cd7aad8, 0x17e43c8800759ba5,
    0x030b199f9c0d958e, 0x1ddd4baa0093028f,
    0x61e6f003c1887d79, 0x12aa4f4a405be199,
    0xba60ac04b1ea9cd7, 0x1754e31cd072d9ff,
    0xa8f8d705de65440d, 0x1d2a1be4048f907f,
    0xc99b8663aaff4a88, 0x123a516e82d9ba4f,
    0xbc0267fc95bf1d2a, 0x16c8e5ca239028e3,
    0xab0301fbbb2ee474, 0x1c7b1f3cac74331c,
    0xeae1e13d54fd4ec9, 0x11ccf385ebc89ff1,
    0x659a598caa3ca27b, 0x1640306766bac7ee,
    0xff00efefd4cbcb1a, 0x1bd03c81406979e9,
    0x3f6095f5e4ff5ef0, 0x116225d0c841ec32,
    0xcf38bb735e3f36ac, 0x15baaf44fa52673e,
    0x8306ea5035cf0457, 0x1b295b1638e7010e,
    0x11e4527221a162b6, 0x10f9d8ede39060a9,
    0x565d670eaa09bb64, 0x15384f295c7478d3,
    0x2bf4c0d2548c2a3d, 0x1a8662f3b3919708,
    0x1b78f88374d79a66, 0x1093fdd8503afe65,
    0x625736a4520d8100, 0x14b8fd4e6449bdfe,
    0xfaed044d6690e140, 0x19e73ca1fd5c2d7d,
    0xbcd422b0601a8cc8, 0x103085e53e599c6e,
    0x6c092b5c78212ffa, 0x143ca75e8df0038a,
    0x070b763396297bf8, 0x194bd136316c046d,
    0x48ce53c07bb3daf6, 0x1f9ec583bdc70588,
    0x2d80f4584d5068da, 0x13c33b72569c6375,
    0x78e1316e60a48310, 0x18b40a4eec437c52,
];

// 907 inclusive [first, last] code point ranges (>= U+0080) that debugStr /
// debugChar escape as \u{..} (non-printable or grapheme-extend).

const DEBUG_ESCAPE_RANGES: StaticArray<u32> = [
    0x80, 0xa0, 0xad, 0xad, 0x300, 0x36f, 0x378, 0x379, 0x380, 0x383, 0x38b, 0x38b, 0x38d, 0x38d,
    0x3a2, 0x3a2, 0x483, 0x489, 0x530, 0x530, 0x557, 0x558, 0x58b, 0x58c, 0x590, 0x5bd,
    0x5bf, 0x5bf, 0x5c1, 0x5c2, 0x5c4, 0x5c5, 0x5c7, 0x5cf, 0x5eb, 0x5ee, 0x5f5, 0x605,
    0x610, 0x61a, 0x61c, 0x61c, 0x64b, 0x65f, 0x670, 0x670, 0x6d6, 0x6dd, 0x6df, 0x6e4,
    0x6e7, 0x6e8, 0x6ea, 0x6ed, 0x70e, 0x70f, 0x711, 0x711, 0x730, 0x74c, 0x7a6, 0x7b0,
    0x7b2, 0x7bf, 0x7eb, 0x7f3, 0x7fb, 0x7fd, 0x816, 0x819, 0x81b, 0x823, 0x825, 0x827,
    0x829, 0x82f, 0x83f, 0x83f, 0x859, 0x85d, 0x85f, 0x85f, 0x86b, 0x86f, 0x890, 0x89f,
    0x8ca, 0x902, 0x93a, 0x93a, 0x93c, 0x93c, 0x941, 0x948, 0x94d, 0x94d, 0x951, 0x957,
    0x962, 0x963, 0x981, 0x981, 0x984, 0x984, 0x98d, 0x98e, 0x991, 0x992, 0x9a9, 0x9a9,
    0x9b1, 0x9b1, 0x9b3, 0x9b5, 0x9ba, 0x9bc, 0x9be, 0x9be, 0x9c1, 0x9c6, 0x9c9, 0x9ca,
    0x9cd, 0x9cd, 0x9cf, 0x9db, 0x9de, 0x9de, 0x9e2, 0x9e5, 0x9fe, 0xa02, 0xa04, 0xa04,
    0xa0b, 0xa0e, 0xa11, 0xa12, 0xa29, 0xa29, 0xa31, 0xa31, 0xa34, 0xa34, 0xa37, 0xa37,
    0xa3a, 0xa3d, 0xa41, 0xa58, 0xa5d, 0xa5d, 0xa5f, 0xa65, 0xa70, 0xa71, 0xa75, 0xa75,
    0xa77, 0xa82, 0xa84, 0xa84, 0xa8e, 0xa8e, 0xa92, 0xa92, 0xaa9, 0xaa9, 0xab1, 0xab1,
    0xab4, 0xab4, 0xaba, 0xabc, 0xac1, 0xac8, 0xaca, 0xaca, 0xacd, 0xacf, 0xad1, 0xadf,
    0xae2, 0xae5, 0xaf2, 0xaf8, 0xafa, 0xb01, 0xb04, 0xb04, 0xb0d, 0xb0e, 0xb11, 0xb12,
    0xb29, 0xb29, 0xb31, 0xb31, 0xb34, 0xb34, 0xb3a, 0xb3c, 0xb3e, 0xb3f, 0xb41, 0xb46,
    0xb49, 0xb4a, 0xb4d, 0xb5b, 0xb5e, 0xb5e, 0xb62, 0xb65, 0xb78, 0xb82, 0xb84, 0xb84,
    0xb8b, 0xb8d, 0xb91, 0xb91, 0xb96, 0xb98, 0xb9b, 0xb9b, 0xb9d, 0xb9d, 0xba0, 0xba2,
    0xba5, 0xba7, 0xbab, 0xbad, 0xbba, 0xbbe, 0xbc0, 0xbc0, 0xbc3, 0xbc5, 0xbc9, 0xbc9,
    0xbcd, 0xbcf, 0xbd1, 0xbe5, 0xbfb, 0xc00, 0xc04, 0xc04, 0xc0d, 0xc0d, 0xc11, 0xc11,
    0xc29, 0xc29, 0xc3a, 0xc3c, 0xc3e, 0xc40, 0xc45, 0xc57, 0xc5b, 0xc5b, 0xc5e, 0xc5f,
    0xc62, 0xc65, 0xc70, 0xc76, 0xc81, 0xc81, 0xc8d, 0xc8d, 0xc91, 0xc91, 0xca9, 0xca9,
    0xcb4, 0xcb4, 0xcba, 0xcbc, 0xcbf, 0xcc0, 0xcc2, 0xcc2, 0xcc5, 0xcdb, 0xcdf, 0xcdf,
    0xce2, 0xce5, 0xcf0, 0xcf0, 0xcf4, 0xd01, 0xd0d, 0xd0d, 0xd11, 0xd11, 0xd3b, 0xd3c,
    0xd3e, 0xd3e, 0xd41, 0xd45, 0xd49, 0xd49, 0xd4d, 0xd4d, 0xd50, 0xd53, 0xd57, 0xd57,
    0xd62, 0xd65, 0xd80, 0xd81, 0xd84, 0xd84, 0xd97, 0xd99, 0xdb2, 0xdb2, 0xdbc, 0xdbc,
    0xdbe, 0xdbf, 0xdc7, 0xdcf, 0xdd2, 0xdd7, 0xddf, 0xde5, 0xdf0, 0xdf1, 0xdf5, 0xe00,
    0xe31, 0xe31, 0xe34, 0xe3e, 0xe47, 0xe4e, 0xe5c, 0xe80, 0xe83, 0xe83, 0xe85, 0xe85,
    0xe8b, 0xe8b, 0xea4, 0xea4, 0xea6, 0xea6, 0xeb1, 0xeb1, 0xeb4, 0xebc, 0xebe, 0xebf,
    0xec5, 0xec5, 0xec7, 0xecf, 0xeda, 0xedb, 0xee0, 0xeff, 0xf18, 0xf19, 0xf35, 0xf35,
    0xf37, 0xf37, 0xf39, 0xf39, 0xf48, 0xf48, 0xf6d, 0xf7e, 0xf80, 0xf84, 0xf86, 0xf87,
    0xf8d, 0xfbd, 0xfc6, 0xfc6, 0xfcd, 0xfcd, 0xfdb, 0xfff, 0x102d, 0x1030, 0x1032, 0x1037,
    0x1039, 0x103a, 0x103d, 0x103e, 0x1058, 0x1059, 0x105e, 0x1060, 0x1071, 0x1074, 0x1082, 0x1082,
    0x1085, 0x1086, 0x108d, 0x108d, 0x109d, 0x109d, 0x10c6, 0x10c6, 0x10c8, 0x10cc, 0x10ce, 0x10cf,
    0x115f, 0x1160, 0x1249, 0x1249, 0x124e, 0x124f, 0x1257, 0x1257, 0x1259, 0x1259, 0x125e, 0x125f,
    0x1289, 0x1289, 0x128e, 0x128f, 0x12b1, 0x12b1, 0x12b6, 0x12b7, 0x12bf, 0x12bf, 0x12c1, 0x12c1,
    0x12c6, 0x12c7, 0x12d7, 0x12d7, 0x1311, 0x1311, 0x1316, 0x1317, 0x135b, 0x135f, 0x137d, 0x137f,
    0x139a, 0x139f, 0x13f6, 0x13f7, 0x13fe, 0x13ff, 0x1680, 0x1680, 0x169d, 0x169f, 0x16f9, 0x16ff,
    0x1712, 0x171e, 0x1732, 0x1734, 0x1737, 0x173f, 0x1752, 0x175f, 0x176d, 0x176d, 0x1771, 0x177f,
    0x17b4, 0x17b5, 0x17b7, 0x17bd, 0x17c6, 0x17c6, 0x17c9, 0x17d3, 0x17dd, 0x17df, 0x17ea, 0x17ef,
    0x17fa, 0x17ff, 0x180b, 0x180f, 0x181a, 0x181f, 0x1879, 0x187f, 0x1885, 0x1886, 0x18a9, 0x18a9,
    0x18ab, 0x18af, 0x18f6, 0x18ff, 0x191f, 0x1922, 0x1927, 0x1928, 0x192c, 0x192f, 0x1932, 0x1932,
    0x1939, 0x193f, 0x1941, 0x1943, 0x196e, 0x196f, 0x1975, 0x197f, 0x19ac, 0x19af, 0x19ca, 0x19cf,
    0x19db, 0x19dd, 0x1a17, 0x1a18, 0x1a1b, 0x1a1d, 0x1a56, 0x1a56, 0x1a58, 0x1a60, 0x1a62, 0x1a62,
    0x1a65, 0x1a6c, 0x1a73, 0x1a7f, 0x1a8a, 0x1a8f, 0x1a9a, 0x1a9f, 0x1aae, 0x1b03, 0x1b34, 0x1b3d,
    0x1b42, 0x1b44, 0x1b4d, 0x1b4d, 0x1b6b, 0x1b73, 0x1b80, 0x1b81, 0x1ba2, 0x1ba5, 0x1ba8, 0x1bad,
    0x1be6, 0x1be6, 0x1be8, 0x1be9, 0x1bed, 0x1bed, 0x1bef, 0x1bfb, 0x1c2c, 0x1c33, 0x1c36, 0x1c3a,
    0x1c4a, 0x1c4c, 0x1c8b, 0x1c8f, 0x1cbb, 0x1cbc, 0x1cc8, 0x1cd2, 0x1cd4, 0x1ce0, 0x1ce2, 0x1ce8,
    0x1ced, 0x1ced, 0x1cf4, 0x1cf4, 0x1cf8, 0x1cf9, 0x1cfb, 0x1cff, 0x1dc0, 0x1dff, 0x1f16, 0x1f17,
    0x1f1e, 0x1f1f, 0x1f46, 0x1f47, 0x1f4e, 0x1f4f, 0x1f58, 0x1f58, 0x1f5a, 0x1f5a, 0x1f5c, 0x1f5c,
    0x1f5e, 0x1f5e, 0x1f7e, 0x1f7f, 0x1fb5, 0x1fb5, 0x1fc5, 0x1fc5, 0x1fd4, 0x1fd5, 0x1fdc, 0x1fdc,
    0x1ff0, 0x1ff1, 0x1ff5, 0x1ff5, 0x1fff, 0x200f, 0x2028, 0x202f, 0x205f, 0x206f, 0x2072, 0x2073,
    0x208f, 0x208f, 0x209d, 0x209f, 0x20c2, 0x20ff, 0x218c, 0x218f, 0x242a, 0x243f, 0x244b, 0x245f,
    0x2b74, 0x2b75, 0x2cef, 0x2cf1, 0x2cf4, 0x2cf8, 0x2d26, 0x2d26, 0x2d28, 0x2d2c, 0x2d2e, 0x2d2f,
    0x2d68, 0x2d6e, 0x2d71, 0x2d7f, 0x2d97, 0x2d9f, 0x2da7, 0x2da7, 0x2daf, 0x2daf, 0x2db7, 0x2db7,
    0x2dbf, 0x2dbf, 0x2dc7, 0x2dc7, 0x2dcf, 0x2dcf, 0x2dd7, 0x2dd7, 0x2ddf, 0x2dff, 0x2e5e, 0x2e7f,
    0x2e9a, 0x2e9a, 0x2ef4, 0x2eff, 0x2fd6, 0x2fef, 0x3000, 0x3000, 0x302a, 0x302f, 0x3040, 0x3040,
    0x3097, 0x309a, 0x3100, 0x3104, 0x3130, 0x3130, 0x3164, 0x3164, 0x318f, 0x318f, 0x31e6, 0x31ee,
    0x321f, 0x321f, 0xa48d, 0xa48f, 0xa4c7, 0xa4cf, 0xa62c, 0xa63f, 0xa66f, 0xa672, 0xa674, 0xa67d,
    0xa69e, 0xa69f, 0xa6f0, 0xa6f1, 0xa6f8, 0xa6ff, 0xa7dd, 0xa7f0, 0xa802, 0xa802, 0xa806, 0xa806,
    0xa80b, 0xa80b, 0xa825, 0xa826, 0xa82c, 0xa82f, 0xa83a, 0xa83f, 0xa878, 0xa87f, 0xa8c4, 0xa8cd,
    0xa8da, 0xa8f1, 0xa8ff, 0xa8ff, 0xa926, 0xa92d, 0xa947, 0xa951, 0xa953, 0xa95e, 0xa97d, 0xa982,
    0xa9b3, 0xa9b3, 0xa9b6, 0xa9b9, 0xa9bc, 0xa9bd, 0xa9c0, 0xa9c0, 0xa9ce, 0xa9ce, 0xa9da, 0xa9dd,
    0xa9e5, 0xa9e5, 0xa9ff, 0xa9ff, 0xaa29, 0xaa2e, 0xaa31, 0xaa32, 0xaa35, 0xaa3f, 0xaa43, 0xaa43,
    0xaa4c, 0xaa4c, 0xaa4e, 0xaa4f, 0xaa5a, 0xaa5b, 0xaa7c, 0xaa7c, 0xaab0, 0xaab0, 0xaab2, 0xaab4,
    0xaab7, 0xaab8, 0xaabe, 0xaabf, 0xaac1, 0xaac1, 0xaac3, 0xaada, 0xaaec, 0xaaed, 0xaaf6, 0xab00,
    0xab07, 0xab08, 0xab0f, 0xab10, 0xab17, 0xab1f, 0xab27, 0xab27, 0xab2f, 0xab2f, 0xab6c, 0xab6f,
    0xabe5, 0xabe5, 0xabe8, 0xabe8, 0xabed, 0xabef, 0xabfa, 0xabff, 0xd7a4, 0xd7af, 0xd7c7, 0xd7ca,
    0xd7fc, 0xf8ff, 0xfa6e, 0xfa6f, 0xfada, 0xfaff, 0xfb07, 0xfb12, 0xfb18, 0xfb1c, 0xfb1e, 0xfb1e,
    0xfb37, 0xfb37, 0xfb3d, 0xfb3d, 0xfb3f, 0xfb3f, 0xfb42, 0xfb42, 0xfb45, 0xfb45, 0xfdd0, 0xfdef,
    0xfe00, 0xfe0f, 0xfe1a, 0xfe2f, 0xfe53, 0xfe53, 0xfe67, 0xfe67, 0xfe6c, 0xfe6f, 0xfe75, 0xfe75,
    0xfefd, 0xff00, 0xff9e, 0xffa0, 0xffbf, 0xffc1, 0xffc8, 0xffc9, 0xffd0, 0xffd1, 0xffd8, 0xffd9,
    0xffdd, 0xffdf, 0xffe7, 0xffe7, 0xffef, 0xfffb, 0xfffe, 0xffff, 0x1000c, 0x1000c,
    0x10027, 0x10027, 0x1003b, 0x1003b, 0x1003e, 0x1003e, 0x1004e, 0x1004f, 0x1005e, 0x1007f,
    0x100fb, 0x100ff, 0x10103, 0x10106, 0x10134, 0x10136, 0x1018f, 0x1018f, 0x1019d, 0x1019f,
    0x101a1, 0x101cf, 0x101fd, 0x1027f, 0x1029d, 0x1029f, 0x102d1, 0x102e0, 0x102fc, 0x102ff,
    0x10324, 0x1032c, 0x1034b, 0x1034f, 0x10376, 0x1037f, 0x1039e, 0x1039e, 0x103c4, 0x103c7,
    0x103d6, 0x103ff, 0x1049e, 0x1049f, 0x104aa, 0x104af, 0x104d4, 0x104d7, 0x104fc, 0x104ff,
    0x10528, 0x1052f, 0x10564, 0x1056e, 0x1057b, 0x1057b, 0x1058b, 0x1058b, 0x10593, 0x10593,
    0x10596, 0x10596, 0x105a2, 0x105a2, 0x105b2, 0x105b2, 0x105ba, 0x105ba, 0x105bd, 0x105bf,
    0x105f4, 0x105ff, 0x10737, 0x1073f, 0x10756, 0x1075f, 0x10768, 0x1077f, 0x10786, 0x10786,
    0x107b1, 0x107b1, 0x107bb, 0x107ff, 0x10806, 0x10807, 0x10809, 0x10809, 0x10836, 0x10836,
    0x10839, 0x1083b, 0x1083d, 0x1083e, 0x10856, 0x10856, 0x1089f, 0x108a6, 0x108b0, 0x108df,
    0x108f3, 0x108f3, 0x108f6, 0x108fa, 0x1091c, 0x1091e, 0x1093a, 0x1093e, 0x1095a, 0x1097f,
    0x109b8, 0x109bb, 0x109d0, 0x109d1, 0x10a01, 0x10a0f, 0x10a14, 0x10a14, 0x10a18, 0x10a18,
    0x10a36, 0x10a3f, 0x10a49, 0x10a4f, 0x10a59, 0x10a5f, 0x10aa0, 0x10abf, 0x10ae5, 0x10aea,
    0x10af7, 0x10aff, 0x10b36, 0x10b38, 0x10b56, 0x10b57, 0x10b73, 0x10b77, 0x10b92, 0x10b98,
    0x10b9d, 0x10ba8, 0x10bb0, 0x10bff, 0x10c49, 0x10c7f, 0x10cb3, 0x10cbf, 0x10cf3, 0x10cf9,
    0x10d24, 0x10d2f, 0x10d3a, 0x10d3f, 0x10d66, 0x10d6d, 0x10d86, 0x10d8d, 0x10d90, 0x10e5f,
    0x10e7f, 0x10e7f, 0x10eaa, 0x10eac, 0x10eae, 0x10eaf, 0x10eb2, 0x10ec1, 0x10ec8, 0x10ecf,
    0x10ed9, 0x10eff, 0x10f28, 0x10f2f, 0x10f46, 0x10f50, 0x10f5a, 0x10f6f, 0x10f82, 0x10f85,
    0x10f8a, 0x10faf, 0x10fcc, 0x10fdf, 0x10ff7, 0x10fff, 0x11001, 0x11001, 0x11038, 0x11046,
    0x1104e, 0x11051, 0x11070, 0x11070, 0x11073, 0x11074, 0x11076, 0x11081, 0x110b3, 0x110b6,
    0x110b9, 0x110ba, 0x110bd, 0x110bd, 0x110c2, 0x110cf, 0x110e9, 0x110ef, 0x110fa, 0x11102,
    0x11127, 0x1112b, 0x1112d, 0x11135, 0x11148, 0x1114f, 0x11173, 0x11173, 0x11177, 0x11181,
    0x111b6, 0x111be, 0x111c0, 0x111c0, 0x111c9, 0x111cc, 0x111cf, 0x111cf, 0x111e0, 0x111e0,
    0x111f5, 0x111ff, 0x11212, 0x11212, 0x1122f, 0x11231, 0x11234, 0x11237, 0x1123e, 0x1123e,
    0x11241, 0x1127f, 0x11287, 0x11287, 0x11289, 0x11289, 0x1128e, 0x1128e, 0x1129e, 0x1129e,
    0x112aa, 0x112af, 0x112df, 0x112df, 0x112e3, 0x112ef, 0x112fa, 0x11301, 0x11304, 0x11304,
    0x1130d, 0x1130e, 0x11311, 0x11312, 0x11329, 0x11329, 0x11331, 0x11331, 0x11334, 0x11334,
    0x1133a, 0x1133c, 0x1133e, 0x1133e, 0x11340, 0x11340, 0x11345, 0x11346, 0x11349, 0x1134a,
    0x1134d, 0x1134f, 0x11351, 0x1135c, 0x11364, 0x1137f, 0x1138a, 0x1138a, 0x1138c, 0x1138d,
    0x1138f, 0x1138f, 0x113b6, 0x113b6, 0x113b8, 0x113b8, 0x113bb, 0x113c9, 0x113cb, 0x113cb,
    0x113ce, 0x113d0, 0x113d2, 0x113d2, 0x113d6, 0x113d6, 0x113d9, 0x113ff, 0x11438, 0x1143f,
    0x11442, 0x11444, 0x11446, 0x11446, 0x1145c, 0x1145c, 0x1145e, 0x1145e, 0x11462, 0x1147f,
    0x114b0, 0x114b0, 0x114b3, 0x114b8, 0x114ba, 0x114ba, 0x114bd, 0x114bd, 0x114bf, 0x114c0,
    0x114c2, 0x114c3, 0x114c8, 0x114cf, 0x114da, 0x1157f, 0x115af, 0x115af, 0x115b2, 0x115b7,
    0x115bc, 0x115bd, 0x115bf, 0x115c0, 0x115dc, 0x115ff, 0x11633, 0x1163a, 0x1163d, 0x1163d,
    0x1163f, 0x11640, 0x11645, 0x1164f, 0x1165a, 0x1165f, 0x1166d, 0x1167f, 0x116ab, 0x116ab,
    0x116ad, 0x116ad, 0x116b0, 0x116b7, 0x116ba, 0x116bf, 0x116ca, 0x116cf, 0x116e4, 0x116ff,
    0x1171b, 0x1171d, 0x1171f, 0x1171f, 0x11722, 0x11725, 0x11727, 0x1172f, 0x11747, 0x117ff,
    0x1182f, 0x11837, 0x11839, 0x1183a, 0x1183c, 0x1189f, 0x118f3, 0x118fe, 0x11907, 0x11908,
    0x1190a, 0x1190b, 0x11914, 0x11914, 0x11917, 0x11917, 0x11930, 0x11930, 0x11936, 0x11936,
    0x11939, 0x1193e, 0x11943, 0x11943, 0x11947, 0x1194f, 0x1195a, 0x1199f, 0x119a8, 0x119a9,
    0x119d4, 0x119db, 0x119e0, 0x119e0, 0x119e5, 0x119ff, 0x11a01, 0x11a0a, 0x11a33, 0x11a38,
    0x11a3b, 0x11a3e, 0x11a47, 0x11a4f, 0x11a51, 0x11a56, 0x11a59, 0x11a5b, 0x11a8a, 0x11a96,
    0x11a98, 0x11a99, 0x11aa3, 0x11aaf, 0x11af9, 0x11aff, 0x11b0a, 0x11b60, 0x11b62, 0x11b64,
    0x11b66, 0x11b66, 0x11b68, 0x11bbf, 0x11be2, 0x11bef, 0x11bfa, 0x11bff, 0x11c09, 0x11c09,
    0x11c30, 0x11c3d, 0x11c3f, 0x11c3f, 0x11c46, 0x11c4f, 0x11c6d, 0x11c6f, 0x11c90, 0x11ca8,
    0x11caa, 0x11cb0, 0x11cb2, 0x11cb3, 0x11cb5, 0x11cff, 0x11d07, 0x11d07, 0x11d0a, 0x11d0a,
    0x11d31, 0x11d45, 0x11d47, 0x11d4f, 0x11d5a, 0x11d5f, 0x11d66, 0x11d66, 0x11d69, 0x11d69,
    0x11d8f, 0x11d92, 0x11d95, 0x11d95, 0x11d97, 0x11d97, 0x11d99, 0x11d9f, 0x11daa, 0x11daf,
    0x11ddc, 0x11ddf, 0x11dea, 0x11edf, 0x11ef3, 0x11ef4, 0x11ef9, 0x11f01, 0x11f11, 0x11f11,
    0x11f36, 0x11f3d, 0x11f40, 0x11f42, 0x11f5a, 0x11faf, 0x11fb1, 0x11fbf, 0x11ff2, 0x11ffe,
    0x1239a, 0x123ff, 0x1246f, 0x1246f, 0x12475, 0x1247f, 0x12544, 0x12f8f, 0x12ff3, 0x12fff,
    0x13430, 0x13440, 0x13447, 0x1345f, 0x143fb, 0x143ff, 0x14647, 0x160ff, 0x1611e, 0x16129,
    0x1612d, 0x1612f, 0x1613a, 0x167ff, 0x16a39, 0x16a3f, 0x16a5f, 0x16a5f, 0x16a6a, 0x16a6d,
    0x16abf, 0x16abf, 0x16aca, 0x16acf, 0x16aee, 0x16af4, 0x16af6, 0x16aff, 0x16b30, 0x16b36,
    0x16b46, 0x16b4f, 0x16b5a, 0x16b5a, 0x16b62, 0x16b62, 0x16b78, 0x16b7c, 0x16b90, 0x16d3f,
    0x16d7a, 0x16e3f, 0x16e9b, 0x16e9f, 0x16eb9, 0x16eba, 0x16ed4, 0x16eff, 0x16f4b, 0x16f4f,
    0x16f88, 0x16f92, 0x16fa0, 0x16fdf, 0x16fe4, 0x16ff1, 0x16ff7, 0x16fff, 0x18cd6, 0x18cfe,
    0x18d1f, 0x18d7f, 0x18df3, 0x1afef, 0x1aff4, 0x1aff4, 0x1affc, 0x1affc, 0x1afff, 0x1afff,
    0x1b123, 0x1b131, 0x1b133, 0x1b14f, 0x1b153, 0x1b154, 0x1b156, 0x1b163, 0x1b168, 0x1b16f,
    0x1b2fc, 0x1bbff, 0x1bc6b, 0x1bc6f, 0x1bc7d, 0x1bc7f, 0x1bc89, 0x1bc8f, 0x1bc9a, 0x1bc9b,
    0x1bc9d, 0x1bc9e, 0x1bca0, 0x1cbff, 0x1ccfd, 0x1ccff, 0x1ceb4, 0x1ceb9, 0x1ced1, 0x1cedf,
    0x1cef1, 0x1cf4f, 0x1cfc4, 0x1cfff, 0x1d0f6, 0x1d0ff, 0x1d127, 0x1d128, 0x1d165, 0x1d169,
    0x1d16d, 0x1d182, 0x1d185, 0x1d18b, 0x1d1aa, 0x1d1ad, 0x1d1eb, 0x1d1ff, 0x1d242, 0x1d244,
    0x1d246, 0x1d2bf, 0x1d2d4, 0x1d2df, 0x1d2f4, 0x1d2ff, 0x1d357, 0x1d35f, 0x1d379, 0x1d3ff,
    0x1d455, 0x1d455, 0x1d49d, 0x1d49d, 0x1d4a0, 0x1d4a1, 0x1d4a3, 0x1d4a4, 0x1d4a7, 0x1d4a8,
    0x1d4ad, 0x1d4ad, 0x1d4ba, 0x1d4ba, 0x1d4bc, 0x1d4bc, 0x1d4c4, 0x1d4c4, 0x1d506, 0x1d506,
    0x1d50b, 0x1d50c, 0x1d515, 0x1d515, 0x1d51d, 0x1d51d, 0x1d53a, 0x1d53a, 0x1d53f, 0x1d53f,
    0x1d545, 0x1d545, 0x1d547, 0x1d549, 0x1d551, 0x1d551, 0x1d6a6, 0x1d6a7, 0x1d7cc, 0x1d7cd,
    0x1da00, 0x1da36, 0x1da3b, 0x1da6c, 0x1da75, 0x1da75, 0x1da84, 0x1da84, 0x1da8c, 0x1deff,
    0x1df1f, 0x1df24, 0x1df2b, 0x1e02f, 0x1e06e, 0x1e0ff, 0x1e12d, 0x1e136, 0x1e13e, 0x1e13f,
    0x1e14a, 0x1e14d, 0x1e150, 0x1e28f, 0x1e2ae, 0x1e2bf, 0x1e2ec, 0x1e2ef, 0x1e2fa, 0x1e2fe,
    0x1e300, 0x1e4cf, 0x1e4ec, 0x1e4ef, 0x1e4fa, 0x1e5cf, 0x1e5ee, 0x1e5ef, 0x1e5fb, 0x1e5fe,
    0x1e600, 0x1e6bf, 0x1e6df, 0x1e6df, 0x1e6e3, 0x1e6e3, 0x1e6e6, 0x1e6e6, 0x1e6ee, 0x1e6ef,
    0x1e6f5, 0x1e6fd, 0x1e700, 0x1e7df, 0x1e7e7, 0x1e7e7, 0x1e7ec, 0x1e7ec, 0x1e7ef, 0x1e7ef,
    0x1e7ff, 0x1e7ff, 0x1e8c5, 0x1e8c6, 0x1e8d0, 0x1e8ff, 0x1e944, 0x1e94a, 0x1e94c, 0x1e94f,
    0x1e95a, 0x1e95d, 0x1e960, 0x1ec70, 0x1ecb5, 0x1ed00, 0x1ed3e, 0x1edff, 0x1ee04, 0x1ee04,
    0x1ee20, 0x1ee20, 0x1ee23, 0x1ee23, 0x1ee25, 0x1ee26, 0x1ee28, 0x1ee28, 0x1ee33, 0x1ee33,
    0x1ee38, 0x1ee38, 0x1ee3a, 0x1ee3a, 0x1ee3c, 0x1ee41, 0x1ee43, 0x1ee46, 0x1ee48, 0x1ee48,
    0x1ee4a, 0x1ee4a, 0x1ee4c, 0x1ee4c, 0x1ee50, 0x1ee50, 0x1ee53, 0x1ee53, 0x1ee55, 0x1ee56,
    0x1ee58, 0x1ee58, 0x1ee5a, 0x1ee5a, 0x1ee5c, 0x1ee5c, 0x1ee5e, 0x1ee5e, 0x1ee60, 0x1ee60,
    0x1ee63, 0x1ee63, 0x1ee65, 0x1ee66, 0x1ee6b, 0x1ee6b, 0x1ee73, 0x1ee73, 0x1ee78, 0x1ee78,
    0x1ee7d, 0x1ee7d, 0x1ee7f, 0x1ee7f, 0x1ee8a, 0x1ee8a, 0x1ee9c, 0x1eea0, 0x1eea4, 0x1eea4,
    0x1eeaa, 0x1eeaa, 0x1eebc, 0x1eeef, 0x1eef2, 0x1efff, 0x1f02c, 0x1f02f, 0x1f094, 0x1f09f,
    0x1f0af, 0x1f0b0, 0x1f0c0, 0x1f0c0, 0x1f0d0, 0x1f0d0, 0x1f0f6, 0x1f0ff, 0x1f1ae, 0x1f1e5,
    0x1f203, 0x1f20f, 0x1f23c, 0x1f23f, 0x1f249, 0x1f24f, 0x1f252, 0x1f25f, 0x1f266, 0x1f2ff,
    0x1f6d9, 0x1f6db, 0x1f6ed, 0x1f6ef, 0x1f6fd, 0x1f6ff, 0x1f7da, 0x1f7df, 0x1f7ec, 0x1f7ef,
    0x1f7f1, 0x1f7ff, 0x1f80c, 0x1f80f, 0x1f848, 0x1f84f, 0x1f85a, 0x1f85f, 0x1f888, 0x1f88f,
    0x1f8ae, 0x1f8af, 0x1f8bc, 0x1f8bf, 0x1f8c2, 0x1f8cf, 0x1f8d9, 0x1f8ff, 0x1fa58, 0x1fa5f,
    0x1fa6e, 0x1fa6f, 0x1fa7d, 0x1fa7f, 0x1fa8b, 0x1fa8d, 0x1fac7, 0x1fac7, 0x1fac9, 0x1facc,
    0x1fadd, 0x1fade, 0x1faeb, 0x1faee, 0x1faf9, 0x1faff, 0x1fb93, 0x1fb93, 0x1fbfb, 0x1ffff,
    0x2a6e0, 0x2a6ff, 0x2b81e, 0x2b81f, 0x2ceae, 0x2ceaf, 0x2ebe1, 0x2ebef, 0x2ee5e, 0x2f7ff,
    0x2fa1e, 0x2ffff, 0x3134b, 0x3134f, 0x3347a, 0x10ffff,
];
