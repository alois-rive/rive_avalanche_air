// The ray through a point of a picture (milestone 31: moved here from the
// tools' engine/src/authoring/render/pick.as, which re-exports it, so that the run
// time casts the pointer's ray into a scene's collision shapes as the
// editor picks: engine/src/scene/runtime/scene_runtime.as SceneInstance.pickRay).
//
// Points are in the picture's pixels before SSAA, origin at the top-left,
// y down; pixel centres are at +0.5.

import { VEC3_ZERO, Vec3 } from "../base/vecmath";
import { Camera } from "./camera";

// A ray in world space: `dir` is a unit vector.
export class Ray {
    origin: Vec3;
    dir: Vec3;

    constructor(origin: Vec3, dir: Vec3) {
        this.origin = origin;
        this.dir = dir;
    }
}

// The world-space ray of `camera` through the point (x, y) of a `width` x
// `height` picture: from the near plane, towards the far one (parallel rays
// for an orthographic camera).
//
// The point is unprojected through the inverse of the frame's own
// view-projection, so the ray is the one the picture was drawn with.
// Camera.projectionMatrix is WebGPU's clip space: depth 0 on the near plane
// and 1 on the far one (perspectiveRhDirectx / orthographicRhDirectx), y up,
// so the pixel's y is turned over and the two planes are z = 0 and z = 1.
export function pixelRay(camera: Camera, width: u32, height: u32, x: f32, y: f32): Ray {
    const r = new Ray(VEC3_ZERO, VEC3_ZERO);
    pixelRayInto(camera, width, height, x, y, r);
    return r;
}

// pixelRay into a kept Ray (allocates nothing: the pointer's ray each
// event, the editor's hover).
export function pixelRayInto(camera: Camera, width: u32, height: u32, x: f32, y: f32, out: Ray): void {
    const w = <f32>max<u32>(width, 1);
    const h = <f32>max<u32>(height, 1);
    const inv = camera.viewProj(w / h).inverse();
    const nx = x / w * <f32>2.0 - <f32>1.0;
    const ny = <f32>1.0 - y / h * <f32>2.0;
    const near = inv.projectPoint3(Vec3(nx, ny, 0));
    const far = inv.projectPoint3(Vec3(nx, ny, 1));
    // A degenerate camera (no depth range, a singular matrix) gives no
    // direction: fall back on its view axis so the ray is still a ray.
    let dir = (far - near).normalizeOrZero();
    if (!dir.isFinite() || dir == VEC3_ZERO) dir = camera.forward();
    out.origin = near.isFinite() ? near : camera.eye;
    out.dir = dir;
}
