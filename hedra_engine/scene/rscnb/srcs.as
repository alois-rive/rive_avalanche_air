// A built scene's provenance (milestone 41, docs/plans/BUILD.md section
// 5.4): the SRCS section the CLI's `build` writes into each built .rscnb,
// after ORDR and before ASST (format.as SECTION_SOURCES). The run time reads
// it to tell, cheaply, whether the built form can stand for the scene's
// source (engine/src/scene/runtime/sources.as builtState): built for this library's
// major, and from the same .rscn text as the one the Rive project declares.
//
//   0   u32       the library major it was built for (version.as HEDRA_ENGINE_MAJOR)
//   4   32 bytes  the input digest (every file of the scene's closure, the
//                 import settings, the library, Hedra's version, the
//                 targets: the build's own record of what it read)
//   36  32 bytes  the SHA-256 of the scene's own .rscn bytes
//   68  u32 n, then n bytes of UTF-8: the scene's path in the Rive project
//                 ("world/courtyard.rscn")
//
// Then zeros up to a multiple of 8 (the codec's padding between sections).
// A reader of this version reads these fields and ignores bytes after them,
// so a later version may append fields; RSCN.md, "Built scenes", is
// normative.

import { Result } from "../../base/util";
import { SceneryError } from "../error";
import { BinReader, BinWriter } from "./bin";
import { RSCNB_INVALID_CODE, RSCNB_INVALID_HINT, RscnbSection, rscnbSection } from "./codec";
import { SECTION_SOURCES } from "./format";

// The length of a SHA-256 digest.
export const SRCS_DIGEST_BYTES: i32 = 32;

export class SceneProvenance {
    // The library major the scene was built for.
    major: i32 = 0;
    // The build's input digest, and the SHA-256 of the scene's .rscn.
    inputDigest: Uint8Array = new Uint8Array(SRCS_DIGEST_BYTES);
    textSha256: Uint8Array = new Uint8Array(SRCS_DIGEST_BYTES);
    // The scene's path in the Rive project ("world/courtyard.rscn").
    path: string = "";
}

// The section's bytes for `p` (a digest of another length is the caller's
// mistake: a panic).
export function encodeSrcs(p: SceneProvenance): Uint8Array {
    if (p.inputDigest.length != SRCS_DIGEST_BYTES || p.textSha256.length != SRCS_DIGEST_BYTES) {
        throw new Error("encodeSrcs: a digest is not " + SRCS_DIGEST_BYTES.toString() + " bytes");
    }
    const path = Uint8Array.wrap(String.UTF8.encode(p.path));
    const w = new BinWriter(72 + path.length);
    w.u32(<u32>p.major);
    w.bytes(p.inputDigest);
    w.bytes(p.textSha256);
    w.u32(<u32>path.length);
    w.bytes(path);
    return w.toBytes();
}

// The SRCS section of `p`, for RscnbOptions.extra.
export function srcsSection(p: SceneProvenance): RscnbSection {
    return new RscnbSection(SECTION_SOURCES, encodeSrcs(p));
}

function invalid<T>(file: string, why: string): Result<T> {
    return SceneryError.at(RSCNB_INVALID_CODE, file, 0, 0, file + " is not a binary scene this version reads: its SRCS "
        + "section " + why, RSCNB_INVALID_HINT).fail<T>();
}

// The provenance in the SRCS section's bytes `data` (named `file` in
// errors).
export function decodeSrcs(data: Uint8Array, file: string): Result<SceneProvenance> {
    const r = new BinReader(data);
    const out = new SceneProvenance();
    out.major = <i32>r.u32();
    out.inputDigest = r.copy(SRCS_DIGEST_BYTES);
    out.textSha256 = r.copy(SRCS_DIGEST_BYTES);
    const n = <i32>r.u32();
    out.path = r.utf8(n);
    if (r.failed) return invalid<SceneProvenance>(file, "is cut short or not UTF-8 (" + r.why + ")");
    return Result.okv<SceneProvenance>(out);
}

// The provenance of the .rscnb `bytes` (named `file` in errors), or null
// when it has no SRCS section (a scene saved by the tools, or written
// without provenance); fails as decodeRscnb does on a file this version does not read.
export function sceneProvenance(bytes: Uint8Array, file: string): Result<SceneProvenance?> {
    const s = rscnbSection(bytes, file, SECTION_SOURCES);
    if (!s.ok) return s.forward<SceneProvenance?>();
    const data = s.value;
    if (data == null) return Result.okv<SceneProvenance?>(null);
    const d = decodeSrcs(data!, file);
    if (!d.ok) return d.forward<SceneProvenance?>();
    return Result.okv<SceneProvenance?>(d.value);
}
