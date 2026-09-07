import XCTest
@testable import DumpCompareCore

/// `Design/FAVORITES_SYNC_PLAN.md`: the library as a document — what is written
/// to a file, and what another machine's build has to be able to read.
///
/// The file is the one part of this feature that outlives the build that wrote
/// it, so the tests are mostly about reading: an older file, a newer one, and a
/// file somebody edited by hand.
final class PatternLibraryTests: XCTestCase {
    private func entry(_ name: String, _ pattern: String,
                       _ encoding: SearchEncoding = .hex) -> SearchPatternEntry {
        SearchPatternEntry(name: name, pattern: pattern, encoding: encoding)
    }

    // MARK: - The file

    func testALibraryRoundTrips() throws {
        var library = PatternLibrary()
        library.setOrder([entry("ME FPT", "$FPT", .ascii), entry("Capsule", "5A A5")])
        library.tombstones = [PatternLibrary.Tombstone(id: UUID(), device: "8B2C")]
        library.vector = VersionVector(["8B2C": 3])

        let read = try PatternLibrary(fileContents: library.fileContents())

        XCTAssertEqual(read.ordered.map(\.name), ["ME FPT", "Capsule"])
        XCTAssertEqual(read.entries.map(\.id), library.entries.map(\.id), "ids survive")
        XCTAssertEqual(read.entries.map(\.sortKey), library.entries.map(\.sortKey))
        XCTAssertEqual(read.entries, library.entries, "and so does what each one says")
        XCTAssertEqual(read.tombstones.map(\.id), library.tombstones.map(\.id))
        XCTAssertEqual(read.tombstones.map(\.device), library.tombstones.map(\.device))
        XCTAssertEqual(read.vector, library.vector)
        XCTAssertEqual(read.format, library.format)
        // Timestamps are kept to the millisecond — enough to order two edits,
        // and legible in the file, which a raw epoch would not be.
        XCTAssertEqual(read.entries[0].modifiedAt.timeIntervalSince1970,
                       library.entries[0].modifiedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(read.tombstones[0].deletedAt.timeIntervalSince1970,
                       library.tombstones[0].deletedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    /// It is meant to be read by a person and diffed by a tool.
    func testTheFileIsLegible() throws {
        var library = PatternLibrary()
        library.setOrder([entry("ME FPT", "$FPT", .ascii)])
        let text = try XCTUnwrap(String(data: library.fileContents(), encoding: .utf8))

        XCTAssertTrue(text.contains("\n"), "pretty-printed, not one line")
        XCTAssertTrue(text.contains("\"name\" : \"ME FPT\""), text)
        XCTAssertLessThan(text.range(of: "\"caseSensitive\"")!.lowerBound,
                          text.range(of: "\"encoding\"")!.lowerBound,
                          "keys are sorted, so a diff of one change is one line")
    }

    /// A file written by a build that had none of the syncing yet is a library,
    /// not an error: everything but the pattern and its encoding is optional.
    func testAFileFromAnEarlierBuildReads() throws {
        let json = """
        { "entries": [ { "name": "ME FPT", "pattern": "$FPT", "encoding": "ascii" } ] }
        """
        let library = try PatternLibrary(fileContents: Data(json.utf8))

        XCTAssertEqual(library.entries.count, 1)
        XCTAssertEqual(library.entries[0].name, "ME FPT")
        XCTAssertEqual(library.entries[0].sortKey, 0)
        XCTAssertTrue(library.entries[0].device.isEmpty)
        XCTAssertEqual(library.format, PatternLibrary.currentFormat)
        XCTAssertTrue(library.tombstones.isEmpty)
    }

    /// And one from a *later* build is read for what this build knows, rather
    /// than refused — the other machine may be ahead of this one.
    func testAFileFromALaterBuildKeepsWhatThisBuildUnderstands() throws {
        let json = """
        { "format": 99, "somethingNew": true,
          "entries": [ { "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
                         "name": "ME FPT", "pattern": "$FPT", "encoding": "ascii",
                         "caseSensitive": false, "sortKey": 2048,
                         "modifiedAt": "2026-09-05T10:14:22Z", "device": "8B2C",
                         "colour": "red" } ] }
        """
        let library = try PatternLibrary(fileContents: Data(json.utf8))

        XCTAssertEqual(library.format, 99, "read as it was written")
        XCTAssertEqual(library.entries.count, 1)
        XCTAssertEqual(library.entries[0].id, UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA"))
        XCTAssertEqual(library.entries[0].sortKey, 2048)
        XCTAssertEqual(library.entries[0].device, "8B2C")
    }

    /// Bytes that are not a library at all do throw — the caller keeps the last
    /// good copy rather than replacing it with nothing.
    func testGarbageThrows() {
        XCTAssertThrowsError(try PatternLibrary(fileContents: Data("not json".utf8)))
        XCTAssertThrowsError(try PatternLibrary(
            fileContents: Data(#"{ "entries": [ { "name": "no pattern" } ] }"#.utf8)))
    }

    // MARK: - Order

    /// The order is the user's, and it is carried by the entries rather than by
    /// their position in the array — two machines renumbering one list have
    /// nothing left to merge.
    func testOrderTravelsWithTheEntries() {
        var library = PatternLibrary()
        library.setOrder([entry("first", "11"), entry("second", "22"), entry("third", "33")])

        XCTAssertEqual(library.ordered.map(\.name), ["first", "second", "third"])
        XCTAssertEqual(library.entries.map(\.sortKey), [1024, 2048, 3072])

        // Shuffled in the array, the order still reads off the keys.
        library.entries.reverse()
        XCTAssertEqual(library.ordered.map(\.name), ["first", "second", "third"])
    }

    /// Entries that were never placed — a library migrated from the old store —
    /// keep the order they arrived in, and reading twice gives the same list.
    func testUnplacedEntriesKeepTheOrderTheyArrivedIn() {
        var library = PatternLibrary()
        library.entries = [entry("first", "11"), entry("second", "22"), entry("third", "33")]

        XCTAssertEqual(library.ordered.map(\.name), ["first", "second", "third"])
        XCTAssertEqual(library.ordered.map(\.name), library.ordered.map(\.name))
    }

    /// A dragged row asks for a place between two others, and gets one without
    /// renumbering anything else.
    func testAKeyBetweenTwoOthersNeedsNoRenumbering() {
        let between = PatternLibrary.sortKey(between: 1024, and: 2048)
        XCTAssertGreaterThan(between, 1024)
        XCTAssertLessThan(between, 2048)

        XCTAssertGreaterThan(PatternLibrary.sortKey(between: 3072, and: nil), 3072,
                             "dropped at the end")
        XCTAssertLessThan(PatternLibrary.sortKey(between: nil, and: 1024), 1024,
                          "dropped at the front")
        XCTAssertEqual(PatternLibrary.sortKey(between: nil, and: nil),
                       PatternLibrary.sortKeyStep, "the first entry of an empty list")
    }
}
