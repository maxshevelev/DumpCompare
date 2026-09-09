import XCTest
import Foundation
@testable import MEFirmware

/// Phase 8 — Huffman decompression. The `Huffman.dat` grammar and the chunked
/// decoder are tested against synthetic self-consistent dictionaries and
/// hand-built compressed blobs; tests never touch the network (async-api §Testing
/// seam). The code tables here are deliberately trivial: one 8-bit codeword per
/// byte, so a "compressed" body is byte-for-byte its decompressed content — that
/// isolates the chunk directory / bit-buffer / dictionary machinery from any real
/// Huffman-table encoding concerns.
final class HuffmanTests: XCTestCase {

    // MARK: Fixtures

    /// A dictionary whose `code` and `data` tables are identical 8-bit identity
    /// codes: codeword value `v` decodes to the single byte `v`.
    private static func identityDictionary(unknown: Set<Int> = []) -> HuffmanDictionary {
        let shape = [HuffmanShape(length: 8, threshold: 0, maxCodeword: 255)]
        var symbols: [[UInt8]] = []
        for codeword in stride(from: 255, through: 0, by: -1) {
            symbols.append([UInt8(codeword)])
        }
        var unknowns: [Int: Set<Int>] = [:]
        if !unknown.isEmpty {
            unknowns[8] = unknown
            for codeword in unknown {
                symbols[255 - codeword] = [0x7F]   // unknown codeword -> placeholder
            }
        }
        let table = HuffmanSymbolTable(symbolsByLength: [8: symbols],
                                       unknownCodewords: unknowns)
        return HuffmanDictionary(shape: shape, code: table, data: table)
    }

    /// A module whose chunk directory declares each chunk's (start offset, dict flag).
    private static func module(chunks: [(flag: UInt32, offset: Int)],
                               bodies: [Data]) -> Data {
        var module = Data()
        for chunk in chunks {
            module.appendWithUInt32((chunk.flag << 25) | UInt32(chunk.offset))
        }
        for body in bodies { module.append(body) }
        return module
    }

    private static func content(_ length: Int, seed: UInt8 = 0x00) -> Data {
        Data((0..<length).map { (UInt8($0 & 0xFF)) ^ seed })
    }

    // MARK: Dictionary parser

    func testParseBuildsShapeSymbolsAndUnknowns() throws {
        // code: length 1 codeword 0 -> 'A'; length 2 codewords 0/3 -> 'a'/'b',
        // codewords 1..2 (gaps) absent -> 0x7F placeholders and unknown.
        let json = """
        {"12": {"code": {
            "0": "41",
            "00": "61",
            "11": "62"
        }, "data": {"0": "42"}}}
        """
        let parsed = try HuffmanDictionaries.parse(json)
        let v12 = try XCTUnwrap(parsed.version12)
        XCTAssertNil(parsed.version11)

        XCTAssertEqual(v12.shape.map(\.length), [1, 2])          // ascending length
        XCTAssertEqual(v12.shape[0].threshold, 0 << 31)          // min 0 @ len 1
        XCTAssertEqual(v12.shape[0].maxCodeword, 0)
        XCTAssertEqual(v12.shape[1].maxCodeword, 3)

        // code table: len-2 symbols indexed (max 3 - codeword): 3->'b', 2/1 gaps, 0->'a'.
        let symbols2 = try XCTUnwrap(v12.code.symbolsByLength[2])
        XCTAssertEqual(symbols2[0], [0x62])   // codeword 3 '11'
        XCTAssertEqual(symbols2[1], [0x7F])   // codeword 2 gap
        XCTAssertEqual(symbols2[2], [0x7F])   // codeword 1 gap
        XCTAssertEqual(symbols2[3], [0x61])   // codeword 0 '00'
        XCTAssertEqual(v12.code.unknownCodewords[2], [1, 2])
        XCTAssertEqual(try XCTUnwrap(v12.code.symbolsByLength[1])[0], [0x41])
        // data table built from its own mapping under the *code* shape.
        XCTAssertEqual(try XCTUnwrap(v12.data.symbolsByLength[1])[0], [0x42])
    }

    func testParseRejectsMissingCodeTable() {
        XCTAssertThrowsError(try HuffmanDictionaries.parse(#"{"12": {"data": {}}}"#))
    }

    // MARK: Dictionary version selection

    func testDictionaryVersionSelection() {
        XCTAssertEqual(HuffmanDictionaries.version(variant: "CSME", major: 11, minor: 0), 11)
        XCTAssertEqual(HuffmanDictionaries.version(variant: "CSME", major: 12, minor: 0), 12)
        XCTAssertEqual(HuffmanDictionaries.version(variant: "CSME", major: 14, minor: 5), 11)
        XCTAssertEqual(HuffmanDictionaries.version(variant: "CSME", major: 15, minor: 30), 12)
        XCTAssertEqual(HuffmanDictionaries.version(variant: "CSSPS", major: 4, minor: 0), 11)
        XCTAssertNil(HuffmanDictionaries.version(variant: "CSSPS", major: 1, minor: 0))
        XCTAssertNil(HuffmanDictionaries.version(variant: "PMC", major: 1, minor: 0))
        XCTAssertNil(HuffmanDictionaries.version(variant: "CSTXEC", major: 1, minor: 0))
    }

    // MARK: Decoder — single chunk

    func testDecodeSingleChunkIdentity() {
        let dict = Self.identityDictionary()
        let body = Self.content(0x1000)
        let module = Self.module(chunks: [(flag: 0x20, offset: 0)], bodies: [body])

        let result = HuffmanDecoder.decompress(
            module: module, compressedSize: 4 + 0x1000,
            decompressedSize: 0x1000, dictionary: dict)

        XCTAssertEqual(Data(result.output), body)
        XCTAssertTrue(result.clean)
    }

    func testDecodeTwoChunksWithIndependentDictionariesAndOffsets() {
        // Chunk 0 uses the code table (0x20), chunk 1 the data table (0x60); the
        // second directory entry points at its own start inside the stream.
        let dict = Self.identityDictionary()
        let a = Self.content(0x1000, seed: 0x11)
        let b = Self.content(0x1000, seed: 0xEE)
        let module = Self.module(chunks: [(flag: 0x20, offset: 0),
                                          (flag: 0x60, offset: 0x1000)],
                                 bodies: [a, b])

        let result = HuffmanDecoder.decompress(
            module: module, compressedSize: 8 + 0x2000,
            decompressedSize: 0x2000, dictionary: dict)

        var expected = a
        expected.append(b)
        XCTAssertEqual(Data(result.output), expected)
        XCTAssertTrue(result.clean)
    }

    func testDecodeModuleShorterThanItsDirectoryFillsAll() {
        // decompressed_size implies 2 chunks -> an 8-byte directory, but the module
        // is only 4 bytes: the directory cannot even be read. The decoder falls
        // back to an all-0x7F fill and reports unclean, never an out-of-bounds read.
        let dict = Self.identityDictionary()
        let module = Data(repeating: 0xFF, count: 4)

        let result = HuffmanDecoder.decompress(
            module: module, compressedSize: 4,
            decompressedSize: 0x2000, dictionary: dict)

        XCTAssertEqual(result.output.count, 0x2000)
        XCTAssertTrue(result.output.allSatisfy { $0 == 0x7F })
        XCTAssertFalse(result.clean)
    }

    // MARK: Decoder — truncation / unknowns fill, never early-return

    func testDecodeTruncatedStreamFillsAndContinuesToNextChunk() {
        // Chunk 0's directory-implied stream is only its 4-byte head (chunk 1
        // begins right after, at stream offset 4), so chunk 0 runs dry after 4
        // symbols, is 0x7F-filled to its 0x1000 boundary — and the *second* chunk
        // still decodes its own body from offset 4.
        let dict = Self.identityDictionary()
        let head = Self.content(4)
        let second = Self.content(0x1000, seed: 0x5A)
        let module = Self.module(chunks: [(flag: 0x20, offset: 0),
                                          (flag: 0x20, offset: 4)],
                                 bodies: [head, second])

        let result = HuffmanDecoder.decompress(
            module: module, compressedSize: 8 + 4 + 0x1000,
            decompressedSize: 0x2000, dictionary: dict)

        XCTAssertEqual(result.output.count, 0x2000)
        XCTAssertEqual(result.output.prefix(4), head)              // decoded fine
        XCTAssertTrue(result.output[4..<0x1000].allSatisfy { $0 == 0x7F })  // filled
        XCTAssertEqual(Data(result.output[0x1000...]), second)     // next chunk intact
        XCTAssertFalse(result.clean)
    }

    func testDecodeUnknownCodewordFlagsCleanButStillEmits() {
        // Byte 0x41's codeword is unknown (0x7F placeholder): the decoder flags the
        // run but keeps going — the length of the output is unaffected.
        let dict = Self.identityDictionary(unknown: [0x41])
        var body = Data(repeating: 0xAA, count: 0x1000)
        body[10] = 0x41
        let module = Self.module(chunks: [(flag: 0x20, offset: 0)], bodies: [body])

        let result = HuffmanDecoder.decompress(
            module: module, compressedSize: 4 + 0x1000,
            decompressedSize: 0x1000, dictionary: dict)

        XCTAssertEqual(result.output.count, 0x1000)
        XCTAssertEqual(result.output[10], 0x7F)   // the placeholder came through
        XCTAssertEqual(result.output[11], 0xAA)   // decoding continued past it
        XCTAssertFalse(result.clean)
    }

    func testDecodeEmptyDecompressedSizeYieldsEmpty() {
        let dict = Self.identityDictionary()
        let result = HuffmanDecoder.decompress(
            module: Data(), compressedSize: 0, decompressedSize: 0, dictionary: dict)
        XCTAssertEqual(result.output.count, 0)
        XCTAssertFalse(result.clean)
    }
}

// MARK: - Data test helpers (module-private, appended here to keep fixtures local)

private extension Data {
    mutating func appendWithUInt32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}
