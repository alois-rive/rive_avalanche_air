// Instancing: a PackedScene becomes a tree of new nodes (docs/formats/RSCN.md,
// "Instancing"). For an .rscn document, each node declaration in order:
//
// - the root (the first) is a new node of its `type`, or, with `instance`,
//   the root of the instanced scene renamed (an inherited scene);
// - a node with `type` is a new node under its parent, and one with
//   `instance` an instanced scene's root under it; the parent is found by
//   its path from the root, through instanced subtrees;
// - a node with neither is an override: it names a node an instanced scene
//   (or a model) put there, and its properties and groups are laid over
//   that node's.
//
// Every declaration's properties are one layer on its node (node.as),
// resolved against the resources of the file that declares it, so that an
// outer scene's override sits on top of the instanced scene's own values.
// Then the scene's connections are resolved relative to its root, and
// unique names are checked per scene (the owner).
//
// Resources are shared (the loader's cache for ext_resources; a scene's
// sub_resources are built once per tree); nodes are always new, so a scene
// instanced twice gives two independent subtrees. A scene that
// instances itself, directly or through others, is an error, as is a chain
// of instances deeper than MAX_INSTANCE_DEPTH files. An error inside an
// instanced file keeps its own position and gets a "required by" entry for
// every instance that led to it, outermost last.
//
// Milestone 48 (docs/plans/RIVE_MODEL.md section 3.7): a scene that
// instances a model lists the model's clips as its own read-only
// animations, after the ones it declares (../anim/scene_anims.as
// ImportedModel): each node of the scene's own file that instances a model
// adds its clips, labelled with the file's name ("Walk (hero.glb)"), or
// with the node's path when two of the file's nodes instance files of one
// name; a model that is the tree's root labels them with its file's name.
// Then what only the instanced tree can tell is warned (the value kept and
// written back): a bone property or bone_name naming no bone
// (bone-unknown), a blend shape property naming no blend shape
// (blend-shape-unknown), a BoneAttachment3D whose parent is no Skeleton3D
// (bone-attachment-parent) and a skinned MeshInstance3D whose `skeleton`
// finds none (skeleton-missing).

import { Result } from "../../base/util";
import { XmlPos } from "../../base/xml";
import { SceneryError, sceneryErrorOf } from "../error";
import { findProp } from "../classdb";
import { ConnectionDecl, NodeDecl, Property, RscnDoc } from "../rscn/doc";
import { KEPT_HINT, enumRangeProblem, foundText, withArticle } from "../rscn/validate";
import { Value } from "../value";
import { DocResources, resolveResources } from "../resource/build";
import { ResourceLoader, dirOf, mountPackedScene } from "../resource/loader";
import { ModelResource, PackedScene } from "../resource/types";
import { BoneAttachment3D, MeshInstance3D, SceneNode, Skeleton3D, createNode } from "./node";
import { Connection, InstanceShare, SceneTree } from "./tree";
import { modelToNodes } from "./model_nodes";
import { attachSceneMachines, instancingWarnings } from "../sm/scene_machines";
import { StateMachine } from "../sm/machine";
import { Diagnostic } from "../error";
import {
    ImportedModel, attachModelAnimations, attachSceneAnimations, blendShapeNamesHint, boneNamesHint,
} from "../anim/scene_anims";
import { LinearAnimation } from "../anim/animation";
import {
    BLEND_SHAPES_PREFIX, BLEND_SHAPE_UNKNOWN_CODE, BONES_PREFIX, BONE_ATTACHMENT_PARENT_CODE, BONE_UNKNOWN_CODE,
    SKELETON_MISSING_CODE, blendShapeOf, parseBoneProperty,
} from "../skeleton/names";
import { ImportedClipSet } from "../skeleton/clips";

// How many files a chain of instances may hold, the root scene's included:
// far more than any real scene nests, and few enough that a runaway chain
// stops before it exhausts the stack.
export const MAX_INSTANCE_DEPTH: i32 = 32;

// The `embedded-ignored` warning of a packed scene `file` (with `n`
// embedded files) that another scene instances: the loader's, and
// the CLI's `inspect --check`'s for a document it reads that is not the root.
export function embeddedIgnoredMessage(file: string, n: i32): string {
    return file + " is a packed scene instanced by another: its " + n.toString()
        + (n == 1 ? " embedded file is" : " embedded files are") + " ignored";
}

export const EMBEDDED_IGNORED_HINT = "only the root scene's embedded files are used; instance the unpacked scene instead";

// The children of the nodes an instancing looks into, by name (milestone
// 13): SceneNode.child scans its parent's children, so 10,000 siblings,
// each declared after a lookup among the ones before it, took 50 million
// name comparisons (5 s for scale/boxes.rscn). One index per parent is
// built the first time a name is looked up under it and kept in step with
// the children the instancing adds; nothing else changes a node's children
// or names while a tree is being instanced (an instance root is renamed
// before it is added), and the index is dropped with the Instancer, so the
// trees the editor changes afterwards never see it. The first child of a
// name wins, as in SceneNode.child (a model's objects may repeat one).
class ChildIndex {
    byParent: Map<SceneNode, Map<string, SceneNode>> = new Map<SceneNode, Map<string, SceneNode>>();

    of(parent: SceneNode): Map<string, SceneNode> {
        if (this.byParent.has(parent)) return this.byParent.get(parent);
        const m = new Map<string, SceneNode>();
        const kids = parent.children;
        for (let i = 0; i < kids.length; i++) if (!m.has(kids[i].name)) m.set(kids[i].name, kids[i]);
        this.byParent.set(parent, m);
        return m;
    }

    child(parent: SceneNode, name: string): SceneNode? {
        const m = this.of(parent);
        return m.has(name) ? m.get(name) : null;
    }

    addChild(parent: SceneNode, c: SceneNode): void {
        parent.addChild(c);
        if (!this.byParent.has(parent)) return;
        const m = this.byParent.get(parent);
        if (!m.has(c.name)) m.set(c.name, c);
    }

    // The node a scene-relative path names ("." the root, "A/B" below it),
    // walking children by name (instanced subtrees included); null when a
    // segment is missing.
    sceneNode(root: SceneNode, path: string): SceneNode? {
        if (path == ".") return root;
        if (path.indexOf("/") < 0) return this.child(root, path);
        const segs = path.split("/");
        let cur: SceneNode? = root;
        for (let i = 0; i < segs.length; i++) {
            const at = cur;
            if (at == null) return null;
            cur = segs[i] == "." ? at : this.child(at, segs[i]);
        }
        return cur;
    }
}

class Instancer {
    loader: ResourceLoader;
    // The absolute paths of the scenes being instanced, outermost first
    // (for cycles and the depth limit).
    stack: Array<string> = [];
    connections: Array<Connection> = [];
    // Each scene's resources, resolved once however often it is instanced,
    // so that its sub_resources are shared by every instance as its
    // ext_resources are (through the loader's cache).
    resources: Map<PackedScene, DocResources> = new Map<PackedScene, DocResources>();
    // Milestone 45: each document's animations, compiled once however
    // often the scene is instanced (the share's, when there is one).
    animations: Map<RscnDoc, Array<LinearAnimation>> = new Map<RscnDoc, Array<LinearAnimation>>();
    // Milestone 46: and its state machines, likewise.
    machines: Map<RscnDoc, Array<StateMachine>> = new Map<RscnDoc, Array<StateMachine>>();
    // Milestone 48: each document's imported clips, made once however often
    // the scene is instanced (the share's, when there is one).
    clips: Map<RscnDoc, ImportedClipSet> = new Map<RscnDoc, ImportedClipSet>();
    // The `property-unknown` warnings already given (file:line:col), so that
    // a scene instanced twice warns once.
    warned: Set<string> = new Set<string>();
    names: ChildIndex = new ChildIndex();

    constructor(loader: ResourceLoader, share: InstanceShare? = null) {
        this.loader = loader;
        // Milestone 39: a share's map is used as this instancer's own, so
        // every tree instanced with it resolves each scene once.
        if (share != null) {
            this.resources = share.resources;
            this.animations = share.animations;
            this.machines = share.machines;
            this.clips = share.clips;
        }
    }

    // How errors and dumps name a PackedScene: its display path, or, for a
    // scene built in code (no path), the name its document was given.
    display(ps: PackedScene): string {
        if (ps.path.length > 0) return this.loader.displayPath(ps.path);
        const doc = ps.doc;
        if (doc != null && doc.file.length > 0) return doc.file;
        return ps.file;
    }

    // The subtree of a PackedScene; its root's owner is left null.
    scene(ps: PackedScene): Result<SceneNode> {
        const model = ps.model;
        if (model != null) return Result.okv<SceneNode>(this.model(ps, model));
        const doc = ps.doc;
        if (doc == null) {
            return SceneryError.at("instance-invalid", this.display(ps), 0, 0,
                this.display(ps) + " holds neither a scene nor a model").fail<SceneNode>();
        }
        return this.rscn(ps, doc);
    }

    model(ps: PackedScene, model: ModelResource): SceneNode {
        const path = ps.path.length > 0 ? ps.path : model.path;
        return modelToNodes(model, path, this.display(ps));
    }

    rscn(ps: PackedScene, doc: RscnDoc): Result<SceneNode> {
        // Only the root scene's files are mounted (loadSceneTree): a
        // nested scene's would shadow its parent's, so they are ignored.
        // Said before its resources are resolved, which is when a missing
        // file fails the load: the warning explains that failure.
        const embedded = doc.embeddedFiles();
        if (this.stack.length > 1 && embedded.length > 0 && !this.warned.has("embedded " + doc.file)) {
            this.warned.add("embedded " + doc.file);
            const at = embedded[0].pos;
            this.loader.diagnostics.warning("embedded-ignored", doc.file, at.line, at.col,
                embeddedIgnoredMessage(doc.file, embedded.length), EMBEDDED_IGNORED_HINT);
        }
        let res: DocResources;
        if (this.resources.has(ps)) {
            res = this.resources.get(ps);
        } else {
            const r = resolveResources(doc, ps.path, this.loader);
            if (!r.ok) {
                // A failed load prints no warning, so the error itself says
                // why a packed scene's files were not found: over the hint
                // about the path, which is right but beside the point.
                const e = sceneryErrorOf<DocResources>(r);
                if (e != null && this.stack.length > 1 && embedded.length > 0 && (e.hint == null || e.code == "file-read")) {
                    e.hint = doc.file + " is a packed scene, and its embedded files are ignored when another scene instances it: "
                        + "instance the unpacked scene instead";
                }
                return r.forward<SceneNode>();
            }
            res = r.value;
            this.resources.set(ps, res);
        }
        const file = doc.file;
        const here = this.display(ps);
        const decls = doc.nodes();
        if (decls.length == 0) {
            return SceneryError.at("root-missing", file, doc.pos.line, doc.pos.col, "the scene has no node").fail<SceneNode>();
        }
        // The nodes this file creates (by type or instance): an override
        // must name a node inside an instance, never one of these.
        const declared = new Set<SceneNode>();
        // Milestone 48: the models this file's nodes instance (their paths
        // from the root, "." for the root), whose clips the scene lists;
        // and every node a declaration landed on, with its declaration,
        // for the skeleton checks once the tree is made.
        const modelPaths = new Array<string>();
        const models = new Array<PackedScene>();
        const landed = new Array<SceneNode>();
        const landedDecls = new Array<NodeDecl>();
        let root: SceneNode? = null;
        for (let i = 0; i < decls.length; i++) {
            const decl = decls[i];
            let node: SceneNode;
            const inst = decl.instance;
            const type = decl.type;
            if (root == null) {
                if (inst != null) {
                    const c = this.child(decl, doc, res);
                    if (!c.ok) return c;
                    node = c.value;
                    node.name = decl.name;
                } else if (type != null) {
                    node = createNode(type, decl.name);
                    node.sceneFile = here;
                } else {
                    const at = decl.attrPos("name");
                    return SceneryError.at("node-type-missing", file, at.line, at.col,
                        "the root node \"" + decl.name + "\" has neither type nor instance").fail<SceneNode>();
                }
                root = node;
                declared.add(node);
            } else {
                const scope: SceneNode = root;
                const parentPath = decl.parent;
                if (parentPath == null) {
                    return SceneryError.at("parent-missing", file, decl.pos.line, decl.pos.col,
                        "node \"" + decl.name + "\" has no parent (only the first node is the root)").fail<SceneNode>();
                }
                const parent = this.names.sceneNode(scope, parentPath);
                if (parent == null) {
                    const at = decl.attrPos("parent");
                    return SceneryError.at("parent-not-found", file, at.line, at.col,
                        "parent \"" + parentPath + "\" not found").fail<SceneNode>();
                }
                if (inst != null || type != null) {
                    if (this.names.child(parent, decl.name) != null) {
                        const at = decl.attrPos("name");
                        return SceneryError.at("name-duplicate", file, at.line, at.col,
                            "\"" + parentPath + "\" already has a child named \"" + decl.name + "\"").fail<SceneNode>();
                    }
                    if (inst != null) {
                        const c = this.child(decl, doc, res);
                        if (!c.ok) return c;
                        node = c.value;
                        node.name = decl.name;
                    } else {
                        node = createNode(type as string, decl.name);
                        node.sceneFile = here;
                    }
                    node.owner = scope;
                    this.names.addChild(parent, node);
                    declared.add(node);
                } else {
                    const target = this.names.child(parent, decl.name);
                    const at = decl.attrPos("name");
                    if (target == null) {
                        return SceneryError.at("override-missing", file, at.line, at.col,
                            "node \"" + decl.path() + "\" not found in the instanced scene").fail<SceneNode>();
                    }
                    if (declared.has(target)) {
                        return SceneryError.at("override-outside-instance", file, at.line, at.col,
                            "node \"" + decl.path() + "\" has neither type nor instance, but is not inside an instanced scene",
                            "give it a type, or name a node inside an instance").fail<SceneNode>();
                    }
                    node = target;
                }
            }
            let layer = decl.properties();
            if (type == null) {
                const checked = this.checkLayer(node, layer, file);
                if (!checked.ok) return checked.forward<SceneNode>();
                layer = checked.value;
            }
            const applied = node.applyProperties(layer, res, file);
            if (!applied.ok) return applied.forward<SceneNode>();
            landed.push(node);
            landedDecls.push(decl);
            if (inst != null) {
                const ps = this.modelOf(inst, res);
                if (ps != null) {
                    modelPaths.push(i == 0 ? "." : decl.path());
                    models.push(ps);
                }
            }
            node.addGroups(decl.groups());
            // Milestone 17: its bindings, layered as its properties are.
            const bound = node.applyBindings(decl.bindings(), file);
            if (!bound.ok) return bound.forward<SceneNode>();
        }
        const top = root as SceneNode;
        const conns = doc.connections();
        for (let i = 0; i < conns.length; i++) {
            const made = this.connection(conns[i], top, file);
            if (!made.ok) return made.forward<SceneNode>();
        }
        const unique = checkUnique(top, file);
        if (!unique.ok) return unique.forward<SceneNode>();
        // Milestone 48: what only the tree tells of skeletons.
        for (let i = 0; i < landed.length; i++) this.checkSkeletal(landed[i], landedDecls[i], top, file);
        // Milestone 45: the file's timelines, on the root of what it made
        // (compiled once per document for this instancing, or the share's),
        // and milestone 48's: the clips of the models it instances.
        attachSceneAnimations(top, doc, file, this.loader.diagnostics, this.animations, this.importedModels(modelPaths, models),
            this.clips);
        // Milestone 46: its state machines, whose states play those
        // timelines (compiled once per document, as the timelines are).
        attachSceneMachines(top, doc, file, this.loader.diagnostics, this.machines);
        return Result.okv<SceneNode>(top);
    }

    // Milestone 48: the PackedScene of a model an `instance` names, or null
    // (a scene, or nothing the resources resolve: child() reported it).
    modelOf(instance: Value, res: DocResources): PackedScene? {
        const r = res.get(instance);
        const isScene = r instanceof PackedScene;
        if (r == null || !isScene) return null;
        const ps = r as PackedScene;
        return ps.model != null ? ps : null;
    }

    // The models a file's nodes instance, with the source their clips are
    // labelled with: the file's name, or the node's path for files of a
    // name two nodes instance (a model at the root keeps its file's name).
    importedModels(paths: Array<string>, models: Array<PackedScene>): Array<ImportedModel> {
        const out = new Array<ImportedModel>();
        const names = new Array<string>();
        for (let i = 0; i < models.length; i++) names.push(fileNameOf(this.modelFile(models[i])));
        for (let i = 0; i < models.length; i++) {
            let twice = false;
            for (let k = 0; k < names.length && !twice; k++) if (k != i && names[k] == names[i]) twice = true;
            const source = twice && paths[i] != "." ? paths[i] : names[i];
            out.push(new ImportedModel(paths[i], models[i].model as ModelResource, source));
        }
        return out;
    }

    // The file a model's PackedScene was loaded from.
    modelFile(ps: PackedScene): string {
        if (ps.path.length > 0) return ps.path;
        const m = ps.model;
        return m != null && m.path.length > 0 ? m.path : ps.file;
    }

    // Milestone 48: the load warnings of a node `decl` landed on (each
    // once, at the property's place, else the declaration's): its bone
    // properties and bone_name name bones of its skeleton, its blend shape
    // properties blend shapes of its mesh, an attachment's parent is a
    // Skeleton3D, and a skinned mesh's `skeleton` finds one.
    checkSkeletal(node: SceneNode, decl: NodeDecl, root: SceneNode, file: string): void {
        const props = decl.properties();
        const isSkeleton = node instanceof Skeleton3D;
        const isMesh = node instanceof MeshInstance3D;
        const isAttachment = node instanceof BoneAttachment3D;
        if (!isSkeleton && !isMesh && !isAttachment) return;
        const where = node === root ? "." : node.pathFrom(root);
        // (gathered, then given in the order of their places)
        const found = new Array<SkeletalWarning>();
        for (let i = 0; i < props.length; i++) {
            const p = props[i];
            if (isSkeleton && p.name.startsWith(BONES_PREFIX)) {
                const bp = parseBoneProperty(p.name);
                const sk = node as Skeleton3D;
                if (bp != null && bp.axis < 0 && sk.findBone(bp.bone) < 0) {
                    found.push(new SkeletalWarning(BONE_UNKNOWN_CODE, p.pos.line, p.pos.col, "Skeleton3D \"" + where + "\" has no bone \""
                        + bp.bone + "\": " + p.name + " is kept and changes nothing", boneNamesHint(sk)));
                }
            } else if (isMesh && p.name.startsWith(BLEND_SHAPES_PREFIX)) {
                const shape = blendShapeOf(p.name);
                const mesh = node as MeshInstance3D;
                if (shape != null && mesh.findBlendShapeByName(shape) < 0) {
                    found.push(new SkeletalWarning(BLEND_SHAPE_UNKNOWN_CODE, p.pos.line, p.pos.col, "MeshInstance3D \"" + where
                        + "\" has no blend shape \"" + shape + "\": " + p.name + " is kept and changes nothing", blendShapeNamesHint(mesh)));
                }
            }
        }
        if (isAttachment) {
            const a = node as BoneAttachment3D;
            const sk = a.skeleton();
            if (sk == null) {
                const parent = node.parent;
                const what = parent != null ? "\"" + (parent === root ? "." : parent.pathFrom(root)) + "\" (a " + parent.className + ")"
                    : "nothing";
                found.push(new SkeletalWarning(BONE_ATTACHMENT_PARENT_CODE, decl.pos.line, decl.pos.col, "BoneAttachment3D \"" + where
                    + "\" is a child of " + what + ", not of a Skeleton3D: it stays where its transform puts it",
                    "put it under the Skeleton3D whose bone it follows (a model's armature, as \"Hero/Armature\")"));
            } else if ((a.boneName.length > 0 || a.boneIdx >= 0) && a.boneIn(sk) < 0) {
                const at = propertyPos(decl, a.boneName.length > 0 ? "bone_name" : "bone_idx");
                const named = a.boneName.length > 0 ? "\"" + a.boneName + "\"" : "at index " + a.boneIdx.toString();
                found.push(new SkeletalWarning(BONE_UNKNOWN_CODE, at.line, at.col, "BoneAttachment3D \"" + where + "\" follows no bone: its skeleton has no bone "
                    + named, boneNamesHint(sk)));
            }
        }
        if (isMesh) {
            const mesh = node as MeshInstance3D;
            if (mesh.skin != null && mesh.resolvedSkeleton() == null) {
                const at = propertyPos(decl, "skeleton");
                found.push(new SkeletalWarning(SKELETON_MISSING_CODE, at.line, at.col, "the skinned MeshInstance3D \"" + where + "\" finds no Skeleton3D at \""
                    + mesh.skeletonPath + "\": it is drawn as it was bound",
                    "skeleton is the path from the mesh to its Skeleton3D (a model's own is right: take the override away)"));
            }
        }
        found.sort((a: SkeletalWarning, b: SkeletalWarning): i32 => a.line != b.line ? a.line - b.line : a.col - b.col);
        for (let i = 0; i < found.length; i++) {
            const w = found[i];
            this.warnOnce(w.code, file, w.line, w.col, w.message, w.hint);
        }
    }

    // A warning of the loader's, once per place (a scene instanced twice
    // warns once).
    warnOnce(code: string, file: string, line: i32, col: i32, message: string, hint: string): void {
        const key = code + " " + file + ":" + line.toString() + ":" + col.toString() + " " + message;
        if (this.warned.has(key)) return;
        this.warned.add(key);
        this.loader.diagnostics.warning(code, file, line, col, message, hint);
    }

    // The properties of a declaration without a type (an instanced root or
    // an override), checked against the class of the node they land on:
    // the validator knew only that the node is a Node. A value of the wrong
    // type is a `property-type` error and an enum value out of range an
    // `enum-range` one, as on a typed node: letting either through would
    // read as the class default and so silently undo the value the
    // instanced scene set. A property the class does not have is a
    // `property-unknown` warning and stays in the layer, as it does on a
    // typed node: it may be an exported property of the node's script (set
    // by this layer or any other), which takes it from the node's effective
    // properties (../player/runtime.as), and the typed fields ignore names
    // they do not know. A node of a type this version does not know keeps
    // every property without a warning, as a typed one does.
    checkLayer(node: SceneNode, layer: Array<Property>, file: string): Result<Array<Property>> {
        const cls = node.schemaClass();
        const out = new Array<Property>();
        for (let i = 0; i < layer.length; i++) {
            const p = layer[i];
            const info = findProp(cls, p.name);
            if (info == null) {
                if (node.unknownType) {
                    out.push(p);
                    continue;
                }
                const key = file + ":" + p.pos.line.toString() + ":" + p.pos.col.toString();
                if (!this.warned.has(key)) {
                    this.warned.add(key);
                    this.loader.diagnostics.warning("property-unknown", file, p.pos.line, p.pos.col,
                        node.className + " has no property \"" + p.name + "\"", KEPT_HINT);
                }
                out.push(p);
                continue;
            }
            if (!info.accepts(p.value)) {
                const vp = p.valuePos.isKnown() ? p.valuePos : p.pos;
                return SceneryError.at("property-type", file, vp.line, vp.col,
                    info.name + " is " + withArticle(info.typeText()) + ", found " + foundText(p.value)).fail<Array<Property>>();
            }
            const range = enumRangeProblem(info, p.value);
            if (range.length > 0) {
                const vp = p.valuePos.isKnown() ? p.valuePos : p.pos;
                return SceneryError.at("enum-range", file, vp.line, vp.col, range).fail<Array<Property>>();
            }
            out.push(p);
        }
        return Result.okv<Array<Property>>(out);
    }

    // The instanced scene's root for a declaration with `instance`.
    child(decl: NodeDecl, doc: RscnDoc, res: DocResources): Result<SceneNode> {
        const at = decl.attrPos("instance");
        const r = res.get(decl.instance as Value);
        const isScene = r instanceof PackedScene;
        if (r == null || !isScene) {
            return SceneryError.at("instance-invalid", doc.file, at.line, at.col,
                "instance must name an ext_resource of type PackedScene").fail<SceneNode>();
        }
        const ps = r as PackedScene;
        const abs = ps.path;
        const seen = this.stack.indexOf(abs);
        if (seen >= 0) {
            const chain = new Array<string>();
            for (let k = seen; k < this.stack.length; k++) chain.push(this.loader.displayPath(this.stack[k]));
            chain.push(this.loader.displayPath(abs));
            return SceneryError.at("instance-cycle", doc.file, at.line, at.col, "instance cycle: " + chain.join(" -> "),
                "a scene cannot contain itself: remove one of the instances").fail<SceneNode>();
        }
        if (this.stack.length >= MAX_INSTANCE_DEPTH) {
            return SceneryError.at("instance-depth", doc.file, at.line, at.col,
                "instances nested more than " + MAX_INSTANCE_DEPTH.toString() + " deep",
                "a chain of instanced scenes holds at most " + MAX_INSTANCE_DEPTH.toString()
                    + " files: instance a scene that nests fewer").fail<SceneNode>();
        }
        this.stack.push(abs);
        const built = this.scene(ps);
        this.stack.pop();
        const shown = this.display(ps);
        if (!built.ok) {
            let e = sceneryErrorOf<SceneNode>(built);
            if (e == null) e = SceneryError.at("instance-invalid", shown, 0, 0, built.err);
            return e.within(doc.file, decl.pos.line, decl.pos.col, "instance of " + shown).fail<SceneNode>();
        }
        const node = built.value;
        node.sceneFile = shown;
        node.instancePath = abs;
        node.instancePaths.push(abs);
        return Result.okv<SceneNode>(node);
    }

    connection(c: ConnectionDecl, root: SceneNode, file: string): Result<bool> {
        const from = root.getNode(c.from);
        if (from == null) {
            const at = c.attrPos("from");
            return SceneryError.at("connection-node-missing", file, at.line, at.col,
                "connection from \"" + c.from + "\": node not found").fail<bool>();
        }
        const to = root.getNode(c.to);
        if (to == null) {
            const at = c.attrPos("to");
            return SceneryError.at("connection-node-missing", file, at.line, at.col,
                "connection to \"" + c.to + "\": node not found").fail<bool>();
        }
        const made = new Connection(c.signal, from, to, c.method);
        made.flags = c.flags;
        made.file = file;
        made.line = c.pos.line;
        made.col = c.pos.col;
        this.connections.push(made);
        return Result.okv<bool>(true);
    }
}

// Two nodes of one scene (the same owner) marked unique with the same name
// would make %Name ambiguous. Checked over the whole subtree, so that an
// override making a node inside an instance unique is caught too; the
// error is at the second node's unique_name_in_owner.
function checkUnique(root: SceneNode, file: string): Result<bool> {
    // Unique nodes are few: a pairwise check over them is enough.
    const marked = new Array<SceneNode>();
    const stack = new Array<SceneNode>();
    stack.push(root);
    while (stack.length > 0) {
        const n = stack.pop();
        for (let i = n.children.length - 1; i >= 0; i--) stack.push(n.children[i]);
        if (!n.unique) continue;
        for (let k = 0; k < marked.length; k++) {
            const first = marked[k];
            if (first.name != n.name || first.owner != n.owner) continue;
            const where = n.uniqueFile.length > 0 ? n.uniqueFile : file;
            return SceneryError.at("unique-duplicate", where, n.uniqueLine, n.uniqueCol,
                "%" + n.name + " names two nodes of one scene: \"" + first.pathFrom(root) + "\" and \"" + n.pathFrom(root) + "\"",
                "unique names must differ within a scene").fail<bool>();
        }
        marked.push(n);
    }
    return Result.okv<bool>(true);
}

// Instances a PackedScene as a new tree whose root keeps the root
// declaration's name (a model's: its file stem). The loader resolves and
// caches every resource the scenes name.
//
// Milestone 39: with a `share`, the scenes' sub_resources are resolved once
// for every tree instanced with it (tree.as InstanceShare), and the tree
// keeps the share for the scenes its scripts instance.
export function instantiate(scene: PackedScene, loader: ResourceLoader, share: InstanceShare? = null): Result<SceneTree> {
    const inst = new Instancer(loader, share);
    inst.stack.push(scene.path);
    const r = inst.scene(scene);
    if (!r.ok) return r.forward<SceneTree>();
    // Milestone 48: a model as the tree's root lists its own clips.
    const model = scene.model;
    if (model != null) {
        const file = inst.modelFile(scene);
        attachModelAnimations(r.value, model, fileNameOf(file), inst.display(scene), loader.diagnostics);
    }
    const tree = new SceneTree(r.value, loader);
    tree.scenePath = scene.path;
    tree.connections = inst.connections;
    tree.share = share;
    // Milestone 46: an instancing node naming a state machine or an
    // animation its scene does not have (known only now: the node's own
    // properties land after its scene is made), warned once each.
    const found = new Array<Diagnostic>();
    instancingWarnings(tree.root, found);
    for (let i = 0; i < found.length; i++) addWarningOnce(loader, found[i]);
    return Result.okv<SceneTree>(tree);
}

// Loads, validates and instances a root scene (an .rscn file, or a model
// file as a scene). The loader is ResourceLoader.forScene(abs) unless one is
// given (a test's, or one whose cache is already filled).
//
// A root scene that holds embedded files (a packed scene, RSCN.md "Packed
// scenes") is its own project: the project root becomes its directory,
// whatever hedra.yaml is above it, and its files are mounted there
// (mountPackedScene) before any of its resources is resolved.
// When the root moves, the scene is read again, so that it and its
// diagnostics are named from the new root.
// Milestone 39: `share` as `instantiate`'s.
export function loadSceneTree(abs: string, loader: ResourceLoader? = null, share: InstanceShare? = null): Result<SceneTree> {
    const l = loader != null ? loader : ResourceLoader.forScene(abs);
    const before = l.diagnostics.items.length;
    let ps = l.loadScene(abs);
    if (!ps.ok) return ps.forward<SceneTree>();
    const doc = ps.value.doc;
    if (doc != null && doc.embeddedFiles().length > 0) {
        if (l.projectRoot != dirOf(abs)) {
            l.projectRoot = dirOf(abs);
            l.forget("PackedScene", abs);
            l.diagnostics.items.splice(before, l.diagnostics.items.length - before);
            ps = l.loadScene(abs);
            if (!ps.ok) return ps.forward<SceneTree>();
        }
        const again = ps.value.doc;
        if (again != null) mountPackedScene(l, abs, again);
    }
    return instantiate(ps.value, l, share);
}

// Adds `d` to the loader's diagnostics unless it holds the same already (a
// scene instanced again by the same loader warns once).
function addWarningOnce(loader: ResourceLoader, d: Diagnostic): void {
    const items = loader.diagnostics.items;
    for (let i = 0; i < items.length; i++) {
        const e = items[i];
        if (e.code == d.code && e.file == d.file && e.line == d.line && e.col == d.col && e.message == d.message) return;
    }
    loader.diagnostics.add(d);
}

// A load warning of the skeletal checks, before it is given.
class SkeletalWarning {
    code: string;
    line: i32;
    col: i32;
    message: string;
    hint: string;

    constructor(code: string, line: i32, col: i32, message: string, hint: string) {
        this.code = code;
        this.line = line;
        this.col = col;
        this.message = message;
        this.hint = hint;
    }
}

// The file name of a path ("/work/models/hero.glb" -> "hero.glb").
function fileNameOf(path: string): string {
    return path.substring(path.lastIndexOf("/") + 1);
}

// Where property `name` of `decl` is, else the declaration.
function propertyPos(decl: NodeDecl, name: string): XmlPos {
    const props = decl.properties();
    for (let i = 0; i < props.length; i++) if (props[i].name == name) return props[i].pos;
    return decl.pos;
}
