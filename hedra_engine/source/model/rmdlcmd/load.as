// Loading a model for a program other than Hedra: Hedra's library,
// CLI, editor and built projects. In order, for a file whose header is good:
//
// 1. the header alone: an empty scene;
// 2. a cache entry for the whole file (cache.as findCached, wholeOnly):
//    whatever the file holds, if Hedra opened it since it last changed;
// 3. the data form (data/mod.as): a file of data lines only replays here,
//    deterministically, through the shared model;
// 4. the caller's last look (`entry`, an EntryProbe): Hedra's packed
//    scenes carry the cache entry their load read, mounted where a listing
//    of the cache directory does not show it, so they look it up by name
//    (engine/src/source/scene/resource/model.as wholeCacheEntry);
// 5. milestone 22: the commands, replayed by the installed CommandReplayer
//    (engine/src/commands/replayer.as: Hedra's command kernel, which
//    Hedra's CLI and editor carry);
// 6. otherwise E_NEEDS_MODEL_COMMANDS at the first line that is not a data line,
//    with a hint naming the ways out: write the model it builds as an .rmdl
//    document, which loads without the kernel (the CLI's `model <file>
//    --to <file.rmdl>`), or build the project. The player of a
//    built project installs no replayer: it carries none of the kernel, and
//    the CLI's `build` packs a cache entry for every model it replayed
//    (editor/program/src/build/pack.as), so it never gets here.
//
// Hedra has its own loader (engine/src/commands/replay.as), which
// replays every command and writes the cache. A load here never writes.

import { Result } from "../../../base/util";
import { Scene } from "../scene";
import { vfs, isValidUtf8 } from "../../../fs/vfs";
import { RmdlError, E_NEEDS_MODEL_COMMANDS, E_SYNTAX } from "./format";
import { RmdlDoc } from "./doc";
import { firstWord, tokenizeLine } from "./lex";
import { CacheHit, cacheDirOf, findCached } from "./cache";
import { DataReplay } from "./data/mod";
import { CLI } from "../../../base/names";
import { rmdlPathFor } from "../formats";

// Where a loaded scene came from.
export enum RmdlSource {
    // The header alone: an empty scene.
    Empty,
    // A cache entry.
    Cache,
    // The data lines, replayed.
    Data,
    // The commands, replayed by the installed CommandReplayer (milestone 22).
    Replay,
}

export class RmdlLoad {
    scene: Scene = new Scene();
    doc: RmdlDoc = RmdlDoc.empty();
    source: RmdlSource = RmdlSource.Empty;
    // The cache entry read, for RmdlSource.Cache ("" otherwise): a packed
    // scene embeds what a load read.
    cachePath: string = "";
    // RmdlSource.Replay in an open world (CONTRACT.md §8.5) that read a file
    // the vfs did not know: the run, whose vfs.needs grew, is thrown away
    // and run again once the host has answered. When the cache's directory
    // or an entry was the unknown file the commands are not replayed at all
    // (the scene is empty): the entry may be there, and replaying first
    // would be work for nothing, for a long model most of the command's
    // time.
    deferred: bool = false;
}

// A caller's last look for a cache entry before the commands are replayed
// (step 4 above): null when it has none. Called only for a file of
// commands that findCached did not find whole.
export abstract class EntryProbe {
    abstract entry(doc: RmdlDoc, abs: string, display: string): CacheHit?;
}

// A program that carries Hedra's command kernel (engine/src/commands)
// replays a model of commands instead of failing with E_NEEDS_MODEL_COMMANDS: it
// installs a CommandReplayer (engine/src/commands/replayer.as
// installKernelReplayer), which this module cannot import (shared/src/model
// is below the kernel). A program that does not, the player of a built
// project among them, carries none of the kernel and keeps step 6.
export abstract class CommandReplayer {
    // The scene `doc` (read from `abs`; `display` names it in errors)
    // builds, replayed in full: data lines, then commands. Never writes.
    // Fails with an RmdlError (format.as): E_REPLAY, E_COMMAND_NOT_ALLOWED,
    // E_DATA, E_DATA_MISPLACED, E_SYNTAX.
    abstract replay(doc: RmdlDoc, abs: string, display: string): Result<Scene>;

    // Around the load of a model that adds a tool modifier, in commands or
    // in data lines (scan.as namesToolModifier), up to its scene's
    // conversion, which
    // evaluates the modifier stacks: the kernel installs the model's own
    // tools, `tools/` beside it (engine/src/commands/tools.as ModelTools),
    // and puts back the set before on leave. A replayer of no tools does
    // nothing.
    enterTools(abs: string): void {}
    leaveTools(): void {}
}

// The installed replayer's enterTools and leaveTools, or nothing when
// none is installed (the player: a data-form model's tool modifier is then
// left out, with the warning engine/src/source/model/modifiers/mod.as gives, which
// the conversion passes on as one of the model's: Scene.stackWarnings and
// engine/src/source/scene/resource/model.as modelFromScene).
export function enterModelTools(abs: string): void {
    const r = replayerCell;
    if (r != null) r.enterTools(abs);
}

export function leaveModelTools(): void {
    const r = replayerCell;
    if (r != null) r.leaveTools();
}

let replayerCell: CommandReplayer? = null;

// Installs the replayer (null: none: model-needs-commands, as before
// milestone 22).
export function installCommandReplayer(r: CommandReplayer?): void {
    replayerCell = r;
}

// The installed replayer, or null.
export function commandReplayer(): CommandReplayer? {
    return replayerCell;
}

// Reads `abs` through the vfs and loads it as above. `display` is how errors
// name the file. Fails with an RmdlError (format.as): E_HEADER,
// E_FORMAT_NEWER, E_SYNTAX, E_DATA, E_DATA_MISPLACED, E_NEEDS_MODEL_COMMANDS, the
// replayer's (E_REPLAY, E_COMMAND_NOT_ALLOWED), or the vfs's error when the
// file cannot be read (its IoError the cause, so a caller can tell a
// missing model from the rest). Never writes: the cache is Hedra's to
// write.
export function loadRmdl(abs: string, display: string, entry: EntryProbe? = null): Result<RmdlLoad> {
    const r = vfs.read(abs);
    if (!r.ok) return r.forward<RmdlLoad>();
    return loadRmdlBytes(abs, display, r.value, entry);
}

// The same from bytes already read (a prefetcher, a test).
export function loadRmdlBytes(abs: string, display: string, bytes: Uint8Array, entry: EntryProbe? = null): Result<RmdlLoad> {
    if (!isValidUtf8(bytes)) {
        return new RmdlError(E_SYNTAX, display, 0, "the file is not UTF-8 text", "an .rmdlcmd is UTF-8 text, one command a line").fail<RmdlLoad>();
    }
    const text = String.UTF8.decodeUnsafe(bytes.dataStart, <usize>bytes.length);
    const parsed = RmdlDoc.parse(text, display);
    if (!parsed.ok) return parsed.forward<RmdlLoad>();
    const doc = parsed.value;
    const misplaced = doc.checkDataPlacement(display);
    if (misplaced != null) return misplaced.fail<RmdlLoad>();
    const out = new RmdlLoad();
    out.doc = doc;
    if (doc.entryCount() == 0) {
        out.source = RmdlSource.Empty;
        out.scene = new Scene();
        return Result.okv<RmdlLoad>(out);
    }
    const needs = vfs.needs.length;
    const hit = findCached(doc, abs, true);
    if (hit == null && !doc.isDataOnly() && replayerCell != null) {
        // The directories above the cache's, which Hedra's replay states
        // for the cache its save may write (engine/src/commands/
        // replay.as loadDocScene): asked with the listing, so that a run
        // that puts the replay off learns them in the same round, and the
        // next run replays once rather than in a run thrown away for them.
        const cache = parentDir(cacheDirOf(abs));
        vfs.exists(cache);
        vfs.exists(parentDir(cache));
    }
    if (hit != null) return cached(out, hit);
    if (doc.isDataOnly()) {
        const done = dataFormScene(doc, display);
        if (!done.ok) return done.forward<RmdlLoad>();
        out.source = RmdlSource.Data;
        out.scene = done.value;
        return Result.okv<RmdlLoad>(out);
    }
    if (entry != null) {
        const probed = entry.entry(doc, abs, display);
        if (probed != null) return cached(out, probed);
    }
    const replayer = replayerCell;
    if (replayer == null) return needsModeler(doc, display).fail<RmdlLoad>();
    out.source = RmdlSource.Replay;
    if (vfs.needs.length > needs) {
        // The cache's directory or an entry is not known yet: see deferred.
        out.deferred = true;
        out.scene = new Scene();
        return Result.okv<RmdlLoad>(out);
    }
    const r = replayer.replay(doc, abs, display);
    if (!r.ok) return r.forward<RmdlLoad>();
    out.scene = r.value;
    // (the replayer may put its own lookup off the same way: an empty scene
    // and needs that grew)
    out.deferred = vfs.needs.length > needs;
    return Result.okv<RmdlLoad>(out);
}

function parentDir(p: string): string {
    const i = p.lastIndexOf("/");
    return i <= 0 ? "/" : p.substring(0, i);
}

function cached(out: RmdlLoad, hit: CacheHit): Result<RmdlLoad> {
    out.source = RmdlSource.Cache;
    out.scene = hit.scene;
    out.cachePath = hit.path;
    return Result.okv<RmdlLoad>(out);
}

// The scene a doc of data lines only builds (doc.isDataOnly()), with no
// cache and no file system: for a loader that holds the bytes alone (a
// GPU test harness's blob). Fails with E_DATA at the line at fault.
export function dataFormScene(doc: RmdlDoc, display: string): Result<Scene> {
    const replay = new DataReplay(display);
    for (let i = 0; i < doc.entries.length; i++) {
        const e = doc.entries[i];
        const a = replay.apply(e.commands[0], e.lines[0]);
        if (!a.ok) return a.forward<Scene>();
    }
    return replay.finish();
}

// The error for a doc with commands this program cannot replay: at the first
// command line that is not a data line, unless a command line does not
// even tokenize (an unterminated quote), which is the file's own error and
// the one to fix first.
function needsModeler(doc: RmdlDoc, display: string): RmdlError {
    for (let i = doc.dataEntries(); i < doc.entries.length; i++) {
        const e = doc.entries[i];
        for (let k = 0; k < e.commands.length; k++) {
            const t = tokenizeLine(e.commands[k]);
            if (!t.ok) {
                return new RmdlError(E_SYNTAX, display, e.lines[k], t.err,
                    "close the quote; a command is one line (write a line feed in a quoted token as \\n)");
            }
        }
    }
    const first = doc.entries[doc.dataEntries()];
    const line = first.lines[0];
    // The commands in the hint run in a shell, where the editor's `res://`
    // means nothing: the path relative to the project is what to type.
    const p = display.startsWith("res://") ? display.substring(6) : display;
    return new RmdlError(E_NEEDS_MODEL_COMMANDS, display, line,
        display + " holds model commands this program cannot replay (line " + line.toString() + ": " + firstWord(first.commands[0]) + ")",
        "write the model as a document, which loads without them: `" + CLI + " model " + p + " --to " + rmdlPathFor(p)
        + "`, or build the project");
}
