// The Hedra projects compiled into a Rive project (milestone 41,
// docs/plans/BUILD.md section 5.3): each project's generated, committed
// hedra_project.as registers itself here by a top-level statement, so
// that nothing has to import it:
//
//   registerProject("world", "courtyard.rscn", 0, registerScripts);
//
// its path in the Rive project ("" when the Hedra project is the Rive
// project's own directory), its main scene (hedra.yaml's main_scene, a
// path in the project; "" when it has none), the library major it was
// written for, and the function that fills a ScriptRegistry with the
// project's script classes, each keyed by its path in the project
// ("scripts/spin.as": the key a scene's script is looked up by, whether
// the scene is drawn from its text or from its built form;
// sources.as). AnimaScript has no reflection, so this generated code is
// what lets a scene's `script` make an instance and set its exported
// properties.
//
// Milestone 42: a project whose scenes take their data from the Rive
// project (a view model named without a file, a global, a converter of the
// project's) also lists the .rml files that data is declared in, by their
// paths in the Rive project, each declared as a `hedra:<path>` blob in
// its hedra_engine.rml; the argument is written only when there are any:
//
//   registerProject("data", "data.rscn", 0, registerScripts, ["data/data.rml"]);
//
// A scene drawn from its text reads its project's data from those files
// (project_data.as BlobProjectData); a built scene carries the converters
// it uses and needs none of them.
//
// Milestone 62: a project whose hedra.yaml sets the screen-space effects'
// quality (Godot's project settings: rendering/environment/
// screen_space_reflection/* and rendering/camera/depth_of_field/*) passes
// those lines as a sixth argument, after the data files (an empty list when
// it has none); the argument is written only when it sets one:
//
//   registerProject("hall", "hall.rscn", 0, registerScripts, [],
//       "rendering/camera/depth_of_field/depth_of_field_bokeh_quality: very_low\n");
//
// The instances of its scenes draw with that quality
// (`screenQuality()`, parsed once: ../../render/screen.as
// screenQualityFromSettings), the tools' quality for the same file.
//
// Milestone 63: the navigation map's settings (Godot's navigation/3d/*
// keys, ../navigation/settings.as) travel in the same argument, after the
// screen quality's lines, written only when the project sets one:
//
//   registerProject("navigation", "navigation.rscn", 0, registerScripts, [],
//       "navigation/3d/default_cell_size: 0.2\n");
//
// The instances of its scenes make their maps with them
// (`navigationSettings()`, parsed once: navigationSettingsFromText), the
// tools' settings for the same file.
//
// Milestone 67 (docs/engine/PERFORMANCE.md, "The knobs"): the render
// quality's lines (Godot's rendering/anti_aliasing/quality/msaa_3d,
// rendering/scaling_3d/* and the others of ../../render/quality.as
// RENDER_SETTING_KEYS, and their `.web` forms) travel among the screen
// quality's, written only when the project sets one:
//
//   registerProject("chess", "study.rscn", 0, registerScripts, [],
//       "rendering/scaling_3d/scale: 0.75\nrendering/scaling_3d/scale.web: 0.5\n");
//
// The instances of its scenes draw with them (`renderQuality(web)`,
// parsed once for each of the two platforms: renderQualityFromSettings),
// the tools' quality for the same file; each parser passes over the
// others' lines.
//
// A second registration of one name replaces the first. Registering
// allocates; looking a project up does not.

import { ScriptRegistry } from "../script";
import { ScreenQuality, screenQualityFromSettings } from "../../render/screen";
import { NavigationSettings, navigationSettingsFromText } from "../navigation/settings";
import { RenderQuality, renderQualityFromSettings } from "../../render/quality";
import { ResourceSettings, resourceSettingsFromText } from "./resource_settings";

// Fills a registry with one project's script classes.
export type ScriptRegistrar = (registry: ScriptRegistry) => void;

export class RegisteredProject {
    // The project's path in the Rive project ("world"; "" for the Rive
    // project's own directory).
    name: string;
    // Its main scene, a path in the project ("courtyard.rscn"; "" for none).
    mainScene: string;
    // The library major hedra_project.as was written for.
    major: i32;
    registrar: ScriptRegistrar;
    // The Rive project's .rml files the project's data comes from (paths
    // in the Rive project, sorted; empty when its scenes use none).
    dataFiles: Array<string>;
    // Milestone 62: its hedra.yaml's screen quality lines ("" when it sets
    // none: Godot's defaults), with (milestone 67) its render quality's
    // among them, and (milestone 63) its navigation lines after them.
    settings: string;
    // The registry, filled on first use (scripts).
    private filled: ScriptRegistry? = null;
    // The quality `settings` say, parsed on first use, and what they said
    // that is not one of a setting's choices (the tools' warnings).
    private quality: ScreenQuality? = null;
    // The navigation settings `settings` say, parsed on first use.
    private navigation: NavigationSettings? = null;
    // Milestone 67: the render quality `settings` say, parsed on first use,
    // without the web's overrides and with them.
    private render: RenderQuality? = null;
    // Milestone 67b: the loading and memory settings, parsed on first use,
    // without the web's overrides and with them.
    private resources: ResourceSettings? = null;
    private resourcesWeb: ResourceSettings? = null;
    private renderWeb: RenderQuality? = null;
    settingsWarnings: Array<string> = [];

    constructor(name: string, mainScene: string, major: i32, registrar: ScriptRegistrar, dataFiles: Array<string> = [],
        settings: string = "") {
        this.name = name;
        this.mainScene = mainScene;
        this.major = major;
        this.registrar = registrar;
        this.dataFiles = dataFiles;
        this.settings = settings;
    }

    // The screen-space effects' quality the project sets (Godot's defaults
    // for what it does not), parsed once.
    screenQuality(): ScreenQuality {
        let q = this.quality;
        if (q == null) {
            q = screenQualityFromSettings(this.settings, new ScreenQuality(), this.settingsWarnings);
            this.quality = q;
        }
        return q;
    }

    // Milestone 63: the navigation map's settings the project sets (Godot's
    // defaults for what it does not), parsed once; the screen quality's
    // lines are passed over (and the navigation's by screenQuality).
    navigationSettings(): NavigationSettings {
        let n = this.navigation;
        if (n == null) {
            n = navigationSettingsFromText(this.settings, new NavigationSettings(), this.settingsWarnings);
            this.navigation = n;
        }
        return n;
    }

    // Milestone 67: the render quality the project sets (the defaults for
    // what it does not), with the `.web` lines over the others when `web`
    // (the WebGL 2 runtime), parsed once each. The screen quality's and the
    // navigation's lines are passed over (and these by theirs).
    renderQuality(web: bool = false): RenderQuality {
        let q = web ? this.renderWeb : this.render;
        if (q == null) {
            // (the warnings once: a bad line says the same on both)
            const said = this.render != null || this.renderWeb != null;
            q = renderQualityFromSettings(this.settings, new RenderQuality(), said ? new Array<string>() : this.settingsWarnings, web);
            if (web) this.renderWeb = q;
            else this.render = q;
        }
        return q;
    }

    // Milestone 67b (resource_settings.as): the loading and memory settings
    // the project sets (the defaults for what it does not), with the `.web`
    // budget over the other when `web`, parsed once each; the other
    // parsers' lines are passed over (and these by theirs).
    resourceSettings(web: bool = false): ResourceSettings {
        let r = web ? this.resourcesWeb : this.resources;
        if (r == null) {
            const said = this.resources != null || this.resourcesWeb != null;
            r = resourceSettingsFromText(this.settings, new ResourceSettings(), said ? new Array<string>() : this.settingsWarnings, web);
            if (web) this.resourcesWeb = r;
            else this.resources = r;
        }
        return r;
    }

    // The project's script classes (filled once).
    scripts(): ScriptRegistry {
        let r = this.filled;
        if (r == null) {
            r = new ScriptRegistry();
            this.registrar(r);
            this.filled = r;
        }
        return r;
    }
}

// (null, a constant that needs no start code, and made on first use: a
// generated hedra_project.as may run its top-level registration before
// this module's start function, which would otherwise put an empty array
// back over what it registered; milestone 40 met the same with the file
// readers, engine/src/scene/resource/loader.as)
let projectList: Array<RegisteredProject>? = null;

function list(): Array<RegisteredProject> {
    let l = projectList;
    if (l == null) {
        l = new Array<RegisteredProject>();
        projectList = l;
    }
    return l;
}

// Registers a Hedra project (see the header).
export function registerProject(name: string, mainScene: string, major: i32, registrar: ScriptRegistrar,
    dataFiles: Array<string> = [], settings: string = ""): void {
    const projects = list();
    const p = new RegisteredProject(name, mainScene, major, registrar, dataFiles, settings);
    for (let i = 0; i < projects.length; i++) {
        if (projects[i].name == name) {
            projects[i] = p;
            return;
        }
    }
    projects.push(p);
}

// Every registered project, in the order registered.
export function registeredProjects(): Array<RegisteredProject> {
    return list();
}

// The project registered as `name`, or null.
export function projectNamed(name: string): RegisteredProject? {
    const projects = list();
    for (let i = 0; i < projects.length; i++) if (projects[i].name == name) return projects[i];
    return null;
}

// Forgets every registration (tests).
export function clearProjects(): void {
    list().length = 0;
}
