// Milestone 17: reading and writing a binding target (./targets.as) on a
// node of a loaded scene (docs/formats/RSCN.md, "Bindings"):
//
// - a vector component sets that component of the node's local transform
//   (the others are kept, as Godot's rotation:y keeps x and z); `scale`
//   alone sets all three; rotation_degrees is converted to radians. The
//   other components come from the node's BindingPose (below) when the
//   caller keeps one, else from the matrix;
// - milestone 32: a PathFollow3D's progress and progress_ratio are
//   written through its setters (Godot's set_progress wraps it round the
//   curve with loop, or holds it to the curve), which place it on its path
//   and keep `progress`'s Value, the node's own, in step (made once, then
//   set in place); progress_ratio, which no file stores (classdb's
//   `derived`), is read and written as progress / the baked length;
// - a typed property (visible, light_energy, light_color, current, fov,
//   modulate) is set as an effective property (SceneNode.setProp) and the
//   node's typed fields re-read (readFields), so a tool that shows the
//   node shows the bound value; `current` true clears every other camera's
//   (Godot's make_current), so the scene is seen through it;
// - a material target sets the field of the StandardMaterial3D the node's
//   material_override or mesh's material holds, which every node using
//   that material shares (Godot's rule for a shared resource). A node
//   without one has nothing to set: writeTarget answers false.
//
// Milestone 42 (docs/plans/RIVE_MODEL.md section 3.1): any bindable
// property, as the generated table names it (./targets.as):
//
// - a node property of any class, by its name (`omni_range`, `offset:y` a
//   vector's component, an enum by its key or index, a string): set as an
//   effective property and the typed fields re-read, as above;
// - a property of a resource the node holds: `material_override:<p>` and
//   `mesh:material:<p>` (a StandardMaterial3D), `mesh:<p>` (a
//   PrimitiveMesh: costly, its triangles are made again),
//   `environment:<p>` (a WorldEnvironment's Environment), milestone 37,
//   `material:<p>` (a FogVolume's FogMaterial) and, milestone 62,
//   `attributes:<p>` (a Camera3D's CameraAttributesPractical) and
//   `camera_attributes:<p>` (a WorldEnvironment's), each written in place
//   by ./material_fields.as;
// - milestone 61: a ShaderMaterial's `shader_parameter/<name>` through
//   material_override: or mesh:material:, and through their next passes
//   (`material_override:next_pass:shader_parameter/<name>`), a vector's
//   component by `:x` to `:w` (./shader_target_names.as), written in place
//   into the material's params by ./material_fields.as;
// - the outputs, read only (a to_source binding's): `global_position:x|y|z`
//   (the node's world origin, metres), `screen_position:x|y` (that origin
//   projected through the view's camera into its points, top left, y down)
//   and `screen_visible`, through an OutputView (./outputs.as); without a
//   valid view, or behind the camera, a screen output reads nothing.
//
// How a target is reached is worked out once per property string
// (accessOf, kept in a map) so a frame allocates nothing to find it.
//
// Colours cross as ARGB bytes (Rive's) and are the format's sRGB with
// straight alpha in the scene: a channel is byte / 255, and back
// round(clamp(x, 0, 1) * 255).
//
// Targets are told apart by comparing the whole property string (no
// substring is made), so a frame that writes bindings allocates nothing for
// a vector component or a resource's field. A node property's first write
// makes its new Value (the effective properties hold the declarations' own
// values, which are never changed in place); milestone 49: the Value is
// the node's own (SceneNode.writtenValues), so a later write of a number,
// a boolean, a colour or a vector sets it in place and allocates nothing
// (a machine or a timeline playing in the editor writes every frame, and
// the editor's memory is never given back). The properties whose Value's
// identity tells a change (bones/ and blend_shapes/: the node applies one
// only when its Value is another) still get a new Value each write.

import { MAT4_NAN, Mat3, Mat4, Vec2, Vec3, Vec4 } from "../../base/vecmath";
import { Value, ValueKind } from "../value";
import {
    AudioListener3D, AudioStreamPlayer3D, CPUParticles3D, Camera3D, Decal, FogVolume, Light3D, ArtboardSprite3D, MeshInstance3D,
    MultiMeshInstance3D, NavigationAgent3D, PathFollow3D, SceneNode, WorldEnvironment,
} from "../tree/node";
import { basisFromEulerYXZ, scaled, withBasis } from "../tree/xform";
import { SceneTree } from "../tree/tree";
import { viewportOf } from "../tree/viewports";
import { PropInfo, PropType, findProp } from "../classdb";
import { VmKind } from "../riv/riv_info";
import { Resource } from "../resource/types";
import { PrimitiveMesh } from "../resource/primitives";
import { BindingTarget } from "./targets";
import { BoundValue } from "./values";
import { OutputView, inFront, onScreen, screenAxis } from "./outputs";
import { BLEND_SHAPES_PREFIX, BONES_PREFIX } from "../skeleton/names";
import {
    F_BOOL, F_COLOR, F_INT, F_NONE, F_NUMBER, F_VEC2, F_VEC4, FIELD_REBUILT, FieldIO, resourceField, writeResourceField,
} from "./material_fields";
import { NEXT_PASS_PREFIX } from "./shader_target_names";
import { ArrayMesh, ArtboardTexture, Mesh, StandardMaterial3D } from "../resource/types";
import { PBR_SLOT_COUNT } from "../../material/pbr";
import { DECAL_TEXTURES } from "../../render/decal";

const DEG: f64 = Math.PI / 180;

// Which vector a component target names: 0 position, 1 rotation, 2
// rotation_degrees, 3 scale; -1 for none.
function vectorOf(p: string): i32 {
    if (p == "position:x" || p == "position:y" || p == "position:z") return 0;
    if (p == "rotation:x" || p == "rotation:y" || p == "rotation:z") return 1;
    if (p == "rotation_degrees:x" || p == "rotation_degrees:y" || p == "rotation_degrees:z") return 2;
    if (p == "scale:x" || p == "scale:y" || p == "scale:z") return 3;
    return -1;
}

// The component a vector target names (0 x, 1 y, 2 z): its last character.
function axisOf(p: string): i32 {
    return p.charCodeAt(p.length - 1) - 0x78;
}

// Milestone 32: which of a PathFollow3D's targets `p` names that its
// setters write (see the header): 0 progress, 1 progress_ratio; -1 for
// any other (its offsets, mode and switches take the generic road: their
// Values set, then readFields places the node).
function followerTarget(p: string): i32 {
    if (p == "progress") return 0;
    if (p == "progress_ratio") return 1;
    return -1;
}

function component(v: Vec3, axis: i32): f64 {
    return axis == 0 ? <f64>v.x : axis == 1 ? <f64>v.y : <f64>v.z;
}

function withComponent(v: Vec3, axis: i32, x: f64): Vec3 {
    const f = <f32>x;
    return axis == 0 ? Vec3(f, v.y, v.z) : axis == 1 ? Vec3(v.x, f, v.z) : Vec3(v.x, v.y, f);
}

// The rotation and scale the bindings last wrote to one node, and the local
// matrix those writes left. The matrix alone cannot give them back: its
// Euler angles come out with X within +-90 degrees (eulerYXZFromBasis), so
// on a node turned 30 degrees about Y, X = 100 reads back as (80, 210,
// 180), and the next write of X = 101 would land at the orientation of X =
// 79 (a hinge swept 0 to 360 would rock back and forth instead of
// turning); a negative scale component reads back as all three negative
// with a half turn folded into the rotation, so a later scale:y = 2 would
// come out as -2. While the node's local matrix is the one the bindings
// left, its components are read and written from here; once something
// else (a script, an animation) has turned or scaled it, they are taken
// from the matrix again (sync). Only the basis is compared: a script that
// moves a bound hinge (setPosition, translate) changes the origin alone,
// and reading the angles back then would bring the fold above back.
export class BindingPose {
    // NaN never compares equal, so the first sync reads the node unless
    // seed took its declared values.
    local: Mat4 = MAT4_NAN;
    rotation: Vec3 = Vec3(0, 0, 0);
    scale: Vec3 = Vec3(1, 1, 1);

    // The pose of `node`, kept on it so that a second binder over the same
    // tree carries on from the first one's writes. A node without one, or
    // whose basis is no longer the one the last write left (the editor
    // re-applied its layers after an edit, say), gets a new one seeded from
    // its declared values; a script's turn is then read from the matrix by
    // sync, as before.
    static of(node: SceneNode): BindingPose {
        const kept = node.bindingPose;
        if (kept != null && Mat3.fromMat4(node.local) == Mat3.fromMat4(kept.local)) return kept;
        const pose = new BindingPose();
        pose.seed(node);
        node.bindingPose = pose;
        return pose;
    }

    // Seeds the pose from the rotation and scale `node` declares
    // (rotation_degrees, else rotation, and scale: its effective
    // properties), as Godot keeps them, rather than from the matrix, which
    // gives X = 120 back as (60, 180, 180) and scale (-1, 1, 1) as all three
    // negative with a half turn: a later yaw or scale:y write would then
    // land a half turn away, or upside down. The declared values are taken
    // only when they give the node's basis (to a few f32 steps); when they
    // do not (only `transform` declared, say) the first sync reads the
    // matrix, as before.
    seed(node: SceneNode): void {
        let rot = Vec3(0, 0, 0);
        const rd = node.getProp("rotation_degrees");
        const r = node.getProp("rotation");
        if (rd != null && rd.kind == ValueKind.Vector3) rot = Vec3(degreesAt(rd, 0), degreesAt(rd, 1), degreesAt(rd, 2));
        else if (r != null && r.kind == ValueKind.Vector3) rot = r.vec3();
        const s = node.getProp("scale");
        const scale = s != null && s.kind == ValueKind.Vector3 ? s.vec3() : Vec3(1, 1, 1);
        const want = scaled(basisFromEulerYXZ(rot), scale);
        if (!nearBasis(Mat3.fromMat4(node.local), want)) return;
        this.rotation = rot;
        this.scale = scale;
        this.local = node.local;
    }

    // Takes the rotation and scale from `node` unless its basis is still
    // the one the last write left (a new origin is only taken).
    sync(node: SceneNode): void {
        const m = node.local;
        if (Mat3.fromMat4(m) == Mat3.fromMat4(this.local)) {
            this.local = m;
            return;
        }
        this.rotation = node.rotation;
        this.scale = node.scale;
        this.local = m;
    }

    // Sets `node`'s basis from the rotation and scale held here (its origin
    // kept), and remembers the matrix that gives.
    apply(node: SceneNode): void {
        node.local = withBasis(node.local, scaled(basisFromEulerYXZ(this.rotation), this.scale));
        this.local = node.local;
    }
}

// Component k of a declared rotation_degrees, in radians, converted from
// the f64 the file holds as applyLayer does.
function degreesAt(v: Value, k: i32): f32 {
    return k < v.n.length ? <f32>(v.n[k] * DEG) : 0;
}

// Whether two bases agree to within 1e-5 of each element's size (at least
// 1): applyLayer builds the declared basis through rotationOf, which can
// differ from basisFromEulerYXZ's by an f32 step or two.
function nearBasis(a: Mat3, b: Mat3): bool {
    for (let c = 0; c < 3; c++) {
        const u = a.col(c);
        const v = b.col(c);
        if (!near(u.x, v.x) || !near(u.y, v.y) || !near(u.z, v.z)) return false;
    }
    return true;
}

function near(a: f32, b: f32): bool {
    const d = Math.abs(<f64>a - <f64>b);
    return d <= 1e-5 * Math.max(1, Math.abs(<f64>a));
}


// ARGB bytes to the format's colour (sRGB, straight alpha): byte / 255.
export function argbToVec4(argb: u32): Vec4 {
    return Vec4(
        <f32>(<f64>((argb >> 16) & 0xff) / 255),
        <f32>(<f64>((argb >> 8) & 0xff) / 255),
        <f32>(<f64>(argb & 0xff) / 255),
        <f32>(<f64>((argb >> 24) & 0xff) / 255),
    );
}

function byteOf(x: f32): u32 {
    // NaN fails every comparison, so it reads as 0 here (isNaN would be a
    // self-comparison, which the linter flags).
    if (!(x > 0)) return 0;
    if (x >= 1) return 255;
    return <u32>Math.round(<f64>x * 255);
}

// The format's colour to ARGB bytes: round(clamp(x, 0, 1) * 255).
export function vec4ToArgb(c: Vec4): u32 {
    return (byteOf(c.w) << 24) | (byteOf(c.x) << 16) | (byteOf(c.y) << 8) | byteOf(c.z);
}

// --- milestone 42: any property ------------------------------------------------

// How a property is reached (accessOf).
const ROUTE_NODE: i32 = 0;
const ROUTE_RESOURCE: i32 = 1;
const ROUTE_OUTPUT: i32 = 2;

// The resource a ROUTE_RESOURCE property is a field of.
const HOLDER_MATERIAL_OVERRIDE: i32 = 0;
const HOLDER_MESH_MATERIAL: i32 = 1;
const HOLDER_MESH: i32 = 2;
const HOLDER_ENVIRONMENT: i32 = 3;
// Milestone 37: a FogVolume's FogMaterial (`material:<p>`).
const HOLDER_FOG_MATERIAL: i32 = 4;
// Milestone 62: a Camera3D's CameraAttributesPractical (`attributes:<p>`)
// and a WorldEnvironment's (`camera_attributes:<p>`).
const HOLDER_CAMERA_ATTRIBUTES: i32 = 5;
const HOLDER_WORLD_CAMERA_ATTRIBUTES: i32 = 6;
// Milestone 67: the first ArtboardTexture a node shows (`artboard:<p>`,
// firstArtboardTextureOf).
const HOLDER_ARTBOARD: i32 = 7;

// The outputs.
const OUTPUT_GLOBAL_POSITION: i32 = 0;
const OUTPUT_SCREEN_POSITION: i32 = 1;
const OUTPUT_SCREEN_VISIBLE: i32 = 2;
// Milestone 36: an AudioStreamPlayer3D's listener_volume_db and
// listener_pan, what the audio feature (or the tools' clock) computed.
const OUTPUT_LISTENER_DB: i32 = 3;
const OUTPUT_LISTENER_PAN: i32 = 4;
// Milestone 63: a NavigationAgent3D's current_speed, distance_to_target,
// is_target_reached and is_navigation_finished, what the navigation (the
// run time's feature, or the tools' clock) computed.
const OUTPUT_NAV_SPEED: i32 = 5;
const OUTPUT_NAV_DISTANCE: i32 = 6;
const OUTPUT_NAV_REACHED: i32 = 7;
const OUTPUT_NAV_FINISHED: i32 = 8;

// A target property taken apart: the route, the property or field name
// without its component, the component (0 x, 1 y, 2 z, 3 w; -1 none), and
// the holder or the output; milestone 61: how many next passes past the
// holder's material the field is on.
class TargetAccess {
    route: i32 = ROUTE_NODE;
    name: string = "";
    axis: i32 = -1;
    holder: i32 = 0;
    output: i32 = 0;
    hops: i32 = 0;
}

const accesses = new Map<string, TargetAccess>();

// The component a trailing ":x", ":y", ":z" or (milestone 61, a shader
// parameter's vec4) ":w" names (-1 none), with the name before it.
function splitAxis(a: TargetAccess, rest: string): void {
    const n = rest.length;
    if (n > 2 && rest.charCodeAt(n - 2) == 0x3a) {
        const c = rest.charCodeAt(n - 1);
        if (c >= 0x77 && c <= 0x7a) {
            a.axis = c == 0x77 ? 3 : c - 0x78;
            a.name = rest.substring(0, n - 2);
            return;
        }
    }
    a.axis = -1;
    a.name = rest;
}

// How `property` is reached, worked out the first time it is asked for.
function accessOf(property: string): TargetAccess {
    if (accesses.has(property)) return accesses.get(property);
    const a = new TargetAccess();
    if (property == "screen_visible") {
        a.route = ROUTE_OUTPUT;
        a.output = OUTPUT_SCREEN_VISIBLE;
        a.name = property;
    } else if (property == "listener_volume_db" || property == "listener_pan") {
        a.route = ROUTE_OUTPUT;
        a.output = property == "listener_pan" ? OUTPUT_LISTENER_PAN : OUTPUT_LISTENER_DB;
        a.name = property;
        a.axis = -1;
    } else if (property == "current_speed" || property == "distance_to_target" || property == "is_target_reached"
        || property == "is_navigation_finished") {
        a.route = ROUTE_OUTPUT;
        a.output = property == "current_speed" ? OUTPUT_NAV_SPEED : property == "distance_to_target" ? OUTPUT_NAV_DISTANCE
            : property == "is_target_reached" ? OUTPUT_NAV_REACHED : OUTPUT_NAV_FINISHED;
        a.name = property;
        a.axis = -1;
    } else if (property.startsWith("global_position:") || property.startsWith("screen_position:")) {
        a.route = ROUTE_OUTPUT;
        splitAxis(a, property);
        a.output = property.startsWith("global") ? OUTPUT_GLOBAL_POSITION : OUTPUT_SCREEN_POSITION;
    } else if (property.startsWith("material_override:")) {
        a.route = ROUTE_RESOURCE;
        a.holder = HOLDER_MATERIAL_OVERRIDE;
        splitAxis(a, property.substring(skipNextPasses(a, property, 18)));
    } else if (property.startsWith("mesh:material:")) {
        a.route = ROUTE_RESOURCE;
        a.holder = HOLDER_MESH_MATERIAL;
        splitAxis(a, property.substring(skipNextPasses(a, property, 14)));
    } else if (property.startsWith("mesh:")) {
        a.route = ROUTE_RESOURCE;
        a.holder = HOLDER_MESH;
        splitAxis(a, property.substring(5));
    } else if (property.startsWith("environment:")) {
        a.route = ROUTE_RESOURCE;
        a.holder = HOLDER_ENVIRONMENT;
        splitAxis(a, property.substring(12));
    } else if (property.startsWith("material:")) {
        a.route = ROUTE_RESOURCE;
        a.holder = HOLDER_FOG_MATERIAL;
        splitAxis(a, property.substring(9));
    } else if (property.startsWith("attributes:")) {
        a.route = ROUTE_RESOURCE;
        a.holder = HOLDER_CAMERA_ATTRIBUTES;
        splitAxis(a, property.substring(11));
    } else if (property.startsWith("camera_attributes:")) {
        a.route = ROUTE_RESOURCE;
        a.holder = HOLDER_WORLD_CAMERA_ATTRIBUTES;
        splitAxis(a, property.substring(18));
    } else if (property.startsWith(ARTBOARD_ROUTE)) {
        a.route = ROUTE_RESOURCE;
        a.holder = HOLDER_ARTBOARD;
        splitAxis(a, property.substring(ARTBOARD_ROUTE.length));
    } else {
        splitAxis(a, property);
    }
    accesses.set(property, a);
    return a;
}

// Milestone 61: the index past the `next_pass:` prefixes of `property`
// from `at`, counted into `a.hops`.
function skipNextPasses(a: TargetAccess, property: string, at: i32): i32 {
    let i = at;
    while (property.startsWith(NEXT_PASS_PREFIX, i)) {
        i += NEXT_PASS_PREFIX.length;
        a.hops++;
    }
    return i;
}

// Whether `property` is an output (read only: a to_source binding's).
export function isOutputProperty(property: string): bool {
    return accessOf(property).route == ROUTE_OUTPUT;
}

// Whether writing `property` rebuilds a mesh (`mesh:<p>` on a primitive).
export function isCostlyProperty(property: string): bool {
    const a = accessOf(property);
    return a.route == ROUTE_RESOURCE && a.holder == HOLDER_MESH;
}

// The resource a ROUTE_RESOURCE target is a field of on `node`, or null
// (milestone 61: `hops` next passes past the holder's material).
function holderOf(node: SceneNode, holder: i32, hops: i32 = 0): Resource? {
    const r = holderAt(node, holder);
    if (hops == 0 || r == null) return r;
    let m: Resource? = r;
    for (let i = 0; i < hops && m != null; i++) {
        const isMaterial = m instanceof StandardMaterial3D;
        m = isMaterial ? (m as StandardMaterial3D).nextPass : null;
    }
    return m;
}

function holderAt(node: SceneNode, holder: i32): Resource? {
    if (holder == HOLDER_ARTBOARD) return firstArtboardTextureOf(node);
    if (holder == HOLDER_ENVIRONMENT) {
        const isEnv = node instanceof WorldEnvironment;
        return isEnv ? (node as WorldEnvironment).environment : null;
    }
    if (holder == HOLDER_FOG_MATERIAL) {
        const isFog = node instanceof FogVolume;
        return isFog ? (node as FogVolume).fogMaterial() : null;
    }
    if (holder == HOLDER_CAMERA_ATTRIBUTES) {
        const isCamera = node instanceof Camera3D;
        return isCamera ? (node as Camera3D).attributes : null;
    }
    if (holder == HOLDER_WORLD_CAMERA_ATTRIBUTES) {
        const isEnv = node instanceof WorldEnvironment;
        return isEnv ? (node as WorldEnvironment).cameraAttributes : null;
    }
    const isMesh = node instanceof MeshInstance3D;
    if (!isMesh) return null;
    const m = node as MeshInstance3D;
    if (holder == HOLDER_MATERIAL_OVERRIDE) return m.materialOverride;
    const mesh = m.mesh;
    if (mesh == null) return null;
    const isPrimitive = mesh instanceof PrimitiveMesh;
    if (!isPrimitive) return null;
    return holder == HOLDER_MESH ? mesh as PrimitiveMesh : (mesh as PrimitiveMesh).material;
}

// Whether the last writeTarget made a mesh again (a costly write), for the
// binder's count.
let rebuilt: bool = false;

export function lastWriteRebuilt(): bool {
    return rebuilt;
}

// The scratch field of the resource routes (one: nothing here re-enters).
const io = new FieldIO();

// The enum names of `field` of resource `r` ([] when none).
function resourceEnumNames(r: Resource, field: string): Array<string> {
    const p = findProp(r.className(), field);
    return p != null ? p.enumNames : NO_NAMES;
}

const NO_NAMES: Array<string> = [];

// The index an enum value names among `names`: its key, or a whole number
// (an index, from a number source or an enum whose key is not one of
// them); -1 when it names none.
function enumIndexOf(v: BoundValue, names: Array<string>): i32 {
    if (v.kind == VmKind.Enum || v.kind == VmKind.String) {
        for (let i = 0; i < names.length; i++) if (names[i] == v.text) return i;
        return -1;
    }
    if (v.kind == VmKind.Number) {
        const n = v.number;
        if (n >= 0 && n < <f64>names.length && n == Math.floor(n)) return <i32>n;
    }
    return -1;
}

// Reads a resource route's field into `out`.
function readResource(node: SceneNode, a: TargetAccess, out: BoundValue): bool {
    const r = holderOf(node, a.holder, a.hops);
    if (r == null) return false;
    const k = fieldOf(r, a.name, false);
    if (k == F_NONE) return false;
    if (k == F_NUMBER) out.setNumber(io.f);
    else if (k == F_BOOL) out.setBoolean(io.b);
    else if (k == F_COLOR) {
        // (milestone 61: a shader parameter's colour by a component, a number)
        if (a.axis >= 0) out.setNumber(<f64>(a.axis == 0 ? io.c.x : a.axis == 1 ? io.c.y : a.axis == 2 ? io.c.z : io.c.w));
        else out.setColor(vec4ToArgb(io.c));
    } else if (k == F_INT) {
        const names = resourceEnumNames(r, a.name);
        if (names.length > 0) out.setEnum(io.i, io.i >= 0 && io.i < names.length ? names[io.i] : "");
        else out.setNumber(<f64>io.i);
    } else if (k == F_VEC2) {
        if (a.axis < 0 || a.axis > 1) return false;
        out.setNumber(<f64>(a.axis == 0 ? io.v2.x : io.v2.y));
    } else if (k == F_VEC4) {
        if (a.axis < 0) return false;
        out.setNumber(<f64>(a.axis == 0 ? io.v4.x : a.axis == 1 ? io.v4.y : a.axis == 2 ? io.v4.z : io.v4.w));
    } else {
        if (a.axis < 0 || a.axis > 2) return false;
        out.setNumber(component(io.v3, a.axis));
    }
    return true;
}

// Writes a resource route's field from `v` (of its kind); false when the
// node has no such resource or field, or `v` is a value it cannot take.
function writeResource(node: SceneNode, a: TargetAccess, v: BoundValue): bool {
    const r = holderOf(node, a.holder, a.hops);
    if (r == null) return false;
    const k = fieldOf(r, a.name, false);
    if (k == F_NONE) return false;
    if (k == F_NUMBER) {
        if (v.kind != VmKind.Number) return false;
        io.f = v.number;
    } else if (k == F_BOOL) {
        if (v.kind == VmKind.Boolean) io.b = v.boolean;
        else if (v.kind == VmKind.Number) io.b = v.number != 0;
        else return false;
    } else if (k == F_COLOR) {
        if (a.axis >= 0) {
            // (milestone 61: one component of a shader parameter's colour)
            if (v.kind != VmKind.Number) return false;
            const f = <f32>v.number;
            const c = io.c;
            io.c = a.axis == 0 ? Vec4(f, c.y, c.z, c.w) : a.axis == 1 ? Vec4(c.x, f, c.z, c.w)
                : a.axis == 2 ? Vec4(c.x, c.y, f, c.w) : Vec4(c.x, c.y, c.z, f);
        } else {
            if (v.kind != VmKind.Color) return false;
            io.c = argbToVec4(v.color);
        }
    } else if (k == F_INT) {
        const names = resourceEnumNames(r, a.name);
        if (names.length > 0) {
            const i = enumIndexOf(v, names);
            if (i < 0) return false;
            io.i = i;
        } else {
            if (v.kind != VmKind.Number) return false;
            io.i = <i32>Math.round(v.number);
        }
    } else if (k == F_VEC2) {
        if (v.kind != VmKind.Number || a.axis < 0 || a.axis > 1) return false;
        const f = <f32>v.number;
        io.v2 = a.axis == 0 ? Vec2(f, io.v2.y) : Vec2(io.v2.x, f);
    } else if (k == F_VEC4) {
        if (v.kind != VmKind.Number || a.axis < 0) return false;
        const f = <f32>v.number;
        const c = io.v4;
        io.v4 = a.axis == 0 ? Vec4(f, c.y, c.z, c.w) : a.axis == 1 ? Vec4(c.x, f, c.z, c.w)
            : a.axis == 2 ? Vec4(c.x, c.y, f, c.w) : Vec4(c.x, c.y, c.z, f);
    } else {
        if (v.kind != VmKind.Number || a.axis < 0 || a.axis > 2) return false;
        io.v3 = withComponent(io.v3, a.axis, v.number);
    }
    // (milestone 67: an artboard texture's field is the player's, read at
    // its next advance: no plan, no rebuild)
    const isArtboard = r instanceof ArtboardTexture;
    if (isArtboard) {
        artboardTextureField(r as ArtboardTexture, a.name, io, true);
        rebuilt = false;
        return true;
    }
    rebuilt = writeResourceField(r, a.name, io) == FIELD_REBUILT;
    return true;
}

// Milestone 67: a resource route's field `n` of `r` through `io` (read, or
// written when `w`): an ArtboardTexture's here, every other resource's
// material_fields.as's.
function fieldOf(r: Resource, n: string, w: bool): i32 {
    const isArtboard = r instanceof ArtboardTexture;
    if (isArtboard) return artboardTextureField(r as ArtboardTexture, n, io, w);
    return resourceField(r, n, io, w);
}

// Milestone 67 (docs/formats/RSCN.md, "ArtboardTexture"): the fields of an
// ArtboardTexture a binding or a key drives, by their .rscn names:
// render_target_update_mode (F_INT, an enum) and update_fps (F_NUMBER). A
// write of the mode goes through the texture's setter only when it changes,
// as a file's value does (a binding writes only a change, a timeline its
// value every frame): becoming `once` counts one write, which the player
// draws again for. Allocates nothing.
export function artboardTextureField(t: ArtboardTexture, n: string, io: FieldIO, w: bool): i32 {
    if (n == "render_target_update_mode") {
        if (w) {
            if (io.i != t.updateMode) t.updateMode = io.i;
        } else io.i = t.updateMode;
        return F_INT;
    }
    if (n == "update_fps") {
        if (w) t.updateFps = <f32>io.f;
        else io.f = <f64>t.updateFps;
        return F_NUMBER;
    }
    return F_NONE;
}

// Milestone 67: the route prefix of an ArtboardTexture's fields.
export const ARTBOARD_ROUTE = "artboard:";

// Milestone 67: the ArtboardTexture `artboard:<p>` reaches on `node`, the
// first its drawn materials name, in the order the renderer draws them:
// a MeshInstance3D's material_override, else its mesh's materials (a
// primitive mesh's one, an ArrayMesh's surfaces' in order), each in slot
// order (PbrSlot); a MultiMeshInstance3D's mesh's and a CPUParticles3D's
// mesh's the same way; an ArtboardSprite3D's texture; a Decal's slots in
// their order (albedo, normal, ORM, emission). null for a node that shows
// none. A texture is a resource: every node that shows it shares its
// fields (Godot's rule). Allocates nothing.
export function firstArtboardTextureOf(node: SceneNode): ArtboardTexture? {
    const isMesh = node instanceof MeshInstance3D;
    if (isMesh) {
        const mi = node as MeshInstance3D;
        const o = mi.materialOverride;
        if (o != null) return artboardOfMaterial(o);
        return artboardOfMesh(mi.mesh);
    }
    const isMulti = node instanceof MultiMeshInstance3D;
    if (isMulti) {
        const mm = (node as MultiMeshInstance3D).multimesh;
        return mm != null ? artboardOfMesh(mm.mesh) : null;
    }
    const isParticles = node instanceof CPUParticles3D;
    if (isParticles) return artboardOfMesh((node as CPUParticles3D).mesh);
    const isSprite = node instanceof ArtboardSprite3D;
    if (isSprite) return (node as ArtboardSprite3D).texture;
    const isDecal = node instanceof Decal;
    if (isDecal) {
        const d = node as Decal;
        for (let slot = 0; slot < DECAL_TEXTURES; slot++) {
            const t = d.textureAt(slot);
            const isArtboard = t != null && t instanceof ArtboardTexture;
            if (isArtboard) return t as ArtboardTexture;
        }
    }
    return null;
}

function artboardOfMesh(mesh: Mesh?): ArtboardTexture? {
    if (mesh == null) return null;
    const isPrimitive = mesh instanceof PrimitiveMesh;
    if (isPrimitive) return artboardOfMaterial((mesh as PrimitiveMesh).material);
    const isArray = mesh instanceof ArrayMesh;
    if (!isArray) return null;
    const surfaces = (mesh as ArrayMesh).surfaces;
    for (let k = 0; k < surfaces.length; k++) {
        const t = artboardOfMaterial(unchecked(surfaces[k]).material);
        if (t != null) return t;
    }
    return null;
}

function artboardOfMaterial(m: StandardMaterial3D?): ArtboardTexture? {
    if (m == null) return null;
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const t = m.textureAt(slot);
        const isArtboard = t != null && t instanceof ArtboardTexture;
        if (isArtboard) return t as ArtboardTexture;
    }
    return null;
}

// The effective value of node property `info` on `node` (its default when
// unset or of the wrong type).
function nodeValue(node: SceneNode, info: PropInfo): Value {
    const v = node.getProp(info.name);
    return v != null && info.accepts(v) ? v : info.def;
}

// Reads a node property (by its name, a vector's component) into `out`.
function readNodeProp(node: SceneNode, a: TargetAccess, out: BoundValue): bool {
    const info = findProp(node.schemaClass(), a.name);
    if (info == null) return false;
    const v = nodeValue(node, info);
    switch (info.type) {
        case PropType.Float:
            out.setNumber(v.asF64());
            return true;
        case PropType.Int: {
            const names = info.enumNames;
            if (names.length == 0) {
                out.setNumber(<f64>v.asI64());
                return true;
            }
            const i = v.asI32();
            out.setEnum(i, i >= 0 && i < names.length ? names[i] : "");
            return true;
        }
        case PropType.Bool:
            out.setBoolean(v.kind == ValueKind.Bool && v.b);
            return true;
        case PropType.Color:
            out.setColor(vec4ToArgb(v.vec4()));
            return true;
        case PropType.String:
        case PropType.StringName:
        case PropType.NodePath:
            out.setString(v.s);
            return true;
        case PropType.Vector2:
        case PropType.Vector3: {
            if (a.axis < 0 || a.axis >= v.n.length) return false;
            out.setNumber(v.n[a.axis]);
            return true;
        }
        default:
            return false;
    }
}

// Writes a node property from `v`: its new Value set as an effective
// property and the typed fields re-read. False when the class has no such
// property, or `v` is a value it cannot take (an enum key it lacks).
function writeNodeProp(node: SceneNode, a: TargetAccess, v: BoundValue): bool {
    const info = findProp(node.schemaClass(), a.name);
    if (info == null) return false;
    let made: Value? = null;
    switch (info.type) {
        case PropType.Float:
            if (v.kind != VmKind.Number) return false;
            setFloat(node, a.name, v.number);
            return true;
        case PropType.Int: {
            const names = info.enumNames;
            let i: i64 = 0;
            if (names.length > 0) {
                const k = enumIndexOf(v, names);
                if (k < 0) return false;
                i = <i64>k;
            } else {
                if (v.kind != VmKind.Number) return false;
                i = <i64>Math.round(v.number);
            }
            const own = ownValue(node, a.name, ValueKind.Int);
            if (own != null) {
                own.i = i;
                node.readFields();
                return true;
            }
            made = Value.int(i);
            break;
        }
        case PropType.Bool:
            if (v.kind == VmKind.Boolean) setBool(node, a.name, v.boolean);
            else if (v.kind == VmKind.Number) setBool(node, a.name, v.number != 0);
            else return false;
            return true;
        case PropType.Color: {
            if (v.kind != VmKind.Color) return false;
            setColor(node, a.name, argbToVec4(v.color));
            return true;
        }
        case PropType.String:
        case PropType.StringName:
        case PropType.NodePath: {
            if (v.kind != VmKind.String && v.kind != VmKind.Enum) return false;
            if (info.type == PropType.String) made = Value.str(v.text);
            else if (info.type == PropType.StringName) made = Value.stringName(v.text);
            else made = Value.nodePath(v.text);
            break;
        }
        case PropType.Vector2:
        case PropType.Vector3: {
            if (v.kind != VmKind.Number || a.axis < 0) return false;
            const have = nodeValue(node, info);
            const n = info.type == PropType.Vector2 ? 2 : 3;
            if (a.axis >= n) return false;
            const x = have.n.length > 0 ? have.n[0] : 0;
            const y = have.n.length > 1 ? have.n[1] : 0;
            const z = have.n.length > 2 ? have.n[2] : 0;
            const w = v.number;
            const own = ownValue(node, a.name, info.type == PropType.Vector2 ? ValueKind.Vector2 : ValueKind.Vector3);
            if (own != null && own.n.length == n) {
                own.n[a.axis] = w;
                node.readFields();
                return true;
            }
            if (n == 2) made = Value.vector2(a.axis == 0 ? w : x, a.axis == 1 ? w : y);
            else made = Value.vector3(a.axis == 0 ? w : x, a.axis == 1 ? w : y, a.axis == 2 ? w : z);
            break;
        }
        default:
            return false;
    }
    setMade(node, a.name, made as Value);
    return true;
}

// Reads an output into `out`: false when the node is not a 3D one, or a
// screen output has no valid view (or the node is behind its camera, for
// screen_position: the binding keeps its last value).
function readOutput(node: SceneNode, a: TargetAccess, out: BoundValue, view: OutputView?): bool {
    // (milestone 63: an agent is a Node, not a 3D node)
    if (a.output >= OUTPUT_NAV_SPEED && a.output <= OUTPUT_NAV_FINISHED) {
        const isAgent = node instanceof NavigationAgent3D;
        if (!isAgent) return false;
        const g = node as NavigationAgent3D;
        if (a.output == OUTPUT_NAV_SPEED) out.setNumber(<f64>g.currentSpeed);
        else if (a.output == OUTPUT_NAV_DISTANCE) out.setNumber(<f64>g.nav.distanceToTarget);
        else if (a.output == OUTPUT_NAV_REACHED) out.setBoolean(g.nav.targetReached);
        else out.setBoolean(g.nav.navigationFinished);
        return true;
    }
    if (!node.is3d) return false;
    if (a.output == OUTPUT_LISTENER_DB || a.output == OUTPUT_LISTENER_PAN) {
        const isPlayer = node instanceof AudioStreamPlayer3D;
        if (!isPlayer) return false;
        const p = node as AudioStreamPlayer3D;
        out.setNumber(<f64>(a.output == OUTPUT_LISTENER_PAN ? p.listenerPan : p.listenerVolumeDb));
        return true;
    }
    const origin = node.globalPosition;
    if (a.output == OUTPUT_GLOBAL_POSITION) {
        if (a.axis < 0) return false;
        out.setNumber(component(origin, a.axis));
        return true;
    }
    if (view == null || !view.valid) return false;
    const c = view.clip(origin);
    if (a.output == OUTPUT_SCREEN_VISIBLE) {
        out.setBoolean(onScreen(c));
        return true;
    }
    if (a.axis < 0 || a.axis > 1 || !inFront(c)) return false;
    out.setNumber(screenAxis(view, c, a.axis));
    return true;
}

// The generic road (milestone 42) of readTarget.
function readAny(node: SceneNode, p: string, out: BoundValue, view: OutputView?): bool {
    const a = accessOf(p);
    if (a.route == ROUTE_OUTPUT) return readOutput(node, a, out, view);
    if (a.route == ROUTE_RESOURCE) return readResource(node, a, out);
    return readNodeProp(node, a, out);
}

// The generic road (milestone 42) of writeTarget.
function writeAny(node: SceneNode, p: string, v: BoundValue): bool {
    const a = accessOf(p);
    if (a.route == ROUTE_OUTPUT) return false;
    if (a.route == ROUTE_RESOURCE) return writeResource(node, a, v);
    return writeNodeProp(node, a, v);
}

// Reads the target's value on `node` into `out` (a BoundValue of the
// target's kind); false when the node has nothing there (a material target
// without a material, a node not of the target's class, an output without
// a view). `pose`: the node's BindingPose, which a rotation or scale is
// read from while the node is where the bindings left it (null: from the
// matrix). `view`: what a screen output projects through (milestone 42).
export function readTarget(node: SceneNode, t: BindingTarget, out: BoundValue, pose: BindingPose? = null,
    view: OutputView? = null): bool {
    const p = t.property;
    const vec = vectorOf(p);
    if (vec >= 0) {
        if (!node.is3d) return false;
        const axis = axisOf(p);
        if (vec == 0) {
            out.setNumber(component(node.position, axis));
            return true;
        }
        let rotation: Vec3;
        let scale: Vec3;
        if (pose != null) {
            pose.sync(node);
            rotation = pose.rotation;
            scale = pose.scale;
        } else {
            rotation = node.rotation;
            scale = node.scale;
        }
        if (vec == 1) out.setNumber(component(rotation, axis));
        else if (vec == 2) out.setNumber(component(rotation, axis) / DEG);
        else out.setNumber(component(scale, axis));
        return true;
    }
    if (p == "scale") {
        // A uniform scale reads as its x: the three are equal once written.
        if (!node.is3d) return false;
        if (pose != null) {
            pose.sync(node);
            out.setNumber(<f64>pose.scale.x);
        } else out.setNumber(<f64>node.scale.x);
        return true;
    }
    if (p == "visible") {
        if (!node.is3d) return false;
        out.setBoolean(node.visible);
        return true;
    }
    if (p == "light_energy") {
        const isLight = node instanceof Light3D;
        if (!isLight) return false;
        out.setNumber(<f64>(node as Light3D).energy);
        return true;
    }
    if (p == "current") {
        // (milestone 36: an AudioListener3D's `current` too)
        const isListener = node instanceof AudioListener3D;
        if (isListener) {
            out.setBoolean((node as AudioListener3D).current);
            return true;
        }
    }
    if (p == "current" || p == "fov") {
        const isCamera = node instanceof Camera3D;
        if (!isCamera) return false;
        const c = node as Camera3D;
        if (p == "current") out.setBoolean(c.current);
        else out.setNumber(<f64>c.fov);
        return true;
    }
    if (p == "light_color" || p == "modulate") {
        const c = readTargetColor(node, t);
        if (!isFinite(c.x)) return false;
        out.setColor(vec4ToArgb(c));
        return true;
    }
    const follower = followerTarget(p);
    if (follower >= 0) {
        const isFollower = node instanceof PathFollow3D;
        if (!isFollower) return false;
        const f = node as PathFollow3D;
        out.setNumber(follower == 0 ? f.getProgress() : f.getProgressRatio());
        return true;
    }
    return readAny(node, p, out, view);
}

// Writes `v` (of the target's kind) to the target on `node`, in `tree`
// (for `current`); false when the node has nothing there, or the target
// is an output. `pose`: the node's BindingPose, which a rotation or scale
// write keeps the other components from (null: from the matrix, as
// setRotation and setScale do).
export function writeTarget(tree: SceneTree, node: SceneNode, t: BindingTarget, v: BoundValue, pose: BindingPose? = null): bool {
    rebuilt = false;
    const p = t.property;
    const vec = vectorOf(p);
    if (vec >= 0) {
        if (!node.is3d) return false;
        const axis = axisOf(p);
        if (pose != null) {
            pose.sync(node);
            if (vec == 0) {
                node.setPosition(withComponent(node.position, axis, v.number));
                // The basis is untouched: the pose still holds it.
                pose.local = node.local;
                return true;
            }
            if (vec == 1) pose.rotation = withComponent(pose.rotation, axis, v.number);
            else if (vec == 2) pose.rotation = withComponent(pose.rotation, axis, v.number * DEG);
            else pose.scale = withComponent(pose.scale, axis, v.number);
            pose.apply(node);
            return true;
        }
        if (vec == 0) node.setPosition(withComponent(node.position, axis, v.number));
        else if (vec == 1) node.setRotation(withComponent(node.rotation, axis, v.number));
        else if (vec == 2) node.setRotation(withComponent(node.rotation, axis, v.number * DEG));
        else node.setScale(withComponent(node.scale, axis, v.number));
        return true;
    }
    if (p == "scale") {
        if (!node.is3d) return false;
        const f = <f32>v.number;
        if (pose != null) {
            pose.sync(node);
            pose.scale = Vec3(f, f, f);
            pose.apply(node);
        } else node.setScale(Vec3(f, f, f));
        return true;
    }
    if (p == "visible") {
        if (!node.is3d) return false;
        setBool(node, "visible", v.boolean);
        return true;
    }
    if (p == "light_color" || p == "modulate") {
        if (v.kind != VmKind.Color) return false;
        return writeTargetColor(tree, node, t, argbToVec4(v.color));
    }
    if (p == "light_energy") {
        const isLight = node instanceof Light3D;
        if (!isLight) return false;
        setFloat(node, p, v.number);
        return true;
    }
    if (p == "current") {
        // Milestone 36: Godot's AudioListener3D set_current likewise: true
        // is make_current (one listener of the viewport is current, so the
        // others are not), false clear_current (the one heard gives its
        // place to the next listener, else to the camera).
        const isListener = node instanceof AudioListener3D;
        if (isListener) {
            const l = node as AudioListener3D;
            if (!v.boolean) l.clearCurrent();
            setBool(node, p, v.boolean);
            if (v.boolean) l.makeCurrent();
            return true;
        }
    }
    if (p == "current" || p == "fov") {
        const isCamera = node instanceof Camera3D;
        if (!isCamera) return false;
        if (p == "fov") {
            setFloat(node, p, v.number);
            return true;
        }
        setBool(node, p, v.boolean);
        // Godot's make_current: one camera of a viewport is current, so
        // that viewport's others are not (clear_current gives the view back
        // to its first camera, as viewportCameraOf picks it).
        if (v.boolean) clearOtherCameras(tree, node);
        return true;
    }
    const follower = followerTarget(p);
    if (follower >= 0) {
        const isFollower = node instanceof PathFollow3D;
        if (!isFollower || v.kind != VmKind.Number) return false;
        const f = node as PathFollow3D;
        if (follower == 0) f.setProgress(v.number);
        else f.setProgressRatio(v.number);
        return true;
    }
    return writeAny(node, p, v);
}

// Milestone 27: a colour target's value (light_color, modulate, a
// material's albedo_color or emission; since milestone 42 any colour
// property or resource field) as the scene holds it, sRGB with straight
// alpha in floats, which a tween interpolates without the bytes a view
// model's colour crosses as; x is NaN when the node has nothing there.
export function readTargetColor(node: SceneNode, t: BindingTarget): Vec4 {
    const p = t.property;
    const none = Vec4(<f32>NaN, 0, 0, 0);
    if (p == "light_color") {
        const isLight = node instanceof Light3D;
        return isLight ? (node as Light3D).color : none;
    }
    if (p == "modulate") {
        // (milestone 33: a Decal's modulate is read as any colour property)
        const isSprite = node instanceof ArtboardSprite3D;
        if (isSprite) return (node as ArtboardSprite3D).modulate;
    }
    const a = accessOf(p);
    if (a.route == ROUTE_RESOURCE) {
        const r = holderOf(node, a.holder, a.hops);
        if (r == null || resourceField(r, a.name, io, false) != F_COLOR) return none;
        return io.c;
    }
    if (a.route != ROUTE_NODE) return none;
    const info = findProp(node.schemaClass(), a.name);
    if (info == null || info.type != PropType.Color) return none;
    return nodeValue(node, info).vec4();
}

// Writes the colour `c` (sRGB, straight alpha) to a colour target on
// `node`; false when the node has nothing there. A view model's colour
// arrives here as its bytes (writeTarget), a tween's as it is.
export function writeTargetColor(tree: SceneTree, node: SceneNode, t: BindingTarget, c: Vec4): bool {
    rebuilt = false;
    const p = t.property;
    if (p == "light_color") {
        const isLight = node instanceof Light3D;
        if (!isLight) return false;
        setColor(node, p, c);
        return true;
    }
    if (p == "modulate") {
        // (milestone 33: a Decal's modulate is written as any colour
        // property)
        const isSprite = node instanceof ArtboardSprite3D;
        if (isSprite) {
            setColor(node, p, c);
            return true;
        }
    }
    const a = accessOf(p);
    if (a.route == ROUTE_RESOURCE) {
        const r = holderOf(node, a.holder, a.hops);
        if (r == null || resourceField(r, a.name, io, false) != F_COLOR) return false;
        io.c = c;
        rebuilt = writeResourceField(r, a.name, io) == FIELD_REBUILT;
        return true;
    }
    if (a.route != ROUTE_NODE) return false;
    const info = findProp(node.schemaClass(), a.name);
    if (info == null || info.type != PropType.Color) return false;
    setColor(node, a.name, c);
    return true;
}

// Whether the node has the material a material target names (milestone
// 17's binding-target-missing): false only for a material or mesh target
// whose resource is absent.
export function hasTargetResource(node: SceneNode, t: BindingTarget): bool {
    const a = accessOf(t.property);
    if (a.route != ROUTE_RESOURCE) return true;
    return holderOf(node, a.holder, a.hops) != null;
}

// Sets an effective property and re-reads the typed fields from them, so
// that what reads the node (the renderer, a tool listing its properties)
// sees the bound value.
function setTyped(node: SceneNode, name: string, value: Value): void {
    node.setProp(name, value);
    node.readFields();
}

// Milestone 49 (see the header): the node's own Value of `name`, of kind
// `kind`, which a write sets in place; null for a property whose Value
// the write must replace (none of the node's own yet, another kind, or a
// bone's or a blend shape's, whose new Value is how the node sees the
// change).
function ownValue(node: SceneNode, name: string, kind: ValueKind): Value? {
    if (name.startsWith(BONES_PREFIX) || name.startsWith(BLEND_SHAPES_PREFIX)) return null;
    return node.writtenProp(name, kind);
}

// `made` written as the effective value of `name`: the node's own from
// now on (SceneNode.setWrittenProp), but for a bone's or a blend shape's.
function setMade(node: SceneNode, name: string, made: Value): void {
    if (name.startsWith(BONES_PREFIX) || name.startsWith(BLEND_SHAPES_PREFIX)) node.setProp(name, made);
    else node.setWrittenProp(name, made);
    node.readFields();
}

// A number written to `name`: in place in the node's own Value, or a new
// one.
function setFloat(node: SceneNode, name: string, x: f64): void {
    const own = ownValue(node, name, ValueKind.Float);
    if (own == null) {
        setMade(node, name, Value.float(x));
        return;
    }
    own.f = x;
    node.readFields();
}

// A colour (sRGB, straight alpha) written to `name`, as setFloat.
function setColor(node: SceneNode, name: string, c: Vec4): void {
    const own = ownValue(node, name, ValueKind.Color);
    if (own == null || own.n.length != 4) {
        setMade(node, name, Value.color(<f64>c.x, <f64>c.y, <f64>c.z, <f64>c.w));
        return;
    }
    own.n[0] = <f64>c.x;
    own.n[1] = <f64>c.y;
    own.n[2] = <f64>c.z;
    own.n[3] = <f64>c.w;
    node.readFields();
}

// A boolean written to `name`, as setFloat.
function setBool(node: SceneNode, name: string, b: bool): void {
    const own = ownValue(node, name, ValueKind.Bool);
    if (own == null) {
        setMade(node, name, Value.bool(b));
        return;
    }
    own.b = b;
    node.readFields();
}

// Godot's make_current on `camera`: sets its `current` (as a key or a
// binding writes it) and clears it on the other cameras of its viewport.
export function makeCameraCurrent(tree: SceneTree, camera: Camera3D): void {
    setBool(camera, "current", true);
    clearOtherCameras(tree, camera);
}

// Per viewport, as Godot's make_current: only the cameras of `current`'s
// own viewport (the nearest SubViewport above it, or the main one) give
// way, so keying a feed's camera leaves the main view's camera alone and
// the other way round.
function clearOtherCameras(tree: SceneTree, current: SceneNode): void {
    const all = tree.walk();
    const own = viewportOf(current);
    for (let i = 0; i < all.length; i++) {
        const n = all[i];
        if (n === current) continue;
        const isCamera = n instanceof Camera3D;
        if (!isCamera || !(n as Camera3D).current) continue;
        if (viewportOf(n) !== own) continue;
        setTyped(n, "current", Value.bool(false));
    }
}
