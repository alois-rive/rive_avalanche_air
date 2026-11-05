// hedra_engine/scene: the run time API for host code (milestone 41,
// docs/plans/BUILD.md section 6). A Rive project's own Layout, the
// library's Scene3D component (hedra_engine/scene3d) and the generated
// hedra_project.as import it by this root-relative path:
//
//   import { SceneOptions, SceneRuntime } from "hedra_engine/scene";
//
//   const rt = new SceneRuntime();
//   const got = rt.load(context, "world/courtyard.rscn", new SceneOptions());
//   const scene = got.instance;           // null when nothing could be drawn
//   // each frame: scene.advance(seconds); scene.draw(renderer, width, height, scale)
//
// The three sources (sources.as): the scene's text through the declared
// `hedra:` blobs, its built form under build/hedra/, or Auto (the
// built form when it is current, else the text with a label). Milestone
// 42: a scene's view model, globals and converters may come from the Rive
// project's own RML (docs/engine/DATA.md); newSceneRuntime installs the
// provider that reads it for a scene drawn from its text (the declared
// .rml blobs the project lists: engine/src/scene/runtime/project_data.as). A public
// module: what it exports is the library's promise to host code (a name
// that leaves bumps the library's major, version.as).

export { HEDRA_ENGINE_DIR, HEDRA_ENGINE_MAJOR, HEDRA_ENGINE_VERSION } from "./version";
export { CONNECT_ONE_SHOT, MAX_PICTURE_SIDE, RUNTIME_LOD_THRESHOLD, SceneInstance, SceneRuntime } from "./scene/runtime/scene_runtime";
export {
    BLOB_PREFIX, BUILT_DIR, BlobFiles, BuiltState, FileSource, REASON_INVALID, REASON_NOT_BUILT, REASON_NO_SOURCE_READERS,
    REASON_OTHER_MAJOR, REASON_OUT_OF_DATE, SceneLoad, SceneOptions, SceneSource, blobNameOf, builtPathOf, sceneSourceName,
    sceneSourceNamed,
} from "./scene/runtime/sources";
export {
    RegisteredProject, ScriptRegistrar, projectNamed, registerProject, registeredProjects,
} from "./scene/runtime/projects";
export { CameraHandle, LightHandle, MeshHandle, Node3DHandle, NodeHandle } from "./scene/runtime/handles";
export { SignalEvent } from "./scene/runtime/signals";
// Milestone 45: the events a scene fired (SceneInstance.takeEvents).
export { EVENT_FIRED_SIGNAL, FiredEvent } from "./scene/runtime/events";
export { UnbuiltLabel, labelFit, labelRect, labelText } from "./scene/runtime/label";

import { SceneRuntime as Runtime } from "./scene/runtime/scene_runtime";
import { installScriptsFeature } from "./scene/runtime/feature_scripts";
import { installArtboardsFeature } from "./scene/runtime/feature_artboards";
import { installBindingsFeature } from "./scene/runtime/feature_bindings";
import { installInteractionFeature } from "./scene/runtime/feature_interaction";
import { installAnimationFeature } from "./scene/runtime/feature_animation";
import { installParticlesFeature } from "./scene/runtime/feature_particles";
import { installAudioFeature } from "./scene/runtime/feature_audio";
import { installNavigationFeature } from "./scene/runtime/feature_navigation";
import { installBlobProjectData } from "./scene/runtime/project_data";
import { setShaderRoot } from "./render/gpu/pipelines";
import { HEDRA_ENGINE_DIR } from "./version";
import { installRemaps } from "./scene/runtime/remap";
import { installResourceCache } from "./scene/runtime/runtime_resources";

// A runtime ready for load(): every feature of the run time installed (a
// node's scripts, live artboard textures, view model bindings, and the
// interaction of areas, ray casts and the pointer's picking), the
// renderer's shaders found under the vendored library (hedra_engine/shaders/),
// milestone 45's timelines (Rive's LinearAnimations, played by the Scene3D's
// `animation` and by scripts' `scene.animation(name)`), the state
// machines and their listeners (a pointer event reaches the machines'
// pointer listeners and the artboards shown in 3D, each picked once; an
// event's fire binding fires its view model trigger),
// and the Rive project's data read for a scene drawn from its text (unless
// a provider is installed already: the tools have their own).
// What the Scene3D component loads each scene into, and what Play runs a
// game with; a host's own Layout makes one per scene it shows (each
// scene's levels of detail and files are its runtime's own).
export function newSceneRuntime(): Runtime {
    setShaderRoot(HEDRA_ENGINE_DIR + "/");
    installBlobProjectData();
    const rt = new Runtime();
    installScriptsFeature(rt);
    installArtboardsFeature(rt);
    installBindingsFeature(rt);
    installInteractionFeature(rt);
    installAnimationFeature(rt);
    installParticlesFeature(rt);
    installAudioFeature(rt);
    installNavigationFeature(rt);
    // (milestone 67b, docs/engine/RESOURCES.md: the remaps first, so that the
    // cache keeps what they chose; the cache installs the CPU-copy policy)
    installRemaps(rt);
    installResourceCache(rt);
    return rt;
}
