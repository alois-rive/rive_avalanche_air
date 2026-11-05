// Milestone 36: a built scene's Audio entry (./format.as AssetKind.Audio;
// docs/cli/BUILD.md section 17): what a sound is, so that a built scene in
// a Rive project knows its length and loop before the runtime's audio
// has played it, and which Rive AudioAsset it is. The samples are never
// here: they are the AudioAsset the build declares in hedra.rml (the
// file) and hedra.built.rml (its left and right forms). The compiler
// writes it (compiler/src/bundle/audio_write.as encodeAudioStream), from
// the stream the tools read; this reads it back.
//
//   u32 1                 the payload's version (./payload.as PAYLOAD_VERSION)
//   u32 format            AUDIO_FORMAT_* (../resource/audio_stream.as)
//   u32 sample rate       Hz
//   u32 channels
//   f64 frames            the length in sample frames
//   f64 duration          seconds
//   u32 loop mode         AUDIO_LOOP_*
//   f64 loop begin        seconds
//   f64 loop end          seconds, -1 the end
//   u32 flags             AUDIO_PAYLOAD_PAN_FORMS: the build declared the
//                         left and right forms
//   str type              AudioStream, AudioStreamWAV or AudioStreamMP3
//   str asset name        "hedra:<path in the Rive project>"
//
// (str: u32 byte length, then UTF-8, as every payload's.)

import { Result } from "../../base/util";
import { BinReader } from "../rscnb/bin";
import { AudioStream } from "../resource/audio_stream";
import { PAYLOAD_VERSION, readStr } from "./payload";

export const AUDIO_PAYLOAD_PAN_FORMS: u32 = 1;

export function decodeAudioStream(bytes: Uint8Array, what: string): Result<AudioStream> {
    const r = new BinReader(bytes);
    const v = r.u32();
    if (!r.failed && v != PAYLOAD_VERSION) r.fail(what + " version " + v.toString() + " is not " + PAYLOAD_VERSION.toString());
    const a = new AudioStream();
    a.format = <i32>r.u32();
    a.sampleRate = <i32>r.u32();
    a.channels = <i32>r.u32();
    a.frames = r.f64();
    a.duration = r.f64();
    a.loopMode = <i32>r.u32();
    a.loopBegin = r.f64();
    a.loopEnd = r.f64();
    const flags = r.u32();
    a.panForms = (flags & AUDIO_PAYLOAD_PAN_FORMS) != 0;
    a.type = readStr(r);
    a.assetName = readStr(r);
    if (!r.failed && r.pos != r.size) r.fail(what + " has " + r.remaining().toString() + " bytes after its end");
    if (r.failed) return Result.fail<AudioStream>(what + ": " + r.why);
    return Result.okv<AudioStream>(a);
}
