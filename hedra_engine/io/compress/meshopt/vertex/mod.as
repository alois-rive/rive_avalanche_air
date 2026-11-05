// Derived from meshopt-rs 0.1.2 (MIT); see THIRD_PARTY_NOTICES.md.
//
// The vertex codec's version enum. `DecodeError` lives in
// engine/src/io/compress/meshopt/util (shared with the index codecs).

export enum VertexEncodingVersion {
    // Decodable by all versions
    V0,
}

// The version the encoder writes: V0.
export const VERTEX_ENCODING_VERSION_DEFAULT: VertexEncodingVersion = VertexEncodingVersion.V0;

// The version number stored in the header byte.
export function vertexEncodingVersionByte(v: VertexEncodingVersion): u8 {
    switch (v) {
        default: return 0;
    }
}
