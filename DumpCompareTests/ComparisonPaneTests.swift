import DumpCompareCore
import XCTest
@testable import DumpCompare

/// M5 tests for the pane's comparison-mode behaviors: live visible diff against
/// the companion (§8.3 rule 6: background state, EOF-only highlighting) and
/// caret/selection synchronization by absolute offset (§9).
@MainActor
final class ComparisonPaneTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("comp-pane-test-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

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

    func testEqualBytesAreSameEqualLengths() throws {
        let pair = try openPair([0x41, 0x42, 0x43], [0x41, 0x42, 0x43])
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        let states = pair.0.hexByteStates(in: 0..<3)
        XCTAssertEqual(states.map(\.isDifferent), [false, false, false])
    }

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

    func testShorterPaneShowsEOFPlaceholdersNotDiffs() throws {
        let pair = try openPair([0x41, 0x42], [0x41, 0x42, 0x43])
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        // Present bytes match; past EOF is a placeholder, not a difference.
        let states = pair.0.hexByteStates(in: 0..<4)
        XCTAssertEqual(states.map(\.isDifferent), [false, false, false, false])
        XCTAssertEqual(states.map(\.isEOF), [false, false, true, true])
    }

    func testLongerPaneHighlightsEOFOnlyBytes() throws {
        let pair = try openPair([0x41, 0x42], [0x41, 0x42, 0x43])
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        // Bytes 0-1 match; byte 2 exists only here → EOF-only difference.
        let states = pair.1.hexByteStates(in: 0..<3)
        XCTAssertEqual(states.map(\.isDifferent), [false, false, true])
        XCTAssertEqual(states.map(\.isEOF), [false, false, false])
        XCTAssertEqual(states[2].byte, 0x43)
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

    /// Each pane mirrors the companion's selection (clamped to its own file
    /// size) through `hexMirroredSelection`; the panes' own selections stay
    /// independent.
    func testMirrorReflectsCompanionSelection() throws {
        let pair = try openPair(Array(repeating: 0x00, count: 10), Array(repeating: 0x00, count: 20))
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        pair.0.setSelection(SelectionModel(start: 3, end: 7, fileSize: 10))
        XCTAssertEqual(pair.1.hexMirroredSelection(), SelectionModel(start: 3, end: 7, fileSize: 20))
        // …and the mirror is symmetric.
        XCTAssertEqual(pair.0.hexMirroredSelection(), pair.1.hexSelection().clamped(to: 10))
    }

    func testMirrorClampsToShorterPane() throws {
        let pair = try openPair(Array(repeating: 0x00, count: 10), Array(repeating: 0x00, count: 20))
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        pair.1.setSelection(SelectionModel(start: 5, end: 15, fileSize: 20))
        // The longer pane's selection (5…15) mirrors into the shorter pane
        // clamped to its EOF.
        XCTAssertEqual(pair.0.hexMirroredSelection(), SelectionModel(start: 5, end: 10, fileSize: 10))
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

    /// Without a companion there is nothing to synchronize with, so the extent is
    /// the pane's own file.
    func testScrollExtentIsTheFileInSingleFileMode() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 100))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        XCTAssertEqual(pane.scrollExtent, 100)
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
