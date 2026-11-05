// The .lmbake resource (milestone 19, Godot's LightmapGIData saved as
// .lmbake): a LightmapGI's bake on disk, as the CLI's `bake` and the scene
// editor's Bake button write it and every program reads it. Its format is
// docs/formats/RSCN.md "LightmapGIData" (normative):
//
//   <stem>.lmbake            XML: the settings baked with, the layers, the
//                            instances (node, part, layer, counts, digest,
//                            transform) and the probes (scene space, Y up,
//                            relative to the root of the scene that
//                            declares the LightmapGI)
//   <stem>.lightmap-<k>.hdr  layer k, a Radiance HDR image (hdr.as encodeHdr)
//   <stem>.lmuv              the instances' lightmapped meshes: "LMUV",
//                            version 1, then per instance its xref, uv and
//                            indices, little-endian
//
// Every file is written deterministically (the same LightmapData, the same
// bytes: no date, no version, numbers by their shortest round trip) and
// named relative to the .lmbake's directory. In memory a LightmapData is in
// the renderer's space (Z up); the reader and the writer convert the
// instances' transforms and the probes' positions and SH from and to scene
// space (sh.as, ../space.as), which only permutes and negates, so nothing
// is lost.
//
// The reader trusts nothing: every count, index, layer and coordinate is
// checked, so that the adapter (../render/lightmap.as) can build meshes from
// a bake without checking again. Elements and attributes it does not know
// are ignored, so an older reader takes a newer file's bake.

import { Result } from "../../base/util";
import { MAT4_IDENTITY, Mat4, Vec3 } from "../../base/vecmath";
import { displayF32 } from "../../base/fmt";
import { XmlDocument, XmlNode, XmlPos, parseXml, xmlErrorOf } from "../../base/xml";
import { vfs } from "../../fs/vfs";
import { fileStem, parent } from "../../fs/path";
import { decodeHdr } from "../../render/hdr";
import {
    BakeSettings, LIGHTMAP_MAX_SIZE, LIGHTMAP_PROBE_SUBDIV, LIGHTMAP_QUALITY_NAMES, LightmapData, LightmapInstance,
    instanceKey,
} from "../../render/lightmap/data";
import { SH_L1_FLOATS, shSceneToRender } from "../../render/lightmap/sh";
import { SceneryError } from "../error";
import { LightmapGIData, Resource } from "../resource/types";
import { SCENE_TO_MODEL, sceneToModel } from "../space";
import { ValueKind } from "../value";
import { parseValueText } from "../value_text";
import { CLI } from "../../base/names";

// One file of a bake: its absolute path and its bytes.
export class LmbakeFile {
    path: string;
    bytes: Uint8Array;

    constructor(path: string, bytes: Uint8Array) {
        this.path = path;
        this.bytes = bytes;
    }
}

function dirAndStem(lmbake: string): string {
    const dir = parent(lmbake);
    const stem = fileStem(lmbake);
    const d = dir != null ? dir : "";
    const s = stem != null ? stem : "lightmap";
    return d.length == 0 ? s : (d == "/" ? "/" + s : d + "/" + s);
}

// Where a scene's bake goes by default: `<dir>/<scene stem>.lmbake`.
export function defaultLmbakePath(scenePath: string): string {
    return dirAndStem(scenePath) + ".lmbake";
}

// Layer `layer`'s image beside the .lmbake at `lmbake`:
// `<dir>/<stem>.lightmap-<layer>.hdr`.
export function lmbakeImagePath(lmbake: string, layer: i32): string {
    return dirAndStem(lmbake) + ".lightmap-" + layer.toString() + ".hdr";
}

// The lightmapped meshes' file beside it: `<dir>/<stem>.lmuv`.
export function lmbakeUvPath(lmbake: string): string {
    return dirAndStem(lmbake) + ".lmuv";
}

// The version of the .lmbake's XML (`format`) and of the .lmuv's header.
export const LMBAKE_FORMAT: i32 = 1;
export const LMUV_VERSION: u32 = 1;

// LightmapGI.environment_mode by Godot's names (data.as LIGHTMAP_ENV_*).
export const ENVIRONMENT_NAMES: StaticArray<string> = ["disabled", "scene", "custom_sky", "custom_color"];

// The end of the warning a scene's unreadable bake becomes (the loader's
// readLightmap): the CLI's `bake` drops it from its answer, since the bake it
// writes mends it.
export const LMBAKE_UNREAD_SUFFIX = "; the scene is drawn with real-time light";

const BAKE_AGAIN = "bake the scene again (`" + CLI + " bake <scene>`); the format is docs/formats/RSCN.md \"LightmapGIData\"";

// --- reading -----------------------------------------------------------

// The .lmbake at `abs` and the files it names, read through the vfs into
// a LightmapGIData (the loader's reader of ext_resource type
// LightmapGIData). Errors: lightmap-data-invalid, at the file (line 0) or
// at the element that is wrong.
export function readLmbake(abs: string, display: string): Result<Resource> {
    const bytes = vfs.read(abs);
    if (!bytes.ok) {
        const e = SceneryError.at("lightmap-data-invalid", display, 0, 0, "cannot read " + display + ": " + bytes.err, BAKE_AGAIN);
        return e.fail<Resource>();
    }
    const r = new LmbakeReader(abs, display);
    const data = r.read(bytes.value);
    if (data == null) return r.error!.fail<Resource>();
    return Result.okv<Resource>(lightmapResource(data));
}

// The absolute paths of the files the .lmbake text `bytes` at `abs` names
// (its images and its .lmuv), for prefetching and the editor's closure;
// empty when it does not parse.
export function lmbakeSidecars(bytes: Uint8Array, abs: string): Array<string> {
    const out = new Array<string>();
    const parsed = parseXml(bytes, abs);
    if (!parsed.ok) return out;
    const root = parsed.value.root;
    if (root.name != "lightmap_gi_data") return out;
    const dir = dirOfPath(abs);
    const els = root.elements();
    for (let i = 0; i < els.length; i++) {
        const e = els[i];
        if (e.name != "layer" && e.name != "meshes") continue;
        const p = e.attr("path");
        if (p == null || !relativeOk(p)) continue;
        const full = joinDir(dir, p);
        if (!out.includes(full)) out.push(full);
    }
    return out;
}

// The directory part of an absolute path, or a display path ("res://a/b"
// gives "res://a"; a bare name gives "").
function dirOfPath(p: string): string {
    const slash = p.lastIndexOf("/");
    if (slash < 0) return "";
    if (slash == 0) return "/";
    // ("res://a" is in "res://")
    if (p.charCodeAt(slash - 1) == 47) return p.substring(0, slash + 1);
    return p.substring(0, slash);
}

function joinDir(dir: string, rel: string): string {
    if (dir.length == 0) return rel;
    return dir.endsWith("/") ? dir + rel : dir + "/" + rel;
}

// A path a bake may name: relative, `/` separated, with no empty, `.` or
// `..` part (a bake's files are beside it or below it).
function relativeOk(p: string): bool {
    if (p.length == 0 || p.startsWith("/") || p.indexOf("\\") >= 0 || p.indexOf(":") >= 0) return false;
    const parts = p.split("/");
    for (let i = 0; i < parts.length; i++) {
        const s = parts[i];
        if (s.length == 0 || s == "." || s == "..") return false;
    }
    return true;
}

class LmbakeReader {
    abs: string;
    display: string;
    error: SceneryError? = null;
    // By instance read: the lightmap vertices and indices its element
    // says it has. Nothing is allocated from them until readMeshes has
    // checked them against the .lmuv's real size (a damaged count must
    // fail as lightmap-data-invalid, not as an allocation of gigabytes).
    lightmapVertices: Array<i32> = [];
    lightmapIndices: Array<i32> = [];

    constructor(abs: string, display: string) {
        this.abs = abs;
        this.display = display;
    }

    // Records the first problem (at `pos`, or the file when unknown);
    // returns null for the caller to return.
    fail(pos: XmlPos?, message: string): LightmapData? {
        if (this.error == null) {
            const line = pos != null ? pos.line : 0;
            const col = pos != null ? pos.col : 0;
            this.error = SceneryError.at("lightmap-data-invalid", this.display, line, col, message, BAKE_AGAIN);
        }
        return null;
    }

    failed(): bool {
        return this.error != null;
    }

    read(bytes: Uint8Array): LightmapData? {
        const parsed = parseXml(bytes, this.display);
        if (!parsed.ok) {
            const xe = xmlErrorOf<XmlDocument>(parsed);
            return this.fail(xe != null ? xe.pos : null, "not an .lmbake file: " + (xe != null ? xe.message : parsed.err));
        }
        const root = parsed.value.root;
        if (root.name != "lightmap_gi_data") {
            return this.fail(root.pos, "not an .lmbake file: the root element is <" + root.name + ">, not <lightmap_gi_data>");
        }
        const format = this.intAttr(root, "format", 1, i32.MAX_VALUE);
        if (this.failed()) return null;
        if (format != LMBAKE_FORMAT) {
            return this.fail(root.pos, "format " + format.toString() + " is newer than this program reads (format "
                + LMBAKE_FORMAT.toString() + ")");
        }
        const data = new LightmapData();
        const width = this.intAttr(root, "width", 0, LIGHTMAP_MAX_SIZE);
        const height = this.intAttr(root, "height", 0, LIGHTMAP_MAX_SIZE);
        if (this.failed()) return null;
        data.images.width = width;
        data.images.height = height;

        const els = root.elements();
        // The elements by kind, in order; the others are ignored.
        let settings: XmlNode? = null;
        let meshes: XmlNode? = null;
        const layers = new Array<XmlNode>();
        const instances = new Array<XmlNode>();
        const probes = new Array<XmlNode>();
        for (let i = 0; i < els.length; i++) {
            const e = els[i];
            if (e.name == "settings") {
                if (settings != null) return this.fail(e.pos, "a second <settings>");
                settings = e;
            } else if (e.name == "meshes") {
                if (meshes != null) return this.fail(e.pos, "a second <meshes>");
                meshes = e;
            } else if (e.name == "layer") layers.push(e);
            else if (e.name == "instance") instances.push(e);
            else if (e.name == "probe") probes.push(e);
        }
        if (settings != null) this.readSettings(settings, data.settings);
        if (this.failed()) return null;

        // The layers, numbered from 0 in order, each an HDR image of the
        // bake's size.
        for (let k = 0; k < layers.length; k++) {
            const e = layers[k];
            const index = this.intAttr(e, "index", 0, i32.MAX_VALUE);
            if (this.failed()) return null;
            if (index != k) return this.fail(e.pos, "layer " + index.toString() + " where layer " + k.toString() + " was due");
            if (width == 0 || height == 0) return this.fail(e.pos, "a layer in a bake of size " + width.toString() + " x " + height.toString());
            const file = this.fileOf(e);
            if (file == null) return null;
            const r = decodeHdr(file);
            if (!r.ok) return this.fail(e.pos, "layer " + k.toString() + ": " + r.err);
            const img = r.value;
            if (<i32>img.width != width || <i32>img.height != height) {
                return this.fail(e.pos, "layer " + k.toString() + " is " + img.width.toString() + " x " + img.height.toString()
                    + ", not the bake's " + width.toString() + " x " + height.toString());
            }
            data.images.layers.push(img);
        }

        // The instances' attributes, then their meshes from the .lmuv.
        const keys = new Set<string>();
        for (let i = 0; i < instances.length; i++) {
            const e = instances[i];
            const inst = this.readInstance(e, layers.length);
            if (inst == null) return null;
            const key = instanceKey(inst.node, inst.part);
            if (keys.has(key)) return this.fail(e.pos, "instance " + key + " is given twice");
            keys.add(key);
            data.instances.push(inst);
        }
        if (instances.length > 0 && meshes == null) {
            return this.fail(root.pos, "instances without <meshes> (the .lmuv file)");
        }
        if (meshes != null) this.readMeshes(meshes, instances, data.instances);
        if (this.failed()) return null;

        // The probes, scene space in the file.
        const sh = new Float32Array(probes.length * SH_L1_FLOATS);
        for (let i = 0; i < probes.length; i++) {
            const e = probes[i];
            const pos = this.vec3Attr(e, "position");
            if (this.failed()) return null;
            const s = this.attrOf(e, "sh");
            if (s == null) return null;
            const parts = s.split(" ");
            if (parts.length != SH_L1_FLOATS) {
                return this.fail(e.pos, "sh holds " + parts.length.toString() + " numbers, not " + SH_L1_FLOATS.toString());
            }
            for (let k = 0; k < SH_L1_FLOATS; k++) {
                const x = numberOf(parts[k]);
                if (isNaN(x)) return this.fail(e.pos, "sh: \"" + parts[k] + "\" is not a number");
                sh[i * SH_L1_FLOATS + k] = <f32>x;
            }
            shSceneToRender(sh, i * SH_L1_FLOATS);
            data.probes.positions.push(sceneToModel(pos));
        }
        data.probes.sh = sh;
        return data;
    }

    readSettings(e: XmlNode, s: BakeSettings): void {
        const q = e.attr("quality");
        if (q != null) {
            const k = nameIndex(LIGHTMAP_QUALITY_NAMES, q);
            if (k < 0) {
                this.fail(e.pos, "quality \"" + q + "\" is none of " + LIGHTMAP_QUALITY_NAMES.join(", "));
                return;
            }
            s.quality = k;
        }
        if (e.attr("bounces") != null) s.bounces = this.intAttr(e, "bounces", 0, i32.MAX_VALUE);
        if (e.attr("bounce_indirect_energy") != null) s.bounceIndirectEnergy = this.floatAttr(e, "bounce_indirect_energy");
        if (e.attr("use_texture_for_bounces") != null) s.useTextureForBounces = this.boolAttr(e, "use_texture_for_bounces");
        if (e.attr("interior") != null) s.interior = this.boolAttr(e, "interior");
        if (e.attr("use_denoiser") != null) s.useDenoiser = this.boolAttr(e, "use_denoiser");
        if (e.attr("denoiser_strength") != null) s.denoiserStrength = this.floatAttr(e, "denoiser_strength");
        if (e.attr("denoiser_range") != null) s.denoiserRange = this.intAttr(e, "denoiser_range", 0, i32.MAX_VALUE);
        if (e.attr("bias") != null) s.bias = this.floatAttr(e, "bias");
        if (e.attr("lightmap_texel_size") != null) s.texelSize = this.floatAttr(e, "lightmap_texel_size");
        if (e.attr("texel_scale") != null) s.texelScale = this.floatAttr(e, "texel_scale");
        if (this.failed()) return;
        const env = e.attr("environment_mode");
        if (env != null) {
            const k = nameIndex(ENVIRONMENT_NAMES, env);
            if (k < 0) {
                this.fail(e.pos, "environment_mode \"" + env + "\" is none of " + ENVIRONMENT_NAMES.join(", "));
                return;
            }
            s.environmentMode = k;
        }
        if (e.attr("generate_probes_subdiv") != null) {
            const cells = this.intAttr(e, "generate_probes_subdiv", 0, i32.MAX_VALUE);
            if (this.failed()) return;
            let k = -1;
            for (let i = 0; i < LIGHTMAP_PROBE_SUBDIV.length; i++) if (LIGHTMAP_PROBE_SUBDIV[i] == cells) k = i;
            if (k < 0) {
                this.fail(e.pos, "generate_probes_subdiv " + cells.toString() + " is none of 0, 4, 8, 16, 32");
                return;
            }
            s.generateProbesSubdiv = k;
        }
    }

    readInstance(e: XmlNode, layers: i32): LightmapInstance? {
        const inst = new LightmapInstance();
        const node = this.attrOf(e, "node");
        if (node == null) return null;
        if (node.length == 0) {
            this.fail(e.pos, "an instance with an empty node path");
            return null;
        }
        inst.node = node;
        inst.part = this.intAttr(e, "part", 0, i32.MAX_VALUE);
        inst.layer = this.intAttr(e, "layer", 0, i32.MAX_VALUE);
        inst.sourceVertices = this.intAttr(e, "vertices", 0, i32.MAX_VALUE);
        inst.sourceTriangles = this.intAttr(e, "triangles", 0, i32.MAX_VALUE / 3);
        const lv = this.intAttr(e, "lightmap_vertices", 0, i32.MAX_VALUE / 2);
        const li = this.intAttr(e, "lightmap_indices", 0, i32.MAX_VALUE);
        if (this.failed()) return null;
        const key = instanceKey(inst.node, inst.part);
        if (inst.layer >= layers) {
            this.fail(e.pos, "instance " + key + " is in layer " + inst.layer.toString() + ", past the bake's "
                + layers.toString() + (layers == 1 ? " layer" : " layers"));
            return null;
        }
        const digest = this.attrOf(e, "digest");
        if (digest == null) return null;
        if (!isDigest(digest)) {
            this.fail(e.pos, "instance " + key + ": digest \"" + digest + "\" is not 16 lowercase hex digits");
            return null;
        }
        inst.digest = digest;
        inst.transform = this.transformAttr(e, "transform");
        if (this.failed()) return null;
        if (li != inst.sourceTriangles * 3) {
            this.fail(e.pos, "instance " + key + ": " + li.toString() + " lightmap indices for "
                + inst.sourceTriangles.toString() + " triangles (three a triangle)");
            return null;
        }
        if (lv > 0 && inst.sourceVertices == 0) {
            this.fail(e.pos, "instance " + key + ": lightmap vertices of a mesh without vertices");
            return null;
        }
        // The arrays' sizes, allocated by readMeshes once the .lmuv holds
        // them (the reader's lightmapVertices and lightmapIndices).
        this.lightmapVertices.push(lv);
        this.lightmapIndices.push(li);
        return inst;
    }

    // The .lmuv `meshes` names into `out` (the instances `els` declared).
    readMeshes(meshes: XmlNode, els: Array<XmlNode>, out: Array<LightmapInstance>): void {
        const size = this.intAttr(meshes, "size", 0, i32.MAX_VALUE);
        if (this.failed()) return;
        const b = this.fileOf(meshes);
        if (b == null) return;
        if (b.length != size) {
            this.fail(meshes.pos, "the .lmuv is " + b.length.toString() + " bytes, not the " + size.toString() + " it should be");
            return;
        }
        if (b.length < 12 || b[0] != 0x4c || b[1] != 0x4d || b[2] != 0x55 || b[3] != 0x56) {
            this.fail(meshes.pos, "the .lmuv does not start with LMUV");
            return;
        }
        const version = u32At(b, 4);
        if (version != LMUV_VERSION) {
            this.fail(meshes.pos, "the .lmuv is version " + version.toString() + ", not " + LMUV_VERSION.toString());
            return;
        }
        const count = u32At(b, 8);
        if (<i64>count != <i64>out.length) {
            this.fail(meshes.pos, "the .lmuv holds " + count.toString() + " meshes for " + out.length.toString() + " instances");
            return;
        }
        let at: i64 = 12;
        for (let i = 0; i < out.length; i++) {
            const inst = out[i];
            const e = els[i];
            const key = instanceKey(inst.node, inst.part);
            if (at + 8 > <i64>b.length) {
                this.fail(e.pos, "instance " + key + ": the .lmuv ends before its mesh");
                return;
            }
            const nv = u32At(b, <i32>at);
            const ni = u32At(b, <i32>at + 4);
            at += 8;
            const lv = this.lightmapVertices[i], li = this.lightmapIndices[i];
            if (<i64>nv != <i64>lv || <i64>ni != <i64>li) {
                this.fail(e.pos, "instance " + key + ": the .lmuv's mesh has " + nv.toString() + " vertices and " + ni.toString()
                    + " indices, not " + lv.toString() + " and " + li.toString());
                return;
            }
            const need = <i64>nv * 12 + <i64>ni * 4;
            if (at + need > <i64>b.length) {
                this.fail(e.pos, "instance " + key + ": the .lmuv ends inside its mesh");
                return;
            }
            // (the file holds them: what is allocated is at most its size)
            inst.xref = new Uint32Array(lv);
            inst.uv = new Float32Array(lv * 2);
            inst.indices = new Uint32Array(li);
            let p = <i32>at;
            for (let k = 0; k < <i32>nv; k++) {
                const x = u32At(b, p);
                p += 4;
                if (<i64>x >= <i64>inst.sourceVertices) {
                    this.fail(e.pos, "instance " + key + ": vertex " + k.toString() + " is source vertex " + x.toString()
                        + ", past its " + inst.sourceVertices.toString());
                    return;
                }
                inst.xref[k] = x;
            }
            for (let k = 0; k < <i32>nv * 2; k++) {
                const u = reinterpret<f32>(u32At(b, p));
                p += 4;
                if (!(u >= 0 && u <= 1)) {
                    this.fail(e.pos, "instance " + key + ": a lightmap coordinate of vertex " + (k >> 1).toString()
                        + " is " + displayF32(u) + ", outside 0 to 1");
                    return;
                }
                inst.uv[k] = u;
            }
            for (let k = 0; k < <i32>ni; k++) {
                const x = u32At(b, p);
                p += 4;
                if (x >= nv) {
                    this.fail(e.pos, "instance " + key + ": index " + k.toString() + " is " + x.toString() + ", past its "
                        + nv.toString() + " lightmap vertices");
                    return;
                }
                inst.indices[k] = x;
            }
            at = <i64>p;
        }
        if (at != <i64>b.length) {
            this.fail(meshes.pos, "the .lmuv has " + (<i64>b.length - at).toString() + " bytes after its last mesh");
        }
    }

    // The bytes of the file element `e`'s path names (beside the .lmbake).
    fileOf(e: XmlNode): Uint8Array? {
        const p = this.attrOf(e, "path");
        if (p == null) return null;
        if (!relativeOk(p)) {
            this.fail(e.pos, "path \"" + p + "\" must be relative to the .lmbake's directory, with / and no . or ..");
            return null;
        }
        const r = vfs.read(joinDir(dirOfPath(this.abs), p));
        if (!r.ok) {
            this.fail(e.pos, "cannot read " + joinDir(dirOfPath(this.display), p) + ": " + r.err);
            return null;
        }
        return r.value;
    }

    attrOf(e: XmlNode, name: string): string? {
        const v = e.attr(name);
        if (v == null) this.fail(e.pos, "<" + e.name + "> has no " + name);
        return v;
    }

    // A whole number from `lo` to `hi`, written in decimal digits.
    intAttr(e: XmlNode, name: string, lo: i32, hi: i32): i32 {
        if (this.failed()) return 0;
        const s = this.attrOf(e, name);
        if (s == null) return 0;
        let v: i64 = 0;
        let ok = s.length > 0 && s.length <= 10;
        for (let i = 0; i < s.length && ok; i++) {
            const c = s.charCodeAt(i);
            if (c < 48 || c > 57) ok = false;
            else v = v * 10 + <i64>(c - 48);
        }
        if (!ok || v < <i64>lo || v > <i64>hi) {
            this.fail(e.pos, "<" + e.name + "> " + name + " \"" + s + "\" is not a whole number from " + lo.toString()
                + " to " + hi.toString());
            return 0;
        }
        return <i32>v;
    }

    floatAttr(e: XmlNode, name: string): f32 {
        if (this.failed()) return 0;
        const s = this.attrOf(e, name);
        if (s == null) return 0;
        const x = numberOf(s);
        if (isNaN(x)) {
            this.fail(e.pos, "<" + e.name + "> " + name + " \"" + s + "\" is not a number");
            return 0;
        }
        return <f32>x;
    }

    boolAttr(e: XmlNode, name: string): bool {
        if (this.failed()) return false;
        const s = this.attrOf(e, name);
        if (s == null) return false;
        if (s == "true") return true;
        if (s != "false") this.fail(e.pos, "<" + e.name + "> " + name + " \"" + s + "\" is not true or false");
        return false;
    }

    // A Transform3D(...) of twelve finite numbers (Godot's order: the
    // basis's rows, then the origin), from the mesh's space to the scene's,
    // as the renderer's world matrix (SCENE_TO_MODEL times it: exact).
    transformAttr(e: XmlNode, name: string): Mat4 {
        if (this.failed()) return MAT4_IDENTITY;
        const s = this.attrOf(e, name);
        if (s == null) return MAT4_IDENTITY;
        const p = parseValueText(s);
        let ok = p.ok && p.value.kind == ValueKind.Transform3D && p.value.n.length == 12;
        for (let k = 0; ok && k < 12; k++) if (!isFinite(p.value.n[k])) ok = false;
        if (!ok) {
            this.fail(e.pos, "<" + e.name + "> " + name + " \"" + s + "\" is not a Transform3D of 12 numbers");
            return MAT4_IDENTITY;
        }
        return SCENE_TO_MODEL * p.value.mat4();
    }

    vec3Attr(e: XmlNode, name: string): Vec3 {
        if (this.failed()) return Vec3(0, 0, 0);
        const s = this.attrOf(e, name);
        if (s == null) return Vec3(0, 0, 0);
        const p = parseValueText(s);
        if (!p.ok || p.value.kind != ValueKind.Vector3 || p.value.n.length != 3
            || !isFinite(p.value.n[0]) || !isFinite(p.value.n[1]) || !isFinite(p.value.n[2])) {
            this.fail(e.pos, "<" + e.name + "> " + name + " \"" + s + "\" is not a Vector3(x, y, z)");
            return Vec3(0, 0, 0);
        }
        return Vec3(<f32>p.value.n[0], <f32>p.value.n[1], <f32>p.value.n[2]);
    }
}

// A finite number written as the format writes one (an int or a float), or
// NaN.
function numberOf(s: string): f64 {
    if (s.length == 0) return NaN;
    const p = parseValueText(s);
    if (!p.ok) return NaN;
    const v = p.value;
    let x: f64 = NaN;
    if (v.kind == ValueKind.Int) x = <f64>v.i;
    else if (v.kind == ValueKind.Float) x = v.f;
    return isFinite(x) ? x : NaN;
}

function nameIndex(names: StaticArray<string>, s: string): i32 {
    for (let i = 0; i < names.length; i++) if (names[i] == s) return i;
    return -1;
}

function isDigest(s: string): bool {
    if (s.length != 16) return false;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 102))) return false;
    }
    return true;
}

function u32At(b: Uint8Array, at: i32): u32 {
    return <u32>b[at] | (<u32>b[at + 1] << 8) | (<u32>b[at + 2] << 16) | (<u32>b[at + 3] << 24);
}

// --- writing -----------------------------------------------------------

// A loaded bake.
export function lightmapResource(data: LightmapData): LightmapGIData {
    const r = new LightmapGIData();
    r.data = data;
    return r;
}
