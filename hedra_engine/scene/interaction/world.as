// The interaction world of a scene tree (milestone 31, docs/formats/RSCN.md
// "Interaction"): its collision objects (Area3D, StaticBody3D), their
// enabled shapes placed in the world, and its rays, with the queries
// everything asks of them -- a ray's nearest hit, the shapes holding a
// point, what overlaps an area -- through geometry.as and gjk.as. It is
// Godot's direct space state too (api.as), which the run time's feature
// puts on the tree (SceneTree.world) for scripts.
//
// Who uses it: the run time's interaction feature (../runtime/
// feature_interaction.as: areas' signals, RayCast3D, the pointer), the CLI's
// `inspect --ray/--point/--overlaps/--pick` and `render --shapes` (through
// debug_draw.as), the editor's shape gizmos and hover
// (editor/src/scene/shape_gizmo.as).
//
// The world is made from a tree once (`constructor`, `rebuild` after a
// subtree holding a collision object, shape or ray joined or left the
// tree: node.as SceneNode.shapesEpoch, the tree root's own; any other
// child, a rename or a group changes none of it), and follows
// what moved with `sync` (every entry's global transform, its inverse and
// its world box: allocates nothing). A query uses the entries as the last
// sync left them; the space state's queries (intersectRay,
// intersectPoint) sync first, so a script sees what it just moved, as in
// Godot (and rebuild first when the tree's structure moved since).
//
// Which shapes take part (Godot's rules): a CollisionShape3D whose parent
// is a CollisionObject3D, with a shape, not disabled, visible or not
// (visibility changes nothing, as in Godot), its object in the tree. A
// query takes an object when its collision_layer shares a bit with the
// query's mask, when its class is wanted (bodies, areas), and when it is
// not excluded.
//
// The broad phase. A ray tests each entry's world box (a slab test) before
// its shape; a query for one point tests the boxes too. An area's overlaps
// come from a sort-and-sweep on x over every entry's box: the entries'
// indices are kept in an array sorted by the boxes' lower x, sorted again
// by insertion at each step (things move a little between frames, so the
// array is nearly sorted and the sort is linear), then swept once to list,
// for each entry of an area, the entries whose boxes meet its own. One
// sweep serves every area of a step (it is made again only after a sync).
// The sweep reads copies of the boxes, flags and owners laid out in its
// order, and a body's scan steps from area to area (two bodies are never
// listed). A world of 1,000 moving areas and 1,000 bodies steps in about
// 2.6 ms on an Apple M5 Pro (4.2 ms with the machine loaded, where the
// first version took 10.3: about 6 idle), the sync and the sweep about
// 2 ms each loaded, the shapes' own tests 0.5 (gjk.as answers a sphere
// against a sphere or a box without GJK)
// (editor/program/tests/interaction/alloc_test.as logs it);
// the sample's 9 objects cost about 30 microseconds a frame, its scripts
// included.
//
// Milestone 34: collision objects and RayCast3Ds in a SubViewport's world
// of its own (../tree/viewports.as inOwnWorld) take no part: physics stays
// in the main world (Godot gives each World3D a space of its own;
// docs/engine/VIEWPORTS.md says where we differ). Their shapes go with them.

import { Mat4, MAT4_IDENTITY, Vec3, Vec4 } from "../../base/vecmath";
import { SceneTree } from "../tree/tree";
import { inOwnWorld } from "../tree/viewports";
import { Area3D, CollisionObject3D, CollisionShape3D, RayCast3D, SceneNode, treeShapesEpoch } from "../tree/node";
import { Shape3D } from "../resource/types";
import {
    PhysicsDirectSpaceState3D, PhysicsPointQueryParameters3D, PhysicsPointResult, PhysicsRayQueryParameters3D, PhysicsRayResult,
} from "./api";
import { Aabb, ShapeHit, pointInShape, rayShape, shapeLocalBounds } from "./geometry";
import { shapesOverlap } from "./gjk";

// Metres a world box is grown by before a ray or a point is tested against
// it, so that rounding never drops a shape the exact test would meet.
const BOX_SLACK: f64 = 1e-6;

// One shape in the world: every CollisionShape3D of a collision object
// has one, with a shape or not (a script may give it one later, in _ready
// say, which changes no structure: the next sync sees it).
export class ShapeEntry {
    node: CollisionShape3D;
    object: CollisionObject3D;
    // As of the last sync (null: none yet, and the entry is disabled).
    shape: Shape3D?;
    // Its index among the object's shapes (Godot's shape_idx).
    index: i32;
    // Its shape's space to the world (the CollisionShape3D's global
    // transform) and back, and its world box, as of the last sync.
    world: Mat4 = MAT4_IDENTITY;
    inverse: Mat4 = MAT4_IDENTITY;
    bounds: Aabb = new Aabb();
    // As of the last sync: the node is disabled or has no shape (every
    // query skips the entry; its box is empty).
    disabled: bool = false;
    // Its object's index in InteractionWorld.objects (tree order).
    objectIndex: i32 = -1;
    // Whether its object is an Area3D.
    isArea: bool = false;
    // The shape's own box, for the shape and version it was made for (a
    // ConcavePolygonShape3D's is a pass over its triangles: made again
    // only when the shape changed).
    local: Aabb = new Aabb();
    localShape: Shape3D? = null;
    localVersion: i32 = -1;
    // The sweep's answer for an area's entry: the indices of the entries
    // of other objects whose boxes meet its own (kept, refilled).
    near: Array<i32> = [];
    // The next entry of the same object (-1: none): an object's shapes are
    // found from InteractionWorld's `firstEntry` without a scan.
    nextOfObject: i32 = -1;
    // `world` as f64 columns x, y, z and the translation (three numbers
    // each), as of the last sync; false before the first.
    affine: StaticArray<f64> = new StaticArray<f64>(12);
    synced: bool = false;

    constructor(node: CollisionShape3D, object: CollisionObject3D, shape: Shape3D?, index: i32) {
        this.node = node;
        this.object = object;
        this.shape = shape;
        this.index = index;
    }
}

// A ray's nearest hit in the world (a kept object, filled again by each
// castRay).
export class WorldRayHit {
    // Along the ray from `from`, in metres.
    distance: f64 = Infinity;
    position: Vec3 = Vec3(0, 0, 0);
    // Unit, world space; zero for a ray that started inside the shape.
    normal: Vec3 = Vec3(0, 0, 0);
    entry: ShapeEntry? = null;
    // A ConcavePolygonShape3D's triangle, else -1.
    faceIndex: i32 = -1;
}

export class InteractionWorld extends PhysicsDirectSpaceState3D {
    tree: SceneTree;
    // In tree order.
    objects: Array<CollisionObject3D> = [];
    entries: Array<ShapeEntry> = [];
    rays: Array<RayCast3D> = [];
    areas: Array<Area3D> = [];
    // Bumped by each rebuild (a feature that keeps per-object records sees
    // that they are stale), and by each sync that found something moved,
    // appeared or went (the pointer's hover is cast again, Play's --shapes
    // drawn again).
    generation: i32 = 0;
    motion: i64 = 0;
    // The tree root's shapesEpoch at the last rebuild.
    epoch: i32 = 0;
    // While set, intersectRay and intersectPoint do not sync first (the
    // feature casts every RayCast3D after one sync of its own).
    holdSync: bool = false;
    // Syncs so far, and the sync the sweep's lists were made after.
    private syncs: i64 = 0;
    private sweptAt: i64 = -1;
    // The sweep's order: entry indices by their box's lower x.
    private order: Array<i32> = [];
    // By entry, as of the last sync (the sweep's data, flat: an object's
    // fields cost more to reach): its world box (min x, y, z, max x, y,
    // z), whether it is disabled (1) or an area's (2), its object's index.
    private boxes: Float64Array = new Float64Array(0);
    private flags: Int32Array = new Int32Array(0);
    private owners: Int32Array = new Int32Array(0);
    // The same, in the sweep's order (made by each sweep, so that its
    // inner loop reads one array position after another).
    private sortedBoxes: Float64Array = new Float64Array(0);
    private sortedFlags: Int32Array = new Int32Array(0);
    private sortedOwners: Int32Array = new Int32Array(0);
    // By sorted position: the first area's at or after it (n: none), so
    // that a body's scan skips the other bodies.
    private nextArea: Int32Array = new Int32Array(1);
    // By object index: its first entry (-1: none).
    private firstEntry: Array<i32> = [];
    private lastEntry: Array<i32> = [];
    // Kept for the queries (nothing is allocated per query).
    private hit: ShapeHit = new ShapeHit();
    private rayHit: WorldRayHit = new WorldRayHit();
    private rayResult: PhysicsRayResult = new PhysicsRayResult();
    private pointEntries: Array<ShapeEntry> = [];
    private pointPool: Array<PhysicsPointResult> = [];
    private pointResults: Array<PhysicsPointResult> = [];
    private found: Array<i32> = [];

    constructor(tree: SceneTree) {
        super();
        this.tree = tree;
        this.rebuild();
    }

    // The index of `o` in `objects`, -1 when it is not there.
    indexOf(o: CollisionObject3D): i32 {
        const i = o.worldIndex;
        if (i >= 0 && i < this.objects.length && unchecked(this.objects[i]) === o) return i;
        return this.objects.indexOf(o);
    }

    // The enabled entries that have a shape (what `render --shapes` counts
    // and debugLinesInto draws; a disabled shape is drawn nowhere).
    shapeCount(): i32 {
        let n = 0;
        const es = this.entries;
        for (let i = 0; i < es.length; i++) {
            const e = unchecked(es[i]);
            if (e.shape != null && !e.disabled) n++;
        }
        return n;
    }

    // Whether a collision object, shape or ray joined or left the tree
    // since the last rebuild.
    stale(): bool {
        return treeShapesEpoch(this.tree.root) != this.epoch;
    }

    // Collects the objects, shapes, rays and areas of the tree as it is
    // now (allocates: after a structure change only), then syncs.
    rebuild(): void {
        this.epoch = treeShapesEpoch(this.tree.root);
        this.generation++;
        this.objects = [];
        this.entries = [];
        this.rays = [];
        this.areas = [];
        this.order = [];
        this.firstEntry = [];
        this.lastEntry = [];
        this.sweptAt = -1;
        const all = this.tree.walk();
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            if (n.freed) continue;
            const isObject = n instanceof CollisionObject3D;
            const isShape = n instanceof CollisionShape3D;
            const isRay = n instanceof RayCast3D;
            if ((isObject || isRay) && inOwnWorld(n)) continue;
            if (isObject) {
                const o = n as CollisionObject3D;
                o.worldIndex = this.objects.length;
                this.objects.push(o);
                this.firstEntry.push(-1);
                this.lastEntry.push(-1);
                const isArea = n instanceof Area3D;
                if (isArea) this.areas.push(n as Area3D);
            } else if (isRay) {
                this.rays.push(n as RayCast3D);
            } else if (isShape) {
                const sn = n as CollisionShape3D;
                const owner = sn.owner3d();
                const shape = sn.shape;
                if (owner == null) continue;
                // (its owner, its parent, came before it in the walk)
                const at = this.indexOf(owner);
                if (at < 0) continue;
                const e = new ShapeEntry(sn, owner, shape, sn.shapeIndex());
                e.objectIndex = at;
                const k = this.entries.length;
                const last = this.lastEntry[at];
                if (last < 0) this.firstEntry[at] = k;
                else this.entries[last].nextOfObject = k;
                this.lastEntry[at] = k;
                const isArea = owner instanceof Area3D;
                e.isArea = isArea;
                this.order.push(this.entries.length);
                this.entries.push(e);
            }
        }
        const n = this.entries.length;
        this.boxes = new Float64Array(n * 6);
        this.flags = new Int32Array(n);
        this.owners = new Int32Array(n);
        this.sortedBoxes = new Float64Array(n * 6);
        this.sortedFlags = new Int32Array(n);
        this.sortedOwners = new Int32Array(n);
        this.nextArea = new Int32Array(n + 1);
        for (let i = 0; i < n; i++) this.owners[i] = this.entries[i].objectIndex;
        this.sync();
    }

    // Every entry's transforms and box from the nodes as they are now.
    // Allocates nothing.
    sync(): void {
        this.syncs++;
        let moved = false;
        const es = this.entries;
        for (let i = 0; i < es.length; i++) {
            const e = unchecked(es[i]);
            const n = e.node;
            const s = n.shape;
            const off = n.disabled || s == null;
            if (off != e.disabled) moved = true;
            e.disabled = off;
            if (s == null) {
                e.shape = null;
                e.bounds.setEmpty();
                unchecked(this.boxes[i * 6] = Infinity);
                unchecked(this.boxes[i * 6 + 3] = -Infinity);
                unchecked(this.flags[i] = 1);
                continue;
            }
            if (s !== e.shape) {
                e.shape = s;
                moved = true;
            }
            if (e.localShape !== s || e.localVersion != s.version) {
                shapeLocalBounds(s, e.local);
                e.localShape = s;
                e.localVersion = s.version;
                // (the box again, from the new local box)
                e.synced = false;
                moved = true;
            }
            // (the global transform in scalar arithmetic: Mat4's products
            // and inverse cost a microsecond each, which a world of
            // thousands of shapes cannot pay every frame)
            globalAffine(n, ACC);
            let same = e.synced;
            const a = e.affine;
            for (let k = 0; k < 12; k++) {
                if (unchecked(a[k]) != unchecked(ACC[k])) {
                    same = false;
                    break;
                }
            }
            if (!same) {
                for (let k = 0; k < 12; k++) unchecked(a[k] = ACC[k]);
                e.world = affineMat4(a);
                e.inverse = affineMat4(invertAffine(a, INV));
                e.synced = true;
                moved = true;
            }
            const bx = e.bounds;
            if (off) bx.setEmpty();
            else if (!same || bx.isEmpty()) affineBox(e.local, a, bx);
            const k6 = i * 6;
            const boxes = this.boxes;
            unchecked(boxes[k6] = bx.minX);
            unchecked(boxes[k6 + 1] = bx.minY);
            unchecked(boxes[k6 + 2] = bx.minZ);
            unchecked(boxes[k6 + 3] = bx.maxX);
            unchecked(boxes[k6 + 4] = bx.maxY);
            unchecked(boxes[k6 + 5] = bx.maxZ);
            unchecked(this.flags[i] = (off ? 1 : 0) | (e.isArea ? 2 : 0));
        }
        if (moved) this.motion++;
    }

    // The nearest hit of the segment from `from` to `to` (world space) on a
    // shape of an object that `mask`, `bodies`, `areas` and `exclude` take
    // (and, with `pickable`, whose input_ray_pickable is on: the pointer's
    // picking), into `out`; whether there is one. Allocates nothing.
    castRay(from: Vec3, to: Vec3, mask: u32, bodies: bool, areas: bool, hitFromInside: bool, hitBackFaces: bool,
        exclude: Array<SceneNode>?, pickable: bool, out: WorldRayHit): bool {
        return this.cast(from, to, mask, bodies, areas, hitFromInside, hitBackFaces, exclude, pickable, null, false,
            out);
    }

    // castRay on every layer, bodies and areas, pickable or not, past the
    // shapes whose node is hidden (visibleInTree): what the editor's
    // pointer meets among the shapes it draws. Physics ignores visibility,
    // as Godot's does, so only the editor asks this; a hidden shape in
    // front does not hide a drawn one behind it. Allocates nothing.
    castRayDrawn(from: Vec3, to: Vec3, out: WorldRayHit): bool {
        return this.cast(from, to, 0xFFFFFFFF, true, true, false, true, null, false, null, true, out);
    }

    // castRay against the shapes of `object` alone (any layer, any class):
    // where the pointer's ray meets an object that captured it.
    castRayOn(object: CollisionObject3D, from: Vec3, to: Vec3, out: WorldRayHit): bool {
        return this.cast(from, to, 0xFFFFFFFF, true, true, false, true, null, false, object, false, out);
    }

    // Milestone 47 (../listen/pick.as: a listener's pointer meets every
    // collision object it listens to, not only the nearest): the segment
    // from `from` to `to` (world space) against entry `index` of `entries`
    // alone, whatever its object's layer, class or input_ray_pickable (the
    // caller chose it), as castRay meets it (back faces too, not from
    // inside); whether it meets the shape, `out` the hit. A disabled entry
    // or one without a shape is never met. Uses the entries as the last
    // sync left them. Allocates nothing.
    castRayEntry(index: i32, from: Vec3, to: Vec3, out: WorldRayHit): bool {
        out.entry = null;
        out.distance = Infinity;
        out.faceIndex = -1;
        if (index < 0 || index >= this.entries.length) return false;
        const e = unchecked(this.entries[index]);
        const s = e.shape;
        if (e.disabled || s == null) return false;
        const ox = <f64>from.x;
        const oy = <f64>from.y;
        const oz = <f64>from.z;
        const dx = <f64>to.x - ox;
        const dy = <f64>to.y - oy;
        const dz = <f64>to.z - oz;
        if (!segmentMeetsBox(e.bounds, ox, oy, oz, dx, dy, dz, 1)) return false;
        const inv = e.inverse;
        const h = this.hit;
        if (!rayShape(s, pointX(inv, ox, oy, oz), pointY(inv, ox, oy, oz), pointZ(inv, ox, oy, oz), dirX(inv, dx, dy, dz),
            dirY(inv, dx, dy, dz), dirZ(inv, dx, dy, dz), 1, false, true, h)) return false;
        const best = h.t;
        const length = Math.sqrt(dx * dx + dy * dy + dz * dz);
        out.entry = e;
        out.distance = best * length;
        out.position = Vec3(<f32>(ox + dx * best), <f32>(oy + dy * best), <f32>(oz + dz * best));
        out.faceIndex = h.face;
        if (h.inside) {
            out.normal = Vec3(0, 0, 0);
        } else {
            const nx = h.nx, ny = h.ny, nz = h.nz;
            const wx = <f64>inv.xAxis.x * nx + <f64>inv.xAxis.y * ny + <f64>inv.xAxis.z * nz;
            const wy = <f64>inv.yAxis.x * nx + <f64>inv.yAxis.y * ny + <f64>inv.yAxis.z * nz;
            const wz = <f64>inv.zAxis.x * nx + <f64>inv.zAxis.y * ny + <f64>inv.zAxis.z * nz;
            const l = Math.sqrt(wx * wx + wy * wy + wz * wz);
            out.normal = l > 0 ? Vec3(<f32>(wx / l), <f32>(wy / l), <f32>(wz / l)) : Vec3(0, 0, 0);
        }
        return true;
    }

    private cast(from: Vec3, to: Vec3, mask: u32, bodies: bool, areas: bool, hitFromInside: bool, hitBackFaces: bool,
        exclude: Array<SceneNode>?, pickable: bool, only: CollisionObject3D?, drawnOnly: bool,
        out: WorldRayHit): bool {
        out.entry = null;
        out.distance = Infinity;
        out.faceIndex = -1;
        const ox = <f64>from.x;
        const oy = <f64>from.y;
        const oz = <f64>from.z;
        const dx = <f64>to.x - ox;
        const dy = <f64>to.y - oy;
        const dz = <f64>to.z - oz;
        const h = this.hit;
        let best: f64 = 1;
        let found: ShapeEntry? = null;
        let nx: f64 = 0;
        let ny: f64 = 0;
        let nz: f64 = 0;
        let face: i32 = -1;
        let inside = false;
        const es = this.entries;
        for (let i = 0; i < es.length; i++) {
            const e = unchecked(es[i]);
            if (e.disabled) continue;
            if (drawnOnly && !e.node.visibleInTree()) continue;
            const o = e.object;
            if (only != null) {
                if (o !== only) continue;
            } else if (!takes(o, e.isArea, mask, bodies, areas, exclude, pickable)) {
                continue;
            }
            if (!segmentMeetsBox(e.bounds, ox, oy, oz, dx, dy, dz, best)) continue;
            // (the ray in the shape's space: the same parameter t)
            const inv = e.inverse;
            const lox = pointX(inv, ox, oy, oz);
            const loy = pointY(inv, ox, oy, oz);
            const loz = pointZ(inv, ox, oy, oz);
            const ldx = dirX(inv, dx, dy, dz);
            const ldy = dirY(inv, dx, dy, dz);
            const ldz = dirZ(inv, dx, dy, dz);
            if (!rayShape(e.shape!, lox, loy, loz, ldx, ldy, ldz, best, hitFromInside, hitBackFaces, h)) continue;
            // (ties: the earlier entry)
            if (found != null && !(h.t < best)) continue;
            best = h.t;
            found = e;
            nx = h.nx;
            ny = h.ny;
            nz = h.nz;
            face = h.face;
            inside = h.inside;
        }
        if (found == null) return false;
        const length = Math.sqrt(dx * dx + dy * dy + dz * dz);
        out.entry = found;
        out.distance = best * length;
        out.position = Vec3(<f32>(ox + dx * best), <f32>(oy + dy * best), <f32>(oz + dz * best));
        out.faceIndex = face;
        if (inside) {
            out.normal = Vec3(0, 0, 0);
        } else {
            // (the normal through the inverse's transpose, then unit)
            const inv = found.inverse;
            const wx = <f64>inv.xAxis.x * nx + <f64>inv.xAxis.y * ny + <f64>inv.xAxis.z * nz;
            const wy = <f64>inv.yAxis.x * nx + <f64>inv.yAxis.y * ny + <f64>inv.yAxis.z * nz;
            const wz = <f64>inv.zAxis.x * nx + <f64>inv.zAxis.y * ny + <f64>inv.zAxis.z * nz;
            const l = Math.sqrt(wx * wx + wy * wy + wz * wz);
            out.normal = l > 0 ? Vec3(<f32>(wx / l), <f32>(wy / l), <f32>(wz / l)) : Vec3(0, 0, 0);
        }
        return true;
    }

    // The entries whose shape holds the point (world space), in tree order,
    // into `out` (emptied first), at most `max`; returns how many.
    // Allocates nothing once `out` has grown.
    pointQuery(p: Vec3, mask: u32, bodies: bool, areas: bool, exclude: Array<SceneNode>?, out: Array<ShapeEntry>,
        max: i32): i32 {
        out.length = 0;
        const x = <f64>p.x;
        const y = <f64>p.y;
        const z = <f64>p.z;
        const es = this.entries;
        for (let i = 0; i < es.length && out.length < max; i++) {
            const e = unchecked(es[i]);
            if (e.disabled || !takes(e.object, e.isArea, mask, bodies, areas, exclude, false)) continue;
            const b = e.bounds;
            if (x < b.minX - BOX_SLACK || x > b.maxX + BOX_SLACK || y < b.minY - BOX_SLACK || y > b.maxY + BOX_SLACK
                || z < b.minZ - BOX_SLACK || z > b.maxZ + BOX_SLACK) continue;
            const inv = e.inverse;
            if (pointInShape(e.shape!, pointX(inv, x, y, z), pointY(inv, x, y, z), pointZ(inv, x, y, z))) out.push(e);
        }
        return out.length;
    }

    // What overlaps the area now by Godot's rules (its enabled shapes
    // against those of every other object in a layer of its mask; an area
    // only when monitorable), into `bodies` and `areas` (emptied first), in
    // tree order. An area that is not monitoring overlaps nothing.
    // Allocates nothing once the arrays have grown.
    overlapsOf(a: Area3D, bodies: Array<SceneNode>, areas: Array<Area3D>): void {
        bodies.length = 0;
        areas.length = 0;
        if (!a.monitoring) return;
        if (this.sweptAt != this.syncs) this.sweep();
        const es = this.entries;
        const found = this.found;
        found.length = 0;
        const mask = a.collisionMask;
        const ai = this.indexOf(a);
        for (let i = ai >= 0 ? unchecked(this.firstEntry[ai]) : -1; i >= 0; i = unchecked(es[i]).nextOfObject) {
            const ea = unchecked(es[i]);
            if (ea.disabled) continue;
            const near = ea.near;
            for (let k = 0; k < near.length; k++) {
                const eb = unchecked(es[unchecked(near[k])]);
                if (eb.disabled || eb.object === a) continue;
                const o = eb.object;
                if ((o.collisionLayer & mask) == 0) continue;
                if (eb.isArea && !(o as Area3D).monitorable) continue;
                if (found.includes(eb.objectIndex)) continue;
                if (!shapesOverlap(ea.shape!, ea.world, ea.inverse, eb.shape!, eb.world, eb.inverse)) continue;
                found.push(eb.objectIndex);
            }
        }
        // (tree order: the objects' indices sorted, by insertion: a handful)
        for (let i = 1; i < found.length; i++) {
            const v = unchecked(found[i]);
            let j = i - 1;
            while (j >= 0 && unchecked(found[j]) > v) {
                found[j + 1] = unchecked(found[j]);
                j--;
            }
            found[j + 1] = v;
        }
        for (let i = 0; i < found.length; i++) {
            const o = unchecked(this.objects[unchecked(found[i])]);
            const isArea = o instanceof Area3D;
            if (isArea) areas.push(o as Area3D);
            else bodies.push(o);
        }
    }

    // The sort-and-sweep (see the header): each area entry's `near`.
    private sweep(): void {
        this.sweptAt = this.syncs;
        const es = this.entries;
        const order = this.order;
        const boxes = this.boxes;
        const flags = this.flags;
        const owners = this.owners;
        for (let i = 0; i < es.length; i++) unchecked(es[i]).near.length = 0;
        // Insertion sort by the boxes' lower x (an empty box's is +inf).
        for (let i = 1; i < order.length; i++) {
            const v = unchecked(order[i]);
            const key = unchecked(boxes[v * 6]);
            let j = i - 1;
            while (j >= 0 && unchecked(boxes[unchecked(order[j]) * 6]) > key) {
                unchecked(order[j + 1] = order[j]);
                j--;
            }
            unchecked(order[j + 1] = v);
        }
        // (the boxes, flags and owners copied in that order)
        const n = order.length;
        const sb = this.sortedBoxes;
        const sf = this.sortedFlags;
        const so = this.sortedOwners;
        for (let j = 0; j < n; j++) {
            const ib = unchecked(order[j]);
            const b6 = ib * 6;
            const j6 = j * 6;
            unchecked(sb[j6] = boxes[b6]);
            unchecked(sb[j6 + 1] = boxes[b6 + 1]);
            unchecked(sb[j6 + 2] = boxes[b6 + 2]);
            unchecked(sb[j6 + 3] = boxes[b6 + 3]);
            unchecked(sb[j6 + 4] = boxes[b6 + 4]);
            unchecked(sb[j6 + 5] = boxes[b6 + 5]);
            unchecked(sf[j] = flags[ib]);
            unchecked(so[j] = owners[ib]);
        }
        const na = this.nextArea;
        unchecked(na[n] = n);
        for (let j = n - 1; j >= 0; j--) unchecked(na[j] = (unchecked(sf[j]) & 2) != 0 ? j : unchecked(na[j + 1]));
        for (let i = 0; i < n; i++) {
            const fa = unchecked(sf[i]);
            if ((fa & 1) != 0) continue;
            const a6 = i * 6;
            const aMinX = unchecked(sb[a6]);
            // (the empty boxes are last)
            if (aMinX == Infinity) break;
            const aMinY = unchecked(sb[a6 + 1]);
            const aMinZ = unchecked(sb[a6 + 2]);
            const aMaxX = unchecked(sb[a6 + 3]);
            const aMaxY = unchecked(sb[a6 + 4]);
            const aMaxZ = unchecked(sb[a6 + 5]);
            const oa = unchecked(so[i]);
            const aArea = (fa & 2) != 0;
            // (an area meets everything after it, a body only the areas)
            for (let j = aArea ? i + 1 : unchecked(na[i + 1]); j < n; j = aArea ? j + 1 : unchecked(na[j + 1])) {
                const b6 = j * 6;
                if (unchecked(sb[b6]) > aMaxX) break;
                const fb = unchecked(sf[j]);
                if ((fb & 1) != 0 || unchecked(so[j]) == oa) continue;
                if (aMinY > unchecked(sb[b6 + 4]) || unchecked(sb[b6 + 1]) > aMaxY
                    || aMinZ > unchecked(sb[b6 + 5]) || unchecked(sb[b6 + 2]) > aMaxZ) continue;
                const ia = unchecked(order[i]);
                const ib = unchecked(order[j]);
                if (aArea) unchecked(es[ia]).near.push(ib);
                if ((fb & 2) != 0) unchecked(es[ib]).near.push(ia);
            }
        }
    }

    // Brings the world up to the tree: rebuilt when its structure moved,
    // else synced (what the space state's queries do first).
    update(): void {
        if (this.stale()) this.rebuild();
        else this.sync();
    }

    // Godot's intersect_ray (api.as): syncs, then castRay.
    intersectRay(q: PhysicsRayQueryParameters3D): PhysicsRayResult? {
        if (!this.holdSync) this.update();
        const h = this.rayHit;
        if (!this.castRay(q.from, q.to, q.collisionMask, q.collideWithBodies, q.collideWithAreas, q.hitFromInside,
            q.hitBackFaces, q.exclude, false, h)) return null;
        const e = h.entry!;
        const r = this.rayResult;
        r.position = h.position;
        r.normal = h.normal;
        r.collider = e.object;
        r.shape = e.index;
        r.faceIndex = h.faceIndex;
        return r;
    }

    // Godot's intersect_point (api.as): syncs, then pointQuery.
    intersectPoint(q: PhysicsPointQueryParameters3D, maxResults: i32 = 32): Array<PhysicsPointResult> {
        if (!this.holdSync) this.update();
        const n = this.pointQuery(q.position, q.collisionMask, q.collideWithBodies, q.collideWithAreas, q.exclude,
            this.pointEntries, maxResults);
        const pool = this.pointPool;
        while (pool.length < n) pool.push(new PhysicsPointResult());
        const out = this.pointResults;
        out.length = 0;
        for (let i = 0; i < n; i++) {
            const e = unchecked(this.pointEntries[i]);
            const r = unchecked(pool[i]);
            r.collider = e.object;
            r.shape = e.index;
            out.push(r);
        }
        return out;
    }
}

// Whether a query takes the object (see the header).
function takes(o: CollisionObject3D, isArea: bool, mask: u32, bodies: bool, areas: bool,
    exclude: Array<SceneNode>?, pickable: bool): bool {
    if ((o.collisionLayer & mask) == 0) return false;
    if (isArea ? !areas : !bodies) return false;
    if (pickable && !o.inputRayPickable) return false;
    if (exclude != null) {
        for (let i = 0; i < exclude.length; i++) if (unchecked(exclude[i]) === o) return false;
    }
    return true;
}

// The point p through m (columns), one coordinate each (f64: the matrix's
// f32 entries widened).
function pointX(m: Mat4, x: f64, y: f64, z: f64): f64 {
    return <f64>m.xAxis.x * x + <f64>m.yAxis.x * y + <f64>m.zAxis.x * z + <f64>m.wAxis.x;
}

function pointY(m: Mat4, x: f64, y: f64, z: f64): f64 {
    return <f64>m.xAxis.y * x + <f64>m.yAxis.y * y + <f64>m.zAxis.y * z + <f64>m.wAxis.y;
}

function pointZ(m: Mat4, x: f64, y: f64, z: f64): f64 {
    return <f64>m.xAxis.z * x + <f64>m.yAxis.z * y + <f64>m.zAxis.z * z + <f64>m.wAxis.z;
}

function dirX(m: Mat4, x: f64, y: f64, z: f64): f64 {
    return <f64>m.xAxis.x * x + <f64>m.yAxis.x * y + <f64>m.zAxis.x * z;
}

function dirY(m: Mat4, x: f64, y: f64, z: f64): f64 {
    return <f64>m.xAxis.y * x + <f64>m.yAxis.y * y + <f64>m.zAxis.y * z;
}

function dirZ(m: Mat4, x: f64, y: f64, z: f64): f64 {
    return <f64>m.xAxis.z * x + <f64>m.yAxis.z * y + <f64>m.zAxis.z * z;
}

// Scratch for sync (module-level: nothing allocated per call).
const ACC = new StaticArray<f64>(12);
const INV = new StaticArray<f64>(12);

// `n`'s global transform (SceneNode.global: the local transforms of its 3D
// ancestors, multiplied) into `out`, an affine one as f64 columns (x, y,
// z, translation; three numbers each). Every node transform is affine.
function globalAffine(n: SceneNode, out: StaticArray<f64>): void {
    const l = n.local;
    let x0 = <f64>l.xAxis.x;
    let x1 = <f64>l.xAxis.y;
    let x2 = <f64>l.xAxis.z;
    let y0 = <f64>l.yAxis.x;
    let y1 = <f64>l.yAxis.y;
    let y2 = <f64>l.yAxis.z;
    let z0 = <f64>l.zAxis.x;
    let z1 = <f64>l.zAxis.y;
    let z2 = <f64>l.zAxis.z;
    let t0 = <f64>l.wAxis.x;
    let t1 = <f64>l.wAxis.y;
    let t2 = <f64>l.wAxis.z;
    let cur = n;
    while (true) {
        const p = cur.parent;
        if (p == null || !p.is3d) break;
        const m = p.local;
        const m0 = <f64>m.xAxis.x;
        const m1 = <f64>m.xAxis.y;
        const m2 = <f64>m.xAxis.z;
        const m3 = <f64>m.yAxis.x;
        const m4 = <f64>m.yAxis.y;
        const m5 = <f64>m.yAxis.z;
        const m6 = <f64>m.zAxis.x;
        const m7 = <f64>m.zAxis.y;
        const m8 = <f64>m.zAxis.z;
        // (each column through p's linear part; the translation gains p's)
        let a = x0;
        let b = x1;
        let c = x2;
        x0 = m0 * a + m3 * b + m6 * c;
        x1 = m1 * a + m4 * b + m7 * c;
        x2 = m2 * a + m5 * b + m8 * c;
        a = y0;
        b = y1;
        c = y2;
        y0 = m0 * a + m3 * b + m6 * c;
        y1 = m1 * a + m4 * b + m7 * c;
        y2 = m2 * a + m5 * b + m8 * c;
        a = z0;
        b = z1;
        c = z2;
        z0 = m0 * a + m3 * b + m6 * c;
        z1 = m1 * a + m4 * b + m7 * c;
        z2 = m2 * a + m5 * b + m8 * c;
        a = t0;
        b = t1;
        c = t2;
        t0 = m0 * a + m3 * b + m6 * c + <f64>m.wAxis.x;
        t1 = m1 * a + m4 * b + m7 * c + <f64>m.wAxis.y;
        t2 = m2 * a + m5 * b + m8 * c + <f64>m.wAxis.z;
        cur = p;
    }
    unchecked(out[0] = x0);
    unchecked(out[1] = x1);
    unchecked(out[2] = x2);
    unchecked(out[3] = y0);
    unchecked(out[4] = y1);
    unchecked(out[5] = y2);
    unchecked(out[6] = z0);
    unchecked(out[7] = z1);
    unchecked(out[8] = z2);
    unchecked(out[9] = t0);
    unchecked(out[10] = t1);
    unchecked(out[11] = t2);
}

// The inverse of the affine `a` into `out` (zero when `a` is singular, as
// Mat4.inverseOrZero); returns `out`.
function invertAffine(a: StaticArray<f64>, out: StaticArray<f64>): StaticArray<f64> {
    const a0 = unchecked(a[0]);
    const a1 = unchecked(a[1]);
    const a2 = unchecked(a[2]);
    const a3 = unchecked(a[3]);
    const a4 = unchecked(a[4]);
    const a5 = unchecked(a[5]);
    const a6 = unchecked(a[6]);
    const a7 = unchecked(a[7]);
    const a8 = unchecked(a[8]);
    // (cofactors of the 3 x 3 part, columns x = (a0, a1, a2), ...)
    const c0 = a4 * a8 - a7 * a5;
    const c1 = a7 * a2 - a1 * a8;
    const c2 = a1 * a5 - a4 * a2;
    const det = a0 * c0 + a3 * c1 + a6 * c2;
    if (det == 0 || !isFinite(det)) {
        for (let k = 0; k < 12; k++) unchecked(out[k] = 0);
        return out;
    }
    const r = 1 / det;
    // (the inverse's columns: row i of the adjugate is column i here)
    const i0 = c0 * r;
    const i1 = c1 * r;
    const i2 = c2 * r;
    const i3 = (a6 * a5 - a3 * a8) * r;
    const i4 = (a0 * a8 - a6 * a2) * r;
    const i5 = (a3 * a2 - a0 * a5) * r;
    const i6 = (a3 * a7 - a6 * a4) * r;
    const i7 = (a6 * a1 - a0 * a7) * r;
    const i8 = (a0 * a4 - a3 * a1) * r;
    unchecked(out[0] = i0);
    unchecked(out[1] = i1);
    unchecked(out[2] = i2);
    unchecked(out[3] = i3);
    unchecked(out[4] = i4);
    unchecked(out[5] = i5);
    unchecked(out[6] = i6);
    unchecked(out[7] = i7);
    unchecked(out[8] = i8);
    const tx = unchecked(a[9]);
    const ty = unchecked(a[10]);
    const tz = unchecked(a[11]);
    unchecked(out[9] = -(i0 * tx + i3 * ty + i6 * tz));
    unchecked(out[10] = -(i1 * tx + i4 * ty + i7 * tz));
    unchecked(out[11] = -(i2 * tx + i5 * ty + i8 * tz));
    return out;
}

// The affine `a` as a Mat4.
function affineMat4(a: StaticArray<f64>): Mat4 {
    return Mat4(
        Vec4(<f32>unchecked(a[0]), <f32>unchecked(a[1]), <f32>unchecked(a[2]), 0),
        Vec4(<f32>unchecked(a[3]), <f32>unchecked(a[4]), <f32>unchecked(a[5]), 0),
        Vec4(<f32>unchecked(a[6]), <f32>unchecked(a[7]), <f32>unchecked(a[8]), 0),
        Vec4(<f32>unchecked(a[9]), <f32>unchecked(a[10]), <f32>unchecked(a[11]), 1),
    );
}

// worldBox with the affine `a`.
function affineBox(b: Aabb, a: StaticArray<f64>, out: Aabb): void {
    if (b.isEmpty()) {
        out.setEmpty();
        return;
    }
    const cx = (b.minX + b.maxX) * 0.5;
    const cy = (b.minY + b.maxY) * 0.5;
    const cz = (b.minZ + b.maxZ) * 0.5;
    const ex = (b.maxX - b.minX) * 0.5;
    const ey = (b.maxY - b.minY) * 0.5;
    const ez = (b.maxZ - b.minZ) * 0.5;
    const a0 = unchecked(a[0]);
    const a1 = unchecked(a[1]);
    const a2 = unchecked(a[2]);
    const a3 = unchecked(a[3]);
    const a4 = unchecked(a[4]);
    const a5 = unchecked(a[5]);
    const a6 = unchecked(a[6]);
    const a7 = unchecked(a[7]);
    const a8 = unchecked(a[8]);
    const wx = a0 * cx + a3 * cy + a6 * cz + unchecked(a[9]);
    const wy = a1 * cx + a4 * cy + a7 * cz + unchecked(a[10]);
    const wz = a2 * cx + a5 * cy + a8 * cz + unchecked(a[11]);
    const hx = Math.abs(a0) * ex + Math.abs(a3) * ey + Math.abs(a6) * ez;
    const hy = Math.abs(a1) * ex + Math.abs(a4) * ey + Math.abs(a7) * ez;
    const hz = Math.abs(a2) * ex + Math.abs(a5) * ey + Math.abs(a8) * ez;
    out.set(wx - hx, wy - hy, wz - hz, wx + hx, wy + hy, wz + hz);
}

// The world box of the local box `b` placed by `m`: its centre carried,
// its half extents through the absolute values of m's linear part (the
// tightest box of the 8 corners).
export function worldBox(b: Aabb, m: Mat4, out: Aabb): void {
    if (b.isEmpty()) {
        out.setEmpty();
        return;
    }
    const cx = (b.minX + b.maxX) * 0.5;
    const cy = (b.minY + b.maxY) * 0.5;
    const cz = (b.minZ + b.maxZ) * 0.5;
    const ex = (b.maxX - b.minX) * 0.5;
    const ey = (b.maxY - b.minY) * 0.5;
    const ez = (b.maxZ - b.minZ) * 0.5;
    const wx = pointX(m, cx, cy, cz);
    const wy = pointY(m, cx, cy, cz);
    const wz = pointZ(m, cx, cy, cz);
    const hx = Math.abs(<f64>m.xAxis.x) * ex + Math.abs(<f64>m.yAxis.x) * ey + Math.abs(<f64>m.zAxis.x) * ez;
    const hy = Math.abs(<f64>m.xAxis.y) * ex + Math.abs(<f64>m.yAxis.y) * ey + Math.abs(<f64>m.zAxis.y) * ez;
    const hz = Math.abs(<f64>m.xAxis.z) * ex + Math.abs(<f64>m.yAxis.z) * ey + Math.abs(<f64>m.zAxis.z) * ez;
    out.set(wx - hx, wy - hy, wz - hz, wx + hx, wy + hy, wz + hz);
}

// Whether the segment o + t d, t in [0, tMax], meets the box (grown by
// BOX_SLACK): the slab test.
function segmentMeetsBox(b: Aabb, ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64, tMax: f64): bool {
    if (b.isEmpty()) return false;
    let t0: f64 = 0;
    let t1 = tMax;
    if (dx == 0) {
        if (ox < b.minX - BOX_SLACK || ox > b.maxX + BOX_SLACK) return false;
    } else {
        let ta = (b.minX - BOX_SLACK - ox) / dx;
        let tb = (b.maxX + BOX_SLACK - ox) / dx;
        if (ta > tb) {
            const s = ta;
            ta = tb;
            tb = s;
        }
        if (ta > t0) t0 = ta;
        if (tb < t1) t1 = tb;
        if (t0 > t1) return false;
    }
    if (dy == 0) {
        if (oy < b.minY - BOX_SLACK || oy > b.maxY + BOX_SLACK) return false;
    } else {
        let ta = (b.minY - BOX_SLACK - oy) / dy;
        let tb = (b.maxY + BOX_SLACK - oy) / dy;
        if (ta > tb) {
            const s = ta;
            ta = tb;
            tb = s;
        }
        if (ta > t0) t0 = ta;
        if (tb < t1) t1 = tb;
        if (t0 > t1) return false;
    }
    if (dz == 0) {
        if (oz < b.minZ - BOX_SLACK || oz > b.maxZ + BOX_SLACK) return false;
    } else {
        let ta = (b.minZ - BOX_SLACK - oz) / dz;
        let tb = (b.maxZ + BOX_SLACK - oz) / dz;
        if (ta > tb) {
            const s = ta;
            ta = tb;
            tb = s;
        }
        if (ta > t0) t0 = ta;
        if (tb < t1) t1 = tb;
        if (t0 > t1) return false;
    }
    return true;
}
