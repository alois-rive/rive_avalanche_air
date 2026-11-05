// What a run time tells the parts that manage its resources (milestone
// 67b, docs/engine/RESOURCES.md): the remaps (remap.as: which form of each
// resource a load reads), the resource cache and its lifetimes
// (runtime_resources.as) and the CPU copies (../resource/cpu_copy.as).
// newSceneRuntime() adds them to every run time it makes (Rive projects,
// Play); a SceneRuntime made with `new` (the tests, the tools) has none and
// loads as it always did.
//
// SceneRuntime calls each hook, in the order they were added, at these
// points (scene_runtime.as):
//
//   attached         addHook
//   bundleUsed       useBundle, once the bundle's resources are made and
//                    mounted (a built scene, a bundle, a scene file); also
//                    by load_task.as and remap.as for the resources they
//                    make, so a hook is called again for the same `res`
//                    when useBundle takes the load task's: it must be
//                    idempotent
//   loaderMade       instantiate and instantiateFile, for each tree's
//                    loader, before the tree loads (a fresh loader each
//                    time once a hook asked for `freshLoaders`)
//   instanceMade     instantiateTree, before the instance starts
//   instanceDisposed SceneInstance.dispose, after its parts let go
//   advanced         the start of SceneInstance.advance (cheap: no
//                    allocation, nothing when there is nothing to do)
//   statusPart       SceneInstance.status: members appended to its JSON
//                    (",\"resources\":{...}"; "" for none), with
//   statusMark       a number that changes whenever the part would
//                    (statusChanged rewrites the status only then)
//
// `loadProject` and `loadFiles` on the runtime say which Hedra project and
// which files the load in progress reads (load, loadText, loadBuilt,
// loadFrom; "" and null for loadBundle, loadSceneFile and useFiles).
//
// Nothing here may allocate per frame: `advanced`, `statusPart` and
// `statusMark` run every frame of every instance.

import { ResourceLoader } from "../resource/loader";
import { BundleResources } from "../bundle/provider";
import { SceneInstance, SceneRuntime } from "./scene_runtime";

export abstract class RuntimeHook {
    attached(rt: SceneRuntime): void {}
    bundleUsed(rt: SceneRuntime, res: BundleResources): void {}
    // `res` the bundle the tree reads (null: the files of useFiles, the
    // text source's).
    loaderMade(rt: SceneRuntime, loader: ResourceLoader, res: BundleResources?): void {}
    instanceMade(rt: SceneRuntime, inst: SceneInstance): void {}
    instanceDisposed(rt: SceneRuntime, inst: SceneInstance): void {}
    advanced(inst: SceneInstance): void {}
    statusPart(inst: SceneInstance): string {
        return "";
    }
    statusMark(inst: SceneInstance): i64 {
        return 0;
    }
}
