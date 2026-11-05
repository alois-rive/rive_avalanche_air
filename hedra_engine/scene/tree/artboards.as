// The ArtboardTextures a scene tree draws (milestone 15): every one that a
// material of a drawn mesh holds in any texture slot, found the way the
// adapter (../render/adapter.as) finds materials: a MeshInstance3D's
// material_override, then its mesh's materials (a built-in mesh's one, an
// ArrayMesh's surfaces'), a MultiMeshInstance3D's mesh's; a material file
// (.mtlx) loads as the StandardMaterial3D those hold. Models (.modeler,
// glTF) never hold one. Milestone 16: an ArtboardSprite3D's `texture` too,
// which the adapter draws as the albedo of the sprite's own material
// (../render/sprites.as), so it counts as a base colour slot. Each texture once, in the order first met walking
// the tree depth first from the root (children in order), and within a
// material in slot order (PbrSlot). Milestone 33: a Decal's textures too,
// in its slot order (albedo, normal, ORM, emission), where the walk meets
// the Decal: the renderer draws them into its decal atlas, live as a
// material's are (../render/decals.as, hedra_engine/render/gpu/decals.as).
// Milestone 35: a CPUParticles3D's mesh's materials too, as a MultiMesh's
// (the adapter draws its mesh with them: ../render/particles.as).
//
// What uses it: the warnings (../warnings.as: each texture's
// artboardTextureProblems), `inspect`, the player of built projects
// (../player/artboards.as) and the CLI's `build` (which artboards to copy
// into the project, and which state machine each runs).
//
// Hidden nodes count: a script may show them in a built project.
//
// A sky's panorama (WorldEnvironment -> Environment -> Sky ->
// PanoramaSkyMaterial.panorama) may hold an ArtboardTexture too, but it is
// never live: the renderer reads a panorama's texels on the CPU once, so
// it draws the placeholder everywhere. Those are panoramaArtboardTextures,
// apart, for the warnings only: the build copies no artboard for them, and
// the player plays none.

import { PBR_SLOT_COUNT, PbrSlot } from "../../material/pbr";
import { ArrayMesh, ArtboardTexture, Mesh, PanoramaSkyMaterial, StandardMaterial3D, Texture2D } from "../resource/types";
import { slotEnabled } from "../resource/pbr_map";
import { PrimitiveMesh } from "../resource/primitives";
import { DECAL_TEXTURES, DECAL_TEXTURE_ALBEDO, DECAL_TEXTURE_EMISSION, DECAL_TEXTURE_NORMAL, decalSlotIsSrgb }
    from "../../render/decal";
import {
    ArtboardSprite3D, CPUParticles3D, Decal, MeshInstance3D, MultiMeshInstance3D, SceneNode, WorldEnvironment,
} from "./node";
import { SceneTree } from "./tree";

export function artboardTexturesOf(tree: SceneTree): Array<ArtboardTexture> {
    const out = new Array<ArtboardTexture>();
    const seen = new Set<StandardMaterial3D>();
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        // (Each test is a bool first: as the adapter does, so the class
        // check is made at run time.)
        const isMesh = n instanceof MeshInstance3D;
        const isMulti = n instanceof MultiMeshInstance3D;
        const isSprite = n instanceof ArtboardSprite3D;
        const isDecal = n instanceof Decal;
        const isParticles = n instanceof CPUParticles3D;
        if (isMesh) {
            const mi = n as MeshInstance3D;
            fromMaterial(mi.materialOverride, seen, out);
            fromMesh(mi.mesh, seen, out);
        } else if (isMulti) {
            const mm = (n as MultiMeshInstance3D).multimesh;
            if (mm != null) fromMesh(mm.mesh, seen, out);
        } else if (isParticles) {
            fromMesh((n as CPUParticles3D).mesh, seen, out);
        } else if (isSprite) {
            const t = (n as ArtboardSprite3D).texture;
            if (t != null && !out.includes(t)) out.push(t);
        } else if (isDecal) {
            fromDecal(n as Decal, out);
        }
    }
    return out;
}

// A Decal's ArtboardTextures, in its slot order (DECAL_TEXTURE_*).
function fromDecal(d: Decal, out: Array<ArtboardTexture>): void {
    for (let slot = 0; slot < DECAL_TEXTURES; slot++) {
        const t = d.textureAt(slot);
        if (t == null) continue;
        const isArtboard = t instanceof ArtboardTexture;
        if (!isArtboard) continue;
        const a = t as ArtboardTexture;
        if (!out.includes(a)) out.push(a);
    }
}

// A mesh's materials: a built-in mesh's one (without generating its
// triangles), an ArrayMesh's surfaces'.
function fromMesh(mesh: Mesh?, seen: Set<StandardMaterial3D>, out: Array<ArtboardTexture>): void {
    if (mesh == null) return;
    const isPrimitive = mesh instanceof PrimitiveMesh;
    const isArray = mesh instanceof ArrayMesh;
    if (isPrimitive) {
        fromMaterial((mesh as PrimitiveMesh).material, seen, out);
    } else if (isArray) {
        const surfaces = (mesh as ArrayMesh).surfaces;
        for (let k = 0; k < surfaces.length; k++) fromMaterial(surfaces[k].material, seen, out);
    }
}

function fromMaterial(m: StandardMaterial3D?, seen: Set<StandardMaterial3D>, out: Array<ArtboardTexture>): void {
    if (m == null || seen.has(m)) return;
    seen.add(m);
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const t = m.textureAt(slot);
        if (t == null) continue;
        const isArtboard = t instanceof ArtboardTexture;
        if (!isArtboard) continue;
        const a = t as ArtboardTexture;
        if (!out.includes(a)) out.push(a);
    }
}

// The ArtboardTextures `tree`'s skies hold as their panorama (see the
// header), each once, in tree order; none that a material holds too
// (artboardTexturesOf lists those).
export function panoramaArtboardTextures(tree: SceneTree): Array<ArtboardTexture> {
    const out = new Array<ArtboardTexture>();
    const materials = artboardTexturesOf(tree);
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        const isEnv = n instanceof WorldEnvironment;
        if (!isEnv) continue;
        const env = (n as WorldEnvironment).environment;
        if (env == null) continue;
        const sky = env.sky;
        if (sky == null) continue;
        const m = sky.skyMaterial;
        if (m == null) continue;
        // (By name, as render/lights.as tells the two sky materials apart.)
        if (m.className() != "PanoramaSkyMaterial") continue;
        const t = (m as PanoramaSkyMaterial).panorama;
        if (t == null) continue;
        const isArtboard = t instanceof ArtboardTexture;
        if (!isArtboard) continue;
        const a = t as ArtboardTexture;
        if (!out.includes(a) && !materials.includes(a)) out.push(a);
    }
    return out;
}

// Where an ArtboardTexture is used in a tree's materials (artboardSlotsOf).
export class ArtboardSlots {
    // The PbrSlots that hold it in the tree's drawn materials, each once,
    // in slot order.
    slots: Array<i32> = [];
    // Those the renderer binds as one of its five textures, by form: base
    // colour or emission (colour), normal, metallic-roughness or occlusion
    // (data).
    colour: bool = false;
    data: bool = false;
    // The first slot holding it that the renderer composes on the CPU (an
    // extension slot, or roughness beside another metallic texture), -1
    // for none: there it draws its placeholder.
    extension: i32 = -1;

    // Whether it is drawn live anywhere.
    live(): bool {
        return this.colour || this.data;
    }
}

// Milestone 34: any Texture2D, not only an ArtboardTexture: a
// ViewportTexture's slots are counted the same way (its viewport's colour
// and data targets: ../render/viewports.as).
// Where `t` is used by the materials of the meshes `tree` draws (the walk
// of artboardTexturesOf: material_override, else the mesh's materials;
// MultiMesh meshes and a CPUParticles3D's; a sprite's texture, its
// material's albedo; a Decal's slots), as the renderer binds them (../player/artboards.as's header).
// A Decal's albedo or emission is a colour layer of the decal atlas (the
// colour target, recorded as PbrSlot.BaseColor and Emissive), its normal
// or ORM a data layer (the data target, recorded as PbrSlot.Normal and
// Occlusion): the atlas blits a live colour or data view as the binder
// holds it (MaterialBinder.setLive), so the player's targets serve
// materials and decals alike.
export function artboardSlotsOf(tree: SceneTree, t: Texture2D): ArtboardSlots {
    const out = new ArtboardSlots();
    const seen = new Set<StandardMaterial3D>();
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        // (A bool first: `if (x instanceof C)` is folded to false.)
        const isMesh = n instanceof MeshInstance3D;
        const isMulti = n instanceof MultiMeshInstance3D;
        const isSprite = n instanceof ArtboardSprite3D;
        const isDecal = n instanceof Decal;
        const isParticles = n instanceof CPUParticles3D;
        if (isDecal) {
            slotsOfDecal(n as Decal, t, out);
        } else if (isSprite) {
            // The sprite's material holds it as albedo_texture alone.
            const st: Texture2D? = (n as ArtboardSprite3D).texture;
            if (st === t) {
                if (!out.slots.includes(PbrSlot.BaseColor)) out.slots.push(PbrSlot.BaseColor);
                out.colour = true;
            }
        } else if (isMesh) {
            const mi = n as MeshInstance3D;
            // An override hides the mesh's own materials: the adapter
            // draws it alone.
            if (mi.materialOverride != null) slotsOfMaterial(mi.materialOverride, t, seen, out);
            else slotsOfMesh(mi.mesh, t, seen, out);
        } else if (isMulti) {
            const mm = (n as MultiMeshInstance3D).multimesh;
            if (mm != null) slotsOfMesh(mm.mesh, t, seen, out);
        } else if (isParticles) {
            slotsOfMesh((n as CPUParticles3D).mesh, t, seen, out);
        }
    }
    // In slot order, each once.
    out.slots.sort();
    return out;
}

// Where `t` is used by material `m` alone (a material file loaded by
// itself), as artboardSlotsOf counts a tree's.
export function artboardSlotsOfMaterial(m: StandardMaterial3D, t: Texture2D): ArtboardSlots {
    const out = new ArtboardSlots();
    slotsOfMaterial(m, t, new Set<StandardMaterial3D>(), out);
    out.slots.sort();
    return out;
}

// Where `t` is used by Decal `d`: its slots as PbrSlots, colour or data.
function slotsOfDecal(d: Decal, t: Texture2D, out: ArtboardSlots): void {
    for (let slot = 0; slot < DECAL_TEXTURES; slot++) {
        if (d.textureAt(slot) !== t) continue;
        const pbr = slot == DECAL_TEXTURE_ALBEDO ? PbrSlot.BaseColor
            : slot == DECAL_TEXTURE_NORMAL ? PbrSlot.Normal
            : slot == DECAL_TEXTURE_EMISSION ? PbrSlot.Emissive : PbrSlot.Occlusion;
        if (!out.slots.includes(pbr)) out.slots.push(pbr);
        if (decalSlotIsSrgb(slot)) out.colour = true;
        else out.data = true;
    }
}

function slotsOfMesh(mesh: Mesh?, t: Texture2D, seen: Set<StandardMaterial3D>, out: ArtboardSlots): void {
    if (mesh == null) return;
    const isPrimitive = mesh instanceof PrimitiveMesh;
    const isArray = mesh instanceof ArrayMesh;
    if (isPrimitive) {
        slotsOfMaterial((mesh as PrimitiveMesh).material, t, seen, out);
    } else if (isArray) {
        const surfaces = (mesh as ArrayMesh).surfaces;
        for (let k = 0; k < surfaces.length; k++) slotsOfMaterial(surfaces[k].material, t, seen, out);
    }
}

function slotsOfMaterial(m: StandardMaterial3D?, t: Texture2D, seen: Set<StandardMaterial3D>,
    out: ArtboardSlots): void {
    if (m == null || seen.has(m)) return;
    seen.add(m);
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        if (m.textureAt(slot) !== t) continue;
        if (!out.slots.includes(slot)) out.slots.push(slot);
        const form = slotForm(m, slot);
        if (form == FORM_COLOUR) out.colour = true;
        else if (form == FORM_DATA) out.data = true;
        else if (form == FORM_EXTENSION && out.extension < 0) out.extension = slot;
    }
}

const FORM_NONE: i32 = 0;
const FORM_COLOUR: i32 = 1;
const FORM_DATA: i32 = 2;
const FORM_EXTENSION: i32 = 3;

// How the renderer draws `m`'s texture in `slot` (materials.as
// materialDesc's rules): not at all (a switch is off), as a colour or data
// binding, or composed on the CPU.
function slotForm(m: StandardMaterial3D, slot: i32): i32 {
    switch (slot) {
        case PbrSlot.BaseColor: return FORM_COLOUR;
        case PbrSlot.Emissive: return m.emissionEnabled ? FORM_COLOUR : FORM_NONE;
        case PbrSlot.Normal: return m.normalEnabled ? FORM_DATA : FORM_NONE;
        case PbrSlot.Occlusion: return m.aoEnabled ? FORM_DATA : FORM_NONE;
        case PbrSlot.Metallic: return FORM_DATA;
        case PbrSlot.Roughness: {
            const mt = m.metallicTexture;
            const rt = m.roughnessTexture;
            // Alone, or the same image as metallic: the one binding. Packed
            // beside another metallic image: not drawn (materialDesc draws
            // the metallic one). Beside another, unpacked: its own layer.
            if (mt == null || mt === rt) return FORM_DATA;
            return m.packedMetallicRoughness ? FORM_NONE : FORM_EXTENSION;
        }
        // An extension slot whose feature is off is never drawn.
        default: return slotEnabled(m, slot) ? FORM_EXTENSION : FORM_NONE;
    }
}
