// What an .rmdl holds besides its model (milestone 60): the document's head,
// which no command changes and a tool rewriting the file keeps (the model
// project holds it beside the scene: engine/src/authoring/model_project/
// project.as), and what a read gives back.
//
// The head is the root's `uid`, the `<meta>` entries in file order, and the
// `uid` of each ext_resource that has one (by its type and path: the model
// keeps a file as its path, so the uid waits here for the writer).
// Comments, unknown elements and unknown attributes are not kept: the file
// is written from the model, as Godot writes a .tscn (a read warns about
// what a rewrite would drop).
//
// Milestone 61: a Material's `shader` and its `shader_parameter/<name>`
// properties (RMDL.md section 5: the material is a ShaderMaterial, its own
// settings its fallback) are no part of the model's data form, which no
// command reads or writes: they wait here, by the material's name, for
// the loader (engine/src/source/scene/resource/model.as, which makes the
// ShaderMaterial) and the writer (write.as, which writes them back after
// the material's own properties). A material renamed or removed by a
// command leaves its entry unused, and a rewrite drops it.

import { Scene } from "../scene";
import { Diagnostics } from "../../../scene/error";

// One `<meta name="..." value="..."/>`.
export class RmdlMeta {
    name: string;
    value: string;

    constructor(name: string, value: string) {
        this.name = name;
        this.value = value;
    }

    clone(): RmdlMeta {
        return new RmdlMeta(this.name, this.value);
    }
}

// The uid an `<ext_resource>` carried, kept for the file it names: as
// `.rscn` keeps one, written back on the ext_resource of that type and path.
export class RmdlExtUid {
    type: string;
    path: string;
    uid: string;

    constructor(type: string, path: string, uid: string) {
        this.type = type;
        this.path = path;
        this.uid = uid;
    }

    clone(): RmdlExtUid {
        return new RmdlExtUid(this.type, this.path, this.uid);
    }
}

// Milestone 61: one Material's shader and parameters, as the document
// wrote them: the shader's path, and each parameter's name with its value's
// text (canonical: value_text.as printValue), or for a texture its file's
// path (`textures[i]` non-empty, `values[i]` then "").
export class RmdlShader {
    material: string;
    path: string;
    params: Array<string> = [];
    values: Array<string> = [];
    textures: Array<string> = [];

    constructor(material: string, path: string) {
        this.material = material;
        this.path = path;
    }

    clone(): RmdlShader {
        const s = new RmdlShader(this.material, this.path);
        for (let i = 0; i < this.params.length; i++) {
            s.params.push(this.params[i]);
            s.values.push(this.values[i]);
            s.textures.push(this.textures[i]);
        }
        return s;
    }
}

export class RmdlHead {
    // The root's uid (`rmdl://bench`), or null when it has none.
    uid: string? = null;
    // The metadata, in file order (a name at most once).
    meta: Array<RmdlMeta> = [];
    // The ext_resources' uids, in file order (one per type and path).
    extUids: Array<RmdlExtUid> = [];
    // Milestone 61: the materials' shaders, in file order (one per material
    // name).
    shaders: Array<RmdlShader> = [];

    clone(): RmdlHead {
        const h = new RmdlHead();
        h.uid = this.uid;
        for (let i = 0; i < this.meta.length; i++) h.meta.push(this.meta[i].clone());
        for (let i = 0; i < this.extUids.length; i++) h.extUids.push(this.extUids[i].clone());
        for (let i = 0; i < this.shaders.length; i++) h.shaders.push(this.shaders[i].clone());
        return h;
    }

    isEmpty(): bool {
        return this.uid == null && this.meta.length == 0 && this.extUids.length == 0 && this.shaders.length == 0;
    }

    // Milestone 61: the shader of the material named `material`, or null.
    shaderOf(material: string): RmdlShader? {
        for (let i = 0; i < this.shaders.length; i++) if (this.shaders[i].material == material) return this.shaders[i];
        return null;
    }

    // The uid kept for the ext_resource of `type` naming `path`, or null.
    extUid(type: string, path: string): string? {
        for (let i = 0; i < this.extUids.length; i++) {
            const e = this.extUids[i];
            if (e.type == type && e.path == path) return e.uid;
        }
        return null;
    }

    // Keeps `uid` for the ext_resource of `type` naming `path` (the last
    // one given wins).
    setExtUid(type: string, path: string, uid: string): void {
        for (let i = 0; i < this.extUids.length; i++) {
            const e = this.extUids[i];
            if (e.type == type && e.path == path) {
                e.uid = uid;
                return;
            }
        }
        this.extUids.push(new RmdlExtUid(type, path, uid));
    }

    // The value of a metadata entry, or null.
    metaValue(name: string): string? {
        for (let i = 0; i < this.meta.length; i++) if (this.meta[i].name == name) return this.meta[i].value;
        return null;
    }
}

// A document read: its head, the scene it holds (after Scene.afterLoad, as
// a decoded scene), and the warnings of the read (unknown content dropped
// on a rewrite, unused resources).
export class RmdlRead {
    head: RmdlHead;
    scene: Scene;
    warnings: Diagnostics;
    // How many comments and processing instructions the read skipped: a
    // rewrite drops them too (`hedra format` refuses to without --force),
    // and no warning says so.
    dropped: i32 = 0;

    constructor(head: RmdlHead, scene: Scene, warnings: Diagnostics) {
        this.head = head;
        this.scene = scene;
        this.warnings = warnings;
    }
}
