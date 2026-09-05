//  RenderBenchmarkTests.swift
//  How long a frame takes.
//
//  The thresholds are deliberately loose — CI machines vary and a flaky
//  performance test is worse than none — but the numbers are printed, so a
//  regression shows up as a number moving rather than only as a red test.
//
//  The two cases that matter are the extremes: a full rebuild, which is what
//  a `clear` or a resize costs, and a single dirty row, which is what typing
//  a character costs. The second is the one that has to be cheap, and the
//  whole dirty-tracking design exists to make it so.

import XCTest

final class RenderBenchmarkTests: XCTestCase {
    /// A large but plausible terminal: a maximized window on a 16" display.
    private static let columns = 200
    private static let rows = 50

    private func fill(_ h: RenderHarness) {
        // Realistic-ish content: mixed text, some styling, some colour.
        let sample =
            "for (i, entry) in results.enumerated() where entry.isValid { print(entry) } "
        for row in 0..<Self.rows {
            var text = ""
            while text.count < Self.columns { text += sample }
            h.source.write(String(text.prefix(Self.columns)), row: row)
            // A quarter of the rows carry styling, which splits shaping runs.
            if row % 4 == 0 {
                for x in 10..<30 {
                    h.source.snapshot.rowData[row].cells[x].hasStyling = true
                    h.source.snapshot.rowData[row].cells[x].flags = [.bold]
                }
            }
            if row % 7 == 0 {
                for x in 40..<60 {
                    h.source.setBackground(PackedRGB(r: 80, g: 20, b: 90), row: row, column: x)
                }
            }
        }
    }

    private func time(_ iterations: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(iterations) / 1_000_000
    }

    func testFullScreenRebuild() throws {
        let h = try RenderHarness(columns: Self.columns, rows: Self.rows)
        fill(h)

        // Warm the glyph atlas and the shaping cache; the first frame of a
        // session pays for rasterizing every glyph it sees and is not what
        // steady-state performance looks like.
        h.source.snapshot.dirty = .full
        _ = try h.render()

        let cpu = time(20) {
            h.source.snapshot.dirty = .full
            h.source.dirty = true
            h.renderer.updateFrame()
        }
        let total = time(20) {
            h.source.snapshot.dirty = .full
            h.source.dirty = true
            h.renderer.updateFrame()
            h.renderer.drawFrame(sync: true)
        }
        let ms = total

        print(
            String(
                format: "full rebuild %dx%d: %.3f ms/frame (%.0f fps) [cpu %.3f, gpu+submit %.3f]",
                Self.columns, Self.rows, ms, 1000 / ms, cpu, total - cpu))
        // 10,000 cells rebuilt, shaped and drawn should fit inside a 120 Hz
        // frame with room to spare.
        XCTAssertLessThan(ms, 8.0, "a full rebuild should fit in a frame")
    }

    func testSingleRowUpdate() throws {
        let h = try RenderHarness(columns: Self.columns, rows: Self.rows)
        fill(h)
        h.source.snapshot.dirty = .full
        _ = try h.render()

        var counter = 0
        func dirtyOneRow() {
            counter += 1
            // Change one row, as typing a character does.
            let row = counter % Self.rows
            h.source.snapshot.rowData[row].cells[counter % Self.columns].codepoint =
                UInt32(0x41 + (counter % 26))
            h.source.snapshot.dirty = .partial
            for i in h.source.snapshot.rowDirty.indices {
                h.source.snapshot.rowDirty[i] = (i == row)
            }
            h.source.dirty = true
        }

        let cpu = time(200) {
            dirtyOneRow()
            h.renderer.updateFrame()
        }
        let total = time(200) {
            dirtyOneRow()
            h.renderer.updateFrame()
            h.renderer.drawFrame(sync: true)
        }
        let ms = total

        print(
            String(
                format: "single row of %d: %.3f ms/frame [cpu %.3f, gpu+submit %.3f]",
                Self.columns, ms, cpu, total - cpu))
        // One dirty row out of fifty must be far cheaper than fifty.
        XCTAssertLessThan(ms, 3.0, "a one-row update should be nearly free")
    }

    /// The shaping cache is the difference between shaping every run every
    /// frame and shaping none of them, so check it is actually working.
    func testShapingCacheMakesRepeatFramesFaster() throws {
        let h = try RenderHarness(columns: Self.columns, rows: Self.rows)
        fill(h)

        let cold = time(1) {
            h.source.snapshot.dirty = .full
            h.source.dirty = true
            h.renderer.updateFrame()
            h.renderer.drawFrame(sync: true)
        }
        let warm = time(10) {
            h.source.snapshot.dirty = .full
            h.source.dirty = true
            h.renderer.updateFrame()
            h.renderer.drawFrame(sync: true)
        }

        print(String(format: "cold %.3f ms, warm %.3f ms (%.1fx)", cold, warm, cold / warm))
        XCTAssertLessThan(warm, cold, "warm frames should be faster than the first")
    }
}
