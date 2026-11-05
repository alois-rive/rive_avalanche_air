// Scene space and model space. A scene is Y up, right-handed, in metres,
// like Godot and glTF; a model (a .modeler file, and a glTF file once the
// shared importer has read it into a shared/model Scene) is Z up, like
// Blender. Both are right-handed, so going from one to the other is a
// rotation: a quarter turn about X,
//
//     model (x, y, z)  ->  scene (x, z, -y)
//
// which is exactly the inverse of the conversion the glTF importer applies
// (engine/src/source/io/core/axis.as, forward -Z, up Y), so a glTF model lands in a
// scene with the coordinates its file holds, bit for bit.
//
// A point or direction converts with MODEL_TO_SCENE; a transform that acts
// in model space (an object's matrix) converts by conjugation,
// M_scene = C * M_model * C^-1, so that the same object ends up in the same
// place whichever space its parents are in, and an unrotated object becomes
// an unrotated node. Cameras and lights of a .modeler file are the
// exception: they aim along their own -Z in both conventions, so their node
// keeps the object's own axes (world C * M_model, no C^-1 on the right) and
// aims where the object aims in Hedra. A glTF file's cameras and lights
// convert by conjugation like everything else, since the importer converted
// them that way, so their node's transform is the file's (resource/model.as;
// docs/formats/RSCN.md, "Space").

import { Mat4, Vec3, Vec4 } from "../base/vecmath";

// Columns: where model X, Y and Z go in scene space.
export const MODEL_TO_SCENE: Mat4 = Mat4(
    Vec4(1, 0, 0, 0),
    Vec4(0, 0, -1, 0),
    Vec4(0, 1, 0, 0),
    Vec4(0, 0, 0, 1),
);

export const SCENE_TO_MODEL: Mat4 = Mat4(
    Vec4(1, 0, 0, 0),
    Vec4(0, 0, 1, 0),
    Vec4(0, -1, 0, 0),
    Vec4(0, 0, 0, 1),
);

// A model-space point or direction in scene space: (x, z, -y). Exact (no
// arithmetic but a sign change).
export function modelToScene(p: Vec3): Vec3 {
    return Vec3(p.x, p.z, -p.y);
}

// A scene-space point or direction in model space: (x, -z, y).
export function sceneToModel(p: Vec3): Vec3 {
    return Vec3(p.x, -p.z, p.y);
}

// A model-space transform in scene space: C * m * C^-1. Exact: it permutes
// and negates the matrix's entries.
export function modelMatrixToScene(m: Mat4): Mat4 {
    // Rows and columns y and z swap, and those that cross get a sign.
    return Mat4(
        Vec4(m.xAxis.x, m.xAxis.z, -m.xAxis.y, m.xAxis.w),
        Vec4(m.zAxis.x, m.zAxis.z, -m.zAxis.y, m.zAxis.w),
        Vec4(-m.yAxis.x, -m.yAxis.z, m.yAxis.y, -m.yAxis.w),
        Vec4(m.wAxis.x, m.wAxis.z, -m.wAxis.y, m.wAxis.w),
    );
}
