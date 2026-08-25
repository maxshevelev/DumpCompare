import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3 / §9 scroll preservation: opening or closing the second pane must not
/// move the first pane's scroll. The first pane's `FilePaneView` is reused
/// across the mode change (not rebuilt), so its scroll — view state in the clip
/// view's bounds — survives. The old design rebuilt every pane on each `apply`,
/// and the fresh view's init followed the caret to the top of the viewport,
/// which is the bug these tests lock out.
@MainActor
final class ScrollPreservationTests: XCTestCase {
    /// Scrolls `pane`'s clip view to `y` (clamped to the document extent).
    private func scroll(_ pane: FilePaneView, toY y: CGFloat) {
        pane.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        pane.scrollView.reflectScrolledClipView(pane.scrollView.contentView)
    }

    /// Closes both panes (stopping their file watchers) and deletes the temp
    /// files. Closing before deleting matters: a delete under a live watcher
    /// would raise a modal change prompt that blocks the test's main thread.
    /// The `tempFile` teardown deletes the files again at test end; a second
    /// removal of a gone file is a no-op.
    private func cleanup(_ controller: MainViewController, _ urls: [URL]) {
        controller.windowModel.pane1.close()
        controller.windowModel.pane2.close()
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// A real controller in a real window with one file open (single-file mode),
    /// the pane scrolled down away from the top. Returns the pane view and the
    /// scroll position it actually settled at.
    private func makeScrolledSingleFile(_ bytes: [UInt8]) throws
        -> (MainViewController, NSWindow, URL, FilePaneView, CGFloat) {
        let controller = MainViewController()
        let window = makeTestWindow()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let url = try tempFile(bytes)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()

        let pane = try descendant(FilePaneView.self, of: window.contentView!)
        scroll(pane, toY: 1000)
        window.layoutIfNeeded()
        let y = pane.scrollView.contentView.bounds.origin.y
        return (controller, window, url, pane, y)
    }

    /// Opening the second file (single-file → comparison) must leave the first
    /// pane's view — and its scroll — exactly where they were.
    func testOpeningSecondFilePreservesFirstPaneScroll() throws {
        let (controller, window, urlA, paneBefore, yBefore) =
            try makeScrolledSingleFile([UInt8](repeating: 0x11, count: 16384))
        defer { cleanup(controller, [urlA]) }
        XCTAssertGreaterThan(yBefore, 0, "precondition: the first pane is scrolled down")

        let urlB = try tempFile([UInt8](repeating: 0x22, count: 16384))
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()

        XCTAssertEqual(controller.mode, .comparison)
        let comparison = try descendant(ComparisonView.self, of: window.contentView!)
        let paneAfter = comparison.paneView1
        XCTAssertTrue(paneAfter === paneBefore,
                      "the first pane's view must be reused, not rebuilt")
        let yAfter = paneAfter.scrollView.contentView.bounds.origin.y
        XCTAssertEqual(yAfter, yBefore, accuracy: 0.5,
                       "opening the second file must not move the first pane's scroll")
    }

    /// Closing the second file (comparison → single-file) must leave the first
    /// pane's view — and its scroll — exactly where they were.
    func testClosingSecondFilePreservesFirstPaneScroll() throws {
        let controller = MainViewController()
        let window = makeTestWindow()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let urlA = try tempFile([UInt8](repeating: 0x11, count: 16384))
        let urlB = try tempFile([UInt8](repeating: 0x22, count: 16384))
        defer { cleanup(controller, [urlA, urlB]) }
        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()

        let comparison = try descendant(ComparisonView.self, of: window.contentView!)
        let paneBefore = comparison.paneView1
        scroll(paneBefore, toY: 1000)
        window.layoutIfNeeded()
        let yBefore = paneBefore.scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(yBefore, 0, "precondition: the first pane is scrolled down")

        controller.windowModel.closePane(1)   // close the second pane
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()

        XCTAssertEqual(controller.mode, .singleFile)
        let paneAfter = try descendant(FilePaneView.self, of: window.contentView!)
        XCTAssertTrue(paneAfter === paneBefore,
                      "the first pane's view must be reused, not rebuilt")
        let yAfter = paneAfter.scrollView.contentView.bounds.origin.y
        XCTAssertEqual(yAfter, yBefore, accuracy: 0.5,
                       "closing the second file must not move the first pane's scroll")
    }
}
