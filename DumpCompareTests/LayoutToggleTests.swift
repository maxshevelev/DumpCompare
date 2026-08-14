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

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toggle-test-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
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

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
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

        guard let cv = wc.mainViewController.view.subviews.compactMap({ $0 as? ComparisonView }).first else {
            XCTFail("no comparisonView"); return
        }
        let sv = cv.splitView

        // Vertical: side-by-side, full height, window unchanged.
        XCTAssertEqual(window.frame.size.width, 1080, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.height, 692, accuracy: 1)  // 720 − titlebar
        XCTAssertEqual(cv.paneView2.frame.height, 692, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width + cv.paneView2.frame.width + 1, 1080, accuracy: 1)

        // Toggle to stacked: window MUST keep its size, panes full-width stacked.
        wc.mainViewController.togglePaneLayout()
        settle(window)
        XCTAssertEqual(window.frame.size.width, 1080, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width, 1080, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.width, 1080, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.height, 345.5, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.height, 345.5, accuracy: 1)

        // Divider still draggable in stacked mode (first pane sits on top, so
        // its bottom edge — maxY in the flipped split view — is the divider).
        let dividerY = cv.paneView1.frame.maxY
        let down = NSPoint(x: 400, y: dividerY - 100)
        sv.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(sv, NSPoint(x: 400, y: dividerY)), window: window))
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(sv, down), window: window))
        sv.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(sv, down), window: window))
        XCTAssertEqual(cv.paneView1.frame.height, 245.5, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.height, 445.5, accuracy: 1)

        // Toggle back to vertical: window still unchanged, side-by-side returns.
        wc.mainViewController.togglePaneLayout()
        settle(window)
        XCTAssertEqual(window.frame.size.width, 1080, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.height, 692, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width + cv.paneView2.frame.width + 1, 1080, accuracy: 1)
    }
}
