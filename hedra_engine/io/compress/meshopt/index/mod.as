// Derived from meshopt-rs 0.1.2 (MIT); see THIRD_PARTY_NOTICES.md.
//
// The index codecs' version enum and the varint used by both index codecs.
// `DecodeError` lives in engine/src/io/compress/meshopt/util (shared with the vertex
// codec).

import { ByteReader } from "../util";

export enum IndexEncodingVersion {
    // Decodable by all versions
    V0,
    // Decodable by meshoptimizer 0.14+
    V1,
}

// The version the encoders write: V1.
export const INDEX_ENCODING_VERSION_DEFAULT: IndexEncodingVersion = IndexEncodingVersion.V1;

// The version number stored in the header byte.
export function indexEncodingVersionByte(v: IndexEncodingVersion): u8 {
    switch (v) {
        case IndexEncodingVersion.V0: return 0;
        default: return 1;
    }
}

export function decodeVByte(data: ByteReader): u32 {
    const lead = <u32>data.readByte();

    // fast path: single byte
    if (lead < 128) {
        return lead;
    }

    // slow path: up to 4 extra bytes
    // note that this loop always terminates, which is important for malformed data
    let result: u32 = lead & 127;
    let shift: u32 = 7;

    for (let i = 0; i < 4; i++) {
        const group = <u32>data.readByte();
        result |= (group & 127) << shift;
        shift += 7;

        if (group < 128) {
            break;
        }
    }

    return result;
}
