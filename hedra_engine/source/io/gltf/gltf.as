// Loading a glTF file: reading a `.gltf` or `.glb` into a document,
// validating it, resolving its buffers and images, and the loading errors.
//
// Files go through the VFS (engine/src/fs/vfs.as). Images are not decoded:
// ImageData keeps the encoded bytes and their format.

import { Result, ErrorValue, panic } from "../../../base/util";
import { vfs } from "../../../fs/vfs";
import { parent, join } from "../../../fs/path";
import { Root } from "./doc";
import { rootFromBytes, isValidUtf8 } from "./de";
import { validateRoot, validationText, ValidationIssue } from "./validate";
import { glbFromReader, glbFromSlice, isGlb, FAILED_TO_FILL_WHOLE_BUFFER, Glb } from "./glb";

// ---------------------------------------------------------------------------
// Loading errors

export enum GltfErrorKind {
    Base64,
    Binary,
    BufferLength,
    Deserialize,
    Io,
    Image,
    MissingBlob,
    ExternalReferenceInSliceImport,
    UnsupportedImageEncoding,
    UnsupportedImageFormat,
    UnsupportedScheme,
    Validation,
}

export class GltfError extends ErrorValue {
    kind: GltfErrorKind;
    // Base64 / Binary / Deserialize / Io / Image: the inner error's Display.
    text: string = "";
    // The inner typed error (DeError, GlbError, a VFS IoError, Base64Error).
    source: ErrorValue? = null;
    // BufferLength
    buffer: i32 = 0;
    expected: u64 = 0;
    actual: u64 = 0;
    // Validation
    issues: Array<ValidationIssue> = [];

    constructor(kind: GltfErrorKind) {
        super();
        this.kind = kind;
    }

    static wrap(kind: GltfErrorKind, text: string, source: ErrorValue?): GltfError {
        const e = new GltfError(kind);
        e.text = text;
        e.source = source;
        return e;
    }

    // The error message.
    toString(): string {
        switch (this.kind) {
            case GltfErrorKind.BufferLength:
                return "buffer " + this.buffer.toString() + ": expected " + this.expected.toString()
                    + " bytes but received " + this.actual.toString() + " bytes";
            case GltfErrorKind.MissingBlob: return "missing binary portion of binary glTF";
            case GltfErrorKind.ExternalReferenceInSliceImport: return "external reference in slice only import";
            case GltfErrorKind.UnsupportedImageEncoding: return "unsupported image encoding";
            case GltfErrorKind.UnsupportedScheme: return "unsupported URI scheme";
            case GltfErrorKind.Validation: return validationText(this.issues);
            default: return this.text;
        }
    }

    fail<T>(): Result<T> {
        return Result.failWith<T>(this);
    }
}

// The GltfError of a failed Result (null for anything else).
export function gltfErrorOf<T>(r: Result<T>): GltfError? {
    if (r.ok) return null;
    const c = r.cause;
    if (c == null) return null;
    const is = c instanceof GltfError;
    if (is) return c as GltfError;
    return null;
}

function fromResult<T, U>(kind: GltfErrorKind, r: Result<U>): Result<T> {
    return GltfError.wrap(kind, r.err, r.cause).fail<T>();
}

// ---------------------------------------------------------------------------
// Gltf / Document

// A loaded glTF: the document Root and the GLB's BIN chunk.
export class Gltf {
    document: Root;
    blob: Uint8Array?;
    constructor(document: Root, blob: Uint8Array?) {
        this.document = document;
        this.blob = blob;
    }
}

// Gltf::from_reader_without_validation over a file's bytes: `read_exact` of
// the magic, then a GLB (Glb::from_reader, its JSON chunk through
// `from_slice`) or the whole text as JSON (rootFromBytes with ioRead).
export function gltfFromReaderWithoutValidation(bytes: Uint8Array): Result<Gltf> {
    if (bytes.length < 4) {
        return GltfError.wrap(GltfErrorKind.Io, FAILED_TO_FILL_WHOLE_BUFFER, null).fail<Gltf>();
    }
    if (isGlb(bytes)) {
        const g = glbFromReader(bytes);
        if (!g.ok) return fromResult<Gltf, Glb>(GltfErrorKind.Binary, g);
        const root = rootFromBytes(g.value.json, false);
        if (!root.ok) return fromResult<Gltf, Root>(GltfErrorKind.Deserialize, root);
        return Result.okv<Gltf>(new Gltf(root.value, g.value.bin));
    }
    const root = rootFromBytes(bytes, true);
    if (!root.ok) return fromResult<Gltf, Root>(GltfErrorKind.Deserialize, root);
    return Result.okv<Gltf>(new Gltf(root.value, null));
}

// Gltf::from_reader: the same, validated.
export function gltfFromReader(bytes: Uint8Array): Result<Gltf> {
    const g = gltfFromReaderWithoutValidation(bytes);
    if (!g.ok) return g;
    const v = documentValidate(g.value.document);
    if (!v.ok) return v.forward<Gltf>();
    return g;
}

// Gltf::from_slice_without_validation.
export function gltfFromSliceWithoutValidation(bytes: Uint8Array): Result<Gltf> {
    if (isGlb(bytes)) {
        const g = glbFromSlice(bytes);
        if (!g.ok) return fromResult<Gltf, Glb>(GltfErrorKind.Binary, g);
        const root = rootFromBytes(g.value.json, false);
        if (!root.ok) return fromResult<Gltf, Root>(GltfErrorKind.Deserialize, root);
        return Result.okv<Gltf>(new Gltf(root.value, g.value.bin));
    }
    const root = rootFromBytes(bytes, false);
    if (!root.ok) return fromResult<Gltf, Root>(GltfErrorKind.Deserialize, root);
    return Result.okv<Gltf>(new Gltf(root.value, null));
}

// Gltf::from_slice.
export function gltfFromSlice(bytes: Uint8Array): Result<Gltf> {
    const g = gltfFromSliceWithoutValidation(bytes);
    if (!g.ok) return g;
    const v = documentValidate(g.value.document);
    if (!v.ok) return v.forward<Gltf>();
    return g;
}

// Opens a glTF or GLB file through the VFS and parses it (gltfFromReader).
export function gltfOpen(path: string): Result<Gltf> {
    const bytes = vfs.read(path);
    if (!bytes.ok) return fromResult<Gltf, Uint8Array>(GltfErrorKind.Io, bytes);
    return gltfFromReader(bytes.value);
}

// Validates the document: ok, or a Validation error listing every issue.
// `extra`: extensions a file may require besides ENABLED_EXTENSIONS, read by
// the caller (validateRoot).
export function documentValidate(root: Root, extra: Array<string> = []): Result<bool> {
    const issues = validateRoot(root, extra);
    if (issues.length == 0) return Result.okv<bool>(true);
    const e = new GltfError(GltfErrorKind.Validation);
    e.issues = issues;
    return e.fail<bool>();
}

// Document::from_json: the root, once it validates (`extra` as for
// documentValidate).
export function documentFromJson(root: Root, extra: Array<string> = []): Result<Root> {
    const v = documentValidate(root, extra);
    if (!v.ok) return v.forward<Root>();
    return Result.okv<Root>(root);
}

// ---------------------------------------------------------------------------
// base64 0.13.1 `decode` (STANDARD: `+` `/`, padding optional but checked,
// no trailing bits), with its errors

export enum Base64ErrorKind {
    InvalidByte,
    InvalidLength,
    InvalidLastSymbol,
}

export class Base64Error extends ErrorValue {
    kind: Base64ErrorKind;
    offset: i32 = 0;
    byte: u8 = 0;
    constructor(kind: Base64ErrorKind, offset: i32, byte: u8) {
        super();
        this.kind = kind;
        this.offset = offset;
        this.byte = byte;
    }
    toString(): string {
        switch (this.kind) {
            case Base64ErrorKind.InvalidByte:
                return "Invalid byte " + this.byte.toString() + ", offset " + this.offset.toString() + ".";
            case Base64ErrorKind.InvalidLength: return "Encoded text cannot have a 6-bit remainder.";
            default:
                return "Invalid last symbol " + this.byte.toString() + ", offset " + this.offset.toString() + ".";
        }
    }
}

const PAD: u8 = 0x3D; // '='

function morsel(c: u8): i32 {
    if (c >= 65 && c <= 90) return <i32>c - 65;
    if (c >= 97 && c <= 122) return <i32>c - 71;
    if (c >= 48 && c <= 57) return <i32>c + 4;
    if (c == 43) return 62;
    if (c == 47) return 63;
    return -1;
}

export function base64Decode(input: Uint8Array): Result<Uint8Array> {
    const len = input.length;
    const rem = len % 8;
    if (rem == 1 || rem == 5) {
        if (len > 0) {
            const b = input[len - 1];
            if (b != PAD && morsel(b) < 0) {
                return Result.failWith<Uint8Array>(new Base64Error(Base64ErrorKind.InvalidByte, len - 1, b));
            }
        }
        return Result.failWith<Uint8Array>(new Base64Error(Base64ErrorKind.InvalidLength, 0, 0));
    }
    const numChunks = (len + 7) / 8;
    const out: Array<u8> = [];
    // Every chunk but the last is decoded whole (8 symbols, no padding).
    const fullEnd = numChunks > 0 ? (numChunks - 1) * 8 : 0;
    for (let i = 0; i < fullEnd; i += 8) {
        let acc: u64 = 0;
        for (let k = 0; k < 8; k++) {
            const m = morsel(input[i + k]);
            if (m < 0) return Result.failWith<Uint8Array>(new Base64Error(Base64ErrorKind.InvalidByte, i + k, input[i + k]));
            acc = (acc << 6) | <u64>m;
        }
        for (let k = 5; k >= 0; k--) out.push(<u8>(acc >> (<u64>k * 8)));
    }
    // The last chunk, with padding.
    let leftover: u64 = 0;
    let morsels = 0;
    let padding = 0;
    let firstPad = 0;
    let lastSymbol: u8 = 0;
    const start = fullEnd;
    for (let i = 0; i < len - start; i++) {
        const b = input[start + i];
        if (b == PAD) {
            if (i % 4 < 2) {
                const bad = start + (padding > 0 ? firstPad : i);
                return Result.failWith<Uint8Array>(new Base64Error(Base64ErrorKind.InvalidByte, bad, b));
            }
            if (padding == 0) firstPad = i;
            padding++;
            continue;
        }
        if (padding > 0) {
            return Result.failWith<Uint8Array>(new Base64Error(Base64ErrorKind.InvalidByte, start + firstPad, PAD));
        }
        lastSymbol = b;
        const shift = <u64>(64 - (morsels + 1) * 6);
        const m = morsel(b);
        if (m < 0) return Result.failWith<Uint8Array>(new Base64Error(Base64ErrorKind.InvalidByte, start + i, b));
        leftover |= <u64>m << shift;
        morsels++;
    }
    let ready = 0;
    switch (morsels) {
        case 0: ready = 0; break;
        case 2: ready = 8; break;
        case 3: ready = 16; break;
        case 4: ready = 24; break;
        case 6: ready = 32; break;
        case 7: ready = 40; break;
        case 8: ready = 48; break;
        default: panic("Impossible: must only have 0 to 8 input bytes in last chunk, with no invalid lengths");
    }
    const mask: u64 = ready == 0 ? u64.MAX_VALUE : (u64.MAX_VALUE >> <u64>ready);
    if ((leftover & mask) != 0) {
        return Result.failWith<Uint8Array>(
            new Base64Error(Base64ErrorKind.InvalidLastSymbol, start + morsels - 1, lastSymbol));
    }
    for (let appended = 0; appended < ready; appended += 8) {
        out.push(<u8>(leftover >> <u64>(56 - appended)));
    }
    const r = new Uint8Array(out.length);
    for (let i = 0; i < out.length; i++) r[i] = out[i];
    return Result.okv<Uint8Array>(r);
}

// ---------------------------------------------------------------------------
// URIs

// Percent-decodes a URI; a `%XX` sequence that does not decode to UTF-8
// panics.
export function urlDecode(s: string): string {
    const data = Uint8Array.wrap(String.UTF8.encode(s));
    let hasPct = false;
    for (let i = 0; i < data.length; i++) {
        if (data[i] == 0x25) {
            hasPct = true;
            break;
        }
    }
    if (!hasPct) return s;
    const out: Array<u8> = [];
    let i = 0;
    while (i < data.length) {
        const c = data[i];
        if (c != 0x25) {
            out.push(c);
            i++;
            continue;
        }
        if (data.length - (i + 1) < 2) {
            // fewer than two bytes after '%': "%" and the rest, verbatim
            for (let k = i; k < data.length; k++) out.push(data[k]);
            break;
        }
        const h1 = hexDigit(data[i + 1]);
        if (h1 < 0) {
            out.push(0x25);
            i++;
            continue;
        }
        const h2 = hexDigit(data[i + 2]);
        if (h2 < 0) {
            out.push(0x25);
            out.push(data[i + 1]);
            i += 2;
            continue;
        }
        out.push(<u8>((h1 << 4) | h2));
        i += 3;
    }
    const bytes = new Uint8Array(out.length);
    for (let k = 0; k < out.length; k++) bytes[k] = out[k];
    if (!isValidUtf8(bytes)) {
        panic("called `Result::unwrap()` on an `Err` value: FromUtf8Error");
    }
    return String.UTF8.decode(bytes.buffer);
}

function hexDigit(c: u8): i32 {
    if (c >= 48 && c <= 57) return <i32>c - 48;
    if (c >= 65 && c <= 70) return <i32>c - 55;
    if (c >= 97 && c <= 102) return <i32>c - 87;
    return -1;
}

export enum SchemeKind {
    Data,
    File,
    Relative,
    Unsupported,
}

// How a buffer or image URI is resolved: data URI, relative file, or
// unsupported.
export class Scheme {
    kind: SchemeKind = SchemeKind.Unsupported;
    mime: string? = null; // Data: the media type part, when there is one
    data: string = ""; // Data: the base64 text
    path: string = ""; // File / Relative (decoded)

    // Scheme::parse
    static parse(uri: string): Scheme {
        const s = new Scheme();
        if (uri.includes(":")) {
            if (uri.startsWith("data:")) {
                const rest = uri.substring(5);
                const parts = rest.split(";base64,");
                s.kind = SchemeKind.Data;
                if (parts.length >= 2) {
                    s.mime = parts[0];
                    s.data = parts[1];
                } else {
                    s.mime = null;
                    s.data = parts[0];
                }
            } else if (uri.startsWith("file://")) {
                s.kind = SchemeKind.File;
                s.path = uri.substring(7);
            } else if (uri.startsWith("file:")) {
                s.kind = SchemeKind.File;
                s.path = uri.substring(5);
            } else {
                s.kind = SchemeKind.Unsupported;
            }
        } else {
            s.kind = SchemeKind.Relative;
            s.path = urlDecode(uri);
        }
        return s;
    }
}

function readToEnd(path: string): Result<Uint8Array> {
    const r = vfs.read(path);
    if (!r.ok) return fromResult<Uint8Array, Uint8Array>(GltfErrorKind.Io, r);
    return r;
}

// The file a uri names, as schemeRead reads it under `base` (absolute for
// a file: uri, else relative to the glTF's directory), or null for a data:
// uri or an unsupported scheme: what an importer reports as a file it read.
export function schemeFilePath(uri: string): string? {
    const s = Scheme.parse(uri);
    if (s.kind == SchemeKind.File || s.kind == SchemeKind.Relative) return s.path;
    return null;
}

// Scheme::read
export function schemeRead(base: string?, uri: string): Result<Uint8Array> {
    const s = Scheme.parse(uri);
    switch (s.kind) {
        case SchemeKind.Data: {
            const d = base64Decode(Uint8Array.wrap(String.UTF8.encode(s.data)));
            if (!d.ok) return fromResult<Uint8Array, Uint8Array>(GltfErrorKind.Base64, d);
            return d;
        }
        case SchemeKind.File:
            if (base != null) return readToEnd(s.path);
            break;
        case SchemeKind.Relative:
            if (base != null) return readToEnd(join(base, s.path));
            break;
        default:
            return new GltfError(GltfErrorKind.UnsupportedScheme).fail<Uint8Array>();
    }
    return new GltfError(GltfErrorKind.ExternalReferenceInSliceImport).fail<Uint8Array>();
}

// ---------------------------------------------------------------------------
// Buffers

// The GLB blob, taken by the first buffer that uses it.
export class BlobSlot {
    blob: Uint8Array?;
    constructor(blob: Uint8Array?) {
        this.blob = blob;
    }
}

// buffer::Data::from_source_and_blob: the uri's bytes (`uri` null = the
// BIN chunk), zero-padded to a multiple of 4.
export function bufferDataFromSourceAndBlob(uri: string?, base: string?, blob: BlobSlot): Result<Uint8Array> {
    let data: Uint8Array;
    if (uri != null) {
        const r = schemeRead(base, uri);
        if (!r.ok) return r;
        data = r.value;
    } else {
        const b = blob.blob;
        if (b == null) return new GltfError(GltfErrorKind.MissingBlob).fail<Uint8Array>();
        blob.blob = null;
        data = b;
    }
    if (data.length % 4 != 0) {
        const padded = new Uint8Array((data.length + 3) & ~3);
        padded.set(data, 0);
        data = padded;
    }
    return Result.okv<Uint8Array>(data);
}

// The bytes of every buffer, in document order.
export function importBuffers(root: Root, base: string?, blob: Uint8Array?): Result<Array<Uint8Array>> {
    const slot = new BlobSlot(blob);
    const out: Array<Uint8Array> = [];
    for (let i = 0; i < root.buffers.length; i++) {
        const b = root.buffers[i];
        const d = bufferDataFromSourceAndBlob(b.uri, base, slot);
        if (!d.ok) return d.forward<Array<Uint8Array>>();
        if (<u64>d.value.length < b.byteLength) {
            const e = new GltfError(GltfErrorKind.BufferLength);
            e.buffer = i;
            e.expected = b.byteLength;
            e.actual = <u64>d.value.length;
            return e.fail<Array<Uint8Array>>();
        }
        out.push(d.value);
    }
    return Result.okv<Array<Uint8Array>>(out);
}

// ---------------------------------------------------------------------------
// Images

export enum ImageFormat {
    Png,
    Jpeg,
}

// image::Data, without the decode: the encoded bytes and their format.
export class ImageData {
    bytes: Uint8Array;
    format: ImageFormat;
    constructor(bytes: Uint8Array, format: ImageFormat) {
        this.bytes = bytes;
        this.format = format;
    }
}

// Where an image's bytes come from: a buffer view or a uri.
export class ImageSource {
    isView: bool = false;
    view: i32 = -1; // View: the buffer view
    mimeType: string? = null; // View: always set; Uri: optional
    uri: string = ""; // Uri
}

// An image's source: a view (then `mimeType` is unwrapped) or a uri (unwrapped).
export function imageSource(root: Root, image: i32): ImageSource {
    const im = root.images[image];
    const s = new ImageSource();
    if (im.bufferView >= 0) {
        if (im.bufferView >= root.bufferViews.length) panic("called `Option::unwrap()` on a `None` value");
        const mt = im.mimeType;
        if (mt == null) panic("called `Option::unwrap()` on a `None` value");
        s.isView = true;
        s.view = im.bufferView;
        s.mimeType = mt;
    } else {
        const u = im.uri;
        if (u == null) panic("called `Option::unwrap()` on a `None` value");
        s.uri = u as string;
        s.mimeType = im.mimeType;
    }
    return s;
}

// The last `.`-separated piece of `uri` (`uri.rsplit('.').next()`).
function lastDotPiece(uri: string): string {
    const i = uri.lastIndexOf(".");
    return i < 0 ? uri : uri.substring(i + 1);
}

// image::Data::from_source (the `guess_mime_type` feature is off, so an
// unknown mime type is UnsupportedImageEncoding). No pixel decoding.
export function imageDataFromSource(root: Root, image: i32, base: string?, buffers: Array<Uint8Array>): Result<ImageData> {
    const src = imageSource(root, image);
    if (!src.isView) {
        if (base == null) return new GltfError(GltfErrorKind.ExternalReferenceInSliceImport).fail<ImageData>();
        const scheme = Scheme.parse(src.uri);
        if (scheme.kind == SchemeKind.Data && scheme.mime != null) {
            const d = base64Decode(Uint8Array.wrap(String.UTF8.encode(scheme.data)));
            if (!d.ok) return fromResult<ImageData, Uint8Array>(GltfErrorKind.Base64, d);
            const m = scheme.mime as string;
            if (m == "image/png") return Result.okv<ImageData>(new ImageData(d.value, ImageFormat.Png));
            if (m == "image/jpeg") return Result.okv<ImageData>(new ImageData(d.value, ImageFormat.Jpeg));
            return new GltfError(GltfErrorKind.UnsupportedImageEncoding).fail<ImageData>();
        }
        if (scheme.kind == SchemeKind.Unsupported) return new GltfError(GltfErrorKind.UnsupportedScheme).fail<ImageData>();
        const r = schemeRead(base, src.uri);
        if (!r.ok) return r.forward<ImageData>();
        const mt = src.mimeType;
        if (mt != null) {
            if (mt == "image/png") return Result.okv<ImageData>(new ImageData(r.value, ImageFormat.Png));
            if (mt == "image/jpeg") return Result.okv<ImageData>(new ImageData(r.value, ImageFormat.Jpeg));
            return new GltfError(GltfErrorKind.UnsupportedImageEncoding).fail<ImageData>();
        }
        const ext = lastDotPiece(src.uri);
        if (ext == "png") return Result.okv<ImageData>(new ImageData(r.value, ImageFormat.Png));
        if (ext == "jpg" || ext == "jpeg") return Result.okv<ImageData>(new ImageData(r.value, ImageFormat.Jpeg));
        return new GltfError(GltfErrorKind.UnsupportedImageEncoding).fail<ImageData>();
    }
    const view = root.bufferViews[src.view];
    if (view.buffer < 0 || view.buffer >= buffers.length) {
        panic("index out of bounds: the len is " + buffers.length.toString() + " but the index is " + view.buffer.toString());
    }
    const data = buffers[view.buffer];
    const begin = view.byteOffset >= 0 ? view.byteOffset : 0;
    const end = begin + <i64>view.byteLength;
    if (end > <i64>data.length) {
        panic("range end index " + end.toString() + " out of range for slice of length " + data.length.toString());
    }
    const bytes = data.slice(<i32>begin, <i32>end);
    const mt = src.mimeType as string;
    if (mt == "image/png") return Result.okv<ImageData>(new ImageData(bytes, ImageFormat.Png));
    if (mt == "image/jpeg") return Result.okv<ImageData>(new ImageData(bytes, ImageFormat.Jpeg));
    return new GltfError(GltfErrorKind.UnsupportedImageEncoding).fail<ImageData>();
}

// The data of every image, in document order.
export function importImages(root: Root, base: string?, buffers: Array<Uint8Array>): Result<Array<ImageData>> {
    const out: Array<ImageData> = [];
    for (let i = 0; i < root.images.length; i++) {
        const d = imageDataFromSource(root, i, base, buffers);
        if (!d.ok) return d.forward<Array<ImageData>>();
        out.push(d.value);
    }
    return Result.okv<Array<ImageData>>(out);
}

// An imported file: the document, its buffers and its images.
export class Import {
    document: Root;
    buffers: Array<Uint8Array>;
    images: Array<ImageData>;
    constructor(document: Root, buffers: Array<Uint8Array>, images: Array<ImageData>) {
        this.document = document;
        this.buffers = buffers;
        this.images = images;
    }
}

function importImpl(g: Gltf, base: string?): Result<Import> {
    const buffers = importBuffers(g.document, base, g.blob);
    if (!buffers.ok) return buffers.forward<Import>();
    const images = importImages(g.document, base, buffers.value);
    if (!images.ok) return images.forward<Import>();
    return Result.okv<Import>(new Import(g.document, buffers.value, images.value));
}

// Imports the file at `path`: the file (validated), its buffers and its images,
// uris resolved against the file's directory ("./" when it has none).
export function gltfImport(path: string): Result<Import> {
    const p = parent(path);
    const base = p != null ? p : "./";
    const bytes = vfs.read(path);
    if (!bytes.ok) return fromResult<Import, Uint8Array>(GltfErrorKind.Io, bytes);
    const g = gltfFromReader(bytes.value);
    if (!g.ok) return g.forward<Import>();
    return importImpl(g.value, base);
}

// Imports a file already in memory: no base directory, so only data: uris and the blob.
export function gltfImportSlice(bytes: Uint8Array): Result<Import> {
    const g = gltfFromSlice(bytes);
    if (!g.ok) return g.forward<Import>();
    return importImpl(g.value, null);
}
