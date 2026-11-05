// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Prediction-method selection, the half a decoder build needs: which
// bitstream first carried a scheme, and the scheme an older bitstream's era
// used instead. Choosing a scheme for an attribute reads the encoder, so it
// is ../encode/prediction_scheme_selection.as's; this file imports nothing
// under ../encode/ so that the decoders never pull the encoder in.

import { DracoVersion, versionLessThan } from "../core/version";
import { EncoderOptions } from "../geometry/encoder_options";
import { PredictionSchemeMethod } from "./prediction_scheme";

// The bitstream version that first carried `method`.
//
// MESH_PREDICTION_CONSTRAINED_MULTI_PARALLELOGRAM first appears in Draco
// 0.10.0 (bitstream 1.2); MESH_PREDICTION_TEX_COORDS_PORTABLE and
// MESH_PREDICTION_GEOMETRIC_NORMAL in Draco 1.0.0 (2.0). The rest have been
// there since 0.9.1 (1.1), the oldest bitstream the encoder writes.
// (Exported for tests.)
export function introducedAt(method: PredictionSchemeMethod): DracoVersion {
    switch (method) {
        case PredictionSchemeMethod.MeshPredictionConstrainedMultiParallelogram:
            return DracoVersion(1, 2);
        case PredictionSchemeMethod.MeshPredictionTexCoordsPortable:
        case PredictionSchemeMethod.MeshPredictionGeometricNormal:
            return DracoVersion(2, 0);
        default:
            return DracoVersion(1, 1);
    }
}

// The scheme an encoder of the target's era would have picked instead. Every
// substitute predates what it replaces and predicts only from the
// attribute's own previously coded values.
function eraSubstitute(method: PredictionSchemeMethod): PredictionSchemeMethod {
    switch (method) {
        case PredictionSchemeMethod.MeshPredictionGeometricNormal:
            return PredictionSchemeMethod.Difference;
        case PredictionSchemeMethod.MeshPredictionTexCoordsPortable:
        case PredictionSchemeMethod.MeshPredictionConstrainedMultiParallelogram:
            return PredictionSchemeMethod.MeshPredictionParallelogram;
        default:
            return method;
    }
}

// Replaces a scheme the target bitstream predates with the one its era used.
// Naming a scheme older decoders do not know is not a graceful degradation:
// they decode it as something else, silently. (Exported for tests.)
export function downgradeToBitstreamEra(
    method: PredictionSchemeMethod,
    options: EncoderOptions,
): PredictionSchemeMethod {
    const version = options.getVersion();
    // (0, 0) means "encoder default", which is always the newest.
    if (version.major == 0) {
        return method;
    }
    if (versionLessThan(version.major, version.minor, introducedAt(method))) {
        return eraSubstitute(method);
    }
    return method;
}
