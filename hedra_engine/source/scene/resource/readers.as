// The tools' file readers (milestone 40): the engine's loader
// (engine/src/scene/resource/loader.as) reads model and
// material files through the FileReaders it has installed, and the engine
// carries none of its own (its ExportedReaders fail, naming why: a Rive
// project's run time reads every model and material from its built scenes). The
// tools install these, which read a model file (an .rmdl read, an .rmdlcmd replayed, or
// a glTF file with its Draco and meshopt decoders: model.as) and
// a MaterialX material file (material_file.as). That keeps about 2 MB of
// readers and the model kernel out of the engine part of the library a
// Rive project compiles (docs/cli/BUILD.md section 3).
//
// Milestone 36: and a sound's header and .import (../../audio/reader.as
// readAudioSource), so that the tools know a stream's length, format and
// loop; the engine's default knows nothing until the runtime plays it.
//
// Installed explicitly, never by importing a module: each program's start
// (src/app/main.as) calls ../../install.as installSourceReaders, the scene
// renderer's constructor (engine/src/authoring/render/scene_renderer.as) calls it
// too, and so do the tests that load files without either. Installing is
// idempotent and allocates nothing after the first.

import { Result } from "../../../base/util";
import { ResourceLoader, FileReaders, currentFileReaders, installFileReaders } from "../../../scene/resource/loader";
import { ModelFormat, ModelResource, ModelSource, Resource } from "../../../scene/resource/types";
import { TextureSource } from "../../../scene/resource/model_hints";
// (aliased: a method of the same name below would shadow them, W1014)
import { loadModelFile as loadModelFileAt, modelFromScene } from "./model";
import { readMaterialFile as readMaterialFileAt } from "./material_file";
import { sourceScene } from "./model_source";
import { readAudioSource } from "../../audio/reader";

export class ToolReaders extends FileReaders {
    loadModelFile(abs: string, display: string, textures: TextureSource): Result<ModelResource> {
        return loadModelFileAt(abs, display, textures);
    }

    // A tool's ModelSource is a KernelModelSource (model_source.as): the
    // scene is converted as a file read into it would be. (sourceScene
    // tests the class there: see installSourceReaders.) Any other source
    // (none is made in the tools) gives a model with no objects, saying so.
    modelFromSource(source: ModelSource, format: ModelFormat, baseDir: string, textures: TextureSource): ModelResource {
        const scene = sourceScene(source);
        if (scene != null) return modelFromScene(scene, format, baseDir, textures);
        const m = new ModelResource();
        m.source = source;
        m.format = format;
        m.warnings.push("the model has no model scene to convert");
        return m;
    }

    readMaterialFile(loader: ResourceLoader, abs: string, display: string): Result<Resource> {
        return readMaterialFileAt(loader, abs, display);
    }

    readAudioFile(abs: string, display: string, type: string, bytes: Uint8Array?): Result<Resource> {
        return readAudioSource(abs, display, type, bytes);
    }
}

// The one ToolReaders installed (made on the first install).
let toolReaders: ToolReaders? = null;

// Installs the tools' readers unless they are installed already (a command
// run again on a host's answers allocates nothing more). (Compared by
// identity, not by instanceof: this module and model.as import each
// other, and an instanceof written here came out false for an object of
// the class it named; model_source.as sourceScene holds the one this
// module needs.)
export function installSourceReaders(): void {
    let r = toolReaders;
    if (r == null) {
        r = new ToolReaders();
        toolReaders = r;
    }
    if (currentFileReaders() !== r) installFileReaders(r);
}

// Whether the tools' readers are the ones installed (tests; and a check a
// program's start can assert).
export function toolReadersInstalled(): bool {
    const r = toolReaders;
    return r != null && currentFileReaders() === r;
}
