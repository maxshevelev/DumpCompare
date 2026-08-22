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
///
/// The two alignment tests below sample the **ink `draw(_:)` actually put on the
/// strip** rather than reading `labelFrames()`. `labelFrames()` is a second
/// implementation of `draw`'s arithmetic written for the tests, so asserting it
/// against the expressions it is built from let the two drift apart with both
/// tests green. Sampling the render tests the code that ships. The expectations
/// are the grid's own `HexLayout` positions — `HexLayoutTests` pins those to
/// absolute points at a known `charWidth`, while the header's `charWidth` comes
/// from whatever monospaced font the system supplies, so absolute points here
/// would be machine metrics rather than a rule.
@MainActor
final class HexColumnHeaderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private var windows: [NSWindow] = []

    /// A real pane with a file open, in a real window: the header needs a size
    /// to draw into, and the dump needs a clip view that can actually scroll.
    private func makePane(_ bytes: [UInt8], width: CGFloat = 900)
        throws -> (FilePaneView, HexColumnHeaderView, HexView) {
        let url = try tempFile(bytes)
        let viewModel = PaneViewModel()
        try viewModel.open(url: url)
        let pane = FilePaneView(viewModel: viewModel)
        let window = makeTestWindow(width: width, height: 400)
        let content = try XCTUnwrap(window.contentView)
        pane.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pane.topAnchor.constraint(equalTo: content.topAnchor),
            pane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.layoutIfNeeded()
        windows.append(window)
        let header = try XCTUnwrap(pane.subviews.compactMap { $0 as? HexColumnHeaderView }.first)
        let hexView = try XCTUnwrap(pane.scrollView.documentView as? HexView)
        addTeardownBlock { @MainActor in viewModel.close() }
        return (pane, header, hexView)
    }

    // MARK: - Reading the ink the header draws

    /// The strip as rendered by its own `draw(_:)`.
    private func render(_ header: HexColumnHeaderView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(header.bitmapImageRepForCachingDisplay(in: header.bounds))
        header.cacheDisplay(in: header.bounds, to: rep)
        return rep
    }

    /// How blue a pixel is. The header's ink is a desaturated blue in both
    /// appearances (§6) while the strip's paper is neutral, so blue-minus-red
    /// separates glyph from background without an appearance-dependent
    /// threshold.
    private func blueness(_ colour: NSColor) -> CGFloat {
        guard let rgb = colour.usingColorSpace(.deviceRGB) else { return 0 }
        return rgb.blueComponent - rgb.redComponent
    }

    /// The leftmost x (in the header's points) carrying ink between `x0` and
    /// `x1`, or nil where nothing was drawn.
    ///
    /// The bottom 2 pt are skipped: the ink-blue rule under the labels runs the
    /// strip's whole width and would answer every probe.
    private func firstInkX(in rep: NSBitmapImageRep, of header: HexColumnHeaderView,
                           from x0: CGFloat, to x1: CGFloat) -> CGFloat? {
        let scaleX = CGFloat(rep.pixelsWide) / header.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / header.bounds.height
        let rows = min(rep.pixelsHigh, Int(max(0, header.bounds.height - 2) * scaleY))
        var px = max(0, Int((x0 * scaleX).rounded(.down)))
        let last = min(rep.pixelsWide - 1, Int((x1 * scaleX).rounded(.up)))
        while px <= last {
            for py in 0..<rows {
                if let colour = rep.colorAt(x: px, y: py), blueness(colour) > 0.1 {
                    return CGFloat(px) / scaleX
                }
            }
            px += 1
        }
        return nil
    }

    /// Where the ink of the label over byte `column` starts, given a strip
    /// shifted left by `shift` points. The probe window is the cell itself plus
    /// a point of slack — a glyph's ink begins to the *right* of its origin, and
    /// reaching any further left would catch the label before it.
    private func indexInkX(in rep: NSBitmapImageRep, of header: HexColumnHeaderView,
                           layout: HexLayout, column: Int, shift: CGFloat = 0) -> CGFloat? {
        let cellX = layout.hexByteX(column: column) - shift
        return firstInkX(in: rep, of: header, from: cellX - 1, to: cellX + layout.hexByteWidth)
    }

    /// A glyph's left side bearing puts its first inked pixel a fraction of a
    /// character right of the drawing origin, and the render is sampled at
    /// device-pixel resolution. Both are far below the 3-character pitch
    /// between two byte-offset indices, so this tolerance cannot let a label
    /// pass for its neighbour.
    private let inkTolerance: CGFloat = 3

    // MARK: - Alignment (§6)

    /// The labels align with the columns they name: the offset title at the
    /// offset column's left edge, one byte-offset index ("00".."0F") over each
    /// hex cell, and the ASCII title at the ASCII column's left edge — asserted
    /// against the ink the header really draws.
    func testLabelsAlignWithTheColumnsTheyName() throws {
        let (_, header, hexView) = try makePane([UInt8](repeating: 0x55, count: 64))
        let layout = hexView.hexLayout
        XCTAssertEqual(header.horizontalOffset, 0,
                       "premise: the dump is not scrolled sideways")
        XCTAssertGreaterThan(header.bounds.width, layout.contentWidth,
                             "premise: the whole row fits the strip, so every label is drawn")

        let rep = try render(header)

        XCTAssertEqual(try XCTUnwrap(firstInkX(in: rep, of: header,
                                               from: 0, to: layout.hexByteX(column: 0) - 1),
                                     "no offset title drawn"),
                       layout.leftPadding, accuracy: inkTolerance,
                       "the offset title starts at the offset column's own left edge")

        for column in 0..<HexLayout.bytesPerRow {
            let ink = try XCTUnwrap(indexInkX(in: rep, of: header, layout: layout, column: column),
                                    "no byte-offset index drawn over byte \(column)")
            XCTAssertEqual(ink, layout.hexByteX(column: column), accuracy: inkTolerance,
                           "byte \(column)'s index must sit over byte \(column)'s cell")
        }

        XCTAssertEqual(try XCTUnwrap(firstInkX(in: rep, of: header,
                                               from: layout.asciiX(column: 0) - layout.gapBeforeAscii / 2,
                                               to: layout.contentWidth),
                                     "no decoded-text title drawn"),
                       layout.asciiX(column: 0), accuracy: inkTolerance,
                       "the decoded-text title starts at the ASCII column's left edge")
    }

    /// Scrolling the dump sideways moves the header with it (§6).
    ///
    /// The behaviour worth pinning is the clip-view observer in `FilePaneView`,
    /// which is what *sets* `horizontalOffset`: without it the labels stand
    /// still while the columns slide out from under them. A per-label loop over
    /// an offset the test assigned itself never touches that wiring, so the
    /// scroll is driven through the real clip view here.
    func testScrollingTheDumpMovesTheHeaderWithIt() throws {
        // Narrower than one hex row, so the dump genuinely has somewhere to go.
        let (pane, header, hexView) = try makePane([UInt8](repeating: 0x55, count: 64), width: 300)
        let layout = hexView.hexLayout
        XCTAssertLessThan(pane.bounds.width, layout.contentWidth,
                          "premise: the row is wider than the pane, so the dump can scroll sideways")
        // In a pane this narrow the caret reveal in `refresh()` has already
        // nudged the clip view to the caret's column, so the strip starts out
        // shifted. Put the dump back at the row's start for a known baseline.
        pane.scrollView.contentView.scroll(to: .zero)
        pane.scrollView.reflectScrolledClipView(pane.scrollView.contentView)
        XCTAssertTrue(pumpUntil(2) { header.horizontalOffset == 0 },
                      "premise: the header starts level with an unscrolled dump")
        let before = try XCTUnwrap(indexInkX(in: try render(header), of: header,
                                             layout: layout, column: 0),
                                   "byte 0's index must be on screen before the scroll")

        pane.scrollView.contentView.scroll(to: NSPoint(x: 40, y: 0))
        pane.scrollView.reflectScrolledClipView(pane.scrollView.contentView)

        XCTAssertTrue(pumpUntil(2) { header.horizontalOffset == 40 },
                      "the pane must hand the header the dump's new scroll offset, got \(header.horizontalOffset)")
        let after = try XCTUnwrap(indexInkX(in: try render(header), of: header,
                                            layout: layout, column: 0, shift: 40),
                                  "byte 0's index must have moved 40 pt left, not vanished")
        XCTAssertEqual(before - after, 40, accuracy: 1,
                       "the label moves exactly as far as the dump did")
    }

    /// The header is one hex row tall plus vertical padding and sits pinned above
    /// the scroll view (a direct subview of the pane, never scrolls vertically)
    /// and counts toward the window's zoom-to-fit height.
    func testHeaderIsAPinnedStripAboveTheScrollViewCountingTowardFitHeight() throws {
        let (pane, header, _) = try makePane([UInt8](repeating: 0x55, count: 64))
        let subviews = pane.subviews

        XCTAssertTrue(subviews.contains { $0 is PaneHeaderView })
        XCTAssertTrue(subviews.contains { $0 is HexColumnHeaderView })
        // The scroll view now shares the pane with the Search All results panel
        // through a split view (§11), which is the pane's arranged dump pane.
        let split = try XCTUnwrap(subviews.compactMap { $0 as? NSSplitView }.first)
        XCTAssertTrue(split.arrangedSubviews[0] === pane.scrollView)

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
        let (pane, header, _) = try makePane([UInt8](repeating: 0x55, count: 64))
        let before = header.gridRefreshCount

        UserDefaults.standard.set(4, forKey: WordSize.userDefaultsKey)
        WordSize.set(.four)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(header.gridRefreshCount, before + 1,
                       "the pane must ask the header to rebuild when the word size changes")
        XCTAssertNotNil(pane.window, "the pane stayed in its window for the test's lifetime")
    }

}

