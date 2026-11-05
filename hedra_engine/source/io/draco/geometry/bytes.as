// Little-endian scalar reads and writes on byte views, and the checked
// 64-bit size arithmetic the Draco data model uses.
//
// Every read and write here assumes the caller checked the bounds first.

export function readU8(d: Uint8Array, o: i32): u8 {
    return unchecked(d[o]);
}

export function readI8(d: Uint8Array, o: i32): i8 {
    return <i8>unchecked(d[o]);
}

export function readU16Le(d: Uint8Array, o: i32): u16 {
    return <u16>(<u32>unchecked(d[o]) | (<u32>unchecked(d[o + 1]) << 8));
}

export function readI16Le(d: Uint8Array, o: i32): i16 {
    return <i16>readU16Le(d, o);
}

export function readU32Le(d: Uint8Array, o: i32): u32 {
    return (
        <u32>unchecked(d[o]) |
        (<u32>unchecked(d[o + 1]) << 8) |
        (<u32>unchecked(d[o + 2]) << 16) |
        (<u32>unchecked(d[o + 3]) << 24)
    );
}

export function readI32Le(d: Uint8Array, o: i32): i32 {
    return <i32>readU32Le(d, o);
}

export function readU64Le(d: Uint8Array, o: i32): u64 {
    return <u64>readU32Le(d, o) | (<u64>readU32Le(d, o + 4) << 32);
}

export function readI64Le(d: Uint8Array, o: i32): i64 {
    return <i64>readU64Le(d, o);
}

export function readF32Le(d: Uint8Array, o: i32): f32 {
    return reinterpret<f32>(readU32Le(d, o));
}

export function readF64Le(d: Uint8Array, o: i32): f64 {
    return reinterpret<f64>(readU64Le(d, o));
}

export function writeU32Le(d: Uint8Array, o: i32, v: u32): void {
    unchecked((d[o] = <u8>v));
    unchecked((d[o + 1] = <u8>(v >> 8)));
    unchecked((d[o + 2] = <u8>(v >> 16)));
    unchecked((d[o + 3] = <u8>(v >> 24)));
}

export function writeI32Le(d: Uint8Array, o: i32, v: i32): void {
    writeU32Le(d, o, <u32>v);
}

export function writeF32Le(d: Uint8Array, o: i32, v: f32): void {
    writeU32Le(d, o, reinterpret<u32>(v));
}

export function writeU64Le(d: Uint8Array, o: i32, v: u64): void {
    writeU32Le(d, o, <u32>v);
    writeU32Le(d, o + 4, <u32>(v >> 32));
}

export function writeF64Le(d: Uint8Array, o: i32, v: f64): void {
    writeU64Le(d, o, reinterpret<u64>(v));
}

// The little-endian bytes of a scalar, as a fresh array.
export function u32LeBytes(v: u32): Uint8Array {
    const b = new Uint8Array(4);
    writeU32Le(b, 0, v);
    return b;
}

export function i32LeBytes(v: i32): Uint8Array {
    return u32LeBytes(<u32>v);
}

export function f32LeBytes(v: f32): Uint8Array {
    return u32LeBytes(reinterpret<u32>(v));
}

export function u64LeBytes(v: u64): Uint8Array {
    const b = new Uint8Array(8);
    writeU64Le(b, 0, v);
    return b;
}

export function i64LeBytes(v: i64): Uint8Array {
    return u64LeBytes(<u64>v);
}

export function f64LeBytes(v: f64): Uint8Array {
    return u64LeBytes(reinterpret<u64>(v));
}

// Checked 64-bit `a * b` / `a + b`: the
// result, or U64_NONE when it overflows. No real count reaches u64::MAX, so
// the sentinel cannot collide with a value.
export const U64_NONE: u64 = u64.MAX_VALUE;

export function checkedMulU64(a: u64, b: u64): u64 {
    if (a == U64_NONE || b == U64_NONE) return U64_NONE;
    if (a == 0 || b == 0) return 0;
    if (a > (u64.MAX_VALUE - 1) / b) return U64_NONE;
    return a * b;
}

export function checkedAddU64(a: u64, b: u64): u64 {
    if (a == U64_NONE || b == U64_NONE) return U64_NONE;
    const s = a + b;
    if (s < a || s == U64_NONE) return U64_NONE;
    return s;
}
