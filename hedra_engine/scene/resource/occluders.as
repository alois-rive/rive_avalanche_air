// Milestone 37: Godot's occluder shapes, an OccluderInstance3D's `occluder`
// (../classdb.as has their properties; docs/formats/RSCN.md "Occlusion
// culling"). Each is in its node's space (Y up, metres) and becomes
// triangles for the culling: ../render/occluder_shapes.as
// `occluderMeshOf` makes Godot's own meshes of the primitives (a box's 12
// triangles, a quad's 2, a sphere of 7 rings of 7 segments, a polygon
// triangulated), and an ArrayOccluder3D is its triangles as they are.
//
// An ArrayOccluder3D comes from a sub_resource (vertices, indices) or from
// an .occ file (ext_resource type ArrayOccluder3D, ./occ_file.as), which
// `hedra bake --occluders` writes. Its numbers are kept as the file gives
// them; one whose indices are not whole triangles of its vertices draws no
// occluder (the warnings say so: occluder-invalid).
//
// `version` moves whenever a field is set (the builder, the editor's
// edits), so a frame that kept an occluder's triangles knows to make them
// again.

import { Vec2, Vec3 } from "../../base/vecmath";
import { Value } from "../value";
import { Resource } from "./types";

export abstract class Occluder3D extends Resource {
    version: u32 = 0;
    // Its triangles as the culling takes them, made by
    // ../render/occluder_shapes.as occluderMeshOf when `version` moves.
    mesh: OccluderMesh = new OccluderMesh();
}

// An occluder's triangles in its node's space (../render/occluder_shapes.as
// makes them).
export class OccluderMesh {
    // x, y, z a point.
    vertices: Float32Array = new Float32Array(0);
    // Three a triangle.
    indices: Uint32Array = new Uint32Array(0);
    // The occluder's version these were made from (-1: none yet).
    version: i64 = -1;
    // Why it has no triangle ("" when it has some): what the warnings say.
    problem: string = "";
}

export class ArrayOccluder3D extends Occluder3D {
    // x, y, z a point.
    vertices: Float32Array = new Float32Array(0);
    // Three a triangle, into vertices.
    indices: Uint32Array = new Uint32Array(0);
    // Whether the indices were whole triangles of the vertices when set
    // (a multiple of 3, each below the point count, none negative).
    valid: bool = true;
    // Whether the indices as written held a negative one (each stored as
    // 0): kept with them, so that vertices set after them, as a file may
    // order its properties, leave the occluder invalid all the same.
    negativeIndices: bool = false;

    className(): string {
        return "ArrayOccluder3D";
    }

    // Sets both arrays (Godot's set_arrays), checking the indices
    // (`negative`: they were written with a negative one).
    setArrays(vertices: Float32Array, indices: Uint32Array, negative: bool = false): void {
        this.vertices = vertices;
        this.indices = indices;
        this.negativeIndices = negative;
        this.valid = !negative && arrayOccluderValid(vertices.length / 3, indices);
        this.version++;
    }
}

export class BoxOccluder3D extends Occluder3D {
    size: Vec3 = Vec3(1, 1, 1);

    className(): string {
        return "BoxOccluder3D";
    }
}

export class SphereOccluder3D extends Occluder3D {
    radius: f32 = 1;

    className(): string {
        return "SphereOccluder3D";
    }
}

export class QuadOccluder3D extends Occluder3D {
    size: Vec2 = Vec2(1, 1);

    className(): string {
        return "QuadOccluder3D";
    }
}

export class PolygonOccluder3D extends Occluder3D {
    // x, y a corner, in order.
    polygon: Float32Array = new Float32Array(0);

    className(): string {
        return "PolygonOccluder3D";
    }
}

// Whether `indices` are whole triangles of `points` points.
export function arrayOccluderValid(points: i32, indices: Uint32Array): bool {
    if (indices.length % 3 != 0) return false;
    for (let i = 0; i < indices.length; i++) if (<i32>unchecked(indices[i]) >= points) return false;
    return true;
}

// A new occluder of class `type`, or null for a type that is not one.
export function newOccluder(type: string): Occluder3D? {
    if (type == "ArrayOccluder3D") return new ArrayOccluder3D();
    if (type == "BoxOccluder3D") return new BoxOccluder3D();
    if (type == "SphereOccluder3D") return new SphereOccluder3D();
    if (type == "QuadOccluder3D") return new QuadOccluder3D();
    if (type == "PolygonOccluder3D") return new PolygonOccluder3D();
    return null;
}

// Sets an occluder's field from a property value of the right type (the
// caller checked it against ../classdb.as), clamped as Godot's setters
// clamp (a sphere's radius at least 0); whether `name` is one of its
// fields. Moves `version`.
export function setOccluderField(o: Occluder3D, name: string, v: Value): bool {
    const cls = o.className();
    if (cls == "ArrayOccluder3D") {
        const a = o as ArrayOccluder3D;
        if (name == "vertices") {
            const f = new Float32Array(v.n.length);
            for (let i = 0; i < v.n.length; i++) f[i] = <f32>v.n[i];
            a.setArrays(f, a.indices, a.negativeIndices);
        } else if (name == "indices") {
            const u = new Uint32Array(v.n.length);
            let negative = false;
            for (let i = 0; i < v.n.length; i++) {
                const x = v.n[i];
                if (x < 0) negative = true;
                u[i] = x < 0 ? 0 : <u32>x;
            }
            a.setArrays(a.vertices, u, negative);
        } else return false;
    } else if (cls == "BoxOccluder3D" && name == "size") {
        (o as BoxOccluder3D).size = v.vec3();
    } else if (cls == "SphereOccluder3D" && name == "radius") {
        const r = v.asF32();
        (o as SphereOccluder3D).radius = r > 0 ? r : 0;
    } else if (cls == "QuadOccluder3D" && name == "size") {
        (o as QuadOccluder3D).size = v.vec2();
    } else if (cls == "PolygonOccluder3D" && name == "polygon") {
        const f = new Float32Array(v.n.length);
        for (let i = 0; i < v.n.length; i++) f[i] = <f32>v.n[i];
        (o as PolygonOccluder3D).polygon = f;
    } else {
        return false;
    }
    o.version++;
    return true;
}
