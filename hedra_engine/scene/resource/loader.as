// The resource loader: turns the paths a scene names into resources,
// through the host's virtual file system (engine/src/fs/vfs.as), and keeps
// one of each in a cache keyed by type and absolute path, so that a model
// used by a hundred nodes, or a scene instanced a hundred times, is read
// once. One loader serves one load of a scene (one run of a command): the
// vfs is complete only for that run, so a loader is never kept across runs.
//
// Paths: an ext_resource names a file by `res://<path>` (relative to the
// project root: the nearest directory, from the root scene's up, holding
// `hedra.yaml`, else the root scene's directory) or by a path relative to
// the file that names it. Both must stay inside the project; an absolute
// path, another scheme or a way out of the project is an error
// (docs/formats/RSCN.md, "Resource paths").
//
// Errors name files by their display path: `res://<path>` inside the
// project, the absolute path outside it.
//
// A load error about a file as a whole (it cannot be read, is not a PNG,
// is not a model) has line 0 and the file's display path: resolveResources
// (build.as) moves it to the ext_resource that named the file. An error at a
// position inside the file (a syntax error in a nested .rscn) keeps it.
//
// Milestone 67b (docs/engine/RESOURCES.md, "The cache" and "Lifetimes"):
// in a run time the loader has a `holder` (the instance's: ./cache.as),
// and then every resource it hands out, from its own cache, its provider
// or a file, is in the run time's resource cache and held once by the
// holder. A file is looked for in that cache before it is read (keyed by
// its path in the Rive project, ResourceCache.paths with `riveProject` and
// `riveBundleRoot`, which the hook sets: so a second loader, another
// instance's or another Scene3D's, gets the same object), and what a
// resource's loading loaded on the way (a model's textures, a material's)
// becomes its dependency there (ResourceCache.addDep). Without a holder
// (every tool) the loader is as it was.

import { Result, toAsciiLowercase } from "../../base/util";
import { INVALID_UTF8, vfs } from "../../fs/vfs";
import { Image } from "../../render/image";
import { decodeHdr, isHdrPath } from "../../render/hdr";
import { Diagnostics, SceneryError, sceneryErrorOf } from "../error";
import { classInfo, extTypeAccepts, extTypeNames } from "../classdb";
import { readRiveFile } from "./artboard_texture";
import { DATA_SOURCE_UNREADABLE, readRmlData } from "../data/rml_read";
import { DataDoc } from "../data/model";
import { RscnDoc } from "../rscn/doc";
import { parseRscn } from "../rscn/parse";
import { validateRscn } from "../rscn/validate";
import {
    LightmapGIData, ModelFormat, ModelResource, ModelSource, PackedScene, ReflectionProbeData, Resource, RiveData, Script, StandardMaterial3D,
    Texture2D, UnknownResource,
} from "./types";
import {
    FILE_READ_HINT, MODEL_RETIRED_CODE, MODEL_RETIRED_HINT, TEXTURE_DECODE_HINT, TextureSource, retiredModelMessage,
} from "./model_hints";
import { ResourceProvider } from "./provider";
import { RSCNB_EXTENSION } from "../rscnb/format";
import { decodeRscnb } from "../rscnb/codec";
import { LMBAKE_UNREAD_SUFFIX, readLmbake } from "../lightmap/lmbake";
import { RPROBE_UNREAD_SUFFIX, readRprobe } from "../probe/rprobe";
import { OCC_UNREAD_SUFFIX, readOcc } from "./occ_file";
import { ArrayOccluder3D } from "./occluders";
import { Shader, shaderOfText, unreadableShader } from "./shader";
import { CLI, RETIRED_MODEL_EXTENSION } from "../../base/names";
import { AudioStream, audioAssetOfTextPath, isAudioDeclaredMark } from "./audio_stream";
import { CachedResource, ResourceHolder, cacheKeyOf } from "./cache";

// What a .hdr Texture2D must be (hdr.as reads Radiance's RGBE files only).
const HDR_DECODE_HINT = "a .hdr file must be a Radiance HDR image (FORMAT=32-bit_rle_rgbe, -Y <height> +X <width>); "
    + "save it as such, or use a PNG";

// The name of the file that marks a project's root directory.
export const PROJECT_FILE = "hedra.yaml";

// The cache key of a resource: its ext_resource type and absolute path (a
// glTF file is both a Model and a PackedScene; the PackedScene holds the
// same ModelResource).
export function cacheKey(type: string, abs: string): string {
    return type + " " + abs;
}

// The project root for a root scene: the nearest directory, from the
// scene's own up to the file system's root, that holds hedra.yaml; else
// the scene's directory.
export function findProjectRoot(scenePath: string): string {
    const start = dirOf(scenePath);
    let dir = start;
    while (true) {
        if (vfs.isFile(dir == "/" ? "/" + PROJECT_FILE : dir + "/" + PROJECT_FILE)) return dir;
        if (dir == "/") break;
        dir = dirOf(dir);
    }
    return start;
}

// The directory of an absolute contract path ("/" for a file at the root).
export function dirOf(abs: string): string {
    const slash = abs.lastIndexOf("/");
    return slash <= 0 ? "/" : abs.substring(0, slash);
}

// The error `resolve` gives (no position: the caller knows where the
// reference is).
function pathError(code: string, message: string, hint: string): Result<string> {
    return SceneryError.at(code, "", 0, 0, message, hint).fail<string>();
}

const PATH_HINT = "name a file by res://<path> (from the project root) or by a path relative to this file, with /";

// Milestone 40: the file readers the loader cannot do without in a tool,
// and which the engine does not carry: a model file (an .rmdl read, an
// .rmdlcmd replayed, a .modeler, a glTF file with its Draco and meshopt decoders) and a
// MaterialX material file. They need the model kernel and about 2 MB of
// decoders (docs/cli/BUILD.md section 3), so the tools
// install theirs at start (engine/src/source/scene/resource/readers.as,
// installSourceReaders), and the engine's own, ExportedReaders, fails each
// read naming why. A Rive project's run time reads every model and
// material from its built, self-contained .rscnb (../bundle/provider.as
// hands the loader ready resources before it would read a file), so it
// reaches a reader only by a path the built scene has no entry for, which
// Build never writes.
export abstract class FileReaders {
    // The model file at `abs` (`display`: how errors name it), its textures
    // read through `textures`.
    abstract loadModelFile(abs: string, display: string, textures: TextureSource): Result<ModelResource>;

    // `source` as a model of `format` whose textures are relative to
    // `baseDir` (ResourceLoader.adoptModel: the scene editor's model just
    // converted, held in memory).
    abstract modelFromSource(source: ModelSource, format: ModelFormat, baseDir: string, textures: TextureSource): ModelResource;

    // The material file at `abs`, its textures loaded through `loader`.
    abstract readMaterialFile(loader: ResourceLoader, abs: string, display: string): Result<Resource>;

    // Milestone 41: whether these readers read sources at all (the tools'
    // and hedra_engine/source/'s do; the engine's own, ExportedReaders, does
    // not: a scene drawn from its text then says "no source readers").
    readsSources(): bool {
        return true;
    }

    // Milestone 36: the sound at `abs`, an ext_resource of `type`
    // (AudioStream, AudioStreamWAV, AudioStreamMP3): `bytes` the file's,
    // or null when the file is a Rive AudioAsset the run time cannot read
    // (./audio_stream.as AUDIO_DECLARED_TEXT). This default, the engine's
    // (ExportedReaders keeps it), reads nothing: a stream whose length the
    // runtime's AudioSource gives at its first play, without a loop. The
    // source tier's (engine/src/source/audio/reader.as) reads the header
    // (format, rate, channels, length; audio-invalid when it is none of
    // WAV, MP3 and FLAC) and the .import beside the file (the loop, the
    // left and right forms).
    readAudioFile(abs: string, display: string, type: string, bytes: Uint8Array?): Result<Resource> {
        const a = new AudioStream();
        a.type = type;
        return Result.okv<Resource>(a);
    }
}

const NOT_EXPORTED_HINT = "the run time reads models and materials from a built scene only: "
    + "build the scene again with `" + CLI + " build` (docs/cli/BUILD.md)";

// The engine's readers (milestone 39's readers_export.as): every read fails
// as a file that does not load, saying the built scene holds no such file.
export class ExportedReaders extends FileReaders {
    readsSources(): bool {
        return false;
    }

    loadModelFile(abs: string, display: string, textures: TextureSource): Result<ModelResource> {
        return SceneryError.at("model-load", display, 0, 0,
            "cannot load model " + display + ": the built scene holds no such model", NOT_EXPORTED_HINT).fail<ModelResource>();
    }

    modelFromSource(source: ModelSource, format: ModelFormat, baseDir: string, textures: TextureSource): ModelResource {
        const m = new ModelResource();
        m.source = source;
        m.format = format;
        m.warnings.push("the run time does not convert models");
        return m;
    }

    readMaterialFile(loader: ResourceLoader, abs: string, display: string): Result<Resource> {
        return SceneryError.at("file-read", display, 0, 0,
            "cannot read " + display + ": the built scene holds no such material", NOT_EXPORTED_HINT).fail<Resource>();
    }
}

// Null until first asked for or installed. (A constant initial value on
// purpose: a non-constant one runs in the start function in module order,
// and a tool's module that installs its readers by a top-level statement
// can run before this module's initialiser, which would then put the
// engine's default back over the tool's.)
let fileReaders: FileReaders? = null;

// Installs the readers every later load uses (a tool's, at start).
export function installFileReaders(r: FileReaders): void {
    fileReaders = r;
}

// The readers installed (the engine's ExportedReaders until a tool
// installs its own).
export function currentFileReaders(): FileReaders {
    let r = fileReaders;
    if (r == null) {
        r = new ExportedReaders();
        fileReaders = r;
    }
    return r;
}

export class ResourceLoader {
    // Absolute, normalised, no trailing slash (but "/" itself).
    projectRoot: string;
    // Warnings (and, with `inspect --check`, errors) found while loading,
    // in the order found: unknown types and properties of every document
    // read, textures that could not be read, a model's import warnings.
    diagnostics: Diagnostics = new Diagnostics();
    private cache: Map<string, Resource> = new Map<string, Resource>();
    // Milestone 39: ready resources asked for before any file is read (the
    // run time's built scene: provider.as); null in every tool.
    provider: ResourceProvider? = null;
    // Milestone 67b (docs/engine/RESOURCES.md, "Lifetimes"): the run time's
    // holder of the instance this loader loads for (./cache.as): every
    // resource `load` hands out is held once by it. Null in every tool (and
    // in a runtime without the cache hook): nothing is counted.
    holder: ResourceHolder? = null;
    // Milestone 67b: the Hedra project this loader loads for (its path in
    // the Rive project, "" for its root) and the root its bundle is mounted
    // at ("" for none): what the cache's keys are made from (see the
    // header). Set with `holder` by the run time's hook.
    riveProject: string = "";
    riveBundleRoot: string = "";
    // Milestone 67b (docs/engine/RESOURCES.md, "Lifetimes"): the holders of
    // what the instance's scripts load and instance, apart from the
    // instance's own (`beginScope`): one for each scene a script loaded
    // (../script.as NodeScript.load, until PackedSceneRef.release) and one
    // for each subtree it instanced (until the subtree is freed:
    // ../tree/node.as markFreed). Each is let go of when its owner goes,
    // and every one of them when the instance does (releaseHolders).
    scopedHolders: Array<ResourceHolder> = [];
    // Milestone 67b: how many live instances were made with this loader's
    // trees (the run time's hook counts them). Usually one; a tree a
    // program instances with another instance's loader (instance.as
    // instantiate, then SceneRuntime.instantiateTree: a cutscene read
    // through its level's loader) makes two, and the holders above are
    // both instances' then: let go of with the last (releaseHolders).
    instances: i32 = 0;
    private scopeStack: Array<ResourceHolder> = [];
    // The resources each load in progress loaded on the way, innermost
    // last (its dependencies), and the keys `forget` dropped, which are
    // read again rather than taken from the run time's cache.
    private holding: Array<Array<CachedResource>> = [];
    private refetch: Set<string>? = null;
    // The resources `hold` put in the run time's cache (`wasFreed`).
    private handed: Set<Resource> = new Set<Resource>();

    constructor(projectRoot: string) {
        this.projectRoot = projectRoot;
    }

    // A loader for a root scene: its project root found by
    // findProjectRoot.
    static forScene(scenePath: string): ResourceLoader {
        return new ResourceLoader(findProjectRoot(scenePath));
    }

    // Puts a resource in the cache (tests; and the loader itself).
    put(type: string, abs: string, r: Resource): void {
        this.cache.set(cacheKey(type, abs), r);
    }

    // Every resource loaded so far (ext_resources: scenes, models, textures,
    // scripts), in the order they were first loaded: what the CLI's `inspect`
    // lists as a scene's files. Each resource's `path` is its absolute
    // path, `file` its display path.
    loaded(): Array<Resource> {
        return this.cache.values();
    }

    // Milestone 67b: from now until endScope, what `load` hands out is held
    // by a holder of its own, which it returns (null without the run time's
    // cache: nothing is held, and endScope need not be called).
    beginScope(): ResourceHolder? {
        const h = this.holder;
        if (h == null) return null;
        // (the holders whose owners went, dropped from the list first)
        if (this.scopedHolders.length >= 32) {
            const live = new Array<ResourceHolder>();
            for (let i = 0; i < this.scopedHolders.length; i++) if (!this.scopedHolders[i].closed) live.push(this.scopedHolders[i]);
            this.scopedHolders = live;
        }
        const s = new ResourceHolder(h.cache);
        this.scopedHolders.push(s);
        this.scopeStack.push(h);
        this.holder = s;
        return s;
    }

    // Milestone 67b: `h`, a holder made outside a scope (a node moved out
    // of an instanced subtree: ../tree/node.as removeChild), let go of
    // with the instance's others (releaseHolders) unless its owner closes
    // it first.
    adopt(h: ResourceHolder): void {
        this.scopedHolders.push(h);
    }

    // The holder of before beginScope's again.
    endScope(): void {
        const n = this.scopeStack.length;
        if (n == 0) return;
        this.holder = this.scopeStack.pop();
    }

    // Milestone 67b: lets go of everything this loader's instance holds:
    // its scripts' scenes and subtrees (the scoped holders, the last made
    // first), then its own (the run time's hook, when the instance is
    // disposed).
    releaseHolders(): void {
        for (let i = this.scopedHolders.length - 1; i >= 0; i--) this.scopedHolders[i].close();
        this.scopedHolders.length = 0;
        const h = this.holder;
        if (h != null) h.releaseAll();
    }

    // Drops a resource from the cache (a root scene read again once it
    // turned out to be packed: its display path changes with the root).
    forget(type: string, abs: string): void {
        this.cache.delete(cacheKey(type, abs));
        // (milestone 67b: read again, not taken from the run time's cache)
        if (this.holder != null) {
            let r = this.refetch;
            if (r == null) {
                r = new Set<string>();
                this.refetch = r;
            }
            r.add(cacheKey(type, abs));
        }
    }

    // Milestone 67b: the path in the Rive project of `abs` (the run time's
    // ResourceCache.paths), else `abs` itself.
    private keyPath(abs: string): string {
        const h = this.holder;
        if (h == null) return abs;
        const paths = h.cache.paths;
        const p = paths != null ? paths.rivePath(abs, this.riveProject, this.riveBundleRoot) : "";
        return p.length > 0 ? p : abs;
    }

    // Milestone 67b: the run time's cache key of the file `abs` read as
    // `type` (its source: "s"; a material's with the root its textures
    // resolve against; one a provider gave without the cache, "p").
    private keyOf(type: string, abs: string, provided: bool): string {
        let variant = provided ? "p" : "s";
        if (type == "Material") variant += "|" + this.projectRoot;
        return cacheKeyOf(type, this.keyPath(abs), variant);
    }

    // Milestone 67b: the resource the run time's cache holds for the file
    // `abs` as `type` (another loader read it), or null.
    private shared(type: string, abs: string): Resource? {
        const h = this.holder;
        if (h == null) return null;
        const r = this.refetch;
        if (r != null && r.has(cacheKey(type, abs))) return null;
        const e = h.cache.find(this.keyOf(type, abs, false));
        return e != null ? e.resource : null;
    }

    // Milestone 67b: `r` (loaded as `type` from `abs`) in the run time's
    // cache and held by the holder; `deps` what its loading loaded (null:
    // it was not loaded now). Also a dependency of the load in progress
    // around it, if any.
    private hold(type: string, abs: string, r: Resource, deps: Array<CachedResource>?, provided: bool): void {
        const h = this.holder;
        if (h == null) return;
        const cache = h.cache;
        let e = cache.entryOf(r);
        let replaced: CachedResource? = null;
        if (e == null) {
            const path = this.keyPath(abs);
            const key = this.keyOf(type, abs, provided);
            e = cache.add(key, path, type, r);
            // (the key taken by another object of the same file: one read
            // before `forget`, which this loader read again and hands out
            // in its place. The new one takes the key, so that it is
            // counted, shared and freed; this loader's reference to the
            // old one goes once the new one holds what both name, and the
            // old one is freed when its last holder goes)
            if (e.resource !== r) {
                replaced = e;
                cache.unkey(key);
                e = cache.add(key, path, type, r);
            }
            if (e.origin.from.length == 0) e.origin.from = path;
        }
        if (deps != null) for (let i = 0; i < deps.length; i++) cache.addDep(e, deps[i]);
        const n = this.holding.length;
        if (n > 0) this.holding[n - 1].push(e);
        h.hold(e);
        if (!e.depsSettled) cache.settle(e);
        this.handed.add(r);
        if (replaced != null) {
            h.drop(replaced);
            const old = replaced.resource;
            if (this.handed.has(old)) this.handed.delete(old);
        }
    }

    // Milestone 67b: whether `r`, which this loader handed out to a holder,
    // was freed by the run time's cache since (no live entry holds it).
    // A resource never handed out (a tool's, a placeholder while its file
    // is read) is not.
    private wasFreed(r: Resource): bool {
        const h = this.holder;
        if (h == null || !this.handed.has(r)) return false;
        return h.cache.entryOf(r) == null;
    }

    // The absolute paths mountEmbedded mounted, in order: listing a
    // directory does not show mounted files (vfs.mount), so what walks one
    // (the CLI's `build` reading a Rive project a packed scene carries) asks
    // here.
    mounted: Array<string> = [];

    // A packed scene's files (docs/formats/RSCN.md, "Packed scenes"): each
    // embedded file of `doc` is mounted in the virtual file system at its
    // res:// path under the project root, over whatever is on disk there,
    // so that every later read of the scene's resources finds it. Mounted,
    // not added: an added file would make its directories exist, and a
    // command writing into one (`render q.rscn -o models/shot.png` beside
    // the packed file alone) would then not create it. Returns
    // how many files it mounted. A file at `skip` (the packed scene's own
    // absolute path) is not mounted: it would stand in for the scene, which
    // the CLI's `build --pack` refuses to make (`pack-collision`) but a hand
    // edit can.
    mountEmbedded(doc: RscnDoc, skip: string = ""): i32 {
        const files = doc.embeddedFiles();
        const base = this.projectRoot == "/" ? "" : this.projectRoot;
        let n = 0;
        for (let i = 0; i < files.length; i++) {
            const f = files[i];
            const abs = base + "/" + f.path.substring(6);
            if (abs == skip) continue;
            vfs.mount(abs, f.data);
            if (!this.mounted.includes(abs)) this.mounted.push(abs);
            n++;
        }
        return n;
    }

    cached(type: string, abs: string): Resource? {
        const k = cacheKey(type, abs);
        return this.cache.has(k) ? this.cache.get(k) : null;
    }

    // How errors name an absolute path: `res://<path>` inside the project,
    // else the path itself.
    displayPath(abs: string): string {
        const root = this.projectRoot;
        if (abs == root) return "res://";
        if (root == "/") return abs.startsWith("/") ? "res://" + abs.substring(1) : abs;
        if (abs.startsWith(root + "/")) return "res://" + abs.substring(root.length + 1);
        return abs;
    }

    // The absolute path an ext_resource's `path` names, `fromFile` being
    // the absolute path of the file that names it ("" for a document built
    // in code: relative paths start at the project root). Errors: code
    // "path-invalid" (empty, absolute, another scheme, a backslash, a
    // directory) or "path-outside-project"; `file`, `line`, `col` are left
    // empty for the caller, which knows where the reference is.
    resolve(ref: string, fromFile: string): Result<string> {
        if (ref.length == 0) return pathError("path-invalid", "the path is empty", PATH_HINT);
        if (ref.includes("\\")) return pathError("path-invalid", "\"" + ref + "\" has a backslash", PATH_HINT);
        let base: string;
        let rel: string;
        if (ref.startsWith("res://")) {
            base = this.projectRoot;
            rel = ref.substring(6);
        } else if (ref.includes("://") || ref.startsWith("/") || (ref.length >= 2 && ref.charCodeAt(1) == 58)) {
            return pathError("path-invalid", "\"" + ref + "\" is not a res:// or relative path", PATH_HINT);
        } else {
            base = fromFile.length > 0 ? dirOf(fromFile) : this.projectRoot;
            rel = ref;
        }
        if (rel.length == 0 || rel.endsWith("/")) return pathError("path-invalid", "\"" + ref + "\" names a directory", PATH_HINT);
        // Normalised by hand rather than by normalizeAbs, which stops at "/"
        // silently: a ".." above the root must be an error.
        const parts = new Array<string>();
        const baseParts = base.split("/");
        for (let i = 0; i < baseParts.length; i++) if (baseParts[i].length > 0) parts.push(baseParts[i]);
        const relParts = rel.split("/");
        for (let i = 0; i < relParts.length; i++) {
            const p = relParts[i];
            if (p.length == 0 || p == ".") continue;
            if (p == "..") {
                if (parts.length == 0) {
                    return pathError("path-outside-project", "\"" + ref + "\" leads outside the project (" + this.displayPath(this.projectRoot) + ")", PATH_HINT);
                }
                parts.pop();
                continue;
            }
            parts.push(p);
        }
        const abs = "/" + parts.join("/");
        const root = this.projectRoot;
        if (root != "/" && abs != root && !abs.startsWith(root + "/")) {
            return pathError("path-outside-project", "\"" + ref + "\" leads outside the project (the root is " + root + ")", PATH_HINT);
        }
        return Result.okv<string>(abs);
    }

    // The resource of that type at that absolute path: the cached one, else
    // loaded (and cached). Types: those of classdb's extTypeNames(); the
    // file's extension must be one the type accepts.
    load(type: string, abs: string): Result<Resource> {
        let have = this.cached(type, abs);
        // (milestone 67b: one this loader handed out that the run time's
        // cache has freed since, its last holder gone: its pixels, arrays
        // and GPU objects are released, so it is read again, as Godot's
        // load() after the last Ref went)
        if (have != null && this.wasFreed(have)) {
            this.cache.delete(cacheKey(type, abs));
            this.handed.delete(have);
            have = null;
        }
        if (have != null) {
            // (milestone 67b: held by this loader's instance, once)
            if (this.holder != null) this.hold(type, abs, have, null, false);
            return Result.okv<Resource>(have);
        }
        const display = this.displayPath(abs);
        const types = extTypeNames();
        if (!types.includes(type)) {
            return SceneryError.at("ext-type-unknown", display, 0, 0, "unknown resource type \"" + type + "\"",
                "the resource types are " + types.join(", ")).fail<Resource>();
        }
        const ext = extensionOf(abs);
        if (!extTypeAccepts(type, ext)) {
            const info = classInfo(type);
            const wanted = info != null ? extensionList(info.extensions) : "";
            // The error is at the file, so the message leaves its path out
            // (LoaderTextures puts it back where the message stands alone).
            return SceneryError.at("ext-type-extension", display, 0, 0,
                "cannot be a " + type + ": a " + type + " is a " + wanted + " file",
                "name a " + wanted + " file where a " + type + " goes").fail<Resource>();
        }
        let r: Result<Resource>;
        // (milestone 67b: what this load loads on the way, its dependencies)
        const holding = this.holder != null;
        if (holding) this.holding.push(new Array<CachedResource>());
        const p = this.provider;
        const provided = p != null ? p.provide(type, abs, display, this.projectRoot) : null;
        const shared = provided == null && holding ? this.shared(type, abs) : null;
        if (provided != null) r = provided;
        else if (shared != null) r = Result.okv<Resource>(shared);
        else if (type == "PackedScene") r = this.readScene(abs, display, ext);
        else if (type == "Model") r = this.readModel(abs, display);
        else if (type == "Texture2D") r = this.readTexture(abs, display);
        else if (type == "Material") r = this.readMaterial(abs, display);
        else if (type == "RiveFile") r = readRiveFile(abs, display);
        else if (type == "RiveData") r = this.readRiveData(abs, display);
        else if (type == "LightmapGIData") r = this.readLightmap(abs, display);
        else if (type == "ReflectionProbeData") r = this.readProbeData(abs, display);
        else if (type == "ArrayOccluder3D") r = this.readOccluder(abs, display);
        else if (type == "Shader") r = this.readShader(abs, display);
        else if (type == "AudioStream" || type == "AudioStreamWAV" || type == "AudioStreamMP3") r = this.readAudio(type, abs, display);
        else r = this.readScript(abs, display);
        const deps = holding ? this.holding.pop() : null;
        if (!r.ok) return r;
        const res = r.value;
        res.path = abs;
        res.file = display;
        this.put(type, abs, res);
        if (holding) this.hold(type, abs, res, deps, provided != null);
        return r;
    }

    // Milestone 42: an .rml read for its data model (a ViewModel's `file`;
    // ../data/rml_read.as). A file that cannot be read fails the scene as
    // any file a scene names; one that reads but is not RML data rive
    // accepts does not: its error becomes the warning data-source-unreadable
    // at the file and the RiveData holds no data, so the scene draws, its
    // bindings unresolved (../data/source.as dataSourceOf says why).
    private readRiveData(abs: string, display: string): Result<Resource> {
        const t = vfs.readToString(abs);
        if (!t.ok) {
            return SceneryError.at("file-read", display, 0, 0, "cannot read " + display + ": " + t.err,
                "the path is relative to the file that names it, or res:// from the project root").fail<Resource>();
        }
        const f = new RiveData();
        const r = readRmlData(t.value, display);
        if (r.ok) {
            r.value.path = abs;
            f.data = r.value;
            return Result.okv<Resource>(f);
        }
        const e = sceneryErrorOf<DataDoc>(r);
        this.diagnostics.warning(DATA_SOURCE_UNREADABLE, display, e != null ? e.line : 0, e != null ? e.col : 0,
            display + " does not read as RML data: " + (e != null ? e.message : r.err),
            "fix the file (`rive inspect` names the same problem); `" + CLI + " inspect " + display + "` shows what it declares");
        return Result.okv<Resource>(f);
    }

    // Milestone 19: an .lmbake (lmbake.as). One that cannot be read (a file
    // missing or damaged, a format this program does not read) does not
    // fail the scene: its error becomes a warning at the file, and the
    // LightmapGIData holds no bake, so the scene is drawn in real time and
    // can be baked again (the CLI's `bake` and the editor load the scene
    // first: a fatal bake file would leave it stuck until edited by hand).
    private readLightmap(abs: string, display: string): Result<Resource> {
        const r = readLmbake(abs, display);
        if (r.ok) return r;
        const e = sceneryErrorOf<Resource>(r);
        if (e == null) return r;
        this.diagnostics.warning(e.code, e.file, e.line, e.col,
            e.message + LMBAKE_UNREAD_SUFFIX, e.hint);
        return Result.okv<Resource>(new LightmapGIData());
    }

    // Milestone 20: an .rprobe (../probe/rprobe.as). As an .lmbake, one that
    // cannot be read does not fail the scene: its error becomes a warning
    // at the file, and the ReflectionProbeData holds no cube, so the probe
    // is captured when drawn, as one without a bake, and the CLI's `bake`
    // writes the file again.
    private readProbeData(abs: string, display: string): Result<Resource> {
        const r = readRprobe(abs, display);
        if (r.ok) return r;
        const e = sceneryErrorOf<Resource>(r);
        if (e == null) return r;
        this.diagnostics.warning(e.code, e.file, e.line, e.col,
            e.message + RPROBE_UNREAD_SUFFIX, e.hint);
        return Result.okv<Resource>(new ReflectionProbeData());
    }

    // Milestone 37: an .occ (./occ_file.as), a baked occluder. As an
    // .rprobe, one that cannot be read does not fail the scene: its error
    // becomes a warning at the file, and the ArrayOccluder3D is empty, so it
    // occludes nothing and every object is drawn, and the CLI's `bake
    // --occluders` writes the file again.
    private readOccluder(abs: string, display: string): Result<Resource> {
        const r = readOcc(abs, display);
        if (r.ok) return r;
        const e = sceneryErrorOf<Resource>(r);
        if (e == null) return r;
        this.diagnostics.warning(e.code, e.file, e.line, e.col,
            e.message + OCC_UNREAD_SUFFIX, e.hint);
        return Result.okv<Resource>(new ArrayOccluder3D());
    }

    // Milestone 61: a shader file (.wgsl): its text and its declarations
    // (shader.as shaderOfText). One that reads with errors loads (its
    // problems are the program's: the materials that use it draw their
    // fallback, ../render/materials.as reports them), and so does one
    // that cannot be read, missing or not UTF-8 (shader.as
    // unreadableShader: its one error file-read), which the robustness rule
    // of a shader that does not compile covers too: the scene draws, its
    // material says why it is drawn plain.
    private readShader(abs: string, display: string): Result<Resource> {
        const t = vfs.readToString(abs);
        if (!t.ok) {
            const encoding = t.err.includes(INVALID_UTF8);
            const hint = encoding ? "save the shader as UTF-8 text (WGSL is ASCII; a comment may be any UTF-8)" : FILE_READ_HINT;
            return Result.okv<Resource>(unreadableShader(display, t.err, hint));
        }
        return Result.okv<Resource>(shaderOfText(t.value, display));
    }

    // Milestone 14: a material file, MaterialX (material_file.as reads it).
    // It holds its place in the cache while its textures load, so that
    // loaded() lists it before them, as a scene is listed before what it
    // names (`inspect`'s files). It names textures only, so it cannot name
    // itself (no cycle to guard against, unlike scenes).
    private readMaterial(abs: string, display: string): Result<Resource> {
        this.put("Material", abs, new UnknownResource("Material"));
        const r = currentFileReaders().readMaterialFile(this, abs, display);
        if (!r.ok) this.forget("Material", abs);
        return r;
    }

    // An adapter over loadTexture for the models (model.as): a texture
    // that cannot be loaded is null, with the reason.
    textureSource(): TextureSource {
        return new LoaderTextures(this);
    }

    private readScene(abs: string, display: string, ext: string): Result<Resource> {
        if (ext == RSCNB_EXTENSION) return this.readBinaryScene(abs, display);
        if (ext != "rscn") {
            // A model file as a scene: its objects become nodes, from the
            // same ModelResource a Model ext_resource of the file gets.
            const m = this.loadModel(abs);
            if (!m.ok) return m.forward<Resource>();
            const p = new PackedScene();
            p.model = m.value;
            return Result.okv<Resource>(p);
        }
        const bytes = readFile(abs, display);
        if (!bytes.ok) return bytes.forward<Resource>();
        const parsed = parseRscn(bytes.value, display);
        if (!parsed.ok) return parsed.forward<Resource>();
        const doc = parsed.value;
        const found = validateRscn(doc);
        this.diagnostics.addAll(found);
        const first = found.firstError();
        if (first != null) return first.toError().fail<Resource>();
        const p = new PackedScene();
        p.doc = doc;
        return Result.okv<Resource>(p);
    }

    // Milestone 39: a binary scene (../rscnb/codec.as), validated as a
    // parsed .rscn is.
    private readBinaryScene(abs: string, display: string): Result<Resource> {
        const bytes = readFile(abs, display);
        if (!bytes.ok) return bytes.forward<Resource>();
        const decoded = decodeRscnb(bytes.value, display);
        if (!decoded.ok) return decoded.forward<Resource>();
        const doc = decoded.value;
        const found = validateRscn(doc);
        this.diagnostics.addAll(found);
        const first = found.firstError();
        if (first != null) return first.toError().fail<Resource>();
        const p = new PackedScene();
        p.doc = doc;
        return Result.okv<Resource>(p);
    }

    // A model file (model.as loadModelFile): an .rmdl, an .rmdlcmd, or a
    // .modeler, which loads with the warning that its format is retired
    // (milestone 21), first among the model's warnings, or a glTF file.
    private readModel(abs: string, display: string): Result<Resource> {
        const r = currentFileReaders().loadModelFile(abs, display, this.textureSource());
        if (!r.ok) return r.forward<Resource>();
        const m = r.value;
        if (extensionOf(abs) == RETIRED_MODEL_EXTENSION) {
            this.diagnostics.warning(MODEL_RETIRED_CODE, display, 0, 0, retiredModelMessage(display), MODEL_RETIRED_HINT);
        }
        this.modelWarnings(m, display);
        return Result.okv<Resource>(m);
    }

    private modelWarnings(m: ModelResource, display: string): void {
        // (an .rmdl's read warnings first: they are about the file as read)
        for (let i = 0; i < m.readWarnings.length; i++) this.diagnostics.add(m.readWarnings[i]);
        for (let i = 0; i < m.warnings.length; i++) {
            const w = m.warnings[i];
            // A texture the model names but that could not be loaded has a
            // code of its own (model.as words it "texture <path> of
            // material ..."); the rest are the model's other warnings.
            this.diagnostics.warning(w.startsWith("texture ") ? "texture-missing" : "model-warning", display, 0, 0, w);
        }
    }

    // Milestone 21: `source` (the tools' model of a Hedra scene,
    // milestone 40) as the model of the model file at `abs`, which is being
    // written from it, cached and with its warnings as if it had been read
    // from there, so that a scene naming the file instances without
    // reading it. A document (.rmdl) and the data form (.rmdlcmd) both
    // rebuild the scene byte for byte (engine/src/source/model/rmdl,
    // engine/src/source/model/rmdlcmd/data), so a later load of the file
    // gives the same model.
    adoptModel(abs: string, source: ModelSource): ModelResource {
        const display = this.displayPath(abs);
        const m = currentFileReaders().modelFromSource(source, ModelFormat.Modeler, dirOf(abs), this.textureSource());
        m.path = abs;
        m.file = display;
        this.modelWarnings(m, display);
        this.put("Model", abs, m);
        return m;
    }

    // Milestone 36: a sound (./audio_stream.as): the file's bytes, or none
    // when the text source answers that it is a Rive AudioAsset, handed to
    // the installed readers; a stream read from the text source in a Rive
    // project is the AudioAsset its place under the text root names.
    private readAudio(type: string, abs: string, display: string): Result<Resource> {
        const bytes = readFile(abs, display);
        if (!bytes.ok) return bytes.forward<Resource>();
        const held: Uint8Array? = isAudioDeclaredMark(bytes.value) ? null : bytes.value;
        const r = currentFileReaders().readAudioFile(abs, display, type, held);
        if (!r.ok) return r;
        const a = r.value as AudioStream;
        if (a.assetName.length == 0) a.assetName = audioAssetOfTextPath(abs);
        return r;
    }

    private readTexture(abs: string, display: string): Result<Resource> {
        const bytes = readFile(abs, display);
        if (!bytes.ok) return bytes.forward<Resource>();
        if (isHdrPath(abs)) {
            // A panorama (milestone 11): linear texels, no 8-bit image.
            const hdr = decodeHdr(bytes.value);
            if (!hdr.ok) {
                return SceneryError.at("texture-decode", display, 0, 0, display + " is not a Radiance HDR image: " + hdr.err,
                    HDR_DECODE_HINT).fail<Resource>();
            }
            const h = new Texture2D();
            h.hdr = hdr.value;
            h.width = <i32>hdr.value.width;
            h.height = <i32>hdr.value.height;
            return Result.okv<Resource>(h);
        }
        const img = Image.decodePng(bytes.value);
        if (!img.ok) {
            return SceneryError.at("texture-decode", display, 0, 0, display + " is not a PNG image: " + img.err, TEXTURE_DECODE_HINT).fail<Resource>();
        }
        const t = new Texture2D();
        t.image = img.value;
        t.width = <i32>img.value.width;
        t.height = <i32>img.value.height;
        return Result.okv<Resource>(t);
    }

    private readScript(abs: string, display: string): Result<Resource> {
        const text = vfs.readToString(abs);
        if (!text.ok) {
            return SceneryError.at("file-read", display, 0, 0, "cannot read " + display + ": " + text.err, FILE_READ_HINT).fail<Resource>();
        }
        const sc = new Script();
        sc.source = text.value;
        sc.scriptClass = scriptClassOf(text.value);
        if (sc.scriptClass == null) {
            this.diagnostics.warning("script-class-missing", display, 0, 0,
                display + " declares no class that extends NodeScript",
                "a node script holds one `class <Name> extends NodeScript`");
        }
        return Result.okv<Resource>(sc);
    }

    // .rscn: read, parsed and validated (the validator's warnings go to
    // `diagnostics`; its first error fails the load). .rmdl, .rmdlcmd,
    // .modeler, .gltf, .glb: the model behind it (loadModel).
    loadScene(abs: string): Result<PackedScene> {
        const r = this.load("PackedScene", abs);
        if (!r.ok) return r.forward<PackedScene>();
        return Result.okv<PackedScene>(r.value as PackedScene);
    }

    // An .rmdl, .rmdlcmd, .modeler, .gltf or .glb file as a model (model.as); its
    // warnings go to `diagnostics` once, when it is first loaded.
    loadModel(abs: string): Result<ModelResource> {
        const r = this.load("Model", abs);
        if (!r.ok) return r.forward<ModelResource>();
        return Result.okv<ModelResource>(r.value as ModelResource);
    }

    // A PNG or Radiance HDR file.
    loadTexture(abs: string): Result<Texture2D> {
        const r = this.load("Texture2D", abs);
        if (!r.ok) return r.forward<Texture2D>();
        return Result.okv<Texture2D>(r.value as Texture2D);
    }

    // Milestone 14: a material file's material (material_file.as), cached as
    // ("Material", abs) like every ext_resource.
    loadMaterial(abs: string): Result<StandardMaterial3D> {
        const r = this.load("Material", abs);
        if (!r.ok) return r.forward<StandardMaterial3D>();
        return Result.okv<StandardMaterial3D>(r.value as StandardMaterial3D);
    }

    // Milestone 61: a shader file (.wgsl), cached as ("Shader", abs) like
    // every ext_resource (a model's ShaderMaterial names it too).
    loadShader(abs: string): Result<Shader> {
        const r = this.load("Shader", abs);
        if (!r.ok) return r.forward<Shader>();
        return Result.okv<Shader>(r.value as Shader);
    }

    // An .as file, and the class in it that extends NodeScript.
    loadScript(abs: string): Result<Script> {
        const r = this.load("Script", abs);
        if (!r.ok) return r.forward<Script>();
        return Result.okv<Script>(r.value as Script);
    }
}

// A packed root scene is its own project (docs/formats/RSCN.md, "Packed
// scenes"): when `doc`, the root scene at `abs`, holds embedded files, the
// loader's project root becomes the scene's directory and the files are
// mounted there (mountEmbedded). Returns whether it did. Call it before
// anything the root names is resolved; loadSceneTree (../tree/instance.as)
// does, and so must any tool that looks at a root scene's files without
// loading it (`inspect --check`).
export function mountPackedScene(loader: ResourceLoader, abs: string, doc: RscnDoc): bool {
    const files = doc.embeddedFiles();
    if (files.length == 0) return false;
    loader.projectRoot = dirOf(abs);
    const own = loader.displayPath(abs);
    for (let i = 0; i < files.length; i++) {
        if (files[i].path != own) continue;
        const at = files[i].pos;
        loader.diagnostics.warning("embedded-ignored", own, at.line, at.col,
            "the embedded file " + own + " is this packed scene's own path: it is ignored",
            "remove it, or pack the scene under another name (`" + CLI + " build --pack -o <other>.rscn`)");
    }
    loader.mountEmbedded(doc, abs);
    return true;
}

// The lower-case extension of a path, without the dot ("" when none).
function extensionOf(abs: string): string {
    const slash = abs.lastIndexOf("/");
    const dot = abs.lastIndexOf(".");
    if (dot <= slash + 1) return "";
    return toAsciiLowercase(abs.substring(dot + 1));
}

// ".png", ".rmdl, .rmdlcmd, .modeler, .gltf or .glb".
function extensionList(exts: Array<string>): string {
    let s = "";
    for (let i = 0; i < exts.length; i++) {
        if (i > 0) s += i == exts.length - 1 ? " or " : ", ";
        s += "." + exts[i];
    }
    return s;
}

function readFile(abs: string, display: string): Result<Uint8Array> {
    const r = vfs.read(abs);
    if (!r.ok) return SceneryError.at("file-read", display, 0, 0, "cannot read " + display + ": " + r.err, FILE_READ_HINT).fail<Uint8Array>();
    return r;
}

function isWordChar(c: i32): bool {
    return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
}

function isSpace(c: i32): bool {
    return c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12;
}

// Where the run of spaces starting at `i` ends (i itself when there is
// none).
function skipSpaces(s: string, i: i32): i32 {
    while (i < s.length && isSpace(s.charCodeAt(i))) i++;
    return i;
}

// The name in the first `class <Name> extends NodeScript` of a script (the
// regular expression class\s+(\w+)\s+extends\s+NodeScript, matched by hand:
// there is no regex engine), or null. "class" and "NodeScript" must be
// whole words.
export function scriptClassOf(src: string): string? {
    let from = 0;
    while (true) {
        const at = src.indexOf("class", from);
        if (at < 0) return null;
        from = at + 1;
        if (at > 0 && isWordChar(src.charCodeAt(at - 1))) continue;
        let i = at + 5;
        let j = skipSpaces(src, i);
        if (j == i) continue;
        const nameStart = j;
        while (j < src.length && isWordChar(src.charCodeAt(j))) j++;
        if (j == nameStart) continue;
        const name = src.substring(nameStart, j);
        i = skipSpaces(src, j);
        if (i == j || !src.startsWith("extends", i)) continue;
        j = skipSpaces(src, i + 7);
        if (j == i + 7 || !src.startsWith("NodeScript", j)) continue;
        const end = j + 10;
        if (end < src.length && isWordChar(src.charCodeAt(end))) continue;
        return name;
    }
}

// A load error's message for where it is read without the error's file
// (a model's texture, an ext_resource's failure reported at the
// ext_resource): `ext-type-extension` leaves the file out of its message,
// since it is the error's file, so it is put back.
export function standaloneMessage(e: SceneryError): string {
    return e.code == "ext-type-extension" ? e.file + " " + e.message : e.message;
}

// ResourceLoader.textureSource: textures through the loader's cache.
class LoaderTextures extends TextureSource {
    loader: ResourceLoader;

    constructor(loader: ResourceLoader) {
        super();
        this.loader = loader;
    }

    texture(path: string): Texture2D? {
        const r = this.loader.loadTexture(path);
        if (r.ok) return r.value;
        const e = sceneryErrorOf<Texture2D>(r);
        this.why = e == null ? r.err : standaloneMessage(e);
        return null;
    }

    // A model's MaterialX material, loaded and cached as a Material
    // ext_resource of a scene is (its warnings the loader's).
    material(path: string): StandardMaterial3D? {
        const r = this.loader.loadMaterial(path);
        if (r.ok) return r.value;
        const e = sceneryErrorOf<StandardMaterial3D>(r);
        this.why = e == null ? r.err : standaloneMessage(e);
        return null;
    }

    // Milestone 61: a model's ShaderMaterial's shader, loaded and cached as a
    // Shader ext_resource of a scene is; one that cannot be read is null
    // with the reason (the model's warning: its material is drawn with its
    // own settings, RMDL.md section 5).
    shader(path: string): Shader? {
        const r = this.loader.loadShader(path);
        if (r.ok && r.value.unreadable.length > 0) {
            this.why = r.value.unreadable;
            return null;
        }
        if (r.ok) return r.value;
        const e = sceneryErrorOf<Shader>(r);
        this.why = e == null ? r.err : standaloneMessage(e);
        return null;
    }
}

// Milestone 61: the shader file at `path` (absolute) through a model's
// texture source (an .rmdl Material's `shader`, RMDL.md section 5): the
// loader's when the source is a loader's, else null with the reason in
// `src.why` (a source that reads no shader file says so). Kept here, beside
// the loader's source, so that model_hints.as's TextureSource stays as it
// is.
export function shaderThroughTextures(src: TextureSource, path: string): Shader? {
    const isLoader = src instanceof LoaderTextures;
    if (isLoader) return (src as LoaderTextures).shader(path);
    src.why = "no shader file is read here";
    return null;
}
