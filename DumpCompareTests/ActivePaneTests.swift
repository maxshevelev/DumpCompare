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
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-pane-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func makeComparisonView() throws -> (ComparisonView, NSWindow, URL, URL) {
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 1024))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 1024))
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

    // MARK: - Caret visibility & mirror (§3.3)

    /// The caret is drawn only on the active pane; the inactive pane mirrors it
    /// with a thin frame around the byte at that offset. Selections are synced
    /// between panes, so the inactive pane's own selection start is the offset
    /// to frame.
    func testInactivePaneMirrorsActiveCaret() throws {
        let (cv, window, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let hex1 = try hexView(of: cv.paneView1)
        let hex2 = try hexView(of: cv.paneView2)

        // Wire the companion pair the way MainViewController does (§9), so
        // selections stay in sync across panes.
        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Pane 2 becomes active; pane 1 must stop showing its own caret and
        // start mirroring instead.
        cv.setActive(1)
        XCTAssertFalse(hex1.isActive)
        XCTAssertTrue(hex2.isActive)

        // Move the active pane's caret to byte 7 of row 0.
        click(hex2, at: byteCentre(hex2, row: 0, column: 7), window: window)

        // The selection synced to pane 1 (same absolute offset).
        XCTAssertEqual(cv.paneView1.viewModel.hexSelection().start, 7)

        let rects = hex1.mirrorFrameRects()
        XCTAssertEqual(rects.count, 2, "mirror frames the hex cell and the ASCII char")
        let layout = hex1.hexLayout
        XCTAssertEqual(rects[0], layout.hexByteFrame(row: 0, column: 7))
        XCTAssertEqual(rects[1].minX, layout.asciiX(column: 7))
        XCTAssertEqual(rects[1].minY, layout.hexByteFrame(row: 0, column: 7).minY)

        // The active pane draws no mirror frame.
        XCTAssertTrue(hex2.mirrorFrameRects().isEmpty)
    }

    /// When the active pane's caret is at EOF there is no byte to mirror, so the
    /// inactive pane draws no frame.
    func testMirrorAbsentAtEOF() throws {
        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        cv.setActive(1)
        vm2.moveCaret(to: 1024)  // EOF of both 1024-byte files

        let hex1 = try hexView(of: cv.paneView1)
        XCTAssertFalse(hex1.isActive)
        XCTAssertTrue(hex1.mirrorFrameRects().isEmpty)
    }
}
