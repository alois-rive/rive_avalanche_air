// SHA-256 (FIPS 180-4). Milestone 39 wrote it for the digests a build
// reports (the sha256 of the lines "<sha256 of the file>  <path>\n", as
// compiler/tools/gen_engine_bundle.sh computes ENGINE_SOURCES_SHA256 and `sha256sum` prints
// them); milestone 41 moved it into the library, whose run time compares a
// built scene's SRCS digest of its .rscn with the declared text's
// (engine/src/scene/runtime/sources.as), and whose build digests every input. A
// scene's text is a few kilobytes (the courtyard's 11,751 bytes); nothing
// here needs to be faster than that asks.

const K: StaticArray<u32> = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

// The digest of `data`, 32 bytes.
export function sha256(data: Uint8Array): Uint8Array {
    const h = new StaticArray<u32>(8);
    h[0] = 0x6a09e667;
    h[1] = 0xbb67ae85;
    h[2] = 0x3c6ef372;
    h[3] = 0xa54ff53a;
    h[4] = 0x510e527f;
    h[5] = 0x9b05688c;
    h[6] = 0x1f83d9ab;
    h[7] = 0x5be0cd19;
    // The message padded: a 1 bit, zeros, and the length in bits (64-bit
    // big-endian), to a multiple of 64 bytes.
    const n = data.length;
    const total = ((n + 9 + 63) / 64) * 64;
    const m = new Uint8Array(total);
    m.set(data, 0);
    m[n] = 0x80;
    const bits = <u64>n * 8;
    for (let i = 0; i < 8; i++) m[total - 1 - i] = <u8>(bits >> (<u64>i * 8));
    const w = new StaticArray<u32>(64);
    for (let off = 0; off < total; off += 64) {
        for (let t = 0; t < 16; t++) {
            const j = off + t * 4;
            w[t] = (<u32>m[j] << 24) | (<u32>m[j + 1] << 16) | (<u32>m[j + 2] << 8) | <u32>m[j + 3];
        }
        for (let t = 16; t < 64; t++) {
            const a = w[t - 15];
            const b = w[t - 2];
            const s0 = rotr(a, 7) ^ rotr(a, 18) ^ (a >>> 3);
            const s1 = rotr(b, 17) ^ rotr(b, 19) ^ (b >>> 10);
            w[t] = w[t - 16] + s0 + w[t - 7] + s1;
        }
        let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (let t = 0; t < 64; t++) {
            const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            const ch = (e & f) ^ (~e & g);
            const t1 = hh + S1 + ch + K[t] + w[t];
            const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            const maj = (a & b) ^ (a & c) ^ (b & c);
            const t2 = S0 + maj;
            hh = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = b;
            b = a;
            a = t1 + t2;
        }
        h[0] += a;
        h[1] += b;
        h[2] += c;
        h[3] += d;
        h[4] += e;
        h[5] += f;
        h[6] += g;
        h[7] += hh;
    }
    const out = new Uint8Array(32);
    for (let i = 0; i < 8; i++) {
        out[i * 4] = <u8>(h[i] >>> 24);
        out[i * 4 + 1] = <u8>(h[i] >>> 16);
        out[i * 4 + 2] = <u8>(h[i] >>> 8);
        out[i * 4 + 3] = <u8>h[i];
    }
    return out;
}

function rotr(x: u32, n: u32): u32 {
    return (x >>> n) | (x << (32 - n));
}

// The digest of `data` in lower-case hex, as `sha256sum` prints it.
export function sha256Hex(data: Uint8Array): string {
    const d = sha256(data);
    const digits = "0123456789abcdef";
    const parts = new Array<string>();
    for (let i = 0; i < d.length; i++) {
        parts.push(digits.charAt(d[i] >> 4));
        parts.push(digits.charAt(d[i] & 15));
    }
    return parts.join("");
}

// The digest of `text`'s UTF-8 bytes, in hex.
export function sha256Text(text: string): string {
    return sha256Hex(Uint8Array.wrap(String.UTF8.encode(text)));
}
