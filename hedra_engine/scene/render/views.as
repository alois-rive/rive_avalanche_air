// The views a scene is drawn from (milestone 5, the CLI's `render --view` and
// `--sheet`; sheet.as tiles several into a contact sheet).
//
// A view is one of:
// - the scene's own: its current Camera3D, else a camera framing everything
//   drawn from Hedra's iso angle (the default render, and `--view camera`);
// - a preset (iso, front, back, left, right, top, bottom): a camera framing
//   everything drawn from the preset's angles, orthographic for all but iso,
//   with Hedra's default field of view, exactly as Hedra frames its
//   presets (`Camera.frame` with Hedra's FramingRequest), so a model seen
//   from the front in Hedra is the model seen from the front in Hedra;
// - a Camera3D by node path (`--view camera:<path>`, `--camera <path>`).
//
// A view's label (SceneFrame.view, the render answer's `views`, a sheet
// tile's caption) says what was drawn: the preset's name, `camera:<path>`
// for a Camera3D (the scene's own view names the current camera's path), and
// `iso` for the framed default, which is the iso preset's picture.

import { Bounds, Camera, DEFAULT_FOV, FramingRequest, VIEW_PRESET_ALL, ViewPreset } from "../../render/camera";

export enum SceneViewKind {
    // The current camera, else the framed default.
    Scene,
    // SceneView.preset: a ViewPreset.
    Preset,
    // SceneView.camera: a Camera3D's node path.
    Camera,
}

export class SceneView {
    kind: SceneViewKind = SceneViewKind.Scene;
    // A ViewPreset for Preset, else -1.
    preset: i32 = -1;
    // The node path of Camera, else "".
    camera: string = "";

    static scene(): SceneView {
        return new SceneView();
    }

    static preset(p: ViewPreset): SceneView {
        const v = new SceneView();
        v.kind = SceneViewKind.Preset;
        v.preset = <i32>p;
        return v;
    }

    static camera(path: string): SceneView {
        const v = new SceneView();
        v.kind = SceneViewKind.Camera;
        v.camera = path;
        return v;
    }

    // The view a word names (the names of VIEW_NAMES, exactly, or
    // camera:<path> with a path), or null.
    static parse(s: string): SceneView? {
        if (s == "camera") return SceneView.scene();
        if (s.startsWith("camera:")) {
            const path = s.substring(7);
            return path.length > 0 ? SceneView.camera(path) : null;
        }
        for (let i = 0; i < VIEW_PRESET_ALL.length; i++) {
            const p = VIEW_PRESET_ALL[i];
            if (ViewPreset.name(p) == s) return SceneView.preset(p);
        }
        return null;
    }

    equals(o: SceneView): bool {
        return this.kind == o.kind && this.preset == o.preset && this.camera == o.camera;
    }
}

// The words SceneView.parse takes, for hints.
export const VIEW_NAMES = "iso, front, back, left, right, top, bottom, camera and camera:<node path>";

// The camera of preset `p` around `bounds` (render space) for a picture of
// aspect `aspect`: Hedra's `viewCamera` for a preset with no override
// (its angles, orthographic but for iso, DEFAULT_FOV, the projected-corner
// fit).
export function presetCamera(p: ViewPreset, bounds: Bounds, aspect: f32): Camera {
    const a = ViewPreset.angles(p);
    return Camera.frame(bounds, FramingRequest(a.x, a.y, ViewPreset.isOrtho(p), DEFAULT_FOV, aspect, false, 0, false));
}
