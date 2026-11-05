// The run time's one resource cache (milestone 67b,
// docs/engine/RESOURCES.md, "The cache"), Godot's ResourceCache with its
// Ref<Resource> counts: every resource a run time loads (a texture, a
// model and its meshes, a material, a packed scene, a shader, a sound
// stream, a lightmap, a probe, a Rive file, an occluder) is kept here by
// its resolved path and kind (and, where they change what is decoded, the
// form or the root: `cacheKeyOf`), so that loading the same path twice,
// from one scene or from two Scene3D views, gives the same object, and so
// one GPU upload of it.
//
// Lifetimes: each instance holds its references in a ResourceHolder (one
// reference per resource, however many nodes use it), taken as its tree's
// loader hands resources out (loader.as ResourceLoader.holder); when the
// instance is disposed, the holder lets go of them, and a resource whose
// last reference goes is freed: removed from the cache, its GPU objects
// retired to the GPU ledger (released one frame later,
// ../../render/gpu/ledger.as), and the listeners told (the renderers'
// caches drop what they kept for it). So instanced scenes share their
// resources, and a scene change frees what the old scene alone used once
// the new one holds its own (the Scene3D loads the new scene before it
// disposes the old: ../runtime/scene3d.as).
//
// Deterministic: the cache never frees on its own (no collector, no
// timer), only when a count reaches 0, in the order the counts do; the
// order `entries` lists is the order resources were first added.
//
// The tools do not use it: their loaders keep their own caches, one per
// run (loader.as), and every picture they make is unchanged. A run time
// made by newSceneRuntime() (Rive projects, Play) uses the module's one
// (`runtimeResourceCache`).
//
// Dependencies (Godot's Ref<Resource> members): a resource made from
// others keeps a reference to each (CachedResource.deps), so that it never
// outlives what it draws with. A model or a material takes the textures
// and materials loaded while it was made (the loader and the bundle tell
// the cache which: ResourceCache.addDep); a packed scene takes its
// ext_resources once its document's resources are resolved (`settle`,
// through the run time's ResourceDeps: the instances' share knows them),
// since a second instance of a scene reuses those resources without
// loading them again. A dependency is let go of after the resource that
// held it is freed.
//
// The hook that wires all this into a run time is
// ../runtime/runtime_resources.as.

import { ArrayMesh, ModelResource, PackedScene, Resource, Texture2D } from "./types";
import { GpuRelease, gpuLedger, imageUploadBytes } from "../../render/gpu/ledger";
import { GpuMesh } from "../../render/mesh";
import { LINE_INSTANCE_SIZE, POINT_INSTANCE_SIZE, SURFACE_VERTEX_SIZE } from "../../render/gpu/layouts";

// Where a resource came from (docs/engine/RESOURCES.md, "Remaps").
export enum ResourceForm {
    // Its source file, read and decoded at run time (a .png, a .glb, an
    // .mtlx, an .rscn).
    Source = 0,
    // A built scene's entry (an .rscnb's ASST: prebuilt meshes, the
    // texture's GPU forms).
    Built = 1,
    // The import cache (the tools: a texture's processed forms).
    Imported = 2,
    // Made in memory (a resource built in code, a model converted in the
    // editor).
    Memory = 3,
}

export const RESOURCE_FORM_NAMES: StaticArray<string> = ["source", "built", "imported", "memory"];

export function resourceFormName(f: ResourceForm): string {
    const i = <i32>f;
    return i >= 0 && i < RESOURCE_FORM_NAMES.length ? RESOURCE_FORM_NAMES[i] : "source";
}

export class ResourceOrigin {
    form: ResourceForm = ResourceForm.Source;
    // The file it was read from, in the Rive project ("world/textures/oak.png";
    // a built one's "build/hedra/world/courtyard.rscnb#textures/oak.png"), or
    // the absolute path in the tools.
    from: string = "";
    // Why its source was read although a built form exists (one of
    // ../runtime/remap.as REMAP_REASON_*; "" when it is not such a
    // fallback).
    reason: string = "";
}

export class CachedResource {
    key: string;
    // The resolved path: a path in the Rive project in a run time
    // ("world/textures/oak.png"), the absolute path in the tools.
    path: string;
    // The ext_resource type ("Texture2D", "Model", "Material",
    // "PackedScene", "Shader", "AudioStream", "LightmapGIData",
    // "ReflectionProbeData", "RiveFile", "ArrayOccluder3D", "Script").
    kind: string;
    resource: Resource;
    origin: ResourceOrigin = new ResourceOrigin();
    // The holders that hold it.
    refs: i32 = 0;
    // The bytes of its CPU side (pixels, compressed levels, vertex and
    // index arrays, a document) as resourceCpuBytes measures them, and of
    // its GPU side (what its uploads charged the ledger).
    cpuBytes: i64 = 0;
    gpuBytes: i64 = 0;
    // When it was added (the order `entries` lists).
    order: i32 = 0;
    // What freeing it releases on the GPU (each charged to `gpuBytes`).
    gpu: Array<GpuRelease> = [];
    freed: bool = false;
    // What it holds a reference to (see the header), each once.
    deps: Array<CachedResource> = [];
    // Whether its dependencies are known: true for every kind but a packed
    // scene, whose ext_resources are known once its document's resources
    // are resolved (ResourceCache.settle).
    depsSettled: bool = true;

    constructor(key: string, path: string, kind: string, resource: Resource) {
        this.key = key;
        this.path = path;
        this.kind = kind;
        this.resource = resource;
    }

    // Charges `r` to this resource: freed with it.
    addGpu(r: GpuRelease): void {
        this.gpu.push(r);
        this.gpuBytes += r.bytes();
    }
}

// Told when a resource is freed (the renderers' caches, the instances'
// share), before its GPU objects are retired; and when one is added (the
// run time's hook indexes what its uploads will be charged to).
export abstract class CacheListener {
    abstract freed(e: CachedResource): void;
    added(e: CachedResource): void {}
}

// What a resource the cache cannot see into holds (the run time's: a
// packed scene's ext_resources, from the instances' share). `depsOf` puts
// them in `out` and says true, or says false when they are not known yet
// (asked again later).
export abstract class ResourceDeps {
    abstract depsOf(r: Resource, out: Array<Resource>): bool;
}

// Where an absolute path a loader reads is in the Rive project (the run
// time's: ../runtime/rive_paths.as rivePathOfAbs, given to the cache so
// that the loader, below the run time, need not import it): "" outside.
export abstract class ResourcePaths {
    abstract rivePath(abs: string, project: string, bundleRoot: string): string;
}

export class ResourceTotals {
    count: i32 = 0;
    refs: i32 = 0;
    cpuBytes: i64 = 0;
    gpuBytes: i64 = 0;
    // How many came from their source while a built form exists (a
    // fallback: their origin's reason is not "").
    fallbacks: i32 = 0;

    reset(): void {
        this.count = 0;
        this.refs = 0;
        this.cpuBytes = 0;
        this.gpuBytes = 0;
        this.fallbacks = 0;
    }
}

// The key of a resource: its kind and resolved path, and `variant` where
// one path decodes to different objects (a texture's chosen GPU form, a
// material's project root): "Texture2D world/textures/oak.png@bc".
export function cacheKeyOf(kind: string, path: string, variant: string = ""): string {
    return variant.length > 0 ? kind + " " + path + "@" + variant : kind + " " + path;
}

export class ResourceCache {
    private byKey: Map<string, CachedResource> = new Map<string, CachedResource>();
    private byResource: Map<Resource, CachedResource> = new Map<Resource, CachedResource>();
    private live: Array<CachedResource> = [];
    private listeners: Array<CacheListener> = [];
    private added: i32 = 0;
    // Origins said before their resource was added (noteOrigin), by kind
    // and path.
    private pendingOrigins: Map<string, ResourceOrigin> = new Map<string, ResourceOrigin>();
    // How many resources were freed in all (tests).
    freedCount: i32 = 0;
    // The run time's (see ResourceDeps and ResourcePaths); null: a packed
    // scene's dependencies are not followed, and the loader keys by
    // absolute paths.
    deps: ResourceDeps? = null;
    paths: ResourcePaths? = null;
    // Entries whose dependencies are not known yet (`settle`), in the
    // order added.
    private unsettled: Array<CachedResource> = [];
    // settle's scratch (kept: settling allocates nothing more once grown).
    private found: Array<Resource> = [];

    // Says where the resource of `kind` at `path` (in the Rive project)
    // came from: the remaps (../runtime/remap.as) say it as they choose,
    // before the loader has the resource; the entry takes it when it is
    // added (or at once, when it is there).
    noteOrigin(kind: string, path: string, origin: ResourceOrigin): void {
        for (let i = 0; i < this.live.length; i++) {
            const e = this.live[i];
            if (e.kind == kind && e.path == path) {
                e.origin = origin;
                return;
            }
        }
        this.pendingOrigins.set(kind + " " + path, origin);
    }

    find(key: string): CachedResource? {
        return this.byKey.has(key) ? this.byKey.get(key) : null;
    }

    // The entry holding `r` (by identity), or null.
    entryOf(r: Resource): CachedResource? {
        return this.byResource.has(r) ? this.byResource.get(r) : null;
    }

    // Adds `resource` under `key` with no reference yet (the caller holds it
    // next); an entry already there under `key` is returned instead, and
    // `resource` is not added.
    add(key: string, path: string, kind: string, resource: Resource, origin: ResourceOrigin? = null): CachedResource {
        const have = this.find(key);
        if (have != null) return have;
        const e = new CachedResource(key, path, kind, resource);
        if (origin != null) e.origin = origin;
        const said = kind + " " + path;
        if (this.pendingOrigins.has(said)) {
            if (origin == null) e.origin = this.pendingOrigins.get(said);
            this.pendingOrigins.delete(said);
        }
        e.order = this.added++;
        e.cpuBytes = resourceCpuBytes(resource);
        if (resource instanceof PackedScene) {
            e.depsSettled = false;
            this.unsettled.push(e);
        }
        this.byKey.set(key, e);
        this.byResource.set(resource, e);
        this.live.push(e);
        for (let i = 0; i < this.listeners.length; i++) this.listeners[i].added(e);
        return e;
    }

    // Milestone 67b: lets `key` name no entry; its entry, if any, stays
    // live for those who hold it and is freed as any other. A loader that
    // read the file again as a new object (ResourceLoader.forget: a root
    // scene found packed, read again from its own root) puts that one
    // under the key, as Godot's CACHE_MODE_REPLACE does.
    unkey(key: string): void {
        if (this.byKey.has(key)) this.byKey.delete(key);
    }

    // `e` holds a reference to `dep` (once, however often it is said; not
    // to itself, nor to a freed entry).
    addDep(e: CachedResource, dep: CachedResource): void {
        if (e === dep || dep.freed || e.freed) return;
        for (let i = 0; i < e.deps.length; i++) if (e.deps[i] === dep) return;
        e.deps.push(dep);
        this.acquire(dep);
    }

    // Takes `e`'s dependencies from the run time's ResourceDeps, when it
    // knows them now (see the header); true when they are known.
    settle(e: CachedResource): bool {
        if (e.depsSettled || e.freed) return true;
        const d = this.deps;
        if (d == null) return false;
        const out = this.found;
        out.length = 0;
        if (!d.depsOf(e.resource, out)) return false;
        for (let i = 0; i < out.length; i++) {
            const dep = this.entryOf(out[i]);
            if (dep != null) this.addDep(e, dep);
        }
        out.length = 0;
        e.depsSettled = true;
        const at = this.unsettled.indexOf(e);
        if (at >= 0) this.unsettled.splice(at, 1);
        return true;
    }

    // settle for every entry whose dependencies are not known yet (an
    // instance was made: its scenes' resources are resolved). Allocates
    // nothing when there is none.
    settleAll(): void {
        for (let i = this.unsettled.length - 1; i >= 0; i--) {
            if (i < this.unsettled.length) this.settle(this.unsettled[i]);
        }
    }

    // How many entries wait for their dependencies (tests).
    get unsettledCount(): i32 {
        return this.unsettled.length;
    }

    // Sets `e`'s CPU bytes (what resourceCpuBytes says once part of it was
    // released: ./cpu_copy.as).
    setCpuBytes(e: CachedResource, bytes: i64): void {
        e.cpuBytes = bytes;
    }

    acquire(e: CachedResource): void {
        e.refs++;
    }

    // One reference fewer; at 0 the resource is freed (see the header).
    release(e: CachedResource): void {
        if (e.freed) return;
        e.refs--;
        if (e.refs > 0) return;
        this.free(e);
    }

    private free(e: CachedResource): void {
        e.freed = true;
        e.refs = 0;
        if (this.byKey.has(e.key) && this.byKey.get(e.key) === e) this.byKey.delete(e.key);
        if (this.byResource.has(e.resource)) this.byResource.delete(e.resource);
        const at = this.live.indexOf(e);
        if (at >= 0) this.live.splice(at, 1);
        if (!e.depsSettled) {
            const u = this.unsettled.indexOf(e);
            if (u >= 0) this.unsettled.splice(u, 1);
            e.depsSettled = true;
        }
        for (let i = 0; i < this.listeners.length; i++) this.listeners[i].freed(e);
        const ledger = gpuLedger();
        for (let i = 0; i < e.gpu.length; i++) ledger.retire(e.gpu[i]);
        e.gpu.length = 0;
        e.gpuBytes = 0;
        this.freedCount++;
        // (what it held, after it: a scene before the textures it draws,
        // the last taken first)
        const deps = e.deps;
        e.deps = [];
        for (let i = deps.length - 1; i >= 0; i--) this.release(deps[i]);
    }

    addListener(l: CacheListener): void {
        for (let i = 0; i < this.listeners.length; i++) if (this.listeners[i] === l) return;
        this.listeners.push(l);
    }

    removeListener(l: CacheListener): void {
        const at = this.listeners.indexOf(l);
        if (at >= 0) this.listeners.splice(at, 1);
    }

    // The live entries, in the order they were added.
    entries(): Array<CachedResource> {
        return this.live;
    }

    get count(): i32 {
        return this.live.length;
    }

    totals(out: ResourceTotals): ResourceTotals {
        out.reset();
        for (let i = 0; i < this.live.length; i++) {
            const e = this.live[i];
            out.count++;
            out.refs += e.refs;
            out.cpuBytes += e.cpuBytes;
            out.gpuBytes += e.gpuBytes;
            if (e.origin.reason.length > 0) out.fallbacks++;
        }
        return out;
    }
}

// What one instance holds (see the header): each resource once.
export class ResourceHolder {
    cache: ResourceCache;
    // Whether its owner went (`close`): a script's loaded scene released,
    // or its instanced subtree freed (../resource/loader.as scoped holders).
    closed: bool = false;
    private held: Array<CachedResource> = [];
    private set: Set<CachedResource> = new Set<CachedResource>();

    constructor(cache: ResourceCache) {
        this.cache = cache;
    }

    // Takes a reference to `e`, unless this holder has one.
    hold(e: CachedResource): void {
        if (this.set.has(e)) return;
        this.set.add(e);
        this.held.push(e);
        this.cache.acquire(e);
    }

    holds(e: CachedResource): bool {
        return this.set.has(e);
    }

    // Lets go of the reference to `e`, if this holder has one.
    drop(e: CachedResource): void {
        if (!this.set.has(e)) return;
        this.set.delete(e);
        const at = this.held.indexOf(e);
        if (at >= 0) this.held.splice(at, 1);
        this.cache.release(e);
    }

    get count(): i32 {
        return this.held.length;
    }

    // Takes a reference to each resource `other` holds (but those freed),
    // keeping its own: a node moved out of a subtree a script instanced
    // keeps what that subtree holds (../tree/node.as removeChild).
    holdAllOf(other: ResourceHolder): void {
        for (let i = 0; i < other.held.length; i++) {
            const e = other.held[i];
            if (!e.freed) this.hold(e);
        }
    }

    // Hands every reference to `other` (which takes one where it holds
    // none), then lets go of its own: nothing is freed on the way (a load's
    // own holder handing what it decoded ahead to the instance it made:
    // ../runtime/load_task.as).
    moveTo(other: ResourceHolder): void {
        for (let i = 0; i < this.held.length; i++) {
            const e = this.held[i];
            if (!e.freed) other.hold(e);
        }
        this.releaseAll();
    }

    // Lets go of every reference, the last taken first (so that a scene is
    // freed before what it names).
    releaseAll(): void {
        for (let i = this.held.length - 1; i >= 0; i--) this.cache.release(this.held[i]);
        this.held.length = 0;
        this.set.clear();
    }

    // releaseAll, for good: its owner went. Idempotent.
    close(): void {
        this.releaseAll();
        this.closed = true;
    }
}

// The bytes of `r`'s CPU side (see CachedResource.cpuBytes): a texture's
// pixels, its processed forms' levels and an .hdr's floats; a model's
// meshes' arrays (a built one's prebuilt vertices at the 56 bytes of their
// packed layout, its indices and levels' indices, its extra UV sets and the
// bytes its upload packed; a converted one's surfaces' numbers). A packed
// scene counts 0: its document is small beside what it names, which is
// counted where it is cached. Every other kind counts 0. What ./cpu_copy.as
// released counts 0 (its arrays are empty), so the figure is taken again
// after a release (../runtime/runtime_resources.as).
export function resourceCpuBytes(r: Resource): i64 {
    if (r instanceof Texture2D) {
        const t = r as Texture2D;
        let n: i64 = 0;
        const img = t.image;
        if (img != null) n += <i64>img.data.length;
        const forms = t.compressed;
        if (forms != null) {
            for (let i = 0; i < forms.length; i++) {
                const ls = forms[i].levels;
                for (let k = 0; k < ls.length; k++) n += <i64>ls[k].data.length;
            }
        }
        const h = t.hdr;
        if (h != null) n += <i64>h.data.length * 4;
        return n;
    }
    if (r instanceof ModelResource) {
        const m = r as ModelResource;
        const seen = new Array<ArrayMesh>();
        let n: i64 = 0;
        for (let i = 0; i < m.objects.length; i++) {
            const mesh = m.objects[i].mesh;
            if (mesh == null || seen.includes(mesh)) continue;
            seen.push(mesh);
            const pre = mesh.prebuilt;
            if (pre != null) {
                n += gpuMeshCpuBytes(pre.gpu);
            } else {
                for (let s = 0; s < mesh.surfaces.length; s++) {
                    const f = mesh.surfaces[s];
                    n += <i64>(f.positions.length + f.normals.length + f.uvs.length) * 4 + <i64>f.indices.length * 4;
                }
            }
        }
        return n;
    }
    return 0;
}

// A GpuMesh's arrays as resourceCpuBytes counts them.
export function gpuMeshCpuBytes(g: GpuMesh): i64 {
    let n: i64 = <i64>g.verts.length * <i64>SURFACE_VERTEX_SIZE + <i64>g.indices.length * 4;
    const uv1 = g.uv1;
    if (uv1 != null) n += <i64>uv1.length * 8;
    const lm = g.lightmapUv;
    if (lm != null) n += <i64>lm.length * 8;
    const ls = g.lods;
    if (ls != null) for (let i = 0; i < ls.length; i++) n += <i64>ls[i].indices.length * 4;
    for (let i = 0; i < g.uploadBytes.length; i++) n += <i64>g.uploadBytes[i].byteLength;
    return n;
}

// The bytes `r` would hold on the GPU once uploaded, as the ledger would
// charge them (a texture's chosen form with its levels, else its image's
// chain as a colour slot samples it; a model's meshes' buffers): what the
// tools print without a device (`hedra inspect --resources`, `--stats`).
// The form taken is the first a texture holds (the run time's choice reads
// that one alone; the tools' textures hold every form, and the device
// would take the first it supports); a colour slot's rgba16float chain for
// an image (8 bytes a texel: the larger of the two slots). A model's mesh:
// its vertices, its indices with every level's, its wire edges and points
// in their packed layouts (render/gpu/layouts.as), as the uploader packs
// them. Other kinds 0.
export function estimateGpuBytes(r: Resource): i64 {
    if (r instanceof Texture2D) {
        const t = r as Texture2D;
        const forms = t.compressed;
        if (forms != null && forms.length > 0) {
            let n: i64 = 0;
            const ls = forms[0].levels;
            for (let k = 0; k < ls.length; k++) n += <i64>ls[k].data.length;
            return n;
        }
        const img = t.image;
        if (img != null) return imageUploadBytes(img.width, img.height, true);
        return 0;
    }
    if (r instanceof ModelResource) {
        const m = r as ModelResource;
        const seen = new Array<ArrayMesh>();
        let n: i64 = 0;
        for (let i = 0; i < m.objects.length; i++) {
            const mesh = m.objects[i].mesh;
            if (mesh == null || seen.includes(mesh)) continue;
            seen.push(mesh);
            const pre = mesh.prebuilt;
            if (pre != null) {
                const g = pre.gpu;
                let ix: i64 = <i64>g.indices.length;
                const ls = g.lods;
                if (ls != null) for (let k = 0; k < ls.length; k++) ix += <i64>ls[k].indices.length;
                n += <i64>g.verts.length * <i64>SURFACE_VERTEX_SIZE + ix * 4 + <i64>g.edges.length * <i64>LINE_INSTANCE_SIZE
                    + <i64>g.points.length * <i64>POINT_INSTANCE_SIZE;
            } else {
                for (let s = 0; s < mesh.surfaces.length; s++) {
                    const f = mesh.surfaces[s];
                    n += <i64>f.vertexCount() * <i64>SURFACE_VERTEX_SIZE + <i64>f.indices.length * 4;
                }
            }
        }
        return n;
    }
    return 0;
}

let theCache: ResourceCache? = null;

// The module's cache (every runtime made by newSceneRuntime shares it).
export function runtimeResourceCache(): ResourceCache {
    let c = theCache;
    if (c == null) {
        c = new ResourceCache();
        theCache = c;
    }
    return c;
}

// A fresh module cache (tests: each starts empty).
export function resetRuntimeResourceCache(): ResourceCache {
    const c = new ResourceCache();
    theCache = c;
    return c;
}
