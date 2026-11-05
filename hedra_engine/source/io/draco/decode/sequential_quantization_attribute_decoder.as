// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Reads an attribute that was quantized into integers (Draco's
// `sequential_quantization_attribute_decoder.h`). The integer decoder fills a
// portable attribute with the quantized values; the quantization transform
// held here turns them back into floats.
//
// Where the parameters sit depends on the version: below 2.0 between the
// prediction header and the values (read first, then stepped over); 2.0 and
// later after the values, where the caller reads them.

import { Result } from "../../../../base/util";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DataType, dataTypeDebug } from "../core/draco_types";
import { DracoError, Status, okStatus } from "../core/status";
import { AttributeQuantizationTransform } from "../geometry/attribute_quantization_transform";
import { PointAttribute } from "../geometry/geometry_attribute";
import { PointCloud } from "../geometry/point_cloud";
import { CornerTable } from "../mesh/corner_table";
import { EntryToPointIdMap } from "../prediction/prediction_scheme";
import { PointCloudDecoder, carriesTransformByte } from "./point_cloud_decoder";
import {
    PortableExtent,
    PreIntegerDecodeHook,
    SequentialIntegerAttributeDecoder,
    SkipBytesHook,
} from "./sequential_integer_attribute_decoder";

export class SequentialQuantizationAttributeDecoder {
    private base: SequentialIntegerAttributeDecoder = new SequentialIntegerAttributeDecoder();
    private transform_: AttributeQuantizationTransform = new AttributeQuantizationTransform();

    constructor() {}

    // The transform with whatever parameters have been read so far (all of
    // them below 2.0; none yet at 2.0 and later).
    transform(): AttributeQuantizationTransform {
        return this.transform_;
    }

    // Hands the transform over.
    intoTransform(): AttributeQuantizationTransform {
        return this.transform_;
    }

    // Refuses an attribute quantization cannot describe: only floating-point
    // values are quantized.
    init(decoder: PointCloudDecoder, pointCloud: PointCloud, attributeId: i32): Status {
        this.base.init(decoder, attributeId);

        const r = pointCloud.tryAttribute(attributeId);
        if (!r.ok) return r.forward<bool>();
        const attribute = r.value;
        if (attribute.dataType() != DataType.Float32) {
            return DracoError.general(
                "Quantized decoding needs float32 values, attribute " + attributeId.toString() + " is " +
                dataTypeDebug(attribute.dataType()),
            ).fail<bool>();
        }
        return okStatus();
    }

    // Reads the quantization parameters out of a pre-2.0 stream and reports
    // how many bytes the integer decode has to step over to reach the values.
    // The buffer is left where it was found.
    private readInlineParameters(pointCloud: PointCloud, attributeId: i32, buffer: DecoderBuffer): Result<u64> {
        const savedPos = buffer.position();
        const rm = buffer.decodeU8();
        if (!rm.ok) {
            return DracoError.general("Failed to read prediction method").fail<u64>();
        }
        const carriesTransform = carriesTransformByte(rm.value);
        if (carriesTransform) {
            if (!buffer.decodeU8().ok) {
                return DracoError.general("Failed to read transform type").fail<u64>();
            }
        }
        const ro = pointCloud.tryAttribute(attributeId);
        if (!ro.ok) return ro.forward<u64>();
        const sp = this.transform_.decodeParameters(ro.value, buffer);
        if (!sp.ok) {
            return DracoError.general("Failed to decode quantization parameters (v<2.0): " + sp.err).fail<u64>();
        }

        const bytesConsumed = <u64>(buffer.position() - savedPos);
        const headerBytes: u64 = carriesTransform ? 2 : 1;
        if (!buffer.setPosition(<u64>savedPos).ok) {
            return DracoError.general("Failed to reset buffer position").fail<u64>();
        }
        return Result.okv<u64>(bytesConsumed - headerBytes);
    }

    // Decodes the quantized values into a portable attribute and hands it
    // back for the caller's inverse transform.
    decodeValues(
        pointCloud: PointCloud,
        pointIds: EntryToPointIdMap,
        buffer: DecoderBuffer,
        bitstreamVersion: u16,
        extent: PortableExtent,
        cornerTable: CornerTable?,
        dataToCornerMap: Array<u32>?,
        vertexToDataMap: Array<i32>?,
        portableParentAttribute: PointAttribute?,
    ): Result<PointAttribute> {
        const attributeId = this.base.attributeId();
        // The portable attribute keeps the original's type and width and
        // swaps only the value representation.
        const ro = pointCloud.tryAttribute(attributeId);
        if (!ro.ok) return ro.forward<PointAttribute>();
        const attributeType = ro.value.attributeType();
        const numComponents = ro.value.numComponents();
        const portable = new PointAttribute();
        const si = extent.init(portable, attributeType, numComponents, DataType.Uint32, false);
        if (!si.ok) return si.forward<PointAttribute>();

        let skipBytes: u64 = 0;
        if (bitstreamVersion < 0x0200) {
            const r = this.readInlineParameters(pointCloud, attributeId, buffer);
            if (!r.ok) return r.forward<PointAttribute>();
            skipBytes = r.value;
        }

        const hook: PreIntegerDecodeHook? = skipBytes > 0 ? new SkipBytesHook(skipBytes) : null;

        const s = this.base.decodeValues(
            pointCloud,
            pointIds,
            buffer,
            cornerTable,
            dataToCornerMap,
            vertexToDataMap,
            portable,
            portableParentAttribute,
            hook,
        );
        if (!s.ok) return s.forward<PointAttribute>();
        return Result.okv<PointAttribute>(portable);
    }
}
