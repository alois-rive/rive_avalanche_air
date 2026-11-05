// The asset container (milestone 39): one prebaked, versioned binary
// holding scenes as .rscnb and the assets they use, each stored once
// however many scenes use it, aligned, with a table of contents read in
// one pass. A built scene carries one in its ASST section and is read as a
// bundle of one scene (scene_file.as); docs/cli/BUILD.md section 17
// ("Inside a built scene") specifies it; this file holds the constants
// every reader and writer agrees on.
//
//   header (BUNDLE_HEADER_BYTES = 64)
//     0  magic          BUNDLE_MAGIC: "RSCNBD", 0x0D, 0x0A
//     8  u16 version    BUNDLE_VERSION
//    10  u16 flags      0
//    12  u32 entries    the table of contents' entries
//    16  u64 size       the file's length in bytes
//    24  u32 toc        the table's offset (64) and
//    28  u32 tocBytes   its length (entries * TOC_ENTRY_BYTES)
//    32  u32 strings    the string table's offset (../rscnb/bin.as
//    36  u32 strBytes   StringTable) and length
//    40  u32 crc32      of bytes [64, data): the table and the strings
//    44  u32 data       the first asset's offset (a multiple of BUNDLE_ALIGN)
//    48  u32 align      BUNDLE_ALIGN
//    52  u32 producer   a string index: "Hedra <version>"
//    56  u64            0 (reserved)
//   table of contents: `entries` records of TOC_ENTRY_BYTES, sorted by
//   kind, then by name (UTF-8 bytes), each
//     u32 kind (AssetKind), u32 name (a string index), u64 offset,
//     u64 size, u32 flags (0), u32 crc32 of the asset's bytes
//   the assets: each at a multiple of BUNDLE_ALIGN; two entries with the
//   same bytes share one range (the dedup across scenes and paths).
//
// Names are bundle paths: a file's path relative to the bundle root (a
// built scene's Hedra project root), with "/"
// ("courtyard/models/bench.rmdl"); an asset that is part of a file has its
// path, "#" and its key ("courtyard/models/planter.glb#image0").
//
// The payload of each kind is the writer's and the reader's (payload.as,
// encode.as, decode.as), specified in docs/cli/BUILD.md section 17.

import { toAsciiLowercase } from "../../base/util";

export const BUNDLE_MAGIC: StaticArray<u8> = [0x52, 0x53, 0x43, 0x4E, 0x42, 0x44, 0x0D, 0x0A];

// The format's version (bumped when this reader could not read a newer
// writer's bundle).
export const BUNDLE_VERSION: u32 = 1;

export const BUNDLE_HEADER_BYTES: i32 = 64;
export const TOC_ENTRY_BYTES: i32 = 32;

// Every asset starts at a multiple of this many bytes: enough for any
// typed view of it (f64) and for the GPU's copy alignment.
export const BUNDLE_ALIGN: i32 = 16;

// What an entry of the table holds. New kinds are appended (a reader
// skips a kind it does not know); a later milestone that adds one says so
// in BUILD.md section 17's table.
export enum AssetKind {
    // The bundle's index, one entry named "": its name, the features its
    // scenes use (../runtime/features.as), each scene's bundle path and
    // project root, the scripts' bundle paths.
    Index = 0,
    // A scene as .rscnb (without its fidelity section), named by the
    // scene's own bundle path (".rscn" kept: it is what an ext_resource, an
    // instance and a script's load() name).
    Scene = 1,
    // A material file (.mtlx) as a .rscnb material document.
    Material = 2,
    // A model (.rmdl, .rmdlcmd, .glb, .gltf, .modeler): its objects (class, parent,
    // transform, visibility, properties, mesh) and materials, read without
    // replaying or importing anything.
    Model = 3,
    // One mesh in the renderer's GPU layout (hedra_engine/render/gpu/layouts.as
    // SurfaceVertex, packed), its indices, material ranges, second UV set,
    // bounds and (milestone 26, payload version 2) its generated levels of
    // detail, stored compressed unless the model's import says not; named
    // "<model path>#<object id>".
    Mesh = 4,
    // A texture: u32 TextureFormat, then its bytes: the source file's (PNG,
    // or Radiance HDR), or (milestone 26) a table of its forms, each a KTX2
    // file of one family Build's --target names, and its source PNG
    // when --target names `source` too (TextureFormat.Ktx2).
    Texture = 5,
    // A LightmapGI's bake (an .lmbake, its layers and meshes) decoded, in
    // binary: no XML at run time.
    Lightmap = 6,
    // A reflection probe's capture (an .rprobe, binary already).
    Probe = 7,
    // A Rive file (.riv) a scene's artboard textures and view model name.
    Rive = 8,
    // A script's record: its class name (the code itself is compiled into
    // the project's module and found through its registry, ../runtime).
    Script = 9,
    // Any other file the loader reads, as it is, mounted in the run time's
    // file system at its path (the fallback: a kind this version does not
    // prebake still loads).
    File = 10,
    // Milestone 26: a primitive mesh's generated levels of detail (a
    // SphereMesh's, a BoxMesh's: the run time builds the mesh from the
    // scene, and has no simplifier to make them), named by the mesh's key
    // (meshproc/lod_bytes.as meshLodKey): encode.as encodeMeshLods.
    Lods = 11,
    // Milestone 36: a sound an AudioStreamPlayer3D plays (an AudioStream
    // ext_resource): what it is (format, rate, channels, length, loop, its
    // Rive asset's name), never its samples, which are the Rive AudioAsset
    // the build declares (./audio.as has the payload).
    Audio = 12,
    // Milestone 37: a baked occluder (an .occ, binary already: an
    // ArrayOccluder3D ext_resource; ../resource/occ_file.as has the
    // format), the file's bytes as they are.
    Occluder = 13,
    // Milestone 61: a shader file (a Shader ext_resource, .wgsl), its text
    // as UTF-8, as it is: the run time reads its declarations again
    // (render/shader/parse.as) and finds the module rive compiled from its
    // composed form by its key (render/shader/program.as shaderAssetName).
    Shader = 14,
}

export const ASSET_KIND_NAMES: StaticArray<string> = [
    "index", "scene", "material", "model", "mesh", "texture", "lightmap", "probe", "rive", "script", "file", "lods", "audio",
    "occluder", "shader",
];

// The name of a kind (its number for one this version does not know).
export function assetKindName(k: u32): string {
    return k < <u32>ASSET_KIND_NAMES.length ? ASSET_KIND_NAMES[<i32>k] : "kind " + k.toString();
}

// A texture's form in the bundle: its source file (PNG, Radiance HDR), or
// (milestone 26) its processed forms, each a KTX2 file
// (hedra_engine/texture/ktx2.as), with or without the source PNG (payload.as
// TEXTURE_KIND_*, BUILD.md section 17).
export enum TextureFormat {
    Png = 1,
    Hdr = 2,
    Ktx2 = 3,
}

// Where the run time puts the bundle's files: a scene at bundle path p is
// BUNDLE_ROOT + "/" + p in its virtual file system, and a scene's project
// root (where its res:// paths start) is BUNDLE_ROOT + "/" + its root.
export const BUNDLE_ROOT = "/hedra-bundle";

// Milestone 40: the root of the `n`th place a bundle can be put in. Scenes
// built into one Rive project share one hedra_engine library and so one
// virtual file system, and each mounts its File entries there
// (provider.as BundleResources.mount): a bundle whose files would replace
// different bytes another bundle mounted at the same path is put at the
// next root instead (BUNDLE_ROOT~2, ~3, ...), so neither reads the other's.
// The first, BUNDLE_ROOT, is every bundle's that meets no such file.
export function bundleRootAt(n: i32): string {
    return n <= 1 ? BUNDLE_ROOT : BUNDLE_ROOT + "~" + n.toString();
}

// The absolute run-time path of bundle path `p` ("" is the root) under
// `root` (a bundleRootAt; the first by default).
export function bundleAbs(p: string, root: string = BUNDLE_ROOT): string {
    return p.length == 0 ? root : root + "/" + p;
}

// The bundle path of a run-time absolute path under any bundle root
// (bundleRootAt), or null outside every bundle.
export function bundlePathOf(abs: string): string? {
    if (!abs.startsWith(BUNDLE_ROOT)) return null;
    let at = BUNDLE_ROOT.length;
    if (at < abs.length && abs.charCodeAt(at) == 0x7e) {
        // "~<digits>"
        let end = at + 1;
        while (end < abs.length && abs.charCodeAt(end) >= 0x30 && abs.charCodeAt(end) <= 0x39) end++;
        if (end == at + 1) return null;
        at = end;
    }
    if (at == abs.length) return "";
    if (abs.charCodeAt(at) != 0x2f) return null;
    return abs.substring(at + 1);
}

// A scene's bundle path as the bundle names it: ".rscn" kept, so that a
// scene built as its .rscnb is found by the name an ext_resource, an
// instance, a script's load() and SceneRuntime.instantiate give its text
// twin ("x.rscnb" is stored and found as "x.rscn"). Any other path as it is.
export function sceneBundleName(path: string): string {
    if (!toAsciiLowercase(path).endsWith(".rscnb")) return path;
    return path.substring(0, path.length - 1);
}

// The bundle path of `abs` (an absolute path on the building machine)
// under the bundle root `root` (absolute, no trailing slash), or null when
// it lies outside.
export function bundlePathUnder(root: string, abs: string): string? {
    if (abs == root) return "";
    const prefix = root == "/" ? "/" : root + "/";
    if (!abs.startsWith(prefix)) return null;
    return abs.substring(prefix.length);
}

// Whether `bytes` start as a bundle does.
export function looksLikeBundle(bytes: Uint8Array): bool {
    if (bytes.length < BUNDLE_MAGIC.length) return false;
    for (let i = 0; i < BUNDLE_MAGIC.length; i++) if (bytes[i] != BUNDLE_MAGIC[i]) return false;
    return true;
}

// One entry of the table of contents.
export class TocEntry {
    kind: u32;
    name: string;
    offset: u64;
    size: u64;
    flags: u32 = 0;
    crc: u32 = 0;

    constructor(kind: u32, name: string, offset: u64, size: u64) {
        this.kind = kind;
        this.name = name;
        this.offset = offset;
        this.size = size;
    }
}
