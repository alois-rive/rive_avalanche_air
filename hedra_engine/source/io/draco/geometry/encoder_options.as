// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The integer option bag that configures Draco encoding. Global options apply
// to the whole geometry; attribute options override a value for one attribute
// id and fall back to the global value when unset.
//
// The maps are copy-on-write: `clone()` shares the maps and counts the
// sharers; a setter on a bag whose maps are shared copies them first, so a
// clone and its source never see each other's writes. There is no drop, so
// a dropped clone keeps counting (the next write then copies once more than
// strictly needed; values are unaffected). `sharesMapsWith` tells whether
// two bags share their maps. A forced encoding method is read with
// `hasEncodingMethod()` + `getEncodingMethod()`; the version is a
// DracoVersion.

import { DracoVersion } from "../core/version";

class Inner {
    globalOptions: Map<string, i32> = new Map<string, i32>();
    attributeOptions: Map<i32, Map<string, i32>> = new Map<i32, Map<string, i32>>();
    sharers: i32 = 1;

    deepCopy(): Inner {
        const c = new Inner();
        const gk = this.globalOptions.keys();
        for (let i = 0; i < gk.length; i++) c.globalOptions.set(gk[i], this.globalOptions.get(gk[i]));
        const ak = this.attributeOptions.keys();
        for (let i = 0; i < ak.length; i++) {
            const src = this.attributeOptions.get(ak[i]);
            const dst = new Map<string, i32>();
            const k = src.keys();
            for (let j = 0; j < k.length; j++) dst.set(k[j], src.get(k[j]));
            c.attributeOptions.set(ak[i], dst);
        }
        return c;
    }
}

export class EncoderOptions {
    private inner: Inner = new Inner();

    constructor() {}

    // Arc::make_mut: the maps this bag may write, copied first when shared.
    private makeMut(): Inner {
        if (this.inner.sharers > 1) {
            this.inner.sharers -= 1;
            this.inner = this.inner.deepCopy();
        }
        return this.inner;
    }

    // A copy that shares the maps until one side writes.
    clone(): EncoderOptions {
        const o = new EncoderOptions();
        o.inner = this.inner;
        this.inner.sharers += 1;
        return o;
    }

    // Whether both bags share the same maps.
    sharesMapsWith(other: EncoderOptions): bool {
        return this.inner == other.inner;
    }

    // The configured encoding speed, defaulting to 5.
    getEncodingSpeed(): i32 {
        return this.getGlobalInt("encoding_speed", 5);
    }

    // The configured decoding speed target, defaulting to 5.
    getDecodingSpeed(): i32 {
        return this.getGlobalInt("decoding_speed", 5);
    }

    // The maximum of both speeds (C++ ExpertEncoder::GetSpeed), 5 when neither is set.
    getSpeed(): i32 {
        const g = this.inner.globalOptions;
        const encodingSpeed = g.has("encoding_speed") ? g.get("encoding_speed") : -1;
        const decodingSpeed = g.has("decoding_speed") ? g.get("decoding_speed") : -1;
        const maxSpeed = max(encodingSpeed, decodingSpeed);
        if (maxSpeed == -1) {
            return 5;
        }
        return maxSpeed;
    }

    // Sets both speeds from a draco_encoder-style compression level
    // (`speed = 10 - level`, not range-checked).
    setCompressionLevel(level: i32): void {
        const speed = 10 - level;
        this.setGlobalInt("encoding_speed", speed);
        this.setGlobalInt("decoding_speed", speed);
    }

    // `10 - getSpeed()`.
    getCompressionLevel(): i32 {
        return 10 - this.getSpeed();
    }

    // Sets `quantization_bits` for one attribute id.
    setAttributeQuantization(attId: i32, quantizationBits: i32): void {
        this.setAttributeInt(attId, "quantization_bits", quantizationBits);
    }

    // The `quantization_bits` for one attribute id, or -1 if none was set
    // for it or globally.
    getAttributeQuantization(attId: i32): i32 {
        return this.getAttributeInt(attId, "quantization_bits", -1);
    }

    // The forced prediction scheme, or -1 for the encoder default.
    getPredictionScheme(): i32 {
        return this.getGlobalInt("prediction_scheme", -1);
    }

    // The prediction scheme forced for one attribute, falling back to the
    // global setting and then to -1.
    getAttributePredictionScheme(attId: i32): i32 {
        return this.getAttributeInt(attId, "prediction_scheme", -1);
    }

    // Forces a prediction scheme by numeric Draco method id.
    setPredictionScheme(value: i32): void {
        this.setGlobalInt("prediction_scheme", value);
    }

    // Whether an encoding method was forced.
    hasEncodingMethod(): bool {
        return this.inner.globalOptions.has("encoding_method");
    }

    // The forced encoding method; check hasEncodingMethod() first (0 when unset).
    getEncodingMethod(): i32 {
        const g = this.inner.globalOptions;
        return g.has("encoding_method") ? g.get("encoding_method") : 0;
    }

    // Forces an encoding method by numeric Draco method id.
    setEncodingMethod(value: i32): void {
        this.setGlobalInt("encoding_method", value);
    }

    // Sets the target Draco bitstream version.
    setVersion(major: u8, minor: u8): void {
        this.setGlobalInt("version_major", <i32>major);
        this.setGlobalInt("version_minor", <i32>minor);
    }

    // The target Draco bitstream version, or (0, 0) for the default.
    getVersion(): DracoVersion {
        const major = this.getGlobalInt("version_major", -1);
        const minor = this.getGlobalInt("version_minor", -1);
        if (major == -1 || minor == -1) {
            return DracoVersion(0, 0);
        }
        return DracoVersion(<u8>major, <u8>minor);
    }

    // Sets a global integer option.
    setGlobalInt(key: string, value: i32): void {
        this.makeMut().globalOptions.set(key, value);
    }

    // A global integer option or the supplied default.
    getGlobalInt(key: string, defaultVal: i32): i32 {
        const g = this.inner.globalOptions;
        return g.has(key) ? g.get(key) : defaultVal;
    }

    // Sets an integer option for one attribute id.
    setAttributeInt(attId: i32, key: string, value: i32): void {
        const inner = this.makeMut();
        if (!inner.attributeOptions.has(attId)) {
            inner.attributeOptions.set(attId, new Map<string, i32>());
        }
        inner.attributeOptions.get(attId).set(key, value);
    }

    // An attribute integer option, falling back to the global value.
    getAttributeInt(attId: i32, key: string, defaultVal: i32): i32 {
        const a = this.inner.attributeOptions;
        if (a.has(attId)) {
            const opts = a.get(attId);
            if (opts.has(key)) {
                return opts.get(key);
            }
        }
        return this.getGlobalInt(key, defaultVal);
    }
}
