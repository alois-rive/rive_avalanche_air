// The resources a scene uses, as the library holds them once loaded: the
// runtime side of the resource classes of ../classdb.as. A resource is shared:
// every node that names it (and every instance of a scene that declares it)
// holds the same object, and the loader's cache (loader.as) keeps one per
// file.
//
// Everything here is in scene space (Y up, ../space.as); colours are as the
// format writes them (sRGB, straight alpha, ../classdb.as).
//
// Milestone 3 scaffolding: the data model is the agreed interface of every
// package. The primitive meshes, which generate their triangles, are in
// primitives.as.

import { Mat4, Vec2, Vec3, Vec4, MAT4_IDENTITY } from "../../base/vecmath";
import { Image } from "../../render/image";
import { FloatImage } from "../../render/hdr";
import { Value } from "../value";
import { Diagnostic } from "../error";
import { RscnDoc } from "../rscn/doc";
import { RivInfo } from "../riv/riv_info";
import { DataDoc } from "../data/model";
import { LightmapData } from "../../render/lightmap/data";
import { RadianceMap } from "../../render/sky";
import { GpuMesh, MeshUploader } from "../../render/mesh";
import { CompressedImage } from "../../texture/format";
import { decodeLevel } from "../../texture/decode";
import { noteCpuMiss, pinForm, pinImage } from "./cpu_copy";
import { ModelClip, ModelSkeleton, ModelSkin } from "../skeleton/model_skin";
import { UPDATE_ONCE, UPDATE_WHEN_VISIBLE } from "../../render/viewport";

export abstract class Resource {
    // The file it was loaded from (an absolute path), for an ext_resource;
    // "" for a sub_resource or one built in code.
    path: string = "";
    // The sub_resource id it was declared with ("" otherwise).
    id: string = "";
    // The file that declared it, as errors name it (the loader's display
    // path).
    file: string = "";
    // resource_name.
    name: string = "";
    // Milestone 50: how many times a binding, a timeline or a tween wrote
    // one of its fields (../binding/material_fields.as writeResourceField):
    // a frame refreshed in place (../render/adapter.as refreshSceneFrame)
    // plans again when its environment's count moved.
    writes: i32 = 0;

    // Its class in ../classdb.as ("StandardMaterial3D", "Model").
    abstract className(): string;
}

// A sub_resource whose type this format version does not know: its
// properties are kept (the document keeps them too) and nothing uses it.
export class UnknownResource extends Resource {
    type: string;
    propNames: Array<string> = [];
    propValues: Array<Value> = [];

    constructor(type: string) {
        super();
        this.type = type;
    }

    className(): string {
        return this.type;
    }
}

// A PNG image (ext_resource type Texture2D, and a model's textures), or a
// Radiance HDR image for a PanoramaSkyMaterial (milestone 11).
export class Texture2D extends Resource {
    // The PNG's pixels; null for an .hdr file.
    image: Image? = null;
    // The .hdr file's linear texels; null for a PNG. A material slot draws
    // only `image` (materialDesc leaves an .hdr out with a warning).
    hdr: FloatImage? = null;
    width: i32 = 0;
    height: i32 = 0;
    // Milestone 26: the texture's processed forms as a built scene
    // holds them (KTX2: bundle/decode.as), in form order (bc, etc2, astc,
    // then rgba8); the material binder uploads the first the device takes
    // as it is, or decodes one (render/material.as). The run time
    // reads only the form it chose (runtime/scene_runtime.as), the tools
    // every form the bundle has. null for a texture loaded from its file,
    // or stored as its source alone; `image` is then the picture. A texture
    // stored without its source has `image` null and its forms here.
    compressed: Array<CompressedImage>? = null;
    // linear()'s PNG conversion, and the image it was made from.
    private linearImage: FloatImage? = null;
    private linearSource: Image? = null;
    // How the materials described so far sample it (noteSampled): as
    // colour (an sRGB slot) and as data (a linear one).
    sampledSrgb: bool = false;
    sampledLinear: bool = false;

    className(): string {
        return "Texture2D";
    }

    // Milestone 67b (docs/engine/RESOURCES.md, "CPU copies"): a material
    // samples the texture as colour (`srgb`) or as data. The renderer
    // uploads an image once for each (an sRGB slot's texels converted to
    // linear half floats, a data slot's as they are), so a texture sampled
    // both ways, the same picture as one material's albedo and another's
    // normal map, keeps its pixels: the second upload may come frames
    // after the first, when a run time would have released them. Said by
    // the scene's materials as they are described (../render/materials.as
    // texturePath), which is before their textures are bound.
    noteSampled(srgb: bool): void {
        if (srgb) this.sampledSrgb = true;
        else this.sampledLinear = true;
        if (this.sampledSrgb && this.sampledLinear) this.keepCpu();
    }

    // Keeps the CPU side (the image and every form) after the uploads: a
    // part of the renderer reads it on the CPU (an extension slot's
    // layers, composed into one array texture), or it is sampled both
    // ways (noteSampled).
    keepCpu(): void {
        const img = this.image;
        if (img != null) pinImage(img);
        const forms = this.compressed;
        if (forms != null) for (let i = 0; i < forms.length; i++) pinForm(forms[i]);
    }

    // The texels as linear RGB, as a panorama reads them: `hdr`, or the PNG
    // decoded from sRGB. The conversion is made once and the same object
    // returned after, so the renderer's sky cache, which checks the image
    // it was built from, sees one image from frame to frame. null for a
    // texture with neither.
    //
    // Milestone 67b (docs/engine/RESOURCES.md, "CPU copies"): the texels it
    // reads are pinned (cpu_copy.as), so that a run time keeps them when
    // the same texture is also a material's and its upload would release
    // them; a texture released before its first conversion counts a miss
    // and gives null (a black sky, as a panorama missing).
    linear(): FloatImage? {
        const h = this.hdr;
        if (h != null) return h;
        let img = this.image;
        if (img == null) img = this.firstFormDecoded();
        if (img == null) return null;
        if (this.linearSource !== img || this.linearImage == null) {
            pinImage(img);
            if (img.released) {
                noteCpuMiss("panorama: a released texture");
                return null;
            }
            this.linearImage = FloatImage.fromImage(img, true);
            this.linearSource = img;
        }
        return this.linearImage;
    }

    // A texture stored as processed forms alone (no `image`), as a picture:
    // its first form's level 0 decoded on the CPU, once (a panorama drawn
    // from a bundle that kept no source: linear()). null when it has none
    // or it does not decode.
    private decodedForm: Image? = null;

    firstFormDecoded(): Image? {
        const held = this.decodedForm;
        if (held != null) return held;
        const forms = this.compressed;
        if (forms == null || forms.length == 0 || forms[0].levels.length == 0) return null;
        const f = forms[0];
        // (milestone 67b: read on the CPU, so kept; one released already
        // has nothing to decode)
        pinForm(f);
        if (f.released) {
            noteCpuMiss("panorama: a released texture form");
            return null;
        }
        const l = f.levels[0];
        const d = decodeLevel(f.format, l.data, l.width, l.height);
        if (!d.ok) return null;
        this.decodedForm = d.value;
        return d.value;
    }
}

// Milestone 42: what a ViewModel's `file` names (docs/plans/RIVE_MODEL.md
// section 4.5): a RiveFile (.riv) or a RiveData (.rml), the abstract base
// of both (classdb's RiveSource, the class of ViewModel.file).
export abstract class RiveSource extends Resource {
}

// A Rive file (ext_resource type RiveFile, milestone 15): a .riv, read for
// its artboards (../riv/riv_info.as) so that an ArtboardTexture can name
// one. Nothing draws it in the tools; a project the CLI's `build` writes
// plays its artboards from their RML source, the Rive project beside it
// (artboard_texture.as, riveSourceDir).
export class RiveFile extends RiveSource {
    // Its artboards; null when the file could not be read as a Rive file
    // (the loader reported why).
    info: RivInfo? = null;

    className(): string {
        return "RiveFile";
    }
}

// Milestone 42: an .rml file read for its data model (ext_resource type
// RiveData, docs/plans/RIVE_MODEL.md section 4.5): the view models, enums
// and converters it declares (../data/rml_read.as), for a scene outside a
// Rive project that wants data it can edit. `data` is null when the file
// could not be read (the loader reported why).
export class RiveData extends RiveSource {
    data: DataDoc? = null;

    className(): string {
        return "RiveData";
    }
}

// What an ArtboardTexture's `path` holds after the declaring file's path
// (see below).
export const ARTBOARD_TEXTURE_MARK = "#artboard:";

// A texture drawn from a Rive artboard (sub_resource type ArtboardTexture,
// milestone 15, Godot's ViewportTexture for a Rive artboard): any material
// texture slot takes one, as it takes any Texture2D. In the tools (render,
// preview, editor) it is its placeholder, `image`: a labelled checker in
// the texture's aspect (../render/artboard_placeholder.as). In a project
// the CLI's `build` writes, the player draws the artboard into it every
// frame (../player/artboards.as).
//
// `path` is not a file: it is the absolute path of the file that declares
// the texture + ARTBOARD_TEXTURE_MARK + its sub_resource id (an .rscn) or
// its slot's property name (an .mtlx), as a glTF file's embedded image is
// `<model path>#<image>`. So two textures of one artboard are two textures
// (two instances, each with its own state), and the renderer's texture
// cache (which reads `image` through SceneTextureFiles) and the player
// key on it (artboard_texture.as, artboardTexturePath).
export class ArtboardTexture extends Texture2D {
    // `file`: the RiveFile, null when unset. (Named `rive` here: a
    // Resource's `file` is the display path of the file that declared it.)
    rive: RiveFile? = null;
    // `artboard`: the artboard's name.
    artboard: string = "";
    // `state_machine`: the state machine an instance runs; "" for the
    // artboard's default one.
    stateMachine: string = "";
    // `size`: the texture's size in pixels as set; 0 x 0 for the
    // artboard's own size. `width` and `height` (Texture2D's) are the size
    // resolved (artboard_texture.as, resolveArtboardTextureSize).
    sizeX: i32 = 0;
    sizeY: i32 = 0;
    // Milestone 67 (docs/formats/RSCN.md, "ArtboardTexture"): `update_fps`,
    // Hedra's cap on how often its picture is drawn again, in redraws a
    // second of the scene's clock (0: whenever it changes). The artboard
    // itself always advances (../player/artboards.as).
    updateFps: f32 = 0;
    // How many times `once` was written to `render_target_update_mode`
    // (updateMode's setter): the player draws a `once` texture again at each
    // new count, as Godot's SubViewport takes a new picture at each write of
    // UPDATE_ONCE. A file's value, a binding and a key write only a change
    // (../binding/apply.as artboardTextureField), so they count when it
    // becomes once.
    onceWrites: i32 = 0;
    // The bit the scene's artboard player gave this texture when it
    // collected the tree's textures (../player/artboards.as
    // ArtboardTextures.collect: 1 << its index then, 0 past the first 32 or
    // when no player holds it): the bit a frame's items carry for it
    // (../render/artboard_bits.as) and the one the player tests for
    // when_visible. Kept on the texture, not worked out again from the
    // tree's order at each plan, so that a node removed or added before it
    // in the tree shifts no bit (a texture otherwise read as out of view
    // while it is seen, and frozen). Not a property of the file.
    seenBit: u32 = 0;
    // `render_target_update_mode`: Godot's SubViewport.UpdateMode by number
    // (hedra_engine/render/viewport.as UPDATE_*), behind updateMode.
    private modeNow: i32 = UPDATE_WHEN_VISIBLE;

    get updateMode(): i32 {
        return this.modeNow;
    }

    set updateMode(m: i32) {
        if (m == UPDATE_ONCE) this.onceWrites++;
        this.modeNow = m;
    }

    className(): string {
        return "ArtboardTexture";
    }
}

// What a ViewportTexture's `path` holds after the declaring file's path
// (see below).
export const VIEWPORT_TEXTURE_MARK = "#viewport:";

// Milestone 34: the picture a SubViewport draws (sub_resource type
// ViewportTexture, Godot's ViewportTexture; docs/formats/RSCN.md,
// "Viewports"). Any texture slot takes one, as it takes any Texture2D.
// The renderer draws its SubViewport into a target of its own each time
// the viewport updates (hedra_engine/render/gpu/viewports.as) and binds that
// target wherever a slot names the texture's `path`
// (MaterialBinder.setLive), in the tools and in built projects alike; until
// the viewport has drawn once, the slot samples `image`, one transparent
// black texel (viewport_texture.as VIEWPORT_TEXTURE_BLANK), as Godot's
// never-drawn viewport texture is.
//
// `path` is not a file: the absolute path of the file that declares the
// texture + VIEWPORT_TEXTURE_MARK + its sub_resource id, as an
// ArtboardTexture's is (viewport_texture.as viewportTexturePath).
// `width` and `height` are the SubViewport's size once the tree is planned
// (DEFAULT_VIEWPORT_SIDE square before, and when it names none).
export class ViewportTexture extends Texture2D {
    // `viewport_path`: the SubViewport, from the root of the declaring
    // scene ("" when unset).
    viewportPath: string = "";

    className(): string {
        return "ViewportTexture";
    }
}

// Milestone 17: a view model of a Rive file (sub_resource type ViewModel),
// which the scene's root names as its `view_model`: the data its nodes'
// bindings read and write (docs/formats/RSCN.md, "Bindings";
// ../binding/binder.as). In the tools its values are the named instance's,
// read from the .riv (../binding/schema.as); in a project the CLI's `build`
// writes, the scene's artboard binds an instance of it, which the player
// reads and writes every frame (../player/view_model.as).
export class SceneViewModel extends Resource {
    // `file`: the RiveFile, null when unset (named `rive` as an
    // ArtboardTexture's is: a Resource's `file` is its declaring file).
    rive: RiveFile? = null;
    // Milestone 42: `file` when it names an .rml (a RiveData); null for a
    // .riv or none. With neither, the view model is the enclosing Rive
    // project's (../data/source.as dataSourceOf).
    data: RiveData? = null;
    // `view_model`: the view model's name.
    viewModel: string = "";
    // `instance`: the instance the scene starts from; "" for the view
    // model's default one.
    instance: string = "";

    className(): string {
        return "ViewModel";
    }
}

// Milestone 19: a LightmapGI's bake (ext_resource type LightmapGIData, an
// .lmbake file: ../lightmap/lmbake.as reads it, docs/formats/RSCN.md
// "LightmapGIData" is its format). `data` is in the renderer's space, as
// the adapter puts it on a frame (hedra_engine/render/lightmap/data.as); null
// never once loaded (a file that cannot be read is a load error).
export class LightmapGIData extends Resource {
    data: LightmapData? = null;

    className(): string {
        return "LightmapGIData";
    }
}

// Milestone 20: a ReflectionProbe's capture (ext_resource type
// ReflectionProbeData, an .rprobe file: ../probe/rprobe.as reads it,
// docs/formats/RSCN.md "ReflectionProbeData" is its format). `cube` is the
// filtered cube map in probe space (hedra_engine/render/probe/data.as), null when
// the file could not be read (a warning: the probe is then captured when
// drawn, as one without a bake); `capture` is where it was captured from and
// `size` the box it was captured for, both in the scene space of the root
// of the scene that declares the probe, as written.
export class ReflectionProbeData extends Resource {
    cube: RadianceMap? = null;
    capture: Vec3 = Vec3(0, 0, 0);
    size: Vec3 = Vec3(0, 0, 0);
    // The .rprobe's flags (probe/rprobe.as RPROBE_INTERIOR | RPROBE_SHADOWS):
    // what the probe was captured with, compared when drawn
    // (reflection-probe-changed).
    flags: u32 = 0;

    className(): string {
        return "ReflectionProbeData";
    }
}

// A node script (ext_resource type Script): the .as file's text. Scripts
// run only in a project the CLI's `build` writes (milestone 5); the library
// keeps the source and the name of the class that extends NodeScript.
export class Script extends Resource {
    source: string = "";
    // The class declared as `class <Name> extends NodeScript` (null when
    // there is none: a warning).
    scriptClass: string? = null;

    className(): string {
        return "Script";
    }
}

// StandardMaterial3D: the properties of ../classdb.as as fields.
export class StandardMaterial3D extends Resource {
    albedoColor: Vec4 = Vec4(1, 1, 1, 1);
    albedoTexture: Texture2D? = null;
    metallic: f32 = 0;
    metallicTexture: Texture2D? = null;
    roughness: f32 = 1;
    roughnessTexture: Texture2D? = null;
    // metallic_texture and roughness_texture are one image packed as glTF
    // packs it (blue metallic, green roughness): set for a model's
    // materials, whose metallic-roughness texture is one image.
    packedMetallicRoughness: bool = false;
    emissionEnabled: bool = false;
    emission: Vec4 = Vec4(0, 0, 0, 1);
    emissionEnergy: f32 = 1;
    emissionTexture: Texture2D? = null;
    normalEnabled: bool = false;
    normalScale: f32 = 1;
    normalTexture: Texture2D? = null;
    aoEnabled: bool = false;
    aoTexture: Texture2D? = null;
    // 0 disabled, 1 alpha, 2 alpha_scissor.
    transparency: i32 = 0;
    alphaScissorThreshold: f32 = 0.5;
    // 0 back, 1 front, 2 disabled.
    cullMode: i32 = 0;
    // Milestone 13: the vertex colour (a MultiMesh instance's) multiplies
    // the albedo, and is sRGB rather than linear.
    vertexColorUseAsAlbedo: bool = false;
    vertexColorIsSrgb: bool = false;
    // Milestone 14: uv1_scale and uv1_offset (texture coordinates are
    // scaled, then moved; z is kept, not drawn).
    uv1Scale: Vec3 = Vec3(1, 1, 1);
    uv1Offset: Vec3 = Vec3(0, 0, 0);
    // Milestone 35: Godot's billboard_mode (BILLBOARD_* of
    // ../particles/state.as) and billboard_keep_scale, drawn on a
    // CPUParticles3D's mesh (../particles/pack.as turns its particles).
    billboardMode: i32 = 0;
    billboardKeepScale: bool = false;

    // Milestone 14: the rest of glTF 2.0's material (../classdb.as
    // materialPbrProps names them; engine/src/material/pbr.as and
    // docs/formats/MATERIALS.md say what each is). Defaults are classdb's.
    // 0 unshaded (glTF's KHR_materials_unlit), 1 per_pixel.
    shadingMode: i32 = 1;
    aoStrength: f32 = 1;
    ior: f32 = 1.5;
    specular: f32 = 1;
    specularTexture: Texture2D? = null;
    specularColor: Vec4 = Vec4(1, 1, 1, 1);
    specularColorTexture: Texture2D? = null;
    clearcoatEnabled: bool = false;
    clearcoat: f32 = 1;
    clearcoatRoughness: f32 = 0.5;
    clearcoatTexture: Texture2D? = null;
    clearcoatRoughnessTexture: Texture2D? = null;
    clearcoatNormalTexture: Texture2D? = null;
    clearcoatNormalScale: f32 = 1;
    anisotropyEnabled: bool = false;
    anisotropy: f32 = 0;
    // Radians, counter-clockwise from the tangent.
    anisotropyRotation: f32 = 0;
    anisotropyTexture: Texture2D? = null;
    sheenColor: Vec4 = Vec4(0, 0, 0, 1);
    sheenColorTexture: Texture2D? = null;
    sheenRoughness: f32 = 0;
    sheenRoughnessTexture: Texture2D? = null;
    refractionEnabled: bool = false;
    // Milestone 62: Godot's refraction_scale (drawn while the Environment's
    // screen_refraction_enabled is on).
    refractionScale: f32 = 0.05;
    transmission: f32 = 1;
    refractionTexture: Texture2D? = null;
    thickness: f32 = 0;
    thicknessTexture: Texture2D? = null;
    // 0: light is never attenuated (glTF's +infinity).
    attenuationDistance: f32 = 0;
    attenuationColor: Vec4 = Vec4(1, 1, 1, 1);
    dispersion: f32 = 0;
    iridescence: f32 = 0;
    iridescenceTexture: Texture2D? = null;
    iridescenceIor: f32 = 1.3;
    iridescenceThicknessMinimum: f32 = 100;
    iridescenceThicknessMaximum: f32 = 400;
    iridescenceThicknessTexture: Texture2D? = null;
    backlightEnabled: bool = false;
    diffuseTransmission: f32 = 1;
    diffuseTransmissionTexture: Texture2D? = null;
    backlight: Vec4 = Vec4(1, 1, 1, 1);
    backlightTexture: Texture2D? = null;
    // Each texture slot's UV set and KHR_texture_transform, by PbrSlot
    // (classdb.as MATERIAL_TEXTURE_PROPS order).
    uvs: Array<MaterialUv> = MaterialUv.slots();
    // Milestone 61: Godot's Material.next_pass and render_priority (every
    // material has them; ShaderMaterial, ./shader.as, derives from this
    // class). None and 0 draw as before.
    nextPass: StandardMaterial3D? = null;
    renderPriority: i32 = 0;

    className(): string {
        return "StandardMaterial3D";
    }

    // The texture in slot `slot` (a PbrSlot: classdb.as
    // MATERIAL_TEXTURE_PROPS[slot] names it).
    textureAt(slot: i32): Texture2D? {
        switch (slot) {
            case 0: return this.albedoTexture;
            case 1: return this.metallicTexture;
            case 2: return this.roughnessTexture;
            case 3: return this.normalTexture;
            case 4: return this.aoTexture;
            case 5: return this.emissionTexture;
            case 6: return this.clearcoatTexture;
            case 7: return this.clearcoatRoughnessTexture;
            case 8: return this.clearcoatNormalTexture;
            case 9: return this.sheenColorTexture;
            case 10: return this.sheenRoughnessTexture;
            case 11: return this.specularTexture;
            case 12: return this.specularColorTexture;
            case 13: return this.refractionTexture;
            case 14: return this.thicknessTexture;
            case 15: return this.iridescenceTexture;
            case 16: return this.iridescenceThicknessTexture;
            case 17: return this.anisotropyTexture;
            case 18: return this.diffuseTransmissionTexture;
            case 19: return this.backlightTexture;
            default: return null;
        }
    }

    setTextureAt(slot: i32, t: Texture2D?): void {
        switch (slot) {
            case 0: this.albedoTexture = t; break;
            case 1: this.metallicTexture = t; break;
            case 2: this.roughnessTexture = t; break;
            case 3: this.normalTexture = t; break;
            case 4: this.aoTexture = t; break;
            case 5: this.emissionTexture = t; break;
            case 6: this.clearcoatTexture = t; break;
            case 7: this.clearcoatRoughnessTexture = t; break;
            case 8: this.clearcoatNormalTexture = t; break;
            case 9: this.sheenColorTexture = t; break;
            case 10: this.sheenRoughnessTexture = t; break;
            case 11: this.specularTexture = t; break;
            case 12: this.specularColorTexture = t; break;
            case 13: this.refractionTexture = t; break;
            case 14: this.thicknessTexture = t; break;
            case 15: this.iridescenceTexture = t; break;
            case 16: this.iridescenceThicknessTexture = t; break;
            case 17: this.anisotropyTexture = t; break;
            case 18: this.diffuseTransmissionTexture = t; break;
            case 19: this.backlightTexture = t; break;
            default: break;
        }
    }
}

// A material texture slot's UV set and KHR_texture_transform
// (`<texture>_texcoord`, `_offset`, `_rotation` in radians, `_scale`).
export class MaterialUv {
    texcoord: i32 = 0;
    offset: Vec2 = Vec2(0, 0);
    rotation: f32 = 0;
    scale: Vec2 = Vec2(1, 1);

    // The 20 slots' (PBR_SLOT_COUNT) identity transforms. (A static
    // method: the linter does not see a function called from a field's
    // initialiser.)
    static slots(): Array<MaterialUv> {
        const a: Array<MaterialUv> = [];
        for (let i = 0; i < 20; i++) a.push(new MaterialUv());
        return a;
    }

    isIdentity(): bool {
        return this.texcoord == 0 && this.offset.x == 0 && this.offset.y == 0 && this.rotation == 0
            && this.scale.x == 1 && this.scale.y == 1;
    }
}

// Environment: the properties of ../classdb.as as fields.
export class Environment extends Resource {
    // 0 clear_color, 1 color, 2 sky.
    backgroundMode: i32 = 0;
    backgroundColor: Vec4 = Vec4(0, 0, 0, 1);
    backgroundEnergy: f32 = 1;
    sky: Sky? = null;
    // Euler angles in radians, order YXZ.
    skyRotation: Vec3 = Vec3(0, 0, 0);
    // 0 background, 1 disabled, 2 color, 3 sky.
    ambientLightSource: i32 = 0;
    ambientLightColor: Vec4 = Vec4(0, 0, 0, 1);
    ambientLightSkyContribution: f32 = 1;
    ambientLightEnergy: f32 = 1;
    // 0 background, 1 disabled, 2 sky.
    reflectedLightSource: i32 = 0;
    skyTopColor: Vec4 = Vec4(0.385, 0.454, 0.55, 1);
    skyHorizonColor: Vec4 = Vec4(0.6463, 0.6558, 0.6708, 1);
    groundBottomColor: Vec4 = Vec4(0.2, 0.169, 0.133, 1);
    groundHorizonColor: Vec4 = Vec4(0.6463, 0.6558, 0.6708, 1);
    // 0 linear, 1 reinhard, 2 filmic, 3 aces, 4 agx.
    tonemapMode: i32 = 0;
    tonemapExposure: f32 = 1;
    tonemapWhite: f32 = 1;
    // Milestone 62: Godot's screen-space reflections, and Hedra's switch of
    // the screen-space refraction (../classdb.as).
    ssrEnabled: bool = false;
    ssrMaxSteps: i32 = 64;
    ssrFadeIn: f32 = 0.15;
    ssrFadeOut: f32 = 2;
    ssrDepthTolerance: f32 = 0.2;
    screenRefractionEnabled: bool = false;
    // Milestone 12: SSAO, glow and adjustments.
    ssaoEnabled: bool = false;
    ssaoRadius: f32 = 1;
    ssaoIntensity: f32 = 2;
    ssaoPower: f32 = 1.5;
    ssaoDetail: f32 = 0.5;
    ssaoHorizon: f32 = 0.06;
    ssaoSharpness: f32 = 0.98;
    ssaoLightAffect: f32 = 0;
    ssaoAoChannelAffect: f32 = 0;
    glowEnabled: bool = false;
    // glow_levels/1 .. glow_levels/7.
    glowLevels: Array<f32> = [0, 0, 1, 0, 1, 0, 0];
    glowNormalized: bool = false;
    glowIntensity: f32 = 0.8;
    glowStrength: f32 = 1;
    glowMix: f32 = 0.05;
    glowBloom: f32 = 0;
    // 0 additive, 1 screen, 2 softlight, 3 replace, 4 mix.
    glowBlendMode: i32 = 2;
    glowHdrThreshold: f32 = 1;
    glowHdrScale: f32 = 2;
    glowHdrLuminanceCap: f32 = 12;
    adjustmentEnabled: bool = false;
    adjustmentBrightness: f32 = 1;
    adjustmentContrast: f32 = 1;
    adjustmentSaturation: f32 = 1;
    fogEnabled: bool = false;
    // 0 exponential, 1 depth.
    fogMode: i32 = 0;
    fogLightColor: Vec4 = Vec4(0.518, 0.553, 0.608, 1);
    fogLightEnergy: f32 = 1;
    fogSunScatter: f32 = 0;
    fogDensity: f32 = 0.01;
    fogAerialPerspective: f32 = 0;
    fogSkyAffect: f32 = 1;
    fogHeight: f32 = 0;
    fogHeightDensity: f32 = 0;
    fogDepthCurve: f32 = 1;
    fogDepthBegin: f32 = 10;
    fogDepthEnd: f32 = 100;
    // Milestone 37: Godot's volumetric fog (../classdb.as; docs/engine/
    // FOG.md), as the file wrote them (sRGB colours). gi_inject,
    // detail_spread and the temporal reprojection are kept, not drawn.
    volumetricFogEnabled: bool = false;
    volumetricFogDensity: f32 = 0.05;
    volumetricFogAlbedo: Vec4 = Vec4(1, 1, 1, 1);
    volumetricFogEmission: Vec4 = Vec4(0, 0, 0, 1);
    volumetricFogEmissionEnergy: f32 = 1;
    volumetricFogGiInject: f32 = 1;
    volumetricFogAnisotropy: f32 = 0.2;
    volumetricFogLength: f32 = 64;
    volumetricFogDetailSpread: f32 = 2;
    volumetricFogAmbientInject: f32 = 0;
    volumetricFogSkyAffect: f32 = 1;
    volumetricFogTemporalReprojectionEnabled: bool = true;
    volumetricFogTemporalReprojectionAmount: f32 = 0.9;

    className(): string {
        return "Environment";
    }
}

// Sky: the material it is drawn with, and the reflection map's size.
export class Sky extends Resource {
    // A ProceduralSkyMaterial or a PanoramaSkyMaterial (null: none, and
    // the environment draws as if it had no sky).
    skyMaterial: Resource? = null;
    // radiance_size: 0..6 for 32..2048 texels.
    radianceSize: i32 = 3;

    className(): string {
        return "Sky";
    }
}

// ProceduralSkyMaterial: the properties of ../classdb.as as fields.
export class ProceduralSkyMaterial extends Resource {
    skyTopColor: Vec4 = Vec4(0.385, 0.454, 0.55, 1);
    skyHorizonColor: Vec4 = Vec4(0.6463, 0.6558, 0.6708, 1);
    skyCurve: f32 = 0.15;
    skyEnergy: f32 = 1;
    groundBottomColor: Vec4 = Vec4(0.2, 0.169, 0.133, 1);
    groundHorizonColor: Vec4 = Vec4(0.6463, 0.6558, 0.6708, 1);
    groundCurve: f32 = 0.02;
    groundEnergy: f32 = 1;
    // Degrees.
    sunAngleMax: f32 = 30;
    sunCurve: f32 = 0.15;
    energy: f32 = 1;

    className(): string {
        return "ProceduralSkyMaterial";
    }
}

// PanoramaSkyMaterial: an equirectangular image (a .hdr or .png Texture2D).
export class PanoramaSkyMaterial extends Resource {
    panorama: Texture2D? = null;
    filter: bool = true;
    energy: f32 = 1;

    className(): string {
        return "PanoramaSkyMaterial";
    }
}

// One material's triangles: flat arrays, three floats per position and
// normal and two per UV, indices in threes, counter-clockwise seen from the
// front (the side the normal points to).
export class MeshSurface {
    positions: Array<f32> = [];
    normals: Array<f32> = [];
    // Empty when the mesh has no UVs.
    uvs: Array<f32> = [];
    indices: Array<u32> = [];
    material: StandardMaterial3D? = null;

    vertexCount(): i32 {
        return this.positions.length / 3;
    }

    triangleCount(): i32 {
        return this.indices.length / 3;
    }
}

export abstract class Mesh extends Resource {
    // The triangles (a primitive mesh generates them on first use).
    abstract arrays(): ArrayMesh;
}

// Where a model's mesh came from: an object of the model it was evaluated
// from. A renderer draws such a mesh from the model itself (its
// ModelSource's mesh cache: as Hedra builds it, in model space) rather
// than from the triangles below, so a model looks the same in both programs
// (milestone 4, ../render/meshes.as).
export class ModelMeshSource {
    model: ModelResource;
    // The object's id in the model (ModelSource's ids: the Hedra scene's
    // object ids, for the tools' models).
    objectId: u32;

    constructor(model: ModelResource, objectId: u32) {
        this.model = model;
        this.objectId = objectId;
    }
}

// Milestone 40: what the renderer asks of the model a ModelResource was
// read from, by object id. The model kernel (Hedra's Scene, its meshes
// and modifiers) is the tools': they read a model file into one and give
// the ModelResource a source over it (engine/src/source/scene/resource/
// model_source.as, KernelModelSource), so the engine draws a model as
// Hedra does without carrying the kernel. A model from a built scene (a
// self-contained .rscnb) has no source: its meshes arrive
// prebuilt (ArrayMesh.prebuilt) with what the adapter would have asked
// here.
export abstract class ModelSource {
    // The name of object `id`; null when the model has no such object (it
    // was removed since the meshes were evaluated).
    abstract objectName(id: u32): string?;

    // The index in ModelResource.materials of material slot `slot` of
    // object `id`; -1 when the object is gone or the slot is missing or
    // names no material (the default material then applies).
    abstract materialIndex(id: u32, slot: u16): i64;

    // The UV layer the textures of object `id` sample through (its UV set
    // 0); null for the mesh's active layer.
    abstract textureLayer(id: u32): string?;

    // A new cache of this model's GPU meshes. Object ids are per model, so
    // a scene render cache keeps one per model it draws (../render/cache.as).
    abstract meshCache(): ModelMeshCache;
}

// A model's GPU meshes, built from its objects on first use and kept until
// the object changes (ModelSource.meshCache).
export abstract class ModelMeshCache {
    // How many meshes were built (the scene render cache counts them, and
    // tests see the cache hit).
    builds: u32 = 0;

    // The GpuMesh of object `id`, in model space (Z up), with UV set 1 and
    // no cage or weights, uploaded through `uploader` when it is not null;
    // null when the object is gone or is no mesh.
    abstract mesh(id: u32, uploader: MeshUploader?): GpuMesh?;
}

// Milestone 39: a mesh that arrives ready from a built scene
// (../bundle/provider.as): the GpuMesh the renderer would have built (a
// model's through meshbuild, anything else's through arrayMeshToGpu), and
// what the adapter otherwise reads from the model behind it, so that a
// tree loaded from a bundle plans the frame a tree loaded from the files
// plans, with no model to evaluate. The scene render cache
// (../render/cache.as) takes `gpu` as it is, shared by every tree and
// every instance that uses the mesh, so it is uploaded once.
export class PrebuiltMesh {
    gpu: GpuMesh;
    // Placed as a model's mesh (built in model space, Z up) rather than as
    // a primitive's (scene space): SceneMesh.fromSource.
    modelSpace: bool = false;
    // The material of each range slot of `gpu` (what the adapter's
    // rangeMaterial finds through the model for a model's mesh).
    slotMaterials: Array<StandardMaterial3D?> = [];
    // The material Hedra colours the object by (its slot 0's), and the
    // object's name (the Random shading's colour).
    colorMaterial: StandardMaterial3D? = null;
    objectName: string = "";

    constructor(gpu: GpuMesh) {
        this.gpu = gpu;
    }
}

// Triangles with their materials: a model's meshes, and what a primitive
// mesh generates.
export class ArrayMesh extends Mesh {
    surfaces: Array<MeshSurface> = [];
    // The model object it was evaluated from; null for a primitive or a
    // mesh built in code.
    source: ModelMeshSource? = null;
    // Milestone 39: the mesh ready from a bundle (null everywhere else);
    // when set, the renderer draws it and never reads `surfaces` or
    // `source` for the triangles (the bounds below still hold).
    prebuilt: PrebuiltMesh? = null;
    // The bounds of every position (both zero when there is none), set by
    // computeBounds.
    aabbMin: Vec3 = Vec3(0, 0, 0);
    aabbMax: Vec3 = Vec3(0, 0, 0);

    className(): string {
        return "ArrayMesh";
    }

    arrays(): ArrayMesh {
        return this;
    }

    computeBounds(): void {
        let first = true;
        let lo = Vec3(0, 0, 0);
        let hi = Vec3(0, 0, 0);
        for (let s = 0; s < this.surfaces.length; s++) {
            const p = this.surfaces[s].positions;
            for (let i = 0; i + 2 < p.length; i += 3) {
                const v = Vec3(p[i], p[i + 1], p[i + 2]);
                if (first) {
                    lo = v;
                    hi = v;
                    first = false;
                } else {
                    lo = lo.min(v);
                    hi = hi.max(v);
                }
            }
        }
        this.aabbMin = lo;
        this.aabbMax = hi;
    }

    triangleCount(): i32 {
        let n = 0;
        for (let s = 0; s < this.surfaces.length; s++) n += this.surfaces[s].triangleCount();
        return n;
    }
}

// MultiMesh (milestone 13): one mesh drawn many times, the properties of
// ../classdb.as as fields. `buffer` is Godot's layout exactly: per instance
// the 3D transform's rows (basis.rows[r].x, .y, .z, origin[r], for r = 0,
// 1, 2), then 4 colour numbers with `useColors`, then 4 of custom data with
// `useCustomData` (engine/src/render/instances.as packs it for the GPU).
// Numbers are f64 as read, so that a scene written back is the one read.
export class MultiMesh extends Resource {
    // 0 transform_2d, 1 transform_3d (only 3D is drawn).
    transformFormat: i32 = 0;
    useColors: bool = false;
    useCustomData: bool = false;
    instanceCount: i32 = 0;
    // -1: all.
    visibleInstanceCount: i32 = -1;
    mesh: Mesh? = null;
    buffer: Array<f64> = [];

    className(): string {
        return "MultiMesh";
    }

    // The numbers one instance takes in `buffer` (8 or 12, plus 4 for the
    // colour, plus 4 for the custom data).
    stride(): i32 {
        return (this.transformFormat == 1 ? 12 : 8) + (this.useColors ? 4 : 0) + (this.useCustomData ? 4 : 0);
    }
}

// Milestone 31: the collision shapes (docs/formats/RSCN.md, "Interaction";
// ../classdb.as has Godot's properties), sub_resources a CollisionShape3D
// names. Lengths in metres, in the shape's own space (the node's), centred
// on its origin, Y up. What the queries need beyond the fields (a convex
// hull's planes, a concave shape's BVH) is made on first use and kept in
// `prepared`, which ../interaction/prepared.as fills; a change of a field
// (the editor's handles, a script) calls `changed()`, which drops it.
//
// The kinds, for a switch (SHAPE_*; ../interaction/geometry.as reads them).
export const SHAPE_BOX: i32 = 0;
export const SHAPE_SPHERE: i32 = 1;
export const SHAPE_CAPSULE: i32 = 2;
export const SHAPE_CYLINDER: i32 = 3;
export const SHAPE_CONVEX: i32 = 4;
export const SHAPE_CONCAVE: i32 = 5;

// What a query keeps of a shape between calls (../interaction/prepared.as
// derives it; an abstract class here so that this file imports nothing of
// the interaction code).
export abstract class ShapePrepared {
    // The shape's `version` it was made for.
    version: i32 = -1;
}

export abstract class Shape3D extends Resource {
    margin: f64 = 0.04;
    // Bumped by changed(): what was prepared for an older version is made
    // again.
    version: i32 = 0;
    prepared: ShapePrepared? = null;

    abstract kind(): i32;

    // A field changed (the editor's live handle drag, a script): what was
    // prepared from the old fields is dropped.
    changed(): void {
        this.version++;
        this.prepared = null;
    }
}

export class BoxShape3D extends Shape3D {
    size: Vec3 = Vec3(1, 1, 1);

    className(): string {
        return "BoxShape3D";
    }

    kind(): i32 {
        return SHAPE_BOX;
    }
}

export class SphereShape3D extends Shape3D {
    radius: f64 = 0.5;

    className(): string {
        return "SphereShape3D";
    }

    kind(): i32 {
        return SHAPE_SPHERE;
    }
}

// Godot's capsule: `height` is the whole height, the caps included; under
// twice the radius, the radius is taken as half the height (Godot 4 clamps
// the same way), so the shape is a sphere then.
export class CapsuleShape3D extends Shape3D {
    radius: f64 = 0.5;
    height: f64 = 2;

    className(): string {
        return "CapsuleShape3D";
    }

    kind(): i32 {
        return SHAPE_CAPSULE;
    }

    // The radius the shape has (radius, or half the height when that is
    // less).
    effectiveRadius(): f64 {
        return min<f64>(this.radius, this.height * 0.5);
    }

    // Half the length of its cylinder, between the caps' centres (0 or
    // more).
    halfSegment(): f64 {
        return max<f64>(this.height * 0.5 - this.effectiveRadius(), 0);
    }
}

export class CylinderShape3D extends Shape3D {
    height: f64 = 2;
    radius: f64 = 0.5;

    className(): string {
        return "CylinderShape3D";
    }

    kind(): i32 {
        return SHAPE_CYLINDER;
    }
}

// `points`: x, y, z each, as read (a PackedVector3Array's numbers).
export class ConvexPolygonShape3D extends Shape3D {
    points: Array<f64> = [];

    className(): string {
        return "ConvexPolygonShape3D";
    }

    kind(): i32 {
        return SHAPE_CONVEX;
    }
}

// `data`: nine numbers a triangle (a, b, c), as read; the front face is
// clockwise seen from the front, as Godot winds it: its normal is
// normalize((c - a) x (b - a)).
export class ConcavePolygonShape3D extends Shape3D {
    data: Array<f64> = [];
    backfaceCollision: bool = false;

    className(): string {
        return "ConcavePolygonShape3D";
    }

    kind(): i32 {
        return SHAPE_CONCAVE;
    }

    // Whole triangles (a trailing partial one, which the validator
    // reports, is left out).
    triangleCount(): i32 {
        return this.data.length / 9;
    }
}

export enum ModelFormat {
    Modeler,
    Gltf,
}

// One object of a model, ready to become a node: the node class, its
// properties in the format's own terms, its transform relative to its
// parent object in scene space, and, for a mesh, the evaluated triangles
// (modifiers applied, in the object's own space, Y up).
export class ModelObject {
    name: string = "";
    // "Node3D" (an empty or an armature), "MeshInstance3D", "Camera3D",
    // "DirectionalLight3D", "OmniLight3D", "SpotLight3D".
    className: string = "Node3D";
    // Index of the parent object in ModelResource.objects, -1 at the top.
    parent: i32 = -1;
    local: Mat4 = MAT4_IDENTITY;
    // False for an object hidden in the model (it becomes an invisible node).
    visible: bool = true;
    mesh: ArrayMesh? = null;
    // Node properties the object sets (a camera's fov, a light's colour and
    // energy), pairwise, in the order they are applied.
    propNames: Array<string> = [];
    propValues: Array<Value> = [];
    // Milestone 48 (../skeleton/model_skin.as): an armature's bones (the
    // object becomes a Skeleton3D); a mesh's skin (its GpuMesh then holds
    // the mesh at bind time, with skinJoints and skinWeights, and the
    // armature's modifier is not applied to it); the bone of the skeleton
    // of its parent object that it follows ("" none: the object is a child
    // of a BoneAttachment3D named after the bone); a mesh's blend shapes
    // (its GpuMesh's morphs, in this order) and their weights as the file
    // sets them.
    skeleton: ModelSkeleton? = null;
    skin: ModelSkin? = null;
    parentBone: string = "";
    blendShapes: Array<string> = [];
    blendShapeWeights: Array<f32> = [];
}

// A model file (ext_resource type Model, or the model behind a PackedScene
// of a .gltf, .glb or .modeler file).
export class ModelResource extends Resource {
    format: ModelFormat = ModelFormat.Modeler;
    // The model the meshes in `objects` were evaluated from, as the tools
    // read it (milestone 40: ModelSource); null for a model from a built scene,
    // whose meshes are prebuilt.
    source: ModelSource? = null;
    // Parents before their children, siblings in the model's order.
    objects: Array<ModelObject> = [];
    // The model's materials (index = the shared model's material index).
    materials: Array<StandardMaterial3D> = [];
    // What loading it reported without failing (the glTF importer's
    // warnings, textures that could not be read).
    warnings: Array<string> = [];
    // An .rmdl's read warnings (content a rewrite of the document would
    // drop, a resource nothing names: docs/formats/RMDL.md, "Errors"), each
    // with its own code and its place in the model file, which the loader
    // reports as they are.
    readWarnings: Array<Diagnostic> = [];
    // Milestone 48: its animations (a glTF file's, an .rmdl's actions), in
    // the file's order, which a scene instancing it lists as read-only
    // LinearAnimations (../skeleton/clips.as).
    clips: Array<ModelClip> = [];

    className(): string {
        return "Model";
    }
}

// A scene to instance: an .rscn document, or a model whose objects become
// nodes.
export class PackedScene extends Resource {
    doc: RscnDoc? = null;
    model: ModelResource? = null;

    className(): string {
        return "PackedScene";
    }
}
