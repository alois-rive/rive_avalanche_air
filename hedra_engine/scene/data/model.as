// Rive's data model as Hedra reads it from RML (docs/plans/RIVE_MODEL.md
// sections 3.4 and 4.4): view models with their properties and instances,
// enums, and converters, independent of where they were declared (a Rive
// project's .rml files, one .rml a scene names, or a scene's own top-level
// converters). A .riv's view models stay ../riv/riv_info.as RivInfo; the
// two meet in ./source.as DataSource, which the binder resolves against.
//
// RML refers by id (`client:object`); these objects keep the ids they were
// read with (so that the writer, editor/src/scene/rml_write.as, can
// edit the file in place) and also resolve every reference to an index or
// a name, which is what the binder and the converters use. A scene's own
// converters have no ids: they are named, and reference each other by
// name (`<DataConverterGroupItem converter="A"/>`).
//
// Everything here is plain data. ./rml_read.as fills it from RML text;
// ../rscn/parse.as fills a scene's converters (Entry.converter); the
// binary scene carries the converters a scene uses (../rscnb/binds.as).

import { VmKind } from "../riv/riv_info";

// Where a declaration was written: its file as errors name it and its
// element's position (1-based line and column; 0 when made in code).
export class DataWhere {
    file: string = "";
    line: i32 = 0;
    col: i32 = 0;
}

// One property of a view model (RML ViewModelProperty<Kind>).
export class DataProperty {
    name: string = "";
    kind: VmKind = VmKind.Other;
    // The element's id as written ("0:62"), "" when none.
    id: string = "";
    // VmKind.ViewModel: the name of the view model it holds
    // (viewModelReferenceId resolved), "" when it names none.
    reference: string = "";
    // VmKind.Enum: the enum's name (enumId resolved), "" for a system enum
    // or none.
    enumName: string = "";
    // A system enum's property (ViewModelPropertyEnumSystem): its enumType
    // and its enumId as written (the DataEnumSystem's id, DataDoc
    // systemEnums; "" when it has none). Kept so that a property written
    // back (a .data.rml written from it) is still a system enum's, with its
    // values.
    enumSystem: bool = false;
    enumType: string = "";
    systemEnum: string = "";
    where: DataWhere = new DataWhere();
}

// One value of an instance (RML ViewModelInstance<Kind>), by the
// property's kind. A property an instance leaves out has no DataValue: it
// is unset (a script cannot reach it at run time: the experiment of
// docs/milestones/M42.md).
export class DataValue {
    // The property's index in its view model's `properties`.
    property: i32 = -1;
    kind: VmKind = VmKind.Other;
    number: f64 = 0;
    boolean: bool = false;
    // ARGB, sRGB with straight alpha, as RML's propertyValue="FFFFA41C".
    color: u32 = 0;
    // String values; an enum's value key.
    text: string = "";
    // VmKind.ViewModel: the name of the nested instance it holds
    // (propertyValue resolved to its instance), "" when none.
    instance: string = "";
    // The element's id as written, "" when none.
    id: string = "";
}

// One instance of a view model (RML ViewModelInstance).
export class DataInstance {
    name: string = "";
    id: string = "";
    values: Array<DataValue> = [];
    where: DataWhere = new DataWhere();

    value(property: i32): DataValue? {
        for (let i = 0; i < this.values.length; i++) if (this.values[i].property == property) return this.values[i];
        return null;
    }
}

// One view model (RML ViewModel).
export class DataViewModel {
    name: string = "";
    id: string = "";
    // viewModelType="global": one instance, bound to no artboard, shared by
    // every artboard and script of the file.
    global: bool = false;
    properties: Array<DataProperty> = [];
    instances: Array<DataInstance> = [];
    // The index in `instances` of the default one: the one
    // defaultInstanceId names in RML, else the first; -1 when none.
    defaultInstance: i32 = -1;
    where: DataWhere = new DataWhere();

    propertyIndex(name: string): i32 {
        for (let i = 0; i < this.properties.length; i++) if (this.properties[i].name == name) return i;
        return -1;
    }

    instanceIndex(name: string): i32 {
        for (let i = 0; i < this.instances.length; i++) if (this.instances[i].name == name) return i;
        return -1;
    }
}

// One custom enum (RML DataEnumCustom and its DataEnumValues).
export class DataEnum {
    name: string = "";
    id: string = "";
    // The value keys, in order.
    values: Array<string> = [];
    // Each value's DataEnumValue id as written ("" when it has none), by
    // index. RML's ViewModelInstanceEnum names its value by this id (rive
    // refuses a key there), which the reader turns into the key; the writer
    // mints one when an instance first names a value that has none.
    valueIds: Array<string> = [];
    // Each value's label (DataEnumValue value=), by index.
    labels: Array<string> = [];
    // A system enum (DataEnumSystem, with its enumType): it has no name,
    // and is in DataDoc.systemEnums rather than enums.
    system: bool = false;
    enumType: string = "";
    where: DataWhere = new DataWhere();
}

// One attribute of a converter as written (RML's own names: minInput,
// operationType, ...), its value the text.
export class DataAttr {
    name: string;
    value: string;

    constructor(name: string, value: string) {
        this.name = name;
        this.value = value;
    }
}

// One converter (RML DataConverter<Type>, or a scene's top-level element of
// the same name). `type` is the element's name ("DataConverterRangeMapper");
// `attrs` every attribute but name and id, as written, in order; a group's
// members are `items`, by name (RML's converterId resolved to the named
// converter's name); a DataConverterFormula's token children are kept in
// `children` as written (type and attrs). A converter that is not in the
// engine's catalogue still reads: building it is ../binding/converters.as's
// to refuse (binding-converter-unsupported).
export class DataConverterDecl {
    type: string = "";
    name: string = "";
    id: string = "";
    attrs: Array<DataAttr> = [];
    items: Array<string> = [];
    children: Array<DataConverterDecl> = [];
    where: DataWhere = new DataWhere();

    attr(name: string): string? {
        for (let i = 0; i < this.attrs.length; i++) if (this.attrs[i].name == name) return this.attrs[i].value;
        return null;
    }
}

// What one RML file declares of the data model (or a scene's converters:
// `viewModels` and `enums` empty).
export class DataDoc {
    // The file as errors name it.
    file: string = "";
    // Its absolute vfs path when it was read from a file ("" otherwise: a
    // bundle's blob). `file` may be a res:// path, which the editor cannot
    // open to write a value into.
    path: string = "";
    viewModels: Array<DataViewModel> = [];
    enums: Array<DataEnum> = [];
    // The system enums (DataEnumSystem) the file declares, found by id.
    systemEnums: Array<DataEnum> = [];
    converters: Array<DataConverterDecl> = [];

    viewModel(name: string): DataViewModel? {
        for (let i = 0; i < this.viewModels.length; i++) if (this.viewModels[i].name == name) return this.viewModels[i];
        return null;
    }

    converter(name: string): DataConverterDecl? {
        for (let i = 0; i < this.converters.length; i++) if (this.converters[i].name == name) return this.converters[i];
        return null;
    }

    enumNamed(name: string): DataEnum? {
        for (let i = 0; i < this.enums.length; i++) if (this.enums[i].name == name) return this.enums[i];
        return null;
    }
}

// The element names of the converters the engine evaluates (RIVE_MODEL.md
// section 3.4, its catalogue): ../binding/converters.as builds these, and
// refuses the others (DataConverterNumberToList, ListToLength, EnumToUint,
// ScriptedDataConverter) with binding-converter-unsupported.
export const CONVERTER_TYPES: StaticArray<string> = [
    "DataConverterOperation",
    "DataConverterOperationValue",
    "DataConverterOperationViewModel",
    "DataConverterSystemDegsToRads",
    "DataConverterSystemNormalizer",
    "DataConverterRangeMapper",
    "DataConverterRounder",
    "DataConverterToString",
    "DataConverterToNumber",
    "DataConverterStringPad",
    "DataConverterStringTrim",
    "DataConverterStringRemoveZeros",
    "DataConverterBooleanNegate",
    "DataConverterTrigger",
    "DataConverterInterpolator",
    "DataConverterFormula",
    "DataConverterGroup",
];

// Whether an element name is a converter's (any DataConverter*, known to
// the engine or not, and ScriptedDataConverter): what the .rscn reader takes
// as a top-level converter declaration.
export function isConverterElement(tag: string): bool {
    return (tag.startsWith("DataConverter") && tag != "DataConverterGroupItem") || tag == "ScriptedDataConverter";
}

// Whether the engine evaluates converters of element `type`.
export function isKnownConverter(type: string): bool {
    for (let i = 0; i < CONVERTER_TYPES.length; i++) if (CONVERTER_TYPES[i] == type) return true;
    return false;
}
