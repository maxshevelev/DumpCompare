import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §11 Smart Search, through the real bar and window: the toggle, the encoding
/// the search adopts, and what is said when no encoding finds anything.
///
/// What gets tried and in what order is the model's, and tested there
/// (`SmartSearchTests` in the Core package). What is tested here is the part
/// that is UI: that the popup ends up naming the encoding that won, that the
/// history remembers it, and that a pass which found nothing says so.
@MainActor
final class SmartSearchFlowTests: XCTestCase {
    private var isolatedSuiteName = ""
    private var isolatedDefaults: UserDefaults!
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        (isolatedSuiteName, isolatedDefaults) = isolatedDefaults(for: self)
        FindHistoryStore.defaults = isolatedDefaults
        FindBarView.defaults = isolatedDefaults
        FilePaneView.defaults = isolatedDefaults
        FilePaneView.operationDebounce = 0.02
        // The plate holds for four seconds in the app; a test only needs to see
        // it arrive.
        TransientNoticeView.holdDuration = 0.05
    }

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        discardIsolatedDefaults(isolatedSuiteName, isolatedDefaults)
        FindHistoryStore.defaults = .standard
        FindBarView.defaults = .standard
        FilePaneView.defaults = .standard
        FilePaneView.operationDebounce = FilePaneView.defaultOperationDebounce
        TransientNoticeView.holdDuration = 4
        isolatedDefaults = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeController(_ bytes: [UInt8])
        throws -> (MainViewController, NSWindow, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        tempFiles.append(url)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 800, height: 600))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.contentView?.heightAnchor.constraint(greaterThanOrEqualToConstant: 600)
            .isActive = true
        window.layoutIfNeeded()
        return (controller, window, url)
    }

    private func cleanup(_ controller: MainViewController) {
        controller.windowModel.pane1.close()
    }

    private func findBar(_ window: NSWindow) throws -> FindBarView {
        try XCTUnwrap(descendants(of: window.contentView!, FindBarView.self)
            .first { !$0.isHidden })
    }

    private func combo(_ window: NSWindow) throws -> NSComboBox {
        try XCTUnwrap(descendants(of: try findBar(window), NSComboBox.self).first)
    }

    private func encodingPopup(_ window: NSWindow) throws -> NSPopUpButton {
        try XCTUnwrap(descendants(of: try findBar(window), NSPopUpButton.self).first)
    }

    /// Types `pattern` and presses Find Next.
    private func search(_ pattern: String, in window: NSWindow) throws {
        try combo(window).stringValue = pattern
        try findBar(window).pressFindForTests(.forward)
    }

    // MARK: - The toggle

    /// On by default, beside the encoding it takes over, and remembered.
    func testTheToggleIsOnByDefaultAndRemembered() throws {
        let (controller, window, _) = try makeController([0x41])
        defer { cleanup(controller) }
        controller.findPattern()
        let bar = try findBar(window)

        XCTAssertTrue(bar.smartSearchOnForTests, "on until the user says otherwise")
        XCTAssertEqual(bar.smartButton.accessibilityLabel(), "Smart Search")
        XCTAssertFalse(bar.smartButton.isHidden)

        bar.smartButton.performClick(nil)
        XCTAssertFalse(bar.smartSearchOnForTests)
        XCTAssertEqual(isolatedDefaults.object(forKey: FindBarView.smartSearchKey) as? Bool, false,
                       "the choice is remembered")

        // And restored when the bar is opened again.
        let (_, _, done, _) = try barControls(window)
        done.performClick(nil)
        controller.findPattern()
        XCTAssertFalse(try findBar(window).smartSearchOnForTests)
    }

    /// The case toggle is on the bar while Smart Search is, whatever the popup
    /// says: the pass will try the text encodings, so case is a live question
    /// even under `Hex bytes` (§11).
    func testTheCaseToggleStaysWhileSmartSearchIsOn() throws {
        let (controller, window, _) = try makeController([0x41])
        defer { cleanup(controller) }
        controller.findPattern()
        let bar = try findBar(window)
        let popup = try encodingPopup(window)
        popup.selectItem(at: SearchEncoding.allCases.firstIndex(of: .hex)!)
        popup.sendAction(popup.action, to: popup.target)

        XCTAssertTrue(bar.smartSearchOnForTests, "the premise")
        XCTAssertFalse(bar.caseButton.isHidden, "case matters for the encodings it will try")

        bar.smartButton.performClick(nil)
        XCTAssertTrue(bar.caseButton.isHidden, "and with the chosen encoding, hex has no case")
    }

    private func barControls(_ window: NSWindow)
        throws -> (NSComboBox, NSPopUpButton, NSButton, NSButton) {
        let bar = try findBar(window)
        let buttons = descendants(of: bar, NSButton.self)
        func button(_ label: String) throws -> NSButton {
            try XCTUnwrap(buttons.first { $0.accessibilityLabel() == label }, "button \(label)")
        }
        return (try combo(window), try encodingPopup(window),
                try button("Done"), try button("Case Sensitive"))
    }

    // MARK: - The encoding is a result

    /// The reader knows the string and not how it is stored: `boot` is in the
    /// file as UTF-16, and typing it finds it — with the popup left naming the
    /// encoding that found it, and the history remembering that pairing.
    func testAStringStoredAsUTF16IsFoundAndItsEncodingAdopted() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 512)
        bytes.replaceSubrange(64..<72, with: [0x62, 0, 0x6F, 0, 0x6F, 0, 0x74, 0])
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        try search("boot", in: window)

        XCTAssertTrue(pumpUntil(5) { pane.hexSelection().start == 64 },
                      "the string is found in the encoding it is stored in")
        XCTAssertEqual(pane.hexSelection().end, 72)
        XCTAssertEqual(pane.currentMatch, 64..<72, "and the plate is on it")
        XCTAssertEqual(try encodingPopup(window).titleOfSelectedItem, "UTF-16 LE",
                       "the popup says how it was found")
        XCTAssertEqual(FindHistoryStore.mostRecent?.encoding, .utf16LE,
                       "and the history remembers the pairing")
        XCTAssertEqual(FindHistoryStore.mostRecent?.pattern, "boot")
    }

    /// A pattern that reads as hex is bytes first — and the popup says so.
    func testAHexLikePatternIsAdoptedAsBytes() throws {
        var bytes = [UInt8](repeating: 0x41, count: 256)
        bytes.replaceSubrange(32..<34, with: [0xDE, 0xAD])
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        try search("DE AD", in: window)

        XCTAssertTrue(pumpUntil(5) { pane.hexSelection().start == 32 })
        XCTAssertEqual(try encodingPopup(window).titleOfSelectedItem, "Hex bytes")
        XCTAssertEqual(FindHistoryStore.mostRecent?.encoding, .hex)
    }

    /// The index behind the answer is the adopted encoding's, so the count and
    /// the panel are about the search that was actually found (§11).
    func testTheAdoptedEncodingIsWhatGetsIndexed() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 512)
        bytes.replaceSubrange(64..<72, with: [0x62, 0, 0x6F, 0, 0x6F, 0, 0x74, 0])
        bytes.replaceSubrange(128..<136, with: [0x62, 0, 0x6F, 0, 0x6F, 0, 0x74, 0])
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        try search("boot", in: window)

        XCTAssertTrue(pumpUntil(5) { pane.matchSet?.isComplete == true },
                      "the index lands behind the answer")
        XCTAssertEqual(pane.matchSet?.pattern.encoding, .utf16LE)
        XCTAssertEqual(pane.matchSet?.total, 2, "both occurrences, in that encoding")
        XCTAssertTrue(pumpUntil(2) { (try? self.findBar(window))?.countTextForTests == "1 of 2" })
    }

    /// A hex search, then a text one, in the same session — the reported bug:
    /// after a Smart Search settled on `Hex bytes`, a string that is plainly in
    /// the file as ASCII came back not found until the encoding was switched by
    /// hand. Typing the second pattern is part of the case: it ends the first
    /// search's highlighting, and the second press must still be a fresh pass
    /// rather than anything to do with what the popup now says.
    func testATextSearchAfterAHexSearchStillFindsTheText() throws {
        var bytes = [UInt8](repeating: 0x41, count: 512)
        bytes.replaceSubrange(32..<34, with: [0xDE, 0xAD])
        bytes.replaceSubrange(128..<132, with: Array("boot".utf8))
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        try search("DE AD", in: window)
        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 32..<34 }, "the hex pattern is found")
        XCTAssertEqual(try encodingPopup(window).titleOfSelectedItem, "Hex bytes")

        // The user types over it, which ends the first search's highlighting.
        let field = try combo(window)
        field.stringValue = "boot"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        try findBar(window).pressFindForTests(.forward)

        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 128..<132 },
                      "the text is in the file as ASCII, so Smart Search must find it")
        XCTAssertEqual(try encodingPopup(window).titleOfSelectedItem, "ASCII",
                       "and the popup follows the encoding that found it")
    }

    /// The same, with a second pattern that *also* reads as hex: `cafe` is four
    /// hex digits and a word, so the pass tries the bytes first and the text
    /// after — and the text is what is in the file.
    func testAHexLikeStringIsFoundAsTextWhenItsBytesAreNotThere() throws {
        var bytes = [UInt8](repeating: 0x41, count: 512)
        bytes.replaceSubrange(32..<34, with: [0xDE, 0xAD])
        bytes.replaceSubrange(200..<204, with: Array("cafe".utf8))
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        try search("DE AD", in: window)
        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 32..<34 }, "the hex pattern first")

        let field = try combo(window)
        field.stringValue = "cafe"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        try findBar(window).pressFindForTests(.forward)

        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 200..<204 },
                      "CA FE is nowhere, so the word is what is found")
        XCTAssertEqual(try encodingPopup(window).titleOfSelectedItem, "ASCII")
    }

    /// And through the combo's own action, which is what Return in the field
    /// actually calls — a path with one more way to go wrong: it treats a
    /// selected dropdown item as a *pick* rather than a search.
    func testReturnInTheFieldSearchesRatherThanRepickingHistory() throws {
        var bytes = [UInt8](repeating: 0x41, count: 512)
        bytes.replaceSubrange(32..<34, with: [0xDE, 0xAD])
        bytes.replaceSubrange(128..<132, with: Array("boot".utf8))
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let field = try combo(window)
        field.stringValue = "DE AD"
        field.sendAction(field.action, to: field.target)   // Return
        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 32..<34 }, "the hex pattern")

        field.stringValue = "boot"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        field.sendAction(field.action, to: field.target)   // Return again

        XCTAssertEqual(field.stringValue, "boot", "the press must not rewrite the field")
        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 128..<132 },
                      "and it must search what is in the field")
    }

    // MARK: - What the user already knows (§11)

    /// A pattern picked out of the history comes with an encoding — the entry
    /// records the pair — and that is a statement about the encoding as much as
    /// about the pattern. So the first attempt is *that* encoding, even where
    /// Smart Search's own order would have tried another one first and found
    /// something.
    func testAPickedHistoryEntryIsTriedInItsOwnEncodingFirst() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 512)
        bytes.replaceSubrange(64..<68, with: Array("boot".utf8))          // ASCII
        bytes.replaceSubrange(128..<136, with: [0x62, 0, 0x6F, 0, 0x6F, 0, 0x74, 0])  // UTF-16LE
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        let pane = controller.windowModel.pane1
        // The pattern was last found as UTF-16 LE.
        FindHistoryStore.record(pattern: "boot", encoding: .utf16LE)

        controller.findPattern()
        let bar = try findBar(window)
        XCTAssertEqual(bar.preferredEncodingForTests, .utf16LE,
                       "the bar opens on the last search, encoding and all")
        try findBar(window).pressFindForTests(.forward)

        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 128..<136 },
                      "the encoding the user brought is tried before the app's own guesses")
        XCTAssertEqual(try encodingPopup(window).titleOfSelectedItem, "UTF-16 LE")
    }

    /// And typing takes that back: the text is the user's again, so the
    /// encoding is the app's to work out — ASCII, which its order tries first,
    /// and which is where the string also is.
    func testTypingForgetsThePickedEncoding() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 512)
        bytes.replaceSubrange(64..<68, with: Array("boot".utf8))
        bytes.replaceSubrange(128..<136, with: [0x62, 0, 0x6F, 0, 0x6F, 0, 0x74, 0])
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        let pane = controller.windowModel.pane1
        FindHistoryStore.record(pattern: "boot", encoding: .utf16LE)

        controller.findPattern()
        let bar = try findBar(window)
        let field = try combo(window)
        // Typed over — the same text, which is the sharpest form of the case:
        // only the *provenance* differs.
        field.stringValue = "boot"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        XCTAssertNil(bar.preferredEncodingForTests, "a keystroke takes the pairing back")
        try findBar(window).pressFindForTests(.forward)

        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 64..<68 },
                      "so the default order applies, and ASCII comes first")
        XCTAssertEqual(try encodingPopup(window).titleOfSelectedItem, "ASCII")
    }

    /// Choosing the encoding by hand is a statement too — with Smart Search on
    /// it is what the first attempt uses, which is how a reader who *knows* the
    /// string is ASCII says so without turning Smart Search off.
    func testChoosingTheEncodingByHandIsTriedFirst() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 512)
        bytes.replaceSubrange(64..<68, with: Array("beef".utf8))
        bytes.replaceSubrange(200..<202, with: [0xBE, 0xEF])
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let field = try combo(window)
        field.stringValue = "beef"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        // `beef` reads as hex, so without a word from the user the bytes win.
        let popup = try encodingPopup(window)
        popup.selectItem(at: SearchEncoding.allCases.firstIndex(of: .ascii)!)
        popup.sendAction(popup.action, to: popup.target)
        try findBar(window).pressFindForTests(.forward)

        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 64..<68 },
                      "the chosen encoding is tried first, so the word wins over the bytes")
        XCTAssertEqual(try encodingPopup(window).titleOfSelectedItem, "ASCII")
    }

    /// The reported case, with the shape of the file it was reported on: a
    /// 16 MB dump holding `FF 33` early and the word `Root` — capital R, and no
    /// lowercase `root` anywhere. Searching `FF 33` adopts hex; typing `root`
    /// must then find `Root`, because the case toggle is off and ASCII folds
    /// letters.
    func testTheReportedSequenceOnADumpsShape() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 16 << 20)
        bytes.replaceSubrange(0x2eae3..<0x2eae5, with: [0xFF, 0x33])
        bytes.replaceSubrange(0x66a144..<0x66a148, with: Array("Root".utf8))
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        let pane = controller.windowModel.pane1

        controller.findPattern()
        let bar = try findBar(window)
        XCTAssertFalse(bar.caseButton.state == .on, "the premise: case-insensitive")
        try search("FF 33", in: window)
        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 0x2eae3..<0x2eae5 },
                      "the hex pattern is found")
        XCTAssertEqual(try encodingPopup(window).titleOfSelectedItem, "Hex bytes")

        let field = try combo(window)
        field.stringValue = "root"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        try findBar(window).pressFindForTests(.forward)

        XCTAssertTrue(pumpUntil(5) { pane.currentMatch == 0x66a144..<0x66a148 },
                      "`root` folds onto `Root`, so Smart Search must find it")
        XCTAssertEqual(try encodingPopup(window).titleOfSelectedItem, "ASCII")
        XCTAssertNil(controller.transientNotice, "and nothing reports a failure")
    }

    // MARK: - When nothing is found anywhere

    /// A pass that comes back empty says so as a plate over the window, naming
    /// every encoding it tried: the answer is about the pass, not about any one
    /// of its scans (§11).
    func testAPassThatFindsNothingNamesWhatItTried() throws {
        let (controller, window, _) = try makeController([UInt8](repeating: 0xFF, count: 256))
        defer { cleanup(controller) }

        controller.findPattern()
        try search("boot", in: window)

        XCTAssertTrue(pumpUntil(5) { controller.transientNotice != nil },
                      "the plate appears")
        let notice = try XCTUnwrap(controller.transientNotice)
        XCTAssertEqual(notice.lines.first, "Smart search.")
        XCTAssertEqual(notice.lines.dropFirst().map { $0 },
                       ["ASCII, UTF-8 — no results.",
                        "UTF-16 LE — no results.",
                        "UTF-16 BE — no results."],
                       "one line per question asked, naming every encoding it stood for")
        XCTAssertTrue(pumpUntil(2) { (try? self.findBar(window))?.countTextForTests
                                        == "Not found" },
                      "and the bar says it too, where a count would go")
    }

    /// A hex-looking pattern that is nowhere lists hex among the encodings it
    /// tried — including as text, which is the point of trying it.
    func testAHexLikePatternThatIsNowhereListsHexFirst() throws {
        let (controller, window, _) = try makeController([UInt8](repeating: 0x41, count: 256))
        defer { cleanup(controller) }

        controller.findPattern()
        try search("DE AD", in: window)

        XCTAssertTrue(pumpUntil(5) { controller.transientNotice != nil })
        let notice = try XCTUnwrap(controller.transientNotice)
        XCTAssertEqual(notice.lines.dropFirst().first, "Hex bytes — no results.")
        XCTAssertEqual(notice.lines.count, 5, "hex, then the text encodings it also tried")
    }

    /// Where the plate sits: horizontally centred in the window, in the lower
    /// third — out of the way of the bytes being read at the top of it, and of
    /// the find bar above them (§11).
    func testTheNoticeIsCentredAndSitsInTheLowerThird() throws {
        let (controller, window, _) = try makeController([UInt8](repeating: 0xFF, count: 256))
        defer { cleanup(controller) }

        controller.findPattern()
        try search("boot", in: window)
        XCTAssertTrue(pumpUntil(5) { controller.transientNotice != nil })
        window.layoutIfNeeded()

        let notice = try XCTUnwrap(controller.transientNotice)
        let content = controller.view
        XCTAssertEqual(notice.frame.midX, content.bounds.midX, accuracy: 0.5,
                       "centred across the window")
        XCTAssertGreaterThan(notice.frame.width, 100, "and sized to its lines")
        // The view is not flipped, so a third of the way *up* is a small y.
        XCTAssertEqual(notice.frame.midY,
                       content.bounds.height * TransientNoticePresenter.verticalFraction,
                       accuracy: 1,
                       "a third of the height up from the bottom")
        XCTAssertGreaterThan(notice.frame.minY, content.bounds.minY, "inside the window")
        XCTAssertLessThan(notice.frame.midY, content.bounds.midY, "and below its middle")
    }

    /// A plate reports a search, so it goes the moment that search stops being
    /// the current one: activating another pattern takes it away at once
    /// rather than leaving it to sit out its four seconds over a search that
    /// has already answered (§11).
    func testANewSearchTakesTheStalePlateAway() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 512)
        bytes.replaceSubrange(64..<68, with: Array("boot".utf8))
        let (controller, window, _) = try makeController(bytes)
        defer { cleanup(controller) }
        // Long enough that only a deliberate dismissal can end it.
        TransientNoticeView.holdDuration = 5
        defer { TransientNoticeView.holdDuration = 0.05 }

        controller.findPattern()
        try search("nowhere", in: window)
        XCTAssertTrue(pumpUntil(5) { controller.transientNotice != nil }, "the premise")

        let field = try combo(window)
        field.stringValue = "boot"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        try findBar(window).pressFindForTests(.forward)

        XCTAssertNil(controller.transientNotice, "the stale answer is gone at once")
        XCTAssertTrue(pumpUntil(2) { controller.windowModel.pane1.currentMatch == 64..<68 },
                      "and the new search runs")
    }

    /// And dismissing the bar takes it with it: the plate is about a search,
    /// and closing the bar means that search is over (§11).
    func testClosingTheBarTakesThePlateAway() throws {
        let (controller, window, _) = try makeController([UInt8](repeating: 0xFF, count: 256))
        defer { cleanup(controller) }
        TransientNoticeView.holdDuration = 5
        defer { TransientNoticeView.holdDuration = 0.05 }

        controller.findPattern()
        try search("nowhere", in: window)
        XCTAssertTrue(pumpUntil(5) { controller.transientNotice != nil }, "the premise")
        let plate = try XCTUnwrap(controller.transientNotice)

        let (_, _, done, _) = try barControls(window)
        done.performClick(nil)

        XCTAssertNil(controller.transientNotice, "gone with the bar")
        XCTAssertTrue(pumpUntil(2) { plate.superview == nil }, "and off the window")
    }

    /// It goes on its own, and takes nothing with it: a report, not a dialog.
    func testTheNoticeLeavesOnItsOwn() throws {
        let (controller, window, _) = try makeController([UInt8](repeating: 0xFF, count: 256))
        defer { cleanup(controller) }

        controller.findPattern()
        try search("boot", in: window)
        XCTAssertTrue(pumpUntil(5) { controller.transientNotice != nil })
        let notice = try XCTUnwrap(controller.transientNotice)

        XCTAssertTrue(pumpUntil(3) { notice.superview == nil },
                      "the plate takes itself off screen")
    }

    /// A click over the plate belongs to the dump underneath: it reports and
    /// leaves, so it is never something to dismiss.
    func testTheNoticeDoesNotSwallowClicks() throws {
        let (controller, window, _) = try makeController([UInt8](repeating: 0xFF, count: 256))
        defer { cleanup(controller) }

        controller.findPattern()
        try search("boot", in: window)
        XCTAssertTrue(pumpUntil(5) { controller.transientNotice != nil })
        let notice = try XCTUnwrap(controller.transientNotice)

        XCTAssertNil(notice.hitTest(NSPoint(x: notice.bounds.midX, y: notice.bounds.midY)))
    }
}
