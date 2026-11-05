// Milestone 36: a sound, the resource an AudioStreamPlayer3D's `stream`
// names (../classdb.as AudioStream, AudioStreamWAV, AudioStreamMP3;
// docs/formats/RSCN.md "Audio", docs/engine/AUDIO.md). It holds what the
// sound is, never its samples: in a Rive project the bytes are a Rive
// AudioAsset the build declares (`assetName`), which the run time plays
// through the runtime's audio (../audio/rive_out.as); the tools read the
// file's header for its length and format (the source tier's reader,
// FileReaders.readAudioFile) and play nothing.
//
// Where its fields come from:
//
//   the tools        the source tier reads the file's header (format,
//                    rate, channels, length) and its .import (the loop and
//                    whether the import made the left and right forms);
//                    assetName stays "" (nothing plays)
//   text, in Rive    the loader is handed AUDIO_DECLARED_MARK in place of
//                    the bytes (the file is an AudioAsset, not a blob:
//                    ../runtime/scene_runtime.as ProjectFiles answers so);
//                    the length is the runtime's (AudioSource.duration, at
//                    the first play), the loop the .import's when the source
//                    tier is vendored; assetName from the file's place under
//                    the text root
//   built            the bundle's Audio entry (../bundle/audio.as), which
//                    the compiler writes from what the tools read, assetName
//                    included
//
// A player's left and right forms (the import's, for a WAV) are the Rive
// AudioAssets named assetName + AUDIO_LEFT_SUFFIX and AUDIO_RIGHT_SUFFIX:
// the run time pans with them when it finds them, and plays the stream
// centred otherwise.

import { toAsciiLowercase } from "../../base/util";
import { Resource } from "./types";

// The formats (what the bytes are, not the extension).
export const AUDIO_FORMAT_UNKNOWN: i32 = 0;
export const AUDIO_FORMAT_WAV: i32 = 1;
export const AUDIO_FORMAT_MP3: i32 = 2;
export const AUDIO_FORMAT_FLAC: i32 = 3;
export const AUDIO_FORMAT_NAMES: StaticArray<string> = ["unknown", "wav", "mp3", "flac"];

// Godot's AudioStreamWAV.LoopMode numbers (what the stream does at its
// end); an MP3's or FLAC's `loop` is LOOP_FORWARD from its loop_offset.
export const AUDIO_LOOP_DISABLED: i32 = 0;
export const AUDIO_LOOP_FORWARD: i32 = 1;
export const AUDIO_LOOP_PINGPONG: i32 = 2;
export const AUDIO_LOOP_BACKWARD: i32 = 3;
export const AUDIO_LOOP_NAMES: StaticArray<string> = ["disabled", "forward", "pingpong", "backward"];

// The suffixes of a stream's left and right forms' Rive asset names
// ("hedra:audio/sounds/hum.wav#left").
export const AUDIO_LEFT_SUFFIX = "#left";
export const AUDIO_RIGHT_SUFFIX = "#right";

// What a text source's file system answers for a declared audio file whose
// bytes it cannot hand over (the run time's ProjectFiles): the loader takes
// it for "a Rive AudioAsset, nothing to read".
export const AUDIO_DECLARED_TEXT = "HEDRA-AUDIO-ASSET\n";

// Where the text source puts a project's files (../runtime/scene_runtime.as
// TEXT_ROOT, "/hedra", and its slash; a test checks that they agree): a
// file at /hedra/<rive path> is the Rive asset "hedra:<rive path>".
export const AUDIO_TEXT_ROOT = "/hedra/";

export class AudioStream extends Resource {
    // The ext_resource's type: AudioStream, AudioStreamWAV or AudioStreamMP3.
    type: string = "AudioStream";
    format: i32 = AUDIO_FORMAT_UNKNOWN;
    // The length in seconds (-1 until known: a text scene in Rive learns it
    // from the runtime's AudioSource at its first play), the file's sample
    // rate, channels and length in sample frames (0 when not known).
    duration: f64 = -1;
    sampleRate: i32 = 0;
    channels: i32 = 0;
    frames: f64 = 0;
    // AUDIO_LOOP_*, and the loop's start and end in seconds (end -1: the
    // stream's end).
    loopMode: i32 = AUDIO_LOOP_DISABLED;
    loopBegin: f64 = 0;
    loopEnd: f64 = -1;
    // The import's loop begin in seconds when the reader found it at or
    // past the loop's end and took 0 instead (the `audio-loop-begin`
    // warning's); -1 when it did not. The tools' alone: a build writes the
    // begin it took.
    loopBeginDropped: f64 = -1;
    // Whether the import made the left and right forms (a WAV whose
    // .import keeps edit/panning_forms on): what inspect and the warnings
    // say; the run time looks the forms up whatever this says.
    panForms: bool = false;
    // The Rive asset the stream is ("hedra:audio/sounds/hum.wav"); "" when
    // none is known (the tools).
    assetName: string = "";

    className(): string {
        return this.type;
    }

    // Whether it loops.
    loops(): bool {
        return this.loopMode != AUDIO_LOOP_DISABLED;
    }
}

// The bytes of AUDIO_DECLARED_TEXT, made once.
let declaredBytes: Uint8Array? = null;

export function audioDeclaredMark(): Uint8Array {
    let b = declaredBytes;
    if (b == null) {
        b = Uint8Array.wrap(String.UTF8.encode(AUDIO_DECLARED_TEXT));
        declaredBytes = b;
    }
    return b;
}

// Whether `bytes` are the mark.
export function isAudioDeclaredMark(bytes: Uint8Array): bool {
    const m = audioDeclaredMark();
    if (bytes.length != m.length) return false;
    for (let i = 0; i < m.length; i++) if (bytes[i] != m[i]) return false;
    return true;
}

// Whether a path names an audio file the format takes (by its extension,
// any case).
export function isAudioPath(path: string): bool {
    const dot = path.lastIndexOf(".");
    if (dot < 0) return false;
    const e = toAsciiLowercase(path.substring(dot + 1));
    return e == "wav" || e == "mp3" || e == "flac";
}

// The Rive asset of a file the text source holds at `abs` ("" when it is
// not under the text root).
export function audioAssetOfTextPath(abs: string): string {
    if (!abs.startsWith(AUDIO_TEXT_ROOT)) return "";
    return "hedra:" + abs.substring(AUDIO_TEXT_ROOT.length);
}
