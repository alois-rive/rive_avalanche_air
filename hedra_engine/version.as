// The hedra_engine library's name and version (milestone 41, docs/plans/BUILD.md
// section 4.3; milestone 40 for the engine). The library is this directory,
// engine/src/: it imports nothing outside itself but the rive std,
// and its own files by relative paths only, so a copy compiles wherever it
// is put in a Rive project (tools/check_engine.py).
//
// the CLI's `build` vendors it at a Rive project's root as hedra_engine/, with
// hedra_engine/VERSION beside the files (the name and HEDRA_ENGINE_VERSION, the
// SHA-256 over every other file, the program that wrote it).
//
// The version follows what a built scene, a generated hedra_project.as
// and a node script of the previous version need: a change that one of
// them could not run with bumps the major part; anything else the minor or
// patch part. A built .rscnb records the major it was built for (its SRCS
// section, scene/rscnb/srcs.as), and the run time draws a scene built for
// another major from its source instead (the label says so).

// The directory's name in a Rive project, and the prefix of its files.
export const HEDRA_ENGINE_DIR = "hedra_engine";

// Its version, as major.minor.patch: the product's (VERSION at the
// repository's root), restarted at 0.1.0 with Hedra.
export const HEDRA_ENGINE_VERSION = "0.1.0";

// The major part.
export const HEDRA_ENGINE_MAJOR: i32 = 0;

