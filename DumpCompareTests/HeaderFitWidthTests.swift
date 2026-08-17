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

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fit-width-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        tempFiles.append(url)
        return url
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

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clickCount, pressure: 1)!
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
        cv.splitView.setPosition(wide, ofDividerAt: 0)
        XCTAssertGreaterThan(cv.paneView1.frame.width, cv.paneView1.contentFitWidth)

        doubleClick(header: try header(of: cv.paneView1), window: window)

        XCTAssertEqual(cv.paneView1.frame.width, wide, accuracy: 1)
    }

    /// Stacked mode is full-width, so a header double-click must not re-arrange
    /// the vertical split.
    func testHeaderDoubleClickIsANoOpInStackedMode() throws {
        let (cv, window) = try makeComparisonView(width: 800)
        UserDefaults.standard.set(false, forKey: "ComparisonPaneLayoutIsVertical")
        cv.splitView.isVertical = false
        window.layoutIfNeeded()

        // Panes are full-width: the horizontal content already fits.
        XCTAssertGreaterThanOrEqual(cv.paneView1.frame.width, cv.paneView1.contentFitWidth)

        doubleClick(header: try header(of: cv.paneView2), window: window)

        XCTAssertEqual(cv.paneView1.frame.height, cv.paneView2.frame.height, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width, cv.splitView.bounds.width, accuracy: 1)
    }
}
