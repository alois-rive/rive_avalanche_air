// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Decodes octahedron-encoded normals (Draco's
// `sequential_normal_attribute_decoder.h`). The integer decoder reads the
// quantized 2D octahedral pair into a portable attribute; the caller's inverse
// octahedral transform rebuilds unit normals from it. The mesh-only arguments
// (corner table, maps, portable position) are null for a point cloud.

import { Result } from "../../../../base/util";
import { DecoderBuffer } from "../core/decoder_buffer";
import { DataType, dataTypeDebug } from "../core/draco_types";
import { DracoError, Status, okStatus } from "../core/status";
import { AttributeOctahedronTransform } from "../geometry/attribute_octahedron_transform";
import { GeometryAttributeType, PointAttribute } from "../geometry/geometry_attribute";
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

export class SequentialNormalAttributeDecoder {
    private base: SequentialIntegerAttributeDecoder = new SequentialIntegerAttributeDecoder();
    private quantizationBits_: u8 = 0;

    constructor() {}

    // The octahedron bit count read from the stream, once `decodeValues` has
    // run. Zero for 2.0 and later, where the count follows the values and the
    // caller takes it from the transform data instead.
    quantizationBits(): u8 {
        return this.quantizationBits_;
    }

    // Refuses an attribute the octahedral encoding cannot describe (three
    // float32 components), before a byte is read.
    init(decoder: PointCloudDecoder, pointCloud: PointCloud, attributeId: i32): Status {
        this.base.init(decoder, attributeId);

        const r = pointCloud.tryAttribute(attributeId);
        if (!r.ok) return r.forward<bool>();
        const attribute = r.value;
        if (attribute.numComponents() != 3) {
            return DracoError.general(
                "Normal decoding needs 3 components, attribute " + attributeId.toString() + " has " +
                attribute.numComponents().toString(),
            ).fail<bool>();
        }
        if (attribute.dataType() != DataType.Float32) {
            return DracoError.general(
                "Normal decoding needs float32 values, attribute " + attributeId.toString() + " is " +
                dataTypeDebug(attribute.dataType()),
            ).fail<bool>();
        }
        return okStatus();
    }

    // Reads the octahedron's bit count out of a pre-2.0 stream and reports
    // how many bytes the integer decode has to step over to reach the values.
    // The buffer is left where it was found.
    private readInlineQuantizationBits(buffer: DecoderBuffer): Result<u64> {
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
        const rq = buffer.decodeU8();
        if (!rq.ok) {
            return DracoError.general("Failed to read normal quant_bits").fail<u64>();
        }
        const quantizationBits = rq.value;
        if (!AttributeOctahedronTransform.isValidQuantizationBits(<i32>quantizationBits)) {
            return DracoError.general("Invalid normal quantization bits").fail<u64>();
        }
        this.quantizationBits_ = quantizationBits;

        const bytesConsumed = <u64>(buffer.position() - savedPos);
        const headerBytes: u64 = carriesTransform ? 2 : 1;
        if (!buffer.setPosition(<u64>savedPos).ok) {
            return DracoError.general("Failed to reset buffer position").fail<u64>();
        }
        return Result.okv<u64>(bytesConsumed - headerBytes);
    }

    // Decodes the octahedral pair into a portable attribute and hands it back
    // for the caller's inverse transform.
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
        const portable = new PointAttribute();
        const si = extent.init(portable, GeometryAttributeType.Generic, 2, DataType.Uint32, false);
        if (!si.ok) return si.forward<PointAttribute>();

        let skipBytes: u64 = 0;
        if (bitstreamVersion < 0x0200) {
            const r = this.readInlineQuantizationBits(buffer);
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
