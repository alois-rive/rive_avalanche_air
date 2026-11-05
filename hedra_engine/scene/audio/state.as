// Milestone 36: what an AudioStreamPlayer3D is playing (docs/engine/
// AUDIO.md; the contract between the node's methods (../tree/node.as
// play, stop, seek: a stop and a play), the clock that moves its
// playbacks (./clock.as), the gains the listener hears (./attenuation.as) and the feature that plays
// them through the runtime's audio (../runtime/feature_audio.as,
// ./rive_out.as)). Made at the node's first play, its voices made with it:
// nothing here allocates afterwards.
//
// A voice is one playback (Godot's AudioStreamPlayback): `max_polyphony`
// of them may overlap, a play past it taking the oldest's place. Its
// position is the scene's clock's (seconds advanced since it began, from
// where it began), not the audio device's: the tools play nothing and
// still know where every playback is, renders and goldens are stable, and
// `finished` comes at the same frame in the tools, Play and a built
// project. The runtime's sounds follow it: started, paused and stopped by
// the feature, which keeps their handles in the voice.

// Godot's AudioStreamPlayer3D max_polyphony is at least 1; Hedra's at most
// 8 (two of the runtime's sounds a voice when panned: 16 sounds a player).
export const MAX_AUDIO_POLYPHONY: i32 = 8;
// What the outputs read when nothing is heard (Godot's -80 dB floor of
// volume_db), and the dB a linear gain of 0 is taken as.
export const AUDIO_SILENT_DB: f32 = -80;
// No sound of the runtime's (a voice's handle not taken).
export const AUDIO_NO_SOUND: i32 = -1;
// The tools' clock steps, as the particles' (../particles/state.as
// PARTICLE_TOOL_STEP): 1/60 s, so `render --time 2` is 120 frames of a host.
export const AUDIO_TOOL_STEP: f64 = 1.0 / 60.0;

export class AudioVoice {
    // In use: begun and not yet ended or stopped.
    active: bool = false;
    // Seconds into the stream, on the scene's clock (wrapped into the loop
    // for a looping stream).
    position: f64 = 0;
    // The order voices began in (the oldest is taken past max_polyphony).
    serial: i64 = 0;
    // Set when the voice stopped or ended while the runtime's sounds were
    // playing it: the feature stops and releases them, then clears it.
    released: bool = false;
    // Set when it ended at its stream's end (not stopped): its sounds play
    // their last moments out and the runtime frees them (the feature does
    // not cut them).
    playedOut: bool = false;
    // Where a play (a seek's too) of this frame put it (`fresh` until the
    // feature's next frame): the clock then moved it on by the frame's
    // seconds, but the runtime's sounds start here, so the device
    // plays the stream from where it was played and not a frame into it
    // (the scene's clock runs that frame ahead of the device).
    from: f64 = 0;
    fresh: bool = false;
    // The runtime's sounds (AUDIO_NO_SOUND: none): the left and right forms
    // when panned, else one centred; and, for a looping stream, the next
    // pass's, scheduled at the current pass's end frame.
    left: i32 = AUDIO_NO_SOUND;
    right: i32 = AUDIO_NO_SOUND;
    centre: i32 = AUDIO_NO_SOUND;
    nextLeft: i32 = AUDIO_NO_SOUND;
    nextRight: i32 = AUDIO_NO_SOUND;
    nextCentre: i32 = AUDIO_NO_SOUND;
    // The audio engine's frame the current sounds began at, and the
    // stream's seconds they began from (for the next pass's frame); and
    // the same of the next pass, once scheduled.
    startFrame: f64 = 0;
    startOffset: f64 = 0;
    nextFrame: f64 = 0;
    nextOffset: f64 = 0;
    // The sounds of the playback this voice held before a play took its
    // place while they still played (every voice in use: handOff), for the
    // feature to stop; clear() keeps them.
    goneLeft: i32 = AUDIO_NO_SOUND;
    goneRight: i32 = AUDIO_NO_SOUND;
    goneCentre: i32 = AUDIO_NO_SOUND;
    goneNextLeft: i32 = AUDIO_NO_SOUND;
    goneNextRight: i32 = AUDIO_NO_SOUND;
    goneNextCentre: i32 = AUDIO_NO_SOUND;

    // Back to unused, its handles forgotten (the feature released them).
    clear(): void {
        this.active = false;
        this.position = 0;
        this.released = false;
        this.playedOut = false;
        this.from = 0;
        this.fresh = false;
        this.left = AUDIO_NO_SOUND;
        this.right = AUDIO_NO_SOUND;
        this.centre = AUDIO_NO_SOUND;
        this.nextLeft = AUDIO_NO_SOUND;
        this.nextRight = AUDIO_NO_SOUND;
        this.nextCentre = AUDIO_NO_SOUND;
        this.startFrame = 0;
        this.startOffset = 0;
        this.nextFrame = 0;
        this.nextOffset = 0;
    }

    // Whether the runtime plays it (any sound taken).
    sounding(): bool {
        return this.left != AUDIO_NO_SOUND || this.right != AUDIO_NO_SOUND || this.centre != AUDIO_NO_SOUND
            || this.nextLeft != AUDIO_NO_SOUND || this.nextRight != AUDIO_NO_SOUND || this.nextCentre != AUDIO_NO_SOUND;
    }

    // Its sounds handed to the gone ones (a play takes the voice at once;
    // the feature stops them at its next frame). A gone sound not yet
    // stopped (a second hand-off in one frame) is overwritten only past
    // MAX_AUDIO_POLYPHONY plays a frame.
    handOff(): void {
        if (this.left != AUDIO_NO_SOUND) this.goneLeft = this.left;
        if (this.right != AUDIO_NO_SOUND) this.goneRight = this.right;
        if (this.centre != AUDIO_NO_SOUND) this.goneCentre = this.centre;
        if (this.nextLeft != AUDIO_NO_SOUND) this.goneNextLeft = this.nextLeft;
        if (this.nextRight != AUDIO_NO_SOUND) this.goneNextRight = this.nextRight;
        if (this.nextCentre != AUDIO_NO_SOUND) this.goneNextCentre = this.nextCentre;
        this.left = AUDIO_NO_SOUND;
        this.right = AUDIO_NO_SOUND;
        this.centre = AUDIO_NO_SOUND;
        this.nextLeft = AUDIO_NO_SOUND;
        this.nextRight = AUDIO_NO_SOUND;
        this.nextCentre = AUDIO_NO_SOUND;
        this.released = false;
    }

    // Whether it holds gone sounds.
    hasGone(): bool {
        return this.goneLeft != AUDIO_NO_SOUND || this.goneRight != AUDIO_NO_SOUND || this.goneCentre != AUDIO_NO_SOUND
            || this.goneNextLeft != AUDIO_NO_SOUND || this.goneNextRight != AUDIO_NO_SOUND
            || this.goneNextCentre != AUDIO_NO_SOUND;
    }
}

export class AudioPlayback {
    // MAX_AUDIO_POLYPHONY voices, made once.
    voices: Array<AudioVoice> = [];
    private serial: i64 = 0;
    // stream_paused as the clock last applied it (the feature pauses and
    // resumes the sounds when it changes).
    paused: bool = false;
    // A playback ended this frame (Godot's finished): the feature emits the
    // node's signal once and clears it.
    finishedPending: bool = false;
    // What the listener hears of the player now (./attenuation.as): the
    // outputs' values (listener_volume_db, listener_pan, also on the node),
    // the gain of each form (linear; the centred stream's when it has no
    // forms) and the distance to the listener, in metres. Silent: -80 dB,
    // pan 0, gains 0.
    volumeDb: f32 = AUDIO_SILENT_DB;
    pan: f32 = 0;
    gainLeft: f32 = 0;
    gainRight: f32 = 0;
    gainCentre: f32 = 0;
    distance: f32 = 0;
    // Whether a listener was found for the gains (false: none, silent).
    heard: bool = false;
    // play() calls in all (tests), and a count that moves whenever a voice
    // begins, ends or is stopped (the feature's status stamp).
    plays: i64 = 0;
    version: i64 = 0;

    constructor() {
        for (let i = 0; i < MAX_AUDIO_POLYPHONY; i++) this.voices.push(new AudioVoice());
    }

    // A new playback from `from` seconds, taking a free voice, or past
    // `polyphony` (1 to MAX_AUDIO_POLYPHONY) the oldest active one (marked
    // released when the runtime played it, as Godot stops the oldest). The
    // voice it took.
    play(from: f64, polyphony: i32): AudioVoice {
        const limit = polyphony < 1 ? 1 : (polyphony > MAX_AUDIO_POLYPHONY ? MAX_AUDIO_POLYPHONY : polyphony);
        let active = 0;
        let free: AudioVoice? = null;
        let oldest: AudioVoice? = null;
        for (let i = 0; i < this.voices.length; i++) {
            const v = unchecked(this.voices[i]);
            if (v.active) {
                active++;
                if (oldest == null || v.serial < oldest.serial) oldest = v;
            } else if (free == null && !v.released && !v.sounding()) {
                free = v;
            }
        }
        let v: AudioVoice;
        if (active >= limit && oldest != null) {
            v = oldest;
            this.stopVoice(v);
            // (the oldest's slot is reused at once when nothing sounds in it;
            // else a free one, the oldest's sounds released by the feature;
            // with none free, the oldest's sounds are handed off)
            if (v.sounding()) {
                if (free != null) v = free;
                else v.handOff();
            }
        } else if (free != null) {
            v = free;
        } else {
            v = this.spare(null);
            if (v.sounding()) v.handOff();
        }
        v.clear();
        v.active = true;
        v.position = from > 0 ? from : 0;
        v.from = v.position;
        v.fresh = true;
        v.serial = ++this.serial;
        this.plays++;
        this.version++;
        return v;
    }

    // Stops every voice (Godot's stop(): no finished).
    stopAll(): void {
        for (let i = 0; i < this.voices.length; i++) {
            const v = unchecked(this.voices[i]);
            if (v.active) this.stopVoice(v);
        }
    }

    // The newest active voice's position (Godot's get_playback_position),
    // 0 when none plays.
    position(): f64 {
        let best: AudioVoice? = null;
        for (let i = 0; i < this.voices.length; i++) {
            const v = unchecked(this.voices[i]);
            if (v.active && (best == null || v.serial > best.serial)) best = v;
        }
        return best != null ? best.position : 0;
    }

    // How many voices are active.
    activeCount(): i32 {
        let n = 0;
        for (let i = 0; i < this.voices.length; i++) if (unchecked(this.voices[i]).active) n++;
        return n;
    }

    // Ends `v` (stopped, or at its end: the caller sets finishedPending);
    // the feature releases its sounds.
    stopVoice(v: AudioVoice): void {
        if (!v.active) return;
        v.active = false;
        v.playedOut = false;
        if (v.sounding()) v.released = true;
        this.version++;
    }

    // Ends `v` at its stream's end (the clock): as stopVoice, but its
    // sounds are left to play out (the device is up to a frame and the
    // start's lead behind the clock, and cutting them would lose that much
    // of the stream's end).
    endVoice(v: AudioVoice): void {
        if (!v.active) return;
        this.stopVoice(v);
        v.playedOut = v.released;
    }

    // A voice for a new playback when every slot still sounds (the
    // runtime's sounds of stopped voices not yet released): the one that
    // is not `not`, released first. (Only past MAX_AUDIO_POLYPHONY plays in
    // one frame.)
    private spare(not: AudioVoice?): AudioVoice {
        for (let i = 0; i < this.voices.length; i++) {
            const v = unchecked(this.voices[i]);
            if (v !== not && !v.active) return v;
        }
        return unchecked(this.voices[0]);
    }
}
