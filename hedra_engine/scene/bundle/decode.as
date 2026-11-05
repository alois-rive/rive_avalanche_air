// The bundle's payloads decoded into the resources the loader holds
// (milestone 39; payload.as and docs/cli/BUILD.md section 17 lay them
// out, encode.as
// writes them). The run time's side: nothing here parses text, replays a
// model or imports a glTF file. A model comes back as its objects and
// materials, each mesh a PrebuiltMesh (the GpuMesh the renderer would have
// built, ../resource/types.as) with no shared-model Scene behind it; a
// texture as its decoded image; a lightmap as its LightmapData.
//
// Every function returns a failed Result with a sentence (no code: the
// provider makes it a bundle-invalid error at the bundle) when the bytes
// are not what the writer writes, never traps.

import { Result, i64FitsI32 } from "../../base/util";
import { Vec2, Vec3, Vec4 } from "../../base/vecmath";
import { isValidUtf8 } from "../../fs/vfs";
import { Shader, shaderMaterialFrom, shaderOfText } from "../resource/shader";
import { Value } from "../value";
import { parseValue } from "../value_text";
import { Image } from "../../render/image";
import { FloatImage, decodeHdr } from "../../render/hdr";
import { GpuMesh, MaterialRange, MeshLod } from "../../render/mesh";
import { TextureFamilies } from "../../render/material";
import { CompressedImage, blockFormatName, formOfBlockFormat } from "../../texture/format";
import { readKtx2 } from "../../texture/ktx2";
import { decodeIndicesPooled, decodeVertices, releaseIndices } from "../../meshproc/vertex_codec";
import { SurfaceVertex } from "../../render/gpu/layouts";
import { LightmapData, LightmapInstance } from "../../render/lightmap/data";
import { BinReader, NONE, StringTable, stringAt } from "../rscnb/bin";
import { readValueTable, valueAt } from "../rscnb/values";
import {
    ArrayMesh, LightmapGIData, MeshSurface, ModelFormat, ModelObject, ModelResource, PrebuiltMesh, Script,
    StandardMaterial3D, Texture2D,
} from "../resource/types";
import { TextureFormat } from "./format";
import {
    LAYER_F32, LAYER_HDR, MESH_COMPRESSED, MESH_MODEL_SPACE, MESH_MORPHS, MESH_PAYLOAD_VERSION, MESH_PAYLOAD_VERSION_SKIN, MESH_SKIN,
    MESH_UV1, MODEL_PAYLOAD_VERSION_RIG, PAYLOAD_VERSION, readModelRig, readMorphBlock, readSkinBlock,
    TEXTURE_FILE_ALIGN, TEXTURE_KIND_COUNT, TEXTURE_KIND_NAMES, TEXTURE_KIND_RGBA8, TEXTURE_KIND_SOURCE,
    TEXTURE_TABLE_ENTRY_BYTES, TextureLookup, readMat4, readMaterial, readStr, readVec3,
    MATERIAL_FORM_INLINE, MATERIAL_FORM_REFRACTION, MATERIAL_FORM_SHADER, SHADER_PARAM_TEXTURE, SHADER_PARAM_VALUE,
} from "./payload";

// The bytes of a Mesh entry by name (the provider's bundle), null when the
// bundle holds none.
export abstract class MeshBytes {
    abstract meshBytes(name: string): Uint8Array?;
}

function version(r: BinReader, what: string): bool {
    const v = r.u32();
    if (r.failed) return false;
    if (v != PAYLOAD_VERSION) {
        r.fail(what + " version " + v.toString() + " is not " + PAYLOAD_VERSION.toString());
        return false;
    }
    return true;
}

// The reader's state as a Result, failing too when bytes are left over
// (the writer writes nothing after a payload's last field).
function finished<T>(r: BinReader, v: T, what: string): Result<T> {
    if (!r.failed && r.pos != r.size) r.fail(what + " has " + r.remaining().toString() + " bytes after its end");
    if (r.failed) return Result.fail<T>(what + ": " + r.why);
    return Result.okv<T>(v);
}

// Milestone 26: which of a texture's stored forms (a TextureFormat.Ktx2
// payload's kinds) a reader decodes. The tools (`render <bundle>`) read
// every kind, so that `--textures` can draw any; the run time
// reads one, chosen once from the device's families (scene_runtime.as):
// the first of bc, etc2 and astc the device takes and the texture has,
// else rgba8, else the source, else the first family it has, which the
// binder then decodes on the CPU. Only the chosen file is inflated and
// parsed.
export class TextureChoice {
    all: bool = true;
    // The kinds in the order tried (payload.as TEXTURE_KIND_*).
    order: Array<u32> = [];
    // What the run time's status says (`textures <name>`): the first
    // family the device takes, "rgba8" when it takes none, "source" with
    // no device (or for the tools).
    name: string = "source";

    // Every kind (the tools).
    static every(): TextureChoice {
        return new TextureChoice();
    }

    // The run time's order on a device that takes `f` (see the header).
    static forFamilies(f: TextureFamilies): TextureChoice {
        const c = new TextureChoice();
        c.all = false;
        if (f.known && f.bc) c.order.push(1);
        if (f.known && f.etc2) c.order.push(2);
        if (f.known && f.astc) c.order.push(3);
        c.name = c.order.length > 0 ? TEXTURE_KIND_NAMES[<i32>c.order[0]] : f.known ? "rgba8" : "source";
        c.order.push(TEXTURE_KIND_RGBA8);
        c.order.push(TEXTURE_KIND_SOURCE);
        for (let k: u32 = 1; k <= 3; k++) if (!c.order.includes(k)) c.order.push(k);
        return c;
    }

    // Of the kinds a texture has (ascending), which to read: their
    // indices into `kinds`.
    pick(kinds: Array<u32>): Array<i32> {
        const out = new Array<i32>();
        if (this.all) {
            for (let i = 0; i < kinds.length; i++) out.push(i);
            return out;
        }
        for (let k = 0; k < this.order.length; k++) {
            const at = kinds.indexOf(this.order[k]);
            if (at >= 0) {
                out.push(at);
                break;
            }
        }
        return out;
    }
}

// A Texture: u32 TextureFormat, then the file's bytes (a PNG, or a Radiance
// HDR image), decoded as the loader decodes the file; or (milestone 26,
// TextureFormat.Ktx2) the table of its forms, of which `choice` says which
// to read (the source into `image`, KTX2 forms into `compressed`, in kind
// order).
export function decodeTexture(bytes: Uint8Array, what: string, choice: TextureChoice = TextureChoice.every()): Result<Texture2D> {
    const r = new BinReader(bytes);
    const format = r.u32();
    if (r.failed) return Result.fail<Texture2D>(what + ": " + r.why);
    const body = bytes.subarray(4);
    const t = new Texture2D();
    if (format == <u32>TextureFormat.Png) {
        const img = Image.decodePng(body);
        if (!img.ok) return Result.fail<Texture2D>(what + " is not a PNG image: " + img.err);
        t.image = img.value;
        t.width = <i32>img.value.width;
        t.height = <i32>img.value.height;
    } else if (format == <u32>TextureFormat.Hdr) {
        const hdr = decodeHdr(body);
        if (!hdr.ok) return Result.fail<Texture2D>(what + " is not a Radiance HDR image: " + hdr.err);
        t.hdr = hdr.value;
        t.width = <i32>hdr.value.width;
        t.height = <i32>hdr.value.height;
    } else if (format == <u32>TextureFormat.Ktx2) {
        return decodeTextureForms(bytes, r, what, choice, t);
    } else {
        return Result.fail<Texture2D>(what + " is in a texture format this version does not read (" + format.toString() + ")");
    }
    return Result.okv<Texture2D>(t);
}

// The rest of a Ktx2 payload (`r` past its format): the table checked
// whole (kinds ascending, each once, files aligned, in order, inside the
// payload and filling it), then the chosen files read.
function decodeTextureForms(bytes: Uint8Array, r: BinReader, what: string, choice: TextureChoice, t: Texture2D): Result<Texture2D> {
    const count = r.u32();
    if (r.failed) return Result.fail<Texture2D>(what + ": " + r.why);
    if (count == 0 || count > TEXTURE_KIND_COUNT) {
        return Result.fail<Texture2D>(what + ": a table of " + count.toString() + " forms (1 to " + TEXTURE_KIND_COUNT.toString()
            + ")");
    }
    const kinds = new Array<u32>();
    const offsets = new Array<i32>();
    const sizes = new Array<i32>();
    let end = 8 + <i32>count * TEXTURE_TABLE_ENTRY_BYTES;
    for (let i: u32 = 0; i < count; i++) {
        const kind = r.u32();
        const offset = r.u32();
        const size = r.u32();
        if (r.failed) return Result.fail<Texture2D>(what + ": " + r.why);
        if (kind >= TEXTURE_KIND_COUNT) return Result.fail<Texture2D>(what + ": a form of kind " + kind.toString() + ", which this version does not know");
        if (i > 0 && kind <= kinds[kinds.length - 1]) return Result.fail<Texture2D>(what + ": its forms are not in kind order, or one is there twice");
        if ((offset & <u32>(TEXTURE_FILE_ALIGN - 1)) != 0 || <i64>offset < <i64>end || size == 0
            || <u64>offset + <u64>size > <u64>bytes.length) {
            return Result.fail<Texture2D>(what + ": its " + TEXTURE_KIND_NAMES[<i32>kind] + " form lies outside the payload");
        }
        kinds.push(kind);
        offsets.push(<i32>offset);
        sizes.push(<i32>size);
        end = <i32>(offset + size);
    }
    if (end != bytes.length) return Result.fail<Texture2D>(what + " has " + (bytes.length - end).toString() + " bytes after its last form");
    const picked = choice.pick(kinds);
    const forms = new Array<CompressedImage>();
    for (let p = 0; p < picked.length; p++) {
        const i = picked[p];
        const kind = kinds[i];
        const file = bytes.subarray(offsets[i], offsets[i] + sizes[i]);
        const label = what + "'s " + TEXTURE_KIND_NAMES[<i32>kind] + " form";
        if (kind == TEXTURE_KIND_SOURCE) {
            const img = Image.decodePng(file);
            if (!img.ok) return Result.fail<Texture2D>(label + " is not a PNG image: " + img.err);
            t.image = img.value;
            continue;
        }
        const k = readKtx2(file, label);
        if (!k.ok) return k.forward<Texture2D>();
        const ci = k.value;
        const family = <u32>formOfBlockFormat(ci.format);
        if (family != (kind == TEXTURE_KIND_RGBA8 ? 0 : kind)) {
            return Result.fail<Texture2D>(label + " holds " + blockFormatName(ci.format) + ", not a " + TEXTURE_KIND_NAMES[<i32>kind]
                + " format");
        }
        forms.push(ci);
    }
    if (forms.length > 0) t.compressed = forms;
    const img = t.image;
    if (img != null) {
        t.width = <i32>img.width;
        t.height = <i32>img.height;
    } else if (forms.length > 0) {
        t.width = <i32>forms[0].width;
        t.height = <i32>forms[0].height;
    }
    return Result.okv<Texture2D>(t);
}

// Milestone 61: a Shader entry (format.as AssetKind.Shader): the shader
// file's text, UTF-8 as the build read it, with no header of its own (the
// run time reads its declarations again, as the loader reads the file:
// ../resource/shader.as shaderOfText, `display` naming it in its
// diagnostics). Text that is not UTF-8 is a damaged entry.
export function decodeShader(bytes: Uint8Array, what: string, display: string): Result<Shader> {
    if (!isValidUtf8(bytes)) return Result.fail<Shader>(what + ": its text is not UTF-8");
    const text = String.UTF8.decode(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    return Result.okv<Shader>(shaderOfText(text, display));
}

// A Script: its class (the code is compiled into the project's module).
export function decodeScript(bytes: Uint8Array, what: string): Result<Script> {
    const r = new BinReader(bytes);
    version(r, what);
    const has = r.u32();
    const name = readStr(r);
    const s = new Script();
    s.scriptClass = has != 0 ? name : null;
    return finished<Script>(r, s, what);
}

function materialAt(r: BinReader, materials: Array<StandardMaterial3D>, i: u32): StandardMaterial3D? {
    if (i == NONE) return null;
    if (i >= <u32>materials.length) {
        r.fail("a material index (" + i.toString() + ") past the model's " + materials.length.toString());
        return null;
    }
    return materials[<i32>i];
}

// A Mesh of a model whose materials are `materials`: the ArrayMesh a model
// object holds, with its PrebuiltMesh and its bounds; its surfaces hold
// their materials and no triangles (what walks a mesh's materials, as
// ../tree/artboards.as does, finds them; the renderer draws the prebuilt).
// Its GpuMesh has no wire lines and no points (encode.as encodeMesh).
// Milestone 26: version 2 adds the levels of detail (GpuMesh.lods, null when
// there are none, as every mesh built in the tools) and compression;
// version 1 (milestone 39's bundles) is still read.
export function decodeMesh(bytes: Uint8Array, what: string, materials: Array<StandardMaterial3D>): Result<ArrayMesh> {
    const r = new BinReader(bytes);
    const v = r.u32();
    if (r.failed) return Result.fail<ArrayMesh>(what + ": " + r.why);
    if (v != PAYLOAD_VERSION && v != MESH_PAYLOAD_VERSION && v != MESH_PAYLOAD_VERSION_SKIN) {
        return Result.fail<ArrayMesh>(what + ": version " + v.toString() + " is not " + PAYLOAD_VERSION.toString() + ", "
            + MESH_PAYLOAD_VERSION.toString() + " or " + MESH_PAYLOAD_VERSION_SKIN.toString());
    }
    // (milestone 48: version 3 is version 2 with a skin or blend shapes)
    const v3 = v == MESH_PAYLOAD_VERSION_SKIN;
    const v2 = v == MESH_PAYLOAD_VERSION || v3;
    const flags = r.u32();
    const known = MESH_MODEL_SPACE | MESH_UV1 | (v2 ? MESH_COMPRESSED : 0) | (v3 ? MESH_SKIN | MESH_MORPHS : 0);
    if ((flags & ~known) != 0) r.fail("flags this version does not know");
    const name = readStr(r);
    const objectName = readStr(r);
    const lo = readVec3(r);
    const hi = readVec3(r);
    const color = materialAt(r, materials, r.u32());
    const slotCount = r.count(4);
    const slots = new Array<StandardMaterial3D?>();
    for (let i = 0; i < slotCount; i++) slots.push(materialAt(r, materials, r.u32()));
    const surfaceCount = r.count(4);
    const surfaces = new Array<MeshSurface>();
    for (let i = 0; i < surfaceCount; i++) {
        const s = new MeshSurface();
        s.material = materialAt(r, materials, r.u32());
        surfaces.push(s);
    }
    const ranges = readRanges(r);
    const lods = new Array<MeshLod>();
    const lodCounts = new Array<i32>();
    if (v2) {
        const n = r.count(12);
        for (let i = 0; i < n && !r.failed; i++) {
            const l = new MeshLod();
            l.error = r.f32();
            lodCounts.push(<i32>r.u32());
            l.ranges = readRanges(r);
            lods.push(l);
        }
    } else {
        // Version 1's table: one level, the whole mesh (read and checked,
        // not drawn).
        const n = r.count(12);
        for (let i = 0; i < n; i++) {
            r.u32();
            r.u32();
            r.f32();
        }
    }
    const nv = <i32>r.u32();
    const ni = <i32>r.u32();
    const nl = v2 ? <i32>r.u32() : 0;
    r.align(16);
    if (r.failed) return Result.fail<ArrayMesh>(what + ": " + r.why);
    // (each count by itself, and the sum in i64: a negative count, or two
    // that wrap round, would otherwise add up to nl while a level's ranges
    // reach past its indices, and the GPU would read past the buffer)
    let sum: i64 = 0;
    let countsFit = nl >= 0;
    for (let i = 0; i < lodCounts.length; i++) {
        const c = lodCounts[i];
        if (c < 0 || c > nl) countsFit = false;
        sum += <i64>c;
    }
    if (nv < 0 || ni < 0 || !countsFit || sum != <i64>nl) {
        return Result.fail<ArrayMesh>(what + ": its levels' index counts do not add up");
    }
    // (the levels' indices follow level 0's in one array: their total in
    // i64 too, which two counts near i32's top would wrap negative)
    const total64: i64 = <i64>ni + <i64>nl;
    if (!i64FitsI32(total64)) return Result.fail<ArrayMesh>(what + ": its index counts add up to more than a mesh holds");
    const total = <i32>total64;
    const uv1 = (flags & MESH_UV1) != 0;
    let verts: Array<SurfaceVertex>;
    let uvs: Array<Vec2>? = null;
    let all: Array<u32>;
    // (milestone 67b: the compressed indices stay in their scratch buffer,
    // ../../base/scratch.as, and each level's array is copied out of it:
    // the whole list is never made, as it is from uncompressed bytes)
    let pooled: Uint32Array? = null;
    if ((flags & MESH_COMPRESSED) != 0) {
        const qlo = readVec3(r);
        const qhi = readVec3(r);
        const vn = r.count(1);
        const vb = r.view(vn);
        r.align(4);
        const inn = r.count(1);
        const ib = r.view(inn);
        if (r.failed) return Result.fail<ArrayMesh>(what + ": " + r.why);
        if (!v3 && r.pos != r.size) return Result.fail<ArrayMesh>(what + " has " + r.remaining().toString() + " bytes after its end");
        const dv = decodeVertices(vb, nv, uv1, qlo, qhi, what);
        if (!dv.ok) return dv.forward<ArrayMesh>();
        verts = dv.value.verts;
        uvs = dv.value.uv1;
        if (verts.length != nv || (uv1 && (uvs == null || uvs.length != nv))) {
            return Result.fail<ArrayMesh>(what + ": its vertices decode to another count");
        }
        const di = decodeIndicesPooled(ib, total, nv, what);
        if (!di.ok) return di.forward<ArrayMesh>();
        const got = di.value;
        if (got.length != total) {
            releaseIndices(got);
            return Result.fail<ArrayMesh>(what + ": its indices decode to another count");
        }
        // (every index is checked against nv by the decoder)
        pooled = got;
        all = [];
    } else {
        const need = <i64>nv * 56 + total64 * 4 + (uv1 ? <i64>nv * 8 : 0);
        // (version 3's skin and blend shapes come after: read below)
        if (v3 ? need > <i64>r.remaining() : need != <i64>r.remaining()) {
            return Result.fail<ArrayMesh>(what + ": its arrays do not fill its " + r.remaining().toString() + " bytes");
        }
        const blk = r.view(<i32>need);
        const dv = new DataView(blk.buffer, blk.byteOffset, blk.byteLength);
        let at = 0;
        verts = new Array<SurfaceVertex>(nv);
        for (let i = 0; i < nv; i++) {
            const pos = Vec3(dv.getFloat32(at, true), dv.getFloat32(at + 4, true), dv.getFloat32(at + 8, true));
            const normal = Vec3(dv.getFloat32(at + 12, true), dv.getFloat32(at + 16, true), dv.getFloat32(at + 20, true));
            const uv = Vec2(dv.getFloat32(at + 24, true), dv.getFloat32(at + 28, true));
            const vflags = dv.getUint32(at + 32, true);
            const tangent = Vec4(dv.getFloat32(at + 36, true), dv.getFloat32(at + 40, true), dv.getFloat32(at + 44, true),
                dv.getFloat32(at + 48, true));
            const weight = dv.getFloat32(at + 52, true);
            unchecked(verts[i] = SurfaceVertex(pos, normal, uv, vflags, tangent, weight));
            at += 56;
        }
        all = new Array<u32>(total);
        for (let i = 0; i < total; i++) {
            const k = dv.getUint32(at, true);
            if (k >= <u32>nv) return Result.fail<ArrayMesh>(what + ": index " + i.toString() + " names vertex " + k.toString() + " of " + nv.toString());
            unchecked(all[i] = k);
            at += 4;
        }
        if (uv1) {
            const u = new Array<Vec2>(nv);
            for (let i = 0; i < nv; i++) {
                unchecked(u[i] = Vec2(dv.getFloat32(at, true), dv.getFloat32(at + 4, true)));
                at += 8;
            }
            uvs = u;
        }
    }
    const p = pooled;
    if (p != null) {
        const cut = cutLevels(p, ni, lods, lodCounts);
        releaseIndices(p);
        all = cut;
    }
    const indices = p != null ? all : (nl == 0 ? all : all.slice(0, ni));
    if (!rangesFit(ranges, ni)) return Result.fail<ArrayMesh>(what + ": a range runs past its indices");
    let from = ni;
    for (let i = 0; i < lods.length; i++) {
        const l = lods[i];
        const n = lodCounts[i];
        if (p == null) l.indices = all.slice(from, from + n);
        from += n;
        if (!rangesFit(l.ranges, n)) return Result.fail<ArrayMesh>(what + ": a range of level " + (i + 1).toString() + " runs past its indices");
    }
    const g = GpuMesh.fromArrays(verts, indices, ranges);
    if (uvs != null) g.uv1 = uvs;
    if (lods.length > 0) g.lods = lods;
    // Milestone 48: the skin and the blend shapes, per vertex.
    if ((flags & MESH_SKIN) != 0) {
        const sb = readSkinBlock(r, nv);
        if (sb == null) return Result.fail<ArrayMesh>(what + ": " + r.why);
        g.skinJoints = sb.joints;
        g.skinWeights = sb.weights;
    }
    if ((flags & MESH_MORPHS) != 0) {
        const mb = readMorphBlock(r, nv);
        if (mb == null) return Result.fail<ArrayMesh>(what + ": " + r.why);
        g.morphs = mb;
    }

    const pre = new PrebuiltMesh(g);
    pre.modelSpace = (flags & MESH_MODEL_SPACE) != 0;
    pre.slotMaterials = slots;
    pre.colorMaterial = color;
    pre.objectName = objectName;
    const m = new ArrayMesh();
    m.name = name;
    m.prebuilt = pre;
    m.surfaces = surfaces;
    m.aabbMin = lo;
    m.aabbMax = hi;
    return finished<ArrayMesh>(r, m, what);
}

// Milestone 67b: level 0's `ni` indices of `idx` as a list (returned), and
// each level's after them into its `indices` (`counts` each), as
// decodeMesh slices them from the whole list.
function cutLevels(idx: Uint32Array, ni: i32, lods: Array<MeshLod>, counts: Array<i32>): Array<u32> {
    const first = new Array<u32>(ni);
    for (let i = 0; i < ni; i++) unchecked(first[i] = unchecked(idx[i]));
    let from = ni;
    for (let k = 0; k < lods.length; k++) {
        const n = counts[k];
        const level = new Array<u32>(n);
        for (let i = 0; i < n; i++) unchecked(level[i] = unchecked(idx[from + i]));
        lods[k].indices = level;
        from += n;
    }
    return first;
}

// A list of material runs: u32 count, then (slot, first, count) each.
function readRanges(r: BinReader): Array<MaterialRange> {
    const n = r.count(12);
    const out = new Array<MaterialRange>();
    for (let i = 0; i < n; i++) {
        const slot = r.u32();
        const first = r.u32();
        const count = r.u32();
        if (slot > 0xFFFF) r.fail("a range's slot (" + slot.toString() + ") is past 65535");
        out.push(MaterialRange(<u16>slot, first, count));
    }
    return out;
}

function rangesFit(ranges: Array<MaterialRange>, n: i32): bool {
    for (let i = 0; i < ranges.length; i++) {
        const g = ranges[i];
        if (<u64>g.first + <u64>g.count > <u64>n) return false;
    }
    return true;
}

// A Model: its materials, then its objects, each mesh object's mesh from
// the Mesh entry it names (`meshes`), textures through `textures`.
export function decodeModel(bytes: Uint8Array, what: string, textures: TextureLookup, meshes: MeshBytes): Result<ModelResource> {
    const r = new BinReader(bytes);
    // (milestone 48: version 2 adds the objects' rigs and the clips)
    const mv = r.u32();
    if (!r.failed && mv != PAYLOAD_VERSION && mv != MODEL_PAYLOAD_VERSION_RIG) {
        r.fail(what + " version " + mv.toString() + " is not " + PAYLOAD_VERSION.toString() + " or " + MODEL_PAYLOAD_VERSION_RIG.toString());
    }
    const strings = StringTable.read(r);
    if (strings == null) return Result.fail<ModelResource>(what + ": " + r.why);
    const values = readValueTable(r, strings);
    if (values == null) return Result.fail<ModelResource>(what + ": " + r.why);
    const m = new ModelResource();
    const format = r.u32();
    if (format > 1) r.fail("a model format this version does not know (" + format.toString() + ")");
    m.format = format == 1 ? ModelFormat.Gltf : ModelFormat.Modeler;
    const nm = r.count(4);
    for (let i = 0; i < nm && !r.failed; i++) {
        const form = r.u32();
        if (form != MATERIAL_FORM_INLINE && form != MATERIAL_FORM_SHADER && form != MATERIAL_FORM_REFRACTION) {
            r.fail("a material form this version does not know (" + form.toString() + ")");
            break;
        }
        const mat = readMaterial(r, textures);
        // (milestone 62: form 2's refraction_scale after the record)
        if (form == MATERIAL_FORM_REFRACTION) mat.refractionScale = r.f32();
        m.materials.push(form == MATERIAL_FORM_SHADER ? readShaderMaterial(r, mat, textures) : mat);
    }
    const no = r.count(16);
    for (let i = 0; i < no && !r.failed; i++) {
        const o = new ModelObject();
        o.name = stringAt(r, strings, r.u32());
        o.className = stringAt(r, strings, r.u32());
        o.parent = r.i32();
        if (o.parent < -1 || o.parent >= i) r.fail("object " + i.toString() + "'s parent (" + o.parent.toString() + ") is not before it");
        o.local = readMat4(r);
        const vis = r.u32();
        if (vis > 1) r.fail("a visibility that is neither 0 nor 1");
        o.visible = vis == 1;
        const meshName = r.u32();
        const np = r.count(8);
        for (let k = 0; k < np; k++) {
            o.propNames.push(stringAt(r, strings, r.u32()));
            o.propValues.push(valueAt(r, values, r.u32()));
        }
        if (r.failed) break;
        if (meshName != NONE) {
            const mn = stringAt(r, strings, meshName);
            if (r.failed) break;
            const mb = meshes.meshBytes(mn);
            if (mb == null) return Result.fail<ModelResource>(what + ": its object " + o.name + " names the mesh " + mn + ", which the bundle does not hold");
            const mesh = decodeMesh(mb, "mesh " + mn, m.materials);
            if (!mesh.ok) return mesh.forward<ModelResource>();
            o.mesh = mesh.value;
        }
        m.objects.push(o);
    }
    if (!r.failed && mv == MODEL_PAYLOAD_VERSION_RIG && !readModelRig(r, m)) return Result.fail<ModelResource>(what + ": " + r.why);
    return finished<ModelResource>(r, m, what);
}

// Milestone 61: a form 1 material's shader part (payload.as), after its
// fallback `fallback`: the ShaderMaterial, its parameters declared, then
// its shader set (null when the bundle holds none: the fallback is drawn).
function readShaderMaterial(r: BinReader, fallback: StandardMaterial3D, textures: TextureLookup): StandardMaterial3D {
    const sm = shaderMaterialFrom(fallback);
    const shader = readStr(r);
    const n = r.count(9);
    for (let i = 0; i < n && !r.failed; i++) {
        const name = readStr(r);
        const kind = r.u8();
        const text = readStr(r);
        if (r.failed) break;
        if (kind == SHADER_PARAM_TEXTURE) {
            sm.declare(name, Value.extResource(text), textures.textureOf(text));
        } else if (kind == SHADER_PARAM_VALUE) {
            const v = parseValue(text);
            if (!v.ok) r.fail("shader parameter " + name + "'s value " + text + " does not read: " + v.err);
            else sm.declare(name, v.value, null);
        } else {
            r.fail("a shader parameter kind this version does not know (" + kind.toString() + ")");
        }
    }
    sm.setShader(shader.length > 0 ? textures.shaderOf(shader) : null);
    return sm;
}

// A Lightmap: the LightmapData an .lmbake and its files read into (or none,
// for a bake the build could not read: a LightmapGIData without data,
// drawn in real time as the loader's is).
export function decodeLightmap(bytes: Uint8Array, what: string): Result<LightmapGIData> {
    const r = new BinReader(bytes);
    version(r, what);
    const res = new LightmapGIData();
    const has = r.u32();
    if (has == 0) return finished<LightmapGIData>(r, res, what);
    const d = new LightmapData();
    const s = d.settings;
    s.quality = r.i32();
    s.bounces = r.i32();
    s.bounceIndirectEnergy = r.f32();
    s.directional = r.u32() != 0;
    s.useTextureForBounces = r.u32() != 0;
    s.interior = r.u32() != 0;
    s.useDenoiser = r.u32() != 0;
    s.denoiserStrength = r.f32();
    s.denoiserRange = r.i32();
    s.bias = r.f32();
    s.texelSize = r.f32();
    s.texelScale = r.f32();
    s.maxTextureSize = r.i32();
    s.environmentMode = r.i32();
    s.environmentCustomColor = readVec3(r);
    s.environmentCustomEnergy = r.f32();
    s.generateProbesSubdiv = r.i32();
    d.images.width = r.i32();
    d.images.height = r.i32();
    const layers = r.count(12);
    for (let i = 0; i < layers && !r.failed; i++) {
        const form = r.u32();
        const w = r.u32();
        const h = r.u32();
        const n = r.count(1);
        const body = r.view(n);
        r.align(4);
        if (r.failed) break;
        if (form == LAYER_HDR) {
            const img = decodeHdr(body);
            if (!img.ok) return Result.fail<LightmapGIData>(what + ": layer " + i.toString() + " is not a Radiance HDR image: " + img.err);
            if (img.value.width != w || img.value.height != h) r.fail("layer " + i.toString() + " is not the size it says");
            d.images.layers.push(img.value);
        } else if (form == LAYER_F32) {
            if (<u64>n != <u64>w * <u64>h * 12) {
                r.fail("layer " + i.toString() + "'s texels are not " + w.toString() + " x " + h.toString());
                break;
            }
            const texels = new Float32Array(<i32>(w * h * 3));
            const dv = new DataView(body.buffer, body.byteOffset, body.byteLength);
            for (let k = 0; k < texels.length; k++) texels[k] = dv.getFloat32(k << 2, true);
            d.images.layers.push(new FloatImage(w, h, texels));
        } else {
            r.fail("a layer form this version does not know (" + form.toString() + ")");
        }
    }
    const instances = r.count(4);
    for (let i = 0; i < instances && !r.failed; i++) {
        const inst = new LightmapInstance();
        inst.node = readStr(r);
        inst.part = r.i32();
        inst.layer = r.i32();
        inst.sourceVertices = r.i32();
        inst.sourceTriangles = r.i32();
        inst.digest = readStr(r);
        inst.transform = readMat4(r);
        inst.xref = readU32s(r);
        inst.uv = readF32s(r);
        inst.indices = readU32s(r);
        d.instances.push(inst);
    }
    const probes = r.count(12);
    for (let i = 0; i < probes; i++) d.probes.positions.push(readVec3(r));
    d.probes.sh = readF32s(r);
    res.data = d;
    return finished<LightmapGIData>(r, res, what);
}

function readU32s(r: BinReader): Uint32Array {
    const n = r.count(4);
    const out = new Uint32Array(n);
    for (let i = 0; i < n; i++) out[i] = r.u32();
    return out;
}

function readF32s(r: BinReader): Float32Array {
    const n = r.count(4);
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = r.f32();
    return out;
}

// Milestone 26: a Lods entry's levels (encode.as encodeMeshLods), for a
// mesh of `vertexCount` vertices: fails, never traps, on bytes it did not
// write (a short read, a count past the bytes, a range past its level's
// indices, an index past the vertices, bytes left over), another version,
// or levels of another vertex count.
export function decodeMeshLods(bytes: Uint8Array, vertexCount: i32, what: string): Result<Array<MeshLod>> {
    const r = new BinReader(bytes, 0, bytes.length);
    const version = r.u32();
    if (r.failed) return Result.fail<Array<MeshLod>>(what + ": " + r.why);
    if (version != 1) return Result.fail<Array<MeshLod>>(what + ": version " + version.toString() + " is not 1");
    const n = r.u32();
    const levels = r.count(16);
    if (r.failed) return Result.fail<Array<MeshLod>>(what + ": " + r.why);
    if (n != <u32>vertexCount) {
        return Result.fail<Array<MeshLod>>(what + ": levels of " + n.toString() + " vertices for a mesh of " + vertexCount.toString());
    }
    const out = new Array<MeshLod>();
    const counts = new Array<i32>();
    let total: i64 = 0;
    for (let i = 0; i < levels; i++) {
        const l = new MeshLod();
        l.error = r.f32();
        const nr = r.count(12);
        for (let k = 0; k < nr; k++) {
            const slot = r.u32();
            const first = r.u32();
            const count = r.u32();
            if (slot > 65535) return Result.fail<Array<MeshLod>>(what + ": a range's slot " + slot.toString());
            l.ranges.push(MaterialRange(<u16>slot, first, count));
        }
        const c = r.u32();
        if (r.failed) return Result.fail<Array<MeshLod>>(what + ": " + r.why);
        if (c % 3 != 0) return Result.fail<Array<MeshLod>>(what + ": level " + (i + 1).toString() + "'s indices are not whole triangles");
        total += <i64>c;
        if (total > <i64>bytes.length * 64) return Result.fail<Array<MeshLod>>(what + ": more indices than the bytes hold");
        counts.push(<i32>c);
        out.push(l);
    }
    const len = r.count(1);
    const packed = r.view(len);
    if (r.failed) return Result.fail<Array<MeshLod>>(what + ": " + r.why);
    if (r.remaining() != 0) return Result.fail<Array<MeshLod>>(what + " has " + r.remaining().toString() + " bytes after its end");
    // (milestone 67b: the indices read out of their scratch buffer, level
    // by level, as decodeMesh's)
    const all = decodeIndicesPooled(packed, <i32>total, vertexCount, what);
    if (!all.ok) return all.forward<Array<MeshLod>>();
    const idx = all.value;
    let at = 0;
    for (let i = 0; i < out.length; i++) {
        const count = counts[i];
        const level = new Array<u32>(count);
        for (let k = 0; k < count; k++) unchecked(level[k] = unchecked(idx[at + k]));
        out[i].indices = level;
        at += count;
    }
    releaseIndices(idx);
    let from = 0;
    for (let i = 0; i < out.length; i++) {
        const l = out[i];
        from += counts[i];
        if (!rangesFit(l.ranges, counts[i])) return Result.fail<Array<MeshLod>>(what + ": a range of level " + (i + 1).toString() + " runs past its indices");
        for (let k = 0; k < l.indices.length; k++) {
            if (l.indices[k] >= <u32>vertexCount) return Result.fail<Array<MeshLod>>(what + ": an index past the vertices");
        }
    }
    return Result.okv<Array<MeshLod>>(out);
}
