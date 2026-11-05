// Milestone 26, package WP2: a model's import settings applied where the
// Hedra library loads it (resource/model.as calls applyModelImport on
// every ModelResource it loads, when the model has an .import that is not
// all defaults: a model without one loads exactly as before).
//
// - nodes/root_scale scales the model's top-level objects' transforms
//   (their children follow), so node positions, bounds, culling and the
//   bake see the scaled model, as Godot's root scale does;
// - nodes/up_axis: the default (auto) is each format's own convention as
//   the loader applies it today (glTF +Y, .rmdl +Z); y or z override it,
//   turning the top-level objects about X;
// - meshes/light_baking sets what the model's mesh nodes get as their
//   gi_mode when instanced (disabled 0, static 1, dynamic 2: Godot's
//   GeometryInstance3D.gi_mode), unless the scene sets it on the node;
// - meshes/generate_lods and meshes/force_disable_compression are the
//   build's (bundle/write.as) and `render --lod-threshold`'s: nothing
//   here.
//
// The settings are read straight from the model's `.import` (sidecar.as)
// rather than through import/importer.as readSettings, which they mirror
// (no file: the defaults; a file of another importer: the defaults): the
// importer carries the encoders and the resource loader, and the loader
// reaches this file, so going through it would close a loop of imports.
//
// light_baking reaches the nodes a model becomes when it is instanced as a
// scene (an ext_resource PackedScene of the model: tree/model_nodes.as,
// one MeshInstance3D per mesh object, the setting as the property the
// object sets first, so the scene's own gi_mode wins); a ModelInstance3D
// draws its parts as one node, whose gi_mode is the scene's.

import { Result } from "../../../base/util";
import { MAT4_IDENTITY, Mat4, Vec4 } from "../../../base/vecmath";
import { IoErrorKind, ioErrorOf, vfs } from "../../../fs/vfs";
import { ModelFormat, ModelResource } from "../../../scene/resource/types";
import { Value } from "../../../scene/value";
import {
    LIGHT_BAKING_DISABLED, LIGHT_BAKING_DYNAMIC, LIGHT_BAKING_STATIC, MODEL_IMPORTER, ModelImportParams, UP_AXIS_AUTO,
    UP_AXIS_Y, UP_AXIS_Z,
} from "../../import/params";
import { importPathOf, parseImportFile } from "../../import/sidecar";

// Godot's GeometryInstance3D.gi_mode of meshes/light_baking (static and
// static_lightmaps both bake: static 1; dynamic 2; disabled 0).
export function giModeOf(lightBaking: i32): i32 {
    if (lightBaking == LIGHT_BAKING_DISABLED) return 0;
    if (lightBaking == LIGHT_BAKING_DYNAMIC) return 2;
    return 1;
}

// The turn that takes a model whose content is up along `up` (UP_AXIS_Y or
// UP_AXIS_Z, of the file's axes) to the scene's +Y, given the format's own
// convention the loader already applied (glTF +Y, an .rmdl, .rmdlcmd or .modeler
// +Z); the identity when they agree or `up` is auto. Exact: the cosines
// and sines of the quarter turns are written as 0 and 1.
export function upAxisTurns(format: ModelFormat, up: i32): bool {
    const native = format == ModelFormat.Gltf ? UP_AXIS_Y : UP_AXIS_Z;
    return up != UP_AXIS_AUTO && up != native;
}

export function upAxisTurn(format: ModelFormat, up: i32): Mat4 {
    if (!upAxisTurns(format, up)) return MAT4_IDENTITY;
    if (up == UP_AXIS_Z) {
        // A glTF whose content is Z up: its +Z (the scene's +Z as loaded)
        // to +Y, a quarter turn about X by -90 degrees.
        return Mat4(Vec4(1, 0, 0, 0), Vec4(0, 0, -1, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 0, 1));
    }
    // A model whose content is Y up although its format is Z up: its +Y,
    // which the loader turned to the scene's -Z, to +Y (+90 degrees).
    return Mat4(Vec4(1, 0, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, -1, 0, 0), Vec4(0, 0, 0, 1));
}

// Applies the settings to a freshly loaded model (see the header).
// Defaults change nothing.
export function applyModelImport(model: ModelResource, params: ModelImportParams): void {
    if (params.isDefault()) return;
    const s = <f32>params.rootScale;
    const turn = upAxisTurn(model.format, params.upAxis);
    const scaled = s != 1;
    const turned = upAxisTurns(model.format, params.upAxis);
    const objs = model.objects;
    if (scaled || turned) {
        const scale = Mat4(Vec4(s, 0, 0, 0), Vec4(0, s, 0, 0), Vec4(0, 0, s, 0), Vec4(0, 0, 0, 1));
        const m = scaled && turned ? scale * turn : scaled ? scale : turn;
        for (let i = 0; i < objs.length; i++) {
            const o = objs[i];
            if (o.parent < 0) o.local = m * o.local;
        }
    }
    if (params.lightBaking != LIGHT_BAKING_STATIC) {
        const gi = giModeOf(params.lightBaking);
        for (let i = 0; i < objs.length; i++) {
            const o = objs[i];
            if (o.className != "MeshInstance3D") continue;
            // First, so a property the object sets itself, and the scene's
            // own, come after it.
            o.propNames.unshift("gi_mode");
            o.propValues.unshift(Value.int(gi));
        }
    }
}

// The model's import settings: its .import's, the defaults when it has
// none (or one of another importer); a failure naming the file for an
// .import that cannot be read or does not parse.
export function modelImportSettings(modelAbs: string): Result<ModelImportParams> {
    const ip = importPathOf(modelAbs);
    const r = vfs.read(ip);
    if (!r.ok) {
        const e = ioErrorOf<Uint8Array>(r);
        if (e != null && e.kind == IoErrorKind.NotFound) return Result.okv<ModelImportParams>(new ModelImportParams());
        return Result.fail<ModelImportParams>("cannot read " + ip + ": " + r.err);
    }
    const b = r.value;
    const text = String.UTF8.decode(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
    const p = parseImportFile(text, ip);
    if (!p.ok) return p.forward<ModelImportParams>();
    if (p.value.importer != MODEL_IMPORTER) return Result.okv<ModelImportParams>(new ModelImportParams());
    return Result.okv<ModelImportParams>(ModelImportParams.from(p.value.params));
}

// The model's import settings (its .import's, else the defaults), read
// through the VFS; an .import that does not parse gives the defaults
// (resource/model.as reads modelImportSettings and warns of it).
export function modelImportParams(modelAbs: string): ModelImportParams {
    const r = modelImportSettings(modelAbs);
    return r.ok ? r.value : new ModelImportParams();
}
