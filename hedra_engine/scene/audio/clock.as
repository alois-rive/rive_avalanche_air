// Milestone 36: the scene's clock for its sounds (docs/engine/AUDIO.md
// "The clock"): every AudioStreamPlayer3D's playbacks moved by the frame's
// seconds, on the scene's clock and not the audio device's, so the tools
// know where every playback is without playing it and `finished` comes at
// the same frame in `hedra render --time`, the editor's readouts, Play and
// a built project. The run time's feature calls advancePlayer for each
// player every frame (after the scripts); the tools call audioAtTime.
//
// Per player and frame, in this order:
//   1. the plays the property and autoplay owe (startRequested): play(0);
//   2. stream_paused: paused playbacks do not move (AudioPlayback.paused
//      follows it, for the feature to pause and resume the sounds);
//   3. each active voice's position += seconds (Godot's pitch_scale is not
//      applied: audio-pitch); at the stream's end (its duration; unknown,
//      -1, never ends) a looping stream wraps into [loop_begin, loop_end]
//      (loop_end -1: the duration; a loop of no length holds at its
//      begin; ping-pong and backward play forward: audio-loop-mode), a
//      stream that does not loop ends: the voice stops, finishedPending is
//      set (once a frame however many ended, as Godot emits `finished`
//      once a frame), and when it was the last the node's `playing` reads
//      false (AudioStreamPlayer3D.endedAll).
// An invisible player plays on (Godot's do too). A frame of 0 seconds (a
// paused scene) moves nothing, but the owed starts are taken. A start and
// the frame's seconds are one step, so the first frame of a host and the
// tools' clock's first step agree (60 frames of 1/60 s leave a voice
// begun on the first at 1 s); the voice keeps where it was played from
// (AudioVoice.from), and a built project's sounds start there, the clock
// running that frame ahead of the device. The seconds are the frame's
// own: the run time does not scale them by the Scene3D's speed.

import { AudioStreamPlayer3D, SceneNode } from "../tree/node";
import { SceneTree } from "../tree/tree";
import { AudioStream } from "../resource/audio_stream";
import { AUDIO_SILENT_DB, AUDIO_TOOL_STEP } from "./state";
import { ListenerPose } from "./listener";
import { AudioGains, playerGains } from "./attenuation";

// The longest time the tools' clock runs (as the particles' clock's).
export const AUDIO_TOOL_MAX_TIME: f64 = 3600;

// What audioAtTime ran: the players, those playing at the end, their
// active voices, the steps and the time they make.
export class AudioRun {
    players: i32 = 0;
    playing: i32 = 0;
    voices: i32 = 0;
    steps: i32 = 0;
    time: f64 = 0;
}

// The AudioStreamPlayer3D nodes of `walked` (a tree walk) into `out`
// (cleared first); their number.
export function audioPlayers(walked: Array<SceneNode>, out: Array<AudioStreamPlayer3D>): i32 {
    out.length = 0;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isPlayer = n instanceof AudioStreamPlayer3D;
        if (isPlayer) out.push(n as AudioStreamPlayer3D);
    }
    return out.length;
}

// The shortest loop a built project plays without gaps, in seconds: the
// run time schedules a loop's next pass once a frame (feature_audio.as),
// so a pass shorter than a frame ends before the next can be scheduled;
// 0.05 s is a frame of a 20 fps host (`audio-loop-short` warns below it).
export const AUDIO_LOOP_SHORTEST: f64 = 0.05;

// The end of a pass of `s` in seconds: a looping stream's loop end (its
// duration when the loop's end is -1 or past it), else its duration; -1
// when not known.
export function streamPassEnd(s: AudioStream): f64 {
    const d = s.duration;
    if (!s.loops()) return d;
    const e = s.loopEnd;
    if (e >= 0 && (d < 0 || e < d)) return e;
    return d;
}

// Where a looping pass of `s` after the first begins, in seconds, given
// its pass end `passEnd`: its loop's begin, or 0 when that is at or past
// the end (Godot's rule: an MP3's or Ogg's seek at or past the length
// goes to 0; a begin there would start a pass every frame and never end).
export function streamLoopBegin(s: AudioStream, passEnd: f64): f64 {
    const b = s.loopBegin;
    return b > 0 && b < passEnd ? b : 0;
}

// How near a looping voice's position may come to its loop's end before it
// wraps, in seconds: a thousandth of a sample at 48 kHz, far above what
// summing frames of 1/60 s loses (about 1e-16 s a frame) and far below
// anything heard.
export const AUDIO_LOOP_EPSILON: f64 = 2e-8;

// One frame of `seconds` for `p` (steps 1 to 3 above); whether anything it
// plays changed (a playback began, ended or was stopped). Allocates
// nothing once its AudioPlayback is made.
export function advancePlayer(p: AudioStreamPlayer3D, seconds: f64): bool {
    let changed = false;
    if (p.startRequested) {
        p.startRequested = false;
        p.play(0);
        changed = true;
    }
    const a = p.audio;
    if (a == null) return changed;
    a.paused = p.streamPaused;
    if (a.paused || !(seconds > 0)) return changed;
    const s = p.stream;
    const loops = s != null && s.loops();
    const end = s != null ? streamPassEnd(s) : -1;
    const begin = s != null ? streamLoopBegin(s, end) : 0;
    let ended = 0;
    const voices = a.voices;
    for (let i = 0; i < voices.length; i++) {
        const v = unchecked(voices[i]);
        if (!v.active) continue;
        v.position += seconds;
        if (end < 0) continue;
        if (loops) {
            // (frames of 1/60 s summed fall a hair short of a loop's end
            // that a whole number of them reaches: wrapped within
            // AUDIO_LOOP_EPSILON of it, the readout at the boundary is the
            // loop's begin, as Godot's, not its end)
            if (v.position < end - AUDIO_LOOP_EPSILON) continue;
            const span = end - begin;
            const over = v.position > end ? v.position - end : 0;
            v.position = span > 0 ? begin + over % span : begin;
        } else if (v.position < end) {
            continue;
        } else {
            a.endVoice(v);
            ended++;
        }
    }
    if (ended > 0) {
        a.finishedPending = true;
        if (a.activeCount() == 0) p.endedAll();
        changed = true;
    }
    return changed;
}

// Every player of `walked` advanced by `seconds`; how many changed.
export function advanceTreeAudio(walked: Array<SceneNode>, seconds: f64): i32 {
    let changed = 0;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isPlayer = n instanceof AudioStreamPlayer3D;
        if (isPlayer && advancePlayer(n as AudioStreamPlayer3D, seconds)) changed++;
    }
    return changed;
}

// The tools' start of a player: no playback, and one owed when it
// autoplays or its file's `playing` is true (as a host's first frame).
export function toolsStartPlayer(p: AudioStreamPlayer3D): void {
    const a = p.audio;
    if (a != null) {
        a.stopAll();
        for (let i = 0; i < a.voices.length; i++) a.voices[i].clear();
        a.finishedPending = false;
    }
    p.startRequested = p.autoplay || p.playingProp;
}

// The steps `seconds` takes on the tools' clock (1/60 s each, rounded),
// held to AUDIO_TOOL_MAX_TIME.
export function audioToolSteps(seconds: f64): i32 {
    if (!(seconds > 0)) return 0;
    const t = seconds < AUDIO_TOOL_MAX_TIME ? seconds : AUDIO_TOOL_MAX_TIME;
    return <i32>Math.round(t / AUDIO_TOOL_STEP);
}

// Whether `p` is heard now: a playback plays and is not paused.
export function playerSounding(p: AudioStreamPlayer3D): bool {
    const a = p.audio;
    return a != null && !a.paused && a.activeCount() > 0;
}

// What `listener` (null or not valid: none, silent) hears of `p` into `g`
// (playerGains, computed whether it plays or not, for the readouts), then
// the node's outputs (listener_volume_db, listener_pan) and its playback's
// gains: what it hears while a playback sounds, else -80 dB, pan 0 and
// gains 0 (Godot's player is silent when it does not play or is paused).
// Allocates nothing.
export function hearPlayer(p: AudioStreamPlayer3D, listener: ListenerPose?, g: AudioGains): void {
    const heard = listener != null && listener.valid;
    if (heard) {
        playerGains(p, listener!, g);
    } else {
        g.gain = 0;
        g.db = AUDIO_SILENT_DB;
        g.left = 0;
        g.right = 0;
        g.centre = 0;
        g.pan = 0;
        g.distance = 0;
    }
    const on = heard && playerSounding(p);
    p.listenerVolumeDb = on ? g.db : AUDIO_SILENT_DB;
    p.listenerPan = on ? g.pan : 0;
    const a = p.audio;
    if (a == null) return;
    a.heard = heard;
    a.distance = g.distance;
    a.volumeDb = p.listenerVolumeDb;
    a.pan = p.listenerPan;
    a.gainLeft = on ? g.left : 0;
    a.gainRight = on ? g.right : 0;
    a.gainCentre = on ? g.centre : 0;
}

// `tree`'s players started as a host's first frame starts them, then
// advanced `seconds` on the tools' clock, and the outputs set for
// `listener` (null: silent) at the end. A tree without a player is left as
// it is.
export function audioAtTime(tree: SceneTree, seconds: f64, listener: ListenerPose?): AudioRun {
    const run = new AudioRun();
    const walked = tree.walk();
    const players = new Array<AudioStreamPlayer3D>();
    run.players = audioPlayers(walked, players);
    if (run.players == 0) return run;
    for (let i = 0; i < players.length; i++) toolsStartPlayer(players[i]);
    const steps = audioToolSteps(seconds);
    // (the starts at time 0, then each step)
    advanceTreeAudio(walked, 0);
    for (let k = 0; k < steps; k++) advanceTreeAudio(walked, AUDIO_TOOL_STEP);
    run.steps = steps;
    run.time = <f64>steps * AUDIO_TOOL_STEP;
    const g = new AudioGains();
    for (let i = 0; i < players.length; i++) {
        const p = players[i];
        hearPlayer(p, listener, g);
        const a = p.audio;
        const n = a != null ? a.activeCount() : 0;
        if (n > 0) run.playing++;
        run.voices += n;
    }
    return run;
}
