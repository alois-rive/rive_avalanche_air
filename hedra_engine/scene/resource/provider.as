// A source of ready resources the loader asks before it reads a file
// (milestone 39): the run time's bundle (../bundle/provider.as
// BundleResources) gives each scene, model, texture and material already
// decoded, so that nothing is parsed, replayed or imported at run time. A
// loader without one (every tool) reads files as it always did.
//
// Milestone 39 scaffolding: complete.

import { Result } from "../../base/util";
import { Resource } from "./types";

export abstract class ResourceProvider {
    // The resource of `type` (an ext_resource type: classdb.as
    // extTypeNames) at the absolute path `abs` (`display` is how errors
    // name it), or null when this provider does not hold it: the loader
    // then reads the file through the vfs, as without a provider. A failed
    // result fails the load as the file's own error would. The loader sets
    // the resource's `path` and `file` and caches it, as for a file it read.
    // `root` is the asking loader's project root: what a resource that
    // names files itself (a material's res:// textures) resolves them
    // against, as the loader would have had it read the file.
    abstract provide(type: string, abs: string, display: string, root: string): Result<Resource>?;
}
