import XCTest
@testable import DumpCompare

/// §3, §4.1: more than one window, before there are tabs.
///
/// A tab is a window (`Design/TABS_PLAN.md`), so everything here is what tabs
/// will stand on. The questions are the ones a second window asks for the first
/// time: does a window keep its own panes and its own marks, does "the same file
/// is already open" still mean anything once the other pane can be in another
/// window, and does the second window stop fighting the first over one saved
/// frame.
@MainActor
final class MultiWindowTests: XCTestCase {

    // MARK: - The command

    /// New Window sits in the File menu under ⇧⌘N, carrying no target: it is
    /// the app delegate that owns the windows, and the responder chain is what
    /// carries the command past every view controller to reach it.
    func testNewWindowSitsInTheFileMenuUnderShiftCommandN() throws {
        let item = try XCTUnwrap(MainMenu.makeFileMenu().items.first { $0.title == "New Window" },
                                 "a File item making a window")

        XCTAssertEqual(item.keyEquivalent, "N", "⇧⌘N — the capital is the shift")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item.action, #selector(AppDelegate.newWindow(_:)))
        XCTAssertNil(item.target, "New Window must travel the responder chain to the app delegate")
    }

    /// New File and New Window are different commands on different keys — the
    /// two are easy to conflate by ear, and ⌘N stays the document (§4).
    func testNewFileAndNewWindowAreDistinctCommands() {
        let items = MainMenu.makeFileMenu().items
        let newFile = items.first { $0.title == "New File" }
        let newWindow = items.first { $0.title == "New Window" }

        XCTAssertEqual(newFile?.keyEquivalent, "n")
        XCTAssertEqual(newWindow?.keyEquivalent, "N")
        XCTAssertEqual(newFile?.action, #selector(MainViewController.newDocument))
        XCTAssertNotEqual(newFile?.action, newWindow?.action)
    }

    // MARK: - A window keeps its own everything

    /// Two windows are two comparisons: separate panes, and separate bookmark
    /// lists. The list is the window's (§20) — a mark made in one must not
    /// appear in the other, which is also the rule the tear-off will copy
    /// against.
    func testTwoWindowsKeepSeparatePanesAndBookmarks() throws {
        let first = MainViewController()
        let second = MainViewController()

        let urlA = try tempFile([UInt8](repeating: 0xAA, count: 64))
        let urlB = try tempFile([UInt8](repeating: 0xBB, count: 64))
        try first.windowModel.pane1.open(url: urlA)
        try second.windowModel.pane1.open(url: urlB)

        XCTAssertNotIdentical(first.windowModel, second.windowModel)
        XCTAssertEqual(first.windowModel.pane1.status.fileName, urlA.lastPathComponent)
        XCTAssertEqual(second.windowModel.pane1.status.fileName, urlB.lastPathComponent)

        _ = first.windowModel.bookmarkStore.add(rowContaining: 0, name: "first only")

        XCTAssertEqual(first.windowModel.bookmarkStore.bookmarks.count, 1)
        XCTAssertTrue(second.windowModel.bookmarkStore.bookmarks.isEmpty,
                      "a mark made in one window must not appear in the other")
    }

    // MARK: - Rule 6 across windows

    /// The registry answers "where is this file open?" for the whole app. The
    /// pane a caller is about to open into is excluded: the target of an open is
    /// never its own obstacle (a file already there is a reload, §4.1 rule 5).
    func testTheRegistryFindsAFileOpenInAnotherWindow() throws {
        let registry = OpenDocumentRegistry()
        let first = MainViewController()
        let second = MainViewController()
        registry.register(first)
        registry.register(second)

        let url = try tempFile([UInt8](repeating: 0x5A, count: 32))
        try first.windowModel.pane1.open(url: url)

        let found = registry.location(of: url, excluding: (second, 0))
        XCTAssertIdentical(found?.controller, first)
        XCTAssertEqual(found?.paneIndex, 0)

        XCTAssertNil(registry.location(of: url, excluding: (first, 0)),
                     "the pane holding it is the one being opened into: a reload, not a clash")
    }

    /// Registering the same controller twice must not make it answer twice, so
    /// a caller need not track whether it has already registered.
    func testRegisteringTwiceIsANoOp() throws {
        let registry = OpenDocumentRegistry()
        let controller = MainViewController()
        registry.register(controller)
        registry.register(controller)

        let url = try tempFile([UInt8](repeating: 0x01, count: 16))
        try controller.windowModel.pane1.open(url: url)

        XCTAssertNotNil(registry.location(of: url, excluding: nil))
    }

    /// The whole point of the registry: opening a file that another window
    /// already holds is refused, with the pane left as it was. Two live
    /// documents over one file are two dirty states, two watchers, and a piece
    /// table whose base moves under it when the other one saves.
    func testOpeningAFileAlreadyOpenInAnotherWindowIsRefused() throws {
        let registry = OpenDocumentRegistry()
        let first = MainViewController()
        let second = MainViewController()
        for controller in [first, second] {
            controller.openDocuments = registry
            registry.register(controller)
        }

        let url = try tempFile([UInt8](repeating: 0x7E, count: 48))
        first.openFiles([url])
        XCTAssertTrue(first.windowModel.pane1.isOpen, "the first window took the file")

        second.openFiles([url])

        XCTAssertFalse(second.windowModel.pane1.isOpen,
                       "the same file must not be open in two windows at once")
        XCTAssertEqual(second.lastAlertTitle, "File already open")
    }

    /// Without a registry a controller answers the rule from its own two panes,
    /// which is what a single window has always done — every test builds a
    /// controller on its own, and none of them should start seeing each other's
    /// files.
    func testAControllerWithNoRegistryAnswersFromItsOwnPanesAlone() throws {
        let first = MainViewController()
        let second = MainViewController()

        let url = try tempFile([UInt8](repeating: 0x33, count: 32))
        first.openFiles([url])
        second.openFiles([url])

        XCTAssertTrue(first.windowModel.pane1.isOpen)
        XCTAssertTrue(second.windowModel.pane1.isOpen,
                      "no registry: the other controller is invisible, as it always was")
    }

    // MARK: - The frame

    /// One autosave name can serve one window. The launch window keeps
    /// "MainWindow"; a later window saves no frame at all and is cascaded off
    /// the one in front instead, so the two never write over each other's saved
    /// size (§3.1).
    ///
    /// The first assertion is also a regression test for a silent one: the name
    /// has to be set *after* `super.init(window:)`, because a window controller
    /// taking ownership of a window clears the name it was carrying. Set in the
    /// lines above it, as it was, the call does nothing at all and no frame is
    /// ever saved — which is why the window used to open at its default size
    /// every launch while the code said otherwise.
    func testOnlyTheFirstWindowClaimsTheFrameAutosaveName() {
        let first = MainWindowController()
        defer { first.close() }
        let second = MainWindowController(frameAutosaveName: nil)
        defer { second.close() }

        XCTAssertEqual(first.window?.frameAutosaveName, "MainWindow",
                       "the name must survive super.init(window:)")
        XCTAssertEqual(second.window?.frameAutosaveName, "",
                       "no name: AppKit reports the empty string for a window that saves nothing")
    }
}
