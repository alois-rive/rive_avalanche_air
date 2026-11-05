// Reads a shader file's declarations (./program.as has the format): Godot's
// `shader_type`, `render_mode`, `group_uniforms` and `uniform` statements at
// the top level, which no WGSL compiler reads (the composer blanks them),
// the stage functions' signatures, and what the code uses. The code itself
// is WGSL, and rive compiles it (hedra_compiler/shader/compose.as splices
// it into the template first): this reader checks only what the composer
// and the GPU side rely on, so that a file that passes here and fails there
// fails with rive's own message, mapped back to the user's line and column.
//
// What it reports (ShaderDiagnostic codes, RSCN.md's table): a file that
// does not start with `shader_type spatial;` (shader-syntax, or
// shader-type-unsupported for Godot's other types), a render mode Godot has
// not (shader-render-mode-unknown) or Hedra does not draw (a warning,
// shader-render-mode-unsupported), two of one family
// (shader-render-mode-conflict), a uniform's type, hint or default it
// cannot take (shader-uniform-type-unsupported, -hint-unknown,
// -hint-unsupported, -hint-type, -default), a uniform declared twice
// (shader-uniform-duplicate) or a name that hides one
// (shader-uniform-shadowed: the composer rewrites every use of a uniform's
// name), too many uniforms, textures or bytes (shader-too-many-uniforms,
// shader-too-many-textures, shader-block-too-large), a top-level name that
// is the composer's or a built-in's (shader-name-reserved), a name GLSL
// would refuse once rive translates the code for WebGL 2
// (shader-name-glsl: `gl`, a `gl_` prefix, a `__` anywhere), a stage
// function with parameters or a result (shader-stage-signature), a
// built-in Hedra does not give (shader-builtin-unsupported) or one of
// another stage in a stage function (shader-builtin-stage), and a block
// comment never closed or a character WGSL does not read (shader-syntax).
// It never fails: a program with an error is drawn with the fallback
// material and never composed.

import {
    BLEND_ADD, BLEND_MIX, BLEND_MUL, BLEND_PREMUL_ALPHA, BLEND_SUB, BUILTINS_FRAGMENT, BUILTINS_GLOBAL,
    BUILTINS_LIGHT, BUILTINS_UNSUPPORTED, BUILTINS_VERTEX, CULL_BACK, CULL_DISABLED, CULL_FRONT,
    DEPTH_DRAW_ALWAYS, DEPTH_DRAW_NEVER, DEPTH_DRAW_OPAQUE, DIFFUSE_BURLEY, DIFFUSE_LAMBERT, DIFFUSE_LAMBERT_WRAP,
    DIFFUSE_TOON, FILTER_NAMES, HINTS_UNSUPPORTED, HINT_DEFAULT_BLACK, HINT_DEFAULT_TRANSPARENT,
    HINT_DEFAULT_WHITE, HINT_NORMAL, HINT_RANGE, HINT_SOURCE_COLOR, MAX_PARAM_BLOCK_BYTES, MAX_SHADER_SLOTS,
    MAX_SHADER_TEXTURES, MAX_SHADER_UNIFORMS, MAX_SHADER_VARYINGS, RENDER_MODES, RENDER_MODES_DRAWN, RESERVED_PREFIX, SHADER_ERROR,
    SHADER_WARNING, SPECULAR_DISABLED, SPECULAR_SCHLICK_GGX, SPECULAR_TOON, ShaderDiagnostic, ShaderProgram,
    ShaderUniform, ShaderVarying, UniformType, shaderKey, uniformComponents,
} from "./program";
import { layoutUniforms, slotCount } from "./layout";
import { TOK_IDENT, TOK_NUMBER, TOK_OTHER, TOK_PUNCT, WgslTokens, tokenizeWgsl } from "./lex";

// Where the docs explain the format (each hint names it).
export const SHADERS_DOC = "docs/engine/SHADERS.md";

// Godot's other shader types (shader-type-unsupported rather than a typo).
const OTHER_TYPES: StaticArray<string> = ["canvas_item", "particles", "sky", "fog"];

class Reader {
    p: ShaderProgram;
    t: WgslTokens;
    i: i32 = 0;
    // Per token: inside a declaration statement the composer blanks.
    directive: Array<bool> = [];
    group: string = "";
    subgroup: string = "";
    // The render mode families already set (blend, depth_draw, cull,
    // diffuse, specular), each its token for the conflict's message.
    families: Map<string, string> = new Map<string, string>();
    // [open, close] of each stage function's body (token indices), and
    // which stage (0 vertex, 1 fragment, 2 light).
    bodies: Array<i32> = [];
    stages: Array<i32> = [];
    // The file ends inside its `shader_type` statement (reported there, not
    // again as a file without one).
    cutShaderType: bool = false;

    constructor(p: ShaderProgram, t: WgslTokens) {
        this.p = p;
        this.t = t;
        for (let k = 0; k < t.count; k++) this.directive.push(false);
    }

    error(code: string, k: i32, message: string, hint: string): void {
        const line = k >= 0 && k < this.t.count ? this.t.lines[k] : (this.t.count > 0 ? this.t.lines[this.t.count - 1] : 1);
        const col = k >= 0 && k < this.t.count ? this.t.cols[k] : 1;
        this.p.diagnostics.push(new ShaderDiagnostic(SHADER_ERROR, code, message, hint, line, col));
    }

    warn(code: string, k: i32, message: string, hint: string): void {
        const line = k >= 0 && k < this.t.count ? this.t.lines[k] : (this.t.count > 0 ? this.t.lines[this.t.count - 1] : 1);
        const col = k >= 0 && k < this.t.count ? this.t.cols[k] : 1;
        this.p.diagnostics.push(new ShaderDiagnostic(SHADER_WARNING, code, message, hint, line, col));
    }

    get done(): bool {
        return this.i >= this.t.count;
    }

    // Whether the statement at the reader's index runs to the end of the
    // file without its `;` (or its closing `}`): a file saved halfway
    // through a line, which live reload reads as often as a whole one. The
    // index is left where it was.
    truncated(): bool {
        const at = this.i;
        const ended = this.skipStatement();
        this.i = at;
        return !ended;
    }

    // An error just after the file's last word (where the missing rest of a
    // statement would go).
    errorAtEnd(code: string, message: string, hint: string): void {
        const n = this.t.count;
        const line = n > 0 ? this.t.lines[n - 1] : 1;
        const col = n > 0 ? this.t.cols[n - 1] + this.t.ends[n - 1] - this.t.starts[n - 1] : 1;
        this.p.diagnostics.push(new ShaderDiagnostic(SHADER_ERROR, code, message, hint, line, col));
    }

    // Marks tokens [from, to) as a declaration's.
    mark(from: i32, to: i32): void {
        for (let k = from; k < to && k < this.t.count; k++) this.directive[k] = true;
    }

    // Skips to just after the `;` that ends the statement at depth 0 (or the
    // end of the file); the index after it. False when the file ended first.
    skipStatement(): bool {
        let depth = 0;
        while (!this.done) {
            const k = this.i;
            this.i++;
            if (this.t.is(k, "(") || this.t.is(k, "[") || this.t.is(k, "{")) depth++;
            else if (this.t.is(k, ")") || this.t.is(k, "]")) depth--;
            else if (this.t.is(k, "}")) {
                depth--;
                if (depth <= 0) {
                    if (this.t.is(this.i, ";")) this.i++;
                    return true;
                }
            } else if (depth <= 0 && this.t.is(k, ";")) return true;
        }
        return false;
    }
}

// The program of `text`, the file `display` (as errors name it).
export function parseShader(text: string, display: string): ShaderProgram {
    const p = new ShaderProgram();
    p.path = display;
    p.text = text;
    p.key = shaderKey(text);
    const t = tokenizeWgsl(text);
    const r = new Reader(p, t);
    if (t.openCommentLine > 0) {
        p.diagnostics.push(new ShaderDiagnostic(SHADER_ERROR, "shader-syntax", "a block comment is never closed",
            "close it with */", t.openCommentLine, t.openCommentCol));
    }
    for (let k = 0; k < t.count; k++) {
        if (t.kindAt(k) == TOK_OTHER) {
            r.error("shader-syntax", k, "\"" + t.word(k) + "\" is not a character of WGSL outside a comment",
                "WGSL code is ASCII here; keep other characters in comments");
        }
    }
    topLevel(r);
    if (p.shaderType.length == 0 && !r.cutShaderType && !hasCode(p, "shader-type-unsupported")) {
        p.diagnostics.unshift(new ShaderDiagnostic(SHADER_ERROR, "shader-syntax",
            "a shader file starts with `shader_type spatial;`", "add `shader_type spatial;` as its first line (" + SHADERS_DOC + ")",
            1, 1));
    }
    scanWords(r);
    scanStages(r);
    layoutUniforms(p);
    limits(r);
    return p;
}

// Which tokens of `t` (a shader file's words) are inside a declaration
// statement (`shader_type`, `render_mode`, `group_uniforms`, `uniform`,
// `varying`, `global|instance uniform`, each to its `;`): the words the
// composer (hedra_compiler/shader/compose.as) blanks, marked by the same
// walk parseShader makes, so the two never disagree.
export function declarationTokens(t: WgslTokens): Array<bool> {
    const r = new Reader(new ShaderProgram(), t);
    topLevel(r);
    return r.directive;
}

function hasCode(p: ShaderProgram, code: string): bool {
    for (let i = 0; i < p.diagnostics.length; i++) if (p.diagnostics[i].code == code) return true;
    return false;
}

function topLevel(r: Reader): void {
    const t = r.t;
    let first = true;
    while (!r.done) {
        const k = r.i;
        if (r.truncated()) {
            // Read no further: each declaration's reader would report the
            // missing words as a wrong type, hint or default instead.
            if (t.is(k, "shader_type")) r.cutShaderType = true;
            const open = unclosedBracket(t, k);
            if (open >= 0) {
                // (a bracket closed by another kind: the file is whole, one
                // `(` or `[` was left open, and the statement swallowed the
                // rest of it; said there, not at the file's end)
                const close = CLOSERS[OPENERS.indexOf(t.word(open))];
                const at = unclosedBracketCloser(t, k);
                r.error("shader-syntax", open, "this `" + t.word(open) + "` is never closed",
                    "close it with `" + close + "` before the `" + t.word(at) + "` at " + t.lines[at].toString() + ":"
                        + t.cols[at].toString());
            } else {
                r.errorAtEnd("shader-syntax", "the file ends partway through `" + t.word(k) + "`",
                    "finish the statement with `;`" + (t.is(k, "fn") ? ", or close the function's body with `}`" : ""));
            }
            r.mark(k, t.count);
            r.i = t.count;
            break;
        }
        if (t.is(k, "shader_type")) {
            shaderType(r, first);
        } else if (t.is(k, "render_mode")) {
            renderModes(r);
        } else if (t.is(k, "group_uniforms")) {
            groupUniforms(r);
        } else if (t.is(k, "uniform")) {
            uniform(r);
        } else if (t.is(k, "varying")) {
            varying(r);
        } else if ((t.is(k, "global") || t.is(k, "instance")) && t.is(k + 1, "uniform")) {
            r.error("shader-uniform-hint-unsupported", k, "a " + t.word(k) + " uniform is not in the format",
                "declare it as a material's uniform (`uniform name: type;`): Hedra has no global or per-instance uniforms");
            r.skipStatement();
            r.mark(k, r.i);
        } else if (t.is(k, "fn")) {
            fnDecl(r);
        } else if (t.is(k, "@") && (t.is(k + 1, "group") || t.is(k + 1, "binding") || t.is(k + 1, "vertex")
            || t.is(k + 1, "fragment") || t.is(k + 1, "compute"))) {
            r.error("shader-syntax", k, "a shader declares no entry point and no binding of its own",
                "define fn vertex(), fn fragment() and fn light(), and declare textures as uniforms ("
                    + SHADERS_DOC + "); the engine's template has the entry points and the bindings");
            r.skipStatement();
        } else {
            declName(r, k);
            r.skipStatement();
        }
        first = false;
    }
}

const OPENERS: StaticArray<string> = ["(", "[", "{"];
const CLOSERS: StaticArray<string> = [")", "]", "}"];

// The first closing bracket from token `from` on that closes another kind
// than the bracket open innermost (the `}` of `return (x * 2.0; }`), or -1
// when every one matches (a file that only stops early).
function unclosedBracketCloser(t: WgslTokens, from: i32): i32 {
    const stack = new Array<i32>();
    for (let k = from; k < t.count; k++) {
        if (t.kindAt(k) != TOK_PUNCT) continue;
        const w = t.word(k);
        if (OPENERS.includes(w)) {
            stack.push(OPENERS.indexOf(w));
            continue;
        }
        const c = CLOSERS.indexOf(w);
        if (c < 0 || stack.length == 0) continue;
        if (stack[stack.length - 1] != c) return k;
        stack.pop();
    }
    return -1;
}

// The bracket left open that unclosedBracketCloser's closer meets (its
// token), or -1.
function unclosedBracket(t: WgslTokens, from: i32): i32 {
    const at = unclosedBracketCloser(t, from);
    if (at < 0) return -1;
    const stack = new Array<i32>();
    for (let k = from; k < at; k++) {
        if (t.kindAt(k) != TOK_PUNCT) continue;
        const w = t.word(k);
        if (OPENERS.includes(w)) stack.push(k);
        else if (CLOSERS.includes(w) && stack.length > 0) stack.pop();
    }
    return stack.length > 0 ? stack[stack.length - 1] : -1;
}

function shaderType(r: Reader, first: bool): void {
    const t = r.t;
    const k = r.i;
    r.skipStatement();
    r.mark(k, r.i);
    if (!first) {
        r.error("shader-syntax", k, "`shader_type` comes first in a shader file", "move it to the first line");
    }
    if (!(t.kindAt(k + 1) == TOK_IDENT) || !t.is(k + 2, ";")) {
        r.error("shader-syntax", k, "`shader_type` takes one word and a `;`", "write `shader_type spatial;`");
        return;
    }
    const w = t.word(k + 1);
    if (w == "spatial") {
        r.p.shaderType = w;
        return;
    }
    if (OTHER_TYPES.includes(w)) {
        r.error("shader-type-unsupported", k + 1, "a " + w + " shader is not in the format",
            "Hedra draws spatial shaders, a surface's material (" + SHADERS_DOC + ")");
    } else {
        r.error("shader-syntax", k + 1, "\"" + w + "\" is no shader type", "write `shader_type spatial;`");
    }
}

// The family a render mode belongs to, and its value there; "" for a mode
// of its own.
function familyOf(mode: string): string {
    if (mode.startsWith("blend_")) return "blend";
    if (mode.startsWith("depth_draw_")) return "depth_draw";
    if (mode.startsWith("cull_")) return "cull";
    if (mode.startsWith("diffuse_")) return "diffuse";
    if (mode.startsWith("specular_")) return "specular";
    return "";
}

function renderModes(r: Reader): void {
    const t = r.t;
    const start = r.i;
    r.skipStatement();
    const end = r.i;
    r.mark(start, end);
    let k = start + 1;
    while (k < end) {
        if (t.is(k, ",") || t.is(k, ";")) {
            k++;
            continue;
        }
        if (t.kindAt(k) != TOK_IDENT) {
            r.error("shader-syntax", k, "`render_mode` lists render modes, separated by commas",
                "write `render_mode unshaded, cull_disabled;`");
            k++;
            continue;
        }
        const m = t.word(k);
        const at = RENDER_MODES.indexOf(m);
        if (at < 0) {
            r.error("shader-render-mode-unknown", k, "\"" + m + "\" is no render mode of a spatial shader",
                "the render modes are Godot's (" + SHADERS_DOC + ", \"Render modes\")");
            k++;
            continue;
        }
        if (r.p.renderModes.includes(m)) {
            k++;
            continue;
        }
        const fam = familyOf(m);
        if (fam.length > 0) {
            if (r.families.has(fam)) {
                r.error("shader-render-mode-conflict", k, "\"" + m + "\" and \"" + r.families.get(fam) + "\" are both "
                    + fam + " modes", "keep one of them");
                k++;
                continue;
            }
            r.families.set(fam, m);
        }
        r.p.renderModes.push(m);
        if (RENDER_MODES_DRAWN[at] == 0) {
            r.warn("shader-render-mode-unsupported", k, "the render mode " + m + " is not drawn by Hedra: ignored",
                "see " + SHADERS_DOC + ", \"Render modes\"");
        }
        applyMode(r.p, m);
        k++;
    }
}

function applyMode(p: ShaderProgram, m: string): void {
    if (m == "blend_mix") p.blend = BLEND_MIX;
    else if (m == "blend_add") p.blend = BLEND_ADD;
    else if (m == "blend_sub") p.blend = BLEND_SUB;
    else if (m == "blend_mul") p.blend = BLEND_MUL;
    else if (m == "blend_premul_alpha") p.blend = BLEND_PREMUL_ALPHA;
    else if (m == "depth_draw_opaque") p.depthDraw = DEPTH_DRAW_OPAQUE;
    else if (m == "depth_draw_always") p.depthDraw = DEPTH_DRAW_ALWAYS;
    else if (m == "depth_draw_never") p.depthDraw = DEPTH_DRAW_NEVER;
    else if (m == "depth_test_disabled") p.depthTest = false;
    else if (m == "cull_back") p.cull = CULL_BACK;
    else if (m == "cull_front") p.cull = CULL_FRONT;
    else if (m == "cull_disabled") p.cull = CULL_DISABLED;
    else if (m == "unshaded") p.unshaded = true;
    else if (m == "diffuse_lambert") p.diffuse = DIFFUSE_LAMBERT;
    else if (m == "diffuse_lambert_wrap") p.diffuse = DIFFUSE_LAMBERT_WRAP;
    else if (m == "diffuse_burley") p.diffuse = DIFFUSE_BURLEY;
    else if (m == "diffuse_toon") p.diffuse = DIFFUSE_TOON;
    else if (m == "specular_schlick_ggx") p.specular = SPECULAR_SCHLICK_GGX;
    else if (m == "specular_toon") p.specular = SPECULAR_TOON;
    else if (m == "specular_disabled") p.specular = SPECULAR_DISABLED;
    else if (m == "skip_vertex_transform") p.skipVertexTransform = true;
    else if (m == "world_vertex_coords") p.worldVertexCoords = true;
    else if (m == "shadows_disabled") p.shadowsDisabled = true;
    else if (m == "ambient_light_disabled") p.ambientLightDisabled = true;
    else if (m == "fog_disabled") p.fogDisabled = true;
}

function groupUniforms(r: Reader): void {
    const t = r.t;
    const k = r.i;
    r.skipStatement();
    r.mark(k, r.i);
    if (t.is(k + 1, ";")) {
        r.group = "";
        r.subgroup = "";
        return;
    }
    if (t.kindAt(k + 1) == TOK_IDENT && t.is(k + 2, ";")) {
        r.group = t.word(k + 1);
        r.subgroup = "";
        return;
    }
    if (t.kindAt(k + 1) == TOK_IDENT && t.is(k + 2, ".") && t.kindAt(k + 3) == TOK_IDENT && t.is(k + 4, ";")) {
        r.group = t.word(k + 1);
        r.subgroup = t.word(k + 3);
        return;
    }
    r.error("shader-syntax", k, "`group_uniforms` takes a group, a group and a subgroup, or nothing",
        "write `group_uniforms Look;`, `group_uniforms Look.Rim;` or `group_uniforms;`");
}

// The type at token `k` and how many tokens it takes; -1 when it is no
// type the format has.
class TypeAt {
    type: UniformType = UniformType.Float;
    tokens: i32 = 0;
}

function typeAt(t: WgslTokens, k: i32, out: TypeAt): bool {
    if (t.kindAt(k) != TOK_IDENT) return false;
    const w = t.word(k);
    out.tokens = 1;
    if (w == "f32") out.type = UniformType.Float;
    else if (w == "i32") out.type = UniformType.Int;
    else if (w == "u32") out.type = UniformType.UInt;
    else if (w == "bool") out.type = UniformType.Bool;
    else if (w == "vec2f") out.type = UniformType.Vec2;
    else if (w == "vec3f") out.type = UniformType.Vec3;
    else if (w == "vec4f") out.type = UniformType.Vec4;
    else if (w == "vec2i") out.type = UniformType.IVec2;
    else if (w == "vec3i") out.type = UniformType.IVec3;
    else if (w == "vec4i") out.type = UniformType.IVec4;
    else if ((w == "vec2" || w == "vec3" || w == "vec4" || w == "texture_2d") && t.is(k + 1, "<") && t.is(k + 3, ">")) {
        out.tokens = 4;
        const e = t.word(k + 2);
        if (w == "texture_2d") {
            if (e != "f32") return false;
            out.type = UniformType.Texture2D;
            return true;
        }
        const n = w == "vec2" ? 2 : w == "vec3" ? 3 : 4;
        if (e == "f32") out.type = n == 2 ? UniformType.Vec2 : n == 3 ? UniformType.Vec3 : UniformType.Vec4;
        else if (e == "i32") out.type = n == 2 ? UniformType.IVec2 : n == 3 ? UniformType.IVec3 : UniformType.IVec4;
        else return false;
    } else return false;
    return true;
}

// The number at token `k` (a `-` before it at k - 1 is the caller's); NaN
// when it is none the format reads.
function numberAt(t: WgslTokens, k: i32): f64 {
    if (t.kindAt(k) != TOK_NUMBER) return NaN;
    let w = t.word(k);
    const last = w.charCodeAt(w.length - 1);
    const hex = w.startsWith("0x") || w.startsWith("0X");
    if (!hex && (last == 0x66 || last == 0x68 || last == 0x69 || last == 0x75)) w = w.substring(0, w.length - 1);
    else if (hex && (last == 0x69 || last == 0x75)) w = w.substring(0, w.length - 1);
    if (hex) {
        if (w.includes(".") || w.includes("p") || w.includes("P")) return NaN;
        return <f64>I64.parseInt(w.substring(2), 16);
    }
    return F64.parseFloat(w);
}

// Reads a signed number at the reader's index into `out`, moving past it.
function signedAt(r: Reader, k: i32): f64 {
    const t = r.t;
    if (t.is(k, "-")) return -numberAt(t, k + 1);
    return numberAt(t, k);
}

function signedLen(t: WgslTokens, k: i32): i32 {
    return t.is(k, "-") ? 2 : 1;
}

function uniform(r: Reader): void {
    const t = r.t;
    const p = r.p;
    const start = r.i;
    r.skipStatement();
    const end = r.i;
    r.mark(start, end);
    let k = start + 1;
    if (t.kindAt(k) != TOK_IDENT || !t.is(k + 1, ":")) {
        r.error("shader-syntax", start, "a uniform is `uniform name: type [: hints] [= default];`",
            "write `uniform tint: vec4<f32> : source_color = vec4<f32>(1.0);` (" + SHADERS_DOC + ")");
        return;
    }
    const nameTok = k;
    const name = t.word(k);
    if (glslName(r, k, name)) return;
    if (p.uniformIndex(name) >= 0) {
        r.error("shader-uniform-duplicate", k, "the uniform " + name + " is declared twice", "rename one of them");
        return;
    }
    if (reservedName(name)) {
        r.error("shader-name-reserved", k, "\"" + name + "\" is a name of the engine's", "rename the uniform");
        return;
    }
    k += 2;
    const ty = new TypeAt();
    if (!typeAt(t, k, ty)) {
        r.error("shader-uniform-type-unsupported", k, "\"" + t.word(k) + "\" is no type a uniform takes",
            "a uniform is f32, i32, u32, bool, a vec2, vec3 or vec4 of f32 or i32, or texture_2d<f32>");
        return;
    }
    const u = new ShaderUniform(name, ty.type);
    u.line = t.lines[nameTok];
    u.col = t.cols[nameTok];
    u.group = r.group;
    u.subgroup = r.subgroup;
    k += ty.tokens;
    const texture = u.type == UniformType.Texture2D;
    let hasFilter = false;
    let hasRepeat = false;
    if (t.is(k, ":")) {
        k++;
        while (k < end && !t.is(k, "=") && !t.is(k, ";")) {
            if (t.is(k, ",")) {
                k++;
                continue;
            }
            if (t.kindAt(k) != TOK_IDENT) {
                r.error("shader-syntax", k, "a uniform's hints are words, separated by commas", "write `: source_color`");
                return;
            }
            const h = t.word(k);
            const hk = k;
            k++;
            if (h == "source_color") {
                if (!(texture || u.type == UniformType.Vec3 || u.type == UniformType.Vec4)) {
                    r.error("shader-uniform-hint-type", hk, "source_color is a colour's hint: a vec3, a vec4 or a texture",
                        "remove it, or make the uniform a vec3<f32> or vec4<f32>");
                }
                u.hints |= HINT_SOURCE_COLOR;
            } else if (h == "hint_range") {
                if (!(u.type == UniformType.Float || u.type == UniformType.Int)) {
                    r.error("shader-uniform-hint-type", hk, "hint_range is a number's hint: an f32 or an i32", "remove it");
                }
                if (!t.is(k, "(")) {
                    r.error("shader-syntax", hk, "hint_range takes (min, max) or (min, max, step)", "write `hint_range(0.0, 1.0)`");
                    return;
                }
                k++;
                const a = signedAt(r, k);
                k += signedLen(t, k);
                if (!t.is(k, ",")) {
                    r.error("shader-syntax", hk, "hint_range takes (min, max) or (min, max, step)", "write `hint_range(0.0, 1.0)`");
                    return;
                }
                k++;
                const b = signedAt(r, k);
                k += signedLen(t, k);
                let step: f64 = 0;
                if (t.is(k, ",")) {
                    k++;
                    step = signedAt(r, k);
                    k += signedLen(t, k);
                }
                if (!t.is(k, ")") || isNaN(a) || isNaN(b) || isNaN(step)) {
                    r.error("shader-syntax", hk, "hint_range takes (min, max) or (min, max, step), numbers",
                        "write `hint_range(0.0, 1.0, 0.01)`");
                    return;
                }
                k++;
                u.hints |= HINT_RANGE;
                u.rangeMin = a;
                u.rangeMax = b;
                u.rangeStep = step;
            } else if (h == "hint_normal" || h == "hint_default_white" || h == "hint_default_black"
                || h == "hint_default_transparent" || h == "repeat_enable" || h == "repeat_disable"
                || FILTER_NAMES.includes(h)) {
                if (!texture) {
                    r.error("shader-uniform-hint-type", hk, h + " is a texture's hint", "remove it");
                    continue;
                }
                if (h == "hint_normal") u.hints |= HINT_NORMAL;
                else if (h == "hint_default_white") u.hints |= HINT_DEFAULT_WHITE;
                else if (h == "hint_default_black") u.hints |= HINT_DEFAULT_BLACK;
                else if (h == "hint_default_transparent") u.hints |= HINT_DEFAULT_TRANSPARENT;
                else if (h == "repeat_enable" || h == "repeat_disable") {
                    if (hasRepeat) r.error("shader-uniform-hint-type", hk, "a texture repeats or not: one repeat_ hint", "keep one");
                    hasRepeat = true;
                    u.repeat = h == "repeat_enable";
                } else {
                    if (hasFilter) r.error("shader-uniform-hint-type", hk, "a texture has one filter: one filter_ hint", "keep one");
                    hasFilter = true;
                    u.filter = FILTER_NAMES.indexOf(h);
                }
            } else if (HINTS_UNSUPPORTED.includes(h)) {
                r.error("shader-uniform-hint-unsupported", hk, "the hint " + h + " is not in the format",
                    "see " + SHADERS_DOC + ", \"Uniforms\"");
                if (t.is(k, "(")) {
                    while (k < end && !t.is(k, ")")) k++;
                    k++;
                }
            } else {
                r.error("shader-uniform-hint-unknown", hk, "\"" + h + "\" is no uniform hint",
                    "the hints are Godot's: source_color, hint_range, hint_normal, hint_default_*, filter_*, repeat_*");
                if (t.is(k, "(")) {
                    while (k < end && !t.is(k, ")")) k++;
                    k++;
                }
            }
        }
    }
    // The zero value, then the default written.
    for (let c = 0; c < 4; c++) u.def[c] = 0;
    if (u.type == UniformType.Vec4 && (u.hints & HINT_SOURCE_COLOR) != 0) u.def[3] = 1;
    if (t.is(k, "=")) {
        if (texture) {
            r.error("shader-uniform-default", k, "a texture uniform has no default in the code",
                "remove `= ...`; hint_default_white, _black or _transparent say what it is when unset");
            return;
        }
        if (!defaultAt(r, u, k + 1, end)) return;
        k = end - 1;
    }
    // Whatever follows the type, its hints or its default is a mistake (a
    // forgotten `:` before a hint, a forgotten `=` before a default): said,
    // rather than the words dropped and the uniform loaded without them.
    if (!t.is(k, ";")) {
        if (k < end && t.is(end - 1, ";")) {
            r.error("shader-syntax", k, "expected `:`, `=` or `;` after the uniform's type",
                "write `uniform name: type : hints = default;`");
        } else {
            r.error("shader-syntax", start, "a uniform ends with `;`", "add `;`");
        }
        return;
    }
    p.uniforms.push(u);
}

function varying(r: Reader): void {
    const t = r.t;
    const p = r.p;
    const start = r.i;
    r.skipStatement();
    const end = r.i;
    r.mark(start, end);
    const k = start + 1;
    if (t.is(k, "flat")) {
        r.error("shader-varying-unsupported", k, "a flat varying is not in the format",
            "pass a number through a smooth varying, or compute it in fragment()");
        return;
    }
    if (t.kindAt(k) != TOK_IDENT || !t.is(k + 1, ":")) {
        r.error("shader-syntax", start, "a varying is `varying name: type;`", "write `varying height: f32;`");
        return;
    }
    const name = t.word(k);
    if (glslName(r, k, name)) return;
    const ty = new TypeAt();
    const ok = typeAt(t, k + 2, ty);
    if (!ok || !(ty.type == UniformType.Float || ty.type == UniformType.Vec2 || ty.type == UniformType.Vec3
        || ty.type == UniformType.Vec4)) {
        r.error("shader-varying-unsupported", k + 2, "a varying is an f32, a vec2<f32>, a vec3<f32> or a vec4<f32>",
            "carry a whole number as an f32");
        return;
    }
    if (!t.is(k + 2 + ty.tokens, ";")) {
        r.error("shader-syntax", start, "a varying ends with `;`", "add `;`");
        return;
    }
    if (reservedName(name) || p.uniformIndex(name) >= 0) {
        r.error("shader-name-reserved", k, "\"" + name + "\" is a uniform's or the engine's name", "rename the varying");
        return;
    }
    for (let i = 0; i < p.varyings.length; i++) {
        if (p.varyings[i].name == name) {
            r.error("shader-uniform-duplicate", k, "the varying " + name + " is declared twice", "rename one of them");
            return;
        }
    }
    if (p.varyings.length >= MAX_SHADER_VARYINGS) {
        r.error("shader-too-many-varyings", k, "a shader holds at most " + MAX_SHADER_VARYINGS.toString() + " varyings",
            "pack them into vec4s");
        return;
    }
    const v = new ShaderVarying(name, ty.type);
    v.line = t.lines[k];
    v.col = t.cols[k];
    v.slot = p.varyings.length;
    p.varyings.push(v);
}

// Reads the default from token `k` to the statement's `;` (before `end`)
// into u.def: a number, true or false, or a constructor of the uniform's
// type with one number for every component or one for all.
function defaultAt(r: Reader, u: ShaderUniform, k: i32, end: i32): bool {
    const t = r.t;
    const n = uniformComponents(u.type);
    const nums = new Array<f64>();
    if (t.is(k, "true") || t.is(k, "false")) {
        if (u.type != UniformType.Bool) return badDefault(r, u, k);
        u.def[0] = t.is(k, "true") ? 1 : 0;
        return t.is(k + 1, ";") ? true : badDefault(r, u, k);
    }
    if (t.kindAt(k) == TOK_NUMBER || t.is(k, "-")) {
        const x = signedAt(r, k);
        k += signedLen(t, k);
        if (isNaN(x) || !t.is(k, ";") || n != 1) return badDefault(r, u, k);
        u.def[0] = u.type == UniformType.Bool ? (x != 0 ? 1 : 0) : x;
        return true;
    }
    // A constructor: vecN<f32>(...), vecNf(...), vecN(...), f32(...).
    if (t.kindAt(k) != TOK_IDENT) return badDefault(r, u, k);
    k++;
    if (t.is(k, "<")) {
        while (k < end && !t.is(k, ">")) k++;
        k++;
    }
    if (!t.is(k, "(")) return badDefault(r, u, k);
    k++;
    while (k < end && !t.is(k, ")")) {
        if (t.is(k, ",")) {
            k++;
            continue;
        }
        if (t.is(k, "true") || t.is(k, "false")) {
            nums.push(t.is(k, "true") ? 1 : 0);
            k++;
            continue;
        }
        const x = signedAt(r, k);
        if (isNaN(x)) return badDefault(r, u, k);
        nums.push(x);
        k += signedLen(t, k);
    }
    if (!t.is(k, ")") || !t.is(k + 1, ";")) return badDefault(r, u, k);
    if (nums.length == 1) {
        for (let c = 0; c < n; c++) u.def[c] = nums[0];
        return true;
    }
    if (nums.length != n) return badDefault(r, u, k);
    for (let c = 0; c < n; c++) u.def[c] = nums[c];
    return true;
}

function badDefault(r: Reader, u: ShaderUniform, k: i32): bool {
    r.error("shader-uniform-default", k, "the default of " + u.name + " is not a constant of its type",
        "write a number, true or false, or the type's constructor of numbers (vec4<f32>(1.0, 0.5, 0.2, 1.0))");
    return false;
}

// Whether `name` is the composer's or one of Godot's built-ins.
// The names rule of WebGL 2 (GLSL ES 3.0 refuses `gl`, a `gl_` prefix and
// a `__` anywhere, and rive's translation keeps a WGSL name as it is or
// adds a suffix that keeps the prefix).
export function glslRefuses(name: string): bool {
    return name == "gl" || name.startsWith("gl_") || name.includes("__");
}

function glslName(r: Reader, k: i32, name: string): bool {
    if (!glslRefuses(name)) return false;
    r.error("shader-name-glsl", k, "\"" + name + "\" is a name GLSL refuses (WebGL 2 draws the shader as GLSL)",
        "rename it: no name is `gl`, starts with `gl_` or holds `__`");
    return true;
}

function reservedName(name: string): bool {
    if (name.startsWith(RESERVED_PREFIX) || name.startsWith("HEDRA_") || name.startsWith("SAMPLER_")) return true;
    return BUILTINS_GLOBAL.includes(name) || BUILTINS_VERTEX.includes(name) || BUILTINS_FRAGMENT.includes(name)
        || BUILTINS_LIGHT.includes(name) || BUILTINS_UNSUPPORTED.includes(name);
}

// A top-level declaration's name (struct, const, override, alias, var):
// reserved names are refused.
function declName(r: Reader, k: i32): void {
    const t = r.t;
    let at = -1;
    if (t.is(k, "struct") || t.is(k, "const") || t.is(k, "override") || t.is(k, "alias")) at = k + 1;
    else if (t.is(k, "var")) {
        at = k + 1;
        if (t.is(at, "<")) {
            while (at < t.count && !t.is(at, ">")) at++;
            at++;
        }
    }
    if (at < 0 || at >= t.count || t.kindAt(at) != TOK_IDENT) return;
    const name = t.word(at);
    if (reservedName(name)) {
        r.error("shader-name-reserved", at, "\"" + name + "\" is a name of the engine's (a built-in, or the composer's)",
            "rename it");
    }
}

function fnDecl(r: Reader): void {
    const t = r.t;
    const k = r.i;
    const nameAt = k + 1;
    if (t.kindAt(nameAt) == TOK_IDENT) {
        const name = t.word(nameAt);
        const stage = name == "vertex" ? 0 : name == "fragment" ? 1 : name == "light" ? 2 : -1;
        if (stage >= 0) {
            const ok = t.is(nameAt + 1, "(") && t.is(nameAt + 2, ")") && t.is(nameAt + 3, "{");
            if (!ok) {
                r.error("shader-stage-signature", nameAt, "fn " + name + "() takes no parameters and returns nothing",
                    "write `fn " + name + "() { ... }`; it reads and writes the built-ins");
            } else {
                if (stage == 0) {
                    if (r.p.hasVertex) r.error("shader-syntax", nameAt, "fn vertex() is defined twice", "keep one");
                    r.p.hasVertex = true;
                } else if (stage == 1) {
                    if (r.p.hasFragment) r.error("shader-syntax", nameAt, "fn fragment() is defined twice", "keep one");
                    r.p.hasFragment = true;
                } else {
                    if (r.p.hasLight) r.error("shader-syntax", nameAt, "fn light() is defined twice", "keep one");
                    r.p.hasLight = true;
                }
            }
            r.skipStatement();
            if (ok) {
                r.bodies.push(nameAt + 3);
                r.bodies.push(r.i - 1);
                r.stages.push(stage);
            }
            return;
        }
        if (reservedName(name)) {
            r.error("shader-name-reserved", nameAt, "\"" + name + "\" is a name of the engine's (a built-in, or the composer's)",
                "rename the function");
        }
    }
    r.skipStatement();
}

// Every word of the code (not of a declaration statement): what it uses,
// the names rule, the unsupported built-ins, uniforms hidden.
function scanWords(r: Reader): void {
    const t = r.t;
    const p = r.p;
    for (let k = 0; k < t.count; k++) {
        if (t.kindAt(k) != TOK_IDENT || r.directive[k]) continue;
        const w = t.word(k);
        if (glslName(r, k, w)) continue;
        const member = k > 0 && t.is(k - 1, ".");
        if (member) continue;
        if (w == "ALPHA") p.usesAlpha = true;
        else if (w == "ALPHA_SCISSOR_THRESHOLD") p.usesAlphaScissor = true;
        else if (w == "discard") p.usesDiscard = true;
        else if (w == "TIME") p.usesTime = true;
        else if (w == "SCREEN_UV") p.usesScreenUv = true;
        else if (w == "INSTANCE_ID") p.usesInstanceId = true;
        else if (w == "INSTANCE_CUSTOM") p.usesInstanceCustom = true;
        else if (w == "POSITION") p.usesPosition = true;
        if (BUILTINS_UNSUPPORTED.includes(w)) {
            r.error("shader-builtin-unsupported", k, "the built-in " + w + " is not given by Hedra",
                "see " + SHADERS_DOC + ", \"Built-ins\"");
            continue;
        }
        if (p.uniformIndex(w) >= 0) {
            const declares = t.is(k + 1, ":") || t.is(k - 1, "let") || t.is(k - 1, "var") || t.is(k - 1, "const")
                || t.is(k - 1, "fn") || t.is(k - 1, "struct") || t.is(k - 1, "alias") || t.is(k - 1, "override")
                || closesVarTemplate(t, k - 1);
            if (declares) {
                r.error("shader-uniform-shadowed", k, "\"" + w + "\" hides the uniform of that name",
                    "rename it: every use of a uniform's name reads the uniform");
            }
        }
    }
}

// Whether token `k` is the `>` closing a `var<...>` (`var<private> name`
// declares `name`). Any other `>` is a comparison (`UV.x > threshold`, the
// dissolve's), a shift (`x >> amount`) or a type's (`vec3<f32>`), and the
// word after it only reads the uniform. The walk back stops at a statement's
// edge, so it costs a few words.
function closesVarTemplate(t: WgslTokens, k: i32): bool {
    if (!t.is(k, ">") || t.is(k - 1, ">") || t.is(k - 1, "-")) return false;
    let depth = 0;
    for (let j = k; j >= 0; j--) {
        if (t.is(j, ">")) depth++;
        else if (t.is(j, "<")) {
            depth--;
            if (depth == 0) return t.is(j - 1, "var");
        } else if (t.is(j, ";") || t.is(j, "{") || t.is(j, "}") || t.is(j, "(") || t.is(j, ")")) return false;
    }
    return false;
}

function stageName(s: i32): string {
    return s == 0 ? "vertex()" : s == 1 ? "fragment()" : "light()";
}

// WGSL's calls that need a fragment's derivatives, which a vertex stage
// has not: naga refuses them there without saying where.
const FRAGMENT_CALLS: StaticArray<string> = [
    "textureSample", "textureSampleBias", "textureSampleCompare", "dpdx", "dpdxCoarse", "dpdxFine", "dpdy",
    "dpdyCoarse", "dpdyFine", "fwidth", "fwidthCoarse", "fwidthFine",
];

// A stage function naming another stage's built-in, or vertex() calling
// one of FRAGMENT_CALLS.
function scanStages(r: Reader): void {
    const t = r.t;
    for (let b = 0; b < r.stages.length; b++) {
        const stage = r.stages[b];
        const open = r.bodies[b * 2];
        const close = r.bodies[b * 2 + 1];
        for (let k = open + 1; k < close; k++) {
            if (t.kindAt(k) != TOK_IDENT || (k > 0 && t.is(k - 1, "."))) continue;
            const w = t.word(k);
            if (stage == 0 && t.is(k + 1, "(") && FRAGMENT_CALLS.includes(w)) {
                r.error("shader-builtin-stage", k, w + "() is the fragment stage's, not vertex()'s",
                    "WGSL has no derivatives in a vertex stage: sample at a level, `textureSampleLevel(t, s, uv, 0.0)`, "
                    + "or Godot's `texture(t, uv)`, which vertex() reads at level 0 (" + SHADERS_DOC + ", \"Uniforms\")");
                continue;
            }
            if (BUILTINS_GLOBAL.includes(w)) continue;
            const inV = BUILTINS_VERTEX.includes(w);
            const inF = BUILTINS_FRAGMENT.includes(w);
            const inL = BUILTINS_LIGHT.includes(w);
            if (!inV && !inF && !inL) continue;
            const ok = stage == 0 ? inV : stage == 1 ? inF : inL;
            if (ok) continue;
            const owners = new Array<string>();
            if (inV) owners.push("vertex()");
            if (inF) owners.push("fragment()");
            if (inL) owners.push("light()");
            r.error("shader-builtin-stage", k, w + " is " + owners.join(" and ") + "'s, not " + stageName(stage) + "'s",
                "pass the value through a varying (`varying name: type;`, written in one stage and read in the next), or compute it in its stage (" + SHADERS_DOC + ", \"Built-ins\")");
        }
    }
}

function limits(r: Reader): void {
    const p = r.p;
    let textures = 0;
    for (let i = 0; i < p.uniforms.length; i++) {
        const u = p.uniforms[i];
        if (i == MAX_SHADER_UNIFORMS) {
            p.diagnostics.push(new ShaderDiagnostic(SHADER_ERROR, "shader-too-many-uniforms",
                "a shader holds at most " + MAX_SHADER_UNIFORMS.toString() + " uniforms", "pack some into vectors", u.line, u.col));
        }
        if (u.type == UniformType.Texture2D) {
            textures++;
            if (textures == MAX_SHADER_TEXTURES + 1) {
                p.diagnostics.push(new ShaderDiagnostic(SHADER_ERROR, "shader-too-many-textures",
                    "a shader holds at most " + MAX_SHADER_TEXTURES.toString() + " textures (WebGL 2's texture units)",
                    "combine textures into the channels of one", u.line, u.col));
            }
        }
        if (u.offset >= 0 && u.offset + u.size > MAX_PARAM_BLOCK_BYTES) {
            p.diagnostics.push(new ShaderDiagnostic(SHADER_ERROR, "shader-block-too-large",
                "the uniforms take more than " + MAX_PARAM_BLOCK_BYTES.toString() + " bytes", "use fewer or smaller uniforms",
                u.line, u.col));
            break;
        }
    }
    if (textures <= MAX_SHADER_TEXTURES && slotCount(p) > MAX_SHADER_SLOTS) {
        // (at the first texture whose sampler made the count go over)
        let last: ShaderUniform? = null;
        for (let i = 0; i < p.uniforms.length; i++) if (p.uniforms[i].type == UniformType.Texture2D) last = p.uniforms[i];
        const u = last as ShaderUniform;
        p.diagnostics.push(new ShaderDiagnostic(SHADER_ERROR, "shader-too-many-textures",
            "the textures and their samplers take " + slotCount(p).toString() + " bindings, more than "
                + MAX_SHADER_SLOTS.toString(),
            "give more textures the same filter_ and repeat_ hints (textures of one kind share a sampler)", u.line, u.col));
    }
}
