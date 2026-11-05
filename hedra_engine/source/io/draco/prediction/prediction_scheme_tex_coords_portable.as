// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The portable texture-coordinate predictor.
//
// Predicts UV coordinates from the triangle's 3D positions using integer-only
// arithmetic (`intSqrt`, wrapping i64/u64 math) for bit-exact results across
// platforms. The current tex-coord prediction scheme.
//
// Upstream keeps the prediction itself in one place, and so does this file:
// MeshPredictionSchemeTexCoordsPortablePredictor carries the whole computation
// and both schemes call it, with `isEncoder` selecting only the orientation
// handling (the encoder tries both orientations and records the closer one;
// the decoder pops the recorded choice).
//
// The i64/u64 arithmetic below wraps on purpose; division uses
// `wrappingDivI64` (i64.MIN / -1 would trap).

import { panic } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { EncoderBuffer } from "../core/encoder_buffer";
import { intSqrt } from "../core/math_utils";
import { DracoError, Status, okStatus } from "../core/status";
import { bitstreamVersion as packVersion } from "../core/version";
import { RAnsBitDecoder } from "../entropy/rans_bit_decoder";
import { RAnsBitEncoder } from "../entropy/rans_bit_encoder";
import { GeometryAttributeType, geometryAttributeTypeDebug } from "../geometry/geometry_attribute";
import { CornerIndex, INVALID_ATTRIBUTE_VALUE_INDEX } from "../geometry/geometry_indices";
import { PredictionParent } from "../geometry/portable_attribute";
import { MeshPredictionSchemeData } from "../mesh/mesh_prediction_scheme_data";
import {
    EntryToPointIdMap,
    PredictionSchemeDecoder,
    PredictionSchemeEncoder,
    PredictionSchemeEncodingTransform,
    PredictionSchemeMethod,
    PredictionSchemeTransformType,
} from "./prediction_scheme";
import { PredictionSchemeWrapDecodingTransform, PredictionSchemeWrapEncodingTransform } from "./prediction_scheme_wrap";

// 3- and 2-component i64 vectors for the integer vector helpers.
export struct I64Vec3 {
    x: i64 = 0;
    y: i64 = 0;
    z: i64 = 0;
    constructor(x: i64, y: i64, z: i64) {
        this.x = x;
        this.y = y;
        this.z = z;
    }
}

export struct I64Vec2 {
    x: i64 = 0;
    y: i64 = 0;
    constructor(x: i64, y: i64) {
        this.x = x;
        this.y = y;
    }
}

// `i64::wrapping_div`: `i64::MIN / -1` is `i64::MIN` (AS would trap).
// @ts-ignore: decorator
@inline
export function wrappingDivI64(a: i64, b: i64): i64 {
    if (b == -1) return -a;
    return a / b;
}

// `i64::unsigned_abs`.
// @ts-ignore: decorator
@inline
function unsignedAbs(v: i64): u64 {
    return v < 0 ? <u64>(-v) : <u64>v;
}

// These integer vector helpers wrap, matching C++ Draco's int64 intermediate
// math (two's-complement wraparound) instead of panicking on malformed input.
export function vec3Sub(a: I64Vec3, b: I64Vec3): I64Vec3 {
    return I64Vec3(a.x - b.x, a.y - b.y, a.z - b.z);
}
export function vec3Add(a: I64Vec3, b: I64Vec3): I64Vec3 {
    return I64Vec3(a.x + b.x, a.y + b.y, a.z + b.z);
}
export function vec3SquaredNorm(a: I64Vec3): u64 {
    return <u64>(a.x * a.x + a.y * a.y + a.z * a.z);
}
export function vec3Dot(a: I64Vec3, b: I64Vec3): i64 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}
export function vec3MulScalar(a: I64Vec3, s: i64): I64Vec3 {
    return I64Vec3(a.x * s, a.y * s, a.z * s);
}
export function vec3DivScalar(a: I64Vec3, s: i64): I64Vec3 {
    return I64Vec3(wrappingDivI64(a.x, s), wrappingDivI64(a.y, s), wrappingDivI64(a.z, s));
}
export function vec2Sub(a: I64Vec2, b: I64Vec2): I64Vec2 {
    return I64Vec2(a.x - b.x, a.y - b.y);
}
export function vec2Add(a: I64Vec2, b: I64Vec2): I64Vec2 {
    return I64Vec2(a.x + b.x, a.y + b.y);
}
export function vec2Mul(a: I64Vec2, s: i64): I64Vec2 {
    return I64Vec2(a.x * s, a.y * s);
}
export function vec2SquaredNorm(a: I64Vec2): i64 {
    return a.x * a.x + a.y * a.y;
}

function exceedsI64ProductLimitU64(aAbs: u64, bAbs: u64): bool {
    return aAbs != 0 && bAbs > (<u64>i64.MAX_VALUE) / aAbs;
}

function vec2Absmax(v: I64Vec2): u64 {
    const a = unsignedAbs(v.x);
    const b = unsignedAbs(v.y);
    return a > b ? a : b;
}

function vec3Absmax(v: I64Vec3): u64 {
    let m = unsignedAbs(v.x);
    const b = unsignedAbs(v.y);
    if (b > m) m = b;
    const c = unsignedAbs(v.z);
    if (c > m) m = c;
    return m;
}

// The three overflow guards upstream applies before the scaled-space
// multiplications; the only refusals the geometric branch has.
export function texCoordsPredictionOverflowChecks(
    nUv: I64Vec2,
    pnUv: I64Vec2,
    pn: I64Vec3,
    cnDotPn: i64,
    pnNorm2Squared: u64,
): bool {
    const nUvAbsmax = vec2Absmax(nUv);
    if (exceedsI64ProductLimitU64(nUvAbsmax, pnNorm2Squared)) {
        return false;
    }

    const pnUvAbsmax = vec2Absmax(pnUv);
    if (pnUvAbsmax == 0 || exceedsI64ProductLimitU64(unsignedAbs(cnDotPn), pnUvAbsmax)) {
        return false;
    }

    const pnAbsmax = vec3Absmax(pn);
    if (pnAbsmax == 0 || exceedsI64ProductLimitU64(unsignedAbs(cnDotPn), pnAbsmax)) {
        return false;
    }

    return true;
}

// `(a + b) / d` with the combine in unsigned arithmetic, then an i64 divide
// (a plain divide: i64::MIN / -1 traps).
export function vec2WrappingAddDivU64(a: I64Vec2, b: I64Vec2, divisor: u64): I64Vec2 {
    const d = <i64>divisor;
    return I64Vec2(<i64>(<u64>a.x + <u64>b.x) / d, <i64>(<u64>a.y + <u64>b.y) / d);
}

// `(a - b) / d`, the subtracting twin.
export function vec2WrappingSubDivU64(a: I64Vec2, b: I64Vec2, divisor: u64): I64Vec2 {
    const d = <i64>divisor;
    return I64Vec2(<i64>(<u64>a.x - <u64>b.x) / d, <i64>(<u64>a.y - <u64>b.y) / d);
}

// The shared tex-coord prediction (exported for the tests, which drive it
// directly).
export class MeshPredictionSchemeTexCoordsPortablePredictor {
    posParent: PredictionParent? = null;
    meshData: MeshPredictionSchemeData? = null;
    // Encoded / decoded UV flips: the encoder pushes one per predicted entry
    // (walking backwards), the decoder pops one (walking forwards).
    orientations: Array<bool> = [];
    // Scratch for the position reads.
    private posScratch: StaticArray<i64> = new StaticArray<i64>(3);
    // Results of the lookups below, valid when the lookup returned true.
    private lastPos: I64Vec3 = I64Vec3(0, 0, 0);
    private lastUv: I64Vec2 = I64Vec2(0, 0);

    constructor() {}

    init(meshData: MeshPredictionSchemeData): void {
        this.meshData = meshData.clone();
    }

    setParentAttribute(parent: PredictionParent): Status {
        if (parent.attributeType() != GeometryAttributeType.Position) {
            return DracoError.invalidParameter(
                `Portable texture-coordinate prediction needs a position parent, got ${geometryAttributeTypeDebug(parent.attributeType())}`,
            ).fail<bool>();
        }
        if (parent.numComponents() != 3) {
            return DracoError.invalidParameter(
                `Portable texture-coordinate prediction needs a 3-component parent, got ${parent.numComponents()}`,
            ).fail<bool>();
        }
        this.posParent = parent;
        return okStatus();
    }

    isInitialized(): bool {
        return this.posParent != null && this.meshData != null;
    }

    // The position of an entry into `lastPos`; false for a point outside the
    // entry map, one the position attribute maps nowhere, or a value no i64
    // can hold.
    private getPositionForEntryId(entryId: i32, map: EntryToPointIdMap): bool {
        if (entryId < 0) return false;
        const pointId = map.get(entryId);
        if (pointId < 0) return false;
        const parent = this.posParent;
        if (parent == null) return false;
        const valIndex = parent.mappedIndex(<u32>pointId);
        if (valIndex == INVALID_ATTRIBUTE_VALUE_INDEX) {
            return false;
        }
        const pos = this.posScratch;
        pos[0] = 0;
        pos[1] = 0;
        pos[2] = 0;
        if (!parent.readVector3AsI64(<u64>valIndex, pos)) {
            return false;
        }
        this.lastPos = I64Vec3(pos[0], pos[1], pos[2]);
        return true;
    }

    // The UV of an entry into `lastUv`.
    private getTexCoordForEntryId(entryId: i32, data: Int32Array): bool {
        if (entryId < 0) return false;
        const offset = <i64>entryId * 2;
        if (offset + 1 >= <i64>data.length) return false;
        this.lastUv = I64Vec2(<i64>data[<i32>offset], <i64>data[<i32>offset + 1]);
        return true;
    }

    // Computes the predicted UV coordinate for `dataId` from whatever is
    // already coded in `data`, into `predictedValue[0..2]`.
    computePredictedValue(
        isEncoder: bool,
        cornerId: CornerIndex,
        data: Int32Array,
        dataId: i32,
        entryToPointIdMap: EntryToPointIdMap,
        predictedValue: Int32Array,
    ): bool {
        const meshData = this.meshData;
        if (meshData == null) return false;
        const cornerTable = meshData.cornerTable();
        if (cornerTable == null) return false;
        const vertexToDataMap = meshData.vertexToDataMap();
        if (vertexToDataMap == null) return false;

        const nextVertId = cornerTable.vertexAfter(cornerId);
        const prevVertId = cornerTable.vertexBefore(cornerId);

        if (nextVertId >= <u32>vertexToDataMap.length) return false;
        const nextDataId = vertexToDataMap[<i32>nextVertId];
        if (prevVertId >= <u32>vertexToDataMap.length) return false;
        const prevDataId = vertexToDataMap[<i32>prevVertId];

        if (prevDataId < dataId && nextDataId < dataId) {
            if (!this.getTexCoordForEntryId(nextDataId, data)) return false;
            const nUv = this.lastUv;
            if (!this.getTexCoordForEntryId(prevDataId, data)) return false;
            const pUv = this.lastUv;

            if (nUv.x == pUv.x && nUv.y == pUv.y) {
                // A degenerate UV triangle: no reliable prediction.
                predictedValue[0] = <i32>pUv.x;
                predictedValue[1] = <i32>pUv.y;
                return true;
            }

            if (!this.getPositionForEntryId(dataId, entryToPointIdMap)) return false;
            const tipPos = this.lastPos;
            if (!this.getPositionForEntryId(nextDataId, entryToPointIdMap)) return false;
            const nextPos = this.lastPos;
            if (!this.getPositionForEntryId(prevDataId, entryToPointIdMap)) return false;
            const prevPos = this.lastPos;

            // Predict the tip C through the projection X of C onto
            // |prev_pos - next_pos|.
            const pn = vec3Sub(prevPos, nextPos);
            const pnNorm2Squared = vec3SquaredNorm(pn);

            if (pnNorm2Squared != 0) {
                const cn = vec3Sub(tipPos, nextPos);
                const cnDotPn = vec3Dot(pn, cn);
                const pnUv = vec2Sub(pUv, nUv);

                // Everything runs in the scaled space x_uv = X_UV * |PN|^2;
                // the guards bound the products that space produces.
                if (!texCoordsPredictionOverflowChecks(nUv, pnUv, pn, cnDotPn, pnNorm2Squared)) {
                    return false;
                }

                const xUv = vec2Add(vec2Mul(nUv, <i64>pnNorm2Squared), vec2Mul(pnUv, cnDotPn));

                const xPos = vec3Add(nextPos, vec3DivScalar(vec3MulScalar(pn, cnDotPn), <i64>pnNorm2Squared));

                const cxNorm2Squared = vec3SquaredNorm(vec3Sub(tipPos, xPos));

                // CX_UV is PN_UV rotated by 90 degrees and scaled; the u64
                // product wraps on purpose (upstream's uint64_t multiply).
                let cxUv = I64Vec2(pnUv.y, -pnUv.x);
                const normSquared = intSqrt(cxNorm2Squared * pnNorm2Squared);
                cxUv = vec2Mul(cxUv, <i64>normSquared);

                let predictedUv: I64Vec2;
                if (isEncoder) {
                    // Both candidates; keep the one closer to the value being
                    // coded and record the choice as one orientation bit.
                    const pred0 = vec2WrappingAddDivU64(xUv, cxUv, pnNorm2Squared);
                    const pred1 = vec2WrappingSubDivU64(xUv, cxUv, pnNorm2Squared);

                    if (!this.getTexCoordForEntryId(dataId, data)) return false;
                    const cUv = this.lastUv;

                    const dist0 = vec2SquaredNorm(vec2Sub(cUv, pred0));
                    const dist1 = vec2SquaredNorm(vec2Sub(cUv, pred1));

                    if (dist0 < dist1) {
                        predictedUv = pred0;
                        this.orientations.push(true);
                    } else {
                        predictedUv = pred1;
                        this.orientations.push(false);
                    }
                } else {
                    if (this.orientations.length == 0) {
                        return false;
                    }
                    const orientation = this.orientations.pop();
                    predictedUv = orientation
                        ? vec2WrappingAddDivU64(xUv, cxUv, pnNorm2Squared)
                        : vec2WrappingSubDivU64(xUv, cxUv, pnNorm2Squared);
                }

                predictedValue[0] = <i32>predictedUv.x;
                predictedValue[1] = <i32>predictedUv.y;
                return true;
            }
        }

        // Delta coding, for a corner whose neighbours cannot carry a
        // geometric prediction (upstream issue #1117: the previous corner is
        // always overwritten, and both sides spell that). A negative id is a
        // vertex that never received data, and refuses the prediction.
        let dataOffset: i64;
        if (prevDataId < dataId) {
            let offset = prevDataId;
            if (nextDataId < dataId) {
                offset = nextDataId;
            } else if (dataId > 0) {
                offset = dataId - 1;
            }
            dataOffset = offset < 0 ? -1 : <i64>offset * 2;
        } else if (nextDataId < dataId) {
            dataOffset = nextDataId < 0 ? -1 : <i64>nextDataId * 2;
        } else if (dataId > 0) {
            dataOffset = <i64>(dataId - 1) * 2;
        } else {
            predictedValue[0] = 0;
            predictedValue[1] = 0;
            return true;
        }
        if (dataOffset < 0) {
            return false;
        }
        if (dataOffset >= <i64>data.length) return false;
        if (dataOffset + 1 >= <i64>data.length) return false;
        predictedValue[0] = data[<i32>dataOffset];
        predictedValue[1] = data[<i32>dataOffset + 1];
        return true;
    }
}

export class MeshPredictionSchemeTexCoordsPortableDecoder extends PredictionSchemeDecoder {
    transform: PredictionSchemeWrapDecodingTransform;
    predictor: MeshPredictionSchemeTexCoordsPortablePredictor = new MeshPredictionSchemeTexCoordsPortablePredictor();
    private predictedValue: Int32Array = new Int32Array(2);

    constructor(transform: PredictionSchemeWrapDecodingTransform) {
        super();
        this.transform = transform;
    }

    init(meshData: MeshPredictionSchemeData): void {
        this.predictor.init(meshData);
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionTexCoordsPortable;
    }

    isInitialized(): bool {
        return this.predictor.isInitialized();
    }

    getNumParentAttributes(): i32 {
        return 1;
    }

    getParentAttributeType(_i: i32): GeometryAttributeType {
        return GeometryAttributeType.Position;
    }

    setParentAttribute(parent: PredictionParent): Status {
        return this.predictor.setParentAttribute(parent);
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    decodePredictionData(buffer: DecoderBuffer): Status {
        const r = buffer.decode<i32>();
        if (!r.ok) {
            return DracoError.buffer("Stream ends before the texture-coordinate orientation count").fail<bool>();
        }
        const numOrientations = r.value;
        if (numOrientations < 0) {
            return DracoError.general(`Stream declares ${numOrientations} orientations`).fail<bool>();
        }
        // The bound is structural: computeOriginalValues pops exactly one
        // orientation per predicted entry.
        const meshData = this.predictor.meshData;
        const d2c = meshData != null ? meshData.dataToCornerMap() : null;
        if (d2c == null) {
            return DracoError.general(
                "Portable texture-coordinate prediction has no data-to-corner map",
            ).fail<bool>();
        }
        const maxOrientations = d2c.length;
        if (numOrientations > maxOrientations) {
            return DracoError.general(
                `Stream declares ${numOrientations} orientations, more than the ${maxOrientations} entries that can consume them`,
            ).fail<bool>();
        }

        const orientations = this.predictor.orientations;
        orientations.length = 0;

        let lastOrientation = true;
        const decoder = new RAnsBitDecoder();
        if (!decoder.startDecoding(buffer)) {
            return DracoError.buffer("Texture-coordinate orientation rANS stream is truncated").fail<bool>();
        }

        for (let i = 0; i < numOrientations; i++) {
            const isSame = decoder.decodeNextBit();
            const orientation = isSame ? lastOrientation : !lastOrientation;
            orientations.push(orientation);
            lastOrientation = orientation;
        }
        decoder.endDecoding();

        // Then the wrap transform data (min/max bounds).
        return this.transform.decodeTransformData(buffer);
    }

    computeOriginalValues(
        data: Int32Array,
        _size: i32,
        numComponents: i32,
        entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        if (numComponents != 2) {
            return DracoError.invalidParameter(
                `Portable texture-coordinate prediction needs 2 components, got ${numComponents}`,
            ).fail<bool>();
        }
        if (this.predictor.posParent == null) {
            return DracoError.general("Portable texture-coordinate prediction has no position parent").fail<bool>();
        }

        const si = this.transform.init(numComponents);
        if (!si.ok) return si;

        if (entryToPointIdMap == null) {
            return DracoError.general("Portable texture-coordinate prediction has no entry-to-point map").fail<bool>();
        }
        const entryMap = entryToPointIdMap;

        const meshData = this.predictor.meshData;
        if (meshData == null) {
            return DracoError.general("Portable texture-coordinate prediction has no mesh data").fail<bool>();
        }
        const d2cOpt = meshData.dataToCornerMap();
        if (d2cOpt == null) {
            return DracoError.general("Portable texture-coordinate prediction has no data-to-corner map").fail<bool>();
        }
        const dataToCornerMap = d2cOpt;
        if (entryMap.len() < dataToCornerMap.length) {
            return DracoError.general(
                `Portable texture-coordinate prediction needs ${dataToCornerMap.length} entries, the map has ${entryMap.len()}`,
            ).fail<bool>();
        }
        const cornerMapSize = dataToCornerMap.length;
        // An i32 * 2 product always fits i64: no overflow check needed.
        const requiredValues = <i64>cornerMapSize * <i64>numComponents;
        if (<i64>data.length < requiredValues) {
            return DracoError.general(
                `Portable texture-coordinate prediction needs ${requiredValues} values, has ${data.length}`,
            ).fail<bool>();
        }

        const predictedValue = this.predictedValue;
        for (let p = 0; p < cornerMapSize; p++) {
            const cornerId = unchecked(dataToCornerMap[p]);

            // The buffer itself is the source of the values decoded so far.
            if (!this.predictor.computePredictedValue(false, cornerId, data, p, entryMap, predictedValue)) {
                return DracoError.general(`Portable texture-coordinate prediction failed at entry ${p}`).fail<bool>();
            }

            const dstOffset = p * numComponents;
            this.transform.computeOriginalValue(predictedValue, 0, data, dstOffset, 2);
        }
        return okStatus();
    }
}

// The correction transform of the portable tex-coord encoder: Wrap (in
// Draco, TexCoordsPortable is a prediction method, not a transform).
export class PredictionSchemeTexCoordsPortableEncodingTransform extends PredictionSchemeEncodingTransform {
    inner: PredictionSchemeWrapEncodingTransform = new PredictionSchemeWrapEncodingTransform();

    constructor() {
        super();
    }

    getType(): PredictionSchemeTransformType {
        return PredictionSchemeTransformType.Wrap;
    }

    init(data: Int32Array, size: i32, numComponents: i32): void {
        this.inner.init(data, size, numComponents);
    }

    computeCorrection(
        originalVals: Int32Array, origOff: i32,
        predictedVals: Int32Array, predOff: i32,
        outCorrVals: Int32Array, outOff: i32,
        n: i32,
    ): void {
        this.inner.computeCorrection(originalVals, origOff, predictedVals, predOff, outCorrVals, outOff, n);
    }

    encodeTransformData(buffer: ByteVec): Status {
        return this.inner.encodeTransformData(buffer);
    }
}

export class MeshPredictionSchemeTexCoordsPortableEncoder extends PredictionSchemeEncoder {
    transform: PredictionSchemeTexCoordsPortableEncodingTransform;
    predictor: MeshPredictionSchemeTexCoordsPortablePredictor = new MeshPredictionSchemeTexCoordsPortablePredictor();
    // Target bitstream, packed as 0xMMmm; 0 means the newest. Only the
    // orientation rANS stream's size prefix depends on it.
    bitstreamVersion: u16 = 0;
    private predictedValue: Int32Array = new Int32Array(2);

    constructor(transform: PredictionSchemeTexCoordsPortableEncodingTransform) {
        super();
        this.transform = transform;
    }

    // Targets a specific bitstream version (read off the encoder options).
    setBitstreamVersion(major: u8, minor: u8): void {
        this.bitstreamVersion = packVersion(major, minor);
    }

    init(meshData: MeshPredictionSchemeData): void {
        this.predictor.init(meshData);
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionTexCoordsPortable;
    }

    isInitialized(): bool {
        return this.predictor.isInitialized();
    }

    getNumParentAttributes(): i32 {
        return 1;
    }

    getParentAttributeType(_i: i32): GeometryAttributeType {
        return GeometryAttributeType.Position;
    }

    setParentAttribute(parent: PredictionParent): Status {
        return this.predictor.setParentAttribute(parent);
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    encodePredictionData(buffer: ByteVec): Status {
        const tempBuffer = new EncoderBuffer();
        // The orientation rANS size prefix is a u32 pre-2.2 and a varint
        // after; a version of 0 means the newest.
        tempBuffer.setVersion(<u8>(this.bitstreamVersion >> 8), <u8>(this.bitstreamVersion & 0xff));
        const orientations = this.predictor.orientations;
        const numOrientations = <i32>orientations.length;
        tempBuffer.encode<i32>(numOrientations);

        let lastOrientation = true;
        const encoder = new RAnsBitEncoder();
        encoder.startEncoding();

        for (let i = 0; i < orientations.length; i++) {
            const orientation = orientations[i];
            encoder.encodeBit(orientation == lastOrientation);
            lastOrientation = orientation;
        }
        encoder.endEncoding(tempBuffer);

        buffer.extend(tempBuffer.data());

        // Match Draco: after the orientations, the wrap transform bounds.
        return this.transform.encodeTransformData(buffer);
    }

    computeCorrectionValues(
        inData: Int32Array,
        outCorr: Int32Array,
        _size: i32,
        numComponents: i32,
        entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        if (numComponents != 2) {
            return DracoError.invalidParameter(
                `Portable texture-coordinate prediction needs 2 components, got ${numComponents}`,
            ).fail<bool>();
        }
        if (this.predictor.posParent == null) {
            return DracoError.general("Portable texture-coordinate prediction has no position parent").fail<bool>();
        }

        // Wrap bounds for the corrections (over the whole input).
        this.transform.init(inData, inData.length, numComponents);

        if (entryToPointIdMap == null) {
            return DracoError.general("Portable texture-coordinate prediction has no entry-to-point map").fail<bool>();
        }
        const entryMap = entryToPointIdMap;

        const meshData = this.predictor.meshData;
        if (meshData == null) {
            return DracoError.general("Portable texture-coordinate prediction has no mesh data").fail<bool>();
        }
        const d2cOpt = meshData.dataToCornerMap();
        if (d2cOpt == null) {
            return DracoError.general("Portable texture-coordinate prediction has no data-to-corner map").fail<bool>();
        }
        const dataToCornerMap = d2cOpt;
        const cornerMapSize = dataToCornerMap.length;

        const predictedValue = this.predictedValue;

        // In reverse order.
        for (let p = cornerMapSize - 1; p >= 0; p--) {
            const cornerId = unchecked(dataToCornerMap[p]);

            if (!this.predictor.computePredictedValue(true, cornerId, inData, p, entryMap, predictedValue)) {
                return DracoError.general(`Portable texture-coordinate prediction failed at entry ${p}`).fail<bool>();
            }

            const dstOffset = p * numComponents;
            // Both buffers are read at `[dst..dst + 2]` (panics past the end).
            if (dstOffset + 2 > inData.length || dstOffset + 2 > outCorr.length) {
                sliceEndPanic(dstOffset + 2, dstOffset + 2 > inData.length ? inData.length : outCorr.length);
            }
            this.transform.computeCorrection(inData, dstOffset, predictedValue, 0, outCorr, dstOffset, 2);
        }
        return okStatus();
    }
}

function sliceEndPanic(end: i32, len: i32): void {
    // The slice-index panic message.
    panic(`range end index ${end} out of range for slice of length ${len}`);
}
