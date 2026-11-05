// Wireframe (Blender: Generate > Wireframe): replace the surface with a
// solid bar along every edge.
//
// Each edge becomes a four-sided tube, inset from the faces it belongs to
// so the bars of a vertex meet without overlapping. Blender builds the
// joints from the vertex's face fan; this builds them the same way, by
// offsetting each bar's ends towards the vertex by the thickness.

import { Vec3, VEC3_ZERO, VEC3_X, VEC3_Z } from "../../../../base/vecmath";
import { Result, minF32 } from "../../../../base/util";
import { Mesh, VertId, EdgeId, FaceId } from "../../mesh/mod";
import { ModifierEnv } from "../mod";
import { PropDef, PropKind, Props, prop } from "./props";
import { VERTEX_GROUP, INVERT_GROUP, weightField, weightAt } from "./common";

export const PROPS: Array<PropDef> = [
    prop("thickness", PropKind.Float(), "0.02", "how thick each bar is"),
    prop(
        "offset",
        PropKind.Range(-1.0, 1.0),
        "0",
        "-1 puts the bar inside the original surface, 1 outside, 0 centred",
    ),
    prop("boundary", PropKind.Bool(), "true", "make bars along open boundary edges too"),
    prop(
        "replace",
        PropKind.Bool(),
        "true",
        "throw the original faces away (off keeps them inside the wireframe)",
    ),
    prop("even", PropKind.Bool(), "true", "keep the thickness even where edges meet at a sharp angle"),
    prop("relative", PropKind.Bool(), "false", "scale each bar by the length of the edge it follows"),
    prop("material-offset", PropKind.Int(), "0", "add this to the material slot of every face made"),
    VERTEX_GROUP,
    INVERT_GROUP,
];

// A per-vertex weight.
export type VertWeight = (v: VertId) => f32;

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const wf = weightField(mesh, p, env);
    const warnings = wf.field.warnings.slice(0);
    if (mesh.edges.isEmpty()) {
        return Result.okv<Array<string>>(warnings);
    }
    const thickness = p.f32("thickness");
    if (thickness <= <f32>0.0) {
        warnings.push("thickness is zero, so no bars were made");
        return Result.okv<Array<string>>(warnings);
    }
    const opts = new Opts();
    opts.thickness = thickness;
    opts.offset = p.f32("offset");
    opts.boundary = p.bool("boundary");
    opts.replace = p.bool("replace");
    opts.even = p.bool("even");
    opts.relative = p.bool("relative");
    opts.materialOffset = <u16>p.u32("material-offset");
    const built = wireframe(mesh, opts, (v: VertId): f32 => weightAt(wf.field, wf.invert, v));
    if (built == 0) {
        warnings.push("no edge qualified: with --boundary off an open surface has nothing to wrap");
    }
    mesh.recalcNormals();
    mesh.touch();
    return Result.okv<Array<string>>(warnings);
}

// The wireframe options; `new Opts()` gives the defaults.
export class Opts {
    thickness: f32 = 0.02;
    offset: f32 = 0.0;
    boundary: bool = true;
    replace: bool = true;
    even: bool = true;
    relative: bool = false;
    materialOffset: u16 = 0;
}

// Build the bars. Returns how many edges produced one; also what the
// `wireframe` edit operator runs.
export function wireframe(mesh: Mesh, opts: Opts, weight: VertWeight): i32 {
    // Everything is measured on the mesh as it came in, before any bar is
    // added, so a bar's frame never reads geometry this pass created.
    const edgeIds = mesh.edges.ids();
    const edgeA: Array<VertId> = [];
    const edgeB: Array<VertId> = [];
    const faceCount: Array<i32> = [];
    for (let i = 0; i < edgeIds.length; i++) {
        const e = mesh.edges.at(edgeIds[i]);
        edgeA.push(e.v[0]);
        edgeB.push(e.v[1]);
        faceCount.push(mesh.edgeFaces(edgeIds[i]).length);
    }
    // Vertex normals looked up by id (ids are unique, so a map is enough).
    const normals = new Map<VertId, Vec3>();
    const vids = mesh.verts.ids();
    for (let i = 0; i < vids.length; i++) {
        normals.set(vids[i], mesh.vertNormal(vids[i]));
    }
    const oldFaces: Array<FaceId> = mesh.faces.ids();
    // The material of the face an edge borders, so a bar keeps the surface's
    // slot rather than falling back to 0.
    const materialOf = new Map<EdgeId, u16>();
    for (let i = 0; i < edgeIds.length; i++) {
        const ef = mesh.edgeFaces(edgeIds[i]);
        const slot: u16 = ef.length > 0 ? mesh.faces.at(ef[0]).materialIndex : <u16>0;
        materialOf.set(edgeIds[i], slot);
    }

    let built = 0;
    for (let i = 0; i < edgeIds.length; i++) {
        const edge = edgeIds[i];
        const a = edgeA[i];
        const b = edgeB[i];
        const fc = faceCount[i];
        if (fc == 0) {
            continue;
        }
        if (fc == 1 && !opts.boundary) {
            continue;
        }
        const w = minF32(weight(a), weight(b));
        if (w <= <f32>0.0) {
            continue;
        }
        const pa = mesh.verts.at(a).co;
        const pb = mesh.verts.at(b).co;
        let along = pb - pa;
        const length = along.length();
        if (length < <f32>1e-9) {
            continue;
        }
        along = along / length;
        let radius = opts.thickness * <f32>0.5 * w;
        if (opts.relative) {
            radius *= length;
        }
        // The bar's cross-section: the edge's own normal (the mean of its
        // vertices') and the perpendicular in the surface.
        let normal = (normalOf(normals, a) + normalOf(normals, b)).normalizeOrZero();
        if (normal == VEC3_ZERO) {
            normal = VEC3_Z;
        }
        let side = along.cross(normal).normalizeOrZero();
        if (side == VEC3_ZERO) {
            side = along.cross(VEC3_X).normalizeOrZero();
        }
        const up = side.cross(along).normalizeOrZero();
        // Blender's offset slides the whole bar along the surface normal.
        const shift = up * (radius * opts.offset);
        // Pull the ends back so bars meeting at a vertex do not overlap;
        // with --even off they are left square, which is cheaper and fine
        // on a mesh whose edges meet near a right angle.
        let inset: f32 = opts.even ? radius : <f32>0.0;
        inset = minF32(inset, length * <f32>0.4);
        const start = pa + along * inset + shift;
        const end = pb - along * inset + shift;

        const r0 = ring(mesh, start, side, up, radius);
        const r1 = ring(mesh, end, side, up, radius);
        const base: u16 = materialOf.has(edge) ? materialOf.get(edge) : <u16>0;
        const slot = <u16>(base + opts.materialOffset);
        // Four sides plus two caps: a closed box per edge, which is what
        // makes the result printable even where bars do not meet.
        for (let k = 0; k < 4; k++) {
            const j = (k + 1) % 4;
            addBarFace(mesh, [r0[k], r0[j], r1[j], r1[k]], slot);
        }
        addBarFace(mesh, [r0[3], r0[2], r0[1], r0[0]], slot);
        addBarFace(mesh, [r1[0], r1[1], r1[2], r1[3]], slot);
        built += 1;
    }

    if (opts.replace && built > 0) {
        mesh.deleteFacesCleanup(oldFaces);
        mesh.deleteLooseVerts();
        mesh.deleteWireEdges();
    }
    return built;
}

function normalOf(normals: Map<VertId, Vec3>, v: VertId): Vec3 {
    return normals.has(v) ? normals.get(v) : VEC3_Z;
}

function ring(mesh: Mesh, at: Vec3, side: Vec3, up: Vec3, radius: f32): Array<VertId> {
    return [
        mesh.addVert(at - side * radius - up * radius),
        mesh.addVert(at + side * radius - up * radius),
        mesh.addVert(at + side * radius + up * radius),
        mesh.addVert(at - side * radius + up * radius),
    ];
}

function addBarFace(mesh: Mesh, verts: Array<VertId>, slot: u16): void {
    const f = mesh.addFace(verts);
    mesh.faces.at(f).materialIndex = slot;
}
