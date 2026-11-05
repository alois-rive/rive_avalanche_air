// Who writes a model's replay cache entry (./cache.as): the seam between
// the code that saves a model (engine/src/authoring/model_project/project.as) and the code
// that writes a built form. Reading an entry is the source tier's, and every
// tool that opens a model does it; writing one is the compiler's
// (compiler/src/model/cache_write.as), which the engine may not
// import. So the project asks this slot, and a program that saves models
// (Hedra, Hedra's model editor) installs the writer in main. With none
// installed a save writes the model file and its ring alone, and the next
// open replays as it would on any cache miss.

import { Result } from "../../../base/util";
import { Scene } from "../scene";
import { RmdlDoc } from "./doc";
import { CacheDep } from "./cache";

export abstract class ModelCacheWriter {
    // The entry for the scene `doc`'s first `n` entries build, for the model
    // at `modelAbs` (an absolute path), which read `deps` besides the model.
    // The entry's path, or why it could not be written.
    abstract write(doc: RmdlDoc, n: i32, modelAbs: string, scene: Scene, deps: Array<CacheDep>): Result<string>;
}

let writer: ModelCacheWriter? = null;

// Installs `w` (null: none), replacing the writer before it.
export function setModelCacheWriter(w: ModelCacheWriter?): void {
    writer = w;
}

// The writer installed, or null.
export function modelCacheWriter(): ModelCacheWriter? {
    return writer;
}
