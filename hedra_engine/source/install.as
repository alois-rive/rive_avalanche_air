// The source readers install themselves (milestone 41, docs/plans/BUILD.md
// section 4.4): every .as file of a Rive project is compiled into its
// module and its top-level statements run at start, so a project holding
// hedra_engine/source/ reads glTF (with Draco and meshopt), model
// documents (.rmdl), data-form .rmdlcmd (the model kernel replays it) and
// MaterialX from their sources, and one
// that excludes it (`exclude: [hedra_engine/source]` in rive.yaml) does not:
// the engine's own readers then fail, naming the missing part
// (engine/src/scene/resource/loader.as ExportedReaders), and a scene drawn from
// its text says "no source readers".
//
// The readers are the tools' (engine/src/source/scene/resource/readers.as ToolReaders);
// this file is the library's documented entry to them. Installing is
// idempotent.
//
// The top-level call below is for Rive projects, which compile every file
// of the library, so holding this directory is what installs the readers.
// The tools stage only the files they import and never rely on an
// import's side effect: each program calls installSourceReaders first
// thing in its main, the scene renderer in its constructor, and a test
// that loads model or material files without either calls it itself.

import { installSourceReaders as installReaders, toolReadersInstalled } from "./scene/resource/readers";

// Installs the source readers (again: a no-op once they are).
export function installSourceReaders(): void {
    installReaders();
}

// Whether the source readers are the ones installed.
export function sourceReadersInstalled(): bool {
    return toolReadersInstalled();
}

// (a Rive project's install: see above)
installSourceReaders();
