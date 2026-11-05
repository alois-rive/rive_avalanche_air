// The .rscnb binary scene (milestone 39): the constants of its layout,
// which docs/formats/RSCN.md ("Binary scenes: .rscnb") specifies and
// codec.as reads and writes. The same PackedScene content as an .rscn, in
// Godot's .scn's way: a string table, a values table, then flat records
// that name strings and values by index, so that a scene instances
// without parsing any text.
//
//   header (32 bytes)
//     0  magic        RSCNB_MAGIC: "RSCNB", 0x00, 0x0D, 0x0A (as PNG's, a
//                     text-mode copy that rewrites line ends is caught)
//     8  u16 version  RSCNB_VERSION, the encoding's
//    10  u16 format   the .rscn format version (rscn/doc.as FORMAT_VERSION)
//    12  u8  kind     RscnbKind: 0 a scene, 1 a material document
//    13  u8  flags    RSCNB_FLAG_*
//    14  u16 sections the number of entries in the section table
//    16  u32 size     the file's length in bytes
//    20  u32 crc32    of bytes [32, size) (hedra_engine/render/png.as crc32)
//    24  u64          0 (reserved)
//   section table: `sections` entries of { u32 id (fourcc), u32 offset,
//   u32 size }, in the order of SECTION_ORDER; every section starts at a
//   multiple of 8 bytes. A reader skips a section it does not know.
//
// The sections' contents are codec.as's, specified in RSCN.md ("Binary
// scenes: .rscnb").

import { toAsciiLowercase } from "../../base/util";
import { fourcc } from "./bin";

// The extension, without the dot.
export const RSCNB_EXTENSION = "rscnb";

// The first eight bytes.
export const RSCNB_MAGIC: StaticArray<u8> = [0x52, 0x53, 0x43, 0x4E, 0x42, 0x00, 0x0D, 0x0A];

// The encoding's version (bumped when a reader of this version could not
// read what a newer writer writes).
export const RSCNB_VERSION: u32 = 1;

// The header's length.
export const RSCNB_HEADER_BYTES: i32 = 32;

// What a .rscnb holds.
export enum RscnbKind {
    // A scene: an RscnDoc of DocKind.Scene.
    Scene = 0,
    // A material document (DocKind.Material): how the bundle stores an
    // .mtlx material, already read.
    Material = 1,
}

// The file keeps what only the tools need (comments, unknown elements and
// attributes, the prolog and epilog: RscnbOptions.fidelity), so that
// `.rscn -> .rscnb -> .rscn` gives the same canonical text. A built scene
// leaves it out.
export const RSCNB_FLAG_FIDELITY: u32 = 1;

// Milestone 40: the file is self-contained, a built scene: its ASST
// section carries every asset the scene uses in its prebuilt form (the
// assets of a bundle of this one scene, ../bundle/format.as AssetKind),
// so that the run time loads it with nothing beside it
// (../bundle/scene_file.as reads it as a bundle of one scene). Set exactly
// when ASST is there. docs/formats/RSCN.md, "Self-contained scenes".
export const RSCNB_FLAG_ASSETS: u32 = 2;

// The sections, by id. STRS and VALS come first, since every other one
// names strings and values; ORDR gives the document's entries in source
// order (the text's sections and its comments between them).
export const SECTION_STRINGS: u32 = fourcc("STRS");
export const SECTION_VALUES: u32 = fourcc("VALS");
export const SECTION_EXT: u32 = fourcc("EXTR");
export const SECTION_SUB: u32 = fourcc("SUBR");
export const SECTION_NODES: u32 = fourcc("NODE");
export const SECTION_ITEMS: u32 = fourcc("ITEM");
export const SECTION_BINDINGS: u32 = fourcc("BIND");
export const SECTION_CONNECTIONS: u32 = fourcc("CONN");
export const SECTION_EMBEDDED: u32 = fourcc("EMBD");
export const SECTION_ORDER: u32 = fourcc("ORDR");
export const SECTION_FIDELITY: u32 = fourcc("FIDL");
// Milestone 40: the embedded assets of a self-contained scene
// (RSCNB_FLAG_ASSETS), after every other section, at a multiple of
// SCENE_ASSET_ALIGN bytes of the file: u32 n, u32 0, then n records of
// 32 bytes { u32 kind (AssetKind), u32 name (a string of STRS), u64
// offset (from the start of the file), u64 size, u32 flags (0), u32 crc32
// }, sorted by kind then name as a bundle's table is, then the assets,
// each at a multiple of SCENE_ASSET_ALIGN bytes of the file. The scene's
// own entry (its kind Scene, its bundle path) is not a record: the file
// is it. RSCN.md, "Self-contained scenes", is normative.
export const SECTION_ASSETS: u32 = fourcc("ASST");
// Milestone 41: a built scene's provenance (the CLI's `build`,
// docs/plans/BUILD.md section 5.4): the library major it was built for,
// its input digest, the SHA-256 of its own .rscn and its path in the Rive
// project (./srcs.as). After ORDR (and FIDL), before ASST. Optional: a
// self-contained scene written without provenance has none.
export const SECTION_SOURCES: u32 = fourcc("SRCS");
// Milestone 41 reserves these for Rive's own model (docs/plans/
// RIVE_MODEL.md section 4.6: RM2's animation keys as parallel arrays,
// RM3's state machine records, RM1's binds and converters as records),
// written after SRCS and before ASST in this order when they come.
// Milestone 42 writes BNDS (./binds.as) when a document needs it,
// milestone 45 ANIM (./anim.as: the scene's Events and LinearAnimations)
// when a document has any, and milestone 46 STMC (./sm.as: the scene's
// StateMachines, ORDR's kind 11) when a document has one; a scene without
// any of them has none, so its bytes are what they were before. A reader
// of an older version refuses ORDR's kind 11 (an entry of an unknown
// kind), which only a scene with a state machine has.
export const SECTION_ANIMATIONS: u32 = fourcc("ANIM");
export const SECTION_STATE_MACHINES: u32 = fourcc("STMC");
export const SECTION_BINDS: u32 = fourcc("BNDS");
// The order of the optional sections a writer places between ORDR (or
// FIDL) and ASST (codec.as RscnbOptions.extra is written in this order).
export const OPTIONAL_SECTION_ORDER: StaticArray<u32> = [
    SECTION_SOURCES, SECTION_ANIMATIONS, SECTION_STATE_MACHINES, SECTION_BINDS,
];
// (the bundle's BUNDLE_ALIGN: any typed view, and the GPU's copies)
export const SCENE_ASSET_ALIGN: i32 = 16;

// Whether `path` names a binary scene (any case).
export function isRscnbPath(path: string): bool {
    return toAsciiLowercase(path).endsWith("." + RSCNB_EXTENSION);
}

// Whether `bytes` start as a .rscnb does (its magic).
export function looksLikeRscnb(bytes: Uint8Array): bool {
    if (bytes.length < RSCNB_MAGIC.length) return false;
    for (let i = 0; i < RSCNB_MAGIC.length; i++) if (bytes[i] != RSCNB_MAGIC[i]) return false;
    return true;
}

// `path` with its .rscn extension made .rscnb ("a.rscn" -> "a.rscnb"), or
// with .rscnb appended when it has another.
export function rscnbPathFor(path: string): string {
    const low = toAsciiLowercase(path);
    if (low.endsWith(".rscn")) return path + "b";
    if (low.endsWith(".rscnb")) return path;
    return path + "." + RSCNB_EXTENSION;
}

// The text twin of a binary scene ("a.rscnb" -> "a.rscn").
export function rscnPathFor(path: string): string {
    const low = toAsciiLowercase(path);
    if (low.endsWith(".rscnb")) return path.substring(0, path.length - 1);
    if (low.endsWith(".rscn")) return path;
    return path + ".rscn";
}
