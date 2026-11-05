// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The always-on backstop against a reservation nothing backs (a header naming
// gigabytes over a stream that carries none of them). Sizes are u64.

import { DracoError, ErrorKind, Status, okStatus } from "./status";

// How many bytes of allocation one byte of input may back.
export const MAX_ALLOCATED_BYTES_PER_INPUT_BYTE: u64 = 1 << 20;

// The most any decode may reserve regardless of its input size.
export const MAX_UNBACKED_BYTES: u64 = (<u64>256) << 20;

// Refuses a cumulative reservation of `requestedBytes` that a
// `streamBytes`-byte stream cannot back.
export function ensureAllocationIsBacked(requestedBytes: u64, streamBytes: u64): Status {
    if (requestedBytes > MAX_UNBACKED_BYTES || requestedBytes / MAX_ALLOCATED_BYTES_PER_INPUT_BYTE > streamBytes) {
        return DracoError.allocationExceedsInput(requestedBytes, streamBytes).fail<bool>();
    }
    return okStatus();
}

// Refuses a declared symbol count larger than the stream could carry at one
// bit per symbol.
export function ensureSymbolsAreBacked(count: u64, streamBytes: u64): Status {
    // streamBytes * 8, saturating at u64::MAX.
    const capacity: u64 = streamBytes > u64.MAX_VALUE / 8 ? u64.MAX_VALUE : streamBytes * 8;
    if (count > capacity) {
        return DracoError.create(
            ErrorKind.AllocationExceedsInput,
            "declared " + count.toString() + " symbols, more than the " + streamBytes.toString() +
            " byte stream could carry at one bit each",
        ).fail<bool>();
    }
    return okStatus();
}
