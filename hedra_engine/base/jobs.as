// Jobs: work cut into units that may run in any order, on any number of
// workers, and still give the same bytes (docs/engine/JOBS.md).
//
// The vocabulary, the engine's and the compiler's alike:
//   - a job is a piece of work over an index range [0, count): a frame's
//     items culled, an occlusion buffer's rows filled, a frame's emitters
//     advanced; the build's scenes planned, assets imported, scenes built;
//   - a unit is one slice of it, run whole by one worker: here items
//     [unitBegin(u), unitEnd(u)) of a fixed `grain` (the slices depend on
//     the count and the grain alone, never on how many workers there are);
//     in the build (compiler/src/build/budget.as) one scene planned, one
//     asset imported or one scene built;
//   - an executor runs a job's units: SerialExecutor one after the other on
//     the calling thread, AtomicExecutor by workers claiming the next unit
//     from a shared counter (fetch-and-add) and counting the units done;
//     the build's runs them in order and its gate (UnitGate, the session
//     budget) may stop before a unit, the rest going to a fresh instance of
//     the program (the respawn hand-over), which resumes at that unit.
//
// The rules that make a job's output the same whatever runs it:
//   1. a unit writes only what is its own: the outputs of its items (a
//      slot by item index), or its unit's slot (UnitCounts, or arrays a job
//      keeps by unit); never a total shared with another unit;
//   2. totals are merged after the run, by unit in unit order (integer
//      sums are the same in any order; floating-point ones and lists are
//      not, which is why the merge is ordered and the slices fixed);
//   3. a unit's scratch is its worker's (the `worker` argument, 0 to
//      workers() - 1), never module state that another worker could be
//      writing at the same time;
//   4. what every unit reads is made before the run (the job's fields),
//      and nothing a unit writes is read by another unit of the same run.
// A job that writes only by item (rule 1) may also cut its range by the
// executor's workers() (the occlusion buffer's bands): its output does not
// depend on the cut either, as the tests check for every such job.
//
// Threads (docs/engine/JOBS.md, "Threads and atomics"): the AnimaScript
// compiler knows no atomic instruction on the module's own memory. Rive's
// script threads (rive 1.8.0, docs/milestones/TOOLCHAIN-1.8.md) run a
// `@job` function in a lane: an instance of the module of its own, sharing
// memory only through shared objects. The jobs that are worth it on lanes
// are LaneJobs (below), run by a lane executor (LaneExecutorBase) that
// render/lanes.as builds on those threads and the Scene3D component
// installs here, in every built Rive project. The AtomicExecutor is the same
// claiming within one memory, on the calling thread: its counter
// operations are plain loads and stores (`atomic.add` and `atomic.load`
// once the compiler has them), and its tests take several workers in
// turn, so that every job cut by workers is cut as on several threads.
//
// Allocation: running a job allocates nothing (no closure, no array; the
// executors keep their control block from the start), and UnitCounts keeps
// its storage for the most units it held.

// The executors (setJobExecutor).
export const EXECUTOR_SERIAL: i32 = 0;
export const EXECUTOR_ATOMIC: i32 = 1;
// Rive's script threads: the lane executor of render/lanes.as (installed
// by installLaneExecutor, as the Scene3D component does; the serial
// executor where none is installed).
export const EXECUTOR_LANES: i32 = 2;
// The executor jobs() is until setJobExecutor: the one switch. The lanes
// under a runtime that collects (`wasmRuntime: frame`: every built Rive
// project, where each run's lane handles and results are given back at
// the frame's end), the serial executor under the stub runtime, which
// never frees (the command-line tool and the editors, whose frames must not
// grow their heap). The lane executor runs a job serially when the pool
// has no thread, and is the serial one where it is not built in.
export const JOB_EXECUTOR_DEFAULT: i32 = ASC_RUNTIME == 3 ? EXECUTOR_LANES : EXECUTOR_SERIAL;
// The most workers an executor has (a job's scratch by worker is sized to
// it at most).
export const MAX_JOB_WORKERS: i32 = 16;

// A job: its units run by an executor (Executor.run). A subclass holds what
// its units read and write as fields, set before the run.
export abstract class Job {
    // Runs unit `unit`, items [begin, end) of the range, on worker `worker`.
    abstract runUnit(unit: i32, begin: i32, end: i32, worker: i32): void;
}

// How many units a range of `count` items cuts into at `grain` items a
// unit (a grain under 1 is 1): 0 for an empty range.
export function unitCount(count: i32, grain: i32): i32 {
    if (count <= 0) return 0;
    const g = grain < 1 ? 1 : grain;
    return (count - 1) / g + 1;
}

// The first item of unit `unit` at `grain`.
@inline
export function unitBegin(unit: i32, grain: i32): i32 {
    return unit * (grain < 1 ? 1 : grain);
}

// One past the last item of unit `unit` of a range of `count` at `grain`.
@inline
export function unitEnd(unit: i32, count: i32, grain: i32): i32 {
    const e = (unit + 1) * (grain < 1 ? 1 : grain);
    return e < count ? e : count;
}

// The grain that cuts `count` items into `parts` units at most (one each
// for a job cut by workers: a band of rows a worker).
export function grainFor(count: i32, parts: i32): i32 {
    if (count <= 0) return 1;
    const p = parts < 1 ? 1 : parts;
    return (count - 1) / p + 1;
}

// Runs jobs.
export abstract class Executor {
    // The workers that run units at once (1: the calling thread alone). A
    // job that cuts its range by workers reads it before the run.
    abstract workers(): i32;
    // Runs every unit of `job` over [0, count) at `grain` items a unit, and
    // returns when all are done (the units in any order, on any worker).
    abstract run(job: Job, count: i32, grain: i32): void;
    // Whether its workers are lanes, each a start and a copy of the job's
    // input (LaneExecutorBase): a job then cuts its range by workers only
    // when it is big enough to gain from them (the occlusion buffer's
    // OCCLUSION_LANE_SETUP triangles).
    startsLanes(): bool {
        return false;
    }
}

// The units one after the other, in order, on the calling thread
// (worker 0): what a frame did before jobs, plus one call a unit.
export class SerialExecutor extends Executor {
    workers(): i32 {
        return 1;
    }

    run(job: Job, count: i32, grain: i32): void {
        const units = unitCount(count, grain);
        for (let u = 0; u < units; u++) job.runUnit(u, unitBegin(u, grain), unitEnd(u, count, grain), 0);
    }
}

// The control block's words (AtomicExecutor.ctl), each written by the
// counter operations alone once a job is posted.
const CTL_NEXT = 0; // the next unit to claim
const CTL_DONE = 1; // the units done
const CTL_UNITS = 2; // the posted job's units
const CTL_COUNT = 3; // its range
const CTL_GRAIN = 4; // its grain
const CTL_EPOCH = 5; // moved by every post: a helper's sign of a new job
const CTL_WORDS = 8;

// The counter operations: atomic read-modify-writes on the control block.
// Plain loads and stores today (one thread; the pinned compiler has no
// atomic instruction: docs/engine/JOBS.md); with threads, fetchAdd is
// `atomic.add<i32>` (Atomics.add), loadWord `atomic.load<i32>` and
// storeWord `atomic.store<i32>` on the same addresses, sequentially
// consistent, which is all the executor asks of them.
@inline
function fetchAdd(ctl: StaticArray<i32>, word: i32, v: i32): i32 {
    const old = unchecked(ctl[word]);
    unchecked(ctl[word] = old + v);
    return old;
}

@inline
function loadWord(ctl: StaticArray<i32>, word: i32): i32 {
    return unchecked(ctl[word]);
}

@inline
function storeWord(ctl: StaticArray<i32>, word: i32, v: i32): void {
    unchecked(ctl[word] = v);
}

// Units claimed from a shared counter: each worker takes the next unit with
// a fetch-and-add on CTL_NEXT until none is left, and counts it done with
// one on CTL_DONE; the run is over when CTL_DONE reaches the units. No lock:
// two counters a unit, whatever the number of workers.
//
// The calling thread posts the job (post), works it as worker 0 (claim
// until false) and waits for the others (finish). A helper thread, once a
// host has them, attaches (attachHelper: its worker index) and, at each new
// epoch, claims units of the posted job as its worker (help). On one thread
// `simulated` workers are taken in turn by the caller, a unit each, so that
// the claiming, the counting and the jobs cut by workers() are tested as
// they would run on several.
export class AtomicExecutor extends Executor {
    private ctl: StaticArray<i32> = new StaticArray<i32>(CTL_WORDS);
    private job: Job? = null;
    private helpers: i32 = 0;
    private simulated: i32;
    // Units run by each worker in the last run (for the tests).
    ranBy: StaticArray<i32> = new StaticArray<i32>(MAX_JOB_WORKERS);

    // `simulated` workers taken in turn on the calling thread (1: the
    // caller works alone, as with no helper thread).
    constructor(simulated: i32 = 1) {
        super();
        this.simulated = simulated < 1 ? 1 : simulated > MAX_JOB_WORKERS ? MAX_JOB_WORKERS : simulated;
    }

    workers(): i32 {
        const w = this.simulated + this.helpers;
        return w > MAX_JOB_WORKERS ? MAX_JOB_WORKERS : w;
    }

    // A helper thread's worker index (1 on), or -1 when there are
    // MAX_JOB_WORKERS already. Only a host that runs threads calls it.
    attachHelper(): i32 {
        if (this.workers() >= MAX_JOB_WORKERS) return -1;
        this.helpers++;
        return this.workers() - 1;
    }

    run(job: Job, count: i32, grain: i32): void {
        this.post(job, count, grain);
        const sim = this.simulated;
        if (sim == 1) {
            while (this.claim(0)) {}
        } else {
            // (the simulated workers in turn, a unit each)
            let w = 0;
            while (this.claim(w)) w = w + 1 == sim ? 0 : w + 1;
        }
        this.finish();
    }

    // Posts `job` for the workers: its range and grain, the counters at 0,
    // then the epoch moved (last: a helper that sees it sees the rest).
    post(job: Job, count: i32, grain: i32): void {
        const ctl = this.ctl;
        const g = grain < 1 ? 1 : grain;
        this.job = job;
        for (let w = 0; w < MAX_JOB_WORKERS; w++) unchecked(this.ranBy[w] = 0);
        storeWord(ctl, CTL_COUNT, count);
        storeWord(ctl, CTL_GRAIN, g);
        storeWord(ctl, CTL_UNITS, unitCount(count, g));
        storeWord(ctl, CTL_NEXT, 0);
        storeWord(ctl, CTL_DONE, 0);
        fetchAdd(ctl, CTL_EPOCH, 1);
    }

    // Claims the next unit of the posted job and runs it as `worker`; false
    // when every unit is claimed (a claim past the last leaves the counter
    // past it, which no one reads as a unit).
    claim(worker: i32): bool {
        const ctl = this.ctl;
        const units = loadWord(ctl, CTL_UNITS);
        if (loadWord(ctl, CTL_NEXT) >= units) return false;
        const u = fetchAdd(ctl, CTL_NEXT, 1);
        if (u >= units) return false;
        const job = this.job;
        if (job == null) return false;
        const count = loadWord(ctl, CTL_COUNT);
        const grain = loadWord(ctl, CTL_GRAIN);
        job.runUnit(u, unitBegin(u, grain), unitEnd(u, count, grain), worker);
        if (worker >= 0 && worker < MAX_JOB_WORKERS) unchecked(this.ranBy[worker] = unchecked(this.ranBy[worker]) + 1);
        fetchAdd(ctl, CTL_DONE, 1);
        return true;
    }

    // A helper's share of the posted job: units claimed as `worker` until
    // none is left; how many it ran.
    help(worker: i32): i32 {
        let n = 0;
        while (this.claim(worker)) n++;
        return n;
    }

    // The epoch of the job posted last (a helper waits for it to move).
    epoch(): i32 {
        return loadWord(this.ctl, CTL_EPOCH);
    }

    // Waits until every unit of the posted job is done (at once on one
    // thread: the caller ran them all), then lets the job go.
    finish(): void {
        const ctl = this.ctl;
        const units = loadWord(ctl, CTL_UNITS);
        // (a helper still running its last unit: wait for its count)
        while (loadWord(ctl, CTL_DONE) < units) {}
        this.job = null;
    }

    // The units done in the last run, and how many it had (for the tests).
    unitsDone(): i32 {
        return loadWord(this.ctl, CTL_DONE);
    }

    unitsPosted(): i32 {
        return loadWord(this.ctl, CTL_UNITS);
    }
}

// Counters by unit, merged in unit order: a job's totals (rule 2 of the
// header). `fields` counters a unit; prepare() before the run, add() in a
// unit, total() and most() after it. Keeps its storage.
export class UnitCounts {
    fields: i32;
    units: i32 = 0;
    private data: Array<i64> = [];

    constructor(fields: i32) {
        this.fields = fields < 1 ? 1 : fields;
    }

    // Room for `units` units, every counter 0.
    prepare(units: i32): void {
        const n = (units < 0 ? 0 : units) * this.fields;
        if (this.data.length < n) this.data.length = n;
        for (let i = 0; i < n; i++) unchecked(this.data[i] = 0);
        this.units = units < 0 ? 0 : units;
    }

    @inline
    add(unit: i32, field: i32, v: i64): void {
        const i = unit * this.fields + field;
        unchecked(this.data[i] = unchecked(this.data[i]) + v);
    }

    // Raises the counter to `v` when it is less.
    @inline
    raise(unit: i32, field: i32, v: i64): void {
        const i = unit * this.fields + field;
        if (v > unchecked(this.data[i])) unchecked(this.data[i] = v);
    }

    get(unit: i32, field: i32): i64 {
        return unchecked(this.data[unit * this.fields + field]);
    }

    // The sum over the units, in unit order.
    total(field: i32): i64 {
        let s: i64 = 0;
        for (let u = 0; u < this.units; u++) s += unchecked(this.data[u * this.fields + field]);
        return s;
    }

    // The most of the units' (0 for none).
    most(field: i32): i64 {
        let m: i64 = 0;
        for (let u = 0; u < this.units; u++) {
            const v = unchecked(this.data[u * this.fields + field]);
            if (u == 0 || v > m) m = v;
        }
        return m;
    }
}

// What may stop an ordered run of units before one of them (the build's
// session budget, compiler/src/build/budget.as: the units it does not run
// go to a fresh instance of the program, which resumes at the first of
// them).
export abstract class UnitGate {
    // Whether the next unit, estimated to take `estimate` bytes (0: not
    // known), is to run elsewhere: the run stops before it.
    abstract due(estimate: i64): bool;
    // A unit was run.
    abstract done(): void;
}

// ---------------------------------------------------------------------------
// Jobs on Rive's script threads (docs/engine/JOBS.md, "Script threads")
//
// Rive runs a `@job` function in a lane of its own, a fresh instance of
// the module with its own memory, on a pool of threads; lanes share
// memory only through shared objects (bytes fixed once made, and regions
// whose words have atomic operations). The executor that uses them is
// render/lanes.as (on `rive/jobs` and `rive/shared`), installed here by
// installLaneExecutor. What the engine says of a job that can run so is
// below, in plain types: a LaneJob writes what its units read into words
// (packLanes), which the executor sends to its lanes as one Blob; its lane
// function (by laneKind) claims units from a counter every lane shares
// (UnitClaims: an atomic add on a shared region's word), computes each as
// runUnit would, with the same code, and gives back a LaneResult; the
// executor merges each unit a lane gave back with mergeLaneUnit, in unit
// order, after the run, and runs any other unit on the main lane.

// The lane functions (LaneJob.laneKind; render/lanes.as runs them).
export const LANE_OCCLUSION: i32 = 1;
export const LANE_LIGHTS: i32 = 2;
export const LANE_LIGHT_CLUSTERS: i32 = 3;
export const LANE_OCCLUSION_SETUP: i32 = 4;
// Milestone 63: the navigation agents' avoidance (scene/navigation/
// avoidance.as AvoidanceJob).
export const LANE_AVOIDANCE: i32 = 5;

// The next unit of a run for whoever asks, -1 once every one is claimed.
export abstract class UnitClaims {
    abstract next(): i32;
}

// Claims in order, for a lane's code run on the main lane (the tests).
export class LocalClaims extends UnitClaims {
    at: i32 = 0;
    units: i32;

    constructor(units: i32) {
        super();
        this.units = units;
    }

    next(): i32 {
        return this.at < this.units ? this.at++ : -1;
    }
}

// What a lane gives back: the units it claimed, in claim order, and its
// numbers, each unit's from unitInts[i] in `ints` and unitFloats[i] in
// `floats` (i its place in `units`), laid out as its job says.
export class LaneResult {
    units: Int32Array = new Int32Array(0);
    ints: Int32Array = new Int32Array(0);
    floats: Float32Array = new Float32Array(0);
    unitInts: Int32Array = new Int32Array(0);
    unitFloats: Int32Array = new Int32Array(0);
}

// A LaneResult made by a lane, its arrays grown as units are added.
export class LaneResultWriter {
    private units: Int32Array;
    private unitInts: Int32Array;
    private unitFloats: Int32Array;
    private ints: Int32Array = new Int32Array(256);
    private floats: Float32Array = new Float32Array(1024);
    private count: i32 = 0;
    intCount: i32 = 0;
    floatCount: i32 = 0;

    constructor(units: i32) {
        this.units = new Int32Array(units);
        this.unitInts = new Int32Array(units);
        this.unitFloats = new Int32Array(units);
    }

    // Unit `unit` begins: its numbers are those added from now on.
    begin(unit: i32): void {
        unchecked(this.units[this.count] = unit);
        unchecked(this.unitInts[this.count] = this.intCount);
        unchecked(this.unitFloats[this.count] = this.floatCount);
        this.count++;
    }

    addInt(v: i32): void {
        if (this.intCount == this.ints.length) {
            const more = new Int32Array(this.ints.length * 2);
            for (let i = 0; i < this.intCount; i++) unchecked(more[i] = unchecked(this.ints[i]));
            this.ints = more;
        }
        unchecked(this.ints[this.intCount++] = v);
    }

    // The first `n` of `v`.
    addInts(v: Int32Array, n: i32): void {
        if (this.intCount + n > this.ints.length) {
            let size = this.ints.length * 2;
            while (size < this.intCount + n) size *= 2;
            const more = new Int32Array(size);
            for (let i = 0; i < this.intCount; i++) unchecked(more[i] = unchecked(this.ints[i]));
            this.ints = more;
        }
        for (let i = 0; i < n; i++) unchecked(this.ints[this.intCount + i] = unchecked(v[i]));
        this.intCount += n;
    }

    // Room for `n` more floats; the index of the first.
    reserveFloats(n: i32): i32 {
        if (this.floatCount + n > this.floats.length) {
            let size = this.floats.length * 2;
            while (size < this.floatCount + n) size *= 2;
            const more = new Float32Array(size);
            for (let i = 0; i < this.floatCount; i++) unchecked(more[i] = unchecked(this.floats[i]));
            this.floats = more;
        }
        const at = this.floatCount;
        this.floatCount += n;
        return at;
    }

    floatArray(): Float32Array {
        return this.floats;
    }

    result(): LaneResult {
        const r = new LaneResult();
        r.units = this.units.subarray(0, this.count);
        r.unitInts = this.unitInts.subarray(0, this.count);
        r.unitFloats = this.unitFloats.subarray(0, this.count);
        r.ints = this.ints.subarray(0, this.intCount);
        r.floats = this.floats.subarray(0, this.floatCount);
        return r;
    }
}

// A job whose units can also run on lanes (the section's header).
export abstract class LaneJob extends Job {
    // Which lane function computes its units (LANE_*).
    abstract laneKind(): i32;
    // Whether a run of `count` items at `grain` is worth lanes: its work
    // against a lane's start (about 10 µs natively) and the copies.
    abstract worthLanes(count: i32, grain: i32): bool;
    // Writes what every unit of the run reads into laneWords(); the bytes
    // written.
    abstract packLanes(count: i32, grain: i32, units: i32): i32;
    abstract laneWords(): ArrayBuffer;
    // Unit `unit`, as a lane computed it (the `at`-th of `r.units`), into
    // the job's outputs.
    abstract mergeLaneUnit(unit: i32, r: LaneResult, at: i32): void;
}

// The lane executor's run, the same whatever runs the lanes: render/lanes.as'
// on Rive's script threads, or a test's lanes on the main lane. A job that
// is not a LaneJob, a run with one unit, a pool without threads or a run
// its job says is not worth lanes runs as the serial executor runs it.
// Otherwise: the job packs its input; `lanes` lanes start (threads(), at
// most one fewer than the units, at most MAX_LANES), each claiming units
// from the run's shared counter; the main lane claims units from the same
// counter while they run and runs those itself; each lane is joined; then
// in unit order each unit a lane gave back is merged, and any unit no one
// gave back (a lane that failed, or did not end within the call's budget)
// is run by the main lane.
export abstract class LaneExecutorBase extends Executor {
    // What the last run of a LaneJob did (for the tests and the benches).
    lanesStarted: i32 = 0;
    unitsByLanes: i32 = 0;
    unitsHere: i32 = 0;
    unitsAgain: i32 = 0;
    private ranHere: Uint8Array = new Uint8Array(0);
    private laneOf: Int32Array = new Int32Array(0);
    private atOf: Int32Array = new Int32Array(0);
    private results: Array<LaneResult> = [];

    // The pool's threads (0: every job on the main lane).
    abstract threads(): i32;
    // Opens a run: the job's input (`bytes` of `words`) where the lanes
    // read it, a counter of `units` they share at 0; the main lane's
    // claims on it.
    abstract openRun(words: ArrayBuffer, bytes: i32, units: i32): UnitClaims;
    // Starts lane `lane` of the open run on lane function `kind`; false
    // when it could not.
    abstract startLane(lane: i32, kind: i32, count: i32, grain: i32, units: i32): bool;
    // Joins lane `lane`: its result, or null when it failed or is still
    // running (it is then stopped).
    abstract joinLane(lane: i32): LaneResult?;
    // Lets go of the run's shared objects and lanes.
    abstract closeRun(): void;

    workers(): i32 {
        return this.threads() + 1;
    }

    startsLanes(): bool {
        return true;
    }

    run(job: Job, count: i32, grain: i32): void {
        const units = unitCount(count, grain);
        const isLane = job instanceof LaneJob;
        if (isLane) {
            this.lanesStarted = 0;
            this.unitsByLanes = 0;
            this.unitsHere = 0;
            this.unitsAgain = 0;
        }
        const threads = isLane ? this.threads() : 0;
        if (!isLane || threads <= 0 || units < 2 || !(job as LaneJob).worthLanes(count, grain)) {
            for (let u = 0; u < units; u++) job.runUnit(u, unitBegin(u, grain), unitEnd(u, count, grain), 0);
            return;
        }
        const lj = job as LaneJob;
        if (this.ranHere.length < units) {
            this.ranHere = new Uint8Array(units);
            this.laneOf = new Int32Array(units);
            this.atOf = new Int32Array(units);
        }
        for (let u = 0; u < units; u++) {
            unchecked(this.ranHere[u] = 0);
            unchecked(this.laneOf[u] = -1);
        }
        const bytes = lj.packLanes(count, grain, units);
        const mine = this.openRun(lj.laneWords(), bytes, units);
        let lanes = units - 1;
        if (lanes > threads) lanes = threads;
        if (lanes > MAX_LANES) lanes = MAX_LANES;
        const kind = lj.laneKind();
        let started = 0;
        for (let l = 0; l < lanes; l++) {
            if (!this.startLane(l, kind, count, grain, units)) break;
            started++;
        }
        this.lanesStarted = started;
        while (true) {
            const u = mine.next();
            if (u < 0) break;
            job.runUnit(u, unitBegin(u, grain), unitEnd(u, count, grain), 0);
            unchecked(this.ranHere[u] = 1);
            this.unitsHere++;
        }
        this.results.length = 0;
        for (let l = 0; l < started; l++) {
            const r = this.joinLane(l);
            if (r == null) continue;
            const at = this.results.length;
            this.results.push(r);
            for (let i = 0; i < r.units.length; i++) {
                const u = unchecked(r.units[i]);
                if (u < 0 || u >= units) continue;
                unchecked(this.laneOf[u] = at);
                unchecked(this.atOf[u] = i);
            }
        }
        for (let u = 0; u < units; u++) {
            if (unchecked(this.ranHere[u]) != 0) continue;
            const l = unchecked(this.laneOf[u]);
            if (l >= 0) {
                lj.mergeLaneUnit(u, unchecked(this.results[l]), unchecked(this.atOf[u]));
                this.unitsByLanes++;
            } else {
                job.runUnit(u, unitBegin(u, grain), unitEnd(u, count, grain), 0);
                this.unitsAgain++;
            }
        }
        this.results.length = 0;
        this.closeRun();
    }
}

// The most lanes one run starts (the pool has at most 6 threads natively).
export const MAX_LANES: i32 = 8;

let installedLanes: Executor? = null;

// Puts the lane executor in the place of EXECUTOR_LANES (and in use,
// when it is the default and nothing chose another).
export function installLaneExecutor(e: Executor): void {
    installedLanes = e;
    if (JOB_EXECUTOR_DEFAULT == EXECUTOR_LANES && !isDefined(HEDRA_JOBS_SIMULATED)) {
        if (current === defaultExecutor) current = e;
        defaultExecutor = e;
    }
}

// The lane executor, or null where none is built in.
export function laneJobExecutor(): Executor? {
    return installedLanes;
}

// ---------------------------------------------------------------------------
// The executor in use

const serialExecutor = new SerialExecutor();
const atomicExecutor = new AtomicExecutor();
// The tests' switch: built with `--define=HEDRA_JOBS_SIMULATED=1`
// (tools/unit-test.sh, tools/test-all.sh), every job runs on the atomic
// executor with SIMULATED_WORKERS workers taken in turn, so that a whole
// suite checks its pictures and numbers with the jobs cut and claimed as
// on several threads.
export const SIMULATED_WORKERS: i32 = 3;
const simulatedExecutor = new AtomicExecutor(SIMULATED_WORKERS);

function executorOf(kind: i32): Executor {
    if (kind == EXECUTOR_ATOMIC) return atomicExecutor;
    if (kind == EXECUTOR_LANES) {
        const l = installedLanes;
        if (l != null) return l;
    }
    return serialExecutor;
}

let defaultExecutor: Executor = isDefined(HEDRA_JOBS_SIMULATED) ? simulatedExecutor : executorOf(JOB_EXECUTOR_DEFAULT);
let current: Executor = defaultExecutor;

// The executor the engine's frame jobs run on.
export function jobs(): Executor {
    return current;
}

// The executor jobs() is until it is changed.
export function defaultJobExecutor(): Executor {
    return defaultExecutor;
}

// Chooses the executor by kind (EXECUTOR_*; another kind: the default).
export function setJobExecutor(kind: i32): void {
    current = kind == EXECUTOR_SERIAL || kind == EXECUTOR_ATOMIC || kind == EXECUTOR_LANES ? executorOf(kind) : defaultExecutor;
}

// Puts `e` in use (a test's simulated workers), or the default for null.
export function useJobExecutor(e: Executor?): void {
    if (e == null) current = defaultExecutor;
    else current = e;
}
