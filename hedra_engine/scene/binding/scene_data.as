// The tools' data of a scene (docs/plans/RIVE_MODEL.md sections 3.4 and
// 11, RM1): its view model's instance and its data source's globals, in
// memory, as the CLI's `render --data`, `inspect` and the editor's Data dock
// and viewport read and set them. The run time binds live instances
// instead (../runtime/feature_bindings.as).
//
// The source is ../data/source.as dataSourceOf's: the ViewModel's file (a
// .riv or an .rml), else the Rive project's data through the installed
// provider. The view model resolves in it (its instance, or the view
// model's default: RML's defaultInstanceId, a .riv's first), and every
// global view model of it is held at its default instance.
//
// A `--data` path is the scene's view model's (`lamp/level`), or a
// global's: `global/<Name>/<path>` (`global/Theme/accent`), as long as the
// scene's view model has no property called `global` (then the root's path
// wins, and the global is not reachable by --data: the error says so).

import { Result } from "../../base/util";
import { Diagnostic, Severity } from "../error";
import { SceneTree } from "../tree/tree";
import { DataSource, dataSourceOf } from "../data/source";
import { schemaOf } from "./schema";
import { SceneBindings, converterLookupOf, resolveSchemaIn, sceneViewModelOf, viewModelUnknown } from "./binder";
import { DataAssignment, MemoryGlobals, MemoryViewModel } from "./values";
import { OutputView } from "./outputs";

// The first segment of a --data path naming a global.
export const GLOBAL_DATA_PREFIX = "global/";

export class SceneData {
    // Where the data came from (null: the scene has none).
    source: DataSource? = null;
    // The scene's view model's instance (null: it names none, or it does
    // not resolve).
    root: MemoryViewModel? = null;
    // Each global view model of the source, its default instance's values
    // (schema.name the global's name), in the source's order.
    globals: Array<MemoryViewModel> = [];
    // Why the source or the view model did not resolve (view-model-unknown,
    // data-source-unreadable), as warnings.
    warnings: Array<Diagnostic> = [];
    // Milestone 42 (added): the bindings applySceneData ran (null before),
    // so that the outputs can be pushed once the picture's view is known
    // (pushOutputs).
    bindings: SceneBindings? = null;
    // Why the scene's view model does not resolve ("" when it does or the
    // scene names none): the error of a --data the root would take.
    rootError: string = "";

    global(name: string): MemoryViewModel? {
        for (let i = 0; i < this.globals.length; i++) if (this.globals[i].schema.name == name) return this.globals[i];
        return null;
    }

    // Bumped whenever any value changes (the root's and the globals'
    // versions summed), so that a viewer knows when to redraw.
    version(): u32 {
        let v: u32 = 0;
        const r = this.root;
        if (r != null) v += r.version;
        for (let i = 0; i < this.globals.length; i++) v += this.globals[i].version;
        return v;
    }

    // Whether `path` names a global (see the header).
    isGlobalPath(path: string): bool {
        if (!path.startsWith(GLOBAL_DATA_PREFIX)) return false;
        const r = this.root;
        if (r == null) return true;
        // (the root's own `global/...` wins)
        const fields = r.schema.fields;
        for (let i = 0; i < fields.length; i++) if (fields[i].path == "global" || fields[i].path.startsWith(GLOBAL_DATA_PREFIX)) return false;
        return true;
    }

    // Sets one --data assignment (see the header); the error is `--data
    // <path>: <why>`, changing nothing.
    set(path: string, text: string): Result<bool> {
        if (this.isGlobalPath(path)) {
            const rest = path.substring(GLOBAL_DATA_PREFIX.length);
            const slash = rest.indexOf("/");
            const name = slash >= 0 ? rest.substring(0, slash) : rest;
            const g = this.global(name);
            if (g == null) {
                const names = new Array<string>();
                for (let i = 0; i < this.globals.length; i++) names.push(this.globals[i].schema.name);
                return Result.fail<bool>("--data " + path + ": no global view model \"" + name + "\" ("
                    + (names.length > 0 ? "the globals: " + names.join(", ")
                        : this.source != null ? (this.source as DataSource).label + " has none" : "the scene has no data") + ")");
            }
            if (slash < 0 || slash == rest.length - 1) {
                return Result.fail<bool>("--data " + path + ": name a property of the global " + name + ", as global/" + name
                    + "/<path>");
            }
            return g.setAs(rest.substring(slash + 1), text, path);
        }
        const r = this.root;
        if (r == null) {
            if (this.rootError.length > 0) return Result.fail<bool>("--data: the scene's view model does not resolve: " + this.rootError);
            return Result.fail<bool>("--data: the scene names no view model");
        }
        return r.set(path, text);
    }

    // Milestone 42 (added): pushes the bindings applySceneData ran once
    // more with `view` (the picture's: its camera and size), so that a
    // to_source binding of an output writes the view model; returns how
    // many wrote.
    pushOutputs(view: OutputView): i32 {
        const b = this.bindings;
        if (b == null) return 0;
        b.setOutputView(view);
        return b.pushBound();
    }
}

// The data of `tree`: its source, its view model's instance and the
// source's globals, none of it applied to the nodes.
export function sceneDataOf(tree: SceneTree): SceneData {
    const d = new SceneData();
    const vm = sceneViewModelOf(tree);
    // A ViewModel naming a file: that file's (its failure is the view
    // model's warning, as before); else the project's, whose unreadable
    // RML is data-source-unreadable.
    const named = vm != null && (vm.rive != null || vm.data != null);
    const s = dataSourceOf(tree);
    let sourceErr = "";
    if (s.ok) d.source = s.value;
    else {
        sourceErr = s.err;
        if (!named) {
            d.warnings.push(new Diagnostic(Severity.Warning, "data-source-unreadable", tree.loader.displayPath(tree.scenePath), 0, 0,
                "the scene's data could not be read: " + s.err,
                "the scene still draws; `rive <project> --check` reads the project's RML as rive does"));
        }
    }
    if (vm != null) {
        const r = resolveSchemaIn(tree, vm, d.source, named ? sourceErr : "");
        if (r.ok) d.root = new MemoryViewModel(r.value);
        else {
            d.rootError = r.err;
            if (named || sourceErr.length == 0) d.warnings.push(viewModelUnknown(tree, vm, r.err));
        }
    }
    const src = d.source;
    if (src != null) {
        // What reading the source found (a project's .rml that does not
        // read: data-source-unreadable), so that bindingDiagnostics, and
        // with it the editor, says it as the CLI does.
        for (let i = 0; i < src.warnings.length; i++) d.warnings.push(src.warnings[i]);
        const info = src.info();
        for (let i = 0; i < info.viewModels.length; i++) {
            const g = info.viewModels[i];
            if (!g.global) continue;
            const r = schemaOf(info, g.name, "");
            if (r.ok) d.globals.push(new MemoryViewModel(r.value));
        }
    }
    return d;
}

// What the tools draw: `tree`'s data with `data` set on it (in order),
// pulled once through every binding (one_way, two_way and once), then
// pushed (two_way and to_source, the outputs with `view` when given:
// SceneData.pushOutputs pushes them once the view is known), so that the
// answer lists what the scene wrote. A failure is the first assignment
// that failed.
export function applySceneData(tree: SceneTree, data: Array<DataAssignment>, view: OutputView? = null): Result<SceneData> {
    const d = sceneDataOf(tree);
    for (let i = 0; i < data.length; i++) {
        const r = d.set(data[i].path, data[i].text);
        if (!r.ok) return Result.fail<SceneData>(r.err);
    }
    const b = SceneBindings.collectData(tree, d, converterLookupOf(tree, d.source));
    b.bindData(d.root, new MemoryGlobals(d.globals));
    b.setOutputView(view);
    b.pullBound();
    b.pushBound();
    d.bindings = b;
    return Result.okv<SceneData>(d);
}
