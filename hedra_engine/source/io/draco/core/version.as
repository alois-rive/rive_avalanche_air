// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Draco bitstream version constants and checks.
//
// A version is a `DracoVersion` struct (`DEFAULT_MESH_VERSION.major`,
// `.minor`). Constants are namespace-free top-level declarations.

import { Result } from "../../../../base/util";
import { DracoError } from "./status";

// A `(major, minor)` bitstream version.
export struct DracoVersion {
    major: u8 = 0;
    minor: u8 = 0;

    constructor(major: u8, minor: u8) {
        this.major = major;
        this.minor = minor;
    }
}

// Latest Draco point cloud / mesh bitstream versions.
export const DRACO_POINT_CLOUD_BITSTREAM_VERSION_MAJOR: u8 = 2;
export const DRACO_POINT_CLOUD_BITSTREAM_VERSION_MINOR: u8 = 3;
export const DRACO_MESH_BITSTREAM_VERSION_MAJOR: u8 = 2;
export const DRACO_MESH_BITSTREAM_VERSION_MINOR: u8 = 2;

// Default version for Mesh encoding (both Sequential and Edgebreaker): v2.2.
export const DEFAULT_MESH_VERSION: DracoVersion = DracoVersion(DRACO_MESH_BITSTREAM_VERSION_MAJOR, DRACO_MESH_BITSTREAM_VERSION_MINOR);

// Default version for PointCloud encoding, both methods: v2.3.
export const DEFAULT_POINT_CLOUD_VERSION: DracoVersion = DracoVersion(
    DRACO_POINT_CLOUD_BITSTREAM_VERSION_MAJOR,
    DRACO_POINT_CLOUD_BITSTREAM_VERSION_MINOR,
);

// Version that introduced the header flags field (v1.3).
export const VERSION_FLAGS_INTRODUCED: DracoVersion = DracoVersion(1, 3);
// Version that introduced varint encoding for metadata fields (v2.0).
export const VERSION_VARINT_ENCODING: DracoVersion = DracoVersion(2, 0);
// Version that introduced varint for unique_id in attributes (v1.3).
export const VERSION_VARINT_UNIQUE_ID: DracoVersion = DracoVersion(1, 3);

// (major, minor) >= target.
export function versionAtLeast(major: u8, minor: u8, target: DracoVersion): bool {
    return major > target.major || (major == target.major && minor >= target.minor);
}

// (major, minor) < target.
export function versionLessThan(major: u8, minor: u8, target: DracoVersion): bool {
    return major < target.major || (major == target.major && minor < target.minor);
}

// v2.0+ uses varint encoding for metadata fields.
export function usesVarintEncoding(major: u8, _minor: u8): bool {
    return major >= VERSION_VARINT_ENCODING.major;
}

// v1.3+ includes header flags.
export function hasHeaderFlags(major: u8, minor: u8): bool {
    return versionAtLeast(major, minor, VERSION_FLAGS_INTRODUCED);
}

// v1.3+ uses varint for attribute unique_id.
export function usesVarintUniqueId(major: u8, minor: u8): bool {
    return versionAtLeast(major, minor, VERSION_VARINT_UNIQUE_ID);
}

// The coder a stream is written with.
export enum EncodeTarget {
    MeshEdgebreaker,
    MeshSequential,
    PointCloudSequential,
    PointCloudKdTree,
}

// `{:?}` of an EncodeTarget.
export function encodeTargetDebug(target: EncodeTarget): string {
    switch (target) {
        case EncodeTarget.MeshEdgebreaker: return "MeshEdgebreaker";
        case EncodeTarget.MeshSequential: return "MeshSequential";
        case EncodeTarget.PointCloudSequential: return "PointCloudSequential";
        case EncodeTarget.PointCloudKdTree: return "PointCloudKdTree";
    }
    return "";
}

// The bitstream versions the encoder writes
// for the target and reads back, newest first.
export function claimedVersions(target: EncodeTarget): Array<DracoVersion> {
    const out = new Array<DracoVersion>();
    switch (target) {
        case EncodeTarget.MeshEdgebreaker: {
            out.push(DracoVersion(2, 2));
            out.push(DracoVersion(2, 1));
            out.push(DracoVersion(2, 0));
            out.push(DracoVersion(1, 2));
            out.push(DracoVersion(1, 1));
            break;
        }
        case EncodeTarget.MeshSequential: {
            out.push(DracoVersion(2, 2));
            out.push(DracoVersion(1, 3));
            break;
        }
        case EncodeTarget.PointCloudSequential: {
            out.push(DracoVersion(2, 3));
            out.push(DracoVersion(1, 3));
            break;
        }
        case EncodeTarget.PointCloudKdTree: {
            out.push(DracoVersion(2, 3));
            break;
        }
    }
    return out;
}

// `EncodeTarget::default_version`: the version written when none is asked for.
export function defaultVersion(target: EncodeTarget): DracoVersion {
    switch (target) {
        case EncodeTarget.MeshEdgebreaker:
        case EncodeTarget.MeshSequential:
            return DEFAULT_MESH_VERSION;
    }
    return DEFAULT_POINT_CLOUD_VERSION;
}

// Rejects a target bitstream version the encoder does not write for `target`.
// `(0, 0)` means "use the default" and is accepted.
export function validateEncodableVersion(major: u8, minor: u8, target: EncodeTarget): Result<bool> {
    if (major == 0 && minor == 0) {
        return Result.okv<bool>(true);
    }
    const claimed = claimedVersions(target);
    for (let i = 0; i < claimed.length; i++) {
        if (claimed[i].major == major && claimed[i].minor == minor) return Result.okv<bool>(true);
    }
    const parts = new Array<string>();
    for (let i = 0; i < claimed.length; i++) {
        parts.push(claimed[i].major.toString() + "." + claimed[i].minor.toString());
    }
    return DracoError.unsupportedVersion(
        "Cannot encode bitstream version " + major.toString() + "." + minor.toString() +
        " for " + encodeTargetDebug(target) + ": supported are " + parts.join(", "),
    ).fail<bool>();
}

// Packs `(major, minor)` into the `0xMMmm` value used for ordered comparisons.
export function bitstreamVersion(major: u8, minor: u8): u16 {
    return ((<u16>major) << 8) | <u16>minor;
}

// Whether an encode targeting this version hands prediction schemes only the
// portable attribute copy (`major == 0` = "whichever default applies").
export function bindsPortableParentOnly(major: u8, minor: u8): bool {
    return major == 0 || bitstreamVersion(major, minor) >= 0x0200;
}
