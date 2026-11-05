// Baked lighting (milestone 19, Godot's LightmapGI): the data every part of
// it agrees on. The baker (baker.as) turns a BakeInput into a LightmapData;
// Hedra writes that to disk as an .lmbake resource and reads it back
// (engine/src/scene/lightmap/lmbake.as, docs/formats/RSCN.md
// "LightmapGIData"); its adapter puts it on a frame (RenderFrame.lightmap,
// DrawItem.lightmapLayer and probeSh, GpuMesh.lightmapUv:
// engine/src/scene/render/lightmap.as), and the renderer draws it
// (surface.wgsl's lightmap entry points, gpu/lightmap.as).
//
// Nothing here knows a scene: an item is a mesh, a world matrix and its
// materials, as in a RenderFrame. Everything in memory is in the frame's
// world space (the renderer's Z up, as RenderFrame's); the .lmbake file is
// in scene space (Y up, Godot's), and its reader and writer convert.
//
// What a lightmap texel holds: the diffuse light arriving at the surface,
// scaled so that the shader multiplies it by the surface's diffuse colour
// (albedo times 1 - metallic) and adds it, as lit() adds the flat ambient
// light (`B` below, sh.as says the same of a probe). A white surface under
// an open sky of radiance L everywhere holds L; one square to a
// directional light of colour c and energy e holds c * e (Godot's
// photometry: frame.as LightDesc).
//
// These types are the baker's interface: what Hedra, the baker and the
// renderer exchange (docs/milestones/M19.md).

import { MAT4_IDENTITY, Mat4, Vec3 } from "../../base/vecmath";
import { FNV64_OFFSET, FNV64_PRIME, Result } from "../../base/util";
import { hexU64 } from "../../base/fmt";
import { FloatImage } from "../hdr";
import { GpuMesh } from "../mesh";
import { EnvironmentDesc, LightDesc, SkyDesc } from "../frame";
import { Image } from "../image";
import { MaterialDesc, TextureFiles, TextureStamp, decode } from "../material";
import { CPU_COPY_RELEASE, cpuCopyPolicy, noteCpuMiss } from "../../scene/resource/cpu_copy";

// LightmapGI.quality, Godot's numbers.
export const LIGHTMAP_QUALITY_LOW: i32 = 0;
export const LIGHTMAP_QUALITY_MEDIUM: i32 = 1;
export const LIGHTMAP_QUALITY_HIGH: i32 = 2;
export const LIGHTMAP_QUALITY_ULTRA: i32 = 3;
export const LIGHTMAP_QUALITY_NAMES: StaticArray<string> = ["low", "medium", "high", "ultra"];

// LightmapGI.environment_mode, Godot's numbers: no light from the
// environment; the scene's (its WorldEnvironment's sky or ambient colour,
// as lit() lights an unbaked surface); a sky of its own
// (BakeSettings.customSky, times environment_custom_energy); a colour.
export const LIGHTMAP_ENV_DISABLED: i32 = 0;
export const LIGHTMAP_ENV_SCENE: i32 = 1;
export const LIGHTMAP_ENV_CUSTOM_SKY: i32 = 2;
export const LIGHTMAP_ENV_CUSTOM_COLOR: i32 = 3;

// LightmapGI.generate_probes_subdiv, Godot's enum: the automatic probe
// grid's cells along the longest side of the static geometry's box (0:
// no automatic probes, only LightmapProbe nodes).
export const LIGHTMAP_PROBE_SUBDIV: StaticArray<i32> = [0, 4, 8, 16, 32];

// The largest layer the baker makes, whatever max_texture_size asks
// (Godot's default is 16384: a 16384-texel half-float layer is 2 GiB).
export const LIGHTMAP_MAX_SIZE: i32 = 4096;

// The empty texels kept between two charts of a layer, and between a
// chart and the layer's edge, so that bilinear sampling never reads a
// neighbour's light (the dilation fills them from their chart).
export const LIGHTMAP_PADDING: i32 = 2;

// GeometryInstance3D.gi_mode, Godot's numbers.
export const GI_MODE_DISABLED: i32 = 0;
export const GI_MODE_STATIC: i32 = 1;
export const GI_MODE_DYNAMIC: i32 = 2;

// The baked light of a frame's lightmapped items: one or more layers of
// the same size, linear RGB (FloatImage: three f32 a texel, rows top
// first). A layer's texel (x, y) is centred on (x + 0.5) / width, (y +
// 0.5) / height of GpuMesh.lightmapUv: v grows down the rows, so the
// shader samples the uploaded rows at the coordinate as it is.
export class LightmapImages {
    width: i32 = 0;
    height: i32 = 0;
    layers: Array<FloatImage> = [];
}

// One lightmapped item of a bake: which item (its node and its index among
// the node's items), where its texels are, and its mesh as the lightmap
// draws it. A chart seam needs a vertex on each side of it, so the
// lightmapped mesh has vertices of its own: vertex k is the source mesh's
// vertex xref[k] (GpuMesh.verts, every attribute copied) at uv[2k], uv[2k
// + 1] of layer `layer`, and its triangles are `indices` (three a
// triangle, in the source mesh's triangle order, so that its material
// ranges' first and count are the source's).
export class LightmapInstance {
    // The node's path from the root of the scene that declares the
    // LightmapGI (SceneNode.pathFrom: "." is that root), and the item's
    // index among the items that node draws, in the order the adapter adds
    // them (a ModelInstance3D's parts; 0 for any other node). Relative to
    // that root, so that the bake still finds its items when the scene is
    // instanced in another.
    node: string = "";
    part: i32 = 0;
    layer: i32 = 0;
    // What the item drew when it was baked: its source mesh's vertex and
    // triangle counts, `lightmapDigest` of the mesh, and `transform`, its
    // world matrix in the frame of that same root (BakeInput.frame). A
    // drawn item whose own differ (the transform by more than
    // `lightmapTransformMatches` allows) was moved or changed after the
    // bake: it is drawn without its lightmap, with a warning.
    sourceVertices: i32 = 0;
    sourceTriangles: i32 = 0;
    digest: string = "";
    transform: Mat4 = MAT4_IDENTITY;
    xref: Uint32Array = new Uint32Array(0);
    uv: Float32Array = new Float32Array(0);
    indices: Uint32Array = new Uint32Array(0);
    // Milestone 67b: in a run time that releases CPU copies
    // (scene/resource/cpu_copy.as), the lightmapped mesh made from
    // `sharedFrom` (scene/render/lightmap.as lightmappedMeshOf), shared by
    // every render cache that draws the item: the source's arrays are let
    // go of after the plan that made it, so a second Scene3D, or the scene
    // shown again, could not make it again. Null elsewhere (the tools make
    // one per cache, as before).
    sharedMesh: GpuMesh? = null;
    sharedFrom: GpuMesh? = null;
}

// The probes a bake places for the items that are not lightmapped (Godot's
// LightmapProbe and its automatic grid): positions in the frame of the
// root of the scene that declares the LightmapGI (BakeInput.frame: the
// frame's world space for a scene drawn alone), and SH_L1_FLOATS numbers
// a probe (sh.as, directions in that frame too) of the light arriving
// there from the baked surfaces and the environment (not the lights' direct
// light, which such an item takes in real time).
export class LightmapProbeSet {
    positions: Array<Vec3> = [];
    sh: Float32Array = new Float32Array(0);

    get count(): i32 {
        return this.positions.length;
    }
}

// What LightmapGI asks of a bake: its properties, Godot's names and
// defaults (engine/src/scene/classdb.as documents each), linear colours.
export class BakeSettings {
    quality: i32 = LIGHTMAP_QUALITY_MEDIUM;
    bounces: i32 = 3;
    bounceIndirectEnergy: f32 = 1;
    // Directional lightmaps (Godot's `directional`) are not made: the
    // setting is kept and said.
    directional: bool = false;
    useTextureForBounces: bool = true;
    interior: bool = false;
    useDenoiser: bool = true;
    denoiserStrength: f32 = 0.1;
    denoiserRange: i32 = 10;
    // Moves a texel's rays off its surface, in the frame's units.
    bias: f32 = 0.0005;
    // The size of a lightmap texel on a surface (lightmap_texel_size,
    // metres), divided by texel_scale and by each item's
    // gi_lightmap_texel_scale.
    texelSize: f32 = 0.2;
    texelScale: f32 = 1;
    maxTextureSize: i32 = 16384;
    environmentMode: i32 = LIGHTMAP_ENV_SCENE;
    environmentCustomColor: Vec3 = Vec3(1, 1, 1);
    environmentCustomEnergy: f32 = 1;
    // environment_custom_sky's sky (environment_mode custom_sky), as the
    // renderer describes one: null when the LightmapGI names none (the
    // environment then adds no light, with a warning). Not written to the
    // .lmbake.
    customSky: SkyDesc? = null;
    // An index of LIGHTMAP_PROBE_SUBDIV.
    generateProbesSubdiv: i32 = 2;
}

// A whole bake: its images, its instances (in the order of the items it
// was given), its probes, and the settings it was made with.
export class LightmapData {
    images: LightmapImages = new LightmapImages();
    instances: Array<LightmapInstance> = [];
    probes: LightmapProbeSet = new LightmapProbeSet();
    settings: BakeSettings = new BakeSettings();
}

// One static item of a bake (GeometryInstance3D.gi_mode static): it casts
// baked light and shadows and receives a lightmap. `mesh` is the item's
// GpuMesh as the frame draws it (its CPU arrays are read; it is never
// changed), `world` its DrawItem.world, `materials` its DrawItem.materials
// (indices into BakeInput.materials, -1 the renderer's default material).
export class BakeItem {
    node: string = "";
    part: i32 = 0;
    mesh: GpuMesh;
    world: Mat4;
    materials: Array<i64> = [];
    // gi_lightmap_texel_scale: more texels (above 1) or fewer.
    texelScale: f32 = 1;
    // Whether it blocks baked light (cast_shadow not off).
    castsShadow: bool = true;

    constructor(mesh: GpuMesh, world: Mat4) {
        this.mesh = mesh;
        this.world = world;
    }
}

// Everything a bake reads. Hedra makes it from a scene
// (compiler/src/bake/bake.as prepareBake).
export class BakeInput {
    items: Array<BakeItem> = [];
    // The frame's materials, which BakeItem.materials index.
    materials: Array<MaterialDesc> = [];
    // Where the materials' textures are read (null: no texture is read,
    // bounces take the materials' colours), and where relative texture
    // paths resolve (RenderFrame.baseDir).
    textures: TextureFiles? = null;
    baseDir: string = "";
    // The lights the bake sees: every light of the frame whose bakeMode is
    // not LIGHT_BAKE_DISABLED (a static one's direct light is baked; a
    // dynamic one's only bounces).
    lights: Array<LightDesc> = [];
    // The frame's environment (LIGHTMAP_ENV_SCENE reads it).
    environment: EnvironmentDesc = new EnvironmentDesc();
    // Where the scene's LightmapProbe nodes are (frame world space): a
    // probe is baked at each, besides the automatic grid's.
    probePoints: Array<Vec3> = [];
    settings: BakeSettings = new BakeSettings();
    // The most bytes the bake may allocate (0: no limit); a bake that would
    // need more fails with `bake-too-large` before it allocates.
    memoryLimit: i64 = 0;
    // The world matrix of the root of the scene that declares the
    // LightmapGI (frame world space). The bake is traced in the frame's
    // world; its instances' transforms and its probes (positions and
    // directions) are kept relative to this, so that the bake holds
    // wherever that scene is instanced. Identity for a scene baked as the
    // root of its own tree, unless its root node is moved.
    frame: Mat4 = MAT4_IDENTITY;
    // The buffers to bake into (BakeBuffers): reused, and grown only when
    // a bake needs more, by a program that bakes many times in one run
    // (the scene editor); null for a bake of its own.
    buffers: BakeBuffers? = null;
}

// The BakeBuffers slots, by kind: the G-buffer's five Float32Arrays and
// its item (raster.as), the scene's four Float32Arrays and four
// Int32Arrays (scene.as), then the baker's own (baker.as), a layer's image
// from BAKE_SLOT_IMAGES on.
export const BAKE_SLOT_GBUFFER_F32: i32 = 0;
export const BAKE_SLOT_GBUFFER_I32: i32 = 0;
export const BAKE_SLOT_SCENE_F32: i32 = 5;
export const BAKE_SLOT_SCENE_I32: i32 = 1;
export const BAKE_SLOT_BAKER_F32: i32 = 9;
export const BAKE_SLOT_BAKER_I32: i32 = 5;
export const BAKE_SLOT_BAKER_U8: i32 = 0;
export const BAKE_SLOT_IMAGES: i32 = 32;

// Typed arrays a baker borrows rather than allocates: one per use (the
// G-buffer's fields, the light buffers, the hit cache...), each grown to
// the largest size a bake has asked of it and handed out as a view of that
// length, cleared. The stub runtime never frees, so a program that bakes
// again and again (the scene editor) keeps one set: its second bake of
// the same scene allocates only what is proportional to the scene's
// triangles (the charts, the BVH), not its texels or rays. It also keeps
// the base colour textures the bakes read (`texture`), so that a texture
// is decoded once for as long as its file does not change, not once a
// bake.
export class BakeBuffers {
    private f32s: Array<Float32Array> = [];
    private i32s: Array<Int32Array> = [];
    private u8s: Array<Uint8Array> = [];
    // Decoded textures by resolved path.
    private textures: Map<string, BakeTexture> = new Map<string, BakeTexture>();
    // The bytes held in all.
    bytes: i64 = 0;

    // The texture at `path` (resolved), decoded through `files`: the one
    // kept from an earlier bake while the file's stamp (its size, and its
    // modification time when `files` has one) is the same, else decoded
    // and kept. A failure is not kept: the next bake tries again. An image
    // `files` already holds in memory (a model's embedded one) is its own,
    // not kept here.
    texture(path: string, files: TextureFiles): Result<Image> {
        const held = files.decoded(path);
        // (milestone 67b: a bake reads pixels a run time may have let go of;
        // nothing bakes in a run time, so this is a miss if it ever does)
        if (held != null && held.released) noteCpuMiss("bake: a released texture");
        if (held != null) return Result.okv<Image>(held);
        const stamp = files.stamp(path);
        if (this.textures.has(path)) {
            const kept = this.textures.get(path);
            if (TextureStamp.same(kept.stamp, stamp)) return Result.okv<Image>(kept.image);
        }
        const img = decode(path, files);
        if (!img.ok) return img;
        if (this.textures.has(path)) this.bytes -= imageBytes(this.textures.get(path).image);
        this.textures.set(path, new BakeTexture(stamp, img.value));
        this.bytes += imageBytes(img.value);
        return img;
    }

    // Slot `slot`'s Float32Array of `n` numbers, zeroed.
    f32(slot: i32, n: i32): Float32Array {
        while (this.f32s.length <= slot) this.f32s.push(new Float32Array(0));
        let a = this.f32s[slot];
        if (a.length < n) {
            this.bytes += <i64>(n - a.length) * 4;
            a = new Float32Array(n);
            this.f32s[slot] = a;
        }
        const v = a.subarray(0, n);
        v.fill(0);
        return v;
    }

    // Slot `slot`'s Int32Array of `n` numbers, each `fill`.
    i32(slot: i32, n: i32, fill: i32 = 0): Int32Array {
        while (this.i32s.length <= slot) this.i32s.push(new Int32Array(0));
        let a = this.i32s[slot];
        if (a.length < n) {
            this.bytes += <i64>(n - a.length) * 4;
            a = new Int32Array(n);
            this.i32s[slot] = a;
        }
        const v = a.subarray(0, n);
        v.fill(fill);
        return v;
    }

    // Slot `slot`'s Uint8Array of `n` bytes, zeroed.
    u8(slot: i32, n: i32): Uint8Array {
        while (this.u8s.length <= slot) this.u8s.push(new Uint8Array(0));
        let a = this.u8s[slot];
        if (a.length < n) {
            this.bytes += <i64>(n - a.length);
            a = new Uint8Array(n);
            this.u8s[slot] = a;
        }
        const v = a.subarray(0, n);
        v.fill(0);
        return v;
    }
}

// A texture BakeBuffers keeps, and the stamp of the file it was decoded
// from.
class BakeTexture {
    stamp: TextureStamp?;
    image: Image;

    constructor(stamp: TextureStamp?, image: Image) {
        this.stamp = stamp;
        this.image = image;
    }
}

// The bytes a decoded texture holds (RGBA8).
export function imageBytes(img: Image): i64 {
    return <i64>img.width * <i64>img.height * 4;
}

// What a bake counted, and how long each phase took (BAKE_PHASES order,
// seconds of the program's clock: not part of any file, so not
// deterministic).
export class BakeStats {
    instances: i32 = 0;
    charts: i32 = 0;
    width: i32 = 0;
    height: i32 = 0;
    layers: i32 = 0;
    // Texels covered by a chart.
    texels: i64 = 0;
    probes: i32 = 0;
    rays: i64 = 0;
    // The bytes the baker allocated for its buffers.
    bytes: i64 = 0;
    phaseSeconds: Array<f64> = [];
}

// Why a bake failed: a code (docs/formats/RSCN.md "Errors and warnings":
// bake-nothing-static, bake-too-large, bake-failed), a sentence and a hint.
export class BakeError {
    code: string;
    message: string;
    hint: string;

    constructor(code: string, message: string, hint: string) {
        this.code = code;
        this.message = message;
        this.hint = hint;
    }
}

export class BakeResult {
    data: LightmapData = new LightmapData();
    stats: BakeStats = new BakeStats();
    // What was baked differently than asked (a directional lightmap, a
    // custom sky), one sentence each.
    warnings: Array<string> = [];
}

// The key of an instance: its node path and part ("Walls/Back#0").
export function instanceKey(node: string, part: i32): string {
    return node + "#" + part.toString();
}

// What a lightmap was baked on, as 16 hex digits: FNV-1a 64 over the
// mesh's vertex and triangle counts, its indices, and the bits of each
// vertex's position in the mesh's own space. The baker records it and the
// adapter compares it, so an item remodelled since its bake is noticed
// (one moved or scaled is noticed by its transform:
// `lightmapTransformMatches`). Deterministic: integer arithmetic only.
//
// Milestone 67b: in a run time that releases CPU copies, the answer is
// kept on the mesh (GpuMesh.lightmapDigestKept, for its vertsRevision; not
// for a deforming mesh), so that a mesh whose arrays were let go of after
// the plan that matched it first still matches; a released mesh never
// matched before answers "" (matching no bake) and counts a miss. The
// tools work it out every time, as before.
export function lightmapDigest(mesh: GpuMesh): string {
    const keep = cpuCopyPolicy() == CPU_COPY_RELEASE && !mesh.deforms;
    const rev = <i64>mesh.vertsRevision;
    if (keep && mesh.lightmapDigestRevision == rev) return mesh.lightmapDigestKept;
    if (mesh.cpuReleased) {
        noteCpuMiss("lightmap: the digest of a released mesh");
        return "";
    }
    const d = digestOf(mesh);
    if (keep) {
        mesh.lightmapDigestKept = d;
        mesh.lightmapDigestRevision = rev;
    }
    return d;
}

function digestOf(mesh: GpuMesh): string {
    let h: u64 = FNV64_OFFSET;
    h = mix32(h, <u32>mesh.verts.length);
    h = mix32(h, <u32>(mesh.indices.length / 3));
    for (let i = 0; i < mesh.indices.length; i++) h = mix32(h, mesh.indices[i]);
    for (let i = 0; i < mesh.verts.length; i++) {
        const p = mesh.verts[i].pos;
        h = mix32(h, reinterpret<u32>(p.x));
        h = mix32(h, reinterpret<u32>(p.y));
        h = mix32(h, reinterpret<u32>(p.z));
    }
    return hexU64(h, 16);
}

// The tolerance of `lightmapTransformMatches`: a ten-thousandth of an
// entry's size, at least of 1 (a tenth of a millimetre of a move, or
// about 0.006 degrees of a turn).
export const LIGHTMAP_TRANSFORM_TOLERANCE: f32 = 1e-4;

// Whether an item drawn at `drawn` (its world matrix in the frame of the
// root that declares the LightmapGI) is where its bake put it, at `baked`
// (LightmapInstance.transform): every entry of the 3 x 4 matrix within
// LIGHTMAP_TRANSFORM_TOLERANCE times the larger of 1 and the entries. Not
// bit for bit: an instanced scene's matrices are products of other
// matrices than its own file's, so their last bits differ.
export function lightmapTransformMatches(drawn: Mat4, baked: Mat4): bool {
    return close3(drawn.xAxis.x, baked.xAxis.x, drawn.xAxis.y, baked.xAxis.y, drawn.xAxis.z, baked.xAxis.z)
        && close3(drawn.yAxis.x, baked.yAxis.x, drawn.yAxis.y, baked.yAxis.y, drawn.yAxis.z, baked.yAxis.z)
        && close3(drawn.zAxis.x, baked.zAxis.x, drawn.zAxis.y, baked.zAxis.y, drawn.zAxis.z, baked.zAxis.z)
        && close3(drawn.wAxis.x, baked.wAxis.x, drawn.wAxis.y, baked.wAxis.y, drawn.wAxis.z, baked.wAxis.z);
}

function close3(a0: f32, b0: f32, a1: f32, b1: f32, a2: f32, b2: f32): bool {
    return close1(a0, b0) && close1(a1, b1) && close1(a2, b2);
}

function close1(a: f32, b: f32): bool {
    const size = max<f32>(<f32>1, max<f32>(Mathf.abs(a), Mathf.abs(b)));
    return Mathf.abs(a - b) <= LIGHTMAP_TRANSFORM_TOLERANCE * size;
}

// FNV-1a over the four bytes of `v`, low byte first.
function mix32(h: u64, v: u32): u64 {
    for (let k = 0; k < 4; k++) {
        h ^= <u64>((v >> (<u32>k * 8)) & 0xff);
        h *= FNV64_PRIME;
    }
    return h;
}
