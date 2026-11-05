// The geometry of an ArtboardSprite3D (milestone 16): where its quad lies
// in the node's space, Godot 4's billboard turn, and which side of it a
// camera sees. Pure maths on vecmath's structs: nothing here allocates,
// so the adapter can turn every sprite to the camera on each moving frame
// (sprites.as `orientSprites`, from adapter.as `retargetSceneFrame`).
//
// Everything is in scene space (Y up, ../space.as); the adapter converts
// the frame's camera (render space, Z up) with modelToScene first and the
// result with SCENE_TO_MODEL after.
//
// The quad. A unit quad, 0..1 on X and Y, facing +Z, its UV (x, y) at
// (x, y) (UV origin bottom-left, as every mesh of the renderer: the
// texture's top-left texel is at the quad's top-left corner). Godot's
// SpriteBase3D lays the texture's rectangle out in pixels: size (w, h),
// position `offset` minus (w, h) / 2 when `centered`, y up; times
// `pixel_size` that is the rectangle in metres (`spriteRect`). On `axis`
// Z the rectangle's x is the node's +X and its y +Y; on Y, +X and +Z; on
// X, +Z and +Y; the quad faces +axis (`spritePlacement`, which maps the
// unit quad onto the rectangle, the quad's Z onto the unit axis).
//
// The billboard (Godot's BaseMaterial3D billboard modes, as its shader
// computes MODELVIEW_MATRIX): with C the camera's world matrix (columns
// right, up, back, eye: `cameraToWorld`) and s the lengths of the node's
// global basis columns,
//   enabled  basis = (C.right * s.x, C.up * s.y, C.back * s.z): the quad
//            lies in the camera's plane, upright on the screen;
//   fixed_y  basis = (normalize(cross(Y, C.back)) * s.x, Y * s.y,
//            normalize(cross(C.right, Y)) * s.z), Y the scene's up: the
//            quad turns about the scene's Y axis only;
//   disabled the node's global transform as it is;
// the origin is always the node's. When a cross product is shorter than
// 1e-6 (fixed_y seen from straight above or below) the other axis is
// made from the one that is not: x = normalize(cross(Y, z)) or
// z = normalize(cross(x, Y)), and +X when both are.
//
// Godot loses the sign of a scale in a billboard (it takes each column's
// length), so a mirrored billboard is drawn unmirrored, as there.
//
// `mulMat4` lives here too: the adapter's product of two matrices in
// scalars, which sprites.as needs number for number the same.

import { Mat4, Vec2, Vec3, Vec4 } from "../../base/vecmath";

// ArtboardSprite3D.billboard.
export const BILLBOARD_DISABLED: i32 = 0;
export const BILLBOARD_ENABLED: i32 = 1;
export const BILLBOARD_FIXED_Y: i32 = 2;

// ArtboardSprite3D.axis.
export const SPRITE_AXIS_X: i32 = 0;
export const SPRITE_AXIS_Y: i32 = 1;
export const SPRITE_AXIS_Z: i32 = 2;

// A cross product shorter than this is taken as no direction (fixed_y).
const DEGENERATE: f32 = 1e-6;

// The scene's up (fixed_y turns about it).
const UP: Vec3 = Vec3(0, 1, 0);

// The sprite's rectangle in its own plane, in metres: (x, y) its
// bottom-left corner, (z, w) its width and height. `texW` x `texH` is the
// texture's size in pixels (ArtboardTexture.width, height); a size or a
// pixel_size of 0 or less gives an empty rectangle (0, 0, 0, 0). Worked
// out in pixels and scaled last, as Godot does.
export function spriteRect(texW: i32, texH: i32, pixelSize: f32, centered: bool, offset: Vec2): Vec4 {
    // (`!(a > 0)` so that a NaN pixel_size is empty too)
    if (texW <= 0 || texH <= 0 || !(pixelSize > 0)) return Vec4(0, 0, 0, 0);
    const w = <f32>texW;
    const h = <f32>texH;
    let x = offset.x;
    let y = offset.y;
    if (centered) {
        x -= w * <f32>0.5;
        y -= h * <f32>0.5;
    }
    return Vec4(x * pixelSize, y * pixelSize, w * pixelSize, h * pixelSize);
}

// The matrix that maps the unit quad onto `rect` (spriteRect) on `axis`
// (SPRITE_AXIS_*; any other value is Z), in the node's space: its X column
// is the rectangle's x direction times its width, its Y column the y
// direction times its height, its Z column the unit axis, its origin the
// rectangle's corner. Its determinant is negative on axes X and Y (the
// quad's winding is mirrored there: the adapter's `mirrored` handles it).
export function spritePlacement(rect: Vec4, axis: i32): Mat4 {
    const x = rect.x;
    const y = rect.y;
    const w = rect.z;
    const h = rect.w;
    if (axis == SPRITE_AXIS_X) {
        // x along +Z, y along +Y, facing +X.
        return Mat4(Vec4(0, 0, w, 0), Vec4(0, h, 0, 0), Vec4(1, 0, 0, 0), Vec4(0, y, x, 1));
    }
    if (axis == SPRITE_AXIS_Y) {
        // x along +X, y along +Z, facing +Y.
        return Mat4(Vec4(w, 0, 0, 0), Vec4(0, 0, h, 0), Vec4(0, 1, 0, 0), Vec4(x, 0, y, 1));
    }
    return Mat4(Vec4(w, 0, 0, 0), Vec4(0, h, 0, 0), Vec4(0, 0, 1, 0), Vec4(x, y, 0, 1));
}

// The world matrix of a camera at `eye` looking at `target` with `up`
// (one space, scene space here): columns right, up, back (unit,
// right-handed) and the eye, the inverse of camera.lookAtMat4Rh's view
// matrix, with the same axes (worked out as it works them out). An `up`
// along the view, which lookAtMat4Rh cannot take, gives the right +X
// rather than NaN, so a sprite stays finite.
export function cameraToWorld(eye: Vec3, target: Vec3, up: Vec3): Mat4 {
    const f = (target - eye).normalize();
    let s = f.cross(up);
    if (s.length() < DEGENERATE) s = Vec3(1, 0, 0);
    else s = s.normalize();
    const u = s.cross(f);
    return Mat4(Vec4(s.x, s.y, s.z, 0), Vec4(u.x, u.y, u.z, 0), Vec4(-f.x, -f.y, -f.z, 0),
        Vec4(eye.x, eye.y, eye.z, 1));
}

// The node's global transform `global` turned as billboard mode `mode`
// says (the header) for a camera whose world matrix is `cam`
// (cameraToWorld). BILLBOARD_DISABLED, or any unknown mode, returns
// `global` as it is.
export function billboardTransform(global: Mat4, mode: i32, cam: Mat4): Mat4 {
    if (mode != BILLBOARD_ENABLED && mode != BILLBOARD_FIXED_Y) return global;
    const sx = global.xAxis.xyz().length();
    const sy = global.yAxis.xyz().length();
    const sz = global.zAxis.xyz().length();
    const right = cam.xAxis.xyz();
    const back = cam.zAxis.xyz();
    let x: Vec3;
    let y: Vec3;
    let z: Vec3;
    if (mode == BILLBOARD_ENABLED) {
        x = right;
        y = cam.yAxis.xyz();
        z = back;
    } else {
        // Turned about the scene's Y only: x across the view, z towards
        // the camera, both horizontal.
        const cx = UP.cross(back);
        const cz = right.cross(UP);
        const lx = cx.length();
        const lz = cz.length();
        if (lx >= DEGENERATE && lz >= DEGENERATE) {
            x = cx / lx;
            z = cz / lz;
        } else if (lz >= DEGENERATE) {
            // Looking straight down or up: back is along Y, right is not.
            z = cz / lz;
            x = UP.cross(z).normalize();
        } else if (lx >= DEGENERATE) {
            x = cx / lx;
            z = x.cross(UP).normalize();
        } else {
            x = Vec3(1, 0, 0);
            z = x.cross(UP).normalize();
        }
        y = UP;
    }
    const o = global.wAxis;
    return Mat4(Vec4(x.x * sx, x.y * sx, x.z * sx, 0), Vec4(y.x * sy, y.y * sy, y.z * sy, 0),
        Vec4(z.x * sz, z.y * sz, z.z * sz, 0), o);
}

// Whether the camera `cam` (cameraToWorld) sees the front of a quad placed
// by `world` (the billboard transform times spritePlacement): the front is
// the side the quad's +Z points to after `world`, that is
// cross(world.x, world.y) / det(world's 3 x 3) (the inverse-transpose's
// image of +Z, so a mirrored placement keeps its axis's side). Seen from
// the quad's centre: perspective, the eye on that side
// (dot(n, eye - centre) >= 0); orthographic, the camera looking against it
// (dot(n, cam.back) >= 0). Edge-on counts as seen, and so does a quad
// flattened to nothing (a zero determinant).
export function spriteFacesCamera(world: Mat4, cam: Mat4, orthographic: bool): bool {
    const x = world.xAxis.xyz();
    const y = world.yAxis.xyz();
    const c = x.cross(y);
    const det = world.zAxis.xyz().dot(c);
    if (det == 0 || !isFinite<f32>(det)) return true;
    const n = c / det;
    if (orthographic) return n.dot(cam.zAxis.xyz()) >= 0;
    const centre = world.wAxis.xyz() + x * <f32>0.5 + y * <f32>0.5;
    return n.dot(cam.wAxis.xyz() - centre) >= 0;
}

// The radius of a sphere about the node's origin that holds the quad
// under any billboard turn: the farthest corner of `placement` from the
// origin, times the longest column of `global`'s basis. The adapter boxes
// a billboard's item with it, so its bounds (culling, framing) do not
// depend on the camera.
export function billboardRadius(global: Mat4, placement: Mat4): f32 {
    const o = placement.wAxis.xyz();
    const a = placement.xAxis.xyz();
    const b = placement.yAxis.xyz();
    const far = Mathf.max(Mathf.max(o.length(), (o + a).length()), Mathf.max((o + b).length(), (o + a + b).length()));
    const s = Mathf.max(Mathf.max(global.xAxis.xyz().length(), global.yAxis.xyz().length()), global.zAxis.xyz().length());
    return far * s;
}

// `a * b`, number for number (Mat4's operator: each column of b through
// mulVec4, the terms summed x, y, z, w), in scalars: a plan multiplies
// once an item, and the struct temporaries cost more than the sums.
export function mulMat4(a: Mat4, b: Mat4): Mat4 {
    return Mat4(mulCol(a, b.xAxis), mulCol(a, b.yAxis), mulCol(a, b.zAxis), mulCol(a, b.wAxis));
}

function mulCol(a: Mat4, v: Vec4): Vec4 {
    const x = a.xAxis;
    const y = a.yAxis;
    const z = a.zAxis;
    const w = a.wAxis;
    return Vec4(
        x.x * v.x + y.x * v.y + z.x * v.z + w.x * v.w,
        x.y * v.x + y.y * v.y + z.y * v.z + w.y * v.w,
        x.z * v.x + y.z * v.y + z.z * v.z + w.z * v.w,
        x.w * v.x + y.w * v.y + z.w * v.z + w.w * v.w,
    );
}
