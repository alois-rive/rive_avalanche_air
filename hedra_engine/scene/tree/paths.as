// Node paths (docs/formats/RSCN.md, "Node paths"), as Godot writes them:
//
//   .            the node itself          ..        its parent
//   A/B          a child's child          /Root/A   from the tree's root,
//                                                   named by its first segment
//   %Name/B      the node marked unique_name_in_owner and named Name, among
//                those the caller owns, else its owner's; then its child B
//   A/%Name      the same from A: among the nodes A owns (A an instanced
//                scene's root: that scene's), else A's owner's
//
// `.` and `..` may appear anywhere in a path. This file only splits a path
// into its parts; SceneNode.getNode (node.as) walks them, so that the node
// class and the path rules do not import each other.

// A node path, split.
export class NodePathParts {
    // It began with "/": the first segment names the tree's root.
    absolute: bool = false;
    // The segments in order ("." and ".." kept; a "%Name" segment kept
    // with its "%").
    segments: Array<string> = [];
}

// Splits a path; null when it is empty or has an empty segment ("A//B",
// "A/", a lone "/"), which names no node.
export function splitNodePath(path: string): NodePathParts? {
    if (path.length == 0) return null;
    const parts = new NodePathParts();
    let rest = path;
    if (rest.startsWith("/")) {
        parts.absolute = true;
        rest = rest.substring(1);
    }
    const segments = rest.split("/");
    for (let i = 0; i < segments.length; i++) if (segments[i].length == 0) return null;
    parts.segments = segments;
    return parts;
}

// Whether a segment names a unique node ("%Name", with a name after the
// "%").
export function isUniqueSegment(segment: string): bool {
    return segment.length > 1 && segment.charCodeAt(0) == 37;
}

// The name a "%Name" segment looks for.
export function uniqueName(segment: string): string {
    return segment.substring(1);
}
