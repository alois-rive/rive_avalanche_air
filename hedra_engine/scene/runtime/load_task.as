// A scene loaded over several frames (milestone 67b,
// docs/engine/RESOURCES.md, "Loading"), Godot's interactive and threaded
// loading (ResourceLoader.load_threaded_request, _get_status with its
// progress, _get) on one thread: SceneRuntime.loadFrom cut into steps, each
// frame taking the steps that fit the project's
// loading/frame_budget_msec (resource_settings.as), the Scene3D drawing
// what it drew before (nothing, or the last scene's last picture) until the
// scene is ready, its view model's `progress` going from 0 to 1.
//
//   const task = new LoadTask(rt, files, "world/courtyard.rscn", options, ctx);
//   ... each advance: if (task.step(8)) { const got = task.result!; ... }
//   ... the tools and tests: const got = task.finish();
//
// The steps (`state`):
//
//   LOAD_READING     the built file read and checked (scene_runtime.as
//                    builtBundleFrom: one read, one CRC, the SRCS check,
//                    through KeptFiles, which keeps the bytes so that the
//                    load later checks the same object and parses it no
//                    more), the text's choice made as loadFrom makes it; a
//                    scene drawn from its text goes to INSTANCING
//   LOAD_DECODING    the built file's entries decoded, a few a step, into a
//                    BundleResources the runtime's next useBundle takes
//                    (SceneRuntime.preparedResources): in the order the
//                    decoders lean on each other (every texture, then the
//                    shaders, the materials, the models with their meshes,
//                    the scenes, the rest), each kind in the file's order,
//                    each entry asked as the scene's loader asks it (its
//                    path, display name and project root)
//   LOAD_INSTANCING  the tree made (SceneRuntime.loadFrom: every resource
//                    already decoded, so this is the tree alone)
//   LOAD_READY       `result` holds the SceneLoad loadFrom gave
//   LOAD_FAILED      `result` holds the failure
//
// The file holds the scene, every resource it reads and the scenes its
// scripts load by a literal path; all of them are decoded ahead, as
// Godot's preload() loads what a script names when the script loads.
//
// The budget is spent by estimate, not by the clock (`loadCostOf`: an
// entry's bytes times its kind's rate, plus a fixed cost an entry,
// measured once on the reference machine under rive's interpreter), so a
// load takes the same steps on every machine and every capture of a built
// project (`rive --screenshot` at a frame, the baked-and-run proofs) is the
// same; a step takes at least one entry, so a frame may run over by one
// entry's decode. The clock's figures are kept for the log and `--stats`
// (`worstStepMs`, `elapsedMs`), never read to decide. A budget of 0 (or
// less) in the first `step` is the load of before: SceneRuntime.loadFrom
// over the caller's files, nothing decoded ahead. A text load is one step
// (the text path is not cut: milestone 64's background loading cuts it).
//
// `progress()` is the estimate's share done: 0.02 once the file is read,
// up to 0.9 as the entries are decoded (each its estimate's share), 1 once
// the tree is made; it only rises.
//
// The foundation milestone 64 builds on: the decode step's entries are
// independent (each its own bytes in, one resource out, but for the
// order above, which a worker keeps by finishing a group before the next),
// so 64 hands them to rive's workers (background loading, the bytes sent
// as shared Blobs and uploaded from them: GPUBuffer.fromBlob) and keeps
// this order, the prepared resources and the steps' results; on the web
// runtime, which has no threads, this serial schedule stays.

import { Context } from "rive/host";
import { clock } from "rive/os";
import { scratch } from "../../base/scratch";
import { VfsReadFallback, vfs } from "../../fs/vfs";
import { FileSource, SceneLoad, SceneOptions, SceneSource, builtPathOf } from "./sources";
import { ProjectFiles, SceneRuntime, builtBundleFrom, builtRootSlot, projectOfScene, webTarget } from "./scene_runtime";
import { RegisteredProject } from "./projects";
import { ResourceSettings } from "./resource_settings";
import { Bundle } from "../bundle/read";
import { BundleResources, bundleLoader } from "../bundle/provider";
import { AssetKind, TextureFormat, TocEntry, bundleAbs } from "../bundle/format";
import { TextureChoice } from "../bundle/decode";
import { TEXTURE_KIND_COUNT, TEXTURE_KIND_SOURCE, TEXTURE_TABLE_ENTRY_BYTES } from "../bundle/payload";
import { ResourceLoader } from "../resource/loader";
import { Resource } from "../resource/types";
import { ResourceHolder } from "../resource/cache";
import { noteRscnbVerified, rememberVerifiedRscnb } from "../rscnb/codec";
import { RSCNB_HEADER_BYTES, looksLikeRscnb } from "../rscnb/format";
import { crcUpdate } from "../../render/png";
import { deviceFamilies } from "../../render/gpu/materials";

export const LOAD_READING: i32 = 0;
export const LOAD_DECODING: i32 = 1;
export const LOAD_INSTANCING: i32 = 2;
export const LOAD_READY: i32 = 3;
export const LOAD_FAILED: i32 = 4;

// The shares of `progress()` (see the header).
export const LOAD_PROGRESS_READ: f64 = 0.02;
export const LOAD_PROGRESS_INSTANCE: f64 = 0.1;

// What the files read of a load (FileSource), with the built file's bytes
// kept from the first read of them to the end of the load: the check in
// READING and loadFrom's in INSTANCING then read the same object
// (scene_runtime.as builtCheck parses it once), as BlobFiles, which wraps a
// new view of the blob at every read, would not; the scene's text is kept
// likewise (`textPath`), so that its checks hash one copy of it, not one
// a read (a blob read is a copy into the module's memory). `release` lets
// the bytes go (the load task does once the load is over): every read then
// passes through.
export class KeptFiles extends FileSource {
    inner: FileSource;
    // The paths whose bytes are kept ("" none), and them.
    keptPath: string;
    textPath: string = "";
    private kept: Uint8Array? = null;
    private readOnce: bool = false;
    private text: Uint8Array? = null;
    private textOnce: bool = false;

    constructor(inner: FileSource, keptPath: string) {
        super();
        this.inner = inner;
        this.keptPath = keptPath;
    }

    read(path: string): Uint8Array? {
        if (path.length == 0) return this.inner.read(path);
        if (path == this.keptPath) {
            if (!this.readOnce) {
                this.readOnce = true;
                this.kept = this.inner.read(path);
            }
            return this.kept;
        }
        if (path == this.textPath) {
            if (!this.textOnce) {
                this.textOnce = true;
                this.text = this.inner.read(path);
            }
            return this.text;
        }
        return this.inner.read(path);
    }

    hasAudio(path: string): bool {
        return this.inner.hasAudio(path);
    }

    // (the same files as `inner`: a read fallback over either is kept)
    sameAs(other: FileSource): bool {
        const me: FileSource = this;
        if (me === other) return true;
        const kept = other instanceof KeptFiles;
        if (kept) return this.inner.sameAs((other as KeptFiles).inner);
        return this.inner.sameAs(other);
    }

    release(): void {
        this.keptPath = "";
        this.kept = null;
        this.readOnce = false;
        this.textPath = "";
        this.text = null;
        this.textOnce = false;
    }
}

// One entry the decoding step decodes: the resource type its loader asks
// for, its path (as the scene's loader resolves it), and its estimate.
class LoadUnit {
    type: string;
    abs: string;
    cost: f64;

    constructor(type: string, abs: string, cost: f64) {
        this.type = type;
        this.abs = abs;
        this.cost = cost;
    }
}

export class LoadTask {
    rt: SceneRuntime;
    files: FileSource;
    path: string;
    options: SceneOptions;
    ctx: Context?;
    state: i32 = LOAD_READING;
    // The steps taken (the frames that loaded), and the longest one by the
    // clock (ms).
    steps: i32 = 0;
    worstStepMs: f64 = 0;
    // What the longest step did (the log's "(the tree)", "(decoding
    // textures/oak.png)"...): which part of a load overruns a frame.
    worstStepWhat: string = "";
    result: SceneLoad? = null;
    // The clock's time from the first step's start to
    // the end of the last (ms; the log's "in ... ms"), and the steps' own
    // time summed.
    elapsedMs: f64 = 0;
    stepsMs: f64 = 0;
    // What the files read through (`files` with the built file kept), the
    // project and its settings (READING), and the built file and the
    // resources decoded ahead (DECODING; null for a text load).
    kept: KeptFiles;
    project: RegisteredProject? = null;
    settings: ResourceSettings = new ResourceSettings();
    bundle: Bundle? = null;
    res: BundleResources? = null;
    // The estimate of every entry decoded ahead and of those done (ms), how
    // many were decoded and how many of those failed (the load then fails
    // on them as before), and the estimates of the reading and the tree.
    totalCost: f64 = 0;
    doneCost: f64 = 0;
    decodedAhead: i32 = 0;
    failedAhead: i32 = 0;
    readCost: f64 = 0;
    instanceCost: f64 = 0;
    // The scene's text's bytes (READING: what its checks hash).
    private textBytes: u64 = 0;
    // READING a large built file: its
    // whole-file CRC taken over several steps (`verify`), so that no frame
    // takes all of it (the chess sample's 12.9 MB file: about 290 ms);
    // `crcBytes` the file (null: not started, or done), `crcAt` the next
    // byte, `crc` the running value, `readStarted` whether the file was read.
    // (tests make it smaller: a fixture's files are small)
    crcSplitBytes: i32 = LOAD_CRC_SPLIT_BYTES;
    crcChunkBytes: i32 = LOAD_CRC_CHUNK_BYTES;
    // How many steps took a part of the CRC (tests).
    crcSteps: i32 = 0;
    private readStarted: bool = false;
    private crcBytes: Uint8Array? = null;
    private crcAt: i32 = 0;
    private crc: u32 = 0;
    // The entries to decode, in order, and the next.
    private units: Array<LoadUnit> = [];
    // What the decoding step decoded, and the load's own references to it
    // in the run time's cache (null without the cache): held from its
    // decoding, so that a load given up (`cancel`) or failed lets go of it,
    // and handed to the instance once it is made (see finishWith).
    private ahead: Array<Resource> = [];
    private holder: ResourceHolder? = null;
    // Whether the load was given up (`cancel`).
    cancelled: bool = false;
    // The read fallback `prepare` installed at the bundle's root, and the
    // one it replaced (put back by `cancel`).
    private fallbackRoot: string = "";
    private ourFallback: VfsReadFallback? = null;
    private priorFallback: VfsReadFallback? = null;
    private next: i32 = 0;
    // The loader whose paths and names the entries are asked by (the main
    // scene's: provider.as bundleLoader).
    private loader: ResourceLoader? = null;
    // Whether the load went the staged way (a first step with a budget),
    // and the clock at its first step (s).
    private staged: bool = false;
    private startedAt: f64 = 0;
    // The parts of the step under way (STEP_*) and its largest entry.
    private stepParts: i32 = 0;
    private stepLargest: LoadUnit? = null;

    constructor(rt: SceneRuntime, files: FileSource, path: string, options: SceneOptions, ctx: Context?) {
        this.rt = rt;
        this.files = files;
        this.path = path;
        this.options = options;
        this.ctx = ctx;
        this.kept = new KeptFiles(files, "");
    }

    // Takes the steps that fit `budgetMsec` (at least one; 0: all of them);
    // whether the load is done (READY or FAILED).
    step(budgetMsec: f64): bool {
        if (this.done()) return true;
        const t0 = clock();
        if (this.steps == 0) this.startedAt = t0;
        this.steps++;
        const whole = !(budgetMsec > 0);
        this.stepParts = 0;
        this.stepLargest = null;
        if (whole && !this.staged) {
            // (the load of before: one advance, the caller's files)
            this.finishWith(this.rt.loadFrom(this.files, this.path, this.options, this.ctx));
        } else {
            this.staged = true;
            this.runSteps(whole, budgetMsec);
        }
        const t1 = clock();
        const ms = (t1 - t0) * 1000;
        this.stepsMs += ms;
        if (ms > this.worstStepMs) {
            this.worstStepMs = ms;
            this.worstStepWhat = this.stepWhat();
        }
        this.elapsedMs = (t1 - this.startedAt) * 1000;
        return this.done();
    }

    // Every step left; the load's result.
    finish(): SceneLoad {
        while (!this.step(0)) {}
        return this.result!;
    }

    done(): bool {
        return this.state == LOAD_READY || this.state == LOAD_FAILED;
    }

    // How far the load is, 0 to 1 (the estimate's share done; 1 once done).
    progress(): f64 {
        if (this.done()) return 1;
        if (this.state == LOAD_READING) {
            // (a large file's CRC: its share of the reading's)
            const c = this.crcBytes;
            return c != null && c.length > 0 ? LOAD_PROGRESS_READ * <f64>this.crcAt / <f64>c.length : 0;
        }
        let p = LOAD_PROGRESS_READ;
        const decodeShare = 1 - LOAD_PROGRESS_READ - LOAD_PROGRESS_INSTANCE;
        if (this.state == LOAD_INSTANCING || !(this.totalCost > 0)) p += decodeShare;
        else p += decodeShare * min<f64>(1, this.doneCost / this.totalCost);
        return p;
    }

    // How many entries the decoding step decodes (tests, `--stats`).
    get unitCount(): i32 {
        return this.units.length;
    }

    // Whether the scene is drawn from its built form ("built") or its text
    // ("text"): the result's once done.
    formName(): string {
        const got = this.result;
        if (got != null) return got.source == SceneSource.Built ? "built" : "text";
        return this.bundle != null ? "built" : "text";
    }

    // The log line of a load done (scene3d.as writes it once): "hedra:
    // loaded world/study.rscn (built) in 412.3 ms over 31 frames, worst step
    // 14.0 ms (decoding textures/oak.png)", the worst step's parts named
    // (reading, the CRC, decoding with its largest entry, the tree); a load
    // of one step says its time alone.
    logLine(): string {
        const got = this.result;
        const shown = got != null && got.scenePath.length > 0 ? got.scenePath : this.path;
        let s = "hedra: " + (this.state == LOAD_FAILED ? "could not load " : "loaded ") + shown + " (" + this.formName() + ") in "
            + tenths(this.elapsedMs) + " ms";
        if (this.steps > 1) {
            s += " over " + this.steps.toString() + " frames, worst step " + tenths(this.worstStepMs) + " ms";
            if (this.worstStepWhat.length > 0) s += " (" + this.worstStepWhat + ")";
        }
        return s;
    }

    // What this step did, for worstStepWhat: its parts in order, the
    // decoding named by its largest entry (by the estimate).
    private stepWhat(): string {
        const parts = new Array<string>();
        const p = this.stepParts;
        if ((p & STEP_READ) != 0) parts.push("reading");
        if ((p & STEP_CRC) != 0) parts.push("the CRC");
        if ((p & STEP_DECODE) != 0) {
            const u = this.stepLargest;
            parts.push(u != null ? "decoding " + displayOfAbs(u.abs, this.bundle) : "decoding");
        }
        if ((p & STEP_TREE) != 0) parts.push("the tree");
        return parts.join(", ");
    }

    // The steps that fit (see the header): the reading, then entries while
    // their estimates fit what is left of the budget (the first of a step
    // always), then the tree when it fits too.
    private runSteps(whole: bool, budget: f64): void {
        let spent: f64 = 0;
        let took = false;
        while (!this.done()) {
            if (this.state == LOAD_READING) {
                if (this.crcBytes != null) {
                    // (a large file's CRC, a part a step: at least
                    // LOAD_CRC_CHUNK_BYTES, and what the budget left holds)
                    if (!whole && took && spent >= budget) return;
                    spent += this.verify(whole ? 0 : max<f64>(budget - spent, 1e-9));
                    this.stepParts |= STEP_CRC;
                    took = true;
                    continue;
                }
                this.stepParts |= STEP_READ;
                this.read();
                spent += this.readCost;
                continue;
            }
            if (this.state == LOAD_DECODING) {
                if (this.next >= this.units.length) {
                    this.state = LOAD_INSTANCING;
                    continue;
                }
                const u = unchecked(this.units[this.next]);
                if (!whole && took && spent + u.cost > budget) return;
                this.decode(u);
                this.stepParts |= STEP_DECODE;
                const big = this.stepLargest;
                if (big == null || u.cost > big.cost) this.stepLargest = u;
                this.next++;
                this.doneCost += u.cost;
                spent += u.cost;
                took = true;
                continue;
            }
            // (LOAD_INSTANCING)
            if (!whole && took && spent + this.instanceCost > budget) return;
            this.stepParts |= STEP_TREE;
            this.instance();
            return;
        }
    }

    // READING (see the header): the project, its settings, and the source
    // loadFrom would choose: a built file that is current (or the one asked
    // for) is decoded ahead; anything else goes to the tree at once, where
    // loadFrom says what it says of it today.
    private read(): void {
        const rt = this.rt;
        const project = projectOfScene(this.path, this.options.project);
        this.project = project;
        this.state = LOAD_INSTANCING;
        if (project == null) return;
        this.settings = project.resourceSettings(rt.webTag >= 0 ? rt.webTag == 1 : webTarget(this.ctx));
        const source = this.options.source;
        if (source == SceneSource.Text) return;
        const rivePath = riveScenePath(project, this.path);
        const builtPath = builtPathOf(rivePath);
        this.kept.keptPath = builtPath;
        this.kept.textPath = rivePath;
        if (!this.readStarted) {
            this.readStarted = true;
            // (a large built file: its CRC first, over the next steps; the
            // check below then finds it taken: ../rscnb/codec.as)
            const file = this.kept.read(builtPath);
            if (file != null && file.length > this.crcSplitBytes && looksLikeRscnb(file)) {
                this.crcBytes = file;
                this.crcAt = RSCNB_HEADER_BYTES;
                this.crc = 0xffffffff;
                this.readCost = 0;
                this.state = LOAD_READING;
                return;
            }
        }
        const b = builtBundleFrom(this.kept, this.path, this.options, this.rt);
        if (b == null) return;
        const bytes = this.kept.read(builtPath);
        // (the file parsed and its CRC checked, the text hashed once for
        // the check: loadFrom's check at the tree finds both in the
        // runtime's memo, scene_runtime.as BuiltCheckMemo)
        const text = this.kept.read(rivePath);
        this.textBytes = text != null ? <u64>text.length : 0;
        // (the CRC already taken by `verify` is not counted again)
        const crcd = this.crcAt > 0 ? 0 : (bytes != null ? <u64>bytes.length : 0);
        this.readCost = loadCostOf(LOAD_COST_READ, crcd) + loadCostOf(LOAD_COST_HASH, this.textBytes);
        // (Auto draws a stale file's text first, as loadFrom does)
        if (source == SceneSource.Auto && bytes != null && rt.checkMemo.stale()) return;
        // (a scene that uses a feature the module lacks: useBundle refuses it)
        if ((b.features & ~rt.installed()) != 0) return;
        this.bundle = b;
        this.prepare(b, project);
        this.state = LOAD_DECODING;
    }

    // A part of a large built file's CRC (see `crcBytes`): the bytes
    // `budget` holds by the estimate (all of them when 0), at least
    // LOAD_CRC_CHUNK_BYTES; once the last is taken, the file is said
    // verified when the CRC is its header's (when it is not, the check
    // takes it again and says the file is damaged, as before). The
    // estimate spent.
    private verify(budget: f64): f64 {
        const bytes = this.crcBytes!;
        const left = bytes.length - this.crcAt;
        let n = left;
        if (budget > 0) {
            const fits = <i32>min<f64>(<f64>left, budget / RATE_READ * 1048576.0);
            n = max<i32>(min<i32>(left, this.crcChunkBytes), fits);
        }
        this.crc = crcUpdate(this.crc, bytes, this.crcAt, this.crcAt + n);
        this.crcSteps++;
        this.crcAt += n;
        if (this.crcAt >= bytes.length) {
            const want = u32At(bytes, 20);
            if (~this.crc == want) {
                // (this runtime's load's: another runtime's load ending
                // does not forget it)
                rememberVerifiedRscnb(this.rt.checkMemo.scope);
                noteRscnbVerified(bytes, want);
            }
            this.crcBytes = null;
        }
        return loadCostOf(LOAD_COST_READ, <u64>n);
    }

    // The resources over `b` as useBundle makes them (its texture choice,
    // its first root, mounted, the hooks told), set for loadFrom's useBundle
    // to take, the scene's read fallback in place as loadFrom puts it, and
    // the entries planned.
    private prepare(b: Bundle, project: RegisteredProject): void {
        const rt = this.rt;
        const res = new BundleResources(b);
        let fam = rt.families;
        if (fam == null) {
            fam = deviceFamilies();
            rt.families = fam;
        }
        const choice = TextureChoice.forFamilies(fam);
        res.textureChoice = choice;
        res.firstRoot = builtRootSlot(project.name);
        // (mounted once: useBundle's mount() finds it done, so its error is
        // said here, as useBundle says it)
        const m = res.mount();
        if (!m.ok) rt.fail(m.err);
        // (what loadFrom installs before its tree reads, which it keeps: a
        // file the bundle lacks is read from the declared text then too)
        const fallback = new ProjectFiles(this.kept, project);
        this.fallbackRoot = b.root;
        this.priorFallback = vfs.readFallback(b.root);
        this.ourFallback = fallback;
        vfs.setReadFallback(b.root, fallback);
        // (the entries decoded ahead are keyed in the cache by their Rive
        // paths, as the one-step load's are: loadProject is not set yet)
        res.project = project.name;
        for (let i = 0; i < rt.hooks.length; i++) rt.hooks[i].bundleUsed(rt, res);
        rt.preparedResources = res;
        this.res = res;
        const main = b.scene(b.main);
        if (main == null) return;
        const mainEntry = b.find(AssetKind.Scene, main.path);
        this.instanceCost = loadCostOf(LOAD_COST_INSTANCE, mainEntry != null ? ownBytes(b, mainEntry) : 0);
        this.loader = bundleLoader(res, main);
        this.plan(b, choice);
    }

    // The entries (see the header's order), with their estimates and total.
    private plan(b: Bundle, choice: TextureChoice): void {
        const es = b.entries;
        // (a model's meshes are decoded with it: their estimate is its)
        const meshCost = new Map<string, f64>();
        for (let i = 0; i < es.length; i++) {
            const e = unchecked(es[i]);
            if (e.kind != <u32>AssetKind.Mesh) continue;
            const hash = e.name.lastIndexOf("#");
            if (hash <= 0) continue;
            const model = e.name.substring(0, hash);
            const c = loadCostOf(<u32>AssetKind.Mesh, e.size);
            meshCost.set(model, (meshCost.has(model) ? meshCost.get(model) : 0) + c);
        }
        for (let g = 0; g < UNIT_GROUPS.length; g++) {
            const kind = unchecked(UNIT_GROUPS[g]);
            for (let i = 0; i < es.length; i++) {
                const e = unchecked(es[i]);
                if (e.kind != kind) continue;
                let cost: f64;
                if (kind == <u32>AssetKind.Texture) cost = textureCost(b, e, choice);
                else cost = loadCostOf(kind, ownBytes(b, e));
                if (kind == <u32>AssetKind.Model && meshCost.has(e.name)) cost += meshCost.get(e.name);
                this.units.push(new LoadUnit(typeOfKind(kind), bundleAbs(e.name, b.root), cost));
                this.totalCost += cost;
            }
        }
    }

    // One entry asked of the prepared resources as the scene's loader asks
    // it (provider.as BundleResources.provide: decoded once and kept, so the
    // tree's loader finds it).
    private decode(u: LoadUnit): void {
        const res = this.res;
        const l = this.loader;
        if (res == null || l == null) return;
        const got = res.provide(u.type, u.abs, l.displayPath(u.abs), l.projectRoot);
        this.decodedAhead++;
        if (got == null || !got.ok) {
            this.failedAhead++;
            return;
        }
        const r = got!.value;
        this.ahead.push(r);
        // (held by the load from now: the cache adds what it decodes with
        // no reference, and nothing else holds it until the tree is made)
        const cache = res.cache;
        if (cache == null) return;
        const e = cache.entryOf(r);
        if (e == null || e.freed) return;
        let h = this.holder;
        if (h == null) {
            h = new ResourceHolder(cache);
            this.holder = h;
        }
        h.hold(e);
    }

    // Milestone 67b: gives the load up (the Scene3D asked for another
    // scene before this one was ready, or was disposed): the load's
    // references to what it decoded ahead let go of (each freed unless an
    // instance holds it too), the prepared resources and the built file's
    // bytes dropped, the files it mounted taken out and the read fallback
    // it installed replaced by the one before, the file's verified CRC
    // forgotten (../rscnb/codec.as). A load done is left as it is: its
    // instance, or its failure, holds what it holds. The task is then done
    // (FAILED, with no result).
    cancel(): void {
        if (this.done()) return;
        this.cancelled = true;
        this.state = LOAD_FAILED;
        const h = this.holder;
        this.holder = null;
        if (h != null) h.releaseAll();
        const p = this.rt.preparedResources;
        if (p != null && p === this.res) this.rt.preparedResources = null;
        const res = this.res;
        if (res != null) res.unmount();
        const ours = this.ourFallback;
        if (ours != null && vfs.readFallback(this.fallbackRoot) === ours) vfs.setReadFallback(this.fallbackRoot, this.priorFallback);
        this.ourFallback = null;
        this.priorFallback = null;
        this.kept.release();
        this.crcBytes = null;
        this.bundle = null;
        this.res = null;
        this.units.length = 0;
        this.ahead.length = 0;
        this.loader = null;
        this.rt.checkMemo.clear();
        scratch().trim();
    }

    // INSTANCING: loadFrom over the kept files (the same bytes, so the same
    // Bundle, so the prepared resources), then READY or FAILED.
    private instance(): void {
        const files: FileSource = this.staged ? this.kept : this.files;
        this.finishWith(this.rt.loadFrom(files, this.path, this.options, this.ctx));
    }

    private finishWith(got: SceneLoad): void {
        this.result = got;
        this.state = got.instance != null ? LOAD_READY : LOAD_FAILED;
        // (an entry decoded ahead that the tree never asked for, a scene a
        // script may load later among them, is held by the instance as
        // Godot's preload() holds what a script names, so that it is freed
        // with the instance rather than kept in the run time's cache with
        // no reference; a failed load lets go of all of it)
        this.holdAhead(got);
        // (prepared resources loadFrom did not take, a text load's: let go,
        // what they mounted taken out and the read fallback put back, as
        // `cancel` does; taken, the fallback is the scene's)
        const p = this.rt.preparedResources;
        if (p != null && p === this.res) this.rt.preparedResources = null;
        const res = this.res;
        if (res != null && this.rt.resources !== res) {
            res.unmount();
            const ours = this.ourFallback;
            if (ours != null && vfs.readFallback(this.fallbackRoot) === ours) vfs.setReadFallback(this.fallbackRoot, this.priorFallback);
        }
        this.ourFallback = null;
        this.priorFallback = null;
        this.kept.release();
        this.units.length = 0;
        this.ahead.length = 0;
        this.loader = null;
        // (what the load's decoders needed is not held while the scene
        // plays: ../../base/scratch.as)
        scratch().trim();
    }

    // What was decoded ahead, handed from the load's holder to the
    // instance's (the run time's: runtime_resources.as), each resource the
    // cache keeps once; with no instance (a failed load), let go of.
    private holdAhead(got: SceneLoad): void {
        const mine = this.holder;
        this.holder = null;
        if (mine == null) return;
        const inst = got.instance;
        const h = inst != null ? inst.tree.loader.holder : null;
        if (h != null) mine.moveTo(h);
        else mine.releaseAll();
    }
}

// The parts of a step (LoadTask.stepWhat).
const STEP_READ: i32 = 1;
const STEP_CRC: i32 = 2;
const STEP_DECODE: i32 = 4;
const STEP_TREE: i32 = 8;

// An entry's name in the log: its path in the bundle (`abs` less the
// bundle's root).
function displayOfAbs(abs: string, b: Bundle?): string {
    if (b != null && abs.startsWith(b.root + "/")) return abs.substring(b.root.length + 1);
    return abs;
}

// The kinds of the decoding step in their order (see the header).
const UNIT_GROUPS: StaticArray<u32> = [
    <u32>AssetKind.Texture, <u32>AssetKind.Shader, <u32>AssetKind.Material, <u32>AssetKind.Model, <u32>AssetKind.Scene,
    <u32>AssetKind.Lightmap, <u32>AssetKind.Probe, <u32>AssetKind.Rive, <u32>AssetKind.Script, <u32>AssetKind.Audio,
    <u32>AssetKind.Occluder,
];

// The type the scene's loader asks an entry of `kind` by
// (provider.as BundleResources.provide).
function typeOfKind(kind: u32): string {
    if (kind == <u32>AssetKind.Scene) return "PackedScene";
    if (kind == <u32>AssetKind.Model) return "Model";
    if (kind == <u32>AssetKind.Texture) return "Texture2D";
    if (kind == <u32>AssetKind.Material) return "Material";
    if (kind == <u32>AssetKind.Lightmap) return "LightmapGIData";
    if (kind == <u32>AssetKind.Probe) return "ReflectionProbeData";
    if (kind == <u32>AssetKind.Rive) return "RiveFile";
    if (kind == <u32>AssetKind.Script) return "Script";
    if (kind == <u32>AssetKind.Audio) return "AudioStream";
    if (kind == <u32>AssetKind.Occluder) return "ArrayOccluder3D";
    return "Shader";
}

// The scene's path in the Rive project (scene_runtime.as placeOf's).
function riveScenePath(project: RegisteredProject, scenePath: string): string {
    let rel = scenePath;
    if (rel.startsWith("res://")) rel = rel.substring(6);
    else if (project.name.length > 0 && rel.startsWith(project.name + "/")) rel = rel.substring(project.name.length + 1);
    if (rel.length == 0) rel = project.mainScene;
    return project.name.length > 0 ? project.name + "/" + rel : rel;
}

// A texture entry's estimate: the form the run time reads of it (the
// device's choice, decode.as TextureChoice): a PNG decoded, a KTX2 file
// read (its levels views of the bytes, or inflated), a Radiance HDR.
function textureCost(b: Bundle, e: TocEntry, choice: TextureChoice): f64 {
    const whole = loadCostOf(<u32>AssetKind.Texture, e.size);
    if (e.size < 8) return whole;
    // (the payload's header, read where it lies: its CRC is checked when
    // the entry is decoded)
    const v = b.bytes.subarray(<i32>e.offset, <i32>(e.offset + e.size));
    const format = u32At(v, 0);
    if (format == <u32>TextureFormat.Png) return loadCostOf(<u32>AssetKind.Texture, <u64>(v.length - 4));
    if (format == <u32>TextureFormat.Hdr) return loadCostOf(LOAD_COST_HDR, <u64>(v.length - 4));
    if (format != <u32>TextureFormat.Ktx2) return whole;
    const count = u32At(v, 4);
    if (count == 0 || count > TEXTURE_KIND_COUNT || 8 + <i32>count * TEXTURE_TABLE_ENTRY_BYTES > v.length) return whole;
    const kinds = new Array<u32>();
    for (let i = 0; i < <i32>count; i++) kinds.push(u32At(v, 8 + i * TEXTURE_TABLE_ENTRY_BYTES));
    const picked = choice.pick(kinds);
    let cost: f64 = 0;
    for (let p = 0; p < picked.length; p++) {
        const at = 8 + picked[p] * TEXTURE_TABLE_ENTRY_BYTES;
        const kind = u32At(v, at);
        const off = u32At(v, at + 4);
        const size = u32At(v, at + 8);
        if (kind == TEXTURE_KIND_SOURCE) {
            cost += loadCostOf(<u32>AssetKind.Texture, <u64>size);
            continue;
        }
        // (a KTX2 file's supercompressionScheme is its byte 44's u32)
        const zlib = size >= 48 && <u64>off + 48 <= <u64>v.length && u32At(v, <i32>off + 44) == 3;
        cost += loadCostOf(zlib ? LOAD_COST_KTX2_ZLIB : LOAD_COST_KTX2, <u64>size);
    }
    return cost > 0 ? cost : whole;
}

// An entry's own bytes: its size, but for a scene file's own scene, whose
// entry is the whole file (scene_file.as), the bytes before the first
// asset (its tables, and the asset records).
function ownBytes(b: Bundle, e: TocEntry): u64 {
    if (e.offset != 0 || e.size != <u64>b.bytes.length) return e.size;
    let first = e.size;
    const es = b.entries;
    for (let i = 0; i < es.length; i++) {
        const o = unchecked(es[i]);
        if (o !== e && o.size > 0 && o.offset < first) first = o.offset;
    }
    return first;
}

function u32At(b: Uint8Array, o: i32): u32 {
    return <u32>b[o] | (<u32>b[o + 1] << 8) | (<u32>b[o + 2] << 16) | (<u32>b[o + 3] << 24);
}

// "412.3" (one decimal).
function tenths(ms: f64): string {
    const t = <i64>Math.round(ms * 10);
    return (t / 10).toString() + "." + (t % 10).toString();
}

// The estimate's kinds beyond the bundle's (format.as AssetKind, by which
// a texture's PNG source and every other entry go): a texture's KTX2 form
// stored (its levels are views of the bytes) and deflated, a Radiance HDR
// image, the reading (the built file parsed and its CRC checked, by the
// file's bytes), the tree (by the main scene's own bytes) and a text
// hashed (SHA-256: the scene's text is compared with the file's SRCS).
export const LOAD_COST_KTX2: u32 = 100;
export const LOAD_COST_KTX2_ZLIB: u32 = 101;
export const LOAD_COST_HDR: u32 = 102;
export const LOAD_COST_READ: u32 = 103;
export const LOAD_COST_INSTANCE: u32 = 104;
export const LOAD_COST_HASH: u32 = 105;

// A built file larger than this has its CRC taken over several steps
// (LoadTask.verify), at least LOAD_CRC_CHUNK_BYTES a step: 1 MiB is about
// 22 ms of CRC by the estimate, 256 KiB about 5.5 ms.
export const LOAD_CRC_SPLIT_BYTES: i32 = 1048576;
export const LOAD_CRC_CHUNK_BYTES: i32 = 262144;

// The rates (ms per MiB) and the fixed costs of an entry (ms), measured by
// editor/program/tests/runtime/load_cost_bench_test.as (`unit-test.sh -v`
// prints them) under rive 1.8.0's `--test` interpreter on an Apple M5 Pro
// (48 GB), 2026-10-31, the best of five decodes of each entry as the
// decoding step asks it: the world fixtures' courtyard, spawn, bound and
// plain files and the materials, pbr, baked, reflections and sky samples
// built for bc (scenes 96 to 1,024 ms a MiB, 0.2 to 4.5 ms each; models
// with their meshes 78 to 162; materials 402, 0.2 ms each; textures' bc
// forms 0.44 ms each, small ones; a lightmap 62, a probe 22), three PNGs
// (226), a 256 x 256 rgba8 KTX2 with its chain stored (0.01: its levels
// are views) and deflated (83), a Radiance HDR (870), CRC-32 17, SHA-256
// 102, the tree 383 to 479. Each rate is taken a quarter or so higher, as
// a load's first decodes run colder than the best of five; a Rive file's
// info, a script's record, a sound's and an occluder's are read once, at
// the other rate. The estimate paces a load: it need not be exact, only
// the same on every machine.
const RATE_SCENE: f64 = 800;
const RATE_MATERIAL: f64 = 450;
const RATE_MODEL: f64 = 190;
const RATE_MESH: f64 = 190;
const RATE_PNG: f64 = 280;
const RATE_KTX2: f64 = 1;
const RATE_KTX2_ZLIB: f64 = 110;
const RATE_HDR: f64 = 1100;
const RATE_LIGHTMAP: f64 = 80;
const RATE_PROBE: f64 = 30;
const RATE_OTHER: f64 = 150;
const RATE_READ: f64 = 22;
const RATE_HASH: f64 = 125;
const RATE_INSTANCE: f64 = 600;
const FIXED_ENTRY: f64 = 0.02;
const FIXED_SCENE: f64 = 0.3;
const FIXED_MATERIAL: f64 = 0.2;
const FIXED_MODEL: f64 = 0.1;
const FIXED_TEXTURE: f64 = 0.4;
const FIXED_READ: f64 = 0.2;
const FIXED_INSTANCE: f64 = 0.5;

// The estimated milliseconds of decoding an entry of `kind`
// (../bundle/format.as AssetKind, or one of the LOAD_COST_* above) of
// `bytes` bytes (see the header): its kind's rate, plus its fixed cost.
export function loadCostOf(kind: u32, bytes: u64): f64 {
    const mib = <f64>bytes / 1048576.0;
    let rate: f64 = RATE_OTHER;
    let fixed: f64 = FIXED_ENTRY;
    if (kind == <u32>AssetKind.Scene) {
        rate = RATE_SCENE;
        fixed = FIXED_SCENE;
    } else if (kind == <u32>AssetKind.Material) {
        rate = RATE_MATERIAL;
        fixed = FIXED_MATERIAL;
    } else if (kind == <u32>AssetKind.Model) {
        rate = RATE_MODEL;
        fixed = FIXED_MODEL;
    } else if (kind == <u32>AssetKind.Mesh) {
        rate = RATE_MESH;
    } else if (kind == <u32>AssetKind.Texture || kind == LOAD_COST_KTX2 || kind == LOAD_COST_KTX2_ZLIB || kind == LOAD_COST_HDR) {
        rate = kind == LOAD_COST_KTX2 ? RATE_KTX2 : kind == LOAD_COST_KTX2_ZLIB ? RATE_KTX2_ZLIB : kind == LOAD_COST_HDR ? RATE_HDR
            : RATE_PNG;
        fixed = FIXED_TEXTURE;
    } else if (kind == <u32>AssetKind.Lightmap) {
        rate = RATE_LIGHTMAP;
    } else if (kind == <u32>AssetKind.Probe) {
        rate = RATE_PROBE;
    } else if (kind == LOAD_COST_READ) {
        rate = RATE_READ;
        fixed = FIXED_READ;
    } else if (kind == LOAD_COST_HASH) {
        rate = RATE_HASH;
        fixed = 0;
    } else if (kind == LOAD_COST_INSTANCE) {
        rate = RATE_INSTANCE;
        fixed = FIXED_INSTANCE;
    }
    return fixed + rate * mib;
}
