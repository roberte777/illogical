//  RendererTestAccess.swift
//  Convenience accessors for the renderer's snapshot.

import Foundation

extension TerminalRenderer {
    func snapshotCell(_ column: Int, _ row: Int) -> RenderCell? {
        guard row < snapshot.rowData.count, column < snapshot.rowData[row].cells.count
        else { return nil }
        return snapshot.rowData[row].cells[column]
    }
}
