// Where a scene's data model comes from (docs/plans/RIVE_MODEL.md section
// 3.4, "Where view models come from"), behind one seam the binder resolves
// against:
//
//   RivDataSource   a .riv's view models (the ViewModel's `file` names a
//                   RiveFile): read-only, the first instance the default
//                   (the runtime's rule, ../riv/riv_info.as);
//   DocDataSource   RML data: one .rml (the ViewModel's `file` names a
//                   RiveData), or every .rml of the Rive project the scene
//                   sits in (no `file`), merged in the order rive compiles
//                   them; defaultInstanceId is the default.
//
// A source answers the view models as a RivInfo (so ../binding/schema.as
// schemaOf serves all three), its globals among them (RivViewModel.global),
// and the converters and enums by name.
//
// The project's data is found by the ProjectDataProvider installed: the
// tools' (engine/src/source/project/project_data.as: rive.yaml above the scene and
// the .rml files rive would compile) or the library's in a Rive project
// (the declared RML blobs, ../runtime/project_data.as). With none installed a
// scene that names no file has no data source.

import { Result } from "../../base/util";
import { RivInfo, RivViewModel, RivVmInstance, RivVmProperty, RivVmValue, VmKind } from "../riv/riv_info";
import { SceneViewModel } from "../resource/types";
import { SceneTree } from "../tree/tree";
import { Diagnostic } from "../error";
import { DataConverterDecl, DataDoc, DataEnum, DataViewModel } from "./model";

export enum DataSourceKind {
    // A .riv (RiveFile).
    Riv,
    // One .rml (RiveData).
    Rml,
    // The enclosing Rive project's .rml files.
    Project,
}

export abstract class DataSource {
    kind: DataSourceKind;
    // What messages name it by: the file's display path, or the Rive
    // project's directory ("the Rive project at res://..").
    label: string;
    // What reading it found without failing: a project's .rml that does
    // not read is left out, as the warning data-source-unreadable naming
    // the file and the reader's message (the scene still draws). The tools
    // show these with the scene's warnings.
    warnings: Array<Diagnostic> = [];

    constructor(kind: DataSourceKind, label: string) {
        this.kind = kind;
        this.label = label;
    }

    // Its view models, globals included, as a RivInfo (artboards empty for
    // an RML source).
    abstract info(): RivInfo;

    // The converter called `name`, or null (a .riv has none the tools can
    // read).
    converter(name: string): DataConverterDecl? {
        return null;
    }

    // The value keys of the enum called `name`, or null.
    enumValues(name: string): Array<string>? {
        return null;
    }

    // The names of its converters, each once, in order (a .riv's: none
    // read), for a binding-converter-unknown hint.
    converterNames(): Array<string> {
        return [];
    }

    // The names of its global view models, in order.
    globalNames(): Array<string> {
        const out = new Array<string>();
        const vms = this.info().viewModels;
        for (let i = 0; i < vms.length; i++) if (vms[i].global) out.push(vms[i].name);
        return out;
    }
}

// A .riv's view models.
export class RivDataSource extends DataSource {
    rivInfo: RivInfo;

    constructor(info: RivInfo, label: string) {
        super(DataSourceKind.Riv, label);
        this.rivInfo = info;
    }

    info(): RivInfo {
        return this.rivInfo;
    }
}

// RML data: one file's, or a project's files' merged (the first
// declaration of a name wins). A reference one file makes to another's
// element is "@" + its id (./rml_read.as): resolve() names it, and
// converter() and enumValues() take either form.
export class DocDataSource extends DataSource {
    docs: Array<DataDoc>;
    private cached: RivInfo? = null;
    private idNames: Map<string, string>? = null;

    constructor(kind: DataSourceKind, label: string, docs: Array<DataDoc>) {
        super(kind, label);
        this.docs = docs;
    }

    info(): RivInfo {
        const c = this.cached;
        if (c != null) return c;
        const made = rivInfoOfDocs(this.docs);
        this.cached = made;
        return made;
    }

    // `ref` as a name: itself, or for "@<id>" the name of the element of
    // that id in any doc (a value's key for an enum value), "" when no doc
    // declares it.
    resolve(ref: string): string {
        if (!ref.startsWith("@")) return ref;
        let m = this.idNames;
        if (m == null) {
            m = dataIdNames(this.docs);
            this.idNames = m;
        }
        const id = ref.substring(1);
        return m.has(id) ? m.get(id) : "";
    }

    viewModel(name: string): DataViewModel? {
        const n = this.resolve(name);
        for (let i = 0; i < this.docs.length; i++) {
            const v = this.docs[i].viewModel(n);
            if (v != null) return v;
        }
        return null;
    }

    converter(name: string): DataConverterDecl? {
        if (name.startsWith("@")) {
            const id = name.substring(1);
            for (let i = 0; i < this.docs.length; i++) {
                const cs = this.docs[i].converters;
                for (let k = 0; k < cs.length; k++) if (cs[k].id == id) return cs[k];
            }
            return null;
        }
        for (let i = 0; i < this.docs.length; i++) {
            const c = this.docs[i].converter(name);
            if (c != null) return c;
        }
        return null;
    }

    enumValues(name: string): Array<string>? {
        return enumKeys(this.docs, this.resolve(name));
    }

    converterNames(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.docs.length; i++) {
            const cs = this.docs[i].converters;
            for (let k = 0; k < cs.length; k++) if (cs[k].name.length > 0 && !out.includes(cs[k].name)) out.push(cs[k].name);
        }
        return out;
    }
}

// Every id the docs declare among their data elements, to the name a
// reference to it means: a view model's, an instance's, a converter's, an
// enum's name, an enum value's key.
export function dataIdNames(docs: Array<DataDoc>): Map<string, string> {
    const m = new Map<string, string>();
    for (let d = 0; d < docs.length; d++) {
        const doc = docs[d];
        for (let i = 0; i < doc.viewModels.length; i++) {
            const vm = doc.viewModels[i];
            if (vm.id.length > 0) m.set(vm.id, vm.name);
            for (let k = 0; k < vm.instances.length; k++) {
                const inst = vm.instances[k];
                if (inst.id.length > 0) m.set(inst.id, inst.name);
            }
            for (let k = 0; k < vm.properties.length; k++) {
                const p = vm.properties[k];
                if (p.id.length > 0) m.set(p.id, p.name);
            }
        }
        for (let i = 0; i < doc.enums.length; i++) {
            const e = doc.enums[i];
            if (e.id.length > 0) m.set(e.id, e.name);
            for (let k = 0; k < e.valueIds.length && k < e.values.length; k++) {
                if (e.valueIds[k].length > 0) m.set(e.valueIds[k], e.values[k]);
            }
        }
        // (and a system enum's values: an instance's ViewModelInstanceEnum
        // may name one another file declares; the enum has no name, so its
        // id stands for its enumType)
        for (let i = 0; i < doc.systemEnums.length; i++) {
            const e = doc.systemEnums[i];
            if (e.id.length > 0) m.set(e.id, e.name.length > 0 ? e.name : e.enumType);
            for (let k = 0; k < e.valueIds.length && k < e.values.length; k++) {
                if (e.valueIds[k].length > 0) m.set(e.valueIds[k], e.values[k]);
            }
        }
        for (let i = 0; i < doc.converters.length; i++) {
            const c = doc.converters[i];
            if (c.id.length > 0) m.set(c.id, c.name);
        }
    }
    return m;
}

function resolveIn(m: Map<string, string>, ref: string): string {
    if (!ref.startsWith("@")) return ref;
    const id = ref.substring(1);
    return m.has(id) ? m.get(id) : "";
}

// The view models of `docs` as a RivInfo: each DataViewModel a
// RivViewModel (references, nested instances and enum values resolved by
// name across every doc, "@<id>" ones by id; a custom enum's keys copied,
// and a system enum's, found by its id),
// its default instance the one defaultInstanceId named
// (DataViewModel.defaultInstance). The first view model of a name wins.
export function rivInfoOfDocs(docs: Array<DataDoc>): RivInfo {
    const info = new RivInfo();
    const ids = dataIdNames(docs);
    const all = new Array<DataViewModel>();
    for (let d = 0; d < docs.length; d++) {
        const vms = docs[d].viewModels;
        for (let i = 0; i < vms.length; i++) {
            let dup = false;
            for (let k = 0; k < all.length; k++) if (all[k].name == vms[i].name) dup = true;
            if (!dup) all.push(vms[i]);
        }
    }
    for (let i = 0; i < all.length; i++) {
        const src = all[i];
        const vm = new RivViewModel();
        vm.name = src.name;
        vm.global = src.global;
        for (let p = 0; p < src.properties.length; p++) {
            const sp = src.properties[p];
            const rp = new RivVmProperty();
            rp.name = sp.name;
            rp.kind = sp.kind;
            if (sp.kind == VmKind.ViewModel) rp.reference = indexOfName(all, resolveIn(ids, sp.reference));
            if (sp.kind == VmKind.Enum && sp.enumName.length > 0) {
                const keys = enumKeys(docs, resolveIn(ids, sp.enumName));
                if (keys != null) rp.enumValues = keys;
            } else if (sp.kind == VmKind.Enum && sp.enumSystem) {
                // A system enum has no name: its keys are those of the
                // DataEnumSystem its enumId names.
                const keys = systemEnumKeys(docs, sp.systemEnum);
                if (keys != null) rp.enumValues = keys;
            }
            vm.properties.push(rp);
        }
        for (let n = 0; n < src.instances.length; n++) {
            const si = src.instances[n];
            const ri = new RivVmInstance();
            ri.name = si.name;
            for (let v = 0; v < si.values.length; v++) {
                const sv = si.values[v];
                const rv = new RivVmValue();
                rv.property = sv.property;
                rv.kind = sv.kind;
                rv.number = sv.number;
                rv.boolean = sv.boolean;
                rv.color = sv.color;
                rv.text = sv.text;
                const known = sv.property >= 0 && sv.property < src.properties.length;
                if (sv.kind == VmKind.ViewModel && known) {
                    const ref = indexOfName(all, resolveIn(ids, src.properties[sv.property].reference));
                    rv.instance = ref >= 0 ? all[ref].instanceIndex(resolveIn(ids, sv.instance)) : -1;
                }
                if (sv.kind == VmKind.Enum && sv.text.startsWith("@")) {
                    // (a value of another file's enum: its key, and its index
                    // in the property's keys)
                    rv.text = resolveIn(ids, sv.text);
                    rv.number = known ? <f64>vm.properties[sv.property].enumValues.indexOf(rv.text) : -1;
                    if (rv.text.length == 0) rv.number = -1;
                }
                ri.values.push(rv);
            }
            vm.instances.push(ri);
        }
        vm.defaultInstance = src.defaultInstance;
        info.viewModels.push(vm);
    }
    return info;
}

function indexOfName(all: Array<DataViewModel>, name: string): i32 {
    if (name.length == 0) return -1;
    for (let i = 0; i < all.length; i++) if (all[i].name == name) return i;
    return -1;
}

// The keys of the system enum (DataDoc.systemEnums) whose id is `id`:
// null when no doc declares it.
function systemEnumKeys(docs: Array<DataDoc>, id: string): Array<string>? {
    if (id.length == 0) return null;
    for (let d = 0; d < docs.length; d++) {
        const es = docs[d].systemEnums;
        for (let i = 0; i < es.length; i++) if (es[i].id == id) return es[i].values;
    }
    return null;
}

function enumKeys(docs: Array<DataDoc>, name: string): Array<string>? {
    if (name.length == 0) return null;
    for (let d = 0; d < docs.length; d++) {
        const e: DataEnum? = docs[d].enumNamed(name);
        if (e != null) return e.values;
    }
    return null;
}

// --- the project's data ------------------------------------------------------

// Finds the data a scene names without a file (its Rive project's) and
// reads an .rml a RiveData names. Installed once by the program or the
// library (setProjectDataProvider).
export abstract class ProjectDataProvider {
    // The data of the Rive project enclosing the scene at `scenePath` (an
    // absolute vfs path): null when the scene is in no Rive project (no
    // rive.yaml above it); a failure when its .rml files could not be read
    // (the message says which and why). A missing file read is a vfs need,
    // as any load's (the result is then a failure the next round retries).
    abstract projectData(scenePath: string): Result<DataSource?>;
}

let provider: ProjectDataProvider? = null;

export function setProjectDataProvider(p: ProjectDataProvider?): void {
    provider = p;
}

export function projectDataProvider(): ProjectDataProvider? {
    return provider;
}

// The data source of `tree`'s scene: its root's ViewModel's file (a .riv
// or an .rml), else the enclosing Rive project's (through the provider),
// else null. A failure says why the source named could not be read. A
// scene whose root names no ViewModel still has its project's data when a
// binding names a global (its bindings may name globals alone), and none
// otherwise.
export function dataSourceOf(tree: SceneTree): Result<DataSource?> {
    const vm: SceneViewModel? = tree.root.viewModel;
    if (vm != null) {
        const rive = vm.rive;
        if (rive != null) {
            const info = rive.info;
            const label = tree.loader.displayPath(rive.path);
            if (info == null) return Result.fail<DataSource?>(label + " could not be read as a Rive file");
            return Result.okv<DataSource?>(new RivDataSource(info, label));
        }
        const data = vm.data;
        if (data != null) {
            const doc = data.data;
            const label = tree.loader.displayPath(data.path);
            if (doc == null) return Result.fail<DataSource?>(label + " could not be read as RML data");
            return Result.okv<DataSource?>(new DocDataSource(DataSourceKind.Rml, label, [doc]));
        }
    }
    const p = provider;
    if (p == null) return Result.okv<DataSource?>(null);
    // (a scene naming no view model has use for its project's data only
    // through a binding to a global: any other, a format-1 scene among them,
    // asks nothing of the project, so its load reads no file more than it
    // did)
    if (vm == null && !bindsGlobal(tree)) return Result.okv<DataSource?>(null);
    return p.projectData(tree.scenePath);
}

// Whether a node of `tree` has a binding naming a global view model.
function bindsGlobal(tree: SceneTree): bool {
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const b = all[i].bindings;
        for (let k = 0; k < b.length; k++) if (b[k].global.length > 0) return true;
    }
    return false;
}
