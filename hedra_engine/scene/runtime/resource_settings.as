// A Hedra project's loading and memory settings (milestone 67b,
// docs/engine/RESOURCES.md, "Settings"): hedra.yaml's lines, which `hedra
// build` passes to registerProject among the others of its sixth argument
// (../../source/project/resource_settings.as resourceSettingLines) and
// which the run time reads back here, once per project
// (projects.as RegisteredProject.resourceSettings). Hedra's settings: Godot
// loads synchronously unless asked (ResourceLoader.load_threaded_request),
// keeps its imported textures' RIDs rather than their images, and has no
// switch for either.
//
//   loading/frame_budget_msec: 8       the milliseconds a frame spends
//                                      loading a scene at most (by the
//                                      estimate of load_task.as); 0, the
//                                      default: the whole load in the
//                                      first advance, as before. A `.web`
//                                      form applies on the web runtime.
//   loading/verify_sources: text       which resources a load checks
//                                      against their sources before it
//                                      reads their built forms (remap.as):
//                                      `text` (the default) those a scene
//                                      drawn from its text reads, `always`
//                                      every one (reads and hashes every
//                                      declared source: for editing
//                                      textures and models without
//                                      building)
//   memory/keep_cpu_copies: false      keep every texture's pixels and
//                                      mesh's arrays after their upload
//                                      (../resource/cpu_copy.as)
//   debug/print_resources: false       the Scene3D logs its `resources`
//                                      text (Context.log, "hedra:
//                                      resources {...} at frame N") each
//                                      time it changes, as Godot's
//                                      debug/settings/stdout/print_fps
//                                      prints the frame rate: what a
//                                      headless `rive --bench`, which
//                                      draws every frame but dumps no
//                                      view model, reads the GPU's
//                                      figures from
//   export/embed_sources: true         (the build's alone) whether
//                                      hedra.rml declares the scenes'
//                                      source files, which a scene drawn
//                                      from its text reads; false: their
//                                      texts and settings only, a Rive
//                                      file then carrying the built
//                                      forms alone
//
// Who reads them: the remaps (verify_sources: remap.as; embed_sources is
// the build's: hedra_compiler/build/declare.as), the CPU-copy policy
// (keep_cpu_copies: runtime_resources.as, ../resource/cpu_copy.as) and the
// Scene3D's load (frame_budget_msec: scene3d.as, load_task.as).

import { parseF64 } from "../../base/parse";

export const SETTING_LOAD_FRAME_BUDGET = "loading/frame_budget_msec";
export const SETTING_LOAD_VERIFY_SOURCES = "loading/verify_sources";
export const SETTING_KEEP_CPU_COPIES = "memory/keep_cpu_copies";
export const SETTING_EMBED_SOURCES = "export/embed_sources";
export const SETTING_PRINT_RESOURCES = "debug/print_resources";

export const VERIFY_SOURCES_TEXT: i32 = 0;
export const VERIFY_SOURCES_ALWAYS: i32 = 1;
export const VERIFY_SOURCES_NAMES: StaticArray<string> = ["text", "always"];

// Every key, the `.web` form of the budget among them.
export const RESOURCE_SETTING_KEYS: StaticArray<string> = [
    SETTING_LOAD_FRAME_BUDGET, SETTING_LOAD_FRAME_BUDGET + ".web", SETTING_LOAD_VERIFY_SOURCES, SETTING_KEEP_CPU_COPIES,
    SETTING_EMBED_SOURCES, SETTING_PRINT_RESOURCES,
];

export function isResourceSettingKey(key: string): bool {
    for (let i = 0; i < RESOURCE_SETTING_KEYS.length; i++) if (RESOURCE_SETTING_KEYS[i] == key) return true;
    return false;
}

export class ResourceSettings {
    // The frame budget in milliseconds (0: the whole load at once).
    frameBudgetMsec: f64 = 0;
    verifySources: i32 = VERIFY_SOURCES_TEXT;
    keepCpuCopies: bool = false;
    embedSources: bool = true;
    printResources: bool = false;

    copyFrom(o: ResourceSettings): void {
        this.frameBudgetMsec = o.frameBudgetMsec;
        this.verifySources = o.verifySources;
        this.keepCpuCopies = o.keepCpuCopies;
        this.embedSources = o.embedSources;
        this.printResources = o.printResources;
    }
}

// The settings `text` (hedra.yaml's lines, or registerProject's sixth
// argument) sets, over `out`; a value that is none of a setting's is a
// warning in `warnings` and leaves the default. `web`: the `.web` form of
// the budget wins over the plain one (the web runtime). Other keys are
// passed over.
export function resourceSettingsFromText(text: string, out: ResourceSettings, warnings: Array<string>, web: bool = false): ResourceSettings {
    const lines = text.split("\n");
    let webBudget: f64 = -1;
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i];
        const hash = line.indexOf("#");
        if (hash >= 0) line = line.substring(0, hash);
        line = line.trim();
        const colon = line.indexOf(":");
        if (colon <= 0) continue;
        const key = line.substring(0, colon).trim();
        if (!isResourceSettingKey(key)) continue;
        let value = line.substring(colon + 1).trim();
        if (value.length >= 2 && (value.startsWith("\"") && value.endsWith("\"") || value.startsWith("'") && value.endsWith("'"))) {
            value = value.substring(1, value.length - 1);
        }
        if (key == SETTING_LOAD_FRAME_BUDGET || key == SETTING_LOAD_FRAME_BUDGET + ".web") {
            const n = parseF64(value);
            if (!n.ok || !(n.value >= 0) || !isFinite(n.value)) {
                warnings.push("hedra.yaml: " + key + " is " + value + ", not a number of milliseconds, 0 or more");
                continue;
            }
            if (key == SETTING_LOAD_FRAME_BUDGET) out.frameBudgetMsec = n.value;
            else webBudget = n.value;
        } else if (key == SETTING_LOAD_VERIFY_SOURCES) {
            let c = -1;
            for (let k = 0; k < VERIFY_SOURCES_NAMES.length; k++) if (VERIFY_SOURCES_NAMES[k] == value) c = k;
            if (c < 0) warnings.push("hedra.yaml: " + key + " is " + value + ", not text or always");
            else out.verifySources = c;
        } else {
            if (value != "true" && value != "false") {
                warnings.push("hedra.yaml: " + key + " is " + value + ", not true or false");
                continue;
            }
            if (key == SETTING_KEEP_CPU_COPIES) out.keepCpuCopies = value == "true";
            else if (key == SETTING_PRINT_RESOURCES) out.printResources = value == "true";
            else out.embedSources = value == "true";
        }
    }
    if (web && webBudget >= 0) out.frameBudgetMsec = webBudget;
    return out;
}
