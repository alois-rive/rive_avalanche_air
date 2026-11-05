// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Shannon entropy estimation (Draco's `shannon_entropy.h`). The encoder uses
// these estimates to choose between coding schemes and to size rANS tables.
//
// f64 `log2` is appleLog2 (core/base/libm.as), which reproduces Apple's
// libsystem_m; musl's `Math.log2` differs from it on ~0.02% of inputs. The
// golden tests check the estimates against recorded reference values.

import { f64ToI64, panic } from "../../../../base/util";
import { appleLog2 } from "../../../../base/libm";
import { approximateRansFrequencyTableBits } from "./rans_symbol_coding";

// Largest symbol held in the dense frequency table; anything at or above it
// goes to the sparse side table (2^18: the symbol coder's own raw threshold).
const MAX_DENSE_SYMBOL: i64 = 1 << 18;

// Running totals of an entropy estimate (a value struct, zeroed by default).
export struct EntropyData {
    entropyNorm: f64 = 0;
    numValues: i32 = 0;
    maxSymbol: i32 = 0;
    numUniqueSymbols: i32 = 0;
    constructor(entropyNorm: f64, numValues: i32, maxSymbol: i32, numUniqueSymbols: i32) {
        this.entropyNorm = entropyNorm;
        this.numValues = numValues;
        this.maxSymbol = maxSymbol;
        this.numUniqueSymbols = numUniqueSymbols;
    }
}

export class ShannonEntropyTracker {
    entropyData: EntropyData = EntropyData(0, 0, 0, 0);
    frequencies: Array<i32> = [];
    // Frequencies of symbols at or above MAX_DENSE_SYMBOL.
    sparseFrequencies: Map<u32, i32> = new Map<u32, i32>();
    // Memoised exact `f * log2(f)` keyed by integer frequency.
    entropyNormCache: Array<f64> = [];
    // The last (n, n * log2(n)) computed for a whole value count.
    numValuesNormCacheN: i32 = 0;
    numValuesNormCacheV: f64 = 0.0;

    constructor() {}

    // `f * log2(f)` for a non-negative integer frequency (0.0 for f < 2).
    private fTimesLog2F(f: i32): f64 {
        if (f < 2) {
            return 0.0;
        }
        const i = f;
        const cache = this.entropyNormCache;
        if (i >= cache.length) {
            const oldLen = cache.length;
            cache.length = i + 1;
            for (let j = oldLen; j <= i; j++) {
                const jf = <f64>j;
                cache[j] = jf * appleLog2(jf);
            }
        }
        return cache[i];
    }

    push(symbols: Array<u32>): EntropyData {
        return this.updateSymbols(symbols, true);
    }

    peek(symbols: Array<u32>): EntropyData {
        return this.updateSymbols(symbols, false);
    }

    private updateSymbols(symbols: Array<u32>, pushChanges: bool): EntropyData {
        let retData = this.entropyData;
        retData.numValues += symbols.length;

        for (let i = 0; i < symbols.length; i++) {
            const symbol = unchecked(symbols[i]);
            const index = <i64>symbol;

            // Grow the dense table only when the symbols are really being
            // added; while peeking, an uncovered symbol's count is how often
            // it already appeared in this same call.
            let frequency: i32 = 0;
            if (index >= MAX_DENSE_SYMBOL) {
                frequency = this.sparseFrequencies.has(symbol) ? this.sparseFrequencies.get(symbol) : 0;
            } else if (index < <i64>this.frequencies.length) {
                frequency = this.frequencies[<i32>index];
            } else if (pushChanges) {
                this.frequencies.length = <i32>index + 1;
            } else {
                for (let k = 0; k < i; k++) {
                    if (unchecked(symbols[k]) == symbol) {
                        frequency += 1;
                    }
                }
            }

            let oldSymbolEntropyNorm: f64 = 0.0;
            if (frequency > 1) {
                oldSymbolEntropyNorm = this.fTimesLog2F(frequency);
            } else if (frequency == 0) {
                retData.numUniqueSymbols += 1;
                if (<i32>symbol > retData.maxSymbol) {
                    retData.maxSymbol = <i32>symbol;
                }
            }

            // Modify the frequency during the loop, revert afterwards when
            // peeking (like C++).
            frequency += 1;
            if (index >= MAX_DENSE_SYMBOL) {
                this.sparseFrequencies.set(symbol, frequency);
            } else if (index < <i64>this.frequencies.length) {
                this.frequencies[<i32>index] = frequency;
            }
            const newSymbolEntropyNorm = this.fTimesLog2F(frequency);

            retData.entropyNorm += newSymbolEntropyNorm - oldSymbolEntropyNorm;
        }

        if (pushChanges) {
            this.entropyData = retData;
        } else {
            // Revert frequency table changes. Symbols the table does not
            // cover were never written above.
            for (let i = 0; i < symbols.length; i++) {
                const symbol = unchecked(symbols[i]);
                const index = <i64>symbol;
                if (index >= MAX_DENSE_SYMBOL) {
                    if (this.sparseFrequencies.has(symbol)) {
                        const f = this.sparseFrequencies.get(symbol) - 1;
                        if (f == 0) {
                            this.sparseFrequencies.delete(symbol);
                        } else {
                            this.sparseFrequencies.set(symbol, f);
                        }
                    }
                } else if (index < <i64>this.frequencies.length) {
                    this.frequencies[<i32>index] = this.frequencies[<i32>index] - 1;
                }
            }
        }

        return retData;
    }

    getNumberOfDataBits(): i64 {
        return ShannonEntropyTracker.getNumberOfDataBitsStatic(this.entropyData);
    }

    // getNumberOfDataBitsStatic with the `n * log2(n)` term memoised across
    // calls sharing `n` (identical arithmetic, identical bits).
    numberOfDataBits(entropyData: EntropyData): i64 {
        if (entropyData.numValues < 2) {
            return 0;
        }
        if (this.numValuesNormCacheN != entropyData.numValues) {
            const n = <f64>entropyData.numValues;
            this.numValuesNormCacheN = entropyData.numValues;
            this.numValuesNormCacheV = n * appleLog2(n);
        }
        return f64ToI64(Math.ceil(this.numValuesNormCacheV - entropyData.entropyNorm));
    }

    getNumberOfRAnsTableBits(): i64 {
        return ShannonEntropyTracker.getNumberOfRAnsTableBitsStatic(this.entropyData);
    }

    static getNumberOfDataBitsStatic(entropyData: EntropyData): i64 {
        if (entropyData.numValues < 2) {
            return 0;
        }

        const numValues = <f64>entropyData.numValues;
        const bits = numValues * appleLog2(numValues) - entropyData.entropyNorm;
        return f64ToI64(Math.ceil(bits));
    }

    static getNumberOfRAnsTableBitsStatic(entropyData: EntropyData): i64 {
        // `max_symbol + 1` wraps like upstream's `int` arithmetic (a cost
        // heuristic, not a bitstream value).
        return <i64>approximateRansFrequencyTableBits(
            <u32>(entropyData.maxSymbol + 1),
            <u32>entropyData.numUniqueSymbols,
        );
    }
}

// Largest `max_value` for which the estimators below build a dense
// frequency table (one slot per possible value, 0..=max_value). Past it the
// table would cost the wasm heap up to 16 GB (AS traps at 2^28 slots), so
// they count over a sorted copy instead.
export const DENSE_FREQUENCY_TABLE_LIMIT: u64 = 1 << 20;

// The count of every distinct symbol, in ascending symbol order: what a
// dense `frequencies[0..=max_value]` table holds once its zero slots are
// skipped. A loop over these counts visits the same values in the same order
// as a loop over the table, so any f64 sum over them is bit-identical.
// A symbol past `maxValue` panics as an out-of-bounds index.
export function sortedSymbolCounts(symbols: Array<u32>, maxValue: u64): Array<u32> {
    const sorted = symbols.slice(0);
    sorted.sort(); // plain numbers: ascending, stability irrelevant
    const n = sorted.length;
    const counts = new Array<u32>();
    if (n == 0) return counts;
    const top = <u64>unchecked(sorted[n - 1]);
    if (top > maxValue) {
        panic("index out of bounds: the len is " + (maxValue + 1).toString() + " but the index is " + top.toString());
    }
    let i = 0;
    while (i < n) {
        const s = unchecked(sorted[i]);
        let j = i + 1;
        while (j < n && unchecked(sorted[j]) == s) j++;
        counts.push(<u32>(j - i));
        i = j;
    }
    return counts;
}

// Shannon entropy of `symbols`; the optional out-param (a 1-element
// Int32Array, or null) receives the number of unique symbols.
export function computeShannonEntropy(
    symbols: Array<u32>,
    maxValue: i32,
    outNumUniqueSymbols: Int32Array? = null,
): i64 {
    if (<u64>maxValue >= DENSE_FREQUENCY_TABLE_LIMIT) {
        return computeShannonEntropySorted(symbols, maxValue, outNumUniqueSymbols);
    }
    let numUniqueSymbols: i32 = 0;
    const symbolFrequencies = new Array<i32>(maxValue + 1);

    for (let i = 0; i < symbols.length; i++) {
        const s = <i32>unchecked(symbols[i]);
        symbolFrequencies[s] = symbolFrequencies[s] + 1;
    }

    let totalBits: f64 = 0.0;
    const numSymbolsD = <f64>symbols.length;

    for (let i = 0; i < symbolFrequencies.length; i++) {
        const freq = unchecked(symbolFrequencies[i]);
        if (freq > 0) {
            numUniqueSymbols += 1;
            totalBits += (<f64>freq) * appleLog2((<f64>freq) / numSymbolsD);
        }
    }

    if (outNumUniqueSymbols != null) {
        outNumUniqueSymbols[0] = numUniqueSymbols;
    }

    return f64ToI64(-totalBits);
}

// computeShannonEntropy past DENSE_FREQUENCY_TABLE_LIMIT: the same sum over
// the same counts in the same order (see sortedSymbolCounts).
function computeShannonEntropySorted(
    symbols: Array<u32>,
    maxValue: i32,
    outNumUniqueSymbols: Int32Array?,
): i64 {
    const counts = sortedSymbolCounts(symbols, <u64>maxValue);
    let totalBits: f64 = 0.0;
    const numSymbolsD = <f64>symbols.length;
    for (let i = 0; i < counts.length; i++) {
        const freq = <i32>unchecked(counts[i]);
        totalBits += (<f64>freq) * appleLog2((<f64>freq) / numSymbolsD);
    }
    if (outNumUniqueSymbols != null) {
        outNumUniqueSymbols[0] = counts.length;
    }
    return f64ToI64(-totalBits);
}

export function computeBinaryShannonEntropy(numValues: u32, numTrueValues: u32): f64 {
    if (numValues == 0) {
        return 0.0;
    }

    if (numTrueValues == 0 || numValues == numTrueValues) {
        return 0.0;
    }

    const trueFreq = (<f64>numTrueValues) / (<f64>numValues);
    const falseFreq = 1.0 - trueFreq;

    return -(trueFreq * appleLog2(trueFreq) + falseFreq * appleLog2(falseFreq));
}
