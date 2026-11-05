// Milestone 63: Godot 4.4's NavigationMesh, a NavigationRegion3D's
// navigation_mesh (../classdb.as has its properties; docs/formats/RSCN.md
// "Navigation", docs/engine/NAVIGATION.md "In a scene file"): the
// settings a bake makes it with, in Godot's names, and the baked polygons in
// Godot's own form, `vertices` (a PackedVector3Array, the region's space: Y
// up, metres) and `polygons` (an Array of PackedInt32Array, each a convex
// polygon's corners as indices into vertices, clockwise seen from above, as
// Godot keeps them). A bake (hedra_compiler/bake/navmesh/) writes the two
// arrays into the sub_resource; a file may write them by hand.
//
// The polygons are kept flat: polygon k's corners are
// polygonIndices[polygonStarts[k] .. polygonStarts[k + 1]), so a map made
// from them reads two typed arrays and allocates nothing per polygon. The
// numbers are kept as the file gives them; `valid` says whether every
// polygon has 3 corners or more, each an index of a vertex (the warnings
// say why not: navigation-mesh-invalid, and the map then takes none of its
// polygons).
//
// `version` moves whenever a field is set (the builder, a bake, the
// editor's edits), so a map that kept a region's polygons knows to read
// them again.

import { Value, ValueKind } from "../value";
import { Resource } from "./types";

// Godot's NavigationMesh.SamplePartitionType.
export const NAVMESH_PARTITION_WATERSHED: i32 = 0;
export const NAVMESH_PARTITION_MONOTONE: i32 = 1;
export const NAVMESH_PARTITION_LAYERS: i32 = 2;
// Godot's NavigationMesh.ParsedGeometryType.
export const NAVMESH_PARSED_MESH_INSTANCES: i32 = 0;
export const NAVMESH_PARSED_STATIC_COLLIDERS: i32 = 1;
export const NAVMESH_PARSED_BOTH: i32 = 2;
// Godot's NavigationMesh.SourceGeometryMode.
export const NAVMESH_SOURCE_ROOT_NODE_CHILDREN: i32 = 0;
export const NAVMESH_SOURCE_GROUPS_WITH_CHILDREN: i32 = 1;
export const NAVMESH_SOURCE_GROUPS_EXPLICIT: i32 = 2;

// The default group of the two group modes (Godot's).
export const NAVMESH_SOURCE_GROUP_DEFAULT = "navigation_mesh_source_group";

// The most corners a polygon may have (Godot's vertices_per_polygon is 3 to
// 6 for a bake; a hand-written polygon may have more, up to this, which the
// map's polygon records hold).
export const NAVMESH_MAX_POLYGON_CORNERS: i32 = 32;

export class NavigationMesh extends Resource {
    // x, y, z a point, in the region's space.
    vertices: Float32Array = new Float32Array(0);
    // The polygons, flat (see the header): P + 1 starts, then the corners.
    polygonStarts: Int32Array = new Int32Array(1);
    polygonIndices: Int32Array = new Int32Array(0);
    // Every polygon has 3 to NAVMESH_MAX_POLYGON_CORNERS corners, each an
    // index of a vertex (checked again when either array is set).
    valid: bool = true;
    // Moves with every set field.
    version: u32 = 0;

    samplePartitionType: i32 = NAVMESH_PARTITION_WATERSHED;
    geometryParsedGeometryType: i32 = NAVMESH_PARSED_BOTH;
    // Godot's u32 mask, kept in an i64 (the file's 4294967295).
    geometryCollisionMask: i64 = 4294967295;
    geometrySourceGeometryMode: i32 = NAVMESH_SOURCE_ROOT_NODE_CHILDREN;
    geometrySourceGroupName: string = NAVMESH_SOURCE_GROUP_DEFAULT;
    cellSize: f32 = 0.25;
    cellHeight: f32 = 0.25;
    borderSize: f32 = 0;
    agentHeight: f32 = 1.5;
    agentRadius: f32 = 0.5;
    agentMaxClimb: f32 = 0.25;
    agentMaxSlope: f32 = 45;
    regionMinSize: f32 = 2;
    regionMergeSize: f32 = 20;
    edgeMaxLength: f32 = 0;
    edgeMaxError: f32 = 1.3;
    verticesPerPolygon: f32 = 6;
    detailSampleDistance: f32 = 6;
    detailSampleMaxError: f32 = 1;
    filterLowHangingObstacles: bool = false;
    filterLedgeSpans: bool = false;
    filterWalkableLowHeightSpans: bool = false;

    className(): string {
        return "NavigationMesh";
    }

    // How many polygons it holds.
    polygonCount(): i32 {
        return this.polygonStarts.length - 1;
    }

    // How many points `vertices` holds.
    vertexCount(): i32 {
        return this.vertices.length / 3;
    }

    // Sets the vertices (x, y, z a point); the polygons are checked again.
    setVertices(vertices: Float32Array): void {
        this.vertices = vertices;
        this.valid = navigationPolygonsValid(this.vertexCount(), this.polygonStarts, this.polygonIndices);
        this.version++;
    }

    // Sets the polygons (flat: see the header), checked against the
    // vertices.
    setPolygons(starts: Int32Array, indices: Int32Array): void {
        this.polygonStarts = starts;
        this.polygonIndices = indices;
        this.valid = navigationPolygonsValid(this.vertexCount(), starts, indices);
        this.version++;
    }

    // Godot's clear(): no vertex, no polygon (the settings are kept).
    clear(): void {
        this.vertices = new Float32Array(0);
        this.polygonStarts = new Int32Array(1);
        this.polygonIndices = new Int32Array(0);
        this.valid = true;
        this.version++;
    }
}

// Whether flat polygons (`starts`, `indices`) are whole polygons of a mesh
// of `vertexCount` points: starts begins at 0, never goes down, ends at the
// corners' count, each polygon has 3 to NAVMESH_MAX_POLYGON_CORNERS corners,
// each corner below vertexCount and not negative.
export function navigationPolygonsValid(vertexCount: i32, starts: Int32Array, indices: Int32Array): bool {
    const p = starts.length - 1;
    if (p < 0 || starts[0] != 0 || starts[p] != indices.length) return false;
    for (let k = 0; k < p; k++) {
        const n = starts[k + 1] - starts[k];
        if (n < 3 || n > NAVMESH_MAX_POLYGON_CORNERS) return false;
    }
    for (let i = 0; i < indices.length; i++) {
        const c = indices[i];
        if (c < 0 || c >= vertexCount) return false;
    }
    return true;
}

// The flat polygons of a `polygons` value (an Array of PackedInt32Array, the
// file's form): null when an item is not a PackedInt32Array (the validator
// says so; the mesh is then left without polygons and invalid).
export class FlatPolygons {
    starts: Int32Array = new Int32Array(1);
    indices: Int32Array = new Int32Array(0);
}

export function flatPolygonsOf(v: Value): FlatPolygons? {
    if (v.kind != ValueKind.Array) return null;
    const items = v.items;
    let total = 0;
    for (let k = 0; k < items.length; k++) {
        const it = items[k];
        if (it.kind != ValueKind.PackedInt32Array) return null;
        total += it.n.length;
    }
    const out = new FlatPolygons();
    out.starts = new Int32Array(items.length + 1);
    out.indices = new Int32Array(total);
    let at = 0;
    for (let k = 0; k < items.length; k++) {
        const n = items[k].n;
        out.starts[k] = at;
        for (let i = 0; i < n.length; i++) out.indices[at++] = <i32>n[i];
    }
    out.starts[items.length] = at;
    return out;
}

// The `vertices` value of a mesh, Godot's text form (what a bake writes).
export function navigationVerticesValue(m: NavigationMesh): Value {
    const n = new Array<f64>(m.vertices.length);
    for (let i = 0; i < m.vertices.length; i++) n[i] = <f64>m.vertices[i];
    return Value.packedVector3s(n);
}

// The `polygons` value of a mesh: an Array of PackedInt32Array, one a
// polygon (what a bake writes).
export function navigationPolygonsValue(m: NavigationMesh): Value {
    const p = m.polygonCount();
    const items = new Array<Value>(p);
    for (let k = 0; k < p; k++) {
        const a = m.polygonStarts[k];
        const b = m.polygonStarts[k + 1];
        const n = new Array<f64>(b - a);
        for (let i = a; i < b; i++) n[i - a] = <f64>m.polygonIndices[i];
        items[k] = Value.packedInts(n);
    }
    return Value.array(items);
}

// Sets a NavigationMesh's field from a property value of the right type
// (the caller checked it against ../classdb.as); whether `name` is one of
// its fields (the editor sets fields through it too).
export function setNavigationMeshField(m: NavigationMesh, name: string, v: Value): bool {
    if (name == "vertices") {
        const f = new Float32Array(v.n.length);
        for (let i = 0; i < v.n.length; i++) f[i] = <f32>v.n[i];
        m.setVertices(f);
        return true;
    }
    if (name == "polygons") {
        const flat = flatPolygonsOf(v);
        if (flat == null) {
            m.setPolygons(new Int32Array(1), new Int32Array(0));
            m.valid = false;
        } else {
            m.setPolygons(flat!.starts, flat!.indices);
        }
        return true;
    }
    if (name == "sample_partition_type") m.samplePartitionType = <i32>v.asI64();
    else if (name == "geometry_parsed_geometry_type") m.geometryParsedGeometryType = <i32>v.asI64();
    else if (name == "geometry_collision_mask") m.geometryCollisionMask = v.asI64() & 0xffffffff;
    else if (name == "geometry_source_geometry_mode") m.geometrySourceGeometryMode = <i32>v.asI64();
    else if (name == "geometry_source_group_name") m.geometrySourceGroupName = v.s;
    else if (name == "cell_size") m.cellSize = v.asF32();
    else if (name == "cell_height") m.cellHeight = v.asF32();
    else if (name == "border_size") m.borderSize = v.asF32();
    else if (name == "agent_height") m.agentHeight = v.asF32();
    else if (name == "agent_radius") m.agentRadius = v.asF32();
    else if (name == "agent_max_climb") m.agentMaxClimb = v.asF32();
    else if (name == "agent_max_slope") m.agentMaxSlope = v.asF32();
    else if (name == "region_min_size") m.regionMinSize = v.asF32();
    else if (name == "region_merge_size") m.regionMergeSize = v.asF32();
    else if (name == "edge_max_length") m.edgeMaxLength = v.asF32();
    else if (name == "edge_max_error") m.edgeMaxError = v.asF32();
    else if (name == "vertices_per_polygon") m.verticesPerPolygon = v.asF32();
    else if (name == "detail_sample_distance") m.detailSampleDistance = v.asF32();
    else if (name == "detail_sample_max_error") m.detailSampleMaxError = v.asF32();
    else if (name == "filter_low_hanging_obstacles") m.filterLowHangingObstacles = v.b;
    else if (name == "filter_ledge_spans") m.filterLedgeSpans = v.b;
    else if (name == "filter_walkable_low_height_spans") m.filterWalkableLowHeightSpans = v.b;
    else return false;
    m.version++;
    return true;
}
