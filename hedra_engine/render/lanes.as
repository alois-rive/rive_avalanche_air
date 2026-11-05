// The engine's jobs on Rive's script threads (docs/engine/JOBS.md,
// "Script threads"): the lane executor, and the lane functions of the jobs
// that can run on lanes, on `rive/jobs` and `rive/shared` (rive 1.8.0 and
// later: docs/milestones/TOOLCHAIN-1.8.md). The Scene3D component
// (hedra_engine/scene3d) installs the executor (jobs.as
// installLaneExecutor), so that in every built Rive project, under the
// frame runtime, it is every job's; the programs (the stub runtime) do not
// import it and keep the serial executor, and the tests install it where
// they ask for it.
//
// A run (jobs.as LaneExecutorBase): the job's input words go to the lanes
// as one Blob (bytes fixed once made, which every lane reads without a
// copy); the run's unit counter is a word of a SharedRegion, which each
// lane and the main lane take units from with its atomic add; each lane is
// a `@job` function (one by LANE_* kind) that rebuilds what its units read
// from the Blob, runs each unit it claims with the engine's own code, and
// gives back a LaneResult, which crosses back as a copy of its arrays.

import { Job as LaneHandle, Jobs } from "rive/jobs";
import { Blob, SharedRegion } from "rive/shared";
import {
    LANE_AVOIDANCE, LANE_LIGHTS, LANE_LIGHT_CLUSTERS, LANE_OCCLUSION, LANE_OCCLUSION_SETUP, LaneExecutorBase, LaneResult,
    UnitClaims,
} from "../base/jobs";
import { occlusionLaneUnits, occlusionSetupLaneUnits } from "./occlusion";
import { lightLaneUnits } from "./light_select";
import { avoidanceLaneUnits } from "../scene/navigation/avoidance";

// The run's counter: the region's first word.
const CLAIM_WORD: u32 = 0;

// Units claimed with an atomic add on a region's word (a lane's, or the
// main lane's while the lanes run).
class RegionClaims extends UnitClaims {
    region: SharedRegion;
    units: i32;

    constructor(region: SharedRegion, units: i32) {
        super();
        this.region = region;
        this.units = units;
    }

    next(): i32 {
        const u = <i32>this.region.atomicAdd(CLAIM_WORD, 1);
        return u < this.units ? u : -1;
    }
}

unsafe function blobOf(words: ArrayBuffer, bytes: i32): Blob {
    return Blob.from(words, 0, bytes);
}

unsafe function wordsOf(input: Blob): ArrayBuffer {
    const words = new ArrayBuffer(<i32>input.byteLength);
    input.readInto(0, words);
    return words;
}

// The occluders' triangles set up (render/occlusion.as SetupJob).
@job export function occlusionSetupLane(input: Blob, claims: SharedRegion, count: i32, grain: i32, units: i32): LaneResult {
    return occlusionSetupLaneUnits(wordsOf(input), new RegionClaims(claims, units), count, grain, units);
}

// The occlusion buffer's tiles filled (render/occlusion.as FillJob).
@job export function occlusionLane(input: Blob, claims: SharedRegion, count: i32, grain: i32, units: i32): LaneResult {
    return occlusionLaneUnits(wordsOf(input), new RegionClaims(claims, units), count, grain, units);
}

// The items' lights, alone or (`clusters`) by clusters (render/
// light_select.as AssignJob).
@job export function lightLane(input: Blob, claims: SharedRegion, count: i32, grain: i32, units: i32,
    clusters: bool): LaneResult {
    return lightLaneUnits(wordsOf(input), new RegionClaims(claims, units), count, grain, units, clusters);
}

// Milestone 63: the navigation agents' avoidance (scene/navigation/
// avoidance.as AvoidanceJob): each claimed unit's agents' new velocities.
@job export function avoidanceLane(input: Blob, claims: SharedRegion, count: i32, grain: i32, units: i32): LaneResult {
    return avoidanceLaneUnits(wordsOf(input), new RegionClaims(claims, units), count, grain, units);
}

// Jobs on Rive's pool of script threads.
export class LaneExecutor extends LaneExecutorBase {
    private region: SharedRegion? = null;
    private input: Blob? = null;
    private handles: Array<LaneHandle<LaneResult>> = [];

    threads(): i32 {
        return <i32>Jobs.threads();
    }

    openRun(words: ArrayBuffer, bytes: i32, units: i32): UnitClaims {
        if (this.region == null) this.region = SharedRegion.create(8);
        const region = this.region!;
        region.atomicStore(CLAIM_WORD, 0);
        this.input = blobOf(words, bytes);
        this.handles.length = 0;
        return new RegionClaims(region, units);
    }

    startLane(lane: i32, kind: i32, count: i32, grain: i32, units: i32): bool {
        const input = this.input!;
        const region = this.region!;
        if (kind == LANE_OCCLUSION) {
            this.handles.push(Jobs.run(occlusionLane, input, region, count, grain, units));
        } else if (kind == LANE_OCCLUSION_SETUP) {
            this.handles.push(Jobs.run(occlusionSetupLane, input, region, count, grain, units));
        } else if (kind == LANE_LIGHTS || kind == LANE_LIGHT_CLUSTERS) {
            this.handles.push(Jobs.run(lightLane, input, region, count, grain, units, kind == LANE_LIGHT_CLUSTERS));
        } else if (kind == LANE_AVOIDANCE) {
            this.handles.push(Jobs.run(avoidanceLane, input, region, count, grain, units));
        } else {
            return false;
        }
        return true;
    }

    joinLane(lane: i32): LaneResult? {
        const h = unchecked(this.handles[lane]);
        const r = h.join();
        if (r == null || !r.ok) {
            h.stop();
            return null;
        }
        return r.value;
    }

    closeRun(): void {
        for (let l = 0; l < this.handles.length; l++) unchecked(this.handles[l]).release();
        this.handles.length = 0;
        const input = this.input;
        if (input != null) input.release();
        this.input = null;
    }
}
