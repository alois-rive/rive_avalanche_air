// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Integer-only math helpers.

// floor(sqrt(number)), bit-exact and platform independent (Newton's method
// from a power-of-two estimate). No step can overflow u64 for any input: the
// estimate is at most 2^32 and the first Newton step stays below 2^32 when
// it starts there (verified with overflow checks up to u64::MAX; tests/io/draco_bitstream_fuzz_test.as).
export function intSqrt(number: u64): u64 {
    if (number == 0) {
        return 0;
    }
    // First estimate good initial value of the square root as log2(number).
    let actNumber = number;
    let squareRoot: u64 = 1;
    while (actNumber >= 2) {
        // Double the square root until |square_root * square_root > number|.
        squareRoot *= 2;
        actNumber /= 4;
    }
    // Newton's (Babylonian) method to find the true floor(sqrt()).
    while (true) {
        squareRoot = (squareRoot + number / squareRoot) / 2;
        if (squareRoot * squareRoot <= number) {
            break;
        }
    }
    return squareRoot;
}
