// The modifier family this package owns, and the table that describes it.
//
// Each modifier is one `ModDef`: its Blender name, its properties with
// Blender's defaults, and the function that runs it. `TABLE` is the only
// place a new one has to be added — `modifier add`'s type list, its flags,
// `modifier set`'s validation, `modifier list`'s output, `help` and
// `commands --json` are all generated from it.
//
// This file holds TABLE, find, typeNames, install and the `ExtModifiers`
// implementation. The shared helpers (`Eval`, `ModDef`, VERTEX_GROUP /
// INVERT_GROUP, owner, weightField, weightAt, test support) live in
// ./common.

import { Result, cmpStr, stableSort } from "../../../../base/util";
import { Mesh } from "../../mesh/mod";
import { ExtModifiers, ModifierEnv, installExtModifiers } from "../mod";
import { PropDef, Props, validate as validateProp } from "./props";
import { ModDef } from "./common";
import { PROPS as BOOLEAN_PROPS, eval as booleanEval } from "./boolean";
import { PROPS as CAST_PROPS, eval as castEval } from "./cast";
import { PROPS as DECIMATE_PROPS, eval as decimateEval } from "./decimate";
import { PROPS as DISPLACE_PROPS, eval as displaceEval } from "./displace";
import { PROPS as MASK_PROPS, eval as maskEval } from "./mask";
import { PROPS as REMESH_PROPS, eval as remeshEval } from "./remesh";
import { PROPS as SCREW_PROPS, eval as screwEval } from "./screw";
import { PROPS as SHRINKWRAP_PROPS, eval as shrinkwrapEval } from "./shrinkwrap";
import { PROPS as SIMPLE_DEFORM_PROPS, eval as simpleDeformEval } from "./simple_deform";
import { PROPS as SMOOTH_PROPS, eval as smoothEval } from "./smooth";
import { PROPS as WIREFRAME_PROPS, eval as wireframeEval } from "./wireframe";

// Every modifier this package owns, kind-sorted and unique (a test
// enforces it). Shared records: never mutate them.
export const TABLE: Array<ModDef> = [
    new ModDef(
        "boolean",
        "Boolean",
        "Cut, join or intersect with another mesh object",
        BOOLEAN_PROPS,
        booleanEval,
    ),
    new ModDef(
        "cast",
        "Cast",
        "Blend the shape towards a sphere, cylinder or cuboid",
        CAST_PROPS,
        castEval,
    ),
    new ModDef(
        "decimate",
        "Decimate",
        "Reduce the face count by collapse, un-subdivide or planar merge",
        DECIMATE_PROPS,
        decimateEval,
    ),
    new ModDef(
        "displace",
        "Displace",
        "Push vertices along an axis or their normal, by an attribute",
        DISPLACE_PROPS,
        displaceEval,
    ),
    new ModDef(
        "mask",
        "Mask",
        "Show only the faces whose vertices are in a vertex group",
        MASK_PROPS,
        maskEval,
    ),
    new ModDef(
        "remesh",
        "Remesh",
        "Rebuild the surface on a uniform grid (blocks or voxel)",
        REMESH_PROPS,
        remeshEval,
    ),
    new ModDef(
        "screw",
        "Screw",
        "Revolve the profile around an axis, optionally advancing along it",
        SCREW_PROPS,
        screwEval,
    ),
    new ModDef(
        "shrinkwrap",
        "Shrinkwrap",
        "Pull vertices onto the surface of another object",
        SHRINKWRAP_PROPS,
        shrinkwrapEval,
    ),
    new ModDef(
        "simple-deform",
        "SimpleDeform",
        "Twist, bend, taper or stretch around an axis",
        SIMPLE_DEFORM_PROPS,
        simpleDeformEval,
    ),
    new ModDef(
        "smooth",
        "Smooth",
        "Relax vertices towards their neighbours (plain or Laplacian)",
        SMOOTH_PROPS,
        smoothEval,
    ),
    new ModDef(
        "wireframe",
        "Wireframe",
        "Replace the surface with solid bars along its edges",
        WIREFRAME_PROPS,
        wireframeEval,
    ),
];

// The def of one type, or null.
export function find(kind: string): ModDef? {
    for (let i = 0; i < TABLE.length; i++) {
        if (TABLE[i].kind == kind) return TABLE[i];
    }
    return null;
}

let NAMES: Array<string>? = null;

// Every type name, for `modifier add`'s choice list. Built once; the same
// array every call (never mutate it).
export function typeNames(): Array<string> {
    const cached = NAMES;
    if (cached != null) return cached;
    const names: Array<string> = [];
    for (let i = 0; i < TABLE.length; i++) names.push(TABLE[i].kind);
    NAMES = names;
    return names;
}

// `def.props.iter().find(|p| p.name == name)`.
function propOf(def: ModDef, name: string): PropDef? {
    for (let i = 0; i < def.props.length; i++) {
        if (def.props[i].name == name) return def.props[i];
    }
    return null;
}

// The `ExtModifiers` implementation core calls for this package's modifiers.
export class Blender extends ExtModifiers {
    types(): Array<string> {
        return typeNames();
    }

    displayName(kind: string): string? {
        const d = find(kind);
        if (d == null) return null;
        return d.display;
    }

    // The Map is filled in key (byte) order, so iterating it directly gives
    // sorted order; core's readers still sort with `sortedKeys`
    // (shared/src/model/scene), which agrees. A repeated name would keep its last
    // default.
    defaults(kind: string): Map<string, string>? {
        const d = find(kind);
        if (d == null) return null;
        const declared = new Map<string, string>();
        for (let i = 0; i < d.props.length; i++) declared.set(d.props[i].name, d.props[i].default);
        const names = declared.keys();
        stableSort<string>(names, cmpStr);
        const m = new Map<string, string>();
        for (let i = 0; i < names.length; i++) m.set(names[i], declared.get(names[i]));
        return m;
    }

    propNames(kind: string): Array<string> {
        const out: Array<string> = [];
        const d = find(kind);
        if (d == null) return out;
        for (let i = 0; i < d.props.length; i++) out.push(d.props[i].name);
        return out;
    }

    validate(kind: string, prop: string, value: string): Result<string> {
        const d = find(kind);
        if (d == null) return Result.fail<string>("no modifier type '" + kind + "'");
        const p = propOf(d, prop);
        if (p == null) return Result.fail<string>(kind + " modifiers have no property '" + prop + "'");
        return validateProp(p, value);
    }

    evaluate(kind: string, props: Map<string, string>, mesh: Mesh, env: ModifierEnv): Result<Array<string>> {
        const d = find(kind);
        if (d == null) {
            return Result.fail<Array<string>>(
                "'" + kind + "' is not a modifier this build knows; `help modifier add` lists them",
            );
        }
        return d.eval(mesh, new Props(props, d.props), env);
    }
}

// The single instance handed to core.
const EXT: Blender = new Blender();

// Let modifier stacks evaluate this package's modifiers.
export function install(): void {
    installExtModifiers(EXT);
}
