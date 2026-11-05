// URI and path helpers shared by the exporter and importer: percent
// encoding, lexical relative paths, and the `data:` URI decoding glTF allows
// for images.
//
// Paths are strings with the platform's rules (engine/src/fs/path.as: drive
// prefixes and `\` on Windows); file-system queries (`canonicalize`,
// `current_dir`) go through the VFS (engine/src/fs/vfs.as), which answers
// native paths but never a verbatim `\\?\` one: `stripVerbatim` is the
// identity.

import { StringBuilder } from "../../../base/util";
import { vfs } from "../../../fs/vfs";
import { Component, ComponentKind, components, isAbsolute, join } from "../../../fs/path";

// `UNRESERVED`: b"-._~/".
function isUnreserved(b: i32): bool {
    return b == 45 || b == 46 || b == 95 || b == 126 || b == 47;
}

function isAsciiAlphanumeric(b: i32): bool {
    return (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122);
}

const HEX_UPPER = "0123456789ABCDEF";

// Percent-encode a path for a glTF `uri`: everything outside the URI
// unreserved set (plus `/`) is escaped, byte by byte on the UTF-8, so spaces
// become `%20`.
export function percentEncode(s: string): string {
    const bytes = Uint8Array.wrap(String.UTF8.encode(s));
    const out = new StringBuilder();
    for (let i = 0; i < bytes.length; i++) {
        const b = <i32>bytes[i];
        if (isAsciiAlphanumeric(b) || isUnreserved(b)) {
            out.push(String.fromCharCode(b));
        } else {
            out.push("%" + HEX_UPPER.charAt(b >> 4) + HEX_UPPER.charAt(b & 15));
        }
    }
    return out.toString();
}

function hexDigit(b: i32): i32 {
    if (b >= 48 && b <= 57) return b - 48;
    if (b >= 65 && b <= 70) return b - 55;
    if (b >= 97 && b <= 102) return b - 87;
    return -1;
}

// The hex byte written as the two bytes after a `%` (already known to
// be valid UTF-8, i.e. these are two ASCII bytes or one 2-byte character,
// which never parses). A leading `+` sign is accepted, so `%+F` is 0x0F.
// -1 when it does not parse.
function parseHexPair(b0: i32, b1: i32): i32 {
    const lo = hexDigit(b1);
    if (lo < 0) return -1;
    if (b0 == 43) return lo; // "+X"
    const hi = hexDigit(b0);
    if (hi < 0) return -1;
    return (hi << 4) | lo;
}

// Whether bytes[i..i+2] is valid UTF-8.
function twoBytesAreUtf8(bytes: Uint8Array, i: i32): bool {
    const a = <i32>bytes[i];
    const b = <i32>bytes[i + 1];
    if (a < 0x80) return b < 0x80;
    return a >= 0xC2 && a <= 0xDF && b >= 0x80 && b <= 0xBF;
}

// Decodes well-formed `%XX` escapes only (anything else is copied as is),
// then reads the bytes as UTF-8 lossily (see utf8Lossy).
export function percentDecode(s: string): string {
    const bytes = Uint8Array.wrap(String.UTF8.encode(s));
    const out = new Uint8Array(bytes.length);
    let n = 0;
    let i = 0;
    while (i < bytes.length) {
        let hex = -1;
        if (bytes[i] == 37 && i + 2 < bytes.length && twoBytesAreUtf8(bytes, i + 1)) {
            hex = parseHexPair(<i32>bytes[i + 1], <i32>bytes[i + 2]);
        }
        if (hex >= 0) {
            out[n++] = <u8>hex;
            i += 3;
        } else {
            out[n++] = bytes[i];
            i += 1;
        }
    }
    return utf8Lossy(out.subarray(0, n));
}

function isCont(b: i32): bool {
    return b >= 0x80 && b <= 0xBF;
}

// Decodes UTF-8 lossily: every maximal invalid prefix of a sequence becomes
// one U+FFFD (the WHATWG / Unicode "substitution of maximal subparts" rule).
export function utf8Lossy(bytes: Uint8Array): string {
    const n = bytes.length;
    const out = new StringBuilder();
    let runStart = 0; // start of the pending valid run
    let i = 0;
    while (i < n) {
        const b0 = <i32>bytes[i];
        if (b0 < 0x80) {
            i++;
            continue;
        }
        let bad = 0; // length of the invalid sequence at i, 0 = valid char
        let width = 0;
        if (b0 >= 0xC2 && b0 <= 0xDF) {
            width = 2;
            if (i + 1 < n && isCont(<i32>bytes[i + 1])) bad = 0; else bad = 1;
        } else if (b0 >= 0xE0 && b0 <= 0xEF) {
            width = 3;
            let lo = 0x80;
            let hi = 0xBF;
            if (b0 == 0xE0) lo = 0xA0;
            if (b0 == 0xED) hi = 0x9F;
            if (!(i + 1 < n && <i32>bytes[i + 1] >= lo && <i32>bytes[i + 1] <= hi)) bad = 1;
            else if (!(i + 2 < n && isCont(<i32>bytes[i + 2]))) bad = 2;
        } else if (b0 >= 0xF0 && b0 <= 0xF4) {
            width = 4;
            let lo = 0x80;
            let hi = 0xBF;
            if (b0 == 0xF0) lo = 0x90;
            if (b0 == 0xF4) hi = 0x8F;
            if (!(i + 1 < n && <i32>bytes[i + 1] >= lo && <i32>bytes[i + 1] <= hi)) bad = 1;
            else if (!(i + 2 < n && isCont(<i32>bytes[i + 2]))) bad = 2;
            else if (!(i + 3 < n && isCont(<i32>bytes[i + 3]))) bad = 3;
        } else {
            bad = 1;
        }
        if (bad == 0) {
            i += width;
            continue;
        }
        if (i > runStart) out.push(String.UTF8.decodeUnsafe(bytes.dataStart + <usize>runStart, <usize>(i - runStart)));
        out.push("�");
        i += bad;
        runStart = i;
    }
    if (n > runStart) out.push(String.UTF8.decodeUnsafe(bytes.dataStart + <usize>runStart, <usize>(n - runStart)));
    return out.toString();
}

// `path` made absolute against the current directory (lexically, no
// symlink resolution).
export function absolute(path: string): string {
    if (isAbsolute(path)) return path;
    return join(vfs.currentDir(), path);
}

function sameComponent(a: Component, b: Component): bool {
    return a.kind == b.kind && a.text == b.text;
}

// Lexical relative path from directory `from` to `to`; both must be
// absolute. null when they share no root (their first components differ).
export function relativePath(from: string, to: string): string? {
    const f = components(from);
    const t = components(to);
    const fFirst = f.length > 0;
    const tFirst = t.length > 0;
    if (fFirst != tFirst) return null;
    if (fFirst && !sameComponent(f[0], t[0])) return null;
    let common = 0;
    while (common < f.length && common < t.length && sameComponent(f[common], t[common])) common++;
    let out = "";
    for (let i = common; i < f.length; i++) out = join(out, "..");
    for (let i = common; i < t.length; i++) out = join(out, t[i].text);
    return out;
}

// Best-effort relative path from `dir` to `target`, for URIs and project
// relative texture paths. Both are canonicalized when they exist so that
// symlinked directories (macOS `/tmp`, `/var`) do not produce spurious `..`
// chains; when either does not exist both are used lexically. Falls back to
// the absolute target.
export function bestRelative(dir: string, target: string): string {
    const dc = vfs.canonicalize(dir);
    const tc = vfs.canonicalize(target);
    let d: string;
    let t: string;
    if (dc.ok && tc.ok) {
        d = stripVerbatim(dc.value);
        t = stripVerbatim(tc.value);
    } else {
        d = absolute(dir);
        t = absolute(target);
    }
    const r = relativePath(d, t);
    return r != null ? r : t;
}

// Windows' `\\?\` verbatim prefix: the VFS's `canonicalize` never answers
// one, so the identity.
export function stripVerbatim(path: string): string {
    return path;
}

// A path as a forward-slash string, the form both glTF and the project file
// use: component by component (`a//b/./c/` is `a/b/c`).
export function slashed(path: string): string {
    const cs = components(path);
    const out = new StringBuilder();
    // The last char written (0 while `out` is empty), to tell whether `out` ends in '/'.
    let last = 0;
    for (let i = 0; i < cs.length; i++) {
        const c = cs[i];
        if (c.kind == ComponentKind.RootDir) {
            if (last != 47) {
                out.push("/");
                last = 47;
            }
        } else {
            if (last != 0 && last != 47) out.push("/");
            out.push(c.text);
            // A component is never empty (".", ".." or a name).
            last = <i32>c.text.charCodeAt(c.text.length - 1);
        }
    }
    return out.toString();
}

// `data_uri`'s `(mime, bytes)`.
export class DataUri {
    mime: string;
    bytes: Uint8Array;

    constructor(mime: string, bytes: Uint8Array) {
        this.mime = mime;
        this.bytes = bytes;
    }
}

// Decode a `data:<mime>;base64,<payload>` URI (or a percent-encoded
// `data:<mime>,<payload>` one) into (mime, bytes). null when it is not one.
export function dataUri(uri: string): DataUri? {
    if (!uri.startsWith("data:")) return null;
    const rest = uri.substring(5);
    const comma = rest.indexOf(",");
    if (comma < 0) return null;
    const header = rest.substring(0, comma);
    const payload = rest.substring(comma + 1);
    let mime = header;
    let b64 = false;
    if (header.endsWith(";base64")) {
        mime = header.substring(0, header.length - 7);
        b64 = true;
    }
    let bytes: Uint8Array;
    if (b64) {
        const d = decodeBase64(payload);
        if (d == null) return null;
        bytes = d;
    } else {
        bytes = Uint8Array.wrap(String.UTF8.encode(percentDecode(payload)));
    }
    return new DataUri(mime, bytes);
}

// Base64 with both alphabets (`+`/`-` are 62, `/`/`_` are 63); `=`, `\n`,
// `\r` and space are skipped, anything else is None (null). Trailing bits
// that do not make a byte are dropped.
export function decodeBase64(s: string): Uint8Array? {
    const src = Uint8Array.wrap(String.UTF8.encode(s));
    const out = new Uint8Array(src.length);
    let n = 0;
    let acc: u32 = 0;
    let bits: i32 = 0;
    for (let i = 0; i < src.length; i++) {
        const c = <i32>src[i];
        let v: i32;
        if (c >= 65 && c <= 90) v = c - 65;
        else if (c >= 97 && c <= 122) v = c - 97 + 26;
        else if (c >= 48 && c <= 57) v = c - 48 + 52;
        else if (c == 43 || c == 45) v = 62;
        else if (c == 47 || c == 95) v = 63;
        else if (c == 61 || c == 10 || c == 13 || c == 32) continue;
        else return null;
        acc = (acc << 6) | <u32>v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = <u8>(acc >> <u32>bits);
            acc &= (<u32>1 << <u32>bits) - 1;
        }
    }
    return out.slice(0, n);
}
