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

    // MARK: - Selection sync (§9)

    func testCaretSyncsToCompanion() throws {
        let pair = try openPair(Array(repeating: 0x00, count: 10), Array(repeating: 0x00, count: 20))
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        pair.0.moveCaret(to: 7)
        XCTAssertEqual(pair.0.caretOffset, 7)
        XCTAssertEqual(pair.1.caretOffset, 7)
    }

    func testSelectionSyncClampsToShorterPane() throws {
        let pair = try openPair(Array(repeating: 0x00, count: 10), Array(repeating: 0x00, count: 20))
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        pair.1.moveCaret(to: 15)
        // The longer pane's caret lives at 15 (within its own 20 bytes)…
        XCTAssertEqual(pair.1.caretOffset, 15)
        // …and syncs into the shorter pane clamped to its EOF.
        XCTAssertEqual(pair.0.caretOffset, 10)
    }

    func testNoInfiniteSyncLoop() throws {
        let pair = try openPair(Array(repeating: 0x00, count: 5), Array(repeating: 0x00, count: 5))
        defer {
            try? FileManager.default.removeItem(at: pair.2)
            try? FileManager.default.removeItem(at: pair.3)
        }
        // Moving either caret must not bounce between panes forever.
        pair.0.moveCaret(to: 3)
        XCTAssertEqual(pair.1.caretOffset, 3)
        pair.1.moveCaret(to: 1)
        XCTAssertEqual(pair.0.caretOffset, 1)
        XCTAssertEqual(pair.1.caretOffset, 1)
    }
}
