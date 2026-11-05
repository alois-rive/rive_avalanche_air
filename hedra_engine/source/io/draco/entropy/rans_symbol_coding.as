// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// RAnsSymbol and the precision computations shared by the symbol encoder and
// decoder (Draco's `rans_symbol_coding.h`).

// A symbol's probability and cumulative probability (a value struct).
export struct RAnsSymbol {
    prob: u32 = 0;
    cumProb: u32 = 0;
    constructor(prob: u32, cumProb: u32) {
        this.prob = prob;
        this.cumProb = cumProb;
    }
}

export function computeRansUnclampedPrecision(symbolsBitLength: u32): u32 {
    return (3 * symbolsBitLength) / 2;
}

export function computeRansPrecisionFromUniqueSymbolsBitLength(symbolsBitLength: u32): u32 {
    const prec = computeRansUnclampedPrecision(symbolsBitLength);
    return prec < 12 ? 12 : prec > 20 ? 20 : prec;
}

export function approximateRansFrequencyTableBits(maxValue: u32, numUniqueSymbols: u32): u64 {
    const diff: u32 = maxValue > numUniqueSymbols ? maxValue - numUniqueSymbols : 0;
    const tableZeroFrequencyBits: u32 = 8 * (numUniqueSymbols + diff / 64);
    return <u64>(8 * numUniqueSymbols + tableZeroFrequencyBits);
}
