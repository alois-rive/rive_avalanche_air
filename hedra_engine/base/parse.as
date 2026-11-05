// Strict number parsing: a fixed grammar, fixed error messages and correct
// rounding.
//
// Never use AS `parseFloat` / `parseInt` / `I32.parseInt` for user input:
//   * they are lenient ("  3.25abc" -> 3.25, "" -> NaN, "1.5" -> 1 as int)
//     where these return an error;
//   * parseFloat is not correctly rounded: it is off by many ulps on some
//     long inputs ("6082936744260077.317627e26") and by 1 ulp on short f32
//     ones ("7.038531e-26" through <f32>parseFloat), while these always
//     round the exact decimal value to nearest, ties to even.
//
//   parseF64(s): Result<f64>
//   parseF32(s): Result<f32>   (rounded once, straight to f32)
//   parseU64 / parseUsize / parseU32 / parseU16 / parseU8
//   parseI64 / parseI32
//   r.err is the user-visible message ("invalid float literal", ...)
//
// Floats: optional sign, then "inf" / "infinity" / "nan" (ASCII
// case-insensitive) or digits with an optional '.', at least one digit, and
// an optional exponent `e`/`E` [sign] digits. No whitespace, no '_', no hex.
// The value is computed exactly with a small bignum (value = D * 10^E as a
// ratio of integers), so every input is correctly rounded.

import { Result } from "./util";

export const FLOAT_ERR_EMPTY = "cannot parse float from empty string";
export const FLOAT_ERR_INVALID = "invalid float literal";
export const INT_ERR_EMPTY = "cannot parse integer from empty string";
export const INT_ERR_INVALID_DIGIT = "invalid digit found in string";
export const INT_ERR_POS_OVERFLOW = "number too large to fit in target type";
export const INT_ERR_NEG_OVERFLOW = "number too small to fit in target type";

// ---------------------------------------------------------------------------
// Minimal unsigned bignum (little-endian base 2^32 limbs).

class Big {
    limbs: Uint32Array;
    len: i32 = 0;

    constructor(capacity: i32) {
        this.limbs = new Uint32Array(capacity > 2 ? capacity : 2);
    }

    ensure(n: i32): void {
        if (this.limbs.length < n) {
            const next = new Uint32Array(n * 2);
            next.set(this.limbs.subarray(0, this.len));
            this.limbs = next;
        }
    }

    clone(): Big {
        const b = new Big(this.len + 2);
        b.limbs.set(this.limbs.subarray(0, this.len));
        b.len = this.len;
        return b;
    }

    isZero(): bool {
        return this.len == 0;
    }

    trim(): void {
        while (this.len > 0 && this.limbs[this.len - 1] == 0) this.len--;
    }

    // this = this * k + add
    mulAdd(k: u32, add: u32): void {
        let carry: u64 = <u64>add;
        for (let i = 0; i < this.len; i++) {
            const t = <u64>this.limbs[i] * <u64>k + carry;
            this.limbs[i] = <u32>(t & 0xFFFFFFFF);
            carry = t >> 32;
        }
        if (carry != 0) {
            this.ensure(this.len + 1);
            this.limbs[this.len] = <u32>carry;
            this.len++;
        }
    }

    shl(bits: i32): void {
        if (this.len == 0 || bits == 0) return;
        const words = bits >> 5;
        const b = bits & 31;
        this.ensure(this.len + words + 1);
        this.limbs[this.len + words] = 0;
        for (let i = this.len - 1; i >= 0; i--) {
            const v = this.limbs[i];
            if (b != 0) this.limbs[i + words + 1] |= v >>> (32 - b);
            this.limbs[i + words] = b != 0 ? v << b : v;
        }
        for (let i = 0; i < words; i++) this.limbs[i] = 0;
        this.len = this.len + words + 1;
        this.trim();
    }

    shr1(): void {
        for (let i = 0; i < this.len; i++) {
            let v = this.limbs[i] >>> 1;
            if (i + 1 < this.len) v |= this.limbs[i + 1] << 31;
            this.limbs[i] = v;
        }
        this.trim();
    }

    bitLength(): i32 {
        if (this.len == 0) return 0;
        return (this.len - 1) * 32 + (32 - <i32>clz<u32>(this.limbs[this.len - 1]));
    }

    // -1, 0, 1
    cmp(o: Big): i32 {
        if (this.len != o.len) return this.len < o.len ? -1 : 1;
        for (let i = this.len - 1; i >= 0; i--) {
            const a = this.limbs[i];
            const b = o.limbs[i];
            if (a != b) return a < b ? -1 : 1;
        }
        return 0;
    }

    // this -= o, requires this >= o
    sub(o: Big): void {
        let borrow: i64 = 0;
        for (let i = 0; i < this.len; i++) {
            let t = <i64>this.limbs[i] - borrow - (i < o.len ? <i64>o.limbs[i] : 0);
            if (t < 0) {
                t += 0x100000000;
                borrow = 1;
            } else {
                borrow = 0;
            }
            this.limbs[i] = <u32>t;
        }
        this.trim();
    }
}

function bigPow10(e: i32): Big {
    const b = new Big(e / 9 + 2);
    b.limbs[0] = 1;
    b.len = 1;
    let k = e;
    while (k >= 9) {
        b.mulAdd(1000000000, 0);
        k -= 9;
    }
    let p: u32 = 1;
    for (let i = 0; i < k; i++) p *= 10;
    if (p != 1) b.mulAdd(p, 0);
    return b;
}

// ---------------------------------------------------------------------------
// Float grammar

class FloatParts {
    ok: bool = false;
    empty: bool = false;
    neg: bool = false;
    special: i32 = 0; // 0 number, 1 inf, 2 nan
    digits: string = ""; // significant digits, no leading or trailing zeros ("" = zero)
    exp: i64 = 0; // value = digits * 10^exp
}

function lowerAscii(c: i32): i32 {
    return c >= 65 && c <= 90 ? c + 32 : c;
}

function eqIgnoreAsciiCase(s: string, from: i32, word: string): bool {
    if (s.length - from != word.length) return false;
    for (let i = 0; i < word.length; i++) {
        if (lowerAscii(s.charCodeAt(from + i)) != word.charCodeAt(i)) return false;
    }
    return true;
}

function splitFloat(s: string): FloatParts {
    const p = new FloatParts();
    const n = s.length;
    if (n == 0) {
        p.empty = true;
        return p;
    }
    let i = 0;
    const c0 = s.charCodeAt(0);
    if (c0 == 43 || c0 == 45) {
        p.neg = c0 == 45;
        i = 1;
    }
    if (i == n) return p;
    if (eqIgnoreAsciiCase(s, i, "inf") || eqIgnoreAsciiCase(s, i, "infinity")) {
        p.special = 1;
        p.ok = true;
        return p;
    }
    if (eqIgnoreAsciiCase(s, i, "nan")) {
        p.special = 2;
        p.ok = true;
        return p;
    }
    const parts: Array<string> = [];
    let nDigits = 0;
    let fracDigits = 0;
    let start = i;
    while (i < n && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) i++;
    nDigits += i - start;
    if (i > start) parts.push(s.substring(start, i));
    if (i < n && s.charCodeAt(i) == 46) {
        i++;
        start = i;
        while (i < n && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) i++;
        fracDigits = i - start;
        nDigits += fracDigits;
        if (i > start) parts.push(s.substring(start, i));
    }
    if (nDigits == 0) return p;
    let exp: i64 = 0;
    if (i < n && (s.charCodeAt(i) == 101 || s.charCodeAt(i) == 69)) {
        i++;
        let eneg = false;
        if (i < n && (s.charCodeAt(i) == 43 || s.charCodeAt(i) == 45)) {
            eneg = s.charCodeAt(i) == 45;
            i++;
        }
        const es = i;
        while (i < n && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) {
            // saturate: anything beyond 10^12 is 0 or infinity anyway
            if (exp < 1000000000000) exp = exp * 10 + <i64>(s.charCodeAt(i) - 48);
            i++;
        }
        if (i == es) return p;
        if (eneg) exp = -exp;
    }
    if (i != n) return p;
    const all = parts.join("");
    let a = 0;
    let b = all.length;
    while (a < b && all.charCodeAt(a) == 48) a++;
    while (b > a && all.charCodeAt(b - 1) == 48) b--;
    p.digits = all.substring(a, b);
    // all = digits followed by (all.length - b) zeros; value = all * 10^(exp - fracDigits)
    p.exp = exp - <i64>fracDigits + <i64>(all.length - b);
    p.ok = true;
    return p;
}

// Correctly rounded digits * 10^exp for a binary format with `prec` mantissa
// bits (hidden bit included) and smallest quantum 2^minq. Returns the IEEE
// bits of the positive result (exponent field 0x7FF / 0xFF = infinity).
function roundDecimal(digits: string, exp: i64, prec: i32, minq: i32, infBits: u64): u64 {
    if (digits.length == 0) return 0;
    const nd = <i64>digits.length;
    // value < 10^(nd + exp); value >= 10^(nd - 1 + exp)
    const maxDec: i64 = prec == 53 ? 309 : 39;
    const minDec: i64 = prec == 53 ? -324 : -46;
    if (nd + exp <= minDec) return 0;
    if (nd - 1 + exp >= maxDec) return infBits;
    const e = <i32>exp;

    // N / Dd = digits * 10^e
    const num = new Big(<i32>(nd / 9) + 4);
    let k = 0;
    while (k < digits.length) {
        const end = min(k + 9, digits.length);
        let chunk: u32 = 0;
        let scale: u32 = 1;
        for (let j = k; j < end; j++) {
            chunk = chunk * 10 + <u32>(digits.charCodeAt(j) - 48);
            scale *= 10;
        }
        if (num.len == 0) {
            num.limbs[0] = chunk;
            num.len = chunk != 0 ? 1 : 0;
        } else {
            num.mulAdd(scale, chunk);
        }
        k = end;
    }
    let den: Big;
    if (e >= 0) {
        const p10 = bigPow10(e);
        // num *= 10^e (schoolbook)
        const prod = new Big(num.len + p10.len + 1);
        for (let i = 0; i < num.len; i++) {
            let carry: u64 = 0;
            const a = <u64>num.limbs[i];
            for (let j = 0; j < p10.len; j++) {
                const t = a * <u64>p10.limbs[j] + <u64>prod.limbs[i + j] + carry;
                prod.limbs[i + j] = <u32>(t & 0xFFFFFFFF);
                carry = t >> 32;
            }
            prod.limbs[i + p10.len] = <u32>carry;
        }
        prod.len = num.len + p10.len;
        prod.trim();
        den = new Big(2);
        den.limbs[0] = 1;
        den.len = 1;
        return roundRatio(prod, den, prec, minq, infBits);
    }
    den = bigPow10(-e);
    return roundRatio(num, den, prec, minq, infBits);
}

function roundRatio(n: Big, d: Big, prec: i32, minq: i32, infBits: u64): u64 {
    // eTop = floor(log2(n / d))
    let eTop = n.bitLength() - d.bitLength();
    const na = n.clone();
    const db = d.clone();
    if (eTop >= 0) db.shl(eTop);
    else na.shl(-eTop);
    if (na.cmp(db) < 0) eTop--;
    const emaxTop = prec == 53 ? 1023 : 127;
    if (eTop > emaxTop) return infBits;
    let qe = eTop - (prec - 1);
    if (qe < minq) qe = minq;
    // q = floor(n / (d * 2^(qe - 1))): the result in half-quantum units
    const s = 1 - qe;
    const a = n.clone();
    const b = d.clone();
    if (s >= 0) a.shl(s);
    else b.shl(-s);
    // q < 2^(prec + 1): long division, one bit at a time
    let q: u64 = 0;
    const qbits = prec + 2;
    b.shl(qbits - 1);
    for (let i = qbits - 1; i >= 0; i--) {
        q <<= 1;
        if (a.cmp(b) >= 0) {
            a.sub(b);
            q |= 1;
        }
        b.shr1();
    }
    const sticky = !a.isZero();
    let m = q >> 1;
    const half = (q & 1) != 0;
    if (half && (sticky || (m & 1) != 0)) m++;
    const bits = (<u64>(qe - minq) << <u64>(prec - 1)) + m;
    return bits >= infBits ? infBits : bits;
}

// Parses an f64.
export function parseF64(s: string): Result<f64> {
    const p = splitFloat(s);
    if (p.empty) return Result.fail<f64>(FLOAT_ERR_EMPTY);
    if (!p.ok) return Result.fail<f64>(FLOAT_ERR_INVALID);
    let v: f64;
    if (p.special == 1) v = Infinity;
    else if (p.special == 2) v = NaN;
    else v = reinterpret<f64>(roundDecimal(p.digits, p.exp, 53, -1074, 0x7FF0000000000000));
    return Result.okv<f64>(p.neg ? -v : v);
}

// Parses an f32: rounded once from the exact decimal value (not
// through f64, which can double-round).
export function parseF32(s: string): Result<f32> {
    const p = splitFloat(s);
    if (p.empty) return Result.fail<f32>(FLOAT_ERR_EMPTY);
    if (!p.ok) return Result.fail<f32>(FLOAT_ERR_INVALID);
    let v: f32;
    if (p.special == 1) v = Infinity;
    else if (p.special == 2) v = NaN;
    else v = reinterpret<f32>(<u32>roundDecimal(p.digits, p.exp, 24, -149, 0x7F800000));
    return Result.okv<f32>(p.neg ? -v : v);
}

// ---------------------------------------------------------------------------
// Integers (core::num from_str_radix, radix 10)

class IntParts {
    err: string = "";
    neg: bool = false;
    mag: u64 = 0; // magnitude, valid when err == ""
}

// Parses sign + decimal digits left to right: a bad digit or an overflow
// past `limit` (the largest magnitude allowed for that sign) is reported at
// the first character where it happens.
function splitInt(s: string, signed: bool, posLimit: u64, negLimit: u64): IntParts {
    const r = new IntParts();
    const n = s.length;
    if (n == 0) {
        r.err = INT_ERR_EMPTY;
        return r;
    }
    let i = 0;
    const c0 = s.charCodeAt(0);
    if (c0 == 43 || c0 == 45) {
        if (n == 1) {
            r.err = INT_ERR_INVALID_DIGIT;
            return r;
        }
        if (c0 == 43) i = 1;
        else if (signed) {
            r.neg = true;
            i = 1;
        }
    }
    const limit = r.neg ? negLimit : posLimit;
    let v: u64 = 0;
    for (; i < n; i++) {
        const c = s.charCodeAt(i);
        if (c < 48 || c > 57) {
            r.err = INT_ERR_INVALID_DIGIT;
            return r;
        }
        const d = <u64>(c - 48);
        if (v > (limit - d) / 10) {
            r.err = r.neg ? INT_ERR_NEG_OVERFLOW : INT_ERR_POS_OVERFLOW;
            return r;
        }
        v = v * 10 + d;
    }
    r.mag = v;
    return r;
}

export function parseU64(s: string): Result<u64> {
    const p = splitInt(s, false, u64.MAX_VALUE, 0);
    if (p.err.length > 0) return Result.fail<u64>(p.err);
    return Result.okv<u64>(p.mag);
}

// A usize is 64 bits wide (the same as parseU64).

export function parseUsize(s: string): Result<u64> {
    return parseU64(s);
}

export function parseU32(s: string): Result<u32> {
    const p = splitInt(s, false, <u64>u32.MAX_VALUE, 0);
    if (p.err.length > 0) return Result.fail<u32>(p.err);
    return Result.okv<u32>(<u32>p.mag);
}

export function parseU16(s: string): Result<u16> {
    const p = splitInt(s, false, <u64>u16.MAX_VALUE, 0);
    if (p.err.length > 0) return Result.fail<u16>(p.err);
    return Result.okv<u16>(<u16>p.mag);
}

export function parseU8(s: string): Result<u8> {
    const p = splitInt(s, false, <u64>u8.MAX_VALUE, 0);
    if (p.err.length > 0) return Result.fail<u8>(p.err);
    return Result.okv<u8>(<u8>p.mag);
}

export function parseI64(s: string): Result<i64> {
    const p = splitInt(s, true, <u64>i64.MAX_VALUE, <u64>i64.MAX_VALUE + 1);
    if (p.err.length > 0) return Result.fail<i64>(p.err);
    return Result.okv<i64>(p.neg ? <i64>(<u64>0 - p.mag) : <i64>p.mag);
}

export function parseI32(s: string): Result<i32> {
    const p = splitInt(s, true, <u64>i32.MAX_VALUE, <u64>i32.MAX_VALUE + 1);
    if (p.err.length > 0) return Result.fail<i32>(p.err);
    return Result.okv<i32>(p.neg ? <i32>(<i64>0 - <i64>p.mag) : <i32>p.mag);
}
