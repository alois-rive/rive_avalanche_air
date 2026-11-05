// Milestone 36: the runtime's audio as the scene's AudioOut (./backend.as):
// a Rive project's AudioAssets found by name through the host's Context,
// played with rive/audio. Sources are looked up once a name and kept (a
// name the file does not have is kept too, so it is not asked again);
// sounds live in a table of slots reused once released (the lowest free
// one), each with the volume it was last given, so a frame that sets the
// same volumes again calls nothing and a frame that only changes them
// allocates nothing (a new sound is the runtime's handle, made at a play).
//
// A stop ends the sound rather than stopping it: the runtime's engine
// keeps every sound it plays in a list it leaves only through its end
// callback (AudioEngine::SoundCompleted, run when the sound's data runs
// out) or the engine's own stop of an artboard, which a script cannot
// reach; AudioSound.stop, with a fade or without, stops the mixing before
// the end, and release() drops only the script's handle, so a stopped
// sound's miniaudio sound and decoder would stay for the engine's life
// (every radio Off, every ring cut short, every next pass a pause drops).
// Ended, it is silenced (volume 0, from the device's next period), sought
// to its source's end and set playing (a paused one is the runtime's
// stop(0)): the next period the device mixes reads nothing more, the end
// callback runs and the engine frees it at its next play. The 5 ms fade a
// stop could have is lost (a stop cuts at the period); a sound not yet
// begun (a scheduled pass) ends at its start frame. An MP3 is not sought:
// its decoder seeks by decoding every frame up to the target on the audio
// thread (no seek table), which for a long piece of music would stall the
// mix, so it plays its rest out silent and is freed at its end. dispose()
// releases the sources and any sound still held, as the runtime frees them
// only on release().
//
// Without an audio engine (hedra's own runtime, built without
// WITH_RIVE_AUDIO, and `rive --test`) Context.audio finds nothing and the
// plays return null: the feature then only computes the gains and the
// outputs. Headless (`rive --screenshot`, `--data-dump`) the engine runs
// without a device: plays return sounds and its clock stays at 0.

import { Context } from "rive/host";
import { Audio, AudioSound, AudioSource } from "rive/audio";
import { AudioOut } from "./backend";

export class RiveAudioOut extends AudioOut {
    ctx: Context;
    private names: Array<string> = [];
    private sources: Array<AudioSource?> = [];
    private slots: Array<AudioSound?> = [];
    private volumes: Array<f32> = [];
    // Each slot's source (its length is where a stop seeks to), and
    // whether each source may be sought to its end (not an MP3).
    private of: Array<i32> = [];
    private seekable: Array<bool> = [];
    private live: i32 = 0;

    constructor(ctx: Context) {
        super();
        this.ctx = ctx;
    }

    source(name: string): i32 {
        const at = this.names.indexOf(name);
        if (at >= 0) return this.sources[at] != null ? at : -1;
        this.names.push(name);
        const s = this.ctx.audio(name);
        this.sources.push(s);
        this.seekable.push(!name.toLowerCase().endsWith(".mp3"));
        return s != null ? this.names.length - 1 : -1;
    }

    duration(source: i32): f64 {
        const s = this.src(source);
        return s != null ? s.duration : -1;
    }

    sampleRate(): f64 {
        return Audio.sampleRate();
    }

    clockFrame(): f64 {
        return Audio.timeFrame();
    }

    start(source: i32, frame: f64, offset: f64, volume: f32): i32 {
        const s = this.src(source);
        if (s == null) return -1;
        const sound = Audio.playAtFrame(s, frame > 0 ? frame : 0);
        if (sound == null) return -1;
        sound.volume = <f64>volume;
        if (offset > 0) sound.seek(offset);
        let slot = -1;
        for (let i = 0; i < this.slots.length && slot < 0; i++) if (unchecked(this.slots[i]) == null) slot = i;
        if (slot < 0) {
            slot = this.slots.length;
            this.slots.push(sound);
            this.volumes.push(volume);
            this.of.push(source);
        } else {
            this.slots[slot] = sound;
            this.volumes[slot] = volume;
            this.of[slot] = source;
        }
        this.live++;
        return slot;
    }

    setVolume(sound: i32, volume: f32): void {
        const s = this.at(sound);
        if (s == null || unchecked(this.volumes[sound]) == volume) return;
        this.volumes[sound] = volume;
        s.volume = <f64>volume;
    }

    pause(sound: i32): void {
        const s = this.at(sound);
        if (s != null) s.pause();
    }

    resume(sound: i32): void {
        const s = this.at(sound);
        if (s != null) s.resume();
    }

    seek(sound: i32, seconds: f64): void {
        const s = this.at(sound);
        if (s != null) s.seek(seconds > 0 ? seconds : 0);
    }

    stop(sound: i32): void {
        const s = this.at(sound);
        if (s == null) return;
        // (ended, not stopped: see the header)
        s.volume = 0;
        const from = unchecked(this.of[sound]);
        const src = this.src(from);
        const d = src != null ? src.duration : 0;
        if (d > 0 && unchecked(this.seekable[from])) s.seek(d);
        s.resume();
        this.release(sound);
    }

    completed(sound: i32): bool {
        const s = this.at(sound);
        return s == null || s.completed();
    }

    release(sound: i32): void {
        const s = this.at(sound);
        if (s == null) return;
        s.release();
        this.slots[sound] = null;
        this.live--;
    }

    sounds(): i32 {
        return this.live;
    }

    dispose(): void {
        for (let i = 0; i < this.slots.length; i++) {
            const s = unchecked(this.slots[i]);
            if (s != null) s.release();
        }
        for (let i = 0; i < this.sources.length; i++) {
            const s = unchecked(this.sources[i]);
            if (s != null) s.release();
        }
        this.slots.length = 0;
        this.volumes.length = 0;
        this.of.length = 0;
        this.sources.length = 0;
        this.seekable.length = 0;
        this.names.length = 0;
        this.live = 0;
    }

    private src(source: i32): AudioSource? {
        return source >= 0 && source < this.sources.length ? unchecked(this.sources[source]) : null;
    }

    private at(sound: i32): AudioSound? {
        return sound >= 0 && sound < this.slots.length ? unchecked(this.slots[sound]) : null;
    }
}
