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

    /// Where the plate sits: horizontally centred in the window, above the
    /// middle — where Xcode puts a build's result (§11).
    func testTheNoticeIsCentredAndSitsAboveTheMiddle() throws {
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
        // The view is not flipped, so "above the middle" is a larger y.
        XCTAssertEqual(notice.frame.midY,
                       content.bounds.height * (1 - MainViewController.noticeVerticalFraction),
                       accuracy: 1,
                       "a third of the way down from the top")
        XCTAssertLessThan(notice.frame.midY, content.bounds.maxY, "inside the window")
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
