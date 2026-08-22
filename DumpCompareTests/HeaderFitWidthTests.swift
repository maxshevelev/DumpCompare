import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3: double-clicking a pane's header in side-by-side mode animates the
/// divider so that pane's hex content fits by width.
///
/// The window is deliberately narrow — smaller than the hex grid width — so a
/// 50/50 pane cannot show its full content. The double-click is driven through
/// the real `PaneHeaderView` so the wiring (header → ComparisonView →
/// ProportionalSplitView) is exercised, not just the math.
@MainActor
final class HeaderFitWidthTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "ComparisonPaneLayoutIsVertical")
    }

    override func tearDown() {
        removeTempFiles()
        super.tearDown()
    }

    /// Every file this class writes, deleted in `tearDown`: the test host is
    /// sandboxed, so these land in the app's own container and stay there — a
    /// few thousand of them had piled up before this was added.
    private var tempFiles: [URL] = []

    private func removeTempFiles() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
    }

    /// Builds a ComparisonView pinned into a real window of `width` points.
    private func makeComparisonView(width: CGFloat) throws -> (ComparisonView, NSWindow) {
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 1024))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 2048))
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
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
        return (cv, window)
    }

    /// The real header view of a pane (its topmost direct subview).
    private func header(of pane: FilePaneView) throws -> PaneHeaderView {
        try XCTUnwrap(pane.subviews.compactMap({ $0 as? PaneHeaderView }).first)
    }

    private func windowPoint(_ view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    /// Drags the divider to `x` (in the split view's own coordinates) with
    /// synthesized mouse events — the gesture the app actually offers, and the
    /// only way a test can move this divider.
    private func dragDivider(of cv: ComparisonView, to x: CGFloat, window: NSWindow) {
        let sv = cv.splitView
        let start = NSPoint(x: sv.arrangedSubviews[0].frame.maxX, y: sv.bounds.midY)
        let target = NSPoint(x: x, y: sv.bounds.midY)
        sv.mouseDown(with: mouse(.leftMouseDown, at: sv.convert(start, to: nil), window: window))
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: sv.convert(target, to: nil), window: window))
        sv.mouseUp(with: mouse(.leftMouseUp, at: sv.convert(target, to: nil), window: window))
    }

    private func doubleClick(header: PaneHeaderView, window: NSWindow) {
        let p = windowPoint(header)
        header.mouseDown(with: mouse(.leftMouseDown, at: p, window: window, clickCount: 1))
        header.mouseUp(with: mouse(.leftMouseUp, at: p, window: window, clickCount: 1))
        header.mouseDown(with: mouse(.leftMouseDown, at: p, window: window, clickCount: 2))
        header.mouseUp(with: mouse(.leftMouseUp, at: p, window: window, clickCount: 2))
        // Let the 0.2s divider animation finish.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
    }

    func testDoubleClickPane1HeaderExpandsItToContentWidth() throws {
        let (cv, window) = try makeComparisonView(width: 800)

        // 50/50 pane width is below the content width, so the content cannot fit.
        XCTAssertLessThan(cv.paneView1.frame.width, cv.paneView1.hexContentWidth)

        doubleClick(header: try header(of: cv.paneView1), window: window)

        XCTAssertEqual(cv.paneView1.frame.width, cv.paneView1.contentFitWidth, accuracy: 1)
        // The panes still tile the split view; the second pane takes the rest.
        XCTAssertEqual(cv.paneView1.frame.width + cv.paneView2.frame.width + cv.splitView.dividerThickness,
                       cv.splitView.bounds.width, accuracy: 1)
    }

    func testDoubleClickPane2HeaderExpandsItToContentWidth() throws {
        let (cv, window) = try makeComparisonView(width: 800)
        XCTAssertLessThan(cv.paneView2.frame.width, cv.paneView2.hexContentWidth)

        doubleClick(header: try header(of: cv.paneView2), window: window)

        XCTAssertEqual(cv.paneView2.frame.width, cv.paneView2.contentFitWidth, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width + cv.paneView2.frame.width + cv.splitView.dividerThickness,
                       cv.splitView.bounds.width, accuracy: 1)
    }

    /// Fitting the width is a strict expansion: a pane that already shows its
    /// content is left untouched.
    func testHeaderDoubleClickWhenContentAlreadyFitsIsANoOp() throws {
        let (cv, window) = try makeComparisonView(width: 800)
        // Drag the divider far right so pane1 is comfortably wider than its
        // content (hex grid + slack).
        let wide = cv.paneView1.contentFitWidth + 50
        dragDivider(of: cv, to: wide, window: window)
        XCTAssertEqual(cv.paneView1.frame.width, wide, accuracy: 1,
                       "premise: the drag landed where it was aimed")
        XCTAssertGreaterThan(cv.paneView1.frame.width, cv.paneView1.contentFitWidth)

        doubleClick(header: try header(of: cv.paneView1), window: window)

        XCTAssertEqual(cv.paneView1.frame.width, wide, accuracy: 1)
    }

    /// Stacked mode is full-width, so a header double-click must not re-arrange
    /// the vertical split.
    ///
    /// The window is narrower than the hex grid on purpose. At the 800 pt the
    /// other tests use, a stacked pane is already wider than its content, so
    /// `fitContentWidth` returns at the same early guard the test above covers
    /// and the stacked case is never reached — the version of this test that did
    /// that passed with `fitPane`'s stacked guard deleted.
    func testHeaderDoubleClickIsANoOpInStackedMode() throws {
        let (cv, window) = try makeComparisonView(width: 400)
        UserDefaults.standard.set(false, forKey: "ComparisonPaneLayoutIsVertical")
        cv.splitView.isVertical = false
        window.layoutIfNeeded()
        let heightBefore = cv.paneView1.frame.height

        // Premise: the pane does NOT fit its content, so the fit path is
        // genuinely entered and only the stacked guard can stop it.
        XCTAssertLessThan(cv.paneView2.frame.width, cv.paneView2.contentFitWidth,
                          "premise: a full-width stacked pane is still narrower than its grid")

        doubleClick(header: try header(of: cv.paneView2), window: window)

        XCTAssertEqual(cv.paneView1.frame.height, heightBefore, accuracy: 1,
                       "a stacked header double-click must not move the divider")
        XCTAssertEqual(cv.paneView1.frame.height, cv.paneView2.frame.height, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width, cv.splitView.bounds.width, accuracy: 1)
    }
}
