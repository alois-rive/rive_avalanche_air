// Milestone 62: Godot's CameraAttributesPractical, a camera's depth of
// field and exposure (../classdb.as has its properties; docs/formats/
// RSCN.md "Camera attributes", docs/engine/SCREEN_EFFECTS.md what each
// does). Held by a Camera3D's `attributes` or a WorldEnvironment's
// `camera_attributes` (a camera's own replaces the WorldEnvironment's, as
// in Godot). The fields are the file's values; what a frame draws of them
// is ../render's (the frame's DofDesc, the exposure multiplied). A
// binding, a timeline or a tween writes them in place
// (../binding/material_fields.as cameraAttributesField), and every camera
// naming the resource changes with it, as a shared resource does in Godot.
//
// Godot's CameraAttributesPhysical is not in the format (an unknown type,
// as today); its sensitivity and auto exposure are kept, not drawn.

import { Value } from "../value";
import { Resource } from "./types";

export class CameraAttributesPractical extends Resource {
    // CameraAttributes.
    exposureSensitivity: f32 = 100;
    exposureMultiplier: f32 = 1;
    autoExposureEnabled: bool = false;
    autoExposureScale: f32 = 0.4;
    autoExposureSpeed: f32 = 0.5;
    // CameraAttributesPractical.
    dofBlurFarEnabled: bool = false;
    dofBlurFarDistance: f32 = 10;
    dofBlurFarTransition: f32 = 5;
    dofBlurNearEnabled: bool = false;
    dofBlurNearDistance: f32 = 2;
    dofBlurNearTransition: f32 = 1;
    dofBlurAmount: f32 = 0.1;
    autoExposureMinSensitivity: f32 = 0;
    autoExposureMaxSensitivity: f32 = 800;

    className(): string {
        return "CameraAttributesPractical";
    }
}

// Sets a CameraAttributesPractical's field from a property value of the
// right type (the caller checked it against ../classdb.as); whether `name`
// is one of its fields (the editor sets fields through it too).
export function setCameraAttributesField(a: CameraAttributesPractical, name: string, v: Value): bool {
    if (name == "exposure_sensitivity") a.exposureSensitivity = v.asF32();
    else if (name == "exposure_multiplier") a.exposureMultiplier = v.asF32();
    else if (name == "auto_exposure_enabled") a.autoExposureEnabled = v.b;
    else if (name == "auto_exposure_scale") a.autoExposureScale = v.asF32();
    else if (name == "auto_exposure_speed") a.autoExposureSpeed = v.asF32();
    else if (name == "dof_blur_far_enabled") a.dofBlurFarEnabled = v.b;
    else if (name == "dof_blur_far_distance") a.dofBlurFarDistance = v.asF32();
    else if (name == "dof_blur_far_transition") a.dofBlurFarTransition = v.asF32();
    else if (name == "dof_blur_near_enabled") a.dofBlurNearEnabled = v.b;
    else if (name == "dof_blur_near_distance") a.dofBlurNearDistance = v.asF32();
    else if (name == "dof_blur_near_transition") a.dofBlurNearTransition = v.asF32();
    else if (name == "dof_blur_amount") a.dofBlurAmount = v.asF32();
    else if (name == "auto_exposure_min_sensitivity") a.autoExposureMinSensitivity = v.asF32();
    else if (name == "auto_exposure_max_sensitivity") a.autoExposureMaxSensitivity = v.asF32();
    else return false;
    return true;
}
