// The replay cache (milestone 21): the scene a model's first n entries
// build, kept beside the model so that opening it again takes the time of
// decoding a scene, not of replaying its commands. docs/formats/RMDLCMD.md,
// "The cache", is the normative description.
//
// Where: `<the model's directory>/build/cache/rmdlcmd/`, one file an entry:
//
//   <stem>.<n>.<key>.mdlc        bench.12.3f9a0c2e5d1b7a44.mdlc
//
// where n is the number of entries replayed and key the 16 hex digits of
// prefixKey(doc, n): FNV-1a 64 of `hedra-model-1 <RMDL_KERNEL> schema
// <SCHEMA_VERSION>\n` followed by the doc's prefixText(n). Comments are not
// in the key, so editing one keeps the cache; a kernel or schema change
// misses every old entry.
//
// The bytes, little-endian:
//
//   0   8  magic "RMDLC\0\0\0"
//   8   4  CACHE_FORMAT (1)
//   12  4  n, the entries replayed
//   16  8  key
//   24  8  the prefix text's length in UTF-8 bytes (a second check on the key)
//   32  4  dep count, then per dep: u32 byte length + the path's UTF-8 (as
//          the command wrote it, relative to the model's directory), u64
//          FNV-1a 64 of the file's bytes (an `import`'s source: what a
//          replay read besides the model)
//   ..  4  the scene's length, then the scene in the HEDRAMDL envelope
//          (hedra_engine/source/model/file.as encode: magic, schema, postcard)
//
// Hedra writes an entry on every save (and, for a long replay, on the
// way: replay.as); Hedra only reads (load.as). An entry that does not
// decode, or whose deps changed, is a miss, never an error. Hedra keeps
// the RMDL_CACHE_KEEP newest entries of a stem and removes the others when
// it writes one.

import { Result, FNV64_OFFSET, FNV64_PRIME, fnv1a64Bytes, i64FitsI32, stableSort } from "../../../base/util";
import { hexU64 } from "../../../base/fmt";
import { Scene } from "../scene";
import { SCHEMA_VERSION, decode as decodeScene } from "../file";
import { vfs, isValidUtf8 } from "../../../fs/vfs";
import { join } from "../../../fs/path";
import { RMDL_KERNEL, RmdlError, E_CACHE } from "./format";
import { RmdlDoc, RmdlEntry } from "./doc";
import { CLI } from "../../../base/names";

// The cache's directory, relative to the model's directory.
export const RMDL_CACHE_DIR = "build/cache/rmdlcmd";
export const RMDL_CACHE_EXTENSION = "mdlc";
export const CACHE_FORMAT: u32 = 1;
// Entries kept a stem: the newest, by n (the longest prefixes).
export const RMDL_CACHE_KEEP: i32 = 4;

// The text every key starts with: what a replay's result depends on besides
// the commands.
export function keySalt(): string {
    return "hedra-model-1 " + RMDL_KERNEL.toString() + " schema " + SCHEMA_VERSION.toString() + "\n";
}

// FNV-1a 64 and the UTF-8 length of text fed to it piece by piece, the
// same as hedra_engine/base/util fnv1a64 of the pieces joined, without joining
// them: the key of a 2,563-command model is then a pass over its lines, not
// a copy of its text (the stub runtime never frees). A surrogate pair is
// never split between two pieces here (every piece ends with a line feed).
class KeyHasher {
    h: u64 = FNV64_OFFSET;
    bytes: u64 = 0;

    private byte(b: u32): void {
        this.h = (this.h ^ <u64>b) * FNV64_PRIME;
        this.bytes++;
    }

    add(s: string): void {
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
                this.byte(c);
            } else if (c < 0x800) {
                this.byte(0xC0 | (c >> 6));
                this.byte(0x80 | (c & 0x3F));
            } else if (c < 0x10000) {
                this.byte(0xE0 | (c >> 12));
                this.byte(0x80 | ((c >> 6) & 0x3F));
                this.byte(0x80 | (c & 0x3F));
            } else {
                this.byte(0xF0 | (c >> 18));
                this.byte(0x80 | ((c >> 12) & 0x3F));
                this.byte(0x80 | ((c >> 6) & 0x3F));
                this.byte(0x80 | (c & 0x3F));
            }
        }
    }

    // One entry's command lines, each with its line feed (doc.prefixText).
    addEntry(e: RmdlEntry): void {
        const c = e.commands;
        for (let k = 0; k < c.length; k++) {
            this.add(c[k]);
            this.byte(0x0A);
        }
    }
}

// A hasher that has taken the salt, its byte count back at zero (the
// prefix length the entry records is the commands' alone).
export function saltedHasher(): KeyHasher {
    const h = new KeyHasher();
    h.add(keySalt());
    h.bytes = 0;
    return h;
}

// The cache key of the doc's first n entries: fnv1a64(keySalt() +
// doc.prefixText(n)), computed without building that text.
export function prefixKey(doc: RmdlDoc, n: i32): u64 {
    const h = saltedHasher();
    const m = n < 0 || n > doc.entryCount() ? doc.entryCount() : n;
    for (let i = 0; i < m; i++) h.addEntry(doc.entries[i]);
    return h.h;
}

// The UTF-8 length of doc.prefixText(n): the entry's second check on its
// key.
export function prefixBytes(doc: RmdlDoc, n: i32): u64 {
    const h = saltedHasher();
    const m = n < 0 || n > doc.entryCount() ? doc.entryCount() : n;
    for (let i = 0; i < m; i++) h.addEntry(doc.entries[i]);
    return h.bytes;
}

// The model's directory, as cacheDirOf takes it: "." for a bare name, ""
// for a file at the root (so that "" + "/build" is absolute again).
export function modelDirOf(modelAbs: string): string {
    const slash = modelAbs.lastIndexOf("/");
    return slash < 0 ? "." : slash == 0 ? "" : modelAbs.substring(0, slash);
}

// `bench` for `/p/models/bench.rmdlcmd`: the file name up to its last dot (a
// dotfile, `.rmdlcmd`, is all stem).
export function stemOf(modelAbs: string): string {
    const name = modelAbs.substring(modelAbs.lastIndexOf("/") + 1);
    const dot = name.lastIndexOf(".");
    return dot <= 0 ? name : name.substring(0, dot);
}

// The hash a CacheDep records of a file's bytes (FNV-1a 64, the standard
// prime): Hedra hashes what an `import` read with it when it writes an
// entry, findCached what is on disk now.
export function depHash(bytes: Uint8Array): u64 {
    return fnv1a64Bytes(bytes);
}

// `<model dir>/build/cache/rmdlcmd` for a model's absolute path.
export function cacheDirOf(modelAbs: string): string {
    return modelDirOf(modelAbs) + "/" + RMDL_CACHE_DIR;
}

// `bench.12.3f9a0c2e5d1b7a44.mdlc`.
export function cacheFileName(stem: string, n: i32, key: u64): string {
    return stem + "." + n.toString() + "." + hexU64(key, 16) + "." + RMDL_CACHE_EXTENSION;
}

// The n and key a cache file's name holds for `stem`, or null when the name
// is not one of stem's entries.
export class CacheName {
    n: i32 = 0;
    key: u64 = 0;
}

// Only the exact form cacheFileName writes is an entry's name: n in
// decimal without a leading zero, the key in 16 lowercase hex digits. The
// key's fixed width makes the parse unambiguous when stems hold dots: for
// the stem `a`, `a.1.5.<key>.mdlc` (an entry of the model `a.1`) is no
// entry, since `5.<key>` is not 16 hex digits.
export function parseCacheFileName(name: string, stem: string): CacheName? {
    const sl = stem.length;
    const tail = 1 + RMDL_CACHE_EXTENSION.length; // ".mdlc"
    // stem "." n "." key16 ".mdlc"
    if (name.length < sl + 1 + 1 + 1 + 16 + tail) return null;
    if (!name.startsWith(stem) || name.charCodeAt(sl) != 0x2E) return null;
    const extAt = name.length - tail;
    if (name.charCodeAt(extAt) != 0x2E || name.substring(extAt + 1) != RMDL_CACHE_EXTENSION) return null;
    const keyAt = extAt - 16;
    if (name.charCodeAt(keyAt - 1) != 0x2E) return null;
    let key: u64 = 0;
    for (let i = keyAt; i < extAt; i++) {
        const c = name.charCodeAt(i);
        let d: i32;
        if (c >= 48 && c <= 57) d = c - 48;
        else if (c >= 97 && c <= 102) d = c - 87;
        else return null;
        key = (key << 4) | <u64>d;
    }
    const nAt = sl + 1;
    const nEnd = keyAt - 1;
    if (nEnd <= nAt) return null;
    if (nEnd - nAt > 1 && name.charCodeAt(nAt) == 48) return null;
    if (nEnd - nAt > 10) return null;
    let n: i64 = 0;
    for (let i = nAt; i < nEnd; i++) {
        const c = name.charCodeAt(i);
        if (c < 48 || c > 57) return null;
        n = n * 10 + <i64>(c - 48);
    }
    // (an entry count past i32 is no name Hedra wrote)
    if (!i64FitsI32(n)) return null;
    const out = new CacheName();
    out.n = <i32>n;
    out.key = key;
    return out;
}

// A file a replay read besides the model, and the hash of its bytes then.
export class CacheDep {
    path: string;
    hash: u64;

    constructor(path: string, hash: u64) {
        this.path = path;
        this.hash = hash;
    }
}

// One cache file's content.
export class CacheEntry {
    n: i32 = 0;
    key: u64 = 0;
    prefixBytes: u64 = 0;
    deps: Array<CacheDep> = [];
    // The scene as hedra_engine/source/model/file.as encode writes it.
    sceneBytes: Uint8Array = new Uint8Array(0);
}

// "RMDLC\0\0\0"
export const MAGIC: StaticArray<u8> = [0x52, 0x4D, 0x44, 0x4C, 0x43, 0, 0, 0];
export const MAGIC_LEN: i32 = 8;
// magic, format, n, key, prefix length, dep count
export const FIXED_LEN: i32 = 8 + 4 + 4 + 8 + 8 + 4;
// A dep's smallest record: its path's length and its hash.
export const DEP_MIN_LEN: i32 = 4 + 8;

function getU32(b: Uint8Array, at: i32): u32 {
    return <u32>b[at] | (<u32>b[at + 1] << 8) | (<u32>b[at + 2] << 16) | (<u32>b[at + 3] << 24);
}

function getU64(b: Uint8Array, at: i32): u64 {
    let v: u64 = 0;
    for (let i = 7; i >= 0; i--) v = (v << 8) | <u64>b[at + i];
    return v;
}

function cacheError(display: string, message: string): RmdlError {
    return new RmdlError(E_CACHE, display, 0, message, "a cache entry is only ever a miss: " + CLI + " writes a new one when it next saves the model");
}

// Fails (E_CACHE) on a bad magic, format, or a truncated file. The scene's
// bytes are a view into `bytes`, not a copy.
export function decodeCacheEntry(bytes: Uint8Array, display: string): Result<CacheEntry> {
    const len = bytes.length;
    if (len < MAGIC_LEN) return cacheError(display, "not a cache entry: too short for its magic").fail<CacheEntry>();
    for (let i = 0; i < MAGIC_LEN; i++) {
        if (bytes[i] != MAGIC[i]) return cacheError(display, "not a cache entry: bad magic").fail<CacheEntry>();
    }
    if (len < MAGIC_LEN + 4) return cacheError(display, "the cache entry is truncated").fail<CacheEntry>();
    const format = getU32(bytes, 8);
    if (format != CACHE_FORMAT) {
        return cacheError(display, "cache entry format " + format.toString() + ", this build reads " + CACHE_FORMAT.toString()).fail<CacheEntry>();
    }
    if (len < FIXED_LEN) return cacheError(display, "the cache entry is truncated").fail<CacheEntry>();
    const e = new CacheEntry();
    const n = getU32(bytes, 12);
    if (n > <u32>i32.MAX_VALUE) return cacheError(display, "the cache entry's entry count is out of range").fail<CacheEntry>();
    e.n = <i32>n;
    e.key = getU64(bytes, 16);
    e.prefixBytes = getU64(bytes, 24);
    const depCount = getU32(bytes, 32);
    let at = FIXED_LEN;
    // (checked against what is left before anything is allocated for it:
    // a damaged count must not ask for gigabytes)
    if (<u64>depCount * <u64>DEP_MIN_LEN > <u64>(len - at)) return cacheError(display, "the cache entry is truncated").fail<CacheEntry>();
    for (let i: u32 = 0; i < depCount; i++) {
        if (len - at < 4) return cacheError(display, "the cache entry is truncated").fail<CacheEntry>();
        const pl = getU32(bytes, at);
        at += 4;
        if (<u64>pl + 8 > <u64>(len - at)) return cacheError(display, "the cache entry is truncated").fail<CacheEntry>();
        const p = bytes.subarray(at, at + <i32>pl);
        if (!isValidUtf8(p)) return cacheError(display, "a dependency path in the cache entry is not UTF-8").fail<CacheEntry>();
        const path = String.UTF8.decodeUnsafe(p.dataStart, <usize>pl);
        at += <i32>pl;
        e.deps.push(new CacheDep(path, getU64(bytes, at)));
        at += 8;
    }
    if (len - at < 4) return cacheError(display, "the cache entry is truncated").fail<CacheEntry>();
    const sl = getU32(bytes, at);
    at += 4;
    if (<u64>sl > <u64>(len - at)) return cacheError(display, "the cache entry is truncated").fail<CacheEntry>();
    if (<u64>sl < <u64>(len - at)) return cacheError(display, "the cache entry has bytes after its scene").fail<CacheEntry>();
    e.sceneBytes = bytes.subarray(at, at + <i32>sl);
    return Result.okv<CacheEntry>(e);
}

// The longest cached prefix of a doc: which entry file, how many entries it
// covers, the scene it holds (decoded, afterLoad run), and the files that
// prefix read: a replay that resumes from it carries them into the next
// entry, or an import in the prefix stops being checked once the model has
// been opened from the cache.
export class CacheHit {
    n: i32 = 0;
    path: string = "";
    scene: Scene = new Scene();
    deps: Array<CacheDep> = [];
}

// One of the stem's entries in the listing.
class Candidate {
    path: string;
    n: i32;
    key: u64;
    // The key and prefix length the doc's first n entries have.
    docKey: u64 = 0;
    docBytes: u64 = 0;

    constructor(path: string, n: i32, key: u64) {
        this.path = path;
        this.n = n;
        this.key = key;
    }
}

export function nameOf(path: string): string {
    return path.substring(max(path.lastIndexOf("/"), path.lastIndexOf("\\")) + 1);
}

// The stem's entries the directory lists, longest prefix first (ties in
// name order, the listing's), or null when it cannot be listed.
export function listEntries(modelAbs: string): Array<Candidate>? {
    const listed = vfs.readDir(cacheDirOf(modelAbs));
    if (!listed.ok) return null;
    const stem = stemOf(modelAbs);
    const out: Array<Candidate> = [];
    const paths = listed.value;
    for (let i = 0; i < paths.length; i++) {
        const c = parseCacheFileName(nameOf(paths[i]), stem);
        if (c != null) out.push(new Candidate(paths[i], c.n, c.key));
    }
    stableSort<Candidate>(out, (a: Candidate, b: Candidate): i32 => b.n - a.n);
    return out;
}

// Whether every dep still hashes as it did. `seen` keeps the hashes this
// lookup read, so that candidates sharing an import read it once.
function depsHold(deps: Array<CacheDep>, modelDir: string, seen: Map<string, u64>): bool {
    for (let i = 0; i < deps.length; i++) {
        const d = deps[i];
        const abs = join(modelDir, d.path);
        let h: u64;
        if (seen.has(abs)) {
            h = seen.get(abs);
        } else {
            const r = vfs.read(abs);
            if (!r.ok) return false;
            h = depHash(r.value);
            seen.set(abs, h);
        }
        if (h != d.hash) return false;
    }
    return true;
}

// Looks through the model's cache directory (through the vfs: a listing,
// then the reads of the candidates, longest first) for the longest prefix
// of `doc` it holds whose deps still hash the same. `wholeOnly`: only an
// entry for the whole doc counts (Hedra). Null on a miss, or when the
// directory does not exist.
//
// The names are checked first: an entry whose name's key is not the doc's
// for its n is never read, so a lookup reads only the entries that can
// match (one, unless a damaged one shadows it). Any failure after that, a
// file that will not decode, a changed dep, a scene of a schema this build
// cannot read, is a miss for that entry and the next one is tried.
export function findCached(doc: RmdlDoc, modelAbs: string, wholeOnly: bool): CacheHit? {
    const listed = listEntries(modelAbs);
    if (listed == null) return null;
    const count = doc.entryCount();
    const cands: Array<Candidate> = [];
    for (let i = 0; i < listed.length; i++) {
        const c = listed[i];
        if (c.n > count || (wholeOnly && c.n != count)) continue;
        cands.push(c);
    }
    if (cands.length == 0) return null;
    // Every candidate's key in one pass over the doc's lines: the list is
    // longest first, so walk it from the end.
    const h = saltedHasher();
    let j = cands.length - 1;
    for (let i = 0; i <= count && j >= 0; i++) {
        while (j >= 0 && cands[j].n == i) {
            cands[j].docKey = h.h;
            cands[j].docBytes = h.bytes;
            j--;
        }
        if (i < count) h.addEntry(doc.entries[i]);
    }
    const dir = modelDirOf(modelAbs);
    // (a model at the root: its deps are under "/", which join needs said)
    const modelDir = dir.length == 0 ? "/" : dir;
    const seen = new Map<string, u64>();
    for (let i = 0; i < cands.length; i++) {
        const c = cands[i];
        if (c.key != c.docKey) continue;
        const r = vfs.read(c.path);
        if (!r.ok) continue;
        const d = decodeCacheEntry(r.value, c.path);
        if (!d.ok) continue;
        const e = d.value;
        if (e.n != c.n || e.key != c.key || e.prefixBytes != c.docBytes) continue;
        if (!depsHold(e.deps, modelDir, seen)) continue;
        const s = decodeScene(e.sceneBytes, c.path);
        if (!s.ok) continue;
        const hit = new CacheHit();
        hit.n = c.n;
        hit.path = c.path;
        hit.scene = s.value;
        hit.deps = e.deps;
        return hit;
    }
    return null;
}

