// The navigation map's settings (milestone 63, docs/engine/NAVIGATION.md
// "The map"): Godot's project settings navigation/3d/*, which a Hedra
// project sets in its hedra.yaml, the same keys and defaults as Godot 4.4:
//
//   navigation/3d/default_cell_size: 0.25
//   navigation/3d/default_cell_height: 0.25
//   navigation/3d/default_edge_connection_margin: 0.25
//   navigation/3d/default_link_connection_radius: 1.0
//   navigation/3d/use_edge_connections: true
//   navigation/3d/merge_rasterizer_cell_scale: 1.0
//
// The tools read them from the scene's project's hedra.yaml
// (../../source/project/navigation_settings.as); a built project passes the
// lines of these keys to registerProject with the screen quality's
// (../runtime/projects.as `settings`, RegisteredProject.navigationSettings),
// so a scene's map is the same in the tools and in a built project. A
// value that is not a number (or a bool) is a warning, and the default is
// kept.

import { parseF64 } from "../../base/parse";

export const SETTING_NAV_CELL_SIZE = "navigation/3d/default_cell_size";
export const SETTING_NAV_CELL_HEIGHT = "navigation/3d/default_cell_height";
export const SETTING_NAV_EDGE_CONNECTION_MARGIN = "navigation/3d/default_edge_connection_margin";
export const SETTING_NAV_LINK_CONNECTION_RADIUS = "navigation/3d/default_link_connection_radius";
export const SETTING_NAV_USE_EDGE_CONNECTIONS = "navigation/3d/use_edge_connections";
export const SETTING_NAV_MERGE_RASTERIZER_CELL_SCALE = "navigation/3d/merge_rasterizer_cell_scale";

// Every key, for the generated hedra_project.as (the lines it passes).
export const NAVIGATION_SETTING_KEYS: StaticArray<string> = [
    SETTING_NAV_CELL_SIZE, SETTING_NAV_CELL_HEIGHT, SETTING_NAV_EDGE_CONNECTION_MARGIN, SETTING_NAV_LINK_CONNECTION_RADIUS,
    SETTING_NAV_USE_EDGE_CONNECTIONS, SETTING_NAV_MERGE_RASTERIZER_CELL_SCALE,
];

export class NavigationSettings {
    cellSize: f32 = 0.25;
    cellHeight: f32 = 0.25;
    edgeConnectionMargin: f32 = 0.25;
    linkConnectionRadius: f32 = 1.0;
    useEdgeConnections: bool = true;
    // Godot's merge_rasterizer_cell_scale: the polygons' corners are joined
    // on a grid of cellSize times this (and cellHeight times it).
    mergeRasterizerCellScale: f32 = 1.0;

    copyFrom(o: NavigationSettings): void {
        this.cellSize = o.cellSize;
        this.cellHeight = o.cellHeight;
        this.edgeConnectionMargin = o.edgeConnectionMargin;
        this.linkConnectionRadius = o.linkConnectionRadius;
        this.useEdgeConnections = o.useEdgeConnections;
        this.mergeRasterizerCellScale = o.mergeRasterizerCellScale;
    }

    equals(o: NavigationSettings): bool {
        return this.cellSize == o.cellSize && this.cellHeight == o.cellHeight
            && this.edgeConnectionMargin == o.edgeConnectionMargin && this.linkConnectionRadius == o.linkConnectionRadius
            && this.useEdgeConnections == o.useEdgeConnections && this.mergeRasterizerCellScale == o.mergeRasterizerCellScale;
    }
}

// Whether `key` is one of the navigation settings.
export function isNavigationSetting(key: string): bool {
    for (let i = 0; i < NAVIGATION_SETTING_KEYS.length; i++) if (NAVIGATION_SETTING_KEYS[i] == key) return true;
    return false;
}

// `out` with the navigation keys of `text` (hedra.yaml's lines, or the
// generated module's) set; a bad value is a warning
// ("hedra.yaml: <key> is <v>, not a number above 0"), the default kept.
// Other keys are passed over. Returns `out`.
export function navigationSettingsFromText(text: string, out: NavigationSettings, warnings: Array<string>): NavigationSettings {
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i];
        const hash = line.indexOf("#");
        if (hash >= 0) line = line.substring(0, hash);
        line = line.trim();
        const colon = line.indexOf(":");
        if (colon <= 0) continue;
        const key = line.substring(0, colon).trim();
        if (!isNavigationSetting(key)) continue;
        let value = line.substring(colon + 1).trim();
        if (value.length >= 2 && (value.startsWith("\"") && value.endsWith("\"") || value.startsWith("'") && value.endsWith("'"))) {
            value = value.substring(1, value.length - 1);
        }
        if (key == SETTING_NAV_USE_EDGE_CONNECTIONS) {
            if (value == "true") out.useEdgeConnections = true;
            else if (value == "false") out.useEdgeConnections = false;
            else warnings.push("hedra.yaml: " + key + " is " + value + ", not true or false");
            continue;
        }
        const n = parseF64(value);
        if (!n.ok || !(n.value > 0) || !isFinite(n.value)) {
            warnings.push("hedra.yaml: " + key + " is " + value + ", not a number above 0");
            continue;
        }
        const f = <f32>n.value;
        if (key == SETTING_NAV_CELL_SIZE) out.cellSize = f;
        else if (key == SETTING_NAV_CELL_HEIGHT) out.cellHeight = f;
        else if (key == SETTING_NAV_EDGE_CONNECTION_MARGIN) out.edgeConnectionMargin = f;
        else if (key == SETTING_NAV_LINK_CONNECTION_RADIUS) out.linkConnectionRadius = f;
        else out.mergeRasterizerCellScale = f;
    }
    return out;
}
