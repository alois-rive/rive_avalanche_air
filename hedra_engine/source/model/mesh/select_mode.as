// The scene's `SelectMode`, in a leaf module.
//
// mesh/selection.as needs SelectMode, while the scene imports the mesh; to
// keep the mesh free of the scene module, the type lives here and
// `shared/src/model/scene` re-exports it.
//
// A rasc struct (a value, copied on assignment).

import { JsonMap, JsonValue } from "../../../base/json";
import { debugStruct } from "../../../base/fmt";

// Blender's select mode bitset (vertex / edge / face may be combined).
// Field order is the file format.
export struct SelectMode {
    vert: bool = true;
    edge: bool = false;
    face: bool = false;

    constructor(vert: bool, edge: bool, face: bool) {
        this.vert = vert;
        this.edge = edge;
        this.face = face;
    }

    operator==(a: SelectMode, b: SelectMode): bool {
        return a.vert == b.vert && a.edge == b.edge && a.face == b.face;
    }
    readonly hash(): u32 {
        return (this.vert ? 1 : 0) | (this.edge ? 2 : 0) | (this.face ? 4 : 0);
    }

    // "vert", "edge+face", ... (empty when nothing is enabled).
    readonly label(): string {
        const parts: Array<string> = [];
        if (this.vert) parts.push("vert");
        if (this.edge) parts.push("edge");
        if (this.face) parts.push("face");
        return parts.join("+");
    }

    // Debug text: `SelectMode { vert: true, edge: false, face: false }`.
    readonly debug(): string {
        return debugStruct(
            "SelectMode",
            ["vert", "edge", "face"],
            [this.vert ? "true" : "false", this.edge ? "true" : "false", this.face ? "true" : "false"],
        );
    }

    // `{"vert":..,"edge":..,"face":..}`.
    readonly toJson(): JsonValue {
        const m = new JsonMap();
        m.insert("vert", JsonValue.bool(this.vert));
        m.insert("edge", JsonValue.bool(this.edge));
        m.insert("face", JsonValue.bool(this.face));
        return JsonValue.object(m);
    }
}

// The default select mode: vertex mode only.

export function selectModeDefault(): SelectMode {
    return SelectMode(true, false, false);
}
