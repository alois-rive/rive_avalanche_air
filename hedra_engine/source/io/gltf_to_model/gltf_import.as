// Read glTF 2.0 (`.gltf` / `.glb`) into a Scene. Nodes become
// objects (Y-up converted back to Z-up), every primitive of a mesh is merged
// into one triangle mesh with material slots, `TEXCOORD_n` become UV layers,
// materials and textures come along, skins become armature objects with
// vertex groups and an Armature modifier on their meshes (see
// import_skins.as), morph targets become shape keys and animations become
// actions (see import_anim.as). Cameras and `KHR_lights_punctual` lights
// become camera and light objects (see engine/src/source/io/core/camera_light.as), and
// `KHR_draco_mesh_compression`, `EXT_meshopt_compression` and
// `KHR_mesh_quantization` are normalized away before any of this runs (see
// engine/src/source/io/compress/decode.as), so nothing below has to know the file stored
// its mesh data compactly.
//
// Files go through the VFS (engine/src/fs/vfs.as); paths are Unix strings and
// error messages show them as they are. Counts are i32, glTF indices the
// i32s of engine/src/source/io/gltf/doc.as, and a missing object is NO_OBJ.

import {
    Result, panic, roundF32, f32ToI64, minF32, maxF32, toAsciiLowercase,
} from "../../../base/util";
import { zeroPad } from "../../../base/fmt";
import { linearToSrgbValue } from "../../../base/color";
import { JsonMap } from "../../../base/json";
import {
    Mat4, Vec2, Vec3, Quat, MAT4_IDENTITY, VEC3_ZERO, EulerRot, toDegrees,
} from "../../../base/vecmath";
import {
    Scene, Object, ObjectData, ObjectDataKind, Parent, ParentKind, Transform, TRANSFORM_IDENTITY,
    Material, MaterialTextures, TextureRef, TextureSlot, AlphaMode, Empty, EmptyDisplay, LightKind,
    Modifier, ModifierKindInstance, ModifierKindArmature, VertexGroup, NO_OBJ,
} from "../../model/scene";
import { Armature } from "../../model/armature/mod";
import { Mesh, GroupWeight } from "../../model/mesh/mod";
import { AttrType, AttrValue, Domain } from "../../model/mesh/attr";
import { vfs } from "../../../fs/vfs";
import { parent as pathParent, extension as pathExtension, join as pathJoin } from "../../../fs/path";
import {
    Root, Buffer as GltfBuffer, Node as GltfNode, Material as GltfMaterial,
    SemanticKind, Mode, AlphaMode as GltfAlphaMode, KhrLight, accessorTypeMultiplicity,
} from "../gltf/doc";
import {
    Gltf, GltfErrorKind, gltfErrorOf, gltfFromReaderWithoutValidation, documentFromJson, BlobSlot,
    bufferDataFromSourceAndBlob, imageSource, schemeFilePath,
} from "../gltf/gltf";
import {
    PrimitiveReader, nodeTransform, primitiveMode, defaultScene, documentLights, nodeLight,
    accessorDimensions, accessorOffset, viewOffset, viewStride,
} from "../gltf/reader";
import { IoError, ioError } from "../core/error";
import { Axis, axisLabel, conversion } from "../core/axis";
import { LightingMode, cameraFromGltf, lightFromGltf } from "../core/camera_light";
import { CompressReport } from "../core/compress";
import { percentDecode, slashed, bestRelative, dataUri } from "../core/uri";
import { decode as compressDecode } from "../compress/decode";
import { NodeGraph, SkinSet, ToScene, ToArm, buildArmature, mat4FromCols } from "./import_skins";
import { targetNames, addShapeKeys, AnimScene, importAnimations } from "./import_anim";
import { isUnicodeAlphanumeric } from "./alnum";
import { PbrImages, pbrFromGltf } from "./import_pbr";
import { PbrMaterial } from "../../../material/pbr";

// Where a glTF file's embedded images go instead of files under
// texturesDir (null: written through the vfs, as Hedra imports do). A
// scene loads a model without changing the disk, so it keeps them in
// memory.
export abstract class ImageSink {
    // Keeps the bytes of image `index` (its chosen file name `file`, e.g.
    // "Crate.png"); returns the path the TextureRef will hold.
    abstract store(index: i32, file: string, bytes: Uint8Array): Result<string>;
}

// Import options; `new ImportOpts()` holds the defaults.
export class ImportOpts {
    // Weld vertices that share a position (within 1e-6), undoing the
    // per-corner split exporters do for normals and UV seams. Triangles
    // stay triangles.
    mergeVertices: bool = true;
    // The frame the file is in; the inverse conversion brings it back to
    // Hedra's Z-up.
    axisForward: Axis = Axis.NegZ;
    axisUp: Axis = Axis.Y;
    scale: f32 = 1.0;
    // Project directory; texture paths are stored relative to it.
    baseDir: string = ".";
    // Where embedded images are written; default `<base_dir>/textures`.
    texturesDir: string? = null;
    // Select the imported objects (and deselect the rest), like Blender.
    select: bool = true;
    // Read animations into actions.
    animations: bool = true;
    // Read morph targets into shape keys.
    morphTargets: bool = true;
    // Read glTF cameras into camera objects. Off leaves the node as an empty.
    cameras: bool = true;
    // Read `KHR_lights_punctual` lights into light objects.
    lights: bool = true;
    // How a glTF light's intensity becomes an energy in watts.
    lightingMode: LightingMode = LightingMode.Spec;
    // Embedded images go here instead of to texturesDir when set.
    imageSink: ImageSink? = null;
    // Also read each material whole, as glTF defines it (every
    // KHR_materials_* extension, texCoord and KHR_texture_transform), into
    // ImportReport.pbrMaterials (import_pbr.as). The scene's materials are
    // the same either way: the shared model's Material has no room for it.
    pbr: bool = false;
    // Extensions a file may require besides the ones the reader handles
    // itself: the caller reads them (Hedra passes import_pbr.as's
    // PBR_EXTENSIONS with `pbr`). Empty, a file requiring one is refused.
    extensions: Array<string> = [];
    // Keep the parsed document and where its nodes landed in
    // ImportReport.gltf (a scene's model load reads skins, morph targets
    // and animations from the file itself: engine/src/source/
    // engine/src/source/scene/resource/model_skeleton.as). Off, nothing is kept.
    keepDocument: bool = false;
    // Warn of the animations skipped with `animations` off ("2
    // animation(s) skipped (--animations off)"), as Hedra's import says
    // it; a scene's load, which reads them from the document instead,
    // turns it off.
    warnSkippedAnimations: bool = true;
    // Carry a skin's joint frames over to its bones' rest frames when they
    // differ (import_skins.as's header), so the file's rest pose is an
    // identity pose basis and the mesh is the bind mesh at rest. Off, the
    // channels are the reference importer's, as Hedra's import goldens
    // record them; a scene's model load turns it on.
    carryJointFrames: bool = false;

    clone(): ImportOpts {
        const o = new ImportOpts();
        o.mergeVertices = this.mergeVertices;
        o.axisForward = this.axisForward;
        o.axisUp = this.axisUp;
        o.scale = this.scale;
        o.baseDir = this.baseDir;
        o.texturesDir = this.texturesDir;
        o.select = this.select;
        o.animations = this.animations;
        o.morphTargets = this.morphTargets;
        o.cameras = this.cameras;
        o.lights = this.lights;
        o.lightingMode = this.lightingMode;
        o.imageSink = this.imageSink;
        o.pbr = this.pbr;
        o.extensions = this.extensions.slice(0);
        o.keepDocument = this.keepDocument;
        o.warnSkippedAnimations = this.warnSkippedAnimations;
        o.carryJointFrames = this.carryJointFrames;
        return o;
    }
}

// What an import read, for the command's report.
export class ImportReport {
    objects: i32 = 0;
    meshes: i32 = 0;
    materials: i32 = 0;
    textures: i32 = 0;
    triangles: i32 = 0;
    armatures: i32 = 0;
    // Actions created: one per animated object, so a glTF animation that
    // drives several objects counts several times.
    animations: i32 = 0;
    // Shape keys created, the Basis of each mesh included.
    shapeKeys: i32 = 0;
    cameras: i32 = 0;
    lights: i32 = 0;
    // What was decompressed on the way in, empty for a plain file.
    compression: CompressReport = new CompressReport();
    warnings: Array<string> = [];
    // With ImportOpts.pbr: each material the import added, whole, in the
    // order they were added to the scene (pbrMaterials[k] is the material
    // at the scene's material count before the import, plus k). Empty
    // otherwise.
    pbrMaterials: Array<PbrMaterial> = [];
    // The files read besides the source: a .gltf's external buffers, each
    // as its uri names it (relative to the .gltf's directory, or absolute).
    // A model file's cache entry depends on them as much as on the .gltf
    // (docs/formats/RMDLCMD.md, the cache): a re-export often changes only the .bin.
    // Images are not here: the import keeps a reference to an external
    // image, never its bytes.
    sidecars: Array<string> = [];
    // With ImportOpts.keepDocument: the document read and where its nodes
    // landed in the scene. Null otherwise.
    gltf: GltfImportMap? = null;

    clone(): ImportReport {
        const r = new ImportReport();
        r.objects = this.objects;
        r.meshes = this.meshes;
        r.materials = this.materials;
        r.textures = this.textures;
        r.triangles = this.triangles;
        r.armatures = this.armatures;
        r.animations = this.animations;
        r.shapeKeys = this.shapeKeys;
        r.cameras = this.cameras;
        r.lights = this.lights;
        r.compression = this.compression.clone();
        r.warnings = this.warnings.slice(0);
        for (let i = 0; i < this.pbrMaterials.length; i++) r.pbrMaterials.push(this.pbrMaterials[i].clone());
        r.sidecars = this.sidecars.slice(0);
        // (shared: the document is read, never changed)
        r.gltf = this.gltf;
        return r;
    }
}

// What an import kept of the file for a reader that goes back to it
// (ImportOpts.keepDocument): the document (decompressed and validated) and
// its buffers, the frame change and unit scale the importer applied, and
// where each node went: its object, the armature object of each skin, the
// bone each joint became.
export class GltfImportMap {
    document: Root;
    buffers: Array<Uint8Array>;
    // The Hedra-to-file frame change (axis.as conversion) and the unit
    // scale: an object's transform is `convInv * node * conv`, its
    // translation times `scale`.
    conv: Mat4;
    scale: f32;
    // glTF node -> scene object id (joints are bones: not here).
    objOfNode: Map<i32, u32>;
    skins: SkinSet;
    graph: NodeGraph;
    // Per skin: its armature object, and its joints' bone names in joint
    // order.
    armObj: Array<u32>;
    boneNames: Array<Array<string>>;
    // The mesh objects a skin deforms, with the skin of each (parallel).
    skinnedObjs: Array<u32> = [];
    skinOfObj: Array<i32> = [];

    constructor(document: Root, buffers: Array<Uint8Array>, conv: Mat4, scale: f32, objOfNode: Map<i32, u32>, skins: SkinSet,
        graph: NodeGraph, armObj: Array<u32>, boneNames: Array<Array<string>>) {
        this.document = document;
        this.buffers = buffers;
        this.conv = conv;
        this.scale = scale;
        this.objOfNode = objOfNode;
        this.skins = skins;
        this.graph = graph;
        this.armObj = armObj;
        this.boneNames = boneNames;
    }
}

// UV layer name for `TEXCOORD_n`, Blender style. A texture's
// `texCoord` is a u32, so `set` is an i64 (never negative here).
export function layerName(set: i64): string {
    if (set == 0) return "UVMap";
    return "UVMap." + zeroPad(set, 3);
}

// `gltf_error(path, e)`: an i/o failure stays one, anything else is Parse.
function gltfError<T, U>(path: string, r: Result<U>): Result<T> {
    const e = gltfErrorOf<U>(r);
    if (e != null && e.kind == GltfErrorKind.Io) return IoError.io(path, e.text, e.source).fail<T>();
    return IoError.parse(path, e != null ? e.toString() : r.err).fail<T>();
}

function isMeshoptFallback(buffer: GltfBuffer): bool {
    const e = buffer.extensions;
    if (e == null) return false;
    const m = e.get("EXT_meshopt_compression");
    if (m == null) return false;
    const f = m.get("fallback");
    if (f == null || !f.isBool()) return false;
    return f.asBool();
}

// Read every buffer of the document.
//
// importBuffers (engine/src/source/io/gltf/gltf.as) would do this, except for the buffer
// `EXT_meshopt_compression` requires a compressed asset to declare: a
// *fallback* with no uri and no bytes, which exists only so that a viewer
// without the extension finds something well-formed behind each view.
// `import_buffers` sees a second bufferless buffer and gives up, so the
// fallback is filled with the zeros it stands for instead. Nothing ever
// reads them -- every view over a fallback carries the extension, and the
// decompression pass repoints all of those.
function loadBuffers(
    document: Root, gltfDir: string, blob: Uint8Array?, path: string, sidecars: Array<string>,
): Result<Array<Uint8Array>> {
    const slot = new BlobSlot(blob);
    const out: Array<Uint8Array> = [];
    for (let i = 0; i < document.buffers.length; i++) {
        const buffer = document.buffers[i];
        if (isMeshoptFallback(buffer)) {
            out.push(new Uint8Array(<i32>buffer.byteLength));
            continue;
        }
        const data = bufferDataFromSourceAndBlob(buffer.uri, gltfDir, slot);
        if (!data.ok) return gltfError<Array<Uint8Array>, Uint8Array>(path, data);
        const uri = buffer.uri;
        if (uri != null) {
            const f = schemeFilePath(uri);
            if (f != null && !sidecars.includes(f)) sidecars.push(f);
        }
        if (<u64>data.value.length < buffer.byteLength) {
            return IoError.parse(
                path,
                "buffer " + i.toString() + " declares " + buffer.byteLength.toString() + " bytes but only "
                    + data.value.length.toString() + " are there",
            ).fail<Array<Uint8Array>>();
        }
        out.push(data.value);
    }
    return Result.okv<Array<Uint8Array>>(out);
}

export const INSTANCE_SCALE = "instance_scale";
export const INSTANCE_ROTATION = "instance_rotation";

// One copy a node's `EXT_mesh_gpu_instancing` asks for.
//
// Blender writes that extension for an instanced collection or a Geometry
// Nodes scatter, which is the same thing `distribute on faces` plus an
// instance modifier describes here, so it is read back as exactly that: the
// mesh becomes the object to copy, the translations become a cloud of
// points, and the scales and rotations become the point attributes the
// modifier reads.
export class GpuInstance {
    translation: Vec3 = VEC3_ZERO;
    // Euler XYZ degrees, from the file's quaternion.
    rotation: Vec3 = VEC3_ZERO;
    scale: Vec3 = VEC3_ZERO;
}

// Build the point cloud and the instance modifier that stand for a node's
// instanced copies, and hide the mesh they copy.
//
// The cloud takes the prototype's transform, because the instance
// transforms are in the node's own space; the prototype keeps it too, so
// that `realize` puts the copies exactly where the file drew them.
function instanceCloud(scene: Scene, prototype: u32, instances: Array<GpuInstance>, nodeName: string?, select: bool): u32 {
    const cloud = new Mesh();
    cloud.addAttr(INSTANCE_SCALE, Domain.Point, AttrType.Vec3);
    cloud.addAttr(INSTANCE_ROTATION, Domain.Point, AttrType.Vec3);
    for (let k = 0; k < instances.length; k++) {
        const i = instances[k];
        const v = cloud.addVert(i.translation);
        const sa = cloud.attrMut(INSTANCE_SCALE);
        if (sa != null) sa.set(v, AttrValue.vec3(i.scale));
        const ra = cloud.attrMut(INSTANCE_ROTATION);
        if (ra != null) ra.set(v, AttrValue.vec3(i.rotation));
    }
    const proto = scene.objects.at(prototype);
    let base: string;
    if (nodeName != null && nodeName != proto.name) base = nodeName;
    else base = proto.name + " Instances";
    const name = scene.uniqueName(base);
    const obj = new Object(name, ObjectData.fromMesh(cloud));
    obj.transform = proto.transform;
    const pp = proto.parent;
    obj.parent = pp != null ? pp.clone() : null;
    // The geometry the cloud stands for is the prototype's, so are its
    // material slots: without this every round trip adds one more default
    // material for a cloud that appeared to have none.
    obj.materialSlots = proto.materialSlots.slice(0);
    obj.select = select;
    obj.modifiers.push(new Modifier(
        "Instance",
        ModifierKindInstance.create(prototype, 1.0, INSTANCE_SCALE, false, VEC3_ZERO, INSTANCE_ROTATION),
        true,
    ));
    // The file draws the mesh only at the instance transforms, so on its
    // own it is a prototype rather than a thing in the picture. It stays
    // visible in the viewport and selectable, because editing it is how you
    // change every copy.
    proto.hideRender = true;
    return scene.addObject(obj);
}

// `v[k]` on a row read from the file, panicking with the index and length
// when out of bounds.
function rowAt(row: Array<f32>, k: i32): f32 {
    if (k >= row.length) {
        panic("index out of bounds: the len is " + row.length.toString() + " but the index is " + k.toString());
    }
    return row[k];
}

// Every row of one `EXT_mesh_gpu_instancing` attribute, or null when anything is missing or out of range.
function readInstanceRows(document: Root, buffers: Array<Uint8Array>, attributes: JsonMap, name: string): Array<Array<f32>>? {
    const iv = attributes.get(name);
    if (iv == null || !iv.isU64()) return null;
    const index = iv.asU64();
    if (index >= <u64>document.accessors.length) return null;
    const accessor = document.accessors[<i32>index];
    // The typed readers key off a known semantic, and these are an
    // extension's, so the components are walked by hand. Every instancing
    // attribute is plain `f32` by the extension's spec.
    const count = accessor.count;
    const comps = accessorTypeMultiplicity(accessorDimensions(accessor));
    if (accessor.bufferView < 0) return null;
    const data = document.bufferViews[accessor.bufferView];
    if (data.buffer < 0 || data.buffer >= buffers.length) return null;
    const buffer = buffers[data.buffer];
    const vs = viewStride(data);
    const stride: u64 = vs > 0 ? <u64>vs : <u64>(comps * 4);
    const start = viewOffset(data) + accessorOffset(accessor);
    const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    const out: Array<Array<f32>> = [];
    for (let i: u64 = 0; i < count; i++) {
        const base = start + i * stride;
        const row: Array<f32> = [];
        for (let c = 0; c < comps; c++) {
            const at = base + <u64>(c * 4);
            if (at + 4 > <u64>buffer.length) return null;
            row.push(view.getFloat32(<i32>at, true));
        }
        out.push(row);
    }
    return out;
}

// The copies a node asks for, or null when it carries no such extension.
function gpuInstances(document: Root, buffers: Array<Uint8Array>, node: GltfNode, convInv: Mat4, unit: f32): Array<GpuInstance>? {
    const ext = node.extensions;
    if (ext == null) return null;
    const inst = ext.get("EXT_mesh_gpu_instancing");
    if (inst == null) return null;
    const attrs = inst.get("attributes");
    if (attrs == null) return null;
    const attributes = attrs.asObject();
    if (attributes == null) return null;

    const translations = readInstanceRows(document, buffers, attributes, "TRANSLATION");
    const rotations = readInstanceRows(document, buffers, attributes, "ROTATION");
    const scales = readInstanceRows(document, buffers, attributes, "SCALE");
    let count = -1;
    if (translations != null) count = max(count, translations.length);
    if (rotations != null) count = max(count, rotations.length);
    if (scales != null) count = max(count, scales.length);
    if (count < 0) return null;
    const out: Array<GpuInstance> = [];
    for (let i = 0; i < count; i++) {
        const t: Array<f32> = translations != null && i < translations.length ? translations[i] : [0, 0, 0];
        const s: Array<f32> = scales != null && i < scales.length ? scales[i] : [1, 1, 1];
        const r: Array<f32> = rotations != null && i < rotations.length ? rotations[i] : [0, 0, 0, 1];
        const quat = Quat.fromXyzw(rowAt(r, 0), rowAt(r, 1), rowAt(r, 2), rowAt(r, 3)).normalize();
        // The whole placement goes through the axis conversion at once, so a
        // Y-up file lands the same way its mesh does.
        const placement = convInv
            * Mat4.fromScaleRotationTranslation(
                Vec3(rowAt(s, 0), rowAt(s, 1), rowAt(s, 2)),
                quat,
                Vec3(rowAt(t, 0), rowAt(t, 1), rowAt(t, 2)),
            )
            * convInv.inverse();
        const srt = placement.toScaleRotationTranslation();
        const e = srt.rotation.toEuler(EulerRot.XYZ);
        const g = new GpuInstance();
        g.translation = srt.translation * unit;
        g.rotation = Vec3(toDegrees(e.x), toDegrees(e.y), toDegrees(e.z));
        g.scale = srt.scale;
        out.push(g);
    }
    return out;
}

// Images of the document, written or referenced on first use.
class ImageStore {
    document: Root;
    buffers: Array<Uint8Array>;
    gltfDir: string;
    baseDir: string;
    texturesDir: string;
    // Image index -> project path (null = could not be read).
    resolved: Map<i32, string?> = new Map<i32, string?>();
    usedNames: Set<string> = new Set<string>();
    // ImportOpts.imageSink: embedded images go there, not to the vfs.
    sink: ImageSink? = null;

    constructor(document: Root, buffers: Array<Uint8Array>, gltfDir: string, baseDir: string, texturesDir: string) {
        this.document = document;
        this.buffers = buffers;
        this.gltfDir = gltfDir;
        this.baseDir = baseDir;
        this.texturesDir = texturesDir;
    }

    count(): i32 {
        const vs = this.resolved.values();
        let n = 0;
        for (let i = 0; i < vs.length; i++) if (vs[i] != null) n++;
        return n;
    }

    // Project-relative path for the image, creating the file when the data
    // is embedded. null when the image could not be read.
    pathFor(index: i32, material: string, warnings: Array<string>): Result<string?> {
        if (this.resolved.has(index)) return Result.okv<string?>(this.resolved.get(index));
        const image = this.document.images[index];
        const source = imageSource(this.document, index);
        let result: string? = null;
        if (source.isView) {
            const view = this.document.bufferViews[source.view];
            const start = viewOffset(view);
            const end = start + view.byteLength;
            let bytes: Uint8Array? = null;
            if (view.buffer >= 0 && view.buffer < this.buffers.length) {
                const d = this.buffers[view.buffer];
                if (end >= start && end <= <u64>d.length) bytes = d.subarray(<i32>start, <i32>end);
            }
            if (bytes != null) {
                const w = this.write(index, image.name, source.mimeType as string, bytes);
                if (!w.ok) return w;
                result = w.value;
            } else {
                warnings.push(
                    "image " + index.toString() + " of material '" + material + "' points outside its buffer; skipped",
                );
                result = null;
            }
        } else {
            const uri = source.uri;
            const du = dataUri(uri);
            if (du != null) {
                const mt = source.mimeType;
                const w = this.write(index, image.name, mt != null ? mt : du.mime, du.bytes);
                if (!w.ok) return w;
                result = w.value;
            } else {
                const file = pathJoin(this.gltfDir, percentDecode(uri));
                if (!vfs.isFile(file)) {
                    warnings.push(
                        "image '" + uri + "' of material '" + material + "' not found next to the glTF; the reference is kept",
                    );
                }
                result = this.projectPath(file);
            }
        }
        this.resolved.set(index, result);
        return Result.okv<string?>(result);
    }

    projectPath(file: string): string {
        return slashed(bestRelative(this.baseDir, file));
    }

    write(index: i32, name: string?, mime: string, bytes: Uint8Array): Result<string?> {
        let ext: string;
        if (mime == "image/png") ext = "png";
        else if (mime == "image/jpeg") ext = "jpg";
        else {
            // Not core glTF; keep the bytes with the subtype as extension so
            // nothing is lost, the renderer will report it if it cannot load it.
            const slash = mime.lastIndexOf("/");
            ext = slash < 0 ? mime : mime.substring(slash + 1);
        }
        let stem = name != null ? sanitizeStem(name) : "";
        if (stem.length == 0) stem = "image_" + index.toString();
        let file = stem + "." + ext;
        let n = 1;
        while (this.usedNames.has(file)) {
            file = stem + "_" + n.toString() + "." + ext;
            n += 1;
        }
        this.usedNames.add(file);
        const sink = this.sink;
        if (sink != null) {
            const kept = sink.store(index, file, bytes);
            if (!kept.ok) return kept.forward<string?>();
            return Result.okv<string?>(kept.value);
        }
        const mk = vfs.createDirAll(this.texturesDir);
        if (!mk.ok) return ioError<bool>(this.texturesDir, mk).fail<string?>();
        const path = pathJoin(this.texturesDir, file);
        const wr = vfs.write(path, bytes);
        if (!wr.ok) return ioError<bool>(path, wr).fail<string?>();
        return Result.okv<string?>(this.projectPath(path));
    }
}

// A file stem from an image name: no separators, no image extension.
export function sanitizeStem(name: string): string {
    const lower = toAsciiLowercase(name);
    let trimmed = name;
    const exts: Array<string> = [".png", ".jpg", ".jpeg"];
    for (let i = 0; i < exts.length; i++) {
        if (lower.endsWith(exts[i])) {
            // ASCII lowercasing keeps every UTF-16 index where it was.
            trimmed = name.substring(0, lower.length - exts[i].length);
            break;
        }
    }
    const out: Array<string> = [];
    let i = 0;
    while (i < trimmed.length) {
        const cp = <u32>trimmed.codePointAt(i);
        const len = cp > 0xffff ? 2 : 1;
        if (isUnicodeAlphanumeric(cp) || cp == 45 || cp == 95 || cp == 46) out.push(trimmed.substring(i, i + len));
        else out.push("_");
        i += len;
    }
    return out.join("");
}

function textureRef(document: Root, texture: i32, texCoord: u32, material: string, images: ImageStore, warnings: Array<string>): Result<TextureRef?> {
    const t = document.textures[texture];
    // The texture's image; panics when the index is out of range.
    if (<u64>t.source >= <u64>document.images.length) panic("called `Option::unwrap()` on a `None` value");
    const p = images.pathFor(<i32>t.source, material, warnings);
    if (!p.ok) return p.forward<TextureRef?>();
    const path = p.value;
    if (path == null) return Result.okv<TextureRef?>(null);
    // Set 0 is the active layer; other sets name their layer.
    return Result.okv<TextureRef?>(new TextureRef(path, texCoord > 0 ? layerName(<i64>texCoord) : null));
}

// One `slot(..)` call of convert_material: a texture index (-1 = None).
function setSlot(
    textures: MaterialTextures, slot: TextureSlot, document: Root, texture: i32, texCoord: u32, name: string,
    images: ImageStore, warnings: Array<string>,
): Result<bool> {
    if (texture < 0) return Result.okv<bool>(true);
    const r = textureRef(document, texture, texCoord, name, images, warnings);
    if (!r.ok) return r.forward<bool>();
    textures.setSlot(slot, r.value);
    return Result.okv<bool>(true);
}

// The importer's images for import_pbr.as: a texture's image as the core
// textures get theirs (one ImageStore, so each image is resolved once).
class StorePbrImages extends PbrImages {
    document: Root;
    images: ImageStore;

    constructor(document: Root, images: ImageStore) {
        super();
        this.document = document;
        this.images = images;
    }

    pathOf(texture: i32, material: string, warnings: Array<string>): Result<string?> {
        const source = this.document.textures[texture].source;
        // The validator has checked every texture's source.
        return this.images.pathFor(<i32>source, material, warnings);
    }
}

function convertMaterial(document: Root, m: GltfMaterial, name: string, images: ImageStore, warnings: Array<string>): Result<Material> {
    const pbr = m.pbrMetallicRoughness;
    const f = pbr.baseColorFactor;
    const textures = new MaterialTextures();
    const bc = pbr.baseColorTexture;
    let r = setSlot(textures, TextureSlot.BaseColor, document, bc != null ? bc.index : -1, bc != null ? bc.texCoord : 0, name, images, warnings);
    if (!r.ok) return r.forward<Material>();
    const nt = m.normalTexture;
    r = setSlot(textures, TextureSlot.Normal, document, nt != null ? nt.index : -1, nt != null ? nt.texCoord : 0, name, images, warnings);
    if (!r.ok) return r.forward<Material>();
    const mr = pbr.metallicRoughnessTexture;
    r = setSlot(textures, TextureSlot.MetallicRoughness, document, mr != null ? mr.index : -1, mr != null ? mr.texCoord : 0, name, images, warnings);
    if (!r.ok) return r.forward<Material>();
    const et = m.emissiveTexture;
    r = setSlot(textures, TextureSlot.Emission, document, et != null ? et.index : -1, et != null ? et.texCoord : 0, name, images, warnings);
    if (!r.ok) return r.forward<Material>();
    const ot = m.occlusionTexture;
    r = setSlot(textures, TextureSlot.Occlusion, document, ot != null ? ot.index : -1, ot != null ? ot.texCoord : 0, name, images, warnings);
    if (!r.ok) return r.forward<Material>();
    const out = new Material();
    out.name = name;
    // glTF's color factors are linear, scene colors sRGB (alpha is linear
    // in both).
    out.baseColor = [linearToSrgbValue(f[0]), linearToSrgbValue(f[1]), linearToSrgbValue(f[2])];
    out.metallic = pbr.metallicFactor;
    out.roughness = pbr.roughnessFactor;
    const ef = m.emissiveFactor;
    out.emission = [linearToSrgbValue(ef[0]), linearToSrgbValue(ef[1]), linearToSrgbValue(ef[2])];
    let strength: f32 = 1.0;
    const ext = m.extensions;
    if (ext != null) {
        const es = ext.emissiveStrength;
        if (es != null) strength = es.emissiveStrength;
    }
    out.emissionStrength = strength;
    out.alpha = f[3];
    const am = m.alphaMode;
    if (am == GltfAlphaMode.Opaque) out.alphaMode = AlphaMode.Opaque;
    else if (am == GltfAlphaMode.Mask) out.alphaMode = AlphaMode.Mask;
    else if (am == GltfAlphaMode.Blend) out.alphaMode = AlphaMode.Blend;
    else panic("attempted to unwrap an invalid item");
    let cutoff: f32 = 0.5;
    if (!isNaN(m.alphaCutoff)) cutoff = m.alphaCutoff;
    out.alphaCutoff = cutoff;
    out.doubleSided = m.doubleSided;
    out.textures = textures;
    return Result.okv<Material>(out);
}

// Vertex weld key: positions quantized to 1e-6 (`[i64; 3]`, as text).
function weldKey(p: Vec3): string {
    const x = f32ToI64(roundF32(p.x * <f32>1e6));
    const y = f32ToI64(roundF32(p.y * <f32>1e6));
    const z = f32ToI64(roundF32(p.z * <f32>1e6));
    return x.toString() + "," + y.toString() + "," + z.toString();
}

// Absolute shape key positions of one morph target, by
// vertex id.
export class VertPositions {
    ids: Array<u32> = [];
    cos: Array<Vec3> = [];
}

class MeshContext {
    path: string;
    document: Root;
    buffers: Array<Uint8Array>;
    convInv: Mat4;
    // glTF material index -> scene material index.
    matMap: Array<i32>;
    constructor(path: string, document: Root, buffers: Array<Uint8Array>, convInv: Mat4, matMap: Array<i32>) {
        this.path = path;
        this.document = document;
        this.buffers = buffers;
        this.convInv = convInv;
        this.matMap = matMap;
    }
}

// A converted mesh and the object's material slots.
export class ConvertedMesh {
    mesh: Mesh;
    slots: Array<u32>;
    constructor(mesh: Mesh, slots: Array<u32>) {
        this.mesh = mesh;
        this.slots = slots;
    }
}

// The debug name of a primitive Mode.
function modeDebug(m: i32): string {
    switch (m) {
        case Mode.Points: return "Points";
        case Mode.Lines: return "Lines";
        case Mode.LineLoop: return "LineLoop";
        case Mode.LineStrip: return "LineStrip";
        case Mode.Triangles: return "Triangles";
        case Mode.TriangleStrip: return "TriangleStrip";
        default: return "TriangleFan";
    }
}

// All primitives of a glTF mesh as one Mesh plus the object's material slots
// (scene material indices, in first-use order). With `skinned`, `JOINTS_0` /
// `WEIGHTS_0` become vertex group memberships (group index = joint index; the
// object gets the groups themselves).
function convertMesh(gmIndex: i32, ctx: MeshContext, opts: ImportOpts, skinned: bool, warnings: Array<string>): Result<ConvertedMesh> {
    const doc = ctx.document;
    const gm = doc.meshes[gmIndex];
    const gmName = gm.name;
    const meshName = gmName != null ? gmName : "mesh";
    let uvSets = 0;
    for (let pi = 0; pi < gm.primitives.length; pi++) {
        const keys = gm.primitives[pi].attributes.keys;
        let n = 0;
        for (let k = 0; k < keys.length; k++) if (keys[k].kind == SemanticKind.TexCoords) n++;
        if (n > uvSets) uvSets = n;
    }
    const mesh = uvSets == 0 ? Mesh.new() : Mesh.withDefaultUv();
    for (let set = 1; set < uvSets; set++) mesh.addUvLayer(layerName(set));
    const slots: Array<u32> = [];
    // Absolute shape key positions per morph target, by vertex id.
    const morph: Array<VertPositions> = [];
    const weld = new Map<string, u32>();
    let degenerate = 0;
    let morphWarned = false;
    for (let pi = 0; pi < gm.primitives.length; pi++) {
        const prim = gm.primitives[pi];
        const mode = primitiveMode(prim);
        // A POINTS primitive comes back as loose vertices, which is exactly
        // what a point cloud is here and what `export` writes for one.
        // Everything else but triangles is still skipped.
        if (mode == Mode.Points) {
            const reader = new PrimitiveReader(doc, prim, ctx.buffers);
            const positions = reader.readPositions();
            if (positions != null) {
                for (let i = 0; i + 2 < positions.length; i += 3) {
                    const co = ctx.convInv.transformPoint3(Vec3(positions[i], positions[i + 1], positions[i + 2])) * opts.scale;
                    mesh.addVert(co);
                }
            } else {
                warnings.push("'" + meshName + "': primitive " + pi.toString() + " has no POSITION; skipped");
            }
            continue;
        }
        if (mode != Mode.Triangles) {
            warnings.push(
                "'" + meshName + "': primitive " + pi.toString() + " is " + modeDebug(mode)
                    + ", only triangles are imported; skipped",
            );
            continue;
        }
        const targets = prim.targets;
        if (targets != null && targets.length > 0 && !opts.morphTargets && !morphWarned) {
            warnings.push("'" + meshName + "': morph targets skipped");
            morphWarned = true;
        }
        let sparse = prim.indices >= 0 && doc.accessors[prim.indices].sparse != null;
        if (!sparse) {
            const vals = prim.attributes.values;
            for (let k = 0; k < vals.length; k++) {
                if (doc.accessors[vals[k]].sparse != null) {
                    sparse = true;
                    break;
                }
            }
        }
        if (sparse) {
            return IoError.unsupported(ctx.path, "sparse accessor on mesh '" + meshName + "'").fail<ConvertedMesh>();
        }
        const reader = new PrimitiveReader(doc, prim, ctx.buffers);
        const rawPositions = reader.readPositions();
        if (rawPositions == null) {
            warnings.push("'" + meshName + "': primitive " + pi.toString() + " has no POSITION; skipped");
            continue;
        }
        const positions: Array<Vec3> = [];
        for (let i = 0; i + 2 < rawPositions.length; i += 3) {
            positions.push(ctx.convInv.transformPoint3(Vec3(rawPositions[i], rawPositions[i + 1], rawPositions[i + 2])) * opts.scale);
        }
        const rawNormals = reader.readNormals();
        let normals: Array<Vec3>? = null;
        if (rawNormals != null) {
            const ns: Array<Vec3> = [];
            for (let i = 0; i + 2 < rawNormals.length; i += 3) {
                ns.push(ctx.convInv.transformVector3(Vec3(rawNormals[i], rawNormals[i + 1], rawNormals[i + 2])));
            }
            normals = ns;
        }
        const uvs: Array<Float32Array> = [];
        for (let set = 0; set < uvSets; set++) {
            const t = reader.readTexCoords(<u32>set);
            uvs.push(t != null ? t.intoF32() : new Float32Array(0));
        }
        let indices: Uint32Array;
        const ri = reader.readIndices();
        if (ri != null) {
            indices = ri.intoU32();
        } else {
            indices = new Uint32Array(positions.length);
            for (let i = 0; i < positions.length; i++) indices[i] = <u32>i;
        }
        // Weights > 0 only, summed when a joint repeats in the 4 slots.
        const rj = reader.readJoints(0);
        const rw = reader.readWeights(0);
        let groups: Array<Array<GroupWeight>>? = null;
        if (skinned && rj != null && rw != null) {
            const j = rj.intoU16();
            const w = rw.intoF32();
            const n = min(rj.count, rw.count);
            const gs: Array<Array<GroupWeight>> = [];
            for (let i = 0; i < n; i++) {
                const out: Array<GroupWeight> = [];
                for (let k = 0; k < 4; k++) {
                    const jj = <u32>j[i * 4 + k];
                    const ww = w[i * 4 + k];
                    if (ww > 0.0) {
                        let found = -1;
                        for (let q = 0; q < out.length; q++) {
                            if (out[q].group == jj) {
                                found = q;
                                break;
                            }
                        }
                        if (found >= 0) out[found].weight += ww;
                        else out.push(GroupWeight.new(jj, ww));
                    }
                }
                gs.push(out);
            }
            groups = gs;
        }
        // Welded vertices keep the first corner's weights: a split vertex
        // is one source vertex in the exporter, so they agree.
        const verts: Array<u32> = [];
        for (let i = 0; i < positions.length; i++) {
            const p = positions[i];
            if (opts.mergeVertices) {
                const key = weldKey(p);
                if (weld.has(key)) {
                    verts.push(weld.get(key));
                    continue;
                }
                const v = addWeldVert(mesh, p, groups, i);
                weld.set(key, v);
                verts.push(v);
            } else {
                verts.push(addWeldVert(mesh, p, groups, i));
            }
        }
        if (opts.morphTargets) {
            // Deltas are relative to the primitive's own POSITION stream,
            // which `positions` already holds in Hedra space.
            const mts = reader.readMorphTargets();
            for (let ti = 0; ti < mts.length; ti++) {
                const deltas = mts[ti].positions;
                if (deltas == null) continue;
                while (morph.length <= ti) morph.push(new VertPositions());
                const dn = deltas.length / 3;
                for (let i = 0; i < dn; i++) {
                    if (i >= verts.length || i >= positions.length) continue;
                    const d = ctx.convInv.transformVector3(Vec3(deltas[i * 3], deltas[i * 3 + 1], deltas[i * 3 + 2])) * opts.scale;
                    morph[ti].ids.push(verts[i]);
                    morph[ti].cos.push(positions[i] + d);
                }
            }
        }
        let materialIndex: u16 = 0;
        if (prim.material >= 0) {
            const si = <u32>ctx.matMap[prim.material];
            let pos = slots.indexOf(si);
            if (pos < 0) {
                slots.push(si);
                pos = slots.length - 1;
            }
            materialIndex = <u16>pos;
        }
        // (No material: glTF's default material, first slot if any exists.)
        let outOfRange = 0;
        const tris = indices.length / 3;
        for (let t = 0; t < tris; t++) {
            const src0 = indices[t * 3];
            const src1 = indices[t * 3 + 1];
            const src2 = indices[t * 3 + 2];
            const vl = <u32>verts.length;
            if (src0 >= vl || src1 >= vl || src2 >= vl) {
                outOfRange += 1;
                continue;
            }
            const src: Array<i32> = [<i32>src0, <i32>src1, <i32>src2];
            const ids: Array<u32> = [verts[src[0]], verts[src[1]], verts[src[2]]];
            if (ids[0] == ids[1] || ids[1] == ids[2] || ids[0] == ids[2]) {
                degenerate += 1;
                continue;
            }
            const f = mesh.addFace(ids);
            // Flat faces come back flat: the file's normals are only used to
            // tell whether they were smooth-shaded.
            let smooth = false;
            if (normals != null) {
                const fnorm = mesh.faces.at(f).normal;
                for (let k = 0; k < 3; k++) {
                    if (src[k] < normals.length && normals[src[k]].normalizeOrZero().dot(fnorm) < <f32>0.9999) {
                        smooth = true;
                        break;
                    }
                }
            }
            const face = mesh.faces.at(f);
            face.smooth = smooth;
            face.materialIndex = materialIndex;
            let k = 0;
            for (let l = face.loopStart; l < face.loopStart + face.loopLen; l++) {
                for (let layer = 0; layer < uvs.length; layer++) {
                    const set = uvs[layer];
                    const at = src[k];
                    if (at < set.length / 2) {
                        // Back to Blender's bottom-left UV origin.
                        const lp = mesh.loops.at(l);
                        if (layer >= lp.uv.length) {
                            panic("index out of bounds: the len is " + lp.uv.length.toString() + " but the index is " + layer.toString());
                        }
                        lp.uv[layer] = Vec2(set[at * 2], <f32>1.0 - set[at * 2 + 1]);
                    }
                }
                k++;
            }
        }
        if (outOfRange > 0) {
            warnings.push("'" + meshName + "': " + outOfRange.toString() + " triangle(s) index past the vertex data; skipped");
        }
    }
    if (degenerate > 0) {
        warnings.push("'" + meshName + "': " + degenerate.toString() + " degenerate triangle(s) dropped");
    }
    if (morph.length > 0) {
        const names = targetNames(gm, morph.length);
        addShapeKeys(mesh, names, morph, gm.weights);
    }
    // Smooth and material flags were written directly.
    mesh.touch();
    return Result.okv<ConvertedMesh>(new ConvertedMesh(mesh, slots));
}

// Adds a welded vertex to `mesh` with its group weights.
function addWeldVert(mesh: Mesh, p: Vec3, groups: Array<Array<GroupWeight>>?, i: i32): u32 {
    const v = mesh.addVert(p);
    if (groups != null && i < groups.length) {
        const g = groups[i];
        const copy: Array<GroupWeight> = [];
        for (let k = 0; k < g.length; k++) copy.push(g[k].clone());
        mesh.verts.at(v).groups = copy;
    }
    return v;
}

// The node walk's pending entry: node, its parent object (NO_OBJ = None),
// and the joint it hangs under when its glTF parent is a joint.
class Pending {
    node: i32;
    parent: u32;
    under: UnderJoint?;
    constructor(node: i32, parent: u32, under: UnderJoint?) {
        this.node = node;
        this.parent = parent;
        this.under = under;
    }
}

// `(skin, joint node)`.
class UnderJoint {
    skin: i32;
    joint: i32;
    constructor(skin: i32, joint: i32) {
        this.skin = skin;
        this.joint = joint;
    }
}

// An object id with one or two indices: bookkeeping of the walk.
class ObjRef {
    id: u32;
    a: i32;
    b: i32;
    constructor(id: u32, a: i32, b: i32) {
        this.id = id;
        this.a = a;
        this.b = b;
    }
}

export function importGltf(scene: Scene, path: string, opts: ImportOpts): Result<ImportReport> {
    return import_(scene, path, opts);
}

// `gltf_import::import`. (`import` is a keyword; `importGltf` is an alias.)
export function import_(scene: Scene, path: string, opts: ImportOpts): Result<ImportReport> {
    const e = pathExtension(path);
    const ext = e != null ? toAsciiLowercase(e) : "";
    if (ext != "glb" && ext != "gltf") {
        return IoError.badExtension(ext).fail<ImportReport>();
    }
    const c = conversion(opts.axisForward, opts.axisUp);
    if (!c.isSome) {
        return IoError.badAxes(axisLabel(opts.axisForward), axisLabel(opts.axisUp)).fail<ImportReport>();
    }
    const conv = c.value;
    const convInv = conv.inverse();
    const pp = pathParent(path);
    const gltfDir = pp != null && pp.length > 0 ? pp : ".";
    // Parsed without validation on purpose: a compressed asset is *not*
    // valid glTF as it sits on disk -- a Draco primitive's accessors have no
    // buffer view, and both extensions are in `extensionsRequired` -- so
    // validating here would reject exactly the files this understands. The
    // decompressed document is validated instead, a few lines down, which is
    // a stronger check anyway: it covers the bytes that were actually decoded.
    const file = vfs.read(path);
    if (!file.ok) return ioError<Uint8Array>(path, file).fail<ImportReport>();
    const parsed = gltfFromReaderWithoutValidation(file.value);
    if (!parsed.ok) return gltfError<ImportReport, Gltf>(path, parsed);
    const sidecars: Array<string> = [];
    const lb = loadBuffers(parsed.value.document, gltfDir, parsed.value.blob, path, sidecars);
    if (!lb.ok) return lb.forward<ImportReport>();
    const raw = lb.value;

    // Decompress before anything reads the document, so the rest of this
    // file never has to know the asset was compressed.
    const root = parsed.value.document;
    const cr = compressDecode(root, raw, path);
    if (!cr.ok) return cr.forward<ImportReport>();
    const compressed = cr.value;

    // What is still required is genuinely unsupported; whatever the pass
    // above handled has been struck off. Checked before validation so the
    // answer names the extension instead of the damage it did.
    for (let i = 0; i < root.extensionsRequired.length; i++) {
        const required = root.extensionsRequired[i];
        if (!opts.extensions.includes(required)) {
            return IoError.unsupported(path, "required extension " + required).fail<ImportReport>();
        }
    }
    const dv = documentFromJson(root, opts.extensions);
    if (!dv.ok) return gltfError<ImportReport, Root>(path, dv);
    const document = dv.value;
    const buffers = raw;

    const report = new ImportReport();
    report.sidecars = sidecars;
    for (let i = 0; i < compressed.warnings.length; i++) report.warnings.push(compressed.warnings[i]);
    report.compression = compressed;
    // Only what an option turned off is reported as skipped; everything
    // here has an importer now.
    const lights = documentLights(document);
    const skipN: Array<i32> = [
        opts.cameras ? 0 : document.cameras.length,
        opts.lights ? 0 : (lights != null ? lights.length : 0),
        opts.animations || !opts.warnSkippedAnimations ? 0 : document.animations.length,
    ];
    const skipWhat: Array<string> = ["camera(s)", "light(s)", "animation(s)"];
    const skipWhy: Array<string> = ["--cameras off", "--lights off", "--animations off"];
    for (let i = 0; i < 3; i++) {
        if (skipN[i] > 0) {
            report.warnings.push(skipN[i].toString() + " " + skipWhat[i] + " skipped (" + skipWhy[i] + ")");
        }
    }

    const td = opts.texturesDir;
    const images = new ImageStore(document, buffers, gltfDir, opts.baseDir, td != null ? td : pathJoin(opts.baseDir, "textures"));
    images.sink = opts.imageSink;

    // Materials in file order; pushed one by one so unique naming sees the
    // previous ones.
    const matMap: Array<i32> = [];
    for (let i = 0; i < document.materials.length; i++) {
        const m = document.materials[i];
        const mn = m.name;
        const name = scene.uniqueMaterialName(mn != null ? mn : "Material");
        const material = convertMaterial(document, m, name, images, report.warnings);
        if (!material.ok) return material.forward<ImportReport>();
        scene.materials.push(material.value);
        matMap.push(scene.materials.length - 1);
    }
    report.materials = matMap.length;
    // The whole materials after every core one, so that the images only an
    // extension names come last and the core images keep the names they
    // have without `pbr`: the scene is the same either way.
    if (opts.pbr) {
        const pbrImages = new StorePbrImages(document, images);
        for (let i = 0; i < document.materials.length; i++) {
            const name = scene.materials[matMap[i]].name;
            const p = pbrFromGltf(document, document.materials[i], name, pbrImages, report.warnings);
            if (!p.ok) return p.forward<ImportReport>();
            report.pbrMaterials.push(p.value);
        }
    }

    const ctx = new MeshContext(path, document, buffers, convInv, matMap);
    // Converted once per glTF mesh (with and without skin weights);
    // instancing nodes get copies. Key: mesh index * 2 + skinned.
    const meshCache = new Map<i64, ConvertedMesh>();

    // Skins: joint nodes become bones, not objects; the armature objects
    // exist before the walk so skinned meshes and bone children can point at
    // them, and are placed once their node (if any) has been visited.
    const graph = NodeGraph.create(document);
    const skins = SkinSet.create(document, buffers, graph);
    const toScene = new ToScene(conv, convInv, opts.scale);
    const armObj: Array<u32> = [];
    for (let si = 0; si < skins.skins.length; si++) {
        const skin = skins.skins[si];
        let base: string;
        if (skin.armNode >= 0) {
            const nn = skin.armNode < document.nodes.length ? document.nodes[skin.armNode].name : null;
            base = nn != null ? nn : "Armature";
        } else {
            base = skin.name;
        }
        const obj = new Object(scene.uniqueName(base), ObjectData.fromArmature(new Armature()));
        obj.select = opts.select;
        armObj.push(scene.addObject(obj));
        report.objects += 1;
    }
    report.armatures = armObj.length;
    // (mesh object, skin) to bind after the walk.
    const skinnedObjs: Array<ObjRef> = [];
    // Objects hanging under a joint: (object, skin, joint node).
    const boneChildren: Array<ObjRef> = [];
    // Children of skinned mesh nodes: (object, parent node), whose parent
    // object loses its node transform.
    const skinnedChildren: Array<ObjRef> = [];
    // Where every node landed, for the animation channels.
    const objOfNode = new Map<i32, u32>();

    // Nodes of the default scene (or every root when the file has none),
    // depth first so parents exist before their children.
    let roots: Array<i32>;
    let sceneIndex = defaultScene(document);
    if (sceneIndex < 0 && document.scenes.length > 0) sceneIndex = 0;
    if (sceneIndex >= 0) {
        roots = document.scenes[sceneIndex].nodes.slice(0);
    } else {
        const children = new Set<i32>();
        for (let i = 0; i < document.nodes.length; i++) {
            const ch = document.nodes[i].children;
            if (ch != null) for (let k = 0; k < ch.length; k++) children.add(ch[k]);
        }
        roots = [];
        for (let i = 0; i < document.nodes.length; i++) if (!children.has(i)) roots.push(i);
    }
    if (opts.select) {
        const all = scene.objects.values();
        for (let i = 0; i < all.length; i++) all[i].select = false;
    }
    const stack: Array<Pending> = [];
    for (let i = roots.length - 1; i >= 0; i--) stack.push(new Pending(roots[i], NO_OBJ, null));
    let lastRoot: u32 = NO_OBJ;
    while (stack.length > 0) {
        const pending = stack.pop();
        const ni = pending.node;
        const node = document.nodes[ni];
        const parent = pending.parent;
        const underJoint = pending.under;
        if (skins.isJoint(ni)) {
            // Bones, not objects; anything else under them parents to the bone.
            const joint = skins.jointOf(ni);
            const ch = node.children;
            if (ch != null) {
                for (let k = ch.length - 1; k >= 0; k--) {
                    const under = joint != null ? new UnderJoint(joint.skin, ni) : null;
                    stack.push(new Pending(ch[k], NO_OBJ, under));
                }
            }
            continue;
        }
        const nodeSkin = node.skin;
        const adopted = skins.adoptedSkin(ni);
        let data: ObjectData;
        let slots: Array<u32>;
        if (node.mesh >= 0) {
            const skinned = nodeSkin >= 0;
            const key = <i64>node.mesh * 2 + (skinned ? 1 : 0);
            let cached: ConvertedMesh;
            if (meshCache.has(key)) {
                cached = meshCache.get(key);
            } else {
                const cm = convertMesh(node.mesh, ctx, opts, skinned, report.warnings);
                if (!cm.ok) return cm.forward<ImportReport>();
                cached = cm.value;
                meshCache.set(key, cached);
            }
            report.meshes += 1;
            report.triangles += cached.mesh.faces.len();
            report.shapeKeys += cached.mesh.shapeKeys.length;
            const mesh = cached.mesh.clone();
            // Node weights override the mesh's own defaults.
            const w = node.weights;
            if (w != null) {
                for (let k = 1; k < mesh.shapeKeys.length && k - 1 < w.length; k++) {
                    const sk = mesh.shapeKeys[k];
                    const v = w[k - 1];
                    sk.value = v;
                    sk.sliderMin = minF32(sk.sliderMin, v);
                    sk.sliderMax = maxF32(sk.sliderMax, v);
                }
            }
            data = ObjectData.fromMesh(mesh);
            slots = cached.slots.slice(0);
        } else if (adopted >= 0) {
            data = ObjectData.fromEmpty(new Empty());
            slots = [];
        } else {
            // Both a camera and a light look down the node's local -Z, which
            // is what Hedra means by either, so the converted node
            // transform is the whole of their orientation.
            const cam = node.camera;
            const li = nodeLight(document, node);
            if (cam >= 0 && opts.cameras) {
                report.cameras += 1;
                data = ObjectData.fromCamera(cameraFromGltf(document.cameras[cam], opts.scale));
            } else if (li >= 0 && opts.lights) {
                const l: KhrLight = (lights as Array<KhrLight>)[li];
                const light = lightFromGltf(l, opts.lightingMode);
                if (light.kind == LightKind.Spot) {
                    const ln = l.name;
                    report.warnings.push(
                        "'" + (ln != null ? ln : "Light") + "' is a spot light; Hedra does not model cone angles, "
                            + "so innerConeAngle / outerConeAngle were dropped",
                    );
                }
                report.lights += 1;
                data = ObjectData.fromLight(light);
            } else {
                data = ObjectData.fromEmpty(new Empty(EmptyDisplay.PlainAxes, 1.0));
            }
            slots = [];
        }
        const instances = gpuInstances(document, buffers, node, convInv, opts.scale);
        // An instanced node names two objects: the thing being copied and the
        // copies. The glTF *mesh* name belongs to the first and the *node*
        // name to the second, which is also how the exporter writes them, so
        // a round trip leaves both where they were.
        const nodeName = node.name;
        const gmName: string? = node.mesh >= 0 ? document.meshes[node.mesh].name : null;
        let base: string;
        if (instances != null) {
            if (gmName != null) base = gmName;
            else if (nodeName != null) base = nodeName;
            else base = "Mesh";
        } else {
            if (nodeName != null) base = nodeName;
            else if (gmName != null) base = gmName;
            else {
                switch (data.kind) {
                    case ObjectDataKind.Mesh: base = "Mesh"; break;
                    case ObjectDataKind.Camera: base = "Camera"; break;
                    case ObjectDataKind.Light: base = "Light"; break;
                    default: base = "Empty";
                }
            }
        }
        // Undo the exporter's frame change, then apply the unit scale to the
        // translation only (mesh data is scaled directly).
        const local = toScene.apply(mat4FromCols(nodeTransform(node).matrix()));
        let id: u32;
        if (adopted >= 0) {
            // The armature node is the armature object made before the walk.
            id = armObj[adopted];
        } else {
            id = scene.addObject(new Object(scene.uniqueName(base), data));
            report.objects += 1;
        }
        objOfNode.set(ni, id);
        const obj = scene.objects.at(id);
        obj.transform = Transform.fromMatrix(local);
        obj.materialSlots = slots;
        obj.parent = parent != NO_OBJ ? new Parent(parent, ParentKind.object()) : null;
        obj.select = opts.select;
        if (nodeSkin >= 0 && nodeSkin < armObj.length) {
            skinnedObjs.push(new ObjRef(id, nodeSkin, 0));
        }
        if (underJoint != null) {
            boneChildren.push(new ObjRef(id, underJoint.skin, underJoint.joint));
        }
        const gp = graph.parent[ni];
        if (gp >= 0 && gp < document.nodes.length && document.nodes[gp].skin >= 0) {
            skinnedChildren.push(new ObjRef(id, gp, 0));
        }
        if (parent == NO_OBJ && underJoint == null) {
            lastRoot = id;
        }
        // `EXT_mesh_gpu_instancing`: the node's mesh is drawn once per
        // instance transform and *not* at the node itself, so the mesh object
        // becomes a hidden prototype and a cloud of points beside it carries
        // the copies.
        if (instances != null && instances.length > 0) {
            const cloud = instanceCloud(scene, id, instances, nodeName, opts.select);
            report.objects += 1;
            report.warnings.push(
                "'" + scene.objects.at(id).name + "': EXT_mesh_gpu_instancing places " + instances.length.toString()
                    + " copies; they are an instance modifier on '" + scene.objects.at(cloud).name
                    + "', and the mesh itself is marked hide-render because the file draws it only at those copies",
            );
        }
        const ch = node.children;
        if (ch != null) {
            for (let k = ch.length - 1; k >= 0; k--) stack.push(new Pending(ch[k], id, null));
        }
    }

    // Bones and poses, now that every armature object has its transform.
    const boneNames: Array<Array<string>> = [];
    for (let si = 0; si < skins.skins.length; si++) {
        const skin = skins.skins[si];
        const armId = armObj[si];
        const invWorld = scene.worldMatrix(armId).inverse();
        const toArm = new ToArm(invWorld, toScene);
        const arm = new Armature();
        const names = buildArmature(arm, document, skin, graph, toArm, opts.carryJointFrames);
        const ao = scene.objects.at(armId);
        if (ao.data.kind == ObjectDataKind.Armature) ao.data.armatureData = arm;
        boneNames.push(names);
    }
    // Skinned meshes: vertices are in bind (world) space and glTF ignores
    // the node transform, so the object sits at the world origin under its
    // armature, with the groups and the modifier that re-deform it.
    for (let i = 0; i < skinnedObjs.length; i++) {
        const so = skinnedObjs[i];
        const armId = armObj[so.a];
        const invWorld = scene.worldMatrix(armId).inverse();
        const obj = scene.objects.at(so.id);
        obj.parent = new Parent(armId, ParentKind.armature());
        obj.parentInverse = invWorld;
        obj.transform = TRANSFORM_IDENTITY;
        const names = boneNames[so.a];
        const groups: Array<VertexGroup> = [];
        for (let k = 0; k < names.length; k++) groups.push(new VertexGroup(names[k], false));
        obj.vertexGroups = groups;
        obj.modifiers.push(new Modifier("Armature", ModifierKindArmature.create(armId, false, true, false), true));
    }
    // Children of a skinned node keep the world placement the file gave them
    // although their parent object moved to the origin.
    for (let i = 0; i < skinnedChildren.length; i++) {
        const sc = skinnedChildren[i];
        const p = scene.objects.at(sc.id).parent;
        let parentWorld = MAT4_IDENTITY;
        if (p != null) parentWorld = scene.worldMatrix(p.id);
        scene.objects.at(sc.id).parentInverse = parentWorld.inverse() * toScene.apply(graph.global[sc.a]);
    }
    // Objects under a joint: parented to the bone, placed where the file has
    // them (the parent inverse absorbs the joint's global transform).
    for (let i = 0; i < boneChildren.length; i++) {
        const bc = boneChildren[i];
        const armId = armObj[bc.a];
        const skin = skins.skins[bc.a];
        const bone = skin.jointOfNode.has(bc.b) ? boneNames[bc.a][skin.jointOfNode.get(bc.b)] : "";
        const invWorld = scene.worldMatrix(armId).inverse();
        const obj = scene.objects.at(bc.id);
        obj.parent = new Parent(armId, ParentKind.boneOf(bone));
        obj.parentInverse = invWorld * toScene.apply(graph.global[bc.b]);
    }
    if (opts.keepDocument) {
        const kept = new GltfImportMap(document, buffers, conv, opts.scale, objOfNode, skins, graph, armObj, boneNames);
        for (let i = 0; i < skinnedObjs.length; i++) {
            kept.skinnedObjs.push(skinnedObjs[i].id);
            kept.skinOfObj.push(skinnedObjs[i].a);
        }
        report.gltf = kept;
    }
    if (opts.animations && document.animations.length > 0) {
        const skinned: Array<u32> = [];
        for (let i = 0; i < skinnedObjs.length; i++) skinned.push(skinnedObjs[i].id);
        const map = new AnimScene(objOfNode, skins, armObj, boneNames, skinned);
        report.animations = importAnimations(scene, document, buffers, conv, opts.scale, map, report.warnings);
    }
    if (lastRoot != NO_OBJ) {
        scene.active = lastRoot;
    }
    report.textures = images.count();
    return Result.okv<ImportReport>(report);
}
