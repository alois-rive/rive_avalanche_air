// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The contiguous little-endian byte store behind every PointAttribute, with
// typed read/write helpers.
//
// Byte positions are i64 so that a position read from a stream
// is range-checked before it is narrowed. `data()` / `dataMut()` are views of
// the live bytes (the same Uint8Array: writes through it land in the buffer)
// and are valid until the next call that grows the buffer.

import { Result, panic } from "../../../../base/util";
import { debugStruct, debugList } from "../../../../base/fmt";
import { ByteVec, BYTE_VEC_MAX_CAPACITY, checkRange } from "./byte_vec";

export class DataBufferDescriptor {
    bufferId: i64 = 0;
    bufferUpdateCount: i64 = 0;

    clone(): DataBufferDescriptor {
        const d = new DataBufferDescriptor();
        d.bufferId = this.bufferId;
        d.bufferUpdateCount = this.bufferUpdateCount;
        return d;
    }

    // Debug text of the descriptor.
    debug(): string {
        return debugStruct(
            "DataBufferDescriptor",
            ["buffer_id", "buffer_update_count"],
            [this.bufferId.toString(), this.bufferUpdateCount.toString()],
        );
    }
}

// Allocation-failure messages.
const TRY_RESERVE_CAPACITY_OVERFLOW =
    "memory allocation failed because the computed capacity exceeded the collection's maximum";
const TRY_RESERVE_ALLOC_ERROR = "memory allocation failed because the memory allocator returned an error";

export class DataBuffer {
    private bytes: ByteVec = new ByteVec();
    private descriptor: DataBufferDescriptor = new DataBufferDescriptor();

    constructor() {}

    // `data` at `offset` (default 0), growing the buffer when needed.
    update(data: Uint8Array, offset: i64 = 0): void {
        const end = offset + <i64>data.length;
        if (end > <i64>this.bytes.length) {
            this.resizeTo(end);
        }
        this.bytes.range(<i32>offset, <i32>end).set(data, 0);
        this.descriptor.bufferUpdateCount += 1;
    }

    resize(newSize: i64): void {
        this.resizeTo(newSize);
    }

    private resizeTo(newSize: i64): void {
        if (newSize < 0 || newSize > <i64>BYTE_VEC_MAX_CAPACITY) panic("capacity overflow");
        this.bytes.resize(<i32>newSize, 0);
    }

    // Takes the byte storage out, leaving the buffer empty.
    takeStorage(): ByteVec {
        const s = this.bytes;
        this.bytes = new ByteVec();
        return s;
    }

    // Whether the buffer owns an allocation, empty or not.
    hasStorage(): bool {
        return this.bytes.capacity() > 0;
    }

    // Adopts a previously taken storage, emptied, as this buffer's own.
    adoptStorage(storage: ByteVec): void {
        storage.clear();
        this.bytes = storage;
    }

    // Grows or shrinks to `newSize`, failing instead of trapping when the
    // allocation cannot be made. Sizes above i64::MAX report a capacity
    // overflow; sizes above the largest allocatable Uint8Array
    // (BYTE_VEC_MAX_CAPACITY) report an allocator failure. (An allocation below that cap that
    // runs the 4 GiB wasm memory out still traps: there is no fallible
    // allocation in AS.)
    tryResize(newSize: u64): Result<bool> {
        if (newSize > <u64>this.bytes.length) {
            if (newSize > <u64>i64.MAX_VALUE) return Result.fail<bool>(TRY_RESERVE_CAPACITY_OVERFLOW);
            if (newSize > <u64>BYTE_VEC_MAX_CAPACITY) return Result.fail<bool>(TRY_RESERVE_ALLOC_ERROR);
            this.bytes.reserveExact(<i32>newSize - this.bytes.length);
        }
        this.bytes.resize(<i32>newSize, 0);
        return Result.okv<bool>(true);
    }

    // Appends the stored bytes to `stream`.
    writeDataToStream(stream: ByteVec): Result<bool> {
        stream.extend(this.bytes.data());
        return Result.okv<bool>(true);
    }

    // Copies `out.length` bytes from `bytePos` (panics out of range).
    read(bytePos: i64, out: Uint8Array): void {
        const end = bytePos + <i64>out.length;
        checkRange(bytePos, end, <i64>this.bytes.length);
        out.set(this.bytes.range(<i32>bytePos, <i32>end), 0);
    }

    tryRead(bytePos: u64, out: Uint8Array): bool {
        const len = <u64>out.length;
        if (bytePos > u64.MAX_VALUE - len) return false;
        const end = bytePos + len;
        if (end > <u64>this.bytes.length) return false;
        out.set(this.bytes.range(<i32>bytePos, <i32>end), 0);
        return true;
    }

    // Writes `inData` at `bytePos` (panics out of range).
    write(bytePos: i64, inData: Uint8Array): void {
        const end = bytePos + <i64>inData.length;
        checkRange(bytePos, end, <i64>this.bytes.length);
        this.bytes.range(<i32>bytePos, <i32>end).set(inData, 0);
    }

    tryWrite(bytePos: u64, inData: Uint8Array): bool {
        const len = <u64>inData.length;
        if (bytePos > u64.MAX_VALUE - len) return false;
        const end = bytePos + len;
        if (end > <u64>this.bytes.length) return false;
        this.bytes.range(<i32>bytePos, <i32>end).set(inData, 0);
        return true;
    }

    // Writes f32 values at `bytePos` as little-endian bytes, growing the
    // buffer when the range runs past its end. Counts as an update.
    updateF32sLe(bytePos: i64, values: Float32Array): void {
        const n = values.length;
        const end = bytePos + <i64>n * 4;
        if (end > <i64>this.bytes.length) {
            this.resizeTo(end);
        }
        const dst = this.bytes.range(<i32>bytePos, <i32>end);
        for (let i = 0; i < n; i++) {
            const bits = reinterpret<u32>(unchecked(values[i]));
            const o = i * 4;
            dst[o] = <u8>bits;
            dst[o + 1] = <u8>(bits >> 8);
            dst[o + 2] = <u8>(bits >> 16);
            dst[o + 3] = <u8>(bits >> 24);
        }
        this.descriptor.bufferUpdateCount += 1;
    }

    // updateF32sLe for an Array<f32>.
    updateF32sLeArray(bytePos: i64, values: Array<f32>): void {
        const f = new Float32Array(values.length);
        for (let i = 0; i < values.length; i++) f[i] = values[i];
        this.updateF32sLe(bytePos, f);
    }

    // Copies `size` bytes of `srcBuf` from `srcOffset` to `dstOffset`,
    // growing this buffer when needed (panics when the source range is out).
    copy(dstOffset: i64, srcBuf: DataBuffer, srcOffset: i64, size: i64): void {
        checkRange(srcOffset, srcOffset + size, <i64>srcBuf.bytes.length);
        // Copy first: `srcBuf` may be this buffer, whose storage a resize replaces.
        const src = srcBuf.bytes.range(<i32>srcOffset, <i32>(srcOffset + size)).slice(0);
        if (dstOffset + size > <i64>this.bytes.length) {
            this.resizeTo(dstOffset + size);
        }
        this.bytes.range(<i32>dstOffset, <i32>(dstOffset + size)).set(src, 0);
    }

    setUpdateCount(count: i64): void {
        this.descriptor.bufferUpdateCount = count;
    }

    updateCount(): i64 {
        return this.descriptor.bufferUpdateCount;
    }

    dataSize(): i32 {
        return this.bytes.length;
    }

    data(): Uint8Array {
        return this.bytes.data();
    }

    dataMut(): Uint8Array {
        return this.bytes.data();
    }

    bufferId(): i64 {
        return this.descriptor.bufferId;
    }

    setBufferId(bufferId: i64): void {
        this.descriptor.bufferId = bufferId;
    }

    // Debug text: `DataBuffer { data: [..], descriptor: .. }`.
    debug(): string {
        const bytes = this.bytes.data();
        const items = new Array<string>(bytes.length);
        for (let i = 0; i < bytes.length; i++) items[i] = bytes[i].toString();
        return debugStruct("DataBuffer", ["data", "descriptor"], [debugList(items), this.descriptor.debug()]);
    }

    // A deep copy of the bytes and the descriptor.
    clone(): DataBuffer {
        const d = new DataBuffer();
        d.bytes = this.bytes.clone();
        d.descriptor = this.descriptor.clone();
        return d;
    }
}
