import DumpCompareCore
import XCTest
@testable import DumpCompare

/// M5 tests for the pane's comparison-mode behaviors: live visible diff against
/// the companion (§8.3 rule 6: background state, EOF-only highlighting) and
/// caret/selection synchronization by absolute offset (§9).
@MainActor
final class ComparisonPaneTests: XCTestCase {
    /// Opens both files and cross-wires them as companions. Files stay on disk
    /// for the whole test (the storages read them lazily). Bind the returned
    /// tuple to a `let` for the test's lifetime: the panes reference each other
    /// weakly, so dropping either side deallocates it and the companion diff
    /// silently turns off.
    private func openPair(_ left: [UInt8], _ right: [UInt8]) throws -> (PaneViewModel, PaneViewModel, URL, URL) {
        let urlA = try tempFile(left)
        let urlB = try tempFile(right)
        let paneA = PaneViewModel()
        let paneB = PaneViewModel()
        try paneA.open(url: urlA)
        try paneB.open(url: urlB)
        paneA.companion = paneB
        paneB.companion = paneA
        return (paneA, paneB, urlA, urlB)
    }

    // MARK: - Live visible diff (§8.3 rule 6)

    func testDifferentBytesMarkedInBothPanes() throws {
        let pair = try openPair([0x41, 0x42, 0x43], [0x41, 0x00, 0x43])
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        let a = pair.0.hexByteStates(in: 0..<3)
        XCTAssertEqual(a.map(\.isDifferent), [false, true, false])
        XCTAssertEqual(a.map(\.byte), [0x41, 0x42, 0x43])
        let b = pair.1.hexByteStates(in: 0..<3)
        XCTAssertEqual(b.map(\.isDifferent), [false, true, false])
        XCTAssertEqual(b.map(\.byte), [0x41, 0x00, 0x43])
    }

    /// The two sides of one rule in `hexByteStates`: where the files differ only
    /// in length, the byte that exists on one side alone is a *difference* there
    /// and a *placeholder* on the side that ran out. Both arms read the same pair,
    /// so a failure points at that single asymmetry.
    func testEOFIsAPlaceholderOnTheShortSideAndADifferenceOnTheLong() throws {
        let pair = try openPair([0x41, 0x42], [0x41, 0x42, 0x43])
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        // Short side: present bytes match; past EOF is a placeholder, not a
        // difference — and the row is read past the companion's end too.
        let short = pair.0.hexByteStates(in: 0..<4)
        XCTAssertEqual(short.map(\.isDifferent), [false, false, false, false],
                       "nothing past the shorter file's end may be marked different")
        XCTAssertEqual(short.map(\.isEOF), [false, false, true, true],
                       "the shorter pane marks every offset past its own end as EOF")

        // Long side: bytes 0-1 match; byte 2 exists only here → EOF-only difference.
        let long = pair.1.hexByteStates(in: 0..<3)
        XCTAssertEqual(long.map(\.isDifferent), [false, false, true],
                       "the byte the companion does not have is a difference here")
        XCTAssertEqual(long.map(\.isEOF), [false, false, false],
                       "the longer pane has no EOF placeholder inside its own file")
        XCTAssertEqual(long[2].byte, 0x43, "the EOF-only byte still shows its value")
    }

    func testDifferentAndModifiedShownTogether() throws {
        let pair = try openPair([0x41], [0x42])
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        pair.0.typeASCII(0x43)  // edit byte 0 → 0x43 (modified + different)
        let state = pair.0.hexByteStates(in: 0..<1)[0]
        XCTAssertEqual(state.byte, 0x43)
        XCTAssertTrue(state.isModified)
        XCTAssertTrue(state.isDifferent)
    }

    func testEditUpdatesVisibleDiffImmediately() throws {
        let pair = try openPair([0x41], [0x42])
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        var state = pair.0.hexByteStates(in: 0..<1)[0]
        XCTAssertTrue(state.isDifferent)
        pair.0.typeASCII(0x42)  // now matches the companion
        state = pair.0.hexByteStates(in: 0..<1)[0]
        XCTAssertFalse(state.isDifferent)
    }

    // MARK: - Selection mirroring (§9)

    /// One rule, both directions: `hexMirroredSelection` carries the companion's
    /// selection over by absolute offset, clamped to the receiving pane's own
    /// file size. Into the longer pane nothing is lost; into the shorter one the
    /// end is cut at EOF.
    ///
    /// The expected selections are written out rather than derived from
    /// `hexSelection().clamped(to:)`, which is the production expression itself
    /// and so would pass for any mirror at all.
    func testTheMirrorCarriesTheCompanionsSelectionAndClampsItToEOF() throws {
        let pair = try openPair(Array(repeating: 0x00, count: 10), Array(repeating: 0x00, count: 20))
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        pair.0.setSelection(SelectionModel(start: 3, end: 7, fileSize: 10))
        XCTAssertEqual(pair.1.hexMirroredSelection(), SelectionModel(start: 3, end: 7, fileSize: 20),
                       "a selection well inside both files mirrors over unchanged")

        // The longer pane's selection (5…15) mirrors into the shorter pane
        // clamped to its EOF.
        pair.1.setSelection(SelectionModel(start: 5, end: 15, fileSize: 20))
        XCTAssertEqual(pair.0.hexMirroredSelection(), SelectionModel(start: 5, end: 10, fileSize: 10),
                       "a selection running past the shorter file is cut at its end")

        // …and the mirror is symmetric: setting the second selection did not
        // disturb what the first pane sends the other way.
        XCTAssertEqual(pair.1.hexMirroredSelection(), SelectionModel(start: 3, end: 7, fileSize: 20),
                       "each pane mirrors the other independently, in both directions")
    }

    func testSelectionsAreIndependent() throws {
        let pair = try openPair(Array(repeating: 0x00, count: 5), Array(repeating: 0x00, count: 5))
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        // Moving either caret must not touch the other pane's selection…
        pair.0.moveCaret(to: 3)
        XCTAssertEqual(pair.0.caretOffset, 3)
        XCTAssertEqual(pair.1.caretOffset, 0)
        pair.1.moveCaret(to: 1)
        XCTAssertEqual(pair.0.caretOffset, 3)
        XCTAssertEqual(pair.1.caretOffset, 1)
        // …but each pane still mirrors the other's selection.
        XCTAssertEqual(pair.1.hexMirroredSelection(), pair.0.hexSelection())
        XCTAssertEqual(pair.0.hexMirroredSelection(), pair.1.hexSelection())
    }

    /// A bare caret (empty selection) mirrors as an empty selection, which the
    /// view traces as a single-byte contour on the opposite pane; a standalone
    /// pane has no companion and mirrors nothing at all.
    func testEmptyAndNoCompanionMirrorNothing() throws {
        let pair = try openPair([0x00, 0x00], [0x00, 0x00])
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        // Empty selection on the companion → empty mirrored selection.
        pair.0.moveCaret(to: 1)
        XCTAssertEqual(pair.1.hexMirroredSelection(), SelectionModel.empty(at: 1, fileSize: 2))

        // A lone pane has no companion to mirror.
        let lone = PaneViewModel()
        XCTAssertNil(lone.hexMirroredSelection())
    }

    // MARK: - Scroll extent over the longer file (§9)

    /// Scrolling is synchronized by absolute offset, so a pane must be able to
    /// reach the longer file's end even when its own file stopped much earlier —
    /// otherwise the shorter pane hits the bottom of its own document and the
    /// two panes drift apart.
    func testScrollExtentSpansTheLongerFile() throws {
        let pair = try openPair([UInt8](repeating: 0x41, count: 8_000),
                                [UInt8](repeating: 0x42, count: 64))
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        XCTAssertEqual(pair.0.fileSize, 8_000)
        XCTAssertEqual(pair.1.fileSize, 64)
        XCTAssertEqual(pair.0.scrollExtent, 8_000, "the longer pane spans its own file")
        XCTAssertEqual(pair.1.scrollExtent, 8_000,
                       "the shorter pane spans the comparison's extent, not its own 64 bytes")
    }

    /// The extent follows the companion: growing the longer file extends the
    /// shorter pane's reach, and losing the companion collapses it back.
    func testScrollExtentFollowsTheCompanion() throws {
        let pair = try openPair([UInt8](repeating: 0x41, count: 64),
                                [UInt8](repeating: 0x42, count: 64))
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        XCTAssertEqual(pair.1.scrollExtent, 64, "equal lengths: nothing to extend")

        pair.0.moveCaret(to: 64)
        pair.0.typeASCII(0x5A)   // appends one byte past EOF
        XCTAssertEqual(pair.0.fileSize, 65)
        XCTAssertEqual(pair.1.scrollExtent, 65,
                       "the shorter pane now has to reach the companion's new end")

        pair.1.companion = nil
        XCTAssertEqual(pair.1.scrollExtent, 64, "no companion, no extension")
    }

}
