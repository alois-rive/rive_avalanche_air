// Milestone 17: a view model as the tools see it (docs/formats/RSCN.md,
// "Bindings"): the properties of a view model of a .riv
// (../riv/riv_info.as RivViewModel), flattened into paths, nested view
// models walked (`lamp/level`), each with its kind and its value in the
// instance the scene starts from. Bindings are resolved against it
// (./binder.as), the tools' MemoryViewModel (./values.as) starts from its
// values, and the CLI's `inspect <file>.riv` lists it.
//
// The values are the runtime's: an instance's value for each property
// (../riv/riv_info.as RivVmValue), a property it leaves out read as the
// runtime starts it (0, false, "", the colour 0), and a nested view model's
// from the instance of it the value names. `rive --data-dump` shows the same
// numbers for the instance the artboard binds (the editor program's schema_test.as
// checks tests/fixtures/riv/vm.riv against what it printed).

import { Result } from "../../base/util";
import { RivInfo, RivViewModel, RivVmInstance, RivVmValue, VmKind } from "../riv/riv_info";

// The most segments a path has: deeper nested view models are not walked,
// so a view model that holds itself (directly or through others) stops.
export const VM_PATH_DEPTH: i32 = 8;

// One property of the flattened view model.
export class VmField {
    // Its path from the view model: "angle", "lamp/level".
    path: string;
    kind: VmKind;
    // Its value in the instance (the kind's own field; a property the
    // instance does not set reads as the runtime reads it: 0, false, the
    // colour 0 (transparent black), "").
    number: f64 = 0;
    boolean: bool = false;
    // ARGB, sRGB with straight alpha.
    color: u32 = 0;
    // A string's value; an enum's value key.
    text: string = "";
    // Milestone 42: an enum's keys, in order (empty for other kinds, and
    // for an enum whose keys the source does not give).
    enumValues: Array<string> = [];
    // Milestone 42: a nested view model's (VmKind.ViewModel) view model,
    // by name ("" when it names none): what a data_path context names.
    reference: string = "";

    constructor(path: string, kind: VmKind) {
        this.path = path;
        this.kind = kind;
    }
}

export class ViewModelSchema {
    // The view model's name, and the instance the values are from.
    name: string = "";
    instance: string = "";
    // Every property, nested ones after the property that holds them, in
    // file order; a nested view model's own field (kind ViewModel) comes
    // first, then its properties.
    fields: Array<VmField> = [];

    field(path: string): VmField? {
        for (let i = 0; i < this.fields.length; i++) if (this.fields[i].path == path) return this.fields[i];
        return null;
    }

    // The paths a binding may name (number, boolean, color, string and
    // enum fields), in order: what a message about an unknown path lists.
    bindablePaths(): Array<string> {
        return this.pathsUnder("");
    }

    // Milestone 42: the bindable paths under `prefix` ("door/": a data
    // context's), the prefix taken off, in order: what a message about a
    // path unknown in that context lists.
    pathsUnder(prefix: string): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.fields.length; i++) {
            const f = this.fields[i];
            const k = f.kind;
            if (k != VmKind.Number && k != VmKind.Boolean && k != VmKind.Color && k != VmKind.String && k != VmKind.Enum) continue;
            if (!f.path.startsWith(prefix)) continue;
            out.push(f.path.substring(prefix.length));
        }
        return out;
    }

    // Milestone 31: the paths a signal binding may name (trigger fields),
    // in order: what a message about a signal binding's path lists.
    triggerPaths(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.fields.length; i++) if (this.fields[i].kind == VmKind.Trigger) out.push(this.fields[i].path);
        return out;
    }
}

// The schema of the view model `name` of `info`, its values those of the
// instance `instance` ("" for the view model's default instance, which is
// its first: riv_info.as). Fails when the file has no such view model
// ("no view model \"X\" in it: A, B") or no such instance ("no instance
// \"Y\" of view model X: Default, Night"). Nested view models are walked
// to paths of VM_PATH_DEPTH segments (a view model holding itself stops
// there). The schema's `instance` is the instance's name ("" when the view
// model has none, and then every value is unset).
export function schemaOf(info: RivInfo, name: string, instance: string): Result<ViewModelSchema> {
    const vm = info.viewModel(name);
    if (vm == null) {
        return Result.fail<ViewModelSchema>("no view model \"" + name + "\" in it: " + namesOrNone(info.viewModelNames()));
    }
    let index = vm.defaultInstance;
    if (instance.length > 0) {
        index = vm.instanceIndex(instance);
        if (index < 0) {
            return Result.fail<ViewModelSchema>("no instance \"" + instance + "\" of view model " + name + ": "
                + namesOrNone(vm.instanceNames()));
        }
    }
    const s = new ViewModelSchema();
    s.name = name;
    const inst = index >= 0 && index < vm.instances.length ? vm.instances[index] : null;
    s.instance = inst != null ? inst.name : "";
    walk(info, vm, inst, "", 1, s.fields);
    return Result.okv<ViewModelSchema>(s);
}

function namesOrNone(names: Array<string>): string {
    return names.length > 0 ? names.join(", ") : "none";
}

// The instance's value for property `p`: the first that names it (the
// runtime's ViewModelInstance::propertyValue), and only when its kind is
// the property's.
function valueOf(inst: RivVmInstance?, p: i32, kind: VmKind): RivVmValue? {
    if (inst == null) return null;
    const values = inst.values;
    for (let i = 0; i < values.length; i++) {
        const v = values[i];
        if (v.property == p) return v.kind == kind ? v : null;
    }
    return null;
}

// Appends the fields of `vm` (values from `inst`, null: all unset) under
// `prefix`, at paths of `depth` segments.
function walk(info: RivInfo, vm: RivViewModel, inst: RivVmInstance?, prefix: string, depth: i32, out: Array<VmField>): void {
    for (let i = 0; i < vm.properties.length; i++) {
        const p = vm.properties[i];
        const f = new VmField(prefix + p.name, p.kind);
        out.push(f);
        if (p.kind == VmKind.Enum) f.enumValues = p.enumValues;
        const v = valueOf(inst, i, p.kind);
        if (p.kind == VmKind.ViewModel) {
            if (p.reference < 0 || p.reference >= info.viewModels.length) continue;
            const nested = info.viewModels[p.reference];
            f.reference = nested.name;
            if (depth >= VM_PATH_DEPTH) continue;
            const k = v != null ? v.instance : -1;
            walk(info, nested, k >= 0 && k < nested.instances.length ? nested.instances[k] : null, f.path + "/", depth + 1, out);
            continue;
        }
        if (v == null) continue;
        f.number = v.number;
        f.boolean = v.boolean;
        f.color = v.color;
        f.text = v.text;
    }
}
