// The source tier's reader of a sound (an AudioStream ext_resource: a
// .wav, .mp3 or .flac file), which the tools' FileReaders.readAudioFile
// calls (../scene/resource/readers.as): what the file is, from its header
// (./info.as: format, rate, channels, length), and how it plays, from the
// .import beside it (../import/sidecar.as), Godot's import settings:
//
//   wav    edit/loop_mode: detect (the file's first smpl loop, else none),
//          disabled, forward, pingpong, backward (AUDIO_LOOP_*: ping-pong
//          and backward are kept, and play forward); edit/loop_begin and
//          edit/loop_end in sample frames, a negative one counted from the
//          end as Godot counts it (-1 the end), clamped to the file, turned
//          into seconds; edit/panning_forms: whether the build makes the
//          left and right forms that pan it (panForms: the setting, so that
//          a WAV not yet imported is the panned stream a build will make
//          it; a build's Audio entry says whether the forms were declared)
//   mp3,   loop (forward from loop_offset, seconds) or not
//   flac
//
// A file without an .import plays as the defaults say (a WAV: detect, its
// forms on; an MP3 or FLAC: once). An .import of another importer (the
// file renamed from another kind) counts as none, as the importer takes it.
//
// At run time in a Rive project the bytes are not there (the file is a
// Rive AudioAsset: `bytes` is null): the .import alone is read, its
// [remap] metadata giving the loop the import resolved (a WAV's
// metadata/loop_mode, loop_begin and loop_end, in seconds: there is no
// smpl chunk to read and no rate to turn frames into seconds), its
// [params] otherwise (a loop it cannot place without the rate plays from
// the start to the end); the length is the runtime's (-1 here).
//
// A loop whose begin is at or past its end loops from 0 (Godot's MP3 and
// Ogg streams' rule; the stream keeps the begin it dropped for the
// `audio-loop-begin` warning).
//
// Errors: bytes that are no WAV, MP3 or FLAC are audio-invalid, at the
// file; an .import that does not parse is import-invalid at it, in the
// tools (at run time it is passed over: the stream plays its defaults).

import { Result } from "../../base/util";
import { parseF64 } from "../../base/parse";
import { IoErrorKind, ioErrorOf, vfs } from "../../fs/vfs";
import { SceneryError } from "../../scene/error";
import { Resource } from "../../scene/resource/types";
import {
    AUDIO_FORMAT_WAV, AUDIO_LOOP_BACKWARD, AUDIO_LOOP_DISABLED, AUDIO_LOOP_FORWARD, AUDIO_LOOP_PINGPONG, AudioStream,
} from "../../scene/resource/audio_stream";
import { ImportFile, importPathOf, parseImportFile } from "../import/sidecar";
import {
    AudioImportParams, WAV_IMPORTER, WAV_LOOP_BACKWARD, WAV_LOOP_DETECT, WAV_LOOP_DISABLED, WAV_LOOP_FORWARD, WAV_LOOP_PINGPONG,
    importerOf, isAudioImporter, numberText,
} from "../import/params";
import { AudioInfo, readAudioInfo } from "./info";

export const AUDIO_INVALID_CODE = "audio-invalid";
export const AUDIO_INVALID_HINT = "a sound is a WAV (PCM or float), MP3 or FLAC file, which the Rive runtime decodes: "
    + "convert it to one of those";
const IMPORT_INVALID_CODE = "import-invalid";
const IMPORT_INVALID_HINT = "fix that line, or delete the .import file to start again from the defaults "
    + "(docs/formats/IMPORT.md, \"The .import file\")";

// The cache suffixes of a WAV's left and right forms
// (`<file>-<key>.left.wav`: compiler/src/import/importer.as).
export const AUDIO_LEFT_FORM_SUFFIX = "left.wav";
export const AUDIO_RIGHT_FORM_SUFFIX = "right.wav";

// The [remap] metadata keys a WAV's import writes (what the loop resolved
// to: AUDIO_LOOP_*, and its begin and end in seconds, -1 the end).
export const META_LOOP_MODE = "loop_mode";
export const META_LOOP_BEGIN = "loop_begin";
export const META_LOOP_END = "loop_end";

// A stream's loop as the import resolves it: AUDIO_LOOP_*, and its begin
// and end in sample frames (end -1: the end of the file).
export class AudioLoop {
    mode: i32 = AUDIO_LOOP_DISABLED;
    beginFrames: f64 = 0;
    endFrames: f64 = -1;
    // The begin the settings or the smpl chunk gave, in frames, when it was
    // at or past the loop's end and 0 was taken instead; -1 when it was not.
    droppedBeginFrames: f64 = -1;

    // The begin in seconds at `rate`.
    beginSeconds(rate: i32): f64 {
        return rate > 0 ? this.beginFrames / <f64>rate : 0;
    }

    // The end in seconds at `rate` (-1: the end).
    endSeconds(rate: i32): f64 {
        return this.endFrames < 0 || rate <= 0 ? -1 : this.endFrames / <f64>rate;
    }

    // The frame a looping stream's forms stop at: its loop's end when that
    // is inside the file, else -1 (the whole file; and a stream that does
    // not loop plays whole).
    trimFrames(frames: f64): f64 {
        if (this.mode == AUDIO_LOOP_DISABLED || this.endFrames < 0) return -1;
        return this.endFrames > 0 && this.endFrames < frames ? this.endFrames : -1;
    }
}

// A frame setting as Godot's importer takes it: negative from the end (-1
// the last frame's end), clamped to the file.
function framesIn(v: i64, frames: f64): f64 {
    let f = <f64>v;
    if (f < 0) f = f + frames + 1;
    if (f < 0) f = 0;
    if (f > frames) f = frames;
    return f;
}

// The loop of a WAV of `info` imported with `p` (Godot's
// ResourceImporterWAV): detect reads the file's smpl loop (none: it plays
// once), disabled none, forward, ping-pong and backward the settings'
// frames. An end at the file's end is -1.
export function wavLoopOf(info: AudioInfo, p: AudioImportParams): AudioLoop {
    const l = new AudioLoop();
    const frames = info.frames;
    if (p.loopMode == WAV_LOOP_DETECT) {
        if (info.smplLoopMode != AUDIO_LOOP_DISABLED) {
            l.mode = info.smplLoopMode;
            l.beginFrames = Math.min(Math.max(info.smplLoopBegin, 0), frames);
            l.endFrames = Math.min(Math.max(info.smplLoopEnd, 0), frames);
        }
    } else if (p.loopMode != WAV_LOOP_DISABLED) {
        l.mode = loopModeOf(p.loopMode);
        l.beginFrames = framesIn(p.loopBegin, frames);
        l.endFrames = framesIn(p.loopEnd, frames);
    }
    if (l.endFrames >= frames) l.endFrames = -1;
    // A begin at or past the end (loop_begin -1, one past loop_end, or a
    // smpl loop whose start is not before its end) would start a pass every
    // frame and never end: it loops from 0 instead, as Godot's MP3 and Ogg
    // streams do with a loop_offset past their end; and a loop left with
    // no length (an end at 0) plays the whole file.
    const end = l.endFrames < 0 ? frames : l.endFrames;
    if (l.mode != AUDIO_LOOP_DISABLED && frames > 0 && l.beginFrames >= end) {
        l.droppedBeginFrames = l.beginFrames;
        l.beginFrames = 0;
        if (end <= 0) l.endFrames = -1;
    }
    return l;
}

// AUDIO_LOOP_* of an explicit edit/loop_mode (forward, pingpong, backward).
function loopModeOf(wavMode: i32): i32 {
    if (wavMode == WAV_LOOP_FORWARD) return AUDIO_LOOP_FORWARD;
    if (wavMode == WAV_LOOP_PINGPONG) return AUDIO_LOOP_PINGPONG;
    if (wavMode == WAV_LOOP_BACKWARD) return AUDIO_LOOP_BACKWARD;
    return AUDIO_LOOP_DISABLED;
}

// Records in `f`'s [remap] what a WAV's loop resolved to (see the header):
// the mode, and its begin and end in seconds at `rate`.
export function setLoopMetadata(f: ImportFile, loop: AudioLoop, rate: i32): void {
    f.setMeta(META_LOOP_MODE, loop.mode.toString());
    f.setMeta(META_LOOP_BEGIN, numberText(loop.beginSeconds(rate)));
    f.setMeta(META_LOOP_END, numberText(loop.endSeconds(rate)));
}

function metaNumber(f: ImportFile, key: string, fallback: f64): f64 {
    const v = f.meta(key);
    if (v == null) return fallback;
    const n = parseF64(v!);
    return n.ok && isFinite(n.value) ? n.value : fallback;
}

// The .import beside the sound at `abs`: null when there is none (or one
// of another importer); a failure (import-invalid, at it) for one that
// cannot be read or does not parse, unless `lenient` (run time).
function readSidecar(abs: string, display: string, importer: string, lenient: bool): Result<ImportFile?> {
    const ip = importPathOf(abs);
    const shown = importPathOf(display);
    const r = vfs.read(ip);
    if (!r.ok) {
        const e = ioErrorOf<Uint8Array>(r);
        if (lenient || (e != null && e.kind == IoErrorKind.NotFound)) return Result.okv<ImportFile?>(null);
        return SceneryError.at(IMPORT_INVALID_CODE, shown, 0, 0, "cannot read " + shown + ": " + r.err,
            "check that the file can be read").fail<ImportFile?>();
    }
    const b = r.value;
    const text = String.UTF8.decode(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
    const p = parseImportFile(text, shown);
    if (!p.ok) {
        if (lenient) return Result.okv<ImportFile?>(null);
        // (parseImportFile says "<file>:<line>: <why>": the file and the
        // line are the error's place, the why its message)
        let line = 0;
        let why = p.err;
        if (p.err.startsWith(shown + ":")) {
            const rest = p.err.substring(shown.length + 1);
            const colon = rest.indexOf(": ");
            const n = parseF64(rest.substring(0, max<i32>(0, colon)));
            if (n.ok && colon > 0) {
                line = <i32>n.value;
                why = rest.substring(colon + 2);
            }
        }
        return SceneryError.at(IMPORT_INVALID_CODE, shown, line, 0, why, IMPORT_INVALID_HINT).fail<ImportFile?>();
    }
    if (p.value.importer != importer) return Result.okv<ImportFile?>(null);
    return Result.okv<ImportFile?>(p.value);
}

// The AudioStream of the sound at `abs` (shown as `display`), an
// ext_resource of `type` (AudioStream, AudioStreamWAV, AudioStreamMP3),
// whose bytes are `bytes` (null: a Rive AudioAsset at run time). See the
// header.
export function readAudioSource(abs: string, display: string, type: string, bytes: Uint8Array?): Result<Resource> {
    const a = new AudioStream();
    a.type = type;
    let info: AudioInfo? = null;
    if (bytes != null) {
        const r = readAudioInfo(bytes);
        if (!r.ok) {
            return SceneryError.at(AUDIO_INVALID_CODE, display, 0, 0, display + " is not a WAV, MP3 or FLAC file: " + r.err,
                AUDIO_INVALID_HINT).fail<Resource>();
        }
        const i = r.value;
        info = i;
        a.format = i.format;
        a.sampleRate = i.sampleRate;
        a.channels = i.channels;
        a.frames = i.frames;
        a.duration = i.duration;
    }
    const imp = importerOf(abs);
    if (imp == null || !isAudioImporter(imp)) return Result.okv<Resource>(a);
    const s = readSidecar(abs, display, imp, bytes == null);
    if (!s.ok) return s.forward<Resource>();
    const file = s.value;
    const params = file != null ? AudioImportParams.from(file.params) : new AudioImportParams();
    if (imp == WAV_IMPORTER) {
        // (a .wav whose bytes are another format has no forms to make)
        a.panForms = params.panningForms && (info == null || info.format == AUDIO_FORMAT_WAV);
        if (info != null) {
            const loop = wavLoopOf(info, params);
            a.loopMode = loop.mode;
            a.loopBegin = loop.beginSeconds(info.sampleRate);
            a.loopEnd = loop.endSeconds(info.sampleRate);
            if (loop.droppedBeginFrames >= 0 && info.sampleRate > 0) {
                a.loopBeginDropped = loop.droppedBeginFrames / <f64>info.sampleRate;
            }
        } else if (file != null && file.meta(META_LOOP_MODE) != null) {
            const m = <i32>metaNumber(file, META_LOOP_MODE, 0);
            a.loopMode = m >= AUDIO_LOOP_DISABLED && m <= AUDIO_LOOP_BACKWARD ? m : AUDIO_LOOP_DISABLED;
            a.loopBegin = Math.max(0, metaNumber(file, META_LOOP_BEGIN, 0));
            a.loopEnd = metaNumber(file, META_LOOP_END, -1);
            if (a.loopEnd < 0) a.loopEnd = -1;
        } else if (params.loopMode != WAV_LOOP_DETECT && params.loopMode != WAV_LOOP_DISABLED) {
            // (no rate to place frames by: the whole file)
            a.loopMode = loopModeOf(params.loopMode);
        }
    } else if (params.loop) {
        a.loopMode = AUDIO_LOOP_FORWARD;
        a.loopBegin = params.loopOffset;
        a.loopEnd = -1;
        // (a loop_offset at or past the end loops from 0: Godot's seek
        // there goes to 0)
        if (a.duration > 0 && a.loopBegin >= a.duration) {
            a.loopBeginDropped = a.loopBegin;
            a.loopBegin = 0;
        }
    }
    return Result.okv<Resource>(a);
}

