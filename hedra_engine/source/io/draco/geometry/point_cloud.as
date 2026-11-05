// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Point cloud geometry with typed attributes and optional metadata. Mesh
// (mesh.as) extends this class.
//
// `attribute(id)` panics out of range; `tryAttribute` returns a Result.
// Optional attributes are `PointAttribute?`.

import { Result, panic } from "../../../../base/util";
import { DracoError, Status, okStatus } from "../core/status";
import { AttributeStorage, GeometryAttributeType, PointAttribute } from "./geometry_attribute";
import { AttributeMetadata, GeometryMetadata, Metadata } from "./metadata";

// A point's key for the dedup maps: its value index per attribute, two
// UTF-16 units per u32.
function pointKey(pc: PointCloud, point: u32, units: Array<i32>): string {
    const n = pc.numAttributes();
    for (let attId = 0; attId < n; attId++) {
        const v = pc.attribute(attId).mappedIndex(point);
        unchecked((units[attId * 2] = <i32>(v & 0xffff)));
        unchecked((units[attId * 2 + 1] = <i32>(v >>> 16)));
    }
    return String.fromCharCodes(units);
}

export class PointCloud {
    protected attributes: Array<PointAttribute> = new Array<PointAttribute>();
    protected numPoints_: i32 = 0;
    protected metadata_: GeometryMetadata? = null;
    // The value storage and explicit maps of attributes a `clear` dropped,
    // handed to the next attributes added. Empty on a cloud never cleared.
    spareStorage: Array<AttributeStorage> = new Array<AttributeStorage>();

    constructor() {}

    // Drops every attribute, point and the metadata, keeping the dropped
    // attributes' storage (emptied) for the next attributes added.
    clear(): void {
        for (let i = 0; i < this.attributes.length; i++) {
            const storage = this.attributes[i].takeStorage();
            if (storage.bytes.capacity() > 0 || storage.mapCapacity > 0) {
                this.spareStorage.push(storage);
            }
        }
        this.attributes.length = 0;
        this.numPoints_ = 0;
        this.metadata_ = null;
    }

    // Frees the storage `clear` retained from earlier attributes.
    releaseSpareStorage(): void {
        this.spareStorage = new Array<AttributeStorage>();
    }

    // Hands a spare storage to an attribute that has none of its own.
    private adoptSpareStorage(attribute: PointAttribute): void {
        if (attribute.buffer().hasStorage()) {
            return;
        }
        if (this.spareStorage.length > 0) {
            attribute.adoptStorage(this.spareStorage.pop());
        }
    }

    // Sets the number of logical points.
    setNumPoints(numPoints: i32): void {
        this.numPoints_ = numPoints;
    }

    // Adds an attribute (taking ownership) and assigns it a unique id
    // matching its attribute id.
    addAttribute(attribute: PointAttribute): i32 {
        if (this.numPoints_ == 0 && attribute.size() > 0) {
            this.numPoints_ = attribute.size();
        }
        const id = this.attributes.length;
        attribute.setUniqueId(<u32>id);
        this.adoptSpareStorage(attribute);
        this.attributes.push(attribute);
        return id;
    }

    // Adds an attribute while preserving its existing unique id.
    addAttributePreserveUniqueId(attribute: PointAttribute): i32 {
        if (this.numPoints_ == 0 && attribute.size() > 0) {
            this.numPoints_ = attribute.size();
        }
        const id = this.attributes.length;
        this.adoptSpareStorage(attribute);
        this.attributes.push(attribute);
        return id;
    }

    // Places an attribute at `attId`, growing the list with empty attributes
    // if needed; its unique id becomes `attId`.
    setAttribute(attId: i32, attribute: PointAttribute): void {
        // A negative id is an impossibly large index: panic as a failed growth.
        if (attId < 0) panic("capacity overflow");
        const index = attId;
        while (this.attributes.length <= index) {
            this.attributes.push(new PointAttribute());
        }
        attribute.setUniqueId(<u32>attId);
        this.attributes[index] = attribute;
    }

    numAttributes(): i32 {
        return this.attributes.length;
    }

    // The attribute id for a Draco unique id, or -1.
    attributeIdByUniqueId(uniqueId: u32): i32 {
        for (let i = 0; i < this.attributes.length; i++) {
            if (this.attributes[i].uniqueId() == uniqueId) {
                return i;
            }
        }
        return -1;
    }

    attributeByUniqueId(uniqueId: u32): PointAttribute? {
        const id = this.attributeIdByUniqueId(uniqueId);
        return id >= 0 ? this.attributes[id] : null;
    }

    // Returns an attribute by attribute id (panics out of range).
    attribute(attId: i32): PointAttribute {
        if (attId < 0 || attId >= this.attributes.length) {
            panic(
                // The id is printed as an unsigned 64-bit index.
                "index out of bounds: the len is " + this.attributes.length.toString() + " but the index is " + (<u64><i64>attId).toString(),
            );
        }
        return unchecked(this.attributes[attId]);
    }

    tryAttribute(attId: i32): Result<PointAttribute> {
        if (attId < 0 || attId >= this.attributes.length) {
            return DracoError.general("Point cloud attribute id out of range").fail<PointAttribute>();
        }
        return Result.okv<PointAttribute>(this.attributes[attId]);
    }

    attributeMut(attId: i32): PointAttribute {
        return this.attribute(attId);
    }

    tryAttributeMut(attId: i32): Result<PointAttribute> {
        return this.tryAttribute(attId);
    }

    // The first attribute id with the requested semantic type, or -1.
    namedAttributeId(attType: GeometryAttributeType): i32 {
        for (let i = 0; i < this.attributes.length; i++) {
            if (this.attributes[i].attributeType() == attType) {
                return i;
            }
        }
        return -1;
    }

    namedAttribute(attType: GeometryAttributeType): PointAttribute? {
        const id = this.namedAttributeId(attType);
        return id >= 0 ? this.attributes[id] : null;
    }

    // Merges bit-identical values in every attribute.
    deduplicateAttributeValues(): Status {
        if (this.numPoints() == 0) {
            return okStatus();
        }
        for (let attId = 0; attId < this.numAttributes(); attId++) {
            const r = this.attributeMut(attId).deduplicateValues();
            if (!r.ok) return r.forward<bool>();
        }
        return okStatus();
    }

    // Merges points whose attribute values all coincide, keeping the order
    // in which they first appear. (Mesh overrides this to remap its faces.)
    deduplicatePointIds(): void {
        this.pointCloudDeduplicatePointIdsReturningMap();
    }

    // PointCloud::deduplicate_point_ids_returning_map (renamed: Mesh has its
    // own with a different result): the old-point-to-new-point map when
    // anything merged, else null.
    pointCloudDeduplicatePointIdsReturningMap(): Array<u32>? {
        const numPoints = this.numPoints();
        if (numPoints == 0 || this.numAttributes() == 0) {
            return null;
        }

        const units = new Array<i32>(this.numAttributes() * 2);
        const firstSeen = new Map<string, u32>();
        const indexMap = new Array<u32>();
        const uniquePoints = new Array<u32>();
        let numUnique: u32 = 0;
        for (let point = 0; point < numPoints; point++) {
            const key = pointKey(this, <u32>point, units);
            if (firstSeen.has(key)) {
                indexMap.push(firstSeen.get(key));
            } else {
                firstSeen.set(key, numUnique);
                indexMap.push(numUnique);
                uniquePoints.push(<u32>point);
                numUnique += 1;
            }
        }
        if (<i32>numUnique == numPoints) {
            return null;
        }

        // Each attribute's new map is built whole and installed whole.
        for (let attId = 0; attId < this.numAttributes(); attId++) {
            const att = this.attribute(attId);
            const values = new Array<u32>(uniquePoints.length);
            for (let k = 0; k < uniquePoints.length; k++) {
                unchecked((values[k] = att.mappedIndex(unchecked(uniquePoints[k]))));
            }
            this.attributeMut(attId).setExplicitMappingFrom(values);
        }
        this.setNumPoints(<i32>numUnique);
        return indexMap;
    }

    // Returns the number of logical points.
    numPoints(): i32 {
        return this.numPoints_;
    }

    metadata(): GeometryMetadata? {
        return this.metadata_;
    }

    metadataMut(): GeometryMetadata? {
        return this.metadata_;
    }

    // Geometry metadata, inserting an empty block when absent.
    metadataOrInsert(): GeometryMetadata {
        let m = this.metadata_;
        if (m == null) {
            m = new GeometryMetadata();
            this.metadata_ = m;
        }
        return m;
    }

    setMetadata(metadata: GeometryMetadata?): void {
        this.metadata_ = metadata;
    }

    attributeMetadataByUniqueId(attributeUniqueId: u32): AttributeMetadata? {
        const m = this.metadata_;
        if (m == null) return null;
        return m.attributeMetadataByUniqueId(attributeUniqueId);
    }

    attributeMetadataByStringEntry(entryName: string, entryValue: string): AttributeMetadata? {
        const m = this.metadata_;
        if (m == null) return null;
        return m.attributeMetadataByStringEntry(entryName, entryValue);
    }

    // Sets metadata for an attribute id.
    setAttributeMetadata(attId: i32, metadata: Metadata): Status {
        const a = this.tryAttribute(attId);
        if (!a.ok) return a.forward<bool>();
        const uniqueId = a.value.uniqueId();
        this.metadataOrInsert().setAttributeMetadata(uniqueId, metadata);
        return okStatus();
    }

    // A deep copy, spare storage included (a clone's capacity is its
    // length, so each spare map's capacity becomes
    // its length, as ByteVec.clone does for the bytes).
    clone(): PointCloud {
        const pc = new PointCloud();
        this.copyInto(pc);
        return pc;
    }

    protected copyInto(pc: PointCloud): void {
        for (let i = 0; i < this.attributes.length; i++) pc.attributes.push(this.attributes[i].clone());
        pc.numPoints_ = this.numPoints_;
        const m = this.metadata_;
        pc.metadata_ = m != null ? m.clone() : null;
        for (let i = 0; i < this.spareStorage.length; i++) {
            const s = this.spareStorage[i];
            pc.spareStorage.push(new AttributeStorage(s.bytes.clone(), s.map.slice(0), s.map.length));
        }
    }
}
