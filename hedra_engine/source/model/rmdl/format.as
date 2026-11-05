// The .rmdl model format (milestone 60): what every reader and writer of a
// model document agrees on. An .rmdl is an XML document of the model at a
// moment, written like an .rscn (docs/formats/RMDL.md is the normative
// description; docs/formats/RSCN.md the conventions it shares):
//
//   <?xml version="1.0" encoding="UTF-8"?>
//   <rmdl format="1" uid="rmdl://bench">
//     <ext_resource id="1_wood" type="Texture2D" path="textures/wood.png"/>
//     <sub_resource id="Material_0" type="Material"> ... </sub_resource>
//     <sub_resource id="Mesh_0" type="Mesh"> ... packed arrays ... </sub_resource>
//     <scene> ... the session ... </scene>
//     <object name="Seat" type="mesh"> ... </object>
//   </rmdl>
//
// The modules: doc.as (the head: uid, metadata), read.as (the reader),
// write.as (the canonical writer), validate.as (every problem of a file, for
// `check`), scan.as (the files a document names, without building it),
// schema.as (the elements and their properties, against the data form's
// records). Errors and diagnostics are the scene format's (SceneryError,
// Diagnostics: engine/src/scene/error.as), at file:line:column, with the
// codes .rscn uses for what both formats check and the codes below for
// what only a model has.

// The format version this build reads and writes.
export const RMDL_FORMAT: i32 = 1;
// The root element.
export const RMDL_ROOT = "rmdl";
// The scheme of a document's uid (kept, not interpreted: `rmdl://bench`).
export const RMDL_UID_SCHEME = "rmdl://";

// The codes only a model document gives (the shared ones are .rscn's:
// xml-syntax, root-element, format-missing, format-unsupported,
// attribute-missing, attribute-invalid, text-unexpected, element-order,
// property-content, property-duplicate, value-syntax, id-invalid,
// id-duplicate, path-invalid, ext-type-extension, ext-type-unknown,
// sub-type-unknown, resource-undeclared, element-unknown,
// attribute-unknown, property-unknown).
//
// A command file named .rmdl (its first line `# rmdlcmd 1`, `# rmdl 1`, or
// a command): the hint says how to rename and convert it.
export const E_RMDL_COMMAND_FILE = "rmdl-command-file";
// A value that does not fit the model: a count that is not the arrays',
// an id or a reference out of range, a mesh object without its mesh; the
// message names the property.
export const E_RMDL_INVALID = "rmdl-invalid";
// Two objects with one name (objects are named by references).
export const E_RMDL_NAME_DUPLICATE = "rmdl-name-duplicate";
// A reference by name (a parent, a modifier's or a constraint's object, a
// bone, the active object or vertex group) that names nothing.
export const E_RMDL_NAME_MISSING = "rmdl-name-missing";
// A resource of the wrong type where a property names one (an object's
// `data` that is no Mesh or Armature, a material slot that is no
// Material, a texture that is no Texture2D).
export const E_RMDL_RESOURCE_TYPE = "rmdl-resource-type";
// One Mesh or Armature named by two objects (each object owns its data).
export const E_RMDL_RESOURCE_SHARED = "rmdl-resource-shared";
// A warning: a sub_resource no object or material slot uses.
export const W_RMDL_RESOURCE_UNUSED = "rmdl-resource-unused";
// A warning (check only): an import's source whose bytes no longer hash as
// recorded (the file changed since the geometry was copied).
export const W_RMDL_IMPORT_CHANGED = "rmdl-import-changed";
// A warning (check only): a comment or a processing instruction, which the
// model does not hold, so that a rewrite drops it (`hedra format` refuses
// to without --force, and names this check).
export const W_RMDL_DROPPED = "rmdl-dropped";
// The writer: a scene it cannot write (two objects with one name, a
// reference to an empty slot: only a hand-written data form makes them; a
// name holding a character XML cannot hold).
export const E_RMDL_WRITE = "rmdl-write";
