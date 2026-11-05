// The run time's resources (milestone 67b, docs/engine/RESOURCES.md): the
// hook that puts every resource a SceneRuntime loads in the module's one
// cache (../resource/cache.as), holds each instance's references, frees
// what the last instance let go of, and installs the run time's CPU-copy
// policy (../resource/cpu_copy.as) with the project's
// memory/keep_cpu_copies (resource_settings.as).
//
// What it does at each point (runtime_hooks.as):
//
//   attached         the runtime shares the module's cache: its
//                    InstanceShare and its GPU texture share become the
//                    cache's (every Scene3D of a Rive file shares them),
//                    `freshLoaders` on (one loader, so one holder, per
//                    instance)
//   bundleUsed       the bundle's resources are kept in the cache
//                    (BundleResources.cache, keyed by their paths in the
//                    Rive project: BundleResources.project); the share is
//                    the cache's again (useBundle made a new one); the
//                    CPU-copy policy installed
//   loaderMade       the loader gets the holder of the instance to come
//                    (ResourceLoader.holder): every resource it hands out is
//                    held once; the paths its keys are made from; the
//                    policy installed. A loader whose tree never became an
//                    instance (it failed to load) lets go at the next
//   instanceMade     the instance takes that holder (counted on its
//                    loader: ResourceLoader.instances); its runtime's render
//                    cache is told of every resource freed from now on; the
//                    packed scenes' dependencies are taken (their
//                    documents' resources are resolved now)
//   instanceDisposed the holder lets go, and so do those of what its
//                    scripts loaded and instanced (loader.as
//                    releaseHolders): what no instance holds is freed.
//                    A loader two live instances were made with (a tree
//                    instanced with another instance's loader) holds for
//                    both: it lets go with the last (loader.as instances)
//   advanced         the dependencies of what a script loaded since taken
//                    (ResourceCache.settleAll), the CPU copies due released
//                    (../resource/cpu_copy.as),
//                    the CPU figures of what was uploaded taken again, and
//                    the GPU ledger's retired objects released (ledger.as
//                    flushRetired): nothing is allocated
//   statusPart       nothing: every status is as it was (the remaps say
//                    their fallbacks: remap.as)
//
// Freeing a resource (the cache's listener, `freed`, in this order): the
// instances' share forgets a packed scene (tree.as InstanceShare.forget);
// every texture share forgets a texture's image and forms (material.as
// TextureShare.forget: a binder asking again uploads again); every render
// cache told forgets what it kept for the resource and its meshes
// (../render/cache.as forgetResource, forgetMeshes); then the cache retires
// its GPU objects to the ledger (refunded at once, released at the next
// advance) and lets go of its dependencies.
//
// Charging: an upload (../../render/upload_events.as) is charged to the
// resource that owns what went up: a texture's image or forms (indexed when
// the Texture2D is added to the cache), a built model's prebuilt meshes
// (indexed when the model is added), a mesh a render cache built from a
// model's object or from a scene's primitive (found through the render
// caches when it goes up: meshOfGpu, then the model, or the scene whose
// document declares it). What no resource owns goes to the ledger's
// "(engine)" figures (ledger.as).
//
// The totals go to the Scene3D's own written property `resources`
// (scene3d.as, docs/cli/BUILD.md section 8), `resourcesText()` below,
// rewritten only when `resourcesMark()` changes, so that a project that does
// not bind it, and every status a test or a session compares, are as they
// were.

import { GPUTextureView } from "rive/gpu";
import { RuntimeHook } from "./runtime_hooks";
import { SceneInstance, SceneRuntime } from "./scene_runtime";
import { rivePathOfAbs } from "./rive_paths";
import { projectNamed } from "./projects";
import {
    CacheListener, CachedResource, ResourceCache, ResourceDeps, ResourceHolder, ResourcePaths, ResourceTotals,
    resetRuntimeResourceCache, resourceCpuBytes, runtimeResourceCache,
} from "../resource/cache";
import { ResourceLoader } from "../resource/loader";
import { BundleResources } from "../bundle/provider";
import { InstanceShare } from "../tree/tree";
import { ArrayMesh, Mesh, ModelResource, PackedScene, Resource, Texture2D } from "../resource/types";
import { SceneRenderCache } from "../render/cache";
import { installCpuCopies, releasePendingCpuCopies, resetCpuCopies } from "../resource/cpu_copy";
import { resetRemapLog } from "./remap";
import { Image } from "../../render/image";
import { GpuMesh } from "../../render/mesh";
import { CompressedImage } from "../../texture/format";
import { SharedTextures, TextureShare } from "../../render/material";
import { UploadListener, addUploadListener, removeUploadListener } from "../../render/upload_events";
import { GpuRelease, LEDGER_BUFFER, LEDGER_TEXTURE, gpuLedger, resetGpuLedger } from "../../render/gpu/ledger";
import { MeshBuffersRelease, meshBuffersRelease } from "../../render/gpu/mesh_cache";
import { fixedF64 } from "../../base/fmt";

// What one resource's uploads are charged by (see the header).
class OwnedObjects {
    images: Array<Image> = [];
    forms: Array<CompressedImage> = [];
    meshes: Array<GpuMesh> = [];
}

// A texture's GPU release as the ledger counts it: the bytes its upload
// charged, released through the backend that uploaded (null: a backend
// with nothing to release, a test's).
class TextureRelease extends GpuRelease {
    inner: GpuRelease?;
    n: i64;

    constructor(inner: GpuRelease?, n: i64) {
        super();
        this.inner = inner;
        this.n = n;
    }

    release(): void {
        const i = this.inner;
        if (i != null) i.release();
    }

    bytes(): i64 {
        return this.n;
    }

    kind(): i32 {
        return LEDGER_TEXTURE;
    }
}

// A packed scene's dependencies: its document's ext_resources, as the
// instances' share resolved them (not known until a tree of it was
// instanced).
class ShareDeps extends ResourceDeps {
    share: InstanceShare;

    constructor(share: InstanceShare) {
        super();
        this.share = share;
    }

    depsOf(r: Resource, out: Array<Resource>): bool {
        if (!(r instanceof PackedScene)) return true;
        const p = r as PackedScene;
        // (a model as a scene holds its model: the bundle and the loader
        // said so as they made it)
        if (p.doc == null) return true;
        if (!this.share.resources.has(p)) return false;
        const ext = this.share.resources.get(p).ext.values();
        for (let i = 0; i < ext.length; i++) out.push(ext[i]);
        return true;
    }
}

class RivePaths extends ResourcePaths {
    rivePath(abs: string, project: string, bundleRoot: string): string {
        return rivePathOfAbs(abs, project, bundleRoot);
    }
}

// The upload listener of one cache's run time.
class ResourceUploads extends UploadListener {
    res: RuntimeResources;

    constructor(res: RuntimeResources) {
        super();
        this.res = res;
    }

    textureUploaded(img: Image?, form: CompressedImage?, srgb: bool, bytes: i64): void {
        this.res.textureUploaded(img, form, srgb, bytes);
    }

    meshUploaded(mesh: GpuMesh, bytes: i64): void {
        this.res.meshUploaded(mesh, bytes);
    }
}

export class RuntimeResources extends CacheListener {
    cache: ResourceCache;
    // The module's shares (see the header): every runtime of the cache
    // instances with `instances` and binds through `textures`.
    instances: InstanceShare = new InstanceShare();
    textures: TextureShare<GPUTextureView> = new TextureShare<GPUTextureView>();
    // Every texture share a free is told of: `textures`, and any other a
    // program binds through (addTextureShare: a test's).
    private shares: Array<SharedTextures> = [];
    // The render caches of the runtimes with a live instance, and how many
    // each has.
    private renderCaches: Array<SceneRenderCache> = [];
    private renderUsers: Array<i32> = [];
    // What each upload is charged to (see the header).
    private imageOwner: Map<Image, CachedResource> = new Map<Image, CachedResource>();
    private formOwner: Map<CompressedImage, CachedResource> = new Map<CompressedImage, CachedResource>();
    private meshOwner: Map<GpuMesh, CachedResource> = new Map<GpuMesh, CachedResource>();
    private owned: Map<CachedResource, OwnedObjects> = new Map<CachedResource, OwnedObjects>();
    private meshReleases: Map<GpuMesh, MeshBuffersRelease> = new Map<GpuMesh, MeshBuffersRelease>();
    // Resources uploaded since the last frame: their CPU figures are taken
    // again once the copies due are released (`frame`).
    private dirty: Array<CachedResource> = [];
    uploads: ResourceUploads;
    // Whether a loaded project keeps its CPU copies (then every one is
    // kept: memory/keep_cpu_copies).
    keepCopies: bool = false;

    constructor(cache: ResourceCache) {
        super();
        this.cache = cache;
        this.shares.push(this.textures);
        this.uploads = new ResourceUploads(this);
    }

    // Also tells `s` of every texture freed (a share a program binds
    // through besides the module's: a test's).
    addTextureShare(s: SharedTextures): void {
        if (!this.shares.includes(s)) this.shares.push(s);
    }

    // How many render caches are told of a free (tests).
    get renderCacheCount(): i32 {
        return this.renderCaches.length;
    }

    useRenderCache(c: SceneRenderCache): void {
        const at = this.renderCaches.indexOf(c);
        if (at >= 0) {
            this.renderUsers[at]++;
            return;
        }
        this.renderCaches.push(c);
        this.renderUsers.push(1);
    }

    leaveRenderCache(c: SceneRenderCache): void {
        const at = this.renderCaches.indexOf(c);
        if (at < 0) return;
        this.renderUsers[at]--;
        if (this.renderUsers[at] > 0) return;
        this.renderCaches.splice(at, 1);
        this.renderUsers.splice(at, 1);
        this.retireMeshesOf(c);
    }

    // How many uploaded meshes are charged to resources (tests: a scene
    // switch leaves as many as before it).
    get chargedMeshCount(): i32 {
        return this.meshReleases.size;
    }

    // The meshes render cache `c` built and uploaded for resources that
    // stay loaded (a model's objects, a scene's primitives: every runtime's
    // cache builds its own, so a Scene3D's new runtime builds them again),
    // retired once no instance draws with `c`: taken off their resource's
    // charges and its GPU objects, refunded to the ledger and released at
    // the next advance, and forgotten by `c`. A built model's prebuilt
    // meshes are the resource's own, shared by every cache, and stay. So a
    // scene switch that keeps a resource loaded leaves its GPU figures as
    // they were, not one more copy of its meshes a switch.
    private retireMeshesOf(c: SceneRenderCache): void {
        if (this.meshReleases.size == 0) return;
        const meshes = this.meshReleases.keys();
        const gone = new Array<GpuMesh>();
        for (let i = 0; i < meshes.length; i++) {
            const g = meshes[i];
            const a = c.meshOfGpu(g);
            if (a == null) continue;
            const pre = a.prebuilt;
            if (pre != null && pre.gpu === g) continue;
            let other = false;
            for (let k = 0; k < this.renderCaches.length && !other; k++) other = this.renderCaches[k].meshOfGpu(g) != null;
            if (!other) gone.push(g);
        }
        if (gone.length == 0) return;
        const ledger = gpuLedger();
        for (let i = 0; i < gone.length; i++) {
            const g = gone[i];
            const rel = this.meshReleases.get(g);
            this.meshReleases.delete(g);
            if (this.meshOwner.has(g)) {
                const owner = this.meshOwner.get(g);
                this.meshOwner.delete(g);
                const r: GpuRelease = rel;
                const k = owner.gpu.indexOf(r);
                if (k >= 0) {
                    owner.gpu.splice(k, 1);
                    owner.gpuBytes -= rel.n;
                }
                if (this.owned.has(owner)) {
                    const ms = this.owned.get(owner).meshes;
                    const m = ms.indexOf(g);
                    if (m >= 0) ms.splice(m, 1);
                }
            }
            ledger.retire(rel);
        }
        c.forgetBuilt(gone);
    }

    private ownedOf(e: CachedResource): OwnedObjects {
        if (this.owned.has(e)) return this.owned.get(e);
        const o = new OwnedObjects();
        this.owned.set(e, o);
        return o;
    }

    // (the cache's listener) What `e`'s uploads will be charged to.
    added(e: CachedResource): void {
        const r = e.resource;
        if (r instanceof Texture2D) {
            const t = r as Texture2D;
            const img = t.image;
            const forms = t.compressed;
            if (img == null && (forms == null || forms.length == 0)) return;
            const o = this.ownedOf(e);
            if (img != null) {
                this.imageOwner.set(img, e);
                o.images.push(img);
            }
            if (forms != null) {
                for (let i = 0; i < forms.length; i++) {
                    this.formOwner.set(forms[i], e);
                    o.forms.push(forms[i]);
                }
            }
            return;
        }
        if (r instanceof ModelResource) {
            const m = r as ModelResource;
            for (let i = 0; i < m.objects.length; i++) {
                const mesh = m.objects[i].mesh;
                const pre = mesh != null ? mesh.prebuilt : null;
                if (pre == null || this.meshOwner.has(pre.gpu)) continue;
                this.meshOwner.set(pre.gpu, e);
                this.ownedOf(e).meshes.push(pre.gpu);
            }
        }
    }

    // (the cache's listener) See the header.
    freed(e: CachedResource): void {
        const r = e.resource;
        if (r instanceof PackedScene) this.instances.forget(r as PackedScene);
        if (r instanceof Texture2D) {
            const t = r as Texture2D;
            const img = t.image;
            const forms = t.compressed;
            for (let s = 0; s < this.shares.length; s++) {
                const share = this.shares[s];
                if (img != null) share.forget(img, null);
                if (forms != null) for (let i = 0; i < forms.length; i++) share.forget(null, forms[i]);
            }
            // (a copy released after its upload now has neither its bytes
            // nor its upload: no render cache takes it in again, and a tree
            // that still names the texture draws it read again from its
            // source, as Godot's load() after the last Ref went reads the
            // file again: Image.freed)
            if (img != null && img.released) img.freed = true;
            if (forms != null) for (let i = 0; i < forms.length; i++) if (forms[i].released) forms[i].freed = true;
        }
        const o: OwnedObjects? = this.owned.has(e) ? this.owned.get(e) : null;
        const meshes = o != null ? o.meshes : NO_MESHES;
        for (let i = 0; i < this.renderCaches.length; i++) {
            const c = this.renderCaches[i];
            c.forgetResource(r);
            c.forgetMeshes(meshes);
        }
        if (o != null) {
            for (let i = 0; i < o.images.length; i++) if (this.imageOwner.has(o.images[i])) this.imageOwner.delete(o.images[i]);
            for (let i = 0; i < o.forms.length; i++) if (this.formOwner.has(o.forms[i])) this.formOwner.delete(o.forms[i]);
            for (let i = 0; i < o.meshes.length; i++) {
                const g = o.meshes[i];
                if (this.meshOwner.has(g)) this.meshOwner.delete(g);
                if (this.meshReleases.has(g)) this.meshReleases.delete(g);
            }
            this.owned.delete(e);
        }
        const d = this.dirty.indexOf(e);
        if (d >= 0) this.dirty.splice(d, 1);
    }

    // The release a share recorded for the upload of `img` or `form`.
    private releaseOf(img: Image?, form: CompressedImage?, srgb: bool): GpuRelease? {
        for (let s = 0; s < this.shares.length; s++) {
            const share = this.shares[s];
            if (img != null) {
                const r = share.releaseFor(img, null, srgb);
                if (r != null) return r;
            }
            if (form != null) {
                const r = share.releaseFor(null, form, srgb);
                if (r != null) return r;
            }
        }
        return null;
    }

    textureUploaded(img: Image?, form: CompressedImage?, srgb: bool, bytes: i64): void {
        let owner: CachedResource? = null;
        if (form != null && this.formOwner.has(form)) owner = this.formOwner.get(form);
        if (owner == null && img != null && this.imageOwner.has(img)) owner = this.imageOwner.get(img);
        const ledger = gpuLedger();
        if (owner == null || owner.freed) {
            ledger.chargeEngine(LEDGER_TEXTURE, bytes);
            return;
        }
        ledger.charge(LEDGER_TEXTURE, bytes);
        owner.addGpu(new TextureRelease(this.releaseOf(img, form, srgb), bytes));
        this.markDirty(owner);
    }

    meshUploaded(mesh: GpuMesh, bytes: i64): void {
        let owner: CachedResource? = this.meshOwner.has(mesh) ? this.meshOwner.get(mesh) : null;
        if (owner == null) {
            owner = this.meshOwnerOf(mesh);
            if (owner != null) {
                this.meshOwner.set(mesh, owner);
                this.ownedOf(owner).meshes.push(mesh);
            }
        }
        const ledger = gpuLedger();
        if (owner == null || owner.freed) {
            ledger.chargeEngine(LEDGER_BUFFER, bytes);
            return;
        }
        if (this.meshReleases.has(mesh)) {
            // (uploaded again in place of its first upload: the charge moves)
            const rel = this.meshReleases.get(mesh);
            ledger.recharge(LEDGER_BUFFER, rel.n, bytes);
            owner.gpuBytes += bytes - rel.n;
            rel.n = bytes;
        } else {
            const rel = meshBuffersRelease(mesh, bytes);
            ledger.charge(LEDGER_BUFFER, bytes);
            owner.addGpu(rel);
            this.meshReleases.set(mesh, rel);
        }
        this.markDirty(owner);
    }

    // The resource a mesh going up belongs to (see the header), or null.
    private meshOwnerOf(g: GpuMesh): CachedResource? {
        for (let i = 0; i < this.renderCaches.length; i++) {
            const a = this.renderCaches[i].meshOfGpu(g);
            if (a == null) continue;
            const src = a.source;
            if (src != null) return this.cache.entryOf(src.model);
            return this.sceneDeclaring(a);
        }
        return null;
    }

    // The cached scene whose document declares the mesh `a` (a primitive's
    // triangles: PrimitiveMesh.arrays), or null.
    private sceneDeclaring(a: ArrayMesh): CachedResource? {
        const scenes = this.instances.resources.keys();
        for (let i = 0; i < scenes.length; i++) {
            const subs = this.instances.resources.get(scenes[i]).sub.values();
            for (let k = 0; k < subs.length; k++) {
                const s = subs[k];
                if (s === a || (s instanceof Mesh && (s as Mesh).arrays() === a)) return this.cache.entryOf(scenes[i]);
            }
        }
        return null;
    }

    private markDirty(e: CachedResource): void {
        if (!this.dirty.includes(e)) this.dirty.push(e);
    }

    // The start of an instance's advance (see the header): allocates
    // nothing.
    frame(): void {
        // (the CPU copies an upload made redundant, released after the
        // frame that uploaded them drew: ../resource/cpu_copy.as)
        releasePendingCpuCopies();
        const n = this.dirty.length;
        if (n > 0) {
            for (let i = 0; i < n; i++) {
                const e = unchecked(this.dirty[i]);
                if (!e.freed) this.cache.setCpuBytes(e, resourceCpuBytes(e.resource));
            }
            this.dirty.length = 0;
        }
        gpuLedger().flushRetired();
    }
}

// The empty list of meshes a resource without uploads frees (read, never
// written).
const NO_MESHES: Array<GpuMesh> = [];

// One RuntimeResources per cache (the module's, and a test's own), made on
// first use, its listeners installed then (uninstallResourceCacheListeners
// takes them out). Null until then (a constant initial value: see
// ../resource/loader.as's readers).
let states: Array<RuntimeResources>? = null;

// The run time of `cache` (the module's when null), made and installed on
// first use.
export function runtimeResources(cache: ResourceCache? = null): RuntimeResources {
    const c = cache != null ? cache : runtimeResourceCache();
    let all = states;
    if (all == null) {
        all = new Array<RuntimeResources>();
        states = all;
    }
    for (let i = 0; i < all.length; i++) if (all[i].cache === c) return all[i];
    const r = new RuntimeResources(c);
    c.addListener(r);
    c.deps = new ShareDeps(r.instances);
    c.paths = new RivePaths();
    addUploadListener(r.uploads);
    all.push(r);
    return r;
}

// Takes every cache's run-time listeners out (tests: a suite that made a
// runtime with the hook, through newSceneRuntime or installResourceCache,
// ends with this, resetRuntimeResourceCache and resetGpuLedger, so that the
// suites after it see the tools' behaviour).
export function uninstallResourceCacheListeners(): void {
    const all = states;
    if (all == null) return;
    for (let i = 0; i < all.length; i++) {
        const r = all[i];
        removeUploadListener(r.uploads);
        r.cache.removeListener(r);
        r.cache.deps = null;
        r.cache.paths = null;
    }
    states = null;
}

// Every piece of the run time's module-wide resource state back to the
// tools' (tests: `rive --test` runs every suite of a closure in one module,
// so a suite that made a runtime with newSceneRuntime, a Scene3D or
// installResourceCache ends with this): the cache's listeners out, a new
// cache and GPU ledger, the tools' CPU-copy policy, the remaps' log lines
// said afresh.
export function resetRuntimeResources(): void {
    uninstallResourceCacheListeners();
    resetRuntimeResourceCache();
    resetGpuLedger();
    resetCpuCopies();
    resetRemapLog();
}

export class ResourceCacheHook extends RuntimeHook {
    cache: ResourceCache;
    res: RuntimeResources;
    // The loader made last, until an instance takes it (see the header).
    private unclaimed: ResourceLoader? = null;

    constructor(cache: ResourceCache) {
        super();
        this.cache = cache;
        this.res = runtimeResources(cache);
    }

    attached(rt: SceneRuntime): void {
        rt.freshLoaders = true;
        rt.share = this.res.instances;
        rt.gpuTextures = this.res.textures;
    }

    bundleUsed(rt: SceneRuntime, res: BundleResources): void {
        res.cache = this.cache;
        // (the remaps say the project of a built file they open themselves)
        if (res.project.length == 0) res.project = rt.loadProject;
        rt.share = this.res.instances;
        this.installPolicy(rt);
    }

    loaderMade(rt: SceneRuntime, loader: ResourceLoader, res: BundleResources?): void {
        rt.share = this.res.instances;
        this.dropUnclaimed(loader);
        if (loader.holder == null) loader.holder = new ResourceHolder(this.cache);
        loader.riveProject = rt.loadProject;
        loader.riveBundleRoot = res != null ? res.bundle.root : "";
        this.unclaimed = loader;
        this.installPolicy(rt);
    }

    instanceMade(rt: SceneRuntime, inst: SceneInstance): void {
        const l = inst.tree.loader;
        if (this.unclaimed === l) this.unclaimed = null;
        l.instances++;
        this.res.useRenderCache(rt.cache);
        this.cache.settleAll();
    }

    instanceDisposed(rt: SceneRuntime, inst: SceneInstance): void {
        // (a scene's dependencies taken first, so that it is freed before
        // what it names)
        this.cache.settleAll();
        // (a loader another live instance was made with too holds for that
        // one as well: what it loaded is let go of with the last of them,
        // as Godot frees a resource once no node holds it, never while
        // another instance still draws it)
        const l = inst.tree.loader;
        if (l.instances > 0) l.instances--;
        if (l.instances == 0) l.releaseHolders();
        this.res.leaveRenderCache(rt.cache);
    }

    advanced(inst: SceneInstance): void {
        // (a scene a script loaded and
        // instanced since takes its dependencies now, not at the next
        // instance made or disposed, so that the references the
        // `resources` property counts are the same whenever the load
        // happened; allocates nothing when none waits, nor for one whose
        // document was not instanced yet)
        this.cache.settleAll();
        this.res.frame();
    }

    // The last loader's holder, when its tree became no instance.
    private dropUnclaimed(next: ResourceLoader): void {
        const l = this.unclaimed;
        this.unclaimed = null;
        if (l == null || l === next) return;
        const h = l.holder;
        if (h != null) h.releaseAll();
    }

    // The CPU-copy policy of the project loading (kept when any loaded
    // project keeps its copies).
    private installPolicy(rt: SceneRuntime): void {
        const p = projectNamed(rt.loadProject);
        if (p != null && p.resourceSettings(rt.webTag == 1).keepCpuCopies) this.res.keepCopies = true;
        installCpuCopies(this.res.keepCopies);
    }
}

// Adds the resource cache to `rt` (newSceneRuntime does), the module's own
// unless `cache` is given (tests).
export function installResourceCache(rt: SceneRuntime, cache: ResourceCache? = null): ResourceCacheHook {
    const h = new ResourceCacheHook(cache != null ? cache : runtimeResourceCache());
    rt.addHook(h);
    return h;
}

// The totals of the module's cache (the editor's Monitors, `--stats`).
export function runtimeResourceTotals(out: ResourceTotals): ResourceTotals {
    return runtimeResourceCache().totals(out);
}

// resourcesMark's totals (kept: marking allocates nothing).
let markTotals: ResourceTotals? = null;

// The text the Scene3D writes to its `resources` property: the module's
// cache and GPU ledger as JSON, keys in this order:
// {"count":N,"refs":R,"cpu":B,"gpu":B,"textures":T,"buffers":U,"fallbacks":F}
// (count, refs, cpu, fallbacks: the cache's totals; gpu the ledger's bytes,
// textures and buffers its live objects).
export function resourcesText(): string {
    const t = runtimeResourceCache().totals(new ResourceTotals());
    const l = gpuLedger();
    return "{\"count\":" + t.count.toString() + ",\"refs\":" + t.refs.toString() + ",\"cpu\":" + t.cpuBytes.toString()
        + ",\"gpu\":" + l.totalBytes().toString() + ",\"textures\":" + l.textures.toString() + ",\"buffers\":"
        + l.buffers.toString() + ",\"fallbacks\":" + t.fallbacks.toString() + "}";
}

// resourcesText for a reader (the Scene3D's `resourceSummary`): "7
// resources, 15 references", then "CPU 42.2 KB, GPU 47.4 KB" (bytes in
// SI units: B, KB, MB, GB), then "2 read from source" when any resource is
// a fallback, a line each.
export function resourcesSummary(): string {
    const t = runtimeResourceCache().totals(new ResourceTotals());
    const l = gpuLedger();
    let s = t.count.toString() + (t.count == 1 ? " resource, " : " resources, ") + t.refs.toString()
        + (t.refs == 1 ? " reference" : " references") + "\nCPU " + siBytes(t.cpuBytes) + ", GPU " + siBytes(l.totalBytes());
    if (t.fallbacks > 0) s += "\n" + t.fallbacks.toString() + " read from source";
    return s;
}

// `n` bytes as "512 B", "42.2 KB", "14.1 MB" or "1.2 GB".
export function siBytes(n: i64): string {
    if (n < 1000) return n.toString() + " B";
    if (n < 1000000) return fixedF64(<f64>n / 1000, 1) + " KB";
    if (n < 1000000000) return fixedF64(<f64>n / 1000000, 1) + " MB";
    return fixedF64(<f64>n / 1000000000, 1) + " GB";
}

// A number that changes whenever resourcesText would (allocates nothing
// once its totals are made).
export function resourcesMark(): i64 {
    let t = markTotals;
    if (t == null) {
        t = new ResourceTotals();
        markTotals = t;
    }
    runtimeResourceCache().totals(t);
    const l = gpuLedger();
    let m: i64 = <i64>t.count;
    m = m * 1000003 + <i64>t.refs;
    m = m * 1000003 + t.cpuBytes;
    m = m * 1000003 + l.totalBytes();
    m = m * 1000003 + l.textures;
    m = m * 1000003 + l.buffers;
    m = m * 1000003 + <i64>t.fallbacks;
    return m;
}
