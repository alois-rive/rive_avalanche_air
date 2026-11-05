// A playing LinearAnimation (milestone 45): Rive's LinearAnimationInstance
// (rive-runtime src/animation/linear_animation_instance.cpp), ported with
// its f32 arithmetic: the time accumulated by speed, wrapped, clamped or
// reflected by the loop mode inside the work area, the spilled time kept,
// and the KeyFrameCallbacks crossed reported (Rive's reportKeyedCallbacks,
// with its rules at the start frame, after a loop and backwards). Quantize
// is applied where Rive applies it, when the keys are evaluated
// (./animation.as LinearAnimation.applyTime).
//
// The instance knows times, not nodes: ./scene_anims.as applies it to a
// tree (SceneAnimations.apply), and the callbacks crossed go to a
// CallbackSink. It also keeps, per track, the key the last apply found
// (`hints`), so that a frame moving forward finds its keys without a
// search.

import { CallbackReporter, LinearAnimation } from "./animation";
import { LoopMode } from "./decl";

// Where an advance reports the callbacks it crossed: the keyed object's
// index and the track's index in the animation (LinearAnimation.objects,
// KeyedObjectTracks.tracks), and the seconds since the key (Rive's
// elapsedSeconds - keyframe seconds, for the event's delay).
export abstract class CallbackSink extends CallbackReporter {
    abstract callback(objectIndex: i32, trackIndex: i32, delaySeconds: f32): void;
}

// A pingPong step longer than this many periods (2 * range) is folded
// before bouncing; and no step bounces more than PINGPONG_BOUNCES times.
const PINGPONG_FOLD: f32 = 64;
const PINGPONG_BOUNCES = 1024;

export class LinearAnimationInstance {
    animation: LinearAnimation;
    // Rive's m_time, m_totalTime, m_lastTotalTime, m_spilledTime and
    // m_direction (1 or -1: a pingPong going back); didLoop as Rive's, and
    // how many times it was true.
    time: f32 = 0;
    totalTime: f32 = 0;
    lastTotalTime: f32 = 0;
    spilledTime: f32 = 0;
    direction: i32 = 1;
    didLoop: bool = false;
    loopCount: i32 = 0;
    // Rive's speed multiplier (a state's speed): the seconds an advance is
    // given are multiplied by it, and a negative one starts the animation
    // at its end. 1 for every route of this version.
    speed: f32 = 1;
    // Per track (KeyedTrack.flat), the key index the last apply found (-1:
    // none yet).
    hints: StaticArray<i32>;
    // Rive's m_speedDirection.
    private speedDirection: f32 = 1;

    constructor(animation: LinearAnimation, speedMultiplier: f32 = 1) {
        this.animation = animation;
        this.speed = speedMultiplier;
        this.speedDirection = speedMultiplier >= 0 ? 1 : -1;
        this.time = speedMultiplier >= 0 ? animation.startTime() : animation.endTime();
        this.hints = new StaticArray<i32>(animation.trackCount);
        for (let i = 0; i < this.hints.length; i++) unchecked(this.hints[i] = -1);
    }

    // Rive's directedSpeed: the animation's speed with the pingPong's
    // direction.
    directedSpeed(): f32 {
        return <f32>this.direction * this.animation.speed;
    }

    // Rive's advance(seconds, reporter): returns whether the animation
    // keeps going (false once a oneShot has reached its end; also false for
    // a step of no time, as Rive's).
    advance(seconds: f32, sink: CallbackSink? = null): bool {
        const elapsedSeconds: f32 = seconds * this.speed;
        const animation = this.animation;
        const deltaSeconds: f32 = elapsedSeconds * animation.speed * <f32>this.direction;

        this.spilledTime = 0;
        // A step of no time is none (as Rive's); so is one of infinite or
        // NaN time (a script's advance(Infinity), a speed past f32's
        // range): a loop's modulo would make the time NaN, and a pingPong
        // would bounce between -inf and +inf for ever.
        // A finite step can still take the time past f32's frames (an
        // advance(1e37), a 3e38 speed at 120 fps): its frames are infinite
        // and the wrap's modulo NaN for good, so it is none either.
        if (deltaSeconds == 0 || !isFinite(deltaSeconds) || !isFinite(elapsedSeconds)
            || !isFinite((this.time + deltaSeconds) * <f32>animation.fps)) {
            this.didLoop = false;
            return false;
        }

        this.lastTotalTime = this.totalTime;
        this.totalTime += Mathf.abs(deltaSeconds);

        // (Rive: spilled time is not tracked once a one-shot is complete)
        const killSpilledTime = !this.keepGoingBy(elapsedSeconds);

        let lastTime = this.time;
        this.time += deltaSeconds;
        if (sink != null) animation.reportKeyedCallbacks(sink, lastTime, this.time, this.speedDirection, false);

        const fps = <f32>animation.fps;
        let frames: f32 = this.time * fps;
        const start: f32 = animation.enableWorkArea ? <f32>animation.workStart : 0;
        const end: f32 = animation.enableWorkArea ? <f32>animation.workEnd : <f32>animation.duration;
        const range: f32 = end - start;

        let didLoop = false;
        let direction = deltaSeconds < 0 ? -1 : 1;
        const loop = animation.loop;
        if (range <= 0 && loop != LoopMode.OneShot) {
            // A loop or pingPong over no frames (or a reversed work area)
            // has nothing to wrap over: the loop's modulo would give NaN
            // and the pingPong's bounce would never land inside the range.
            // The check refuses such ranges; this keeps a scene that slips
            // past it (a script, a hand-built animation) from freezing.
            frames = start;
            this.time = frames / fps;
        } else if (loop == LoopMode.OneShot) {
            if (direction == 1 && frames > end) {
                // The spilled time is the share of the step past the end,
                // in the step's own (speed-scaled) frames.
                const deltaFrames: f32 = deltaSeconds * fps;
                const spilledFramesRatio: f32 = (frames - end) / deltaFrames;
                this.spilledTime = spilledFramesRatio * elapsedSeconds;
                frames = end;
                this.time = frames / fps;
                didLoop = true;
            } else if (direction == -1 && frames < start) {
                const deltaFrames: f32 = Mathf.abs(deltaSeconds * fps);
                const spilledFramesRatio: f32 = (start - frames) / deltaFrames;
                this.spilledTime = spilledFramesRatio * elapsedSeconds;
                frames = start;
                this.time = frames / fps;
                didLoop = true;
            }
        } else if (loop == LoopMode.Loop) {
            if (direction == 1 && frames >= end) {
                const deltaFrames: f32 = deltaSeconds * fps;
                const remainder: f32 = (frames - start) % range;
                const spilledFramesRatio: f32 = remainder / deltaFrames;
                this.spilledTime = spilledFramesRatio * elapsedSeconds;
                frames = start + remainder;
                this.time = frames / fps;
                didLoop = true;
                if (sink != null) animation.reportKeyedCallbacks(sink, 0, this.time, this.speedDirection, false);
            } else if (direction == -1 && frames <= start) {
                const deltaFrames: f32 = deltaSeconds * fps;
                const remainder: f32 = Mathf.abs((start - frames) % range);
                const spilledFramesRatio: f32 = Mathf.abs(remainder / deltaFrames);
                this.spilledTime = spilledFramesRatio * elapsedSeconds;
                frames = end - remainder;
                this.time = frames / fps;
                didLoop = true;
                if (sink != null) animation.reportKeyedCallbacks(sink, end / fps, this.time, this.speedDirection, false);
            }
        } else {
            let fromPong = true;
            // A step many ranges long (a speed of 1e30) is folded first:
            // every 2 * range of overshoot is two bounces that land where
            // they started, going the same way, so dropping whole periods
            // keeps the place and the direction. Past f32's resolution the
            // bounces below would never shrink the overshoot. Steps under
            // PINGPONG_FOLD periods bounce one by one, as Rive's do, each
            // reporting its callbacks.
            const period: f32 = 2 * range;
            if (direction == 1 && frames - end > period * PINGPONG_FOLD) {
                frames = end + (frames - end) % period;
                this.time = frames / fps;
                didLoop = true;
            } else if (direction == -1 && start - frames > period * PINGPONG_FOLD) {
                frames = start - (start - frames) % period;
                this.time = frames / fps;
                didLoop = true;
            }
            let bounces = 0;
            while (true) {
                if (bounces++ >= PINGPONG_BOUNCES) {
                    // (unreachable after the fold; kept so that no rounding
                    // can freeze the run time)
                    frames = Mathf.min(Mathf.max(frames, start), end);
                    this.time = frames / fps;
                    break;
                }
                if (direction == 1 && frames >= end) {
                    this.spilledTime = (frames - end) / fps;
                    frames = end + (end - frames);
                    lastTime = end / fps;
                } else if (direction == -1 && frames < start) {
                    this.spilledTime = (start - frames) / fps;
                    frames = start + (start - frames);
                    lastTime = start / fps;
                } else {
                    // Within the range: done (a loop, as a long step may
                    // bounce more than once).
                    break;
                }
                this.time = frames / fps;
                this.direction *= -1;
                direction *= -1;
                didLoop = true;
                if (sink != null) animation.reportKeyedCallbacks(sink, lastTime, this.time, this.speedDirection, fromPong);
                fromPong = !fromPong;
            }
        }

        if (killSpilledTime) this.spilledTime = 0;
        this.didLoop = didLoop;
        if (didLoop) this.loopCount++;
        return this.keepGoingBy(elapsedSeconds);
    }

    // Rive's time(value): moves the playhead (seconds, not wrapped: the
    // next advance wraps), keeping the total times in step and the
    // direction forward. (Rive's start here is the work area's start in
    // frames times the fps, kept as written.)
    setTime(seconds: f32): void {
        // (a time of infinity or NaN is no place on the timeline: ignored;
        // so is one whose frames f32 cannot hold, 1e38 s at 60 fps)
        if (this.time == seconds || !isFinite(seconds) || !isFinite(seconds * <f32>this.animation.fps)) return;
        this.time = seconds;
        const diff = this.totalTime - this.lastTotalTime;
        const a = this.animation;
        const start: f32 = (a.enableWorkArea ? <f32>a.workStart : <f32>0) * <f32>a.fps;
        this.totalTime = seconds - start;
        this.lastTotalTime = this.totalTime - diff;
        this.direction = 1;
    }

    // The frames at the animation's fps.
    setTimeFrames(frames: f32): void {
        this.setTime(frames / <f32>this.animation.fps);
    }

    // A fraction 0 to 1 of the duration, from the start (Rive's script
    // Animation.setTimePercentage).
    setTimePercentage(fraction: f32): void {
        this.setTime(this.animation.startSeconds() + fraction * this.animation.durationSeconds());
    }

    // Rive's keepGoing: a loop or pingPong always; a oneShot until its end
    // (its start, backwards).
    keepGoing(): bool {
        return this.keepGoingBy(1);
    }

    // Rive's keepGoing(speedMultiplier).
    keepGoingBy(multiplier: f32): bool {
        const a = this.animation;
        if (a.loop != LoopMode.OneShot) return true;
        const s = this.directedSpeed() * multiplier;
        return (s > 0 && this.time < a.endSeconds()) || (s < 0 && this.time > a.startSeconds());
    }

    // Starts again from the start (the end for a negative speed). Rive's
    // reset sets only the time, for an instance its state machine made
    // anew on entering the state; this one is played again in place, so
    // the direction, the totals and the counts start again too, and the
    // keys found are forgotten.
    reset(): void {
        this.time = this.speed >= 0 ? this.animation.startTime() : this.animation.endTime();
        this.totalTime = 0;
        this.lastTotalTime = 0;
        this.spilledTime = 0;
        this.direction = 1;
        this.didLoop = false;
        this.loopCount = 0;
        for (let i = 0; i < this.hints.length; i++) unchecked(this.hints[i] = -1);
    }
}
