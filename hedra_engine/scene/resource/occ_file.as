// The .occ resource (milestone 37, an ArrayOccluder3D: a baked occluder):
// what `hedra bake --occluders` and the scene editor's Bake Occluders write
// for each OccluderInstance3D (hedra_compiler/bake/occ_write.as), and what
// every program reads where an ext_resource of type ArrayOccluder3D names
// one. Godot saves its baked occluders as .occ files too (its own binary
// resource); Hedra's is its own format, as its .lmbake is. The format is
// docs/formats/RSCN.md "ArrayOccluder3D" (normative); in short, one binary
// file, little-endian:
//
//   offset  bytes  what
//        0      4  "HOCC"
//        4      4  u32 version, 1
//        8      4  u32 V, the vertices
//       12      4  u32 I, the indices (a multiple of 3)
//       16     24  f32 x 6 the vertices' box: min x, y, z, then max x, y, z
//                  (the node's space: Y up, metres)
//       40      8  u64 FNV-1a 64 of every byte from offset 48 on
//       48 12 x V  the vertices, f32 x, y, z each, in the occluder
//                  instance's space
//   48 + 12V 4 x I the indices, u32 each, every one below V
//
// so 48 + 12 V + 4 I bytes. Written deterministically: the same bake, the
// same bytes (no date, no version of the program). The reader trusts
// nothing: magic, version, counts, the file's length, the digest, the
// floats (finite) and the indices (below V) are checked, and the box is
// checked to hold every vertex (occluder-data-invalid otherwise), which
// the loader turns into a warning at the file: the occluder is then empty
// (occludes nothing) and the scene draws, every object drawn.

import { FNV64_OFFSET, FNV64_PRIME, Result } from "../../base/util";
import { fileStem, parent } from "../../fs/path";
import { vfs } from "../../fs/vfs";
import { CLI } from "../../base/names";
import { SceneryError } from "../error";
import { probeFileKey } from "../probe/rprobe";
import { ArrayOccluder3D } from "./occluders";
import { Resource } from "./types";

export const OCC_MAGIC = "HOCC";
export const OCC_VERSION: u32 = 1;
export const OCC_HEADER_BYTES: i32 = 48;
// The most vertices or indices an .occ may hold: far past what a bake
// keeps (an interior's occluders are hundreds of triangles), a bound on
// what a damaged header can make the reader allocate (48 MB of numbers).
export const OCC_MAX_COUNT: u32 = 4194304;
// The file extension (with its dot).
export const OCC_EXTENSION = ".occ";
export const OCCLUDER_DATA_INVALID_CODE = "occluder-data-invalid";

// The end of the warning an unreadable .occ becomes (the loader's
// readOccluder): the CLI's `bake --occluders` drops it from its answer,
// since the file it writes mends it.
export const OCC_UNREAD_SUFFIX = "; the occluder occludes nothing";

// What an .occ holds.
export class OccContent {
    vertices: Float32Array = new Float32Array(0);
    indices: Uint32Array = new Uint32Array(0);
    // The box written (min x, y, z, max x, y, z).
    bounds: StaticArray<f32> = new StaticArray<f32>(6);
}

// Where the bake of the OccluderInstance3D at `nodePath` (from the root of
// the scene at `scenePath`, which declares it) goes by default:
// `<dir>/<scene stem>.<key>.occ`, the key as an .rprobe's
// (samples/scenes/occlusion/occlusion.Occluder.occ).
export function defaultOccPath(scenePath: string, nodePath: string): string {
    const dir = parent(scenePath);
    const stem = fileStem(scenePath);
    const d = dir != null ? dir : "";
    const s = (stem != null ? stem : "scene") + "." + probeFileKey(nodePath) + OCC_EXTENSION;
    return d.length == 0 ? s : (d == "/" ? "/" + s : d + "/" + s);
}

// The .occ at `abs` read through the vfs into an ArrayOccluder3D (the
// loader's reader of ext_resource type ArrayOccluder3D). Errors:
// occluder-data-invalid at the file (line 0), which the loader turns into a
// warning (the occluder is then empty).
export function readOcc(abs: string, display: string): Result<Resource> {
    const bytes = vfs.read(abs);
    if (!bytes.ok) return invalid<Resource>(display, "cannot read " + display + ": " + bytes.err);
    const r = decodeOcc(bytes.value, display);
    if (!r.ok) return r.forward<Resource>();
    return Result.okv<Resource>(occluderResource(r.value));
}

// `bytes` (an .occ, named `display` in errors) decoded, every check of the
// header's done before anything is allocated from it.
export function decodeOcc(bytes: Uint8Array, display: string): Result<OccContent> {
    const n = bytes.length;
    if (n < OCC_HEADER_BYTES) {
        return invalid<OccContent>(display, display + " is " + n.toString() + " bytes, shorter than the "
            + OCC_HEADER_BYTES.toString() + "-byte header of an occluder");
    }
    let magic = "";
    for (let i = 0; i < 4; i++) magic += String.fromCharCode(bytes[i]);
    if (magic != OCC_MAGIC) return invalid<OccContent>(display, display + " is not an occluder (no " + OCC_MAGIC + " magic)");
    const version = readU32(bytes, 4);
    if (version != OCC_VERSION) {
        return invalid<OccContent>(display, display + " is version " + version.toString() + "; this build reads version "
            + OCC_VERSION.toString());
    }
    const v = readU32(bytes, 8);
    const ic = readU32(bytes, 12);
    if (v > OCC_MAX_COUNT || ic > OCC_MAX_COUNT) {
        return invalid<OccContent>(display, display + ": " + v.toString() + " vertices and " + ic.toString()
            + " indices (at most " + OCC_MAX_COUNT.toString() + " each)");
    }
    if (ic % 3 != 0) return invalid<OccContent>(display, display + ": " + ic.toString() + " indices, not three a triangle");
    const want = <i64>OCC_HEADER_BYTES + <i64>v * 12 + <i64>ic * 4;
    if (<i64>n != want) {
        return invalid<OccContent>(display, display + " is " + n.toString() + " bytes; " + v.toString() + " vertices and "
            + ic.toString() + " indices take " + want.toString());
    }
    const stored = readU64(bytes, 40);
    const digest = occDigest(bytes);
    if (stored != digest) return invalid<OccContent>(display, display + ": its numbers do not match its digest");
    const c = new OccContent();
    for (let k = 0; k < 6; k++) {
        const x = reinterpret<f32>(readU32(bytes, 16 + k * 4));
        if (!isFinite<f32>(x)) return invalid<OccContent>(display, display + ": its box is not finite");
        c.bounds[k] = x;
    }
    const verts = new Float32Array(<i32>v * 3);
    let at = OCC_HEADER_BYTES;
    for (let i = 0; i < <i32>v * 3; i++) {
        const x = reinterpret<f32>(readU32(bytes, at));
        at += 4;
        if (!isFinite<f32>(x)) return invalid<OccContent>(display, display + ": vertex " + (i / 3).toString() + " is not finite");
        const axis = i % 3;
        if (x < c.bounds[axis] || x > c.bounds[3 + axis]) {
            return invalid<OccContent>(display, display + ": vertex " + (i / 3).toString() + " is outside its box");
        }
        verts[i] = x;
    }
    const idx = new Uint32Array(<i32>ic);
    for (let i = 0; i < <i32>ic; i++) {
        const k = readU32(bytes, at);
        at += 4;
        if (k >= v) {
            return invalid<OccContent>(display, display + ": index " + i.toString() + " is " + k.toString() + ", past its "
                + v.toString() + " vertices");
        }
        idx[i] = k;
    }
    c.vertices = verts;
    c.indices = idx;
    return Result.okv<OccContent>(c);
}

// FNV-1a 64 of every byte from the header's end on.
export function occDigest(bytes: Uint8Array): u64 {
    let h = FNV64_OFFSET;
    for (let i = OCC_HEADER_BYTES; i < bytes.length; i++) {
        h ^= <u64>unchecked(bytes[i]);
        h *= FNV64_PRIME;
    }
    return h;
}

// The ArrayOccluder3D of `c` (what the loader keeps), sharing its arrays.
export function occluderResource(c: OccContent): ArrayOccluder3D {
    const r = new ArrayOccluder3D();
    r.setArrays(c.vertices, c.indices);
    return r;
}

const BAKE_AGAIN = "bake the occluders again (`" + CLI + " bake --occluders <scene>`); the format is docs/formats/RSCN.md \"ArrayOccluder3D\"";

function invalid<T>(display: string, message: string): Result<T> {
    return SceneryError.at(OCCLUDER_DATA_INVALID_CODE, display, 0, 0, message, BAKE_AGAIN).fail<T>();
}

function readU32(b: Uint8Array, at: i32): u32 {
    return <u32>b[at] | (<u32>b[at + 1] << 8) | (<u32>b[at + 2] << 16) | (<u32>b[at + 3] << 24);
}

function readU64(b: Uint8Array, at: i32): u64 {
    return <u64>readU32(b, at) | (<u64>readU32(b, at + 4) << 32);
}
