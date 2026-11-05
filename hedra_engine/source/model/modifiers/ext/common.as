// The shared helpers of the modifier family this package owns: the `Eval`
// signature, the `ModDef` record, the property sets every deformer shares,
// the owner / weight-field lookups, and the per-modifier test support.
//
// TABLE, find, typeNames and the ExtModifiers implementation live in
// engine/src/source/model/modifiers/ext/table.as.

import { Mesh } from "../../mesh/mod";
import { ModifierEnv } from "../mod";
import { Object, NO_OBJ } from "../../scene";
import { Result, panic } from "../../../../base/util";
import { PropDef, PropKind, Props, prop, validate } from "./props";
import { Field } from "./geom/field";

// What a modifier's evaluator is given and what it may answer: the
// warnings on success, the message on failure. The mesh is changed in
// place (use `assignMesh` from core modifiers to replace it wholesale).
export type Eval = (mesh: Mesh, p: Props, env: ModifierEnv) => Result<Array<string>>;

// One modifier type.
export class ModDef {
    // The name `modifier add` spells, kebab-case.
    kind: string;
    // Blender's name for it, which a new modifier takes.
    display: string;
    // One line for `help modifier add`.
    summary: string;
    props: Array<PropDef>;
    eval: Eval;

    constructor(kind: string, display: string, summary: string, props: Array<PropDef>, evalFn: Eval) {
        this.kind = kind;
        this.display = display;
        this.summary = summary;
        this.props = props;
        this.eval = evalFn;
    }
}

// Property sets shared by several modifiers, so the same knob is spelled
// the same way everywhere (as it is in Blender). Shared objects: never
// mutate them.
export const VERTEX_GROUP: PropDef = prop(
    "vertex-group",
    PropKind.Name(),
    "none",
    "limit the effect to this vertex group, weighted by it",
);
export const INVERT_GROUP: PropDef = prop(
    "invert-vertex-group",
    PropKind.Bool(),
    "false",
    "use one minus the group's weight",
);

// The object owning the stack, when the evaluation has scene context.
export function owner(env: ModifierEnv): Object? {
    const s = env.scene;
    if (s == null || env.object == NO_OBJ) return null;
    return s.objects.get(env.object);
}

// The weight field of `weightField` and whether to invert it.
export class WeightField {
    field: Field;
    invert: bool;
    constructor(field: Field, invert: bool) {
        this.field = field;
        this.invert = invert;
    }
}

// The `Field` a deformer is weighted by, from the `vertex-group` /
// `invert-vertex-group` pair every one of them shares.
//
// Only the vertex group: Blender gives Displace a texture *as well*, in a
// different role — the group scales the effect, the texture is the value
// being displaced — so that one reads its attribute itself.
export function weightField(mesh: Mesh, p: Props, env: ModifierEnv): WeightField {
    const field = Field.build(mesh, owner(env), p.str("vertex-group"), "");
    return new WeightField(field, p.bool("invert-vertex-group"));
}

// One vertex's weight, with the invert flag folded in.
export function weightAt(field: Field, invert: bool, v: u32): f32 {
    const w = field.at(v);
    return invert ? <f32>1.0 - w : w;
}

// ---------------------------------------------------------------------------
// Test support: helpers the per-modifier tests share.

// Every property at its default, with `overrides` (pairs `[name, value]`)
// applied through the same validation `modifier set` uses — so a test
// cannot set a value the command line could not.
export function props(defs: Array<PropDef>, overrides: Array<Array<string>>): Map<string, string> {
    const map = new Map<string, string>();
    for (let i = 0; i < defs.length; i++) map.set(defs[i].name, defs[i].default);
    for (let i = 0; i < overrides.length; i++) {
        const name = overrides[i][0];
        const value = overrides[i][1];
        let def: PropDef? = null;
        for (let j = 0; j < defs.length; j++) {
            if (defs[j].name == name) {
                def = defs[j];
                break;
            }
        }
        if (def == null) {
            panic("no property '" + name + "'");
            return map;
        }
        const stored = validate(def, value);
        if (!stored.ok) panic(name + ": " + stored.err);
        map.set(name, stored.value);
    }
    return map;
}

// Run an evaluator and return its warnings, asserting it succeeded and
// that the mesh it produced is still valid. The caller passes the
// modifier's PROPS as `defs`.
export function evalWith(f: Eval, mesh: Mesh, map: Map<string, string>, defs: Array<PropDef>): Array<string> {
    const r = f(mesh, new Props(map, defs), new ModifierEnv());
    if (!r.ok) panic("evaluation failed: " + r.err);
    const ok = mesh.validate();
    if (!ok.ok) panic("the evaluated mesh is valid: " + ok.err);
    return r.value;
}

// Run an evaluator that is expected to fail, and return the message.
export function evalErr(f: Eval, mesh: Mesh, map: Map<string, string>, defs: Array<PropDef>): string {
    const r = f(mesh, new Props(map, defs), new ModifierEnv());
    if (r.ok) panic("expected this evaluation to fail");
    return r.err;
}
