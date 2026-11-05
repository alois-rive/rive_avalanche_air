// Milestone 67 (docs/engine/PERFORMANCE.md, "Pictures that change"): each
// item's DrawItem.artboards, the artboard textures its materials show (a
// bit each: the texture's ArtboardTexture.seenBit, which the scene's
// player gave it when it collected the tree's textures,
// ../player/artboards.as ArtboardTextures.collect, 1 << the texture's index
// then; the first 32), so that the renderer can say which ones a frame drew
// (FrameRenderer.artboardsDrawn) and an ArtboardTexture whose
// render_target_update_mode is when_visible is drawn again only while it
// is seen, as Godot's SubViewport is. Set when the frame is built (an item
// keeps its materials while the plan is refreshed in place); 0 for every
// item of a frame without artboard textures.
//
// The bit is the texture's own, not its index in the tree as it is now: a
// node holding an earlier texture removed (queue_free, removeChild) or one
// added before it would otherwise shift every later texture's bit away
// from the one the player tests, and a visible texture that changes would
// freeze while another was drawn out of view. A texture no player holds
// (one a script added after the player collected the tree's, or any in the
// tools, which run no player) carries 0.
//
// What carries a bit: every material of the frame (SceneFrame
// .materialResources, the frame's material keys) that holds an
// ArtboardTexture in a texture slot, an ArtboardSprite3D's own material
// among them (its texture is that material's albedo), and so every item
// drawing a range with that material, a next pass's item too. A Decal's
// textures are drawn into the decal atlas, not by an item: the player
// counts a texture a decal paints as always seen (it cannot tell).
//
// A frame whose materials hold no ArtboardTexture costs one loop over its
// materials and allocates nothing; one that holds some allocates the
// materials' bits (a full plan allocates anyway).

import { PBR_SLOT_COUNT } from "../../material/pbr";
import { ArtboardTexture, StandardMaterial3D } from "../resource/types";
import { SceneNode } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { SceneFrame } from "./adapter";

// The textures a bit can name: DrawItem.artboards is a u32.
export const ARTBOARD_BITS: i32 = 32;

export function markArtboardItems(tree: SceneTree, walked: Array<SceneNode>, sf: SceneFrame): void {
    const mats = sf.materialResources;
    let any = false;
    for (let k = 0; k < mats.length && !any; k++) any = holdsArtboard(unchecked(mats[k]));
    if (!any) return;
    const bits = new Array<u32>(mats.length);
    for (let k = 0; k < mats.length; k++) unchecked(bits[k] = materialBits(unchecked(mats[k])));
    const items = sf.frame.items;
    for (let i = 0; i < items.length; i++) {
        const item = unchecked(items[i]);
        let b: u32 = 0;
        const keys = item.materials;
        for (let r = 0; r < keys.length; r++) {
            const key = unchecked(keys[r]);
            if (key >= 0 && key < <i64>bits.length) b |= unchecked(bits[<i32>key]);
        }
        item.artboards = b;
    }
}

// The bit of texture `index` of the tree's artboard textures (0 past the
// first ARTBOARD_BITS).
export function artboardBit(index: i32): u32 {
    return index >= 0 && index < ARTBOARD_BITS ? (<u32>1) << <u32>index : 0;
}

function holdsArtboard(m: StandardMaterial3D): bool {
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const t = m.textureAt(slot);
        const isArtboard = t != null && t instanceof ArtboardTexture;
        if (isArtboard) return true;
    }
    return false;
}

// The bits of the artboard textures `m` holds (each texture's seenBit).
function materialBits(m: StandardMaterial3D): u32 {
    let b: u32 = 0;
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const t = m.textureAt(slot);
        const isArtboard = t != null && t instanceof ArtboardTexture;
        if (!isArtboard) continue;
        b |= (t as ArtboardTexture).seenBit;
    }
    return b;
}
