// A document's resources: every ext_resource loaded (through the loader,
// so shared with every other document that names the same file) and every
// sub_resource built from its properties, in declaration order (a
// sub_resource may name only those declared before it, so there is no
// cycle to find). The scene tree resolves ExtResource("id") and
// SubResource("id") values of the document against them.

import { FogMaterial, setFogMaterialField } from "./fog_material";
import { CameraAttributesPractical, setCameraAttributesField } from "./camera_attributes";
import { NavigationMesh, setNavigationMeshField } from "./navigation_mesh";
import { Occluder3D, newOccluder, setOccluderField } from "./occluders";
import { Result, f64ToI32 } from "../../base/util";
import { vfs } from "../../fs/vfs";
import { SceneryError, sceneryErrorOf } from "../error";
import { MATERIAL_TEXTURE_PROPS, MATERIAL_UV_SUFFIXES, classInfo, findProp, isA, shaderParameterOf } from "../classdb";
import { Value, ValueKind } from "../value";
import { Declaration, ExtResourceDecl, Property, RscnDoc, SubResourceDecl } from "../rscn/doc";
import {
    ArtboardTexture, BoxShape3D, CapsuleShape3D, ConcavePolygonShape3D, ConvexPolygonShape3D, CylinderShape3D, Environment, Mesh,
    MultiMesh, PanoramaSkyMaterial, ProceduralSkyMaterial, Resource, RiveData, RiveFile, SceneViewModel, Shape3D, Sky, SphereShape3D,
    StandardMaterial3D, Texture2D, UnknownResource, ViewportTexture,
} from "./types";
import { finishArtboardTexture } from "./artboard_texture";
import { finishViewportTexture } from "./viewport_texture";
import { PrimitiveMesh, newPrimitive, setPrimitiveField, tooLargeHint, tooLargeMessage } from "./primitives";
import { ResourceLoader, standaloneMessage } from "./loader";
import { extPathHint } from "./model_hints";
// Milestone 32: a Path3D's curve.
import { CURVE_POINT_STRIDE, Curve3D } from "../path/curve3d";
import { CURVE_BAKE_MAX, Curve } from "./curve";
import { Gradient } from "./gradient";
import { Shader, ShaderMaterial } from "./shader";

export class DocResources {
    doc: RscnDoc;
    // The absolute path of the document ("" for one built in code: its
    // relative paths resolve against the project root).
    path: string = "";
    ext: Map<string, Resource> = new Map<string, Resource>();
    sub: Map<string, Resource> = new Map<string, Resource>();

    constructor(doc: RscnDoc) {
        this.doc = doc;
    }

    // The resource an ExtResource or SubResource value names, or null (a
    // null value, another kind, or an id the document does not declare).
    get(v: Value): Resource? {
        if (v.kind == ValueKind.ExtResource) return this.ext.has(v.s) ? this.ext.get(v.s) : null;
        if (v.kind == ValueKind.SubResource) return this.sub.has(v.s) ? this.sub.get(v.s) : null;
        return null;
    }

    // The type an ExtResource or SubResource value's declaration gives, or
    // "" when the document declares no such id (or the value is neither).
    declaredType(v: Value): string {
        if (v.kind == ValueKind.ExtResource) {
            const exts = this.doc.extResources();
            for (let i = 0; i < exts.length; i++) if (exts[i].id == v.s) return exts[i].type;
        } else if (v.kind == ValueKind.SubResource) {
            const subs = this.doc.subResources();
            for (let i = 0; i < subs.length; i++) if (subs[i].id == v.s) return subs[i].type;
        }
        return "";
    }
}

// Loads every ext_resource of the document and builds every sub_resource.
// `path` is the document's absolute path ("" for one built in code).
//
// Where a problem is reported: a problem with the named file as a whole (it
// cannot be read, has the wrong extension, is not a model) comes from the
// loader without a position and is reported at the ext_resource's path
// attribute, its message naming the file; a problem at a position inside
// the named file (a syntax error in a nested .rscn) keeps that position and
// gets the ext_resource as a "required by" entry. An ext_resource of a type
// this format version does not know is skipped (the validator warned about
// it; the validator also refuses every use of it).
//
// `only` (milestone 14): the ids to load and build, the others left out;
// null for all of them. The editor's preview of one material builds just
// what it names (usedBy) rather than every mesh and scene of the document.
export function resolveResources(doc: RscnDoc, path: string, loader: ResourceLoader, only: Set<string>? = null): Result<DocResources> {
    const res = new DocResources(doc);
    res.path = path;
    const exts = doc.extResources();
    // While the VFS is still asking the host for files (an open world), a
    // file that failed to load may only be unknown yet: the loop goes on,
    // so that one run asks for every file the document names rather than
    // one per run, and the first failure is returned after it.
    let failed: Result<DocResources>? = null;
    for (let i = 0; i < exts.length; i++) {
        if (failed != null && !vfs.incomplete) break;
        const ext = exts[i];
        if (only != null && !only.has(ext.id)) continue;
        const info = classInfo(ext.type);
        if (info == null || !info.extType) continue;
        const where = ext.attrPos("path");
        const abs = loader.resolve(ext.path, path);
        if (!abs.ok) {
            const e = sceneryErrorOf<string>(abs);
            const code = e != null ? e.code : "path-invalid";
            const hint = e != null ? e.hint : null;
            const message = e != null ? e.message : abs.err;
            return SceneryError.at(code, doc.file, where.line, where.col, "ext_resource \"" + ext.id + "\": " + message, hint)
                .fail<DocResources>();
        }
        const r = loader.load(ext.type, abs.value);
        if (!r.ok) {
            if (failed == null) failed = loadFailure(r, doc, ext, where.line, where.col, loader.displayPath(abs.value));
            continue;
        }
        res.ext.set(ext.id, r.value);
    }
    if (failed != null) return failed;
    const subs = doc.subResources();
    for (let i = 0; i < subs.length; i++) {
        if (only != null && !only.has(subs[i].id)) continue;
        const b = buildSubResource(subs[i], res);
        if (!b.ok) return b.forward<DocResources>();
        const made = b.value;
        made.id = subs[i].id;
        made.file = doc.file;
        res.sub.set(subs[i].id, made);
    }
    return Result.okv<DocResources>(res);
}

// The ids a declaration's properties name, and those the sub_resources
// they name name in turn (milestone 14): with the declaration's own id (a
// sub_resource's), what resolveResources(doc, ..., only) must build for it.
// Ids the document does not declare are included; building reports them.
export function usedBy(doc: RscnDoc, decl: Declaration): Set<string> {
    const out = new Set<string>();
    const todo = new Array<Declaration>();
    todo.push(decl);
    while (todo.length > 0) {
        const d = todo.pop();
        const props = d.properties();
        for (let i = 0; i < props.length; i++) namedIds(doc, props[i].value, out, todo);
    }
    return out;
}

// Every ExtResource and SubResource id in `v` (arrays and dictionaries
// walked) into `out`; a sub_resource seen for the first time into `todo`.
function namedIds(doc: RscnDoc, v: Value, out: Set<string>, todo: Array<Declaration>): void {
    if (v.kind == ValueKind.Array || v.kind == ValueKind.Dictionary) {
        for (let i = 0; i < v.keys.length; i++) namedIds(doc, v.keys[i], out, todo);
        for (let i = 0; i < v.items.length; i++) namedIds(doc, v.items[i], out, todo);
        return;
    }
    if (v.kind != ValueKind.ExtResource && v.kind != ValueKind.SubResource) return;
    if (out.has(v.s)) return;
    out.add(v.s);
    if (v.kind == ValueKind.SubResource) {
        const sub = doc.findSub(v.s);
        if (sub != null) todo.push(sub);
    }
}

// The failure of an ext_resource whose file did not load, reported where
// resolveResources says.
function loadFailure(r: Result<Resource>, doc: RscnDoc, ext: ExtResourceDecl, line: i32, col: i32, display: string): Result<DocResources> {
    const e = sceneryErrorOf<Resource>(r);
    if (e == null) {
        return SceneryError.at("file-read", doc.file, line, col, "ext_resource \"" + ext.id + "\": " + r.err, extPathHint(ext.path)).fail<DocResources>();
    }
    if (e.line > 0) {
        e.within(doc.file, ext.pos.line, ext.pos.col, "ext_resource \"" + ext.id + "\" (" + display + ")");
        return e.fail<DocResources>();
    }
    // The file the ext_resource names could not be read: the hint says how
    // its path is read, as inspect --check does; any other error keeps its
    // own.
    const hint = e.code == "file-read" ? extPathHint(ext.path) : e.hint;
    const moved = SceneryError.at(e.code, doc.file, line, col, "ext_resource \"" + ext.id + "\": " + standaloneMessage(e), hint);
    for (let k = 0; k < e.trace.length; k++) moved.trace.push(e.trace[k]);
    return moved.fail<DocResources>();
}

// Builds one sub_resource from its properties (defaults from ../classdb.as;
// resource-valued properties resolved against `res`, which holds every
// earlier one). An unknown type gives an UnknownResource.
//
// A property the class does not have, or whose value has the wrong type,
// is passed over (the field keeps its default): the validator reported it,
// and a newer file's additions must not stop an older tool. A resource
// value is checked here, since only here is the resource known: naming
// a resource of the wrong class is property-resource-class, naming none
// resource-undeclared, both at the value. A built-in mesh above the vertex
// limit is primitive-too-large, at the sub_resource.
export function buildSubResource(decl: SubResourceDecl, res: DocResources): Result<Resource> {
    const type = decl.type;
    const info = classInfo(type);
    if (info == null || !info.subResource) {
        const u = new UnknownResource(type);
        const props = decl.properties();
        for (let i = 0; i < props.length; i++) {
            u.propNames.push(props[i].name);
            u.propValues.push(props[i].value);
        }
        const nameProp = decl.property("resource_name");
        if (nameProp != null && nameProp.value.kind == ValueKind.String) u.name = nameProp.value.s;
        return Result.okv<Resource>(u);
    }
    const primitive = newPrimitive(type);
    const shape = newShape(type);
    // Milestone 37: an occluder shape.
    const occluder = newOccluder(type);
    let made: Resource;
    if (primitive != null) made = primitive;
    else if (shape != null) made = shape;
    else if (occluder != null) made = occluder;
    else if (type == "FogMaterial") made = new FogMaterial();
    else if (type == "CameraAttributesPractical") made = new CameraAttributesPractical();
    // Milestone 63.
    else if (type == "NavigationMesh") made = new NavigationMesh();
    else if (type == "ShaderMaterial") made = new ShaderMaterial();
    else if (type == "StandardMaterial3D") made = new StandardMaterial3D();
    else if (type == "Sky") made = new Sky();
    else if (type == "ProceduralSkyMaterial") made = new ProceduralSkyMaterial();
    else if (type == "PanoramaSkyMaterial") made = new PanoramaSkyMaterial();
    else if (type == "MultiMesh") made = new MultiMesh();
    else if (type == "ArtboardTexture") made = new ArtboardTexture();
    else if (type == "ViewportTexture") made = new ViewportTexture();
    else if (type == "ViewModel") made = new SceneViewModel();
    else if (type == "Curve3D") made = new Curve3D();
    else if (type == "Curve") made = new Curve();
    else if (type == "Gradient") made = new Gradient();
    else made = new Environment();
    const props = decl.properties();
    for (let i = 0; i < props.length; i++) {
        const p = props[i];
        const pi = findProp(type, p.name);
        if (pi == null || !pi.accepts(p.value)) continue;
        const r = setField(made, p, pi.resourceClass, res);
        if (!r.ok) return r.forward<Resource>();
    }
    // Milestone 15: its path, size and placeholder, once its fields are set.
    const isArtboard = made instanceof ArtboardTexture;
    if (isArtboard) finishArtboardTexture(made as ArtboardTexture, res.path, decl.id);
    // Milestone 34: likewise a ViewportTexture's path, size and blank image.
    const isViewport = made instanceof ViewportTexture;
    if (isViewport) finishViewportTexture(made as ViewportTexture, res.path, decl.id);
    // The validator refuses the same mesh; this keeps a document built in
    // code (not validated) from asking generate() for it.
    if (primitive != null && primitive.tooLarge()) {
        return SceneryError.at("primitive-too-large", res.doc.file, decl.pos.line, decl.pos.col,
            tooLargeMessage(primitive, decl.id), tooLargeHint(primitive)).fail<Resource>();
    }
    return Result.okv<Resource>(made);
}

// Milestone 35: sets a Curve's field from a property value of the right
// type (the caller checked it against ../classdb.as), in the order the file
// gives them, as Godot's loader does: `_data` replaces the points, then
// `point_count` drops points or adds them at (0, 0). bake_resolution is
// held to 1 .. CURVE_BAKE_MAX. Marks the bake stale. Returns whether `name`
// is a field of a Curve (the editor sets fields through it too).
export function setParticleCurveField(c: Curve, name: string, v: Value): bool {
    if (name == "min_value") c.minValue = v.asF32();
    else if (name == "max_value") c.maxValue = v.asF32();
    else if (name == "bake_resolution") c.bakeResolution = min<i32>(max<i32>(v.asI32(), 1), CURVE_BAKE_MAX);
    else if (name == "_data") c.setData(v);
    else if (name == "point_count") c.setPointCount(v.asI32());
    else return false;
    c.dirty = true;
    return true;
}

// Milestone 35: sets a Gradient's field likewise: `offsets` and `colors`
// are paired into its stops once either is set (Gradient.setStops).
// Returns whether `name` is a field of a Gradient.
export function setGradientField(g: Gradient, name: string, v: Value): bool {
    if (name == "offsets") {
        g.rawOffsets = v.n;
        g.setStops();
    } else if (name == "colors") {
        g.rawColors = v.n;
        g.setStops();
    } else if (name == "interpolation_mode") g.interpolationMode = v.asI32();
    else if (name == "interpolation_color_space") g.colorSpace = v.asI32();
    else return false;
    return true;
}

// Milestone 31: a new shape of a sub_resource type (../classdb.as), with
// Godot's defaults, or null when `type` is no concrete shape.
export function newShape(type: string): Shape3D? {
    if (type == "BoxShape3D") return new BoxShape3D();
    if (type == "SphereShape3D") return new SphereShape3D();
    if (type == "CapsuleShape3D") return new CapsuleShape3D();
    if (type == "CylinderShape3D") return new CylinderShape3D();
    if (type == "ConvexPolygonShape3D") return new ConvexPolygonShape3D();
    if (type == "ConcavePolygonShape3D") return new ConcavePolygonShape3D();
    return null;
}

// Milestone 31: sets a shape's field from a property value of the right
// type (the caller checked it against ../classdb.as) and drops what was
// prepared from the old fields (Shape3D.changed). Returns whether `name`
// is a field of the shape's class. Loading, the editor's live handle drag
// and its Inspector set fields through it.
export function setShapeField(s: Shape3D, name: string, v: Value): bool {
    let known = true;
    if (name == "margin") {
        s.margin = v.asF64();
    } else {
        const cls = s.className();
        if (cls == "BoxShape3D" && name == "size") (s as BoxShape3D).size = v.vec3();
        else if (cls == "SphereShape3D" && name == "radius") (s as SphereShape3D).radius = v.asF64();
        else if (cls == "CapsuleShape3D" && name == "radius") (s as CapsuleShape3D).radius = v.asF64();
        else if (cls == "CapsuleShape3D" && name == "height") (s as CapsuleShape3D).height = v.asF64();
        else if (cls == "CylinderShape3D" && name == "radius") (s as CylinderShape3D).radius = v.asF64();
        else if (cls == "CylinderShape3D" && name == "height") (s as CylinderShape3D).height = v.asF64();
        else if (cls == "ConvexPolygonShape3D" && name == "points") (s as ConvexPolygonShape3D).points = v.n.slice(0);
        else if (cls == "ConcavePolygonShape3D" && name == "data") (s as ConcavePolygonShape3D).data = v.n.slice(0);
        else if (cls == "ConcavePolygonShape3D" && name == "backface_collision") (s as ConcavePolygonShape3D).backfaceCollision = v.b;
        else known = false;
    }
    if (known) s.changed();
    return known;
}

// Milestone 32: sets a curve's field from a property value of the right
// type (the caller checked it against ../classdb.as), in the order the
// file gives them, as Godot's loader does: `_data` replaces the points
// (Godot's _set_data; one without both keys, with "points" not a
// PackedVector3Array or "tilts" not a PackedFloat32Array, or whose points
// are not nine numbers a point, changes nothing: the validator's
// curve-data says why), and `point_count` then drops points or adds them
// at the origin (Godot's set_point_count). A tilt `_data` lacks is 0, one
// over is left out. Marks the bake stale.
// Returns whether `name` is a field of a curve. Loading and the editor's
// live drag set fields through it.
export function setCurveField(c: Curve3D, name: string, v: Value): bool {
    if (name == "closed") {
        c.closed = v.b;
    } else if (name == "bake_interval") {
        c.bakeInterval = v.asF32();
    } else if (name == "up_vector_enabled") {
        c.upVectorEnabled = v.b;
    } else if (name == "point_count") {
        c.setPointCount(v.asI32());
        return true;
    } else if (name == "_data") {
        const pts = dictionaryItem(v, "points");
        const tilts = dictionaryItem(v, "tilts");
        if (pts == null || tilts == null || pts.kind != ValueKind.PackedVector3Array) return true;
        // (tilts of another kind keep nothing either: the validator's
        // curve-data says the curve keeps no points from such a _data)
        if (tilts.kind != ValueKind.PackedFloat32Array) return true;
        if (pts.n.length % CURVE_POINT_STRIDE != 0) return true;
        const count = pts.n.length / CURVE_POINT_STRIDE;
        c.points = pts.n.slice(0);
        const t = new Array<f64>(count);
        const have = tilts.n;
        for (let i = 0; i < count; i++) t[i] = i < have.length ? have[i] : 0;
        c.tilts = t;
    } else {
        return false;
    }
    c.markDirty();
    return true;
}

// The item of a Dictionary value under the String (or StringName) key
// `key`, or null.
export function dictionaryItem(d: Value, key: string): Value? {
    if (d.kind != ValueKind.Dictionary) return null;
    for (let i = 0; i < d.keys.length && i < d.items.length; i++) {
        const k = d.keys[i];
        if ((k.kind == ValueKind.String || k.kind == ValueKind.StringName) && k.s == key) return d.items[i];
    }
    return null;
}

// The resource a resource-valued property names: null for a null value;
// an error when the id is not declared or the resource is not a `want`.
function resourceOf(p: Property, want: string, res: DocResources): Result<Resource?> {
    const v = p.value;
    if (v.kind == ValueKind.Nil) return Result.okv<Resource?>(null);
    const file = res.doc.file;
    const r = res.get(v);
    const ext = v.kind == ValueKind.ExtResource;
    const text = (ext ? "ExtResource" : "SubResource") + "(\"" + v.s + "\")";
    if (r == null) {
        // Worded as the validator words it; an ext_resource of a type this
        // version does not know is not loaded, so it names nothing either.
        return SceneryError.at("resource-undeclared", file, p.valuePos.line, p.valuePos.col,
            "no " + (ext ? "ext_resource" : "sub_resource") + " with id \"" + v.s + "\"").fail<Resource?>();
    }
    // (an UnknownResource answers the type it was declared with, which may
    // name a class it is not: only a validated document never holds one
    // where a known class is wanted)
    const unknown = r instanceof UnknownResource;
    if (unknown || !isA(r.className(), want)) {
        return SceneryError.at("property-resource-class", file, p.valuePos.line, p.valuePos.col,
            p.name + " must be a " + want + ", found " + r.className() + " " + text
            + (unknown ? " (a sub_resource of a type this version does not build)" : "")).fail<Resource?>();
    }
    return Result.okv<Resource?>(r);
}

// A ViewModel's `file`: a RiveFile or a RiveData (their base RiveSource),
// null when unset. (Checked by class rather than through resourceOf's
// RiveSource alone, so that the message names what a ViewModel takes.)
function viewModelFileOf(p: Property, res: DocResources): Result<Resource?> {
    const v = p.value;
    if (v.kind == ValueKind.Nil) return Result.okv<Resource?>(null);
    const r = res.get(v);
    if (r != null && (isA(r.className(), "RiveFile") || r.className() == "RiveData")) return Result.okv<Resource?>(r);
    if (r == null) return resourceOf(p, "RiveSource", res);
    const ext = v.kind == ValueKind.ExtResource;
    const text = (ext ? "ExtResource" : "SubResource") + "(\"" + v.s + "\")";
    return SceneryError.at("property-resource-class", res.doc.file, p.valuePos.line, p.valuePos.col,
        p.name + " must be a RiveFile (.riv) or a RiveData (.rml), found " + r.className() + " " + text).fail<Resource?>();
}

function texture(p: Property, res: DocResources): Result<Texture2D?> {
    const r = resourceOf(p, "Texture2D", res);
    if (!r.ok) return r.forward<Texture2D?>();
    const t = r.value;
    return Result.okv<Texture2D?>(t != null ? t as Texture2D : null);
}

const OK: Result<bool> = Result.okv<bool>(true);

function setField(made: Resource, p: Property, resourceClass: string, res: DocResources): Result<bool> {
    const v = p.value;
    const n = p.name;
    if (n == "resource_name") {
        made.name = v.s;
        return OK;
    }
    // (A bool first, as `isPrimitive` below: an `if` on `instanceof` of a
    // base-typed value is decided at compile time.)
    const isArtboard = made instanceof ArtboardTexture;
    if (isArtboard) {
        const t = made as ArtboardTexture;
        if (n == "file") {
            const r = resourceOf(p, "RiveFile", res);
            if (!r.ok) return r.forward<bool>();
            const f = r.value;
            t.rive = f != null ? f as RiveFile : null;
        } else if (n == "artboard") {
            t.artboard = v.s;
        } else if (n == "state_machine") {
            t.stateMachine = v.s;
        } else if (n == "size") {
            t.sizeX = f64ToI32(v.n[0]);
            t.sizeY = f64ToI32(v.n[1]);
        } else if (n == "render_target_update_mode") {
            // Milestone 67: through the setter only when it changes, so a
            // file's `once` counts one write (as a SubViewport's does).
            const m = v.asI32();
            if (m != t.updateMode) t.updateMode = m;
        } else if (n == "update_fps") {
            t.updateFps = v.asF32();
        }
        return OK;
    }
    // Milestone 34.
    const isViewportTexture = made instanceof ViewportTexture;
    if (isViewportTexture) {
        if (n == "viewport_path") (made as ViewportTexture).viewportPath = v.s;
        return OK;
    }
    // Milestone 17.
    const isViewModel = made instanceof SceneViewModel;
    if (isViewModel) {
        const vm = made as SceneViewModel;
        if (n == "file") {
            // Milestone 42: a .riv (RiveFile) or an .rml (RiveData); unset,
            // the enclosing Rive project's data (../data/source.as
            // dataSourceOf).
            const r = viewModelFileOf(p, res);
            if (!r.ok) return r.forward<bool>();
            const f = r.value;
            vm.rive = null;
            vm.data = null;
            if (f != null) {
                const isData = f instanceof RiveData;
                if (isData) vm.data = f as RiveData;
                else vm.rive = f as RiveFile;
            }
        } else if (n == "view_model") {
            vm.viewModel = v.s;
        } else if (n == "instance") {
            vm.instance = v.s;
        }
        return OK;
    }
    // Milestone 31.
    const isShape = made instanceof Shape3D;
    if (isShape) {
        setShapeField(made as Shape3D, n, v);
        return OK;
    }
    // Milestone 32.
    const isCurve = made instanceof Curve3D;
    if (isCurve) {
        setCurveField(made as Curve3D, n, v);
        return OK;
    }
    // Milestone 37.
    const isOccluder = made instanceof Occluder3D;
    if (isOccluder) {
        setOccluderField(made as Occluder3D, n, v);
        return OK;
    }
    const isFog = made instanceof FogMaterial;
    if (isFog) {
        setFogMaterialField(made as FogMaterial, n, v);
        return OK;
    }
    // Milestone 62.
    const isAttributes = made instanceof CameraAttributesPractical;
    if (isAttributes) {
        setCameraAttributesField(made as CameraAttributesPractical, n, v);
        return OK;
    }
    // Milestone 63.
    const isNavMesh = made instanceof NavigationMesh;
    if (isNavMesh) {
        setNavigationMeshField(made as NavigationMesh, n, v);
        return OK;
    }
    // Milestone 35.
    const isParticleCurve = made instanceof Curve;
    if (isParticleCurve) {
        setParticleCurveField(made as Curve, n, v);
        return OK;
    }
    const isGradient = made instanceof Gradient;
    if (isGradient) {
        setGradientField(made as Gradient, n, v);
        return OK;
    }
    const isPrimitive = made instanceof PrimitiveMesh;
    if (isPrimitive) {
        const pm = made as PrimitiveMesh;
        if (n == "material") {
            // (a StandardMaterial3D, or milestone 61's ShaderMaterial, which
            // derives from it here; any other is refused as before)
            const named = res.get(v);
            const shaderMaterial = named != null && named.className() == "ShaderMaterial";
            const r = shaderMaterial ? Result.okv<Resource?>(named) : resourceOf(p, "StandardMaterial3D", res);
            if (!r.ok) return r.forward<bool>();
            const m = r.value;
            pm.material = m != null ? m as StandardMaterial3D : null;
            return OK;
        }
        setPrimitiveField(pm, n, v);
        return OK;
    }
    // Milestone 61: Godot's Material's own two, on every material (a
    // ShaderMaterial is one here: ./shader.as).
    const isAnyMaterial = made instanceof StandardMaterial3D;
    if (isAnyMaterial && (n == "next_pass" || n == "render_priority")) {
        const m = made as StandardMaterial3D;
        if (n == "render_priority") {
            const k = v.asI32();
            m.renderPriority = k < -128 ? -128 : k > 127 ? 127 : k;
            return OK;
        }
        const r = resourceOf(p, "Material", res);
        if (!r.ok) return r.forward<bool>();
        const next = r.value;
        const isStandard = next != null && next instanceof StandardMaterial3D;
        m.nextPass = isStandard ? next as StandardMaterial3D : null;
        return OK;
    }
    // Milestone 61: a ShaderMaterial's shader and parameters (./shader.as;
    // what does not fit its shader is the material's `problems`, which the
    // scene's diagnostics report).
    const isShaderMaterial = made instanceof ShaderMaterial;
    if (isShaderMaterial) {
        const m = made as ShaderMaterial;
        if (n == "shader") {
            const r = resourceOf(p, "Shader", res);
            if (!r.ok) return r.forward<bool>();
            const sh = r.value;
            m.setShader(sh != null ? sh as Shader : null);
            return OK;
        }
        const param = shaderParameterOf(n);
        if (param != null) {
            let tex: Texture2D? = null;
            if (v.isResource()) {
                const t = texture(p, res);
                if (!t.ok) return t.forward<bool>();
                tex = t.value;
            }
            m.declare(param, v, tex);
        }
        return OK;
    }
    const isMaterial = made instanceof StandardMaterial3D;
    if (isMaterial) {
        const m = made as StandardMaterial3D;
        if (resourceClass == "Texture2D") {
            const t = texture(p, res);
            if (!t.ok) return t.forward<bool>();
            const slot = materialTextureSlot(n);
            if (slot >= 0) m.setTextureAt(slot, t.value);
            return OK;
        }
        if (setMaterialPbrField(m, n, v)) return OK;
        if (n == "albedo_color") m.albedoColor = v.vec4();
        else if (n == "metallic") m.metallic = v.asF32();
        else if (n == "roughness") m.roughness = v.asF32();
        else if (n == "emission_enabled") m.emissionEnabled = v.b;
        else if (n == "emission") m.emission = v.vec4();
        else if (n == "emission_energy_multiplier") m.emissionEnergy = v.asF32();
        else if (n == "normal_enabled") m.normalEnabled = v.b;
        else if (n == "normal_scale") m.normalScale = v.asF32();
        else if (n == "ao_enabled") m.aoEnabled = v.b;
        else if (n == "transparency") m.transparency = v.asI32();
        else if (n == "alpha_scissor_threshold") m.alphaScissorThreshold = v.asF32();
        else if (n == "cull_mode") m.cullMode = v.asI32();
        else if (n == "vertex_color_use_as_albedo") m.vertexColorUseAsAlbedo = v.b;
        else if (n == "vertex_color_is_srgb") m.vertexColorIsSrgb = v.b;
        else if (n == "uv1_scale") m.uv1Scale = v.vec3();
        else if (n == "uv1_offset") m.uv1Offset = v.vec3();
        else if (n == "billboard_mode") m.billboardMode = v.asI32();
        else if (n == "billboard_keep_scale") m.billboardKeepScale = v.b;
        return OK;
    }
    // By class name, as ../render/lights.as skyDesc tests the sky materials
    // (`instanceof` trapped there).
    const cls = made.className();
    if (cls == "Sky") {
        const sky = made as Sky;
        if (n == "sky_material") {
            const r = resourceOf(p, "SkyMaterial", res);
            if (!r.ok) return r.forward<bool>();
            sky.skyMaterial = r.value;
        } else if (n == "radiance_size") sky.radianceSize = v.asI32();
        return OK;
    }
    if (cls == "ProceduralSkyMaterial") {
        const m = made as ProceduralSkyMaterial;
        if (n == "sky_top_color") m.skyTopColor = v.vec4();
        else if (n == "sky_horizon_color") m.skyHorizonColor = v.vec4();
        else if (n == "sky_curve") m.skyCurve = v.asF32();
        else if (n == "sky_energy_multiplier") m.skyEnergy = v.asF32();
        else if (n == "ground_bottom_color") m.groundBottomColor = v.vec4();
        else if (n == "ground_horizon_color") m.groundHorizonColor = v.vec4();
        else if (n == "ground_curve") m.groundCurve = v.asF32();
        else if (n == "ground_energy_multiplier") m.groundEnergy = v.asF32();
        else if (n == "sun_angle_max") m.sunAngleMax = v.asF32();
        else if (n == "sun_curve") m.sunCurve = v.asF32();
        else if (n == "energy_multiplier") m.energy = v.asF32();
        return OK;
    }
    if (cls == "MultiMesh") {
        const mm = made as MultiMesh;
        if (n == "mesh") {
            const r = resourceOf(p, "Mesh", res);
            if (!r.ok) return r.forward<bool>();
            const mesh = r.value;
            mm.mesh = mesh != null ? mesh as Mesh : null;
        } else if (n == "transform_format") mm.transformFormat = v.asI32();
        else if (n == "use_colors") mm.useColors = v.b;
        else if (n == "use_custom_data") mm.useCustomData = v.b;
        else if (n == "instance_count") mm.instanceCount = v.asI32();
        else if (n == "visible_instance_count") mm.visibleInstanceCount = v.asI32();
        else if (n == "buffer") mm.buffer = v.n;
        return OK;
    }
    if (cls == "PanoramaSkyMaterial") {
        const m = made as PanoramaSkyMaterial;
        if (n == "panorama") {
            const t = texture(p, res);
            if (!t.ok) return t.forward<bool>();
            m.panorama = t.value;
        } else if (n == "filter") m.filter = v.b;
        else if (n == "energy_multiplier") m.energy = v.asF32();
        return OK;
    }
    const e = made as Environment;
    if (n == "background_mode") e.backgroundMode = v.asI32();
    else if (n == "background_color") e.backgroundColor = v.vec4();
    else if (n == "background_energy_multiplier") e.backgroundEnergy = v.asF32();
    else if (n == "sky") {
        const r = resourceOf(p, "Sky", res);
        if (!r.ok) return r.forward<bool>();
        const sky = r.value;
        e.sky = sky != null ? sky as Sky : null;
    } else if (n == "sky_rotation") e.skyRotation = v.vec3();
    else if (n == "ambient_light_source") e.ambientLightSource = v.asI32();
    else if (n == "ambient_light_color") e.ambientLightColor = v.vec4();
    else if (n == "ambient_light_sky_contribution") e.ambientLightSkyContribution = v.asF32();
    else if (n == "ambient_light_energy") e.ambientLightEnergy = v.asF32();
    else if (n == "reflected_light_source") e.reflectedLightSource = v.asI32();
    else if (n == "sky_top_color") e.skyTopColor = v.vec4();
    else if (n == "sky_horizon_color") e.skyHorizonColor = v.vec4();
    else if (n == "ground_bottom_color") e.groundBottomColor = v.vec4();
    else if (n == "ground_horizon_color") e.groundHorizonColor = v.vec4();
    else if (n == "tonemap_mode") e.tonemapMode = v.asI32();
    else if (n == "tonemap_exposure") e.tonemapExposure = v.asF32();
    else if (n == "tonemap_white") e.tonemapWhite = v.asF32();
    else if (n == "ssr_enabled") e.ssrEnabled = v.b;
    else if (n == "ssr_max_steps") e.ssrMaxSteps = v.asI32();
    else if (n == "ssr_fade_in") e.ssrFadeIn = v.asF32();
    else if (n == "ssr_fade_out") e.ssrFadeOut = v.asF32();
    else if (n == "ssr_depth_tolerance") e.ssrDepthTolerance = v.asF32();
    else if (n == "screen_refraction_enabled") e.screenRefractionEnabled = v.b;
    else if (n == "ssao_enabled") e.ssaoEnabled = v.b;
    else if (n == "ssao_radius") e.ssaoRadius = v.asF32();
    else if (n == "ssao_intensity") e.ssaoIntensity = v.asF32();
    else if (n == "ssao_power") e.ssaoPower = v.asF32();
    else if (n == "ssao_detail") e.ssaoDetail = v.asF32();
    else if (n == "ssao_horizon") e.ssaoHorizon = v.asF32();
    else if (n == "ssao_sharpness") e.ssaoSharpness = v.asF32();
    else if (n == "ssao_light_affect") e.ssaoLightAffect = v.asF32();
    else if (n == "ssao_ao_channel_affect") e.ssaoAoChannelAffect = v.asF32();
    else if (n == "glow_enabled") e.glowEnabled = v.b;
    else if (n.length == 13 && n.startsWith("glow_levels/")) {
        // glow_levels/1 .. /7 (the schema declares no other).
        const k = n.charCodeAt(12) - 48;
        if (k >= 1 && k <= e.glowLevels.length) e.glowLevels[k - 1] = v.asF32();
    } else if (n == "glow_normalized") e.glowNormalized = v.b;
    else if (n == "glow_intensity") e.glowIntensity = v.asF32();
    else if (n == "glow_strength") e.glowStrength = v.asF32();
    else if (n == "glow_mix") e.glowMix = v.asF32();
    else if (n == "glow_bloom") e.glowBloom = v.asF32();
    else if (n == "glow_blend_mode") e.glowBlendMode = v.asI32();
    else if (n == "glow_hdr_threshold") e.glowHdrThreshold = v.asF32();
    else if (n == "glow_hdr_scale") e.glowHdrScale = v.asF32();
    else if (n == "glow_hdr_luminance_cap") e.glowHdrLuminanceCap = v.asF32();
    else if (n == "fog_enabled") e.fogEnabled = v.b;
    else if (n == "fog_mode") e.fogMode = v.asI32();
    else if (n == "fog_light_color") e.fogLightColor = v.vec4();
    else if (n == "fog_light_energy") e.fogLightEnergy = v.asF32();
    else if (n == "fog_sun_scatter") e.fogSunScatter = v.asF32();
    else if (n == "fog_density") e.fogDensity = v.asF32();
    else if (n == "fog_aerial_perspective") e.fogAerialPerspective = v.asF32();
    else if (n == "fog_sky_affect") e.fogSkyAffect = v.asF32();
    else if (n == "fog_height") e.fogHeight = v.asF32();
    else if (n == "fog_height_density") e.fogHeightDensity = v.asF32();
    else if (n == "fog_depth_curve") e.fogDepthCurve = v.asF32();
    else if (n == "fog_depth_begin") e.fogDepthBegin = v.asF32();
    else if (n == "fog_depth_end") e.fogDepthEnd = v.asF32();
    // Milestone 37.
    else if (n == "volumetric_fog_enabled") e.volumetricFogEnabled = v.b;
    else if (n == "volumetric_fog_density") e.volumetricFogDensity = v.asF32();
    else if (n == "volumetric_fog_albedo") e.volumetricFogAlbedo = v.vec4();
    else if (n == "volumetric_fog_emission") e.volumetricFogEmission = v.vec4();
    else if (n == "volumetric_fog_emission_energy") e.volumetricFogEmissionEnergy = v.asF32();
    else if (n == "volumetric_fog_gi_inject") e.volumetricFogGiInject = v.asF32();
    else if (n == "volumetric_fog_anisotropy") e.volumetricFogAnisotropy = v.asF32();
    else if (n == "volumetric_fog_length") e.volumetricFogLength = v.asF32();
    else if (n == "volumetric_fog_detail_spread") e.volumetricFogDetailSpread = v.asF32();
    else if (n == "volumetric_fog_ambient_inject") e.volumetricFogAmbientInject = v.asF32();
    else if (n == "volumetric_fog_sky_affect") e.volumetricFogSkyAffect = v.asF32();
    else if (n == "volumetric_fog_temporal_reprojection_enabled") e.volumetricFogTemporalReprojectionEnabled = v.b;
    else if (n == "volumetric_fog_temporal_reprojection_amount") e.volumetricFogTemporalReprojectionAmount = v.asF32();
    else if (n == "adjustment_enabled") e.adjustmentEnabled = v.b;
    else if (n == "adjustment_brightness") e.adjustmentBrightness = v.asF32();
    else if (n == "adjustment_contrast") e.adjustmentContrast = v.asF32();
    else if (n == "adjustment_saturation") e.adjustmentSaturation = v.asF32();
    return OK;
}

// The PbrSlot a StandardMaterial3D texture property fills (classdb.as
// MATERIAL_TEXTURE_PROPS), or -1.
export function materialTextureSlot(name: string): i32 {
    for (let i = 0; i < MATERIAL_TEXTURE_PROPS.length; i++) if (MATERIAL_TEXTURE_PROPS[i] == name) return i;
    return -1;
}

// Milestone 14: StandardMaterial3D's glTF properties (classdb.as
// materialPbrProps) set from their values; false for any other name.
function setMaterialPbrField(m: StandardMaterial3D, n: string, v: Value): bool {
    if (n == "shading_mode") m.shadingMode = v.asI32();
    else if (n == "ao_strength") m.aoStrength = v.asF32();
    else if (n == "ior") m.ior = v.asF32();
    else if (n == "specular") m.specular = v.asF32();
    else if (n == "specular_color") m.specularColor = v.vec4();
    else if (n == "clearcoat_enabled") m.clearcoatEnabled = v.b;
    else if (n == "clearcoat") m.clearcoat = v.asF32();
    else if (n == "clearcoat_roughness") m.clearcoatRoughness = v.asF32();
    else if (n == "clearcoat_normal_scale") m.clearcoatNormalScale = v.asF32();
    else if (n == "anisotropy_enabled") m.anisotropyEnabled = v.b;
    else if (n == "anisotropy") m.anisotropy = v.asF32();
    else if (n == "anisotropy_rotation") m.anisotropyRotation = v.asF32();
    else if (n == "sheen_color") m.sheenColor = v.vec4();
    else if (n == "sheen_roughness") m.sheenRoughness = v.asF32();
    else if (n == "refraction_enabled") m.refractionEnabled = v.b;
    else if (n == "refraction_scale") m.refractionScale = v.asF32();
    else if (n == "transmission") m.transmission = v.asF32();
    else if (n == "thickness") m.thickness = v.asF32();
    else if (n == "attenuation_distance") m.attenuationDistance = v.asF32();
    else if (n == "attenuation_color") m.attenuationColor = v.vec4();
    else if (n == "dispersion") m.dispersion = v.asF32();
    else if (n == "iridescence") m.iridescence = v.asF32();
    else if (n == "iridescence_ior") m.iridescenceIor = v.asF32();
    else if (n == "iridescence_thickness_minimum") m.iridescenceThicknessMinimum = v.asF32();
    else if (n == "iridescence_thickness_maximum") m.iridescenceThicknessMaximum = v.asF32();
    else if (n == "backlight_enabled") m.backlightEnabled = v.b;
    else if (n == "diffuse_transmission") m.diffuseTransmission = v.asF32();
    else if (n == "backlight") m.backlight = v.vec4();
    else return setMaterialUvField(m, n, v);
    return true;
}

// `<texture property>_texcoord`, `_offset`, `_rotation` or `_scale`.
function setMaterialUvField(m: StandardMaterial3D, n: string, v: Value): bool {
    for (let k = 0; k < MATERIAL_UV_SUFFIXES.length; k++) {
        const suffix = MATERIAL_UV_SUFFIXES[k];
        if (!n.endsWith(suffix)) continue;
        const slot = materialTextureSlot(n.substring(0, n.length - suffix.length));
        if (slot < 0) continue;
        const uv = m.uvs[slot];
        if (k == 0) uv.texcoord = v.asI32();
        else if (k == 1) uv.offset = v.vec2();
        else if (k == 2) uv.rotation = v.asF32();
        else uv.scale = v.vec2();
        return true;
    }
    return false;
}
