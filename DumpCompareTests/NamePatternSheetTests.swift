import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §11: naming the pattern in the Find bar, which is how a library actually
/// fills up — nobody opens Settings to type a pattern from memory.
@MainActor
final class NamePatternSheetTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        FavoritePatternStore.defaults = store
    }

    override func tearDown() {
        FavoritePatternStore.defaults = .standard
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    private func makeSheet(_ entry: SearchPatternEntry)
    -> (sheet: NamePatternSheetController, kept: () -> SearchPatternEntry?) {
        var captured: SearchPatternEntry?
        let sheet = NamePatternSheetController(entry: entry) { captured = $0 }
        _ = sheet.view  // loadView builds the widgets
        return (sheet, { captured })
    }

    private func name(_ sheet: NamePatternSheetController) -> NSTextField? {
        sheet.firstField() as? NSTextField
    }

    /// The sheet asks for the one thing the bar has not got. What is being kept
    /// is stated above the field and cannot be edited there — it is already
    /// what the user typed.
    func testItAsksForANameAndSaysWhatIsBeingKept() throws {
        let (sheet, _) = makeSheet(SearchPatternEntry(pattern: "windows", encoding: .utf16LE))

        XCTAssertEqual(try XCTUnwrap(name(sheet)).stringValue, "",
                       "the name starts empty — a pattern has none yet")
        let message = try XCTUnwrap(sheet.messageText)
        XCTAssertTrue(message.contains("\"windows\""), message)
        XCTAssertTrue(message.contains("UTF-16 LE"), message)
        XCTAssertTrue(message.contains("ignore case"), message)
    }

    /// Hex says nothing about case: bytes have none, so the line does not
    /// pretend the flag means something (§11).
    func testHexSaysNothingAboutCase() throws {
        let (sheet, _) = makeSheet(SearchPatternEntry(pattern: "DE AD", encoding: .hex,
                                                      caseSensitive: true))
        let message = try XCTUnwrap(sheet.messageText)
        XCTAssertTrue(message.contains("Hex bytes"), message)
        XCTAssertFalse(message.contains("case"), message)
    }

    /// A name is the point of the entry — a favourite without one renders as a
    /// recent, and the list gains a row nothing can find again.
    func testANameIsRequired() {
        let (sheet, kept) = makeSheet(SearchPatternEntry(pattern: "windows", encoding: .ascii))

        name(sheet)?.stringValue = "   "

        XCTAssertNotNil(sheet.validate(), "the sheet says why")
        sheet.submitPressed()
        XCTAssertNil(kept(), "and nothing was kept")
        XCTAssertFalse(sheet.errorLabel.stringValue.isEmpty)
    }

    /// The name is trimmed, and everything else comes through as the bar had
    /// it: the encoding the popup names (after a Smart Search, the one that
    /// *worked*) and the case rule.
    func testKeepingTakesTheNameAndTheBarsOwnSearch() throws {
        let entry = SearchPatternEntry(pattern: "windows", encoding: .utf16LE, caseSensitive: true)
        let (sheet, kept) = makeSheet(entry)

        name(sheet)?.stringValue = "  Windows loader "
        XCTAssertNil(sheet.validate())
        sheet.handleSubmit()

        let result = try XCTUnwrap(kept())
        XCTAssertEqual(result.name, "Windows loader")
        XCTAssertEqual(result.pattern, "windows")
        XCTAssertEqual(result.encoding, .utf16LE)
        XCTAssertTrue(result.caseSensitive)
    }

    /// The same search under two names is two answers to one question, so the
    /// sheet refuses and says which name it is already kept under (§11).
    func testTheSameSearchIsRefusedByName() {
        FavoritePatternStore.add(SearchPatternEntry(name: "ME FPT", pattern: "$FPT",
                                                    encoding: .ascii))
        let (sheet, kept) = makeSheet(SearchPatternEntry(pattern: "$FPT", encoding: .ascii))

        name(sheet)?.stringValue = "Something else"

        let complaint = sheet.validate() ?? ""
        XCTAssertTrue(complaint.contains("ME FPT"), complaint)
        sheet.submitPressed()
        XCTAssertNil(kept())
    }

    /// The same pattern in another encoding is a different search, and is kept.
    func testTheSamePatternInAnotherEncodingIsKept() throws {
        FavoritePatternStore.add(SearchPatternEntry(name: "as text", pattern: "4142",
                                                    encoding: .ascii))
        let (sheet, kept) = makeSheet(SearchPatternEntry(pattern: "4142", encoding: .hex))

        name(sheet)?.stringValue = "as bytes"
        XCTAssertNil(sheet.validate())
        sheet.handleSubmit()

        XCTAssertEqual(try XCTUnwrap(kept()).name, "as bytes")
    }

    /// A pattern the bar could not search is not kept either — the validation
    /// is the bar's own parse, and the only way to reach this sheet with one is
    /// a hand-edited store picked back into the field (§11).
    func testAnUnsearchablePatternIsRefused() {
        let (sheet, kept) = makeSheet(SearchPatternEntry(pattern: "DE A", encoding: .hex))

        name(sheet)?.stringValue = "Hand-edited"

        XCTAssertNotNil(sheet.validate())
        sheet.submitPressed()
        XCTAssertNil(kept())
    }
}
