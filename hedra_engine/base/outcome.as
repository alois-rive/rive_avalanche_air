// What an operation ends with, as data: a failure (its code, message, hint
// and exit code) or a successful answer (its message, warnings, JSON fields
// and text form). Printing them is the host's business (the answer
// convention: JSON when stdout is not a terminal, text on a terminal); the
// code that turns sources into built files and the commands that run it
// only make them, so both sides import this module and neither imports the
// other.
//
// Exit codes: 0 done, 1 a command error (a bad flag or argument), 2 a
// scene that cannot be loaded or used, 3 the device or I/O (a file that
// could not be written among them).

import { ErrorValue, Result } from "./util";
import { JsonMap } from "./json";

export const EXIT_USAGE: i32 = 1;
export const EXIT_SCENE: i32 = 2;
// Rendering's device and I/O errors (RenderError.exitCode), and a file the
// program could not write.
export const EXIT_IO: i32 = 3;

// A failed command: what the host prints and the exit code it returns.
export class Failure extends ErrorValue {
    code: string;
    message: string;
    hint: string?;
    exit: i32;

    constructor(code: string, message: string, hint: string?, exit: i32) {
        super();
        this.code = code;
        this.message = message;
        this.hint = hint;
        this.exit = exit;
    }

    // A command error: a bad flag or argument (exit 1).
    static command(message: string, hint: string?): Failure {
        return new Failure("command", message, hint, EXIT_USAGE);
    }

    fail<T>(): Result<T> {
        return Result.failWith<T>(this);
    }

    toString(): string {
        return this.message;
    }
}

// A command's successful answer (every command but `render`, which keeps
// its RenderAnswer, answers with one): its message and warnings, its own
// JSON fields in order, and what the text form prints.
export class Answer {
    message: string = "";
    warnings: Array<string> = [];
    // The command's own JSON fields, in order (after the common ones).
    data: JsonMap = new JsonMap();
    // What the text form prints on stdout instead of the message (a tree, a
    // file's text, a list of problems), exactly, with its own line ends;
    // null: the message and a newline.
    text: string? = null;
    // The exit code of an answer that is not a failure but must not exit 0:
    // `inspect --check` of a scene with errors (2), `format --check` of a
    // file that is not canonical (1). The answer still goes to stdout.
    exit: i32 = 0;

    constructor(message: string) {
        this.message = message;
    }
}
