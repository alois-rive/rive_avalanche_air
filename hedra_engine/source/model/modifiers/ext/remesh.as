// Remesh (Blender: Generate > Remesh): throw the topology away and rebuild
// the surface on a uniform grid.
//
// `blocks` is the voxel surface itself — every cell whose centre is inside
// the original gets its outward-facing walls, which is Blender's blocky
// mode exactly. `smooth` and `sharp` run the same voxelization and then
// relax the result, which is what Blender's octree modes amount to once
// the dual contouring is gone. `voxel` is the same grid addressed by an
// edge length rather than an octree depth.
//
// Every mode needs a closed input: the grid is filled by an inside test,
// and "inside" means nothing on an open surface.

import { Vec3, IVec3 } from "../../../../base/vecmath";
import { Result, roundF32, f32ToU32 } from "../../../../base/util";
import { Mesh, VertId, FaceId } from "../../mesh/mod";
import { ModifierEnv, assignMesh } from "../mod";
import { Bvh } from "./geom/bvh";
import { Tri } from "./geom/tri";
import { PropDef, PropKind, Props, prop } from "./props";
import { collapseTo, NO_AXIS } from "./decimate";

export const PROPS: Array<PropDef> = [
    prop(
        "mode",
        PropKind.Choice(["blocks", "smooth", "sharp", "voxel"]),
        "blocks",
        "blocks keeps the cubes, smooth and sharp relax them, voxel sizes the grid by length",
    ),
    prop(
        "octree-depth",
        PropKind.IntRange(1, 8),
        "4",
        "outside voxel mode, the grid is 2^depth cells across the longest side",
    ),
    prop("voxel-size", PropKind.Float(), "0.1", "in voxel mode, the edge length of one cell"),
    prop(
        "adaptivity",
        PropKind.Range(0.0, 1.0),
        "0",
        "collapse the result afterwards, keeping this fraction of the faces (0 = keep all)",
    ),
    prop("smooth-shading", PropKind.Bool(), "false", "mark the faces it makes as smooth-shaded"),
    prop("remove-disconnected", PropKind.Bool(), "true", "keep only the largest connected piece"),
];

// A hard ceiling on the grid: 128^3 cells is already a two-million-cell
// inside test, and anything past it is a hang rather than a result.
export const MAX_CELLS: u64 = 128 * 128 * 128;

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const warnings: Array<string> = [];
    if (mesh.faces.isEmpty()) {
        return Result.fail<Array<string>>("remesh needs a closed surface, and this mesh has no faces");
    }
    if (!mesh.isClosedManifold()) {
        warnings.push(
            "the mesh is not a closed manifold, so the inside test may fill the wrong cells " +
                "(`inspect check` lists the non-manifold edges)",
        );
    }
    const bounds = mesh.bounds();
    if (bounds == null) {
        return Result.okv<Array<string>>(warnings);
    }
    const min = bounds.lo;
    const max = bounds.hi;
    const size = max - min;
    const longest = size.maxElement();
    if (longest <= <f32>0.0) {
        return Result.okv<Array<string>>(warnings);
    }
    const mode = p.str("mode");
    let cell: f32;
    if (mode == "voxel") {
        const v = p.f32("voxel-size");
        if (v <= <f32>0.0) {
            return Result.fail<Array<string>>("voxel-size must be greater than zero");
        }
        cell = v;
    } else {
        let depth = p.u32("octree-depth");
        if (depth < 1) depth = 1;
        if (depth > 8) depth = 8;
        cell = longest / <f32>(<u32>1 << depth);
    }
    const dims = ((size / cell).ceil() + Vec3.splat(2.0)).asIVec3().max(IVec3.splat(1));
    const cells = <u64>dims.x * <u64>dims.y * <u64>dims.z;
    if (cells > MAX_CELLS) {
        return Result.fail<Array<string>>(
            "that grid would be " +
                dims.x.toString() +
                "x" +
                dims.y.toString() +
                "x" +
                dims.z.toString() +
                " = " +
                cells.toString() +
                " cells; lower --octree-depth or raise " +
                "--voxel-size (the limit is " +
                MAX_CELLS.toString() +
                ")",
        );
    }

    const out = voxelize(mesh, min - Vec3.splat(cell), dims, cell, p.bool("smooth-shading"));
    if (out.faces.isEmpty()) {
        warnings.push(
            "the grid is coarser than the shape, so no cell fell inside it; " +
                "raise --octree-depth or lower --voxel-size",
        );
        return Result.okv<Array<string>>(warnings);
    }
    assignMesh(mesh, out);

    if (p.bool("remove-disconnected")) {
        const dropped = keepLargestIsland(mesh);
        if (dropped > 0) {
            warnings.push("dropped " + dropped.toString() + " disconnected faces");
        }
    }
    if (mode == "smooth" || mode == "sharp") {
        // `sharp` relaxes less, which is the difference the names carry
        // in Blender: sharp keeps the creases the grid produced.
        const repeat = mode == "smooth" ? 3 : 1;
        for (let i = 0; i < repeat; i++) {
            relax(mesh, 0.5);
        }
    }
    const adaptivity = p.f32("adaptivity");
    if (adaptivity > <f32>0.0) {
        const target = <i32>f32ToU32(roundF32(<f32>mesh.faces.len() * (<f32>1.0 - adaptivity)));
        collapseTo(mesh, target > 4 ? target : 4, NO_AXIS, (v: VertId): f32 => <f32>0.0);
    }
    mesh.recalcNormals();
    mesh.touch();
    return Result.okv<Array<string>>(warnings);
}

// The six walls of a cell: (neighbour direction, four corner offsets), in
// the order -x, +x, -y, +y, -z, +z. Three ints per IVec3.
const FACE_DIRS: StaticArray<i32> = [-1, 0, 0, 1, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, -1, 0, 0, 1];
const FACE_QUADS: StaticArray<i32> = [
    // -x
    0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 1, 0,
    // +x
    1, 0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1,
    // -y
    0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1,
    // +y
    0, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0,
    // -z
    0, 0, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0,
    // +z
    0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1,
];

// Corners are shared between neighbouring cells, so a corner is added
// once and looked up by its integer coordinate.
class Corners {
    map: Map<IVec3, VertId> = new Map<IVec3, VertId>();
    origin: Vec3;
    cell: f32;
    constructor(origin: Vec3, cell: f32) {
        this.origin = origin;
        this.cell = cell;
    }
    corner(out: Mesh, c: IVec3): VertId {
        if (this.map.has(c)) return this.map.get(c);
        const v = out.addVert(this.origin + c.asVec3() * this.cell);
        this.map.set(c, v);
        return v;
    }
}

function cellIndex(c: IVec3, dims: IVec3): i32 {
    return (c.z * dims.y + c.y) * dims.x + c.x;
}

// Every cell whose centre is inside gets the walls it does not share with
// another filled cell.
function voxelize(mesh: Mesh, origin: Vec3, dims: IVec3, cell: f32, smooth: bool): Mesh {
    const tris: Array<Tri> = [];
    const fids = mesh.faces.ids();
    for (let i = 0; i < fids.length; i++) {
        const f = fids[i];
        const ts = mesh.triangulateFace(f);
        for (let k = 0; k < ts.length; k++) {
            const t = ts[k];
            tris.push(
                Tri.new(
                    mesh.verts.at(mesh.loops.at(t[0]).vert).co,
                    mesh.verts.at(mesh.loops.at(t[1]).vert).co,
                    mesh.verts.at(mesh.loops.at(t[2]).vert).co,
                    f,
                ),
            );
        }
    }
    const bvh = Bvh.build(tris);
    const filled = new Uint8Array(dims.x * dims.y * dims.z);
    for (let z = 0; z < dims.z; z++) {
        for (let y = 0; y < dims.y; y++) {
            for (let x = 0; x < dims.x; x++) {
                const c = IVec3(x, y, z);
                const centre = origin + (c.asVec3() + Vec3.splat(0.5)) * cell;
                filled[cellIndex(c, dims)] = bvh.inside(centre) ? 1 : 0;
            }
        }
    }

    const out = Mesh.new();
    const corners = new Corners(origin, cell);
    for (let z = 0; z < dims.z; z++) {
        for (let y = 0; y < dims.y; y++) {
            for (let x = 0; x < dims.x; x++) {
                const c = IVec3(x, y, z);
                if (filled[cellIndex(c, dims)] == 0) {
                    continue;
                }
                for (let d = 0; d < 6; d++) {
                    const n = c + IVec3(FACE_DIRS[d * 3], FACE_DIRS[d * 3 + 1], FACE_DIRS[d * 3 + 2]);
                    const insideGrid =
                        n.x >= 0 && n.y >= 0 && n.z >= 0 && n.x < dims.x && n.y < dims.y && n.z < dims.z;
                    if (insideGrid && filled[cellIndex(n, dims)] != 0) {
                        continue;
                    }
                    const verts: Array<VertId> = [];
                    for (let k = 0; k < 4; k++) {
                        const o = d * 12 + k * 3;
                        verts.push(corners.corner(out, c + IVec3(FACE_QUADS[o], FACE_QUADS[o + 1], FACE_QUADS[o + 2])));
                    }
                    const f = out.addFace(verts);
                    out.faces.at(f).smooth = smooth;
                }
            }
        }
    }
    out.deleteLooseVerts();
    out.recalcNormals();
    return out;
}

function sameIds(a: Array<FaceId>, b: Array<FaceId>): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// Keep only the largest connected group of faces. Returns how many faces
// were dropped.
export function keepLargestIsland(mesh: Mesh): i32 {
    const seen = new Set<u32>();
    let best: Array<u32> = [];
    const all: Array<Array<u32>> = [];
    const fids = mesh.faces.ids();
    for (let i = 0; i < fids.length; i++) {
        const f = fids[i];
        if (seen.has(f)) {
            continue;
        }
        const group = mesh.linkedFaces(f, (e: u32): bool => true);
        for (let k = 0; k < group.length; k++) seen.add(group[k]);
        if (group.length > best.length) {
            best = group.slice(0);
        }
        all.push(group);
    }
    if (all.length <= 1) {
        return 0;
    }
    const drop: Array<u32> = [];
    for (let i = 0; i < all.length; i++) {
        const g = all[i];
        if (sameIds(g, best)) continue;
        for (let k = 0; k < g.length; k++) drop.push(g[k]);
    }
    const n = drop.length;
    mesh.deleteFacesCleanup(drop);
    mesh.deleteLooseVerts();
    return n;
}

// A pending move: the vertex and its displacement.
class Move {
    v: VertId;
    d: Vec3;
    constructor(v: VertId, d: Vec3) {
        this.v = v;
        this.d = d;
    }
}

// One umbrella smoothing pass, used by the smooth and sharp modes.
export function relax(mesh: Mesh, factor: f32): void {
    const moves: Array<Move> = [];
    const ids = mesh.verts.ids();
    for (let i = 0; i < ids.length; i++) {
        const v = ids[i];
        const n = mesh.vertNeighbors(v);
        if (n.length == 0) {
            continue;
        }
        let sum = Vec3(0, 0, 0);
        for (let k = 0; k < n.length; k++) sum = sum + mesh.verts.at(n[k]).co;
        const mean = sum / <f32>n.length;
        moves.push(new Move(v, (mean - mesh.verts.at(v).co) * factor));
    }
    for (let i = 0; i < moves.length; i++) {
        const vert = mesh.verts.at(moves[i].v);
        vert.co = vert.co + moves[i].d;
    }
}
