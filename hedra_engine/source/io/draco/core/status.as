// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// DracoError, its ErrorKind, and Status.
//
//   build an error        DracoError.buffer("x"), DracoError.create(kind, msg)
//   fail with it          e.fail<T>()  (Result.failWith<T>(e))
//   success / no value    Status = Result<bool>, ok value `true`: okStatus()
//   read it               e.kind() / e.message() / e.toString() (also Result.err)
//   debug text            e.debug()
//   branch on the kind    const e = dracoErrorOf(r); if (e != null) switch (e.kind()) …
//   add context           e.context(ctx)   (ctx is the display text)

import { ErrorValue, Result } from "../../../../base/util";
import { debugStr, debugStruct } from "../../../../base/fmt";

// What a DracoError refused.
export enum ErrorKind {
    General,
    Io,
    InvalidParameter,
    UnsupportedVersion,
    UnknownVersion,
    UnsupportedFeature,
    BitstreamVersionUnsupported,
    Buffer,
    AllocationExceedsInput,
    LimitExceeded,
}

// `ErrorKind::as_str`: the fixed text this kind contributes to Display.
export function errorKindAsStr(kind: ErrorKind): string {
    switch (kind) {
        case ErrorKind.General: return "General error";
        case ErrorKind.Io: return "IO error";
        case ErrorKind.InvalidParameter: return "Invalid parameter";
        case ErrorKind.UnsupportedVersion: return "Unsupported version";
        case ErrorKind.UnknownVersion: return "Unknown version";
        case ErrorKind.UnsupportedFeature: return "Unsupported feature";
        case ErrorKind.BitstreamVersionUnsupported: return "Bitstream version unsupported";
        case ErrorKind.Buffer: return "Buffer decode error";
        case ErrorKind.AllocationExceedsInput: return "Allocation exceeds input";
        case ErrorKind.LimitExceeded: return "Decode limit exceeded";
    }
    return "";
}

// `{:?}` of an ErrorKind (the variant name).
export function errorKindDebug(kind: ErrorKind): string {
    switch (kind) {
        case ErrorKind.General: return "General";
        case ErrorKind.Io: return "Io";
        case ErrorKind.InvalidParameter: return "InvalidParameter";
        case ErrorKind.UnsupportedVersion: return "UnsupportedVersion";
        case ErrorKind.UnknownVersion: return "UnknownVersion";
        case ErrorKind.UnsupportedFeature: return "UnsupportedFeature";
        case ErrorKind.BitstreamVersionUnsupported: return "BitstreamVersionUnsupported";
        case ErrorKind.Buffer: return "Buffer";
        case ErrorKind.AllocationExceedsInput: return "AllocationExceedsInput";
        case ErrorKind.LimitExceeded: return "LimitExceeded";
    }
    return "";
}

// Error returned by Draco decoding, encoding, and data model operations.
export class DracoError extends ErrorValue {
    private kind_: ErrorKind;
    private message_: string;

    constructor(kind: ErrorKind, message: string) {
        super();
        this.kind_ = kind;
        this.message_ = message;
    }

    // An error of `kind` with `message`.
    static create(kind: ErrorKind, message: string): DracoError {
        return new DracoError(kind, message);
    }

    kind(): ErrorKind {
        return this.kind_;
    }

    // The message alone, without the fixed text ErrorKind adds.
    message(): string {
        return this.message_;
    }

    static general(message: string): DracoError {
        return new DracoError(ErrorKind.General, message);
    }
    static io(message: string): DracoError {
        return new DracoError(ErrorKind.Io, message);
    }
    static invalidParameter(message: string): DracoError {
        return new DracoError(ErrorKind.InvalidParameter, message);
    }
    static unsupportedVersion(message: string): DracoError {
        return new DracoError(ErrorKind.UnsupportedVersion, message);
    }
    static unknownVersion(message: string): DracoError {
        return new DracoError(ErrorKind.UnknownVersion, message);
    }
    static unsupportedFeature(message: string): DracoError {
        return new DracoError(ErrorKind.UnsupportedFeature, message);
    }
    static bitstreamVersionUnsupported(): DracoError {
        return new DracoError(ErrorKind.BitstreamVersionUnsupported, "");
    }
    static buffer(message: string): DracoError {
        return new DracoError(ErrorKind.Buffer, message);
    }

    // Prefixes this error's message with `context` (its Display text),
    // keeping its kind.
    context(context: string): DracoError {
        const message = this.message_.length == 0 ? context : context + ": " + this.message_;
        return new DracoError(this.kind_, message);
    }

    static allocationExceedsInput(requestedBytes: u64, streamBytes: u64): DracoError {
        return new DracoError(
            ErrorKind.AllocationExceedsInput,
            "would allocate " + requestedBytes.toString() + " bytes from a " + streamBytes.toString() + " byte stream",
        );
    }

    // A failed Result<T> carrying this error.
    fail<T>(): Result<T> {
        return Result.failWith<T>(this);
    }

    // Equal when kind and message are.
    equals(other: DracoError): bool {
        return this.kind_ == other.kind_ && this.message_ == other.message_;
    }

    clone(): DracoError {
        return new DracoError(this.kind_, this.message_);
    }

    // Display.
    toString(): string {
        if (this.message_.length == 0) return errorKindAsStr(this.kind_);
        return errorKindAsStr(this.kind_) + ": " + this.message_;
    }

    // Debug: `DracoError { kind: Buffer, message: "…" }`.
    debug(): string {
        return debugStruct("DracoError", ["kind", "message"], [errorKindDebug(this.kind_), debugStr(this.message_)]);
    }
}

// A result with no value: a Result<bool> whose Ok value is true.
export type Status = Result<bool>;

// Returns a successful Status.
export function okStatus(): Status {
    return Result.okv<bool>(true);
}

// Creates a generic DracoError from a message.
export function errorStatus(msg: string): DracoError {
    return DracoError.general(msg);
}

// The error for a failure with no detail.
export function dracoErrorFromUnit(): DracoError {
    return DracoError.general("Unknown error");
}

// The typed DracoError of a failed Result, or null (Ok, or a plain-string / other error).
export function dracoErrorOf<T>(r: Result<T>): DracoError? {
    if (r.ok) return null;
    const c = r.cause;
    if (c == null) return null;
    const isDraco = c instanceof DracoError;
    if (isDraco) return c as DracoError;
    return null;
}
