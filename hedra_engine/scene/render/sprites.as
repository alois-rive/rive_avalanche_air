// How the adapter (adapter.as) draws an ArtboardSprite3D (milestone 16):
// as one DrawItem of a shared unit quad (`spriteQuad`) placed by
// billboard.as, with a material made for the sprite (`spriteMaterial`)
// whose albedo is the sprite's ArtboardTexture. So everything milestone 15
// built for a material's artboard texture serves a sprite unchanged: the
// placeholder in the tools, the CLI's `build`'s copy of the artboard, and
// the player's live view, which the material binder binds by the
// texture's path (../player/artboards.as).
//
// A sprite is drawn when it is visible in the tree, has a texture and a
// non-empty rectangle (billboard.as spriteRect). Its item records the
// sprite node (SceneFrame.itemNodes), so picking, the selection outline
// and the editor's gizmo treat it as any other node's item.
//
// The material (Godot's SpriteBase3D material, as StandardMaterial3D
// fields): albedo_texture the texture; albedo_color `modulate`;
// shading_mode per_pixel when `shaded`, else unshaded (unlit); roughness
// 1, metallic 0; cull_mode disabled when `double_sided`, else back;
// transparency from `alpha_cut` and `transparent`: disabled -> alpha
// (blended) when transparent, else disabled (opaque); discard ->
// alpha_scissor at alpha_scissor_threshold; opaque_prepass -> alpha
// (Godot's depth prepass is not drawn); alpha_hash -> alpha_scissor at 0.5
// (Godot's dither is not drawn). resource_name is the node's path, so
// warnings name the sprite.
//
// Turning to the camera. A sprite's world matrix depends on the camera
// (its billboard, and whether a one-sided sprite is seen from behind), and
// nothing else in a frame does. So the adapter keeps a SpriteItem per
// sprite (SceneFrame.sprites) and `orientSprites` sets each item's world,
// normal matrix and `mirrored` for the frame's camera as it is: once the
// frame's camera is known in buildSceneFrame, and again in every
// retargetSceneFrame (the preview's and the editor's moving frames, which
// must allocate nothing). A one-sided sprite seen from behind is not in
// the picture: its item becomes CAST_SHADOW_SHADOWS_ONLY when the sprite
// casts a shadow (it still does, as the shadow pass culls no face), else
// its mesh is set to null (drawn in no pass, never picked), and both are
// put back when it faces the camera again. A billboard's item is boxed
// by billboard.as billboardRadius about the node's origin, so its bounds
// do not depend on the camera; a sprite that is not a billboard is boxed
// by its quad as placed. Shadow maps see each sprite as the main camera
// turned it (Godot turns billboards to the light there).
//
// The quad's UVs. The renderer's UV origin is bottom-left (surface.wgsl's
// `tex_uv` flips to image rows) and an ArrayMesh's is top-left (Godot's;
// meshes.as `uvAt` flips it back), so the quads below store (u, 1 - v)
// for the renderer's (u, v) = (x, y): the texture's top-left texel lands
// on the quad's top-left corner seen from the front.
//
// `normalInto` lives here: the adapter's normal matrix, which every item's
// world matrix, a sprite's included, is given number for number alike.

import { Mat4, Vec4 } from "../../base/vecmath";
import { CAST_SHADOW_OFF, CAST_SHADOW_SHADOWS_ONLY, DrawItem, RenderFrame } from "../../render/frame";
import { GpuMesh } from "../../render/mesh";
import { SCENE_TO_MODEL, modelToScene } from "../space";
import { ArrayMesh, MeshSurface, StandardMaterial3D } from "../resource/types";
import { ArtboardSprite3D } from "../tree/node";
import {
    billboardTransform, cameraToWorld, mulMat4, spriteFacesCamera, spritePlacement, spriteRect,
} from "./billboard";

// One sprite's item in a frame, as `orientSprites` turns it.
export class SpriteItem {
    // Its index in frame.items.
    item: i32;
    node: ArtboardSprite3D;
    // The node's global transform (scene space) when the frame was built.
    global: Mat4;
    // billboard.as spritePlacement of the node's rectangle and axis.
    placement: Mat4;
    // The node's billboard (billboard.as BILLBOARD_*) and double_sided.
    billboard: i32;
    doubleSided: bool;
    // The item's castShadow and mesh as built, which a sprite seen from
    // behind gives up and gets back (the header).
    castShadow: u32;
    mesh: GpuMesh?;

    constructor(item: i32, node: ArtboardSprite3D, global: Mat4, placement: Mat4, castShadow: u32,
        mesh: GpuMesh?) {
        this.item = item;
        this.node = node;
        this.global = global;
        this.placement = placement;
        this.billboard = node.billboard;
        this.doubleSided = node.doubleSided;
        this.castShadow = castShadow;
        this.mesh = mesh;
    }
}

// StandardMaterial3D.transparency and cull_mode values the material uses.
const TRANSPARENCY_DISABLED: i32 = 0;
const TRANSPARENCY_ALPHA: i32 = 1;
const TRANSPARENCY_SCISSOR: i32 = 2;
const CULL_BACK: i32 = 0;
const CULL_DISABLED: i32 = 2;

// ArtboardSprite3D.alpha_cut.
const ALPHA_CUT_DISCARD: i32 = 1;
const ALPHA_CUT_OPAQUE_PREPASS: i32 = 2;
const ALPHA_CUT_HASH: i32 = 3;

// The material the sprite draws with (the header), made afresh from the
// node's fields; null when it has no texture.
export function spriteMaterial(s: ArtboardSprite3D): StandardMaterial3D? {
    const t = s.texture;
    if (t == null) return null;
    const m = new StandardMaterial3D();
    m.name = s.path();
    spriteMaterialInto(m, s);
    return m;
}

// spriteMaterial's fields written into `m`, but its name
// (milestone 50: a frame refreshed in place keeps the sprite's material,
// adapter.as refreshSceneFrame).
export function spriteMaterialInto(m: StandardMaterial3D, s: ArtboardSprite3D): void {
    m.albedoTexture = s.texture;
    m.albedoColor = s.modulate;
    m.shadingMode = s.shaded ? 1 : 0;
    m.metallic = 0;
    m.roughness = 1;
    m.cullMode = s.doubleSided ? CULL_DISABLED : CULL_BACK;
    m.alphaScissorThreshold = 0.5;
    const cut = s.alphaCut;
    if (cut == ALPHA_CUT_DISCARD) {
        m.transparency = TRANSPARENCY_SCISSOR;
        m.alphaScissorThreshold = s.alphaScissorThreshold;
    } else if (cut == ALPHA_CUT_OPAQUE_PREPASS) {
        // Godot draws the opaque part first into the depth buffer; here it
        // is blended alone.
        m.transparency = TRANSPARENCY_ALPHA;
    } else if (cut == ALPHA_CUT_HASH) {
        // Godot dithers; here it is cut at one half.
        m.transparency = TRANSPARENCY_SCISSOR;
        m.alphaScissorThreshold = 0.5;
    } else {
        m.transparency = s.transparent ? TRANSPARENCY_ALPHA : TRANSPARENCY_DISABLED;
    }
}

// The four quads, by flipH + 2 * flipV, made on first use.
const QUADS: Array<ArrayMesh?> = [null, null, null, null];

// One of four unit quads (billboard.as's header), shared by every sprite
// and made on first use: flipped left to right (its U is 1 - x), top to
// bottom (its V is 1 - y), both or neither. One surface, no material (the
// sprite's is drawn as an override).
export function spriteQuad(flipH: bool, flipV: bool): ArrayMesh {
    const k = (flipH ? 1 : 0) + (flipV ? 2 : 0);
    const have = QUADS[k];
    if (have != null) return have;
    const s = new MeshSurface();
    // Counter-clockwise seen from +Z: (0, 0), (1, 0), (1, 1), (0, 1).
    const xs: StaticArray<f32> = [0, 1, 1, 0];
    const ys: StaticArray<f32> = [0, 0, 1, 1];
    for (let i = 0; i < 4; i++) {
        const x = xs[i];
        const y = ys[i];
        s.positions.push(x);
        s.positions.push(y);
        s.positions.push(0);
        s.normals.push(0);
        s.normals.push(0);
        s.normals.push(1);
        const u = flipH ? <f32>1 - x : x;
        const v = flipV ? <f32>1 - y : y;
        // (top-left origin in the mesh: the header)
        s.uvs.push(u);
        s.uvs.push(<f32>1 - v);
    }
    const tris: StaticArray<u32> = [0, 1, 2, 0, 2, 3];
    for (let i = 0; i < tris.length; i++) s.indices.push(tris[i]);
    const m = new ArrayMesh();
    m.surfaces.push(s);
    m.computeBounds();
    QUADS[k] = m;
    return m;
}

// billboard.as spritePlacement of the node's texture size, pixel_size,
// centered, offset and axis; a sprite without a texture has an empty
// rectangle, so its quad has no area (the adapter draws no such sprite).
export function spritePlacementOf(s: ArtboardSprite3D): Mat4 {
    const t = s.texture;
    const w = t != null ? t.width : 0;
    const h = t != null ? t.height : 0;
    return spritePlacement(spriteRect(w, h, s.pixelSize, s.centered, s.offset), s.axis);
}

// Sets `item.normal`, the inverse-transpose of world's 3x3, and returns
// world's determinant. Mat3's `inverse()` is the transpose of the rows
// (y x z, z x x, x x y) over the determinant (z . (x x y)), so its
// transpose is those rows, number for number: worked out here in scalars
// without the two transposes. (The adapter's, for every item.)
export function normalInto(world: Mat4, item: DrawItem): f32 {
    const x = world.xAxis;
    const y = world.yAxis;
    const z = world.zAxis;
    // Vec3.cross: (a.y b.z - a.z b.y, a.z b.x - a.x b.z, a.x b.y - a.y b.x).
    const c0x = y.y * z.z - y.z * z.y;
    const c0y = y.z * z.x - y.x * z.z;
    const c0z = y.x * z.y - y.y * z.x;
    const c1x = z.y * x.z - z.z * x.y;
    const c1y = z.z * x.x - z.x * x.z;
    const c1z = z.x * x.y - z.y * x.x;
    const c2x = x.y * y.z - x.z * y.y;
    const c2y = x.z * y.x - x.x * y.z;
    const c2z = x.x * y.y - x.y * y.x;
    // Vec3.dot: x * x + y * y + z * z.
    const det = z.x * c2x + z.y * c2y + z.z * c2z;
    const inv = <f32>1.0 / det;
    item.normal = Mat4(Vec4(c0x * inv, c0y * inv, c0z * inv, 0), Vec4(c1x * inv, c1y * inv, c1z * inv, 0),
        Vec4(c2x * inv, c2y * inv, c2z * inv, 0), Vec4(0, 0, 0, 1));
    return det;
}

// Sets each sprite item of `frame` for frame.camera (the header).
// Allocates nothing: every value here is a struct.
export function orientSprites(frame: RenderFrame, sprites: Array<SpriteItem>): void {
    const n = sprites.length;
    if (n == 0) return;
    const c = frame.camera;
    // Render space is Z up, a sprite's turn is worked out in scene space.
    const cam = cameraToWorld(modelToScene(c.eye), modelToScene(c.target), modelToScene(c.up));
    const ortho = c.isOrtho();
    const items = frame.items;
    for (let i = 0; i < n; i++) {
        const sp = unchecked(sprites[i]);
        if (sp.item < 0 || sp.item >= items.length) continue;
        const d = unchecked(items[sp.item]);
        const w = mulMat4(billboardTransform(sp.global, sp.billboard, cam), sp.placement);
        const world = mulMat4(SCENE_TO_MODEL, w);
        d.world = world;
        d.mirrored = normalInto(world, d) < 0;
        if (sp.doubleSided || spriteFacesCamera(w, cam, ortho)) {
            d.castShadow = sp.castShadow;
            d.mesh = sp.mesh;
        } else if (sp.castShadow != CAST_SHADOW_OFF) {
            // Seen from behind but casting: in the shadow maps only.
            d.castShadow = CAST_SHADOW_SHADOWS_ONLY;
            d.mesh = sp.mesh;
        } else {
            d.castShadow = sp.castShadow;
            d.mesh = null;
        }
    }
}
