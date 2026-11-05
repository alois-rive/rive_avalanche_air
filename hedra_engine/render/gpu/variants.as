// The device side of the surface shader's variants (../variant.as,
// docs/engine/SHADING.md "Specialised shaders"): for each draw of the main
// pass in the lit and material shadings, the key of what it uses
// (../variant_keys.as), the key's module from the frame's source
// (../shader/variants.as), and the key's pipelines (Pipelines
// .surfacePipelineOf with that module), made on first use and kept by key
// and blending. A key whose module is not ready, or whose pipeline the
// host refused, draws with the ubershader's pipeline, exactly as before:
// the renderer's `want` (Godot 4.4's ubershader, drawn while a specialised
// pipeline compiles).
//
// The renderer (./renderer.as drawSurfaces) asks `pick` for every range it
// draws with a StandardMaterial3D in the main pass (never a custom
// material, an item drawn on top, or another pass); `beginView` once a
// view, with the frame its draws belong to: a range of another frame (a
// probe's capture, drawn without a beginView of its own) is the
// ubershader's.
//
// A variant's module keeps the ubershader's binding interface (every
// declaration, and the phony anchors of its fragment entry:
// hedra_compiler/shader/variants.as), so its pipelines take the
// ubershader's group layouts (Pipelines.surfaceLayouts) and every bind
// group of the view serves them. The material part of a key is worked out
// once per material and kept (by the frame's materials array, by identity,
// and the binder's generations: a value dragged or a texture made live
// works it out again); the draw part is the view's frame-wide bits, the
// item's own and the vertex kind, and the source's volatile bits
// (../shader/variants.as) on top.
//
// Allocation: a key seen before is a map lookup by u64 and a few field
// reads; a new key makes its entry, and its pipelines once its module is
// ready. A view of the same frame allocates nothing.

import { GPUPipeline, GPUTextureView, GPUBindGroup, GPUShaderModule } from "rive/gpu";
import { DrawItem, RenderFrame } from "../frame";
import {
    MaterialBinder, MaterialDesc, extLayersInto, materialExtUniformInto, materialIsExt, materialUniform, textureBitsOf,
} from "../material";
import { PBR_SLOT_COUNT } from "../../material/pbr";
import { PostPlan } from "../post";
import { SurfaceVariantSource, VARIANT_PENDING, VARIANT_READY } from "../shader/variants";
import {
    VARIANT_UBER, VB_D_VERTEX_INSTANCED, VB_D_VERTEX_LIGHTMAP, VB_D_VERTEX_PLAIN, VB_D_VERTEX_SKINNED, VB_M_EXT,
    variantKey,
} from "../variant";
import { frameHasVariants, frameVariantBits, itemVariantBitsOf, materialVariantBits } from "../variant_keys";
import { MaterialExtUniform } from "./layouts";
import { buffersOf } from "./mesh_cache";
import { Pipelines } from "./pipelines";

// What the last view drew (the statistics' and the status's
// "variants"): ranges drawn with a variant, ranges drawn with the
// ubershader, keys asked that a source does not have ready.
export class VariantStats {
    drawn: i32 = 0;
    uber: i32 = 0;
    pending: i32 = 0;
    // Distinct keys with pipelines made so far.
    keys: i32 = 0;

    reset(): void {
        this.drawn = 0;
        this.uber = 0;
        this.pending = 0;
    }
}

// A draw's vertex kind (VB_D_VERTEX_*).
export function variantKindOf(instanced: bool, skinned: bool, lightmapped: bool): u32 {
    if (lightmapped) return VB_D_VERTEX_LIGHTMAP;
    if (instanced) return VB_D_VERTEX_INSTANCED;
    if (skinned) return VB_D_VERTEX_SKINNED;
    return VB_D_VERTEX_PLAIN;
}

// A key's module and pipelines (opaque, blended, and the depth prepass's),
// null until made; `refused` once the host refused one.
class VariantPipelines {
    key: u64;
    module: GPUShaderModule? = null;
    opaque: GPUPipeline? = null;
    blended: GPUPipeline? = null;
    depth: GPUPipeline? = null;
    refused: bool = false;
    // The source's generation this entry last asked it at (a module that
    // is not ready is asked again only once the generation moved).
    asked: i32 = -1;

    constructor(key: u64) {
        this.key = key;
    }

    releasePipelines(): void {
        const a = this.opaque;
        if (a != null) a.release();
        const b = this.blended;
        if (b != null) b.release();
        const d = this.depth;
        if (d != null) d.release();
        this.opaque = null;
        this.blended = null;
        this.depth = null;
        this.refused = false;
    }
}

// A material whose key part is not worked out yet.
const BITS_UNKNOWN: u64 = 0xFFFFFFFFFFFFFFFF;

export class SurfaceVariants {
    stats: VariantStats = new VariantStats();
    private entries: Map<u64, VariantPipelines> = new Map<u64, VariantPipelines>();
    // The Pipelines the entries' pipelines were made with (a renderer whose
    // samples or format changed has new ones: every pipeline is made again).
    private madeWith: Pipelines? = null;
    // The view's frame, whether it draws in a shading variants serve, and
    // its frame-wide bits (beginView).
    private viewFrame: RenderFrame? = null;
    private viewOn: bool = false;
    private frameBits: u32 = 0;
    // The material part of keys (the low 32 bits; BITS_UNKNOWN until worked
    // out), by index of `bitsOf`'s materials array, at the binder's
    // generations `bitsValues` and `bitsLive`; and the default material's.
    private bitsOf: Array<MaterialDesc>? = null;
    private bits: Array<u64> = [];
    private bitsValues: i32 = -1;
    private bitsLive: i32 = -1;
    private defaultBits: u64 = BITS_UNKNOWN;
    private defaultDesc: MaterialDesc = new MaterialDesc();
    // The extended block and layers a material's bits are worked out
    // through (filled in place).
    private extScratch: MaterialExtUniform = new MaterialExtUniform();
    private layerScratch: StaticArray<i32> = new StaticArray<i32>(PBR_SLOT_COUNT);

    // A view's frame-wide bits, read from its frame (the main view's, a
    // viewport's: each calls it before its main pass). `post` and
    // `shadowed` are the view's plans, which the bits do not read
    // (../variant_keys.as frameVariantBits says why).
    beginView(f: RenderFrame, post: PostPlan, shadowed: bool): void {
        this.stats.reset();
        this.viewFrame = f;
        this.viewOn = frameHasVariants(f) && f.renderQuality.specializeSurfaces;
        this.frameBits = this.viewOn ? frameVariantBits(f, post, shadowed) : 0;
    }

    // The key of the range of item `d` with material `materialKey`, of
    // vertex kind `kind`, with `source`'s volatile bits; VARIANT_UBER when
    // the range is the ubershader's whatever the source holds.
    private keyOf(source: SurfaceVariantSource, materials: MaterialBinder<GPUTextureView, GPUBindGroup>,
        f: RenderFrame, d: DrawItem, materialKey: i64, kind: u32, ext: bool): u64 {
        return this.keyFor(source, materials.valuesGeneration, materials.liveGeneration, f, d, materialKey, kind, ext);
    }

    // keyOf with the binder's generations given (what the tests reach
    // without a device): the key, or VARIANT_UBER for the ubershader's (not 0,
    // which is a key like any other: the material shading's plain,
    // untextured range sets no bit, and is drawn with its variant).
    keyFor(source: SurfaceVariantSource, valuesGeneration: i32, liveGeneration: i32, f: RenderFrame, d: DrawItem,
        materialKey: i64, kind: u32, ext: bool): u64 {
        if (!this.viewOn || f !== this.viewFrame) return VARIANT_UBER;
        // (an instanced item is never skinned: the ubershader's pipelines
        // draw such a mix as they always did)
        if (kind == VB_D_VERTEX_SKINNED && d.instances != null) return VARIANT_UBER;
        const m = this.materialBits(valuesGeneration, liveGeneration, f, materialKey);
        // (the lightmap entries' vertex stage is one for both: a prepass
        // may name either)
        if (m == BITS_UNKNOWN || (kind != VB_D_VERTEX_LIGHTMAP && ((m & <u64>VB_M_EXT) != 0) != ext)) return VARIANT_UBER;
        const g = d.mesh;
        const b = g != null ? buffersOf(g) : null;
        const hidden = b != null && b.hiddenFaces;
        const draw = this.frameBits | itemVariantBitsOf(f, d, hidden) | kind;
        return variantKey(<u32>m, draw) | source.volatile();
    }

    // Whether key `key`'s module is ready (asked of `source` the first time,
    // then again only once its generation moved): `pick`'s look-up, without
    // a pipeline (the tests' way in).
    ready(source: SurfaceVariantSource, key: u64): bool {
        const e = this.entryAt(source, key);
        return e != null && e.module != null;
    }

    // The entry of `key`, made on first use, its module asked for while it
    // has none (null for no key), its pipelines those of `pl`.
    private entryOf(source: SurfaceVariantSource, pl: Pipelines, key: u64): VariantPipelines? {
        if (key == VARIANT_UBER) return null;
        if (this.madeWith !== pl) {
            this.release();
            this.madeWith = pl;
        }
        return this.entryAt(source, key);
    }

    private entryAt(source: SurfaceVariantSource, key: u64): VariantPipelines? {
        if (key == VARIANT_UBER) return null;
        let e: VariantPipelines;
        if (this.entries.has(key)) {
            e = this.entries.get(key);
        } else {
            e = new VariantPipelines(key);
            this.entries.set(key, e);
        }
        if (e.module == null && e.asked != source.generation) {
            // (a source answers a key it has never been asked for by
            // starting it: the tools' compile, the project's asset)
            const mod = source.moduleOf(key);
            if (mod != null && source.stateOf(key) == VARIANT_READY) e.module = mod;
            else e.asked = source.generation;
        }
        return e;
    }

    // The pipeline the range of item `d` with material `materialKey` draws
    // with in the main pass: its variant's, of vertex kind `kind`, the
    // extended entries when `ext`, blended when `blend`; null for the
    // ubershader's (the renderer's own choice). `source` null: no variants.
    pick(
        pl: Pipelines, source: SurfaceVariantSource?, materials: MaterialBinder<GPUTextureView, GPUBindGroup>,
        f: RenderFrame, d: DrawItem, materialKey: i64, kind: u32, ext: bool, blend: bool,
    ): GPUPipeline? {
        if (source == null) {
            this.stats.uber++;
            return null;
        }
        const e = this.entryOf(source, pl, this.keyOf(source, materials, f, d, materialKey, kind, ext));
        if (e == null || e.refused) {
            this.stats.uber++;
            return null;
        }
        const mod = e.module;
        if (mod == null) {
            if (source.stateOf(e.key) == VARIANT_PENDING) this.stats.pending++;
            this.stats.uber++;
            return null;
        }
        let p = blend ? e.blended : e.opaque;
        if (p == null) {
            const made = pl.surfacePipelineOf(mod, kind, ext, blend);
            if (made.handle == 0) {
                e.refused = true;
                this.stats.uber++;
                return null;
            }
            if (e.opaque == null && e.blended == null) this.stats.keys++;
            if (blend) e.blended = made;
            else e.opaque = made;
            p = made;
        }
        this.stats.drawn++;
        return p;
    }

    // The depth prepass's pipeline for the same draw: the variant's own
    // (Pipelines.depthPipelineOf with its module), so that the main pass
    // drawn with the variant finds the depths its vertex stage wrote; null
    // when `pick` would answer null (the prepass then draws the
    // ubershader's, as the main pass does).
    pickDepth(
        pl: Pipelines, source: SurfaceVariantSource?, materials: MaterialBinder<GPUTextureView, GPUBindGroup>,
        f: RenderFrame, d: DrawItem, materialKey: i64, kind: u32, ext: bool,
    ): GPUPipeline? {
        if (source == null) return null;
        const e = this.entryOf(source, pl, this.keyOf(source, materials, f, d, materialKey, kind, ext));
        if (e == null || e.refused) return null;
        const mod = e.module;
        if (mod == null) return null;
        // (the main pass's pipeline first: a module the host refuses there
        // is the ubershader's in both passes)
        if (e.opaque == null) {
            const made = pl.surfacePipelineOf(mod, kind, ext, false);
            if (made.handle == 0) {
                e.refused = true;
                return null;
            }
            if (e.blended == null) this.stats.keys++;
            e.opaque = made;
        }
        let p = e.depth;
        if (p == null) {
            const made = pl.depthPipelineOf(mod, kind, ext);
            if (made.handle == 0) {
                e.refused = true;
                return null;
            }
            e.depth = made;
            p = made;
        }
        return p;
    }

    // The material part of the key of the frame's material `key` (-1: the
    // default material), worked out once per material and kept while the
    // materials array and the binder's generations are the same;
    // BITS_UNKNOWN for a key past the array.
    private materialBits(valuesGeneration: i32, liveGeneration: i32, f: RenderFrame, key: i64): u64 {
        if (key < 0) {
            let b = this.defaultBits;
            if (b == BITS_UNKNOWN) {
                b = <u64>this.bitsOfDesc(this.defaultDesc);
                this.defaultBits = b;
            }
            return b;
        }
        const mats = f.materials;
        if (this.bitsOf !== mats || this.bits.length != mats.length || this.bitsValues != valuesGeneration
            || this.bitsLive != liveGeneration) {
            this.bitsOf = mats;
            this.bitsValues = valuesGeneration;
            this.bitsLive = liveGeneration;
            const bits = this.bits;
            if (bits.length != mats.length) bits.length = mats.length;
            for (let i = 0; i < bits.length; i++) unchecked(bits[i] = BITS_UNKNOWN);
        }
        const i = <i32>key;
        if (i >= this.bits.length) return BITS_UNKNOWN;
        let b = unchecked(this.bits[i]);
        if (b == BITS_UNKNOWN) {
            b = <u64>this.bitsOfDesc(unchecked(mats[i]));
            unchecked(this.bits[i] = b);
        }
        return b;
    }

    // The material bits of `m`, from the uniform its group binds
    // (material.as materialUniform, and its extended block).
    private bitsOfDesc(m: MaterialDesc): u32 {
        const tex = textureBitsOf(m);
        const u = materialUniform(m, tex);
        if (!materialIsExt(m)) return materialVariantBits(u, null);
        const ext = materialExtUniformInto(m, tex, extLayersInto(m, this.layerScratch), this.extScratch);
        return materialVariantBits(u, ext);
    }

    // Every pipeline released (a renderer's pipelines remade: another MSAA
    // count or colour format); the modules are kept (their source's).
    release(): void {
        const all = this.entries.values();
        for (let i = 0; i < all.length; i++) all[i].releasePipelines();
        this.stats.keys = 0;
        this.madeWith = null;
    }
}
