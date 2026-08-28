import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §23 Duplicate: in single-file mode, File ▸ Duplicate (and the pane header's
/// own twin) copies the pane's content into the free pane as an untitled,
/// never-saved document. The copy carries the source's unsaved edits and its
/// partition, becomes the active pane, and switches the window to comparison
/// mode — where it reads as identical to its source until one side is edited.
/// The source is left exactly as it was: same file, same edits, same watcher.
@MainActor
final class DuplicateTests: XCTestCase {
    /// A real controller in a real window (empty launch state).
    private func makeController() -> (MainViewController, NSWindow) {
        let controller = MainViewController()
        let window = makeTestWindow()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return (controller, window)
    }

    /// Close both panes (stops the file watchers) before the temp files go, so
    /// the external-change prompt cannot block the test with a modal.
    private func cleanup(_ controller: MainViewController) {
        controller.windowModel.pane1.close()
        controller.windowModel.pane2.close()
    }

    private func openFileIntoPane1(_ controller: MainViewController, _ url: URL) throws {
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
    }

    private func bytes(of pane: PaneViewModel) throws -> [UInt8] {
        try XCTUnwrap(pane.document).read(at: 0, length: Int(pane.fileSize))
    }

    // MARK: - What the copy is

    func testDuplicatePutsAnUntitledCopyOfTheContentInTheSecondPane() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([UInt8](0x10..<0x20))
        try openFileIntoPane1(controller, url)

        controller.duplicate(from: controller.windowModel.pane1)

        let copy = controller.windowModel.pane2
        XCTAssertEqual(controller.mode, .comparison,
                       "a second document must switch to comparison mode")
        XCTAssertTrue(copy.isOpen)
        XCTAssertTrue(copy.isUntitled, "the copy is a new document, not a file on disk")
        XCTAssertEqual(copy.status.fileName, "Untitled")
        XCTAssertTrue(copy.status.isDirty,
                      "content that has never been on disk must warn on close")
        XCTAssertFalse(copy.status.isReadOnly)
        XCTAssertEqual(try bytes(of: copy), [UInt8](0x10..<0x20))
        XCTAssertEqual(controller.windowModel.activePaneIndex, 1,
                       "the copy is what the user just made, so it becomes active")
    }

    /// The copy is of what the pane *shows*, edits included — not of the file on
    /// disk (§23).
    func testTheCopyCarriesTheSourcesUnsavedEdits() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([0x00, 0x01, 0x02, 0x03])
        try openFileIntoPane1(controller, url)
        let source = controller.windowModel.pane1
        try XCTUnwrap(source.document).overwrite(range: 1..<2, with: [0xAA])

        controller.duplicate(from: source)

        XCTAssertEqual(try bytes(of: controller.windowModel.pane2), [0x00, 0xAA, 0x02, 0x03])
    }

    /// The copy is the same bytes, so it is the same pieces: the cuts and the
    /// names — the record of which dump each half came from — come across (§23).
    func testTheCopyCarriesTheSourcesPartition() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([UInt8](repeating: 0x41, count: 64))
        try openFileIntoPane1(controller, url)
        let source = controller.windowModel.pane1
        XCTAssertTrue(source.segmentStore.addCut(at: 32))
        source.segmentStore.rename(1, to: "second-chip.bin")

        controller.duplicate(from: source)

        let copy = controller.windowModel.pane2
        XCTAssertEqual(copy.segmentStore.cuts, [32])
        XCTAssertEqual(copy.segmentStore.segments.map(\.name),
                       source.segmentStore.segments.map(\.name))
    }

    /// A duplicate leaves the source alone: it keeps its file, its edits and its
    /// dirty state, and records no undo step of its own.
    func testTheSourceIsUnchanged() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([0x00, 0x01, 0x02])
        try openFileIntoPane1(controller, url)
        let source = controller.windowModel.pane1
        try XCTUnwrap(source.document).overwrite(range: 0..<1, with: [0xAA])
        let canUndoBefore = source.status.canUndo

        controller.duplicate(from: source)

        XCTAssertFalse(source.isUntitled, "the source keeps its file")
        XCTAssertEqual(source.document?.url, url)
        XCTAssertEqual(source.status.fileName, url.lastPathComponent)
        XCTAssertEqual(try bytes(of: source), [0xAA, 0x01, 0x02])
        XCTAssertEqual(source.status.canUndo, canUndoBefore,
                       "a duplicate is not an edit on the source")
    }

    /// The two panes are separate documents from then on: editing one leaves the
    /// other where it was, which is the whole point of having the copy.
    func testTheTwoPanesAreIndependentAfterwards() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([0x00, 0x01, 0x02])
        try openFileIntoPane1(controller, url)
        let source = controller.windowModel.pane1
        controller.duplicate(from: source)
        let copy = controller.windowModel.pane2

        try XCTUnwrap(copy.document).overwrite(range: 0..<1, with: [0xEE])
        try XCTUnwrap(source.document).overwrite(range: 2..<3, with: [0xDD])

        XCTAssertEqual(try bytes(of: copy), [0xEE, 0x01, 0x02])
        XCTAssertEqual(try bytes(of: source), [0x00, 0x01, 0xDD])
    }

    /// The copy has no file behind it, so nothing watches one and no byte of it
    /// reads as modified until it has been saved and edited (§6).
    func testTheCopyHasNoSavedReferenceOfItsOwn() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([0x00, 0x01, 0x02])
        try openFileIntoPane1(controller, url)

        controller.duplicate(from: controller.windowModel.pane1)

        let copy = controller.windowModel.pane2
        XCTAssertNil(copy.savedStorage)
        XCTAssertTrue(copy.editedRanges.isEmpty,
                      "the copy's bytes are its content, not edits over a file")
    }

    // MARK: - When the command is available

    /// The copy needs a pane to land in and bytes to copy: no file, an empty
    /// untitled document, or both panes occupied all disable it (§23).
    func testDuplicateNeedsOneOpenPaneWithBytes() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let item = try XCTUnwrap(
            MainWindowController().makeFileMenu().items.first { $0.title == "Duplicate" })
        XCTAssertEqual(item.action, #selector(MainViewController.duplicateDocument))

        // Empty: nothing to copy.
        XCTAssertFalse(controller.validateMenuItem(item))

        // An untitled document with no bytes yet: still nothing to copy.
        controller.windowModel.pane1.openUntitled()
        controller.apply(mode: .singleFile)
        XCTAssertFalse(controller.validateMenuItem(item))

        // Single-file mode with content: available.
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 16))
        try openFileIntoPane1(controller, url1)
        XCTAssertTrue(controller.validateMenuItem(item))

        // Comparison mode: no free pane for the copy.
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 16))
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)
        XCTAssertFalse(controller.validateMenuItem(item))
    }

    /// The header menu's twin acts on the pane it was built for and is validated
    /// by the same rule.
    func testPaneMenuDuplicateActsOnItsOwnPane() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([UInt8](0x10..<0x20))
        try openFileIntoPane1(controller, url)
        let source = controller.windowModel.pane1
        let item = try XCTUnwrap(
            controller.makePaneMenu(for: source).items.first { $0.title == "Duplicate" })
        XCTAssertEqual(item.action, #selector(MainViewController.duplicatePaneDocument(_:)))
        XCTAssertTrue(item.representedObject as? PaneViewModel === source)
        XCTAssertTrue(controller.validateMenuItem(item))

        controller.duplicatePaneDocument(item)

        XCTAssertEqual(controller.mode, .comparison)
        XCTAssertTrue(controller.windowModel.pane2.isUntitled)
        XCTAssertEqual(try bytes(of: controller.windowModel.pane2), [UInt8](0x10..<0x20))
    }

    /// A no-op when the rule does not hold, however the command is reached: a
    /// stray call with both panes occupied must not replace the other pane's
    /// document.
    func testDuplicateDoesNothingWhenBothPanesAreOccupied() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 16))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 16))
        try openFileIntoPane1(controller, url1)
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)

        controller.duplicate(from: controller.windowModel.pane1)

        XCTAssertFalse(controller.windowModel.pane2.isUntitled)
        XCTAssertEqual(controller.windowModel.pane2.status.fileName, url2.lastPathComponent)
    }

    /// The transient status line names the source and the size: the copy's own
    /// header only says "Untitled", so this is where the pair is named (§23).
    func testTheStatusLineNamesTheSource() throws {
        let (controller, window) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([UInt8](repeating: 0x41, count: 1024))
        try openFileIntoPane1(controller, url)

        controller.duplicate(from: controller.windowModel.pane1)
        window.layoutIfNeeded()

        let comparison = try descendant(ComparisonView.self, of: window.contentView!)
        let labels = descendants(of: comparison.paneView2, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(labels.contains { $0.contains("Duplicated") && $0.contains(url.lastPathComponent) },
                      "expected a line naming the source, got: \(labels)")
    }
}
