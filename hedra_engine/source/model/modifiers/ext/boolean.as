// Boolean (Blender: Generate > Boolean): difference, union or intersect
// against another mesh object.
//
// The solver is the straightforward one that Blender calls "fast": split
// every triangle of each mesh along its intersections with the other, then
// keep or drop whole pieces by testing a point inside each against the
// other solid. It is exact about which side a piece falls on — the inside
// test votes over three rays (see `Bvh.inside`) — and it does not try to
// weld the two surfaces into shared edges, which is the part Blender's
// "exact" solver adds. The result is therefore a correct closed shape whose
// seam has coincident but unmerged vertices; a `merge by distance`
// afterwards joins them when that matters.
//
// Both inputs must be closed: "inside" means nothing on an open surface,
// and a boolean against one is reported rather than guessed at.

import { Vec3, VEC3_ZERO } from "../../../../base/vecmath";
import { Result, roundF64, f64ToI64 } from "../../../../base/util";
import { Mesh, UvLayer, VertId, FaceId, NO_ID } from "../../mesh/mod";
import { ModifierEnv, assignMesh } from "../mod";
import { Scene, NO_OBJ } from "../../scene";
import { Bvh } from "./geom/bvh";
import { Tri, TriSegment, triTriIntersect } from "./geom/tri";
import { PropDef, PropKind, Props, prop } from "./props";

export const PROPS: Array<PropDef> = [
    prop(
        "operation",
        PropKind.Choice(["difference", "union", "intersect"]),
        "difference",
        "difference cuts the object away, union merges it, intersect keeps the overlap",
    ),
    prop("object", PropKind.Name(), "none", "the mesh object to cut with"),
    prop(
        "solver",
        PropKind.Choice(["fast", "exact"]),
        "fast",
        "only `fast` is implemented, and `exact` runs it and says so",
    ),
    prop(
        "self-intersection",
        PropKind.Bool(),
        "false",
        "ignored, because the solver does not resolve a mesh against itself",
    ),
    prop("hole-tolerant", PropKind.Bool(), "false", "ignored, because both inputs must be closed"),
    prop(
        "material-mode",
        PropKind.Choice(["index", "transfer"]),
        "index",
        "index keeps each side's own material slot, transfer gives the cut this object's",
    ),
];

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const warnings: Array<string> = [];
    const name = p.optStr("object");
    if (name == null) {
        return Result.fail<Array<string>>("boolean needs an object (`modifier set <name> object <object>`)");
    }
    const scene = env.scene;
    const ownerId = env.object;
    if (scene == null || ownerId == NO_OBJ) {
        return Result.fail<Array<string>>("boolean needs the scene (evaluated without context)");
    }
    if (p.str("solver") == "exact") {
        warnings.push(
            "the exact solver is not implemented; this ran the fast one " +
                "(`merge by-distance` welds the seam afterwards)",
        );
    }
    const flags = ["self-intersection", "hole-tolerant"];
    for (let i = 0; i < flags.length; i++) {
        if (p.bool(flags[i])) {
            warnings.push("--" + flags[i] + " is ignored by the fast solver");
        }
    }
    const found = findOperand(scene, name, ownerId);
    if (!found.ok) return found.forward<Array<string>>();
    const operand = found.value;
    const toLocal = scene.worldMatrix(ownerId).inverse() * scene.worldMatrix(operand.id);
    const cutter = operand.mesh.clone();
    cutter.transform(toLocal);

    const op = p.str("operation");
    const transfer = p.str("material-mode") == "transfer";
    const result = boolean(mesh, cutter, op, transfer, warnings);
    if (!result.ok) return result.forward<Array<string>>();
    assignMesh(mesh, result.value);
    return Result.okv<Array<string>>(warnings);
}

// The shared solver: also what the `boolean` edit operator runs.
export function boolean(a: Mesh, b: Mesh, op: string, transferMaterial: bool, warnings: Array<string>): Result<Mesh> {
    const inputs: Array<Mesh> = [a, b];
    const names = ["this object", "the operand"];
    for (let i = 0; i < 2; i++) {
        const mesh = inputs[i];
        const which = names[i];
        if (mesh.faces.isEmpty()) {
            return Result.fail<Mesh>(which + " has no faces");
        }
        if (!mesh.isClosedManifold()) {
            warnings.push(
                which +
                    " is not a closed manifold; the result may keep or drop the wrong pieces " +
                    "(`inspect check` lists the non-manifold edges)",
            );
        }
    }

    const trisA = triangles(a);
    const trisB = triangles(b);
    // Bvh.build never mutates its array, so the lists are shared.
    const bvhA = Bvh.build(trisA);
    const bvhB = Bvh.build(trisB);

    // Split each side's triangles wherever the other crosses them.
    const piecesA = splitAll(trisA, bvhB);
    const piecesB = splitAll(trisB, bvhA);

    // Which pieces survive, and whether their winding flips.
    let keepAInside = false;
    let keepBInside = false;
    let flipB = false;
    if (op == "union") {
        // (false, false, false)
    } else if (op == "intersect") {
        keepAInside = true;
        keepBInside = true;
    } else {
        // Difference keeps this object's outside and the operand's inside,
        // turned inside out so the cut faces point into the hole.
        keepBInside = true;
        flipB = true;
    }

    const out = Mesh.new();
    const layers = a.uvLayers.length > b.uvLayers.length ? a.uvLayers.length : b.uvLayers.length;
    for (let i = 0; i < layers; i++) {
        out.uvLayers.push(UvLayer.new("UVMap" + (out.uvLayers.length + 1).toString()));
    }
    if (a.uvLayers.length > 0) {
        out.uvLayers[0].name = a.uvLayers[0].name;
    }
    out.activeUv = 0;

    const welder = new Welder();
    const kept = new Counter();
    emit(out, welder, piecesA, trisA, bvhB, keepAInside, false, a, -1, kept);
    emit(out, welder, piecesB, trisB, bvhA, keepBInside, flipB, b, transferMaterial ? 0 : -1, kept);
    if (kept.n == 0) {
        warnings.push(
            "the " + op + " left no geometry: the two meshes may not overlap the way the operation needs",
        );
    }
    out.recalcNormals();
    return Result.okv<Mesh>(out);
}

// A shared counter (closures and helpers cannot write a local).
class Counter {
    n: i32 = 0;
}

// One triangle as three corners.
export class TriPart {
    a: Vec3;
    b: Vec3;
    c: Vec3;
    constructor(a: Vec3, b: Vec3, c: Vec3) {
        this.a = a;
        this.b = b;
        this.c = c;
    }
    get(i: i32): Vec3 {
        if (i == 0) return this.a;
        if (i == 1) return this.b;
        return this.c;
    }
}

// An index into the side's triangles and
// the pieces it was split into.
export class Pieces {
    tri: i32;
    parts: Array<TriPart>;
    constructor(tri: i32, parts: Array<TriPart>) {
        this.tri = tri;
        this.parts = parts;
    }
}

// Add every surviving piece of one side to `out`. `forceMaterial` is -1
// for none.
function emit(
    out: Mesh,
    welder: Welder,
    pieces: Array<Pieces>,
    tris: Array<Tri>,
    against: Bvh,
    keepInside: bool,
    flip: bool,
    source: Mesh,
    forceMaterial: i32,
    kept: Counter,
): void {
    for (let k = 0; k < pieces.length; k++) {
        const face = sourceFace(tris, pieces[k].tri);
        const parts = pieces[k].parts;
        for (let pi = 0; pi < parts.length; pi++) {
            const part = parts[pi];
            const centre = (part.a + part.b + part.c) / <f32>3.0;
            if (against.inside(centre) != keepInside) {
                continue;
            }
            const o1 = flip ? 2 : 1;
            const o2 = flip ? 1 : 2;
            const verts: Array<VertId> = [];
            verts.push(welder.vert(out, part.get(0)));
            verts.push(welder.vert(out, part.get(o1)));
            verts.push(welder.vert(out, part.get(o2)));
            if (verts[0] == verts[1] || verts[1] == verts[2] || verts[0] == verts[2]) {
                continue;
            }
            const id = out.addFace(verts);
            if (face != NO_ID) {
                const src = source.faces.at(face);
                const dst = out.faces.at(id);
                dst.smooth = src.smooth;
                dst.materialIndex = forceMaterial >= 0 ? <u16>forceMaterial : src.materialIndex;
            }
            kept.n += 1;
        }
    }
}

// Which face a triangle index came from. `triangles` built the list face
// by face in `triangulateFace` order and tagged each triangle with its
// face, so the tag is the answer.
function sourceFace(tris: Array<Tri>, triIndex: i32): FaceId {
    if (triIndex < 0 || triIndex >= tris.length) return NO_ID;
    return tris[triIndex].src;
}

// One ten-thousandth of a unit: fine enough that two distinct modelling
// features never collapse, coarse enough that two computations of the same
// intersection point land in the same cell.
const WELD: f64 = 1e4;

// Vertices welded within a tolerance, so the pieces of one split triangle
// share their corners instead of each bringing its own.
class Welder {
    // Quantized position -> vertex (lookup only).
    map: Map<string, VertId> = new Map<string, VertId>();

    vert(mesh: Mesh, p: Vec3): VertId {
        const kx = f64ToI64(roundF64(<f64>p.x * WELD));
        const ky = f64ToI64(roundF64(<f64>p.y * WELD));
        const kz = f64ToI64(roundF64(<f64>p.z * WELD));
        const key = kx.toString() + "," + ky.toString() + "," + kz.toString();
        if (this.map.has(key)) {
            return this.map.get(key);
        }
        const v = mesh.addVert(p);
        this.map.set(key, v);
        return v;
    }
}

function triangles(mesh: Mesh): Array<Tri> {
    const out: Array<Tri> = [];
    const ids = mesh.faces.ids();
    for (let i = 0; i < ids.length; i++) {
        const f = ids[i];
        const ts = mesh.triangulateFace(f);
        for (let k = 0; k < ts.length; k++) {
            const t = ts[k];
            out.push(
                Tri.new(
                    mesh.verts.at(mesh.loops.at(t[0]).vert).co,
                    mesh.verts.at(mesh.loops.at(t[1]).vert).co,
                    mesh.verts.at(mesh.loops.at(t[2]).vert).co,
                    f,
                ),
            );
        }
    }
    return out;
}

// Split every triangle by the ones it crosses. Returns `(index into
// `tris`, the pieces)`.
function splitAll(tris: Array<Tri>, against: Bvh): Array<Pieces> {
    const out: Array<Pieces> = [];
    const pad = Vec3.splat(<f32>1e-5);
    const others = against.tris();
    for (let i = 0; i < tris.length; i++) {
        const t = tris[i];
        const cand = against.overlapping(t.min() - pad, t.max() + pad);
        const cuts: Array<TriSegment> = [];
        for (let k = 0; k < cand.length; k++) {
            const s = triTriIntersect(t, others[cand[k]]);
            if (s != null) cuts.push(s);
        }
        out.push(new Pieces(i, splitTri(new TriPart(t.v[0], t.v[1], t.v[2]), cuts)));
    }
    return out;
}

// Cut one triangle by a set of segments, by repeatedly splitting on the
// plane each segment lies in (perpendicular to the triangle).
//
// Splitting on planes rather than inserting the segments as constrained
// edges is what makes this the "fast" solver: the cut is in the right
// place and the pieces fall on the right sides, but the seam is a fan of
// triangles rather than the minimal one.
export function splitTri(tri: TriPart, cuts: Array<TriSegment>): Array<TriPart> {
    let parts: Array<TriPart> = [tri];
    const normal = (tri.b - tri.a).cross(tri.c - tri.a).normalizeOrZero();
    if (normal == VEC3_ZERO) {
        return parts;
    }
    for (let i = 0; i < cuts.length; i++) {
        const a = cuts[i].p;
        const b = cuts[i].q;
        const along = b - a;
        if (along.lengthSquared() < <f32>1e-14) {
            continue;
        }
        // The plane containing the segment and standing on the triangle.
        const planeN = along.cross(normal).normalizeOrZero();
        if (planeN == VEC3_ZERO) {
            continue;
        }
        const planeD = planeN.dot(a);
        const next: Array<TriPart> = [];
        for (let k = 0; k < parts.length; k++) {
            const pieces = cutByPlane(parts[k], planeN, planeD);
            for (let j = 0; j < pieces.length; j++) next.push(pieces[j]);
        }
        parts = next;
        // A pathological input can keep subdividing; Blender's fast solver
        // gives up the same way rather than running out of memory.
        if (parts.length > 4096) {
            break;
        }
    }
    return parts;
}

// Split one triangle by a plane into one, two or three triangles.
export function cutByPlane(t: TriPart, n: Vec3, d: f32): Array<TriPart> {
    const EPS: f32 = 1e-6;
    const side: StaticArray<f32> = new StaticArray<f32>(3);
    for (let i = 0; i < 3; i++) side[i] = n.dot(t.get(i)) - d;
    let allAbove = true;
    let allBelow = true;
    for (let i = 0; i < 3; i++) {
        if (!(side[i] >= -EPS)) allAbove = false;
        if (!(side[i] <= EPS)) allBelow = false;
    }
    if (allAbove || allBelow) {
        return [t];
    }
    // The lone vertex on its own side.
    let lone = 0;
    for (let i = 0; i < 3; i++) {
        const s = side[i];
        const sa = side[(i + 1) % 3];
        const sb = side[(i + 2) % 3];
        if ((s > EPS && sa <= EPS && sb <= EPS) || (s < -EPS && sa >= -EPS && sb >= -EPS)) {
            lone = i;
            break;
        }
    }
    const i = lone;
    const j = (lone + 1) % 3;
    const k = (lone + 2) % 3;
    const p = cutAt(t, side, i, j);
    const q = cutAt(t, side, i, k);
    const cands: Array<TriPart> = [
        new TriPart(t.get(i), p, q),
        new TriPart(p, t.get(j), t.get(k)),
        new TriPart(p, t.get(k), q),
    ];
    const out: Array<TriPart> = [];
    for (let c = 0; c < 3; c++) {
        const tri = cands[c];
        if ((tri.b - tri.a).cross(tri.c - tri.a).length() > <f32>1e-12) out.push(tri);
    }
    return out;
}

// Where edge `a`-`b` of `t` crosses the plane, for `cutByPlane`.
function cutAt(t: TriPart, side: StaticArray<f32>, a: i32, b: i32): Vec3 {
    const sa = side[a];
    const sb = side[b];
    const denom = sa - sb;
    if (Mathf.abs(denom) < <f32>1e-12) {
        return t.get(a);
    }
    return t.get(a) + (t.get(b) - t.get(a)) * (sa / denom);
}

// An operand object: its id and mesh.
class Operand {
    id: u32;
    mesh: Mesh;
    constructor(id: u32, mesh: Mesh) {
        this.id = id;
        this.mesh = mesh;
    }
}

function findOperand(scene: Scene, name: string, ownerId: u32): Result<Operand> {
    const ids = scene.objects.ids();
    for (let i = 0; i < ids.length; i++) {
        const id = ids[i];
        const obj = scene.objects.at(id);
        if (obj.name != name) continue;
        if (id == ownerId) {
            return Result.fail<Operand>("an object cannot be booleaned against itself");
        }
        const mesh = obj.mesh();
        if (mesh == null) {
            return Result.fail<Operand>("'" + name + "' is a " + obj.typeName() + ", not a mesh");
        }
        return Result.okv<Operand>(new Operand(id, mesh));
    }
    return Result.fail<Operand>("no object named '" + name + "'");
}
