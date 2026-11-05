// The bundle as the loader's ResourceProvider (milestone 39): each scene
// of the bundle, and each model, mesh, texture, material, lightmap, probe,
// Rive file and script it names, decoded from its entry the first time a
// loader asks for it and kept, so that every tree made from the bundle (two
// instances of one scene, a scene instanced by another, a script's load())
// shares one resource, and so one GPU upload, of each. A path the bundle
// has no entry for is the loader's to read (null), which finds the File
// entries mounted in the run time's file system (`mount`).
//
// What each kind becomes (decode.as): a Scene the .rscnb's document (the
// loader validated it when it was built: it is not validated again); a
// Model its objects and materials, each mesh object's mesh a PrebuiltMesh
// (milestone 26: with its levels of detail, GpuMesh.lods);
// a Texture its image, or its processed forms (Texture2D.compressed: every
// one in the tools, the run time's choice alone, `textureChoice`); a Material the material document built as a material
// file's is (material_file.as buildMaterialDoc), its textures from this
// bundle, resolved against the project root of the loader asking (a
// material two projects share is kept once per root: its res:// textures
// are each project's own); a Lightmap its LightmapData; a Probe the .rprobe's capture; a
// Rive file its artboards; a Script its class. A failure is a
// bundle-invalid error at the bundle (the entry and why).
//
// Milestone 67b (docs/engine/RESOURCES.md, "The cache"): in a run time
// (`cache` set by its resource hook, ../runtime/runtime_resources.as) an
// entry is looked for in the module's resource cache before it is decoded,
// and what is decoded is put there, keyed by its path in the Rive project
// (`project` + "/" + its name) and by its bytes' CRC (so that two built
// files holding the same bytes share one resource, and a stale file's
// other bytes do not), with the texture form chosen (`textureChoice`) and,
// for a material, the project root its textures resolve against: Texture2D
// world/textures/oak.png@b1a2b3c4d.bc. The cache then holds it for as long
// as an instance does, and `kept` is not used (it would keep a freed
// resource's CPU side alive for the bundle's life). What a model's or a
// material's decoding decoded (its textures, its materials) is that
// resource's dependency in the cache (ResourceCache.addDep).

import { Result } from "../../base/util";
import { vfs } from "../../fs/vfs";
import { SceneryError } from "../error";
import { ResourceLoader } from "../resource/loader";
import { SceneTree } from "../tree/tree";
import { loadSceneTree } from "../tree/instance";
import { ResourceProvider } from "../resource/provider";
import { ModelResource, PackedScene, ReflectionProbeData, Resource, RiveFile, Texture2D } from "../resource/types";
import { ArrayOccluder3D } from "../resource/occluders";
import { Shader } from "../resource/shader";
import { decodeOcc, occluderResource } from "../resource/occ_file";
import { buildMaterialDoc } from "../resource/material_build";
import { decodeRscnb } from "../rscnb/codec";
import { decodeRprobe, probeDataResource } from "../probe/rprobe";
import { readRivInfo } from "../riv/riv_info";
import { AssetKind, TocEntry, bundleAbs, bundlePathOf, bundleRootAt, sceneBundleName } from "./format";
import { BUNDLE_INVALID_CODE, BUNDLE_INVALID_HINT, Bundle, BundleScene } from "./read";
import { MeshBytes, TextureChoice, decodeLightmap, decodeModel, decodeScript, decodeShader, decodeTexture } from "./decode";
import { TextureLookup } from "./payload";
import { GpuMesh, MeshLod } from "../../render/mesh";
import { lodsFit, meshLodKey } from "../../meshproc/lod_bytes";
import { ArrayMesh } from "../resource/types";
import { LodSource, currentLodSource } from "../render/meshes";
import { decodeMeshLods } from "./decode";
import { sceneFileBundle } from "./scene_file";
import { decodeAudioStream } from "./audio";
import { CachedResource, ResourceCache, ResourceOrigin, ResourceForm, cacheKeyOf } from "../resource/cache";
import { hexU64 } from "../../base/fmt";

// The textures a model's materials name, from the provider.
class ProviderTextures extends TextureLookup {
    res: BundleResources;
    // The first failure (a model then fails with it).
    why: string = "";

    constructor(res: BundleResources) {
        super();
        this.res = res;
    }

    textureOf(name: string): Texture2D? {
        const r = this.res.texture(name);
        if (r.ok) return r.value;
        if (this.why.length == 0) this.why = r.err;
        return null;
    }

    // Milestone 61: a model's ShaderMaterial's shader, its Shader entry
    // decoded once (a damaged one draws the fallback, said once).
    shaderOf(name: string): Shader? {
        const r = this.res.shader(name);
        if (r.ok) return r.value;
        return null;
    }
}

// The Mesh entries' bytes, CRC checked.
class ProviderMeshes extends MeshBytes {
    res: BundleResources;

    constructor(res: BundleResources) {
        super();
        this.res = res;
    }

    meshBytes(name: string): Uint8Array? {
        const e = this.res.bundle.find(AssetKind.Mesh, name);
        if (e == null) return null;
        const d = this.res.bundle.verified(e);
        return d.ok ? d.value : null;
    }
}

export class BundleResources extends ResourceProvider {
    bundle: Bundle;
    // Milestone 26: which of a texture's stored forms are decoded (every
    // one, the tools'; the run time sets its device's choice before the
    // first texture is read: decode.as TextureChoice).
    textureChoice: TextureChoice = TextureChoice.every();
    // How many entries were decoded (each once): what a test reads to see
    // that two instances share their resources.
    decoded: i32 = 0;
    // By "<kind> <name>": what each entry decoded to.
    private kept: Map<string, Resource> = new Map<string, Resource>();
    private mounted: bool = false;
    // Milestone 41: the first bundle root `mount` tries (bundleRootAt): 1,
    // but for a scene the run time loaded from a Rive project's build/,
    // which starts at its Hedra project's own (SceneRuntime.loadFrom), so
    // that a scene it lacks is read from that project's declared text.
    firstRoot: i32 = 1;
    // Milestone 67b (docs/engine/RESOURCES.md, "The cache"): the run time's
    // resource cache, which decoded entries are kept in by their paths in
    // the Rive project (`project` + "/" + the entry's name) so that every
    // runtime and every built file that holds a resource shares one object
    // of it; null (every tool, and a runtime without the cache hook): kept
    // here only, as before. Set by the hook (../runtime/runtime_resources.as)
    // and by the remaps for the built files they open (../runtime/remap.as).
    cache: ResourceCache? = null;
    project: string = "";
    // Milestone 67b: the entries decoded while each decoding in progress
    // runs (a model's textures, a material's), innermost last: they become
    // its dependencies in the cache.
    private frames: Array<Array<CachedResource>> = [];

    constructor(bundle: Bundle) {
        super();
        this.bundle = bundle;
    }

    // A bundle-invalid error naming the entry.
    private invalid<T>(what: string, why: string): Result<T> {
        const f = this.bundle.file;
        return SceneryError.at(BUNDLE_INVALID_CODE, f, 0, 0, f + ": " + what + " cannot be read: " + why, BUNDLE_INVALID_HINT)
            .fail<T>();
    }

    private keep(kind: AssetKind, name: string, r: Resource): void {
        this.kept.set((<u32>kind).toString() + " " + name, r);
        this.decoded++;
    }

    private held(kind: AssetKind, name: string): Resource? {
        const k = (<u32>kind).toString() + " " + name;
        return this.kept.has(k) ? this.kept.get(k) : null;
    }

    // The bytes of `e`, CRC checked.
    private bytesOf(e: TocEntry): Result<Uint8Array> {
        return this.bundle.verified(e);
    }

    provide(type: string, abs: string, display: string, root: string): Result<Resource>? {
        const name = bundlePathOf(abs);
        if (name == null) return null;
        if (type == "PackedScene") {
            const sceneName = sceneBundleName(name);
            if (this.bundle.find(AssetKind.Scene, sceneName) != null) return this.decodeKind(AssetKind.Scene, sceneName, display, root);
            // A model file as a scene: the same model a Model ext_resource
            // of the file gets.
            const me = this.bundle.find(AssetKind.Model, name);
            if (me == null) return null;
            const m = this.decodeKind(AssetKind.Model, name, display, root);
            if (!m.ok) return m;
            // (milestone 67b: one scene of the model in the cache, holding
            // the model, rather than one each time a loader asks)
            const cache = this.cache;
            const key = cache != null ? cacheKeyOf("PackedScene", this.rivePathOf(name), "m" + hexU64(me.crc, 8)) : "";
            if (cache != null) {
                const have = cache.find(key);
                if (have != null) return Result.okv<Resource>(have.resource);
            }
            const p = new PackedScene();
            p.model = m.value as ModelResource;
            if (cache != null) {
                const e = cache.add(key, this.rivePathOf(name), "PackedScene", p, this.originOf(name));
                const model = cache.entryOf(p.model!);
                if (model != null) cache.addDep(e, model);
                // (its dependency is its model: nothing to settle)
                cache.settle(e);
                return Result.okv<Resource>(e.resource);
            }
            return Result.okv<Resource>(p);
        }
        let kind: AssetKind;
        if (type == "Model") kind = AssetKind.Model;
        else if (type == "Texture2D") kind = AssetKind.Texture;
        else if (type == "Material") kind = AssetKind.Material;
        else if (type == "RiveFile") kind = AssetKind.Rive;
        else if (type == "LightmapGIData") kind = AssetKind.Lightmap;
        else if (type == "ReflectionProbeData") kind = AssetKind.Probe;
        else if (type == "Script") kind = AssetKind.Script;
        else if (type == "AudioStream" || type == "AudioStreamWAV" || type == "AudioStreamMP3") kind = AssetKind.Audio;
        else if (type == "ArrayOccluder3D") kind = AssetKind.Occluder;
        else if (type == "Shader") kind = AssetKind.Shader;
        else return null;
        if (this.bundle.find(kind, name) == null) return null;
        return this.decodeKind(kind, name, display, root);
    }

    // Milestone 67b: how many entries the bundle has, and entry `i` decoded
    // ahead of the loader's asking (../runtime/load_task.as's decoding
    // step), as the loader would have it decoded: a scene, model, texture,
    // material, lightmap, probe, Rive file, script, sound, occluder or
    // shader is decoded and kept (a material against the main scene's
    // project root, as bundleLoader's loader asks); any other kind (a file,
    // the index, a mesh or levels of detail, which their model decodes) is
    // skipped. False when the entry does not decode (the loader then fails
    // on it as before) or was skipped.
    get entryCount(): i32 {
        return this.bundle.entries.length;
    }

    warmEntry(i: i32): bool {
        if (i < 0 || i >= this.bundle.entries.length) return false;
        const e = this.bundle.entries[i];
        const kind = <AssetKind>e.kind;
        if (kind != AssetKind.Scene && kind != AssetKind.Model && kind != AssetKind.Texture && kind != AssetKind.Material
            && kind != AssetKind.Lightmap && kind != AssetKind.Probe && kind != AssetKind.Rive && kind != AssetKind.Script
            && kind != AssetKind.Audio && kind != AssetKind.Occluder && kind != AssetKind.Shader) {
            return false;
        }
        let root = "";
        if (kind == AssetKind.Material) {
            const main = this.bundle.scene(this.bundle.main);
            if (main != null) root = main.rootAbs();
        }
        return this.decodeKind(kind, e.name, e.name, root).ok;
    }

    // Milestone 61: the shader file named `name` (its bundle path), decoded
    // once.
    shader(name: string): Result<Shader> {
        const r = this.decodeKind(AssetKind.Shader, name, name, "");
        if (!r.ok) return r.forward<Shader>();
        return Result.okv<Shader>(r.value as Shader);
    }

    // The texture named `name` (a file's bundle path, or "<model>#<key>"
    // for an image a glTF file embeds), decoded once.
    texture(name: string): Result<Texture2D> {
        const r = this.decodeKind(AssetKind.Texture, name, name, "");
        if (!r.ok) return r.forward<Texture2D>();
        return Result.okv<Texture2D>(r.value as Texture2D);
    }

    // The resource entry (`kind`, `name`) holds, decoded on first use.
    // `display` is how the first loader to ask names the file: a scene's
    // and a material's documents keep it, as a document read from the file
    // keeps the loader's name for it (what nodes' sceneFile and messages
    // show). `root` is that loader's project root: only a Material uses it
    // (its res:// textures resolve against it), and so only a Material is
    // kept per root.
    private decodeKind(kind: AssetKind, name: string, display: string, root: string): Result<Resource> {
        const cache = this.cache;
        if (cache != null) return this.decodeCached(cache, kind, name, display, root);
        const keptAs = kind == AssetKind.Material ? name + "\n" + root : name;
        const have = this.held(kind, keptAs);
        if (have != null) return Result.okv<Resource>(have);
        const made = this.decodeEntry(kind, name, display, root);
        if (!made.ok) return made;
        this.keep(kind, keptAs, made.value);
        return made;
    }

    // Milestone 67b: the path of entry `name` in the Rive project.
    rivePathOf(name: string): string {
        return this.project.length > 0 ? this.project + "/" + name : name;
    }

    // Milestone 67b: the cache key of entry `e` of `kind` (see the header).
    // A self-contained scene's own entry (the whole file, trusted: its CRC
    // in the table is 0) is known by the CRC its header carries instead.
    cacheKey(kind: AssetKind, e: TocEntry, root: string): string {
        let crc = e.crc;
        const bytes = this.bundle.bytes;
        if (crc == 0 && kind == AssetKind.Scene && e.offset == 0 && bytes.length >= 24) {
            crc = <u32>bytes[20] | (<u32>bytes[21] << 8) | (<u32>bytes[22] << 16) | (<u32>bytes[23] << 24);
        }
        let variant = "b" + hexU64(crc, 8);
        if (kind == AssetKind.Texture) variant += "." + this.textureChoice.name + (this.textureChoice.all ? "*" : "");
        if (kind == AssetKind.Material) variant += "|" + root;
        return cacheKeyOf(cacheKindName(kind), this.rivePathOf(e.name), variant);
    }

    // Where entry `name` comes from (the cache entry's origin).
    private originOf(name: string): ResourceOrigin {
        const o = new ResourceOrigin();
        o.form = ResourceForm.Built;
        o.from = this.bundle.file + "#" + name;
        return o;
    }

    // decodeKind with the run time's cache (see the header).
    private decodeCached(cache: ResourceCache, kind: AssetKind, name: string, display: string, root: string): Result<Resource> {
        const e = this.bundle.find(kind, name);
        if (e == null) return this.invalid<Resource>(kindLabel(kind) + " " + name, "the bundle holds no such entry");
        const key = this.cacheKey(kind, e, root);
        const have = cache.find(key);
        if (have != null) {
            this.noteDecoded(have);
            return Result.okv<Resource>(have.resource);
        }
        this.frames.push(new Array<CachedResource>());
        const made = this.decodeEntry(kind, name, display, root);
        const deps = this.frames.pop();
        if (!made.ok) return made;
        this.decoded++;
        const entry = cache.add(key, this.rivePathOf(name), cacheKindName(kind), made.value, this.originOf(name));
        for (let i = 0; i < deps.length; i++) cache.addDep(entry, deps[i]);
        this.noteDecoded(entry);
        return Result.okv<Resource>(entry.resource);
    }

    // `e` was asked for while another entry decodes: one of its
    // dependencies.
    private noteDecoded(e: CachedResource): void {
        const n = this.frames.length;
        if (n > 0) this.frames[n - 1].push(e);
    }

    // The resource entry (`kind`, `name`) holds, decoded (see decodeKind).
    private decodeEntry(kind: AssetKind, name: string, display: string, root: string): Result<Resource> {
        const e = this.bundle.find(kind, name);
        const what = kindLabel(kind) + " " + name;
        if (e == null) return this.invalid<Resource>(what, "the bundle holds no such entry");
        const b = this.bytesOf(e);
        if (!b.ok) return b.forward<Resource>();
        const bytes = b.value;
        let made: Resource;
        if (kind == AssetKind.Scene) {
            const d = decodeRscnb(bytes, display);
            if (!d.ok) return this.invalid<Resource>(what, d.err);
            const p = new PackedScene();
            p.doc = d.value;
            made = p;
        } else if (kind == AssetKind.Model) {
            const textures = new ProviderTextures(this);
            const m = decodeModel(bytes, what, textures, new ProviderMeshes(this));
            if (!m.ok) return this.invalid<Resource>(what, textures.why.length > 0 ? textures.why : m.err);
            made = m.value;
        } else if (kind == AssetKind.Texture) {
            const t = decodeTexture(bytes, what, this.textureChoice);
            if (!t.ok) return this.invalid<Resource>(what, t.err);
            const tex = t.value;
            // Its path is its identity in the renderer's texture files (an
            // embedded image's "<model>#<key>", as the loader names one).
            tex.path = bundleAbs(name, this.bundle.root);
            tex.file = name;
            const hash = name.indexOf("#");
            if (hash >= 0) tex.name = name.substring(hash + 1);
            made = tex;
        } else if (kind == AssetKind.Material) {
            const d = decodeRscnb(bytes, display);
            if (!d.ok) return this.invalid<Resource>(what, d.err);
            const loader = new ResourceLoader(root);
            loader.provider = this;
            const m = buildMaterialDoc(d.value, bundleAbs(name, this.bundle.root), loader);
            if (!m.ok) return m.forward<Resource>();
            made = m.value;
        } else if (kind == AssetKind.Lightmap) {
            const l = decodeLightmap(bytes, what);
            if (!l.ok) return this.invalid<Resource>(what, l.err);
            made = l.value;
        } else if (kind == AssetKind.Probe) {
            // A probe the build could not read is empty: captured when
            // drawn, as the loader leaves one it cannot read.
            if (bytes.length == 0) {
                made = new ReflectionProbeData();
            } else {
                const c = decodeRprobe(bytes, name);
                if (!c.ok) return this.invalid<Resource>(what, c.err);
                made = probeDataResource(c.value);
            }
        } else if (kind == AssetKind.Rive) {
            const info = readRivInfo(bytes);
            if (!info.ok) return this.invalid<Resource>(what, info.err);
            const f = new RiveFile();
            f.info = info.value;
            made = f;
        } else if (kind == AssetKind.Script) {
            const s = decodeScript(bytes, what);
            if (!s.ok) return this.invalid<Resource>(what, s.err);
            made = s.value;
        } else if (kind == AssetKind.Audio) {
            const a = decodeAudioStream(bytes, what);
            if (!a.ok) return this.invalid<Resource>(what, a.err);
            made = a.value;
        } else if (kind == AssetKind.Occluder) {
            // Milestone 37: an occluder the build could not read is empty
            // (occludes nothing), as the loader leaves one it cannot read.
            if (bytes.length == 0) {
                made = new ArrayOccluder3D();
            } else {
                const c = decodeOcc(bytes, name);
                if (!c.ok) return this.invalid<Resource>(what, c.err);
                made = occluderResource(c.value);
            }
        } else if (kind == AssetKind.Shader) {
            // Milestone 61: a shader file's text (UTF-8, as the build read
            // it), read again as the loader reads one: its declarations,
            // and its key, by which the run time finds the module rive
            // compiled (../runtime/shader_assets.as).
            const sh = decodeShader(bytes, what, display);
            if (!sh.ok) return this.invalid<Resource>(what, sh.err);
            made = sh.value;
        } else {
            return this.invalid<Resource>(what, "it is not a resource");
        }
        return Result.okv<Resource>(made);
    }

    // Mounts every File entry in the vfs at its run-time path (once; the
    // run time calls it after loadBundle), each checked against its CRC
    // first, as every other entry is when it is read (Bundle.verified): the
    // vfs hands the bytes to whatever reads the path, past the bundle. A
    // damaged one is not mounted, and the first is the error (the others
    // are mounted all the same).
    //
    // Milestone 40: the vfs is the module's, shared by every scene
    // built into one Rive project, so the bundle is first put at the
    // first root (format.as bundleRootAt) where none of its files would
    // replace different bytes another bundle mounted: two projects' scenes
    // with a file at the same path each read their own. A bundle that
    // meets no such file stays at BUNDLE_ROOT.
    mount(): Result<bool> {
        if (this.mounted) return Result.okv<bool>(true);
        this.mounted = true;
        let first: Result<bool>? = null;
        const files = new Array<string>();
        const datas = new Array<Uint8Array>();
        const es = this.bundle.entries;
        for (let i = 0; i < es.length; i++) {
            const e = es[i];
            if (e.kind != <u32>AssetKind.File) continue;
            const d = this.bundle.verified(e);
            if (!d.ok) {
                if (first == null) first = d.forward<bool>();
                continue;
            }
            files.push(e.name);
            datas.push(d.value);
        }
        let n = this.firstRoot > 1 ? this.firstRoot : 1;
        while (clashes(files, datas, bundleRootAt(n))) n++;
        this.bundle.placeAt(bundleRootAt(n));
        for (let i = 0; i < files.length; i++) {
            const abs = bundleAbs(files[i], this.bundle.root);
            this.mountedPaths.push(abs);
            this.mountedDatas.push(datas[i]);
            this.mountedBefore.push(vfs.mounted(abs));
            vfs.mount(abs, datas[i]);
        }
        return first != null ? first! : Result.okv<bool>(true);
    }

    // Milestone 67b: what `mount` mounted (absolute paths, the bytes, and
    // what each replaced), for `unmount`.
    private mountedPaths: Array<string> = [];
    private mountedDatas: Array<Uint8Array> = [];
    private mountedBefore: Array<Uint8Array?> = [];

    // Milestone 67b: takes out what `mount` mounted that is still this
    // bundle's (a later mount of the same path stays), putting back what it
    // replaced: a load given up (../runtime/load_task.as LoadTask.cancel)
    // so leaves no view of its built file's bytes in the file system.
    unmount(): void {
        for (let i = this.mountedPaths.length - 1; i >= 0; i--) {
            vfs.unmount(this.mountedPaths[i], this.mountedDatas[i], this.mountedBefore[i]);
        }
        this.mountedPaths.length = 0;
        this.mountedDatas.length = 0;
        this.mountedBefore.length = 0;
        this.mounted = false;
    }
}

// Whether mounting `files` (bundle paths, with their bytes `datas`) under
// `root` would replace different bytes already mounted there.
function clashes(files: Array<string>, datas: Array<Uint8Array>, root: string): bool {
    for (let i = 0; i < files.length; i++) {
        const had = vfs.mounted(bundleAbs(files[i], root));
        if (had != null && !sameBytes(had, datas[i])) return true;
    }
    return false;
}

function sameBytes(a: Uint8Array, b: Uint8Array): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
    return true;
}

// Milestone 26: where the run time's primitive meshes get their levels of
// detail (render/meshes.as provideLods): the bundle's Lods entry of the
// mesh's key (format.as AssetKind.Lods), which the build generated as the
// tools generate them, when it holds one that fits the mesh; none
// otherwise. A model's mesh comes with its own (a Mesh entry's), and a
// mesh built in code has none. Each mesh is asked once (provideLods keeps
// the answer).
export class BundleLodSource extends LodSource {
    res: BundleResources;

    constructor(res: BundleResources) {
        super();
        this.res = res;
    }

    levels(mesh: ArrayMesh, g: GpuMesh): Array<MeshLod> {
        const none = new Array<MeshLod>();
        if (mesh.prebuilt != null || mesh.source != null || g.indices.length == 0) return none;
        const key = meshLodKey(g);
        const e = this.res.bundle.find(AssetKind.Lods, key);
        if (e == null) return none;
        const d = this.res.bundle.verified(e);
        if (!d.ok) return none;
        const r = decodeMeshLods(d.value, g.verts.length, "the levels of detail " + key);
        if (!r.ok || !lodsFit(r.value, g)) return none;
        return r.value;
    }
}

// The level source for a runtime that loaded `res`, which the runtime
// gives its own SceneRenderCache (cache.as lodSource) rather than
// installing it for the whole module: scenes built into one Rive
// project share one hedra_engine library, and a module-wide source would let the
// scene loaded last decide the levels of every scene's meshes. Null when
// the tools' own source (compiler/src/import/lod_source.as, which makes the
// same levels) is installed: a bundle rendered by the tools keeps it.
export function useBundleLods(res: BundleResources): LodSource? {
    const cur = currentLodSource();
    if (cur != null && !(cur instanceof BundleLodSource)) return null;
    return new BundleLodSource(res);
}

// Milestone 67b: the resource cache's kind of an entry of kind `k` (the
// ext_resource type a loader asks for it as; ../resource/cache.as).
export function cacheKindName(k: AssetKind): string {
    switch (k) {
        case AssetKind.Scene: return "PackedScene";
        case AssetKind.Material: return "Material";
        case AssetKind.Model: return "Model";
        case AssetKind.Texture: return "Texture2D";
        case AssetKind.Lightmap: return "LightmapGIData";
        case AssetKind.Probe: return "ReflectionProbeData";
        case AssetKind.Rive: return "RiveFile";
        case AssetKind.Script: return "Script";
        case AssetKind.Audio: return "AudioStream";
        case AssetKind.Occluder: return "ArrayOccluder3D";
        case AssetKind.Shader: return "Shader";
        default: return kindLabel(k);
    }
}

function kindLabel(k: AssetKind): string {
    switch (k) {
        case AssetKind.Scene: return "scene";
        case AssetKind.Material: return "material";
        case AssetKind.Model: return "model";
        case AssetKind.Mesh: return "mesh";
        case AssetKind.Texture: return "texture";
        case AssetKind.Lightmap: return "lightmap";
        case AssetKind.Probe: return "probe";
        case AssetKind.Rive: return "Rive file";
        case AssetKind.Script: return "script";
        case AssetKind.Lods: return "levels of detail";
        case AssetKind.Audio: return "audio stream";
        case AssetKind.Occluder: return "occluder";
        case AssetKind.Shader: return "shader";
        default: return "entry";
    }
}

// A loader for instancing `scene` from `res`: its project root the
// scene's, its provider `res`.
export function bundleLoader(res: BundleResources, scene: BundleScene): ResourceLoader {
    const l = new ResourceLoader(scene.rootAbs());
    l.provider = res;
    return l;
}

// The tree of the self-contained scene file at `abs` (a built .rscnb,
// whose ASST section carries every asset it uses; named `shown` in
// errors, as typed), read through the vfs and loaded from the file alone,
// as the run time loads it: what the CLI's `render <scene>.rscnb` draws for
// a built scene, so that the picture of a scene from its built form can be
// compared with the scene's own, pixel for pixel.
export function loadSceneFileTree(abs: string, shown: string): Result<SceneTree> {
    const bytes = vfs.read(abs);
    if (!bytes.ok) {
        return SceneryError.at("file-read", shown, 0, 0, "cannot read " + shown + ": " + bytes.err,
            "check that the file exists and can be read").fail<SceneTree>();
    }
    const b = sceneFileBundle(bytes.value, shown);
    if (!b.ok) return b.forward<SceneTree>();
    return loadFromBundle(b.value, b.value.main);
}

// The tree of the scene at bundle path `scenePath` of `bundle` (a fresh
// provider: see BundleResources to share one).
export function loadFromBundle(bundle: Bundle, scenePath: string): Result<SceneTree> {
    const res = new BundleResources(bundle);
    const m = res.mount();
    if (!m.ok) return m.forward<SceneTree>();
    return loadBundleScene(res, scenePath);
}

// The tree of the scene at bundle path `scenePath`, its resources from
// `res` (shared with every other tree loaded through it). A scene the
// bundle does not list is a file-read error at "<bundle>#<path>", its hint
// naming the scenes the bundle holds.
export function loadBundleScene(res: BundleResources, scenePath: string): Result<SceneTree> {
    const bundle = res.bundle;
    const scene = bundle.scene(scenePath);
    if (scene == null) {
        const names = new Array<string>();
        for (let i = 0; i < bundle.scenes.length; i++) names.push(bundle.scenes[i].path);
        return SceneryError.at("file-read", bundle.file + "#" + scenePath, 0, 0, "the bundle holds no scene " + scenePath,
            names.length > 0 ? "its scenes are " + names.join(", ") : "the bundle holds no scene").fail<SceneTree>();
    }
    return loadSceneTree(scene.abs(), bundleLoader(res, scene));
}
