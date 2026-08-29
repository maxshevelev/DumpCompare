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

    /// The whole point of the registry: a file another window already holds is
    /// not opened a second time. Two live documents over one file are two dirty
    /// states, two watchers, and a piece table whose base moves under it when
    /// the other one saves.
    ///
    /// Choosing "Show in Its Tab" brings that window forward with the file's
    /// pane active — the default answer, and what the test seam picks.
    func testOpeningAFileOpenInAnotherWindowGoesToThatWindow() throws {
        let registry = OpenDocumentRegistry()
        let first = MainViewController()
        let second = MainViewController()
        for controller in [first, second] {
            controller.openDocuments = registry
            registry.register(controller)
        }

        let other = try tempFile([UInt8](repeating: 0x11, count: 48))
        let wanted = try tempFile([UInt8](repeating: 0x7E, count: 48))
        first.openFiles([other, wanted])
        XCTAssertEqual(first.windowModel.pane2.status.fileName, wanted.lastPathComponent,
                       "the first window holds the wanted file in its second pane")
        first.windowModel.setActivePane(0)

        second.openFiles([wanted])

        XCTAssertFalse(second.windowModel.pane1.isOpen,
                       "the same file must not be open in two windows at once")
        XCTAssertNil(second.lastAlertTitle,
                     "the three-way question is not the dead-end alert")
        XCTAssertEqual(first.windowModel.activePaneIndex, 1,
                       "the window holding it activates the pane that does")
    }

    /// Within one window the refusal stands: both panes are already in front of
    /// the user, so there is nowhere to take them.
    func testOpeningAFileOpenInThisWindowsOtherPaneIsRefused() throws {
        let controller = MainViewController()
        let first = try tempFile([UInt8](repeating: 0x22, count: 32))
        let second = try tempFile([UInt8](repeating: 0x33, count: 32))
        controller.openFiles([first, second])
        // Aim the open at the pane that does NOT hold it: opening a file into
        // the pane already showing it is a reload (rule 5), not a clash.
        controller.windowModel.setActivePane(1)

        controller.openFiles([first])

        XCTAssertEqual(controller.lastAlertTitle, "File already open")
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

    /// A second window opens at a usable size.
    ///
    /// A window arrives with a degenerate frame — 1×84 when measured — and it is
    /// `showWindow`'s repair that has always given it its height. Skipping that
    /// repair for a window with no autosaved frame, on the grounds that it had
    /// nothing to restore, left the second window 84 points tall: the frame was
    /// never about the autosave.
    func testASecondWindowOpensAtAUsableSize() {
        let first = MainWindowController()
        defer { first.close() }
        first.showWindow(nil)

        let second = MainWindowController(frameAutosaveName: nil)
        defer { second.close() }
        second.showWindow(nil)

        let frame = second.window?.frame ?? .zero
        XCTAssertGreaterThan(frame.height, 200, "a new window must not open as a sliver")
        XCTAssertGreaterThan(frame.width, 200)
    }

    // MARK: - The window's name

    /// A window is named after the files it holds, because that name is what the
    /// tab bar and the Window menu show. An empty window keeps the app's name:
    /// it holds no document, and "Untitled" already means a New File that has
    /// never been saved.
    func testTheWindowIsNamedAfterItsFiles() throws {
        let controller = MainViewController()
        XCTAssertEqual(controller.windowTitle, "Empty", "nothing open says so")

        let a = try tempFile([UInt8](repeating: 0xA1, count: 32))
        controller.openFiles([a])
        XCTAssertEqual(controller.windowTitle, a.lastPathComponent)

        let b = try tempFile([UInt8](repeating: 0xB2, count: 32))
        controller.openFiles([b])
        XCTAssertEqual(controller.windowTitle,
                       "\(a.lastPathComponent) ↔ \(b.lastPathComponent)",
                       "a comparison is named after both of its files")
    }

    /// The name reaches the window, not just the computed property — it rides
    /// the signal the pane headers ride, so opening a file moves both at once.
    func testOpeningAFileRenamesTheWindow() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        wc.showWindow(nil)
        XCTAssertEqual(wc.window?.title, "Empty")

        let url = try tempFile([UInt8](repeating: 0xC3, count: 32))
        wc.mainViewController.openFiles([url])

        XCTAssertEqual(wc.window?.title, url.lastPathComponent)
    }

    /// A tab is labelled by its window's title even though the title bar itself
    /// is hidden (the toolbar occupies it, §10.3). The two are separate: hiding
    /// the title hides the text drawn in the title bar, not the name the window
    /// answers to.
    func testATabIsLabelledByItsWindowsTitle() throws {
        let host = MainWindowController()
        defer { host.close() }
        let joiner = MainWindowController(frameAutosaveName: nil)
        defer { joiner.close() }
        // Tabbing is disallowed under test so a dozen suites do not merge their
        // windows; this one is about tabs, so it opts back in.
        for controller in [host, joiner] {
            controller.window?.tabbingMode = .automatic
        }
        host.showWindow(nil)

        let url = try tempFile([UInt8](repeating: 0xD4, count: 32))
        joiner.mainViewController.openFiles([url])
        guard let hostWindow = host.window, let joined = joiner.window else {
            return XCTFail("both windows exist")
        }
        hostWindow.addTabbedWindow(joined, ordered: .above)

        XCTAssertEqual(hostWindow.titleVisibility, .hidden, "the premise: the title bar shows no text")
        XCTAssertEqual(joined.tab.title, url.lastPathComponent,
                       "the tab reads the window's title regardless")
        XCTAssertEqual(hostWindow.tabGroup?.windows.count, 2)
    }

    // MARK: - New Tab

    /// ⌘T is the app's own command, not one AppKit contributes. Automatic
    /// tabbing supplies the bar, Merge All Windows and Move Tab to New Window;
    /// the New Tab item and its key are ours to add, the way Terminal and Safari
    /// add theirs. Leaving it to the system left ⌘T doing nothing at all.
    func testNewTabSitsInTheFileMenuUnderCommandT() throws {
        let item = try XCTUnwrap(MainMenu.makeFileMenu().items.first { $0.title == "New Tab" },
                                 "a File item making a tab")

        XCTAssertEqual(item.keyEquivalent, "t")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item.action, #selector(MainViewController.newTab(_:)))
        XCTAssertNil(item.target, "it lands on the key window's controller")
    }

    /// New Tab asks the window it was invoked from for a sibling, so the tab
    /// joins that window rather than an arbitrary one.
    func testNewTabAsksTheWindowItCameFrom() {
        let controller = MainViewController()
        var asked = 0
        controller.makeSiblingTab = {
            asked += 1
            return MainViewController()
        }

        controller.newTab(nil)

        XCTAssertEqual(asked, 1)
    }

    /// The tab bar's + button calls `newWindowForTab(_:)`, and AppKit looks for
    /// it along the *window's* responder chain — which ends at the window
    /// controller. Implementing it on the app delegate alone, past the end of
    /// that chain, left the button with nothing to call.
    func testTheTabBarsPlusButtonReachesTheWindowController() {
        let wc = MainWindowController()
        defer { wc.close() }
        var asked = 0
        wc.mainViewController.makeSiblingTab = {
            asked += 1
            return MainViewController()
        }

        XCTAssertTrue(wc.responds(to: #selector(NSWindowController.newWindowForTab(_:))),
                      "the window controller must answer, or AppKit hides the + button")
        wc.newWindowForTab(nil)

        XCTAssertEqual(asked, 1)
    }

    // MARK: - The choice when a file is open elsewhere

    /// Keeps the registry alive for the length of a test. `openDocuments` is a
    /// weak back-reference to something the app owns, so a registry made and
    /// left inside a helper is deallocated on the way out — and every controller
    /// quietly falls back to answering rule 6 from its own two panes.
    private var registry: OpenDocumentRegistry?

    /// Two windows sharing a registry, the first holding `wanted` in its second
    /// pane, the second empty and about to ask for it.
    private func twoWindowsOneFile() throws -> (holder: MainViewController,
                                                asker: MainViewController,
                                                wanted: URL) {
        let registry = OpenDocumentRegistry()
        self.registry = registry
        addTeardownBlock { self.registry = nil }
        let holder = MainViewController()
        let asker = MainViewController()
        for controller in [holder, asker] {
            controller.openDocuments = registry
            registry.register(controller)
        }
        let other = try tempFile([UInt8](repeating: 0x11, count: 48))
        let wanted = try tempFile([UInt8](repeating: 0x7E, count: 48))
        holder.openFiles([other, wanted])
        return (holder, asker, wanted)
    }

    /// Answers the next alert with `button`, and stops afterwards.
    private func answerAlerts(with button: NSApplication.ModalResponse) {
        MainViewController.modalResponder = { _ in button }
        addTeardownBlock { MainViewController.modalResponder = nil }
    }

    /// The question names the file and offers all three answers, with Cancel
    /// last so AppKit gives it the Escape key.
    func testTheQuestionOffersShowMoveAndCancel() throws {
        // `holder` is bound rather than discarded: the registry holds its
        // windows weakly, so a controller nothing keeps drops out of it and
        // there is no clash left to ask about.
        let (holder, asker, wanted) = try twoWindowsOneFile()
        XCTAssertTrue(holder.windowModel.pane2.isOpen, "the premise")
        var seen: NSAlert?
        MainViewController.modalResponder = { alert in
            seen = alert
            return .alertThirdButtonReturn
        }
        addTeardownBlock { MainViewController.modalResponder = nil }

        asker.openFiles([wanted])

        let alert = try XCTUnwrap(seen, "opening a file open elsewhere must ask")
        XCTAssertTrue(alert.messageText.contains(wanted.lastPathComponent),
                      "the question names the file")
        XCTAssertEqual(alert.buttons.map(\.title),
                       ["Show in Its Tab", "Move to This Tab", "Cancel"])
    }

    /// Cancel leaves both windows exactly as they were.
    func testCancellingLeavesEverythingWhereItWas() throws {
        let (holder, asker, wanted) = try twoWindowsOneFile()
        answerAlerts(with: .alertThirdButtonReturn)

        asker.openFiles([wanted])

        XCTAssertFalse(asker.windowModel.pane1.isOpen, "nothing opened here")
        XCTAssertEqual(holder.windowModel.pane2.status.fileName, wanted.lastPathComponent,
                       "and nothing moved out of there")
        XCTAssertEqual(holder.mode, .comparison)
    }

    /// "Move to This Tab" is the answer that actually opens it here: the pane
    /// itself moves, so the file is still open exactly once, and the window it
    /// came from keeps its other file on its own.
    func testMovingBringsThePaneItselfAcrossWindows() throws {
        let (holder, asker, wanted) = try twoWindowsOneFile()
        let moved = holder.windowModel.pane2
        answerAlerts(with: .alertSecondButtonReturn)

        asker.openFiles([wanted])

        XCTAssertIdentical(asker.windowModel.pane1, moved,
                           "the same pane object, not a second document over one file")
        XCTAssertEqual(asker.mode, .singleFile)
        XCTAssertEqual(holder.mode, .singleFile, "the comparison it left is over")
        XCTAssertFalse(holder.windowModel.pane2.isOpen)
    }

    /// The moved pane brings its unsaved edits — it is moved, never re-read.
    func testMovingCarriesUnsavedEdits() throws {
        let (holder, asker, wanted) = try twoWindowsOneFile()
        try holder.windowModel.pane2.pasteWrite([0xFF, 0xFE])
        XCTAssertTrue(holder.windowModel.pane2.status.isDirty, "the premise")
        answerAlerts(with: .alertSecondButtonReturn)

        asker.openFiles([wanted])

        XCTAssertTrue(asker.windowModel.pane1.status.isDirty,
                      "the edits came along; the file was not re-read from disk")
    }

    /// A pane reads the bookmark list of the window it is in, so a moved pane
    /// adopts the receiving window's marks. The lists are not merged: two
    /// windows' notes on one row cannot both survive, and one row holds one
    /// bookmark.
    func testAMovedPaneAdoptsTheReceivingWindowsBookmarks() throws {
        let (holder, asker, wanted) = try twoWindowsOneFile()
        _ = holder.windowModel.bookmarkStore.add(rowContaining: 0, name: "theirs")
        _ = asker.windowModel.bookmarkStore.add(rowContaining: 16, name: "ours")
        answerAlerts(with: .alertSecondButtonReturn)

        asker.openFiles([wanted])

        XCTAssertIdentical(asker.windowModel.pane1.bookmarkStore, asker.windowModel.bookmarkStore)
        XCTAssertEqual(asker.windowModel.bookmarkStore.bookmarks.map(\.name), ["ours"],
                       "the receiving window's list, unmerged")
    }
}
