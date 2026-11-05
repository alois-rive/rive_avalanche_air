// The process environment of one program run: file system,
// environment variables, working directory, stdin and whether the streams
// are terminals. A script cannot touch any of these, so every file system,
// environment and stdin access of the app goes through the process-wide
// `vfs` instead, and the host (CONTRACT.md §8) fills it with facts
// (host/facts.as replays them before each run).
//
// Two modes:
// - closed world (`complete = true`, tests and closed-world hosts): the VFS
//   is the whole file system; a path it does not know is absent, and no
//   need is ever recorded.
// - open world (`complete = false`, the CLI): the VFS knows only what the
//   host told it. Touching a path whose state is unknown records a *need*
//   and answers as if it were absent. A need names what the operation wants
//   to learn: `stat` (what is there), `read` (a file's bytes: `read` of an
//   unknown path asks for them at once), `list` (a directory's entries), or
//   `stdin`. The host answers every need from the real disk and the
//   invocation runs again from scratch; nothing is written to disk until a
//   run finishes with no needs left, so the final run saw exactly the real
//   disk.
//
// Writes change the in-memory state and are journaled as ops (write, append,
// mkdir, remove, rmdir, rmtree, rename, chmod), the contract's effects, which
// the host applies to the disk in order after the final run (facts.as
// writes them as messages).
//
// Error texts are the macOS error message with its errno ("No such file or
// directory (os error 2)", …) on every OS, and `kind` classifies it
// (IoErrorKind).
//
// Paths are keyed by their lexical absolute form, the contract path
// (CONTRACT.md §4), but every operation first checks what the OS would check
// on the path as written: a `..` needs the part before it to be an existing
// directory, and a trailing `/` or `/.` needs the target to be a directory
// (as on macOS).
//
// The platform (`start.platform.os`, given to `reset`) picks the path rules
// (path.as): on Windows the app writes and reads native paths (`C:\x`,
// `sub\x`, `\x`), `currentDir` and `canonicalize` answer native paths, a
// `..` is resolved lexically before the file system sees the path (as
// Win32 does), and environment variable names ignore case.

import { ErrorValue, Result, stableSort, cmpStr, toAsciiUppercase } from "../base/util";
import {
    isAbsolute, join, nativePath, normalizeAbs, parent, resolveAgainst, setWindowsPaths, usesWindowsPaths,
} from "./path";

// ---------------------------------------------------------------------------
// I/O errors

export enum IoErrorKind {
    NotFound,
    PermissionDenied,
    AlreadyExists,
    NotADirectory,
    IsADirectory,
    DirectoryNotEmpty,
    InvalidInput,
    InvalidData,
    Other,
}

export class IoError extends ErrorValue {
    kind: IoErrorKind;
    message: string;

    constructor(kind: IoErrorKind, message: string) {
        super();
        this.kind = kind;
        this.message = message;
    }

    // An OS error, displayed as `{strerror} (os error {code})` (macOS errno).
    static os(kind: IoErrorKind): IoError {
        let text = "Unknown error";
        let code = 0;
        switch (kind) {
            case IoErrorKind.NotFound: text = "No such file or directory"; code = 2; break;
            case IoErrorKind.PermissionDenied: text = "Permission denied"; code = 13; break;
            case IoErrorKind.AlreadyExists: text = "File exists"; code = 17; break;
            case IoErrorKind.NotADirectory: text = "Not a directory"; code = 20; break;
            case IoErrorKind.IsADirectory: text = "Is a directory"; code = 21; break;
            case IoErrorKind.InvalidInput: text = "Invalid argument"; code = 22; break;
            case IoErrorKind.DirectoryNotEmpty: text = "Directory not empty"; code = 66; break;
            default: break;
        }
        return new IoError(kind, text + " (os error " + code.toString() + ")");
    }

    // EPERM: "Operation not permitted (os error 1)" (PermissionDenied).
    static eperm(): IoError {
        return new IoError(IoErrorKind.PermissionDenied, "Operation not permitted (os error 1)");
    }

    toString(): string {
        return this.message;
    }

    fail<T>(): Result<T> {
        return Result.failWith<T>(this);
    }
}

// The IoError of a failed VFS result (null when it is not an IoError).
export function ioErrorOf<T>(r: Result<T>): IoError? {
    if (r.ok) return null;
    const c = r.cause;
    if (c == null) return null;
    const isIo = c instanceof IoError;
    if (isIo) return c as IoError;
    return null;
}

// `readToString` on bytes that are not UTF-8.
export const INVALID_UTF8 = "stream did not contain valid UTF-8";

// Whether `b` is well-formed UTF-8 (no overlongs, surrogates or code points
// above U+10FFFF).
export function isValidUtf8(b: Uint8Array): bool {
    const n = b.length;
    let i = 0;
    while (i < n) {
        const c = <u32>b[i];
        if (c < 0x80) {
            i++;
            continue;
        }
        let need = 0;
        let min: u32 = 0;
        let cp: u32 = 0;
        if (c >= 0xc2 && c <= 0xdf) { need = 1; cp = c & 0x1f; min = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { need = 2; cp = c & 0x0f; min = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { need = 3; cp = c & 0x07; min = 0x10000; }
        else return false;
        if (i + need >= n) return false;
        for (let k = 1; k <= need; k++) {
            const d = <u32>b[i + k];
            if ((d & 0xc0) != 0x80) return false;
            cp = (cp << 6) | (d & 0x3f);
        }
        if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return false;
        i += need + 1;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Nodes

export enum NodeKind {
    Absent,
    File,
    Dir,
    Other, // exists, neither a regular file nor a directory (fifo, socket, …)
}

export class Node {
    kind: NodeKind;
    data: Uint8Array? = null; // File: content, null while unknown
    size: i64 = -1; // File: length when known without the content
    listed: bool = false; // Dir: every child is known
    readable: bool = true;
    // access(W_OK), as the host reported it: a file
    // that cannot be opened for writing, a directory in which nothing can be
    // created, removed or renamed (EACCES). Unknown nodes are writable.
    writable: bool = true;
    real: string? = null; // canonical path reported by the host
    // The host reported this very path, so its canonical form is known:
    // `real`, or the path itself when `real` is null.
    realKnown: bool = false;
    // Absent: the error the path, and every path below it, gives. The
    // host's `reason` (§6): ENOENT (NotFound), ENOTDIR (a component on the
    // way is not a directory: NotADirectory) or EACCES (the path cannot be
    // looked up: PermissionDenied).
    absentError: IoErrorKind = IoErrorKind.NotFound;
    // Created by this run (or the cwd chain): not a symlink, so its canonical
    // form is its parent's plus its name.
    notLink: bool = false;

    constructor(kind: NodeKind) {
        this.kind = kind;
    }
}

// A node's metadata (the parts the app reads).
export class Metadata {
    kind: NodeKind;
    len: u64;

    constructor(kind: NodeKind, len: u64) {
        this.kind = kind;
        this.len = len;
    }

    isFile(): bool {
        return this.kind == NodeKind.File;
    }

    isDir(): bool {
        return this.kind == NodeKind.Dir;
    }
}

export class Op {
    op: string;
    path: string;
    to: string = "";
    data: Uint8Array? = null;
    mode: u32 = 0;
    // A `write` whose bytes are the PNG of this capture (a render output,
    // §10), -1 for a plain write. `data` then holds the empty placeholder
    // the run saw. Set by `Vfs.tagCapture`.
    capture: i32 = -1;

    constructor(op: string, path: string) {
        this.op = op;
        this.path = path;
    }
}

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
}

function parentKey(abs: string): string? {
    if (abs == "/") return null;
    const i = abs.lastIndexOf("/");
    return i <= 0 ? "/" : abs.substring(0, i);
}

// Milestone 41: where the files under a root come from when they are
// neither nodes nor mounted (Vfs.setReadFallback): a scene drawn from its
// text in a Rive project reads its .rscn and assets from the project's
// declared blobs (hedra_engine/scene's text source). `rel` is the path under the
// root ("props/fountain.rscn"); null when there is no such file.
export abstract class VfsReadFallback {
    abstract read(rel: string): Uint8Array?;
}

// One root's fallback, and the paths it had no file for (asked once).
class FallbackRoot {
    root: string;
    prefix: string;
    f: VfsReadFallback;
    misses: Set<string> = new Set<string>();
    // The absolute paths it mounted (unmounted when it is replaced).
    mounted: Array<string> = [];
    dir: Node;

    constructor(root: string, f: VfsReadFallback) {
        this.root = root;
        this.prefix = root == "/" ? "/" : root + "/";
        this.f = f;
        const d = new Node(NodeKind.Dir);
        d.notLink = true;
        this.dir = d;
    }
}

// ---------------------------------------------------------------------------
// The VFS

export class Vfs {
    cwd: string = "/";
    complete: bool = true;
    nodes: Map<string, Node> = new Map<string, Node>();
    ops: Array<Op> = [];
    needs: Array<string> = []; // "stat:/abs", "read:/abs", "list:/abs", "stdin:"
    needSet: Set<string> = new Set<string>();

    env: Map<string, string> = new Map<string, string>();
    stdinIsTerminal: bool = false; // isatty(0)
    stdoutIsTerminal: bool = false; // isatty(1): the default output format
    stderrIsTerminal: bool = false; // isatty(2): style global-flag errors
    argv0: string = ""; // argv[0] as invoked: the usage name ("": the program's own)
    stdinKnown: bool = true; // closed world: stdin is `stdinData` (empty by default)
    stdinData: Uint8Array = new Uint8Array(0);
    stdinRead: bool = false;
    // `start.platform.os`: "macos", "linux", "windows", or anything else
    // ("web"); "" when nobody said (tests).
    os: string = "";
    // `start.pid`, the host's process id: -1 when not given.
    pid: i64 = -1;
    // When not null, every successful `read` (and so `readToString`) of a
    // file appends its absolute path, once: the CLI's `build --pack` sets it
    // while loading a scene to learn every file the scene needs. Left alone
    // by `reset`; nobody else sets it.
    readLog: Array<string>? = null;
    // Files mounted over the file system (`mount`), by absolute path.
    private mounts: Map<string, Node> = new Map<string, Node>();
    // Milestone 41: the read fallbacks (setReadFallback), by root.
    private fallbacks: Array<FallbackRoot> = [];

    // Forget everything: a fresh process on `os` in `cwd` (a contract path).
    reset(cwd: string, complete: bool, os: string = ""): void {
        this.os = os;
        setWindowsPaths(os == "windows");
        this.pid = -1;
        this.cwd = normalizeAbs(cwd);
        this.complete = complete;
        this.nodes = new Map<string, Node>();
        this.mounts = new Map<string, Node>();
        this.fallbacks = [];
        this.ops = [];
        this.needs = [];
        this.needSet = new Set<string>();
        this.env = new Map<string, string>();
        this.stdinIsTerminal = false;
        this.stdoutIsTerminal = false;
        this.stderrIsTerminal = false;
        this.argv0 = "";
        this.stdinKnown = complete;
        this.stdinData = new Uint8Array(0);
        this.stdinRead = false;
        this.markDir("/");
        this.markDir(this.cwd);
        // getcwd() is a physical path: no symlink on the way
        let cur: string? = this.cwd;
        while (cur != null) {
            const key: string = cur;
            this.nodes.get(key).notLink = true;
            cur = parentKey(key);
        }
    }

    // Absolute, lexically normalized key of a (possibly relative) path: its
    // contract path (a native Windows path becomes `/C:/…`). The empty path
    // stays "" (every operation on it is NotFound).
    resolve(p: string): string {
        return resolveAgainst(this.cwd, p);
    }

    // Whether this is a Windows process (the path rules and environment
    // names follow).
    get windows(): bool {
        return this.os == "windows";
    }

    // --- seeding (tests and the host's facts) --------------------------------

    // Marks `abs` and every ancestor as a directory (unless known otherwise).
    markDir(abs: string): Node {
        let cur: string? = abs;
        let first: Node? = null;
        while (cur != null) {
            const key: string = cur;
            if (this.nodes.has(key)) {
                const n = this.nodes.get(key);
                if (first == null) first = n;
                if (n.kind == NodeKind.Dir) break;
                if (key != abs) break; // an ancestor known as something else: leave it
                n.kind = NodeKind.Dir;
                n.data = null;
            } else {
                const n = new Node(NodeKind.Dir);
                this.nodes.set(key, n);
                if (first == null) first = n;
            }
            cur = parentKey(key);
        }
        return first!;
    }

    // An existing node implies that its ancestors are directories; an absent
    // one implies nothing about them.
    private setNode(abs: string, n: Node): void {
        const par = parentKey(abs);
        if (par != null && n.kind != NodeKind.Absent) this.markDir(par);
        this.nodes.set(abs, n);
    }

    addFile(path: string, data: Uint8Array): void {
        const n = new Node(NodeKind.File);
        n.data = data;
        n.size = data.length;
        this.setNode(this.resolve(path), n);
    }

    // A file read from somewhere other than the file system (the files a
    // Hedra packed scene embeds): found at `path` over whatever the host
    // says is there, but implying nothing about the directories above it,
    // which stay as the host reports them. Unlike `addFile`, a directory
    // that holds only mounted files is not taken to exist, so a write into
    // it still creates it, and `readDir` does not list mounted files. Kept
    // until the next `reset`.
    mount(path: string, data: Uint8Array): void {
        const n = new Node(NodeKind.File);
        n.data = data;
        n.size = data.length;
        n.notLink = true;
        this.mounts.set(this.resolve(path), n);
    }

    // Milestone 67b: takes out the file mounted at `path` when it is `data`
    // (the same bytes object: what a load mounted, which another mount
    // may have replaced since), putting back `previous` when it is not
    // null; whether it did. A load given up lets go of its built file's
    // bytes so (../scene/bundle/provider.as BundleResources.unmount).
    unmount(path: string, data: Uint8Array, previous: Uint8Array? = null): bool {
        const abs = this.resolve(path);
        if (!this.mounts.has(abs) || this.mounts.get(abs).data !== data) return false;
        if (previous != null) this.mount(abs, previous);
        else this.mounts.delete(abs);
        return true;
    }

    // Milestone 41: files under `root` (an absolute path) that are neither
    // nodes nor mounted are asked of `f` (null removes the root's fallback):
    // `read`, `exists`, `isFile` and `metadata` of such a path call
    // `f.read` with the path under the root, mount the bytes it gives (so
    // it is asked once per file) and answer with them; a path it has no
    // file for is absent, and is not asked again. The root itself is a
    // directory; `readDir` is not served (a fallback cannot list). The
    // longest root holding a path answers for it. Kept until the next
    // `reset`, as mounts are.
    setReadFallback(root: string, f: VfsReadFallback?): void {
        const abs = this.resolve(root);
        for (let i = 0; i < this.fallbacks.length; i++) {
            const had = this.fallbacks[i];
            if (had.root != abs) continue;
            if (had.f === f) return;
            // (what the old one gave is forgotten: the new one answers anew)
            for (let k = 0; k < had.mounted.length; k++) this.mounts.delete(had.mounted[k]);
            if (f == null) this.fallbacks.splice(i, 1);
            else this.fallbacks[i] = new FallbackRoot(abs, f);
            return;
        }
        if (f != null) this.fallbacks.push(new FallbackRoot(abs, f));
    }

    // The fallback installed at `root` (setReadFallback), or null.
    readFallback(root: string): VfsReadFallback? {
        const abs = this.resolve(root);
        for (let i = 0; i < this.fallbacks.length; i++) if (this.fallbacks[i].root == abs) return this.fallbacks[i].f;
        return null;
    }

    // Whether a read fallback's root holds `abs` (its answer is final there).
    private underFallback(abs: string): bool {
        for (let i = 0; i < this.fallbacks.length; i++) {
            const fb = unchecked(this.fallbacks[i]);
            if (abs == fb.root || abs.startsWith(fb.prefix)) return true;
        }
        return false;
    }

    // The node a read fallback gives `abs` (mounted on the way), or null.
    private fromFallback(abs: string): Node? {
        const fbs = this.fallbacks;
        if (fbs.length == 0) return null;
        let best: FallbackRoot? = null;
        for (let i = 0; i < fbs.length; i++) {
            const fb = unchecked(fbs[i]);
            if (abs != fb.root && !abs.startsWith(fb.prefix)) continue;
            if (best == null || fb.root.length > best.root.length) best = fb;
        }
        if (best == null) return null;
        if (abs == best.root) return best.dir;
        const rel = abs.substring(best.prefix.length);
        if (best.misses.has(rel)) return null;
        const data = best.f.read(rel);
        if (data == null) {
            best.misses.add(rel);
            return null;
        }
        this.mount(abs, data);
        best.mounted.push(abs);
        return this.mounts.get(abs);
    }

    // The bytes mounted at `path` (`mount`), or null when none are.
    mounted(path: string): Uint8Array? {
        const abs = this.resolve(path);
        return this.mounts.has(abs) ? this.mounts.get(abs).data : null;
    }

    addTextFile(path: string, text: string): void {
        this.addFile(path, Uint8Array.wrap(String.UTF8.encode(text)));
    }

    // A file whose content is not known yet (open world).
    // An already known file keeps its content.
    addFileStub(path: string, size: i64): Node {
        const abs = this.resolve(path);
        if (this.nodes.has(abs)) {
            const old = this.nodes.get(abs);
            if (old.kind == NodeKind.File) {
                if (old.size < 0) old.size = size;
                return old;
            }
        }
        const n = new Node(NodeKind.File);
        n.size = size;
        this.setNode(abs, n);
        return n;
    }

    addDir(path: string): Node {
        return this.markDir(this.resolve(path));
    }

    // Nothing at `path`; looking it (or anything below it) up fails with
    // `why`: NotFound, NotADirectory or PermissionDenied (Node.absentError).
    addAbsent(path: string, why: IoErrorKind = IoErrorKind.NotFound): void {
        const n = new Node(NodeKind.Absent);
        n.absentError = why;
        this.setNode(this.resolve(path), n);
    }

    addOther(path: string): void {
        this.setNode(this.resolve(path), new Node(NodeKind.Other));
    }

    setStdin(data: Uint8Array): void {
        this.stdinKnown = true;
        this.stdinData = data;
    }

    // --- needs --------------------------------------------------------------

    // Records a need (`what`: stat, read, list or stdin), once. A `read` or
    // `list` answer tells what a `stat` answer would, so a `stat` of the
    // same path is left out (or replaced, in its place). A closed world
    // records nothing: every fact is already there.
    private need(what: string, abs: string): void {
        if (this.complete) return;
        const key = what + ":" + abs;
        if (this.needSet.has(key)) return;
        if (what == "stat") {
            if (this.needSet.has("read:" + abs) || this.needSet.has("list:" + abs)) return;
        } else if (what == "read" || what == "list") {
            const stat = "stat:" + abs;
            if (this.needSet.has(stat)) {
                this.needs[this.needs.indexOf(stat)] = key;
                this.needSet.delete(stat);
                this.needSet.add(key);
                return;
            }
        }
        this.needSet.add(key);
        this.needs.push(key);
    }

    // True when the open-world run touched something unknown: its results
    // must be discarded and the invocation run again with the answers.
    get incomplete(): bool {
        return this.needs.length > 0;
    }

    // --- lookup -------------------------------------------------------------

    // The state of `abs`. Unknown paths are Absent (and, in the open world,
    // recorded as a need: `want`, what the caller is after). A missing or
    // non-directory ancestor makes the answer the matching traversal error
    // (`errKind`), and so does an absent node: its `absentError`.
    private errKind: IoErrorKind = IoErrorKind.NotFound;

    private lookup(abs: string, want: string = "stat"): Node? {
        this.errKind = IoErrorKind.NotFound;
        if (abs.length == 0) return null;
        if (this.mounts.has(abs)) return this.mounts.get(abs);
        if (this.nodes.has(abs)) {
            const n = this.nodes.get(abs);
            if (n.kind == NodeKind.Absent) this.errKind = n.absentError;
            return n;
        }
        // (milestone 41: a root's read fallback answers for what is under it)
        if (this.fallbacks.length > 0) {
            const fb = this.fromFallback(abs);
            if (fb != null) return fb;
            if (this.underFallback(abs)) return null;
        }
        // ancestors: the nearest known one decides
        let cur = parentKey(abs);
        while (cur != null) {
            const key: string = cur;
            if (this.nodes.has(key)) {
                const a = this.nodes.get(key);
                if (a.kind == NodeKind.File || a.kind == NodeKind.Other) {
                    this.errKind = IoErrorKind.NotADirectory;
                    return null;
                }
                if (a.kind == NodeKind.Absent) {
                    this.errKind = a.absentError;
                    return null;
                }
                // a directory: its listing (or a closed world) settles the
                // child on the way down, which is not a node, so absent
                if (a.listed || this.complete) return null;
                break;
            }
            cur = parentKey(key);
        }
        if (this.complete) return null;
        this.need(want, abs);
        return null;
    }

    private kindOf(abs: string): NodeKind {
        const n = this.lookup(abs);
        return n == null ? NodeKind.Absent : n.kind;
    }

    // The OS's checks on the path as written, which the lexical key loses:
    // each `..` needs the part before it to be an existing directory
    // (`nope/../f` is NotFound, `file/../f` NotADirectory). Returns the
    // error kind, or -1. Windows resolves `..` lexically before the file
    // system sees the path (GetFullPathName), so there is nothing to check.
    private dotDotError(p: string): i32 {
        if (p.indexOf("..") < 0 || usesWindowsPaths()) return -1;
        let prefix = isAbsolute(p) ? "/" : this.cwd;
        const n = p.length;
        let i = 0;
        while (i <= n) {
            let j = i;
            while (j < n && p.charCodeAt(j) != 47) j++;
            const piece = p.substring(i, j);
            if (piece == "..") {
                const k = this.kindOf(prefix);
                if (k == NodeKind.Absent) return <i32>this.errKind;
                if (k != NodeKind.Dir) return <i32>IoErrorKind.NotADirectory;
                const up = parentKey(prefix);
                prefix = up != null ? up : "/";
            } else if (piece.length > 0 && piece != ".") {
                prefix = prefix == "/" ? "/" + piece : prefix + "/" + piece;
            }
            i = j + 1;
        }
        return -1;
    }

    // `path/` or `path/.` (Windows: `\` too): the OS wants a directory there.
    private static dirOnly(p: string): bool {
        if (p.endsWith("/") || p.endsWith("/.")) return true;
        return usesWindowsPaths() && (p.endsWith("\\") || p.endsWith("\\."));
    }

    // The node `path` names as the OS would resolve it: null when it does not
    // exist or cannot be reached, with the error kind in `errKind` (NotFound,
    // or NotADirectory for a file on the way or before a trailing `/`).
    // `unreachable` is set when the path itself is wrong (empty, or a `..`
    // that fails), as opposed to a missing final node that could be created.
    // `want` is the need an unknown final node records (lookup).
    private unreachable: bool = false;

    private stat(path: string, want: string = "stat"): Node? {
        this.errKind = IoErrorKind.NotFound;
        this.unreachable = true;
        if (path.length == 0) return null;
        const e = this.dotDotError(path);
        if (e >= 0) {
            this.errKind = <IoErrorKind>e;
            return null;
        }
        this.unreachable = false;
        const n = this.lookup(this.resolve(path), want);
        if (n == null || n.kind == NodeKind.Absent) return null;
        if (n.kind != NodeKind.Dir && Vfs.dirOnly(path)) {
            this.errKind = IoErrorKind.NotADirectory;
            return null;
        }
        return n;
    }

    private statKind(path: string): NodeKind {
        const n = this.stat(path);
        return n == null ? NodeKind.Absent : n.kind;
    }

    // --- path queries --------------------------------------------------------

    // Whether anything is at `path`.
    exists(path: string): bool {
        return this.statKind(path) != NodeKind.Absent;
    }

    // Whether `path` is a file.
    isFile(path: string): bool {
        return this.statKind(path) == NodeKind.File;
    }

    // Whether `path` is a directory.
    isDir(path: string): bool {
        return this.statKind(path) == NodeKind.Dir;
    }

    // The metadata of `path` (symlinks followed).
    metadata(path: string): Result<Metadata> {
        const abs = this.resolve(path);
        const n = this.stat(path);
        if (n == null) return IoError.os(this.errKind).fail<Metadata>();
        let len: u64 = 0;
        if (n.kind == NodeKind.File) {
            const d = n.data;
            if (d != null) len = <u64>d.length;
            else if (n.size >= 0) len = <u64>n.size;
            else this.need("stat", abs); // (a listing entry without a size)
        }
        return Result.okv<Metadata>(new Metadata(n.kind, len));
    }

    // The canonical absolute path: every symlink resolved. The nearest node on
    // the way up whose canonical form is known (reported by the host, or
    // the cwd chain) gives the base, and the names below it are appended.
    // In the open world a node that might be a symlink (an ancestor implied
    // by a child, or a listing entry) is asked about as a stat need. macOS
    // realpath accepts a trailing `/` after a file. The answer is the native
    // spelling (Windows: `C:\x`, never a verbatim `\\?\` path).
    canonicalize(path: string): Result<string> {
        const abs = this.resolve(path);
        let n: Node? = null;
        this.errKind = IoErrorKind.NotFound;
        if (path.length > 0) {
            const e = this.dotDotError(path);
            if (e >= 0) return IoError.os(<IoErrorKind>e).fail<string>();
            n = this.lookup(abs);
        }
        if (n == null || n.kind == NodeKind.Absent) return IoError.os(this.errKind).fail<string>();
        const names: Array<string> = [];
        let base = abs;
        let cur: string? = abs;
        while (cur != null) {
            const key: string = cur;
            if (!this.nodes.has(key)) {
                // not a node (a closed world's implicit directory): as is
                base = key;
                break;
            }
            const m = this.nodes.get(key);
            const real = m.real;
            if (real != null) {
                base = real;
                break;
            }
            if (m.realKnown || key == "/") {
                base = key;
                break;
            }
            if (!m.notLink) {
                if (!this.complete) this.need("stat", key);
                base = key;
                break;
            }
            const up = parentKey(key);
            names.push(key.substring(up == "/" ? 1 : up!.length + 1));
            cur = up;
        }
        let out = base;
        for (let i = names.length - 1; i >= 0; i--) out = out == "/" ? "/" + names[i] : out + "/" + names[i];
        return Result.okv<string>(nativePath(out));
    }

    // The working directory, spelled natively (Windows: `C:\Users\a`; the
    // key `cwd` is `/C:/Users/a`).
    currentDir(): string {
        return nativePath(this.cwd);
    }

    // --- reads --------------------------------------------------------------

    // The file's bytes: a fresh copy the caller owns. An unknown path is
    // asked for with its bytes (a `read` need), so one answer settles it.
    // A closed world's file without bytes cannot be read (EACCES): the host
    // gave everything the program may use.
    read(path: string): Result<Uint8Array> {
        const abs = this.resolve(path);
        const n = this.stat(path, "read");
        if (n == null) return IoError.os(this.errKind).fail<Uint8Array>();
        if (n.kind == NodeKind.Dir) return IoError.os(IoErrorKind.IsADirectory).fail<Uint8Array>();
        if (!n.readable) return IoError.os(IoErrorKind.PermissionDenied).fail<Uint8Array>();
        const d = n.data;
        if (d == null) {
            if (this.complete) return IoError.os(IoErrorKind.PermissionDenied).fail<Uint8Array>();
            this.need("read", abs);
            return IoError.os(IoErrorKind.NotFound).fail<Uint8Array>();
        }
        const log = this.readLog;
        if (log != null && !log.includes(abs)) log.push(abs);
        return Result.okv<Uint8Array>(d.slice(0));
    }

    // The file's text (an error when it is not UTF-8).
    readToString(path: string): Result<string> {
        const r = this.read(path);
        if (!r.ok) return r.forward<string>();
        if (!isValidUtf8(r.value)) return new IoError(IoErrorKind.InvalidData, INVALID_UTF8).fail<string>();
        return Result.okv<string>(String.UTF8.decode(r.value.buffer.slice(r.value.byteOffset, r.value.byteOffset + r.value.byteLength)));
    }

    // The directory's entries as full paths (`path` as given, joined with
    // each name as path.as `join` does), sorted by name. File systems list in no fixed order;
    // every caller in the app sorts, so sorted is the portable choice. An
    // unknown path is asked for with its entries (a `list` need).
    readDir(path: string): Result<Array<string>> {
        const abs = this.resolve(path);
        const n = this.stat(path, "list");
        if (n == null) return IoError.os(this.errKind).fail<Array<string>>();
        if (n.kind != NodeKind.Dir) return IoError.os(IoErrorKind.NotADirectory).fail<Array<string>>();
        if (!n.readable) return IoError.os(IoErrorKind.PermissionDenied).fail<Array<string>>();
        if (!n.listed && !this.complete) {
            this.need("list", abs);
            return Result.okv<Array<string>>([]);
        }
        const names: Array<string> = [];
        const prefix = abs == "/" ? "/" : abs + "/";
        const keys = this.nodes.keys();
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i];
            if (k.length <= prefix.length || !k.startsWith(prefix)) continue;
            const rest = k.substring(prefix.length);
            if (rest.indexOf("/") >= 0) continue;
            if (this.nodes.get(k).kind == NodeKind.Absent) continue;
            names.push(rest);
        }
        stableSort<string>(names, cmpStr);
        const out: Array<string> = [];
        if (usesWindowsPaths()) {
            for (let i = 0; i < names.length; i++) out.push(join(path, names[i]));
            return Result.okv<Array<string>>(out);
        }
        const base = path.length > 0 && path.charCodeAt(path.length - 1) == 47 ? path : path + "/";
        for (let i = 0; i < names.length; i++) out.push(base + names[i]);
        return Result.okv<Array<string>>(out);
    }

    // The whole of stdin as text the first time,
    // then "" (end of file).
    readStdin(): Result<string> {
        if (!this.stdinKnown) {
            this.need("stdin", "");
            return Result.okv<string>("");
        }
        if (this.stdinRead) return Result.okv<string>("");
        this.stdinRead = true;
        const d = this.stdinData;
        if (!isValidUtf8(d)) return new IoError(IoErrorKind.InvalidData, INVALID_UTF8).fail<string>();
        return Result.okv<string>(String.UTF8.decode(d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength)));
    }

    // Like `readStdin`, as raw bytes (a fresh copy), for readers that split
    // lines themselves (the `shell`).
    readStdinBytes(): Result<Uint8Array> {
        if (!this.stdinKnown) {
            this.need("stdin", "");
            return Result.okv<Uint8Array>(new Uint8Array(0));
        }
        if (this.stdinRead) return Result.okv<Uint8Array>(new Uint8Array(0));
        this.stdinRead = true;
        return Result.okv<Uint8Array>(this.stdinData.slice(0));
    }

    // --- environment ----------------------------------------------------------

    // The environment variable `name`, or null when it is unset. Windows
    // names ignore case (`SystemRoot` is `SYSTEMROOT`): they are kept
    // upper-cased.
    envVar(name: string): string? {
        const key = this.windows ? toAsciiUppercase(name) : name;
        return this.env.has(key) ? this.env.get(key) : null;
    }

    setEnv(name: string, value: string): void {
        this.env.set(this.windows ? toAsciiUppercase(name) : name, value);
    }

    // --- writes ---------------------------------------------------------------

    // A file this run creates at `abs` (not a symlink).
    private newFile(abs: string, data: Uint8Array): Node {
        const f = new Node(NodeKind.File);
        f.data = data;
        f.size = data.length;
        f.notLink = true;
        this.nodes.set(abs, f);
        return f;
    }

    // A directory this run creates at `abs` (so every child is known).
    private newDir(abs: string): void {
        const d = new Node(NodeKind.Dir);
        d.listed = true;
        d.notLink = true;
        this.nodes.set(abs, d);
    }

    // The target of a create (`open(O_CREAT)`): the existing node, or null
    // with `errKind` when it cannot be created there (an absent target
    // named with a trailing `/` is NotFound). `ok` tells the two nulls apart.
    private createOk: bool = false;

    private createTarget(path: string, abs: string): Node? {
        this.createOk = false;
        const n = this.stat(path);
        if (n != null) {
            this.createOk = true;
            return n;
        }
        if (this.unreachable || this.errKind != IoErrorKind.NotFound) return null;
        if (Vfs.dirOnly(path)) return null;
        const e = this.checkParent(abs);
        if (e != null) {
            this.errKind = e.kind;
            return null;
        }
        this.createOk = true;
        return null;
    }

    // The parent of `abs` must be an existing directory.
    private checkParent(abs: string): IoError? {
        if (abs.length == 0) return IoError.os(IoErrorKind.NotFound);
        const par = parentKey(abs);
        if (par == null) return IoError.os(IoErrorKind.IsADirectory);
        const n = this.lookup(par);
        if (n == null || n.kind == NodeKind.Absent) return IoError.os(this.errKind);
        if (n.kind != NodeKind.Dir) return IoError.os(IoErrorKind.NotADirectory);
        return null;
    }

    // Whether `abs`'s parent directory is known to deny writing (EACCES for
    // a create, unlink, rmdir or rename in it).
    private parentDenied(abs: string): bool {
        const par = parentKey(abs);
        if (par == null || !this.nodes.has(par)) return false;
        return !this.nodes.get(par).writable;
    }

    private journal(op: Op): void {
        const k = this.ops.length;
        // mkdir ops are applied as `mkdir -p`: a child's covers its parent's
        if (k > 0 && op.op == "mkdir" && this.ops[k - 1].op == "mkdir" && op.path.startsWith(this.ops[k - 1].path + "/")) {
            this.ops[k - 1] = op;
            return;
        }
        if (k > 0 && (op.op == "write" || op.op == "append")) {
            const prev = this.ops[k - 1];
            const pd = prev.data;
            const od = op.data;
            if (prev.path == op.path && pd != null && od != null) {
                if (op.op == "write" && (prev.op == "write" || prev.op == "append")) {
                    this.ops[k - 1] = op;
                    return;
                }
                // (a capture's bytes are the host's PNG, not `pd`: appended
                // bytes follow it as their own op)
                if (op.op == "append" && (prev.op == "write" || prev.op == "append") && prev.capture < 0) {
                    prev.data = concatBytes(pd, od);
                    return;
                }
            }
        }
        this.ops.push(op);
    }

    // Makes the last effect on `path`, the write of a render output's empty
    // placeholder, write the PNG of capture `id` instead (§10: the file is
    // created where the run created it). False, and nothing changes, when
    // the last effect on `path` is not a write.
    tagCapture(path: string, id: i32): bool {
        const abs = this.resolve(path);
        for (let i = this.ops.length - 1; i >= 0; i--) {
            const op = this.ops[i];
            const target = op.op == "rename" ? op.to : op.path;
            if (target != abs && op.path != abs) continue;
            if (op.op != "write") return false;
            op.capture = id;
            return true;
        }
        return false;
    }

    // Writes `data` to `path`: create or truncate.
    write(path: string, data: Uint8Array): Result<bool> {
        const abs = this.resolve(path);
        const n = this.createTarget(path, abs);
        if (!this.createOk) return IoError.os(this.errKind).fail<bool>();
        if (n != null && n.kind == NodeKind.Dir) return IoError.os(IoErrorKind.IsADirectory).fail<bool>();
        if (n != null ? !n.writable : this.parentDenied(abs)) return IoError.os(IoErrorKind.PermissionDenied).fail<bool>();
        const copy = data.slice(0);
        if (n != null && n.kind == NodeKind.File) {
            // truncate in place: a symlink stays one
            n.data = copy;
            n.size = copy.length;
        } else {
            this.newFile(abs, copy);
        }
        const op = new Op("write", abs);
        op.data = copy;
        this.journal(op);
        return Result.okv<bool>(true);
    }

    writeString(path: string, s: string): Result<bool> {
        return this.write(path, Uint8Array.wrap(String.UTF8.encode(s)));
    }

    // Appends `data` to `path`, creating the file when it is missing.
    append(path: string, data: Uint8Array): Result<bool> {
        const abs = this.resolve(path);
        const n = this.createTarget(path, abs);
        if (!this.createOk) return IoError.os(this.errKind).fail<bool>();
        if (n != null && n.kind == NodeKind.Dir) return IoError.os(IoErrorKind.IsADirectory).fail<bool>();
        if (n != null ? !n.writable : this.parentDenied(abs)) return IoError.os(IoErrorKind.PermissionDenied).fail<bool>();
        const copy = data.slice(0);
        if (n == null) {
            this.newFile(abs, copy.slice(0));
        } else if (n.kind == NodeKind.File) {
            const d = n.data;
            if (d != null) {
                n.data = concatBytes(d, copy);
                n.size = n.data!.length;
            } else if (n.size >= 0) {
                n.size += copy.length;
            }
        }
        const op = new Op("append", abs);
        op.data = copy;
        this.journal(op);
        return Result.okv<bool>(true);
    }

    appendString(path: string, s: string): Result<bool> {
        return this.append(path, Uint8Array.wrap(String.UTF8.encode(s)));
    }

    // Creates one directory (the parent must exist).
    createDir(path: string): Result<bool> {
        const abs = this.resolve(path);
        const n = this.stat(path);
        if (n != null) return IoError.os(IoErrorKind.AlreadyExists).fail<bool>();
        if (this.unreachable || this.errKind != IoErrorKind.NotFound) return IoError.os(this.errKind).fail<bool>();
        const e = this.checkParent(abs);
        if (e != null) return e.fail<bool>();
        if (this.parentDenied(abs)) return IoError.os(IoErrorKind.PermissionDenied).fail<bool>();
        this.newDir(abs);
        this.journal(new Op("mkdir", abs));
        return Result.okv<bool>(true);
    }

    // Creates a directory and any missing parents, on the path as written:
    // `mkdir`, and on NotFound the parent first, then `mkdir` again; any
    // other failure is fine when the path is a directory by then.
    createDirAll(path: string): Result<bool> {
        if (path.length == 0) return Result.okv<bool>(true);
        const r = this.createDir(path);
        if (r.ok) return r;
        const e = ioErrorOf<bool>(r);
        if (e == null || e.kind != IoErrorKind.NotFound) {
            if (this.isDir(path)) return Result.okv<bool>(true);
            return r;
        }
        const par = parent(path);
        if (par == null) return new IoError(IoErrorKind.Other, "failed to create whole tree").fail<bool>();
        const pr = this.createDirAll(par);
        if (!pr.ok) return pr;
        const r2 = this.createDir(path);
        if (r2.ok) return r2;
        if (this.isDir(path)) return Result.okv<bool>(true);
        return r2;
    }

    // Removes a file.
    removeFile(path: string): Result<bool> {
        const abs = this.resolve(path);
        const n = this.stat(path);
        if (n == null) return IoError.os(this.errKind).fail<bool>();
        if (n.kind == NodeKind.Dir) return IoError.eperm().fail<bool>(); // unlink(2) on a directory
        if (this.parentDenied(abs)) return IoError.os(IoErrorKind.PermissionDenied).fail<bool>();
        this.nodes.set(abs, new Node(NodeKind.Absent));
        this.journal(new Op("remove", abs));
        return Result.okv<bool>(true);
    }

    // Children of `abs` currently present.
    private presentChildren(abs: string): i32 {
        const prefix = abs == "/" ? "/" : abs + "/";
        const keys = this.nodes.keys();
        let count = 0;
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i];
            if (k.length > prefix.length && k.startsWith(prefix) && this.nodes.get(k).kind != NodeKind.Absent) count++;
        }
        return count;
    }

    // Removes a directory (it must be empty). rmdir(2) needs no read
    // permission, so an unreadable directory (whose entries the host cannot
    // list) is removed if nothing is known in it, and the host's rmdir
    // tells.
    removeDir(path: string): Result<bool> {
        const abs = this.resolve(path);
        const n = this.stat(path, "list");
        if (n == null) return IoError.os(this.errKind).fail<bool>();
        if (n.kind != NodeKind.Dir) return IoError.os(IoErrorKind.NotADirectory).fail<bool>();
        if (this.parentDenied(abs)) return IoError.os(IoErrorKind.PermissionDenied).fail<bool>();
        if (!n.listed && n.readable && !this.complete) {
            this.need("list", abs);
            return IoError.os(IoErrorKind.DirectoryNotEmpty).fail<bool>();
        }
        if (this.presentChildren(abs) > 0) return IoError.os(IoErrorKind.DirectoryNotEmpty).fail<bool>();
        this.dropSubtree(abs);
        this.journal(new Op("rmdir", abs));
        return Result.okv<bool>(true);
    }

    private dropSubtree(abs: string): void {
        const prefix = abs == "/" ? "/" : abs + "/";
        const keys = this.nodes.keys();
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i];
            if (k.length > prefix.length && k.startsWith(prefix)) this.nodes.set(k, new Node(NodeKind.Absent));
        }
        const gone = new Node(NodeKind.Absent);
        this.nodes.set(abs, gone);
    }

    // Removes a directory and everything in it.
    removeDirAll(path: string): Result<bool> {
        const abs = this.resolve(path);
        const n = this.stat(path);
        if (n == null) return IoError.os(this.errKind).fail<bool>();
        if (n.kind != NodeKind.Dir) return IoError.os(IoErrorKind.NotADirectory).fail<bool>();
        if (this.parentDenied(abs)) return IoError.os(IoErrorKind.PermissionDenied).fail<bool>();
        this.dropSubtree(abs);
        this.journal(new Op("rmtree", abs));
        return Result.okv<bool>(true);
    }

    // Renames `from` to `to` (rename(2) semantics for files and empty dirs).
    rename(from: string, to: string): Result<bool> {
        const a = this.resolve(from);
        const b = this.resolve(to);
        const n = this.stat(from);
        if (n == null) return IoError.os(this.errKind).fail<bool>();
        const m = this.stat(to);
        if (m == null && (this.unreachable || this.errKind != IoErrorKind.NotFound)) return IoError.os(this.errKind).fail<bool>();
        const mk = m == null ? NodeKind.Absent : m.kind;
        if (mk == NodeKind.Absent) {
            // `file` -> `new/` is NotFound; a directory may take the slash
            if (n.kind != NodeKind.Dir && Vfs.dirOnly(to)) return IoError.os(IoErrorKind.NotFound).fail<bool>();
            const e = this.checkParent(b);
            if (e != null) return e.fail<bool>();
        }
        if (this.parentDenied(a) || this.parentDenied(b)) return IoError.os(IoErrorKind.PermissionDenied).fail<bool>();
        if (a == b) return Result.okv<bool>(true);
        if (n.kind == NodeKind.Dir) {
            if (mk == NodeKind.File || mk == NodeKind.Other) return IoError.os(IoErrorKind.NotADirectory).fail<bool>();
            if (mk == NodeKind.Dir && this.presentChildren(b) > 0) return IoError.os(IoErrorKind.DirectoryNotEmpty).fail<bool>();
            if (b.startsWith(a + "/")) return IoError.os(IoErrorKind.InvalidInput).fail<bool>();
            // move the known subtree
            const prefix = a + "/";
            const keys = this.nodes.keys();
            const moved: Array<string> = [];
            for (let i = 0; i < keys.length; i++) {
                if (keys[i].startsWith(prefix)) moved.push(keys[i]);
            }
            if (mk == NodeKind.Dir) this.dropSubtree(b);
            for (let i = 0; i < moved.length; i++) {
                const k = moved[i];
                const c = this.nodes.get(k);
                Vfs.moved(c);
                this.nodes.set(b + k.substring(a.length), c);
                this.nodes.set(k, new Node(NodeKind.Absent));
            }
        } else if (mk == NodeKind.Dir) {
            return IoError.os(IoErrorKind.IsADirectory).fail<bool>();
        }
        Vfs.moved(n);
        this.nodes.set(b, n);
        this.nodes.set(a, new Node(NodeKind.Absent));
        const op = new Op("rename", a);
        op.to = b;
        this.journal(op);
        return Result.okv<bool>(true);
    }

    // A node renamed by this run: its canonical form follows its new place
    // (the app renames only regular files it wrote).
    private static moved(n: Node): void {
        n.real = null;
        n.realKnown = false;
        n.notLink = true;
    }

    // Copies a file: the number of bytes copied.
    copy(from: string, to: string): Result<u64> {
        const r = this.read(from);
        if (!r.ok) return r.forward<u64>();
        const w = this.write(to, r.value);
        if (!w.ok) return w.forward<u64>();
        return Result.okv<u64>(<u64>r.value.length);
    }

    // Sets the permission bits of `path` to `mode`.
    setPermissions(path: string, mode: u32): Result<bool> {
        const abs = this.resolve(path);
        const n = this.stat(path);
        if (n == null) return IoError.os(this.errKind).fail<bool>();
        const op = new Op("chmod", abs);
        op.mode = mode;
        this.journal(op);
        return Result.okv<bool>(true);
    }

    // The known state of `path` (for tests and diagnostics): the content of
    // a file, or null.
    contentOf(path: string): Uint8Array? {
        const abs = this.resolve(path);
        if (!this.nodes.has(abs)) return null;
        const n = this.nodes.get(abs);
        return n.kind == NodeKind.File ? n.data : null;
    }

    textOf(path: string): string? {
        const d = this.contentOf(path);
        if (d == null) return null;
        return String.UTF8.decode(d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength));
    }
}

// The process-wide environment. `Facts.replay` (host/facts.as) resets it for
// each run of a command; tests reset it with `vfs.reset("/work", true)`.
export let vfs: Vfs = new Vfs();
