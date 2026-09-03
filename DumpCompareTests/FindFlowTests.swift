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
        // And the results panel's height, which some twenty tests here write on
        // their way past a shown panel — that was landing in the user's own
        // preferences.
        FilePaneView.defaults = isolatedDefaults
        // The operation strip's reveal delay: shortened so the two tests that
        // wait it out cost 40 ms instead of a hand-tuned 500.
        FilePaneView.operationDebounce = 0.02
    }

    override func tearDown() {
        removeTempFiles()
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        FindHistoryStore.defaults = .standard
        FindBarView.defaults = .standard
        FilePaneView.defaults = .standard
        FilePaneView.operationDebounce = FilePaneView.defaultOperationDebounce
        isolatedDefaults = nil
        super.tearDown()
    }

    /// Every file this class writes, deleted in `tearDown`: the test host is
    /// sandboxed, so these land in the app's own container and stay there.
    private var tempFiles: [URL] = []

    private func removeTempFiles() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
    }

    /// A real controller in a real window with one file open (single-file mode).
    /// The test host resizes the window to the pane's fitting size (which, with
    /// the hex dump's content-sized scroll view, would leave the results-panel
    /// split with zero height); pin a real content height so the layout has
    /// room for the dump and the panel.
    private func makeController(_ bytes: [UInt8], height: CGFloat = 600)
        throws -> (MainViewController, NSWindow, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        // Assigning contentViewController resizes the window to the controller's
        // (empty-mode) view's fitting size; re-affirm a real size so the pane's
        // first layout happens at its final height, not a shrunken one.
        window.setContentSize(NSSize(width: 800, height: height))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.contentView?.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        window.layoutIfNeeded()
        return (controller, window, url)
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

    /// Presses the Find Next (`>`) segment.
    private func clickFindNext(_ window: NSWindow) throws {
        try findBar(window).pressFindForTests(.forward)
    }

    /// Presses the Find Previous (`<`) segment.
    private func clickFindPrevious(_ window: NSWindow) throws {
        try findBar(window).pressFindForTests(.backward)
    }

    /// Whether the find bar's count label says `text` — "3 of 128",
    /// "Not found", or nothing at all (§11).
    private func hasCount(_ text: String, in window: NSWindow) -> Bool {
        (try? findBar(window))?.countTextForTests == text
    }

    /// Whether any text field in the window shows `text` (e.g. a transient
    /// operation message in the pane's status bar).
    private func hasStatus(_ text: String, in window: NSWindow) -> Bool {
        descendants(of: window.contentView!, NSTextField.self).contains { $0.stringValue == text }
    }

    /// The Search All button in the find bar.
    private func findAllButton(_ window: NSWindow) throws -> NSButton {
        let bar = try findBar(window)
        return try XCTUnwrap(descendants(of: bar, NSButton.self).first { $0.accessibilityLabel() == "Search Results" },
                             "Search Results button")
    }

    /// The single file pane's Search All results panel.
    private func resultsView(_ window: NSWindow) throws -> SearchResultsViewController {
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        return paneView.searchResults
    }

    /// The results panel's header text.
    private func headerText(of view: SearchResultsViewController) -> String {
        (descendants(of: view.view, NSTextField.self)
            .first { $0.stringValue.hasPrefix("Search results") })?.stringValue ?? ""
    }

    /// Presses the results button for `pattern` and waits for the panel to open
    /// on the search's result.
    ///
    /// The panel no longer opens empty and fills: the scan that feeds the dump's
    /// highlighting is the one behind it, so the panel appears with its rows
    /// already in place (§11).
    @discardableResult
    private func runSearchAll(_ pattern: String, in window: NSWindow) throws -> SearchResultsViewController {
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = pattern
        try findAllButton(window).performClick(nil)
        let view = try resultsView(window)
        XCTAssertTrue(pumpUntil(5) { view.view.frame.height > 1 },
                      "the results button must open the panel")
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

    /// A pattern with no match reports it and keeps the find bar open. The
    /// message is not directional any more: the scan covers the whole file, so
    /// "nothing after the cursor" would understate what it found out
    /// (`Design/FIND_HIGHLIGHT_PLAN.md`; §11's directional rule went with the
    /// wrap).
    func testFindNoMatchShowsMessageAndKeepsBarOpen() throws {
        let bytes: [UInt8] = [0x41, 0x42, 0x43, 0x44]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "FF FF FF FF FF"
        try clickFindNext(window)

        XCTAssertTrue(pumpUntil(2) { self.hasCount("Not found", in: window) },
                      "the bar must say the pattern occurs nowhere")
        XCTAssertFalse(try findBar(window).isHidden,
                       "the find bar must stay open when there is no match")
    }

    // MARK: - Navigation off the match set

    /// The scan that activates a search keeps its result, so the set is there
    /// afterwards and holds every occurrence — not the one match the press
    /// moved to.
    func testASearchKeepsEveryOccurrenceItFound() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA, 0x00, 0xAA]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)

        let pane = controller.windowModel.pane1
        XCTAssertTrue(pumpUntil(3) { pane.matchSet?.total == 3 },
                      "the whole file is scanned once, and the set is kept")
        XCTAssertEqual(pane.matchRanges(intersecting: 0..<5), [0..<1, 2..<3, 4..<5])
        XCTAssertEqual(pane.currentMatchIndex, 0, "the first match is the one the press landed on")
    }

    /// The second press is a step through the set, not another scan: it moves
    /// the selection in the same turn, with nothing to wait for.
    func testASecondPressStepsWithoutScanning() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA, 0x00, 0xAA]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { pane.currentMatchIndex == 0 },
                      "the scan lands on the first match")

        try clickFindNext(window)
        XCTAssertEqual(pane.hexSelection().start, 2,
                       "an index step lands immediately — no background scan to wait for")
        XCTAssertEqual(pane.currentMatchIndex, 1)
    }

    /// Find Next at the last match returns to the first: with the whole set in
    /// hand there is no reason to stop at the end, which is why §11's "no match
    /// after the cursor" rule is gone.
    func testFindNextWrapsAtTheLastMatch() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { pane.currentMatchIndex == 0 })
        try clickFindNext(window)
        XCTAssertEqual(pane.hexSelection().start, 2, "the second match")

        try clickFindNext(window)
        XCTAssertEqual(pane.hexSelection().start, 0, "past the last match, back to the first")
        XCTAssertEqual(pane.currentMatchIndex, 0)
        XCTAssertFalse(hasCount("Not found", in: window),
                       "a wrap is not a failure and says nothing")
    }

    func testFindPreviousWrapsAtTheFirstMatch() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { pane.currentMatchIndex == 0 })

        try clickFindPrevious(window)
        XCTAssertEqual(pane.hexSelection().start, 2, "before the first match is the last one")
        XCTAssertEqual(pane.currentMatchIndex, 1)
    }

    /// A single match wraps onto itself. The press must not read as a dead key:
    /// the match stays selected and the view is centred on it again.
    func testASingleMatchWrapsOntoItself() throws {
        let bytes: [UInt8] = [0x00, 0xAA, 0x00]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { pane.currentMatchIndex == 0 })

        try clickFindNext(window)
        XCTAssertEqual(pane.hexSelection().start, 1, "the only match stays selected")
        XCTAssertEqual(pane.hexSelection().end, 2)
        XCTAssertEqual(pane.currentMatchIndex, 0)
        XCTAssertFalse(hasCount("Not found", in: window))
    }

    // MARK: - The count in the bar (§11)

    /// The bar counts what the scan found and says where in it the user is,
    /// and the number follows every step.
    func testTheBarCountsAndFollowsTheSteps() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA, 0x00, 0xAA]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        controller.findPattern()
        let bar = try findBar(window)
        XCTAssertEqual(bar.countTextForTests, "", "before a search the bar stays quiet")

        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { bar.countTextForTests == "1 of 3" },
                      "the count and the position arrive with the set")

        try clickFindNext(window)
        XCTAssertEqual(bar.countTextForTests, "2 of 3")
        try clickFindPrevious(window)
        XCTAssertEqual(bar.countTextForTests, "1 of 3")
        // And around the wrap.
        try clickFindPrevious(window)
        XCTAssertEqual(bar.countTextForTests, "3 of 3")
        XCTAssertNil(bar.countWarningForTests, "three matches is nothing to warn about")
    }

    /// A pattern that occurs nowhere kills the stepper and the results button:
    /// there is nothing to step through and nothing to list.
    func testNotFoundDisablesTheStepperUntilThePatternChanges() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43, 0x44])
        defer { cleanup(controller, url) }
        controller.findPattern()
        let bar = try findBar(window)
        let (combo, _, _, _) = try barControls(window)
        XCTAssertTrue(bar.navControlEnabledForTests,
                      "before a search the stepper is how a search is started")

        combo.stringValue = "FF FF"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { bar.countTextForTests == "Not found" })
        XCTAssertFalse(bar.navControlEnabledForTests, "nothing to step through")
        XCTAssertFalse(bar.findAllEnabledForTests, "nothing to list")

        // Editing the pattern describes a different search, so the bar goes
        // quiet and the controls come back.
        combo.stringValue = "41"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: combo)
        XCTAssertEqual(bar.countTextForTests, "")
        XCTAssertTrue(bar.navControlEnabledForTests)
    }

    /// Typing a new pattern also ends the highlighting the old one earned:
    /// nothing on screen may describe a pattern that is not in the field. The
    /// set itself stays — see `testTypingANewPatternStopsTheGreysAndLeavesThePanel`.
    func testEditingThePatternEndsTheSession() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { pane.matchSet != nil })

        combo.stringValue = "AA 00"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: combo)
        XCTAssertFalse(pane.highlightsMatches, "the greys belonged to the pattern that was there")
        XCTAssertNil(pane.highlightedMatchSet, "so nothing draws them")
    }

    /// The count's width is fixed by a template, so a four-figure count does
    /// not shove the stepper sideways as the user walks the matches.
    func testTheCountDoesNotMoveTheStepper() throws {
        let (controller, window, url) = try makeController([0x41, 0x42])
        defer { cleanup(controller, url) }
        controller.findPattern()
        let bar = try findBar(window)
        _ = try barControls(window)

        bar.show(count: FindCount(total: 9, ordinal: 1, isListable: true, isHighlightable: true))
        window.layoutIfNeeded()
        let narrow = bar.navControlFrameForTests.minX

        bar.show(count: FindCount(total: 4096, ordinal: 128, isListable: false, isHighlightable: true))
        window.layoutIfNeeded()
        XCTAssertEqual(bar.navControlFrameForTests.minX, narrow, accuracy: 0.5,
                       "the stepper stays put between 1 of 9 and 128 of 4,096")
    }

    /// The count is a region of the bar that comes and goes with the search.
    /// An empty slot held open by its own template reads as a control that
    /// failed to draw, so with no search the label leaves the layout and the
    /// stepper closes up against the pattern field (§11).
    func testTheCountAreaAppearsWithTheSearchAndCollapsesWithout() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x41])
        defer { cleanup(controller, url) }
        controller.findPattern()
        let bar = try findBar(window)
        let (combo, _, _, _) = try barControls(window)

        window.layoutIfNeeded()
        XCTAssertFalse(bar.countShownForTests, "a bar just opened has nothing to count")
        let stepper = bar.navControlFrameForTests.minX
        let roomyField = bar.patternFieldWidthForTests

        combo.stringValue = "41"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { bar.countTextForTests == "1 of 2" })
        window.layoutIfNeeded()
        XCTAssertTrue(bar.countShownForTests, "a result claims its place")
        // The place is real, and it comes out of the pattern field — the only
        // control that gives width up. The stepper does not budge either way:
        // its position is what §11 pins against a climbing count.
        XCTAssertLessThan(bar.patternFieldWidthForTests, roomyField - 60,
                          "the count took its slot out of the field")
        XCTAssertEqual(bar.navControlFrameForTests.minX, stepper, accuracy: 0.5,
                       "and the stepper stayed where it was")

        // An edit voids the set, and the count goes with it rather than
        // leaving its slot behind.
        let pane = controller.windowModel.pane1
        pane.moveCaret(to: 1)
        try pane.pasteWrite([0xFF])
        window.layoutIfNeeded()
        XCTAssertEqual(bar.countTextForTests, "")
        XCTAssertFalse(bar.countShownForTests, "an invalidated search leaves no gap")
        XCTAssertEqual(bar.patternFieldWidthForTests, roomyField, accuracy: 0.5,
                       "the field has the width back")
    }

    /// Past the listing limit the bar carries the reason as a glyph beside the
    /// count — the count is what proves the matches exist, so the explanation
    /// belongs next to it rather than in a message that fades.
    func testTheBarWarnsWhenThereAreTooManyToList() throws {
        let (controller, window, url) = try makeController([0x41, 0x42])
        defer { cleanup(controller, url) }
        controller.findPattern()
        let bar = try findBar(window)
        _ = try barControls(window)

        bar.show(count: FindCount(total: 4812, ordinal: 3, isListable: false, isHighlightable: true))
        // Grouped in the reader's own region format, like every other number
        // macOS shows, so the expectation is built the same way.
        XCTAssertEqual(bar.countTextForTests, "3 of \(grouped(4812))")
        XCTAssertEqual(bar.countWarningForTests, "Too many matches to list. Refine the pattern.")

        bar.show(count: FindCount(total: 2_481_903, ordinal: nil,
                                  isListable: false, isHighlightable: false))
        XCTAssertEqual(bar.countTextForTests, grouped(2_481_903))
        XCTAssertEqual(bar.countWarningForTests,
                       "Too many matches to highlight — navigation and the map still cover all of them.")
    }

    /// The count is uncapped: `defaultMaxResults` limits what the results panel
    /// *lists*, never what the scan counts, because the count is what tells the
    /// user the pattern is too generic.
    func testTheSetCountsPastTheResultsLimit() throws {
        let count = SearchEngine.defaultMaxResults + 200
        let (controller, window, url) = try makeController([UInt8](repeating: 0xAA, count: count))
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)

        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.matchSet?.total == count },
                      "every occurrence is counted, however many there are")
    }

    /// An edit moves the bytes the matches were found in, so the session ends
    /// rather than showing offsets that are now a guess.
    func testAnEditEndsTheSession() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { pane.matchSet != nil })

        pane.moveCaret(to: 1)
        pane.typeHexNibble(0xA)
        pane.typeHexNibble(0xA)
        XCTAssertNil(pane.matchSet, "the offsets are stale, so the greys go")
        XCTAssertNil(pane.currentMatchIndex)
    }

    /// The session ends with the bar — nothing left on screen claims a search
    /// is active. What ends is the *showing*; the set stays, which is what the
    /// results panel goes on listing (§11).
    func testClosingTheBarEndsTheSession() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { pane.matchSet != nil })

        let (_, _, done, _) = try barControls(window)
        done.performClick(nil)
        XCTAssertNil(pane.highlightedMatchSet)
        XCTAssertNil(pane.currentMatchIndex)

        // And Escape, which is the other way out of the bar.
        controller.findPattern()
        let (reopened, _, _, _) = try barControls(window)
        reopened.stringValue = "AA"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { pane.matchSet != nil })
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                   timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, characters: "\u{1B}",
                                   charactersIgnoringModifiers: "\u{1B}",
                                   isARepeat: false, keyCode: 53)!
        _ = window.performKeyEquivalent(with: esc)
        XCTAssertTrue(pumpUntil(2) { !pane.highlightsMatches },
                      "Escape ends the session too")
    }

    /// Including while a results panel is open: closing the bar means the search
    /// is over, and greys left on the dump would say otherwise. The panel keeps
    /// its rows — they were asked for, and their offsets are still true.
    func testClosingTheBarEndsTheSessionEvenBehindAResultsPanel() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "AA"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { pane.matchSet != nil })
        let panel = try runSearchAll("AA", in: window)
        XCTAssertEqual(panel.tableView.numberOfRows, 2)

        let (_, _, done, _) = try barControls(window)
        done.performClick(nil)
        XCTAssertNil(pane.highlightedMatchSet, "the highlighting goes with the bar")
        XCTAssertEqual(panel.tableView.numberOfRows, 2,
                       "the panel keeps the rows it was asked for")
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
        XCTAssertEqual(encoding.titleOfSelectedItem, "UTF-8")
    }

    /// The encoding popup names the encodings and nothing else. A "Text — "
    /// prefix on four of the five items spent the bar's width restating what
    /// `UTF-8` already says to anyone reading a dump; `Hex bytes` keeps its
    /// noun, being the one item that is not a text encoding.
    func testTheEncodingPopupNamesEncodingsWithoutAPrefix() throws {
        let (controller, window, url) = try makeController([0x41])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (_, encoding, _, _) = try barControls(window)

        XCTAssertEqual(encoding.itemTitles, ["Hex bytes", "ASCII", "UTF-8", "UTF-16 LE", "UTF-16 BE"])
        XCTAssertEqual(encoding.itemTitles.count, SearchEncoding.allCases.count,
                       "one item per encoding, in the enum's order")
    }

    /// Picking an older search from the pattern combo's list loads its pattern
    /// and its own encoding into the fields — and must NOT run a search. The
    /// same pattern saved under two encodings is two distinct labelled items, so
    /// picking one of them switches the encoding with the pattern unchanged.
    func testFindRecentDropdownLoadsAPatternAndItsEncodingWithoutSearching() throws {
        // Seed history: most recent last, so "DE AD" is the default and the
        // others are the older entries the dropdown will load.
        FindHistoryStore.record(pattern: "AA BB", encoding: .ascii)
        FindHistoryStore.record(pattern: "ABCD", encoding: .ascii)
        FindHistoryStore.record(pattern: "ABCD", encoding: .hex)
        FindHistoryStore.record(pattern: "DE AD", encoding: .hex)

        // Every seeded search has a match in the file, so a stray search would
        // leave a selection behind for the assertions below to catch.
        let bytes: [UInt8] = [0xDE, 0xAD,                          // "DE AD" hex
                              0x41, 0x41, 0x20, 0x42, 0x42,        // "AA BB" ASCII
                              0x41, 0x42, 0x43, 0x44,              // "ABCD" ASCII
                              0xAB, 0xCD]                          // "ABCD" hex
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, encoding, _, _) = try barControls(window)
        XCTAssertEqual(combo.stringValue, "DE AD", "most recent search must be the default")
        XCTAssertEqual(encoding.titleOfSelectedItem, "Hex bytes", "with its own encoding")

        let index = combo.indexOfItem(withObjectValue: "AA BB — ASCII")
        XCTAssertGreaterThanOrEqual(index, 0, "the combo must list the AA BB search")
        XCTAssertTrue(pickFromHistory(combo, at: index, expecting: "AA BB"),
                      "the picked search must load into the field")

        // The field gets the bare pattern — never the "— encoding" suffix that
        // labels the dropdown item — and the popup carries the encoding.
        XCTAssertEqual(combo.stringValue, "AA BB", "only the pattern must reach the field")
        XCTAssertEqual(encoding.titleOfSelectedItem, "ASCII")
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty,
                      "picking a recent search must load it, not run it")

        // One pattern under two encodings: two distinct items, each restoring
        // its own encoding.
        let asciiIndex = combo.indexOfItem(withObjectValue: "ABCD — ASCII")
        let hexIndex = combo.indexOfItem(withObjectValue: "ABCD — Hex")
        XCTAssertGreaterThanOrEqual(asciiIndex, 0, "the ASCII pair must be listed")
        XCTAssertGreaterThanOrEqual(hexIndex, 0, "the Hex pair must be listed")
        XCTAssertNotEqual(asciiIndex, hexIndex, "the two pairs are distinct items")

        XCTAssertTrue(pickFromHistory(combo, at: hexIndex, expecting: "ABCD"),
                      "the Hex pair must load into the field")
        XCTAssertEqual(encoding.titleOfSelectedItem, "Hex bytes")
        XCTAssertTrue(pickFromHistory(combo, at: asciiIndex, expecting: "ABCD"),
                      "and the ASCII pair after it")
        XCTAssertEqual(combo.stringValue, "ABCD", "the pattern is unchanged between the two")
        XCTAssertEqual(encoding.titleOfSelectedItem, "ASCII",
                       "but the encoding follows the pair that was picked")
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty,
                      "and still nothing was searched")
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))  // let any stray focus-time action fire
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

    /// The toggle actually changes matching: "hi" finds "Hi" by default,
    /// finds only exact "hi" with the toggle on, and "hI" has no match then.
    /// A match already on screen moves the highlight, not the page: the same
    /// rule the caret follows (§10.4). Walking a cluster of matches used to
    /// re-centre the view on every press.
    func testAMatchAlreadyOnScreenDoesNotScrollThePane() throws {
        // 300 rows, with two matches four rows apart in the middle of the file,
        // well away from the ends where a centred reveal would be clamped: the
        // first press centres row 40, and row 44 is then plainly on screen.
        var bytes = [UInt8](repeating: 0x11, count: 300 * 16)
        bytes.replaceSubrange(40 * 16..<(40 * 16 + 3), with: [0xDE, 0xAD, 0xBE])
        bytes.replaceSubrange(44 * 16..<(44 * 16 + 3), with: [0xDE, 0xAD, 0xBE])
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "DE AD BE"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { pane.currentMatchIndex == 0 })

        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let clip = paneView.scrollView.contentView
        let before = clip.bounds.origin.y

        XCTAssertGreaterThan(before, 1, "the first match was off screen, so it was centred")

        try clickFindNext(window)
        XCTAssertEqual(pane.hexSelection().start, UInt64(44 * 16), "the highlight moved")
        XCTAssertEqual(clip.bounds.origin.y, before, accuracy: 0.5,
                       "and the page did not")
    }

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
        XCTAssertTrue(pumpUntil(2) { self.hasCount("Not found", in: window) },
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
        XCTAssertEqual(encoding.titleOfSelectedItem, "ASCII")
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

        // Let the debounce window elapse — several times over, at the 20 ms this
        // suite sets it to — and the strip must still be hidden, because the
        // operation had already finished when it opened.
        RunLoop.main.run(until: Date().addingTimeInterval(FilePaneView.operationDebounce * 5))
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
        XCTAssertLessThan(view.view.frame.height, 1,
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
        let closeButton = try XCTUnwrap(descendants(of: view.view, NSButton.self).first {
            $0.accessibilityLabel() == "Close search results"
        })
        closeButton.performClick(nil)
        XCTAssertTrue(pumpUntil(2) { view.view.frame.height < 1 })

        for newHeight: CGFloat in [700, 500, 800] {
            window.setContentSize(NSSize(width: 800, height: newHeight))
            window.layoutIfNeeded()
            XCTAssertLessThan(view.view.frame.height, 1,
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
        let header = try XCTUnwrap(descendants(of: view.view, NSTextField.self).first {
            $0.stringValue.hasPrefix("Search results")
        })
        XCTAssertEqual(header.stringValue, "Search results (4)")
    }

    /// Search All opens the results panel immediately — before any scanning — in
    /// its "searching" state, and the count/table settle once the scan finishes.
    /// Previously the panel only appeared after the whole scan completed.
    func testTheResultsButtonOpensThePanelOnTheSearchsResult() throws {
        // Six matches, one per chunk, so the scan really does have to cover the
        // file before the panel can be right.
        MainViewController.searchChunkSize = 8
        addTeardownBlock { MainViewController.searchChunkSize = SearchEngine.defaultChunkSize }
        var bytes = [UInt8](repeating: 0x00, count: 48)
        for chunk in 0..<6 { bytes[chunk * 8] = 0xDE; bytes[chunk * 8 + 1] = 0xAD }
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let bar = try findBar(window)
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        XCTAssertTrue(paneView.searchResultsPanelVisible)
        XCTAssertEqual(view.tableView.numberOfRows, 6, "one row per match, all of them")
        XCTAssertTrue(bar.resultsShownForTests, "and the button reads as on")

        // It is a toggle now, not a search: pressing it again puts the panel away.
        try findAllButton(window).performClick(nil)
        XCTAssertFalse(paneView.searchResultsPanelVisible, "a second press hides it")
        XCTAssertFalse(bar.resultsShownForTests)
    }

    /// The panel lists what the set holds, and says so in its header — the same
    /// count the Find bar shows.
    func testThePanelListsTheSetsMatches() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD, 0x00, 0xDE, 0xAD])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        XCTAssertEqual(view.tableView.numberOfRows, 2)
        XCTAssertEqual(headerText(of: view), "Search results (2)")
        XCTAssertEqual(view.content, .matches(total: 2))
        XCTAssertEqual(view.listedMatchesForTesting, [0..<2, 3..<5],
                       "and the rows are the set's own matches, read out of it")
    }

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
        view.view.layoutSubtreeIfNeeded()

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
    func testTheResultsButtonOpensNothingWhenThereAreNoMatches() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "FF FF FF"
        try findAllButton(window).performClick(nil)
        XCTAssertTrue(pumpUntil(3) { self.hasCount("Not found", in: window) })

        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        XCTAssertFalse(paneView.searchResultsPanelVisible,
                       "an empty result opens no panel — the bar already says Not found")
        XCTAssertFalse(try findBar(window).resultsShownForTests)
    }

    /// Closing the panel forgets its rows, and leaves the search itself alone:
    /// the pattern in the field is unchanged, so the greys and the count stay.
    func testClosingThePanelForgetsItsResults() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD, 0x00, 0xDE, 0xAD])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        XCTAssertEqual(view.tableView.numberOfRows, 2)

        let closeButton = try XCTUnwrap(descendants(of: view.view, NSButton.self).first {
            $0.accessibilityLabel() == "Close search results"
        })
        closeButton.performClick(nil)

        XCTAssertTrue(pumpUntil(3) { view.view.frame.height < 1 }, "closing hides the panel")
        XCTAssertEqual(view.tableView.numberOfRows, 0, "and forgets the rows")
        XCTAssertFalse(try findBar(window).resultsShownForTests,
                       "the bar's toggle follows the panel")
        // The search itself is untouched: the greys and the count stay, because
        // the pattern is still what is in the field (§11).
        XCTAssertEqual(controller.windowModel.pane1.matchSet?.total, 2)
    }

    /// The results panel is a pane of the pane's split view: shown after Search
    /// All as an expanded pane, collapsed when hidden (the ×) so the dump
    /// reclaims the full height.
    func testSearchResultsPanelShowsAndCollapses() throws {
        // A tall window on purpose: with nothing persisted the panel opens at
        // its built-in default, and the pane has to be roomy enough that the
        // "never taller than the pane allows" clamp cannot be what decides the
        // height instead.
        let (controller, window, url) = try makeController([0xDE, 0xAD, 0x00, 0x00, 0x00, 0x00],
                                                           height: 1000)
        defer {
            cleanup(controller, url)
            FilePaneView.defaults.removeObject(forKey: FilePaneView.searchResultsHeightDefaultsKey)
        }
        FilePaneView.defaults.removeObject(forKey: FilePaneView.searchResultsHeightDefaultsKey)

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let split = paneView.searchResultsSplit

        window.layoutIfNeeded()
        XCTAssertGreaterThan(view.view.frame.height, 0,
                             "the panel must be an expanded pane while results are shown")
        XCTAssertGreaterThan(split.bounds.height, 600,
                             "premise: the pane is several times the default height, so the clamp is idle")
        // The built-in default, written out. Reading `SearchResultsViewController.panelHeight`
        // back through the clamp the pane applies to it made this assertion true
        // for any default at all.
        XCTAssertEqual(view.view.frame.height, 160, accuracy: 0.5,
                       "the panel opens at its 160 pt default height (§11)")

        let closeButton = try XCTUnwrap(descendants(of: view.view, NSButton.self).first {
            $0.accessibilityLabel() == "Close search results"
        })
        closeButton.performClick(nil)
        XCTAssertTrue(pumpUntil(2) { view.view.frame.height < 1 },
                      "hiding the panel must collapse it to zero height")
        window.layoutIfNeeded()
        // The divider is pinned to the very bottom, so the dump fills the pane
        // minus the divider's own thickness.
        XCTAssertEqual(paneView.scrollView.frame.height,
                       split.bounds.height - split.dividerThickness, accuracy: 0.5,
                       "the dump must reclaim the panel's height")
    }

    /// The user's chosen height is restored on the next Search All, verbatim.
    ///
    /// The window is tall enough that the "never taller than the pane allows"
    /// clamp cannot interfere — asserted as a premise, because at a small window
    /// size the old expectation (the clamp, re-typed) degenerated into
    /// `room == room` and the persisted value stopped mattering.
    func testSearchResultsPanelRestoresPersistedHeight() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD, 0x00, 0x00, 0x00, 0x00],
                                                           height: 1000)
        defer {
            cleanup(controller, url)
            FilePaneView.defaults.removeObject(forKey: FilePaneView.searchResultsHeightDefaultsKey)
        }
        FilePaneView.defaults.set(120.0, forKey: FilePaneView.searchResultsHeightDefaultsKey)

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        window.layoutIfNeeded()
        XCTAssertGreaterThan(paneView.searchResultsSplit.bounds.height, 600,
                             "premise: the pane is several times the restored height, so the clamp is idle")
        XCTAssertEqual(view.view.frame.height, 120, accuracy: 0.5,
                       "Search All must restore the persisted 120 pt panel height")
    }

    /// A height persisted from a taller window or the other pane is clamped to
    /// the pane's room when the panel opens: Search All never shows the panel
    /// taller than the pane allows, however large the stored value is (§11).
    func testSearchResultsPanelClampsPersistedHeightOnShow() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD])
        defer {
            cleanup(controller, url)
            FilePaneView.defaults.removeObject(forKey: FilePaneView.searchResultsHeightDefaultsKey)
        }
        FilePaneView.defaults.set(10_000.0, forKey: FilePaneView.searchResultsHeightDefaultsKey)

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        window.layoutIfNeeded()

        // What the rule actually says, with no arithmetic copied out of
        // `applySearchResultsHeight`: the panel opens shorter than the pane — so
        // the dump keeps the larger share — and never below the panel's own
        // minimum. The exact fraction is an implementation detail (§11 does not
        // name one), and re-typing it made this test pass for any fraction.
        XCTAssertGreaterThanOrEqual(view.view.frame.height, FilePaneView.minSearchResultsHeight,
                                    "however stale the stored height, the panel is usable")
        XCTAssertLessThan(view.view.frame.height, paneView.scrollView.frame.height,
                          "and the dump keeps the greater part of the pane")
    }

    /// The one-third-of-the-dump clamp applies only to the first show of a
    /// session — the height restored from a previous launch. A height the user
    /// chose by dragging the divider in this session is applied as-is on later
    /// shows, even above the restored clamp (§11).
    func testSearchResultsPanelKeepsDraggedHeightInSession() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD])
        defer {
            cleanup(controller, url)
            FilePaneView.defaults.removeObject(forKey: FilePaneView.searchResultsHeightDefaultsKey)
        }
        FilePaneView.defaults.set(10_000.0, forKey: FilePaneView.searchResultsHeightDefaultsKey)

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        window.layoutIfNeeded()
        // The first show clamps the stale persisted height to the pane's room.
        let firstShowHeight = view.view.frame.height
        XCTAssertLessThan(firstShowHeight, paneView.scrollView.frame.height,
                          "the first show clamps the stale persisted height")

        // The user drags the divider taller than the restored clamp would
        // allow; the split persists that height as the user's choice.
        paneView.setSearchResultsPanelHeight(400)
        window.layoutIfNeeded()
        let draggedHeight = view.view.frame.height
        XCTAssertGreaterThan(draggedHeight, firstShowHeight,
                             "a drag must be able to exceed the restored clamp")

        // Close and reopen the panel: the height picked in this session wins.
        let closeButton = try XCTUnwrap(descendants(of: view.view, NSButton.self).first {
            $0.accessibilityLabel() == "Close search results"
        })
        closeButton.performClick(nil)
        XCTAssertTrue(pumpUntil(2) { view.view.frame.height < 1 })

        try runSearchAll("DE AD", in: window)
        window.layoutIfNeeded()
        XCTAssertEqual(view.view.frame.height, draggedHeight, accuracy: 0.5,
                       "a height chosen in this session must apply as-is on the next show")
    }

    /// The divider applies what it is asked for and clamps what it cannot: an
    /// in-range height takes effect verbatim, while the panel can't shrink
    /// below its minimum nor grow past the point that would squeeze the hex
    /// dump away. The clamp is the split's `clampDividerPosition` when a
    /// divider move (or a drag) targets an out-of-range divider —
    /// `setSearchResultsPanelHeight` asks for the raw height and the split
    /// clamps it.
    func testSearchResultsPanelDividerClamps() throws {
        let (controller, window, url) = try makeController([0xDE, 0xAD])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let split = paneView.searchResultsSplit
        window.layoutIfNeeded()

        // 120 pt is in range for this window, so it is applied as asked — the
        // mechanism a native drag drives. The premise is the pane's size rather
        // than a copy of the delegate's own min/max arithmetic, which made the
        // literal below pass for whatever the clamp happened to be.
        XCTAssertGreaterThan(split.bounds.height, 400,
                             "premise: the pane has far more than 120 pt to give away")
        paneView.setSearchResultsPanelHeight(120)
        window.layoutIfNeeded()
        XCTAssertEqual(view.view.frame.height, 120, accuracy: 0.5,
                       "an in-range panel height must take effect unchanged")

        // Asking for less than the panel's minimum clamps up to the minimum —
        // 80 pt, written out rather than read back from the constant the clamp
        // is made of (a minimum of 0 satisfied that).
        paneView.setSearchResultsPanelHeight(10)
        window.layoutIfNeeded()
        XCTAssertEqual(view.view.frame.height, 80, accuracy: 0.5,
                       "the divider must keep the results panel at its 80 pt minimum")

        // Asking for more than the pane's room clamps down so the hex dump
        // keeps its own 40 pt minimum.
        paneView.setSearchResultsPanelHeight(10_000)
        window.layoutIfNeeded()
        XCTAssertEqual(paneView.scrollView.frame.height, 40, accuracy: 0.5,
                       "the divider must keep the hex dump at its 40 pt minimum")
    }

    /// A search that must scan the whole file (2 GiB of zeros, pattern never
    /// matches) must keep the main thread responsive and show the Searching…
    /// strip with live progress — the same behaviour as indexing. This guards
    /// against the search regressing into a synchronous scan that freezes the
    /// app (§14.4).
    func testLongSearchKeepsMainThreadResponsiveAndShowsProgress() throws {
        // 8 MiB of 0x00 read 512 bytes at a time: "FF FF" never occurs, so the
        // scan covers the whole file, and 16 384 chunks make it last long enough
        // to watch. The fixture used to be 2 GiB — written to disk on every run —
        // to buy the same seconds that the chunk size buys here.
        MainViewController.searchChunkSize = 512
        addTeardownBlock { MainViewController.searchChunkSize = SearchEngine.defaultChunkSize }
        let url = try tempFile([UInt8](repeating: 0x00, count: 8 * 1024 * 1024))

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
        XCTAssertTrue(pumpUntil(30) { self.hasCount("Not found", in: window) },
                      "the full-file scan must complete")
        XCTAssertTrue(pumpUntil(5) { paneView.operationView.isHidden },
                      "the strip must hide once the search finishes")
    }


    // MARK: - Case folding is offered wherever text has case (§11)

    /// Text is text: the toggle is offered for ASCII, UTF-8 and both UTF-16s,
    /// each with the fold that fits (`CaseFolding`). Only hex is left out, and
    /// there the control leaves the bar rather than sitting greyed out saying
    /// "off" while the search matches exactly — the reading that made the toggle
    /// look as if it worked backwards. Where it is offered it starts off,
    /// case-insensitive like TextEdit.
    func testCaseToggleIsOfferedForEveryTextEncodingAndNotForHex() throws {
        XCTAssertTrue(FindBarView.supportsCaseFolding(.ascii))
        XCTAssertTrue(FindBarView.supportsCaseFolding(.utf8))
        XCTAssertTrue(FindBarView.supportsCaseFolding(.utf16LE))
        XCTAssertTrue(FindBarView.supportsCaseFolding(.utf16BE))
        XCTAssertFalse(FindBarView.supportsCaseFolding(.hex))

        let bytes: [UInt8] = [0x41, 0x42]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }
        controller.findPattern()
        let (_, encoding, _, caseToggle) = try barControls(window)
        XCTAssertEqual(caseToggle.state, .off, "case-insensitive must be the default")

        for (mode, expected) in [(SearchEncoding.utf8, true), (.utf16LE, true),
                                 (.utf16BE, true), (.hex, false), (.ascii, true)] {
            encoding.selectItem(at: SearchEncoding.allCases.firstIndex(of: mode)!)
            encoding.sendAction(encoding.action, to: encoding.target)
            XCTAssertEqual(!caseToggle.isHidden, expected,
                           "the toggle's presence for \(mode)")
        }
    }

    /// A case-insensitive UTF-16 search finds the other case — the whole point —
    /// and still keeps two different characters apart. The fold that made this
    /// impossible worked a byte at a time, so it folded the high byte of
    /// U+6100 (`00 61` LE) as if it were the letter `a` and matched U+4100.
    func testUTF16SearchFoldsLettersAndKeepsOtherCharactersApart() throws {
        // "Setup" in UTF-16LE, upper-case S, followed by U+4100.
        let text = try SearchEngine.parsePattern("Setup", encoding: .utf16LE).bytes
        let u4100 = try SearchEngine.parsePattern("\u{4100}", encoding: .utf16LE).bytes
        let (controller, window, url) = try makeController(text + u4100)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, encoding, _, caseToggle) = try barControls(window)
        encoding.selectItem(at: SearchEncoding.allCases.firstIndex(of: .utf16LE)!)
        encoding.sendAction(encoding.action, to: encoding.target)
        XCTAssertFalse(caseToggle.isHidden, "UTF-16 is text, so the toggle is there")
        XCTAssertEqual(caseToggle.state, .off, "and it starts case-insensitive")

        // Lower case finds the upper-case string.
        combo.stringValue = "setup"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) {
            controller.windowModel.pane1.hexSelection().start == 0
                && controller.windowModel.pane1.hexSelection().count == UInt64(text.count)
        }, "a case-insensitive UTF-16 search finds \"Setup\" for \"setup\"")

        // And a different character is still a different character.
        controller.windowModel.pane1.moveCaret(to: 0)
        combo.stringValue = "\u{6100}"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { self.hasCount("Not found", in: window) },
                      "U+6100 must not match U+4100")
    }

    /// Turning the toggle on makes a UTF-16 search exact again, so the two cases
    /// stop matching each other.
    func testUTF16SearchIsExactWhenTheToggleIsOn() throws {
        let text = try SearchEngine.parsePattern("Setup", encoding: .utf16LE).bytes
        let (controller, window, url) = try makeController(text)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let (combo, encoding, _, _) = try barControls(window)
        encoding.selectItem(at: SearchEncoding.allCases.firstIndex(of: .utf16LE)!)
        encoding.sendAction(encoding.action, to: encoding.target)
        try findBar(window).setCaseSensitiveForTests(true)

        combo.stringValue = "setup"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(3) { self.hasCount("Not found", in: window) },
                      "case-sensitive means the lower-case spelling is not there")
    }

    // MARK: - The listing limit (§11)

    /// Exactly the limit is a list: every match is a row, and the header counts
    /// them.
    func testExactlyTheListingLimitIsStillListed() throws {
        let limit = SearchEngine.defaultMaxResults
        let bytes = (0..<limit).flatMap { _ -> [UInt8] in [0x41, 0x42] }
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("41 42", in: window)
        XCTAssertEqual(view.tableView.numberOfRows, limit, "every match is listed")
        XCTAssertEqual(headerText(of: view), "Search results (\(grouped(limit)))")
    }

    /// One past the limit is not a list at all: the panel states the count and
    /// what to do about it, because four thousand rows look exactly like forty
    /// until you scroll to the end (§11).
    func testPastTheListingLimitThePanelSaysWhyInsteadOfListing() throws {
        let limit = SearchEngine.defaultMaxResults
        let bytes = (0..<(limit + 1)).flatMap { _ -> [UInt8] in [0x41, 0x42] }
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("41 42", in: window)
        XCTAssertEqual(view.content, .tooMany(total: limit + 1))
        XCTAssertEqual(view.tableView.numberOfRows, 0, "nothing is listed")
        XCTAssertEqual(headerText(of: view), "Search results (\(grouped(limit + 1)))",
                       "the count is exact — it is the diagnosis")
        let message = try XCTUnwrap(descendants(of: view.view, NSTextField.self)
            .first { $0.stringValue.contains("too many to list") })
        XCTAssertFalse(message.isHidden)
        XCTAssertTrue(message.stringValue.contains("Refine the pattern"))
    }

    /// A count in the reader's region format, as the panel prints it.
    private func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value))!
    }

    // MARK: - The results panel outlives the Find bar (§11)

    /// The results live in the pane's own panel, with its own ×, so dismissing
    /// the Find bar must leave them alone.
    func testClosingTheFindBarKeepsTheResultsPanel() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0xDE, 0xAD, 0x00]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        XCTAssertEqual(view.tableView.numberOfRows, 2)

        let (_, _, done, _) = try barControls(window)
        done.performClick(nil)
        // `findBar(_:)` only finds a *visible* bar, so look it up directly.
        let bar = try XCTUnwrap(descendants(of: window.contentView!, FindBarView.self).first)
        XCTAssertTrue(bar.isHidden, "the bar is dismissed")

        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        XCTAssertTrue(paneView.searchResultsPanelVisible,
                      "the results panel stays open")
        XCTAssertEqual(view.tableView.numberOfRows, 2, "with its rows intact")
    }

    /// One set, one list: activating a *different* search rewrites the panel's
    /// rows rather than leaving the previous search's on screen. The panel and
    /// the dump read the same set, so they cannot be showing two searches.
    func testANewSearchRewritesThePanelsRows() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0xDE, 0xAD, 0x11, 0x22, 0x11, 0x22, 0x11, 0x22]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        XCTAssertEqual(view.listedMatchesForTesting, [0..<2, 3..<5], "the premise")

        // A new pattern, searched from the bar while the panel stays open.
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "11 22"
        try clickFindNext(window)

        XCTAssertTrue(pumpUntil(3) { view.listedMatchesForTesting.count == 3 },
                      "the panel must follow the search that is now active")
        XCTAssertEqual(view.listedMatchesForTesting, [5..<7, 7..<9, 9..<11])
        XCTAssertEqual(headerText(of: view), "Search results (3)",
                       "header and rows are the same set")
        XCTAssertTrue(hasCount("1 of 3", in: window), "and so is the bar's count")
    }

    /// Dismissing the bar ends the *highlighting* and keeps the *set*: the
    /// search was run, its offsets are still true, and the panel goes on
    /// listing it until something invalidates it (§11).
    func testDoneEndsTheHighlightingAndKeepsTheSet() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0xDE, 0xAD, 0x00]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        try clickFindNext(window)
        let pane = controller.windowModel.pane1
        XCTAssertTrue(pumpUntil(3) { pane.highlightsMatches && pane.currentMatchIndex == 0 },
                      "the premise: a search is being shown")

        let (_, _, done, _) = try barControls(window)
        done.performClick(nil)

        XCTAssertFalse(pane.highlightsMatches, "the dump stops advertising the search")
        XCTAssertNil(pane.currentMatchIndex, "and the indicator goes with the greys")
        XCTAssertNil(pane.highlightedMatchSet, "so nothing draws it")
        XCTAssertNotNil(pane.matchSet, "but the set itself survives")
        XCTAssertEqual(view.listedMatchesForTesting, [0..<2, 3..<5], "and the panel still lists it")
    }

    /// Picking a row out of the panel turns the highlighting back on — the
    /// greys are what say where the *other* occurrences are, and a row picked
    /// from a list is the user pointing at one of them (§11).
    func testPickingARowTurnsTheHighlightingBackOn() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0xDE, 0xAD, 0x00]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let (_, _, done, _) = try barControls(window)
        done.performClick(nil)
        let pane = controller.windowModel.pane1
        XCTAssertFalse(pane.highlightsMatches, "the premise: no highlighting, panel still listing")

        clickResultRow(1, in: view)

        XCTAssertTrue(pane.highlightsMatches, "the greys are back")
        XCTAssertEqual(pane.currentMatchIndex, 1, "on the row that was picked")
        XCTAssertEqual(pane.currentMatchRange, 3..<5, "which is where the plate is")
        XCTAssertEqual(pane.hexSelection().start, 3, "and the match is selected")
    }

    /// The two channels the pane offers for a search, and which is which: the
    /// results panel listens to the set, and nothing else. A stepped indicator
    /// is an appearance change — it must not reach the table at all, because
    /// rebuilding the table is how a selection gets dropped.
    func testOnlyANewSetIsAnnouncedToTheList() {
        let pane = PaneViewModel()
        let pattern = SearchPattern(bytes: [0xAA], encoding: .hex)
        let set = MatchSet(pattern: pattern, folding: .exact, extent: 64, starts: [0, 8, 16])
        var setChanges = 0
        var appearanceChanges = 0
        pane.onMatchSetChanged = { setChanges += 1 }
        pane.onMatchesChanged = { appearanceChanges += 1 }

        pane.setMatches(set)
        XCTAssertEqual(setChanges, 1, "a new set is the list's business")

        pane.setCurrentMatch(1)
        pane.highlightMatches(current: 2)
        pane.endMatchHighlighting()
        XCTAssertEqual(setChanges, 1, "the plate moving, and going, is not")
        XCTAssertEqual(appearanceChanges, 4, "though all of it repaints")

        pane.clearMatches()
        XCTAssertEqual(setChanges, 2, "and a dropped set is, so the list can go with it")
    }

    /// The row the user clicked stays selected. It is the panel's own record of
    /// where the user is; and picking a row moves the find indicator, which
    /// comes back to the panel as a reload — one that must not rebuild the
    /// table and drop the selection it was just given.
    func testAPickedRowStaysSelected() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0xDE, 0xAD, 0x00, 0xDE, 0xAD]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        clickResultRow(1, in: view)

        XCTAssertEqual(view.tableView.selectedRow, 1, "the picked row is selected")
        XCTAssertTrue(pumpUntil(1) { view.tableView.selectedRow == 1 },
                      "and stays selected once the move has settled")

        // A step of the indicator from the bar is the same kind of reload.
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(2) { controller.windowModel.pane1.currentMatchIndex == 2 },
                      "the premise: the indicator moved on")
        XCTAssertEqual(view.tableView.selectedRow, 1, "the picked row is still the picked row")

        // A different search does rebuild the table, so the old row cannot stay.
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "00"
        try clickFindNext(window)
        XCTAssertTrue(pumpUntil(2) { view.listedMatchesForTesting.count == 2 },
                      "the panel followed the new search")
        XCTAssertEqual(view.tableView.selectedRow, -1,
                       "and a row of the previous search is not selected in it")
    }

    /// Retyping the pattern ends the highlighting (the field describes no
    /// search yet) but leaves the panel listing the search that *was* run: the
    /// file has not moved, so those offsets are still true.
    func testTypingANewPatternStopsTheGreysAndLeavesThePanel() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0xDE, 0xAD, 0x00]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD", in: window)
        let (combo, _, _, _) = try barControls(window)
        combo.stringValue = "DE AD B"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: combo)

        let pane = controller.windowModel.pane1
        XCTAssertFalse(pane.highlightsMatches, "a pattern being typed describes no search")
        XCTAssertTrue(hasCount("", in: window), "so the count goes too")
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        XCTAssertTrue(paneView.searchResultsPanelVisible, "the panel stays")
        XCTAssertEqual(view.listedMatchesForTesting, [0..<2, 3..<5], "listing what was run")
    }

    /// An edit is the one thing that voids the results: every offset in the set
    /// becomes a guess, so the set goes — and the panel goes with it, because a
    /// list of offsets the file no longer has is worse than no list (§11).
    func testAnEditTakesThePanelDownWithTheSet() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0x00, 0xDE, 0xAD, 0x00]
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        _ = try runSearchAll("DE AD", in: window)
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let bar = try findBar(window)
        XCTAssertTrue(paneView.searchResultsPanelVisible, "the premise")

        let pane = controller.windowModel.pane1
        pane.moveCaret(to: 2)
        try pane.pasteWrite([0xFF])

        XCTAssertNil(pane.matchSet, "the set is void")
        XCTAssertFalse(paneView.searchResultsPanelVisible, "and the list goes with it")
        XCTAssertFalse(bar.resultsShownForTests, "the bar's toggle follows")
    }

    /// Clicks a result row the way the table does — a selection plus the
    /// table's own action, which is what a real click sends.
    private func clickResultRow(_ row: Int, in view: SearchResultsViewController) {
        view.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        _ = NSApp.sendAction(view.tableView.action!, to: view.tableView.target, from: view.tableView)
    }

    // MARK: - Column widths follow the values (§11)

    /// The value font is monospaced and every value has a known length, so a
    /// column's default width is computed from a template rather than left at a
    /// hand-picked constant: wide enough for the widest value it can hold, and
    /// not materially wider.
    func testColumnWidthsFitTheWidestValue() throws {
        // 4-byte pattern, file big enough that an excerpt is never clamped.
        let pattern: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        var bytes = [UInt8](repeating: 0x41, count: 200)
        bytes.replaceSubrange(100..<104, with: pattern)
        let (controller, window, url) = try makeController(bytes)
        defer { cleanup(controller, url) }

        controller.findPattern()
        let view = try runSearchAll("DE AD BE EF", in: window)
        XCTAssertEqual(view.tableView.numberOfRows, 1)

        let font = AppearanceSettings.font(size: 13)
        func width(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        // 8 bytes of padding either side of a 4-byte match.
        let excerptBytes = 8 + pattern.count + 8
        let expected: [(String, String)] = [
            ("offset", String(repeating: "0", count: 8)),
            ("hex", [String](repeating: "FF", count: excerptBytes).joined(separator: " ")),
            ("text", String(repeating: "W", count: excerptBytes)),
        ]
        for (id, template) in expected {
            let column = try XCTUnwrap(view.tableView.tableColumns.first {
                $0.identifier.rawValue == id
            }, "column \(id)")
            let value = width(template)
            XCTAssertGreaterThanOrEqual(column.width, value,
                                        "\(id) must fit its widest value (\(value) pt)")
            // The only additions are the cell's two 4 pt insets and 1 pt of
            // rounding slack — anything more would be a hand-picked constant.
            XCTAssertLessThanOrEqual(column.width, value + 2 * SearchResultCellView.labelInset + 1,
                                     "\(id) must not be wider than its content needs")
        }
    }


    // MARK: - The case toggle carries its state (§11)

    /// The "Aa" toggle has to LOOK different when it is on. It did not: the
    /// button was `.toggle`, which shows its state by swapping `image` for
    /// `alternateImage`, and no alternate image was ever set — so both states
    /// drew the same glyph on the same bezel and the only way to know whether
    /// the next search would fold case was to run it twice.
    ///
    /// The check is a render, because that is where the bug lived: the flag
    /// behind the button was correct all along.
    func testTheCaseToggleLooksDifferentWhenItIsOn() throws {
        let suite = "FindFlowTests.caseToggle"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        FindBarView.defaults = defaults
        defer {
            FindBarView.defaults = .standard
            defaults.removePersistentDomain(forName: suite)
        }

        // In a window, and displayed: a view with no window never draws, and
        // this is about drawing.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let bar = FindBarView()
        window.contentView = bar
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        bar.prepareForShow()
        // ASCII: the case toggle only means anything where a byte fold models
        // the encoding's case rules, and the bar opens on Hex bytes, where it is
        // disabled and every match is exact (§11).
        bar.selectEncodingForTests(.ascii)

        func render() -> Data? {
            bar.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let rect = bar.caseButton.convert(bar.caseButton.bounds.insetBy(dx: -4, dy: -4), to: bar)
            guard let rep = bar.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            bar.cacheDisplay(in: rect, to: rep)
            return rep.representation(using: .png, properties: [:])
        }

        bar.caseButton.state = .off
        let off = try XCTUnwrap(render())
        XCTAssertFalse(bar.isCaseSensitive, "off means fold case (§11)")

        bar.setCaseSensitiveForTests(true)
        let on = try XCTUnwrap(render())

        XCTAssertNotEqual(off, on, "the toggle's two states must not draw the same")
        XCTAssertTrue(bar.isCaseSensitive, "and on means match exactly")
    }

    /// The state must survive a layout pass. A button's type is stored as its
    /// cell's highlight/state masks, and assigning `bezelStyle` re-derives them —
    /// so setting the type first (as this did) let a real display cycle turn the
    /// toggle back into a momentary button.
    func testTheCaseToggleKeepsItsStateThroughALayoutPass() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let bar = FindBarView()
        window.contentView = bar
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        bar.selectEncodingForTests(.ascii)
        bar.setCaseSensitiveForTests(true)
        bar.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(bar.caseButton.state, .on, "a display cycle must not clear the toggle")
        XCTAssertTrue(bar.isCaseSensitive)
    }
}
