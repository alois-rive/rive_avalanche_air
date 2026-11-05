// PoseClip: one copied pose channel (the CLI's `pose copy`), which the scene
// keeps (Scene.poseClipboard) and the file stores. It lives with the model,
// not with the pose operators that make it, so that the model does not
// depend on Hedra's operators.

import { Vec3, Quat } from "../../../base/vecmath";
import { debugStr, debugStruct } from "../../../base/fmt";

// One copied pose channel (`pose copy`), persisted in the scene so a later
// invocation can paste it. The field order is the file format.
export class PoseClip {
    bone: string = "";
    location: Vec3 = Vec3(0, 0, 0);
    rotation: Quat = Quat(0, 0, 0, 1);
    scale: Vec3 = Vec3(1, 1, 1);

    constructor(bone: string = "", location: Vec3 = Vec3(0, 0, 0), rotation: Quat = Quat(0, 0, 0, 1), scale: Vec3 = Vec3(1, 1, 1)) {
        this.bone = bone;
        this.location = location;
        this.rotation = rotation;
        this.scale = scale;
    }

    clone(): PoseClip {
        return new PoseClip(this.bone, this.location, this.rotation, this.scale);
    }

    equals(o: PoseClip): bool {
        return this.bone == o.bone && this.location == o.location && this.rotation == o.rotation && this.scale == o.scale;
    }

    // Debug text: `PoseClip { bone: "B", location: Vec3(..), rotation: Quat(..), scale: Vec3(..) }`.
    debug(): string {
        return debugStruct(
            "PoseClip",
            ["bone", "location", "rotation", "scale"],
            [debugStr(this.bone), this.location.debug(), this.rotation.debug(), this.scale.debug()],
        );
    }
}
