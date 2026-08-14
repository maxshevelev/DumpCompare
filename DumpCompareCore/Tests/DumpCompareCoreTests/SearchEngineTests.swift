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

    func testFindNoMatch() throws {
        let bytes: [UInt8] = [0x00, 0x01, 0x02]
        XCTAssertNil(try find([0xAA, 0xBB], in: bytes))
        XCTAssertNil(try find([0xAA, 0xBB], in: bytes, direction: .backward))
        XCTAssertNil(try find([0x05], in: bytes))
    }

    func testFindPatternLongerThanFile() throws {
        XCTAssertNil(try find([0x00, 0x01, 0x02, 0x03], in: [0x00, 0x01]))
    }

    func testFindSingleByte() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA, 0x00]
        XCTAssertEqual(try find([0xAA], in: bytes, from: 0), 0..<1)
        XCTAssertEqual(try find([0xAA], in: bytes, from: 1), 2..<3)
    }

    func testFindBackward() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xDE, 0xAD]
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 7, direction: .backward), 5..<7)
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 5, direction: .backward), 0..<2)
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 4, direction: .backward), 0..<2)
        XCTAssertNil(try find([0xDE, 0xAD], in: bytes, from: 0, direction: .backward))
    }

    func testFindBackwardSingleByte() throws {
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA, 0x00]
        XCTAssertEqual(try find([0xAA], in: bytes, from: 4, direction: .backward), 2..<3)
        XCTAssertEqual(try find([0xAA], in: bytes, from: 1, direction: .backward), 0..<1)
        XCTAssertEqual(try find([0xAA], in: bytes, from: 0, direction: .backward), 0..<1)
    }

    func testFindMatchAtEOF() throws {
        let bytes: [UInt8] = [0x00, 0x01, 0xAA, 0xBB]
        XCTAssertEqual(try find([0xAA, 0xBB], in: bytes), 2..<4)
        XCTAssertEqual(try find([0xBB], in: bytes), 3..<4)
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

    func testFindReportsProgress() throws {
        var last: Double = -1
        let result = try SearchEngine.find(
            pattern: [0xFF], in: ArrayStorage([UInt8](repeating: 0, count: 16)),
            chunkSize: 4,
            progress: { last = $0 }
        )
        XCTAssertNil(result)
        XCTAssertEqual(last, 1.0)
    }
}
