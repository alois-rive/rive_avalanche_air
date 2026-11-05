// The ViewportTexture resource (milestone 34, Godot's ViewportTexture):
// the one place its rules are written, so that the sub_resource builder
// (build.as), the viewport graph (../tree/viewports.as), the warnings, the
// renderer's binding and the CLI agree. The format is docs/formats/
// RSCN.md's "SubViewport".
//
// The rules:
// - Its `path` is viewportTexturePath(declaring file, sub_resource id): no
//   file, the identity the renderer binds the viewport's picture under
//   (MaterialBinder.setLive), as an ArtboardTexture's is. Two textures of
//   one SubViewport are two paths, both bound to the one picture.
// - Its `image`, what a slot samples until the viewport has drawn, is
//   VIEWPORT_TEXTURE_BLANK: one transparent black texel, as Godot's
//   viewport texture is before its first frame.
// - Its `width` and `height` are DEFAULT_VIEWPORT_SIDE until the tree is
//   planned, then its SubViewport's size (../tree/viewports.as
//   resolveViewportTextures).
// - `viewport_path` is a node path from the root of the scene that
//   declares the texture (Godot's resource local to its scene): the
//   graph resolves it in the first instance of that scene in tree order.
//   Problems are warnings (viewport-texture-path, -missing,
//   -not-subviewport, -shared, -extension: ../../source/project/
//   warnings.as viewportDiagnostics), so a scene with a misspelt path
//   renders (its slots draw the blank texel).

import { Image, Rgba } from "../../render/image";
import { DEFAULT_VIEWPORT_SIDE } from "../../render/viewport";
import { VIEWPORT_TEXTURE_MARK, ViewportTexture } from "./types";

// Where every viewport problem's hint sends a reader.
export const VIEWPORT_DOC = "docs/formats/RSCN.md \"Viewports\"";

// What a ViewportTexture's slots sample before its viewport first drew.
export const VIEWPORT_TEXTURE_BLANK: Image = Image.new(1, 1, Rgba(0, 0, 0, 0));

// The `path` of a ViewportTexture declared in the file at `declaringAbs`
// (an absolute path) with sub_resource id `id`.
export function viewportTexturePath(declaringAbs: string, id: string): string {
    return declaringAbs + VIEWPORT_TEXTURE_MARK + id;
}

// Whether a texture path is a ViewportTexture's (viewportTexturePath).
export function isViewportTexturePath(path: string): bool {
    return path.includes(VIEWPORT_TEXTURE_MARK);
}

// Finishes a texture whose fields are set (build.as after its
// properties): its path, its first size and its blank image.
export function finishViewportTexture(t: ViewportTexture, declaringAbs: string, id: string): void {
    t.path = viewportTexturePath(declaringAbs, id);
    t.width = DEFAULT_VIEWPORT_SIDE;
    t.height = DEFAULT_VIEWPORT_SIDE;
    t.image = VIEWPORT_TEXTURE_BLANK;
}

// The sub_resource id `t` was declared with: what follows
// VIEWPORT_TEXTURE_MARK in its path; "" for a texture not finished.
export function viewportTextureKey(t: ViewportTexture): string {
    const at = t.path.lastIndexOf(VIEWPORT_TEXTURE_MARK);
    return at < 0 ? "" : t.path.substring(at + VIEWPORT_TEXTURE_MARK.length);
}

// The absolute path of the file that declared `t`; "" for a texture not
// finished.
export function viewportTextureDeclarer(t: ViewportTexture): string {
    const at = t.path.lastIndexOf(VIEWPORT_TEXTURE_MARK);
    return at < 0 ? "" : t.path.substring(0, at);
}
