// The .rprobe resource (milestone 20, a ReflectionProbe's capture): what
// the CLI's `bake` and the scene editor's Bake button write for each
// ReflectionProbe whose update_mode is once, and what every program reads
// instead of capturing. Its format is docs/formats/RSCN.md
// "ReflectionProbeData" (normative); in short, one binary file,
// little-endian:
//
//   offset  bytes  what
//        0      4  "RPRB"
//        4      4  u32 version, 1
//        8      4  u32 the face size N at level 0 (PROBE_FACE_SIZE, 128)
//       12      4  u32 the levels L (radianceLevels(N): down to 4 texels)
//       16      4  u32 the texel encoding, 1: RGBE (Radiance's shared
//                  exponent, hdr.as's rule for one texel)
//       20     12  f32 x 3 where it was captured from, scene space (Y up,
//                  metres), relative to the root of the scene that
//                  declares the probe
//       32     12  f32 x 3 the probe's size (its box) when captured
//       44      4  u32 flags: 1 interior, 2 enable_shadows
//       48      8  u64 FNV-1a 64 of every byte from offset 56 on
//       56      -  the texels: for each level m = 0 .. L - 1, each face
//                  +X, -X, +Y, -Y, +Z, -Z (probe space, sky.as's order and
//                  orientation), its N >> m rows top first, N >> m texels a
//                  row, 4 bytes a texel
//
// so 524,216 bytes at 128 texels a face (56 + 24 x 21,840 texels).
// Written deterministically: the same capture, the same bytes (no date, no
// version of the program). The reader trusts nothing: magic, version,
// sizes, encoding, the file's length, the digest and the floats are checked
// (reflection-probe-data-invalid otherwise).
//
// In memory the cube is a sky.as RadianceMap in probe space, which has no
// handedness to convert: probe space is the node's axes as scene space has
// them, so the file and memory hold the same directions. Only the capture
// point is in a scene's frame (the reader and writer keep it as written).

import { FNV64_OFFSET, FNV64_PRIME, Result } from "../../base/util";
import { Vec3 } from "../../base/vecmath";
import { fileStem, parent } from "../../fs/path";
import { vfs } from "../../fs/vfs";
import { rgbeDecode } from "../../render/hdr";
import { CubeLevel, RadianceMap, radianceLevels } from "../../render/sky";
import { SceneryError } from "../error";
import { ReflectionProbeData, Resource } from "../resource/types";
import { CLI } from "../../base/names";

export const RPROBE_MAGIC = "RPRB";
export const RPROBE_VERSION: u32 = 1;
// The texel encodings: RGBE, 4 bytes a texel.
export const RPROBE_ENCODING_RGBE: u32 = 1;
export const RPROBE_HEADER_BYTES: i32 = 56;
// RprobeContent flags.
export const RPROBE_INTERIOR: u32 = 1;
export const RPROBE_SHADOWS: u32 = 2;

// The end of the warning an unreadable .rprobe becomes (the loader's
// readProbeData): the CLI's `bake` drops it from its answer, since the file
// it writes mends it.
export const RPROBE_UNREAD_SUFFIX = "; the probe is captured when drawn";

// The file extension (with its dot).
export const RPROBE_EXTENSION = ".rprobe";

// What an .rprobe holds.
export class RprobeContent {
    // PROBE_LEVELS levels of PROBE_FACE_SIZE (any power of two from 4 is
    // read; the renderer draws only PROBE_FACE_SIZE: probe/data.as
    // isProbeCube).
    cube: RadianceMap = new RadianceMap();
    // Scene space, relative to the root of the scene that declares the
    // probe.
    capture: Vec3 = Vec3(0, 0, 0);
    size: Vec3 = Vec3(0, 0, 0);
    // RPROBE_INTERIOR | RPROBE_SHADOWS.
    flags: u32 = 0;
}

// The name a probe's file takes in a file name: its node path from the
// scene's root ("." for the root itself, "root"), each "/" a "-", and every
// character but ASCII letters, digits, "_" and "-" a "_".
export function probeFileKey(probePath: string): string {
    if (probePath == "." || probePath.length == 0) return "root";
    let out = "";
    for (let i = 0; i < probePath.length; i++) {
        const c = probePath.charCodeAt(i);
        const ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 45;
        out += c == 47 ? "-" : ok ? String.fromCharCode(c) : "_";
    }
    return out;
}

// Where the capture of the probe at `probePath` (from the root of the scene
// at `scenePath`, which declares it) goes by default:
// `<dir>/<scene stem>.<probeFileKey(probePath)>.rprobe`
// (samples/scenes/reflections/reflections.Probe.rprobe).
export function defaultRprobePath(scenePath: string, probePath: string): string {
    const dir = parent(scenePath);
    const stem = fileStem(scenePath);
    const d = dir != null ? dir : "";
    const s = (stem != null ? stem : "scene") + "." + probeFileKey(probePath) + RPROBE_EXTENSION;
    return d.length == 0 ? s : (d == "/" ? "/" + s : d + "/" + s);
}

// The .rprobe at `abs` read through the vfs into a ReflectionProbeData
// (the loader's reader of ext_resource type ReflectionProbeData). Errors:
// reflection-probe-data-invalid at the file (line 0), which the loader
// turns into a warning (the probe is then captured when drawn).
export function readRprobe(abs: string, display: string): Result<Resource> {
    const bytes = vfs.read(abs);
    if (!bytes.ok) return invalid<Resource>(display, "cannot read " + display + ": " + bytes.err);
    const r = decodeRprobe(bytes.value, display);
    if (!r.ok) return r.forward<Resource>();
    return Result.okv<Resource>(probeDataResource(r.value));
}

// `bytes` (an .rprobe, named `display` in errors) decoded, every check of
// the header's done before anything is allocated from it: the length, the
// magic, the version, the face size (a power of two from 4 to
// RPROBE_MAX_FACE_SIZE), the levels (radianceLevels of it), the encoding,
// the file's length (exactly the header and the texels), the digest, and
// the capture point and size (finite). Errors: reflection-probe-data-invalid.
export function decodeRprobe(bytes: Uint8Array, display: string): Result<RprobeContent> {
    const n = bytes.length;
    if (n < RPROBE_HEADER_BYTES) {
        return invalid<RprobeContent>(display, display + " is " + n.toString() + " bytes, shorter than the "
            + RPROBE_HEADER_BYTES.toString() + "-byte header of a reflection probe capture");
    }
    let magic = "";
    for (let i = 0; i < 4; i++) magic += String.fromCharCode(bytes[i]);
    if (magic != RPROBE_MAGIC) {
        return invalid<RprobeContent>(display, display + " is not a reflection probe capture (no " + RPROBE_MAGIC + " magic)");
    }
    const version = readU32(bytes, 4);
    if (version != RPROBE_VERSION) {
        return invalid<RprobeContent>(display, display + " is version " + version.toString() + "; this build reads version "
            + RPROBE_VERSION.toString());
    }
    const size = readU32(bytes, 8);
    if (size < 4 || size > RPROBE_MAX_FACE_SIZE || (size & (size - 1)) != 0) {
        return invalid<RprobeContent>(display, display + ": a face of " + size.toString()
            + " texels (a power of two from 4 to " + RPROBE_MAX_FACE_SIZE.toString() + ")");
    }
    const levels = readU32(bytes, 12);
    if (levels != radianceLevels(size)) {
        return invalid<RprobeContent>(display, display + ": " + levels.toString() + " levels for faces of " + size.toString()
            + " texels (it takes " + radianceLevels(size).toString() + ")");
    }
    const encoding = readU32(bytes, 16);
    if (encoding != RPROBE_ENCODING_RGBE) {
        return invalid<RprobeContent>(display, display + ": texel encoding " + encoding.toString() + " (only "
            + RPROBE_ENCODING_RGBE.toString() + ", RGBE)");
    }
    const want = <i64>RPROBE_HEADER_BYTES + texelBytes(size, levels);
    if (<i64>n != want) {
        return invalid<RprobeContent>(display, display + " is " + n.toString() + " bytes; faces of " + size.toString()
            + " texels in " + levels.toString() + " levels take " + want.toString());
    }
    const stored = readU64(bytes, 48);
    const digest = texelDigest(bytes);
    if (stored != digest) {
        return invalid<RprobeContent>(display, display + ": its texels do not match its digest (" + hex16(stored)
            + ", the texels' is " + hex16(digest) + ")");
    }
    const c = new RprobeContent();
    const nums = new StaticArray<f32>(6);
    for (let i = 0; i < 6; i++) {
        const v = reinterpret<f32>(readU32(bytes, 20 + i * 4));
        if (!isFinite<f32>(v)) {
            return invalid<RprobeContent>(display, display + ": its " + (i < 3 ? "capture point" : "size") + " is not finite");
        }
        nums[i] = v;
    }
    c.capture = Vec3(nums[0], nums[1], nums[2]);
    c.size = Vec3(nums[3], nums[4], nums[5]);
    c.flags = readU32(bytes, 44);
    let at = RPROBE_HEADER_BYTES;
    for (let m: u32 = 0; m < levels; m++) {
        const level = new CubeLevel(size >> m);
        const side = <i32>(size >> m);
        for (let f = 0; f < 6; f++) {
            const face = level.faces[f];
            for (let i = 0; i < side * side; i++) {
                const t = rgbeDecode(bytes, at);
                face[i * 3] = t.x;
                face[i * 3 + 1] = t.y;
                face[i * 3 + 2] = t.z;
                at += 4;
            }
        }
        c.cube.levels.push(level);
    }
    return Result.okv<RprobeContent>(c);
}

// The largest face an .rprobe may hold (texels): far past what a capture
// makes (PROBE_FACE_SIZE, 128), a bound on what a damaged header can make
// the reader allocate (1024: 33.5 MB of texels in the file).
export const RPROBE_MAX_FACE_SIZE: u32 = 1024;

const BAKE_AGAIN = "bake the scene again (`" + CLI + " bake <scene>`); the format is docs/formats/RSCN.md \"ReflectionProbeData\"";

function invalid<T>(display: string, message: string): Result<T> {
    return SceneryError.at("reflection-probe-data-invalid", display, 0, 0, message, BAKE_AGAIN).fail<T>();
}

// The texels' bytes of faces of `size` in `levels` levels.
function texelBytes(size: u32, levels: u32): i64 {
    let total: i64 = 0;
    for (let m: u32 = 0; m < levels; m++) {
        const side = <i64>(size >> m);
        total += side * side * 6 * 4;
    }
    return total;
}

// FNV-1a 64 of every byte from the header's end on.
export function texelDigest(bytes: Uint8Array): u64 {
    let h = FNV64_OFFSET;
    for (let i = RPROBE_HEADER_BYTES; i < bytes.length; i++) {
        h ^= <u64>unchecked(bytes[i]);
        h *= FNV64_PRIME;
    }
    return h;
}

function readU32(b: Uint8Array, at: i32): u32 {
    return <u32>b[at] | (<u32>b[at + 1] << 8) | (<u32>b[at + 2] << 16) | (<u32>b[at + 3] << 24);
}

function readU64(b: Uint8Array, at: i32): u64 {
    return <u64>readU32(b, at) | (<u64>readU32(b, at + 4) << 32);
}

// 16 hex digits.
function hex16(v: u64): string {
    let s = v.toString(16);
    while (s.length < 16) s = "0" + s;
    return s;
}

// The ReflectionProbeData of `c` (what the loader keeps), sharing its cube.
export function probeDataResource(c: RprobeContent): ReflectionProbeData {
    const r = new ReflectionProbeData();
    r.cube = c.cube;
    r.capture = c.capture;
    r.size = c.size;
    r.flags = c.flags;
    return r;
}
