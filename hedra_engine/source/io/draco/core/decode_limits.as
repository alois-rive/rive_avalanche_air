// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Caller-set ceilings on what one decode may produce. Exceeding one fails the
// decode with ErrorKind.LimitExceeded (the caller's policy), as opposed to
// AllocationExceedsInput (a malformed stream, see decode_budget).
//
// The `with*` setters return a modified copy and leave the receiver alone.

import { debugStruct } from "../../../../base/fmt";
import { DracoError, ErrorKind, Status, okStatus } from "./status";

export class DecodeLimits {
    maxPoints: u64 = 256_000_000;
    maxFaces: u64 = 512_000_000;
    maxDecodedBytes: u64 = (<u64>2) << 30;

    // The default limits.
    static defaults(): DecodeLimits {
        return new DecodeLimits();
    }

    // No ceilings at all.
    static permissive(): DecodeLimits {
        const l = new DecodeLimits();
        l.maxPoints = u64.MAX_VALUE;
        l.maxFaces = u64.MAX_VALUE;
        l.maxDecodedBytes = u64.MAX_VALUE;
        return l;
    }

    // Tight ceilings for fuzzing.
    static fuzzing(): DecodeLimits {
        const l = new DecodeLimits();
        l.maxPoints = 1 << 20;
        l.maxFaces = 1 << 20;
        l.maxDecodedBytes = (<u64>64) << 20;
        return l;
    }

    clone(): DecodeLimits {
        const l = new DecodeLimits();
        l.maxPoints = this.maxPoints;
        l.maxFaces = this.maxFaces;
        l.maxDecodedBytes = this.maxDecodedBytes;
        return l;
    }

    equals(o: DecodeLimits): bool {
        return this.maxPoints == o.maxPoints && this.maxFaces == o.maxFaces && this.maxDecodedBytes == o.maxDecodedBytes;
    }

    // Debug text listing every limit.
    debug(): string {
        return debugStruct(
            "DecodeLimits",
            ["max_points", "max_faces", "max_decoded_bytes"],
            [this.maxPoints.toString(), this.maxFaces.toString(), this.maxDecodedBytes.toString()],
        );
    }

    checkPoints(points: u64): Status {
        return DecodeLimits.check("points", points, this.maxPoints);
    }

    checkFaces(faces: u64): Status {
        return DecodeLimits.check("faces", faces, this.maxFaces);
    }

    checkDecodedBytes(bytes: u64): Status {
        return DecodeLimits.check("decoded attribute bytes", bytes, this.maxDecodedBytes);
    }

    private static check(what: string, value: u64, ceiling: u64): Status {
        if (value > ceiling) {
            return DracoError.create(
                ErrorKind.LimitExceeded,
                "stream decodes " + value.toString() + " " + what + ", over the caller's ceiling of " + ceiling.toString(),
            ).fail<bool>();
        }
        return okStatus();
    }

    // Sets maxPoints (on a copy).
    withMaxPoints(value: u64): DecodeLimits {
        const l = this.clone();
        l.maxPoints = value;
        return l;
    }

    // Sets maxFaces (on a copy).
    withMaxFaces(value: u64): DecodeLimits {
        const l = this.clone();
        l.maxFaces = value;
        return l;
    }

    // Sets maxDecodedBytes (on a copy).
    withMaxDecodedBytes(value: u64): DecodeLimits {
        const l = this.clone();
        l.maxDecodedBytes = value;
        return l;
    }
}
