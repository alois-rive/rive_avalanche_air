// The particles feature of the run time (milestone 35, features.as
// FEATURE_PARTICLES; docs/engine/PARTICLES.md, docs/cli/BUILD.md section
// 18): each instance's CPUParticles3D nodes advanced every frame by the
// frame's seconds (../particles/sim.as), after the scripts (PHASE_SCRIPTS:
// installed after the scripts feature, so a script that moves or restarts
// an emitter is seen this frame, as Godot's internal process follows the
// tree's), and a frame drawn again when a particle changed. A one_shot
// emission that ended emits its node's `finished` once (Godot's signal),
// through SceneInstance.emitEvent with an event of the node's own, so that
// connections, scripts and a `signal:finished` binding hear it (a view
// model trigger, which the host artboard's state machine turns into a
// Rive event). The instance's seconds are already its speed's, and 0 when
// it is not playing: nothing moves then. An invisible emitter is not
// advanced (sim.as). The emitters are found again only when the tree's
// structure changes (a script adding or removing nodes, a rename), not by
// a walk each frame; a scene without a CPUParticles3D costs a comparison a
// frame; idle, walking, emitting and `finished` allocate nothing (the
// events are made with the emitters, their `from` the emitter's path from
// the instance's root, then filled again).

import { Value } from "../value";
import { CPUParticles3D, SceneNode, treeStructureEpoch } from "../tree/node";
import { EmitterJob } from "../particles/sim";
import { FEATURE_PARTICLES, Feature, InstanceFeature, PHASE_SCRIPTS } from "./features";
import { SignalEvent } from "./signals";
import { SceneInstance, SceneRuntime } from "./scene_runtime";

export class ParticlesFeature extends Feature {
    bit(): u32 {
        return FEATURE_PARTICLES;
    }

    forInstance(inst: SceneInstance): InstanceFeature {
        return new ParticlesPart();
    }
}

// One instance's emitters, found again when the tree's structure changes.
export class ParticlesPart extends InstanceFeature {
    emitters: Array<CPUParticles3D> = [];
    // `finished`, one event per emitter (in `emitters` order).
    finished: Array<SignalEvent> = [];
    private walked: Array<SceneNode> = [];
    // The emitters a frame advances, as a job (../particles/sim.as).
    private job: EmitterJob = new EmitterJob();
    private stack: Array<SceneNode> = [];
    private epoch: i32 = -1;

    attach(inst: SceneInstance, root: SceneNode): void {
        this.epoch = -1;
    }

    detach(inst: SceneInstance, root: SceneNode): void {
        this.epoch = -1;
    }

    advance(inst: SceneInstance, seconds: f64, phase: i32): bool {
        if (phase != PHASE_SCRIPTS) return false;
        this.find(inst);
        let changed = false;
        const emitters = this.emitters;
        const n = emitters.length;
        const job = this.job;
        // The emitters in runs, each advanced as a job (jobs.as), then its
        // `finished` emitted: a run ends at an emitter that may emit it (a
        // one_shot one, or one with an emission pending), so that what its
        // handlers do is seen by every emitter after it, as when each was
        // advanced in turn. A frame of emitters that loop is one run.
        let a = 0;
        while (a < n) {
            let z = a;
            while (z < n && !mayFinish(unchecked(emitters[z]))) z++;
            const end = z < n ? z + 1 : n;
            job.clear();
            for (let i = a; i < end; i++) {
                const p = unchecked(emitters[i]);
                if (p.visibleInTree()) job.add(p, p.global(), i);
            }
            job.run(seconds);
            for (let k = 0; k < job.count; k++) {
                if (unchecked(job.changed[k])) changed = true;
                const p = unchecked(job.emitters[k]);
                const s = p.particles;
                if (s != null && s.finishedPending) {
                    // (taken before the emit: a handler may restart it)
                    s.finishedPending = false;
                    inst.emitEvent(p, unchecked(this.finished[unchecked(job.from[k])]));
                    changed = true;
                }
            }
            a = end;
        }
        return changed;
    }

    // The emitters of the instance's tree, again when its structure moved.
    private find(inst: SceneInstance): void {
        const e = treeStructureEpoch();
        if (e == this.epoch) return;
        this.epoch = e;
        inst.tree.walkInto(this.walked, this.stack);
        this.emitters.length = 0;
        this.finished.length = 0;
        for (let i = 0; i < this.walked.length; i++) {
            const n = this.walked[i];
            const isParticles = n instanceof CPUParticles3D;
            if (!isParticles) continue;
            this.emitters.push(n as CPUParticles3D);
            this.finished.push(new SignalEvent(n.pathFrom(inst.tree.root), "finished", Value.nil()));
        }
    }
}

// Whether advancing `p` may leave it a `finished` to emit (sim.as: a
// one_shot emitter's, or one already pending).
function mayFinish(p: CPUParticles3D): bool {
    if (p.oneShot) return true;
    const s = p.particles;
    return s != null && s.finishedPending;
}

// Adds the particles feature to `rt` (newSceneRuntime(), and the module's
// generated features.as when the bundle's scenes use it).
export function installParticlesFeature(rt: SceneRuntime): void {
    rt.install(new ParticlesFeature());
}
