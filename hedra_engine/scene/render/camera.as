// The camera a scene is drawn through, in render space (Hedra's Z up:
// SCENE_TO_MODEL of the scene's Y up, ../space.as), decision 7 of milestone
// 4: a Camera3D node, found by path or the scene's current one, or a camera
// framing everything drawn from Hedra's iso angle when the scene has
// none. A Camera3D becomes a Camera the way Hedra's `--view camera:<name>`
// turns a camera object into one (Hedra's scene_view.as, cameraObject),
// with Godot's meaning of fov, size and keep_aspect.

import { Result, clampF32, maxF32 } from "../../base/util";
import { VEC3_NEG_Z, VEC3_Y, VEC3_ZERO, toDegrees, toRadians } from "../../base/vecmath";
import { appleAtanf, appleTanf } from "../../base/libm";
import {
    Bounds, Camera, DEFAULT_FOV, FramingRequest, ISO_AZIMUTH, ISO_ELEVATION, Projection,
} from "../../render/camera";
import { SceneryError } from "../error";
import { SCENE_TO_MODEL } from "../space";
import { Camera3D } from "../tree/node";
import { SceneTree } from "../tree/tree";

// The fov a Camera3D is drawn with is clamped to these degrees (Godot's
// Camera3D.set_fov range).
export const MIN_FOV: f32 = 1;
export const MAX_FOV: f32 = 179;

// `c` as the renderer's Camera for a picture of aspect `aspect` (width /
// height): the eye at its global origin, looking along its global -Z with
// its global +Y up. `bounds` (what is drawn, render space) only places the
// target, in front of the eye by the distance to the bounds' centre along
// the view (at least 1), as Hedra does; the picture does not depend on it.
export function cameraOf(c: Camera3D, bounds: Bounds, aspect: f32): Camera {
    const out = new Camera(VEC3_ZERO, VEC3_ZERO, VEC3_Y, Projection.perspective(60), 1, 2);
    cameraInto(c, bounds, aspect, out);
    return out;
}

// cameraOf into `out`, allocating nothing (milestone 31: the run time's
// picking follows a moved camera between the pictures it draws).
export function cameraInto(c: Camera3D, bounds: Bounds, aspect: f32, out: Camera): void {
    const world = SCENE_TO_MODEL * c.global();
    const eye = world.transformPoint3(VEC3_ZERO);
    const forward = world.transformVector3(VEC3_NEG_Z).normalizeOrZero();
    const up = world.transformVector3(VEC3_Y).normalizeOrZero();
    const ahead = maxF32((bounds.center() - eye).dot(forward), 1.0);
    const a: f32 = isFinite(aspect) && aspect > 0 ? aspect : 1;
    // keep_aspect 1 (keep_height, Godot's default): fov and size measure
    // the height; 0 (keep_width): the width. A model's camera measures the
    // longer side, as Hedra's `--view camera:<name>` does (scene_view.as
    // cameraObject): the height of a portrait picture.
    const keepHeight = c.majorAxis ? a < 1 : c.keepAspect != 0;
    let projection: Projection;
    if (c.projection == 1) {
        const half = maxF32(c.size, <f32>1e-3) * <f32>0.5;
        projection = Projection.orthographic(keepHeight ? half : half / a);
    } else {
        // Godot's Camera3D refuses a fov outside 1 to 179 degrees; past
        // them the projection turns the picture over or draws nothing.
        const fov = toRadians(clampF32(c.fov, MIN_FOV, MAX_FOV));
        const fovY = keepHeight ? fov : <f32>2.0 * appleAtanf(appleTanf(fov * <f32>0.5) / a);
        projection = Projection.perspective(toDegrees(fovY));
    }
    const near = maxF32(c.near, <f32>1e-4);
    out.eye = eye;
    out.target = eye + forward * ahead;
    out.up = up;
    out.projection = projection;
    out.near = near;
    out.far = maxF32(c.far, near + <f32>1.0);
}

// The camera of a scene with none: `Camera.frame` around `bounds` from
// Hedra's iso angle with its default field of view, as the CLI's `render`
// frames a model.
export function framedCamera(bounds: Bounds, aspect: f32): Camera {
    return Camera.frame(bounds, FramingRequest(ISO_AZIMUTH, ISO_ELEVATION, false, DEFAULT_FOV, aspect, false, 0, false));
}

// Every Camera3D's path from the root, in tree order: the hint of the
// camera errors.
function camerasHint(tree: SceneTree): string {
    const paths = new Array<string>();
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const isCamera = all[i] instanceof Camera3D;
        if (isCamera) paths.push(all[i].path());
    }
    if (paths.length == 0) return "the scene has no Camera3D; leave --camera out to frame the scene";
    return "cameras: " + paths.join(", ");
}

// The Camera3D `path` names from the root (SceneNode.getNode: relative,
// absolute or %Unique). Fails with a SceneryError on `display` (the scene
// as errors name it): "camera-not-found" when no node has that path,
// "not-a-camera" when the node is of another class; both hint at the
// scene's cameras.
export function findCamera(tree: SceneTree, path: string, display: string): Result<Camera3D> {
    const n = tree.getNode(path);
    if (n == null) {
        return SceneryError.at("camera-not-found", display, 0, 0, "no node '" + path + "'", camerasHint(tree))
            .fail<Camera3D>();
    }
    const isCamera = n instanceof Camera3D;
    if (!isCamera) {
        return SceneryError.at("not-a-camera", display, 0, 0, "'" + path + "' is " + article(n.className) + " " + n.className + ", not a Camera3D",
            camerasHint(tree)).fail<Camera3D>();
    }
    return Result.okv<Camera3D>(n as Camera3D);
}

// "a" or "an" before a class name: "an OmniLight3D", "a Node3D".
function article(word: string): string {
    return word.length > 0 && "AEIOU".includes(word.charAt(0)) ? "an" : "a";
}
