// The tools' data of a Rive project (docs/plans/RIVE_MODEL.md section 3.4):
// a scene whose ViewModel names no file reads the view models, enums and
// converters of the Rive project it sits in, that is of every .rml file
// `rive <project>` would compile, read with the engine's RML data reader
// (engine/src/scene/data/rml_read.as) and merged in path order.
// Installed by the Hedra program and the editor (installProjectData), it
// is the engine's ProjectDataProvider.
//
// The project is the folder of the nearest rive.yaml at or above the scene.
// Its .rml files are found as rive's scan finds them (rive-cli's
// project_scan.cpp scanProject): every file under the project's folder
// whose name ends in .rml (any case), dot names skipped (a dot folder is
// not entered), rive.yaml's `exclude:` items matched as rive matches them
// (./rive_yaml.as isExcluded; a folder whose files the items all leave
// out is not entered, excludesAllUnder), rive's output folder (`output: dir:`,
// build/ by default) excluded as rive excludes it, and sorted by their path
// in the project, byte for byte. A Rive project nested inside another (a
// folder holding its own rive.yaml) is walked like any other folder, as
// rive walks it: its files merge into the outer project's document unless
// `exclude:` leaves them out (Build refuses such a project:
// build-nested-project), while a scene inside the nested project reads the
// nested one, its nearest.
//
// An .rml that does not read (not UTF-8, not XML, a data element rive would
// refuse) is left out, with the warning data-source-unreadable naming the
// file and the reader's message on the source (DataSource.warnings): the
// scene still draws, its bindings to that file's data then unknown.
//
// The parsed files are cached per project and kept while their bytes are
// unchanged: each call walks the project again (so that a file added or
// removed counts) and compares each file's bytes with those it was parsed
// from, parsing again only those that changed; with nothing changed it
// answers the same source object.

import { Result, cmpStr, stableSort, toAsciiLowercase } from "../../base/util";
import { vfs, isValidUtf8 } from "../../fs/vfs";
import { joinKey } from "../../fs/path";
import { Diagnostic, Severity, sceneryErrorOf } from "../../scene/error";
import { DataDoc } from "../../scene/data/model";
import { DATA_SOURCE_UNREADABLE, readRmlData } from "../../scene/data/rml_read";
import {
    DataSource, DataSourceKind, DocDataSource, ProjectDataProvider, projectDataProvider, setProjectDataProvider,
} from "../../scene/data/source";
import { dirOf } from "../../scene/resource/loader";
import { RiveYaml, excludesAllUnder, isExcluded, parseRiveYaml } from "./rive_yaml";

// The Rive project's settings file.
export const RIVE_YAML_FILE = "rive.yaml";
// How deep the walk goes (a symbolic link loop stops here), as Build's.
const DATA_WALK_DEPTH: i32 = 64;

// `abs` as the tools show it: from the working directory when under it,
// else absolute.
export function shownDataPath(abs: string): string {
    const cwd = vfs.cwd;
    if (abs == cwd) return ".";
    const prefix = cwd == "/" ? "/" : cwd + "/";
    return abs.startsWith(prefix) ? abs.substring(prefix.length) : abs;
}

// The directory holding the rive.yaml nearest above `path` (an absolute
// vfs path: a file's directory and each above it, or a directory and each
// above it), "" when there is none.
export function riveProjectOf(path: string): string {
    let d = vfs.isDir(path) ? path : dirOf(path);
    while (true) {
        if (vfs.isFile(joinKey(d, RIVE_YAML_FILE))) return d;
        if (d == "/") return "";
        d = dirOf(d);
    }
}

// rive.yaml of the project at `root`, read (an unreadable one reads as
// empty: rive would refuse to build it, which is not the data's concern).
export function riveYamlOf(root: string): RiveYaml {
    const r = vfs.readToString(joinKey(root, RIVE_YAML_FILE));
    return r.ok ? parseRiveYaml(r.value) : new RiveYaml();
}

// The path of `abs` in the project at `root`.
function relOf(root: string, abs: string): string {
    if (abs == root) return "";
    return abs.substring(root == "/" ? 1 : root.length + 1);
}

function walk(root: string, dir: string, exclude: Array<string>, depth: i32, out: Array<string>): void {
    const r = vfs.readDir(dir);
    if (!r.ok) return;
    const names = r.value;
    for (let i = 0; i < names.length; i++) {
        const p = names[i];
        const name = p.substring(p.lastIndexOf("/") + 1);
        if (name.startsWith(".")) continue;
        const rel = relOf(root, p);
        if (vfs.isDir(p)) {
            if (depth < DATA_WALK_DEPTH && !excludesAllUnder(rel, exclude)) walk(root, p, exclude, depth + 1, out);
        } else if (toAsciiLowercase(name).endsWith(".rml") && !isExcluded(rel, exclude) && vfs.isFile(p)) {
            out.push(p);
        }
    }
}

// The .rml files of the Rive project at `root`, absolute, sorted by their
// path from `root` byte for byte: those rive compiles (see the header).
export function projectRmlFiles(root: string): Result<Array<string>> {
    if (!vfs.isDir(root)) return Result.fail<Array<string>>("cannot read " + shownDataPath(root) + ": it is not a folder");
    const y = riveYamlOf(root);
    const exclude = y.exclude.slice(0);
    exclude.push(y.outputDir);
    const out = new Array<string>();
    walk(root, root, exclude, 0, out);
    // (byte order of the absolute paths is that of the paths in the
    // project: they share the prefix)
    stableSort<string>(out, cmpStr);
    return Result.okv<Array<string>>(out);
}

// One file of a cached project: the bytes it was parsed from, and what
// they read as (null and the warning when they did not).
class CachedFile {
    path: string;
    bytes: Uint8Array;
    doc: DataDoc?;
    warning: Diagnostic?;
    // Whether the bytes were read (a file that could not be read is tried
    // again).
    read: bool = true;

    constructor(path: string, bytes: Uint8Array, doc: DataDoc?, warning: Diagnostic?) {
        this.path = path;
        this.bytes = bytes;
        this.doc = doc;
        this.warning = warning;
    }
}

class CachedProject {
    files: Array<CachedFile> = [];
    source: DocDataSource? = null;
}

function sameBytes(a: Uint8Array, b: Uint8Array): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (unchecked(a[i]) != unchecked(b[i])) return false;
    return true;
}

function unreadable(file: string, line: i32, col: i32, why: string): Diagnostic {
    return new Diagnostic(Severity.Warning, DATA_SOURCE_UNREADABLE, file, line, col,
        "the Rive project's data in " + file + " does not read, so it is left out: " + why,
        "fix the file (`rive inspect` names the same problem), or leave it out with rive.yaml's exclude:");
}

// `bytes` of the file at `abs` read as RML data, or the warning.
function readFile(abs: string, bytes: Uint8Array): CachedFile {
    const shown = shownDataPath(abs);
    if (!isValidUtf8(bytes)) return new CachedFile(abs, bytes, null, unreadable(shown, 0, 0, "it is not UTF-8 text"));
    const text = String.UTF8.decode(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    const r = readRmlData(text, shown);
    if (r.ok) {
        r.value.path = abs;
        return new CachedFile(abs, bytes, r.value, null);
    }
    const e = sceneryErrorOf<DataDoc>(r);
    if (e != null) return new CachedFile(abs, bytes, null, unreadable(shown, e.line, e.col, e.message));
    return new CachedFile(abs, bytes, null, unreadable(shown, 0, 0, r.err));
}

export class ToolProjectData extends ProjectDataProvider {
    // By the project's folder.
    private projects: Map<string, CachedProject> = new Map<string, CachedProject>();

    projectData(scenePath: string): Result<DataSource?> {
        const root = riveProjectOf(scenePath);
        if (root.length == 0) return Result.okv<DataSource?>(null);
        return this.dataOf(root);
    }

    // The data of the Rive project at `root` (see the header).
    dataOf(root: string): Result<DataSource?> {
        const files = projectRmlFiles(root);
        if (!files.ok) return files.forward<DataSource?>();
        const paths = files.value;
        let cached = this.projects.has(root) ? this.projects.get(root) : null;
        if (cached == null) {
            cached = new CachedProject();
            this.projects.set(root, cached);
        }
        let changed = cached.source == null || cached.files.length != paths.length;
        const next = new Array<CachedFile>();
        for (let i = 0; i < paths.length; i++) {
            const abs = paths[i];
            const b = vfs.read(abs);
            const bytes = b.ok ? b.value : new Uint8Array(0);
            const old = i < cached.files.length && cached.files[i].path == abs ? cached.files[i] : null;
            if (old != null && b.ok && old.read && sameBytes(old.bytes, bytes)) {
                next.push(old);
                continue;
            }
            changed = true;
            if (!b.ok) {
                const failed = new CachedFile(abs, bytes, null, unreadable(shownDataPath(abs), 0, 0, "cannot read it: " + b.err));
                failed.read = false;
                next.push(failed);
                continue;
            }
            next.push(readFile(abs, bytes));
        }
        const have = cached.source;
        if (!changed && have != null) return Result.okv<DataSource?>(have);
        const docs = new Array<DataDoc>();
        const warnings = new Array<Diagnostic>();
        for (let i = 0; i < next.length; i++) {
            const d = next[i].doc;
            if (d != null) docs.push(d);
            const w = next[i].warning;
            if (w != null) warnings.push(w);
        }
        const source = new DocDataSource(DataSourceKind.Project, "the Rive project at " + shownDataPath(root), docs);
        source.warnings = warnings;
        cached.files = next;
        cached.source = source;
        return Result.okv<DataSource?>(source);
    }
}

// Installs ToolProjectData as the engine's provider (once; again is a
// no-op).
export function installProjectData(): void {
    const p = projectDataProvider();
    if (p != null && p instanceof ToolProjectData) return;
    setProjectDataProvider(new ToolProjectData());
}
