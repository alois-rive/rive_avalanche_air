// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// The transform-type enum and the AttributeTransform abstract class.
//
// An attribute transform converts attribute values into a more compressible
// "portable" integer representation before coding, and inverts it on decode
// (quantization, octahedral normal mapping).

import { Result } from "../../../../base/util";
import { DataType } from "../core/draco_types";
import { DecoderBuffer } from "../core/decoder_buffer";
import { EncoderBuffer } from "../core/encoder_buffer";
import { Status } from "../core/status";
import { EntryToPointIdMap } from "../prediction/prediction_scheme";
import { AttributeTransformData } from "./attribute_transform_data";
import { PointAttribute } from "./geometry_attribute";

export enum AttributeTransformType {
    InvalidTransform = -1,
    NoTransform = 0,
    QuantizationTransform = 1,
    OctahedronTransform = 2,
}

// The transform type with tag `value`; an unknown tag is a failure with
// the message "()".
export function attributeTransformTypeTryFrom(value: u8): Result<AttributeTransformType> {
    if (value <= 2) return Result.okv<AttributeTransformType>(<AttributeTransformType><i32>value);
    return Result.fail<AttributeTransformType>("()");
}

// `{:?}` of an AttributeTransformType (the variant name).
export function attributeTransformTypeDebug(t: AttributeTransformType): string {
    switch (t) {
        case AttributeTransformType.InvalidTransform: return "InvalidTransform";
        case AttributeTransformType.NoTransform: return "NoTransform";
        case AttributeTransformType.QuantizationTransform: return "QuantizationTransform";
        case AttributeTransformType.OctahedronTransform: return "OctahedronTransform";
    }
    return "";
}

// A transform between an attribute's stored values and its portable integer
// form. Every fallible method returns a Status naming what went wrong.
export abstract class AttributeTransform {
    abstract transformType(): AttributeTransformType;

    abstract initFromAttribute(attribute: PointAttribute): Status;

    abstract copyToAttributeTransformData(outData: AttributeTransformData): void;

    abstract transformAttribute(
        attribute: PointAttribute,
        pointIds: EntryToPointIdMap,
        targetAttribute: PointAttribute,
    ): Status;

    abstract inverseTransformAttribute(attribute: PointAttribute, targetAttribute: PointAttribute): Status;

    abstract encodeParameters(encoderBuffer: EncoderBuffer): Status;

    abstract decodeParameters(attribute: PointAttribute, decoderBuffer: DecoderBuffer): Status;

    abstract getTransformedDataType(attribute: PointAttribute): DataType;

    abstract getTransformedNumComponents(attribute: PointAttribute): i32;
}
