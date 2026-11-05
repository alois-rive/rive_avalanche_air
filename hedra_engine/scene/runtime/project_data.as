// The data of a Rive project, as the library reads it at run time
// (docs/plans/RIVE_MODEL.md sections 3.4 and 7; docs/engine/DATA.md): the
// engine's ProjectDataProvider (../data/source.as) in a Rive project. A
// scene whose view model names no file, or whose bindings name a global or
// a converter of the project's, takes them from the Rive project's .rml
// files. rive compiles those into the .riv and keeps no text of them, so
// the CLI's `build` declares the ones the project's scenes use as
// `hedra:<path>` blobs (its hedra_engine.rml) and the generated
// hedra_project.as lists them (projects.as RegisteredProject.dataFiles).
//
// Only a scene drawn from its text asks: the text source loads it under
// /hedra/<project> (scene_runtime.as textRootOf) through a ProjectFiles
// read fallback, whose FileSource (the Rive project's blobs) is where the
// files are read. The answer is a DocDataSource of every listed file, each
// read with the engine's RML data reader (../data/rml_read.as), cached per
// project and FileSource: a project's files are read and parsed once, at
// the first load that needs them, never on a frame. A built scene is
// mounted elsewhere and gets no source (its converters travel in its BNDS
// section; the live view model instance is the schema the binder needs),
// nor does a scene of a project that lists no files (its bindings then
// behave as a scene's outside any Rive project).
//
// A listed file that is not declared, or does not read as RML, fails with
// the file and the reason; the binder reports it as the warning
// data-source-unreadable and the scene still draws.

import { Result } from "../../base/util";
import { vfs } from "../../fs/vfs";
import { DataDoc } from "../data/model";
import { DataSource, DataSourceKind, DocDataSource, ProjectDataProvider, projectDataProvider, setProjectDataProvider } from "../data/source";
import { readRmlData } from "../data/rml_read";
import { BLOB_PREFIX, FileSource } from "./sources";
import { RegisteredProject, registeredProjects } from "./projects";
import { ProjectFiles, TEXT_ROOT, textRootOf } from "./scene_runtime";
import { CLI } from "../../base/names";

// One project's data, as read through one FileSource.
class ProjectDataEntry {
    project: RegisteredProject;
    files: FileSource;
    result: Result<DataSource?>;

    constructor(project: RegisteredProject, files: FileSource, result: Result<DataSource?>) {
        this.project = project;
        this.files = files;
        this.result = result;
    }
}

export class BlobProjectData extends ProjectDataProvider {
    private entries: Array<ProjectDataEntry> = [];
    // How many times a project's files were read and parsed (the tests'
    // check of the cache).
    reads: i32 = 0;

    projectData(scenePath: string): Result<DataSource?> {
        const project = projectOfTextPath(scenePath);
        if (project == null || project.dataFiles.length == 0) return Result.okv<DataSource?>(null);
        const fallback = vfs.readFallback(textRootOf(project.name));
        if (fallback == null || !(fallback instanceof ProjectFiles)) return Result.okv<DataSource?>(null);
        const files = (fallback as ProjectFiles).files;
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[i];
            if (e.project === project && e.files.sameAs(files)) return e.result;
        }
        const made = readProjectData(project, files);
        this.reads++;
        this.entries.push(new ProjectDataEntry(project, files, made));
        return made;
    }

    // Forgets what was read (tests; a host that swaps its Rive file).
    clear(): void {
        this.entries.length = 0;
    }
}

// The registered project whose text root holds `scenePath` (the longest
// such root: "/hedra" holds every path of the project ""), or null for a
// path outside every one (a built scene's, a tool's).
export function projectOfTextPath(scenePath: string): RegisteredProject? {
    if (scenePath != TEXT_ROOT && !scenePath.startsWith(TEXT_ROOT + "/")) return null;
    const all = registeredProjects();
    let best: RegisteredProject? = null;
    let bestLength = -1;
    for (let i = 0; i < all.length; i++) {
        const root = textRootOf(all[i].name);
        if (scenePath != root && !scenePath.startsWith(root + "/")) continue;
        if (root.length > bestLength) {
            best = all[i];
            bestLength = root.length;
        }
    }
    return best;
}

// Every file `project` lists, read through `files` and parsed, as one
// source (the files' declarations merged in the listed order, which is the
// byte order of their paths, as rive merges them).
export function readProjectData(project: RegisteredProject, files: FileSource): Result<DataSource?> {
    const docs = new Array<DataDoc>();
    for (let i = 0; i < project.dataFiles.length; i++) {
        const path = project.dataFiles[i];
        const bytes = files.read(path);
        if (bytes == null) {
            return Result.fail<DataSource?>(path + " is not declared in the Rive project (no blob " + BLOB_PREFIX + path
                + "): build the Hedra project " + (project.name.length > 0 ? "\"" + project.name + "\"" : "at the Rive project's root")
                + " with " + CLI + " build, which declares it");
        }
        const text = String.UTF8.decode(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
        const doc = readRmlData(text, path);
        if (!doc.ok) return Result.fail<DataSource?>(doc.err);
        docs.push(doc.value);
    }
    const label = "the Rive project's data (" + project.dataFiles.join(", ") + ")";
    return Result.okv<DataSource?>(new DocDataSource(DataSourceKind.Project, label, docs));
}

// Installs a BlobProjectData as the engine's provider unless one is
// installed already (the tools install their own: hedra_engine/scene's
// newSceneRuntime calls this, and must not replace it).
export function installBlobProjectData(): void {
    if (projectDataProvider() == null) setProjectDataProvider(new BlobProjectData());
}
