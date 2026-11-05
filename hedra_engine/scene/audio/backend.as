// Milestone 36: what plays the scene's sounds (docs/engine/AUDIO.md
// "In a Rive project"): the runtime's audio in a Rive project
// (./rive_out.as RiveAudioOut, over Context.audio and rive/audio), a
// recording one in the tests, none in the tools (they are silent: the
// feature then only computes the gains and the outputs). The feature
// (../runtime/feature_audio.as) is its only caller; the ids are its own
// small numbers into tables made once, so a frame allocates nothing.
//
// What the pinned runtime offers a script (rive 1.6.0's rive/audio, read
// for this milestone): an AudioSource per AudioAsset (Context.audio(name):
// duration, sampleRate, channels), and per play an AudioSound with
// play/pause/resume/stop(fadeFrames)/seek/seekFrame/completed/time/
// timeFrame and a linear `volume`; the engine's clock (Audio.time,
// timeFrame, sampleRate) and sample-exact starts (Audio.playAtFrame). No
// pan, no pitch, no filter, no loop: a sound's stereo balance is its
// file's, so a player pans by playing two forms of its stream, the left
// channel alone and the right alone, started at the same frame, each at
// its own volume; and a loop is the next pass scheduled at the current
// one's end frame. Headless (`rive --screenshot`, `--data-dump`) the
// engine runs without a device: plays return sounds, volumes read back,
// and its clock stays at 0.
//
// The engine frees a sound only when it reaches the end of its data (its
// end callback) or the engine goes; a sound stopped, with a fade or
// without, never reaches it and is kept, decoder and all, for the
// engine's life. So a stop here ends the sound instead (./rive_out.as),
// without the fade the runtime's stop would give.

export abstract class AudioOut {
    // The source of the Rive AudioAsset `name`, or -1 when the file has
    // none; the same id for the same name. (Looked up once a name: the
    // feature keeps the ids.)
    abstract source(name: string): i32;

    // The source's length in seconds (the runtime's AudioSource.duration).
    abstract duration(source: i32): f64;

    // The engine's sample rate (Hz) and clock (frames since it started);
    // 0 and 0 when there is no engine.
    abstract sampleRate(): f64;
    abstract clockFrame(): f64;

    // A sound of `source` started at the engine's `frame` (now, or later:
    // a loop's next pass), from `offset` seconds into it, at linear
    // `volume`; -1 when the runtime has no engine or refused.
    abstract start(source: i32, frame: f64, offset: f64, volume: f32): i32;

    abstract setVolume(sound: i32, volume: f32): void;
    abstract pause(sound: i32): void;
    abstract resume(sound: i32): void;
    abstract seek(sound: i32, seconds: f64): void;

    // Ends the sound (silent from the device's next period; the runtime
    // then frees it) and lets its id go.
    abstract stop(sound: i32): void;

    // Whether the sound has played to its end (its id then goes with
    // release).
    abstract completed(sound: i32): bool;
    abstract release(sound: i32): void;

    // How many sounds it holds now (the status's count; tests).
    abstract sounds(): i32;

    // Lets go of everything it holds from the runtime (its sources and any
    // sound still held), when the instance it plays for is disposed. The
    // runtime frees a source only on its release() or when it is
    // collected, and the stub allocator never collects, so without this a
    // Scene3D that swaps its scene would leave every source behind.
    dispose(): void {}
}
