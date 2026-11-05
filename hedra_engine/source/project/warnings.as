// A loaded scene's warnings as every command reports them.
//
// A node's script takes the node's properties its class does not have as
// the script's exported properties (docs/formats/RSCN.md, "Scripts"),
// whichever declaration set them: the node's own, an instance root's or an
// override's, and whichever of them set `script`. The validator and the
// instancer know only the node's class, so they warn `property-unknown`
// about each of them; the script takes them, so they are not unknown.
// `render`, `inspect` (every view, --check included) and `build` drop those
// warnings here, so the three commands agree on what a scene's warnings are,
// and the scene editor's Output panel shows the same (milestone 7 moved this
// module here from editor/program/src/app/warnings.as, which re-exports it).
//
// Milestone 15 adds the warnings of the ArtboardTextures the tree draws
// (artboardDiagnostics): they are problems of the loaded tree rather than of
// one document (a texture is checked against the .riv it names, which only
// the loader reads), so they are found here, once, for every command.
//
// Milestone 16 adds those of the ArtboardSprite3Ds that draw nothing
// (spriteDiagnostics): one without a texture, and one whose rectangle is
// empty (pixel_size, or its texture's size, 0 or less), each at the
// node's declaration.
//
// Milestone 17 adds those of the scene's view model and bindings
// (../binding/binder.as bindingDiagnostics): a view model that does not
// resolve, and each binding that cannot run (an unknown path, a kind that
// cannot drive its target, a material target without a material, ...). A
// scene without either has none.
//
// Milestone 19 adds those of its LightmapGIs (lightmapDiagnostics): every
// one but the one used, which are not (`lightmap-gi-multiple`), and one
// without light_data (`lightmap-no-data`: the scene is drawn in real time
// until it is baked).
//
// Milestone 20 adds those of its ReflectionProbes (probeDiagnostics): a
// visible once probe without a usable capture (`reflection-probe-no-data`:
// it is captured when drawn), one moved since its capture
// (`reflection-probe-moved`), one whose size, interior or enable_shadows
// changed since (`reflection-probe-changed`), and the visible probes past
// the 8 a frame draws (`reflection-probe-too-many`).
//
// Milestone 31 adds Godot's configuration warnings of its collision nodes
// (interactionDiagnostics), each at the node's declaration: a
// CollisionShape3D whose parent is no CollisionObject3D
// (`collision-shape-parent`), one without a shape
// (`collision-shape-missing`), a CollisionObject3D without a
// CollisionShape3D child (`collision-object-no-shape`), a CollisionShape3D
// scaled non-uniformly (`collision-shape-scale`: exact here, approximate
// in Godot, so it is said for a scene meant for both), and one whose
// ConvexPolygonShape3D has no volume (`convex-shape-flat`).
//
// Milestone 32 adds Godot's configuration warnings of a PathFollow3D
// (pathDiagnostics), at the node's declaration and, as Godot's, only for
// one visible in the tree: one whose parent is not a Path3D
// (`path-follow-parent`), and an oriented one whose Path3D's curve bakes no
// up vectors (`path-follow-up-vector`).
//
// Milestone 33 adds Godot's configuration warnings of a Decal
// (decalDiagnostics), at the node's declaration, hidden ones included (a
// binding, a timeline or a script may show them): one without any texture
// (`decal-no-texture`), one with a normal or ORM texture but no albedo
// (`decal-no-albedo`: the albedo's alpha blends them), one whose cull_mask
// is 0 (`decal-cull-mask`), and one whose file gives a size of 0 or less
// on an axis (`decal-size`: held to 0.001 there, as Godot's set_size
// holds it). What a whole scene's decals ask of the renderer's budgets is
// the compiler's (hedra_compiler/check/decals.as).
//
// Milestone 34 adds those of the SubViewports and ViewportTextures
// (viewportDiagnostics; ../../scene/tree/viewports.as has the rules):
// each ViewportTexture a drawn material or decal holds that shows no
// SubViewport (`viewport-texture-path`: no viewport_path;
// `viewport-texture-missing`: it names no node; `viewport-texture-not-
// subviewport`: it names a node of another class), one declared in a scene
// instanced more than once (`viewport-texture-shared`: every instance
// shows the first one's SubViewport, where Godot makes it local to each),
// one in a slot composed on the CPU (`viewport-texture-extension`), one
// that is a sky's panorama (`viewport-texture-panorama`: read on the CPU
// once, so never live, the sky black), each at the texture's
// <sub_resource>; and each SubViewport without a camera
// (`viewport-no-camera`) or whose size is out of range (`viewport-size`),
// at the node's declaration. What a scene's viewports ask of the
// renderer's budgets is the compiler's (hedra_compiler/check/viewports.as).
//
// Milestone 35 adds those of the CPUParticles3D nodes and of the billboard
// materials (particleDiagnostics), each at the node's declaration, hidden
// ones included, Godot's sentence opening the hint where Godot has one: an
// emitter without a mesh (`particles-no-mesh`), whose file's amount is out
// of 1 to 10000 (`particles-amount`: it emits the nearest) or lifetime
// below 0.01 (`particles-lifetime`), that emits from points without any
// (`particles-no-points`) or from an emission_points_from that gives none
// (`particles-points-from`: no node, no mesh node, no triangles), whose
// emission_normals or emission_colors are of another count than its points
// (`particles-normals`, `particles-colors`: not used, as Godot uses them
// only when the counts agree), whose colours its mesh's material does not
// draw (`particles-vertex-color`: no vertex_color_use_as_albedo), or whose
// billboards drop its scale (`particles-billboard-scale`: no
// billboard_keep_scale); and each node other than an emitter drawing a
// material whose billboard_mode is set (`material-billboard-ignored`: the
// turn is the particles' alone here). What a scene's particles cost a
// frame is the compiler's (hedra_compiler/check/particles.as).
//
// Milestone 36 adds those of the AudioStreamPlayer3D and AudioListener3D
// nodes (audioDiagnostics), each at the node's declaration: what the
// runtime cannot play as Godot does (`audio-no-stream`, `audio-pitch`,
// `audio-doppler`, `audio-bus`, `audio-filter`, `audio-polyphony`,
// `audio-not-panned`, `audio-loop-mode`, `audio-loop-begin`,
// `audio-loop-short`) and a current listener that another, after it,
// takes the place of (`audio-listeners`). What a scene's sounds cost is the compiler's
// (hedra_compiler/check/audio.as).

import { fogDiagnostics } from "./fog_warnings";
import { occluderDiagnostics } from "./occluder_warnings";
import { shaderDiagnostics } from "./shader_warnings";
import { screenProblems } from "./screen_warnings";
import { navigationDiagnostics } from "./navigation_warnings";
import { navigationAgentDiagnostics } from "./navigation_agent_warnings";
import { vfs } from "../../fs/vfs";
import { Diagnostic, Severity, whereText } from "../../scene/error";
import { NodeDecl, RscnDoc } from "../../scene/rscn/doc";
import { ResourceLoader } from "../../scene/resource/loader";
import {
    ArrayMesh, ArtboardTexture, ConvexPolygonShape3D, Mesh, PackedScene, Script, StandardMaterial3D,
} from "../../scene/resource/types";
import {
    VIEWPORT_TARGET_NOT_FOUND, VIEWPORT_TARGET_NO_PATH, VIEWPORT_TARGET_NOT_SUBVIEWPORT, panoramaViewportTextures,
    sceneRootsOf, viewportGraph,
} from "../../scene/tree/viewports";
import { viewportTextureDeclarer, viewportTextureKey } from "../../scene/resource/viewport_texture";
import { MAX_VIEWPORT_SIDE } from "../../render/viewport";
import { PBR_SLOT_COUNT } from "../../material/pbr";
import {
    ARTBOARD_DOC, ArtboardProblem, artboardTextureDeclarer, artboardTextureKey, artboardTextureProblems,
} from "../../scene/resource/artboard_texture";
import { ArtboardSlots, artboardSlotsOf, artboardSlotsOfMaterial, artboardTexturesOf, panoramaArtboardTextures }
    from "../../scene/tree/artboards";
import { MATERIAL_TEXTURE_PROPS } from "../../scene/classdb";
import { SceneTree, underSubViewport } from "../../scene/tree/tree";
import { ValueKind } from "../../scene/value";
import {
    ArtboardSprite3D, AudioListener3D, AudioStreamPlayer3D, CPUParticles3D, CollisionObject3D, CollisionShape3D, Decal,
    LightmapGI, MeshInstance3D, ModelInstance3D, MultiMeshInstance3D, Path3D, PathFollow3D, ReflectionProbe, SceneNode,
    SubViewport,
} from "../../scene/tree/node";
import {
    AUDIO_FORMAT_FLAC, AUDIO_FORMAT_MP3, AUDIO_FORMAT_WAV, AUDIO_LOOP_BACKWARD, AUDIO_LOOP_PINGPONG, AudioStream,
} from "../../scene/resource/audio_stream";
import { MAX_AUDIO_POLYPHONY } from "../../scene/audio/state";
import { AUDIO_LOOP_SHORTEST, streamLoopBegin, streamPassEnd } from "../../scene/audio/clock";
import { toAsciiLowercase } from "../../base/util";
import { PrimitiveMesh } from "../../scene/resource/primitives";
import { materialLabel } from "../../scene/render/materials";
import {
    EMISSION_DIRECTED_POINTS, EMISSION_POINTS, MAX_PARTICLE_AMOUNT, MIN_PARTICLE_LIFETIME,
} from "../../scene/particles/state";
import { POINTS_EMPTY, POINTS_NOT_MESH, POINTS_NO_NODE, pointsFromNode } from "../../scene/particles/points";
import { isBillboard } from "../../scene/particles/pack";
import { ROTATION_ORIENTED } from "../../scene/path/follow";
import { convexHull } from "../../scene/interaction/hull";
import { MAX_PROBES, PROBE_FACE_SIZE, PROBE_UPDATE_ALWAYS, isProbeCube } from "../../render/probe/data";
import { PROBE_MOVED_TOLERANCE, probeCaptureInScene } from "../../scene/render/probes";
import { RPROBE_INTERIOR, RPROBE_SHADOWS } from "../../scene/probe/rprobe";
import { spriteRect } from "../../scene/render/billboard";
import { displayF32, displayF64 } from "../../base/fmt";
import { Vec3 } from "../../base/vecmath";
import { DECAL_TEXTURE_ALBEDO, DECAL_TEXTURE_NORMAL, DECAL_TEXTURE_ORM } from "../../render/decal";
import { bindingDiagnostics } from "../../scene/binding/binder";
import { scanScript } from "./script_scan";
import { CLI } from "../../base/names";

// The nodes of `tree` that the declaration `decl` of the document at
// `docAbs` lands on: its path from the root of each instance of that
// document (instancePaths, so that a scene reached only as the root of
// another instanced scene is found too), or from the tree's root for the
// root scene itself (a scene cannot instance itself). A document neither
// instanced nor the root scene lands nowhere: resolving it against the
// tree's root would check its properties against the wrong node. (the CLI's
// `build`'s script check, editor/program/src/build/script_check.as, uses it
// too.)
export function landedNodes(tree: SceneTree, docAbs: string, decl: NodeDecl): Array<SceneNode> {
    return landedFrom(landedRoots(tree, docAbs), decl);
}

// The roots landedNodes resolves a declaration of the document at `docAbs`
// from (one walk of the tree: a caller asking for every declaration of a
// document finds them once).
export function landedRoots(tree: SceneTree, docAbs: string): Array<SceneNode> {
    const roots = new Array<SceneNode>();
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) if (all[i].instancePaths.includes(docAbs)) roots.push(all[i]);
    if (roots.length == 0 && docAbs == tree.scenePath) roots.push(tree.root);
    return roots;
}

// landedNodes from the document's `roots` (landedRoots).
export function landedFrom(roots: Array<SceneNode>, decl: NodeDecl): Array<SceneNode> {
    const out = new Array<SceneNode>();
    const path = decl.path();
    for (let i = 0; i < roots.length; i++) {
        const n = path == "." ? roots[i] : roots[i].getNode(path);
        if (n != null) out.push(n);
    }
    return out;
}

// Whether the property at `line`:`col` of `doc` (at `docAbs`) is a script's
// exported property (src/build/script_scan.as). With the loaded `tree`: every
// node the declaration that sets it lands on has a script, set by whichever
// layer, whose class exports a property of that name. Without one (a scene
// that did not load): the declaration itself sets `script` to a Script
// ext_resource that exports it.
export function exportedProperty(
    loader: ResourceLoader, docAbs: string, doc: RscnDoc, line: i32, col: i32, tree: SceneTree? = null,
): bool {
    const nodes = doc.nodes();
    for (let i = 0; i < nodes.length; i++) {
        const decl: NodeDecl = nodes[i];
        const props = decl.properties();
        for (let k = 0; k < props.length; k++) {
            const prop = props[k];
            if (prop.pos.line != line || prop.pos.col != col) continue;
            if (tree != null) {
                const landed = landedNodes(tree, docAbs, decl);
                if (landed.length == 0) return false;
                for (let j = 0; j < landed.length; j++) {
                    const s = landed[j].script;
                    if (s == null || scanScript((s as Script).source).field(prop.name) == null) return false;
                }
                return true;
            }
            const s = decl.property("script");
            if (s == null || s.value.kind != ValueKind.ExtResource) return false;
            const ext = doc.findExt(s.value.s);
            if (ext == null || ext.type != "Script") return false;
            const abs = loader.resolve(ext.path, docAbs);
            if (!abs.ok) return false;
            const src = vfs.readToString(abs.value);
            if (!src.ok) return false;
            return scanScript(src.value).field(prop.name) != null;
        }
    }
    return false;
}

// A loaded scene's diagnostics without the property-unknown warnings that
// are scripts' exported properties (exportedProperty).
export function sceneDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const scenes = tree.loader.loaded();
    const out = new Array<Diagnostic>();
    const items = tree.diagnostics.items;
    for (let i = 0; i < items.length; i++) {
        const d = items[i];
        let drop = false;
        if (d.code == "property-unknown" && d.severity == Severity.Warning) {
            for (let k = 0; k < scenes.length && !drop; k++) {
                const r = scenes[k];
                if (!(r instanceof PackedScene)) continue;
                const doc = (r as PackedScene).doc;
                if (doc != null && doc.file == d.file) drop = exportedProperty(tree.loader, r.path, doc, d.line, d.col, tree);
            }
        }
        if (!drop) out.push(d);
    }
    const art = artboardDiagnostics(tree);
    for (let i = 0; i < art.length; i++) out.push(art[i]);
    const sprites = spriteDiagnostics(tree);
    for (let i = 0; i < sprites.length; i++) out.push(sprites[i]);
    const bindings = bindingDiagnostics(tree);
    for (let i = 0; i < bindings.length; i++) out.push(bindings[i]);
    const lightmaps = lightmapDiagnostics(tree);
    for (let i = 0; i < lightmaps.length; i++) out.push(lightmaps[i]);
    const probes = probeDiagnostics(tree);
    for (let i = 0; i < probes.length; i++) out.push(probes[i]);
    const shapes = interactionDiagnostics(tree);
    for (let i = 0; i < shapes.length; i++) out.push(shapes[i]);
    const paths = pathDiagnostics(tree);
    for (let i = 0; i < paths.length; i++) out.push(paths[i]);
    const decals = decalDiagnostics(tree);
    for (let i = 0; i < decals.length; i++) out.push(decals[i]);
    const viewports = viewportDiagnostics(tree);
    for (let i = 0; i < viewports.length; i++) out.push(viewports[i]);
    const particles = particleDiagnostics(tree);
    for (let i = 0; i < particles.length; i++) out.push(particles[i]);
    const audio = audioDiagnostics(tree);
    for (let i = 0; i < audio.length; i++) out.push(audio[i]);
    // Milestone 37: the fog volumes' and the occluders' (their own files).
    const fog = fogDiagnostics(tree);
    for (let i = 0; i < fog.length; i++) out.push(fog[i]);
    const occluders = occluderDiagnostics(tree);
    for (let i = 0; i < occluders.length; i++) out.push(occluders[i]);
    // Milestone 61: the custom shader materials' (their shaders' own too).
    const shaders = shaderDiagnostics(tree);
    for (let i = 0; i < shaders.length; i++) out.push(shaders[i]);
    // Milestone 62: the screen-space effects' (screen_warnings.as).
    const screen = screenProblems(tree);
    for (let i = 0; i < screen.length; i++) out.push(screen[i]);
    // Milestone 63: the navigation's: its regions, meshes and links
    // (navigation_warnings.as), its agents and obstacles
    // (navigation_agent_warnings.as).
    const navigation = navigationDiagnostics(tree);
    for (let i = 0; i < navigation.length; i++) out.push(navigation[i]);
    const agents = navigationAgentDiagnostics(tree);
    for (let i = 0; i < agents.length; i++) out.push(agents[i]);
    return out;
}

// Where the collision nodes' warnings point.
const INTERACTION_DOC = "docs/formats/RSCN.md \"Interaction\"";
// Godot's own sentences (its configuration warnings), as the hints.
export const SHAPE_PARENT_HINT = "CollisionShape3D only serves to provide a collision shape to a CollisionObject3D derived node: "
    + "make it a child of an Area3D or a StaticBody3D; see " + INTERACTION_DOC;
export const SHAPE_MISSING_HINT = "a shape must be provided for CollisionShape3D to function: set its shape to a BoxShape3D, "
    + "SphereShape3D, CapsuleShape3D, CylinderShape3D, ConvexPolygonShape3D or ConcavePolygonShape3D; see " + INTERACTION_DOC;
export const OBJECT_NO_SHAPE_HINT = "consider adding a CollisionShape3D as a child to define its shape; see " + INTERACTION_DOC;
export const SHAPE_SCALE_HINT = "Godot handles a non-uniformly scaled shape approximately: make the scale uniform (the same on "
    + "all axes) and change the size of the shape resource instead; see " + INTERACTION_DOC;
export const CONVEX_FLAT_HINT = "a convex shape needs four points or more, not all in one plane; Create Single Convex Collision "
    + "Sibling makes one from a mesh; see " + INTERACTION_DOC;
// How much a CollisionShape3D's axes may differ in length, relative to the
// longest, and still count as scaled uniformly (float noise of a rotation
// is far below it).
export const SHAPE_SCALE_TOLERANCE: f64 = 1e-4;

// The warnings of the collision nodes of `tree` (see the header), in tree
// order, each at the node's declaration (nodeDeclaration), hidden nodes
// included (visibility changes nothing about collisions, as in Godot).
export function interactionDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        const isObject = n instanceof CollisionObject3D;
        if (isObject) {
            let shapes = 0;
            for (let k = 0; k < n.children.length; k++) {
                const isShape = n.children[k] instanceof CollisionShape3D;
                if (isShape) shapes++;
            }
            if (shapes == 0) {
                pushAt(out, tree, n, "collision-object-no-shape",
                    n.path() + " (" + n.className + ") has no shape, so it can't collide or interact with other objects",
                    OBJECT_NO_SHAPE_HINT);
            }
            continue;
        }
        const isShapeNode = n instanceof CollisionShape3D;
        if (!isShapeNode) continue;
        const c = n as CollisionShape3D;
        if (c.owner3d() == null) {
            pushAt(out, tree, n, "collision-shape-parent",
                c.path() + " gives its shape to nothing: a CollisionShape3D's parent is an Area3D or a StaticBody3D",
                SHAPE_PARENT_HINT);
        }
        const shape = c.shape;
        if (shape == null) {
            pushAt(out, tree, n, "collision-shape-missing",
                c.path() + " has no shape: it gives its object nothing to collide with", SHAPE_MISSING_HINT);
        }
        const scale = nonUniformScale(c);
        if (scale.length > 0) {
            pushAt(out, tree, n, "collision-shape-scale",
                c.path() + " is scaled non-uniformly (" + scale + "): exact here, approximate in Godot", SHAPE_SCALE_HINT);
        }
        if (shape == null) continue;
        const isConvex = shape instanceof ConvexPolygonShape3D;
        if (!isConvex) continue;
        const points = (shape as ConvexPolygonShape3D).points;
        if (convexHull(points).solid()) continue;
        const count = points.length / 3;
        pushAt(out, tree, n, "convex-shape-flat",
            c.path() + "'s ConvexPolygonShape3D has no volume (" + count.toString() + (count == 1 ? " point" : " points")
                + ", none of them off one plane): nothing overlaps it or is in it, and rays never meet it",
            CONVEX_FLAT_HINT);
    }
    return out;
}

// Where the path nodes' warnings point.
const PATHS_DOC = "docs/formats/RSCN.md \"Paths\"";
// Godot's own sentences (PathFollow3D::get_configuration_warnings), as the
// hints.
export const FOLLOW_PARENT_HINT = "PathFollow3D only works when set as a child of a Path3D node; see " + PATHS_DOC;
export const FOLLOW_UP_VECTOR_HINT = "PathFollow3D's ROTATION_ORIENTED requires \"Up Vector\" to be enabled in its parent "
    + "Path3D's Curve resource; see " + PATHS_DOC;

// The warnings of the PathFollow3Ds of `tree` (see the header), in tree
// order, each at the node's declaration; a node hidden in the tree has
// none, as in Godot (whose warnings ask is_visible_in_tree()).
export function pathDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        const isFollower = n instanceof PathFollow3D;
        if (!isFollower || !n.visibleInTree()) continue;
        const f = n as PathFollow3D;
        const parent = f.parent;
        const isPath = parent instanceof Path3D;
        if (!isPath) {
            pushAt(out, tree, n, "path-follow-parent",
                "PathFollow3D " + f.path() + " is not a child of a Path3D: it stays where its transform puts it",
                FOLLOW_PARENT_HINT);
            continue;
        }
        const c = (parent as Path3D).curve;
        if (c == null || c.upVectorEnabled || f.rotationMode != ROTATION_ORIENTED) continue;
        pushAt(out, tree, n, "path-follow-up-vector",
            "PathFollow3D " + f.path() + " is oriented, but its curve bakes no up vectors: it turns about the curve's tangent as +y allows",
            FOLLOW_UP_VECTOR_HINT);
    }
    return out;
}

// Where a Decal's warnings point (the compiler's budget rules too).
export const DECALS_DOC = "docs/formats/RSCN.md \"Decals\"";
// Where the lights' budget warnings point (milestone 59: the compiler's
// light-too-many, hedra_compiler/check/lights.as): the lighting page's
// "Many lights", which says how a frame's 64 and an object's 8 are chosen.
export const LIGHTING_DOC = "docs/engine/LIGHTING.md";
// Godot's own sentences (Decal::get_configuration_warnings), as the hints.
export const DECAL_NO_TEXTURE_HINT = "The decal has no textures loaded into any of its texture properties, and will "
    + "therefore not be visible; see " + DECALS_DOC;
export const DECAL_NO_ALBEDO_HINT = "An Albedo texture with an alpha channel is required to blend the normal/ORM maps "
    + "onto the underlying surface. If you don't want the Albedo texture to be visible, set Albedo Mix to 0; see "
    + DECALS_DOC;
export const DECAL_CULL_MASK_HINT = "enable at least one bit in the Cull Mask property; see " + DECALS_DOC;
export const DECAL_SIZE_HINT = "size is the decal's box in metres, above 0 on every axis; see " + DECALS_DOC;

// The warnings of the Decals of `tree` (see the header), in tree order,
// each at the node's declaration, hidden ones included.
export function decalDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const all = tree.decals();
    for (let i = 0; i < all.length; i++) {
        const d = all[i];
        const albedo = d.textureAt(DECAL_TEXTURE_ALBEDO) != null;
        const blended = d.textureAt(DECAL_TEXTURE_NORMAL) != null || d.textureAt(DECAL_TEXTURE_ORM) != null;
        if (!albedo && !blended && d.textureEmission == null) {
            pushAt(out, tree, d, "decal-no-texture", "Decal " + d.path() + " has no texture: it draws nothing",
                DECAL_NO_TEXTURE_HINT);
        } else if (!albedo && blended) {
            pushAt(out, tree, d, "decal-no-albedo", "Decal " + d.path()
                + " has a normal or ORM texture but no texture_albedo: the albedo's alpha blends them, so they draw nothing",
                DECAL_NO_ALBEDO_HINT);
        }
        if (d.cullMask == 0) {
            pushAt(out, tree, d, "decal-cull-mask", "Decal " + d.path() + "'s cull_mask is 0: it paints nothing",
                DECAL_CULL_MASK_HINT);
        }
        const axes = nonPositiveAxes(d);
        if (axes.length > 0) {
            pushAt(out, tree, d, "decal-size", "Decal " + d.path() + "'s size is not positive on " + axes
                + ": drawn at 0.001 m there", DECAL_SIZE_HINT);
        }
    }
    return out;
}

// Where the viewports' warnings point (the compiler's budget rules too).
export const VIEWPORTS_DOC = "docs/formats/RSCN.md \"Viewports\"";
// The hints, Godot's own sentences first where it has one (ViewportTexture's
// errors).
export const VIEWPORT_PATH_HINT = "Path to node is empty: set viewport_path to the SubViewport's path from the root of "
    + "the scene that declares the texture; see " + VIEWPORTS_DOC;
export const VIEWPORT_SHARED_HINT = "Godot makes a ViewportTexture local to each instance of its scene; here every "
    + "instance shows the first one's: declare the texture in the scene that instances it; see " + VIEWPORTS_DOC;
export const VIEWPORT_EXTENSION_HINT = "a viewport is live in albedo, emission, normal, metallic, roughness or ambient "
    + "occlusion; see " + VIEWPORTS_DOC;
export const VIEWPORT_CAMERA_HINT = "add a Camera3D under it: it looks through the first one with current on, else the "
    + "first; see " + VIEWPORTS_DOC;
export const VIEWPORT_SIZE_HINT = "size is the picture's width and height in pixels; see " + VIEWPORTS_DOC;
export const VIEWPORT_PANORAMA_HINT = "a panorama is read on the CPU once, so it cannot be live; show the viewport on a "
    + "mesh's material instead; see " + VIEWPORTS_DOC;

// The warnings of the SubViewports of `tree` and of the ViewportTextures
// its nodes show (see the header): the textures' in the order the viewport
// graph finds them, then the SubViewports' in tree order, hidden ones
// included (a binding, a timeline or a script may show them).
export function viewportDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const g = viewportGraph(tree);
    const panoramas = panoramaViewportTextures(tree);
    if (g.viewports.length == 0 && g.textures.length == 0 && panoramas.length == 0) return out;
    const walked = tree.walk();
    for (let i = 0; i < g.textures.length; i++) {
        const t = g.textures[i];
        const abs = viewportTextureDeclarer(t);
        const at = subResourceAt(tree, abs, viewportTextureKey(t));
        const name = "ViewportTexture \"" + viewportTextureKey(t) + "\"";
        const named = name + ": viewport_path \"" + t.viewportPath + "\" names ";
        const roots = sceneRootsOf(tree, walked, abs);
        const problem = g.problem[i];
        if (problem == VIEWPORT_TARGET_NO_PATH) {
            at.warn(out, "viewport-texture-path", name + " has no viewport_path: it draws transparent black",
                VIEWPORT_PATH_HINT);
        } else if (problem == VIEWPORT_TARGET_NOT_FOUND) {
            at.warn(out, "viewport-texture-missing", named + "no node: it draws transparent black",
                "ViewportTexture: Path to node is invalid; " + viewportsFrom(walked, roots));
        } else if (problem == VIEWPORT_TARGET_NOT_SUBVIEWPORT) {
            const n = roots[0].getNode(t.viewportPath)!;
            at.warn(out, "viewport-texture-not-subviewport", named + n.path() + ", " + article(n.className) + " "
                + n.className + ", not a SubViewport: it draws transparent black",
                "Path to node does not point to a SubViewport; " + viewportsFrom(walked, roots));
        }
        const target = g.target[i];
        if (g.shared[i] && target >= 0) {
            at.warn(out, "viewport-texture-shared", name + " is declared in " + tree.loader.displayPath(abs)
                + ", instanced " + roots.length.toString() + " times: every instance shows the first one's SubViewport "
                + g.viewports[target].path(), VIEWPORT_SHARED_HINT);
        }
        const ext = artboardSlotsOf(tree, t).extension;
        if (ext >= 0) {
            at.warn(out, "viewport-texture-extension", name + " in " + MATERIAL_TEXTURE_PROPS[ext]
                + " is drawn transparent black: that slot is composed on the CPU, so it cannot be live",
                VIEWPORT_EXTENSION_HINT);
        }
    }
    // (a sky's panorama: never live, whatever it names)
    for (let i = 0; i < panoramas.length; i++) {
        const t = panoramas[i];
        const at = subResourceAt(tree, viewportTextureDeclarer(t), viewportTextureKey(t));
        at.warn(out, "viewport-texture-panorama", "ViewportTexture \"" + viewportTextureKey(t)
            + "\" is a sky's panorama: the sky draws black, in a built project too", VIEWPORT_PANORAMA_HINT);
    }
    for (let k = 0; k < g.viewports.length; k++) {
        const v = g.viewports[k];
        if (g.camera[k] == null) {
            pushAt(out, tree, v, "viewport-no-camera", "SubViewport " + v.path() + " has no Camera3D: it draws nothing",
                VIEWPORT_CAMERA_HINT);
        }
        if (v.sizeX != v.width || v.sizeY != v.height) {
            pushAt(out, tree, v, "viewport-size", "SubViewport " + v.path() + "'s size Vector2i(" + v.sizeX.toString()
                + ", " + v.sizeY.toString() + ") is out of range: each side is 1 to " + MAX_VIEWPORT_SIDE.toString()
                + "; drawn at " + v.width.toString() + " x " + v.height.toString(), VIEWPORT_SIZE_HINT);
        }
    }
    return out;
}

// Where the particles' warnings point (the compiler's budget rule too).
export const PARTICLES_DOC = "docs/formats/RSCN.md \"Particles\"";
// The hints, Godot's own sentences first where it has one
// (CPUParticles3D::get_configuration_warnings).
export const PARTICLES_NO_MESH_HINT = "Nothing is visible because no mesh has been assigned. Set mesh to a QuadMesh with a "
    + "billboard material, or any mesh; see " + PARTICLES_DOC;
export const PARTICLES_AMOUNT_HINT = "amount is how many particles one emitter keeps, 1 to "
    + MAX_PARTICLE_AMOUNT.toString() + "; see " + PARTICLES_DOC;
export const PARTICLES_LIFETIME_HINT = "lifetime is each particle's life in seconds, at least 0.01; see " + PARTICLES_DOC;
export const PARTICLES_NO_POINTS_HINT = "set emission_points (the editor's Particles menu: Create Emission Points From "
    + "Node), or name a mesh node in emission_points_from; see " + PARTICLES_DOC;
export const PARTICLES_POINTS_FROM_HINT = "emission_points_from is a path from the emitter to a MeshInstance3D or "
    + "ModelInstance3D whose mesh has triangles; see " + PARTICLES_DOC;
export const PARTICLES_NORMALS_HINT = "Godot uses emission_normals only when there is one for each emission point; see "
    + PARTICLES_DOC;
export const PARTICLES_COLORS_HINT = "Godot uses emission_colors only when there is one for each emission point; see "
    + PARTICLES_DOC;
export const PARTICLES_VERTEX_COLOR_HINT = "a particle's colour reaches its mesh as the vertex colour: set "
    + "vertex_color_use_as_albedo on the mesh's material; see " + PARTICLES_DOC;
export const PARTICLES_BILLBOARD_SCALE_HINT = "a billboard is drawn at its mesh's size unless its material sets "
    + "billboard_keep_scale, as Godot's shader draws it; see " + PARTICLES_DOC;
export const MATERIAL_BILLBOARD_HINT = "billboards are turned to the camera with a CPUParticles3D's particles; give the "
    + "material to a CPUParticles3D's mesh, or set billboard_mode to disabled; see " + PARTICLES_DOC;

// The material of a mesh's first surface (a primitive's own, an
// ArrayMesh's first surface's), or null.
function firstMaterial(mesh: Mesh?): StandardMaterial3D? {
    if (mesh == null) return null;
    const isPrimitive = mesh instanceof PrimitiveMesh;
    const isArray = mesh instanceof ArrayMesh;
    if (isPrimitive) return (mesh as PrimitiveMesh).material;
    if (isArray) {
        const surfaces = (mesh as ArrayMesh).surfaces;
        return surfaces.length > 0 ? surfaces[0].material : null;
    }
    return null;
}

// The first material of `mesh` whose billboard_mode is set, or null.
function billboardIn(mesh: Mesh?): StandardMaterial3D? {
    if (mesh == null) return null;
    const isPrimitive = mesh instanceof PrimitiveMesh;
    const isArray = mesh instanceof ArrayMesh;
    if (isPrimitive) {
        const m = (mesh as PrimitiveMesh).material;
        return m != null && isBillboard(m.billboardMode) ? m : null;
    }
    if (isArray) {
        const surfaces = (mesh as ArrayMesh).surfaces;
        for (let k = 0; k < surfaces.length; k++) {
            const m = surfaces[k].material;
            if (m != null && isBillboard(m.billboardMode)) return m;
        }
    }
    return null;
}

// The billboard material node `n` (not an emitter) draws, or null: a
// MeshInstance3D's override or mesh's, a MultiMesh's mesh's, a model's.
function ignoredBillboard(n: SceneNode): StandardMaterial3D? {
    const isMesh = n instanceof MeshInstance3D;
    const isMulti = n instanceof MultiMeshInstance3D;
    const isModel = n instanceof ModelInstance3D;
    if (isMesh) {
        const mi = n as MeshInstance3D;
        const o = mi.materialOverride;
        if (o != null) return isBillboard(o.billboardMode) ? o : null;
        return billboardIn(mi.mesh);
    }
    if (isMulti) {
        const mm = (n as MultiMeshInstance3D).multimesh;
        return mm != null ? billboardIn(mm.mesh) : null;
    }
    if (isModel) {
        const model = (n as ModelInstance3D).model;
        if (model == null) return null;
        for (let k = 0; k < model.materials.length; k++) {
            const m = model.materials[k];
            if (m != null && isBillboard(m.billboardMode)) return m;
        }
    }
    return null;
}

// The file's number for `name` on `n` (its declarations' value), or
// `fallback` when none is a number.
function fileNumber(n: SceneNode, name: string, fallback: f64): f64 {
    const v = n.getProp(name);
    if (v == null || (v.kind != ValueKind.Int && v.kind != ValueKind.Float)) return fallback;
    return v.asF64();
}

// The warnings of the CPUParticles3D nodes of `tree` and of the billboard
// materials other nodes draw (see the header), in tree order, each at the
// node's declaration, hidden ones included (a binding, a timeline or a
// script may show them).
export function particleDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const walked = tree.walk();
    let points: Array<f64>? = null;
    let normals: Array<f64>? = null;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isParticles = n instanceof CPUParticles3D;
        if (!isParticles) {
            const m = ignoredBillboard(n);
            if (m != null) {
                pushAt(out, tree, n, "material-billboard-ignored", "material " + materialLabel(m)
                    + "'s billboard_mode is drawn only on a CPUParticles3D's mesh: " + n.path()
                    + " draws it facing its own way", MATERIAL_BILLBOARD_HINT);
            }
            continue;
        }
        const p = n as CPUParticles3D;
        const name = "CPUParticles3D " + p.path();
        const mesh = p.mesh;
        if (mesh == null) pushAt(out, tree, p, "particles-no-mesh", name + " has no mesh: nothing is drawn", PARTICLES_NO_MESH_HINT);
        if (p.amountSet < 1 || p.amountSet > MAX_PARTICLE_AMOUNT) {
            pushAt(out, tree, p, "particles-amount", name + "'s amount " + p.amountSet.toString() + " is out of range: 1 to "
                + MAX_PARTICLE_AMOUNT.toString() + "; it emits " + p.amount.toString(), PARTICLES_AMOUNT_HINT);
        }
        const life = fileNumber(p, "lifetime", 1);
        if (life < <f64>MIN_PARTICLE_LIFETIME) {
            pushAt(out, tree, p, "particles-lifetime", name + "'s lifetime " + displayF32(<f32>life)
                + " is below 0.01: it lives 0.01 s", PARTICLES_LIFETIME_HINT);
        }
        const shape = p.emissionShape;
        const fromPoints = shape == EMISSION_POINTS || shape == EMISSION_DIRECTED_POINTS;
        const count = p.emissionPoints.length / 3;
        if (fromPoints && count == 0) {
            const from = p.emissionPointsFrom;
            if (from.length == 0) {
                pushAt(out, tree, p, "particles-no-points", name
                    + " emits from emission points but has none: every particle starts at its origin", PARTICLES_NO_POINTS_HINT);
            } else {
                if (points == null) points = new Array<f64>();
                if (normals == null) normals = new Array<f64>();
                const r = pointsFromNode(p, points!, normals!);
                const said = name + "'s emission_points_from \"" + from + "\" names ";
                const target = p.getNode(from);
                let what = "";
                if (r == POINTS_NO_NODE || (target == null && (r == POINTS_NOT_MESH || r == POINTS_EMPTY))) {
                    what = "no node";
                } else if (r == POINTS_NOT_MESH && target != null) {
                    what = target.path() + ", " + article(target.className) + " " + target.className
                        + ", not a MeshInstance3D or ModelInstance3D";
                } else if (r == POINTS_EMPTY && target != null) {
                    what = target.path() + ", whose mesh has no triangles";
                }
                if (what.length > 0) {
                    pushAt(out, tree, p, "particles-points-from", said + what + ": every particle starts at its origin",
                        PARTICLES_POINTS_FROM_HINT);
                }
            }
        }
        const normalCount = p.emissionNormals.length / 3;
        if (shape == EMISSION_DIRECTED_POINTS && normalCount > 0 && normalCount != count) {
            pushAt(out, tree, p, "particles-normals", name + " has " + normalCount.toString() + " emission_normals for "
                + count.toString() + " points: they are not used", PARTICLES_NORMALS_HINT);
        }
        const colorCount = p.emissionColors.length / 4;
        if (colorCount > 0 && colorCount != count) {
            pushAt(out, tree, p, "particles-colors", name + " has " + colorCount.toString() + " emission_colors for "
                + count.toString() + " points: they are not used", PARTICLES_COLORS_HINT);
        }
        if (mesh == null) continue;
        const m = firstMaterial(mesh);
        const c = p.color;
        const coloured = c.x != 1 || c.y != 1 || c.z != 1 || c.w != 1 || p.colorRamp != null || p.colorInitialRamp != null;
        if (coloured && (m == null || !m.vertexColorUseAsAlbedo)) {
            pushAt(out, tree, p, "particles-vertex-color", name
                + "'s colours are not drawn: its mesh's material does not set vertex_color_use_as_albedo",
                PARTICLES_VERTEX_COLOR_HINT);
        }
        if (m != null && isBillboard(m.billboardMode) && !m.billboardKeepScale) {
            const curves = p.splitScale
                ? p.scaleCurveX != null || p.scaleCurveY != null || p.scaleCurveZ != null
                : p.scaleAmountCurve != null;
            if (p.scaleAmountMin != 1 || p.scaleAmountMax != 1 || curves) {
                pushAt(out, tree, p, "particles-billboard-scale", name
                    + " draws its billboards at the mesh's size: set billboard_keep_scale on its material to keep the "
                    + "particles' scale", PARTICLES_BILLBOARD_SCALE_HINT);
            }
        }
    }
    return out;
}

// Where the audio warnings point.
export const AUDIO_DOC = "docs/formats/RSCN.md \"Audio\"";
const AUDIO_NO_STREAM_HINT = "set its stream to an AudioStream ext_resource of a .wav, .mp3 or .flac file; see " + AUDIO_DOC;
const AUDIO_PITCH_HINT = "the runtime plays every sound at its own speed: leave pitch_scale at 1; see " + AUDIO_DOC;
const AUDIO_DOPPLER_HINT = "set doppler_tracking to disabled (0); see " + AUDIO_DOC;
const AUDIO_BUS_HINT = "the runtime mixes every sound together: leave bus at \"Master\"; see " + AUDIO_DOC;
const AUDIO_FILTER_HINT = "leave attenuation_filter_cutoff_hz at 5000 and attenuation_filter_db at -24; see " + AUDIO_DOC;
const AUDIO_POLYPHONY_HINT = "max_polyphony is how many of its playbacks may overlap, 1 to 8; see " + AUDIO_DOC;
const AUDIO_NOT_PANNED_HINT = "use a WAV stream to hear where it is, or set panning_strength to 0; see " + AUDIO_DOC;
const AUDIO_LOOP_MODE_HINT = "set its import's loop to forward (edit/loop_mode=2 in the .import); see " + AUDIO_DOC;
const AUDIO_LOOP_BEGIN_HINT = "set its import's loop start inside the loop (edit/loop_begin below edit/loop_end for a WAV, "
    + "loop_offset below the length for an MP3 or FLAC); see " + AUDIO_DOC;
const AUDIO_LOOP_SHORT_HINT = "loop a longer stretch: repeat the cycle in the file until its loop lasts "
    + "0.05 s or more; see " + AUDIO_DOC;
const AUDIO_LISTENERS_HINT = "only the last current AudioListener3D in tree order hears the scene (as in Godot, each is made "
    + "current as it enters): clear current on the others; see " + AUDIO_DOC;

// Whether `s` is played panned: a WAV whose import made its left and right
// forms. A stream whose header was not read (the run time's text scene) is
// taken by its extension, the forms on, as the import's default.
function streamPanned(s: AudioStream): bool {
    if (s.format == AUDIO_FORMAT_WAV) return s.panForms;
    if (s.format == AUDIO_FORMAT_MP3 || s.format == AUDIO_FORMAT_FLAC) return false;
    const dot = s.path.lastIndexOf(".");
    return dot >= 0 && toAsciiLowercase(s.path.substring(dot + 1)) == "wav";
}

// The warnings of the AudioStreamPlayer3D and AudioListener3D nodes of
// `tree`, in tree order, each at the node's declaration, hidden ones
// included (Godot plays an invisible player, and hears from an invisible
// listener): a player without a stream (`audio-no-stream`); one that sets
// what the runtime cannot apply: Godot's pitch (`audio-pitch`), Doppler
// (`audio-doppler`, which is pitch), a bus of its own (`audio-bus`), the
// attenuation filter (`audio-filter`); one whose file's max_polyphony is
// out of 1 to 8 (`audio-polyphony`: it plays the nearest); one that pans
// a stream without left and right forms (`audio-not-panned`: an MP3, a
// FLAC, or a WAV whose import made none plays centred); one whose stream
// loops ping-pong or backward (`audio-loop-mode`: it plays forward); one
// whose stream's loop begins at or past its end (`audio-loop-begin`: it
// loops from 0); one whose loop is shorter than AUDIO_LOOP_SHORTEST
// (`audio-loop-short`: a built project schedules a pass a frame, so it
// plays with gaps); and
// each current AudioListener3D before the last of the scene's
// (`audio-listeners`: the last in tree order hears the scene, as Godot's
// each entering with `current` on is made current in turn; a SubViewport's
// are its own).
export function audioDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const walked = tree.walk();
    // (the scene's current listeners, in tree order: those of a SubViewport
    // are its own)
    const currents = new Array<AudioListener3D>();
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isListener = n instanceof AudioListener3D;
        if (isListener) {
            const l = n as AudioListener3D;
            if (l.current && !underSubViewport(l)) currents.push(l);
            continue;
        }
        const isPlayer = n instanceof AudioStreamPlayer3D;
        if (!isPlayer) continue;
        const p = n as AudioStreamPlayer3D;
        const name = "AudioStreamPlayer3D " + p.path();
        const s = p.stream;
        if (s == null) pushAt(out, tree, p, "audio-no-stream", name + " has no stream: nothing plays", AUDIO_NO_STREAM_HINT);
        if (p.pitchScale != 1) {
            pushAt(out, tree, p, "audio-pitch", name + " plays at pitch_scale " + displayF32(p.pitchScale)
                + ", which the runtime does not apply: it plays at 1", AUDIO_PITCH_HINT);
        }
        if (p.dopplerTracking != 0) {
            pushAt(out, tree, p, "audio-doppler", name + " tracks Doppler, which the runtime cannot apply (it has no pitch)",
                AUDIO_DOPPLER_HINT);
        }
        if (p.bus != "Master") {
            pushAt(out, tree, p, "audio-bus", name + " plays on bus \"" + p.bus + "\": every sound plays on the runtime's one mix",
                AUDIO_BUS_HINT);
        }
        if (p.attenuationFilterDb != -24 || p.attenuationFilterCutoffHz != 5000) {
            pushAt(out, tree, p, "audio-filter", name
                + " sets the attenuation filter, which the runtime cannot apply (it has no filters)", AUDIO_FILTER_HINT);
        }
        if (p.maxPolyphonySet < 1 || p.maxPolyphonySet > MAX_AUDIO_POLYPHONY) {
            pushAt(out, tree, p, "audio-polyphony", name + "'s max_polyphony " + p.maxPolyphonySet.toString()
                + " is out of range: 1 to " + MAX_AUDIO_POLYPHONY.toString() + "; it plays " + p.maxPolyphony.toString(),
                AUDIO_POLYPHONY_HINT);
        }
        if (s == null) continue;
        const file = s.path.length > 0 ? tree.loader.displayPath(s.path) : "its stream";
        if (p.panningStrength > 0 && !streamPanned(s)) {
            pushAt(out, tree, p, "audio-not-panned", name + " is played centred: " + file
                + " has no left and right forms (only a WAV does: AUDIO.md \"Panning\")", AUDIO_NOT_PANNED_HINT);
        }
        if (s.loopMode == AUDIO_LOOP_PINGPONG || s.loopMode == AUDIO_LOOP_BACKWARD) {
            pushAt(out, tree, p, "audio-loop-mode", name + "'s stream " + file + " loops "
                + (s.loopMode == AUDIO_LOOP_PINGPONG ? "ping-pong" : "backward") + ", which plays forward", AUDIO_LOOP_MODE_HINT);
        }
        if (s.loops() && s.loopBeginDropped >= 0) {
            pushAt(out, tree, p, "audio-loop-begin", name + "'s stream " + file + " loops from "
                + displayF64(s.loopBeginDropped) + " s, which is not before its loop's end: it loops from 0",
                AUDIO_LOOP_BEGIN_HINT);
        }
        if (s.loops()) {
            const passEnd = streamPassEnd(s);
            const span = passEnd - streamLoopBegin(s, passEnd);
            // (to the microsecond: a loop of 0.5 - 0.45 s is 0.05 s)
            if (passEnd > 0 && span > 0 && span < AUDIO_LOOP_SHORTEST - 1e-6) {
                pushAt(out, tree, p, "audio-loop-short", name + "'s stream " + file + " loops every "
                    + displayF64(Math.round(span * 1e6) / 1e6)
                    + " s, shorter than " + displayF64(AUDIO_LOOP_SHORTEST) + " s: in a built project it plays with gaps",
                    AUDIO_LOOP_SHORT_HINT);
            }
        }
    }
    if (currents.length > 1) {
        const heard = currents[currents.length - 1];
        for (let i = 0; i < currents.length - 1; i++) {
            const l = currents[i];
            pushAt(out, tree, l, "audio-listeners", "AudioListener3D " + l.path() + " is current, but " + heard.path()
                + " is current after it in the tree: it hears nothing", AUDIO_LISTENERS_HINT);
        }
    }
    return out;
}

// "the scene's SubViewports: A, B" (their paths from the first of `roots`,
// the root of the scene declaring a texture, among those under it; from the
// tree's root when there is none), or "the scene has no SubViewport"; and
// where the docs are.
function viewportsFrom(walked: Array<SceneNode>, roots: Array<SceneNode>): string {
    const root: SceneNode? = roots.length > 0 ? roots[0] : null;
    const paths = new Array<string>();
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isViewport = n instanceof SubViewport;
        if (!isViewport) continue;
        let under = root == null;
        let q = n.parent;
        while (q != null && !under) {
            under = q === root;
            q = q.parent;
        }
        if (under) paths.push(n.pathFrom(root));
    }
    return (paths.length == 0 ? "the scene has no SubViewport" : "the scene's SubViewports: " + paths.join(", "))
        + "; see " + VIEWPORTS_DOC;
}

// "a" or "an" before a class name.
function article(word: string): string {
    return word.length > 0 && "AEIOU".includes(word.charAt(0)) ? "an" : "a";
}

// The axes on which the size `d`'s declarations give it is 0 or less
// ("x", "x and z", "x, y and z"), "" for none (or no size of its kind:
// the validator says so).
function nonPositiveAxes(d: Decal): string {
    const v = d.getProp("size");
    if (v == null || v.kind != ValueKind.Vector3) return "";
    const s = v.vec3();
    const names = new Array<string>();
    if (!(s.x > 0)) names.push("x");
    if (!(s.y > 0)) names.push("y");
    if (!(s.z > 0)) names.push("z");
    if (names.length < 2) return names.join("");
    return names.slice(0, names.length - 1).join(", ") + " and " + names[names.length - 1];
}

// A warning of `n` at its declaration.
function pushAt(out: Array<Diagnostic>, tree: SceneTree, n: SceneNode, code: string, message: string, hint: string): void {
    out.push(nodeWarning(tree, n, code, message, hint));
}

// A warning of `n` at its declaration (nodeDeclaration): the warnings here
// and the compiler's rules about a node (hedra_compiler/check/decals.as)
// place theirs alike.
export function nodeWarning(tree: SceneTree, n: SceneNode, code: string, message: string, hint: string): Diagnostic {
    const at = nodeDeclaration(tree, n);
    return new Diagnostic(Severity.Warning, code, at.file, at.line, at.col, message, hint);
}

// The lengths of `n`'s global axes as "x, y, z" (displayF32) when they
// differ by more than SHAPE_SCALE_TOLERANCE of the longest, else "".
function nonUniformScale(n: SceneNode): string {
    const g = n.global();
    const x = <f64>g.xAxis.truncate().length();
    const y = <f64>g.yAxis.truncate().length();
    const z = <f64>g.zAxis.truncate().length();
    const hi = max<f64>(x, max<f64>(y, z));
    const lo = min<f64>(x, min<f64>(y, z));
    if (hi - lo <= SHAPE_SCALE_TOLERANCE * hi) return "";
    return displayF32(<f32>x) + ", " + displayF32(<f32>y) + ", " + displayF32(<f32>z);
}

// Where a ReflectionProbe's warnings point.
const PROBE_DOC = "docs/formats/RSCN.md \"ReflectionProbe\"";

// The warnings of the ReflectionProbes of `tree`, in tree order, each at
// the node's declaration (nodeDeclaration), for the visible ones (a hidden
// probe is not drawn, so neither captured nor counted):
//   - `reflection-probe-no-data`: one whose update_mode is once without
//     probe_data, or whose probe_data holds a capture of another size than
//     a frame draws (probe/data.as isProbeCube); a probe_data that could
//     not be read is the loader's warning already
//     (reflection-probe-data-invalid);
//   - `reflection-probe-moved`: one drawn from its capture whose capture
//     point is no longer where the capture was made (render/probes.as
//     PROBE_MOVED_TOLERANCE; the frame says so too, of a probe a binding
//     or a script moves);
//   - `reflection-probe-changed`: one drawn from its capture whose
//     `size`, `interior` or `enable_shadows` is not what its .rprobe
//     records (the capture saw another box, or lit it otherwise: what
//     the CLI's `bake --check` calls out of date);
//   - `reflection-probe-too-many`: once, at the first one past the
//     MAX_PROBES a frame draws (those past it are not drawn, so not
//     warned of otherwise).
// What of probe `node` differs from the `size` and `flags` its capture
// records, as "size", "interior" and "enable_shadows" joined by " and "
// (or ", " then " and "), "" when nothing does.
function probeChanges(node: ReflectionProbe, size: Vec3, flags: u32): string {
    const names = new Array<string>();
    if (node.size != size) names.push("size");
    if (node.interior != ((flags & RPROBE_INTERIOR) != 0)) names.push("interior");
    if (node.enableShadows != ((flags & RPROBE_SHADOWS) != 0)) names.push("enable_shadows");
    let out = "";
    for (let i = 0; i < names.length; i++) {
        out += (i == 0 ? "" : i == names.length - 1 ? " and " : ", ") + names[i];
    }
    return out;
}

export function probeDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const all = tree.reflectionProbes();
    const shown = new Array<ReflectionProbe>();
    for (let i = 0; i < all.length; i++) if (all[i].visibleInTree()) shown.push(all[i]);
    const drawn = min<i32>(shown.length, MAX_PROBES);
    for (let i = 0; i < drawn; i++) {
        const p = shown[i];
        if (p.updateMode == PROBE_UPDATE_ALWAYS) continue;
        const data = p.probeData;
        if (data == null) {
            const at = nodeDeclaration(tree, p);
            out.push(new Diagnostic(Severity.Warning, "reflection-probe-no-data", at.file, at.line, at.col,
                "reflection probe " + p.path() + " has no probe_data: it is captured when drawn; run `" + CLI + " bake`",
                "`" + CLI + " bake <scene>` captures it and sets probe_data; see " + PROBE_DOC));
            continue;
        }
        const cube = data.cube;
        if (cube == null) continue;
        if (!isProbeCube(cube)) {
            const at = nodeDeclaration(tree, p);
            out.push(new Diagnostic(Severity.Warning, "reflection-probe-no-data", at.file, at.line, at.col,
                "reflection probe " + p.path() + "'s probe_data is a capture of " + cube.size().toString()
                + " texels a face, not " + PROBE_FACE_SIZE.toString() + ": it is captured when drawn; run `" + CLI + " bake`",
                "`" + CLI + " bake <scene>` captures it again; see " + PROBE_DOC));
            continue;
        }
        if (probeCaptureInScene(p).distance(data.capture) > PROBE_MOVED_TOLERANCE) {
            const at = nodeDeclaration(tree, p);
            out.push(new Diagnostic(Severity.Warning, "reflection-probe-moved", at.file, at.line, at.col,
                "reflection probe " + p.path() + " moved since its capture; drawn from it: bake again",
                "`" + CLI + " bake <scene>` captures it where it is now; see " + PROBE_DOC));
        }
        const changed = probeChanges(p, data.size, data.flags);
        if (changed.length > 0) {
            const at = nodeDeclaration(tree, p);
            out.push(new Diagnostic(Severity.Warning, "reflection-probe-changed", at.file, at.line, at.col,
                "reflection probe " + p.path() + "'s " + changed + " changed since its capture; drawn from it: bake again",
                "`" + CLI + " bake <scene>` captures it as it is now; see " + PROBE_DOC));
        }
    }
    if (shown.length > MAX_PROBES) {
        const p = shown[MAX_PROBES];
        const left = shown.length - MAX_PROBES;
        const at = nodeDeclaration(tree, p);
        out.push(new Diagnostic(Severity.Warning, "reflection-probe-too-many", at.file, at.line, at.col,
            shown.length.toString() + " reflection probes: the last " + left.toString() + ", from " + p.path() + " on, "
            + (left == 1 ? "is" : "are") + " not drawn (at most " + MAX_PROBES.toString() + ")",
            "a frame draws the first " + MAX_PROBES.toString() + " visible reflection probes in tree order: remove or "
            + "hide some, or cover more with one box; see " + PROBE_DOC));
    }
    return out;
}

// Where a LightmapGI's warnings point.
const LIGHTMAP_DOC = "docs/formats/RSCN.md \"LightmapGI\"";

// The warnings of the LightmapGIs of `tree`, in tree order, each at the
// node's declaration (nodeDeclaration): the one used (SceneTree
// lightmapGi: the first of the scene nearest the root) without light_data
// (`lightmap-no-data`), and every other (`lightmap-gi-multiple`).
export function lightmapDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const all = tree.walk();
    const first = tree.lightmapGi();
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        const isGi = n instanceof LightmapGI;
        if (!isGi) continue;
        const gi = n as LightmapGI;
        const at = nodeDeclaration(tree, n);
        if (gi === first) {
            if (gi.lightData != null) continue;
            out.push(new Diagnostic(Severity.Warning, "lightmap-no-data", at.file, at.line, at.col,
                gi.path() + " has no light_data: the scene is drawn with real-time light; run `" + CLI + " bake`",
                "`" + CLI + " bake <scene>` bakes it and sets light_data; see " + LIGHTMAP_DOC));
        } else {
            out.push(new Diagnostic(Severity.Warning, "lightmap-gi-multiple", at.file, at.line, at.col,
                "only one LightmapGI, " + first!.path() + ", is used",
                "a scene has one bake: remove " + gi.path() + "; see " + LIGHTMAP_DOC));
        }
    }
    return out;
}

// Where an ArtboardSprite3D's warnings point (SPRITE_DOC is its section).
const SPRITE_DOC = "docs/formats/RSCN.md \"ArtboardSprite3D\"";

// The warnings of the ArtboardSprite3Ds of `tree` that draw nothing, in
// tree order, hidden ones included (a script may show them): no texture
// (`sprite-no-texture`), or an empty rectangle (`sprite-empty`:
// ../render/billboard.as spriteRect). Each at the node's declaration
// (nodeDeclaration).
export function spriteDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        const isSprite = n instanceof ArtboardSprite3D;
        if (!isSprite) continue;
        const s = n as ArtboardSprite3D;
        const t = s.texture;
        let code = "";
        let message = "";
        let hint = "";
        if (t == null) {
            code = "sprite-no-texture";
            message = "ArtboardSprite3D \"" + s.path() + "\" has no texture: it draws nothing";
            hint = "set its texture to an ArtboardTexture; see " + SPRITE_DOC;
        } else {
            const r = spriteRect(t.width, t.height, s.pixelSize, s.centered, s.offset);
            if (r.z > 0 && r.w > 0) continue;
            code = "sprite-empty";
            message = "ArtboardSprite3D \"" + s.path() + "\" is empty (pixel_size " + displayF32(s.pixelSize)
                + "): it draws nothing";
            hint = "pixel_size is the size of one texture pixel in metres, above 0; see " + SPRITE_DOC;
        }
        const at = nodeDeclaration(tree, n);
        out.push(new Diagnostic(Severity.Warning, code, at.file, at.line, at.col, message, hint));
    }
    return out;
}

// A position in a scene file.
class Where {
    file: string = "";
    line: i32 = 0;
    col: i32 = 0;

    // A warning here, onto `out`.
    warn(out: Array<Diagnostic>, code: string, message: string, hint: string): void {
        out.push(new Diagnostic(Severity.Warning, code, this.file, this.line, this.col, message, hint));
    }
}

// Where `node` is declared: the <node> of the scene that gives it its
// class (a declaration with a type), else the first declaration that
// lands on it (an override), in the order the loader read the scenes;
// the root scene's file at 0:0 when none does.
function nodeDeclaration(tree: SceneTree, node: SceneNode): Where {
    const out = new Where();
    out.file = tree.loader.displayPath(tree.scenePath);
    let found = false;
    const scenes = tree.loader.loaded();
    for (let k = 0; k < scenes.length; k++) {
        const r = scenes[k];
        const isScene = r instanceof PackedScene;
        if (!isScene) continue;
        const doc = (r as PackedScene).doc;
        if (doc == null) continue;
        const roots = landedRoots(tree, r.path);
        if (roots.length == 0) continue;
        const nodes = doc.nodes();
        for (let i = 0; i < nodes.length; i++) {
            const decl: NodeDecl = nodes[i];
            if (found && decl.type == null) continue;
            if (!landedFrom(roots, decl).includes(node)) continue;
            out.file = doc.file;
            out.line = decl.pos.line;
            out.col = decl.pos.col;
            if (decl.type != null) return out;
            found = true;
        }
    }
    return out;
}

// The warnings of every ArtboardTexture the tree draws (artboardTexturesOf,
// each texture once: a texture two materials use is one declaration), in
// that order, each problem at the texture's declaration: its <sub_resource>
// when an .rscn the load read (the root scene or an instanced one) declares
// it, else the start of the file that does (an .mtlx slot: its line is the
// material file's own business, and its reader keeps no position per
// slot).
export function artboardDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const textures = artboardTexturesOf(tree);
    // A sky's panorama: its own problems, then that it is never live
    // (../tree/artboards.as panoramaArtboardTextures).
    const panoramas = panoramaArtboardTextures(tree);
    for (let i = 0; i < panoramas.length; i++) textures.push(panoramas[i]);
    if (textures.length == 0) return out;
    for (let i = 0; i < textures.length; i++) {
        const t: ArtboardTexture = textures[i];
        const problems = artboardTextureProblems(t);
        if (panoramas.includes(t)) problems.push(panoramaProblem(t));
        else {
            const ext = extensionSlotProblem(t, artboardSlotsOf(tree, t));
            if (ext != null) problems.push(ext);
        }
        if (problems.length == 0) continue;
        const at = subResourceAt(tree, artboardTextureDeclarer(t), artboardTextureKey(t));
        for (let k = 0; k < problems.length; k++) {
            const p = problems[k];
            at.warn(out, p.code, p.message, p.hint);
        }
    }
    return out;
}

// Where the sub_resource `key` of the file at `abs` is declared: its
// <sub_resource> when an .rscn the load read declares it, else the start
// of that file.
function subResourceAt(tree: SceneTree, abs: string, key: string): Where {
    const out = new Where();
    out.file = tree.loader.displayPath(abs);
    const scenes = tree.loader.loaded();
    for (let k = 0; k < scenes.length; k++) {
        const r = scenes[k];
        const isScene = r instanceof PackedScene;
        if (!isScene || r.path != abs) continue;
        const doc = (r as PackedScene).doc;
        if (doc == null) continue;
        const decl = doc.findSub(key);
        if (decl == null) continue;
        out.file = doc.file;
        out.line = decl.pos.line;
        out.col = decl.pos.col;
        break;
    }
    return out;
}

// The warning of an ArtboardTexture that is a sky's panorama.
function panoramaProblem(t: ArtboardTexture): ArtboardProblem {
    const key = artboardTextureKey(t);
    return ArtboardProblem.warning("artboard-panorama",
        (key.length > 0 ? "ArtboardTexture \"" + key + "\"" : "an ArtboardTexture")
            + " is a sky's panorama: it draws as a placeholder, in a built project too",
        "a panorama is read on the CPU once, so it cannot be live; draw the artboard on a mesh's material instead; see "
            + ARTBOARD_DOC);
}

// The warning of an ArtboardTexture in a slot the renderer composes on
// the CPU (an extension slot: clear coat, sheen, specular, ...; or
// roughness beside another metallic texture), null when it is in none:
// there it draws its placeholder, in a built project too, as a built
// project's status says (../player/artboards.as).
function extensionSlotProblem(t: ArtboardTexture, slots: ArtboardSlots): ArtboardProblem? {
    if (slots.extension < 0) return null;
    const key = artboardTextureKey(t);
    const slot = MATERIAL_TEXTURE_PROPS[slots.extension];
    return ArtboardProblem.warning("artboard-extension-slot",
        (key.length > 0 ? "ArtboardTexture \"" + key + "\"" : "an ArtboardTexture") + " in " + slot
            + " draws as a placeholder there, in a built project too",
        "the renderer composes that slot on the CPU, so it cannot be live; an artboard plays live in albedo, emission, "
            + "normal, metallic, roughness or ambient occlusion; see " + ARTBOARD_DOC);
}

// The warnings of the ArtboardTextures of material `m`, loaded alone (a
// material file `render`, `inspect` and `inspect --check` were given, not
// a scene naming it), each problem at the start of the file that declares
// the texture, as artboardDiagnostics places an .mtlx slot's: added to
// `loader`'s diagnostics, where those commands read a material's warnings.
// Each texture once, in slot order.
export function addMaterialArtboardWarnings(loader: ResourceLoader, m: StandardMaterial3D): void {
    const seen = new Array<ArtboardTexture>();
    for (let slot = 0; slot < PBR_SLOT_COUNT; slot++) {
        const t = m.textureAt(slot);
        if (t == null) continue;
        const isArtboard = t instanceof ArtboardTexture;
        if (!isArtboard) continue;
        const a = t as ArtboardTexture;
        if (seen.includes(a)) continue;
        seen.push(a);
        const problems = artboardTextureProblems(a);
        const ext = extensionSlotProblem(a, artboardSlotsOfMaterial(m, a));
        if (ext != null) problems.push(ext);
        const file = loader.displayPath(artboardTextureDeclarer(a));
        for (let k = 0; k < problems.length; k++) {
            const p = problems[k];
            loader.diagnostics.add(new Diagnostic(Severity.Warning, p.code, file, 0, 0, p.message, p.hint));
        }
    }
}

// sceneDiagnostics as the answers' warnings: `<where>: <message>`, one line
// each, the chain of references that led there left out.
export function sceneWarnings(tree: SceneTree): Array<string> {
    const out = new Array<string>();
    const items = sceneDiagnostics(tree);
    for (let i = 0; i < items.length; i++) out.push(whereText(items[i].file, items[i].line, items[i].col) + ": " + items[i].message);
    return out;
}

// Appends a frame's warnings (SceneFrame.warnings) to `out`, an answer's
// warnings that start with sceneWarnings, leaving out any already there and
// any whose text is a diagnostic's message (`<where>: <it>`): a frame says
// some of what the diagnostics say (render/probes.as warns of a probe that
// moved since its capture, which probeDiagnostics also reports when the
// file itself moved it), and an answer says each thing once, with the
// diagnostic's place.
export function addFrameWarnings(out: Array<string>, frame: Array<string>): void {
    const n = out.length;
    for (let i = 0; i < frame.length; i++) {
        const w = frame[i];
        if (out.includes(w)) continue;
        const tail = ": " + w;
        let said = false;
        for (let k = 0; k < n && !said; k++) said = out[k].endsWith(tail);
        if (!said) out.push(w);
    }
}
