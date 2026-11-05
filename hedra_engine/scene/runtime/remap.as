// Remaps (milestone 67b, docs/engine/RESOURCES.md, "Remaps"): which form of
// each resource a run time reads, Godot's .import remaps
// (res://.godot/imported) on Hedra's built forms. Loading X.rscn, a
// texture, a model or a material loads its built equivalent whenever one
// exists and is current, and its source only when the built form is
// missing or stale, the same rule for every resource kind and for a scene
// instanced or loaded from another:
//
//   - the root scene: its .rscnb when builtState says Current (sources.as,
//     scene_runtime.as loadFrom: unchanged), else its text;
//   - every resource a tree reads that its bundle does not hold (a scene
//     drawn from its text, a scene a script loads that the root's built
//     file lacks, a sub-scene of either): the project's remap index
//     (`build/hedra/<project>/remap.json`, which `hedra build` writes and
//     declares in hedra.built.rml beside the built scenes) names the built
//     files that carry it and the SHA-256 of the source it was built from;
//     it is read from the first of those files when the source is not
//     declared, or is and hashes to that SHA-256 (loading/verify_sources,
//     resource_settings.as, says which loads check); else from its source,
//     with the reason (REMAP_REASON_*), once in the log
//     (`Context.log`) and in the status's `"sources"`;
//   - a resource the index does not know is read from its source, as
//     before.
//
// So a scene edited since its build draws its unchanged textures and
// models from their built forms (and draws at all when export/
// embed_sources leaves their sources out of the Rive file), and a scene a
// script loads by a computed path draws from its own built file. A stale
// root is itself such a resource: its text is read "changed since the
// build", and says so like any other.
//
// The choice is made once per resource and path in a runtime (`RemapState`
// keeps it), and every resource's origin is its cache entry's
// (../resource/cache.as ResourceOrigin): `hedra inspect --resources` and
// `hedra check` print them (remapReport, the tools' view of the same
// choice over the files on disk).
//
// The engine reads the index; the compiler writes it
// (compiler/src/build/remap_write.as): the engine never writes a built
// form (docs/plans/HEDRA.md section 3.4).
//
// The index (JSON, schema 1, one entry a line, by path; docs/cli/BUILD.md,
// "The remap index"):
//
//   {
//     "schema": 1,
//     "major": 0,
//     "project": "world",
//     "scenes": [
//       {"scene": "world/courtyard.rscn", "built": "build/hedra/world/courtyard.rscnb", "text_sha256": "<hex>"}
//     ],
//     "resources": [
//       {"path": "world/textures/oak.png", "kind": "texture", "entry": "textures/oak.png", "built": ["build/hedra/world/courtyard.rscnb"], "sha256": "<hex>", "bytes": 48213, "import_sha256": "<hex or empty>"}
//     ]
//   }
//
// How a choice is made (RemapState.choose), once per kind and path:
//
//   1. no entry in the index: the source, no reason (nothing built holds
//      it: not a fallback);
//   2. the source declared (it is read, hashed and its bytes dropped, once
//      per runtime; its .import sidecar too) and its SHA-256 or its
//      sidecar's not the index's: the source, REMAP_REASON_CHANGED. Done
//      before the built files are opened, so that a changed resource never
//      costs a built file's read (the outcome is the plan's but for the
//      reason when no built file could be read either, which then says
//      the source changed);
//   3. the first of the entry's built files that is declared, reads as a
//      self-contained scene of this library's major and holds the entry,
//      the root's own first when its text is loaded (a stale root's built
//      file, read for its check already, holds what it names, so one file
//      is opened where several would be: RemapState.prefer), then the
//      ones this runtime opened already (in the index's path order), then
//      the others in that order: built, read from it; none:
//      the source, REMAP_REASON_OTHER_MAJOR when one was of another
//      major, else REMAP_REASON_UNREADABLE when one did not read (or did
//      not hold the entry), else REMAP_REASON_NOT_BUILT (declared nowhere).
//      A source not declared (the export case) is built when a file holds
//      it: nothing to compare.
//
// Each built file is opened once per runtime (its bytes read once, its
// BundleResources made with the device's texture choice, at its project's
// slot, mounted, and every hook told `bundleUsed`, so that the cache keeps
// what it decodes) and kept for the runtime's life, as the root's own.
//
// A built root's own entries come from its file without a check (it is
// current by its SRCS: Godot's exported game trusting its imports), unless
// the project sets `loading/verify_sources: always`: then each entry's
// source is hashed first and a changed one read from its source (the
// preview while editing a texture without `hedra build --watch`; every
// declared source read and hashed once per load). The textures a built
// model carries are its own and are not checked apart.
//
// A fallback is said once per path in the module: the line waits in its
// state until an instance with a Context advances (RemapHook.advanced),
// which writes it with Context.log; without a Context (the tests) nothing
// is written, and remapLogLines() lists what would have been.
//
// A runtime made with `new SceneRuntime()` (the tests, the tools) has no
// RemapHook and loads as before; nothing here runs in the tools but
// remapReport, which decodes nothing and tells no cache.

import { Context } from "rive/host";
import { Result, cmpStr, i64FitsI32, i64ToI32, stableSort } from "../../base/util";
import { JsonKind, JsonMap, JsonNumberKind, jsonQuote, parseJson } from "../../base/json";
import { sha256Hex } from "../../base/sha256";
import { HEDRA_ENGINE_MAJOR } from "../../version";
import { Resource } from "../resource/types";
import { ResourceProvider } from "../resource/provider";
import { ResourceLoader } from "../resource/loader";
import { ResourceForm, ResourceOrigin, runtimeResourceCache } from "../resource/cache";
import { Bundle } from "../bundle/read";
import { sceneFileBundle } from "../bundle/scene_file";
import { BundleResources } from "../bundle/provider";
import { AssetKind, bundleAbs } from "../bundle/format";
import { TextureChoice } from "../bundle/decode";
import { sceneProvenance } from "../rscnb/srcs";
import { deviceFamilies } from "../../render/gpu/materials";
import { FileSource, BUILT_DIR } from "./sources";
import { RegisteredProject, projectNamed } from "./projects";
import { RuntimeHook } from "./runtime_hooks";
import { SceneInstance, SceneRuntime, builtRootSlot } from "./scene_runtime";
import { rivePathOfAbs } from "./rive_paths";
import { VERIFY_SOURCES_ALWAYS } from "./resource_settings";

export const REMAP_FILE = "remap.json";
export const REMAP_SCHEMA: i32 = 1;

// The reasons a resource is read from its source although a built form is
// known (ResourceOrigin.reason, the status's "sources", the log, `hedra
// check`'s resource-source-fallback).
export const REMAP_REASON_CHANGED = "changed since the build";
export const REMAP_REASON_NOT_BUILT = "no built form";
export const REMAP_REASON_UNREADABLE = "built file unreadable";
export const REMAP_REASON_OTHER_MAJOR = "built for another major";

// The most paths the status's "sources" lists (then "...").
export const REMAP_STATUS_MAX: i32 = 32;

// The suffix of a source's import settings (source/import/sidecar.as
// importPathOf: "<asset>.import"; the run time does not import the source
// tier).
const SIDECAR_SUFFIX = ".import";

// Where `hedra build` writes a project's index in the Rive project
// ("world" -> "build/hedra/world/remap.json"; "" -> "build/hedra/remap.json").
export function remapPathOf(project: string): string {
    return project.length > 0 ? BUILT_DIR + project + "/" + REMAP_FILE : BUILT_DIR + REMAP_FILE;
}

export class RemapScene {
    // Its path in the Rive project, its built file, the SHA-256 (hex) of
    // the text it was built from.
    scene: string = "";
    built: string = "";
    textSha256: string = "";
}

export class RemapEntry {
    // The source's path in the Rive project ("world/textures/oak.png").
    path: string = "";
    // The bundle entry's kind (../bundle/format.as assetKindName: "texture",
    // "model", "material", "scene", "shader", "audio", "lightmap", "probe",
    // "rive", "occluder", "script") and name in each built file.
    kind: string = "";
    entry: string = "";
    // The built files that carry it (in path order).
    built: Array<string> = [];
    // The SHA-256 (hex) and size of the source the build read, and of its
    // .import settings ("" when it has none).
    sha256: string = "";
    bytes: i64 = 0;
    importSha256: string = "";
}

export class RemapIndex {
    schema: i32 = REMAP_SCHEMA;
    major: i32 = 0;
    project: string = "";
    scenes: Array<RemapScene> = [];
    resources: Array<RemapEntry> = [];
    // Why the index is empty though a file was read (a schema or a major
    // this library does not read: the log's line); "" otherwise.
    ignored: string = "";
    // `resources` by path (made on the first lookup: a project's index
    // holds a few hundred entries, each looked up once or twice a load).
    private byPath: Map<string, RemapEntry>? = null;

    scene(path: string): RemapScene? {
        for (let i = 0; i < this.scenes.length; i++) if (this.scenes[i].scene == path) return this.scenes[i];
        return null;
    }

    resource(path: string): RemapEntry? {
        let m = this.byPath;
        if (m == null) {
            const made = new Map<string, RemapEntry>();
            for (let i = 0; i < this.resources.length; i++) {
                if (!made.has(this.resources[i].path)) made.set(this.resources[i].path, this.resources[i]);
            }
            this.byPath = made;
            m = made;
        }
        return m.has(path) ? m.get(path) : null;
    }
}

// The index `text` holds (`file` names it in errors): schema 1 above. A
// schema other than REMAP_SCHEMA, or a major other than this library's, is
// an empty index whose `ignored` says why (every resource is then read from
// its source, as without an index); text that is not such an index fails.
export function parseRemapIndex(text: string, file: string): Result<RemapIndex> {
    const parsed = parseJson(text);
    if (!parsed.ok) return Result.fail<RemapIndex>(file + ": not a remap index: " + parsed.err);
    const root = parsed.value.asObject();
    if (root == null) return Result.fail<RemapIndex>(file + ": not a remap index: not a JSON object");
    const schema = intField(root, "schema");
    if (schema < 0) return Result.fail<RemapIndex>(file + ": not a remap index: no \"schema\"");
    const out = new RemapIndex();
    if (schema != <i64>REMAP_SCHEMA) {
        out.schema = i64ToI32(schema);
        out.ignored = file + " is schema " + schema.toString() + "; resources are read from their sources";
        return Result.okv<RemapIndex>(out);
    }
    const major = intField(root, "major");
    const project = strField(root, "project");
    const scenesValue = root.get("scenes");
    const scenes = scenesValue != null ? scenesValue.asArray() : null;
    const resourcesValue = root.get("resources");
    const resources = resourcesValue != null ? resourcesValue.asArray() : null;
    if (major < 0 || !i64FitsI32(major) || project == null || scenes == null || resources == null) {
        return Result.fail<RemapIndex>(file + ": not a remap index: a field is missing or of the wrong type");
    }
    out.major = <i32>major;
    out.project = project;
    if (out.major != HEDRA_ENGINE_MAJOR) {
        out.ignored = file + " is for Hedra " + major.toString() + ".x (this library is " + HEDRA_ENGINE_MAJOR.toString()
            + ".x); resources are read from their sources";
        return Result.okv<RemapIndex>(out);
    }
    for (let i = 0; i < scenes.length; i++) {
        const o = scenes[i].asObject();
        const s = o != null ? remapSceneOf(o) : null;
        if (s == null) return Result.fail<RemapIndex>(file + ": not a remap index: scene " + i.toString() + " is malformed");
        out.scenes.push(s);
    }
    for (let i = 0; i < resources.length; i++) {
        const o = resources[i].asObject();
        const e = o != null ? remapEntryOf(o) : null;
        if (e == null) return Result.fail<RemapIndex>(file + ": not a remap index: resource " + i.toString() + " is malformed");
        out.resources.push(e);
    }
    return Result.okv<RemapIndex>(out);
}

function remapSceneOf(o: JsonMap): RemapScene? {
    const scene = strField(o, "scene");
    const built = strField(o, "built");
    const text = strField(o, "text_sha256");
    if (scene == null || built == null || text == null) return null;
    const s = new RemapScene();
    s.scene = scene;
    s.built = built;
    s.textSha256 = text;
    return s;
}

function remapEntryOf(o: JsonMap): RemapEntry? {
    const path = strField(o, "path");
    const kind = strField(o, "kind");
    const entry = strField(o, "entry");
    const builtValue = o.get("built");
    const built = builtValue != null ? builtValue.asArray() : null;
    const sha = strField(o, "sha256");
    const bytes = intField(o, "bytes");
    const imp = strField(o, "import_sha256");
    if (path == null || kind == null || entry == null || built == null || sha == null || bytes < 0 || imp == null) return null;
    const e = new RemapEntry();
    e.path = path;
    e.kind = kind;
    e.entry = entry;
    e.sha256 = sha;
    e.bytes = bytes;
    e.importSha256 = imp;
    for (let i = 0; i < built.length; i++) {
        const b = built[i].asStr();
        if (b == null) return null;
        e.built.push(b);
    }
    return e;
}

// The string at `key`, or null.
function strField(o: JsonMap, key: string): string? {
    const v = o.get(key);
    return v != null && v.kind == JsonKind.String ? v.str : null;
}

// The non-negative integer at `key` (up to i64's), or -1.
function intField(o: JsonMap, key: string): i64 {
    const v = o.get(key);
    if (v == null || v.kind != JsonKind.Number || v.numKind != JsonNumberKind.PosInt) return -1;
    return v.u > <u64>i64.MAX_VALUE ? -1 : <i64>v.u;
}

// The ext_resource type a run time asks an index kind as (the tools'
// report: remapReport), "" for a kind that is not a resource of its own.
export function remapTypeOfKind(kind: string): string {
    if (kind == "texture") return "Texture2D";
    if (kind == "model") return "Model";
    if (kind == "material") return "Material";
    if (kind == "scene") return "PackedScene";
    if (kind == "shader") return "Shader";
    if (kind == "lightmap") return "LightmapGIData";
    if (kind == "probe") return "ReflectionProbeData";
    if (kind == "rive") return "RiveFile";
    if (kind == "occluder") return "ArrayOccluder3D";
    if (kind == "script") return "Script";
    return "";
}

// The AssetKind of an index kind name (assetKindName's inverse), -1 for
// one that is not a resource of its own.
function assetKindOfName(name: string): i32 {
    if (name == "scene") return <i32>AssetKind.Scene;
    if (name == "material") return <i32>AssetKind.Material;
    if (name == "model") return <i32>AssetKind.Model;
    if (name == "texture") return <i32>AssetKind.Texture;
    if (name == "lightmap") return <i32>AssetKind.Lightmap;
    if (name == "probe") return <i32>AssetKind.Probe;
    if (name == "rive") return <i32>AssetKind.Rive;
    if (name == "script") return <i32>AssetKind.Script;
    if (name == "occluder") return <i32>AssetKind.Occluder;
    if (name == "shader") return <i32>AssetKind.Shader;
    return -1;
}

// What a remap chose for one resource.
export class RemapChoice {
    form: ResourceForm = ResourceForm.Source;
    // The file read: "build/hedra/world/courtyard.rscnb#textures/oak.png",
    // or the source's path.
    from: string = "";
    reason: string = "";
    // Built: the built file and its entry ("" otherwise).
    file: string = "";
    entry: string = "";
}

// A built file a state opened (or could not).
class OpenedFile {
    file: string;
    bundle: Bundle? = null;
    res: BundleResources? = null;
    // "" when it reads; else the reason it gives a fallback.
    why: string = "";

    constructor(file: string) {
        this.file = file;
    }
}

// The log's lines said in this module (once each, whichever runtime
// chose: see the header), in the order said.
let saidLines: Array<string> = [];
let saidSet: Set<string> = new Set<string>();

// Every line the remaps said (the tests read it: without a Context
// nothing reaches a log).
export function remapLogLines(): Array<string> {
    return saidLines;
}

// Forgets the lines said (tests, which share one module).
export function resetRemapLog(): void {
    saidLines = [];
    saidSet = new Set<string>();
}

// One runtime's remaps for one Hedra project: the index (read once), the
// built files opened for their entries (each once), the sources hashed
// (each once), the choices made.
export class RemapState {
    files: FileSource;
    project: RegisteredProject;
    index: RemapIndex? = null;
    // The runtime whose built files these are (its hooks told of each one
    // opened, its device's families used); null for the tools' report,
    // which opens files only to see whether they read.
    rt: SceneRuntime? = null;
    // Whether a Built choice makes the file's resources (false: the
    // report's, which decodes nothing).
    decodes: bool = true;
    // Whether each choice is told to the run time's cache, and a fallback
    // said in the log (false: the tools').
    tellsCache: bool = true;
    // The paths read from their sources for a reason, sorted (the
    // status's "sources").
    fallbacks: Array<string> = [];
    // Lines waiting for a Context to be said on (RemapHook.advanced).
    pendingLog: Array<string> = [];
    // How many sources were read and hashed (tests).
    hashed: i32 = 0;
    private choices: Map<string, RemapChoice> = new Map<string, RemapChoice>();
    // By path: whether the declared source is the one the index's entry
    // was built from, or is not declared (1), or not (0); absent: not
    // looked at yet.
    private verdicts: Map<string, i32> = new Map<string, i32>();
    private opened: Map<string, OpenedFile> = new Map<string, OpenedFile>();
    private openOrder: Array<string> = [];
    // The built files tried first, in the order preferred (`prefer`).
    private preferred: Array<string> = [];
    private statusText: string = "";
    private statusCount: i32 = -1;

    constructor(files: FileSource, project: RegisteredProject) {
        this.files = files;
        this.project = project;
    }

    // Tries `file` (a built file, a path in the Rive project) before any
    // other for the choices made from now on: a root loaded from its text
    // prefers its own built file (RemapHook.loaderMade).
    prefer(file: string): void {
        if (file.length == 0 || this.preferred.includes(file)) return;
        this.preferred.push(file);
    }

    // The project's index, read and parsed once (an empty one when the
    // Rive project declares none, or one that does not read: said once).
    loadIndex(): RemapIndex {
        const have = this.index;
        if (have != null) return have;
        let ix = new RemapIndex();
        const path = remapPathOf(this.project.name);
        const bytes = this.files.read(path);
        if (bytes != null && bytes.length > 0) {
            const text = String.UTF8.decode(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
            const p = parseRemapIndex(text, path);
            if (!p.ok) {
                this.say(p.err + "; resources are read from their sources");
            } else {
                ix = p.value;
                if (ix.ignored.length > 0) this.say(ix.ignored);
            }
        }
        this.index = ix;
        return ix;
    }

    // Whether the project checks a built root's own entries against their
    // sources (loading/verify_sources: always).
    verifiesAll(): bool {
        return this.project.resourceSettings(false).verifySources == VERIFY_SOURCES_ALWAYS;
    }

    // The form `type` (an ext_resource type) at `path` (in the Rive
    // project) is read in, and from where (see the header). Made once per
    // type and path; told to the cache, and a fallback said, when made.
    choose(type: string, path: string): RemapChoice {
        const key = type + " " + path;
        if (this.choices.has(key)) return this.choices.get(key);
        const c = this.decide(path);
        this.choices.set(key, c);
        this.noted(type, path, c);
        return c;
    }

    // The choice made for `type` at `path`, or null (tests, tools).
    choiceOf(type: string, path: string): RemapChoice? {
        const key = type + " " + path;
        return this.choices.has(key) ? this.choices.get(key) : null;
    }

    // Whether the index knows `path` and its declared source (or sidecar)
    // is not the one the build read: the check `verify_sources: always`
    // makes of a built root's own entries. False when the source is not
    // declared or the index does not know it.
    changedSource(path: string): bool {
        const e = this.loadIndex().resource(path);
        if (e == null) return false;
        return this.verdict(e) == 0;
    }

    // A built root's entry read from its source because it changed (the
    // provider found it so with `changedSource`), noted as a choice is.
    sourceChanged(type: string, path: string): void {
        const key = type + " " + path;
        if (this.choices.has(key)) return;
        const c = new RemapChoice();
        c.from = path;
        c.reason = REMAP_REASON_CHANGED;
        this.choices.set(key, c);
        this.noted(type, path, c);
    }

    // The resource `type` at `path` as the choice says: from its built
    // file (Built), else null (the loader reads the source). `display` is
    // the asking loader's name for it (ResourceProvider.provide); a
    // material's res:// textures resolve in the built file's own root,
    // where its textures are.
    provideBuilt(type: string, path: string, display: string): Result<Resource>? {
        const c = this.choose(type, path);
        if (c.form != ResourceForm.Built || !this.decodes) return null;
        if (!this.opened.has(c.file)) return null;
        const o = this.opened.get(c.file);
        const res = o.res;
        const b = o.bundle;
        if (res == null || b == null) return null;
        let root = bundleAbs("", b.root);
        const main = b.scene(b.main);
        if (main != null) root = main.rootAbs();
        return res.provide(type, bundleAbs(c.entry, b.root), display, root);
    }

    // Whether the scene `s` of the index would be drawn from its built file
    // (builtState Current: declared, of this major, and its declared text
    // the one built, or not declared).
    sceneCurrent(s: RemapScene): bool {
        const o = this.open(s.built);
        if (o.why.length > 0) return false;
        const text = this.files.read(s.scene);
        return text == null || sha256Hex(text) == s.textSha256;
    }

    // The status's member (",\"sources\":[...]", "" with no fallback),
    // made again only when a fallback was added.
    statusPart(): string {
        const n = this.fallbacks.length;
        if (n == 0) return "";
        if (n == this.statusCount) return this.statusText;
        const shown = new Array<string>();
        for (let i = 0; i < n && i < REMAP_STATUS_MAX; i++) shown.push(jsonQuote(this.fallbacks[i]));
        if (n > REMAP_STATUS_MAX) shown.push(jsonQuote("..."));
        this.statusText = ",\"sources\":[" + shown.join(",") + "]";
        this.statusCount = n;
        return this.statusText;
    }

    // Says the pending lines on `ctx` (none left after).
    flushLog(ctx: Context): void {
        if (this.pendingLog.length == 0) return;
        for (let i = 0; i < this.pendingLog.length; i++) ctx.log(this.pendingLog[i]);
        this.pendingLog.length = 0;
    }

    // The built files opened, in the order opened (tests).
    openedFiles(): Array<string> {
        return this.openOrder;
    }

    // The choice for `path` (any type), without the cache or the log.
    private decide(path: string): RemapChoice {
        const c = new RemapChoice();
        c.from = path;
        const e = this.loadIndex().resource(path);
        if (e == null) return c;
        if (this.verdict(e) == 0) {
            c.reason = REMAP_REASON_CHANGED;
            return c;
        }
        const kind = assetKindOfName(e.kind);
        let otherMajor = false;
        let unreadable = false;
        // (the preferred files first, in the order preferred; then those
        // this state opened, then the others, each in the index's path
        // order)
        for (let pass = 0; pass < 3; pass++) {
            const n = pass == 0 ? this.preferred.length : e.built.length;
            for (let i = 0; i < n; i++) {
                const f = pass == 0 ? this.preferred[i] : e.built[i];
                if (pass == 0) {
                    if (!e.built.includes(f)) continue;
                } else {
                    if (this.preferred.includes(f)) continue;
                    if ((pass == 1) != this.opened.has(f)) continue;
                }
                const o = this.open(f);
                if (o.why == REMAP_REASON_OTHER_MAJOR) otherMajor = true;
                else if (o.why == REMAP_REASON_UNREADABLE) unreadable = true;
                if (o.why.length > 0) continue;
                const b = o.bundle;
                if (b == null || kind < 0 || b.find(<AssetKind>kind, e.entry) == null) {
                    // (the index says the file holds it and it does not:
                    // the file is not the one indexed)
                    unreadable = true;
                    continue;
                }
                c.form = ResourceForm.Built;
                c.file = f;
                c.entry = e.entry;
                c.from = f + "#" + e.entry;
                return c;
            }
        }
        c.reason = otherMajor ? REMAP_REASON_OTHER_MAJOR : unreadable ? REMAP_REASON_UNREADABLE : REMAP_REASON_NOT_BUILT;
        return c;
    }

    // 1 when the declared source of `e` (and its sidecar) are the ones its
    // built files were made from, or the source is not declared; 0 when
    // they changed. Each source hashed once, its bytes dropped at once.
    private verdict(e: RemapEntry): i32 {
        if (this.verdicts.has(e.path)) return this.verdicts.get(e.path);
        let v = 1;
        const src = this.files.read(e.path);
        if (src != null) {
            // (a size that moved is a change without a hash: SHA-256 costs
            // about 90 ms a MiB under rive's interpreter, optimised, 175
            // without)
            if (<i64>src.length != e.bytes) {
                v = 0;
            } else {
                this.hashed++;
                if (sha256Hex(src) != e.sha256) v = 0;
            }
            if (v == 1) {
                const side = this.files.read(e.path + SIDECAR_SUFFIX);
                const sideSha = side != null ? sha256Hex(side) : "";
                if (sideSha != e.importSha256) v = 0;
            }
        }
        this.verdicts.set(e.path, v);
        return v;
    }

    // The built file `file`, opened once (see the header).
    private open(file: string): OpenedFile {
        if (this.opened.has(file)) return this.opened.get(file);
        const o = new OpenedFile(file);
        this.opened.set(file, o);
        this.openOrder.push(file);
        // (the runtime's own built root: the same file, made already)
        const rt = this.rt;
        if (rt != null) {
            const own = rt.resources;
            if (own != null && own.bundle.file == file) {
                o.bundle = own.bundle;
                o.res = own;
                return o;
            }
        }
        const bytes = this.files.read(file);
        if (bytes == null || bytes.length == 0) {
            o.why = REMAP_REASON_NOT_BUILT;
            return o;
        }
        const prov = sceneProvenance(bytes, file);
        if (!prov.ok) {
            o.why = REMAP_REASON_UNREADABLE;
            return o;
        }
        const p = prov.value;
        if (p != null && p.major != HEDRA_ENGINE_MAJOR) {
            o.why = REMAP_REASON_OTHER_MAJOR;
            return o;
        }
        const b = sceneFileBundle(bytes, file);
        if (!b.ok) {
            o.why = REMAP_REASON_UNREADABLE;
            return o;
        }
        o.bundle = b.value;
        if (!this.decodes || rt == null) return o;
        const res = new BundleResources(b.value);
        // (the device's choice, as useBundle makes it: the runtime's
        // status keeps its own "textures")
        let fam = rt.families;
        if (fam == null) {
            fam = deviceFamilies();
            rt.families = fam;
        }
        res.textureChoice = TextureChoice.forFamilies(fam);
        res.firstRoot = builtRootSlot(this.project.name);
        // (a damaged file entry is left unmounted: only what reads it fails)
        res.mount();
        o.res = res;
        // (every hook told, as useBundle tells them, the load's project and
        // files said for the time of the call: a script's load() opens a
        // file outside loadFrom)
        const project = rt.loadProject;
        const files = rt.loadFiles;
        rt.loadProject = this.project.name;
        rt.loadFiles = this.files;
        res.project = this.project.name;
        for (let i = 0; i < rt.hooks.length; i++) rt.hooks[i].bundleUsed(rt, res);
        rt.loadProject = project;
        rt.loadFiles = files;
        return o;
    }

    // `c` made for `type` at `path`: told to the cache, a fallback listed
    // and said.
    private noted(type: string, path: string, c: RemapChoice): void {
        if (this.tellsCache) {
            const o = new ResourceOrigin();
            o.form = c.form;
            o.from = c.from;
            o.reason = c.reason;
            runtimeResourceCache().noteOrigin(type, path, o);
        }
        if (c.form == ResourceForm.Built || c.reason.length == 0) return;
        if (!this.fallbacks.includes(path)) {
            this.fallbacks.push(path);
            stableSort<string>(this.fallbacks, cmpStr);
        }
        this.say(path + " read from its source (" + c.reason + ")");
    }

    // A line for the log, once per module: kept until an instance's
    // Context says it (see the header).
    private say(text: string): void {
        if (!this.tellsCache) return;
        const line = "hedra: " + text;
        if (saidSet.has(line)) return;
        saidSet.add(line);
        saidLines.push(line);
        this.pendingLog.push(line);
    }
}

// The provider a tree's loader asks (installed by RemapHook.loaderMade):
// `inner` first (the tree's own bundle, when it reads one), then the built
// files the index names, else null (the loader reads the source).
export class RemapProvider extends ResourceProvider {
    state: RemapState;
    inner: ResourceProvider?;
    // Where the tree's own bundle is mounted ("" for a tree drawn from its
    // text): its absolute paths are mapped to paths in the Rive project
    // through it (rive_paths.as).
    bundleRoot: string = "";

    constructor(state: RemapState, inner: ResourceProvider?) {
        super();
        this.state = state;
        this.inner = inner;
    }

    provide(type: string, abs: string, display: string, root: string): Result<Resource>? {
        const st = this.state;
        const p = this.inner;
        if (p != null) {
            // (loading/verify_sources: always: a changed source wins over
            // the tree's own entry)
            if (st.verifiesAll()) {
                const path = rivePathOfAbs(abs, st.project.name, this.bundleRoot);
                if (path.length > 0 && st.changedSource(path)) {
                    st.sourceChanged(type, path);
                    return null;
                }
            }
            const got = p.provide(type, abs, display, root);
            if (got != null) return got;
        }
        const path = rivePathOfAbs(abs, st.project.name, this.bundleRoot);
        if (path.length == 0) return null;
        return st.provideBuilt(type, path, display);
    }
}

// The run time's remaps (see the header): each loader a load makes asks
// a RemapProvider over the tree's own provider; the states (one per Hedra
// project and files the runtime loads) are kept for the runtime's life.
export class RemapHook extends RuntimeHook {
    states: Array<RemapState> = [];
    // The state of the last load and the project root of its loader: a
    // loader made outside a load (an instance made again later) for that
    // root reads through it too.
    private lastState: RemapState? = null;
    private lastRoot: string = "";

    // The state for `files` and `project` (made on first use).
    stateFor(rt: SceneRuntime, files: FileSource, project: RegisteredProject): RemapState {
        for (let i = 0; i < this.states.length; i++) {
            const s = this.states[i];
            if (s.project === project && s.files.sameAs(files)) return s;
        }
        const s = new RemapState(files, project);
        s.rt = rt;
        this.states.push(s);
        return s;
    }

    loaderMade(rt: SceneRuntime, loader: ResourceLoader, res: BundleResources?): void {
        let state: RemapState? = null;
        const files = rt.loadFiles;
        if (files != null) {
            const project = projectNamed(rt.loadProject);
            if (project == null) return;
            state = this.stateFor(rt, files, project);
        } else if (loader.projectRoot == this.lastRoot) {
            state = this.lastState;
        }
        if (state == null) return;
        if (files != null) state.prefer(rt.loadRootBuilt);
        this.lastState = state;
        this.lastRoot = loader.projectRoot;
        const root = res != null ? res.bundle.root : "";
        const had = loader.provider;
        const ours = had != null && had instanceof RemapProvider;
        if (ours) {
            // (a loader kept from an earlier instance: it reads through the
            // remaps already)
            const rp = had as RemapProvider;
            rp.state = state;
            rp.bundleRoot = root;
            return;
        }
        const rp = new RemapProvider(state, had);
        rp.bundleRoot = root;
        loader.provider = rp;
    }

    // (allocates nothing unless a line waits for a Context)
    advanced(inst: SceneInstance): void {
        const ctx = inst.ctx;
        if (ctx == null) return;
        const st = stateOf(inst);
        if (st != null && st.pendingLog.length > 0) st.flushLog(ctx);
    }

    statusPart(inst: SceneInstance): string {
        const st = stateOf(inst);
        return st != null ? st.statusPart() : "";
    }

    statusMark(inst: SceneInstance): i64 {
        const st = stateOf(inst);
        return st != null ? <i64>st.fallbacks.length : 0;
    }
}

// The remaps' state of `inst`'s tree (its loader's RemapProvider), or null.
function stateOf(inst: SceneInstance): RemapState? {
    const p = inst.tree.loader.provider;
    if (p == null) return null;
    const ours = p instanceof RemapProvider;
    if (!ours) return null;
    return (p as RemapProvider).state;
}

// The remap hook of `rt`, or null (tests, tools).
export function remapHookOf(rt: SceneRuntime): RemapHook? {
    for (let i = 0; i < rt.hooks.length; i++) {
        const h = rt.hooks[i];
        const ours = h instanceof RemapHook;
        if (ours) return h as RemapHook;
    }
    return null;
}

// Adds the remaps to `rt` (newSceneRuntime does).
export function installRemaps(rt: SceneRuntime): void {
    rt.addHook(new RemapHook());
}

// One row of the tools' report: what a run would read for each resource of
// a project's scenes.
export class RemapRow {
    scene: string = "";
    path: string = "";
    kind: string = "";
    form: ResourceForm = ResourceForm.Source;
    from: string = "";
    reason: string = "";
    // Drawn from its built form although its source changed since the
    // build: a current built scene's own entry under verify_sources: text,
    // which a run time trusts as Godot's export trusts its imports (the
    // run shows the picture of the build). The tools hash every source to
    // say so (`hedra check`'s resource-built-stale); a run never does.
    stale: bool = false;
}

// The tools' view of the remaps (`hedra check`, `hedra inspect
// --resources`): for every scene of `project` the index lists (in its
// order: by scene) and every resource its built file carries (by path),
// what a run time reading `files` would read: a scene drawn from its built
// file reads its own entries from it (each checked against its source
// first when the project sets verify_sources: always), and a scene drawn
// from its text reads each through the remaps' choice. Nothing is decoded,
// nothing logged and no cache told; a project without an index gives no
// row. Every source a built scene carries is hashed against the index,
// whatever verify_sources says, so that a row a run would draw stale says
// so (RemapRow.stale): the tools can afford what a run's load cannot.
export function remapReport(files: FileSource, project: RegisteredProject): Array<RemapRow> {
    const out = new Array<RemapRow>();
    const st = new RemapState(files, project);
    st.decodes = false;
    st.tellsCache = false;
    const ix = st.loadIndex();
    const all = st.verifiesAll();
    for (let s = 0; s < ix.scenes.length; s++) {
        const sc = ix.scenes[s];
        const current = st.sceneCurrent(sc);
        for (let i = 0; i < ix.resources.length; i++) {
            const e = ix.resources[i];
            if (!e.built.includes(sc.built)) continue;
            const row = new RemapRow();
            row.scene = sc.scene;
            row.path = e.path;
            row.kind = e.kind;
            if (current) {
                const changed = st.changedSource(e.path);
                if (all && changed) {
                    row.from = e.path;
                    row.reason = REMAP_REASON_CHANGED;
                } else {
                    row.form = ResourceForm.Built;
                    row.from = sc.built + "#" + e.entry;
                    row.stale = changed;
                }
            } else {
                const c = st.choose(remapTypeOfKind(e.kind), e.path);
                row.form = c.form;
                row.from = c.from;
                row.reason = c.reason;
            }
            out.push(row);
        }
    }
    return out;
}
