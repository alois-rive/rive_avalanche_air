// A frame's reflection probes on the GPU (milestone 20, Godot's
// ReflectionProbe; engine/src/render/probe/data.as has the conventions):
// the atlas the lit shader reads them from (surface.wgsl group 0, bindings
// 13 to 15), the block that describes them, the baked cubes' uploads, the
// live capture's targets and passes (probe.wgsl), and the schedule that
// says which probe is uploaded or captured on a frame. gpu/renderer.as draws
// a live capture's six views itself (`captureProbe`), with the shared
// renderer, and hands each picture here.
//
// The atlas is one rgba16float 2D texture of 6N x MAX_PROBES * N texels (N =
// PROBE_FACE_SIZE: 768 x 1024) with PROBE_LEVELS mips, a render target for
// the live passes, made on the first frame that has probes (a 1 x 1 dummy
// before it, which no frame reads: every frame without probes writes a
// block of zeros). Row r is the frame's r-th probe; face f of level m is the
// N >> m square at (f * (N >> m), r * (N >> m)) of mip m (`probeFaceRect`).
// A host that refuses the atlas draws the frame without probes, saying so.
//
// A baked probe (its desc's `cube`) is uploaded once per RadianceMap object
// (by identity) and row: render targets are GPU-only on Metal (an upload
// into one is undefined), so each row keeps an upload texture of its own,
// 6N x N with the same mips, written from the cube (rgb to half floats, as
// gpu/environment.as `cubeFaceBytes`) and copied into the atlas by
// fs_probe_copy, a pass per level.
//
// A live capture (an `always` probe, or a `once` probe without a bake): the
// renderer draws the six views of data.as `probeFaceCamera`, each into the
// N x N HDR `picture` (MSAA as the main pass, resolved), and after each
// `place` puts it into its face of level 0 of the scratch chain (6N x N,
// PROBE_LEVELS mips), mirrored; `finish` then halves the chain level by
// level (fs_probe_down), copies level 0 into the atlas row (fs_probe_copy)
// and prefilters levels 1 and down into it from the chain (fs_probe_filter,
// sky.as `prefilter` ported: the same 32 Hammersley samples, worked out on
// the CPU by `probeFilterUniformInto` into a block per level, made once).
// Every pass draws one full-screen triangle into one mip of one texture
// through a viewport to the rectangle it writes, loading what is around it.
// The capture's frame (`ProbeCaptureFrame`): the main frame's items through
// data.as `capturesItem`, its lights with their shadows off unless the probe
// enables them, `captureEnvironmentInto`'s environment, no overlay,
// outline, line, point or post pass, and no probe (no recursion).
// Milestone 59: a capture looks every way from the probe's origin, so the
// renderer plans its pool of lights around that point (light_select.as
// planLightPoolAround: no frustum, the nearest kept past 64) and gives the
// shared items their lists from it for each face (renderer.as
// captureView); the main view gives them its own again before it draws.
//
// The schedule (`ProbeSchedule.plan`, CPU, a test's): per frame drawn, a
// probe whose row lacks its baked cube is uploaded (a row is kept for one
// probe: ReflectionProbeDesc's key and scene, so another scene's probe at
// the same path starts afresh); a live probe is captured
// when it is `once` and its row holds no capture made at its capture key
// (data.as's placing fields, compared by value: `ProbeRow.sameKey`), when it
// is `always` and never captured in its row, and otherwise, `always`
// probes take turns, round robin, PROBE_LIVE_PER_FRAME a frame. A host
// frame captures once: the later views of a sheet only read what the first
// captured (`beginFrame` starts a host frame).
//
// Allocation: everything a capture draws with (targets, views, groups,
// blocks, the capture frame, its lights and environment, the passes'
// descriptors) is made on first use and kept, so a capture after the first
// allocates nothing on the heap (the editor's soak with an `always` probe
// checks it), and a frame without probes allocates nothing here at all.

import {
    GPUBindGroup, GPUBindGroupTexture, GPUBindGroupUBO, GPUBuffer, GPUCanvas, GPUColorAttachment, GPUPassDesc,
    GPUPipeline, GPURenderPass, GPUSampler, GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc,
} from "rive/gpu";
import { BufferUsage, Filter, LoadOp, StoreOp, TextureFormat, WrapMode } from "rive/gpu_enums";
import { abi, rive_gpu_texture_upload_v1 } from "rive/bindings";
import { MAT4_IDENTITY, Mat4, Vec3, Vec4, cosf, log2f, sinf } from "../../base/vecmath";
import { Camera, Projection } from "../camera";
import { CULL_NOT_DRAWN, CullResult } from "../cull";
import {
    DrawItem, EnvironmentDesc, ItemLines, ItemPoints, LightDesc, RenderFrame, SHADE_LIT,
} from "../frame";
import { LineInstance, PointInstance } from "./layouts";
import { PostPlan } from "../post";
import { ShadowPlan } from "../shadow";
import { PREFILTER_SAMPLES, RadianceMap } from "../sky";
import {
    MAX_PROBES, PROBE_FACE_SIZE, PROBE_LEVELS, PROBE_LIVE_PER_FRAME, PROBE_UPDATE_ALWAYS,
    PROBE_UPDATE_ONCE, ReflectionProbeDesc, ReflectionProbeSet, capturesItem, captureEnvironmentInto, isProbeCube,
    probeFaceCamera,
} from "../probe/data";
import {
    COLOR_FORMAT, DEPTH_FORMAT, PROBE_ATLAS_FORMAT, PROBE_BOX, PROBE_INTERIOR, ProbeFilterUniform, ProbeUniform, U32x4,
} from "./layouts";
import { cubeFaceBytes } from "./environment";
import { ProbePipelines } from "./pipelines";
import { uploadRegion } from "./upload";

// What FrameRenderer.warnings says when a frame's probes cannot be drawn
// (the frame is then drawn without them: reflections from the sky alone).
export const PROBE_ATLAS_WARNING = "reflection probes are not drawn: the host rejected their atlas";
export const PROBE_HALF_FLOAT_WARNING =
    "reflection probes are not drawn: the device has no half-float render targets";

// What the schedule does with a probe's row on a frame.
export const PROBE_ACTION_NONE: i32 = 0;
export const PROBE_ACTION_UPLOAD: i32 = 1;
export const PROBE_ACTION_CAPTURE: i32 = 2;

// Bytes per rgba16float texel.
const TEXEL_BYTES: u32 = 8;

const PI: f32 = 3.14159265358979323846;

// ---------------------------------------------------------------- the atlas

// A rectangle of texels in one mip of a texture.
export class ProbeRect {
    x: u32 = 0;
    y: u32 = 0;
    w: u32 = 0;
    h: u32 = 0;

    set(x: u32, y: u32, w: u32, h: u32): ProbeRect {
        this.x = x;
        this.y = y;
        this.w = w;
        this.h = h;
        return this;
    }
}

// A face's side at `level` (PROBE_FACE_SIZE >> level).
export function probeLevelSize(level: u32): u32 {
    return PROBE_FACE_SIZE >> level;
}

// The atlas's size at `level`: six faces across, MAX_PROBES rows down.
export function probeAtlasWidth(level: u32): u32 {
    return 6 * probeLevelSize(level);
}

export function probeAtlasHeight(level: u32): u32 {
    return <u32>MAX_PROBES * probeLevelSize(level);
}

// Row `row` of the atlas at `level` (every face of it), into `out`.
export function probeRowRect(row: i32, level: u32, out: ProbeRect): ProbeRect {
    const n = probeLevelSize(level);
    return out.set(0, <u32>row * n, 6 * n, n);
}

// Face `face` of row `row` at `level`, into `out`.
export function probeFaceRect(row: i32, face: i32, level: u32, out: ProbeRect): ProbeRect {
    const n = probeLevelSize(level);
    return out.set(<u32>face * n, <u32>row * n, n, n);
}

// ---------------------------------------------------------------- the filter

// Van der Corput's radical inverse in base 2 (sky.as's, for its samples).
function radicalInverse(k: u32): f32 {
    let b = k;
    b = (b << 16) | (b >> 16);
    b = ((b & 0x55555555) << 1) | ((b & 0xaaaaaaaa) >> 1);
    b = ((b & 0x33333333) << 2) | ((b & 0xcccccccc) >> 2);
    b = ((b & 0x0f0f0f0f) << 4) | ((b & 0xf0f0f0f0) >> 4);
    b = ((b & 0x00ff00ff) << 8) | ((b & 0xff00ff00) >> 8);
    return <f32>(<f64>b * 2.3283064365386963e-10);
}

function clampF(x: f32, lo: f32, hi: f32): f32 {
    return x < lo ? lo : x > hi ? hi : x;
}

// fs_probe_filter's block for level `m` of a chain of `levels` levels whose
// level 0 is `baseSize` texels a face: sky.as `prefilter`'s samples for
// roughness m / (levels - 1), number for number (its offsets from the
// normal, first source level and two weights each; samples below the
// horizon left out), and one over their weights' sum. Into `out`.
export function probeFilterUniformInto(m: u32, levels: i32, baseSize: u32, out: ProbeFilterUniform): ProbeFilterUniform {
    const k = PREFILTER_SAMPLES;
    const r = <f32>m / <f32>(levels - 1);
    const alpha = r * r;
    const a2 = alpha * alpha;
    const omegaP = <f32>4 * PI / (<f32>6 * <f32>baseSize * <f32>baseSize);
    const s = out.samples;
    s.fill(0);
    let used = 0;
    let weight: f32 = 0;
    for (let i = 0; i < k; i++) {
        const u = <f32>i / <f32>k;
        const v = radicalInverse(<u32>i);
        const phi = 2 * PI * u;
        const cosT = Mathf.sqrt((1 - v) / (1 + (a2 - 1) * v));
        const sinT = Mathf.sqrt(Mathf.max(0, 1 - cosT * cosT));
        const nl = 2 * cosT * cosT - 1;
        if (nl <= 0) continue;
        const dd = cosT * cosT * (a2 - 1) + 1;
        const dist = a2 / (PI * dd * dd);
        const pdf = dist / 4;
        const omegaS = <f32>1 / (<f32>k * pdf);
        const lod = clampF(0.5 * log2f(omegaS / omegaP) + 1, 0, <f32>(levels - 1));
        let lo = <i32>lod;
        let fr = lod - <f32>lo;
        if (lo >= levels - 1) {
            lo = levels - 1;
            fr = 0;
        }
        const at = used * 8;
        s[at] = 2 * cosT * sinT * cosf(phi);
        s[at + 1] = 2 * cosT * sinT * sinf(phi);
        s[at + 2] = nl;
        s[at + 3] = <f32>lo;
        s[at + 4] = nl * (1 - fr);
        s[at + 5] = nl * fr;
        weight += nl;
        used++;
    }
    out.info = Vec4(weight > 0 ? <f32>1 / weight : 0, <f32>used, <f32>m, <f32>levels);
    return out;
}

// ---------------------------------------------------------------- the block

// The probe block of a frame whose probes are `set` and whose rows are
// `schedule`'s: an entry per probe whose row is ready, in order (its row in
// info.w), the count and the atlas's levels and face size; all zeros when
// none is. Into `out` (nothing allocated).
export function probeUniformInto(set: ReflectionProbeSet?, schedule: ProbeSchedule, out: ProbeUniform): ProbeUniform {
    let n = 0;
    if (set != null) {
        const count = min<i32>(schedule.count, set.list.length);
        for (let r = 0; r < count; r++) {
            if (!schedule.rows[r].ready) continue;
            const p = set.list[r];
            const e = out.entries[n];
            e.toLocal = p.toLocal;
            e.extents = Vec4(p.extents.x, p.extents.y, p.extents.z, p.blendDistance);
            e.offset = Vec4(p.originOffset.x, p.originOffset.y, p.originOffset.z, p.intensity);
            e.ambient = Vec4(p.ambientColor.x, p.ambientColor.y, p.ambientColor.z, 0);
            e.info = U32x4(
                (p.boxProjection ? PROBE_BOX : 0) | (p.interior ? PROBE_INTERIOR : 0), <u32>p.ambientMode,
                p.reflectionMask, <u32>r);
            n++;
        }
    }
    out.counts = n > 0 ? U32x4(<u32>n, PROBE_LEVELS, PROBE_FACE_SIZE, 0) : U32x4(0, 0, 0, 0);
    return out;
}

// ---------------------------------------------------------------- the schedule

// What one atlas row holds, and what it was made from.
export class ProbeRow {
    // The probe (ReflectionProbeDesc.key) whose row it is ("" none yet).
    key: string = "";
    // Its scene (ReflectionProbeDesc.scene).
    scene: string = "";
    // The baked cube uploaded into it (by identity), or null.
    cube: RadianceMap? = null;
    // It holds a live capture.
    live: bool = false;
    // It holds something the shader may read.
    ready: bool = false;
    // The capture key of its live capture (data.as section 1.9's fields:
    // what places a capture).
    toWorld: Mat4 = MAT4_IDENTITY;
    extents: Vec3 = Vec3(0, 0, 0);
    originOffset: Vec3 = Vec3(0, 0, 0);
    maxDistance: f32 = 0;
    cullMask: u32 = 0;
    reflectionMask: u32 = 0;
    interior: bool = false;
    enableShadows: bool = false;
    ambientMode: i32 = 0;
    ambientColor: Vec3 = Vec3(0, 0, 0);

    // Forgets what it holds (another probe takes the row).
    reset(key: string, scene: string): void {
        this.key = key;
        this.scene = scene;
        this.cube = null;
        this.live = false;
        this.ready = false;
    }

    // Keeps `p`'s capture key.
    keyFrom(p: ReflectionProbeDesc): void {
        this.toWorld = p.toWorld;
        this.extents = p.extents;
        this.originOffset = p.originOffset;
        this.maxDistance = p.maxDistance;
        this.cullMask = p.cullMask;
        this.reflectionMask = p.reflectionMask;
        this.interior = p.interior;
        this.enableShadows = p.enableShadows;
        this.ambientMode = p.ambientMode;
        this.ambientColor = p.ambientColor;
    }

    // Whether its capture was made at `p`'s capture key (by value).
    sameKey(p: ReflectionProbeDesc): bool {
        return this.toWorld == p.toWorld && this.extents == p.extents && this.originOffset == p.originOffset
            && this.maxDistance == p.maxDistance && this.cullMask == p.cullMask
            && this.reflectionMask == p.reflectionMask && this.interior == p.interior
            && this.enableShadows == p.enableShadows && this.ambientMode == p.ambientMode
            && this.ambientColor == p.ambientColor;
    }
}

// Which rows a frame uploads and captures (see the header). Pure CPU.
export class ProbeSchedule {
    // By atlas row (MAX_PROBES).
    rows: Array<ProbeRow> = [];
    // This frame's action per row (PROBE_ACTION_*), for its first `count`.
    actions: StaticArray<i32> = new StaticArray<i32>(MAX_PROBES);
    // The probes of the frame planned last (at most MAX_PROBES).
    count: i32 = 0;
    // The row the round robin looks at first.
    private cursor: i32 = 0;
    // Whether this host frame planned captures already (a sheet's later
    // views capture nothing).
    private hostFrameCaptured: bool = false;

    constructor() {
        for (let i = 0; i < MAX_PROBES; i++) this.rows.push(new ProbeRow());
    }

    // A new host frame (FrameRenderer.beginFrame).
    beginFrame(): void {
        this.hostFrameCaptured = false;
    }

    // Plans frame `f` (see the header): fills `actions` for its probes and
    // marks the rows as they will be once done (`failed` takes one back).
    // The probes the frame has (0 without, or outside the lit shading,
    // which reads none).
    plan(f: RenderFrame): i32 {
        const actions = this.actions;
        for (let r = 0; r < MAX_PROBES; r++) unchecked(actions[r] = PROBE_ACTION_NONE);
        this.count = 0;
        const set = f.probes;
        if (set == null || f.shading != SHADE_LIT) return 0;
        const list = set.list;
        const n = min<i32>(list.length, MAX_PROBES);
        this.count = n;
        if (n == 0) return 0;
        const mayCapture = !this.hostFrameCaptured;
        for (let r = 0; r < n; r++) {
            const p = list[r];
            const row = this.rows[r];
            if (row.key != p.key || row.scene != p.scene) row.reset(p.key, p.scene);
            const cube = p.cube;
            if (cube != null) {
                if (row.cube !== cube) {
                    actions[r] = PROBE_ACTION_UPLOAD;
                    row.cube = cube;
                    row.live = false;
                    row.ready = true;
                }
                continue;
            }
            if (row.cube != null) {
                // Its bake is gone: it is captured live from now on.
                row.cube = null;
                row.live = false;
                row.ready = false;
            }
            if (!mayCapture) continue;
            if (!row.live || (p.updateMode == PROBE_UPDATE_ONCE && !row.sameKey(p))) {
                actions[r] = PROBE_ACTION_CAPTURE;
                row.live = true;
                row.ready = true;
                row.keyFrom(p);
            }
        }
        if (mayCapture) {
            // The always probes captured before take turns.
            let budget = PROBE_LIVE_PER_FRAME;
            for (let k = 0; k < n && budget > 0; k++) {
                const r = (this.cursor + k) % n;
                const p = list[r];
                if (actions[r] != PROBE_ACTION_NONE || p.cube != null || p.updateMode != PROBE_UPDATE_ALWAYS) continue;
                if (!this.rows[r].live) continue;
                actions[r] = PROBE_ACTION_CAPTURE;
                this.rows[r].keyFrom(p);
                this.cursor = (r + 1) % n;
                budget--;
            }
            this.hostFrameCaptured = true;
        }
        return n;
    }

    // Row `r`'s upload or capture did not happen: nothing in it is read,
    // and the next frame tries again.
    failed(r: i32): void {
        const row = this.rows[r];
        row.reset(row.key, row.scene);
    }

    // Every row forgotten (the frame's probes could not be drawn at all).
    forget(): void {
        for (let r = 0; r < this.rows.length; r++) this.rows[r].reset("", "");
    }

    // The rows of scene `scene`'s probes forgotten (that scene loaded again:
    // its tree is new at the same path, so its probes' rows would match).
    forgetScene(scene: string): void {
        for (let r = 0; r < this.rows.length; r++) if (this.rows[r].scene == scene) this.rows[r].reset("", "");
    }
}

// ---------------------------------------------------------------- the capture frame

// `src`'s every field into `dst`, its shadow kept only when `shadows`.
export function copyLightInto(src: LightDesc, dst: LightDesc, shadows: bool): void {
    dst.kind = src.kind;
    dst.color = src.color;
    dst.energy = src.energy;
    dst.specular = src.specular;
    dst.position = src.position;
    dst.direction = src.direction;
    dst.range = src.range;
    dst.attenuation = src.attenuation;
    dst.spotAngle = src.spotAngle;
    dst.spotAngleAttenuation = src.spotAngleAttenuation;
    dst.shadow = src.shadow && shadows;
    dst.shadowBias = src.shadowBias;
    dst.shadowNormalBias = src.shadowNormalBias;
    dst.shadowBlur = src.shadowBlur;
    dst.shadowOpacity = src.shadowOpacity;
    dst.directionalShadowMode = src.directionalShadowMode;
    dst.shadowSplits = src.shadowSplits;
    dst.shadowMaxDistance = src.shadowMaxDistance;
    dst.shadowFadeStart = src.shadowFadeStart;
    dst.angularDistance = src.angularDistance;
    dst.bakeMode = src.bakeMode;
    dst.size = src.size;
    dst.indirectEnergy = src.indirectEnergy;
}

// Leaves out of every pass (main and shadow tiles) of a capture of `p` the
// items its capture does not draw (data.as capturesItem): `cull` is what
// cull.as decided for the capture's frame.
export function leaveOutUncaptured(p: ReflectionProbeDesc, items: Array<DrawItem>, cull: CullResult): void {
    const n = min<i32>(items.length, cull.main.length);
    for (let i = 0; i < n; i++) {
        if (capturesItem(p, unchecked(items[i]))) continue;
        unchecked(cull.main[i] = CULL_NOT_DRAWN);
        unchecked(cull.casters[i] = 0);
    }
}

// The frame one face of a live capture is drawn from (see the header),
// kept and set up in place for every capture.
export class ProbeCaptureFrame {
    frame: RenderFrame;
    environment: EnvironmentDesc = new EnvironmentDesc();
    lights: Array<LightDesc> = [];
    // The colour the capture's main pass clears to: linear, before the tone
    // map (data.as section 2's background where no sky is drawn).
    clear: Vec3 = Vec3(0, 0, 0);
    // The visibility ranges' state, empty for each capture (no hysteresis).
    private ranges: Array<bool> = [];
    private noLines: Array<LineInstance> = [];
    private noPoints: Array<PointInstance> = [];
    private noItemLines: Array<ItemLines> = [];
    private noItemPoints: Array<ItemPoints> = [];

    constructor() {
        const cam = new Camera(Vec3(0, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0), Projection.perspective(90), 0.01, 1);
        this.frame = new RenderFrame(PROBE_FACE_SIZE, PROBE_FACE_SIZE, cam);
    }

    // The frame of a capture of `p` from frame `f` (the camera of face 0;
    // `face` turns it). Nothing allocated once `lights` holds as many
    // lights as `f`.
    setUp(f: RenderFrame, p: ReflectionProbeDesc): void {
        const c = this.frame;
        c.width = PROBE_FACE_SIZE;
        c.height = PROBE_FACE_SIZE;
        c.ssaa = 1;
        c.gridExtent = 0;
        c.shading = SHADE_LIT;
        c.overlayFlags = 0;
        c.editMode = false;
        c.matcap = 0;
        c.background = Vec4(0, 0, 0, 1);
        c.drawSurfaces = true;
        c.materialMode = f.materialMode;
        c.outline = false;
        c.items = f.items;
        c.materials = f.materials;
        c.baseDir = f.baseDir;
        c.worldLines = this.noLines;
        c.topLines = this.noLines;
        c.topPoints = this.noPoints;
        c.itemLines = this.noItemLines;
        c.itemPoints = this.noItemPoints;
        c.overlay = null;
        const ls = this.lights;
        while (ls.length < f.lights.length) ls.push(new LightDesc());
        ls.length = f.lights.length;
        for (let i = 0; i < ls.length; i++) copyLightInto(f.lights[i], ls[i], p.enableShadows);
        c.lights = ls;
        captureEnvironmentInto(f.environment, p, this.environment);
        c.environment = this.environment;
        c.casterBounds = f.casterBounds;
        c.hasCasters = f.hasCasters;
        c.drawBounds = f.drawBounds;
        c.hasDrawBounds = f.hasDrawBounds;
        c.lightmap = f.lightmap;
        c.probes = null;
        const set = f.probes;
        this.clear = p.interior || set == null ? Vec3(0, 0, 0) : set.clear;
        this.face(p, 0);
    }

    // Turns the frame to face `face` of `p`, its visibility ranges as for a
    // first picture.
    face(p: ReflectionProbeDesc, face: i32): void {
        const c = this.frame;
        probeFaceCamera(p, face, c.camera);
        const ranges = this.ranges;
        ranges.length = c.items.length;
        ranges.fill(false);
        c.rangeState = ranges;
    }
}

// ---------------------------------------------------------------- the GPU side

// `pass.setBindGroup(0, g)` through the host binding, allocating nothing
// (renderer.as's `bindGroup`).
function bindGroup0(pass: GPURenderPass, g: GPUBindGroup): void {
    abi.rive_gpu_pass_set_bind_group(pass.handle, 0, g.handle, 0, 0);
}

// A 2D render target of `w` x `h` texels, `mips` levels, `samples` samples.
function texture(w: u32, h: u32, format: TextureFormat, mips: u32, samples: u32, renderTarget: bool): GPUTexture {
    const d = new GPUTextureDesc();
    d.width = w;
    d.height = h;
    d.format = format;
    d.numMipmaps = mips;
    d.sampleCount = samples;
    d.renderTarget = renderTarget;
    return new GPUTexture(d);
}

// The view of mip `level` of `t` alone.
function levelView(t: GPUTexture, level: u32): GPUTextureView {
    const d = new GPUTextureViewDesc();
    d.baseMipLevel = level;
    d.mipCount = 1;
    return t.view(d);
}

// Every mip of `t`, one view each; empty when the host refuses one.
function levelViews(t: GPUTexture, levels: u32): Array<GPUTextureView> {
    const out = new Array<GPUTextureView>();
    for (let m: u32 = 0; m < levels; m++) {
        const v = levelView(t, m);
        if (v.handle == 0) return [];
        out.push(v);
    }
    return out;
}

// A baked row's upload texture, its levels' views and the groups that copy
// each into the atlas.
class RowUpload {
    texture: GPUTexture;
    groups: Array<GPUBindGroup>;

    constructor(texture: GPUTexture, groups: Array<GPUBindGroup>) {
        this.texture = texture;
        this.groups = groups;
    }
}

export class GpuProbes {
    // The atlas (binding 14): the 1 x 1 dummy until a frame has probes.
    view: GPUTextureView;
    // Bilinear within a level, the level the shader names, clamped
    // (binding 15).
    sampler: GPUSampler;
    // +1 whenever `view` changes: the renderer remakes the bind groups.
    generation: u32 = 0;
    // The frame's block, filled by `fillUniform` (zeros without probes).
    uniform: ProbeUniform = new ProbeUniform();
    schedule: ProbeSchedule = new ProbeSchedule();
    // A live capture's frame, and the shadow plan and post plan it is
    // drawn with (no post pass; toneInPost: lit() keeps HDR colour).
    capture: ProbeCaptureFrame = new ProbeCaptureFrame();
    shadowPlan: ShadowPlan = new ShadowPlan();
    capturePost: PostPlan = new PostPlan();
    // The live captures and uploads the last frame made (statistics).
    captures: i32 = 0;
    uploads: i32 = 0;
    private dummy: GPUTexture;
    private dummyView: GPUTextureView;
    // The atlas and a view of each of its mips (what the passes draw into);
    // `atlasTried` once made or refused.
    private atlas: GPUTexture? = null;
    private atlasLevels: Array<GPUTextureView> = [];
    private atlasTried: bool = false;
    // The capture's targets (made on the first capture): the N x N HDR
    // picture, its MSAA colour and depth, the scratch chain and its views.
    private picture: GPUTexture? = null;
    private pictureView: GPUTextureView? = null;
    private msaaView: GPUTextureView? = null;
    private depthView: GPUTextureView? = null;
    private samples: u32 = 0;
    private captureTried: bool = false;
    private scratchView: GPUTextureView? = null;
    private scratchLevels: Array<GPUTextureView> = [];
    // fs_probe_filter's blocks by level (index 0 unused: level 0 is
    // copied), and the groups of every live pass.
    private filterBuffers: Array<GPUBuffer> = [];
    private placeGroup: GPUBindGroup? = null;
    private downGroups: Array<GPUBindGroup> = [];
    private copyGroup: GPUBindGroup? = null;
    private filterGroups: Array<GPUBindGroup> = [];
    // The baked rows' uploads, by row.
    private rowUploads: Array<RowUpload?> = [];
    // The probe passes' descriptor and colour attachment, and the pass
    // wrapper (passes are recorded one at a time).
    private color: GPUColorAttachment = new GPUColorAttachment();
    private desc: GPUPassDesc = new GPUPassDesc();
    private wrapper: GPURenderPass = new GPURenderPass(0);
    private rect: ProbeRect = new ProbeRect();

    constructor() {
        // A host that refuses even this could not make the surface
        // pipelines either (group 0 declares the atlas binding).
        this.dummy = texture(1, 1, PROBE_ATLAS_FORMAT, 1, 1, false);
        if (this.dummy.handle != 0) this.dummy.upload(region(1, 1, 0, 0, 0), new ArrayBuffer(<i32>TEXEL_BYTES));
        this.dummyView = this.dummy.view();
        this.view = this.dummyView;
        this.sampler = new GPUSampler(
            Filter.linear, Filter.linear, Filter.nearest, WrapMode.clampToEdge, WrapMode.clampToEdge);
        this.capturePost.toneInPost = true;
        this.desc.color = [this.color];
        for (let i = 0; i < MAX_PROBES; i++) this.rowUploads.push(null);
    }

    // A new host frame (FrameRenderer.beginFrame).
    beginFrame(): void {
        this.schedule.beginFrame();
    }

    // The atlas, made on the first call (see the header); false when the
    // host refused it (then and on every later call).
    ensureAtlas(): bool {
        if (this.atlas != null) return true;
        if (this.atlasTried) return false;
        this.atlasTried = true;
        const t = texture(probeAtlasWidth(0), probeAtlasHeight(0), PROBE_ATLAS_FORMAT, PROBE_LEVELS, 1, true);
        if (t.handle == 0) return false;
        const whole = t.view();
        const levels = levelViews(t, PROBE_LEVELS);
        if (whole.handle == 0 || levels.length == 0) {
            if (whole.handle != 0) whole.release();
            for (let i = 0; i < levels.length; i++) levels[i].release();
            t.release();
            return false;
        }
        this.atlas = t;
        this.atlasLevels = levels;
        this.view = whole;
        this.generation++;
        return true;
    }

    // Uploads `cube` (a baked probe) into row `row` (see the header);
    // false when it is not a probe's cube or the host refused its texture.
    upload(row: i32, cube: RadianceMap?, pp: ProbePipelines, canvas: GPUCanvas): bool {
        if (cube == null || !isProbeCube(cube)) return false;
        let u = this.rowUploads[row];
        if (u == null) {
            const t = texture(probeAtlasWidth(0), probeLevelSize(0), PROBE_ATLAS_FORMAT, PROBE_LEVELS, 1, false);
            if (t.handle == 0) return false;
            const views = levelViews(t, PROBE_LEVELS);
            if (views.length == 0 || !this.ensureFilters(pp)) {
                t.release();
                return false;
            }
            const groups = new Array<GPUBindGroup>();
            for (let m = 0; m < views.length; m++) groups.push(this.group(pp, 1, views[m]));
            u = new RowUpload(t, groups);
            this.rowUploads[row] = u;
        }
        for (let m = 0; m < cube.levels.length; m++) {
            const level = cube.levels[m];
            const n = level.size;
            for (let f = 0; f < 6; f++) {
                u.texture.upload(region(n, n, <u32>m, <u32>f * n, 0), cubeFaceBytes(level, f));
            }
        }
        for (let m = 0; m < <i32>PROBE_LEVELS; m++) {
            const r = probeRowRect(row, <u32>m, this.rect);
            this.pass(this.atlasLevels[m], false, r, pp.copy, u.groups[m], canvas);
        }
        this.uploads++;
        return true;
    }

    // The capture's targets for the main pass's `samples` (see the
    // header), made on the first capture; false when the host refused one.
    // (A renderer's pipelines keep one sample count, so the targets are
    // made once; a host that refused one is not asked again.)
    ensureCaptureTargets(pp: ProbePipelines, samples: u32): bool {
        if (this.picture != null) return this.samples == samples;
        if (this.captureTried) return false;
        this.captureTried = true;
        const n = PROBE_FACE_SIZE;
        const pic = texture(n, n, PROBE_ATLAS_FORMAT, 1, 1, true);
        const depth = texture(n, n, DEPTH_FORMAT, 1, samples, true);
        const msaa = samples > 1 ? texture(n, n, COLOR_FORMAT, 1, samples, true) : null;
        const scratch = texture(probeAtlasWidth(0), n, PROBE_ATLAS_FORMAT, PROBE_LEVELS, 1, true);
        const scratchLevels = scratch.handle != 0 ? levelViews(scratch, PROBE_LEVELS) : [];
        if (pic.handle == 0 || depth.handle == 0 || (msaa != null && msaa.handle == 0) || scratchLevels.length == 0
            || !this.ensureFilters(pp)) {
            for (let i = 0; i < scratchLevels.length; i++) scratchLevels[i].release();
            if (pic.handle != 0) pic.release();
            if (depth.handle != 0) depth.release();
            if (msaa != null && msaa.handle != 0) msaa.release();
            if (scratch.handle != 0) scratch.release();
            return false;
        }
        const picView = pic.view();
        this.picture = pic;
        this.pictureView = picView;
        this.depthView = depth.view();
        this.msaaView = msaa != null ? msaa.view() : null;
        this.samples = samples;
        const whole = scratch.view();
        this.scratchView = whole;
        this.scratchLevels = scratchLevels;
        this.placeGroup = this.group(pp, 1, picView);
        this.copyGroup = this.group(pp, 1, scratchLevels[0]);
        for (let m = 1; m < <i32>PROBE_LEVELS; m++) {
            this.downGroups.push(this.group(pp, 1, scratchLevels[m - 1]));
            this.filterGroups.push(this.group(pp, m, whole));
        }
        return true;
    }

    // The colour attachment of a capture view's main pass, into `c`: the
    // MSAA target resolved into the picture (or the picture itself with
    // one sample), cleared to the capture frame's `clear`; and its depth.
    captureColor(c: GPUColorAttachment): void {
        const pic = this.pictureView;
        const msaa = this.msaaView;
        if (msaa != null) {
            c.view = msaa;
            c.resolveTarget = pic;
            c.storeOp = StoreOp.discard;
        } else {
            c.view = pic;
            c.resolveTarget = null;
            c.storeOp = StoreOp.store;
        }
        c.loadOp = LoadOp.clear;
        const k = this.capture.clear;
        c.clearR = k.x;
        c.clearG = k.y;
        c.clearB = k.z;
        c.clearA = 1;
    }

    captureDepth(): GPUTextureView? {
        return this.depthView;
    }

    // The picture of face `face` into its face of scratch level 0.
    place(face: i32, pp: ProbePipelines, canvas: GPUCanvas): void {
        const g = this.placeGroup;
        if (g == null) return;
        const n = PROBE_FACE_SIZE;
        this.pass(this.scratchLevels[0], false, this.rect.set(<u32>face * n, 0, n, n), pp.place, g, canvas);
    }

    // The scratch chain's levels, then atlas row `row`: level 0 copied,
    // every other prefiltered (see the header).
    finish(row: i32, pp: ProbePipelines, canvas: GPUCanvas): void {
        const copy = this.copyGroup;
        if (copy == null) return;
        for (let m = 1; m < <i32>PROBE_LEVELS; m++) {
            const n = probeLevelSize(<u32>m);
            this.pass(this.scratchLevels[m], true, this.rect.set(0, 0, 6 * n, n), pp.down, this.downGroups[m - 1], canvas);
        }
        this.pass(this.atlasLevels[0], false, probeRowRect(row, 0, this.rect), pp.copy, copy, canvas);
        for (let m = 1; m < <i32>PROBE_LEVELS; m++) {
            this.pass(this.atlasLevels[m], false, probeRowRect(row, <u32>m, this.rect), pp.filter,
                this.filterGroups[m - 1], canvas);
        }
        this.captures++;
    }

    // The frame's block from its probes (`probeUniformInto`).
    fillUniform(set: ReflectionProbeSet?): void {
        probeUniformInto(set, this.schedule, this.uniform);
    }

    // A block of zeros: the frame draws no probe.
    clearUniform(): void {
        this.uniform.counts = U32x4(0, 0, 0, 0);
    }

    // fs_probe_filter's blocks, made once (their samples depend on the
    // level alone).
    private ensureFilters(pp: ProbePipelines): bool {
        if (this.filterBuffers.length > 0) return true;
        const u = new ProbeFilterUniform();
        for (let m: u32 = 0; m < PROBE_LEVELS; m++) {
            probeFilterUniformInto(max<u32>(m, 1), <i32>PROBE_LEVELS, PROBE_FACE_SIZE, u);
            const bytes = u.toBytes();
            const b = new GPUBuffer(BufferUsage.uniform, <u32>bytes.byteLength, bytes);
            if (b.handle == 0) {
                this.filterBuffers.length = 0;
                return false;
            }
            this.filterBuffers.push(b);
        }
        return true;
    }

    // Group 0 of the probe module: level `level`'s block and `src`.
    private group(pp: ProbePipelines, level: i32, src: GPUTextureView): GPUBindGroup {
        return new GPUBindGroup(
            pp.layout, [new GPUBindGroupUBO(0, this.filterBuffers[level])], [new GPUBindGroupTexture(1, src)]);
    }

    // One probe pass: `pipeline` with group `g` into `rect` of `target`
    // (a view of one mip), the rest of it loaded, or cleared when `whole`
    // (the rectangle is all of it).
    private pass(
        target: GPUTextureView, whole: bool, rect: ProbeRect, pipeline: GPUPipeline, g: GPUBindGroup, canvas: GPUCanvas,
    ): void {
        const c = this.color;
        c.view = target;
        c.resolveTarget = null;
        c.loadOp = whole ? LoadOp.clear : LoadOp.load;
        c.storeOp = StoreOp.store;
        c.clearR = 0;
        c.clearG = 0;
        c.clearB = 0;
        c.clearA = 1;
        this.desc.depthView = null;
        this.desc.label = "hedra probe filter";
        const pass = canvas.beginRenderPass(this.desc, this.wrapper);
        pass.setPipeline(pipeline);
        pass.setViewport(<f32>rect.x, <f32>rect.y, <f32>rect.w, <f32>rect.h);
        pass.setScissor(rect.x, rect.y, rect.w, rect.h);
        bindGroup0(pass, g);
        pass.draw(3);
        pass.finish();
    }
}

// The upload region of a `w` x `h` block at (x, y) of mip `mip` (the
// renderer's one region: gpu/upload.as).
function region(w: u32, h: u32, mip: u32, x: u32, y: u32): rive_gpu_texture_upload_v1 {
    return uploadRegion(w, h, mip, 0, x, y, w * TEXEL_BYTES);
}
