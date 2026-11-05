// hedra_engine/scene3d: the Scene3D component (milestone 41, docs/plans/BUILD.md
// section 6.4): the only Layout of the library. A designer places a
// ScriptedLayout of it (the ScriptAsset hedra_engine.rml declares, id 93:1)
// and binds its artboard to a view model with these properties (the
// library's Scene3D view model has them all; a project's own view model
// may have any of them, and `data` besides):
//
//   scene         string  the scene's path in the Rive project
//                         ("world/courtyard.rscn"); "" the main scene of the
//                         only Hedra project
//   source        string  auto (default), text or built
//   unbuiltLabel  bool    the label when Auto draws from the text (default true)
//   animation     string  the scene's LinearAnimation played from its start
//                         ("" none, the default; milestone 45): a change
//                         plays the new one, a scene switch plays it in the
//                         new scene, an unknown name is the status's error
//   stateMachine  string  the scene's state machine run from its start (""
//                         its default, the first it declares unless its
//                         root's default_state_machine says otherwise; "-"
//                         none): a change runs the new one, an unknown
//                         name is the status's error
//   events        string  written (milestone 49): the names of the events
//                         the scene and the scenes it instances fired since
//                         the last advance, oldest first, joined by "\n"
//                         ("" none); written only when it changes
//   renderScale   number  the 3D's render scale (Godot's scaling_3d_scale,
//                         0.25 to 2; milestone 67, docs/engine/PERFORMANCE.md
//                         "Render scale"): 0 (the default) the project's
//                         rendering/scaling_3d/scale (1 unless hedra.yaml
//                         says otherwise)
//   scalingMode   string  bilinear or fsr (Godot's scaling_3d_mode: the
//                         picture stretched, or upscaled by FSR 1.0); "" (the
//                         default) the project's
//   maxDensity    number  the 3D picture's pixels a point at most: 0 (the
//                         default) the project's max_density (2), negative
//                         no cap
//   maxPixels     number  the 3D picture's pixels at most: 0 (the default)
//                         the project's max_pixels (2560 x 1440), negative
//                         no cap
//   loadBudget    number  the milliseconds an advance spends loading a
//                         scene at most (milestone 67b,
//                         docs/engine/RESOURCES.md "Loading"): 0 (the
//                         default) the project's loading/frame_budget_msec
//                         (0 unless hedra.yaml sets it: the whole load in
//                         one advance), negative the whole load at once;
//                         while a scene loads the one shown before keeps
//                         playing and drawing
//   progress      number  written: how far the scene's load is, 0 to 1 (1
//                         once it is shown), only when it changes; a
//                         binding draws a loading bar from it
//   resources     string  written: the run time's resources as JSON
//                         ({"count":N,"refs":R,"cpu":B,"gpu":B,
//                         "textures":T,"buffers":U,"fallbacks":F}), only
//                         when they change
//   camera, playing, speed, yaw, lodThreshold, data, status: as the engine's
//                         Scene3D (engine/src/scene/runtime/scene3d.as Scene3DView)
//
// The four render-scale properties are bindable and keyable as any of the
// view model's (a state machine's timeline keys renderScale, a binding
// drives it from a settings screen); scripts, listeners and the bindings'
// screen outputs keep the layout's points and pixels whatever the scale.
// A picture smaller than the layout's pixels draws fewer pixels: a scale
// of 0.5 draws a quarter of them. Above the caps the 3D draws fewer pixels
// than the display has (a 4K window at density 1 at 2560 x 1440; density
// 3 at density 2), the UI drawn by Rive around it staying sharp.
//
// The status (milestone 61) gains `"shaders":{"drawn":N,"fallback":M}` when
// the last picture drew a custom shader material (a ShaderMaterial): how
// many of its draws used the module rive compiled from what `hedra build`
// wrote into hedra_shaders/, and how many drew the material's fallback (a
// shader not built into the Rive project). A scene without one says
// nothing of shaders (SceneInstance.status, ./scene/runtime/scene_runtime.as).
// It gains `"picture":[W,H]` (milestone 67) while the 3D picture is not
// the layout's pixels (a render scale or a cap applies), and
// `"variants":{"drawn":N,"ubershader":M,"pending":P}` while the last
// picture drew specialised surface shaders or waited for one.
// It gains `"screen":{"ssr":B,"refraction":B,"dof":B}` (milestone 62) when
// the last picture's plan draws a screen-space effect: the Environment's
// reflections (ssr_enabled), its screen refraction with glass in the
// picture (screen_refraction_enabled), the camera's depth of field (its
// CameraAttributesPractical's dof_blur_*), each true when drawn; the
// quality is the project's (its hedra.yaml's settings, passed by the
// generated hedra_project.as). A scene without them says nothing of the
// screen.
//
// A scene that writes its data (its bindings two_way, to_source or
// signal:, an event's fire binding, a state machine writing the view
// model, a script, an artboard texture bound to its instance) keeps running
// while the layout is off-screen, so the artboard's state machine reads the
// same values whether or not the scene is shown (milestone 49); so does a
// scene that declares events while the view model has `events`; a scene
// that only reads stands still off-screen.
//
// A scene's artboard textures take the inputs artboard_0 to artboard_7 in
// the order the scene names them (the tree's order: each Rive file's
// artboard once, as its materials first use it).
//
// The layout's pointer events go to the scene in the artboard's
// coordinates: its scripts' _input first, then the interaction feature's
// picking (collision objects' signals), then the state machines' pointer
// listeners (meshes hit by their triangles as drawn) and the artboards the
// scene shows in 3D (the event forwarded to the artboard under the pointer,
// at that point in its own coordinates), these two reading one pick of the
// event.
//
// Everything happens in the run time's Scene3DView, in its loading mode:
// each scene shown is loaded into a runtime of its own (newSceneRuntime,
// hedra_engine/scene) by a load task (scene/runtime/load_task.as: one
// advance, or several under the load budget), from the blobs the Rive
// project's hedra_engine.rml and hedra.built.rml declare. Without a bound
// view model the defaults apply (the main scene, auto, the label on).

import { Context, Layout } from "rive/host";
import { Artboard } from "rive/artboard";
import { Renderer } from "rive/renderer";
import { KeyboardEvent, PointerEvent } from "rive/events";
import { InputKind } from "./scene/script";
import { Scene3DView } from "./scene/runtime/scene3d";
import { SceneRuntime } from "./scene/runtime/scene_runtime";
import { newSceneRuntime } from "./scene";
import { installLaneExecutor } from "./base/jobs";
import { LaneExecutor } from "./render/lanes";

// The frame's jobs on Rive's script threads (render/lanes.as): every built
// Rive project has the component, so the lane executor is every job's
// there (jobs.as JOB_EXECUTOR_DEFAULT, the frame runtime). Where the pool
// has no thread (a web runtime built without them) it runs them serially.
installLaneExecutor(new LaneExecutor());

// The number of artboard inputs (artboard_0 to artboard_7).
export const SCENE3D_ARTBOARD_INPUTS: i32 = 8;

// Each scene's runtime (Scene3DView's factory).
function makeRuntime(): SceneRuntime {
    return newSceneRuntime();
}

export class Scene3D extends Layout {
    @input("artboard_0") artboard0: Artboard? = null;
    @input("artboard_1") artboard1: Artboard? = null;
    @input("artboard_2") artboard2: Artboard? = null;
    @input("artboard_3") artboard3: Artboard? = null;
    @input("artboard_4") artboard4: Artboard? = null;
    @input("artboard_5") artboard5: Artboard? = null;
    @input("artboard_6") artboard6: Artboard? = null;
    @input("artboard_7") artboard7: Artboard? = null;
    view: Scene3DView = new Scene3DView();

    override init(context: Context): bool {
        return this.view.initLoading(context, makeRuntime);
    }

    override advance(seconds: f64): bool {
        const v = this.view;
        v.provideArtboard(0, this.artboard0);
        v.provideArtboard(1, this.artboard1);
        v.provideArtboard(2, this.artboard2);
        v.provideArtboard(3, this.artboard3);
        v.provideArtboard(4, this.artboard4);
        v.provideArtboard(5, this.artboard5);
        v.provideArtboard(6, this.artboard6);
        v.provideArtboard(7, this.artboard7);
        return v.advance(seconds);
    }

    override draw(renderer: Renderer): void {
        this.view.draw(renderer);
    }

    override resize(width: f64, height: f64, scale: f64): void {
        this.view.resize(width, height, scale);
    }

    override pointerDown(e: PointerEvent): void {
        this.view.pointer(InputKind.PointerDown, <f32>e.position.x, <f32>e.position.y, <i32>e.id);
    }

    override pointerMove(e: PointerEvent): void {
        this.view.pointer(InputKind.PointerMove, <f32>e.position.x, <f32>e.position.y, <i32>e.id);
    }

    override pointerUp(e: PointerEvent): void {
        this.view.pointer(InputKind.PointerUp, <f32>e.position.x, <f32>e.position.y, <i32>e.id);
    }

    override pointerExit(e: PointerEvent): void {
        this.view.pointer(InputKind.PointerExit, <f32>e.position.x, <f32>e.position.y, <i32>e.id);
    }

    override keyboardEvent(e: KeyboardEvent): bool {
        const kind = e.phase == "down" ? InputKind.KeyDown : (e.phase == "repeat" ? InputKind.KeyRepeat : InputKind.KeyUp);
        return this.view.key(kind, <i32>e.key, e.shift, e.control, e.alt, e.meta);
    }
}
