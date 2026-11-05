// Emission points from a mesh (milestone 35; docs/engine/PARTICLES.md):
// what Godot's editor does with "Create Emission Points From Node"
// (surface points, and with directed_points their normals), done for
// emission_points_from when a scene loads in the tools or as text in a
// Rive project, and by the compiler at build (which writes the points into
// the built scene's emission_points, so a built project never samples).
// One function serves both, so the built points are the text's, number for
// number.
//
// The sampling: `count` points on the triangles of the named node's mesh
// (a MeshInstance3D's mesh, every visible part of a ModelInstance3D, as
// the scene's plan draws them), placed by the node's global transform and
// taken into the emitter's space (its global transform's inverse, at that
// moment); each triangle chosen with a chance in proportion to its area in
// that space (a cumulative table of the areas, searched by halving with a
// 32-bit draw: two of the stream's 16-bit numbers), a point in it
// uniformly by the barycentric weights (1 - sqrt r1, sqrt r1 (1 - r2),
// sqrt r1 r2), its normal the vertices' interpolated by the same weights
// when the surface has normals (taken through the inverse transpose and
// normalised), else the triangle's own (the normalised cross product of
// its edges, turned over under a mirroring transform), all from one
// ParticleRandom seeded idhash(emitterSeed(use_fixed_seed, seed, path, 0)
// ^ 0x5eed) so that the same scene gives the same points. Four draws a
// point. Allocates its outputs and the table.

import { Mat4, Vec3 } from "../../base/vecmath";
import { ArrayMesh } from "../resource/types";
import { CPUParticles3D, MeshInstance3D, ModelInstance3D } from "../tree/node";
import { ParticleRandom, emitterSeed, idhash } from "./random";

// pointsFromNode's answers.
export const POINTS_OK: i32 = 0;
// emission_points_from is empty.
export const POINTS_NONE: i32 = 1;
// It names no node.
export const POINTS_NO_NODE: i32 = 2;
// It names a node that is neither a MeshInstance3D nor a ModelInstance3D.
export const POINTS_NOT_MESH: i32 = 3;
// Its mesh has no triangles (or none with an area).
export const POINTS_EMPTY: i32 = 4;

// `count` points (three numbers each) and their normals sampled on `mesh`'s
// triangles, each vertex placed by `toEmitter`, appended to `points` and
// `normals`, drawn from `seed`; the points added (0 for a mesh without
// triangles).
export function sampleSurfacePoints(
    mesh: ArrayMesh, toEmitter: Mat4, count: i32, seed: u32, points: Array<f64>, normals: Array<f64>,
): i32 {
    return samplePlaced([mesh], [toEmitter], count, seed, points, normals);
}

// The seed the points of `node` are drawn from (see the header).
export function pointsSeed(node: CPUParticles3D): u32 {
    const fixed = node.useFixedSeed;
    return idhash(emitterSeed(fixed, node.seed, fixed ? "" : node.path(), 0) ^ 0x5eed);
}

// The points node.emissionPointsFrom gives `node` (node.emissionPointsCount
// of them, from pointsSeed), into `points` and `normals` (cleared first);
// POINTS_* says how it went.
export function pointsFromNode(node: CPUParticles3D, points: Array<f64>, normals: Array<f64>): i32 {
    points.length = 0;
    normals.length = 0;
    const path = node.emissionPointsFrom;
    if (path.length == 0) return POINTS_NONE;
    const target = node.getNode(path);
    if (target == null) return POINTS_NO_NODE;
    const toEmitter = node.global().inverse();
    const meshes = new Array<ArrayMesh>();
    const places = new Array<Mat4>();
    const isMesh = target instanceof MeshInstance3D;
    const isModel = target instanceof ModelInstance3D;
    if (isMesh) {
        const m = (target as MeshInstance3D).mesh;
        if (m == null) return POINTS_EMPTY;
        meshes.push(m.arrays());
        places.push(toEmitter * target.global());
    } else if (isModel) {
        const parts = (target as ModelInstance3D).parts();
        const g = toEmitter * target.global();
        for (let i = 0; i < parts.length; i++) {
            const p = parts[i];
            if (!p.visible) continue;
            meshes.push(p.mesh);
            places.push(g * p.local);
        }
    } else {
        return POINTS_NOT_MESH;
    }
    const n = samplePlaced(meshes, places, node.emissionPointsCount, pointsSeed(node), points, normals);
    return n > 0 ? POINTS_OK : POINTS_EMPTY;
}

function vertexAt(a: Array<f32>, i: u32): Vec3 {
    const k = <i32>i * 3;
    return Vec3(a[k], a[k + 1], a[k + 2]);
}

// `count` points over every triangle of `meshes`, each placed by its
// `places` matrix (see the header).
function samplePlaced(
    meshes: Array<ArrayMesh>, places: Array<Mat4>, count: i32, seed: u32, points: Array<f64>, normals: Array<f64>,
): i32 {
    // The table: each triangle with an area, its mesh, surface and first
    // index, and the areas summed up to it.
    const sums = new Array<f64>();
    const ofMesh = new Array<i32>();
    const ofSurface = new Array<i32>();
    const ofIndex = new Array<i32>();
    let total: f64 = 0;
    for (let m = 0; m < meshes.length; m++) {
        const surfaces = meshes[m].surfaces;
        const place = places[m];
        for (let si = 0; si < surfaces.length; si++) {
            const sf = surfaces[si];
            const pos = sf.positions;
            const idx = sf.indices;
            const nv = <u32>(pos.length / 3);
            for (let t = 0; t + 2 < idx.length; t += 3) {
                const i0 = idx[t];
                const i1 = idx[t + 1];
                const i2 = idx[t + 2];
                if (i0 >= nv || i1 >= nv || i2 >= nv) continue;
                const a = place.transformPoint3(vertexAt(pos, i0));
                const b = place.transformPoint3(vertexAt(pos, i1));
                const c = place.transformPoint3(vertexAt(pos, i2));
                const area = <f64>(b - a).cross(c - a).length() * 0.5;
                if (!(area > 0)) continue;
                total += area;
                sums.push(total);
                ofMesh.push(m);
                ofSurface.push(si);
                ofIndex.push(t);
            }
        }
    }
    const tris = sums.length;
    if (tris == 0 || count <= 0) return 0;
    // Each mesh's normal matrix, and whether its placement mirrors.
    const normalMats = new Array<Mat4>();
    const mirrors = new Array<bool>();
    for (let m = 0; m < places.length; m++) {
        const p = places[m];
        normalMats.push(p.inverse().transpose());
        mirrors.push(p.determinant() < 0);
    }
    const rng = new ParticleRandom();
    rng.seed(seed);
    for (let k = 0; k < count; k++) {
        // (a 32-bit fraction from two 16-bit draws: a triangle of a
        // thousandth of a percent of the area is still found)
        const hi = <f64>rng.next() * 65535.0;
        const lo = <f64>rng.next() * 65535.0;
        const u = (hi * 65536.0 + lo) / (65536.0 * 65536.0 - 1.0) * total;
        let a0 = 0;
        let a1 = tris - 1;
        while (a0 < a1) {
            const mid = (a0 + a1) >> 1;
            if (unchecked(sums[mid]) < u) a0 = mid + 1;
            else a1 = mid;
        }
        const m = ofMesh[a0];
        const sf = meshes[m].surfaces[ofSurface[a0]];
        const t = ofIndex[a0];
        const place = places[m];
        const i0 = sf.indices[t];
        const i1 = sf.indices[t + 1];
        const i2 = sf.indices[t + 2];
        const a = place.transformPoint3(vertexAt(sf.positions, i0));
        const b = place.transformPoint3(vertexAt(sf.positions, i1));
        const c = place.transformPoint3(vertexAt(sf.positions, i2));
        const sr = Mathf.sqrt(rng.next());
        const r2 = rng.next();
        const wa = 1 - sr;
        const wb = sr * (1 - r2);
        const wc = sr * r2;
        const p = a * wa + b * wb + c * wc;
        points.push(<f64>p.x);
        points.push(<f64>p.y);
        points.push(<f64>p.z);
        let nrm: Vec3;
        if (sf.normals.length == sf.positions.length) {
            const na = vertexAt(sf.normals, i0);
            const nb = vertexAt(sf.normals, i1);
            const nc = vertexAt(sf.normals, i2);
            nrm = normalMats[m].transformVector3(na * wa + nb * wb + nc * wc).normalizeOrZero();
        } else {
            nrm = (b - a).cross(c - a).normalizeOrZero();
            if (mirrors[m]) nrm = -nrm;
        }
        normals.push(<f64>nrm.x);
        normals.push(<f64>nrm.y);
        normals.push(<f64>nrm.z);
    }
    return count;
}
