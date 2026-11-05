// The names Hedra's text gives programs and retired formats: the one file
// of engine/ and compiler/ that spells them (tools/check_layers.py allows
// it, docs/plans/HEDRA.md section 6.1). Hints and generated text name the
// command line program through CLI, so the libraries never spell a program.

// The command line program, as a hint tells the user to run it.
export const CLI = "hedra";
// The editor, as a hint names it.
export const EDITOR = "hedra-editor";

// The model file before the .rmdl: its extension (without the dot), and the
// program that converted it to an .rmdl.
export const RETIRED_MODEL_EXTENSION = "modeler";
export const RETIRED_MODEL_PROGRAM = "modeler";

// The script API's import path before the library was hedra_engine.
export const RETIRED_SCRIPT_IMPORT = "scenery/script";
