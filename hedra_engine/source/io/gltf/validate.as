// Document validation: every field is walked in declaration order (path
// segments are camel-cased field names, which differ from the JSON names for
// the extension fields: `khrLightsPunctual`), then each struct's hook.
// Only the fields whose validation does something are visited here:
// indices (IndexOutOfBounds), enums (Invalid), byte strides (Invalid), the missing-data hooks and the required extensions.

import { panic } from "../../../base/util";
import { JsonValue, JsonKind } from "../../../base/json";
import {
    Root, Accessor, Primitive, TextureInfo, Semantic, SemanticKind, KhrLightType,
    CHECKED_INVALID, CHECKED_NONE, TEXTURE_SOURCE_EMPTY, MIN_BYTE_STRIDE, MAX_BYTE_STRIDE, ENABLED_EXTENSIONS,
} from "./doc";

// A validation error.
export enum ValidationError {
    IndexOutOfBounds,
    Invalid,
    Missing,
    Oversize,
    Unsupported,
}

export function validationErrorText(e: ValidationError): string {
    switch (e) {
        case ValidationError.IndexOutOfBounds: return "Index out of bounds";
        case ValidationError.Invalid: return "Invalid value";
        case ValidationError.Missing: return "Missing data";
        case ValidationError.Oversize: return "Size exceeds system limits";
        default: return "Unsupported extension";
    }
}

// One `(Path, Error)` pair.
export class ValidationIssue {
    path: string;
    error: ValidationError;
    constructor(path: string, error: ValidationError) {
        this.path = path;
        this.error = error;
    }
}

// `path.name`
function field(path: string, name: string): string {
    return path.length == 0 ? name : path + "." + name;
}

// `path[i]`
function index(path: string, i: i32): string {
    return path + "[" + i.toString() + "]";
}

// `path["key"]`
function key(path: string, k: string): string {
    return path + "[\"" + k + "\"]";
}

class V {
    root: Root;
    out: Array<ValidationIssue> = [];
    constructor(root: Root) {
        this.root = root;
    }

    report(path: string, e: ValidationError): void {
        this.out.push(new ValidationIssue(path, e));
    }

    // Index<T>::validate against an array of `len` items.
    idx(path: string, i: i32, len: i32): void {
        if (i < 0 || i >= len) this.report(path, ValidationError.IndexOutOfBounds);
    }

    optIdx(path: string, i: i32, len: i32): void {
        if (i >= 0) this.idx(path, i, len);
    }

    checked(path: string, v: i32): void {
        if (v == CHECKED_INVALID) this.report(path, ValidationError.Invalid);
    }

    textureInfo(path: string, t: TextureInfo?): void {
        if (t == null) return;
        this.idx(field(path, "index"), t.index, this.root.textures.length);
    }
}

function validateAccessor(v: V, path: string, a: Accessor): void {
    v.optIdx(field(path, "bufferView"), a.bufferView, v.root.bufferViews.length);
    v.checked(field(path, "componentType"), a.componentType);
    v.checked(field(path, "type"), a.type_);
    const s = a.sparse;
    if (s != null) {
        const sp = field(path, "sparse");
        v.idx(field(field(sp, "indices"), "bufferView"), s.indices.bufferView, v.root.bufferViews.length);
        v.checked(field(field(sp, "indices"), "componentType"), s.indices.componentType);
        v.idx(field(field(sp, "values"), "bufferView"), s.values.bufferView, v.root.bufferViews.length);
    }
    // accessor_validate_hook
    if (a.sparse == null && a.bufferView < 0) v.report(field(path, "bufferView"), ValidationError.Missing);
}

// `from_value::<[f32; 3]>(v).is_err()`
function isF32x3(x: JsonValue): bool {
    if (x.kind != JsonKind.Array) return false;
    const items = x.items;
    if (items == null || items.length != 3) return false;
    for (let i = 0; i < 3; i++) {
        if (items[i].kind != JsonKind.Number) return false;
    }
    return true;
}

function validatePrimitive(v: V, path: string, p: Primitive): void {
    const nAcc = v.root.accessors.length;
    const attrs = field(path, "attributes");
    for (let i = 0; i < p.attributes.keys.length; i++) {
        const k = p.attributes.keys[i];
        const kp = key(attrs, k.toString());
        if (!k.isValid()) v.report(kp, ValidationError.Invalid);
        v.idx(kp, p.attributes.values[i], nAcc);
    }
    v.optIdx(field(path, "indices"), p.indices, nAcc);
    v.optIdx(field(path, "material"), p.material, v.root.materials.length);
    v.checked(field(path, "mode"), p.mode);
    const ts = p.targets;
    if (ts != null) {
        const tp = field(path, "targets");
        for (let i = 0; i < ts.length; i++) {
            const t = ts[i];
            const ip = index(tp, i);
            v.optIdx(field(ip, "positions"), t.positions, nAcc);
            v.optIdx(field(ip, "normals"), t.normals, nAcc);
            v.optIdx(field(ip, "tangents"), t.tangents, nAcc);
        }
    }
    // primitive_validate_hook
    const positionPath = key(attrs, "POSITION");
    const pos = p.attributes.get(Semantic.of(SemanticKind.Positions));
    if (p.attributes.has(Semantic.of(SemanticKind.Positions))) {
        if (pos < 0 || pos >= nAcc) {
            // `&root.accessors[index]` in the hook.
            panic("index out of bounds: the len is " + nAcc.toString() + " but the index is " + pos.toString());
            return;
        }
        const acc = v.root.accessors[pos];
        const mn = acc.min;
        if (mn != null) {
            if (!isF32x3(mn)) v.report(field(positionPath, "min"), ValidationError.Invalid);
        } else {
            v.report(field(positionPath, "min"), ValidationError.Missing);
        }
        const mx = acc.max;
        if (mx != null) {
            if (!isF32x3(mx)) v.report(field(positionPath, "max"), ValidationError.Invalid);
        } else {
            v.report(field(positionPath, "max"), ValidationError.Missing);
        }
    } else {
        v.report(positionPath, ValidationError.Missing);
    }
}

// Validates a Root: every (path, error) pair, in field declaration order.
export function validateRoot(root: Root, extra: Array<string> = []): Array<ValidationIssue> {
    const v = new V(root);
    const nViews = root.bufferViews.length;
    const nAcc = root.accessors.length;
    const nNodes = root.nodes.length;

    for (let i = 0; i < root.accessors.length; i++) {
        validateAccessor(v, index("accessors", i), root.accessors[i]);
    }
    for (let i = 0; i < root.animations.length; i++) {
        const a = root.animations[i];
        const ap = index("animations", i);
        // Animation::validate: samplers, then the channels' sampler indices.
        for (let j = 0; j < a.samplers.length; j++) {
            const s = a.samplers[j];
            const sp = index(field(ap, "samplers"), j);
            v.idx(field(sp, "input"), s.input, nAcc);
            v.checked(field(sp, "interpolation"), s.interpolation);
            v.idx(field(sp, "output"), s.output, nAcc);
        }
        for (let j = 0; j < a.channels.length; j++) {
            const c = a.channels[j];
            if (c.sampler < 0 || c.sampler >= a.samplers.length) {
                v.report(field(index(field(ap, "channels"), j), "sampler"), ValidationError.IndexOutOfBounds);
            }
        }
    }
    for (let i = 0; i < root.bufferViews.length; i++) {
        const b = root.bufferViews[i];
        const bp = index("bufferViews", i);
        v.idx(field(bp, "buffer"), b.buffer, root.buffers.length);
        if (b.byteStride >= 0 && (b.byteStride < MIN_BYTE_STRIDE || b.byteStride > MAX_BYTE_STRIDE)) {
            v.report(field(bp, "byteStride"), ValidationError.Invalid);
        }
        if (b.target != CHECKED_NONE) v.checked(field(bp, "target"), b.target);
    }
    v.optIdx("scene", root.scene, root.scenes.length);
    const ext = root.extensions;
    if (ext != null) {
        const k = ext.khrLightsPunctual;
        if (k != null) {
            const lp = field(field("extensions", "khrLightsPunctual"), "lights");
            for (let i = 0; i < k.lights.length; i++) {
                const l = k.lights[i];
                const ip = index(lp, i);
                v.checked(field(ip, "type"), l.type_);
                // light_validate_hook
                if (l.type_ == KhrLightType.Spot && l.spot == null) v.report(field(ip, "spot"), ValidationError.Missing);
            }
        }
    }
    for (let i = 0; i < root.cameras.length; i++) {
        const c = root.cameras[i];
        const cp = index("cameras", i);
        v.checked(field(cp, "type"), c.type_);
        // camera_validate_hook
        if (c.orthographic == null && c.perspective == null) v.report(cp, ValidationError.Missing);
    }
    for (let i = 0; i < root.images.length; i++) {
        v.optIdx(field(index("images", i), "bufferView"), root.images[i].bufferView, nViews);
    }
    for (let i = 0; i < root.materials.length; i++) {
        const m = root.materials[i];
        const mp = index("materials", i);
        v.checked(field(mp, "alphaMode"), m.alphaMode);
        const pbr = field(mp, "pbrMetallicRoughness");
        v.textureInfo(field(pbr, "baseColorTexture"), m.pbrMetallicRoughness.baseColorTexture);
        v.textureInfo(field(pbr, "metallicRoughnessTexture"), m.pbrMetallicRoughness.metallicRoughnessTexture);
        const nt = m.normalTexture;
        if (nt != null) v.idx(field(field(mp, "normalTexture"), "index"), nt.index, root.textures.length);
        const ot = m.occlusionTexture;
        if (ot != null) v.idx(field(field(mp, "occlusionTexture"), "index"), ot.index, root.textures.length);
        v.textureInfo(field(mp, "emissiveTexture"), m.emissiveTexture);
    }
    for (let i = 0; i < root.meshes.length; i++) {
        const m = root.meshes[i];
        const pp = field(index("meshes", i), "primitives");
        for (let j = 0; j < m.primitives.length; j++) validatePrimitive(v, index(pp, j), m.primitives[j]);
    }
    const nLights = root.lights().length;
    for (let i = 0; i < root.nodes.length; i++) {
        const n = root.nodes[i];
        const np = index("nodes", i);
        v.optIdx(field(np, "camera"), n.camera, root.cameras.length);
        const ch = n.children;
        if (ch != null) {
            for (let j = 0; j < ch.length; j++) v.idx(index(field(np, "children"), j), ch[j], nNodes);
        }
        const ne = n.extensions;
        if (ne != null) {
            const k = ne.khrLightsPunctual;
            if (k != null) {
                v.idx(field(field(field(np, "extensions"), "khrLightsPunctual"), "light"), k.light, nLights);
            }
        }
        v.optIdx(field(np, "mesh"), n.mesh, root.meshes.length);
        v.optIdx(field(np, "skin"), n.skin, root.skins.length);
    }
    for (let i = 0; i < root.samplers.length; i++) {
        const s = root.samplers[i];
        const sp = index("samplers", i);
        if (s.magFilter != CHECKED_NONE) v.checked(field(sp, "magFilter"), s.magFilter);
        if (s.minFilter != CHECKED_NONE) v.checked(field(sp, "minFilter"), s.minFilter);
        v.checked(field(sp, "wrapS"), s.wrapS);
        v.checked(field(sp, "wrapT"), s.wrapT);
    }
    for (let i = 0; i < root.scenes.length; i++) {
        const s = root.scenes[i];
        for (let j = 0; j < s.nodes.length; j++) v.idx(index(field(index("scenes", i), "nodes"), j), s.nodes[j], nNodes);
    }
    for (let i = 0; i < root.skins.length; i++) {
        const s = root.skins[i];
        const sp = index("skins", i);
        v.optIdx(field(sp, "inverseBindMatrices"), s.inverseBindMatrices, nAcc);
        for (let j = 0; j < s.joints.length; j++) v.idx(index(field(sp, "joints"), j), s.joints[j], nNodes);
        v.optIdx(field(sp, "skeleton"), s.skeleton, nNodes);
    }
    for (let i = 0; i < root.textures.length; i++) {
        const t = root.textures[i];
        const tp = index("textures", i);
        v.optIdx(field(tp, "sampler"), t.sampler, root.samplers.length);
        // source_validate (without allow_empty_texture)
        if (t.source == TEXTURE_SOURCE_EMPTY) {
            v.report(field(tp, "source"), ValidationError.Missing);
        } else if (t.source >= <u32>root.images.length) {
            v.report(field(tp, "source"), ValidationError.IndexOutOfBounds);
        }
    }
    // root_validate_hook. `extra` names the extensions the caller reads
    // itself (Hedra's whole materials, engine/src/source/io/gltf_to_model/import_pbr.as);
    // empty by default, so Hedra refuses what it always refused.
    for (let i = 0; i < root.extensionsRequired.length; i++) {
        const e = root.extensionsRequired[i];
        if (!ENABLED_EXTENSIONS.includes(e) && !extra.includes(e)) {
            v.report(index("extensionsRequired", i) + " = \"" + e + "\"", ValidationError.Unsupported);
        }
    }
    return v.out;
}

// The Validation error message: "invalid glTF: {path}: {error}; ...".
export function validationText(issues: Array<ValidationIssue>): string {
    let s = "invalid glTF:";
    for (let i = 0; i < issues.length; i++) {
        s += " " + issues[i].path + ": " + validationErrorText(issues[i].error) + ";";
    }
    return s;
}
