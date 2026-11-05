// A scene's camera attributes as a frame draws them (milestone 62;
// ../resource/camera_attributes.as holds Godot's CameraAttributesPractical,
// ../../render/screen.as what a frame carries of the screen-space effects):
// which attributes a camera draws with, and the frame's DofDesc and
// exposure multiplier made of them. buildSceneFrame (adapter.as) and the
// viewports' frames (viewports.as) call these; refreshSceneFrame calls them
// again on each refresh in place, which allocates nothing.
//
// Godot's rule: a Camera3D's own `attributes` replace those of the
// WorldEnvironment of its world (`camera_attributes`); a view through no
// camera node (the editor's free camera, a preset view, the framed default)
// takes its world's WorldEnvironment's. A world's WorldEnvironment is its
// first in tree order, as the renderer's environment is (adapter.as
// environmentIn): the main world's, or that of the SubViewport with
// own_world_3d the camera is drawn in.
//
// A scene without camera attributes draws as before: no depth of field, an
// exposure multiplier of 1 (exact: the tone map's exposure times 1).

import { DofDesc } from "../../render/screen";
import { CameraAttributesPractical } from "../resource/camera_attributes";
import { Camera3D, SceneNode, SubViewport, WorldEnvironment } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { worldViewportOf } from "../tree/viewports";

// The attributes `camera` draws with among `walked` (a tree's walk, in tree
// order): its own, else its world's WorldEnvironment's; with `camera` null,
// the WorldEnvironment's of `world` (null: the main world). Null when there
// are none. Allocates nothing.
export function cameraAttributesIn(walked: Array<SceneNode>, camera: Camera3D?, world: SubViewport? = null): CameraAttributesPractical? {
    let w = world;
    if (camera != null) {
        const own = camera.attributes;
        if (own != null) return own;
        w = worldViewportOf(camera);
    }
    for (let i = 0; i < walked.length; i++) {
        const n = unchecked(walked[i]);
        const isEnv = n instanceof WorldEnvironment;
        if (isEnv && worldViewportOf(n) === w) return (n as WorldEnvironment).cameraAttributes;
    }
    return null;
}

// cameraAttributesIn over `tree`'s walk (the tools; it allocates the walk).
export function cameraAttributesOf(tree: SceneTree, camera: Camera3D?): CameraAttributesPractical? {
    return cameraAttributesIn(tree.walk(), camera);
}

// Where the attributes `camera` draws with come from (`inspect --screen`):
// "camera" its own, "world_environment" its world's WorldEnvironment's,
// "" none.
export function cameraAttributesSource(walked: Array<SceneNode>, camera: Camera3D?, world: SubViewport? = null): string {
    if (camera != null && camera.attributes != null) return "camera";
    return cameraAttributesIn(walked, camera, world) != null ? "world_environment" : "";
}

// `out` set to the depth of field `a` draws (Godot's dof_blur_* as the file
// wrote them: the renderer clamps the amount and reads a negative
// transition as Godot's physical scaling, ../../render/screen.as dofCoc),
// or to none (both sides off, Godot's defaults) when `a` is null. Returns
// `out`; allocates nothing.
export function dofDescInto(a: CameraAttributesPractical?, out: DofDesc): DofDesc {
    if (a == null) {
        out.farEnabled = false;
        out.farDistance = 10;
        out.farTransition = 5;
        out.nearEnabled = false;
        out.nearDistance = 2;
        out.nearTransition = 1;
        out.amount = 0.1;
        return out;
    }
    out.farEnabled = a.dofBlurFarEnabled;
    out.farDistance = a.dofBlurFarDistance;
    out.farTransition = a.dofBlurFarTransition;
    out.nearEnabled = a.dofBlurNearEnabled;
    out.nearDistance = a.dofBlurNearDistance;
    out.nearTransition = a.dofBlurNearTransition;
    out.amount = a.dofBlurAmount;
    return out;
}

// What `a` multiplies the tone map's exposure by: its exposure_multiplier
// (Godot's CameraAttributes.exposure_multiplier, applied as written: a
// negative or 0 one draws black, as Godot's), 1 without attributes.
// exposure_sensitivity and the auto exposure are kept, not drawn (the
// warning camera-attributes-auto-exposure says so).
export function exposureMultiplierOf(a: CameraAttributesPractical?): f32 {
    return a != null ? a.exposureMultiplier : 1;
}
