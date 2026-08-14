import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Tests for window zoom-to-fit (§3.1): double-clicking the title bar / Window
/// > Zoom sizes the window to the hex content width instead of zooming to max.
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

    private func makeController() -> MainWindowController {
        let controller = MainWindowController()
        _ = controller.mainViewController.view  // loadView + viewDidLoad → empty mode
        return controller
    }

    func testEmptyModeKeepsPreferredFrame() {
        let controller = makeController()
        let window = controller.window!
        let preferred = NSRect(x: 0, y: 0, width: 3000, height: 2000)

        let frame = controller.mainViewController.windowWillUseStandardFrame(window, defaultFrame: preferred)

        XCTAssertEqual(frame, preferred)
    }

    func testSingleFileWidthsToHexContent() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController

        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        let pane = try XCTUnwrap(findPane(in: mainVC.view))
        let expected = pane.hexContentWidth + MainViewController.paneSlack

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        XCTAssertEqual(frame.width, expected, accuracy: 1)
        XCTAssertEqual(frame.height, window.frame.height, accuracy: 0.5)
        XCTAssertEqual(frame.origin, window.frame.origin)
        // Zoom-to-fit must be much narrower than the preferred (max) frame.
        XCTAssertLessThan(frame.width, 1000)
    }

    func testPerformZoomUsesContentWidth() throws {
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        try mainVC.windowModel.pane1.open(url: try tempFile([UInt8](repeating: 0x41, count: 4096)))
        mainVC.apply(mode: .singleFile)
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: false)
        let before = window.frame

        window.performZoom(nil)

        // The window is not on screen here, so zoom applies the standard frame
        // synchronously instead of animating.
        let pane = try XCTUnwrap(findPane(in: mainVC.view))
        let expected = pane.hexContentWidth + MainViewController.paneSlack
        XCTAssertEqual(window.frame.width, expected, accuracy: 1)
        XCTAssertEqual(window.frame.height, before.height, accuracy: 0.5)
        XCTAssertEqual(window.frame.origin, before.origin)
    }

    func testComparisonVerticalSumsPanes() throws {
        UserDefaults.standard.set(true, forKey: "ComparisonPaneLayoutIsVertical")
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 512))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController

        try mainVC.windowModel.pane1.open(url: url1)
        try mainVC.windowModel.pane2.open(url: url2)
        mainVC.apply(mode: .comparison)
        let panes = findPanes(in: mainVC.view)
        XCTAssertEqual(panes.count, 2)
        let paneWidth = try XCTUnwrap(panes.first).hexContentWidth
        let expected = 2 * (paneWidth + MainViewController.paneSlack) + 1

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        XCTAssertEqual(frame.width, expected, accuracy: 1)
    }

    func testComparisonStackedUsesMaxPaneWidth() throws {
        UserDefaults.standard.set(false, forKey: "ComparisonPaneLayoutIsVertical")
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 512))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController

        try mainVC.windowModel.pane1.open(url: url1)
        try mainVC.windowModel.pane2.open(url: url2)
        mainVC.apply(mode: .comparison)
        let panes = findPanes(in: mainVC.view)
        XCTAssertEqual(panes.count, 2)
        let paneWidth = try XCTUnwrap(panes.first).hexContentWidth
        let expected = paneWidth + MainViewController.paneSlack

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        XCTAssertEqual(frame.width, expected, accuracy: 1)
    }
}
