// Where a state machine reads and writes its scene's data (docs/plans/
// RIVE_MODEL.md sections 3.3 and 3.4): the view model instance
// its scene is bound to, and the global view models by name. A condition's
// path, a 1D blend's number, a direct blend's weight, a fire action's
// trigger and an input's binding are paths in the scene's data context
// (../binding/binder.as contextCandidates: the instanced scene's data_path
// prefixes, innermost first), or in a global's (`global`).
//
// The tools (render, inspect, the editor's preview) read the scene's
// SceneData (../binding/scene_data.as: a MemoryViewModel and the globals'
// MemoryViewModels): MemorySmData. The run time reads the instance's bound
// view model and the host's globals (../runtime/feature_animation.as,
// through SceneInstance.dataValues and globalValues).
//
// A global the run time does not find at once (Context.globalViewModel
// answers null until the host has bound data) is looked up again on each
// advance for GLOBAL_LOOKUP_ADVANCES advances, then given up with an error
// in the status, as the bindings' globals are.

import { GlobalValues, ViewModelValues } from "../binding/values";
import { contextCandidates } from "../binding/binder";

export { contextCandidates };

// The advances a missing global is looked up on before the lookup stops:
// one second at 60 a second (the bindings' and the state machines').
export const GLOBAL_LOOKUP_ADVANCES: i32 = 60;

export abstract class SmData {
    // The scene's view model instance (null: none bound).
    abstract values(): ViewModelValues?;
    // The global view model `name` (null: none of that name, or not found
    // yet: the run time looks a missing global up again on later frames).
    abstract global(name: string): ViewModelValues?;
}

// The tools' data: fixed values, made once (SceneData's root and globals).
export class MemorySmData extends SmData {
    root: ViewModelValues?;
    globals: GlobalValues?;

    constructor(root: ViewModelValues?, globals: GlobalValues?) {
        super();
        this.root = root;
        this.globals = globals;
    }

    values(): ViewModelValues? {
        return this.root;
    }

    global(name: string): ViewModelValues? {
        const g = this.globals;
        return g != null ? g.global(name) : null;
    }
}
