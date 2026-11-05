// CoreError, the error type of the core library.
//
// One class with a `kind` tag and the union of the variants' fields; build
// values with the static factories (named after the variants) so unused
// fields keep their defaults. Messages, hints and exit codes are
// user-visible: change them only on purpose.
//
//   fail with                 Result.failWith<T>(CoreError.noSuchObject(name, hint))
//   Result<T> (util.as)       its `cause` is a CoreError
//   dispatch                  switch (e.kind) { case CoreErrorKind.WrongMode: ... }
//   e.toString()              the message (also Result.err)
//   e.debug()                 the structured debug form
//   e.hint()                  string?
//   e.exitCode()              the process exit code
//
// NoSuchElement's element kind is stored in `elementKind`, since `kind` is
// the variant tag. Io's `source` is the underlying error's message.

import { ErrorValue, Result } from "./util";
import { debugStr, debugStruct, debugTuple } from "./fmt";
import { CLI, RETIRED_MODEL_EXTENSION, RETIRED_MODEL_PROGRAM } from "./names";

// One tag per error variant.
export enum CoreErrorKind {
    NoSuchObject,
    NothingSelected,
    NoActiveObject,
    WrongMode,
    InvalidArgument,
    NoSuchElement,
    NoSuchMaterial,
    NoSuchBone,
    NoSuchVertexGroup,
    NoSuchAction,
    NoSuchShapeKey,
    NotYet,
    NothingToUndo,
    NothingToRedo,
    NoSuchCheckpoint,
    BadMagic,
    BadVersion,
    ProjectExists,
    ProjectMissing,
    Serialize,
    Io,
}

export class CoreError extends ErrorValue {
    kind: CoreErrorKind;
    // NoSuch{Object,Material,Bone,VertexGroup,Action,ShapeKey}
    name: string = "";
    // every variant with a `hint` field
    hintText: string = "";
    // WrongMode, NotYet
    what: string = "";
    required: string = "";
    current: string = "";
    // NoSuchElement
    elementKind: string = "";
    id: u32 = 0;
    // BadVersion
    found: u32 = 0;
    supported: u32 = 0;
    // tuple variants: InvalidArgument, NoSuchCheckpoint, BadMagic,
    // ProjectExists, ProjectMissing, Serialize; and Io's path
    arg: string = "";
    // Io: the underlying i/o error's message
    source: string = "";

    constructor(kind: CoreErrorKind) {
        super();
        this.kind = kind;
    }

    static noSuchObject(name: string, hint: string): CoreError {
        const e = new CoreError(CoreErrorKind.NoSuchObject);
        e.name = name;
        e.hintText = hint;
        return e;
    }
    static nothingSelected(hint: string): CoreError {
        const e = new CoreError(CoreErrorKind.NothingSelected);
        e.hintText = hint;
        return e;
    }
    static noActiveObject(hint: string): CoreError {
        const e = new CoreError(CoreErrorKind.NoActiveObject);
        e.hintText = hint;
        return e;
    }
    static wrongMode(what: string, required: string, current: string): CoreError {
        const e = new CoreError(CoreErrorKind.WrongMode);
        e.what = what;
        e.required = required;
        e.current = current;
        return e;
    }
    static invalidArgument(msg: string): CoreError {
        const e = new CoreError(CoreErrorKind.InvalidArgument);
        e.arg = msg;
        return e;
    }
    static noSuchElement(elementKind: string, id: u32, hint: string): CoreError {
        const e = new CoreError(CoreErrorKind.NoSuchElement);
        e.elementKind = elementKind;
        e.id = id;
        e.hintText = hint;
        return e;
    }
    static noSuchMaterial(name: string, hint: string): CoreError {
        const e = new CoreError(CoreErrorKind.NoSuchMaterial);
        e.name = name;
        e.hintText = hint;
        return e;
    }
    static noSuchBone(name: string, hint: string): CoreError {
        const e = new CoreError(CoreErrorKind.NoSuchBone);
        e.name = name;
        e.hintText = hint;
        return e;
    }
    static noSuchVertexGroup(name: string, hint: string): CoreError {
        const e = new CoreError(CoreErrorKind.NoSuchVertexGroup);
        e.name = name;
        e.hintText = hint;
        return e;
    }
    static noSuchAction(name: string, hint: string): CoreError {
        const e = new CoreError(CoreErrorKind.NoSuchAction);
        e.name = name;
        e.hintText = hint;
        return e;
    }
    static noSuchShapeKey(name: string, hint: string): CoreError {
        const e = new CoreError(CoreErrorKind.NoSuchShapeKey);
        e.name = name;
        e.hintText = hint;
        return e;
    }
    static notYet(what: string, hint: string): CoreError {
        const e = new CoreError(CoreErrorKind.NotYet);
        e.what = what;
        e.hintText = hint;
        return e;
    }
    static nothingToUndo(): CoreError {
        return new CoreError(CoreErrorKind.NothingToUndo);
    }
    static nothingToRedo(): CoreError {
        return new CoreError(CoreErrorKind.NothingToRedo);
    }
    static noSuchCheckpoint(name: string): CoreError {
        const e = new CoreError(CoreErrorKind.NoSuchCheckpoint);
        e.arg = name;
        return e;
    }
    static badMagic(what: string): CoreError {
        const e = new CoreError(CoreErrorKind.BadMagic);
        e.arg = what;
        return e;
    }
    static badVersion(found: u32, supported: u32): CoreError {
        const e = new CoreError(CoreErrorKind.BadVersion);
        e.found = found;
        e.supported = supported;
        return e;
    }
    static projectExists(path: string): CoreError {
        const e = new CoreError(CoreErrorKind.ProjectExists);
        e.arg = path;
        return e;
    }
    static projectMissing(path: string): CoreError {
        const e = new CoreError(CoreErrorKind.ProjectMissing);
        e.arg = path;
        return e;
    }
    static serialize(msg: string): CoreError {
        const e = new CoreError(CoreErrorKind.Serialize);
        e.arg = msg;
        return e;
    }
    // An i/o error on `path`; `source` is the underlying error's message.
    static io(path: string, source: string): CoreError {
        const e = new CoreError(CoreErrorKind.Io);
        e.arg = path;
        e.source = source;
        return e;
    }

    // A failed Result<T> carrying this error (Result.failWith with the typed cause).
    fail<T>(): Result<T> {
        return Result.failWith<T>(this);
    }

    // The user-visible message.
    toString(): string {
        switch (this.kind) {
            case CoreErrorKind.NoSuchObject: return "no object named '" + this.name + "'";
            case CoreErrorKind.NothingSelected: return "nothing selected";
            case CoreErrorKind.NoActiveObject: return "no active object";
            case CoreErrorKind.WrongMode:
                return this.what + " requires " + this.required + " mode (current: " + this.current + ")";
            case CoreErrorKind.InvalidArgument: return "invalid argument: " + this.arg;
            case CoreErrorKind.NoSuchElement: return "no " + this.elementKind + " with id " + this.id.toString();
            case CoreErrorKind.NoSuchMaterial: return "no material named '" + this.name + "'";
            case CoreErrorKind.NoSuchBone: return "no bone named '" + this.name + "'";
            case CoreErrorKind.NoSuchVertexGroup: return "no vertex group named '" + this.name + "'";
            case CoreErrorKind.NoSuchAction: return "no action named '" + this.name + "'";
            case CoreErrorKind.NoSuchShapeKey: return "no shape key named '" + this.name + "'";
            case CoreErrorKind.NotYet: return this.what + " is not available yet";
            case CoreErrorKind.NothingToUndo: return "nothing to undo";
            case CoreErrorKind.NothingToRedo: return "nothing to redo";
            case CoreErrorKind.NoSuchCheckpoint: return "no checkpoint named '" + this.arg + "'";
            case CoreErrorKind.BadMagic: return "not a Hedra model file: " + this.arg;
            case CoreErrorKind.BadVersion:
                return "unsupported scene schema version " + this.found.toString() + " (this build writes schema "
                    + this.supported.toString() + "; `" + CLI + " version` lists the ones it reads)";
            case CoreErrorKind.ProjectExists: return "project file '" + this.arg + "' already exists";
            case CoreErrorKind.ProjectMissing: return "project file '" + this.arg + "' not found";
            case CoreErrorKind.Serialize: return "serialization failed: " + this.arg;
            default: return "i/o error on " + this.arg + ": " + this.source; // Io
        }
    }

    // Debug form: `Variant { field: value, .. }` (Io's source as a quoted string).

    debug(): string {
        switch (this.kind) {
            case CoreErrorKind.NoSuchObject:
                return debugStruct("NoSuchObject", ["name", "hint"], [debugStr(this.name), debugStr(this.hintText)]);
            case CoreErrorKind.NothingSelected: return debugStruct("NothingSelected", ["hint"], [debugStr(this.hintText)]);
            case CoreErrorKind.NoActiveObject: return debugStruct("NoActiveObject", ["hint"], [debugStr(this.hintText)]);
            case CoreErrorKind.WrongMode:
                return debugStruct("WrongMode", ["what", "required", "current"],
                    [debugStr(this.what), debugStr(this.required), debugStr(this.current)]);
            case CoreErrorKind.InvalidArgument: return debugTuple("InvalidArgument", [debugStr(this.arg)]);
            case CoreErrorKind.NoSuchElement:
                return debugStruct("NoSuchElement", ["kind", "id", "hint"],
                    [debugStr(this.elementKind), this.id.toString(), debugStr(this.hintText)]);
            case CoreErrorKind.NoSuchMaterial:
                return debugStruct("NoSuchMaterial", ["name", "hint"], [debugStr(this.name), debugStr(this.hintText)]);
            case CoreErrorKind.NoSuchBone:
                return debugStruct("NoSuchBone", ["name", "hint"], [debugStr(this.name), debugStr(this.hintText)]);
            case CoreErrorKind.NoSuchVertexGroup:
                return debugStruct("NoSuchVertexGroup", ["name", "hint"], [debugStr(this.name), debugStr(this.hintText)]);
            case CoreErrorKind.NoSuchAction:
                return debugStruct("NoSuchAction", ["name", "hint"], [debugStr(this.name), debugStr(this.hintText)]);
            case CoreErrorKind.NoSuchShapeKey:
                return debugStruct("NoSuchShapeKey", ["name", "hint"], [debugStr(this.name), debugStr(this.hintText)]);
            case CoreErrorKind.NotYet:
                return debugStruct("NotYet", ["what", "hint"], [debugStr(this.what), debugStr(this.hintText)]);
            case CoreErrorKind.NothingToUndo: return "NothingToUndo";
            case CoreErrorKind.NothingToRedo: return "NothingToRedo";
            case CoreErrorKind.NoSuchCheckpoint: return debugTuple("NoSuchCheckpoint", [debugStr(this.arg)]);
            case CoreErrorKind.BadMagic: return debugTuple("BadMagic", [debugStr(this.arg)]);
            case CoreErrorKind.BadVersion:
                return debugStruct("BadVersion", ["found", "supported"], [this.found.toString(), this.supported.toString()]);
            case CoreErrorKind.ProjectExists: return debugTuple("ProjectExists", [debugStr(this.arg)]);
            case CoreErrorKind.ProjectMissing: return debugTuple("ProjectMissing", [debugStr(this.arg)]);
            case CoreErrorKind.Serialize: return debugTuple("Serialize", [debugStr(this.arg)]);
            default: return debugStruct("Io", ["path", "source"], [debugStr(this.arg), debugStr(this.source)]);
        }
    }

    // A short, actionable hint for the caller, when the error has one.
    hint(): string? {
        switch (this.kind) {
            case CoreErrorKind.NoSuchObject:
            case CoreErrorKind.NothingSelected:
            case CoreErrorKind.NoActiveObject:
            case CoreErrorKind.NoSuchElement:
            case CoreErrorKind.NoSuchMaterial:
            case CoreErrorKind.NoSuchBone:
            case CoreErrorKind.NoSuchVertexGroup:
            case CoreErrorKind.NoSuchAction:
            case CoreErrorKind.NoSuchShapeKey:
            case CoreErrorKind.NotYet:
                return this.hintText;
            case CoreErrorKind.WrongMode: {
                if (this.required == "object") return "run `mode object` first";
                if (this.required == "pose") return "run `mode pose` on an armature object first";
                if (this.required == "edit (armature)") return "run `mode edit` on an armature object first";
                return "run `mode edit` on a mesh object first";
            }
            case CoreErrorKind.NothingToUndo: return "`history` lists the undo ring";
            case CoreErrorKind.NothingToRedo: return "redo is only possible right after `undo`";
            case CoreErrorKind.NoSuchCheckpoint: return "`history` lists checkpoints";
            case CoreErrorKind.ProjectExists: return "pass --force to overwrite, or pick another -p path";
            case CoreErrorKind.ProjectMissing: return "run `" + CLI + " model <file> new` or pass a file";
            case CoreErrorKind.BadVersion: {
                if (this.found < this.supported) {
                    return "this schema predates the migration path: run `" + RETIRED_MODEL_PROGRAM + " new --force` and replay the `.log` with `"
                        + RETIRED_MODEL_PROGRAM + " run <file>." + RETIRED_MODEL_EXTENSION + ".log`";
                }
                return null;
            }
            default: return null;
        }
    }

    // Exit-code class per PLAN §2: 1 command error, 2 project error, 3 I/O.
    exitCode(): i32 {
        switch (this.kind) {
            case CoreErrorKind.BadMagic:
            case CoreErrorKind.BadVersion:
            case CoreErrorKind.ProjectMissing:
            case CoreErrorKind.ProjectExists:
            case CoreErrorKind.Serialize:
                return 2;
            case CoreErrorKind.Io:
                return 3;
            default:
                return 1;
        }
    }
}

// The CoreError behind a failed Result, or null when it failed with a plain
// message (or succeeded). Use instead of an unchecked `r.cause as CoreError`.
export function coreErrorOf<T>(r: Result<T>): CoreError? {
    const c = r.cause;
    if (c == null) return null;
    const isCore = c instanceof CoreError;
    if (isCore) return c as CoreError;
    return null;
}
