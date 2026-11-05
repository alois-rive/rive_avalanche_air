// Merge vertices (M) and remove doubles
// (`merge --by-distance`).

import { Vec3, VEC3_ZERO } from "../../../base/vecmath";
import { Result, dedup } from "../../../base/util";
import { CoreError } from "../../../base/error";
import { OpReport } from "../../../base/report";
import { Mesh, ElemKind, FaceId, VertId, NO_ID } from "../mesh/mod";
import { Scene } from "../scene";
import { editObject, editMesh, meshReport, nothingSelected } from "./mod";

// The `MergeAt` tags.
export enum MergeAtKind {
    Center,
    First,
    Last,
    Cursor,
    Collapse,
    // Remove doubles: weld selected vertices closer than the distance.
    ByDistance,
}

// Where the selected vertices end up (Blender's merge menu). `ByDistance`
// carries `distance`.
export class MergeAt {
    kind: MergeAtKind = MergeAtKind.Center;
    distance: f32 = 0;

    static of(kind: MergeAtKind): MergeAt {
        const m = new MergeAt();
        m.kind = kind;
        return m;
    }

    static byDistance(d: f32): MergeAt {
        const m = new MergeAt();
        m.kind = MergeAtKind.ByDistance;
        m.distance = d;
        return m;
    }

    // null when `s` names no merge target.
    static parse(s: string): MergeAt? {
        if (s == "center") return MergeAt.of(MergeAtKind.Center);
        if (s == "first") return MergeAt.of(MergeAtKind.First);
        if (s == "last") return MergeAt.of(MergeAtKind.Last);
        if (s == "cursor") return MergeAt.of(MergeAtKind.Cursor);
        if (s == "collapse") return MergeAt.of(MergeAtKind.Collapse);
        return null;
    }

    name(): string {
        switch (this.kind) {
            case MergeAtKind.Center: return "center";
            case MergeAtKind.First: return "first";
            case MergeAtKind.Last: return "last";
            case MergeAtKind.Cursor: return "cursor";
            case MergeAtKind.Collapse: return "collapse";
            default: return "distance";
        }
    }

    clone(): MergeAt {
        const m = new MergeAt();
        m.kind = this.kind;
        m.distance = this.distance;
        return m;
    }

    equals(o: MergeAt): bool {
        if (this.kind != o.kind) return false;
        return this.kind != MergeAtKind.ByDistance || this.distance == o.distance;
    }
}

function bad(msg: string): CoreError {
    return CoreError.invalidArgument(msg);
}

function sortIds(a: Array<u32>): void {
    a.sort((x: u32, y: u32): i32 => (x < y ? -1 : x > y ? 1 : 0));
}

// "1 vertex" / "n vertices" (the irregular plural `plural` cannot form).
export function vertices(n: i64): string {
    if (n == 1) return "1 vertex";
    return n.toString() + " vertices";
}

// The surviving vert and the number of verts removed by `mergeVertsAt`.
export class MergedAt {
    target: VertId = 0;
    removed: i32 = 0;
}

// Merge `verts` into one vertex placed at `co`. The lowest id survives
// unless `keep` (NO_ID = none) names the survivor. Returns the survivor and
// how many vertices were removed.
export function mergeVertsAt(mesh: Mesh, verts: Array<VertId>, co: Vec3, keep: VertId = NO_ID): MergedAt {
    const ids = verts.slice(0);
    sortIds(ids);
    dedup<u32>(ids);
    const target = keep != NO_ID && ids.includes(keep) ? keep : ids[0];
    const others: Array<VertId> = [];
    for (let i = 0; i < ids.length; i++) {
        if (ids[i] != target) others.push(ids[i]);
    }
    mesh.mergeVerts(target, others);
    mesh.verts.at(target).co = co;
    const faces = mesh.vertFaces(target);
    mesh.recalcFaceNormals(faces);
    const r = new MergedAt();
    r.target = target;
    r.removed = others.length;
    return r;
}

// Groups of selected vertices connected through edges between selected
// vertices (what `collapse` merges separately). Each group is sorted.
export function selectedGroups(mesh: Mesh, verts: Array<VertId>): Array<Array<VertId>> {
    const set = new Set<VertId>();
    for (let i = 0; i < verts.length; i++) set.add(verts[i]);
    const seen = new Set<VertId>();
    const sorted = verts.slice(0);
    sortIds(sorted);
    const out: Array<Array<VertId>> = [];
    for (let s = 0; s < sorted.length; s++) {
        const start = sorted[s];
        if (seen.has(start)) continue;
        seen.add(start);
        const group: Array<VertId> = [start];
        const queue: Array<VertId> = [start];
        let head = 0;
        while (head < queue.length) {
            const v = queue[head++];
            const ns = mesh.vertNeighbors(v);
            for (let k = 0; k < ns.length; k++) {
                const n = ns[k];
                if (set.has(n) && !seen.has(n)) {
                    seen.add(n);
                    group.push(n);
                    queue.push(n);
                }
            }
        }
        sortIds(group);
        out.push(group);
    }
    return out;
}

function median(mesh: Mesh, verts: Array<VertId>): Vec3 {
    let sum = VEC3_ZERO;
    for (let i = 0; i < verts.length; i++) sum = sum + mesh.verts.at(verts[i]).co;
    return sum / <f32>(verts.length > 1 ? verts.length : 1);
}

// First / last selected vertex from the selection history.
function historyVert(mesh: Mesh, verts: Array<VertId>, last: bool): Result<VertId> {
    let found: VertId = NO_ID;
    const h = mesh.selectionHistory;
    for (let i = 0; i < h.length; i++) {
        if (h[i].kind == ElemKind.Vert && verts.includes(h[i].id)) {
            found = h[i].id;
            if (!last) break;
        }
    }
    if (found == NO_ID) {
        return Result.failWith<VertId>(
            bad(
                "merge at " +
                    (last ? "last" : "first") +
                    " needs a selection history: select the verts one at a time so the history knows which is first/last",
            ),
        );
    }
    return Result.okv<VertId>(found);
}

// Mesh-level merge; `cursor` is the 3D cursor in the mesh's local space.
// Returns how many vertices were removed.
export function mergeMesh(mesh: Mesh, at: MergeAt, cursor: Vec3): Result<i32> {
    const verts = mesh.selectedVerts();
    if (verts.length == 0) return Result.failWith<i32>(nothingSelected(ElemKind.Vert));
    let removed = 0;
    if (at.kind == MergeAtKind.ByDistance) {
        const d = at.distance;
        if (d < 0.0) return Result.failWith<i32>(bad("--by-distance must be zero or positive"));
        removed = mesh.mergeByDistance(verts, d);
    } else if (at.kind == MergeAtKind.Collapse) {
        const groups = selectedGroups(mesh, verts);
        for (let g = 0; g < groups.length; g++) {
            const group = groups[g];
            if (group.length < 2) continue;
            const co = median(mesh, group);
            removed += mergeVertsAt(mesh, group, co, NO_ID).removed;
        }
    } else {
        if (verts.length < 2) return Result.failWith<i32>(bad("merge needs at least two selected vertices"));
        let co = VEC3_ZERO;
        let keep: VertId = NO_ID;
        switch (at.kind) {
            case MergeAtKind.Center: {
                co = median(mesh, verts);
                break;
            }
            case MergeAtKind.Cursor: {
                co = cursor;
                break;
            }
            case MergeAtKind.First:
            case MergeAtKind.Last: {
                const r = historyVert(mesh, verts, at.kind == MergeAtKind.Last);
                if (!r.ok) return r.forward<i32>();
                co = mesh.verts.at(r.value).co;
                keep = r.value;
                break;
            }
            default:
                break;
        }
        removed = mergeVertsAt(mesh, verts, co, keep).removed;
    }
    removeDuplicateFaces(mesh);
    mesh.flushSelection(ElemKind.Vert);
    mesh.debugValidate();
    return Result.okv<i32>(removed);
}

// Welding can leave two faces over the same vertices (two coincident
// cubes merged into one); like Blender, keep only the first.
function removeDuplicateFaces(mesh: Mesh): i32 {
    // Keyed by the joined sorted ring.
    const seen = new Set<string>();
    const doubles: Array<FaceId> = [];
    const ids: Array<FaceId> = [];
    const sel = mesh.selectedVerts();
    for (let i = 0; i < sel.length; i++) {
        const fs = mesh.vertFaces(sel[i]);
        for (let k = 0; k < fs.length; k++) ids.push(fs[k]);
    }
    sortIds(ids);
    dedup<u32>(ids);
    for (let i = 0; i < ids.length; i++) {
        const f = ids[i];
        const ring = mesh.faceVerts(f);
        sortIds(ring);
        const key = ring.join(",");
        if (seen.has(key)) {
            doubles.push(f);
        } else {
            seen.add(key);
        }
    }
    const n = doubles.length;
    if (n > 0) mesh.deleteFaces(doubles);
    return n;
}

export function merge(scene: Scene, at: MergeAt): Result<OpReport> {
    const ro = editObject(scene, "merge");
    if (!ro.ok) return ro.forward<OpReport>();
    const id = ro.value;
    const cursor = scene.worldMatrix(id).inverse().transformPoint3(scene.cursor.location);
    const rm = editMesh(scene, "merge");
    if (!rm.ok) return rm.forward<OpReport>();
    const mesh = rm.value;
    const selected = mesh.selectedCount(ElemKind.Vert);
    const rr = mergeMesh(mesh, at, cursor);
    if (!rr.ok) return rr.forward<OpReport>();
    const removed = rr.value;
    let msg: string;
    if (at.kind == MergeAtKind.ByDistance) {
        msg = "Removed " + vertices(removed);
    } else if (at.kind == MergeAtKind.Collapse) {
        msg = "Collapsed " + vertices(selected) + " into " + vertices(selected - removed);
    } else {
        msg = "Merged " + vertices(selected) + " at " + at.name();
    }
    return Result.okv<OpReport>(meshReport(msg, mesh));
}
