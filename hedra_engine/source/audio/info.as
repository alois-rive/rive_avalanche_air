// What a sound file is, read from its header and nothing more: the tools'
// side of an AudioStream (the run time never reads a sound's bytes: the
// Rive runtime decodes them, docs/engine/AUDIO.md). The pinned runtime
// decodes WAV, MP3 and FLAC (miniaudio's dr_wav, minimp3 and dr_flac) and
// tells them apart by their bytes, never by the extension, so this does
// too:
//
//   WAV   RIFF/WAVE: its `fmt ` chunk (PCM 1, IEEE float 3, or extensible
//         0xFFFE naming either; 8, 16, 24 or 32-bit PCM, 32 or 64-bit
//         float), its `data` chunk (the frames: data bytes / block align),
//         and the first loop of a `smpl` chunk (Godot's importer reads the
//         same one, as edit/loop_mode detect). Chunks of odd size are
//         padded to even, as RIFF says; unknown chunks are skipped; a data
//         chunk that claims more bytes than the file has (a stream never
//         finished) counts what is there.
//   FLAC  `fLaC`, then its STREAMINFO block: the rate, the channels, the
//         bits and the total samples (0 there: not known, duration -1).
//   MP3   any ID3v2 tags skipped, then MPEG 1, 2 or 2.5 Layer III frames
//         walked header to header, every complete frame counted until the
//         bytes stop being frames (an ID3v1 tag, the end). The length is
//         the runtime's own (its decoder is dr_mp3, gapless): a first frame
//         holding a Xing or Info tag is no audio and is not counted, and
//         when the tag carries LAME's extension its encoder delay and
//         padding are trimmed as dr_mp3 trims them (delay + 529 samples at
//         the start, padding - 529 at the end, at least 0). The fixture
//         hum.mp3: 23 frames, the first an Info tag, 22 x 576 - (576 + 529)
//         - (1,071 - 529) = 11,025 samples at 22,050 Hz = 0.5 s, what
//         AudioSource.duration says from rive master 0e1cc69671 on ("exact
//         mp3 lengths"; rive 1.6.0 to 1.8.0 counted every frame and trimmed
//         nothing: 0.6008163 s).
//
// Anything else fails with why (an Ogg file says it is Ogg, which the
// runtime cannot decode): the reader's audio-invalid
// (engine/src/source/audio/reader.as).

import { Result } from "../../base/util";
import { AUDIO_FORMAT_FLAC, AUDIO_FORMAT_MP3, AUDIO_FORMAT_UNKNOWN, AUDIO_FORMAT_WAV, AUDIO_LOOP_BACKWARD, AUDIO_LOOP_DISABLED,
    AUDIO_LOOP_FORWARD, AUDIO_LOOP_PINGPONG } from "../../scene/resource/audio_stream";

// WAV's fmt chunk format tags.
export const WAV_FORMAT_PCM: i32 = 1;
export const WAV_FORMAT_FLOAT: i32 = 3;
export const WAV_FORMAT_EXTENSIBLE: i32 = 0xFFFE;

export class AudioInfo {
    // AUDIO_FORMAT_* (../../scene/resource/audio_stream.as).
    format: i32 = AUDIO_FORMAT_UNKNOWN;
    sampleRate: i32 = 0;
    channels: i32 = 0;
    // The length in sample frames, and in seconds (-1 when the file does
    // not say: a FLAC whose STREAMINFO counts 0 samples).
    frames: f64 = 0;
    duration: f64 = -1;
    // A WAV's or FLAC's bits per sample (an MP3's 16, what it decodes to),
    // and whether a WAV's samples are IEEE floats.
    bitsPerSample: i32 = 0;
    floatSamples: bool = false;
    // Where the samples start in the file and how many bytes they take (a
    // WAV's data chunk; an MP3's first frame and its frames; a FLAC's
    // frames after its metadata blocks).
    dataOffset: i32 = 0;
    dataBytes: i32 = 0;
    // A WAV's first smpl loop, in sample frames (-1 none), and its kind
    // as AUDIO_LOOP_* (forward, ping-pong or backward; DISABLED: none).
    smplLoopBegin: f64 = -1;
    smplLoopEnd: f64 = -1;
    smplLoopMode: i32 = AUDIO_LOOP_DISABLED;
    // An MP3's frames (each of samplesPerFrame samples), a Xing or Info
    // frame among them; whether its first frame is one; the samples the
    // runtime trims at the start (LAME's encoder delay + 529) and at the
    // end (LAME's padding - 529, at least 0): frames counts what is left.
    mpegFrames: i32 = 0;
    samplesPerFrame: i32 = 0;
    mpegInfoFrame: bool = false;
    mpegTrimStart: i32 = 0;
    mpegTrimEnd: i32 = 0;

    // A WAV's bytes a frame (channels x bytes a sample).
    get blockAlign(): i32 {
        return this.channels * ((this.bitsPerSample + 7) >> 3);
    }
}

function u16le(b: Uint8Array, at: i32): u32 {
    return <u32>b[at] | (<u32>b[at + 1] << 8);
}

function u32le(b: Uint8Array, at: i32): u32 {
    return <u32>b[at] | (<u32>b[at + 1] << 8) | (<u32>b[at + 2] << 16) | (<u32>b[at + 3] << 24);
}

function tagAt(b: Uint8Array, at: i32, tag: string): bool {
    if (at < 0 || at + tag.length > b.length) return false;
    for (let i = 0; i < tag.length; i++) if (<i32>b[at + i] != tag.charCodeAt(i)) return false;
    return true;
}

function fail(why: string): Result<AudioInfo> {
    return Result.fail<AudioInfo>(why);
}

// ---------------------------------------------------------------------------
// WAV

function readWav(b: Uint8Array): Result<AudioInfo> {
    if (b.length < 12) return fail("its RIFF header is cut short");
    const info = new AudioInfo();
    info.format = AUDIO_FORMAT_WAV;
    let fmt = false;
    let data = false;
    let tag: i32 = 0;
    let at = 12;
    // (a chunk's header is 8 bytes; one cut short ends the walk)
    while (at + 8 <= b.length) {
        const size = u32le(b, at + 4);
        const body = at + 8;
        const left = <u32>(b.length - body);
        const have = <i32>(size < left ? size : left);
        if (tagAt(b, at, "fmt ")) {
            if (have < 16) return fail("its fmt chunk is " + have.toString() + " bytes, under the 16 it must hold");
            tag = <i32>u16le(b, body);
            info.channels = <i32>u16le(b, body + 2);
            info.sampleRate = <i32>u32le(b, body + 4);
            info.bitsPerSample = <i32>u16le(b, body + 14);
            if (tag == WAV_FORMAT_EXTENSIBLE) {
                // WAVE_FORMAT_EXTENSIBLE: cbSize, valid bits, channel mask,
                // then the sub-format GUID, whose first two bytes are the
                // format tag it stands for.
                if (have < 40) return fail("its extensible fmt chunk is " + have.toString() + " bytes, under the 40 it must hold");
                tag = <i32>u16le(b, body + 24);
            }
            fmt = true;
        } else if (tagAt(b, at, "data")) {
            info.dataOffset = body;
            info.dataBytes = have;
            data = true;
        } else if (tagAt(b, at, "smpl") && have >= 36) {
            const loops = u32le(b, body + 28);
            // (the first loop: 24 bytes after the 36 of the header)
            if (loops > 0 && have >= 60) {
                const type = u32le(b, body + 36 + 4);
                if (type <= 2) {
                    info.smplLoopMode = type == 0 ? AUDIO_LOOP_FORWARD : type == 1 ? AUDIO_LOOP_PINGPONG : AUDIO_LOOP_BACKWARD;
                    info.smplLoopBegin = <f64>u32le(b, body + 36 + 8);
                    info.smplLoopEnd = <f64>u32le(b, body + 36 + 12);
                }
            }
        }
        // (an odd chunk is padded to even)
        const next = <i64>body + <i64>size + <i64>(size & 1);
        if (next > <i64>b.length) break;
        at = <i32>next;
    }
    if (!fmt) return fail("it has no fmt chunk");
    if (!data) return fail("it has no data chunk");
    if (tag == WAV_FORMAT_PCM) {
        const bits = info.bitsPerSample;
        if (bits != 8 && bits != 16 && bits != 24 && bits != 32) {
            return fail("it is " + bits.toString() + "-bit PCM (the runtime reads 8, 16, 24 and 32-bit PCM)");
        }
    } else if (tag == WAV_FORMAT_FLOAT) {
        const bits = info.bitsPerSample;
        if (bits != 32 && bits != 64) return fail("it is " + bits.toString() + "-bit float (32 or 64-bit, not that)");
        info.floatSamples = true;
    } else {
        return fail("its samples are of format " + tag.toString()
            + " (the runtime reads PCM 1, IEEE float 3 and extensible 0xFFFE naming either)");
    }
    if (info.channels <= 0) return fail("its fmt chunk names no channel");
    if (info.sampleRate <= 0) return fail("its sample rate is 0");
    const block = info.blockAlign;
    info.frames = <f64>(info.dataBytes / block);
    info.duration = info.frames / <f64>info.sampleRate;
    return Result.okv<AudioInfo>(info);
}

// ---------------------------------------------------------------------------
// FLAC

function readFlac(b: Uint8Array, at: i32): Result<AudioInfo> {
    // "fLaC", then metadata blocks: a byte of last-flag and type, 3 bytes
    // of length; the first is STREAMINFO (type 0), 34 bytes.
    const head = at + 4;
    if (head + 4 + 34 > b.length) return fail("its STREAMINFO block is cut short");
    if ((b[head] & 0x7F) != 0) return fail("its first metadata block is not STREAMINFO");
    const s = head + 4;
    // bytes 10..17: 20 bits of rate, 3 of channels - 1, 5 of bits - 1, 36
    // of total samples
    const rate = (<u32>b[s + 10] << 12) | (<u32>b[s + 11] << 4) | (<u32>b[s + 12] >> 4);
    const channels = ((<i32>b[s + 12] >> 1) & 7) + 1;
    const bits = (((<i32>b[s + 12] & 1) << 4) | (<i32>b[s + 13] >> 4)) + 1;
    let total: u64 = <u64>(b[s + 13] & 0x0F);
    for (let k = 14; k < 18; k++) total = (total << 8) | <u64>b[s + k];
    if (rate == 0) return fail("its STREAMINFO says a sample rate of 0");
    const info = new AudioInfo();
    info.format = AUDIO_FORMAT_FLAC;
    info.sampleRate = <i32>rate;
    info.channels = channels;
    info.bitsPerSample = bits;
    info.frames = <f64>total;
    info.duration = total == 0 ? -1 : <f64>total / <f64>rate;
    // the frames start after the last metadata block
    let m = head;
    while (m + 4 <= b.length) {
        const last = (b[m] & 0x80) != 0;
        const len = (<i32>b[m + 1] << 16) | (<i32>b[m + 2] << 8) | <i32>b[m + 3];
        m += 4 + len;
        if (last) break;
    }
    info.dataOffset = min<i32>(m, b.length);
    info.dataBytes = b.length - info.dataOffset;
    return Result.okv<AudioInfo>(info);
}

// ---------------------------------------------------------------------------
// MP3

// Layer III bit rates in kb/s by index: MPEG 1, then MPEG 2 and 2.5.
const MPEG1_L3_KBPS: StaticArray<i32> = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
const MPEG2_L3_KBPS: StaticArray<i32> = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
// Sample rates by index: MPEG 1, 2 and 2.5.
const MPEG1_RATES: StaticArray<i32> = [44100, 48000, 32000];
const MPEG2_RATES: StaticArray<i32> = [22050, 24000, 16000];
const MPEG25_RATES: StaticArray<i32> = [11025, 12000, 8000];

// One frame header read.
export class MpegFrame {
    // 1 (MPEG 1), 2 (MPEG 2) or 25 (MPEG 2.5).
    version: i32 = 0;
    layer: i32 = 0;
    rate: i32 = 0;
    kbps: i32 = 0;
    channels: i32 = 0;
    bytes: i32 = 0;
    samples: i32 = 0;
}

// The MPEG audio frame header at `at` (any layer), or null when the bytes
// there are none: a sync of 11 set bits, a known version and layer, a bit
// rate that is neither free nor bad, a known sample rate.
export function mpegFrameAt(b: Uint8Array, at: i32): MpegFrame? {
    if (at < 0 || at + 4 > b.length) return null;
    const h1 = <i32>b[at + 1];
    const h2 = <i32>b[at + 2];
    if (b[at] != 0xFF || (h1 & 0xE0) != 0xE0) return null;
    const v = (h1 >> 3) & 3;
    const l = (h1 >> 1) & 3;
    const bri = h2 >> 4;
    const sri = (h2 >> 2) & 3;
    if (v == 1 || l == 0 || bri == 0 || bri == 15 || sri == 3) return null;
    const f = new MpegFrame();
    f.version = v == 3 ? 1 : v == 2 ? 2 : 25;
    f.layer = 4 - l;
    f.rate = v == 3 ? MPEG1_RATES[sri] : v == 2 ? MPEG2_RATES[sri] : MPEG25_RATES[sri];
    f.channels = ((<i32>b[at + 3] >> 6) & 3) == 3 ? 1 : 2;
    const pad = (h2 >> 1) & 1;
    if (f.layer == 3) {
        f.kbps = v == 3 ? MPEG1_L3_KBPS[bri] : MPEG2_L3_KBPS[bri];
        // 1152 samples a frame in MPEG 1, 576 in MPEG 2 and 2.5
        f.samples = v == 3 ? 1152 : 576;
        f.bytes = (v == 3 ? 144000 : 72000) * f.kbps / f.rate + pad;
    } else {
        // (layers I and II: known, refused by the reader; their sizes kept
        // rough, they are never walked)
        f.kbps = 0;
        f.samples = f.layer == 1 ? 384 : 1152;
        f.bytes = 0;
    }
    return f;
}

// The bytes the ID3v2 tags at the start take (0: none), each 10 bytes of
// header, a syncsafe size, and a 10-byte footer when its flag says so.
export function id3v2Bytes(b: Uint8Array): i32 {
    let at = 0;
    while (tagAt(b, at, "ID3") && at + 10 <= b.length) {
        const size = (<i32>(b[at + 6] & 0x7F) << 21) | (<i32>(b[at + 7] & 0x7F) << 14) | (<i32>(b[at + 8] & 0x7F) << 7)
            | <i32>(b[at + 9] & 0x7F);
        const footer = (b[at + 5] & 0x10) != 0 ? 10 : 0;
        at += 10 + size + footer;
    }
    return min<i32>(at, b.length);
}

// How far past the tags the first frame may start: decoders scan for a
// sync over junk an encoder left, and so does this, as far as this.
const MP3_SYNC_SCAN: i32 = 4096;

function readMp3(b: Uint8Array, from: i32): Result<AudioInfo> {
    let at = from;
    let first: MpegFrame? = null;
    // (the first Layer I or II header seen: the file is refused as one only
    // when no Layer III frame follows within the scan, since encoder junk
    // can hold bytes shaped like such a header, as like a Layer III one,
    // and the runtime's decoder scans past them)
    let otherLayer = 0;
    const end = min<i32>(b.length, from + MP3_SYNC_SCAN);
    for (; at < end; at++) {
        const f = mpegFrameAt(b, at);
        if (f == null) continue;
        // (a sync is taken once the frame after it is a frame too, or the
        // file ends with it: a stray 0xFF in the junk is not one)
        if (f.layer == 3 && f.bytes > 4) {
            const next = mpegFrameAt(b, at + f.bytes);
            if (next != null || at + f.bytes >= b.length) {
                first = f;
                break;
            }
        } else if (f.layer != 3 && otherLayer == 0) {
            otherLayer = f.layer;
        }
    }
    if (first == null && otherLayer != 0) {
        return fail("it is MPEG audio Layer " + (otherLayer == 1 ? "I" : "II") + ", not Layer III (MP3)");
    }
    if (first == null) return fail("no MPEG audio frame starts within its first " + MP3_SYNC_SCAN.toString() + " bytes"
        + (from > 0 ? " after its ID3 tag" : ""));
    const f0 = first!;
    const info = new AudioInfo();
    info.format = AUDIO_FORMAT_MP3;
    info.sampleRate = f0.rate;
    info.channels = f0.channels;
    info.bitsPerSample = 16;
    info.samplesPerFrame = f0.samples;
    info.dataOffset = at;
    let frames = 0;
    let p = at;
    while (true) {
        const f = mpegFrameAt(b, p);
        // (a frame of another version or rate ends the stream: decoders
        // stop there too)
        if (f == null || f.layer != 3 || f.rate != f0.rate || f.bytes <= 4 || p + f.bytes > b.length) break;
        frames++;
        p += f.bytes;
    }
    info.mpegFrames = frames;
    info.dataBytes = p - at;
    readGapless(b, at, f0, info);
    const audioFrames = info.mpegInfoFrame ? frames - 1 : frames;
    const samples = <f64>audioFrames * <f64>f0.samples - <f64>info.mpegTrimStart - <f64>info.mpegTrimEnd;
    info.frames = samples > 0 ? samples : 0;
    info.duration = info.frames / <f64>f0.rate;
    return Result.okv<AudioInfo>(info);
}

// The Xing or Info tag of the first frame at `at`, as dr_mp3 reads it:
// past the header (and its CRC) and the Layer III side information (17 or
// 32 bytes in MPEG 1, 9 or 17 in MPEG 2 and 2.5, mono or not), the tag
// name, 4 bytes of flags, the fields they name (a frame count, a byte
// count, a 100-byte table, a quality), then LAME's extension when its
// first byte is not 0: 21 bytes on, 12 bits of encoder delay and 12 of
// padding. Sets info's mpegInfoFrame, mpegTrimStart and mpegTrimEnd.
function readGapless(b: Uint8Array, at: i32, f0: MpegFrame, info: AudioInfo): void {
    // (dr_mp3 takes the frame for a tag only when every field it reads is
    // inside the frame; otherwise the frame is audio like the others)
    const end = min<i32>(b.length, at + f0.bytes);
    const crc = (<i32>b[at + 1] & 1) == 0 ? 2 : 0;
    const side = f0.version == 1 ? (f0.channels == 1 ? 17 : 32) : (f0.channels == 1 ? 9 : 17);
    let t = at + 4 + crc + side;
    if (t + 8 > end) return;
    if (!tagAt(b, t, "Xing") && !tagAt(b, t, "Info")) return;
    const flags = <i32>b[t + 7];
    t += 8;
    if ((flags & 1) != 0) t += 4;
    if ((flags & 2) != 0) t += 4;
    if ((flags & 4) != 0) t += 100;
    if ((flags & 8) != 0) t += 4;
    if (t + 1 > end) return;
    let delay = 0;
    let padding = 0;
    if (b[t] != 0) {
        if (t + 36 > end) return;
        const q = t + 21;
        delay = ((<i32>b[q] << 4) | (<i32>b[q + 1] >> 4)) + 529;
        padding = max<i32>(0, (((<i32>b[q + 1] & 0xF) << 8) | <i32>b[q + 2]) - 529);
    }
    info.mpegInfoFrame = true;
    info.mpegTrimStart = delay;
    info.mpegTrimEnd = padding;
}

// ---------------------------------------------------------------------------

// What `bytes` are (see the header), or why they are no WAV, MP3 or FLAC.
export function readAudioInfo(bytes: Uint8Array): Result<AudioInfo> {
    const b = bytes;
    if (b.length < 4) return fail("it holds " + b.length.toString() + " bytes");
    if (tagAt(b, 0, "RIFF")) {
        if (!tagAt(b, 8, "WAVE")) return fail("it is a RIFF file but not WAVE");
        return readWav(b);
    }
    if (tagAt(b, 0, "RF64")) return fail("it is an RF64 WAV, which the runtime does not read (write a plain RIFF WAV)");
    if (tagAt(b, 0, "fLaC")) return readFlac(b, 0);
    if (tagAt(b, 0, "OggS")) return fail("it is Ogg, which the Rive runtime cannot decode");
    if (tagAt(b, 0, "FORM")) return fail("it is AIFF, which the Rive runtime cannot decode");
    const tags = id3v2Bytes(b);
    // (a FLAC may carry an ID3 tag before its fLaC, as some taggers write)
    if (tags > 0 && tagAt(b, tags, "fLaC")) return readFlac(b, tags);
    if (tags > 0 || mpegFrameAt(b, 0) != null) return readMp3(b, tags);
    return fail("its first bytes are none of RIFF/WAVE, fLaC, an ID3 tag or an MPEG audio frame");
}
