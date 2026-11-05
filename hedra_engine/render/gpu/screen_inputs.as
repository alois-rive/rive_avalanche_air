// Milestone 62: what the renderer (./renderer.as) hands the screen-space
// effects' passes of one view (./ssr.as GpuSsr, ./dof.as GpuDof): the
// view's slot, its render size and samples, and the views of the targets
// its earlier passes drew. One object, kept by the renderer and filled in
// place for each view, so that handing it over allocates nothing.

import { GPUTextureView } from "rive/gpu";

export class ScreenInputs {
    // The view's uniform slot (ViewBuffers.customId: unique to the slot
    // for the renderer's life), by which a pass keeps the buffers and
    // targets of each view apart (a buffer a recorded pass reads is never
    // rewritten in the same frame: renderer.as's header).
    slot: i32 = 0;
    // The render size (the frame's size times its SSAA factor).
    pxW: u32 = 1;
    pxH: u32 = 1;
    // The main pass's MSAA count (Pipelines.samples): what a pipeline drawn
    // inside the main pass's second half (GpuSsr.merge) is made for.
    samples: u32 = 1;
    // Whether the reflections' merge is drawn in a pass of its own over the
    // first half's resolve (GpuSsr.mergeOver: one sample, no depth), the
    // second half having nothing else to draw, rather than inside it.
    mergeAlone: bool = false;
    // The normal-depth pass's two targets (render size, one sample):
    // NORMAL_DEPTH_FORMAT (view-space normal, view depth; 0 where nothing
    // is drawn) and SSR_SURFACE_FORMAT (F0, roughness). null before the
    // pass runs (a plan without `prepass`).
    normalDepth: GPUTextureView? = null;
    surface: GPUTextureView? = null;
    // The screen texture with all its mips (SCREEN_FORMAT, render size at
    // level 0), and how many: null and 0 without the plan's `split`.
    screen: GPUTextureView? = null;
    screenLevels: i32 = 0;
    // The resolved HDR colour once the main pass is done (COLOR_FORMAT,
    // render size, one sample): the depth of field's source.
    colour: GPUTextureView? = null;

    // Every view null, the sizes 1, the counts 0 (before a view fills it).
    clear(): void {
        this.slot = 0;
        this.pxW = 1;
        this.pxH = 1;
        this.samples = 1;
        this.mergeAlone = false;
        this.normalDepth = null;
        this.surface = null;
        this.screen = null;
        this.screenLevels = 0;
        this.colour = null;
    }
}
