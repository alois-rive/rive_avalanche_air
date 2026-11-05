// The audio feature of the run time (milestone 36, features.as
// FEATURE_AUDIO; docs/engine/AUDIO.md, docs/cli/BUILD.md section 18):
// each instance's AudioStreamPlayer3D nodes advanced every frame on the
// scene's clock (../audio/clock.as, after the scripts: PHASE_SCRIPTS,
// installed after the particles feature, so a script's play() or move is
// heard this frame), their gains at the listener computed
// (../audio/attenuation.as: the current AudioListener3D, else the camera
// the instance is seen through, SceneInstance.cameraListener), the two
// outputs set (listener_volume_db, listener_pan), and the playbacks
// played through the runtime's audio (../audio/rive_out.as over the
// instance's Context; none without one: the tools are silent). A playback
// that ended emits its node's `finished` once a frame (Godot's signal),
// through SceneInstance.emitEvent with an event of the node's own, so that
// connections, scripts and a `signal:finished` binding hear it.
//
// How a playback (a voice, ../audio/state.as) is played:
//   - its stream's sources are looked up once a stream, by the stream's
//     Rive asset name: panned when both its left and right forms are found
//     (assetName + "#left" and "#right": two sounds a voice, started at the
//     same engine frame, each at its speaker's gain), else centred on the
//     stream's own asset (one sound at the centre gain: Godot's power,
//     without the balance), else silent; a stream whose length the file
//     did not say takes the source's;
//   - a voice that plays and has no sound yet starts its sounds at the
//     engine's frame AUDIO_START_LEAD from now (both forms then name the
//     same frame the device has not yet mixed, however the audio thread
//     runs between the two plays), from where it was played this frame
//     (AudioVoice.from: not a frame into the stream), else from its
//     position; a seek is Godot's, a stop and a play: its old sounds are
//     stopped and new ones started the same way;
//   - a voice that was stopped ends its sounds (AudioOut.stop: silent from
//     the device's next period, and run to their end so that the runtime
//     frees them); one that played to its stream's end leaves them to play
//     their last moments out (the device runs that frame and the lead
//     behind the clock), released once the runtime says they completed;
//     every frame each sound is given its gain (the runtime's linear
//     volume);
//   - a looping stream has no loop in the runtime: its next pass is
//     scheduled sample-exact at the current pass's end frame once the
//     engine's clock is within AUDIO_LOOP_LOOKAHEAD of it, and becomes the
//     current one when the clock reaches it (the old sounds released once
//     the runtime says they completed; a centred stream whose loop ends
//     inside its file has its old sound stopped then, up to a frame late).
//     A pass that ended before its next could be scheduled (the frames
//     stalled while the device played on, as a hidden browser tab's do, or
//     a loop shorter than a frame) has the passes missed skipped: the next
//     starts the lead from now, where the loop has got to by then, so a
//     stall never replays what it missed;
//   - stream_paused, and the instance not playing, pause the sounds (the
//     next pass, not yet begun, is dropped and scheduled again after; one
//     begun by the frame is made the current one first, paused or not);
//     the sounds resume where they were.
// The clock moves by the frame's own seconds, not times the Scene3D's
// speed (SceneInstance.frameSeconds): the runtime plays every sound at its
// own speed, and Godot's time scale does not change its sounds either.
// Headless (`rive --screenshot`, `--data-dump`) the engine's clock stays
// at 0: the sounds start, no next pass is scheduled, and the gains and the
// outputs are computed all the same.
// While a player plays (and the instance plays), the part keeps the scene
// advancing (SceneInstance.keepsRunning), as a host would stop advancing a
// scene whose picture does not change: the clock must go on looping and
// ending the sounds, and firing `finished`.
//
// The players are found again only when the tree's structure changes, as
// the particles' emitters are; a player found for the first time owes its
// autoplay (Godot's play on entering the tree); a scene without a player
// costs a comparison a frame. A disposed instance, and a player freed,
// stop their sounds; a player a script removes from the tree pauses (its
// clock, its playbacks and its sounds hold, as Godot's EXIT_TREE pauses
// the stream) and resumes when it enters again, owing its autoplay again,
// as Godot's ENTER_TREE plays it (detach, find). Idle,
// walking and playing allocate nothing (the runtime's sound handles are
// made at a play, a stream's sources at its first lookup).
//
// The status adds `,"audio":{"players":N,"playing":N,"sounds":N,
// "sources":N}` for a scene with a player: those playing, the runtime's
// sounds held, and the streams whose Rive AudioAsset was found.

import { Value } from "../value";
import { AudioListener3D, AudioStreamPlayer3D, SceneNode, treeStructureEpoch } from "../tree/node";
import { AudioStream, AUDIO_LEFT_SUFFIX, AUDIO_RIGHT_SUFFIX } from "../resource/audio_stream";
import { advancePlayer, hearPlayer, streamLoopBegin, streamPassEnd } from "../audio/clock";
import { AudioGains } from "../audio/attenuation";
import { AUDIO_NO_SOUND, AudioPlayback, AudioVoice } from "../audio/state";
import { AudioOut } from "../audio/backend";
import { RiveAudioOut } from "../audio/rive_out";
import { ListenerPose, listenerAmong, listenerFromNode } from "../audio/listener";
import { FEATURE_AUDIO, Feature, InstanceFeature, PHASE_SCRIPTS } from "./features";
import { SignalEvent } from "./signals";
import { underSubViewport } from "../tree/tree";
import { SceneInstance, SceneRuntime } from "./scene_runtime";

// How early a loop's next pass is scheduled before the current one ends
// (seconds of the engine's clock: a frame of a slow host is well within).
export const AUDIO_LOOP_LOOKAHEAD: f64 = 0.25;
// How far ahead of the engine's clock a playback's sounds start (seconds):
// the clock is the frame the device mixes next, and each play takes the
// engine's lock and opens a decoder, so a period may be mixed between the
// left form's play and the right's; started at a frame two desktop periods
// (10 ms each) and more ahead, both forms begin on the same sample. (The
// web's ScriptProcessor mixes on the page's own thread, between frames.)
export const AUDIO_START_LEAD: f64 = 0.03;
// The old passes of loops waiting for the runtime to complete them, at
// most (past it they are stopped at once).
const RETIRING_CAPACITY = 64;

export class AudioFeature extends Feature {
    bit(): u32 {
        return FEATURE_AUDIO;
    }

    forInstance(inst: SceneInstance): InstanceFeature {
        return new AudioPart();
    }
}

// A stream's sources in the backend (looked up once).
class StreamSources {
    stream: AudioStream;
    left: i32 = -1;
    right: i32 = -1;
    centre: i32 = -1;

    constructor(stream: AudioStream) {
        this.stream = stream;
    }

    panned(): bool {
        return this.left >= 0 && this.right >= 0;
    }

    found(): bool {
        return this.panned() || this.centre >= 0;
    }
}

// What the feature keeps of one player.
class PlayerSounds {
    player: AudioStreamPlayer3D;
    // The stream its sources were looked up for, and them (null: none
    // looked up, or no backend).
    looked: AudioStream? = null;
    sources: StreamSources? = null;
    // Whether its sounds are paused, and the engine's frame they were
    // paused at (a resumed loop's end frame moves by the pause).
    paused: bool = false;
    pausedFrame: f64 = 0;
    // Out of the tree (a script removed it, not to free it): its playbacks
    // and sounds paused until it enters again, as Godot's EXIT_TREE pauses
    // the stream (see detach).
    away: bool = false;
    // Found again by the last search (find).
    seen: bool = false;

    constructor(player: AudioStreamPlayer3D) {
        this.player = player;
    }
}

// One instance's players, found again when the tree's structure changes.
export class AudioPart extends InstanceFeature {
    players: Array<AudioStreamPlayer3D> = [];
    // `finished`, one event per player (in `players` order).
    finished: Array<SignalEvent> = [];
    // The listener of the last advance.
    listener: ListenerPose = new ListenerPose();
    // What plays the sounds (null: silent; made at the first advance from
    // the instance's Context), settable by tests.
    out: AudioOut? = null;
    // The AudioListener3D nodes of the tree, in tree order, but those under
    // a SubViewport.
    listeners: Array<AudioListener3D> = [];
    private states: Array<PlayerSounds> = [];
    // The players out of the tree, paused (detach), until they enter it
    // again or are freed.
    private away: Array<PlayerSounds> = [];
    private streams: Array<StreamSources> = [];
    private gains: AudioGains = new AudioGains();
    private retiring: StaticArray<i32> = new StaticArray<i32>(RETIRING_CAPACITY);
    private retired: i32 = 0;
    private outTried: bool = false;
    private walked: Array<SceneNode> = [];
    private stack: Array<SceneNode> = [];
    private oldStates: Array<PlayerSounds> = [];
    private epoch: i32 = -1;

    attach(inst: SceneInstance, root: SceneNode): void {
        this.epoch = -1;
    }

    // A subtree leaving the tree: its players pause, as Godot's EXIT_TREE
    // pauses their streams (set_stream_paused(true)): their clocks hold,
    // `playing` stays on, their sounds pause, and entering the tree again
    // resumes them where they were and owes autoplay again (Godot's
    // ENTER_TREE plays an autoplay player again; find). A subtree going to
    // be freed (queueFree) stops its players and their sounds for good.
    detach(inst: SceneInstance, root: SceneNode): void {
        for (let i = 0; i < this.states.length; i++) {
            const st = unchecked(this.states[i]);
            if (!within(st.player, root)) continue;
            if (goingAway(st.player)) {
                st.player.stop();
                this.silence(st);
            } else {
                this.leave(st);
            }
        }
        this.epoch = -1;
    }

    advance(inst: SceneInstance, seconds: f64, phase: i32): bool {
        if (phase != PHASE_SCRIPTS) return false;
        if (this.away.length > 0) this.dropFreed();
        this.find(inst);
        if (this.players.length == 0) return false;
        let out = this.out;
        if (out == null && !this.outTried) {
            this.outTried = true;
            const ctx = inst.ctx;
            if (ctx != null) {
                out = new RiveAudioOut(ctx);
                this.out = out;
            }
        }
        this.hearFrom(inst);
        // (the frame's own seconds: `seconds` is times the speed)
        const real = inst.frameSeconds;
        const held = !(real > 0) && !inst.playing;
        if (out != null) this.collectRetired(out);
        for (let i = 0; i < this.players.length; i++) {
            const p = unchecked(this.players[i]);
            const st = unchecked(this.states[i]);
            // (one a `finished` handler earlier in this loop took out of
            // the tree: leave paused its sounds and holds its clock, and
            // nothing here may resume them before it enters the tree
            // again; the next frame's find files it with the away ones)
            if (st.away) continue;
            if (out != null && p.stream !== st.looked) this.lookUp(st, out);
            advancePlayer(p, real);
            hearPlayer(p, this.listener, this.gains);
            if (out != null) this.sound(st, out, held);
            const a = p.audio;
            if (a != null && a.finishedPending) {
                // (taken before the emit: a handler may play it again)
                a.finishedPending = false;
                inst.emitEvent(p, unchecked(this.finished[i]));
            }
        }
        // (a sound changes no picture: the outputs' bindings push whatever
        // the plan does; but while one plays the scene keeps advancing,
        // or a scene where nothing else moves would be left still and its
        // clock would neither loop nor end the sounds)
        if (inst.playing && this.playingCount() > 0) inst.keepsRunning = true;
        return false;
    }

    dispose(inst: SceneInstance): void {
        for (let i = 0; i < this.states.length; i++) this.silence(unchecked(this.states[i]));
        for (let i = 0; i < this.away.length; i++) this.silence(unchecked(this.away[i]));
        this.away.length = 0;
        const out = this.out;
        if (out != null) {
            for (let i = 0; i < this.retired; i++) out.stop(unchecked(this.retiring[i]));
        }
        this.retired = 0;
        // (the runtime's sources go with the instance: nothing collects
        // them; a later advance stays silent rather than make another)
        if (out != null) out.dispose();
        this.out = null;
        this.outTried = true;
    }

    status(inst: SceneInstance): string {
        if (this.players.length == 0) return "";
        const out = this.out;
        return ",\"audio\":{\"players\":" + this.players.length.toString()
            + ",\"playing\":" + this.playingCount().toString()
            + ",\"sounds\":" + (out != null ? out.sounds() : 0).toString()
            + ",\"sources\":" + this.sourcesFound().toString() + "}";
    }

    stamp(inst: SceneInstance): i64 {
        if (this.players.length == 0) return 0;
        const out = this.out;
        let m: i64 = this.players.length;
        m = m * 1009 + this.playingCount();
        m = m * 1009 + (out != null ? out.sounds() : 0);
        m = m * 1009 + this.sourcesFound();
        return m;
    }

    // How many players play (a playback active).
    playingCount(): i32 {
        let n = 0;
        for (let i = 0; i < this.players.length; i++) if (unchecked(this.players[i]).hasStreamPlayback()) n++;
        return n;
    }

    // How many of the looked-up streams have their asset found.
    sourcesFound(): i32 {
        let n = 0;
        for (let i = 0; i < this.streams.length; i++) if (unchecked(this.streams[i]).found()) n++;
        return n;
    }

    // The listener of this frame (Godot's rule, ../audio/listener.as: the
    // last current AudioListener3D in tree order, else the first one, its
    // visibility not counted), else the camera the instance is seen
    // through.
    private hearFrom(inst: SceneInstance): void {
        const pose = this.listener;
        const l = listenerAmong(this.listeners);
        if (l != null) {
            listenerFromNode(l, pose);
            return;
        }
        if (!inst.cameraListener(pose)) pose.valid = false;
    }

    // The sources of the player's stream, once a stream.
    private lookUp(st: PlayerSounds, out: AudioOut): void {
        const s = st.player.stream;
        st.looked = s;
        st.sources = null;
        if (s == null) return;
        for (let i = 0; i < this.streams.length; i++) {
            const known = unchecked(this.streams[i]);
            if (known.stream === s) {
                st.sources = known;
                return;
            }
        }
        const src = new StreamSources(s);
        const name = s.assetName;
        if (name.length > 0) {
            src.left = out.source(name + AUDIO_LEFT_SUFFIX);
            src.right = out.source(name + AUDIO_RIGHT_SUFFIX);
            if (!src.panned()) src.centre = out.source(name);
            if (s.duration < 0) {
                const from = src.panned() ? src.left : src.centre;
                if (from >= 0) {
                    const d = out.duration(from);
                    if (d > 0) s.duration = d;
                }
            }
        }
        this.streams.push(src);
        st.sources = src;
    }

    // The runtime's sounds of one player this frame (see the header).
    private sound(st: PlayerSounds, out: AudioOut, held: bool): void {
        const p = st.player;
        const a = p.audio;
        if (a == null) return;
        const rate = out.sampleRate();
        const now = out.clockFrame();
        const pause = a.paused || held;
        const src = st.sources;
        this.promoteBegun(st, out);
        if (pause != st.paused) this.pauseSounds(st, out, pause);
        for (let i = 0; i < a.voices.length; i++) {
            const v = unchecked(a.voices[i]);
            if (v.hasGone()) stopGone(v, out);
            if (v.released) {
                // (played to its end on the clock: the device, behind it,
                // plays the end out; and headless, where nothing completes,
                // they go at once)
                if (v.playedOut && now > 0) this.playOut(v, out);
                else stopSounds(v, out);
                if (!v.active) v.clear();
                else v.released = false;
            }
            // (where a play or a seek of this frame put it, before the
            // frame's seconds: once, whether its sounds start or not)
            const fresh = v.fresh;
            v.fresh = false;
            if (!v.active || src == null || !src.found()) continue;
            const panned = src.panned();
            const from = fresh ? v.from : v.position;
            if (!hasCurrent(v)) {
                // (no engine, no start: plays would return nothing)
                if (!(rate > 0)) continue;
                const at = now + AUDIO_START_LEAD * rate;
                if (panned) {
                    v.left = out.start(src.left, at, from, a.gainLeft);
                    v.right = out.start(src.right, at, from, a.gainRight);
                } else {
                    v.centre = out.start(src.centre, at, from, a.gainCentre);
                }
                // (started while paused: the resume shifts startFrame by
                // the whole pause, so it is counted from the pause frame,
                // and the sounds, their start passed, begin at the resume)
                v.startFrame = pause ? st.pausedFrame : at;
                v.startOffset = from;
                if (pause) {
                    pauseSound(out, v.left);
                    pauseSound(out, v.right);
                    pauseSound(out, v.centre);
                }
                continue;
            }
            setVolume(out, v.left, a.gainLeft);
            setVolume(out, v.right, a.gainRight);
            setVolume(out, v.centre, a.gainCentre);
            setVolume(out, v.nextLeft, a.gainLeft);
            setVolume(out, v.nextRight, a.gainRight);
            setVolume(out, v.nextCentre, a.gainCentre);
            if (!pause && rate > 0 && src.stream.loops()) this.loop(v, a, src, out, rate, now);
        }
    }

    // A looping voice's next pass, scheduled at the current one's end
    // frame, and made the current one once the clock reaches it; the passes
    // a stall missed skipped (see the header).
    private loop(v: AudioVoice, a: AudioPlayback, src: StreamSources, out: AudioOut, rate: f64, now: f64): void {
        const s = src.stream;
        const passEnd = streamPassEnd(s);
        if (!(passEnd > 0)) return;
        const begin = streamLoopBegin(s, passEnd);
        const panned = src.panned();
        if (hasNext(v)) {
            if (now < v.nextFrame) return;
            this.promote(v, src, out);
        }
        // (the pass after, in the same frame: a loop down to a frame long
        // is scheduled in time)
        const endFrame = v.startFrame + (passEnd - v.startOffset) * rate;
        if (now < endFrame - AUDIO_LOOP_LOOKAHEAD * rate) return;
        let at = endFrame;
        let from = begin;
        if (endFrame <= now) {
            // The pass ended on the device before its next was scheduled:
            // the next starts the lead from now, where the loop is then.
            at = now + AUDIO_START_LEAD * rate;
            const span = passEnd - begin;
            from = span > 0 ? begin + ((at - endFrame) / rate) % span : begin;
        }
        if (panned) {
            v.nextLeft = out.start(src.left, at, from, a.gainLeft);
            v.nextRight = out.start(src.right, at, from, a.gainRight);
        } else {
            v.nextCentre = out.start(src.centre, at, from, a.gainCentre);
        }
        v.nextFrame = at;
        v.nextOffset = from;
    }

    // Each looping voice's next pass begun by now made the current one,
    // paused or not, before a pause: a pause in the frame it begins holds
    // the pass that sounds, not the one that ended (which a resume would
    // play again from its start, over the loop).
    private promoteBegun(st: PlayerSounds, out: AudioOut): void {
        const a = st.player.audio;
        const src = st.sources;
        if (a == null || src == null || !(out.sampleRate() > 0)) return;
        const now = out.clockFrame();
        for (let i = 0; i < a.voices.length; i++) {
            const v = unchecked(a.voices[i]);
            // (a voice stopped this frame has every sound stopped instead)
            if (v.active && hasNext(v) && now >= v.nextFrame) this.promote(v, src, out);
        }
    }

    // A player's sounds paused (the next passes, not begun, dropped) or
    // resumed where they were.
    private pauseSounds(st: PlayerSounds, out: AudioOut, pause: bool): void {
        const a = st.player.audio;
        if (a == null) return;
        const now = out.clockFrame();
        st.paused = pause;
        if (pause) st.pausedFrame = now;
        for (let i = 0; i < a.voices.length; i++) {
            const v = unchecked(a.voices[i]);
            if (pause) {
                this.dropNext(v, out);
                pauseSound(out, v.left);
                pauseSound(out, v.right);
                pauseSound(out, v.centre);
            } else {
                // (a sound not yet begun at the pause, its start ahead,
                // begins at that start or, past it, at the resume)
                if (v.startFrame > st.pausedFrame) v.startFrame = Math.max(v.startFrame, now);
                else v.startFrame += now - st.pausedFrame;
                resumeSound(out, v.left);
                resumeSound(out, v.right);
                resumeSound(out, v.centre);
            }
        }
    }

    // A player leaving the tree, not to be freed: its sounds paused (the
    // feature's next frame resumes them once it is found in the tree
    // again, find).
    private leave(st: PlayerSounds): void {
        st.away = true;
        const out = this.out;
        if (out == null || st.paused) return;
        this.promoteBegun(st, out);
        this.pauseSounds(st, out, true);
    }

    // The players away from the tree that were freed since: stopped, their
    // sounds with them.
    private dropFreed(): void {
        let i = 0;
        while (i < this.away.length) {
            const st = unchecked(this.away[i]);
            if (goingAway(st.player)) {
                st.player.stop();
                this.silence(st);
                // (the last in its place: the order does not count)
                const last = this.away.length - 1;
                unchecked(this.away[i] = this.away[last]);
                this.away.length = last;
            } else {
                i++;
            }
        }
    }

    // A looping voice's next pass, begun, made the current one: the old
    // pass is at its end, a centred stream whose loop ends inside its file
    // cut there, the others ending by themselves.
    private promote(v: AudioVoice, src: StreamSources, out: AudioOut): void {
        const s = src.stream;
        const passEnd = streamPassEnd(s);
        const cut = !src.panned() && s.duration > 0 && passEnd < s.duration;
        this.endPass(out, v.left, cut);
        this.endPass(out, v.right, cut);
        this.endPass(out, v.centre, cut);
        v.left = v.nextLeft;
        v.right = v.nextRight;
        v.centre = v.nextCentre;
        v.nextLeft = AUDIO_NO_SOUND;
        v.nextRight = AUDIO_NO_SOUND;
        v.nextCentre = AUDIO_NO_SOUND;
        v.startFrame = v.nextFrame;
        v.startOffset = v.nextOffset;
    }

    // An old pass's sound: stopped now when `cut`, else released once the
    // runtime says it completed.
    private endPass(out: AudioOut, sound: i32, cut: bool): void {
        if (sound == AUDIO_NO_SOUND) return;
        if (cut || this.retired >= RETIRING_CAPACITY) {
            out.stop(sound);
            return;
        }
        unchecked(this.retiring[this.retired] = sound);
        this.retired++;
    }

    // The sounds of a voice that played to its stream's end, left to play
    // their end out and released once the runtime completes them (its next
    // pass, not begun, is stopped).
    private playOut(v: AudioVoice, out: AudioOut): void {
        stopGone(v, out);
        this.endPass(out, v.left, false);
        this.endPass(out, v.right, false);
        this.endPass(out, v.centre, false);
        v.left = AUDIO_NO_SOUND;
        v.right = AUDIO_NO_SOUND;
        v.centre = AUDIO_NO_SOUND;
        this.dropNext(v, out);
    }

    // The old passes the runtime completed, released.
    private collectRetired(out: AudioOut): void {
        let i = 0;
        while (i < this.retired) {
            const sound = unchecked(this.retiring[i]);
            if (out.completed(sound)) {
                out.release(sound);
                this.retired--;
                unchecked(this.retiring[i] = this.retiring[this.retired]);
            } else {
                i++;
            }
        }
    }

    // A voice's next pass, not yet begun, dropped (a pause; the resume
    // schedules it again).
    private dropNext(v: AudioVoice, out: AudioOut): void {
        if (v.nextLeft != AUDIO_NO_SOUND) out.stop(v.nextLeft);
        if (v.nextRight != AUDIO_NO_SOUND) out.stop(v.nextRight);
        if (v.nextCentre != AUDIO_NO_SOUND) out.stop(v.nextCentre);
        v.nextLeft = AUDIO_NO_SOUND;
        v.nextRight = AUDIO_NO_SOUND;
        v.nextCentre = AUDIO_NO_SOUND;
    }

    // Every sound of a player stopped and let go (its voices keep their
    // places on the scene's clock).
    private silence(st: PlayerSounds): void {
        const out = this.out;
        const a = st.player.audio;
        if (out == null || a == null) return;
        for (let i = 0; i < a.voices.length; i++) {
            const v = unchecked(a.voices[i]);
            stopSounds(v, out);
            if (!v.active) v.clear();
            else v.released = false;
        }
        st.paused = false;
    }

    // The players and listeners of the instance's tree, again when its
    // structure moved; a player found for the first time owes its autoplay.
    private find(inst: SceneInstance): void {
        const e = treeStructureEpoch();
        if (e == this.epoch) return;
        this.epoch = e;
        inst.tree.walkInto(this.walked, this.stack);
        const old = this.oldStates;
        old.length = 0;
        for (let i = 0; i < this.states.length; i++) {
            const st = this.states[i];
            st.seen = false;
            old.push(st);
        }
        for (let i = 0; i < this.away.length; i++) {
            const st = this.away[i];
            st.seen = false;
            old.push(st);
        }
        this.away.length = 0;
        this.players.length = 0;
        this.finished.length = 0;
        this.states.length = 0;
        this.listeners.length = 0;
        for (let i = 0; i < this.walked.length; i++) {
            const n = this.walked[i];
            const isListener = n instanceof AudioListener3D;
            if (isListener) {
                // (a SubViewport's are its own, as its cameras are)
                if (!underSubViewport(n)) this.listeners.push(n as AudioListener3D);
                continue;
            }
            const isPlayer = n instanceof AudioStreamPlayer3D;
            if (!isPlayer) continue;
            const p = n as AudioStreamPlayer3D;
            let st: PlayerSounds? = null;
            for (let k = 0; k < old.length && st == null; k++) if (old[k].player === p) st = old[k];
            if (st == null) {
                st = new PlayerSounds(p);
                if (p.autoplay) p.startRequested = true;
            } else if (st.away) {
                // (back in the tree: its sounds resume at the next frame,
                // and an autoplay player plays again, as Godot's ENTER_TREE)
                st.away = false;
                if (p.autoplay) p.startRequested = true;
            }
            st.seen = true;
            this.players.push(p);
            this.states.push(st);
            this.finished.push(new SignalEvent(n.pathFrom(inst.tree.root), "finished", Value.nil()));
        }
        // (a player away keeps its paused sounds until it enters the tree
        // again or is freed; one gone without a detach loses them)
        for (let k = 0; k < old.length; k++) {
            const st = old[k];
            if (st.seen) continue;
            if (st.away && !goingAway(st.player)) this.away.push(st);
            else this.silence(st);
        }
        old.length = 0;
    }
}

// Whether `n` is `root` or under it.
function within(n: SceneNode, root: SceneNode): bool {
    let q: SceneNode? = n;
    while (q != null) {
        if (q === root) return true;
        q = q.parent;
    }
    return false;
}

// Whether `n`, or a node above it, is freed or queued to be (queueFree):
// its sounds are not to be resumed.
function goingAway(n: SceneNode): bool {
    let q: SceneNode? = n;
    while (q != null) {
        if (q.queued || q.freed) return true;
        q = q.parent;
    }
    return false;
}

function hasCurrent(v: AudioVoice): bool {
    return v.left != AUDIO_NO_SOUND || v.right != AUDIO_NO_SOUND || v.centre != AUDIO_NO_SOUND;
}

function hasNext(v: AudioVoice): bool {
    return v.nextLeft != AUDIO_NO_SOUND || v.nextRight != AUDIO_NO_SOUND || v.nextCentre != AUDIO_NO_SOUND;
}

// The sounds `v` handed off (a play took its place while they played)
// stopped and let go.
function stopGone(v: AudioVoice, out: AudioOut): void {
    if (v.goneLeft != AUDIO_NO_SOUND) out.stop(v.goneLeft);
    if (v.goneRight != AUDIO_NO_SOUND) out.stop(v.goneRight);
    if (v.goneCentre != AUDIO_NO_SOUND) out.stop(v.goneCentre);
    if (v.goneNextLeft != AUDIO_NO_SOUND) out.stop(v.goneNextLeft);
    if (v.goneNextRight != AUDIO_NO_SOUND) out.stop(v.goneNextRight);
    if (v.goneNextCentre != AUDIO_NO_SOUND) out.stop(v.goneNextCentre);
    v.goneLeft = AUDIO_NO_SOUND;
    v.goneRight = AUDIO_NO_SOUND;
    v.goneCentre = AUDIO_NO_SOUND;
    v.goneNextLeft = AUDIO_NO_SOUND;
    v.goneNextRight = AUDIO_NO_SOUND;
    v.goneNextCentre = AUDIO_NO_SOUND;
}

// Every sound of `v` stopped and let go (the gone ones too).
function stopSounds(v: AudioVoice, out: AudioOut): void {
    stopGone(v, out);
    if (v.left != AUDIO_NO_SOUND) out.stop(v.left);
    if (v.right != AUDIO_NO_SOUND) out.stop(v.right);
    if (v.centre != AUDIO_NO_SOUND) out.stop(v.centre);
    if (v.nextLeft != AUDIO_NO_SOUND) out.stop(v.nextLeft);
    if (v.nextRight != AUDIO_NO_SOUND) out.stop(v.nextRight);
    if (v.nextCentre != AUDIO_NO_SOUND) out.stop(v.nextCentre);
    v.left = AUDIO_NO_SOUND;
    v.right = AUDIO_NO_SOUND;
    v.centre = AUDIO_NO_SOUND;
    v.nextLeft = AUDIO_NO_SOUND;
    v.nextRight = AUDIO_NO_SOUND;
    v.nextCentre = AUDIO_NO_SOUND;
}

function pauseSound(out: AudioOut, sound: i32): void {
    if (sound != AUDIO_NO_SOUND) out.pause(sound);
}

function resumeSound(out: AudioOut, sound: i32): void {
    if (sound != AUDIO_NO_SOUND) out.resume(sound);
}

function setVolume(out: AudioOut, sound: i32, volume: f32): void {
    if (sound != AUDIO_NO_SOUND) out.setVolume(sound, volume);
}

// Adds the audio feature to `rt` (newSceneRuntime(), and the module's
// generated features.as when the bundle's scenes use it).
export function installAudioFeature(rt: SceneRuntime): void {
    rt.install(new AudioFeature());
}
