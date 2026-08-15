import XCTest
@testable import DumpCompare

/// Tests for window zoom-to-fit (§3.1): double-clicking the title bar / Window
/// > Zoom sizes the window to the loaded files' real content — the width to
/// the hex grid(s) plus the taller pane's content height (header/status chrome
/// included) — both capped at the screen's visible size. The top edge stays
/// put; only the bottom edge moves.
@MainActor
final class ZoomToFitTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-test-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func findPanes(in view: NSView) -> [FilePaneView] {
        var found: [FilePaneView] = []
        if let pane = view as? FilePaneView {
            found.append(pane)
        }
        for sub in view.subviews {
            found.append(contentsOf: findPanes(in: sub))
        }
        return found
    }

    private func findPane(in view: NSView) -> FilePaneView? {
        findPanes(in: view).first
    }

    private func findSplitView(in view: NSView) -> ProportionalSplitView? {
        if let split = view as? ProportionalSplitView { return split }
        for sub in view.subviews {
            if let found = findSplitView(in: sub) { return found }
        }
        return nil
    }

    private func makeController() -> MainWindowController {
        let controller = MainWindowController()
        _ = controller.mainViewController.view  // loadView + viewDidLoad → empty mode
        return controller
    }

    /// The uncapped window-frame height for `contentHeight` of content (adds
    /// the title bar). Mirrors `windowWillUseStandardFrame`'s conversion.
    private func rawFrameHeight(for contentHeight: CGFloat, window: NSWindow) -> CGFloat {
        window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 0, height: contentHeight)).height
    }

    /// The frame height `windowWillUseStandardFrame` picks for `contentHeight`:
    /// the content height capped at the screen's visible height.
    private func expectedFrameHeight(for contentHeight: CGFloat, window: NSWindow) -> CGFloat {
        let raw = rawFrameHeight(for: contentHeight, window: window)
        let screen = window.screen ?? NSScreen.main
        return min(raw, screen?.visibleFrame.height ?? raw)
    }

    /// The frame width `windowWillUseStandardFrame` picks for `contentWidth`:
    /// the content width capped at the screen's visible width.
    private func expectedFrameWidth(for contentWidth: CGFloat, window: NSWindow) -> CGFloat {
        let screen = window.screen ?? NSScreen.main
        return min(contentWidth, screen?.visibleFrame.width ?? contentWidth)
    }

    /// Close the panes and delete the temp files. Closing stops the file
    /// watchers: deleting first would fire the external-change prompt, and that
    /// `NSAlert.runModal()` would block the test's main thread forever.
    private func cleanup(_ mainVC: MainViewController, _ urls: URL...) {
        mainVC.windowModel.pane1.close()
        mainVC.windowModel.pane2.close()
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    func testEmptyModeKeepsPreferredFrame() {
        let controller = makeController()
        let window = controller.window!
        let preferred = NSRect(x: 0, y: 0, width: 3000, height: 2000)

        let frame = controller.mainViewController.windowWillUseStandardFrame(window, defaultFrame: preferred)

        XCTAssertEqual(frame, preferred)
    }

    func testSingleFileFitsContentWidthAndHeight() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 256))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url) }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: false)
        let before = window.frame

        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        let pane = try XCTUnwrap(findPane(in: mainVC.view))

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        XCTAssertEqual(frame.width, expectedFrameWidth(for: pane.contentFitWidth, window: window),
                       accuracy: 1, "width must fit the hex grid")
        XCTAssertEqual(frame.height, expectedFrameHeight(for: pane.contentFitHeight, window: window),
                       accuracy: 1, "height must fit the hex content")
        XCTAssertEqual(frame.origin.x, before.origin.x, accuracy: 0.5, "x must be kept")
        // The top edge stays put — the window grows/shrinks from the bottom.
        XCTAssertEqual(frame.origin.y + frame.height, before.origin.y + before.height, accuracy: 0.5)
        // Zoom-to-fit must be much smaller than the preferred (max) frame.
        XCTAssertLessThan(frame.width, 1000)
        XCTAssertLessThan(frame.height, 1000)
    }

    func testPerformZoomUsesContentWidthAndHeight() throws {
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        let url = try tempFile([UInt8](repeating: 0x41, count: 256))
        defer { cleanup(mainVC, url) }
        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: false)
        let before = window.frame

        window.performZoom(nil)

        // The window is not on screen here, so zoom applies the standard frame
        // synchronously instead of animating.
        let pane = try XCTUnwrap(findPane(in: mainVC.view))
        XCTAssertEqual(window.frame.width, expectedFrameWidth(for: pane.contentFitWidth, window: window),
                       accuracy: 1)
        XCTAssertEqual(window.frame.height, expectedFrameHeight(for: pane.contentFitHeight, window: window),
                       accuracy: 1)
        XCTAssertEqual(window.frame.origin.x, before.origin.x, accuracy: 0.5, "x must be kept")
    }

    /// Side-by-side: the width must fit both grids plus the divider, the height
    /// the taller of the two files.
    func testComparisonVerticalFitsBothPanes() throws {
        UserDefaults.standard.set(true, forKey: "ComparisonPaneLayoutIsVertical")
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 512))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url1, url2) }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: false)

        try mainVC.windowModel.pane1.open(url: url1)
        try mainVC.windowModel.pane2.open(url: url2)
        mainVC.apply(mode: .comparison)
        let panes = findPanes(in: mainVC.view)
        XCTAssertEqual(panes.count, 2)
        let divider = try XCTUnwrap(findSplitView(in: mainVC.view))
        let expectedWidth = panes[0].contentFitWidth + panes[1].contentFitWidth + divider.dividerThickness
        let expectedHeight = max(panes[0].contentFitHeight, panes[1].contentFitHeight)

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        XCTAssertEqual(frame.width, expectedFrameWidth(for: expectedWidth, window: window),
                       accuracy: 1, "width must fit both grids plus the divider")
        XCTAssertEqual(frame.height, expectedFrameHeight(for: expectedHeight, window: window),
                       accuracy: 1, "height must fit the taller of the two files")
    }

    /// Stacked: both panes share the full width, so the width fits the wider
    /// grid; the height still targets the taller file's content.
    func testComparisonStackedFitsBothPanes() throws {
        UserDefaults.standard.set(false, forKey: "ComparisonPaneLayoutIsVertical")
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 512))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url1, url2) }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: false)

        try mainVC.windowModel.pane1.open(url: url1)
        try mainVC.windowModel.pane2.open(url: url2)
        mainVC.apply(mode: .comparison)
        let panes = findPanes(in: mainVC.view)
        XCTAssertEqual(panes.count, 2)
        let expectedWidth = max(panes[0].contentFitWidth, panes[1].contentFitWidth)
        let expectedHeight = max(panes[0].contentFitHeight, panes[1].contentFitHeight)

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        XCTAssertEqual(frame.width, expectedFrameWidth(for: expectedWidth, window: window),
                       accuracy: 1, "width must fit the wider grid")
        XCTAssertEqual(frame.height, expectedFrameHeight(for: expectedHeight, window: window),
                       accuracy: 1, "height must fit the taller of the two files")
    }

    /// When the content is taller than the screen, the height caps at the
    /// screen's visible height instead of growing off-screen.
    func testTallContentCapsAtScreenHeight() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 256 * 1024))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url) }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: false)

        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        let pane = try XCTUnwrap(findPane(in: mainVC.view))
        let uncapped = rawFrameHeight(for: pane.contentFitHeight, window: window)

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        let screen = window.screen ?? NSScreen.main
        if let screen {
            XCTAssertGreaterThan(uncapped, screen.visibleFrame.height,
                                 "precondition: the content must exceed the screen")
            XCTAssertEqual(frame.height, screen.visibleFrame.height, accuracy: 1,
                           "the height must cap at the screen's visible height")
        } else {
            XCTAssertEqual(frame.height, uncapped, accuracy: 1,
                           "no screen to cap at — the content height is used")
        }
    }
}
