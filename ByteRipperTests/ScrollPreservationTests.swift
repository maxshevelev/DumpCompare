import ByteRipperCore
import UEFIImage
import UEFIToolUI
import XCTest
@testable import ByteRipper

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

    /// Loading another file into a pane leaves the viewport where it was.
    ///
    /// A load is not a navigation: the reader scrolled somewhere on purpose,
    /// and putting a second dump into the pane is usually a way of reading the
    /// same offsets in a different file. The fresh document used to put its
    /// caret at 0 and the reveal that followed dragged the dump to the top.
    func testLoadingAnotherFileIntoThePanePreservesItsScroll() throws {
        let (controller, window, url, pane, yBefore) =
            try makeScrolledSingleFile([UInt8](repeating: 0x11, count: 16384))
        var urls = [url]
        defer { cleanup(controller, urls) }
        XCTAssertGreaterThan(yBefore, 0, "precondition: the pane is scrolled down")

        let second = try tempFile([UInt8](repeating: 0x22, count: 16384))
        urls.append(second)
        try controller.windowModel.pane1.open(url: second)
        window.layoutIfNeeded()

        XCTAssertEqual(pane.scrollView.contentView.bounds.origin.y, yBefore, accuracy: 0.5,
                       "the load left the viewport where the reader was")
    }

    /// The same through the gesture a reader actually uses: a drop on
    /// "Replace Current File".
    func testReplacingTheFileByDropPreservesTheScroll() throws {
        let (controller, window, url, pane, _) =
            try makeScrolledSingleFile([UInt8](repeating: 0x11, count: 16384))
        var urls = [url]
        defer { cleanup(controller, urls) }

        // The caret somewhere the viewport is not — which is the case the
        // complaint is about: a reveal here drags the dump to the caret.
        controller.windowModel.pane1.moveCaret(to: 0x3F00)
        scroll(pane, toY: 400)
        window.layoutIfNeeded()
        let yBefore = pane.scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(yBefore, 0, "precondition: the pane is scrolled down")

        let second = try tempFile([UInt8](repeating: 0x22, count: 16384))
        urls.append(second)
        controller.handleSingleFileDrop(target: .replace, urls: [second])
        window.layoutIfNeeded()

        XCTAssertEqual(pane.scrollView.contentView.bounds.origin.y, yBefore, accuracy: 0.5,
                       "the drop left the viewport where the reader was")
    }

    /// Every way of opening a file into a pane is the same way.
    ///
    /// The Open panel and Launch Services (`openFiles`), a drop on Replace
    /// Current File, and the pane header's own Open (`openFiles(into:)`) are
    /// three gestures, not three behaviours: each is a route into
    /// `openIntoPane`, and below it there is one `PaneViewModel.open` in the
    /// whole app. What that has to mean to a reader is that they answer
    /// identically — the caret comes over, and the viewport stays. Driving all
    /// three over one setup is what stops a fourth entry point from quietly
    /// growing rules of its own.
    func testEveryRouteIntoAPaneLandsTheSameWay() throws {
        var urls: [URL] = []
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }

        /// Opens a file the given way over a pane scrolled away from its
        /// caret, and reports where the reader was left.
        func outcome(
            of route: (MainViewController, URL) -> Void
        ) throws -> (y: CGFloat, caret: UInt64, yBefore: CGFloat) {
            let (controller, window, url, pane, _) =
                try makeScrolledSingleFile([UInt8](repeating: 0x11, count: 16384))
            defer { cleanup(controller, [url]) }
            urls.append(url)

            controller.windowModel.pane1.moveCaret(to: 0x3F00)
            scroll(pane, toY: 400)
            window.layoutIfNeeded()
            let yBefore = pane.scrollView.contentView.bounds.origin.y

            let second = try tempFile([UInt8](repeating: 0x22, count: 16384))
            urls.append(second)
            route(controller, second)
            window.layoutIfNeeded()

            return (pane.scrollView.contentView.bounds.origin.y,
                    controller.windowModel.pane1.caretOffset,
                    yBefore)
        }

        let panel = try outcome { controller, url in controller.openFiles([url]) }
        let drop = try outcome { controller, url in
            controller.handleSingleFileDrop(target: .replace, urls: [url])
        }
        let header = try outcome { controller, url in
            controller.openFiles(into: 0, urls: [url])
        }
        // And opening the file the pane already holds, which is a reload — a
        // different thing to do, but not a different place to leave the reader.
        let again = try outcome { controller, _ in
            controller.openFiles([controller.windowModel.pane1.document!.url])
        }

        XCTAssertGreaterThan(panel.yBefore, 0, "precondition: the pane is scrolled down")
        for (name, result) in [("the Open panel", panel), ("a drop", drop),
                               ("the pane header", header),
                               ("opening the same file again", again)] {
            XCTAssertEqual(result.y, result.yBefore, accuracy: 0.5,
                           "\(name) left the viewport where the reader was")
            XCTAssertEqual(result.caret, 0x3F00,
                           "\(name) carried the caret over")
        }
    }

    /// Re-dropping the file that is already open is a reload (§4.1 rule 5),
    /// and a reload is not a navigation either: the reader asked for the bytes
    /// back, not to be taken to wherever the caret happens to be.
    func testReloadingTheSameFilePreservesTheScroll() throws {
        let (controller, window, url, pane, _) =
            try makeScrolledSingleFile([UInt8](repeating: 0x11, count: 16384))
        defer { cleanup(controller, [url]) }

        controller.windowModel.pane1.moveCaret(to: 0x3F00)
        scroll(pane, toY: 400)
        window.layoutIfNeeded()
        let yBefore = pane.scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(yBefore, 0, "precondition: the pane is scrolled down")

        controller.handleSingleFileDrop(target: .replace, urls: [url])
        window.layoutIfNeeded()

        XCTAssertEqual(pane.scrollView.contentView.bounds.origin.y, yBefore, accuracy: 0.5,
                       "the reload left the viewport where the reader was")
        XCTAssertEqual(controller.windowModel.pane1.caretOffset, 0x3F00,
                       "and the caret where they left it")
    }

    /// With a tool panel open, too.
    ///
    /// A panel publishes the zone of the node it has in focus, and the host
    /// scrolls the dump to a zone that has just come into focus — that is what
    /// a panel is for. But a *replaced file* is not a new focus: the node that
    /// was in focus belonged to the file that is gone, and republishing it
    /// drags the dump to wherever that path happens to land in the new one.
    func testReplacingTheFileWithAToolPanelOpenPreservesTheScroll() throws {
        let (controller, window, url, pane, _) =
            try makeScrolledSingleFile(UEFITestImage.make() + UEFITestImage.make())
        var urls = [url]
        defer { cleanup(controller, urls) }

        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        let session = try XCTUnwrap(controller.tools.session as? UEFIToolSession)
        let shown = expectation(description: "the panel is up")
        session.onDisplay = { _ in shown.fulfill() }
        wait(for: [shown], timeout: 5)
        session.onDisplay = nil

        // Something in focus, so there is a zone to republish.
        let outline = try XCTUnwrap(
            descendants(of: try XCTUnwrap(controller.tools.panel), NSOutlineView.self).first
        )
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.layoutIfNeeded()
        XCTAssertFalse(controller.windowModel.pane1.zones.zones.isEmpty,
                       "precondition: the panel published a zone")

        scroll(pane, toY: 1000)
        window.layoutIfNeeded()
        let yBefore = pane.scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(yBefore, 0, "precondition: the pane is scrolled down")

        let second = try tempFile(UEFITestImage.make() + UEFITestImage.make())
        urls.append(second)
        try controller.windowModel.pane1.open(url: second)
        window.layoutIfNeeded()

        XCTAssertEqual(pane.scrollView.contentView.bounds.origin.y, yBefore, accuracy: 0.5,
                       "the load left the viewport where the reader was")
    }

    /// The room the file leaves is the limit: a shorter file cannot hold the
    /// old scroll, and the view clamps to its end rather than refusing to load.
    func testLoadingAShorterFileClampsTheScrollToItsEnd() throws {
        let (controller, window, url, pane, yBefore) =
            try makeScrolledSingleFile([UInt8](repeating: 0x11, count: 16384))
        var urls = [url]
        defer { cleanup(controller, urls) }
        XCTAssertGreaterThan(yBefore, 0, "precondition: the pane is scrolled down")

        let shorter = try tempFile([UInt8](repeating: 0x22, count: 32))
        urls.append(shorter)
        try controller.windowModel.pane1.open(url: shorter)
        window.layoutIfNeeded()

        let y = pane.scrollView.contentView.bounds.origin.y
        XCTAssertLessThan(y, yBefore, "there is no such offset in the new file")
        XCTAssertGreaterThanOrEqual(y, 0)
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
