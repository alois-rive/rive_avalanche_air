// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The generic (untyped) sequential attribute decoder. It copies attribute
// values verbatim, byte for byte, for attributes with no prediction or
// transform (Draco's `sequential_generic_attribute_decoder` path).

import { DecoderBuffer } from "../core/decoder_buffer";
import { dataTypeByteLength } from "../core/draco_types";
import { DracoError, Status, okStatus } from "../core/status";
import { U64_NONE, checkedMulU64 } from "../geometry/bytes";
import { PointCloud } from "../geometry/point_cloud";
import { EntryToPointIdMap } from "../prediction/prediction_scheme";
import { PointCloudDecoder } from "./point_cloud_decoder";
import { SequentialAttributeDecoder } from "./sequential_attribute_decoder";

export class SequentialGenericAttributeDecoder {
    private base: SequentialAttributeDecoder = new SequentialAttributeDecoder();

    constructor() {}

    init(decoder: PointCloudDecoder, attributeId: i32): void {
        this.base.init(decoder, attributeId);
    }

    decodeValues(pointCloud: PointCloud, pointIds: EntryToPointIdMap, buffer: DecoderBuffer): Status {
        const attributeId = this.base.attributeId();
        const ra = pointCloud.tryAttribute(attributeId);
        if (!ra.ok) return ra.forward<bool>();
        const attribute = ra.value;

        const numComponents = <u64>attribute.numComponents();
        const numPoints = <u64>pointIds.len();
        const dataTypeSize = <u64>dataTypeByteLength(attribute.dataType());

        // Two checked 64-bit multiplies.
        const partial = checkedMulU64(numPoints, numComponents);
        const totalSize = partial == U64_NONE ? U64_NONE : checkedMulU64(partial, dataTypeSize);
        if (totalSize == U64_NONE) {
            return DracoError.general("Generic attribute size overflow").fail<bool>();
        }

        // The bytes first, the buffer after: `decodeSlice` refuses a count the
        // remaining bytes cannot cover, so the destination is sized from data
        // that exists.
        const rb = buffer.decodeSlice(totalSize);
        if (!rb.ok) {
            return DracoError.general("Failed to decode generic attribute").fail<bool>();
        }
        const bytes = rb.value;

        const rm = pointCloud.tryAttributeMut(attributeId);
        if (!rm.ok) return rm.forward<bool>();
        const target = rm.value;
        if (!target.bufferMut().tryResize(<u64>bytes.length).ok) {
            return DracoError.general("Failed to allocate generic attribute").fail<bool>();
        }
        target.bufferMut().dataMut().set(bytes, 0);
        return okStatus();
    }
}
