// Derived from meshopt-rs 0.1.2 (MIT); see THIRD_PARTY_NOTICES.md.
//
// Vertex buffer decode filters, applied in place to the output of
// decodeVertexBuffer (the `filter` of `EXT_meshopt_compression`).
//
// Every filter takes the decoded bytes and reads the little-endian lanes
// itself (4 x u8, 4 x u16 or u32 per element), over the whole elements the
// data holds.

import { f32ToI32, minF32, maxF32 } from "../../../../base/util";

function readI16(data: Uint8Array, at: i32): i32 {
    return <i32><i16>(<u16>data[at] | (<u16>data[at + 1] << 8));
}

function readU16(data: Uint8Array, at: i32): u16 {
    return <u16>data[at] | (<u16>data[at + 1] << 8);
}

function writeU16(data: Uint8Array, at: i32, v: u16): void {
    data[at] = <u8>v;
    data[at + 1] = <u8>(v >> 8);
}

function decodeFilterOctScalar(data: Uint8Array, stride: i32): void {
    const max = <f32>((1 << (stride / 4 * 8 - 1)) - 1);

    const count = data.length / stride;
    for (let e = 0; e < count; e++) {
        const at = e * stride;

        // convert x and y to floats and reconstruct z; this assumes zf encodes 1.0 at the same bit count
        let x: f32 = 0;
        let y: f32 = 0;
        let z: f32 = 0;
        if (stride == 4) {
            x = <f32><i8>data[at];
            y = <f32><i8>data[at + 1];
            z = <f32><i8>data[at + 2];
        } else {
            x = <f32>readI16(data, at);
            y = <f32>readI16(data, at + 2);
            z = <f32>readI16(data, at + 4);
        }

        z = z - Mathf.abs(x) - Mathf.abs(y);

        // fixup octahedral coordinates for z<0
        const t = minF32(z, 0.0);

        x += x >= 0.0 ? t : -t;
        y += y >= 0.0 ? t : -t;

        // compute normal length & scale
        const l = Mathf.sqrt(x * x + y * y + z * z);
        const s = max / l;

        // rounded signed float->int
        const xf = f32ToI32(x * s + (x >= 0.0 ? <f32>0.5 : <f32>-0.5));
        const yf = f32ToI32(y * s + (y >= 0.0 ? <f32>0.5 : <f32>-0.5));
        const zf = f32ToI32(z * s + (z >= 0.0 ? <f32>0.5 : <f32>-0.5));

        if (stride == 4) {
            data[at] = <u8>xf;
            data[at + 1] = <u8>yf;
            data[at + 2] = <u8>zf;
        } else {
            writeU16(data, at, <u16>xf);
            writeU16(data, at + 2, <u16>yf);
            writeU16(data, at + 4, <u16>zf);
        }
    }
}

function decodeFilterQuatScalar(data: Uint8Array): void {
    const scale: f32 = <f32>1.0 / Mathf.sqrt(<f32>2.0);

    const count = data.length / 8;
    for (let e = 0; e < count; e++) {
        const at = e * 8;
        const q0 = readU16(data, at);
        const q1 = readU16(data, at + 2);
        const q2 = readU16(data, at + 4);
        const q3 = readU16(data, at + 6);

        // recover scale from the high byte of the component
        const sf = q3 | 3;
        const ss: f32 = scale / <f32>sf;

        // convert x/y/z to [-1..1] (scaled...)
        const x: f32 = <f32>q0 * ss;
        const y: f32 = <f32>q1 * ss;
        const z: f32 = <f32>q2 * ss;

        // reconstruct w as a square root; we clamp to 0.0 to avoid NaN due to precision errors
        const ww: f32 = <f32>1.0 - x * x - y * y - z * z;
        const w = Mathf.sqrt(maxF32(ww, 0.0));

        // rounded signed float->int
        const xf = f32ToI32(x * <f32>32767.0 + (x >= 0.0 ? <f32>0.5 : <f32>-0.5));
        const yf = f32ToI32(y * <f32>32767.0 + (y >= 0.0 ? <f32>0.5 : <f32>-0.5));
        const zf = f32ToI32(z * <f32>32767.0 + (z >= 0.0 ? <f32>0.5 : <f32>-0.5));
        const wf = f32ToI32(w * <f32>32767.0 + <f32>0.5);

        const qc = <i32>(q3 & 3);

        // output order is dictated by input index
        writeU16(data, at + ((qc + 1) & 3) * 2, <u16><i16>xf);
        writeU16(data, at + ((qc + 2) & 3) * 2, <u16><i16>yf);
        writeU16(data, at + ((qc + 3) & 3) * 2, <u16><i16>zf);
        writeU16(data, at + ((qc + 0) & 3) * 2, <u16><i16>wf);
    }
}

function decodeFilterExpScalar(data: Uint8Array): void {
    const count = data.length / 4;
    for (let e = 0; e < count; e++) {
        const at = e * 4;
        const v: u32 = <u32>data[at] | (<u32>data[at + 1] << 8) | (<u32>data[at + 2] << 16) | (<u32>data[at + 3] << 24);

        // decode mantissa and exponent
        const m = (<i32>(v << 8)) >> 8;
        const ex = (<i32>v) >> 24;

        // optimized version of ldexp(float(m), e)
        const ui: u32 = (<u32>(ex + 127)) << 23;
        const f: f32 = reinterpret<f32>(ui) * <f32>m;

        const out = reinterpret<u32>(f);
        data[at] = <u8>out;
        data[at + 1] = <u8>(out >> 8);
        data[at + 2] = <u8>(out >> 16);
        data[at + 3] = <u8>(out >> 24);
    }
}

// Decodes octahedral encoding of a unit vector with K-bit (K <= 16) signed X/Y
// as an input; Z must store 1.0. Each component is stored as an 8-bit
// normalized integer (4-byte elements). W is preserved as is.
export function decodeFilterOct8(data: Uint8Array): void {
    decodeFilterOctScalar(data, 4);
}

// Same with 16-bit components (8-byte elements, little-endian i16 lanes).
export function decodeFilterOct16(data: Uint8Array): void {
    decodeFilterOctScalar(data, 8);
}

// Decodes 3-component quaternion encoding with K-bit (4 <= K <= 16) component
// encoding and a 2-bit component index indicating which component to
// reconstruct (8-byte elements, little-endian u16 lanes).
export function decodeFilterQuat(data: Uint8Array): void {
    decodeFilterQuatScalar(data);
}

// Decodes exponential encoding of floating-point data with 8-bit exponent and
// 24-bit integer mantissa as 2^E*M. Each 32-bit (little-endian) component is
// decoded in isolation.
export function decodeFilterExp(data: Uint8Array): void {
    decodeFilterExpScalar(data);
}
