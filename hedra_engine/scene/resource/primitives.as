// Derived from Godot Engine 4.x (MIT); see THIRD_PARTY_NOTICES.md.
// The built-in meshes (sub_resource types BoxMesh, SphereMesh, CylinderMesh
// and PlaneMesh of ../classdb.as): their parameters, with the defaults of
// format 1 (Godot 4's), and the triangles each generates, in scene space
// (Y up), with normals and UVs laid out as Godot lays them out, and one
// surface whose material is the mesh's `material`. docs/formats/RSCN.md,
// "Built-in meshes", gives the vertex and triangle counts for each.
//
// Each generator follows Godot 4's `_create_mesh_array` for its class,
// vertex for vertex, so that a scene written for Godot looks the same here,
// with one difference: Godot's front faces are clockwise and ours (glTF's
// and Hedra's) counter-clockwise, so every triangle's indices are written
// in the reverse order. Seams, pole vertices and degenerate pole triangles
// are kept as Godot has them, so the counts match its. Positions are
// computed from the grid index rather than accumulated, so the last row of
// a grid lands exactly on the edge.

import { displayF64 } from "../../base/fmt";
import { Vec2, Vec3 } from "../../base/vecmath";
import { Value } from "../value";
import { ArrayMesh, Mesh, MeshSurface, StandardMaterial3D } from "./types";

const TAU: f64 = 2.0 * Math.PI;

function pushVertex(s: MeshSurface, px: f64, py: f64, pz: f64, n: Vec3, u: f64, v: f64): void {
    s.positions.push(<f32>px);
    s.positions.push(<f32>py);
    s.positions.push(<f32>pz);
    s.normals.push(n.x);
    s.normals.push(n.y);
    s.normals.push(n.z);
    s.uvs.push(<f32>u);
    s.uvs.push(<f32>v);
}

// Godot's grid cell (prev + a, prev + b, this + a), (prev + b, this + b,
// this + a), each triangle reversed to be counter-clockwise.
function pushCell(s: MeshSurface, prevrow: i32, thisrow: i32, a: i32, b: i32): void {
    s.indices.push(<u32>(prevrow + a));
    s.indices.push(<u32>(thisrow + a));
    s.indices.push(<u32>(prevrow + b));
    s.indices.push(<u32>(prevrow + b));
    s.indices.push(<u32>(thisrow + a));
    s.indices.push(<u32>(thisrow + b));
}

// Godot's cap triangle (a, b, c), reversed.
function pushTri(s: MeshSurface, a: i32, b: i32, c: i32): void {
    s.indices.push(<u32>a);
    s.indices.push(<u32>c);
    s.indices.push(<u32>b);
}

// The one surface of a primitive, with the mesh's material and its bounds.
function finish(s: MeshSurface, material: StandardMaterial3D?): ArrayMesh {
    s.material = material;
    const m = new ArrayMesh();
    m.surfaces.push(s);
    m.computeBounds();
    return m;
}

// The point of a circle at fraction `u` of a turn, starting at +Z and going
// toward +X (Godot's order). The seam vertex (u = 1) is exactly the first,
// as Godot writes it, rather than sin(2 pi), which is not quite 0.
function circleX(i: i32, n: i32): f64 {
    return i == n ? 0.0 : Math.sin(<f64>i / <f64>n * TAU);
}

function circleZ(i: i32, n: i32): f64 {
    return i == n ? 1.0 : Math.cos(<f64>i / <f64>n * TAU);
}

function atLeast(v: i32, lo: i32): i32 {
    return v > lo ? v : lo;
}

// The most vertices a built-in mesh may have (docs/formats/RSCN.md, "Built-in
// meshes"). Godot sets no limit, but the subdivisions are 32-bit ints, so
// without one a single property (radial_segments 2147483647) asks for more
// memory than a WebAssembly heap has, and a cut count of 2147483647 overflows
// `cuts + 1`. A million vertices is about 32 MB of positions, normals and
// UVs, and about 450 times the defaults' largest mesh (SphereMesh, 2,210). The
// validator and the sub_resource builder refuse a mesh above it
// (`primitive-too-large`); generate() makes an empty mesh for one built in
// code, so that no loop below ever runs past it.
export const PRIMITIVE_VERTEX_LIMIT: f64 = 1000000;

export abstract class PrimitiveMesh extends Mesh {
    material: StandardMaterial3D? = null;
    private cached: ArrayMesh? = null;

    // The triangles, generated once (a mesh is not changed after it is
    // built; one that is must call invalidate()).
    arrays(): ArrayMesh {
        let m = this.cached;
        if (m == null) {
            m = this.generate();
            this.cached = m;
        }
        return m;
    }

    invalidate(): void {
        this.cached = null;
    }

    // The vertices generate() makes, by RSCN.md's formulas, computed in f64
    // so that no parameter overflows it.
    abstract vertexCount(): f64;

    // Whether the mesh is above PRIMITIVE_VERTEX_LIMIT.
    tooLarge(): bool {
        return this.vertexCount() > PRIMITIVE_VERTEX_LIMIT;
    }

    // Builds the triangles (one surface, `material` as its material, bounds
    // computed); an empty surface for a mesh that is tooLarge().
    generate(): ArrayMesh {
        const s = new MeshSurface();
        if (!this.tooLarge()) this.fill(s);
        return finish(s, this.material);
    }

    // Adds the vertices and triangles to `s`.
    abstract fill(s: MeshSurface): void;
}

export class BoxMesh extends PrimitiveMesh {
    size: Vec3 = Vec3(1, 1, 1);
    subdivideWidth: i32 = 0;
    subdivideHeight: i32 = 0;
    subdivideDepth: i32 = 0;

    className(): string {
        return "BoxMesh";
    }

    vertexCount(): f64 {
        const w = <f64>atLeast(this.subdivideWidth, 0);
        const h = <f64>atLeast(this.subdivideHeight, 0);
        const d = <f64>atLeast(this.subdivideDepth, 0);
        return 2.0 * ((w + 2.0) * (h + 2.0) + (d + 2.0) * (h + 2.0) + (w + 2.0) * (d + 2.0));
    }

    // Six faces, each a (cuts + 2) x (cuts + 2) grid of vertices with a flat
    // normal, UVs in Godot's 3 x 2 atlas: front, right, back on the top row,
    // left, top, bottom on the bottom one.
    fill(s: MeshSurface): void {
        const w = atLeast(this.subdivideWidth, 0);
        const h = atLeast(this.subdivideHeight, 0);
        const d = atLeast(this.subdivideDepth, 0);
        const sx = <f64>this.size.x;
        const sy = <f64>this.size.y;
        const sz = <f64>this.size.z;
        const x0 = -sx * 0.5;
        const y0 = -sy * 0.5;
        const z0 = -sz * 0.5;
        const third = 1.0 / 3.0;
        const twoThirds = 2.0 / 3.0;
        let point = 0;

        // Front (+Z) and back (-Z), interleaved as Godot writes them.
        let thisrow = point;
        let prevrow = 0;
        for (let j = 0; j <= h + 1; j++) {
            const y = y0 + sy * <f64>j / <f64>(h + 1);
            const v = <f64>j / (2.0 * <f64>(h + 1));
            for (let i = 0; i <= w + 1; i++) {
                const x = x0 + sx * <f64>i / <f64>(w + 1);
                const u = <f64>i / (3.0 * <f64>(w + 1));
                pushVertex(s, x, -y, -z0, Vec3(0, 0, 1), u, v);
                pushVertex(s, -x, -y, z0, Vec3(0, 0, -1), twoThirds + u, v);
                point += 2;
                if (i > 0 && j > 0) {
                    const i2 = i * 2;
                    pushCell(s, prevrow, thisrow, i2 - 2, i2);
                    pushCell(s, prevrow, thisrow, i2 - 1, i2 + 1);
                }
            }
            prevrow = thisrow;
            thisrow = point;
        }

        // Right (+X) and left (-X).
        thisrow = point;
        prevrow = 0;
        for (let j = 0; j <= h + 1; j++) {
            const y = y0 + sy * <f64>j / <f64>(h + 1);
            const v = <f64>j / (2.0 * <f64>(h + 1));
            for (let i = 0; i <= d + 1; i++) {
                const z = z0 + sz * <f64>i / <f64>(d + 1);
                const u = <f64>i / (3.0 * <f64>(d + 1));
                pushVertex(s, -x0, -y, -z, Vec3(1, 0, 0), third + u, v);
                pushVertex(s, x0, -y, z, Vec3(-1, 0, 0), u, 0.5 + v);
                point += 2;
                if (i > 0 && j > 0) {
                    const i2 = i * 2;
                    pushCell(s, prevrow, thisrow, i2 - 2, i2);
                    pushCell(s, prevrow, thisrow, i2 - 1, i2 + 1);
                }
            }
            prevrow = thisrow;
            thisrow = point;
        }

        // Top (+Y) and bottom (-Y).
        thisrow = point;
        prevrow = 0;
        for (let j = 0; j <= d + 1; j++) {
            const z = z0 + sz * <f64>j / <f64>(d + 1);
            const v = <f64>j / (2.0 * <f64>(d + 1));
            for (let i = 0; i <= w + 1; i++) {
                const x = x0 + sx * <f64>i / <f64>(w + 1);
                const u = <f64>i / (3.0 * <f64>(w + 1));
                pushVertex(s, -x, -y0, -z, Vec3(0, 1, 0), third + u, 0.5 + v);
                pushVertex(s, x, y0, -z, Vec3(0, -1, 0), twoThirds + u, 0.5 + v);
                point += 2;
                if (i > 0 && j > 0) {
                    const i2 = i * 2;
                    pushCell(s, prevrow, thisrow, i2 - 2, i2);
                    pushCell(s, prevrow, thisrow, i2 - 1, i2 + 1);
                }
            }
            prevrow = thisrow;
            thisrow = point;
        }
    }
}

export class SphereMesh extends PrimitiveMesh {
    radius: f32 = 0.5;
    height: f32 = 1;
    radialSegments: i32 = 64;
    rings: i32 = 32;
    isHemisphere: bool = false;

    className(): string {
        return "SphereMesh";
    }

    vertexCount(): f64 {
        const radial = <f64>atLeast(this.radialSegments, 4);
        const rings = <f64>atLeast(this.rings, 1);
        return (rings + 2.0) * (radial + 1.0);
    }

    // Rings from the top pole (v = 0) to the bottom one (v = 1), each a
    // circle of radialSegments + 1 vertices (the seam twice); every vertex of
    // a pole ring is the pole. `height` stretches the sphere along Y into an
    // ellipsoid (normals follow). A hemisphere is Godot's: the height is the
    // dome's, from y = 0 to y = height, and the rings below the equator
    // fold flat onto y = 0 as the base disc, facing down, so that the
    // vertex and triangle counts do not change.
    fill(s: MeshSurface): void {
        const radial = atLeast(this.radialSegments, 4);
        const rings = atLeast(this.rings, 1);
        const radius = <f64>this.radius;
        const scale = <f64>this.height * (this.isHemisphere ? 1.0 : 0.5);
        let point = 0;
        let thisrow = 0;
        let prevrow = 0;
        for (let j = 0; j <= rings + 1; j++) {
            const v = <f64>j / <f64>(rings + 1);
            // The last ring is exactly the bottom pole (sin(pi) is not 0).
            const w = j == rings + 1 ? 0.0 : Math.sin(Math.PI * v);
            const y = j == rings + 1 ? -1.0 : Math.cos(Math.PI * v);
            for (let i = 0; i <= radial; i++) {
                const u = <f64>i / <f64>radial;
                const x = circleX(i, radial);
                const z = circleZ(i, radial);
                if (this.isHemisphere && y < 0.0) {
                    pushVertex(s, x * radius * w, 0.0, z * radius * w, Vec3(0, -1, 0), u, v);
                } else {
                    const n = Vec3(<f32>(x * w * scale), <f32>(radius * y), <f32>(z * w * scale));
                    pushVertex(s, x * radius * w, scale * y, z * radius * w, n.normalizeOr(Vec3(0, y < 0 ? -1 : 1, 0)), u, v);
                }
                point++;
                if (i > 0 && j > 0) pushCell(s, prevrow, thisrow, i - 1, i);
            }
            prevrow = thisrow;
            thisrow = point;
        }
    }
}

export class CylinderMesh extends PrimitiveMesh {
    topRadius: f32 = 0.5;
    bottomRadius: f32 = 0.5;
    height: f32 = 2;
    radialSegments: i32 = 64;
    rings: i32 = 4;
    capTop: bool = true;
    capBottom: bool = true;

    className(): string {
        return "CylinderMesh";
    }

    vertexCount(): f64 {
        const radial = <f64>atLeast(this.radialSegments, 4);
        const rings = <f64>atLeast(this.rings, 0);
        let n = (rings + 2.0) * (radial + 1.0);
        if (this.capTop && this.topRadius > 0) n += radial + 2.0;
        if (this.capBottom && this.bottomRadius > 0) n += radial + 2.0;
        return n;
    }

    // The side: rings + 2 circles of radialSegments + 1 vertices from the
    // top (v = 0) down, the radius going from topRadius to bottomRadius,
    // normals leaning with the slope; UVs in the upper half of the texture.
    // Each cap (when asked for and its radius is not 0): a centre and a
    // circle, as a fan, UVs in a disc of the lower half (top left, bottom
    // right).
    fill(s: MeshSurface): void {
        const radial = atLeast(this.radialSegments, 4);
        const rings = atLeast(this.rings, 0);
        const top = <f64>this.topRadius;
        const bottom = <f64>this.bottomRadius;
        const height = <f64>this.height;
        // The side's normal: (x, slope, z) normalised, the slope being how
        // much the radius shrinks per unit of height.
        const slope = height != 0.0 ? (bottom - top) / height : 0.0;
        let point = 0;
        let thisrow = 0;
        let prevrow = 0;
        for (let j = 0; j <= rings + 1; j++) {
            const v = <f64>j / <f64>(rings + 1);
            const radius = top + (bottom - top) * v;
            const y = height * 0.5 - height * v;
            for (let i = 0; i <= radial; i++) {
                const u = <f64>i / <f64>radial;
                const x = circleX(i, radial);
                const z = circleZ(i, radial);
                const n = Vec3(<f32>x, <f32>slope, <f32>z).normalize();
                pushVertex(s, x * radius, y, z * radius, n, u, v * 0.5);
                point++;
                if (i > 0 && j > 0) pushCell(s, prevrow, thisrow, i - 1, i);
            }
            prevrow = thisrow;
            thisrow = point;
        }
        if (this.capTop && top > 0.0) {
            const y = height * 0.5;
            const centre = point;
            pushVertex(s, 0, y, 0, Vec3(0, 1, 0), 0.25, 0.75);
            point++;
            for (let i = 0; i <= radial; i++) {
                const x = circleX(i, radial);
                const z = circleZ(i, radial);
                pushVertex(s, x * top, y, z * top, Vec3(0, 1, 0), (x + 1.0) * 0.25, 0.5 + (z + 1.0) * 0.25);
                point++;
                if (i > 0) pushTri(s, centre, point - 1, point - 2);
            }
        }
        if (this.capBottom && bottom > 0.0) {
            const y = height * -0.5;
            const centre = point;
            pushVertex(s, 0, y, 0, Vec3(0, -1, 0), 0.75, 0.75);
            point++;
            for (let i = 0; i <= radial; i++) {
                const x = circleX(i, radial);
                const z = circleZ(i, radial);
                pushVertex(s, x * bottom, y, z * bottom, Vec3(0, -1, 0), 0.5 + (x + 1.0) * 0.25, 1.0 - (z + 1.0) * 0.25);
                point++;
                if (i > 0) pushTri(s, centre, point - 2, point - 1);
            }
        }
    }
}

export class PlaneMesh extends PrimitiveMesh {
    size: Vec2 = Vec2(2, 2);
    subdivideWidth: i32 = 0;
    subdivideDepth: i32 = 0;
    centerOffset: Vec3 = Vec3(0, 0, 0);
    // 0 face_x, 1 face_y, 2 face_z.
    orientation: i32 = 1;

    className(): string {
        return "PlaneMesh";
    }

    vertexCount(): f64 {
        const w = <f64>atLeast(this.subdivideWidth, 0);
        const d = <f64>atLeast(this.subdivideDepth, 0);
        return (w + 2.0) * (d + 2.0);
    }

    // A (cuts + 2) x (cuts + 2) grid facing +X, +Y or +Z (orientation),
    // offset by centerOffset; UVs flipped both ways as Godot flips them (to
    // match its QuadMesh).
    fill(s: MeshSurface): void {
        const w = atLeast(this.subdivideWidth, 0);
        const d = atLeast(this.subdivideDepth, 0);
        const sw = <f64>this.size.x;
        const sd = <f64>this.size.y;
        const x0 = -sw * 0.5;
        const z0 = -sd * 0.5;
        const o = this.centerOffset;
        const ox = <f64>o.x;
        const oy = <f64>o.y;
        const oz = <f64>o.z;
        let normal = Vec3(0, 1, 0);
        if (this.orientation == 0) normal = Vec3(1, 0, 0);
        else if (this.orientation == 2) normal = Vec3(0, 0, 1);
        let point = 0;
        let thisrow = 0;
        let prevrow = 0;
        for (let j = 0; j <= d + 1; j++) {
            const z = z0 + sd * <f64>j / <f64>(d + 1);
            for (let i = 0; i <= w + 1; i++) {
                const x = x0 + sw * <f64>i / <f64>(w + 1);
                const u = <f64>i / <f64>(w + 1);
                const v = <f64>j / <f64>(d + 1);
                if (this.orientation == 0) pushVertex(s, ox, z + oy, x + oz, normal, 1.0 - u, 1.0 - v);
                else if (this.orientation == 2) pushVertex(s, -x + ox, z + oy, oz, normal, 1.0 - u, 1.0 - v);
                else pushVertex(s, -x + ox, oy, -z + oz, normal, 1.0 - u, 1.0 - v);
                point++;
                if (i > 0 && j > 0) pushCell(s, prevrow, thisrow, i - 1, i);
            }
            prevrow = thisrow;
            thisrow = point;
        }
    }
}

// Milestone 35: Godot's QuadMesh, a PlaneMesh of 1 x 1 facing +Z (the
// quad a billboard particle draws); every field is PlaneMesh's.
export class QuadMesh extends PlaneMesh {
    constructor() {
        super();
        this.size = Vec2(1, 1);
        this.orientation = 2;
    }

    className(): string {
        return "QuadMesh";
    }
}

// A built-in mesh of class `type` with its defaults, or null for any other
// class.
export function newPrimitive(type: string): PrimitiveMesh? {
    if (type == "BoxMesh") return new BoxMesh();
    if (type == "SphereMesh") return new SphereMesh();
    if (type == "CylinderMesh") return new CylinderMesh();
    if (type == "PlaneMesh") return new PlaneMesh();
    if (type == "QuadMesh") return new QuadMesh();
    return null;
}

// Sets property `n` of a built-in mesh from `v`, a value of the property's
// type (../classdb.as); `material`, a resource, is the caller's to resolve,
// and a name the class does not have changes nothing. Shared by the
// sub_resource builder and the validator, which sets the same fields to
// check the vertex limit before anything is loaded.
export function setPrimitiveField(made: PrimitiveMesh, n: string, v: Value): void {
    // Each test in a local first, as elsewhere in the library: the branches
    // are then plain bools rather than narrowing conditions.
    const isBox = made instanceof BoxMesh;
    const isSphere = made instanceof SphereMesh;
    const isCylinder = made instanceof CylinderMesh;
    const isPlane = made instanceof PlaneMesh;
    if (isBox) {
        const b = made as BoxMesh;
        if (n == "size") b.size = v.vec3();
        else if (n == "subdivide_width") b.subdivideWidth = v.asI32();
        else if (n == "subdivide_height") b.subdivideHeight = v.asI32();
        else if (n == "subdivide_depth") b.subdivideDepth = v.asI32();
    } else if (isSphere) {
        const sp = made as SphereMesh;
        if (n == "radius") sp.radius = v.asF32();
        else if (n == "height") sp.height = v.asF32();
        else if (n == "radial_segments") sp.radialSegments = v.asI32();
        else if (n == "rings") sp.rings = v.asI32();
        else if (n == "is_hemisphere") sp.isHemisphere = v.b;
    } else if (isCylinder) {
        const c = made as CylinderMesh;
        if (n == "top_radius") c.topRadius = v.asF32();
        else if (n == "bottom_radius") c.bottomRadius = v.asF32();
        else if (n == "height") c.height = v.asF32();
        else if (n == "radial_segments") c.radialSegments = v.asI32();
        else if (n == "rings") c.rings = v.asI32();
        else if (n == "cap_top") c.capTop = v.b;
        else if (n == "cap_bottom") c.capBottom = v.b;
    } else if (isPlane) {
        const pl = made as PlaneMesh;
        if (n == "size") pl.size = v.vec2();
        else if (n == "subdivide_width") pl.subdivideWidth = v.asI32();
        else if (n == "subdivide_depth") pl.subdivideDepth = v.asI32();
        else if (n == "center_offset") pl.centerOffset = v.vec3();
        else if (n == "orientation") pl.orientation = v.asI32();
    }
}

// The message and hint of a `primitive-too-large` error for sub_resource
// `id`.
export function tooLargeMessage(m: PrimitiveMesh, id: string): string {
    return m.className() + " \"" + id + "\" makes " + displayF64(m.vertexCount()) + " vertices, more than the limit of "
        + displayF64(PRIMITIVE_VERTEX_LIMIT);
}

export function tooLargeHint(m: PrimitiveMesh): string {
    const isBox = m instanceof BoxMesh;
    const isPlane = m instanceof PlaneMesh;
    const which = isBox ? "subdivide_width, subdivide_height or subdivide_depth"
        : isPlane ? "subdivide_width or subdivide_depth" : "radial_segments or rings";
    return "lower " + which + "; RSCN.md, \"Built-in meshes\", gives each mesh's vertex count";
}
