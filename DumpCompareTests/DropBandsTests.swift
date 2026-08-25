import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §22.4 the drop bands, exercised through the real `MainViewController`: a
/// drop on a join band joins the file, a drop on the replace band replaces it,
/// extra files dropped on a join band are ignored with a notification, and an
/// empty pane offers only the Open target. The routing is driven through the
/// controller's drop handlers directly, so the tests assert on the pane's bytes
/// and partition after the drop.
@MainActor
final class DropBandsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// A full controller whose active pane is open over `bytes`.
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

    private func cleanup(_ controller: MainViewController, _ url: URL?) {
        controller.windowModel.pane1.close()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// A temp source file holding `bytes`, removed when the test ends.
    private func makeSourceFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropBandsTests-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The pane's bytes for `range`, read live (edits included).
    private func paneBytes(_ pane: PaneViewModel, _ range: Range<UInt64>) throws -> [UInt8] {
        try XCTUnwrap(pane.byteStorage).read(at: range.lowerBound, length: Int(range.count))
    }

    // MARK: - A band maps to the right command

    /// A drop on the Insert-at-Start band joins the file's bytes before the
    /// pane's content (§22.4): the pane detaches (untitled, dirty), and the
    /// seam is a cut named for both sources.
    func testADropOnTheInsertBandJoinsAtTheStart() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let source = try makeSourceFile([0xB0, 0xB1])
        controller.handleSingleFileDrop(target: .insertAtStart, urls: [source])

        XCTAssertEqual(pane.fileSize, 18)
        XCTAssertEqual(try paneBytes(pane, 0..<18), [0xB0, 0xB1] + [UInt8](0..<16),
                       "the source's bytes land before the original content")
        XCTAssertTrue(pane.isUntitled, "the join detaches the pane from its file")
        let pieces = pane.segmentStore.segments
        XCTAssertEqual(pieces.map(\.range), [0..<2, 2..<18], "the seam is a cut at the seam")
        XCTAssertEqual(pieces.first?.name, source.lastPathComponent, "the inserted half")
        XCTAssertEqual(pieces.last?.name, url.lastPathComponent, "the original content")
        _ = window
    }

    /// A drop on the Append-at-End band joins the file's bytes after the pane's
    /// content (§22.4).
    func testADropOnTheAppendBandJoinsAtTheEnd() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let source = try makeSourceFile([0xA0, 0xA1, 0xA2])
        controller.handleSingleFileDrop(target: .appendAtEnd, urls: [source])

        XCTAssertEqual(pane.fileSize, 19)
        XCTAssertEqual(try paneBytes(pane, 0..<19), [UInt8](0..<16) + [0xA0, 0xA1, 0xA2],
                       "the source's bytes land after the original content")
        XCTAssertTrue(pane.isUntitled, "the join detaches the pane from its file")
        let pieces = pane.segmentStore.segments
        XCTAssertEqual(pieces.map(\.range), [0..<16, 16..<19], "the seam is a cut at the old end")
        XCTAssertEqual(pieces.first?.name, url.lastPathComponent, "the original content")
        XCTAssertEqual(pieces.last?.name, source.lastPathComponent, "the appended half")
        _ = window
    }

    /// A drop on the Replace band replaces the pane's file with the dropped
    /// file (§4.3): the pane now shows the source's bytes and is attached to
    /// the source (not untitled).
    func testADropOnTheReplaceBandReplacesTheFile() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let source = try makeSourceFile([0xC0, 0xC1, 0xC2, 0xC3])
        controller.handleSingleFileDrop(target: .replace, urls: [source])

        XCTAssertEqual(pane.fileSize, 4, "the pane now holds the source's bytes")
        XCTAssertEqual(try paneBytes(pane, 0..<4), [0xC0, 0xC1, 0xC2, 0xC3])
        XCTAssertFalse(pane.isUntitled, "a replace keeps the pane attached to the new file")
        XCTAssertEqual(pane.status.fileName, source.lastPathComponent)
        _ = window
    }

    // MARK: - Extra files are ignored

    /// Several files dropped on a join band: the first is joined and the rest
    /// are ignored with the standard notification (§22.4).
    func testExtraFilesDroppedOnAJoinBandAreIgnored() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let first = try makeSourceFile([0xA0])
        let second = try makeSourceFile([0xA1])
        let third = try makeSourceFile([0xA2])

        controller.handleSingleFileDrop(target: .appendAtEnd,
                                        urls: [first, second, third])

        // Only the first file is joined; the pane's size is original + one byte.
        XCTAssertEqual(pane.fileSize, 17, "only the first file is joined")
        XCTAssertEqual(try paneBytes(pane, 16..<17), [0xA0], "the first file's byte lands at the seam")
        // The two extras are ignored with the notification.
        XCTAssertEqual(controller.lastAlertTitle, "Additional files ignored",
                       "the extra files are reported as ignored")
        _ = window
    }

    // MARK: - An empty pane offers only Open

    /// With no file open, the drop area is the single "Open" target
    /// (`EmptyStateView`), not the three-band overlay — there is nothing to
    /// join to (§22.4).
    func testAnEmptyPaneOffersOnlyOpen() {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.apply(mode: .empty)
        window.layoutIfNeeded()

        // The empty mode shows the single "Open" target (EmptyStateView), not
        // the three-band join overlay — there is nothing to join to (§22.4).
        XCTAssertNotNil(findView(EmptyStateView.self, in: controller.view),
                        "an empty pane offers the Open target")
        XCTAssertNil(findView(PaneDropBandsView.self, in: controller.view),
                     "an empty pane has no join bands")
    }

    // MARK: - Comparison-mode routing

    /// A full controller in comparison mode, both panes open over their bytes.
    private func makeComparisonController(_ bytes1: [UInt8], _ bytes2: [UInt8]) throws
        -> (MainViewController, NSWindow, URL, URL) {
        let url1 = try tempFile(bytes1)
        let url2 = try tempFile(bytes2)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        return (controller, window, url1, url2)
    }

    /// A drop on pane 0's Insert-at-Start band joins the file into pane 0 only
    /// (§22.4 comparison mode): pane 0's bytes change and it detaches; pane 1 is
    /// untouched and still attached to its file.
    func testAJoinBandDropInComparisonModeJoinsOnlyTheTargetPane() throws {
        let (controller, window, url1, url2) = try makeComparisonController([UInt8](0..<16), [UInt8](16..<32))
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }
        let pane1 = controller.windowModel.pane1
        let pane2 = controller.windowModel.pane2

        let source = try makeSourceFile([0xB0, 0xB1])
        controller.handleComparisonBandDrop(targetPane: 0, target: .insertAtStart, urls: [source])

        // Pane 0 joined: the source's bytes land before its content, and it detaches.
        XCTAssertEqual(pane1.fileSize, 18)
        XCTAssertEqual(try paneBytes(pane1, 0..<18), [0xB0, 0xB1] + [UInt8](0..<16))
        XCTAssertTrue(pane1.isUntitled, "the joined pane detaches from its file")
        // Pane 1 is untouched: still attached to its file, same size.
        XCTAssertEqual(pane2.fileSize, 16)
        XCTAssertFalse(pane2.isUntitled, "the other pane is untouched")
        _ = window
    }

    /// A drop on pane 1's Replace band replaces pane 1's file with the dropped
    /// file (§22.4 comparison mode): pane 1 now holds the source's bytes and is
    /// attached to it; pane 0 is untouched.
    func testAReplaceBandDropInComparisonModeReplacesOnlyTheTargetPane() throws {
        let (controller, window, url1, url2) = try makeComparisonController([UInt8](0..<16), [UInt8](16..<32))
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }
        let pane1 = controller.windowModel.pane1
        let pane2 = controller.windowModel.pane2

        let source = try makeSourceFile([0xC0, 0xC1, 0xC2, 0xC3])
        controller.handleComparisonBandDrop(targetPane: 1, target: .replace, urls: [source])

        // Pane 1 replaced: it now holds the source's bytes and is attached to it.
        XCTAssertEqual(pane2.fileSize, 4)
        XCTAssertEqual(try paneBytes(pane2, 0..<4), [0xC0, 0xC1, 0xC2, 0xC3])
        XCTAssertEqual(pane2.status.fileName, source.lastPathComponent)
        // Pane 0 is untouched.
        XCTAssertEqual(pane1.fileSize, 16)
        XCTAssertFalse(pane1.isUntitled, "the other pane is untouched")
        _ = window
    }

    // MARK: - Mouse events pass through the overlays (§4.3)

    /// In single-file mode the two drop overlays (the three-band "this file"
    /// half and the "second file" half) sit on top of the hex dump. A hit-test
    /// at a point over the dump must return the hex view (or a descendant of the
    /// pane), NOT one of the overlays — otherwise the overlays swallow every
    /// click and drag over the dump, breaking selection and autoscroll. The
    /// file drag is owned by the always-present `SingleFileDropView` (the hex
    /// view's ancestor), reached by the drag system walking up from the dump.
    func testSingleFileOverlaysPassMouseEventsThroughToTheHexDump() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 256))
        defer { cleanup(controller, url) }

        let dropView = try XCTUnwrap(findView(SingleFileDropView.self, in: controller.view))
        let hexView = try XCTUnwrap(findView(HexView.self, in: controller.view))
        let scrollView = try XCTUnwrap(hexView.enclosingScrollView)
        // Force a full layout pass: the controller's complex hierarchy needs the
        // window sized before hit-testing is meaningful.
        window.setContentSize(NSSize(width: 800, height: 600))
        window.layoutIfNeeded()
        dropView.layoutSubtreeIfNeeded()
        // A point at the centre of the visible dump, in the drop view's own
        // coordinate system (hitTest expects the receiver's coordinates, not
        // window ones; the hex view's own centre can sit off-screen).
        let point = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: dropView)

        let hit = dropView.hitTest(point)
        XCTAssertNotNil(hit, "a hit over the hex dump must find a view")
        XCTAssertFalse(hit is PaneDropBandsView, "the three-band overlay must not swallow the click")
        XCTAssertFalse(hit is DropZoneView, "the second-file overlay must not swallow the click")
        let pane = try XCTUnwrap(findView(FilePaneView.self, in: controller.view))
        XCTAssertTrue(hit?.isDescendant(of: pane) ?? false,
                      "the click must land on the hex dump, not an overlay")
        _ = window
    }

    /// The `SingleFileDropView` is the registered file-drop destination in
    /// single-file mode: it is the hex view's ancestor, so the drag system
    /// reaches it by walking up from the dump (the overlays are not
    /// hit-testable and cannot steal the drag).
    func testTheSingleFileDropViewIsTheRegisteredDropDestination() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 256))
        defer { cleanup(controller, url) }

        let dropView = try XCTUnwrap(findView(SingleFileDropView.self, in: controller.view))
        XCTAssertTrue(dropView.registeredDraggedTypes.contains(.fileURL),
                      "the single-file drop view must be the file-drop destination")
        _ = window
    }

    /// The three-band overlay is purely visual in single-file mode and must NOT
    /// be a registered drop destination: the parent `SingleFileDropView` owns
    /// the drop. AppKit resolves the destination by frame among registered
    /// views (not via the `hitTest:` override), so a registered overlay would be
    /// picked as the deepest destination and steal the drop — whose `onDrop` is
    /// nil in single-file mode, silently discarding the file (§4.3, §22.4).
    func testTheSingleFileBandOverlayIsNotADropDestination() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 256))
        defer { cleanup(controller, url) }

        let bands = try XCTUnwrap(findView(PaneDropBandsView.self, in: controller.view))
        XCTAssertFalse(bands.registeredDraggedTypes.contains(.fileURL),
                       "the single-file band overlay must not register for file drags — the parent drop view owns the drop")
        _ = window
    }

    /// Recursively finds the first view of type `T` in the hierarchy rooted at
    /// `root`.
    private func findView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        for subview in root.subviews {
            if let match = subview as? T { return match }
            if let found = findView(type, in: subview) { return found }
        }
        return nil
    }
}
