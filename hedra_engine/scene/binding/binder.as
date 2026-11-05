// Milestone 17: a loaded scene's bindings, resolved and run (docs/scene/
// RSCN.md, "Bindings"). The scene's view model is its root's `view_model`
// (a ViewModel resource: a view model's name in the scene's data); each
// node carries the bindings its declarations gave it (SceneNode.bindings,
// an override's replacing the instanced scene's for the same property, an
// empty path removing it). SceneBindings resolves each against the data
// and the node's class (./targets.as), keeps what it found wrong as
// warnings, and runs the ones that resolve:
//
//   pull   view model to nodes: each binding whose view model value
//          differs from the one it last applied (every binding, the first
//          time; again when a time-based converter moved) converts it and
//          writes the node's target (./apply.as);
//   push   nodes to view model: a two_way binding whose node value differs
//          from the one it last applied (a script moved the node) converts
//          it back; a to_source binding whenever its node's value (or
//          output's) differs from the one it last wrote.
//
// Milestone 42 (docs/plans/RIVE_MODEL.md section 3.4, the spec's 5.1 to
// 5.5) adds, per binding:
//
// - its direction: one_way and two_way pull (two_way pushes back), and
//   to_source only pushes, an output (global_position, screen_position,
//   screen_visible) included; `once` lets go after the first pull (one_way)
//   or the first push (to_source);
// - its chain of converters, run in that order from source to node: the
//   implicit one of scale, offset and convert (./converters.as
//   ImplicitConverter), then the converter the binding names. Pulling runs
//   both forward; a two_way write back runs the named converter's reverse,
//   then the implicit one's; a to_source push runs the named converter
//   forward (Rive's main direction: the runtime's bind applies `convert`
//   from target to source on a to-source bind, and `reverseConvert` only
//   on a two-way bind's write back), then the implicit one's reverse, so
//   that scale, offset and convert keep meaning `node = source * scale +
//   offset` whichever way the value goes;
// - its data context (`data_path` on an instancing node): the candidates
//   `ctx_k + path` from the innermost context out to the root, the first
//   that names a property (tools: of a kind it takes, in the schema; run
//   time: any, in the live values) winning and kept;
// - `global="Name"`: the path is a global view model's
//   (GlobalValues.global; no context applies).
//
// Numbers are compared within BIND_TOLERANCE, relative: a rotation read
// back from a node's matrix is not bit for bit the one written. A built
// project's run time pulls before the scripts and pushes after them
// (../runtime/feature_bindings.as); the tools pull once, then push once
// with the picture's view (./scene_data.as applySceneData).
//
// The warnings (RSCN.md, "Errors and warnings"), each at the <binding>
// (or the ViewModel sub_resource) they are about; a binding with a warning
// does nothing:
//
//   view-model-unknown            the ViewModel names no view model of its
//                                 data, or no instance of it, or no data
//   view-model-instanced          an instanced scene's root names a view
//                                 model other than its context's: the
//                                 outermost scene's when its instancing
//                                 node has no data_path, else the one the
//                                 data_path's property holds
//   binding-no-view-model         a node has bindings, the scene no view
//                                 model
//   binding-path-unknown          no candidate path names a property
//   binding-type                  the property's kind (after the
//                                 converters) cannot drive the target
//   binding-property              the node's class has no such target (an
//                                 override's binding, which the validator
//                                 could not check)
//   binding-output-mode           an override binds an output other than
//                                 to_source
//   binding-target-missing        a resource target on a node without that
//                                 resource; milestone 61: a shader
//                                 parameter target its material cannot
//                                 take (./shader_targets.as: no
//                                 ShaderMaterial, no such uniform, a
//                                 texture, a whole vector), with the reason
//   binding-conversion            scale, offset or convert on a non-number
//                                 target of an override's binding
//   binding-global-unknown        no global view model of that name
//   binding-converter-unknown, -unsupported, -invalid, -cycle
//                                 the converter could not be built
//                                 (./converters.as)
//
// collectData resolves against the tools' data (./scene_data.as
// SceneData: the schemas of the view model and the globals); collectLive
// keeps every candidate and resolves at bind against the live values, as
// the run time needs (a built scene carries no schema). collect and
// collectWith are milestone 17's entries, over collectData.
//
// Milestone 31: a `signal:<name>` binding (./targets.as) resolves to a
// SignalBinding instead, kept apart from the bindings pull and push run:
// it needs a trigger at its path (binding-path-unknown, binding-type as
// any other), and a node that can emit <name>, its class's own signal
// (classdb.hasSignal) or any name when it has a script (emitSignal);
// otherwise
//
//   binding-signal-unknown    the node's class does not emit the signal and
//                             the node has no script that could
//
// bindTriggers looks each one's trigger up once, when the view model is
// bound (ViewModelValues.trigger). fire(from, signal), called each time a
// node emits a signal (../runtime/feature_bindings.as), holds a firing for
// each trigger bound to it, and fireHeld fires what is held, at the start
// of the next advance, before the artboards advance: a Rive host resets a
// view model's triggers at the end of each frame's state machine advance,
// and the artboard textures' state machines advance first in the frame,
// so a trigger fired later in it (by a Timer's timeout, a script's
// process, an area's overlap) would be reset before any state machine
// saw it. A signal emitted by a pointer or key event between frames is
// fired at the start of the frame that follows, before the state machines
// read it, as at once. Neither allocates. The tools never fire one: render
// runs nothing.
//
// Memory: once bound, an idle frame (no value changed) allocates nothing:
// paths are resolved once, values compared in place, converters and
// outputs evaluated into kept values.

import { Result } from "../../base/util";
import { displayF64 } from "../../base/fmt";
import { Diagnostic, Severity } from "../error";
import { classSignals, hasSignal } from "../classdb";
import { PackedScene, SceneViewModel } from "../resource/types";
import { SceneNode } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { VmKind, vmKindName } from "../riv/riv_info";
import { DataConverterDecl } from "../data/model";
import { DataSource } from "../data/source";
import { BindingConvert, BindingMode, BindingSpec } from "./binding";
import { ViewModelSchema, VmField, schemaOf } from "./schema";
import { BindKind, BindingTarget, bindKindName, bindingTargetsOf, findBindingTarget, signalTargetName } from "./targets";
import { BoundValue, DataAssignment, GlobalValues, MemoryGlobals, MemoryViewModel, TriggerSink, ViewModelValues } from "./values";
import { BindingPose, hasTargetResource, isOutputProperty, lastWriteRebuilt, readTarget, writeTarget } from "./apply";
import { Converter, ConverterLookup, ConverterProblem, buildNamedConverter, implicitConverter, kindText } from "./converters";
import { OutputView } from "./outputs";
import { resolveShaderTarget, resolvedTarget } from "./shader_targets";
import { SceneData, applySceneData, sceneDataOf } from "./scene_data";
import { EVENT_FIRED_SIGNAL } from "../runtime/events";
import { CLI } from "../../base/names";

// Two numbers within this, relative to the larger (at least 1), are the
// same value.
export const BIND_TOLERANCE: f64 = 1e-5;

// Where the warnings send the reader.
const BINDING_DOC = "docs/formats/RSCN.md \"Bindings\"";

// The node property that sets an instanced scene's data context.
export const DATA_PATH_PROPERTY = "data_path";

// One binding that resolved: its node, target and spec, and the values it
// last applied.
export class ResolvedBinding {
    node: SceneNode;
    target: BindingTarget;
    spec: BindingSpec;
    // The view model's value the last pull applied, and the node's value
    // it gave (of the target's kind, read back from the node: a rotation
    // comes back from the matrix not bit for bit as written); `primed`
    // once the first pull ran. A to_source binding: the node's value it
    // last wrote (`primed` once it wrote one).
    lastSource: BoundValue = new BoundValue();
    lastNode: BoundValue = new BoundValue();
    primed: bool = false;
    // The rotation and scale the node's bindings last wrote (./apply.as
    // BindingPose), one shared by every binding of the node, so that a
    // rotation:x keeps the y and z a rotation:y binding wrote.
    pose: BindingPose;
    // Milestone 42: the paths it may name, the innermost data context's
    // first (one when resolved against a schema), the one chosen (`path`,
    // "" until bound), and the values it was chosen in.
    candidates: Array<string> = [];
    path: string = "";
    boundTo: ViewModelValues? = null;
    // A global binding's values (bindData; null while not found).
    values: ViewModelValues? = null;
    // The converters: scale/offset/convert's, then the named one.
    implicit: Converter? = null;
    converter: Converter? = null;
    // A time-based converter moved: pull again though the source did not
    // change.
    forced: bool = false;
    // A `once` binding that has applied.
    done: bool = false;
    // An enum key the node's property lacks was said (once: the run
    // time's status).
    said: bool = false;
    // Scratch values for the converters, so that a frame allocates nothing.
    a: BoundValue = new BoundValue();

    constructor(node: SceneNode, target: BindingTarget, spec: BindingSpec, pose: BindingPose = new BindingPose()) {
        this.node = node;
        this.target = target;
        this.spec = spec;
        this.pose = pose;
        this.path = spec.path;
        this.candidates = [spec.path];
    }

    // Whether a converter of its chain is time-based.
    timed(): bool {
        const c = this.converter;
        return c != null && c.timed();
    }
}

// Milestone 31: one signal binding that resolved: the node whose signal
// fires the trigger at spec.path, and that trigger once bound.
export class SignalBinding {
    node: SceneNode;
    spec: BindingSpec;
    // The signal's name (the property's after `signal:`).
    signal: string;
    // The trigger (bindTriggers; null until then, or when the bound view
    // model has none at the path: a live view model that is not the file's).
    sink: TriggerSink? = null;
    // How many times it fired the trigger (fireHeld), and the firings held
    // since (fire).
    fired: i32 = 0;
    held: i32 = 0;
    // Milestone 42: the trigger's candidate paths (data contexts), as a
    // ResolvedBinding's.
    candidates: Array<string> = [];

    constructor(node: SceneNode, spec: BindingSpec, signal: string) {
        this.node = node;
        this.spec = spec;
        this.signal = signal;
        this.candidates = [spec.path];
    }
}

export class SceneBindings {
    tree: SceneTree;
    // The scene's view model and its schema (null: none, or it did not
    // resolve; always null for collectLive).
    viewModel: SceneViewModel? = null;
    schema: ViewModelSchema? = null;
    // The bindings that resolved, in tree order, each node's in its order.
    bindings: Array<ResolvedBinding> = [];
    // Milestone 31: the signal bindings that resolved, in the same order,
    // and how many firings they hold (fire; fireHeld fires them).
    signals: Array<SignalBinding> = [];
    held: i32 = 0;
    // What did not resolve (the warnings above), in tree order.
    warnings: Array<Diagnostic> = [];
    // Milestone 42: the values bound (bindData), the view outputs project
    // through (setOutputView), the bindings with a time-based converter,
    // how many writes made a mesh again (costly), and what went wrong
    // while running (an enum key the node lacks), for the run time's
    // status (takeProblems).
    root: ViewModelValues? = null;
    globals: GlobalValues? = null;
    view: OutputView? = null;
    timed: Array<ResolvedBinding> = [];
    rebuilds: i64 = 0;
    problems: Array<string> = [];
    // Scratch values, so that pull and push allocate nothing.
    private source: BoundValue = new BoundValue();
    private value: BoundValue = new BoundValue();
    // Lookups by declaring file (an instanced scene's own converters).
    private lookups: Map<string, ConverterLookup> = new Map<string, ConverterLookup>();

    constructor(tree: SceneTree) {
        this.tree = tree;
    }

    // Resolves every binding of `tree` against its data (./scene_data.as
    // sceneDataOf: the view model's schema and the globals'), its warnings
    // (view-model-unknown, data-source-unreadable) first.
    static collect(tree: SceneTree): SceneBindings {
        const d = sceneDataOf(tree);
        const b = SceneBindings.collectData(tree, d, converterLookupOf(tree, d.source));
        for (let i = d.warnings.length - 1; i >= 0; i--) b.warnings.unshift(d.warnings[i]);
        return b;
    }

    // Resolves every binding of `tree` against `schema` (null: the scene
    // has no view model, or it did not resolve: every binding is then
    // binding-no-view-model) and no globals. collect's seam, for tests
    // that make the schema by hand.
    static collectWith(tree: SceneTree, schema: ViewModelSchema?): SceneBindings {
        const b = new SceneBindings(tree);
        b.viewModel = sceneViewModelOf(tree);
        b.schema = schema;
        b.collectAll(converterLookupOf(tree, null), false, null, null);
        return b;
    }

    // Milestone 42, the tools: resolves every binding against `data`'s
    // schemas (its view model's and its globals'; null: no data), the
    // converters looked up in `lookup`. Warnings about the data itself
    // are `data.warnings`, not repeated here.
    static collectData(tree: SceneTree, data: SceneData?, lookup: ConverterLookup): SceneBindings {
        const b = new SceneBindings(tree);
        b.viewModel = sceneViewModelOf(tree);
        let globals: Array<MemoryViewModel>? = null;
        let source: DataSource? = null;
        if (data != null) {
            const r = data.root;
            b.schema = r != null ? r.schema : null;
            globals = data.globals;
            source = data.source;
        }
        b.collectAll(lookup, false, globals != null ? globals : [], source);
        return b;
    }

    // Milestone 42, the run time: every binding's candidate paths kept
    // (no schema: the live values decide at bind), the converters built
    // from `lookup`. Only what the scene alone tells is a warning.
    static collectLive(tree: SceneTree, lookup: ConverterLookup): SceneBindings {
        const b = new SceneBindings(tree);
        b.viewModel = sceneViewModelOf(tree);
        b.collectAll(lookup, true, null, null);
        return b;
    }

    // Walks the tree: each instanced root's view model checked, each
    // binding resolved. `live`: no schema (collectLive). `globals`: the
    // tools' globals (null: collectWith's none, and no global binding
    // resolves).
    private collectAll(lookup: ConverterLookup, live: bool, globals: Array<MemoryViewModel>?, source: DataSource?): void {
        const tree = this.tree;
        this.lookups.set(rootFile(tree), lookup);
        const all = tree.walk();
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            if (n !== tree.root && !live) this.checkInstanced(n);
            if (n.bindings.length == 0) continue;
            const pose = BindingPose.of(n);
            for (let k = 0; k < n.bindings.length; k++) this.resolve(n, n.bindings[k], pose, lookup, live, globals, source);
        }
        for (let i = 0; i < this.bindings.length; i++) if (this.bindings[i].timed()) this.timed.push(this.bindings[i]);
    }

    // view-model-instanced: `n`, the root of an instanced scene, names a
    // view model other than its context's (see the header). (Any other
    // node that sets view_model is the validator's view-model-not-root.)
    private checkInstanced(n: SceneNode): void {
        const vm = n.viewModel;
        if (vm == null || n.instancePath.length == 0) return;
        const dp = dataPathOf(n);
        const schema = this.schema;
        if (dp.length > 0 && schema != null) {
            // Its context is the nested view model at the data_path (in
            // its parent's context).
            const prefixes = contextPrefixes(n.parent, "");
            let field: VmField? = null;
            for (let k = 0; k < prefixes.length && field == null; k++) {
                const f = schema.field(prefixes[k] + dp);
                if (f != null && f.kind == VmKind.ViewModel) field = f;
            }
            if (field == null || field.reference == vm.viewModel) return;
            const at = viewModelWhere(this.tree, vm);
            const message = "the instanced scene \"" + n.path() + "\" names " + describeViewModel(this.tree, vm)
                + ", but its data_path \"" + dp + "\" holds the view model \"" + field.reference + "\""
                + ": its bindings resolve against \"" + field.reference + "\"";
            const hint = "name \"" + field.reference + "\" in the instanced scene, or point data_path at a property holding \""
                + vm.viewModel + "\"; see " + BINDING_DOC;
            this.warning("view-model-instanced", at.file, at.line, at.col, message, hint);
            return;
        }
        if (dp.length > 0) return;
        const outer = this.viewModel;
        if (outer != null && sameViewModel(vm, outer)) return;
        const at = viewModelWhere(this.tree, vm);
        const theirs = describeViewModel(this.tree, vm);
        const ours = outer != null ? "the scene's, " + describeViewModel(this.tree, outer) : "none (the scene names no view model)";
        const message = "the instanced scene \"" + n.path() + "\" names " + theirs + ", not " + ours
            + ": its bindings resolve against the outermost scene's view model";
        const hint = "name the same view model in both, or none in the instanced scene, or give its instancing node a "
            + "data_path; see " + BINDING_DOC;
        this.warning("view-model-instanced", at.file, at.line, at.col, message, hint);
    }

    // The converter lookup of a binding declared in `file`: the scene's
    // own converters of that file, then `base`'s.
    private lookupFor(file: string, base: ConverterLookup): ConverterLookup {
        if (this.lookups.has(file)) return this.lookups.get(file);
        const l = new ConverterLookup();
        l.scene = sceneConverters(this.tree, file);
        for (let i = 0; i < base.scene.length; i++) l.scene.push(base.scene[i]);
        l.source = base.source;
        this.lookups.set(file, l);
        return l;
    }

    // One binding of `n`: resolved, or a warning.
    private resolve(n: SceneNode, spec: BindingSpec, pose: BindingPose, lookup: ConverterLookup, live: bool,
        globals: Array<MemoryViewModel>?, source: DataSource?): void {
        const cls = n.schemaClass();
        const found = findBindingTarget(cls, spec.property);
        const where = "node \"" + n.path() + "\"";
        if (found == null) {
            const message = where + " (" + cls + ") has no binding target \"" + spec.property + "\"";
            this.warning("binding-property", spec.file, spec.line, spec.col, message, targetsHint(cls));
            return;
        }
        let target: BindingTarget = found;
        // Milestone 61: a shader parameter's kind is its uniform's, which
        // the node's material says (./shader_targets.as).
        if (target.deferred) {
            const info = resolveShaderTarget(n, spec.property);
            if (!info.ok) {
                this.warning("binding-target-missing", spec.file, spec.line, spec.col,
                    where + " binds " + spec.property + ", but " + info.reason, info.hint);
                return;
            }
            target = resolvedTarget(target, info);
        }
        if (target.kind == BindKind.Trigger) {
            this.resolveSignal(n, cls, spec, where, live, globals, source);
            return;
        }
        const output = target.output || isOutputProperty(spec.property);
        if (output && spec.mode != BindingMode.ToSource) {
            const message = where + " binds " + spec.property + ", an output, " + modeText(spec.mode) + ": an output is only read";
            const hint = "write mode=\"to_source\" so that the node's value is written into the view model";
            this.warning("binding-output-mode", spec.file, spec.line, spec.col, message, hint);
            return;
        }
        // The validator refuses a conversion on a non-number target of a
        // typed node; an override's target is known only here, and its
        // conversion would otherwise be dropped without a word.
        if (target.kind != BindKind.Number && !spec.isIdentity()) {
            const message = where + " binds " + spec.property + ", " + withArticle(kindWord(target.kind)) + " target, with "
                + conversionText(spec) + ": it takes none";
            const hint = "remove scale, offset and convert: a " + kindWord(target.kind)
                + " target takes the view model's value as it is (or through a converter)";
            this.warning("binding-conversion", spec.file, spec.line, spec.col, message, hint);
            return;
        }
        const r = new ResolvedBinding(n, target, spec, pose);
        r.implicit = implicitConverter(spec.scale, spec.offset, spec.convert == BindingConvert.DegreesToRadians);
        if (spec.converter.length > 0) {
            const problem = new ConverterProblem();
            const c = buildNamedConverter(spec.converter, this.lookupFor(spec.file, lookup), problem);
            if (c == null) {
                this.warning(problem.code, spec.file, spec.line, spec.col, where + " binds " + spec.property + " through "
                    + problem.message, problem.hint);
                return;
            }
            c.setDirection(spec.mode == BindingMode.ToSource);
            r.converter = c;
        }
        if (live) {
            if (!this.hasResource(n, target, spec, where)) return;
            if (spec.global.length == 0) r.candidates = candidatePaths(n, spec);
            this.bindings.push(r);
            return;
        }
        const schema = this.schemaOf(spec, where, globals, source);
        if (schema == null) return;
        const chosen = this.choosePath(n, spec, r, schema, where, false);
        if (chosen.length == 0) return;
        if (!this.hasResource(n, target, spec, where)) return;
        r.path = chosen;
        r.candidates = [chosen];
        this.bindings.push(r);
    }

    // binding-target-missing: a resource target on a node without that
    // resource; false with the warning.
    private hasResource(n: SceneNode, target: BindingTarget, spec: BindingSpec, where: string): bool {
        if (!hasTargetResource(n, target)) {
            const geometry = spec.property.startsWith("mesh:") && !spec.property.startsWith("mesh:material:");
            // (milestone 62: a camera's or a WorldEnvironment's attributes)
            const attributes = spec.property.startsWith("attributes:") || spec.property.startsWith("camera_attributes:");
            // (milestone 67: the first ArtboardTexture the node shows)
            const artboard = spec.property.startsWith("artboard:");
            const missing = spec.property.startsWith("environment:") ? "environment"
                : attributes ? "camera attributes" : geometry ? "primitive mesh" : artboard ? "artboard texture" : "material";
            const message = where + " has no " + missing + " for " + spec.property;
            const hint = artboard
                ? "give one of its materials (or a sprite's texture, a decal's slot) an ArtboardTexture sub_resource"
                : spec.property.startsWith("environment:")
                ? "set its environment to an Environment sub_resource"
                : attributes
                ? "set its " + (spec.property.startsWith("attributes:") ? "attributes" : "camera_attributes")
                    + " to a CameraAttributesPractical sub_resource"
                : spec.property.startsWith("material:")
                    ? "set its material to a FogMaterial sub_resource"
                    : geometry
                    ? "give it a primitive mesh (BoxMesh, SphereMesh, CylinderMesh, PlaneMesh)"
                    : spec.property.startsWith("mesh:")
                        ? "give its mesh a material (a StandardMaterial3D), or bind material_override:<property>"
                        : "set its material_override to a StandardMaterial3D, or bind mesh:material:<property>";
            this.warning("binding-target-missing", spec.file, spec.line, spec.col, message, hint);
            return false;
        }
        return true;
    }

    // The schema a binding resolves against: its global's, else the
    // scene's view model's; null with the warning when there is none.
    private schemaOf(spec: BindingSpec, where: string, globals: Array<MemoryViewModel>?, source: DataSource?): ViewModelSchema? {
        const bound = where + " binds " + spec.property + " to \"" + spec.path + "\"";
        if (spec.global.length > 0) {
            if (globals != null) {
                for (let i = 0; i < globals.length; i++) if (globals[i].schema.name == spec.global) return globals[i].schema;
            }
            const names = new Array<string>();
            if (globals != null) for (let i = 0; i < globals.length; i++) names.push(globals[i].schema.name);
            const message = bound + " of the global view model \"" + spec.global + "\", which the scene's data does not have";
            const hint = names.length > 0 ? "its global view models: " + names.join(", ")
                : (source != null ? source.label + " declares no global view model" : "the scene has no data (no ViewModel file, and no Rive project above it)");
            this.warning("binding-global-unknown", spec.file, spec.line, spec.col, message, hint);
            return null;
        }
        const schema = this.schema;
        if (schema == null) {
            const why = this.viewModel != null ? "the scene's view model does not resolve" : "the scene names no view model";
            const hint = "set the scene root's view_model to a ViewModel sub_resource; see " + BINDING_DOC;
            this.warning("binding-no-view-model", spec.file, spec.line, spec.col, bound + ", but " + why, hint);
            return null;
        }
        return schema;
    }

    // The path a binding of `n` names in `schema` (see the header): the
    // first candidate naming a property of a kind it takes; "" with the
    // warning when none does. `trigger`: a signal binding's (a trigger).
    private choosePath(n: SceneNode, spec: BindingSpec, r: ResolvedBinding?, schema: ViewModelSchema, where: string,
        trigger: bool): string {
        const candidates = spec.global.length > 0 ? [spec.path] : candidatePaths(n, spec);
        let wrong: VmField? = null;
        let wrongPath = "";
        for (let i = 0; i < candidates.length; i++) {
            const f = schema.field(candidates[i]);
            if (f == null) continue;
            const ok = trigger ? f.kind == VmKind.Trigger : r != null && this.kindsAgree(r, f);
            if (ok) return candidates[i];
            if (wrong == null) {
                wrong = f;
                wrongPath = candidates[i];
            }
        }
        const innermost = candidates[0].substring(0, candidates[0].length - spec.path.length);
        const named = spec.global.length > 0 ? "the global view model " + spec.global : "the view model " + schema.name;
        if (wrong == null) {
            const message = named + " has no property at \"" + spec.path + "\""
                + (innermost.length > 0 ? " (in the data context \"" + innermost.substring(0, innermost.length - 1) + "\" or above it, "
                    + where + ")" : " (" + where + ")");
            const paths = trigger ? schema.triggerPaths() : schema.pathsUnder(innermost);
            const hint = (trigger ? "its triggers: " : "its bindable paths: ") + (paths.length > 0 ? paths.join(", ") : "none");
            this.warning("binding-path-unknown", spec.file, spec.line, spec.col, message, hint);
            return "";
        }
        const w = wrong as VmField;
        if (trigger) {
            const paths = schema.triggerPaths();
            const message = "\"" + wrongPath + "\" is " + withArticle(vmKindName(w.kind)) + " property: " + spec.property
                + " fires a trigger (" + where + ")";
            const hint = "a signal binding's path names a trigger; the view model's triggers: "
                + (paths.length > 0 ? paths.join(", ") : "none");
            this.warning("binding-type", spec.file, spec.line, spec.col, message, hint);
            return "";
        }
        const b = r as ResolvedBinding;
        this.warning("binding-type", spec.file, spec.line, spec.col, this.typeMessage(b, w, wrongPath, where), typeHint(b));
        return "";
    }

    // Whether a view model property of the field's kind and a binding's
    // target agree, through its converters, in its direction.
    private kindsAgree(b: ResolvedBinding, f: VmField): bool {
        const target = b.target.kind;
        if (b.spec.mode == BindingMode.ToSource) {
            let k = targetVmKind(target);
            const c = b.converter;
            if (c != null) k = c.outputKind(k);
            const imp = b.implicit;
            if (imp != null) k = imp.outputKind(k);
            return writable(k, f.kind);
        }
        let k = f.kind;
        const imp = b.implicit;
        if (imp != null) k = imp.outputKind(k);
        const c = b.converter;
        if (c != null) k = c.outputKind(k);
        return takes(k, target);
    }

    private typeMessage(b: ResolvedBinding, f: VmField, path: string, where: string): string {
        const spec = b.spec;
        const head = "\"" + path + "\" is " + withArticle(vmKindName(f.kind)) + " property";
        const c = b.converter;
        if (spec.mode == BindingMode.ToSource) {
            let k = targetVmKind(b.target.kind);
            if (c != null) k = c.outputKind(k);
            return head + ": " + spec.property + " (" + withArticle(bindKindName(b.target.kind)) + ")"
                + (c != null ? ", through the converter \"" + c.name + "\", gives " + (k == VmKind.Other ? "nothing" : kindText(k)) : "")
                + ", which it cannot hold (" + where + ")";
        }
        if (c == null) {
            return head + ": it cannot drive " + spec.property + ", " + withArticle(bindKindName(b.target.kind)) + " (" + where + ")";
        }
        let k = f.kind;
        const imp = b.implicit;
        if (imp != null) k = imp.outputKind(k);
        k = c.outputKind(k);
        return head + ", which the converter \"" + c.name + "\" turns into " + (k == VmKind.Other ? "nothing (it takes no "
            + vmKindName(f.kind) + ")" : kindText(k)) + ": it cannot drive " + spec.property + ", "
            + withArticle(bindKindName(b.target.kind)) + " (" + where + ")";
    }

    // One signal binding of `n` (of class `cls`): resolved, or a warning.
    // Its mode and conversion are checked as it is read (binding.as
    // readBindingDecl refuses them); the rest is checked here, in the order
    // of the other bindings' checks.
    private resolveSignal(n: SceneNode, cls: string, spec: BindingSpec, where: string, live: bool,
        globals: Array<MemoryViewModel>?, source: DataSource?): void {
        const s = new SignalBinding(n, spec, signalTargetName(spec.property));
        if (!live) {
            const schema = this.schemaOf(spec, where, globals, source);
            if (schema == null) return;
            const chosen = this.choosePath(n, spec, null, schema, where, true);
            if (chosen.length == 0) return;
            s.candidates = [chosen];
        } else if (spec.global.length == 0) {
            s.candidates = candidatePaths(n, spec);
        }
        const signal = s.signal;
        if (n.script == null && !hasSignal(cls, signal) && !emitsEvents(n, signal)) {
            const own = classSignals(cls);
            const bound = where + " binds " + spec.property + " to \"" + spec.path + "\"";
            const message = bound + ", but " + cls + " does not emit " + signal + " and the node has no script to emit it";
            const hint = (own.length > 0 ? cls + " emits " + own.join(", ") : cls + " emits no signal of its own")
                + "; a node with a script may emit any signal (emitSignal)";
            this.warning("binding-signal-unknown", spec.file, spec.line, spec.col, message, hint);
            return;
        }
        this.signals.push(s);
    }

    // Looks the trigger of each signal binding up in `values` (null: the
    // view model was unbound, so none fires, and what was held is dropped)
    // or, for a global one, in the globals bound; returns how many were
    // found. Called when the view model is bound, never per frame.
    bindTriggers(values: ViewModelValues?): i32 {
        let found = 0;
        const gs = this.globals;
        for (let i = 0; i < this.signals.length; i++) {
            const b = this.signals[i];
            const g = b.spec.global;
            const vals = g.length > 0 ? (gs != null ? gs.global(g) : null) : values;
            let sink: TriggerSink? = null;
            if (vals != null) {
                for (let k = 0; k < b.candidates.length && sink == null; k++) sink = vals.trigger(b.candidates[k]);
            }
            b.sink = sink;
            if (sink != null) found++;
            else b.held = 0;
        }
        if (values == null && gs == null) this.held = 0;
        return found;
    }

    // Milestone 42: binds the scene's values (`root`, null: none) and the
    // globals (null: none). Each binding's path is chosen again at its
    // next pull or push; the signal bindings' triggers are looked up now,
    // and an OperationViewModel converter reads its operand from the
    // binding's values. Called when the values are bound, and again when
    // a global is found (a live one comes after the first advance).
    bindData(root: ViewModelValues?, globals: GlobalValues?): void {
        this.root = root;
        this.globals = globals;
        for (let i = 0; i < this.bindings.length; i++) {
            const b = this.bindings[i];
            b.boundTo = null;
            const g = b.spec.global;
            const values = g.length > 0 ? (globals != null ? globals.global(g) : null) : root;
            // A binding bound to other values applies again, a `once` one
            // too, as rive's do when their source changes
            // (DataBindContext::bindFromContext binds again). Only those:
            // this runs again when a global is found, which must not apply
            // a `once` binding to the scene's own values a second time.
            if (values !== b.values) {
                b.done = false;
                b.primed = false;
                b.forced = false;
            }
            b.values = values;
        }
        this.bindTriggers(root);
    }

    // The global view models the bindings name, each once, in order.
    globalNames(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.bindings.length; i++) {
            const g = this.bindings[i].spec.global;
            if (g.length > 0 && !out.includes(g)) out.push(g);
        }
        for (let i = 0; i < this.signals.length; i++) {
            const g = this.signals[i].spec.global;
            if (g.length > 0 && !out.includes(g)) out.push(g);
        }
        return out;
    }

    // Milestone 42: whether a binding writes a costly property (a built-in
    // mesh's geometry, a material's pipeline field): the run time's status
    // then says how many such writes the last frame made ("rebuilds").
    writesCostly(): bool {
        const all = this.bindings;
        for (let i = 0; i < all.length; i++) {
            const b = unchecked(all[i]);
            if (b.target.costly && b.spec.mode != BindingMode.ToSource) return true;
        }
        return false;
    }

    // Milestone 42: the view screen outputs project through (null: none,
    // and a to_source binding of one writes nothing).
    setOutputView(v: OutputView?): void {
        this.view = v;
    }

    // Milestone 42: time passes for the time-based converters (an
    // Interpolator), in the data binds' phase before the pull; true when
    // one moved (its binding is pulled again).
    advanceConverters(seconds: f64): bool {
        let moved = false;
        const ts = this.timed;
        for (let i = 0; i < ts.length; i++) {
            const b = unchecked(ts[i]);
            const c = b.converter;
            if (c != null && c.advance(seconds)) {
                b.forced = true;
                moved = true;
            }
        }
        return moved;
    }

    // Milestone 42: what went wrong while running since the last call (an
    // enum key a node's property lacks, said once per binding), for the
    // run time's status; empties the list.
    takeProblems(): Array<string> {
        const p = this.problems;
        if (p.length > 0) this.problems = [];
        return p;
    }

    // `from` emitted `signal`: holds a firing of the trigger of each signal
    // binding of that node and signal (fireHeld fires them; see the
    // header); returns how many. Allocates nothing (names are compared, no
    // string is made).
    fire(from: SceneNode, signal: string): i32 {
        let n = 0;
        const all = this.signals;
        for (let i = 0; i < all.length; i++) {
            const b = unchecked(all[i]);
            if (b.node !== from || b.signal != signal || b.sink == null) continue;
            b.held++;
            n++;
        }
        this.held += n;
        return n;
    }

    // Fires the triggers of the firings held, in declaration order, each
    // as many times as its signal was emitted (a Rive state machine sees a
    // trigger fired twice before it advances as fired); returns how many
    // firings. Allocates nothing.
    fireHeld(): i32 {
        if (this.held == 0) return 0;
        let n = 0;
        const all = this.signals;
        for (let i = 0; i < all.length; i++) {
            const b = unchecked(all[i]);
            const k = b.held;
            if (k == 0) continue;
            b.held = 0;
            const sink = b.sink;
            if (sink == null) continue;
            for (let j = 0; j < k; j++) sink.fire();
            b.fired += k;
            n += k;
        }
        this.held = 0;
        return n;
    }

    private warning(code: string, file: string, line: i32, col: i32, message: string, hint: string): void {
        this.warnings.push(new Diagnostic(Severity.Warning, code, file, line, col, message, hint));
    }

    // The values binding `b` reads and writes with `root` the scene's,
    // its path chosen among its candidates when they are new (null: none,
    // or no candidate names a property there).
    private valuesOf(b: ResolvedBinding, root: ViewModelValues?): ViewModelValues? {
        const vals = b.spec.global.length > 0 ? b.values : root;
        if (vals == null) return null;
        if (b.boundTo !== vals) {
            b.boundTo = vals;
            b.path = "";
            const cs = b.candidates;
            for (let i = 0; i < cs.length; i++) {
                if (vals.kindOf(cs[i]) != VmKind.Other) {
                    b.path = cs[i];
                    break;
                }
            }
            const c = b.converter;
            if (c != null) c.bind(vals);
        }
        return b.path.length > 0 ? vals : null;
    }

    // View model to nodes with the values bound (bindData).
    pullBound(): i32 {
        return this.pullWith(this.root);
    }

    // Nodes to view model with the values bound (bindData).
    pushBound(): i32 {
        return this.pushWith(this.root);
    }

    // View model to nodes (see the header), `values` the scene's (global
    // bindings read their own); returns how many bindings wrote their
    // node. Allocates nothing once primed while no value changes (a
    // changed node property makes its Value: ./apply.as).
    pull(values: ViewModelValues): i32 {
        return this.pullWith(values);
    }

    // Nodes to view model, two_way and to_source bindings (see the
    // header); returns how many wrote the view model. A two_way binding not
    // yet pulled has nothing to compare with and is left alone.
    push(values: ViewModelValues): i32 {
        return this.pushWith(values);
    }

    private pullWith(root: ViewModelValues?): i32 {
        let n = 0;
        const src = this.source;
        const out = this.value;
        const all = this.bindings;
        for (let i = 0; i < all.length; i++) {
            const b = unchecked(all[i]);
            const mode = b.spec.mode;
            if (mode == BindingMode.ToSource || b.done) continue;
            const vals = this.valuesOf(b, root);
            if (vals == null || !vals.read(b.path, src)) continue;
            if (b.primed && !b.forced && src.equals(b.lastSource)) continue;
            b.forced = false;
            if (!this.toNode(b, src, out)) continue;
            if (!writeTarget(this.tree, b.node, b.target, out, b.pose)) {
                this.refused(b, out);
                continue;
            }
            // (a costly target: a built-in mesh made again, or a material's
            // pipeline field, which makes a new variant)
            if (lastWriteRebuilt() || b.target.costly) this.rebuilds++;
            b.lastSource.copyFrom(src);
            if (!readTarget(b.node, b.target, b.lastNode, b.pose, this.view)) b.lastNode.copyFrom(out);
            b.primed = true;
            if (b.spec.once) b.done = true;
            n++;
        }
        return n;
    }

    private pushWith(root: ViewModelValues?): i32 {
        let n = 0;
        const now = this.value;
        const out = this.source;
        const all = this.bindings;
        for (let i = 0; i < all.length; i++) {
            const b = unchecked(all[i]);
            const mode = b.spec.mode;
            if (mode == BindingMode.OneWay || b.done) continue;
            const toSource = mode == BindingMode.ToSource;
            if (!toSource && !b.primed) continue;
            const vals = this.valuesOf(b, root);
            if (vals == null) continue;
            if (!readTarget(b.node, b.target, now, b.pose, this.view)) continue;
            // A to_source binding through a time-based converter pushes
            // while the converter moves although the node holds still: its
            // value reaches the end over the frames after the node's change.
            const forced = toSource && b.forced;
            if (b.primed && !forced && now.equals(b.lastNode, BIND_TOLERANCE)) continue;
            if (toSource) b.forced = false;
            if (!this.toSource(b, now, out, toSource)) continue;
            if (!vals.write(b.path, out)) continue;
            // What the view model holds now (a Rive number is an f32), so
            // that the next pull sees no change.
            if (!vals.read(b.path, b.lastSource)) b.lastSource.copyFrom(out);
            b.lastNode.copyFrom(now);
            b.primed = true;
            if (toSource && b.spec.once) b.done = true;
            n++;
        }
        return n;
    }

    // The node's value for the view model's `src` (pull): through the
    // converters, then taken by the target's kind (a number to a boolean
    // is not 0). False when the result is of a kind the target does not
    // take (a live view model that is not the file's).
    private toNode(b: ResolvedBinding, src: BoundValue, out: BoundValue): bool {
        let v = src;
        const imp = b.implicit;
        if (imp != null) {
            if (!imp.forward(v, b.a)) return false;
            v = b.a;
        }
        const c = b.converter;
        if (c != null) {
            if (!c.forward(v, out)) return false;
            v = out;
        }
        return coerce(v, b.target.kind, out);
    }

    // The view model's value for the node's `now` (push): a two_way write
    // back through the named converter's reverse, then the implicit one's;
    // a to_source write (`main`) through the named converter forward (its
    // main direction), then the implicit one's reverse. A boolean goes to a
    // number view model as 1 or 0 (ViewModelValues.write).
    private toSource(b: ResolvedBinding, now: BoundValue, out: BoundValue, main: bool): bool {
        let v = now;
        const c = b.converter;
        if (c != null) {
            const ok = main ? c.forward(v, b.a) : c.reverse(v, b.a);
            if (!ok) return false;
            v = b.a;
        }
        const imp = b.implicit;
        if (imp != null) return imp.reverse(v, out);
        out.copyFrom(v);
        if (!main && b.target.kind == BindKind.Boolean && b.lastSource.kind == VmKind.Number) {
            out.setNumber(now.boolean ? 1 : 0);
        }
        return true;
    }

    // A write the node refused: an enum key its property lacks is said
    // once (takeProblems).
    private refused(b: ResolvedBinding, v: BoundValue): void {
        if (b.said || b.target.kind != BindKind.Enum) return;
        b.said = true;
        this.problems.push("node \"" + b.node.path() + "\" binds " + b.spec.property + " to \"" + b.path + "\": "
            + (v.kind == VmKind.Number ? "index " + displayF64(v.number) : "\"" + v.text + "\"") + " is not one of its values");
    }
}

// The view model kind a target's value crosses as (to_source: what the
// node gives).
function targetVmKind(k: BindKind): VmKind {
    switch (k) {
        case BindKind.Number: return VmKind.Number;
        case BindKind.Boolean: return VmKind.Boolean;
        case BindKind.Color: return VmKind.Color;
        case BindKind.String: return VmKind.String;
        case BindKind.Enum: return VmKind.Enum;
        default: return VmKind.Trigger;
    }
}

// Whether a value of kind `k` may drive a target of kind `target` (the
// spec's 5.2): a number a Number (an enum's index only through a
// converter); a boolean or a number a Boolean; a colour a Color; a string
// a String; an enum (by its key), a string (as a key) or a number (an
// index) an Enum.
export function takes(k: VmKind, target: BindKind): bool {
    switch (target) {
        case BindKind.Number: return k == VmKind.Number;
        case BindKind.Boolean: return k == VmKind.Boolean || k == VmKind.Number;
        case BindKind.Color: return k == VmKind.Color;
        case BindKind.String: return k == VmKind.String;
        case BindKind.Enum: return k == VmKind.Enum || k == VmKind.String || k == VmKind.Number;
        default: return k == VmKind.Trigger;
    }
}

// Whether a view model property of kind `prop` may hold a value of kind
// `k` (ViewModelValues.write's rules).
function writable(k: VmKind, prop: VmKind): bool {
    switch (prop) {
        case VmKind.Number: return k == VmKind.Number || k == VmKind.Boolean || k == VmKind.Enum;
        case VmKind.Boolean: return k == VmKind.Boolean || k == VmKind.Number;
        case VmKind.Color: return k == VmKind.Color;
        case VmKind.String: return k == VmKind.String || k == VmKind.Enum;
        case VmKind.Enum: return k == VmKind.Enum || k == VmKind.String || k == VmKind.Number;
        default: return false;
    }
}

// `v` as the target's kind takes it, into `out` (which may be `v`).
function coerce(v: BoundValue, target: BindKind, out: BoundValue): bool {
    if (!takes(v.kind, target)) return false;
    if (target == BindKind.Boolean && v.kind == VmKind.Number) {
        out.setBoolean(v.number != 0);
        return true;
    }
    if (v !== out) out.copyFrom(v);
    return true;
}

function typeHint(b: ResolvedBinding): string {
    if (b.converter != null) return "the converter's result must be of a kind the target takes: a number target a number, "
        + "a boolean one a boolean or a number, a color one a color, a string one a string, an enum one an enum or a number";
    return "a number target takes a number, a boolean one a boolean or a number, a color one a color, "
        + "a string one a string, an enum one an enum (by its key) or a number (its index); a converter turns one into another";
}

// The data_path an instancing node sets ("" none).
export function dataPathOf(n: SceneNode): string {
    if (n.instancePath.length == 0) return "";
    const v = n.getProp(DATA_PATH_PROPERTY);
    return v != null ? v.s : "";
}

// The data context prefixes of what is inside `n` (and `n` itself), the
// innermost first and "" (the root's) last: each instancing node from `n`
// up with a data_path adds one, `prefix + data_path + "/"`. `skipOwn`: the
// file that declares the binding. An override (a binding a scene declares
// on a node of a scene it instances, the instancing node or any node below
// it) belongs to the declaring file's context, so the data_paths of the
// nodes walked while still inside the instanced scenes do not apply: the
// walk counts them only from the first node of the declaring file up (an
// instance root's sceneFile is the instanced file, so its own data_path is
// skipped for an override and kept for a binding its own file declares).
function contextPrefixes(n: SceneNode?, skipOwn: string): Array<string> {
    const paths = new Array<string>();
    let at = n;
    let inside = skipOwn.length > 0;
    while (at != null) {
        if (inside && at.sceneFile == skipOwn) inside = false;
        const dp = dataPathOf(at);
        if (dp.length > 0 && !inside) paths.push(dp);
        at = at.parent;
    }
    // paths: innermost first; the prefixes compose from the outermost.
    const prefixes = new Array<string>();
    let acc = "";
    for (let i = paths.length - 1; i >= 0; i--) {
        acc += paths[i] + "/";
        prefixes.push(acc);
    }
    prefixes.reverse();
    prefixes.push("");
    return prefixes;
}

// The candidate paths of a binding of `n`, the innermost context's first
// (the spec's 5.3).
export function candidatePaths(n: SceneNode, spec: BindingSpec): Array<string> {
    const prefixes = contextPrefixes(n, spec.file);
    const out = new Array<string>();
    for (let i = 0; i < prefixes.length; i++) out.push(prefixes[i] + spec.path);
    return out;
}

// Milestone 46: the candidate paths of `path` read by what the scene file
// `file` declares at `node` (a state machine's conditions and blend inputs:
// `node` the scene's root, `file` its file), the innermost data context's
// first, "" (the outermost scene's) last: as a binding of `file` on `node`
// would resolve it (candidatePaths).
export function contextCandidates(node: SceneNode, file: string, path: string): Array<string> {
    const prefixes = contextPrefixes(node, file);
    const out = new Array<string>();
    for (let i = 0; i < prefixes.length; i++) out.push(prefixes[i] + path);
    return out;
}

// The scene's view model: its root's `view_model`, or null.
export function sceneViewModelOf(tree: SceneTree): SceneViewModel? {
    return tree.root.viewModel;
}

// The root scene's file as its document names it.
function rootFile(tree: SceneTree): string {
    return tree.loader.displayPath(tree.scenePath);
}

// The converters the scene file `file` declares (EntryKind.Converter
// entries, then a built scene's project converters, RscnDoc
// .projectConverters), in order; none when it is not loaded.
export function sceneConverters(tree: SceneTree, file: string): Array<DataConverterDecl> {
    const out = new Array<DataConverterDecl>();
    const scenes = tree.loader.loaded();
    for (let k = 0; k < scenes.length; k++) {
        const r = scenes[k];
        const isScene = r instanceof PackedScene;
        if (!isScene) continue;
        const doc = (r as PackedScene).doc;
        if (doc == null || doc.file != file) continue;
        for (let i = 0; i < doc.entries.length; i++) {
            const c = doc.entries[i].converter;
            if (c != null) out.push(c);
        }
        for (let i = 0; i < doc.projectConverters.length; i++) out.push(doc.projectConverters[i]);
        break;
    }
    return out;
}

// The converter lookup of `tree`'s bindings: its root scene's converters
// (and a built scene's project converters), then `source`'s.
export function converterLookupOf(tree: SceneTree, source: DataSource?): ConverterLookup {
    const l = new ConverterLookup();
    l.scene = sceneConverters(tree, rootFile(tree));
    l.source = source;
    return l;
}

// The schema of `vm` in `source` (./schema.as schemaOf of the source's
// view models), or why there is none. `sourceErr`: why the source could
// not be read ("" when it was).
export function resolveSchemaIn(tree: SceneTree, vm: SceneViewModel, source: DataSource?, sourceErr: string): Result<ViewModelSchema> {
    if (sourceErr.length > 0) return Result.fail<ViewModelSchema>("ViewModel \"" + vm.id + "\": " + sourceErr);
    if (source == null) {
        const named = vm.rive != null || vm.data != null;
        return Result.fail<ViewModelSchema>("ViewModel \"" + vm.id + "\" names no file"
            + (named ? "" : " and the scene is in no Rive project (no rive.yaml above it)"));
    }
    const s = schemaOf(source.info(), vm.viewModel, vm.instance);
    if (!s.ok) return Result.fail<ViewModelSchema>("ViewModel \"" + vm.id + "\": " + source.label + " has " + s.err);
    return s;
}

// The schema of the scene's view model in its data, or null when the
// scene names none or it does not resolve (collect's warnings say why).
export function viewModelSchemaOf(tree: SceneTree): ViewModelSchema? {
    const d = sceneDataOf(tree);
    const r = d.root;
    return r != null ? r.schema : null;
}

// The tools' view model of `tree`: its schema's values in memory (the
// ViewModel's instance), or null when the scene names none or it does not
// resolve (the warnings say why).
export function memoryViewModelOf(tree: SceneTree): MemoryViewModel? {
    return sceneDataOf(tree).root;
}

// Sets each assignment on `vm`, in order (MemoryViewModel.set); the first
// that fails is the error, as `--data <path>: <why>`.
export function assignData(vm: MemoryViewModel, data: Array<DataAssignment>): Result<bool> {
    for (let i = 0; i < data.length; i++) {
        const r = vm.set(data[i].path, data[i].text);
        if (!r.ok) return r;
    }
    return Result.okv<bool>(true);
}

// What the tools draw: `tree`'s bindings pulled once from its view model
// with `data` set on it (`--data`; a `global/<Name>/...` path sets a
// global). Returns the view model (null when the scene has none), its
// nodes now showing its values. Milestone 17's entry, over
// ./scene_data.as applySceneData.
export function applyViewModel(tree: SceneTree, data: Array<DataAssignment>): Result<MemoryViewModel?> {
    const r = applySceneData(tree, data);
    if (!r.ok) return Result.fail<MemoryViewModel?>(r.err);
    return Result.okv<MemoryViewModel?>(r.value.root);
}

// The warnings of `tree`'s bindings (SceneBindings.collect's, against
// ../data/source.as dataSourceOf: the project's data when a provider is
// installed), for the CLI's `render`, `inspect --check` and the editor's
// Output panel.
export function bindingDiagnostics(tree: SceneTree): Array<Diagnostic> {
    return SceneBindings.collect(tree).warnings;
}

// The view model warning of the data: `vm` does not resolve (`why`).
export function viewModelUnknown(tree: SceneTree, vm: SceneViewModel, why: string): Diagnostic {
    const at = viewModelWhere(tree, vm);
    const hint = "name a view model (and instance) of the scene's data; " + CLI + " inspect <file>.riv or <file>.rml lists them, see "
        + BINDING_DOC;
    return new Diagnostic(Severity.Warning, "view-model-unknown", at.file, at.line, at.col, why, hint);
}

// Whether two ViewModels name one view model: the same file and name (the
// instance is the outermost scene's to choose).
function sameViewModel(a: SceneViewModel, b: SceneViewModel): bool {
    return fileOf(a) == fileOf(b) && a.viewModel == b.viewModel;
}

// The path of the file a ViewModel names ("" for the project's data).
function fileOf(vm: SceneViewModel): string {
    const r = vm.rive;
    if (r != null) return r.path;
    const d = vm.data;
    return d != null ? d.path : "";
}

// `the view model "Dial" of res://ui/dial.riv`, for messages.
function describeViewModel(tree: SceneTree, vm: SceneViewModel): string {
    const f = fileOf(vm);
    return "the view model \"" + vm.viewModel + "\"" + (f.length > 0 ? " of " + tree.loader.displayPath(f) : "");
}

// A position in a scene file.
class Where {
    file: string = "";
    line: i32 = 0;
    col: i32 = 0;
}

// Where the ViewModel sub_resource `vm` is declared: its <sub_resource>
// in the scene that declares it, else that file at 0:0.
function viewModelWhere(tree: SceneTree, vm: SceneViewModel): Where {
    const out = new Where();
    out.file = vm.file;
    const scenes = tree.loader.loaded();
    for (let k = 0; k < scenes.length; k++) {
        const r = scenes[k];
        const isScene = r instanceof PackedScene;
        if (!isScene) continue;
        const doc = (r as PackedScene).doc;
        if (doc == null || doc.file != vm.file) continue;
        const d = doc.findSub(vm.id);
        if (d == null) continue;
        out.line = d.pos.line;
        out.col = d.pos.col;
        break;
    }
    return out;
}

// "a number", "an enum".
function withArticle(word: string): string {
    const c = word.charCodeAt(0);
    const vowel = c == 0x61 || c == 0x65 || c == 0x69 || c == 0x6f || c == 0x75;
    return (vowel ? "an " : "a ") + word;
}

// A target kind as milestone 17's messages wrote it ("colour").
function kindWord(k: BindKind): string {
    return k == BindKind.Color ? "colour" : bindKindName(k);
}

function modeText(m: BindingMode): string {
    return m == BindingMode.TwoWay ? "two_way" : "one_way";
}

// "scale 2, offset 1 and convert degrees_to_radians": the conversion
// attributes `spec` sets, for a binding-conversion warning.
function conversionText(spec: BindingSpec): string {
    const parts = new Array<string>();
    if (spec.scale != 1) parts.push("scale " + displayF64(spec.scale));
    if (spec.offset != 0) parts.push("offset " + displayF64(spec.offset));
    if (spec.convert != BindingConvert.None) parts.push("convert degrees_to_radians");
    if (parts.length == 1) return parts[0];
    return parts.slice(0, parts.length - 1).join(", ") + " and " + parts[parts.length - 1];
}

// The targets of class `cls`, for a binding-property hint.
function targetsHint(cls: string): string {
    const ts = bindingTargetsOf(cls);
    if (ts.length == 0) return cls + " has no binding targets; see " + BINDING_DOC;
    const names = new Array<string>();
    for (let i = 0; i < ts.length; i++) names.push(ts[i].property);
    return "its targets: " + names.join(", ");
}

// (MemoryGlobals is ./values.as's; re-exported for the tools that build
// one beside a SceneBindings.)
export { MemoryGlobals };

// Milestone 45: the root of a scene that declares events emits
// event_fired for each one its timelines (or its scripts) fire
// (../runtime/events.as), with no script of its own: a
// `signal:event_fired` binding there resolves.
function emitsEvents(n: SceneNode, signal: string): bool {
    if (signal != EVENT_FIRED_SIGNAL) return false;
    const a = n.animations;
    return a != null && a.root === n && a.events.length > 0;
}
