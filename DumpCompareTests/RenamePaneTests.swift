import Cocoa
import XCTest
@testable import DumpCompare

/// §23: naming a document that has no file yet.
///
/// An unsaved document's name is a label — the header's, the save panel's
/// starting point, and the base every piece's file name is built from when the
/// partition is written out (§21.5). That last one is why it is worth being able
/// to set: Save All as Separate Files asks for a folder and nothing else, so
/// without a name of its own a copy's pieces all arrive called `Untitled_S0.bin`.
@MainActor
final class RenamePaneTests: XCTestCase {

    // MARK: - The rule

    /// Space at either end reads as a mistake in a header and makes a file
    /// indistinguishable from its neighbour.
    func testANameIsTrimmed() {
        XCTAssertEqual(PaneName.sanitized("  bios.bin \n"), "bios.bin")
    }

    /// A separator in a name is not a name: the file it would make lives
    /// somewhere else, or nowhere. It is dropped, and the header shows what is
    /// left, so the user can see it and say it differently.
    func testTheSeparatorsAreDropped() {
        XCTAssertEqual(PaneName.sanitized("bios/1.bin"), "bios1.bin")
        XCTAssertEqual(PaneName.sanitized("bios:1.bin"), "bios1.bin")
    }

    /// A name of nothing asks for nothing.
    func testANameOfNothingIsRefused() {
        XCTAssertNil(PaneName.sanitized(""))
        XCTAssertNil(PaneName.sanitized("   "))
        XCTAssertNil(PaneName.sanitized("//"))
    }

    // MARK: - Which panes have a name to change

    /// A New File and a copy: both are documents with no file behind them, so
    /// their names are labels.
    func testAnUnsavedDocumentCanBeRenamed() throws {
        let controller = MainViewController()
        controller.newDocument()
        XCTAssertTrue(controller.windowModel.pane1.canRename)

        let url = try tempFile([UInt8](repeating: 0xAA, count: 32))
        let second = MainViewController()
        second.openFiles([url])
        second.duplicate(from: second.windowModel.pane1)
        XCTAssertTrue(second.windowModel.pane2.canRename, "a copy is unsaved too")
    }

    /// A saved document's name is its file's, and moving a file is Save As's
    /// business. An empty pane has no name at all.
    func testAFileAndAnEmptyPaneCannotBeRenamed() throws {
        let controller = MainViewController()
        XCTAssertFalse(controller.windowModel.pane1.canRename, "nothing is open")

        let url = try tempFile([UInt8](repeating: 0xAA, count: 32))
        controller.openFiles([url])
        XCTAssertFalse(controller.windowModel.pane1.canRename)
        XCTAssertFalse(controller.windowModel.pane1.rename(to: "other.bin"))
        XCTAssertEqual(controller.windowModel.pane1.status.fileName, url.lastPathComponent)
    }

    /// The name the header shows follows the rename, and nothing is written:
    /// the file appears when the document is saved, not when it is named.
    func testRenamingChangesTheNameAndWritesNothing() {
        let controller = MainViewController()
        controller.newDocument()
        let pane = controller.windowModel.pane1

        XCTAssertTrue(pane.rename(to: "patched.bin"))

        XCTAssertEqual(pane.status.fileName, "patched.bin")
        XCTAssertTrue(pane.isUntitled, "still nothing on disk")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: FileManager.default.currentDirectoryPath + "/patched.bin"))
    }

    /// A name that survives as nothing leaves the old one alone — a field closed
    /// by accident must not blank the header.
    func testAnEmptyNameLeavesTheOldOne() {
        let controller = MainViewController()
        controller.newDocument()
        let pane = controller.windowModel.pane1
        XCTAssertTrue(pane.rename(to: "patched.bin"))

        XCTAssertFalse(pane.rename(to: "   "))

        XCTAssertEqual(pane.status.fileName, "patched.bin")
    }

    // MARK: - The field in the header

    /// A window-hosted controller holding a New File, and that pane's view — the
    /// window first, so the pane the document lands in is one the window built.
    private func newFilePane() throws -> (MainViewController, NSWindow, FilePaneView) {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // Left open when the test ends, like every other windowed suite here: a
        // programmatically made window is released when closed, and closing it
        // out from under the views the test still holds crashes a later suite.
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.newDocument()
        window.layoutIfNeeded()
        let view = try XCTUnwrap(descendants(of: controller.view, FilePaneView.self).first)
        return (controller, window, view)
    }

    /// The editor opens carrying the name the header was showing — the name is
    /// changed, not typed again from nothing.
    func testTheFieldOpensWithTheNameTheHeaderShows() throws {
        let (controller, _, view) = try newFilePane()
        controller.windowModel.pane1.rename(to: "dump.bin")

        view.beginRenaming()

        XCTAssertTrue(view.isRenaming)
        XCTAssertEqual(view.renameFieldForTesting?.stringValue, "dump.bin")
    }

    /// Committing writes the name and puts the title back.
    func testCommittingTheFieldWritesTheName() throws {
        let (controller, _, view) = try newFilePane()
        view.beginRenaming()
        let field = try XCTUnwrap(view.renameFieldForTesting)
        field.stringValue = "patched.bin"

        _ = view.control(field, textView: NSTextView(),
                         doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertFalse(view.isRenaming, "the field is gone")
        XCTAssertEqual(controller.windowModel.pane1.status.fileName, "patched.bin")
    }

    /// Escape leaves the name as it was, whatever was typed.
    func testEscapeLeavesTheNameAlone() throws {
        let (controller, _, view) = try newFilePane()
        view.beginRenaming()
        let field = try XCTUnwrap(view.renameFieldForTesting)
        field.stringValue = "typed-then-abandoned.bin"

        _ = view.control(field, textView: NSTextView(),
                         doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertFalse(view.isRenaming)
        XCTAssertEqual(controller.windowModel.pane1.status.fileName, "Untitled")
    }

    /// Clicking away is a commit, the way the Finder's rename behaves: losing
    /// what was typed to a stray click is the worse surprise.
    func testLosingFocusCommits() throws {
        let (controller, _, view) = try newFilePane()
        view.beginRenaming()
        try XCTUnwrap(view.renameFieldForTesting).stringValue = "clicked-away.bin"

        view.endRenaming(commit: true)

        XCTAssertEqual(controller.windowModel.pane1.status.fileName, "clicked-away.bin")
    }

    // MARK: - The menu item

    /// Rename is in the header's File menu, and enabled only for a document
    /// whose name is the app's to change.
    func testTheMenuItemFollowsWhatCanBeRenamed() throws {
        let controller = MainViewController()
        let url = try tempFile([UInt8](repeating: 0xAA, count: 32))
        controller.openFiles([url])
        let menu = controller.makePaneMenu(for: controller.windowModel.pane1)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Rename" },
                                 "the header menu carries Rename")

        XCTAssertFalse(controller.validateMenuItem(item), "a file's name is its file's")

        controller.newDocumentInPane(item)
        XCTAssertTrue(controller.validateMenuItem(item), "an unsaved document's is not")
    }
}
