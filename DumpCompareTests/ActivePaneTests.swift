import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3: the highlighted pane and the pane the user actually types into must
/// never diverge. Focus is the single source of truth — clicking the hex dump
/// makes its hex view first responder, which fires `onActivate`, which drives
/// the active-pane highlight. Chrome clicks (the header) route through the same
/// path (`focusHexView`), so every way of switching panes agrees.
///
/// Driven through the real `ComparisonView` and real hex views (same harness as
/// `HeaderFitWidthTests`): a synthesized click on a pane's dump or header must
/// produce the right `onPaneActivated` index and leave the window's first
/// responder on that pane's hex view.
@MainActor
final class ActivePaneTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "ComparisonPaneLayoutIsVertical")
        // The contour-padding rules depend on the word size; pin it so the
        // suite isn't at the mercy of whatever the shared defaults hold.
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-pane-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func makeComparisonView(bytes1: [UInt8]? = nil, bytes2: [UInt8]? = nil) throws -> (ComparisonView, NSWindow, URL, URL) {
        let url1 = try tempFile(bytes1 ?? [UInt8](repeating: 0x41, count: 1024))
        let url2 = try tempFile(bytes2 ?? [UInt8](repeating: 0x42, count: 1024))
        let p1 = PaneViewModel()
        let p2 = PaneViewModel()
        try p1.open(url: url1)
        try p2.open(url: url2)
        let coordinator = ComparisonCoordinator { () -> (left: ByteStorage, right: ByteStorage)? in
            guard let l = p1.byteStorage, let r = p2.byteStorage else { return nil }
            return (l, r)
        }
        let cv = ComparisonView(coordinator: coordinator,
                                paneView1: FilePaneView(viewModel: p1),
                                paneView2: FilePaneView(viewModel: p2))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        cv.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            cv.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            cv.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.layoutIfNeeded()
        return (cv, window, url1, url2)
    }

    /// The real header view of a pane (first row of its vertical stack).
    private func header(of pane: FilePaneView) throws -> PaneHeaderView {
        let stack = try XCTUnwrap(pane.subviews.compactMap({ $0 as? NSStackView }).first)
        return try XCTUnwrap(stack.arrangedSubviews.first as? PaneHeaderView)
    }

    private func hexView(of pane: FilePaneView) throws -> HexView {
        try XCTUnwrap(pane.scrollView.documentView as? HexView)
    }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Window point of the centre of byte `column` in `row` — a real clickable
    /// spot inside the hex grid.
    private func byteCentre(_ hexView: HexView, row: Int, column: Int) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.hexByteX(column: column) + layout.charWidth,
                            y: CGFloat(row) * layout.rowHeight)
        return hexView.convert(local, to: nil)
    }

    private func click(_ view: NSView, at p: NSPoint, window: NSWindow) {
        view.mouseDown(with: mouse(.leftMouseDown, at: p, window: window))
    }

    /// Clicking a pane's hex dump must activate that pane — the highlight
    /// follows where typing goes (the first responder).
    func testClickingHexDumpActivatesThatPane() throws {
        let (cv, window, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        var activated: [Int] = []
        cv.onPaneActivated = { activated.append($0) }

        let hex2 = try hexView(of: cv.paneView2)
        click(hex2, at: byteCentre(hex2, row: 0, column: 4), window: window)

        XCTAssertEqual(activated, [1])
        XCTAssertTrue(window.firstResponder === hex2,
                      "the clicked dump's hex view must hold first responder")
    }

    /// Clicking pane 1 after pane 2 has focus must switch activation back.
    func testClickingOtherDumpSwitchesActivation() throws {
        let (cv, window, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        var activated: [Int] = []
        cv.onPaneActivated = { activated.append($0) }

        let hex2 = try hexView(of: cv.paneView2)
        let hex1 = try hexView(of: cv.paneView1)
        click(hex2, at: byteCentre(hex2, row: 0, column: 4), window: window)
        click(hex1, at: byteCentre(hex1, row: 0, column: 4), window: window)

        XCTAssertEqual(activated, [1, 0])
        XCTAssertTrue(window.firstResponder === hex1)
    }

    /// A header click must activate that pane AND move focus to its hex view —
    /// otherwise typing would go to the previously focused pane while the header
    /// says a different one is active. Both flows go through focus.
    func testHeaderClickActivatesAndFocusesPane() throws {
        let (cv, window, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        var activated: [Int] = []
        cv.onPaneActivated = { activated.append($0) }

        let header1 = try header(of: cv.paneView1)
        let hex1 = try hexView(of: cv.paneView1)
        click(header1, at: header1.convert(NSPoint(x: 20, y: header1.bounds.midY), to: nil), window: window)

        XCTAssertEqual(activated, [0])
        XCTAssertTrue(window.firstResponder === hex1,
                      "a header click must move typing focus to that pane's hex view")
    }

    /// Same guarantee from the other side: just focusing pane 2's dump must be
    /// what activates pane 2 — not a side effect of the header highlight. Then
    /// a header click on pane 1 must move both activation and focus to pane 1.
    func testFocusIsTheSingleSourceOfTruth() throws {
        let (cv, window, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        var activated: [Int] = []
        cv.onPaneActivated = { activated.append($0) }

        let hex2 = try hexView(of: cv.paneView2)
        let hex1 = try hexView(of: cv.paneView1)

        // Focusing a pane's dump alone must activate that pane.
        XCTAssertTrue(window.makeFirstResponder(hex2))
        XCTAssertEqual(activated, [1])
        XCTAssertTrue(window.firstResponder === hex2)

        // A header click then pulls both activation and focus to pane 1.
        let header1 = try header(of: cv.paneView1)
        click(header1, at: header1.convert(NSPoint(x: 20, y: header1.bounds.midY), to: nil), window: window)

        XCTAssertEqual(activated, [1, 0])
        XCTAssertTrue(window.firstResponder === hex1)
    }

    // MARK: - Selection independence & mirror (§3.3)

    /// Selections are independent per pane: moving one pane's selection leaves
    /// the other pane's selection untouched. The opposite pane's selection is
    /// *mirrored* as a single closed contour — one loop of line segments around
    /// the whole selected span in the hex column, one in the ASCII column.
    func testOppositePaneMirrorsSelectionWithContour() throws {
        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Pane 2 selects bytes 4…9 (range end exclusive).
        vm2.setSelection(SelectionModel(start: 4, end: 10, fileSize: 1024))

        // Pane 1 mirrors pane 2's selection as one closed loop around the hex
        // span and one around the ASCII span, padded off the glyphs.
        let hex1 = try hexView(of: cv.paneView1)
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2, "one loop around the hex span, one around the ASCII span")
        let layout = hex1.hexLayout
        let pad = HexView.mirrorContourPadding
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 4) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 9) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 9) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 4) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
        // The ASCII loop hugs the characters: no word gaps in the ASCII column,
        // so only its outer edges (column 0, column 15) get padding — a
        // mid-column selection sits flush against the neighbor chars.
        XCTAssertEqual(loops[1], [
            CGPoint(x: layout.asciiX(column: 4), y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 9) + layout.charWidth, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 9) + layout.charWidth, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.asciiX(column: 4), y: layout.rowFrame(row: 0).maxY),
        ])

        // The panes' selections are independent: pane 1's own selection is
        // still a caret at 0.
        XCTAssertTrue(vm1.hexSelection().isEmpty)
        XCTAssertEqual(vm1.hexSelection().start, 0)

        // Mirroring is symmetric — pane 2 mirrors pane 1's selection too. Pane
        // 1 is at a bare caret; a caret mirror lands only on the opposite
        // (inactive) pane, and pane 2 is the active one here, so nothing is
        // drawn.
        let hex2 = try hexView(of: cv.paneView2)
        XCTAssertTrue(hex2.mirrorContours().isEmpty)
    }

    /// A mirrored selection is clamped to this pane's file size: the contour
    /// stops at this pane's EOF, never past it (§9: shorter pane clamps to EOF).
    func testMirrorClampsToPaneFileSize() throws {
        let (cv, _, url1, url2) = try makeComparisonView(
            bytes1: [UInt8](repeating: 0x41, count: 8),   // pane 1 is shorter
            bytes2: [UInt8](repeating: 0x42, count: 1024)
        )
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Pane 2 selects bytes 0…15; pane 1 has only 8 bytes, so its mirror
        // contour stops at byte 7 (the hex loop covers columns 0…7).
        vm2.setSelection(SelectionModel(start: 0, end: 16, fileSize: 1024))

        let hex1 = try hexView(of: cv.paneView1)
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2, "hex loop + ASCII loop")
        let layout = hex1.hexLayout
        let pad = HexView.mirrorContourPadding
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 7) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 7) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
        // Left edge at column 0 pads into the gap before the ASCII column; the
        // right edge at column 7 is not the column's outer edge, so it stays
        // flush against column 8's neighbor (nothing selected there).
        XCTAssertEqual(loops[1], [
            CGPoint(x: layout.asciiX(column: 0) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 7) + layout.charWidth, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 7) + layout.charWidth, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.asciiX(column: 0) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
    }

    /// A mirrored selection spanning several rows becomes one closed loop per
    /// column — a rectangle around the whole span with no seam at the row
    /// boundary.
    func testMirrorContourSpansFullRows() throws {
        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Pane 2 selects rows 1 and 2 in full (bytes 16…47, end exclusive).
        vm2.setSelection(SelectionModel(start: 16, end: 48, fileSize: 1024))

        let hex1 = try hexView(of: cv.paneView1)
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2, "one loop around the whole hex span, one around the whole ASCII span")
        let layout = hex1.hexLayout
        let pad = HexView.mirrorContourPadding
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 1).minY),
            CGPoint(x: layout.hexByteX(column: 15) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 1).minY),
            CGPoint(x: layout.hexByteX(column: 15) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 2).maxY),
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 2).maxY),
        ])
        XCTAssertEqual(loops[1], [
            CGPoint(x: layout.asciiX(column: 0) - pad, y: layout.rowFrame(row: 1).minY),
            CGPoint(x: layout.asciiX(column: 15) + layout.charWidth + pad, y: layout.rowFrame(row: 1).minY),
            CGPoint(x: layout.asciiX(column: 15) + layout.charWidth + pad, y: layout.rowFrame(row: 2).maxY),
            CGPoint(x: layout.asciiX(column: 0) - pad, y: layout.rowFrame(row: 2).maxY),
        ])
    }

    /// A selection that starts and ends mid-row steps the contour inward on the
    /// first row's left and the last row's right — one closed outline tracing
    /// the whole selection, not per-row frames.
    func testMirrorContourStepsAroundPartialRows() throws {
        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Rows 0 (cols 4–15), 1 (all), and 2 (cols 0–5).
        vm2.setSelection(SelectionModel(start: 4, end: 38, fileSize: 1024))

        let hex1 = try hexView(of: cv.paneView1)
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2)
        let layout = hex1.hexLayout
        let pad = HexView.mirrorContourPadding
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 4) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 15) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 15) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 2).minY),
            CGPoint(x: layout.hexByteX(column: 5) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 2).minY),
            CGPoint(x: layout.hexByteX(column: 5) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 2).maxY),
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 2).maxY),
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 4) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
    }

    /// With words larger than one byte, the hex contour pads only at word
    /// boundaries (where a spacer already exists): a selection starting or
    /// ending mid-word stays flush there, since padding would push the line
    /// onto the neighbor glyph. The ASCII column pads only at its outer edges.
    func testMirrorContourPadsOnlyAtWordBoundaries() throws {
        let previousWordSize = UserDefaults.standard.integer(forKey: WordSize.userDefaultsKey)
        UserDefaults.standard.set(2, forKey: WordSize.userDefaultsKey)
        defer { UserDefaults.standard.set(previousWordSize, forKey: WordSize.userDefaultsKey) }

        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        let hex1 = try hexView(of: cv.paneView1)
        let layout = hex1.hexLayout
        XCTAssertEqual(layout.wordSize, 2, "test expects 2-byte words")

        // Selection over columns 1…3 (bytes 1…3). Column 1 is mid-word (the
        // word 0–1 runs across it) and column 3 ends a word, so only the right
        // edge pads into the word spacer; the left edge stays flush.
        vm2.setSelection(SelectionModel(start: 1, end: 4, fileSize: 1024))
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2)
        let pad = HexView.mirrorContourPadding
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 1), y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 3) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 3) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 1), y: layout.rowFrame(row: 0).maxY),
        ])
        // The ASCII column packs characters with no spacers, so a mid-column
        // selection is flush on both sides.
        XCTAssertEqual(loops[1], [
            CGPoint(x: layout.asciiX(column: 1), y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 3) + layout.charWidth, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 3) + layout.charWidth, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.asciiX(column: 1), y: layout.rowFrame(row: 0).maxY),
        ])

        // Word-aligned edges (columns 0…3, both on word boundaries) pad fully.
        vm2.setSelection(SelectionModel(start: 0, end: 4, fileSize: 1024))
        XCTAssertEqual(hex1.mirrorContours()[0], [
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 3) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 3) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
    }

    /// A bare caret on the active pane mirrors onto the inactive pane as a
    /// single-byte contour — the same closed-contour treatment a selection
    /// gets, so the byte under the caret stays visible in the other file
    /// (§3.3). The active pane itself draws no caret contour: its own caret
    /// bar and cross-column link already mark the byte.
    func testBareCaretMirrorsOnInactivePane() throws {
        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Pane 2 becomes active and its caret moves to byte 7; pane 1 mirrors
        // it as one loop around the hex byte and one around the ASCII char.
        cv.setActive(1)
        vm2.moveCaret(to: 7)

        XCTAssertEqual(vm1.caretOffset, 0, "selections are independent")
        let hex1 = try hexView(of: cv.paneView1)
        XCTAssertFalse(hex1.isActive)
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2, "one loop around the hex byte, one around the ASCII char")
        let layout = hex1.hexLayout
        let pad = HexView.mirrorContourPadding
        // Word size 1: both edges of byte 7 are word boundaries, so they pad.
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 7) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 7) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 7) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 7) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
        // ASCII packs its chars with no spacers: a mid-column byte is flush.
        XCTAssertEqual(loops[1], [
            CGPoint(x: layout.asciiX(column: 7), y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 7) + layout.charWidth, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 7) + layout.charWidth, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.asciiX(column: 7), y: layout.rowFrame(row: 0).maxY),
        ])

        // The active pane does not mirror the inactive pane's caret: a box on
        // the pane that owns the caret would double up on its own caret bar.
        let hex2 = try hexView(of: cv.paneView2)
        XCTAssertTrue(hex2.isActive)
        XCTAssertTrue(hex2.mirrorContours().isEmpty)
    }
}
