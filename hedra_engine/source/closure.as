// What loading a source reads: the files a scene, a material, a model, a
// script, a lightmap or an import's settings name, as the loaders resolve
// them. The prefetchers (the Hedra, Hedra and Hedra programs'
// host/prefetch.as, the editor's editor/src/scene/closure.as) ask
// for these files ahead of a run, so that a scene naming many files loads
// in a round or two rather than one round per file: each of them keeps its
// own bookkeeping (what was asked, what was followed, the session's facts)
// and asks this module what each answered file names. One copy of each
// rule, so that a loader's change is followed by every prefetcher at once.
//
// Pure functions of bytes and paths: no host, no facts, no file read. Each
// `*Needs` function appends to `out`, in the order the loader reads the
// files (the prefetch-round tests pin that order, and with it the rounds).
// A file that does not parse names nothing: its load reports it.
//
// What each kind of file names:
// - a scene (.rscn, its binary .rscnb) and a material file (.mtlx): its
//   ext_resources (a material file's through the seam, material_file.as:
//   its textures are its document's ext_resources whatever its format),
//   resolved as the loader resolves them, from the project root that the
//   hedra.yaml files above the scene settle (projectFilesAbove);
// - a model: its `.import` beside it (its import settings, which the loader
//   applies: engine/src/source/scene/import/model_import.as);
//   an .rmdl's files (the textures, MaterialX files and instanced models
//   its ext_resources name, each followed in turn by its plan, and, when a
//   modifier is a tool's, its tools directory: engine/src/source/scene/
//   resource/model.as rmdlDocumentFiles; nothing else: a document is read,
//   never replayed or cached); an .rmdlcmd's own files (the files its lines
//   name, the two directories above its cache directory, its textures and
//   tools directories, its cache directory: rmdlNamedFiles); a glTF's
//   buffers and images;
// - an .rmdlcmd's cache directory, listed: the newest entries of each model
//   it serves; an entry: the files its replay read and its scene's textures;
// - a model's textures or tools directory, listed: its images or tools;
// - a script: the files it imports by relative path, as the CLI's `build`
//   resolves them (scriptImportPath);
// - an .lmbake: its images and its meshes file (lmbakeSidecars);
// - an `.import`: the cache files its [deps] dest_files name;
// - a Rive project's folder, listed: its folders and its .rml files, as
//   engine/src/source/project/project_data.as projectRmlFiles walks it.

import { isValidUtf8 } from "../fs/vfs";
import { parseJson } from "../base/json";
import { toAsciiLowercase } from "../base/util";
import { dataUri, percentDecode } from "./io/core/uri";
import { join, resolveAgainst } from "../fs/path";
import { ModelFileKind, isModelFilePath, lowerExtensionOf, modelFileKind } from "./model/formats";
import {
    RmdlFiles, cacheEntryFiles, isTextureFile, isToolFile, rmdlCacheEntries, rmdlDocumentFiles, rmdlNamedFiles,
} from "./scene/resource/model";
import { parseRscnHead } from "../scene/rscn/parse";
import { decodeRscnb } from "../scene/rscnb/codec";
import { isMaterialFilePath, parseMaterialFileHead } from "./scene/resource/material_file";
import { PROJECT_FILE, ResourceLoader, dirOf } from "../scene/resource/loader";
import { lmbakeSidecars } from "../scene/lightmap/lmbake";
import { importPathOf, parseImportFile } from "./import/sidecar";
import { importerOf } from "./import/params";
import { scanScript } from "./project/script_scan";
import { excludesAllUnder, isExcluded } from "./project/rive_yaml";

// What a file's answer leads to (bits of a plan; a driver may keep its own
// bits above these).
export const CLOSURE_SCENE: i32 = 1; // .rscn, .rscnb: its ext_resources (sceneNeeds)
export const CLOSURE_MODEL: i32 = 2; // .rmdl, .rmdlcmd, .gltf, .glb: its files, buffers, cache (modelNeeds)
export const CLOSURE_SCRIPT: i32 = 4; // .as: its relative imports (scriptNeeds)
export const CLOSURE_MATERIAL: i32 = 8; // .mtlx: its textures, as a scene's ext_resources (sceneNeeds)
export const CLOSURE_LMBAKE: i32 = 16; // .lmbake: its images and meshes file (lmbakeNeeds)
export const CLOSURE_RPROBE: i32 = 32; // .rprobe: read whole, naming nothing
export const CLOSURE_RMDL_CACHE: i32 = 64; // an .rmdlcmd's cache directory: its entries (cacheListingNeeds)
export const CLOSURE_CACHE_ENTRY: i32 = 128; // an .rmdlcmd's cache entry: what it names (cacheEntryNeeds)
export const CLOSURE_TEXTURES: i32 = 256; // an .rmdlcmd's textures directory: its images (listingNeeds)
export const CLOSURE_TOOLS: i32 = 512; // a model's tools directory: its .tool files (listingNeeds)
export const CLOSURE_IMPORT: i32 = 1024; // a source's .import: its cache files (importNeeds)

// How deep a Rive project is walked for its .rml files ahead of a load.
export const RIVE_DATA_DEPTH: i32 = 16;

// What a need asks of a path. The numbers are the host contract's (shared/
// src/host/protocol.as Want: CONTRACT.md's fs wants), so a driver hands
// one on as it is; the engine names them without importing the host.
export enum ClosureWant {
    Stat = 1,
    Read = 2,
    List = 3,
}

// One file (or directory) loading a source reads: what to ask of it, and
// what its answer leads to (CLOSURE_* bits, 0 for nothing).
export class ClosureNeed {
    want: ClosureWant;
    path: string;
    plan: i32;
    // The model a cache entry is of (cacheListingNeeds), which reading the
    // entry needs (cacheEntryNeeds); "" for any other need.
    model: string;
    constructor(want: ClosureWant, path: string, plan: i32, model: string = "") {
        this.want = want;
        this.path = path;
        this.plan = plan;
        this.model = model;
    }
}

// An entry of a directory's listing, as a driver hands it in.
export class ClosureListing {
    name: string;
    isFile: bool;
    isDir: bool;
    constructor(name: string, isFile: bool, isDir: bool = false) {
        this.name = name;
        this.isFile = isFile;
        this.isDir = isDir;
    }
}

// What a named file's bytes lead to, by its extension (any case).
export function closurePlanFor(path: string): i32 {
    const ext = extensionOf(path);
    if (ext == "rscn" || ext == "rscnb") return CLOSURE_SCENE;
    if (isMaterialFilePath(path)) return CLOSURE_MATERIAL;
    if (isModelFilePath(path)) return CLOSURE_MODEL;
    if (ext == "as") return CLOSURE_SCRIPT;
    if (ext == "lmbake") return CLOSURE_LMBAKE;
    if (ext == "rprobe") return CLOSURE_RPROBE;
    return 0;
}

// The project file (`name`, hedra.yaml unless said) a directory may hold.
export function projectFileIn(dir: string, name: string = PROJECT_FILE): string {
    return dir == "/" ? "/" + name : dir + "/" + name;
}

// The project files (hedra.yaml unless `name` says another, such as
// rive.yaml) in `dir` and in each directory above it, nearest first: the
// nearest that is there is the project's (engine/src/scene/
// resource/loader.as findProjectRoot), so a loader asks about each of them
// until one is.
export function projectFilesAbove(dir: string, name: string = PROJECT_FILE): Array<string> {
    const out = new Array<string>();
    let at = dir;
    while (true) {
        out.push(projectFileIn(at, name));
        if (at == "/") break;
        at = dirOf(at);
    }
    return out;
}

// The files a scene (.rscn, .rscnb) or a material file (.mtlx) at `path`
// names (its ext_resources), resolved as the loader resolves them from the
// project root `projectRoot`, each read with its own plan. An .rscn is read
// to the end of its ext_resources only; an .rscnb is decoded whole (it has
// no head to stop at, and its decode costs less than an .rscn's head).
export function sceneNeeds(path: string, data: Uint8Array, projectRoot: string, out: Array<ClosureNeed>): void {
    const parsed = isMaterialFilePath(path) ? parseMaterialFileHead(data, path)
        : extensionOf(path) == "rscnb" ? decodeRscnb(data, path) : parseRscnHead(data, path);
    if (!parsed.ok) return;
    const loader = new ResourceLoader(projectRoot);
    const exts = parsed.value.extResources();
    for (let i = 0; i < exts.length; i++) {
        const r = loader.resolve(exts[i].path, path);
        if (!r.ok) continue;
        out.push(new ClosureNeed(ClosureWant.Read, r.value, closurePlanFor(r.value)));
    }
}

// The files a model at `path` names: its import settings (importSettingsOf),
// then an .rmdl's files (rmdlDocumentFiles: its textures, MaterialX files
// and instanced models, read; its tools directory, listed), an .rmdlcmd's own files (rmdlNamedFiles: those its
// lines name, read; the directories above its cache directory, stated,
// which a replay states for the save it may make; its textures and tools
// directories, listed; its cache directory, listed last) or a glTF's
// buffers and images (gltfNeeds; `cwd` resolves them). Returns the
// .rmdlcmd's cache directory, "" for any other model and for bytes that are
// no .rmdlcmd.
export function modelNeeds(path: string, data: Uint8Array, cwd: string, out: Array<ClosureNeed>): string {
    const settings = importSettingsOf(path);
    if (settings != null) out.push(new ClosureNeed(ClosureWant.Read, settings, CLOSURE_IMPORT));
    const kind = modelFileKind(path);
    if (kind == ModelFileKind.Snapshot) {
        const f = rmdlDocumentFiles(path, data);
        if (f != null) modelFileNeeds(f, out);
        return "";
    }
    if (kind == ModelFileKind.Commands) {
        const f = rmdlNamedFiles(path, data);
        if (f == null) return "";
        modelFileNeeds(f, out);
        out.push(new ClosureNeed(ClosureWant.List, f.cacheDir, CLOSURE_RMDL_CACHE));
        return f.cacheDir;
    }
    if (lowerExtensionOf(path) == "gltf") gltfNeeds(path, data, cwd, out);
    return "";
}

// A model file's needs but its cache directory's, in the loader's order:
// the files it names, read; the directories stated; its textures and tools
// directories, listed.
function modelFileNeeds(f: RmdlFiles, out: Array<ClosureNeed>): void {
    for (let i = 0; i < f.named.length; i++) {
        out.push(new ClosureNeed(ClosureWant.Read, f.named[i], closurePlanFor(f.named[i])));
    }
    for (let i = 0; i < f.stats.length; i++) out.push(new ClosureNeed(ClosureWant.Stat, f.stats[i], 0));
    if (f.texturesDir.length > 0) out.push(new ClosureNeed(ClosureWant.List, f.texturesDir, CLOSURE_TEXTURES));
    if (f.toolsDir.length > 0) out.push(new ClosureNeed(ClosureWant.List, f.toolsDir, CLOSURE_TOOLS));
}

// The files a glTF (JSON) at `path` names beside it, as the importer reads
// them: its buffers, read, then its images (`images`: read unless said; a
// `data:` URI is inline), each URI percent-decoded from the file's
// directory and resolved against `cwd`. `max` caps the entries looked at in
// each of the two arrays.
export function gltfNeeds(path: string, data: Uint8Array, cwd: string, out: Array<ClosureNeed>,
    images: ClosureWant = ClosureWant.Read, max: i32 = i32.MAX_VALUE): void {
    if (!isValidUtf8(data)) return;
    const r = parseJson(String.UTF8.decode(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)));
    if (!r.ok || !r.value.isObject()) return;
    const dir = dirOf(path);
    for (let k = 0; k < 2; k++) {
        const items = r.value.get(k == 0 ? "buffers" : "images");
        if (items == null || !items.isArray()) continue;
        const a = items.asArray()!;
        for (let i = 0; i < a.length && i < max; i++) {
            if (!a[i].isObject()) continue;
            const u = a[i].get("uri");
            if (u == null) continue;
            const uri = u.asStr();
            if (uri == null || uri.length == 0 || dataUri(uri) != null) continue;
            const file = resolveAgainst(cwd, join(dir, percentDecode(uri)));
            out.push(new ClosureNeed(k == 0 ? ClosureWant.Read : images, file, 0));
        }
    }
}

// An .rmdlcmd cache directory `cacheDir`, listed: for each model it serves
// (`models`, absolute .rmdlcmd paths, in the order they were followed), its
// stem's entries among the listing's files, newest first, at most as many as
// Hedra keeps (rmdlCacheEntries), each read (its need names its model).
// An absent directory: no cache.
export function cacheListingNeeds(cacheDir: string, models: Array<string>, listing: Array<ClosureListing>,
    out: Array<ClosureNeed>): void {
    const names = new Array<string>();
    for (let i = 0; i < listing.length; i++) if (listing[i].isFile) names.push(listing[i].name);
    for (let k = 0; k < models.length; k++) {
        const entries = rmdlCacheEntries(models[k], names);
        for (let i = 0; i < entries.length; i++) {
            out.push(new ClosureNeed(ClosureWant.Read, entries[i], CLOSURE_CACHE_ENTRY, models[k]));
        }
    }
}

// A cache entry of the model `model`: the files its replay read (its deps,
// which the lookup hashes again) and the textures of the scene it holds
// (cacheEntryFiles), read.
export function cacheEntryNeeds(model: string, data: Uint8Array, out: Array<ClosureNeed>): void {
    const named = cacheEntryFiles(model, data);
    for (let i = 0; i < named.length; i++) out.push(new ClosureNeed(ClosureWant.Read, named[i], 0));
}

// A model's textures directory (`plan` CLOSURE_TEXTURES: its PNG and JPEG
// images, which a replay of an import looks for there) or tools directory
// (CLOSURE_TOOLS: its `.tool` files, which the load installs), listed: each
// such file, read.
export function listingNeeds(dir: string, plan: i32, listing: Array<ClosureListing>, out: Array<ClosureNeed>): void {
    const tools = (plan & CLOSURE_TOOLS) != 0;
    if (!tools && (plan & CLOSURE_TEXTURES) == 0) return;
    for (let i = 0; i < listing.length; i++) {
        if (!listing[i].isFile) continue;
        const name = listing[i].name;
        if (tools ? isToolFile(name) : isTextureFile(name)) out.push(new ClosureNeed(ClosureWant.Read, join(dir, name), 0));
    }
}

// The files a script at `path` imports by relative path ("./util",
// "../lib/a.as"), read and followed as scripts in turn; the others
// (`hedra_engine/script`, `rive/...`) are no files.
export function scriptNeeds(path: string, data: Uint8Array, out: Array<ClosureNeed>): void {
    if (!isValidUtf8(data)) return;
    const text = String.UTF8.decode(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    const imports = scanScript(text).imports;
    for (let i = 0; i < imports.length; i++) {
        const spec = imports[i];
        if (!spec.startsWith("./") && !spec.startsWith("../")) continue;
        const abs = scriptImportPath(path, spec);
        if (abs.length > 0) out.push(new ClosureNeed(ClosureWant.Read, abs, CLOSURE_SCRIPT));
    }
}

// The absolute path a relative import names from the script `fromAbs`
// ("./a", "../lib/b.as": `.as` added when missing), or "" when it climbs
// above "/": the rule of editor/program/src/build/pack.as importPath,
// which the CLI's `build` packs a script's imports by.
export function scriptImportPath(fromAbs: string, spec: string): string {
    const parts = new Array<string>();
    const base = dirOf(fromAbs).split("/");
    for (let i = 0; i < base.length; i++) if (base[i].length > 0) parts.push(base[i]);
    const rel = spec.split("/");
    for (let i = 0; i < rel.length; i++) {
        const p = rel[i];
        if (p.length == 0 || p == ".") continue;
        if (p == "..") {
            if (parts.length == 0) return "";
            parts.pop();
            continue;
        }
        parts.push(p);
    }
    const abs = "/" + parts.join("/");
    return abs.endsWith(".as") ? abs : abs + ".as";
}

// An .lmbake at `path` (a LightmapGI's light_data): the images and the
// meshes file it names (engine/src/scene/lightmap/lmbake.as
// lmbakeSidecars), read.
export function lmbakeNeeds(path: string, data: Uint8Array, out: Array<ClosureNeed>): void {
    const named = lmbakeSidecars(data, path);
    for (let i = 0; i < named.length; i++) out.push(new ClosureNeed(ClosureWant.Read, named[i], 0));
}

// An `.import` at `path`: the cache files its [deps] dest_files name
// (relative to its directory, resolved against `cwd`), read: the processed
// forms a texture is drawn or stored with, a model's levels of detail. A
// stale list costs an absent answer or two, never correctness.
export function importNeeds(path: string, data: Uint8Array, cwd: string, out: Array<ClosureNeed>): void {
    if (!isValidUtf8(data)) return;
    const p = parseImportFile(String.UTF8.decode(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)), path);
    if (!p.ok) return;
    const dir = dirOf(path);
    const dests = p.value.destFiles;
    for (let i = 0; i < dests.length; i++) {
        out.push(new ClosureNeed(ClosureWant.Read, resolveAgainst(cwd, join(dir, dests[i])), 0));
    }
}

// The `.import` beside a source an importer takes (a .png, an .rmdl, an
// .rmdlcmd, a
// glTF: engine/src/source/import/params.as importerOf), which its
// loader reads for its settings (most sources have none, which the answer
// says at once); null for any other file.
export function importSettingsOf(path: string): string? {
    return importerOf(path) != null ? importPathOf(path) : null;
}

// A folder `dir` of the Rive project at `root`, `depth` levels below it,
// listed: its folders listed in turn and its .rml files read, dot names
// skipped and what rive.yaml's `exclude` (with its output folder: `exclude`)
// leaves out not entered, as engine/src/source/project/project_data.as
// projectRmlFiles walks it; no folder RIVE_DATA_DEPTH levels down or more.
export function riveDataNeeds(root: string, dir: string, depth: i32, exclude: Array<string>,
    listing: Array<ClosureListing>, out: Array<ClosureNeed>): void {
    for (let i = 0; i < listing.length; i++) {
        const e = listing[i];
        if (e.name.startsWith(".")) continue;
        const child = join(dir, e.name);
        const rel = child.substring(root == "/" ? 1 : root.length + 1);
        if (e.isDir) {
            if (depth + 1 >= RIVE_DATA_DEPTH || excludesAllUnder(rel, exclude)) continue;
            out.push(new ClosureNeed(ClosureWant.List, child, 0));
        } else if (e.isFile && toAsciiLowercase(e.name).endsWith(".rml") && !isExcluded(rel, exclude)) {
            out.push(new ClosureNeed(ClosureWant.Read, child, 0));
        }
    }
}

// The lower-case extension of a path, without the dot ("" for none).
function extensionOf(path: string): string {
    const slash = path.lastIndexOf("/");
    const dot = path.lastIndexOf(".");
    return dot <= slash + 1 ? "" : toAsciiLowercase(path.substring(dot + 1));
}
