// `RenderError`: every way a render can fail.
//
// One class with a `kind` tag and per-kind fields. Propagate it
// through `Result<T>` (`RenderError.invalid(..).fail<T>()`), and recover the
// typed value from a failed result with `renderErrorOf(r)`.

import { ErrorValue, Result } from "../base/util";

export enum RenderErrorKind {
    NoAdapter,
    Device,
    Io,
    Encode,
    Invalid,
}

// The hint given for every `Device` error.
export const DEVICE_HINT = "rive renders only on the GPU device of its host, and there is no other adapter to pick: on macOS it needs a Metal-capable GPU";

export class RenderError extends ErrorValue {
    kind: RenderErrorKind;
    // NoAdapter / Invalid: `message`; Device / Encode: the tuple payload.
    message: string = "";
    // NoAdapter / Invalid.
    hintText: string = "";
    // Io.
    path: string = "";
    // Io: the I/O error text.
    source: string = "";

    constructor(kind: RenderErrorKind) {
        super();
        this.kind = kind;
    }

    static noAdapter(message: string, hint: string): RenderError {
        const e = new RenderError(RenderErrorKind.NoAdapter);
        e.message = message;
        e.hintText = hint;
        return e;
    }

    static device(message: string): RenderError {
        const e = new RenderError(RenderErrorKind.Device);
        e.message = message;
        return e;
    }

    static io(path: string, source: string): RenderError {
        const e = new RenderError(RenderErrorKind.Io);
        e.path = path;
        e.source = source;
        return e;
    }

    static encode(message: string): RenderError {
        const e = new RenderError(RenderErrorKind.Encode);
        e.message = message;
        return e;
    }

    // An `Invalid` error with its message and hint.
    static invalid(message: string, hint: string): RenderError {
        const e = new RenderError(RenderErrorKind.Invalid);
        e.message = message;
        e.hintText = hint;
        return e;
    }

    // A failed Result<T> carrying this error.
    fail<T>(): Result<T> {
        return Result.failWith<T>(this);
    }

    // Display text of the error.
    toString(): string {
        switch (this.kind) {
            case RenderErrorKind.Device: return "graphics device error: " + this.message;
            case RenderErrorKind.Io: return "i/o error on " + this.path + ": " + this.source;
            case RenderErrorKind.Encode: return "PNG error: " + this.message;
            default: return this.message; // NoAdapter, Invalid
        }
    }

    hint(): string? {
        switch (this.kind) {
            case RenderErrorKind.NoAdapter:
            case RenderErrorKind.Invalid:
                return this.hintText;
            case RenderErrorKind.Device:
                return DEVICE_HINT;
            default:
                return null;
        }
    }

    // Stable error code for the JSON answer.
    code(): string {
        switch (this.kind) {
            case RenderErrorKind.NoAdapter: return "no-adapter";
            case RenderErrorKind.Device: return "device";
            case RenderErrorKind.Io: return "io";
            case RenderErrorKind.Encode: return "png";
            default: return "invalid-argument";
        }
    }

    // PLAN §2: 3 for I/O and GPU-availability failures, 1 for bad arguments.
    exitCode(): i32 {
        switch (this.kind) {
            case RenderErrorKind.NoAdapter:
            case RenderErrorKind.Device:
            case RenderErrorKind.Io:
            case RenderErrorKind.Encode:
                return 3;
            default:
                return 1;
        }
    }
}

// The typed RenderError behind a failed result, or null.
export function renderErrorOf<T>(r: Result<T>): RenderError? {
    const c = r.cause;
    if (c == null) return null;
    const isRender = c instanceof RenderError;
    if (isRender) return c as RenderError;
    return null;
}
