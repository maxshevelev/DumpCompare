import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §6 column header: a pinned strip above the dump naming the columns — "Offset",
/// the sequential byte offsets "00".."0F" over the hex cells, and "Decoded
/// text" — in ink blue, separated from the rows by a thin rule.
///
/// The header must never scroll vertically (it sits outside the scroll view)
/// and must mirror the horizontal scroll so each label tracks the column it
/// names. The label positions are the same grid geometry the rows use, so they
/// align with the first row's cells.
@MainActor
final class HexColumnHeaderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("colheader-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    /// A real pane with a file open, so the header's hexView geometry is live.
    private func makePane(_ bytes: [UInt8]) throws -> (FilePaneView, HexColumnHeaderView, HexView, URL) {
        let url = try tempFile(bytes)
        let viewModel = PaneViewModel()
        try viewModel.open(url: url)
        let pane = FilePaneView(viewModel: viewModel)
        let stack = try XCTUnwrap(pane.subviews.compactMap { $0 as? NSStackView }.first)
        let header = try XCTUnwrap(stack.arrangedSubviews[1] as? HexColumnHeaderView)
        let hexView = try XCTUnwrap(pane.scrollView.documentView as? HexView)
        // A window-less pane has a zero-size clip view, so refresh()'s
        // `revealCaret` → `scrollToVisible` nudges the clip origin to the caret
        // column, firing the mirroring observer. In a window the caret row is
        // already visible and no scroll happens. Pin the unscrolled baseline.
        header.horizontalOffset = 0
        return (pane, header, hexView, url)
    }

    /// The labels align with the columns they name: the offset title at the
    /// offset column's left edge, one byte-offset index ("00".."0F") over each
    /// hex cell, and the ASCII title at the ASCII column's left edge.
    func testLabelsAlignWithTheColumnsTheyName() throws {
        let (_, header, hexView, url) = try makePane([UInt8](repeating: 0x55, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = hexView.hexLayout

        let frames = header.labelFrames()

        XCTAssertEqual(frames.offset.minX, layout.leftPadding, accuracy: 0.01)
        XCTAssertEqual(frames.columns.count, HexLayout.bytesPerRow)
        // One index per byte: the first over byte 0's cell, the last over byte
        // 15's. Adjacent indices follow the same column pitch as the cells —
        // with 1-byte words each byte is its own word, so the pitch includes
        // the inter-word gap.
        XCTAssertEqual(frames.columns.first!.minX, layout.hexByteX(column: 0), accuracy: 0.01)
        XCTAssertEqual(frames.columns.last!.minX, layout.hexByteX(column: 15), accuracy: 0.01)
        XCTAssertEqual(frames.columns[1].minX - frames.columns[0].minX,
                       layout.hexByteWidth + layout.hexByteGap, accuracy: 0.01)
        XCTAssertEqual(frames.ascii.minX, layout.asciiX(column: 0), accuracy: 0.01)
        // The labels sit in the header's strip: one hex row plus symmetric
        // top/bottom padding (§6).
        XCTAssertEqual(frames.offset.height,
                       layout.rowHeight + 2 * HexColumnHeaderView.verticalPadding, accuracy: 0.01)
    }

    /// Mirrors the scroll view's horizontal offset: every label shifts left by
    /// the same amount, keeping the columns in registration while scrolling.
    func testHorizontalOffsetShiftsEveryLabelByTheSameAmount() throws {
        let (_, header, _, url) = try makePane([UInt8](repeating: 0x55, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }

        let before = header.labelFrames()
        header.horizontalOffset = 47
        let after = header.labelFrames()

        XCTAssertEqual(before.offset.minX - after.offset.minX, 47, accuracy: 0.01)
        XCTAssertEqual(before.columns.first!.minX - after.columns.first!.minX, 47, accuracy: 0.01)
        XCTAssertEqual(before.columns.last!.minX - after.columns.last!.minX, 47, accuracy: 0.01)
        XCTAssertEqual(before.ascii.minX - after.ascii.minX, 47, accuracy: 0.01)
    }

    /// The header is one hex row tall plus vertical padding and sits in the pane
    /// stack above the scroll view, so it is pinned (never scrolls vertically)
    /// and counts toward the window's zoom-to-fit height.
    func testHeaderIsAPinnedStripAboveTheScrollViewCountingTowardFitHeight() throws {
        let (pane, header, hexView, url) = try makePane([UInt8](repeating: 0x55, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let stack = try XCTUnwrap(pane.subviews.compactMap { $0 as? NSStackView }.first)

        XCTAssertTrue(stack.arrangedSubviews[0] is PaneHeaderView)
        XCTAssertTrue(stack.arrangedSubviews[1] is HexColumnHeaderView)
        XCTAssertTrue(stack.arrangedSubviews[2] === pane.scrollView)

        XCTAssertEqual(header.headerHeight,
                       hexView.hexLayout.rowHeight + 2 * HexColumnHeaderView.verticalPadding, accuracy: 0.01)
        XCTAssertEqual(
            pane.contentFitHeight,
            pane.hexContentHeight + FilePaneView.headerHeight + FilePaneView.statusBarHeight + header.headerHeight,
            accuracy: 0.01
        )
    }

    /// Changing the word size must make the pane ask the header to rebuild
    /// (§6): the grid regroups, so the labels have to be redrawn at the new
    /// column positions instead of lingering at the old ones. (The request is
    /// observed via `gridRefreshCount` — `needsDisplay` isn't readable in a
    /// headless test host.)
    func testWordSizeChangeRebuildsHeader() throws {
        // The pane must stay alive for the test's lifetime: it owns the
        // observer that asks the header to rebuild, and dropping it would
        // deallocate it and remove the observer.
        let (pane, header, _, url) = try makePane([UInt8](repeating: 0x55, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let before = header.gridRefreshCount

        UserDefaults.standard.set(4, forKey: WordSize.userDefaultsKey)
        WordSize.set(.four)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(header.gridRefreshCount, before + 1,
                       "the pane must ask the header to rebuild when the word size changes")
    }

    /// The offset column and the header share the ink-blue color, and it
    /// resolves blue-dominant in both light and dark appearances.
    func testInkBlueResolvesBlueDominantInLightAndDark() throws {
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            // NSColor(name:) dynamic colors resolve against the drawing
            // appearance; performAsCurrentDrawingAppearance pins it for the
            // resolution so components can be read.
            var resolved = NSColor.white
            appearance.performAsCurrentDrawingAppearance {
                resolved = HexTheme.inkBlue.usingColorSpace(.deviceRGB)!
            }
            let r = resolved.redComponent
            let g = resolved.greenComponent
            let b = resolved.blueComponent
            XCTAssertGreaterThan(b, r, "ink blue in \(name.rawValue) must be blue-dominant")
            XCTAssertGreaterThan(b, g, "ink blue in \(name.rawValue) must be blue-dominant")
        }
    }
}
