// The scene envelope. `HEDRAMDL` magic, the u32 little-endian schema
// version, then the postcard-encoded Scene. It is no model file any more
// (a model's file is an .rmdl, its document, or an .rmdlcmd, its commands:
// formats.as): it holds the scene of a replay cache entry
// (rmdlcmd/cache.as), of an undo ring's snapshot (the authoring tier's
// model_project/undo.as) and of a packed scene's model, which the same build
// writes and reads, so only this build's schema is read; an entry of
// another schema is a cache miss (its key names the schema too).
//
// File access goes through the app's `vfs` (engine/src/fs/vfs.as): rive-cli
// scripts have no file system of their own.


import { Result } from "../../base/util";
import { CoreError } from "../../base/error";
import { Scene } from "./scene";
import { PostcardReader } from "./io/postcard";
import { encodeSceneBody, readScene } from "./io/codec";
import { vfs, ioErrorOf, IoErrorKind } from "../../fs/vfs";
import { extension, withExtension } from "../../fs/path";

// b"HEDRAMDL"
export function magic(): Uint8Array {
    const m = new Uint8Array(8);
    const s = "HEDRAMDL";
    for (let i = 0; i < 8; i++) m[i] = <u8>s.charCodeAt(i);
    return m;
}

export const MAGIC_LEN: i32 = 8;

// The schema this build writes, and the one it reads: 2, which ends a
// scene with the files it names besides its textures (a material that is
// a MaterialX file, an empty that instances a model: io/codec.as
// writeFileRefs). Schema 1's bodies are schema 2's without that tail, but
// a build of schema 1 would read a body that has one as though it had
// none, so the word moved: such a build refuses the file instead.
export const SCHEMA_VERSION: u32 = 2;

// Magic + version + postcard(scene).
export function encode(scene: Scene): Result<Uint8Array> {
    const body = encodeSceneBody(scene);
    const out = new Uint8Array(MAGIC_LEN + 4 + body.length);
    out.set(magic(), 0);
    const v = SCHEMA_VERSION;
    out[8] = <u8>v;
    out[9] = <u8>(v >> 8);
    out[10] = <u8>(v >> 16);
    out[11] = <u8>(v >> 24);
    out.set(body, MAGIC_LEN + 4);
    return Result.okv<Uint8Array>(out);
}

// The schema version word of a file (bytes 8..12, little endian); the
// caller checks the length.
export function versionOf(bytes: Uint8Array): u32 {
    return <u32>bytes[8] | (<u32>bytes[9] << 8) | (<u32>bytes[10] << 16) | (<u32>bytes[11] << 24);
}

export function decode(bytes: Uint8Array, what: string): Result<Scene> {
    let good = bytes.length >= MAGIC_LEN + 4;
    if (good) {
        const m = magic();
        for (let i = 0; i < MAGIC_LEN; i++) {
            if (bytes[i] != m[i]) {
                good = false;
                break;
            }
        }
    }
    if (!good) return CoreError.badMagic(what).fail<Scene>();
    const version = versionOf(bytes);
    if (version != SCHEMA_VERSION) return CoreError.badVersion(version, SCHEMA_VERSION).fail<Scene>();
    const r = new PostcardReader(bytes.subarray(MAGIC_LEN + 4));
    const scene = readScene(r);
    if (r.failed) return CoreError.serialize(what + ": " + r.errorText()).fail<Scene>();
    scene.afterLoad();
    return Result.okv<Scene>(scene);
}

export function save(scene: Scene, path: string): Result<bool> {
    const bytes = encode(scene);
    if (!bytes.ok) return bytes.forward<bool>();
    return writeAtomic(path, bytes.value);
}

export function load(path: string): Result<Scene> {
    const r = vfs.read(path);
    if (!r.ok) {
        const e = ioErrorOf<Uint8Array>(r);
        if (e != null && e.kind == IoErrorKind.NotFound) return CoreError.projectMissing(path).fail<Scene>();
        return CoreError.io(path, r.err).fail<Scene>();
    }
    return decode(r.value, path);
}

// Write via a sibling temp file and rename so a crash never truncates the
// project.
export function writeAtomic(path: string, bytes: Uint8Array): Result<bool> {
    const ext = extension(path);
    const tmp = withExtension(path, (ext != null ? ext : "bin") + ".tmp");
    const w = vfs.write(tmp, bytes);
    if (!w.ok) return CoreError.io(tmp, w.err).fail<bool>();
    const m = vfs.rename(tmp, path);
    if (!m.ok) return CoreError.io(path, m.err).fail<bool>();
    return Result.okv<bool>(true);
}
