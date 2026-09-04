import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §11: a hex pattern is shown back the way a dump prints it — `deadbeef` goes
/// in, `DE AD BE EF` stands in the field and in the recents.
///
/// Against a bare `FindBarView`: what the search *finds* is the controller's,
/// and what the field says about it is the bar's.
@MainActor
final class HexPatternFormattingTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!
    private var bar: FindBarView!
    private var window: NSWindow!
    private var searched: [FindBarView.Request] = []

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        FindBarView.defaults = store
        FindHistoryStore.defaults = store
        FavoritePatternStore.defaults = store

        bar = FindBarView()
        bar.onSearch = { [weak self] request, _ in self?.searched.append(request) }
        bar.onSearchAll = { [weak self] request in self?.searched.append(request) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 60),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = bar
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        bar.prepareForShow()
    }

    override func tearDown() {
        searched = []
        window = nil
        bar = nil
        FindBarView.defaults = .standard
        FindHistoryStore.defaults = .standard
        FavoritePatternStore.defaults = .standard
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    /// Hex chosen by hand: the search goes out, and the field holds the bytes
    /// in the form the dump beside it prints them.
    func testAHexSearchLeavesTheFieldInTheDumpsForm() {
        if bar.smartSearchOnForTests { bar.smartButton.performClick(nil) }
        bar.setEncodingForTests(.hex)
        bar.setPatternForTests("deadbeef")

        bar.pressFindForTests(.forward)

        XCTAssertEqual(searched.count, 1, "the premise: it searched")
        XCTAssertEqual(bar.patternTextForTests, "DE AD BE EF")
    }

    /// And the recents keep that form: the history records what the field
    /// holds, so the next pick puts the same readable text back.
    func testTheRecentsKeepTheDumpsForm() {
        if bar.smartSearchOnForTests { bar.smartButton.performClick(nil) }
        bar.setEncodingForTests(.hex)
        bar.setPatternForTests("0xde 0xad")

        bar.pressFindForTests(.forward)

        XCTAssertEqual(FindHistoryStore.mostRecent?.pattern, "DE AD")
        XCTAssertEqual(FindHistoryStore.mostRecent?.encoding, .hex)
    }

    /// A Smart Search that lands on hex found *bytes*, so the field says so —
    /// the popup already names the encoding, and the two must agree.
    func testASmartPassThatLandsOnHexFormatsTheField() {
        XCTAssertTrue(bar.smartSearchOnForTests, "the premise")
        bar.setPatternForTests("deadbeef")

        bar.adopt(encoding: .hex)

        XCTAssertEqual(bar.patternTextForTests, "DE AD BE EF")
        XCTAssertEqual(FindHistoryStore.mostRecent?.pattern, "DE AD BE EF",
                       "and that is what is recorded")
    }

    /// A pass that landed on a text encoding leaves the field alone: there the
    /// field holds the string being looked for, not a transcription of bytes.
    func testATextEncodingLeavesTheFieldAlone() {
        bar.setPatternForTests("root")

        bar.adopt(encoding: .ascii)

        XCTAssertEqual(bar.patternTextForTests, "root")
        XCTAssertEqual(FindHistoryStore.mostRecent?.pattern, "root")
    }

    /// Only a search reformats. Typing is left strictly alone — a field that
    /// regrouped bytes under the caret would be unusable.
    func testTypingIsNotReformatted() {
        if bar.smartSearchOnForTests { bar.smartButton.performClick(nil) }
        bar.setEncodingForTests(.hex)

        bar.setPatternForTests("deadbe")

        XCTAssertEqual(bar.patternTextForTests, "deadbe")
    }

    /// Find All is a search too, so it formats and records the same way.
    func testFindAllFormatsTheFieldAsWell() {
        if bar.smartSearchOnForTests { bar.smartButton.performClick(nil) }
        bar.setEncodingForTests(.hex)
        bar.setPatternForTests("5aa5f00f")

        bar.pressFindAllForTests()

        XCTAssertEqual(bar.patternTextForTests, "5A A5 F0 0F")
        XCTAssertEqual(FindHistoryStore.mostRecent?.pattern, "5A A5 F0 0F")
    }
}
