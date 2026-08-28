import XCTest
@testable import DumpCompareCore

final class SearchEngineTests: XCTestCase {
    private func parse(_ text: String, _ encoding: SearchEncoding) throws -> [UInt8] {
        try SearchEngine.parsePattern(text, encoding: encoding).bytes
    }

    private func find(_ pattern: [UInt8], in bytes: [UInt8], from: UInt64 = 0,
                      direction: SearchDirection = .forward, chunkSize: Int = 7) throws -> Range<UInt64>? {
        try SearchEngine.find(pattern: pattern, in: ArrayStorage(bytes), from: from,
                              direction: direction, chunkSize: chunkSize)
    }

    // MARK: - Pattern parsing

    func testParseHexVariants() throws {
        XCTAssertEqual(try parse("DEADBEEF", .hex), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try parse("DE AD BE EF", .hex), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try parse("0xDE 0xAD", .hex), [0xDE, 0xAD])
        XCTAssertEqual(try parse("deadbeef", .hex), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try parse("ff", .hex), [0xFF])
        XCTAssertEqual(try parse("00", .hex), [0x00])
    }

    func testParseHexInvalid() {
        let bad = ["", "  ", "0x", "0X", "DEADBEE", "XYZ", "12G", "0x1G", "DE 0x", "abcde"]
        for text in bad {
            XCTAssertThrowsError(try parse(text, .hex), text) { error in
                XCTAssertEqual(error as? SearchError, .invalidHexPattern, text)
            }
        }
    }

    func testParseAsciiAndUtf8() throws {
        XCTAssertEqual(try parse("Hello", .ascii), [0x48, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertThrowsError(try parse("é", .ascii)) { error in
            XCTAssertEqual(error as? SearchError, .undecodableText)
        }
        XCTAssertEqual(try parse("Hello", .utf8), [0x48, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertEqual(try parse("é", .utf8), [0xC3, 0xA9])
        XCTAssertThrowsError(try parse("", .utf8)) { error in
            XCTAssertEqual(error as? SearchError, .emptyPattern)
        }
    }

    func testParseUtf16() throws {
        // "A" = 0x0041; "é" = 0x00E9.
        XCTAssertEqual(try parse("A", .utf16LE), [0x41, 0x00])
        XCTAssertEqual(try parse("A", .utf16BE), [0x00, 0x41])
        XCTAssertEqual(try parse("é", .utf16LE), [0xE9, 0x00])
        XCTAssertEqual(try parse("é", .utf16BE), [0x00, 0xE9])
    }

    func testEmptyPatternThrows() {
        XCTAssertThrowsError(try SearchEngine.find(pattern: [], in: ArrayStorage([1, 2, 3]))) { error in
            XCTAssertEqual(error as? SearchError, .emptyPattern)
        }
    }

    // MARK: - Find

    func testFindAtStartMiddleEnd() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xDE, 0xAD]
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 0), 0..<2)
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 1), 5..<7)
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 5), 5..<7)
        XCTAssertNil(try find([0xDE, 0xAD], in: bytes, from: 6))
        XCTAssertEqual(try find([0xBE, 0xEF], in: bytes, from: 0), 2..<4)
    }

    /// The edges of `find`: nothing to find, nothing that could fit, a
    /// one-byte pattern (the shortest window there is), and a match ending
    /// exactly at EOF.
    func testFindEdges() throws {
        let cases: [(name: String, pattern: [UInt8], bytes: [UInt8], from: UInt64,
                     direction: SearchDirection, expected: Range<UInt64>?)] = [
            ("no match, forward", [0xAA, 0xBB], [0x00, 0x01, 0x02], 0, .forward, nil),
            ("no match, backward from EOF", [0xAA, 0xBB], [0x00, 0x01, 0x02], 3, .backward, nil),
            ("no match for a single byte", [0x05], [0x00, 0x01, 0x02], 0, .forward, nil),
            ("a pattern longer than the file", [0x00, 0x01, 0x02, 0x03], [0x00, 0x01], 0, .forward, nil),
            ("a single byte at the start", [0xAA], [0xAA, 0x00, 0xAA, 0x00], 0, .forward, 0..<1),
            ("a single byte past the first match", [0xAA], [0xAA, 0x00, 0xAA, 0x00], 1, .forward, 2..<3),
            ("a match ending at EOF", [0xAA, 0xBB], [0x00, 0x01, 0xAA, 0xBB], 0, .forward, 2..<4),
            ("the last byte of the file", [0xBB], [0x00, 0x01, 0xAA, 0xBB], 0, .forward, 3..<4),
        ]
        for testCase in cases {
            XCTAssertEqual(try find(testCase.pattern, in: testCase.bytes, from: testCase.from,
                                    direction: testCase.direction),
                           testCase.expected, testCase.name)
        }
    }

    func testFindBackward() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xDE, 0xAD]
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 7, direction: .backward), 5..<7)
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 5, direction: .backward), 0..<2)
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 4, direction: .backward), 0..<2)
        // A caret at 0 has nothing before it, so there is no previous match.
        XCTAssertNil(try find([0xDE, 0xAD], in: bytes, from: 0, direction: .backward))

        // A one-byte pattern: the shortest window, where the overlap arithmetic
        // that walks backward has nothing to spare.
        let single: [UInt8] = [0xAA, 0x00, 0xAA, 0x00]
        XCTAssertEqual(try find([0xAA], in: single, from: 4, direction: .backward), 2..<3)
        XCTAssertEqual(try find([0xAA], in: single, from: 1, direction: .backward), 0..<1)
        XCTAssertNil(try find([0xAA], in: single, from: 0, direction: .backward))
    }

    func testFindBackwardExcludesMatchStartingAtCaret() throws {
        // [AA] at index 4 starts exactly at the caret; it must NOT be returned.
        // Otherwise Find Previous from a caret sitting on a match would re-find
        // that same match instead of moving backward.
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA, 0x00, 0xAA]
        XCTAssertEqual(try find([0xAA], in: bytes, from: 4, direction: .backward), 2..<3)
    }

    func testFindAcrossChunkBoundary() throws {
        // Chunk size 3; pattern straddles offsets 2..<5 (boundary at 3).
        let bytes: [UInt8] = [0x00, 0x01, 0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x00]
        XCTAssertEqual(try find([0xAA, 0xBB, 0xCC], in: bytes, chunkSize: 3), 2..<5)
        // Backward search across the same boundary.
        XCTAssertEqual(try find([0xAA, 0xBB, 0xCC], in: bytes, from: 8, direction: .backward, chunkSize: 3), 2..<5)
    }

    func testFindUsesCurrentUnsavedContent() throws {
        let base = ArrayStorage([0xAA, 0x00, 0x00, 0x00])
        let storage = EditOverlayStorage(base: base)
        try storage.overwrite(range: 1..<2, with: [0xBB])

        XCTAssertEqual(try SearchEngine.find(pattern: [0xBB], in: storage), 1..<2)
        XCTAssertEqual(try SearchEngine.find(pattern: [0x00, 0x00], in: storage), 2..<4)
        XCTAssertNil(try SearchEngine.find(pattern: [0x00, 0x00], in: storage, from: 3))
        XCTAssertEqual(try SearchEngine.find(pattern: [0xAA], in: storage), 0..<1)
    }

    func testFindCancellationThrows() throws {
        XCTAssertThrowsError(try SearchEngine.find(
            pattern: [0xAA], in: ArrayStorage([UInt8](repeating: 0, count: 32)),
            chunkSize: 4,
            shouldCancel: { true }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Case-insensitive find (§11)

    private func findCI(_ pattern: [UInt8], in bytes: [UInt8], from: UInt64 = 0,
                        direction: SearchDirection = .forward, chunkSize: Int = 7,
                        caseSensitive: Bool = false) throws -> Range<UInt64>? {
        try SearchEngine.find(pattern: pattern, in: ArrayStorage(bytes), from: from,
                              direction: direction, caseSensitive: caseSensitive,
                              chunkSize: chunkSize)
    }

    func testFindCaseInsensitiveAscii() throws {
        // "Hi there" — pattern "HI" matches the lowercase 'i' at 0..<2.
        let bytes = Array("Hi there".utf8)
        XCTAssertEqual(try findCI(Array("HI".utf8), in: bytes), 0..<2)
        XCTAssertEqual(try findCI(Array("hi".utf8), in: bytes), 0..<2)
        XCTAssertEqual(try findCI(Array("THE".utf8), in: bytes), 3..<6)
        // Case-sensitive is exact: uppercase "HI" does not match "Hi".
        XCTAssertNil(try findCI(Array("HI".utf8), in: bytes, caseSensitive: true))
        XCTAssertEqual(try findCI(Array("Hi".utf8), in: bytes, caseSensitive: true), 0..<2)
    }

    func testFindCaseInsensitiveUtf8() throws {
        // "Café" = C a f é (5 bytes). The ASCII 'C' folds to 'c', so a lowercase
        // pattern matches; but É (0xC3 0x89) never folds to é (0xC3 0xA9), so a
        // case-swapped pattern with the accent does not.
        let bytes = Array("Café".utf8)
        XCTAssertEqual(try findCI(Array("café".utf8), in: bytes), 0..<5)
        // Case-sensitive: only the exact bytes match ("Café"), not "café" or "CAFÉ".
        XCTAssertEqual(try findCI(Array("Café".utf8), in: bytes, caseSensitive: true), 0..<5)
        XCTAssertNil(try findCI(Array("café".utf8), in: bytes, caseSensitive: true))
        XCTAssertNil(try findCI(Array("CAFÉ".utf8), in: bytes))
        XCTAssertNil(try findCI(Array("CAFÉ".utf8), in: bytes, caseSensitive: true))
    }

    func testFindCaseInsensitiveUtf16() throws {
        let bytes = Array("Hi there".data(using: .utf16LittleEndian)!)
        // "HI" UTF-16LE = 48 00 49 00; folds 'I' against the 'i' in "Hi".
        XCTAssertEqual(try findCI(Array("HI".data(using: .utf16LittleEndian)!), in: bytes), 0..<4)
        XCTAssertNil(try findCI(Array("HI".data(using: .utf16LittleEndian)!), in: bytes, caseSensitive: true))
    }

    func testFindCaseInsensitiveBackward() throws {
        let bytes = Array("ab AB ab".utf8)
        // Last case-insensitive "ab" is at 6..<8; a case-sensitive search from
        // the end still finds the exact "ab" at 6..<8, and the earlier "AB"
        // (3..<5) is only reachable case-insensitively.
        XCTAssertEqual(try findCI(Array("AB".utf8), in: bytes, from: 8, direction: .backward), 6..<8)
        XCTAssertEqual(try findCI(Array("ab".utf8), in: bytes, from: 5, direction: .backward, caseSensitive: true), 0..<2)
        XCTAssertEqual(try findCI(Array("AB".utf8), in: bytes, from: 8, direction: .backward, caseSensitive: false), 6..<8)
        // Case-insensitive backward from the end must skip the exact "ab" and
        // land on "AB" when asked to go earlier.
        XCTAssertEqual(try findCI(Array("ab".utf8), in: bytes, from: 6, direction: .backward), 3..<5)
    }

    func testFindCaseInsensitiveAcrossChunkBoundary() throws {
        // Chunk size 3; "AbC" straddles offsets 2..<5 (boundary at 3) and is
        // matched by lowercase "abc" across the boundary.
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.replaceSubrange(2..<5, with: Array("AbC".utf8))
        XCTAssertEqual(try findCI(Array("abc".utf8), in: bytes, chunkSize: 3), 2..<5)
        XCTAssertEqual(try findCI(Array("abc".utf8), in: bytes, from: 8, direction: .backward, chunkSize: 3), 2..<5)
    }

    func testFindExactSearchDistinguishesRawBytes() throws {
        // Case-sensitivity lives in the byte domain: folding only rewrites ASCII
        // letters, so an exact (case-sensitive) search treats 0x41 'A' and
        // 0x61 'a' as different bytes. The Find bar keeps this for hex patterns
        // (its Aa toggle is disabled when the encoding is hex).
        let bytes: [UInt8] = [0x41, 0x62, 0x63]
        XCTAssertEqual(try findCI([0x41, 0x62, 0x63], in: bytes, caseSensitive: true), 0..<3)
        XCTAssertNil(try findCI([0x61, 0x62, 0x63], in: bytes, caseSensitive: true))
    }

    // MARK: - Find All (§11)

    private func findAll(_ pattern: [UInt8], in bytes: [UInt8], chunkSize: Int = 7,
                         caseSensitive: Bool = true) throws -> [Range<UInt64>] {
        try SearchEngine.findAll(pattern: pattern, in: ArrayStorage(bytes),
                                 caseSensitive: caseSensitive, chunkSize: chunkSize)
    }

    func testFindAllFindsEveryOccurrence() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0x00, 0xDE, 0xAD, 0xBE, 0xDE, 0xAD]
        XCTAssertEqual(try findAll([0xDE, 0xAD], in: bytes), [0..<2, 4..<6, 7..<9])
        XCTAssertEqual(try findAll([0xBE], in: bytes), [2..<3, 6..<7])
    }

    /// The same edges for `findAll`, whose answer is a list rather than one
    /// range: every byte matching, nothing matching, nothing that could fit, and
    /// a match ending exactly at EOF.
    func testFindAllEdges() throws {
        let cases: [(name: String, pattern: [UInt8], bytes: [UInt8], expected: [Range<UInt64>])] = [
            ("a single byte matching every byte", [0xAA], [0xAA, 0xAA, 0xAA], [0..<1, 1..<2, 2..<3]),
            ("no match", [0xAA, 0xBB], [0x00, 0x01, 0x02], []),
            ("a pattern longer than the file", [0x00, 0x01, 0x02, 0x03], [0x00, 0x01], []),
            ("a match ending at EOF", [0xAA, 0xBB], [0x00, 0x01, 0xAA, 0xBB], [2..<4]),
        ]
        for testCase in cases {
            XCTAssertEqual(try findAll(testCase.pattern, in: testCase.bytes), testCase.expected,
                           testCase.name)
        }
    }

    /// Consecutive matches never overlap: after a match the scan resumes just
    /// past its end, so "AAAAAA" with pattern "AAA" yields 0..<3 and 3..<6 —
    /// the overlapping starts at 1 and 2 are skipped.
    func testFindAllNonOverlapping() throws {
        let bytes: [UInt8] = [0x41, 0x41, 0x41, 0x41, 0x41, 0x41]  // "AAAAAA"
        XCTAssertEqual(try findAll([0x41, 0x41, 0x41], in: bytes), [0..<3, 3..<6])
    }

    func testFindAllAcrossChunkBoundary() throws {
        // Chunk size 3; the match straddles offset 2..<5 (boundary at 3).
        let bytes: [UInt8] = [0x00, 0x01, 0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x00]
        XCTAssertEqual(try findAll([0xAA, 0xBB, 0xCC], in: bytes, chunkSize: 3), [2..<5])
    }

    /// Matches spanning several chunk boundaries, some ending exactly at a
    /// boundary — the overlap must neither drop nor double-count a match.
    func testFindAllAcrossMultipleChunkBoundaries() throws {
        let bytes: [UInt8] = [0xAA, 0xBB, 0xAA, 0xBB, 0xAA, 0xBB, 0xAA, 0xBB]
        XCTAssertEqual(try findAll([0xAA, 0xBB], in: bytes, chunkSize: 3),
                       [0..<2, 2..<4, 4..<6, 6..<8])
    }

    /// A match starting exactly at a chunk boundary is found once, by the
    /// window that owns the fresh portion the boundary opens — never twice.
    func testFindAllMatchAtChunkBoundaryIsCountedOnce() throws {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0x00]
        XCTAssertEqual(try findAll([0xAA, 0xBB], in: bytes, chunkSize: 4), [4..<6])
    }

    func testFindAllCaseInsensitive() throws {
        let bytes = Array("Hi hi HI".utf8)  // "Hi" at 0, "hi" at 3, "HI" at 6
        XCTAssertEqual(try findAll(Array("hi".utf8), in: bytes, caseSensitive: false),
                       [0..<2, 3..<5, 6..<8])
        // Case-sensitive finds only the exact lowercase pair.
        XCTAssertEqual(try findAll(Array("hi".utf8), in: bytes, caseSensitive: true), [3..<5])
    }

    func testFindAllAcrossChunkBoundaryCaseInsensitive() throws {
        // Chunk size 3; "AbC" straddles offsets 2..<5 and matches "abc".
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.replaceSubrange(2..<5, with: Array("AbC".utf8))
        XCTAssertEqual(try findAll(Array("abc".utf8), in: bytes, chunkSize: 3, caseSensitive: false), [2..<5])
    }

    func testFindAllUsesCurrentUnsavedContent() throws {
        let base = ArrayStorage([0xAA, 0x00, 0xAA, 0x00])
        let storage = EditOverlayStorage(base: base)
        try storage.overwrite(range: 1..<2, with: [0xAA])
        // After the edit the file is AA AA AA 00: every single-byte match at
        // 0, 1, and 2 is reported (adjacent, never overlapping).
        XCTAssertEqual(try SearchEngine.findAll(pattern: [0xAA], in: storage),
                       [0..<1, 1..<2, 2..<3])
    }

    func testFindAllCancellationThrows() throws {
        XCTAssertThrowsError(try SearchEngine.findAll(
            pattern: [0xAA], in: ArrayStorage([UInt8](repeating: 0, count: 32)),
            chunkSize: 4,
            shouldCancel: { true }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testFindAllReportsProgress() throws {
        var last: Double = -1
        let result = try SearchEngine.findAll(
            pattern: [0xFF], in: ArrayStorage([UInt8](repeating: 0, count: 16)),
            chunkSize: 4,
            progress: { last = $0 }
        )
        XCTAssertEqual(result, [])
        XCTAssertEqual(last, 1.0)
    }

    func testFindAllEmptyPatternThrows() {
        XCTAssertThrowsError(try SearchEngine.findAll(pattern: [], in: ArrayStorage([1, 2, 3]))) { error in
            XCTAssertEqual(error as? SearchError, .emptyPattern)
        }
    }

    // MARK: - findAllStream

    /// The streaming API yields the same matches as `findAll`, one `Range` per
    /// occurrence and in file order, so a caller can add a result row the moment
    /// each match is found — not only once the scan completes.
    func testFindAllStreamYieldsEachMatchLive() async throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0x00, 0xDE, 0xAD, 0xBE, 0xDE, 0xAD]
        let expected: [Range<UInt64>] = [0..<2, 4..<6, 7..<9]
        let stream = SearchEngine.findAllStream(pattern: [0xDE, 0xAD], in: ArrayStorage(bytes))

        var all: [Range<UInt64>] = []
        for try await match in stream { all.append(match) }
        XCTAssertEqual(all, expected, "each match is delivered individually, in file order")
    }

    func testFindAllStreamEmptyPatternThrows() async {
        let stream = SearchEngine.findAllStream(pattern: [], in: ArrayStorage([1, 2, 3]))
        do {
            for try await _ in stream {}
            XCTFail("an empty pattern must fail the stream")
        } catch {
            XCTAssertEqual(error as? SearchError, .emptyPattern)
        }
    }

    /// A `shouldCancel` stop is not an error: matches found before the stop are
    /// delivered, the stream finishes normally, and the scan never covers the
    /// rest of the file.
    func testFindAllStreamStopsMidScanOnShouldCancel() async throws {
        let counter = CancellationCounter()
        let stream = SearchEngine.findAllStream(
            pattern: [0xAA], in: ArrayStorage([UInt8](repeating: 0xAA, count: 16)),
            chunkSize: 4,
            shouldCancel: { counter.bump() > 1 })

        var received: [Range<UInt64>] = []
        do {
            for try await match in stream { received.append(match) }
        } catch {
            XCTFail("a shouldCancel stop must finish the stream normally, got \(error)")
        }
        XCTAssertEqual(received, [0..<1, 1..<2, 2..<3, 3..<4],
                       "the matches found before the stop are delivered, the rest are not")
    }

    /// Cancelling the task iterating the stream ends the loop well short of the
    /// full result — the app's × button and a newer Search All both rely on
    /// this. Note that on this platform a cancelled task's `next()` returns
    /// `nil` (a normal end) rather than throwing `CancellationError`; the caller
    /// distinguishes the two itself (the app checks `Task.isCancelled` after the
    /// loop). Here we assert the loop actually ends before the scan could
    /// possibly finish.
    func testFindAllStreamCancellationStopsIteration() async throws {
        // Every byte matches, and the storage parks the scan inside its second
        // read: only the first chunk's matches can ever have been yielded when
        // the cancel lands, so "some arrived" and "not all of them" are both
        // facts rather than a bet on how fast the scan runs. `maxResults` is the
        // whole file so the cap cannot end the scan before the cancel does.
        let chunkSize = 64
        let total = chunkSize * 8
        let storage = GatedStorage(size: UInt64(total), byte: 0xAA, parkAtRead: 2)
        let stream = SearchEngine.findAllStream(pattern: [0xAA], in: storage,
                                                chunkSize: chunkSize, maxResults: total)

        let firstMatch = expectation(description: "the first match reached the consumer")
        let task = Task { () -> Int in
            var iterator = stream.makeAsyncIterator()
            var count = 0
            if let first = try await iterator.next() {
                XCTAssertEqual(first, 0..<1, "matches arrive in file order")
                count += 1
                firstMatch.fulfill()
            }
            while try await iterator.next() != nil { count += 1 }
            return count
        }
        await fulfillment(of: [firstMatch], timeout: 5)

        task.cancel()
        let count = try await task.value
        storage.release()   // let the parked scan thread go

        XCTAssertGreaterThan(count, 0, "the matches that arrived before the cancel are kept")
        XCTAssertLessThanOrEqual(count, chunkSize,
                                 "the scan is parked after one chunk, so it cannot have yielded more")
        XCTAssertLessThan(count, total,
                          "cancelling the consumer stops the iteration short of the full result")
    }

    /// A Search All stops once the match cap is reached: the stream delivers the
    /// first `maxResults` matches and finishes normally (no error), and because
    /// the scan stops early it must not report full progress.
    func testFindAllStreamStopsAtMaxResults() async throws {
        // 4 KiB of matching bytes: the cap is hit inside the first 64-byte
        // chunk, well before the file is covered.
        let bytes = [UInt8](repeating: 0xAA, count: 4096)
        let sawFullProgress = Flag()
        let stream = SearchEngine.findAllStream(
            pattern: [0xAA], in: ArrayStorage(bytes), chunkSize: 64, maxResults: 3,
            progress: { if $0 >= 1 { sawFullProgress.set() } })

        var all: [Range<UInt64>] = []
        do {
            for try await match in stream { all.append(match) }
        } catch {
            XCTFail("a capped scan must finish the stream normally, got \(error)")
        }
        XCTAssertEqual(all, [0..<1, 1..<2, 2..<3],
                       "the first maxResults matches are delivered, then the scan stops")
        XCTAssertFalse(sawFullProgress.value,
                       "a scan stopped by the cap must not report full coverage")
    }
}

/// A thread-safe counter for driving `shouldCancel` in tests: the closure runs
/// on the scan's detached task, so a plain captured `var` would not compile
/// cleanly.
private final class CancellationCounter: @unchecked Sendable {
    private var value = 0
    func bump() -> Int {
        value += 1
        return value
    }
}

/// A thread-safe one-shot boolean for assertions from `progress` closures,
/// which run on the scan's detached task (see `CancellationCounter`).
private final class Flag: @unchecked Sendable {
    private var _value = false
    var value: Bool { _value }
    func set() { _value = true }
}

/// The progress and folding contracts of `find` (§11). These three tests were
/// written inside `Flag` above — a plain class, not an `XCTestCase` — so XCTest
/// never discovered them and they had never run once. Backward progress had no
/// live coverage at all as a result.
extension SearchEngineTests {

    // MARK: - Progress contract (0...1)

    /// Windows overlap by `patternLength - 1`, so summing their lengths
    /// overshoots the file: the forward scan used to report up to 1.36.
    func testForwardProgressNeverExceedsOne() throws {
        let data = MemoryBackedStorage(bytes: [UInt8](repeating: 0x00, count: 100))
        var reported: [Double] = []
        _ = try SearchEngine.find(pattern: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF], in: data,
                                  chunkSize: 10, progress: { reported.append($0) })
        XCTAssertFalse(reported.isEmpty, "a multi-chunk scan reports progress")
        XCTAssertLessThanOrEqual(reported.max() ?? 0, 1.0, "progress stays within its contract")
        XCTAssertGreaterThanOrEqual(reported.min() ?? 1, 0.0)
        XCTAssertEqual(reported.last, 1.0, "a completed scan ends at 100 %")
    }

    /// A backward search covers `[0, caret)`, so its progress must be measured
    /// over that span. Measured against the whole file it opened at 91 % for a
    /// caret at 10 % and crawled to 100 %.
    func testBackwardProgressMeasuresTheSearchedSpan() throws {
        let data = MemoryBackedStorage(bytes: [UInt8](repeating: 0x00, count: 1000))
        var reported: [Double] = []
        _ = try SearchEngine.find(pattern: [0xFF], in: data, from: 100, direction: .backward,
                                  chunkSize: 10, progress: { reported.append($0) })
        XCTAssertFalse(reported.isEmpty)
        XCTAssertLessThan(reported.first ?? 1, 0.2,
                          "a scan that has just begun must not report near-completion")
        XCTAssertLessThanOrEqual(reported.max() ?? 0, 1.0)
        XCTAssertEqual(reported.last, 1.0, "and it still ends at 100 %")
    }

    // MARK: - Folding is chosen by the encoding (§11)

    /// The byte-wise fold is exactly that — bytes, wherever they sit. It models
    /// case for a single-byte ASCII-compatible encoding and for nothing else,
    /// which is why `CaseFolding` exists: a caller asks for the rule that fits
    /// its encoding instead of a bare Bool.
    func testTheByteWiseFoldIsByteLevel() throws {
        let data = MemoryBackedStorage(bytes: [0x41, 0x00])   // UTF-16BE U+4100
        // A UTF-16BE pattern for U+6100 is 61 00 — a different character.
        let pattern = try SearchEngine.parsePattern("\u{6100}", encoding: .utf16BE)
        XCTAssertEqual(pattern.bytes, [0x61, 0x00])

        XCTAssertNil(try SearchEngine.find(pattern: pattern.bytes, in: data, folding: .exact),
                     "exact matching keeps the two characters apart")
        XCTAssertNotNil(try SearchEngine.find(pattern: pattern.bytes, in: data, folding: .asciiBytes),
                        "the byte-wise fold cannot tell a code unit's high byte from a letter")
    }

    /// Hex is bytes, and bytes have no case: the rule for hex is exact whatever
    /// the user asked for.
    func testTheRuleForHexIsAlwaysExact() {
        XCTAssertEqual(CaseFolding(encoding: .hex, caseSensitive: false), .exact)
        XCTAssertEqual(CaseFolding(encoding: .hex, caseSensitive: true), .exact)
        XCTAssertEqual(CaseFolding(encoding: .ascii, caseSensitive: false), .asciiBytes)
        XCTAssertEqual(CaseFolding(encoding: .utf8, caseSensitive: false), .asciiBytes)
        XCTAssertEqual(CaseFolding(encoding: .utf16LE, caseSensitive: false), .utf16(littleEndian: true))
        XCTAssertEqual(CaseFolding(encoding: .utf16BE, caseSensitive: false), .utf16(littleEndian: false))
        XCTAssertEqual(CaseFolding(encoding: .utf16LE, caseSensitive: true), .exact)
    }

    /// UTF-16 IS text, so a case-insensitive search has to work there — it just
    /// cannot be done a byte at a time. Folding a *code unit*, and only when its
    /// other byte is zero (i.e. when it encodes an ASCII letter), finds `a` for a
    /// pattern of `A` and leaves `U+6100` alone.
    func testUTF16FoldingMatchesLettersAndNothingElse() throws {
        // "Setup" in UTF-16LE, upper-case S.
        let text = MemoryBackedStorage(bytes: try SearchEngine.parsePattern("Setup", encoding: .utf16LE).bytes)
        let lower = try SearchEngine.parsePattern("setup", encoding: .utf16LE).bytes

        XCTAssertNil(try SearchEngine.find(pattern: lower, in: text, folding: .exact),
                     "exact matching is case-sensitive, as ever")
        XCTAssertEqual(try SearchEngine.find(pattern: lower, in: text,
                                             folding: .utf16(littleEndian: true)),
                       0..<UInt64(lower.count),
                       "and the code-unit fold finds it")

        // The hazard the byte-wise fold walked into: U+6100 (00 61 LE) must not
        // match U+4100 (00 41 LE) — neither code unit encodes an ASCII letter,
        // since the byte that would be the letter is the zero one.
        let u6100 = try SearchEngine.parsePattern("\u{6100}", encoding: .utf16LE)
        let u4100 = MemoryBackedStorage(bytes: try SearchEngine.parsePattern("\u{4100}", encoding: .utf16LE).bytes)
        XCTAssertNil(try SearchEngine.find(pattern: u6100.bytes, in: u4100,
                                           folding: .utf16(littleEndian: true)),
                     "two different characters stay different")
    }

    /// The same, big-endian: the letter is the second byte of the pair.
    func testUTF16BigEndianFoldingMatchesLetters() throws {
        let text = MemoryBackedStorage(bytes: try SearchEngine.parsePattern("BIOS", encoding: .utf16BE).bytes)
        let lower = try SearchEngine.parsePattern("bios", encoding: .utf16BE).bytes

        XCTAssertEqual(try SearchEngine.find(pattern: lower, in: text,
                                             folding: .utf16(littleEndian: false)),
                       0..<UInt64(lower.count))
        XCTAssertNil(try SearchEngine.find(pattern: lower, in: text,
                                           folding: .utf16(littleEndian: true)),
                     "the wrong byte order folds the wrong byte, so nothing matches")
    }

    /// A code unit is two bytes counted from the *string's* own start, not from
    /// any grid in the file — so a UTF-16 string is found wherever it sits, at an
    /// even offset or an odd one. The first version of this folded whole windows
    /// on the file's 2-byte grid, which was faster and missed every upper-case
    /// string at an odd offset.
    func testUTF16FoldingFindsStringsAtAnyOffsetEvenOrOdd() throws {
        let word = try SearchEngine.parsePattern("Setup", encoding: .utf16LE).bytes
        let pattern = try SearchEngine.parsePattern("setup", encoding: .utf16LE).bytes

        for padding in 0...3 {
            let data = MemoryBackedStorage(bytes: [UInt8](repeating: 0xFF, count: padding) + word)
            let expected = UInt64(padding)..<UInt64(padding + word.count)

            XCTAssertEqual(try SearchEngine.find(pattern: pattern, in: data,
                                                 folding: .utf16(littleEndian: true)),
                           expected, "forward, at offset \(padding)")
            XCTAssertEqual(try SearchEngine.find(pattern: pattern, in: data,
                                                 from: UInt64(padding + word.count),
                                                 direction: .backward,
                                                 folding: .utf16(littleEndian: true)),
                           expected, "backward, at offset \(padding)")
            XCTAssertEqual(try SearchEngine.findAll(pattern: pattern, in: data,
                                                    folding: .utf16(littleEndian: true)),
                           [expected], "Search All, at offset \(padding)")
        }
    }

    /// The same for big-endian, where the letter is the second byte of the pair.
    func testUTF16BigEndianFoldingFindsStringsAtAnyOffset() throws {
        let word = try SearchEngine.parsePattern("BIOS", encoding: .utf16BE).bytes
        let pattern = try SearchEngine.parsePattern("bios", encoding: .utf16BE).bytes

        for padding in 0...3 {
            let data = MemoryBackedStorage(bytes: [UInt8](repeating: 0xFF, count: padding) + word)
            XCTAssertEqual(try SearchEngine.find(pattern: pattern, in: data,
                                                 folding: .utf16(littleEndian: false)),
                           UInt64(padding)..<UInt64(padding + word.count),
                           "at offset \(padding)")
        }
    }

    /// A match crossing a window boundary is still found: the candidate walk uses
    /// the same overlapped windows as the folded path.
    func testUTF16FoldingFindsAMatchAcrossAWindowBoundary() throws {
        let word = try SearchEngine.parsePattern("Setup", encoding: .utf16LE).bytes
        let pattern = try SearchEngine.parsePattern("setup", encoding: .utf16LE).bytes
        // The string straddles the boundary of a 16-byte chunk.
        let padding = 13
        let data = MemoryBackedStorage(bytes: [UInt8](repeating: 0xFF, count: padding) + word)

        XCTAssertEqual(try SearchEngine.find(pattern: pattern, in: data,
                                             folding: .utf16(littleEndian: true), chunkSize: 16),
                       UInt64(padding)..<UInt64(padding + word.count))
        XCTAssertEqual(try SearchEngine.findAll(pattern: pattern, in: data,
                                                folding: .utf16(littleEndian: true), chunkSize: 16),
                       [UInt64(padding)..<UInt64(padding + word.count)])
    }

    /// Search All folds the same way, so a case-insensitive UTF-16 sweep reports
    /// every occurrence whatever its case.
    func testUTF16FoldingInSearchAll() throws {
        let mixed = try SearchEngine.parsePattern("EfiEFIefi", encoding: .utf16LE).bytes
        let data = MemoryBackedStorage(bytes: mixed)
        let pattern = try SearchEngine.parsePattern("efi", encoding: .utf16LE).bytes

        let hits = try SearchEngine.findAll(pattern: pattern, in: data,
                                            folding: .utf16(littleEndian: true))
        XCTAssertEqual(hits, [0..<6, 6..<12, 12..<18], "all three, one per spelling")
    }
}
