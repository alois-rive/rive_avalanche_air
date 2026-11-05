// What a rename elsewhere in a scene rewrites in its state machines
// (docs/formats/RSCN.md, "State machines"): a machine names animations,
// events and nodes by their names and paths, so renaming one of them
// rewrites every reference in the same step, as renaming a node rewrites
// the keyed targets of the scene's animations. Pure document edits: the
// editor's history step (editor/src/scene/edit), the CLI or a
// script calls them on the document it then writes, and each answers how
// many references it rewrote (0: nothing named it).
//
// Milestone 47: the listeners too. A node renamed or moved rewrites each
// listener's target and each ListenerAlignTarget's; an event renamed
// rewrites each ListenerFireEvent's event and each event listener's that
// hears the scene's own events (not one whose target is, or lies under, a
// node instancing a scene: that one hears the instanced scene's event of
// that name).

import { RscnDoc } from "../rscn/doc";
import {
    ActionKind, ConditionKind, FireActionDecl, LayerDecl, ListenerActionKind, ListenerType, StateKind, StateMachineDecl,
} from "./decl";

// Every transition of `l` going to the state called `from` goes to `to`.
function retarget(l: LayerDecl, from: string, to: string): void {
    for (let i = 0; i < l.states.length; i++) {
        const ts = l.states[i].transitions;
        for (let k = 0; k < ts.length; k++) if (ts[k].to == from) ts[k].to = to;
    }
}

// The animation `from` renamed `to`: every AnimationState playing it and
// every blend animation of a blend state. An AnimationState without a name
// of its own is called after its animation, so the transitions going to it
// follow the new name.
export function renameAnimationInMachines(doc: RscnDoc, from: string, to: string): i32 {
    if (from == to) return 0;
    const machines = doc.stateMachines();
    let n = 0;
    for (let m = 0; m < machines.length; m++) {
        const layers = machines[m].layers;
        for (let l = 0; l < layers.length; l++) {
            const states = layers[l].states;
            for (let s = 0; s < states.length; s++) {
                const st = states[s];
                if (st.kind == StateKind.Animation && st.animation == from) {
                    if (st.name.length == 0) retarget(layers[l], from, to);
                    st.animation = to;
                    n++;
                }
                for (let b = 0; b < st.blends.length; b++) {
                    if (st.blends[b].animation != from) continue;
                    st.blends[b].animation = to;
                    n++;
                }
            }
        }
    }
    return n;
}

function renameEvents(actions: Array<FireActionDecl>, from: string, to: string): i32 {
    let n = 0;
    for (let i = 0; i < actions.length; i++) {
        if (actions[i].kind != ActionKind.FireEvent || actions[i].event != from) continue;
        actions[i].event = to;
        n++;
    }
    return n;
}

// The Event `from` renamed `to`: every StateMachineFireEvent firing it, on
// a state or on a transition, every ListenerFireEvent firing it and every
// event listener hearing it from the scene itself.
export function renameEventInMachines(doc: RscnDoc, from: string, to: string): i32 {
    if (from == to) return 0;
    const machines = doc.stateMachines();
    let n = 0;
    for (let m = 0; m < machines.length; m++) {
        const layers = machines[m].layers;
        for (let l = 0; l < layers.length; l++) {
            const states = layers[l].states;
            for (let s = 0; s < states.length; s++) {
                const st = states[s];
                n += renameEvents(st.actions, from, to);
                for (let t = 0; t < st.transitions.length; t++) n += renameEvents(st.transitions[t].actions, from, to);
            }
        }
        const listeners = machines[m].listeners;
        for (let i = 0; i < listeners.length; i++) {
            const l = listeners[i];
            if (l.type == ListenerType.Event && l.event == from && !inInstance(doc, l.target)) {
                l.event = to;
                n++;
            }
            for (let k = 0; k < l.actions.length; k++) {
                const a = l.actions[k];
                if (a.kind != ListenerActionKind.FireEvent || a.event != from) continue;
                a.event = to;
                n++;
            }
        }
    }
    return n;
}

// Whether the node path `path` names a node instancing a scene, or a node
// under one (whose events are the instanced scene's).
function inInstance(doc: RscnDoc, path: string): bool {
    if (path.length == 0 || path == ".") return false;
    const segs = path.split("/");
    for (let k = 1; k <= segs.length; k++) {
        const n = doc.findNode(segs.slice(0, k).join("/"));
        if (n == null) return true;
        if (n.instance != null) return true;
    }
    return false;
}

// Whether `path` is `ancestor` or a node below it.
function under(path: string, ancestor: string): bool {
    return path == ancestor || path.startsWith(ancestor + "/");
}

// The node at `from` (a path from the root) renamed or moved to `to`: every
// TransitionComponentCondition reading it, or a node below it, reads the
// node at its new path, and every listener and ListenerAlignTarget naming
// it or a node below it names the new path. The root (".") never moves.
export function renameNodeInMachines(doc: RscnDoc, from: string, to: string): i32 {
    if (from == "." || from == to) return 0;
    const machines: Array<StateMachineDecl> = doc.stateMachines();
    let n = 0;
    for (let m = 0; m < machines.length; m++) {
        const layers = machines[m].layers;
        for (let l = 0; l < layers.length; l++) {
            const states = layers[l].states;
            for (let s = 0; s < states.length; s++) {
                const ts = states[s].transitions;
                for (let t = 0; t < ts.length; t++) {
                    const cs = ts[t].conditions;
                    for (let c = 0; c < cs.length; c++) {
                        const k = cs[c];
                        if (k.kind != ConditionKind.Component || !under(k.target, from)) continue;
                        k.target = to + k.target.substring(from.length);
                        n++;
                    }
                }
            }
        }
        const listeners = machines[m].listeners;
        for (let i = 0; i < listeners.length; i++) {
            const l = listeners[i];
            if (l.target.length > 0 && l.target != "." && under(l.target, from)) {
                l.target = to + l.target.substring(from.length);
                n++;
            }
            for (let k = 0; k < l.actions.length; k++) {
                const a = l.actions[k];
                if (a.kind != ListenerActionKind.AlignTarget || !under(a.target, from)) continue;
                a.target = to + a.target.substring(from.length);
                n++;
            }
        }
    }
    return n;
}
