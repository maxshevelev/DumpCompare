import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §11 Find: drives the whole flow through the real `MainViewController` —
/// Cmd+F shows the non-modal find bar, typing a pattern + Find Next runs a
/// background search and selects the match, the bar stays open (only Esc/Done
/// close it), and history + case sensitivity behave like TextEdit.
@MainActor
final class FindFlowTests: XCTestCase {
    /// A throwaway defaults domain, one per test run, so the tests never read or
    /// pollute the real app's `UserDefaults.standard` (e.g. patterns the user
    /// typed while trying the app by hand).
    private var isolatedSuiteName = ""
    private var isolatedDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        isolatedSuiteName = "FindFlowTests-\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: isolatedSuiteName)
        // Route the find feature's persistence (history + Aa toggle) at the
        // isolated store; restored to .standard in tearDown.
        FindHistoryStore.defaults = isolatedDefaults
        FindBarView.defaults = isolatedDefaults
    }

    override func tearDown() {
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        FindHistoryStore.defaults = .standard
        FindBarView.defaults = .standard
        isolatedDefaults = nil
        super.tearDown()
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("find-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    /// A real controller in a real window with one file open (single-file mode).
    /// The test host resizes the window to the pane's fitting size (which, with
    /// the hex dump's content-sized scroll view, would leave the results-panel
    /// split with zero height); pin a real content height so the layout has
    /// room for the dump and the panel.
    private func makeController(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        // Assigning contentViewController resizes the window to the controller's
        // (empty-mode) view's fitting size; re-affirm a real size so the pane's
        // first layout happens at its final height, not a shrunken one.
        window.setContentSize(NSSize(width: 800, height: 600))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.contentView?.heightAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true
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

    /// Pumps the main runloop until `condition` holds or the deadline passes.
    @discardableResult
    private func pumpUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Close the pane and delete the temp file. Closing stops the file watcher:
    /// deleting the file first would fire the external-change prompt, and that
    /// `NSAlert.runModal()` would block the test's main thread forever.
    private func cleanup(_ controller: MainViewController, _ url: URL) {
        controller.windowModel.pane1.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// The visible find bar in the window.
    private func findBar(_ window: NSWindow) throws -> FindBarView {
        try XCTUnwrap(descendants(of: window.contentView!, FindBarView.self).first { !$0.isHidden },
                      "the find bar must be visible")
    }

    /// The bar's controls: (pattern combo, encoding popup, Done, Aa case toggle).
    /// Navigation is two joined buttons, driven via `clickFindNext` /
    /// `clickFindPrevious`.
    private func barControls(_ window: NSWindow)
        throws -> (NSComboBox, NSPopUpButton, NSButton, NSButton) {
        let bar = try findBar(window)
        let combo = try XCTUnwrap(descendants(of: bar, NSComboBox.self).first, "pattern combo")
        let encoding = try XCTUnwrap(descendants(of: bar, NSPopUpButton.self).first, "encoding popup")
        let buttons = descendants(of: bar, NSButton.self)
        func button(_ label: String) throws -> NSButton {
            try XCTUnwrap(buttons.first { $0.accessibilityLabel() == label }, "button \(label)")
        }
        return (combo, encoding, try button("Done"), try button("Case Sensitive"))
    }

    /// Simulates the user picking an item from the combo's popup list. A real
    /// pick posts `selectionDidChangeNotification` (which the bar observes); the
    /// combo's action does NOT fire for a popup pick on an editable combo. The
    /// bar applies the load on the next runloop turn, so pump until the field
    /// holds the bare pattern and the pick's selection has been cleared.
    @discardableResult
    private func pickFromHistory(_ combo: NSComboBox, at index: Int,
                                 expecting pattern: String) -> Bool {
        combo.selectItem(at: index)
        NotificationCenter.default.post(name: NSComboBox.selectionDidChangeNotification, object: combo)
        return pumpUntil(2) { combo.indexOfSelectedItem < 0 && combo.stringValue == pattern }
    }

    /// Clicks the Find Next (`>`) button.
    private func clickFindNext(_ window: NSWindow) throws {
        try navButton(window, label: "Find Next").performClick(nil)
    }

    /// Clicks the Find Previous (`<`) button.
    private func clickFindPrevious(_ window: NSWindow) throws {
        try navButton(window, label: "Find Previous").performClick(nil)
    }

    /// A `<` `>` navigation button inside the find bar's joined block.
    private func navButton(_ window: NSWindow, label: String) throws -> NSButton {
        let bar = try findBar(window)
        return try XCTUnwrap(descendants(of: bar, NSButton.self).first { $0.accessibilityLabel() == label },
                             "nav button \(label)")
    }

    /// Whether any text field in the window shows `text` (e.g. a transient
    /// "No match found." in the pane's status bar).
    private func hasStatus(_ text: String, in window: NSWindow) -> Bool {
        descendants(of: window.contentView!, NSTextField.self).contains { $0.stringValue == text }
    }

    /// The Search All button in the find bar.
    private func findAllButton(_ window: NSWindow) throws -> NSButton {
        let bar = try findBar(window)
        return try XCTUnwrap(descendants(of: bar, NSButton.self).first { $0.accessibilityLabel() == "Find All" },
                             "Find All button")
    }

    /// The single file pane's Search All results panel.
    private func resultsView(_ window: NSWindow) throws -> SearchResultsView {
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        return paneView.searchResultsView
    }

    /// Runs a Search All for `pattern` and waits for it to finish: the panel
    /// opens immediately, and the header's trailing "…" drops once the
    /// background scan completes, so the table holds every match.
    @discardableResult
    private func runSearchAll(_ pattern: String, in window: NSWindow) throws -> SearchResultsView {
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = pattern
        try findAllButton(window).performClick(nil)
        let view = try resultsView(window)
        // The panel is shown immediately; the scan streams results in and the
        // "…" in the count drops when it completes. Wait for both.
        XCTAssertTrue(pumpUntil(5) { view.frame.height > 1 && !view.isSearching },
                      "Search All must show the results panel and finish scanning")
        return view
    }

    // MARK: - Flow

    /// The full happy path: Cmd+F → type a hex pattern → Find Next → the match
    /// is selected in the pane and the bar stays open.
    func testFindNextSelectsTheMatch() throws {
        let bytes: [UInt8] = [0x41, 0x42, 0x43, 0xDE, 0xAD, 0xBE, 0x44, 0x45, 0x46, 0x47]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "DE AD BE"
        try clickFindNext(window)

        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == 3 },
                      "Find Next must select the match")
        XCTAssertEqual(controller.windowModel.pane1.hexSelection().end, 6)
        XCTAssertFalse(try findBar(window).isHidden,
                       "the find bar must stay open after a successful search")
    }

    /// Find Previous from the caret finds the last match ending at/before the
    /// caret instead of the first one after it.
    func testFindPreviousFindsLastMatchBeforeCaret() throws {
        let bytes: [UInt8] = [0xAA, 0xAA, 0xAA, 0xAA, 0xAA]  // matches at 0,1,2,3
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        controller.windowModel.pane1.moveCaret(to: 4)

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindPrevious(window)

        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == 3 })
    }

    /// A pattern with no match reports it in the pane's status bar and keeps
    /// the find bar open.
    func testFindNoMatchShowsMessageAndKeepsBarOpen() throws {
        let bytes: [UInt8] = [0x41, 0x42, 0x43, 0x44]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "FF FF FF FF FF"
        try clickFindNext(window)

        XCTAssertTrue(pumpUntil(2) { self.hasStatus("No match found.", in: window) },
                      "the status bar must show No match found.")
        XCTAssertFalse(try findBar(window).isHidden,
                       "the find bar must stay open when there is no match")
    }

    /// After a Return search the focus stays in the pattern field, so a second
    /// Return re-searches instead of landing on the hex view (§11).
    func testEnterKeepsFocusForRepeatedSearch() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0x00, 0xDE, 0xAD, 0xBE]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "DE AD BE"
        // Focus the pattern field as the user would.
        window.makeFirstResponder(combo)

        // First Return searches and selects the first match. Wait for the full
        // selection (start == 0 is trivially true when nothing has happened),
        // so the second Return searches from a known completed state.
        combo.sendAction(combo.action!, to: combo.target)
        XCTAssertTrue(pumpUntil(3) { let s = controller.windowModel.pane1.hexSelection(); return s.start == 0 && s.end == 3 },
                      "first Return must run a search and select the match")
        // Focus must stay in the pattern field — a later Enter lands here, not
        // in the hex view.
        let responder = window.firstResponder
        XCTAssertTrue(responder === combo || responder === combo.currentEditor(),
                      "focus must stay in the pattern field after a Return search")

        // Second Return re-searches and finds the next match.
        combo.sendAction(combo.action!, to: combo.target)
        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == 4 },
                      "a subsequent Return must run the search again")
    }

    /// Pressing Return in the pattern field runs a forward search — the natural
    /// way to submit a find (§11).
    func testReturnInPatternFieldSearchesForward() throws {
        let bytes: [UInt8] = [0x41, 0x42, 0x43, 0xDE, 0xAD, 0xBE, 0x44]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "DE AD BE"

        // Return in the field triggers its action — the same path a user takes.
        combo.sendAction(combo.action!, to: combo.target)

        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == 3 },
                      "Return must run the search")
    }

    /// The Edit > Find menu item's action must reach the controller through the
    /// responder chain (nil target, exactly as the app builds it) and show the
    /// find bar — the full menu path, not a direct call. The test host has no
    /// key window (`NSApp.sendAction` with nil target starts from the key window
    /// and always fails headless), so dispatch through the window's own
    /// responder chain instead — same nil-target semantics, window-scoped.
    func testFindMenuItemDispatchesThroughResponderChain() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        let item = NSMenuItem(title: "Find", action: #selector(MainViewController.findPattern), keyEquivalent: "f")
        item.target = nil  // responder-chain, exactly as the app builds it

        window.makeFirstResponder(window.contentView)
        // NSWindow has no sendAction(_:to:from:) — dispatch manually through the
        // window's responder chain (contentView → MainViewController) instead.
        let dispatched = window.contentView?.tryToPerform(item.action!, with: item) ?? false
        XCTAssertTrue(dispatched, "Find must resolve to a responder")
        XCTAssertTrue(pumpUntil(2) { descendants(of: window.contentView!, FindBarView.self).first?.isHidden == false },
                      "Find must show the find bar")
    }

    /// Done closes the bar; Esc is wired as Done's key equivalent and closes it
    /// too (§11).
    func testEscAndDoneCloseTheBar() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        controller.findPattern()
        _ = try barControls(window)

        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                   timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, characters: "\u{1B}",
                                   charactersIgnoringModifiers: "\u{1B}",
                                   isARepeat: false, keyCode: 53)!
        _ = window.performKeyEquivalent(with: esc)

        XCTAssertTrue(pumpUntil(2) { descendants(of: window.contentView!, FindBarView.self).first?.isHidden == true },
                      "Esc must close the find bar")

        // Reopen and close with the Done button.
        controller.findPattern()
        let (_, _, done, _) = try barControls(window)
        done.performClick(nil)
        XCTAssertTrue(pumpUntil(2) { descendants(of: window.contentView!, FindBarView.self).first?.isHidden == true },
                      "Done must close the find bar")
    }

    // MARK: - History (§11)

    /// A successful search is remembered; reopening the bar offers the same
    /// pattern (and encoding) as the default.
    func testFindHistoryDefaultsToLastSearch() throws {
        let bytes: [UInt8] = [0x41, 0x42, 0x43, 0xDE, 0xAD, 0xBE, 0x44]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        var (combo, _, done, _) = try barControls(window)
        combo.stringValue = "DE AD BE"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == 3 })
        XCTAssertEqual(FindHistoryStore.mostRecent?.pattern, "DE AD BE")

        // Reopen: the last search is offered by default.
        done.performClick(nil)
        controller.findPattern()
        (combo, _, _, _) = try barControls(window)
        XCTAssertEqual(combo.stringValue, "DE AD BE")
    }

    /// The encoding used for a search is stored with it and restored on reopen.
    func testFindHistoryStoresAndRestoresEncoding() throws {
        let bytes: [UInt8] = Array("Hi there, how are you?".utf8)
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        var (combo, encoding, done, _) = try barControls(window)
        encoding.selectItem(at: SearchEncoding.allCases.firstIndex(of: .utf8)!)
        encoding.sendAction(encoding.action, to: encoding.target)
        combo.stringValue = "Hi"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == 0 })

        XCTAssertEqual(FindHistoryStore.mostRecent?.encoding, .utf8)

        // Reopen: the encoding popup is restored to UTF-8.
        done.performClick(nil)
        controller.findPattern()
        (_, encoding, _, _) = try barControls(window)
        XCTAssertEqual(encoding.titleOfSelectedItem, "Text — UTF-8")
    }

    /// Picking an older search from the pattern combo's list loads its pattern
    /// and encoding into the fields — and must NOT run a search.
    func testFindRecentDropdownLoadsSearchWithoutSearching() throws {
        // Seed history: most recent first, so "DE AD" is the default and
        // "AA BB" is the older entry the dropdown will load.
        FindHistoryStore.record(pattern: "AA BB", encoding: .ascii)
        FindHistoryStore.record(pattern: "DE AD", encoding: .hex)

        let bytes: [UInt8] = [0xDE, 0xAD, 0x41, 0x41, 0x20, 0x42, 0x42]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, encoding, _, _) = try barControls(window)
        XCTAssertEqual(combo.stringValue, "DE AD", "most recent search must be the default")

        let index = combo.indexOfItem(withObjectValue: "AA BB — ASCII")
        XCTAssertGreaterThanOrEqual(index, 0, "the combo must list the AA BB search")
        XCTAssertTrue(pickFromHistory(combo, at: index, expecting: "AA BB"),
                      "the picked search must load into the field")

        // The field gets the bare pattern — never the "— encoding" suffix that
        // labels the dropdown item — and the popup carries the encoding.
        XCTAssertEqual(combo.stringValue, "AA BB", "only the pattern must reach the field")
        XCTAssertEqual(encoding.titleOfSelectedItem, "Text — ASCII")
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty,
                      "picking a recent search must load it, not run it")
    }

    /// The history is capped at 10 entries, most recent first.
    func testFindHistoryCapsAtTen() throws {
        for i in 0..<12 {
            FindHistoryStore.record(pattern: String(format: "%02X", i), encoding: .hex)
        }
        let recent = FindHistoryStore.recent
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.pattern, "0B", "most recent must be first")
        XCTAssertEqual(recent.last?.pattern, "02", "oldest kept is 02; 00 and 01 dropped")
        XCTAssertFalse(recent.contains { $0.pattern == "00" })
    }

    /// One entry per (pattern, encoding) pair: the same pattern under two
    /// encodings stays as two items; reusing an exact pair moves it to the
    /// front instead of duplicating it.
    func testFindHistoryDedupesByPair() throws {
        FindHistoryStore.record(pattern: "AA", encoding: .hex)
        FindHistoryStore.record(pattern: "AA", encoding: .utf8)
        var recent = FindHistoryStore.recent
        XCTAssertEqual(recent.count, 2, "different encodings of one pattern are separate items")
        XCTAssertEqual(recent.first?.pattern, "AA")
        XCTAssertEqual(recent.first?.encoding, .utf8, "newest pair must be first")

        // Reusing the same pair moves it to the front without duplicating.
        FindHistoryStore.record(pattern: "AA", encoding: .hex)
        recent = FindHistoryStore.recent
        XCTAssertEqual(recent.count, 2, "reusing a pair must not add a duplicate")
        XCTAssertEqual(recent.first?.encoding, .hex, "the reused pair moves to the top")

        // Re-recording a pair with a different case flag replaces the stored
        // flag rather than adding a second entry (latest search wins).
        FindHistoryStore.record(pattern: "AA", encoding: .utf8, caseSensitive: true)
        recent = FindHistoryStore.recent
        XCTAssertEqual(recent.count, 2, "the pair is still one entry")
        XCTAssertEqual(recent.first?.caseSensitive, true,
                       "re-recording the pair carries the new case flag")
    }

    /// The same pattern saved under two encodings appears as two labelled items
    /// in the dropdown; picking one restores its own encoding without running a
    /// search.
    func testFindHistorySamePatternDifferentEncodingsLoadIndependently() throws {
        FindHistoryStore.record(pattern: "ABCD", encoding: .ascii)
        FindHistoryStore.record(pattern: "ABCD", encoding: .hex)

        let bytes: [UInt8] = Array("ABCD".utf8)
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, encoding, _, _) = try barControls(window)

        // The most recent pair (hex) is offered by default.
        XCTAssertEqual(combo.stringValue, "ABCD")
        XCTAssertEqual(encoding.titleOfSelectedItem, "Hex bytes")

        // Both pairs are listed as distinct, encoding-labelled items.
        let asciiIndex = combo.indexOfItem(withObjectValue: "ABCD — ASCII")
        let hexIndex = combo.indexOfItem(withObjectValue: "ABCD — Hex")
        XCTAssertGreaterThanOrEqual(asciiIndex, 0, "the ASCII pair must be listed")
        XCTAssertGreaterThanOrEqual(hexIndex, 0, "the Hex pair must be listed")
        XCTAssertNotEqual(asciiIndex, hexIndex, "the two pairs are distinct items")

        // Pick the ASCII pair: field keeps the pattern, popup switches to ASCII.
        XCTAssertTrue(pickFromHistory(combo, at: asciiIndex, expecting: "ABCD"),
                      "the picked search must load into the field")
        XCTAssertEqual(combo.stringValue, "ABCD")
        XCTAssertEqual(encoding.titleOfSelectedItem, "Text — ASCII")
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty,
                      "picking a recent search must load it, not run it")
    }

    /// Reopening Find with a remembered pattern must not search on its own.
    func testReopenFindDoesNotAutoSearch() throws {
        // Two occurrences so a stray auto-search finds the next one and moves
        // the selection.
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xDE, 0xAD, 0xBE]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        // First search finds the first match.
        controller.findPattern()
        let (combo, _, done, _) = try barControls(window)
        combo.stringValue = "DE AD BE"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == 0 })

        // Reopen: the last pattern is pre-filled, but the bar must stay open and
        // the selection must not move until the user explicitly searches.
        done.performClick(nil)
        controller.findPattern()
        XCTAssertTrue(pumpUntil(2) { descendants(of: window.contentView!, FindBarView.self).first?.isHidden == false })
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))  // let any stray focus-time action fire
        XCTAssertFalse(try findBar(window).isHidden, "reopening Find must not auto-search and dismiss itself")
        XCTAssertEqual(controller.windowModel.pane1.hexSelection().start, 0,
                       "the selection must not move on reopen")
    }

    /// A match far below the viewport is scrolled to the vertical centre of the
    /// pane — not left at the bottom edge (Find Next) or top edge (Find Previous).
    func testFindCentersMatchInView() throws {
        // 300 rows; the match at row 250 is far below the initial viewport.
        var bytes = [UInt8](repeating: 0x11, count: 300 * 16)
        bytes[250 * 16] = 0xDE
        bytes[250 * 16 + 1] = 0xAD
        bytes[250 * 16 + 2] = 0xBE
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "DE AD BE"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == UInt64(250 * 16) })

        // The match is selected, and the pane scrolled so it sits mid-view.
        let matchStart = controller.windowModel.pane1.hexSelection().start
        XCTAssertEqual(matchStart, UInt64(250 * 16))
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let hexView = try XCTUnwrap(paneView.scrollView.documentView as? HexView)
        let clip = paneView.scrollView.contentView
        let rowFrame = hexView.hexLayout.rowFrame(row: Int(matchStart / 16))
        let maxY = max(0, hexView.bounds.height - clip.bounds.height)
        let expected = min(max(0, rowFrame.midY - clip.bounds.height / 2), maxY)
        XCTAssertEqual(clip.bounds.origin.y, expected, accuracy: 1.0,
                       "the match row must be vertically centred in the pane")
    }

    // MARK: - Case sensitivity (§11)

    /// The Aa toggle is off by default (case-insensitive, like TextEdit) and is
    /// disabled for hex patterns, where it is meaningless.
    func testCaseToggleDefaultsOffAndDisabledForHex() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (_, encoding, _, caseToggle) = try barControls(window)
        XCTAssertEqual(encoding.titleOfSelectedItem, "Hex bytes")
        XCTAssertEqual(caseToggle.state, .off, "case-insensitive must be the default")
        XCTAssertFalse(caseToggle.isEnabled, "case sensitivity is meaningless for hex")

        // Switching to a text encoding enables the toggle.
        encoding.selectItem(at: SearchEncoding.allCases.firstIndex(of: .utf8)!)
        encoding.sendAction(encoding.action, to: encoding.target)
        XCTAssertTrue(caseToggle.isEnabled, "text encodings can be searched case-sensitively")
    }

    /// The toggle actually changes matching: "hi" finds "Hi" by default,
    /// finds only exact "hi" with the toggle on, and "hI" has no match then.
    func testCaseSensitiveToggleControlsMatching() throws {
        let bytes: [UInt8] = Array("Hi hi HI".utf8)  // "hi" at 0 and 3; "HI" at 6
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, encoding, _, caseToggle) = try barControls(window)
        encoding.selectItem(at: SearchEncoding.allCases.firstIndex(of: .utf8)!)
        encoding.sendAction(encoding.action, to: encoding.target)

        // Default (off): "hi" matches "Hi" at the very start.
        combo.stringValue = "hi"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == 0 },
                      "case-insensitive search must find the first hi-like match")

        // Toggle on: "hi" now matches only the exact lowercase one at 3.
        caseToggle.performClick(nil)
        XCTAssertTrue(caseToggle.state == .on)
        combo.stringValue = "hi"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == 3 },
                      "case-sensitive search must skip Hi")

        // Case-sensitive "hI" exists nowhere → No match found.
        combo.stringValue = "hI"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(2) { self.hasStatus("No match found.", in: window) },
                      "case-sensitive search must not match mixed case")
    }

    /// Hex patterns are always byte-exact: the Aa toggle's default "case
    /// insensitive" state must NOT fold hex bytes (0x45 = 'E'). "4545" (= EE)
    /// must match only the exact byte pair 45 45 — never "Ee" (45 65) or
    /// "eE" (65 45), which fold to "ee".
    func testHexSearchIsAlwaysByteExact() throws {
        // Bytes: "Ee" (45 65), "EE" (45 45) at offset 2, "eE" (65 45).
        let bytes: [UInt8] = [0x45, 0x65, 0x45, 0x45, 0x65, 0x45]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, encoding, _, caseToggle) = try barControls(window)
        XCTAssertEqual(encoding.titleOfSelectedItem, "Hex bytes")
        XCTAssertEqual(caseToggle.state, .off, "case-insensitive is the default for text — but hex must ignore it")

        combo.stringValue = "4545"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.hexSelection().start == 2 },
                      "hex search must match the exact bytes 45 45, not a folded Ee/eE")
    }

    /// The case-sensitive flag is stored with each history entry for text
    /// encodings, shown as a "(CS)" suffix in the dropdown, and restored into
    /// the form when the item is picked — while hex never shows it.
    func testFindHistoryStoresAndRestoresCaseSensitivity() throws {
        // Seed: an ASCII search recorded case-sensitively, plus a hex one
        // (always byte-exact — its forced flag must not display a suffix).
        FindHistoryStore.record(pattern: "ABCD", encoding: .ascii, caseSensitive: true)
        FindHistoryStore.record(pattern: "4545", encoding: .hex, caseSensitive: true)

        let bytes: [UInt8] = Array("ABCD".utf8)
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, encoding, _, caseToggle) = try barControls(window)

        // The dropdown labels the case-sensitive entry with "(CS)".
        let csIndex = combo.indexOfItem(withObjectValue: "ABCD — ASCII (CS)")
        XCTAssertGreaterThanOrEqual(csIndex, 0,
                                    "a case-sensitive search must show the (CS) suffix")
        XCTAssertGreaterThanOrEqual(combo.indexOfItem(withObjectValue: "4545 — Hex"), 0,
                                    "hex is always exact — no (CS) suffix")

        // Pick the case-sensitive entry: the form's toggle follows it.
        XCTAssertTrue(pickFromHistory(combo, at: csIndex, expecting: "ABCD"),
                      "the picked search must load into the field")
        XCTAssertEqual(combo.stringValue, "ABCD")
        XCTAssertEqual(encoding.titleOfSelectedItem, "Text — ASCII")
        XCTAssertEqual(caseToggle.state, .on,
                       "picking a case-sensitive entry restores the toggle")
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty,
                      "picking a recent search must load it, not run it")
    }

    /// The persisted toggle survives closing and reopening the bar.
    func testCaseTogglePersistsAcrossReopen() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        controller.findPattern()
        var (_, encoding, done, caseToggle) = try barControls(window)
        encoding.selectItem(at: SearchEncoding.allCases.firstIndex(of: .utf8)!)
        encoding.sendAction(encoding.action, to: encoding.target)
        caseToggle.performClick(nil)
        XCTAssertTrue(caseToggle.state == .on)

        done.performClick(nil)
        controller.findPattern()
        (_, encoding, _, caseToggle) = try barControls(window)
        XCTAssertEqual(caseToggle.state, .on, "the case toggle must persist across reopen")
    }

    // MARK: - Background operation (§14.4)

    /// An instant search must not flash the operation strip in the status bar:
    /// the reveal is debounced (~0.3 s), and the search finishing first cancels
    /// it.
    func testFastSearchDoesNotFlashOperationIndicator() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0x41, 0x42]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "DE AD BE"
        try clickFindNext(window)
        // start == 0 is trivially true pre-search, so wait for the full match.
        XCTAssertTrue(pumpUntil(3) { let s = controller.windowModel.pane1.hexSelection(); return s.start == 0 && s.end == 3 },
                      "the search must complete")

        // Let the debounce window elapse; the strip must stay hidden because the
        // operation already finished.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        XCTAssertTrue(paneView.operationView.isHidden,
                      "an instant search must not flash the operation indicator")
    }

    /// A running operation shows its strip (name + progress) after the debounce
    /// and the (×) button routes to the operation's cancel action.
    func testRunningOperationShowsIndicatorAndCancels() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)

        var cancelled = false
        let op = BackgroundOperation(name: "Indexing…") { cancelled = true }
        paneView.beginOperation(op)
        XCTAssertTrue(paneView.operationView.isHidden,
                      "the strip must wait for the debounce before appearing")

        XCTAssertTrue(pumpUntil(2) { !paneView.operationView.isHidden },
                      "the strip must appear after the debounce")
        XCTAssertEqual(paneView.operationView.nameLabel.stringValue, "Indexing…")

        // The (×) button asks the operation to cancel its owner's work.
        paneView.operationView.cancelButton.performClick(nil)
        XCTAssertTrue(cancelled, "the × button must route to the operation's cancel action")
    }

    // MARK: - Search All (§11)

    /// The results panel is collapsed by default — it only expands for a Search
    /// All.
    func testSearchResultsPanelCollapsedByDefault() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }
        let view = try resultsView(window)
        window.layoutIfNeeded()
        XCTAssertLessThan(view.frame.height, 1,
                          "the results panel must stay collapsed until a Search All runs")
    }

    /// The collapsed (hidden) panel stays collapsed across a window resize — it
    /// must not pop open to the default half-height distribution.
    func testSearchResultsPanelStaysCollapsedOnWindowResize() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)

        // Hide, then make the window bigger and smaller.
        let closeButton = try XCTUnwrap(descendants(of: view, NSButton.self).first {
            $0.accessibilityLabel() == "Close search results"
        })
        closeButton.performClick(nil)
        XCTAssertTrue(pumpUntil(2) { view.frame.height < 1 })

        for newHeight: CGFloat in [700, 500, 800] {
            window.setContentSize(NSSize(width: 800, height: newHeight))
            window.layoutIfNeeded()
            XCTAssertLessThan(view.frame.height, 1,
                              "the collapsed panel must survive a resize to \(newHeight)")
            XCTAssertEqual(paneView.scrollView.frame.height,
                           paneView.searchResultsSplit.bounds.height - paneView.searchResultsSplit.dividerThickness,
                           accuracy: 0.5,
                           "the dump must reclaim the whole pane at \(newHeight)")
        }
    }

    /// Search All lists every occurrence: the panel's header shows the match
    /// count and the table holds one row per match, in file order.
    func testSearchAllShowsEveryMatchInPanel() throws {
        // "DE AD" at offsets 0, 6, 12, 18.
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0x00, 0x00,
                              0x00, 0x00, 0xDE, 0xAD, 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)

        XCTAssertEqual(view.tableView.numberOfRows, 4,
                       "one row per occurrence")
        let header = try XCTUnwrap(descendants(of: view, NSTextField.self).first {
            $0.stringValue.hasPrefix("Search results")
        })
        XCTAssertEqual(header.stringValue, "Search results (4)")
    }

    /// Search All opens the results panel immediately — before any scanning — in
    /// its "searching" state, and the count/table settle once the scan finishes.
    /// Previously the panel only appeared after the whole scan completed.
    func testSearchAllShowsPanelImmediately() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0x00, 0x00,
                              0x00, 0x00, 0xDE, 0xAD, 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "DE AD"
        try findAllButton(window).performClick(nil)

        // Right after the click the panel is already shown and searching: both
        // `showSearchResults` and `setSearching(true)` run synchronously inside
        // the click handler, before the background scan has produced a result.
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        XCTAssertTrue(paneView.searchResultsSplit.resultsPanelVisible,
                      "the panel must be shown immediately on Search All")
        XCTAssertTrue(paneView.searchResultsView.isSearching,
                      "the scan must still be running right after the click")

        // It fills dynamically and settles once the scan completes.
        XCTAssertTrue(pumpUntil(5) { !paneView.searchResultsView.isSearching },
                      "the scan must eventually finish")
        XCTAssertEqual(paneView.searchResultsView.tableView.numberOfRows, 4,
                       "one row per match after the scan settles")
    }

    /// The panel's count and table update live as a search streams in: each
    /// `append` grows both, and the header's trailing "…" marks a still-running
    /// search, dropping once it settles.
    func testSearchResultsCountUpdatesLive() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let view = paneView.searchResultsView
        paneView.showSearchResults(matches: [])
        view.setSearching(true)

        XCTAssertEqual(view.tableView.numberOfRows, 0)
        XCTAssertTrue(view.isSearching)
        XCTAssertEqual(headerText(of: view), "Search results (0…)")

        view.append(matches: [0..<2])
        view.append(matches: [4..<6, 7..<9])
        XCTAssertEqual(view.tableView.numberOfRows, 3, "rows grow with each batch")
        XCTAssertEqual(headerText(of: view), "Search results (3…)")

        view.setSearching(false)
        XCTAssertEqual(headerText(of: view), "Search results (3)", "the ellipsis drops once settled")
    }

    /// The results panel's header text ("Search results (NNN…)").
    private func headerText(of view: SearchResultsView) -> String {
        descendants(of: view, NSTextField.self).first {
            $0.stringValue.hasPrefix("Search results")
        }?.stringValue ?? ""
    }

    /// A Search All that finds more than the match cap stops at the cap — 1000
    /// rows, no more — and the header says the search returned too many results
    /// instead of reporting the count as final.
    func testSearchAllCapsResultsAtMax() throws {
        // 1500 matching bytes: a one-byte pattern over 1500 zero bytes finds
        // 1500 occurrences, well past the 1000-match cap.
        let bytes = [UInt8](repeating: 0x00, count: 1500)
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("00", in: window)

        XCTAssertEqual(view.tableView.numberOfRows, 1000,
                       "the scan stops at the 1000-match cap")
        let header = try XCTUnwrap(descendants(of: view, NSTextField.self).first {
            $0.stringValue.hasPrefix("Search results")
        })
        XCTAssertEqual(header.stringValue, "Search results (1000) — too many results")
    }

    /// The found bytes are drawn bold in each row's hex and text excerpts —
    /// the emphasis that marks the match inside its context window.
    func testSearchAllBoldsTheMatchInExcerpts() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0x00, 0x00, 0x00]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        XCTAssertEqual(view.tableView.numberOfRows, 1)

        func boldRunCount(in columnID: String) throws -> Int {
            let column = try XCTUnwrap(view.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(columnID)))
            let columnIndex = view.tableView.column(withIdentifier: column.identifier)
            let cell = try XCTUnwrap(view.tableView.view(atColumn: columnIndex, row: 0,
                                                         makeIfNecessary: true) as? SearchResultCellView)
            let attr = cell.attributedText
            var count = 0
            attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
                if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) {
                    count += 1
                }
            }
            return count
        }

        XCTAssertGreaterThan(try boldRunCount(in: "hex"), 0,
                             "the matched bytes must be bold in the hex excerpt")
        XCTAssertGreaterThan(try boldRunCount(in: "text"), 0,
                             "the matched bytes must be bold in the text excerpt")
    }

    /// A Search Results value must never wrap onto a second line: the excerpt
    /// is handed to the cell whole, and the cell's single-line label truncates
    /// the tail with "…" against the column's current width. Pins the no-wrap
    /// guarantee — a wrapped label would grow taller than one line.
    func testSearchAllExcerptNeverWraps() throws {
        // One 2-byte match ("DE AD") at the start of a 200-byte file: the
        // excerpt window is the match ±8 bytes clamped to the file, so the hex
        // cell shows 10 bytes ("DE AD 00 00 …", ~29 glyphs) — far wider than
        // the narrowed 100pt column.
        let bytes: [UInt8] = [0xDE, 0xAD] + [UInt8](repeating: 0x00, count: 198)
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        XCTAssertEqual(view.tableView.numberOfRows, 1)

        // Narrow the hex column so the excerpt cannot fit on one line.
        let hexColumn = try XCTUnwrap(view.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("hex")))
        hexColumn.width = 100
        view.layoutSubtreeIfNeeded()

        let hexIndex = view.tableView.column(withIdentifier: hexColumn.identifier)
        let cell = try XCTUnwrap(view.tableView.view(atColumn: hexIndex, row: 0,
                                                     makeIfNecessary: true) as? SearchResultCellView)
        cell.layoutSubtreeIfNeeded()

        // One 13pt line is ≈17pt tall; a wrapped label would need ≥2 lines
        // (~34pt), spilling past the 20pt row into the next one.
        let label = try XCTUnwrap(descendants(of: cell, NSTextField.self).first)
        XCTAssertLessThanOrEqual(label.frame.height, 20,
                                 "a Search Results value must stay on one line, truncating with \"…\" instead of wrapping")
    }

    /// Clicking a result row positions the caret at that match and selects it —
    /// the same behaviour as a single Find result.
    func testSearchAllRowClickSelectsMatch() throws {
        // Matches at 0, 4, 8.
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0x00, 0xDE, 0xAD, 0x00, 0x00, 0xDE, 0xAD]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        XCTAssertEqual(view.tableView.numberOfRows, 3)

        // Selecting row 1 and firing the table's action mirrors a click: the
        // action handler (`rowClicked`) falls back to the selected row, reports
        // the match's range, and the pane selects it (§11). NSTableView's own
        // click-to-select needs a physically pressed button, so a synthetic
        // mouse event can't drive it — selection + action is the real path
        // behind the handler.
        let tableView = view.tableView
        tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        tableView.sendAction(tableView.action, to: tableView.target)

        XCTAssertEqual(controller.windowModel.pane1.hexSelection().start, 4)
        XCTAssertEqual(controller.windowModel.pane1.hexSelection().end, 6)
    }

    /// A Search All with no occurrences shows an empty panel with "(0)" — the
    /// panel always reports the count.
    func testSearchAllNoMatchesShowsZeroCount() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("FF FF FF", in: window)

        XCTAssertEqual(view.tableView.numberOfRows, 0)
        let header = try XCTUnwrap(descendants(of: view, NSTextField.self).first {
            $0.stringValue.hasPrefix("Search results")
        })
        XCTAssertEqual(header.stringValue, "Search results (0)")
    }

    /// The panel's × hides it again.
    func testSearchAllCloseButtonHidesPanel() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        XCTAssertGreaterThan(view.frame.height, 1, "Search All must show the results panel")

        let closeButton = try XCTUnwrap(descendants(of: view, NSButton.self).first {
            $0.accessibilityLabel() == "Close search results"
        })
        closeButton.performClick(nil)
        XCTAssertTrue(pumpUntil(2) { view.frame.height < 1 },
                      "the × must collapse the results panel to zero height")
    }

    /// Closing the panel mid-search stops the scan and forgets the results: a
    /// scan left running would keep streaming matches into the cleared panel,
    /// so the table must stay empty after the close.
    func testSearchAllCloseStopsTheSearch() throws {
        // A match every 64 KiB across a 32 MiB file: the scan streams matches
        // for a while, so it is certainly still running when we close the panel
        // a moment later.
        var bytes = [UInt8](repeating: 0x00, count: 1 << 25)
        var offset = 0
        while offset + 2 < bytes.count {
            bytes[offset] = 0xDE
            bytes[offset + 1] = 0xAD
            offset += 64 << 10
        }
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "DE AD"
        try findAllButton(window).performClick(nil)

        // Right after the click the scan is still running (no runloop pump has
        // let the main-actor consumer settle it), so the × below closes it live.
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let view = paneView.searchResultsView
        XCTAssertTrue(view.isSearching, "the scan must still be running right after the click")

        let closeButton = try XCTUnwrap(descendants(of: view, NSButton.self).first {
            $0.accessibilityLabel() == "Close search results"
        })
        closeButton.performClick(nil)

        XCTAssertTrue(pumpUntil(3) { view.frame.height < 1 }, "closing hides the panel")
        XCTAssertTrue(pumpUntil(3) { !view.isSearching }, "closing stops the search")
        // Give a still-running scan time to keep streaming; the panel must stay
        // empty — matches streamed after the close would refill the rows.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(view.tableView.numberOfRows, 0,
                       "closing the panel stops the search and forgets the results")
    }

    /// The results panel is a native NSSplitView pane: shown after Search All
    /// as an expanded pane, collapsed when hidden (the ×) so the dump reclaims
    /// the full height.
    func testSearchResultsPanelShowsAndCollapses() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD, 0x00, 0x00, 0x00, 0x00])
        defer {
            cleanup(controller, url)
            UserDefaults.standard.removeObject(forKey: FilePaneView.searchResultsHeightDefaultsKey)
        }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let split = paneView.searchResultsSplit

        window.layoutIfNeeded()
        XCTAssertFalse(split.isSubviewCollapsed(view),
                       "the panel must be an expanded pane while results are shown")
        XCTAssertEqual(view.frame.height, expectedPanelHeight(SearchResultsView.panelHeight, split: split),
                       accuracy: 0.5, "the panel opens at its default height")

        let closeButton = try XCTUnwrap(descendants(of: view, NSButton.self).first {
            $0.accessibilityLabel() == "Close search results"
        })
        closeButton.performClick(nil)
        XCTAssertTrue(pumpUntil(2) { view.frame.height < 1 },
                      "hiding the panel must collapse it to zero height")
        window.layoutIfNeeded()
        // The divider is pinned to the very bottom, so the dump fills the pane
        // minus the divider's own thickness.
        XCTAssertEqual(paneView.scrollView.frame.height,
                       split.bounds.height - split.dividerThickness, accuracy: 0.5,
                       "the dump must reclaim the panel's height")
    }

    /// Setting the split view's panel height moves the divider so the panel
    /// takes exactly that much — the mechanism a native drag drives.
    func testSearchResultsPanelResizesToRequestedHeight() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD, 0x00, 0x00, 0x00, 0x00])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let split = paneView.searchResultsSplit

        split.setPanelHeight(120)
        window.layoutIfNeeded()
        XCTAssertEqual(view.frame.height, expectedPanelHeight(120, split: split), accuracy: 0.5,
                       "the panel height must take effect")
    }

    /// The user's chosen height is restored on the next Search All.
    func testSearchResultsPanelRestoresPersistedHeight() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD, 0x00, 0x00, 0x00, 0x00])
        defer {
            cleanup(controller, url)
            UserDefaults.standard.removeObject(forKey: FilePaneView.searchResultsHeightDefaultsKey)
        }
        UserDefaults.standard.set(120.0, forKey: FilePaneView.searchResultsHeightDefaultsKey)

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        window.layoutIfNeeded()
        XCTAssertEqual(view.frame.height, expectedPanelHeight(120, split: paneView.searchResultsSplit),
                       accuracy: 0.5, "Search All must restore the persisted panel height")
    }

    /// The native divider clamps: the panel can't shrink below its minimum nor
    /// grow past the point that would squeeze the hex dump away. The clamp is
    /// enforced by the split delegate when `setPosition` (or a drag) targets an
    /// out-of-range divider — `setPanelHeight` asks for the raw height and the
    /// split clamps it.
    func testSearchResultsPanelDividerClamps() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let split = paneView.searchResultsSplit
        window.layoutIfNeeded()

        // Asking for less than the panel's minimum clamps up to the minimum.
        split.setPanelHeight(10)
        window.layoutIfNeeded()
        XCTAssertEqual(view.frame.height, FilePaneView.minSearchResultsHeight, accuracy: 0.5,
                       "the divider must keep the results panel at its minimum")

        // Asking for more than the pane's room clamps down so the hex dump
        // keeps its minimum.
        split.setPanelHeight(10_000)
        window.layoutIfNeeded()
        XCTAssertEqual(paneView.scrollView.frame.height, FilePaneView.minHexHeightInPane, accuracy: 0.5,
                       "the divider must keep the hex dump at its minimum")
    }

    /// The height a requested panel height resolves to after the split view
    /// clamps it to the pane's room, so assertions hold at any pane size.
    private func expectedPanelHeight(_ stored: CGFloat, split: NSSplitView) -> CGFloat {
        min(max(stored, FilePaneView.minSearchResultsHeight),
            max(FilePaneView.minSearchResultsHeight,
                split.bounds.height - FilePaneView.minHexHeightInPane - split.dividerThickness))
    }

    /// A search that must scan the whole file (2 GiB of zeros, pattern never
    /// matches) must keep the main thread responsive and show the Searching…
    /// strip with live progress — the same behaviour as indexing. This guards
    /// against the search regressing into a synchronous scan that freezes the
    /// app (§14.4).
    func testLongSearchKeepsMainThreadResponsiveAndShowsProgress() throws {
        // 2 GiB of 0x00; "FF FF" never occurs, so the scan covers the whole file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("find-long-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let page = Data(repeating: 0x00, count: 1024 * 1024)
        for _ in 0..<2048 { try handle.write(contentsOf: page) }
        try handle.close()

        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        defer {
            controller.windowModel.pane1.close()
            try? FileManager.default.removeItem(at: url)
        }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "FF FF"
        try clickFindNext(window)

        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)

        // The strip must appear while the scan runs (long enough to clear the
        // 0.3 s debounce) and the main thread must stay responsive: a main-queue
        // block scheduled now fires promptly, not only once the search finishes.
        XCTAssertTrue(pumpUntil(5) { !paneView.operationView.isHidden },
                      "the Searching… strip must appear during a long search")
        XCTAssertEqual(paneView.operationView.nameLabel.stringValue, "Searching…")

        var mainQueueFired = false
        let scheduledAt = Date()
        DispatchQueue.main.async { mainQueueFired = true }
        XCTAssertTrue(pumpUntil(2) { mainQueueFired },
                      "the main thread must process work while the search scans")
        XCTAssertLessThan(Date().timeIntervalSince(scheduledAt), 1.5,
                          "a long search must not stall the main thread")

        // The scan completes: the no-match message shows and the strip hides.
        XCTAssertTrue(pumpUntil(30) { self.hasStatus("No match found.", in: window) },
                      "the full-file scan must complete")
        XCTAssertTrue(pumpUntil(5) { paneView.operationView.isHidden },
                      "the strip must hide once the search finishes")
    }

}
