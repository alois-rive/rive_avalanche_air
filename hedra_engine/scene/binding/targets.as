// Milestone 17: what a binding may bind, class by class (docs/scene/
// RSCN.md, "Bindings"). A target is a node property in Godot's property
// path syntax, a `:` before each subname: a vector's component
// ("position:y"), or a property of the resource a node property holds
// ("material_override:albedo_color", "mesh:material:emission"). Each has a
// kind, which decides the view model properties it takes
// (binding.as bindable) and whether a conversion applies (Number only).
//
// The table is the one source of truth: the validator checks a binding's
// `property` against it (../rscn/validate.as), ./apply.as reads and writes
// each target on a SceneNode, RSCN.md lists it, and the editor offers it.
// It imports only classdb, so the validator may use it. RSCN.md's table is
// rendered from it (rscn_binding_test.as compares the two): change a target
// or its doc, and the table between RSCN.md's property-flags markers.
//
// Milestone 42: the table is generated from classdb's flags (PropInfo
// .bindable and .output, docs/plans/RIVE_MODEL.md section 3.1): every
// bindable property of each node class, a vector one as its components
// (`offset:x`); through a MeshInstance3D its material_override's and its
// mesh's material's StandardMaterial3D properties and its mesh's
// PrimitiveMesh ones (`mesh:size:x`, costly: a new mesh); through a
// WorldEnvironment its Environment's (milestone 37: through a FogVolume
// its FogMaterial's, `material:density`); and the outputs, which only a
// to_source binding may name. Format 1's 33 targets come first, as they
// were (FORMAT1_TARGETS), so that their order, kinds and words do not move.
//
// Milestone 31: `signal:<name>` is a family of targets every node class has,
// not rows of the table: it binds the node's signal <name> to a view model
// trigger, which the run time fires each time the node emits it
// (./binder.as, ../runtime/feature_bindings.as). findBindingTarget answers
// one for any well formed name (a script may emit any); bindingTargets()
// and bindingTargetsOf() leave the family out, so the table and the
// editor's list of targets are what they were.
//
// Milestone 48: `blend_shapes/<name>` is a family too, of MeshInstance3D
// (a blend shape's weight, a number: animates, bindable; classdb's
// FAMILY_BLEND_SHAPE). findBindingTarget answers one for any well formed
// name on a MeshInstance3D (which blend shapes there are, only the
// instanced model tells: the binder finds the node's); the table leaves it
// out as it leaves out signals. A Skeleton3D's bone properties animate but
// are not bindable (a binding names a node's property; a bone is not a
// node).
//
// Milestone 61: a ShaderMaterial's `shader_parameter/<name>` is a family
// too, reached through a MeshInstance3D's material_override or its mesh's
// material, and through their next passes (./shader_target_names.as:
// `material_override:shader_parameter/threshold`,
// `mesh:material:next_pass:shader_parameter/tint:x`). findBindingTarget
// answers any well formed one on a MeshInstance3D with `deferred` set and
// kind Number: which kind it is (Color for a source_color uniform, Boolean
// for a bool, Number for a scalar or a component), and whether the
// material has the uniform at all, only the node's material tells, so the
// binder and the timelines resolve it when they bind
// (./shader_targets.as). Godot's ShaderMaterial is on any
// GeometryInstance3D; Hedra's material_override is MeshInstance3D's. The
// table leaves the family out, as it leaves out blend shapes.

import { ClassInfo, PropInfo, PropType, classInfo, classNames, findProp, isA } from "../classdb";
import { BLEND_SHAPES_PREFIX, blendShapeOf } from "../skeleton/names";
import { isShaderTargetName, parseShaderTargetName } from "./shader_target_names";

// What a target holds.
export enum BindKind {
    // A float (a vector's component, an energy, a field of view).
    Number,
    // A bool (visible, current).
    Boolean,
    // A Color, sRGB with straight alpha as every colour of the format.
    Color,
    // Milestone 31: a signal (`signal:<name>`): nothing is read or written,
    // the view model's trigger is fired when the node emits it.
    Trigger,
    // Milestone 42 (appended): a String or StringName property, and an int
    // enum (PropInfo.enumNames), driven by a view model enum's key.
    String,
    Enum,
}

export function bindKindName(k: BindKind): string {
    switch (k) {
        case BindKind.Number: return "number";
        case BindKind.Boolean: return "boolean";
        case BindKind.Trigger: return "trigger";
        case BindKind.String: return "string";
        case BindKind.Enum: return "enum";
        default: return "color";
    }
}

export class BindingTarget {
    // The `property` attribute that names it.
    property: string;
    kind: BindKind;
    // The class that has it (a node class; subclasses have it too).
    owner: string;
    // One line for RSCN.md and the editor.
    doc: string;
    // Milestone 42: an output (PropInfo.output: global_position:x,
    // screen_position:y, screen_visible): read only, so only a to_source
    // binding may name it (binding-output-mode).
    output: bool = false;
    // Milestone 42: the property's other flags (classdb PropInfo): a
    // timeline may key it, and writing it rebuilds GPU data (a mesh, a
    // pipeline). RSCN.md's table prints them.
    animates: bool = false;
    costly: bool = false;
    // Milestone 61: a shader parameter's target, whose kind the node's
    // material decides (./shader_targets.as resolveShaderTarget); `kind` is
    // Number until it is resolved.
    deferred: bool = false;

    constructor(property: string, kind: BindKind, owner: string, doc: string) {
        this.property = property;
        this.kind = kind;
        this.owner = owner;
        this.doc = doc;
    }

    // The flags as RSCN.md's table writes them: "animates, bindable", plus
    // "costly"; "output" alone for an output.
    flagsText(): string {
        if (this.output) return "output";
        const out = new Array<string>();
        if (this.animates) out.push("animates");
        out.push("bindable");
        if (this.costly) out.push("costly");
        return out.join(", ");
    }
}

// The material properties a binding reaches through material_override and
// a mesh's material (a StandardMaterial3D; a material file's material is
// the same class once loaded).
export const MATERIAL_BIND_PROPS: StaticArray<string> = [
    "albedo_color", "emission", "emission_energy_multiplier", "metallic", "roughness",
];

let targetTable: Array<BindingTarget>? = null;

// How many targets format 1 had: the first of bindingTargets(). A binding
// of any other (or an output) needs format 2 (../rscn/doc.as formatNeeded).
export const FORMAT1_TARGETS: i32 = 33;

function add(t: Array<BindingTarget>, property: string, kind: BindKind, owner: string, doc: string): BindingTarget {
    const b = new BindingTarget(property, kind, owner, doc);
    t.push(b);
    return b;
}

function materialKind(name: string): BindKind {
    return name == "albedo_color" || name == "emission" ? BindKind.Color : BindKind.Number;
}

// Format 1's 33 (milestone 17's 29, then milestone 32's four), as they
// were written by hand (their docs are RSCN.md's words): the flags come
// from classdb as every other target's.
function format1(t: Array<BindingTarget>): void {
    const axes = ["x", "y", "z"];
    const vectors = ["position", "rotation", "rotation_degrees", "scale"];
    const before = ["The position along", "The rotation about", "The rotation about", "The scale along"];
    const after = [" (metres, in the parent's space).", " in radians (Euler YXZ, as rotation).", " in degrees.", "."];
    for (let v = 0; v < vectors.length; v++) {
        for (let a = 0; a < axes.length; a++) {
            add(t, vectors[v] + ":" + axes[a], BindKind.Number, "Node3D", before[v] + " " + axes[a] + after[v]);
        }
    }
    add(t, "scale", BindKind.Number, "Node3D", "The scale along all three axes at once (a uniform scale).");
    add(t, "visible", BindKind.Boolean, "Node3D", "Whether the node and its children are drawn.");
    add(t, "light_energy", BindKind.Number, "Light3D", "The light's energy (its strength).");
    add(t, "light_color", BindKind.Color, "Light3D", "The light's colour.");
    add(t, "current", BindKind.Boolean, "Camera3D",
        "The camera the scene is seen through: true makes it current (and no other), false gives the view back.");
    add(t, "fov", BindKind.Number, "Camera3D", "The field of view in degrees.");
    for (let i = 0; i < MATERIAL_BIND_PROPS.length; i++) {
        const m = MATERIAL_BIND_PROPS[i];
        add(t, "material_override:" + m, materialKind(m), "MeshInstance3D",
            "The " + m + " of the node's material_override (a StandardMaterial3D, shared by every node that uses it).");
    }
    for (let i = 0; i < MATERIAL_BIND_PROPS.length; i++) {
        const m = MATERIAL_BIND_PROPS[i];
        add(t, "mesh:material:" + m, materialKind(m), "MeshInstance3D",
            "The " + m + " of the node's mesh's material (shared by every node that uses it).");
    }
    add(t, "modulate", BindKind.Color, "ArtboardSprite3D", "Multiplies the sprite's colour and alpha.");
    // Milestone 32: a follower's place on its path (RSCN.md, "Paths"),
    // format 1's since paths came (a format-1 file binds them).
    add(t, "progress", BindKind.Number, "PathFollow3D",
        "How far along its Path3D's curve it is, in metres (wrapped round with loop, else held to the curve).");
    add(t, "progress_ratio", BindKind.Number, "PathFollow3D",
        "progress as a share of the curve's baked length: 0 at its start, 1 at its end.");
    add(t, "h_offset", BindKind.Number, "PathFollow3D", "How far it sits to the side of the curve, in metres.");
    add(t, "v_offset", BindKind.Number, "PathFollow3D", "How far it sits above the curve, in metres.");
}

// The kind a bindable property of type `p.type` drives (a vector's
// components are numbers).
function kindOf(p: PropInfo): BindKind {
    switch (p.type) {
        case PropType.Bool: return BindKind.Boolean;
        case PropType.Color: return BindKind.Color;
        case PropType.Int: return p.enumNames.length > 0 ? BindKind.Enum : BindKind.Number;
        case PropType.String:
        case PropType.StringName:
            return BindKind.String;
        default: return BindKind.Number;
    }
}

// The components of a vector property ("x", "y"[, "z"]), none for any
// other.
function componentsOf(p: PropInfo): Array<string> {
    if (p.type == PropType.Vector3) return ["x", "y", "z"];
    if (p.type == PropType.Vector2) return ["x", "y"];
    return [];
}

// The doc of a vector's component: "<axis>: " and the property's.
function componentDoc(doc: string, axis: string): string {
    return axis + ": " + doc;
}

// The targets of property `p` named `prefix + p.name` (a component each
// for a vector), owned by `owner`, unless `owner` has one of that name
// already (format 1's, or a property two mesh classes share: the first
// wins; classes apart may each have one, as the lights' shadow_bias).
// `doc` is the row's words for the whole property.
function addProp(t: Array<BindingTarget>, seen: Set<string>, prefix: string, p: PropInfo, owner: string, doc: string): void {
    const name = prefix + p.name;
    const parts = componentsOf(p);
    if (parts.length == 0) {
        if (seen.has(owner + " " + name)) return;
        seen.add(owner + " " + name);
        const b = add(t, name, kindOf(p), owner, doc);
        b.output = p.output;
        b.animates = p.animates;
        b.costly = p.costly;
        return;
    }
    for (let k = 0; k < parts.length; k++) {
        const c = name + ":" + parts[k];
        if (seen.has(owner + " " + c)) continue;
        seen.add(owner + " " + c);
        const b = add(t, c, BindKind.Number, owner, componentDoc(doc, parts[k]));
        b.output = p.output;
        b.animates = p.animates;
        b.costly = p.costly;
    }
}

// Whether `p` is a row of the table: bindable, or an output.
function listed(p: PropInfo): bool {
    return p.bindable || p.output;
}

// The resource classes a sub-property prefix reaches, in the classdb's
// order: the concrete PrimitiveMesh classes, for `mesh:`.
function primitiveMeshClasses(): Array<string> {
    const out = new Array<string>();
    const names = classNames();
    for (let i = 0; i < names.length; i++) {
        const c = classInfo(names[i]) as ClassInfo;
        if (!c.isAbstract && isA(c.name, "PrimitiveMesh")) out.push(c.name);
    }
    return out;
}

function build(): Array<BindingTarget> {
    const t = new Array<BindingTarget>();
    format1(t);
    const seen = new Set<string>();
    for (let i = 0; i < t.length; i++) seen.add(t[i].owner + " " + t[i].property);
    // The flags of format 1's from their properties (the uniform scale is
    // Node3D.scale's; a material's are StandardMaterial3D's).
    for (let i = 0; i < t.length; i++) {
        const b = t[i];
        const colon = b.property.lastIndexOf(":");
        let name = b.property;
        let cls = b.owner;
        if (b.property.startsWith("material_override:") || b.property.startsWith("mesh:material:")) {
            name = b.property.substring(colon + 1);
            cls = "StandardMaterial3D";
        } else if (colon >= 0) {
            name = b.property.substring(0, colon);
        }
        const p = findProp(cls, name);
        if (p != null) {
            b.animates = p.animates;
            b.costly = p.costly;
        }
    }
    // Every node class's own bindable properties, in the classdb's order.
    const names = classNames();
    for (let i = 0; i < names.length; i++) {
        const c = classInfo(names[i]) as ClassInfo;
        if (!c.isNode) continue;
        for (let k = 0; k < c.props.length; k++) {
            const p = c.props[k];
            if (p.bindable) addProp(t, seen, "", p, c.name, p.doc);
        }
    }
    // Through a MeshInstance3D: its materials' and its mesh's (milestone
    // 61: then Godot's Material's, every material's: render_priority).
    const material = classInfo("StandardMaterial3D") as ClassInfo;
    const base = classInfo("Material") as ClassInfo;
    for (let k = 0; k < material.props.length; k++) {
        const p = material.props[k];
        if (listed(p)) {
            addProp(t, seen, "material_override:", p, "MeshInstance3D",
                "The " + p.name + " of the node's material_override (a StandardMaterial3D, shared by every node that uses it): " + p.doc);
        }
    }
    for (let k = 0; k < base.props.length; k++) {
        const p = base.props[k];
        if (listed(p)) {
            addProp(t, seen, "material_override:", p, "MeshInstance3D",
                "The " + p.name + " of the node's material_override (any material, shared by every node that uses it): " + p.doc);
        }
    }
    for (let k = 0; k < material.props.length; k++) {
        const p = material.props[k];
        if (listed(p)) {
            addProp(t, seen, "mesh:material:", p, "MeshInstance3D",
                "The " + p.name + " of the node's mesh's material (shared by every node that uses it): " + p.doc);
        }
    }
    for (let k = 0; k < base.props.length; k++) {
        const p = base.props[k];
        if (listed(p)) {
            addProp(t, seen, "mesh:material:", p, "MeshInstance3D",
                "The " + p.name + " of the node's mesh's material (any material, shared by every node that uses it): " + p.doc);
        }
    }
    const meshes = primitiveMeshClasses();
    for (let m = 0; m < meshes.length; m++) {
        const c = classInfo(meshes[m]) as ClassInfo;
        for (let k = 0; k < c.props.length; k++) {
            const p = c.props[k];
            if (!listed(p)) continue;
            // (the classes that have it, for the row's words)
            const have = new Array<string>();
            for (let j = 0; j < meshes.length; j++) {
                const q = findProp(meshes[j], p.name);
                if (q != null) have.push(meshes[j]);
            }
            addProp(t, seen, "mesh:", p, "MeshInstance3D",
                "The " + p.name + " of the node's mesh, a " + have.join(" or ") + " (shared by every node that uses it; a new mesh is built): "
                    + p.doc);
        }
    }
    // Through a WorldEnvironment: its Environment's.
    const env = classInfo("Environment") as ClassInfo;
    for (let k = 0; k < env.props.length; k++) {
        const p = env.props[k];
        if (listed(p)) addProp(t, seen, "environment:", p, "WorldEnvironment", "The " + p.name + " of the node's environment: " + p.doc);
    }
    // Milestone 37: through a FogVolume, its FogMaterial's.
    const fog = classInfo("FogMaterial") as ClassInfo;
    for (let k = 0; k < fog.props.length; k++) {
        const p = fog.props[k];
        if (listed(p)) {
            addProp(t, seen, "material:", p, "FogVolume",
                "The " + p.name + " of the node's material (a FogMaterial, shared by every FogVolume that uses it): " + p.doc);
        }
    }
    // Milestone 62: through a Camera3D, its CameraAttributesPractical's
    // (Godot's CameraAttributes' first, then its own), and the same through
    // a WorldEnvironment's camera_attributes.
    const attributes = [classInfo("CameraAttributes") as ClassInfo, classInfo("CameraAttributesPractical") as ClassInfo];
    for (let a = 0; a < attributes.length; a++) {
        const c = attributes[a];
        for (let k = 0; k < c.props.length; k++) {
            const p = c.props[k];
            if (listed(p)) {
                addProp(t, seen, "attributes:", p, "Camera3D",
                    "The " + p.name + " of the camera's attributes (a CameraAttributesPractical, shared by every camera that uses it): " + p.doc);
            }
        }
    }
    for (let a = 0; a < attributes.length; a++) {
        const c = attributes[a];
        for (let k = 0; k < c.props.length; k++) {
            const p = c.props[k];
            if (listed(p)) {
                addProp(t, seen, "camera_attributes:", p, "WorldEnvironment",
                    "The " + p.name + " of the node's camera attributes (the cameras' without their own): " + p.doc);
            }
        }
    }
    // Milestone 67: through a node that shows an ArtboardTexture (a
    // GeometryInstance3D's materials, an ArtboardSprite3D's texture, a
    // Decal's slots), the first it shows: its update mode and rate
    // (apply.as firstArtboardTextureOf).
    const artboard = classInfo("ArtboardTexture") as ClassInfo;
    const shows = ["GeometryInstance3D", "Decal"];
    for (let s = 0; s < shows.length; s++) {
        for (let k = 0; k < artboard.props.length; k++) {
            const p = artboard.props[k];
            if (listed(p)) {
                addProp(t, seen, "artboard:", p, shows[s],
                    "The " + p.name + " of the first ArtboardTexture the node shows (shared by every node that shows it): " + p.doc);
            }
        }
    }
    // The outputs, last: read only, for to_source bindings.
    for (let i = 0; i < names.length; i++) {
        const c = classInfo(names[i]) as ClassInfo;
        if (!c.isNode) continue;
        for (let k = 0; k < c.props.length; k++) {
            const p = c.props[k];
            if (p.output) addProp(t, seen, "", p, c.name, p.doc);
        }
    }
    return t;
}

// Every target, in documentation order.
export function bindingTargets(): Array<BindingTarget> {
    const t = targetTable;
    if (t != null) return t;
    const made = build();
    targetTable = made;
    return made;
}

// The targets a node of class `className` has (its own and its bases'), in
// documentation order; none for a class this version does not know.
export function bindingTargetsOf(className: string): Array<BindingTarget> {
    const out = new Array<BindingTarget>();
    const all = bindingTargets();
    for (let i = 0; i < all.length; i++) if (isA(className, all[i].owner)) out.push(all[i]);
    return out;
}

// Whether `property` names an output of some class (global_position:x,
// screen_position:y, screen_visible): what only a to_source binding may
// name, told from the name alone (no other target shares one).
export function isOutputTarget(property: string): bool {
    const all = bindingTargets();
    for (let i = all.length - 1; i >= 0; i--) {
        const t = all[i];
        if (!t.output) break;
        if (t.property == property) return true;
    }
    return false;
}

// Whether `property` names one of format 1's targets (whatever the class),
// or a signal: what a format-1 file may bind.
export function isFormat1Target(property: string): bool {
    if (isSignalTarget(property)) return true;
    const all = bindingTargets();
    for (let i = 0; i < FORMAT1_TARGETS && i < all.length; i++) if (all[i].property == property) return true;
    return false;
}

// What a signal target's property starts with.
export const SIGNAL_TARGET_PREFIX = "signal:";

// The class that has every signal target: each node class.
const SIGNAL_TARGET_OWNER = "Node";

// Whether `property` names a signal target (`signal:` and anything after
// it, well formed or not: signalTargetName says).
export function isSignalTarget(property: string): bool {
    return property.startsWith(SIGNAL_TARGET_PREFIX);
}

// The signal a `signal:<name>` property names, or "" when `property` is no
// signal target or its name is not an identifier ([A-Za-z_][A-Za-z0-9_]*,
// as Godot's signal names are).
export function signalTargetName(property: string): string {
    if (!isSignalTarget(property)) return "";
    const n = property.length;
    const start = SIGNAL_TARGET_PREFIX.length;
    if (n == start) return "";
    for (let i = start; i < n; i++) {
        const c = property.charCodeAt(i);
        const letter = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
        const digit = c >= 0x30 && c <= 0x39;
        if (!letter && !(digit && i > start)) return "";
    }
    return property.substring(start);
}

// The class that has every blend shape target, and milestone 61's shader
// parameter targets.
const BLEND_SHAPE_TARGET_OWNER = "MeshInstance3D";
const SHADER_TARGET_OWNER = "MeshInstance3D";

// Whether `property` names a blend shape target (`blend_shapes/` and a
// name).
export function isBlendShapeTarget(property: string): bool {
    return property.startsWith(BLEND_SHAPES_PREFIX) && blendShapeOf(property) != null;
}

// The target `property` of class `className`, or null when the class has
// no such target. A well formed `signal:<name>` is a Trigger target of
// every node class, a `blend_shapes/<name>` a Number target of a
// MeshInstance3D, and (milestone 61) a shader parameter's a deferred one
// of a MeshInstance3D (each made anew: it is asked for when a scene is
// checked or bound, never per frame).
export function findBindingTarget(className: string, property: string): BindingTarget? {
    if (property.startsWith(BLEND_SHAPES_PREFIX)) {
        const shape = blendShapeOf(property);
        if (shape == null || !isA(className, BLEND_SHAPE_TARGET_OWNER)) return null;
        const t = new BindingTarget(property, BindKind.Number, BLEND_SHAPE_TARGET_OWNER,
            "The weight of the mesh's blend shape " + shape + " (0 to 1).");
        t.animates = true;
        return t;
    }
    if (isShaderTargetName(property)) {
        const t = parseShaderTargetName(property);
        if (t == null || !isA(className, SHADER_TARGET_OWNER)) return null;
        const b = new BindingTarget(property, BindKind.Number, SHADER_TARGET_OWNER,
            "The shader parameter " + t.param + (t.axis >= 0 ? " (one component)" : "") + " of the node's "
                + (property.startsWith("mesh:") ? "mesh's material" : "material_override")
                + (t.hops > 0 ? "'s next pass" : "") + ": a ShaderMaterial's uniform.");
        b.animates = true;
        b.deferred = true;
        return b;
    }
    if (isSignalTarget(property)) {
        const name = signalTargetName(property);
        if (name.length == 0 || !isA(className, SIGNAL_TARGET_OWNER)) return null;
        return new BindingTarget(property, BindKind.Trigger, SIGNAL_TARGET_OWNER,
            "Fires the view model trigger at path each time the node emits " + name + ".");
    }
    const all = bindingTargets();
    for (let i = 0; i < all.length; i++) {
        const t = all[i];
        if (t.property == property && isA(className, t.owner)) return t;
    }
    return null;
}
