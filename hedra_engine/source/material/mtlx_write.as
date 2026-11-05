// The canonical MaterialX text of a PbrMaterial (milestone 14): what
// writeMtlx (mtlx.as) returns, the CLI's `format` and the scene editor write.
// docs/formats/MATERIALS.md, "Canonical form", is the normative
// description; in short:
//
// - `<?xml version="1.0" encoding="UTF-8"?>`, then `<materialx
//   version="1.39" colorspace="lin_rec709">`, two-space indent, one
//   element per line, "\n" line ends.
// - Elements in this order: the `texcoord` nodes the textures need
//   (`uv1`, ...), then each texture slot in PbrSlot order (its image node,
//   then its `extract`, `normalmap` or `mix`), the `gltf_pbr` node
//   `<name>_surface`, the `surfacematerial` `<name>`, and the
//   `hedra_extras` nodegraph when the material has an extra off its
//   default.
// - Attributes `name`, `type`, then `value` or `nodename` and `output`,
//   `colorspace` last (but for a texture drawn from a Rive artboard,
//   whose file input ends with `rive_artboard`, `rive_state_machine`,
//   `rive_size`, milestone 15). Inputs in their nodedef's order, each only
//   when it differs from its nodedef's default (gltf_pbr's metallic
//   default is 1, so a dielectric writes `metallic` 0).
// - Numbers are the shortest decimal that reads back as the same f32;
//   colours (glTF's colour factors, sRGB in Hedra) carry
//   colorspace="srgb_texture", so nothing is converted; `rotate` is in
//   degrees.
//
// Two departures from "only when off the default", both so that the
// reader gets back what was written: a material without iridescence writes
// `iridescence_thickness` only when it is not glTF's 400 (MaterialX's
// default is 100, read back as 400 when the film has no weight, where it
// draws nothing), and a texture's factor channels that the material does
// not read stay 1.

import { escapeXmlAttr } from "../../base/xml";
import {
    PBR_ALPHA_OPAQUE, PBR_ARTBOARD_MODES, PBR_ARTBOARD_WHEN_VISIBLE, PBR_SLOT_COUNT, PbrMaterial, PbrSlot, PbrTexture,
} from "../../material/pbr";
import {
    EXTRAS_GRAPH, EXTRA_NAMES, EXTRA_TYPES, GLTF_PBR_INPUTS, METALLIC_ROUGHNESS_NODE, MTLX_DEFS_VERSION, MTLX_REFRACTION_SCALE_DEFAULT,
    MTLX_SLOTS, MtlxInputDef,
    MtlxBillboard, MtlxSlot, RIVE_SIZE_MAX,
} from "./mtlx_defs";
import { mtlxDegrees, mtlxNumber, mtlxNumbers } from "./mtlx_text";

// An element being written: a tag, attributes in order, children.
class El {
    tag: string;
    keys: Array<string> = [];
    values: Array<string> = [];
    children: Array<El> = [];

    constructor(tag: string, name: string, type: string) {
        this.tag = tag;
        this.attr("name", name);
        this.attr("type", type);
    }

    attr(k: string, v: string): El {
        this.keys.push(k);
        this.values.push(v);
        return this;
    }

    add(e: El): El {
        this.children.push(e);
        return e;
    }

    write(out: Array<string>, depth: i32): void {
        let s = "  ".repeat(depth) + "<" + this.tag;
        for (let k = 0; k < this.keys.length; k++) s += " " + this.keys[k] + "=\"" + escapeXmlAttr(this.values[k]) + "\"";
        if (this.children.length == 0) {
            out.push(s + "/>");
            return;
        }
        out.push(s + ">");
        for (let k = 0; k < this.children.length; k++) this.children[k].write(out, depth + 1);
        out.push("  ".repeat(depth) + "</" + this.tag + ">");
    }
}

function input(name: string, type: string): El {
    return new El("input", name, type);
}

function valueInput(name: string, type: string, value: string): El {
    return input(name, type).attr("value", value);
}

function colourInput(name: string, type: string, value: string): El {
    return input(name, type).attr("value", value).attr("colorspace", "srgb_texture");
}

function linkInput(name: string, type: string, node: string, output: string = ""): El {
    const e = input(name, type).attr("nodename", node);
    if (output.length > 0) e.attr("output", output);
    return e;
}

function rgb(c: StaticArray<f32>): Array<f32> {
    return [c[0], c[1], c[2]];
}

function allAre(a: Array<f32>, v: f32): bool {
    for (let k = 0; k < a.length; k++) if (a[k] != v) return false;
    return true;
}

// A material's name as a MaterialX identifier ([A-Za-z_][A-Za-z0-9_]*):
// other characters become "_", a leading digit gets one before it, and an
// empty name is "Material".
export function mtlxIdentifier(name: string): string {
    if (name.length == 0) return "Material";
    let s = "";
    for (let k = 0; k < name.length; k++) {
        const c = name.charCodeAt(k);
        const ok = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || (k > 0 && c >= 48 && c <= 57);
        if (ok) s += name.charAt(k);
        else if (k == 0 && c >= 48 && c <= 57) s += "_" + name.charAt(k);
        else s += "_";
    }
    return s;
}

// One scope of the document (its top level, or the extras nodegraph): the
// elements written so far and the texcoord sets they need.
class Scope {
    nodes: Array<El> = [];
    sets: Array<i32> = [];

    texcoord(set: i32): string {
        if (!this.sets.includes(set)) this.sets.push(set);
        return "uv" + set.toString();
    }

    // The texcoord nodes, in set order, then the other nodes.
    elements(): Array<El> {
        const sorted = this.sets.slice(0);
        sorted.sort((a: i32, b: i32): i32 => a - b);
        const out = new Array<El>();
        for (let k = 0; k < sorted.length; k++) {
            const t = new El("texcoord", "uv" + sorted[k].toString(), "vector2");
            t.add(valueInput("index", "integer", sorted[k].toString()));
            out.push(t);
        }
        for (let k = 0; k < this.nodes.length; k++) out.push(this.nodes[k]);
        return out;
    }
}

// An image node of slot `d` for texture `t` (its file, factor, UV set and
// transform; `factor` null for none, `factorName` the factor's input).
function imageNode(scope: Scope, d: MtlxSlot, name: string, category: string, type: string, t: PbrTexture,
    factorName: string, factorType: string, factor: Array<f32>?, srgb: bool): El {
    const e = new El(category, name, type);
    const file = input("file", "filename").attr("value", t.path);
    if (d.srgb) file.attr("colorspace", "srgb_texture");
    const a = t.artboard;
    if (a != null) {
        // Milestone 15: a texture drawn from a Rive artboard names the .riv
        // and carries the artboard as attributes of the same input, after
        // colorspace (MATERIALS.md, "Artboard textures").
        file.attr("rive_artboard", a.artboard);
        if (a.stateMachine.length > 0) file.attr("rive_state_machine", a.stateMachine);
        // A size out of the reader's range (1 to RIVE_SIZE_MAX a side) is
        // drawn at the artboard's own size anyway (artboard_texture.as
        // resolveArtboardTextureSize): leaving it out loses nothing, and
        // writing it would make a file its reader refuses.
        if (a.width >= 1 && a.height >= 1 && a.width <= RIVE_SIZE_MAX && a.height <= RIVE_SIZE_MAX) {
            file.attr("rive_size", a.width.toString() + ", " + a.height.toString());
        }
        // Milestone 67: only when not the defaults, so a file of before is
        // written as it was.
        if (a.updateMode != PBR_ARTBOARD_WHEN_VISIBLE && a.updateMode >= 0 && a.updateMode < PBR_ARTBOARD_MODES.length) {
            file.attr("rive_update_mode", PBR_ARTBOARD_MODES[a.updateMode]);
        }
        if (a.updateFps > 0 && isFinite(a.updateFps)) file.attr("rive_update_fps", mtlxNumber(a.updateFps));
    }
    e.add(file);
    const factorFirst = factorName == "factor";
    if (factorFirst) factorTo(e, factorName, factorType, factor, srgb);
    if (t.texCoord != 0) e.add(linkInput("texcoord", "vector2", scope.texcoord(t.texCoord)));
    if (t.scale[0] != 1 || t.scale[1] != 1) e.add(valueInput("scale", "vector2", mtlxNumbers([t.scale[0], t.scale[1]])));
    if (t.rotation != 0) e.add(valueInput("rotate", "float", mtlxDegrees(t.rotation)));
    if (t.offset[0] != 0 || t.offset[1] != 0) e.add(valueInput("offset", "vector2", mtlxNumbers([t.offset[0], t.offset[1]])));
    if (!factorFirst) factorTo(e, factorName, factorType, factor, srgb);
    return e;
}

function factorTo(e: El, name: string, type: string, factor: Array<f32>?, srgb: bool): void {
    if (factor == null || allAre(factor, 1)) return;
    const text = mtlxNumbers(factor);
    e.add(srgb ? colourInput(name, type, text) : valueInput(name, type, text));
}

// A factor of `n` channels, 1 but for `channel`, which is `v`.
function channelFactor(n: i32, channel: i32, v: f32): Array<f32> {
    const out = new Array<f32>();
    for (let k = 0; k < n; k++) out.push(k == channel ? v : <f32>1);
    return out;
}

function extractNode(name: string, from: string, inType: string, channel: i32): El {
    const e = new El("extract", name, "float");
    e.add(linkInput("in", inType, from));
    if (channel != 0) e.add(valueInput("index", "integer", channel.toString()));
    return e;
}

// What connects to a gltf_pbr input or an extra: a node and its output.
class Link {
    node: string;
    output: string;

    constructor(node: string, output: string = "") {
        this.node = node;
        this.output = output;
    }
}

// The writer's state: the links each slot's texture made, by the input
// (or extra) they feed.
class Writer {
    m: PbrMaterial;
    // Milestone 35: the billboard beside it (null: none).
    billboard: MtlxBillboard? = null;
    top: Scope = new Scope();
    extras: Scope = new Scope();
    links: Map<string, Link> = new Map<string, Link>();

    constructor(m: PbrMaterial) {
        this.m = m;
    }

    // The scalar factor of a one-channel slot (its glTF factor).
    scalarOf(slot: i32): f32 {
        const m = this.m;
        switch (slot) {
            case PbrSlot.Metallic: return m.metallic;
            case PbrSlot.Roughness: return m.roughness;
            case PbrSlot.Clearcoat: return m.clearcoat;
            case PbrSlot.ClearcoatRoughness: return m.clearcoatRoughness;
            case PbrSlot.SheenRoughness: return m.sheenRoughness;
            case PbrSlot.Specular: return m.specular;
            case PbrSlot.Transmission: return m.transmission;
            case PbrSlot.Thickness: return m.thickness;
            case PbrSlot.Iridescence: return m.iridescence;
            case PbrSlot.DiffuseTransmission: return m.diffuseTransmission;
            default: return 1;
        }
    }

    // The colour factor of an sRGB slot.
    colourOf(slot: i32): Array<f32> {
        const m = this.m;
        switch (slot) {
            case PbrSlot.Emissive: return rgb(m.emissive);
            case PbrSlot.SheenColor: return rgb(m.sheenColor);
            case PbrSlot.SpecularColor: return rgb(m.specularColor);
            default: return rgb(m.diffuseTransmissionColor);
        }
    }

    slots(): void {
        const m = this.m;
        const mt = m.texture(PbrSlot.Metallic);
        const rt = m.texture(PbrSlot.Roughness);
        const shared = mt != null && rt != null && mt.equals(rt);
        for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
            const t = m.texture(slot);
            if (t == null) continue;
            const d = MTLX_SLOTS[slot];
            const extra = d.input.length == 0;
            const scope = extra ? this.extras : this.top;
            const key = extra ? d.extra : d.input;
            if (slot == PbrSlot.BaseColor) {
                const c = m.baseColor;
                scope.nodes.push(imageNode(scope, d, d.node, d.category, d.type, t, "color", "color4", [c[0], c[1], c[2], c[3]], true));
                this.links.set("base_color", new Link(d.node, "outcolor"));
                this.links.set("alpha", new Link(d.node, "outa"));
            } else if (slot == PbrSlot.Metallic && shared) {
                const f: Array<f32> = [1, m.roughness, m.metallic];
                scope.nodes.push(imageNode(scope, d, METALLIC_ROUGHNESS_NODE, d.category, d.type, t, "factor", "color3", f, false));
                scope.nodes.push(extractNode(d.channelNode(), METALLIC_ROUGHNESS_NODE, "color3", d.channel));
                this.links.set(key, new Link(d.channelNode()));
            } else if (slot == PbrSlot.Roughness && shared) {
                scope.nodes.push(extractNode(d.channelNode(), METALLIC_ROUGHNESS_NODE, "color3", d.channel));
                this.links.set(key, new Link(d.channelNode()));
            } else if (slot == PbrSlot.Normal || slot == PbrSlot.ClearcoatNormal) {
                const scale = slot == PbrSlot.Normal ? m.normalScale : m.clearcoatNormalScale;
                if (scale == 1) {
                    scope.nodes.push(imageNode(scope, d, d.node, d.category, d.type, t, "", "", null, false));
                    this.links.set(key, new Link(d.node));
                } else {
                    scope.nodes.push(imageNode(scope, d, d.node, "gltf_image", "vector3", t, "", "", null, false));
                    const n = new El("normalmap", d.input + "_scaled", "vector3");
                    n.add(linkInput("in", "vector3", d.node));
                    n.add(valueInput("scale", "float", mtlxNumber(scale)));
                    scope.nodes.push(n);
                    this.links.set(key, new Link(d.input + "_scaled"));
                }
            } else if (slot == PbrSlot.Occlusion) {
                scope.nodes.push(imageNode(scope, d, d.node, d.category, d.type, t, "", "", null, false));
                if (m.occlusionStrength == 1) {
                    this.links.set(key, new Link(d.node));
                } else {
                    const x = new El("mix", "occlusion_mixed", "float");
                    x.add(linkInput("fg", "float", d.node));
                    x.add(valueInput("bg", "float", "1"));
                    if (m.occlusionStrength != 0) x.add(valueInput("mix", "float", mtlxNumber(m.occlusionStrength)));
                    scope.nodes.push(x);
                    this.links.set(key, new Link("occlusion_mixed"));
                }
            } else if (slot == PbrSlot.IridescenceThickness) {
                const e = imageNode(scope, d, d.node, d.category, d.type, t, "", "", null, false);
                if (m.iridescenceThicknessMinimum != 100) {
                    e.add(valueInput("thicknessMin", "float", mtlxNumber(m.iridescenceThicknessMinimum)));
                }
                if (m.iridescenceThicknessMaximum != 400) {
                    e.add(valueInput("thicknessMax", "float", mtlxNumber(m.iridescenceThicknessMaximum)));
                }
                scope.nodes.push(e);
                this.links.set(key, new Link(d.node));
            } else if (slot == PbrSlot.Anisotropy) {
                const e = imageNode(scope, d, d.node, d.category, d.type, t, "", "", null, false);
                if (m.anisotropyStrength != 1) e.add(valueInput("anisotropy_strength", "float", mtlxNumber(m.anisotropyStrength)));
                if (m.anisotropyRotation != 0) e.add(valueInput("anisotropy_rotation", "float", mtlxNumber(m.anisotropyRotation)));
                scope.nodes.push(e);
                this.links.set("anisotropy_strength", new Link(d.node, "anisotropy_strength_out"));
                this.links.set("anisotropy_rotation", new Link(d.node, "anisotropy_rotation_out"));
            } else if (d.channel >= 0) {
                const n = d.type == "color4" ? 4 : 3;
                const f = channelFactor(n, d.channel, this.scalarOf(slot));
                scope.nodes.push(imageNode(scope, d, d.node, d.category, d.type, t, "factor", d.type, f, false));
                scope.nodes.push(extractNode(d.channelNode(), d.node, d.type, d.channel));
                this.links.set(key, new Link(d.channelNode()));
            } else if (d.srgb) {
                scope.nodes.push(imageNode(scope, d, d.node, d.category, d.type, t, "factor", "color3", this.colourOf(slot), true));
                this.links.set(key, new Link(d.node));
            } else {
                // A float image whose factor is the slot's scalar.
                scope.nodes.push(imageNode(scope, d, d.node, d.category, d.type, t, "factor", "float", [this.scalarOf(slot)], false));
                this.links.set(key, new Link(d.node));
            }
        }
    }

    // gltf_pbr's input `def`: its link, or its value when it differs from
    // the nodedef's default; null to leave it out.
    pbrInput(def: MtlxInputDef): El? {
        const name = def.name;
        if (this.links.has(name)) {
            const l = this.links.get(name);
            return linkInput(name, def.type, l.node, l.output);
        }
        const m = this.m;
        if (def.type == "color3") {
            let c: Array<f32>;
            if (name == "base_color") c = [m.baseColor[0], m.baseColor[1], m.baseColor[2]];
            else if (name == "specular_color") c = rgb(m.specularColor);
            else if (name == "sheen_color") c = rgb(m.sheenColor);
            else if (name == "emissive") c = rgb(m.emissive);
            else c = rgb(m.attenuationColor);
            const text = mtlxNumbers(c);
            return text == def.def ? null : colourInput(name, "color3", text);
        }
        if (name == "alpha_mode") {
            return m.alphaMode == PBR_ALPHA_OPAQUE ? null : valueInput(name, "integer", m.alphaMode.toString());
        }
        if (def.type != "float") return null;
        if (name == "attenuation_distance") {
            return m.attenuationDistance == 0 ? null : valueInput(name, "float", mtlxNumber(m.attenuationDistance));
        }
        if (name == "iridescence_thickness") {
            const film = m.iridescence != 0 || m.texture(PbrSlot.Iridescence) != null;
            const absent: f32 = film ? 100 : 400;
            const v = m.iridescenceThicknessMaximum;
            return v == absent ? null : valueInput(name, "float", mtlxNumber(v));
        }
        let v: f32 = 0;
        if (name == "metallic") v = m.metallic;
        else if (name == "roughness") v = m.roughness;
        else if (name == "transmission") v = m.transmission;
        else if (name == "specular") v = m.specular;
        else if (name == "ior") v = m.ior;
        else if (name == "alpha") v = m.baseColor[3];
        else if (name == "alpha_cutoff") v = m.alphaCutoff;
        else if (name == "iridescence") v = m.iridescence;
        else if (name == "iridescence_ior") v = m.iridescenceIor;
        else if (name == "sheen_roughness") v = m.sheenRoughness;
        else if (name == "clearcoat") v = m.clearcoat;
        else if (name == "clearcoat_roughness") v = m.clearcoatRoughness;
        else if (name == "emissive_strength") v = m.emissiveStrength;
        else if (name == "thickness") v = m.thickness;
        else if (name == "anisotropy_strength") v = m.anisotropyStrength;
        else if (name == "anisotropy_rotation") v = m.anisotropyRotation;
        else if (name == "dispersion") v = m.dispersion;
        else return null;
        const text = mtlxNumber(v);
        return text == def.def ? null : valueInput(name, "float", text);
    }

    // The extras off their defaults: a node (a constant, or the slot's
    // image) and the output, for each.
    extrasGraph(): El? {
        const m = this.m;
        const outputs = new Array<El>();
        for (let k = 0; k < EXTRA_NAMES.length; k++) {
            const name = EXTRA_NAMES[k];
            const type = EXTRA_TYPES[k];
            if (this.links.has(name)) {
                outputs.push(new El("output", name, type).attr("nodename", this.links.get(name).node));
                continue;
            }
            let value = "";
            let colour = false;
            if (name == "double_sided") value = m.doubleSided ? "true" : "";
            // (a double-sided material culls nothing: the reader reads
            // cull_front past then, so it is not written)
            else if (name == "cull_front") value = m.cullFront && !m.doubleSided ? "true" : "";
            else if (name == "unlit") value = m.unlit ? "true" : "";
            else if (name == "vertex_color_use_as_albedo") value = m.vertexColorUseAsAlbedo ? "true" : "";
            else if (name == "vertex_color_is_srgb") value = m.vertexColorIsSrgb ? "true" : "";
            else if (name == "billboard_mode") {
                const bb = this.billboard;
                if (bb != null && bb.mode != 0) value = bb.mode.toString();
            } else if (name == "billboard_keep_scale") {
                const bb = this.billboard;
                if (bb != null && bb.keepScale) value = "true";
            } else if (name == "refraction_scale") {
                // (milestone 62: off Godot's 0.05 only)
                const bb = this.billboard;
                if (bb != null && bb.refractionScale != MTLX_REFRACTION_SCALE_DEFAULT) value = mtlxNumber(bb.refractionScale);
            }
            else if (name == "iridescence_thickness_minimum") {
                // With a thickness texture its node holds the minimum.
                const v = m.iridescenceThicknessMinimum;
                if (v != 100 && m.texture(PbrSlot.IridescenceThickness) == null) value = mtlxNumber(v);
            } else if (name == "diffuse_transmission") {
                if (m.diffuseTransmission != 0) value = mtlxNumber(m.diffuseTransmission);
            } else {
                const c = rgb(m.diffuseTransmissionColor);
                if (!allAre(c, 1)) value = mtlxNumbers(c);
                colour = true;
            }
            if (value.length == 0) continue;
            const node = name + "_value";
            const e = new El("constant", node, type);
            // The constant's own default (0, false, black) is left out, as
            // every input at its nodedef's default.
            const zero = value == "0" || value == "0, 0, 0";
            if (!zero) e.add(colour ? colourInput("value", type, value) : valueInput("value", type, value));
            this.extras.nodes.push(e);
            outputs.push(new El("output", name, type).attr("nodename", node));
        }
        if (outputs.length == 0) return null;
        const g = new El("nodegraph", EXTRAS_GRAPH, "");
        g.keys.pop();
        g.values.pop();
        const nodes = this.extras.elements();
        for (let k = 0; k < nodes.length; k++) g.add(nodes[k]);
        for (let k = 0; k < outputs.length; k++) g.add(outputs[k]);
        return g;
    }
}

// The canonical document of `m` (see the header), with `billboard` (milestone
// 35) in the extras when it is set.
export function writeMtlxText(m: PbrMaterial, billboard: MtlxBillboard? = null): string {
    const w = new Writer(m);
    w.billboard = billboard;
    w.slots();
    let name = mtlxIdentifier(m.name);
    // A material named as one of its nodes would make two elements of one
    // name, which MaterialX forbids: such a name gets "_material".
    const taken = new Set<string>();
    const nodes = w.top.elements();
    for (let k = 0; k < nodes.length; k++) taken.add(nodes[k].values[0]);
    taken.add(EXTRAS_GRAPH);
    while (taken.has(name) || taken.has(name + "_surface")) name += "_material";
    const shaderName = name + "_surface";
    const shader = new El("gltf_pbr", shaderName, "surfaceshader");
    for (let k = 0; k < GLTF_PBR_INPUTS.length; k++) {
        const e = w.pbrInput(GLTF_PBR_INPUTS[k]);
        if (e != null) shader.add(e);
    }
    const material = new El("surfacematerial", name, "material");
    material.add(linkInput("surfaceshader", "surfaceshader", shaderName));
    const extras = w.extrasGraph();

    const out = new Array<string>();
    out.push("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    out.push("<materialx version=\"" + MTLX_DEFS_VERSION + "\" colorspace=\"lin_rec709\">");
    for (let k = 0; k < nodes.length; k++) nodes[k].write(out, 1);
    shader.write(out, 1);
    material.write(out, 1);
    if (extras != null) extras.write(out, 1);
    out.push("</materialx>");
    return out.join("\n") + "\n";
}
