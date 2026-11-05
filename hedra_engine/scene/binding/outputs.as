// What a binding's outputs read beside the node (docs/plans/RIVE_MODEL.md
// section 3.1, "Outputs"): `screen_position:x|y` and `screen_visible`
// project the node's origin through the camera the scene is seen through
// into the view's points (the Scene3D layout's, or `render --size`'s), so a
// 2D label follows a 3D node. The run time sets the view before each push
// (SceneInstance, from its camera, its yaw and the layout's size), the
// tools once per picture (outputViewOf the frame's camera); a binding of
// an output reads nothing until a view is set (`valid` false).
//
// Coordinates are Rive's layout's: x right and y down from the view's top
// left corner, in points. Behind the camera (clip w at or below 1e-6, the
// renderer's own test: Camera.project) a node has no screen position: the
// output keeps its last value, and screen_visible is false.

import { MAT4_IDENTITY, Mat4, Vec3, Vec4 } from "../../base/vecmath";
import { Camera } from "../../render/camera";
import { sceneToModel } from "../space";

export class OutputView {
    // The camera's view-projection matrix (the renderer's model space, Z
    // up, to clip space: Camera.viewProj; a scene point goes through
    // ../space.as sceneToModel first).
    viewProjection: Mat4 = MAT4_IDENTITY;
    // The view's size in points (the layout's, not its pixels).
    width: f64 = 0;
    height: f64 = 0;
    // Whether a view was set.
    valid: bool = false;

    set(viewProjection: Mat4, width: f64, height: f64): void {
        this.viewProjection = viewProjection;
        this.width = width;
        this.height = height;
        this.valid = width > 0 && height > 0;
    }

    // Milestone 42: the view through `camera` at `width` x `height` points
    // (allocates nothing: the matrices are values).
    setCamera(camera: Camera, width: f64, height: f64): void {
        const aspect = <f32>(height > 0 ? width / height : 1);
        this.set(camera.viewProj(aspect), width, height);
    }

    // The clip-space position of the scene-space point `p`.
    clip(p: Vec3): Vec4 {
        return this.viewProjection.mulVec4(sceneToModel(p).extend(1.0));
    }
}

// The view through `camera` at `width` x `height` points: what the tools
// hand applySceneData (their picture's camera: the planned frame's).
export function outputViewOf(camera: Camera, width: f64, height: f64): OutputView {
    const v = new OutputView();
    v.setCamera(camera, width, height);
    return v;
}

// Whether a clip position is in front of the camera (its w above the
// renderer's 1e-6).
export function inFront(c: Vec4): bool {
    return c.w > <f32>1e-6;
}

// The x (axis 0) or y (1) in the view's points of a clip position in front
// of the camera: Rive's layout coordinates, top left, y down.
export function screenAxis(view: OutputView, c: Vec4, axis: i32): f64 {
    const w = <f64>c.w;
    if (axis == 0) return (<f64>c.x / w * 0.5 + 0.5) * view.width;
    return (1.0 - (<f64>c.y / w * 0.5 + 0.5)) * view.height;
}

// Whether a clip position is drawn: in front of the near plane (WebGPU's
// depth 0 to 1) and inside the view.
export function onScreen(c: Vec4): bool {
    if (!inFront(c)) return false;
    const w = c.w;
    const x = c.x / w;
    const y = c.y / w;
    const z = c.z / w;
    return x >= -1 && x <= 1 && y >= -1 && y <= 1 && z >= 0 && z <= 1;
}
