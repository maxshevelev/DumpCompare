import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.5 closing: the pane's header (×) must work in single-file mode too, and
/// closing the last file must return the window to its launch state (empty
/// mode, find bar dismissed). Previously only the comparison-mode panes wired
/// `onClose`, so the single-file (×) was visible but ignored.
@MainActor
final class CloseFileTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("close-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    /// A real controller in a real window with one file open (single-file mode).
    private func makeController(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window, url)
    }

    private func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        var result: [T] = []
        for sub in view.subviews {
            if let match = sub as? T { result.append(match) }
            result.append(contentsOf: descendants(of: sub, type))
        }
        return result
    }

    private func closeButton(in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(of: view, NSButton.self).first { $0.toolTip == "Close pane" },
                      "the pane header's ✕ button")
    }

    private func emptyState(_ window: NSWindow) -> [EmptyStateView] {
        descendants(of: window.contentView!, EmptyStateView.self)
    }

    /// Close the pane and delete the temp file. Closing stops the file watcher:
    /// deleting the file first would fire the external-change prompt, and that
    /// `NSAlert.runModal()` would block the test's main thread forever.
    private func cleanup(_ controller: MainViewController, _ url: URL) {
        controller.windowModel.pane1.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// The single-file pane must have a working ✕ that closes the file.
    func testCloseButtonClosesLastFile() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        XCTAssertEqual(controller.mode, .singleFile)
        XCTAssertTrue(emptyState(window).isEmpty, "precondition: single-file mode shows no empty state")

        let button = try closeButton(in: window.contentView!)
        button.performClick(nil)

        XCTAssertEqual(controller.mode, .empty, "closing the last file must return to empty mode")
        XCTAssertTrue(emptyState(window).contains { !$0.isHidden },
                      "the empty state must be on screen after closing the last file")
    }

    /// Returning to the launch state must also dismiss the find bar — nothing is
    /// left to search over the empty state.
    func testClosingLastFileDismissesFindBar() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        controller.findPattern()
        XCTAssertTrue(descendants(of: window.contentView!, FindBarView.self).first?.isHidden == false,
                      "precondition: the find bar is visible")

        let button = try closeButton(in: window.contentView!)
        button.performClick(nil)

        XCTAssertEqual(controller.mode, .empty)
        XCTAssertTrue(descendants(of: window.contentView!, FindBarView.self).first?.isHidden == true,
                      "closing the last file must hide the find bar (launch state)")
    }

    /// File > Close Pane (the menu path) keeps working for the single pane and
    /// lands in the same empty state.
    func testClosePaneMenuItemReturnsToEmpty() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        let item = NSMenuItem(title: "Close Pane", action: #selector(MainViewController.closeCurrentFile),
                              keyEquivalent: "")
        item.target = nil  // responder-chain, exactly as the app builds it
        let dispatched = window.contentView?.tryToPerform(item.action!, with: item) ?? false
        XCTAssertTrue(dispatched, "Close Pane must resolve to a responder")

        XCTAssertEqual(controller.mode, .empty)
        XCTAssertTrue(emptyState(window).contains { !$0.isHidden })
    }
}
