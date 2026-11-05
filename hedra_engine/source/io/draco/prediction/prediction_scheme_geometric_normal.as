// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The geometric normal predictor.
//
// Predicts vertex normals from the surrounding mesh geometry (face normals
// gathered through the corner table), so only a small octahedral correction
// is coded. NormalPredictionMode selects the prediction variant. Draco
// bitstreams use the NormalOctahedronCanonicalized transform data for it.
//
// The decoder sums its cross products in i128: `I128` below is the
// two-word signed integer that arithmetic needs. The encoder works in
// wrapping i64, which AS arithmetic is.

import { i64ToI32, panic, panicAs } from "../../../../base/util";
import { ByteVec } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { EncoderBuffer } from "../core/encoder_buffer";
import { DracoError, Status, okStatus } from "../core/status";
import { bitstreamVersion as packVersion } from "../core/version";
import { RAnsBitDecoder } from "../entropy/rans_bit_decoder";
import { RAnsBitEncoder } from "../entropy/rans_bit_encoder";
import { GeometryAttributeType, geometryAttributeTypeDebug } from "../geometry/geometry_attribute";
import {
    CornerIndex,
    INVALID_ATTRIBUTE_VALUE_INDEX,
    INVALID_CORNER_INDEX,
    VertexIndex,
} from "../geometry/geometry_indices";
import { OctahedronToolBox } from "../geometry/normal_compression_utils";
import { PredictionParent } from "../geometry/portable_attribute";
import { CornerTable } from "../mesh/corner_table";
import { MeshPredictionSchemeData } from "../mesh/mesh_prediction_scheme_data";
import {
    EntryToPointIdMap,
    PredictionSchemeDecoder,
    PredictionSchemeEncoder,
    PredictionSchemeMethod,
    PredictionSchemeTransformType,
} from "./prediction_scheme";
import { PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform } from "./prediction_scheme_normal_octahedron_canonicalized_decoding_transform";
import { PredictionSchemeNormalOctahedronCanonicalizedEncodingTransform } from "./prediction_scheme_normal_octahedron_canonicalized_encoding_transform";

export enum NormalPredictionMode {
    OneTriangle = 0,
    TriangleArea = 1,
}

// `{:?}` of a NormalPredictionMode.
export function normalPredictionModeDebug(m: NormalPredictionMode): string {
    return m == NormalPredictionMode.OneTriangle ? "OneTriangle" : "TriangleArea";
}

// ---------------------------------------------------------------------------
// i128, as far as the decoder's normal accumulation needs it.

// A signed 128-bit integer: `hi` is the upper word (with the sign), `lo` the
// lower word.
export struct I128 {
    hi: i64 = 0;
    lo: u64 = 0;
    constructor(hi: i64, lo: u64) {
        this.hi = hi;
        this.lo = lo;
    }
}

const MASK32: u64 = 0xffffffff;

export function i128Neg(a: I128): I128 {
    const lo = ~a.lo + 1;
    const hi = ~a.hi + (lo == 0 ? 1 : 0);
    return I128(hi, lo);
}

export function i128Add(a: I128, b: I128): I128 {
    const lo = a.lo + b.lo;
    const carry: i64 = lo < a.lo ? 1 : 0;
    return I128(a.hi + b.hi + carry, lo);
}

export function i128Sub(a: I128, b: I128): I128 {
    return i128Add(a, i128Neg(b));
}

// @ts-ignore: decorator
@inline
function i128IsZero(a: I128): bool {
    return a.hi == 0 && a.lo == 0;
}

export function i128Abs(a: I128): I128 {
    return a.hi < 0 ? i128Neg(a) : a;
}

// The full 128-bit product of two unsigned 64-bit words.
function u64MulWide(a: u64, b: u64): I128 {
    const aLo = a & MASK32;
    const aHi = a >> 32;
    const bLo = b & MASK32;
    const bHi = b >> 32;
    const p0 = aLo * bLo;
    const p1 = aLo * bHi;
    const p2 = aHi * bLo;
    const p3 = aHi * bHi;
    const mid = (p0 >> 32) + (p1 & MASK32) + (p2 & MASK32);
    const lo = (mid << 32) | (p0 & MASK32);
    const hi = p3 + (p1 >> 32) + (p2 >> 32) + (mid >> 32);
    return I128(<i64>hi, lo);
}

// `a as i128 * b as i128`.
export function i128MulI64(a: i64, b: i64): I128 {
    const ua: u64 = a < 0 ? <u64>(-a) : <u64>a;
    const ub: u64 = b < 0 ? <u64>(-b) : <u64>b;
    const p = u64MulWide(ua, ub);
    return (a < 0) != (b < 0) ? i128Neg(p) : p;
}

// Unsigned `a > b` of two non-negative values.
// @ts-ignore: decorator
@inline
function i128Gt(a: I128, b: I128): bool {
    return a.hi > b.hi || (a.hi == b.hi && a.lo > b.lo);
}

// Unsigned magnitude division `n / d` (d != 0), both non-negative.
function u128Div(n: I128, d: I128): I128 {
    if (n.hi == 0 && d.hi == 0) {
        return I128(0, n.lo / d.lo);
    }
    // Shift-subtract long division.
    let qHi: u64 = 0;
    let qLo: u64 = 0;
    let rHi: u64 = 0;
    let rLo: u64 = 0;
    const nHi = <u64>n.hi;
    const dHi = <u64>d.hi;
    const dLo = d.lo;
    for (let i = 127; i >= 0; i--) {
        // r = (r << 1) | bit i of n
        rHi = (rHi << 1) | (rLo >> 63);
        const bit: u64 = i >= 64 ? (nHi >> <u64>(i - 64)) & 1 : (n.lo >> <u64>i) & 1;
        rLo = (rLo << 1) | bit;
        if (rHi > dHi || (rHi == dHi && rLo >= dLo)) {
            const borrow: u64 = rLo < dLo ? 1 : 0;
            rLo = rLo - dLo;
            rHi = rHi - dHi - borrow;
            if (i >= 64) {
                qHi |= (<u64>1) << <u64>(i - 64);
            } else {
                qLo |= (<u64>1) << <u64>i;
            }
        }
    }
    return I128(<i64>qHi, qLo);
}

// Signed `a / d` truncating toward zero, for a positive divisor.
export function i128DivPositive(a: I128, d: I128): I128 {
    const q = u128Div(i128Abs(a), d);
    return a.hi < 0 ? i128Neg(q) : q;
}

// `a >> n` for a non-negative value, 0 < n < 64.
function i128ShrNonNeg(a: I128, n: i32): I128 {
    const lo = (a.lo >> <u64>n) | ((<u64>a.hi) << <u64>(64 - n));
    return I128(a.hi >> <i64>n, lo);
}

// ---------------------------------------------------------------------------

// A 3-component i32 position.
export struct I32x3 {
    x: i32 = 0;
    y: i32 = 0;
    z: i32 = 0;
    constructor(x: i32, y: i32, z: i32) {
        this.x = x;
        this.y = y;
        this.z = z;
    }
}

// A 3-component i64 position (the encoder's).
export struct I64x3 {
    x: i64 = 0;
    y: i64 = 0;
    z: i64 = 0;
    constructor(x: i64, y: i64, z: i64) {
        this.x = x;
        this.y = y;
        this.z = z;
    }
}

function clampI32(x: i64): i32 {
    return i64ToI32(x);
}

// Resolves a vertex to its position, once, with no cache.
//
// The corner table used for prediction may be seam-adjusted, which can
// introduce vertex ids that don't correspond to an original point:
// vertex_to_data_map + entry_to_point_id_map resolve back to one. Any break
// in that chain means "no position", which the callers treat as the origin.
export function positionForVertex(
    vertexToDataMap: Array<i32>,
    entryToPointIdMap: EntryToPointIdMap,
    posParent: PredictionParent,
    v: VertexIndex,
): I32x3 {
    const dataId = v < <u32>vertexToDataMap.length ? unchecked(vertexToDataMap[<i32>v]) : -1;
    if (dataId < 0) {
        return I32x3(0, 0, 0);
    }
    const pointId = entryToPointIdMap.get(dataId);
    if (pointId < 0) {
        return I32x3(0, 0, 0);
    }
    const posValId = posParent.mappedIndex(<u32>pointId);
    if (posValId == INVALID_ATTRIBUTE_VALUE_INDEX) {
        return I32x3(0, 0, 0);
    }

    const pos = new StaticArray<i64>(3);
    if (!posParent.readVector3AsI64(<u64>posValId, pos)) {
        return I32x3(0, 0, 0);
    }
    return I32x3(clampI32(pos[0]), clampI32(pos[1]), clampI32(pos[2]));
}

// The position lookup above, memoised per vertex: the predictor asks for a
// vertex's position once per incident corner and again for each neighbour's
// own prediction, and the lookup is pure in the vertex.
export class CornerPositions {
    cornerTable: CornerTable;
    vertexToDataMap: Array<i32>;
    entryToPointIdMap: EntryToPointIdMap;
    posParent: PredictionParent;
    // Indexed by vertex id (3 values each); `cached[v]` says whether filled.
    private cache: Int32Array;
    private cached: Uint8Array;

    constructor(
        cornerTable: CornerTable,
        vertexToDataMap: Array<i32>,
        entryToPointIdMap: EntryToPointIdMap,
        posParent: PredictionParent,
    ) {
        this.cornerTable = cornerTable;
        this.vertexToDataMap = vertexToDataMap;
        this.entryToPointIdMap = entryToPointIdMap;
        this.posParent = posParent;
        // A vertex outside the map has no position anyway.
        const numVertices = vertexToDataMap.length;
        this.cache = new Int32Array(numVertices * 3);
        this.cached = new Uint8Array(numVertices);
    }

    get(cornerId: CornerIndex): I32x3 {
        if (cornerId == INVALID_CORNER_INDEX) {
            return I32x3(0, 0, 0);
        }
        return this.getByVertex(this.cornerTable.vertex(cornerId));
    }

    // Same cache as `get`, keyed directly by vertex.
    getByVertex(v: VertexIndex): I32x3 {
        if (v >= <u32>this.cached.length) {
            // Off the end of the map: the uncached path returns the origin.
            return positionForVertex(this.vertexToDataMap, this.entryToPointIdMap, this.posParent, v);
        }
        const vi = <i32>v;
        if (this.cached[vi] != 0) {
            return I32x3(this.cache[vi * 3], this.cache[vi * 3 + 1], this.cache[vi * 3 + 2]);
        }
        const pos = positionForVertex(this.vertexToDataMap, this.entryToPointIdMap, this.posParent, v);
        this.cache[vi * 3] = pos.x;
        this.cache[vi * 3 + 1] = pos.y;
        this.cache[vi * 3 + 2] = pos.z;
        this.cached[vi] = 1;
        return pos;
    }
}

const UPPER_BOUND_128: I128 = I128(0, <u64>1 << 29);

// Predicts one normal from the geometry around `cornerId` (decoder side),
// into `prediction[0..3]`.
export function computePredictedValue(
    positions: CornerPositions,
    predictionMode: NormalPredictionMode,
    cornerId: CornerIndex,
    prediction: StaticArray<i32>,
): void {
    if (cornerId == INVALID_CORNER_INDEX) {
        prediction[0] = 0;
        prediction[1] = 0;
        prediction[2] = 0;
        return;
    }

    const cornerTable = positions.cornerTable;
    const posCent = positions.get(cornerId);

    let n0 = I128(0, 0);
    let n1 = I128(0, 0);
    let n2 = I128(0, 0);

    const cit = new VertexCornersIterator(cornerTable, cornerId);
    while (!cit.end()) {
        let vNextId: VertexIndex;
        let vPrevId: VertexIndex;
        if (predictionMode == NormalPredictionMode.OneTriangle) {
            vNextId = cornerTable.vertexAfter(cornerId);
            vPrevId = cornerTable.vertexBefore(cornerId);
        } else {
            vNextId = cornerTable.vertexAfter(cit.corner());
            vPrevId = cornerTable.vertexBefore(cit.corner());
        }

        const posPrev = positions.getByVertex(vPrevId);
        const posNext = positions.getByVertex(vNextId);

        const nx = <i64>posNext.x - <i64>posCent.x;
        const ny = <i64>posNext.y - <i64>posCent.y;
        const nz = <i64>posNext.z - <i64>posCent.z;
        const px = <i64>posPrev.x - <i64>posCent.x;
        const py = <i64>posPrev.y - <i64>posCent.y;
        const pz = <i64>posPrev.z - <i64>posCent.z;

        n0 = i128Add(n0, i128Sub(i128MulI64(ny, pz), i128MulI64(nz, py)));
        n1 = i128Add(n1, i128Sub(i128MulI64(nz, px), i128MulI64(nx, pz)));
        n2 = i128Add(n2, i128Sub(i128MulI64(nx, py), i128MulI64(ny, px)));

        if (predictionMode == NormalPredictionMode.OneTriangle) {
            break;
        }

        cit.next(cornerTable);
    }

    if (i128IsZero(n0) && i128IsZero(n1) && i128IsZero(n2)) {
        prediction[0] = 0;
        prediction[1] = 0;
        prediction[2] = 0;
        return;
    }

    const absSum = i128Add(i128Add(i128Abs(n0), i128Abs(n1)), i128Abs(n2));
    if (i128Gt(absSum, UPPER_BOUND_128)) {
        // abs_sum / 2^29 on a non-negative value.
        const quotient = i128ShrNonNeg(absSum, 29);
        n0 = i128DivPositive(n0, quotient);
        n1 = i128DivPositive(n1, quotient);
        n2 = i128DivPositive(n2, quotient);
    }

    // `as i32` keeps the low 32 bits.
    prediction[0] = <i32>n0.lo;
    prediction[1] = <i32>n1.lo;
    prediction[2] = <i32>n2.lo;
}

// Walks every corner attached to the vertex of the corner it starts from:
// sweeps right from the start; only a boundary stops it early, and then the
// walk goes back to the start and sweeps left for the rest of the fan.
export class VertexCornersIterator {
    // Where the walk began, and what the right sweep must not return to.
    private startCorner: CornerIndex;
    private corner_: CornerIndex;
    // Set once the right sweep has run into a boundary.
    private sweepingLeft: bool = false;
    private isEnd: bool;

    constructor(_cornerTable: CornerTable, cornerId: CornerIndex) {
        this.startCorner = cornerId;
        this.corner_ = cornerId;
        this.isEnd = cornerId == INVALID_CORNER_INDEX;
    }

    corner(): CornerIndex {
        return this.corner_;
    }

    end(): bool {
        return this.isEnd || this.corner_ == INVALID_CORNER_INDEX;
    }

    next(cornerTable: CornerTable): void {
        if (this.corner_ == INVALID_CORNER_INDEX) {
            return;
        }

        if (!this.sweepingLeft) {
            const right = cornerTable.swingRight(this.corner_);
            if (right == this.startCorner) {
                // Closed ring, back where it started.
                this.finish();
                return;
            }
            if (right != INVALID_CORNER_INDEX) {
                this.corner_ = right;
                return;
            }
            // Boundary: the corners left of the start are still unvisited.
            this.sweepingLeft = true;
            this.setOrFinish(cornerTable.swingLeft(this.startCorner));
            return;
        }

        this.setOrFinish(cornerTable.swingLeft(this.corner_));
    }

    private setOrFinish(corner: CornerIndex): void {
        // Back at the start during the left sweep: treat it as the end
        // rather than lapping the fan forever.
        if (corner == INVALID_CORNER_INDEX || corner == this.startCorner) {
            this.finish();
        } else {
            this.corner_ = corner;
        }
    }

    private finish(): void {
        this.corner_ = INVALID_CORNER_INDEX;
        this.isEnd = true;
    }
}

export class MeshPredictionSchemeGeometricNormalDecoder extends PredictionSchemeDecoder {
    transform: PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform;
    meshData: MeshPredictionSchemeData? = null;
    posParent: PredictionParent? = null;
    entryToPointIdMap: EntryToPointIdMap? = null;
    predictionMode: NormalPredictionMode = NormalPredictionMode.TriangleArea;
    octahedronToolBox: OctahedronToolBox = new OctahedronToolBox();
    flipNormalBits: Array<bool> = [];
    flipNormalBitIndex: i32 = 0;

    constructor(transform: PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform) {
        super();
        this.transform = transform;
    }

    setEntryToPointIdMap(pointIds: EntryToPointIdMap): void {
        this.entryToPointIdMap = pointIds;
    }

    init(meshData: MeshPredictionSchemeData): void {
        this.meshData = meshData.clone();
    }

    isInitialized(): bool {
        const md = this.meshData;
        return md != null &&
            md.cornerTable() != null &&
            md.dataToCornerMap() != null &&
            this.posParent != null &&
            this.entryToPointIdMap != null;
    }

    // The position lookup the predictor runs on, resolved from this decoder's
    // own state (for the tests; the decode pass builds its own).
    cornerPositions(): CornerPositions? {
        const md = this.meshData;
        if (md == null) return null;
        const table = md.cornerTable();
        if (table == null) return null;
        const v2d = md.vertexToDataMap();
        if (v2d == null) return null;
        const map = this.entryToPointIdMap;
        if (map == null) return null;
        const parent = this.posParent;
        if (parent == null) return null;
        return new CornerPositions(table, v2d, map, parent);
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionGeometricNormal;
    }

    getNumParentAttributes(): i32 {
        return 1;
    }

    getParentAttributeType(i: i32): GeometryAttributeType {
        if (i != 0) {
            panic(`assertion \`left == right\` failed\n  left: ${i}\n right: 0`);
        }
        return GeometryAttributeType.Position;
    }

    setParentAttribute(parent: PredictionParent): Status {
        if (parent.attributeType() != GeometryAttributeType.Position) {
            return DracoError.invalidParameter(
                `Geometric normal prediction needs a position parent, got ${geometryAttributeTypeDebug(parent.attributeType())}`,
            ).fail<bool>();
        }
        if (parent.numComponents() != 3) {
            return DracoError.invalidParameter(
                `Geometric normal prediction needs a 3-component parent, got ${parent.numComponents()}`,
            ).fail<bool>();
        }
        this.posParent = parent;
        return okStatus();
    }

    getTransformType(): PredictionSchemeTransformType {
        return PredictionSchemeTransformType.NormalOctahedronCanonicalized;
    }

    computeOriginalValues(
        data: Int32Array,
        _size: i32,
        numComponents: i32,
        _entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        if (!this.isInitialized()) {
            return DracoError.general("Geometric normal prediction was never initialized").fail<bool>();
        }

        // The octahedral coordinates are a pair.
        if (numComponents != 2) {
            return DracoError.invalidParameter(
                `Geometric normal prediction needs 2 octahedral components, got ${numComponents}`,
            ).fail<bool>();
        }
        const si = this.transform.init(numComponents);
        if (!si.ok) return si;

        const md = this.meshData;
        if (md == null) {
            return DracoError.general("Geometric normal prediction has no mesh data").fail<bool>();
        }
        const d2cOpt = md.dataToCornerMap();
        if (d2cOpt == null) {
            return DracoError.general("Geometric normal prediction has no data-to-corner map").fail<bool>();
        }
        const dataToCornerMap = d2cOpt;
        const cornerMapSize = dataToCornerMap.length;
        const needed = <i64>cornerMapSize * <i64>numComponents;
        if (needed > <i64>data.length) {
            return DracoError.general(
                `Geometric normal prediction needs ${needed} values, has ${data.length}`,
            ).fail<bool>();
        }

        // Resolved once for the pass. A missing vertex-to-data map leaves every
        // position at the origin, which predicts a zero normal for every entry.
        const positions = this.cornerPositions();

        const predNormal3d = new StaticArray<i32>(3);
        const prediction = new Int32Array(2);

        for (let i = 0; i < cornerMapSize; i++) {
            const cornerId = unchecked(dataToCornerMap[i]);
            if (positions != null) {
                computePredictedValue(positions, this.predictionMode, cornerId, predNormal3d);
            } else {
                predNormal3d[0] = 0;
                predNormal3d[1] = 0;
                predNormal3d[2] = 0;
            }
            this.octahedronToolBox.canonicalizeIntegerVector(predNormal3d);

            const idx = this.flipNormalBitIndex;
            if (idx >= 0 && idx < this.flipNormalBits.length && this.flipNormalBits[idx]) {
                predNormal3d[0] = -predNormal3d[0];
                predNormal3d[1] = -predNormal3d[1];
                predNormal3d[2] = -predNormal3d[2];
            }
            this.flipNormalBitIndex += 1;

            const st = this.octahedronToolBox.integerVectorToQuantizedOctahedralCoords(predNormal3d);
            prediction[0] = st.s;
            prediction[1] = st.t;

            const offset = i * numComponents;
            this.transform.computeOriginalValue(prediction, 0, data, offset, numComponents);
        }
        return okStatus();
    }

    // Everything decodePredictionData reads, from the current position; the
    // caller rewinds on failure.
    private tryDecodeAtPos(buf: DecoderBuffer, bitstreamVersion: u16): Status {
        const s = this.transform.decodeTransformData(buf);
        if (!s.ok) return s;

        // Set up the octahedral toolbox from the decoded transform.
        this.octahedronToolBox.setQuantizationBits(this.transform.quantizationBits());

        // Backward compatibility: bitstreams < 2.2 store the prediction mode.
        if (bitstreamVersion < 0x0202) {
            const r = buf.decodeU8();
            if (!r.ok) {
                return DracoError.buffer("Stream ends before the pre-2.2 normal prediction mode").fail<bool>();
            }
            const mode = r.value;
            if (mode > <u8>NormalPredictionMode.TriangleArea) {
                return DracoError.unsupportedFeature(`Normal prediction mode ${mode}`).fail<bool>();
            }
            this.predictionMode = mode == 0 ? NormalPredictionMode.OneTriangle : NormalPredictionMode.TriangleArea;
        }

        const md = this.meshData;
        const d2c = md != null ? md.dataToCornerMap() : null;
        if (d2c == null) {
            return DracoError.general("Geometric normal prediction has no data-to-corner map").fail<bool>();
        }
        const numValues = d2c.length;

        const bits = this.flipNormalBits;
        bits.length = 0;

        const decoder = new RAnsBitDecoder();
        if (!decoder.startDecoding(buf)) {
            return DracoError.buffer("Normal flip-bit rANS stream is truncated").fail<bool>();
        }

        for (let i = 0; i < numValues; i++) {
            bits.push(decoder.decodeNextBit());
        }
        decoder.endDecoding();
        this.flipNormalBitIndex = 0;
        return okStatus();
    }

    decodePredictionData(buffer: DecoderBuffer): Status {
        const startPos = buffer.position();
        const bitstreamVersion: u16 = buffer.bitstreamVersion();
        // Legacy (< 2.2) bitstreams are decoded too; nothing is refused here.

        const r = this.tryDecodeAtPos(buffer, bitstreamVersion);
        if (!r.ok) {
            buffer.setPosition(<u64>startPos);
        }
        return r;
    }
}

// The encoder's position lookup, memoised per vertex; the encoder works in
// unclamped i64.
export class EncoderCornerPositions {
    cornerTable: CornerTable;
    vertexToDataMap: Array<i32>;
    map: EntryToPointIdMap;
    posParent: PredictionParent;
    private cache: Int64Array;
    private cached: Uint8Array;
    private scratch: StaticArray<i64> = new StaticArray<i64>(3);

    constructor(
        cornerTable: CornerTable,
        vertexToDataMap: Array<i32>,
        map: EntryToPointIdMap,
        posParent: PredictionParent,
    ) {
        this.cornerTable = cornerTable;
        this.vertexToDataMap = vertexToDataMap;
        this.map = map;
        this.posParent = posParent;
        const numVertices = vertexToDataMap.length;
        this.cache = new Int64Array(numVertices * 3);
        this.cached = new Uint8Array(numVertices);
    }

    get(ci: CornerIndex): I64x3 {
        const vertex = this.cornerTable.vertex(ci);
        if (vertex >= <u32>this.cached.length) {
            return this.lookup(vertex);
        }
        const vi = <i32>vertex;
        if (this.cached[vi] != 0) {
            return I64x3(this.cache[vi * 3], this.cache[vi * 3 + 1], this.cache[vi * 3 + 2]);
        }
        const pos = this.lookup(vertex);
        this.cache[vi * 3] = pos.x;
        this.cache[vi * 3 + 1] = pos.y;
        this.cache[vi * 3 + 2] = pos.z;
        this.cached[vi] = 1;
        return pos;
    }

    private lookup(vertex: u32): I64x3 {
        // A vertex past the map's end panics.
        if (vertex >= <u32>this.vertexToDataMap.length) {
            panic(`index out of bounds: the len is ${this.vertexToDataMap.length} but the index is ${vertex}`);
        }
        const dataId = unchecked(this.vertexToDataMap[<i32>vertex]);

        // A negative data id is past every map.
        const pointId = dataId < 0 ? <i64>-1 : this.map.get(dataId);
        if (pointId < 0) {
            return I64x3(0, 0, 0);
        }
        const posValId = this.posParent.mappedIndex(<u32>pointId);

        const pos = this.scratch;
        pos[0] = 0;
        pos[1] = 0;
        pos[2] = 0;
        if (!this.posParent.readVector3AsI64(<u64>posValId, pos)) {
            return I64x3(0, 0, 0);
        }
        return I64x3(pos[0], pos[1], pos[2]);
    }
}

// Cross product of two 64-bit integer vectors, wrapping on overflow.
export function crossProduct(a: I64x3, b: I64x3): I64x3 {
    return I64x3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

// @ts-ignore: decorator
@inline
function wrappingAbsI64(v: i64): i64 {
    return v < 0 ? -v : v;
}

// Predicts one normal from the geometry around `cornerId`, encoder side,
// into `prediction[0..3]`. Every step wraps on purpose (upstream reaches the
// same by C++ overflow and uint64_t accumulation).
export function computeEncoderPredictedValue(
    positions: EncoderCornerPositions,
    predictionMode: NormalPredictionMode,
    cornerId: CornerIndex,
    prediction: StaticArray<i32>,
): void {
    if (cornerId == INVALID_CORNER_INDEX) {
        prediction[0] = 0;
        prediction[1] = 0;
        prediction[2] = 0;
        return;
    }

    const cornerTable = positions.cornerTable;
    const cit = new VertexCornersIterator(cornerTable, cornerId);
    const posCent = positions.get(cornerId);

    let nx: i64 = 0;
    let ny: i64 = 0;
    let nz: i64 = 0;

    while (!cit.end()) {
        const base = predictionMode == NormalPredictionMode.OneTriangle ? cornerId : cit.corner();
        const cNext = cornerTable.next(base);
        const cPrev = cornerTable.previous(base);

        const posNext = positions.get(cNext);
        const posPrev = positions.get(cPrev);

        const deltaNext = I64x3(posNext.x - posCent.x, posNext.y - posCent.y, posNext.z - posCent.z);
        const deltaPrev = I64x3(posPrev.x - posCent.x, posPrev.y - posCent.y, posPrev.z - posCent.z);

        const cross = crossProduct(deltaNext, deltaPrev);

        nx = nx + cross.x;
        ny = ny + cross.y;
        nz = nz + cross.z;

        cit.next(cornerTable);

        if (predictionMode == NormalPredictionMode.OneTriangle) {
            break;
        }
    }

    const upperBound: i64 = 1 << 29;
    // Wrapping: a wrapped normal can sit at i64::MIN.
    const absSum = wrappingAbsI64(nx) + wrappingAbsI64(ny) + wrappingAbsI64(nz);

    if (absSum > upperBound) {
        const quotient = absSum / upperBound;
        if (quotient > 0) {
            nx /= quotient;
            ny /= quotient;
            nz /= quotient;
        }
    }

    prediction[0] = <i32>nx;
    prediction[1] = <i32>ny;
    prediction[2] = <i32>nz;
}

export class MeshPredictionSchemeGeometricNormalEncoder extends PredictionSchemeEncoder {
    transform: PredictionSchemeNormalOctahedronCanonicalizedEncodingTransform;
    // Held apart from the transform, as the C++ encoder holds
    // octahedron_tool_box_.
    octahedronToolBox: OctahedronToolBox = new OctahedronToolBox();
    meshData: MeshPredictionSchemeData? = null;
    posParent: PredictionParent? = null;
    predictionMode: NormalPredictionMode = NormalPredictionMode.TriangleArea;
    flipNormalBitEncoder: RAnsBitEncoder = new RAnsBitEncoder();
    // Target bitstream, packed as 0xMMmm; 0 means the newest.
    bitstreamVersion: u16 = 0;

    constructor(transform: PredictionSchemeNormalOctahedronCanonicalizedEncodingTransform) {
        super();
        this.transform = transform;
    }

    // Targets a specific bitstream version (read off the encoder options).
    setBitstreamVersion(major: u8, minor: u8): void {
        this.bitstreamVersion = packVersion(major, minor);
    }

    init(meshData: MeshPredictionSchemeData): void {
        this.meshData = meshData.clone();
    }

    getPredictionMethod(): PredictionSchemeMethod {
        return PredictionSchemeMethod.MeshPredictionGeometricNormal;
    }

    isInitialized(): bool {
        return this.meshData != null && this.posParent != null;
    }

    getNumParentAttributes(): i32 {
        return 1;
    }

    getParentAttributeType(i: i32): GeometryAttributeType {
        return i == 0 ? GeometryAttributeType.Position : GeometryAttributeType.Invalid;
    }

    setParentAttribute(parent: PredictionParent): Status {
        if (parent.attributeType() != GeometryAttributeType.Position) {
            return DracoError.invalidParameter(
                `Geometric normal prediction needs a position parent, got ${geometryAttributeTypeDebug(parent.attributeType())}`,
            ).fail<bool>();
        }
        this.posParent = parent;
        return okStatus();
    }

    getTransformType(): PredictionSchemeTransformType {
        return this.transform.getType();
    }

    computeCorrectionValues(
        inData: Int32Array,
        outCorr: Int32Array,
        _size: i32,
        numComponents: i32,
        entryToPointIdMap: EntryToPointIdMap?,
    ): Status {
        if (!this.isInitialized()) {
            return DracoError.general("Geometric normal prediction was never initialized").fail<bool>();
        }

        if (entryToPointIdMap == null) {
            return DracoError.invalidParameter("Geometric normal prediction needs an entry-to-point map").fail<bool>();
        }
        const map = entryToPointIdMap;

        // Expecting in_data in octahedral coordinates (portable attribute).
        if (numComponents != 2) {
            return DracoError.invalidParameter(
                `Geometric normal prediction needs 2 octahedral components, got ${numComponents}`,
            ).fail<bool>();
        }

        // SetQuantizationBits(transform().quantization_bits()).
        if (!this.octahedronToolBox.setQuantizationBits(this.transform.quantizationBits())) {
            return DracoError.invalidParameter(
                `Octahedral quantization bits ${this.transform.quantizationBits()} outside the supported range 2..=30`,
            ).fail<bool>();
        }

        this.flipNormalBitEncoder.startEncoding();

        const UNWRAP_NONE = "called `Option::unwrap()` on a `None` value";
        const md = this.meshData;
        if (md == null) return panicAs<Status>(UNWRAP_NONE);
        const d2c = md.dataToCornerMap();
        if (d2c == null) return panicAs<Status>(UNWRAP_NONE);
        const dataToCornerMap = d2c;
        const table = md.cornerTable();
        if (table == null) return panicAs<Status>(UNWRAP_NONE);
        const v2d = md.vertexToDataMap();
        if (v2d == null) return panicAs<Status>(UNWRAP_NONE);
        const parent = this.posParent;
        if (parent == null) return panicAs<Status>(UNWRAP_NONE);
        const positions = new EncoderCornerPositions(table, v2d, map, parent);

        const predNormal3d = new StaticArray<i32>(3);
        const negNormal3d = new StaticArray<i32>(3);
        const posPredNormalOct = new Int32Array(2);
        const negPredNormalOct = new Int32Array(2);
        const posCorrection = new Int32Array(2);
        const negCorrection = new Int32Array(2);
        const tb = this.octahedronToolBox;

        // Over the corner map, not over `size` (upstream loops to
        // data_to_corner_map()->size()).
        const cornerMapSize = dataToCornerMap.length;
        for (let i = 0; i < cornerMapSize; i++) {
            const cornerId = unchecked(dataToCornerMap[i]);

            computeEncoderPredictedValue(positions, this.predictionMode, cornerId, predNormal3d);

            tb.canonicalizeIntegerVector(predNormal3d);

            // Octahedral coordinates for both possible directions.
            const posSt = tb.integerVectorToQuantizedOctahedralCoords(predNormal3d);
            posPredNormalOct[0] = posSt.s;
            posPredNormalOct[1] = posSt.t;

            negNormal3d[0] = -predNormal3d[0];
            negNormal3d[1] = -predNormal3d[1];
            negNormal3d[2] = -predNormal3d[2];
            const negSt = tb.integerVectorToQuantizedOctahedralCoords(negNormal3d);
            negPredNormalOct[0] = negSt.s;
            negPredNormalOct[1] = negSt.t;

            const offset = i * numComponents;
            // Reading `inData[offset..offset + numComponents]` panics past the end.
            if (offset + numComponents > inData.length) {
                panic(`range end index ${offset + numComponents} out of range for slice of length ${inData.length}`);
            }

            this.transform.computeCorrection(inData, offset, posPredNormalOct, 0, posCorrection, 0, numComponents);
            this.transform.computeCorrection(inData, offset, negPredNormalOct, 0, negCorrection, 0, numComponents);

            posCorrection[0] = tb.modMax(posCorrection[0]);
            posCorrection[1] = tb.modMax(posCorrection[1]);
            negCorrection[0] = tb.modMax(negCorrection[0]);
            negCorrection[1] = tb.modMax(negCorrection[1]);

            const posAbsSum = absI32(posCorrection[0]) + absI32(posCorrection[1]);
            const negAbsSum = absI32(negCorrection[0]) + absI32(negCorrection[1]);

            if (posAbsSum < negAbsSum) {
                this.flipNormalBitEncoder.encodeBit(false);
                outCorr[offset] = tb.makePositive(posCorrection[0]);
                outCorr[offset + 1] = tb.makePositive(posCorrection[1]);
            } else {
                this.flipNormalBitEncoder.encodeBit(true);
                outCorr[offset] = tb.makePositive(negCorrection[0]);
                outCorr[offset + 1] = tb.makePositive(negCorrection[1]);
            }
        }
        return okStatus();
    }

    encodePredictionData(buffer: ByteVec): Status {
        const s = this.transform.encodeTransformData(buffer);
        if (!s.ok) return s;

        // Pre-2.2 carries the prediction mode between the transform data and
        // the flip bits; 2.2 dropped it and assumes triangle area.
        if (this.bitstreamVersion != 0 && this.bitstreamVersion < 0x0202) {
            buffer.push(<u8>this.predictionMode);
        }

        const tempBuffer = new EncoderBuffer();
        // The flip-bit rANS size prefix is a u32 pre-2.2 and a varint after.
        tempBuffer.setVersion(<u8>(this.bitstreamVersion >> 8), <u8>(this.bitstreamVersion & 0xff));
        this.flipNormalBitEncoder.endEncoding(tempBuffer);
        buffer.extend(tempBuffer.data());
        return okStatus();
    }
}

// @ts-ignore: decorator
@inline
function absI32(v: i32): i32 {
    return v < 0 ? -v : v;
}
