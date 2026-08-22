import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3: toggling the pane arrangement (View > Toggle Pane Layout) must re-lay
/// the panes out in the other orientation WITHOUT resizing the window.
///
/// This test goes through the real `MainWindowController` because the bug it
/// guards against only manifests in the real app setup: NSSplitView re-fits
/// the window to the content's fitting size when `isVertical` changes, and in
/// stacked mode that fitting size is one pane wide — so the window collapsed
/// to half its width on toggle, breaking the layout.
///
/// ProportionalSplitView restores the pre-toggle window frame during layout, so
/// the assertions below check that the window size is unchanged in both
/// directions and that the divider stays draggable in both orientations.
@MainActor
final class LayoutToggleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Deterministic: clear any autosaved window frame and force vertical start.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame MainWindow")
        UserDefaults.standard.set(true, forKey: "ComparisonPaneLayoutIsVertical")
    }

    override func tearDown() {
        removeTempFiles()
        super.tearDown()
    }

    /// Every file this class writes, deleted in `tearDown`: the test host is
    /// sandboxed, so these land in the app's own container and stay there.
    private var tempFiles: [URL] = []

    private func removeTempFiles() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
    }

    /// Runs the window through several display + runloop turns so the re-fit /
    /// restore cycle NSSplitView triggers on orientation change settles.
    private func settle(_ window: NSWindow, turns: Int = 4) {
        for _ in 0..<turns {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            window.layoutIfNeeded()
        }
    }

    private func windowPoint(_ splitView: NSSplitView, _ point: NSPoint) -> NSPoint {
        splitView.convert(point, to: nil)
    }

    func testToggleKeepsWindowSizeAndDividerWorks() throws {
        let wc = MainWindowController()
        wc.showWindow(nil)
        let window = wc.window!
        window.setFrame(NSRect(x: 100, y: 100, width: 1080, height: 720), display: true)
        window.layoutIfNeeded()
        settle(window)

        let url1 = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 512))
        try wc.mainViewController.windowModel.pane1.open(url: url1)
        try wc.mainViewController.windowModel.pane2.open(url: url2)
        wc.mainViewController.apply(mode: .comparison)
        settle(window)

        guard let cv = descendants(of: wc.mainViewController.view, ComparisonView.self).first else {
            XCTFail("no comparisonView"); return
        }
        let sv = cv.splitView

        // The panes fill the window's content area: window height minus the
        // title bar and the unified toolbar, which occupies the title bar.
        // Read it from the window rather than hard-coding, so a toolbar height
        // change doesn't silently break the geometry assertions below (§10.3).
        let contentHeight = window.contentLayoutRect.height

        // Vertical: side-by-side, full height, window unchanged.
        XCTAssertEqual(window.frame.size.width, 1080, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.height, contentHeight, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.height, contentHeight, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width + cv.paneView2.frame.width + cv.splitView.dividerThickness, 1080, accuracy: 1)

        // Toggle to stacked: window MUST keep its size, panes full-width stacked.
        wc.mainViewController.togglePaneLayout()
        settle(window)
        XCTAssertEqual(window.frame.size.width, 1080, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width, 1080, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.width, 1080, accuracy: 1)
        let stackedHalf = (contentHeight - cv.splitView.dividerThickness) / 2
        XCTAssertEqual(cv.paneView1.frame.height, stackedHalf, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.height, stackedHalf, accuracy: 1)

        // Divider still draggable in stacked mode (first pane sits on top, so
        // its bottom edge — maxY in the flipped split view — is the divider).
        let dividerY = cv.paneView1.frame.maxY
        let down = NSPoint(x: 400, y: dividerY - 100)
        sv.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(sv, NSPoint(x: 400, y: dividerY)), window: window))
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(sv, down), window: window))
        sv.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(sv, down), window: window))
        XCTAssertEqual(cv.paneView1.frame.height, stackedHalf - 100, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.height, stackedHalf + 100, accuracy: 1)

        // Toggle back to vertical: window still unchanged, side-by-side returns.
        wc.mainViewController.togglePaneLayout()
        settle(window)
        XCTAssertEqual(window.frame.size.width, 1080, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.height, contentHeight, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width + cv.paneView2.frame.width + cv.splitView.dividerThickness, 1080, accuracy: 1)
    }

    /// §3.3: each pane layout keeps its OWN divider proportion. Dragging the
    /// divider side-by-side must not leak into the stacked layout (or vice
    /// versa): a toggle re-applies the other layout's remembered ratio, and the
    /// dragged one comes back when the layout is restored.
    func testEachLayoutKeepsItsOwnDividerProportion() throws {
        let wc = MainWindowController()
        wc.showWindow(nil)
        let window = wc.window!
        window.setFrame(NSRect(x: 100, y: 100, width: 1080, height: 720), display: true)
        window.layoutIfNeeded()
        settle(window)

        let url1 = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 512))
        try wc.mainViewController.windowModel.pane1.open(url: url1)
        try wc.mainViewController.windowModel.pane2.open(url: url2)
        wc.mainViewController.apply(mode: .comparison)
        settle(window)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        guard let cv = descendants(of: wc.mainViewController.view, ComparisonView.self).first else {
            XCTFail("no comparisonView"); return
        }
        let sv = cv.splitView
        let contentHeight = window.contentLayoutRect.height
        let availableW = 1080 - sv.dividerThickness
        let availableH = contentHeight - sv.dividerThickness

        // Side-by-side: drag the divider to a 75/25 split.
        let dividerX = cv.paneView1.frame.maxX
        let target = NSPoint(x: 0.75 * availableW, y: 300)
        sv.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(sv, NSPoint(x: dividerX, y: 300)), window: window))
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(sv, target), window: window))
        sv.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(sv, target), window: window))
        XCTAssertEqual(cv.paneView1.frame.width / availableW, 0.75, accuracy: 0.01)

        // Toggle to stacked: the stacked layout has never had its divider
        // touched, so it must open at 50/50 — NOT the 75/25 dragged above.
        wc.mainViewController.togglePaneLayout()
        settle(window)
        XCTAssertEqual(cv.paneView1.frame.height, availableH / 2, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.height, availableH / 2, accuracy: 1)

        // Stacked: drag the divider so the top pane gets a 30% share.
        let dividerY = cv.paneView1.frame.maxY
        let stackedTarget = NSPoint(x: 400, y: 0.30 * availableH)
        sv.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(sv, NSPoint(x: 400, y: dividerY)), window: window))
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(sv, stackedTarget), window: window))
        sv.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(sv, stackedTarget), window: window))
        XCTAssertEqual(cv.paneView1.frame.height / availableH, 0.30, accuracy: 0.01)

        // Back to side-by-side: the 75/25 proportion is restored, untouched by
        // the stacked drag.
        wc.mainViewController.togglePaneLayout()
        settle(window)
        XCTAssertEqual(cv.paneView1.frame.width / availableW, 0.75, accuracy: 0.01)
        XCTAssertEqual(cv.paneView2.frame.width / availableW, 0.25, accuracy: 0.01)
    }
}
