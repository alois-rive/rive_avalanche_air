// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Raw Draco metadata (entries of bytes plus nested blocks), per-attribute
// metadata, and their bitstream codec.
//
// Lives with the data model because PointCloud holds a GeometryMetadata; the
// decoder needs `GeometryMetadata.decode` to parse and skip it.
//
// Name-keyed maps are a Map plus keys sorted with cmpStr when iterating.
// Absent byte, string and block lookups are `null`; absent i32 / f64 values
// are a Result<T> whose failure has err "None".

import { Result, cmpStr, stableSort, utf8Len } from "../../../../base/util";
import { DecoderBuffer, utf8ErrorText } from "../core/decoder_buffer";
import { EncoderBuffer } from "../core/encoder_buffer";
import { DracoError, Status, okStatus } from "../core/status";
import { i32LeBytes, f64LeBytes, readI32Le, readF64Le, writeI32Le, writeF64Le } from "./bytes";

// Header flag bit indicating that geometry metadata follows the payload.
export const METADATA_FLAG_MASK: u16 = 0x8000;

const MAX_METADATA_NESTING_DEPTH: i32 = 1000;
const MAX_METADATA_NAME_LEN: i32 = 255;

function bytesEqual(a: Uint8Array, b: Uint8Array): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) {
        if (unchecked(a[i]) != unchecked(b[i])) return false;
    }
    return true;
}

function sortedKeys<V>(m: Map<string, V>): Array<string> {
    const keys = m.keys();
    stableSort<string>(keys, (a: string, b: string): i32 => cmpStr(a, b));
    return keys;
}

function utf8Bytes(s: string): Uint8Array {
    return Uint8Array.wrap(String.UTF8.encode(s));
}

// One block being decoded: its sub-blocks read so far and the name of the
// one being decoded now.
class DecodeFrame {
    metadata: Metadata;
    numSub: u64;
    done: u64 = 0;
    depth: i32;
    pendingName: string = "";

    constructor(metadata: Metadata, numSub: u64, depth: i32) {
        this.metadata = metadata;
        this.numSub = numSub;
        this.depth = depth;
    }
}

// One block being encoded: its sorted sub-block names and the next to write.
class EncodeFrame {
    metadata: Metadata;
    names: Array<string>;
    next: i32 = 0;

    constructor(metadata: Metadata, names: Array<string>) {
        this.metadata = metadata;
        this.names = names;
    }
}

// Raw Draco metadata map: entries store the exact byte payload written to
// the bitstream.
export class Metadata {
    private entries_: Map<string, Uint8Array> = new Map<string, Uint8Array>();
    private subMetadata_: Map<string, Metadata> = new Map<string, Metadata>();

    constructor() {}

    // True when there are no entries or nested metadata blocks.
    isEmpty(): bool {
        return this.entries_.size == 0 && this.subMetadata_.size == 0;
    }

    // All raw entries (iterate `entryNames()` for sorted order).
    entries(): Map<string, Uint8Array> {
        return this.entries_;
    }

    // All nested blocks (iterate `subMetadataNames()` for sorted order).
    subMetadata(): Map<string, Metadata> {
        return this.subMetadata_;
    }

    // Entry names in byte order.
    entryNames(): Array<string> {
        return sortedKeys<Uint8Array>(this.entries_);
    }

    // Nested block names in byte order.
    subMetadataNames(): Array<string> {
        return sortedKeys<Metadata>(this.subMetadata_);
    }

    // The raw byte value for an entry (the stored array), or null.
    getRaw(name: string): Uint8Array? {
        if (!this.entries_.has(name)) return null;
        return this.entries_.get(name);
    }

    // Sets a raw byte entry (a copy of `value`); refuses an empty value and
    // a name longer than 255 bytes.
    setRaw(name: string, value: Uint8Array): Status {
        const v = validateMetadataName(name);
        if (!v.ok) return v;
        if (value.length == 0) {
            return DracoError.invalidParameter("Metadata entry value must not be empty").fail<bool>();
        }
        this.entries_.set(name, value.slice(0));
        return okStatus();
    }

    setI32(name: string, value: i32): Status {
        return this.setRaw(name, i32LeBytes(value));
    }

    getI32(name: string): Result<i32> {
        const bytes = this.getRaw(name);
        if (bytes == null || bytes.length != 4) return Result.fail<i32>("None");
        return Result.okv<i32>(readI32Le(bytes, 0));
    }

    setI32Array(name: string, values: Array<i32>): Status {
        const bytes = new Uint8Array(values.length * 4);
        for (let i = 0; i < values.length; i++) writeI32Le(bytes, i * 4, values[i]);
        return this.setRaw(name, bytes);
    }

    // The array, or null when the bytes are empty or not a whole number of i32s.
    getI32Array(name: string): Array<i32>? {
        const bytes = this.getRaw(name);
        if (bytes == null || bytes.length == 0 || bytes.length % 4 != 0) return null;
        const out = new Array<i32>();
        for (let o = 0; o < bytes.length; o += 4) out.push(readI32Le(bytes, o));
        return out;
    }

    setF64(name: string, value: f64): Status {
        return this.setRaw(name, f64LeBytes(value));
    }

    getF64(name: string): Result<f64> {
        const bytes = this.getRaw(name);
        if (bytes == null || bytes.length != 8) return Result.fail<f64>("None");
        return Result.okv<f64>(readF64Le(bytes, 0));
    }

    setF64Array(name: string, values: Array<f64>): Status {
        const bytes = new Uint8Array(values.length * 8);
        for (let i = 0; i < values.length; i++) writeF64Le(bytes, i * 8, values[i]);
        return this.setRaw(name, bytes);
    }

    getF64Array(name: string): Array<f64>? {
        const bytes = this.getRaw(name);
        if (bytes == null || bytes.length == 0 || bytes.length % 8 != 0) return null;
        const out = new Array<f64>();
        for (let o = 0; o < bytes.length; o += 8) out.push(readF64Le(bytes, o));
        return out;
    }

    // Stores a UTF-8 string entry.
    setString(name: string, value: string): Status {
        return this.setRaw(name, utf8Bytes(value));
    }

    // The entry as a string, or null when absent or not valid UTF-8.
    getString(name: string): string? {
        const bytes = this.getRaw(name);
        if (bytes == null) return null;
        if (utf8ErrorText(bytes) != "") return null;
        return String.UTF8.decode(bytes.slice(0).buffer);
    }

    // Removes and returns a raw entry.
    removeEntry(name: string): Uint8Array? {
        if (!this.entries_.has(name)) return null;
        const v = this.entries_.get(name);
        this.entries_.delete(name);
        return v;
    }

    getSubMetadata(name: string): Metadata? {
        if (!this.subMetadata_.has(name)) return null;
        return this.subMetadata_.get(name);
    }

    getSubMetadataMut(name: string): Metadata? {
        return this.getSubMetadata(name);
    }

    insertSubMetadata(name: string, metadata: Metadata): Status {
        const v = validateMetadataName(name);
        if (!v.ok) return v;
        if (this.subMetadata_.has(name)) {
            return DracoError.general("Duplicate sub-metadata name: " + name).fail<bool>();
        }
        this.subMetadata_.set(name, metadata);
        return okStatus();
    }

    // Decodes a metadata block from a Draco bitstream buffer.
    static decode(buffer: DecoderBuffer): Result<Metadata> {
        return Metadata.decodeWithDepth(buffer, 0);
    }

    // Decodes nested blocks on an explicit stack rather than by recursion
    // (a deep nesting would overflow the wasm operand stack long before the
    // limit of 1000 levels); reads and checks happen in depth-first order.
    private static decodeWithDepth(buffer: DecoderBuffer, depth: i32): Result<Metadata> {
        const rootR = Metadata.decodeHead(buffer, depth);
        if (!rootR.ok) return rootR.forward<Metadata>();
        const stack = new Array<DecodeFrame>();
        stack.push(rootR.value);
        while (true) {
            const top = stack[stack.length - 1];
            if (top.done == top.numSub) {
                stack.pop();
                if (stack.length == 0) {
                    return Result.okv<Metadata>(top.metadata);
                }
                const parent = stack[stack.length - 1];
                parent.metadata.subMetadata_.set(parent.pendingName, top.metadata);
                continue;
            }
            const nameR = decodeName(buffer);
            if (!nameR.ok) return nameR.forward<Metadata>();
            const name = nameR.value;
            if (top.metadata.subMetadata_.has(name)) {
                return DracoError.general("Duplicate sub-metadata name: " + name).fail<Metadata>();
            }
            top.pendingName = name;
            top.done += 1;
            const childR = Metadata.decodeHead(buffer, top.depth + 1);
            if (!childR.ok) return childR.forward<Metadata>();
            stack.push(childR.value);
        }
        return unreachable();
    }

    // One block's depth check, entries and sub-metadata count.
    private static decodeHead(buffer: DecoderBuffer, depth: i32): Result<DecodeFrame> {
        if (depth > MAX_METADATA_NESTING_DEPTH) {
            return DracoError.general("Metadata nesting depth exceeded").fail<DecodeFrame>();
        }

        const numEntriesR = decodeBoundedCount(buffer, "metadata entries count");
        if (!numEntriesR.ok) return numEntriesR.forward<DecodeFrame>();
        const numEntries = numEntriesR.value;
        const metadata = new Metadata();
        for (let i: u64 = 0; i < numEntries; i++) {
            const nameR = decodeName(buffer);
            if (!nameR.ok) return nameR.forward<DecodeFrame>();
            const sizeR = buffer.decodeVarint();
            if (!sizeR.ok) return sizeR.forward<DecodeFrame>();
            const dataSize = sizeR.value;
            if (dataSize == 0) {
                return DracoError.general("Invalid metadata entry data size").fail<DecodeFrame>();
            }
            if (dataSize > <u64>buffer.remainingSize()) {
                return DracoError.general("Failed to read metadata entry value").fail<DecodeFrame>();
            }
            const sliceR = buffer.decodeSlice(dataSize);
            if (!sliceR.ok) return sliceR.forward<DecodeFrame>();
            metadata.entries_.set(nameR.value, sliceR.value.slice(0));
        }

        const numSubR = decodeBoundedCount(buffer, "sub-metadata count");
        if (!numSubR.ok) return numSubR.forward<DecodeFrame>();
        return Result.okv<DecodeFrame>(new DecodeFrame(metadata, numSubR.value, depth));
    }

    // Encodes this metadata block (entries and blocks in name order),
    // walking the sub-blocks on an explicit stack in depth-first order.
    encode(buffer: EncoderBuffer): Status {
        const rootR = this.encodeHead(buffer);
        if (!rootR.ok) return rootR.forward<bool>();
        const stack = new Array<EncodeFrame>();
        stack.push(rootR.value);
        while (stack.length > 0) {
            const top = stack[stack.length - 1];
            if (top.next == top.names.length) {
                stack.pop();
                continue;
            }
            const name = top.names[top.next];
            top.next += 1;
            const e = encodeName(buffer, name);
            if (!e.ok) return e;
            const childR = top.metadata.subMetadata_.get(name).encodeHead(buffer);
            if (!childR.ok) return childR.forward<bool>();
            stack.push(childR.value);
        }
        return okStatus();
    }

    // This block's entries and sub-block count.
    private encodeHead(buffer: EncoderBuffer): Result<EncodeFrame> {
        const names = this.entryNames();
        buffer.encodeVarint(<u64>names.length);
        for (let i = 0; i < names.length; i++) {
            const name = names[i];
            const e = encodeName(buffer, name);
            if (!e.ok) return e.forward<EncodeFrame>();
            const value = this.entries_.get(name);
            if (value.length == 0) {
                return DracoError.invalidParameter("Metadata entry value must not be empty").fail<EncodeFrame>();
            }
            buffer.encodeVarint(<u64>value.length);
            buffer.encodeData(value);
        }

        const subs = this.subMetadataNames();
        buffer.encodeVarint(<u64>subs.length);
        return Result.okv<EncodeFrame>(new EncodeFrame(this, subs));
    }

    // Structural equality. Walks the blocks on an explicit stack: a decoded
    // block can nest 1000 deep, which overflows the wasm operand stack when
    // recursed (the result is the same, only the visiting order differs).
    equals(other: Metadata): bool {
        const left: Array<Metadata> = [this];
        const right: Array<Metadata> = [other];
        while (left.length > 0) {
            const a = left.pop();
            const b = right.pop();
            if (a.entries_.size != b.entries_.size || a.subMetadata_.size != b.subMetadata_.size) return false;
            const names = a.entries_.keys();
            for (let i = 0; i < names.length; i++) {
                const n = names[i];
                if (!b.entries_.has(n)) return false;
                if (!bytesEqual(a.entries_.get(n), b.entries_.get(n))) return false;
            }
            const subs = a.subMetadata_.keys();
            for (let i = 0; i < subs.length; i++) {
                const n = subs[i];
                if (!b.subMetadata_.has(n)) return false;
                left.push(a.subMetadata_.get(n));
                right.push(b.subMetadata_.get(n));
            }
        }
        return true;
    }

    // A deep copy (on an explicit stack, like equals).
    clone(): Metadata {
        const root = new Metadata();
        const sources: Array<Metadata> = [this];
        const copies: Array<Metadata> = [root];
        while (sources.length > 0) {
            const src = sources.pop();
            const dst = copies.pop();
            const names = src.entries_.keys();
            for (let i = 0; i < names.length; i++) dst.entries_.set(names[i], src.entries_.get(names[i]).slice(0));
            const subs = src.subMetadata_.keys();
            for (let i = 0; i < subs.length; i++) {
                const child = new Metadata();
                dst.subMetadata_.set(subs[i], child);
                sources.push(src.subMetadata_.get(subs[i]));
                copies.push(child);
            }
        }
        return root;
    }
}

// Metadata associated with one geometry attribute unique id.
export class AttributeMetadata {
    private attributeUniqueId_: u32;
    metadataValue: Metadata;

    constructor(attributeUniqueId: u32, metadata: Metadata) {
        this.attributeUniqueId_ = attributeUniqueId;
        this.metadataValue = metadata;
    }

    attributeUniqueId(): u32 {
        return this.attributeUniqueId_;
    }

    metadata(): Metadata {
        return this.metadataValue;
    }

    metadataMut(): Metadata {
        return this.metadataValue;
    }

    equals(other: AttributeMetadata): bool {
        return this.attributeUniqueId_ == other.attributeUniqueId_ && this.metadataValue.equals(other.metadataValue);
    }

    clone(): AttributeMetadata {
        return new AttributeMetadata(this.attributeUniqueId_, this.metadataValue.clone());
    }
}

// Geometry-level metadata plus per-attribute metadata.
export class GeometryMetadata {
    private metadata_: Metadata = new Metadata();
    private attributeMetadata_: Array<AttributeMetadata> = new Array<AttributeMetadata>();

    constructor() {}

    // True when no geometry or attribute metadata is present.
    isEmpty(): bool {
        return this.metadata_.isEmpty() && this.attributeMetadata_.length == 0;
    }

    metadata(): Metadata {
        return this.metadata_;
    }

    metadataMut(): Metadata {
        return this.metadata_;
    }

    attributeMetadata(): Array<AttributeMetadata> {
        return this.attributeMetadata_;
    }

    // The first per-attribute block with this unique id, or null.
    attributeMetadataByUniqueId(attributeUniqueId: u32): AttributeMetadata? {
        for (let i = 0; i < this.attributeMetadata_.length; i++) {
            const m = this.attributeMetadata_[i];
            if (m.attributeUniqueId() == attributeUniqueId) return m;
        }
        return null;
    }

    // The first per-attribute block whose string entry `entryName` equals `entryValue`.
    attributeMetadataByStringEntry(entryName: string, entryValue: string): AttributeMetadata? {
        for (let i = 0; i < this.attributeMetadata_.length; i++) {
            const m = this.attributeMetadata_[i];
            const s = m.metadataValue.getString(entryName);
            if (s != null && s == entryValue) return m;
        }
        return null;
    }

    attributeMetadataByUniqueIdMut(attributeUniqueId: u32): AttributeMetadata? {
        return this.attributeMetadataByUniqueId(attributeUniqueId);
    }

    // Inserts or replaces metadata for one attribute unique id.
    setAttributeMetadata(attributeUniqueId: u32, metadata: Metadata): void {
        const existing = this.attributeMetadataByUniqueIdMut(attributeUniqueId);
        if (existing != null) {
            existing.metadataValue = metadata;
        } else {
            this.attributeMetadata_.push(new AttributeMetadata(attributeUniqueId, metadata));
        }
    }

    // Decodes geometry metadata from a Draco bitstream buffer.
    static decode(buffer: DecoderBuffer): Result<GeometryMetadata> {
        const countR = decodeBoundedCount(buffer, "attribute metadata count");
        if (!countR.ok) return countR.forward<GeometryMetadata>();
        const numAttributeMetadata = countR.value;
        const geometryMetadata = new GeometryMetadata();

        for (let i: u64 = 0; i < numAttributeMetadata; i++) {
            const idR = buffer.decodeVarint();
            if (!idR.ok) return idR.forward<GeometryMetadata>();
            if (idR.value > <u64>u32.MAX_VALUE) {
                return DracoError.general("Attribute metadata unique id too large").fail<GeometryMetadata>();
            }
            const mR = Metadata.decode(buffer);
            if (!mR.ok) return mR.forward<GeometryMetadata>();
            geometryMetadata.attributeMetadata_.push(new AttributeMetadata(<u32>idR.value, mR.value));
        }
        const mR = Metadata.decode(buffer);
        if (!mR.ok) return mR.forward<GeometryMetadata>();
        geometryMetadata.metadata_ = mR.value;
        return Result.okv<GeometryMetadata>(geometryMetadata);
    }

    // Encodes geometry metadata to a Draco bitstream buffer.
    encode(buffer: EncoderBuffer): Status {
        buffer.encodeVarint(<u64>this.attributeMetadata_.length);
        for (let i = 0; i < this.attributeMetadata_.length; i++) {
            const am = this.attributeMetadata_[i];
            buffer.encodeVarint(<u64>am.attributeUniqueId());
            const s = am.metadataValue.encode(buffer);
            if (!s.ok) return s;
        }
        return this.metadata_.encode(buffer);
    }

    // Structural equality.
    equals(other: GeometryMetadata): bool {
        if (!this.metadata_.equals(other.metadata_)) return false;
        if (this.attributeMetadata_.length != other.attributeMetadata_.length) return false;
        for (let i = 0; i < this.attributeMetadata_.length; i++) {
            if (!this.attributeMetadata_[i].equals(other.attributeMetadata_[i])) return false;
        }
        return true;
    }

    // A deep copy.
    clone(): GeometryMetadata {
        const g = new GeometryMetadata();
        g.metadata_ = this.metadata_.clone();
        for (let i = 0; i < this.attributeMetadata_.length; i++) g.attributeMetadata_.push(this.attributeMetadata_[i].clone());
        return g;
    }
}

function validateMetadataName(name: string): Status {
    const len = utf8Len(name);
    if (len > MAX_METADATA_NAME_LEN) {
        return DracoError.invalidParameter("Metadata name too long: " + len.toString() + " bytes").fail<bool>();
    }
    return okStatus();
}

function encodeName(buffer: EncoderBuffer, name: string): Status {
    const v = validateMetadataName(name);
    if (!v.ok) return v;
    const bytes = utf8Bytes(name);
    buffer.encodeU8(<u8>bytes.length);
    if (bytes.length > 0) {
        buffer.encodeData(bytes);
    }
    return okStatus();
}

function decodeName(buffer: DecoderBuffer): Result<string> {
    const lenR = buffer.decodeU8();
    if (!lenR.ok) return lenR.forward<string>();
    const nameLen = <i32>lenR.value;
    if (nameLen > buffer.remainingSize()) {
        return DracoError.general("Failed to read metadata name").fail<string>();
    }
    const sliceR = buffer.decodeSlice(<u64>nameLen);
    if (!sliceR.ok) return sliceR.forward<string>();
    const name = sliceR.value;
    if (utf8ErrorText(name) != "") {
        return DracoError.general("Invalid UTF-8 metadata name").fail<string>();
    }
    return Result.okv<string>(String.UTF8.decode(name.slice(0).buffer));
}

function decodeBoundedCount(buffer: DecoderBuffer, label: string): Result<u64> {
    const r = buffer.decodeVarint();
    if (!r.ok) return r;
    const count = r.value;
    if (count > <u64>buffer.remainingSize()) {
        return DracoError.general("Invalid " + label).fail<u64>();
    }
    return Result.okv<u64>(count);
}
