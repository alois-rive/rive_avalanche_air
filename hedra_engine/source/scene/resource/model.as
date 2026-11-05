// Models: a model file (.rmdl, .rmdlcmd) or a glTF file (.gltf, .glb) read
// into the shared model (shared/src/model: a Scene, Z up) and turned into
// what a scene needs (types.as, ModelResource): one ModelObject per object, parents
// first, with its transform relative to its parent in scene space
// (../space.as), a mesh's evaluated triangles (modifiers applied, as Hedra
// draws them) in scene space, the materials as StandardMaterial3D with
// their textures, and each camera and light as the node properties of
// format 1. Milestone 48: its skeletons, skins, bone attachments and blend
// shapes (model_skeleton.as, model_morphs.as) and its animations as clips
// (model_clips.as); a glTF file's are read from its document, which the
// importer keeps for it (ImportOpts.keepDocument). Every format takes the same road after reading, so a model looks
// the same whichever file it came from: a material is glTF's whole material
// first (a glTF file's as the importer reads it with ImportOpts.pbr, a
// model file's through engine/src/source/material/model_pbr.as), then a
// StandardMaterial3D through pbr_map.as, as every material of Hedra.
// docs/formats/RSCN.md, "Models", states the conversion.
//
// Loading a model changes nothing on disk: the images a glTF file embeds,
// which Hedra's import writes out as files, are kept in memory here
// (MemoryImages) and decoded from there.
//
// The two model files (engine/src/source/model/formats.as tells them
// apart by their extension):
//
// - an .rmdl (docs/formats/RMDL.md) is the model as a document: it is read
//   (engine/src/source/model/rmdl/read.as readRmdl) straight into the
//   shared model's Scene, without the command kernel and without a cache,
//   so every program reads it, the player of a built project included. A
//   document that does not read is the reader's SceneryError, at its line
//   and column in the model file; the loader adds the scene that named it.
//   What the read warns about (content a rewrite would drop, an unused
//   resource) stays a warning of the model, with its own code and place
//   (ModelResource.readWarnings);
// - an .rmdlcmd (docs/formats/RMDLCMD.md) is the commands that build the
//   model; it is loaded through engine/src/source/model/rmdlcmd/load.as
//   (ModelFormat.Modeler: Hedra's scene). In order: a cache entry for the
//   whole file, its data form, a packed scene's entry (wholeCacheEntry),
//   and its commands replayed by Hedra's kernel where the program installed
//   it (Hedra's CLI and editor: engine/src/commands/replayer.as); a program
//   without the kernel (the player of a built project) fails with
//   model-needs-commands at the first command line instead.
//
// Milestone 61: an .rmdl Material with a `shader` (RMDL.md section 5; the
// document's head keeps it, ../../model/rmdl/doc.as RmdlShader) is a
// ShaderMaterial whose fallback is the material as it would be without
// one (its own settings, or its MaterialX file's), its shader loaded and
// cached as a Shader ext_resource of a scene is, its parameters declared
// as an .rscn's (a texture's loaded as the material's slots are). A shader
// that cannot be read is a warning of the model, and the material draws
// its fallback; a shader of an instanced model's material (composed in) is
// not kept.
//
// The helpers at the end (rmdlDocumentFiles for an .rmdl; rmdlNamedFiles,
// rmdlCacheEntries, cacheEntryFiles for an .rmdlcmd) are what Hedra's
// prefetchers and the editor's closure ask for ahead of a load.

import { Result, toAsciiLowercase } from "../../../base/util";
import { applyModelImport, modelImportSettings } from "../import/model_import";
import { Vec2, Vec3, toDegrees } from "../../../base/vecmath";
import { linearToSrgbValue } from "../../../base/color";
import { normalizeAbs } from "../../../fs/path";
import { isValidUtf8, vfs } from "../../../fs/vfs";
import { Image } from "../../../render/image";
import { CameraKind, LightKind, ModifierKindTag, NO_OBJ, ObjectDataKind, Scene, TextureRef } from "../../model/scene";
import { decode } from "../../model/file";
import { ModelFileKind, modelFileKind } from "../../model/formats";
import { RmdlError, rmdlErrorOf } from "../../model/rmdlcmd/format";
import { readRmdl } from "../../model/rmdl/read";
import { RmdlHead } from "../../model/rmdl/doc";
import { shaderMaterialFrom } from "../../../scene/resource/shader";
import { shaderThroughTextures } from "../../../scene/resource/loader";
import { parseValue } from "../../../scene/value_text";
import { rmdlLoadedPaths } from "../../model/rmdl/scan";
import { RmdlDoc } from "../../model/rmdlcmd/doc";
import {
    CacheHit, RMDL_CACHE_KEEP, cacheDirOf, cacheFileName, decodeCacheEntry, depHash, parseCacheFileName, prefixBytes, prefixKey,
    stemOf,
} from "../../model/rmdlcmd/cache";
import { EntryProbe, RmdlLoad, enterModelTools, leaveModelTools, loadRmdlBytes } from "../../model/rmdlcmd/load";
import { namesToolModifier, referencedPaths } from "../../model/rmdlcmd/scan";
import { Mesh as ModelMesh } from "../../model/mesh/mod";
import { triangulateFaceInto } from "../../model/mesh/triangulate";
import { validateMesh } from "../../model/mesh/validate";
import { GltfImportMap, ImageSink, ImportOpts, import_ } from "../../io/gltf_to_model/gltf_import";
import { PBR_EXTENSIONS } from "../../io/gltf_to_model/import_pbr";
import { PbrMaterial, PbrSlot } from "../../../material/pbr";
import { pbrFromModelMaterial } from "../../material/model_pbr";
import { majorFov } from "../../io/core/camera_light";
import { Diagnostic, SceneryError } from "../../../scene/error";
import { Value } from "../../../scene/value";
import { modelToScene } from "../../../scene/space";
import {
    ArrayMesh, MeshSurface, ModelFormat, ModelMeshSource, ModelObject, ModelResource, StandardMaterial3D, Texture2D,
} from "../../../scene/resource/types";
import { PbrTextures, standardFromPbr } from "../../../scene/resource/pbr_map";
import { FILE_READ_HINT, MODEL_LOAD_HINT, TextureSource } from "../../../scene/resource/model_hints";
import { KernelModelSource } from "./model_source";
import { ModelReading, objectSceneLocal, readGltfSkeletons, readSceneSkeletons } from "./model_skeleton";
import { readGltfClips, readSceneClips } from "./model_clips";
import { ModelFiles, ModelSource as ModelFileSource, composeScene } from "../../model/compose";
import { readMtlx } from "../../material/mtlx";
// (what every model load names: model_hints.as, which the loader imports
// without this file)
export {
    FILE_READ_HINT, MODEL_LOAD_HINT, TEXTURE_DECODE_HINT, TextureSource, extPathHint,
} from "../../../scene/resource/model_hints";


// The distance a glTF point or spot light reaches: glTF lights have no
// cut-off, and Godot's range is one, so it is set far beyond any scene.
const UNBOUNDED_RANGE: f64 = 4096;

// Watts per unit of Godot's light_energy for point, spot and area lights:
// Hedra's default 1000 W lamp becomes Godot's default energy of 1.
// Decided: RSCN.md's Models section says why, and its Rendering section
// how Hedra draws the energy.
const WATTS_PER_ENERGY: f32 = 1000;

// A glTF file's embedded images, kept by the importer's ImageSink hook
// under `<abs model path>#<file>` instead of being written next to the
// project.
class MemoryImages extends ImageSink {
    modelPath: string;
    bytes: Map<string, Uint8Array> = new Map<string, Uint8Array>();

    constructor(modelPath: string) {
        super();
        this.modelPath = modelPath;
    }

    store(index: i32, file: string, bytes: Uint8Array): Result<string> {
        const key = this.modelPath + "#" + file;
        // A copy: the importer's buffers are not ours to keep alive.
        this.bytes.set(key, bytes.slice(0));
        return Result.okv<string>(key);
    }
}

function isPngName(file: string): bool {
    return toAsciiLowercase(file).endsWith(".png");
}

// Textures for one model: its embedded images (decoded once, on first
// use), then the loader's source for files.
class ModelTextures extends TextureSource {
    images: MemoryImages;
    files: TextureSource;
    display: string;
    decoded: Map<string, Texture2D?> = new Map<string, Texture2D?>();
    failures: Map<string, string> = new Map<string, string>();

    constructor(images: MemoryImages, files: TextureSource, display: string) {
        super();
        this.images = images;
        this.files = files;
        this.display = display;
    }

    texture(path: string): Texture2D? {
        if (!this.images.bytes.has(path)) {
            const t = this.files.texture(path);
            this.why = this.files.why;
            return t;
        }
        if (!this.decoded.has(path)) this.decode(path);
        const t = this.decoded.get(path);
        if (t == null) this.why = this.failures.get(path);
        return t;
    }

    material(path: string): StandardMaterial3D? {
        const m = this.files.material(path);
        this.why = this.files.why;
        return m;
    }

    // An embedded image by the model's display path, as the Texture2D's
    // `file` names it (its key holds the model's absolute path).
    shown(path: string, written: string): string {
        if (!this.images.bytes.has(path)) return written;
        return this.display + "#" + path.substring(this.images.modelPath.length + 1);
    }

    private decode(key: string): void {
        const file = key.substring(this.images.modelPath.length + 1);
        if (!isPngName(file)) {
            this.decoded.set(key, null);
            this.failures.set(key, "the embedded image is not a PNG image");
            return;
        }
        const img = Image.decodePng(this.images.bytes.get(key));
        if (!img.ok) {
            this.decoded.set(key, null);
            this.failures.set(key, "the embedded image is not a PNG image: " + img.err);
            return;
        }
        const t = new Texture2D();
        t.image = img.value;
        t.width = <i32>img.value.width;
        t.height = <i32>img.value.height;
        t.path = key;
        t.file = this.display + "#" + file;
        t.name = file;
        this.decoded.set(key, t);
    }
}

function lowerExtension(abs: string): string {
    const slash = abs.lastIndexOf("/");
    const dot = abs.lastIndexOf(".");
    if (dot <= slash + 1) return "";
    return toAsciiLowercase(abs.substring(dot + 1));
}

function dirOfPath(abs: string): string {
    const slash = abs.lastIndexOf("/");
    return slash <= 0 ? "/" : abs.substring(0, slash);
}


function modelLoadError(display: string, message: string): Result<ModelResource> {
    return SceneryError.at("model-load", display, 0, 0, "cannot load model " + display + ": " + message, MODEL_LOAD_HINT).fail<ModelResource>();
}

// Reads a model file through the vfs: an .rmdl with its reader (no kernel,
// no cache), an .rmdlcmd as its commands load (loadRmdlScene), .gltf and
// .glb with the shared glTF importer (shared/src/io/import), and converts
// it (modelFromScene). `display` is how errors name the file.
// Textures are loaded through `textures` (the loader's), so a missing one
// is a warning on the model, not an error.
//
// A model that has a tool modifier is converted with the tools beside it
// installed (load.as enterModelTools: the stack's evaluation needs the
// tool, and the kernel's replay of `modifier add tool <name>` too, for an
// .rmdlcmd of commands), which are put back once the scene is converted. A
// program without the kernel installs none: the modifier is then left out,
// with the warning the stack gives.
export function loadModelFile(abs: string, display: string, textures: TextureSource): Result<ModelResource> {
    if (modelFileKind(abs) != ModelFileKind.Commands) return loadModelFileWith(abs, display, textures);
    const bytes = vfs.read(abs);
    const tools = bytes.ok && namesToolModifier(bytes.value);
    if (tools) enterModelTools(abs);
    const r = loadModelFileWith(abs, display, textures);
    if (tools) leaveModelTools();
    return r;
}

function loadModelFileWith(abs: string, display: string, textures: TextureSource): Result<ModelResource> {
    const kind = modelFileKind(abs);
    const baseDir = dirOfPath(abs);
    let scene: Scene;
    let format: ModelFormat;
    let source: TextureSource = textures;
    const importWarnings = new Array<string>();
    let readWarnings: Array<Diagnostic>? = null;
    let pbr: Array<PbrMaterial>? = null;
    let gltf: GltfImportMap? = null;
    let head: RmdlHead? = null;
    // A file that cannot be read is file-read, whatever its format, as for
    // every other resource (the importer would say it in its own words).
    const bytes = vfs.read(abs);
    if (!bytes.ok) {
        return SceneryError.at("file-read", display, 0, 0, "cannot read " + display + ": " + bytes.err, FILE_READ_HINT).fail<ModelResource>();
    }
    if (kind == ModelFileKind.Snapshot) {
        // (the reader's errors are SceneryErrors at their place in the
        // file, named as `display` names it: passed on as they are)
        const read = readRmdl(bytes.value, display);
        if (!read.ok) return read.forward<ModelResource>();
        scene = read.value.scene;
        format = ModelFormat.Modeler;
        readWarnings = read.value.warnings.items;
        head = read.value.head;
    } else if (kind == ModelFileKind.Commands) {
        const loaded = loadRmdlScene(abs, display, bytes.value);
        if (!loaded.ok) return loaded.forward<ModelResource>();
        scene = loaded.value;
        format = ModelFormat.Modeler;
    } else if (kind == ModelFileKind.Gltf) {
        scene = new Scene();
        const images = new MemoryImages(abs);
        const opts = gltfReadOpts(baseDir, images);
        const r = import_(scene, abs, opts);
        if (!r.ok) return modelLoadError(display, r.err);
        for (let i = 0; i < r.value.warnings.length; i++) importWarnings.push(r.value.warnings[i]);
        pbr = r.value.pbrMaterials;
        gltf = r.value.gltf;
        format = ModelFormat.Gltf;
        source = new ModelTextures(images, textures, display);
    } else {
        return modelLoadError(display, "a model is an .rmdl, .rmdlcmd, .gltf or .glb file");
    }
    // A document's tool modifiers are evaluated with their tools (an
    // .rmdlcmd's are entered around the whole load: loadModelFile).
    const tools = kind == ModelFileKind.Snapshot && hasToolModifier(scene);
    if (tools) enterModelTools(abs);
    const m = modelFromScene(scene, format, baseDir, source, pbr, gltf, abs, head);
    if (tools) leaveModelTools();
    // The importer's warnings come first: they are about the file as read.
    for (let i = importWarnings.length - 1; i >= 0; i--) m.warnings.unshift(importWarnings[i]);
    if (readWarnings != null) m.readWarnings = readWarnings;
    // Milestone 26: the model's import settings (its .import beside it:
    // root scale, up axis, light baking), when it has some that are not
    // the defaults; a model without one loads exactly as before.
    const settings = modelImportSettings(abs);
    if (!settings.ok) m.warnings.push(settings.err + "; loaded with the default import settings");
    else if (!settings.value.isDefault()) applyModelImport(m, settings.value);
    m.path = abs;
    m.file = display;
    return Result.okv<ModelResource>(m);
}

// How a scene reads a glTF file (`images` keeps its embedded images).
function gltfReadOpts(baseDir: string, images: ImageSink): ImportOpts {
    const opts = new ImportOpts();
    opts.baseDir = baseDir;
    // A scene reads the model as it is: nothing selected, the pose at
    // rest (no actions), shape keys and cameras and lights kept. Its
    // skins, morph targets and animations are read from the document
    // itself (model_skeleton.as, model_clips.as), which the import
    // keeps for that, so the skipped actions are no loss to warn of.
    opts.select = false;
    opts.animations = false;
    opts.keepDocument = true;
    opts.warnSkippedAnimations = false;
    // Bones parented to joints whose axes do not run along them pose
    // at rest as the identity, so what hangs on a bone sits where the
    // file puts it (import_skins.as).
    opts.carryJointFrames = true;
    opts.morphTargets = true;
    opts.cameras = true;
    opts.lights = true;
    opts.imageSink = images;
    // Each material whole (every glTF material extension, texCoord and
    // KHR_texture_transform), and a file that requires one of those
    // extensions is read rather than refused.
    opts.pbr = true;
    opts.extensions = PBR_EXTENSIONS.slice(0);
    return opts;
}

// Whether an object of `scene` has a tool modifier (a user tool's, which
// the stack evaluates through the tools beside the model).
function hasToolModifier(scene: Scene): bool {
    const bound = scene.objects.idBound();
    for (let id: u32 = 0; id < bound; id++) {
        const o = scene.objects.get(id);
        if (o == null) continue;
        for (let k = 0; k < o.modifiers.length; k++) if (o.modifiers[k].kind.tag == ModifierKindTag.Tool) return true;
    }
    return false;
}

// --- conversion --------------------------------------------------------------

// A light's colour is linear in the shared model (as glTF's and Blender's);
// the format's is sRGB.
function srgb(c: f32): f32 {
    return linearToSrgbValue(c);
}

// Where a texture path of the model points: an absolute path (an embedded
// image's key is one) as it is, else relative to the model's directory.
function texturePath(baseDir: string, path: string): string {
    if (path.startsWith("/")) return path;
    return normalizeAbs(baseDir + "/" + path);
}

// The order a material's textures are fetched in, so that the warnings
// about the ones that cannot be had come in the order they always have:
// glTF's core textures as the importer reads them (base colour,
// metallic-roughness, normal, emission, occlusion), then the extensions'.
const FETCH_ORDER: Array<i32> = [
    PbrSlot.BaseColor, PbrSlot.Metallic, PbrSlot.Roughness, PbrSlot.Normal, PbrSlot.Emissive, PbrSlot.Occlusion,
    6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
];

// One material's textures for standardFromPbr, fetched beforehand (see
// materialOf): a PbrTexture's path as the model wrote it -> its Texture2D.
class FetchedTextures extends PbrTextures {
    byPath: Map<string, Texture2D?> = new Map<string, Texture2D?>();

    textureOf(path: string): Texture2D? {
        return this.byPath.has(path) ? this.byPath.get(path) : null;
    }
}

// A model's material as the format's: its textures fetched through
// `textures` (relative paths from the model's directory), a warning for
// each one that cannot be had, then standardFromPbr (pbr_map.as), the road
// every material of Hedra takes.
//
// A texture that cannot be had leaves its slot empty, so its feature
// (normal map, occlusion, a clearcoat texture, ...) is drawn without it,
// except an emission texture: emission stays on, drawing the emissive
// colour, as it always has for a model.
function materialOf(src: PbrMaterial, baseDir: string, textures: TextureSource, warnings: Array<string>): StandardMaterial3D {
    const p = src.clone();
    const fetched = new FetchedTextures();
    for (let k = 0; k < FETCH_ORDER.length; k++) {
        const slot = FETCH_ORDER[k];
        const pt = p.texture(slot);
        if (pt == null) continue;
        // glTF's metallic-roughness texture fills two slots: fetched (and
        // warned about) once, for Metallic, and Roughness follows it.
        if (slot == PbrSlot.Roughness) {
            const mt = src.texture(PbrSlot.Metallic);
            if (mt != null && mt.path == pt.path) {
                if (p.texture(PbrSlot.Metallic) == null) p.setTexture(slot, null);
                continue;
            }
        }
        if (!fetched.byPath.has(pt.path) || fetched.byPath.get(pt.path) == null) {
            const path = texturePath(baseDir, pt.path);
            const t = textures.texture(path);
            if (t == null) warnings.push("texture " + textures.shown(path, pt.path) + " of material '" + src.name + "': " + textures.why);
            fetched.byPath.set(pt.path, t);
        }
        if (fetched.byPath.get(pt.path) == null && slot != PbrSlot.Emissive) p.setTexture(slot, null);
    }
    return standardFromPbr(p, fetched);
}

// Milestone 61: `made`, or the ShaderMaterial the head gives the material
// `name` (see the header): `made`'s settings its fallback (`made` itself
// unchanged: a MaterialX file's material is the loader's, shared), its
// parameters declared, then its shader set (which maps them).
function withShader(made: StandardMaterial3D, name: string, head: RmdlHead?, baseDir: string, textures: TextureSource,
    warnings: Array<string>): StandardMaterial3D {
    if (head == null) return made;
    const sh = head.shaderOf(name);
    if (sh == null) return made;
    const sm = shaderMaterialFrom(made);
    for (let k = 0; k < sh.params.length; k++) {
        const tex = sh.textures[k];
        if (tex.length > 0) {
            const tabs = texturePath(baseDir, tex);
            const t = textures.texture(tabs);
            if (t == null) {
                warnings.push("texture " + textures.shown(tabs, tex) + " of material '" + name + "'s shader_parameter/" + sh.params[k] + ": "
                    + textures.why);
                continue;
            }
            sm.declare(sh.params[k], Value.extResource(tex), t);
            continue;
        }
        const v = parseValue(sh.values[k]);
        if (v.ok) sm.declare(sh.params[k], v.value, null);
    }
    const abs = texturePath(baseDir, sh.path);
    const shader = shaderThroughTextures(textures, abs);
    if (shader == null) {
        warnings.push("material '" + name + "': cannot read its shader " + sh.path + ": " + textures.why + "; it is drawn with its own settings");
    }
    sm.setShader(shader);
    return sm;
}

function pushVec3(a: Array<f32>, v: Vec3): void {
    a.push(v.x);
    a.push(v.y);
    a.push(v.z);
}

// The evaluated mesh's triangles, per material slot (ascending), one
// vertex per triangle corner: positions and normals in scene space, the
// active UV layer flipped to a top-left origin.
function convertMesh(mesh: ModelMesh, name: string, slots: Array<u32>, materials: Array<StandardMaterial3D>): ArrayMesh {
    const fb = mesh.faces.idBound();
    // Smooth normals as Hedra draws and exports them (hedra_engine/source/render/meshbuild.as,
    // io/export/geometry.as): the sum of the normals of the smooth faces
    // around a vertex, normalised; a flat face uses its own normal.
    const faceNormals = new Array<Vec3>(<i32>fb);
    for (let i = 0; i < <i32>fb; i++) faceNormals[i] = Vec3(0, 0, 0);
    const vb = <i32>mesh.verts.idBound();
    const vsum = new Array<Vec3>(vb);
    for (let i = 0; i < vb; i++) vsum[i] = Vec3(0, 0, 0);
    const used = new Array<i32>();
    for (let id: u32 = 0; id < fb; id++) {
        const f = mesh.faces.get(id);
        if (f == null || f.loopLen < 3) continue;
        const n = mesh.computeFaceNormal(id);
        faceNormals[<i32>id] = n;
        if (!used.includes(<i32>f.materialIndex)) used.push(<i32>f.materialIndex);
        if (!f.smooth) continue;
        for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
            const v = <i32>mesh.loops.at(l).vert;
            vsum[v] = vsum[v] + n;
        }
    }
    used.sort((a: i32, b: i32): i32 => a - b);
    const hasUv = mesh.uvLayers.length > 0;
    const layer = hasUv ? <i32>(mesh.activeUv < <u32>mesh.uvLayers.length ? mesh.activeUv : 0) : 0;
    const out = new ArrayMesh();
    out.name = name;
    const tris = new Array<u32>();
    for (let k = 0; k < used.length; k++) {
        const slot = used[k];
        const s = new MeshSurface();
        if (slot < slots.length) {
            const mi = <i32>slots[slot];
            if (mi >= 0 && mi < materials.length) s.material = materials[mi];
        }
        for (let id: u32 = 0; id < fb; id++) {
            const f = mesh.faces.get(id);
            if (f == null || f.loopLen < 3 || <i32>f.materialIndex != slot) continue;
            tris.length = 0;
            triangulateFaceInto(mesh, id, tris);
            const fn = faceNormals[<i32>id];
            for (let c = 0; c < tris.length; c++) {
                const loop = mesh.loops.at(tris[c]);
                const n = f.smooth ? vsum[<i32>loop.vert].normalizeOrZero() : fn;
                pushVec3(s.positions, modelToScene(mesh.verts.at(loop.vert).co));
                pushVec3(s.normals, modelToScene(n));
                if (hasUv) {
                    const uv = layer < loop.uv.length ? loop.uv[layer] : Vec2(0, 0);
                    s.uvs.push(uv.x);
                    s.uvs.push(<f32>1 - uv.y);
                }
                s.indices.push(<u32>s.indices.length);
            }
        }
        out.surfaces.push(s);
    }
    out.computeBounds();
    return out;
}

function float(x: f32): Value {
    return Value.float(<f64>x);
}

function setProp(o: ModelObject, name: string, v: Value): void {
    o.propNames.push(name);
    o.propValues.push(v);
}

// Converts a loaded shared-model Scene: evaluates every mesh object, builds
// the objects, materials and node properties. `baseDir` is the directory
// texture paths are relative to (the model file's).
//
// `pbr` holds the materials whole (a glTF import's ImportReport.pbrMaterials,
// aligned with scene.materials); null takes them from the shared model's
// (pbrFromModelMaterial), which is all an .rmdl has.
//
// `gltf` (milestone 48): the document a glTF import kept (ImportReport.gltf),
// from which the skeletons, skins and clips are read; null reads them from
// the scene's armatures and actions, as for an .rmdl.
//
// A model whose empties instance other models is converted with them put
// in (../../model/compose.as: their objects under the empty's node, as
// Godot places an instanced scene's), read through the vfs from `baseDir`
// (absolute, as the loader's paths are); `path` is the model's own file,
// so that an instance of it is the cycle it is. A material that is a
// MaterialX file is that file's material, loaded through `textures` as an
// .rscn's Material ext_resource is (the loader caches and reports it); one
// that cannot be had is a warning, and the material its own settings.
// Milestone 61: `head` (an .rmdl's) gives the materials that are
// ShaderMaterials (see the header).
export function modelFromScene(scene: Scene, format: ModelFormat, baseDir: string, textures: TextureSource,
    pbr: Array<PbrMaterial>? = null, gltf: GltfImportMap? = null, path: string = "", head: RmdlHead? = null): ModelResource {
    const m = new ModelResource();
    const composed = composeScene(scene, baseDir, new FileModelFiles(), false, path);
    for (let i = 0; i < composed.warnings.length; i++) m.warnings.push(composed.warnings[i]);
    scene = composed.scene;
    const source = new KernelModelSource(scene, format);
    m.source = source;
    m.format = format;
    for (let i = 0; i < scene.materials.length; i++) {
        const mat = scene.materials[i];
        const file = mat.file;
        if (file != null) {
            const abs = texturePath(baseDir, file);
            const loaded = textures.material(abs);
            if (loaded != null) {
                m.materials.push(withShader(loaded, mat.name, head, baseDir, textures, m.warnings));
                continue;
            }
            m.warnings.push("material '" + mat.name + "': cannot read its MaterialX file " + file + ": " + textures.why
                + "; it is drawn with its own settings");
        }
        const fromFile = i < composed.pbr.length ? composed.pbr[i] : null;
        const whole = pbr != null && i < pbr.length ? pbr[i] : fromFile != null ? fromFile : pbrFromModelMaterial(mat);
        m.materials.push(withShader(materialOf(whole, baseDir, textures, m.warnings), mat.name, head, baseDir, textures, m.warnings));
    }

    // Depth first from the top-level objects, children in id order (a
    // stack of ids, pushed in reverse so that they pop in order).
    const order = new Array<u32>();
    const parentOf = new Array<i32>();
    const stack = new Array<u32>();
    const stackParent = new Array<i32>();
    const bound = scene.objects.idBound();
    for (let id: u32 = bound; id > 0; id--) {
        const o = scene.objects.get(id - 1);
        if (o == null) continue;
        const p = o.parent;
        if (p != null && scene.objects.contains(p.id) && p.id != id - 1) continue;
        stack.push(id - 1);
        stackParent.push(-1);
    }
    while (stack.length > 0) {
        const id = stack.pop();
        const parent = stackParent.pop();
        const index = order.length;
        order.push(id);
        parentOf.push(parent);
        const kids = scene.children(id);
        for (let k = kids.length - 1; k >= 0; k--) {
            if (kids[k] == id) continue;
            stack.push(kids[k]);
            stackParent.push(index);
        }
    }

    // Local matrices in model space: the transform relative to the parent's
    // world, which is `parentInverse * transform` (Scene.worldMatrix) and
    // is read directly rather than through an inverse, so that a node's
    // transform comes out as the file wrote it.
    for (let i = 0; i < order.length; i++) {
        const id = order[i];
        const obj = scene.objects.at(id);
        const kind = obj.data.kind;
        const out = new ModelObject();
        out.name = obj.name;
        out.parent = parentOf[i];
        out.visible = !(obj.hide || obj.hideRender);

        out.local = objectSceneLocal(scene, id, out.parent < 0 ? NO_OBJ : order[out.parent], format);

        switch (kind) {
            case ObjectDataKind.Mesh: {
                out.className = "MeshInstance3D";
                // The modifiers assume a well-formed mesh and stop the
                // program on a broken one, so a broken mesh (a damaged or
                // hand-made file) is checked first and left out, with a
                // warning, rather than taking the whole scene down.
                const base = obj.data.mesh();
                if (base == null) break;
                const valid = validateMesh(base);
                if (!valid.ok) {
                    m.warnings.push("mesh '" + obj.name + "' is malformed (" + valid.err + "); it is left out");
                    break;
                }
                const cow = scene.evaluatedMesh(id);
                // A modifier the stack left out (a tool not beside the
                // model, a program with no tool evaluator) is a warning on
                // the model, as Hedra gives it, not a silent difference.
                const said = scene.stackWarnings(id);
                for (let w = 0; w < said.length; w++) m.warnings.push("mesh '" + obj.name + "': " + said[w]);
                if (cow != null) {
                    const mesh = convertMesh(cow.mesh, obj.name, obj.materialSlots, m.materials);
                    mesh.source = new ModelMeshSource(m, id);
                    out.mesh = mesh;
                }
                break;
            }
            case ObjectDataKind.Camera: {
                out.className = "Camera3D";
                const cam = obj.data.camera();
                if (cam != null) {
                    setProp(out, "projection", Value.int(cam.kind == CameraKind.Orthographic ? 1 : 0));
                    setProp(out, "fov", float(toDegrees(majorFov(cam.focalLengthMm))));
                    // majorFov measures the larger side: Godot's keep_width
                    // for a landscape view, the usual one. The renderer
                    // keeps the larger side for a portrait one too (the
                    // node's majorAxis, tree/model_nodes.as), as Hedra.
                    setProp(out, "keep_aspect", Value.int(0));
                    setProp(out, "near", float(cam.clipStart));
                    setProp(out, "far", float(cam.clipEnd));
                    setProp(out, "size", float(cam.orthoScale));
                }
                break;
            }
            case ObjectDataKind.Light: {
                const light = obj.data.light();
                out.className = "OmniLight3D";
                if (light != null) {
                    const c = light.color;
                    const color = Value.color(<f64>srgb(c.x), <f64>srgb(c.y), <f64>srgb(c.z), 1);
                    if (light.kind == LightKind.Sun) {
                        out.className = "DirectionalLight3D";
                        setProp(out, "light_color", color);
                        setProp(out, "light_energy", float(light.energy));
                    } else if (light.kind == LightKind.Spot) {
                        out.className = "SpotLight3D";
                        setProp(out, "light_color", color);
                        setProp(out, "light_energy", float(light.energy / WATTS_PER_ENERGY));
                        setProp(out, "spot_range", Value.float(UNBOUNDED_RANGE));
                        setProp(out, "spot_angle", Value.float(45));
                    } else {
                        if (light.kind == LightKind.Area) {
                            m.warnings.push("area light '" + obj.name + "' approximated by an omni light");
                        }
                        setProp(out, "light_color", color);
                        setProp(out, "light_energy", float(light.energy / WATTS_PER_ENERGY));
                        setProp(out, "omni_range", Value.float(UNBOUNDED_RANGE));
                    }
                }
                break;
            }
            default:
                // Empties and armatures (bones are not nodes: what hangs from
                // a bone hangs from the armature's node, following the bone:
                // ModelObject.parentBone, model_skeleton.as).
                out.className = "Node3D";
        }
        m.objects.push(out);
    }

    // Milestone 48: skeletons, skins, attachments, blend shapes, clips.
    const reading = new ModelReading(scene, format, order, gltf);
    if (gltf != null) {
        readGltfSkeletons(reading, m);
        readGltfClips(reading, m);
    } else {
        readSceneSkeletons(reading, m);
        readSceneClips(reading, m);
    }
    source.plans = reading.plans;
    return m;
}

// --- instances and material files ---------------------------------------------

// A glTF file's embedded images, for an instance of it: mounted in the vfs
// under `<abs model path>#<file>` (what the import names them), so that
// every reader of textures finds them as files, the scene loader's and
// the model renderer's alike, and nothing is written to disk.
class MountedImages extends ImageSink {
    modelPath: string;

    constructor(modelPath: string) {
        super();
        this.modelPath = modelPath;
    }

    store(index: i32, file: string, bytes: Uint8Array): Result<string> {
        const key = this.modelPath + "#" + file;
        vfs.mount(key, bytes.slice(0));
        return Result.okv<string>(key);
    }
}

// The files a model's instances and MaterialX materials name, read through
// the vfs (compose.as ModelFiles): an .rmdl read, an .rmdlcmd loaded as a
// scene loads one (its cache, its data form, its commands replayed where
// the kernel is installed), a glTF file imported as a scene reads it (its
// materials whole), a MaterialX file read (mtlx.as). Each is read once
// while the reader lives (`clear` forgets them: the model editor's, when a
// file it watches changes).
export class FileModelFiles extends ModelFiles {
    models: Map<string, ModelFileSource> = new Map<string, ModelFileSource>();
    materials: Map<string, PbrMaterial> = new Map<string, PbrMaterial>();
    failures: Map<string, string> = new Map<string, string>();

    clear(): void {
        this.models.clear();
        this.materials.clear();
        this.failures.clear();
    }

    model(abs: string): Result<ModelFileSource> {
        if (this.models.has(abs)) return Result.okv<ModelFileSource>(this.models.get(abs));
        if (this.failures.has(abs)) return Result.fail<ModelFileSource>(this.failures.get(abs));
        const r = readModelSource(abs);
        if (!r.ok) this.failures.set(abs, r.err);
        else this.models.set(abs, r.value);
        return r;
    }

    material(abs: string): Result<PbrMaterial> {
        if (this.materials.has(abs)) return Result.okv<PbrMaterial>(this.materials.get(abs));
        const key = "material:" + abs;
        if (this.failures.has(key)) return Result.fail<PbrMaterial>(this.failures.get(key));
        const t = vfs.readToString(abs);
        let r: Result<PbrMaterial>;
        if (!t.ok) r = Result.fail<PbrMaterial>(t.err);
        else {
            const m = readMtlx(t.value, abs);
            r = m.ok ? Result.okv<PbrMaterial>(m.value.material) : Result.fail<PbrMaterial>(m.err);
        }
        if (!r.ok) this.failures.set(key, r.err);
        else this.materials.set(abs, r.value);
        return r;
    }
}

// A model file read as the scene an instance of it puts in.
function readModelSource(abs: string): Result<ModelFileSource> {
    const kind = modelFileKind(abs);
    if (kind == ModelFileKind.None) return Result.fail<ModelFileSource>("a model is an .rmdl, .rmdlcmd, .gltf or .glb file");
    const bytes = vfs.read(abs);
    if (!bytes.ok) return Result.fail<ModelFileSource>(bytes.err);
    if (kind == ModelFileKind.Snapshot) {
        const read = readRmdl(bytes.value, abs);
        if (!read.ok) return Result.fail<ModelFileSource>(read.err);
        return Result.okv<ModelFileSource>(new ModelFileSource(read.value.scene));
    }
    if (kind == ModelFileKind.Commands) {
        const tools = namesToolModifier(bytes.value);
        if (tools) enterModelTools(abs);
        const loaded = loadRmdlScene(abs, abs, bytes.value);
        if (tools) leaveModelTools();
        if (!loaded.ok) return Result.fail<ModelFileSource>(loaded.err);
        return Result.okv<ModelFileSource>(new ModelFileSource(loaded.value));
    }
    const scene = new Scene();
    const opts = gltfReadOpts(dirOfPath(abs), new MountedImages(abs));
    opts.keepDocument = false;
    const r = import_(scene, abs, opts);
    if (!r.ok) return Result.fail<ModelFileSource>(r.err);
    return Result.okv<ModelFileSource>(new ModelFileSource(scene, r.value.pbrMaterials));
}

// --- .rmdlcmd (milestone 21) ---------------------------------------------------

// The scene of the .rmdlcmd at `abs` (read: `bytes`), as rmdlcmd/load.as
// loads it (load.as loadRmdlBytes): a cache entry for the whole file, its
// data lines, a packed scene's entry, its commands replayed (when the
// program carries Hedra's kernel), else model-needs-commands. An RmdlError
// becomes a SceneryError with its code, the file as `display` names it, its
// line and its hint.
//
// A packed scene (RSCN.md, "Packed scenes") carries the cache entry its load
// read, mounted at its res:// path; the cache's lookup lists the cache
// directory, and a listing never shows mounted files (vfs.mount), so a
// command-form model the lookup missed is looked for once more by its
// entry's exact name (PackedEntry, wholeCacheEntry), which a read finds
// mounted or not, before its commands are replayed: the entry is the
// scene the model was packed with, and costs a decode, not a replay.
export function loadRmdlScene(abs: string, display: string, bytes: Uint8Array): Result<Scene> {
    const r = loadRmdlBytes(abs, display, bytes, packedEntry());
    if (r.ok) return Result.okv<Scene>(r.value.scene);
    const e = rmdlErrorOf<RmdlLoad>(r);
    if (e == null) {
        return SceneryError.at("model-load", display, 0, 0, "cannot load model " + display + ": " + r.err, MODEL_LOAD_HINT)
            .fail<Scene>();
    }
    return rmdlSceneryError(e, display).fail<Scene>();
}

// An RmdlError in Hedra's words: the same code, line, message and hint.
export function rmdlSceneryError(e: RmdlError, display: string): SceneryError {
    return SceneryError.at(e.code, display, e.line, 0, e.message, e.hint);
}

function bytesText(bytes: Uint8Array): string {
    return String.UTF8.decode(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
}

// load.as's last look before a replay: the entry by its exact name.
class PackedEntry extends EntryProbe {
    entry(doc: RmdlDoc, abs: string, display: string): CacheHit? {
        return wholeEntryOf(doc, abs);
    }
}

// (made on first use: a module-level `new` is no constant for the module's
// start)
let packedEntryCell: PackedEntry? = null;

function packedEntry(): PackedEntry {
    let p = packedEntryCell;
    if (p == null) {
        p = new PackedEntry();
        packedEntryCell = p;
    }
    return p;
}

// The scene of the cache entry for the whole of the .rmdlcmd at `abs`, found
// by its exact name (cache.as cacheFileName of the doc's entry count and
// key), or null: no such entry, or one whose header, key, prefix length or
// a dependency's hash does not match (a miss, never an error, as for
// findCached).
export function wholeCacheEntry(abs: string, display: string, bytes: Uint8Array): Scene? {
    const parsed = RmdlDoc.parse(bytesText(bytes), display);
    if (!parsed.ok) return null;
    const hit = wholeEntryOf(parsed.value, abs);
    return hit != null ? hit.scene : null;
}

// The path of the cache entry for the whole of `doc` (the .rmdlcmd at `abs`),
// or "" for a doc of no entries: where Hedra writes it, and where
// the CLI's `build` packs one for a model it replayed (src/build/pack.as).
export function wholeEntryPath(doc: RmdlDoc, abs: string): string {
    const n = doc.entryCount();
    if (n == 0) return "";
    return cacheDirOf(abs) + "/" + cacheFileName(stemOf(abs), n, prefixKey(doc, n));
}

function wholeEntryOf(doc: RmdlDoc, abs: string): CacheHit? {
    const n = doc.entryCount();
    if (n == 0) return null;
    const key = prefixKey(doc, n);
    const path = wholeEntryPath(doc, abs);
    const read = vfs.read(path);
    if (!read.ok) return null;
    const entry = decodeCacheEntry(read.value, path);
    if (!entry.ok) return null;
    const e = entry.value;
    if (e.n != n || e.key != key) return null;
    if (e.prefixBytes != prefixBytes(doc, n)) return null;
    const dir = dirOfPath(abs);
    for (let i = 0; i < e.deps.length; i++) {
        const dep = e.deps[i];
        const b = vfs.read(texturePath(dir, dep.path));
        if (!b.ok || depHash(b.value) != dep.hash) return null;
    }
    const scene = decode(e.sceneBytes, path);
    if (!scene.ok) return null;
    const hit = new CacheHit();
    hit.n = n;
    hit.path = path;
    hit.scene = scene.value;
    hit.deps = e.deps;
    return hit;
}

// What a prefetcher asks for once an .rmdlcmd's bytes are in: its cache
// directory, to list (then rmdlCacheEntries), and the files its lines name
// (hedra_engine/source/model/rmdlcmd/scan.as referencedPaths: an import's source, a
// material's texture), absolute as the loader reads them (from the model's
// directory). Null for bytes that are no .rmdlcmd: the load reports that.
//
// Milestone 22: what a replay of its commands asks about besides
// (engine/src/commands/replayer.as), so that a model Hedra replays
// cold loads in the same round as one it finds cached: the directories
// above the cache directory, which Hedra's loader states for the save it
// may make (`stats`), and, for a model importing a glTF file, the directory
// the import's embedded images are kept in (`texturesDir`, the default
// `textures/` beside the model), whose listing tells which are there and
// whose images the model's materials then read.
//
// An .rmdl's are fewer (rmdlDocumentFiles): no cache, no replay, nothing
// imported; `cacheDir` is then "".
export class RmdlFiles {
    cacheDir: string = "";
    named: Array<string> = [];
    stats: Array<string> = [];
    texturesDir: string = "";
    // For a model that adds a tool modifier (scan.as namesToolModifier):
    // `tools/` beside it, whose listing tells which tools are there and
    // whose `.tool` files the load reads (engine/src/commands/tools.as).
    toolsDir: string = "";
}

export function rmdlNamedFiles(abs: string, bytes: Uint8Array): RmdlFiles? {
    if (!isValidUtf8(bytes)) return null;
    const parsed = RmdlDoc.parse(bytesText(bytes), abs);
    if (!parsed.ok) return null;
    const out = new RmdlFiles();
    out.cacheDir = cacheDirOf(abs);
    const dir = dirOfPath(abs);
    const refs = referencedPaths(parsed.value);
    for (let i = 0; i < refs.length; i++) {
        const p = texturePath(dir, refs[i]);
        if (!out.named.includes(p)) out.named.push(p);
        const ext = lowerExtension(p);
        if (ext == "glb" || ext == "gltf") out.texturesDir = (dir == "/" ? "" : dir) + "/textures";
    }
    if (!parsed.value.isDataOnly()) {
        const cache = dirOfPath(out.cacheDir);
        out.stats.push(dirOfPath(cache));
        out.stats.push(cache);
    }
    // (a data-form model names its tool modifiers too, and its stack is
    // evaluated with them at conversion, as a model of commands' is)
    if (namesToolModifier(bytes)) out.toolsDir = (dir == "/" ? "" : dir) + "/tools";
    return out;
}

// What a prefetcher asks for once an .rmdl's bytes are in: the files its
// load reads (engine/src/source/model/rmdl/scan.as rmdlLoadedPaths: its
// textures, MaterialX files and instanced models, never the glTF file an
// import copied geometry from, which a document only names), absolute as the loader reads them (from the
// model's directory), and `tools/` beside it when a modifier of it is a
// tool's (documentNamesToolModifier). No cache directory: a document is
// read, never replayed. Null for bytes that are not UTF-8 (the load
// reports them); a text that is no document names nothing.
export function rmdlDocumentFiles(abs: string, bytes: Uint8Array): RmdlFiles? {
    if (!isValidUtf8(bytes)) return null;
    const text = bytesText(bytes);
    const out = new RmdlFiles();
    const dir = dirOfPath(abs);
    const refs = rmdlLoadedPaths(text);
    for (let i = 0; i < refs.length; i++) {
        const p = texturePath(dir, refs[i]);
        if (!out.named.includes(p)) out.named.push(p);
    }
    if (documentNamesToolModifier(text)) out.toolsDir = (dir == "/" ? "" : dir) + "/tools";
    return out;
}

// Whether an .rmdl's text has a `<modifier ... type="tool">` element (the
// attribute's value in either quote, spaces around its `=`), read without
// parsing the document: a prefetcher asks it of every model it follows.
// Over-matching costs a directory listing; a document the reader refuses
// has no stack to evaluate.
export function documentNamesToolModifier(text: string): bool {
    let at = text.indexOf("<modifier");
    while (at >= 0) {
        const end = text.indexOf(">", at);
        const stop = end < 0 ? text.length : end;
        let t = text.indexOf("type", at + 9);
        while (t >= 0 && t < stop) {
            if (isToolValue(text, t + 4, stop)) return true;
            t = text.indexOf("type", t + 4);
        }
        if (end < 0) return false;
        at = text.indexOf("<modifier", end);
    }
    return false;
}

// Whether `text` from `i` (just after an attribute name) reads `= "tool"`
// or `='tool'` before `stop`.
function isToolValue(text: string, i: i32, stop: i32): bool {
    while (i < stop && isXmlSpace(text.charCodeAt(i))) i++;
    if (i >= stop || text.charCodeAt(i) != 0x3D) return false;
    i++;
    while (i < stop && isXmlSpace(text.charCodeAt(i))) i++;
    if (i >= stop) return false;
    const q = text.charCodeAt(i);
    if (q != 0x22 && q != 0x27) return false;
    return i + 5 < stop && text.substring(i + 1, i + 5) == "tool" && text.charCodeAt(i + 5) == q;
}

function isXmlSpace(c: i32): bool {
    return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
}

// Whether a file of a model's tools directory is a tool its load installs
// (engine/src/commands/tools.as toolFiles).
export function isToolFile(name: string): bool {
    return name.endsWith(".tool");
}

// Whether a file of a model's textures directory is an image its
// materials may name (what glTF embeds: PNG or JPEG).
export function isTextureFile(name: string): bool {
    const ext = lowerExtension(name);
    return ext == "png" || ext == "jpg" || ext == "jpeg";
}

// The cache entries of the model at `abs` among `names`, the file names its
// cache directory's listing holds: the stem's, newest (largest n) first, at
// most RMDL_CACHE_KEEP (as many as Hedra keeps), absolute.
export function rmdlCacheEntries(abs: string, names: Array<string>): Array<string> {
    const stem = stemOf(abs);
    const dir = cacheDirOf(abs);
    const found = new Array<string>();
    const ns = new Array<i32>();
    for (let i = 0; i < names.length; i++) {
        const c = parseCacheFileName(names[i], stem);
        if (c == null) continue;
        // (an insertion by n, largest first: a handful of entries)
        found.push(dir + "/" + names[i]);
        ns.push(c.n);
        let at = found.length - 1;
        while (at > 0 && ns[at - 1] < ns[at]) {
            const f = found[at - 1];
            found[at - 1] = found[at];
            found[at] = f;
            const k = ns[at - 1];
            ns[at - 1] = ns[at];
            ns[at] = k;
            at--;
        }
    }
    if (found.length > RMDL_CACHE_KEEP) found.length = RMDL_CACHE_KEEP;
    return found;
}

// The files a cache entry of the model at `modelAbs` leads to: the files
// its replay read (its deps, which the lookup hashes again) and the
// textures of the scene it holds (sceneTextures), absolute. [] for bytes
// that are no cache entry.
export function cacheEntryFiles(modelAbs: string, entryBytes: Uint8Array): Array<string> {
    const out = new Array<string>();
    const entry = decodeCacheEntry(entryBytes, modelAbs);
    if (!entry.ok) return out;
    const dir = dirOfPath(modelAbs);
    const deps = entry.value.deps;
    for (let i = 0; i < deps.length; i++) out.push(texturePath(dir, deps[i].path));
    const scene = decode(entry.value.sceneBytes, modelAbs);
    if (!scene.ok) return out;
    const t = sceneTextures(scene.value, dir);
    for (let i = 0; i < t.length; i++) if (!out.includes(t[i])) out.push(t[i]);
    return out;
}

// The texture files a model's materials name, absolute (texturePath: from
// the model's directory `dir`), each once, in material and slot order;
// then the MaterialX files its materials are and the models its empties
// instance (what a load reads besides), in material and object order.
export function sceneTextures(scene: Scene, dir: string): Array<string> {
    const out = new Array<string>();
    const mats = scene.materials;
    for (let i = 0; i < mats.length; i++) {
        const t = mats[i].textures;
        pushTexture(out, dir, t.baseColor);
        pushTexture(out, dir, t.metallicRoughness);
        pushTexture(out, dir, t.normal);
        pushTexture(out, dir, t.emission);
        pushTexture(out, dir, t.occlusion);
    }
    for (let i = 0; i < mats.length; i++) {
        const f = mats[i].file;
        if (f != null && f.length > 0) pushPath(out, texturePath(dir, f));
    }
    const bound = scene.objects.idBound();
    for (let id: u32 = 0; id < bound; id++) {
        const o = scene.objects.get(id);
        if (o == null || o.data.kind != ObjectDataKind.Empty) continue;
        const inst = o.data.emptyData!.instance;
        if (inst != null && inst.length > 0) pushPath(out, texturePath(dir, inst));
    }
    return out;
}

function pushPath(out: Array<string>, p: string): void {
    if (!out.includes(p)) out.push(p);
}

function pushTexture(out: Array<string>, dir: string, ref: TextureRef?): void {
    if (ref == null || ref.path.length == 0) return;
    const p = texturePath(dir, ref.path);
    if (!out.includes(p)) out.push(p);
}
