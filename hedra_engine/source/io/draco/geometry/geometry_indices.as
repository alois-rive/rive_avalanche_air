// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The typed index wrappers.
//
// Each index is a plain u32 alias. The aliases document intent only: the
// compiler does not tell them apart. `CornerIndex + u32` / `- u32` are plain
// u32 arithmetic (wrapping on overflow).

// Index of a unique attribute value.
export type AttributeValueIndex = u32;
// Index of a point in point-cloud or mesh geometry.
export type PointIndex = u32;
// Index of a corner-table vertex.
export type VertexIndex = u32;
// Index of a corner in triangle corner-table topology.
export type CornerIndex = u32;
// Index of a triangle face.
export type FaceIndex = u32;

// Sentinel attribute value index used for missing mappings.
export const INVALID_ATTRIBUTE_VALUE_INDEX: u32 = u32.MAX_VALUE;
// Sentinel point index.
export const INVALID_POINT_INDEX: u32 = u32.MAX_VALUE;
// Sentinel corner-table vertex index.
export const INVALID_VERTEX_INDEX: u32 = u32.MAX_VALUE;
// Sentinel corner index.
export const INVALID_CORNER_INDEX: u32 = u32.MAX_VALUE;
// Sentinel face index.
export const INVALID_FACE_INDEX: u32 = u32.MAX_VALUE;
