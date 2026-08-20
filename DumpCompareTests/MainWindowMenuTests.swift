import XCTest
@testable import DumpCompare

/// §11: ⌘V must reach the standard `paste:` action through the responder
/// chain, so a focused text field's editor pastes text while the focused hex
/// view performs paste-write. "Paste Write" must not claim ⌘V globally — that
/// intercept is what made ⌘V in Go To / Select Block / Find fire paste-write
/// into the dump instead of pasting into the field.
@MainActor
final class MainWindowMenuTests: XCTestCase {
    /// `buildMainMenu()` assigns `NSApp.mainMenu`; restore it so this suite
    /// leaves no process-wide side effect.
    private var previousMainMenu: NSMenu?

    override func setUp() {
        super.setUp()
        previousMainMenu = NSApp.mainMenu
    }

    override func tearDown() {
        NSApp.mainMenu = previousMainMenu
        previousMainMenu = nil
        super.tearDown()
    }

    private func makeEditMenu() -> NSMenu {
        MainWindowController().makeEditMenu()
    }

    // MARK: - ⌘V routing

    /// The ⌘V key equivalent belongs to the standard "Paste" item, whose
    /// `paste:` action dispatches through the responder chain (target nil).
    func testCmdVIsStandardPasteNotPasteWrite() {
        let paste = makeEditMenu().items.first { $0.keyEquivalent == "v" }
        XCTAssertEqual(paste?.title, "Paste")
        XCTAssertEqual(paste?.action, #selector(NSText.paste(_:)))
        XCTAssertNil(paste?.target,
                     "paste: must go to the first responder, not a fixed target")
    }

    /// Plain Paste IS the paste-write in the dump (MainViewController.paste
    /// overwrites bytes when the hex view holds focus), so a separate
    /// "Paste Write" menu entry would only duplicate it — none should exist.
    func testNoSeparatePasteWriteEntry() {
        let write = makeEditMenu().items.first { $0.action == #selector(MainViewController.pasteWrite) }
        XCTAssertNil(write,
                     "Paste Write is redundant: Paste (⌘V) already overwrites bytes in the dump")
    }

    /// Structural sanity: standard "Paste" sits right after "Copy", followed
    /// only by the genuinely different insert mode, matching the system Edit
    /// menu layout.
    func testStandardPasteSitsAfterCopy() {
        let titles = makeEditMenu().items.map(\.title)
        XCTAssertEqual(titles.filter { $0 == "Copy" }.count, 1)
        let copyIndex = titles.firstIndex(of: "Copy")!
        XCTAssertEqual(titles[copyIndex + 1], "Paste")
        XCTAssertEqual(titles[copyIndex + 2], "Paste Insert…")
    }

    // MARK: - Insert Mode toggle

    /// The Edit menu carries the Insert Mode toggle, wired to the controller's
    /// `toggleInsertMode` (a checked mode item, not a one-shot command), bound
    /// to ⌥⌘I.
    func testEditMenuHasInsertModeToggle() {
        let item = makeEditMenu().items.first { $0.title == "Insert Mode" }
        XCTAssertNotNil(item, "the Edit menu should offer an Insert Mode toggle")
        XCTAssertEqual(item?.action, #selector(MainViewController.toggleInsertMode))
        XCTAssertEqual(item?.keyEquivalent, "i")
        XCTAssertEqual(item?.keyEquivalentModifierMask, [.command, .option])
    }

    /// The Insert Mode checkmark follows the ACTIVE pane's mode: the mode is per
    /// pane (§7.6), so the toggle flips the pane the keys go to and leaves the
    /// other one alone.
    func testInsertModeCheckmarkFollowsTheToggle() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)
        let editMenu = try XCTUnwrap(NSApp.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "Edit" })
        let item = try XCTUnwrap(editMenu.items.first {
            $0.action == #selector(MainViewController.toggleInsertMode)
        }, "an Edit item toggling insert mode")

        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        XCTAssertFalse(controller.windowModel.pane1.isInsertMode)
        XCTAssertFalse(controller.windowModel.pane2.isInsertMode)

        controller.toggleInsertMode(nil)

        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        XCTAssertTrue(controller.windowModel.pane1.isInsertMode, "the active pane flipped")
        XCTAssertFalse(controller.windowModel.pane2.isInsertMode, "the other pane did not")
        XCTAssertNotNil(controller.windowModel.pane1.confirmInsertModeWarning,
                        "the one-time warning is wired into the pane that flipped")
    }
}
