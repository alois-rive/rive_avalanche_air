// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Scalar quantization helpers.
//
// Quantizer and its inverse map floating-point values to and from a
// fixed-point integer grid defined by an origin and range. All arithmetic is
// f32, in a fixed operation order so results are reproducible bit for bit.

import { f32ToI32 } from "../../../../base/util";

export class Quantizer {
    inverseDelta: f32 = 0;

    constructor() {}

    init(range: f32, maxQuantizedValue: i32): void {
        if (range > <f32>0) {
            this.inverseDelta = <f32>maxQuantizedValue / range;
        } else {
            this.inverseDelta = 0;
        }
    }

    initWithDelta(delta: f32): void {
        if (delta > <f32>0) {
            this.inverseDelta = <f32>1 / delta;
        } else {
            this.inverseDelta = 0;
        }
    }

    // floor(val * inverse_delta + 0.5) as i32, saturating.
    quantizeFloat(val: f32): i32 {
        const v: f32 = val * this.inverseDelta;
        const scaled: f32 = v + <f32>0.5;
        const truncated = f32ToI32(scaled);
        if (<f32>truncated > scaled) {
            // saturating_sub(1)
            return truncated == i32.MIN_VALUE ? i32.MIN_VALUE : truncated - 1;
        }
        return truncated;
    }

    clone(): Quantizer {
        const q = new Quantizer();
        q.inverseDelta = this.inverseDelta;
        return q;
    }
}

export class Dequantizer {
    delta: f32 = 0;

    constructor() {}

    init(range: f32, maxQuantizedValue: i32): bool {
        if (maxQuantizedValue > 0) {
            this.delta = range / <f32>maxQuantizedValue;
            return true;
        }
        return false;
    }

    initWithDelta(delta: f32): bool {
        if (delta >= <f32>0) {
            this.delta = delta;
            return true;
        }
        return false;
    }

    dequantizeFloat(val: i32): f32 {
        return <f32>val * this.delta;
    }

    clone(): Dequantizer {
        const d = new Dequantizer();
        d.delta = this.delta;
        return d;
    }
}
