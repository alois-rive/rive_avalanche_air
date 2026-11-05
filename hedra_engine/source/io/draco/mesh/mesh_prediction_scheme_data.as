// Derived from draco-core 2.1.0 (Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// Shared context for mesh prediction schemes -- the corner table plus the
// data-id <-> corner mappings that mesh predictors traverse.
//
// The fields are shared references (`null` = unset). Nothing is copied: the
// arrays stay live views of the caller's data.

import { CornerTable } from "./corner_table";

export class MeshPredictionSchemeData {
    private cornerTable_: CornerTable? = null;
    private vertexToDataMap_: Array<i32>? = null;
    private dataToCornerMap_: Array<u32>? = null;

    // Everything unset.
    constructor() {}

    set(cornerTable: CornerTable, dataToCornerMap: Array<u32>, vertexToDataMap: Array<i32>): void {
        this.cornerTable_ = cornerTable;
        this.dataToCornerMap_ = dataToCornerMap;
        this.vertexToDataMap_ = vertexToDataMap;
    }

    cornerTable(): CornerTable? {
        return this.cornerTable_;
    }

    vertexToDataMap(): Array<i32>? {
        return this.vertexToDataMap_;
    }

    dataToCornerMap(): Array<u32>? {
        return this.dataToCornerMap_;
    }

    // Copies the references, not the data.
    clone(): MeshPredictionSchemeData {
        const d = new MeshPredictionSchemeData();
        d.cornerTable_ = this.cornerTable_;
        d.vertexToDataMap_ = this.vertexToDataMap_;
        d.dataToCornerMap_ = this.dataToCornerMap_;
        return d;
    }
}
