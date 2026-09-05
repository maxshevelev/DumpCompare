import XCTest
@testable import DumpCompareCore

/// What this machine keeps on disk: its own library, and the state it last
/// agreed with each of the other machines' files
/// (`Design/FAVORITES_SYNC_PLAN.md`).
final class FavoritesDocumentTests: XCTestCase {
    private func entry(_ name: String) -> SearchPatternEntry {
        SearchPatternEntry(name: name, pattern: "AA", encoding: .hex)
    }

    private func library(_ names: [String], vector: VersionVector = VersionVector()) -> PatternLibrary {
        var library = PatternLibrary()
        library.setOrder(names.map(entry))
        library.vector = vector
        return library
    }

    /// One base per machine, kept by the name of the file that machine writes.
    func testBasesSurviveARoundTrip() throws {
        var document = FavoritesDocument(local: library(["mine"]))
        document.bases["DumpCompare Patterns (Mac mini 3F7A9C21).json"] =
            library(["theirs"], vector: VersionVector(["mini": 2]))

        let read = try FavoritesDocument(fileContents: document.fileContents())

        XCTAssertEqual(read, document)
        XCTAssertEqual(read.bases.count, 1)
        XCTAssertEqual(read.bases["DumpCompare Patterns (Mac mini 3F7A9C21).json"]?
            .ordered.map(\.name), ["theirs"])
    }

    /// A file written before any of this is a bare library, and is read as this
    /// machine's truth with nothing agreed yet.
    func testABareLibraryIsReadAsTheTruth() throws {
        let read = try FavoritesDocument(fileContents: library(["mine"]).fileContents())

        XCTAssertEqual(read.local.ordered.map(\.name), ["mine"])
        XCTAssertTrue(read.bases.isEmpty)
    }
}
