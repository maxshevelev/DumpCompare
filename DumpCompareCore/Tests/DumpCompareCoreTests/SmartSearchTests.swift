import XCTest
@testable import DumpCompareCore

/// §11 Smart Search: what gets tried, and in what order. Pure — no window, no
/// file — because the order *is* the feature: a reader who knows the string
/// and not its encoding gets the right answer only if the guesses are made in
/// the right sequence.
final class SmartSearchTests: XCTestCase {

    // MARK: - Does this look like hex?

    /// The question is not "could the parser read this as hex" but "does this
    /// look like it was meant as hex", so the test is the shape a hex dump
    /// prints: an even run of digits, or those digits in pairs.
    func testHexLooksLikeHex() {
        XCTAssertTrue(SmartSearch.looksLikeHexBytes("DEADBEEF"))
        XCTAssertTrue(SmartSearch.looksLikeHexBytes("DE AD BE EF"))
        XCTAssertTrue(SmartSearch.looksLikeHexBytes("deadbeef"), "case is not the question")
        XCTAssertTrue(SmartSearch.looksLikeHexBytes("00"))
        XCTAssertTrue(SmartSearch.looksLikeHexBytes("  DE AD  "), "trimmed at the ends")
    }

    func testAnythingElseIsText() {
        XCTAssertFalse(SmartSearch.looksLikeHexBytes("DEA"), "an odd run of digits")
        XCTAssertFalse(SmartSearch.looksLikeHexBytes("DEAD BEEF"),
                       "grouped in fours — a reader who means bytes writes pairs")
        XCTAssertFalse(SmartSearch.looksLikeHexBytes("DE AD B"), "a stray digit")
        XCTAssertFalse(SmartSearch.looksLikeHexBytes("hello"))
        XCTAssertFalse(SmartSearch.looksLikeHexBytes("cafe babe"), "even a hex-ish word")
        XCTAssertFalse(SmartSearch.looksLikeHexBytes(""))
        XCTAssertFalse(SmartSearch.looksLikeHexBytes("   "))
    }

    // MARK: - The order

    /// A pattern that reads as hex is looked for as bytes first — that is what
    /// it says on the tin — and as text afterwards, in case it was a word all
    /// along (`cafe` is both).
    func testHexIsTriedFirstForAHexPattern() {
        let attempts = SmartSearch.attempts(for: "DEAD", caseSensitive: false)
        XCTAssertEqual(attempts.first?.encoding, .hex)
        XCTAssertEqual(attempts.first?.pattern.bytes, [0xDE, 0xAD])
        XCTAssertEqual(attempts.first?.encodings, [.hex])
        XCTAssertEqual(attempts.first?.folding, .exact, "bytes have no case")
        XCTAssertTrue(attempts.dropFirst().allSatisfy { $0.encoding != .hex },
                      "and hex is tried once")
    }

    /// Text is tried ASCII first, then the UTF-16 pair — and never as hex,
    /// because it does not look like hex.
    func testATextPatternIsNeverTriedAsHex() {
        let attempts = SmartSearch.attempts(for: "boot", caseSensitive: false)
        XCTAssertTrue(attempts.allSatisfy { $0.encoding != .hex })
        XCTAssertEqual(attempts.map(\.encoding), [.ascii, .utf16LE, .utf16BE],
                       "UTF-8 asks the same question as ASCII here, so it is not asked twice")
        XCTAssertEqual(attempts[0].pattern.bytes, Array("boot".utf8))
        XCTAssertEqual(attempts[1].pattern.bytes, [0x62, 0, 0x6F, 0, 0x6F, 0, 0x74, 0])
        XCTAssertEqual(attempts[2].pattern.bytes, [0, 0x62, 0, 0x6F, 0, 0x6F, 0, 0x74])
    }

    /// One scan per *question*, not per encoding: `boot` as ASCII and as UTF-8
    /// is the same four bytes compared the same way, and scanning a dump twice
    /// for them would be twice the wait for one answer. The attempt is named
    /// for both, so the notice tells the truth about what was tried.
    func testEncodingsThatAskTheSameQuestionAreOneAttempt() {
        let attempts = SmartSearch.attempts(for: "boot", caseSensitive: false)
        XCTAssertEqual(attempts.first?.encodings, [.ascii, .utf8])
        XCTAssertEqual(attempts.first?.encoding, .ascii,
                       "and the narrower claim is the one the field adopts")
    }

    /// Text no ASCII byte can carry is still tried in the encodings that can.
    func testAnEncodingThatCannotCarryTheTextIsLeftOut() {
        let attempts = SmartSearch.attempts(for: "ключ", caseSensitive: false)
        XCTAssertEqual(attempts.map(\.encoding), [.utf8, .utf16LE, .utf16BE],
                       "ASCII cannot encode it, so there is nothing to look for")
        XCTAssertEqual(attempts.first?.encodings, [.utf8])
    }

    /// The case flag is part of each attempt, because it is part of the
    /// question: the same bytes compared exactly and compared folded are two
    /// different searches, and a fold that models one encoding does not model
    /// another (§11).
    func testTheCaseFlagRidesWithEachAttempt() {
        let folded = SmartSearch.attempts(for: "boot", caseSensitive: false)
        XCTAssertEqual(folded.map(\.folding),
                       [.asciiBytes, .utf16(littleEndian: true), .utf16(littleEndian: false)])

        let exact = SmartSearch.attempts(for: "boot", caseSensitive: true)
        XCTAssertEqual(exact.map(\.folding), [.exact, .exact, .exact])
        XCTAssertNotEqual(folded, exact, "so the two are not the same pass")
    }

    /// Nothing to look for is not a list of nothing to look for: an empty field
    /// yields no attempts at all, which is the caller's cue that there is no
    /// pattern rather than a bad one. Spaces are not nothing, though — three of
    /// them are three bytes a dump may well hold.
    func testAnEmptyFieldYieldsNoAttempts() {
        XCTAssertTrue(SmartSearch.attempts(for: "", caseSensitive: false).isEmpty)
        XCTAssertEqual(SmartSearch.attempts(for: "   ", caseSensitive: false).first?.pattern.bytes,
                       [0x20, 0x20, 0x20])
    }

    // MARK: - The pass

    /// The pass is the feature, not just the order: each attempt is the two
    /// scans a plain search runs — from the anchor, then from the file's other
    /// end — so "this encoding finds nothing" means nothing *anywhere*, and
    /// only then does the next encoding get a turn.
    func testThePassAdoptsTheFirstEncodingThatFindsAnything() throws {
        // "boot" as UTF-16LE, and nowhere as ASCII.
        var bytes = [UInt8](repeating: 0xFF, count: 64)
        bytes.replaceSubrange(16..<24, with: [0x62, 0, 0x6F, 0, 0x6F, 0, 0x74, 0])
        let storage = ArrayStorage(bytes)
        let attempts = SmartSearch.attempts(for: "boot", caseSensitive: false)

        let outcome = try SmartSearch.firstMatch(among: attempts, in: storage, from: 0)

        guard case .found(let attempt, let range, let wrapped) = outcome else {
            return XCTFail("the string is in the file, in one of the encodings")
        }
        XCTAssertEqual(attempt.encoding, .utf16LE)
        XCTAssertEqual(range, 16..<24)
        XCTAssertFalse(wrapped, "found ahead of the anchor")
    }

    /// A match behind the anchor is still a match: each attempt wraps before
    /// the pass gives up on its encoding, or the encodings would be ruled out
    /// by where the caret happens to be.
    func testAnAttemptWrapsBeforeTheNextEncodingIsTried() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 64)
        bytes.replaceSubrange(4..<8, with: Array("boot".utf8))
        let storage = ArrayStorage(bytes)
        let attempts = SmartSearch.attempts(for: "boot", caseSensitive: false)

        let outcome = try SmartSearch.firstMatch(among: attempts, in: storage, from: 40)

        XCTAssertEqual(outcome, .found(attempt: attempts[0], range: 4..<8, wrapped: true),
                       "ASCII finds it behind the anchor rather than losing to UTF-16, "
                           + "and says that it had to wrap for it")
    }

    /// Nothing in any encoding is its own answer, and the caller needs the list
    /// it tried to say so.
    func testAPassThatFindsNothingSaysSo() throws {
        let storage = ArrayStorage([UInt8](repeating: 0xFF, count: 64))
        let attempts = SmartSearch.attempts(for: "boot", caseSensitive: false)

        XCTAssertEqual(try SmartSearch.firstMatch(among: attempts, in: storage, from: 0),
                       .nothing)
    }

    /// The whole pass is one progress: every attempt owns its share, so the bar
    /// advances through a run of failed encodings instead of restarting at each.
    func testProgressCoversTheWholePass() throws {
        let storage = ArrayStorage([UInt8](repeating: 0xFF, count: 4096))
        let attempts = SmartSearch.attempts(for: "boot", caseSensitive: false)
        var reported: [Double] = []

        _ = try SmartSearch.firstMatch(among: attempts, in: storage, from: 0, chunkSize: 512,
                                       progress: { reported.append($0) })

        XCTAssertFalse(reported.isEmpty)
        XCTAssertEqual(reported, reported.sorted(), "and it never goes backwards")
        XCTAssertEqual(try XCTUnwrap(reported.last), 1, accuracy: 0.001,
                       "a finished pass is a finished bar")
        XCTAssertTrue(reported.contains { $0 > 0.3 && $0 < 0.7 },
                      "the middle of the pass is the middle of the bar")
    }

    /// Cancelling stops the pass where it is: several scans of a file is a wait
    /// worth being able to stop.
    func testCancellingStopsThePass() {
        let storage = ArrayStorage([UInt8](repeating: 0xFF, count: 4096))
        let attempts = SmartSearch.attempts(for: "boot", caseSensitive: false)
        var scans = 0

        XCTAssertThrowsError(
            try SmartSearch.firstMatch(among: attempts, in: storage, from: 0, chunkSize: 512,
                                       shouldCancel: { scans += 1; return scans > 2 })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
}
