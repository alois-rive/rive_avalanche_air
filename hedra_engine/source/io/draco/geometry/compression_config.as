// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Bitstream configuration enums. Discriminants are the wire values.

export enum EncodedGeometryType {
    InvalidGeometryType = -1,
    PointCloud = 0,
    TriangularMesh = 1,
}

export enum PointCloudEncodingMethod {
    PointCloudSequentialEncoding = 0,
    PointCloudKdTreeEncoding = 1,
}

export enum MeshEncodingMethod {
    MeshSequentialEncoding = 0,
    MeshEdgebreakerEncoding = 1,
}

export enum AttributeEncoderType {
    BasicAttributeEncoder = 0,
    MeshTraversalAttributeEncoder = 1,
    KdTreeAttributeEncoder = 2,
}

// `{:?}` of each enum (the variant name).
export function encodedGeometryTypeDebug(t: EncodedGeometryType): string {
    switch (t) {
        case EncodedGeometryType.InvalidGeometryType: return "InvalidGeometryType";
        case EncodedGeometryType.PointCloud: return "PointCloud";
        case EncodedGeometryType.TriangularMesh: return "TriangularMesh";
    }
    return "";
}

export function pointCloudEncodingMethodDebug(m: PointCloudEncodingMethod): string {
    switch (m) {
        case PointCloudEncodingMethod.PointCloudSequentialEncoding: return "PointCloudSequentialEncoding";
        case PointCloudEncodingMethod.PointCloudKdTreeEncoding: return "PointCloudKdTreeEncoding";
    }
    return "";
}

export function meshEncodingMethodDebug(m: MeshEncodingMethod): string {
    switch (m) {
        case MeshEncodingMethod.MeshSequentialEncoding: return "MeshSequentialEncoding";
        case MeshEncodingMethod.MeshEdgebreakerEncoding: return "MeshEdgebreakerEncoding";
    }
    return "";
}

export function attributeEncoderTypeDebug(t: AttributeEncoderType): string {
    switch (t) {
        case AttributeEncoderType.BasicAttributeEncoder: return "BasicAttributeEncoder";
        case AttributeEncoderType.MeshTraversalAttributeEncoder: return "MeshTraversalAttributeEncoder";
        case AttributeEncoderType.KdTreeAttributeEncoder: return "KdTreeAttributeEncoder";
    }
    return "";
}
