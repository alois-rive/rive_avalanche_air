// BMesh-style mesh kernel. Verts, edges, faces and
// face corners (loops) live in slot storage with stable ids. The loops of one
// face occupy a contiguous run of loop ids, so per-face iteration is a range
// walk (`for (let l = f.loopStart; l < f.loopEnd(); l++)`).
//
// Adjacency (`vert -> edges`, `edge -> faces`) is maintained by every
// mutating method here, so operators can query it without rebuilding after
// each step. The order of those lists is observable (operators iterate them)
// and is part of the results: pushes append, `unlinkEdge` removes keeping
// the order, `popLoops` uses swap-remove.
//
// Methods that live in other modules: attributes are in the "attributes"
// section below (types in ./attr); `validate()` / `debugValidate()` call
// ./validate. Euler operators, queries, selection, shape keys, triangulation
// and UVs are free functions `fn(m: Mesh, ...)` in their own module
// (./euler, ./query, ./selection, ./shapekey, ./triangulate, ./uv), with
// one-line delegating methods in that module's section at the end of the
// class.
//
// A missing id is the NO_ID sentinel (u32::MAX).

import { SlotVec } from "../../../base/slot";
import { Vec2, Vec3, Mat4 } from "../../../base/vecmath";
import { Result, panic, stableSort, dedup, maxF32 } from "../../../base/util";
import { ShapeKey } from "./shapekey";
import {
    hasShapeKeys as hasShapeKeysFn, findShapeKey as findShapeKeyFn, activeShapeKeyOf as activeShapeKeyOfFn, shapeKeyCo as shapeKeyCoFn, extendShapeKeys as extendShapeKeysFn, uniqueShapeKeyName as uniqueShapeKeyNameFn,
    shapeKeyAdd as shapeKeyAddFn, shapeKeyRemove as shapeKeyRemoveFn, hasShapeKeyMix as hasShapeKeyMixFn, shapeKeyMix as shapeKeyMixFn, setAllPositions as setAllPositionsFn, withShapeKeyMix as withShapeKeyMixFn,
    withShapeKey as withShapeKeyFn, storeActiveShapeKey as storeActiveShapeKeyFn, loadShapeKey as loadShapeKeyFn, propagateBasisChange as propagateBasisChangeFn,
} from "./shapekey";
import { triangulateFace as triangulateFaceFn } from "./triangulate";
import {
    Join, UvVertices, UvBounds, uvLayerIndex as uvLayerIndexFn, uvLayerNames as uvLayerNamesFn, uniqueUvLayerName as uniqueUvLayerNameFn, addUvLayer as addUvLayerFn, removeUvLayer as removeUvLayerFn,
    uvOf as uvOfFn, setUv as setUvFn, uvFlag as uvFlagFn, setUvFlag as setUvFlagFn, uvSelected as uvSelectedFn, uvPinned as uvPinnedFn, uvFaces as uvFacesFn, uvSelectedLoops as uvSelectedLoopsFn, uvSelectFaces as uvSelectFacesFn,
    uvSelectSticky as uvSelectStickyFn, uvIslands as uvIslandsFn, uvVertices as uvVerticesFn, uvBounds as uvBoundsFn, uvFaceArea as uvFaceAreaFn,
} from "./uv";
import {
    Domain, AttrType, AttrValue, AttrValueKind, AttrData, AttrLayer, attrMean,
} from "./attr";
import { validateMesh } from "./validate";
import {
    SplitEdgeResult, SplitFaceResult, splitEdge as eulerSplitEdge, splitFace as eulerSplitFace,
    joinFaces as eulerJoinFaces, collapseEdge as eulerCollapseEdge, mergeVerts as eulerMergeVerts,
    dissolveEdge as eulerDissolveEdge, dissolveVert as eulerDissolveVert,
    mergeByDistance as eulerMergeByDistance,
} from "./euler";
import * as query from "./query";
import * as selection from "./selection";
import { ActivePosition } from "./selection";
import { SelectMode } from "./select_mode";
import { ElementCounts } from "../../../base/report";

// Re-exported so callers import the mesh types from one place.
export { AttrData, AttrLayer, AttrType, AttrValue, Domain } from "./attr";
export { ShapeKey } from "./shapekey";

export type VertId = u32;
export type EdgeId = u32;
export type FaceId = u32;
export type LoopId = u32;

// Sentinel for "no vert / edge / face / loop".
export const NO_ID: u32 = 0xFFFFFFFF;

// Debug-only invariant checks: off by default (they cost time in the CLI);
// test suites switch them on with `setDebugAssertions(true)`.
export let DEBUG_ASSERTIONS: bool = false;
export function setDebugAssertions(on: bool): void {
    DEBUG_ASSERTIONS = on;
}

// One `(vertex group index, weight)` pair of `Vert.groups`.
export class GroupWeight {
    group: u32 = 0;
    weight: f32 = 0;

    static new(group: u32, weight: f32): GroupWeight {
        const g = new GroupWeight();
        g.group = group;
        g.weight = weight;
        return g;
    }

    clone(): GroupWeight {
        return GroupWeight.new(this.group, this.weight);
    }
}

// Deep copy of a group list.
export function cloneGroups(gs: Array<GroupWeight>): Array<GroupWeight> {
    const out: Array<GroupWeight> = [];
    for (let i = 0; i < gs.length; i++) out.push(gs[i].clone());
    return out;
}

export class Vert {
    co: Vec3 = Vec3(0, 0, 0);
    select: bool = false;
    hide: bool = false;
    // `(vertex group index, weight)` pairs, in `Object.vertexGroups` order.
    groups: Array<GroupWeight> = [];

    static new(co: Vec3): Vert {
        const v = new Vert();
        v.co = co;
        return v;
    }

    clone(): Vert {
        const v = new Vert();
        v.co = this.co;
        v.select = this.select;
        v.hide = this.hide;
        v.groups = cloneGroups(this.groups);
        return v;
    }

    // Field-wise equality.
    equals(o: Vert): bool {
        if (!(this.co == o.co) || this.select != o.select || this.hide != o.hide) return false;
        if (this.groups.length != o.groups.length) return false;
        for (let i = 0; i < this.groups.length; i++) {
            if (this.groups[i].group != o.groups[i].group || this.groups[i].weight != o.groups[i].weight) return false;
        }
        return true;
    }
}

export class Edge {
    // The two end verts; a value array (copied on assignment).
    v: FixedArray<u32, 2>;
    select: bool = false;
    hide: bool = false;
    seam: bool = false;
    sharp: bool = false;
    crease: f32 = 0;
    bevelWeight: f32 = 0;

    static new(a: VertId, b: VertId): Edge {
        const e = new Edge();
        e.v[0] = a;
        e.v[1] = b;
        return e;
    }

    // Sets both end verts.
    setV(a: VertId, b: VertId): void {
        this.v[0] = a;
        this.v[1] = b;
    }

    // The vertex at the other end, or NO_ID if `v` is not on this edge.
    other(v: VertId): VertId {
        if (this.v[0] == v) return this.v[1];
        if (this.v[1] == v) return this.v[0];
        return NO_ID;
    }

    hasVert(v: VertId): bool {
        return this.v[0] == v || this.v[1] == v;
    }

    // Copy the marks (seam, sharp, crease, bevel weight) from another edge.
    copyMarks(from: Edge): void {
        this.seam = from.seam;
        this.sharp = from.sharp;
        this.crease = from.crease;
        this.bevelWeight = from.bevelWeight;
    }

    clone(): Edge {
        const e = new Edge();
        e.v[0] = this.v[0];
        e.v[1] = this.v[1];
        e.select = this.select;
        e.hide = this.hide;
        e.seam = this.seam;
        e.sharp = this.sharp;
        e.crease = this.crease;
        e.bevelWeight = this.bevelWeight;
        return e;
    }

    equals(o: Edge): bool {
        return this.v[0] == o.v[0] && this.v[1] == o.v[1] && this.select == o.select && this.hide == o.hide
            && this.seam == o.seam && this.sharp == o.sharp && this.crease == o.crease && this.bevelWeight == o.bevelWeight;
    }
}

export class Face {
    loopStart: LoopId = 0;
    loopLen: u32 = 0;
    normal: Vec3 = Vec3(0, 0, 0);
    smooth: bool = false;
    materialIndex: u16 = 0;
    select: bool = false;
    hide: bool = false;

    // The face's loops are the range loopStart..loopEnd().
    loopEnd(): LoopId {
        return this.loopStart + this.loopLen;
    }

    // The loop ids as an array (allocates; prefer the range walk in hot code).
    loops(): Array<LoopId> {
        const out: Array<LoopId> = [];
        for (let l = this.loopStart; l < this.loopStart + this.loopLen; l++) out.push(l);
        return out;
    }

    clone(): Face {
        const f = new Face();
        f.loopStart = this.loopStart;
        f.loopLen = this.loopLen;
        f.normal = this.normal;
        f.smooth = this.smooth;
        f.materialIndex = this.materialIndex;
        f.select = this.select;
        f.hide = this.hide;
        return f;
    }

    equals(o: Face): bool {
        return this.loopStart == o.loopStart && this.loopLen == o.loopLen && this.normal == o.normal
            && this.smooth == o.smooth && this.materialIndex == o.materialIndex && this.select == o.select && this.hide == o.hide;
    }
}

export class Loop {
    vert: VertId = 0;
    edge: EdgeId = 0;
    face: FaceId = 0;
    // One UV per UV layer, indexed like `Mesh.uvLayers`.
    uv: Array<Vec2> = [];
    // Per-layer UV editor state (UV_SELECT, UV_PIN bits), indexed like `uv`.
    // May be shorter than `uv` on loops rebuilt by an operator; the UV
    // accessors treat missing entries as clear.
    uvFlags: Array<u8> = [];

    clone(): Loop {
        const l = new Loop();
        l.vert = this.vert;
        l.edge = this.edge;
        l.face = this.face;
        l.uv = this.uv.slice(0);
        l.uvFlags = this.uvFlags.slice(0);
        return l;
    }

    equals(o: Loop): bool {
        if (this.vert != o.vert || this.edge != o.edge || this.face != o.face) return false;
        if (this.uv.length != o.uv.length || this.uvFlags.length != o.uvFlags.length) return false;
        for (let i = 0; i < this.uv.length; i++) if (!(this.uv[i] == o.uv[i])) return false;
        for (let i = 0; i < this.uvFlags.length; i++) if (this.uvFlags[i] != o.uvFlags[i]) return false;
        return true;
    }
}

export class UvLayer {
    name: string = "";

    static new(name: string): UvLayer {
        const l = new UvLayer();
        l.name = name;
        return l;
    }

    clone(): UvLayer {
        return UvLayer.new(this.name);
    }

    // Field-wise equality.
    equals(o: UvLayer): bool {
        return this.name == o.name;
    }
}

// A saved selection (`select-set save <name>`).
export class SelectionSet {
    verts: Array<VertId> = [];
    edges: Array<EdgeId> = [];
    faces: Array<FaceId> = [];

    clone(): SelectionSet {
        const s = new SelectionSet();
        s.verts = this.verts.slice(0);
        s.edges = this.edges.slice(0);
        s.faces = this.faces.slice(0);
        return s;
    }

    // Field-wise equality.
    equals(o: SelectionSet): bool {
        return sameIds(this.verts, o.verts) && sameIds(this.edges, o.edges) && sameIds(this.faces, o.faces);
    }
}

function sameIds(a: Array<u32>, b: Array<u32>): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
    return true;
}

// Variant order is the file format.
export enum ElemKind {
    Vert,
    Edge,
    Face,
}

export namespace ElemKind {
    export function name(k: ElemKind): string {
        switch (k) {
            case ElemKind.Vert: return "vert";
            case ElemKind.Edge: return "edge";
            default: return "face";
        }
    }

    // The variant name ("Vert", ...), also used in saved data.
    export function debug(k: ElemKind): string {
        switch (k) {
            case ElemKind.Vert: return "Vert";
            case ElemKind.Edge: return "Edge";
            default: return "Face";
        }
    }

    // The kind named by `s`, or -1.
    export function parse(s: string): i32 {
        if (s == "vert" || s == "verts" || s == "vertex" || s == "vertices") return ElemKind.Vert;
        if (s == "edge" || s == "edges") return ElemKind.Edge;
        if (s == "face" || s == "faces") return ElemKind.Face;
        return -1;
    }
}

// One entry of `Mesh.selectionHistory`.
export class ElemRef {
    kind: ElemKind = ElemKind.Vert;
    id: u32 = 0;

    static new(kind: ElemKind, id: u32): ElemRef {
        const r = new ElemRef();
        r.kind = kind;
        r.id = id;
        return r;
    }

    clone(): ElemRef {
        return ElemRef.new(this.kind, this.id);
    }

    equals(o: ElemRef): bool {
        return this.kind == o.kind && this.id == o.id;
    }
}

// A face corner's UV data by vertex: the vert, its UV per layer and its UV flags.
export class CornerUv {
    vert: VertId = 0;
    uv: Array<Vec2> = [];
    flags: Array<u8> = [];

    static new(vert: VertId, uv: Array<Vec2>, flags: Array<u8>): CornerUv {
        const c = new CornerUv();
        c.vert = vert;
        c.uv = uv;
        c.flags = flags;
        return c;
    }
}

// What Mesh.bounds returns (null when there is nothing to bound).
export class Bounds {
    lo: Vec3 = Vec3(0, 0, 0);
    hi: Vec3 = Vec3(0, 0, 0);

    static new(lo: Vec3, hi: Vec3): Bounds {
        const b = new Bounds();
        b.lo = lo;
        b.hi = hi;
        return b;
    }
}

// What Mesh.extract returns: the new mesh and the old -> new vert map.
export class Extracted {
    mesh: Mesh;
    vmap: Map<VertId, VertId>;

    constructor(mesh: Mesh, vmap: Map<VertId, VertId>) {
        this.mesh = mesh;
        this.vmap = vmap;
    }
}

// Every revision handed out in this process is unique, so a mesh that was
// reloaded (undo, `open`) can never collide with a stale cache entry.
let NEXT_REVISION: u64 = 1;

function freshRevision(): u64 {
    const r = NEXT_REVISION;
    NEXT_REVISION += 1;
    return r;
}

// Weighted mean of vertex group memberships, used wherever an operator
// creates a vertex from others. `lists[i]` is weighted by `factors[i]`
// Groups below a hair of weight are
// dropped so lists do not grow with every cut.
export function interpolateGroups(lists: Array<Array<GroupWeight>>, factors: Array<f32>): Array<GroupWeight> {
    const out: Array<GroupWeight> = [];
    const n = min(lists.length, factors.length);
    for (let s = 0; s < n; s++) {
        const groups = lists[s];
        const factor = factors[s];
        for (let i = 0; i < groups.length; i++) {
            const g = groups[i].group;
            const v = groups[i].weight * factor;
            let found = -1;
            for (let j = 0; j < out.length; j++) {
                if (out[j].group == g) {
                    found = j;
                    break;
                }
            }
            if (found >= 0) out[found].weight += v;
            else out.push(GroupWeight.new(g, v));
        }
    }
    const kept: Array<GroupWeight> = [];
    for (let i = 0; i < out.length; i++) {
        if (out[i].weight > <f32>1e-6) kept.push(out[i]);
    }
    stableSort<GroupWeight>(kept, (a: GroupWeight, b: GroupWeight): i32 => (a.group < b.group ? -1 : (a.group > b.group ? 1 : 0)));
    return kept;
}

function edgeKey(a: VertId, b: VertId): u64 {
    return a < b ? ((<u64>a << 32) | <u64>b) : ((<u64>b << 32) | <u64>a);
}

function pushTo(map: Map<u32, Array<u32>>, key: u32, value: u32): void {
    if (map.has(key)) map.get(key).push(value);
    else map.set(key, [value]);
}

function sortU32(a: Array<u32>): void {
    a.sort((x: u32, y: u32): i32 => (x < y ? -1 : (x > y ? 1 : 0)));
}

export class Mesh {
    verts: SlotVec<Vert> = new SlotVec<Vert>();
    edges: SlotVec<Edge> = new SlotVec<Edge>();
    faces: SlotVec<Face> = new SlotVec<Face>();
    loops: SlotVec<Loop> = new SlotVec<Loop>();
    uvLayers: Array<UvLayer> = [];
    activeUv: u32 = 0;
    // Ordered history of selected elements, for "active element" semantics.
    selectionHistory: Array<ElemRef> = [];
    // Named selections (`select-set`). Iterate the keys sorted with cmpStr
    // wherever the order is observable.
    savedSelections: Map<string, SelectionSet> = new Map<string, SelectionSet>();
    // Relative shape keys, the Basis first.
    shapeKeys: Array<ShapeKey> = [];
    // Index of the active key.
    activeShapeKey: u32 = 0;
    // Named attribute layers on the four domains (last serialized field).
    attributes: Array<AttrLayer> = [];

    // Transient lookup tables (not saved); rebuilt by afterLoad.
    // Read them through findEdge / vertEdges / edgeFaces; the maps are public
    // only for validate and the codec.
    edgeLookup: Map<u64, EdgeId> = new Map<u64, EdgeId>();
    vertEdgesMap: Map<VertId, Array<EdgeId>> = new Map<VertId, Array<EdgeId>>();
    edgeFacesMap: Map<EdgeId, Array<FaceId>> = new Map<EdgeId, Array<FaceId>>();
    // Process-unique stamp that changes on every mutation through this API.
    // Not persisted. `new Mesh()` has revision 0; `Mesh.new()` gets a fresh
    // revision.
    revision: u64 = 0;

    static new(): Mesh {
        const m = new Mesh();
        m.touch();
        return m;
    }

    // Mark the mesh as changed. Mesh methods call this themselves; operators
    // that write fields directly (selection flags, smooth flags) must call it.
    touch(): void {
        this.revision = freshRevision();
    }

    // Mesh with one UV layer named like Blender's default.
    static withDefaultUv(): Mesh {
        const m = Mesh.new();
        m.uvLayers.push(UvLayer.new("UVMap"));
        return m;
    }

    // A deep copy, lookup tables and revision included.
    clone(): Mesh {
        const m = new Mesh();
        m.verts = this.verts.map<Vert>((v: Vert): Vert => v.clone());
        m.edges = this.edges.map<Edge>((e: Edge): Edge => e.clone());
        m.faces = this.faces.map<Face>((f: Face): Face => f.clone());
        m.loops = this.loops.map<Loop>((l: Loop): Loop => l.clone());
        for (let i = 0; i < this.uvLayers.length; i++) m.uvLayers.push(this.uvLayers[i].clone());
        m.activeUv = this.activeUv;
        for (let i = 0; i < this.selectionHistory.length; i++) m.selectionHistory.push(this.selectionHistory[i].clone());
        const names = this.savedSelections.keys();
        for (let i = 0; i < names.length; i++) m.savedSelections.set(names[i], this.savedSelections.get(names[i]).clone());
        for (let i = 0; i < this.shapeKeys.length; i++) m.shapeKeys.push(this.shapeKeys[i].clone());
        m.activeShapeKey = this.activeShapeKey;
        for (let i = 0; i < this.attributes.length; i++) m.attributes.push(this.attributes[i].clone());
        const ek = this.edgeLookup.keys();
        for (let i = 0; i < ek.length; i++) m.edgeLookup.set(ek[i], this.edgeLookup.get(ek[i]));
        const vk = this.vertEdgesMap.keys();
        for (let i = 0; i < vk.length; i++) m.vertEdgesMap.set(vk[i], this.vertEdgesMap.get(vk[i]).slice(0));
        const fk = this.edgeFacesMap.keys();
        for (let i = 0; i < fk.length; i++) m.edgeFacesMap.set(fk[i], this.edgeFacesMap.get(fk[i]).slice(0));
        m.revision = this.revision;
        return m;
    }

    // Rebuild transient lookup tables after deserialization.
    afterLoad(): void {
        this.touch();
        this.edgeLookup.clear();
        this.vertEdgesMap.clear();
        this.edgeFacesMap.clear();
        const eb = this.edges.idBound();
        for (let id: u32 = 0; id < eb; id++) {
            const e = this.edges.get(id);
            if (e == null) continue;
            this.edgeLookup.set(edgeKey(e.v[0], e.v[1]), id);
            pushTo(this.vertEdgesMap, e.v[0], id);
            pushTo(this.vertEdgesMap, e.v[1], id);
        }
        const fb = this.faces.idBound();
        for (let fid: u32 = 0; fid < fb; fid++) {
            const f = this.faces.get(fid);
            if (f == null) continue;
            for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
                pushTo(this.edgeFacesMap, this.loops.at(l).edge, fid);
            }
        }
    }

    // ------------------------------------------------------------ creation

    // Reserve room for a bulk build (a no-op here).
    reserve(verts: i32, edges: i32, faces: i32, loops: i32): void {}

    addVert(co: Vec3): VertId {
        this.touch();
        const id = this.verts.push(Vert.new(co));
        this.growAttrs(Domain.Point);
        return id;
    }

    // A vertex at `co` whose group weights are the weighted mean of the
    // sources (`srcVerts[i]` weighted by `srcFactors[i]`).
    addVertFrom(co: Vec3, srcVerts: Array<VertId>, srcFactors: Array<f32>): VertId {
        const lists: Array<Array<GroupWeight>> = [];
        const factors: Array<f32> = [];
        const n = min(srcVerts.length, srcFactors.length);
        for (let i = 0; i < n; i++) {
            const vert = this.verts.get(srcVerts[i]);
            if (vert == null) continue;
            lists.push(vert.groups);
            factors.push(srcFactors[i]);
        }
        const groups = interpolateGroups(lists, factors);
        this.touch();
        const v = Vert.new(co);
        v.groups = groups;
        const id = this.verts.push(v);
        this.growAttrs(Domain.Point);
        // The same sources the group weights came from.
        this.interpolatePointAttrs(id, srcVerts, srcFactors);
        return id;
    }

    // The edge joining a and b, or NO_ID.
    findEdge(a: VertId, b: VertId): EdgeId {
        const k = edgeKey(a, b);
        return this.edgeLookup.has(k) ? this.edgeLookup.get(k) : NO_ID;
    }

    addEdge(a: VertId, b: VertId): EdgeId {
        const found = this.findEdge(a, b);
        if (found != NO_ID) return found;
        if (DEBUG_ASSERTIONS && a == b) panic("degenerate edge");
        const id = this.edges.push(Edge.new(a, b));
        this.linkEdge(id, a, b);
        this.growAttrs(Domain.Edge);
        this.touch();
        return id;
    }

    private linkEdge(id: EdgeId, a: VertId, b: VertId): void {
        this.edgeLookup.set(edgeKey(a, b), id);
        pushTo(this.vertEdgesMap, a, id);
        pushTo(this.vertEdgesMap, b, id);
    }

    private unlinkEdge(id: EdgeId, a: VertId, b: VertId): void {
        this.edgeLookup.delete(edgeKey(a, b));
        for (let k = 0; k < 2; k++) {
            const v = k == 0 ? a : b;
            if (!this.vertEdgesMap.has(v)) continue;
            const list = this.vertEdgesMap.get(v);
            let w = 0;
            for (let i = 0; i < list.length; i++) {
                if (list[i] != id) {
                    list[w] = list[i];
                    w++;
                }
            }
            list.length = w;
            if (list.length == 0) this.vertEdgesMap.delete(v);
        }
    }

    // Re-point an existing edge to new endpoints (used by merge/collapse).
    // The caller guarantees no other edge already joins `a` and `b`.
    setEdgeVerts(id: EdgeId, a: VertId, b: VertId): void {
        const e = this.edges.at(id);
        const oa = e.v[0];
        const ob = e.v[1];
        this.unlinkEdge(id, oa, ob);
        e.setV(a, b);
        this.linkEdge(id, a, b);
        this.touch();
    }

    // Add a face over `verts` (counter-clockwise seen from outside), creating
    // missing edges. UVs are zeroed for every layer; use addFaceUv to set
    // them on the active layer.
    addFace(verts: Array<VertId>): FaceId {
        const n = verts.length;
        if (DEBUG_ASSERTIONS && n < 3) panic("faces need at least 3 verts");
        const faceId = this.faces.idBound();
        const loopStart = this.pushLoops(faceId, verts);
        const f = new Face();
        f.loopStart = loopStart;
        f.loopLen = <u32>n;
        const id = this.faces.push(f);
        if (DEBUG_ASSERTIONS && id != faceId) panic("assertion `left == right` failed");
        this.growAttrs(Domain.Face);
        const normal = this.computeFaceNormal(id);
        this.faces.at(id).normal = normal;
        this.touch();
        return id;
    }

    // Push a fresh contiguous loop ring for `faceId` and register the
    // edge -> face links. Returns the first loop id.
    private pushLoops(faceId: FaceId, verts: Array<VertId>): LoopId {
        const n = verts.length;
        const loopStart = this.loops.idBound();
        const layers = this.uvLayers.length;
        for (let i = 0; i < n; i++) {
            const a = verts[i];
            const b = verts[(i + 1) % n];
            const edge = this.addEdge(a, b);
            pushTo(this.edgeFacesMap, edge, faceId);
            const lp = new Loop();
            lp.vert = a;
            lp.edge = edge;
            lp.face = faceId;
            for (let k = 0; k < layers; k++) {
                lp.uv.push(Vec2(0, 0));
                lp.uvFlags.push(0);
            }
            this.loops.push(lp);
        }
        this.growAttrs(Domain.Corner);
        return loopStart;
    }

    private popLoops(faceId: FaceId, start: LoopId, end: LoopId): void {
        for (let l = start; l < end; l++) {
            const lp = this.loops.remove(l);
            if (lp == null) continue;
            if (!this.edgeFacesMap.has(lp.edge)) continue;
            const list = this.edgeFacesMap.get(lp.edge);
            const pos = list.indexOf(faceId);
            if (pos >= 0) {
                const last = list.length - 1;
                if (pos != last) list[pos] = list[last];
                list.length = last;
            }
            if (list.length == 0) this.edgeFacesMap.delete(lp.edge);
        }
    }

    addFaceUv(verts: Array<VertId>, uvs: Array<Vec2>): FaceId {
        const id = this.addFace(verts);
        // Compared as u32: an out-of-range
        // active layer, however large, sets nothing.
        if (this.activeUv < <u32>this.uvLayers.length) {
            const layer = <i32>this.activeUv;
            const f = this.faces.at(id);
            let k = 0;
            for (let l = f.loopStart; l < f.loopStart + f.loopLen && k < uvs.length; l++) {
                // Array<struct> takes no indexed store: write the fields.
                const uvArr = this.loops.at(l).uv;
                uvArr[layer].x = uvs[k].x;
                uvArr[layer].y = uvs[k].y;
                k++;
            }
        }
        return id;
    }

    // Add a face copying flags and material from `like` (smooth, material,
    // hide); selection is not copied.
    addFaceLike(verts: Array<VertId>, like: FaceId): FaceId {
        const src = this.faces.at(like);
        const smooth = src.smooth;
        const material = src.materialIndex;
        const hide = src.hide;
        const id = this.addFace(verts);
        const f = this.faces.at(id);
        f.smooth = smooth;
        f.materialIndex = material;
        f.hide = hide;
        this.copyAttrs(Domain.Face, like, id);
        return id;
    }

    // Pop a face's loops (keeping the face record with loopLen = 0) and
    // return the corner UVs (and UV flags) by vertex, so the ring can be
    // rebuilt after the edges it uses were re-pointed or removed.
    detachFaceLoops(id: FaceId): Array<CornerUv> {
        const f = this.faces.at(id);
        const old: Array<CornerUv> = [];
        for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
            const lp = this.loops.at(l);
            old.push(CornerUv.new(lp.vert, lp.uv.slice(0), lp.uvFlags.slice(0)));
        }
        this.popLoops(id, f.loopStart, f.loopStart + f.loopLen);
        f.loopLen = 0;
        return old;
    }

    // Give a detached face a new ring. UVs are carried over by vertex id
    // where the vertex was already a corner; new corners take the UV of the
    // previous corner in the new ring so seams stay put.
    attachFaceLoops(id: FaceId, verts: Array<VertId>, old: Array<CornerUv>): void {
        if (DEBUG_ASSERTIONS && verts.length < 3) panic("faces need at least 3 verts");
        if (DEBUG_ASSERTIONS && this.faces.at(id).loopLen != 0) panic("face still has loops");
        const loopStart = this.pushLoops(id, verts);
        const f = this.faces.at(id);
        f.loopStart = loopStart;
        f.loopLen = <u32>verts.length;
        let last: Array<Vec2>? = old.length > 0 ? old[0].uv.slice(0) : null;
        for (let i = 0; i < verts.length; i++) {
            const v = verts[i];
            const l = loopStart + <u32>i;
            let found = -1;
            for (let j = 0; j < old.length; j++) {
                if (old[j].vert == v) {
                    found = j;
                    break;
                }
            }
            if (found >= 0) {
                const lp = this.loops.at(l);
                lp.uv = old[found].uv.slice(0);
                lp.uvFlags = old[found].flags.slice(0);
                last = old[found].uv.slice(0);
            } else if (last != null) {
                this.loops.at(l).uv = last!.slice(0);
            }
        }
        const normal = this.computeFaceNormal(id);
        this.faces.at(id).normal = normal;
        this.touch();
    }

    // Replace the vertex ring of an existing face, keeping its id, flags
    // and normal direction. Loops are re-allocated; UVs are carried over by
    // vertex id (see attachFaceLoops).
    setFaceVerts(id: FaceId, verts: Array<VertId>): void {
        const old = this.detachFaceLoops(id);
        this.attachFaceLoops(id, verts, old);
    }

    // Replace a face's vertices corner for corner (`verts[i]` takes the
    // place of corner i), keeping each corner's UVs, UV flags and corner
    // attributes. Unlike setFaceVerts, which carries UVs by vertex id, this
    // holds when the new vertices are copies that were never corners of
    // the face (edge split).
    remapFaceVerts(id: FaceId, verts: Array<VertId>): void {
        const oldStart = this.faces.at(id).loopStart;
        const n = this.faces.at(id).loopLen;
        if (DEBUG_ASSERTIONS && <u32>verts.length != n) panic("remapFaceVerts needs one vertex per corner");
        const old = this.detachFaceLoops(id);
        for (let i = 0; i < old.length; i++) old[i].vert = verts[i];
        this.attachFaceLoops(id, verts, old);
        const start = this.faces.at(id).loopStart;
        // Popped loops keep their attribute values, so they can be copied.
        if (start != oldStart) {
            for (let i: u32 = 0; i < n; i++) this.copyAttrs(Domain.Corner, oldStart + i, start + i);
        }
    }

    // ------------------------------------------------------------- queries

    faceVerts(id: FaceId): Array<VertId> {
        const f = this.faces.at(id);
        const out: Array<VertId> = [];
        for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) out.push(this.loops.at(l).vert);
        return out;
    }

    faceEdges(id: FaceId): Array<EdgeId> {
        const f = this.faces.at(id);
        const out: Array<EdgeId> = [];
        for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) out.push(this.loops.at(l).edge);
        return out;
    }

    // Edges around a vertex (unique; in link order). LIVE VIEW of the
    // adjacency list: never mutate it, and copy it with
    // `.slice(0)` before changing the mesh while
    // iterating. A vertex without edges gets a fresh empty array.
    vertEdges(v: VertId): Array<EdgeId> {
        return this.vertEdgesMap.has(v) ? this.vertEdgesMap.get(v) : [];
    }

    // Faces using an edge (usually one or two). LIVE VIEW, as vertEdges.
    edgeFaces(e: EdgeId): Array<FaceId> {
        return this.edgeFacesMap.has(e) ? this.edgeFacesMap.get(e) : [];
    }

    // Faces around a vertex (unique, sorted).
    vertFaces(v: VertId): Array<FaceId> {
        const out: Array<FaceId> = [];
        const es = this.vertEdges(v);
        for (let i = 0; i < es.length; i++) {
            const fs = this.edgeFaces(es[i]);
            for (let j = 0; j < fs.length; j++) out.push(fs[j]);
        }
        sortU32(out);
        dedup<u32>(out);
        return out;
    }

    vertNeighbors(v: VertId): Array<VertId> {
        const out: Array<VertId> = [];
        const es = this.vertEdges(v);
        for (let i = 0; i < es.length; i++) {
            const o = this.edges.at(es[i]).other(v);
            if (o != NO_ID) out.push(o);
        }
        return out;
    }

    isBoundaryEdge(e: EdgeId): bool {
        return this.edgeFaces(e).length == 1;
    }

    isWireEdge(e: EdgeId): bool {
        return this.edgeFaces(e).length == 0;
    }

    // Edge shared by two faces, or NO_ID.
    sharedEdge(a: FaceId, b: FaceId): EdgeId {
        const es = this.faceEdges(a);
        for (let i = 0; i < es.length; i++) {
            if (this.edgeFaces(es[i]).includes(b)) return es[i];
        }
        return NO_ID;
    }

    // The loop of face `f` whose corner is vertex `v`, or NO_ID.
    faceLoopOf(f: FaceId, v: VertId): LoopId {
        const face = this.faces.at(f);
        for (let l = face.loopStart; l < face.loopStart + face.loopLen; l++) {
            if (this.loops.at(l).vert == v) return l;
        }
        return NO_ID;
    }

    // Next / previous loop within the face ring.
    loopNext(l: LoopId): LoopId {
        const f = this.faces.at(this.loops.at(l).face);
        const i = l - f.loopStart;
        return f.loopStart + (i + 1) % f.loopLen;
    }

    loopPrev(l: LoopId): LoopId {
        const f = this.faces.at(this.loops.at(l).face);
        const i = l - f.loopStart;
        return f.loopStart + (i + f.loopLen - 1) % f.loopLen;
    }

    // The other face across `e` from `f` if the edge is manifold, or NO_ID.
    otherFace(e: EdgeId, f: FaceId): FaceId {
        const faces = this.edgeFaces(e);
        if (faces.length != 2) return NO_ID;
        if (faces[0] == f) return faces[1];
        if (faces[1] == f) return faces[0];
        return NO_ID;
    }

    // True when face `f` walks edge `e` from `e.v[0]` to `e.v[1]`.
    faceWalksEdgeForward(f: FaceId, e: EdgeId): bool {
        const edge = this.edges.at(e);
        const a = edge.v[0];
        const b = edge.v[1];
        const face = this.faces.at(f);
        for (let l = face.loopStart; l < face.loopStart + face.loopLen; l++) {
            if (this.loops.at(l).vert == a && this.loops.at(this.loopNext(l)).vert == b) return true;
        }
        return false;
    }

    // Newell's method, robust for concave and non-planar polygons.
    // (The corners are read off the loop run rather than a faceVerts()
    // array: this runs for every face on every normal refresh, and the
    // never-freeing runtime would keep one array per face per call.)
    computeFaceNormal(id: FaceId): Vec3 {
        const f = this.faces.at(id);
        const start = f.loopStart;
        const n = f.loopLen;
        let nx: f32 = 0;
        let ny: f32 = 0;
        let nz: f32 = 0;
        for (let i: u32 = 0; i < n; i++) {
            const a = this.verts.at(this.loops.at(start + i).vert).co;
            const b = this.verts.at(this.loops.at(start + (i + 1) % n).vert).co;
            nx += (a.y - b.y) * (a.z + b.z);
            ny += (a.z - b.z) * (a.x + b.x);
            nz += (a.x - b.x) * (a.y + b.y);
        }
        return Vec3(nx, ny, nz).normalizeOrZero();
    }

    recalcNormals(): void {
        this.touch();
        const fb = this.faces.idBound();
        for (let id: u32 = 0; id < fb; id++) {
            const f = this.faces.get(id);
            if (f == null) continue;
            f.normal = this.computeFaceNormal(id);
        }
    }

    // Refresh the normals of the given faces only.
    recalcFaceNormals(ids: Array<FaceId>): void {
        this.touch();
        for (let i = 0; i < ids.length; i++) {
            const id = ids[i];
            const f = this.faces.get(id);
            if (f != null) f.normal = this.computeFaceNormal(id);
        }
    }

    // Smooth vertex normal: area-weighted average of the adjacent face
    // normals (Blender's default vertex normal).
    vertNormal(v: VertId): Vec3 {
        let n = Vec3(0, 0, 0);
        const fs = this.vertFaces(v);
        for (let i = 0; i < fs.length; i++) {
            n = n + this.faces.at(fs[i]).normal * this.faceArea(fs[i]);
        }
        return n.normalizeOrZero();
    }

    // (faceArea and faceCenter walk the loop run too, see computeFaceNormal.)
    faceArea(id: FaceId): f32 {
        const f = this.faces.at(id);
        const start = f.loopStart;
        const len = f.loopLen;
        let n = Vec3(0, 0, 0);
        for (let i: u32 = 0; i < len; i++) {
            const a = this.verts.at(this.loops.at(start + i).vert).co;
            const b = this.verts.at(this.loops.at(start + (i + 1) % len).vert).co;
            n = n + a.cross(b);
        }
        return n.length() * <f32>0.5;
    }

    faceCenter(id: FaceId): Vec3 {
        const f = this.faces.at(id);
        const start = f.loopStart;
        const len = f.loopLen;
        let sum = Vec3(0, 0, 0);
        for (let l = start; l < start + len; l++) sum = sum + this.verts.at(this.loops.at(l).vert).co;
        return sum / <f32><i32>len;
    }

    facePerimeter(id: FaceId): f32 {
        const es = this.faceEdges(id);
        // The sum starts from -0.0, so an empty sum is -0.0.
        let s: f32 = -0.0;
        for (let i = 0; i < es.length; i++) s += this.edgeLength(es[i]);
        return s;
    }

    edgeLength(id: EdgeId): f32 {
        const e = this.edges.at(id);
        return this.verts.at(e.v[0]).co.distance(this.verts.at(e.v[1]).co);
    }

    edgeCenter(id: EdgeId): Vec3 {
        const e = this.edges.at(id);
        return (this.verts.at(e.v[0]).co + this.verts.at(e.v[1]).co) * <f32>0.5;
    }

    // Triangle count after triangulation (`n - 2` per face).
    triCount(): i32 {
        let n = 0;
        const fb = this.faces.idBound();
        for (let id: u32 = 0; id < fb; id++) {
            const f = this.faces.get(id);
            if (f == null) continue;
            if (f.loopLen > 2) n += <i32>(f.loopLen - 2);
        }
        return n;
    }

    // ------------------------------------------------------------- removal

    private pruneHistory(kind: ElemKind): void {
        const h = this.selectionHistory;
        let w = 0;
        for (let i = 0; i < h.length; i++) {
            const r = h[i];
            if (r.kind != kind || this.contains(kind, r.id)) {
                h[w] = r;
                w++;
            }
        }
        h.length = w;
    }

    // Delete faces (and their loops). Edges and verts stay.
    deleteFaces(ids: Array<FaceId>): void {
        this.touch();
        for (let i = 0; i < ids.length; i++) {
            const id = ids[i];
            const f = this.faces.remove(id);
            if (f != null) this.popLoops(id, f.loopStart, f.loopStart + f.loopLen);
        }
        this.pruneHistory(ElemKind.Face);
    }

    // Remove an edge (faces using it are deleted first).
    removeEdge(id: EdgeId): void {
        const faces = this.edgeFaces(id).slice(0);
        if (faces.length > 0) this.deleteFaces(faces);
        const e = this.edges.remove(id);
        if (e != null) {
            this.unlinkEdge(id, e.v[0], e.v[1]);
            this.touch();
        }
        this.pruneHistory(ElemKind.Edge);
    }

    // Remove a vertex with everything attached to it.
    removeVert(id: VertId): void {
        const edges = this.vertEdges(id).slice(0);
        for (let i = 0; i < edges.length; i++) this.removeEdge(edges[i]);
        if (this.verts.remove(id) != null) this.touch();
        this.pruneHistory(ElemKind.Vert);
    }

    // Blender's "Delete > Vertices": verts plus every edge and face on them.
    deleteVerts(ids: Array<VertId>): void {
        for (let i = 0; i < ids.length; i++) this.removeVert(ids[i]);
    }

    // Blender's "Delete > Edges": edges plus their faces, then verts that
    // were used only by those edges.
    deleteEdges(ids: Array<EdgeId>): void {
        const touched: Array<VertId> = [];
        for (let i = 0; i < ids.length; i++) {
            const e = ids[i];
            const edge = this.edges.get(e);
            if (edge != null) {
                touched.push(edge.v[0]);
                touched.push(edge.v[1]);
            }
            this.removeEdge(e);
        }
        sortU32(touched);
        dedup<u32>(touched);
        for (let i = 0; i < touched.length; i++) {
            const v = touched[i];
            if (this.verts.contains(v) && this.vertEdges(v).length == 0) this.removeVert(v);
        }
    }

    // Blender's "Delete > Faces": faces, then edges and verts no longer
    // used by any remaining face.
    deleteFacesCleanup(ids: Array<FaceId>): void {
        const edges: Array<EdgeId> = [];
        const verts: Array<VertId> = [];
        for (let i = 0; i < ids.length; i++) {
            const f = ids[i];
            if (this.faces.contains(f)) {
                const fe = this.faceEdges(f);
                for (let j = 0; j < fe.length; j++) edges.push(fe[j]);
                const fv = this.faceVerts(f);
                for (let j = 0; j < fv.length; j++) verts.push(fv[j]);
            }
        }
        this.deleteFaces(ids);
        sortU32(edges);
        dedup<u32>(edges);
        for (let i = 0; i < edges.length; i++) {
            const e = edges[i];
            if (this.edges.contains(e) && this.edgeFaces(e).length == 0) this.removeEdge(e);
        }
        sortU32(verts);
        dedup<u32>(verts);
        for (let i = 0; i < verts.length; i++) {
            const v = verts[i];
            if (this.verts.contains(v) && this.vertEdges(v).length == 0) this.removeVert(v);
        }
    }

    // Blender's "Delete > Only Edges & Faces": edges and their faces; verts stay.
    deleteEdgesKeepVerts(ids: Array<EdgeId>): void {
        for (let i = 0; i < ids.length; i++) this.removeEdge(ids[i]);
    }

    // Remove every vertex that has no edges (Blender's "loose verts").
    deleteLooseVerts(): i32 {
        const loose: Array<VertId> = [];
        const vb = this.verts.idBound();
        for (let v: u32 = 0; v < vb; v++) {
            if (this.verts.contains(v) && this.vertEdges(v).length == 0) loose.push(v);
        }
        for (let i = 0; i < loose.length; i++) this.removeVert(loose[i]);
        return loose.length;
    }

    // Remove every edge with no faces.
    deleteWireEdges(): i32 {
        const wire: Array<EdgeId> = [];
        const eb = this.edges.idBound();
        for (let e: u32 = 0; e < eb; e++) {
            if (this.edges.contains(e) && this.edgeFaces(e).length == 0) wire.push(e);
        }
        for (let i = 0; i < wire.length; i++) this.removeEdge(wire[i]);
        return wire.length;
    }

    // ---------------------------------------------------------- transforms

    // Transform every vertex by `m` and refresh normals.
    transform(m: Mat4): void {
        const vb = this.verts.idBound();
        for (let id: u32 = 0; id < vb; id++) {
            const v = this.verts.get(id);
            if (v == null) continue;
            v.co = m.transformPoint3(v.co);
        }
        // A negative determinant flips winding; recompute the normals.
        this.recalcNormals();
    }

    translate(d: Vec3): void {
        this.touch();
        const vb = this.verts.idBound();
        for (let id: u32 = 0; id < vb; id++) {
            const v = this.verts.get(id);
            if (v == null) continue;
            v.co = v.co + d;
        }
    }

    // Axis-aligned bounds in local space, or null for an empty mesh.
    bounds(): Bounds? {
        let have = false;
        let lo = Vec3(0, 0, 0);
        let hi = Vec3(0, 0, 0);
        const vb = this.verts.idBound();
        for (let id: u32 = 0; id < vb; id++) {
            const v = this.verts.get(id);
            if (v == null) continue;
            if (!have) {
                lo = v.co;
                hi = v.co;
                have = true;
            } else {
                lo = lo.min(v.co);
                hi = hi.max(v.co);
            }
        }
        return have ? Bounds.new(lo, hi) : null;
    }

    // Median point of the vertices (Blender's "median point").
    median(): Vec3 {
        if (this.verts.isEmpty()) return Vec3(0, 0, 0);
        let sum = Vec3(0, 0, 0);
        const vb = this.verts.idBound();
        for (let id: u32 = 0; id < vb; id++) {
            const v = this.verts.get(id);
            if (v == null) continue;
            sum = sum + v.co;
        }
        return sum / <f32>this.verts.len();
    }

    // Area-weighted centroid of the faces (Blender's "center of mass
    // (surface)"), falling back to the median for wire meshes.
    surfaceCentroid(): Vec3 {
        let total: f32 = 0.0;
        let acc = Vec3(0, 0, 0);
        const fb = this.faces.idBound();
        for (let id: u32 = 0; id < fb; id++) {
            if (!this.faces.contains(id)) continue;
            const a = this.faceArea(id);
            acc = acc + this.faceCenter(id) * a;
            total += a;
        }
        if (total > <f32>1e-12) return acc / total;
        return this.median();
    }

    // ---------------------------------------------------------- selection

    selectAll(select: bool): void {
        this.touch();
        const vb = this.verts.idBound();
        for (let id: u32 = 0; id < vb; id++) {
            const v = this.verts.get(id);
            if (v != null && !v.hide) v.select = select;
        }
        const eb = this.edges.idBound();
        for (let id: u32 = 0; id < eb; id++) {
            const e = this.edges.get(id);
            if (e != null && !e.hide) e.select = select;
        }
        const fb = this.faces.idBound();
        for (let id: u32 = 0; id < fb; id++) {
            const f = this.faces.get(id);
            if (f != null && !f.hide) f.select = select;
        }
        if (!select) this.selectionHistory.length = 0;
    }

    selectedCount(kind: ElemKind): i32 {
        let n = 0;
        switch (kind) {
            case ElemKind.Vert: {
                const b = this.verts.idBound();
                for (let id: u32 = 0; id < b; id++) {
                    const v = this.verts.get(id);
                    if (v != null && v.select) n++;
                }
                break;
            }
            case ElemKind.Edge: {
                const b = this.edges.idBound();
                for (let id: u32 = 0; id < b; id++) {
                    const e = this.edges.get(id);
                    if (e != null && e.select) n++;
                }
                break;
            }
            default: {
                const b = this.faces.idBound();
                for (let id: u32 = 0; id < b; id++) {
                    const f = this.faces.get(id);
                    if (f != null && f.select) n++;
                }
                break;
            }
        }
        return n;
    }

    selectedVerts(): Array<VertId> {
        const out: Array<VertId> = [];
        const b = this.verts.idBound();
        for (let id: u32 = 0; id < b; id++) {
            const v = this.verts.get(id);
            if (v != null && v.select) out.push(id);
        }
        return out;
    }

    selectedEdges(): Array<EdgeId> {
        const out: Array<EdgeId> = [];
        const b = this.edges.idBound();
        for (let id: u32 = 0; id < b; id++) {
            const e = this.edges.get(id);
            if (e != null && e.select) out.push(id);
        }
        return out;
    }

    selectedFaces(): Array<FaceId> {
        const out: Array<FaceId> = [];
        const b = this.faces.idBound();
        for (let id: u32 = 0; id < b; id++) {
            const f = this.faces.get(id);
            if (f != null && f.select) out.push(id);
        }
        return out;
    }

    contains(kind: ElemKind, id: u32): bool {
        switch (kind) {
            case ElemKind.Vert: return this.verts.contains(id);
            case ElemKind.Edge: return this.edges.contains(id);
            default: return this.faces.contains(id);
        }
    }

    idBound(kind: ElemKind): u32 {
        switch (kind) {
            case ElemKind.Vert: return this.verts.idBound();
            case ElemKind.Edge: return this.edges.idBound();
            default: return this.faces.idBound();
        }
    }

    isSelected(kind: ElemKind, id: u32): bool {
        switch (kind) {
            case ElemKind.Vert: {
                const v = this.verts.get(id);
                return v != null && v.select;
            }
            case ElemKind.Edge: {
                const e = this.edges.get(id);
                return e != null && e.select;
            }
            default: {
                const f = this.faces.get(id);
                return f != null && f.select;
            }
        }
    }

    isHidden(kind: ElemKind, id: u32): bool {
        switch (kind) {
            case ElemKind.Vert: {
                const v = this.verts.get(id);
                return v != null && v.hide;
            }
            case ElemKind.Edge: {
                const e = this.edges.get(id);
                return e != null && e.hide;
            }
            default: {
                const f = this.faces.get(id);
                return f != null && f.hide;
            }
        }
    }

    // Set one element's selection flag without flushing.
    setSelect(kind: ElemKind, id: u32, select: bool): void {
        switch (kind) {
            case ElemKind.Vert: {
                const v = this.verts.get(id);
                if (v != null) v.select = select;
                break;
            }
            case ElemKind.Edge: {
                const e = this.edges.get(id);
                if (e != null) e.select = select;
                break;
            }
            default: {
                const f = this.faces.get(id);
                if (f != null) f.select = select;
                break;
            }
        }
        this.touch();
    }

    // -------------------------------------------------------------- append

    // Append `other` (already in this mesh's local space). Returns the
    // vertex id map so callers can relate the copies to their sources.
    // Named attributes are unified by name and domain, as UV layers are: a
    // layer `other` has and this mesh does not is created here first.
    append(other: Mesh, materialOffset: u16): Map<VertId, VertId> {
        this.touch();
        for (let i = 0; i < other.attributes.length; i++) {
            const a = other.attributes[i];
            let have = false;
            for (let j = 0; j < this.attributes.length; j++) {
                const mine = this.attributes[j];
                if (mine.name == a.name && mine.domain == a.domain) {
                    have = true;
                    break;
                }
            }
            if (!have) this.addAttr(a.name, a.domain, a.ty());
        }
        const attrMap: Array<i32> = [];
        for (let j = 0; j < this.attributes.length; j++) {
            const mine = this.attributes[j];
            let pos = -1;
            for (let k = 0; k < other.attributes.length; k++) {
                const o = other.attributes[k];
                if (o.name == mine.name && o.domain == mine.domain) {
                    pos = k;
                    break;
                }
            }
            attrMap.push(pos);
        }
        const emap = new Map<EdgeId, EdgeId>();
        const fmap = new Map<FaceId, FaceId>();
        const lmap = new Map<LoopId, LoopId>();

        const vmap = new Map<VertId, VertId>();
        const ovb = other.verts.idBound();
        for (let id: u32 = 0; id < ovb; id++) {
            const v = other.verts.get(id);
            if (v == null) continue;
            const nv = this.verts.push(v.clone());
            vmap.set(id, nv);
        }
        this.growAttrs(Domain.Point);
        // Unify UV layers by name: copy what exists, zero the rest.
        const layerMap: Array<i32> = [];
        for (let j = 0; j < this.uvLayers.length; j++) {
            let pos = -1;
            for (let k = 0; k < other.uvLayers.length; k++) {
                if (other.uvLayers[k].name == this.uvLayers[j].name) {
                    pos = k;
                    break;
                }
            }
            layerMap.push(pos);
        }
        const oeb = other.edges.idBound();
        for (let id: u32 = 0; id < oeb; id++) {
            const src = other.edges.get(id);
            if (src == null) continue;
            const ne = this.addEdge(vmap.get(src.v[0]), vmap.get(src.v[1]));
            emap.set(id, ne);
            const dst = this.edges.at(ne);
            dst.select = dst.select || src.select;
            dst.hide = src.hide;
            dst.seam = dst.seam || src.seam;
            dst.sharp = dst.sharp || src.sharp;
            dst.crease = maxF32(dst.crease, src.crease);
            dst.bevelWeight = maxF32(dst.bevelWeight, src.bevelWeight);
        }
        const ofb = other.faces.idBound();
        for (let fid: u32 = 0; fid < ofb; fid++) {
            const f = other.faces.get(fid);
            if (f == null) continue;
            const verts: Array<VertId> = [];
            for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) verts.push(vmap.get(other.loops.at(l).vert));
            const nf = this.addFace(verts);
            fmap.set(fid, nf);
            const dst = this.faces.at(nf);
            dst.smooth = f.smooth;
            dst.select = f.select;
            dst.hide = f.hide;
            dst.materialIndex = <u16>(f.materialIndex + materialOffset);
            const count = min(f.loopLen, dst.loopLen);
            for (let k: u32 = 0; k < count; k++) {
                const sl = f.loopStart + k;
                const dl = dst.loopStart + k;
                lmap.set(sl, dl);
                const slp = other.loops.at(sl);
                const dlp = this.loops.at(dl);
                for (let li = 0; li < layerMap.length; li++) {
                    const si = layerMap[li];
                    if (si < 0) continue;
                    dlp.uv[li].x = slp.uv[si].x;
                    dlp.uv[li].y = slp.uv[si].y;
                    const flags: u8 = si < slp.uvFlags.length ? slp.uvFlags[si] : 0;
                    if (flags != 0) dlp.uvFlags[li] = flags;
                }
            }
        }
        for (let mine = 0; mine < attrMap.length; mine++) {
            const from = attrMap[mine];
            if (from < 0) continue;
            const domain = this.attributes[mine].domain;
            let ids: Map<u32, u32>;
            switch (domain) {
                case Domain.Point: ids = vmap; break;
                case Domain.Edge: ids = emap; break;
                case Domain.Face: ids = fmap; break;
                default: ids = lmap; break;
            }
            const srcs = ids.keys();
            for (let k = 0; k < srcs.length; k++) {
                const src = srcs[k];
                const v = other.attributes[from].get(src);
                if (v != null) this.attributes[mine].set(ids.get(src), v);
            }
        }
        return vmap;
    }

    // A new mesh holding copies of the given faces (with their verts and
    // edges) plus any loose selected edges/verts passed in. Returns the
    // mesh and the source -> copy vertex map.
    extract(faces: Array<FaceId>, edges: Array<EdgeId>, verts: Array<VertId>): Extracted {
        const out = Mesh.new();
        for (let i = 0; i < this.uvLayers.length; i++) out.uvLayers.push(this.uvLayers[i].clone());
        out.activeUv = this.activeUv;
        const vmap = new Map<VertId, VertId>();
        const wantVerts: Array<VertId> = verts.slice(0);
        for (let i = 0; i < edges.length; i++) {
            const e = this.edges.at(edges[i]);
            wantVerts.push(e.v[0]);
            wantVerts.push(e.v[1]);
        }
        for (let i = 0; i < faces.length; i++) {
            const fv = this.faceVerts(faces[i]);
            for (let j = 0; j < fv.length; j++) wantVerts.push(fv[j]);
        }
        sortU32(wantVerts);
        dedup<u32>(wantVerts);
        for (let i = 0; i < wantVerts.length; i++) {
            const v = wantVerts[i];
            const nv = out.verts.push(this.verts.at(v).clone());
            vmap.set(v, nv);
        }
        const wantEdges: Array<EdgeId> = edges.slice(0);
        for (let i = 0; i < faces.length; i++) {
            const fe = this.faceEdges(faces[i]);
            for (let j = 0; j < fe.length; j++) wantEdges.push(fe[j]);
        }
        sortU32(wantEdges);
        dedup<u32>(wantEdges);
        for (let i = 0; i < wantEdges.length; i++) {
            const src = this.edges.at(wantEdges[i]);
            const ne = out.addEdge(vmap.get(src.v[0]), vmap.get(src.v[1]));
            const dst = out.edges.at(ne);
            dst.select = src.select;
            dst.hide = src.hide;
            dst.copyMarks(src);
        }
        const sortedFaces = faces.slice(0);
        sortU32(sortedFaces);
        dedup<u32>(sortedFaces);
        for (let i = 0; i < sortedFaces.length; i++) {
            const src = this.faces.at(sortedFaces[i]);
            const ring: Array<VertId> = [];
            for (let l = src.loopStart; l < src.loopStart + src.loopLen; l++) ring.push(vmap.get(this.loops.at(l).vert));
            const nf = out.addFace(ring);
            const dst = out.faces.at(nf);
            dst.smooth = src.smooth;
            dst.select = src.select;
            dst.hide = src.hide;
            dst.materialIndex = src.materialIndex;
            const count = min(src.loopLen, dst.loopLen);
            for (let k: u32 = 0; k < count; k++) {
                const slp = this.loops.at(src.loopStart + k);
                const dlp = out.loops.at(dst.loopStart + k);
                dlp.uv = slp.uv.slice(0);
                dlp.uvFlags = slp.uvFlags.slice(0);
            }
        }
        out.touch();
        return new Extracted(out, vmap);
    }

    // ============================================================ attributes

    // Index of the layer called `name`, or -1.
    attrIndex(name: string): i32 {
        for (let i = 0; i < this.attributes.length; i++) {
            if (this.attributes[i].name == name) return i;
        }
        return -1;
    }

    attr(name: string): AttrLayer? {
        const i = this.attrIndex(name);
        return i >= 0 ? this.attributes[i] : null;
    }

    // For writing: touches the mesh, then returns the layer (or null).
    attrMut(name: string): AttrLayer? {
        this.touch();
        const i = this.attrIndex(name);
        return i >= 0 ? this.attributes[i] : null;
    }

    attrNames(): Array<string> {
        const out: Array<string> = [];
        for (let i = 0; i < this.attributes.length; i++) out.push(this.attributes[i].name);
        return out;
    }

    // The number of slots a domain's array needs: the element id bound, so
    // an id is a direct index.
    domainLen(domain: Domain): i32 {
        switch (domain) {
            case Domain.Point: return <i32>this.verts.idBound();
            case Domain.Edge: return <i32>this.edges.idBound();
            case Domain.Face: return <i32>this.faces.idBound();
            default: return <i32>this.loops.idBound();
        }
    }

    // Add a layer of zeros. Replaces one of the same name, as Blender's
    // attribute panel does. Returns its index.
    addAttr(name: string, domain: Domain, ty: AttrType): i32 {
        this.touch();
        const data = AttrData.new(ty, this.domainLen(domain));
        const layer = AttrLayer.new(name, domain, data);
        const i = this.attrIndex(name);
        if (i >= 0) {
            this.attributes[i] = layer;
            return i;
        }
        this.attributes.push(layer);
        return this.attributes.length - 1;
    }

    removeAttr(name: string): bool {
        const i = this.attrIndex(name);
        if (i < 0) return false;
        this.touch();
        this.attributes.splice(i, 1);
        return true;
    }

    // Grow every layer of `domain` so a newly pushed element has a slot.
    // Called by the kernel after each push, so no operator has to know
    // attributes exist.
    growAttrs(domain: Domain): void {
        const len = this.domainLen(domain);
        for (let i = 0; i < this.attributes.length; i++) {
            const a = this.attributes[i];
            if (a.domain == domain && a.data.len() < len) a.data.resize(len);
        }
    }

    // One element's value, converted from the layer's domain to the
    // element's when they differ (see attrOn).
    attrValue(name: string, kind: ElemKind, id: u32): AttrValue? {
        const i = this.attrIndex(name);
        if (i < 0) return null;
        return this.attrOn(i, kind, id);
    }

    // As above, by layer index. Going down (face to point) averages over the
    // elements that touch it; going up (point to face) averages the corners.
    attrOn(layer: i32, kind: ElemKind, id: u32): AttrValue? {
        if (layer < 0 || layer >= this.attributes.length) return null;
        const a = this.attributes[layer];
        if (a.domain == Domain.of(kind)) return a.get(id);
        let verts: Array<VertId>;
        switch (kind) {
            case ElemKind.Vert: {
                verts = [id];
                break;
            }
            case ElemKind.Edge: {
                const e = this.edges.get(id);
                if (e == null) return null;
                verts = [e.v[0], e.v[1]];
                break;
            }
            default: {
                verts = this.faceVerts(id);
                break;
            }
        }
        const values: Array<AttrValue> = [];
        switch (a.domain) {
            case Domain.Point: {
                for (let i = 0; i < verts.length; i++) {
                    const x = a.get(verts[i]);
                    if (x != null) values.push(x);
                }
                break;
            }
            case Domain.Edge: {
                let edges: Array<EdgeId>;
                switch (kind) {
                    case ElemKind.Vert: edges = this.vertEdges(id).slice(0); break;
                    case ElemKind.Edge: edges = [id]; break;
                    default: edges = this.faceEdges(id); break;
                }
                for (let i = 0; i < edges.length; i++) {
                    const x = a.get(edges[i]);
                    if (x != null) values.push(x);
                }
                break;
            }
            case Domain.Face: {
                let faces: Array<FaceId>;
                switch (kind) {
                    case ElemKind.Vert: faces = this.vertFaces(id); break;
                    case ElemKind.Edge: faces = this.edgeFaces(id).slice(0); break;
                    default: faces = [id]; break;
                }
                for (let i = 0; i < faces.length; i++) {
                    const x = a.get(faces[i]);
                    if (x != null) values.push(x);
                }
                break;
            }
            default: {
                let loops: Array<LoopId>;
                switch (kind) {
                    case ElemKind.Vert: {
                        loops = this.vertLoops(id);
                        break;
                    }
                    case ElemKind.Edge: {
                        loops = [];
                        const fs = this.edgeFaces(id);
                        for (let i = 0; i < fs.length; i++) {
                            const f = this.faces.at(fs[i]);
                            for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
                                if (this.loops.at(l).edge == id) loops.push(l);
                            }
                        }
                        break;
                    }
                    default: {
                        const f = this.faces.get(id);
                        if (f == null) return null;
                        loops = f.loops();
                        break;
                    }
                }
                for (let i = 0; i < loops.length; i++) {
                    const x = a.get(loops[i]);
                    if (x != null) values.push(x);
                }
                break;
            }
        }
        return attrMean(values);
    }

    // Every loop that starts at `v`, for corner-domain conversion.
    private vertLoops(v: VertId): Array<LoopId> {
        const out: Array<LoopId> = [];
        const fs = this.vertFaces(v);
        for (let i = 0; i < fs.length; i++) {
            const f = this.faces.at(fs[i]);
            for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
                if (this.loops.at(l).vert == v) out.push(l);
            }
        }
        return out;
    }

    // Copy every attribute of `domain` from one element to another.
    copyAttrs(domain: Domain, from: u32, to: u32): void {
        for (let i = 0; i < this.attributes.length; i++) {
            const a = this.attributes[i];
            if (a.domain != domain) continue;
            const v = a.get(from);
            if (v != null) a.set(to, v);
        }
    }

    // Give a new point the weighted mean of the sources (`srcVerts[i]`
    // weighted by `srcWeights[i]`), as addVertFrom does for group weights.
    interpolatePointAttrs(to: VertId, srcVerts: Array<VertId>, srcWeights: Array<f32>): void {
        let any = false;
        for (let i = 0; i < this.attributes.length; i++) {
            if (this.attributes[i].domain == Domain.Point) {
                any = true;
                break;
            }
        }
        if (!any) return;
        const n = min(srcVerts.length, srcWeights.length);
        // The sum starts from -0.0, so an empty sum is -0.0.
        let total: f32 = -0.0;
        for (let i = 0; i < n; i++) total += srcWeights[i];
        if (total == 0.0) return;
        for (let i = 0; i < this.attributes.length; i++) {
            const a = this.attributes[i];
            if (a.domain != Domain.Point) continue;
            let acc = Vec3(0, 0, 0);
            let num: f64 = 0.0;
            for (let s = 0; s < n; s++) {
                const w = srcWeights[s];
                const x = a.get(srcVerts[s]);
                if (x == null) continue;
                if (x.kind == AttrValueKind.Vec3) acc = acc + x.v * (w / total);
                else num += x.n * <f64>(w / total);
            }
            a.set(to, a.ty() == AttrType.Vec3 ? AttrValue.vec3(acc) : AttrValue.num(num));
        }
    }

    // Convert a layer to another domain in place, averaging as attrOn does.
    convertAttr(name: string, to: Domain): bool {
        const i = this.attrIndex(name);
        if (i < 0) return false;
        if (this.attributes[i].domain == to) return true;
        const ty = this.attributes[i].ty();
        const len = this.domainLen(to);
        const data = AttrData.new(ty, len);
        for (let id = 0; id < len; id++) {
            const v = this.attrInDomain(i, to, <u32>id);
            if (v != null) data.set(id, v);
        }
        this.attributes[i].domain = to;
        this.attributes[i].data = data;
        this.touch();
        return true;
    }

    // The value layer `i` would have at element `id` of `domain`. Unlike
    // attrOn this takes a domain rather than a selectable kind, so it also
    // reaches corners.
    private attrInDomain(i: i32, domain: Domain, id: u32): AttrValue? {
        if (i < 0 || i >= this.attributes.length) return null;
        const a = this.attributes[i];
        if (a.domain == domain) return a.get(id);
        switch (domain) {
            case Domain.Point: return this.attrOn(i, ElemKind.Vert, id);
            case Domain.Edge: return this.attrOn(i, ElemKind.Edge, id);
            case Domain.Face: return this.attrOn(i, ElemKind.Face, id);
            default: {
                // A corner takes the value of its own vertex, edge or face.
                const l = this.loops.get(id);
                if (l == null) return null;
                switch (a.domain) {
                    case Domain.Point: return a.get(l.vert);
                    case Domain.Edge: return a.get(l.edge);
                    case Domain.Face: return a.get(l.face);
                    default: return a.get(id);
                }
            }
        }
    }

    // ============================================================ validation

    // Check every invariant the kernel relies on. Returns the first
    // violation as the error message.
    validate(): Result<bool> {
        return validateMesh(this);
    }

    // Panics when an invariant is broken while DEBUG_ASSERTIONS is on; a
    // no-op otherwise. Operators call this before returning.
    debugValidate(): void {
        if (!DEBUG_ASSERTIONS) return;
        const r = this.validate();
        if (!r.ok) panic("mesh invariant violated: " + r.err);
    }

    // ======================================================= Euler operators
    // (code in ./euler)

    splitEdge(e: EdgeId, t: f32): SplitEdgeResult { return eulerSplitEdge(this, e, t); }
    splitFace(f: FaceId, a: VertId, b: VertId): Result<SplitFaceResult> { return eulerSplitFace(this, f, a, b); }
    joinFaces(f1: FaceId, f2: FaceId): Result<FaceId> { return eulerJoinFaces(this, f1, f2); }
    // `co` is the merged vert's position, used only when `hasCo`.
    collapseEdge(e: EdgeId, co: Vec3, hasCo: bool): VertId { return eulerCollapseEdge(this, e, co, hasCo); }
    mergeVerts(target: VertId, others: Array<VertId>): void { eulerMergeVerts(this, target, others); }
    // Ok(NO_ID) when no joined face results.
    dissolveEdge(e: EdgeId): Result<FaceId> { return eulerDissolveEdge(this, e); }
    dissolveVert(v: VertId): Result<bool> { return eulerDissolveVert(this, v); }
    mergeByDistance(verts: Array<VertId>, dist: f32): i32 { return eulerMergeByDistance(this, verts, dist); }

    // =============================================================== queries
    // (code in ./query)

    edgeFaceCounts(): Map<EdgeId, i32> { return query.edgeFaceCounts(this); }
    isClosedManifold(): bool { return query.isClosedManifold(this); }
    eulerCharacteristic(): i64 { return query.eulerCharacteristic(this); }
    degenerateFaces(): Array<FaceId> { return query.degenerateFaces(this); }
    degenerateFaceCount(): i32 { return query.degenerateFaceCount(this); }
    ngonCount(): i32 { return query.ngonCount(this); }
    ngons(): Array<FaceId> { return query.ngons(this); }
    nonManifoldEdges(): Array<EdgeId> { return query.nonManifoldEdges(this); }
    boundaryEdges(): Array<EdgeId> { return query.boundaryEdges(this); }
    wireEdges(): Array<EdgeId> { return query.wireEdges(this); }
    looseVerts(): Array<VertId> { return query.looseVerts(this); }
    nonManifoldVerts(): Array<VertId> { return query.nonManifoldVerts(this); }
    inconsistentNormalEdges(): Array<EdgeId> { return query.inconsistentNormalEdges(this); }
    duplicateVertGroups(eps: f32): Array<Array<VertId>> { return query.duplicateVertGroups(this, eps); }
    connectedComponents(): Array<Array<VertId>> { return query.connectedComponents(this); }
    linkedFaces(start: FaceId, cross: (e: EdgeId) => bool): Array<FaceId> { return query.linkedFaces(this, start, cross); }
    // NaN unless the edge has exactly two faces.
    edgeFaceAngle(e: EdgeId): f32 { return query.edgeFaceAngle(this, e); }
    // NO_ID when there is none.
    oppositeEdgeInQuad(f: FaceId, e: EdgeId): EdgeId { return query.oppositeEdgeInQuad(this, f, e); }

    // ============================================================= selection
    // (code in ./selection)

    flushSelection(kind: ElemKind): void { selection.flushSelection(this, kind); }
    // The element kind a select mode works on.
    static primaryKind(mode: SelectMode): ElemKind { return selection.primaryKind(mode); }
    convertSelectMode(from: SelectMode, to: SelectMode): void { selection.convertSelectMode(this, from, to); }
    selectIds(kind: ElemKind, ids: Array<u32>, select: bool): void { selection.selectIds(this, kind, ids, select); }
    pushHistory(kind: ElemKind, id: u32): void { selection.pushHistory(this, kind, id); }
    // null when there is none; the result is a copy of the history entry.
    activeElement(): ElemRef? { return selection.activeElement(this); }
    // NO_ID when there is none.
    activeOfKind(kind: ElemKind): u32 { return selection.activeOfKind(this, kind); }
    activePosition(): ActivePosition? { return selection.activePosition(this); }
    // Counts of the verts, edges and faces hidden.
    hideSelected(unselected: bool): ElementCounts { return selection.hideSelected(this, unselected); }
    reveal(select: bool): ElementCounts { return selection.reveal(this, select); }
    selectionSet(): SelectionSet { return selection.selectionSet(this); }
    applySelectionSet(set: SelectionSet): i32 { return selection.applySelectionSet(this, set); }
    selectedIds(kind: ElemKind): Array<u32> { return selection.selectedIds(this, kind); }
    setSelection(kind: ElemKind, ids: Array<u32>): void { selection.setSelection(this, kind, ids); }

    // ============================================================ shape keys
    // (code in ./shapekey. Key indices are i32, -1 = none.)

    hasShapeKeys(): bool { return hasShapeKeysFn(this); }
    findShapeKey(name: string): i32 { return findShapeKeyFn(this, name); }
    // The active shape key (named ...Ref because the field is `activeShapeKey`).
    activeShapeKeyRef(): ShapeKey? { return activeShapeKeyOfFn(this); }
    shapeKeyCo(key: i32, v: VertId): Vec3 { return shapeKeyCoFn(this, key, v); }
    extendShapeKeys(): void { extendShapeKeysFn(this); }
    uniqueShapeKeyName(base: string): string { return uniqueShapeKeyNameFn(this, base); }
    shapeKeyAdd(name: string, fromMix: bool): i32 { return shapeKeyAddFn(this, name, fromMix); }
    shapeKeyRemove(index: i32): void { shapeKeyRemoveFn(this, index); }
    hasShapeKeyMix(): bool { return hasShapeKeyMixFn(this); }
    shapeKeyMix(): Array<Vec3> { return shapeKeyMixFn(this); }
    setAllPositions(positions: Array<Vec3>): void { setAllPositionsFn(this, positions); }
    withShapeKeyMix(): Mesh { return withShapeKeyMixFn(this); }
    withShapeKey(key: i32): Mesh { return withShapeKeyFn(this, key); }
    storeActiveShapeKey(): void { storeActiveShapeKeyFn(this); }
    loadShapeKey(key: i32): void { loadShapeKeyFn(this, key); }
    propagateBasisChange(): void { propagateBasisChangeFn(this); }

    // ========================================================= triangulation
    // (code in ./triangulate)

    triangulateFace(id: FaceId): Array<StaticArray<LoopId>> { return triangulateFaceFn(this, id); }

    // =================================================================== UVs
    // (code in ./uv. Layer indices are i32, -1 = none.)


    uvLayerIndex(name: string?): i32 { return uvLayerIndexFn(this, name); }
    uvLayerNames(): Array<string> { return uvLayerNamesFn(this); }
    uniqueUvLayerName(base: string): string { return uniqueUvLayerNameFn(this, base); }
    addUvLayer(name: string): i32 { return addUvLayerFn(this, name); }
    removeUvLayer(index: i32): void { removeUvLayerFn(this, index); }
    uv(l: LoopId, layer: i32): Vec2 { return uvOfFn(this, l, layer); }
    setUv(l: LoopId, layer: i32, uv: Vec2): void { setUvFn(this, l, layer, uv); }
    uvFlag(l: LoopId, layer: i32, flag: u8): bool { return uvFlagFn(this, l, layer, flag); }
    setUvFlag(l: LoopId, layer: i32, flag: u8, on: bool): void { setUvFlagFn(this, l, layer, flag, on); }
    uvSelected(l: LoopId, layer: i32): bool { return uvSelectedFn(this, l, layer); }
    uvPinned(l: LoopId, layer: i32): bool { return uvPinnedFn(this, l, layer); }
    uvFaces(): Array<FaceId> { return uvFacesFn(this); }
    uvSelectedLoops(faces: Array<FaceId>, layer: i32): Array<LoopId> { return uvSelectedLoopsFn(this, faces, layer); }
    uvSelectFaces(faces: Array<FaceId>, layer: i32, on: bool): void { uvSelectFacesFn(this, faces, layer, on); }
    uvSelectSticky(faces: Array<FaceId>, layer: i32): void { uvSelectStickyFn(this, faces, layer); }
    uvIslands(faces: Array<FaceId>, join: Join): Array<Array<FaceId>> { return uvIslandsFn(this, faces, join); }
    uvVertices(faces: Array<FaceId>, join: Join): UvVertices { return uvVerticesFn(this, faces, join); }
    uvBounds(loops: Array<LoopId>, layer: i32): UvBounds? { return uvBoundsFn(this, loops, layer); }
    uvFaceArea(f: FaceId, layer: i32): f32 { return uvFaceAreaFn(this, f, layer); }
}
