//  SurfaceSizeTestSupport.swift
//  A grid with a plausible cell attached to it.
//
//  Tests about reconnects and lifecycles care about cols and rows and nothing
//  else, but `SurfaceSize` carries a cell too — and a zero cell is a real
//  value with a real meaning ("this client has no font"), so it is the wrong
//  thing to write into a test that is not about that. These numbers are one
//  JetBrains Mono cell at 2x, which is what the app actually reports.

import Foundation

extension SurfaceSize {
    static func test(cols: UInt16, rows: UInt16) -> SurfaceSize {
        SurfaceSize(cols: cols, rows: rows, cell: CellSize(width: 16, height: 38))
    }
}
