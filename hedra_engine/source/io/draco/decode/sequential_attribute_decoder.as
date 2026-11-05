// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The base sequential attribute decoder (Draco's
// `sequential_attribute_decoder.h`). It reads attribute values in point order
// with no prediction or transform; the integer, generic and normal decoders
// reuse it. Every hook is a no-op.

import { DecoderBuffer } from "../core/decoder_buffer";
import { PointAttribute } from "../geometry/geometry_attribute";
import { EntryToPointIdMap } from "../prediction/prediction_scheme";
import { PointCloudDecoder } from "./point_cloud_decoder";

export class SequentialAttributeDecoder {
    private attributeId_: i32 = -1;

    constructor() {}

    attributeId(): i32 {
        return this.attributeId_;
    }

    init(_decoder: PointCloudDecoder, attributeId: i32): void {
        this.attributeId_ = attributeId;
    }

    initializeStandalone(_attribute: PointAttribute): void {}

    decodePortableAttribute(_pointIds: EntryToPointIdMap, _inBuffer: DecoderBuffer): void {}

    decodeDataNeededByPortableTransform(_pointIds: EntryToPointIdMap, _inBuffer: DecoderBuffer): void {}

    transformAttributeToOriginalFormat(_pointIds: EntryToPointIdMap): void {}
}
