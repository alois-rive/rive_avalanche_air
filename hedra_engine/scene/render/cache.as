// What a scene's renders keep from one frame to the next: the GPU meshes
// built from the scene's meshes (a primitive's triangles, or a model's mesh
// built by its ModelSource exactly as Hedra builds it), and the
// images of the scene's textures, which the renderer's material binder reads
// through `textures` instead of the disk (a glTF model's embedded images are
// no file).
//
// A program keeps one SceneRenderCache per renderer: it hands it to
// buildSceneFrame (adapter.as), which fills it, installs `textures` as the
// renderer's texture files once (`FrameRenderer.materials.files`), and calls
// `upload` in the host's draw before `FrameRenderer.renderFrame`.
//
// Meshes are cached by resource identity: a mesh resource shared by many
// nodes (a pillar used twice, a model instanced twice) is built once. A
// model's meshes are built through one ModelMeshCache per ModelResource
// (its source's), keyed by object id as Hedra's is. A reloaded scene (the
// preview's reload on save) holds new resources, so its meshes miss by
// identity and are built afresh; the old tree's entries are then dead, and
// the preview drops them with `mark` and `sweep` once the new tree's first
// picture is planned, handing their device buffers to
// `FrameRenderer.retire` as Hedra's adapter does. Textures are compared
// by stamp instead (SceneTextureFiles.stamp).
//
// Milestone 19 adds what a scene's bake puts on its frames (lightmap.as):
// each lightmapped item's mesh, built once per LightmapInstance (a reloaded
// bake is new instances, so its meshes are built afresh and `sweep` drops
// the old), what each item slot was last matched to, and a probe light
// array per item slot, so that planning the same tree again allocates
// nothing for its bake.
//
// Milestone 20 adds the reflection probes a frame draws (probes.as): their
// descs and the ReflectionProbeSet, kept and updated in place, so that
// planning the same tree again allocates nothing for them either.
//
// Milestone 48 adds what a node's skin and blend shapes keep from frame to
// frame (`deformOf`, NodeDeform): its palette (skinning.as SkinState), its
// blended copy of the mesh (morph.as MorphCache), the CPU-skinned copy the
// wire shadings draw (skinning.as CpuSkin), and a ModelInstance3D's
// file-pose palettes, by node, kept while plans use the node and dropped by
// `sweep` (their copies' buffers handed back for the renderer to release),
// so that a posed or blended node plans again with no allocation.
//
// Milestone 35 adds the CPUParticles3D nodes' instances (`keepParticles`):
// each emitter's InstanceData is its particle state's own, packed again in
// place as its particles move, so the cache keeps no copy; it only records
// which a plan drew, so that `sweep` hands those of a reloaded tree's old
// nodes (or of an emitter no longer drawn) to the renderer, which releases
// their buffers as a dropped MultiMesh's.
//
// Milestone 67b (docs/engine/RESOURCES.md, "Lifetimes"): the run time's
// resource cache tells every runtime's render cache when it frees a
// resource (../runtime/runtime_resources.as): `forgetResource` drops what
// was kept for a texture (its image and forms by path, so that a later
// texture at the path is a new stamp, and the binder uploads it rather
// than binding the view released with the old one) or a model (its meshes
// and its mesh cache), `forgetMeshes` the meshes of a freed resource by
// their GpuMeshes (whose device buffers the resource's GPU release lets go
// of: they are not retired here), and `meshOfGpu` tells the hook which
// mesh resource an upload belongs to. A texture's image or forms freed
// after their release (Image.freed: neither bytes nor an upload left) are
// never taken in or handed out again, even by a cache that was not told:
// a tree that still names the texture draws its path from the source
// (SceneTextureFiles.add, dropFreed) rather than the binder's fallback.

import { Result } from "../../base/util";
import { MAT4_IDENTITY, Mat4 } from "../../base/vecmath";
import { Image } from "../../render/image";
import { Bounds } from "../../render/camera";
import { RenderFrame } from "../../render/frame";
import { GpuMesh, MeshUploader, vertexBox } from "../../render/mesh";
import { FrameRenderer } from "../../render/gpu/renderer";
import { InstanceData, packInstances } from "../../render/instances";
import { TextureFiles, TextureStamp, VfsTextureFiles } from "../../render/material";
import { CompressedImage, formOfBlockFormat } from "../../texture/format";
import { ArrayMesh, ModelMeshCache, ModelMeshSource, ModelResource, MultiMesh, Resource, Texture2D } from "../resource/types";
import { LightmapData, LightmapInstance, LightmapProbeSet } from "../../render/lightmap/data";
import { SH_L1_FLOATS } from "../../render/lightmap/sh";
import { MODEL_TO_SCENE } from "../space";
import { ReflectionProbeDesc, ReflectionProbeSet } from "../../render/probe/data";
import { LightmapGI, ReflectionProbe, SceneNode, WorldEnvironment } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { LodSource, arrayMeshToGpu, modelObjectMesh, provideLods } from "./meshes";
import { CPU_COPY_RELEASE, cpuCopyPolicy } from "../resource/cpu_copy";
import { MorphCache } from "./morph";
import { CpuSkin, SkinState, filePosePalette } from "./skinning";

// The texture files of a scene's materials: the images the scene's
// Texture2D resources hold, by their path (an absolute file path, or
// `<model path>#<image>` for an image a glTF file embeds), and the disk
// through the vfs for any other path.
//
// Milestone 26: which form of each texture is drawn (`mode`, the frame's
// SceneRenderOptions.textures; `useTextures`). TEXTURES_SOURCE (-2, the
// default) draws the images, as before; a texture a built scene holds
// as processed forms alone (`addCompressed`, from Texture2D.compressed)
// draws those, there being no source. TEXTURES_IMPORTED (-1) draws every
// processed form a texture has (the binder takes the first the device
// does), and a TextureForm (bc 1, etc2 2, astc 3) that form alone (decoded
// on the CPU where the device does not take it): a bundle's forms as it
// holds them, a file's through `imported` (the tools' ImportedTextureFiles,
// hedra_compiler/import/texture_files.as, which reads the import cache or imports
// in memory; set by texture_mode.as, never by the run time, whose module
// must not carry the encoders). A texture without the form asked for is
// drawn from its source. A mode change is a new stamp for every texture,
// so the binder uploads each again.
export class SceneTextureFiles extends TextureFiles {
    images: Map<string, Image> = new Map<string, Image>();
    // By path: how many different pictures have been registered there. The
    // binder keeps a GPU texture while its stamp is unchanged, and neither
    // an image in memory nor the vfs has a modification time, so this count
    // stands in for one: a PNG re-saved with other pixels at the same size
    // (or a glTF re-exported) and reloaded is a new stamp, and an unchanged
    // file reloaded keeps its stamp, so its GPU texture.
    private generations: Map<string, u32> = new Map<string, u32>();
    disk: VfsTextureFiles = new VfsTextureFiles();
    // Milestone 26 (see the header): the mode, the bundle's forms by path,
    // what `compressed` answered for each path in this mode (kept: the
    // binder asks once per stamp, and an answer filtered once allocates
    // nothing again), and the tools' imported files.
    mode: i32 = TEXTURES_SOURCE_MODE;
    forms: Map<string, Array<CompressedImage>> = new Map<string, Array<CompressedImage>>();
    private picked: Map<string, Array<CompressedImage>?> = new Map<string, Array<CompressedImage>?>();
    imported: TextureFiles? = null;
    // How many times `useTextures` changed the mode or the imported files.
    // It is part of every stamp but the source mode's: an editor's Reimport
    // goes through the source mode and straight back with fresh imported
    // files and no bind in between, so a stamp of the mode alone would
    // still be the one the binder kept, and the old forms would stay drawn.
    private usesGeneration: u32 = 0;

    // Registers the image a Texture2D holds under its path. The same Image
    // again (every frame of an unchanged scene) keeps the stamp, and so
    // does a new Image with the same pixels (every reload decodes the
    // scene's files afresh, and an unchanged one must not be uploaded
    // again: comparing the bytes costs far less than the upload's mip
    // chain).
    //
    // Milestone 67b: an image freed after its release (Image.freed: its
    // texture was freed, its pixels and its upload gone) is taken in no
    // more, as Godot's ResourceCache never hands back a resource being
    // deleted: a tree that still names it draws its path from the source.
    add(path: string, image: Image): void {
        if (image.freed) {
            this.dropFreed(path);
            return;
        }
        if (this.images.has(path)) {
            const held = this.images.get(path);
            if (held === image) return;
            if (held.equals(image)) {
                this.images.set(path, image);
                return;
            }
        }
        this.bump(path);
        this.images.set(path, image);
    }

    // Milestone 26: registers a bundle texture's processed forms under its
    // path (Texture2D.compressed); the same array again keeps the stamp.
    // (milestone 67b: freed forms, as a freed image in `add`, are not)
    addCompressed(path: string, forms: Array<CompressedImage>): void {
        if (anyFreed(forms)) {
            this.dropFreed(path);
            return;
        }
        if (this.forms.has(path) && this.forms.get(path) === forms) return;
        this.bump(path);
        this.forms.set(path, forms);
        if (this.picked.has(path)) this.picked.delete(path);
    }

    private bump(path: string): void {
        const gen: u32 = this.generations.has(path) ? this.generations.get(path) + 1 : 1;
        this.generations.set(path, gen);
    }

    // Milestone 67b (see the header): forgets the image `image` and the
    // forms `forms` registered at `path` when they are those (the freed
    // texture's), so that what is registered there next is a new stamp
    // (`add` bumps a path it holds nothing at). Its generation is kept.
    forget(path: string, image: Image?, forms: Array<CompressedImage>?): void {
        if (image != null && this.images.has(path) && this.images.get(path) === image) this.images.delete(path);
        if (forms != null && this.forms.has(path) && this.forms.get(path) === forms) {
            this.forms.delete(path);
            if (this.picked.has(path)) this.picked.delete(path);
        }
    }

    // Milestone 67b: forgets what `path` holds that was freed after its
    // release (Image.freed, CompressedImage.freed), which a cache the run
    // time did not tell of the free (no live instance drew with it then)
    // may still hold: the path's source is drawn instead. Its generation
    // is kept. Two tests when nothing was freed; allocates nothing.
    private dropFreed(path: string): void {
        if (this.images.has(path) && this.images.get(path).freed) this.images.delete(path);
        if (this.forms.has(path) && anyFreed(this.forms.get(path))) {
            this.forms.delete(path);
            if (this.picked.has(path)) this.picked.delete(path);
        }
    }

    // Draws textures in `mode` (see the header), files' processed forms
    // through `imported` (null: none, the run time's case). Nothing changes,
    // and nothing is allocated, when both are what they were.
    useTextures(mode: i32, imported: TextureFiles?): void {
        if (mode == this.mode && imported === this.imported) return;
        this.mode = mode;
        this.imported = imported;
        this.picked.clear();
        // (kept below 2^18: with the image generation below 2^32 and the
        // mode in eighths the stamp stays an exact f64)
        this.usesGeneration = (this.usesGeneration + 1) & 0x3ffff;
    }

    canonicalize(path: string): string? {
        if (this.images.has(path) || this.forms.has(path)) return path;
        return this.disk.canonicalize(path);
    }

    stamp(path: string): TextureStamp? {
        // (milestone 67b: what was freed is not drawn: the binder asks for
        // the stamp first, and then reads the source, or `decoded` and
        // `compressed`, which agree with it)
        this.dropFreed(path);
        // (the mode, and how often it or the imported files changed, are
        // part of every stamp but the source mode's, which stays what it
        // was before milestone 26)
        const m: f64 = this.mode == TEXTURES_SOURCE_MODE ? 0
            : <f64>(this.mode + 3) / 8 + <f64>this.usesGeneration * 4294967296.0;
        if (this.images.has(path)) {
            const img = this.images.get(path);
            const n: u64 = <u64>img.width * <u64>img.height + this.serialOf(path);
            return new TextureStamp(true, <f64>this.generations.get(path) + m, n);
        }
        if (this.forms.has(path)) {
            const f = this.forms.get(path);
            const n: u64 = f.length > 0 ? <u64>f[0].width * <u64>f[0].height : 0;
            return new TextureStamp(true, <f64>this.generations.get(path) + m, n);
        }
        const d = this.disk.stamp(path);
        if (d == null || this.mode == TEXTURES_SOURCE_MODE) return d;
        return new TextureStamp(true, m, d.len + this.serialOf(path));
    }

    // The imported files' serial for `path` (TextureFiles.formsSerial: an
    // import in slices finished, its forms now drawn where the source was),
    // in the stamp's length above 2^40 (a file's length is below it); 0 in
    // the source mode and without imported files.
    private serialOf(path: string): u64 {
        const imp = this.imported;
        if (imp == null || this.mode == TEXTURES_SOURCE_MODE) return 0;
        return <u64>imp.formsSerial(path) << 40;
    }

    read(path: string): Result<Uint8Array> {
        return this.disk.read(path);
    }

    // (milestone 67b: never an image freed after its release: see `add`)
    decoded(path: string): Image? {
        if (!this.images.has(path)) return null;
        const img = this.images.get(path);
        return img.freed ? null : img;
    }

    // The forms drawn for `path` in this mode (see the header); null draws
    // the source.
    compressed(path: string): Array<CompressedImage>? {
        // (a file's forms through the imported files, asked each time: they
        // keep their answers, and one may change when an import in slices
        // finishes)
        if (this.forms.has(path) && anyFreed(this.forms.get(path))) this.dropFreed(path);
        if (!this.forms.has(path)) {
            const imp = this.imported;
            return this.mode == TEXTURES_SOURCE_MODE || imp == null ? null : imp.compressed(path);
        }
        if (this.picked.has(path)) return this.picked.get(path);
        const r = this.pick(path);
        this.picked.set(path, r);
        return r;
    }

    // The forms a bundle's texture at `path` (one of `forms`) draws in this
    // mode.
    private pick(path: string): Array<CompressedImage>? {
        const hasSource = this.images.has(path);
        const all = this.forms.get(path);
        if (all.length == 0) return null;
        if (this.mode == TEXTURES_SOURCE_MODE) return hasSource ? null : all;
        if (this.mode < 0) return all;
        const only = new Array<CompressedImage>();
        for (let i = 0; i < all.length; i++) {
            if (<i32>formOfBlockFormat(all[i].format) == this.mode) only.push(all[i]);
        }
        if (only.length > 0) return only;
        return hasSource ? null : all;
    }

    // Which form of each texture a mode draws, for answers: `form` of
    // TextureForm by `path`, -1 for the source. (The binder's own record of
    // what it uploaded is MaterialBinder.drawnForms.)
    formOf(path: string): i32 {
        const c = this.compressed(path);
        if (c == null || c.length == 0) return -1;
        return <i32>formOfBlockFormat(c[0].format);
    }
}

// Milestone 67b: whether one of `forms` was freed after its release
// (CompressedImage.freed: its texture's forms go together).
function anyFreed(forms: Array<CompressedImage>): bool {
    for (let i = 0; i < forms.length; i++) if (unchecked(forms[i]).freed) return true;
    return false;
}

// SceneRenderOptions.textures's TEXTURES_SOURCE (adapter.as, which imports
// this file: the value is repeated rather than imported back).
const TEXTURES_SOURCE_MODE: i32 = -2;

// One mesh resource as drawn: its GpuMesh, which road built it, and the
// bounds of its vertices in the mesh's own space.
export class SceneMesh {
    mesh: ArrayMesh;
    gpu: GpuMesh;
    // Built from the model's object (meshes.as, modelObjectMesh): in model
    // space, its ranges' slots are the object's material slots. Otherwise
    // from the triangle lists: in scene space, slot k is surface k.
    fromSource: bool;
    // The vertices' bounds (a point at the origin for an empty mesh).
    local: Bounds;
    // The cache's `epoch` when a plan last used it (`sweep`).
    seen: u32 = 0;

    constructor(mesh: ArrayMesh, gpu: GpuMesh, fromSource: bool) {
        this.mesh = mesh;
        this.gpu = gpu;
        this.fromSource = fromSource;
        this.local = vertexBounds(gpu);
    }
}

// (a mesh whose CPU copies were released keeps its box: ../../render/mesh.as
// vertexBox, the same numbers as the arrays gave)
function vertexBounds(g: GpuMesh): Bounds {
    return vertexBox(g);
}

// A MultiMesh's instances packed for one mesh entry (milestone 13): kept
// while the plans use it, so a MultiMesh is packed once and uploaded once.
// What they were packed from is kept beside them: the same MultiMesh
// object with other numbers (an edit made in place) is packed again.
class SceneInstances {
    multimesh: MultiMesh;
    mesh: SceneMesh;
    data: InstanceData;
    seen: u32 = 0;
    buffer: Array<f64>;
    numbers: i32;
    instanceCount: i32;
    stride: i32;
    useColors: bool;
    visible: i32;

    constructor(multimesh: MultiMesh, mesh: SceneMesh, data: InstanceData) {
        this.multimesh = multimesh;
        this.mesh = mesh;
        this.data = data;
        this.buffer = multimesh.buffer;
        this.numbers = multimesh.buffer.length;
        this.instanceCount = multimesh.instanceCount;
        this.stride = multimesh.stride();
        this.useColors = multimesh.useColors;
        this.visible = multimesh.visibleInstanceCount;
    }

    // `multimesh` still holds what `data` was packed from.
    current(): bool {
        const mm = this.multimesh;
        return mm.buffer === this.buffer && mm.buffer.length == this.numbers && mm.instanceCount == this.instanceCount
            && mm.stride() == this.stride && mm.useColors == this.useColors && mm.visibleInstanceCount == this.visible;
    }
}

// Milestone 19: the mesh a lightmapped item draws, built from its source
// mesh and its LightmapInstance (lightmap.as `lightmappedMesh`).
export class LightmapMesh {
    instance: LightmapInstance;
    source: GpuMesh;
    gpu: GpuMesh;
    seen: u32 = 0;

    constructor(instance: LightmapInstance, source: GpuMesh, gpu: GpuMesh) {
        this.instance = instance;
        this.source = source;
        this.gpu = gpu;
    }
}

// Milestone 19: what an item slot was matched to the last time a bake was
// put on a frame (lightmap.as): its node and part, the instance found for
// them (null: none), and the verdict on its source mesh at its world
// matrix, so an unchanged item is not hashed again. `drawn` is the mesh
// the item was given (the lightmapped one, or its source).
export class LightmapMatch {
    data: LightmapData? = null;
    node: SceneNode? = null;
    part: i32 = -1;
    instance: LightmapInstance? = null;
    source: GpuMesh? = null;
    world: Mat4 = MAT4_IDENTITY;
    fresh: bool = false;
    drawn: GpuMesh? = null;
    // The stale warning, made once.
    warning: string = "";
    // Milestone 67: what the slot's probe light (SceneRenderCache
    // .probeArray) was last interpolated from: the probe set, the point
    // looked up in the bake's frame (its bits) and the frame the light was
    // turned out of (its bits, when the bake's root had moved). The same
    // three give the same numbers, so applyLightmap keeps the array rather
    // than search every probe again for an item that did not move (Godot
    // looks an instance's probe light up when it moves, not every frame).
    shProbes: LightmapProbeSet? = null;
    shX: u32 = 0;
    shY: u32 = 0;
    shZ: u32 = 0;
    shMoved: bool = false;
    shFrame: Mat4 = MAT4_IDENTITY;
}

// Milestone 19: what applyLightmap put on the frame (SceneFrame.lightmapped
// and probeLit).
export class LightmapCounts {
    lightmapped: i32 = 0;
    probeLit: i32 = 0;
}

// Milestone 20: one drawn reflection probe slot of a frame (probes.as): the
// desc put on the frame, updated in place each plan, the node it was last
// made for with its path (the desc's key, worked out again only when the
// node changes) and its moved warning, made once.
export class ProbeSlot {
    desc: ReflectionProbeDesc = new ReflectionProbeDesc();
    node: ReflectionProbe? = null;
    key: string = "";
    moved: string = "";
}

// Milestone 48: what one node's skin and blend shapes keep (see the
// header), by part: 0 for a MeshInstance3D, the part's index for a
// ModelInstance3D's (ModelInstance3D.parts). Each is made on first use.
export class NodeDeform {
    node: SceneNode;
    seen: u32 = 0;
    private skins: Array<SkinState?> = [];
    private morphs: Array<MorphCache?> = [];
    private cpus: Array<CpuSkin?> = [];
    // A ModelInstance3D's file-pose palettes (skinning.as filePosePalette),
    // by part, and the model and object they were made for.
    private fixed: Array<Array<Mat4>?> = [];
    private fixedModel: Array<ModelResource?> = [];
    private fixedObject: Array<i32> = [];

    constructor(node: SceneNode) {
        this.node = node;
    }

    skin(part: i32): SkinState {
        while (this.skins.length <= part) this.skins.push(null);
        let s = unchecked(this.skins[part]);
        if (s == null) {
            s = new SkinState();
            this.skins[part] = s;
        }
        return s;
    }

    morph(part: i32): MorphCache {
        while (this.morphs.length <= part) this.morphs.push(null);
        let m = unchecked(this.morphs[part]);
        if (m == null) {
            m = new MorphCache();
            this.morphs[part] = m;
        }
        return m;
    }

    cpu(part: i32): CpuSkin {
        while (this.cpus.length <= part) this.cpus.push(null);
        let c = unchecked(this.cpus[part]);
        if (c == null) {
            c = new CpuSkin();
            this.cpus[part] = c;
        }
        return c;
    }

    // Part `part`'s file-pose palette of object `object` of `model`, made
    // once (null: the object is not skinned).
    filePose(part: i32, model: ModelResource, object: i32): Array<Mat4>? {
        while (this.fixed.length <= part) {
            this.fixed.push(null);
            this.fixedModel.push(null);
            this.fixedObject.push(-1);
        }
        if (unchecked(this.fixedModel[part]) !== model || unchecked(this.fixedObject[part]) != object) {
            this.fixed[part] = filePosePalette(model, object);
            this.fixedModel[part] = model;
            this.fixedObject[part] = object;
        }
        return unchecked(this.fixed[part]);
    }

    // The copies its blend shapes and wire skinning made, for `sweep`.
    copies(out: Array<GpuMesh>): void {
        for (let i = 0; i < this.morphs.length; i++) {
            const m = this.morphs[i];
            const d = m != null ? m.mesh : null;
            if (d != null) out.push(d.out);
        }
        for (let i = 0; i < this.cpus.length; i++) {
            const c = this.cpus[i];
            const g = c != null ? c.copy() : null;
            if (g != null) out.push(g);
        }
    }

    // Hands every copy changed without an uploader to `uploader`
    // (SceneRenderCache.upload).
    flush(uploader: MeshUploader, replaced: Array<GpuMesh>): void {
        for (let i = 0; i < this.morphs.length; i++) {
            const m = this.morphs[i];
            const d = m != null ? m.mesh : null;
            if (d != null && (d.stale || d.out.gpu == null)) d.flush(uploader, replaced);
        }
        for (let i = 0; i < this.cpus.length; i++) {
            const c = this.cpus[i];
            if (c != null) c.flush(uploader, replaced);
        }
    }
}

// A model's mesh cache (object ids are per model, so one cache per model).
class ModelMeshes {
    model: ModelResource;
    cache: ModelMeshCache;

    constructor(model: ModelResource, cache: ModelMeshCache) {
        this.model = model;
        this.cache = cache;
    }
}

// Milestone 67b: whether `mesh` is one of `m`'s (an object's mesh, or one
// built from its objects).
function meshOfModel(mesh: ArrayMesh, m: ModelResource): bool {
    const src = mesh.source;
    if (src != null && src.model === m) return true;
    for (let i = 0; i < m.objects.length; i++) if (m.objects[i].mesh === mesh) return true;
    return false;
}

// What forgetRanges leaves: read by seedRanges, never written.
const NO_RANGE_NODES: Array<SceneNode> = [];

export class SceneRenderCache {
    textures: SceneTextureFiles = new SceneTextureFiles();
    // The renderer this cache feeds draws into a half-float target
    // (FrameRenderer.halfFloat; a plan-only renderer says yes). Without one
    // `buildSceneFrame` warns that post-processing is not drawn, since the
    // renderer's own warning never reaches an answer.
    halfFloat: bool = true;
    // How many GPU meshes were built (tests see the cache hit).
    builds: u32 = 0;
    // By mesh resource, compared by identity (a scene holds a few dozen
    // meshes at most, so a list is enough).
    private meshes: Array<SceneMesh> = [];
    private models: Array<ModelMeshes> = [];
    // By MultiMesh and mesh entry, compared by identity (milestone 13).
    private instanceSets: Array<SceneInstances> = [];
    // The instances the last `sweep` dropped, for the caller to hand to
    // the renderer (their device buffers, if any, are still alive).
    goneInstances: Array<InstanceData> = [];
    // Instances packed again since the last sweep (their MultiMesh changed
    // in place): handed over with the next sweep's goneInstances.
    private repacked: Array<InstanceData> = [];
    // How many MultiMeshes were packed (tests see the cache hit).
    packs: u32 = 0;
    // Milestone 35: the dynamic instances of the CPUParticles3D nodes the
    // plans draw (each state's own InstanceData, kept on its node and
    // packed again as its particles move: ../particles/pack.as), with the
    // epoch a plan or a refresh last drew each; a sweep hands those no plan
    // drew since the mark over with goneInstances (their buffers released;
    // a node drawn again later uploads its data again).
    private particleSets: Array<InstanceData> = [];
    private particleSeen: Array<u32> = [];
    // Bumped by `mark`; every entry a plan uses takes the current value.
    private epoch: u32 = 0;
    // The last frame built with this cache and the node of each of its
    // items, for Godot's visibility-range hysteresis (`seedRanges`).
    private rangeFrame: RenderFrame? = null;
    private rangeNodes: Array<SceneNode> = [];
    // The caller's name for the view the range state above belongs to
    // (-1: none). The editor plans its free camera, its play frame and
    // every tab with one cache: a node drawn from one of those views must
    // not start drawn from another (`forgetRanges`).
    rangeView: i64 = -1;
    // Milestone 19 (lightmap.as): the lightmapped meshes, by instance; each
    // item slot's last match and its probe light; the counts of the last
    // frame; the tree and LightmapGI last looked at; and how many
    // lightmapped meshes were built (tests see the cache hit).
    private lightmapMeshes: Array<LightmapMesh> = [];
    lightmapMatches: Array<LightmapMatch> = [];
    private probeArrays: Array<Float32Array> = [];
    lightmapCounts: LightmapCounts = new LightmapCounts();
    lightmapTree: SceneTree? = null;
    lightmapGi: LightmapGI? = null;
    // applyLightmap's warning that a bake matches nothing, and the
    // LightmapGI it names (said once, then kept: a refreshed frame makes no
    // string).
    lightmapNoneGi: LightmapGI? = null;
    lightmapNoneSaid: string = "";
    // The instances of `lightmapKeysOf` by instanceKey.
    lightmapKeysOf: LightmapData? = null;
    lightmapKeys: Map<string, LightmapInstance> = new Map<string, LightmapInstance>();
    lightmapBuilds: u32 = 0;
    // Milestone 20 (probes.as): the tree last looked at, its
    // ReflectionProbes in tree order and its WorldEnvironment (looked for
    // once per tree); the drawn slots; the set every frame of this cache
    // is given (updated in place).
    probeTree: SceneTree? = null;
    // Milestone 34: and node.as treeOwnWorldsEpoch then (a probe under a
    // SubViewport whose own_world_3d changed is in another world now).
    probeWorlds: i32 = -1;
    probeNodes: Array<ReflectionProbe> = [];
    probeEnvironment: WorldEnvironment? = null;
    probeSlots: Array<ProbeSlot> = [];
    probeSet: ReflectionProbeSet = new ReflectionProbeSet();
    // Milestone 40: where this cache's meshes get their levels of detail
    // (meshes.as provideLods), ahead of the module's installed source: the
    // run time sets its bundle's here (SceneRuntime.useBundle), so each
    // built scene keeps its own levels however many share the module.
    lodSource: LodSource? = null;
    // Milestone 48 (see the header): by node (its serial: SceneNode.serial
    // says why), and in the order made.
    private deforms: Map<i32, NodeDeform> = new Map<i32, NodeDeform>();
    private deformList: Array<NodeDeform> = [];

    // Milestone 48: what node `node` keeps for its skin and blend shapes,
    // made on first use; marked used by this plan.
    deformOf(node: SceneNode): NodeDeform {
        if (this.deforms.has(node.serial)) {
            const d = this.deforms.get(node.serial);
            d.seen = this.epoch;
            return d;
        }
        const d = new NodeDeform(node);
        d.seen = this.epoch;
        this.deforms.set(node.serial, d);
        this.deformList.push(d);
        return d;
    }

    // How many nodes keep a skin or blend shapes (tests see a sweep drop
    // the dead ones).
    get deformCount(): i32 {
        return this.deformList.length;
    }

    // How many meshes are held (tests see a sweep drop the dead ones).
    get size(): i32 {
        return this.meshes.length;
    }

    // Starts the plan whose meshes the next `sweep` keeps.
    mark(): void {
        this.epoch++;
    }

    // Drops every mesh no plan used since the last `mark`, and every
    // model's MeshCache no kept mesh comes from, returning the dropped
    // GpuMeshes for the caller to hand to `FrameRenderer.retire` (their
    // device buffers, if any, are still alive). Call after the first plan
    // of a reloaded tree: the old tree's meshes are dead (the new tree's
    // resources are new objects), and a mesh the new tree hides from that
    // plan is simply built when it shows.
    sweep(): Array<GpuMesh> {
        const gone: Array<GpuMesh> = [];
        const kept: Array<SceneMesh> = [];
        for (let i = 0; i < this.meshes.length; i++) {
            const e = this.meshes[i];
            if (e.seen == this.epoch) kept.push(e);
            // (milestone 39: a bundle's prebuilt mesh is the bundle's, shared
            // by every cache and instance drawing it: dropped from this
            // cache, never retired by it)
            else if (e.mesh.prebuilt == null) gone.push(e.gpu);
        }
        this.meshes = kept;
        const models: Array<ModelMeshes> = [];
        for (let i = 0; i < this.models.length; i++) {
            const m = this.models[i];
            let used = false;
            for (let k = 0; k < kept.length && !used; k++) {
                const src = kept[k].mesh.source;
                used = src != null && src.model == m.model;
            }
            if (used) models.push(m);
        }
        this.models = models;
        const sets: Array<SceneInstances> = [];
        this.goneInstances = this.repacked;
        this.repacked = [];
        for (let i = 0; i < this.instanceSets.length; i++) {
            const e = this.instanceSets[i];
            if (e.seen == this.epoch) sets.push(e);
            else this.goneInstances.push(e.data);
        }
        this.instanceSets = sets;
        // Milestone 35: the particles' instances no plan drew since the mark.
        let lost = false;
        for (let i = 0; i < this.particleSets.length; i++) if (this.particleSeen[i] != this.epoch) lost = true;
        if (lost) {
            const keep = new Array<InstanceData>();
            const seen = new Array<u32>();
            for (let i = 0; i < this.particleSets.length; i++) {
                if (this.particleSeen[i] == this.epoch) {
                    keep.push(this.particleSets[i]);
                    seen.push(this.epoch);
                } else {
                    this.goneInstances.push(this.particleSets[i]);
                }
            }
            this.particleSets = keep;
            this.particleSeen = seen;
        }
        const lm: Array<LightmapMesh> = [];
        for (let i = 0; i < this.lightmapMeshes.length; i++) {
            const e = this.lightmapMeshes[i];
            if (e.seen == this.epoch) lm.push(e);
            else gone.push(e.gpu);
        }
        this.lightmapMeshes = lm;
        // Milestone 48: nodes no plan used since the mark (a reloaded tree's
        // old nodes) drop their palettes and copies.
        let dropped = false;
        for (let i = 0; i < this.deformList.length; i++) {
            if (this.deformList[i].seen != this.epoch) dropped = true;
        }
        if (dropped) {
            const keep: Array<NodeDeform> = [];
            for (let i = 0; i < this.deformList.length; i++) {
                const d = this.deformList[i];
                if (d.seen == this.epoch) {
                    keep.push(d);
                } else {
                    d.copies(gone);
                    this.deforms.delete(d.node.serial);
                }
            }
            this.deformList = keep;
        }
        return gone;
    }

    // Milestone 19: the kept lightmapped mesh of `instance` drawing
    // `source`, or null (lightmap.as builds it and hands it to
    // `keepLightmapMesh`). Marks it used by this plan.
    lightmapMesh(instance: LightmapInstance, source: GpuMesh, uploader: MeshUploader?): GpuMesh? {
        for (let i = 0; i < this.lightmapMeshes.length; i++) {
            const e = this.lightmapMeshes[i];
            if (e.instance === instance && e.source === source) {
                e.seen = this.epoch;
                if (uploader != null && e.gpu.gpu == null) uploader.upload(e.gpu);
                return e.gpu;
            }
        }
        return null;
    }

    keepLightmapMesh(instance: LightmapInstance, source: GpuMesh, gpu: GpuMesh, uploader: MeshUploader?): void {
        const e = new LightmapMesh(instance, source, gpu);
        e.seen = this.epoch;
        this.lightmapMeshes.push(e);
        this.lightmapBuilds++;
        if (uploader != null) uploader.upload(gpu);
    }

    // How many lightmapped meshes are held.
    get lightmapMeshCount(): i32 {
        return this.lightmapMeshes.length;
    }

    // Milestone 19: item slot `i`'s match (made on first use, then kept).
    lightmapMatch(i: i32): LightmapMatch {
        while (this.lightmapMatches.length <= i) this.lightmapMatches.push(new LightmapMatch());
        return unchecked(this.lightmapMatches[i]);
    }

    // Milestone 20: drawn probe slot `i` (made on first use, then kept).
    probeSlot(i: i32): ProbeSlot {
        while (this.probeSlots.length <= i) this.probeSlots.push(new ProbeSlot());
        return unchecked(this.probeSlots[i]);
    }

    // Milestone 19: item slot `i`'s probe light (SH_L1_FLOATS numbers,
    // made on first use, then kept: a frame's DrawItem.probeSh).
    probeArray(i: i32): Float32Array {
        while (this.probeArrays.length <= i) this.probeArrays.push(new Float32Array(SH_L1_FLOATS));
        return unchecked(this.probeArrays[i]);
    }

    // The instances of `mm` drawing the mesh entry `mesh` (milestone 13),
    // packed on first use (hedra_engine/render/instances.as): Godot's buffer as
    // written, a .modeler mesh (built Z up) taken to the scene's space by
    // each instance, as the adapter places one copy.
    instances(mm: MultiMesh, mesh: SceneMesh): InstanceData {
        for (let i = 0; i < this.instanceSets.length; i++) {
            const e = this.instanceSets[i];
            if (e.multimesh == mm && e.mesh == mesh) {
                e.seen = this.epoch;
                if (e.current()) return e.data;
                // Changed in place: packed again, the old one retired at the
                // next sweep.
                this.repacked.push(e.data);
                const fresh = new SceneInstances(mm, mesh, this.pack(mm, mesh));
                fresh.seen = this.epoch;
                this.instanceSets[i] = fresh;
                return fresh.data;
            }
        }
        const data = this.pack(mm, mesh);
        const e = new SceneInstances(mm, mesh, data);
        e.seen = this.epoch;
        this.instanceSets.push(e);
        return data;
    }

    // Milestone 35: marks a CPUParticles3D's instances drawn by this plan
    // (see `particleSets`), adding them the first time. Allocates nothing
    // once they are held (a refresh's every frame).
    keepParticles(data: InstanceData): void {
        const sets = this.particleSets;
        for (let i = 0; i < sets.length; i++) {
            if (unchecked(sets[i]) === data) {
                unchecked(this.particleSeen[i] = this.epoch);
                return;
            }
        }
        sets.push(data);
        this.particleSeen.push(this.epoch);
    }

    // How many CPUParticles3D instances are held (tests see a sweep drop
    // them).
    get particleCount(): i32 {
        return this.particleSets.length;
    }

    private pack(mm: MultiMesh, mesh: SceneMesh): InstanceData {
        this.packs++;
        return packInstances(mm.buffer, mm.instanceCount, mm.stride(), mm.useColors, mm.visibleInstanceCount,
            mesh.local, mesh.fromSource, MODEL_TO_SCENE);
    }

    // The GpuMesh of a mesh resource, built on first use (see the header)
    // and uploaded through `uploader` when it is not null and the mesh has
    // no device buffers yet.
    gpuMesh(mesh: ArrayMesh, uploader: MeshUploader?): GpuMesh {
        return this.entry(mesh, uploader).gpu;
    }

    // `gpuMesh` with what the adapter needs besides: which road built it
    // (for the materials of its ranges and its placement) and its bounds.
    // With `lods` (milestone 26: a frame with a level-of-detail threshold),
    // the mesh is given its levels (meshes.as provideLods) before its first
    // upload, so it is uploaded once with them.
    entry(mesh: ArrayMesh, uploader: MeshUploader?, lods: bool = false): SceneMesh {
        for (let i = 0; i < this.meshes.length; i++) {
            const e = this.meshes[i];
            if (e.mesh == mesh) {
                e.seen = this.epoch;
                this.ready(e.gpu, mesh, uploader, lods);
                return e;
            }
        }
        let e: SceneMesh? = null;
        // Milestone 39: a mesh from a built scene arrives built (the
        // GpuMesh this cache would have built, shared by every tree made
        // from the bundle, so uploaded once): taken as it is, placed as
        // the road that built it places it.
        const pre = mesh.prebuilt;
        if (pre != null) {
            e = new SceneMesh(mesh, pre.gpu, pre.modelSpace);
            e.seen = this.epoch;
            this.meshes.push(e);
            this.ready(e.gpu, mesh, uploader, lods);
            return e;
        }
        const src = mesh.source;
        const mc = src != null ? this.modelCache(src) : null;
        if (src != null && mc != null) {
            const before = mc.builds;
            const g = modelObjectMesh(src, mc, null);
            if (g != null) {
                if (mc.builds != before) this.builds++;
                e = new SceneMesh(mesh, g, true);
            }
        }
        // A mesh built in code, a model's object that is gone, or a model
        // with no source: its triangles, which the loader evaluated when the
        // model was read.
        if (e == null) {
            e = new SceneMesh(mesh, arrayMeshToGpu(mesh), false);
            this.builds++;
        }
        e.seen = this.epoch;
        this.meshes.push(e);
        this.ready(e.gpu, mesh, uploader, lods);
        return e;
    }

    // Levels first (when asked), then the upload a mesh without device
    // buffers needs. A mesh already uploaded that is given levels only now
    // (a frame with a threshold after frames without one) is uploaded
    // again: its old buffers go to `replaced` first, for the renderer to
    // release (`retireReplaced`), since the upload replaces
    // GpuMesh.gpu and nothing else holds them.
    //
    // Milestone 67b: under the run time's release policy (cpu_copy.as) the
    // levels are made before the first upload whatever the threshold, as
    // Godot makes them at import: the arrays go a frame after the upload,
    // and the bindable lodThreshold may rise above 0 later, when there
    // would be nothing left to make them from. At 0 the frame draws level
    // 0 alone (frame.as chooseLods), so the picture is the same.
    private ready(g: GpuMesh, mesh: ArrayMesh, uploader: MeshUploader?, lods: bool): void {
        const ahead = !lods && g.gpu == null && g.lods == null && !g.cpuReleased && cpuCopyPolicy() == CPU_COPY_RELEASE;
        const given = (lods || ahead) && provideLods(mesh, g, this.lodSource);
        if (uploader == null) return;
        if (g.gpu == null) {
            uploader.upload(g);
            return;
        }
        if (!given) return;
        const old = new GpuMesh();
        old.gpu = g.gpu;
        g.gpu = null;
        this.replaced.push(old);
        this.reuploads++;
        uploader.upload(g);
    }

    // Shells holding the device buffers of meshes uploaded again with their
    // levels (`ready`), until `retireReplaced` hands them to the renderer.
    replaced: Array<GpuMesh> = [];
    // How many meshes were uploaded again that way (tests count them).
    reuploads: u32 = 0;

    // The mesh cache of `src`'s model, made on first use; null when the
    // model has no source to build from (a built scene's, whose meshes are
    // prebuilt).
    private modelCache(src: ModelMeshSource): ModelMeshCache? {
        for (let i = 0; i < this.models.length; i++) {
            if (this.models[i].model == src.model) return this.models[i].cache;
        }
        const from = src.model.source;
        if (from == null) return null;
        const m = new ModelMeshes(src.model, from.meshCache());
        this.models.push(m);
        return m.cache;
    }

    // Milestone 67b (see the header): the mesh resource whose GpuMesh is `g`
    // (the scene mesh built or taken for it), or null.
    meshOfGpu(g: GpuMesh): ArrayMesh? {
        for (let i = 0; i < this.meshes.length; i++) {
            const e = unchecked(this.meshes[i]);
            if (e.gpu === g) return e.mesh;
        }
        return null;
    }

    // Milestone 67b: forgets what this cache keeps for `r`, which the run
    // time's resource cache freed: a texture's image and forms, a model's
    // meshes (by its objects', and by the meshes built from it) and its
    // mesh cache. Their device buffers are the resource's to release.
    forgetResource(r: Resource): void {
        if (r instanceof Texture2D) {
            const t = r as Texture2D;
            this.textures.forget(t.path, t.image, t.compressed);
            return;
        }
        if (!(r instanceof ModelResource)) return;
        const m = r as ModelResource;
        let drop = false;
        for (let i = 0; i < this.meshes.length && !drop; i++) drop = meshOfModel(this.meshes[i].mesh, m);
        if (drop) {
            const kept: Array<SceneMesh> = [];
            const gone: Array<SceneMesh> = [];
            for (let i = 0; i < this.meshes.length; i++) {
                const e = this.meshes[i];
                if (meshOfModel(e.mesh, m)) gone.push(e);
                else kept.push(e);
            }
            this.meshes = kept;
            this.dropDependents(gone);
        }
        for (let i = this.models.length - 1; i >= 0; i--) if (this.models[i].model === m) this.models.splice(i, 1);
    }

    // Milestone 67b: forgets the meshes drawn as `gpus` (a freed resource's:
    // a packed scene's primitives, a model's), and what was kept for them
    // (their MultiMeshes' instances, handed over with the next sweep's
    // goneInstances; their lightmapped copies, whose buffers go to
    // `replaced` for the renderer to release).
    forgetMeshes(gpus: Array<GpuMesh>): void {
        if (gpus.length == 0) return;
        let any = false;
        for (let i = 0; i < this.meshes.length && !any; i++) any = gpus.includes(this.meshes[i].gpu);
        if (!any) return;
        const kept: Array<SceneMesh> = [];
        const gone: Array<SceneMesh> = [];
        for (let i = 0; i < this.meshes.length; i++) {
            const e = this.meshes[i];
            if (gpus.includes(e.gpu)) gone.push(e);
            else kept.push(e);
        }
        this.meshes = kept;
        this.dropDependents(gone);
    }

    // Milestone 67b: forgets the meshes this cache built that the run
    // time's resources retired once no instance drew with the cache (each
    // cache builds its own from a model's objects and a scene's
    // primitives: ../runtime/runtime_resources.as leaveRenderCache), with
    // the model mesh caches no kept mesh comes from, so that a later plan
    // with this cache builds and uploads them anew.
    forgetBuilt(gpus: Array<GpuMesh>): void {
        this.forgetMeshes(gpus);
        const models: Array<ModelMeshes> = [];
        for (let i = 0; i < this.models.length; i++) {
            const m = this.models[i];
            let used = false;
            for (let k = 0; k < this.meshes.length && !used; k++) {
                const src = this.meshes[k].mesh.source;
                used = src != null && src.model == m.model;
            }
            if (used) models.push(m);
        }
        this.models = models;
    }

    // What was kept for the scene meshes `gone`: their instance sets and
    // their lightmapped copies.
    private dropDependents(gone: Array<SceneMesh>): void {
        if (gone.length == 0) return;
        const sets: Array<SceneInstances> = [];
        for (let i = 0; i < this.instanceSets.length; i++) {
            const e = this.instanceSets[i];
            if (gone.includes(e.mesh)) this.goneInstances.push(e.data);
            else sets.push(e);
        }
        this.instanceSets = sets;
        const lm: Array<LightmapMesh> = [];
        for (let i = 0; i < this.lightmapMeshes.length; i++) {
            const e = this.lightmapMeshes[i];
            let from = false;
            for (let k = 0; k < gone.length && !from; k++) from = gone[k].gpu === e.source;
            if (from) this.replaced.push(e.gpu);
            else lm.push(e);
        }
        this.lightmapMeshes = lm;
    }

    // Drops the range state `seedRanges` carries over, so the next frame
    // starts every node "not drawn", as a picture drawn alone does
    // (`render`). For a plan seen from another view than the last: the
    // hysteresis band is about one camera moving, and a state carried from
    // another camera would keep a node drawn (or hidden) that the new one
    // sees inside its margins.
    forgetRanges(): void {
        this.rangeFrame = null;
        // (one empty array, never written: `rangeNodes` is otherwise a
        // frame's own itemNodes, so it is replaced, not cleared)
        this.rangeNodes = NO_RANGE_NODES;
    }

    // Starts `f`'s visibility-range state (RenderFrame.rangeState, by item)
    // from the frame this cache last built: an item whose node was drawn
    // the last time that frame was culled starts drawn, so its margins act
    // as hysteresis across plans (the player builds a frame every draw;
    // the preview and the editor plan again on each change but a camera
    // move, which retargets the last frame and so keeps its state). The old frame's
    // state is read here, not copied back after each draw: cull.as updates
    // it in place whenever that frame is drawn, and a frame never culled
    // still holds the seed it was given. `nodes` is by item
    // (SceneFrame.itemNodes). A frame with no visibility range (every scene
    // before milestone 13) seeds nothing and allocates nothing.
    seedRanges(f: RenderFrame, nodes: Array<SceneNode>): void {
        const prev = this.rangeFrame;
        const prevNodes = this.rangeNodes;
        this.rangeFrame = f;
        this.rangeNodes = nodes;
        const items = f.items;
        const n = items.length;
        let any = false;
        for (let i = 0; i < n && !any; i++) {
            const d = unchecked(items[i]);
            any = d.rangeBegin > 0 || d.rangeEnd > 0;
        }
        if (!any || prev == null || prev === f) return;
        const was = prev.rangeState;
        const m = min<i32>(min<i32>(was.length, prevNodes.length), prev.items.length);
        if (m == 0) return;
        const state = f.rangeState;
        if (state.length < n) state.length = n;
        // Most plans draw the same tree in the same order: an item is
        // looked for at its own index first, by the same node. Otherwise
        // it is looked for by the node's path, not the node: the editor
        // instances a new tree after every edit, undo and redo, so every
        // node is a new object, and a node that keeps its path keeps its
        // state (a removed or renamed one starts from "not drawn"). The
        // paths are built only when the tree changed.
        let byPath: Map<string, bool>? = null;
        for (let i = 0; i < n && i < nodes.length; i++) {
            const d = unchecked(items[i]);
            if (!(d.rangeBegin > 0 || d.rangeEnd > 0)) continue;
            const node = unchecked(nodes[i]);
            if (i < m && unchecked(prevNodes[i]) === node) {
                unchecked(state[i] = unchecked(was[i]));
                continue;
            }
            if (byPath == null) {
                const map = new Map<string, bool>();
                // (a node's items are culled alike: its first is taken)
                for (let k = m - 1; k >= 0; k--) map.set(unchecked(prevNodes[k]).path(), unchecked(was[k]));
                byPath = map;
            }
            const map = byPath as Map<string, bool>;
            const key = node.path();
            if (map.has(key)) unchecked(state[i] = map.get(key));
        }
    }

    // Uploads every mesh of `f`'s items that has no device buffers yet.
    // Call in the host's draw, before renderFrame: buildSceneFrame builds
    // the meshes on the CPU when it plans a render without a device.
    // Hands the buffers of meshes uploaded again (`replaced`) to `r`, which
    // releases them at its next beginFrame. Every caller of `upload` calls
    // it beside, so a re-upload never strands the buffers it replaced;
    // nothing to hand over (every frame but such a one) allocates nothing.
    retireReplaced(r: FrameRenderer): void {
        const n = this.replaced.length;
        if (n == 0) return;
        for (let i = 0; i < n; i++) r.retire(this.replaced[i]);
        this.replaced.length = 0;
    }

    upload(f: RenderFrame, uploader: MeshUploader): void {
        // Milestone 48: a node's copies blended or skinned in a plan made
        // without a device (morph.as DeformedMesh.stale) first, written in
        // place, or uploaded anew with their old buffers in `replaced`.
        for (let i = 0; i < this.deformList.length; i++) this.deformList[i].flush(uploader, this.replaced);
        for (let i = 0; i < f.items.length; i++) {
            const g = f.items[i].mesh;
            if (g != null && g.gpu == null) uploader.upload(g);
        }
    }
}
