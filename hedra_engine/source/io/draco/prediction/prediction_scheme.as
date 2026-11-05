// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Prediction-scheme abstraction and the method/transform enums.
//
// A prediction scheme predicts each attribute value from previously coded
// values so that only a small residual is entropy-coded. Two enums identify
// what a bitstream used -- PredictionSchemeMethod (which predictor) and
// PredictionSchemeTransformType (how prediction and correction combine) --
// and the abstract classes below are the interfaces the concrete predictors
// and transforms implement.
//
// Notes:
//   - Every scheme and transform is only ever used with DataType = CorrType
//     = i32, so the interfaces are specialized to i32: data is an Int32Array.
//   - A sub-range argument is passed as `(x, a)` plus the length `n` where
//     the callee needs the length (transforms); nothing is copied.
//   - Byte sinks are ByteVec; an optional entry map is
//     `EntryToPointIdMap?`.

import { Result } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { Status } from "../core/status";
import { GeometryAttributeType } from "../geometry/geometry_attribute";
import { PredictionParent } from "../geometry/portable_attribute";

export enum PredictionSchemeMethod {
    // Special value indicating that no prediction scheme was used.
    // CRITICAL: These values must match C++ enum values exactly:
    //   C++: PREDICTION_NONE = -2, PREDICTION_UNDEFINED = -1
    None = -2,
    Undefined = -1,
    Difference = 0,
    MeshPredictionParallelogram = 1,
    MeshPredictionMultiParallelogram = 2,
    MeshPredictionTexCoordsDeprecated = 3,
    MeshPredictionConstrainedMultiParallelogram = 4,
    MeshPredictionTexCoordsPortable = 5,
    MeshPredictionGeometricNormal = 6,
}

// The method with tag `value`; an unknown tag is a failure with the
// message "()".
export function predictionSchemeMethodTryFrom(value: u8): Result<PredictionSchemeMethod> {
    if (value <= 6) return Result.okv<PredictionSchemeMethod>(<PredictionSchemeMethod><i32>value);
    return Result.fail<PredictionSchemeMethod>("()");
}

// `{:?}` of a PredictionSchemeMethod (the variant name).
export function predictionSchemeMethodDebug(m: PredictionSchemeMethod): string {
    switch (m) {
        case PredictionSchemeMethod.None: return "None";
        case PredictionSchemeMethod.Undefined: return "Undefined";
        case PredictionSchemeMethod.Difference: return "Difference";
        case PredictionSchemeMethod.MeshPredictionParallelogram: return "MeshPredictionParallelogram";
        case PredictionSchemeMethod.MeshPredictionMultiParallelogram: return "MeshPredictionMultiParallelogram";
        case PredictionSchemeMethod.MeshPredictionTexCoordsDeprecated: return "MeshPredictionTexCoordsDeprecated";
        case PredictionSchemeMethod.MeshPredictionConstrainedMultiParallelogram:
            return "MeshPredictionConstrainedMultiParallelogram";
        case PredictionSchemeMethod.MeshPredictionTexCoordsPortable: return "MeshPredictionTexCoordsPortable";
        case PredictionSchemeMethod.MeshPredictionGeometricNormal: return "MeshPredictionGeometricNormal";
    }
    return "";
}

export enum PredictionSchemeTransformType {
    None = -1,
    Delta = 0,
    Wrap = 1,
    NormalOctahedron = 2,
    NormalOctahedronCanonicalized = 3,
    Parallelogram = 4,
    TexCoordsPortable = 5,
    GeometricNormal = 6,
    MultiParallelogram = 7,
    ConstrainedMultiParallelogram = 8,
}

// The transform type of a raw byte, or an error when it names none.
//
// Nothing above three. The bitstream's transform types end at
// `NUM_PREDICTION_SCHEME_TRANSFORM_TYPES == 4`, and upstream's decoder
// refuses a byte at or past it before it builds anything. The variants above
// three name predictors, not transforms; no encoder writes them.
export function predictionSchemeTransformTypeTryFrom(value: u8): Result<PredictionSchemeTransformType> {
    if (value <= 3) {
        return Result.okv<PredictionSchemeTransformType>(<PredictionSchemeTransformType><i32>value);
    }
    return Result.fail<PredictionSchemeTransformType>("()");
}

// `{:?}` of a PredictionSchemeTransformType (the variant name).
export function predictionSchemeTransformTypeDebug(t: PredictionSchemeTransformType): string {
    switch (t) {
        case PredictionSchemeTransformType.None: return "None";
        case PredictionSchemeTransformType.Delta: return "Delta";
        case PredictionSchemeTransformType.Wrap: return "Wrap";
        case PredictionSchemeTransformType.NormalOctahedron: return "NormalOctahedron";
        case PredictionSchemeTransformType.NormalOctahedronCanonicalized: return "NormalOctahedronCanonicalized";
        case PredictionSchemeTransformType.Parallelogram: return "Parallelogram";
        case PredictionSchemeTransformType.TexCoordsPortable: return "TexCoordsPortable";
        case PredictionSchemeTransformType.GeometricNormal: return "GeometricNormal";
        case PredictionSchemeTransformType.MultiParallelogram: return "MultiParallelogram";
        case PredictionSchemeTransformType.ConstrainedMultiParallelogram: return "ConstrainedMultiParallelogram";
    }
    return "";
}

// How an entry maps to its point id: through a PointIndex list, a u32 list,
// or the identity over a length. PointIndex is a u32 alias, so the two list
// kinds share one representation: an Array<u32> (not copied).
export enum EntryToPointIdMapKind {
    PointIndices,
    U32,
    // The identity of a given length: entry `i` is point `i`. A sequential
    // decode has no permutation to speak of, and writing one out costs four
    // bytes per point taken from a count the header supplies.
    Identity,
}

export class EntryToPointIdMap {
    kind: EntryToPointIdMapKind = EntryToPointIdMapKind.Identity;
    ids: Array<u32>? = null;
    numPoints: i32 = 0;

    constructor() {}

    static fromPointIndices(pointIds: Array<u32>): EntryToPointIdMap {
        const m = new EntryToPointIdMap();
        m.kind = EntryToPointIdMapKind.PointIndices;
        m.ids = pointIds;
        return m;
    }

    static fromU32Slice(pointIds: Array<u32>): EntryToPointIdMap {
        const m = new EntryToPointIdMap();
        m.kind = EntryToPointIdMapKind.U32;
        m.ids = pointIds;
        return m;
    }

    // The identity over `numPoints` entries, without materializing it.
    static identity(numPoints: i32): EntryToPointIdMap {
        const m = new EntryToPointIdMap();
        m.kind = EntryToPointIdMapKind.Identity;
        m.numPoints = numPoints;
        return m;
    }

    len(): i32 {
        if (this.kind == EntryToPointIdMapKind.Identity) return this.numPoints;
        const ids = this.ids;
        return ids != null ? ids.length : 0;
    }

    isEmpty(): bool {
        return this.len() == 0;
    }

    // The point id of entry `index`, or -1 past the end.
    get(index: i32): i64 {
        if (index < 0) return -1;
        if (this.kind == EntryToPointIdMapKind.Identity) {
            return index < this.numPoints ? <i64>index : -1;
        }
        const ids = this.ids;
        if (ids == null || index >= ids.length) return -1;
        return <i64>unchecked(ids[index]);
    }
}

// A predictor of attribute values from previously coded ones.
//
// Fallible methods return Status and name what went wrong.
// `isInitialized` and `areCorrectionsPositive` stay bool: they are
// predicates, not outcomes.
export abstract class PredictionScheme {
    abstract getPredictionMethod(): PredictionSchemeMethod;
    abstract isInitialized(): bool;
    abstract getNumParentAttributes(): i32;
    abstract getParentAttributeType(i: i32): GeometryAttributeType;
    // Binds the parent a scheme predicts from. A PredictionParent, not a
    // PointAttribute: a scheme may not read attribute storage, only the
    // portable values the parent hands out.
    abstract setParentAttribute(parent: PredictionParent): Status;
    abstract getTransformType(): PredictionSchemeTransformType;

    // Returns true if the correction values are always positive
    // (non-negative), which decides whether corrections are ZigZag-coded.
    areCorrectionsPositive(): bool {
        return false;
    }
}

// Turns original values and predictions into corrections.
//
// `computeCorrection(orig, origOff, pred, predOff, out, outOff, n)` reads
// `orig[origOff..origOff+n]` and `pred[predOff..predOff+n]` and writes
// `out[outOff..outOff+n]`.
export abstract class PredictionSchemeEncodingTransform {
    abstract init(origData: Int32Array, size: i32, numComponents: i32): void;
    abstract computeCorrection(
        originalVals: Int32Array, origOff: i32,
        predictedVals: Int32Array, predOff: i32,
        outCorrVals: Int32Array, outOff: i32,
        n: i32,
    ): void;
    abstract encodeTransformData(buffer: ByteVec): Status;
    abstract getType(): PredictionSchemeTransformType;

    // Returns true if the corrections produced by this transform are always positive.
    areCorrectionsPositive(): bool {
        return false;
    }
}

// Turns corrections and predictions back into original values.
//
// `computeOriginalValue(pred, predOff, data, dataOff, n)` reads
// `pred[predOff..predOff+n]` and updates `data[dataOff..dataOff+n]`:
// `data` holds the correction on entry and the original value on return.
export abstract class PredictionSchemeDecodingTransform {
    // Announces the component count the scheme will hand to
    // computeOriginalValue, and is the transform's one chance to refuse it.
    abstract init(numComponents: i32): Status;
    abstract computeOriginalValue(
        predictedVals: Int32Array, predOff: i32,
        data: Int32Array, dataOff: i32,
        n: i32,
    ): void;
    abstract decodeTransformData(buffer: DecoderBuffer): Status;
    abstract getType(): PredictionSchemeTransformType;

    // Returns true if the corrections are always positive (no ZigZag encoding needed).
    areCorrectionsPositive(): bool {
        return false;
    }
}

// A prediction scheme on the encoding side.
export abstract class PredictionSchemeEncoder extends PredictionScheme {
    abstract computeCorrectionValues(
        inData: Int32Array,
        outCorr: Int32Array,
        size: i32,
        numComponents: i32,
        entryToPointIdMap: EntryToPointIdMap?,
    ): Status;

    abstract encodePredictionData(buffer: ByteVec): Status;
}

// A prediction scheme on the decoding side.
export abstract class PredictionSchemeDecoder extends PredictionScheme {
    // Reconstructs all values in place: `data` holds the decoded corrections
    // on entry and the original values on return.
    abstract computeOriginalValues(
        data: Int32Array,
        size: i32,
        numComponents: i32,
        entryToPointIdMap: EntryToPointIdMap?,
    ): Status;

    abstract decodePredictionData(buffer: DecoderBuffer): Status;
}
