// Screw (Blender: Generate > Screw): revolve a profile around an axis,
// optionally advancing along it so the result is a helix.
//
// A `spin` operator already exists in the kernel for the edit-mode gesture;
// this is the modifier, which differs in the ways that matter for a stack:
// it is re-evaluated from the profile every time, it welds a full turn
// back onto itself, and `screw` plus `iterations` build a thread rather
// than a surface of revolution.

import { Vec3, Mat3, VEC3_X, VEC3_Y, VEC3_Z } from "../../../../base/vecmath";
import { appleSincosf } from "../../../../base/libm";
import { Result, dedup } from "../../../../base/util";
import { Mesh, VertId, EdgeId, NO_ID } from "../../mesh/mod";
import { ModifierEnv, assignMesh } from "../mod";
import { PropDef, PropKind, Props, prop } from "./props";

export const PROPS: Array<PropDef> = [
    prop("axis", PropKind.Axis(), "z", "the axis to revolve around"),
    prop("angle", PropKind.Degrees(), "360", "how far round to sweep"),
    prop("steps", PropKind.IntRange(1, 512), "16", "segments in one sweep"),
    prop("screw", PropKind.Float(), "0", "how far to advance along the axis over one full turn"),
    prop("iterations", PropKind.IntRange(1, 256), "1", "how many turns to repeat, for a thread"),
    prop("merge", PropKind.Bool(), "true", "weld the last ring onto the first when the sweep closes"),
    prop("merge-threshold", PropKind.Float(), "0.001", "how close counts as the same vertex when merging"),
    prop("flip", PropKind.Bool(), "false", "turn the result inside out"),
    prop("smooth", PropKind.Bool(), "false", "mark the faces it makes as smooth-shaded"),
];

// 2π as f32.
const TAU_F32: f32 = 6.28318530717958647692;

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const warnings: Array<string> = [];
    if (mesh.verts.isEmpty()) {
        return Result.okv<Array<string>>(warnings);
    }
    let iterations = p.u32("iterations");
    if (iterations < 1) iterations = 1;
    const angle = p.radians("angle") * <f32>iterations;
    let steps1 = p.u32("steps");
    if (steps1 < 1) steps1 = 1;
    const steps = steps1 * iterations;
    const screw = p.f32("screw") * <f32>iterations;
    const closed =
        p.bool("merge") &&
        iterations == 1 &&
        Mathf.abs(Mathf.abs(p.radians("angle")) - TAU_F32) < <f32>1e-4 &&
        Mathf.abs(screw) < <f32>1e-9;

    const opts = new Opts();
    opts.axis = p.axis("axis");
    opts.angle = angle;
    opts.steps = steps;
    opts.screw = screw;
    opts.close = closed;
    opts.mergeThreshold = p.f32("merge-threshold");
    opts.flip = p.bool("flip");
    opts.smooth = p.bool("smooth");
    const out = revolve(mesh, opts, warnings);
    assignMesh(mesh, out);
    return Result.okv<Array<string>>(warnings);
}

export class Opts {
    axis: i32 = 0;
    // Total sweep in radians.
    angle: f32 = 0;
    // Total number of segments over the whole sweep.
    steps: u32 = 0;
    // Total advance along the axis over the whole sweep.
    screw: f32 = 0;
    // Weld the last ring onto the first.
    close: bool = false;
    mergeThreshold: f32 = 0;
    flip: bool = false;
    smooth: bool = false;
}

function cmpU32(a: u32, b: u32): i32 {
    return a < b ? -1 : a > b ? 1 : 0;
}

// Sweep `mesh`'s edges around the axis. The profile is the mesh's edges —
// a curve of wire edges, or the boundary of an open surface; Blender does
// the same, which is why a Screw on a closed solid produces nothing new.
// Returns a new mesh (`mesh` is not changed).
export function revolve(mesh: Mesh, opts: Opts, warnings: Array<string>): Mesh {
    // The profile edges: wire edges first, and boundary edges when there
    // are none, so both ways of drawing a profile work.
    let profile: Array<EdgeId> = mesh.wireEdges();
    if (profile.length == 0) {
        profile = mesh.boundaryEdges();
    }
    if (profile.length == 0) {
        warnings.push(
            "nothing to revolve: a screw sweeps the mesh's wire or boundary edges, " +
                "and this mesh has neither",
        );
        return mesh.clone();
    }
    profile.sort(cmpU32);

    const out = Mesh.new();
    for (let i = 0; i < mesh.uvLayers.length; i++) {
        out.uvLayers.push(mesh.uvLayers[i].clone());
    }
    out.activeUv = mesh.activeUv;

    const rings = opts.steps + 1;
    const source: Array<VertId> = [];
    for (let i = 0; i < profile.length; i++) {
        const e = mesh.edges.at(profile[i]);
        source.push(e.v[0]);
        source.push(e.v[1]);
    }
    source.sort(cmpU32);
    dedup<VertId>(source);
    // A profile vertex sitting on the axis does not move as the sweep
    // turns, so every ring would otherwise bring its own copy of it and the
    // quads around it would be degenerate rather than the fan of triangles
    // a revolved cone's tip needs. One vertex is shared instead — unless
    // the sweep also advances along the axis, where the tip really does
    // travel and each ring's copy is a different point.
    const onAxis: Array<bool> = [];
    for (let i = 0; i < source.length; i++) {
        let flat = mesh.verts.at(source[i]).co;
        flat.set(opts.axis, 0.0);
        onAxis.push(Mathf.abs(opts.screw) < <f32>1e-9 && flat.length() < <f32>1e-6);
    }
    const shared: Array<VertId> = [];
    for (let i = 0; i < source.length; i++) shared.push(NO_ID);

    // ring -> (source vertex -> new vertex)
    const grid: Array<Array<VertId>> = [];
    for (let step: u32 = 0; step < rings; step++) {
        const t = <f32>step / <f32>opts.steps;
        const turn = rotation(opts.axis, opts.angle * t);
        let rise = Vec3(0, 0, 0);
        rise.set(opts.axis, opts.screw * t);
        const ring: Array<VertId> = [];
        for (let i = 0; i < source.length; i++) {
            const co0 = mesh.verts.at(source[i]).co;
            if (onAxis[i]) {
                if (shared[i] == NO_ID) shared[i] = out.addVert(co0);
                ring.push(shared[i]);
                continue;
            }
            const co = turn.mulVec3(co0) + rise;
            ring.push(out.addVert(co));
        }
        grid.push(ring);
    }
    // The last ring is the first one again when the sweep closes.
    let close = opts.close && grid.length >= 2;
    if (close) {
        const a = grid[0];
        const b = grid[grid.length - 1];
        const n = a.length < b.length ? a.length : b.length;
        for (let i = 0; i < n; i++) {
            if (!((out.verts.at(a[i]).co - out.verts.at(b[i]).co).length() <= opts.mergeThreshold)) {
                close = false;
                break;
            }
        }
    }
    if (close) {
        const last = grid.pop();
        const first = grid[0].slice(0);
        for (let i = 0; i < last.length; i++) {
            const v = last[i];
            // An on-axis vertex is the *same* vertex in every ring; only
            // the copies this ring brought of its own are removed.
            if (!first.includes(v)) {
                out.removeVert(v);
            }
        }
        grid.push(first);
    }

    for (let step = 0; step < grid.length - 1; step++) {
        const a = grid[step];
        const b = grid[step + 1];
        for (let k = 0; k < profile.length; k++) {
            const e = profile[k];
            const edge = mesh.edges.at(e);
            // `source` is sorted and unique, so each index is unambiguous.
            const ip = source.indexOf(edge.v[0]);
            const iq = source.indexOf(edge.v[1]);
            const quad: Array<VertId> = [a[ip], a[iq], b[iq], b[ip]];
            // A profile vertex sitting on the axis does not move, so its
            // corner of the quad is the same vertex twice: drop it and make
            // a triangle, as a revolved cone's tip needs.
            let verts: Array<VertId> = [];
            for (let i = 0; i < 4; i++) {
                const v = quad[i];
                if (verts.length == 0 || verts[verts.length - 1] != v) {
                    verts.push(v);
                }
            }
            if (verts.length > 2 && verts[0] == verts[verts.length - 1]) {
                verts.pop();
            }
            if (verts.length < 3) {
                continue;
            }
            if (opts.flip) {
                verts.reverse();
            }
            const f = out.addFace(verts);
            const face = out.faces.at(f);
            face.smooth = opts.smooth;
            const ef = mesh.edgeFaces(e);
            face.materialIndex = ef.length > 0 ? mesh.faces.at(ef[0]).materialIndex : <u16>0;
        }
    }
    out.deleteLooseVerts();
    out.recalcNormals();
    return out;
}

// A rotation about X, Y or Z. The sine and cosine come from appleSincosf,
// which reproduces Apple libm's `__sincosf_stret` bit for bit. That
// routine is not correctly rounded, and the recorded reference values
// depend on it (a correctly rounded sin/cos put some rings an ulp or two
// off: a 64-step, two-turn sweep moved 16 of 2322 vertices). vecmath's
// `Mat3.fromRotation*` are built the same way.
function rotation(axis: i32, angle: f32): Mat3 {
    const sc = appleSincosf(angle);
    const sina = sc.s;
    const cosa = sc.c;
    if (axis == 0) return Mat3.fromCols(VEC3_X, Vec3(0.0, cosa, sina), Vec3(0.0, -sina, cosa));
    if (axis == 1) return Mat3.fromCols(Vec3(cosa, 0.0, -sina), VEC3_Y, Vec3(sina, 0.0, cosa));
    return Mat3.fromCols(Vec3(cosa, sina, 0.0), Vec3(-sina, cosa, 0.0), VEC3_Z);
}
