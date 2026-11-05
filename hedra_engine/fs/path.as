// Paths over plain strings: the component rules and the accessors the app
// layer uses (pinned by recorded reference values in
// tests/app/vfs_host_test.as, and for Windows in
// tests/app/host_platform_test.as).
//
// A path is a string; an answer that may be missing is `string?`.
//
// Two sets of rules, the ones Rust's std::path has on each OS. The VFS picks
// one per invocation from `start.platform.os` (Vfs.reset →
// setWindowsPaths):
//
// - Unix (the default): only `/` separates; there are no prefixes.
// - Windows: `\` separates too, and a path may begin with a prefix: a drive
//   (`C:`), a UNC share (`\\server\share`, `//server/share`), a verbatim
//   prefix (`\\?\C:`, `\\?\UNC\server\share`) or a device (`\\.\COM1`).
//   The contract's spelling of a drive, `/C:` (CONTRACT.md §4), is a drive
//   prefix as well, so `/C:/a`, `C:\a` and `c:/a` are the same path
//   component by component. A path rooted by a single `/` and no drive is
//   a contract path as it stands; the root of the current drive is `\a`.
//   `join` puts a `\` between two parts, as Rust does.
//
// The VFS keys every path by its contract form (resolveAgainst,
// normalizeAbs); nativePath spells a contract path the way the OS shows it.

export enum ComponentKind {
    RootDir,
    CurDir,
    ParentDir,
    Normal,
    // Windows only: `C:` (the drive upper-cased), `\\server\share`, `\\.\X`.
    Prefix,
}

export class Component {
    kind: ComponentKind;
    start: i32; // byte range in the original string (UTF-16 units here)
    end: i32;
    text: string;

    constructor(kind: ComponentKind, start: i32, end: i32, text: string) {
        this.kind = kind;
        this.start = start;
        this.end = end;
        this.text = text;
    }
}

// ---------------------------------------------------------------------------
// Windows rules

let windowsPaths = false;

// Selects the Windows rules (true) or the Unix ones (false, the default).
export function setWindowsPaths(on: bool): void {
    windowsPaths = on;
}

export function usesWindowsPaths(): bool {
    return windowsPaths;
}

function isSepW(c: i32): bool {
    return c == 47 || c == 92;
}

function isLetter(c: i32): bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

// `c:` → "C:".
function driveText(c: i32): string {
    return String.fromCharCode(c >= 97 ? c - 32 : c) + ":";
}

// The end of the component starting at `i` (the next separator or the end).
function componentEnd(p: string, i: i32): i32 {
    const n = p.length;
    let j = i;
    while (j < n && !isSepW(p.charCodeAt(j))) j++;
    return j;
}

const PREFIX_NONE = 0;
const PREFIX_DISK = 1;
const PREFIX_UNC = 2;
const PREFIX_DEVICE = 3;

// The prefix of a Windows path.
class Prefix {
    kind: i32 = PREFIX_NONE;
    // Where the prefix ends, and where the root after it ends (`rootEnd ==
    // end` when the root is implied or absent).
    end: i32 = 0;
    rootEnd: i32 = 0;
    // A root follows (for UNC, device, verbatim and contract drives it is
    // implied); `C:x` alone has none.
    rooted: bool = false;
    // The Prefix component's text.
    text: string = "";
    // Its components in a contract path: ["C:"], or ["server", "share"],
    // which name no drive, so a host answers them as absent (§4).
    parts: Array<string> = [];
}

// A root separator at `i`, or an implied one.
function rootAt(r: Prefix, p: string, i: i32): Prefix {
    r.end = i;
    r.rooted = true;
    r.rootEnd = i < p.length && isSepW(p.charCodeAt(i)) ? i + 1 : i;
    return r;
}

function parsePrefix(p: string): Prefix {
    const r = new Prefix();
    const n = p.length;
    if (n < 2) return r;
    const c0 = p.charCodeAt(0);
    const c1 = p.charCodeAt(1);
    if (isLetter(c0) && c1 == 58) {
        // `C:\x` (rooted) or `C:x` (relative to that drive's directory)
        r.kind = PREFIX_DISK;
        r.text = driveText(c0);
        r.parts = [r.text];
        r.end = 2;
        r.rooted = n > 2 && isSepW(p.charCodeAt(2));
        r.rootEnd = r.rooted ? 3 : 2;
        return r;
    }
    if (c0 == 47 && n >= 3 && isLetter(c1) && p.charCodeAt(2) == 58 && (n == 3 || isSepW(p.charCodeAt(3)))) {
        // the contract spelling `/C:/x`
        r.kind = PREFIX_DISK;
        r.text = driveText(c1);
        r.parts = [r.text];
        return rootAt(r, p, 3);
    }
    if (!isSepW(c0) || !isSepW(c1)) return r;
    let i = 2;
    if (n >= 4 && (p.charCodeAt(2) == 63 || p.charCodeAt(2) == 46) && isSepW(p.charCodeAt(3))) {
        const verbatim = p.charCodeAt(2) == 63;
        i = 4;
        if (verbatim && n >= 6 && isLetter(p.charCodeAt(4)) && p.charCodeAt(5) == 58 && (n == 6 || isSepW(p.charCodeAt(6)))) {
            // `\\?\C:\x`
            r.kind = PREFIX_DISK;
            r.text = driveText(p.charCodeAt(4));
            r.parts = [r.text];
            return rootAt(r, p, 6);
        }
        const e = componentEnd(p, 4);
        const word = p.substring(4, e);
        if (!verbatim || word != "UNC" || e >= n) {
            // `\\.\COM1`, `\\?\Volume{…}`: the device's name
            r.kind = PREFIX_DEVICE;
            r.text = p.substring(0, e);
            r.parts = word.length > 0 ? [word] : [];
            return rootAt(r, p, e);
        }
        i = e + 1; // `\\?\UNC\server\share`
    }
    // `\\server\share`
    const se = componentEnd(p, i);
    const server = p.substring(i, se);
    let end = se;
    let share = "";
    if (se < n) {
        end = componentEnd(p, se + 1);
        share = p.substring(se + 1, end);
    }
    r.kind = PREFIX_UNC;
    r.text = "\\\\" + server + (share.length > 0 ? "\\" + share : "");
    r.parts = [];
    if (server.length > 0) r.parts.push(server);
    if (share.length > 0) r.parts.push(share);
    return rootAt(r, p, end);
}

// The drive of a contract path (`/C:/x` → "C:"), "" when it names none.
function contractDrive(p: string): string {
    const n = p.length;
    if (n < 3 || p.charCodeAt(0) != 47 || !isLetter(p.charCodeAt(1)) || p.charCodeAt(2) != 58) return "";
    if (n > 3 && !isSepW(p.charCodeAt(3))) return "";
    return driveText(p.charCodeAt(1));
}

function componentsWindows(p: string): Array<Component> {
    const out: Array<Component> = [];
    const n = p.length;
    let i = 0;
    const pre = parsePrefix(p);
    if (pre.kind != PREFIX_NONE) {
        out.push(new Component(ComponentKind.Prefix, 0, pre.end, pre.text));
        if (pre.rooted) out.push(new Component(ComponentKind.RootDir, pre.end, pre.rootEnd, "/"));
        i = pre.rootEnd;
    } else if (n > 0 && isSepW(p.charCodeAt(0))) {
        out.push(new Component(ComponentKind.RootDir, 0, 1, "/"));
        i = 1;
    } else if (n > 0 && p.charCodeAt(0) == 46 && (n == 1 || isSepW(p.charCodeAt(1)))) {
        out.push(new Component(ComponentKind.CurDir, 0, 1, "."));
        i = 1;
    }
    while (i < n) {
        const j = componentEnd(p, i);
        if (j > i) {
            const piece = p.substring(i, j);
            if (piece == "..") {
                out.push(new Component(ComponentKind.ParentDir, i, j, piece));
            } else if (piece != ".") {
                out.push(new Component(ComponentKind.Normal, i, j, piece));
            }
        }
        i = j + 1;
    }
    return out;
}

function normalizeWindows(p: string): string {
    const pre = parsePrefix(p);
    const parts: Array<string> = [];
    for (let k = 0; k < pre.parts.length; k++) parts.push(pre.parts[k]);
    // `..` never climbs above a drive or a share
    const floor = parts.length;
    const n = p.length;
    let i = pre.kind != PREFIX_NONE ? pre.end : 0;
    while (i <= n) {
        const j = componentEnd(p, i);
        const piece = p.substring(i, j);
        if (piece == "..") {
            if (parts.length > floor) parts.pop();
        } else if (piece.length > 0 && piece != ".") {
            parts.push(piece);
        }
        i = j + 1;
    }
    return "/" + parts.join("/");
}

// ---------------------------------------------------------------------------
// The accessors

// The components of `p`: a leading `/` is RootDir, a leading `.` (relative
// paths only) is CurDir, then every non-empty piece other than `.` between
// separators; `..` is ParentDir. (Windows: a prefix first, then its root.)
export function components(p: string): Array<Component> {
    if (windowsPaths) return componentsWindows(p);
    const out: Array<Component> = [];
    const n = p.length;
    let i = 0;
    const hasRoot = n > 0 && p.charCodeAt(0) == 47;
    if (hasRoot) {
        out.push(new Component(ComponentKind.RootDir, 0, 1, "/"));
        i = 1;
    } else if (n > 0 && p.charCodeAt(0) == 46 && (n == 1 || p.charCodeAt(1) == 47)) {
        out.push(new Component(ComponentKind.CurDir, 0, 1, "."));
        i = 1;
    }
    while (i < n) {
        let j = i;
        while (j < n && p.charCodeAt(j) != 47) j++;
        const len = j - i;
        if (len > 0) {
            const piece = p.substring(i, j);
            if (piece == "..") {
                out.push(new Component(ComponentKind.ParentDir, i, j, piece));
            } else if (piece != ".") {
                out.push(new Component(ComponentKind.Normal, i, j, piece));
            }
        }
        i = j + 1;
    }
    return out;
}

// Whether `p` is absolute. Unix: it has a root. Windows: a drive with a
// root (`C:\x`, `/C:/x`), a UNC, verbatim or device path, or a contract
// path (`/x`); `\x` (the current drive's root) and `C:x` are relative.
export function isAbsolute(p: string): bool {
    if (!windowsPaths) return p.length > 0 && p.charCodeAt(0) == 47;
    const pre = parsePrefix(p);
    if (pre.kind == PREFIX_DISK) return pre.rooted;
    if (pre.kind != PREFIX_NONE) return true;
    return p.length > 0 && p.charCodeAt(0) == 47;
}

// The path without its last component: null for `/` and "" (and a bare
// Windows prefix), "" for a single relative component.
export function parent(p: string): string? {
    const c = components(p);
    if (c.length == 0) return null;
    const last = c[c.length - 1];
    if (last.kind == ComponentKind.RootDir || last.kind == ComponentKind.Prefix) return null;
    if (c.length == 1) return "";
    return p.substring(0, c[c.length - 2].end);
}

// The last component when it is a normal name (not `/`, `.` or `..`).
export function fileName(p: string): string? {
    const c = components(p);
    if (c.length == 0) return null;
    const last = c[c.length - 1];
    return last.kind == ComponentKind.Normal ? last.text : null;
}

// Length of the stem inside a file name: up to the last dot, unless the
// name is `..` or its only dot is the first character (a dotfile).
function stemLen(name: string): i32 {
    if (name == "..") return name.length;
    const dot = name.lastIndexOf(".");
    if (dot <= 0) return name.length;
    return dot;
}

// The file name without its extension.
export function fileStem(p: string): string? {
    const name = fileName(p);
    if (name == null) return null;
    return name.substring(0, stemLen(name));
}

// The file name's extension, without the dot (null when there is none).
export function extension(p: string): string? {
    const name = fileName(p);
    if (name == null) return null;
    const l = stemLen(name);
    if (l == name.length) return null;
    return name.substring(l + 1);
}

// `rel` appended to `base` with one separator (`/`; Windows `\`); an
// absolute `rel` replaces the base. Windows, as Rust's `PathBuf::push`:
// `C:x` replaces the base too, `\x` keeps the base's prefix, and nothing
// goes between a bare drive and `rel` (`C:` + `x` is `C:x`).
export function join(base: string, rel: string): string {
    if (windowsPaths) return joinWindows(base, rel);
    if (isAbsolute(rel)) return rel;
    if (base.length == 0) return rel;
    if (base.charCodeAt(base.length - 1) == 47) return base + rel;
    return base + "/" + rel;
}

function joinWindows(base: string, rel: string): string {
    const rp = parsePrefix(rel);
    if (rp.kind == PREFIX_DISK && !rp.rooted) return rel;
    if (isAbsolute(rel)) return rel;
    if (rel.length > 0 && rel.charCodeAt(0) == 92) {
        const bp = parsePrefix(base);
        return bp.kind != PREFIX_NONE ? base.substring(0, bp.end) + rel : rel;
    }
    if (base.length == 0) return rel;
    if (isSepW(base.charCodeAt(base.length - 1))) return base + rel;
    const bp = parsePrefix(base);
    if (bp.kind == PREFIX_DISK && !bp.rooted && bp.end == base.length) return base + rel;
    return base + "\\" + rel;
}

// The contract path of the entry `name` of directory `dir` (a contract
// path): always `/`, whatever the rules (hosts refuse a `\` in a
// component).
export function joinKey(dir: string, name: string): string {
    return dir == "/" ? "/" + name : dir + "/" + name;
}

// The path up to its extension's dot (the whole path when there is no
// extension), then `setExtension(ext)`.
export function withExtension(p: string, ext: string): string {
    const e = extension(p);
    const base = e == null ? p : p.substring(0, p.length - e.length);
    return setExtension(base, ext);
}

// Truncates right after the file stem and adds
// `.ext` unless `ext` is empty; a path without a file name is unchanged.
export function setExtension(p: string, ext: string): string {
    const c = components(p);
    if (c.length == 0) return p;
    const last = c[c.length - 1];
    if (last.kind != ComponentKind.Normal) return p;
    const end = last.start + stemLen(last.text);
    const head = p.substring(0, end);
    return ext.length == 0 ? head : head + "." + ext;
}

// Whether `p` starts with `base`, component-wise.
export function startsWith(p: string, base: string): bool {
    const a = components(p);
    const b = components(base);
    if (b.length > a.length) return false;
    for (let i = 0; i < b.length; i++) {
        if (a[i].kind != b[i].kind || a[i].text != b[i].text) return false;
    }
    return true;
}

// The rest of `p` after `base`'s components, or null when `p` does not
// start with `base`.
export function stripPrefix(p: string, base: string): string? {
    const a = components(p);
    const b = components(base);
    if (b.length > a.length) return null;
    for (let i = 0; i < b.length; i++) {
        if (a[i].kind != b[i].kind || a[i].text != b[i].text) return null;
    }
    if (a.length == b.length) return "";
    // The remainder as a path: from the next component's start
    // to the end, with trailing separators and `.` pieces trimmed.
    return p.substring(a[b.length].start, a[a.length - 1].end);
}

// Lexical normal form of an absolute path: `.` and empty pieces dropped,
// `..` pops (never above `/`). Used for VFS keys. Windows: the contract
// form, `/C:/x` for every spelling of the drive, never above the drive
// (`/server/share/x` for a UNC path, which no host can map).
export function normalizeAbs(p: string): string {
    if (windowsPaths) return normalizeWindows(p);
    const parts: Array<string> = [];
    const n = p.length;
    let i = 0;
    while (i <= n) {
        let j = i;
        while (j < n && p.charCodeAt(j) != 47) j++;
        const piece = p.substring(i, j);
        if (piece == "..") {
            if (parts.length > 0) parts.pop();
        } else if (piece.length > 0 && piece != ".") {
            parts.push(piece);
        }
        i = j + 1;
    }
    return "/" + parts.join("/");
}

// The contract path (the VFS key) of `p` as the user wrote it, against the
// working directory `cwd` (a contract path). "" stays "". Windows: `\x` is
// on the cwd's drive, and `D:x` in the cwd when that is on D:, else at
// D:'s root (the working directories of other drives are not known).
export function resolveAgainst(cwd: string, p: string): string {
    if (p.length == 0) return "";
    if (!windowsPaths) return normalizeAbs(isAbsolute(p) ? p : cwd + "/" + p);
    const pre = parsePrefix(p);
    if (pre.kind == PREFIX_DISK && !pre.rooted) {
        const rest = p.substring(pre.end);
        return normalizeAbs((contractDrive(cwd) == pre.text ? cwd : "/" + pre.text) + "/" + rest);
    }
    if (pre.kind != PREFIX_NONE) return normalizeAbs(p);
    const c0 = p.charCodeAt(0);
    if (c0 == 92) {
        const d = contractDrive(cwd);
        return normalizeAbs(d.length > 0 ? "/" + d + p : p);
    }
    if (c0 == 47) return normalizeAbs(p);
    return normalizeAbs(cwd + "/" + p);
}

// How a contract path is shown: Windows spells a drive path natively
// (`/C:/Users/a` → `C:\Users\a`, `/C:` → `C:\`); every other path (and
// every path on Unix) is shown as it is.
export function nativePath(p: string): string {
    if (!windowsPaths) return p;
    const d = contractDrive(p);
    if (d.length == 0) return p;
    const rest = p.substring(3);
    return rest.length <= 1 ? d + "\\" : d + rest.replaceAll("/", "\\");
}
