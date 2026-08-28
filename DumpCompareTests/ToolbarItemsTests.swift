import Cocoa
import XCTest
@testable import DumpCompare

/// §24: the toolbar's two groups — the commands that act on the dump in the
/// active pane, and the controls that carry a state.
///
/// The mechanism is the one §10.3 established for the difference arrows: an
/// item's enabled state is answered in `validateToolbarItem`, never pushed,
/// because AppKit revalidates visible items on its own schedule and would undo
/// a pushed value. The state the two stateful items DISPLAY is pushed from the
/// same place, so it can never drift from what validation reports.
@MainActor
final class ToolbarItemsTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: WordSize.userDefaultsKey)
        UserDefaults.standard.set(true, forKey: LayoutSettings.layoutDirectionKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WordSize.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: LayoutSettings.layoutDirectionKey)
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    private func file(_ byte: UInt8) throws -> URL {
        let url = try tempFile([UInt8](repeating: byte, count: 64))
        tempFiles.append(url)
        return url
    }

    /// A shown window whose toolbar is realised and validated once.
    private func makeWindow() -> (MainWindowController, NSWindow) {
        let wc = MainWindowController()
        wc.showWindow(nil)
        let window = wc.window!
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 600), display: true)
        // The difference block is in the configured items and taken out a
        // run-loop turn later, with no file open (§10.3) — wait for that, or the
        // toolbar is read mid-reconfiguration.
        _ = pumpUntil(2) {
            (window.toolbar?.items.count ?? 0) >= 11
                && !(window.toolbar?.items.contains { $0.itemIdentifier == .diffNavigation } ?? true)
        }
        window.layoutIfNeeded()
        window.toolbar?.validateVisibleItems()
        return (wc, window)
    }

    private func item(_ window: NSWindow, _ id: NSToolbarItem.Identifier) throws -> NSToolbarItem {
        try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == id },
                      "the toolbar carries \(id.rawValue)")
    }

    // MARK: - Composition

    /// The order is the layout: the document commands, a space, the two
    /// stateful controls, the flexible space that pins the right-hand group to
    /// the window's edge, then the difference plaque, the pane arrangement and
    /// the minimap — each set apart by a system space (§24).
    func testTheToolbarIsTwoGroupsSplitByTheFlexibleSpace() throws {
        let (wc, window) = makeWindow()
        defer { wc.close() }
        let toolbar = try XCTUnwrap(window.toolbar)

        XCTAssertEqual(wc.toolbarDefaultItemIdentifiers(toolbar),
                       [.goTo, .find, .segments, .space, .insertMode, .wordSize,
                        .flexibleSpace, .diffNavigation, .space, .paneLayout, .space, .toggleMinimap])
        // The live items, with no file open: the difference block is carried
        // only in comparison mode (§10.3), everything else is always there.
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier),
                       [.goTo, .find, .segments, .space, .insertMode, .wordSize,
                        .flexibleSpace, .space, .paneLayout, .space, .toggleMinimap])
    }

    /// Every command routes straight at the controller, which resolves the
    /// active pane — the same routing the menu items use (§24.1).
    func testTheCommandsTargetTheController() throws {
        let (wc, window) = makeWindow()
        defer { wc.close() }
        let expected: [(NSToolbarItem.Identifier, Selector)] = [
            (.goTo, #selector(MainViewController.goToPosition)),
            (.find, #selector(MainViewController.findPattern)),
            (.segments, #selector(MainViewController.showSegments)),
            (.insertMode, #selector(MainViewController.toggleInsertMode(_:))),
            (.wordSize, #selector(MainViewController.setWordSize(_:))),
            (.paneLayout, #selector(MainViewController.togglePaneLayout)),
        ]
        for (id, action) in expected {
            let item = try self.item(window, id)
            XCTAssertEqual(item.target as? MainViewController, wc.mainViewController,
                           "\(id.rawValue) targets the controller")
            XCTAssertEqual(item.action, action, "\(id.rawValue)'s action")
            XCTAssertNotNil(item.toolTip, "\(id.rawValue) says what it does on hover")
        }
    }

    /// The whole toolbar fits the window the app opens at — in comparison mode,
    /// where the difference block is carried too (§24.4). AppKit moves trailing
    /// items into an overflow menu on a window too narrow for them, and a window
    /// that opens with its own minimap toggle behind a chevron reads as a bug.
    /// This is the check that fails when an item is added without room for it.
    func testTheWholeToolbarFitsTheLaunchWidth() throws {
        let (wc, window) = makeWindow()
        let controller = wc.mainViewController
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
        }
        try controller.windowModel.pane1.open(url: try file(0x11))
        try controller.windowModel.pane2.open(url: try file(0x22))
        controller.apply(mode: .comparison)
        _ = pumpUntil(2) { window.toolbar?.items.contains { $0.itemIdentifier == .diffNavigation } ?? false }

        window.setFrame(NSRect(x: 100, y: 100, width: MainViewController.launchContentWidth(), height: 600),
                        display: true)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let hidden = (window.toolbar?.items ?? []).filter { !$0.isVisible }.map(\.itemIdentifier.rawValue)
        XCTAssertEqual(hidden, [], "every item is on screen at the width the window opens at")
    }

    // MARK: - The document commands (§24.1)

    /// Go To, Find and Segments need a dump to act on: disabled on an empty
    /// window, enabled the moment a file is open, disabled again when it is
    /// closed. A live-looking button that does nothing when clicked is the
    /// failure this guards against.
    func testTheDocumentCommandsFollowTheActivePane() throws {
        let (wc, window) = makeWindow()
        let controller = wc.mainViewController
        defer { controller.windowModel.pane1.close(); wc.close() }
        let ids: [NSToolbarItem.Identifier] = [.goTo, .find, .segments]

        for id in ids {
            XCTAssertFalse(try item(window, id).isEnabled, "\(id.rawValue): nothing open")
        }

        try controller.windowModel.pane1.open(url: try file(0x11))
        controller.apply(mode: .singleFile)
        window.toolbar?.validateVisibleItems()
        for id in ids {
            XCTAssertTrue(try item(window, id).isEnabled, "\(id.rawValue): a file is open")
        }

        controller.windowModel.pane1.close()
        controller.apply(mode: .empty)
        window.toolbar?.validateVisibleItems()
        for id in ids {
            XCTAssertFalse(try item(window, id).isEnabled, "\(id.rawValue): closed again")
        }
    }

    // MARK: - The insert-mode toggle (§24.2)

    private func insertButton(_ window: NSWindow) throws -> NSButton {
        try XCTUnwrap(item(window, .insertMode).view as? NSButton,
                      "the insert-mode item is a push-on/push-off button")
    }

    /// The toggle carries the ACTIVE pane's typing mode — the mode is per pane
    /// (§7.6), so the button reads the pane the keys go to, and switching panes
    /// switches what it shows. It is never disabled: a typing mode is
    /// meaningful with no file open, exactly as the menu item is.
    func testTheInsertModeToggleCarriesTheActivePanesMode() throws {
        let (wc, window) = makeWindow()
        let controller = wc.mainViewController
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
        }
        let button = try insertButton(window)
        XCTAssertEqual(button.state, .off, "a fresh window types in overwrite mode")
        XCTAssertTrue(try item(window, .insertMode).isEnabled,
                      "a mode switch is meaningful with no file open")

        try controller.windowModel.pane1.open(url: try file(0x11))
        try controller.windowModel.pane2.open(url: try file(0x22))
        controller.apply(mode: .comparison)
        controller.windowModel.setActivePane(0)
        controller.toggleInsertMode(nil)
        XCTAssertTrue(controller.windowModel.pane1.isInsertMode)
        XCTAssertEqual(button.state, .on,
                       "the keyboard path lights the button without waiting for an idle pass")

        // The other pane is still in overwrite mode, and the button follows the
        // active one rather than the window.
        controller.windowModel.setActivePane(1)
        window.toolbar?.validateVisibleItems()
        XCTAssertEqual(button.state, .off, "pane 2 types in overwrite mode")
        controller.windowModel.setActivePane(0)
        window.toolbar?.validateVisibleItems()
        XCTAssertEqual(button.state, .on, "and back")
    }

    /// Clicking the button toggles the mode: the item's own action is only
    /// there for validation, so the click has to be the button's.
    func testClickingTheInsertModeButtonTogglesTheMode() throws {
        let (wc, window) = makeWindow()
        let controller = wc.mainViewController
        defer { controller.windowModel.pane1.close(); wc.close() }
        try controller.windowModel.pane1.open(url: try file(0x11))
        controller.apply(mode: .singleFile)

        let button = try insertButton(window)
        button.performClick(nil)
        XCTAssertTrue(controller.windowModel.activePane.isInsertMode, "the click switched the mode on")
        button.performClick(nil)
        XCTAssertFalse(controller.windowModel.activePane.isInsertMode, "and off again")
    }

    // MARK: - The word-size button (§24.2)

    private func wordSizeButton(_ window: NSWindow) throws -> NSPopUpButton {
        try XCTUnwrap(item(window, .wordSize).view as? NSPopUpButton,
                      "the word-size item is a menu button")
    }

    /// The button names the size in force and sets it. It says "1 Byte", not a
    /// bare digit: the number has to read as a word size, and an icon-only
    /// toolbar draws no labels.
    func testTheWordSizeButtonNamesAndSetsTheSize() throws {
        let (wc, window) = makeWindow()
        defer { wc.close() }
        let button = try wordSizeButton(window)

        XCTAssertEqual(button.numberOfItems, WordSize.allCases.count)
        XCTAssertEqual(button.itemTitles, ["1 Byte", "2 Bytes", "4 Bytes", "8 Bytes"],
                       "the menu names the sizes the way the View menu does")
        XCTAssertEqual(button.selectedTag(), WordSize.one.rawValue, "one byte is the default (§6)")
        XCTAssertEqual(button.title, "1 Byte")

        // Choosing 4 bytes sets the setting the hex views read.
        button.selectItem(withTag: WordSize.four.rawValue)
        wc.mainViewController.setWordSize(button)
        XCTAssertEqual(WordSize.current, .four)

        // And a change made elsewhere — the View menu, the Layout settings tab —
        // moves the button, without waiting for AppKit's own idle pass.
        WordSize.set(.eight)
        XCTAssertEqual(button.selectedTag(), WordSize.eight.rawValue)
        XCTAssertEqual(button.title, "8 Bytes")
    }

    /// A view setting, not something done to a file: the button stays live on an
    /// empty window, the way the minimap toggle does.
    func testTheWordSizeButtonIsAlwaysEnabled() throws {
        let (wc, window) = makeWindow()
        defer { wc.close() }
        XCTAssertTrue(try item(window, .wordSize).isEnabled)
        XCTAssertTrue(try wordSizeButton(window).isEnabled)
    }

    // MARK: - The pane-layout toggle (§24.3)

    /// The icon and the tooltip name the arrangement the click will produce, the
    /// way the Show/Hide Minimap item's title names its act — and the item is
    /// dead outside comparison mode, where there is only one pane to arrange
    /// (§24.3).
    func testThePaneLayoutIconNamesTheArrangementItWillProduce() throws {
        let (wc, window) = makeWindow()
        let controller = wc.mainViewController
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
        }
        let layout = try item(window, .paneLayout)
        XCTAssertFalse(layout.isEnabled, "nothing open: no panes to arrange")

        try controller.windowModel.pane1.open(url: try file(0x11))
        try controller.windowModel.pane2.open(url: try file(0x22))
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        window.toolbar?.validateVisibleItems()

        XCTAssertTrue(layout.isEnabled, "two panes: the arrangement is a choice")
        XCTAssertEqual(layout.image?.accessibilityDescription, "Stack Panes",
                       "side by side now, so the click offers stacked")
        XCTAssertEqual(layout.toolTip, "Stack the panes")

        controller.togglePaneLayout()
        window.layoutIfNeeded()
        XCTAssertFalse(LayoutSettings.isVertical, "the panes are stacked now")
        XCTAssertEqual(layout.image?.accessibilityDescription, "Side-by-Side Panes",
                       "and the icon offers the way back at once, not on the next idle pass")
        XCTAssertEqual(layout.toolTip, "Place the panes side by side")

        controller.windowModel.pane2.close()
        controller.apply(mode: .singleFile)
        window.toolbar?.validateVisibleItems()
        XCTAssertFalse(layout.isEnabled, "one pane left: nothing to arrange")
    }
}
