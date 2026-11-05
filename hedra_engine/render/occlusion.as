// Occlusion culling on the CPU (milestone 37; Godot's occlusion culling,
// renderer_scene_occlusion_cull.h): the frame's occluders (occluder.as)
// rasterised into a small depth buffer from the view's camera, a
// hierarchy of its maxima built over it, and each item's box tested
// against it before drawing: an item whose box is wholly behind what the
// occluders cover is not drawn (cull.as CULL_OCCLUDED, after the frustum
// test, on top of milestone 13's culling). One buffer for the renderer's
// views and for the tools that count (`inspect --stats`, `render`'s
// answer), so the numbers are the draws the GPU was given.
//
// The buffer (normative):
//   - OCCLUSION_BUFFER_WIDTH texels across, the view's aspect down
//     (round(256 * height / width), at most OCCLUSION_BUFFER_MAX_HEIGHT, at
//     least 1), each holding a view depth (metres along the camera's
//     forward, an orthographic camera's too), +infinity where no occluder
//     is; and a guard band one texel wide outside the view on each side,
//     rasterised as the view's texels are (the buffer is (W + 2) x (H + 2)
//     texels, the view's texel (x, y) at (x + 1, y + 1)), so that the
//     texels at the view's edges have neighbours as those inside do;
//   - each occluder triangle of the frame's world through its node's
//     transform and the view, clipped against the near plane (Sutherland-
//     Hodgman, the one plane), filled where it covers a texel's centre
//     (edge functions, the top-left rule: two triangles sharing an edge
//     fill each texel along it once), double-sided (but for a closed
//     occluder's faces turned away from the eye, behind those turned
//     towards it: OccluderDesc.closed); a texel keeps the
//     nearest triangle's depth, and a triangle writes the farthest depth
//     of its plane at the texel's four corners (1/z is affine across the
//     screen in perspective, z in orthographic, so the farthest is at a
//     corner; a plane that passes behind the eye at a corner writes
//     nothing), widened by OCCLUSION_DEPTH_SLACK of it for f32 rounding:
//     what is behind that depth is behind the triangle's plane everywhere
//     in the texel;
//   - an occluder whose box lies wholly beyond one side of the view and
//     its guard band (two texels past the view's edge), or behind the near
//     plane, is not rasterised (none of its triangles could cover a texel's
//     centre): the buffer is the same, made for less;
//   - the levels, over the guard band too: each texel of level k + 1 the
//     farthest of its four in level k (Godot's HZB; a level of odd size
//     folds its last column or row into the last parent), down to 1 x 1;
//   - past OCCLUSION_MAX_TRIANGLES the occluder that would pass it and
//     every one after it, in the scene's order, are left out
//     (stats.dropped, and `warning` for the renderer's warnings).
// An item is occluded (Godot's _is_occluded, on view depth) when the
// buffer holds something, the eye is outside its box, every one of its
// eight corners is beyond the near plane, and at some level every texel
// read is nearer than its nearest depth (the least of its corners'). The
// texels read: the corners' screen rectangle (clipped to the view),
// widened by one texel each side at level 0 (into the guard band at the
// view's edges: the buffer knows coverage at texel centres alone, and a
// box that shows only between the view's edge and its first centres is
// seen unless the guard texel's centre is covered too), and at a level
// the texels holding those (so a coarse texel covers at least what the
// fine ones do); first the level whose texel is at least the rectangle's
// larger side (Godot's ceil(log2(size))),
// then each finer one while a level is inconclusive, at most
// OCCLUSION_MAX_SAMPLES (Godot's 512) in all (past it the item is drawn).
// Conservative, so a scene whose occluders lie inside what they stand for
// (a wall's box inside the wall) draws every pixel it drew without them;
// an occluder in the open hides what is behind it, as in Godot. Not used:
// for shadows (casters are culled per tile as before), for an item that
// draws lines or points (the editor's overlays), with no depth test or in
// the top pass, in a shading without surfaces (wire), or in a probe's
// capture. The editor's statistics line, `render`'s answer and `inspect
// --stats` count the occluded items; `render --occlusion-buffer` writes the
// buffer as a picture (occlusionImage).
//
// Where it differs from Godot: rasterised, not ray cast, by bands of rows
// that are the units of a job (base/jobs.as: one thread today, each band
// its worker's with threads; the same bytes either way), the same kind of
// buffer, deterministic: no jitter, so no occlusion timers; a texel's depth is its triangle's farthest over the
// texel, not the ray's at its centre (Hedra never culls a sliver Godot's
// could); and the depths are along the view's forward, not distances from
// the eye, the box's nearest corner's against them (the same test on the
// same rays: a ray's depth is its distance times its cosine to the
// forward).
//
// What it costs, where every instruction is interpreted (a built project's
// frame in the Rive run time): a buffer is kept as it is while the view and
// every occluder are what it was made from (prepare: a still camera over
// still occluders rasterises nothing), and an item whose box is the one it
// was tested with against a kept buffer has its answer again
// (occludedAt); a closed occluder's faces turned away are left before they
// are clipped; and a box no farther than the occluders' nearest point is
// seen without projecting its corners. None of these changes an answer.
//
// Deterministic (f32 in a fixed order) and allocation-free once warm: the
// buffer's arrays keep their storage for the largest view drawn. The
// triangles are filled as a job of bands of the buffer's rows (a band each
// worker of jobs(): one, the whole buffer, on one thread), every band
// drawing every occluder into its own rows alone, which it fills as the
// whole buffer would (a row is filled from the triangle alone); what each
// band wrote is added up after the run in the occluders' order. The levels
// are folded the same way with more than one worker, and cull.as tests
// the boxes in its own job, each unit in its worker's rectangles.

import { MAT4_IDENTITY, Mat4, Vec3, Vec4 } from "../base/vecmath";
import { Bounds } from "./camera";
import { Image } from "./image";
import { RenderFrame } from "./frame";
import { OccluderDesc } from "./occluder";
import {
    Job, LANE_OCCLUSION, LANE_OCCLUSION_SETUP, LaneJob, LaneResult, LaneResultWriter, UnitClaims, grainFor, jobs, unitBegin, unitEnd,
} from "../base/jobs";

// The buffer's width in texels (Godot's default buffer is in the same
// range: a few hundred rays a row), and the most it is tall.
export const OCCLUSION_BUFFER_WIDTH: i32 = 256;
export const OCCLUSION_BUFFER_MAX_HEIGHT: i32 = 256;
// The buffer's width while the view moves (Godot's buffer follows the
// same idea: a coarser one where it is made every frame): half, its
// height the view's aspect of it, at most half the most.
export const OCCLUSION_MOTION_WIDTH: i32 = 128;
// How far a view's matrix may move, relative to its largest number, and
// still be the view it was (a still camera's frame made again).
export const OCCLUSION_STILL_EPSILON: f32 = 1e-6;
// The frames a buffer remembers the last view of (a view, its viewports).
const MOTION_FRAMES = 8;
// The most buffer texels one item's test reads (Godot's max_samples): past
// it the item is drawn.
export const OCCLUSION_MAX_SAMPLES: i32 = 512;
// The most triangles a frame rasterises (the occluders past it, in the
// scene's order, are left out with a warning: occluder-too-many-triangles).
export const OCCLUSION_MAX_TRIANGLES: i32 = 65536;
// How much farther than its plane a texel's depth is written (relative):
// far above the rounding of the f32 transforms and of 1/z, far below what
// separates a wall from what stands behind it.
export const OCCLUSION_DEPTH_SLACK: f32 = 1e-5;
// How far before the occluders' nearest point a box's nearest corner must
// be for the test to see it without projecting it (relative: a thousand
// times the slack, so that no rounding of a texel's depth reaches it).
export const OCCLUSION_NEAREST_MARGIN: f32 = 1e-3;
// The warning when occluders were left out: the plan's (scene/render/
// occluders.as applyOccluders, SceneFrame.warnings), and the buffer's
// after a prepare that left some out (OcclusionBuffer.takeWarning).
export const OCCLUSION_TRIANGLES_WARNING =
    "occlusion: the occluders past 65,536 triangles in all are left out of the culling (occluder-too-many-triangles)";

// The most levels a buffer has (256 x 256 down to 1 x 1 is 9).
const MAX_LEVELS: i32 = 16;

// What a frame's occlusion did, for the statistics.
export class OcclusionStats {
    // The frame's occluders of its world, and those that had triangles in
    // front of the near plane and inside the view (they wrote a texel).
    occluders: i32 = 0;
    drawn: i32 = 0;
    // Triangles rasterised (every triangle of the occluders not left out),
    // and texels written (a texel once for each triangle covering it).
    triangles: i32 = 0;
    texels: i32 = 0;
    // Items tested, and those found occluded.
    tested: i32 = 0;
    occluded: i32 = 0;
    // Occluders left out past OCCLUSION_MAX_TRIANGLES.
    dropped: i32 = 0;

    reset(): void {
        this.occluders = 0;
        this.drawn = 0;
        this.triangles = 0;
        this.texels = 0;
        this.tested = 0;
        this.occluded = 0;
        this.dropped = 0;
    }

    copyFrom(o: OcclusionStats): void {
        this.occluders = o.occluders;
        this.drawn = o.drawn;
        this.triangles = o.triangles;
        this.texels = o.texels;
        this.tested = o.tested;
        this.occluded = o.occluded;
        this.dropped = o.dropped;
    }
}

// The scratch of setting the triangles up (setupOccluder: the main lane's,
// once a prepare).
export class RasterScratch {
    // One triangle's clipping: up to 4 points (a triangle less a corner
    // behind the near plane is a quad), view space x, y, z.
    clipX: StaticArray<f32> = new StaticArray<f32>(4);
    clipY: StaticArray<f32> = new StaticArray<f32>(4);
    clipZ: StaticArray<f32> = new StaticArray<f32>(4);
    // The clipped polygon's points on the buffer (texels, y down).
    scrX: StaticArray<f32> = new StaticArray<f32>(4);
    scrY: StaticArray<f32> = new StaticArray<f32>(4);
    // An occluder's points in view space (x, y, z each), grown to the
    // largest occluder.
    viewPoints: Float32Array = new Float32Array(0);
    // For the occluder being drawn: 0 when both sides of its triangles
    // occlude, else the sign of the area on the buffer of the faces it keeps.
    facing: f32 = 0;
    // The plane of the triangle being filled (planeOf).
    planeA: f32 = 0;
    planeB: f32 = 0;
    planeC: f32 = 0;
    // The least depth of the points of the occluder being drawn.
    pointsNearest: f32 = f32.POSITIVE_INFINITY;
    // Whose points viewPoints holds (a scratch is its buffer's own): the
    // occluder's place in drawList and the prepare (the buffer's
    // generation), and whether any is in front of the near plane.
    pointsOf: i32 = -1;
    pointsGeneration: i32 = 0;
    pointsFront: bool = false;
}

// The buffer's tiles: bands of whole rows of level 0 (the guard band's
// included), one a worker of the executor (jobs.as workers(): the whole
// buffer on one thread), at least OCCLUSION_MIN_BAND rows each, the last
// shorter; each filled whole by one unit of prepare's fill job from the
// triangles binned to it.
export const OCCLUSION_MIN_BAND: i32 = 8;
// A set-up triangle's floats (OcclusionBuffer.tris): its three points on
// the buffer, turned to run clockwise (y down), and its plane's q = a x + b
// y + c.
const TRI_FLOATS = 9;

// Set-up triangles: TRI_FLOATS each, `count` of them, and each one's
// occluder (its place in drawList). The buffer's whole list, or one setup
// unit's share (setup job), its storage kept.
export class TriSink {
    tris: Float32Array = new Float32Array(0);
    occ: Int32Array = new Int32Array(0);
    count: i32 = 0;
    // The unit's occluder's nearest point (its first unit's).
    nearest: f32 = f32.POSITIVE_INFINITY;

    // Room for one more.
    @inline
    room(): void {
        const n = this.count;
        if ((n + 1) * TRI_FLOATS > this.tris.length) this.grow(n + 1);
    }

    grow(n: i32): void {
        const more = new Float32Array(max<i32>(max<i32>(1024, this.tris.length * 2), n * TRI_FLOATS));
        for (let q = 0; q < this.count * TRI_FLOATS; q++) unchecked(more[q] = unchecked(this.tris[q]));
        this.tris = more;
        const occs = new Int32Array(more.length / TRI_FLOATS);
        for (let q = 0; q < this.count; q++) unchecked(occs[q] = unchecked(this.occ[q]));
        this.occ = occs;
    }

    // `s`'s triangles after these.
    append(s: TriSink): void {
        const n = this.count;
        if ((n + s.count) * TRI_FLOATS > this.tris.length) this.grow(n + s.count);
        copyFloats(this.tris, n * TRI_FLOATS, s.tris, 0, s.count * TRI_FLOATS);
        copyInts(this.occ, n, s.occ, 0, s.count);
        this.count = n + s.count;
    }
}

// The most triangles of an occluder one unit of the setup job sets up.
const SETUP_GRAIN = 256;
// An item test's texel rectangle at each level: x0, x1, y0 and y1, each
// MAX_LEVELS words (OcclusionBuffer.occludedInto's `rect`: a worker's own,
// jobs.as; this one for the tests asked of the buffer itself).
export const OCCLUSION_RECT_WORDS: i32 = 4 * MAX_LEVELS;
const RECT_X1 = MAX_LEVELS;
const RECT_Y0 = 2 * MAX_LEVELS;
const RECT_Y1 = 3 * MAX_LEVELS;
const ownRect = new StaticArray<i32>(OCCLUSION_RECT_WORDS);

// The depth buffer of one view and its levels.
export class OcclusionBuffer {
    // The view's texels across and down (the guard band not counted).
    width: i32 = 0;
    height: i32 = 0;
    // Level 0 first, row-major, top row first: (width + 2) x (height + 2)
    // view depths, the guard band around the view's (texel(x, y) reads
    // the view's texel (x, y)); then the coarser levels (levelOffset).
    // Longer than that when a larger view was drawn before (its storage is
    // kept).
    depth: Float32Array = new Float32Array(0);
    // Whether the last prepare wrote any texel (an empty buffer occludes
    // nothing, and occluded() answers false at once).
    active: bool = false;
    stats: OcclusionStats = new OcclusionStats();
    // OCCLUSION_TRIANGLES_WARNING when the last prepare left occluders out
    // ("" otherwise), until takeWarning.
    warning: string = "";
    // The levels: how many (level 0 included), and each one's size and
    // offset into `depth` (level 0's size the guard band's included).
    levels: i32 = 0;
    levelWidth: StaticArray<i32> = new StaticArray<i32>(MAX_LEVELS);
    levelHeight: StaticArray<i32> = new StaticArray<i32>(MAX_LEVELS);
    levelOffset: StaticArray<i32> = new StaticArray<i32>(MAX_LEVELS);
    // How many times prepare rasterised (a kept buffer is not counted): for
    // the tests and the benches.
    made: i32 = 0;

    // Each frame's view at its last prepare (`moving`: the frame's view
    // moved since; a view and the viewports it draws are frames of their
    // own), MOTION_FRAMES frames at most, the oldest let go.
    private lastFrames: Array<RenderFrame> = [];
    private lastViews: Array<Mat4> = [];
    private lastProjs: Array<Mat4> = [];
    moving: bool = false;
    // The view the buffer was made from.
    private view: Mat4 = MAT4_IDENTITY;
    private proj: Mat4 = MAT4_IDENTITY;
    private viewProj: Mat4 = MAT4_IDENTITY;
    private near: f32 = 0;
    private ortho: bool = false;
    // A depth no texel is nearer than: the nearest point of the occluders
    // that wrote a texel (at the near plane for one that crosses it; a
    // texel holds its triangle's depth at a point inside it, or farther),
    // less OCCLUSION_NEAREST_MARGIN of it for rounding. A box whose nearest
    // corner is no farther is seen, whatever it covers.
    private nearest: f32 = f32.POSITIVE_INFINITY;
    // What the last prepare drew from (`kept`: the buffer still holds it):
    // the size, the view, the world, and each occluder of the frame (its
    // arrays, version, transform, closing, world and box; not the descs
    // themselves, which a frame planned again makes anew for the same
    // occluders), with what it gave. A prepare from the same is that buffer
    // again, so a still camera over still occluders rasterises nothing
    // (keptFrom).
    private kept: bool = false;
    private keptDepth: Float32Array = new Float32Array(0);
    private keptWidth: i32 = 0;
    private keptHeight: i32 = 0;
    private keptView: Mat4 = MAT4_IDENTITY;
    private keptProj: Mat4 = MAT4_IDENTITY;
    private keptNear: f32 = 0;
    private keptScenario: i32 = 0;
    private keptVertices: Array<Float32Array> = [];
    private keptIndices: Array<Uint32Array> = [];
    private keptVersions: Array<u32> = [];
    private keptWorlds: Array<Mat4> = [];
    private keptClosed: Array<bool> = [];
    private keptScenarios: Array<i32> = [];
    private keptBoxed: Array<bool> = [];
    private keptStats: OcclusionStats = new OcclusionStats();
    private keptActive: bool = false;
    private keptNearest: f32 = f32.POSITIVE_INFINITY;
    // The answers of occludedAt, by item: its box and whether it was
    // occluded, valid while their generation is the buffer's (moved by
    // every prepare that rasterises: a kept buffer answers a box it was
    // asked before as it did).
    private generation: i32 = 1;
    private answerGeneration: Array<i32> = [];
    private answerLo: Array<Vec3> = [];
    private answerHi: Array<Vec3> = [];
    private answerOccluded: Array<bool> = [];
    // The frame's occluders the last prepare drew (indices into
    // RenderFrame.occluders) and each one's nearest point.
    private drawList: Array<i32> = [];
    private drawNearest: Array<f32> = [];
    // The setup's scratch.
    private scratch: RasterScratch = new RasterScratch();
    // The triangles set up, in the occluders' order and each one's
    // triangles' (`sink`), and the tiles' bins: the tiles across and down,
    // where each tile's run of `binItems` (triangle indices, in their
    // order) begins (`binStart`, tiles + 1 of them).
    sink: TriSink = new TriSink();
    // The setup job's units: each one's occluder (its place in drawList)
    // and its triangles [begin, end); each unit's share when it does not
    // write the sink itself (more than one worker), each worker's scratch.
    private unitOcc: Int32Array = new Int32Array(0);
    private unitBegin: Int32Array = new Int32Array(0);
    private unitEnd: Int32Array = new Int32Array(0);
    setupUnits: i32 = 0;
    private unitSinks: Array<TriSink> = [];
    private workerScratch: Array<RasterScratch> = [];
    tilesX: i32 = 0;
    tilesY: i32 = 0;
    bandRows: i32 = 1;
    binStart: Int32Array = new Int32Array(0);
    binItems: Int32Array = new Int32Array(0);
    // What each tile wrote of each occluder (by tile, then occluder).
    private tileTexels: Int32Array = new Int32Array(0);
    // Whether the last prepare filled each triangle as it was set up (one
    // worker), keeping none of them.
    immediate: bool = false;
    private eye: Vec3 = Vec3(0, 0, 0);

    // Forgets the last frame's view: the next prepare is a still one
    // (the tests, to start each run of frames from the same state).
    forgetMotion(): void {
        this.lastFrames.length = 0;
        this.lastViews.length = 0;
        this.lastProjs.length = 0;
    }

    // Empties the buffer's answer and its statistics (a frame culled
    // without occluders), allocating nothing.
    clear(): void {
        this.stats.reset();
        this.active = false;
    }

    // Takes the warning of the last prepare ("" for none).
    takeWarning(): string {
        const w = this.warning;
        this.warning = "";
        return w;
    }

    // Rasterises `f`'s occluders of its world (RenderFrame.occluders) from
    // its camera at its aspect, by the rules in the header; nothing when
    // f.occlusion is off. When the view and every occluder are what the
    // buffer was last made from, the buffer is kept as it is (the same
    // bytes: a still camera over still occluders costs the tests alone).
    prepare(f: RenderFrame): void {
        this.stats.reset();
        this.active = false;
        this.warning = "";
        const fw = max<u32>(f.width, 1);
        const fh = max<u32>(f.height, 1);
        const cam = f.camera;
        const aspect = <f32>fw / <f32>fh;
        const view = cam.viewMatrix();
        const proj = cam.projectionMatrix(aspect);
        // While the view moves (the frame's view differs from its last
        // one's, the frame drawn again) the buffer is coarser, half as wide;
        // still, the whole width: the same rules either way, so either is
        // conservative as the other (a texel is the farthest of what covers
        // its centre, and a box's test reads a texel more each side).
        let at = -1;
        for (let i = 0; i < this.lastFrames.length; i++) if (unchecked(this.lastFrames[i]) === f) at = i;
        const moving = f.occlusionMotion && at >= 0
            && !(sameMatrix(view, unchecked(this.lastViews[at])) && sameMatrix(proj, unchecked(this.lastProjs[at])));
        this.moving = moving;
        if (at < 0) {
            if (this.lastFrames.length < MOTION_FRAMES) {
                this.lastFrames.push(f);
                this.lastViews.push(view);
                this.lastProjs.push(proj);
                at = this.lastFrames.length - 1;
            } else {
                // (the oldest's place: each moved down one)
                for (let i = 0; i + 1 < MOTION_FRAMES; i++) {
                    unchecked(this.lastFrames[i] = unchecked(this.lastFrames[i + 1]));
                    unchecked(this.lastViews[i] = unchecked(this.lastViews[i + 1]));
                    unchecked(this.lastProjs[i] = unchecked(this.lastProjs[i + 1]));
                }
                at = MOTION_FRAMES - 1;
                unchecked(this.lastFrames[at] = f);
            }
        }
        unchecked(this.lastViews[at] = view);
        unchecked(this.lastProjs[at] = proj);
        const full = moving ? OCCLUSION_MOTION_WIDTH : OCCLUSION_BUFFER_WIDTH;
        const w = full;
        let h = <i32>Math.round(<f64>full * <f64>fh / <f64>fw);
        const most = moving ? OCCLUSION_BUFFER_MAX_HEIGHT * OCCLUSION_MOTION_WIDTH / OCCLUSION_BUFFER_WIDTH
            : OCCLUSION_BUFFER_MAX_HEIGHT;
        if (h < 1) h = 1;
        if (h > most) h = most;
        if (!f.occlusion) {
            this.size(w, h);
            fillInfinity(this.depth, (w + 2) * (h + 2));
            this.kept = false;
            this.generation++;
            return;
        }
        if (this.keptFrom(f, w, h, view, proj)) {
            this.stats.copyFrom(this.keptStats);
            this.stats.tested = 0;
            this.stats.occluded = 0;
            if (this.stats.dropped > 0) this.warning = OCCLUSION_TRIANGLES_WARNING;
            this.active = this.keptActive;
            this.nearest = this.keptNearest;
            return;
        }
        this.size(w, h);
        fillInfinity(this.depth, (w + 2) * (h + 2));
        this.generation++;
        this.made++;
        this.nearest = f32.POSITIVE_INFINITY;
        this.view = view;
        this.proj = proj;
        this.viewProj = proj * view;
        this.near = cam.near;
        this.ortho = cam.isOrtho();
        this.eye = cam.eye;

        const s = this.stats;
        let taken = 0;
        let dropping = false;
        let nearest = f32.POSITIVE_INFINITY;
        // Which occluders are drawn (the scene's order: the triangle budget
        // and the view's sides decide), then their triangles filled as a job
        // of bands of rows (jobs.as: a band a worker, each texel written by
        // the band holding its row, so the bytes are the same whatever the
        // bands), then what each wrote merged in the occluders' order.
        const occ = f.occluders;
        const list = this.drawList;
        list.length = 0;
        for (let i = 0; i < occ.length; i++) {
            const o = unchecked(occ[i]);
            if (o.scenario != f.scenario) continue;
            s.occluders++;
            const tris = o.indices.length / 3;
            if (dropping || taken + tris > OCCLUSION_MAX_TRIANGLES) {
                dropping = true;
                s.dropped++;
                continue;
            }
            taken += tris;
            // (its box wholly off one side of the view, or behind the near
            // plane: none of its triangles covers a texel)
            if (o.hasBounds && this.offView(o.bounds)) continue;
            list.push(i);
        }
        const drawn = list.length;
        if (drawn > 0) {
            // Each triangle set up once (transformed, its faces turned away
            // left out, clipped, projected, its plane), in the occluders'
            // order, and binned to the tiles it may cover; then the tiles
            // filled as a job, a tile a unit (each texel written by its
            // tile's unit alone, from the same triangles in the same order,
            // so the bytes are the same whoever filled which tile); then
            // what each tile wrote of each occluder added up, in order.
            if (this.drawNearest.length < drawn) this.drawNearest.length = drawn;
            for (let k = 0; k < drawn; k++) unchecked(this.drawNearest[k] = f32.POSITIVE_INFINITY);
            // (one worker, or on lanes too few triangles to gain from them
            // (OCCLUSION_LANE_SETUP): each triangle filled as soon as it is
            // set up, into the whole buffer, as one band, with no list kept)
            const ex = jobs();
            const immediate = ex.workers() <= 1 || (ex.startsLanes() && this.drawnTriangles(f) < OCCLUSION_LANE_SETUP);
            this.immediate = immediate;
            if (immediate) {
                this.tilesX = 1;
                this.tilesY = 1;
                this.bandRows = h + 2;
            }
            if (this.tileTexels.length < drawn) this.tileTexels = new Int32Array(drawn);
            for (let i = 0; i < drawn; i++) unchecked(this.tileTexels[i] = 0);
            this.setupAll(f);
            if (!immediate) this.binTriangles(max<i32>(grainFor(h + 2, ex.workers()), OCCLUSION_MIN_BAND));
            const tiles = this.tilesX * this.tilesY;
            if (this.tileTexels.length < tiles * drawn) this.tileTexels = new Int32Array(tiles * drawn);
            const tt = this.tileTexels;
            if (!immediate) {
                for (let i = 0; i < tiles * drawn; i++) unchecked(tt[i] = 0);
                const job = fillJob;
                job.buffer = this;
                ex.run(job, tiles, 1);
                job.buffer = null;
            }
            for (let k = 0; k < drawn; k++) {
                let texels = 0;
                for (let t = 0; t < tiles; t++) texels += unchecked(tt[t * drawn + k]);
                s.texels += texels;
                if (texels > 0) {
                    s.drawn++;
                    nearest = Mathf.min(nearest, Mathf.max(unchecked(this.drawNearest[k]), this.near));
                }
            }
        }
        s.triangles = taken;
        if (s.dropped > 0) this.warning = OCCLUSION_TRIANGLES_WARNING;
        if (s.texels > 0) {
            this.buildLevels();
            this.nearest = nearest * (<f32>1 - OCCLUSION_NEAREST_MARGIN);
            this.active = true;
        }
        this.keep(f, w, h);
    }

    // Whether the buffer holds what prepare would make of `f` at `w` x `h`
    // with `view` and `proj`: the same view and world, and the same
    // occluders, each with the same arrays, version, transform, closing,
    // world and box (a desc's arrays are its occluder's, made again when it
    // changes: OccluderDesc).
    private keptFrom(f: RenderFrame, w: i32, h: i32, view: Mat4, proj: Mat4): bool {
        if (!this.kept || this.depth !== this.keptDepth || w != this.keptWidth || h != this.keptHeight) return false;
        if (f.camera.near != this.keptNear || f.scenario != this.keptScenario) return false;
        if (!(view == this.keptView) || !(proj == this.keptProj)) return false;
        const occ = f.occluders;
        const n = occ.length;
        if (n != this.keptVertices.length) return false;
        for (let i = 0; i < n; i++) {
            const o = unchecked(occ[i]);
            if (o.vertices !== unchecked(this.keptVertices[i])
                || o.indices !== unchecked(this.keptIndices[i]) || o.version != unchecked(this.keptVersions[i])
                || o.closed != unchecked(this.keptClosed[i]) || o.scenario != unchecked(this.keptScenarios[i])
                || o.hasBounds != unchecked(this.keptBoxed[i]) || !(o.world == unchecked(this.keptWorlds[i]))) {
                return false;
            }
        }
        return true;
    }

    // Notes what the buffer was just made from (keptFrom), in the kept
    // arrays (grown to the most occluders a frame held).
    private keep(f: RenderFrame, w: i32, h: i32): void {
        const occ = f.occluders;
        const n = occ.length;
        this.keptVertices.length = n;
        this.keptIndices.length = n;
        this.keptVersions.length = n;
        this.keptWorlds.length = n;
        this.keptClosed.length = n;
        this.keptScenarios.length = n;
        this.keptBoxed.length = n;
        for (let i = 0; i < n; i++) {
            const o = unchecked(occ[i]);
            unchecked(this.keptVertices[i] = o.vertices);
            unchecked(this.keptIndices[i] = o.indices);
            unchecked(this.keptVersions[i] = o.version);
            unchecked(this.keptWorlds[i] = o.world);
            unchecked(this.keptClosed[i] = o.closed);
            unchecked(this.keptScenarios[i] = o.scenario);
            unchecked(this.keptBoxed[i] = o.hasBounds);
        }
        this.keptDepth = this.depth;
        this.keptWidth = w;
        this.keptHeight = h;
        this.keptView = this.view;
        this.keptProj = this.proj;
        this.keptNear = this.near;
        this.keptScenario = f.scenario;
        this.keptStats.copyFrom(this.stats);
        this.keptActive = this.active;
        this.keptNearest = this.nearest;
        this.kept = true;
    }

    // Whether box `b` (the frame's world) is wholly behind what the buffer
    // covers, by the rule in the header. Counts the test.
    occluded(b: Bounds): bool {
        return this.occludedInto(b, this.stats, ownRect);
    }

    // `occluded`, counted in `counts` (tested, occluded) rather than the
    // buffer's stats, its rectangles in `rect` (OCCLUSION_RECT_WORDS): a
    // unit of the cull's job counts in its own and works in its worker's
    // (jobs.as), the counts added to the buffer's after the run. Reads the
    // buffer alone.
    occludedInto(b: Bounds, counts: OcclusionStats, rect: StaticArray<i32>): bool {
        counts.tested++;
        if (!this.active) return false;
        const lo = b.min;
        const hi = b.max;
        if (!(lo.x <= hi.x && lo.y <= hi.y && lo.z <= hi.z)) return false;
        const e = this.eye;
        // (the eye inside the box: it is seen)
        if (e.x >= lo.x && e.x <= hi.x && e.y >= lo.y && e.y <= hi.y && e.z >= lo.z && e.z <= hi.z) return false;
        // The corners through the view and projection, from the lowest one
        // and the box's three edges (a sum of terms each, not a matrix a
        // corner): the clip x, y and w, and the depth along the forward.
        const m = this.viewProj;
        const v = this.view;
        const ex = hi.x - lo.x, ey = hi.y - lo.y, ez = hi.z - lo.z;
        const bd = -(v.xAxis.z * lo.x + v.yAxis.z * lo.y + v.zAxis.z * lo.z + v.wAxis.z);
        const xd = -v.xAxis.z * ex, yd = -v.yAxis.z * ey, zd = -v.zAxis.z * ez;
        // The nearest corner's depth, the corner that takes each edge whose
        // term is negative: f32 addition is monotonic, so it is the least of
        // the eight corners' depths summed in the same order. A corner
        // before the near plane (the box reaches the eye's side, Godot's
        // "closest point in front of the near plane") is seen; so is a box
        // no nearer than the nearest occluder point (the least depth any
        // texel holds), with no corner to project.
        const minDepth = bd + Mathf.min(xd, 0) + Mathf.min(yd, 0) + Mathf.min(zd, 0);
        if (!(minDepth >= this.near) || !(minDepth > this.nearest)) return false;
        const bw = m.xAxis.w * lo.x + m.yAxis.w * lo.y + m.zAxis.w * lo.z + m.wAxis.w;
        const xw = m.xAxis.w * ex, yw = m.yAxis.w * ey, zw = m.zAxis.w * ez;
        // (a corner with w <= 0 projects nowhere: seen)
        if (!(bw + Mathf.min(xw, 0) + Mathf.min(yw, 0) + Mathf.min(zw, 0) > 0)) return false;
        const bx = m.xAxis.x * lo.x + m.yAxis.x * lo.y + m.zAxis.x * lo.z + m.wAxis.x;
        const by = m.xAxis.y * lo.x + m.yAxis.y * lo.y + m.zAxis.y * lo.z + m.wAxis.y;
        const xx = m.xAxis.x * ex, xy = m.xAxis.y * ex;
        const yx = m.yAxis.x * ey, yy = m.yAxis.y * ey;
        const zx = m.zAxis.x * ez, zy = m.zAxis.y * ez;
        // The eight corners, unrolled (corner k adds the x edge for bit 0,
        // then y for bit 1, then z for bit 2, in that order): clip x, y, w.
        const cx1 = bx + xx, cy1 = by + xy, cw1 = bw + xw;
        const cx2 = bx + yx, cy2 = by + yy, cw2 = bw + yw;
        const cx3 = cx1 + yx, cy3 = cy1 + yy, cw3 = cw1 + yw;
        const cx4 = bx + zx, cy4 = by + zy, cw4 = bw + zw;
        const cx5 = cx1 + zx, cy5 = cy1 + zy, cw5 = cw1 + zw;
        const cx6 = cx2 + zx, cy6 = cy2 + zy, cw6 = cw2 + zw;
        const cx7 = cx3 + zx, cy7 = cy3 + zy, cw7 = cw3 + zw;
        // Their projections' extremes on the clip square (x right, y up).
        const n0 = bx / bw, n1 = cx1 / cw1, n2 = cx2 / cw2, n3 = cx3 / cw3;
        const n4 = cx4 / cw4, n5 = cx5 / cw5, n6 = cx6 / cw6, n7 = cx7 / cw7;
        const u0 = by / bw, u1 = cy1 / cw1, u2 = cy2 / cw2, u3 = cy3 / cw3;
        const u4 = cy4 / cw4, u5 = cy5 / cw5, u6 = cy6 / cw6, u7 = cy7 / cw7;
        const nx0 = Mathf.min(Mathf.min(Mathf.min(n0, n1), Mathf.min(n2, n3)), Mathf.min(Mathf.min(n4, n5), Mathf.min(n6, n7)));
        const nx1 = Mathf.max(Mathf.max(Mathf.max(n0, n1), Mathf.max(n2, n3)), Mathf.max(Mathf.max(n4, n5), Mathf.max(n6, n7)));
        const ny0 = Mathf.min(Mathf.min(Mathf.min(u0, u1), Mathf.min(u2, u3)), Mathf.min(Mathf.min(u4, u5), Mathf.min(u6, u7)));
        const ny1 = Mathf.max(Mathf.max(Mathf.max(u0, u1), Mathf.max(u2, u3)), Mathf.max(Mathf.max(u4, u5), Mathf.max(u6, u7)));
        // On the buffer (texels, y down): the extremes' projections are
        // the projections' extremes, the mapping being monotonic.
        const W = <f32>this.width;
        const H = <f32>this.height;
        let rx0 = (nx0 * <f32>0.5 + <f32>0.5) * W;
        let rx1 = (nx1 * <f32>0.5 + <f32>0.5) * W;
        let ry0 = (<f32>0.5 - ny1 * <f32>0.5) * H;
        let ry1 = (<f32>0.5 - ny0 * <f32>0.5) * H;
        if (!(rx1 >= 0 && ry1 >= 0 && rx0 <= W && ry0 <= H)) return false;
        rx0 = Mathf.max(rx0, 0);
        ry0 = Mathf.max(ry0, 0);
        rx1 = Mathf.min(rx1, W);
        ry1 = Mathf.min(ry1, H);
        // Level 0's rectangle, widened by one texel each side, at most into
        // the guard band (the view's texel x is the buffer's x + 1).
        unchecked(rect[0] = <i32>Mathf.floor(rx0));
        unchecked(rect[RECT_X1] = min<i32>(<i32>Mathf.floor(rx1) + 2, this.width + 1));
        unchecked(rect[RECT_Y0] = <i32>Mathf.floor(ry0));
        unchecked(rect[RECT_Y1] = min<i32>(<i32>Mathf.floor(ry1) + 2, this.height + 1));
        // The first level read: its texel at least the rectangle's larger
        // side (Godot's ceil(log2(size))); the texels of each level holding
        // level 0's.
        const size = Mathf.max(rx1 - rx0, ry1 - ry0);
        let lod = 0;
        while (lod < this.levels - 1 && <f32>(1 << lod) < size) lod++;
        for (let l = 1; l <= lod; l++) {
            const lw = unchecked(this.levelWidth[l]) - 1;
            const lh = unchecked(this.levelHeight[l]) - 1;
            unchecked(rect[l] = min<i32>(unchecked(rect[l - 1]) >> 1, lw));
            unchecked(rect[RECT_X1 + l] = min<i32>(unchecked(rect[RECT_X1 + l - 1]) >> 1, lw));
            unchecked(rect[RECT_Y0 + l] = min<i32>(unchecked(rect[RECT_Y0 + l - 1]) >> 1, lh));
            unchecked(rect[RECT_Y1 + l] = min<i32>(unchecked(rect[RECT_Y1 + l - 1]) >> 1, lh));
        }
        const dep = this.depth;
        let samples = 0;
        for (let l = lod; l >= 0; l--) {
            const x0 = unchecked(rect[l]);
            const x1 = unchecked(rect[RECT_X1 + l]);
            const y0 = unchecked(rect[RECT_Y0 + l]);
            const y1 = unchecked(rect[RECT_Y1 + l]);
            samples += (x1 - x0 + 1) * (y1 - y0 + 1);
            if (samples > OCCLUSION_MAX_SAMPLES) return false;
            const lw = unchecked(this.levelWidth[l]);
            const off = unchecked(this.levelOffset[l]);
            let seen = false;
            for (let y = y0; y <= y1 && !seen; y++) {
                const row = off + y * lw;
                for (let x = x0; x <= x1; x++) {
                    if (!(unchecked(dep[row + x]) < minDepth)) {
                        seen = true;
                        break;
                    }
                }
            }
            if (!seen) {
                counts.occluded++;
                return true;
            }
        }
        return false;
    }

    // `occluded` for item `i` of the frame culled (cull.as), answered as
    // before when the buffer was kept (prepare drew nothing new) and the
    // item's box is the one it was asked with: the same buffer and the same
    // box give the same answer, counted the same, for a few comparisons.
    occludedAt(i: i32, b: Bounds): bool {
        if (i >= 0) this.reserveAnswers(i + 1);
        return this.occludedAtInto(i, b, this.stats, ownRect);
    }

    // Room for the answers of items 0 to n - 1 (before a job's units ask
    // occludedAtInto, which then grows nothing).
    reserveAnswers(n: i32): void {
        if (n > this.answerGeneration.length) {
            this.answerGeneration.length = n;
            this.answerLo.length = n;
            this.answerHi.length = n;
            this.answerOccluded.length = n;
        }
    }

    // `occludedAt`, counted in `counts`, for an item below reserveAnswers'
    // (cull.as's job: each unit asks for its own items, so each answer is
    // written by one unit alone).
    occludedAtInto(i: i32, b: Bounds, counts: OcclusionStats, rect: StaticArray<i32>): bool {
        if (i < 0 || i >= this.answerGeneration.length) return this.occludedInto(b, counts, rect);
        if (unchecked(this.answerGeneration[i]) == this.generation && this.active
            && b.min == unchecked(this.answerLo[i]) && b.max == unchecked(this.answerHi[i])) {
            const was = unchecked(this.answerOccluded[i]);
            counts.tested++;
            if (was) counts.occluded++;
            return was;
        }
        const r = this.occludedInto(b, counts, rect);
        unchecked(this.answerGeneration[i] = this.generation);
        unchecked(this.answerLo[i] = b.min);
        unchecked(this.answerHi[i] = b.max);
        unchecked(this.answerOccluded[i] = r);
        return r;
    }

    // The farthest depth over the view's texels [x0, x1] x [y0, y1] of
    // level 0 (clamped to the buffer, its guard band included: -1 to width
    // across, -1 to height down; +infinity where nothing is, and for an
    // empty range), for tests and the debug picture.
    farthest(x0: i32, y0: i32, x1: i32, y1: i32): f32 {
        if (this.width <= 0 || this.height <= 0) return f32.POSITIVE_INFINITY;
        const a = max<i32>(x0, -1);
        const b = min<i32>(x1, this.width);
        const c = max<i32>(y0, -1);
        const d = min<i32>(y1, this.height);
        if (a > b || c > d) return f32.POSITIVE_INFINITY;
        let far = -f32.POSITIVE_INFINITY;
        const dep = this.depth;
        const stride = this.width + 2;
        for (let y = c; y <= d; y++) {
            for (let x = a; x <= b; x++) {
                const v = unchecked(dep[(y + 1) * stride + x + 1]);
                if (!(v <= far)) far = v;
            }
        }
        return far;
    }

    // The depth of the view's texel (x, y) of level 0: -1 and width across,
    // -1 and height down, are the guard band's; +infinity outside it, or
    // where nothing is.
    texel(x: i32, y: i32): f32 {
        if (x < -1 || y < -1 || x > this.width || y > this.height || this.width <= 0) return f32.POSITIVE_INFINITY;
        const i = (y + 1) * (this.width + 2) + x + 1;
        return i < this.depth.length ? unchecked(this.depth[i]) : f32.POSITIVE_INFINITY;
    }

    // Lays the levels out for a view of `w` x `h` texels (level 0 the
    // guard band's (w + 2) x (h + 2)), growing the storage when it is too
    // small (never shrinking it).
    private size(w: i32, h: i32): void {
        this.width = w;
        this.height = h;
        let total = 0;
        let lw = w + 2;
        let lh = h + 2;
        let k = 0;
        while (true) {
            unchecked(this.levelWidth[k] = lw);
            unchecked(this.levelHeight[k] = lh);
            unchecked(this.levelOffset[k] = total);
            total += lw * lh;
            k++;
            if ((lw == 1 && lh == 1) || k >= MAX_LEVELS) break;
            lw = max<i32>(1, lw >> 1);
            lh = max<i32>(1, lh >> 1);
        }
        this.levels = k;
        if (this.depth.length < total) this.depth = new Float32Array(total);
    }

    // Each level from the one before: a texel the farthest of its
    // children (two by two; the last column or row of a level of odd size
    // folded into the last parent; a level 1 texel wide or tall keeps its
    // one column or row). The common texel is four reads in a loop of its
    // own; the folded ones are read again after it.
    private buildLevels(): void {
        const ex = jobs();
        const workers = ex.workers();
        for (let l = 1; l < this.levels; l++) {
            const ph = unchecked(this.levelHeight[l]);
            // (one worker: the level at once; more: a job of bands of its
            // rows, each texel from its own children alone, so the same)
            if (workers <= 1) {
                this.foldLevel(l, 0, ph);
            } else {
                const job = levelJob;
                job.buffer = this;
                job.level = l;
                ex.run(job, ph, grainFor(ph, workers));
                job.buffer = null;
            }
        }
    }

    // Rows `y0` to `y1 - 1` of level `l` from level l - 1 (buildLevels).
    foldLevel(l: i32, y0: i32, y1: i32): void {
        const dep = this.depth;
        const cw = unchecked(this.levelWidth[l - 1]);
        const ch = unchecked(this.levelHeight[l - 1]);
        const co = unchecked(this.levelOffset[l - 1]);
        const pw = unchecked(this.levelWidth[l]);
        const ph = unchecked(this.levelHeight[l]);
        const po = unchecked(this.levelOffset[l]);
        const sx = cw > 1 ? 1 : 0;
        const sy = ch > 1 ? cw : 0;
        const base = dep.dataStart;
        for (let y = y0; y < y1; y++) {
            const r0 = co + (ch > 1 ? y * 2 : 0) * cw;
            const r1 = r0 + sy;
            const out = po + y * pw;
            if (sx != 0 && sy != 0) {
                // (the common texel: its four children through pointers)
                foldRow(base + (<usize>r0 << 2), base + (<usize>out << 2), pw, <usize>cw << 2);
            } else {
                let c = r0;
                for (let x = 0; x < pw; x++) {
                    const a = maxDepth(unchecked(dep[c]), unchecked(dep[c + sx]));
                    const b = maxDepth(unchecked(dep[c + sy]), unchecked(dep[c + sy + sx]));
                    unchecked(dep[out + x] = maxDepth(a, b));
                    c += sx + sx;
                }
            }
            // (an odd width: its last column into the last parent)
            if (sx != 0 && (cw & 1) != 0) {
                const last = out + pw - 1;
                const col = r0 + cw - 1;
                unchecked(dep[last] = maxDepth(unchecked(dep[last]), maxDepth(unchecked(dep[col]), unchecked(dep[col + sy]))));
            }
            // (an odd height: its last row into the last parents)
            if (sy != 0 && y == ph - 1 && (ch & 1) != 0) {
                const r2 = r1 + cw;
                for (let x = 0; x < pw; x++) {
                    const c2 = r2 + x * 2 * sx;
                    unchecked(dep[out + x] = maxDepth(unchecked(dep[out + x]),
                        maxDepth(unchecked(dep[c2]), unchecked(dep[c2 + sx]))));
                }
                if (sx != 0 && (cw & 1) != 0) {
                    const last = out + pw - 1;
                    unchecked(dep[last] = maxDepth(unchecked(dep[last]), unchecked(dep[r2 + cw - 1])));
                }
            }
        }
    }

    // --- Setting up (the setup job) --------------------------------------

    // Every drawn occluder's triangles set up into `sink`, in order: a job
    // whose units are an occluder's triangles, SETUP_GRAIN at most; on one
    // worker each unit writes the sink itself, in order; on more, each its
    // own share, appended after the run in unit order.
    private setupAll(f: RenderFrame): void {
        const occ = f.occluders;
        const list = this.drawList;
        let units = 0;
        for (let k = 0; k < list.length; k++) {
            const tris = unchecked(occ[unchecked(list[k])]).indices.length / 3;
            units += max<i32>(1, (tris + SETUP_GRAIN - 1) / SETUP_GRAIN);
        }
        if (this.unitOcc.length < units) {
            this.unitOcc = new Int32Array(units);
            this.unitBegin = new Int32Array(units);
            this.unitEnd = new Int32Array(units);
        }
        let u = 0;
        for (let k = 0; k < list.length; k++) {
            const tris = unchecked(occ[unchecked(list[k])]).indices.length / 3;
            const parts = max<i32>(1, (tris + SETUP_GRAIN - 1) / SETUP_GRAIN);
            for (let p = 0; p < parts; p++) {
                unchecked(this.unitOcc[u] = k);
                unchecked(this.unitBegin[u] = p * SETUP_GRAIN);
                unchecked(this.unitEnd[u] = min<i32>(tris, (p + 1) * SETUP_GRAIN));
                u++;
            }
        }
        this.setupUnits = units;
        this.sink.count = 0;
        const ex = jobs();
        // (as the fill: on the calling thread alone when it fills at once)
        const direct = this.immediate;
        if (!direct) {
            while (this.unitSinks.length < units) this.unitSinks.push(new TriSink());
            while (this.workerScratch.length < ex.workers()) this.workerScratch.push(new RasterScratch());
            for (let i = 0; i < units; i++) unchecked(this.unitSinks[i]).count = 0;
        }
        const job = setupJob;
        job.buffer = this;
        job.frame = f;
        job.direct = direct;
        ex.run(job, units, 1);
        job.buffer = null;
        job.frame = null;
        if (!direct) for (let i = 0; i < units; i++) this.mergeSetupSink(i, unchecked(this.unitSinks[i]));
    }

    // Unit `u` of the setup job on worker `worker`.
    setupUnit(f: RenderFrame, u: i32, worker: i32, direct: bool): void {
        const k = unchecked(this.unitOcc[u]);
        const o = unchecked(f.occluders[unchecked(this.drawList[k])]);
        const sink = direct ? this.sink : unchecked(this.unitSinks[u]);
        const r = direct ? this.scratch : unchecked(this.workerScratch[worker]);
        this.setupOccluder(r, o, k, unchecked(this.unitBegin[u]), unchecked(this.unitEnd[u]), sink);
        if (direct && unchecked(this.unitBegin[u]) == 0) unchecked(this.drawNearest[k] = sink.nearest);
    }

    // Unit `u`'s share after the sink's triangles, and its nearest point.
    mergeSetupSink(u: i32, share: TriSink): void {
        this.sink.append(share);
        if (unchecked(this.unitBegin[u]) == 0) unchecked(this.drawNearest[unchecked(this.unitOcc[u])] = share.nearest);
    }

    // The words packSetup() writes for `f`: a header, each unit's
    // occluder and range; each drawn occluder's world, closing, points and
    // indices.
    setupWords(f: RenderFrame): i32 {
        const occ = f.occluders;
        const list = this.drawList;
        let words = SP_HEADER + this.setupUnits * 3 + list.length * SP_OCCLUDER;
        for (let k = 0; k < list.length; k++) {
            const o = unchecked(occ[unchecked(list[k])]);
            words += o.vertices.length + o.indices.length;
        }
        return words;
    }

    packSetup(f: RenderFrame, into: ArrayBuffer): void {
        const fw = Float32Array.wrap(into);
        const iw = Int32Array.wrap(into);
        const uw = Uint32Array.wrap(into);
        const occ = f.occluders;
        const list = this.drawList;
        const n = list.length;
        const units = this.setupUnits;
        unchecked(iw[0] = this.width);
        unchecked(iw[1] = this.height);
        unchecked(iw[2] = this.ortho ? 1 : 0);
        unchecked(fw[3] = this.near);
        putMat4(fw, 4, this.view);
        putMat4(fw, 20, this.proj);
        unchecked(iw[36] = n);
        unchecked(iw[37] = units);
        let at = SP_HEADER;
        for (let u = 0; u < units; u++) {
            unchecked(iw[at] = unchecked(this.unitOcc[u]));
            unchecked(iw[at + 1] = unchecked(this.unitBegin[u]));
            unchecked(iw[at + 2] = unchecked(this.unitEnd[u]));
            at += 3;
        }
        const heads = at;
        at += n * SP_OCCLUDER;
        for (let k = 0; k < n; k++) {
            const o = unchecked(occ[unchecked(list[k])]);
            const h = heads + k * SP_OCCLUDER;
            putMat4(fw, h, o.world);
            unchecked(iw[h + 16] = o.closed ? 1 : 0);
            const nv = o.vertices.length;
            const ni = o.indices.length;
            unchecked(iw[h + 17] = at);
            unchecked(iw[h + 18] = nv);
            copyFloats(fw, at, o.vertices, 0, nv);
            at += nv;
            unchecked(iw[h + 19] = at);
            unchecked(iw[h + 20] = ni);
            copyUints(uw, at, o.indices, 0, ni);
            at += ni;
        }
    }

    // A lane's buffer from what packSetup() wrote: the view, the units,
    // the occluders (drawList all of them); the occluders.
    unpackSetup(words: ArrayBuffer): Array<OccluderDesc> {
        const fw = Float32Array.wrap(words);
        const iw = Int32Array.wrap(words);
        const uw = Uint32Array.wrap(words);
        this.width = unchecked(iw[0]);
        this.height = unchecked(iw[1]);
        this.ortho = unchecked(iw[2]) != 0;
        this.near = unchecked(fw[3]);
        this.view = getMat4(fw, 4);
        this.proj = getMat4(fw, 20);
        const n = unchecked(iw[36]);
        const units = unchecked(iw[37]);
        this.setupUnits = units;
        this.unitOcc = new Int32Array(units);
        this.unitBegin = new Int32Array(units);
        this.unitEnd = new Int32Array(units);
        let at = SP_HEADER;
        for (let u = 0; u < units; u++) {
            unchecked(this.unitOcc[u] = unchecked(iw[at]));
            unchecked(this.unitBegin[u] = unchecked(iw[at + 1]));
            unchecked(this.unitEnd[u] = unchecked(iw[at + 2]));
            at += 3;
        }
        const occ = new Array<OccluderDesc>(n);
        this.drawList.length = n;
        for (let k = 0; k < n; k++) {
            const h = at + k * SP_OCCLUDER;
            const o = new OccluderDesc();
            o.world = getMat4(fw, h);
            o.closed = unchecked(iw[h + 16]) != 0;
            const va = unchecked(iw[h + 17]);
            const nv = unchecked(iw[h + 18]);
            const ia = unchecked(iw[h + 19]);
            const ni = unchecked(iw[h + 20]);
            o.vertices = new Float32Array(nv);
            copyFloats(o.vertices, 0, fw, va, nv);
            o.indices = new Uint32Array(ni);
            copyUints(o.indices, 0, uw, ia, ni);
            occ[k] = o;
            unchecked(this.drawList[k] = k);
        }
        return occ;
    }

    // Unit `u` of the setup on a lane into `w`: its triangles' floats then
    // its nearest point, its triangles' occluders as ints.
    setupLaneUnit(occ: Array<OccluderDesc>, u: i32, w: LaneResultWriter): void {
        const share = this.sink;
        share.count = 0;
        const k = unchecked(this.unitOcc[u]);
        this.setupOccluder(this.scratch, unchecked(occ[k]), k, unchecked(this.unitBegin[u]), unchecked(this.unitEnd[u]), share);
        w.begin(u);
        const n = share.count;
        const at = w.reserveFloats(n * TRI_FLOATS + 1);
        const fl = w.floatArray();
        copyFloats(fl, at, share.tris, 0, n * TRI_FLOATS);
        unchecked(fl[at + n * TRI_FLOATS] = share.nearest);
        w.addInts(share.occ, n);
    }

    // What a lane set up of unit `u` (the `at`-th of r.units) as its
    // share (mergeSetupSink after the run).
    takeSetupLane(u: i32, r: LaneResult, at: i32): void {
        const share = unchecked(this.unitSinks[u]);
        const ia = unchecked(r.unitInts[at]);
        const fa = unchecked(r.unitFloats[at]);
        const n = (at + 1 < r.units.length ? unchecked(r.unitInts[at + 1]) : r.ints.length) - ia;
        share.count = 0;
        if (n * TRI_FLOATS > share.tris.length) share.grow(n);
        copyFloats(share.tris, 0, r.floats, fa, n * TRI_FLOATS);
        copyInts(share.occ, 0, r.ints, ia, n);
        share.count = n;
        share.nearest = unchecked(r.floats[fa + n * TRI_FLOATS]);
    }

    // The triangles of the occluders the last prepare drew.
    drawnTriangles(f: RenderFrame): i32 {
        let t = 0;
        const occ = f.occluders;
        const list = this.drawList;
        for (let k = 0; k < list.length; k++) t += unchecked(occ[unchecked(list[k])]).indices.length / 3;
        return t;
    }

    // --- The fill on lanes (FillJob) --------------------------------------

    // The (triangle, tile) pairs the last prepare binned.
    binnedCount(): i32 {
        return this.tilesX * this.tilesY > 0 ? unchecked(this.binStart[this.tilesX * this.tilesY]) : 0;
    }

    // The occluders the last prepare drew.
    drawnCount(): i32 {
        return this.drawList.length;
    }

    // The words pack() writes.
    packedWords(): i32 {
        const tiles = this.tilesX * this.tilesY;
        return PK_HEADER + this.sink.count * (TRI_FLOATS + 1) + tiles + 1 + unchecked(this.binStart[tiles]);
    }

    // What the tiles' fill reads, into `into` (packedWords long at least).
    pack(into: ArrayBuffer): void {
        const fw = Float32Array.wrap(into);
        const iw = Int32Array.wrap(into);
        const n = this.sink.count;
        const tiles = this.tilesX * this.tilesY;
        const items = unchecked(this.binStart[tiles]);
        unchecked(iw[PK_WIDTH] = this.width);
        unchecked(iw[PK_HEIGHT] = this.height);
        unchecked(iw[PK_ORTHO] = this.ortho ? 1 : 0);
        unchecked(iw[PK_DRAWN] = this.drawList.length);
        unchecked(iw[PK_TRIS] = n);
        unchecked(iw[PK_TILES_X] = this.tilesX);
        unchecked(iw[PK_TILES_Y] = this.tilesY);
        unchecked(iw[PK_ITEMS] = items);
        unchecked(iw[PK_BAND] = this.bandRows);
        let at = PK_HEADER;
        copyFloats(fw, at, this.sink.tris, 0, n * TRI_FLOATS);
        at += n * TRI_FLOATS;
        copyInts(iw, at, this.sink.occ, 0, n);
        at += n;
        copyInts(iw, at, this.binStart, 0, tiles + 1);
        at += tiles + 1;
        copyInts(iw, at, this.binItems, 0, items);
    }

    // A lane's buffer, from what pack() wrote: the size, the triangles and
    // the bins (no texels of its own: a lane fills tiles of its own).
    unpack(words: ArrayBuffer): void {
        const fw = Float32Array.wrap(words);
        const iw = Int32Array.wrap(words);
        this.width = unchecked(iw[PK_WIDTH]);
        this.height = unchecked(iw[PK_HEIGHT]);
        this.ortho = unchecked(iw[PK_ORTHO]) != 0;
        this.drawList.length = unchecked(iw[PK_DRAWN]);
        const n = unchecked(iw[PK_TRIS]);
        this.tilesX = unchecked(iw[PK_TILES_X]);
        this.tilesY = unchecked(iw[PK_TILES_Y]);
        const items = unchecked(iw[PK_ITEMS]);
        this.bandRows = unchecked(iw[PK_BAND]);
        const tiles = this.tilesX * this.tilesY;
        this.sink.count = n;
        this.sink.tris = new Float32Array(n * TRI_FLOATS);
        this.sink.occ = new Int32Array(n);
        this.binStart = new Int32Array(tiles + 1);
        this.binItems = new Int32Array(items);
        let at = PK_HEADER;
        copyFloats(this.sink.tris, 0, fw, at, n * TRI_FLOATS);
        at += n * TRI_FLOATS;
        copyInts(this.sink.occ, 0, iw, at, n);
        at += n;
        copyInts(this.binStart, 0, iw, at, tiles + 1);
        at += tiles + 1;
        copyInts(this.binItems, 0, iw, at, items);
    }

    // What a lane filled of tile `tile` (the `at`-th of r.units) into the
    // buffer: its texels row by row, what it wrote of each occluder.
    mergeTile(tile: i32, r: LaneResult, at: i32): void {
        const tw = this.tileWidth(tile);
        const th = this.tileHeight(tile);
        const row0 = this.tileRows(tile) + 1;
        const col0 = this.tileCols(tile) + 1;
        const stride = this.width + 2;
        const fa = unchecked(r.unitFloats[at]);
        for (let y = 0; y < th; y++) copyWords(this.depth, (row0 + y) * stride + col0, r.floats, fa + y * tw, tw);
        const n = this.drawList.length;
        const ia = unchecked(r.unitInts[at]);
        for (let k = 0; k < n; k++) unchecked(this.tileTexels[tile * n + k] = unchecked(r.ints[ia + k]));
    }

    // Sets up occluder `o`'s triangles (see the header), `k` its place in
    // drawList; its nearest point into drawNearest.
    // (Its triangles [tBegin, tEnd) alone, into `sink`; the nearest point
    // into the sink's `nearest`.)
    setupOccluder(r: RasterScratch, o: OccluderDesc, k: i32, tBegin: i32, tEnd: i32, sink: TriSink): void {
        const verts = o.vertices;
        const idx = o.indices;
        const np = verts.length / 3;
        if (np == 0 || idx.length < 3) return;
        const mv = this.view * o.world;
        // A closed occluder's faces turned away are left out: turned
        // outwards, the faces seen from outside are counter-clockwise in
        // the view (clockwise on the buffer, whose y is down: a negative
        // area), unless its transform mirrors it.
        let facing: f32 = 0;
        if (o.closed) {
            const det = mv.xAxis.x * (mv.yAxis.y * mv.zAxis.z - mv.zAxis.y * mv.yAxis.z)
                - mv.yAxis.x * (mv.xAxis.y * mv.zAxis.z - mv.zAxis.y * mv.xAxis.z)
                + mv.zAxis.x * (mv.xAxis.y * mv.yAxis.z - mv.yAxis.y * mv.xAxis.z);
            facing = det > 0 ? -1 : det < 0 ? 1 : 0;
        }
        r.facing = facing;
        const near = this.near;
        // (its points in view space once a prepare, for its every unit the
        // scratch works in: the scratch keeps the last occluder's)
        if (r.pointsOf == k && r.pointsGeneration == this.generation) {
            sink.nearest = r.pointsNearest;
            if (!r.pointsFront) return;
            this.setupRange(r, o, k, tBegin, tEnd, sink);
            return;
        }
        if (r.viewPoints.length < np * 3) r.viewPoints = new Float32Array(np * 3);
        const vp = r.viewPoints;
        let front = false;
        let least = f32.POSITIVE_INFINITY;
        for (let i = 0; i < np; i++) {
            const x = unchecked(verts[i * 3]);
            const y = unchecked(verts[i * 3 + 1]);
            const z = unchecked(verts[i * 3 + 2]);
            const vx = mv.xAxis.x * x + mv.yAxis.x * y + mv.zAxis.x * z + mv.wAxis.x;
            const vy = mv.xAxis.y * x + mv.yAxis.y * y + mv.zAxis.y * z + mv.wAxis.y;
            const vz = mv.xAxis.z * x + mv.yAxis.z * y + mv.zAxis.z * z + mv.wAxis.z;
            unchecked(vp[i * 3] = vx);
            unchecked(vp[i * 3 + 1] = vy);
            unchecked(vp[i * 3 + 2] = vz);
            if (-vz >= near) front = true;
            least = Mathf.min(least, -vz);
        }
        r.pointsNearest = least;
        r.pointsFront = front;
        r.pointsOf = k;
        r.pointsGeneration = this.generation;
        sink.nearest = least;
        // (wholly behind the near plane: nothing to draw)
        if (!front) return;
        this.setupRange(r, o, k, tBegin, tEnd, sink);
    }

    // Triangles [tBegin, tEnd) of occluder `o` (its points in `r`).
    private setupRange(r: RasterScratch, o: OccluderDesc, k: i32, tBegin: i32, tEnd: i32, sink: TriSink): void {
        const idx = o.indices;
        const np = o.vertices.length / 3;
        const tris = min<i32>(idx.length / 3, tEnd);
        for (let t = tBegin; t < tris; t++) {
            const a = <i32>unchecked(idx[t * 3]);
            const b = <i32>unchecked(idx[t * 3 + 1]);
            const c = <i32>unchecked(idx[t * 3 + 2]);
            if (a >= np || b >= np || c >= np) continue;
            this.setupTriangle(r, a, b, c, k, sink);
        }
    }

    // Triangle (a, b, c) of the view points clipped against the near
    // plane, projected and set up (a fan of the clipped polygon: addTri),
    // with the value of its plane over the screen (planeOf), for occluder
    // `occ`. Each point and each
    // crossing of the near plane is computed from the triangle's points in
    // the order of their indices, so that the same triangle given in
    // another order or winding writes the same bytes.
    private setupTriangle(r: RasterScratch, a: i32, b: i32, c: i32, occ: i32, sink: TriSink): void {
        if (!this.planeOf(r, a, b, c)) return;
        const vp = r.viewPoints;
        const near = this.near;
        let n = 0;
        for (let e = 0; e < 3; e++) {
            const i = e == 0 ? a : e == 1 ? b : c;
            const j = e == 0 ? b : e == 1 ? c : a;
            const iz = unchecked(vp[i * 3 + 2]);
            const jz = unchecked(vp[j * 3 + 2]);
            const iIn = -iz >= near;
            const jIn = -jz >= near;
            if (iIn) {
                unchecked(r.clipX[n] = unchecked(vp[i * 3]));
                unchecked(r.clipY[n] = unchecked(vp[i * 3 + 1]));
                unchecked(r.clipZ[n] = iz);
                n++;
            }
            if (iIn != jIn) {
                const lo = min<i32>(i, j);
                const hi = max<i32>(i, j);
                const lx = unchecked(vp[lo * 3]), ly = unchecked(vp[lo * 3 + 1]), lz = unchecked(vp[lo * 3 + 2]);
                const hx = unchecked(vp[hi * 3]), hy = unchecked(vp[hi * 3 + 1]), hz = unchecked(vp[hi * 3 + 2]);
                const t = (near + lz) / (lz - hz);
                unchecked(r.clipX[n] = lx + (hx - lx) * t);
                unchecked(r.clipY[n] = ly + (hy - ly) * t);
                unchecked(r.clipZ[n] = -near);
                n++;
            }
        }
        if (n < 3) return;
        const p = this.proj;
        const W = <f32>this.width;
        const H = <f32>this.height;
        for (let k = 0; k < n; k++) {
            const vx = unchecked(r.clipX[k]);
            const vy = unchecked(r.clipY[k]);
            const vz = unchecked(r.clipZ[k]);
            const px = p.xAxis.x * vx + p.yAxis.x * vy + p.zAxis.x * vz + p.wAxis.x;
            const py = p.xAxis.y * vx + p.yAxis.y * vy + p.zAxis.y * vz + p.wAxis.y;
            const pw = p.xAxis.w * vx + p.yAxis.w * vy + p.zAxis.w * vz + p.wAxis.w;
            if (!(pw > 0)) return;
            const sx = (px / pw * <f32>0.5 + <f32>0.5) * W;
            const sy = (<f32>0.5 - py / pw * <f32>0.5) * H;
            if (!isFinite(sx) || !isFinite(sy)) return;
            unchecked(r.scrX[k] = sx);
            unchecked(r.scrY[k] = sy);
        }
        for (let k = 1; k + 1 < n; k++) this.addTri(r, 0, k, k + 1, occ, sink);
    }

    // The plane of triangle (a, b, c) of the view points as q over the
    // buffer, q = planeA x + planeB y + planeC at texel point (x, y): 1 /
    // depth in perspective (the depth along the ray through a point of the
    // screen is w / (n . r) for the plane n . p = w and the ray's direction
    // r, so its inverse is affine across the screen), the depth in
    // orthographic. Computed in f64 from the points in the order of their
    // indices, from the triangle itself (not from its clipped corners, which
    // can lie far off the buffer). False for a triangle seen edge on (or
    // through the eye), which covers nothing.
    private planeOf(r: RasterScratch, a: i32, b: i32, c: i32): bool {
        const vp = r.viewPoints;
        let i = a, j = b, k = c;
        // (each swap turns the triangle over: `turned` says whether the
        // sorted order winds the other way)
        let turned = false;
        if (i > j) { const t = i; i = j; j = t; turned = !turned; }
        if (j > k) { const t = j; j = k; k = t; turned = !turned; }
        if (i > j) { const t = i; i = j; j = t; turned = !turned; }
        const ax = <f64>unchecked(vp[i * 3]), ay = <f64>unchecked(vp[i * 3 + 1]), az = <f64>unchecked(vp[i * 3 + 2]);
        const ux = <f64>unchecked(vp[j * 3]) - ax, uy = <f64>unchecked(vp[j * 3 + 1]) - ay;
        const uz = <f64>unchecked(vp[j * 3 + 2]) - az;
        const vx = <f64>unchecked(vp[k * 3]) - ax, vy = <f64>unchecked(vp[k * 3 + 1]) - ay;
        const vz = <f64>unchecked(vp[k * 3 + 2]) - az;
        const nx = uy * vz - uz * vy;
        const ny = uz * vx - ux * vz;
        const nz = ux * vy - uy * vx;
        const w = nx * ax + ny * ay + nz * az;
        // A closed occluder's face turned away from the eye covers nothing
        // the faces turned towards it do not (fill's test, made here before
        // the triangle is clipped and projected): seen from outside, a
        // face's normal in its own winding points at the eye, so its plane
        // passes on the far side of the eye (w < 0 in perspective, the eye
        // the origin), or it points along +z (orthographic); `facing` is -1
        // for an occluder that keeps those, 1 for a mirrored one.
        const facing = r.facing;
        if (facing != 0) {
            const side = this.ortho ? -nz : w;
            if (<f64>facing * (turned ? -side : side) < 0) return false;
        }
        const p = this.proj;
        const p00 = <f64>p.xAxis.x;
        const p11 = <f64>p.yAxis.y;
        // texel x -> ndc x = 2 x / W - 1, texel y -> ndc y = 1 - 2 y / H
        const kx = 2.0 / (<f64>this.width * p00);
        const ky = -2.0 / (<f64>this.height * p11);
        let qa: f64, qb: f64, qc: f64;
        if (this.ortho) {
            // view x = (ndc x - P30) / P00, depth d = (nx x + ny y - w) / nz
            if (!(nz != 0)) return false;
            const x0 = (-1.0 - <f64>p.wAxis.x) / p00;
            const y0 = (1.0 - <f64>p.wAxis.y) / p11;
            qa = nx * kx / nz;
            qb = ny * ky / nz;
            qc = (nx * x0 + ny * y0 - w) / nz;
        } else {
            // the ray (tx, ty, -1), tx = (ndc x + P20) / P00; q = n . r / w
            if (!(w != 0)) return false;
            const x0 = (-1.0 + <f64>p.zAxis.x) / p00;
            const y0 = (1.0 + <f64>p.zAxis.y) / p11;
            qa = nx * kx / w;
            qb = ny * ky / w;
            qc = (nx * x0 + ny * y0 - nz) / w;
        }
        if (!isFinite(qa) || !isFinite(qb) || !isFinite(qc)) return false;
        r.planeA = <f32>qa;
        r.planeB = <f32>qb;
        r.planeC = <f32>qc;
        return true;
    }

    // Screen triangle (i, j, k) of the clipped polygon, for occluder
    // `occ`, kept (tris) when it may cover a texel's centre: not seen edge
    // on, not a closed occluder's face turned away from the eye, not wholly
    // beside or above or below the buffer; turned to run clockwise (y down)
    // as fillTri wants it. Double-sided: the other winding is the same
    // triangle turned.
    private addTri(r: RasterScratch, i: i32, j: i32, k: i32, occ: i32, sink: TriSink): void {
        const x0 = unchecked(r.scrX[i]), y0 = unchecked(r.scrY[i]);
        let x1 = unchecked(r.scrX[j]), y1 = unchecked(r.scrY[j]);
        let x2 = unchecked(r.scrX[k]), y2 = unchecked(r.scrY[k]);
        const area = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0);
        if (!(area != 0) || !isFinite(area)) return;
        // (a closed occluder's face turned away from the eye)
        if (r.facing * area < 0) return;
        if (area < 0) {
            const tx = x1, ty = y1;
            x1 = x2;
            y1 = y2;
            x2 = tx;
            y2 = ty;
        }
        const W = this.width;
        const H = this.height;
        // (wholly left of the first column's centres or right of the last's,
        // or above the first row's or below the last's: it covers none)
        const xlo = x0 < x1 ? (x0 < x2 ? x0 : x2) : (x1 < x2 ? x1 : x2);
        const xhi = x0 > x1 ? (x0 > x2 ? x0 : x2) : (x1 > x2 ? x1 : x2);
        if (!(xhi > <f32>-0.5) || !(xlo <= <f32>W + <f32>0.5)) return;
        if (this.immediate) {
            // (filled at once, into the whole buffer, and not kept)
            const texels = this.fillValues(x0, y0, x1, y1, x2, y2, r.planeA, r.planeB, r.planeC, this.depth.dataStart, 0, 0,
                W + 2, -1, H, -1, W);
            unchecked(this.tileTexels[occ] = unchecked(this.tileTexels[occ]) + texels);
            return;
        }
        const ylo = y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2);
        const yhi = y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2);
        if (max<i32>(<i32>Mathf.ceil(ylo - <f32>0.5), -1) > min<i32>(<i32>Mathf.floor(yhi - <f32>0.5), H)) return;
        sink.room();
        const n = sink.count;
        const t = sink.tris;
        const o = n * TRI_FLOATS;
        unchecked(t[o] = x0);
        unchecked(t[o + 1] = y0);
        unchecked(t[o + 2] = x1);
        unchecked(t[o + 3] = y1);
        unchecked(t[o + 4] = x2);
        unchecked(t[o + 5] = y2);
        unchecked(t[o + 6] = r.planeA);
        unchecked(t[o + 7] = r.planeB);
        unchecked(t[o + 8] = r.planeC);
        unchecked(sink.occ[n] = occ);
        sink.count = n + 1;
    }

    // The tiles each set-up triangle may cover a texel of: its rows (those
    // whose centre is in its height) and its columns widened by two texels
    // each side (a span's ends are crossings of its edges, which f32 may
    // put a hair past its corners), into binStart and binItems, each tile's
    // triangles in their order.
    private binTriangles(band: i32): void {
        const W = this.width;
        const H = this.height;
        const tx = 1;
        const ty = (H + 2 + band - 1) / band;
        this.tilesX = tx;
        this.tilesY = ty;
        this.bandRows = band;
        const tiles = tx * ty;
        if (this.binStart.length < tiles + 1) this.binStart = new Int32Array(tiles + 1);
        const start = this.binStart;
        for (let i = 0; i <= tiles; i++) unchecked(start[i] = 0);
        const t = this.sink.tris;
        const n = this.sink.count;
        // Twice: the counts, then the triangles in place.
        let placed = 0;
        for (let pass = 0; pass < 2; pass++) {
            for (let q = 0; q < n; q++) {
                const o = q * TRI_FLOATS;
                const x0 = unchecked(t[o]), y0 = unchecked(t[o + 1]);
                const x1 = unchecked(t[o + 2]), y1 = unchecked(t[o + 3]);
                const x2 = unchecked(t[o + 4]), y2 = unchecked(t[o + 5]);
                const xlo = x0 < x1 ? (x0 < x2 ? x0 : x2) : (x1 < x2 ? x1 : x2);
                const xhi = x0 > x1 ? (x0 > x2 ? x0 : x2) : (x1 > x2 ? x1 : x2);
                const ylo = y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2);
                const yhi = y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2);
                // (view rows and columns, -1 to H and W; the buffer's are one more)
                const r0 = max<i32>(<i32>Mathf.ceil(ylo - <f32>0.5), -1);
                const r1 = min<i32>(<i32>Mathf.floor(yhi - <f32>0.5), H);
                const c0 = max<i32>(<i32>Mathf.floor(xlo) - 2, -1);
                const c1 = min<i32>(<i32>Mathf.ceil(xhi) + 2, W);
                if (r0 > r1 || c0 > c1) continue;
                const a0 = (r0 + 1) / band, a1 = (r1 + 1) / band;
                const b0 = 0, b1 = 0;
                for (let a = a0; a <= a1; a++) {
                    for (let b = b0; b <= b1; b++) {
                        const tile = a * tx + b;
                        if (pass == 0) {
                            unchecked(start[tile + 1] = unchecked(start[tile + 1]) + 1);
                        } else {
                            const at = unchecked(start[tile]);
                            unchecked(this.binItems[at] = q);
                            unchecked(start[tile] = at + 1);
                        }
                    }
                }
            }
            if (pass == 0) {
                for (let i = 0; i < tiles; i++) unchecked(start[i + 1] = unchecked(start[i + 1]) + unchecked(start[i]));
                placed = unchecked(start[tiles]);
                if (this.binItems.length < placed) this.binItems = new Int32Array(max<i32>(placed, this.binItems.length * 2));
                // (each tile's run from its start: `start[tile]` walks to its
                // end, and is put back after)
            }
        }
        for (let i = tiles; i > 0; i--) unchecked(start[i] = unchecked(start[i - 1]));
        unchecked(start[0] = 0);
    }

    // Tile `tile`'s first view row and column (-1 to height and width).
    tileRows(tile: i32): i32 {
        return tile * this.bandRows - 1;
    }

    tileCols(tile: i32): i32 {
        return -1;
    }

    // The tile's size in texels across and down.
    tileWidth(tile: i32): i32 {
        return this.width + 2;
    }

    tileHeight(tile: i32): i32 {
        return min<i32>(this.bandRows, this.height + 2 - tile * this.bandRows);
    }

    // Unit `tile` of prepare's fill job: the tile's triangles filled into
    // the buffer, what it wrote of each occluder into tileTexels.
    fillTile(tile: i32): void {
        this.fillTileInto(tile, this.depth.dataStart, 0, 0, this.width + 2, this.tileTexels, tile * this.drawList.length);
    }

    // fillTile into the texels at `base` (buffer texel (row, col) at
    // ((row - oRow) * stride + col - oCol), its counts into `counts` from
    // `at` (by occluder).
    fillTileInto(tile: i32, base: usize, oRow: i32, oCol: i32, stride: i32, counts: Int32Array, at: i32): void {
        const rowLo = this.tileRows(tile);
        const colLo = this.tileCols(tile);
        const rowHi = rowLo + this.tileHeight(tile) - 1;
        const colHi = colLo + this.tileWidth(tile) - 1;
        const start = this.binStart;
        const items = this.binItems;
        const end = unchecked(start[tile + 1]);
        for (let i = unchecked(start[tile]); i < end; i++) {
            const q = unchecked(items[i]);
            const texels = this.fillTri(q, base, oRow, oCol, stride, rowLo, rowHi, colLo, colHi);
            const k = at + unchecked(this.sink.occ[q]);
            unchecked(counts[k] = unchecked(counts[k]) + texels);
        }
    }

    // Fills screen triangle (i, j, k) of the clipped polygon: every texel
    // whose centre it covers (the top-left rule: a centre on a left or a
    // top edge is the triangle's, on a right or a bottom edge not) takes
    // the plane's farthest depth over the texel when nearer than its own.
    // A row's span lies between where its centre line crosses the edges
    // on the left and on the right, each crossing computed from the edge's
    // points in one order whichever triangle it belongs to: two triangles
    // sharing an edge split the centres on it exactly (one's left edge is
    // the other's right one), so no texel is filled twice or missed. Each
    // edge runs from its upper point (the lesser y) to its lower one,
    // whatever way the triangle walks it, its side `d` -1 for a left edge
    // (walked upwards), 1 for a right one, 0 for a level one (`top` when
    // the triangle lies below it). The edges are held in locals and the
    // texels written through a pointer: this is the buffer's inner loop.
    // Set-up triangle `q` (addTri: clockwise, y down, so that its left
    // edges go up, its right edges down, a top edge right and a bottom edge
    // left) filled into the view's rows rowLo to rowHi and columns colLo
    // to colHi alone (a tile's: each row is filled from the triangle alone,
    // so a tile fills its texels as the whole buffer would), at `base` as
    // fillTileInto lays it out; the texels it wrote.
    fillTri(q: i32, base: usize, oRow: i32, oCol: i32, stride: i32, rowLo: i32, rowHi: i32, colLo: i32, colHi: i32): i32 {
        const t = this.sink.tris;
        const o = q * TRI_FLOATS;
        return this.fillValues(unchecked(t[o]), unchecked(t[o + 1]), unchecked(t[o + 2]), unchecked(t[o + 3]),
            unchecked(t[o + 4]), unchecked(t[o + 5]), unchecked(t[o + 6]), unchecked(t[o + 7]), unchecked(t[o + 8]), base, oRow,
            oCol, stride, rowLo, rowHi, colLo, colHi);
    }

    // fillTri of the triangle (x0, y0), (x1, y1), (x2, y2), its plane qa,
    // qb, qc0.
    private fillValues(x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, qa: f32, qb: f32, qc0: f32, base: usize,
        oRow: i32, oCol: i32, stride: i32, rowLo: i32, rowHi: i32, colLo: i32, colHi: i32): i32 {
        // (the view's texels and the guard band's: columns -1 to W and rows
        // -1 to H in the view's coordinates, each the buffer's index less
        // one, so that the view's texels are filled exactly as without it)
        const W = this.width;
        const H = this.height;
        const ylo = y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2);
        const yhi = y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2);
        // (the rows whose centre is in [ylo, yhi])
        // (and of those the tile's)
        const by0 = max<i32>(max<i32>(<i32>Mathf.ceil(ylo - <f32>0.5), -1), rowLo);
        const by1 = min<i32>(min<i32>(<i32>Mathf.floor(yhi - <f32>0.5), H), rowHi);
        if (by0 > by1) return 0;
        // Edge 0: 0 -> 1, edge 1: 1 -> 2, edge 2: 2 -> 0.
        const d0 = y1 == y0 ? 0 : y1 < y0 ? -1 : 1;
        const uy0 = d0 < 0 ? y1 : y0, ux0 = d0 < 0 ? x1 : x0;
        const ly0 = d0 < 0 ? y0 : y1, lx0 = d0 < 0 ? x0 : x1;
        const k0 = d0 != 0 ? (lx0 - ux0) / (ly0 - uy0) : <f32>0;
        const out0 = d0 == 0 && !(x1 > x0);
        const d1 = y2 == y1 ? 0 : y2 < y1 ? -1 : 1;
        const uy1 = d1 < 0 ? y2 : y1, ux1 = d1 < 0 ? x2 : x1;
        const ly1 = d1 < 0 ? y1 : y2, lx1 = d1 < 0 ? x1 : x2;
        const k1 = d1 != 0 ? (lx1 - ux1) / (ly1 - uy1) : <f32>0;
        const out1 = d1 == 0 && !(x2 > x1);
        const d2 = y0 == y2 ? 0 : y0 < y2 ? -1 : 1;
        const uy2 = d2 < 0 ? y0 : y2, ux2 = d2 < 0 ? x0 : x2;
        const ly2 = d2 < 0 ? y2 : y0, lx2 = d2 < 0 ? x2 : x0;
        const k2 = d2 != 0 ? (lx2 - ux2) / (ly2 - uy2) : <f32>0;
        const out2 = d2 == 0 && !(x0 > x2);

        // The farthest corner's offset from a texel's top-left corner: the
        // least q in perspective (depth 1 / q), the most in orthographic.
        const ortho = this.ortho;
        const cornerQ = ortho ? Mathf.max(qa, 0) + Mathf.max(qb, 0) : Mathf.min(qa, 0) + Mathf.min(qb, 0);
        const qc = qc0 + cornerQ;
        const slack = <f32>1 + OCCLUSION_DEPTH_SLACK;
        const big = <f32>W + <f32>2;
        let texels = 0;
        for (let y = by0; y <= by1; y++) {
            const py = <f32>y + <f32>0.5;
            // (a row on a bottom edge is out)
            if ((out0 && py == uy0) || (out1 && py == uy1) || (out2 && py == uy2)) continue;
            // The centres from `lo` on (a left edge's crossing: on it is
            // in) and before `hi` (a right edge's: on it is out), from the
            // edges whose rows hold this one (at an edge's lower point
            // exactly that point's x, so that edges meeting there agree).
            let lo: f32 = -big;
            let hi: f32 = big;
            if (d0 != 0 && py >= uy0 && py <= ly0) {
                const at = py == ly0 ? lx0 : ux0 + k0 * (py - uy0);
                if (d0 < 0) {
                    if (at > lo) lo = at;
                } else if (at < hi) {
                    hi = at;
                }
            }
            if (d1 != 0 && py >= uy1 && py <= ly1) {
                const at = py == ly1 ? lx1 : ux1 + k1 * (py - uy1);
                if (d1 < 0) {
                    if (at > lo) lo = at;
                } else if (at < hi) {
                    hi = at;
                }
            }
            if (d2 != 0 && py >= uy2 && py <= ly2) {
                const at = py == ly2 ? lx2 : ux2 + k2 * (py - uy2);
                if (d2 < 0) {
                    if (at > lo) lo = at;
                } else if (at < hi) {
                    hi = at;
                }
            }
            // in: centre x + 0.5 >= lo and < hi (and in the tile)
            const xs = max<i32>(max<i32>(<i32>Mathf.ceil(lo - <f32>0.5), -1), colLo);
            const xe = min<i32>(min<i32>(<i32>Mathf.ceil(hi - <f32>0.5) - 1, W), colHi);
            if (xs > xe) continue;
            const rowQ = qb * <f32>y + qc;
            texels += xe - xs + 1;
            const at = base + (<usize>((y + 1 - oRow) * stride + xs + 1 - oCol) << 2);
            if (ortho) orthoSpan(at, xe - xs + 1, <f32>xs, rowQ, qa, slack);
            else perspectiveSpan(at, xe - xs + 1, <f32>xs, rowQ, qa, slack);
        }
        return texels;
    }

    // Whether box `b` (the frame's world) is wholly off one side of the
    // view and its guard band (every corner beyond the same side of the
    // clip volume widened by two texels, past the guard texels' centres,
    // which are half a texel outside the view) or behind the near plane:
    // what lies in it covers no texel.
    private offView(b: Bounds): bool {
        const m = this.viewProj;
        const v = this.view;
        const near = this.near;
        const gx = <f32>1 + <f32>4 / <f32>this.width;
        const gy = <f32>1 + <f32>4 / <f32>this.height;
        let left = 0, right = 0, below = 0, above = 0, behind = 0;
        for (let k = 0; k < 8; k++) {
            const cx = (k & 1) != 0 ? b.max.x : b.min.x;
            const cy = (k & 2) != 0 ? b.max.y : b.min.y;
            const cz = (k & 4) != 0 ? b.max.z : b.min.z;
            const px = m.xAxis.x * cx + m.yAxis.x * cy + m.zAxis.x * cz + m.wAxis.x;
            const py = m.xAxis.y * cx + m.yAxis.y * cy + m.zAxis.y * cz + m.wAxis.y;
            const pw = m.xAxis.w * cx + m.yAxis.w * cy + m.zAxis.w * cz + m.wAxis.w;
            const vz = v.xAxis.z * cx + v.yAxis.z * cy + v.zAxis.z * cz + v.wAxis.z;
            if (px < -pw * gx) left++;
            if (px > pw * gx) right++;
            if (py < -pw * gy) below++;
            if (py > pw * gy) above++;
            if (-vz < near) behind++;
        }
        return left == 8 || right == 8 || below == 8 || above == 8 || behind == 8;
    }
}

// The buffer's inner loops, through pointers (each texel a load and a
// store, no index arithmetic): this is where the buffer's time goes.

// A row of `n` texels from `at`, the first at column `fx`: each takes the
// plane's farthest depth over it, slack / q in perspective (q = rowQ + qa
// x, x counted up as an f32: whole numbers, exact), when nearer than its
// own; q <= 0 (the plane passes behind the eye at the texel's farthest
// corner) hides nothing there.
unsafe function perspectiveSpan(at: usize, n: i32, fx: f32, rowQ: f32, qa: f32, slack: f32): void {
    const end = at + (<usize>n << 2);
    // (q > 0 at both ends: so it is between, q being computed monotonically
    // in x, and the loop needs no test of it)
    if (rowQ + qa * fx > 0 && rowQ + qa * (fx + <f32>(n - 1)) > 0) {
        for (; at < end; at += 4) {
            const d = slack / (rowQ + qa * fx);
            fx += 1;
            if (d < load<f32>(at)) store<f32>(at, d);
        }
        return;
    }
    for (; at < end; at += 4) {
        const q = rowQ + qa * fx;
        fx += 1;
        if (q > 0) {
            const d = slack / q;
            if (d < load<f32>(at)) store<f32>(at, d);
        }
    }
}

// perspectiveSpan's orthographic case: the depth is (rowQ + qa x) * slack.
unsafe function orthoSpan(at: usize, n: i32, fx: f32, rowQ: f32, qa: f32, slack: f32): void {
    const end = at + (<usize>n << 2);
    for (; at < end; at += 4) {
        const d = (rowQ + qa * fx) * slack;
        fx += 1;
        if (d < load<f32>(at)) store<f32>(at, d);
    }
}

// `n` texels of a level from `out` on, each the farthest of the two by
// two children from `c` on (a child row `below` bytes long).
unsafe function foldRow(c: usize, out: usize, n: i32, below: usize): void {
    const end = out + (<usize>n << 2);
    for (; out < end; out += 4) {
        const r = c + below;
        const a = maxDepth(load<f32>(c), load<f32>(c, 4));
        const b = maxDepth(load<f32>(r), load<f32>(r, 4));
        store<f32>(out, maxDepth(a, b));
        c += 8;
    }
}

// Sets the first `n` floats of `a` to +infinity: one written, then copied
// over the next ones in doubling runs (bulk copies, far cheaper than a
// store a texel where the run time interprets each instruction).
unsafe function fillInfinity(a: Float32Array, n: i32): void {
    if (n <= 0) return;
    const p = a.dataStart;
    store<f32>(p, f32.POSITIVE_INFINITY);
    const total = <usize>n << 2;
    let done: usize = 4;
    while (done < total) {
        const run = min<usize>(done, total - done);
        memory.copy(p + done, p, run);
        done += run;
    }
}

// Whether `a` is `b` within OCCLUSION_STILL_EPSILON of `b`'s largest number.
function sameMatrix(a: Mat4, b: Mat4): bool {
    const big = max<f32>(max<f32>(max<f32>(Mathf.abs(b.wAxis.x), Mathf.abs(b.wAxis.y)), max<f32>(Mathf.abs(b.wAxis.z), <f32>1)),
        max<f32>(Mathf.abs(b.wAxis.w), <f32>1));
    const e = OCCLUSION_STILL_EPSILON * big;
    return near4(a.xAxis, b.xAxis, e) && near4(a.yAxis, b.yAxis, e) && near4(a.zAxis, b.zAxis, e) && near4(a.wAxis, b.wAxis, e);
}

function near4(a: Vec4, b: Vec4, e: f32): bool {
    return Mathf.abs(a.x - b.x) <= e && Mathf.abs(a.y - b.y) <= e && Mathf.abs(a.z - b.z) <= e && Mathf.abs(a.w - b.w) <= e;
}

// The farther of two depths (+infinity, where nothing is, the farthest).
@inline
function maxDepth(a: f32, b: f32): f32 {
    // (one instruction; the same as a > b ? a : b, as no depth is NaN or
    // a signed zero)
    return max<f32>(a, b);
}

// prepare's setup job: the drawn occluders' triangles, SETUP_GRAIN of
// one occluder at most a unit (OcclusionBuffer.setupUnit). On lanes:
// packSetup writes the view and the occluders into words, which go to the
// lanes as one Blob; a lane (occlusionSetupLaneUnits) sets up each unit it
// claims with the same setupOccluder and gives back its triangles, which
// mergeLaneUnit keeps as the unit's share.
class SetupJob extends LaneJob {
    buffer: OcclusionBuffer? = null;
    frame: RenderFrame? = null;
    direct: bool = true;
    private words: ArrayBuffer = new ArrayBuffer(0);

    runUnit(unit: i32, begin: i32, end: i32, worker: i32): void {
        const b = this.buffer!;
        const f = this.frame!;
        for (let u = begin; u < end; u++) b.setupUnit(f, u, worker, this.direct);
    }

    laneKind(): i32 {
        return LANE_OCCLUSION_SETUP;
    }

    worthLanes(count: i32, grain: i32): bool {
        return this.buffer!.drawnTriangles(this.frame!) >= OCCLUSION_LANE_SETUP;
    }

    packLanes(count: i32, grain: i32, units: i32): i32 {
        const words = this.buffer!.setupWords(this.frame!);
        if (this.words.byteLength < words * 4) this.words = new ArrayBuffer(words * 4);
        this.buffer!.packSetup(this.frame!, this.words);
        return words * 4;
    }

    laneWords(): ArrayBuffer {
        return this.words;
    }

    mergeLaneUnit(unit: i32, r: LaneResult, at: i32): void {
        this.buffer!.takeSetupLane(unit, r, at);
    }
}

const setupJob = new SetupJob();

// The fewest triangles drawn for which they are set up on lanes.
export const OCCLUSION_LANE_SETUP: i32 = 1024;

// packSetup()'s words: the header (width, height, orthographic, near, the
// view's matrix, the projection's, the occluders, the units), each unit's
// three, then each occluder's (its world's matrix, closed, where its
// points start and how many words, where its indices start and how many).
const SP_HEADER = 40;
const SP_OCCLUDER = 21;

function putMat4(w: Float32Array, at: i32, m: Mat4): void {
    unchecked(w[at] = m.xAxis.x);
    unchecked(w[at + 1] = m.xAxis.y);
    unchecked(w[at + 2] = m.xAxis.z);
    unchecked(w[at + 3] = m.xAxis.w);
    unchecked(w[at + 4] = m.yAxis.x);
    unchecked(w[at + 5] = m.yAxis.y);
    unchecked(w[at + 6] = m.yAxis.z);
    unchecked(w[at + 7] = m.yAxis.w);
    unchecked(w[at + 8] = m.zAxis.x);
    unchecked(w[at + 9] = m.zAxis.y);
    unchecked(w[at + 10] = m.zAxis.z);
    unchecked(w[at + 11] = m.zAxis.w);
    unchecked(w[at + 12] = m.wAxis.x);
    unchecked(w[at + 13] = m.wAxis.y);
    unchecked(w[at + 14] = m.wAxis.z);
    unchecked(w[at + 15] = m.wAxis.w);
}

function getMat4(w: Float32Array, at: i32): Mat4 {
    return Mat4(
        Vec4(unchecked(w[at]), unchecked(w[at + 1]), unchecked(w[at + 2]), unchecked(w[at + 3])),
        Vec4(unchecked(w[at + 4]), unchecked(w[at + 5]), unchecked(w[at + 6]), unchecked(w[at + 7])),
        Vec4(unchecked(w[at + 8]), unchecked(w[at + 9]), unchecked(w[at + 10]), unchecked(w[at + 11])),
        Vec4(unchecked(w[at + 12]), unchecked(w[at + 13]), unchecked(w[at + 14]), unchecked(w[at + 15])),
    );
}

// `n` numbers of `src` from `from` into `dst` from `to`, at once.
function copyFloats(dst: Float32Array, to: i32, src: Float32Array, from: i32, n: i32): void {
    copyWords(dst, to, src, from, n);
}

unsafe function copyIntWords(dst: usize, src: usize, n: i32): void {
    memory.copy(dst, src, <usize>n << 2);
}

function copyInts(dst: Int32Array, to: i32, src: Int32Array, from: i32, n: i32): void {
    if (n > 0) copyIntWords(dst.dataStart + (<usize>to << 2), src.dataStart + (<usize>from << 2), n);
}

function copyUints(dst: Uint32Array, to: i32, src: Uint32Array, from: i32, n: i32): void {
    if (n > 0) copyIntWords(dst.dataStart + (<usize>to << 2), src.dataStart + (<usize>from << 2), n);
}

// The occluders' triangles set up on a lane (SetupJob, lanes.as): from
// what packSetup() wrote (`words`), every unit it can claim of the run's
// `units`, set up as setupUnit sets them up on the main lane.
export function occlusionSetupLaneUnits(words: ArrayBuffer, claims: UnitClaims, count: i32, grain: i32,
    units: i32): LaneResult {
    const b = new OcclusionBuffer();
    const occ = b.unpackSetup(words);
    const w = new LaneResultWriter(units);
    while (true) {
        const u = claims.next();
        if (u < 0) break;
        for (let v = unitBegin(u, grain); v < unitEnd(u, count, grain); v++) b.setupLaneUnit(occ, v, w);
    }
    return w.result();
}

// prepare's fill job: the buffer's tiles, a tile a unit, each filled by
// OcclusionBuffer.fillTile. On lanes (jobs.as LaneJob), which cannot read
// the buffer: packLanes writes the set-up triangles and their bins into
// words, once a prepare, which go to the lanes as one Blob; a lane
// (occlusionLaneUnits) fills each tile it claims from them with the same
// fillTri, and gives back the tile's texels and what it wrote of each
// occluder, which mergeLaneUnit puts in place.
class FillJob extends LaneJob {
    buffer: OcclusionBuffer? = null;
    // The lanes' input (kept from run to run).
    private words: ArrayBuffer = new ArrayBuffer(0);

    runUnit(unit: i32, begin: i32, end: i32, worker: i32): void {
        const b = this.buffer!;
        for (let t = begin; t < end; t++) b.fillTile(t);
    }

    laneKind(): i32 {
        return LANE_OCCLUSION;
    }

    worthLanes(count: i32, grain: i32): bool {
        return this.buffer!.binnedCount() >= OCCLUSION_LANE_BINNED;
    }

    packLanes(count: i32, grain: i32, units: i32): i32 {
        const words = this.buffer!.packedWords();
        if (this.words.byteLength < words * 4) this.words = new ArrayBuffer(words * 4);
        this.buffer!.pack(this.words);
        return words * 4;
    }

    laneWords(): ArrayBuffer {
        return this.words;
    }

    mergeLaneUnit(unit: i32, r: LaneResult, at: i32): void {
        this.buffer!.mergeTile(unit, r, at);
    }
}

const fillJob = new FillJob();

// The fewest (triangle, tile) pairs binned for which the tiles are filled
// on lanes: below it a lane's start and the copies cost more than the fill.
export const OCCLUSION_LANE_BINNED: i32 = 64;

// pack()'s words: a header (PK_*), then the triangles' floats, their
// occluders, the bins' starts and their items.
const PK_WIDTH = 0;
const PK_HEIGHT = 1;
const PK_ORTHO = 2;
const PK_DRAWN = 3;
const PK_TRIS = 4;
const PK_TILES_X = 5;
const PK_TILES_Y = 6;
const PK_ITEMS = 7;
const PK_BAND = 8;
const PK_HEADER = 9;

// `n` floats of `src` from `from` to `dst` from `to`, at once.
unsafe function copyWords(dst: Float32Array, to: i32, src: Float32Array, from: i32, n: i32): void {
    memory.copy(dst.dataStart + (<usize>to << 2), src.dataStart + (<usize>from << 2), <usize>n << 2);
}

// The occlusion buffer's tiles on a lane (FillJob, lanes.as): from what
// pack() wrote (`words`), every tile it can claim of the run's `units`,
// filled as fillTile fills them on the main lane; each claimed tile's
// texels (row by row) as floats, and what it wrote of each occluder as
// ints.
export function occlusionLaneUnits(words: ArrayBuffer, claims: UnitClaims, count: i32, grain: i32, units: i32): LaneResult {
    const b = new OcclusionBuffer();
    b.unpack(words);
    const n = b.drawnCount();
    const counts = new Int32Array(n);
    const w = new LaneResultWriter(units);
    while (true) {
        const u = claims.next();
        if (u < 0) break;
        for (let t = unitBegin(u, grain); t < unitEnd(u, count, grain); t++) {
            w.begin(t);
            const tw = b.tileWidth(t);
            const th = b.tileHeight(t);
            const at = w.reserveFloats(tw * th);
            const fl = w.floatArray();
            for (let i = 0; i < tw * th; i++) unchecked(fl[at + i] = f32.POSITIVE_INFINITY);
            for (let k = 0; k < n; k++) unchecked(counts[k] = 0);
            b.fillTileInto(t, laneBase(fl, at), b.tileRows(t) + 1, b.tileCols(t) + 1, tw, counts, 0);
            for (let k = 0; k < n; k++) w.addInt(unchecked(counts[k]));
        }
    }
    return w.result();
}

unsafe function laneBase(fl: Float32Array, at: i32): usize {
    return fl.dataStart + (<usize>at << 2);
}

// buildLevels' job with more than one worker: a level's rows, a band a unit.
class LevelJob extends Job {
    buffer: OcclusionBuffer? = null;
    level: i32 = 1;

    runUnit(unit: i32, begin: i32, end: i32, worker: i32): void {
        this.buffer!.foldLevel(this.level, begin, end);
    }
}

const levelJob = new LevelJob();

// The module's buffer, which cull.as prepares for each view it culls (one
// view at a time: nothing re-enters), and which the tools read after a
// cull.
export const frameOcclusion = new OcclusionBuffer();

// The buffer's level 0 as a greyscale picture of its own size: a depth of
// `near` or less white, `far` or more black, linear between; empty texels
// transparent (`render --occlusion-buffer`).
export function occlusionImage(b: OcclusionBuffer, near: f32, far: f32): Image {
    const w = max<i32>(b.width, 1);
    const h = max<i32>(b.height, 1);
    const data = new Uint8Array(w * h * 4);
    if (b.width <= 0 || b.height <= 0 || b.depth.length < (b.width + 2) * (b.height + 2)) return new Image(<u32>w, <u32>h, data);
    const span = far > near ? far - near : <f32>1;
    const dep = b.depth;
    // (the view's texels: the guard band is left out of the picture)
    for (let i = 0; i < w * h; i++) {
        const d = unchecked(dep[(i / w + 1) * (w + 2) + i % w + 1]);
        if (!isFinite(d)) continue;
        let t = (d - near) / span;
        if (!(t > 0)) t = 0;
        if (t > 1) t = 1;
        const g = <u8>Math.round(<f64>(<f32>255 * (<f32>1 - t)));
        unchecked(data[i * 4] = g);
        unchecked(data[i * 4 + 1] = g);
        unchecked(data[i * 4 + 2] = g);
        unchecked(data[i * 4 + 3] = 255);
    }
    return new Image(<u32>w, <u32>h, data);
}
