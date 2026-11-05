// `KHR_draco_mesh_compression`, the Draco bitstream, both ways.
//
// Draco models a mesh the way glTF does not quite: attributes belong to a
// point cloud, triangles index into it, and each attribute carries a
// *unique id* that the glTF extension uses to say which accessor it stands
// for. This module is the translation between that model and a flat set of
// per-vertex `f32` channels, which is the shape both the importer and the
// exporter already work in.
//
// Draco is lossy by design: positions and the rest are quantized to a chosen
// number of bits before encoding, so a round trip moves vertices by up to
// half a quantization step. That is the trade the format exists to make, and
// `export --quantize-position 0` turns it off for positions if a file has to
// survive exactly.

import { Result } from "../../../base/util";
import { DecoderBuffer } from "../draco/core/decoder_buffer";
import { Mesh } from "../draco/geometry/mesh";
import { MeshDecoder } from "../draco/decode/mesh_decoder";

// The values of one decoded attribute: `components` per vertex, in vertex
// order, as many vertices as the mesh has.
export class Channel {
    values: Float32Array = new Float32Array(0);
}

// A decoded Draco mesh: the triangle indices, and a channel per attribute
// unique id the caller asked for.
export class Decoded {
    indices: Array<u32> = [];
    vertices: i32 = 0;
}

// A decoded mesh and what the decode found.
export class DecodedMesh {
    mesh: Mesh;
    decoded: Decoded;

    constructor(mesh: Mesh, decoded: Decoded) {
        this.mesh = mesh;
        this.decoded = decoded;
    }
}

// Decode a Draco buffer. The caller then pulls out the channels it needs by
// unique id, because only it knows which accessor each one feeds.
export function decode(bytes: Uint8Array): Result<DecodedMesh> {
    const buffer = new DecoderBuffer(bytes);
    const mesh = new Mesh();
    const s = new MeshDecoder().decode(buffer, mesh);
    if (!s.ok) {
        return Result.fail<DecodedMesh>("Draco stream is corrupt (" + s.err + ")");
    }
    const faces = mesh.facesFlat();
    const decoded = new Decoded();
    decoded.indices = faces.slice(0);
    decoded.vertices = mesh.numPoints();
    return Result.okv<DecodedMesh>(new DecodedMesh(mesh, decoded));
}

// The values of one attribute of a decoded mesh, by the unique id the glTF
// extension named it with. `components` is what the glTF accessor expects,
// which is what decides the width of the result. Null when the mesh has no
// attribute with that id.
export function channel(mesh: Mesh, uniqueId: u32, components: i32): Channel? {
    const attribute = mesh.attributeByUniqueId(uniqueId);
    if (attribute == null) return null;
    const c = new Channel();
    c.values = attribute.readF32s(mesh.numPoints(), components);
    return c;
}

