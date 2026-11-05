// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Triangle mesh geometry: a PointCloud plus faces.
//
// Faces are stored flat, three point ids per face, in an Array<u32>:
// `facesFlat()` is the live array; `face(f)` returns a Face value struct.

import { Result, panic } from "../../../../base/util";
import { BYTE_VEC_MAX_CAPACITY } from "../core/byte_vec";
import { DracoError, Status, okStatus } from "../core/status";
import { resizeU32Array } from "./geometry_attribute";
import { PointCloud } from "./point_cloud";
import { readU16Le, readU32Le } from "./bytes";

// The most u32 entries one Array<u32> can hold (its storage is a single
// rasc object of at most BYTE_VEC_MAX_CAPACITY bytes).
const MAX_FACE_WORDS: i32 = BYTE_VEC_MAX_CAPACITY / 4;

// One triangle: three point indices.
export struct Face {
    p0: u32 = 0;
    p1: u32 = 0;
    p2: u32 = 0;

    constructor(p0: u32, p1: u32, p2: u32) {
        this.p0 = p0;
        this.p1 = p1;
        this.p2 = p2;
    }

    // Point index `i` (0, 1 or 2).
    readonly get(i: i32): u32 {
        if (i == 0) return this.p0;
        if (i == 1) return this.p1;
        if (i == 2) return this.p2;
        panic("index out of bounds: the len is 3 but the index is " + i.toString());
        return 0;
    }

    readonly hash(): u32 {
        return this.p0 * 73856093 ^ this.p1 * 19349663 ^ this.p2 * 83492791;
    }

    operator==(a: Face, b: Face): bool {
        return a.p0 == b.p0 && a.p1 == b.p1 && a.p2 == b.p2;
    }
}

export class Mesh extends PointCloud {
    private faces_: Array<u32> = new Array<u32>();

    constructor() {
        super();
    }

    // Drops every face and everything the point cloud holds.
    clear(): void {
        super.clear();
        this.faces_.length = 0;
    }

    // Appends one triangle face.
    addFace(face: Face): void {
        this.faces_.push(face.p0);
        this.faces_.push(face.p1);
        this.faces_.push(face.p2);
    }

    // Sets a face, growing the face list with zeroed faces when needed.
    setFace(faceId: u32, face: Face): void {
        if (<i64>faceId >= <i64>this.numFaces()) {
            resizeU32Array(this.faces_, (<i32>faceId + 1) * 3, 0);
        }
        const o = <i32>faceId * 3;
        this.faces_[o] = face.p0;
        this.faces_[o + 1] = face.p1;
        this.faces_[o + 2] = face.p2;
    }

    // Fills every face from a corner table's corner-to-vertex map (the three
    // corners of face f at 3f..3f+3), growing the face list if it is short.
    setFacesFromCornerVertices(cornerToVertexMap: Array<u32>): void {
        const numCornerFaces = cornerToVertexMap.length / 3;
        if (this.numFaces() < numCornerFaces) {
            resizeU32Array(this.faces_, numCornerFaces * 3, 0);
        }
        const n = min(this.numFaces(), numCornerFaces) * 3;
        for (let i = 0; i < n; i++) {
            unchecked((this.faces_[i] = unchecked(cornerToVertexMap[i])));
        }
    }

    // Bulk-sets all faces from a flat index array (3 per face); assumes
    // `setNumFaces` was called with the right count.
    setFacesFromFlatIndices(indices: Array<u32>): void {
        const n = this.faces_.length;
        for (let i = 0; i < n; i++) {
            this.faces_[i] = indices[i];
        }
    }

    // Bulk-sets all faces from tightly packed u8 indices.
    setFacesFromU8Indices(bytes: Uint8Array): void {
        const n = min(this.faces_.length, (bytes.length / 3) * 3);
        for (let i = 0; i < n; i++) {
            unchecked((this.faces_[i] = <u32>unchecked(bytes[i])));
        }
    }

    // Bulk-sets all faces from tightly packed little-endian u16 indices.
    setFacesFromLeU16Indices(bytes: Uint8Array): void {
        const n = min(this.faces_.length, (bytes.length / 6) * 3);
        for (let i = 0; i < n; i++) {
            unchecked((this.faces_[i] = <u32>readU16Le(bytes, i * 2)));
        }
    }

    // Bulk-sets all faces from tightly packed little-endian u32 indices.
    setFacesFromLeU32Indices(bytes: Uint8Array): void {
        const n = min(this.faces_.length, (bytes.length / 12) * 3);
        for (let i = 0; i < n; i++) {
            unchecked((this.faces_[i] = readU32Le(bytes, i * 4)));
        }
    }

    // Sets one face from raw point ids (panics out of range).
    setFaceFromIndices(faceId: i32, i0: u32, i1: u32, i2: u32): void {
        if (faceId < 0 || faceId >= this.numFaces()) {
            panic("index out of bounds: the len is " + this.numFaces().toString() + " but the index is " + faceId.toString());
        }
        const o = faceId * 3;
        this.faces_[o] = i0;
        this.faces_[o + 1] = i1;
        this.faces_[o + 2] = i2;
    }

    // Returns the point indices for a face (panics out of range).
    face(faceId: u32): Face {
        if (<i64>faceId >= <i64>this.numFaces()) {
            panic("index out of bounds: the len is " + this.numFaces().toString() + " but the index is " + faceId.toString());
        }
        const o = <i32>faceId * 3;
        return Face(unchecked(this.faces_[o]), unchecked(this.faces_[o + 1]), unchecked(this.faces_[o + 2]));
    }

    // Every face's point indices, flat (3 per face), in face order: the live
    // array. Do not resize it.
    facesFlat(): Array<u32> {
        return this.faces_;
    }

    numFaces(): i32 {
        return this.faces_.length / 3;
    }

    // Resizes the face list, filling new faces with point index zero.
    setNumFaces(numFaces: i32): void {
        resizeU32Array(this.faces_, numFaces * 3, 0);
    }

    // Fallibly resizes the face list. The count is a u64 because decoders
    // pass what a stream claims: a count whose face list cannot be allocated
    // is an allocation failure, not a trap. (An Array<u32> holds
    // at most MAX_FACE_WORDS entries: its storage is one rasc object.)
    trySetNumFaces(numFaces: u64): Status {
        if (numFaces > <u64>(MAX_FACE_WORDS / 3)) {
            return DracoError.general("Failed to allocate mesh faces").fail<bool>();
        }
        resizeU32Array(this.faces_, <i32>numFaces * 3, 0);
        return okStatus();
    }

    // Merges points whose attribute values all coincide, and rewrites the
    // faces that named them (run deduplicateAttributeValues first).
    deduplicatePointIds(): void {
        this.deduplicatePointIdsReturningMap();
    }

    // deduplicatePointIds, handing back the old-point-to-new-point map
    // (identity when nothing merged).
    deduplicatePointIdsReturningMap(): Array<u32> {
        const originalNumPoints = <u32>this.numPoints();
        const indexMap = this.pointCloudDeduplicatePointIdsReturningMap();
        if (indexMap == null) {
            const ident = new Array<u32>(<i32>originalNumPoints);
            for (let i: u32 = 0; i < originalNumPoints; i++) unchecked((ident[<i32>i] = i));
            return ident;
        }
        const f = this.faces_;
        for (let i = 0; i < f.length; i++) {
            const corner = unchecked(f[i]);
            // A corner past the point count keeps its value.
            if (<u64>corner < <u64>indexMap.length) {
                unchecked((f[i] = unchecked(indexMap[<i32>corner])));
            }
        }
        return indexMap;
    }

    // Drops points no face names, and then the attribute values left with
    // no point, keeping everything else in order. Faces naming a point the
    // mesh does not have are dropped.
    removePointsUnusedByFaces(): void {
        const numPoints = this.numPoints();
        if (numPoints == 0) {
            return;
        }
        // retain faces whose corners all name existing points.
        {
            const f = this.faces_;
            let w = 0;
            const n = f.length;
            for (let r = 0; r < n; r += 3) {
                const a = unchecked(f[r]);
                const b = unchecked(f[r + 1]);
                const c = unchecked(f[r + 2]);
                if (<u64>a < <u64>numPoints && <u64>b < <u64>numPoints && <u64>c < <u64>numPoints) {
                    unchecked((f[w] = a));
                    unchecked((f[w + 1] = b));
                    unchecked((f[w + 2] = c));
                    w += 3;
                }
            }
            f.length = w;
        }

        const used = new StaticArray<bool>(numPoints);
        for (let i = 0; i < this.faces_.length; i++) {
            used[<i32>unchecked(this.faces_[i])] = true;
        }
        let numUsed = 0;
        for (let i = 0; i < numPoints; i++) {
            if (used[i]) numUsed++;
        }
        if (numUsed == numPoints) {
            // An attribute can still carry values no point names.
            this.removeUnusedAttributeValues();
            return;
        }

        const oldToNew = new StaticArray<u32>(numPoints);
        let next: u32 = 0;
        for (let point = 0; point < numPoints; point++) {
            if (used[point]) {
                oldToNew[point] = next;
                next += 1;
            } else {
                oldToNew[point] = u32.MAX_VALUE;
            }
        }
        for (let i = 0; i < this.faces_.length; i++) {
            const corner = unchecked(this.faces_[i]);
            if (<u64>corner < <u64>numPoints) {
                unchecked((this.faces_[i] = oldToNew[<i32>corner]));
            }
        }
        for (let attId = 0; attId < this.numAttributes(); attId++) {
            const att = this.attribute(attId);
            const kept = new Array<u32>();
            for (let point = 0; point < numPoints; point++) {
                if (used[point]) kept.push(att.mappedIndex(<u32>point));
            }
            this.attributeMut(attId).setExplicitMappingFrom(kept);
        }
        this.setNumPoints(numUsed);
        this.removeUnusedAttributeValues();
    }

    // Drops attribute values no point maps to.
    private removeUnusedAttributeValues(): void {
        for (let attId = 0; attId < this.numAttributes(); attId++) {
            this.attributeMut(attId).removeUnusedValues();
        }
    }

    // Merges bit-identical attribute values, then the points those values
    // made identical, then drops what no face names.
    finalize(): Status {
        const s = this.deduplicateAttributeValues();
        if (!s.ok) return s;
        this.deduplicatePointIds();
        this.removePointsUnusedByFaces();
        return okStatus();
    }

    // finalize, additionally handing back the point-merge map (what a
    // caller that built one point per polygon corner needs).
    finalizeReturningCornerMap(): Result<Array<u32>> {
        const s = this.deduplicateAttributeValues();
        if (!s.ok) return s.forward<Array<u32>>();
        const cornerToPoint = this.deduplicatePointIdsReturningMap();
        this.removePointsUnusedByFaces();
        return Result.okv<Array<u32>>(cornerToPoint);
    }

    // Renumbers points into the order the faces first name them, dropping
    // any point no face names at all. Not a deduplication.
    renumberPointsInFaceOrder(): void {
        if (this.faces_.length == 0 || this.numPoints() == 0) {
            return;
        }

        // Old point id -> new id, in first-seen face order.
        const oldToNew = new Map<u32, u32>();
        let newId: u32 = 0;
        for (let i = 0; i < this.faces_.length; i++) {
            const p = unchecked(this.faces_[i]);
            if (!oldToNew.has(p)) {
                oldToNew.set(p, newId);
                newId += 1;
            }
        }

        // No remapping needed when already in order.
        let needsRemap = false;
        const olds = oldToNew.keys();
        for (let i = 0; i < olds.length; i++) {
            if (oldToNew.get(olds[i]) != olds[i]) {
                needsRemap = true;
                break;
            }
        }
        if (!needsRemap) {
            return;
        }

        const numUnique = <i32>newId;
        const newToOld = new StaticArray<u32>(numUnique);
        for (let i = 0; i < olds.length; i++) {
            newToOld[<i32>oldToNew.get(olds[i])] = olds[i];
        }

        for (let i = 0; i < this.faces_.length; i++) {
            this.faces_[i] = oldToNew.get(unchecked(this.faces_[i]));
        }

        // Reorder every attribute's values into the new order.
        for (let attIdx = 0; attIdx < this.numAttributes(); attIdx++) {
            const att = this.attribute(attIdx);
            const stride = <i32>att.byteStride();
            const oldBuffer = att.buffer().data().slice(0);

            const newBuffer = new Uint8Array(numUnique * stride);
            for (let newIdx = 0; newIdx < numUnique; newIdx++) {
                const oldIdx = <i64>newToOld[newIdx];
                if (oldIdx * <i64>stride + <i64>stride <= <i64>oldBuffer.length) {
                    const o = <i32>oldIdx * stride;
                    newBuffer.set(oldBuffer.subarray(o, o + stride), newIdx * stride);
                }
            }

            // Through resizeUniqueEntries, so size() follows the buffer.
            const attMut = this.attributeMut(attIdx);
            if (attMut.resizeUniqueEntries(<u64>numUnique).ok) {
                attMut.bufferMut().write(0, newBuffer);
            }
        }

        this.setNumPoints(numUnique);
    }

    // A deep copy.
    clone(): Mesh {
        const m = new Mesh();
        this.copyInto(m);
        m.faces_ = this.faces_.slice(0);
        return m;
    }
}
