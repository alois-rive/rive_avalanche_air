// The glTF I/O error type, `IoError` (its hints and exit codes). It lives in
// its own module, as the core's CoreError does
// (engine/src/base/error.as), so the codecs, the exporter and the importer can
// name it without importing lib.as, which re-exports all of them.
//
// `IoError` is a class with a `kind` tag and the fields of every variant;
// `toString()` is the error message.

import { ErrorValue, Result } from "../../../base/util";

export enum IoErrorKind {
    NothingToExport,
    BadExtension,
    BadAxes,
    Serialize,
    Io,
    MissingTexture,
    UnsupportedImage,
    Parse,
    Unsupported,
}

export class IoError extends ErrorValue {
    kind: IoErrorKind;
    // NothingToExport(0) / BadExtension(0) / Serialize(0); BadAxes(0, _).
    text: string = "";
    // BadAxes(_, 1).
    text2: string = "";
    // Io / MissingTexture / UnsupportedImage / Parse / Unsupported.
    path: string = "";
    // MissingTexture / UnsupportedImage.
    material: string = "";
    // Parse.
    message: string = "";
    // Unsupported.
    what: string = "";
    // Io: the file-system error's text, and the typed error when there is one
    // (the VFS's `IoError` from engine/src/fs/vfs.as).
    sourceText: string = "";
    source: ErrorValue? = null;

    constructor(kind: IoErrorKind) {
        super();
        this.kind = kind;
    }

    static nothingToExport(s: string): IoError {
        const e = new IoError(IoErrorKind.NothingToExport);
        e.text = s;
        return e;
    }

    static badExtension(ext: string): IoError {
        const e = new IoError(IoErrorKind.BadExtension);
        e.text = ext;
        return e;
    }

    static badAxes(forward: string, up: string): IoError {
        const e = new IoError(IoErrorKind.BadAxes);
        e.text = forward;
        e.text2 = up;
        return e;
    }

    static serialize(m: string): IoError {
        const e = new IoError(IoErrorKind.Serialize);
        e.text = m;
        return e;
    }

    // An Io error: `sourceText` is the file-system error's text.
    static io(path: string, sourceText: string, source: ErrorValue? = null): IoError {
        const e = new IoError(IoErrorKind.Io);
        e.path = path;
        e.sourceText = sourceText;
        e.source = source;
        return e;
    }

    static missingTexture(path: string, material: string): IoError {
        const e = new IoError(IoErrorKind.MissingTexture);
        e.path = path;
        e.material = material;
        return e;
    }

    static unsupportedImage(path: string, material: string): IoError {
        const e = new IoError(IoErrorKind.UnsupportedImage);
        e.path = path;
        e.material = material;
        return e;
    }

    static parse(path: string, message: string): IoError {
        const e = new IoError(IoErrorKind.Parse);
        e.path = path;
        e.message = message;
        return e;
    }

    static unsupported(path: string, what: string): IoError {
        const e = new IoError(IoErrorKind.Unsupported);
        e.path = path;
        e.what = what;
        return e;
    }

    // The error message.
    toString(): string {
        switch (this.kind) {
            case IoErrorKind.NothingToExport: return "nothing to export" + this.text;
            case IoErrorKind.BadExtension: return "unsupported file extension '" + this.text + "' (use .gltf or .glb)";
            case IoErrorKind.BadAxes: return "invalid axis pair forward=" + this.text + " up=" + this.text2;
            case IoErrorKind.Serialize: return "glTF serialization failed: " + this.text;
            case IoErrorKind.Io: return "i/o error on " + this.path + ": " + this.sourceText;
            case IoErrorKind.MissingTexture:
                return "texture '" + this.path + "' of material '" + this.material + "' not found";
            case IoErrorKind.UnsupportedImage:
                return "texture '" + this.path + "' of material '" + this.material + "' is not a PNG or JPEG";
            case IoErrorKind.Parse: return "cannot read glTF '" + this.path + "': " + this.message;
            default: return "unsupported glTF feature in '" + this.path + "': " + this.what;
        }
    }

    // IoError::hint: null for Serialize and Io.
    hint(): string? {
        switch (this.kind) {
            case IoErrorKind.NothingToExport: return "add a mesh, or drop --selection / select something";
            case IoErrorKind.BadExtension: return "name the file tower.glb or tower.gltf";
            case IoErrorKind.BadAxes:
                return "forward and up must be different axes, e.g. --axis-forward -Z --axis-up Y";
            case IoErrorKind.MissingTexture:
                return "texture paths are relative to the project directory; fix the path with "
                    + "`material texture`, or export with --textures reference to keep the uri only";
            case IoErrorKind.UnsupportedImage:
                return "glTF embeds PNG or JPEG only; convert the image, or export with "
                    + "--textures reference";
            case IoErrorKind.Parse:
                return "the file must be valid glTF 2.0 (.gltf with its .bin and images next to it, "
                    + "or a .glb)";
            case IoErrorKind.Unsupported:
                return "Draco, meshopt and mesh quantization are read directly; re-export the "
                    + "asset without whatever else it requires (sparse accessors, say)";
            default: return null;
        }
    }

    // IoError::exit_code: Io is 3, everything else 1.
    exitCode(): i32 {
        return this.kind == IoErrorKind.Io ? 3 : 1;
    }

    fail<T>(): Result<T> {
        return Result.failWith<T>(this);
    }
}

// Wraps a failed file-system call (a VFS Result) as an Io error, keeping its
// text and typed cause.
export function ioError<T>(path: string, source: Result<T>): IoError {
    return IoError.io(path, source.err, source.cause);
}

// The IoError of a failed Result (null when the error is something
// else). Match on `e.kind`.
export function modelerIoErrorOf<T>(r: Result<T>): IoError? {
    if (r.ok) return null;
    const c = r.cause;
    if (c == null) return null;
    const isIo = c instanceof IoError;
    if (isIo) return c as IoError;
    return null;
}
