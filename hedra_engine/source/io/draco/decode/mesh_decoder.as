// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Decoder for Draco triangle-mesh bitstreams. Reads a `.drc` stream written by
// MeshEncoder (or C++ Draco) and rebuilds a Mesh: faces, attributes and
// metadata. It handles both EdgeBreaker and sequential connectivity and
// dequantizes attributes back to their original data types. A point-cloud
// stream (geometry type 0) is decoded into the mesh's point cloud, with no
// faces.
//
// Notes:
//   - The traversal observers and the max-prediction-degree walk are small
//     classes holding their state.
//   - Point-id and corner lists are Array<u32> (PointIndex/CornerIndex are
//     u32 aliases); counts read from the stream are u64.
//   - The mesh's point count is an i32 (PointCloud.numPoints). A sequential
//     stream declaring more than i32::MAX points keeps the full u64 count for
//     the attribute stage (so every refusal there sees the declared count);
//     a decode that would otherwise succeed with such a count (no attribute
//     at all) fails with "Mesh declares N points, more than this decoder can index".

import { Result, panic } from "../../../../base/util";
import { BYTE_VEC_MAX_CAPACITY } from "../core/byte_vec";
import { DecoderBuffer } from "../core/decoder_buffer";
import { dataTypeByteLength, dataTypeTryFrom } from "../core/draco_types";
import { DracoError, Status, okStatus } from "../core/status";
import { DracoVersion, VERSION_FLAGS_INTRODUCED, bitstreamVersion as packBitstreamVersion, versionAtLeast } from "../core/version";
import { ensureSymbolsAreBacked } from "../core/decode_budget";
import { SymbolEncodingOptions, decodeSymbols } from "../entropy/symbol_encoding";
import { AttributeOctahedronTransform } from "../geometry/attribute_octahedron_transform";
import { U64_NONE, checkedMulU64 } from "../geometry/bytes";
import { EncodedGeometryType } from "../geometry/compression_config";
import {
    GeometryAttributeType,
    PointAttribute,
    geometryAttributeTypeTryFrom,
} from "../geometry/geometry_attribute";
import {
    CornerIndex,
    INVALID_ATTRIBUTE_VALUE_INDEX,
    INVALID_CORNER_INDEX,
    INVALID_FACE_INDEX,
    INVALID_VERTEX_INDEX,
    PointIndex,
    VertexIndex,
} from "../geometry/geometry_indices";
import { Face, Mesh } from "../geometry/mesh";
import { GeometryMetadata, METADATA_FLAG_MASK } from "../geometry/metadata";
import { CornerTable, getU32At, setU32At } from "../mesh/corner_table";
import { NewVertexObserver, traverseFromCorner } from "../mesh/corner_traversal";
import { SeamCut, cutSeamEdgesAndRecomputeVertices } from "../mesh/mesh_attribute_corner_table";
import { EntryToPointIdMap } from "../prediction/prediction_scheme";
import { MeshEdgebreakerDecoder } from "./mesh_edgebreaker_decoder";
import {
    PendingNormal,
    PendingQuant,
    PointCloudDecoder,
    findPendingNormal,
    findPendingQuant,
    isDracoMagic,
    satMulU64,
    validateNumAttributesInDecoder,
    validateNumComponents,
} from "./point_cloud_decoder";
import { SequentialGenericAttributeDecoder } from "./sequential_generic_attribute_decoder";
import { PortableExtent, SequentialIntegerAttributeDecoder } from "./sequential_integer_attribute_decoder";
import { SequentialNormalAttributeDecoder } from "./sequential_normal_attribute_decoder";
import { SequentialQuantizationAttributeDecoder } from "./sequential_quantization_attribute_decoder";

// Output of an edgebreaker attribute traversal: point ids in traversal
// order, processed corners, and the vertex -> data-id map.
export class AttributeTraversalArrays {
    pointIds: Array<u32>;
    dataToCornerMap: Array<u32>;
    vertexToDataMap: Array<i32>;

    constructor(pointIds: Array<u32>, dataToCornerMap: Array<u32>, vertexToDataMap: Array<i32>) {
        this.pointIds = pointIds;
        this.dataToCornerMap = dataToCornerMap;
        this.vertexToDataMap = vertexToDataMap;
    }

    // A deep copy.
    clone(): AttributeTraversalArrays {
        return new AttributeTraversalArrays(
            this.pointIds.slice(0),
            this.dataToCornerMap.slice(0),
            this.vertexToDataMap.slice(0),
        );
    }
}

// A portable attribute and its attribute id.
class PortableById {
    id: i32;
    att: PointAttribute;

    constructor(id: i32, att: PointAttribute) {
        this.id = id;
        this.att = att;
    }
}

// Copies `source`'s point-to-value map onto `target` for `numPoints` points.
export function copyPointMapping(source: PointAttribute, target: PointAttribute, numPoints: i32): Status {
    // One copy when the source's map is already the exact shape asked for.
    const map = source.explicitMapping();
    if (map != null) {
        if (map.length == numPoints) {
            target.setExplicitMappingFrom(map);
            return okStatus();
        }
    }
    target.setExplicitMapping(numPoints);
    for (let point = 0; point < numPoints; point++) {
        const pointId: PointIndex = <u32>point;
        const s = target.trySetPointMapEntry(pointId, source.mappedIndex(pointId));
        if (!s.ok) return s;
    }
    return okStatus();
}

// Per corner-table vertex, the data id whose corner names it (-1 for none).
export function buildVertexToDataMapFromCornerMap(cornerTable: CornerTable, dataToCornerMap: Array<u32>): Result<Array<i32>> {
    const vertexToDataMap = new Array<i32>(cornerTable.numVertices());
    vertexToDataMap.fill(-1);
    for (let i = 0; i < dataToCornerMap.length; i++) {
        const corner: CornerIndex = dataToCornerMap[i];
        if (corner == INVALID_CORNER_INDEX) {
            continue;
        }
        if (<i64>corner >= <i64>cornerTable.numCorners()) {
            return DracoError.general("Data-to-corner map references an invalid corner").fail<Array<i32>>();
        }
        const vertex = cornerTable.vertex(corner);
        if (vertex == INVALID_VERTEX_INDEX) {
            continue;
        }
        if (<i64>vertex >= <i64>vertexToDataMap.length) {
            return DracoError.general("Data-to-corner map references an invalid vertex").fail<Array<i32>>();
        }
        vertexToDataMap[<i32>vertex] = i;
    }
    return Result.okv<Array<i32>>(vertexToDataMap);
}

function upsertPortableAttribute(portableAttributesById: Array<PortableById>, attId: i32, portable: PointAttribute): void {
    for (let i = 0; i < portableAttributesById.length; i++) {
        if (portableAttributesById[i].id == attId) {
            portableAttributesById[i].att = portable;
            return;
        }
    }
    portableAttributesById.push(new PortableById(attId, portable));
}

function findPortable(portableAttributesById: Array<PortableById>, attId: i32): PointAttribute? {
    for (let i = 0; i < portableAttributesById.length; i++) {
        if (portableAttributesById[i].id == attId) return portableAttributesById[i].att;
    }
    return null;
}

// `a[i] = v`, panicking out of bounds (a plain AS Array write past the end
// would grow it).
function setBoolAt(a: Array<bool>, i: u32, v: bool): void {
    if (<i64>i >= <i64>a.length) {
        panic("index out of bounds: the len is " + a.length.toString() + " but the index is " + i.toString());
    }
    unchecked((a[<i32>i] = v));
}

function getBoolAt(a: Array<bool>, i: u32): bool {
    if (<i64>i >= <i64>a.length) {
        panic("index out of bounds: the len is " + a.length.toString() + " but the index is " + i.toString());
    }
    return unchecked(a[<i32>i]);
}

// Mesh::CornerToPointId: the point a corner names (u32.MAX_VALUE for the invalid
// corner; panics on a corner past the faces).
function cornerToPointId(mesh: Mesh, c: CornerIndex): PointIndex {
    if (c == INVALID_CORNER_INDEX) {
        return u32.MAX_VALUE;
    }
    const faceId = c / 3;
    const cornerOffset = <i32>(c % 3);
    return mesh.face(faceId).get(cornerOffset);
}

// The depth-first traversal observer:
// records each newly visited vertex, its slot in the attribute data order
// and the corner it was discovered through.
class DfsVisitObserver extends NewVertexObserver {
    mesh: Mesh;
    pointIds: Array<u32>;
    dataToCornerMap: Array<u32>;
    vertexToDataMap: Array<i32>;
    numVisited: i32 = 0;

    constructor(mesh: Mesh, pointIds: Array<u32>, dataToCornerMap: Array<u32>, vertexToDataMap: Array<i32>) {
        super();
        this.mesh = mesh;
        this.pointIds = pointIds;
        this.dataToCornerMap = dataToCornerMap;
        this.vertexToDataMap = vertexToDataMap;
    }

    onNewVertex(vertex: VertexIndex, corner: CornerIndex): void {
        const pointId = cornerToPointId(this.mesh, corner);
        if (<i64>vertex >= <i64>this.vertexToDataMap.length) {
            panic(
                "index out of bounds: the len is " + this.vertexToDataMap.length.toString() + " but the index is " +
                vertex.toString(),
            );
        }
        unchecked((this.vertexToDataMap[<i32>vertex] = this.numVisited));
        // Written only while both slots exist.
        if (this.numVisited < this.pointIds.length && this.numVisited < this.dataToCornerMap.length) {
            unchecked((this.pointIds[this.numVisited] = pointId));
            unchecked((this.dataToCornerMap[this.numVisited] = corner));
            this.numVisited += 1;
        }
    }
}

// The state of the max-prediction-degree traversal (point ids, priority
// stacks, best priority, ...).
class MaxPredictionDegreeWalk {
    mesh: Mesh;
    cornerTable: CornerTable;
    pointIds: Array<u32> = new Array<u32>();
    dataToCornerMap: Array<u32> = new Array<u32>();
    vertexToDataMap: Array<i32>;
    visitedVertices: Array<bool>;
    visitedFaces: Array<bool>;
    predictionDegree: Array<i32>;
    // Buckets (stacks) for priorities 0..2.
    stacks: StaticArray<Array<u32>> = [new Array<u32>(), new Array<u32>(), new Array<u32>()];
    bestPriority: i32 = 0;

    constructor(mesh: Mesh, cornerTable: CornerTable) {
        this.mesh = mesh;
        this.cornerTable = cornerTable;
        const numVertices = cornerTable.numVertices();
        const numFaces = cornerTable.numFaces();
        this.vertexToDataMap = new Array<i32>(numVertices);
        this.vertexToDataMap.fill(-1);
        this.visitedVertices = new Array<bool>(numVertices);
        this.visitedFaces = new Array<bool>(numFaces);
        this.predictionDegree = new Array<i32>(numVertices);
    }

    private visitVertex(v: VertexIndex, c: CornerIndex): void {
        if (v == INVALID_VERTEX_INDEX) {
            return;
        }
        if (<i64>v >= <i64>this.visitedVertices.length) {
            return;
        }
        const vi = <i32>v;
        if (!this.visitedVertices[vi]) {
            this.visitedVertices[vi] = true;
            // The vertex's data id is the current length of the point ids.
            this.vertexToDataMap[vi] = this.pointIds.length;
            const pointId = cornerToPointId(this.mesh, c);
            this.pointIds.push(pointId);
            this.dataToCornerMap.push(c);
        }
    }

    private computePriority(cornerId: CornerIndex): i32 {
        if (cornerId == INVALID_CORNER_INDEX) {
            return 2;
        }
        const vTip = this.cornerTable.vertex(cornerId);
        if (vTip == INVALID_VERTEX_INDEX) {
            return 2;
        }
        if (<i64>vTip < <i64>this.visitedVertices.length && this.visitedVertices[<i32>vTip]) {
            return 0;
        }
        if (<i64>vTip < <i64>this.predictionDegree.length) {
            const vi = <i32>vTip;
            this.predictionDegree[vi] += 1;
            return this.predictionDegree[vi] > 1 ? 1 : 2;
        }
        return 2;
    }

    private addCornerToStack(ci: CornerIndex, priority: i32): void {
        const p = min(priority, 2);
        this.stacks[p].push(ci);
        if (p < this.bestPriority) {
            this.bestPriority = p;
        }
    }

    private popNextCorner(): CornerIndex {
        for (let p = this.bestPriority; p < 3; p++) {
            const s = this.stacks[p];
            if (s.length > 0) {
                const ci = s.pop();
                this.bestPriority = p;
                return ci;
            }
        }
        return INVALID_CORNER_INDEX;
    }

    traverseFromCorner(startCorner: CornerIndex): void {
        const ct = this.cornerTable;
        if (ct.face(startCorner) == INVALID_FACE_INDEX) {
            return;
        }

        // Deliberately no visited-face guard and no stack reset (upstream
        // MaxPredictionDegreeTraverser::TraverseFromCorner).
        this.stacks[0].push(startCorner);
        this.bestPriority = 0;

        // Pre-visit next, prev and tip vertices.
        const nextC = ct.next(startCorner);
        const prevC = ct.previous(startCorner);
        this.visitVertex(ct.vertex(nextC), nextC);
        this.visitVertex(ct.vertex(prevC), prevC);
        this.visitVertex(ct.vertex(startCorner), startCorner);

        while (true) {
            let cornerId = this.popNextCorner();
            if (cornerId == INVALID_CORNER_INDEX) {
                break;
            }
            const faceId0 = ct.face(cornerId);
            if (faceId0 == INVALID_FACE_INDEX) {
                continue;
            }
            if (getBoolAt(this.visitedFaces, faceId0)) {
                continue;
            }

            while (true) {
                const faceId = ct.face(cornerId);
                if (faceId == INVALID_FACE_INDEX) {
                    break;
                }
                setBoolAt(this.visitedFaces, faceId, true);

                const vertId = ct.vertex(cornerId);
                if (vertId != INVALID_VERTEX_INDEX) {
                    if (<i64>vertId < <i64>this.visitedVertices.length && !this.visitedVertices[<i32>vertId]) {
                        this.visitVertex(vertId, cornerId);
                    }
                }

                const rightCornerId = ct.rightCorner(cornerId);
                const leftCornerId = ct.leftCorner(cornerId);
                const rightFaceId = rightCornerId == INVALID_CORNER_INDEX ? INVALID_FACE_INDEX : ct.face(rightCornerId);
                const leftFaceId = leftCornerId == INVALID_CORNER_INDEX ? INVALID_FACE_INDEX : ct.face(leftCornerId);

                const isRightFaceVisited = rightFaceId == INVALID_FACE_INDEX || getBoolAt(this.visitedFaces, rightFaceId);
                const isLeftFaceVisited = leftFaceId == INVALID_FACE_INDEX || getBoolAt(this.visitedFaces, leftFaceId);

                if (!isLeftFaceVisited) {
                    const priority = this.computePriority(leftCornerId);
                    if (isRightFaceVisited && priority <= this.bestPriority) {
                        cornerId = leftCornerId;
                        continue;
                    }
                    this.addCornerToStack(leftCornerId, priority);
                }

                if (!isRightFaceVisited) {
                    const priority = this.computePriority(rightCornerId);
                    if (priority <= this.bestPriority) {
                        cornerId = rightCornerId;
                        continue;
                    }
                    this.addCornerToStack(rightCornerId, priority);
                }

                break;
            }
        }
    }
}

export class MeshDecoder {
    private geometryType: EncodedGeometryType = EncodedGeometryType.TriangularMesh;
    private method: u8 = 0;
    private flags: u16 = 0;
    private versionMajor: u8 = 0;
    private versionMinor: u8 = 0;
    private cornerTable: CornerTable? = null;
    private edgebreakerDataToCornerMap: Array<u32>? = null;
    private edgebreakerAttributeSeamCorners: Array<Array<u32>> = new Array<Array<u32>>();
    private edgebreakerAttributeCornerTables: Array<CornerTable> = new Array<CornerTable>();
    private edgebreakerAttributeVerticesOnSeam: Array<Array<bool>> = new Array<Array<bool>>();
    private edgebreakerProcessedConnectivityCorners: Array<u32> = new Array<u32>();
    private edgebreakerVertexToCornerMap: Array<u32> = new Array<u32>();
    private edgebreakerIsVertHole: Array<bool> = new Array<bool>();
    private traversalMethod: u8 = 0;
    // The point count a sequential header declared, kept whole
    // (the mesh holds it as an i32). See the header comment.
    private sequentialPointsDeclared: bool = false;
    private sequentialNumPoints: u64 = 0;

    constructor() {}

    // Decodes a Draco mesh from `inBuffer` into `outMesh`, replacing whatever
    // it held (on error it is left cleared or half-written).
    decode(inBuffer: DecoderBuffer, outMesh: Mesh): Status {
        // Every stage below adds to the mesh, so it starts empty.
        outMesh.clear();
        this.sequentialPointsDeclared = false;

        // 1. Decode Header
        const sh = this.decodeHeader(inBuffer);
        if (!sh.ok) return sh;

        // 2. Decode Metadata
        if (
            versionAtLeast(this.versionMajor, this.versionMinor, VERSION_FLAGS_INTRODUCED) &&
            (this.flags & METADATA_FLAG_MASK) != 0
        ) {
            const sm = this.decodeMetadata(inBuffer, outMesh);
            if (!sm.ok) return sm;
        }

        if (this.geometryType == EncodedGeometryType.PointCloud) {
            // Point cloud files have no connectivity: the point-cloud decoder
            // reads the points and attributes straight into the mesh.
            const pcDecoder = new PointCloudDecoder();
            return pcDecoder.decodeAfterHeader(this.versionMajor, this.versionMinor, this.method, inBuffer, outMesh);
        }

        // 3. Decode Connectivity
        const sc = this.decodeConnectivity(inBuffer, outMesh);
        if (!sc.ok) return sc;

        // 4. Decode Attributes
        const sa = this.decodeAttributes(inBuffer, outMesh);
        if (!sa.ok) return sa;
        if (this.sequentialPointsDeclared && this.sequentialNumPoints > <u64>i32.MAX_VALUE) {
            return DracoError.general(
                "Mesh declares " + this.sequentialNumPoints.toString() + " points, more than this decoder can index",
            ).fail<bool>();
        }
        return sa;
    }

    // The decoded corner table (if any), for tests.
    getCornerTableRef(): CornerTable? {
        return this.cornerTable;
    }

    private decodeMetadata(inBuffer: DecoderBuffer, outMesh: Mesh): Status {
        const r = GeometryMetadata.decode(inBuffer);
        if (!r.ok) {
            return DracoError.general("Failed to decode metadata").fail<bool>();
        }
        outMesh.setMetadata(r.value);
        return okStatus();
    }

    private decodeHeader(buffer: DecoderBuffer): Status {
        const magic = new Uint8Array(5);
        const sm = buffer.decodeBytes(magic);
        if (!sm.ok) return sm;
        if (!isDracoMagic(magic)) {
            return DracoError.general("Invalid magic").fail<bool>();
        }

        const rmaj = buffer.decodeU8();
        if (!rmaj.ok) return rmaj.forward<bool>();
        this.versionMajor = rmaj.value;
        const rmin = buffer.decodeU8();
        if (!rmin.ok) return rmin.forward<bool>();
        this.versionMinor = rmin.value;
        buffer.setVersion(this.versionMajor, this.versionMinor);

        const rg = buffer.decodeU8();
        if (!rg.ok) return rg.forward<bool>();
        const gType = rg.value;
        if (gType == 0) {
            this.geometryType = EncodedGeometryType.PointCloud;
        } else if (gType == 1) {
            this.geometryType = EncodedGeometryType.TriangularMesh;
        } else {
            return DracoError.general("Invalid geometry type").fail<bool>();
        }

        const rmeth = buffer.decodeU8();
        if (!rmeth.ok) return rmeth.forward<bool>();
        this.method = rmeth.value;

        // The flags field is always present in the binary header.
        const rf = buffer.decodeU16();
        if (!rf.ok) {
            return DracoError.general("Failed to decode flags").fail<bool>();
        }
        this.flags = rf.value;

        return okStatus();
    }

    private decodeConnectivity(buffer: DecoderBuffer, mesh: Mesh): Status {
        if (this.method == 1) {
            const s = this.decodeEdgebreakerConnectivity(buffer, mesh);
            if (!s.ok) return s;
            const sr = this.rebuildEdgebreakerAttributeCornerTables();
            if (!sr.ok) return sr;
            const sp = this.assignEdgebreakerPointsToCorners(mesh);
            if (!sp.ok) return sp;
        } else {
            // Sequential connectivity: raw u32 counts before 2.2, varints from 2.2.
            const seqUsesVarint = versionAtLeast(this.versionMajor, this.versionMinor, DracoVersion(2, 2));
            let numFaces: u64;
            let numPoints: u64;
            if (!seqUsesVarint) {
                const rf = buffer.decodeU32();
                if (!rf.ok) return rf.forward<bool>();
                const rp = buffer.decodeU32();
                if (!rp.ok) return rp.forward<bool>();
                numFaces = <u64>rf.value;
                numPoints = <u64>rp.value;
            } else {
                const rf = buffer.decodeVarint();
                if (!rf.ok) return rf.forward<bool>();
                const rp = buffer.decodeVarint();
                if (!rp.ok) return rp.forward<bool>();
                numFaces = rf.value;
                numPoints = rp.value;
            }
            // No bit-budget guard on these counts: the allocation budget
            // below bounds the work instead.
            const ri = validateMeshIndexCount(numFaces);
            if (!ri.ok) return ri.forward<bool>();
            const numIndices = ri.value;
            mesh.setNumPoints(numPoints > <u64>i32.MAX_VALUE ? i32.MAX_VALUE : <i32>numPoints);
            this.sequentialPointsDeclared = true;
            this.sequentialNumPoints = numPoints;

            if (numFaces > 0 && numPoints > 0) {
                const rc = buffer.decodeU8();
                if (!rc.ok) return rc.forward<bool>();
                const connectivityMethod = rc.value;
                if (connectivityMethod == 0) {
                    // Compressed. The symbol count is bounded before the
                    // buffer it fills is sized.
                    const sb = ensureSymbolsAreBacked(numIndices, <u64>buffer.size());
                    if (!sb.ok) return sb;
                    // Empty on purpose: `decodeSymbols` grows it as symbols arrive.
                    const encodedIndices = new Array<u32>();
                    const options = new SymbolEncodingOptions();
                    const sd = decodeSymbols(numIndices, 1, options, buffer, encodedIndices);
                    if (!sd.ok) {
                        return DracoError.general("Failed to decode compressed sequential connectivity: " + sd.err).fail<bool>();
                    }
                    // Sized from what the decode produced.
                    const rz = makeZeroedIndices(<u64>encodedIndices.length);
                    if (!rz.ok) return rz.forward<bool>();
                    const indices = rz.value;
                    let lastIndexValue: i32 = 0;
                    for (let i = 0; i < encodedIndices.length; i++) {
                        const encodedVal = unchecked(encodedIndices[i]);
                        let indexDiff = <i32>(encodedVal >> 1);
                        if ((encodedVal & 1) != 0) {
                            if (indexDiff > lastIndexValue) {
                                return DracoError.general("Sequential connectivity index underflow").fail<bool>();
                            }
                            indexDiff = -indexDiff;
                        } else if (indexDiff > i32.MAX_VALUE - lastIndexValue) {
                            return DracoError.general("Sequential connectivity index overflow").fail<bool>();
                        }
                        const indexValue = lastIndexValue + indexDiff;
                        unchecked((indices[i] = <u32>indexValue));
                        lastIndexValue = indexValue;
                    }
                    const sf = setNumFacesWithinLimits(mesh, buffer, numFaces);
                    if (!sf.ok) return sf;
                    mesh.setFacesFromFlatIndices(indices);
                } else if (connectivityMethod == 1) {
                    // Raw: bulk read indices from the buffer.
                    if (numPoints < 256) {
                        const bytesNeeded = numIndices;
                        const rb = buffer.decodeSlice(bytesNeeded);
                        if (!rb.ok) {
                            return DracoError.general("Not enough data for u8 indices").fail<bool>();
                        }
                        const sf = setNumFacesWithinLimits(mesh, buffer, numFaces);
                        if (!sf.ok) return sf;
                        mesh.setFacesFromU8Indices(rb.value);
                    } else if (numPoints < 65536) {
                        const bytesNeeded = checkedMulU64(numIndices, 2);
                        if (bytesNeeded == U64_NONE) {
                            return DracoError.general("Mesh u16 index byte count overflow").fail<bool>();
                        }
                        const rb = buffer.decodeSlice(bytesNeeded);
                        if (!rb.ok) {
                            return DracoError.general("Not enough data for u16 indices").fail<bool>();
                        }
                        const sf = setNumFacesWithinLimits(mesh, buffer, numFaces);
                        if (!sf.ok) return sf;
                        mesh.setFacesFromLeU16Indices(rb.value);
                    } else if (numPoints < (1 << 21) && seqUsesVarint) {
                        // Three varints a face, each at least one byte: a face
                        // count past the bytes left cannot be delivered.
                        if (numIndices > <u64>buffer.remainingSize()) {
                            return DracoError.general(
                                "Sequential connectivity declares " + numFaces.toString() + " faces, more than the " +
                                buffer.remainingSize().toString() + " bytes left can encode",
                            ).fail<bool>();
                        }
                        const sf = setNumFacesWithinLimits(mesh, buffer, numFaces);
                        if (!sf.ok) return sf;
                        const nf = <i32>numFaces;
                        for (let faceId = 0; faceId < nf; faceId++) {
                            const r0 = buffer.decodeVarint();
                            if (!r0.ok) return r0.forward<bool>();
                            const r1 = buffer.decodeVarint();
                            if (!r1.ok) return r1.forward<bool>();
                            const r2 = buffer.decodeVarint();
                            if (!r2.ok) return r2.forward<bool>();
                            mesh.setFaceFromIndices(faceId, <u32>r0.value, <u32>r1.value, <u32>r2.value);
                        }
                    } else {
                        const bytesNeeded = checkedMulU64(numIndices, 4);
                        if (bytesNeeded == U64_NONE) {
                            return DracoError.general("Mesh u32 index byte count overflow").fail<bool>();
                        }
                        const rb = buffer.decodeSlice(bytesNeeded);
                        if (!rb.ok) {
                            return DracoError.general("Not enough data for u32 indices").fail<bool>();
                        }
                        const sf = setNumFacesWithinLimits(mesh, buffer, numFaces);
                        if (!sf.ok) return sf;
                        mesh.setFacesFromLeU32Indices(rb.value);
                    }
                } else {
                    return DracoError.general(
                        "Unsupported sequential connectivity method: " + connectivityMethod.toString(),
                    ).fail<bool>();
                }
                // Sequential decoding builds no corner table (C++
                // MeshSequentialDecoder uses a LinearSequencer); the field
                // keeps whatever it held.
            }
        }

        return okStatus();
    }

    // The first half of the method-1 connectivity branch: runs
    // MeshEdgebreakerDecoder and keeps what it hands over for the attribute
    // stage. A separate method, protected so a test can stand in precomputed
    // connectivity and drive the method-1 attribute paths against it.
    protected decodeEdgebreakerConnectivity(buffer: DecoderBuffer, mesh: Mesh): Status {
        const ebDecoder = new MeshEdgebreakerDecoder();
        const s = ebDecoder.decodeConnectivity(buffer, mesh);
        if (!s.ok) return s;

        // Preserve edgebreaker-derived maps for attribute decoding. The
        // edgebreaker decoder's corner table (with its opposite mappings),
        // not one rebuilt from the faces.
        return this.adoptEdgebreakerConnectivity(
            ebDecoder.takeDataToCornerMap(),
            ebDecoder.takeAttributeSeamCorners(),
            ebDecoder.takeProcessedConnectivityCorners(),
            ebDecoder.takeVertexToCornerMap(),
            ebDecoder.takeIsVertHole(),
            ebDecoder.getTraversalDecoderType(),
            ebDecoder.takeCornerTable(),
        );
    }

    // Stores what MeshEdgebreakerDecoder handed over, in a fixed order, and
    // refuses a missing corner table.
    protected adoptEdgebreakerConnectivity(
        dataToCornerMap: Array<u32>?,
        attributeSeamCorners: Array<Array<u32>>,
        processedConnectivityCorners: Array<u32>,
        vertexToCornerMap: Array<u32>,
        isVertHole: Array<bool>,
        traversalDecoderType: u8,
        cornerTable: CornerTable?,
    ): Status {
        this.edgebreakerDataToCornerMap = dataToCornerMap;
        this.edgebreakerAttributeSeamCorners = attributeSeamCorners;
        this.edgebreakerProcessedConnectivityCorners = processedConnectivityCorners;
        this.edgebreakerVertexToCornerMap = vertexToCornerMap;
        this.edgebreakerIsVertHole = isVertHole;
        this.traversalMethod = traversalDecoderType;
        if (cornerTable != null) {
            this.cornerTable = cornerTable;
        } else {
            return DracoError.general("Edgebreaker decoder did not provide corner table").fail<bool>();
        }
        return okStatus();
    }

    // Cuts the seams a stream names into a copy of `baseCt` (the attribute's
    // own corner table) and flags the base vertices on a seam.
    static makeAttributeCornerTable(baseCt: CornerTable, seamCorners: Array<u32>): Result<SeamCut> {
        // Seam corners come off the wire: every index is checked before it
        // addresses anything.
        const numCorners = baseCt.numCorners();
        const isEdgeOnSeam = new Array<bool>(numCorners);
        for (let i = 0; i < seamCorners.length; i++) {
            const c: CornerIndex = seamCorners[i];
            if (c == INVALID_CORNER_INDEX) {
                continue;
            }
            if (<i64>c >= <i64>numCorners) {
                return DracoError.general("Invalid Edgebreaker attribute seam corner").fail<SeamCut>();
            }
            isEdgeOnSeam[<i32>c] = true;

            const opp = baseCt.opposite(c);
            if (opp != INVALID_CORNER_INDEX) {
                if (<i64>opp >= <i64>numCorners) {
                    return DracoError.general("Invalid Edgebreaker attribute seam opposite corner").fail<SeamCut>();
                }
                isEdgeOnSeam[<i32>opp] = true;
            }
        }

        return cutSeamEdgesAndRecomputeVertices(baseCt, isEdgeOnSeam);
    }

    private rebuildEdgebreakerAttributeCornerTables(): Status {
        this.edgebreakerAttributeCornerTables.length = 0;
        this.edgebreakerAttributeVerticesOnSeam.length = 0;
        const baseCt = this.cornerTable;
        if (baseCt == null) {
            return okStatus();
        }
        for (let i = 0; i < this.edgebreakerAttributeSeamCorners.length; i++) {
            const r = MeshDecoder.makeAttributeCornerTable(baseCt, this.edgebreakerAttributeSeamCorners[i]);
            if (!r.ok) return r.forward<bool>();
            this.edgebreakerAttributeCornerTables.push(r.value.ct);
            this.edgebreakerAttributeVerticesOnSeam.push(r.value.isVertexOnSeam);
        }
        return okStatus();
    }

    private assignEdgebreakerPointsToCorners(mesh: Mesh): Status {
        if (this.edgebreakerAttributeCornerTables.length == 0) {
            return okStatus();
        }
        const baseCt = this.cornerTable;
        if (baseCt == null) {
            return okStatus();
        }
        const attrTables = this.edgebreakerAttributeCornerTables;

        const numCorners = baseCt.numCorners();
        const pointToCornerMap = new Array<u32>();
        const cornerToPointMap = new Array<u32>(numCorners);
        cornerToPointMap.fill(u32.MAX_VALUE);

        // The vertex each attribute table gave for the previous corner of the fan.
        const prevAttrVertex = new Array<u32>(attrTables.length);
        prevAttrVertex.fill(INVALID_VERTEX_INDEX);

        // numCorners + 1 (cannot overflow in i64).
        const maxSwingSteps: i64 = <i64>numCorners + 1;
        const numVertices = baseCt.numVertices();
        for (let v = 0; v < numVertices; v++) {
            let c = baseCt.leftMostCorner(<u32>v);
            if (c == INVALID_CORNER_INDEX) {
                continue;
            }

            let firstCorner = c;
            const isVertHole =
                v < this.edgebreakerIsVertHole.length ? this.edgebreakerIsVertHole[v] : baseCt.isVertexOnBoundary(<u32>v);
            if (!isVertHole) {
                for (let attrIndex = 0; attrIndex < attrTables.length; attrIndex++) {
                    const attrCt = attrTables[attrIndex];
                    const baseVertex = baseCt.vertex(c);
                    if (attrIndex >= this.edgebreakerAttributeVerticesOnSeam.length) {
                        continue;
                    }
                    const verticesOnSeam = this.edgebreakerAttributeVerticesOnSeam[attrIndex];
                    if (
                        baseVertex == INVALID_VERTEX_INDEX ||
                        !(<i64>baseVertex < <i64>verticesOnSeam.length ? verticesOnSeam[<i32>baseVertex] : false)
                    ) {
                        continue;
                    }
                    const vertexAtFirst = attrCt.vertex(c);
                    let actC = baseCt.swingRight(c);
                    let seamFound = false;
                    let swingSteps: i64 = 0;
                    while (actC != INVALID_CORNER_INDEX && actC != c) {
                        swingSteps += 1;
                        if (swingSteps > maxSwingSteps) {
                            return DracoError.general("Edgebreaker seam search traversal did not terminate").fail<bool>();
                        }
                        if (attrCt.vertex(actC) != vertexAtFirst) {
                            firstCorner = actC;
                            seamFound = true;
                            break;
                        }
                        actC = baseCt.swingRight(actC);
                    }
                    if (seamFound) {
                        break;
                    }
                }
            }

            c = firstCorner;
            setU32At(cornerToPointMap, c, <u32>pointToCornerMap.length);
            pointToCornerMap.push(c);

            for (let t = 0; t < attrTables.length; t++) {
                prevAttrVertex[t] = attrTables[t].vertex(c);
            }

            let prevC = c;
            c = baseCt.swingRight(c);
            let swingSteps: i64 = 0;
            while (c != INVALID_CORNER_INDEX && c != firstCorner) {
                swingSteps += 1;
                if (swingSteps > maxSwingSteps) {
                    return DracoError.general("Edgebreaker point assignment traversal did not terminate").fail<bool>();
                }
                // Every slot is written on every step (a fold, not `any`).
                let attributeSeam = false;
                for (let t = 0; t < attrTables.length; t++) {
                    const vertex = attrTables[t].vertex(c);
                    const differs = vertex != prevAttrVertex[t];
                    prevAttrVertex[t] = vertex;
                    attributeSeam = attributeSeam || differs;
                }
                if (attributeSeam) {
                    setU32At(cornerToPointMap, c, <u32>pointToCornerMap.length);
                    pointToCornerMap.push(c);
                } else {
                    setU32At(cornerToPointMap, c, getU32At(cornerToPointMap, prevC));
                }
                prevC = c;
                c = baseCt.swingRight(c);
            }
        }

        const numFaces = mesh.numFaces();
        for (let faceId = 0; faceId < numFaces; faceId++) {
            const base = faceId * 3;
            const p0 = getU32At(cornerToPointMap, <u32>base);
            const p1 = getU32At(cornerToPointMap, <u32>(base + 1));
            const p2 = getU32At(cornerToPointMap, <u32>(base + 2));
            if (p0 == u32.MAX_VALUE || p1 == u32.MAX_VALUE || p2 == u32.MAX_VALUE) {
                return DracoError.general("Failed to assign Edgebreaker corner point").fail<bool>();
            }
            mesh.setFace(<u32>faceId, Face(p0, p1, p2));
        }
        mesh.setNumPoints(pointToCornerMap.length);

        return okStatus();
    }

    private decodeAttributes(buffer: DecoderBuffer, mesh: Mesh): Status {
        // Both sequential and Edgebreaker encodings use a u8 for the number of
        // attribute decoders.
        const rn = buffer.decodeU8();
        if (!rn.ok) return rn.forward<bool>();
        const numAttributesDecoders = <i32>rn.value;
        const numPoints: u64 = this.sequentialPointsDeclared ? this.sequentialNumPoints : <u64>mesh.numPoints();

        // Sequential encoding uses the identity, kept symbolic; Edgebreaker
        // builds real traversal arrays below.
        const pointIds =
            this.method == 0
                ? EntryToPointIdMap.identity(numPoints > <u64>i32.MAX_VALUE ? i32.MAX_VALUE : <i32>numPoints)
                : EntryToPointIdMap.identity(0);
        const dataToCornerMap: Array<u32>? = null;

        // This decoder never read a header of its own, so it is told the
        // version (the attribute decoders read it to bind prediction parents).
        const pcDecoder = new PointCloudDecoder();
        pcDecoder.setBitstreamVersion(this.versionMajor, this.versionMinor);
        const bitstreamVersion_: u16 = packBitstreamVersion(this.versionMajor, this.versionMinor);

        // (1) Attribute decoder identifiers (Edgebreaker only).
        const attDataIdByDecoder = new Array<u8>(numAttributesDecoders);
        const encoderTypeByDecoder = new Array<u8>(numAttributesDecoders);
        const traversalMethodByDecoder = new Array<u8>(numAttributesDecoders);
        if (this.method == 1) {
            for (let i = 0; i < numAttributesDecoders; i++) {
                const ra = buffer.decodeU8();
                if (!ra.ok) return ra.forward<bool>();
                attDataIdByDecoder[i] = ra.value;
                const re = buffer.decodeU8();
                if (!re.ok) return re.forward<bool>();
                encoderTypeByDecoder[i] = re.value;
                // traversal_method was added in v1.2; older streams default to
                // DEPTH_FIRST (0).
                if (bitstreamVersion_ >= 0x0102) {
                    const rt = buffer.decodeU8();
                    if (!rt.ok) return rt.forward<bool>();
                    traversalMethodByDecoder[i] = rt.value;
                }
            }
        }

        // (2) Attribute decoder data.
        const attIdsByDecoder = new Array<Array<i32>>();
        const decoderTypesByDecoder = new Array<Array<u8>>();

        for (let d = 0; d < numAttributesDecoders; d++) {
            let numAttributesInDecoder: u64;
            if (bitstreamVersion_ < 0x0200) {
                const r = buffer.decodeU32();
                if (!r.ok) return r.forward<bool>();
                numAttributesInDecoder = <u64>r.value;
            } else {
                const r = buffer.decodeVarint();
                if (!r.ok) return r.forward<bool>();
                numAttributesInDecoder = r.value;
            }
            if (numAttributesInDecoder == 0) {
                return DracoError.general("Invalid number of attributes").fail<bool>();
            }
            const sv = validateNumAttributesInDecoder(numAttributesInDecoder, <u64>buffer.remainingSize());
            if (!sv.ok) return sv;
            const count = <i32>numAttributesInDecoder;

            const attIds = new Array<i32>();
            const decoderTypes = new Array<u8>();

            for (let i = 0; i < count; i++) {
                const rt = buffer.decodeU8();
                if (!rt.ok) return rt.forward<bool>();
                const rat = geometryAttributeTypeTryFrom(rt.value);
                if (!rat.ok) return rat.forward<bool>();

                const rd = buffer.decodeU8();
                if (!rd.ok) return rd.forward<bool>();
                const rdt = dataTypeTryFrom(rd.value);
                if (!rdt.ok) return rdt.forward<bool>();
                const dataType = rdt.value;

                const rc = buffer.decodeU8();
                if (!rc.ok) return rc.forward<bool>();
                const numComponents = rc.value;
                const sn = validateNumComponents(numComponents);
                if (!sn.ok) return sn;
                const rnorm = buffer.decodeU8();
                if (!rnorm.ok) return rnorm.forward<bool>();
                const normalized = rnorm.value != 0;
                let uniqueId: u32;
                if (bitstreamVersion_ < 0x0103) {
                    const r = buffer.decodeU16();
                    if (!r.ok) return r.forward<bool>();
                    uniqueId = <u32>r.value;
                } else {
                    const r = buffer.decodeVarint();
                    if (!r.ok) return r.forward<bool>();
                    uniqueId = <u32>r.value;
                }

                const sb = buffer.chargeDecodedBytes(
                    satMulU64(satMulU64(<u64>numComponents, <u64>dataTypeByteLength(dataType)), numPoints),
                );
                if (!sb.ok) return sb;
                const att = new PointAttribute();
                const si = att.initDeferred(rat.value, numComponents, dataType, normalized, numPoints);
                if (!si.ok) return si;
                att.setUniqueId(uniqueId);
                const attId = mesh.addAttributePreserveUniqueId(att);
                attIds.push(attId);
                // No mapping is written here for EdgeBreaker: the traversal
                // mapping below overwrites every entry.
            }

            for (let i = 0; i < count; i++) {
                const r = buffer.decodeU8();
                if (!r.ok) return r.forward<bool>();
                decoderTypes.push(r.value);
            }

            attIdsByDecoder.push(attIds);
            decoderTypesByDecoder.push(decoderTypes);
        }

        // (3) Attribute decoder payloads.
        const portableAttributesById = new Array<PortableById>();
        // Every edgebreaker attribute decoder asks for the same seed-free
        // depth-first traversal of the same corner table: walked once, copied.
        let dfsTraversal: AttributeTraversalArrays? = null;
        for (let decI = 0; decI < numAttributesDecoders; decI++) {
            const attIds = attIdsByDecoder[decI];
            const decoderTypes = decoderTypesByDecoder[decI];

            // For edgebreaker, the attribute-specific (seam-cut) corner table
            // if one applies.
            let attrCornerTable: CornerTable? = null;
            if (this.method == 1) {
                const attDataId = <i32>attDataIdByDecoder[decI];
                const usesAttributeConnectivity = attDataIdByDecoder[decI] != 0xff && encoderTypeByDecoder[decI] != 0;
                if (usesAttributeConnectivity && attDataId < this.edgebreakerAttributeSeamCorners.length) {
                    if (attDataId < this.edgebreakerAttributeCornerTables.length) {
                        attrCornerTable = this.edgebreakerAttributeCornerTables[attDataId];
                    }
                }
            }

            let pointIdsForDecoder: Array<u32>? = null;
            let dataToCornerMapForDecoder: Array<u32>? = null;
            let vertexToDataMapForDecoder: Array<i32>? = null;
            if (this.method == 1) {
                if (attrCornerTable != null) {
                    // A seam-broken table, not the validated main one: keep the check.
                    const r = MeshDecoder.generatePointIdsAndCornersDfsForTable(mesh, attrCornerTable, new Array<u32>(), false);
                    if (!r.ok) return r.forward<bool>();
                    pointIdsForDecoder = r.value.pointIds;
                    dataToCornerMapForDecoder = r.value.dataToCornerMap;
                    vertexToDataMapForDecoder = r.value.vertexToDataMap;
                }
            }

            const cornerTableForDecoder: CornerTable? = attrCornerTable != null ? attrCornerTable : this.cornerTable;

            let sequencedPointIds: Array<u32>? = null;
            let sequencedDataToCornerMap: Array<u32>? = null;
            let sequencedVertexToDataMap: Array<i32>? = null;

            // Point ids from the traversal method the encoder used (per
            // decoder): 1 = PREDICTION_DEGREE, 0 = DEPTH_FIRST.
            const perDecoderTraversal: u8 =
                this.method == 1 && decI < traversalMethodByDecoder.length ? traversalMethodByDecoder[decI] : 0;
            if (this.method == 0) {
                // Sequential encoding: the identity sequence (LinearSequencer).
            } else {
                if (perDecoderTraversal == 1) {
                    const r = this.generatePointIdsAndCornersMaxPredictionDegree(
                        mesh,
                        this.edgebreakerProcessedConnectivityCorners,
                    );
                    if (!r.ok) return r.forward<bool>();
                    sequencedPointIds = r.value.pointIds;
                    sequencedDataToCornerMap = r.value.dataToCornerMap;
                    sequencedVertexToDataMap = r.value.vertexToDataMap;
                } else {
                    let arrays: AttributeTraversalArrays;
                    const cached = dfsTraversal;
                    if (cached != null) {
                        arrays = cached.clone();
                    } else {
                        const r = this.generatePointIdsAndCornersDfs(mesh, new Array<u32>());
                        if (!r.ok) return r.forward<bool>();
                        arrays = r.value;
                        // Cached only when a later decoder will read it.
                        if (decI + 1 < numAttributesDecoders) {
                            dfsTraversal = arrays.clone();
                        }
                    }
                    sequencedPointIds = arrays.pointIds;
                    sequencedDataToCornerMap = arrays.dataToCornerMap;
                    sequencedVertexToDataMap = arrays.vertexToDataMap;
                }
            }

            // The vertex map from the traversal result, when not already set.
            if (this.method == 1 && sequencedVertexToDataMap == null) {
                const map = sequencedDataToCornerMap;
                if (map != null) {
                    const ct = this.cornerTable;
                    if (ct == null) {
                        return DracoError.general("Edgebreaker attribute traversal missing corner table").fail<bool>();
                    }
                    const r = buildVertexToDataMapFromCornerMap(ct, map);
                    if (!r.ok) return r.forward<bool>();
                    sequencedVertexToDataMap = r.value;
                }
            }

            // The point sequence the values of this decoder follow.
            let pointIdsForValues: EntryToPointIdMap;
            if (pointIdsForDecoder != null) {
                pointIdsForValues = EntryToPointIdMap.fromPointIndices(pointIdsForDecoder);
            } else if (sequencedPointIds != null) {
                pointIdsForValues = EntryToPointIdMap.fromPointIndices(sequencedPointIds);
            } else {
                pointIdsForValues = pointIds;
            }
            let dataToCornerMapOverrideForValues: Array<u32>?;
            if (dataToCornerMapForDecoder != null) {
                dataToCornerMapOverrideForValues = dataToCornerMapForDecoder;
            } else if (sequencedDataToCornerMap != null) {
                dataToCornerMapOverrideForValues = sequencedDataToCornerMap;
            } else {
                dataToCornerMapOverrideForValues = dataToCornerMap;
            }
            const vertexToDataMapOverrideForValues: Array<i32>? =
                pointIdsForDecoder != null ? vertexToDataMapForDecoder : sequencedVertexToDataMap;

            const pendingQuant = new Array<PendingQuant>();
            const pendingNormals = new Array<PendingNormal>();

            for (let localI = 0; localI < attIds.length; localI++) {
                const attId = attIds[localI];
                const decoderType = decoderTypes[localI];
                {
                    const ra = mesh.tryAttributeMut(attId);
                    if (!ra.ok) return ra.forward<bool>();
                    const att = ra.value;
                    if (att.size() != pointIdsForValues.len()) {
                        const s = att.resizeUniqueEntries(<u64>pointIdsForValues.len());
                        if (!s.ok) return s;
                    }
                }
                switch (decoderType) {
                    case 0: {
                        const attDecoder = new SequentialGenericAttributeDecoder();
                        attDecoder.init(pcDecoder, attId);
                        const s = attDecoder.decodeValues(mesh, pointIdsForValues, buffer);
                        if (!s.ok) return s;
                        break;
                    }
                    case 1: {
                        const attDecoder = new SequentialIntegerAttributeDecoder();
                        attDecoder.init(pcDecoder, attId);
                        const portableParentAttribute = findPortable(
                            portableAttributesById,
                            mesh.namedAttributeId(GeometryAttributeType.Position),
                        );
                        const s = attDecoder.decodeValues(
                            mesh,
                            pointIdsForValues,
                            buffer,
                            cornerTableForDecoder,
                            dataToCornerMapOverrideForValues,
                            vertexToDataMapOverrideForValues,
                            null,
                            portableParentAttribute,
                            null,
                        );
                        if (!s.ok) return s;
                        break;
                    }
                    case 2: {
                        const attDecoder = new SequentialQuantizationAttributeDecoder();
                        const si = attDecoder.init(pcDecoder, mesh, attId);
                        if (!si.ok) return si;
                        const portableParentAttribute = findPortable(
                            portableAttributesById,
                            mesh.namedAttributeId(GeometryAttributeType.Position),
                        );
                        const rv = attDecoder.decodeValues(
                            mesh,
                            pointIdsForValues,
                            buffer,
                            bitstreamVersion_,
                            PortableExtent.of(pointIdsForValues),
                            cornerTableForDecoder,
                            dataToCornerMapOverrideForValues,
                            vertexToDataMapOverrideForValues,
                            portableParentAttribute,
                        );
                        if (!rv.ok) return rv.forward<bool>();
                        const portable = rv.value;
                        // Below 2.0 an attribute's own decode dequantizes it in
                        // place at once (a later attribute may read it as a
                        // prediction parent); the later pass repeats it harmlessly.
                        if (bitstreamVersion_ < 0x0200) {
                            const rd = mesh.tryAttributeMut(attId);
                            if (!rd.ok) return rd.forward<bool>();
                            const dst = rd.value;
                            if (dst.size() != portable.size()) {
                                const s = dst.resizeUniqueEntries(<u64>portable.size());
                                if (!s.ok) return s;
                            }
                            const s = attDecoder.transform().inverseTransformAttribute(portable, dst);
                            if (!s.ok) return s;
                        }
                        pendingQuant.push(new PendingQuant(attId, portable, attDecoder.intoTransform()));
                        break;
                    }
                    case 3: {
                        const attDecoder = new SequentialNormalAttributeDecoder();
                        const si = attDecoder.init(pcDecoder, mesh, attId);
                        if (!si.ok) return si;
                        const portableParentAttribute = findPortable(
                            portableAttributesById,
                            mesh.namedAttributeId(GeometryAttributeType.Position),
                        );
                        const rv = attDecoder.decodeValues(
                            mesh,
                            pointIdsForValues,
                            buffer,
                            bitstreamVersion_,
                            PortableExtent.of(pointIdsForValues),
                            cornerTableForDecoder,
                            dataToCornerMapOverrideForValues,
                            vertexToDataMapOverrideForValues,
                            portableParentAttribute,
                        );
                        if (!rv.ok) return rv.forward<bool>();
                        pendingNormals.push(new PendingNormal(attId, rv.value, attDecoder.quantizationBits()));
                        break;
                    }
                    default:
                        return DracoError.general("Unsupported sequential decoder type: " + decoderType.toString()).fail<bool>();
                }
            }

            // Transform data for all attributes (2.0+: after all values).
            for (let localI = 0; localI < attIds.length; localI++) {
                const attId = attIds[localI];
                const decoderType = decoderTypes[localI];
                if (decoderType == 2 && bitstreamVersion_ >= 0x0200) {
                    const idx = findPendingQuant(pendingQuant, attId);
                    if (idx < 0) {
                        return DracoError.general("Missing pending quant entry").fail<bool>();
                    }
                    const ro = mesh.tryAttribute(attId);
                    if (!ro.ok) return ro.forward<bool>();
                    const sp = pendingQuant[idx].transform.decodeParameters(ro.value, buffer);
                    if (!sp.ok) {
                        return DracoError.general("Failed to decode quantization parameters: " + sp.err).fail<bool>();
                    }
                } else if (decoderType == 3 && bitstreamVersion_ >= 0x0200) {
                    const idx = findPendingNormal(pendingNormals, attId);
                    if (idx < 0) {
                        return DracoError.general("Missing pending normal entry").fail<bool>();
                    }
                    const rq = buffer.decodeU8();
                    if (!rq.ok) return rq.forward<bool>();
                    const bits = rq.value;
                    if (!AttributeOctahedronTransform.isValidQuantizationBits(<i32>bits)) {
                        return DracoError.general("Invalid normal quantization bits").fail<bool>();
                    }
                    pendingNormals[idx].quantizationBits = bits;
                }
            }

            // Apply inverse transforms.
            for (let i = 0; i < pendingQuant.length; i++) {
                const q = pendingQuant[i];
                const rd = mesh.tryAttributeMut(q.attId);
                if (!rd.ok) return rd.forward<bool>();
                const dst = rd.value;
                if (dst.size() != q.portable.size()) {
                    const s = dst.resizeUniqueEntries(<u64>q.portable.size());
                    if (!s.ok) return s;
                }
                const s = q.transform.inverseTransformAttribute(q.portable, dst);
                if (!s.ok) {
                    return DracoError.general("Failed to dequantize attribute: " + s.err).fail<bool>();
                }
            }
            for (let i = 0; i < pendingNormals.length; i++) {
                const n = pendingNormals[i];
                const oct = new AttributeOctahedronTransform(-1);
                const sp = oct.setParameters(<i32>n.quantizationBits);
                if (!sp.ok) return sp;
                const rd = mesh.tryAttributeMut(n.attId);
                if (!rd.ok) return rd.forward<bool>();
                const dst = rd.value;
                if (dst.size() != n.portable.size()) {
                    const s = dst.resizeUniqueEntries(<u64>n.portable.size());
                    if (!s.ok) return s;
                }
                const s = oct.inverseTransformAttributeWithLegacyOctahedron(n.portable, dst, bitstreamVersion_ < 0x0200);
                if (!s.ok) {
                    return DracoError.general("Failed to decode normals: " + s.err).fail<bool>();
                }
            }

            // Edgebreaker: the final point -> attribute value mapping
            // (C++ MeshTraversalSequencer::UpdatePointToAttributeIndexMapping).
            // Values are stored in data-id order; point p takes the value of
            // the data id its corner-table vertex maps to.
            if (this.method == 1) {
                const mappingVMap: Array<i32>? =
                    vertexToDataMapForDecoder != null ? vertexToDataMapForDecoder : sequencedVertexToDataMap;
                if (mappingVMap != null) {
                    const meshNumPoints = mesh.numPoints();
                    // Entries no corner reaches stay INVALID.
                    const pointToValue = new Array<u32>(meshNumPoints);
                    pointToValue.fill(INVALID_ATTRIBUTE_VALUE_INDEX);
                    if (cornerTableForDecoder != null) {
                        // Corner c of the mesh is entry c of the corner table
                        // and of the flattened faces (zip: the shorter wins).
                        const c2v = cornerTableForDecoder.cornerToVertexMap;
                        const faces = mesh.facesFlat();
                        const n = min(c2v.length, faces.length);
                        for (let i = 0; i < n; i++) {
                            const vertex = unchecked(c2v[i]);
                            const point = unchecked(faces[i]);
                            if (vertex == INVALID_VERTEX_INDEX) {
                                continue;
                            }
                            if (<i64>vertex >= <i64>mappingVMap.length) {
                                continue;
                            }
                            const dataId = mappingVMap[<i32>vertex];
                            if (dataId < 0) {
                                continue;
                            }
                            if (<i64>point < <i64>pointToValue.length) {
                                pointToValue[<i32>point] = <u32>dataId;
                            }
                        }
                    } else {
                        for (let p = 0; p < meshNumPoints; p++) {
                            if (p < mappingVMap.length && mappingVMap[p] >= 0) {
                                pointToValue[p] = <u32>mappingVMap[p];
                            }
                        }
                    }

                    for (let i = 0; i < attIds.length; i++) {
                        const ra = mesh.tryAttributeMut(attIds[i]);
                        if (!ra.ok) return ra.forward<bool>();
                        ra.value.setExplicitMappingFrom(pointToValue);
                    }
                }
            }

            for (let i = 0; i < pendingQuant.length; i++) {
                const q = pendingQuant[i];
                const portable = q.portable;
                const ro = mesh.tryAttribute(q.attId);
                if (!ro.ok) return ro.forward<bool>();
                const s = copyPointMapping(ro.value, portable, mesh.numPoints());
                if (!s.ok) return s;
                upsertPortableAttribute(portableAttributesById, q.attId, portable);
            }
            for (let i = 0; i < pendingNormals.length; i++) {
                const n = pendingNormals[i];
                const portable = n.portable;
                const ro = mesh.tryAttribute(n.attId);
                if (!ro.ok) return ro.forward<bool>();
                const s = copyPointMapping(ro.value, portable, mesh.numPoints());
                if (!s.ok) return s;
                upsertPortableAttribute(portableAttributesById, n.attId, portable);
            }
        }

        return okStatus();
    }

    // Discovery-order traversal: the order points were created during
    // reconstruction (currently unused).
    generatePointIdsAndCornersDiscovery(mesh: Mesh): AttributeTraversalArrays {
        const numPoints = mesh.numPoints();
        const pointIds = new Array<u32>();
        const dataToCornerMap = new Array<u32>();

        for (let i = 0; i < numPoints; i++) {
            pointIds.push(<u32>i);
            const corner =
                i < this.edgebreakerVertexToCornerMap.length ? this.edgebreakerVertexToCornerMap[i] : u32.MAX_VALUE;
            dataToCornerMap.push(corner == u32.MAX_VALUE ? 0 : corner);
        }

        return new AttributeTraversalArrays(pointIds, dataToCornerMap, new Array<i32>());
    }

    generatePointIdsAndCornersDfs(mesh: Mesh, processedConnectivityCorners: Array<u32>): Result<AttributeTraversalArrays> {
        const cornerTable = this.cornerTable;
        if (cornerTable == null) {
            return DracoError.general("Edgebreaker DFS attribute traversal missing corner table").fail<AttributeTraversalArrays>();
        }
        // The main corner table was already validated during connectivity decode.
        return MeshDecoder.generatePointIdsAndCornersDfsForTable(mesh, cornerTable, processedConnectivityCorners, true);
    }

    // `alreadyValidated`: true when `cornerTable` is known consistent (the
    // main table); false for a seam-broken clone built for one attribute.
    static generatePointIdsAndCornersDfsForTable(
        mesh: Mesh,
        cornerTable: CornerTable,
        processedConnectivityCorners: Array<u32>,
        alreadyValidated: bool,
    ): Result<AttributeTraversalArrays> {
        // Reject an inconsistent table before the walk indexes by its ids.
        if (!alreadyValidated && !cornerTable.isIndexConsistent()) {
            return DracoError.general("Inconsistent corner table for attribute traversal").fail<AttributeTraversalArrays>();
        }
        const numVertices = cornerTable.numVertices();
        const numFaces = cornerTable.numFaces();

        // Sized, then cut back to what the walk visited.
        const pointIds = new Array<u32>(numVertices);
        const dataToCornerMap = new Array<u32>(numVertices);
        const vertexToDataMap = new Array<i32>(numVertices);
        vertexToDataMap.fill(-1);
        const visitedVertices = new Array<bool>(numVertices);
        const visitedFaces = new Array<bool>(numFaces);

        const observer = new DfsVisitObserver(mesh, pointIds, dataToCornerMap, vertexToDataMap);

        // Scratch for the depth-first walk, reused across seeds.
        const cornerStack = new Array<u32>();

        // As C++ MeshTraversalSequencer: the given corners, or corner 3f of
        // every face in order.
        if (processedConnectivityCorners.length > 0) {
            for (let i = 0; i < processedConnectivityCorners.length; i++) {
                traverseFromCorner(
                    cornerTable,
                    processedConnectivityCorners[i],
                    cornerStack,
                    visitedFaces,
                    visitedVertices,
                    observer,
                );
            }
        } else {
            for (let f = 0; f < numFaces; f++) {
                if (!visitedFaces[f]) {
                    traverseFromCorner(cornerTable, <u32>(f * 3), cornerStack, visitedFaces, visitedVertices, observer);
                }
            }
        }

        // Back to the length the pushes would have left.
        pointIds.length = observer.numVisited;
        dataToCornerMap.length = observer.numVisited;

        return Result.okv<AttributeTraversalArrays>(new AttributeTraversalArrays(pointIds, dataToCornerMap, vertexToDataMap));
    }

    // C++ MaxPredictionDegreeTraverser (MESH_TRAVERSAL_PREDICTION_DEGREE).
    generatePointIdsAndCornersMaxPredictionDegree(
        mesh: Mesh,
        _processedConnectivityCorners: Array<u32>,
    ): Result<AttributeTraversalArrays> {
        const cornerTable = this.cornerTable;
        if (cornerTable == null) {
            return DracoError.general("Edgebreaker prediction-degree traversal missing corner table").fail<AttributeTraversalArrays>();
        }
        // No consistency check: this only runs on the main table, checked
        // during connectivity decode.
        const walk = new MaxPredictionDegreeWalk(mesh, cornerTable);

        // The DECODER traverses faces sequentially (face 0, 1, 2, ...), not the
        // processed connectivity corners (those are the encoder's).
        const numFaces = cornerTable.numFaces();
        for (let f = 0; f < numFaces; f++) {
            const firstCorner = cornerTable.firstCorner(<u32>f);
            walk.traverseFromCorner(firstCorner);
        }

        return Result.okv<AttributeTraversalArrays>(
            new AttributeTraversalArrays(walk.pointIds, walk.dataToCornerMap, walk.vertexToDataMap),
        );
    }
}

export function validateMeshIndexCount(numFaces: u64): Result<u64> {
    // numFaces * 3, refused when it overflows u64.
    if (numFaces > u64.MAX_VALUE / 3) {
        return DracoError.general("Mesh face index count overflow").fail<u64>();
    }
    return Result.okv<u64>(numFaces * 3);
}

// The index array, sized from a count that already has an array behind it
// (the symbols the decode produced), so uncharged.
export function makeZeroedIndices(numIndices: u64): Result<Array<u32>> {
    // Nothing can be allocated past one rasc object.
    if (numIndices > <u64>(BYTE_VEC_MAX_CAPACITY / 4)) {
        return DracoError.general("Failed to allocate mesh indices").fail<Array<u32>>();
    }
    return Result.okv<Array<u32>>(new Array<u32>(<i32>numIndices));
}

// Sizes the face array after the caller's ceiling has had its say (checked
// here, after every structural refusal, so a LimitExceeded means the file was
// found coherent).
export function setNumFacesWithinLimits(mesh: Mesh, buffer: DecoderBuffer, numFaces: u64): Status {
    const s = buffer.checkFaces(numFaces);
    if (!s.ok) return s;
    return mesh.trySetNumFaces(numFaces);
}
