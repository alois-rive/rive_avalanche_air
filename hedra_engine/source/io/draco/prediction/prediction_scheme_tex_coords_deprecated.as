// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The deprecated texture-coordinate predictor.
//
// Predicts UV coordinates from the triangle's 3D positions using the original
// (pre-portable) floating-point algorithm, in f32. Kept for decoding legacy
// bitstreams; new content uses the portable tex-coord predictor.
//
// Draco's encoder and decoder each carry their own `compute_predicted_value`;
// they differ only in the orientation handling (the encoder picks and pushes,
// the decoder pops) and in how a missing mesh is answered (the encoder returns
// false, the decoder panics). Here both call `deprecatedPredict` with that
// difference as a flag.

import { f32ToI32, panic } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { EncoderBuffer } from "../core/encoder_buffer";
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
    PredictionSchemeDecodingTransform,
    PredictionSchemeEncoder,
    PredictionSchemeEncodingTransform,
    PredictionSchemeMethod,
    PredictionSchemeTransformType,
} from "./prediction_scheme";

// The deprecated float-to-int conversion: optional round-half-up, then i32::MIN for
// NaN and anything outside i32.
export function f32ToI32Deprecated(value: f32, round: bool): i32 {
    const v: f32 = round ? Mathf.floor(value + <f32>0.5) : value;
    if (isNaN<f32>(v) || <f64>v > <f64>i32.MAX_VALUE || <f64>v < <f64>i32.MIN_VALUE) {
        return i32.MIN_VALUE;
    }
    return f32ToI32(v);
}

// The state both halves predict from (the same four fields in the encoder
// and in the decoder).
class DeprecatedState {
    meshData: MeshPredictionSchemeData? = null;
    orientations: Array<bool> = [];
    posParent: PredictionParent? = null;
    // Results of the lookups below, valid when the lookup returned true.
    pos: StaticArray<f32> = new StaticArray<f32>(3);
    uv: StaticArray<f32> = new StaticArray<f32>(2);

    // The position of an entry into `pos`.
    getPositionForEntryId(entryId: i32, map: EntryToPointIdMap): bool {
        if (entryId < 0) return false;
        const pointId = map.get(entryId);
        if (pointId < 0) return false;
        const parent = this.posParent;
        if (parent == null) return false;
        const valIndex = parent.mappedIndex(<u32>pointId);
        if (valIndex == INVALID_ATTRIBUTE_VALUE_INDEX) {
            return false;
        }
        for (let component = 0; component < 3; component++) {
            if (!parent.readComponentAsF32(<u64>valIndex, <u64>component)) return false;
            this.pos[component] = parent.lastF32;
        }
        return true;
    }

    // The UV of an entry, as f32, into `uv`.
    getTexCoordForEntryId(entryId: i32, data: Int32Array): bool {
        if (entryId < 0) return false;
        const offset = <i64>entryId * 2;
        if (offset + 1 >= <i64>data.length) return false;
        this.uv[0] = <f32>data[<i32>offset];
        this.uv[1] = <f32>data[<i32>offset + 1];
        return true;
    }
}

// Both sides' `compute_predicted_value`, into `predictedValue[0..2]`.
function deprecatedPredict(
    state: DeprecatedState,
    isEncoder: bool,
    cornerId: CornerIndex,
    data: Int32Array,
    dataId: i32,
    map: EntryToPointIdMap,
    predictedValue: Int32Array,
): bool {
    const meshData = state.meshData;
    if (meshData == null) {
        if (isEncoder) return false;
        panic("called `Option::unwrap()` on a `None` value");
        return false;
    }
    const cornerTable = meshData.cornerTable();
    if (cornerTable == null) {
        if (isEncoder) return false;
        panic("called `Option::unwrap()` on a `None` value");
        return false;
    }
    const vertexToDataMap = meshData.vertexToDataMap();
    if (vertexToDataMap == null) {
        if (isEncoder) return false;
        panic("called `Option::unwrap()` on a `None` value");
        return false;
    }

    // vertex_after / vertex_before are vertex(next) / vertex(previous).
    const nextVertId = cornerTable.vertexAfter(cornerId);
    const prevVertId = cornerTable.vertexBefore(cornerId);

    if (nextVertId >= <u32>vertexToDataMap.length) return false;
    const nextDataId = vertexToDataMap[<i32>nextVertId];
    if (prevVertId >= <u32>vertexToDataMap.length) return false;
    const prevDataId = vertexToDataMap[<i32>prevVertId];

    if (prevDataId < dataId && nextDataId < dataId) {
        if (!state.getTexCoordForEntryId(nextDataId, data)) return false;
        const nU = state.uv[0];
        const nV = state.uv[1];
        if (!state.getTexCoordForEntryId(prevDataId, data)) return false;
        const pU = state.uv[0];
        const pV = state.uv[1];

        if (nU == pU && nV == pV) {
            predictedValue[0] = f32ToI32Deprecated(pU, false);
            predictedValue[1] = f32ToI32Deprecated(pV, false);
            return true;
        }

        if (!state.getPositionForEntryId(dataId, map)) return false;
        const tipX = state.pos[0], tipY = state.pos[1], tipZ = state.pos[2];
        if (!state.getPositionForEntryId(nextDataId, map)) return false;
        const nextX = state.pos[0], nextY = state.pos[1], nextZ = state.pos[2];
        if (!state.getPositionForEntryId(prevDataId, map)) return false;
        const prevX = state.pos[0], prevY = state.pos[1], prevZ = state.pos[2];

        const pnX: f32 = prevX - nextX, pnY: f32 = prevY - nextY, pnZ: f32 = prevZ - nextZ;
        const cnX: f32 = tipX - nextX, cnY: f32 = tipY - nextY, cnZ: f32 = tipZ - nextZ;
        const pnNorm2Squared: f32 = pnX * pnX + pnY * pnY + pnZ * pnZ;
        let s: f32 = 0;
        let t: f32 = 0;
        if (pnNorm2Squared > <f32>0) {
            s = (pnX * cnX + pnY * cnY + pnZ * cnZ) / pnNorm2Squared;
            const dX: f32 = cnX - pnX * s, dY: f32 = cnY - pnY * s, dZ: f32 = cnZ - pnZ * s;
            t = Mathf.sqrt((dX * dX + dY * dY + dZ * dZ) / pnNorm2Squared);
        }

        const pnU: f32 = pU - nU;
        const pnV: f32 = pV - nV;
        const pnus: f32 = pnU * s + nU;
        const pnut: f32 = pnU * t;
        const pnvs: f32 = pnV * s + nV;
        const pnvt: f32 = pnV * t;

        let predU: f32;
        let predV: f32;
        if (isEncoder) {
            const trueU: f32 = pnus - pnvt, trueV: f32 = pnvs + pnut;
            const falseU: f32 = pnus + pnvt, falseV: f32 = pnvs - pnut;
            if (!state.getTexCoordForEntryId(dataId, data)) return false;
            const curU = state.uv[0];
            const curV = state.uv[1];
            const dTU: f32 = curU - trueU, dTV: f32 = curV - trueV;
            const dFU: f32 = curU - falseU, dFV: f32 = curV - falseV;
            const distTrue: f32 = dTU * dTU + dTV * dTV;
            const distFalse: f32 = dFU * dFU + dFV * dFV;

            if (distTrue < distFalse) {
                state.orientations.push(true);
                predU = trueU;
                predV = trueV;
            } else {
                state.orientations.push(false);
                predU = falseU;
                predV = falseV;
            }
        } else {
            if (state.orientations.length == 0) return false;
            const orientation = state.orientations.pop();
            if (orientation) {
                predU = pnus - pnvt;
                predV = pnvs + pnut;
            } else {
                predU = pnus + pnvt;
                predV = pnvs - pnut;
            }
        }

        predictedValue[0] = f32ToI32Deprecated(predU, true);
        predictedValue[1] = f32ToI32Deprecated(predV, true);
        return true;
    }

    let dataOffset: i64 = 0;
    if (prevDataId < dataId) {
        if (prevDataId < 0) return false;
        dataOffset = <i64>prevDataId * 2;
    }
    if (nextDataId < dataId) {
        if (nextDataId < 0) return false;
        dataOffset = <i64>nextDataId * 2;
    } else if (prevDataId >= dataId) {
        if (dataId > 0) {
            dataOffset = <i64>(dataId - 1) * 2;
        } else {
            predictedValue[0] = 0;
            predictedValue[1] = 0;
            return true;
        }
    }

    if (dataOffset >= <i64>data.length) return false;
    if (dataOffset + 1 >= <i64>data.length) return false;
    predictedValue[0] = data[<i32>dataOffset];
    predictedValue[1] = data[<i32>dataOffset + 1];
    return true;
}

function positionParentError(parent: PredictionParent): Status {
    return DracoError.invalidParameter(
        `Deprecated texture-coordinate prediction needs a 3-component position parent, got ${geometryAttributeTypeDebug(parent.attributeType())} with ${parent.numComponents()} components`,
    ).fail<bool>();
}

export class MeshPredictionSchemeTexCoordsDeprecatedEncoder extends PredictionSchemeEncoder {
    transform: PredictionSchemeEncodingTransform;
    private state: DeprecatedState = new DeprecatedState();
    // Target bitstream, packed as 0xMMmm; 0 means the newest. Only the
    // orientation count's width depends on it.
    bitstreamVersion: u16 = 0;
    private predictedValue: Int32Array = new Int32Array(2);

    constructor(transform: PredictionSchemeEncodingTransform) {
        super();
        this.transform = transform;
    }

    // How many orientation bits the prediction produced. Zero is a stream no
    // decoder reads back, so the caller checks this before keeping the scheme.
    numOrientations(): i32 {
        return this.state.orientations.length;
    }

    // Targets a specific bitstream version (read off the encoder options).
    setBitstreamVersion(major: u8, minor: u8): void {
        this.bitstreamVersion = packVersion(major, minor);
    }

    init(meshData: MeshPredictionSchemeData): void {
        this.state.meshData = meshData.clone();
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionTexCoordsDeprecated;
    }

    isInitialized(): bool {
        return this.state.posParent != null && this.state.meshData != null;
    }

    getNumParentAttributes(): i32 {
        return 1;
    }

    getParentAttributeType(_i: i32): GeometryAttributeType {
        return GeometryAttributeType.Position;
    }

    setParentAttribute(parent: PredictionParent): Status {
        if (parent.attributeType() != GeometryAttributeType.Position || parent.numComponents() != 3) {
            return positionParentError(parent);
        }
        this.state.posParent = parent;
        return okStatus();
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    encodePredictionData(buffer: ByteVec): Status {
        const tempBuffer = new EncoderBuffer();
        // The orientation rANS size prefix is a u32 pre-2.2 and a varint
        // after; RAnsBitEncoder.endEncoding reads it off this buffer.
        tempBuffer.setVersion(<u8>(this.bitstreamVersion >> 8), <u8>(this.bitstreamVersion & 0xff));
        const orientations = this.state.orientations;
        // An Array length always fits u32, so the count needs no range check.
        const numOrientations = <u64>orientations.length;
        // Pre-2.2 writes the count as a fixed u32; 2.2 moved it to a varint.
        if (this.bitstreamVersion != 0 && this.bitstreamVersion < 0x0202) {
            tempBuffer.encodeU32(<u32>numOrientations);
        } else {
            tempBuffer.encodeVarint(numOrientations);
        }

        let lastOrientation = true;
        const bitEncoder = new RAnsBitEncoder();
        bitEncoder.startEncoding();
        for (let i = 0; i < orientations.length; i++) {
            const orientation = orientations[i];
            bitEncoder.encodeBit(orientation == lastOrientation);
            lastOrientation = orientation;
        }
        bitEncoder.endEncoding(tempBuffer);

        buffer.extend(tempBuffer.data());
        return this.transform.encodeTransformData(buffer);
    }

    computeCorrectionValues(
        inData: Int32Array,
        outCorr: Int32Array,
        size: i32,
        numComponents: i32,
        entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        if (numComponents != 2 || size % numComponents != 0) {
            return DracoError.invalidParameter(
                `Texture-coordinate prediction needs 2 components and a matching value count, got ${numComponents} components over ${size} values`,
            ).fail<bool>();
        }
        if (this.state.posParent == null) {
            return DracoError.general("Texture-coordinate prediction has no position parent").fail<bool>();
        }
        if (entryToPointIdMap == null) {
            return DracoError.general("Texture-coordinate prediction has no entry-to-point map").fail<bool>();
        }
        const entryMap = entryToPointIdMap;
        const meshData = this.state.meshData;
        if (meshData == null) {
            return DracoError.general("Texture-coordinate prediction has no mesh data").fail<bool>();
        }
        const d2cOpt = meshData.dataToCornerMap();
        if (d2cOpt == null) {
            return DracoError.general("Texture-coordinate prediction has no data-to-corner map").fail<bool>();
        }
        const dataToCornerMap = d2cOpt;
        if (entryMap.len() < dataToCornerMap.length || inData.length < size || outCorr.length < size) {
            return DracoError.general(
                `Texture-coordinate prediction needs ${dataToCornerMap.length} entries and ${size} values, has ${entryMap.len()} entries, ${inData.length} inputs and ${outCorr.length} outputs`,
            ).fail<bool>();
        }

        this.transform.init(inData, size, numComponents);
        this.state.orientations.length = 0;

        const predictedValue = this.predictedValue;
        for (let p = dataToCornerMap.length - 1; p >= 0; p--) {
            if (!deprecatedPredict(this.state, true, unchecked(dataToCornerMap[p]), inData, p, entryMap, predictedValue)) {
                return DracoError.general(`Texture-coordinate prediction failed at entry ${p}`).fail<bool>();
            }
            const dstOffset = p * numComponents;
            this.transform.computeCorrection(inData, dstOffset, predictedValue, 0, outCorr, dstOffset, numComponents);
        }

        return okStatus();
    }
}

export class MeshPredictionSchemeTexCoordsDeprecatedDecoder extends PredictionSchemeDecoder {
    transform: PredictionSchemeDecodingTransform;
    private state: DeprecatedState = new DeprecatedState();
    private predictedValue: Int32Array = new Int32Array(2);

    constructor(transform: PredictionSchemeDecodingTransform) {
        super();
        this.transform = transform;
    }

    init(meshData: MeshPredictionSchemeData): void {
        this.state.meshData = meshData.clone();
    }

    // The decoded orientations (for the tests).
    orientations(): Array<bool> {
        return this.state.orientations;
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionTexCoordsDeprecated;
    }

    isInitialized(): bool {
        return this.state.posParent != null && this.state.meshData != null;
    }

    getNumParentAttributes(): i32 {
        return 1;
    }

    getParentAttributeType(_i: i32): GeometryAttributeType {
        return GeometryAttributeType.Position;
    }

    setParentAttribute(parent: PredictionParent): Status {
        if (parent.attributeType() != GeometryAttributeType.Position || parent.numComponents() != 3) {
            return positionParentError(parent);
        }
        this.state.posParent = parent;
        return okStatus();
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    decodePredictionData(buffer: DecoderBuffer): Status {
        const bitstreamVersion = buffer.bitstreamVersion();
        let numOrientations: u32;
        if (bitstreamVersion < 0x0202) {
            const r = buffer.decodeU32();
            if (!r.ok) {
                return DracoError.buffer("Stream ends before the texture-coordinate orientation count").fail<bool>();
            }
            numOrientations = r.value;
        } else {
            const r = buffer.decodeVarint();
            if (!r.ok) {
                return DracoError.buffer("Stream ends before the texture-coordinate orientation count").fail<bool>();
            }
            numOrientations = <u32>r.value;
        }

        if (numOrientations == 0) {
            return DracoError.general("Texture-coordinate prediction declares no orientations").fail<bool>();
        }
        const meshData = this.state.meshData;
        if (meshData == null) {
            return DracoError.general("Texture-coordinate prediction has no mesh data").fail<bool>();
        }
        const cornerTable = meshData.cornerTable();
        if (cornerTable == null) {
            return DracoError.general("Texture-coordinate prediction has no corner table").fail<bool>();
        }
        if (numOrientations > <u32>cornerTable.numCorners()) {
            return DracoError.general(
                `Stream declares ${numOrientations} orientations, more than the ${cornerTable.numCorners()} corners`,
            ).fail<bool>();
        }

        const orientations = this.state.orientations;
        orientations.length = 0;

        let lastOrientation = true;
        const decoder = new RAnsBitDecoder();
        if (!decoder.startDecoding(buffer)) {
            return DracoError.buffer("Texture-coordinate orientation rANS stream is truncated").fail<bool>();
        }
        for (let i: u32 = 0; i < numOrientations; i++) {
            if (!decoder.decodeNextBit()) {
                lastOrientation = !lastOrientation;
            }
            orientations.push(lastOrientation);
        }
        decoder.endDecoding();

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
                `Texture-coordinate prediction needs 2 components, got ${numComponents}`,
            ).fail<bool>();
        }
        if (this.state.posParent == null) {
            return DracoError.general("Texture-coordinate prediction has no position parent").fail<bool>();
        }
        if (entryToPointIdMap == null) {
            return DracoError.general("Texture-coordinate prediction has no entry-to-point map").fail<bool>();
        }
        const entryMap = entryToPointIdMap;
        const meshData = this.state.meshData;
        if (meshData == null) {
            return DracoError.general("Texture-coordinate prediction has no mesh data").fail<bool>();
        }
        const d2cOpt = meshData.dataToCornerMap();
        if (d2cOpt == null) {
            return DracoError.general("Texture-coordinate prediction has no data-to-corner map").fail<bool>();
        }
        const dataToCornerMap = d2cOpt;
        if (entryMap.len() < dataToCornerMap.length) {
            return DracoError.general(
                `Texture-coordinate prediction needs ${dataToCornerMap.length} entries, the map has ${entryMap.len()}`,
            ).fail<bool>();
        }
        // An i32 * 2 product always fits i64: no overflow check needed.
        const requiredValues = <i64>dataToCornerMap.length * <i64>numComponents;
        if (<i64>data.length < requiredValues) {
            return DracoError.general(
                `Texture-coordinate prediction needs ${requiredValues} values, has ${data.length}`,
            ).fail<bool>();
        }

        const si = this.transform.init(numComponents);
        if (!si.ok) return si;
        const predictedValue = this.predictedValue;
        for (let p = 0; p < dataToCornerMap.length; p++) {
            if (!deprecatedPredict(this.state, false, unchecked(dataToCornerMap[p]), data, p, entryMap, predictedValue)) {
                return DracoError.general(`Texture-coordinate prediction failed at entry ${p}`).fail<bool>();
            }
            const dstOffset = p * numComponents;
            this.transform.computeOriginalValue(predictedValue, 0, data, dstOffset, numComponents);
        }

        return okStatus();
    }
}
