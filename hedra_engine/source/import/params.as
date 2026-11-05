// Milestone 26: the import settings, Godot's `[params]` of an `.import`
// file (sidecar.as), for the importers: "texture" (PNG images, Godot's
// ResourceImporterTexture, type CompressedTexture2D) and "scene" (models:
// .rmdl, .rmdlcmd, .gltf, .glb; Godot's ResourceImporterScene, type PackedScene);
// milestone 36, the sounds': "wav" (Godot's ResourceImporterWAV, type
// AudioStreamWAV), "mp3" (Godot's ResourceImporterMP3, type AudioStreamMP3)
// and "flac" (ours: Godot imports no FLAC, the Rive runtime decodes it; type
// AudioStream, with the MP3 importer's loop settings).
// Keys and enum numbers are Godot 4's where Godot has the setting, so a
// Godot user reads them as they are; the few that are ours say so.
// docs/formats/IMPORT.md lists them with what each does; the tables below
// are the truth the parser, the writer, the CLI's `import --set`, the
// answer and the editors' Import dock read.
//
// Values are kept as their canonical text (`ImportParams`), as the file
// holds them: a bool `true`/`false`, an int in decimal, a float as
// hedra_engine/base/fmt prints it (shortest round trip), an enum as its number.
// `TextureImportParams` and `ModelImportParams` are the typed views the
// importers use.

import { Result, toAsciiLowercase } from "../../base/util";
import { parseF64 } from "../../base/parse";
import { CLI } from "../../base/names";
import { isModelFilePath } from "../model/formats";

export const TEXTURE_IMPORTER = "texture";
export const MODEL_IMPORTER = "scene";
export const WAV_IMPORTER = "wav";
export const MP3_IMPORTER = "mp3";
export const FLAC_IMPORTER = "flac";

// Every importer, in the order the hints and the docs list them.
export const IMPORTERS: StaticArray<string> = [TEXTURE_IMPORTER, MODEL_IMPORTER, WAV_IMPORTER, MP3_IMPORTER, FLAC_IMPORTER];

// Whether `importer` is one of the sounds' (wav, mp3, flac).
export function isAudioImporter(importer: string): bool {
    return importer == WAV_IMPORTER || importer == MP3_IMPORTER || importer == FLAC_IMPORTER;
}

// The importer of a path by its extension (any case): "texture" for .png,
// "scene" for a model file (.rmdl, .rmdlcmd, .gltf, .glb:
// ../model/formats.as), "wav", "mp3" and "flac" for the sounds of those
// extensions, null for anything else (an .hdr, a
// panorama or lightmap layer, stays as it is: no importer). It lives with
// the settings rather than with the import itself (compiler/src/import/
// importer.as, which re-exports it) because reading a source asks it too:
// whether a file has an `.import` beside it (engine/src/source/closure.as).
export function importerOf(path: string): string? {
    const lower = toAsciiLowercase(path);
    if (lower.endsWith(".png")) return TEXTURE_IMPORTER;
    if (isModelFilePath(path)) return MODEL_IMPORTER;
    if (lower.endsWith(".wav")) return WAV_IMPORTER;
    if (lower.endsWith(".mp3")) return MP3_IMPORTER;
    if (lower.endsWith(".flac")) return FLAC_IMPORTER;
    return null;
}

export enum ParamKind {
    Bool = 0,
    Int = 1,
    Float = 2,
    // An int naming one of `choices` (its index).
    Enum = 3,
}

export class ParamDef {
    key: string;
    kind: ParamKind;
    // The default as canonical text.
    def: string;
    // An Enum's names, by number (the Import dock's drop-down, the answer's
    // `names`); empty for other kinds.
    choices: Array<string>;
    // The inclusive range of an Int or Float.
    min: f64;
    max: f64;
    // What the Import dock's tooltip and the CLI's `import --help` say.
    help: string;
    // Enum numbers that exist in Godot but that this version does not do
    // (refused with a hint when set).
    unsupported: Array<i32> = [];

    constructor(key: string, kind: ParamKind, def: string, choices: Array<string>, min: f64, max: f64, help: string) {
        this.key = key;
        this.kind = kind;
        this.def = def;
        this.choices = choices;
        this.min = min;
        this.max = max;
        this.help = help;
    }
}

function b(key: string, def: bool, help: string): ParamDef {
    return new ParamDef(key, ParamKind.Bool, def ? "true" : "false", [], 0, 1, help);
}

function i(key: string, def: i32, min: f64, max: f64, help: string): ParamDef {
    return new ParamDef(key, ParamKind.Int, def.toString(), [], min, max, help);
}

function f(key: string, def: string, min: f64, max: f64, help: string): ParamDef {
    return new ParamDef(key, ParamKind.Float, def, [], min, max, help);
}

function e(key: string, def: i32, choices: Array<string>, help: string): ParamDef {
    return new ParamDef(key, ParamKind.Enum, def.toString(), choices, 0, <f64>(choices.length - 1), help);
}

// compress/mode's numbers (Godot's CompressMode).
export const COMPRESS_LOSSLESS: i32 = 0;
export const COMPRESS_LOSSY: i32 = 1;
export const COMPRESS_VRAM_COMPRESSED: i32 = 2;
export const COMPRESS_VRAM_UNCOMPRESSED: i32 = 3;
export const COMPRESS_BASIS_UNIVERSAL: i32 = 4;

// compress/normal_map's and process/srgb's numbers.
export const NORMAL_MAP_DETECT: i32 = 0;
export const NORMAL_MAP_ENABLE: i32 = 1;
export const NORMAL_MAP_DISABLE: i32 = 2;
export const SRGB_DISABLE: i32 = 0;
export const SRGB_ENABLE: i32 = 1;
export const SRGB_DETECT: i32 = 2;

// nodes/up_axis's and meshes/light_baking's numbers.
export const UP_AXIS_AUTO: i32 = 0;
export const UP_AXIS_Y: i32 = 1;
export const UP_AXIS_Z: i32 = 2;
export const LIGHT_BAKING_DISABLED: i32 = 0;
export const LIGHT_BAKING_STATIC: i32 = 1;
export const LIGHT_BAKING_STATIC_LIGHTMAPS: i32 = 2;
export const LIGHT_BAKING_DYNAMIC: i32 = 3;

// edit/loop_mode's numbers (Godot's ResourceImporterWAV: AudioStreamWAV's
// LoopMode plus one, 0 detecting it from the file's smpl chunk).
export const WAV_LOOP_DETECT: i32 = 0;
export const WAV_LOOP_DISABLED: i32 = 1;
export const WAV_LOOP_FORWARD: i32 = 2;
export const WAV_LOOP_PINGPONG: i32 = 3;
export const WAV_LOOP_BACKWARD: i32 = 4;

let textureDefs: Array<ParamDef>? = null;
let modelDefs: Array<ParamDef>? = null;
let wavDefs: Array<ParamDef>? = null;
let streamDefs: Array<ParamDef>? = null;

// The texture importer's settings, in the order the file and the dock
// list them.
export function textureParamDefs(): Array<ParamDef> {
    let t = textureDefs;
    if (t != null) return t;
    t = [];
    const mode = e("compress/mode", COMPRESS_VRAM_COMPRESSED,
        ["lossless", "lossy", "vram_compressed", "vram_uncompressed", "basis_universal"],
        "How the texture is stored in a built scene: lossless keeps the PNG, vram_compressed the GPU's block formats "
        + "(the forms `" + CLI + " build --target` chooses from: bc, etc2, astc), vram_uncompressed RGBA8 with its mipmaps");
    // Lossy is Godot's WebP and Basis Universal its supercompressed form:
    // neither has a decoder in the pinned runtime (docs/milestones/M26.md).
    mode.unsupported = [COMPRESS_LOSSY, COMPRESS_BASIS_UNIVERSAL];
    t.push(mode);
    t.push(b("compress/high_quality", false,
        "BC7 and ASTC 4x4 instead of BC1/BC3 and ASTC 6x6: twice the bytes, closer to the source"));
    t.push(e("compress/normal_map", NORMAL_MAP_DETECT, ["detect", "enable", "disable"],
        "A normal map is compressed in the high-quality formats, with linear error and renormalised mipmaps; detect: "
        + "a texture a material uses in its normal slot"));
    t.push(b("mipmaps/generate", true, "Store the mip chain (halved, box-filtered) with the texture"));
    t.push(i("mipmaps/limit", -1, -1, 16, "The most mip levels below level 0 (-1: down to 1 x 1)"));
    t.push(b("process/fix_alpha_border", true,
        "Give fully transparent texels their opaque neighbours' colour, so filtering shows no dark fringe"));
    t.push(b("process/premult_alpha", false, "Multiply colour by alpha before storing"));
    t.push(b("process/normal_map_invert_y", false, "Flip a normal map's green channel (DirectX to OpenGL convention)"));
    t.push(i("process/size_limit", 0, 0, 16384, "Downscale so that neither side exceeds this many texels (0: no limit)"));
    // Ours (Godot 3's flags/srgb): whether the texels are sRGB-encoded
    // colour, which weights the encoder's error and labels the KTX2.
    t.push(e("process/srgb", SRGB_DETECT, ["disable", "enable", "detect"],
        "Whether the texels are sRGB colour (perceptual error, *_SRGB formats); detect: as the material slot that "
        + "uses it says (colour slots sRGB, data slots linear)"));
    textureDefs = t;
    return t;
}

// The model importer's settings.
export function modelParamDefs(): Array<ParamDef> {
    let t = modelDefs;
    if (t != null) return t;
    t = [];
    t.push(f("nodes/root_scale", "1", 0.0001, 10000, "Scale the whole model by this"));
    // Ours (Blender's importers' up axis): the axis the file calls up.
    t.push(e("nodes/up_axis", UP_AXIS_AUTO, ["auto", "y", "z"],
        "The axis the file treats as up; auto: the format's own (glTF +Y, .rmdl +Z)"));
    t.push(b("meshes/generate_lods", true, "Generate levels of detail, drawn smaller on screen with fewer triangles"));
    t.push(b("meshes/force_disable_compression", false,
        "Store the meshes in a built scene uncompressed (by default quantised and meshopt-coded)"));
    t.push(e("meshes/light_baking", LIGHT_BAKING_STATIC, ["disabled", "static", "static_lightmaps", "dynamic"],
        "How the model's meshes take part in baked lighting (the bake's gi_mode for its nodes): disabled leaves them "
        + "out, static and static_lightmaps bake them, dynamic lights them from the probes"));
    modelDefs = t;
    return t;
}

// The WAV importer's settings: Godot 4.4's edit/ keys (its force/*,
// edit/trim, edit/normalize and compress/mode are not Hedra's: an .import
// that sets them keeps them as unknown keys, written back), and one of
// ours.
export function wavParamDefs(): Array<ParamDef> {
    let t = wavDefs;
    if (t != null) return t;
    t = [];
    t.push(e("edit/loop_mode", WAV_LOOP_DETECT, ["detect", "disabled", "forward", "pingpong", "backward"],
        "Whether the sound loops at its end; detect: as the file's smpl chunk says (none: it plays once). Ping-pong and "
        + "backward play forward (the runtime plays forward only)"));
    t.push(i("edit/loop_begin", 0, -2147483648, 2147483647,
        "The loop's first sample frame when edit/loop_mode is forward, pingpong or backward (negative: from the end, -1 the end)"));
    t.push(i("edit/loop_end", -1, -2147483648, 2147483647,
        "The frame the loop goes back from (-1: the end); inside the file, the left and right forms stop there"));
    // Ours: the forms a build declares beside the file, which pan it.
    t.push(b("edit/panning_forms", true,
        "Make the left and right forms a built project pans the sound with (twice the stereo size of the file); off: it "
        + "plays centred"));
    wavDefs = t;
    return t;
}

// The MP3 importer's settings (Godot 4.4's loop and loop_offset; its bpm,
// beat_count and bar_beats are unknown keys here), which the FLAC
// importer takes as they are.
export function streamParamDefs(): Array<ParamDef> {
    let t = streamDefs;
    if (t != null) return t;
    t = [];
    t.push(b("loop", false, "Whether the sound loops at its end, from loop_offset"));
    t.push(f("loop_offset", "0", 0, 86400, "Where a loop starts again, in seconds"));
    streamDefs = t;
    return t;
}

// The definitions of `importer`'s settings, or null for an unknown one.
export function paramDefsOf(importer: string): Array<ParamDef>? {
    if (importer == TEXTURE_IMPORTER) return textureParamDefs();
    if (importer == MODEL_IMPORTER) return modelParamDefs();
    if (importer == WAV_IMPORTER) return wavParamDefs();
    if (importer == MP3_IMPORTER || importer == FLAC_IMPORTER) return streamParamDefs();
    return null;
}

export function findDef(defs: Array<ParamDef>, key: string): ParamDef? {
    for (let k = 0; k < defs.length; k++) if (defs[k].key == key) return defs[k];
    return null;
}

// The canonical text of `text` as `d`'s value, or why it is not one (an
// Enum takes its number or its name; a Bool true, false, 1 or 0).
export function canonicalValue(d: ParamDef, text: string): Result<string> {
    const t = text.trim();
    if (d.kind == ParamKind.Bool) {
        if (t == "true" || t == "1") return Result.okv<string>("true");
        if (t == "false" || t == "0") return Result.okv<string>("false");
        return Result.fail<string>(d.key + " is true or false, not '" + text + "'");
    }
    if (d.kind == ParamKind.Enum) {
        for (let k = 0; k < d.choices.length; k++) {
            if (d.choices[k] == t || k.toString() == t) {
                if (d.unsupported.includes(k)) {
                    return Result.fail<string>(d.key + " " + d.choices[k] + " is not supported by this version");
                }
                return Result.okv<string>(k.toString());
            }
        }
        return Result.fail<string>(d.key + " is one of " + d.choices.join(", ") + " (or its number), not '" + text + "'");
    }
    const v = parseF64(t);
    if (!v.ok || isNaN(v.value) || !isFinite(v.value)) {
        return Result.fail<string>(d.key + " is a number, not '" + text + "'");
    }
    if (d.kind == ParamKind.Int && v.value != Math.floor(v.value)) {
        return Result.fail<string>(d.key + " is a whole number, not '" + text + "'");
    }
    if (v.value < d.min || v.value > d.max) {
        return Result.fail<string>(d.key + " is from " + numberText(d.min) + " to " + numberText(d.max) + ", not '" + text + "'");
    }
    if (d.kind == ParamKind.Int) return Result.okv<string>((<i64>v.value).toString());
    return Result.okv<string>(numberText(v.value));
}

// A float's canonical text: an integer value without a fraction ("1"),
// else the shortest text that reads back to the same f64.
export function numberText(v: f64): string {
    if (v == Math.floor(v) && Math.abs(v) < 1e15) return (<i64>v).toString();
    return v.toString();
}

// One importer's settings as text, every key of its definitions present,
// in their order.
export class ImportParams {
    importer: string;
    keys: Array<string> = [];
    values: Array<string> = [];

    constructor(importer: string) {
        this.importer = importer;
    }

    // Every setting at its default.
    static defaults(importer: string): ImportParams {
        const p = new ImportParams(importer);
        const defs = paramDefsOf(importer);
        if (defs != null) {
            for (let k = 0; k < defs.length; k++) {
                p.keys.push(defs[k].key);
                p.values.push(defs[k].def);
            }
        }
        return p;
    }

    get(key: string): string? {
        for (let k = 0; k < this.keys.length; k++) if (this.keys[k] == key) return this.values[k];
        return null;
    }

    // Sets `key` to `text` (canonicalised), or says why not (an unknown
    // key, a value that is not one of its kind).
    set(key: string, text: string): Result<bool> {
        const defs = paramDefsOf(this.importer);
        if (defs == null) return Result.fail<bool>("unknown importer '" + this.importer + "'");
        const d = findDef(defs, key);
        if (d == null) return Result.fail<bool>("unknown setting '" + key + "' for the " + this.importer + " importer");
        const v = canonicalValue(d, text);
        if (!v.ok) return v.forward<bool>();
        for (let k = 0; k < this.keys.length; k++) {
            if (this.keys[k] == key) {
                this.values[k] = v.value;
                return Result.okv<bool>(true);
            }
        }
        this.keys.push(key);
        this.values.push(v.value);
        return Result.okv<bool>(true);
    }

    getBool(key: string): bool {
        const v = this.get(key);
        return v != null && v == "true";
    }

    getInt(key: string): i32 {
        const v = this.get(key);
        if (v == null) return 0;
        const n = parseF64(v);
        return n.ok ? <i32>n.value : 0;
    }

    getFloat(key: string): f64 {
        const v = this.get(key);
        if (v == null) return 0;
        const n = parseF64(v);
        return n.ok ? n.value : 0;
    }

    // The text the cache key hashes: "key=value\n" for every setting, in
    // the definitions' order (an unknown importer's keys as they are).
    keyText(): string {
        let s = this.importer + "\n";
        for (let k = 0; k < this.keys.length; k++) s += this.keys[k] + "=" + this.values[k] + "\n";
        return s;
    }

    clone(): ImportParams {
        const p = new ImportParams(this.importer);
        for (let k = 0; k < this.keys.length; k++) {
            p.keys.push(this.keys[k]);
            p.values.push(this.values[k]);
        }
        return p;
    }
}

// The texture importer's settings, typed.
export class TextureImportParams {
    mode: i32 = COMPRESS_VRAM_COMPRESSED;
    highQuality: bool = false;
    normalMap: i32 = NORMAL_MAP_DETECT;
    mipmaps: bool = true;
    mipmapLimit: i32 = -1;
    fixAlphaBorder: bool = true;
    premultAlpha: bool = false;
    normalMapInvertY: bool = false;
    sizeLimit: i32 = 0;
    srgb: i32 = SRGB_DETECT;

    static from(p: ImportParams): TextureImportParams {
        const t = new TextureImportParams();
        t.mode = p.getInt("compress/mode");
        t.highQuality = p.getBool("compress/high_quality");
        t.normalMap = p.getInt("compress/normal_map");
        t.mipmaps = p.getBool("mipmaps/generate");
        t.mipmapLimit = p.getInt("mipmaps/limit");
        t.fixAlphaBorder = p.getBool("process/fix_alpha_border");
        t.premultAlpha = p.getBool("process/premult_alpha");
        t.normalMapInvertY = p.getBool("process/normal_map_invert_y");
        t.sizeLimit = p.getInt("process/size_limit");
        t.srgb = p.getInt("process/srgb");
        return t;
    }
}

// The model importer's settings, typed.
export class ModelImportParams {
    rootScale: f64 = 1;
    upAxis: i32 = UP_AXIS_AUTO;
    generateLods: bool = true;
    compressMeshes: bool = true;
    lightBaking: i32 = LIGHT_BAKING_STATIC;

    static from(p: ImportParams): ModelImportParams {
        const m = new ModelImportParams();
        m.rootScale = p.getFloat("nodes/root_scale");
        m.upAxis = p.getInt("nodes/up_axis");
        m.generateLods = p.getBool("meshes/generate_lods");
        m.compressMeshes = !p.getBool("meshes/force_disable_compression");
        m.lightBaking = p.getInt("meshes/light_baking");
        return m;
    }

    // Whether every setting is its default (the loader then changes
    // nothing: every scene that names no .import loads as before).
    isDefault(): bool {
        return this.rootScale == 1 && this.upAxis == UP_AXIS_AUTO && this.generateLods && this.compressMeshes
            && this.lightBaking == LIGHT_BAKING_STATIC;
    }
}

// A sound's import settings, typed: a WAV's (wav) or an MP3's or FLAC's
// (mp3, flac) as they apply (the others' left at their defaults).
export class AudioImportParams {
    // WAV: edit/loop_mode (WAV_LOOP_*), edit/loop_begin, edit/loop_end in
    // sample frames, edit/panning_forms.
    loopMode: i32 = WAV_LOOP_DETECT;
    loopBegin: i64 = 0;
    loopEnd: i64 = -1;
    panningForms: bool = true;
    // MP3, FLAC: loop and loop_offset (seconds).
    loop: bool = false;
    loopOffset: f64 = 0;

    static from(p: ImportParams): AudioImportParams {
        const a = new AudioImportParams();
        if (p.importer == WAV_IMPORTER) {
            a.loopMode = p.getInt("edit/loop_mode");
            a.loopBegin = <i64>p.getFloat("edit/loop_begin");
            a.loopEnd = <i64>p.getFloat("edit/loop_end");
            a.panningForms = p.getBool("edit/panning_forms");
        } else {
            a.loop = p.getBool("loop");
            a.loopOffset = p.getFloat("loop_offset");
        }
        return a;
    }
}
